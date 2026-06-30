---
description: Fast switch to a saved 1C development branch
agent: code
---

Treat any text after `/itlx-switch-dev-branch` as the development branch name. If it is missing, ask one short question for the name only.

Run the helper directly from the current project directory:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action switch-dev-branch -DevBranchName "<dev-branch-name>"
```

Do not load the full workflow skill first. The helper requires a clean Git worktree and does not load files into 1C automatically.

If the helper fails, report the concise error and log path first. Open detailed workflow references only when the user asks for explanation or recovery guidance.
