# Measurement recipes

The engine measures on the execution host regardless of `local`, `ssh` or `agent`. The controller never times a chat response or SSH transfer. `pack` defaults to `time+profile`, one warmup, three unprofiled repeats and one separate diagnostic profile. Choose `--mode time` for timing alone or `--mode profile` for one profile. Preserve explicit user counts.

## Build the scenario in the project

Use `scripts/New-PerformanceScenario.ps1` from the runner skill to scaffold `tests/performance/<name>` without overwriting existing files. The included Python handshake example is a calibration exercise, not 1C performance evidence. Replace its action and assertions with the requested operation before drawing product conclusions.

Use command mode for a complete script/server operation when its invocation overhead is part of the requested boundary. For a form operation use handshake mode: prepare TestManager/TestClient before `ready.json`, wait for `go.json`, invoke the exact semantic TestClient action and await real readiness, then write `done.json`. Keep authentication/startup and cleanup outside the timed interval. Server background work must have a scenario-specific completion check.

## Vanessa/TestClient

The runner's `Invoke-VanessaFeature.ps1` uses a configured Vanessa EPF and a manager/service base, launches through the shared per-infobase guard, and passes the feature/config parameters through a UTF-8 settings file. The feature must use [the supplied signal helpers](../assets/MeasurementSignals.bsl) and its pinned build's polling steps around the actual TestClient action and assertions. Existing installed-project verification/update commands remain authoritative for their own flows; a filtered profiling scenario is diagnostic, not a fresh full `/itl-check`.

For standalone execution configure `target.vanessa` with `epf`, `managerBase` and a settings JSON template matching the pinned Vanessa build. Profile setup uses that project's normal base/tool preparation adapter; do not copy or patch an installed project's workflow. Workload commands get `ITL_RUN_CONTEXT`, including resolved parameters, target, iteration directory and runtime endpoint. Use the supplied 1C launcher for client processes so the same session guard applies.

Vanessa/BSL can implement the handshake through JSON/text files in the per-iteration directory; use the example fragment as scaffolding, not as proof its business operation is correct. Write result signals atomically after the real readiness condition and assertions. Never treat a button's asynchronous return as rendered UI readiness.

## Installed ITL facade adapter

The runner's `scripts/vanessa_work.py` provides `prepare <setup.feature>`,
`feature <action.feature>` and `cleanup`, using engine-supplied `ITL_RUN_CONTEXT`.
Configure private `target.vanessa.facade`, `helper` and `catalog` with exact local
paths to the pinned ITL executable, helper and Vanessa catalog. The adapter uses
the public MCP stdio gateway; ITL still owns the manager, port leases and guarded
TestClient launch. An existing client cannot be adopted into a performance job.

Preparation runs outside timing. The pinned VAExtension server-expression step reads
`НомерСеанса` in the own TestClient and binds it to the broker's actual PID/start time.
With profiling enabled, the guarded launch receives the job's debugger endpoint;
a changed endpoint or job cannot reuse the client. Discovery must find exactly one
session/base instance and one native client (`ManagedClient` or `Client`) for the
configured alias and observed number. The selected executable is preserved;
the collector does not switch client types to bypass discovery. Zero clients is
`RDBG_OWNED_CLIENT_NOT_DISCOVERED`; multiple clients remain
`RDBG_OWNED_CLIENT_AMBIGUOUS`, including a mixture of both client families.
Missing or ambiguous matches fail before attach. The explicit-session CLI
remains available; alternatively use `--session-observation <relative-run-path.json>`
instead of `--seance`. The observation contains `jobId`, `clientPid`,
`clientStartedAt` and `sessionNumber`.

Each explicit feature is reloaded, its source hash and native results retained,
successful nonempty step evidence required, and client restarts rejected. Wrap the
measured feature in the scenario handshake and assert actual business readiness.
Whole-feature timing includes dispatch, polling and assertions; it is not pure BSL
time. Cleanup closes the own facade, with engine process-job containment as failure
cleanup. Windows PowerShell children reconstruct their module path to avoid loading
incompatible modules inherited from a pwsh host. Fixture tests prove these contracts
only; live 1C and comparable A/B results require separate evidence.

## Debugger topology and ownership

File bases register as `DefAlias`, not the filesystem path. See the platform's
[debugging settings](https://kb.1ci.com/1C_Enterprise_Platform/Guides/Developer_Guides/1C_Enterprise_8.3.24_Developer_Guide/Chapter_36._Service_features/36.2._Setting_Designer_parameters/36.2.4._Debugging/).

For a file base, the worker selects `dbgs.exe` beside the configured platform or the explicit override, starts it on a free loopback port on this execution host, checks its own notification file and keeps ownership until cleanup. For a remote file base this happens remotely, not on the controller. The effective endpoint is in `context.rdbg.url` before preparation starts.

For a server base, `target.rdbg.url` names the actual server/shared `dbgs`. No local replacement is started and no server service is stopped. Both client/server targets must belong to this job's base instance and runtime session. Configure the required server debugging through the authorized environment setup, not by changing server processes during a failed measurement.

Preparation emits `{run}/runtime-proof.json` with `jobId`, `clientPid`, `infoBaseAlias`, `seanceId`, `infoBaseInstanceID`, `targetIds` and `targetTypes` established from fresh own-client startup and debugger discovery. The `runtime-proof --context <context.json> --client-pid <pid> --seance <session> --instance <instance>` helper verifies the guarded launch and live process, then discovers only that explicit session. Obtain the session/instance from the own TestClient/runtime adapter, never by choosing the first debugger target. Only when `context.rdbg` is available, use `debug: true` in the guarded client launch spec to receive `/DEBUG -http /DEBUGGERURL` with the effective endpoint. In time-only mode omit debug/proof setup. For a profiling handshake iteration establish the fresh proof before publishing `ready.json`. The collector independently compares each named target's live base/session/instance/type before attach and checks the same fields in returned packets; it never attaches all discovered targets. A full file-base profile requires the discovered native client family and its ServerEmulation context; a server-base profile requires that client family and Server. Runtime proof, engine requirements and returned packets must retain the exact Client/ManagedClient type; one does not substitute for the other. Legacy proofs without targetTypes still require ManagedClient. Other sessions and JobFileMode are not adopted. Missing collected packets are retained with `complete=false` and explicit missing families/IDs, making the engine result partial. Client inclusive time overlaps server time and must never be added to it.

Original `.response.bin` and decoded XML, request XML, profile summaries and debugger cleanup status are retained. `analyze --raw <paths...> --session <id>` is offline. `--source-analysis none|optional|required` separates raw coverage from source availability; `--source-map` supplies exact bindings. See [source analysis](source-analysis.md) for native identities, manifests and missing-source results. Native PFF generation is not implemented.

## Compare

`compare --baseline <result.json> --candidate <result.json>` accepts only validated samples with matching scenario/parameters/data/environment/readiness and reports a historical median difference. The intentionally changed configuration identity is displayed separately. A source edit is not by itself a comparable runtime dataset.

For controlled A/B, prepare explicit jobs in A/B/A/B order with matching dataset/reset contracts and permitted version updates, then compare paired results. Never update or roll back a database merely to make saved runs look comparable. Record all samples and expose noise; do not claim statistical significance from three repeats.
