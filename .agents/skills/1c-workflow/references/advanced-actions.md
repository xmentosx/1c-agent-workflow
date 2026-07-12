# Advanced Helper Actions

This reference is for diagnostics, recovery, and automation. Do not show this full list as the beginner command surface.

Run helper actions from the project root:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action <action>
```

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
```

Extension helper actions and branch-local MCP actions are advanced/helper commands. Keep `set-dev-branch-extension`, `dump-dev-branch-extension`, ROCTUP MCP actions, and Vanessa UI MCP actions available through helper actions or natural-language requests, but do not generate them as visible Kilo slash commands. New development branches prepare ROCTUP and Vanessa UI MCP as stopped/ready. Start Vanessa UI MCP only for a named runtime UI question, recording, or debugging operation; stop it afterwards, and reload or restart Kilo Code if a manually started server is not visible.

`configure-dev-branch-unsafe-action-protection` is an interactive recovery action for an existing development worktree when branch creation used `skip` before protection was actually disabled. Run it through `run-agent-1c-window.ps1`, optionally passing `-InfoBaseUser <name>` for an empty-password local user. It forces the normal visible Designer confirmation flow and records confirmation in branch state; it never disables protection automatically.

`stop-dev-branch-test-clients` stops only Vanessa `TESTMANAGER`/`TESTCLIENT` processes whose command line belongs to the current development branch infobase/worktree, then fails if any remain. Successful Vanessa verification performs the same cleanup automatically. It never stops foreign worktree test processes.

ROCTUP MCP actions (`install-roctup-mcp`, `update-roctup-mcp`, `start-roctup-mcp`, `stop-roctup-mcp`, `roctup-mcp-status`) manage the ignored EPF/skills cache and the branch-local embedded data MCP. ROCTUP is the preferred data channel for branch infobases and does not need web publication; start it for focused data exploration and stop it after use.

vibecoding1c MCP actions (`vibecoding1c-mcp-setup`, `vibecoding1c-mcp-select`, `vibecoding1c-mcp-refresh-registry`, `vibecoding1c-mcp-update`, `vibecoding1c-mcp-status`, `vibecoding1c-mcp-start`, `vibecoding1c-mcp-stop`, `vibecoding1c-mcp-rotate-keys`, `vibecoding1c-mcp-ensure-model`, `vibecoding1c-mcp-write-client-config`) are exposed through helper actions or natural-language requests. They manage remote LAN registry discovery, per-server remote/local selection, private vibecoding1c MCP distribution, local key rotation, embedding model bootstrap, port allocation, Docker containers, and Codex/Kilo client config for the current scope. Setup applies saved selection and runs selection first when it is missing or incomplete; use `vibecoding1c-mcp-select` or `vibecoding1c-mcp-setup -Force` for an explicit reselect. Remote is the default provider; config-specific remote vibecoding1c MCP always needs an explicit per-server `configId`, and `code`/`graph` selections do not inherit `configId` or `hostId` from each other. Local `code`/`graph` can be selected for project or branch scope. Vanessa UI MCP is managed separately through helper actions and is always branch-local.

In the short `/itl` panel, show advanced/helper actions only as grouped additional capabilities, not as visible slash commands:

```text
ROCTUP MCP: branch-local install/update/start/status/stop
vibecoding1c MCP: setup/status/select/refresh-registry/update
Vanessa UI MCP: branch-local install/start/status/stop
Extension branches: set extension name/dump extension files
Maintenance/recovery: update base without tests, update workflow/rules, close/list/switch branches
```

`update-ai-rules` refreshes files from the configured `ai_rules_1c` source with that source's installer. A configured immutable `aiRules.ref` remains pinned in both `fresh` and `locked`; the controlled fork never consumes `main`. The helper reconciles configured-source MCP client entries only after ready vibecoding1c replacements are written, records the resolved commit in `.agent-1c/dependency-lock.json`, and reapplies the ITL overlay in `USER-RULES.md`. If vibecoding1c selection/state is incomplete, it preserves those MCP entries as the working fallback. It does not normally append to `AGENTS.md` when the configured `AGENTS.md` already points to `USER-RULES.md`.

`update-workflow` refreshes the installed ITL workflow package in an already initialized project. It must run from the `master` worktree, copies only managed workflow files including `install-agent-1c-workflow.ps1`, preserves local runtime state, records `workflowPackage` in `.agent-1c/dependency-lock.json`, regenerates ignored `.kilo/commands/itl*.md` for the current worktree, refreshes ROCTUP MCP and Vanessa UI MCP CFE caches, runs `update-ai-rules` unless `-SkipAiRules` is passed, and prints follow-up commands for vibecoding1c MCP, Vanessa UI MCP, and active `itldev/*` worktrees. In Kilo master, it is exposed as `/itl-update-workflow`; it is not generated in `itldev/*` worktrees.

For normal developer work, prefer the short `/itl-*` commands documented in the README and developer guide.
