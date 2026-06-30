---
description: Fast install Vanessa Automation for ITL 1C branch tests
agent: code
---

Run the helper directly from the current project directory:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action install-vanessa-automation
```

If the helper fails, report the concise error first. Open detailed workflow references only when the user asks for explanation or recovery guidance.
