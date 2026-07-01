---
description: Create an ITL extension development branch
agent: code
---

Treat any text after `/itl-new-extension-branch` as the development branch name. If it is missing, ask for one short value. Do not ask for the extension name during branch creation.

Run the helper directly from the current project directory:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action new-extension-dev-branch -DevBranchName "<dev-branch-name>"
```

The helper creates a sibling Git worktree by default and leaves the current project folder on `master`. Report the branch name, copied infobase path, worktree path, 1C launcher entry, and publication URL when printed. Tell the developer to open a separate Codex/Kilo/IDE window in the printed worktree folder. Use `-UseCurrentWorktree` only if the developer explicitly asks for the legacy single-folder checkout mode. Open detailed workflow references only if the helper fails or the user asks for explanation.
