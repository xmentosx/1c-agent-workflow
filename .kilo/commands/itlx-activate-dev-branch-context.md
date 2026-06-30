---
description: Fast activate the current ITL development branch infobase context
agent: code
---

Run the helper directly from the current project directory:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action activate-dev-branch-context
```

Do not ask for a development branch name. The helper infers it from the current `itldev/<name>` Git branch and writes `.dev.env` values for ai_rules_1c commands.

If the helper fails, report the concise error first. Open detailed workflow references only when the user asks for explanation or recovery guidance.
