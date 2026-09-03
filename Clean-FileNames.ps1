param(
    [Parameter(Mandatory = $true)]
    [string]$Path,

    [switch]$Apply,

    [switch]$Strict,

    [switch]$IncludeDirectories
)

$ErrorActionPreference = "Stop"

# ============================================================
# Clean-FileNames-v5.ps1
#
# Универсальная проверка и безопасное переименование файлов
#
# v5: исправлено обнаружение Unicode-нормализации.
#     Например: и + U+0306 -> й (NFC).
#     Сравнение исходного и нового имени выполняется ordinal,
#     чтобы такие различия не пропускались.
#     Обычный режим сохраняет запятые, скобки, апострофы и тире.
# и, при необходимости, каталогов.
#
# По умолчанию работает ТОЛЬКО В РЕЖИМЕ ПРОВЕРКИ.
#
# Примеры:
#
# Проверить:
#   .\Clean-FileNames.ps1 -Path "D:\downloads\Конференции"
#
# Применить изменения:
#   .\Clean-FileNames.ps1 -Path "D:\downloads\Конференции" -Apply
#
# Строгая проверка:
#   .\Clean-FileNames.ps1 -Path "D:\downloads\Конференции" -Strict
#
# Строгий режим + переименование:
#   .\Clean-FileNames.ps1 -Path "D:\downloads\Конференции" -Strict -Apply
#
# Также обрабатывать имена папок:
#   .\Clean-FileNames.ps1 -Path "D:\downloads\Конференции" -IncludeDirectories
#
# В обычном режиме сохраняются: , ( ) ' — . внутри имени
# ============================================================

# ------------------------------------------------------------
# Проверка исходного пути
# ------------------------------------------------------------

if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    Write-Host ""
    Write-Host "ОШИБКА: папка не существует:" -ForegroundColor Red
    Write-Host $Path -ForegroundColor Yellow
    exit 1
}

$RootPath = (Resolve-Path -LiteralPath $Path).Path

# ------------------------------------------------------------
# Статистика
# ------------------------------------------------------------

$Stats = [ordered]@{
    Checked    = 0
    NeedRename = 0
    Renamed    = 0
    Errors     = 0
}

# ------------------------------------------------------------
# Зарезервированные имена Windows
# ------------------------------------------------------------

$ReservedNames = @(
    "CON","PRN","AUX","NUL",
    "COM1","COM2","COM3","COM4","COM5","COM6","COM7","COM8","COM9",
    "LPT1","LPT2","LPT3","LPT4","LPT5","LPT6","LPT7","LPT8","LPT9"
)

# ------------------------------------------------------------
# Преобразование имени в безопасный вид
# ------------------------------------------------------------

function Convert-ToSafeName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [switch]$StrictMode
    )

    $NewName = $Name

    # --------------------------------------------------------
    # Unicode NFC normalization.
    # Не используем NFKC, чтобы без необходимости не менять
    # типографику, математические символы, надстрочные знаки и т.п.
    # --------------------------------------------------------

    try {
        $NewName = $NewName.Normalize([System.Text.NormalizationForm]::FormC)
    }
    catch {
        # Если конкретная строка не нормализуется, продолжаем.
    }

    # --------------------------------------------------------
    # Невидимые / служебные Unicode-символы
    # --------------------------------------------------------

    $NewName = $NewName.Replace(([char]0x200B).ToString(), "") # Zero Width Space
    $NewName = $NewName.Replace(([char]0x200C).ToString(), "") # Zero Width Non-Joiner
    $NewName = $NewName.Replace(([char]0x200D).ToString(), "") # Zero Width Joiner
    $NewName = $NewName.Replace(([char]0x2060).ToString(), "") # Word Joiner
    $NewName = $NewName.Replace(([char]0xFEFF).ToString(), "") # BOM / ZWNBSP

    # Некоторые дополнительные форматирующие символы Unicode
    # (LRM, RLM и directional isolates/embeddings).
    $NewName = [regex]::Replace(
        $NewName,
        '[\u200E\u200F\u202A-\u202E\u2066-\u2069]',
        ''
    )

    # Неразрывные и похожие пробелы -> обычный пробел
    $NewName = $NewName.Replace(([char]0x00A0).ToString(), " ")
    $NewName = $NewName.Replace(([char]0x202F).ToString(), " ")
    $NewName = $NewName.Replace(([char]0x2007).ToString(), " ")

    # Управляющие символы ASCII 0-31 и DEL
    $NewName = [regex]::Replace($NewName, '[\x00-\x1F\x7F]', '')

    # --------------------------------------------------------
    # Unicode-аналоги символов, способных создавать проблемы
    # в Windows / SCP / SFTP.
    #
    # В частности:
    #   ：  U+FF1A FULLWIDTH COLON
    #   ／  U+FF0F FULLWIDTH SOLIDUS
    #   ＼  U+FF3C FULLWIDTH REVERSE SOLIDUS
    #   ｜  U+FF5C FULLWIDTH VERTICAL LINE
    #   ？  U+FF1F FULLWIDTH QUESTION MARK
    #   ＊  U+FF0A FULLWIDTH ASTERISK
    #   ＜  U+FF1C FULLWIDTH LESS-THAN SIGN
    #   ＞  U+FF1E FULLWIDTH GREATER-THAN SIGN
    #   ＂  U+FF02 FULLWIDTH QUOTATION MARK
    #
    # Также учитываем несколько похожих slash/colon символов.
    # --------------------------------------------------------

    # Colon-like -> безопасный разделитель
    $NewName = $NewName.Replace(([char]0xFF1A).ToString(), " - ") # ：
    $NewName = $NewName.Replace(([char]0xFE55).ToString(), " - ") # ﹕

    # Slash-like -> безопасный разделитель
    $NewName = $NewName.Replace(([char]0xFF0F).ToString(), " - ") # ／
    $NewName = $NewName.Replace(([char]0xFF3C).ToString(), " - ") # ＼
    $NewName = $NewName.Replace(([char]0x2215).ToString(), " - ") # ∕
    $NewName = $NewName.Replace(([char]0x2044).ToString(), " - ") # ⁄

    # Pipe-like
    $NewName = $NewName.Replace(([char]0xFF5C).ToString(), " - ") # ｜

    # Question-mark variants -> удалить
    $NewName = $NewName.Replace(([char]0xFF1F).ToString(), "")    # ？ FULLWIDTH QUESTION MARK
    $NewName = $NewName.Replace(([char]0xFE56).ToString(), "")    # ﹖ SMALL QUESTION MARK
    $NewName = $NewName.Replace(([char]0x061F).ToString(), "")    # ؟ ARABIC QUESTION MARK
    $NewName = $NewName.Replace(([char]0x2E2E).ToString(), "")    # ⸮ REVERSED QUESTION MARK

    # Остальные fullwidth-аналоги
    $NewName = $NewName.Replace(([char]0xFF0A).ToString(), "")    # ＊
    $NewName = $NewName.Replace(([char]0xFF1C).ToString(), "")    # ＜
    $NewName = $NewName.Replace(([char]0xFF1E).ToString(), "")    # ＞
    $NewName = $NewName.Replace(([char]0xFF02).ToString(), "")    # ＂

    # Запятые в обычном режиме НЕ трогаем.
    # Они допустимы в Windows/Linux и полезны для читаемости имён.
    # Unicode-варианты запятых также сохраняются.

    # --------------------------------------------------------
    # Обычные символы, запрещённые Windows
    # или потенциально проблемные для транспорта файлов
    # --------------------------------------------------------

    $NewName = $NewName -replace ':', ' - '
    $NewName = $NewName -replace '[<>"]', ''
    $NewName = $NewName -replace '[\\/|]', ' - '
    # Обычные ASCII-вопросительный знак и звёздочка
    $NewName = $NewName -replace '[?*]', ''

    # --------------------------------------------------------
    # Типографские кавычки
    # --------------------------------------------------------

    $NewName = $NewName -replace '[“”„«»]', ''
    $NewName = $NewName -replace '[‘’‚‛]', "'"

    # --------------------------------------------------------
    # Strict: дополнительно убираем shell-sensitive символы.
    # Обычный режим их НЕ трогает.
    # --------------------------------------------------------

    if ($StrictMode) {
        # Апострофы и скобки
        $NewName = $NewName -replace "'", ''
        $NewName = $NewName -replace '[\(\)\[\]\{\}]', ' '

        # Запятые и их распространённые Unicode-варианты
        $NewName = $NewName.Replace(",", " ")
        $NewName = $NewName.Replace(([char]0xFF0C).ToString(), " ") # ，
        $NewName = $NewName.Replace(([char]0xFE50).ToString(), " ") # ﹐
        $NewName = $NewName.Replace(([char]0x3001).ToString(), " ") # 、
        $NewName = $NewName.Replace(([char]0x060C).ToString(), " ") # ،

        # Остальные shell-sensitive символы
        $NewName = $NewName -replace ';', ' '
        $NewName = $NewName -replace '&', ' and '
        $NewName = $NewName -replace '[$!`^~]', ''
    }

    # --------------------------------------------------------
    # Нормализация пробелов и разделителей
    # --------------------------------------------------------

    $NewName = [regex]::Replace($NewName, '\s+', ' ')
    $NewName = [regex]::Replace($NewName, '\s*-\s*-\s*', ' - ')
    $NewName = $NewName.Trim()

    # Windows не допускает точки и пробелы в конце имени.
    $NewName = $NewName.TrimEnd([char[]]@('.', ' '))

    # Повторная нормализация после всех замен.
    $NewName = [regex]::Replace($NewName, '\s+', ' ').Trim()

    if ([string]::IsNullOrWhiteSpace($NewName)) {
        $NewName = "unnamed"
    }

    # Зарезервированные имена Windows.
    $ReservedCheck = $NewName

    if ($ReservedCheck.Contains(".")) {
        $ReservedCheck = [System.IO.Path]::GetFileNameWithoutExtension($ReservedCheck)
    }

    if ($ReservedNames -contains $ReservedCheck.ToUpperInvariant()) {
        $NewName = "_$NewName"
    }

    return $NewName
}

# ------------------------------------------------------------
# Получение уникального имени при совпадениях
# ------------------------------------------------------------

function Get-UniqueName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Directory,

        [Parameter(Mandatory = $true)]
        [string]$NewName,

        [Parameter(Mandatory = $true)]
        [string]$OriginalFullName,

        [switch]$IsDirectory
    )

    $Candidate = $NewName
    $Counter = 1

    if ($IsDirectory) {
        while ($true) {
            $CandidatePath = Join-Path -Path $Directory -ChildPath $Candidate

            if (
                -not (Test-Path -LiteralPath $CandidatePath) -or
                ([string]::Equals(
                    $CandidatePath,
                    $OriginalFullName,
                    [System.StringComparison]::OrdinalIgnoreCase
                ))
            ) {
                return $Candidate
            }

            $Candidate = "$NewName ($Counter)"
            $Counter++
        }
    }

    $Extension = [System.IO.Path]::GetExtension($NewName)
    $BaseName = [System.IO.Path]::GetFileNameWithoutExtension($NewName)

    while ($true) {
        $CandidatePath = Join-Path -Path $Directory -ChildPath $Candidate

        if (
            -not (Test-Path -LiteralPath $CandidatePath) -or
            ([string]::Equals(
                $CandidatePath,
                $OriginalFullName,
                [System.StringComparison]::OrdinalIgnoreCase
            ))
        ) {
            return $Candidate
        }

        $Candidate = "$BaseName ($Counter)$Extension"
        $Counter++
    }
}

# ------------------------------------------------------------
# Обработка файла
# ------------------------------------------------------------

function Process-File {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo]$File
    )

    $Stats.Checked++

    $OriginalName = $File.Name
    $Extension = $File.Extension

    if ([string]::IsNullOrEmpty($Extension)) {
        $BaseName = $OriginalName
    }
    else {
        $BaseName = $OriginalName.Substring(
            0,
            $OriginalName.Length - $Extension.Length
        )
    }

    $SafeBaseName = Convert-ToSafeName -Name $BaseName -StrictMode:$Strict

    # Расширение стараемся сохранить как есть,
    # удаляя только явно посторонние символы.
    $SafeExtension = $Extension

    if (-not [string]::IsNullOrEmpty($SafeExtension)) {
        $SafeExtension = [regex]::Replace(
            $SafeExtension,
            '[^.\p{L}\p{Nd}_-]',
            ''
        )
    }

    $NewName = "$SafeBaseName$SafeExtension"

    # Ограничиваем имя файла 200 символами, чтобы оставить
    # запас для полного пути и совместимости с различными клиентами.
    $MaxFileNameLength = 200

    if ($NewName.Length -gt $MaxFileNameLength) {
        $AvailableLength = $MaxFileNameLength - $SafeExtension.Length

        if ($AvailableLength -lt 1) {
            $AvailableLength = 1
        }

        $SafeBaseName = $SafeBaseName.Substring(
            0,
            [Math]::Min($SafeBaseName.Length, $AvailableLength)
        ).TrimEnd([char[]]@('.', ' '))

        $NewName = "$SafeBaseName$SafeExtension"
    }

    # ВАЖНО: используем точное ordinal-сравнение.
    # PowerShell -eq/-ceq может считать канонически эквивалентные
    # Unicode-строки одинаковыми, например:
    #   "и" + U+0306  и  "й"
    # Нам нужно обнаруживать такую разницу и физически нормализовать имя.
    if ([string]::Equals(
        $OriginalName,
        $NewName,
        [System.StringComparison]::Ordinal
    )) {
        return
    }

    $Stats.NeedRename++

    $NewName = Get-UniqueName `
        -Directory $File.DirectoryName `
        -NewName $NewName `
        -OriginalFullName $File.FullName

    Write-Host ""
    Write-Host "ФАЙЛ:" -ForegroundColor Cyan
    Write-Host "  Было:  " -NoNewline
    Write-Host $OriginalName -ForegroundColor Yellow
    Write-Host "  Будет: " -NoNewline
    Write-Host $NewName -ForegroundColor Green

    # Если различие вызвано только Unicode-нормализацией,
    # отдельно сообщаем об этом: визуально имена могут выглядеть одинаково.
    try {
        $NormalizedOriginal = $OriginalName.Normalize(
            [System.Text.NormalizationForm]::FormC
        )

        if (
            -not [string]::Equals(
                $OriginalName,
                $NewName,
                [System.StringComparison]::Ordinal
            ) -and
            [string]::Equals(
                $NormalizedOriginal,
                $NewName,
                [System.StringComparison]::Ordinal
            )
        ) {
            Write-Host "  Причина: Unicode NFC normalization" -ForegroundColor DarkYellow
        }
    }
    catch {
    }

    if (-not $Apply) {
        return
    }

    try {
        Rename-Item `
            -LiteralPath $File.FullName `
            -NewName $NewName `
            -ErrorAction Stop

        $Stats.Renamed++
    }
    catch {
        $Stats.Errors++

        Write-Host "  ОШИБКА ПЕРЕИМЕНОВАНИЯ:" -ForegroundColor Red
        Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ------------------------------------------------------------
# Обработка каталога
# ------------------------------------------------------------

function Process-Directory {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.DirectoryInfo]$Directory
    )

    $Stats.Checked++

    $OriginalName = $Directory.Name
    $NewName = Convert-ToSafeName -Name $OriginalName -StrictMode:$Strict

    # ВАЖНО: используем точное ordinal-сравнение.
    # PowerShell -eq/-ceq может считать канонически эквивалентные
    # Unicode-строки одинаковыми, например:
    #   "и" + U+0306  и  "й"
    # Нам нужно обнаруживать такую разницу и физически нормализовать имя.
    if ([string]::Equals(
        $OriginalName,
        $NewName,
        [System.StringComparison]::Ordinal
    )) {
        return
    }

    $Stats.NeedRename++

    $ParentDirectory = $Directory.Parent.FullName

    $NewName = Get-UniqueName `
        -Directory $ParentDirectory `
        -NewName $NewName `
        -OriginalFullName $Directory.FullName `
        -IsDirectory

    Write-Host ""
    Write-Host "ПАПКА:" -ForegroundColor Magenta
    Write-Host "  Было:  " -NoNewline
    Write-Host $OriginalName -ForegroundColor Yellow
    Write-Host "  Будет: " -NoNewline
    Write-Host $NewName -ForegroundColor Green

    # Если различие вызвано только Unicode-нормализацией,
    # отдельно сообщаем об этом: визуально имена могут выглядеть одинаково.
    try {
        $NormalizedOriginal = $OriginalName.Normalize(
            [System.Text.NormalizationForm]::FormC
        )

        if (
            -not [string]::Equals(
                $OriginalName,
                $NewName,
                [System.StringComparison]::Ordinal
            ) -and
            [string]::Equals(
                $NormalizedOriginal,
                $NewName,
                [System.StringComparison]::Ordinal
            )
        ) {
            Write-Host "  Причина: Unicode NFC normalization" -ForegroundColor DarkYellow
        }
    }
    catch {
    }

    if (-not $Apply) {
        return
    }

    try {
        Rename-Item `
            -LiteralPath $Directory.FullName `
            -NewName $NewName `
            -ErrorAction Stop

        $Stats.Renamed++
    }
    catch {
        $Stats.Errors++

        Write-Host "  ОШИБКА ПЕРЕИМЕНОВАНИЯ:" -ForegroundColor Red
        Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ============================================================
# Запуск
# ============================================================

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " ПРОВЕРКА ИМЁН ФАЙЛОВ" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Папка:              $RootPath"
Write-Host "Строгий режим:      $Strict"
Write-Host "Проверка каталогов: $IncludeDirectories"

if ($Apply) {
    Write-Host "Режим:              ПРИМЕНЕНИЕ ИЗМЕНЕНИЙ" -ForegroundColor Red
}
else {
    Write-Host "Режим:              ТОЛЬКО ПРОВЕРКА" -ForegroundColor Green
}

Write-Host ""

# ------------------------------------------------------------
# Файлы
# ------------------------------------------------------------

try {
    $Files = @(
        Get-ChildItem `
            -LiteralPath $RootPath `
            -File `
            -Recurse `
            -Force `
            -ErrorAction Stop
    )
}
catch {
    Write-Host "Не удалось получить список файлов:" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}

foreach ($File in $Files) {
    try {
        Process-File -File $File
    }
    catch {
        $Stats.Errors++

        Write-Host ""
        Write-Host "ОШИБКА ОБРАБОТКИ ФАЙЛА:" -ForegroundColor Red
        Write-Host "  $($File.FullName)" -ForegroundColor Yellow
        Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ------------------------------------------------------------
# Каталоги
# ------------------------------------------------------------

if ($IncludeDirectories) {
    try {
        $Directories = @(
            Get-ChildItem `
                -LiteralPath $RootPath `
                -Directory `
                -Recurse `
                -Force `
                -ErrorAction Stop |
            Sort-Object { $_.FullName.Length } -Descending
        )
    }
    catch {
        Write-Host "Не удалось получить список каталогов:" -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
        exit 1
    }

    foreach ($Directory in $Directories) {
        try {
            Process-Directory -Directory $Directory
        }
        catch {
            $Stats.Errors++

            Write-Host ""
            Write-Host "ОШИБКА ОБРАБОТКИ ПАПКИ:" -ForegroundColor Red
            Write-Host "  $($Directory.FullName)" -ForegroundColor Yellow
            Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

# ============================================================
# Результат
# ============================================================

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " РЕЗУЛЬТАТ" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Проверено:           $($Stats.Checked)"
Write-Host "Требуют изменения:  $($Stats.NeedRename)"
Write-Host "Переименовано:       $($Stats.Renamed)"
Write-Host "Ошибок:              $($Stats.Errors)"
Write-Host ""

if (-not $Apply) {
    Write-Host "Изменения НЕ применялись." -ForegroundColor Yellow
    Write-Host "Для реального переименования добавьте параметр -Apply."
    Write-Host ""
}
