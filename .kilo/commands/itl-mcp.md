---
description: Setup and manage ITL 1C MCP servers for the current scope
agent: code
---

Use this command when the developer asks to install, update, start, stop, or inspect ITL MCP servers.

Default flow:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action mcp-setup
```

Useful direct actions:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action mcp-status
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action mcp-start
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action mcp-stop
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action mcp-update
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action mcp-rotate-keys
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action mcp-ensure-model
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action mcp-write-client-config
```

Scope rules:

- Run from `master` or a project worktree to manage global and project MCP.
- Run from an `itldev/*` worktree to include that branch's local MCP.
- Do not paste license keys into chat; the helper reads them from the private distribution and stores the rotated local copy under `%LOCALAPPDATA%\ITL\MCP\vibecoding1c`.
