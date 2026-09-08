# Security Policy

## English

### Supported version

The current security focus is the published `6.0.0-preview.x` line. Security fixes may be applied to the active development branch and included in a subsequent preview or release. Support is not promised for older versions.

### Reporting a vulnerability

Do not publish exploit details, sensitive filesystem data, private filenames, or other vulnerability details in a normal public issue.

- If GitHub Private Vulnerability Reporting is available for this repository, use it.
- If it is unavailable, open only a minimal public issue asking the maintainer for a private reporting method. Do not include technical exploit details or sensitive information.

No security email address or other private contact channel is currently documented by the project.

Security-relevant examples include:

- unsafe or unintended file renaming or deletion behavior;
- path handling that could affect files outside the selected scope;
- command or script injection;
- integrity problems in the embedded core or build path;
- security-relevant handling of untrusted filenames.

Ordinary filename-cleanup bugs without a security impact should use the Bug report template. An unsigned EXE or SmartScreen warning alone is not a vulnerability. The SHA-256 sidecar can be used to check that a downloaded EXE matches the checksum published with the release; it does not authenticate the publisher and is not a substitute for Authenticode signing.

## Русский

### Поддерживаемая версия

Текущий приоритет безопасности — опубликованная ветка `6.0.0-preview.x`. Исправления безопасности могут вноситься в активную ветку разработки и включаться в следующий preview или release. Поддержка старых версий не обещается.

### Сообщение об уязвимости

Не публикуйте описание эксплуатации, конфиденциальные данные файловой системы, личные имена файлов или другие подробности уязвимости в обычном публичном issue.

- Если для репозитория доступен GitHub Private Vulnerability Reporting, используйте его.
- Если он недоступен, создайте только краткий публичный issue с просьбой предоставить приватный способ связи. Не включайте технические детали эксплуатации или конфиденциальные сведения.

Проект пока не публикует адрес электронной почты или другой приватный канал для сообщений о безопасности.

Примеры вопросов безопасности:

- небезопасное или непреднамеренное переименование либо удаление файлов;
- обработка путей, способная затронуть файлы вне выбранной области;
- внедрение команд или скриптов;
- нарушения целостности встроенного ядра или процесса сборки;
- значимая для безопасности обработка недоверенных имён файлов.

Обычные ошибки очистки имён без последствий для безопасности следует отправлять через шаблон Bug report. Само по себе отсутствие подписи EXE или предупреждение SmartScreen не является уязвимостью. Sidecar SHA-256 можно использовать, чтобы проверить соответствие загруженного EXE контрольной сумме, опубликованной вместе с выпуском; такая проверка не удостоверяет издателя и не заменяет подпись Authenticode.
