---
description: Export CF from the current 1C development branch
agent: code
---

Use the `1c-workflow` skill and execute `EXPORT_DEV_BRANCH_CF`.

Infer the development branch from the current `itldev/<name>` Git branch. If the current branch is not a development branch and no state can be inferred, ask for a development branch name.

Do not refresh master or merge from storage unless the user explicitly asks for refresh first.

Prefer the PowerShell helper:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action export-dev-branch-cf
```
