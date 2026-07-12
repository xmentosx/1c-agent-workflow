# Initialization And Setup Reference

Use this reference for first-time bootstrap, tool readiness, workflow refresh, and configured rules refresh. Routine installed-project actions should use `1c-workflow-fast` or the helper directly.

## State Files

Create and maintain:

- `.agent-1c/project.json`: non-secret project settings.
- `.agent-1c/tools.json`: configurable software checks and install suggestions.
- `.agent-1c/dependency-lock.json`: committed dependency lock manifest for the ITL workflow package, `ai_rules_1c`, Vanessa Automation, ROCTUP MCP Toolkit, and the two Vanessa UI MCP CFE artifacts with URLs/SHA256. Default dependency mode is `fresh`; `locked` mode uses only pinned values.
- `.agent-1c/dev-branches/<safe-dev-branch-name>.json`: local branch runtime state; ignored by Git.
- `.agent-1c/mcp/state.json` and `.agent-1c/mcp/vibecoding1c-selection.json`: local MCP runtime and developer selection; ignored by Git.
- `.dev.env`: local secrets and machine-specific values; never commit it.
- `.agents/skills/1c-workflow/`, `.agents/skills/1c-workflow-fast/`, `.agents/skills/product-docs/`, `.agents/skills/itl-roctup-1c-data/`, and `.agents/skills/itl-vanessa-ui-mcp/`: shared skills installed with the workflow package.
- `.agents/skills/1c-workflow/kilo-command-templates/`: tracked canonical Kilo templates.
- `.kilo/commands/itl*.md`: ignored context-specific ITL Kilo wrappers. OpenSpec command files are managed by `ai_rules_1c` for each selected client.
- `.codex/config.toml` and `.kilo/kilo.json*`: ignored local MCP client state.

Never store passwords in committed files. Write workflow state and `.dev.env` as UTF-8 and preserve Cyrillic paths exactly.

## Project Config Shape

Use this as `.agent-1c/project.json`:

```json
{
  "schemaVersion": 1,
  "masterBranch": "master",
  "baseConfigurationVersion": "PM5",
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
  "aiRules": {
    "repo": "https://github.com/xmentosx/itl_ai_rules_1c.git",
    "ref": "itl-main-a421cf44-r2",
    "tools": ["codex", "kilocode"]
  }
}
```

Use `.dev.env` for secrets, passwords, web publication values, local tool paths, `DEPENDENCY_MODE`, `VERIFICATION_POLICY`, and optional overrides. `GITHUB_TOKEN` (then `GH_TOKEN`) optionally authenticates GitHub API requests; without a token, a fresh dependency resolve falls back to a compatible lock entry only after GitHub rate limiting. Empty password values mean the password is not set.

## Required Questions

Ask only for values the helper cannot collect or infer:

- Project/source infobase kind and path/server/name.
- Base configuration version: `PM4` or `PM5`. Default is `PM5`; store it in committed `.agent-1c/project.json` as `baseConfigurationVersion`.
- Whether the source uses 1C configuration repository storage.
- Repository path/user/password only when source storage is enabled.
- 1C platform executable. First inspect standard `C:\Program Files\1cv8` and `C:\Program Files (x86)\1cv8` version folders and offer installed versions.
- Whether branch infobases should be web-published by default. If no, store `WEB_PUBLISH_BY_DEFAULT=false` and `WEB_PUBLISH_AUTO=false`.
- If branch infobases should be web-published, whether to attempt automatic publication during branch creation. Store `WEB_PUBLISH_AUTO=true|false`; if automatic publication is requested, collect existing `webinst`/publication settings but never install a web server.
- Whether dependencies are `fresh` or `locked`. Default is `fresh`; `locked` requires a complete `.agent-1c/dependency-lock.json`.
- Missing Vanessa Automation, ROCTUP MCP Toolkit, and Vanessa UI MCP CFE artifacts are cached automatically during init/update; do not ask whether they are needed. CFE installation into a branch infobase and the UI MCP server itself remain on demand.

Ask one raw value at a time unless the agent surface supports structured fields. Do not ask for `KEY=value` blocks. For optional passwords, first ask whether the password is set.

## INIT_PROJECT

Goal: create baseline project state.

0. If the target project does not have workflow files yet, start with the one-step bootstrap script from the workflow package:

   ```powershell
   powershell -ExecutionPolicy Bypass -File <source>\install-agent-1c-workflow.ps1 -ProjectRoot <project>
   ```

   The bootstrap script copies only managed workflow files (`.agents/skills/1c-workflow*`, `.agents/skills/product-docs`, `.agents/skills/itl-roctup-1c-data`, `.agents/skills/itl-vanessa-ui-mcp`, `templates/`, root docs/guides, and `install-agent-1c-workflow.ps1`) and then starts the monitored launcher. Do not expand normal initialization into manual copy steps.

1. In an already installed project, start with the monitored foreground launcher:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\run-agent-1c-window.ps1 -- -Action init-project -InitMode wizard
   ```

2. The launcher opens the wizard in an external PowerShell window, writes `.agent-1c/runs/<run>/status.json` and `console.log`, validates the helper path itself, and lets the agent detect completion. Do not call `agent-1c.ps1 -Action init-project -InitMode wizard` directly by default, do not run a separate `Test-Path` preflight, do not wrap it in background PowerShell, and do not set `timeout: 0`. The launcher has a default 60 minute limit (`-MaxWaitSeconds 3600`; `0` disables only when explicit), while the bootstrap forwards `-InitMaxWaitSeconds 3600` by default. Use a positive long outer timeout greater than the launcher limit. Use `-KeepWindowOnFailure` only for explicit manual debugging.
3. If terminal input is unavailable, do not collect the initialization questionnaire in chat and do not continue the lifecycle manually. Use the monitored wizard command, or JSON mode only when explicitly requested or an answers file already exists.
4. Create `.agent-1c/project.json`, `.agent-1c/tools.json`, `.agent-1c/dependency-lock.json`, and `.dev.env` if missing.
5. Run tool checks, initialize Git, checkout/create `master`, update the source infobase from storage when configured, and dump configuration files to `src/cf`.
6. Initial dump must produce `src/cf/ConfigDumpInfo.xml`; later dumps use incremental `-update -force` when that file exists. Stop if `src/cf` is non-empty without `ConfigDumpInfo.xml`.
7. Install/cache ROCTUP MCP Toolkit and Vanessa UI MCP CFE artifacts, install `ai_rules_1c` for every configured `aiRules.tools` client (Codex and Kilo by default), record resolved dependency pins in the dependency lock, reconcile default upstream MCP client entries only when ready vibecoding1c replacements are available, generate Kilo ITL wrappers when Kilo is installed, and apply the ITL overlay to `USER-RULES.md`.
8. Commit rules and workflow files when there are changes.

## Tool Actions

- `check-tools`: validate configured platform, Git, existing web publication tooling when automatic publication is enabled/requested, Vanessa Automation, and writable workflow folders.
- `list-platforms`: show discovered 1C platform versions.
- `detect-web-publication`: detect existing web publication tooling and show usable `.dev.env` values.
- `configure-web-publication`: run the interactive web publication policy/settings wizard after init.
- `publish-dev-branch`: publish or record publication for an existing development branch.
- `install-vanessa-automation`: download `vanessa-automation-single.*.zip`, verify SHA256 when available, unpack under `.agent-1c/tools/vanessa-automation`, and save `VANESSA_*` paths.
- `install-roctup-mcp` / `update-roctup-mcp`: download/cache the OS-specific `MCP_Toolkit*.epf`, verify SHA256 in locked mode, cache upstream skills under ignored `.agent-1c/tools/roctup-mcp-toolkit/skills`, and save `ROCTUP_*` paths.
- init/update: cache `client_mcp.cfe` and `VAExtension*.cfe` for Vanessa UI MCP, verify SHA256 in locked mode, save absolute `VANESSA_MCP_*_CFE_PATH` values for future worktrees, and never start the MCP or install CFE into an infobase as part of caching.

## UPDATE_WORKFLOW

Goal: refresh the installed ITL workflow package without rerunning initialization.

1. Run only from the `master` worktree.
2. Require a clean tracked Git worktree while ignoring local runtime state such as `.dev.env`, `.agent-1c/mcp/`, `.codex/config.toml`, and `.kilo/kilo.json*`.
3. Resolve the package source from `ITL_WORKFLOW_SOURCE_PATH` or clone/update `ITL_WORKFLOW_REPO` and `ITL_WORKFLOW_REF` (`https://github.com/xmentosx/1c-agent-workflow.git`, `master` by default).
4. Copy only managed workflow files: `.agents/skills/1c-workflow*`, `.agents/skills/product-docs`, `.agents/skills/itl-roctup-1c-data`, `.agents/skills/itl-vanessa-ui-mcp`, Kilo templates, `templates/`, `install-agent-1c-workflow.ps1`, `README.md`, `AGENT-INSTALL.md`, `DEVELOPER-GUIDE.ru.md`, `DEV-BRANCH-DEVELOPMENT.ru.md`, `VANESSA-TESTS-GUIDE.md`, and the compatibility stub `VANESSA-TESTS-GUIDE.ru.md`.
5. Preserve local runtime/project state. Do not overwrite `.dev.env`, `.agent-1c/dev-branches/`, `.agent-1c/mcp/`, `.codex/config.toml`, `.kilo/kilo.json*`, or existing project/tools config.
6. Record `workflowPackage.repo/ref/commit/source/updatedAt`, reapply `USER-RULES.md`, refresh ROCTUP MCP and Vanessa UI MCP CFE caches, run `update-ai-rules` unless `-SkipAiRules` is explicit, and leave tracked changes for review.
7. Do not update active `itldev/*` worktrees automatically; print whether MCP client config was reconciled or preserved as upstream fallback, plus follow-up commands for MCP setup/update, branch merge or `/itl-refresh`, and branch-local ROCTUP/Vanessa UI MCP restart when used.

## UPDATE_AI_RULES

Goal: refresh the configured `ai_rules_1c` source while preserving the ITL overlay.

1. Clone or update the configured `ai_rules_1c` repo under `%TEMP%\ai_rules_1c`.
2. When `aiRules.ref` is configured, both `fresh` and `locked` checkout that immutable tag. The controlled fork accepts only `itl-*`; verify that the tag resolves to the commit recorded in the dependency lock, and never consume fork `main`.
3. In `locked`, use the lock repo/ref/commit and stop when required values are missing or disagree. Remote HEAD is allowed only for an explicitly configured legacy/custom repository without `aiRules.ref`; it is never the standard ITL path.
4. Run the configured source installer with `update` when `.ai-rules.json` exists, otherwise `init` with configured clients. Afterward add each configured client absent from `.ai-rules.json`; do not remove additional installed clients automatically.
5. Preserve configured-source files marked `userModified`; use `-Force` only after explicit developer intent.
6. Reconcile default configured-source MCP client entries from ignored Codex/Kilo config only after writing ready vibecoding1c-managed replacements; if selection/state is missing or incomplete, preserve those entries and print `vibecoding1c-mcp-setup` as the recovery action.
7. Reapply the managed ITL block in `USER-RULES.md` from `templates/USER-RULES.append.md`; normally do not append to `AGENTS.md` when it already references `USER-RULES.md`.
8. Record the resolved `ai_rules_1c` commit in `.agent-1c/dependency-lock.json`.
