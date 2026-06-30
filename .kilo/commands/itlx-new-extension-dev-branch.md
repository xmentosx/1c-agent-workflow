---
description: Fast create a 1C extension development branch and infobase copy
agent: code
---

Treat any text after `/itlx-new-extension-dev-branch` as the development branch name. If it is missing, ask one short question for the name only. Do not ask for the extension name during branch creation.

Run the helper directly from the current project directory:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action new-extension-dev-branch -DevBranchName "<dev-branch-name>"
```

If the helper fails, report the concise error and log path first. Open detailed workflow references only when the user asks for explanation or recovery guidance.
