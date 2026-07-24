# Vanessa Automation 1.2.043.28-itl-r2

This directory contains only the controlled downstream patch, immutable
provenance, license notice, and build contract. It does not vendor upstream
sources or a user-machine EPF.

Build the candidate from the repository root:

```powershell
& .\scripts\build-vanessa-automation-patched.ps1
```

The build clones the exact upstream tag, verifies its commit and canonical
`git archive` SHA-256, verifies the patch SHA-256, applies the patch with
`git apply --check`, runs the upstream `Compile.os` and `MakeVASingle.os`
flows, and writes the ignored candidate under `build\third-party`.
For the upstream `MakeVASingle.os` qualification run, the build temporarily
extends the active unsafe-action-protection exception so it matches only its random
`C:\itlvabld\<id>\base` connection string. The user's local `conf.cfg` bytes
are restored in `finally`; the exception is never applied to a project
infobase or to Vanessa MCP runtime.

The 1C compiler does not promise byte-identical EPF output across independent
builds. Qualification therefore records and promotes the exact candidate bytes
used by the live smoke; it must not rebuild the EPF after that smoke. ZIP
packaging itself is deterministic: entries use ordinal path order and a fixed
timestamp, so repacking the unchanged qualified distribution produces the same
archive SHA-256.

The patch removes the unconditional client-side `Новый Файл(...)` path
normalization used by `open_feature_file`, `load_features`, and
`check_syntax`. A constructor-free client-side probe uses the platform's
asynchronous file search, type check, and text read APIs and returns `PATH_INVALID`,
`PATH_NOT_FOUND`, or `PATH_ACCESS_DENIED`; `load_features` accepts either a
feature file or a directory.

For `run_scenario`, the patch also avoids the redundant synchronous
`ФайлСуществуетКомандаСистемы(...)` check while an MCP task identifier is
active. Its progress-state builder derives the feature directory from the
already-qualified path without constructing another client-side `Файл`.
The server-side scenario metadata builder receives the active-MCP marker and
derives the optional `step_definitions` EPF path from that same qualified
string; non-MCP callers continue to use the original `Новый Файл(...)` path.
The active editor tab, saved-file, and `.feature` checks remain in place,
and non-MCP calls retain the original file operations.

The on-demand facade owns the MCP TestClient process. While its freshly
started client is not yet ready for a logical connection, Vanessa returns a
temporary not-connected result for the facade to retry. It does not enter the
ordinary interactive branch that starts another TestClient and performs
client-side executable/file checks. Interactive non-MCP TestClient startup is
unchanged.

Do not apply this patch to installed EPF/CFE files. Consumers install only the
qualified immutable binary artifact and verify its separately recorded
SHA-256.
