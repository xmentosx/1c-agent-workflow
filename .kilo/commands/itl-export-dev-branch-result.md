---
description: Export CF or CFE result from the current 1C development branch
agent: code
---

Use the `1c-workflow` skill and execute `EXPORT_DEV_BRANCH_RESULT`.

Infer the development branch from the current `itldev/<name>` Git branch. Do not ask for a development branch name when the current branch is already a development branch.

Do not refresh master or merge fresh source changes unless the user explicitly asks for refresh first.

Prefer the PowerShell helper:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action export-dev-branch-result
```
