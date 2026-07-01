---
description: Switch between ITL master and development branches
agent: code
---

Treat any text after `/itl-switch` as the target. If the target is missing, ask for `master` or one development branch name.

For `master`, run:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action switch-master
```

For any other value, run:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action switch-dev-branch -DevBranchName "<dev-branch-name>"
```

Require a clean Git worktree. Do not update the 1C infobase during switching.
