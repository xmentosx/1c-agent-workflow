---
description: Initialize an ITL 1C project
agent: code
---

This is a direct bootstrap-only wrapper, not part of the normal `/itl` beginner menu.

Run the monitored helper wizard from the current project directory:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\run-agent-1c-window.ps1 -- -Action init-project -InitMode wizard
```

Do not collect the initialization questionnaire in chat or Kilo Questions before this first helper attempt. The monitored wizard opens a PowerShell window, confirms the current project directory, collects setup values including dependency mode (`fresh` by default, `locked` only for a populated lock manifest), writes `.dev.env`, `.agent-1c/project.json`, and `.agent-1c/dependency-lock.json`, runs the initialization lifecycle, and reports completion back through `.agent-1c/runs/<run>/status.json`.

Run the monitored command in the foreground and wait for it to finish. Do not wrap initialization in a background PowerShell launch, do not keep the launched PowerShell session open after the helper exits, and do not call `agent-1c.ps1 -Action init-project -InitMode wizard` directly as the default agent path.

Do not run a separate `Test-Path` preflight before this launcher. The launcher validates the helper path itself, and raw PowerShell probes can emit serialized `CLIXML` progress records. If the shell tool accepts a timeout, use a positive long timeout such as `1800000` ms for this interactive wizard; never use `timeout: 0`.

Use `-KeepWindowOnFailure` only for manual debugging when the developer explicitly wants the external PowerShell window to stay open after a failure.

If the wizard fails because terminal input is unavailable, do not collect the questionnaire in chat and do not continue the lifecycle manually. Use the monitored wizard command above, or use JSON mode only when the developer explicitly requested non-interactive initialization or an answers file already exists.

Use non-interactive JSON mode only when an answers file already exists or the developer explicitly asks for it:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action init-project -InitMode json -InitAnswersPath <answers.json>
```
