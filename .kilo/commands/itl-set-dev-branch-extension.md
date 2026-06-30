---
description: Set the extension name for the current 1C extension development branch
agent: code
---

Use the `1c-workflow` skill and execute `SET_DEV_BRANCH_EXTENSION`.

Treat any text after `/itl-set-dev-branch-extension` as the extension name. If the extension name is missing, ask for it. If the helper says the extension name is already set, ask for explicit confirmation before rerunning with `-Force`.

Prefer the PowerShell helper:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action set-dev-branch-extension -ExtensionName "<extension-name>"
```
