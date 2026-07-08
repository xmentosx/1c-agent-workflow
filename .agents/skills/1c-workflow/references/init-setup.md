# Initialization And Setup Reference

Use this reference for first-time bootstrap, tool readiness, workflow refresh, and upstream rules refresh. Routine installed-project actions should use `1c-workflow-fast` or the helper directly.

## State Files

Create and maintain:

- `.agent-1c/project.json`: non-secret project settings.
- `.agent-1c/tools.json`: configurable software checks and install suggestions.
- `.agent-1c/dependency-lock.json`: committed dependency lock manifest for the ITL workflow package, `ai_rules_1c`, Vanessa Automation, ROCTUP MCP Toolkit, and downloadable archive URLs/SHA256. Default dependency mode is `fresh`; `locked` mode uses only pinned values.
- `.agent-1c/dev-branches/<safe-dev-branch-name>.json`: local branch runtime state; ignored by Git.
- `.agent-1c/mcp/state.json` and `.agent-1c/mcp/vibecoding1c-selection.json`: local MCP runtime and developer selection; ignored by Git.
- `.dev.env`: local secrets and machine-specific values; never commit it.
- `.agents/skills/1c-workflow/` and `.agents/skills/1c-workflow-fast/`: shared skills.
- `.agents/skills/1c-workflow/kilo-command-templates/`: tracked canonical Kilo templates.
- `.kilo/commands/`: ignored context-specific generated Kilo slash wrappers.
- `.codex/config.toml` and `.kilo/kilo.json*`: ignored local MCP client state.

Never store passwords in committed files. Write workflow state and `.dev.env` as UTF-8 and preserve Cyrillic paths exactly.

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
  "devBranchWorktreeRoot": ""
}
```

Use `.dev.env` for secrets, passwords, web publication values, local tool paths, `DEPENDENCY_MODE`, `VERIFICATION_POLICY`, and optional overrides. Empty password values mean the password is not set.

## Required Questions

Ask only for values the helper cannot collect or infer:

- Project/source infobase kind and path/server/name.
- Whether the source uses 1C configuration repository storage.
- Repository path/user/password only when source storage is enabled.
- 1C platform executable. First inspect standard `C:\Program Files\1cv8` and `C:\Program Files (x86)\1cv8` version folders and offer installed versions.
- Whether branch infobases should be web-published by default. If no, store `WEB_PUBLISH_BY_DEFAULT=false` and `WEB_PUBLISH_AUTO=false`.
- If branch infobases should be web-published, whether to attempt automatic publication during branch creation. Store `WEB_PUBLISH_AUTO=true|false`; if automatic publication is requested, collect existing `webinst`/publication settings but never install a web server.
- Whether dependencies are `fresh` or `locked`. Default is `fresh`; `locked` requires a complete `.agent-1c/dependency-lock.json`.
- Missing Vanessa Automation and ROCTUP MCP Toolkit are installed automatically during init/update; do not ask whether they are needed.

Ask one raw value at a time unless the agent surface supports structured fields. Do not ask for `KEY=value` blocks. For optional passwords, first ask whether the password is set.

## INIT_PROJECT

Goal: create baseline project state.

0. If the target project does not have workflow files yet, start with the one-step bootstrap script from the workflow package:

   ```powershell
   powershell -ExecutionPolicy Bypass -File <source>\install-agent-1c-workflow.ps1 -ProjectRoot <project>
   ```

   The bootstrap script copies only managed workflow files (`.agents/skills/1c-workflow*`, `templates/`, root docs/guides, and `install-agent-1c-workflow.ps1`) and then starts the monitored launcher. Do not expand normal initialization into manual copy steps.

1. In an already installed project, start with the monitored foreground launcher:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\run-agent-1c-window.ps1 -- -Action init-project -InitMode wizard
   ```

2. The launcher opens the wizard in an external PowerShell window, writes `.agent-1c/runs/<run>/status.json` and `console.log`, validates the helper path itself, and lets the agent detect completion. Do not call `agent-1c.ps1 -Action init-project -InitMode wizard` directly by default, do not run a separate `Test-Path` preflight, do not wrap it in background PowerShell, and do not set `timeout: 0`. Use a positive long timeout. Use `-KeepWindowOnFailure` only for explicit manual debugging.
3. If terminal input is unavailable, do not collect the initialization questionnaire in chat and do not continue the lifecycle manually. Use the monitored wizard command, or JSON mode only when explicitly requested or an answers file already exists.
4. Create `.agent-1c/project.json`, `.agent-1c/tools.json`, `.agent-1c/dependency-lock.json`, and `.dev.env` if missing.
5. Run tool checks, initialize Git, checkout/create `master`, update the source infobase from storage when configured, and dump configuration files to `src/cf`.
6. Initial dump must produce `src/cf/ConfigDumpInfo.xml`; later dumps use incremental `-update -force` when that file exists. Stop if `src/cf` is non-empty without `ConfigDumpInfo.xml`.
7. Install/cache ROCTUP MCP Toolkit, install `ai_rules_1c` using the current agent target, record resolved dependency pins in the dependency lock, reconcile default upstream MCP client entries only when ready vibecoding1c replacements are available, generate Kilo wrappers when applicable, and apply the ITL overlay to `USER-RULES.md`.
8. Commit rules and workflow files when there are changes.

## Tool Actions

- `check-tools`: validate configured platform, Git, existing web publication tooling when automatic publication is enabled/requested, Vanessa Automation, and writable workflow folders.
- `list-platforms`: show discovered 1C platform versions.
- `detect-web-publication`: detect existing web publication tooling and show usable `.dev.env` values.
- `configure-web-publication`: run the interactive web publication policy/settings wizard after init.
- `publish-dev-branch`: publish or record publication for an existing development branch.
- `install-vanessa-automation`: download `vanessa-automation-single.*.zip`, verify SHA256 when available, unpack under `.agent-1c/tools/vanessa-automation`, and save `VANESSA_*` paths.
- `install-roctup-mcp` / `update-roctup-mcp`: download/cache the OS-specific `MCP_Toolkit*.epf`, verify SHA256 in locked mode, cache upstream skills under ignored `.agent-1c/tools/roctup-mcp-toolkit/skills`, and save `ROCTUP_*` paths.

## UPDATE_WORKFLOW

Goal: refresh the installed ITL workflow package without rerunning initialization.

1. Run only from the `master` worktree.
2. Require a clean tracked Git worktree while ignoring local runtime state such as `.dev.env`, `.agent-1c/mcp/`, `.codex/config.toml`, and `.kilo/kilo.json*`.
3. Resolve the package source from `ITL_WORKFLOW_SOURCE_PATH` or clone/update `ITL_WORKFLOW_REPO` and `ITL_WORKFLOW_REF` (`https://github.com/xmentosx/1c-agent-workflow.git`, `master` by default).
4. Copy only managed workflow files: `.agents/skills/1c-workflow*`, Kilo templates, `templates/`, `install-agent-1c-workflow.ps1`, `README.md`, `AGENT-INSTALL.md`, `DEVELOPER-GUIDE.ru.md`, `DEV-BRANCH-DEVELOPMENT.ru.md`, `VANESSA-TESTS-GUIDE.md`, and the compatibility stub `VANESSA-TESTS-GUIDE.ru.md`.
5. Preserve local runtime/project state. Do not overwrite `.dev.env`, `.agent-1c/dev-branches/`, `.agent-1c/mcp/`, `.codex/config.toml`, `.kilo/kilo.json*`, or existing project/tools config.
6. Record `workflowPackage.repo/ref/commit/source/updatedAt`, reapply `USER-RULES.md`, refresh ROCTUP MCP cache, run `update-ai-rules` unless `-SkipAiRules` is explicit, and leave tracked changes for review.
7. Do not update active `itldev/*` worktrees automatically; print whether MCP client config was reconciled or preserved as upstream fallback, plus follow-up commands for MCP setup/update, branch merge or `/itl-refresh`, and branch-local ROCTUP/Vanessa MCP restart when used.

## UPDATE_AI_RULES

Goal: refresh upstream `ai_rules_1c` while preserving the ITL overlay.

1. Clone or update the configured `ai_rules_1c` repo under `%TEMP%\ai_rules_1c`.
2. In `fresh`, checkout remote HEAD; in `locked`, checkout the pinned commit/ref and stop when missing.
3. Run the upstream installer with `update` when `.ai-rules.json` exists, otherwise `init` with the configured agent target.
4. Preserve upstream files marked `userModified`; use `-Force` only after explicit developer intent.
5. Reconcile default upstream MCP client entries from ignored Codex/Kilo config only after writing ready vibecoding1c-managed replacements; if selection/state is missing or incomplete, preserve upstream entries and print `vibecoding1c-mcp-setup` as the recovery action.
6. Reapply the managed ITL block in `USER-RULES.md` from `templates/USER-RULES.append.md`; normally do not append to `AGENTS.md` when it already references `USER-RULES.md`.
7. Record the resolved `ai_rules_1c` commit in `.agent-1c/dependency-lock.json`.
