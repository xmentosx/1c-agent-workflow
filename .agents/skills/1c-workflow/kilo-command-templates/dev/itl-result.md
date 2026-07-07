---
description: Export CF or CFE result for the current ITL branch
agent: code
---

Use this command only from an active `itldev/*` development branch worktree.

Run the helper directly from the current project directory:

If the agent shell tool supports `timeout_ms`, run this lifecycle command with `timeout_ms >= 1800000`; do not use `120000 ms` or other short defaults because the helper may launch 1C Designer/Enterprise operations.

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action export-dev-branch-result
```

If the helper warns that fresh passed verification is missing, ask the developer for explicit confirmation before continuing. For confirmed unverified export, rerun with `-AllowUnverifiedResult`. If `VERIFICATION_POLICY=block`, do not ask for an override; run `/itl-check` first.
