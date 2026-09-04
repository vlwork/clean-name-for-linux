# ============================================================
# Clean File Names — Windows GUI
# (Очистка имён файлов — графический интерфейс Windows)
#
# This GUI reuses Clean-FileNames.ps1 in an isolated PowerShell runspace and
# consumes its structured snapshot and statistics. It does not duplicate any
# sanitization, conflict, or UTF-8 length rules.
# (Этот GUI повторно использует Clean-FileNames.ps1 в изолированном PowerShell
# runspace и получает его структурированный snapshot и статистику. Правила
# очистки, конфликтов и ограничения UTF-8 здесь не дублируются.)
# ============================================================

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

$CoreScriptPath = Join-Path $PSScriptRoot "Clean-FileNames.ps1"

# The adapter runs the existing CLI core in a separate runspace. This keeps
# console output out of the GUI and prevents a CLI exit from closing the form.
# (Адаптер запускает существующее CLI-ядро в отдельном runspace. Это не выводит
# консольный текст в GUI и не позволяет CLI exit закрыть форму.)
$CoreAdapterScript = @'
param(
    [string]$CorePath,
    [string]$TargetPath,
    [bool]$DoApply,
    [bool]$UseStrict,
    [bool]$UseDirectories
)

$ErrorActionPreference = "Stop"

$CoreParameters = @{
    Path = $TargetPath
}

if ($DoApply) {
    $CoreParameters.Apply = $true
}

if ($UseStrict) {
    $CoreParameters.Strict = $true
}

if ($UseDirectories) {
    $CoreParameters.IncludeDirectories = $true
}

. $CorePath @CoreParameters *> $null

# Resolve planned paths through stable parent owner IDs so directory renames
# are reflected in the Location column too.
# (Определяем планируемые пути через стабильные ID владельцев родительских
# каталогов, чтобы их переименования учитывались и в столбце Location.)
$ResolvedPathCache = @{}

function Resolve-PlannedRelativePath {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Record
    )

    if ($ResolvedPathCache.ContainsKey($Record.OwnerId)) {
        return [string]$ResolvedPathCache[$Record.OwnerId]
    }

    if ([string]::Equals(
        $Record.ParentOwnerId,
        $SnapshotState.RootOwnerId,
        [System.StringComparison]::Ordinal
    )) {
        $ResolvedPath = [string]$Record.CurrentVirtualName
    }
    else {
        $ParentRecord = $SnapshotState.RecordsByOwnerId[
            $Record.ParentOwnerId
        ]
        $ParentPath = Resolve-PlannedRelativePath -Record $ParentRecord
        $ResolvedPath = Join-Path `
            -Path $ParentPath `
            -ChildPath $Record.CurrentVirtualName
    }

    $ResolvedPathCache[$Record.OwnerId] = $ResolvedPath
    return $ResolvedPath
}

$OrderedRecords = @($FileRecords)

if ($UseDirectories) {
    $OrderedRecords += @($DirectoryRecords)
}

$StructuredRecords = New-Object System.Collections.ArrayList

foreach ($Record in $OrderedRecords) {
    $NeedsRename = -not [string]::Equals(
        $Record.OriginalName,
        $Record.CurrentVirtualName,
        [System.StringComparison]::Ordinal
    )
    $PlannedRelativePath = Resolve-PlannedRelativePath -Record $Record
    $Location = [System.IO.Path]::GetDirectoryName($PlannedRelativePath)

    if ([string]::IsNullOrEmpty($Location)) {
        $Location = "."
    }

    [void]$StructuredRecords.Add([pscustomobject]@{
        ItemType            = $Record.ItemType
        OriginalFullName    = $Record.OriginalFullName
        OriginalName        = $Record.OriginalName
        NewName             = $Record.CurrentVirtualName
        OriginalRelativePath = $Record.RelativePath
        PlannedRelativePath = $PlannedRelativePath
        Location            = $Location
        NeedsRename         = $NeedsRename
        Applied             = ($DoApply -and $NeedsRename)
        Error               = $null
    })
}

[pscustomobject]@{
    Path               = $RootPath
    Apply              = $DoApply
    Strict             = $UseStrict
    IncludeDirectories = $UseDirectories
    Checked            = [int]$Stats.Checked
    NeedRename         = [int]$Stats.NeedRename
    Renamed            = [int]$Stats.Renamed
    Errors             = [int]$Stats.Errors
    Records            = [object[]]$StructuredRecords.ToArray()
}
'@

function Invoke-CleanFileNamesCore {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [switch]$Apply,

        [switch]$Strict,

        [switch]$IncludeDirectories
    )

    if (-not (Test-Path -LiteralPath $CoreScriptPath -PathType Leaf)) {
        throw "Core script was not found (Не найден файл основного скрипта): $CoreScriptPath"
    }

    $PowerShell = [System.Management.Automation.PowerShell]::Create()

    try {
        [void]$PowerShell.AddScript($CoreAdapterScript)
        [void]$PowerShell.AddArgument($CoreScriptPath)
        [void]$PowerShell.AddArgument($Path)
        [void]$PowerShell.AddArgument([bool]$Apply)
        [void]$PowerShell.AddArgument([bool]$Strict)
        [void]$PowerShell.AddArgument([bool]$IncludeDirectories)

        $Output = @($PowerShell.Invoke())

        if ($PowerShell.HadErrors) {
            $CoreErrors = @(
                $PowerShell.Streams.Error |
                    ForEach-Object { $_.ToString() }
            ) -join [Environment]::NewLine

            throw "The core operation failed. (Сбой выполнения основного скрипта.)`r`n$CoreErrors"
        }

        if ($Output.Count -ne 1) {
            throw "The core did not return a structured result. (Основной скрипт не вернул структурированный результат.)"
        }

        return $Output[0]
    }
    finally {
        $PowerShell.Dispose()
    }
}

function Show-GuiMessage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,

        [string]$Caption = "Clean File Names",

        [System.Windows.Forms.MessageBoxButtons]$Buttons = `
            [System.Windows.Forms.MessageBoxButtons]::OK,

        [System.Windows.Forms.MessageBoxIcon]$Icon = `
            [System.Windows.Forms.MessageBoxIcon]::Information
    )

    return [System.Windows.Forms.MessageBox]::Show(
        $Form,
        $Text,
        $Caption,
        $Buttons,
        $Icon
    )
}

function Confirm-ApplyChanges {
    return Show-GuiMessage `
        -Text "Apply all planned renames?`r`n(Применить все запланированные переименования?)" `
        -Caption "Confirm changes (Подтверждение изменений)" `
        -Buttons ([System.Windows.Forms.MessageBoxButtons]::YesNo) `
        -Icon ([System.Windows.Forms.MessageBoxIcon]::Warning)
}

function Select-Folder {
    $Dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $Dialog.Description = "Select a folder to scan (Выберите папку для проверки)"
    $Dialog.ShowNewFolderButton = $false

    if (Test-Path -LiteralPath $FolderTextBox.Text -PathType Container) {
        $Dialog.SelectedPath = $FolderTextBox.Text
    }

    try {
        if ($Dialog.ShowDialog($Form) -eq [System.Windows.Forms.DialogResult]::OK) {
            return $Dialog.SelectedPath
        }

        return $null
    }
    finally {
        $Dialog.Dispose()
    }
}

# Main window. (Главное окно.)
$Form = New-Object System.Windows.Forms.Form
$Form.Text = "Clean File Names — Windows/Linux Compatibility"
$Form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$Form.ClientSize = New-Object System.Drawing.Size(1000, 650)
$Form.MinimumSize = New-Object System.Drawing.Size(850, 550)
$Form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi

$Layout = New-Object System.Windows.Forms.TableLayoutPanel
$Layout.Dock = [System.Windows.Forms.DockStyle]::Fill
$Layout.ColumnCount = 1
$Layout.RowCount = 4
$Layout.Padding = New-Object System.Windows.Forms.Padding(10)
[void]$Layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle(
    [System.Windows.Forms.SizeType]::Absolute,
    50
)))
[void]$Layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle(
    [System.Windows.Forms.SizeType]::Absolute,
    105
)))
[void]$Layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle(
    [System.Windows.Forms.SizeType]::Percent,
    100
)))
[void]$Layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle(
    [System.Windows.Forms.SizeType]::Absolute,
    115
)))

$HeaderLabel = New-Object System.Windows.Forms.Label
$HeaderLabel.Text = "File Name Compatibility Checker (Проверка совместимости имён файлов)"
$HeaderLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
$HeaderLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$HeaderLabel.Font = New-Object System.Drawing.Font(
    $Form.Font.FontFamily,
    14,
    [System.Drawing.FontStyle]::Bold
)

$SettingsPanel = New-Object System.Windows.Forms.Panel
$SettingsPanel.Dock = [System.Windows.Forms.DockStyle]::Fill

$FolderLabel = New-Object System.Windows.Forms.Label
$FolderLabel.Text = "Folder (Папка)"
$FolderLabel.Location = New-Object System.Drawing.Point(3, 4)
$FolderLabel.AutoSize = $true

$FolderTextBox = New-Object System.Windows.Forms.TextBox
$FolderTextBox.Location = New-Object System.Drawing.Point(3, 27)
$FolderTextBox.Size = New-Object System.Drawing.Size(820, 25)
$FolderTextBox.Anchor = `
    [System.Windows.Forms.AnchorStyles]::Top -bor `
    [System.Windows.Forms.AnchorStyles]::Left -bor `
    [System.Windows.Forms.AnchorStyles]::Right

$BrowseButton = New-Object System.Windows.Forms.Button
$BrowseButton.Text = "Browse... (Выбрать...)"
$BrowseButton.Location = New-Object System.Drawing.Point(832, 25)
$BrowseButton.Size = New-Object System.Drawing.Size(138, 29)
$BrowseButton.Anchor = `
    [System.Windows.Forms.AnchorStyles]::Top -bor `
    [System.Windows.Forms.AnchorStyles]::Right

$StrictCheckBox = New-Object System.Windows.Forms.CheckBox
$StrictCheckBox.Text = "Strict mode (Строгий режим)"
$StrictCheckBox.Location = New-Object System.Drawing.Point(3, 67)
$StrictCheckBox.AutoSize = $true
$StrictCheckBox.Checked = $false

$DirectoriesCheckBox = New-Object System.Windows.Forms.CheckBox
$DirectoriesCheckBox.Text = "Rename directories (Переименовывать каталоги)"
$DirectoriesCheckBox.Location = New-Object System.Drawing.Point(245, 67)
$DirectoriesCheckBox.AutoSize = $true
$DirectoriesCheckBox.Checked = $false

[void]$SettingsPanel.Controls.Add($FolderLabel)
[void]$SettingsPanel.Controls.Add($FolderTextBox)
[void]$SettingsPanel.Controls.Add($BrowseButton)
[void]$SettingsPanel.Controls.Add($StrictCheckBox)
[void]$SettingsPanel.Controls.Add($DirectoriesCheckBox)

$ResultsGrid = New-Object System.Windows.Forms.DataGridView
$ResultsGrid.Dock = [System.Windows.Forms.DockStyle]::Fill
$ResultsGrid.Margin = New-Object System.Windows.Forms.Padding(3, 3, 3, 8)
$ResultsGrid.AllowUserToAddRows = $false
$ResultsGrid.AllowUserToDeleteRows = $false
$ResultsGrid.AllowUserToResizeRows = $false
$ResultsGrid.AutoGenerateColumns = $false
$ResultsGrid.AutoSizeColumnsMode = `
    [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::Fill
$ResultsGrid.BackgroundColor = [System.Drawing.SystemColors]::Window
$ResultsGrid.BorderStyle = [System.Windows.Forms.BorderStyle]::Fixed3D
$ResultsGrid.MultiSelect = $false
$ResultsGrid.ReadOnly = $true
$ResultsGrid.RowHeadersVisible = $false
$ResultsGrid.SelectionMode = `
    [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect

foreach ($ColumnDefinition in @(
    @("Type", "Type (Тип)", 15),
    @("Before", "Before (Было)", 30),
    @("After", "After (Будет)", 30),
    @("Location", "Location (Расположение)", 25)
)) {
    $Column = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $Column.Name = $ColumnDefinition[0]
    $Column.HeaderText = $ColumnDefinition[1]
    $Column.FillWeight = $ColumnDefinition[2]
    $Column.ReadOnly = $true
    [void]$ResultsGrid.Columns.Add($Column)
}

$FooterPanel = New-Object System.Windows.Forms.Panel
$FooterPanel.Dock = [System.Windows.Forms.DockStyle]::Fill

$CheckedLabel = New-Object System.Windows.Forms.Label
$CheckedLabel.Location = New-Object System.Drawing.Point(3, 5)
$CheckedLabel.Size = New-Object System.Drawing.Size(245, 22)

$NeedRenameLabel = New-Object System.Windows.Forms.Label
$NeedRenameLabel.Location = New-Object System.Drawing.Point(255, 5)
$NeedRenameLabel.Size = New-Object System.Drawing.Size(310, 22)

$RenamedLabel = New-Object System.Windows.Forms.Label
$RenamedLabel.Location = New-Object System.Drawing.Point(3, 31)
$RenamedLabel.Size = New-Object System.Drawing.Size(245, 22)

$ErrorsLabel = New-Object System.Windows.Forms.Label
$ErrorsLabel.Location = New-Object System.Drawing.Point(255, 31)
$ErrorsLabel.Size = New-Object System.Drawing.Size(310, 22)

$StatusLabel = New-Object System.Windows.Forms.Label
$StatusLabel.Location = New-Object System.Drawing.Point(3, 67)
$StatusLabel.Size = New-Object System.Drawing.Size(620, 30)
$StatusLabel.Anchor = `
    [System.Windows.Forms.AnchorStyles]::Left -bor `
    [System.Windows.Forms.AnchorStyles]::Right -bor `
    [System.Windows.Forms.AnchorStyles]::Bottom
$StatusLabel.AutoEllipsis = $true

$ScanButton = New-Object System.Windows.Forms.Button
$ScanButton.Text = "Scan (Проверить)"
$ScanButton.Location = New-Object System.Drawing.Point(676, 64)
$ScanButton.Size = New-Object System.Drawing.Size(125, 34)
$ScanButton.Anchor = `
    [System.Windows.Forms.AnchorStyles]::Right -bor `
    [System.Windows.Forms.AnchorStyles]::Bottom

$ApplyButton = New-Object System.Windows.Forms.Button
$ApplyButton.Text = "Apply changes (Применить изменения)"
$ApplyButton.Location = New-Object System.Drawing.Point(810, 64)
$ApplyButton.Size = New-Object System.Drawing.Size(160, 34)
$ApplyButton.Anchor = `
    [System.Windows.Forms.AnchorStyles]::Right -bor `
    [System.Windows.Forms.AnchorStyles]::Bottom
$ApplyButton.Enabled = $false

[void]$FooterPanel.Controls.Add($CheckedLabel)
[void]$FooterPanel.Controls.Add($NeedRenameLabel)
[void]$FooterPanel.Controls.Add($RenamedLabel)
[void]$FooterPanel.Controls.Add($ErrorsLabel)
[void]$FooterPanel.Controls.Add($StatusLabel)
[void]$FooterPanel.Controls.Add($ScanButton)
[void]$FooterPanel.Controls.Add($ApplyButton)

[void]$Layout.Controls.Add($HeaderLabel, 0, 0)
[void]$Layout.Controls.Add($SettingsPanel, 0, 1)
[void]$Layout.Controls.Add($ResultsGrid, 0, 2)
[void]$Layout.Controls.Add($FooterPanel, 0, 3)
[void]$Form.Controls.Add($Layout)

$script:ScannedPath = $null
$script:ScannedStrict = $false
$script:ScannedIncludeDirectories = $false
$script:ScannedPlanSignature = $null
$script:PlanCanApply = $false
$script:IsBusy = $false

function Reset-Summary {
    $CheckedLabel.Text = "Checked (Проверено): 0"
    $NeedRenameLabel.Text = "Need renaming (Требуют переименования): 0"
    $RenamedLabel.Text = "Renamed (Переименовано): 0"
    $ErrorsLabel.Text = "Errors (Ошибок): 0"
}

function Clear-CurrentPlan {
    $script:ScannedPath = $null
    $script:ScannedStrict = $false
    $script:ScannedIncludeDirectories = $false
    $script:ScannedPlanSignature = $null
    $script:PlanCanApply = $false
    $ApplyButton.Enabled = $false
    $ResultsGrid.Rows.Clear()
    Reset-Summary
}

function Invalidate-CurrentPlan {
    if ($script:IsBusy) {
        return
    }

    $HadPlan = -not [string]::IsNullOrEmpty($script:ScannedPath)
    Clear-CurrentPlan

    if ($HadPlan) {
        $StatusLabel.Text = "Settings changed — run Scan again. (Параметры изменены — повторите проверку.)"
    }
}

function Set-BusyState {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Busy
    )

    $script:IsBusy = $Busy
    $FolderTextBox.Enabled = -not $Busy
    $BrowseButton.Enabled = -not $Busy
    $StrictCheckBox.Enabled = -not $Busy
    $DirectoriesCheckBox.Enabled = -not $Busy
    $ScanButton.Enabled = -not $Busy

    if ($Busy) {
        $ApplyButton.Enabled = $false
        $Form.UseWaitCursor = $true
        $Form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    }
    else {
        $ApplyButton.Enabled = $script:PlanCanApply
        $Form.UseWaitCursor = $false
        $Form.Cursor = [System.Windows.Forms.Cursors]::Default
    }

    $Form.Refresh()
}

function Resolve-SelectedFolder {
    $SelectedPath = $FolderTextBox.Text.Trim()

    if ([string]::IsNullOrWhiteSpace($SelectedPath)) {
        [void](Show-GuiMessage `
            -Text "Please select a folder first.`r`n(Сначала выберите папку.)" `
            -Icon ([System.Windows.Forms.MessageBoxIcon]::Warning))
        return $null
    }

    try {
        if (-not (Test-Path -LiteralPath $SelectedPath -PathType Container)) {
            [void](Show-GuiMessage `
                -Text "The selected folder does not exist.`r`n(Выбранная папка не существует.)" `
                -Icon ([System.Windows.Forms.MessageBoxIcon]::Warning))
            return $null
        }

        return (Resolve-Path -LiteralPath $SelectedPath).Path
    }
    catch {
        [void](Show-GuiMessage `
            -Text "The selected folder could not be accessed.`r`n(Не удалось получить доступ к выбранной папке.)`r`n`r`n$($_.Exception.Message)" `
            -Icon ([System.Windows.Forms.MessageBoxIcon]::Error))
        return $null
    }
}

function Show-StructuredResult {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Result
    )

    $ResultsGrid.Rows.Clear()

    foreach ($Record in @($Result.Records)) {
        if (-not $Record.NeedsRename) {
            continue
        }

        if ($Record.ItemType -eq "Directory") {
            $DisplayType = "Directory (Каталог)"
        }
        else {
            $DisplayType = "File (Файл)"
        }

        [void]$ResultsGrid.Rows.Add(
            $DisplayType,
            $Record.OriginalName,
            $Record.NewName,
            $Record.Location
        )
    }

    $CheckedLabel.Text = "Checked (Проверено): $($Result.Checked)"
    $NeedRenameLabel.Text = "Need renaming (Требуют переименования): $($Result.NeedRename)"
    $RenamedLabel.Text = "Renamed (Переименовано): $($Result.Renamed)"
    $ErrorsLabel.Text = "Errors (Ошибок): $($Result.Errors)"
}

function Get-PlanSignature {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Result
    )

    # Sort exact plan fields with ordinal semantics, then serialize a fixed
    # ordered structure. JSON escaping prevents separator ambiguities.
    # (Сортируем точные поля плана с ordinal-семантикой, затем сериализуем
    # фиксированную ordered-структуру. JSON escaping исключает неоднозначность
    # разделителей.)
    $PlanRecords = [object[]]@(
        $Result.Records |
            Where-Object { $_.NeedsRename }
    )
    $Comparer = [System.Collections.Generic.Comparer[object]]::Create(
        [System.Comparison[object]]{
            param($Left, $Right)

            foreach ($PropertyName in @(
                "ItemType",
                "OriginalRelativePath",
                "NewName",
                "PlannedRelativePath"
            )) {
                $Comparison = [System.StringComparer]::Ordinal.Compare(
                    [string]$Left.$PropertyName,
                    [string]$Right.$PropertyName
                )

                if ($Comparison -ne 0) {
                    return $Comparison
                }
            }

            return 0
        }
    )

    [System.Array]::Sort($PlanRecords, $Comparer)
    $CanonicalRecords = @(
        foreach ($Record in $PlanRecords) {
            [ordered]@{
                ItemType            = [string]$Record.ItemType
                OriginalRelativePath = [string]$Record.OriginalRelativePath
                NewName             = [string]$Record.NewName
                PlannedRelativePath = [string]$Record.PlannedRelativePath
            }
        }
    )
    $CanonicalPlan = [ordered]@{
        NeedRename = [int]$Result.NeedRename
        Errors     = [int]$Result.Errors
        Records    = $CanonicalRecords
    }

    return ($CanonicalPlan | ConvertTo-Json -Depth 4 -Compress)
}

function Save-ScannedSettings {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [object]$Result
    )

    $script:ScannedPath = $Path
    $script:ScannedStrict = $StrictCheckBox.Checked
    $script:ScannedIncludeDirectories = $DirectoriesCheckBox.Checked
    $script:ScannedPlanSignature = Get-PlanSignature -Result $Result
    $script:PlanCanApply = (
        $Result.NeedRename -gt 0 -and
        $Result.Errors -eq 0
    )
}

function Invoke-ScanAndDisplay {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $Result = Invoke-CleanFileNamesCore `
        -Path $Path `
        -Strict:$StrictCheckBox.Checked `
        -IncludeDirectories:$DirectoriesCheckBox.Checked

    Show-StructuredResult -Result $Result
    Save-ScannedSettings -Path $Path -Result $Result
    $StatusLabel.Text = "Scan completed. (Проверка завершена.)"
    return $Result
}

function Test-ScannedSettingsAreCurrent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CurrentPath
    )

    return (
        -not [string]::IsNullOrEmpty($script:ScannedPath) -and
        -not [string]::IsNullOrEmpty($script:ScannedPlanSignature) -and
        [string]::Equals(
            $CurrentPath,
            $script:ScannedPath,
            [System.StringComparison]::OrdinalIgnoreCase
        ) -and
        $StrictCheckBox.Checked -eq $script:ScannedStrict -and
        $DirectoriesCheckBox.Checked -eq `
            $script:ScannedIncludeDirectories
    )
}

$BrowseButton.Add_Click({
    try {
        $SelectedPath = Select-Folder

        if (-not [string]::IsNullOrEmpty($SelectedPath)) {
            $FolderTextBox.Text = $SelectedPath
        }
    }
    catch {
        [void](Show-GuiMessage `
            -Text "An error occurred while selecting a folder.`r`n(Во время выбора папки произошла ошибка.)`r`n`r`n$($_.Exception.Message)" `
            -Icon ([System.Windows.Forms.MessageBoxIcon]::Error))
    }
})

$FolderTextBox.Add_TextChanged({ Invalidate-CurrentPlan })
$StrictCheckBox.Add_CheckedChanged({ Invalidate-CurrentPlan })
$DirectoriesCheckBox.Add_CheckedChanged({ Invalidate-CurrentPlan })

$ScanButton.Add_Click({
    $SelectedPath = Resolve-SelectedFolder

    if ([string]::IsNullOrEmpty($SelectedPath)) {
        return
    }

    Set-BusyState -Busy $true

    try {
        $Result = Invoke-ScanAndDisplay -Path $SelectedPath

        if ($Result.Errors -gt 0) {
            [void](Show-GuiMessage `
                -Text "Scanning completed with errors.`r`n(Проверка завершена с ошибками.)`r`n`r`nErrors (Ошибок): $($Result.Errors)" `
                -Icon ([System.Windows.Forms.MessageBoxIcon]::Warning))
        }
    }
    catch {
        Clear-CurrentPlan
        $StatusLabel.Text = "Scan failed. (Проверка завершилась ошибкой.)"
        [void](Show-GuiMessage `
            -Text "An error occurred while scanning.`r`n(Во время проверки произошла ошибка.)`r`n`r`n$($_.Exception.Message)" `
            -Icon ([System.Windows.Forms.MessageBoxIcon]::Error))
    }
    finally {
        Set-BusyState -Busy $false
    }
})

$ApplyButton.Add_Click({
    $SelectedPath = Resolve-SelectedFolder

    if ([string]::IsNullOrEmpty($SelectedPath)) {
        return
    }

    if (-not (Test-ScannedSettingsAreCurrent -CurrentPath $SelectedPath)) {
        Clear-CurrentPlan
        $StatusLabel.Text = "Plan is no longer valid. (План больше не действителен.)"
        [void](Show-GuiMessage `
            -Text "The settings changed after Scan. Please run Scan again.`r`n(После проверки параметры изменились. Повторите проверку.)" `
            -Icon ([System.Windows.Forms.MessageBoxIcon]::Warning))
        return
    }

    if ((Confirm-ApplyChanges) -ne [System.Windows.Forms.DialogResult]::Yes) {
        return
    }

    Set-BusyState -Busy $true
    $OperationPhase = "Revalidation"

    try {
        # Revalidate the exact rename plan without changing the displayed UI.
        # (Повторно проверяем точный план переименований, не изменяя показанный UI.)
        # The plan is revalidated immediately after user confirmation and immediately
        # before Apply. This minimizes, but cannot completely eliminate, external
        # filesystem races between revalidation and Rename-Item.
        # (План повторно проверяется сразу после подтверждения пользователя и
        # непосредственно перед Apply. Это минимизирует, но не может полностью исключить
        # внешние изменения файловой системы между повторной проверкой и Rename-Item.)
        $FreshResult = Invoke-CleanFileNamesCore `
            -Path $SelectedPath `
            -Strict:$StrictCheckBox.Checked `
            -IncludeDirectories:$DirectoriesCheckBox.Checked
        $FreshPlanSignature = Get-PlanSignature -Result $FreshResult

        if (-not [string]::Equals(
            $FreshPlanSignature,
            $script:ScannedPlanSignature,
            [System.StringComparison]::Ordinal
        )) {
            Clear-CurrentPlan
            $StatusLabel.Text = "Folder contents changed — run Scan again. (Содержимое папки изменилось — повторите проверку.)"
            [void](Show-GuiMessage `
                -Text "The folder contents changed after Scan.`r`nNo changes were applied. Please run Scan again.`r`n(Содержимое папки изменилось после проверки.`r`nИзменения не применялись. Повторите проверку.)" `
                -Icon ([System.Windows.Forms.MessageBoxIcon]::Warning))
            return
        }

        $OperationPhase = "Apply"
        $ApplyResult = Invoke-CleanFileNamesCore `
            -Path $SelectedPath `
            -Apply `
            -Strict:$StrictCheckBox.Checked `
            -IncludeDirectories:$DirectoriesCheckBox.Checked

        # Refresh the table from the actual current filesystem state.
        # (Обновляем таблицу по фактическому текущему состоянию файловой системы.)
        [void](Invoke-ScanAndDisplay -Path $SelectedPath)

        if ($ApplyResult.Errors -gt 0) {
            $CompletionText = "Completed with errors.`r`n(Завершено с ошибками.)"
            $CompletionIcon = [System.Windows.Forms.MessageBoxIcon]::Warning
        }
        else {
            $CompletionText = "Renaming completed.`r`n(Переименование завершено.)"
            $CompletionIcon = [System.Windows.Forms.MessageBoxIcon]::Information
        }

        $CompletionText += "`r`n`r`nRenamed (Переименовано): $($ApplyResult.Renamed)"
        $CompletionText += "`r`nErrors (Ошибок): $($ApplyResult.Errors)"

        [void](Show-GuiMessage `
            -Text $CompletionText `
            -Icon $CompletionIcon)
    }
    catch {
        Clear-CurrentPlan

        if ($OperationPhase -eq "Revalidation") {
            $StatusLabel.Text = "Plan revalidation failed. (Повторная проверка плана завершилась ошибкой.)"
            [void](Show-GuiMessage `
                -Text "An error occurred while revalidating the plan.`r`n(Во время повторной проверки плана произошла ошибка.)`r`n`r`n$($_.Exception.Message)" `
                -Icon ([System.Windows.Forms.MessageBoxIcon]::Error))
        }
        else {
            $StatusLabel.Text = "Apply failed. (Применение завершилось ошибкой.)"
            [void](Show-GuiMessage `
                -Text "An error occurred while applying changes.`r`n(Во время применения изменений произошла ошибка.)`r`n`r`n$($_.Exception.Message)" `
                -Icon ([System.Windows.Forms.MessageBoxIcon]::Error))
        }
    }
    finally {
        Set-BusyState -Busy $false
    }
})

Reset-Summary
$StatusLabel.Text = "Select a folder and run Scan. (Выберите папку и запустите проверку.)"
$Form.Add_Shown({ [void]$FolderTextBox.Focus() })

# Dot-sourcing initializes the form without opening it, which allows safe local
# UI regression tests. Normal -File execution opens the application window.
# (При dot-sourcing форма инициализируется без открытия, что позволяет выполнять
# безопасные локальные UI regression tests. Обычный запуск через -File открывает окно.)
if ($MyInvocation.InvocationName -ne ".") {
    [System.Windows.Forms.Application]::Run($Form)
}
