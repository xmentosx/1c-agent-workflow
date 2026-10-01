# Workflow update recovery

Use `scripts/update-installed-workflow.ps1` from a clean compatible Git source
checkout, outside the installed project. The launcher delegates to the existing
`update-workflow` owner and its per-root operation lock. Never edit a transaction
receipt, reset the project, run an old installer over new client membership, or
delete the only before snapshot. No infobase load or test run is part of these
file/settings recovery operations.

## Completed update

`-Recovery status` lists retained completed snapshot ids and any pending root
phase. `-Recovery restore -SnapshotId <id>` returns the selected package and
owned settings in a workflow-only inverse commit. Original business bytes and
staging remain intact. The snapshot includes ignored dotenv, MCP ownership and
originally absent paths. Later HEAD, changed owned files or corrupted backup
proof stop before restoration. Interrupted restore and a lost commit
acknowledgement resume through the same command and root receipt. An unresolved
business merge needs its original compatible lifecycle recovery before backward
rollback; do not abort it as a package-update workaround.

CLI caches and external stores remain outside this return. Git local runtime
excludes keep the retained CLI cache and execution-generation file ignored even
after restoring an older tracked `.gitignore`. Reopen/reload the client context
after completion. Completed capsules remain ignored project runtime and contain
settings; do not commit or publish them. The current owner has no automatic
age cleanup for completed capsules.

## Ambiguous post-copy state

A hard interruption can leave `post-copy-running` with outputs that were written
after the last path-state checkpoint. A mismatch does not prove whether those
bytes came from the helper or from later user work. The normal command keeps the
guard strict and supplies this continuation:

1. Run `-Recovery status -SnapshotId <pending-id>` from the compatible source.
   It validates the recorded candidate, branch/HEAD, runtime scope and before
   backups, then preserves changed current files and available exact source
   candidates inside the pending snapshot. The bounded result gives `reportPath`
   and `reportSha256`; file contents, including settings, stay in ignored runtime.
2. Inspect every report path against its recorded phase and writer. A raw source
   file is not the rendered client/settings candidate. Reconstruct generated
   output from preserved before bytes and the recorded writer when needed.
   Genuine user/foreign edits remain blocked for semantic reconciliation; do not
   describe them as helper output merely to continue. Partial directory output
   also requires an owner-specific repair and fresh report.
3. For confirmed interrupted helper outputs only, write a decision file:

   ```json
   {
     "schemaVersion": 1,
     "reportPath": "<absolute path returned by status>",
     "reportSha256": "<exact report hash>",
     "paths": [{
       "relativePath": "<report path>",
       "observedState": "<exact report hash/state>",
       "decision": "resume-confirmed-helper-output",
       "reason": "<concrete writer/content evidence>"
     }]
   }
   ```

   Cover exactly all changed paths, once each. Run `-Recovery reconcile
   -SnapshotId <pending-id> -ReconciliationFile <absolute decision path>`.
   It checks the unchanged report, receipt, source, HEAD, backups and every
   current owned path. A new edit refuses acknowledgement. It persists reviewed
   hashes and their audit; project files, HEAD and business staging do not change.
4. Repeat the update through a compatible source helper. The recorded exact
   candidate checkout must still exist, clean and unchanged. A newer clean source
   can supply the executing helper through `scripts/update-installed-workflow.ps1`;
   recovery records both identities and keeps the old package payload pinned.
   The existing post-copy owner continues, commits, retains terminal proof and
   reports branch rollout separately. `WORKFLOW_UPDATE_NEW_CANDIDATE_PENDING`
   means that recovery completed the old update: repeat the same source-side
   command to install the requested new package. The agent owns this repeat.
   After a lost acknowledgement, inspect status and repeat the original update;
   do not treat a stale decision report as authority.

Before/current/source copies stay with the capsule after completion. Absolute
paths in the historical report refer to its original pending location; the
`*RelativePath` fields resolve from the report directory after retention too.
Copy/commit/rollback phases use their own existing recovery and cannot be
acknowledged through this file-only post-copy route.

At the master commit checkpoint, the original root snapshot still owns retired
rule files and tracked client config even if an interrupted writer already
advanced the current manifest. Commit uses its explicit recorded paths and
validated before backups, preserving foreign config text. Planned paths alone
never grant ownership of business changes; missing or changed before backups
retain the snapshot and require recovery of those exact bytes.

For a stopped development-branch package update, repeat `update-workflow` from
master. Its current owner verifies and completes the recorded old payload under
the same branch lease, then installs the requested new package. Both candidate
checkouts must remain clean and exact. Business staging, a pending merge and its
original lifecycle record stay with their existing owner; repeat that original
business command separately after the package update.

For a stopped `fork-dev-branch`, repeat the original fork command from its source
branch. The fork owner retains its original business anchor and immutable base
snapshot. It accepts a replacement package only through the exact retained
completed-update chain and preserves target-branch settings and proven completed
restoration. Later source business changes do not replace the captured snapshot.

## Client membership failure

Attach/detach snapshots cover client-surface and MCP ownership receipts plus all
client roots, including ZCode and MiMo Code. An ordinary failure restores those
files and the previous client set. When MCP preflight detects a user collision,
late edit or unconfirmed write, recovery preserves current MCP files and ownership
receipts instead of overwriting them with a snapshot. Other owned paths return to
their previous state. Review the reported conflict, then repeat the original
attach/detach command; completed MCP writes retain their ownership for that repeat.
