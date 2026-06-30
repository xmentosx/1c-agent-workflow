---
description: Fast refresh the current 1C development branch via master
agent: code
---

Run the helper directly from the current project directory:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action refresh-dev-branch
```

Do not ask for a development branch name. The helper infers it from the current `itldev/<name>` Git branch, syncs master from the source infobase, merges master, and loads changed files into the branch infobase.

If the helper fails, report the concise error and log path first. Open detailed workflow references only when the user asks for explanation or recovery guidance.
