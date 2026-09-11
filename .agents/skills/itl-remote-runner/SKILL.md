---
name: itl-remote-runner
description: Prepare a Windows remote worker and run authorized jobs through SSH or an exchange folder, including remote 1C tests and performance scenarios. Use for setup, transfer, monitoring, collection, or recovery; local measurements use itl-performance directly.
---

# ITL remote runner

Use `scripts/Invoke-RemoteWork.ps1` on Windows for durable jobs; it provisions pinned user-local Python and invokes the shared `remote_work.py` engine. It works without a plugin, Codex, Git, or a full installed ITL project. Read [the operation contract](references/operations.md) for overrides, offline delivery and the requested operation, and [the job contract](references/contracts.md) when preparing inputs.

## User route

- Resolve a named connection/target from the project's references or the user's private `%LOCALAPPDATA%/ITL/remote-work` profiles. Reuse known authorization; ask together only for missing host/login, workspace/exchange folder, target base and permitted operations. Never treat access to a server as permission for all its bases.
- For a new worker, inspect its OS, Python, 1C and SSH. Prepare missing access with `scripts/Prepare-RemoteHost.ps1`; administrative changes require their actual authorization. The user supplies authentication/host-key trust through SSH or the credential store. Do not put passwords/private keys in profiles, scenarios, prompts or Git.
- Prepare a profile with `prepare`. The user starts the emitted one-shot `Start-Worker.cmd` in the Windows session where 1C should run. It processes one queued job and exits. Do not start a hidden service or simulate a user's interactive login. On a machine with no connection yet, give the user the portable bundle to transfer once.
- Announce host, base, scenario, measurement mode and intended mutations briefly. A request to measure does not authorize a base update. Use an already authorized `update` job stage when requested; its project adapter owns platform update and startup/legal-confirmation handling.
- Use `itl-performance` to create a project scenario and package. Send it over the selected connection. `auto` uses the worker and allows the configured agent fallback; `ssh` forces worker execution; `agent` uses `itl-remote-agent`. File exchange is an alternative transport for the same executor, not a new execution engine.
- Observe the existing job ID after disconnects. Never repeat a failed modifying operation just because its reply was lost. Collect and verify results; engine state and artifacts establish completion, not a zero SSH exit code.

## Runtime boundaries

The execution host starts 1C in the user-started worker's session. File-base profiling starts that host's own loopback `dbgs`; server-base profiling uses the configured shared server endpoint. Cleanup stops only owned processes and detaches only owned debugger targets.

Use the shared 1C launcher or installed project's helper, preserving its per-infobase guard and Vanessa lifecycle. Apply target resource limits to every child process and treat `RESOURCE_LIMIT_EXCEEDED` as a non-replayable safety stop. Arbitrary scenario scripts are trusted authorized code, not sandboxed programs; operation declarations prevent accidental routing, not malicious scripts. Do not send jobs from untrusted shared-folder writers.

On failure inspect current state/result/logs. Automatic AI fallback is diagnosis-only for an interrupted job and requires `agentFallback` in the profile. Continue mutations in a new authorized job linked with `--parent`, after proving prior ownership ended and checking effects. Runtime discrepancies block only wrong-target execution, unauthorized mutation, data loss or false evidence; missing optional capabilities stay diagnostic.
