## 1C Project Lifecycle

For routine installed-project lifecycle work, prefer Kilo `/itl-*` or `.agents/skills/1c-workflow-fast/SKILL.md`. Use `.agents/skills/1c-workflow/SKILL.md` for init, recovery, unusual topology, or explanation; it routes to `.agents/skills/1c-workflow/references/`.

For long ITL lifecycle actions, including `new-dev-branch`, `update-workflow`, `check-dev-branch`, `refresh-dev-branch`, and `export-dev-branch-result`, if the shell supports `timeout_ms`, set `timeout_ms >= 1800000`. Do not use `120000 ms`; these may run 1C Designer/Enterprise (`/LoadConfigFromFiles ... /UpdateDBCfg`). `status`/`help` do not need it.

For Kilo `/itl`, paste helper help stdout verbatim; do not summarize/translate, merge OpenSpec, omit `Lifecycle:`/`Additional helper actions:`, or append "no lifecycle actions executed".

Use `DEV-BRANCH-DEVELOPMENT.ru.md` only inside `itldev/*`: quick-fix for small local fixes, OpenSpec for business feature work or risk. Before creating or editing Vanessa feature files, read `VANESSA-TESTS-GUIDE.md`; skip it for routine lifecycle commands.

Keep detailed ITL overlay rules in `USER-RULES.md`, not upstream-managed `AGENTS.md` when it already points there. Store secrets only in `.dev.env`; write `.dev.env` and `.agent-1c/*.json` as UTF-8.

Treat upstream `ai_rules_1c` as a standards, role, and OpenSpec command library loaded on demand. ITL owns lifecycle, branch context, MCP client config, final verification, and export; it does not generate or modify `/opsx-*`. Do not load whole upstream `content/rules`, `content/skills`, `content/agents`, or `content/commands`; load only the needed file.

Search hygiene: do not read ignored runtime folders such as `.agent-1c/runs/`, `.agent-1c/mcp/`, `.agent-1c/infobases/`, `.agent-1c/tools/`, `build/test-results/`, `logs/`, `tmp/`, or `temp/` unless diagnosing a specific helper run, MCP state, log, or artifact.

Use the vibecoding1c MCP helper request for setup/status/update/selection and client config. Do not use upstream `/installmcp`, `/updatemcp`, or `/checkmcp`; ITL owns selected endpoints and removes duplicates. Vanessa MCP is separate authoring/debugging tooling; external entries are preserved. Do not paste keys into chat/tracked files or expose a Kilo slash command for vibecoding1c MCP.

In `itldev/*`, prefer ROCTUP MCP for data. Start it only for a concrete data exploration operation with `start-roctup-mcp`, use filtered `get_metadata` before `execute_query`, keep limits `<= 50` and `<= 100`, then stop it with `stop-roctup-mcp`. Never call `execute_code`, `restart_1c_session`, or `close_1c_session` unless requested.

For PM5 product logic, architecture, workflows, terminology, permissions, reports, integrations, or acceptance tests, use `.agents/skills/product-docs/SKILL.md` and search `BookStack-product-docs-mcp` before answering, exploring, planning, proposing, or changing behavior. BookStack is advisory, not authoritative; verify against code, tests, current 1C metadata, and available MCP evidence. Cite URLs/`updated_at`. On conflict, report `BookStack says`, `Code/MCP currently shows`, and `Decision`.

Create dev branches in sibling Git worktrees, leave main on `master`, use `-UseCurrentWorktree` only when explicit, and load only into copied branch infobases, never the source infobase.

Treat `.agent-1c/dev-branches/*.json` and `.agent-1c/event-log-baselines/*.json` as local runtime state.

Before upstream infobase-bound commands (`/update1cbase`, `/loadfrom1cbase`, `/getconfigfiles`) inside `itldev/*`, ensure branch context is active; ITL lifecycle commands do this. On `master`, do not run `/update1cbase` unless a test infobase is explicit.

Development completion gate: in `itldev/*`, any agent-made 1C configuration/extension change in `src/cf`, `src/cfe`, modules, forms, commands, metadata, or related 1C logic must include relevant Vanessa tests in `tests/features` and a fresh passed `/itl-check` after final code, metadata, and test edits. This applies to `/opsx-apply`, quick-fix, "develop code by this plan", "execute development tasks", and "make this change". The final reply must name scenarios and the Vanessa report path. Do not answer ready/done/implemented if tests are missing, `/itl-check` did not run, or verification is not fresh passed; stop with blocker diagnostics.

Hybrid cadence: quick-fix needs at least one focused regression scenario. Small OpenSpec runs `test-plan.md` scenarios and one final `/itl-check`. Large OpenSpec groups `tasks.md` into checkable slices: each slice with observable behavior gets at least one focused Vanessa scenario; preparatory tasks are marked pending verification and covered by the next slice. After the last task, run the full 2-4 scenario set for changed business behavior, including happy and boundary/negative cases, and fill `openspec/changes/<change-id>/test-report.md`.

Do not use `/deploy-and-test` as normal ITL verification. The post-change executable cycle is `/itl-check`: it updates the branch infobase, runs Vanessa Automation through `TESTMANAGER -> TESTCLIENT`, checks `.agent-1c/event-log-baselines/*.json`, and fails on fresh non-baseline `Error` signatures. MCP is not the final runner. Stop only current-branch hung `TESTMANAGER`/`TESTCLIENT`.

For `/itl-result` and advanced `close-dev-branch`, follow `verificationPolicy`: `warn` requires explicit unverified confirmation when `/itl-check` is not fresh passed; `block` forbids export/advanced close until verification passes. Export creates `<artifact>.manifest.json`.

Use `DEPENDENCY_MODE=fresh` by default; `DEPENDENCY_MODE=locked` only for chosen pins. Run `/itl-update-workflow`/`update-workflow` only from `master`; it preserves local state, records `workflowPackage`, runs `update-ai-rules` unless `-SkipAiRules`, reapplies this overlay, and leaves changes for review.

For `1cv8.exe`, pass `Start-Process -ArgumentList` as one joined native command-line string, never a PowerShell array.
