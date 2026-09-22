# Prepare, run, observe and transfer

On Windows use `scripts/Invoke-RemoteWork.ps1`; it provides the Python runtime automatically. `Invoke-RemoteWork.ps1 --help` lists the complete CLI. Each command returns JSON. Nonzero exit/error JSON means the operation failed; a successful transport call may still return a job with `failed`, `interrupted`, `needs-attention`, or `partial` state.

The helper acquires pinned CPython 3.13.15 from the official NuGet package into the user-local shared ITL artifact cache. It verifies the package and every installed payload file, serializes concurrent installers and repairs a damaged installation into a new generation. Existing generations remain available to running workers. No administrator rights, NuGet client, pip packages, PATH/registry changes or `conf.cfg` edits are needed. Python runs on the agent/worker host; ordinary business users of 1C do not need it.

Use `-Python <executable>` or `ITL_PYTHON_EXECUTABLE` for an explicit Python 3.11+ installation; an invalid override is reported rather than silently replaced. `ITL_EXECUTION_GUARD_PYTHON` may select the interpreter used by the execution-guard host. `-Offline` uses verified cache or the bundled archive and reports missing input without downloading. Runtime preparation precedes native execution ownership. Direct `remote_work.py` remains available for hosts with an explicitly managed interpreter.

## Prepare once

Inspect 1C and the user's permitted workspace/base. Resolve the profile from the shared contract. The normal worker is user-local and outbound: it needs no administrator rights, Windows service, inbound listener, firewall change or SSH server. `Prepare-RemoteHost.ps1` remains available for offline Python preparation; `-EnableSsh` is an explicit administrator-only compatibility operation and is never implied by remote-worker setup.

Choose the pull broker's stable URL and create private controller and worker halves. The returned JSON deliberately omits the bearer token; protect both generated files and transfer only the worker half to its Windows user. `--controller-folder` and `--worker-folder` are optional corresponding paths to one synchronized/shared folder and can be added later.

```powershell
& .\.agents\skills\itl-remote-runner\scripts\Invoke-RemoteWork.ps1 pair `
  --url https://controller.example:8765 `
  --controller-output "$env:LOCALAPPDATA\ITL\remote-work\host\controller.json" `
  --worker-output C:\ITL\transfer\worker.json
```

Start the broker with every controller pairing it may serve. A random bearer token is not accepted merely because it has the right shape. Non-loopback listeners require a TLS certificate and key; an organization-managed endpoint may instead terminate TLS before a loopback broker.

```powershell
& .\.agents\skills\itl-remote-runner\scripts\Invoke-RemoteWork.ps1 pull-serve `
  --listen 0.0.0.0 --port 8765 --certificate C:\ITL\tls\server.pem `
  --private-key C:\ITL\tls\server.key --connection "$env:LOCALAPPDATA\ITL\remote-work\host\controller.json"
```

```powershell
& .\.agents\skills\itl-remote-runner\scripts\Invoke-RemoteWork.ps1 prepare --spool C:\ITL\worker `
  --profile C:\ITL\private-profile.json --worker-connection C:\ITL\transfer\worker.json
```

Give the user the generated `Start-Worker.cmd`. They launch it after logging into the session that will run 1C. A pull-paired launcher runs a bounded persistent worker because starting the launcher is the user's explicit session opt-in; legacy preparation without a worker connection remains one-shot. `worker.json` records process creation identity, a heartbeat refreshed while a job runs, stopped/stale state and resource snapshots. Probe requires both the matching identity and a fresh heartbeat; it is still not proof of current access to an interactive desktop, so the real scenario establishes usable runtime readiness. Signing out can interrupt 1C; a new worker reconciles the interrupted owner to `interrupted` without replaying its job.

Pull is the normal control channel and also transfers files in verified chunks. Optional `bulkFolders` entries have the same id but may use different local paths on controller and worker. They carry only `itl-blobs/<sha256>` and `itl-results/<sha256>`; all queue/state/control remains on pull. A missing, delayed or damaged folder copy falls back to pull for the same job id. The legacy generated `connection.json` remains an exchange-local compatibility artifact.

When connecting through already authorized SSH, set `transport: ssh` and the concrete `ssh.host` alias; existing SSH config supplies user/key and optional port. SSH carries the same structured spool RPC through stdin. It is not the execution engine and must not be installed automatically.

Use `probe --spool ...` locally or `remote --connection ... --action probe` remotely. Unsupported optional capabilities do not install or start anything during probe.

## Package and execute

```powershell
& .\.agents\skills\itl-remote-runner\scripts\Invoke-RemoteWork.ps1 pack --scenario .\tests\performance\report\scenario.json --output C:\ITL\packages\report-1 --target test --runner local --agent-policy off
& .\.agents\skills\itl-remote-runner\scripts\Invoke-RemoteWork.ps1 submit --package C:\ITL\packages\report-1 --spool C:\ITL\worker
& .\.agents\skills\itl-remote-runner\scripts\Invoke-RemoteWork.ps1 execute --spool C:\ITL\worker --id <returned-id>
```

For the paired remote worker, package with `--runner worker --agent-policy off` and use
`send --package <package> --connection <controller.json>`.

`runner local` requires direct execution in the current user session. `runner worker` requires deterministic queued execution by the user-started worker; sending a local package or executing a worker package through the local entrypoint fails before launch. `agent-policy requested` asks that worker to dispatch the same runtime contract to the configured remote agent; `diagnosis-on-failure` permits only the existing bounded diagnostic fallback. Old `--route local|auto|ssh|agent` packages remain accepted and normalize to this split contract. Transport is selected only by the connection used by `send`, not by the immutable job package.

`--parameters` takes a JSON file. `--operation measure --operation write-data --operation update` expresses only operations already authorized by the user; omit unneeded permissions. Job requests never enlarge the target's allowed operations.

For an explicit remote agent use `--runner worker --agent-policy requested`; no second measurement implementation exists. The remote agent calls `execute --via-agent` for that job. After worker failure, configured diagnosis-on-failure only diagnoses. A subsequent measurement needs a new linked job (`--parent`) and must preserve the old evidence; the interrupted job is not replayed and does not create a generic recovery gate.

## Observe and collect

`status --spool ... --id ...` and `remote --action status --connection ... --id ...` read state. Send `cancel` to request stopping the current phase and owned processes. Cancellation is not rollback. Inspect cleanup and operation effects before choosing any product-specific repair. A `RESOURCE_LIMIT_EXCEEDED` result is a safety stop: inspect `resourceEvidence` and `resource-telemetry.jsonl`, then reconcile effects in a new linked job instead of replaying the old job.

`collect --spool ... --id ... --output ...` collects local results. `remote --action collect --connection ... --id ... --output ...` verifies every downloaded file. Use a new output directory; never overwrite older evidence. Repeated observation does not enqueue work. Files are content-addressed during upload; retry skips complete matching blobs and restarts an incomplete blob without executing partial input.

Add `--allow-partial` to either collection command to retrieve available run
diagnostics before `result.json` exists, including after an engine
crash. The command returns `collectionStatus: partial`, `resultAvailable: false`
and the last observed job state; a stale `running` state is retained as observed,
not interpreted as a live process. It never creates a measurement result,
changes job state, releases an execution guard or executes repair. A successful
command exit means verified transfer only. When a result already exists, the
command retains its normal result response, including a failed result.

`download-manifest.json` records collection time, observed state and every
downloaded file's size/hash. This is a per-file observation, not an atomic
snapshot of all running processes. An unreadable/missing state file is recorded
in `observationErrors` with `observedJob: null`; available logs remain collectable.
Appended log bytes beyond the inventory size
are excluded; changed or truncated inventoried bytes fail collection. A failed
transfer has no completed download manifest; retain its diagnostics and retry
collection into a new directory. Missing run directories still report
`RESULT_NOT_READY`. Keep output outside the execution spool. Private directories
and `context.json`, including private execution contexts and case variants, are excluded
from both inventories and direct file reads. Collection is not proof that owned
work stopped or a product-specific restoration completed; inspect that operation's evidence separately.

## Portable export

`Invoke-RemoteWork.ps1 export --repository <source-root> --output <new-archive.zip>` includes the three skills, pinned Python package and exact shared 1C core/port/session/value/download modules, with a SHA manifest. It excludes the full lifecycle, plugins, profiles, secrets, test bases and measurement artifacts. On the target, verify the archive SHA from the sender, extract it to a private directory and run `Prepare-RemoteHost.ps1 -Offline -Spool ... -Profile ... -WorkerConnection ...`. Python is installed from the included package; licensed 1C remains a machine prerequisite. With no pre-existing connection, the user transfers this first bundle and worker connection half through RDP, a corporate download or any other approved file channel; SSH is not required. The lower-level Python `export` command includes Python only when `--python-archive <package>` is supplied; its hash must match the source manifest.

After the first updater-capable worker is present, later compatible bundles require no remote user action. Run `sync-worker --connection <controller.json> --repository <current-workflow-root>` before the first job from a newer workflow. It probes the remote version, builds the exact current bundle only when needed and stages it through pull and any available bulk folder. `stage-update --connection ... --bundle ...` remains the explicit exact-bundle form. The worker verifies the archive and every manifest entry into a new user-local generation. Its supervisor switches only while idle, confirms startup and rolls back a failed trial; active jobs and private target profiles are never replaced. A pre-updater worker requires one final manual bundle refresh.
