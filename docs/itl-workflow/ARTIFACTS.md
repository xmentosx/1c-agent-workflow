# Project artifact placement

This contract applies to every client working in the project, including source
maintenance. It governs files whose output location the agent chooses.

## Choose the current project worktree

Put ad hoc diagnostics, raw tool-response captures, screenshots, investigation
scripts, downloaded investigation dependencies, unpacked research copies and
intermediate CF/CFE exports under ignored `build/agent-artifacts/<task-id>/` in
the current project worktree. Use `tmp/` inside that directory for disposable
intermediates, `evidence/` for proof and `recovery/` for recovery material.
Use a separate task directory to avoid collisions
with concurrent work. Do not use another branch's checkout or its main worktree.

Never choose a client home directory for those project files. This includes
`~/.codex/visualizations`, other directories under `CODEX_HOME`, and equivalent
Claude Code, Cursor, Kilo, OpenCode or other client homes. A host-provided writable
output directory is not a reason to choose it over the writable project.

Keep existing helper-owned locations authoritative: exports belong in their
configured result path, tests in their configured report path, and lifecycle
runs in their owned runtime directory. Do not redirect a helper's evidence,
snapshots or recovery files into the ad hoc directory. Put requested source,
documentation and final deliverables in the appropriate project location;
temporary placement must not hide intended versioned changes.

An explicit user destination takes precedence. If no project is selected or its
directory cannot be written, explain that specific limitation and obtain a
destination instead of silently falling back to a client home.

## Client and tool-owned exceptions

The client still owns its history, settings, authentication, internal state and
shared dependency caches. Preserve their supported locations. Reuse managed
shared caches rather than downloading a separate copy for each investigation.

When a tool fixes its own output location and offers no project-local output
option, preserve its contract and report the exact location and limitation.
Use a project-local destination whenever the tool supports one. Do not move,
delete or reconfigure client-owned files to enforce this rule, and do not copy
large outputs into both locations without a task requirement.

## Finish the task

Before the final task response, every client uses the same `clean-artifacts`
completion protocol below. Do not replace it with client-specific hooks or
recursive deletion. Closing a chat or switching clients does not prove that a
task or its consumers have finished.

After the task reaches a terminal outcome and all its file consumers and owned
processes finish, write an immutable `completion.json` inside its task directory,
outside `tmp/`. List exact project-relative disposable files below this task's
`tmp/` and all retained proof, inputs, recovery files and transitive dependencies.
Retained paths can be elsewhere in this project, including an older task's
`tmp/`. A directory, age or a filename alone never establishes disposability.
Databases, DT backups, original ETL, `source-snapshots` trees and `handoffs` are
never enrolled as disposable, even under `tmp/`. Preserve them for their owners.

```json
{
  "status": "completed",
  "cleanupConfirmed": true,
  "producer": "agent-task",
  "kind": "agent-task-temp",
  "taskRoot": "build/agent-artifacts/my-task",
  "disposablePaths": ["build/agent-artifacts/my-task/tmp/intermediate.cf"],
  "retainedPaths": [
    "build/agent-artifacts/my-task/evidence/result.json",
    "build/agent-artifacts/my-task/recovery/original.dt"
  ]
}
```

Run from the current project through the existing common helper:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\run-itl-command.ps1 -- -Action clean-artifacts -CleanupDiagnosticsOnly -DiagnosticCompletionPath 'build/agent-artifacts/my-task/completion.json'
```

Use the existing terminal statuses (`completed`, `succeeded`, `passed`, `failed`
or `cancelled`). A failed outcome still retains its failure evidence and inputs
needed for continuation; it does not become accepted merely because temporary
files can be removed. Use an empty `disposablePaths` array when only evidence
needs protection. The helper supports up to 4096 files per completion, in
immutable batches of 256; each stored batch must fit its existing 256 KiB bound.

This class becomes eligible immediately after confirmed completion. The helper
still checks exact file bytes, timestamps, open handles, retained dependencies
and current workflow references. Other diagnostic classes keep their configured
retention age. `ITL_ARTIFACT_CLEANUP_ENABLED=false` disables automatic cleanup
and completion-driven enrollment/removal as before. Repeating an unchanged
completion is safe after deletion; replacement bytes at an old path are not
silently enrolled again. Changed classifications need a new completion receipt.

After successful `reset`, the existing automatic `clean-artifacts` call retries
already enrolled disposable files, for example after a reader has closed them.
Retained proof and recovery remain at their original project paths; existing
branch-reset archives are untouched. No sweep or automatic adoption of legacy,
unknown or unfinished task directories occurs. Retention records and completion
receipts remain small audit/protection records; directories are not recursively
deleted. Explicit `clean-artifacts` also retries eligible files; `-CleanupDryRun`
previews already enrolled files without registering a new completion.

Report cleanup leftovers and retained large intermediates with their reasons;
an unsuccessful removal must not be reported as freed space. Do not edit an
enrolled manifest to force deletion. Preserve the file, close its owned consumer
or repair the missing retained evidence, then retry the same command. Keep runtime
artifacts out of Git; do not stage them merely because they are inside the project.
