## 1C Project Lifecycle

Use `.agents/skills/1c-workflow/SKILL.md` for detailed project initialization, development branch creation, development branch refresh, development branch base update, Vanessa Automation test runs, master sync, development branch listing, branch switching, development branch close, and CF/CFE result export.

For routine lifecycle operations in an already installed project, prefer the short Kilo `/itl-*` commands or `.agents/skills/1c-workflow-fast/SKILL.md`. The fast path runs `.agents/skills/1c-workflow/scripts/agent-1c.ps1` directly and should read detailed workflow references only after helper failure or when the developer asks for explanation.

Use `DEV-BRANCH-DEVELOPMENT.ru.md` for the development process inside a development branch: quick-fix for small local fixes, OpenSpec for business feature work or risky behavior changes.

When asking the developer for missing setup values, ask one value at a time and accept the raw value only. Do not ask for `KEY=value` blocks, one large free-form block with all missing variables, or variable names.

For optional passwords, ask whether the password is set before asking for the value. If the password is not set, store an empty value and do not treat placeholder text as the password.

Before asking for the 1C platform path, search existing standard `C:\Program Files\1cv8` and `C:\Program Files (x86)\1cv8` folders and offer installed versions as choices. Missing standard folders are normal; skip them without error. Do not offer the common `C:\Program Files\1cv8` root as a version.

Do not edit installer-managed `AGENTS.md` directly. Store secrets only in local `.dev.env`.

Write `.dev.env` and `.agent-1c/*.json` files as UTF-8 so Cyrillic usernames and paths are preserved.

Treat `.agent-1c/dev-branches/*.json` as local runtime state. It is ignored by Git because it contains local paths, worktree paths, 1C launcher metadata, verification status, result paths, and unverified override history.

Create new development branches in sibling Git worktrees by default, under `<project-folder>-worktrees/<branch>`, and leave the main project folder on `master`. Use `-UseCurrentWorktree` only when the developer explicitly asks for the legacy single-folder checkout mode.

Use `.agent-1c/infobases/dev-branches` inside the active branch worktree as the default development branch infobase copy root and keep `.agent-1c/infobases/` ignored by Git.

Development branch changes must be loaded only into the development branch infobase copy, never directly into the source infobase connected to 1C configuration repository storage.

Before running ai_rules_1c IB-bound commands such as `/update1cbase`, `/loadfrom1cbase`, or `/getconfigfiles` inside an `itldev/*` branch, ensure the current development branch context is active. The ITL helper does this automatically during branch lifecycle commands.

Do not use `/deploy-and-test` as the normal verification command in an ITL development branch because it reloads all files. The normal executable verification cycle is `/itl-verify`. Use `/itl-update-base` only when you need to update the branch infobase without tests.

Use Vanessa Automation scenarios from `tests/features` for OpenSpec and quick-fix verification. For behavior changes, create or update a small Vanessa Automation check set: at least 2 checks, usually 2-3, and no more than 4 unless explicitly justified. Include the main successful scenario and at least one meaningful boundary or negative scenario. Choose the check type by change kind: unit-like for local logic, integration for object/register/document/exchange interaction, and UI only for forms, commands, or visible user behavior. For large OpenSpec changes, test each meaningful implementation slice separately. If Vanessa finds an error, analyze the report/log, fix it, update the branch base again, and rerun the relevant scenario. Stop and ask the developer only after 3 failed fix attempts for the same group of errors.

For `/itl-result` and `/itl-close`, create `<artifact>.manifest.json` next to the exported CF/CFE. The manifest records artifact SHA256, operation, branch metadata, master/development commits, verification status/report/log, latest 1C log path, publication URL, manual import note, and whether an unverified override was used.

Record current industrial compromises without enforcing them: ideal result/close gating would require fresh passed Vanessa, review, and test report, but the current workflow only warns and requires explicit unverified confirmation; ideal dependency management would use a lock file for `ai_rules_1c`, Vanessa Automation, and SHA256 hashes, but the current workflow uses latest versions and logs archive SHA256 where downloads happen; parallel independent development lines should use separate `itldev/*` branches/worktrees, while one development branch may remain long-lived and contain several sequential tasks.

When Git is on `master`, do not run `/update1cbase` unless the developer explicitly chooses a test infobase. For worktree-created branches, `/itl-switch` shows the target worktree path instead of checking it out over the current folder. The ITL workflow clears active development branch infobase values when switching to `master` or closing a worktree branch.

When launching native Windows executables such as `1cv8.exe` from PowerShell, do not pass a PowerShell array to `Start-Process -ArgumentList`. Join and quote arguments into one native command-line string first, or use the `&` call operator for simple cases. Paths with spaces must remain one native argument; otherwise 1C Designer may exit with code 1 or hang behind `-WindowStyle Hidden`.
