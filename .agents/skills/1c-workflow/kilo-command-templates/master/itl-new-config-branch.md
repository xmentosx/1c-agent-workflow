---
description: Create an ITL configuration development branch
agent: code
---

Use this command only from the `master` worktree. Treat any text after `/itl-new-config-branch` as the development branch name. If it is missing, ask for one short value.

Run the monitored helper launcher from the current project directory so the manual unsafe-action protection confirmation is visible:

If the agent shell tool supports `timeout_ms`, run this lifecycle command with `timeout_ms >= 1800000`; do not use `120000 ms` or other short defaults because the helper may launch 1C Designer/Enterprise operations.

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\run-agent-1c-window.ps1 -- -Action new-dev-branch -DevBranchName "<dev-branch-name>"
```

Use direct `agent-1c.ps1` only for non-interactive automation that explicitly sets `DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP=skip` after the unsafe-action protection is configured separately.

The helper creates a sibling Git worktree by default and leaves the current project folder on `master`. Report the branch name, copied infobase path, worktree path, 1C launcher entry, and publication URL when printed. Tell the developer to open a separate Codex/Kilo/IDE window in the printed worktree folder. Use `-UseCurrentWorktree` only if the developer explicitly asks for the legacy single-folder checkout mode. Open detailed workflow references only if the helper fails or the user asks for explanation.
