---
description: Fast list active 1C development branches
agent: code
---

Run the helper directly from the current project directory:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action list-dev-branches
```

Do not load the full workflow skill first. Report active branches, the current Git branch, and the current development branch marker from the helper output.

If the helper fails, report the concise error and log path first. Open detailed workflow references only when the user asks for explanation or recovery guidance.
