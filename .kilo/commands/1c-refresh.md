---
description: Refresh a 1C feature from storage via master
agent: code
---

Use the `1c-workflow` skill and execute `REFRESH_FEATURE`.

Treat any text after `/1c-refresh` as the proposed feature name. If the feature name cannot be inferred from the current branch or state file, ask for it.

Refresh master from 1C storage, merge master into the feature branch, and load the merged files into the feature infobase.

Prefer the PowerShell helper:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action refresh-feature -FeatureName "<feature-name>"
```
