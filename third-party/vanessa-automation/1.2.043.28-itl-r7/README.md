# Vanessa Automation 1.2.043.28-itl-r7

This directory contains the minimal controlled downstream patch, immutable
provenance, license notice, and build contract. It does not vendor upstream
sources or a user-machine EPF.

Build the candidate from the repository root:

```powershell
& .\scripts\build-vanessa-automation-patched.ps1
```

The build clones the exact upstream tag, verifies its commit and canonical
archive SHA-256, verifies and applies this patch, and runs the upstream
`Compile.os` and `MakeVASingle.os` flows. Qualification promotes the exact EPF
bytes exercised by the live smoke; the candidate must not be rebuilt afterward.

Revision `itl-r7` retains the reduced `itl-r6` patch and fixes the cold
`run_scenario(filePath=..., mode=reloadAndRun)` callback path. The first feature
load now passes a call-local `already loaded` marker into the continuation. Only
that continuation skips the redundant second load and schedules execution for
the next wait-handler event, after the outer callback has completed its cleanup.
The deferred handler checks syntax and starts all scenarios. An already active
feature still follows the ordinary reload path.

The original MCP parameter structure is preserved throughout, including task
identifier, mode, and progress context. The managed form's global callback flag
cleanup order is unchanged.

No safe-mode path probes, `PATH_*` result contract, active-tab disk-check bypass,
or in-memory `reloadAndRunFromLine` substitution is present in this revision.
Consumers install only the qualified immutable artifact and verify its separately
recorded SHA-256.
