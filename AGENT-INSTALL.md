# 1C Agent Workflow Bootstrap

This public file is the bootstrap contract for agents. A developer can say:

```text
Initialize a 1C agent project using this file: https://raw.githubusercontent.com/xmentosx/1c-agent-workflow/master/AGENT-INSTALL.md
```

The agent must read this file, run the one-step bootstrap script for the target project, and wait for it to finish. The bootstrap script installs the shared workflow files and starts the monitored PowerShell helper wizard. The wizard collects missing inputs, writes local settings, writes run status/log files, and runs the project initialization lifecycle.

Canonical bootstrap source:

- Repository: `https://github.com/xmentosx/1c-agent-workflow.git`
- Branch: `master`
- Bootstrap file: `AGENT-INSTALL.md`
- Bootstrap script: `install-agent-1c-workflow.ps1`

Do not infer or try `main` for this package unless the user explicitly provides a different branch or URL.

## Supported Agents

This package supports Codex, Kilo Code, Claude Code, Cursor, and OpenCode, with exactly one active client per project. The initialization wizard requires that choice; `other` and multi-client installs are not supported.

- Common workflow skill: `.agents/skills/1c-workflow`.
- Fast routine workflow skill: `.agents/skills/1c-workflow-fast`.
- Product documentation skill: `.agents/skills/product-docs`.
- Branch data exploration skill: `.agents/skills/itl-roctup-1c-data`.
- Runtime form investigation skill: `.agents/skills/itl-vanessa-ui-mcp`.
- Common project guidance: upstream `AGENTS.md` from `ai_rules_1c` plus detailed ITL overlay notes in `USER-RULES.md`.
- ITL command source templates: `.agents/skills/1c-workflow/kilo-command-templates`; adapters render them to the active client's native command path. Codex uses project-local skills and natural requests because project-local custom slash prompts are not supported.
- Native discovery paths are registered in the helper: Codex `.codex` plus `.agents/skills`; Kilo `.kilo`; Claude `.claude`; Cursor `.cursor`; OpenCode singular `.opencode/agent` and `.opencode/command`, with `.claude/skills` and root `opencode.json`.
- Local MCP/client runtime state is ignored and written only for the active client. Kilo uses `.kilo/kilo.json`; a neighboring `.kilo/kilo.jsonc` collision blocks writes. Tracked Cursor/OpenCode config requires explicit migration.
- Codex usage: choose the skill via `/skills`, invoke `$1c-workflow` for detailed workflows or `$1c-workflow-fast` for routine helper-first commands, or use natural language that matches the skill description.

Do not rely on Codex-only custom prompts for this workflow. They are local to one user and are not the team distribution mechanism.

## Agent Input Collection

Prefer the root bootstrap script for initialization. It copies only managed workflow files into the target project and then starts the monitored PowerShell helper wizard. The wizard collects local setup values, writes `.dev.env`, ensures `.agent-1c/project.json` exists, generates the local Kilo command surface, and then runs the lifecycle. Use `-InitMode configured` only when `.agent-1c/project.json` and `.dev.env` are already prepared.

Default bootstrap command from the cloned workflow package:

```powershell
powershell -ExecutionPolicy Bypass -File <source>\install-agent-1c-workflow.ps1 -ProjectRoot <project>
```

The bootstrap command copies `.agents/skills/1c-workflow*`, `.agents/skills/product-docs`, `.agents/skills/itl-roctup-1c-data`, `.agents/skills/itl-vanessa-ui-mcp`, `templates/`, the root docs/guides, and `install-agent-1c-workflow.ps1`. It does not copy `.dev.env`, `.agent-1c/dev-branches/`, `.agent-1c/mcp/`, `.codex/config.toml`, `.kilo/kilo.json*`, or generated `.kilo/commands/`.

The bootstrap script then runs this monitored initialization command from the target project:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\run-agent-1c-window.ps1 -- -Action init-project -InitMode wizard
```

The monitored launcher opens the wizard in an external PowerShell window and writes `.agent-1c/runs/<run>/status.json` plus `console.log`, so the agent can detect completion without waiting for the developer to close the window manually.

Agents must run this command in the foreground and wait for it to exit. Do not wrap it in a background PowerShell process, do not keep the launched PowerShell session open after the script exits, and do not call `agent-1c.ps1 -Action init-project -InitMode wizard` directly as the default agent path.

Do not run a separate `Test-Path` preflight before this launcher. The launcher validates the helper path itself and reports a clear error if it is missing. Raw PowerShell probes can emit serialized `CLIXML` progress records such as module preparation messages; those records are not the result of the check. The launcher has a built-in 60 minute limit (`-MaxWaitSeconds 3600`, or `0` to disable explicitly); the bootstrap forwards `-InitMaxWaitSeconds 3600` by default. If the agent shell tool accepts a timeout, use a positive long timeout greater than the launcher limit, such as `3900000` ms, for this interactive wizard; never use `timeout: 0` or an infinite timeout sentinel.

If the outer shell interrupts bootstrap, the run is incomplete even when the dump files exist. Repeat the same root bootstrap command with `timeout_ms >= 3900000`; the launcher marks a dead or invalid prior init as `launcher.orphaned` and resumes from the first unproven stage. Never delete `index.lock`, commit files, run later lifecycle steps, or edit `status.json` by hand. A live recorded helper blocks a second init.

Use `run-agent-1c-window.ps1 -KeepWindowOnFailure -- -Action init-project -InitMode wizard` only for manual debugging when the developer explicitly wants the external window to stay open after a failure. Use `-MaxWaitSeconds <seconds>` on that launcher, or `-InitMaxWaitSeconds <seconds>` on `install-agent-1c-workflow.ps1`, when a project needs a different monitored init limit.

For non-interactive automation, write a JSON answers file and run:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action init-project -InitMode json -InitAnswersPath <answers.json>
```

The answers JSON must include `sourceInfoBaseUnsafeActionProtectionMode` as `manual-confirm`, `defer`, or `confirmed`. Configured init reads the same setting from `SOURCE_INFOBASE_UNSAFE_ACTION_PROTECTION_MODE` first and then `project.json`. The normal wizard uses `manual-confirm`, opens the source Configurator only after a negative answer, and stores a local context-bound confirmation without passwords. `defer` leaves the copied-branch fallback active; `confirmed` is an explicit external assertion.

If the wizard fails because terminal input is unavailable, do not collect the initialization questionnaire in chat and do not continue the lifecycle manually. Run the monitored wizard command above, or use JSON mode only when the developer explicitly requested non-interactive initialization or an answers file already exists.

The agent should ask setup questions itself only when preparing a JSON answers file. Manual collection is not a fallback for unavailable interactive terminal input.

Ask interactively in a human-friendly format:

- Ask unrelated setup values one value at a time.
- Ask source infobase values after the source infobase kind is known; ask configuration repository values only when the source infobase is connected to storage.
- If the agent surface supports several structured fields/questions in one prompt, use one grouped form with separate short questions.
- If structured grouped prompts are not available, ask the same values sequentially, one question at a time.
- Never ask the developer to enter 6 or 7 lines into one free-form text answer; Enter may submit the first line in an agent client.
- The developer's answer must contain raw values only, for example `C:\Program Files\1cv8\8.3.xx.xxxx\bin\1cv8.exe`.
- Do not ask the developer to answer in `KEY=value` format.
- Do not require variable names in grouped answers.
- Do not show one large question that lists all missing project variables; grouping is allowed only for the source infobase and configuration repository values.
- Do not require the developer to type environment variable names such as `PLATFORM_PATH` or `SOURCE_INFOBASE_PATH`.
- Variable names may be mentioned only as internal storage hints after the human-readable label.
- In password lines of the grouped questionnaire, exact values `нет` and `-` mean an empty password. Compare these markers case-insensitively after trimming whitespace. Do not store the marker text as a password.
- When launching 1C, omit the infobase `/P` option when the infobase password is empty. For repository login, pass `/ConfigurationRepositoryP` only when `SOURCE_USES_REPOSITORY=true`; when the repository password is empty, pass it as a quoted empty native argument (`""`) so 1C does not open an interactive repository login dialog and the next option is not shifted into the password position.

Required for initial project setup:

- Current working directory is the project root. Do not ask the developer to confirm initialization in chat before starting the monitored wizard; the wizard owns interactive setup questions and visible confirmations. Print the absolute path only as execution context when useful.
- Current agent target. Require one explicit choice: `codex`, `kilocode`, `claude-code`, `cursor`, or `opencode`. The running surface may be offered as the recommended choice but must not be silently inferred. JSON/configured init must provide `agentTarget` or an exact-one `aiRules.tools` value.
- Directory for development branch infobase copies: do not ask during normal initialization. Use `.agent-1c/infobases/dev-branches` inside the active branch worktree and ensure `.agent-1c/infobases/` is ignored by Git. Ask only if the developer explicitly wants a custom location.
- Directory for development branch Git worktrees: do not ask during normal initialization. By default, create sibling worktrees under `<project-folder>-worktrees/<branch>`. Use `DEV_BRANCH_WORKTREE_ROOT` or `devBranchWorktreeRoot` only as an explicit override.
- Development branch infobase copies must be registered automatically in the user's 1C launcher list `%APPDATA%\1C\1CEStart\ibases.v8i` under `/ITL/<project-root-name>`, with the launcher entry name equal to the development branch name. Write that file as UTF-8 with BOM and create a timestamped backup before changing it.
- 1C platform version/path. Before asking for a manual path, scan installed versions under existing standard folders such as `C:\Program Files\1cv8` and `C:\Program Files (x86)\1cv8`. Either folder may be absent; treat missing folders as normal and skip them without error. If versions are found, ask the developer to choose one of them and store the selected `...\bin\1cv8.exe` path. Do not offer the common root `C:\Program Files\1cv8` as a platform version. Ask for a custom full path only when no installed version is found or the developer chooses manual input.
- Base configuration version. Ask whether the project uses `PM4` or `PM5`; default is `PM5`. Store the answer in committed `.agent-1c/project.json` as `baseConfigurationVersion`. `BASE_CONFIGURATION_VERSION` is only a local/process override.
- Web-client testing. Ask whether new development branch infobases should be web-published by default. Store `WEB_PUBLISH_BY_DEFAULT=true|false` in local `.dev.env`, not in committed `project.json`. If the answer is yes, ask whether to attempt automatic publication during branch creation and store `WEB_PUBLISH_AUTO=true|false`. Automatic publication uses an already prepared `webinst`-compatible web contour; the helper may detect or ask for `WEBINST_PATH`, `APACHE_KIND`, `WEB_PUBLICATION_ROOT`, `WEB_PUBLICATION_URL_BASE`, and optional `APACHE_HTTPD_CONF_PATH`, but it must never install Apache or any web server.
- When `WEB_PUBLISH_BY_DEFAULT=false`, an empty `INFOBASE_PUBLISH_URL` is expected and must not be reported as required setup before a development branch.
- Dependency mode. Ask one choice during initialization: fresh or locked. `fresh` selects the newest ROCTUP and Vanessa UI versions admitted by the packaged on-demand compatibility manifest, never an arbitrary upstream latest; `locked` uses only complete pinned URL/SHA256 metadata. The fresh mode does not advance the immutable controlled fork: both modes keep `aiRules.ref` pinned and never advance its `main`. The on-demand facade v1 supports Windows x64 only and init fails before client-config mutation on another platform.
- Vanessa Automation verification. It is required for executable development branch tests and provides the EPF used by branch-local Vanessa UI MCP. If `VANESSA_AUTOMATION_EPF` is missing or invalid, the helper installs it automatically inside the same init run; do not ask whether it is needed. Store downloaded files under `.agent-1c/tools/vanessa-automation` and local paths in `.dev.env`. Standard `/itl-check` uses `StartFeaturePlayer` through `TESTMANAGER -> TESTCLIENT` with branch-local `VANESSA_TEST_PORT` as the TestClient launch/connect port in VAParams, not MCP. `verify-dev-branch helper alias` remains a compatibility alias. It also checks the local branch infobase event log against `.agent-1c/event-log-baselines/<branch>.json`; fresh non-baseline `Error` records fail verification. Foreign branch Vanessa processes are warnings by default; set `VANESSA_TEST_FOREIGN_WAIT_MODE=wait` only for conservative serialized local runs.
- ROCTUP MCP Toolkit. Init/update caches the compatible EPF and `itl-ondemand-mcp` executable, then registers `itl-roctup-data` for the active client. The first tool call starts a client-owned branch backend; idle/client exit stops it and releases its registry port.
- vibecoding1c MCP. Do not ask developers to choose ports, models, or keys during initialization. Ask only whether vibecoding1c MCP should be configured now or later through a normal agent request; the default answer is yes. The default setup applies saved selection and opens selection first only when it is missing or incomplete; use `vibecoding1c-mcp-select` or `vibecoding1c-mcp-setup -Force` for an explicit reselect. Remote LAN vibecoding1c MCP is the default and is discovered from `VIBECODING1C_MCP_REGISTRY_REPO` (default `http://gitlabserv01.itland.local/root/MCP-vibecoding1c-registry.git`); config-specific remote vibecoding1c MCP always requires an explicit per-server `configId` selection, even when the registry has one configuration. The `code` and `graph` selections do not inherit `configId` or `hostId` from each other. Developers can override each server to local. Local vibecoding1c MCP still clones or fast-forwards the private GitLab distribution from `VIBECODING1C_MCP_DISTRIBUTION_REPO` (default `http://gitlabserv01.itland.local/root/MCP-vibecoding1c.git`) into `%LOCALAPPDATA%\ITL\MCP\vibecoding1c\distribution`, rotates license keys into `%LOCALAPPDATA%\ITL\MCP\vibecoding1c`, allocates ports from the local registry, writes only managed entries for the single active client, reconciles default upstream `ai_rules_1c` MCP entries only when ready vibecoding1c replacements are available, and keeps project/branch vibecoding1c MCP out of neighboring worktrees. New development worktrees inherit a complete `master` selection and rematerialize ready `remote` and `local + project` endpoints in the worktree context without copying raw state. Use `VIBECODING1C_MCP_REGISTRY_PATH` and `VIBECODING1C_MCP_DISTRIBUTION_PATH` only as explicit manual checkout overrides.
- Vanessa UI MCP. Init/update caches the compatible `client_mcp.cfe` and `VAExtension*.cfe` and registers `itl-vanessa-ui`. Its first semantic tool call installs missing branch CFE tooling and starts a client-owned backend automatically. This remains distinct from `/itl-check`.
- External MCP. Treat future or user-provided MCP servers as a separate family. Preserve user-owned keys in every active-client config and remove only entries recorded in ITL managed state.
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

2. Run the one-step bootstrap script and wait for it to finish:

```powershell
powershell -ExecutionPolicy Bypass -File <source>\install-agent-1c-workflow.ps1 -ProjectRoot <project>
```

For package-copy verification or other non-init automation, add `-NoInit`. Do not expand the normal bootstrap into manual copy commands.

## Manual Recovery Copy Steps

Use these steps only when `install-agent-1c-workflow.ps1` is unavailable or failed before copying the managed files.

1. Copy the common skills into the target project:

```text
<project>/.agents/skills/1c-workflow/
<project>/.agents/skills/1c-workflow-fast/
<project>/.agents/skills/product-docs/
<project>/.agents/skills/itl-roctup-1c-data/
<project>/.agents/skills/itl-vanessa-ui-mcp/
```

2. Materialize the active client's native command/skill surface through the ITL adapter. For example, Kilo uses:

```text
<project>/.kilo/commands/
```

3. Copy the whole bootstrap templates directory into the target project before running the initialization helper:

```text
<project>/templates/
```

4. Create `.agent-1c/project.json` from `templates/project.json` when missing. Use the default `devBranchInfoBaseRoot` unless the developer explicitly requested a custom location.

5. Create `.agent-1c/dependency-lock.json` from `templates/dependency-lock.json` when missing. The template deliberately has no installed workflow commit. Root bootstrap passes its source checkout origin/ref/full commit into init, which records the files actually copied; a non-Git source records `source=path` with an empty commit. Keep the resulting lock committed when the team wants reproducible bootstrap pins; fresh mode updates it with resolved dependency revisions, URLs, and hashes.

6. Create `.agent-1c/tools.json` from `templates/tools.json` when missing. Keep it committed so the team can adjust required software checks and install suggestions.

7. Create `.dev.env` from `templates/dev.env.example` when missing. Fill local paths, secrets, web publication preference, and the chosen `DEPENDENCY_MODE`. Write it as UTF-8 and ensure `.dev.env` is ignored by Git.

8. Append `templates/gitignore.append` lines to `.gitignore` if absent.

9. Append `templates/AGENTS.append.md` to `AGENTS.md` only as a fallback when `AGENTS.md` does not already reference `USER-RULES.md`. Current `ai_rules_1c` creates and manages the normal root `AGENTS.md`; do not modify it just to add ITL notes.

10. Apply the managed ITL block from `templates/USER-RULES.append.md` to `USER-RULES.md`. New helpers wrap this block with markers so future `update-workflow` runs can replace it safely.

11. Copy the namespaced developer-facing documentation into the target project. Do not copy or overwrite the target project's root `README.md`:

```text
<project>/docs/itl-workflow/PROJECT-WORKFLOW.ru.md
<project>/docs/itl-workflow/FEATURE-DEVELOPMENT.ru.md
<project>/docs/itl-workflow/MODES-AND-SETTINGS.ru.md
<project>/docs/itl-workflow/DEV-ENV-REFERENCE.ru.md
```

12. Do not add detailed workflow text to `AGENTS.md`. Keep ITL-specific rules in `USER-RULES.md` so upstream-managed `AGENTS.md` can continue to update cleanly.

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
- Vanessa Automation: check `VANESSA_AUTOMATION_EPF` or `.agent-1c/tools/vanessa-automation`; if missing, diagnostic output can mention `install-vanessa-automation`, while normal init installs it automatically.
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

`install-vanessa-automation` downloads `vanessa-automation-single.*.zip` from the official `Pr-Mex/vanessa-automation` GitHub release, logs SHA256, unpacks the EPF under `.agent-1c/tools/vanessa-automation`, creates `tests/features` and `build/test-results/vanessa`, and saves `VANESSA_*` paths to `.dev.env`. The helper also uses `VANESSA_TEST_PORT_RANGE=48051..48150` by default for final verify and stores the assigned TestClient port in branch state.

ROCTUP is exposed through the pre-registered `itl-roctup-data` stdio server and does not require web publication or manual helper actions.

Vanessa UI is exposed through `itl-vanessa-ui`. Its backend and CFE preparation are private first-call behavior; the final verify gate remains packet `StartFeaturePlayer` in `TESTMANAGER -> TESTCLIENT` mode.

`vibecoding1c-mcp-setup` refreshes the endpoint registry, applies `.agent-1c/mcp/vibecoding1c-selection.json`, connects selected endpoints, and writes only managed entries for the single active client while preserving user keys. It never writes user-global Codex config. Use the select/status/update actions for their existing narrow purposes.

Dedicated vibecoding1c MCP hosts are prepared without the agent through `vibecoding1c-mcp-host/install-vibecoding1c-mcp-host.ps1`. The host can read configuration XML files from a Git `sourceRepo` or a local `sourcePath` and can publish shared BookStack and Mantis MCP endpoints. Local `sourcePath` folders can be refreshed manually with `-Action dump-config`, which updates the source infobase from 1C configuration repository storage and then runs incremental `/DumpConfigToFiles` when `ConfigDumpInfo.xml` exists. The host publishes only `registry.json` endpoint/freshness metadata to GitLab; secrets, local paths, infobase credentials, `ONEC_AI_TOKEN`, BookStack tokens, and `MANTIS_API_TOKEN` stay in ignored `vibecoding1c-mcp-host/host.config.json`, the host-local distribution `config.env`, or local environment.

The current workflow refreshes the ITL workflow package, Vanessa Automation, and ROCTUP MCP Toolkit in fresh mode. The configured immutable `aiRules.ref` remains pinned and is verified against its dependency-lock commit. The helper records the resolved workflow package and `ai_rules_1c` commits, Vanessa URL/version/SHA256, ROCTUP asset URL/version/SHA256, and downloaded archive hashes in `.agent-1c/dependency-lock.json`. For reproducible bootstrap, choose `DEPENDENCY_MODE=locked`; the helper will use only pinned values and stop when a required pin or hash is missing or mismatched.

## Update Existing ITL Workflow

For projects that already have this workflow installed, do not rerun `init-project`. First update the installed helper/workflow files from this bootstrap package if the project predates `update-workflow`, then use the normal maintenance command:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action update-workflow
```

Ask the active agent to update the ITL workflow or run the helper action directly. The command runs only from the `master` worktree, updates managed files (`.agents/skills/1c-workflow*`, `.agents/skills/product-docs`, `.agents/skills/itl-roctup-1c-data`, `.agents/skills/itl-vanessa-ui-mcp`, command templates, `templates/`, and workflow docs), reconciles the native ITL surface for the active client, preserves local runtime/project state, records `workflowPackage` in `.agent-1c/dependency-lock.json`, refreshes ROCTUP MCP and Vanessa UI MCP CFE caches, and runs pinned `update-ai-rules` unless `-SkipAiRules` is passed.

Optional source overrides:

```powershell
$env:ITL_WORKFLOW_SOURCE_PATH = "D:\Git\1c-agent-workflow"
$env:ITL_WORKFLOW_REPO = "https://github.com/xmentosx/1c-agent-workflow.git"
$env:ITL_WORKFLOW_REF = "master"
```

After the update, review and commit tracked changes in `master`. Active `itldev/*` worktrees do not update automatically; merge or run `/itl-refresh` so each receives the facade config. A facade install/upgrade needs one client reload; later backend starts do not.

## Install ai_rules_1c

After the first source infobase sync and configuration dump, let the ITL helper install project rules from `aiRules.repo` and immutable `aiRules.ref` in `.agent-1c/project.json`. The standard ITL path never clones or pulls a moving upstream branch directly. It checks the configured tag against `.agent-1c/dependency-lock.json` and runs that source's official installer.

For normal initialization, use only the monitored root bootstrap. For an already initialized project, use `update-ai-rules` below. Direct installer invocation is a non-standard recovery path for an explicitly configured custom repository; select and verify an immutable ref/commit first instead of following remote HEAD.

The workflow installs exactly one client from `aiRules.tools`. The wizard choice is mandatory. Legacy `["codex","kilocode"]` migrates to `["kilocode"]`; other multi-client combinations stop for an explicit choice. Switch later only from clean `master` with `/itl-switch-client <client>`; it snapshots state, removes hash-matching managed assets, clears incompatible `SUBAGENT_MODEL_*`, installs the pinned adapter, and leaves other worktrees and RTK integration unchanged.

For an explicit configured-source compatibility check in the workflow repository, run:

```powershell
.\scripts\test-ai-rules-compatibility.ps1
```

To refresh `ai_rules_1c` after initialization, run:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action update-ai-rules
```

Ask the active client to update ITL rules. The helper runs only the pinned source installer, reconciles MCP for that client when ready, records the exact commit, reapplies the managed `USER-RULES.md` block, preserves `LLM-RULES.md`, regenerates native ITL commands and, when enabled, the Kilo/OpenCode routine agent, and avoids modifying source-managed `AGENTS.md` when it already points to `USER-RULES.md`.

`ITL_ROUTINE_MODE` is non-interactive and defaults to `off`. In `off`, every `/itl*` command runs in the main agent. In `auto`, `/itl`, `/itl-status`, and `/itl-litemode` remain direct while the seven long commands use `itl-routine` only when `SUBAGENT_MODEL_LIGHT` names an explicit inexpensive model. In `on`, all ten commands use the routine and an explicit `SUBAGENT_MODEL_LIGHT` is required. Empty or unknown values safely resolve to `off`; the helper never lets the routine inherit the parent model.

## Run Initial Lifecycle

After installing the workflow files, run the monitored script wizard:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\run-agent-1c-window.ps1 -- -Action init-project -InitMode wizard
```

The wizard opens in an external PowerShell window, writes `.agent-1c/runs/<run>/status.json` plus `console.log`, collects setup values, writes `.dev.env` and `.agent-1c/project.json`, and then performs:

The agent must wait for the monitored launcher process to finish. A background launch that returns immediately makes the agent miss completion, and a persistent PowerShell session leaves a stale prompt open after the helper has already written its status. The launcher writes terminal `failed` status itself when the helper exits or times out without writing `succeeded`/`failed`.

On a repeated bootstrap, only `succeeded` with `exitCode=0`, `stage=init.complete`, ordered timestamps, and the current project root is terminal success. Otherwise the launcher resumes saved settings automatically: stages before a proven dump rerun 1C work, while `init.commit-dump` or later validates and commits the existing dump without repeating `/DumpConfigToFiles`.

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

New branch commands create a sibling Git worktree by default and leave the current project folder on `master`. After creation, report the printed worktree path and tell the developer to open a separate window of the selected agent or IDE there. Use `-UseCurrentWorktree` only when the developer explicitly asks for the legacy single-folder checkout mode.

`/itl` must present the lifecycle as a process panel, not as a flat command list: current state, recommended next step, lifecycle path, visible slash commands, then grouped additional helper actions. In a fresh clean `itldev/*` branch with `verification missing`, recommend choosing a development mode (`quick-fix`, `/opsx-explore`, or `/opsx-propose`), not `/itl-check`. Recommend `/itl-check` after checkable configuration/extension/Vanessa feature changes or stale/failed/unknown verification.

The native `/itl` command wrapper must return helper `-Action help` stdout verbatim in one panel. It must not summarize, translate, split the panel into custom sections, merge OpenSpec into visible slash commands, omit `Lifecycle:` or `Additional helper actions:`, or append a "no lifecycle actions executed" note. Existing open worktrees may have a stale ignored command surface; regenerate it by running `update-workflow` from `master`, `/itl-refresh` in the dev worktree, or `switch-dev-branch` when changing branches.

Advanced/helper actions such as extension setup/dump, project initialization, workflow/rules update, and vibecoding1c MCP remain available through natural-language requests or direct PowerShell helper actions. ROCTUP/Vanessa on-demand backend control is private and is not a user command.

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
