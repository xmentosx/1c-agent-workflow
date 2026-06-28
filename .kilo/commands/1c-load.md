---
description: Load current 1C config files into the feature infobase
agent: code
---

Use the `1c-workflow` skill and execute `LOAD_FEATURE`.

If the feature name cannot be inferred from the current Git branch or state file, ask for it.

Prefer the PowerShell helper:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action load-feature -FeatureName "<feature-name>"
```
