---
name: 1c-workflow
description: Initialize and operate ITL 1C configuration/extension projects with Git, source infobases, branch infobase copies, ROCTUP/Vanessa MCP, web publication, Vanessa Automation, CF/CFE export, and refresh. Use for init, checks, MCP setup/status, branch lifecycle, verification, export, switching, or ITL command help.
---

# 1C Workflow

Detailed ITL workflow router. In installed projects, prefer `.agents/skills/1c-workflow-fast/SKILL.md` or Kilo `/itl-*`; open details only after helper failure/request.

## Routing

Use `scripts/agent-1c.ps1` when PowerShell is available; it owns Git, 1C, worktrees, infobases, web publication, Vanessa, manifests, and state.

Open `references/workflow.md` first for the lifecycle panel and topic index. Then open only the matching topic file:

- `references/init-setup.md`: init, checks, web publication/Vanessa setup, `update-workflow`, `update-ai-rules`.
- `references/mcp.md`: ROCTUP data MCP, vibecoding1c MCP, branch Vanessa MCP, External MCP, legacy Data MCP.
- `references/branch-lifecycle.md`: branches, worktrees, extension helpers, context activation, refresh, list/switch, advanced close.
- `references/verification-result.md`: `/itl-check`, Vanessa Automation, event-log baseline, result export, `verificationPolicy`.
- `references/dev-branch-development.md`: work inside an existing `itldev/*` branch.
- `references/advanced-actions.md`: diagnostics and full helper action catalog.

Root `DEVELOPER-GUIDE.ru.md` and `DEV-BRANCH-DEVELOPMENT.ru.md` are human-facing; read only on request/explanation.

Intent mapping:

- Help/menu: show helper `help` or the panel in `references/workflow.md`.
- Init/bootstrap: fresh target uses root `install-agent-1c-workflow.ps1`; installed project uses the monitored init wizard.
- Checks/web publication: `check-tools`, `list-platforms`, `detect-web-publication`, `configure-web-publication`, `publish-dev-branch`, `install-vanessa-automation`.
- ROCTUP branch data MCP: `install-roctup-mcp`, `update-roctup-mcp`, `start-roctup-mcp`, `stop-roctup-mcp`, `roctup-mcp-status`.
- vibecoding1c MCP: `vibecoding1c-mcp-setup`, select, refresh-registry, update, status, start/stop/key/model/client-config helper actions.
- Workflow/rule refresh: `update-workflow`, `update-ai-rules`.
- New work: `new-dev-branch`, `new-extension-dev-branch`.
- Branch lifecycle: `status`, `check-dev-branch`, `update-dev-branch-base`, `verify-dev-branch`, `refresh-dev-branch`, `export-dev-branch-result`.
- Advanced/recovery: `close-dev-branch`, extension helpers, switch/list actions, ROCTUP/Vanessa MCP actions.

If intent is unclear, show the lifecycle panel and wait.

## Safety Guardrails

Fresh target projects must start with the package bootstrap:

```powershell
powershell -ExecutionPolicy Bypass -File <source>\install-agent-1c-workflow.ps1 -ProjectRoot <project>
```

Bootstrap copies managed workflow files, then starts the monitored launcher. Do not expand normal bootstrap into manual copy steps.

Installed projects must start with the foreground monitored launcher:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\run-agent-1c-window.ps1 -- -Action init-project -InitMode wizard
```

Do not call `agent-1c.ps1 -Action init-project -InitMode wizard` directly by default. Do not run a separate `Test-Path` preflight, background PowerShell, or `timeout: 0`; raw probes may emit CLIXML. When terminal input is unavailable, do not collect the questionnaire in chat and do not continue the lifecycle manually. The launcher validates the helper path, owns status, defaults to `MaxWaitSeconds 3600`, and needs a positive long timeout. Use `-KeepWindowOnFailure` only for explicit debugging.

Long lifecycle runs need `timeout_ms >= 1800000`; monitored init needs an outer timeout above 3600s. Do not use `120000 ms`; they may run 1C Designer/Enterprise (`/LoadConfigFromFiles ... /UpdateDBCfg`). `status`/`help` do not need it.

With default `DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP=manual-confirm`, create branches through `scripts/run-agent-1c-window.ps1` so confirmation is visible. Direct helper calls are only explicit automation with `DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP=skip`.

Ask setup questions only when the helper cannot collect them. Store secrets only in `.dev.env` or environment variables. Keep ITL overlay rules in `USER-RULES.md`; do not append to upstream-managed `AGENTS.md` when it already points there.

Use sibling Git worktrees for new development branches and leave the main folder on `master`. Load changes only into the copied branch infobase, never the source infobase. Stop on unexpected dirty Git state before worktree creation, legacy switching, copying bases, dumping config files, or running 1C Designer.

Use `/itl-check` or `check-dev-branch` for the final executable gate. It runs Vanessa through `TESTMANAGER -> TESTCLIENT`, reads JUnit, and checks the event-log baseline. Do not replace final verification with MCP, headless EPF, or `/deploy-and-test`. `/itl-result` obeys `verificationPolicy`.

ROCTUP MCP is the preferred branch-local data channel in `itldev/*` and does not require web publication. vibecoding1c MCP is helper-managed; Vanessa MCP is separate branch tooling; External MCP is unmanaged. Do not paste keys into chat or tracked files.

Do not search or read ignored runtime folders such as `.agent-1c/runs/`, `.agent-1c/mcp/`, `.agent-1c/infobases/`, `build/test-results/`, or `logs/` unless diagnosing a specific helper run or artifact.

When launching native Windows executables such as `1cv8.exe` through `Start-Process`, pass `-ArgumentList` as one joined and correctly quoted native command-line string, never as a PowerShell array.
