param(
    [Parameter(Mandatory = $true)]
    [string]$Path,

    [switch]$Apply,

    [switch]$Strict,

    [switch]$IncludeDirectories
)

$ErrorActionPreference = "Stop"

# UTF-8 encoder with strict validation. Invalid UTF-16 input (for example,
# an unpaired surrogate) raises an error instead of being silently replaced.
$Utf8EncodingStrict = New-Object System.Text.UTF8Encoding($false, $true)

# ============================================================
# Clean-FileNames.ps1 (v6 development)
#
# Универсальная проверка и безопасное переименование файлов
#
# v6: ограничение длины имени и конфликтные суффиксы учитывают
#     размер в UTF-8 байтах.
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

    # ZWSP separates words, so replace it with a visible space. ZWNJ and ZWJ
    # are meaningful in natural-language text and emoji sequences; preserve them.
    $NewName = $NewName.Replace(([char]0x200B).ToString(), " ") # Zero Width Space

    $NewName = $NewName.Replace(([char]0x2060).ToString(), "") # Word Joiner
    $NewName = $NewName.Replace(([char]0xFEFF).ToString(), "") # BOM / ZWNBSP

    # Некоторые дополнительные форматирующие символы Unicode
    # (LRM, RLM и directional isolates/embeddings).
    $NewName = [regex]::Replace(
        $NewName,
        '[\u061C\u200E\u200F\u202A-\u202E\u2066-\u2069]',
        ''
    )

    # Неразрывные и другие Unicode-пробелы -> обычный ASCII-пробел.
    $NewName = [regex]::Replace(
        $NewName,
        '[\u00A0\u2000-\u200A\u202F\u205F\u3000]',
        ' '
    )

    # TAB, CR и LF разделяют текст: сначала заменяем их пробелами, чтобы
    # удаление остальных ASCII controls не склеивало соседние слова.
    $NewName = $NewName.Replace(([char]0x0009).ToString(), " ")
    $NewName = $NewName.Replace(([char]0x000D).ToString(), " ")
    $NewName = $NewName.Replace(([char]0x000A).ToString(), " ")

    # Управляющие символы ASCII 0-31 и DEL
    $NewName = [regex]::Replace($NewName, '[\x00-\x1F\x7F]', '')

    # SOFT HYPHEN невидим в большинстве интерфейсов: делаем его явным.
    $NewName = $NewName.Replace(([char]0x00AD).ToString(), "-")

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
    $NewName = $NewName.Replace(([char]0xFE68).ToString(), " - ") # ﹨

    # Pipe-like
    $NewName = $NewName.Replace(([char]0xFF5C).ToString(), " - ") # ｜

    # Compatibility-варианты запрещённых question/asterisk/angle/quote
    # заменяем пробелами. Безопасную языковую пунктуацию сохраняем.
    $NewName = $NewName.Replace(([char]0xFF1F).ToString(), " ") # ？
    $NewName = $NewName.Replace(([char]0xFE56).ToString(), " ") # ﹖
    $NewName = $NewName.Replace(([char]0xFF0A).ToString(), " ") # ＊
    $NewName = $NewName.Replace(([char]0xFE61).ToString(), " ") # ﹡
    $NewName = $NewName.Replace(([char]0xFF1C).ToString(), " ") # ＜
    $NewName = $NewName.Replace(([char]0xFE64).ToString(), " ") # ﹤
    $NewName = $NewName.Replace(([char]0xFF1E).ToString(), " ") # ＞
    $NewName = $NewName.Replace(([char]0xFE65).ToString(), " ") # ﹥
    $NewName = $NewName.Replace(([char]0xFF02).ToString(), " ") # ＂

    # Запятые в Common cleanup и Strict post-pass НЕ трогаем.
    # Они допустимы в Windows/Linux и полезны для читаемости имён.
    # Unicode-варианты запятых также сохраняются.

    # --------------------------------------------------------
    # Обычные символы, запрещённые Windows
    # или потенциально проблемные для транспорта файлов
    # --------------------------------------------------------

    $NewName = $NewName -replace ':', ' - '
    $NewName = $NewName -replace '[\\/|]', ' - '
    # Запрещённые ASCII-знаки разделяют соседний текст.
    $NewName = $NewName -replace '[<>"]', ' '
    $NewName = $NewName -replace '[?*]', ' '

    # --------------------------------------------------------
    # Безопасная языковая пунктуация
    # --------------------------------------------------------

    # Common cleanup сохраняет типографские кавычки, апострофы, primes,
    # смысловые slash/pipe/colon-символы, variation selectors и combining
    # marks. NFC уже применён выше; глобальную NFKC не используем.

    # --------------------------------------------------------
    # Strict post-pass: уменьшение количества shell-sensitive
    # metacharacters. Это не отменяет обязательное quoting имён файлов.
    # --------------------------------------------------------

    if ($StrictMode) {
        # Все распространённые варианты апострофа приводим к U+02BC.
        # Он сохраняет визуальное разделение и не является ASCII quote.
        $NewName = [regex]::Replace(
            $NewName,
            '[\u0027\u2018-\u201B\u02BC\uFF07]',
            ([char]0x02BC).ToString()
        )

        # Shell grouping, glob и brace characters -> разделитель.
        $NewName = $NewName -replace '[\(\)\[\]\{\}]', ' '

        # Закрывающая скобка перед сохраняемой запятой не должна оставлять
        # искусственный пробел: "[Live]," -> "Live,".
        $NewName = [regex]::Replace(
            $NewName,
            '\s+(?=[,\uFF0C\uFE50\u3001\u060C])',
            ''
        )

        # Видимые метасимволы заменяем, а не удаляем без разделителя.
        # Плюс служит языково-нейтральной заменой ampersand.
        $NewName = $NewName -replace ';', ' '
        $NewName = $NewName -replace '&', ' + '
        $NewName = [regex]::Replace(
            $NewName,
            '[\u0024\u0021\u0060\u005E\u007E]',
            ' '
        )
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
# Размер строки в UTF-8 байтах
# ------------------------------------------------------------

function Get-Utf8ByteCount {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value
    )

    # Строгий encoder также проверяет корректность UTF-16: одиночные
    # surrogate code units не заменяются символом U+FFFD незаметно.
    return $Utf8EncodingStrict.GetByteCount($Value)
}

# ------------------------------------------------------------
# Безопасное усечение строки по размеру в UTF-8
# ------------------------------------------------------------

function Limit-StringToUtf8ByteCount {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value,

        [Parameter(Mandatory = $true)]
        [ValidateRange(0, 2147483647)]
        [int]$MaxUtf8Bytes
    )

    $ValueBytes = Get-Utf8ByteCount -Value $Value

    if ($ValueBytes -le $MaxUtf8Bytes) {
        return $Value
    }

    $Builder = New-Object System.Text.StringBuilder
    $UsedBytes = 0

    # Перебираем Unicode text elements, а не UTF-16 code units.
    # Поэтому усечение не разрезает surrogate pair и по возможности
    # сохраняет базовый символ вместе с его combining marks.
    $Enumerator = [System.Globalization.StringInfo]::GetTextElementEnumerator(
        $Value
    )

    while ($Enumerator.MoveNext()) {
        $TextElement = $Enumerator.GetTextElement()
        $TextElementBytes = Get-Utf8ByteCount -Value $TextElement

        if (($UsedBytes + $TextElementBytes) -gt $MaxUtf8Bytes) {
            break
        }

        [void]$Builder.Append($TextElement)
        $UsedBytes += $TextElementBytes
    }

    return $Builder.ToString()
}

# ------------------------------------------------------------
# Ограничение полного имени файла с сохранением расширения
# ------------------------------------------------------------

function Limit-FileNameToUtf8ByteCount {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$BaseName,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Extension,

        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 2147483647)]
        [int]$MaxUtf8Bytes
    )

    $FullName = "$BaseName$Extension"

    if ((Get-Utf8ByteCount -Value $FullName) -le $MaxUtf8Bytes) {
        return $FullName
    }

    # Сначала сохраняем расширение целиком и отдаём оставшийся byte budget
    # базовой части имени.
    $ExtensionBytes = Get-Utf8ByteCount -Value $Extension
    $AvailableBaseBytes = $MaxUtf8Bytes - $ExtensionBytes
    $LimitedBaseName = ""

    if ($AvailableBaseBytes -gt 0) {
        $LimitedBaseName = Limit-StringToUtf8ByteCount `
            -Value $BaseName `
            -MaxUtf8Bytes $AvailableBaseBytes

        $LimitedBaseName = $LimitedBaseName.TrimEnd(
            [char[]]@('.', ' ')
        )
    }

    if (-not [string]::IsNullOrWhiteSpace($LimitedBaseName)) {
        return "$LimitedBaseName$Extension"
    }

    # Полное расширение иногда не оставляет места даже для одного
    # пригодного text element базового имени. В этом редком случае
    # сохраняем безопасную базовую часть и максимально возможный префикс
    # расширения. Это гарантирует соблюдение лимита и непустое имя.
    $FallbackBaseName = Limit-StringToUtf8ByteCount `
        -Value "unnamed" `
        -MaxUtf8Bytes $MaxUtf8Bytes

    $FallbackBytes = Get-Utf8ByteCount -Value $FallbackBaseName
    $AvailableExtensionBytes = $MaxUtf8Bytes - $FallbackBytes
    $LimitedExtension = Limit-StringToUtf8ByteCount `
        -Value $Extension `
        -MaxUtf8Bytes $AvailableExtensionBytes

    return "$FallbackBaseName$LimitedExtension"
}

# ------------------------------------------------------------
# Формирование имени с конфликтным суффиксом
# ------------------------------------------------------------

function New-ConflictCandidateName {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$BaseName,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Extension,

        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 9223372036854775807)]
        [long]$Counter,

        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 2147483647)]
        [int]$MaxUtf8Bytes
    )

    # Суффикс строится заново для каждого значения счётчика. Поэтому
    # переходы (9) -> (10) и (99) -> (100) автоматически уменьшают
    # доступный базовой части byte budget на фактическую разницу.
    $ConflictSuffix = " ($Counter)"
    $SuffixBytes = Get-Utf8ByteCount -Value $ConflictSuffix
    $AvailableNameBytes = $MaxUtf8Bytes - $SuffixBytes

    if ($AvailableNameBytes -lt 1) {
        throw "Конфликтный суффикс не помещается в лимит имени."
    }

    # Расширение сохраняем полностью, когда вместе с суффиксом оно
    # оставляет место хотя бы для одного пригодного text element базы.
    $ExtensionBytes = Get-Utf8ByteCount -Value $Extension
    $AvailableBaseBytes = $AvailableNameBytes - $ExtensionBytes
    $LimitedBaseName = ""

    if ($AvailableBaseBytes -gt 0) {
        $LimitedBaseName = Limit-StringToUtf8ByteCount `
            -Value $BaseName `
            -MaxUtf8Bytes $AvailableBaseBytes

        $LimitedBaseName = $LimitedBaseName.TrimEnd(
            [char[]]@('.', ' ')
        )
    }

    if (-not [string]::IsNullOrWhiteSpace($LimitedBaseName)) {
        return "$LimitedBaseName$ConflictSuffix$Extension"
    }

    # Если полное расширение не оставляет места для базы, используем
    # минимальную безопасную однобайтовую базу. Остаток отдаём расширению:
    # его префикс усекается только по границам Unicode text elements.
    $FallbackBaseName = "_"
    $FallbackBytes = Get-Utf8ByteCount -Value $FallbackBaseName
    $AvailableExtensionBytes = $AvailableNameBytes - $FallbackBytes
    $LimitedExtension = Limit-StringToUtf8ByteCount `
        -Value $Extension `
        -MaxUtf8Bytes $AvailableExtensionBytes

    return "$FallbackBaseName$ConflictSuffix$LimitedExtension"
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

    $MaxNameUtf8Bytes = 255
    $Extension = ""
    $BaseName = $NewName

    if (-not $IsDirectory) {
        $Extension = [System.IO.Path]::GetExtension($NewName)
        $BaseName = [System.IO.Path]::GetFileNameWithoutExtension($NewName)
    }

    # Для файлов входное имя уже ограничено в Process-File. Повторное
    # ограничение здесь также гарантирует лимит при прямом вызове функции.
    # Для каталогов эта проверка не позволяет вернуть длинный кандидат
    # ещё до появления первого конфликтного суффикса.
    $Candidate = Limit-FileNameToUtf8ByteCount `
        -BaseName $BaseName `
        -Extension $Extension `
        -MaxUtf8Bytes $MaxNameUtf8Bytes

    $Counter = 1

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

        $Candidate = New-ConflictCandidateName `
            -BaseName $BaseName `
            -Extension $Extension `
            -Counter $Counter `
            -MaxUtf8Bytes $MaxNameUtf8Bytes

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

    # Одиночная ведущая точка обозначает dotfile, а не расширение.
    # Для остальных имён сохраняем прежнюю семантику последней точки:
    # .config.json -> .config + .json, archive.tar.gz -> archive.tar + .gz.
    $IsSimpleDotfile = (
        $OriginalName.Length -gt 1 -and
        $OriginalName[0] -eq [char]0x002E -and
        -not $OriginalName.Substring(1).Contains(".")
    )

    $LastDotIndex = $OriginalName.LastIndexOf([char]0x002E)

    if (
        $IsSimpleDotfile -or
        $LastDotIndex -lt 0 -or
        $LastDotIndex -eq ($OriginalName.Length - 1)
    ) {
        $BaseName = $OriginalName
        $Extension = ""
    }
    else {
        $BaseName = $OriginalName.Substring(0, $LastDotIndex)
        $Extension = $OriginalName.Substring($LastDotIndex)
    }

    $SafeBaseName = Convert-ToSafeName -Name $BaseName -StrictMode:$Strict

    # Ведущую точку не пропускаем через очистку: нормализуем только body.
    # В отличие от старого category allowlist, эта политика сохраняет
    # национальные буквы, combining marks, emoji и безопасные символы Unicode.
    $SafeExtension = ""

    if (-not [string]::IsNullOrEmpty($Extension)) {
        $ExtensionBody = $Extension.Substring(1)

        # NFC применяется только к extension body. Глобальную NFKC
        # не используем, чтобы не менять совместимые Unicode-символы.
        try {
            $ExtensionBody = $ExtensionBody.Normalize(
                [System.Text.NormalizationForm]::FormC
            )
        }
        catch {
            # Если конкретная строка не нормализуется, продолжаем очистку.
        }

        # Controls, bidi formatting, WORD JOINER, BOM и ZWSP не несут
        # полезной информации для расширения. ZWNJ, ZWJ, variation selectors
        # и combining marks намеренно не входят в удаляемые наборы.
        $ExtensionBody = [regex]::Replace(
            $ExtensionBody,
            '[\x00-\x1F\x7F]',
            ''
        )
        $ExtensionBody = [regex]::Replace(
            $ExtensionBody,
            '[\u061C\u200E\u200F\u202A-\u202E\u2066-\u2069]',
            ''
        )
        $ExtensionBody = $ExtensionBody.Replace(([char]0x200B).ToString(), "")
        $ExtensionBody = $ExtensionBody.Replace(([char]0x2060).ToString(), "")
        $ExtensionBody = $ExtensionBody.Replace(([char]0xFEFF).ToString(), "")

        # Пробелы и запрещённые Windows символы в extension body удаляем,
        # не превращая короткое расширение в отдельную фразу с разделителями.
        $ExtensionBody = [regex]::Replace($ExtensionBody, '\s+', '')
        $ExtensionBody = [regex]::Replace(
            $ExtensionBody,
            '[<>:"/\\|?*]',
            ''
        )
        $ExtensionBody = [regex]::Replace(
            $ExtensionBody,
            '[\uFF1A\uFE55\uFF0F\uFF3C\uFE68\uFF5C' +
            '\uFF1F\uFE56\uFF0A\uFE61\uFF1C\uFE64' +
            '\uFF1E\uFE65\uFF02]',
            ''
        )

        # Strict post-pass для extension body также только уменьшает
        # количество shell-sensitive metacharacters. Quoting полного имени
        # по-прежнему обязателен. Пробелы в расширение не добавляем.
        if ($Strict) {
            $ExtensionBody = [regex]::Replace(
                $ExtensionBody,
                '[\u0027\u2018-\u201B\u02BC\uFF07]',
                ([char]0x02BC).ToString()
            )
            $ExtensionBody = [regex]::Replace(
                $ExtensionBody,
                '[\(\)\[\]\{\};\u0024\u0021\u0060\u005E\u007E]+',
                '-'
            )
            $ExtensionBody = $ExtensionBody.Replace("&", "+")
        }

        # Не оставляем одиночную ведущую точку, если body полностью очищен.
        if (-not [string]::IsNullOrEmpty($ExtensionBody)) {
            $SafeExtension = ".$ExtensionBody"
        }
    }

    # ext4 допускает до 255 байт на один компонент имени. Здесь ограничиваем
    # исходный кандидат; Get-UniqueName отдельно пересчитает точный бюджет,
    # если к имени потребуется добавить конфликтный суффикс.
    $MaxFileNameUtf8Bytes = 255

    $NewName = Limit-FileNameToUtf8ByteCount `
        -BaseName $SafeBaseName `
        -Extension $SafeExtension `
        -MaxUtf8Bytes $MaxFileNameUtf8Bytes

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

    # ext4 допускает максимум 255 UTF-8 байт на один компонент имени.
    # Для каталога расширения нет, поэтому ограничиваем очищенное имя
    # напрямую по границам Unicode text elements до сравнения с исходным.
    $MaxDirectoryNameUtf8Bytes = 255
    $NewName = Limit-StringToUtf8ByteCount `
        -Value $NewName `
        -MaxUtf8Bytes $MaxDirectoryNameUtf8Bytes

    $NewName = $NewName.TrimEnd([char[]]@('.', ' '))

    if ([string]::IsNullOrWhiteSpace($NewName)) {
        $NewName = "unnamed"
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
