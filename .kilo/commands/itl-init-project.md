---
description: Initialize an ITL 1C project
agent: code
---

This is a direct bootstrap-only wrapper, not part of the normal `/itl` beginner menu.

Run the helper wizard directly from the current project directory:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action init-project -InitMode wizard
```

Do not collect the initialization questionnaire in chat or Kilo Questions before this first helper attempt. The wizard confirms the current project directory, collects setup values, writes `.dev.env` and `.agent-1c/project.json`, and runs the initialization lifecycle.

If the wizard fails because terminal input is unavailable, do not collect the questionnaire in chat and do not continue the lifecycle manually. Open or suggest an interactive PowerShell window with the same wizard command, or use JSON mode only when the developer explicitly requested non-interactive initialization or an answers file already exists.

Use non-interactive JSON mode only when an answers file already exists or the developer explicitly asks for it:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action init-project -InitMode json -InitAnswersPath <answers.json>
```
