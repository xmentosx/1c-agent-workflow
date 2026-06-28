---
description: Export CF from the current 1C feature
agent: code
---

Use the `1c-workflow` skill and execute `EXPORT_FEATURE_CF`.

Treat any text after `/1c-cf` as the proposed feature name. If the feature name cannot be inferred from the current branch or state file, ask for it.

Do not refresh master or merge from storage unless the user explicitly asks for refresh first.

Prefer the PowerShell helper:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action export-feature-cf -FeatureName "<feature-name>"
```
