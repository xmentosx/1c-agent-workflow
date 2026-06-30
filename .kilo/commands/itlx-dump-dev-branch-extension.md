---
description: Fast dump the current 1C development branch extension to src/cfe
agent: code
---

Run the helper directly from the current project directory:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action dump-dev-branch-extension
```

Do not ask for the extension name. The helper reads it from the current extension development branch state.

If the helper fails, report the concise error and log path first. Open detailed workflow references only when the user asks for explanation or recovery guidance.
