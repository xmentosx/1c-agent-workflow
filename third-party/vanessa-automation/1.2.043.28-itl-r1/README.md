# Vanessa Automation 1.2.043.28-itl-r1

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

The patch removes the unconditional client-side `Новый Файл(...)` path
normalization used by `open_feature_file`, `load_features`, and
`check_syntax`. A constructor-free client-side probe uses the platform's
asynchronous file search, type check, and text read APIs and returns `PATH_INVALID`,
`PATH_NOT_FOUND`, or `PATH_ACCESS_DENIED`; `load_features` accepts either a
feature file or a directory.

Do not apply this patch to installed EPF/CFE files. Consumers install only the
qualified immutable binary artifact and verify its separately recorded
SHA-256.
