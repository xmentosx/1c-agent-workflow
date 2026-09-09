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

## Scenario (schemaVersion 1)

Required: `id`, `readyDescription`, `dataIdentity`, `repeatable` and `mutates` booleans, `commands.action`, `commands.verify`. `files` lists all relative dependency paths to include. The package rejects traversal, absolute dependency paths and content changes. `parameters` maps arbitrary names to `type` (`string`, `integer`, `number`, `boolean`, `object`, `array`), optional `default`, `enum`, `required` (default true).

`commands` contains argv arrays for `prepare`, `update`, `action`, `ready`, `verify`, `reset`, `cleanup`. Only `action` and `verify` are mandatory. Arrays are executed without a shell. Available substitutions: `{python}`, `{runtime}`, `{workspace}`, `{input}`, `{run}`, `{context}`, `{iteration}`. Pass parameters in context JSON, not interpolated PowerShell/BSL/shell source. Windows native calls use shared quoting/UTF-8 helpers; invoke the packaged `Invoke-OneCProcess.ps1` for standalone 1C launches or the installed project's guarded helper.

`adapter: command` measures action plus any ready command, including subprocess dispatch; it is suitable for complete script/server calls. `adapter: handshake` starts the workload before timing. It publishes `ready.json` with this `jobId` and `ready: true`, waits for `go.json`, then writes `done.json` only after actual operation readiness. Files are written atomically inside `{iteration}`. `itl_measure.py` supplies this protocol for Python; the Vanessa recipe supplies it for TestClient. Timing is execution-host monotonic time, never SSH latency or chat completion.

The verify phase writes `{iteration}/verification.json` with the matching `jobId`, `passed: true` and a nonempty list of named checks; assertions must inspect real outputs, not merely write true. `itl_measure.verify` emits the contract and fails on false checks. `timeoutSeconds` bounds each phase (default 300, max 86400).

`prepare` runs once before iterations; `reset` runs between iterations. A repeatable mutating scenario requires reset. Updates require both job and target permission and happen outside the timer. Non-repeatable operations get one permitted run: default additional timings/profile remain explicitly missing. Cleanup executes even on failure/cancel; owned subprocess trees are contained in Windows jobs and closed afterward.

## Jobs and results

`pack` creates immutable `request.json`, `scenario.json`, input files, SHA256 and sizes. Job fields include ID, parent ID, target alias, route, mode, resolved parameters, operations and repetition counts. A controller requests a new experiment with a new ID; resend the same package after uncertain delivery. Same ID/different inputs is an error.

Queue states are `queued`, `waiting-for-base`, `running`, `agent-running`, `completed`, `partial`, `cancelled`, `needs-attention`. Publication is atomic after full-file verification. The OS owns admission locks; never delete locks as recovery. A recorded running state with no current owner becomes `needs-attention`, not a restarted update. During engine execution, preparation through cleanup uses the same exclusive database owner; descendants receive the private inherited lease. Agent diagnosis after failure does not authorize rerunning it.

`result.json` contains unprofiled samples, phase costs, summary, raw-profile references, source/data/environment identity, limitations and cleanup errors. `report.md` is rebuilt from that data. `context.json` is private and excluded from result transfer. Raw packets are separate from native PFF; no file renaming or synthetic native export is permitted. A profile's partial source mapping must remain visible.
