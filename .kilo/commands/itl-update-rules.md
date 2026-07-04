---
description: Update upstream ai_rules_1c, clean default MCP entries, and reapply the ITL overlay
agent: code
---

Update managed `ai_rules_1c` files, remove default upstream MCP client entries from ignored Codex/Kilo config, then reapply the ITL overlay in `USER-RULES.md`.

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action update-ai-rules
```

Use `-Force` only when the developer explicitly wants upstream managed files to overwrite local edits that the `ai_rules_1c` installer would otherwise keep as `userModified`.
