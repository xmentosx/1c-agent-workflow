---
description: Export CF from the current 1C feature
agent: code
---

Use the `1c-workflow` skill and execute `EXPORT_FEATURE_CF`.

Infer the feature from the current `feature/<name>` Git branch. If the current branch is not a feature branch and no state can be inferred, ask for a feature name.

Do not refresh master or merge from storage unless the user explicitly asks for refresh first.

Prefer the PowerShell helper:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action export-feature-cf
```
