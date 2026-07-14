# Advanced Helper Actions

This reference is for diagnostics, recovery, and automation. Do not show this full list as the beginner command surface.

Run helper actions from the project root:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action <action>
```

Mutating actions are serialized per worktree through the ignored lifecycle operation lock. Concurrent ordinary operations in separate development worktrees are allowed; actions that also mutate master acquire both scopes. On `LIFECYCLE_OPERATION_CONFLICT`, inspect `status` and wait for or diagnose the recorded PID/phase. Do not delete lock files or edit operation JSON. Read-only help/status/list/validation/tool-detection/MCP-status actions remain available during the operation.

Common internal actions:

```text
init-project
validate
check-tools
list-platforms
detect-web-publication
detect-apache
configure-web-publication
publish-dev-branch
install-vanessa-automation
install-vanessa-mcp
start-vanessa-mcp
stop-vanessa-mcp
vanessa-mcp-status
install-roctup-mcp
update-roctup-mcp
start-roctup-mcp
stop-roctup-mcp
roctup-mcp-status
vibecoding1c-mcp-setup
vibecoding1c-mcp-update
vibecoding1c-mcp-status
vibecoding1c-mcp-start
vibecoding1c-mcp-stop
vibecoding1c-mcp-select
vibecoding1c-mcp-refresh-registry
vibecoding1c-mcp-rotate-keys
vibecoding1c-mcp-ensure-model
vibecoding1c-mcp-write-client-config
update-workflow
update-ai-rules
sync-master
new-dev-branch
new-extension-dev-branch
configure-dev-branch-unsafe-action-protection
init-dev-branch-extension
set-dev-branch-extension
dump-dev-branch-extension
activate-dev-branch-context
update-dev-branch-base
run-dev-branch-tests
stop-dev-branch-test-clients
check-dev-branch
verify-dev-branch
refresh-dev-branch
export-dev-branch-result
close-dev-branch
switch-master
switch-dev-branch
list-dev-branches
status
release-e2e-snapshot
release-e2e-restore
release-e2e-config-roundtrip
release-e2e-extension-smoke
```

Extension helper actions and branch-local MCP actions are advanced/helper commands. After `new-extension-dev-branch`, `init-dev-branch-extension` is the mandatory explicit next step; keep it and the recovery-only `set-dev-branch-extension`/`dump-dev-branch-extension` actions available through helper actions or natural-language requests, but do not generate them as visible Kilo slash commands. `set-dev-branch-extension` records context only and never creates an extension. New development branches prepare ROCTUP and Vanessa UI MCP as stopped/ready. Start Vanessa UI MCP only for a named runtime UI question, recording, or debugging operation; stop it afterwards, and reload or restart Kilo Code if a manually started server is not visible.

`configure-dev-branch-unsafe-action-protection` is an interactive recovery action for an existing development worktree when branch creation used `skip` before protection was actually disabled. Run it through `run-agent-1c-window.ps1`, optionally passing `-InfoBaseUser <name>` for an empty-password local user. It forces the normal visible Designer confirmation flow and records confirmation in branch state; it never disables protection automatically.

`stop-dev-branch-test-clients` stops only Vanessa `TESTMANAGER`/`TESTCLIENT` processes whose command line belongs to the current development branch infobase/worktree, then fails if any remain. Successful Vanessa verification performs the same cleanup automatically. It never stops foreign worktree test processes.

`release-e2e-config-roundtrip` is reserved for `scripts/invoke-release-e2e.ps1`. It dumps the dedicated branch infobase into ignored local state, writes evidence under ignored `build/test-results`, and proves that a root `Configuration.xml` `Comment` loaded in strict `Partial` mode roundtrips while `Ext/ParentConfigurations.bin` is present. Do not expose it as a slash command or use it for ordinary project work.

`release-e2e-snapshot` and `release-e2e-restore` are internal checkpoint actions for the same runner. They accept only a project-local ignored `.dt`; restore invalidates both configuration and extension fingerprints. Do not expose them as slash commands or use them as a general backup interface.

`release-e2e-extension-smoke` is also reserved for the Release runner. It uses the public extension initialization lifecycle to create an Empty extension, produce and reload a CFE, validate both normalized dumps, and restore the disposable infobase and worktree from a snapshot. It is not a project command and must not have a slash wrapper.

ROCTUP MCP actions (`install-roctup-mcp`, `update-roctup-mcp`, `start-roctup-mcp`, `stop-roctup-mcp`, `roctup-mcp-status`) manage the ignored EPF/skills cache and the branch-local embedded data MCP. ROCTUP is the preferred data channel for branch infobases and does not need web publication; start it for focused data exploration and stop it after use.

vibecoding1c MCP actions (`vibecoding1c-mcp-setup`, `vibecoding1c-mcp-select`, `vibecoding1c-mcp-refresh-registry`, `vibecoding1c-mcp-update`, `vibecoding1c-mcp-status`, `vibecoding1c-mcp-start`, `vibecoding1c-mcp-stop`, `vibecoding1c-mcp-rotate-keys`, `vibecoding1c-mcp-ensure-model`, `vibecoding1c-mcp-write-client-config`) are exposed through helper actions or natural-language requests. They manage remote LAN registry discovery, per-server remote/local selection, private vibecoding1c MCP distribution, local key rotation, embedding model bootstrap, port allocation, Docker containers, and Codex/Kilo client config for the current scope. Setup applies saved selection and runs selection first when it is missing or incomplete; use `vibecoding1c-mcp-select` or `vibecoding1c-mcp-setup -Force` for an explicit reselect. Remote is the default provider; config-specific remote vibecoding1c MCP always needs an explicit per-server `configId`, and `code`/`graph` selections do not inherit `configId` or `hostId` from each other. Local `code`/`graph` can be selected for project or branch scope. Vanessa UI MCP is managed separately through helper actions and is always branch-local.

In the short `/itl` panel, show advanced/helper actions only as grouped additional capabilities, not as visible slash commands:

```text
ROCTUP MCP: branch-local install/update/start/status/stop
vibecoding1c MCP: setup/status/select/refresh-registry/update
Vanessa UI MCP: branch-local install/start/status/stop
Extension branches: initialize extension; set/dump are recovery actions
Maintenance/recovery: update base without tests, update workflow/rules, close/list/switch branches
```

`update-ai-rules` refreshes files from the configured `ai_rules_1c` source with `-McpMode delegated`. A configured immutable `aiRules.ref` remains pinned in both `fresh` and `locked`; the controlled fork never consumes `main`. The installer leaves client MCP files byte-for-byte unchanged, then ITL performs the only transactional MCP reconcile after ready vibecoding1c replacements are available. It records the resolved commit in `.agent-1c/dependency-lock.json` and reapplies the ITL overlay in `USER-RULES.md`. If selection/state is incomplete, existing MCP entries are preserved. It does not normally append to `AGENTS.md` when the configured `AGENTS.md` already points to `USER-RULES.md`.

`update-workflow` refreshes the installed ITL workflow package in an already initialized project. It must run from the `master` worktree. The pre-copy phase checks master/clean state, copies only managed workflow files (never root `AGENTS.md`), records `workflowPackage`, then always starts the installed helper in a fresh PowerShell process with internal `post-copy`; only that new process updates rules, MCP, generated commands, and final checks. Generated `.kilo/commands/itl*.md` stay local and ignored. Projects whose old updater predates this re-exec contract need a one-time double run: the first installs it, the second guarantees all post-copy work runs on it. Later updates need one run. Kilo v7 may still display primary-checkout master commands in linked worktrees; `/itl` lists them separately as inherited and invalid, while direct master actions fail before mutation.

For normal developer work, prefer the short `/itl-*` commands documented in the README and developer guide.
