---
description: Close the current ITL branch and export final CF/CFE result
agent: code
---

Run the helper directly from the current project directory:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action close-dev-branch
```

If the helper warns that fresh passed verification is missing, ask the developer for explicit confirmation before continuing. For confirmed unverified close, rerun with `-AllowUnverifiedClose`. If `VERIFICATION_POLICY=block`, do not ask for an override; run `/itl-verify` first.
