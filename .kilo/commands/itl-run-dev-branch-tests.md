---
description: Run Vanessa Automation tests for the current ITL 1C development branch
agent: code
---

Use the `1c-workflow` skill and execute `RUN_DEV_BRANCH_TESTS`.

Do not call `/deploy-and-test` for the normal ITL branch verification flow. If files changed, the branch base must be updated first through `/itl-update-dev-branch-base`; this command only runs Vanessa Automation tests against the already updated branch infobase.

Prefer the PowerShell helper:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action run-dev-branch-tests
```
