---
description: Show 1C features in development
agent: code
---

Use the `1c-workflow` skill and execute `LIST_FEATURES`.

Show features in development and mark the current feature based on the active Git branch.

Prefer the PowerShell helper:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action list-features
```
