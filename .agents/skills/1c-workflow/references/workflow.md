# 1C Agent Workflow Reference

This file is the source of truth for the 1C lifecycle skill. It is written for an agent, not for end-user documentation.

## User-Facing Menu

When the user asks for help or the requested action is unclear, show this menu:

```text
Available 1C workflow actions:
1. Initialize project: check tools, create/sync Git master from a source infobase connected to 1C storage, and install project rules.
2. Start feature: create a feature branch, copy the source infobase, unbind the copy from storage, optionally publish it to Apache.
3. Load feature: load current branch config files into the feature infobase.
4. Refresh feature: sync master from 1C storage, merge master into the feature branch, and update the feature infobase.
5. Export feature CF: export CF from the current feature branch without refreshing master.
6. Sync master: refresh source infobase from 1C storage and update master dump.
7. Finish feature: refresh master, merge master into the feature branch, update the feature infobase, export final CF, then switch to master.
8. Switch branches: switch to master or to a saved feature branch.
```

For Kilo Code, project slash wrappers can expose these as `/1c`, `/1c-init`, `/1c-start`, `/1c-load`, `/1c-refresh`, `/1c-cf`, `/1c-sync`, `/1c-finish`, `/1c-master`, and `/1c-feature`.

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

## Project Config Shape

Use this as `.agent-1c/project.json`:

```json
{
  "schemaVersion": 1,
  "gitRemoteUrl": "",
  "masterBranch": "master",
  "exportPath": "src/cf",
  "artifactsPath": "build/cf",
  "logsPath": "logs/1c",
  "platformPath": "",
  "infoBaseKind": "file",
  "sourceInfoBasePath": "",
  "repositoryPath": "",
  "featureInfoBaseRoot": "",
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
GIT_REMOTE_URL=
INFOBASE_KIND=file
SOURCE_INFOBASE_PATH=C:\1c\bases\source
IB_USER=
IB_PASSWORD=
REPOSITORY_PATH=\\server\repo
REPOSITORY_USER=
REPOSITORY_PASSWORD=
FEATURE_INFOBASE_ROOT=C:\1c\bases\features
WEBINST_PATH=C:\Program Files\1cv8\8.3.xx.xxxx\bin\webinst.exe
APACHE_KIND=apache24
APACHE_HTTPD_CONF_PATH=
WEB_PUBLICATION_ROOT=C:\Apache24\htdocs\1c
WEB_PUBLICATION_URL_BASE=http://localhost
```

## Tools Manifest

Create `.agent-1c/tools.json` from `templates/tools.json`. The helper reads install suggestions from this file and only offers commands; it must not install software without explicit user confirmation.

Default checks:

- `git`: check `git --version`; offer `winget install --id Git.Git -e`.
- `1c-platform`: check `PLATFORM_PATH` or `project.platformPath`; manual install suggestion.
- `codex`: check `codex --version` when target includes Codex.
- `kilocode`: check VS Code extension `kilocode.Kilo-Code` with `code --list-extensions`; offer `code --install-extension kilocode.Kilo-Code --pre-release`.
- `apache-webinst`: check `WEBINST_PATH`/`web.webInstPath` only when web publication is enabled/requested.

## Required Questions

Ask only for values that are missing from `.agent-1c/project.json`, `.agent-1c/tools.json`, `.dev.env`, or the current prompt.

For project initialization:

- Project root.
- Git remote URL if the repository is not initialized and a remote is needed.
- 1C platform executable path (`1cv8.exe`).
- Source infobase kind: `file` or `server`.
- Source infobase path: file base directory or server base string.
- 1C infobase user/password if required.
- Configuration repository address/path.
- Configuration repository user/password.
- Export path inside the repository, default `src/cf`.
- Master branch, default `master`.
- Directory for feature infobase copies (`featureInfoBaseRoot` / `FEATURE_INFOBASE_ROOT`).
- Whether to install for Codex, Kilo Code, or both. If unknown, install the common skill and ask before adding Kilo slash commands.

For starting a feature:

- Feature name.
- Feature branch if not `feature/<safe-feature-name>`.
- Feature infobase path if not derived from `featureInfoBaseRoot`.
- Whether to publish to Apache.
- If publishing: `webinst.exe`, Apache kind, publication root, and URL base.

For finishing a feature:

- Feature name if the state file cannot be inferred from the current branch.
- Confirmation that the developer has tested the feature and the Git tree is clean.

## Preflight

Before destructive or stateful actions:

1. Run `CHECK_TOOLS` during project initialization.
2. Verify `git` is available before Git operations.
3. Verify `1cv8.exe` exists before 1C Designer operations.
4. Verify `featureInfoBaseRoot` is set during initialization and before feature creation.
5. Verify the source file infobase has `1Cv8.1CD` when `infoBaseKind` is `file`.
6. Verify the Git worktree is clean before switching branches.
7. Verify export path resolves inside the project root before clearing it.
8. Create `logsPath`, `artifactsPath`, and `.agent-1c/features`.
9. Ensure `.dev.env`, `*.cf`, `*.dt`, and logs are ignored by Git.

## Git Rules

- If `.git` is absent during initialization, create a Git repository.
- If `gitRemoteUrl` or `GIT_REMOTE_URL` is set and `origin` is absent, add `origin`.
- If `origin` exists and differs from the configured remote URL, stop and report the mismatch.
- Do not pull automatically during simple branch switching.
- Require a clean worktree before branch switching, feature refresh, feature CF export, or feature finish.

## CHECK_TOOLS

Goal: verify the local machine is ready and provide install suggestions without installing automatically.

1. Read `.agent-1c/tools.json` when present.
2. Check required tools based on selected target: Codex, Kilo Code, or both.
3. If web publication is enabled/requested, check Apache/webinst settings too.
4. Report `[OK]` and `[MISSING]` lines.
5. If required software is missing during `INIT_PROJECT`, stop after showing suggested install/setup commands.

## INIT_PROJECT

Goal: create the baseline project state.

1. Collect missing parameters, including `featureInfoBaseRoot`.
2. Create `.agent-1c/project.json`, `.agent-1c/tools.json`, and `.dev.env` if missing.
3. Run `CHECK_TOOLS`; stop on missing required tools after showing suggestions.
4. Initialize Git if needed; add `origin` if configured and absent.
5. Checkout or create `master`.
6. Update the source infobase from 1C configuration repository storage.
7. Dump configuration files into `exportPath`.
8. Commit the dump to `master` when there are changes.
9. Install `ai_rules_1c` per project from `https://github.com/comol/ai_rules_1c`.
10. Install this workflow skill into `.agents/skills/1c-workflow`.
11. If Kilo Code is used, install slash wrappers into `.kilo/commands`.
12. Add project workflow notes to `USER-RULES.md`, not to `AGENTS.md`.
13. Commit rules and workflow files when there are changes.

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

1. Find feature state from `FeatureName`, current branch, or the user.
2. Run `/LoadConfigFromFiles` from `exportPath`.
3. Run `/UpdateDBCfg`.
4. Stop on errors and report the 1C log path.

## REFRESH_FEATURE

Goal: update a feature with the latest configuration from storage without finishing it.

1. Find feature state from `FeatureName`, current branch, or the user.
2. Require a clean Git worktree.
3. Run `SYNC_MASTER`.
4. Checkout the feature branch.
5. Merge `master` into the feature branch.
6. If conflicts occur, stop and resolve them in config files before continuing.
7. Load the merged files into the feature infobase.
8. Update feature state with refresh timestamp and latest 1C log path.

## EXPORT_FEATURE_CF

Goal: create a CF from the current feature branch before full completion.

1. Find feature state from `FeatureName`, current branch, or the user.
2. Require a clean Git worktree.
3. Checkout the feature branch if needed.
4. Load current branch files into the feature infobase.
5. Export CF into `artifactsPath`.
6. Do not refresh `master` or merge from storage unless the user explicitly requested `REFRESH_FEATURE` first.
7. Update feature state with the CF path, timestamp, and latest 1C log path.

## SYNC_MASTER

Goal: refresh `master` from storage.

1. Check the Git worktree is clean.
2. Checkout `master`.
3. Pull with `--ff-only` when a remote/upstream exists.
4. Update source infobase from storage.
5. Dump configuration files into `exportPath`.
6. Commit changes with `sync: refresh 1C configuration from repository`.

## FINISH_FEATURE

Goal: prepare a tested feature for manual import into the storage-connected source base.

1. Confirm the developer has finished testing.
2. Check the Git worktree is clean.
3. Run `SYNC_MASTER`.
4. Checkout the feature branch.
5. Merge `master` into the feature branch.
6. If conflicts occur, stop and resolve them in config files before continuing.
7. Load the merged files into the feature infobase.
8. Export final CF from the feature infobase into `artifactsPath`.
9. Report branch, master commit, feature commit, CF path, latest 1C log path, and publication URL.
10. Checkout `master` before completing.

Do not load the feature directly into the source infobase connected to storage.

## SWITCH_MASTER

Goal: switch Git to the configured master branch.

1. Require a clean Git worktree.
2. Checkout configured `masterBranch`.
3. Report current commit.
4. Do not pull and do not load files into 1C automatically.

## SWITCH_FEATURE

Goal: switch Git to a saved feature branch.

1. Find feature state from `FeatureName`, current branch, or the user.
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
- Git origin exists but differs from configured remote URL.
- Feature infobase target already exists.
- Feature copy cannot be unbound from storage.
- 1C Designer returns a non-zero exit code.
- CF export fails.
- Apache publication is requested but `webinst.exe` or Apache kind is missing.
