---
description: Update the installed ITL workflow package
agent: code
---

Use this command only from the `master` worktree. It refreshes the installed ITL workflow files, regenerates local Kilo ITL commands, updates AI rules by default, and leaves tracked changes for review.

Run the helper directly from the current project directory:

If the agent shell tool supports `timeout_ms`, run this lifecycle command with `timeout_ms >= 1800000`; do not use `120000 ms` or other short defaults because the helper may launch 1C Designer/Enterprise operations.

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action update-workflow
```

If the helper reports a dirty tracked Git worktree, stop and ask the developer to commit or stash tracked changes before retrying. Do not run this command from an `itldev/*` worktree; update development worktrees later by merging fresh `master` or running `/itl-refresh`.
