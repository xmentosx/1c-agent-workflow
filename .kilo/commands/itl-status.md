---
description: Show current ITL 1C development status
agent: code
---

Run the helper directly from the current project directory:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action status
```

Report the current branch, infobase, publication URL, verification status, and latest result paths. Open detailed workflow references only if the helper fails or the user asks for explanation.
