---
name: 1c-workflow-fast
description: Run routine helper commands in installed ITL 1C projects for status, branch creation, Vanessa verification, refresh, and CF/CFE export. Never use for development, review, tests, or docs of the 1c-agent-workflow source repository.
---

# 1C Workflow Fast

## Purpose

Use this skill for routine lifecycle commands when the project already has standard `1c-workflow` files. Map the request to one helper action, run it, and report the result.

Do not open full workflow references before normal lifecycle execution. Open details only when the helper fails, reports missing setup values, or the user asks for explanation.

## Intent Map

- show ITL status: `status`
- inspect on-demand facade/backend state: `status`; actual data/UI operations use `itl-roctup-data` or `itl-vanessa-ui`, not helper actions
- setup/inspect vibecoding1c MCP: `vibecoding1c-mcp-setup` by default, `vibecoding1c-mcp-status`, `vibecoding1c-mcp-select`, `vibecoding1c-mcp-refresh-registry`
- update the installed ITL workflow package from `master`: `update-workflow`
- create new configuration development branch worktree from `master`: `new-dev-branch`
- create/provision an extension branch: collect `Empty|Cfe`, name, and optional CFE path for `new-extension-dev-branch`; unknown values persist pending for first-entry agent setup
- resume pending/failed setup internally with `init-dev-branch-extension`; never expose its PowerShell
- check current branch after changes: `check-dev-branch`
- update current development branch infobase from branch files without tests, when explicitly requested: `update-dev-branch-base`
- verify current branch when compatibility wording is used: `verify-dev-branch`
- refresh current development branch from master/source: `refresh-dev-branch`
- export CF or CFE result from current development branch: `export-dev-branch-result`
- advanced only, when explicit: mark current development branch closed and hide it with `close-dev-branch`
- show/open worktree paths: `status` first; use direct switch helper actions only for legacy recovery.

## Command Template

Run commands from the project root:

Long actions (`new-*`, `init-*`, `update-*`, `check-*`, `verify-*`, `refresh-*`, `export-*`) default to `timeout_ms >= 3900000`, above Designer's 3600-second limit; raise it with a higher configured limit. Do not use `120000 ms`; `status`/`help` do not need it. 1C Designer/Enterprise may run `/LoadConfigFromFiles ... /UpdateDBCfg`.

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action <action>
```

For actions that require a branch name and create a new branch, use the monitored launcher so fallback unsafe-action protection confirmation is visible when master has no matching source confirmation:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\run-agent-1c-window.ps1 -- -Action new-dev-branch -DevBranchName "<dev-branch-name>"
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\run-agent-1c-window.ps1 -- -Action new-extension-dev-branch -DevBranchName "<dev-branch-name>" -ExtensionInitMode Empty -ExtensionName "<extension-name>" -OfferOpenAgent
```

For CFE, replace `Empty` with `Cfe` and append `-ExtensionSourcePath "<absolute-file.cfe>"`. If unknown, omit extension parameters; pending state routes first-entry setup.

Use direct `agent-1c.ps1` for branch creation only when the master source confirmation matches the current base/user or non-interactive automation explicitly sets `DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP=skip`.

On success, the final response must be exactly the non-empty `userReport` Markdown, including for `refresh-dev-branch`. It states success and includes load, Enterprise, MCP/Browser, reload, verification, and advice. Do not translate it, use a code fence, convert it to a table, rename or merge fields, reorder or omit lines, summarize, use `requiredAction`, or read `console.log`. `-UseCurrentWorktree` explicit-only.

New branch commands register stable `itl-roctup-data` and `itl-vanessa-ui` stdio facades with compact `resolve_tool`/`call_tool` surfaces without opening the branch infobase. Resolution is local; their first inner call starts a client-owned backend automatically. For runtime UI research, recording, or debugging follow `.agents/skills/itl-vanessa-ui-mcp/SKILL.md`. Static form/source questions do not call Vanessa UI MCP. `/itl-check` is separate Vanessa Automation verification, not MCP.

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
