# Branch Lifecycle Reference

Use this reference for creating, refreshing, switching, listing, or maintaining development branch worktrees and branch infobase copies.

## Git And Worktree Rules

- `master` is the source worktree. New work uses sibling Git worktrees by default under `<project-folder>-worktrees/<branch>`.
- Use `-UseCurrentWorktree` only when the developer explicitly asks for the legacy single-folder mode.
- Stop on unexpected dirty tracked Git state before worktree creation, legacy switching, copying bases, dumping config files, refresh, result, or advanced close.
- Worktree-created `itldev/*` lifecycle commands must run from the branch worktree unless the helper explicitly delegates to the main worktree.
- Runtime folders such as `.agent-1c/dev-branches/`, `.agent-1c/event-log-baselines/`, `.agent-1c/event-log-signature-cache/`, `.agent-1c/infobases/`, `.agent-1c/runs/`, `.agent-1c/mcp/`, `.agent-1c/tools/`, `.codex/config.toml`, and `.kilo/kilo.json*` are local ignored state.

## Lifecycle Operation Lock

Every mutating helper action holds `.agent-1c/locks/lifecycle.lock` in its current worktree and publishes phase/status evidence in the ignored `lifecycle-operation.json`. A second mutating action in the same worktree fails before mutation with `LIFECYCLE_OPERATION_CONFLICT`; use `status` to see its action, PID, phase and state path. Ordinary actions in different development worktrees may run concurrently. `refresh-dev-branch`, `close-dev-branch`, and a delegated `sync-master` hold both the branch and main-worktree locks in canonical path order, so master cannot change midway through those operations.

`help`, `status`, `list-dev-branches`, `validate`, `check-tools`, platform/publication detection and MCP status actions do not acquire the lifecycle lock. A fresh helper process after workflow copy or branch merge continues the exact operation ID while its parent owns the locks; forged or stale continuation arguments fail with `LIFECYCLE_OPERATION_CONTINUATION_INVALID`. A leftover JSON record without a held file lock is shown as `orphaned` and does not require manual deletion. There is no force-unlock command.

## NEW_DEV_BRANCH / NEW_EXTENSION_DEV_BRANCH

Goal: create an isolated development branch worktree plus isolated copied infobase.

Use the monitored launcher by default when `DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP=manual-confirm` so fallback unsafe-action protection confirmation is visible. A valid master-local source confirmation makes this step question-free. Direct `agent-1c.ps1` branch creation is allowed only when that confirmation is valid or explicit non-interactive automation sets `DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP=skip`.

1. Check the current Git worktree is clean and the command is run from `master`.
2. Sync/checkout `master` in the main worktree and pull `--ff-only` when a remote/upstream exists.
3. Create `itldev/<safe-dev-branch-name>` in a sibling worktree unless explicit branch/worktree paths are supplied.
4. Copy `.dev.env` into the new worktree.
5. Copy the source infobase into the new worktree.
   - File base: recursive directory copy under `.agent-1c/infobases/dev-branches` unless explicitly overridden.
   - Server base: run configured `serverBaseCopyScript`; do not invent server copy commands.
6. If `sourceUsesRepository=true`, unbind the development branch copy from 1C configuration repository storage without repository parameters.
7. Resolve unsafe-action protection immediately after repository unbind. Reuse a context-matching source confirmation from the main worktree; otherwise run the visible Russian confirmation/Configurator loop for the copied base. Persist `unsafe-action-protection-resolved` before continuing so resume never recopies the base or repeats a proven answer.
8. Register the branch infobase in `%APPDATA%\1C\1CEStart\ibases.v8i` under `/ITL/<project-root-name>` with entry name `<project-root-name> - <development-branch-name>`.
9. Save branch state to `.agent-1c/dev-branches/<safe-dev-branch-name>.json` inside the worktree, including `createdWithWorktree`, `worktreePath`, `mainWorktreePath`, launcher metadata, `devBranchKind`, publication status fields, legacy MCP migration fields, and Vanessa Automation verification fields.
10. Activate branch context in `.dev.env`, inherit compatible ROCTUP/Vanessa artifacts, and register the stable `itl-roctup-data` and `itl-vanessa-ui` stdio facades with compact `resolve_tool`/`call_tool` surfaces for the active client. Neither backend nor 1C starts until the first inner call. If `master` has a complete vibecoding1c MCP selection, copy and rematerialize it for the new worktree.
11. If web publication is enabled, run the helper-owned publication cycle: automatic publication only when `WEB_PUBLISH_AUTO=true`, otherwise manual URL entry or skip. Best-effort legacy branch Data MCP connects only after a publication URL exists.
12. Build the event-log baseline and store its reader/cache/count/duration evidence.
13. Persist `initializationStatus=enterprise-normalization-pending`, then run Enterprise with the bundled auto-update EPF against the copied branch infobase only. Save `enterpriseNormalizationStatus`, reason, error, time, EPF and log evidence; set `initializationStatus=ready` only after success.
14. Report branch, worktree/base paths, launcher, MCP/publication state, event-log scan evidence, and Enterprise normalization state.
15. For an extension branch, run the separately transactional initialization phase inside the new worktree when `ExtensionInitMode`, `ExtensionName`, and optional CFE path were collected in chat. If they are explicitly unknown, persist `extensionInitializationStatus=pending`; every development action blocks with `EXTENSION_INIT_REQUIRED` until the agent collects the values on first entry and completes initialization. Never hand a PowerShell command to the developer.
16. Print the Russian instruction that the current folder stayed on `master`, report the structured new worktree path, and open a separate window of the selected agent or IDE best-effort. If its command picker is cached, print the adapter-specific reload instruction.

If the final Enterprise step fails, preserve the worktree, copied infobase, launcher, and failed state. Repeating `new-dev-branch` reuses those assets and retries normalization without copying the base again. Branches created by older workflow versions have no marker; before the first Enterprise-bound ROCTUP, Vanessa UI, Vanessa Automation, publication, or legacy Data MCP action, normalize them once with reason `legacy-preflight`. Never run this normalization against the source infobase.

If branch creation used `DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP=skip` before protection was actually disabled, recover from the branch worktree through the monitored `configure-dev-branch-unsafe-action-protection` helper action. It reopens the normal visible Designer confirmation flow and can record an empty-password local user through `-InfoBaseUser`; do not recreate the branch or mark protection confirmed without the developer's explicit UI action and confirmation.

For extension branches, ask in chat for Empty or CFE, the extension name, and the CFE path when applicable before launching branch creation. Branch copy and extension initialization remain separate transactional phases, but `new-extension-dev-branch` orchestrates both in one user scenario. If the values are unknown, only the second phase is deferred and persisted as pending.

## Extension Helpers

The composite `new-extension-dev-branch` invokes `init-dev-branch-extension -ExtensionInitMode Empty|Cfe -ExtensionName <name> [-ExtensionSourcePath <file.cfe>]` internally from the new worktree. A pending or failed second phase can be resumed without copying the branch infobase again. `Empty` uses the installed `cfe-init.ps1` scaffold and Designer `/LoadConfigFromFiles ... -Extension`; `Cfe` loads the binary directly with `/LoadCfg ... -Extension`. Neither mode uses Designer Agent, `AgentMode`, `/Extension`, or CFE unpacking. The helper snapshots the copied infobase, rolls back on failure, dumps normalized sources only to `src/cfe/<ExtensionName>`, validates them, and records `ready` only after full success.

A configuration branch may contain several related features. An extension branch may also contain several features or OpenSpec changes, but only for its one selected extension. A second changed CFE requires a separate branch, worktree, and branch infobase; the lifecycle intentionally has no `extensions[]` state. Update, check, dump, result, and close reject changed paths under another `src/cfe/<Name>` with `EXTENSION_BRANCH_SINGLE_ARTIFACT` while tolerating unchanged baseline CFE directories.

`set-dev-branch-extension` only records recovery context for an extension already present in the branch infobase; a missing slot fails with `EXTENSION_RECOVERY_SLOT_MISSING` before state or `.dev.env` changes. `dump-dev-branch-extension` writes a temporary dump, validates its root/name/CFE structure, and replaces the canonical dump transactionally. `/update1cbase` is the subsequent development loop after initialization.

Rules:

- Find branch state from `DevBranchName` or current branch.
- If the state belongs to another worktree, report `worktreePath` and tell the developer to open that folder.
- For legacy branches, require a clean Git worktree and checkout the saved branch.
- For a new extension branch without initialized extension state, ask the developer for Empty or CFE, extension name, and optional CFE path in chat, then invoke `init-dev-branch-extension` internally. Never tell the developer to run it. Use `set-dev-branch-extension` only for a manually created legacy extension.

## Branch Context And Base Update

`activate-dev-branch-context` writes the current branch infobase values into `.dev.env` so upstream `ai_rules_1c` commands such as `/update1cbase`, `/loadfrom1cbase`, and `/getconfigfiles` target the copied branch infobase.

`update-dev-branch-base` hashes the sorted loadable source tree (relative path plus SHA-256, excluding `ConfigDumpInfo.xml`) before consulting Git. A matching configuration/extension fingerprint skips Designer; if normalization is not passed, only Enterprise is retried. A changed fingerprint uses Git changed/untracked paths for the exact partial `-listFile`, including root `Configuration.xml`, Cyrillic paths, and mixed lists. Only an actually-started failed partial Designer command falls back once to full load plus `/UpdateDBCfg`; `Partial` disables fallback and `Full` is explicit recovery. Legacy state uses the old Git decision once to seed the fingerprint. Configuration and extension fingerprints are independent; restore/recreate or extension-root changes invalidate the relevant value.

Before a full fallback, the helper preserves the partial exception/list/log and warns that no base snapshot exists. A successful fallback records `configLoadStatus=fallback-succeeded` and `lastConfigLoadMode=full-fallback`; a double failure records `fallback-failed`, both errors/logs, leaves the last-loaded commit unchanged, skips normalization/MCP restart/verification, and requires recreating the branch copy for safe recovery. Full load remains a real-failure fallback, not a special case for root XML.

After any real partial/full configuration or extension load, normalization is marked pending and ITL launches Enterprise through the bundled auto-update EPF to apply update handlers and answer the legal-copy prompt non-interactively. Lifecycle cleanup stops on-demand backend instances first; later tool calls create fresh ones without client reload. The default timeout is 900 seconds; use `DEV_BRANCH_AUTO_UPDATE_TIMEOUT_SECONDS` only for a different positive limit.

After every successful or failed Vanessa verification, stop branch-owned `TESTMANAGER`/`TESTCLIENT` processes and fail the verification if cleanup cannot be proved. Use the advanced `stop-dev-branch-test-clients` recovery action for leftovers from older runs; it matches the current branch infobase/worktree and must not stop foreign worktrees.

Development branch changes must never be loaded directly into the source infobase connected to 1C configuration repository storage.

## STATUS / LIST / SWITCH

- `status` shows the current lifecycle operation or orphaned record, worktree, branch, initialization/normalization/config-load evidence, event-log reader/cache/count/duration, verification/MCP summaries, and target worktree paths.
- `list-dev-branches` shows active branches, worktree/base state, verification and vibecoding1c status; general `status`/`doctor` also report the facade executable and owned on-demand instances.
- `switch-master` clears active branch infobase values and returns legacy single-folder checkouts to `master`.
- `switch-dev-branch` is mainly legacy recovery. For worktree-created branches, report the saved worktree path instead of changing the current folder.

## REFRESH_DEV_BRANCH

Goal: refresh the current development branch from fresh `master` and source state.

1. Require an active `itldev/*` worktree and clean tracked Git state.
2. Refresh `master` from storage/source through the main worktree.
3. Merge fresh `master` into the branch.
4. If workflow helper scripts changed, re-exec the helper in the correct phase.
5. Regenerate context-specific Kilo wrappers if workflow files changed.
6. Update the branch infobase from changed files.
7. Keep the stable facade config and let the next tool call create fresh backend instances after a real load.
8. Re-check whether verification is fresh; stale or unknown verification must be handled before result export.

## CLOSE_DEV_BRANCH

`close-dev-branch` is advanced bookkeeping for hiding a branch from active lists. It follows the same verification policy as result export, exclusively waits for active MCP calls, stops all owned branch backends, records close metadata, and must not delete user worktrees or infobases automatically.
