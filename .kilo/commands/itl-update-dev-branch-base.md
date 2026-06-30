---
description: Update the current 1C development branch infobase from branch files
agent: code
---

Use the `1c-workflow` skill and execute `UPDATE_DEV_BRANCH_BASE`.

Infer the development branch from the current `itldev/<name>` Git branch. If the current branch is not a development branch and no state can be inferred, ask for a development branch name.

Prefer the PowerShell helper:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action update-dev-branch-base
```
