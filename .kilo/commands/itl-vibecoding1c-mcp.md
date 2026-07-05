---
description: Setup and manage vibecoding1c MCP servers for the current scope
agent: code
---

Use this command when the developer asks to install, update, start, stop, or inspect vibecoding1c MCP servers.

Default flow:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action vibecoding1c-mcp-setup
```

This applies the saved per-server selection. If the selection is missing or incomplete, the helper opens the selection flow first. To force a new selection during setup, add `-Force`.

Selection examples:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action vibecoding1c-mcp-select -McpProvider remote -McpConfigId <configId>
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action vibecoding1c-mcp-select -McpServerId code -McpProvider local -McpLocalScope project
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action vibecoding1c-mcp-select -McpServerId graph -McpProvider local -McpLocalScope branch
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action vibecoding1c-mcp-setup -Force
```

Useful direct actions:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action vibecoding1c-mcp-status
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action vibecoding1c-mcp-start
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action vibecoding1c-mcp-stop
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action vibecoding1c-mcp-select
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action vibecoding1c-mcp-refresh-registry
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action vibecoding1c-mcp-update
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action vibecoding1c-mcp-rotate-keys
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action vibecoding1c-mcp-ensure-model
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action vibecoding1c-mcp-write-client-config
```

Scope rules:

- Run from `master` or a project worktree to manage global and project MCP.
- Run from an `itldev/*` worktree to include that branch's local MCP.
- Remote is the default provider. Config-specific remote vibecoding1c MCP always needs an explicit `configId` choice, even when the registry currently contains only one configuration.
- Per-server vibecoding1c local overrides are stored in ignored `.agent-1c/mcp/vibecoding1c-selection.json`; use `-McpLocalScope project|branch` for local config-specific `code`/`graph` MCP. The selection flow shows remote host/endpoint details before connecting.
- Do not paste license keys into chat; the helper reads them from the private distribution and stores the rotated local copy under `%LOCALAPPDATA%\ITL\MCP\vibecoding1c`.
