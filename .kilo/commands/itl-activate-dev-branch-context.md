---
description: Activate the current ITL development branch infobase context for ai_rules_1c commands
agent: code
---

Use the `1c-workflow` skill and execute `ACTIVATE_DEV_BRANCH_CONTEXT`.

Infer the development branch from the current `itldev/<name>` Git branch. If the current branch is not a development branch and no state can be inferred, ask for a development branch name.

This writes `.dev.env` values used by ai_rules_1c commands such as `/update1cbase`, `/deploy-and-test`, `/loadfrom1cbase`, and `/getconfigfiles`.

Prefer the PowerShell helper:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action activate-dev-branch-context
```
