---
description: Initialize a 1C agent project
agent: code
---

Use the `1c-workflow` skill and execute `INIT_PROJECT`.

Read `.agents/skills/1c-workflow/references/workflow.md`, ask for missing required parameters including the feature infobase copies directory, create/update the project state files, check required software, then run the project initialization workflow.

Prefer the PowerShell helper:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action init-project
```
