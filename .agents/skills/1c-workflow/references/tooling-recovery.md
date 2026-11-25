# Tooling readiness and recovery

Use `repair-dev-branch-tooling` through the compact runner for a ready development
branch whose Vanessa or YAxUnit prerequisites are absent, inactive or stale.
It stops only branch-owned runtime, uses lifecycle locks and a call-scoped exact-base execution guard,
and restores pinned extensions without resetting the database or changing tests.
Its first phase, before admission, stops this worktree's own guard holders and names
each one it preserves: another worktree, a holder of a shared base, an unproven owner,
or a mutating Designer that its own timeouts bound. Interactive 1C sessions remain
foreign. A wait that only this worktree's active holder blocks ends with
`EXECUTION_GUARD_BRANCH_HOLDER_RETAINED` and routes here; a holder that reported
`cleanup-unconfirmed` or `idle` is released by the waiting command itself.
Do not call internal installation functions or edit state, locks or repair counts.

Repair plans the target database, recorded runtime cleanup databases and exact
service-base generation before native work. It releases lifecycle locks while
waiting, acquires the complete resource set all-or-none, then reacquires locks and
revalidates the plan. Test-profile databases and test classification are not
repair prerequisites; a broken test manifest must not prevent restoring the tools.
Changed database addresses after waiting stop before mutation.

Database replacement invalidates both installation receipts before mutation and
advances the target generation. Legacy receipts require reconciliation once.
Every preparation probes requested extensions in a fresh Enterprise session:
installed and session-active names, runtime content hashes, security settings,
and the required VAExtension server-code metadata. Probe failure is a runner
prerequisite error; it must not be converted to a product assertion or hidden by
an installation loop. The probe writes its evidence under `build/test-results/tooling-probe`
and caches its EPF under `.agent-1c/tmp/tooling-probe`; both roots remain ignored
when a rollback restores an older workflow baseline.

YAxUnit tracks the pinned engine and hierarchical test sources separately.
Unchanged, proven runtime skips loading; changed test sources load only tests;
a changed engine pin loads only the engine. A replaced database invalidates both.
The configured test extension name must match `Configuration.xml` before loading.

On-demand MCP recovers a disappeared runtime record in the same external
connection: the facade stops only what it launched itself (exact PID, start time
and EXE) and starts a replacement, never waiting on other processes, ports or
leases. Retry the original `manage_test_client(connect)` through that same
facade; a following safe call confirms the replacement. A facade never keeps
the infobase between calls: an unconfirmed stop ends its call, drops that
backend and the next call starts a new one. Do not edit or recreate the missing
JSON, stop a guessed PID, or repeat an unknown modifying call. If an active call
holds the base, wait for it or use its cancellation path. If leftover processes
or holders of this worktree still block the base, run `repair-dev-branch-tooling`:
it releases them without a guessed PID. Then resume the original check; the MCP
client needs no restart. Legacy records remain readable.

An exhausted verification session stops new attempts; an explicitly authorized
extension preserves that same session through the owner operation described in
[verification results](verification-result.md). After an actual successful
tooling mutation newer than exhaustion and a fresh recovery receipt, `begin-verification-repair` may
archive that terminal record and start a new bounded session. Repeating recovery
against already-ready tooling does not grant another budget. Never change triggers
or counters to escape exhaustion. Then run the canonical unfiltered check; a
readiness probe or successful recovery is not YAxUnit/Vanessa/event-log acceptance.
