# 1C Agent Workflow Reference Index

Lifecycle routing index. Open a topic only when helper output, failure, or the request needs it.

## User-Facing Menu

When the user asks for help or the requested action is unclear, show the helper lifecycle panel. Its shape is:

```text
master:
  /itl
  /itl-status
  /itl-new-config-branch <name>
  /itl-new-extension-branch <name>
  /itl-update-workflow
  /itl-switch-client <client>
  /itl-litemode <mode>

itldev/*:
  /itl
  /itl-status
  /itl-vanessa-author
  /itl-check
  /itl-verify-fix
  /itl-refresh
  /itl-result
  /itl-litemode <mode>
```

Render ITL commands only for the one active client. Kilo, Claude, Cursor, and OpenCode use their native project command paths; Codex uses project-local skills and natural requests. `master` and `itldev/*` get matching surfaces. Synchronization removes only generated `itl*.md`, preserves user files, and verifies filenames. Follow the adapter reload instruction. `/itl` returns helper `-Action help` stdout verbatim: state, recommendation, lifecycle, visible commands, and grouped helper actions. Do not summarize, merge OpenSpec into visible commands, omit `Lifecycle:`/`Additional helper actions:`, or add a "no lifecycle actions executed" note. Recommend `/itl-vanessa-author` when changed features lack a fresh authoring pass; otherwise use `/itl-check` for checkable changes or stale/failed/unknown verification. `/itl-verify-fix` is manual recovery, never the default.

For Codex, prefer `$1c-workflow-fast` for routine installed-project actions. Use this detailed skill only for initialization, recovery, unusual topology, or explanation.

## Topic References

- `init-setup.md`: state files, `.agent-1c/project.json`, `.dev.env`, required init questions, monitored wizard, tool checks, web publication/Vanessa setup, `update-workflow`, and `update-ai-rules`.
- `mcp.md`: ROCTUP branch data MCP, vibecoding1c MCP selection/setup/status/update, branch-local Vanessa UI MCP, External MCP preservation, and legacy branch Data MCP publication fallback.
- `branch-lifecycle.md`: Git/worktree rules, new configuration or extension branches, extension bootstrap/dump, branch context activation, base update, refresh, list, switch, and advanced close.
- `verification-result.md`: `/itl-check`, `verify-dev-branch`, Vanessa Automation `TESTMANAGER -> TESTCLIENT`, `VANESSA_TEST_FOREIGN_WAIT_MODE=warn`, event-log baselines, `/itl-result`, result manifests, and `verificationPolicy`.
- `dev-branch-development.md`: develop inside an existing `itldev/*` worktree using quick-fix or OpenSpec.
- `advanced-actions.md`: helper catalog and diagnostics-only actions.

Open only the matching topic file. Do not load the whole reference set for normal lifecycle execution.

## Hot Path

Use `scripts/agent-1c.ps1` when PowerShell is available; it owns Git, 1C, worktrees, infobases, web publication, Vanessa, manifests, and state.

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action <action>
```

Long lifecycle actions may run 1C Designer/Enterprise. Use `timeout_ms >= 1800000`; for monitored init, set the outer timeout above 3600 seconds. `status` and `help` can stay short.

Fresh target bootstrap:

```powershell
powershell -ExecutionPolicy Bypass -File <source>\install-agent-1c-workflow.ps1 -ProjectRoot <project>
```

Copies managed files, then starts the monitored foreground launcher; do not expand into manual copy steps.

Installed project launcher:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\run-agent-1c-window.ps1 -- -Action init-project -InitMode wizard
```

Do not call the wizard helper directly, run `Test-Path` preflight, use background PowerShell, or set `timeout: 0`; probes may emit CLIXML. If terminal input is unavailable, do not collect the questionnaire in chat. Launcher owns `.agent-1c/runs/<run>/status.json`, `-MaxWaitSeconds 3600`, positive long timeout, and debug-only `-KeepWindowOnFailure`. Use `timeout_ms >= 3900000`; after interruption repeat the same command. It rejects live duplicates; do not continue the lifecycle manually or edit Git/status during orphan resume.

## Always-On Safety Notes

- Keep secrets in `.dev.env` or environment variables. Write `.dev.env`, `.agent-1c/*.json`, and branch state as UTF-8.
- Keep ITL overlay rules in `USER-RULES.md`; do not append detailed workflow notes to upstream-managed `AGENTS.md` when it already points to `USER-RULES.md`.
- Use sibling Git worktrees for new development branches by default and leave the main folder on `master`.
- Load branch changes only into the copied development branch infobase, never directly into the source infobase.
- Use `/itl-check` or `check-dev-branch` for executable verification. Effective ITL modes decide which components run; a skipped component produces partial evidence, never a fresh pass. `/deploy-and-test` is a bridge to the same helper.
- Read `references/vanessa-tests.md` and `vanessa-authoring.md` only before creating or editing Vanessa feature files.
- For native Windows executables such as `1cv8.exe`, pass `Start-Process -ArgumentList` as one joined and correctly quoted command-line string, never as a PowerShell array.
- Do not search or load ignored runtime folders such as `.agent-1c/runs/`, `.agent-1c/mcp/`, `.agent-1c/infobases/`, `build/test-results/`, or `logs/` unless diagnosing a specific helper run or artifact.

## Failure Rules

Stop immediately when required parameters are missing, Git state is unexpectedly dirty, branch targets already exist, the source infobase cannot be opened, repository credentials are missing for required storage sync, 1C Designer returns non-zero, CF/CFE export fails, or `verificationPolicy=block` forbids an unverified result.

For recovery, open only the relevant topic reference above.
