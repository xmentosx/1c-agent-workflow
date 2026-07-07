---
name: 1c-workflow
description: Initialize and operate 1C configuration or extension development projects with Git, source infobases, isolated development branch infobase copies, optional Apache publication, Vanessa Automation tests, config/extension dump/load, CF/CFE result export, development branch refresh, and branch switching. Use for 1C project init, tool checks, Vanessa/Apache setup, configuration or extension dev branch lifecycle, branch verification, result export, close, switching, or when the user asks what ITL 1C workflow commands are available.
---

# 1C Workflow

This skill is the detailed ITL workflow router. For routine commands in an installed project, prefer `.agents/skills/1c-workflow-fast/SKILL.md` or short Kilo `/itl-*` wrappers. Open details only after helper failure or on request.

## Routing

Use `scripts/agent-1c.ps1` whenever PowerShell is available. It owns Git, 1C Designer, worktrees, infobase copies, Apache, Vanessa, result manifests, and local state.

Open `references/workflow.md` for initialization, first-time setup, recovery, lifecycle semantics, or unclear helper output. Open `references/advanced-actions.md` only for diagnostics, automation, extension helpers, or Vanessa MCP. For work inside `itldev/*`, open `references/dev-branch-development.md`.

Do not use root `DEVELOPER-GUIDE.ru.md` or `DEV-BRANCH-DEVELOPMENT.ru.md` as mandatory references. They are human-facing; read them only on request or for explanations.

Intent mapping:

- Help/menu: show the short menu from `references/workflow.md`.
- Init/bootstrap: run the monitored init wizard.
- Tool checks: `check-tools`, `list-platforms`, `detect-apache`, `install-apache`, `install-vanessa-automation`.
- vibecoding1c MCP setup/update/status: `vibecoding1c-mcp-setup`, `vibecoding1c-mcp-select`, `vibecoding1c-mcp-refresh-registry`, `vibecoding1c-mcp-update`, `vibecoding1c-mcp-status`, `vibecoding1c-mcp-start`, `vibecoding1c-mcp-stop`, `vibecoding1c-mcp-rotate-keys`, `vibecoding1c-mcp-ensure-model`, `vibecoding1c-mcp-write-client-config`.
- Workflow refresh: `update-workflow`.
- Rule refresh: `update-ai-rules`.
- New work: `new-dev-branch` for configuration branches, `new-extension-dev-branch` for extension branches.
- Branch lifecycle: `status`, `update-dev-branch-base`, `verify-dev-branch`, `refresh-dev-branch`, `export-dev-branch-result`, `close-dev-branch`.
- Extension helpers: `set-dev-branch-extension`, `dump-dev-branch-extension`.
- Switching/listing: `switch-master`, `switch-dev-branch`, `list-dev-branches`.
- Vanessa MCP authoring/debugging: `install-vanessa-mcp`, `start-vanessa-mcp`, `vanessa-mcp-status`, `stop-vanessa-mcp`.

If intent is unclear, show the short menu and wait for the user's choice.

## Safety Guardrails

Initialization must start with the monitored launcher and must run in the foreground:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\run-agent-1c-window.ps1 -- -Action init-project -InitMode wizard
```

Do not call `agent-1c.ps1 -Action init-project -InitMode wizard` directly by default. Do not run separate `Test-Path` preflight, background PowerShell, `timeout: 0`; do not collect the questionnaire in chat when terminal input is unavailable; do not continue the lifecycle manually. The launcher owns CLIXML status and a positive long timeout. Use `-KeepWindowOnFailure` only for manual debugging. Use JSON mode only when requested or when an answers file exists.

Ask setup questions only when the helper cannot collect them itself; ask one raw value at a time unless the agent surface provides structured fields. Store secrets only in `.dev.env` or environment variables. Keep detailed ITL overlay rules in `USER-RULES.md`; do not append to upstream-managed `AGENTS.md` when it already points there.

Dependency mode defaults to `fresh` and records pins/hashes in `.agent-1c/dependency-lock.json`. Use `locked` only for reproducible pins; missing lock values stop initialization.

Write `.dev.env`, `.agent-1c/project.json`, `.agent-1c/tools.json`, and `.agent-1c/dev-branches/*.json` as UTF-8. Preserve Cyrillic paths and usernames exactly.

Use sibling Git worktrees for new development branches by default and leave the main folder on `master`. Use `-UseCurrentWorktree` only when the developer explicitly asks for the legacy single-folder mode. Lifecycle commands for worktree-created `itldev/*` branches must run from the branch worktree unless the helper explicitly delegates to the main worktree.

Development branch changes must load only into the copied development branch infobase, never directly into the source infobase. Stop on unexpected dirty Git state before worktree creation, legacy switching, copying bases, dumping config files, or running 1C Designer.

Use `/itl-verify` or `verify-dev-branch` for the executable gate. It updates the branch base, runs Vanessa Automation through `TESTMANAGER -> TESTCLIENT` with packet `StartFeaturePlayer`, reads JUnit, and checks the branch-local event log baseline. Do not replace final verification with MCP, headless EPF, or `/deploy-and-test`.

`/itl-result` and `/itl-close` obey `verificationPolicy`: default `warn` requires explicit unverified override unless verification is fresh passed; `block` requires `/itl-verify`.

vibecoding1c MCP is exposed through `/itl-vibecoding1c-mcp`; setup selects when saved selection is missing/incomplete; `-Force` reselects. Remote is default. Every remote server needs per-server `hostId` when multiple usable hosts are published; remote `code`/`graph` need per-server `configId`. Developers may override each server to local; local `code`/`graph` needs scope. Vanessa MCP is separate branch-local tooling exposed through `/itl-vanessa-mcp`. External MCP is not managed. Helper may write ignored `.codex/config.toml`, `.kilo/kilo.json`, `.agent-1c/mcp/*`, and `%LOCALAPPDATA%\ITL\MCP\vibecoding1c` state. Do not paste keys into chat or tracked files.

Vanessa MCP is advanced tooling for authoring, form inspection, recording, and debugging. Run one server per `itldev/*` worktree. Do not run shared Vanessa MCP from `master` or show `/itl-vanessa-mcp` in the beginner menu.

When launching native Windows executables such as `1cv8.exe` through `Start-Process`, pass `-ArgumentList` as one joined and correctly quoted native command-line string, never as a PowerShell array.
