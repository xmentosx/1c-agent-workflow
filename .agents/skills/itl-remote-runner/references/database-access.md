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

## Interruption and current integration boundary

A crashed waiter has not been admitted and can be skipped. A crashed running
owner or failed cleanup leaves `needs-attention`: freeing an OS handle does not
prove that database side effects or surviving processes have stopped. No TTL
steal, lock-file deletion, record editing or automatic replay is supported.
Recovery must establish stopped owned work and completed restoration before a
future supported recovery action may release that record.

This implementation currently integrates the portable measurement engine.
Installed lifecycle, persistent facade admission, coordinated recovery and
real multi-host acceptance remain pending in source plan item 4. The queue must
not be advertised as exclusion against those routes until they are integrated.
External user sessions never become participants automatically and are not
terminated by this coordinator. A database profile is not permission to update
its configuration, install instrumentation or modify data.
