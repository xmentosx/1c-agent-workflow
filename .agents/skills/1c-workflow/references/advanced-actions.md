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
mcp-setup
mcp-update
mcp-status
mcp-start
mcp-stop
mcp-rotate-keys
mcp-ensure-model
mcp-write-client-config
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

Team MCP actions (`mcp-setup`, `mcp-update`, `mcp-status`, `mcp-start`, `mcp-stop`, `mcp-rotate-keys`, `mcp-ensure-model`, `mcp-write-client-config`) are exposed through `/itl-mcp`. They manage the private ITL MCP distribution, local key rotation, embedding model bootstrap, port allocation, Docker containers, and Codex/Kilo client config for the current scope.

For normal developer work, prefer the short `/itl-*` commands documented in the README and developer guide.
