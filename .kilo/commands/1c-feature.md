---
description: Switch to a saved 1C feature branch
agent: code
---

Use the `1c-workflow` skill and execute `SWITCH_FEATURE`.

Treat any text after `/1c-feature` as the proposed feature name. If the feature name cannot be inferred from the current branch or state file, ask for it.

Require a clean Git worktree. Do not load files into 1C automatically.

Prefer the PowerShell helper:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action switch-feature -FeatureName "<feature-name>"
```
