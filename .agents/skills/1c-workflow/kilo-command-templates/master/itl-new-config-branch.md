---
description: Create an ITL configuration development branch
agent: code
---

Use this command only from the `master` worktree. Treat any text after `/itl-new-config-branch` as the development branch name. If it is missing, ask for one short value.

Run the helper directly from the current project directory:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action new-dev-branch -DevBranchName "<dev-branch-name>"
```

The helper creates a sibling Git worktree by default and leaves the current project folder on `master`. Report the branch name, copied infobase path, worktree path, 1C launcher entry, and publication URL when printed. Tell the developer to open a separate Codex/Kilo/IDE window in the printed worktree folder. Use `-UseCurrentWorktree` only if the developer explicitly asks for the legacy single-folder checkout mode. Open detailed workflow references only if the helper fails or the user asks for explanation.
