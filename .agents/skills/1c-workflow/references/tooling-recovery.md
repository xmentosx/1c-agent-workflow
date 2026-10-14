# Tooling readiness and recovery

Use `repair-dev-branch-tooling` through the compact runner for a ready development
branch whose Vanessa or YAxUnit prerequisites are absent, inactive or stale.
It stops only branch-owned runtime, uses lifecycle locks and a call-scoped exact-base execution guard,
and restores pinned extensions without resetting the database or changing tests.
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

On-demand MCP can recover a disappeared runtime record in the same external
connection only when the owning facade retains its original launch evidence.
The existing guard and cleanup owner prove quiescence, exact process and target
identity, related TestClient and immutable leases before replacement. Retry the
original `manage_test_client(connect)` through that same facade; a proven recovery
forwards it once and a following safe call confirms the replacement. Do not edit
or recreate the missing JSON, stop a guessed PID, or repeat an unknown modifying
call. If the owner reports an active call, wait for that operation to complete or
use its cancellation path. If ownership/cleanup is unconfirmed, retain the same
facade and its evidence for lifecycle-owner investigation; run
`repair-dev-branch-tooling` only after exact owned cleanup has been established.
Then resume the original check. A fresh chat does not prove same-connection
recovery. Legacy records remain readable; downgrade requires quiescent, resolved
work, and an older facade cannot inherit a live in-memory launch snapshot.

An exhausted verification session stops new attempts; an explicitly authorized
extension preserves that same session through the owner operation described in
[verification results](verification-result.md). After an actual successful
tooling mutation newer than exhaustion and a fresh recovery receipt, `begin-verification-repair` may
archive that terminal record and start a new bounded session. Repeating recovery
against already-ready tooling does not grant another budget. Never change triggers
or counters to escape exhaustion. Then run the canonical unfiltered check; a
readiness probe or successful recovery is not YAxUnit/Vanessa/event-log acceptance.
