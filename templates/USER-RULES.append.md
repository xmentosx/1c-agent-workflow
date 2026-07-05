## 1C Project Lifecycle

Use `.agents/skills/1c-workflow/SKILL.md` for detailed project initialization, development branch creation, development branch refresh, development branch base update, Vanessa Automation test runs, master sync, development branch listing, branch switching, development branch close, and CF/CFE result export.

For routine lifecycle operations in an already installed project, prefer the short Kilo `/itl-*` commands or `.agents/skills/1c-workflow-fast/SKILL.md`. The fast path runs `.agents/skills/1c-workflow/scripts/agent-1c.ps1` directly and should read detailed workflow references only after helper failure or when the developer asks for explanation.

Use `DEV-BRANCH-DEVELOPMENT.ru.md` for the development process inside a development branch: quick-fix for small local fixes, OpenSpec for business feature work or risky behavior changes.

When asking the developer for missing setup values, ask one value at a time and accept the raw value only. Do not ask for `KEY=value` blocks, one large free-form block with all missing variables, or variable names.

For optional passwords, ask whether the password is set before asking for the value. If the password is not set, store an empty value and do not treat placeholder text as the password.

Before asking for the 1C platform path, search existing standard `C:\Program Files\1cv8` and `C:\Program Files (x86)\1cv8` folders and offer installed versions as choices. Missing standard folders are normal; skip them without error. Do not offer the common `C:\Program Files\1cv8` root as a version.

Keep detailed ITL overlay rules in `USER-RULES.md`. Do not append to upstream-managed `AGENTS.md` when it already points to `USER-RULES.md`. Store secrets only in local `.dev.env`.

Treat upstream `ai_rules_1c` as a standards and role library loaded on demand. ITL owns project lifecycle, development branch context, MCP client config, final verification, and result export.

Do not load the whole upstream `content/rules`, `content/skills`, `content/agents`, or `content/commands` tree by default. Load only the specific upstream rule, skill, command, or agent file that matches the current gap. Use upstream subagent pipelines only for full-cycle or risky work, not for routine ITL lifecycle operations. Before a parameter-rich MCP call, read only the relevant upstream MCP doc or the live tool schema.

Write `.dev.env` and `.agent-1c/*.json` files as UTF-8 so Cyrillic usernames and paths are preserved.

Treat `.agent-1c/dev-branches/*.json` and `.agent-1c/event-log-baselines/*.json` as local runtime state. They are ignored by Git because they contain local paths, worktree paths, 1C launcher metadata, verification status, result paths, event-log baseline signatures, and unverified override history.

Use `/itl-vibecoding1c-mcp` for vibecoding1c MCP setup, remote/local selection, registry refresh, update, start/stop, status, key rotation, local embedding model bootstrap, and Codex/Kilo client config. Setup applies saved selection and opens selection first when it is missing or incomplete; use `vibecoding1c-mcp-select` or `vibecoding1c-mcp-setup -Force` to explicitly reselect servers. Remote LAN vibecoding1c MCP is the default; config-specific remote vibecoding1c MCP needs an explicit per-server `configId`, and `code`/`graph` selections do not inherit `configId` or `hostId` from each other. Do not paste MCP license keys into chat or tracked files; the helper stores rotated keys and port/model state under `%LOCALAPPDATA%\ITL\MCP\vibecoding1c` and project/worktree MCP state under ignored `.agent-1c/mcp/`, `.codex/config.toml`, and `.kilo/kilo.json*`.

Do not use upstream `/installmcp`, `/updatemcp`, or `/checkmcp` as the normal MCP path in ITL projects. Use `/itl-vibecoding1c-mcp` and `vibecoding1c-mcp-status`; the helper removes default upstream `ai_rules_1c` MCP client entries after rules install/update to avoid duplicate stale endpoints. Upstream MCP docs still apply as role guidance for exact tool names and arguments when the corresponding `itl-*` endpoint is actually exposed in the current session.

Treat Vanessa MCP and External MCP as separate families. Vanessa MCP is always local branch tooling through `/itl-vanessa-mcp`; External MCP entries are not started, stopped, published, or removed by the vibecoding1c MCP helper.

Create new development branches in sibling Git worktrees by default, under `<project-folder>-worktrees/<branch>`, and leave the main project folder on `master`. Use `-UseCurrentWorktree` only when the developer explicitly asks for the legacy single-folder checkout mode.

Use `.agent-1c/infobases/dev-branches` inside the active branch worktree as the default development branch infobase copy root and keep `.agent-1c/infobases/` ignored by Git.

Development branch changes must be loaded only into the development branch infobase copy, never directly into the source infobase connected to 1C configuration repository storage.

Before running ai_rules_1c IB-bound commands such as `/update1cbase`, `/loadfrom1cbase`, or `/getconfigfiles` inside an `itldev/*` branch, ensure the current development branch context is active. The ITL helper does this automatically during branch lifecycle commands.

Do not use `/deploy-and-test` as the normal verification command in an ITL development branch because it reloads all files. The normal executable verification cycle is `/itl-verify`. Use `/itl-update-base` only when you need to update the branch infobase without tests.

Use Vanessa Automation scenarios from `tests/features` for OpenSpec and quick-fix verification. `/itl-verify` runs Vanessa through packet `StartFeaturePlayer` in a real `TESTMANAGER -> TESTCLIENT` flow with a branch-local `VANESSA_TEST_PORT`; do not replace the final gate with MCP or a headless EPF launch. The same gate also checks the branch-local file infobase event log against the branch baseline and fails on fresh non-baseline `Error` signatures. `VANESSA_TEST_TIMEOUT_SECONDS` limits the full test run; on timeout, stop only current-branch `TESTMANAGER`/`TESTCLIENT` processes. Vanessa MCP is only for authoring, form inspection, step search, recording, and point debugging in the current branch. For behavior changes, create or update a small Vanessa Automation check set: at least 2 checks, usually 2-3, and no more than 4 unless explicitly justified. Include the main successful scenario and at least one meaningful boundary or negative scenario. Choose the check type by change kind: unit-like for local logic, integration for object/register/document/exchange interaction, and UI only for forms, commands, or visible user behavior. For large OpenSpec changes, test each meaningful implementation slice separately. If Vanessa finds an error, analyze the JUnit/report/status/log/event-log report and active 1C process diagnostics, fix the cause, update the branch base again, and rerun the relevant scenario. Never kill another worktree's `TESTMANAGER` or `TESTCLIENT`; stop only the current branch's own hung test manager/client.

For `/itl-result` and `/itl-close`, create `<artifact>.manifest.json` next to the exported CF/CFE. The manifest records artifact SHA256, operation, branch metadata, master/development commits, verification status/report/log, latest 1C log path, publication URL, manual import note, and whether an unverified override was used.

Use `DEPENDENCY_MODE=fresh` by default during initialization: resolve current dependencies and record the ITL workflow package commit, `ai_rules_1c` commit, and Vanessa/Apache URL and SHA256 values in `.agent-1c/dependency-lock.json`. Use `DEPENDENCY_MODE=locked` only when the developer explicitly chooses reproducible pins; stop if the lock manifest is incomplete or a hash does not match.

Use `/itl-update-workflow` or helper action `update-workflow` to refresh the installed ITL workflow package in an already initialized project. Run it only from the `master` worktree. It updates managed workflow files, preserves local runtime state, records `workflowPackage` in `.agent-1c/dependency-lock.json`, runs `update-ai-rules` unless `-SkipAiRules` is explicit, and leaves tracked changes for review/commit. Do not run it from `itldev/*`; merge the updated `master` into active branches or run `/itl-refresh` from each branch worktree.

Use `/itl-update-rules` or helper action `update-ai-rules` to refresh upstream `ai_rules_1c` after initialization. The helper runs the upstream updater, removes default upstream MCP client entries, records the resolved commit in `.agent-1c/dependency-lock.json`, reapplies this ITL overlay, and avoids modifying upstream-managed `AGENTS.md` when it already points to `USER-RULES.md`.

For `/itl-result` and `/itl-close`, follow `VERIFICATION_POLICY`: default `warn` requires explicit unverified confirmation when `/itl-verify` is not fresh passed; `block` forbids export/close until verification passes. Parallel independent development lines should use separate `itldev/*` branches/worktrees, while one development branch may remain long-lived and contain several sequential tasks.

When Git is on `master`, do not run `/update1cbase` unless the developer explicitly chooses a test infobase. For worktree-created branches, `/itl-switch` shows the target worktree path instead of checking it out over the current folder. The ITL workflow clears active development branch infobase values when switching to `master` or closing a worktree branch.

When launching native Windows executables such as `1cv8.exe` from PowerShell, do not pass a PowerShell array to `Start-Process -ArgumentList`. Join and quote arguments into one native command-line string first, or use the `&` call operator for simple cases. Paths with spaces must remain one native argument; otherwise 1C Designer may exit with code 1 or hang behind `-WindowStyle Hidden`.
