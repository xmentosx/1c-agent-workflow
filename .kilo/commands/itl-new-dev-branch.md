---
description: Create a 1C development branch and infobase copy
agent: code
---

Use the `1c-workflow` skill and execute `NEW_DEV_BRANCH`.

Treat any text after `/itl-new-dev-branch` as the proposed development branch name. If the development branch name is missing, ask for it.

Read `.agents/skills/1c-workflow/references/workflow.md`, ask for missing required parameters, then create the development branch workflow. The helper registers the copied infobase in the 1C launcher list under `/ITL/<project-root-name>`.

Prefer the PowerShell helper:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action new-dev-branch -DevBranchName "<dev-branch-name>"
```
