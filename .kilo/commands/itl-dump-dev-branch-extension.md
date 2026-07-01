---
description: Dump extension files from the current ITL extension branch infobase
agent: code
---

Run the helper directly from the current project directory:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action dump-dev-branch-extension
```

Do not ask for a development branch name. The helper infers it from the current `itldev/<name>` Git branch and uses the extension name saved in branch state. If the helper reports that the extension name is missing, ask the developer to run `/itl-set-dev-branch-extension <extension-name>` first.
