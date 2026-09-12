# Database admission

The portable engine reserves all configured databases before preparation and
keeps them until measurement and cleanup finish. `access.additionalBases` and
the configured Vanessa manager base are acquired together with the target.
Nothing is held partially while waiting. Older conflicting tickets run first;
an unrelated database may proceed. A per-job claim prevents duplicate execution.

## One authority and database identity

Every participating executor must configure the same `access.coordinator`
directory (for example a secured SMB share on the execution network). The
directory must support cross-client OS byte locks and atomic rename. A sharing
path being configured does not itself prove its filesystem semantics: qualify
two real execution hosts before claiming remote exclusion. There is no fallback
to local coordination when the configured authority is unavailable.

Without a configured directory, `%PROGRAMDATA%/ITL/infobase-access` coordinates
only the execution host; the result explicitly records that limited scope.
Workspace/project paths never distinguish two jobs using the same database.
Server connection text is normalized; local file paths include the host, while
UNC paths identify the shared file location. DNS aliases or alternate connection
routes need explicit registration instead of guessing that they are equivalent.

Create a UTF-8 JSON array of the authorized connections, such as two
`{"kind":"server","path":"host:port/reference"}` entries. Register them with
`remote_work.py access-register --coordinator <directory> --resource <stable-id>
--bindings <file.json>`. Registration rejects conflicting ownership and refuses
to split an identity currently in use. Configure the same authority on each
project/host; do not put passwords in the registration. `access-status
--coordinator <directory>` lists active owners and waiters without lease tokens.
The coordinator upgrades its storage only when no legacy owner is live. Active
tickets then remain in a small resource index, while released and cancelled
tickets move to an exact-addressed archive and are not scanned by admission or
status. Exact full evidence remains addressable for a conservative 90-day
recovery horizon by default. `remote_work.py access-compact --coordinator
<directory> [--shards <1-256>]` incrementally replaces older full records with
small identity tombstones, then removes tombstones 730 days after compaction.
One restartable cursor and a default batch of 128 records per shard bound each
pass; a crash after record or cursor publication is idempotently resumed.
`access-retention-configure --coordinator <directory>
--recovery-horizon-days <1-3650> --tombstone-retention-days <horizon-3650>
--batch-size <1-10000>` atomically changes these persistent authority-wide
values through a restartable policy-first transaction, so an interrupted
shorter horizon can only retain pins too long. A compaction invocation visits
at most 512 archive records regardless of `--shards` and configured batch size.
Run `access-cleanup --coordinator <directory> [--shards <1-256>]` to retry at
most 128 cleanup debts per invocation. Both maintenance routes use persisted
fixed-size queue pages and direct slot reads; they do not enumerate an archive
or debt shard before applying the cap. Ineligible entries move once to the tail
and completed head pages are reclaimed after a restartable checkpoint, bounding
live queue markers to outstanding work plus one partial page. Cleanup advances
its cursor only after every selected debt is retired or durably requeued, so a
pre-item crash cannot skip work even while new debt arrives. Admission and
status neither scan nor rewrite cleanup debt. Run compaction and cleanup as
maintenance; they never run in admission or status. The unpublished intermediate `cleanup-debt.json`
format is deliberately unsupported: its presence fails closed with
`INFOBASE_ACCESS_CLEANUP_DEBT_LEGACY_UNSUPPORTED` instead of silently ignoring
possible debt; use the intermediate build that created that authority to drain
it before upgrading.

A durable recovery plan pins its ticket before recovery can make it terminal
and removes only its own pin after terminal state is reflected in the job
state. Source-sync phase receipts likewise pin their producer ticket before
publishing the record reference. A successor observes it without mutation,
durably saves the consumed/completed lifecycle state, and only then sends an
explicit idempotent consume acknowledgement which removes that phase pin.
Multiple plans and phases have independent pins. Pins expire no later than the
configured tombstone horizon, so abandoned consumers become explicit bounded
retention debt rather than permanent archive growth. Pending terminal-record
or `.alive` cleanup debt also prevents premature compaction. Within the recovery horizon
(or while pinned) exact lookup returns the full record; after compaction it
returns `INFOBASE_ACCESS_TICKET_COMPACTED`, distinct from a never-known or
expired ticket. Older runtimes fail closed on the new layout marker instead of
bypassing its queue.

## Waiting and inherited ownership

`waitTimeoutSeconds` is 0-86400, default 3600; zero allows immediate admission
only. This budget is independent of scenario phase timeouts. Waiting publishes
`waiting-for-base`, blocking operations, host/PID, project, ticket and elapsed
time. The normal job cancel request stops the wait without starting 1C. After
admission the engine checks package hashes and changes to the worker profile;
preparation remains responsible for actual loaded configuration/data evidence.

`context.json.accessLease` and `ITL_INFOBASE_ACCESS_LEASE` carry a private token
for explicitly nested operations. They may inherit only a subset of the
parent's registered resources while its ticket remains running and its OS lock
is held. A nested operation never releases the parent's ownership. User-facing
results contain the ticket, resources, coordination scope and queue duration,
not the token. All source capture and reset/cleanup happen outside sample timing.

### Private native caller channel

`itl_remote.access_host` exposes the same Python lease implementation over
private parent/child stdio pipes. `scripts/DatabaseAccess.ps1` supplies its
PowerShell adapter using shared native quoting and an explicit UTF-8/ASCII JSON
boundary. It requires Python 3.11+. This is an internal live-owner channel,
not a user-facing recovery or force-unlock command. Do not send its input or
admission response to logs: the admitted response contains the inherited token.
Waiting/progress and terminal responses contain no token.

The caller supplies the complete resolved resource set before acquiring any
project/runtime lock. It keeps the pipe owner through the entire operation and
cleanup, then confirms cleanup or reports its errors. Disconnect/cancellation
after admission retains `needs-attention`; before admission it cancels only the
waiter. An inherited host never releases the outer owner. PowerShell cancellation
observed before handing the grant to the operation starts no database work.
Callers must not treat closing the pipe or killing its host as successful cleanup.

The channel alone does not integrate an entrypoint. Lifecycle and persistent
facade wiring remains required. In particular, a persistent backend that still
holds a database cannot be treated as a released operation merely because one
tool response returned: its stop/idle path must retain inherited access and
must not reacquire behind a lifecycle waiter. Resolve and pin newly generated
Vanessa manager-base paths before admission, then revalidate after waiting;
reserving only the target while creating an unreserved manager is insufficient.

The shared helper's read-only `Get-VanessaServiceInfoBasePlan -State ...`
selects the qualified existing manager or a new generation without creating it.
Include the returned `kind`/`path` in the complete reservation, then pass the
same object to `Ensure-VanessaServiceInfoBase -State <current-state>
-AdmissionPlan <plan>` after admission. Ensure rechecks relevant state, marker,
database presence and current template before any native call. Changed inputs
require resolving/admitting the resource set again; an occupied new-generation
path is never adopted. Serialized template paths are not executed. Ordinary
Ensure callers still obtain a new plan internally; entrypoint wiring must move
planning before admission rather than reserving only the eventual launch.

### Project and branch initialization

Project initialization determines its source connection in the wizard/settings
phase, releases the local lifecycle lock, then reserves the source and seed
databases before any native preparation. Standalone runtime initialization and
workspace adoption reserve their exact future target plus the planned Vanessa
manager before lifecycle locking. Saved manager generations remain part of a
resumed initialization's plan.

Branch creation uses the retained seed without reserving the live source. When
the seed must first be built, the source phase has its own admission. After the
Git phase, the helper releases that source admission before waiting for the new
target. Forking likewise releases the source after its immutable snapshot is
complete, then admits the target. Fork state never inherits the source's Vanessa
manager; a resumed fork preserves only the target's admitted manager inputs.

Each handoff rechecks current configuration and rejects an environment-file or
database-address change before native work. A busy target uses the ordinary
bounded wait/cancellation policy without holding the preceding lifecycle lock
or a partial database reservation. Completed phases publish their acknowledgement
before release. Interrupted native effects still require the supported recovery
inspection below; these entrypoints do not enable timeout-based ownership theft.

## Interruption and current integration boundary

A crashed waiter has not been admitted and can be skipped. A crashed running
owner or failed cleanup leaves `needs-attention`: freeing an OS handle does not
prove that database side effects or surviving processes have stopped. No TTL
steal, lock-file deletion, record editing or automatic replay is supported.
`access-recovery-plan --coordinator <directory> --ticket <ticket>` inspects an
orphan without changing its record. It returns the whole resource set, original
owner and revision, without a lease token. A live owner cannot be recovered.

The recovery protocol claims the original complete resource set using that
revision and the OS owner lock; a changed plan must be inspected again. It keeps
the original owner/sequence and an audit of attempts, rotates the private token,
and rejects late releases or inherited calls using the old token. Waiters remain
queued behind active recovery. An interrupted or incomplete recovery retains
`needs-attention`; neither claim nor normal context exit releases the bases.

An operation-specific adapter must verify stopped owned work and completed
restoration under that ownership before calling completion. The coordinator
checks full resource coverage and records the adapter's evidence, but cannot
infer database quiescence from a dead Python process. There is deliberately no
CLI accepting `passed: true`, a force-unlock flag, or arbitrary cleanup command.
The generic ticket command provides inspection only. Jobs with an original
pinned recovery contract use the [job recovery commands](job-recovery.md).
Workflow tickets have the separate `access-recover-workflow --coordinator
<directory> --ticket <ticket>` adapter. Invoke it through
`scripts/Invoke-RemoteWork.ps1 -Arguments @(...)` so the package resolves its
managed Python runtime. Select the original operation's coordinator and ticket;
this does not rerun the interrupted command. Supported local file-base paths are
pre-native cursor recovery, repository-capture reconciliation and extension
initialization/smoke snapshot rollback with retained lifecycle context. Native
rollback imports the captured helper generation and uses a private recovery
participant. It preserves interrupted source/state/environment files, restores
the original source/environment, invalidates tooling and verification receipts,
and releases admission only after native and lifecycle evidence is complete.
If initialization's successful commit was already acknowledged before the crash,
the adapter preserves the result and releases admission after live inspection.
It does not require a snapshot that normal completion already removed, replay
initialization or report fresh verification. Pending duties, later native work,
additional business databases and occupied/damaged service bases prevent this
completion path. Completed rollback and smoke finalization use their own contracts.
For a server resource, native work starts only when the configured
`serverBaseCopyScript` advertises schema-2 capability `recovery-observe`. Its
path and SHA are bound into the native intent. The operation accepts no session
list or owner override: for each exact `/S` identity it returns schema-1 JSON
with `observationId`, `infoBase`, `databasePresent`, integer `sessionCount`, and
`exclusive`; `exclusive` is true exactly when the authoritative server inventory
contains zero sessions. Recovery invokes it twice through the original host and
retained provider bytes. A missing, changed, redirected, timed-out, malformed or
nonzero-session observation keeps `needs-attention`; it never stops a foreign
server session or steals the queue entry.

During rollback, an unused reservation may remain absent only when the captured
context proves that absence. After a committed initialization, an absent planned
service generation must have no native launch in the indexed journal. Missing
existing databases, surviving sessions and unsupported
additional business-database changes retain `needs-attention`. Provider-backed
server observation still needs live server and multi-host qualification; do not
substitute a calibration/SQLite fixture or a manual success flag.

Source integration covers the portable measurement engine and the fourteen
public lifecycle operations listed in the mutation admission route. Installed
delivery, remaining entrypoints, live server recovery and real multi-host acceptance
remain pending in source plan item 4. Do not advertise exclusion against routes
that have not been integrated and qualified.
External user sessions never become participants automatically and are not
terminated by this coordinator. A database profile is not permission to update
its configuration, install instrumentation or modify data.
