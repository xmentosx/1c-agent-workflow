## 1C Project Lifecycle

Use `.agents/skills/1c-workflow/SKILL.md` for project initialization, feature start, feature refresh, feature load, master sync, feature listing, branch switching, feature finish, and CF export.

Use `FEATURE-DEVELOPMENT.ru.md` for the development process inside a feature branch: quick-fix for small local fixes, OpenSpec for feature work or risky behavior changes.

When asking the developer for missing setup values, ask one value at a time and accept the raw value only. Do not ask for `KEY=value` blocks, one large free-form block with all missing variables, or variable names.

For optional passwords, ask whether the password is set before asking for the value. If the password is not set, store an empty value and do not treat placeholder text as the password.

Before asking for the 1C platform path, search existing standard `C:\Program Files\1cv8` and `C:\Program Files (x86)\1cv8` folders and offer installed versions as choices. Missing standard folders are normal; skip them without error. Do not offer the common `C:\Program Files\1cv8` root as a version.

Do not edit installer-managed `AGENTS.md` directly. Store secrets only in local `.dev.env`.

Write `.dev.env` and `.agent-1c/*.json` files as UTF-8 so Cyrillic usernames and paths are preserved.

Use `.agent-1c/infobases/features` as the default feature infobase copy root and keep `.agent-1c/infobases/` ignored by Git.

Feature changes must be loaded only into the feature infobase copy, never directly into the source infobase connected to 1C configuration repository storage.

When launching native Windows executables such as `1cv8.exe` from PowerShell, do not pass a PowerShell array to `Start-Process -ArgumentList`. Join and quote arguments into one native command-line string first, or use the `&` call operator for simple cases. Paths with spaces must remain one native argument; otherwise 1C Designer may exit with code 1 or hang behind `-WindowStyle Hidden`.
