---
description: Compatibility alias for checking the current ITL branch
agent: code
---

`/itl-verify` is kept for compatibility. For new instructions, prefer `/itl-check`.

Run the helper directly from the current project directory:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action verify-dev-branch
```

Do not call `/deploy-and-test`; the helper updates the branch base partially and then runs Vanessa Automation tests through packet `StartFeaturePlayer` in `TESTMANAGER -> TESTCLIENT` mode with a branch-local test port. It also checks the current branch file infobase event log against the branch baseline and fails on fresh non-baseline `Error` records. Other branch Vanessa processes are diagnostic warnings by default, not a reason to wait. If Vanessa fails, report the JUnit/status/log/event-log paths and process diagnostics, then let the agent attempt fixes according to the project rules.
