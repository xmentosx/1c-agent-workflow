# Disposable diagnostic artifacts

The existing `clean-artifacts` owner also consumes immutable producer receipts
under `.agent-1c/diagnostic-artifacts/<32-hex-id>.json`. It runs automatically
after successful ITL actions and terminal measurement process cleanup, without
Codex, chat automation or an additional confirmation. The retention age
is `ITL_DIAGNOSTIC_ARTIFACT_RETENTION_DAYS` (default 7, minimum 1); the existing
`ITL_ARTIFACT_CLEANUP_ENABLED=false` disables automatic cleanup.

The local and remote measurement engine creates a unique
`build/diagnostic-runtime/<id>/native-temp` in an installed Windows project and
passes it as TEMP/TMP to its owned command trees. After all process cleanup
succeeds, it writes an exact completion receipt and invokes the installed helper
with `-Action clean-artifacts -CleanupDiagnosticsOnly -DiagnosticCompletionPath
<project-relative receipt>`. The helper enrolls only the named native temporary
files, then applies the existing env age and protected-path policy. Unknown files
in that directory remain. An interrupted run or failed process cleanup never
enrolls its files. Retention failures go to `artifact-retention.json` as warnings
and leave the measurement result unchanged. Portable workers without an installed
project package retain their files. An older installed helper must be updated
before it can accept the new completion argument.

Other diagnostic producers use that same completion call with `producer`, `kind`,
`disposablePaths`, `retainedPaths`, terminal `status` and `cleanupConfirmed` in
their immutable receipt. A receipt is at most 1 MiB and names at most 4096 files,
registered in batches of 256. Alternatively, after a diagnostic reaches a
terminal outcome and its owned processes have finished cleanup, its producer
calls `Register-ItlDiagnosticArtifacts` from the
artifact-retention library. Supply the exact project root, producer name,
project-relative terminal receipt, kind, disposable file list and retained
originals. The terminal receipt must report `status` as `completed`, `succeeded`,
`passed`, `failed` or `cancelled`, and `cleanupConfirmed=true`. A failure may
finish cleanly without being accepted; registering its expendable files never
changes the diagnostic outcome or acceptance evidence.

Four producer-declared file classes are eligible:

- `native-temp`: individual `v8_<hex>_<hex>.tmp` files directly inside a
  `*-temp` directory below `build`, after their owning 1C processes finish.
- `derived-trace`: XML/ETLX derivatives below `build`, with the original ETL
  retained and hashed. Keep the decoder command/version, successful decoding
  result and any small extracted summary in the retained evidence list.
- `superseded-attempt`: individually named text/check artifacts of a completed
  attempt below `build`, with a successful replacement receipt outside that
  attempt. The producer supplies `attemptRoot`, `supersededBy` and the complete
  `retainedPaths` dependency list. References can reach much older attempts;
  neither a larger attempt number nor the latest three directories proves that
  an older file is disposable. Current evidence, unique source edits, live
  inputs, rollback material and executable helpers must remain. Databases,
  original traces, CF/CFE/DT, archives and source-snapshot trees cannot use this
  class. Unknown legacy directories require review, never automatic adoption.
- `agent-task-temp`: individually declared temporary files inside
  `build/agent-artifacts/<task>/tmp/`, after terminal task/consumer completion.
  This class is eligible immediately through the same owner; the other classes
  retain their age policy. Databases, DT backups, original ETL, source-snapshot
  trees and handoffs remain excluded. A temporary CF/CFE or investigation helper
  is eligible only in this task's `tmp/` and only when explicitly declared
  disposable. Proof, recovery and all transitive dependencies must be retained.
  The common completion protocol for every client is in
  [project artifact placement](../../../../docs/itl-workflow/ARTIFACTS.md).

Registration hashes each disposable and retained file and records exact size,
timestamp and enrollment time. It never enrolls a directory, a database, a DT backup, a raw
trace or a handoff. An analyzer response can expire only as an explicitly
superseded attempt; its current replacement and dependencies must remain.
Do not mark an artifact that
still serves as original test/validation evidence, a live input, an executable
workaround, a rollback snapshot or unfinished work. No heuristic sweeps old
unmarked investigations. Preserve raw inputs/outputs and cumulative counters.

Planning reads only bounded individual manifests in their dedicated directory and cheap candidate metadata;
hashing large files happens at registration and actual removal, not every
routine status. Execution rechecks the immutable manifest and retained original
hashes, then verifies and deletes the same exclusively opened Windows file
handle. Open files, byte/timestamp changes, missing originals, references from
the owning cleanup plan or another diagnostic receipt, and reparse/outside paths
retain the file. A missing, failed or changed replacement preserves its old
attempt. Unreadable dependency manifests skip diagnostic cleanup with a warning;
repair the producer's record before the next ordinary command. The next
ordinary cleanup can continue after the owner closes a file; no process is
stopped, guard bypassed or proof rewritten. Already removed entries are no-ops.

`Invoke-ItlDiagnosticArtifactCleanup -ProjectRoot <root> -DryRun` provides a
diagnostic-only preview for an existing trusted package caller. Its default age
is seven days; automatic callers pass the age from the existing policy and honor
its enabled flag. `-MinimumAgeDays 0` is reserved for an explicitly authorized
reviewed immediate cleanup. The caller supplies `-ProtectedPaths` from
`Get-ItlArtifactProtectedPaths`; do not create a second deletion policy.

Project callers can use the existing helper command
`agent-1c.ps1 -Action clean-artifacts -CleanupDiagnosticsOnly -ProjectRoot <root>`.
It honors the enabled flag and diagnostic age, uses the existing lifecycle lock
and protected evidence paths, and does not sweep CF, run or recovery archives.
Add `-CleanupDryRun` for a preview. Keep routine output bounded to counts/bytes;
retained-file warnings explain why the original task's files were left intact.
Fresh files survive enrollment and become eligible at a later diagnostic
completion or ordinary automatic ITL cleanup. There is no idle-time timer or
resident service; an inactive project does not generate new diagnostic files.

Agent-task completions additionally bind `taskRoot` and keep their completion
receipt outside `tmp/`. Batches use identity derived from the unchanged receipt,
canonical exact file list and retained paths, so a repeated completion reuses
its original records even after deletion. It cannot adopt replacement bytes at
an old path. An empty disposable list can register evidence protection alone.
Deletion rechecks current workflow proof/recovery references as well as the
retained file hashes. The existing successful-reset cleanup retries registered
leftovers; it does not enroll unknown or unfinished tasks, move ignored proof
into the reset archive, or recursively remove the task directory. Small audit
and protection receipts remain. Disabling automatic cleanup also disables
completion-driven enrollment/removal; a dry-run does not enroll a new receipt.

When a branch command finishes a check and adopts its successful replacement,
the producer can send this completion through that same command (paths below
are illustrative):

```json
{
  "status": "failed",
  "cleanupConfirmed": true,
  "producer": "branch-check",
  "kind": "superseded-attempt",
  "attemptRoot": "build/checks/attempt-1",
  "supersededBy": "build/checks/attempt-2/result.json",
  "disposablePaths": ["build/checks/attempt-1/answer.raw.json"],
  "retainedPaths": ["build/checks/attempt-2/answer.raw.json"]
}
```

The replacement receipt must have `status` equal to `passed`, `succeeded` or
`completed`. The producer lists all transitive dependencies in `retainedPaths`,
including files in older attempts. The helper also retains the replacement
receipt automatically and hashes it. Enrollment waits seven days by default;
the next relevant successful branch command performs cleanup locally. No timer,
external service, directory-wide deletion or verification acceptance change is
introduced. An ordinary command without a producer receipt only cleans already
marked files; it cannot infer which arbitrary agent-generated attempts ended.

Legacy investigations need a separate read-only task/evidence review before
the producer can enroll individual regenerable files. Unknown completion,
unknown ownership or a missing original means retain, not a new approval gate
on the original development task. Reports must distinguish eligible logical
bytes, compressed storage, actual deletions and filesystem free-space changes.
