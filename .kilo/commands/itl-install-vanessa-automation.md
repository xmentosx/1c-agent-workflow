---
description: Install Vanessa Automation for ITL 1C branch tests
agent: code
---

Use the `1c-workflow` skill and execute `INSTALL_VANESSA_AUTOMATION`.

Install Vanessa Automation only after the developer explicitly requested this command or confirmed installation during project initialization. The helper downloads the official single EPF release, stores it locally under `.agent-1c/tools/vanessa-automation`, and writes the local paths to `.dev.env`.

Prefer the PowerShell helper:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action install-vanessa-automation
```
