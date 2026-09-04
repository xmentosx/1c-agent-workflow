---
name: 1c-workflow
description: Route non-routine work in installed ITL 1C projects for initialization, MCP, unclear development modes, recovery, unusual topology, and detailed explanations. For routine status, branch creation, checks, refresh, export, or switching use 1c-workflow-fast or an explicit generated itl-* skill. Never use for development, review, tests, or docs of the 1c-agent-workflow source repository.
---

# 1C Workflow

Detailed ITL workflow router for non-routine work. Explicit generated `itl-*` skills run alone; natural-language routines use only `1c-workflow-fast`.

## Routing

Use `scripts/agent-1c.ps1` when PowerShell is available. Open only the matching topic below. Open `references/workflow.md` only for help, an unclear request, or the complete client-aware command menu:

- `references/init-setup.md`: init, checks, web publication/Vanessa setup, `update-workflow`, `update-ai-rules`.
- `references/mcp.md`: ROCTUP data MCP, vibecoding1c MCP, branch Vanessa UI MCP, External MCP, legacy Data MCP.
- `references/branch-lifecycle.md`: branches, worktrees, extension helpers, context activation, refresh, list/switch, advanced close.
- `references/verification-result.md`: `/itl-check`, Vanessa Automation, event-log baseline, result export, `verificationPolicy`.
- `references/yaxunit-tests.md`: author algorithmic unit tests, boundary partitions, and dangerous invariants with YAxUnit.
- `references/dev-branch-development.md`: unclear development mode, the complete branch-development menu, or pending extension setup inside an existing `itldev/*` branch.
- `references/dev-branch-quick-fix.md`: an already classified direct quick-fix inside `itldev/*`.
- `references/dev-branch-direct.md`: an already classified direct full-cycle change inside `itldev/*`.
- `references/dev-branch-openspec.md`: an already selected OpenSpec planning flow, with quick-fix or full-cycle execution chosen independently, inside `itldev/*`.
- `references/vanessa-tests.md`: author or edit focused Vanessa Automation feature tests.
- `references/vanessa-authoring.md`: use MCP selectively while developing or diagnosing Vanessa tests.
- `references/vanessa-recipes.md`: open one matching pattern after `vanessa-tests.md` selects the check.
- `references/advanced-actions.md` and `references/auxiliary-contours.md`: agent-led extra configurations, bases, tests, CF, extensions, MCP.

Human-facing guides live under `docs/itl-workflow/`; read only for explanation. For unclear intent, show helper `help` unchanged.

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

Long actions default to `timeout_ms >= 3900000`, above Designer's 3600-second limit; raise it with a higher configured limit. Do not use `120000 ms`; status/help do not need it. 1C Designer/Enterprise may run `/LoadConfigFromFiles ... /UpdateDBCfg`.

If monitored bootstrap is interrupted, repeat the same command with `timeout_ms >= 3900000`; the launcher owns orphan detection and resume. Do not delete Git locks, continue init manually, or edit run status.

After any successful compact-runner action with a non-empty `userReport`, the final response must be exactly that Russian Markdown. Exception: on `classify-tests-after-refresh:*`, follow its `advanced-actions.md` continuation before finalizing; never ask the developer or run 1C. Do not translate it, convert it to a table, rename or merge fields, reorder or omit lines, use a code fence, summarize, substitute `requiredAction`, read `console.log`, or lose settings, evidence, MCP/Browser, advice, and actions. New worktree windows need no reload. On `userReportOmitted=true`, follow report recovery in `.agents/skills/1c-workflow/references/advanced-actions.md`; omission never changes the helper result.

With default `DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP=manual-confirm`, create branches through `scripts/run-agent-1c-window.ps1`: a valid source confirmation makes the run question-free, otherwise the copied base is confirmed immediately after repository unbind. Direct helper calls require that source confirmation or explicit automation with `DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP=skip`.

Ask setup questions only when the helper cannot collect them. Store secrets only in `.dev.env` or environment variables. Keep ITL overlay rules in `USER-RULES.md`.

Use sibling Git worktrees, leave the main folder on `master`, and load only the copied branch infobase. Stop on unexpected dirty Git state before lifecycle changes.

Use `/itl-check` or `check-dev-branch` for the final executable gate. It runs configured YAxUnit unit tests, Vanessa Automation through `TESTMANAGER -> TESTCLIENT`, reads JUnit, and checks the event-log baseline. Never replace it with MCP, a headless EPF, or `/deploy-and-test`.

ROCTUP MCP is the preferred branch-local data channel in `itldev/*` and needs no web publication. Use Vanessa UI MCP only when static analysis cannot answer the UI question; `/itl-check` remains the separate verification runner. vibecoding1c MCP is helper-managed; External MCP is unmanaged. Never paste keys into chat or tracked files.

Read ignored runtime folders only when diagnosing a specific helper run or artifact.

When launching native Windows executables such as `1cv8.exe` through `Start-Process`, pass `-ArgumentList` as one joined and correctly quoted native command-line string, never as a PowerShell array.
