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

For an explicit remote agent route use the same package/transfer operations with `--route agent`; no second measurement implementation exists. The remote agent calls `execute --via-agent` for that job. After worker failure, `agentFallback` only diagnoses; create a new linked job (`--parent`) for reconciled recovery rather than changing old evidence.

## Observe and collect

`status --spool ... --id ...` and `remote --action status --connection ... --id ...` read state. Send `cancel` to request stopping the current phase and owned processes. Cancellation is not rollback. Inspect cleanup and operation effects before recovery.

`collect --spool ... --id ... --output ...` collects local results. `remote --action collect --connection ... --id ... --output ...` verifies every downloaded file. Use a new output directory; never overwrite older evidence. Repeated observation does not enqueue work. Files are content-addressed during upload; retry skips complete matching blobs and restarts an incomplete blob without executing partial input.

## Portable export

`export --repository <source-root> --output <new-archive.zip>` includes the three skills, runtime and exact shared 1C core/port/session/value modules, with a SHA manifest. It excludes the full lifecycle, plugins, profiles, secrets, test bases and artifacts. On the target, verify the archive SHA from the sender, extract it to a private directory and prepare its profile. Python and licensed 1C remain machine prerequisites. The main agent can transfer dependencies once SSH exists; before then the user transfers the initial bundle.
