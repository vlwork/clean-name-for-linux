param(
    [switch]$Clean,

    [switch]$SkipTests,

    [switch]$KeepGeneratedScript
)

$ErrorActionPreference = "Stop"

$RequiredPs2ExeVersion = [version]"1.0.18"
$SemanticVersion = "6.0.0-preview.1"
$WindowsVersion = "6.0.0.0"
$ProductName = "Clean File Names"
$Description = "Checks, cleans and normalizes file names for Windows/Linux compatibility."
$ExeName = "Clean-File-Names.exe"
$Utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
$Utf8WithBom = New-Object System.Text.UTF8Encoding($true, $true)
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false, $true)

function Stop-Build {
    param([string]$Message)
    throw $Message
}

function Get-Sha256Hex {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Bytes
    )

    $Algorithm = [System.Security.Cryptography.SHA256]::Create()

    try {
        return [BitConverter]::ToString(
            $Algorithm.ComputeHash($Bytes)
        ).Replace("-", "")
    }
    finally {
        $Algorithm.Dispose()
    }
}

function Get-CanonicalUtf8Payload {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $Bytes = [System.IO.File]::ReadAllBytes($Path)
    $Offset = 0

    if ($Bytes.Length -ge 3 -and
        $Bytes[0] -eq 0xEF -and
        $Bytes[1] -eq 0xBB -and
        $Bytes[2] -eq 0xBF) {
        $Offset = 3
    }

    try {
        $Text = $Utf8Strict.GetString(
            $Bytes,
            $Offset,
            $Bytes.Length - $Offset
        )
    }
    catch {
        Stop-Build (
            "Source file is not valid UTF-8 (Исходный файл не является " +
            "корректным UTF-8): $Path"
        )
    }

    # Omit an optional UTF-8 BOM and canonicalize CRLF or lone CR line endings
    # to LF in memory. The returned Text and Bytes represent the same canonical
    # UTF-8 payload used for SHA-256 and Base64.
    # (Удаляем необязательный UTF-8 BOM и в памяти приводим окончания строк CRLF
    # и одиночные CR к LF. Возвращаемые Text и Bytes представляют один canonical
    # UTF-8 payload, используемый для SHA-256 и Base64.)
    $Text = $Text.Replace("`r`n", "`n").Replace("`r", "`n")
    $CanonicalBytes = $Utf8NoBom.GetBytes($Text)

    return [pscustomobject]@{
        Text  = $Text
        Bytes = $CanonicalBytes
    }
}

function Assert-ParserClean {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Paths
    )

    foreach ($Path in $Paths) {
        $Tokens = $null
        $Errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile(
            $Path,
            [ref]$Tokens,
            [ref]$Errors
        )

        if ($Errors.Count -ne 0) {
            $Details = ($Errors | ForEach-Object { $_.ToString() }) -join "`r`n"
            Stop-Build (
                "PowerShell parser validation failed (Проверка синтаксиса " +
                "PowerShell не пройдена): $Path`r`n$Details"
            )
        }

        Write-Host "Parser PASS: $Path"
    }
}

function Remove-GeneratedDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string[]]$AllowedPaths
    )

    $FullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    $IsAllowed = $false

    foreach ($AllowedPath in $AllowedPaths) {
        $FullAllowedPath = [System.IO.Path]::GetFullPath(
            $AllowedPath
        ).TrimEnd('\')

        if ([string]::Equals(
            $FullPath,
            $FullAllowedPath,
            [StringComparison]::OrdinalIgnoreCase
        )) {
            $IsAllowed = $true
            break
        }
    }

    if (-not $IsAllowed) {
        Stop-Build "Refusing to remove an unexpected path (Отказ от удаления неожиданного пути): $FullPath"
    }

    if (Test-Path -LiteralPath $FullPath) {
        Remove-Item -LiteralPath $FullPath -Recurse -Force
    }
}

function Get-PeMachine {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $Bytes = [System.IO.File]::ReadAllBytes($Path)

    if ($Bytes.Length -lt 64 -or
        $Bytes[0] -ne 0x4D -or
        $Bytes[1] -ne 0x5A) {
        Stop-Build "Output is not a valid PE file (Результат не является корректным PE-файлом)."
    }

    $PeOffset = [BitConverter]::ToInt32($Bytes, 0x3C)

    if ($PeOffset -lt 0 -or $PeOffset + 6 -gt $Bytes.Length -or
        $Bytes[$PeOffset] -ne 0x50 -or
        $Bytes[$PeOffset + 1] -ne 0x45 -or
        $Bytes[$PeOffset + 2] -ne 0 -or
        $Bytes[$PeOffset + 3] -ne 0) {
        Stop-Build "Output has an invalid PE header (Результат содержит некорректный PE-заголовок)."
    }

    return [BitConverter]::ToUInt16($Bytes, $PeOffset + 4)
}

if ($PSVersionTable.PSEdition -ne "Desktop" -or
    $PSVersionTable.PSVersion.Major -ne 5 -or
    $PSVersionTable.PSVersion.Minor -lt 1) {
    Stop-Build (
        "Run this build with Windows PowerShell 5.1. " +
        "(Запустите сборку в Windows PowerShell 5.1.)"
    )
}

$BuildDirectory = [System.IO.Path]::GetFullPath($PSScriptRoot)
$RepositoryRoot = [System.IO.Path]::GetFullPath(
    (Split-Path -Parent $BuildDirectory)
)
$CorePath = Join-Path $RepositoryRoot "Clean-FileNames.ps1"
$GuiPath = Join-Path $RepositoryRoot "Clean-FileNames-GUI.ps1"
$TestPath = Join-Path $RepositoryRoot "tests\Test-CleanFileNames.ps1"
$BuildScriptPath = Join-Path $BuildDirectory "Build-Exe.ps1"
$VersionPath = Join-Path $BuildDirectory "ps2exe.version"
$ObjectDirectory = Join-Path $BuildDirectory "obj"
$GeneratedScriptPath = Join-Path `
    $ObjectDirectory `
    "Clean-File-Names.embedded.ps1"
$DistDirectory = Join-Path $RepositoryRoot "dist"
$ExePath = Join-Path $DistDirectory $ExeName
$ChecksumPath = "$ExePath.sha256"
$AllowedGeneratedDirectories = @($ObjectDirectory, $DistDirectory)

foreach ($RequiredPath in @(
    $CorePath,
    $GuiPath,
    $TestPath,
    $BuildScriptPath,
    $VersionPath
)) {
    if (-not (Test-Path -LiteralPath $RequiredPath -PathType Leaf)) {
        Stop-Build "Required build input is missing (Отсутствует обязательный входной файл): $RequiredPath"
    }
}

$PinnedVersionText = [System.IO.File]::ReadAllText($VersionPath).Trim()
$PinnedVersion = $null

try {
    $PinnedVersion = [version]$PinnedVersionText
}
catch {
    Stop-Build "Invalid PS2EXE version file (Некорректный файл версии PS2EXE): $VersionPath"
}

if ($PinnedVersion -ne $RequiredPs2ExeVersion) {
    Stop-Build (
        "Build expects PS2EXE $RequiredPs2ExeVersion, but ps2exe.version " +
        "contains $PinnedVersion. (Ожидается PS2EXE $RequiredPs2ExeVersion, " +
        "но ps2exe.version содержит $PinnedVersion.)"
    )
}

$AvailableModule = Get-Module -ListAvailable -Name "ps2exe" |
    Where-Object { $_.Version -eq $RequiredPs2ExeVersion } |
    Select-Object -First 1

if ($null -eq $AvailableModule) {
    Stop-Build (
        "PS2EXE $RequiredPs2ExeVersion is not installed. Install it once with: " +
        "Install-Module -Name ps2exe -RequiredVersion $RequiredPs2ExeVersion " +
        "-Scope CurrentUser. (PS2EXE $RequiredPs2ExeVersion не установлен. " +
        "Установите его один раз для CurrentUser.)"
    )
}

Assert-ParserClean -Paths @(
    $CorePath,
    $GuiPath,
    $TestPath,
    $BuildScriptPath
)

if ($Clean) {
    Remove-GeneratedDirectory `
        -Path $ObjectDirectory `
        -AllowedPaths $AllowedGeneratedDirectories
    Remove-GeneratedDirectory `
        -Path $DistDirectory `
        -AllowedPaths $AllowedGeneratedDirectories
}

[void][System.IO.Directory]::CreateDirectory($ObjectDirectory)
[void][System.IO.Directory]::CreateDirectory($DistDirectory)

if ($SkipTests) {
    Write-Warning "Tests were skipped for this development build. (Тесты пропущены для этой отладочной сборки.)"
}
else {
    Write-Host "Running regression tests / Запуск regression tests..."
    $WindowsPowerShell = Join-Path `
        $env:SystemRoot `
        "System32\WindowsPowerShell\v1.0\powershell.exe"
    & $WindowsPowerShell `
        -NoProfile `
        -STA `
        -ExecutionPolicy Bypass `
        -File $TestPath

    if ($LASTEXITCODE -ne 0) {
        Stop-Build "Regression tests failed with exit code $LASTEXITCODE. Build stopped. (Regression tests завершились с кодом $LASTEXITCODE. Сборка остановлена.)"
    }
}

$CorePayload = Get-CanonicalUtf8Payload -Path $CorePath
$GuiPayload = Get-CanonicalUtf8Payload -Path $GuiPath
$CoreSha256 = Get-Sha256Hex -Bytes $CorePayload.Bytes
$CoreBase64 = [Convert]::ToBase64String($CorePayload.Bytes)
$DecodedCoreBytes = [Convert]::FromBase64String($CoreBase64)
$DecodedCoreSha256 = Get-Sha256Hex -Bytes $DecodedCoreBytes

if ($DecodedCoreSha256 -ne $CoreSha256 -or
    $DecodedCoreBytes.Length -ne $CorePayload.Bytes.Length) {
    Stop-Build "Embedded Base64 verification failed (Проверка embedded Base64 не пройдена)."
}

$WrapperPrefix = @(
    "`$script:CleanFileNamesEmbeddedCoreBase64 = '$CoreBase64'",
    "`$script:CleanFileNamesEmbeddedCoreSha256 = '$CoreSha256'",
    "`$script:CleanFileNamesPackaged = `$true"
) -join "`r`n"
$WrapperText = $WrapperPrefix + "`r`n`r`n" + $GuiPayload.Text
[System.IO.File]::WriteAllText(
    $GeneratedScriptPath,
    $WrapperText,
    $Utf8WithBom
)

Write-Host "Semantic version: $SemanticVersion"
Write-Host "Windows file/assembly version: $WindowsVersion"
Write-Host "Canonical core SHA-256: $CoreSha256"
Write-Host "Embedded Base64 verification: PASS"

$ManifestPath = Join-Path $AvailableModule.ModuleBase "ps2exe.psd1"
$ImportedModule = Import-Module `
    -Name $ManifestPath `
    -Force `
    -PassThru

if ($ImportedModule.Version -ne $RequiredPs2ExeVersion) {
    Stop-Build "Loaded an unexpected PS2EXE version (Загружена неожиданная версия PS2EXE): $($ImportedModule.Version)"
}

$CompilerCommand = Get-Command "Invoke-ps2exe" -ErrorAction Stop

if ($CompilerCommand.Module.Version -ne $RequiredPs2ExeVersion) {
    Stop-Build "Invoke-ps2exe does not belong to PS2EXE $RequiredPs2ExeVersion. (Invoke-ps2exe не относится к PS2EXE $RequiredPs2ExeVersion.)"
}

foreach ($OldOutput in @(
    $ExePath,
    $ChecksumPath,
    "$ExePath.config",
    "$ExePath.pdb"
)) {
    if (Test-Path -LiteralPath $OldOutput) {
        Remove-Item -LiteralPath $OldOutput -Force
    }
}

$BuildSucceeded = $false

try {
    Write-Host "Compiling with PS2EXE $RequiredPs2ExeVersion..."
    Invoke-ps2exe `
        -inputFile $GeneratedScriptPath `
        -outputFile $ExePath `
        -noConsole `
        -STA `
        -x64 `
        -DPIAware `
        -noConfigFile `
        -title $ProductName `
        -product $ProductName `
        -description $Description `
        -version $WindowsVersion `
        -ErrorAction Stop

    if (-not (Test-Path -LiteralPath $ExePath -PathType Leaf) -or
        (Get-Item -LiteralPath $ExePath).Length -eq 0) {
        Stop-Build "PS2EXE did not produce the expected executable (PS2EXE не создал ожидаемый EXE): $ExePath"
    }

    if (Test-Path -LiteralPath "$ExePath.config") {
        Stop-Build "Unexpected external config file was produced (Создан неожиданный внешний config-файл)."
    }

    $Machine = Get-PeMachine -Path $ExePath

    if ($Machine -ne 0x8664) {
        Stop-Build (
            ("Expected an x64 PE image (0x8664), got 0x{0:X4}. " -f $Machine) +
            "(Ожидался x64 PE-образ.)"
        )
    }

    $VersionInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo(
        $ExePath
    )

    # PS2EXE 1.0.18 maps -title to FileDescription and -description to
    # FileVersionInfo.Comments. Validate the actual mapping instead of assuming
    # that -description controls the Windows FileDescription field.
    # (PS2EXE 1.0.18 записывает -title в FileDescription, а -description — в
    # FileVersionInfo.Comments. Проверяем фактическое отображение параметров.)
    if ($VersionInfo.FileVersion -ne $WindowsVersion -or
        $VersionInfo.ProductVersion -ne $WindowsVersion -or
        $VersionInfo.ProductName -ne $ProductName -or
        $VersionInfo.FileDescription -ne $ProductName -or
        $VersionInfo.Comments -ne $Description) {
        Stop-Build "Executable metadata validation failed (Проверка метаданных EXE не пройдена)."
    }

    $ExeBytes = [System.IO.File]::ReadAllBytes($ExePath)
    $ExeSha256 = Get-Sha256Hex -Bytes $ExeBytes
    $ChecksumText = "$ExeSha256  $ExeName`r`n"
    [System.IO.File]::WriteAllText(
        $ChecksumPath,
        $ChecksumText,
        $Utf8NoBom
    )
    $BuildSucceeded = $true

    Write-Host "Build PASS: $ExePath"
    Write-Host "EXE size: $($ExeBytes.Length) bytes"
    Write-Host "EXE SHA-256: $ExeSha256"
    Write-Host "Architecture: x64 (PE machine 0x8664)"
}
finally {
    if ($BuildSucceeded -and
        -not $KeepGeneratedScript -and
        (Test-Path -LiteralPath $GeneratedScriptPath)) {
        Remove-Item -LiteralPath $GeneratedScriptPath -Force
    }
}
