---
name: 1c-workflow
description: Initialize and operate 1C configuration or extension development projects with Git, a source infobase that may or may not be connected to a 1C configuration repository, isolated development branch infobase copies, optional Apache web publication, Vanessa Automation tests, config/extension dump/load, CF/CFE result export, development branch refresh from master, and branch switching. Use when the user asks to init a 1C project, check required tools, install Vanessa Automation, create or close a configuration or extension development branch, refresh a development branch from master/storage, sync master, update a development branch base from changed config or extension files, run branch tests, prepare a CF/CFE result, switch to master or a development branch, or asks what ITL 1C workflow commands are available.
---

# 1C Workflow

## Overview

Use this skill to run the standard lifecycle for agent-assisted 1C configuration development. The workflow is cross-agent: the same `.agents/skills/1c-workflow` directory works in Codex and Kilo Code, while Kilo-specific slash command wrappers can live in `.kilo/commands`.

For routine lifecycle commands in an already installed project, prefer the short Kilo `/itl-*` commands or the separate fast skill `.agents/skills/1c-workflow-fast`. The fast path calls the PowerShell helper directly and reads detailed workflow references only after helper failure or when the user asks for explanation.

## Intent Routing

Map user intent to one workflow:

- `HELP`: user asks what actions are available, asks for commands, asks for help, or runs `/itl`.
- `INIT_PROJECT`: user asks to initialize/bootstrap/create a 1C agent project.
- `CHECK_TOOLS`: user asks to check required software, setup, Git, 1C platform, Apache, or webinst.
- `INSTALL_APACHE`: user agreed to automatically install Apache/httpd for 1C web publication.
- `INSTALL_VANESSA_AUTOMATION`: user asks to install Vanessa Automation for branch tests.
- `RUN_DEV_BRANCH_TESTS`: user asks to run tests, Vanessa tests, executable checks, or OpenSpec verification for the current development branch.
- `VERIFY_DEV_BRANCH`: user asks to verify/check the current development branch through the standard ITL cycle.
- `STATUS`: user asks for ITL status, current branch, active branch, current base, or verification state.
- `NEW_DEV_BRANCH`: user asks to create/start/begin a configuration development branch, task branch, customization branch, or parallel work branch.
- `NEW_EXTENSION_DEV_BRANCH`: user asks to create/start/begin an extension development branch.
- `SET_DEV_BRANCH_EXTENSION`: user asks to set or remember the extension name for the current extension development branch.
- `DUMP_DEV_BRANCH_EXTENSION`: user asks to dump/export extension files from the current extension branch infobase into `src/cfe`.
- `ACTIVATE_DEV_BRANCH_CONTEXT`: user asks to make `/update1cbase` or another ai_rules_1c infobase command use the current development branch infobase.
- `SYNC_MASTER`: user asks to refresh/sync master from 1C repository storage or from the current source infobase state.
- `UPDATE_DEV_BRANCH_BASE`: user asks to update the current development branch infobase from branch files.
- `REFRESH_DEV_BRANCH`: user asks to update a development branch from master, refresh the current branch, or merge fresh source/storage changes into a development branch.
- `EXPORT_DEV_BRANCH_RESULT`: user asks to make/export a CF or CFE result for the current development branch without closing it.
- `CLOSE_DEV_BRANCH`: user asks to close/finish the current development branch and prepare/export final CF or CFE result.
- `SWITCH_MASTER`: user asks to switch to master.
- `SWITCH_DEV_BRANCH`: user asks to switch to a development branch.
- `LIST_DEV_BRANCHES`: user asks to list/show active development branches or the current development branch.

If intent is unclear, do not guess. Show the short menu from `references/workflow.md`.

## Required Reading

Before executing any lifecycle workflow, read `references/workflow.md`.

When the user asks to develop, implement, fix, review, or plan work inside an already started development branch, also read `references/dev-branch-development.md` and follow its quick-fix/OpenSpec process.

Use `scripts/agent-1c.ps1` when PowerShell is available. Prefer the script over retyping command-line calls because 1C Designer operations are fragile and benefit from deterministic logging and path checks.

## Operating Rules

For project initialization, prefer the helper script wizard: run `init-project -InitMode wizard`. The wizard collects setup values, writes `.dev.env` and `.agent-1c/project.json`, summarizes values without passwords, and then runs the initialization lifecycle. Use `-InitMode json -InitAnswersPath <file>` only when the agent has already collected structured answers and needs a non-interactive init.

Ask for missing required parameters at the start of the selected workflow only when the helper cannot collect them itself. Do not ask for parameters that are already present in `.agent-1c/project.json` or `.dev.env`.

When collecting unrelated setup parameters from the developer, ask one value at a time and expect the answer to contain only the value. During project initialization, collect source infobase values after the source infobase kind is known, and collect configuration repository values only when the developer says the source infobase is connected to storage. If the agent surface supports several structured fields/questions in one prompt, use one grouped form with separate short questions; otherwise ask the same values sequentially, one question at a time. Never ask the developer to enter 6 or 7 lines into one free-form text answer, because Enter may submit the first line in Codex/Kilo Code. Never ask for a grouped `KEY=value` block, never show one large question that lists all missing project variables, and never require the developer to type variable names.

In password lines of the grouped questionnaire, exact values `нет` and `-` mean an empty password. Compare these markers case-insensitively after trimming whitespace and store an empty value instead of the marker text. When invoking 1C, omit the infobase `/P` option when the infobase password is empty. For repository login, pass `/ConfigurationRepositoryP` only when `sourceUsesRepository=true`; when the repository password is empty, pass it as a quoted empty native argument (`""`) so 1C does not open an interactive repository login dialog and the next option is not shifted into the password position.

Use fixed project defaults: `master` is the main branch and `src/cf` is the configuration dump path. Do not ask the developer for these values during initialization.

Treat `src/cf` as tracked project content. Source dump commits must include only `src/cf` and must verify `src/cf/ConfigDumpInfo.xml` is present in `HEAD` after initial project creation.

Use sibling Git worktrees for new development branches by default. The main project folder stays on `master`; each active development line gets its own worktree under `<project-folder>-worktrees/<branch>` unless `DEV_BRANCH_WORKTREE_ROOT`, `devBranchWorktreeRoot`, or an explicit `-DevBranchWorktreePath` overrides it. Use `-UseCurrentWorktree` only when the developer explicitly asks for the legacy single-folder checkout mode.

Use `.agent-1c/infobases/dev-branches` as the default development branch infobase copy root inside the active branch worktree. Do not ask for this path during normal initialization; ensure `.agent-1c/infobases/` is ignored by Git.

Before asking for the 1C platform path, scan existing standard installation folders for installed versions and offer the discovered version `bin`/`bin\1cv8.exe` paths as choices. Missing `C:\Program Files\1cv8` or `C:\Program Files (x86)\1cv8` folders are normal; skip them without error. Do not offer the common `C:\Program Files\1cv8` root as a version. Ask for a custom path only when no version is found or the developer chooses manual input.

During initialization, ask only whether development branch infobases should be published to Apache for web-client testing. Store the local answer in `.dev.env` as `WEB_PUBLISH_BY_DEFAULT=true|false`; do not store it in committed project JSON. If publishing is enabled, run `detect-apache` and save detected local Apache values to `.dev.env`. If Apache is missing, ask the developer whether to install Apache automatically; after explicit agreement, run `install-apache`, then rerun `detect-apache`/`check-tools`. Do not ask the developer for `webinst.exe`, Apache kind, publication root, URL base, or `httpd.conf` in the ordinary flow.

During initialization, ensure Vanessa Automation is available for executable branch tests. Prefer `install-vanessa-automation`, which downloads the official `vanessa-automation-single` release, stores it under `.agent-1c/tools/vanessa-automation`, and writes `VANESSA_AUTOMATION_EPF`, `VANESSA_AUTOMATION_VERSION`, `VANESSA_FEATURES_PATH`, and `VANESSA_REPORTS_PATH` to local `.dev.env`.

Use the current working directory as the project root. During initialization, show its absolute path and ask the developer to confirm before continuing; do not ask them to enter a project path.

Do not ask whether to configure Codex or Kilo Code. Use the agent surface currently running the workflow; if it cannot be detected, use Codex as the fallback.

For `UPDATE_DEV_BRANCH_BASE`, `REFRESH_DEV_BRANCH`, `EXPORT_DEV_BRANCH_RESULT`, `DUMP_DEV_BRANCH_EXTENSION`, and `CLOSE_DEV_BRANCH`, infer the development branch from the current `itldev/<name>` branch. In worktree mode these actions must run from the branch worktree, not from the main `master` folder. Only ask for or pass `DevBranchName` when the current branch is not a development branch and the action cannot be inferred.

For configuration branches, update the development branch infobase with a generated `-listFile` of changed files under `src/cf`. For extension branches, update the extension from `src/cfe/<safeExtensionName>` with `-Extension <extensionName>`. Do not full-load the entire dump unless the user explicitly asks for a manual recovery path.

For branch verification, use `verify-dev-branch`. It updates the branch base once with `update-dev-branch-base`, then runs Vanessa tests against that already updated branch infobase. Do not use `/deploy-and-test` as the normal ITL verification command because it deploys by loading all files.

For extension branches, the extension name is not collected during branch creation. Collect it only when extension work needs it, save it in branch state with `set-dev-branch-extension`, then use it for dump/update/result commands.

Before running ai_rules_1c infobase-bound commands such as `/update1cbase`, `/deploy-and-test`, `/loadfrom1cbase`, or `/getconfigfiles` inside an `itldev/*` branch, activate the ITL development branch context. The helper does this automatically during lifecycle commands and exposes `activate-dev-branch-context` for manual activation. When on `master`, do not run `/update1cbase` unless the developer explicitly chooses a test infobase; `switch-master` and standalone `sync-master` clear the active development branch context.

Never store passwords in Git, `AGENTS.md`, `USER-RULES.md`, or committed JSON. Store secrets only in local `.dev.env` or process environment variables.

Read and write `.dev.env`, `.agent-1c/project.json`, `.agent-1c/tools.json`, and development branch state JSON as UTF-8. Preserve Cyrillic paths and usernames exactly.

Treat `.agent-1c/dev-branches/*.json` as local runtime state. It is ignored by Git because it contains local paths, worktree paths, 1C launcher metadata, verification status, result paths, and unverified override history.

Do not edit installer-managed `AGENTS.md` directly. Put project-specific workflow notes in `USER-RULES.md` or `.agent-1c/`.

Before creating worktrees, legacy branch switching, copying bases, dumping configuration files, or running 1C Designer, check the working tree and stop on unexpected uncommitted changes.

For file infobases, verify that the directory exists and contains `1Cv8.1CD` before launching 1C Designer. Do not let 1C open the interactive "create new infobase" dialog during this workflow.

All development branch changes load into the copied development branch infobase. Never load them directly into the source infobase.

For `/itl-result` and `/itl-close`, create `<artifact>.manifest.json` next to the exported CF/CFE. The manifest must include schema version, artifact SHA256, operation, branch metadata, master/development commits, verification status/report/log, latest 1C log path, publication URL, manual import note, and whether an unverified override was used.

During initialization, ask whether the source infobase is connected to a 1C configuration repository and store the answer as `SOURCE_USES_REPOSITORY=true|false`. If it is not connected, do not ask for repository path/user/password.

When invoking 1C Designer against the source infobase, pass repository connection arguments (`/ConfigurationRepositoryF`, `/ConfigurationRepositoryN`, `/ConfigurationRepositoryP`) only when `sourceUsesRepository=true`. This applies to source synchronization and source configuration dumps. Do not pass repository connection arguments in manual source mode or when working with the copied development branch infobase.

When unlinking the development branch copy from the 1C configuration repository, do it only when `sourceUsesRepository=true` and do not pass repository credentials or repository address. The unbind operation is local to the copy. If `sourceUsesRepository=false`, skip unbind.

After creating a development branch infobase copy, add it to the user's 1C launcher list `%APPDATA%\1C\1CEStart\ibases.v8i` under `/ITL/<project-root-name>`. Use UTF-8 with BOM for that file, create a timestamped backup before changes, and avoid duplicate launcher entries by matching the saved launcher ID or `Connect` string.

If any 1C command, Git command, or publication command fails, stop the workflow and report the log path.

Run 1C Designer operations strictly sequentially. The helper must wait for each `1cv8.exe` process to exit before starting the next Designer command against the same infobase.

When launching native Windows executables such as `1cv8.exe` through `Start-Process`, pass `-ArgumentList` as one joined and correctly quoted native command-line string, never as a PowerShell array. Paths with spaces break when native quoting is skipped and can make 1C Designer exit with code 1 or hang behind `-WindowStyle Hidden`. Prefer the helper's `Join-NativeCommandLineArguments`/`Invoke-NativeProcessAndWait` pattern, or the `&` call operator for simple calls.

Record current industrial compromises without enforcing them: ideal result/close gating would require fresh passed Vanessa, review, and test report, but the current workflow only warns and requires explicit unverified confirmation; ideal dependency management would use a lock file for `ai_rules_1c`, Vanessa Automation, and SHA256 hashes, but the current workflow uses latest versions and logs archive SHA256 where downloads happen; parallel independent development lines should use separate `itldev/*` branches/worktrees, while one development branch may remain long-lived and contain several sequential tasks.

## Script Usage

From the project root:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action help
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action init-project -InitMode wizard
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action install-apache
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action install-vanessa-automation
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action new-dev-branch -DevBranchName "order-discounts"
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action new-dev-branch -DevBranchName "order-discounts" -OfferOpenAgent
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action new-dev-branch -DevBranchName "order-discounts" -UseCurrentWorktree
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action new-extension-dev-branch -DevBranchName "bonus-extension"
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action set-dev-branch-extension -ExtensionName "BonusExtension"
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action dump-dev-branch-extension
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action activate-dev-branch-context
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action update-dev-branch-base
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action run-dev-branch-tests
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action refresh-dev-branch
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action export-dev-branch-result
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action close-dev-branch
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action switch-master
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action switch-dev-branch -DevBranchName "order-discounts"
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action list-dev-branches
```

The script is a helper, not a substitute for judgment. If project topology is unusual, adapt conservatively and document the deviation in the final report.
