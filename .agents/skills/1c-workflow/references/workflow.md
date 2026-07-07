# 1C Agent Workflow Reference

This file is the source of truth for the 1C lifecycle skill. It is written for an agent, not for end-user documentation.

## User-Facing Menu

When the user asks for help or the requested action is unclear, show this menu:

```text
Available 1C workflow actions:
1. New configuration branch: create an itldev/<name> branch worktree for configuration changes.
2. New extension branch: create an itldev/<name> branch worktree for extension development; set the extension name later.
3. MCP: setup, start, update, or inspect vibecoding1c MCP servers for the current project/worktree scope.
4. Status: show current Git branch, active development branch, infobase, publication URL, verification status, MCP status, and latest result.
5. Update base: update configuration files or extension files in the branch infobase.
6. Verify: update the branch base, then run Vanessa Automation scenarios.
7. Refresh: sync master from storage or the current source infobase state, merge master into the branch, and update the branch base configuration.
8. Result: export CF for configuration branches or CFE for extension branches.
9. Close: refresh master, merge master into the branch, export final CF/CFE result, and mark the branch closed.
10. Switch: show/open a saved development branch worktree or switch a legacy branch.
```

For Kilo Code, project slash wrappers expose the short command surface: `/itl`, `/itl-new-config-branch`, `/itl-new-extension-branch`, `/itl-vibecoding1c-mcp`, `/itl-status`, `/itl-update-base`, `/itl-verify`, `/itl-refresh`, `/itl-result`, `/itl-close`, and `/itl-switch`. These wrappers call the PowerShell helper directly and should open detailed references only after helper failure or on user request. The direct `/itl-init-project` wrapper exists for explicit bootstrap use, but it is not part of the beginner menu after initialization. Extension helper wrappers (`/itl-set-dev-branch-extension`, `/itl-dump-dev-branch-extension`), the advanced `/itl-vanessa-mcp` wrapper, and the maintenance `/itl-update-rules` and `/itl-update-workflow` wrappers remain available when directly needed, but are intentionally not shown in the beginner menu.

For Codex, the detailed skill can be chosen from `/skills` or invoked as `$1c-workflow`; routine helper-first commands can use `$1c-workflow-fast`. Enabled skills also appear in the app slash list when supported by the surface.

## State Files

Create and maintain:

- `.agent-1c/project.json`: non-secret project settings.
- `.agent-1c/tools.json`: configurable software checks and install suggestions.
- `.agent-1c/dependency-lock.json`: committed dependency lock manifest for the ITL workflow package, `ai_rules_1c`, Vanessa Automation, and downloadable archive URLs/SHA256. Default mode is `fresh`; `locked` mode uses only pinned values.
- `.agent-1c/dev-branches/<safe-dev-branch-name>.json`: local development branch runtime state, including branch-local Vanessa verify test port and Vanessa MCP port/PID/URL when used; ignored by Git.
- `.agent-1c/mcp/state.json`: local project/worktree MCP runtime mirror; ignored by Git.
- `.agent-1c/mcp/vibecoding1c-selection.json`: local per-developer remote/local MCP selection; ignored by Git.
- `.dev.env`: local secrets and machine-specific values; never commit it.
- `.agents/skills/1c-workflow/`: shared detailed Agent Skill used by Codex and Kilo Code.
- `.agents/skills/1c-workflow-fast/`: compact Agent Skill for routine helper-first lifecycle actions.
- `.kilo/commands/`: optional Kilo Code slash command wrappers.
- `.codex/config.toml`: project/worktree Codex MCP layer written by `vibecoding1c-mcp-write-client-config`; ignored by Git.
- `.kilo/kilo.json` or `.kilo/kilo.jsonc`: local Kilo Code runtime state; ignored by Git.

Never store passwords in committed files.

All workflow state files and `.dev.env` must be UTF-8. Preserve Cyrillic usernames, infobase paths, and repository paths exactly as the developer entered them. `.agent-1c/dev-branches/*.json` is local state because it contains machine-specific paths, worktree paths, launcher metadata, verification status, result paths, and unverified override history. `.agent-1c/mcp/`, `.codex/config.toml`, and `.kilo/kilo.json*` are also local runtime state; do not commit them.

Current policy notes:

- `verificationPolicy=warn` is the default and requires explicit unverified confirmation before result export or branch close when verification is not fresh passed. `verificationPolicy=block` forbids result export and branch close until `/itl-verify` is fresh passed.
- `dependencyMode=fresh` is the default and records resolved dependency revisions/hashes into `.agent-1c/dependency-lock.json`. `dependencyMode=locked` uses only pinned lock values and fails on missing pins or hash mismatch.
- Parallel independent development lines should use separate `itldev/*` branches/worktrees. One development branch may remain long-lived and contain several sequential tasks.

## Project Config Shape

Use this as `.agent-1c/project.json`:

```json
{
  "schemaVersion": 1,
  "masterBranch": "master",
  "exportPath": "src/cf",
  "extensionsPath": "src/cfe",
  "artifactsPath": "build/result",
  "testsPath": "tests/features",
  "testResultsPath": "build/test-results/vanessa",
  "logsPath": "logs/1c",
  "platformPath": "",
  "infoBaseKind": "file",
  "sourceUsesRepository": true,
  "sourceInfoBasePath": "",
  "sourceServerName": "",
  "sourceInfoBaseName": "",
  "repositoryPath": "",
  "dependencyMode": "fresh",
  "verificationPolicy": "warn",
  "devBranchInfoBaseRoot": ".agent-1c/infobases/dev-branches",
  "devBranchWorktreeRoot": "",
  "serverBaseCopyScript": "",
  "aiRules": {
    "repo": "https://github.com/comol/ai_rules_1c.git",
    "tools": ""
  },
  "web": {
    "publishByDefault": false,
    "webInstPath": "",
    "apacheKind": "apache24",
    "apacheHttpdConfPath": "",
    "publicationRoot": "",
    "publicationUrlBase": "http://localhost"
  },
  "vanessaAutomation": {
    "installRoot": ".agent-1c/tools/vanessa-automation",
    "epfPath": "",
    "version": "",
    "featuresPath": "tests/features",
    "reportsPath": "build/test-results/vanessa"
  }
}
```

Values in `.dev.env` override or supplement JSON for local/secrets:

```dotenv
PLATFORM_PATH=C:\Program Files\1cv8\8.3.xx.xxxx\bin\1cv8.exe
INFOBASE_KIND=file
SOURCE_USES_REPOSITORY=true
SOURCE_INFOBASE_PATH=C:\1c\bases\source
SOURCE_SERVER_NAME=
SOURCE_INFOBASE_NAME=
IB_USER=
# Empty value means the infobase password is not set.
IB_PASSWORD=
REPOSITORY_PATH=\\server\repo
REPOSITORY_USER=
# Empty value means the repository password is not set.
REPOSITORY_PASSWORD=
DEPENDENCY_MODE=fresh
VERIFICATION_POLICY=warn
# Optional override. By default development branch infobase copies are stored under .agent-1c\infobases\dev-branches and ignored by Git.
DEV_BRANCH_INFOBASE_ROOT=
# Optional override. By default development branch Git worktrees are created next to the project as <project-folder>-worktrees\<branch>.
DEV_BRANCH_WORKTREE_ROOT=
WEB_PUBLISH_BY_DEFAULT=false
# Optional override. By default webinst.exe is resolved next to PLATFORM_PATH.
WEBINST_PATH=
APACHE_KIND=apache24
# Optional overrides. By default Apache settings are detected from installed httpd.
APACHE_HTTPD_CONF_PATH=
WEB_PUBLICATION_ROOT=
WEB_PUBLICATION_URL_BASE=
# Optional install override. Normal automatic install uses C:\Apache24.
APACHE_INSTALL_ROOT=
# Vanessa Automation is installed locally during init and is required for executable branch tests.
VANESSA_AUTOMATION_EPF=
VANESSA_AUTOMATION_VERSION=
VANESSA_FEATURES_PATH=tests/features
VANESSA_REPORTS_PATH=build/test-results/vanessa
VANESSA_TEST_PORT_RANGE=48051..48150
VANESSA_TEST_PORT=
VANESSA_TEST_FOREIGN_WAIT_MODE=warn
VANESSA_TEST_FOREIGN_QUIET_SECONDS=60
VANESSA_TEST_FOREIGN_WAIT_TIMEOUT_SECONDS=600
VANESSA_TEST_TIMEOUT_SECONDS=1800
VANESSA_TEST_CLIENT_STARTUP_TIMEOUT_SECONDS=300
VANESSA_TEST_WINDOW_SEARCH_TIMEOUT_SECONDS=60
VANESSA_EVENT_LOG_LEVELS=Error
VANESSA_EVENT_LOG_CLOCK_SKEW_SECONDS=5
VANESSA_EVENT_LOG_READER=auto
VANESSA_MCP_INSTALL_ROOT=.agent-1c/tools/vanessa-mcp
VANESSA_MCP_PORT_RANGE=9874..9973
VANESSA_MCP_PORT=
VANESSA_MCP_URL=
VIBECODING1C_MCP_DISTRIBUTION_REPO=http://gitlabserv01.itland.local/root/MCP-vibecoding1c.git
VIBECODING1C_MCP_DISTRIBUTION_PATH=
VIBECODING1C_MCP_REGISTRY_REPO=http://gitlabserv01.itland.local/root/MCP-vibecoding1c-registry.git
VIBECODING1C_MCP_REGISTRY_PATH=
PATH_METADATA=
PATH_CODE=
PATH_BASES=
USE_GPU=
```

## Tools Manifest

Create `.agent-1c/tools.json` from `templates/tools.json`. The helper reads install suggestions from this file and only offers commands; it must not install software without explicit user confirmation.

Default checks:

- `git`: check `git --version`; offer `winget install --id Git.Git -e`.
- `1c-platform`: check `PLATFORM_PATH` or `project.platformPath`; when missing/invalid, scan installed versions under existing standard folders such as `C:\Program Files\1cv8` and `C:\Program Files (x86)\1cv8` and offer the discovered `...\bin` or `...\bin\1cv8.exe` paths before manual input. Either standard folder may be absent; skip missing folders without error. Do not offer the common root `C:\Program Files\1cv8` as a version.
- `apache-webinst`: check only when web publication is enabled/requested. If `WEBINST_PATH` is empty, use `webinst.exe` found next to the selected `1cv8.exe`; detect Apache settings from installed httpd. If Apache is not detected, offer `install-apache` only after explicit developer confirmation.
- `vanessa-automation`: check `VANESSA_AUTOMATION_EPF` or `.agent-1c/tools/vanessa-automation`; offer `install-vanessa-automation` after explicit developer confirmation.

## Required Questions

In `configured` mode, use values already present in `.agent-1c/project.json`, `.agent-1c/tools.json`, `.dev.env`, or the current prompt. In `wizard` mode, collect the local setup answers and overwrite `.dev.env` only after the developer confirms the summary.

Interactive question style:

- Ask unrelated setup values one value at a time.
- Ask source infobase values after the source infobase kind is known; ask configuration repository values only when the source infobase is connected to storage.
- If the chat surface supports several structured fields/questions in one prompt, use one grouped form with separate short questions.
- If structured grouped prompts are not available, ask the same values sequentially, one question at a time.
- Never ask the developer to enter 6 or 7 lines into one free-form text answer; Enter may submit the first line in Codex/Kilo Code.
- Never ask for a `KEY=value` block.
- Never require variable names in grouped answers.
- Never show one large setup question that lists all missing project variables; grouping is allowed only for the source infobase and configuration repository values.
- Do not make the developer type variable names such as `PLATFORM_PATH`, `DEV_BRANCH_INFOBASE_ROOT`, `DEV_BRANCH_WORKTREE_ROOT`, `SOURCE_INFOBASE_PATH`, `SOURCE_SERVER_NAME`, or `REPOSITORY_PATH`.
- Use human labels in questions, for example: "Выберите версию платформы 1С", "Введите адрес хранилища конфигурации".
- For `file/server` choices, ask a normal choice question first; then ask only the grouped values relevant to that choice.
- In password lines of the grouped questionnaire, exact values `нет` and `-` mean an empty password. Compare these markers case-insensitively after trimming whitespace. Do not store the marker text as a password.
- When invoking 1C, omit the infobase `/P` option when the infobase password is empty. For repository login, pass `/ConfigurationRepositoryP` only when `sourceUsesRepository=true`; when the repository password is empty, pass it as a quoted empty native argument (`""`) so 1C does not open an interactive repository login dialog and the next option is not shifted into the password position.

For project initialization:

- Do not ask for project root. Use the agent's current working directory as the project root, show its absolute path to the developer, and ask for confirmation before initialization.
- 1C platform executable path (`1cv8.exe`): before asking for manual input, search installed versions under existing `C:\Program Files\1cv8` and `C:\Program Files (x86)\1cv8` folders. If a standard folder is absent, skip it silently. If one or more versions are found, ask the developer to choose a version and use its `bin\1cv8.exe` path. A manually entered version `bin` folder is acceptable; the helper resolves it to `bin\1cv8.exe`. Ask for a custom full path only when no version is found or the developer chooses manual input.
- Source infobase kind: `file` or `server`.
- Ask whether the source infobase is connected to a 1C configuration repository. Store the answer as `SOURCE_USES_REPOSITORY=true|false`.
- For a file infobase connected to storage, ask one grouped form or sequential set with exactly 6 separate values: source infobase directory, infobase user, infobase password or `нет`/`-`, configuration repository path/address, configuration repository user, configuration repository password or `нет`/`-`.
- For a file infobase without storage, ask exactly 3 values: source infobase directory, infobase user, infobase password or `нет`/`-`.
- For a server infobase connected to storage, ask one grouped form or sequential set with exactly 7 separate values: 1C server name, source infobase name, infobase user, infobase password or `нет`/`-`, configuration repository path/address, configuration repository user, configuration repository password or `нет`/`-`.
- For a server infobase without storage, ask exactly 4 values: 1C server name, source infobase name, infobase user, infobase password or `нет`/`-`.
- For a server infobase, build the connection string as `Srvr="<server>";Ref="<base>";`.
- Validate the collected questionnaire value count before running 1C. If only one value is received from an attempted multi-line answer or the count is otherwise wrong, repeat the collection as a grouped prompt or as sequential single-value questions. After parsing, summarize the values without passwords and ask for confirmation.
- Directory for development branch worktrees: do not ask by default. Use a sibling `<project-folder>-worktrees/<branch>` folder. Ask only if the developer explicitly wants a custom location.
- Directory for development branch infobase copies: do not ask by default. Use `.agent-1c/infobases/dev-branches` inside the active branch worktree and ignore `.agent-1c/infobases/` in Git. Ask only if the developer explicitly wants a custom location.
- Apache web-client testing: ask only whether new development branch infobases should be published to Apache by default. Store the answer locally in `.dev.env` as `WEB_PUBLISH_BY_DEFAULT=true|false`, never in committed project JSON.
- If Apache publishing is enabled, run `detect-apache` and save detected local values to `.dev.env`. Do not ask for `webinst.exe`, Apache kind, publication root, URL base, or `httpd.conf` in the ordinary initialization flow. If Apache is not detected, ask whether to install it automatically. On "yes", run `install-apache`, then rerun `detect-apache`/`check-tools`; on "no", offer only to disable publication or stop initialization until Apache is configured manually.
- Dependency mode: ask whether initialization should use fresh dependencies or locked dependencies. Default to fresh and store `DEPENDENCY_MODE=fresh`. If locked is chosen, use `.agent-1c/dependency-lock.json` and stop when a required pin or hash is absent.
- Ensure Vanessa Automation is installed for executable branch tests. If no EPF is found, ask whether to install it automatically. On "yes", run `install-vanessa-automation`; on "no", stop initialization with the manual command.
- Do not ask whether the project is for Codex or Kilo Code. Configure the current agent surface; when it cannot be detected, use Codex as the fallback.

For creating a development branch:

- Development branch name.
- Git branch if not `itldev/<safe-dev-branch-name>`.
- Development branch worktree path if not derived from `devBranchWorktreeRoot`.
- Development branch infobase path if not derived from `devBranchInfoBaseRoot`.
- Whether to publish to Apache only when the project was not configured during initialization or the developer wants a one-off override.
- If publishing is requested and Apache settings are missing, run `detect-apache`; if Apache is missing, ask whether to run `install-apache`; do not ask for Apache paths in the ordinary workflow.

For closing a development branch:

- Development branch name if the state file cannot be inferred from the current branch.
- Confirmation that the developer has tested the current work and the Git tree is clean.

## Preflight

Before destructive or stateful actions:

1. Run `CHECK_TOOLS` during project initialization.
2. Verify `git` is available before Git operations.
3. Verify `1cv8.exe` exists before 1C Designer operations.
4. Use default `devBranchInfoBaseRoot` `.agent-1c/infobases/dev-branches` when no override is configured.
5. Verify the source file infobase has `1Cv8.1CD` when `infoBaseKind` is `file`; stop before launching 1C Designer if the file is missing.
6. Verify source server name and infobase name are set when `infoBaseKind` is `server`, unless legacy `sourceInfoBasePath` is explicitly configured.
7. Verify the Git worktree is clean before creating worktrees, legacy branch switching, refresh, result export, or close.
8. Verify `src/cf` resolves inside the project root before dumping config files.
9. Create `logsPath`, `artifactsPath`, and `.agent-1c/dev-branches`.
10. Ensure `.dev.env`, `.agent-1c/dev-branches/`, `*.cf`, `*.dt`, and logs are ignored by Git.
11. Run 1C Designer operations strictly sequentially. The helper must wait for the previous `1cv8.exe` process to exit before starting the next Designer command against the same infobase.
12. Pass repository connection arguments on every 1C Designer launch against the source infobase only when `sourceUsesRepository=true`. Do not pass repository connection arguments in manual source mode or for development branch infobases.
13. When launching native Windows executables such as `1cv8.exe` with `Start-Process`, pass `-ArgumentList` as one joined and correctly quoted native command-line string, never as a PowerShell array. Prefer `Join-NativeCommandLineArguments` from `agent-1c.ps1` or the `&` call operator for simple calls.

## Git Rules

- If `.git` is absent during initialization, create a local Git repository.
- If the repository has no commits yet, treat the current HEAD as an unborn branch. Set/keep HEAD on `master` without running `git checkout -b master` over an existing unborn branch.
- Do not ask for, create, or configure a Git remote during initialization.
- Do not pull automatically during simple branch switching.
- Create new development branches in sibling Git worktrees by default. Use `-UseCurrentWorktree` only for the legacy single-folder checkout mode.
- Require a clean worktree before worktree creation, legacy branch switching, development branch refresh, development branch result export, or development branch close.
- `src/cf` is tracked project content. During source dumps, stage and commit only `src/cf`; do not include unrelated staged files in dump commits.
- Force-add `src/cf` during source dump commits so broad ignore rules such as `src/` cannot hide the standard configuration dump.

## CHECK_TOOLS

Goal: verify the local machine is ready and provide install suggestions without installing automatically.

1. Read `.agent-1c/tools.json` when present.
2. Check required tools: Git, 1C platform, Vanessa Automation, and optional Apache/webinst.
   - For 1C platform, list discovered versions from standard `1cv8` folders when `PLATFORM_PATH` is missing or invalid.
3. If web publication is enabled/requested through `WEB_PUBLISH_BY_DEFAULT=true`, `project.web.publishByDefault=true`, or `-PublishToApache`, check Apache/webinst settings too. Apache detection uses `APACHE_HTTPD_CONF_PATH`, Windows services, `httpd.exe` in `PATH`, and standard folders such as `C:\Apache24`.
4. Report `[OK]` and `[MISSING]` lines.
5. If required software is missing during `INIT_PROJECT`, stop after showing suggested install/setup commands. When the missing component is Apache/httpd and publication is enabled, the preferred suggestion is `install-apache` after explicit developer confirmation.

## INSTALL_VANESSA_AUTOMATION

Goal: install the standard executable test tool for ITL development branches.

1. Never run this action without explicit developer confirmation or a direct install command.
2. If `VANESSA_AUTOMATION_EPF` already points to an existing EPF, save it back to `.dev.env` and finish.
3. In `dependencyMode=fresh`, download the `vanessa-automation-single.*.zip` asset from the latest `Pr-Mex/vanessa-automation` GitHub release and update `.agent-1c/dependency-lock.json` with version, URL, source, and SHA256.
4. In `dependencyMode=locked`, use `dependencies.vanessaAutomation.url` and verify `sha256` when provided. Stop on missing URL or SHA256 mismatch.
5. Unpack it under `.agent-1c/tools/vanessa-automation`.
6. Save `VANESSA_AUTOMATION_EPF`, `VANESSA_AUTOMATION_VERSION`, `VANESSA_FEATURES_PATH=tests/features`, and `VANESSA_REPORTS_PATH=build/test-results/vanessa` to `.dev.env`.
7. Ensure `tests/features` and `build/test-results/vanessa` directories exist. The downloaded tool and reports are local and ignored by Git.

## VIBECODING1C_MCP_SETUP / VIBECODING1C_MCP_SELECT / VIBECODING1C_MCP_REFRESH_REGISTRY / VIBECODING1C_MCP_UPDATE / VIBECODING1C_MCP_STATUS / VIBECODING1C_MCP_START / VIBECODING1C_MCP_STOP

Goal: make vibecoding1c MCP usable on weak developer machines by preferring remote LAN endpoints while preserving local overrides.

1. `/itl-vibecoding1c-mcp` runs `vibecoding1c-mcp-setup` by default. The setup action applies the saved selection; if `.agent-1c/mcp/vibecoding1c-selection.json` is missing or incomplete, it runs selection first. Use `vibecoding1c-mcp-setup -Force` to force a new selection before applying it.
2. Remote is the default provider. The helper clones or fast-forwards the endpoint registry from `VIBECODING1C_MCP_REGISTRY_REPO` into `%LOCALAPPDATA%\ITL\MCP\vibecoding1c\registry`, unless `VIBECODING1C_MCP_REGISTRY_PATH` points to a prepared checkout.
3. Config-specific remote vibecoding1c MCP always requires explicit `configId`; ask even when the registry currently has one configuration. Store the per-developer choice in ignored `.agent-1c/mcp/vibecoding1c-selection.json`.
4. Use `vibecoding1c-mcp-select` for explicit per-server `remote|local`, remote `configId`/`hostId`, and local `project|branch` scope. The selection flow shows matching remote hosts/endpoints with URL, health, freshness, configuration, model, and timestamps. Vanessa MCP is managed separately by the Vanessa MCP actions and is always branch-local.
5. Local MCP clones or fast-forwards the private GitLab distribution from `VIBECODING1C_MCP_DISTRIBUTION_REPO`, rotates license keys locally, ensures the local embedding model when needed, starts Docker/compose containers, and writes Codex/Kilo client config.
6. The distribution may provide `vibecoding1c-mcp.manifest.json`. If it is absent, the helper uses the built-in vibecoding1c manifest for `docs`, `templates`, `syntax`, `codechecker`, `ssl`, `code`, and `graph`.
7. Registry/runtime server names stay unique, for example `itl-1c-docs`, `itl-pm5corp-code`, or a branch-local `itl-<project>-<branch>-code`. Client config uses upstream `ai_rules_1c` canonical MCP names from `clientNames.aiRules1c` when present, with a fallback mapping by logical server id.
8. Local host ports are allocated under `%LOCALAPPDATA%\ITL\MCP\vibecoding1c\ports.json` with a lock file. Vendor ports `8000`, `8002`, `8003`, `8004`, `8006`, `8007`, and `8008` remain container-internal only. Host ranges are `18000..18099` for global, `18100..18499` for project, `18500..18999` for branch, and `19000..19049` for local model fallback.
9. Do not ask users to paste license keys into chat. Keys come from the private distribution `config.env` or local config; the project repo only stores ignored runtime state.
10. `vibecoding1c-mcp-write-client-config` removes only config entries marked `managedBy = vibecoding1c-mcp` and `family = vibecoding1c`; do not delete unrelated or External MCP config.
11. `vibecoding1c-mcp-stop` stops selected local containers. For remote endpoints it only disconnects local client config; host stop is done by `vibecoding1c-mcp-host/install-vibecoding1c-mcp-host.ps1`.
12. `vibecoding1c-mcp-status`, `/itl-status`, and `list-dev-branches` show active vibecoding1c MCP names, URLs, provider, configId, health, indexed time, and freshness (`fresh`, `stale`, `remote-shared`, `unknown`, `indexing`).

## INSTALL_VANESSA_MCP / START_VANESSA_MCP / STOP_VANESSA_MCP / VANESSA_MCP_STATUS

Goal: use the official Vanessa Automation MCP server for scenario authoring/debugging in one isolated development branch.

1. These actions must run from the active `itldev/*` worktree. Do not run a shared Vanessa MCP from `master` for several branches.
2. `install-vanessa-mcp` ensures Vanessa Automation EPF is available, downloads `client_mcp.cfe` from the latest `1c-neurofish/onec-client-mcp-devkit` release and `VAExtension.*.cfe` from the latest `Pr-Mex/vanessa-automation` release, logs SHA256, stores them under `.agent-1c/tools/vanessa-mcp`, and loads them into the current branch infobase with Designer `/LoadCfg <cfe> -Extension <name> /UpdateDBCfg`.
3. `start-vanessa-mcp` auto-installs missing MCP dependencies, allocates a branch-local port from `VANESSA_MCP_PORT_RANGE` or `9874..9973`, saves `VANESSA_MCP_PORT` and `VANESSA_MCP_URL` to the current worktree `.dev.env`, then starts 1C `ENTERPRISE /TESTMANAGER /Execute <vanessa.epf> /C "runMcp;mcpPort=<port>"` in the background.
4. Port allocation reuses the saved branch port when possible, skips ports reserved by other development branch states, skips ports occupied by unrelated processes, and stops with a clear error if the range is exhausted.
5. Save `vanessaMcpPort`, `vanessaMcpUrl`, `vanessaMcpPid`, `vanessaMcpStartedAt`, `vanessaMcpLogPath`, downloaded CFE paths, versions, SHA256 hashes, and install logs in `.agent-1c/dev-branches/<branch>.json`.
6. `vanessa-mcp-status`, `status`, and `list-dev-branches` show MCP PID/port/URL/log when configured. `stop-vanessa-mcp` stops only the saved PID for the current branch.
7. Print MCP client snippets with a branch-specific server name such as `VanessaAutomation-<safeBranchName>`. `start-vanessa-mcp` also writes the branch-local Vanessa MCP entry to `.kilo/kilo.json` with `managedBy = "vanessa-mcp"` and `family = "vanessa"`. Already running Kilo Code sessions may not reload MCP config automatically; if the server is not visible after start, reload or restart Kilo Code. Do not write Vanessa MCP into global Codex, VS Code, Cline, Roo, or Continue configs automatically.
8. MCP is for authoring, form inspection, step search, recording, and debugging. The final `VERIFY_DEV_BRANCH` gate remains the packet `StartFeaturePlayer` run because it produces repeatable reports and verification state.
9. Do not use MCP as the final verification runner. UI scenarios must be verified by `RUN_DEV_BRANCH_TESTS` in the real `TESTMANAGER -> TESTCLIENT` topology.

## EXTERNAL_MCP

External MCP servers are future or user-provided MCP servers outside Vanessa MCP and vibecoding1c MCP. The workflow does not start, stop, publish, or rewrite them; preserve any client config entry not marked as `managedBy = vibecoding1c-mcp` with `family = vibecoding1c`.

## INSTALL_APACHE

Goal: install a local Apache/httpd for 1C web publication when the developer enabled Apache publishing and confirmed automatic installation.

1. Never run this action without explicit developer confirmation.
2. First run `detect-apache`; if Apache is already detected, save detected values to `.dev.env` and continue.
3. In `dependencyMode=fresh`, download the official Apache Lounge zip. Prefer the URL reported by `winget show ApacheLounge.httpd`; if `winget install ApacheLounge.httpd` fails because of a stale hash, this is not a blocker. Update `.agent-1c/dependency-lock.json` with URL, source, and actual SHA256.
4. In `dependencyMode=locked`, use `dependencies.apache.url` and verify `sha256` when provided. Stop on missing URL or SHA256 mismatch. Do not use stale winget metadata as the only blocker in fresh mode.
5. Unpack Apache to `C:\Apache24`. If that directory exists and does not look like an Apache installation, stop without overwriting it.
6. Ensure Microsoft Visual C++ Redistributable 2015-2022 x64 is installed.
7. Configure `conf\httpd.conf`: set `SRVROOT`, choose port 80 when free, otherwise the first free port from 8080..8090, and set `ServerName localhost:<port>`.
8. Register and start the `Apache24` service. If administrator privileges are required, the helper should launch an elevated PowerShell process or print the exact command to run as Administrator.
9. Rerun Apache detection, save `WEB_PUBLISH_BY_DEFAULT`, `WEBINST_PATH`, `APACHE_KIND`, `APACHE_HTTPD_CONF_PATH`, `WEB_PUBLICATION_ROOT`, and `WEB_PUBLICATION_URL_BASE` to `.dev.env` when available.
10. Resume the interrupted init/check-tools flow.

## INIT_PROJECT

Goal: create the baseline project state.

1. First run the monitored helper script wizard: `run-agent-1c-window.ps1 -- -Action init-project -InitMode wizard`. Do not collect the initialization questionnaire in chat or Kilo Questions before this first helper attempt.
2. The monitored launcher opens the wizard in an external PowerShell window, writes `.agent-1c/runs/<run>/status.json` and `console.log`, and lets the agent detect completion without asking the developer to close the wizard manually. Run the monitored command in the foreground and wait for it to exit; do not wrap it in a background PowerShell launch, do not keep the launched PowerShell session open after the helper exits, and do not call `agent-1c.ps1 -Action init-project -InitMode wizard` directly as the default agent path. Do not run a separate `Test-Path` preflight before this command because the launcher validates the helper path itself; a raw PowerShell probe can return `CLIXML` progress records that are not meaningful command output. If the agent shell tool exposes a timeout, use a positive long timeout such as `1800000` ms for the interactive wizard and never set `timeout: 0`. Use `-KeepWindowOnFailure` only for manual debugging when the developer explicitly wants the external PowerShell window to stay open after a failure. The wizard shows the current working directory as project root and confirms the developer wants to initialize there.
3. The wizard collects missing parameters. Do not ask for `devBranchInfoBaseRoot` during normal initialization; use `.agent-1c/infobases/dev-branches`.
   - For the platform path, first offer discovered installed 1C versions; do not make the developer type `C:\Program Files\1cv8\...\bin\1cv8.exe` when it can be selected.
   - Ask whether development branch infobases should be published to Apache for web-client testing. If no, write `WEB_PUBLISH_BY_DEFAULT=false` and do not ask Apache paths. If yes, write `WEB_PUBLISH_BY_DEFAULT=true`, run `detect-apache`, and save detected local Apache settings to `.dev.env`. If Apache is not detected, ask whether to run `install-apache`; after success, rerun `detect-apache`/`check-tools`.
   - Ask whether to use fresh dependency versions or locked versions. Default to fresh. Write `DEPENDENCY_MODE=fresh|locked`; locked mode requires a populated `.agent-1c/dependency-lock.json`.
   - Check Vanessa Automation. If missing, ask whether to install it automatically and run `install-vanessa-automation` after confirmation.
4. If the wizard fails because terminal input is unavailable, do not collect the questionnaire in chat and do not continue the lifecycle manually. Use the monitored wizard command, or use JSON mode only when the developer explicitly requested non-interactive initialization or an answers file already exists.
5. For non-interactive automation, pass `-InitMode json -InitAnswersPath <answers.json>` with the same values the wizard would collect. If required fields are missing, stop before launching 1C.
6. Create `.agent-1c/project.json`, `.agent-1c/tools.json`, `.agent-1c/dependency-lock.json`, and `.dev.env` if missing. Write them as UTF-8.
7. Run `CHECK_TOOLS`; stop on missing required tools after showing suggestions.
8. Initialize local Git if needed.
9. Checkout or create `master`.
10. If `sourceUsesRepository=true`, update the source infobase from 1C configuration repository storage. If `false`, skip repository update and use the source infobase exactly as it is.
11. Dump configuration files into `src/cf`.
   - If `sourceUsesRepository=true`, pass `/ConfigurationRepositoryF`, `/ConfigurationRepositoryN`, and `/ConfigurationRepositoryP` to this dump command too.
   - If `sourceUsesRepository=false`, do not ask for or pass repository settings. The developer must update the source infobase manually before syncing master when fresh external changes are needed.
   - First dump: if `src/cf` is empty, run a full dump.
   - Next dumps: if `src/cf/ConfigDumpInfo.xml` exists, run incremental dump with `-update -force`.
   - Unsafe state: if `src/cf` is not empty and `ConfigDumpInfo.xml` is missing, stop and ask the user to clean the folder or restore `ConfigDumpInfo.xml`.
12. Verify `src/cf/ConfigDumpInfo.xml` exists after the dump. During initial project creation, commit only `src/cf` to `master`, then verify `HEAD:src/cf/ConfigDumpInfo.xml` exists. Stop if Git sees no dump files to commit or the file is missing from `HEAD`.
13. Install `ai_rules_1c` using the current agent target (`codex`, `kilocode`, or fallback `codex`). In fresh mode, use the configured repo and record the resolved commit in `.agent-1c/dependency-lock.json`; in locked mode, use `dependencies.aiRules1c.ref` or `commit` and stop if neither is set. Invoke its installer with named parameters: `-Command init -ProjectRoot <project> -Source <rulesDir> -Tools <tools> -AssumeYes`.
14. Remove default upstream `ai_rules_1c` MCP client entries from ignored Codex/Kilo config. ITL vibecoding1c MCP owns client config; preserve External MCP and entries marked for other managers.
15. Install this workflow skill into `.agents/skills/1c-workflow` and the fast routine skill into `.agents/skills/1c-workflow-fast`.
16. If the current agent is Kilo Code, install slash wrappers into `.kilo/commands`.
17. Keep the ITL overlay in `USER-RULES.md`. Do not append to upstream-managed `AGENTS.md` when the `ai_rules_1c` installer already made it point to `USER-RULES.md`; add the short bridge only as a fallback for projects without such a root `AGENTS.md`.
18. Add detailed project workflow notes to `USER-RULES.md`, not to `AGENTS.md`.
19. Commit rules and workflow files when there are changes.

## UPDATE_WORKFLOW

Goal: refresh the installed ITL workflow package in an already initialized project without rerunning `init-project`.

Helper action: `update-workflow`. Kilo wrapper: `/itl-update-workflow`.

1. Run only from the `master` worktree. If invoked from `itldev/*`, stop and print the saved main worktree path when available.
2. Require a clean tracked Git worktree, while still ignoring local runtime state such as `.dev.env`, `.agent-1c/mcp/`, `.codex/config.toml`, and `.kilo/kilo.json*`.
3. Resolve the package source from `ITL_WORKFLOW_SOURCE_PATH`, or clone/update `ITL_WORKFLOW_REPO` and `ITL_WORKFLOW_REF`. Defaults are `https://github.com/xmentosx/1c-agent-workflow.git` and `master`.
4. Copy only managed workflow files: `.agents/skills/1c-workflow*`, `.kilo/commands/itl*.md`, `templates/`, `README.md`, `AGENT-INSTALL.md`, `DEVELOPER-GUIDE.ru.md`, `DEV-BRANCH-DEVELOPMENT.ru.md`, and `VANESSA-TESTS-GUIDE.ru.md`.
5. Never overwrite local project/runtime state: `.dev.env`, `.agent-1c/dev-branches/`, `.agent-1c/mcp/`, `.codex/config.toml`, `.kilo/kilo.json*`, existing `.agent-1c/project.json`, or existing `.agent-1c/tools.json`.
6. Record `workflowPackage.repo/ref/commit/source/updatedAt` in `.agent-1c/dependency-lock.json` and reapply the managed ITL `USER-RULES.md` block.
7. Run `UPDATE_AI_RULES` unless `-SkipAiRules` is passed.
8. Do not start or stop MCP servers and do not update active development branches automatically. Print the follow-up commands for `vibecoding1c-mcp-update`, `vibecoding1c-mcp-setup`, branch merge or `/itl-refresh`, and branch-local Vanessa MCP reinstall when used.
9. Do not create a commit automatically; leave tracked changes for review.

## UPDATE_AI_RULES

Goal: refresh upstream `ai_rules_1c` while preserving the ITL overlay above it.

Helper action: `update-ai-rules`. Kilo wrapper: `/itl-update-rules`.

1. Clone or update the configured `ai_rules_1c` repo under `%TEMP%\ai_rules_1c`.
2. In `dependencyMode=fresh`, checkout the remote origin HEAD. In `dependencyMode=locked`, checkout `dependencies.aiRules1c.commit` or `ref` and stop when neither is set.
3. If `.ai-rules.json` exists, run the upstream installer with `-Command update -ProjectRoot <project> -Source <rulesDir> -AssumeYes`; if it is missing, run `init` with the configured agent tools.
4. Let the upstream installer preserve files marked `userModified`. Use `-Force` only after explicit developer intent to overwrite local edits with the shipped upstream version.
5. Remove default upstream `ai_rules_1c` MCP client entries from `.codex/config.toml` and `.kilo/kilo.json`; keep `vibecoding1c-mcp` managed entries and External MCP entries.
6. Reapply the ITL overlay in `USER-RULES.md` from `templates/USER-RULES.append.md`.
7. Do not normally append to `AGENTS.md`; upstream `AGENTS.md` already loads `USER-RULES.md`. Add the short ITL bridge only when no `USER-RULES.md` reference exists.
8. Record the resolved `ai_rules_1c` commit in `.agent-1c/dependency-lock.json`.

## NEW_DEV_BRANCH / NEW_EXTENSION_DEV_BRANCH

Goal: create a configuration or extension development branch as an isolated worktree plus isolated development branch infobase.

1. Check the current Git worktree is clean.
2. Checkout/sync `master` in the main project worktree and pull with `--ff-only` when a remote/upstream exists.
3. Create `itldev/<safe-dev-branch-name>` in a sibling worktree under `<project-folder>-worktrees/<safe-dev-branch-name>` unless the user supplied a branch or worktree path.
4. Copy `.dev.env` into the new worktree.
5. Copy the source infobase into the new worktree.
   - File base: recursive directory copy under `devBranchInfoBaseRoot` unless a specific path is supplied.
   - Server base: run the configured `serverBaseCopyScript`; do not invent server copy commands.
6. If `sourceUsesRepository=true`, unbind the development branch copy from 1C configuration repository storage without repository parameters. If `false`, skip unbind.
7. Register the development branch infobase in `%APPDATA%\1C\1CEStart\ibases.v8i` under folder `/ITL/<project-root-name>` with the launcher entry name equal to the development branch name.
8. Optionally publish the development branch copy to Apache through `webinst`; when published, best-effort install branch-local `1c-data-mcp` from `MCP_1C_Distr.zip`, patch the `APA_Инструменты` XML tool name from `vcvalidatequery` to `validatequery`, expose `/hs/mcp`, and connect the branch-scoped MCP endpoint.
9. Save development branch state to `.agent-1c/dev-branches/<safe-dev-branch-name>.json` inside the worktree, including `createdWithWorktree`, `worktreePath`, `mainWorktreePath`, launcher registration metadata, `devBranchKind`, and Data MCP status when publication was requested.
10. Activate the development branch context in the worktree `.dev.env` for ai_rules_1c infobase-bound commands. For extension branches with no extension name yet, clear `INFOBASE_PATH` and tell the developer to run `set-dev-branch-extension` before `/update1cbase`.
11. Report branch, worktree path, development branch infobase path, launcher folder/name, and publication URL if any.
12. Print the Russian instruction that the current folder stayed on `master`, the new worktree path, and that the developer should open a separate Codex/Kilo/IDE window there. If `-OfferOpenAgent` is passed, try a best-effort open, for example via `code -n <worktree-path>`.

For extension branches, do not ask for `extensionName` and do not create the extension during branch creation. The extension is created later in the copied branch infobase during development.

## SET_DEV_BRANCH_EXTENSION / DUMP_DEV_BRANCH_EXTENSION

Goal: attach an extension name to the current extension branch and dump extension files from the branch infobase.

1. `SET_DEV_BRANCH_EXTENSION` works only in an extension branch and saves `extensionName`, `safeExtensionName`, and `extensionExportPath=src/cfe/<safeExtensionName>` in branch state.
2. If the extension name is already set, require explicit overwrite confirmation before changing it.
3. `DUMP_DEV_BRANCH_EXTENSION` works only in an extension branch and reads the extension name from state.
4. Dump extension files through `/DumpConfigToFiles <src/cfe/<name>> -Extension <extensionName> -Format Hierarchical`.
5. Use `-update -force` when `ConfigDumpInfo.xml` already exists.
6. If the extension does not exist in the branch infobase yet, stop and tell the developer to create it in that copied base first.

## ACTIVATE_DEV_BRANCH_CONTEXT

Goal: make ai_rules_1c infobase-bound commands use the current ITL development branch infobase.

1. Read current branch state from `.agent-1c/dev-branches/<name>.json`.
2. For configuration branches, write `.dev.env`: `INFOBASE_KIND`, `INFOBASE_PATH=<devBranchInfoBasePath>`, `EXPORT_PATH=src/cf`, empty `EXTENSION_NAME`, and `INFOBASE_PUBLISH_URL` from branch state when present.
3. For extension branches, require `extensionName` in state and write `EXPORT_PATH=src/cfe/<safeExtensionName>` plus `EXTENSION_NAME=<extensionName>`.
4. Do not modify source/repository settings or credentials.
5. Add diagnostic keys `ITL_ACTIVE_DEV_BRANCH`, `ITL_ACTIVE_DEV_BRANCH_KIND`, and `ITL_ACTIVE_CONTEXT_UPDATED_AT`.
6. When switching to `master`, closing a worktree branch, or running standalone `sync-master`, clear `INFOBASE_PATH`, `INFOBASE_PUBLISH_URL`, `EXPORT_PATH`, `EXTENSION_NAME`, and active ITL diagnostics so `/update1cbase` cannot accidentally target the source base.

## UPDATE_DEV_BRANCH_BASE

Goal: update the current development branch infobase from current branch files.

1. Find development branch state from `DevBranchName` or current branch. In normal use, do not require a name when already on an `itldev/<name>` branch.
2. For worktree-created branches, require the command to run from the branch worktree, not the main `master` folder.
3. Activate the development branch context in `.dev.env`.
4. For configuration branches, build a UTF-8 list file in `logs/1c` from Git changes under `src/cf`.
5. For extension branches, require `extensionName` in state and build the list file from `src/cfe/<safeExtensionName>`.
6. If no changed files are found, skip `/LoadConfigFromFiles` and report that the development branch infobase already matches current branch files.
7. For configuration branches, run `/LoadConfigFromFiles <src/cf> -listFile <listFile> -Format Hierarchical /UpdateDBCfg`.
8. For extension branches, run `/LoadConfigFromFiles <src/cfe/<name>> -Extension <extensionName> -listFile <listFile> -Format Hierarchical /UpdateDBCfg`.
9. When files were actually loaded, copy both bundled auto-update EPFs from `.agents/skills/1c-workflow/tools/auto-update` to ignored `.agent-1c/tools/auto-update`, then launch only `ДляАвтоматическогоОбновленияИБ.epf` in 1C Enterprise user mode with `/Execute <epf>`. This applies update handlers and answers the legal-copy update prompt non-interactively. Do not launch the deferred-handlers EPF in the current workflow.
10. Do not pass `-updateConfigDumpInfo`.
11. Update separate configuration/extension base update fields in branch state, save `lastEnterpriseAutoUpdateAt` and `lastEnterpriseAutoUpdateLogPath` when the post-update launch ran, and report the 1C log paths.
12. If previous verification no longer matches the current commit/base state, mark verification as stale.

## STATUS

Goal: show the current ITL state without changing Git or 1C.

1. Show current Git branch, commit, and clean/dirty worktree state.
2. If the current branch is `itldev/<name>`, show development branch name, kind, worktree path, main worktree path, extension name when relevant, infobase path, publication URL, last base update, last refresh, verification status, latest report/log, and latest CF/CFE result paths.
3. Show Vanessa verify test port/status when configured.
4. Show Vanessa MCP status when the current branch has branch-local MCP state.
5. Show active vibecoding1c MCP names, embedding model, and stale indexes for the current scope.
6. If the current branch is `master`, show that no development branch is active and summarize active development worktrees when state files are discoverable.

## RUN_DEV_BRANCH_TESTS

Goal: run executable Vanessa Automation checks against the current development branch infobase without loading configuration files again.

1. Find development branch state from `DevBranchName` or current branch. In normal use, do not require a name when already on an `itldev/<name>` branch.
2. For worktree-created branches, require the command to run from the branch worktree.
3. Activate the development branch context in `.dev.env`.
4. Require Vanessa Automation EPF. If missing, stop and tell the developer to run `install-vanessa-automation`.
5. Use `VANESSA_FEATURES_PATH` or `tests/features` as the feature directory. Stop clearly if no `.feature` files exist.
6. Create a run directory under `VANESSA_REPORTS_PATH` or `build/test-results/vanessa`.
7. Allocate a branch-local Vanessa test port from `VANESSA_TEST_PORT_RANGE` or `48051..48150`, store it as `vanessaTestPort` in branch state, and write `VANESSA_TEST_PORT` to the current worktree `.dev.env`.
8. Before launch, inspect active `1cv8.exe` / `1cv8c.exe` processes. If a foreign worktree has an active Vanessa `TESTMANAGER`, `TESTCLIENT`, `StartFeaturePlayer`, or `VAParams` process, default `VANESSA_TEST_FOREIGN_WAIT_MODE=warn` prints diagnostics and continues because verify uses branch-local ports, branch-local infobases, and branch-local report directories. Do not wait for a parallel branch by default, and never stop a foreign branch process. If `VANESSA_TEST_FOREIGN_WAIT_MODE=wait`, wait for the configured quiet period/timeout as a conservative local mode.
8a. Ensure the branch event-log baseline exists before launch. New branches create `.agent-1c/event-log-baselines/<branch>.json` during branch initialization; old branches may create a backfill baseline before the first test run.
9. Generate `VAParams.json` in the run directory with the required `ВыполнениеСценариев`, `КлиентТестирования`, JUnit, and status export fields. The test client entry must point to the current branch infobase, use the same local user/password, use thin client on `localhost`, and use the branch-local test port.
10. Launch `1cv8.exe ENTERPRISE` against the branch infobase with `/TESTMANAGER -TPort <vanessaTestPort> /Execute <vanessa.epf>` and `/CStartFeaturePlayer;VAParams=<absolute-json-path>`.
11. Do not put embedded quotes around the `VAParams=` path; Vanessa treats `VAParams="C:\..."` as `file://"C:\..."` and cannot find the params file.
12. Do not call `/LoadConfigFromFiles`, `/update1cbase`, or `/deploy-and-test`. The branch base must already have been updated by `UPDATE_DEV_BRANCH_BASE`.
13. Save test port, test PID, report paths, latest 1C log path, `lastVerificationStatus`, `lastVerifiedCommit`, `lastVerifiedAt`, `lastVerifiedReportPath`, and `lastVerificationLogPath` in development branch state.
14. Treat the run as passed only when 1C exits successfully and JUnit contains executed tests with no failures/errors. A status file without JUnit is `unknown`, not passed.
15. On non-zero exit, missing JUnit/status/log, or `unknown`, print active 1C process diagnostics first. Stop only this branch's own hung `TESTCLIENT`, matched by current branch infobase/worktree and test port.
16. Also check the branch-local file infobase event log from `devBranchInfoBasePath\1Cv8Log` after Vanessa exits. Directly read 8.3.22+ sequential `.lgf/.lgp`; if that reader cannot parse a valid sequential log, use the bundled external data processor fallback that calls `ВыгрузитьЖурналРегистрации`, honors requested event levels, and writes diagnostic JSON with `errorMessage`/`errorDetails` on failure. Do not use COM objects or `ibcmd.exe`.
17. Verification passes only when 1C exits successfully, JUnit has executed tests with no failures/errors, and no fresh non-baseline `Error` signatures appeared during the test window. Apply `VANESSA_TEST_TIMEOUT_SECONDS` or default 1800 seconds; on timeout, stop only this branch's own `TESTMANAGER`/`TESTCLIENT`.

## VERIFY_DEV_BRANCH

Goal: perform the standard ITL verification cycle without a full configuration load.

1. Run `UPDATE_DEV_BRANCH_BASE`.
2. Run `RUN_DEV_BRANCH_TESTS` through the packet `StartFeaturePlayer` command in `TESTMANAGER -> TESTCLIENT` mode, not MCP and not headless EPF.
3. Treat fresh non-baseline event-log errors as verification failures even when JUnit passed.
4. If Vanessa fails, report the report/log/event-log paths and let the agent follow the auto-fix loop from the development process.

## REFRESH_DEV_BRANCH

Goal: update a development branch with the latest master dump without closing it.

1. Find development branch state from `DevBranchName` or current branch. In normal use, do not require a name when already on an `itldev/<name>` branch.
2. For worktree-created branches, require the command to run from the branch worktree.
3. Require a clean Git worktree.
4. Run `SYNC_MASTER`; when called from a dev worktree, it syncs `master` in the saved main worktree.
5. Ensure the current worktree is on the development branch.
6. Merge `master` into the development branch.
7. If conflicts occur, stop and resolve them in config files before continuing.
8. For configuration branches, update changed merged `src/cf` files in the branch infobase, then run the Enterprise auto-update post-step when files were actually loaded.
9. For extension branches, update only the base configuration from `src/cf`; do not update extension files during refresh.
10. Update development branch state with refresh timestamp, config-base update metadata, and latest 1C log path.

## EXPORT_DEV_BRANCH_RESULT

Goal: create a CF or CFE result from the current development branch without closing it.

1. Find development branch state from `DevBranchName` or current branch. In normal use, do not require a name when already on an `itldev/<name>` branch.
2. For worktree-created branches, require the command to run from the branch worktree.
3. Require a clean Git worktree.
4. Ensure the current worktree is on the development branch.
5. For configuration branches, update `src/cf`, run the Enterprise auto-update post-step when files were actually loaded, and export `.cf` into `artifactsPath`.
6. For extension branches, update `src/cfe/<safeExtensionName>` with `-Extension <extensionName>`, run the Enterprise auto-update post-step when files were actually loaded, and export `.cfe` into `artifactsPath`.
7. Do not refresh `master` or merge fresh source changes unless the user explicitly requested `REFRESH_DEV_BRANCH` first.
8. If verification is missing, failed, stale, or unknown, apply `verificationPolicy`: `warn` requires explicit confirmation or `-AllowUnverifiedResult` before exporting; `block` stops without an override path.
9. Create `<artifact>.manifest.json` next to the exported CF/CFE with schema version, artifact SHA256, operation, branch metadata, master/development commits, verification status/report/log, latest 1C log path, publication URL, manual import note, and unverified override flag.
10. Update development branch state with update metadata, result path, result manifest path, timestamp, latest 1C log path, and unverified override metadata when used.

## SYNC_MASTER

Goal: refresh `master` from storage or from the current source infobase state.

1. If called from a worktree-created development branch, delegate synchronization to the saved main worktree.
2. Check the target master Git worktree is clean.
3. Checkout `master` in the main/legacy worktree.
4. Pull with `--ff-only` when a remote/upstream exists.
5. If `sourceUsesRepository=true`, update source infobase from storage. If `false`, skip repository update and assume the developer already updated the source infobase manually when needed.
6. Dump configuration files into `src/cf` using the same full/incremental rules as `INIT_PROJECT`.
   - Pass repository connection arguments only when `sourceUsesRepository=true`.
7. Commit changes with a message that reflects repository mode or source-infobase mode.

## CLOSE_DEV_BRANCH

Goal: prepare tested current work for manual import into the source base and close the development branch.

1. Confirm the developer has finished testing.
2. For worktree-created branches, require the command to run from the branch worktree.
3. Stop branch-local Vanessa MCP if it is running.
4. Check the Git worktree is clean.
5. Run `SYNC_MASTER`; when called from a dev worktree, it syncs `master` in the saved main worktree.
6. Ensure the current worktree is on the development branch.
7. Merge `master` into the development branch.
8. If conflicts occur, stop and resolve them in config files before continuing.
9. Update merged `src/cf` files in the branch infobase. For extension branches, also update extension files from `src/cfe/<safeExtensionName>` before exporting the result. After each real load, run the Enterprise auto-update post-step.
10. Check whether verification is still fresh after sync/merge/update. If it is missing, failed, stale, or unknown, apply `verificationPolicy`: `warn` requires explicit confirmation or `-AllowUnverifiedClose`; `block` stops without an override path.
11. Export final CF or CFE result from the development branch infobase into `artifactsPath`.
12. Create `<artifact>.manifest.json` next to the exported CF/CFE with schema version, artifact SHA256, operation, branch metadata, master/development commits, verification status/report/log, latest 1C log path, publication URL, manual import note, and unverified override flag.
13. Set `closedAt` in development branch state.
14. Report branch, master commit, development branch commit, result path, result manifest path, latest 1C log path, publication URL, worktree path, and unverified override when used.
15. For worktree-created branches, clear active dev context but do not delete the worktree, copied base, or local state. For legacy branches, checkout `master` before completing.

Do not load development branch changes directly into the source infobase.

## LIST_DEV_BRANCHES

Goal: show active development branches and the current development branch.

1. Read `.agent-1c/dev-branches/*.json` from the current worktree and active paths returned by `git worktree list --porcelain`.
2. Show only development branch states without `closedAt`.
3. Show current Git branch and current development branch; if current branch is `master`, report current development branch as `none`.
4. Mark the development branch whose saved branch matches the current Git branch.
5. For each active development branch, show name, branch, worktree path, main worktree path, development branch infobase path, launcher folder/name, publication URL and Data MCP status if any, Vanessa verify test port/status, Vanessa MCP status when configured, vibecoding1c MCP current-scope status, created timestamp, last base update timestamp, and last refresh timestamp.

## SWITCH_MASTER

Goal: switch Git to the fixed `master` branch in legacy mode or show the main worktree path in worktree mode.

1. Require a clean Git worktree.
2. If the current branch state was created with a separate worktree, clear active dev context and report the saved `mainWorktreePath`; do not checkout `master` over the dev worktree.
3. For legacy branches, checkout `master`.
4. Clear active development branch context in `.dev.env` (`INFOBASE_PATH`, `INFOBASE_PUBLISH_URL`, `EXPORT_PATH`, `EXTENSION_NAME`, and diagnostics).
5. Report current commit or main worktree path.
6. Do not pull and do not load files into 1C automatically.

## SWITCH_DEV_BRANCH

Goal: switch Git to a saved development branch in legacy mode or show/open its worktree path in worktree mode.

1. Find development branch state from `DevBranchName` or current branch.
2. If the state was created with a separate worktree and the current folder is not that worktree, report `worktreePath`, tell the developer to open a separate Codex/Kilo/IDE window there, and optionally try best-effort open when requested.
3. For legacy branches, require a clean Git worktree and checkout the saved development branch.
4. Activate the saved development branch context in `.dev.env` only when running inside the branch worktree or legacy checkout. If it is an extension branch without an extension name yet, clear infobase-bound values and tell the developer to run `set-dev-branch-extension`.
5. Report current commit, development branch infobase path, worktree path, and publication URL if any.
6. Do not load files into 1C automatically.

## Failure Rules

Stop immediately when:

- Required parameters are missing and cannot be inferred safely.
- Required software is missing during initialization.
- Source infobase cannot be opened.
- Repository credentials are missing for source synchronization when `sourceUsesRepository=true`.
- Git worktree is dirty before worktree creation, legacy branch switching, refresh, result, or close.
- Development branch infobase target already exists.
- Development branch copy cannot be unbound from storage when `sourceUsesRepository=true`.
- 1C Designer returns a non-zero exit code.
- CF/CFE result export fails.
- Apache publication is requested but `webinst.exe` or Apache/httpd is missing and the developer declined automatic install or manual setup.
- `/itl-result` or `/itl-close` found missing, failed, stale, or unknown verification and either `verificationPolicy=block` or the developer did not explicitly confirm unverified continuation.

## Troubleshooting

- "Ошибка блокировки информационной базы для конфигурирования" during initialization means another Designer process still holds the infobase lock. This can be a manually opened Configurator or a previous `1cv8.exe` process that has not exited yet. Close the manual Configurator; the workflow helper must wait between its own consecutive Designer launches.
- `1cv8.exe` exits with code 1 or appears to hang with `-WindowStyle Hidden` after a PowerShell launch can mean `Start-Process -ArgumentList` received a PowerShell array. Native Windows executables parse one command-line string; without native quoting, a path such as `C:\My Path\base` is split at the space and 1C Designer receives the wrong arguments. Use `Join-NativeCommandLineArguments` or the `&` call operator.
- If `/itl-result` or `/itl-close` stops because verification is missing, failed, stale, or unknown, run `/itl-verify`. With `verificationPolicy=warn`, an explicit unverified override is allowed when the risk is acceptable; with `verificationPolicy=block`, it is not.
