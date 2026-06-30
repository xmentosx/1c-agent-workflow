---
description: Fast export CF from the current 1C development branch
agent: code
---

Run the helper directly from the current project directory:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action export-dev-branch-cf
```

Do not ask for a development branch name. The helper infers it from the current `itldev/<name>` Git branch, loads changed files if needed, and exports CF without closing the branch.

If the helper fails, report the concise error and log path first. Open detailed workflow references only when the user asks for explanation or recovery guidance.
