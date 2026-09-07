# EXE build / Сборка EXE

Prerequisite: PS2EXE `1.0.18` installed for the current user.

Требование: PS2EXE `1.0.18`, установленный для текущего пользователя.

Product version: `6.0.0-preview.1`. Windows file/assembly version: `6.0.0.0`.

Версия продукта: `6.0.0-preview.1`. Версия файла/сборки Windows: `6.0.0.0`.

```powershell
Install-Module -Name ps2exe -RequiredVersion 1.0.18 -Scope CurrentUser
```

## Build / Сборка

Run from Windows PowerShell 5.1. Tests run by default.

Запускайте из Windows PowerShell 5.1. По умолчанию перед сборкой выполняются тесты.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\build\Build-Exe.ps1
```

Output / Результат:

```text
dist\Clean-File-Names.exe
dist\Clean-File-Names.exe.sha256
```

Clean build / Чистая сборка:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\build\Build-Exe.ps1 -Clean
```

For development only, tests can be skipped with `-SkipTests`. The build prints an explicit warning. Use `-KeepGeneratedScript` to retain `build\obj\Clean-File-Names.embedded.ps1` for inspection.

Только при разработке тесты можно пропустить параметром `-SkipTests`; build script выводит явное предупреждение. Параметр `-KeepGeneratedScript` сохраняет `build\obj\Clean-File-Names.embedded.ps1` для проверки.
