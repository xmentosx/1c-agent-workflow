---
description: Verify the current ITL branch through partial base update and Vanessa tests
agent: code
---

Run the helper directly from the current project directory:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action verify-dev-branch
```

Do not call `/deploy-and-test`; the helper updates the branch base partially and then runs Vanessa Automation tests. If Vanessa fails, report the log/report paths and let the agent attempt fixes according to the project rules.
