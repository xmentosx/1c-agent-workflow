---
description: Sync 1C master branch from source infobase
agent: code
---

Use the `1c-workflow` skill and execute `SYNC_MASTER`.

Read `.agents/skills/1c-workflow/references/workflow.md`, verify the Git worktree is clean, update the source infobase from 1C storage only when repository mode is enabled, dump config files, and commit master changes when present. In manual source mode, the developer must update the source infobase before running this command when fresh external changes are needed.

Prefer the PowerShell helper:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action sync-master
```
