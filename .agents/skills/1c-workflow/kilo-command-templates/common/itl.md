---
description: Show the ITL lifecycle panel for the current project context
agent: code
---

Run the helper lifecycle panel from the current project directory:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action help
```

Report the panel as the source of truth for the current folder. Do not execute a lifecycle action unless the developer clearly chooses one. Rare actions such as MCP setup, extension bootstrap/dump, marking a branch closed, and rule updates are available through natural-language requests or helper actions, but they are not part of the visible slash-command surface. Workflow package updates are visible from the master worktree as `/itl-update-workflow`.
