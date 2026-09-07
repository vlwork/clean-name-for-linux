param(
    [string]$ReferenceCommit = "255095f"
)

$ErrorActionPreference = "Stop"
$RepositoryRoot = Split-Path -Parent $PSScriptRoot
$GuiScriptPath = Join-Path $RepositoryRoot "Clean-FileNames-GUI.ps1"
$CoreScriptPath = Join-Path $RepositoryRoot "Clean-FileNames.ps1"
$FixtureRoot = Join-Path `
    ([System.IO.Path]::GetTempPath()) `
    ("CleanFileNames-Regression-{0}" -f [guid]::NewGuid().ToString("N"))
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false, $true)
$EmptyBytes = New-Object byte[] 0
$Passed = 0
$Failed = 0
$Failures = New-Object System.Collections.Generic.List[string]

# Self-contained Windows PowerShell 5.1 regression runner. All filesystem data
# is generated below a unique TEMP root and removed in finally.
# (Самодостаточный regression runner для Windows PowerShell 5.1. Все данные
# создаются в уникальном TEMP-каталоге и удаляются в finally.)

function Add-TestResult {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [bool]$Condition,

        [string]$Details = ""
    )

    if ($Condition) {
        $script:Passed++
        Write-Host "PASS  $Name" -ForegroundColor Green
    }
    else {
        $script:Failed++
        $Message = if ([string]::IsNullOrEmpty($Details)) {
            $Name
        }
        else {
            "$Name — $Details"
        }
        $script:Failures.Add($Message)
        Write-Host "FAIL  $Message" -ForegroundColor Red
    }
}

function New-TestDirectory {
    param([string]$Name)
    $Path = Join-Path $FixtureRoot $Name
    [void][System.IO.Directory]::CreateDirectory($Path)
    return $Path
}

function New-TestFile {
    param(
        [string]$Directory,
        [string]$Name
    )
    [System.IO.File]::WriteAllBytes((Join-Path $Directory $Name), $EmptyBytes)
}

function Invoke-WithCoreText {
    param(
        [string]$Text,
        [string]$Path,
        [switch]$Apply,
        [switch]$Strict,
        [switch]$IncludeDirectories
    )

    $SavedCoreText = $script:CoreText

    try {
        $script:CoreText = $Text
        return Invoke-CleanFileNamesCore `
            -Path $Path `
            -Apply:$Apply `
            -Strict:$Strict `
            -IncludeDirectories:$IncludeDirectories
    }
    finally {
        $script:CoreText = $SavedCoreText
    }
}

function Wait-ForBackgroundScan {
    param([int]$TimeoutSeconds = 30)
    $Deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)

    while ($null -ne $script:ActiveScanOperation -and
        [DateTime]::UtcNow -lt $Deadline) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 10
    }

    return ($null -eq $script:ActiveScanOperation)
}

function Invoke-ProbeScript {
    param([string]$Text)
    $Path = Join-Path $FixtureRoot ("probe-{0}.ps1" -f [guid]::NewGuid().ToString("N"))
    [System.IO.File]::WriteAllText($Path, $Text, $Utf8NoBom)
    $SavedErrorActionPreference = $ErrorActionPreference

    try {
        # Native stderr from an expected negative probe must be captured as data,
        # not promoted to a terminating error by this runner's Stop preference.
        # (Native stderr ожидаемого negative probe захватываем как данные, а не
        # превращаем в terminating error из-за Stop preference runner-а.)
        $ErrorActionPreference = "Continue"
        $Output = @(
            & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
                -NoProfile `
                -Sta `
                -ExecutionPolicy Bypass `
                -File $Path 2>&1
        )
        $ExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $SavedErrorActionPreference
    }

    return [pscustomobject]@{
        ExitCode = $ExitCode
        Output   = ($Output -join [Environment]::NewLine)
    }
}

function ConvertFrom-CanonicalUtf8Bytes {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Bytes
    )

    $Offset = 0

    if ($Bytes.Length -ge 3 -and
        $Bytes[0] -eq 0xEF -and
        $Bytes[1] -eq 0xBB -and
        $Bytes[2] -eq 0xBF) {
        $Offset = 3
    }

    return $Utf8NoBom.GetString($Bytes, $Offset, $Bytes.Length - $Offset)
}

function Invoke-GitProcess {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Arguments,

        [string]$BinaryOutputPath
    )

    $StartInfo = New-Object System.Diagnostics.ProcessStartInfo
    $StartInfo.FileName = "git.exe"
    $StartInfo.Arguments = $Arguments
    $StartInfo.WorkingDirectory = $RepositoryRoot
    $StartInfo.UseShellExecute = $false
    $StartInfo.CreateNoWindow = $true
    $StartInfo.RedirectStandardOutput = $true
    $StartInfo.RedirectStandardError = $true
    $Process = New-Object System.Diagnostics.Process
    $Process.StartInfo = $StartInfo

    try {
        if (-not $Process.Start()) {
            throw "Git process could not be started. (Не удалось запустить процесс Git.)"
        }

        if ([string]::IsNullOrEmpty($BinaryOutputPath)) {
            $StandardOutput = $Process.StandardOutput.ReadToEnd()
        }
        else {
            $OutputStream = New-Object System.IO.FileStream(
                $BinaryOutputPath,
                [System.IO.FileMode]::Create,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::None
            )

            try {
                # Copy raw stdout bytes directly. Do not pass a Git blob through
                # Windows PowerShell native-output text decoding.
                # (Копируем raw stdout bytes напрямую. Не пропускаем Git blob через
                # text decoding native output в Windows PowerShell.)
                $Process.StandardOutput.BaseStream.CopyTo($OutputStream)
            }
            finally {
                $OutputStream.Dispose()
            }

            $StandardOutput = ""
        }

        $StandardError = $Process.StandardError.ReadToEnd()
        $Process.WaitForExit()

        return [pscustomobject]@{
            ExitCode       = $Process.ExitCode
            StandardOutput = $StandardOutput
            StandardError  = $StandardError
        }
    }
    finally {
        $Process.Dispose()
    }
}

function Get-ReferenceCoreText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Commit
    )

    $CommitCheck = Invoke-GitProcess `
        -Arguments ("rev-parse --verify `"{0}^{{commit}}`"" -f $Commit)

    if ($CommitCheck.ExitCode -ne 0) {
        throw "Reference commit could not be resolved (Не удалось определить reference commit): $Commit`r`n$($CommitCheck.StandardError)"
    }

    $BlobSpecification = "$Commit`:Clean-FileNames.ps1"
    $BlobCheck = Invoke-GitProcess `
        -Arguments ("cat-file -e `"{0}`"" -f $BlobSpecification)

    if ($BlobCheck.ExitCode -ne 0) {
        throw "Reference core blob was not found (Reference core blob не найден): $BlobSpecification`r`n$($BlobCheck.StandardError)"
    }

    $BlobPath = Join-Path $FixtureRoot "reference-Clean-FileNames.ps1"
    $BlobRead = Invoke-GitProcess `
        -Arguments ("cat-file blob `"{0}`"" -f $BlobSpecification) `
        -BinaryOutputPath $BlobPath

    if ($BlobRead.ExitCode -ne 0) {
        throw "Reference core blob could not be read (Не удалось прочитать reference core blob): $BlobSpecification`r`n$($BlobRead.StandardError)"
    }

    $BlobBytes = [System.IO.File]::ReadAllBytes($BlobPath)

    if ($BlobBytes.Length -eq 0) {
        throw "Reference core blob is empty. (Reference core blob пуст.)"
    }

    return ConvertFrom-CanonicalUtf8Bytes -Bytes $BlobBytes
}

function Get-ProbePayload {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Probe
    )

    $MarkerPrefix = "CFN_PROBE_V1:"
    $MarkerLine = @(
        $Probe.Output -split '\r?\n' |
            Where-Object { $_.StartsWith($MarkerPrefix, [StringComparison]::Ordinal) }
    )

    if ($MarkerLine.Count -ne 1) {
        return $null
    }

    try {
        $PayloadBytes = [Convert]::FromBase64String(
            $MarkerLine[0].Substring($MarkerPrefix.Length)
        )
        $PayloadJson = $Utf8NoBom.GetString($PayloadBytes)
        return $PayloadJson | ConvertFrom-Json
    }
    catch {
        return $null
    }
}

function Get-TextSha256 {
    param([string]$Text)
    $Algorithm = [System.Security.Cryptography.SHA256]::Create()

    try {
        return [BitConverter]::ToString(
            $Algorithm.ComputeHash($Utf8NoBom.GetBytes($Text))
        ).Replace("-", "")
    }
    finally {
        $Algorithm.Dispose()
    }
}

function Add-ExpectedDiagnosticResult {
    param(
        [string]$Name,
        [object]$Probe,
        [string]$English,
        [string]$Russian
    )

    $Matches = (
        $Probe.ExitCode -ne 0 -and
        $Probe.Output.Contains($English) -and
        $Probe.Output.Contains($Russian)
    )
    Add-TestResult $Name $Matches (
        "ExitCode={0}; English={1}; Russian={2}" -f
            $Probe.ExitCode,
            $Probe.Output.Contains($English),
            $Probe.Output.Contains($Russian)
    )
}

try {
    [void][System.IO.Directory]::CreateDirectory($FixtureRoot)
    . $GuiScriptPath
    $CurrentCoreText = $script:CoreText
    $ReferenceCoreText = Get-ReferenceCoreText -Commit $ReferenceCommit

    # Normal, extension, dotfile, Unicode, emoji, ZWJ/ZWNJ and fullwidth cases.
    # (Normal, extension, dotfile, Unicode, emoji, ZWJ/ZWNJ и fullwidth cases.)
    $NormalPath = New-TestDirectory "normal"
    New-TestFile $NormalPath "file.foo--bar"
    New-TestFile $NormalPath "file.t(`$)!x"
    New-TestFile $NormalPath ".profile"
    New-TestFile $NormalPath ".config  .json"
    New-TestFile $NormalPath ("nfc-{0}{1}.txt" -f [char]0x0438, [char]0x0306)
    New-TestFile $NormalPath ("emoji-{0}.txt" -f [char]::ConvertFromUtf32(0x1F600))
    New-TestFile $NormalPath ("zwj-a{0}b.txt" -f [char]0x200D)
    New-TestFile $NormalPath ("zwnj-a{0}b.txt" -f [char]0x200C)
    New-TestFile $NormalPath ("fullwidth-a{0}b.txt" -f [char]0xFF1A)
    $BigSolidus = ([char]0x29F8).ToString()
    $BigSolidusNormalName = "К4${BigSolidus}16.mp4"
    $BigSolidusRepeatedName = "1${BigSolidus}2${BigSolidus}3.txt"
    New-TestFile $NormalPath $BigSolidusNormalName
    New-TestFile $NormalPath $BigSolidusRepeatedName
    $Normal = Invoke-WithCoreText $CurrentCoreText $NormalPath
    $NormalMap = @{}
    foreach ($Record in $Normal.Records) {
        $NormalMap[$Record.OriginalName] = $Record.NewName
    }
    Add-TestResult "Normal preserves file.foo--bar" (-not $NormalMap.ContainsKey("file.foo--bar"))
    Add-TestResult "Normal preserves extension metacharacters" (-not $NormalMap.ContainsKey("file.t(`$)!x"))
    Add-TestResult "Simple dotfile remains unchanged" (-not $NormalMap.ContainsKey(".profile"))
    Add-TestResult "Dotfile extension normalization" ($NormalMap[".config  .json"] -eq ".config.json")
    Add-TestResult "Unicode NFC" ($Normal.Records.NewName -contains "nfc-й.txt")
    Add-TestResult "Emoji preserved" (-not ($Normal.Records.OriginalName -like "emoji-*").Count)
    Add-TestResult "ZWJ preserved" (-not ($Normal.Records.OriginalName -like "zwj-*").Count)
    Add-TestResult "ZWNJ preserved" (-not ($Normal.Records.OriginalName -like "zwnj-*").Count)
    Add-TestResult "Fullwidth forbidden character normalized" ($NormalMap.Count -gt 0 -and $NormalMap.Keys.Where({ $_ -like "fullwidth-*" }).Count -eq 1)
    Add-TestResult "Normal BIG SOLIDUS separator" ($NormalMap[$BigSolidusNormalName] -eq "К4 - 16.mp4") $NormalMap[$BigSolidusNormalName]
    Add-TestResult "Normal repeated BIG SOLIDUS separators" ($NormalMap[$BigSolidusRepeatedName] -eq "1 - 2 - 3.txt") $NormalMap[$BigSolidusRepeatedName]

    $StrictPath = New-TestDirectory "strict"
    foreach ($Name in @(
        "file.foo--bar",
        "file.t(`$)!x",
        "file.a!!b",
        "file.a--!!--b",
        "file.t;xt",
        "file.t&xt",
        $BigSolidusNormalName
    )) {
        New-TestFile $StrictPath $Name
    }
    $StrictResult = Invoke-WithCoreText $CurrentCoreText $StrictPath -Strict
    $StrictMap = @{}
    foreach ($Record in $StrictResult.Records) {
        $StrictMap[$Record.OriginalName] = $Record.NewName
    }
    Add-TestResult "Strict preserves original double hyphen" (-not $StrictMap.ContainsKey("file.foo--bar"))
    Add-TestResult "Strict extension group replacement" ($StrictMap["file.t(`$)!x"] -eq "file.t-x")
    Add-TestResult "Strict repeated metacharacters" ($StrictMap["file.a!!b"] -eq "file.a-b")
    Add-TestResult "Strict does not globally collapse hyphens" ($StrictMap["file.a--!!--b"] -eq "file.a-----b") $StrictMap["file.a--!!--b"]
    Add-TestResult "Strict semicolon" ($StrictMap["file.t;xt"] -eq "file.t-xt")
    Add-TestResult "Strict ampersand" ($StrictMap["file.t&xt"] -eq "file.t+xt")
    Add-TestResult "Strict BIG SOLIDUS uses Normal cleanup" ($StrictMap[$BigSolidusNormalName] -eq "К4 - 16.mp4") $StrictMap[$BigSolidusNormalName]

    # Collision sequence verifies suffix transitions 1, 10, and 100.
    # (Последовательность конфликтов проверяет переходы суффиксов 1, 10 и 100.)
    $CollisionPath = New-TestDirectory "collisions"
    New-TestFile $CollisionPath "target.txt"
    for ($Index = 1; $Index -le 100; $Index++) {
        New-TestFile $CollisionPath ("target ({0}).txt" -f $Index)
    }
    New-TestFile $CollisionPath "target  .txt"
    $CollisionResult = Invoke-WithCoreText $CurrentCoreText $CollisionPath
    $CollisionRecord = @($CollisionResult.Records | Where-Object OriginalName -eq "target  .txt")[0]
    Add-TestResult "Collision suffix 1/10/100" ($CollisionRecord.NewName -eq "target (101).txt") $CollisionRecord.NewName

    $LongPath = New-TestDirectory "long-utf8"
    $LongName = (([char]0x044F).ToString() * 140) + ".txt"
    New-TestFile $LongPath $LongName
    $LongResult = Invoke-WithCoreText $CurrentCoreText $LongPath
    $LongTarget = [string]$LongResult.Records[0].NewName
    $LongBytes = [System.Text.Encoding]::UTF8.GetByteCount($LongTarget)
    Add-TestResult "255 UTF-8 byte limit" ($LongBytes -le 255 -and $LongTarget.EndsWith(".txt")) "$LongBytes bytes"

    $DirectoryPath = New-TestDirectory "directories"
    $DirtyDirectory = [System.IO.Directory]::CreateDirectory(
        (Join-Path $DirectoryPath "parent  folder")
    )
    New-TestFile $DirtyDirectory.FullName "child  file.txt"
    $DirectoryResult = Invoke-WithCoreText $CurrentCoreText $DirectoryPath -IncludeDirectories
    Add-TestResult "Directory rename included" (@($DirectoryResult.Records | Where-Object ItemType -eq "Directory").Count -eq 1)
    Add-TestResult "Nested file planned under renamed directory" (@($DirectoryResult.Records | Where-Object { $_.PlannedRelativePath -eq "parent folder\child file.txt" }).Count -eq 1)

    $ApplyPath = New-TestDirectory "dry-apply"
    New-TestFile $ApplyPath "apply  one.txt"
    New-TestFile $ApplyPath "apply  two.txt"
    $DryResult = Invoke-WithCoreText $CurrentCoreText $ApplyPath
    $DrySignature = Get-PlanSignature $DryResult
    $ApplyResult = Invoke-WithCoreText $CurrentCoreText $ApplyPath -Apply
    $ApplySignature = Get-PlanSignature $ApplyResult
    $AfterApply = Invoke-WithCoreText $CurrentCoreText $ApplyPath
    Add-TestResult "Dry Run equals Apply plan" ([string]::Equals($DrySignature, $ApplySignature, [StringComparison]::Ordinal))
    Add-TestResult "Apply performed planned renames" ($ApplyResult.Renamed -eq 2 -and $AfterApply.NeedRename -eq 0)

    $RevalidationPath = New-TestDirectory "revalidation"
    New-TestFile $RevalidationPath "first  item.txt"
    $InitialPlan = Invoke-WithCoreText $CurrentCoreText $RevalidationPath
    $InitialSignature = Get-PlanSignature $InitialPlan
    New-TestFile $RevalidationPath "second  item.txt"
    $ChangedSignature = Get-PlanSignature (Invoke-WithCoreText $CurrentCoreText $RevalidationPath)
    Add-TestResult "Plan revalidation detects filesystem change" (-not [string]::Equals($InitialSignature, $ChangedSignature, [StringComparison]::Ordinal))

    # 150 deterministic generated names provide old/new semantic coverage beyond
    # the named edge cases without relying on invalid Windows path syntax.
    # (150 детерминированных имён расширяют old/new semantic coverage без
    # использования недопустимого Windows path syntax.)
    $CorpusPath = New-TestDirectory "equivalence-corpus"
    $Random = New-Object System.Random 20260907
    $Tokens = @("a", "Z", "я", "й", "é", "中", "-", "_", " ", "  ", "(", ")", "&", "!", ([char]::ConvertFromUtf32(0x1F600)))
    for ($Index = 0; $Index -lt 150; $Index++) {
        $Builder = New-Object System.Text.StringBuilder
        [void]$Builder.Append(("case-{0:D3}-" -f $Index))
        for ($TokenIndex = 0; $TokenIndex -lt 12; $TokenIndex++) {
            [void]$Builder.Append($Tokens[$Random.Next(0, $Tokens.Count)])
        }
        [void]$Builder.Append(".txt")
        New-TestFile $CorpusPath $Builder.ToString()
    }
    $CurrentNormalPlan = Get-PlanSignature (
        Invoke-WithCoreText $CurrentCoreText $CorpusPath
    )
    $ReferenceNormalPlan = Get-PlanSignature (
        Invoke-WithCoreText $ReferenceCoreText $CorpusPath
    )
    Add-TestResult "Old/new Normal plans are identical" ([string]::Equals(
        $CurrentNormalPlan,
        $ReferenceNormalPlan,
        [StringComparison]::Ordinal
    ))

    $CurrentStrictPlan = Get-PlanSignature (
        Invoke-WithCoreText $CurrentCoreText $CorpusPath -Strict
    )
    $ReferenceStrictPlan = Get-PlanSignature (
        Invoke-WithCoreText $ReferenceCoreText $CorpusPath -Strict
    )
    Add-TestResult "Old/new Strict plans are identical" ([string]::Equals(
        $CurrentStrictPlan,
        $ReferenceStrictPlan,
        [StringComparison]::Ordinal
    ))

    $EquivalenceDirectoryPath = New-TestDirectory "equivalence-directories"
    $LevelOne = [System.IO.Directory]::CreateDirectory(
        (Join-Path $EquivalenceDirectoryPath "parent  directory")
    )
    $LevelTwo = [System.IO.Directory]::CreateDirectory(
        (Join-Path $LevelOne.FullName "child  directory")
    )
    New-TestFile $LevelOne.FullName "parent  file.txt"
    New-TestFile $LevelTwo.FullName "nested  file.txt"
    $CurrentDirectoryPlan = Get-PlanSignature (
        Invoke-WithCoreText `
            $CurrentCoreText `
            $EquivalenceDirectoryPath `
            -IncludeDirectories
    )
    $ReferenceDirectoryPlan = Get-PlanSignature (
        Invoke-WithCoreText `
            $ReferenceCoreText `
            $EquivalenceDirectoryPath `
            -IncludeDirectories
    )
    Add-TestResult "Old/new IncludeDirectories plans are identical" ([string]::Equals(
        $CurrentDirectoryPlan,
        $ReferenceDirectoryPlan,
        [StringComparison]::Ordinal
    ))

    # Headless GUI workflow tests use the same event-driven background path.
    # (Headless GUI workflow tests используют тот же event-driven background path.)
    $Form.ShowInTaskbar = $false
    $Form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $Form.Location = New-Object System.Drawing.Point(-32000, -32000)
    $Form.Show()
    [System.Windows.Forms.Application]::DoEvents()
    Add-TestResult "GUI startup" ($Form.IsHandleCreated -and -not $Form.IsDisposed)

    $BrowsePath = New-TestDirectory "browse-target"
    $script:TestBrowsePath = $BrowsePath
    function Select-Folder { return $script:TestBrowsePath }
    $BrowseButton.PerformClick()
    Add-TestResult "Browse selects folder" ([string]::Equals($FolderTextBox.Text, $BrowsePath, [StringComparison]::OrdinalIgnoreCase))

    $DropPath = New-TestDirectory "drop-target"
    $DropData = New-Object System.Windows.Forms.DataObject
    $DropData.SetData(
        [System.Windows.Forms.DataFormats]::FileDrop,
        [string[]]@($DropPath)
    )
    $DropEvent = New-Object System.Windows.Forms.DragEventArgs(
        $DropData,
        0,
        0,
        0,
        [System.Windows.Forms.DragDropEffects]::Copy,
        [System.Windows.Forms.DragDropEffects]::Copy
    )
    Set-DroppedFolder -EventArgs $DropEvent
    Add-TestResult "Folder drag and drop" ([string]::Equals($FolderTextBox.Text, $DropPath, [StringComparison]::OrdinalIgnoreCase))

    $GuiPath = New-TestDirectory "gui"
    New-TestFile $GuiPath "gui  item.txt"
    $FolderTextBox.Text = $GuiPath
    $HeartbeatTicks = 0
    $Heartbeat = New-Object System.Windows.Forms.Timer
    $Heartbeat.Interval = 10
    $Heartbeat.Add_Tick({ $script:HeartbeatTicks++ })
    $script:HeartbeatTicks = 0
    $Heartbeat.Start()
    Start-BackgroundScan $GuiPath
    $BackgroundCompleted = Wait-ForBackgroundScan
    $Heartbeat.Stop()
    Add-TestResult "Background Scan completes" ($BackgroundCompleted -and $script:PlanCanApply)
    Add-TestResult "UI message pump remains responsive" ($script:HeartbeatTicks -gt 0) "$($script:HeartbeatTicks) ticks"
    Add-TestResult "Virtual grid presents plan" ($ResultsGrid.VirtualMode -and $ResultsGrid.RowCount -eq 1)

    $GuiStrictPath = New-TestDirectory "gui-strict"
    New-TestFile $GuiStrictPath "file.t(`$)!x"
    $StrictCheckBox.Checked = $true
    $FolderTextBox.Text = $GuiStrictPath
    Start-BackgroundScan $GuiStrictPath
    [void](Wait-ForBackgroundScan)
    Add-TestResult "GUI Strict setting reaches core" ($script:GridRecords.Count -eq 1 -and $script:GridRecords[0].NewName -eq "file.t-x")
    $StrictCheckBox.Checked = $false

    $GuiDirectoriesPath = New-TestDirectory "gui-directories"
    [void][System.IO.Directory]::CreateDirectory(
        (Join-Path $GuiDirectoriesPath "gui  directory")
    )
    $DirectoriesCheckBox.Checked = $true
    $FolderTextBox.Text = $GuiDirectoriesPath
    Start-BackgroundScan $GuiDirectoriesPath
    [void](Wait-ForBackgroundScan)
    Add-TestResult "GUI IncludeDirectories setting reaches core" (@($script:GridRecords | Where-Object ItemType -eq "Directory").Count -eq 1)
    $DirectoriesCheckBox.Checked = $false

    $LargePresentationRecords = New-Object object[] 25000
    for ($Index = 0; $Index -lt $LargePresentationRecords.Count; $Index++) {
        $LargePresentationRecords[$Index] = [pscustomobject]@{
            ItemType        = "File"
            OriginalName    = "before-$Index"
            NewName         = "after-$Index"
            Location        = "."
            OriginalFullName = "C:\fixture\before-$Index"
            NeedsRename     = $true
        }
    }
    Show-StructuredResult ([pscustomobject]@{
        Records = $LargePresentationRecords
        Checked = 25000
        NeedRename = 25000
        Renamed = 0
        Errors = 0
    })
    Add-TestResult "Large result presentation" ($ResultsGrid.RowCount -eq 25000 -and $script:GridRecords.Count -eq 25000)
    Clear-CurrentPlan

    $CancelPath = New-TestDirectory "cancel"
    for ($Index = 0; $Index -lt 2000; $Index++) {
        New-TestFile $CancelPath ("cancel  {0:D5}  item.txt" -f $Index)
    }
    $FolderTextBox.Text = $CancelPath
    Start-BackgroundScan $CancelPath
    $CancelDeadline = [DateTime]::UtcNow.AddMilliseconds(150)
    while ([DateTime]::UtcNow -lt $CancelDeadline) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 5
    }
    Request-ScanCancellation
    $CancelledCompleted = Wait-ForBackgroundScan
    Add-TestResult "Cancel clears partial plan" ($CancelledCompleted -and -not $script:PlanCanApply -and $ResultsGrid.RowCount -eq 0)
    Add-TestResult "Apply disabled after Cancel" (-not $ApplyButton.Enabled)

    $FolderTextBox.Text = $GuiPath
    Start-BackgroundScan $GuiPath
    $RescanCompleted = Wait-ForBackgroundScan
    Add-TestResult "Scan works after Cancel" ($RescanCompleted -and $script:PlanCanApply)

    $StrictCheckBox.Checked = -not $StrictCheckBox.Checked
    Add-TestResult "Settings change invalidates plan" (-not $script:PlanCanApply -and -not $ApplyButton.Enabled)
    $StrictCheckBox.Checked = $false

    $EmptyPath = New-TestDirectory "empty-state"
    New-TestFile $EmptyPath "already-safe.txt"
    $FolderTextBox.Text = $EmptyPath
    Start-BackgroundScan $EmptyPath
    [void](Wait-ForBackgroundScan)
    Add-TestResult "No-change empty state" ($EmptyStateLabel.Visible -and $ResultsGrid.RowCount -eq 0)

    # Replace modal dialogs for Apply safety tests; production confirmation logic
    # itself remains unchanged.
    # (Для Apply safety tests заменяем modal dialogs; production confirmation
    # остаётся неизменным.)
    function Show-GuiMessage { return [System.Windows.Forms.DialogResult]::OK }
    function Confirm-ApplyChanges { return [System.Windows.Forms.DialogResult]::No }
    $NoPath = New-TestDirectory "confirmation-no"
    New-TestFile $NoPath "no  change.txt"
    $FolderTextBox.Text = $NoPath
    $NoPlan = Invoke-CleanFileNamesCore $NoPath
    Show-StructuredResult $NoPlan
    Save-ScannedSettings $NoPath $NoPlan
    $ApplyButton.Enabled = $script:PlanCanApply
    $ApplyButton.PerformClick()
    Add-TestResult "Confirmation No preserves plan" ((Test-Path (Join-Path $NoPath "no  change.txt")) -and $script:PlanCanApply -and $ApplyButton.Enabled)

    function Confirm-ApplyChanges { return [System.Windows.Forms.DialogResult]::Yes }
    $ChangedPath = New-TestDirectory "changed-after-scan"
    New-TestFile $ChangedPath "planned  item.txt"
    $FolderTextBox.Text = $ChangedPath
    $SavedPlan = Invoke-CleanFileNamesCore $ChangedPath
    Show-StructuredResult $SavedPlan
    Save-ScannedSettings $ChangedPath $SavedPlan
    $ApplyButton.Enabled = $script:PlanCanApply
    New-TestFile $ChangedPath "added  later.txt"
    $ApplyButton.PerformClick()
    Add-TestResult "Apply revalidation blocks changed folder" ((Test-Path (Join-Path $ChangedPath "planned  item.txt")) -and -not $script:PlanCanApply -and -not $ApplyButton.Enabled)

    $ApplyGuiPath = New-TestDirectory "gui-apply"
    New-TestFile $ApplyGuiPath "apply  gui.txt"
    $FolderTextBox.Text = $ApplyGuiPath
    $SavedPlan = Invoke-CleanFileNamesCore $ApplyGuiPath
    Show-StructuredResult $SavedPlan
    Save-ScannedSettings $ApplyGuiPath $SavedPlan
    $ApplyButton.Enabled = $script:PlanCanApply
    $ApplyButton.PerformClick()
    Add-TestResult "GUI Apply succeeds after revalidation" (Test-Path (Join-Path $ApplyGuiPath "apply gui.txt"))

    Add-TestResult "Minimum window size" ($Form.MinimumSize.Width -ge 1000 -and $Form.MinimumSize.Height -ge 650)
    Add-TestResult "Drag and drop enabled" ($Form.AllowDrop -and $FolderTextBox.AllowDrop)
    Add-TestResult "Safe keyboard shortcuts configured" ($Form.KeyPreview)
    Add-TestResult "Grid context menu is read-only" ($GridContextMenu.Items.Count -eq 3 -and $ResultsGrid.ReadOnly)
    Add-TestResult "External source mode" ($script:CoreSourceMode -eq "External")

    # Embedded/external startup and fatal-path checks.
    # (Проверки embedded/external startup и fatal path.)
    $CoreBytes = $Utf8NoBom.GetBytes($CurrentCoreText)
    $HashAlgorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        $CoreHash = [BitConverter]::ToString($HashAlgorithm.ComputeHash($CoreBytes)).Replace("-", "")
    }
    finally {
        $HashAlgorithm.Dispose()
    }
    $CoreBase64 = [Convert]::ToBase64String($CoreBytes)
    $EmbeddedPrefix = "`$script:CleanFileNamesEmbeddedCoreBase64 = '$CoreBase64'`r`n"
    $EmbeddedPrefix += "`$script:CleanFileNamesEmbeddedCoreSha256 = '$CoreHash'`r`n"

    $SourceModeFixture = New-TestDirectory "source-mode-fixture"
    New-TestFile $SourceModeFixture "normal  rename.txt"
    New-TestFile $SourceModeFixture "target.txt"
    New-TestFile $SourceModeFixture "target  .txt"
    New-TestFile $SourceModeFixture ("unicode-{0}{1}.txt" -f [char]0x0438, [char]0x0306)
    New-TestFile $SourceModeFixture "strict-file.t(`$)!x"

    $ExternalProbeRoot = New-TestDirectory "external-operation-probe"
    $ExternalProbeGui = Join-Path $ExternalProbeRoot "Clean-FileNames-GUI.ps1"
    [System.IO.File]::Copy($GuiScriptPath, $ExternalProbeGui)
    [System.IO.File]::Copy(
        $CoreScriptPath,
        (Join-Path $ExternalProbeRoot "Clean-FileNames.ps1")
    )

    $EmbeddedProbeRoot = New-TestDirectory "embedded-operation-probe"
    $EmbeddedProbeGui = Join-Path $EmbeddedProbeRoot "Clean-FileNames-GUI.ps1"
    [System.IO.File]::Copy($GuiScriptPath, $EmbeddedProbeGui)
    $EmbeddedExternalCorePath = Join-Path `
        $EmbeddedProbeRoot `
        "Clean-FileNames.ps1"

    $ProbeMarkerFunction = @'
function Write-CfnProbeMarker {
    param([object]$Payload)
    $Json = $Payload | ConvertTo-Json -Depth 6 -Compress
    $Encoding = New-Object System.Text.UTF8Encoding($false, $true)
    $Base64 = [Convert]::ToBase64String($Encoding.GetBytes($Json))
    Write-Output ("CFN_PROBE_V1:" + $Base64)
}
'@

    $ExternalOperationText = @"
`$ErrorActionPreference = 'Stop'
$ProbeMarkerFunction
. '$($ExternalProbeGui.Replace("'", "''"))'
`$GuiLoaded = `$true
if (`$script:CoreSourceMode -ne 'External') { throw 'Unexpected source mode.' }
`$CoreInvoked = `$true
`$Result = Invoke-CleanFileNamesCore -Path '$($SourceModeFixture.Replace("'", "''"))' -Strict
`$Signature = Get-PlanSignature -Result `$Result
Write-CfnProbeMarker ([ordered]@{ SourceMode = `$script:CoreSourceMode; GuiLoaded = `$GuiLoaded; CoreInvoked = `$CoreInvoked; NeedRename = [int]`$Result.NeedRename; PlanSignature = `$Signature; ParentAlive = `$true })
`$Form.Dispose()
"@
    $ExternalOperationProbe = Invoke-ProbeScript $ExternalOperationText
    $ExternalOperationPayload = Get-ProbePayload $ExternalOperationProbe
    Add-TestResult "True external operation probe" (
        $ExternalOperationProbe.ExitCode -eq 0 -and
        $null -ne $ExternalOperationPayload -and
        $ExternalOperationPayload.SourceMode -eq "External" -and
        $ExternalOperationPayload.GuiLoaded -and
        $ExternalOperationPayload.CoreInvoked -and
        $ExternalOperationPayload.NeedRename -gt 0 -and
        $ExternalOperationPayload.ParentAlive
    )

    $EmbeddedOperationText = @"
`$ErrorActionPreference = 'Stop'
$EmbeddedPrefix
$ProbeMarkerFunction
. '$($EmbeddedProbeGui.Replace("'", "''"))'
`$GuiLoaded = `$true
if (`$script:CoreSourceMode -ne 'Embedded') { throw 'Unexpected source mode.' }
`$CoreInvoked = `$true
`$Result = Invoke-CleanFileNamesCore -Path '$($SourceModeFixture.Replace("'", "''"))' -Strict
`$Signature = Get-PlanSignature -Result `$Result
Write-CfnProbeMarker ([ordered]@{ SourceMode = `$script:CoreSourceMode; GuiLoaded = `$GuiLoaded; CoreInvoked = `$CoreInvoked; NeedRename = [int]`$Result.NeedRename; PlanSignature = `$Signature; ParentAlive = `$true })
`$Form.Dispose()
"@
    $EmbeddedOperationProbe = Invoke-ProbeScript $EmbeddedOperationText
    $EmbeddedOperationPayload = Get-ProbePayload $EmbeddedOperationProbe
    Add-TestResult "Embedded operation without external core" (
        -not (Test-Path -LiteralPath $EmbeddedExternalCorePath) -and
        $EmbeddedOperationProbe.ExitCode -eq 0 -and
        $null -ne $EmbeddedOperationPayload -and
        $EmbeddedOperationPayload.SourceMode -eq "Embedded" -and
        $EmbeddedOperationPayload.GuiLoaded -and
        $EmbeddedOperationPayload.CoreInvoked -and
        $EmbeddedOperationPayload.NeedRename -gt 0 -and
        $EmbeddedOperationPayload.ParentAlive
    )

    $SourceModePlansEqual = (
        $null -ne $ExternalOperationPayload -and
        $null -ne $EmbeddedOperationPayload -and
        [string]::Equals(
            [string]$ExternalOperationPayload.PlanSignature,
            [string]$EmbeddedOperationPayload.PlanSignature,
            [StringComparison]::Ordinal
        )
    )
    Add-TestResult "External/embedded operation plans are identical" $SourceModePlansEqual
    $ExternalPlanSignatureHash = Get-TextSha256 `
        ([string]$ExternalOperationPayload.PlanSignature)
    $EmbeddedPlanSignatureHash = Get-TextSha256 `
        ([string]$EmbeddedOperationPayload.PlanSignature)

    $ExternalMissingRoot = New-TestDirectory "external-missing-probe"
    $ExternalMissingGui = Join-Path $ExternalMissingRoot "Clean-FileNames-GUI.ps1"
    [System.IO.File]::Copy($GuiScriptPath, $ExternalMissingGui)
    $ExternalMissing = Invoke-ProbeScript (
        ". '{0}'" -f $ExternalMissingGui.Replace("'", "''")
    )
    Add-ExpectedDiagnosticResult `
        "External missing core diagnostic" `
        $ExternalMissing `
        "Core script could not be loaded." `
        "Не удалось загрузить основной скрипт."

    $ExternalInvalidRoot = New-TestDirectory "external-invalid-utf8-probe"
    $ExternalInvalidGui = Join-Path $ExternalInvalidRoot "Clean-FileNames-GUI.ps1"
    [System.IO.File]::Copy($GuiScriptPath, $ExternalInvalidGui)
    [System.IO.File]::WriteAllBytes(
        (Join-Path $ExternalInvalidRoot "Clean-FileNames.ps1"),
        [byte[]]@(0xC3, 0x28)
    )
    $ExternalInvalid = Invoke-ProbeScript (
        ". '{0}'" -f $ExternalInvalidGui.Replace("'", "''")
    )
    Add-ExpectedDiagnosticResult `
        "External invalid UTF-8 diagnostic" `
        $ExternalInvalid `
        "Core script could not be loaded." `
        "Не удалось загрузить основной скрипт."

    # A valid external core is an explicit fallback trap for every damaged
    # embedded configuration below.
    # (Корректное внешнее ядро служит явной fallback-ловушкой для каждой
    # повреждённой embedded-конфигурации ниже.)
    $NegativeProbeRoot = New-TestDirectory "embedded-negative-probes"
    $NegativeProbeGui = Join-Path $NegativeProbeRoot "Clean-FileNames-GUI.ps1"
    [System.IO.File]::Copy($GuiScriptPath, $NegativeProbeGui)
    [System.IO.File]::Copy(
        $CoreScriptPath,
        (Join-Path $NegativeProbeRoot "Clean-FileNames.ps1")
    )
    $NegativeGuiSource = ". '$($NegativeProbeGui.Replace("'", "''"))'"
    $EmbeddedNegativeCases = @(
        [pscustomobject]@{
            Name = "Embedded invalid Base64 diagnostic"
            Text = "`$script:CleanFileNamesEmbeddedCoreBase64 = '%%%'`r`n`$script:CleanFileNamesEmbeddedCoreSha256 = '$CoreHash'`r`n$NegativeGuiSource"
            English = "Embedded core payload is not valid Base64."
            Russian = "Данные встроенного ядра не являются корректным Base64."
        },
        [pscustomobject]@{
            Name = "Embedded missing hash diagnostic"
            Text = "`$script:CleanFileNamesEmbeddedCoreBase64 = '$CoreBase64'`r`n$NegativeGuiSource"
            English = "Embedded core SHA-256 is missing."
            Russian = "Отсутствует SHA-256 встроенного ядра."
        },
        [pscustomobject]@{
            Name = "Embedded malformed hash diagnostic"
            Text = "`$script:CleanFileNamesEmbeddedCoreBase64 = '$CoreBase64'`r`n`$script:CleanFileNamesEmbeddedCoreSha256 = '1234'`r`n$NegativeGuiSource"
            English = "Embedded core SHA-256 has an invalid format."
            Russian = "SHA-256 встроенного ядра имеет неверный формат."
        },
        [pscustomobject]@{
            Name = "Embedded wrong hash diagnostic"
            Text = "`$script:CleanFileNamesEmbeddedCoreBase64 = '$CoreBase64'`r`n`$script:CleanFileNamesEmbeddedCoreSha256 = '$('0' * 64)'`r`n$NegativeGuiSource"
            English = "Embedded core integrity check failed."
            Russian = "Проверка целостности встроенного ядра не пройдена."
        }
    )

    foreach ($Negative in $EmbeddedNegativeCases) {
        $Probe = Invoke-ProbeScript $Negative.Text
        Add-ExpectedDiagnosticResult `
            $Negative.Name `
            $Probe `
            $Negative.English `
            $Negative.Russian
    }

    $InvalidUtf8 = [byte[]]@(0xC3, 0x28)
    $HashAlgorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        $InvalidHash = [BitConverter]::ToString(
            $HashAlgorithm.ComputeHash($InvalidUtf8)
        ).Replace("-", "")
    }
    finally {
        $HashAlgorithm.Dispose()
    }
    $InvalidText = "`$script:CleanFileNamesEmbeddedCoreBase64 = '$([Convert]::ToBase64String($InvalidUtf8))'`r`n`$script:CleanFileNamesEmbeddedCoreSha256 = '$InvalidHash'`r`n$NegativeGuiSource"
    $EmbeddedInvalidUtf8 = Invoke-ProbeScript $InvalidText
    Add-ExpectedDiagnosticResult `
        "Embedded invalid UTF-8 diagnostic" `
        $EmbeddedInvalidUtf8 `
        "Embedded core payload is not valid UTF-8." `
        "Данные встроенного ядра не являются корректным UTF-8."

    $MissingTarget = Join-Path $FixtureRoot "does-not-exist"
    $ExternalFatalText = @"
`$ErrorActionPreference = 'Stop'
$ProbeMarkerFunction
. '$($ExternalProbeGui.Replace("'", "''"))'
`$GuiLoaded = `$true
if (`$script:CoreSourceMode -ne 'External') { throw 'Unexpected source mode.' }
`$CoreInvoked = `$false
`$ExceptionCaught = `$false
`$Diagnostic = ''
try {
    `$CoreInvoked = `$true
    [void](Invoke-CleanFileNamesCore -Path '$($MissingTarget.Replace("'", "''"))')
}
catch {
    `$ExceptionCaught = `$true
    `$Diagnostic = ((`$_.Exception.Message -replace '\s+', ' ').Trim())
}
Write-CfnProbeMarker ([ordered]@{ SourceMode = `$script:CoreSourceMode; GuiLoaded = `$GuiLoaded; CoreInvoked = `$CoreInvoked; ExceptionCaught = `$ExceptionCaught; Diagnostic = `$Diagnostic; ParentAlive = `$true })
`$Form.Dispose()
"@
    $ExternalFatalProbe = Invoke-ProbeScript $ExternalFatalText
    $ExternalFatalPayload = Get-ProbePayload $ExternalFatalProbe

    $EmbeddedFatalText = @"
`$ErrorActionPreference = 'Stop'
$EmbeddedPrefix
$ProbeMarkerFunction
. '$($EmbeddedProbeGui.Replace("'", "''"))'
`$GuiLoaded = `$true
if (`$script:CoreSourceMode -ne 'Embedded') { throw 'Unexpected source mode.' }
`$CoreInvoked = `$false
`$ExceptionCaught = `$false
`$Diagnostic = ''
try {
    `$CoreInvoked = `$true
    [void](Invoke-CleanFileNamesCore -Path '$($MissingTarget.Replace("'", "''"))')
}
catch {
    `$ExceptionCaught = `$true
    `$Diagnostic = ((`$_.Exception.Message -replace '\s+', ' ').Trim())
}
Write-CfnProbeMarker ([ordered]@{ SourceMode = `$script:CoreSourceMode; GuiLoaded = `$GuiLoaded; CoreInvoked = `$CoreInvoked; ExceptionCaught = `$ExceptionCaught; Diagnostic = `$Diagnostic; ParentAlive = `$true })
`$Form.Dispose()
"@
    $EmbeddedFatalProbe = Invoke-ProbeScript $EmbeddedFatalText
    $EmbeddedFatalPayload = Get-ProbePayload $EmbeddedFatalProbe
    $ExpectedFatalDiagnostic = "The core operation failed. (Сбой выполнения основного скрипта.)"
    Add-TestResult "True external fatal probe" (
        $ExternalFatalProbe.ExitCode -eq 0 -and
        $null -ne $ExternalFatalPayload -and
        $ExternalFatalPayload.SourceMode -eq "External" -and
        $ExternalFatalPayload.GuiLoaded -and
        $ExternalFatalPayload.CoreInvoked -and
        $ExternalFatalPayload.ExceptionCaught -and
        $ExternalFatalPayload.ParentAlive -and
        $ExternalFatalPayload.Diagnostic -eq $ExpectedFatalDiagnostic
    ) $ExternalFatalPayload.Diagnostic
    Add-TestResult "True embedded fatal probe" (
        $EmbeddedFatalProbe.ExitCode -eq 0 -and
        $null -ne $EmbeddedFatalPayload -and
        $EmbeddedFatalPayload.SourceMode -eq "Embedded" -and
        $EmbeddedFatalPayload.GuiLoaded -and
        $EmbeddedFatalPayload.CoreInvoked -and
        $EmbeddedFatalPayload.ExceptionCaught -and
        $EmbeddedFatalPayload.ParentAlive -and
        $EmbeddedFatalPayload.Diagnostic -eq $ExpectedFatalDiagnostic
    ) $EmbeddedFatalPayload.Diagnostic
    Add-TestResult "Fatal external/embedded equality" (
        $null -ne $ExternalFatalPayload -and
        $null -ne $EmbeddedFatalPayload -and
        [string]::Equals(
            [string]$ExternalFatalPayload.Diagnostic,
            [string]$EmbeddedFatalPayload.Diagnostic,
            [StringComparison]::Ordinal
        )
    )

    Write-Host "ExternalPlanSignatureSha256: $ExternalPlanSignatureHash"
    Write-Host "EmbeddedPlanSignatureSha256: $EmbeddedPlanSignatureHash"
    Write-Host "ExternalFatalDiagnostic: $($ExternalFatalPayload.Diagnostic)"
    Write-Host "EmbeddedFatalDiagnostic: $($EmbeddedFatalPayload.Diagnostic)"
}
catch {
    $Failed++
    $Failures.Add("Unhandled test runner error — $($_.Exception.Message)")
    Write-Host "FAIL  Unhandled test runner error — $($_.Exception.Message)" -ForegroundColor Red
}
finally {
    if ($null -ne $Heartbeat) {
        $Heartbeat.Dispose()
    }

    if ($null -ne $script:ActiveScanOperation) {
        try { $script:ActiveScanOperation.PowerShell.Stop() } catch {}
        $script:ActiveScanOperation.PowerShell.Dispose()
        $script:ActiveScanOperation = $null
    }

    if ($null -ne $Form) {
        $Form.Dispose()
    }

    if (Test-Path -LiteralPath $FixtureRoot) {
        [System.IO.Directory]::Delete($FixtureRoot, $true)
    }
}

Write-Host ""
Write-Host "Passed: $Passed"
Write-Host "Failed: $Failed"

if ($Failures.Count -gt 0) {
    $Failures | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    exit 1
}

exit 0
