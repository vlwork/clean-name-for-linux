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

$script:CoreSourceMode = $null
$script:CoreText = $null
$CoreScriptPath = $null

function ConvertFrom-CoreUtf8Bytes {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Bytes
    )

    $TextOffset = 0

    # Both source modes use the same canonical text representation. Remove only
    # an optional leading UTF-8 BOM before strict decoding.
    # (Оба режима источника используют одинаковое каноническое представление
    # текста. Перед строгим декодированием удаляем только начальный UTF-8 BOM.)
    if ($Bytes.Length -ge 3 -and
        $Bytes[0] -eq 0xEF -and
        $Bytes[1] -eq 0xBB -and
        $Bytes[2] -eq 0xBF) {
        $TextOffset = 3
    }

    $StrictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
    return $StrictUtf8.GetString(
        $Bytes,
        $TextOffset,
        $Bytes.Length - $TextOffset
    )
}

# A future generated build wrapper can define both script-level variables before
# this GUI source. Source/development runs do not define them and keep using the
# external core next to this file.
# (Будущий generated build-wrapper может определить обе script-level переменные
# перед этим GUI-кодом. При запуске из исходников они не определены, поэтому
# по-прежнему используется внешнее ядро рядом с этим файлом.)
$EmbeddedBase64Variable = Get-Variable `
    -Name "CleanFileNamesEmbeddedCoreBase64" `
    -Scope Script `
    -ErrorAction SilentlyContinue
$EmbeddedSha256Variable = Get-Variable `
    -Name "CleanFileNamesEmbeddedCoreSha256" `
    -Scope Script `
    -ErrorAction SilentlyContinue

if ($null -ne $EmbeddedBase64Variable -or $null -ne $EmbeddedSha256Variable) {
    $script:CoreSourceMode = "Embedded"

    if ($null -eq $EmbeddedBase64Variable -or
        [string]::IsNullOrWhiteSpace([string]$EmbeddedBase64Variable.Value)) {
        throw "Embedded core payload is missing.`r`n(Отсутствуют данные встроенного ядра.)"
    }

    if ($null -eq $EmbeddedSha256Variable -or
        [string]::IsNullOrWhiteSpace([string]$EmbeddedSha256Variable.Value)) {
        throw "Embedded core SHA-256 is missing.`r`n(Отсутствует SHA-256 встроенного ядра.)"
    }

    $ExpectedEmbeddedSha256 = ([string]$EmbeddedSha256Variable.Value).Trim()

    if ($ExpectedEmbeddedSha256 -notmatch '\A[0-9A-Fa-f]{64}\z') {
        throw "Embedded core SHA-256 has an invalid format.`r`n(SHA-256 встроенного ядра имеет неверный формат.)"
    }

    try {
        $EmbeddedCoreBytes = [Convert]::FromBase64String(
            [string]$EmbeddedBase64Variable.Value
        )
    }
    catch {
        throw "Embedded core payload is not valid Base64.`r`n(Данные встроенного ядра не являются корректным Base64.)`r`n`r`n$($_.Exception.Message)"
    }

    if ($EmbeddedCoreBytes.Length -eq 0) {
        throw "Embedded core payload is empty.`r`n(Данные встроенного ядра пусты.)"
    }

    # The embedded hash detects accidental payload corruption during packaging
    # or distribution. It is not a substitute for executable code signing.
    # (Хэш встроенного ядра обнаруживает случайное повреждение payload при сборке
    # или распространении. Он не заменяет цифровую подпись исполняемого файла.)
    $EmbeddedCoreHashAlgorithm = `
        [System.Security.Cryptography.SHA256]::Create()

    try {
        $ActualEmbeddedSha256 = [BitConverter]::ToString(
            $EmbeddedCoreHashAlgorithm.ComputeHash($EmbeddedCoreBytes)
        ).Replace("-", "")
    }
    finally {
        $EmbeddedCoreHashAlgorithm.Dispose()
    }

    if (-not [string]::Equals(
        $ActualEmbeddedSha256,
        $ExpectedEmbeddedSha256,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Embedded core integrity check failed.`r`n(Проверка целостности встроенного ядра не пройдена.)"
    }

    try {
        $script:CoreText = ConvertFrom-CoreUtf8Bytes -Bytes $EmbeddedCoreBytes
    }
    catch {
        throw "Embedded core payload is not valid UTF-8.`r`n(Данные встроенного ядра не являются корректным UTF-8.)`r`n`r`n$($_.Exception.Message)"
    }

    if ([string]::IsNullOrEmpty($script:CoreText)) {
        throw "Embedded core payload is empty.`r`n(Данные встроенного ядра пусты.)"
    }
}
else {
    $script:CoreSourceMode = "External"
    $CoreScriptPath = Join-Path $PSScriptRoot "Clean-FileNames.ps1"

    try {
        if (-not (Test-Path -LiteralPath $CoreScriptPath -PathType Leaf)) {
            throw "Core script was not found (Не найден файл основного скрипта): $CoreScriptPath"
        }

        $ExternalCoreBytes = [System.IO.File]::ReadAllBytes($CoreScriptPath)
        $script:CoreText = ConvertFrom-CoreUtf8Bytes -Bytes $ExternalCoreBytes

        if ([string]::IsNullOrEmpty($script:CoreText)) {
            throw "Core script is empty. (Основной скрипт пуст.)"
        }
    }
    catch {
        throw "Core script could not be loaded.`r`n(Не удалось загрузить основной скрипт.)`r`n`r`n$($_.Exception.Message)"
    }
}

# The adapter runs the existing CLI core in a separate runspace. This keeps
# console output out of the GUI and prevents a CLI exit from closing the form.
# (Адаптер запускает существующее CLI-ядро в отдельном runspace. Это не выводит
# консольный текст в GUI и не позволяет CLI exit закрыть форму.)
$CoreAdapterScript = @'
param(
    [string]$CoreText,
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

$CoreScriptBlock = [scriptblock]::Create($CoreText)
. $CoreScriptBlock @CoreParameters *> $null

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

    # The GUI displays and signs only rename-plan records. Skipping unchanged
    # items here avoids allocating and transferring tens of thousands of unused
    # PSObjects while preserving Checked and every cleanup decision from core.
    # (GUI отображает и подписывает только записи плана переименований. Пропуск
    # неизменённых объектов здесь исключает создание и передачу десятков тысяч
    # ненужных PSObjects, сохраняя Checked и все решения основного скрипта.)
    if (-not $NeedsRename) {
        continue
    }

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

    $PowerShell = New-CorePowerShell `
        -Path $Path `
        -Apply:$Apply `
        -Strict:$Strict `
        -IncludeDirectories:$IncludeDirectories

    try {
        $Output = @($PowerShell.Invoke())
        return ConvertTo-CoreResult -PowerShell $PowerShell -Output $Output
    }
    finally {
        $PowerShell.Dispose()
    }
}

function New-CorePowerShell {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [switch]$Apply,

        [switch]$Strict,

        [switch]$IncludeDirectories
    )

    $PowerShell = [System.Management.Automation.PowerShell]::Create()

    try {
        [void]$PowerShell.AddScript($CoreAdapterScript)
        [void]$PowerShell.AddArgument($script:CoreText)
        [void]$PowerShell.AddArgument($Path)
        [void]$PowerShell.AddArgument([bool]$Apply)
        [void]$PowerShell.AddArgument([bool]$Strict)
        [void]$PowerShell.AddArgument([bool]$IncludeDirectories)
        return $PowerShell
    }
    catch {
        $PowerShell.Dispose()
        throw
    }
}

function ConvertTo-CoreResult {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PowerShell]$PowerShell,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Output
    )

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

function Start-CleanFileNamesCore {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [switch]$Strict,

        [switch]$IncludeDirectories
    )

    $PowerShell = New-CorePowerShell `
        -Path $Path `
        -Strict:$Strict `
        -IncludeDirectories:$IncludeDirectories

    try {
        $AsyncResult = $PowerShell.BeginInvoke()

        return [pscustomobject]@{
            PowerShell     = $PowerShell
            AsyncResult    = $AsyncResult
            CancelRequested = $false
            StopAsyncResult = $null
        }
    }
    catch {
        $PowerShell.Dispose()
        throw
    }
}

function Complete-CleanFileNamesCore {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Operation
    )

    try {
        if ($null -ne $Operation.StopAsyncResult) {
            $Operation.PowerShell.EndStop($Operation.StopAsyncResult)
        }

        $Output = @($Operation.PowerShell.EndInvoke($Operation.AsyncResult))
        return ConvertTo-CoreResult `
            -PowerShell $Operation.PowerShell `
            -Output $Output
    }
    finally {
        $Operation.PowerShell.Dispose()
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

    if (-not [string]::IsNullOrWhiteSpace($FolderTextBox.Text) -and
        (Test-Path -LiteralPath $FolderTextBox.Text -PathType Container)) {
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
$Form.ClientSize = New-Object System.Drawing.Size(1120, 720)
$Form.MinimumSize = New-Object System.Drawing.Size(1000, 650)
$Form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
$Form.KeyPreview = $true
$Form.AllowDrop = $true

$Layout = New-Object System.Windows.Forms.TableLayoutPanel
$Layout.Dock = [System.Windows.Forms.DockStyle]::Fill
$Layout.ColumnCount = 1
$Layout.RowCount = 5
$Layout.Padding = New-Object System.Windows.Forms.Padding(10)
[void]$Layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle(
    [System.Windows.Forms.SizeType]::Absolute,
    52
)))
[void]$Layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle(
    [System.Windows.Forms.SizeType]::Absolute,
    135
)))
[void]$Layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle(
    [System.Windows.Forms.SizeType]::Percent,
    100
)))
[void]$Layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle(
    [System.Windows.Forms.SizeType]::Absolute,
    82
)))
[void]$Layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle(
    [System.Windows.Forms.SizeType]::Absolute,
    24
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

$SettingsPanel = New-Object System.Windows.Forms.TableLayoutPanel
$SettingsPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$SettingsPanel.ColumnCount = 3
$SettingsPanel.RowCount = 4
[void]$SettingsPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle(
    [System.Windows.Forms.SizeType]::Absolute,
    95
)))
[void]$SettingsPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle(
    [System.Windows.Forms.SizeType]::Percent,
    100
)))
[void]$SettingsPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle(
    [System.Windows.Forms.SizeType]::Absolute,
    170
)))
foreach ($Height in @(32, 30, 40, 25)) {
    [void]$SettingsPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle(
        [System.Windows.Forms.SizeType]::Absolute,
        $Height
    )))
}

$FolderLabel = New-Object System.Windows.Forms.Label
$FolderLabel.Text = "Folder (Папка):"
$FolderLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
$FolderLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft

$FolderTextBox = New-Object System.Windows.Forms.TextBox
$FolderTextBox.Dock = [System.Windows.Forms.DockStyle]::Fill
$FolderTextBox.Margin = New-Object System.Windows.Forms.Padding(3, 4, 8, 3)
$FolderTextBox.AllowDrop = $true

$BrowseButton = New-Object System.Windows.Forms.Button
$BrowseButton.Text = "Browse... (Выбрать...)"
$BrowseButton.Dock = [System.Windows.Forms.DockStyle]::Fill
$BrowseButton.Margin = New-Object System.Windows.Forms.Padding(3, 1, 3, 3)

$StrictCheckBox = New-Object System.Windows.Forms.CheckBox
$StrictCheckBox.Text = "Strict mode (Строгий режим)"
$StrictCheckBox.AutoSize = $true
$StrictCheckBox.Checked = $false
$StrictCheckBox.Margin = New-Object System.Windows.Forms.Padding(3, 4, 20, 3)

$DirectoriesCheckBox = New-Object System.Windows.Forms.CheckBox
$DirectoriesCheckBox.Text = "Rename directories (Переименовывать каталоги)"
$DirectoriesCheckBox.AutoSize = $true
$DirectoriesCheckBox.Checked = $false
$DirectoriesCheckBox.Margin = New-Object System.Windows.Forms.Padding(3, 4, 3, 3)

$OptionsFlow = New-Object System.Windows.Forms.FlowLayoutPanel
$OptionsFlow.Dock = [System.Windows.Forms.DockStyle]::Fill
$OptionsFlow.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
$OptionsFlow.WrapContents = $false
[void]$OptionsFlow.Controls.Add($StrictCheckBox)
[void]$OptionsFlow.Controls.Add($DirectoriesCheckBox)

$ScanButton = New-Object System.Windows.Forms.Button
$ScanButton.Text = "Scan (Проверить)"
$ScanButton.Size = New-Object System.Drawing.Size(135, 32)
$ScanButton.Margin = New-Object System.Windows.Forms.Padding(3, 3, 8, 3)

$CancelScanButton = New-Object System.Windows.Forms.Button
$CancelScanButton.Text = "Cancel scan (Отменить проверку)"
$CancelScanButton.Size = New-Object System.Drawing.Size(205, 32)
$CancelScanButton.Margin = New-Object System.Windows.Forms.Padding(3, 3, 12, 3)
$CancelScanButton.Enabled = $false
$CancelScanButton.Visible = $false

$ScanProgressBar = New-Object System.Windows.Forms.ProgressBar
$ScanProgressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
$ScanProgressBar.MarqueeAnimationSpeed = 30
$ScanProgressBar.Size = New-Object System.Drawing.Size(190, 20)
$ScanProgressBar.Margin = New-Object System.Windows.Forms.Padding(3, 8, 3, 3)
$ScanProgressBar.Visible = $false

$ActionFlow = New-Object System.Windows.Forms.FlowLayoutPanel
$ActionFlow.Dock = [System.Windows.Forms.DockStyle]::Fill
$ActionFlow.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
$ActionFlow.WrapContents = $false
[void]$ActionFlow.Controls.Add($ScanButton)
[void]$ActionFlow.Controls.Add($CancelScanButton)
[void]$ActionFlow.Controls.Add($ScanProgressBar)

$ScanHintLabel = New-Object System.Windows.Forms.Label
$ScanHintLabel.Text = "Files are scanned recursively. (Файлы проверяются во всех вложенных каталогах.)"
$ScanHintLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
$ScanHintLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$ScanHintLabel.ForeColor = [System.Drawing.SystemColors]::GrayText

[void]$SettingsPanel.Controls.Add($FolderLabel, 0, 0)
[void]$SettingsPanel.Controls.Add($FolderTextBox, 1, 0)
[void]$SettingsPanel.Controls.Add($BrowseButton, 2, 0)
[void]$SettingsPanel.Controls.Add($OptionsFlow, 0, 1)
$SettingsPanel.SetColumnSpan($OptionsFlow, 3)
[void]$SettingsPanel.Controls.Add($ActionFlow, 0, 2)
$SettingsPanel.SetColumnSpan($ActionFlow, 3)
[void]$SettingsPanel.Controls.Add($ScanHintLabel, 0, 3)
$SettingsPanel.SetColumnSpan($ScanHintLabel, 3)

$ResultsHost = New-Object System.Windows.Forms.Panel
$ResultsHost.Dock = [System.Windows.Forms.DockStyle]::Fill

$ResultsGrid = New-Object System.Windows.Forms.DataGridView
$ResultsGrid.Dock = [System.Windows.Forms.DockStyle]::Fill
$ResultsGrid.Margin = New-Object System.Windows.Forms.Padding(3, 3, 3, 8)
$ResultsGrid.AllowUserToAddRows = $false
$ResultsGrid.AllowUserToDeleteRows = $false
$ResultsGrid.AllowUserToResizeRows = $false
$ResultsGrid.AutoGenerateColumns = $false
$ResultsGrid.VirtualMode = $true
$ResultsGrid.AutoSizeColumnsMode = `
    [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::Fill
$ResultsGrid.BackgroundColor = [System.Drawing.SystemColors]::Window
$ResultsGrid.BorderStyle = [System.Windows.Forms.BorderStyle]::Fixed3D
$ResultsGrid.MultiSelect = $false
$ResultsGrid.ReadOnly = $true
$ResultsGrid.RowHeadersVisible = $false
$ResultsGrid.SelectionMode = `
    [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
$ResultsGrid.ClipboardCopyMode = `
    [System.Windows.Forms.DataGridViewClipboardCopyMode]::EnableWithoutHeaderText
$ResultsGrid.ShowCellToolTips = $true

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

$EmptyStateLabel = New-Object System.Windows.Forms.Label
$EmptyStateLabel.Text = "No renames are required.`r`n(Переименование не требуется.)"
$EmptyStateLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
$EmptyStateLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$EmptyStateLabel.BackColor = [System.Drawing.SystemColors]::Window
$EmptyStateLabel.ForeColor = [System.Drawing.SystemColors]::GrayText
$EmptyStateLabel.Visible = $false

[void]$ResultsHost.Controls.Add($ResultsGrid)
[void]$ResultsHost.Controls.Add($EmptyStateLabel)

$FooterPanel = New-Object System.Windows.Forms.TableLayoutPanel
$FooterPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$FooterPanel.ColumnCount = 5
$FooterPanel.RowCount = 2
foreach ($Width in @(155, 285, 190, 135)) {
    [void]$FooterPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle(
        [System.Windows.Forms.SizeType]::Absolute,
        $Width
    )))
}
[void]$FooterPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle(
    [System.Windows.Forms.SizeType]::Percent,
    100
)))
[void]$FooterPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle(
    [System.Windows.Forms.SizeType]::Absolute,
    30
)))
[void]$FooterPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle(
    [System.Windows.Forms.SizeType]::Percent,
    100
)))

$CheckedLabel = New-Object System.Windows.Forms.Label
$CheckedLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
$CheckedLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft

$NeedRenameLabel = New-Object System.Windows.Forms.Label
$NeedRenameLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
$NeedRenameLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft

$RenamedLabel = New-Object System.Windows.Forms.Label
$RenamedLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
$RenamedLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft

$ErrorsLabel = New-Object System.Windows.Forms.Label
$ErrorsLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
$ErrorsLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft

$ElapsedLabel = New-Object System.Windows.Forms.Label
$ElapsedLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
$ElapsedLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft

$ApplyButton = New-Object System.Windows.Forms.Button
$ApplyButton.Text = "Apply changes (Применить изменения)"
$ApplyButton.Size = New-Object System.Drawing.Size(190, 34)
$ApplyButton.Anchor = [System.Windows.Forms.AnchorStyles]::Right
$ApplyButton.Enabled = $false

[void]$FooterPanel.Controls.Add($CheckedLabel, 0, 0)
[void]$FooterPanel.Controls.Add($NeedRenameLabel, 1, 0)
[void]$FooterPanel.Controls.Add($RenamedLabel, 2, 0)
[void]$FooterPanel.Controls.Add($ErrorsLabel, 3, 0)
[void]$FooterPanel.Controls.Add($ElapsedLabel, 4, 0)
[void]$FooterPanel.Controls.Add($ApplyButton, 4, 1)

$StatusStrip = New-Object System.Windows.Forms.StatusStrip
$StatusStrip.Dock = [System.Windows.Forms.DockStyle]::Fill
$StatusStrip.SizingGrip = $false
$StatusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
$StatusLabel.Spring = $true
$StatusLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
[void]$StatusStrip.Items.Add($StatusLabel)

[void]$Layout.Controls.Add($HeaderLabel, 0, 0)
[void]$Layout.Controls.Add($SettingsPanel, 0, 1)
[void]$Layout.Controls.Add($ResultsHost, 0, 2)
[void]$Layout.Controls.Add($FooterPanel, 0, 3)
[void]$Layout.Controls.Add($StatusStrip, 0, 4)
[void]$Form.Controls.Add($Layout)

$script:ScannedPath = $null
$script:ScannedStrict = $false
$script:ScannedIncludeDirectories = $false
$script:ScannedPlanSignature = $null
$script:PlanCanApply = $false
$script:IsBusy = $false
$script:IsScanning = $false
$script:GridRecords = [object[]]@()
$script:ActiveScanOperation = $null
$script:ScanStopwatch = New-Object System.Diagnostics.Stopwatch

function Reset-Summary {
    $CheckedLabel.Text = "Checked (Проверено): 0"
    $NeedRenameLabel.Text = "Need renaming (Требуют переименования): 0"
    $RenamedLabel.Text = "Renamed (Переименовано): 0"
    $ErrorsLabel.Text = "Errors (Ошибок): 0"
    $ElapsedLabel.Text = "Elapsed (Прошло): 00:00:00"
}

function Clear-ResultGrid {
    $script:GridRecords = [object[]]@()
    $ResultsGrid.RowCount = 0
    $EmptyStateLabel.Visible = $false
}

function Clear-CurrentPlan {
    $script:ScannedPath = $null
    $script:ScannedStrict = $false
    $script:ScannedIncludeDirectories = $false
    $script:ScannedPlanSignature = $null
    $script:PlanCanApply = $false
    $ApplyButton.Enabled = $false
    Clear-ResultGrid
    Reset-Summary
}

function Invalidate-CurrentPlan {
    if ($script:IsBusy) {
        return
    }

    $HadPlan = -not [string]::IsNullOrEmpty($script:ScannedPath)
    Clear-CurrentPlan

    if ($HadPlan) {
        $StatusLabel.Text = "Plan invalidated — run Scan again. (План недействителен — повторите проверку.)"
    }
}

function Set-BusyState {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Busy,

        [switch]$Scanning
    )

    $script:IsBusy = $Busy
    $script:IsScanning = ($Busy -and $Scanning)
    $FolderTextBox.Enabled = -not $Busy
    $BrowseButton.Enabled = -not $Busy
    $StrictCheckBox.Enabled = -not $Busy
    $DirectoriesCheckBox.Enabled = -not $Busy
    $ScanButton.Enabled = -not $Busy
    $CancelScanButton.Visible = $script:IsScanning
    $CancelScanButton.Enabled = $script:IsScanning
    $ScanProgressBar.Visible = $Busy

    if ($Busy) {
        $ApplyButton.Enabled = $false
        $Form.UseWaitCursor = -not $script:IsScanning
        $Form.Cursor = if ($script:IsScanning) {
            [System.Windows.Forms.Cursors]::Default
        }
        else {
            [System.Windows.Forms.Cursors]::WaitCursor
        }
    }
    else {
        $ApplyButton.Enabled = $script:PlanCanApply
        $Form.UseWaitCursor = $false
        $Form.Cursor = [System.Windows.Forms.Cursors]::Default
    }

    $Form.Refresh()
}

function Format-ElapsedTime {
    param(
        [Parameter(Mandatory = $true)]
        [TimeSpan]$Elapsed
    )

    return "{0:00}:{1:00}:{2:00}" -f `
        [int]$Elapsed.TotalHours,
        $Elapsed.Minutes,
        $Elapsed.Seconds
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

    # VirtualMode makes population O(1): DataGridView asks for visible cell values
    # instead of allocating a DataGridViewRow for every planned rename.
    # (VirtualMode делает заполнение O(1): DataGridView запрашивает значения только
    # видимых ячеек вместо создания DataGridViewRow для каждого переименования.)
    $script:GridRecords = [object[]]@(
        $Result.Records | Where-Object { $_.NeedsRename }
    )
    $ResultsGrid.RowCount = $script:GridRecords.Count
    $ResultsGrid.Invalidate()

    $EmptyStateLabel.Visible = ($Result.NeedRename -eq 0)

    if ($EmptyStateLabel.Visible) {
        $EmptyStateLabel.BringToFront()
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

function Get-SelectedGridRecord {
    if ($ResultsGrid.CurrentCell -eq $null) {
        return $null
    }

    $RowIndex = $ResultsGrid.CurrentCell.RowIndex

    if ($RowIndex -lt 0 -or $RowIndex -ge $script:GridRecords.Count) {
        return $null
    }

    return $script:GridRecords[$RowIndex]
}

function Copy-GridValue {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("Before", "After", "Path")]
        [string]$ValueKind
    )

    $Record = Get-SelectedGridRecord

    if ($null -eq $Record) {
        return
    }

    switch ($ValueKind) {
        "Before" { $Value = [string]$Record.OriginalName }
        "After"  { $Value = [string]$Record.NewName }
        "Path"   { $Value = [string]$Record.OriginalFullName }
    }

    try {
        [System.Windows.Forms.Clipboard]::SetText($Value)
        $StatusLabel.Text = "Copied to clipboard. (Скопировано в буфер обмена.)"
    }
    catch {
        [void](Show-GuiMessage `
            -Text "The value could not be copied.`r`n(Не удалось скопировать значение.)`r`n`r`n$($_.Exception.Message)" `
            -Icon ([System.Windows.Forms.MessageBoxIcon]::Warning))
    }
}

function Set-DroppedFolder {
    param(
        [Parameter(Mandatory = $true)]
        [System.Windows.Forms.DragEventArgs]$EventArgs
    )

    if ($script:IsBusy -or
        -not $EventArgs.Data.GetDataPresent(
            [System.Windows.Forms.DataFormats]::FileDrop
        )) {
        return
    }

    $Paths = [string[]]$EventArgs.Data.GetData(
        [System.Windows.Forms.DataFormats]::FileDrop
    )

    if ($Paths.Count -ne 1 -or
        -not (Test-Path -LiteralPath $Paths[0] -PathType Container)) {
        [void](Show-GuiMessage `
            -Text "Drop one folder only.`r`n(Перетащите только одну папку.)" `
            -Icon ([System.Windows.Forms.MessageBoxIcon]::Warning))
        return
    }

    $FolderTextBox.Text = (Resolve-Path -LiteralPath $Paths[0]).Path
}

function Complete-BackgroundScan {
    $ScanTimer.Stop()
    $script:ScanStopwatch.Stop()
    $Operation = $script:ActiveScanOperation
    $script:ActiveScanOperation = $null
    $WasCancelled = ($null -ne $Operation -and $Operation.CancelRequested)

    try {
        if ($null -eq $Operation) {
            return
        }

        $Result = Complete-CleanFileNamesCore -Operation $Operation

        if ($WasCancelled) {
            Clear-CurrentPlan
            $StatusLabel.Text = "Cancelled. (Проверка отменена.)"
            return
        }

        Show-StructuredResult -Result $Result
        Save-ScannedSettings -Path $Operation.Path -Result $Result

        if ($Result.Errors -gt 0) {
            $StatusLabel.Text = "Scan completed with errors. (Проверка завершена с ошибками.)"
            [void](Show-GuiMessage `
                -Text "Scanning completed with errors.`r`n(Проверка завершена с ошибками.)`r`n`r`nErrors (Ошибок): $($Result.Errors)" `
                -Icon ([System.Windows.Forms.MessageBoxIcon]::Warning))
        }
        elseif ($Result.NeedRename -eq 0) {
            $StatusLabel.Text = "No renames are required. (Переименование не требуется.)"
        }
        else {
            $StatusLabel.Text = "Scan completed. (Проверка завершена.)"
        }
    }
    catch {
        Clear-CurrentPlan

        if ($WasCancelled -or
            $_.Exception -is [System.Management.Automation.PipelineStoppedException]) {
            $StatusLabel.Text = "Cancelled. (Проверка отменена.)"
        }
        else {
            $StatusLabel.Text = "Scan failed. (Проверка завершилась ошибкой.)"
            [void](Show-GuiMessage `
                -Text "An error occurred while scanning.`r`n(Во время проверки произошла ошибка.)`r`n`r`n$($_.Exception.Message)" `
                -Icon ([System.Windows.Forms.MessageBoxIcon]::Error))
        }
    }
    finally {
        $ElapsedText = Format-ElapsedTime -Elapsed $script:ScanStopwatch.Elapsed
        $ElapsedLabel.Text = "Elapsed (Прошло): $ElapsedText"
        Set-BusyState -Busy $false
    }
}

function Start-BackgroundScan {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    Clear-CurrentPlan
    Set-BusyState -Busy $true -Scanning
    $StatusLabel.Text = "Scanning... (Выполняется проверка...)"
    $script:ScanStopwatch.Restart()

    try {
        $Operation = Start-CleanFileNamesCore `
            -Path $Path `
            -Strict:$StrictCheckBox.Checked `
            -IncludeDirectories:$DirectoriesCheckBox.Checked
        $Operation | Add-Member -NotePropertyName Path -NotePropertyValue $Path
        $script:ActiveScanOperation = $Operation
        $ScanTimer.Start()
    }
    catch {
        $script:ScanStopwatch.Stop()
        $script:ActiveScanOperation = $null
        Clear-CurrentPlan
        $StatusLabel.Text = "Scan failed. (Проверка завершилась ошибкой.)"
        Set-BusyState -Busy $false
        [void](Show-GuiMessage `
            -Text "The background scan could not be started.`r`n(Не удалось запустить фоновую проверку.)`r`n`r`n$($_.Exception.Message)" `
            -Icon ([System.Windows.Forms.MessageBoxIcon]::Error))
    }
}

function Request-ScanCancellation {
    if (-not $script:IsScanning -or
        $null -eq $script:ActiveScanOperation -or
        $script:ActiveScanOperation.CancelRequested) {
        return
    }

    $script:ActiveScanOperation.CancelRequested = $true
    $CancelScanButton.Enabled = $false
    $StatusLabel.Text = "Cancelling scan... (Отмена проверки...)"

    try {
        # BeginStop requests cooperative pipeline cancellation without blocking
        # the UI thread. Completion is collected by the regular polling timer.
        # (BeginStop запрашивает кооперативную отмену pipeline без блокировки UI
        # thread. Завершение обрабатывает обычный polling timer.)
        $script:ActiveScanOperation.StopAsyncResult = `
            $script:ActiveScanOperation.PowerShell.BeginStop($null, $null)
    }
    catch {
        Clear-CurrentPlan
        $StatusLabel.Text = "Cancellation failed. (Не удалось отменить проверку.)"
        [void](Show-GuiMessage `
            -Text "The scan could not be cancelled safely.`r`n(Не удалось безопасно отменить проверку.)`r`n`r`n$($_.Exception.Message)" `
            -Icon ([System.Windows.Forms.MessageBoxIcon]::Warning))
    }
}

$ScanTimer = New-Object System.Windows.Forms.Timer
$ScanTimer.Interval = 100
$ScanTimer.Add_Tick({
    $ElapsedText = Format-ElapsedTime -Elapsed $script:ScanStopwatch.Elapsed
    $ElapsedLabel.Text = "Elapsed (Прошло): $ElapsedText"

    if ($null -ne $script:ActiveScanOperation -and
        $script:ActiveScanOperation.AsyncResult.IsCompleted -and
        ($null -eq $script:ActiveScanOperation.StopAsyncResult -or
            $script:ActiveScanOperation.StopAsyncResult.IsCompleted)) {
        Complete-BackgroundScan
    }
})

$ResultsGrid.Add_CellValueNeeded({
    param($Sender, $EventArgs)

    if ($EventArgs.RowIndex -lt 0 -or
        $EventArgs.RowIndex -ge $script:GridRecords.Count) {
        return
    }

    $Record = $script:GridRecords[$EventArgs.RowIndex]

    switch ($EventArgs.ColumnIndex) {
        0 {
            $EventArgs.Value = if ($Record.ItemType -eq "Directory") {
                "Directory (Каталог)"
            }
            else {
                "File (Файл)"
            }
        }
        1 { $EventArgs.Value = $Record.OriginalName }
        2 { $EventArgs.Value = $Record.NewName }
        3 { $EventArgs.Value = $Record.Location }
    }
})

$ResultsGrid.Add_CellToolTipTextNeeded({
    param($Sender, $EventArgs)

    if ($EventArgs.RowIndex -ge 0 -and
        $EventArgs.RowIndex -lt $script:GridRecords.Count -and
        $EventArgs.ColumnIndex -ge 0) {
        $Record = $script:GridRecords[$EventArgs.RowIndex]

        switch ($EventArgs.ColumnIndex) {
            0 { $EventArgs.ToolTipText = [string]$Record.ItemType }
            1 { $EventArgs.ToolTipText = [string]$Record.OriginalName }
            2 { $EventArgs.ToolTipText = [string]$Record.NewName }
            3 { $EventArgs.ToolTipText = [string]$Record.Location }
        }
    }
})

$GridContextMenu = New-Object System.Windows.Forms.ContextMenuStrip
$CopyBeforeItem = $GridContextMenu.Items.Add("Copy Before (Копировать исходное имя)")
$CopyAfterItem = $GridContextMenu.Items.Add("Copy After (Копировать новое имя)")
$CopyPathItem = $GridContextMenu.Items.Add("Copy path (Копировать путь)")
$CopyBeforeItem.Add_Click({ Copy-GridValue -ValueKind Before })
$CopyAfterItem.Add_Click({ Copy-GridValue -ValueKind After })
$CopyPathItem.Add_Click({ Copy-GridValue -ValueKind Path })
$ResultsGrid.ContextMenuStrip = $GridContextMenu
$ResultsGrid.Add_CellMouseDown({
    param($Sender, $EventArgs)

    if ($EventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Right -and
        $EventArgs.RowIndex -ge 0) {
        $ResultsGrid.CurrentCell = $ResultsGrid.Rows[$EventArgs.RowIndex].Cells[
            [Math]::Max(0, $EventArgs.ColumnIndex)
        ]
    }
})

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

$FolderDragEnterHandler = {
    param($Sender, $EventArgs)

    if (-not $script:IsBusy -and
        $EventArgs.Data.GetDataPresent(
            [System.Windows.Forms.DataFormats]::FileDrop
        )) {
        $EventArgs.Effect = [System.Windows.Forms.DragDropEffects]::Copy
    }
    else {
        $EventArgs.Effect = [System.Windows.Forms.DragDropEffects]::None
    }
}
$FolderDragDropHandler = {
    param($Sender, $EventArgs)
    Set-DroppedFolder -EventArgs $EventArgs
}
$Form.Add_DragEnter($FolderDragEnterHandler)
$Form.Add_DragDrop($FolderDragDropHandler)
$FolderTextBox.Add_DragEnter($FolderDragEnterHandler)
$FolderTextBox.Add_DragDrop($FolderDragDropHandler)

$FolderTextBox.Add_TextChanged({ Invalidate-CurrentPlan })
$StrictCheckBox.Add_CheckedChanged({ Invalidate-CurrentPlan })
$DirectoriesCheckBox.Add_CheckedChanged({ Invalidate-CurrentPlan })

$ScanButton.Add_Click({
    $SelectedPath = Resolve-SelectedFolder

    if ([string]::IsNullOrEmpty($SelectedPath)) {
        return
    }

    Start-BackgroundScan -Path $SelectedPath
})

$CancelScanButton.Add_Click({ Request-ScanCancellation })

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
    $StatusLabel.Text = "Applying... (Применение изменений...)"
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
            $StatusLabel.Text = "Completed with errors. (Завершено с ошибками.)"
        }
        else {
            $CompletionText = "Renaming completed.`r`n(Переименование завершено.)"
            $CompletionIcon = [System.Windows.Forms.MessageBoxIcon]::Information
            $StatusLabel.Text = "Completed. (Завершено.)"
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

$Form.Add_KeyDown({
    param($Sender, $EventArgs)

    if ($EventArgs.Control -and $EventArgs.KeyCode -eq "O") {
        if ($BrowseButton.Enabled) {
            $BrowseButton.PerformClick()
        }

        $EventArgs.SuppressKeyPress = $true
    }
    elseif ($EventArgs.KeyCode -eq [System.Windows.Forms.Keys]::F5) {
        if ($ScanButton.Enabled) {
            $ScanButton.PerformClick()
        }

        $EventArgs.SuppressKeyPress = $true
    }
    elseif ($EventArgs.KeyCode -eq [System.Windows.Forms.Keys]::Escape -and
        $script:IsScanning) {
        Request-ScanCancellation
        $EventArgs.SuppressKeyPress = $true
    }
})

$Form.Add_FormClosing({
    if ($null -ne $script:ActiveScanOperation) {
        $ScanTimer.Stop()

        try {
            $script:ActiveScanOperation.PowerShell.Stop()
        }
        catch {
        }
        finally {
            $script:ActiveScanOperation.PowerShell.Dispose()
            $script:ActiveScanOperation = $null
        }
    }

    $ScanTimer.Dispose()
    $GridContextMenu.Dispose()
})

Reset-Summary
$StatusLabel.Text = "Ready — select a folder and run Scan. (Готово — выберите папку и запустите проверку.)"
$Form.Add_Shown({ [void]$FolderTextBox.Focus() })

# Dot-sourcing initializes the form without opening it, which allows safe local
# UI regression tests. Normal -File execution opens the application window.
# (При dot-sourcing форма инициализируется без открытия, что позволяет выполнять
# безопасные локальные UI regression tests. Обычный запуск через -File открывает окно.)
# TODO: Packaged EXE launch behavior must be explicitly regression-tested after
# a PS2EXE build because PS2EXE changes $MyInvocation semantics.
# (TODO: после сборки PS2EXE нужно явно проверить запуск packaged EXE, поскольку
# PS2EXE изменяет семантику $MyInvocation.)
if ($MyInvocation.InvocationName -ne ".") {
    [System.Windows.Forms.Application]::Run($Form)
}
