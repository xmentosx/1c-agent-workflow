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
Live 1C recovery adapters and their evidence remain required before recovering
those operations; a calibration/SQLite fixture does not qualify them.

This implementation currently integrates the portable measurement engine.
Installed lifecycle, persistent facade admission, live 1C recovery
and real multi-host acceptance remain pending in source plan item 4. The queue must
not be advertised as exclusion against those routes until they are integrated.
External user sessions never become participants automatically and are not
terminated by this coordinator. A database profile is not permission to update
its configuration, install instrumentation or modify data.
