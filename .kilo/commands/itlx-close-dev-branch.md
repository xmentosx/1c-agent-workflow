---
description: Fast close the current 1C development branch and export final CF/CFE result
agent: code
---

Run the helper directly from the current project directory:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action close-dev-branch
```

Do not ask for a development branch name. The helper infers it from the current `itldev/<name>` Git branch, refreshes from master, loads changed files, exports final CF/CFE result, marks the branch closed, and switches back to master.

If the helper fails, report the concise error and log path first. Open detailed workflow references only when the user asks for explanation or recovery guidance.
