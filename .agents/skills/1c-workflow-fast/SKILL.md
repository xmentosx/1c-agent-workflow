---
name: 1c-workflow-fast
description: Run routine 1C Agent Workflow commands through the PowerShell helper with minimal context loading. Use for status, ROCTUP/Vanessa UI MCP status/start/stop, vibecoding1c MCP setup/status, config or extension branch creation from master, Vanessa Automation verification, refresh, and CF/CFE export in installed projects.
---

# 1C Workflow Fast

## Purpose

Use this skill for routine lifecycle commands when the project already has standard `1c-workflow` files. Map the request to one helper action, run it, and report the result.

Do not open full workflow references before normal lifecycle execution. Open details only when the helper fails, reports missing setup values, or the user asks for explanation.

## Intent Map

- show ITL status: `status`
- inspect/control ROCTUP branch data MCP: `roctup-mcp-status`, `start-roctup-mcp`, `stop-roctup-mcp`, `install-roctup-mcp`, or `update-roctup-mcp`
- inspect/control Vanessa UI branch MCP: `vanessa-mcp-status`, `start-vanessa-mcp`, `stop-vanessa-mcp`, or `install-vanessa-mcp`
- setup/inspect vibecoding1c MCP: `vibecoding1c-mcp-setup` by default, `vibecoding1c-mcp-status`, `vibecoding1c-mcp-select`, `vibecoding1c-mcp-refresh-registry`
- update the installed ITL workflow package from `master`: `update-workflow`
- create new configuration development branch worktree from `master`: `new-dev-branch`
- create new extension development branch worktree from `master`: `new-extension-dev-branch`
- initialize the extension after branch creation: `init-dev-branch-extension` with `-ExtensionInitMode Empty|Cfe`, `-ExtensionName`, and optional `-ExtensionSourcePath`
- check current branch after changes: `check-dev-branch`
- update current development branch infobase from branch files without tests, when explicitly requested: `update-dev-branch-base`
- verify current branch when compatibility wording is used: `verify-dev-branch`
- refresh current development branch from master/source: `refresh-dev-branch`
- export CF or CFE result from current development branch: `export-dev-branch-result`
- advanced only, when explicit: mark current development branch closed and hide it with `close-dev-branch`
- show/open worktree paths: `status` first; use direct switch helper actions only for legacy recovery.

## Command Template

Run commands from the project root:

Long actions (`new-dev-branch`, `new-extension-dev-branch`, `init-dev-branch-extension`, `update-workflow`, `check-dev-branch`, `update-dev-branch-base`, `verify-dev-branch`, `refresh-dev-branch`, `export-dev-branch-result`) need `timeout_ms >= 1800000` when supported. Do not use `120000 ms`; they may launch 1C Designer/Enterprise (`/LoadConfigFromFiles ... /UpdateDBCfg`). `status`/`help` do not need the long timeout.

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action <action>
```

For actions that require a branch name and create a new branch, use the monitored launcher so the manual unsafe-action protection confirmation is visible:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\run-agent-1c-window.ps1 -- -Action new-dev-branch -DevBranchName "<dev-branch-name>"
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\run-agent-1c-window.ps1 -- -Action new-extension-dev-branch -DevBranchName "<dev-branch-name>"
```

Use direct `agent-1c.ps1` for branch creation only in non-interactive automation with `DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP=skip`.

New branch commands run from `master` and create a sibling Git worktree by default. Report the printed worktree path and tell the developer to open a separate Codex/Kilo/IDE window there. Use `-UseCurrentWorktree` only when explicitly requested.

New branch commands prepare branch-local ROCTUP and Vanessa UI MCP as stopped/ready; they do not start MCP or open the branch infobase. For data exploration, run `start-roctup-mcp`, use the MCP, then run `stop-roctup-mcp`. For runtime UI research, recording, or debugging only, follow `.agents/skills/itl-vanessa-ui-mcp/SKILL.md`, then use `start-vanessa-mcp` and `stop-vanessa-mcp`. Static form/source questions do not start Vanessa UI MCP. `/itl-check` is separate Vanessa Automation verification, not MCP.

For `check-dev-branch`, `update-dev-branch-base`, `verify-dev-branch`, `refresh-dev-branch`, `export-dev-branch-result`, and explicit `close-dev-branch`, do not ask for a branch name; the helper infers current `itldev/<name>`.

Normal post-change check: do not call `/deploy-and-test` or run `update-dev-branch-base` first. Run `check-dev-branch` (`/itl-check`); it updates the branch base, runs Vanessa `StartFeaturePlayer` in `TESTMANAGER -> TESTCLIENT` mode, and checks the branch event-log baseline. Fresh non-baseline `Error` records fail. MCP is not final verification. Foreign branch 1C test processes are warnings unless there is a real conflict or `VANESSA_TEST_FOREIGN_WAIT_MODE=wait`.

For result export and explicit advanced close, let the helper enforce `verificationPolicy`: `warn` needs explicit unverified override; `block` waits for fresh passed check/verify.

## Failure Handling

If the helper exits with an error:

1. Report the action that failed.
2. Report the concise error text.
3. Report the latest log path when the helper prints one.
4. Ask for only the missing value when the helper clearly identifies one.
5. Use full `1c-workflow` only for detailed recovery, unusual topology, or init questionnaire work.

For first-time project bootstrap, follow `AGENT-INSTALL.md`. This fast skill is optimized for regular branch operations after installation.
