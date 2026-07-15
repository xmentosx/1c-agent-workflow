## 1C Project Lifecycle

For routine lifecycle work use Kilo `/itl-*` or `.agents/skills/1c-workflow-fast/SKILL.md`; use `.agents/skills/1c-workflow/SKILL.md` for init/recovery and its one matching reference. Set `timeout_ms >= 1800000` for long 1C Designer/Enterprise actions; do not use `120000 ms` for `LoadConfigFromFiles` or `UpdateDBCfg`. `status`/`help` do not need the long timeout.

For Kilo `/itl`, return helper stdout verbatim: do not summarize, translate, merge OpenSpec, omit `Lifecycle:`/`Additional helper actions:`, or add "no lifecycle actions executed". Human guides are explanatory only. Read `VANESSA-TESTS-GUIDE.md` only before editing `.feature`.

Keep this ITL overlay in `USER-RULES.md`; keep secrets in `.dev.env` and state UTF-8. ITL owns lifecycle, MCP config, verification, and export. `ai_rules_1c` is the on-demand standards, role, and OpenSpec command library; do not generate `/opsx-*` or load whole `content/skills` trees.

Search hygiene: ignore `.agent-1c/runs/`, `.agent-1c/mcp/`, `.agent-1c/infobases/`, `build/test-results/`, and `logs/` unless diagnosing runtime state.

Use the vibecoding1c MCP helper request for setup/status/update/selection and client config; never upstream `/installmcp`, `/updatemcp`, or `/checkmcp`. Preserve external entries and keep keys out of chat/Git. ROCTUP data access and `.agents/skills/itl-vanessa-ui-mcp/SKILL.md` are on demand, not completion gates. Vanessa UI MCP is for a named runtime UI question; `/itl-check` uses Vanessa Automation `TESTMANAGER -> TESTCLIENT` and is the final runner.

For PM5 product logic, technical or implementation architecture, internal subsystem design, integrations, permissions, reports, user workflows, terminology, acceptance tests, and every OpenSpec explore/propose/apply task, activate `.agents/skills/product-docs/SKILL.md` before answering, researching, planning, proposing, applying, or changing behavior (Kilo: `skill("product-docs")`; Codex: native skill activation). Search `BookStack-product-docs-mcp` before a broad repository traversal, then verify against code, tests, current 1C metadata, and available MCP evidence. Cite URLs/`updated_at`; report conflicts as `BookStack says`, `Code/MCP currently shows`, and `Decision`. If BookStack is unavailable, show recovery and label code-only conclusions provisional.

Create dev branches in sibling Git worktrees, leave main on `master`, and load only copied branch infobases. Treat `.agent-1c/dev-branches/*.json` and `.agent-1c/event-log-baselines/*.json` as local state. On `master`, never update the source infobase unless an explicit test infobase is named. Empty `INFOBASE_PUBLISH_URL` is normal when publication is disabled.

Development completion gate: every agent-made 1C configuration/extension change in `itldev/*` requires relevant `tests/features` scenarios and one fresh passed `/itl-check` after final edits. This includes `/opsx-apply`, quick-fix, and direct implementation requests. Name each scenario and Vanessa report path. Without either proof, stop with blocker diagnostics; do not report ready/done/implemented.

For quick-fix define at least one focused regression scenario before code; `syntaxcheck only` is insufficient in `itldev/*`. Promote multi-behavior, public API, architecture, or related-metadata work to OpenSpec.

Hybrid cadence: small OpenSpec runs its `test-plan.md` and one final `/itl-check`. Large OpenSpec verifies each observable slice, carries preparatory tasks forward, then runs the full plan. Plan 2-3 scenarios; a fourth needs justification. Fill `openspec/changes/<change-id>/test-report.md`.

`/itl-check` updates the branch infobase, runs Vanessa, checks `.agent-1c/event-log-baselines/*.json`, and fails on fresh non-baseline `Error` signatures. Do not replace it with MCP or `/deploy-and-test`; stop only current-branch hung `TESTMANAGER`/`TESTCLIENT`.

For `/itl-result` and advanced close, `verificationPolicy=warn` needs explicit unverified confirmation; `block` requires fresh passed verification. Export creates `<artifact>.manifest.json`.

Use `DEPENDENCY_MODE=fresh` normally and `locked` only for chosen pins. Run `/itl-update-workflow`/`update-workflow` only on clean `master`: it preserves local state, records `workflowPackage`, runs `update-ai-rules` unless `-SkipAiRules`, reapplies this overlay, and leaves changes for review. Active dev branches receive it intentionally through `/itl-refresh`; after project-instruction changes run Kilo `/reload` or open a new session.

For `1cv8.exe`, pass `Start-Process -ArgumentList` as one joined native command-line string, never a PowerShell array.
