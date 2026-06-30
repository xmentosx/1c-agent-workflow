---
description: Fast init for a 1C agent project
agent: code
---

Run the helper directly from the current project directory:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action init-project -InitMode wizard
```

Do not load the full workflow skill first. The helper script wizard owns the setup questions. If the helper reports that interactive input is unavailable, ask the developer to run the same command in an interactive terminal or provide an init answers JSON file with `-InitMode json -InitAnswersPath <file>`.

If the helper fails, report the concise error and log path first. Open detailed workflow references only when the user asks for explanation or recovery guidance.
