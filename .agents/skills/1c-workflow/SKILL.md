---
name: 1c-workflow
description: Initialize and operate installed ITL 1C projects for bootstrap, checks, MCP, branch lifecycle, verification, export, refresh, switching, and command help. Never use for development, review, tests, or docs of the 1c-agent-workflow source repository.
---

# 1C Workflow

Detailed ITL workflow router. For routine installed-project work, prefer `1c-workflow-fast` or Kilo `/itl-*`.

## Routing

Use `scripts/agent-1c.ps1` when PowerShell is available. Open `references/workflow.md`, then only the matching topic:

- `references/init-setup.md`: init, checks, web publication/Vanessa setup, `update-workflow`, `update-ai-rules`.
- `references/mcp.md`: ROCTUP data MCP, vibecoding1c MCP, branch Vanessa UI MCP, External MCP, legacy Data MCP.
- `references/branch-lifecycle.md`: branches, worktrees, extension helpers, context activation, refresh, list/switch, advanced close.
- `references/verification-result.md`: `/itl-check`, Vanessa Automation, event-log baseline, result export, `verificationPolicy`.
- `references/dev-branch-development.md`: work inside an existing `itldev/*` branch.
- `references/vanessa-tests.md`: author or edit focused Vanessa Automation feature tests.
- `references/vanessa-authoring.md`: pass the changed-feature MCP authoring gate.
- `references/advanced-actions.md`: diagnostics and full helper action catalog.

Human-facing guides live under `docs/itl-workflow/`; read them only for explanation. For unclear intent, show helper `help` unchanged.

## Safety Guardrails

Fresh target projects must start with the package bootstrap:

```powershell
powershell -ExecutionPolicy Bypass -File <source>\install-agent-1c-workflow.ps1 -ProjectRoot <project>
```

Bootstrap owns managed-file copy and the monitored launcher; do not expand it into manual copy steps.

Installed projects must start with the foreground monitored launcher:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\run-agent-1c-window.ps1 -- -Action init-project -InitMode wizard
```

Do not call the wizard helper directly, preflight with `Test-Path` (raw probes may emit CLIXML), use background PowerShell or `timeout: 0`. If terminal input is unavailable, do not collect the questionnaire in chat and do not continue the lifecycle manually. The launcher owns status and needs a positive long timeout (`MaxWaitSeconds 3600`); use `-KeepWindowOnFailure` only for debugging.

Long lifecycle runs need `timeout_ms >= 1800000`; monitored init needs an outer timeout above 3600s. Do not use `120000 ms`: 1C Designer/Enterprise may run `/LoadConfigFromFiles ... /UpdateDBCfg`; status/help do not need it.

If monitored bootstrap is interrupted, repeat the same command with `timeout_ms >= 3900000`; the launcher owns orphan detection and resume. Do not delete Git locks, continue init manually, or edit run status.

With default `DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP=manual-confirm`, create branches through `scripts/run-agent-1c-window.ps1`: a valid source confirmation makes the run question-free, otherwise the copied base is confirmed immediately after repository unbind. Direct helper calls require that source confirmation or explicit automation with `DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP=skip`.

Ask setup questions only when the helper cannot collect them. Store secrets only in `.dev.env` or environment variables. Keep ITL overlay rules in `USER-RULES.md`.

Use sibling Git worktrees, leave the main folder on `master`, and load only the copied branch infobase. Stop on unexpected dirty Git state before lifecycle changes.

Use `/itl-check` or `check-dev-branch` for the final executable gate. It runs Vanessa Automation verification through `TESTMANAGER -> TESTCLIENT`, reads JUnit, and checks the event-log baseline. Never replace it with MCP, a headless EPF, or `/deploy-and-test`.

Run `/itl-vanessa-author` for new/changed `.feature`; it owns authoring evidence through `itl-vanessa-ui` and stays outside `itl-routine`.

ROCTUP MCP is the preferred branch-local data channel in `itldev/*` and does not require web publication. Vanessa UI MCP is separate branch runtime tooling; use `.agents/skills/itl-vanessa-ui-mcp/SKILL.md` only when static analysis cannot answer the required UI question. Vanessa Automation verification is the separate `/itl-check` runner. vibecoding1c MCP is helper-managed; External MCP is unmanaged. Do not paste keys into chat or tracked files.

Read ignored runtime folders only when diagnosing a specific helper run or artifact.

When launching native Windows executables such as `1cv8.exe` through `Start-Process`, pass `-ArgumentList` as one joined and correctly quoted native command-line string, never as a PowerShell array.
