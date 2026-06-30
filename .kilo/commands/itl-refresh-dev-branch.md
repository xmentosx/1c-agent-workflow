---
description: Refresh a 1C development branch via master
agent: code
---

Use the `1c-workflow` skill and execute `REFRESH_DEV_BRANCH`.

Infer the development branch from the current `itldev/<name>` Git branch. If the current branch is not a development branch and no state can be inferred, ask for a development branch name.

Refresh master from 1C storage or from the current source infobase state, merge master into the development branch, and update the development branch infobase only with changed files. In manual source mode, the developer must update the source infobase before this command when fresh external changes are needed.

Prefer the PowerShell helper:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action refresh-dev-branch
```
