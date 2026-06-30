## 1C Project Lifecycle

Use `.agents/skills/1c-workflow/SKILL.md` for detailed project initialization, development branch creation, development branch refresh, development branch base update, master sync, development branch listing, branch switching, development branch close, and CF/CFE result export.

For routine lifecycle operations in an already installed project, prefer `.agents/skills/1c-workflow-fast/SKILL.md` or Kilo `/itlx-*` commands. The fast path runs `.agents/skills/1c-workflow/scripts/agent-1c.ps1` directly and should read detailed workflow references only after helper failure or when the developer asks for explanation.

Use `DEV-BRANCH-DEVELOPMENT.ru.md` for the development process inside a development branch: quick-fix for small local fixes, OpenSpec for business feature work or risky behavior changes.

When asking the developer for missing setup values, ask one value at a time and accept the raw value only. Do not ask for `KEY=value` blocks, one large free-form block with all missing variables, or variable names.

For optional passwords, ask whether the password is set before asking for the value. If the password is not set, store an empty value and do not treat placeholder text as the password.

Before asking for the 1C platform path, search existing standard `C:\Program Files\1cv8` and `C:\Program Files (x86)\1cv8` folders and offer installed versions as choices. Missing standard folders are normal; skip them without error. Do not offer the common `C:\Program Files\1cv8` root as a version.

Do not edit installer-managed `AGENTS.md` directly. Store secrets only in local `.dev.env`.

Write `.dev.env` and `.agent-1c/*.json` files as UTF-8 so Cyrillic usernames and paths are preserved.

Use `.agent-1c/infobases/dev-branches` as the default development branch infobase copy root and keep `.agent-1c/infobases/` ignored by Git.

Development branch changes must be loaded only into the development branch infobase copy, never directly into the source infobase connected to 1C configuration repository storage.

Before running ai_rules_1c IB-bound commands such as `/update1cbase`, `/deploy-and-test`, `/loadfrom1cbase`, or `/getconfigfiles` inside an `itldev/*` branch, activate the current development branch context with `/itl-activate-dev-branch-context` or `/itlx-activate-dev-branch-context`. The ITL helper also does this automatically during branch lifecycle commands.

When Git is on `master`, do not run `/update1cbase` unless the developer explicitly chooses a test infobase. The ITL workflow clears active development branch infobase values when switching to `master` or running standalone `sync-master`.

When launching native Windows executables such as `1cv8.exe` from PowerShell, do not pass a PowerShell array to `Start-Process -ArgumentList`. Join and quote arguments into one native command-line string first, or use the `&` call operator for simple cases. Paths with spaces must remain one native argument; otherwise 1C Designer may exit with code 1 or hang behind `-WindowStyle Hidden`.
