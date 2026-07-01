---
description: Set the extension name for the current ITL extension branch
agent: code
---

Treat any text after `/itl-set-dev-branch-extension` as the extension name. If it is missing, ask for one short value. This command is only for an existing extension development branch.

Run the helper directly from the current project directory:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action set-dev-branch-extension -ExtensionName "<extension-name>"
```

Report the saved extension name and extension export path. Open detailed workflow references only if the helper fails or the user asks for explanation.
