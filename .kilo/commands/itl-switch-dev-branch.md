---
description: Switch to a saved 1C development branch
agent: code
---

Use the `1c-workflow` skill and execute `SWITCH_DEV_BRANCH`.

Treat any text after `/itl-switch-dev-branch` as the proposed development branch name. If the development branch name cannot be inferred from the current branch or state file, ask for it.

Require a clean Git worktree. Do not load files into 1C automatically.

Prefer the PowerShell helper:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action switch-dev-branch -DevBranchName "<dev-branch-name>"
```
