# 1C Agent Workflow Reference Index

Lifecycle index. Open as needed.

## User-Facing Menu

When help is requested or the action is unclear, show this helper lifecycle panel:

```text
master:
  /itl
  /itl-status
  /itl-new-config-branch <name>
  /itl-new-extension-branch <name>
  /itl-sync-master
  /itl-refresh-all
  /itl-update-workflow
  /itl-switch-client <client>
  /itl-litemode <mode>

itldev/*:
  /itl
  /itl-status
  /itl-check
  /itl-verify-fix
  /itl-refresh
  /itl-refresh-lite
  /itl-reset-branch
  /itl-lock-objects
  /itl-result
  /itl-litemode <mode>
```

Render one active client: Codex, Kilo Code, Claude Code, Cursor, OpenCode, Kimi Code, Qwen Code, Command Code, Cline, or Pi. Use the capability registry (commands, skills, prompts); never infer syntax from a client name. `master` and `itldev/*` get matching surfaces. Synchronization removes hash-owned ITL assets and preserves user/config keys. Follow the reload instruction. `/itl` returns the Russian helper `-Action help` stdout verbatim: state, recommendation, lifecycle, native OpenSpec invocation or exact natural requests, then grouped helper actions. Never promise universal `/opsx*`; do not summarize, omit `Жизненный цикл:`/`Дополнительные действия:`, or add a "no lifecycle actions executed" note. Use `/itl-check` for checkable changes or stale/failed/unknown verification. `/itl-verify-fix` is manual recovery, never the default.

For Codex, use the generated `$itl*` skills for routine installed-project actions; `$itl` shows the current context panel. Use this detailed skill only for initialization, recovery, unusual topology, or explanation.

## Topic References

- `init-setup.md`: state files, `.agent-1c/project.json`, `.dev.env`, required init questions, monitored wizard, tool checks, web publication/Vanessa setup, `update-workflow`, and `update-ai-rules`.
- `mcp.md`: ROCTUP branch data MCP, vibecoding1c MCP selection/setup/status/update, branch-local Vanessa UI MCP, External MCP preservation, and legacy branch Data MCP publication fallback.
- `branch-lifecycle.md`: Git/worktree rules, new configuration or extension branches, extension bootstrap/dump, branch context activation, base update, refresh, list, switch, and advanced close.
- `verification-result.md`: `/itl-check`, `verify-dev-branch`, Vanessa Automation `TESTMANAGER -> TESTCLIENT`, `VANESSA_TEST_FOREIGN_WAIT_MODE=warn`, event-log baselines, `/itl-result`, result manifests, and `verificationPolicy`.
- `dev-branch-development.md`: choose a development mode or handle pending extension setup inside an existing `itldev/*` worktree; after classification it routes directly to one quick-fix, direct full-cycle, or OpenSpec reference.
- `advanced-actions.md`: helper catalog and diagnostics-only actions.

Open only the matching topic file. Do not load the whole reference set for normal lifecycle execution.

## Hot Path

Use `scripts/agent-1c.ps1` when PowerShell is available; it owns Git, 1C, worktrees, infobases, web publication, Vanessa, manifests, and state.

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action <action>
```

Long actions default to `timeout_ms >= 3900000`, above Designer's 3600-second limit; raise it with a higher configured limit. `status` and `help` stay short.

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
- Read `references/vanessa-tests.md` and `vanessa-authoring.md` only before creating, editing, or diagnosing Vanessa feature files.
- `ONEC_MAX_CONCURRENT_SESSIONS` limits workflow-owned 1C launches per exact infobase. Default `3`; `0` disables it. Admission counts external processes, serializes count-and-start, and reserves promised TestClient slots.
- `errorCategory=session-capacity` is a scheduling block, not a product/test failure. The helper may once close local sessions whose exact `/F` or `/S` targets the current dev-branch infobase, regardless of launcher, then retry admission once. Source, other-branch, ambiguous, and PID-reused processes remain fail-closed; do not add retries or alter the limit.
- External `Start-Process 1cv8.exe` cannot be intercepted. Project automation must dot-source `agent-1c.ps1 -Action help`, then call `Start-OneCProcessBackground` with the exact base, whole topology, `ExpectedChildRole=test-client` when applicable, purpose, and `-Visible` when needed. Direct 1C launch is forbidden.
- For other native Windows executables, and inside the guarded 1C launcher implementation, pass `Start-Process -ArgumentList` as one joined and correctly quoted command-line string, never as a PowerShell array.
- Do not search or load ignored runtime folders such as `.agent-1c/runs/`, `.agent-1c/mcp/`, `.agent-1c/infobases/`, `build/test-results/`, or `logs/` unless diagnosing a specific helper run or artifact.

## Failure Rules

Stop immediately when required parameters are missing, Git state is unexpectedly dirty, branch targets already exist, the source infobase cannot be opened, repository credentials are missing for required storage sync, 1C Designer returns non-zero, CF/CFE export fails, or `verificationPolicy=block` forbids an unverified result.

On `ITL_INFOBASE_APPLICATION_NOT_READY`, run `update-dev-branch-base`, then retry the original MCP/test action once; never move this mutation into MCP.

For recovery, open only the relevant topic reference above.
