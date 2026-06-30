---
description: Fast switch to the 1C project master branch
agent: code
---

Run the helper directly from the current project directory:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action switch-master
```

Do not load the full workflow skill first. The helper requires a clean Git worktree and does not load files into 1C automatically.

If the helper fails, report the concise error and log path first. Open detailed workflow references only when the user asks for explanation or recovery guidance.
