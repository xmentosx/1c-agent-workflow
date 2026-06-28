---
description: Finish a 1C feature and export CF
agent: code
---

Use the `1c-workflow` skill and execute `FINISH_FEATURE`.

Treat any text after `/1c-finish` as the proposed feature name. If the feature name cannot be inferred from the current branch or state file, ask for it.

Confirm the developer has tested the feature and the Git tree is clean, then refresh master, merge master into the feature branch, update the feature infobase, export final CF, and switch back to master.

Prefer the PowerShell helper:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action finish-feature -FeatureName "<feature-name>"
```
