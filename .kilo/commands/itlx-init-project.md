---
description: Fast init for a 1C agent project
agent: code
---

Run the helper directly from the current project directory:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action init-project
```

Do not load the full workflow skill first. If the helper reports missing setup values that require the detailed questionnaire, tell the developer to use `/itl-init-project` for the full initialization flow.

If the helper fails, report the concise error and log path first. Open detailed workflow references only when the user asks for explanation or recovery guidance.
