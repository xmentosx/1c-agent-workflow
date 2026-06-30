---
description: Show fast ITL 1C workflow actions
agent: code
---

Show this fast command menu. Do not load the full workflow skill before showing the menu.

Fast commands run the PowerShell helper directly and are intended for routine lifecycle operations:

```text
/itlx-init-project
/itlx-new-dev-branch <name>
/itlx-new-extension-dev-branch <name>
/itlx-set-dev-branch-extension <extension name>
/itlx-dump-dev-branch-extension
/itlx-activate-dev-branch-context
/itlx-update-dev-branch-base
/itlx-run-dev-branch-tests
/itlx-refresh-dev-branch
/itlx-export-dev-branch-result
/itlx-install-vanessa-automation
/itlx-sync-master
/itlx-close-dev-branch
/itlx-list-dev-branches
/itlx-switch-master
/itlx-switch-dev-branch <name>
```

If the user asks for script-level help, run:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action help
```

If a fast command fails, report the concise error and log path first. Open the detailed workflow references only when the user asks for explanation or recovery guidance.
