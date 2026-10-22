# Disposable diagnostic artifacts

The existing `clean-artifacts` owner also consumes immutable producer receipts
under `.agent-1c/diagnostic-artifacts/<32-hex-id>.json`. Its automatic invocation
after successful ITL actions needs no additional confirmation. The retention age
is `ITL_DIAGNOSTIC_ARTIFACT_RETENTION_DAYS` (default 7, minimum 1); the existing
`ITL_ARTIFACT_CLEANUP_ENABLED=false` disables automatic cleanup.

After a diagnostic reaches a terminal outcome and its owned processes have
finished cleanup, its producer calls `Register-ItlDiagnosticArtifacts` from the
artifact-retention library. Supply the exact project root, producer name,
project-relative terminal receipt, kind, disposable file list and retained
originals. The terminal receipt must report `status` as `completed`, `succeeded`,
`passed`, `failed` or `cancelled`, and `cleanupConfirmed=true`. A failure may
finish cleanly without being accepted; registering its expendable files never
changes the diagnostic outcome or acceptance evidence.

Only two producer-declared file classes are eligible:

- `native-temp`: individual `v8_<hex>_<hex>.tmp` files directly inside a
  `*-temp` directory below `build`, after their owning 1C processes finish.
- `derived-trace`: XML/ETLX derivatives below `build`, with the original ETL
  retained and hashed. Keep the decoder command/version, successful decoding
  result and any small extracted summary in the retained evidence list.

Registration hashes each disposable and retained file and records exact size,
timestamp and completion time. It never enrolls a directory, a database, a raw
trace, a response from an analyzer or a handoff. Do not mark an artifact that
still serves as original test/validation evidence, a live input, an executable
workaround, a rollback snapshot or unfinished work. No heuristic sweeps old
unmarked investigations. Preserve raw inputs/outputs and cumulative counters.

Planning reads only bounded individual manifests in their dedicated directory and cheap candidate metadata;
hashing large files happens at registration and actual removal, not every
routine status. Execution rechecks the immutable manifest and retained original
hashes, then verifies and deletes the same exclusively opened Windows file
handle. Open files, byte/timestamp changes, missing originals, references from
the owning cleanup plan and reparse/outside paths retain the file. The next
ordinary cleanup can continue after the owner closes a file; no process is
stopped, guard bypassed or proof rewritten. Already removed entries are no-ops.

`Invoke-ItlDiagnosticArtifactCleanup -ProjectRoot <root> -DryRun` provides a
diagnostic-only preview for an existing trusted package caller. Its default age
is seven days; a scheduled caller must pass the age from the existing policy
and honor its enabled flag. `-MinimumAgeDays 0` is reserved for an explicitly
authorized reviewed immediate cleanup. A recurring caller must not use it.
The caller can supply `-ProtectedPaths` from `Get-ItlArtifactProtectedPaths`.
Use the same functions for scheduling; do not create a second deletion policy.

Scheduled project callers can use the existing helper command
`agent-1c.ps1 -Action clean-artifacts -CleanupDiagnosticsOnly -ProjectRoot <root>`.
It honors the enabled flag and diagnostic age, uses the existing lifecycle lock
and protected evidence paths, and does not sweep CF, run or recovery archives.
Add `-CleanupDryRun` for a preview. Keep routine output bounded to counts/bytes;
retained-file warnings explain why the original task's files were left intact.

Legacy investigations need a separate read-only task/evidence review before
the producer can enroll individual regenerable files. Unknown completion,
unknown ownership or a missing original means retain, not a new approval gate
on the original development task. Reports must distinguish eligible logical
bytes, compressed storage, actual deletions and filesystem free-space changes.
