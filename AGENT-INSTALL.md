# 1C Agent Workflow Bootstrap

This public file is the bootstrap contract for agents. A developer can say:

```text
Initialize a 1C agent project using this file: https://github.com/xmentosx/1c-agent-workflow/blob/master/AGENT-INSTALL.md
```

The agent must read this file, ask for missing inputs, install the shared workflow files into the target project, then run the project initialization lifecycle.

## Supported Agents

This package is designed for both Codex and Kilo Code:

- Common workflow skill: `.agents/skills/1c-workflow`.
- Common project guidance: `AGENTS.md` and `USER-RULES.md`.
- Kilo slash command wrappers: `.kilo/commands/1c*.md`.
- Codex usage: choose the skill via `/skills`, invoke `$1c-workflow`, or use natural language that matches the skill description.

Do not rely on Codex-only custom prompts for this workflow. They are local to one user and are not the team distribution mechanism.

## Agent Input Collection

Ask for missing values only. If `.agent-1c/project.json` or `.dev.env` already contains a value, reuse it.

Required for initial project setup:

- Target project root: the folder where the agent will create the local Git project, service files, and 1C configuration dump.
- Active agent target: `codex`, `kilocode`, or `both`.
- Directory for feature infobase copies (`FEATURE_INFOBASE_ROOT` / `featureInfoBaseRoot`).
- `1cv8.exe` full path.
- Source infobase kind: `file` or `server`.
- For a file infobase: source infobase directory.
- For a server infobase: server name and infobase name. The agent must build the connection string as `Srvr="<server>";Ref="<base>";`.
- Infobase user/password if required.
- 1C configuration repository path/address.
- 1C configuration repository user/password.

Required for feature setup:

- Feature name.
- Feature branch if not `feature/<safe-feature-name>`.
- Feature infobase path if not derived from `FEATURE_INFOBASE_ROOT`.
- Whether to publish to Apache.
- If publishing: `webinst.exe`, Apache kind, publication root, and URL base.

Secrets must go to `.dev.env` or process environment variables. Never commit secrets.

## Install Files Into Target Project

1. Determine the source directory containing this bootstrap package.
   - If this file was read from a cloned repository, use that repository root.
   - If this file was read from a URL and the repository root is unknown, ask the user for the repository URL, clone it to a temporary directory, and use that clone.

2. Copy the common skill into the target project:

```text
<project>/.agents/skills/1c-workflow/
```

3. If the user selected Kilo Code or both, copy Kilo command wrappers into:

```text
<project>/.kilo/commands/
```

4. Create `.agent-1c/project.json` from `templates/project.json` when missing. Fill non-secret values gathered from the user, including `featureInfoBaseRoot`.

5. Create `.agent-1c/tools.json` from `templates/tools.json` when missing. Keep it committed so the team can adjust required software checks and install suggestions.

6. Create `.dev.env` from `templates/dev.env.example` when missing. Fill local paths and secrets. Ensure `.dev.env` is ignored by Git.

7. Append `templates/gitignore.append` lines to `.gitignore` if absent.

8. Append `templates/USER-RULES.append.md` to `USER-RULES.md` if absent.

9. Do not edit installer-managed `AGENTS.md` directly. If `ai_rules_1c` later creates or updates `AGENTS.md`, treat it as managed.

## Check Required Software

Before running the initial lifecycle, check the local machine:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action check-tools
```

The agent must only offer install/setup commands. It must not install software without explicit developer confirmation.

Default checks come from `.agent-1c/tools.json`:

- Git: `git --version`, offer `winget install --id Git.Git -e`.
- 1C platform: check `PLATFORM_PATH` or `platformPath`, manual install.
- Codex: check `codex --version` when target includes Codex.
- Kilo Code: check VS Code extension `kilocode.Kilo-Code`; offer `code --install-extension kilocode.Kilo-Code --pre-release`.
- Apache/webinst: check only when web publication is enabled/requested.

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

$tools = "codex,kilocode" # or "codex" / "kilocode" based on the user's selected target
& (Join-Path $rulesDir "install.ps1") init -Source $rulesDir -Tools $tools
```

If the installer asks which tools to configure, choose the target selected by the user: Codex, Kilo Code, or both.

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
