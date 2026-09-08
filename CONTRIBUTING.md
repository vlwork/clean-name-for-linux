# Contributing

## English

Contributions and reproducible bug reports are welcome. Current development takes place on the `v6-development` branch.

### Guidelines

- Keep each contribution focused and avoid mixing unrelated changes.
- PowerShell code must remain compatible with Windows PowerShell 5.1 unless a change explicitly intends to alter that requirement.
- Preserve the existing English/Russian convention for user-facing output.
- Keep comments clear. English and Russian are preferred for substantial comments to match the existing project workflow.
- Preserve Unicode deliberately. Do not add broad NFKC-style normalization or lookalike replacement rules without evidence and targeted tests.
- The ext4 filename-component limit is 255 UTF-8 bytes. Changes to filename construction must preserve that behavior, including extensions and conflict suffixes.
- Changes to core rename behavior should add or update regression coverage.
- GUI and build changes should receive relevant targeted testing.
- Documentation-only changes do not require heavy regression or build runs unless they affect executable behavior or commands being validated.

Before submitting:

1. Inspect the complete diff.
2. Ensure unrelated generated files and build outputs are not included.
3. Run tests appropriate to the change.
4. Describe what changed and how it was verified.

No specific AI or coding assistant is required for contributing. The repository does not currently claim an automated CI workflow; report the local checks you actually performed.

## Русский

Приветствуются изменения и воспроизводимые сообщения об ошибках. Текущая разработка ведётся в ветке `v6-development`.

### Рекомендации

- Не объединяйте несвязанные изменения в одной работе.
- PowerShell-код должен оставаться совместимым с Windows PowerShell 5.1, если изменение явно не предназначено для пересмотра этого требования.
- Сохраняйте существующий формат пользовательских сообщений на английском и русском языках.
- Пишите понятные комментарии. Для существенных комментариев предпочтительны английская и русская формулировки в соответствии с текущим процессом проекта.
- Изменяйте Unicode осознанно. Не добавляйте широкую NFKC-нормализацию или правила замены похожих символов без подтверждения и целевых тестов.
- Лимит одного компонента имени ext4 составляет 255 UTF-8 байт. Изменения формирования имён должны сохранять это поведение, включая расширения и конфликтные суффиксы.
- Изменения основной логики переименования должны сопровождаться новыми или обновлёнными regression tests.
- Изменения GUI и сборки требуют соответствующих целевых проверок.
- Для документационных изменений не нужны тяжёлые regression/build-прогоны, если они не влияют на поведение программы или проверяемые команды.

Перед отправкой:

1. Проверьте полный diff.
2. Убедитесь, что несвязанные generated-файлы и результаты сборки не включены.
3. Запустите проверки, соответствующие изменению.
4. Опишите сделанные изменения и способ их проверки.

Для участия не требуется Codex или другой конкретный AI-инструмент. Репозиторий пока не заявляет наличие автоматического CI; перечисляйте только фактически выполненные локальные проверки.
