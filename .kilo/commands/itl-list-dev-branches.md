---
description: Show active 1C development branches
agent: code
---

Use the `1c-workflow` skill and execute `LIST_DEV_BRANCHES`.

Show active development branches and mark the current development branch based on the active Git branch.

Prefer the PowerShell helper:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action list-dev-branches
```
