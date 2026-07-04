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
detect-apache
install-apache
install-vanessa-automation
install-vanessa-mcp
start-vanessa-mcp
stop-vanessa-mcp
vanessa-mcp-status
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
set-dev-branch-extension
dump-dev-branch-extension
activate-dev-branch-context
update-dev-branch-base
run-dev-branch-tests
verify-dev-branch
refresh-dev-branch
export-dev-branch-result
close-dev-branch
switch-master
switch-dev-branch
list-dev-branches
status
```

Extension helper actions and Vanessa MCP actions are advanced/helper commands. Keep `/itl-set-dev-branch-extension`, `/itl-dump-dev-branch-extension`, and `/itl-vanessa-mcp` documented for direct use, but do not show them in the beginner `/itl` menu.

vibecoding1c MCP actions (`vibecoding1c-mcp-setup`, `vibecoding1c-mcp-select`, `vibecoding1c-mcp-refresh-registry`, `vibecoding1c-mcp-update`, `vibecoding1c-mcp-status`, `vibecoding1c-mcp-start`, `vibecoding1c-mcp-stop`, `vibecoding1c-mcp-rotate-keys`, `vibecoding1c-mcp-ensure-model`, `vibecoding1c-mcp-write-client-config`) are exposed through `/itl-vibecoding1c-mcp`. They manage remote LAN registry discovery, per-server remote/local selection, private vibecoding1c MCP distribution, local key rotation, embedding model bootstrap, port allocation, Docker containers, and Codex/Kilo client config for the current scope. Remote is the default provider; config-specific remote vibecoding1c MCP always needs an explicit `configId`. Local `code`/`graph` can be selected for project or branch scope. Vanessa MCP is managed separately through `/itl-vanessa-mcp` and is always branch-local.

`update-ai-rules` refreshes upstream `ai_rules_1c` managed files with that installer, removes default upstream MCP client entries so `/itl-vibecoding1c-mcp` remains the client-config owner, records the resolved commit in `.agent-1c/dependency-lock.json`, and reapplies the ITL overlay in `USER-RULES.md`. It does not normally append to `AGENTS.md` when upstream `AGENTS.md` already points to `USER-RULES.md`.

`update-workflow` refreshes the installed ITL workflow package in an already initialized project. It must run from the `master` worktree, copies only managed workflow files, preserves local runtime state, records `workflowPackage` in `.agent-1c/dependency-lock.json`, runs `update-ai-rules` unless `-SkipAiRules` is passed, and prints follow-up commands for vibecoding1c MCP, Vanessa MCP, and active `itldev/*` worktrees. It is exposed through `/itl-update-workflow` and is intentionally not part of the beginner `/itl` menu.

For normal developer work, prefer the short `/itl-*` commands documented in the README and developer guide.
