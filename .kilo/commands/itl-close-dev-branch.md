---
description: Close a 1C development branch and export final CF/CFE result
agent: code
---

Use the `1c-workflow` skill and execute `CLOSE_DEV_BRANCH`.

Infer the development branch from the current `itldev/<name>` Git branch. If the current branch is not a development branch and no state can be inferred, ask for a development branch name.

Confirm the developer has tested the current work and the Git tree is clean, then refresh master from storage or from the current source infobase state, merge master into the development branch, update the development branch infobase only with changed files, export final CF/CFE result, mark the branch closed, and switch back to master.

Prefer the PowerShell helper:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action close-dev-branch
```
