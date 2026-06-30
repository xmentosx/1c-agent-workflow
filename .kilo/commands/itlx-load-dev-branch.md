---
description: Fast load changed 1C config files into the current development branch infobase
agent: code
---

Run the helper directly from the current project directory:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action load-dev-branch
```

Do not ask for a development branch name. The helper infers it from the current `itldev/<name>` Git branch and loads only changed files.

If the helper fails, report the concise error and log path first. Open detailed workflow references only when the user asks for explanation or recovery guidance.
