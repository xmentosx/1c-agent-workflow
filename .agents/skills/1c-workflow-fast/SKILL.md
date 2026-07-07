---
name: 1c-workflow-fast
description: Run routine 1C Agent Workflow lifecycle commands through the PowerShell helper with minimal context loading. Use for status, vibecoding1c MCP setup/status, configuration or extension development branch creation from master, branch verification, refresh, and CF/CFE result export when the project is already installed.
---

# 1C Workflow Fast

## Purpose

Use this skill for routine lifecycle commands when the project already contains the standard `1c-workflow` files. The fast path keeps agent work small: map the user request to one helper action, run the helper, and report the result.

Do not open the full workflow references before normal lifecycle execution. Open detailed references only when the helper fails, reports missing setup values, or the user asks for an explanation.

## Intent Map

- show ITL status: `status`
- setup or inspect vibecoding1c MCP servers: `vibecoding1c-mcp-setup` by default, `vibecoding1c-mcp-status` for status-only, `vibecoding1c-mcp-select` to choose remote/local or configId, `vibecoding1c-mcp-refresh-registry` to update remote endpoint discovery
- update the installed ITL workflow package from `master`: `update-workflow`
- create new configuration development branch worktree from `master`: `new-dev-branch`
- create new extension development branch worktree from `master`: `new-extension-dev-branch`
- check current branch after changes through update plus Vanessa tests: `check-dev-branch`
- update current development branch infobase from branch files without tests, when explicitly requested: `update-dev-branch-base`
- verify current branch through update plus Vanessa tests, when compatibility wording is used: `verify-dev-branch`
- refresh current development branch from master/source: `refresh-dev-branch`
- export CF or CFE result from current development branch: `export-dev-branch-result`
- advanced only, when explicitly requested: mark current development branch closed and hide it from active lists with `close-dev-branch`
- show/open worktree paths: `status` first; use direct switch helper actions only for legacy recovery.

## Command Template

Run commands from the project root:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action <action>
```

For actions that require a branch name:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action new-dev-branch -DevBranchName "<dev-branch-name>"
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action new-extension-dev-branch -DevBranchName "<dev-branch-name>"
```

New branch commands must run from `master` and create a sibling Git worktree by default. Report the printed worktree path and tell the developer to open a separate Codex/Kilo/IDE window there. Use `-UseCurrentWorktree` only when the developer explicitly asks for the legacy single-folder checkout mode.

For `check-dev-branch`, `update-dev-branch-base`, `verify-dev-branch`, `refresh-dev-branch`, `export-dev-branch-result`, and explicit advanced `close-dev-branch`, do not ask for a branch name. The helper infers it from the current `itldev/<name>` Git branch.

For the normal post-change check, do not call `/deploy-and-test` and do not run `update-dev-branch-base` first. Run `check-dev-branch` (`/itl-check` in a dev worktree); it updates the branch base partially and then runs Vanessa Automation through packet `StartFeaturePlayer` in `TESTMANAGER -> TESTCLIENT` mode with a branch-local test port. `verify-dev-branch` remains a compatibility alias for the same helper cycle. The helper also checks the local branch infobase event log against the branch baseline created during branch initialization; fresh non-baseline `Error` records fail verification. MCP is not the final verification runner. Foreign branch 1C test processes are warnings by default, not a reason to wait, unless there is a real port/infobase conflict or `VANESSA_TEST_FOREIGN_WAIT_MODE=wait` is set.

For result export and explicit advanced close, let the helper enforce `verificationPolicy`: default `warn` allows only explicit unverified override; `block` stops until `check-dev-branch` or `verify-dev-branch` is fresh passed.

## Failure Handling

If the helper exits with an error:

1. Report the action that failed.
2. Report the concise error text.
3. Report the latest log path when the helper prints one.
4. Ask for only the missing value when the helper clearly identifies one.
5. Use the full `1c-workflow` skill only for detailed recovery, unusual topology, or init questionnaire work.

For first-time project bootstrap, follow `AGENT-INSTALL.md`. This fast skill is optimized for regular branch operations after installation.
