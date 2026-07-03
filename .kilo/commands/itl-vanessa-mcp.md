---
description: Manage branch-local Vanessa MCP for the current ITL development branch
agent: code
---

Run one of these helper commands from the current development branch worktree:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action install-vanessa-mcp
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action start-vanessa-mcp
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action vanessa-mcp-status
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action stop-vanessa-mcp
```

Use Vanessa MCP for authoring and debugging scenarios against the current branch infobase. Keep `/itl-verify` as the final repeatable verification gate; it runs packet `StartFeaturePlayer` through `TESTMANAGER -> TESTCLIENT`, not MCP.
