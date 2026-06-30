---
description: Fast run Vanessa Automation tests for the current ITL 1C development branch
agent: code
---

Run the helper directly from the current project directory:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action run-dev-branch-tests
```

Do not call `/deploy-and-test` for this fast command. It must not load configuration files; it only runs Vanessa Automation against the already updated development branch infobase.

If the helper fails, report the concise error and log path first. Open detailed workflow references only when the user asks for explanation or recovery guidance.
