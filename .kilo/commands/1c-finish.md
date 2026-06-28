---
description: Finish a 1C feature and export CF
agent: code
---

Use the `1c-workflow` skill and execute `FINISH_FEATURE`.

Infer the feature from the current `feature/<name>` Git branch. If the current branch is not a feature branch and no state can be inferred, ask for a feature name.

Confirm the developer has tested the feature and the Git tree is clean, then refresh master, merge master into the feature branch, update the feature infobase, export final CF, and switch back to master.

Prefer the PowerShell helper:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action finish-feature
```
