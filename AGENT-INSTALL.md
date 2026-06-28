# 1C Agent Workflow Bootstrap

This public file is the bootstrap contract for agents. A developer can say:

```text
Initialize a 1C agent project using this file: https://raw.githubusercontent.com/xmentosx/1c-agent-workflow/master/AGENT-INSTALL.md
```

The agent must read this file, ask for missing inputs, install the shared workflow files into the target project, then run the project initialization lifecycle.

Canonical bootstrap source:

- Repository: `https://github.com/xmentosx/1c-agent-workflow.git`
- Branch: `master`
- Bootstrap file: `AGENT-INSTALL.md`

Do not infer or try `main` for this package unless the user explicitly provides a different branch or URL.

## Supported Agents

This package is designed for both Codex and Kilo Code:

- Common workflow skill: `.agents/skills/1c-workflow`.
- Common project guidance: `AGENTS.md` and `USER-RULES.md`.
- Kilo slash command wrappers: `.kilo/commands/1c*.md`.
- Codex usage: choose the skill via `/skills`, invoke `$1c-workflow`, or use natural language that matches the skill description.

Do not rely on Codex-only custom prompts for this workflow. They are local to one user and are not the team distribution mechanism.

## Agent Input Collection

Ask for missing values only. If `.agent-1c/project.json` or `.dev.env` already contains a value, reuse it.

Ask interactively in a human-friendly format:

- Ask one value at a time.
- The developer's answer must be the raw value only, for example `C:\Program Files\1cv8\8.3.xx.xxxx\bin\1cv8.exe`.
- Do not ask the developer to answer in `KEY=value` format.
- Do not group several required values into one free-form answer.
- Do not show one large question that lists all missing variables.
- If the agent surface supports structured prompts, use a separate prompt for each value, not one prompt with a custom free-form block.
- Do not require the developer to type environment variable names such as `PLATFORM_PATH` or `SOURCE_INFOBASE_PATH`.
- Variable names may be mentioned only as internal storage hints after the human-readable label.
- For passwords that may be empty, first ask a yes/no question such as "Is an infobase password set?" or "Is a repository password set?". Ask for the password value only when the answer is yes. When the answer is no, store an empty value and do not require the developer to type phrases like "без пароля" or "no password". When launching 1C, omit the infobase `/P` option when the infobase password is empty. For repository login, always pass `/ConfigurationRepositoryP`; when the repository password is empty, pass it as a quoted empty native argument (`""`) so 1C does not open an interactive repository login dialog and the next option is not shifted into the password position.

Required for initial project setup:

- Current working directory is the project root. Show its absolute path and ask the developer to confirm initialization in this folder.
- Current agent target. Do not ask the developer to choose Codex/Kilo; use the agent surface that is running this bootstrap. If it cannot be detected, use `codex`.
- Directory for feature infobase copies: do not ask during normal initialization. Use `.agent-1c/infobases/features` inside the project and ensure `.agent-1c/infobases/` is ignored by Git. Ask only if the developer explicitly wants a custom location.
- 1C platform version/path. Before asking for a manual path, scan installed versions under existing standard folders such as `C:\Program Files\1cv8` and `C:\Program Files (x86)\1cv8`. Either folder may be absent; treat missing folders as normal and skip them without error. If versions are found, ask the developer to choose one of them and store the selected `...\bin\1cv8.exe` path. Do not offer the common root `C:\Program Files\1cv8` as a platform version. Ask for a custom full path only when no installed version is found or the developer chooses manual input.
- Source infobase kind: `file` or `server`.
- For a file infobase: source infobase directory.
- For a server infobase: server name and infobase name. The agent must build the connection string as `Srvr="<server>";Ref="<base>";`.
- Infobase user, then ask whether an infobase password is set. If yes, ask for the password. If no, store `IB_PASSWORD=` or leave it absent.
- 1C configuration repository path/address.
- 1C configuration repository user, then ask whether a repository password is set. If yes, ask for the password. If no, store `REPOSITORY_PASSWORD=` or leave it absent.

Required for feature setup:

- Feature name.
- Feature branch if not `feature/<safe-feature-name>`.
- Feature infobase path if not derived from `FEATURE_INFOBASE_ROOT`.
- Whether to publish to Apache.
- If publishing: `webinst.exe`, Apache kind, publication root, and URL base.

Secrets must go to `.dev.env` or process environment variables. Never commit secrets.

Encoding rules:

- Create and update `.dev.env`, `.agent-1c/*.json`, and `.agent-1c/features/*.json` as UTF-8.
- Preserve developer input exactly, including Cyrillic usernames and paths such as `D:\Git\PM5 КОРП 4`.
- Do not recode values through OEM/ANSI console encodings before writing them to files.

## Install Files Into Target Project

1. Determine the source directory containing this bootstrap package.
   - If this file was read from a cloned repository, use that repository root.
   - If this file was read from the canonical URL and the repository root is unknown, clone `https://github.com/xmentosx/1c-agent-workflow.git` with `--branch master --single-branch` to a temporary directory, and use that clone.
   - If the user provided a different bootstrap URL, derive the repository and branch from that URL. If the branch is not present in the URL, ask one short clarifying question instead of guessing `main`.

2. Copy the common skill into the target project:

```text
<project>/.agents/skills/1c-workflow/
```

3. If the current agent is Kilo Code, copy Kilo command wrappers into:

```text
<project>/.kilo/commands/
```

4. Create `.agent-1c/project.json` from `templates/project.json` when missing. Use the default `featureInfoBaseRoot` unless the developer explicitly requested a custom location.

5. Create `.agent-1c/tools.json` from `templates/tools.json` when missing. Keep it committed so the team can adjust required software checks and install suggestions.

6. Create `.dev.env` from `templates/dev.env.example` when missing. Fill local paths and secrets. Write it as UTF-8 and ensure `.dev.env` is ignored by Git.

7. Append `templates/gitignore.append` lines to `.gitignore` if absent.

8. Append `templates/USER-RULES.append.md` to `USER-RULES.md` if absent.

9. Copy developer-facing docs into the target project when present:

```text
<project>/DEVELOPER-GUIDE.ru.md
<project>/FEATURE-DEVELOPMENT.ru.md
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
- Apache/webinst: check only when web publication is enabled/requested.

When the workflow helper is available, the agent may list installed 1C versions with:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action list-platforms
```

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

After installing the workflow files and filling project state, run:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action init-project
```

This performs:

1. Required software check with install suggestions.
2. Git initialization when `.git` is absent.
3. Checkout or creation of local `master`.
4. Source infobase update from 1C configuration repository storage.
5. Dump of configuration files into fixed `src/cf`.
   - First dump is full when `src/cf` is empty.
   - Later dumps are incremental with `-update -force` when `src/cf/ConfigDumpInfo.xml` exists.
   - If `src/cf` is not empty and `ConfigDumpInfo.xml` is missing, initialization stops with a clear error.
   - After the dump, `src/cf/ConfigDumpInfo.xml` must exist and the initial dump must be committed to `master`; if not, initialization stops.
6. Commit of the baseline dump.
7. Installation of `ai_rules_1c`.
8. Commit of workflow/rules files.

If PowerShell is unavailable, follow `.agents/skills/1c-workflow/references/workflow.md` manually with equivalent commands.

## User Commands After Initialization

Developers should not need to remember exact names.

For Kilo Code:

```text
/1c
/1c-init
/1c-start <feature name>
/1c-load
/1c-refresh
/1c-cf
/1c-sync
/1c-finish
/1c-features
/1c-master
/1c-feature <feature name>
```

Typing `/` shows available project commands.

For Codex:

```text
/skills -> 1C Workflow
$1c-workflow
```

Natural language is also supported:

```text
Start a 1C feature named order discounts.
Refresh the current 1C feature from storage.
Export CF for the current 1C feature.
Finish the current 1C feature and export CF.
Sync master from 1C storage.
List current 1C features.
Switch to master.
Switch to feature order discounts.
What 1C workflow actions are available?
```

## Completion Report

After each lifecycle action, report:

- Action executed.
- Git branch.
- Relevant commit hash.
- Source or feature infobase path.
- CF path when exported.
- Latest 1C log path.
- Publication URL when created.
- Any open risks or manual follow-up.
