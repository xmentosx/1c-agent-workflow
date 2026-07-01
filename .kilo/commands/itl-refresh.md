---
description: Refresh the current ITL branch from master/source
agent: code
---

Run the helper directly from the current project directory:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action refresh-dev-branch
```

Do not ask for a development branch name. The helper infers it from the current `itldev/<name>` Git branch. In manual source mode, remind the developer that the source infobase must be updated manually before refresh when fresh external changes are needed.
