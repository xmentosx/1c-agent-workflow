# Windows MCP storage retention

The existing host watchdog owns Windows-volume observation and scheduling under
`host-maintenance.lock`. BuildKit owns cache eligibility, cutover owns accepted
snapshot/deployment history, and Mantis owns native generation publication and
retirement. No host filesystem sweep may delete an index generation.

## Configuration and operation

`storageRetention` in `host.config.json` is opt-in; see the example configuration.
The approved dev-ermakov policy uses 50 GiB low space and a 20 GiB reserve, daily
online collection, a 10 GiB target for unused private build cache older than seven
days, and at least two accepted transitions plus fourteen days for snapshots.
This is not a hard total-storage cap: protected data can exceed these targets.

Use the installed host entrypoint with `-Action storage-status` to read settings,
last observations and errors; `storage-plan` inventories candidates without
deleting them. `storage-run -StorageOnlineOnly` runs eligible online collection
through the existing maintenance lease. Ordinary watchdog cycles use the same
owner. Busy owners leave the attempt pending; no foreign job is stopped.
Unchanged healthy cycles are quiet. Threshold crossings and changed cleanup
failures produce warnings and bounded status; cleanup failure does not turn a
healthy MCP into an unavailable one. Resolve the named owner error and repeat
`storage-run`, or allow the next scheduled attempt after its cooldown.

Windows free bytes come from the volume containing `stateRoot`. Linux `df` inside
Docker's dynamically expanding disk cannot establish Windows free space. A
host-initiated heavy operation needs its estimated temporary allocation plus the
20 GiB reserve. Existing mounted data, measured read-only through the pinned
image, supplies snapshot/rebuild estimates with filesystem overhead and margin.
If admission fails, eligible online cleanup runs once and admission is rechecked.
`MCP_STORAGE_DEFERRED` names the original continuation: free eligible data or
expand the disk, then repeat the original operation. Capacity admission occurs
before stopping an accepted cutover runtime. Incremental nightly work retains
its owner and requires the reserve without inventing a full-rebuild allocation.

## Eligibility and recovery

BuildKit candidates must be reclaimable, private, immutable and old enough.
Immediately before collection the exact planned IDs are checked again. Boolean
CLI filters are not trusted: installed buildx versions differ. Native `until`
filters establish age even when JSON contains relative human dates. Numeric-byte
and older human SI size fields are supported. In-use/shared or
unknown records remain protected. No blanket `system prune` or volume prune runs.

New retained cutovers enroll only after native coverage/tool qualification and
a control main restart. Snapshot creation alone is not acceptance. The host
records the exact manifest SHA, service, retired container/image identity and
acceptance time. Older eligible records still require unchanged manifest/archive
hashes, an ordinary directory under the exact snapshot root, no added evidence,
and no current/pinned/unfinished/failed dependency. Unknown legacy snapshots are
retained. Historic failed-run data does not become disposable through its age.
Remaining snapshots protect the Docker resources they reference; live or changed
containers and shared images remain protected. Unclassified legacy snapshots
also protect image deletion because their full image dependencies are unknown.
Online cache/snapshot collection needs its own build/cutover owners idle; an
independent index worker cannot prevent eligible cold-data collection. Offline
VHD reclaim additionally requires every relevant indexing owner idle.
A concurrent Docker start cannot
be killed by collection: removal never uses force. Native data/model volumes
remain with their native generation owner unless a complete retirement binding
proves them disposable. Interruption retains the catalog and continues from the
observed snapshot/container identities, without replaying an expanded deletion.

Future snapshots inherit the configured NTFS compression attribute; archive
contents and SHA remain unchanged. Disabling retention stops future removals;
already removed disposable cache requires rebuilding. Serving data and the
protected rollback payload are never rollback inputs for cleanup itself.

## Optional detached VHD reclaim

The approved maintenance window is Sunday 03:30–04:00 in the Windows host's local
time (Europe/Moscow on dev-ermakov). It runs at most once per date, only below
50 GiB free and with at least 10 GiB estimated reclaimable allocation. Active
indexing/builds/host maintenance defer it. The exact configured `vhdPath` is
required. Missing Hyper-V cmdlets cause a diagnostic; no elevation is attempted.

Only guest free blocks are trimmed. Docker Desktop stops gracefully, and the
VHD must be detached and exclusively accessible before `Optimize-VHD
-Mode Pretrimmed`. No zero-fill, virtual disk resize, forced shutdown or global
`wsl --shutdown` is used. A `finally` path starts Docker and restores the exact
previously running container IDs even if compaction failed. Normal watchdog
reconciliation then requalifies public MCP endpoints. During actual compaction
all Docker-hosted MCPs are briefly unavailable. The measured manual cycle on
dev-ermakov restored Engine in about 2.5 minutes; this is not a fixed deadline.

## Source-bound Mantis repair

The installed native family has image ID `728b1fe9…` and newer reader/publication
code than the package's legacy Mantis component. `storage-owner-repair.py` is a
build-time adapter bound to exact hashes of both installed owner modules. It
rejects unknown source before changing either file and preserves the native
backend, schema, provider/model identity and serving/reader leases.

Capacity deferrals can retry after the original cooldown and sufficient fresh
capacity, including the native generation peak/reserve, even after three earlier
deferrals. Actual native faults keep their existing bounded retry behavior.
Only a fully verified publication with successful revision/pointer CAS can
release obsolete unpublished-build pins. The existing native retirement owner
still protects actual reader leases and other recovery pins. No new embeddings
are purchased by collection, and the host never directly removes vector files.

Qualification uses `tests/python/qualify_mantis_storage_owner.py` inside the exact
native image with no network or live data mounts: the original reproduces both
defects, the repaired image passes retry, missing-payload preservation and leased
reader retirement. Live replacement additionally compares the full SQL-ready
inventory digest/count before resuming and checks corpus/search readiness.
An optional `mantisTicketServer.image` pins the qualified replacement for future
host operations. Do not carry this repair to another source/image family.
