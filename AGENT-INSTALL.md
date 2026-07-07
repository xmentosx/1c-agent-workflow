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
- Common project guidance: upstream `AGENTS.md` from `ai_rules_1c` plus detailed ITL overlay notes in `USER-RULES.md`.
- Kilo slash command templates: `.agents/skills/1c-workflow/kilo-command-templates`.
- Local Kilo command/runtime state: `.kilo/commands/itl*.md`, `.kilo/kilo.json`, and `.kilo/kilo.jsonc`, ignored by Git.
- Local MCP/client runtime state: `.agent-1c/mcp/` and `.codex/config.toml`, ignored by Git.
- Codex usage: choose the skill via `/skills`, invoke `$1c-workflow` for detailed workflows or `$1c-workflow-fast` for routine helper-first commands, or use natural language that matches the skill description.

Do not rely on Codex-only custom prompts for this workflow. They are local to one user and are not the team distribution mechanism.

## Agent Input Collection

Prefer the monitored PowerShell helper script wizard for initialization. The wizard collects local setup values, writes `.dev.env`, ensures `.agent-1c/project.json` exists, generates the local Kilo command surface, and then runs the lifecycle. Use `-InitMode configured` only when `.agent-1c/project.json` and `.dev.env` are already prepared.

Default initialization command:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\run-agent-1c-window.ps1 -- -Action init-project -InitMode wizard
```

The monitored launcher opens the wizard in an external PowerShell window and writes `.agent-1c/runs/<run>/status.json` plus `console.log`, so the agent can detect completion without waiting for the developer to close the window manually.

Agents must run this command in the foreground and wait for it to exit. Do not wrap it in a background PowerShell process, do not keep the launched PowerShell session open after the script exits, and do not call `agent-1c.ps1 -Action init-project -InitMode wizard` directly as the default agent path.

Do not run a separate `Test-Path` preflight before this launcher. The launcher validates the helper path itself and reports a clear error if it is missing. Raw PowerShell probes can emit serialized `CLIXML` progress records such as module preparation messages; those records are not the result of the check. If the agent shell tool accepts a timeout, use a positive long timeout such as `1800000` ms for this interactive wizard; never use `timeout: 0` or an infinite timeout sentinel.

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
- Development branch infobase copies must be registered automatically in the user's 1C launcher list `%APPDATA%\1C\1CEStart\ibases.v8i` under `/ITL/<project-root-name>`, with the launcher entry name equal to the development branch name. Write that file as UTF-8 with BOM and create a timestamped backup before changing it.
- 1C platform version/path. Before asking for a manual path, scan installed versions under existing standard folders such as `C:\Program Files\1cv8` and `C:\Program Files (x86)\1cv8`. Either folder may be absent; treat missing folders as normal and skip them without error. If versions are found, ask the developer to choose one of them and store the selected `...\bin\1cv8.exe` path. Do not offer the common root `C:\Program Files\1cv8` as a platform version. Ask for a custom full path only when no installed version is found or the developer chooses manual input.
- Web-client testing. Ask whether new development branch infobases should be web-published by default. Store `WEB_PUBLISH_BY_DEFAULT=true|false` in local `.dev.env`, not in committed `project.json`. If the answer is yes, ask whether to attempt automatic publication during branch creation and store `WEB_PUBLISH_AUTO=true|false`. Automatic publication uses an already prepared `webinst`-compatible web contour; the helper may detect or ask for `WEBINST_PATH`, `APACHE_KIND`, `WEB_PUBLICATION_ROOT`, `WEB_PUBLICATION_URL_BASE`, and optional `APACHE_HTTPD_CONF_PATH`, but it must never install Apache or any web server.
- Dependency mode. Ask one choice during initialization: use fresh dependency versions or locked versions from `.agent-1c/dependency-lock.json`. The default is fresh. Store `DEPENDENCY_MODE=fresh|locked` in `.dev.env` and mirror the choice in the dependency lock manifest. In fresh mode, the helper resolves the latest available dependencies and records the `ai_rules_1c` commit plus Vanessa Automation URL/SHA256 metadata. In locked mode, the helper must use only pinned lock values and must stop if a required pin or hash is missing or mismatched.
- Vanessa Automation. It is required for executable development branch tests. If `VANESSA_AUTOMATION_EPF` is missing or invalid, ask for explicit permission to install it automatically. In wizard mode the helper installs it inside the same init run after confirmation; in configured mode rerun `init-project -InitMode configured -InstallVanessaIfMissing`; in JSON mode set `installVanessaIfMissing=true`. Store downloaded files under `.agent-1c/tools/vanessa-automation` and local paths in `.dev.env`. Standard `/itl-check` uses `StartFeaturePlayer` through `TESTMANAGER -> TESTCLIENT` with branch-local `VANESSA_TEST_PORT`, not MCP. `verify-dev-branch helper alias` remains a compatibility alias. It also checks the local branch infobase event log against `.agent-1c/event-log-baselines/<branch>.json`; fresh non-baseline `Error` records fail verification. Foreign branch Vanessa processes are warnings by default; set `VANESSA_TEST_FOREIGN_WAIT_MODE=wait` only for conservative serialized local runs.
- vibecoding1c MCP. Do not ask developers to choose ports, models, or keys during initialization. Ask only whether vibecoding1c MCP should be configured now or later through a normal agent request. The default setup applies saved selection and opens selection first only when it is missing or incomplete; use `vibecoding1c-mcp-select` or `vibecoding1c-mcp-setup -Force` for an explicit reselect. Remote LAN vibecoding1c MCP is the default and is discovered from `VIBECODING1C_MCP_REGISTRY_REPO` (default `http://gitlabserv01.itland.local/root/MCP-vibecoding1c-registry.git`); config-specific remote vibecoding1c MCP always requires an explicit per-server `configId` selection, even when the registry has one configuration. The `code` and `graph` selections do not inherit `configId` or `hostId` from each other. Developers can override each server to local. Local vibecoding1c MCP still clones or fast-forwards the private GitLab distribution from `VIBECODING1C_MCP_DISTRIBUTION_REPO` (default `http://gitlabserv01.itland.local/root/MCP-vibecoding1c.git`) into `%LOCALAPPDATA%\ITL\MCP\vibecoding1c\distribution`, rotates license keys into `%LOCALAPPDATA%\ITL\MCP\vibecoding1c`, allocates ports from the local registry, writes ignored Codex/Kilo config for the current scope, removes default upstream `ai_rules_1c` MCP client entries after rules install/update, and keeps project/branch vibecoding1c MCP out of neighboring worktrees. Use `VIBECODING1C_MCP_REGISTRY_PATH` and `VIBECODING1C_MCP_DISTRIBUTION_PATH` only as explicit manual checkout overrides.
- Vanessa MCP. Do not configure a shared MCP server during project initialization. When a developer needs AI-assisted scenario authoring/debugging, run `install-vanessa-mcp` and `start-vanessa-mcp` from the target `itldev/*` worktree so the MCP port, PID, URL, and infobase are branch-local.
- External MCP. Treat future or user-provided MCP servers as a separate family. Do not publish them through the vibecoding1c registry and do not remove their Codex/Kilo config entries unless they are explicitly marked `managedBy = "vibecoding1c-mcp"` and `family = "vibecoding1c"`.
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
- Whether to web-publish only when the project was not configured during initialization or the developer wants a one-off override.
- If publication is requested and automatic publication settings are missing, let the helper ask inside `configure-web-publication` or `publish-dev-branch`; otherwise do not collect publication details in agent chat.

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

3. Generate context-specific Kilo command wrappers into ignored local state:

```text
<project>/.kilo/commands/
```

4. Create `.agent-1c/project.json` from `templates/project.json` when missing. Use the default `devBranchInfoBaseRoot` unless the developer explicitly requested a custom location.

5. Create `.agent-1c/dependency-lock.json` from `templates/dependency-lock.json` when missing. Keep it committed when the team wants reproducible bootstrap pins; fresh mode updates it with resolved workflow package revision, dependency revisions, URLs, and hashes.

6. Create `.agent-1c/tools.json` from `templates/tools.json` when missing. Keep it committed so the team can adjust required software checks and install suggestions.

7. Create `.dev.env` from `templates/dev.env.example` when missing. Fill local paths, secrets, web publication preference, and the chosen `DEPENDENCY_MODE`. Write it as UTF-8 and ensure `.dev.env` is ignored by Git.

8. Append `templates/gitignore.append` lines to `.gitignore` if absent.

8. Append `templates/AGENTS.append.md` to `AGENTS.md` only as a fallback when `AGENTS.md` does not already reference `USER-RULES.md`. Current `ai_rules_1c` creates and manages the normal root `AGENTS.md`; do not modify it just to add ITL notes.

9. Apply the managed ITL block from `templates/USER-RULES.append.md` to `USER-RULES.md`. New helpers wrap this block with markers so future `update-workflow` runs can replace it safely.

10. Copy developer-facing docs into the target project when present:

```text
<project>/DEVELOPER-GUIDE.ru.md
<project>/DEV-BRANCH-DEVELOPMENT.ru.md
```

11. Do not add detailed workflow text to `AGENTS.md`. Keep ITL-specific rules in `USER-RULES.md` so upstream-managed `AGENTS.md` can continue to update cleanly.

## Diagnostic Tool Checks

The normal bootstrap path is the monitored `init-project` run. It owns required tool preparation and should not be expanded into `check-tools`, separate install actions, and a second init run. Use this section only for diagnostics or manual recovery.

To inspect the local machine readiness:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action check-tools
```

The helper must only offer install/setup commands from this diagnostic action. It must not install software without explicit developer confirmation.

Default checks come from `.agent-1c/tools.json`:

- Git: `git --version`, offer `winget install --id Git.Git -e`.
- 1C platform: check `PLATFORM_PATH` or `platformPath`; when missing/invalid, search installed versions in existing standard `1cv8` folders and offer the discovered `...\bin\1cv8.exe` paths before asking for manual input. Missing `Program Files`/`Program Files (x86)` `1cv8` folders are not errors.
- Vanessa Automation: check `VANESSA_AUTOMATION_EPF` or `.agent-1c/tools/vanessa-automation`; if missing, diagnostic output can mention `install-vanessa-automation`, but normal init continuation should rerun `init-project` with `-InstallVanessaIfMissing` after explicit confirmation.
- Web publication: check `webinst`/publication settings only when automatic web publication is enabled/requested. Prefer `WEB_PUBLISH_BY_DEFAULT` and `WEB_PUBLISH_AUTO` from local `.dev.env`; fall back to `project.web.publishByDefault`/`project.web.publishAuto` only for compatibility. If `WEBINST_PATH` is empty, use `webinst.exe` found next to the selected `1cv8.exe`. Detect an existing Apache/httpd contour from `APACHE_HTTPD_CONF_PATH`, Windows services, `httpd.exe` in `PATH`, or standard folders such as `C:\Apache24`; ITL workflow does not install or configure the web server.

When the workflow helper is available, the agent may list installed 1C versions with:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action list-platforms
```

When automatic web publication is enabled, inspect existing publication settings with:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action detect-web-publication
```

To change publication policy or collect settings after init, run:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action configure-web-publication
```

To finish, skip, or retry publication for an existing development branch, run `publish-dev-branch` from that branch worktree. The helper owns the manual prompt and records the URL/status in branch state.

For diagnostic/manual recovery, if Vanessa Automation is missing and the developer explicitly asks for the standalone install action, run:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action install-vanessa-automation
```

`install-vanessa-automation` downloads `vanessa-automation-single.*.zip` from the official `Pr-Mex/vanessa-automation` GitHub release, logs SHA256, unpacks the EPF under `.agent-1c/tools/vanessa-automation`, creates `tests/features` and `build/test-results/vanessa`, and saves `VANESSA_*` paths to `.dev.env`. The helper also uses `VANESSA_TEST_PORT_RANGE=48051..48150` by default for final verify and stores the assigned port in branch state.

`install-vanessa-mcp` is a development-branch action, not an init action. It downloads `client_mcp.cfe` and `VAExtension.*.cfe`, installs them into the current branch infobase, and `start-vanessa-mcp` starts Vanessa `runMcp` on a branch-local port. MCP is for authoring/debugging; the final verify gate remains packet `StartFeaturePlayer` in `TESTMANAGER -> TESTCLIENT` mode.

`vibecoding1c-mcp-setup` is the vibecoding1c MCP action used when the developer asks the agent to configure or inspect vibecoding1c MCP. It refreshes the remote endpoint registry, applies `.agent-1c/mcp/vibecoding1c-selection.json`, connects selected remote endpoints or starts selected local servers, and writes Codex/Kilo vibecoding1c MCP config. If the per-server selection is missing or incomplete, setup runs selection before connecting; `-Force` repeats selection even when it is complete. Use `vibecoding1c-mcp-select` to choose remote/local, remote `configId`/`hostId`, or local `project|branch` scope. Use `vibecoding1c-mcp-status` for inspection, `vibecoding1c-mcp-refresh-registry` for registry-only update, `vibecoding1c-mcp-update` for registry/distribution/key/image refresh, and `vibecoding1c-mcp-write-client-config` to rewrite only the managed client config blocks.

Dedicated vibecoding1c MCP hosts are prepared without the agent through `vibecoding1c-mcp-host/install-vibecoding1c-mcp-host.ps1`. The host can read configuration XML files from a Git `sourceRepo` or a local `sourcePath`. Local `sourcePath` folders can be refreshed manually with `-Action dump-config`, which updates the source infobase from 1C configuration repository storage and then runs incremental `/DumpConfigToFiles` when `ConfigDumpInfo.xml` exists. The host publishes only `registry.json` endpoint/freshness metadata to GitLab; secrets, local paths, infobase credentials, and `ONEC_AI_TOKEN` stay in ignored `vibecoding1c-mcp-host/host.config.json`, the host-local distribution `config.env`, or local environment.

The current workflow intentionally uses the latest available ITL workflow package, `ai_rules_1c`, and Vanessa Automation by default. It records the resolved workflow package commit, resolved `ai_rules_1c` commit, Vanessa URL/version/SHA256, and downloaded archive hashes in `.agent-1c/dependency-lock.json`. For reproducible bootstrap, choose `DEPENDENCY_MODE=locked`; the helper will use only pinned values and stop when a required pin or hash is missing or mismatched.

## Update Existing ITL Workflow

For projects that already have this workflow installed, do not rerun `init-project`. First update the installed helper/workflow files from this bootstrap package if the project predates `update-workflow`, then use the normal maintenance command:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action update-workflow
```

In Kilo Code, ask the agent to update the ITL workflow or run the helper action directly. The command runs only from the `master` worktree, updates managed files (`.agents/skills/1c-workflow*`, Kilo command templates, `templates/`, and workflow docs), regenerates ignored `.kilo/commands/itl*.md` for the current folder, preserves local runtime/project state, records `workflowPackage` in `.agent-1c/dependency-lock.json`, and runs `update-ai-rules` unless `-SkipAiRules` is passed.

Optional source overrides:

```powershell
$env:ITL_WORKFLOW_SOURCE_PATH = "D:\Git\1c-agent-workflow"
$env:ITL_WORKFLOW_REPO = "https://github.com/xmentosx/1c-agent-workflow.git"
$env:ITL_WORKFLOW_REF = "master"
```

After the update, review and commit tracked changes in `master`. Active `itldev/*` worktrees do not update automatically; merge the updated `master` into each branch or run `/itl-refresh` from that branch worktree. Refresh vibecoding1c MCP or branch-local Vanessa MCP by asking the agent in the relevant worktree.

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

To refresh `ai_rules_1c` after initialization, run:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action update-ai-rules
```

In Kilo Code, ask the agent to update ITL rules. The helper runs the upstream updater, removes default upstream MCP client entries from ignored Codex/Kilo config, records the resolved commit in `.agent-1c/dependency-lock.json`, reapplies the managed `USER-RULES.md` ITL block from `templates/USER-RULES.append.md`, and avoids modifying upstream-managed `AGENTS.md` when it already points to `USER-RULES.md`.

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

If PowerShell is unavailable, start with `.agents/skills/1c-workflow/references/workflow.md`, then open only the matching topic reference for the manual equivalent commands.

## User Commands After Initialization

Developers should not need to remember exact names.

For Kilo Code, slash commands are generated per worktree. In the `master` worktree, show only:

```text
/itl
/itl-status
/itl-new-config-branch <branch name>
/itl-new-extension-branch <branch name>
/itl-update-workflow
```

In an `itldev/*` development worktree, show only:

```text
/itl
/itl-status
/itl-check
/itl-refresh
/itl-result
```

New branch commands create a sibling Git worktree by default and leave the current project folder on `master`. After creation, report the printed worktree path and tell the developer to open a separate Codex/Kilo/IDE window there. Use `-UseCurrentWorktree` only when the developer explicitly asks for the legacy single-folder checkout mode.

Advanced/helper actions such as extension setup/dump, project initialization, workflow/rules update, vibecoding1c MCP, and Vanessa MCP remain available through natural-language requests or direct PowerShell helper actions, but they are intentionally not generated as visible Kilo slash commands.

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
Show the master worktree path.
Show development branch worktree paths.
What 1C workflow actions are available?
```

`/itl-result` follows `VERIFICATION_POLICY`. The default `warn` policy preserves the current explicit unverified override flow and records the override in the result manifest. When `VERIFICATION_POLICY=block`, result export must stop until `/itl-check` or `verify-dev-branch helper alias` is fresh passed; do not bypass that with `-AllowUnverifiedResult`. `close-dev-branch` remains an advanced helper action only when the developer explicitly wants to mark a branch closed and hide it from active lists.

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
