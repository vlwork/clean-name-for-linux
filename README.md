# Clean Name for Linux

## Русская версия

### Назначение

`Clean-FileNames.ps1` — PowerShell-скрипт для проверки, очистки и нормализации имён файлов перед переносом данных с Windows на Linux, в том числе на серверы Proxmox.

Скрипт рекурсивно обходит файлы в указанном каталоге, формирует более переносимые имена и показывает план переименования. По умолчанию он работает в безопасном режиме предварительной проверки (dry run) и ничего не переименовывает. Изменения применяются только при явном указании `-Apply`.

> Сначала рекомендуется запустить скрипт без `-Apply`, внимательно проверить предложенные имена и только затем применять изменения. Перед массовым переименованием сделайте резервную копию важных данных.

### Возможности

- Рекурсивная обработка файлов, включая элементы, доступные через `Get-ChildItem -Force`.
- Безопасный dry run по умолчанию с выводом исходного и предлагаемого имени.
- Фактическое переименование только с параметром `-Apply`.
- Опциональная обработка вложенных каталогов с `-IncludeDirectories`; корневой каталог, переданный в `-Path`, не переименовывается.
- Нормализация Unicode в форму NFC. Для файлов она применяется к базовой части имени, для каталогов — ко всему имени.
- Удаление ряда невидимых и управляющих Unicode-символов: zero-width символов, BOM/ZWNBSP, меток и управляющих символов направления текста, а также управляющих символов ASCII. Некоторые виды неразрывных пробелов заменяются обычным пробелом.
- Замена или удаление символов, запрещённых в Windows либо потенциально проблемных при переносе: `:`, `<`, `>`, `"`, `\\`, `/`, `|`, `?`, `*`, их перечисленных в коде Unicode-аналогов и некоторых типографских кавычек.
- Дополнительная очистка shell-sensitive символов в режиме `-Strict`: апострофов, скобок, запятых, `;`, `&`, `$`, `!`, обратного апострофа, `^` и `~`.
- Нормализация повторяющихся пробелов и разделителей, удаление завершающих точек и пробелов.
- Защита от пустого результата: такое имя заменяется на `unnamed`.
- Обработка зарезервированных имён Windows (`CON`, `PRN`, `AUX`, `NUL`, `COM1`–`COM9`, `LPT1`–`LPT9`) добавлением начального `_`.
- Разрешение обнаруженных конфликтов путём добавления суффиксов ` (1)`, ` (2)` и далее. Для файлов суффикс добавляется перед последним расширением.
- Отдельная обработка последнего расширения файла: сохраняются точка, буквы Unicode, десятичные цифры, `_` и `-`; остальные символы из расширения удаляются.
- Ограничение результирующего имени файла до 200 единиц `.Length` до проверки конфликта. Известные ограничения этого механизма перечислены ниже.
- Итоговая статистика: сколько объектов проверено, сколько требуют изменения, сколько переименовано и сколько ошибок возникло.

### Параметры

| Параметр | Обязательный | Описание |
| --- | --- | --- |
| `-Path <string>` | Да | Путь к существующему каталогу. Файлы внутри него обрабатываются рекурсивно. |
| `-Apply` | Нет | Выполняет переименование. Без параметра скрипт только показывает предлагаемые изменения. |
| `-Strict` | Нет | Дополнительно очищает перечисленные выше shell-sensitive символы. |
| `-IncludeDirectories` | Нет | Помимо файлов обрабатывает вложенные каталоги. Каталоги идут от самых глубоких к родительским. |

### Требования

- Windows.
- PowerShell. Минимальная версия в самом скрипте не задана.
- Права на чтение целевого дерева каталогов и, при использовании `-Apply`, права на переименование файлов и каталогов в нём.

### Использование

Запускайте команды из каталога, в котором находится `Clean-FileNames.ps1`, либо укажите полный путь к скрипту.

Проверка каталога без изменений:

```powershell
.\Clean-FileNames.ps1 -Path "D:\downloads\Conferences"
```

Фактическое применение изменений:

```powershell
.\Clean-FileNames.ps1 -Path "D:\downloads\Conferences" -Apply
```

Строгая проверка без изменений:

```powershell
.\Clean-FileNames.ps1 -Path "D:\downloads\Conferences" -Strict
```

Проверка файлов и вложенных каталогов без изменений:

```powershell
.\Clean-FileNames.ps1 -Path "D:\downloads\Conferences" -IncludeDirectories
```

Сочетание параметров — строгая обработка файлов и каталогов с применением изменений:

```powershell
.\Clean-FileNames.ps1 -Path "D:\downloads\Conferences" -Strict -IncludeDirectories -Apply
```

При неверном или несуществующем `-Path` скрипт завершится с ошибкой. Ошибки отдельных переименований выводятся в консоль и учитываются в итоговой статистике.

### Текущий статус

Текущая опубликованная версия основана на `Clean-FileNames` v5. Это рабочая версия с dry run и явным применением изменений, но код продолжает дорабатываться. Перечисленные ниже ограничения относятся к текущей реализации и не должны восприниматься как уже исправленные.

### Известные ограничения

- Dry run может неточно прогнозировать итоговое имя при конфликте между двумя объектами, которые ещё не были переименованы: будущие имена в режиме проверки заранее не резервируются.
- Ограничение длины имени файла основано на `.Length` строки, тогда как для Linux/ext4 существенен размер имени в UTF-8 байтах.
- Суффикс разрешения конфликта вида ` (1)` добавляется после ограничения длины и может увеличить имя сверх установленного лимита.
- Для каталогов ограничение длины имени не реализовано.
- Остаются дополнительные Unicode edge cases; текущая версия не гарантирует обработку всех допустимых или проблемных сочетаний Unicode и всех особенностей файловых систем Linux.

### Roadmap

- Ограничение длины с учётом размера имени в UTF-8 байтах.
- Точный dry run с резервированием будущих имён.
- Улучшенная обработка Unicode.
- Журнал переименований.
- Возможность отката переименований.
- Автоматические тесты.

---

## English version

### Purpose

`Clean-FileNames.ps1` is a PowerShell script for checking, cleaning, and normalizing file names before moving data from Windows to Linux, including Proxmox servers.

The script recursively scans files under a specified directory, builds more portable names, and displays a rename plan. By default, it runs in a safe preview mode (dry run) and does not rename anything. Changes are made only when `-Apply` is explicitly specified.

> Run the script without `-Apply` first and carefully review the proposed names before applying any changes. Back up important data before a bulk rename operation.

### Features

- Recursive file processing, including items exposed by `Get-ChildItem -Force`.
- Safe dry run by default, showing each original and proposed name.
- Actual renaming only when `-Apply` is specified.
- Optional processing of nested directories with `-IncludeDirectories`; the root directory supplied through `-Path` is not renamed.
- Unicode NFC normalization. For files, it is applied to the base name; for directories, it is applied to the complete name.
- Removal of selected invisible and control Unicode characters: zero-width characters, BOM/ZWNBSP, bidirectional text marks and controls, and ASCII control characters. Several non-breaking space variants are converted to ordinary spaces.
- Replacement or removal of characters prohibited on Windows or potentially troublesome during transfer: `:`, `<`, `>`, `"`, `\\`, `/`, `|`, `?`, `*`, the Unicode lookalikes explicitly listed in the code, and selected typographic quotation marks.
- Additional removal or replacement of shell-sensitive characters in `-Strict` mode: apostrophes, brackets, commas, `;`, `&`, `$`, `!`, backticks, `^`, and `~`.
- Collapsing repeated whitespace and separators, plus removal of trailing dots and spaces.
- Protection against an empty result by replacing it with `unnamed`.
- Handling of reserved Windows names (`CON`, `PRN`, `AUX`, `NUL`, `COM1`–`COM9`, and `LPT1`–`LPT9`) by adding a leading `_`.
- Resolution of detected conflicts by adding ` (1)`, ` (2)`, and subsequent suffixes. For files, the suffix is inserted before the final extension.
- Separate handling of the final file extension: dots, Unicode letters, decimal digits, `_`, and `-` are retained; other extension characters are removed.
- A 200-`.Length`-unit limit on the resulting file name before conflict detection. See the known limitations below.
- Summary statistics for checked objects, required changes, completed renames, and errors.

### Parameters

| Parameter | Required | Description |
| --- | --- | --- |
| `-Path <string>` | Yes | Path to an existing directory. Files below it are processed recursively. |
| `-Apply` | No | Performs renames. Without this switch, the script only displays proposed changes. |
| `-Strict` | No | Additionally cleans the shell-sensitive characters listed above. |
| `-IncludeDirectories` | No | Processes nested directories in addition to files. Directories are processed from deepest to shallowest. |

### Requirements

- Windows.
- PowerShell. The script does not declare a minimum version.
- Permission to read the target directory tree and, when using `-Apply`, permission to rename files and directories in it.

### Usage

Run these commands from the directory containing `Clean-FileNames.ps1`, or provide the full path to the script.

Preview a directory without making changes:

```powershell
.\Clean-FileNames.ps1 -Path "D:\downloads\Conferences"
```

Apply changes:

```powershell
.\Clean-FileNames.ps1 -Path "D:\downloads\Conferences" -Apply
```

Run a strict preview without making changes:

```powershell
.\Clean-FileNames.ps1 -Path "D:\downloads\Conferences" -Strict
```

Preview files and nested directories without making changes:

```powershell
.\Clean-FileNames.ps1 -Path "D:\downloads\Conferences" -IncludeDirectories
```

Combine switches to process files and directories in strict mode and apply changes:

```powershell
.\Clean-FileNames.ps1 -Path "D:\downloads\Conferences" -Strict -IncludeDirectories -Apply
```

If `-Path` is invalid or does not refer to an existing directory, the script exits with an error. Individual rename errors are printed to the console and included in the final statistics.

### Current status

The currently published release is based on `Clean-FileNames` v5. It is a working version with dry-run previews and explicit change application, but development is ongoing. The limitations below apply to the current implementation and should not be read as already fixed.

### Known limitations

- Dry-run output may predict an inaccurate final name when two objects that have not yet been renamed conflict with one another: future names are not reserved during preview.
- The file-name length limit uses the string's `.Length`, while Linux/ext4 limits are based on the name's size in UTF-8 bytes.
- A conflict suffix such as ` (1)` is added after length limiting and can make a name exceed the configured limit.
- Directory-name length limiting is not implemented.
- Additional Unicode edge cases remain. The current version does not guarantee coverage of every valid or problematic Unicode sequence or every Linux filesystem edge case.

### Roadmap

- UTF-8 byte-aware length limiting.
- Accurate dry runs with reservation of future names.
- Improved Unicode handling.
- Rename logging.
- Rename rollback support.
- Automated tests.
