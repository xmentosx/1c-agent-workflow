## 1C Project Lifecycle

Use Kilo `/itl-*` or `.agents/skills/1c-workflow-fast/SKILL.md` routinely; use `.agents/skills/1c-workflow/SKILL.md` plus one reference for init/recovery. Long 1C Designer/Enterprise actions need `timeout_ms >= 1800000`; do not use `120000 ms` for `LoadConfigFromFiles`/`UpdateDBCfg`. `status`/`help` do not.

For Kilo `/itl`, return helper stdout verbatim; do not summarize, translate, merge OpenSpec, omit `Lifecycle:`/`Additional helper actions:`, or add "no lifecycle actions executed". Read `VANESSA-TESTS-GUIDE.md` only before editing `.feature`.

Keep this overlay in `USER-RULES.md`, secrets in `.dev.env`, and state UTF-8. ITL owns lifecycle/MCP/verification/export; `ai_rules_1c` is the on-demand standards, role, and OpenSpec command library. Do not generate `/opsx-*` or load whole `content/skills` trees.

Search hygiene: ignore `.agent-1c/runs/` and `build/test-results/` unless diagnosing runtime state.

Use the vibecoding1c MCP helper request for setup/status/update/selection/client config; never upstream `/installmcp`, `/updatemcp`, or `/checkmcp`. Preserve external entries and secrets. ROCTUP and `.agents/skills/itl-vanessa-ui-mcp/SKILL.md` are on demand, not gates. `/itl-check` uses Vanessa Automation `TESTMANAGER -> TESTCLIENT`.

For PM5 product logic, technical or implementation architecture, internal subsystem design, acceptance tests, and OpenSpec explore/propose/apply, activate `.agents/skills/product-docs/SKILL.md` before answering, researching, planning, proposing, applying, or changing behavior (Kilo: `skill("product-docs")`; Codex: native skill activation). Search `BookStack-product-docs-mcp` before a broad repository traversal, then verify against code, tests, current 1C metadata, and available MCP evidence. Cite URLs/`updated_at`; report conflicts as `BookStack says`, `Code/MCP currently shows`, and `Decision`. If BookStack is unavailable, show recovery and label code-only conclusions provisional.

Use sibling Git worktrees, leave main on `master`, and load only copied branch infobases. Branch/event-baseline JSON is local state. On `master`, never update the source infobase unless an explicit test infobase is named. Empty `INFOBASE_PUBLISH_URL` is normal when publication is disabled.

Development completion gate: `itldev/*` means the current Git branch name, never a directory or file glob. In such a branch, every agent-made 1C configuration/extension change under configured `exportPath`/`extensionsPath` (for example `src/cf`/`src/cfe`) requires relevant scenarios under configured `testsPath` (usually `tests/features`) and one fresh passed `/itl-check` after final edits. `/opsx-apply`, quick-fix, XML-only, and direct implementation requests have no exemption. Name each scenario and Vanessa report path. Without either proof, report blocker diagnostics; do not report ready/done/implemented. On `master`, editing these sources is a branch-safety blocker, not a test-cycle exception.

For quick-fix define one focused regression scenario before code; `syntaxcheck only` is insufficient. Promote multi-behavior, public API, architecture, or related-metadata work to OpenSpec.

Hybrid cadence: small OpenSpec runs its `test-plan.md` and one final `/itl-check`. Large OpenSpec verifies each observable slice, carries preparatory tasks forward, then runs the full plan. Plan 2-3 scenarios; a fourth needs justification. Fill `openspec/changes/<change-id>/test-report.md`.

`/itl-check` updates the branch infobase, runs Vanessa, checks `.agent-1c/event-log-baselines/*.json`, and fails on fresh non-baseline `Error` signatures. Do not replace it with MCP or `/deploy-and-test`; stop only current-branch hung `TESTMANAGER`/`TESTCLIENT`.

For `/itl-result` and advanced close, `verificationPolicy=warn` needs explicit unverified confirmation; `block` requires fresh passed verification. Export creates `<artifact>.manifest.json`.

Use `DEPENDENCY_MODE=fresh`; reserve `locked` for pins. Run `/itl-update-workflow`/`update-workflow` only on clean `master`; it preserves state, records `workflowPackage`, runs `update-ai-rules` unless skipped, and leaves reviewable changes. Active branches receive it through `/itl-refresh`; then run Kilo `/reload` or open a new session.

For `1cv8.exe`, pass `Start-Process -ArgumentList` as one joined native command-line string, never a PowerShell array.
