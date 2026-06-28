# 1C Agent Workflow Reference

This file is the source of truth for the 1C lifecycle skill. It is written for an agent, not for end-user documentation.

## User-Facing Menu

When the user asks for help or the requested action is unclear, show this menu:

```text
Available 1C workflow actions:
1. Initialize project: check tools, create a local Git project, sync master from a source infobase connected to 1C storage, and install project rules.
2. Start feature: create a feature branch, copy the source infobase, unbind the copy from storage, optionally publish it to Apache.
3. Load feature: load changed current branch config files into the feature infobase.
4. Refresh feature: sync master from 1C storage, merge master into the feature branch, and update the feature infobase.
5. Export feature CF: export CF from the current feature branch without refreshing master.
6. Sync master: refresh source infobase from 1C storage and update master dump.
7. Finish feature: refresh master, merge master into the feature branch, update the feature infobase, export final CF, then switch to master.
8. List features: show features in development and the current feature.
9. Switch branches: switch to master or to a saved feature branch.
```

For Kilo Code, project slash wrappers can expose these as `/1c`, `/1c-init`, `/1c-start`, `/1c-load`, `/1c-refresh`, `/1c-cf`, `/1c-sync`, `/1c-finish`, `/1c-features`, `/1c-master`, and `/1c-feature`.

For Codex, the skill can be chosen from `/skills` or invoked as `$1c-workflow`; enabled skills also appear in the app slash list when supported by the surface.

## State Files

Create and maintain:

- `.agent-1c/project.json`: non-secret project settings.
- `.agent-1c/tools.json`: configurable software checks and install suggestions.
- `.agent-1c/features/<safe-feature-name>.json`: feature branch state.
- `.dev.env`: local secrets and machine-specific values; never commit it.
- `.agents/skills/1c-workflow/`: shared Agent Skill used by Codex and Kilo Code.
- `.kilo/commands/`: optional Kilo Code slash command wrappers.

Never store passwords in committed files.

All workflow state files and `.dev.env` must be UTF-8. Preserve Cyrillic usernames, infobase paths, and repository paths exactly as the developer entered them.

## Project Config Shape

Use this as `.agent-1c/project.json`:

```json
{
  "schemaVersion": 1,
  "masterBranch": "master",
  "exportPath": "src/cf",
  "artifactsPath": "build/cf",
  "logsPath": "logs/1c",
  "platformPath": "",
  "infoBaseKind": "file",
  "sourceInfoBasePath": "",
  "sourceServerName": "",
  "sourceInfoBaseName": "",
  "repositoryPath": "",
  "featureInfoBaseRoot": ".agent-1c/infobases/features",
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
  }
}
```

Values in `.dev.env` override or supplement JSON for local/secrets:

```dotenv
PLATFORM_PATH=C:\Program Files\1cv8\8.3.xx.xxxx\bin\1cv8.exe
INFOBASE_KIND=file
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
# Optional override. By default feature infobase copies are stored under .agent-1c\infobases\features and ignored by Git.
FEATURE_INFOBASE_ROOT=
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
```

## Tools Manifest

Create `.agent-1c/tools.json` from `templates/tools.json`. The helper reads install suggestions from this file and only offers commands; it must not install software without explicit user confirmation.

Default checks:

- `git`: check `git --version`; offer `winget install --id Git.Git -e`.
- `1c-platform`: check `PLATFORM_PATH` or `project.platformPath`; when missing/invalid, scan installed versions under existing standard folders such as `C:\Program Files\1cv8` and `C:\Program Files (x86)\1cv8` and offer the discovered `...\bin` or `...\bin\1cv8.exe` paths before manual input. Either standard folder may be absent; skip missing folders without error. Do not offer the common root `C:\Program Files\1cv8` as a version.
- `apache-webinst`: check only when web publication is enabled/requested. If `WEBINST_PATH` is empty, use `webinst.exe` found next to the selected `1cv8.exe`; detect Apache settings from installed httpd. If Apache is not detected, offer `install-apache` only after explicit developer confirmation.

## Required Questions

Ask only for values that are missing from `.agent-1c/project.json`, `.agent-1c/tools.json`, `.dev.env`, or the current prompt.

Interactive question style:

- Ask unrelated setup values one value at a time.
- Ask source infobase and configuration repository values after the source infobase kind is known.
- If the chat surface supports several structured fields/questions in one prompt, use one grouped form with separate short questions.
- If structured grouped prompts are not available, ask the same values sequentially, one question at a time.
- Never ask the developer to enter 6 or 7 lines into one free-form text answer; Enter may submit the first line in Codex/Kilo Code.
- Never ask for a `KEY=value` block.
- Never require variable names in grouped answers.
- Never show one large setup question that lists all missing project variables; grouping is allowed only for the source infobase and configuration repository values.
- Do not make the developer type variable names such as `PLATFORM_PATH`, `FEATURE_INFOBASE_ROOT`, `SOURCE_INFOBASE_PATH`, `SOURCE_SERVER_NAME`, or `REPOSITORY_PATH`.
- Use human labels in questions, for example: "Выберите версию платформы 1С", "Введите адрес хранилища конфигурации".
- For `file/server` choices, ask a normal choice question first; then ask only the grouped values relevant to that choice.
- In password lines of the grouped questionnaire, exact values `нет` and `-` mean an empty password. Compare these markers case-insensitively after trimming whitespace. Do not store the marker text as a password.
- When invoking 1C, omit the infobase `/P` option when the infobase password is empty. For repository login, always pass `/ConfigurationRepositoryP`; when the repository password is empty, pass it as a quoted empty native argument (`""`) so 1C does not open an interactive repository login dialog and the next option is not shifted into the password position.

For project initialization:

- Do not ask for project root. Use the agent's current working directory as the project root, show its absolute path to the developer, and ask for confirmation before initialization.
- 1C platform executable path (`1cv8.exe`): before asking for manual input, search installed versions under existing `C:\Program Files\1cv8` and `C:\Program Files (x86)\1cv8` folders. If a standard folder is absent, skip it silently. If one or more versions are found, ask the developer to choose a version and use its `bin\1cv8.exe` path. A manually entered version `bin` folder is acceptable; the helper resolves it to `bin\1cv8.exe`. Ask for a custom full path only when no version is found or the developer chooses manual input.
- Source infobase kind: `file` or `server`.
- For a file infobase, ask one grouped form or sequential set with exactly 6 separate values: source infobase directory, infobase user, infobase password or `нет`/`-`, configuration repository path/address, configuration repository user, configuration repository password or `нет`/`-`.
- For a server infobase, ask one grouped form or sequential set with exactly 7 separate values: 1C server name, source infobase name, infobase user, infobase password or `нет`/`-`, configuration repository path/address, configuration repository user, configuration repository password or `нет`/`-`. Build the connection string as `Srvr="<server>";Ref="<base>";`.
- Validate the collected questionnaire value count before running 1C. If only one value is received from an attempted multi-line answer or the count is otherwise wrong, repeat the collection as a grouped prompt or as sequential single-value questions. After parsing, summarize the values without passwords and ask for confirmation.
- Directory for feature infobase copies: do not ask by default. Use `.agent-1c/infobases/features` inside the project and ignore `.agent-1c/infobases/` in Git. Ask only if the developer explicitly wants a custom location.
- Apache web-client testing: ask only whether new feature infobases should be published to Apache by default. Store the answer locally in `.dev.env` as `WEB_PUBLISH_BY_DEFAULT=true|false`, never in committed project JSON.
- If Apache publishing is enabled, run `detect-apache` and save detected local values to `.dev.env`. Do not ask for `webinst.exe`, Apache kind, publication root, URL base, or `httpd.conf` in the ordinary initialization flow. If Apache is not detected, ask whether to install it automatically. On "yes", run `install-apache`, then rerun `detect-apache`/`check-tools`; on "no", offer only to disable publication or stop initialization until Apache is configured manually.
- Do not ask whether the project is for Codex or Kilo Code. Configure the current agent surface; when it cannot be detected, use Codex as the fallback.

For starting a feature:

- Feature name.
- Feature branch if not `feature/<safe-feature-name>`.
- Feature infobase path if not derived from `featureInfoBaseRoot`.
- Whether to publish to Apache only when the project was not configured during initialization or the developer wants a one-off override.
- If publishing is requested and Apache settings are missing, run `detect-apache`; if Apache is missing, ask whether to run `install-apache`; do not ask for Apache paths in the ordinary workflow.

For finishing a feature:

- Feature name if the state file cannot be inferred from the current branch.
- Confirmation that the developer has tested the feature and the Git tree is clean.

## Preflight

Before destructive or stateful actions:

1. Run `CHECK_TOOLS` during project initialization.
2. Verify `git` is available before Git operations.
3. Verify `1cv8.exe` exists before 1C Designer operations.
4. Use default `featureInfoBaseRoot` `.agent-1c/infobases/features` when no override is configured.
5. Verify the source file infobase has `1Cv8.1CD` when `infoBaseKind` is `file`; stop before launching 1C Designer if the file is missing.
6. Verify source server name and infobase name are set when `infoBaseKind` is `server`, unless legacy `sourceInfoBasePath` is explicitly configured.
7. Verify the Git worktree is clean before switching branches.
8. Verify `src/cf` resolves inside the project root before dumping config files.
9. Create `logsPath`, `artifactsPath`, and `.agent-1c/features`.
10. Ensure `.dev.env`, `*.cf`, `*.dt`, and logs are ignored by Git.
11. Run 1C Designer operations strictly sequentially. The helper must wait for the previous `1cv8.exe` process to exit before starting the next Designer command against the same infobase.
12. Pass repository connection arguments on every 1C Designer launch against the source infobase connected to storage. Do not pass repository connection arguments for feature infobases after they are unbound from storage.

## Git Rules

- If `.git` is absent during initialization, create a local Git repository.
- If the repository has no commits yet, treat the current HEAD as an unborn branch. Set/keep HEAD on `master` without running `git checkout -b master` over an existing unborn branch.
- Do not ask for, create, or configure a Git remote during initialization.
- Do not pull automatically during simple branch switching.
- Require a clean worktree before branch switching, feature refresh, feature CF export, or feature finish.
- `src/cf` is tracked project content. During source dumps, stage and commit only `src/cf`; do not include unrelated staged files in dump commits.
- Force-add `src/cf` during source dump commits so broad ignore rules such as `src/` cannot hide the standard configuration dump.

## CHECK_TOOLS

Goal: verify the local machine is ready and provide install suggestions without installing automatically.

1. Read `.agent-1c/tools.json` when present.
2. Check required tools: Git, 1C platform, and optional Apache/webinst.
   - For 1C platform, list discovered versions from standard `1cv8` folders when `PLATFORM_PATH` is missing or invalid.
3. If web publication is enabled/requested through `WEB_PUBLISH_BY_DEFAULT=true`, `project.web.publishByDefault=true`, or `-PublishToApache`, check Apache/webinst settings too. Apache detection uses `APACHE_HTTPD_CONF_PATH`, Windows services, `httpd.exe` in `PATH`, and standard folders such as `C:\Apache24`.
4. Report `[OK]` and `[MISSING]` lines.
5. If required software is missing during `INIT_PROJECT`, stop after showing suggested install/setup commands. When the missing component is Apache/httpd and publication is enabled, the preferred suggestion is `install-apache` after explicit developer confirmation.

## INSTALL_APACHE

Goal: install a local Apache/httpd for 1C web publication when the developer enabled Apache publishing and confirmed automatic installation.

1. Never run this action without explicit developer confirmation.
2. First run `detect-apache`; if Apache is already detected, save detected values to `.dev.env` and continue.
3. Download the official Apache Lounge zip. Prefer the URL reported by `winget show ApacheLounge.httpd`; if `winget install ApacheLounge.httpd` fails because of a stale hash, this is not a blocker.
4. Log the actual SHA256 of the downloaded archive. Do not hide hash mismatch warnings, but do not use stale winget metadata as the only blocker for an official Apache Lounge archive.
5. Unpack Apache to `C:\Apache24`. If that directory exists and does not look like an Apache installation, stop without overwriting it.
6. Ensure Microsoft Visual C++ Redistributable 2015-2022 x64 is installed.
7. Configure `conf\httpd.conf`: set `SRVROOT`, choose port 80 when free, otherwise the first free port from 8080..8090, and set `ServerName localhost:<port>`.
8. Register and start the `Apache24` service. If administrator privileges are required, the helper should launch an elevated PowerShell process or print the exact command to run as Administrator.
9. Rerun Apache detection, save `WEB_PUBLISH_BY_DEFAULT`, `WEBINST_PATH`, `APACHE_KIND`, `APACHE_HTTPD_CONF_PATH`, `WEB_PUBLICATION_ROOT`, and `WEB_PUBLICATION_URL_BASE` to `.dev.env` when available.
10. Resume the interrupted init/check-tools flow.

## INIT_PROJECT

Goal: create the baseline project state.

1. Show the current working directory as project root and confirm the developer wants to initialize there.
2. Collect missing parameters. Do not ask for `featureInfoBaseRoot` during normal initialization; use `.agent-1c/infobases/features`.
   - For the platform path, first offer discovered installed 1C versions; do not make the developer type `C:\Program Files\1cv8\...\bin\1cv8.exe` when it can be selected.
   - Ask whether feature infobases should be published to Apache for web-client testing. If no, write `WEB_PUBLISH_BY_DEFAULT=false` and do not ask Apache paths. If yes, write `WEB_PUBLISH_BY_DEFAULT=true`, run `detect-apache`, and save detected local Apache settings to `.dev.env`. If Apache is not detected, ask whether to run `install-apache`; after success, rerun `detect-apache`/`check-tools`.
3. Create `.agent-1c/project.json`, `.agent-1c/tools.json`, and `.dev.env` if missing. Write them as UTF-8.
4. Run `CHECK_TOOLS`; stop on missing required tools after showing suggestions.
5. Initialize local Git if needed.
6. Checkout or create `master`.
7. Update the source infobase from 1C configuration repository storage.
8. Dump configuration files into `src/cf`.
   - Because the source infobase is connected to storage, pass `/ConfigurationRepositoryF`, `/ConfigurationRepositoryN`, and `/ConfigurationRepositoryP` to this dump command too.
   - First dump: if `src/cf` is empty, run a full dump.
   - Next dumps: if `src/cf/ConfigDumpInfo.xml` exists, run incremental dump with `-update -force`.
   - Unsafe state: if `src/cf` is not empty and `ConfigDumpInfo.xml` is missing, stop and ask the user to clean the folder or restore `ConfigDumpInfo.xml`.
9. Verify `src/cf/ConfigDumpInfo.xml` exists after the dump. During initial project creation, commit only `src/cf` to `master`, then verify `HEAD:src/cf/ConfigDumpInfo.xml` exists. Stop if Git sees no dump files to commit or the file is missing from `HEAD`.
10. Install `ai_rules_1c` per project from `https://github.com/comol/ai_rules_1c`, using the current agent target (`codex`, `kilocode`, or fallback `codex`). Invoke its installer with named parameters: `-Command init -ProjectRoot <project> -Source <rulesDir> -Tools <tools> -AssumeYes`.
11. Install this workflow skill into `.agents/skills/1c-workflow`.
12. If the current agent is Kilo Code, install slash wrappers into `.kilo/commands`.
13. Add project workflow notes to `USER-RULES.md`, not to `AGENTS.md`.
14. Commit rules and workflow files when there are changes.

## START_FEATURE

Goal: create a branch and isolated feature infobase.

1. Check the Git worktree is clean.
2. Checkout `master` and pull with `--ff-only` when a remote/upstream exists.
3. Create `feature/<safe-feature-name>` unless the user supplied a branch.
4. Copy the source infobase.
   - File base: recursive directory copy under `featureInfoBaseRoot` unless a specific path is supplied.
   - Server base: run the configured `serverBaseCopyScript`; do not invent server copy commands.
5. Unbind the feature copy from 1C configuration repository storage without repository parameters.
6. Optionally publish the feature copy to Apache through `webinst`.
7. Save feature state to `.agent-1c/features/<safe-feature-name>.json`.
8. Report branch, feature infobase path, and publication URL if any.

## LOAD_FEATURE

Goal: apply current branch files to the feature infobase.

1. Find feature state from `FeatureName` or current branch. In normal use, do not require a feature name when already on a `feature/<name>` branch.
2. Build a UTF-8 list file in `logs/1c` from Git changes under `src/cf` relative to feature state `lastLoadedCommit`; include untracked files under `src/cf`.
3. If no changed files are found, skip `/LoadConfigFromFiles` and report that the feature infobase already matches the current branch config files.
4. Run `/LoadConfigFromFiles <src/cf> -listFile <listFile> -Format Hierarchical /UpdateDBCfg -WarningsAsErrors`.
5. Do not pass `-updateConfigDumpInfo`.
6. After success, update feature state: `lastLoadedCommit`, `lastLoadAt`, `lastLoadListFile`, and latest 1C log path.
7. Stop on errors and report the 1C log path.

## REFRESH_FEATURE

Goal: update a feature with the latest configuration from storage without finishing it.

1. Find feature state from `FeatureName` or current branch. In normal use, do not require a feature name when already on a `feature/<name>` branch.
2. Require a clean Git worktree.
3. Run `SYNC_MASTER`.
4. Checkout the feature branch.
5. Merge `master` into the feature branch.
6. If conflicts occur, stop and resolve them in config files before continuing.
7. Load only changed merged files into the feature infobase using the same partial load rules as `LOAD_FEATURE`.
8. Update feature state with refresh timestamp, load metadata, and latest 1C log path.

## EXPORT_FEATURE_CF

Goal: create a CF from the current feature branch before full completion.

1. Find feature state from `FeatureName` or current branch. In normal use, do not require a feature name when already on a `feature/<name>` branch.
2. Require a clean Git worktree.
3. Checkout the feature branch if needed.
4. Load only changed current branch files into the feature infobase using the same partial load rules as `LOAD_FEATURE`.
5. Export CF into `artifactsPath`.
6. Do not refresh `master` or merge from storage unless the user explicitly requested `REFRESH_FEATURE` first.
7. Update feature state with load metadata, the CF path, timestamp, and latest 1C log path.

## SYNC_MASTER

Goal: refresh `master` from storage.

1. Check the Git worktree is clean.
2. Checkout `master`.
3. Pull with `--ff-only` when a remote/upstream exists.
4. Update source infobase from storage.
5. Dump configuration files into `src/cf` using the same full/incremental rules as `INIT_PROJECT`.
   - Pass repository connection arguments to both source infobase Designer launches.
6. Commit changes with `sync: refresh 1C configuration from repository`.

## FINISH_FEATURE

Goal: prepare a tested feature for manual import into the storage-connected source base.

1. Confirm the developer has finished testing.
2. Check the Git worktree is clean.
3. Run `SYNC_MASTER`.
4. Checkout the feature branch.
5. Merge `master` into the feature branch.
6. If conflicts occur, stop and resolve them in config files before continuing.
7. Load only changed merged files into the feature infobase using the same partial load rules as `LOAD_FEATURE`.
8. Export final CF from the feature infobase into `artifactsPath`.
9. Report branch, master commit, feature commit, CF path, latest 1C log path, and publication URL.
10. Checkout `master` before completing.

Do not load the feature directly into the source infobase connected to storage.

## LIST_FEATURES

Goal: show features currently in development and the active feature.

1. Read `.agent-1c/features/*.json`.
2. Show only feature states without `finishedAt`.
3. Show current Git branch and current feature; if current branch is `master`, report current feature as `none`.
4. Mark the feature whose saved branch matches the current Git branch.
5. For each active feature, show feature name, branch, feature infobase path, publication URL if any, created timestamp, last load timestamp, and last refresh timestamp.

## SWITCH_MASTER

Goal: switch Git to the fixed `master` branch.

1. Require a clean Git worktree.
2. Checkout `master`.
3. Report current commit.
4. Do not pull and do not load files into 1C automatically.

## SWITCH_FEATURE

Goal: switch Git to a saved feature branch.

1. Find feature state from `FeatureName` or current branch.
2. Require a clean Git worktree.
3. Checkout the saved feature branch.
4. Report current commit, feature infobase path, and publication URL if any.
5. Do not load files into 1C automatically.

## Failure Rules

Stop immediately when:

- Required parameters are missing and cannot be inferred safely.
- Required software is missing during initialization.
- Source infobase cannot be opened.
- Repository credentials are missing for source synchronization.
- Git worktree is dirty before branch switching.
- Feature infobase target already exists.
- Feature copy cannot be unbound from storage.
- 1C Designer returns a non-zero exit code.
- CF export fails.
- Apache publication is requested but `webinst.exe` or Apache/httpd is missing and the developer declined automatic install or manual setup.

## Troubleshooting

- "Ошибка блокировки информационной базы для конфигурирования" during initialization means another Designer process still holds the infobase lock. This can be a manually opened Configurator or a previous `1cv8.exe` process that has not exited yet. Close the manual Configurator; the workflow helper must wait between its own consecutive Designer launches.
