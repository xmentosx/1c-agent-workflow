---
description: Show the ITL lifecycle panel for the current project context
agent: code
---

Run the helper lifecycle panel from the current project directory:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action help
```

Report the helper panel as the source of truth for the current folder and keep its structure: current state, recommended next step, lifecycle path, visible slash commands, and additional helper actions. Do not flatten it into a plain command list, do not add a separate "no lifecycle actions executed" note, and do not execute a lifecycle action unless the developer clearly chooses one. Additional helper actions such as vibecoding1c MCP, branch-local Vanessa MCP, extension bootstrap/dump, maintenance, and recovery remain available through natural-language requests or direct helper actions, but they are not part of the visible slash-command surface. Workflow package updates are visible from the master worktree as `/itl-update-workflow`.
