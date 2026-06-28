---
description: Switch to the 1C project master branch
agent: code
---

Use the `1c-workflow` skill and execute `SWITCH_MASTER`.

Require a clean Git worktree. Do not pull and do not load files into 1C automatically.

Prefer the PowerShell helper:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action switch-master
```
