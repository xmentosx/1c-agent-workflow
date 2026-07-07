---
description: Create an ITL extension development branch
agent: code
---

Use this command only from the `master` worktree. Treat any text after `/itl-new-extension-branch` as the development branch name. If it is missing, ask for one short value.

Run the helper directly from the current project directory:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action new-extension-dev-branch -DevBranchName "<dev-branch-name>"
```

The helper creates a sibling Git worktree and a branch infobase copy. It does not create the extension object itself. After opening the printed worktree folder, ask the agent to set up the extension name and dump extension files when the extension has been created in the branch infobase.
