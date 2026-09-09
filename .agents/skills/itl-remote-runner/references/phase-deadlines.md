# Phase deadlines

A scenario can allow a long calculation while bounding preparation and cleanup:

```json
{
  "timeoutSeconds": 300,
  "phaseTimeoutSeconds": {"prepare": 600, "action": 2400, "cleanup": 180}
}
```

The execution host starts each deadline after database admission. Preparation,
each iteration's action/readiness/verification, reset and cleanup have distinct
budgets. A handshake first uses `ready` for workload preparation and controller
start, then receives a fresh `action` deadline in `go.json`. The measured interval
continues to exclude preparation, transport and process teardown. A separate
explicit `ready` command is timed when it establishes the user-visible completion.

Context deadlines are execution-host monotonic values, never a timestamp created
on the submitting computer. The adapter carries the same remaining phase budget
through its file wait, stdio request, facade HTTP call and nested broker startup.
The facade receives `_meta.itlPhaseRemainingMs` on each tool call; values must be
positive and no greater than 86400000. Normal calls without metadata retain a
ten-minute call budget and the normal five-minute broker budget. Long measured
calls require the corresponding 0.4.10-or-newer facade; updating Python alone
does not remove older facade limits.

Cancellation is checked during waits and forwarded to the active MCP request.
An uncertain request is not replayed and that adapter client cannot accept a new
feature. Cleanup ignores action cancellation and gets its own budget; a forced
or nonzero facade exit is a cleanup failure. If preparation fails, cleanup waits
for the daemon's terminal cleanup record rather than assuming absence of
`prepared.json` means the facade stopped. Native cancellation does not prove the
business transaction was rolled back; inspect effects before another run.

Command phase start/failure/completion and elapsed time are retained incrementally
in `progress.json`, including failed runs. This does not yet provide detailed 1C
stage progress inside a business action or prove large-calculation acceptance.
