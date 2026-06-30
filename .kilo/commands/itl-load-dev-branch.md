---
description: Load changed 1C config files into the development branch infobase
agent: code
---

Use the `1c-workflow` skill and execute `LOAD_DEV_BRANCH`.

Infer the development branch from the current `itldev/<name>` Git branch. If the current branch is not a development branch and no state can be inferred, ask for a development branch name.

Prefer the PowerShell helper:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action load-dev-branch
```
