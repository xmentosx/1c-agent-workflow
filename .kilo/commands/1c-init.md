---
description: Initialize a 1C agent project
agent: code
---

Use the `1c-workflow` skill and execute `INIT_PROJECT`.

Read `.agents/skills/1c-workflow/references/workflow.md`, ask for missing required parameters including the feature infobase copies directory, create/update the project state files, check required software, then run the project initialization workflow.

Ask one value at a time. The developer should answer with the value only; do not ask for `KEY=value` input or one large free-form block with all missing variables.

For infobase and repository passwords, ask first whether the password is set. If the developer chooses "no password", store an empty value and do not treat the words "no password" or "без пароля" as the password.

Before asking for `1cv8.exe`, search installed 1C versions under `C:\Program Files\1cv8` and `C:\Program Files (x86)\1cv8`; offer the found versions as choices and use the selected `bin\1cv8.exe` path. Do not offer the common `C:\Program Files\1cv8` root as a version.

Prefer the PowerShell helper:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action init-project
```
