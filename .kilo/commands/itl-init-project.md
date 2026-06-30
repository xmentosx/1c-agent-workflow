---
description: Initialize a 1C agent project
agent: code
---

Use the `1c-workflow` skill and execute `INIT_PROJECT`.

Run the helper script wizard first. It asks the setup questions, writes `.dev.env`/`.agent-1c/project.json`, checks required software, then runs the project initialization workflow. Read `.agents/skills/1c-workflow/references/workflow.md` only if the helper fails or the developer asks for detailed explanation.

Do not ask for the development branch infobase copies directory during normal initialization. Use `.agent-1c/infobases/dev-branches` inside the project and ensure `.agent-1c/infobases/` is ignored by Git.

Ask whether the source infobase is connected to a 1C configuration repository. Ask repository path/user/password only when it is connected. Use one grouped form with separate short questions when Kilo Code can show grouped questions; otherwise ask the same values sequentially, one question at a time. The developer should answer each field with one raw value only. Do not ask for `KEY=value` input, one large free-form block with all missing variables, or a multi-line answer in one text field.

Write `.dev.env` and `.agent-1c/*.json` files as UTF-8; preserve Cyrillic paths and usernames exactly.

For infobase and repository password lines, exact answers `нет` and `-` mean an empty password. Store an empty value and do not treat these markers as the password text.

Before asking for `1cv8.exe`, search installed 1C versions under existing `C:\Program Files\1cv8` and `C:\Program Files (x86)\1cv8` folders. Either folder may be absent; skip missing folders without error. Offer the found versions as choices and use the selected `bin\1cv8.exe` path. Do not offer the common `C:\Program Files\1cv8` root as a version.

Ask whether development branch infobases should be published to Apache for web-client testing. Store the answer locally in `.dev.env` as `WEB_PUBLISH_BY_DEFAULT=true` or `false`. If the answer is no, do not touch Apache. If yes, run `detect-apache`, save detected values to `.dev.env`, and do not ask the developer for Apache paths. If Apache is not detected, ask whether to install it automatically. After explicit agreement, run `install-apache`, then rerun `detect-apache`/`check-tools` and continue initialization. If the developer declines, offer only to disable publication or stop initialization until Apache is configured manually.

Prefer the PowerShell helper:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action init-project -InitMode wizard
```
