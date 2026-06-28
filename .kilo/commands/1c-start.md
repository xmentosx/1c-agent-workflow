---
description: Start a 1C feature branch and infobase copy
agent: code
---

Use the `1c-workflow` skill and execute `START_FEATURE`.

Treat any text after `/1c-start` as the proposed feature name. If the feature name is missing, ask for it.

Read `.agents/skills/1c-workflow/references/workflow.md`, ask for missing required parameters, then start the feature workflow.

Prefer the PowerShell helper:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action start-feature -FeatureName "<feature-name>"
```
