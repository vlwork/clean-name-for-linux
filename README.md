# Clean Name for Linux

Windows tool for reviewing, cleaning, and normalizing file and directory names before moving data to Linux systems, including Proxmox hosts.

This branch is preparing the `6.0.0-preview.1` prerelease. See the [release notes](docs/release-notes-v6.0.0-preview.1.md), [changelog](CHANGELOG.md), and [release checklist](docs/RELEASE-CHECKLIST.md).

[Русская версия](#русская-версия)

## What it does

Clean Name for Linux scans a selected directory recursively and builds a deterministic rename plan. It can be used through the Windows GUI, the single-file GUI executable, or the PowerShell CLI.

Key behavior:

- dry run by default; renaming requires an explicit Apply action or `-Apply`;
- recursive file scanning and optional nested-directory renaming;
- Normal and Strict sanitization modes;
- Unicode NFC normalization with preservation of meaningful ZWJ/ZWNJ characters and removal or replacement of selected invisible, control, compatibility, and Windows-forbidden characters;
- Linux/ext4 component limits enforced as 255 UTF-8 bytes, without splitting Unicode text elements;
- preservation of the final file extension where possible;
- deterministic conflict resolution with ` (1)`, ` (2)`, and later suffixes while keeping the final component within 255 UTF-8 bytes;
- dry-run conflict planning that reserves future names so the plan matches Apply when the filesystem does not change;
- bilingual English/Russian GUI and CLI output;
- automated regression tests and a performance benchmark.

The tool improves Windows/Linux filename portability. It does not make names universally POSIX-shell-safe; quote file paths when using them in a shell.

## Standalone EXE

The planned release contains exactly these user artifacts:

```text
Clean-File-Names.exe
Clean-File-Names.exe.sha256
```

The EXE is a Windows 10/11 x64, no-console, single-file application with the core script embedded. It does not need a separate `Clean-FileNames.ps1`, configuration file, or PowerShell 7 installation beside it. Administrator rights are not requested, but the current user must have permission to enumerate and rename items in the selected directory.

The preview executable is unsigned. Windows SmartScreen may therefore display a warning, especially for a newly downloaded file with low reputation.

Recommended workflow:

1. Download the EXE and its `.sha256` sidecar.
2. Verify the checksum.
3. Run `Clean-File-Names.exe`.
4. Select a folder with Browse or drag and drop.
5. Choose Normal/Strict behavior and whether directories should be renamed.
6. Run Scan and review every proposed rename.
7. Back up important data before a bulk rename.
8. Select Apply changes only after reviewing the plan.

Renaming changes filesystem names immediately; it is not a copy or repair operation.

## Verification

To verify the download in PowerShell:

```powershell
$actual = (Get-FileHash -Algorithm SHA256 .\Clean-File-Names.exe).Hash
$expected = ((Get-Content .\Clean-File-Names.exe.sha256 -Raw).Trim() -split '\s+')[0]
$actual -eq $expected
```

The result should be `True`. The README intentionally does not hard-code a build hash; compare against the sidecar shipped with the same EXE.

## Windows GUI

The GUI presents a read-only rename plan and summary counters. Scanning runs in the background, keeps the interface responsive, and can be cancelled. Changing the folder, Strict option, or directory option invalidates the current plan and disables Apply.

- Folder selects the scan root through Browse, text entry, or drag and drop.
- Strict mode enables the additional punctuation pass.
- Rename directories includes nested directories; the selected root is excluded.
- Scan builds the preview, Cancel scan stops an active scan, and Apply changes starts the guarded rename workflow.

Apply uses this sequence:

```text
Scan → review plan → confirmation → fresh plan revalidation → Apply
```

If the fresh plan differs from the scanned plan, no rename is attempted and the user must scan again. Revalidation minimizes, but cannot completely eliminate, an external filesystem race between the last check and `Rename-Item`.

## Normal and Strict modes

| Mode | Behavior |
| --- | --- |
| Normal | Applies common Windows/Linux compatibility cleanup while preserving safe linguistic punctuation, commas, meaningful combining marks, ZWJ/ZWNJ, and other valid text where implemented. |
| Strict | Includes Normal cleanup and additionally reduces selected shell-sensitive characters such as grouping brackets, semicolons, ampersands, dollar signs, exclamation marks, backticks, carets, and tildes. Apostrophes are normalized to U+02BC. Strict output must still be quoted in shells. |

Verified examples:

```text
Normal: target？.txt          → target.txt
Strict: Schindler's List.mkv → Schindlerʼs List.mkv
Strict: Film (2024).mkv      → Film 2024.mkv
Strict: R&D $Final!.docx     → R + D Final.docx
```

## UTF-8 filename limits

Linux/ext4 limits one filename component to 255 bytes, not 255 characters. The core measures UTF-8 bytes and truncates at Unicode text-element boundaries. For files, the available budget accounts for the final extension; conflict candidates dynamically account for the complete ` (N)` suffix and preserve the extension when possible. Directory names use the same 255-byte component limit without file-extension semantics.

## Run from source

The source workflow has been tested with Windows PowerShell 5.1. The GUI source requires `Clean-FileNames.ps1` beside it.

```powershell
powershell.exe -NoProfile -Sta -ExecutionPolicy Bypass `
    -File .\Clean-FileNames-GUI.ps1
```

CLI parameters:

| Parameter | Required | Description |
| --- | --- | --- |
| `-Path <string>` | Yes | Existing root directory. Files below it are scanned recursively. The root itself is not renamed. |
| `-Apply` | No | Performs the planned renames. Without it, the CLI is a dry run. |
| `-Strict` | No | Enables the additional Strict sanitization pass. |
| `-IncludeDirectories` | No | Also processes nested directories, deepest first. |

Preview without changes:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\Clean-FileNames.ps1 -Path 'D:\Media'
```

Apply after reviewing the dry run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\Clean-FileNames.ps1 -Path 'D:\Media' -Apply
```

Strict preview:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\Clean-FileNames.ps1 -Path 'D:\Media' -Strict
```

Preview files and nested directories:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\Clean-FileNames.ps1 -Path 'D:\Media' -IncludeDirectories
```

The switches can be combined when the combined preview has been reviewed.

Always run without `-Apply` first. Keep a current backup of important data before bulk renaming.

## Development

Run the regression suite:

```powershell
powershell.exe -NoProfile -Sta -ExecutionPolicy Bypass `
    -File .\tests\Test-CleanFileNames.ps1
```

Run a small benchmark sample:

```powershell
powershell.exe -NoProfile -Sta -ExecutionPolicy Bypass `
    -File .\benchmarks\Measure-Performance.ps1 -FileCount 1000 -Runs 3
```

Create a clean release build:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\build\Build-Exe.ps1 -Clean
```

The build requires the pinned PS2EXE `1.0.18` module and runs tests by default. See [build/README.md](build/README.md) for setup and build-only switches.

## Current status

`6.0.0-preview.1` is a prerelease candidate based on the v6 development line. It has automated coverage for the CLI, GUI logic, embedded/external core equivalence, conflict planning, Apply revalidation, cancellation, and packaging integrity. It should be tested with representative data before a stable release.

The project is licensed under the GNU General Public License v3.0 only (`GPL-3.0-only`). See [LICENSE](LICENSE).

## Known limitations

- Renames are not transactional and there is no rename journal or automatic rollback.
- External changes can still occur between final plan revalidation and the underlying `Rename-Item` calls.
- The root directory passed through `-Path` is never renamed.
- The EXE is unsigned, so SmartScreen may warn; SHA-256 verifies integrity but is not code signing.
- Conflict planning follows Windows case-insensitive filename ownership rules.
- Sanitization covers the implemented Unicode cases and does not guarantee every Unicode or filesystem edge case.
- Strict mode reduces selected metacharacters but does not guarantee a shell-safe unquoted name.
- The application is Windows-focused. The EXE is not a Linux or macOS executable, and source/CLI use is documented for PowerShell on Windows.
- PS2EXE compiler metadata such as timestamps and MVIDs makes independently compiled EXEs non-identical at the byte level; always verify the supplied sidecar for the specific artifact.

---

## Русская версия

Clean Name for Linux — Windows-инструмент для проверки, очистки и нормализации имён файлов и каталогов перед переносом данных на Linux-системы, включая узлы Proxmox.

В этой ветке подготавливается предварительный выпуск `6.0.0-preview.1`. См. [заметки о выпуске](docs/release-notes-v6.0.0-preview.1.md), [журнал изменений](CHANGELOG.md) и [чек-лист выпуска](docs/RELEASE-CHECKLIST.md).

### Назначение и возможности

Программа рекурсивно проверяет выбранный каталог и строит детерминированный план переименований. Доступны Windows GUI, однофайловый GUI EXE и PowerShell CLI.

Основное поведение:

- по умолчанию выполняется безопасная проверка без изменений; переименование требует Apply или `-Apply`;
- файлы проверяются рекурсивно, обработка вложенных каталогов включается отдельно;
- доступны режимы Normal и Strict;
- выполняется Unicode NFC-нормализация, сохраняются значимые ZWJ/ZWNJ и удаляются либо заменяются реализованные в коде невидимые, управляющие, compatibility- и запрещённые Windows символы;
- лимит компонента Linux/ext4 контролируется как 255 UTF-8 байт без разрезания Unicode text elements;
- последнее расширение файла по возможности сохраняется;
- конфликты разрешаются детерминированными суффиксами ` (1)`, ` (2)` и далее с соблюдением лимита 255 байт;
- dry run резервирует будущие имена, поэтому при неизменившейся файловой системе план совпадает с Apply;
- GUI и CLI выводят сообщения на английском и русском языках;
- в проекте есть автоматические regression tests и performance benchmark.

Инструмент повышает переносимость имён между Windows и Linux, но не делает их универсально безопасными для POSIX shell. В командах оболочки заключайте пути в кавычки.

### Автономный EXE

Для выпуска запланированы ровно два пользовательских артефакта:

```text
Clean-File-Names.exe
Clean-File-Names.exe.sha256
```

EXE — однофайловое x64-приложение без консольного окна для Windows 10/11. Основной скрипт встроен: рядом не нужны отдельные `Clean-FileNames.ps1`, config-файл или PowerShell 7. Программа не запрашивает права администратора, но пользователю нужны права на просмотр и переименование объектов в выбранном каталоге.

Предварительный EXE не подписан. Поэтому Windows SmartScreen может показать предупреждение, особенно для нового загруженного файла без репутации.

Рекомендуемый порядок работы:

1. Загрузите EXE и соответствующий `.sha256`.
2. Проверьте контрольную сумму.
3. Запустите `Clean-File-Names.exe`.
4. Выберите папку кнопкой Browse или перетащите её в окно.
5. Выберите режим Normal/Strict и необходимость переименования каталогов.
6. Выполните Scan и проверьте каждое предлагаемое имя.
7. Перед массовым переименованием сделайте резервную копию важных данных.
8. Нажимайте Apply changes только после проверки плана.

Переименование сразу изменяет имена в файловой системе; это не копирование и не восстановление данных.

### Проверка файла

Проверка загруженного файла в PowerShell:

```powershell
$actual = (Get-FileHash -Algorithm SHA256 .\Clean-File-Names.exe).Hash
$expected = ((Get-Content .\Clean-File-Names.exe.sha256 -Raw).Trim() -split '\s+')[0]
$actual -eq $expected
```

Результат должен быть `True`. Хэш сборки намеренно не зафиксирован в README: сравнивайте EXE с sidecar из того же выпуска.

### Графический интерфейс Windows

GUI показывает read-only план и итоговые счётчики. Scan выполняется в фоне, интерфейс остаётся отзывчивым, проверку можно отменить. Изменение папки, режима Strict или обработки каталогов аннулирует текущий план и отключает Apply.

- Folder задаёт корень проверки через Browse, ввод пути или drag and drop.
- Strict mode включает дополнительную обработку пунктуации.
- Rename directories добавляет вложенные каталоги, но не выбранный корень.
- Scan строит план, Cancel scan останавливает активную проверку, Apply changes запускает защищённый сценарий переименования.

Последовательность Apply:

```text
Scan → проверка плана → подтверждение → повторная проверка свежего плана → Apply
```

Если свежий план отличается от показанного, переименование не начинается и требуется повторный Scan. Такая проверка уменьшает, но не устраняет полностью возможность внешнего изменения файловой системы между последней проверкой и `Rename-Item`.

### Режимы Normal и Strict

| Режим | Поведение |
| --- | --- |
| Normal | Выполняет общую очистку для совместимости Windows/Linux, сохраняя безопасную языковую пунктуацию, запятые, значимые combining marks, ZWJ/ZWNJ и другой допустимый текст в пределах реализованных правил. |
| Strict | Включает Normal и дополнительно уменьшает число выбранных shell-sensitive символов: группирующих скобок, `;`, `&`, `$`, `!`, обратных апострофов, `^` и `~`. Апострофы приводятся к U+02BC. Даже Strict-имена необходимо заключать в кавычки в shell. |

Проверенные примеры:

```text
Normal: target？.txt          → target.txt
Strict: Schindler's List.mkv → Schindlerʼs List.mkv
Strict: Film (2024).mkv      → Film 2024.mkv
Strict: R&D $Final!.docx     → R + D Final.docx
```

### Лимит имён в UTF-8

Linux/ext4 ограничивает один компонент имени 255 байтами, а не 255 символами. Ядро считает UTF-8 байты и сокращает строки только по границам Unicode text elements. Для файлов бюджет учитывает последнее расширение; при конфликтах динамически учитывается полный суффикс ` (N)`, а расширение сохраняется по возможности. Для каталогов применяется тот же лимит в 255 байт без файловой семантики расширений.

### Запуск из исходников

Работа из исходников проверена в Windows PowerShell 5.1. Для GUI-файла `Clean-FileNames.ps1` должен находиться рядом.

```powershell
powershell.exe -NoProfile -Sta -ExecutionPolicy Bypass `
    -File .\Clean-FileNames-GUI.ps1
```

Параметры CLI:

| Параметр | Обязательный | Описание |
| --- | --- | --- |
| `-Path <string>` | Да | Существующий корневой каталог. Файлы внутри проверяются рекурсивно; сам корень не переименовывается. |
| `-Apply` | Нет | Выполняет запланированные переименования. Без параметра CLI работает как dry run. |
| `-Strict` | Нет | Включает дополнительный Strict post-pass. |
| `-IncludeDirectories` | Нет | Также обрабатывает вложенные каталоги от самых глубоких к родительским. |

Проверка без изменений:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\Clean-FileNames.ps1 -Path 'D:\Media'
```

Применение после проверки dry run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\Clean-FileNames.ps1 -Path 'D:\Media' -Apply
```

Strict-проверка:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\Clean-FileNames.ps1 -Path 'D:\Media' -Strict
```

Проверка файлов и вложенных каталогов:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\Clean-FileNames.ps1 -Path 'D:\Media' -IncludeDirectories
```

Параметры можно сочетать после проверки соответствующего комбинированного плана.

Всегда сначала запускайте CLI без `-Apply`. Перед массовым переименованием храните актуальную резервную копию важных данных.

### Разработка

Regression suite:

```powershell
powershell.exe -NoProfile -Sta -ExecutionPolicy Bypass `
    -File .\tests\Test-CleanFileNames.ps1
```

Небольшой benchmark:

```powershell
powershell.exe -NoProfile -Sta -ExecutionPolicy Bypass `
    -File .\benchmarks\Measure-Performance.ps1 -FileCount 1000 -Runs 3
```

Чистая release-сборка:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\build\Build-Exe.ps1 -Clean
```

Для сборки требуется зафиксированный модуль PS2EXE `1.0.18`; тесты запускаются по умолчанию. Настройка и build-only параметры описаны в [build/README.md](build/README.md).

### Текущий статус

`6.0.0-preview.1` — кандидат на предварительный выпуск из ветки разработки v6. Автоматические тесты покрывают CLI, логику GUI, эквивалентность встроенного и внешнего ядра, планирование конфликтов, повторную проверку перед Apply, отмену и целостность упаковки. До стабильного выпуска программу следует проверить на репрезентативных данных.

Проект распространяется только по GNU General Public License v3.0 (`GPL-3.0-only`). Полный текст лицензии: [LICENSE](LICENSE).

### Известные ограничения

- Переименования не транзакционные; журнала переименований и автоматического отката нет.
- Между финальной проверкой плана и вызовами `Rename-Item` всё ещё возможно внешнее изменение файловой системы.
- Корневой каталог из `-Path` не переименовывается.
- EXE не подписан, поэтому SmartScreen может предупредить; SHA-256 проверяет целостность, но не заменяет подпись кода.
- Планирование конфликтов следует регистронезависимым правилам владения именами Windows.
- Обработка охватывает реализованные Unicode-случаи, но не гарантирует все Unicode- и filesystem edge cases.
- Strict уменьшает число выбранных метасимволов, но не гарантирует безопасное имя без кавычек в shell.
- Проект ориентирован на Windows. EXE не запускается в Linux или macOS, а исходный CLI документирован для PowerShell в Windows.
- Из-за метаданных компилятора PS2EXE, включая timestamp и MVID, независимо собранные EXE не совпадают побайтно; проверяйте sidecar конкретного артефакта.
