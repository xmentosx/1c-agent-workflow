# Initialization And Setup Reference

Use this reference for first-time bootstrap, tool readiness, workflow refresh, and configured rules refresh. Routine installed-project actions should use `1c-workflow-fast` or the helper directly.

## State Files

Create and maintain:

- `.agent-1c/project.json`: non-secret project settings.
- `.agent-1c/tools.json`: configurable software checks and install suggestions.
- `.agent-1c/dependency-lock.json`: committed dependency lock manifest for workflow/rules, Vanessa Automation, compatible ROCTUP/Vanessa backends, and the `itl-ondemand-mcp` Windows x64 executable with URLs/SHA256. Default dependency mode is `fresh`; `locked` uses only pins.
- `.agent-1c/dev-branches/<safe-dev-branch-name>.json`: local branch runtime state; ignored by Git.
- `.agent-1c/source-infobase-unsafe-action-protection.json`: local confirmation bound to the source infobase kind/identity and `IB_USER`; ignored by Git and never contains the password.
- `.agent-1c/mcp/state.json` and `.agent-1c/mcp/vibecoding1c-selection.json`: local MCP runtime and developer selection; ignored by Git.
- `.dev.env`: local secrets and machine-specific values; never commit it.
- `.agents/skills/1c-workflow/`, `.agents/skills/1c-workflow-fast/`, `.agents/skills/product-docs/`, `.agents/skills/itl-roctup-1c-data/`, and `.agents/skills/itl-vanessa-ui-mcp/`: shared skills installed with the workflow package.
- `.agents/skills/1c-workflow/kilo-command-templates/`: tracked canonical Kilo templates.
- Ignored native `itl*` commands, skills, or prompts for the one active client. Codex receives context-specific `.agents/skills/itl*/SKILL.md` wrappers with explicit-only invocation. OpenSpec commands remain owned by `ai_rules_1c`.
- One active-client MCP config: Codex `.codex/config.toml`, Kilo `.kilo/kilo.json`, Claude `.mcp.json`, Cursor `.cursor/mcp.json`, or OpenCode root `opencode.json`.

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
  "sourceInfoBaseUnsafeActionProtectionMode": "manual-confirm",
  "repositoryPath": "",
  "dependencyMode": "fresh",
  "verificationPolicy": "warn",
  "devBranchInfoBaseRoot": ".agent-1c/infobases/dev-branches",
  "branchSeedRoot": ".agent-1c/branch-seed",
  "devBranchWorktreeRoot": "",
  "serverBaseCopyScript": "",
  "aiRules": {
    "repo": "https://github.com/xmentosx/itl_ai_rules_1c.git",
    "ref": "itl-main-b4d9875b-r9",
    "tools": []
  }
}
```

Use `.dev.env` for project-local secrets, passwords, web publication values, local tool paths, `DEPENDENCY_MODE`, `VERIFICATION_POLICY`, and optional overrides. A file source infobase may additionally hold the explicitly user-approved, unencrypted `.itl-source-credentials.json` described below so several projects can reuse the same connection. `DESIGNER_MAX_WORKING_SET_MB` overrides the project-level `designerMaxWorkingSetMb` limit for automated Designer processes in the current worktree; the default is 10240 MB and `0` disables the guard. `DESIGNER_OPERATION_TIMEOUT_SECONDS` bounds every automated Designer operation while it waits for command-specific completion evidence (default 3600 seconds). `DESIGNER_STALL_WARNING_SECONDS` marks an operation `stalled-suspected` after no CPU/log/process progress evidence (default 300 seconds). `DESIGNER_STALL_TIMEOUT_SECONDS` then fails after sustained lack of evidence (default 600 seconds) and stops exact owned Designer PIDs. Neither replaces the independent memory guard or overall hard timeout. `DESIGNER_DUMP_STABILITY_SECONDS` controls how long file or `/Out` evidence must remain unchanged before acceptance (default 5 seconds). `GITHUB_TOKEN` (then `GH_TOKEN`) optionally authenticates GitHub API requests; without a token, a fresh dependency resolve falls back to a compatible lock entry only after GitHub rate limiting. Empty password values mean the password is not set.

`branchSeedRoot` stores one ignored latest-only seed per hashed source identity and may point to a shared absolute directory through local `BRANCH_SEED_ROOT`. For a server source, `serverBaseCopyScript` must implement schema v2: `-Operation capabilities` returns JSON with `schemaVersion: 2`, `restore-seed`, and `event-log-baseline`; `-Operation event-log-baseline` returns schema v2 signature JSON without raw log files; `-Operation restore-seed` accepts `ProjectRoot`, `DevBranchName`, `SeedArtifactPath`, and `DevBranchInfoBasePath`. Older providers fail closed with `SERVER_SEED_PROVIDER_UPGRADE_REQUIRED`.

## Windows Path Budgets

- The absolute initial project root must be at most 35 characters. The bootstrap and `init-project` reject longer paths before mutation and explain that the reserve is required for Windows `MAX_PATH=260` and long 1C configuration/extension source names.
- Only when the requested root is under the current user profile does the error recommend the exact `<user-profile>\W` parent and calculate the project-folder name available there.
- A newly created development worktree path `<parent>\<project-folder>-<safe-branch>` must be at most 50 characters. The error calculates the safe-branch limit only from those fixed path parts; it does not inspect current source files.
- Configuration, extension, and Vanessa install transactions use the ignored project-local `.tx` directory with one-letter operation slots. Successful operations remove their slot and the empty `.tx` root.

## Required Questions

Ask only for values the helper cannot collect or infer:

- One mandatory active client: `codex`, `kilocode`, `claude-code`, `cursor`, or `opencode`.
- Project/source infobase kind and path/server/name.
- For a file source, read `.itl-source-credentials.json` beside `1Cv8.1CD` when the developer accepts reuse (`yes` by default); otherwise collect values and offer to save them there (`yes` by default). The unencrypted JSON contains only `ibUser`, `ibPassword`, `repositoryPath`, `repositoryUser`, and `repositoryPassword`; an empty repository path means storage is disabled. Never use this shared-file behavior for a server infobase.
- Base configuration version: `PM4` or `PM5`. Default is `PM5`; store it in committed `.agent-1c/project.json` as `baseConfigurationVersion`.
- Whether the source uses 1C configuration repository storage, unless that answer was inferred from an accepted file-infobase parameter file.
- Repository path/user/password only when source storage is enabled.
- 1C platform executable. First inspect standard `C:\Program Files\1cv8` and `C:\Program Files (x86)\1cv8` version folders and offer installed versions.
- Whether branch infobases should be web-published by default. If no, store `WEB_PUBLISH_BY_DEFAULT=false` and `WEB_PUBLISH_AUTO=false`.
- If branch infobases should be web-published, whether to attempt automatic publication during branch creation. Store `WEB_PUBLISH_AUTO=true|false`; if automatic publication is requested, collect existing `webinst`/publication settings but never install a web server.
- Source unsafe-action protection mode: `manual-confirm` asks against the source infobase and stores a local context-bound confirmation, `defer` leaves branch creation to confirm its copy, and `confirmed` trusts an explicit external confirmation. JSON/configured init must provide this value; the wizard uses `manual-confirm`.
- Missing Vanessa Automation, ROCTUP MCP Toolkit, and Vanessa UI MCP CFE artifacts are cached automatically during init/update; do not ask whether they are needed. CFE installation into a branch infobase and the UI MCP server itself remain on demand.

The normal wizard does not ask for dependency mode and always records `fresh`. Keep `locked` available only through an explicit JSON/configured answer or a deliberate post-init configuration change; it requires a complete `.agent-1c/dependency-lock.json`.

Ask one raw value at a time unless the agent surface supports structured fields. Do not ask for `KEY=value` blocks. For optional passwords, first ask whether the password is set.

## INIT_PROJECT

Goal: create baseline project state.

0. If the target project does not have workflow files yet, start with the one-step bootstrap script from the workflow package:

   ```powershell
   powershell -ExecutionPolicy Bypass -File <source>\install-agent-1c-workflow.ps1 -ProjectRoot <project>
   ```

   The bootstrap script copies only managed workflow files (`.agents/skills/1c-workflow*`, `.agents/skills/product-docs`, `.agents/skills/itl-roctup-1c-data`, `.agents/skills/itl-vanessa-ui-mcp`, `docs/itl-workflow/`, `templates/`, `AGENT-INSTALL.md`, and `install-agent-1c-workflow.ps1`) and then starts the monitored launcher. It never overwrites the target project's `README.md`. It passes the source checkout origin/ref/full commit into init so `workflowPackage` records the files actually copied; a non-Git source is recorded as `source=path` with an empty commit. Do not expand normal initialization into manual copy steps.

1. In an already installed project, start with the monitored foreground launcher:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\run-agent-1c-window.ps1 -- -Action init-project -InitMode wizard
   ```

2. The launcher opens the wizard in an external PowerShell window, writes `.agent-1c/runs/<run>/status.json` and `console.log`, validates the helper path itself, and lets the agent detect completion. A no answer at the initial project-root confirmation writes terminal `cancelled` before helper-side project mutation. The launcher removes its cancelled run artifacts; the bootstrap installer restores managed paths to their exact pre-copy state and preserves unrelated project files. Cancellation is a final developer decision and must not be retried unless initialization is explicitly requested again. Do not call `agent-1c.ps1 -Action init-project -InitMode wizard` directly by default, do not run a separate `Test-Path` preflight, do not wrap it in background PowerShell, and do not set `timeout: 0`. The launcher has a default 60 minute limit (`-MaxWaitSeconds 3600`; `0` disables only when explicit), while the bootstrap forwards `-InitMaxWaitSeconds 3600` by default. Use a positive long outer timeout greater than the launcher limit. Use `-KeepWindowOnFailure` only for explicit manual debugging.
3. Use `timeout_ms >= 3900000`. If the outer shell interrupts init, repeat the same bootstrap command: the launcher rejects a live duplicate, marks a dead/invalid run `launcher.orphaned`, and resumes saved settings. Never delete `index.lock`, commit or continue lifecycle steps, or edit `status.json` manually. `init.commit-dump` proves the dump returned successfully, so resume validates and commits it without rerunning 1C; earlier stages repeat the dump path.
4. If terminal input is unavailable, do not collect the initialization questionnaire in chat and do not continue the lifecycle manually. Use the monitored wizard command, or JSON mode only when explicitly requested or an answers file already exists.
5. Create `.agent-1c/project.json`, `.agent-1c/tools.json`, `.agent-1c/dependency-lock.json`, and `.dev.env` if missing.
6. Run tool checks, resolve source infobase unsafe-action protection before the first source-base operation, initialize Git, checkout/create `master`, update the source infobase from storage when configured, and dump configuration files to `src/cf`. Source confirmation stays in the current init window without beep/taskbar flashing; interrupted runs repeat only an unproven protection stage.
7. Initial dump must produce `src/cf/ConfigDumpInfo.xml`; later dumps use incremental `-update -force` when that file exists. Stop if `src/cf` is non-empty without `ConfigDumpInfo.xml`.
8. Install/cache dependencies, install `ai_rules_1c` for exactly the selected client, record pins, reconcile MCP only for that client, render its ITL surface, generate the Kilo/OpenCode routine agent when applicable, and apply the ITL overlay.
9. Commit rules and workflow files when there are changes.
10. Make the active client reread the initialized `master` project before the next lifecycle action. For Codex, fully restart the application so it loads the generated project `.codex/config.toml` and connects its MCP servers, then open a new `Local` task. For Kilo Code, run one `/reload` in the already-open `master` window. Apply the matching adapter instruction for other clients.

## Tool Actions

- `check-tools`: validate configured platform, Git, existing web publication tooling when automatic publication is enabled/requested, Vanessa Automation, and writable workflow folders.
- `list-platforms`: show discovered 1C platform versions.
- `detect-web-publication`: detect existing web publication tooling and show usable `.dev.env` values.
- `configure-web-publication`: run the interactive web publication policy/settings wizard after init.
- `publish-dev-branch`: publish or record publication for an existing development branch.
- `install-vanessa-automation`: download `vanessa-automation-single.*.zip`, verify its archive and EPF SHA256 values, stream only the EPF and root license/provenance files through `.tx\v`, atomically install them under `.agent-1c/tools/va`, and save `VANESSA_*` paths. Do not expand the archive's deep `features` tree.
- init/update: download the facade to `%LOCALAPPDATA%\ITL\MCP\ondemand\<version>`, verify SHA256, cache only backend versions admitted by `assets/ondemand-mcp/compatibility.json`, and save ROCTUP/Vanessa artifact paths. It does not start 1C or a backend.

## UPDATE_WORKFLOW

Goal: refresh the installed ITL workflow package without rerunning initialization.

1. Run only from the `master` worktree.
2. Require a clean tracked Git worktree while ignoring local runtime state such as `.dev.env`, `.agent-1c/mcp/`, `.codex/config.toml`, and `.kilo/kilo.json*`.
3. Resolve the package source from `ITL_WORKFLOW_SOURCE_PATH` or clone/update `ITL_WORKFLOW_REPO` and `ITL_WORKFLOW_REF` (`https://github.com/xmentosx/1c-agent-workflow.git`, `master` by default).
4. Copy only managed workflow files: `.agents/skills/1c-workflow*`, `.agents/skills/product-docs`, `.agents/skills/itl-roctup-1c-data`, `.agents/skills/itl-vanessa-ui-mcp`, Kilo templates, `docs/itl-workflow/`, `templates/`, `install-agent-1c-workflow.ps1`, and `AGENT-INSTALL.md`. Never copy or overwrite the target project's root `README.md`. Remove obsolete root workflow docs only when their hashes match a known managed version; preserve divergent files with a warning.
5. Preserve local runtime/project state. Do not overwrite `.dev.env`, `.agent-1c/dev-branches/`, `.agent-1c/mcp/`, `.codex/config.toml`, `.kilo/kilo.json*`, or existing project/tools config.
6. Record provenance and reapply `USER-RULES.md`. In `fresh`, reconcile every workflow-managed dependency lock entry from the copied canonical template before any facade/backend/UI dependency is consumed, while preserving workflow provenance, the controlled `aiRules1c` migration, and foreign entries. In `locked`, never mutate pins and fail once with every missing required lock path. Then refresh compatible facade/backend caches and run `update-ai-rules` unless skipped. After all stages succeed, create one allowlisted local `master` commit named `chore: update ITL workflow to <ref>@<short-sha>`; a no-op creates no commit. Verify tracked state is clean and never push. Reload the active client once after a facade install/upgrade.
7. Do not update active `itldev/*` worktrees automatically; merge/refresh each one so its active-client config receives the stable facades. Backend starts thereafter need no reload.

## UPDATE_AI_RULES

Goal: refresh the configured `ai_rules_1c` source while preserving the ITL overlay.

1. Clone or update the configured `ai_rules_1c` repo under the first writable workflow temp root (`TEMP`/`TMP`, user-profile temp, or project-local `.agent-1c/tmp` fallback).
2. When `aiRules.ref` is configured, both `fresh` and `locked` checkout that immutable tag. The controlled fork accepts only `itl-*`; verify that the tag resolves to the commit recorded in the dependency lock, and never consume fork `main`.
3. In `locked`, use the lock repo/ref/commit and stop when required values are missing or disagree. Remote HEAD is allowed only for an explicitly configured legacy/custom repository without `aiRules.ref`; it is never the standard ITL path.
4. Require exact agreement between configured and installed client. Run `update` when they agree; an approved migration/switch transactionally removes the old managed client and initializes the new one. Never use multi-client `add`.
5. Preserve configured-source files marked `userModified`; use `-Force` only after explicit developer intent.
6. Reconcile default configured-source MCP entries only in the active client's writable config and only after writing ready vibecoding1c-managed replacements; if selection/state is missing or incomplete, preserve those entries and print `vibecoding1c-mcp-setup` as the recovery action.
7. Reapply the managed ITL block in `USER-RULES.md` from `templates/USER-RULES.append.md`; normally do not append to `AGENTS.md` when it already references `USER-RULES.md`.
8. Record the resolved commit, regenerate the active command/routine-agent surface, and preserve `LLM-RULES.md` byte-for-byte.
