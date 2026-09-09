# Prepare, run, observe and transfer

Use Python 3.11+; the runtime has no Python package dependencies. `remote_work.py --help` is the complete executable CLI. Each command returns JSON. Nonzero exit/error JSON means the operation failed; a successful transport call may still return a job with `needs-attention` or `partial`.

## Prepare once

Inspect Python, 1C, SSH and the user's permitted workspace/base. Resolve the profile from the shared contract. On an unconfigured Windows host use `Prepare-RemoteHost.ps1` to inspect prerequisites; `-EnableSsh` is an explicit administrative setup operation. Do not change firewall/service settings during mere inspection.

```powershell
python .\.agents\skills\itl-remote-runner\scripts\remote_work.py prepare --spool C:\ITL\worker --profile C:\ITL\private-profile.json
```

Give the user the generated `Start-Worker.cmd`. They launch it after logging into the session that will run 1C. `worker.json` is a heartbeat, not proof of current access to an interactive desktop; the real scenario establishes usable runtime readiness. Signing out can interrupt 1C; reconnecting the controller must not replay its job.

`connection.json` defaults to exchange transport. When connecting through SSH, set `transport: ssh` and the concrete `ssh.host` alias; existing SSH config supplies user/key and optional port. The connection records remote Python/runtime/spool paths. SSH carries structured commands through stdin with encoded PowerShell bootstrap, without exposing a new network service. Approve/trust the SSH host through the user's existing workflow before noninteractive jobs.

Use `probe --spool ...` locally or `remote --connection ... --action probe` remotely. Unsupported optional capabilities do not install or start anything during probe.

## Package and execute

```powershell
python .\.agents\skills\itl-remote-runner\scripts\remote_work.py pack --scenario .\tests\performance\report\scenario.json --output C:\ITL\packages\report-1 --target test --route local
python .\.agents\skills\itl-remote-runner\scripts\remote_work.py submit --package C:\ITL\packages\report-1 --spool C:\ITL\worker
python .\.agents\skills\itl-remote-runner\scripts\remote_work.py execute --spool C:\ITL\worker --id <returned-id>
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

`export --repository <source-root> --output <new-archive.zip>` includes the three skills, runtime and exact shared 1C core/port/session/value modules, with a SHA manifest. It excludes the full lifecycle, plugins, profiles, secrets, test bases and artifacts. On the target, verify the archive SHA from the sender, extract it to a private directory and prepare its profile. Python and licensed 1C remain machine prerequisites. The main agent can transfer dependencies once SSH exists; before then the user transfers the initial bundle.
