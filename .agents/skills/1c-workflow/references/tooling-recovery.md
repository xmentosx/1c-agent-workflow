# Tooling readiness and recovery

Use `repair-dev-branch-tooling` through the compact runner for a ready development
branch whose Vanessa or YAxUnit prerequisites are absent, inactive or stale.
It stops only branch-owned runtime, uses lifecycle and per-infobase admission,
and restores pinned extensions without resetting the database or changing tests.
Do not call internal installation functions or edit state, locks or repair counts.

Database replacement invalidates both installation receipts before mutation and
advances the target generation. Legacy receipts require reconciliation once.
Every preparation probes requested extensions in a fresh Enterprise session:
installed and session-active names, runtime content hashes, security settings,
and the required VAExtension server-code metadata. Probe failure is a runner
prerequisite error; it must not be converted to a product assertion or hidden by
an installation loop. The probe writes its evidence under `build/tooling-probe`.

YAxUnit tracks the pinned engine and hierarchical test sources separately.
Unchanged, proven runtime skips loading; changed test sources load only tests;
a changed engine pin loads only the engine. A replaced database invalidates both.
The configured test extension name must match `Configuration.xml` before loading.

An exhausted verification session remains terminal. After an actual successful
tooling mutation newer than exhaustion and a fresh recovery receipt, `begin-verification-repair` may
archive that terminal record and start a new bounded session. Repeating recovery
against already-ready tooling does not grant another budget. Never change triggers
or counters to escape exhaustion. Then run the canonical unfiltered check; a
readiness probe or successful recovery is not YAxUnit/Vanessa/event-log acceptance.
