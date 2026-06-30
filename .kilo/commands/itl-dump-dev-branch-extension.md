---
description: Dump the current 1C development branch extension to src/cfe
agent: code
---

Use the `1c-workflow` skill and execute `DUMP_DEV_BRANCH_EXTENSION`.

Do not ask for the extension name. The helper reads it from the current extension development branch state. If it is missing, ask the developer to run `/itl-set-dev-branch-extension <extension name>` first.

Prefer the PowerShell helper:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action dump-dev-branch-extension
```
