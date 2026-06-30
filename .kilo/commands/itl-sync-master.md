---
description: Sync 1C master branch from repository storage
agent: code
---

Use the `1c-workflow` skill and execute `SYNC_MASTER`.

Read `.agents/skills/1c-workflow/references/workflow.md`, verify the Git worktree is clean, update the source infobase from 1C storage, dump config files, and commit master changes when present.

Prefer the PowerShell helper:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action sync-master
```
