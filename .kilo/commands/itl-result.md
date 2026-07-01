---
description: Export CF or CFE result for the current ITL branch
agent: code
---

Run the helper directly from the current project directory:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action export-dev-branch-result
```

If the helper warns that fresh passed verification is missing, ask the developer for explicit confirmation before continuing. For confirmed unverified export, rerun with `-AllowUnverifiedResult`.
