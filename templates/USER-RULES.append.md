## 1C Project Lifecycle

For routine lifecycle work, prefer Kilo `/itl-*` or `.agents/skills/1c-workflow-fast/SKILL.md`. Use `.agents/skills/1c-workflow/SKILL.md` for init and recovery.

For long ITL lifecycle actions, set `timeout_ms >= 1800000`: 1C Designer/Enterprise may run `/LoadConfigFromFiles ... /UpdateDBCfg`. Do not use `120000 ms`. `status`/`help` do not need it.

For Kilo `/itl`, paste helper stdout verbatim; do not summarize, translate, merge OpenSpec, omit `Lifecycle:`/`Additional helper actions:`, or append "no lifecycle actions executed".

Root developer guides are human-facing; read them only when the user asks for an explanation. Use `1c-workflow/SKILL.md` plus one compact reference. Read `VANESSA-TESTS-GUIDE.md` only before editing `.feature`, never for proposal or routine `/itl-check`.

Keep ITL overlay rules in `USER-RULES.md`. Store secrets only in `.dev.env`; write state as UTF-8.

Treat `ai_rules_1c` as an on-demand standards, role, and OpenSpec command library. ITL owns lifecycle, MCP config, verification, and export; do not generate `/opsx-*` or load whole upstream `content/skills` trees.

Search hygiene: ignore `.agent-1c/runs/`, `.agent-1c/mcp/`, `.agent-1c/infobases/`, `build/test-results/`, and `logs/` unless diagnosing their runtime state.

Use the vibecoding1c MCP helper request for setup/status/update/selection and client config; do not use upstream `/installmcp`, `/updatemcp`, or `/checkmcp`. ITL preserves external entries and keeps keys out of chat/tracked files.

In `itldev/*`, prefer ROCTUP MCP for concrete data exploration: filtered `get_metadata`, then `execute_query` with limits `<= 50`/`<= 100`; stop it afterward. Never call code/session-control tools unless requested.

Use `.agents/skills/itl-vanessa-ui-mcp/SKILL.md` only for explicit user-mode inspection/reproduction/debugging, UI steps for a Vanessa Automation scenario, or a named dynamic gap after graph/code analysis. Do not start it merely for a form. Use status/start/stop; empty `VANESSA_MCP_PORT`/`URL` means stopped. Report its error/log and label any static fallback.

`Vanessa Automation verification` is not UI MCP: `/itl-check` runs `StartFeaturePlayer` through `TESTMANAGER -> TESTCLIENT`, JUnit, and event-log checks. Never replace it with UI MCP or treat its failure as an `/itl-check` result.

For PM5 product logic, technical or implementation architecture, internal subsystem design, integrations, permissions, reports, user workflows, terminology, acceptance tests, and every OpenSpec explore/propose/apply task, activate `.agents/skills/product-docs/SKILL.md` before answering, researching, planning, proposing, applying, or changing behavior (Kilo: `skill("product-docs")`; Codex: native skill activation). Search `BookStack-product-docs-mcp` before a broad repository traversal, then verify against code, tests, current 1C metadata, and available MCP evidence. Cite URLs/`updated_at`; report conflicts as `BookStack says`, `Code/MCP currently shows`, and `Decision`. If BookStack is unavailable, show recovery and label code-only conclusions provisional.

Create dev branches in sibling Git worktrees, leave main on `master`, use `-UseCurrentWorktree` only when explicit, and load only into copied branch infobases, never the source infobase.

Treat `.agent-1c/dev-branches/*.json` and `.agent-1c/event-log-baselines/*.json` as local runtime state.

Empty `INFOBASE_PUBLISH_URL` is expected without publication. Recommend it only for requested publication, dependent UI tests, or legacy `1c-data-mcp`.

Before upstream infobase-bound commands (`/update1cbase`, `/loadfrom1cbase`, `/getconfigfiles`) inside `itldev/*`, ensure branch context is active; ITL lifecycle commands do this. On `master`, do not run `/update1cbase` unless a test infobase is explicit.

Development completion gate: every agent-made 1C configuration/extension change in `itldev/*` must include relevant `tests/features` scenarios and a fresh passed `/itl-check` after final edits. This includes `/opsx-apply`, quick-fix, and direct implementation requests. Name scenarios and the Vanessa report path. Without either proof, stop with blocker diagnostics; do not report ready/done/implemented.

For quick-fix, upstream verification is only a floor: `syntaxcheck only` is insufficient in `itldev/*`. Define at least one focused regression scenario before code. Promote multi-behavior, public API, architecture, or related-metadata work to OpenSpec.

Hybrid cadence: small OpenSpec runs its `test-plan.md` and one final `/itl-check`. Large OpenSpec verifies each observable slice, carries preparatory tasks into the next slice, then runs the full plan. Plan 2-3 scenarios; a fourth needs justification. Fill `openspec/changes/<change-id>/test-report.md`.

Do not use `/deploy-and-test` as normal ITL verification. The post-change executable cycle is `/itl-check`: it updates the branch infobase, runs Vanessa Automation through `TESTMANAGER -> TESTCLIENT`, checks `.agent-1c/event-log-baselines/*.json`, and fails on fresh non-baseline `Error` signatures. MCP is not the final runner. Stop only current-branch hung `TESTMANAGER`/`TESTCLIENT`.

For `/itl-result` and advanced `close-dev-branch`, follow `verificationPolicy`: `warn` requires explicit unverified confirmation when `/itl-check` is not fresh passed; `block` forbids export/advanced close until verification passes. Export creates `<artifact>.manifest.json`.

Use `DEPENDENCY_MODE=fresh` by default; `DEPENDENCY_MODE=locked` only for chosen pins. Run `/itl-update-workflow`/`update-workflow` only from `master`; it preserves local state, records `workflowPackage`, runs `update-ai-rules` unless `-SkipAiRules`, reapplies this overlay, and leaves changes for review.

For `1cv8.exe`, pass `Start-Process -ArgumentList` as one joined native command-line string, never a PowerShell array.
