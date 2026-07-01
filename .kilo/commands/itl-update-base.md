---
description: Update the current ITL branch infobase from branch files
agent: code
---

Run the helper directly from the current project directory:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action update-dev-branch-base
```

Do not ask for a development branch name. The helper infers it from the current `itldev/<name>` Git branch and updates only the copied branch infobase. Open detailed workflow references only if the helper fails or the user asks for explanation.
