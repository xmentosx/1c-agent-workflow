---
description: Refresh the current ITL branch from master/source
agent: code
---

Use this command only from an active `itldev/*` development branch worktree.

Run the helper directly from the current project directory:

If the agent shell tool supports `timeout_ms`, run this lifecycle command with `timeout_ms >= 1800000`; do not use `120000 ms` or other short defaults because the helper may launch 1C Designer/Enterprise operations.

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action refresh-dev-branch
```

The helper refreshes `master` from storage or the current source infobase state, merges fresh `master` into the current branch, regenerates the context-specific Kilo command surface if workflow files changed, and updates the branch infobase from configuration files.
