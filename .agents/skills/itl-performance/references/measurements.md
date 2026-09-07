# Measurement recipes

The engine measures on the execution host regardless of `local`, `ssh` or `agent`. The controller never times a chat response or SSH transfer. `pack` defaults to `time+profile`, one warmup, three unprofiled repeats and one separate diagnostic profile. Choose `--mode time` for timing alone or `--mode profile` for one profile. Preserve explicit user counts.

## Build the scenario in the project

Use `scripts/New-PerformanceScenario.ps1` from the runner skill to scaffold `tests/performance/<name>` without overwriting existing files. The included Python handshake example is a calibration exercise, not 1C performance evidence. Replace its action and assertions with the requested operation before drawing product conclusions.

Use command mode for a complete script/server operation when its invocation overhead is part of the requested boundary. For a form operation use handshake mode: prepare TestManager/TestClient before `ready.json`, wait for `go.json`, invoke the exact semantic TestClient action and await real readiness, then write `done.json`. Keep authentication/startup and cleanup outside the timed interval. Server background work must have a scenario-specific completion check.

## Vanessa/TestClient

The runner's `Invoke-VanessaFeature.ps1` uses a configured Vanessa EPF and a manager/service base, launches through the shared per-infobase guard, and passes the feature/config parameters through a UTF-8 settings file. The feature must use [the supplied signal helpers](../assets/MeasurementSignals.bsl) and its pinned build's polling steps around the actual TestClient action and assertions. Existing installed-project verification/update commands remain authoritative for their own flows; a filtered profiling scenario is diagnostic, not a fresh full `/itl-check`.

For standalone execution configure `target.vanessa` with `epf`, `managerBase` and a settings JSON template matching the pinned Vanessa build. Profile setup uses that project's normal base/tool preparation adapter; do not copy or patch an installed project's workflow. Workload commands get `ITL_RUN_CONTEXT`, including resolved parameters, target, iteration directory and runtime endpoint. Use the supplied 1C launcher for client processes so the same session guard applies.

Vanessa/BSL can implement the handshake through JSON/text files in the per-iteration directory; use the example fragment as scaffolding, not as proof its business operation is correct. Write result signals atomically after the real readiness condition and assertions. Never treat a button's asynchronous return as rendered UI readiness.

## Debugger topology and ownership

For a file base, the worker selects `dbgs.exe` beside the configured platform or the explicit override, starts it on a free loopback port on this execution host, checks its own notification file and keeps ownership until cleanup. For a remote file base this happens remotely, not on the controller. The effective endpoint is in `context.rdbg.url` before preparation starts.

For a server base, `target.rdbg.url` names the actual server/shared `dbgs`. No local replacement is started and no server service is stopped. Both client/server targets must belong to this job's base instance and runtime session. Configure the required server debugging through the authorized environment setup, not by changing server processes during a failed measurement.

Preparation emits `{run}/runtime-proof.json` with `jobId`, `clientPid`, `infoBaseAlias`, `seanceId`, `infoBaseInstanceID`, `targetIds` established from fresh own-client startup and debugger discovery. The `runtime-proof --context <context.json> --client-pid <pid> --seance <session> --instance <instance>` helper verifies the guarded launch and live process, then discovers only that explicit session. Obtain the session/instance from the own TestClient/runtime adapter, never by choosing the first debugger target. Only when `context.rdbg` is available, use `debug: true` in the guarded client launch spec to receive `/DEBUG -http /DEBUGGERURL` with the effective endpoint. In time-only mode omit debug/proof setup. For a profiling handshake iteration establish the fresh proof before publishing `ready.json`. The collector independently compares each named target's live base/session/instance before attach and checks the same fields in returned packets; it never attaches all discovered targets. File-base profiles may have only a client target; server profiles require the client and matching server targets.

Original `.response.bin` and decoded XML, request XML, profile summaries and debugger cleanup status are retained. `analyze --raw <paths...> --session <id>` is offline. An optional `--source-map` maps module IDs to exact version, source path and SHA256; unmatched sources remain unmatched, never silently substituted from another checkout. Native PFF generation is not implemented.

## Compare

`compare --baseline <result.json> --candidate <result.json>` accepts only validated samples with matching scenario/parameters/data/environment/readiness and reports a historical median difference. The intentionally changed configuration identity is displayed separately. A source edit is not by itself a comparable runtime dataset.

For controlled A/B, prepare explicit jobs in A/B/A/B order with matching dataset/reset contracts and permitted version updates, then compare paired results. Never update or roll back a database merely to make saved runs look comparable. Record all samples and expose noise; do not claim statistical significance from three repeats.
