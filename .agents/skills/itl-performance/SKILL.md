---
name: itl-performance
description: Measure elapsed time, capture 1C client/server profiles, and compare or analyze reproducible scenarios locally or remotely. Use for actual performance evidence; remote execution composes with itl-remote-runner or itl-remote-agent.
---

# ITL performance

Run the same engine locally, through SSH, or through a remote agent. Local measurements require neither SSH nor another AI agent. On Windows use `../itl-remote-runner/scripts/Invoke-RemoteWork.ps1`, which provisions Python for the shared engine; read [measurement recipes](references/measurements.md) and the [scenario contract](../itl-remote-runner/references/contracts.md) as needed.

## Prepare the scenario

Turn the user's requested operation into a named, versioned scenario under the project's `tests/performance/<name>/`. Save new scenarios directly in project files. Reuse existing ones for “repeat”, changing parameters only in the new job. Never hardcode a PM5 plan, database, username, host or deployment path into the portable skill.

Specify arbitrary typed parameters, data identity, preparation, measured actions, actual readiness, assertions, repeatability, reset and cleanup. Prefer stable semantic Vanessa/TestClient actions; do not silently substitute a server-only call for a user-facing path. For PM5 product decisions use product-docs before designing business assertions.

By default collect one warmup, three unprofiled timings and one separate profiled run. Honor explicit counts/modes. A non-repeatable operation gets one permitted execution; without safe reset, record the omitted profile/repetitions as incomplete rather than rerun it. Never empty shared caches for a “cold” run. Define coldness in the scenario and report its exact scope.

## Execute and interpret

- Resolve local/remote host and target, announce the operation and authorization. Configure `dbgs` according to base topology: for a file base launch a job-owned local `dbgs` on the execution machine; for a server base use its configured shared server endpoint. Never launch a replacement server merely because a server endpoint is unreachable.
- Run preparation and any authorized update outside the measured interval. Use the user's/project's update adapter, including ordinary confirmation handling, instead of inventing a generic destructive update.
- Use handshake timing for UI/server operations whose startup must be excluded. The action signals readiness before `go`, then completion only after its actual ready condition. A command return or active window alone cannot prove rendered HTML/Gantt or background-job completion.
- Collect profiles only for proven owned targets of the same runtime session/base. Validate original raw packets and exact configuration/source identity. Preserve the original bytes and report unmapped sources. Do not add overlapping client/server or inclusive timings.
- Report all unprofiled samples, median/range, readiness, source/data/environment identity, separate phase costs, raw profile locations and limitations. A small sample is not statistical evidence of an improvement. Raw `PerformanceInfoMain` is not a native PFF; an explicit PFF requirement stays open without a verified native file.
- Compare compatible saved runs or prepare explicit alternating A/B jobs with restoration between versions. A historical comparison is labelled as such. Offline analysis must not start 1C.

Benchmark scenarios are explicit diagnostics, outside the default `/itl-check` inventory. Performance results never replace functional verification or authorize weakening assertions. Distinguish engine/fixture tests from real local and remote 1C evidence.
