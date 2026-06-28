---
description: Load current 1C config files into the feature infobase
agent: code
---

Use the `1c-workflow` skill and execute `LOAD_FEATURE`.

Infer the feature from the current `feature/<name>` Git branch. If the current branch is not a feature branch and no state can be inferred, ask for a feature name.

Prefer the PowerShell helper:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action load-feature
```
