---
description: Refresh a 1C feature from storage via master
agent: code
---

Use the `1c-workflow` skill and execute `REFRESH_FEATURE`.

Infer the feature from the current `feature/<name>` Git branch. If the current branch is not a feature branch and no state can be inferred, ask for a feature name.

Refresh master from 1C storage, merge master into the feature branch, and load only changed files into the feature infobase.

Prefer the PowerShell helper:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action refresh-feature
```
