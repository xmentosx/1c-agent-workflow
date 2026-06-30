---
description: Fast create a 1C development branch and infobase copy
agent: code
---

Treat any text after `/itlx-new-dev-branch` as the development branch name. If it is missing, ask one short question for the name only.

Run the helper directly from the current project directory:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action new-dev-branch -DevBranchName "<dev-branch-name>"
```

Do not load the full workflow skill first. The helper owns Git checks, branch creation, infobase copy, repository unbind when needed, launcher registration, and optional Apache publication.

If the helper fails, report the concise error and log path first. Open detailed workflow references only when the user asks for explanation or recovery guidance.
