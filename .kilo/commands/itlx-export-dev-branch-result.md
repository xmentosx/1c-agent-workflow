---
description: Fast export CF or CFE result from the current 1C development branch
agent: code
---

Run the helper directly from the current project directory:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action export-dev-branch-result
```

Do not ask for a development branch name. The helper infers it from the current `itldev/<name>` Git branch, updates the relevant branch base if needed, and exports CF or CFE.

If the helper fails, report the concise error and log path first. Open detailed workflow references only when the user asks for explanation or recovery guidance.
