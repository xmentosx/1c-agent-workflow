---
name: 1c-workflow
description: Initialize and operate ITL 1C configuration or extension projects with Git, source infobases, isolated branch infobase copies, ROCTUP/Vanessa branch MCP, optional web publication, Vanessa Automation, CF/CFE export, and refresh. Use for init, tool checks, branch MCP setup/status, Vanessa/web publication setup, branch lifecycle, verification, result export, switching, or available ITL commands.
---

# 1C Workflow

Detailed ITL workflow router. For installed projects, prefer `.agents/skills/1c-workflow-fast/SKILL.md` or Kilo `/itl-*`; open details only after helper failure/request.

## Routing

Use `scripts/agent-1c.ps1` whenever PowerShell is available; it owns Git, 1C, worktrees, infobases, web publication state, Vanessa, manifests, and state.

Open `references/workflow.md` first for the lightweight lifecycle panel and topic index. Then open only the matching topic file:

- `references/init-setup.md`: initialization, tool checks, web publication/Vanessa setup, `update-workflow`, `update-ai-rules`.
- `references/mcp.md`: ROCTUP branch data MCP, vibecoding1c MCP, branch-local Vanessa MCP, External MCP, legacy branch Data MCP.
- `references/branch-lifecycle.md`: new branches, worktrees, extension helpers, context activation, refresh, list/switch, advanced close.
- `references/verification-result.md`: `/itl-check`, Vanessa Automation, event-log baseline, result export, `verificationPolicy`.
- `references/dev-branch-development.md`: work inside an existing `itldev/*` branch.
- `references/advanced-actions.md`: diagnostics and full helper action catalog.

Root `DEVELOPER-GUIDE.ru.md` and `DEV-BRANCH-DEVELOPMENT.ru.md` are human-facing; read only on request/explanation, never as mandatory references.

Intent mapping:

- Help/menu: show helper `help` or the panel in `references/workflow.md`.
- Init/bootstrap: fresh target uses root `install-agent-1c-workflow.ps1`; installed project uses monitored init wizard.
- Tool checks and web publication: `check-tools`, `list-platforms`, `detect-web-publication`, `configure-web-publication`, `publish-dev-branch`, `install-vanessa-automation`.
- ROCTUP branch data MCP: `install-roctup-mcp`, `update-roctup-mcp`, `start-roctup-mcp`, `stop-roctup-mcp`, `roctup-mcp-status`.
- vibecoding1c MCP: `vibecoding1c-mcp-setup`, `vibecoding1c-mcp-select`, `vibecoding1c-mcp-refresh-registry`, `vibecoding1c-mcp-update`, `vibecoding1c-mcp-status`, start/stop/key/model/client-config helper actions.
- Workflow/rule refresh: `update-workflow`, `update-ai-rules`.
- New work: `new-dev-branch`, `new-extension-dev-branch`.
- Branch lifecycle: `status`, `check-dev-branch`, `update-dev-branch-base`, `verify-dev-branch`, `refresh-dev-branch`, `export-dev-branch-result`.
- Advanced/recovery: `close-dev-branch`, `set-dev-branch-extension`, `dump-dev-branch-extension`, `switch-master`, `switch-dev-branch`, `list-dev-branches`, ROCTUP/Vanessa MCP actions.

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

Do not call `agent-1c.ps1 -Action init-project -InitMode wizard` directly by default. Do not run a separate `Test-Path` preflight, background PowerShell, or `timeout: 0`; raw probes may emit CLIXML. Do not collect the initialization questionnaire in chat when terminal input is unavailable and do not continue the lifecycle manually. The launcher validates the helper path, owns run status, and needs a positive long timeout. Use `-KeepWindowOnFailure` only for explicit manual debugging.

Long lifecycle runs need `timeout_ms >= 1800000`; do not use `120000 ms`. They may run 1C Designer/Enterprise (`/LoadConfigFromFiles ... /UpdateDBCfg`). `status`/`help` do not need the long timeout.

Ask setup questions only when the helper cannot collect them. Store secrets only in `.dev.env` or environment variables. Keep ITL overlay rules in `USER-RULES.md`; do not append to upstream-managed `AGENTS.md` when it already points there.

Use sibling Git worktrees for new development branches by default and leave the main folder on `master`. Development branch changes must load only into the copied branch infobase, never directly into the source infobase. Stop on unexpected dirty Git state before worktree creation, legacy switching, copying bases, dumping config files, or running 1C Designer.

Use `/itl-check` or `check-dev-branch` for the final executable gate. It runs Vanessa Automation through `TESTMANAGER -> TESTCLIENT`, reads JUnit, and checks the branch event-log baseline. Do not replace final verification with MCP, headless EPF, or `/deploy-and-test`. `/itl-result` obeys `verificationPolicy`.

ROCTUP MCP is the preferred branch-local data channel in `itldev/*` branches and does not require web publication. vibecoding1c MCP is helper-managed; Vanessa MCP is separate branch-local tooling; External MCP is not managed. Do not paste keys into chat or tracked files.

Do not search or read ignored runtime folders such as `.agent-1c/runs/`, `.agent-1c/mcp/`, `.agent-1c/infobases/`, `build/test-results/`, or `logs/` unless diagnosing a specific helper run or artifact.

When launching native Windows executables such as `1cv8.exe` through `Start-Process`, pass `-ArgumentList` as one joined and correctly quoted native command-line string, never as a PowerShell array.
