# Vanessa Automation 1.2.043.28-itl-r8

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

Revision `itl-r8` retains the reduced `itl-r7` patch and fixes the cold
`run_scenario(filePath=..., mode=reloadAndRunFromLine, lineNumber=...)` callback
path. The first feature load carries the original call-local mode and line into
the existing load-completion callback. That callback selects the requested
scenario step directly, so no redundant second asynchronous feature load can
erase the cold selection. An already active feature keeps the upstream reload
semantics.

The original MCP parameter structure is preserved throughout, including task
identifier, mode, line, and progress context. No facade retry is added, so a
scenario cannot be executed twice by recovery logic.

No safe-mode path probes, `PATH_*` result contract, active-tab disk-check bypass,
or in-memory editor substitution is present in this revision. Consumers install
only the qualified immutable artifact and verify its separately recorded SHA-256.
