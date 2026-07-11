# Branch Lifecycle Reference

Use this reference for creating, refreshing, switching, listing, or maintaining development branch worktrees and branch infobase copies.

## Git And Worktree Rules

- `master` is the source worktree. New work uses sibling Git worktrees by default under `<project-folder>-worktrees/<branch>`.
- Use `-UseCurrentWorktree` only when the developer explicitly asks for the legacy single-folder mode.
- Stop on unexpected dirty tracked Git state before worktree creation, legacy switching, copying bases, dumping config files, refresh, result, or advanced close.
- Worktree-created `itldev/*` lifecycle commands must run from the branch worktree unless the helper explicitly delegates to the main worktree.
- Runtime folders such as `.agent-1c/dev-branches/`, `.agent-1c/event-log-baselines/`, `.agent-1c/infobases/`, `.agent-1c/runs/`, `.agent-1c/mcp/`, `.agent-1c/tools/`, `.codex/config.toml`, and `.kilo/kilo.json*` are local ignored state.

## NEW_DEV_BRANCH / NEW_EXTENSION_DEV_BRANCH

Goal: create an isolated development branch worktree plus isolated copied infobase.

Use the monitored launcher by default when `DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP=manual-confirm` so the unsafe-action protection confirmation is visible. Direct `agent-1c.ps1` branch creation is only for explicit non-interactive automation with `DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP=skip`.

1. Check the current Git worktree is clean and the command is run from `master`.
2. Sync/checkout `master` in the main worktree and pull `--ff-only` when a remote/upstream exists.
3. Create `itldev/<safe-dev-branch-name>` in a sibling worktree unless explicit branch/worktree paths are supplied.
4. Copy `.dev.env` into the new worktree.
5. Copy the source infobase into the new worktree.
   - File base: recursive directory copy under `.agent-1c/infobases/dev-branches` unless explicitly overridden.
   - Server base: run configured `serverBaseCopyScript`; do not invent server copy commands.
6. If `sourceUsesRepository=true`, unbind the development branch copy from 1C configuration repository storage without repository parameters.
7. Register the branch infobase in `%APPDATA%\1C\1CEStart\ibases.v8i` under `/ITL/<project-root-name>` with entry name `<project-root-name> - <development-branch-name>`.
8. Save branch state to `.agent-1c/dev-branches/<safe-dev-branch-name>.json` inside the worktree, including `createdWithWorktree`, `worktreePath`, `mainWorktreePath`, launcher metadata, `devBranchKind`, publication status fields, ROCTUP/Vanessa UI MCP status, legacy Data MCP status, and Vanessa Automation verification fields.
9. Activate branch context in the worktree `.dev.env`, prepare branch-local ROCTUP/Vanessa UI MCP state as stopped, and leave both servers closed until an agent explicitly needs them. Inherit absolute paths to the checked Vanessa UI MCP CFE cache from `master`; do not install CFE into the branch infobase until `start-vanessa-mcp`. If `master` has a complete vibecoding1c MCP selection, copy that selection into the new worktree and materialize ready `remote` and `local + project` endpoints in the worktree context. Write vibecoding1c endpoints to branch state, `.dev.env`, `.codex/config.toml`, and `.kilo/kilo.json`; ROCTUP/Vanessa UI MCP client entries are written only after explicit `start-roctup-mcp` or `start-vanessa-mcp`.
10. If web publication is enabled, run the helper-owned publication cycle: automatic publication only when `WEB_PUBLISH_AUTO=true`, otherwise manual URL entry or skip. Best-effort legacy branch Data MCP connects only after a publication URL exists.
11. Report branch, worktree path, copied infobase path, launcher folder/name, stopped/ready ROCTUP/Vanessa UI MCP status, and publication URL if any.
12. Print the Russian instruction that the current folder stayed on `master`, the new worktree path, and the developer should open a separate Codex/Kilo/IDE window there. If Kilo still shows a cached command picker, tell the developer to run `/reload` in the new worktree.

If branch creation used `DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP=skip` before protection was actually disabled, recover from the branch worktree through the monitored `configure-dev-branch-unsafe-action-protection` helper action. It reopens the normal visible Designer confirmation flow and can record an empty-password local user through `-InfoBaseUser`; do not recreate the branch or mark protection confirmed without the developer's explicit UI action and confirmation.

For extension branches, do not ask for `extensionName` and do not create the extension during branch creation. The extension is created later in the copied branch infobase.

## Extension Helpers

`set-dev-branch-extension` creates or records the extension in the branch infobase and activates the correct extension context. `dump-dev-branch-extension` dumps it into `src/cfe/<extensionName>`.

Rules:

- Find branch state from `DevBranchName` or current branch.
- If the state belongs to another worktree, report `worktreePath` and tell the developer to open that folder.
- For legacy branches, require a clean Git worktree and checkout the saved branch.
- For extension branches without an extension name, clear infobase-bound values and tell the developer to run `set-dev-branch-extension` before `/update1cbase`.

## Branch Context And Base Update

`activate-dev-branch-context` writes the current branch infobase values into `.dev.env` so upstream `ai_rules_1c` commands such as `/update1cbase`, `/loadfrom1cbase`, and `/getconfigfiles` target the copied branch infobase.

`update-dev-branch-base` loads only changed branch files into the copied branch infobase. When the root `Configuration.xml` changed, it deliberately falls back to a full files load because 1C Designer does not reliably accept that root object through `-listFile`; the changed-file list is still saved as evidence. After a real file load, ITL launches Enterprise user mode through the bundled auto-update EPF to apply update handlers and answer the legal-copy prompt non-interactively, then restarts already-running ROCTUP/Vanessa UI MCP processes so they see the updated infobase. The auto-update process has a finite 900-second default timeout; use local `DEV_BRANCH_AUTO_UPDATE_TIMEOUT_SECONDS` only when a project needs a different positive limit. A timeout fails the lifecycle and stops only the helper-owned Enterprise process. No-op updates do not launch Enterprise or restart MCP.

After every successful or failed Vanessa verification, stop branch-owned `TESTMANAGER`/`TESTCLIENT` processes and fail the verification if cleanup cannot be proved. Use the advanced `stop-dev-branch-test-clients` recovery action for leftovers from older runs; it matches the current branch infobase/worktree and must not stop foreign worktrees.

Development branch changes must never be loaded directly into the source infobase connected to 1C configuration repository storage.

## STATUS / LIST / SWITCH

- `status` shows current worktree, branch, verification/MCP summaries, and target worktree paths.
- `list-dev-branches` shows active branches, branch/worktree paths, main worktree path, copied infobase path, launcher metadata, publication URL/status, ROCTUP MCP status, legacy Data MCP status, Vanessa Automation verification port/status, Vanessa UI MCP status, vibecoding1c MCP current-scope status, and timestamps.
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
7. Restart already-running ROCTUP/Vanessa UI MCP processes after a real load.
8. Re-check whether verification is fresh; stale or unknown verification must be handled before result export.

## CLOSE_DEV_BRANCH

`close-dev-branch` is advanced bookkeeping for hiding a branch from active lists. It is not part of the visible slash-command surface. It follows the same verification policy as result export, stops branch-local ROCTUP and Vanessa UI MCP, records close metadata, and must not delete user worktrees or infobases automatically.
