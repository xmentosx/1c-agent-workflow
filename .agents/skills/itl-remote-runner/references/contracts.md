# Portable job and scenario contract

## Locations and trust

New scenarios live in `tests/performance/<name>/scenario.json` with their scripts/features. Private profiles and spool normally live under `%LOCALAPPDATA%/ITL/remote-work/<host>/`; installed projects may instead use ignored `.agent-1c/remote-work`. Never commit connection profiles, runtime proofs, infobases, CF/CFE/DT, logs or secrets. Keep originals byte-preserving.

The authenticated controller and scenario authors are trusted. A worker executes their scripts under the Windows user's permissions. `allowedOperations` prevents accidental scope expansion; it is not a hostile-code sandbox. Restrict SSH/exchange writes to that controller; use existing SSH host-key verification and credential storage. Do not accept arbitrary shared-folder writers or expose agent/debugger listeners publicly.

## Worker profile (schemaVersion 1)

Create a private JSON object with `targets` keyed by short aliases. Each target has:

- `workspace`: absolute directory on the execution host; must exist.
- `allowedOperations`: explicit list, normally `measure`; include `write-data` for modifying scenarios and `update` only for authorized configuration updates.
- `infoBase`: `{ "kind": "file" | "server", "path": "..." }`, using the same `/F` path or `/S` server/reference identity as ITL.
- `platform`: absolute `1cv8.exe`/`1cv8c.exe` selected on this host.
- `sourceIdentity`: exact CF/CFE hashes or a saved source manifest, including uncommitted inputs; never substitute a commit for a dirty export.
- `environmentIdentity`: comparable platform/build, machine/base/data-copy settings. `dataIdentity` belongs to the scenario; update it when the dataset changes.
- `access`: optional `{ "coordinator": "<shared-authority-directory>", "waitTimeoutSeconds": 3600, "additionalBases": [] }`. All executors accessing the same database must use one authority. `ITL_INFOBASE_ACCESS_ROOT` is the host default. Without either setting the scope is explicitly `execution-host-only`, not cross-host coordination. See [database admission](database-access.md) for identity registration, inherited leases and recovery boundaries.
- `rdbg`: server bases use `{ "mode": "shared", "url": "http://server:1550", "infoBaseAlias": "ref" }`. File bases use `{ "mode": "local", "infoBaseAlias": "DefAlias" }`; `executable` optionally overrides the sibling `dbgs.exe` beside `platform`. Local `dbgs` binds loopback on the execution host and is owned by the job, including for remote file-base jobs. Shared server `dbgs` is never stopped by the worker. Missing profiling capability yields incomplete profile evidence, not a failed time-only capability check.

Optional profile-level `agentFallback: true` enables diagnosis after `auto` failure. `agent` selects a harness adapter; read the agent reference only for that route. The prepared `profilePath` is passed to the remote agent. Store secrets in existing environment/credential references, never plaintext fields.

Each target may define `resourceLimits` with numeric `pollIntervalSeconds`, `maxWorkerMemoryMb`,
`maxProcessMemoryMb`, `maxJobMemoryMb`, `minAvailableMemoryMb`, `maxCommittedPercent`, `maxGrowthMb`, and
`growthWindowSeconds`. `byOperation` may override those fields for `measure`, `write-data`, or `update`; when a job
declares several operations, the worker applies the most restrictive combined policy. The runtime supplies bounded
defaults when a legacy profile omits the section. On Windows, process and job memory are also installed as Job
Object hard limits. Host/process/job samples are flushed to `resource-telemetry.jsonl` and summarized in
`result.json.resourceEvidence`. A threshold breach terminates only the owned Job Object and records
`RESOURCE_LIMIT_EXCEEDED`; external 1C server processes remain outside this boundary.

Optional profile-level `workerLimits` contains `allowPersistent`, `maxJobs`, and `maxLifetimeSeconds`. Generated
launchers are one-shot and process at most one queued job. Persistent polling requires both the explicit
`--persistent` switch and `allowPersistent: true`; it still rotates at the configured job/lifetime limit.

## Scenario (schemaVersion 1)

Required: `id`, `readyDescription`, `dataIdentity`, `repeatable` and `mutates` booleans, `commands.action`, `commands.verify`. `files` lists all relative dependency paths to include. The package rejects traversal, absolute dependency paths and content changes. `parameters` maps arbitrary names to `type` (`string`, `integer`, `number`, `boolean`, `object`, `array`), optional `default`, `enum`, `required` (default true).

`commands` contains argv arrays for `prepare`, `update`, `action`, `ready`, `verify`, `reset`, `cleanup`. Only `action` and `verify` are mandatory. Arrays are executed without a shell. Available substitutions: `{python}`, `{runtime}`, `{workspace}`, `{input}`, `{run}`, `{context}`, `{iteration}`. Pass parameters in context JSON, not interpolated PowerShell/BSL/shell source. Windows native calls use shared quoting/UTF-8 helpers; invoke the packaged `Invoke-OneCProcess.ps1` for standalone 1C launches or the installed project's guarded helper.

`adapter: command` measures action plus any ready command, including subprocess dispatch; it is suitable for complete script/server calls. `adapter: handshake` starts the workload before timing. It publishes `ready.json` with this `jobId` and `ready: true`, waits for `go.json`, then writes `done.json` only after actual operation readiness. Files are written atomically inside `{iteration}`. `itl_measure.py` supplies this protocol for Python; the Vanessa recipe supplies it for TestClient. Timing is execution-host monotonic time, never SSH latency or chat completion.

The verify phase writes `{iteration}/verification.json` with the matching `jobId`, `passed: true` and a nonempty list of named checks; assertions must inspect real outputs, not merely write true. `itl_measure.verify` emits the contract and fails on false checks. `timeoutSeconds` supplies each phase's default (300, maximum 86400); `phaseTimeoutSeconds` may override `update`, `prepare`, `action`, `ready`, `verify`, `reset`, and `cleanup` individually. Values must be finite positive numbers. Queue admission has a separate target access timeout and never consumes the action budget. Child processes inherit the execution-host monotonic phase deadline through context; handshake `go.json` starts the action phase after readiness. Python waits and MCP requests consume the remaining budget, including sequential calls within the phase, rather than restarting a 300-second clock. See [phase deadlines](phase-deadlines.md).

`prepare` runs once before iterations; `reset` runs between iterations. A repeatable mutating scenario requires reset. Updates require both job and target permission and happen outside the timer. Non-repeatable operations get one permitted run: default additional timings/profile remain explicitly missing. Cleanup executes even on failure/cancel; owned subprocess trees are contained in Windows jobs and closed afterward.

Optional `recovery` pins separate inspection, quiescence and restoration hooks
before the original job starts. It never reuses `action` or blindly reruns
`cleanup`. See [job recovery](job-recovery.md) for permissions, evidence, deadlines
and crash semantics. Missing recovery support does not block a normal measurement.

## Jobs and results

`pack` creates immutable `request.json`, `scenario.json`, input files, SHA256 and sizes. Job fields include ID, parent ID, target alias, route, mode, resolved parameters, operations and repetition counts. A controller requests a new experiment with a new ID; resend the same package after uncertain delivery. Same ID/different inputs is an error.

Queue states are `queued`, `waiting-for-base`, `running`, `agent-running`, `completed`, `partial`, `cancelled`, `needs-attention`. Publication is atomic after full-file verification. The OS owns admission locks; never delete locks as recovery. A recorded running state with no current owner becomes `needs-attention`, not a restarted update. During engine execution, preparation through cleanup uses the same exclusive database owner; descendants receive the private inherited lease. Agent diagnosis after failure does not authorize rerunning it.

Before database waiting, the execution host writes `provenance.json` with the request/scenario/input hashes, input file inventory, resolved parameters, repetition counts, requested operations/route, executor, host, readiness criterion and phase budgets. It retains declared data/source/environment identities separately from runtime proof. The file contains no target profile, credential configuration or inherited lease. `collect --allow-partial` can retrieve it during waiting and after cancellation or an engine crash, without a result or automatic replay. The same bytes are referenced by SHA256 in the eventual result. Keep the immutable input package for reproduction; hashes identify its files but do not replace their contents.

During execution, `progress.json` atomically retains each iteration's kind and
status, confirmed timing samples, command and handshake phase boundaries, phase
errors, cleanup errors and the original provenance reference. It stays `running`
until the final result is written; a verified sample does not mean the whole job
or cleanup succeeded. Warmups and failed verification never become timing samples.
Handshake progress writes remain outside the measured interval. Collected
profiles are persisted before workload verification and linked by path and SHA256
with separate coverage and workload-verification flags, without repeating packet
rows in progress. Source mapping refreshes those artifact references and retains
its manifest/resolution evidence. A crash leaves the last durable snapshot;
`collect --allow-partial` retrieves it without inventing completion or replaying
the interrupted iteration. Use observed job status and `resultAvailable` to
distinguish partial evidence from a finished result.

For profile runs, `loadedState` and `loaded-state-evidence.json` bind the actual
runtime proof, packet target IDs, session/base instance, native configuration
versions and versioned module IDs to the retained profile hashes. Declared
`sourceIdentity`, `dataIdentity` and `environmentIdentity` remain declarations in
that evidence and never become proof of what the 1C session loaded. A time-only
run reports loaded state as unavailable because it has no runtime profile.

`sourceAnalysis: none` records the observed runtime/module versions without
exporting configuration source. `optional` or `required` binds the requested
executed modules to copied source bytes by SHA256. When an exact existing binding
is unavailable, the source adapter may capture the target database after workload
verification under the same database lease; the resulting artifact inventory is
verified and retained inside the run. Selection applies only to requested modules.
Profiler packets prove executed modules, not the source of the whole configuration
or its data state, so both claims remain explicitly false.

`result.json` contains unprofiled samples, iteration and phase outcomes, summary, raw-profile references, loaded-state evidence, source/data/environment identity, resource evidence, limitations and cleanup errors. `report.md` is rebuilt from that data. `context.json` is private and excluded from result transfer. Raw packets are separate from native PFF; no file renaming or synthetic native export is permitted. A profile's partial source mapping must remain visible.
