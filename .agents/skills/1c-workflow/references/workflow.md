# 1C Agent Workflow Reference Index

Lightweight lifecycle routing index. Open topic references only when helper output, failure, or user request needs those details.

## User-Facing Menu

When the user asks for help or the requested action is unclear, show the helper lifecycle panel. Its shape is:

```text
master:
  /itl
  /itl-status
  /itl-new-config-branch <name>
  /itl-new-extension-branch <name>
  /itl-update-workflow

itldev/*:
  /itl
  /itl-status
  /itl-check
  /itl-refresh
  /itl-result
```

For Kilo Code, `.kilo/commands/itl*.md` is generated local state. The `master` worktree gets only the master command surface; each `itldev/*` worktree gets only the development command surface. Workflow package updates are visible in `master` as `/itl-update-workflow`. The `/itl` wrapper must return helper `-Action help` stdout verbatim and preserve process order: current folder/branch state, recommended next step, lifecycle path, visible slash commands, then additional helper actions grouped by capability. It must not summarize the panel, merge OpenSpec into visible slash commands, omit `Lifecycle:` or `Additional helper actions:`, or add a "no lifecycle actions executed" note. In a fresh clean `itldev/*` branch with missing verification, recommend choosing a development mode (`quick-fix`, `/opsx-explore`, or `/opsx-propose`), not `/itl-check`. Recommend `/itl-check` only when there are checkable configuration/extension/Vanessa feature changes or stale/failed/unknown verification. Rare actions such as MCP setup, extension setup/dump, marking a branch closed, and rule updates are available through natural-language requests or direct helper actions, but are not generated as visible slash commands.

For Codex, prefer `$1c-workflow-fast` for routine installed-project actions. Use this detailed skill only for initialization, recovery, unusual topology, or explanation.

## Topic References

- `init-setup.md`: state files, `.agent-1c/project.json`, `.dev.env`, required init questions, monitored wizard, tool checks, web publication/Vanessa setup, `update-workflow`, and `update-ai-rules`.
- `mcp.md`: ROCTUP branch data MCP, vibecoding1c MCP selection/setup/status/update, branch-local Vanessa MCP, External MCP preservation, and legacy branch Data MCP publication fallback.
- `branch-lifecycle.md`: Git/worktree rules, new configuration or extension branches, extension bootstrap/dump, branch context activation, base update, refresh, list, switch, and advanced close.
- `verification-result.md`: `/itl-check`, `verify-dev-branch`, Vanessa Automation `TESTMANAGER -> TESTCLIENT`, `VANESSA_TEST_FOREIGN_WAIT_MODE=warn`, event-log baselines, `/itl-result`, result manifests, and `verificationPolicy`.
- `dev-branch-development.md`: how to develop inside an existing `itldev/*` worktree using quick-fix or OpenSpec.
- `advanced-actions.md`: full helper action catalog and diagnostics-only actions.

Open only the matching topic file. Do not load the whole reference set for normal lifecycle execution.

## Hot Path

Use `scripts/agent-1c.ps1` whenever PowerShell is available; it owns Git, 1C, worktrees, infobases, web publication state, Vanessa, manifests, and state.

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action <action>
```

Long lifecycle actions may run 1C Designer/Enterprise. Use `timeout_ms >= 1800000`; `status` and `help` can stay short.

Fresh target bootstrap:

```powershell
powershell -ExecutionPolicy Bypass -File <source>\install-agent-1c-workflow.ps1 -ProjectRoot <project>
```

Copies managed files, then starts the monitored foreground launcher; do not expand into manual copy steps.

Installed project launcher:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\run-agent-1c-window.ps1 -- -Action init-project -InitMode wizard
```

Do not call `agent-1c.ps1 -Action init-project -InitMode wizard` directly by default, run `Test-Path` preflight, use background PowerShell, or set `timeout: 0`; raw probes may emit CLIXML. Do not collect the questionnaire in chat when terminal input is unavailable and do not continue the lifecycle manually. The launcher owns `.agent-1c/runs/<run>/status.json`, needs a positive long timeout, and supports `-KeepWindowOnFailure` only for manual debugging.

## Always-On Safety Notes

- Keep secrets in `.dev.env` or environment variables. Write `.dev.env`, `.agent-1c/*.json`, and branch state as UTF-8.
- Keep ITL overlay rules in `USER-RULES.md`; do not append detailed workflow notes to upstream-managed `AGENTS.md` when it already points to `USER-RULES.md`.
- Use sibling Git worktrees for new development branches by default and leave the main folder on `master`.
- Load branch changes only into the copied development branch infobase, never directly into the source infobase.
- Use `/itl-check` or `check-dev-branch` for the normal executable gate. Do not replace the final gate with MCP, a headless EPF, or `/deploy-and-test`.
- Read `VANESSA-TESTS-GUIDE.md` only before creating or editing Vanessa Automation feature files.
- For native Windows executables such as `1cv8.exe`, pass `Start-Process -ArgumentList` as one joined and correctly quoted command-line string, never as a PowerShell array.
- Do not search or load ignored runtime folders such as `.agent-1c/runs/`, `.agent-1c/mcp/`, `.agent-1c/infobases/`, `build/test-results/`, `logs/`, `tmp/`, or `temp/` unless diagnosing a specific helper run or artifact.

## Failure Rules

Stop immediately when required parameters are missing, Git state is unexpectedly dirty, branch targets already exist, the source infobase cannot be opened, repository credentials are missing for required storage sync, 1C Designer returns non-zero, CF/CFE export fails, or `verificationPolicy=block` forbids an unverified result.

For detailed recovery, open only the relevant topic reference above.
