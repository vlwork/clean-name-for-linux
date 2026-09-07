param(
    [int[]]$FileCount = @(100, 1000, 10000, 25000),

    [ValidateRange(3, 50)]
    [int]$Runs = 3,

    [ValidateRange(0, 100)]
    [int[]]$DirtyPercent = @(0, 80),

    [switch]$IncludeDirectories,

    [switch]$Strict,

    [switch]$Mixed,

    [ValidateRange(1, 86400)]
    [int]$BackgroundTimeoutSeconds = 600,

    [string]$GuiScriptPath = (
        Join-Path (Split-Path -Parent $PSScriptRoot) "Clean-FileNames-GUI.ps1"
    ),

    [string]$OutputJsonPath
)

$ErrorActionPreference = "Stop"

# This benchmark creates only empty files in a unique TEMP directory and always
# removes the fixture in finally. It never runs Apply.
# (Этот benchmark создаёт только пустые файлы в уникальном каталоге TEMP, всегда
# удаляет fixture в finally и никогда не запускает Apply.)

if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne "STA") {
    throw "Run this benchmark in an STA Windows PowerShell 5.1 process. (Запустите benchmark в STA-процессе Windows PowerShell 5.1.)"
}

$GuiScriptPath = (Resolve-Path -LiteralPath $GuiScriptPath).Path
$RepositoryRoot = Split-Path -Parent $GuiScriptPath
$CoreScriptPath = Join-Path $RepositoryRoot "Clean-FileNames.ps1"

if (-not (Test-Path -LiteralPath $CoreScriptPath -PathType Leaf)) {
    throw "Core script was not found (Основной скрипт не найден): $CoreScriptPath"
}

# Dot-sourcing initializes the production GUI helpers. Separate metrics below
# distinguish synchronous computation from the actual background Scan path.
# (Dot-sourcing инициализирует production GUI helpers. Метрики ниже отдельно
# измеряют синхронные вычисления и настоящий background Scan path.)
. $GuiScriptPath

# Create a real WinForms handle and message pump without leaving a visible window
# or taskbar button during the benchmark.
# (Создаём настоящий WinForms handle и message pump, не оставляя видимое окно или
# кнопку taskbar во время benchmark.)
$Form.ShowInTaskbar = $false
$Form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$Form.Location = New-Object System.Drawing.Point(-32000, -32000)
$Form.Show()
[System.Windows.Forms.Application]::DoEvents()

$FixtureRoot = Join-Path `
    ([System.IO.Path]::GetTempPath()) `
    ("CleanFileNames-Benchmark-{0}" -f [guid]::NewGuid().ToString("N"))
$EmptyBytes = New-Object byte[] 0
$Results = New-Object System.Collections.Generic.List[object]

function New-BenchmarkFixture {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [int]$Count,

        [Parameter(Mandatory = $true)]
        [int]$PercentDirty
    )

    [void][System.IO.Directory]::CreateDirectory($Path)
    $DirtyCount = [int][Math]::Floor($Count * ($PercentDirty / 100.0))
    $ParentPaths = @($Path)

    if ($Mixed) {
        $NestedRoot = Join-Path $Path "nested  group"
        $DeepPath = Join-Path $NestedRoot "level-one\level  two\level-three"
        [void][System.IO.Directory]::CreateDirectory($DeepPath)
        $ParentPaths = @(
            $Path,
            $NestedRoot,
            (Split-Path -Parent $DeepPath),
            $DeepPath
        )
    }

    for ($Index = 0; $Index -lt $Count; $Index++) {
        if ($Index -lt $DirtyCount) {
            # Repeated spaces are valid on Windows and deterministically require
            # normalization in both Normal and Strict modes.
            # (Повторяющиеся пробелы допустимы в Windows и детерминированно требуют
            # нормализации как в Normal, так и в Strict.)
            if ($Mixed) {
                switch ($Index % 7) {
                    0 { $Name = "dirty  {0:D6}  item.txt" -f $Index }
                    1 { $Name = "fullwidth-{0:D6}{1}item.txt" -f $Index, [char]0xFF1A }
                    2 { $Name = "nfc-{0:D6}-{1}{2}.txt" -f $Index, [char]0x0438, [char]0x0306 }
                    3 { $Name = "strict-{0:D6}.t(`$)!x" -f $Index }
                    4 { $Name = "emoji  {0:D6}-{1}.txt" -f $Index, [char]::ConvertFromUtf32(0x1F600) }
                    5 { $Name = ".dotfile  {0:D6}.json" -f $Index }
                    6 { $Name = (([char]0x044F).ToString() * 110) + "  {0:D6}.mkv" -f $Index }
                }
            }
            else {
                $Name = "dirty  {0:D6}  item.txt" -f $Index
            }
        }
        else {
            $Name = "clean-{0:D6}.txt" -f $Index
        }

        $ParentPath = $ParentPaths[$Index % $ParentPaths.Count]

        if ($Mixed -and ($Index % 7) -eq 6) {
            # Keep long-name cases at the fixture root so the complete Windows
            # path remains comfortably below legacy MAX_PATH.
            # (Длинные имена размещаем в корне fixture, чтобы полный Windows-путь
            # уверенно оставался короче legacy MAX_PATH.)
            $ParentPath = $Path
        }

        $FilePath = Join-Path $ParentPath $Name
        [System.IO.File]::WriteAllBytes($FilePath, $EmptyBytes)
    }

    if ($Mixed) {
        # A deterministic occupied sequence exercises virtual namespace conflict
        # resolution without using invalid Windows filenames.
        # (Детерминированная занятая последовательность проверяет разрешение
        # конфликтов virtual namespace без недопустимых Windows-имён.)
        foreach ($Name in @(
            "collision.txt",
            "collision (1).txt",
            "collision  .txt"
        )) {
            [System.IO.File]::WriteAllBytes(
                (Join-Path $Path $Name),
                $EmptyBytes
            )
        }
    }

    if ($IncludeDirectories) {
        # Keep directory overhead deterministic and small relative to FileCount.
        # (Делаем нагрузку каталогов детерминированной и небольшой относительно
        # количества файлов.)
        $DirectoryCount = [Math]::Max(1, [int][Math]::Floor($Count / 1000))

        for ($Index = 0; $Index -lt $DirectoryCount; $Index++) {
            $DirectoryName = "benchmark-directory-{0:D4}" -f $Index
            [void][System.IO.Directory]::CreateDirectory(
                (Join-Path $Path $DirectoryName)
            )
        }
    }
}

function Invoke-CoreDryRunOnly {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $Worker = [System.Management.Automation.PowerShell]::Create()

    try {
        [void]$Worker.AddScript(@'
param($CoreText, $TargetPath, $UseStrict, $UseDirectories)
$Parameters = @{ Path = $TargetPath }
if ($UseStrict) { $Parameters.Strict = $true }
if ($UseDirectories) { $Parameters.IncludeDirectories = $true }
$CoreScriptBlock = [scriptblock]::Create($CoreText)
. $CoreScriptBlock @Parameters *> $null
'@)
        [void]$Worker.AddArgument($script:CoreText)
        [void]$Worker.AddArgument($Path)
        [void]$Worker.AddArgument([bool]$Strict)
        [void]$Worker.AddArgument([bool]$IncludeDirectories)
        [void]$Worker.Invoke()

        if ($Worker.HadErrors) {
            throw (($Worker.Streams.Error | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine)
        }
    }
    finally {
        $Worker.Dispose()
    }
}

function Get-MillisecondStatistics {
    param(
        [Parameter(Mandatory = $true)]
        [double[]]$Values
    )

    $Sorted = [double[]]@($Values | Sort-Object)
    $Middle = [int][Math]::Floor($Sorted.Count / 2)

    if (($Sorted.Count % 2) -eq 0) {
        $Median = ($Sorted[$Middle - 1] + $Sorted[$Middle]) / 2.0
    }
    else {
        $Median = $Sorted[$Middle]
    }

    return [pscustomobject]@{
        Median = [Math]::Round($Median, 2)
        Min    = [Math]::Round($Sorted[0], 2)
        Max    = [Math]::Round($Sorted[$Sorted.Count - 1], 2)
    }
}

function Measure-BenchmarkOperation {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Operation
    )

    # One separate warm-up is intentionally excluded from reported values.
    # (Один отдельный warm-up намеренно не включается в результаты.)
    & $Operation
    $Measured = New-Object double[] $Runs

    for ($Run = 0; $Run -lt $Runs; $Run++) {
        $Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        & $Operation
        $Stopwatch.Stop()
        $Measured[$Run] = $Stopwatch.Elapsed.TotalMilliseconds
    }

    return Get-MillisecondStatistics -Values $Measured
}

function Invoke-ProductionBackgroundWorkflow {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [int]$ExpectedNeedRename,

        [Parameter(Mandatory = $true)]
        [int]$ExpectedErrors
    )

    $Deadline = [DateTime]::UtcNow.AddSeconds($BackgroundTimeoutSeconds)
    Start-BackgroundScan -Path $Path

    # Do not call Complete-BackgroundScan here. The production WinForms Timer
    # must observe completion and run the normal event path. Its 100 ms interval
    # is intentionally part of this user-observed latency metric; on small data
    # sets, completion detection can therefore add roughly 0-100 ms.
    # (Не вызываем Complete-BackgroundScan вручную. Завершение должен обнаружить
    # production WinForms Timer через обычный event path. Его интервал 100 мс
    # намеренно входит в пользовательскую latency этой метрики; на малых
    # наборах detection может добавить примерно 0-100 мс.)
    while ($null -ne $script:ActiveScanOperation -and
        [DateTime]::UtcNow -lt $Deadline) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 5
    }

    if ($null -ne $script:ActiveScanOperation) {
        # Request normal cooperative cancellation first. A bounded synchronous
        # stop is only the cleanup fallback for a benchmark timeout.
        # (Сначала запрашиваем обычную кооперативную отмену. Ограниченная
        # синхронная остановка — только cleanup fallback при timeout benchmark.)
        Request-ScanCancellation
        $CancellationDeadline = [DateTime]::UtcNow.AddSeconds(30)

        while ($null -ne $script:ActiveScanOperation -and
            [DateTime]::UtcNow -lt $CancellationDeadline) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 10
        }

        if ($null -ne $script:ActiveScanOperation) {
            $ScanTimer.Stop()

            try {
                $script:ActiveScanOperation.PowerShell.Stop()
            }
            finally {
                $script:ActiveScanOperation.PowerShell.Dispose()
                $script:ActiveScanOperation = $null
                Clear-CurrentPlan
                Set-BusyState -Busy $false
            }
        }

        throw "Background Scan timed out after $BackgroundTimeoutSeconds seconds. (Background Scan превысил timeout $BackgroundTimeoutSeconds секунд.)"
    }

    $ExpectedCanApply = (
        $ExpectedNeedRename -gt 0 -and
        $ExpectedErrors -eq 0
    )
    $StateIsValid = (
        -not $script:IsBusy -and
        (Test-ScannedSettingsAreCurrent -CurrentPath $Path) -and
        $script:GridRecords.Count -eq $ExpectedNeedRename -and
        $script:PlanCanApply -eq $ExpectedCanApply
    )

    if (-not $StateIsValid) {
        throw "Background Scan completed with an invalid GUI state. (Background Scan завершился с некорректным состоянием GUI.)"
    }
}

function Measure-BackgroundWorkflow {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [int]$ExpectedNeedRename,

        [Parameter(Mandatory = $true)]
        [int]$ExpectedErrors
    )

    Invoke-ProductionBackgroundWorkflow `
        -Path $Path `
        -ExpectedNeedRename $ExpectedNeedRename `
        -ExpectedErrors $ExpectedErrors
    Clear-CurrentPlan
    $Measured = New-Object double[] $Runs

    for ($Run = 0; $Run -lt $Runs; $Run++) {
        $Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        Invoke-ProductionBackgroundWorkflow `
            -Path $Path `
            -ExpectedNeedRename $ExpectedNeedRename `
            -ExpectedErrors $ExpectedErrors
        $Stopwatch.Stop()
        $Measured[$Run] = $Stopwatch.Elapsed.TotalMilliseconds
        Clear-CurrentPlan
    }

    return Get-MillisecondStatistics -Values $Measured
}

try {
    [void][System.IO.Directory]::CreateDirectory($FixtureRoot)

    foreach ($Count in $FileCount) {
        if ($Count -lt 1) {
            throw "FileCount values must be positive. (Значения FileCount должны быть положительными.)"
        }

        foreach ($PercentDirty in $DirtyPercent) {
            $Scenario = if ($PercentDirty -eq 0) { "CLEAN" } else { "DIRTY-$PercentDirty" }

            if ($Mixed) {
                $Scenario += "-MIXED"
            }
            $FixturePath = Join-Path $FixtureRoot ("{0}-{1}" -f $Count, $Scenario)
            New-BenchmarkFixture `
                -Path $FixturePath `
                -Count $Count `
                -PercentDirty $PercentDirty

            $FolderTextBox.Text = $FixturePath
            $StrictCheckBox.Checked = [bool]$Strict
            $DirectoriesCheckBox.Checked = [bool]$IncludeDirectories
            [System.Windows.Forms.Application]::DoEvents()

            [GC]::Collect()
            [GC]::WaitForPendingFinalizers()
            [GC]::Collect()
            $MemoryBeforeMb = [Math]::Round(
                ([System.Diagnostics.Process]::GetCurrentProcess().WorkingSet64 / 1MB),
                2
            )

            $CoreOnly = Measure-BenchmarkOperation {
                Invoke-CoreDryRunOnly -Path $FixturePath
            }

            $AdapterOnly = Measure-BenchmarkOperation {
                [void](Invoke-CleanFileNamesCore `
                    -Path $FixturePath `
                    -Strict:$Strict `
                    -IncludeDirectories:$IncludeDirectories)
            }

            $RenderResult = Invoke-CleanFileNamesCore `
                -Path $FixturePath `
                -Strict:$Strict `
                -IncludeDirectories:$IncludeDirectories
            # This measures result population and VirtualMode setup only. It is
            # not a measurement of painting every visible Windows cell.
            # (Измеряется только population результата и настройка VirtualMode,
            # а не painting каждой видимой Windows-ячейки.)
            $PresentationPopulation = Measure-BenchmarkOperation {
                Show-StructuredResult -Result $RenderResult
            }

            # Core + adapter + synchronous result processing. This remains useful
            # as a compute-oriented metric but is not production Scan latency.
            # (Core + adapter + синхронная обработка результата. Это полезная
            # compute-метрика, но не latency production Scan.)
            $SyncWorkflow = Measure-BenchmarkOperation {
                [void](Invoke-ScanAndDisplay -Path $FixturePath)
            }

            $BackgroundWorkflow = Measure-BackgroundWorkflow `
                -Path $FixturePath `
                -ExpectedNeedRename ([int]$RenderResult.NeedRename) `
                -ExpectedErrors ([int]$RenderResult.Errors)

            $MemoryAfterMb = [Math]::Round(
                ([System.Diagnostics.Process]::GetCurrentProcess().WorkingSet64 / 1MB),
                2
            )

            $Results.Add([pscustomobject]@{
                Dataset          = $Count
                Scenario         = $Scenario
                DirtyPercent     = $PercentDirty
                CoreMedianMs     = $CoreOnly.Median
                CoreMinMs        = $CoreOnly.Min
                CoreMaxMs        = $CoreOnly.Max
                AdapterMedianMs  = $AdapterOnly.Median
                AdapterMinMs     = $AdapterOnly.Min
                AdapterMaxMs     = $AdapterOnly.Max
                PresentationPopulationMedianMs = $PresentationPopulation.Median
                PresentationPopulationMinMs = $PresentationPopulation.Min
                PresentationPopulationMaxMs = $PresentationPopulation.Max
                SyncWorkflowMedianMs = $SyncWorkflow.Median
                SyncWorkflowMinMs = $SyncWorkflow.Min
                SyncWorkflowMaxMs = $SyncWorkflow.Max
                BackgroundWorkflowMedianMs = $BackgroundWorkflow.Median
                BackgroundWorkflowMinMs = $BackgroundWorkflow.Min
                BackgroundWorkflowMaxMs = $BackgroundWorkflow.Max
                MemoryBeforeMb   = $MemoryBeforeMb
                MemoryAfterMb    = $MemoryAfterMb
                ResultRows       = [int]$RenderResult.NeedRename
                Runs             = $Runs
            })

            $Results[$Results.Count - 1] | Format-List
            if (Get-Command Clear-ResultGrid -ErrorAction SilentlyContinue) {
                Clear-ResultGrid
            }
            else {
                $ResultsGrid.Rows.Clear()
            }
            [System.IO.Directory]::Delete($FixturePath, $true)
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($OutputJsonPath)) {
        $Results.ToArray() |
            ConvertTo-Json -Depth 4 |
            Set-Content -LiteralPath $OutputJsonPath -Encoding UTF8
    }

    $Results.ToArray()
}
finally {
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

    if ($null -ne $ResultsGrid) {
        if (Get-Command Clear-ResultGrid -ErrorAction SilentlyContinue) {
            Clear-ResultGrid
        }
        else {
            $ResultsGrid.Rows.Clear()
        }
    }

    if ($null -ne $ScanTimer) {
        $ScanTimer.Stop()
        $ScanTimer.Dispose()
    }

    if ($null -ne $Form) {
        $Form.Dispose()
    }

    if (Test-Path -LiteralPath $FixtureRoot) {
        [System.IO.Directory]::Delete($FixtureRoot, $true)
    }
}
