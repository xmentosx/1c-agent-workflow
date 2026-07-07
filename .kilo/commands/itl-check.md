---
description: Check the current ITL branch through base update and Vanessa tests
agent: code
---

Run the helper directly from the current project directory:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action check-dev-branch
```

This is the normal post-change cycle. Do not run `/itl-update-base` first; the helper updates the branch base and then runs Vanessa Automation through packet `StartFeaturePlayer` in `TESTMANAGER -> TESTCLIENT` mode with a branch-local test port. It also checks the current branch file infobase event log against the branch baseline and fails on fresh non-baseline `Error` records. Other branch Vanessa processes are diagnostic warnings by default, not a reason to wait. If Vanessa fails, report the JUnit/status/log/event-log paths and process diagnostics, then let the agent attempt fixes according to the project rules.
