---
description: Fast set the extension name for the current 1C extension development branch
agent: code
---

Treat any text after `/itlx-set-dev-branch-extension` as the extension name. If it is missing, ask one short question for the name only.

Run the helper directly from the current project directory:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action set-dev-branch-extension -ExtensionName "<extension-name>"
```

If the helper says the extension name is already set, ask for explicit confirmation before rerunning with `-Force`.

If the helper fails, report the concise error and log path first. Open detailed workflow references only when the user asks for explanation or recovery guidance.
