# Prepare, run, observe and transfer

On Windows use `scripts/Invoke-RemoteWork.ps1`; it provides the Python runtime automatically. `Invoke-RemoteWork.ps1 --help` lists the complete CLI. Each command returns JSON. Nonzero exit/error JSON means the operation failed; a successful transport call may still return a job with `needs-attention` or `partial`.

The helper acquires pinned CPython 3.13.15 from the official NuGet package into the user-local shared ITL artifact cache. It verifies the package and every installed payload file, serializes concurrent installers and repairs a damaged installation into a new generation. Existing generations remain available to running workers. No administrator rights, NuGet client, pip packages, PATH/registry changes or `conf.cfg` edits are needed. Python runs on the agent/worker host; ordinary business users of 1C do not need it.

Use `-Python <executable>` or `ITL_PYTHON_EXECUTABLE` for an explicit Python 3.11+ installation; an invalid override is reported rather than silently replaced. Database admission also preserves its existing `ITL_INFOBASE_ACCESS_PYTHON` / `databaseAccess.python` override. `-Offline` uses verified cache or the bundled archive and reports missing input without downloading. Runtime preparation precedes database ownership. Direct `remote_work.py` remains available for hosts with an explicitly managed interpreter.

## Prepare once

Inspect 1C, SSH and the user's permitted workspace/base. Resolve the profile from the shared contract. On an unconfigured Windows host `Prepare-RemoteHost.ps1` prepares Python and reports prerequisites; `-EnableSsh` is an explicit administrative setup operation. Do not change firewall/service settings during mere inspection.

```powershell
& .\.agents\skills\itl-remote-runner\scripts\Invoke-RemoteWork.ps1 prepare --spool C:\ITL\worker --profile C:\ITL\private-profile.json
```

Give the user the generated `Start-Worker.cmd`. They launch it after logging into the session that will run 1C. `worker.json` is a heartbeat, not proof of current access to an interactive desktop; the real scenario establishes usable runtime readiness. Signing out can interrupt 1C; reconnecting the controller must not replay its job.

`connection.json` defaults to exchange transport. When connecting through SSH, set `transport: ssh` and the concrete `ssh.host` alias; existing SSH config supplies user/key and optional port. The connection records remote Python/runtime/spool paths. SSH carries structured commands through stdin with encoded PowerShell bootstrap, without exposing a new network service. Approve/trust the SSH host through the user's existing workflow before noninteractive jobs.

Use `probe --spool ...` locally or `remote --connection ... --action probe` remotely. Unsupported optional capabilities do not install or start anything during probe.

## Package and execute

```powershell
& .\.agents\skills\itl-remote-runner\scripts\Invoke-RemoteWork.ps1 pack --scenario .\tests\performance\report\scenario.json --output C:\ITL\packages\report-1 --target test --route local
& .\.agents\skills\itl-remote-runner\scripts\Invoke-RemoteWork.ps1 submit --package C:\ITL\packages\report-1 --spool C:\ITL\worker
& .\.agents\skills\itl-remote-runner\scripts\Invoke-RemoteWork.ps1 execute --spool C:\ITL\worker --id <returned-id>
```

Local `execute` runs directly in the current user session: no SSH or second agent is needed. Remote packaging uses `auto`, `ssh`, or `agent`, then `send --package ... --connection ...`. The already running remote worker executes the queued job. Do not call remote `execute` from a noninteractive SSH session for a client-1C scenario.

`--parameters` takes a JSON file. `--operation measure --operation write-data --operation update` expresses only operations already authorized by the user; omit unneeded permissions. Job requests never enlarge the target's allowed operations.

For an explicit remote agent route use the same package/transfer operations with `--route agent`; no second measurement implementation exists. The remote agent calls `execute --via-agent` for that job. After worker failure, `agentFallback` only diagnoses. Use [job recovery](job-recovery.md) when the original package supports it; a subsequent measurement needs a new linked job (`--parent`) and must preserve the old evidence.

## Observe and collect

`status --spool ... --id ...` and `remote --action status --connection ... --id ...` read state. Send `cancel` to request stopping the current phase and owned processes. Cancellation is not rollback. Inspect cleanup and operation effects before recovery.

`collect --spool ... --id ... --output ...` collects local results. `remote --action collect --connection ... --id ... --output ...` verifies every downloaded file. Use a new output directory; never overwrite older evidence. Repeated observation does not enqueue work. Files are content-addressed during upload; retry skips complete matching blobs and restarts an incomplete blob without executing partial input.

Add `--allow-partial` to either collection command to retrieve available run and
recovery diagnostics before `result.json` exists, including after an engine
crash. The command returns `collectionStatus: partial`, `resultAvailable: false`
and the last observed job state; a stale `running` state is retained as observed,
not interpreted as a live process. It never creates a measurement result,
changes job state, releases database access or executes recovery. A successful
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
and `context.json`, including recovery contexts and case variants, are excluded
from both inventories and direct file reads. Collection is not proof that owned
work stopped or restoration completed; inspect the recovery evidence separately.

## Portable export

`Invoke-RemoteWork.ps1 export --repository <source-root> --output <new-archive.zip>` includes the three skills, pinned Python package and exact shared 1C core/port/session/value/download modules, with a SHA manifest. It excludes the full lifecycle, plugins, profiles, secrets, test bases and measurement artifacts. On the target, verify the archive SHA from the sender, extract it to a private directory and run `Prepare-RemoteHost.ps1 -Offline -Spool ... -Profile ...`. Python is installed from the included package; licensed 1C remains a machine prerequisite. The main agent can transfer dependencies once SSH exists; before then the user transfers the initial bundle. The lower-level Python `export` command includes Python only when `--python-archive <package>` is supplied; its hash must match the source manifest.
