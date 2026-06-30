---
description: Fast sync the 1C project master branch from the source infobase
agent: code
---

Run the helper directly from the current project directory:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action sync-master
```

Do not load the full workflow skill first. The helper owns Git checks, source repository update when enabled, incremental dump, and source dump commit.

If the helper fails, report the concise error and log path first. Open detailed workflow references only when the user asks for explanation or recovery guidance.
