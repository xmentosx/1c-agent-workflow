---
description: Refresh a 1C development branch from storage via master
agent: code
---

Use the `1c-workflow` skill and execute `REFRESH_DEV_BRANCH`.

Infer the development branch from the current `itldev/<name>` Git branch. If the current branch is not a development branch and no state can be inferred, ask for a development branch name.

Refresh master from 1C storage, merge master into the development branch, and load only changed files into the development branch infobase.

Prefer the PowerShell helper:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action refresh-dev-branch
```
