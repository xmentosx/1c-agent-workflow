---
description: Create an ITL configuration development branch
agent: code
---

Treat any text after `/itl-new-config-branch` as the development branch name. If it is missing, ask for one short value.

Run the helper directly from the current project directory:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action new-dev-branch -DevBranchName "<dev-branch-name>"
```

Report the branch name, copied infobase path, 1C launcher entry, and publication URL when printed. Open detailed workflow references only if the helper fails or the user asks for explanation.
