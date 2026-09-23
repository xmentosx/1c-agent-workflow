---
name: itl-remote-runner
description: Prepare a user-started Windows worker and run authorized jobs over its outbound pull channel, with an optional shared folder for large immutable files and SSH only as a preconfigured compatibility adapter. Use for setup, transfer, monitoring, collection, update, or failure diagnosis; local measurements use itl-performance directly.
---

# ITL remote runner

Use `scripts/Invoke-RemoteWork.ps1` on Windows for durable jobs; it provisions pinned user-local Python and invokes the shared `remote_work.py` engine. It works without a plugin, Codex, Git, or a full installed ITL project. Read [the operation contract](references/operations.md) for overrides, offline delivery and the requested operation, and [the job contract](references/contracts.md) when preparing inputs.

## User route

- Resolve a named connection/target from the project's references or the user's private `%LOCALAPPDATA%/ITL/remote-work` profiles. Reuse known authorization; ask together only for missing pull endpoint/pairing, workspace, target base and permitted operations. An optional bulk folder is an optimization, not a readiness prerequisite. Never treat access to a server as permission for all its bases.
- Default to pull pairing. For a new host, stage one `onboard` launcher in an explicitly trusted transfer folder, start the TLS pull broker with its controller half, and ask the user to start only `Start-Worker.cmd` in the Windows session where work should run. Observe `bootstrap-status.json` and pull probe yourself; never ask the user to run a network test, copy console output, choose a 1C executable in the launcher, or type commands into the worker. Prepare exact 1C targets after host connection when necessary. The worker makes the outbound connection without administrator rights, inbound listener, firewall change, SSH server, service or simulated login. Plain HTTP is allowed only on loopback.
- `host-pack` creates durable user-session command jobs in the same queue and pull channel. Use this SSH-like route only when the user's task authorizes host commands and the private worker profile has `hostCommands.enabled: true`; the paired controller then has the Windows user's effective access. Commands are noninteractive argv jobs with input files, timeout, status, cancel and collected stdout/stderr; observe the same job ID after uncertainty and never replay it. Use exact-target ITL jobs and the infobase guard for 1C operations. `prepare --worker-connection` remains a lower-level/offline route. The private connection and spool stay per Windows user.
- Pull owns job control, heartbeat, cancellation and ordinary chunked/resumable transfer. A paired `bulkFolders` entry is optional: use it only for immutable content-addressed input/result/update blobs, verify every size/hash, and fall back to pull without creating a new job. Never put mutable queue state in a synchronized folder.
- Run `sync-worker` before the first job from a newer workflow. When the connected version is older and its profile allows `workerUpdatePolicy: compatible`, it exports the exact current bundle and stages it through the paired connection. The supervisor switches only while idle, confirms the new heartbeat and rolls back a failed trial. A worker predating this updater needs one manual portable refresh.
- SSH is not a prerequisite or the normal job route. Use it only when the host already provides authorized SSH or for separately authorized break-glass administration. `Prepare-RemoteHost.ps1 -EnableSsh` is an explicit administrator-only compatibility action, never an onboarding fallback.
- Announce host, base, scenario, measurement mode and intended mutations briefly. A request to measure does not authorize a base update. Use an already authorized `update` job stage when requested; its project adapter owns platform update and startup/legal-confirmation handling.
- Use `itl-performance` to create a project scenario and package. `runner=worker` means the deterministic user-started runtime executes it; `agentPolicy` independently selects no agent, an explicitly requested agent, or diagnosis after failure. Legacy `route` values remain readable but are not the new authoring contract. Send, observe, cancel and collect over the paired connection.
- Observe the existing job ID after disconnects. Never repeat a failed modifying operation just because its reply was lost. Collect and verify results; engine state and artifacts establish completion, not a zero SSH exit code.

## Database Access Handoff

Before sending a job, declare its complete exact database resource set. A conflicting call/job waits visibly on the execution guard and proceeds after bounded owned cleanup; an idle on-demand backend is not an owner. Never release or terminate a foreign holder. Report a bounded exact-base external conflict and leave foreign processes intact.

A bounded helper or remote job retains its execution guard until normal completion or confirmed terminal owned cleanup. After disconnect or interruption, observe the existing job status and use its supported cancel only when cancellation is intended. Do not replay the old job or bypass a live owner; a later independent command is admitted automatically after cleanup without a generic recovery gate.

## Runtime boundaries

The execution host starts 1C in the user-started worker's session. File-base profiling starts that host's own loopback `dbgs`; server-base profiling uses the configured shared server endpoint. Cleanup stops only owned processes and detaches only owned debugger targets.

Use the shared 1C launcher or installed project's helper, preserving its per-infobase guard and Vanessa lifecycle. Apply target resource limits to every child process and treat `RESOURCE_LIMIT_EXCEEDED` as a non-replayable safety stop. Arbitrary scenario scripts are trusted authorized code, not sandboxed programs; operation declarations prevent accidental routing, not malicious scripts. Do not send jobs from untrusted shared-folder writers.

On failure inspect current state/result/logs. Automatic AI fallback is diagnosis-only for an interrupted job and requires `agentFallback` in the profile. Continue mutations in a new authorized job linked with `--parent`, after proving prior ownership ended and checking effects. Runtime discrepancies block only wrong-target execution, unauthorized mutation, data loss or false evidence; missing optional capabilities stay diagnostic.
