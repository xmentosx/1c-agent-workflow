## 1C Project Lifecycle

For routine lifecycle operations in an installed project, prefer short Kilo `/itl-*` commands or `.agents/skills/1c-workflow-fast/SKILL.md`. Use `.agents/skills/1c-workflow/SKILL.md` for initialization, recovery, unusual topology, or explanation; it routes details to topic references under `.agents/skills/1c-workflow/references/`.

For long ITL lifecycle actions (`new-dev-branch`, `new-extension-dev-branch`, `update-workflow`, `check-dev-branch`, `update-dev-branch-base`, `verify-dev-branch`, `refresh-dev-branch`, `export-dev-branch-result`), if the shell tool supports `timeout_ms`, set `timeout_ms >= 1800000`. Do not use `120000 ms`; these actions may run 1C Designer/Enterprise (`/LoadConfigFromFiles ... /UpdateDBCfg`). `status`/`help` do not need the long timeout.

Use `DEV-BRANCH-DEVELOPMENT.ru.md` only when developing inside an `itldev/*` branch: quick-fix for small local fixes, OpenSpec for business feature work or risky behavior changes. Before creating or editing Vanessa Automation feature files, read `VANESSA-TESTS-GUIDE.md`; do not load it for routine lifecycle commands.

Keep detailed ITL overlay rules in `USER-RULES.md`, not upstream-managed `AGENTS.md` when it already points to `USER-RULES.md`. Store secrets only in local `.dev.env`. Write `.dev.env` and `.agent-1c/*.json` as UTF-8.

Treat upstream `ai_rules_1c` as a standards and role library loaded on demand. ITL owns project lifecycle, development branch context, MCP client config, final verification, and result export. Do not load whole upstream `content/rules`, `content/skills`, `content/agents`, or `content/commands` by default; load only the specific upstream file that matches the current gap.

Search hygiene: do not read or summarize ignored runtime folders such as `.agent-1c/runs/`, `.agent-1c/mcp/`, `.agent-1c/infobases/`, `.agent-1c/tools/`, `build/test-results/`, `logs/`, `tmp/`, or `temp/` unless diagnosing a specific helper run, MCP state, log, or artifact.

Use the vibecoding1c MCP helper request for vibecoding1c MCP setup/status/update/selection and Codex/Kilo client config. Do not use upstream `/installmcp`, `/updatemcp`, or `/checkmcp` as the normal ITL MCP path. ITL connects selected endpoints under upstream canonical MCP names, and the helper removes duplicate stale upstream entries after rules install/update. Treat Vanessa MCP and External MCP as separate families; Vanessa MCP is branch-local authoring/debugging tooling, while External MCP entries are preserved and not managed by ITL. Do not paste MCP license keys into chat or tracked files. Do not expose a visible Kilo slash command for vibecoding1c MCP.

Create new development branches in sibling Git worktrees by default and leave the main project folder on `master`. Use `-UseCurrentWorktree` only when the developer explicitly asks for legacy single-folder mode. Use `.agent-1c/infobases/dev-branches` inside the branch worktree as the default copied infobase root. Development branch changes must load only into the copied branch infobase, never directly into the source infobase connected to storage.

Treat `.agent-1c/dev-branches/*.json` and `.agent-1c/event-log-baselines/*.json` as local runtime state; they contain local paths, worktree paths, launcher metadata, verification status, result paths, event-log signatures, and unverified override history.

Before running upstream infobase-bound commands such as `/update1cbase`, `/loadfrom1cbase`, or `/getconfigfiles` inside `itldev/*`, ensure current branch context is active. ITL helper lifecycle commands do this automatically. When Git is on `master`, do not run `/update1cbase` unless the developer explicitly chooses a test infobase.

Do not use `/deploy-and-test` as the normal verification command in ITL branches. The normal post-change executable cycle is `/itl-check`: it updates the branch infobase, runs Vanessa Automation through `TESTMANAGER -> TESTCLIENT`, checks `.agent-1c/event-log-baselines/*.json`, and fails on fresh non-baseline `Error` signatures. MCP is not the final verification runner. Stop only current-branch hung `TESTMANAGER`/`TESTCLIENT` processes.

For `/itl-result` and advanced `close-dev-branch`, follow `verificationPolicy`: default `warn` requires explicit unverified confirmation when `/itl-check` is not fresh passed; `block` forbids export/advanced close until verification passes. Export creates `<artifact>.manifest.json` next to the CF/CFE with artifact hash, branch metadata, commits, verification status, logs, publication URL, manual import note, and unverified override flag.

Use `DEPENDENCY_MODE=fresh` by default during initialization; use `DEPENDENCY_MODE=locked` only when the developer explicitly chooses reproducible pins. Use `/itl-update-workflow` or helper action `update-workflow` only from `master`; it refreshes managed workflow files, preserves local runtime state, records `workflowPackage`, runs `update-ai-rules` unless `-SkipAiRules` is explicit, reapplies this overlay, and leaves tracked changes for review. Use helper action `update-ai-rules` to refresh upstream rules and remove default upstream MCP client entries.

When launching native Windows executables such as `1cv8.exe` from PowerShell, do not pass a PowerShell array to `Start-Process -ArgumentList`; join and quote arguments into one native command-line string first.
