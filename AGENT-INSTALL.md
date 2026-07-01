# 1C Agent Workflow Bootstrap

This public file is the bootstrap contract for agents. A developer can say:

```text
Initialize a 1C agent project using this file: https://raw.githubusercontent.com/xmentosx/1c-agent-workflow/master/AGENT-INSTALL.md
```

The agent must read this file, install the shared workflow files into the target project, then run the monitored PowerShell helper script wizard. The wizard collects missing inputs, writes local settings, writes run status/log files, and runs the project initialization lifecycle.

Canonical bootstrap source:

- Repository: `https://github.com/xmentosx/1c-agent-workflow.git`
- Branch: `master`
- Bootstrap file: `AGENT-INSTALL.md`

Do not infer or try `main` for this package unless the user explicitly provides a different branch or URL.

## Supported Agents

This package is designed for both Codex and Kilo Code:

- Common workflow skill: `.agents/skills/1c-workflow`.
- Fast routine workflow skill: `.agents/skills/1c-workflow-fast`.
- Common project guidance: `AGENTS.md` and `USER-RULES.md`.
- Kilo slash command wrappers: `.kilo/commands/itl*.md`, using one short `/itl-*` command surface.
- Codex usage: choose the skill via `/skills`, invoke `$1c-workflow` for detailed workflows or `$1c-workflow-fast` for routine helper-first commands, or use natural language that matches the skill description.

Do not rely on Codex-only custom prompts for this workflow. They are local to one user and are not the team distribution mechanism.

## Agent Input Collection

Prefer the monitored PowerShell helper script wizard for initialization. The wizard collects local setup values, writes `.dev.env`, ensures `.agent-1c/project.json` exists, and then runs the lifecycle. In Kilo Code, the direct `/itl-init-project` wrapper must run this monitored helper directly and must not expand initialization into Kilo Questions before the first helper attempt. Use `-InitMode configured` only when `.agent-1c/project.json` and `.dev.env` are already prepared.

Default initialization command:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\run-agent-1c-window.ps1 -- -Action init-project -InitMode wizard
```

The monitored launcher opens the wizard in an external PowerShell window and writes `.agent-1c/runs/<run>/status.json` plus `console.log`, so the agent can detect completion without waiting for the developer to close the window manually.

Agents must run this command in the foreground and wait for it to exit. Do not wrap it in a background PowerShell process, do not keep the launched PowerShell session open after the script exits, and do not call `agent-1c.ps1 -Action init-project -InitMode wizard` directly as the default agent path.

Use `run-agent-1c-window.ps1 -KeepWindowOnFailure -- -Action init-project -InitMode wizard` only for manual debugging when the developer explicitly wants the external window to stay open after a failure.

For non-interactive automation, write a JSON answers file and run:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action init-project -InitMode json -InitAnswersPath <answers.json>
```

If the wizard fails because terminal input is unavailable, do not collect the initialization questionnaire in chat and do not continue the lifecycle manually. Run the monitored wizard command above, or use JSON mode only when the developer explicitly requested non-interactive initialization or an answers file already exists.

The agent should ask setup questions itself only when preparing a JSON answers file. Manual collection is not a fallback for unavailable interactive terminal input.

Ask interactively in a human-friendly format:

- Ask unrelated setup values one value at a time.
- Ask source infobase values after the source infobase kind is known; ask configuration repository values only when the source infobase is connected to storage.
- If the agent surface supports several structured fields/questions in one prompt, use one grouped form with separate short questions.
- If structured grouped prompts are not available, ask the same values sequentially, one question at a time.
- Never ask the developer to enter 6 or 7 lines into one free-form text answer; Enter may submit the first line in Codex/Kilo Code.
- The developer's answer must contain raw values only, for example `C:\Program Files\1cv8\8.3.xx.xxxx\bin\1cv8.exe`.
- Do not ask the developer to answer in `KEY=value` format.
- Do not require variable names in grouped answers.
- Do not show one large question that lists all missing project variables; grouping is allowed only for the source infobase and configuration repository values.
- Do not require the developer to type environment variable names such as `PLATFORM_PATH` or `SOURCE_INFOBASE_PATH`.
- Variable names may be mentioned only as internal storage hints after the human-readable label.
- In password lines of the grouped questionnaire, exact values `нет` and `-` mean an empty password. Compare these markers case-insensitively after trimming whitespace. Do not store the marker text as a password.
- When launching 1C, omit the infobase `/P` option when the infobase password is empty. For repository login, pass `/ConfigurationRepositoryP` only when `SOURCE_USES_REPOSITORY=true`; when the repository password is empty, pass it as a quoted empty native argument (`""`) so 1C does not open an interactive repository login dialog and the next option is not shifted into the password position.

Required for initial project setup:

- Current working directory is the project root. Show its absolute path and ask the developer to confirm initialization in this folder.
- Current agent target. Do not ask the developer to choose Codex/Kilo; use the agent surface that is running this bootstrap. If it cannot be detected, use `codex`.
- Directory for development branch infobase copies: do not ask during normal initialization. Use `.agent-1c/infobases/dev-branches` inside the active branch worktree and ensure `.agent-1c/infobases/` is ignored by Git. Ask only if the developer explicitly wants a custom location.
- Directory for development branch Git worktrees: do not ask during normal initialization. By default, create sibling worktrees under `<project-folder>-worktrees/<branch>`. Use `DEV_BRANCH_WORKTREE_ROOT` or `devBranchWorktreeRoot` only as an explicit override.
- Development branch infobase copies must be registered automatically in the user's 1C launcher list `%APPDATA%\1C\1CEStart\ibases.v8i` under `/ITL/<project-root-name>`. Write that file as UTF-8 with BOM and create a timestamped backup before changing it.
- 1C platform version/path. Before asking for a manual path, scan installed versions under existing standard folders such as `C:\Program Files\1cv8` and `C:\Program Files (x86)\1cv8`. Either folder may be absent; treat missing folders as normal and skip them without error. If versions are found, ask the developer to choose one of them and store the selected `...\bin\1cv8.exe` path. Do not offer the common root `C:\Program Files\1cv8` as a platform version. Ask for a custom full path only when no installed version is found or the developer chooses manual input.
- Apache web-client testing. Ask only whether new development branch infobases should be published to Apache by default. Store `WEB_PUBLISH_BY_DEFAULT=true|false` in local `.dev.env`, not in committed `project.json`. If the answer is no, do not ask Apache paths. If the answer is yes, run `detect-apache`, save the detected local values to `.dev.env`, and do not ask the developer for `webinst.exe`, Apache kind, publication root, URL base, or `httpd.conf`. If Apache is not detected, ask for explicit permission to install it automatically; after permission, run `install-apache`, then rerun `detect-apache`/`check-tools`.
- Vanessa Automation. It is required for executable development branch tests. If `VANESSA_AUTOMATION_EPF` is missing or invalid, ask for explicit permission to install it automatically; after permission, run `install-vanessa-automation`. Store downloaded files under `.agent-1c/tools/vanessa-automation` and local paths in `.dev.env`.
- Source infobase kind: `file` or `server`; ask this before the grouped questionnaire.
- Ask whether the source infobase is connected to a 1C configuration repository. Store `SOURCE_USES_REPOSITORY=true|false`.
- For `file` with storage, ask the source infobase and repository questionnaire as 6 separate questions:
  1. Source infobase directory.
  2. Infobase user.
  3. Infobase password, or `нет`/`-` if empty.
  4. Configuration repository path/address.
  5. Configuration repository user.
  6. Configuration repository password, or `нет`/`-` if empty.
- For `file` without storage, ask 3 separate questions: source infobase directory, infobase user, infobase password or `нет`/`-`.
- For `server` with storage, ask the source infobase and repository questionnaire as 7 separate questions:
  1. 1C server name.
  2. Source infobase name.
  3. Infobase user.
  4. Infobase password, or `нет`/`-` if empty.
  5. Configuration repository path/address.
  6. Configuration repository user.
  7. Configuration repository password, or `нет`/`-` if empty.
- For `server` without storage, ask 4 separate questions: 1C server name, source infobase name, infobase user, infobase password or `нет`/`-`.
- For a server infobase, build the connection string as `Srvr="<server>";Ref="<base>";`.
- Validate the number of collected questionnaire values before running 1C. If only one value is received from an attempted multi-line answer or the count is otherwise wrong, repeat the collection as a grouped prompt or as sequential single-value questions. After parsing, summarize the values without passwords and ask for confirmation.

Required for development branch setup:

- Development branch name.
- Git branch if not `itldev/<safe-dev-branch-name>`.
- Development branch worktree path if not derived from `DEV_BRANCH_WORKTREE_ROOT`.
- Development branch infobase path if not derived from `DEV_BRANCH_INFOBASE_ROOT`.
- Whether to publish to Apache only when the project was not configured during initialization or the developer wants a one-off override.
- If publishing is requested and Apache settings are missing, run `detect-apache`. If Apache is missing, ask whether to run `install-apache`; otherwise do not ask for Apache paths in the ordinary workflow.

Secrets must go to `.dev.env` or process environment variables. Never commit secrets.

Encoding rules:

- Create and update `.dev.env`, `.agent-1c/*.json`, and `.agent-1c/dev-branches/*.json` as UTF-8.
- Preserve developer input exactly, including Cyrillic usernames and paths such as `D:\Git\PM5 КОРП 4`.
- Do not recode values through OEM/ANSI console encodings before writing them to files.
- Treat `.agent-1c/dev-branches/*.json` as local runtime state. It is ignored by Git because it contains local paths, worktree paths, launcher metadata, verification status, and result paths.

## Install Files Into Target Project

1. Determine the source directory containing this bootstrap package.
   - If this file was read from a cloned repository, use that repository root.
   - If this file was read from the canonical URL and the repository root is unknown, clone `https://github.com/xmentosx/1c-agent-workflow.git` with `--branch master --single-branch` to a temporary directory, and use that clone.
   - If the user provided a different bootstrap URL, derive the repository and branch from that URL. If the branch is not present in the URL, ask one short clarifying question instead of guessing `main`.

2. Copy the common skills into the target project:

```text
<project>/.agents/skills/1c-workflow/
<project>/.agents/skills/1c-workflow-fast/
```

3. If the current agent is Kilo Code, copy Kilo command wrappers into:

```text
<project>/.kilo/commands/
```

4. Create `.agent-1c/project.json` from `templates/project.json` when missing. Use the default `devBranchInfoBaseRoot` unless the developer explicitly requested a custom location.

5. Create `.agent-1c/tools.json` from `templates/tools.json` when missing. Keep it committed so the team can adjust required software checks and install suggestions.

6. Create `.dev.env` from `templates/dev.env.example` when missing. Fill local paths, secrets, and local Apache preference. Write it as UTF-8 and ensure `.dev.env` is ignored by Git.

7. Append `templates/gitignore.append` lines to `.gitignore` if absent.

8. Append `templates/USER-RULES.append.md` to `USER-RULES.md` if absent.

9. Copy developer-facing docs into the target project when present:

```text
<project>/DEVELOPER-GUIDE.ru.md
<project>/DEV-BRANCH-DEVELOPMENT.ru.md
```

10. Do not edit installer-managed `AGENTS.md` directly. If `ai_rules_1c` later creates or updates `AGENTS.md`, treat it as managed.

## Check Required Software

Before running the initial lifecycle, check the local machine:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action check-tools
```

The agent must only offer install/setup commands. It must not install software without explicit developer confirmation.

Default checks come from `.agent-1c/tools.json`:

- Git: `git --version`, offer `winget install --id Git.Git -e`.
- 1C platform: check `PLATFORM_PATH` or `platformPath`; when missing/invalid, search installed versions in existing standard `1cv8` folders and offer the discovered `...\bin\1cv8.exe` paths before asking for manual input. Missing `Program Files`/`Program Files (x86)` `1cv8` folders are not errors.
- Vanessa Automation: check `VANESSA_AUTOMATION_EPF` or `.agent-1c/tools/vanessa-automation`; if missing, offer `install-vanessa-automation` after explicit developer confirmation.
- Apache/webinst: check only when web publication is enabled/requested. Prefer `WEB_PUBLISH_BY_DEFAULT` from local `.dev.env`; fall back to `project.web.publishByDefault` only for compatibility. If `WEBINST_PATH` is empty, use `webinst.exe` found next to the selected `1cv8.exe`. Detect Apache from `APACHE_HTTPD_CONF_PATH`, Windows services, `httpd.exe` in `PATH`, or standard folders such as `C:\Apache24`. If Apache is missing, offer `install-apache` after explicit developer confirmation.

When the workflow helper is available, the agent may list installed 1C versions with:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action list-platforms
```

When Apache publication is enabled, detect local Apache settings with:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action detect-apache
```

If Apache is not detected and the developer agrees to automatic installation, run:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action install-apache
```

`install-apache` downloads the official Apache Lounge zip, logs the actual SHA256, unpacks Apache to `C:\Apache24`, configures `Listen`/`ServerName`, installs and starts the `Apache24` service, saves detected values to `.dev.env`, and reruns Apache detection. A stale or mismatched `winget install ApacheLounge.httpd` hash is not a blocker for this path.

If Vanessa Automation is missing and the developer agrees to automatic installation, run:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action install-vanessa-automation
```

`install-vanessa-automation` downloads `vanessa-automation-single.*.zip` from the official `Pr-Mex/vanessa-automation` GitHub release, logs SHA256, unpacks the EPF under `.agent-1c/tools/vanessa-automation`, creates `tests/features` and `build/test-results/vanessa`, and saves `VANESSA_*` paths to `.dev.env`.

The current workflow intentionally uses the latest available `ai_rules_1c` and Vanessa Automation by default. A stricter industrial setup should add a lock file with exact `ai_rules_1c` commit/tag, Vanessa version, and expected SHA256, but this package does not enforce that yet.

## Install ai_rules_1c

After the first source infobase sync and configuration dump, install project rules from:

```text
https://github.com/comol/ai_rules_1c
```

Follow that repository's `AGENT-INSTALL.md`. It supports per-project installation and can install for Codex and Kilo Code.

If using the PowerShell installer directly from the project root:

```powershell
$rulesDir = Join-Path $env:TEMP "ai_rules_1c"
if (Test-Path $rulesDir) {
    git -C $rulesDir pull --ff-only
} else {
    git clone https://github.com/comol/ai_rules_1c.git $rulesDir
}

$tools = "codex" # use "kilocode" when this bootstrap is running from Kilo Code
& (Join-Path $rulesDir "install.ps1") -Command init -ProjectRoot (Get-Location).Path -Source $rulesDir -Tools $tools -AssumeYes
```

If the installer asks which tools to configure, choose the current agent surface. If it cannot be detected, choose Codex.

## Run Initial Lifecycle

After installing the workflow files, run the monitored script wizard:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\run-agent-1c-window.ps1 -- -Action init-project -InitMode wizard
```

The wizard opens in an external PowerShell window, writes `.agent-1c/runs/<run>/status.json` plus `console.log`, collects setup values, writes `.dev.env` and `.agent-1c/project.json`, and then performs:

The agent must wait for the monitored launcher process to finish. A background launch that returns immediately makes the agent miss completion, and a persistent PowerShell session leaves a stale prompt open after the helper has already written its status.

1. Required software check with install suggestions.
2. Git initialization when `.git` is absent.
3. Checkout or creation of local `master`.
4. Source infobase update from 1C configuration repository storage when `SOURCE_USES_REPOSITORY=true`; otherwise this step is skipped and the current source infobase state is used.
5. Dump of configuration files into fixed `src/cf`.
   - If `SOURCE_USES_REPOSITORY=true`, the dump command must also pass `/ConfigurationRepositoryF`, `/ConfigurationRepositoryN`, and `/ConfigurationRepositoryP`.
   - If `SOURCE_USES_REPOSITORY=false`, repository values must not be requested or passed; the developer manually updates the source infobase before `/itl-refresh` when needed.
   - First dump is full when `src/cf` is empty.
   - Later dumps are incremental with `-update -force` when `src/cf/ConfigDumpInfo.xml` exists.
   - If `src/cf` is not empty and `ConfigDumpInfo.xml` is missing, initialization stops with a clear error.
   - After the dump, `src/cf/ConfigDumpInfo.xml` must exist and the initial dump must be committed to `master`; if not, initialization stops.
   - The dump commit must stage and commit only `src/cf`. Unrelated staged files must not be included.
   - `src/cf` is tracked project content and must be force-added if a broad `.gitignore` rule such as `src/` would otherwise hide it.
   - 1C Designer commands must run strictly sequentially; the helper must wait for the repository update process to exit before starting the dump process.
6. Commit of the baseline dump.
7. Installation of `ai_rules_1c`.
8. Commit of workflow/rules files.

If PowerShell is unavailable, follow `.agents/skills/1c-workflow/references/workflow.md` manually with equivalent commands.

## User Commands After Initialization

Developers should not need to remember exact names.

For Kilo Code, show only the short command surface:

```text
/itl
/itl-new-config-branch <branch name>
/itl-new-extension-branch <branch name>
/itl-set-dev-branch-extension <extension name>
/itl-dump-dev-branch-extension
/itl-status
/itl-update-base
/itl-verify
/itl-refresh
/itl-result
/itl-close
/itl-switch <master|branch name>
```

New branch commands create a sibling Git worktree by default and leave the current project folder on `master`. After creation, report the printed worktree path and tell the developer to open a separate Codex/Kilo/IDE window there. Use `-UseCurrentWorktree` only when the developer explicitly asks for the legacy single-folder checkout mode.

Typing `/` shows available project commands.

For Codex:

```text
/skills -> 1C Workflow
$1c-workflow
$1c-workflow-fast
```

Natural language is also supported:

```text
Create a 1C development branch named order discounts.
Refresh the current 1C development branch from fresh master.
Export the result for the current 1C development branch.
Close the current 1C development branch and export the final result.
Sync master from storage or from the current source infobase state.
List current 1C development branches.
Switch to master.
Switch to development branch order discounts.
What 1C workflow actions are available?
```

## Completion Report

After each lifecycle action, report:

- Action executed.
- Git branch.
- Relevant commit hash.
- Source or development branch infobase path.
- Development branch worktree path when created or selected.
- CF/CFE result path when exported.
- Result manifest path when exported.
- Latest 1C log path.
- Publication URL when created.
- Any open risks or manual follow-up.
