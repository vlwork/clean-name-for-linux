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
# (UTF-8 encoder со строгой проверкой. Некорректные входные данные UTF-16,
# например одиночный surrogate, вызывают ошибку вместо неявной замены.)
$Utf8EncodingStrict = New-Object System.Text.UTF8Encoding($false, $true)

# ============================================================
# Clean File Names — v6 development
# (Очистка имён файлов — разработка v6)
#
# Checks and safely normalizes file names for transfer between
# Windows and Linux filesystems. Directories can also be processed.
# (Проверяет и безопасно нормализует имена файлов для переноса
# между файловыми системами Windows и Linux. Также может обрабатывать каталоги.)
#
# v6 measures name limits and conflict suffixes in UTF-8 bytes.
# (В v6 ограничения имён и конфликтные суффиксы учитывают размер в UTF-8 байтах.)
#
# v5 added reliable Unicode normalization detection. Example:
# и + U+0306 -> й (NFC). Original and normalized names are compared
# using ordinal semantics so these changes are not skipped.
# (В v5 добавлено надёжное обнаружение Unicode-нормализации. Например:
# и + U+0306 -> й (NFC). Исходное и нормализованное имена сравниваются
# с использованием ordinal-семантики, чтобы такие изменения не пропускались.)
#
# By default the script runs in Dry Run mode and does not rename anything.
# (По умолчанию скрипт работает в режиме Dry Run и ничего не переименовывает.)
#
# Usage examples (Примеры запуска):
#
# Check only (Только проверка):
#   .\Clean-FileNames.ps1 -Path "D:\downloads\Конференции"
#
# Apply changes (Применить изменения):
#   .\Clean-FileNames.ps1 -Path "D:\downloads\Конференции" -Apply
#
# Check in Strict mode (Проверить в строгом режиме):
#   .\Clean-FileNames.ps1 -Path "D:\downloads\Конференции" -Strict
#
# Apply changes in Strict mode (Применить изменения в строгом режиме):
#   .\Clean-FileNames.ps1 -Path "D:\downloads\Конференции" -Strict -Apply
#
# Include directory names (Обрабатывать имена каталогов):
#   .\Clean-FileNames.ps1 -Path "D:\downloads\Конференции" -IncludeDirectories
#
# Normal mode preserves , ( ) ' — and internal periods.
# (Обычный режим сохраняет , ( ) ' — и точки внутри имени.)
# ============================================================

# ------------------------------------------------------------
# Source path validation (Проверка исходного пути)
# ------------------------------------------------------------

if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    Write-Host ""
    Write-Host "ERROR: Folder does not exist (ОШИБКА: папка не существует):" -ForegroundColor Red
    Write-Host $Path -ForegroundColor Yellow
    exit 1
}

$RootPath = (Resolve-Path -LiteralPath $Path).Path

# ------------------------------------------------------------
# Statistics (Статистика)
# ------------------------------------------------------------

$Stats = [ordered]@{
    Checked    = 0
    NeedRename = 0
    Renamed    = 0
    Errors     = 0
}

# ------------------------------------------------------------
# Reserved Windows names (Зарезервированные имена Windows)
# ------------------------------------------------------------

$ReservedNames = @(
    "CON","PRN","AUX","NUL",
    "COM1","COM2","COM3","COM4","COM5","COM6","COM7","COM8","COM9",
    "LPT1","LPT2","LPT3","LPT4","LPT5","LPT6","LPT7","LPT8","LPT9"
)

# ------------------------------------------------------------
# Safe name conversion (Преобразование имени в безопасный вид)
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
    # Do not use NFKC, which could unnecessarily change typography,
    # mathematical symbols, superscript characters, and similar text.
    # (Не используем NFKC, чтобы без необходимости не менять типографику,
    # математические символы, надстрочные знаки и подобный текст.)
    # --------------------------------------------------------

    try {
        $NewName = $NewName.Normalize([System.Text.NormalizationForm]::FormC)
    }
    catch {
        # Continue when a particular string cannot be normalized.
        # (Если конкретная строка не нормализуется, продолжаем.)
    }

    # --------------------------------------------------------
    # Invisible and formatting Unicode characters
    # (Невидимые и служебные Unicode-символы)
    # --------------------------------------------------------

    # ZWSP separates words, so replace it with a visible space. ZWNJ and ZWJ
    # are meaningful in natural-language text and emoji sequences; preserve them.
    # (ZWSP разделяет слова, поэтому заменяем его видимым пробелом. ZWNJ и ZWJ
    # значимы в естественных языках и emoji-последовательностях; сохраняем их.)
    $NewName = $NewName.Replace(([char]0x200B).ToString(), " ") # Zero Width Space (Пробел нулевой ширины)

    $NewName = $NewName.Replace(([char]0x2060).ToString(), "") # Word Joiner (Соединитель слов)
    $NewName = $NewName.Replace(([char]0xFEFF).ToString(), "") # BOM / ZWNBSP

    # Remove additional Unicode formatting characters such as LRM, RLM,
    # directional isolates, and directional embeddings.
    # (Удаляем дополнительные служебные символы Unicode, включая LRM, RLM,
    # directional isolates и directional embeddings.)
    $NewName = [regex]::Replace(
        $NewName,
        '[\u061C\u200E\u200F\u202A-\u202E\u2066-\u2069]',
        ''
    )

    # Replace non-breaking and other Unicode spaces with an ASCII space.
    # (Заменяем неразрывные и другие Unicode-пробелы обычным ASCII-пробелом.)
    $NewName = [regex]::Replace(
        $NewName,
        '[\u00A0\u2000-\u200A\u202F\u205F\u3000]',
        ' '
    )

    # TAB, CR, and LF separate text. Replace them with spaces before removing
    # other ASCII controls so adjacent words are not joined together.
    # (TAB, CR и LF разделяют текст. Сначала заменяем их пробелами, чтобы
    # удаление остальных ASCII controls не склеивало соседние слова.)
    $NewName = $NewName.Replace(([char]0x0009).ToString(), " ")
    $NewName = $NewName.Replace(([char]0x000D).ToString(), " ")
    $NewName = $NewName.Replace(([char]0x000A).ToString(), " ")

    # Remove ASCII control characters 0-31 and DEL.
    # (Удаляем управляющие символы ASCII 0-31 и DEL.)
    $NewName = [regex]::Replace($NewName, '[\x00-\x1F\x7F]', '')

    # SOFT HYPHEN is invisible in most interfaces; make it explicit.
    # (SOFT HYPHEN невидим в большинстве интерфейсов; делаем его явным.)
    $NewName = $NewName.Replace(([char]0x00AD).ToString(), "-")

    # --------------------------------------------------------
    # Unicode variants of characters that can cause problems with
    # Windows, SCP, or SFTP.
    # (Unicode-аналоги символов, способных создавать проблемы
    # в Windows, SCP или SFTP.)
    #
    # In particular (В частности):
    #   ：  U+FF1A FULLWIDTH COLON
    #   ／  U+FF0F FULLWIDTH SOLIDUS
    #   ＼  U+FF3C FULLWIDTH REVERSE SOLIDUS
    #   ⧸  U+29F8 BIG SOLIDUS
    #   ｜  U+FF5C FULLWIDTH VERTICAL LINE
    #   ？  U+FF1F FULLWIDTH QUESTION MARK
    #   ＊  U+FF0A FULLWIDTH ASTERISK
    #   ＜  U+FF1C FULLWIDTH LESS-THAN SIGN
    #   ＞  U+FF1E FULLWIDTH GREATER-THAN SIGN
    #   ＂  U+FF02 FULLWIDTH QUOTATION MARK
    #
    # Also handle several similar slash and colon characters.
    # (Также обрабатываем несколько похожих символов slash и colon.)
    # --------------------------------------------------------

    # Colon-like characters -> safe separator.
    # (Символы, похожие на colon, -> безопасный разделитель.)
    $NewName = $NewName.Replace(([char]0xFF1A).ToString(), " - ") # ：
    $NewName = $NewName.Replace(([char]0xFE55).ToString(), " - ") # ﹕

    # Slash-like characters -> safe separator.
    # (Символы, похожие на slash, -> безопасный разделитель.)
    $NewName = $NewName.Replace(([char]0xFF0F).ToString(), " - ") # ／
    $NewName = $NewName.Replace(([char]0xFF3C).ToString(), " - ") # ＼
    $NewName = $NewName.Replace(([char]0xFE68).ToString(), " - ") # ﹨
    $NewName = $NewName.Replace(([char]0x29F8).ToString(), " - ") # ⧸

    # Pipe-like characters. (Символы, похожие на pipe.)
    $NewName = $NewName.Replace(([char]0xFF5C).ToString(), " - ") # ｜

    # Replace compatibility variants of forbidden question, asterisk, angle,
    # and quote characters with spaces. Preserve safe linguistic punctuation.
    # (Заменяем пробелами compatibility-варианты запрещённых символов question,
    # asterisk, angle и quote. Безопасную языковую пунктуацию сохраняем.)
    $NewName = $NewName.Replace(([char]0xFF1F).ToString(), " ") # ？
    $NewName = $NewName.Replace(([char]0xFE56).ToString(), " ") # ﹖
    $NewName = $NewName.Replace(([char]0xFF0A).ToString(), " ") # ＊
    $NewName = $NewName.Replace(([char]0xFE61).ToString(), " ") # ﹡
    $NewName = $NewName.Replace(([char]0xFF1C).ToString(), " ") # ＜
    $NewName = $NewName.Replace(([char]0xFE64).ToString(), " ") # ﹤
    $NewName = $NewName.Replace(([char]0xFF1E).ToString(), " ") # ＞
    $NewName = $NewName.Replace(([char]0xFE65).ToString(), " ") # ﹥
    $NewName = $NewName.Replace(([char]0xFF02).ToString(), " ") # ＂

    # Common cleanup and Strict post-pass do not modify commas. They are valid
    # on Windows/Linux and improve readability. Preserve Unicode comma variants too.
    # (Common cleanup и Strict post-pass не изменяют запятые. Они допустимы
    # в Windows/Linux и улучшают читаемость. Unicode-варианты запятых тоже сохраняются.)

    # --------------------------------------------------------
    # Standard characters forbidden by Windows or potentially
    # problematic for file transfer
    # (Обычные символы, запрещённые Windows или потенциально
    # проблемные для передачи файлов)
    # --------------------------------------------------------

    $NewName = $NewName -replace ':', ' - '
    $NewName = $NewName -replace '[\\/|]', ' - '
    # Forbidden ASCII characters separate adjacent text.
    # (Запрещённые ASCII-символы разделяют соседний текст.)
    $NewName = $NewName -replace '[<>"]', ' '
    $NewName = $NewName -replace '[?*]', ' '

    # --------------------------------------------------------
    # Safe linguistic punctuation (Безопасная языковая пунктуация)
    # --------------------------------------------------------

    # Common cleanup preserves typographic quotation marks, apostrophes, primes,
    # meaningful slash/pipe/colon characters, variation selectors, and combining
    # marks. NFC was already applied above; global NFKC is not used.
    # (Common cleanup сохраняет типографские кавычки, апострофы, primes,
    # смысловые символы slash/pipe/colon, variation selectors и combining marks.
    # NFC уже применён выше; глобальную NFKC не используем.)

    # --------------------------------------------------------
    # Strict post-pass reduces shell-sensitive metacharacters. File names
    # must still be quoted when passed to a shell.
    # (Strict post-pass уменьшает количество shell-sensitive metacharacters.
    # При передаче оболочке имена файлов по-прежнему необходимо заключать в кавычки.)
    # --------------------------------------------------------

    if ($StrictMode) {
        # Normalize common apostrophe variants to U+02BC. It preserves visual
        # separation and is not an ASCII quote.
        # (Приводим распространённые варианты апострофа к U+02BC. Он сохраняет
        # визуальное разделение и не является ASCII quote.)
        $NewName = [regex]::Replace(
            $NewName,
            '[\u0027\u2018-\u201B\u02BC\uFF07]',
            ([char]0x02BC).ToString()
        )

        # Shell grouping, glob, and brace characters -> separator.
        # (Shell grouping, glob и brace characters -> разделитель.)
        $NewName = $NewName -replace '[\(\)\[\]\{\}]', ' '

        # A closing bracket before a preserved comma must not leave an
        # artificial space: "[Live]," -> "Live,".
        # (Закрывающая скобка перед сохраняемой запятой не должна оставлять
        # искусственный пробел: "[Live]," -> "Live,".)
        $NewName = [regex]::Replace(
            $NewName,
            '\s+(?=[,\uFF0C\uFE50\u3001\u060C])',
            ''
        )

        # Replace visible metacharacters instead of removing them without a
        # separator. A plus sign is a language-neutral ampersand replacement.
        # (Заменяем видимые метасимволы, а не удаляем их без разделителя.
        # Знак плюса служит языково-нейтральной заменой ampersand.)
        $NewName = $NewName -replace ';', ' '
        $NewName = $NewName -replace '&', ' + '
        $NewName = [regex]::Replace(
            $NewName,
            '[\u0024\u0021\u0060\u005E\u007E]',
            ' '
        )
    }

    # --------------------------------------------------------
    # Space and separator normalization
    # (Нормализация пробелов и разделителей)
    # --------------------------------------------------------

    $NewName = [regex]::Replace($NewName, '\s+', ' ')
    $NewName = [regex]::Replace($NewName, '\s*-\s*-\s*', ' - ')
    $NewName = $NewName.Trim()

    # Windows does not allow trailing periods or spaces in a name.
    # (Windows не допускает точки и пробелы в конце имени.)
    $NewName = $NewName.TrimEnd([char[]]@('.', ' '))

    # Normalize again after all replacements.
    # (Повторно нормализуем после всех замен.)
    $NewName = [regex]::Replace($NewName, '\s+', ' ').Trim()

    if ([string]::IsNullOrWhiteSpace($NewName)) {
        $NewName = "unnamed"
    }

    # Reserved Windows names. (Зарезервированные имена Windows.)
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
# String size in UTF-8 bytes (Размер строки в UTF-8 байтах)
# ------------------------------------------------------------

function Get-Utf8ByteCount {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value
    )

    # The strict encoder also validates UTF-16: unpaired surrogate code units
    # are not silently replaced with U+FFFD.
    # (Строгий encoder также проверяет UTF-16: одиночные surrogate code units
    # не заменяются незаметно символом U+FFFD.)
    return $Utf8EncodingStrict.GetByteCount($Value)
}

# ------------------------------------------------------------
# Unicode-safe truncation by UTF-8 byte size
# (Безопасное для Unicode усечение по размеру в UTF-8 байтах)
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

    # Iterate over Unicode text elements rather than UTF-16 code units. This
    # prevents splitting a surrogate pair and preserves a base character with
    # its combining marks whenever possible.
    # (Перебираем Unicode text elements, а не UTF-16 code units. Поэтому
    # усечение не разрезает surrogate pair и по возможности сохраняет
    # базовый символ вместе с его combining marks.)
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
# Full file name limit with extension preservation
# (Ограничение полного имени файла с сохранением расширения)
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

    # Preserve the complete extension first and give the remaining byte budget
    # to the base name.
    # (Сначала сохраняем расширение целиком и отдаём оставшийся byte budget
    # базовой части имени.)
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

    # A complete extension may leave no room for even one usable text element
    # in the base name. In this rare case, preserve a safe base and the longest
    # possible extension prefix. This guarantees a non-empty name within the limit.
    # (Полное расширение иногда не оставляет места даже для одного пригодного
    # text element базового имени. В этом редком случае сохраняем безопасную
    # базовую часть и максимально возможный префикс расширения. Это гарантирует
    # соблюдение лимита и непустое имя.)
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
# Name generation with a conflict suffix
# (Формирование имени с конфликтным суффиксом)
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

    # Rebuild the suffix for every counter value. Transitions from (9) to (10)
    # and from (99) to (100) therefore reduce the base-name byte budget by the
    # actual difference.
    # (Суффикс строится заново для каждого значения счётчика. Поэтому переходы
    # (9) -> (10) и (99) -> (100) уменьшают byte budget базовой части
    # на фактическую разницу.)
    $ConflictSuffix = " ($Counter)"
    $SuffixBytes = Get-Utf8ByteCount -Value $ConflictSuffix
    $AvailableNameBytes = $MaxUtf8Bytes - $SuffixBytes

    if ($AvailableNameBytes -lt 1) {
        throw "The conflict suffix does not fit within the name limit. (Конфликтный суффикс не помещается в лимит имени.)"
    }

    # Preserve the complete extension when it and the suffix leave room for at
    # least one usable text element in the base name.
    # (Сохраняем расширение полностью, когда вместе с суффиксом оно оставляет
    # место хотя бы для одного пригодного text element базовой части.)
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

    # If the complete extension leaves no room for the base, use a minimal safe
    # one-byte base. Give the remainder to the extension and truncate its prefix
    # only at Unicode text element boundaries.
    # (Если полное расширение не оставляет места для базы, используем минимальную
    # безопасную однобайтовую базу. Остаток отдаём расширению и усекаем его префикс
    # только по границам Unicode text elements.)
    $FallbackBaseName = "_"
    $FallbackBytes = Get-Utf8ByteCount -Value $FallbackBaseName
    $AvailableExtensionBytes = $AvailableNameBytes - $FallbackBytes
    $LimitedExtension = Limit-StringToUtf8ByteCount `
        -Value $Extension `
        -MaxUtf8Bytes $AvailableExtensionBytes

    return "$FallbackBaseName$ConflictSuffix$LimitedExtension"
}

# ------------------------------------------------------------
# Unique name selection for conflicts
# (Выбор уникального имени при конфликтах)
# ------------------------------------------------------------

function Get-UniqueName {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.Dictionary[string,string]]$Namespace,

        [Parameter(Mandatory = $true)]
        [string]$NewName,

        [Parameter(Mandatory = $true)]
        [string]$OwnerId,

        [switch]$IsDirectory
    )

    $MaxNameUtf8Bytes = 255
    $Extension = ""
    $BaseName = $NewName

    if (-not $IsDirectory) {
        $Extension = [System.IO.Path]::GetExtension($NewName)
        $BaseName = [System.IO.Path]::GetFileNameWithoutExtension($NewName)
    }

    # Process-File already limits its input name. Applying the limit again here
    # also guarantees it for direct function calls. For directories, this check
    # prevents returning an oversized candidate before the first conflict suffix.
    # (Process-File уже ограничивает входное имя. Повторное ограничение здесь
    # также гарантирует лимит при прямом вызове функции. Для каталогов эта
    # проверка не позволяет вернуть слишком длинный кандидат до появления
    # первого конфликтного суффикса.)
    $Candidate = Limit-FileNameToUtf8ByteCount `
        -BaseName $BaseName `
        -Extension $Extension `
        -MaxUtf8Bytes $MaxNameUtf8Bytes

    $Counter = 1

    while ($true) {
        $OccupantOwnerId = $null
        $IsOccupied = $Namespace.TryGetValue(
            $Candidate,
            [ref]$OccupantOwnerId
        )

        if (
            -not $IsOccupied -or
            ([string]::Equals(
                $OccupantOwnerId,
                $OwnerId,
                [System.StringComparison]::Ordinal
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
# Filename snapshot and virtual state
# (Снимок состояния и виртуальное состояние имён)
# ------------------------------------------------------------

function Get-OriginalRelativePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FullName
    )

    $RootPrefix = $RootPath
    $Separator = [System.IO.Path]::DirectorySeparatorChar.ToString()

    if (-not $RootPrefix.EndsWith($Separator)) {
        $RootPrefix += $Separator
    }

    if (-not $FullName.StartsWith(
        $RootPrefix,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Object is outside the root directory (Объект находится вне корневого каталога): $FullName"
    }

    return $FullName.Substring($RootPrefix.Length)
}

function New-SnapshotState {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.IO.FileInfo[]]$Files,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.IO.DirectoryInfo[]]$Directories
    )

    $RootOwnerId = "ROOT"
    $DirectoryOwnerByPath = New-Object `
        'System.Collections.Generic.Dictionary[string,string]' `
        ([System.StringComparer]::OrdinalIgnoreCase)
    $RecordsByOwnerId = New-Object `
        'System.Collections.Generic.Dictionary[string,object]' `
        ([System.StringComparer]::Ordinal)
    $Namespaces = New-Object `
        'System.Collections.Generic.Dictionary[string,object]' `
        ([System.StringComparer]::Ordinal)
    $FileRecords = New-Object System.Collections.ArrayList
    $DirectoryRecords = New-Object System.Collections.ArrayList

    $DirectoryOwnerByPath.Add($RootPath, $RootOwnerId)
    $NextOwnerNumber = 1

    # Assign IDs to all directories first so ParentOwnerId does not depend on
    # the order in which Get-ChildItem returned nested directories.
    # (Сначала назначаем ID всем каталогам, чтобы ParentOwnerId не зависел
    # от порядка, в котором Get-ChildItem вернул вложенные каталоги.)
    foreach ($Directory in $Directories) {
        $OwnerId = "D:$NextOwnerNumber"
        $NextOwnerNumber++
        $RelativePath = Get-OriginalRelativePath `
            -FullName $Directory.FullName
        $Depth = @($RelativePath -split '[\\/]').Count

        $Record = [pscustomobject]@{
            OwnerId           = $OwnerId
            ItemType         = "Directory"
            OriginalFullName = $Directory.FullName
            OriginalName     = $Directory.Name
            ParentFullName   = $Directory.Parent.FullName
            ParentOwnerId    = $null
            RelativePath     = $RelativePath
            Depth            = $Depth
            InfoObject       = $Directory
            CurrentVirtualName = $Directory.Name
        }

        $DirectoryOwnerByPath.Add($Directory.FullName, $OwnerId)
        $RecordsByOwnerId.Add($OwnerId, $Record)
        [void]$DirectoryRecords.Add($Record)
    }

    foreach ($Record in $DirectoryRecords) {
        $ParentOwnerId = $null

        if (-not $DirectoryOwnerByPath.TryGetValue(
            $Record.ParentFullName,
            [ref]$ParentOwnerId
        )) {
            throw "Snapshot parent owner was not found (Не найден владелец родительского каталога в snapshot): $($Record.ParentFullName)"
        }

        $Record.ParentOwnerId = $ParentOwnerId
    }

    foreach ($File in $Files) {
        $OwnerId = "F:$NextOwnerNumber"
        $NextOwnerNumber++
        $ParentOwnerId = $null

        if (-not $DirectoryOwnerByPath.TryGetValue(
            $File.DirectoryName,
            [ref]$ParentOwnerId
        )) {
            throw "Snapshot parent owner was not found (Не найден владелец родительского каталога в snapshot): $($File.DirectoryName)"
        }

        $RelativePath = Get-OriginalRelativePath -FullName $File.FullName
        $Record = [pscustomobject]@{
            OwnerId           = $OwnerId
            ItemType         = "File"
            OriginalFullName = $File.FullName
            OriginalName     = $File.Name
            ParentFullName   = $File.DirectoryName
            ParentOwnerId    = $ParentOwnerId
            RelativePath     = $RelativePath
            Depth            = @($RelativePath -split '[\\/]').Count
            InfoObject       = $File
            CurrentVirtualName = $File.Name
        }

        $RecordsByOwnerId.Add($OwnerId, $Record)
        [void]$FileRecords.Add($Record)
    }

    # Files and directories under one parent share a namespace.
    # OrdinalIgnoreCase matches the current Windows name policy; the comparer
    # intentionally performs no additional Unicode normalization.
    # (Файлы и каталоги одного родителя используют единое пространство имён.
    # OrdinalIgnoreCase соответствует текущей Windows-политике имён; comparer
    # намеренно не выполняет дополнительную Unicode-нормализацию.)
    foreach ($Record in @($DirectoryRecords) + @($FileRecords)) {
        if (-not $Namespaces.ContainsKey($Record.ParentOwnerId)) {
            $Namespace = New-Object `
                'System.Collections.Generic.Dictionary[string,string]' `
                ([System.StringComparer]::OrdinalIgnoreCase)
            $Namespaces.Add($Record.ParentOwnerId, $Namespace)
        }

        $Namespace = [System.Collections.Generic.Dictionary[string,string]](
            $Namespaces[$Record.ParentOwnerId]
        )
        $Namespace.Add($Record.OriginalName, $Record.OwnerId)
    }

    return [pscustomobject]@{
        RootOwnerId     = $RootOwnerId
        Files           = [object[]]$FileRecords.ToArray()
        Directories     = [object[]]$DirectoryRecords.ToArray()
        RecordsByOwnerId = $RecordsByOwnerId
        Namespaces      = $Namespaces
    }
}

function Sort-SnapshotRecords {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Records,

        [switch]$DirectoriesDeepestFirst
    )

    $SortedRecords = [object[]]@($Records)
    $Comparer = [System.Collections.Generic.Comparer[object]]::Create(
        [System.Comparison[object]]{
            param($Left, $Right)

            if ($DirectoriesDeepestFirst) {
                $DepthComparison = $Right.Depth.CompareTo($Left.Depth)

                if ($DepthComparison -ne 0) {
                    return $DepthComparison
                }
            }

            $PathComparison = [System.StringComparer]::OrdinalIgnoreCase.Compare(
                $Left.RelativePath,
                $Right.RelativePath
            )

            if ($PathComparison -ne 0) {
                return $PathComparison
            }

            return [System.StringComparer]::Ordinal.Compare(
                $Left.RelativePath,
                $Right.RelativePath
            )
        }
    )

    [System.Array]::Sort($SortedRecords, $Comparer)
    return $SortedRecords
}

function Set-VirtualName {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Record,

        [Parameter(Mandatory = $true)]
        [string]$NewName
    )

    if ([string]::Equals(
        $Record.CurrentVirtualName,
        $NewName,
        [System.StringComparison]::Ordinal
    )) {
        return
    }

    $Namespace = [System.Collections.Generic.Dictionary[string,string]](
        $VirtualNamespaces[$Record.ParentOwnerId]
    )
    $CurrentOwnerId = $null

    if (
        -not $Namespace.TryGetValue(
            $Record.CurrentVirtualName,
            [ref]$CurrentOwnerId
        ) -or
        -not [string]::Equals(
            $CurrentOwnerId,
            $Record.OwnerId,
            [System.StringComparison]::Ordinal
        )
    ) {
        throw "Internal filename ownership state is inconsistent. (Нарушено внутреннее состояние владельца имени.)"
    }

    $TargetOwnerId = $null

    if (
        $Namespace.TryGetValue($NewName, [ref]$TargetOwnerId) -and
        -not [string]::Equals(
            $TargetOwnerId,
            $Record.OwnerId,
            [System.StringComparison]::Ordinal
        )
    ) {
        throw "Target name is already occupied by another owner. (Целевое имя уже занято другим владельцем.)"
    }

    # Remove + Add are also required for a case-only rename: the comparer treats
    # both spellings as one key, but the state must preserve the selected case.
    # (Remove + Add нужны и для переименования только по регистру: comparer
    # считает оба написания одним ключом, но state должен сохранять выбранный регистр.)
    [void]$Namespace.Remove($Record.CurrentVirtualName)
    $Namespace.Add($NewName, $Record.OwnerId)
    $Record.CurrentVirtualName = $NewName
}

# ------------------------------------------------------------
# File processing (Обработка файла)
# ------------------------------------------------------------

function Process-File {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Record
    )

    $File = [System.IO.FileInfo]$Record.InfoObject
    $Stats.Checked++

    $OriginalName = $File.Name

    # A single leading period denotes a dotfile, not an extension. Preserve the
    # existing last-period semantics for all other names:
    # .config.json -> .config + .json, archive.tar.gz -> archive.tar + .gz.
    # (Одиночная ведущая точка обозначает dotfile, а не расширение. Для остальных
    # имён сохраняем прежнюю семантику последней точки.)
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

    # Do not pass the leading period through sanitization; normalize only the body.
    # Unlike the former category allowlist, this policy preserves national letters,
    # combining marks, emoji, and safe Unicode characters.
    # (Не пропускаем ведущую точку через очистку; нормализуем только body.
    # В отличие от прежнего category allowlist, эта политика сохраняет национальные
    # буквы, combining marks, emoji и безопасные символы Unicode.)
    $SafeExtension = ""

    if (-not [string]::IsNullOrEmpty($Extension)) {
        $ExtensionBody = $Extension.Substring(1)

        # Apply NFC only to the extension body. Do not use global NFKC, which
        # could change compatibility Unicode characters.
        # (Применяем NFC только к extension body. Глобальную NFKC не используем,
        # чтобы не менять compatibility-символы Unicode.)
        try {
            $ExtensionBody = $ExtensionBody.Normalize(
                [System.Text.NormalizationForm]::FormC
            )
        }
        catch {
            # Continue sanitization when a particular string cannot be normalized.
            # (Если конкретная строка не нормализуется, продолжаем очистку.)
        }

        # Controls, bidi formatting, WORD JOINER, BOM, and ZWSP carry no useful
        # extension information. ZWNJ, ZWJ, variation selectors, and combining
        # marks are intentionally excluded from the removal sets.
        # (Controls, bidi formatting, WORD JOINER, BOM и ZWSP не несут полезной
        # информации для расширения. ZWNJ, ZWJ, variation selectors и combining
        # marks намеренно не входят в удаляемые наборы.)
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

        # Remove spaces and Windows-forbidden characters from the extension body
        # without turning a short extension into a phrase with separators.
        # (Удаляем пробелы и запрещённые Windows символы из extension body,
        # не превращая короткое расширение в отдельную фразу с разделителями.)
        $ExtensionBody = [regex]::Replace($ExtensionBody, '\s+', '')
        $ExtensionBody = [regex]::Replace(
            $ExtensionBody,
            '[<>:"/\\|?*]',
            ''
        )
        $ExtensionBody = [regex]::Replace(
            $ExtensionBody,
            '[\uFF1A\uFE55\uFF0F\uFF3C\uFE68\u29F8\uFF5C' +
            '\uFF1F\uFE56\uFF0A\uFE61\uFF1C\uFE64' +
            '\uFF1E\uFE65\uFF02]',
            ''
        )

        # The Strict post-pass for the extension body also only reduces
        # shell-sensitive metacharacters. The complete name must still be quoted.
        # Do not add spaces to the extension.
        # (Strict post-pass для extension body также только уменьшает количество
        # shell-sensitive metacharacters. Полное имя по-прежнему необходимо
        # заключать в кавычки. Пробелы в расширение не добавляем.)
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

        # Do not leave a lone leading period when the body was completely removed.
        # (Не оставляем одиночную ведущую точку, если body полностью очищен.)
        if (-not [string]::IsNullOrEmpty($ExtensionBody)) {
            $SafeExtension = ".$ExtensionBody"
        }
    }

    # ext4 allows up to 255 bytes per name component. Limit the initial candidate
    # here; Get-UniqueName recalculates the exact budget if a conflict suffix is needed.
    # (ext4 допускает до 255 байт на один компонент имени. Здесь ограничиваем
    # исходный кандидат; Get-UniqueName пересчитывает точный бюджет, если потребуется
    # добавить конфликтный суффикс.)
    $MaxFileNameUtf8Bytes = 255

    $NewName = Limit-FileNameToUtf8ByteCount `
        -BaseName $SafeBaseName `
        -Extension $SafeExtension `
        -MaxUtf8Bytes $MaxFileNameUtf8Bytes

    # IMPORTANT: use an exact ordinal comparison. PowerShell -eq/-ceq may treat
    # canonically equivalent Unicode strings as equal, for example:
    #   "и" + U+0306  и  "й"
    # The difference must be detected so the physical name is normalized.
    # (ВАЖНО: используем точное ordinal-сравнение. PowerShell -eq/-ceq может считать
    # канонически эквивалентные Unicode-строки одинаковыми, например:
    #   "и" + U+0306  и  "й"
    # Эту разницу необходимо обнаружить, чтобы физически нормализовать имя.)
    if ([string]::Equals(
        $OriginalName,
        $NewName,
        [System.StringComparison]::Ordinal
    )) {
        return
    }

    $Stats.NeedRename++

    $Namespace = [System.Collections.Generic.Dictionary[string,string]](
        $VirtualNamespaces[$Record.ParentOwnerId]
    )
    $NewName = Get-UniqueName `
        -Namespace $Namespace `
        -NewName $NewName `
        -OwnerId $Record.OwnerId

    Write-Host ""
    Write-Host "FILE (ФАЙЛ):" -ForegroundColor Cyan
    Write-Host "  Before (Было):  " -NoNewline
    Write-Host $OriginalName -ForegroundColor Yellow
    Write-Host "  After (Будет):  " -NoNewline
    Write-Host $NewName -ForegroundColor Green

    # Report changes caused only by Unicode normalization separately because the
    # names may look identical.
    # (Отдельно сообщаем об изменениях только из-за Unicode-нормализации, поскольку
    # имена могут выглядеть одинаково.)
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
            Write-Host "  Reason: Unicode NFC normalization (Причина: нормализация Unicode NFC)" -ForegroundColor DarkYellow
        }
    }
    catch {
    }

    if (-not $Apply) {
        # Dry Run models a successful sequential Apply: release the old name and
        # reserve the selected target immediately.
        # (Dry Run моделирует успешный последовательный Apply: старое имя
        # освобождается, а выбранная цель резервируется немедленно.)
        Set-VirtualName -Record $Record -NewName $NewName
        return
    }

    try {
        Rename-Item `
            -LiteralPath $File.FullName `
            -NewName $NewName `
            -ErrorAction Stop

        # In Apply, update the state only after a successful Rename-Item.
        # (В Apply обновляем state только после успешного Rename-Item.)
        Set-VirtualName -Record $Record -NewName $NewName
        $Stats.Renamed++
    }
    catch {
        $Stats.Errors++

        Write-Host "  RENAME ERROR (ОШИБКА ПЕРЕИМЕНОВАНИЯ):" -ForegroundColor Red
        Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ------------------------------------------------------------
# Directory processing (Обработка каталога)
# ------------------------------------------------------------

function Process-Directory {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Record
    )

    $Directory = [System.IO.DirectoryInfo]$Record.InfoObject
    $Stats.Checked++

    $OriginalName = $Directory.Name
    $NewName = Convert-ToSafeName -Name $OriginalName -StrictMode:$Strict

    # ext4 allows up to 255 UTF-8 bytes per name component. A directory has no
    # extension, so limit the sanitized name directly at Unicode text element
    # boundaries before comparing it with the original.
    # (ext4 допускает максимум 255 UTF-8 байт на один компонент имени. У каталога
    # нет расширения, поэтому ограничиваем очищенное имя непосредственно
    # по границам Unicode text elements до сравнения с исходным.)
    $MaxDirectoryNameUtf8Bytes = 255
    $NewName = Limit-StringToUtf8ByteCount `
        -Value $NewName `
        -MaxUtf8Bytes $MaxDirectoryNameUtf8Bytes

    $NewName = $NewName.TrimEnd([char[]]@('.', ' '))

    if ([string]::IsNullOrWhiteSpace($NewName)) {
        $NewName = "unnamed"
    }

    # IMPORTANT: use an exact ordinal comparison. PowerShell -eq/-ceq may treat
    # canonically equivalent Unicode strings as equal, for example:
    #   "и" + U+0306  и  "й"
    # The difference must be detected so the physical name is normalized.
    # (ВАЖНО: используем точное ordinal-сравнение. PowerShell -eq/-ceq может считать
    # канонически эквивалентные Unicode-строки одинаковыми, например:
    #   "и" + U+0306  и  "й"
    # Эту разницу необходимо обнаружить, чтобы физически нормализовать имя.)
    if ([string]::Equals(
        $OriginalName,
        $NewName,
        [System.StringComparison]::Ordinal
    )) {
        return
    }

    $Stats.NeedRename++

    $Namespace = [System.Collections.Generic.Dictionary[string,string]](
        $VirtualNamespaces[$Record.ParentOwnerId]
    )
    $NewName = Get-UniqueName `
        -Namespace $Namespace `
        -NewName $NewName `
        -OwnerId $Record.OwnerId `
        -IsDirectory

    Write-Host ""
    Write-Host "DIRECTORY (КАТАЛОГ):" -ForegroundColor Magenta
    Write-Host "  Before (Было):  " -NoNewline
    Write-Host $OriginalName -ForegroundColor Yellow
    Write-Host "  After (Будет):  " -NoNewline
    Write-Host $NewName -ForegroundColor Green

    # Report changes caused only by Unicode normalization separately because the
    # names may look identical.
    # (Отдельно сообщаем об изменениях только из-за Unicode-нормализации, поскольку
    # имена могут выглядеть одинаково.)
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
            Write-Host "  Reason: Unicode NFC normalization (Причина: нормализация Unicode NFC)" -ForegroundColor DarkYellow
        }
    }
    catch {
    }

    if (-not $Apply) {
        Set-VirtualName -Record $Record -NewName $NewName
        return
    }

    try {
        Rename-Item `
            -LiteralPath $Directory.FullName `
            -NewName $NewName `
            -ErrorAction Stop

        Set-VirtualName -Record $Record -NewName $NewName
        $Stats.Renamed++
    }
    catch {
        $Stats.Errors++

        Write-Host "  RENAME ERROR (ОШИБКА ПЕРЕИМЕНОВАНИЯ):" -ForegroundColor Red
        Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ============================================================
# Execution (Запуск)
# ============================================================

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " CLEAN FILE NAMES (ОЧИСТКА ИМЁН ФАЙЛОВ)" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Folder (Папка):                         $RootPath"
Write-Host "Strict mode (Строгий режим):            $Strict"
Write-Host "Include directories (Обрабатывать каталоги): $IncludeDirectories"

if ($Apply) {
    Write-Host "Mode (Режим): APPLY CHANGES (ПРИМЕНЕНИЕ ИЗМЕНЕНИЙ)" -ForegroundColor Red
}
else {
    Write-Host "Mode (Режим): CHECK ONLY (ТОЛЬКО ПРОВЕРКА)" -ForegroundColor Green
}

Write-Host ""

# Build the file and directory snapshot before the first Process-File call and
# before any Rename-Item. Include directories even without -IncludeDirectories
# because their names occupy the same namespace and can block file targets.
# (Создаём snapshot файлов и каталогов до первого вызова Process-File и до любого
# Rename-Item. Включаем каталоги даже без -IncludeDirectories, поскольку их имена
# занимают то же пространство имён и могут блокировать цели файлов.)
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
    Write-Host "Unable to enumerate files (Не удалось получить список файлов):" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}

try {
    $Directories = @(
        Get-ChildItem `
            -LiteralPath $RootPath `
            -Directory `
            -Recurse `
            -Force `
            -ErrorAction Stop
    )
}
catch {
    Write-Host "Unable to enumerate directories (Не удалось получить список каталогов):" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}

try {
    $SnapshotState = New-SnapshotState `
        -Files $Files `
        -Directories $Directories
    $VirtualNamespaces = $SnapshotState.Namespaces
    $FileRecords = @(
        Sort-SnapshotRecords -Records $SnapshotState.Files
    )
    $DirectoryRecords = @(
        Sort-SnapshotRecords `
            -Records $SnapshotState.Directories `
            -DirectoriesDeepestFirst
    )
}
catch {
    Write-Host "Unable to build filename snapshot (Не удалось построить снимок состояния имён):" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}

# ------------------------------------------------------------
# Files: original relative path, OrdinalIgnoreCase + Ordinal tie-breaker
# (Файлы: исходный relative path, OrdinalIgnoreCase + Ordinal tie-breaker)
# ------------------------------------------------------------

foreach ($Record in $FileRecords) {
    try {
        Process-File -Record $Record
    }
    catch {
        $Stats.Errors++

        Write-Host ""
        Write-Host "FILE PROCESSING ERROR (ОШИБКА ОБРАБОТКИ ФАЙЛА):" -ForegroundColor Red
        Write-Host "  $($Record.OriginalFullName)" -ForegroundColor Yellow
        Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ------------------------------------------------------------
# Directories: descending depth, then the same relative-path comparers
# (Каталоги: глубина по убыванию, затем те же relative-path comparers)
# ------------------------------------------------------------

if ($IncludeDirectories) {
    # With deepest-first ordering, all children are processed before their parent
    # is renamed. A stable ParentOwnerId also preserves the namespace regardless
    # of changes to the directory's physical path.
    # (При порядке deepest-first все дочерние объекты обрабатываются до переименования
    # родителя. Стабильный ParentOwnerId также сохраняет пространство имён независимо
    # от изменений физического пути каталога.)

    foreach ($Record in $DirectoryRecords) {
        try {
            Process-Directory -Record $Record
        }
        catch {
            $Stats.Errors++

            Write-Host ""
            Write-Host "DIRECTORY PROCESSING ERROR (ОШИБКА ОБРАБОТКИ КАТАЛОГА):" -ForegroundColor Red
            Write-Host "  $($Record.OriginalFullName)" -ForegroundColor Yellow
            Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

# ============================================================
# Result (Результат)
# ============================================================

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " RESULT (РЕЗУЛЬТАТ)" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Checked (Проверено):                   $($Stats.Checked)"
Write-Host "Need rename (Требуют переименования):  $($Stats.NeedRename)"
Write-Host "Renamed (Переименовано):               $($Stats.Renamed)"
Write-Host "Errors (Ошибок):                       $($Stats.Errors)"
Write-Host ""

if (-not $Apply) {
    Write-Host "Changes were NOT applied (Изменения НЕ применялись)." -ForegroundColor Yellow
    Write-Host "Add -Apply to perform actual renaming (Для реального переименования добавьте параметр -Apply)."
    Write-Host ""
}
