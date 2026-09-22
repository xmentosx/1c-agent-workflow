# Execution ownership acceptance matrix

The former database-ticket acceptance matrix is superseded. The current contract
is `execution-guards-v2`: OS handles own bounded executions; JSON is diagnostic;
idle backends own no database; interrupted dev/test work creates no generic
recovery gate.

Status vocabulary:

- `LOCAL PASS`: deterministic source/fixture evidence on the exact candidate.
- `PENDING LIVE`: requires an installed disposable 1C/host contour and is not
  implied by local tests.
- `SEPARATE DELIVERY`: registration, publication or installation state, never a
  substitute for runtime acceptance.

| # | Scenario | Required evidence | Current source evidence |
|---|---|---|---|
| 1 | Stale legacy tickets/indexes/recovery markers, no live owner | Cutover removes only obsolete state and the next helper reaches its native phase | `ExecutionGuardCutover.Tests.ps1`; installed upgrade remains `PENDING LIVE` |
| 2 | Two jobs, same exact base | Second reports `waiting-for-base`, then runs after first releases and revalidates input | Python execution-guard/job tests: `LOCAL PASS` |
| 3 | Jobs on different bases | Concurrent progress | Python execution-guard tests: `LOCAL PASS` |
| 4 | Owner dies before native side effect | OS handle releases and waiter proceeds without ticket repair | Python process-boundary tests: `LOCAL PASS` |
| 5 | Owned child hangs | Deadline/cancel closes exact owned tree; waiter proceeds | Supervisor/Job Object fixture: `LOCAL PASS`; real 1C `PENDING LIVE` |
| 6 | Caller dies, supervisor remains | Supervisor completes bounded cleanup | Host fixture: `LOCAL PASS` |
| 7 | Supervisor dies | Job Object closes owned activity; next supervisor checks current processes | Windows fixture: `LOCAL PASS`; real 1C `PENDING LIVE` |
| 8 | Dev/test job interrupted after an effect | Result remains interrupted; next command starts without rollback/recovery gate and does not replay old effect | Job-state tests: `LOCAL PASS`; installed 1C `PENDING LIVE` |
| 9 | Foreign or unidentified 1C process | No force-kill; bounded conflict only for exact base; unrelated base/update continues | Drain/cutover ownership tests: `LOCAL PASS`; real server process `PENDING LIVE` |
| 10 | Refresh-lite fingerprint unchanged | No execution guard is created | Refresh selection fixture: `LOCAL PASS` |
| 11 | Refresh waits for branch base | No master/Git/runtime writer held while waiting; state revalidated afterward | Lifecycle/guard fixture: `LOCAL PASS`; installed contention `PENDING LIVE` |
| 12 | Refresh-all with one busy base | Other branches complete; aliases of the same base serialize | Multi-branch fixture required: `PENDING LIVE` |
| 13 | Multi-resource execution | All-or-none ordered acquisition, no partial hold | Python and Go guard tests: `LOCAL PASS` |
| 14 | Wait cancellation | Only waiter is cancelled; owner remains | Python and Go guard tests: `LOCAL PASS` |
| 15 | Broken/missing diagnostic JSON | No live conflict means next command starts | Python guard tests: `LOCAL PASS` |
| 16 | File path contains spaces and Cyrillic together | Canonical identity, native argv and UTF-8 output remain exact | Python/PowerShell focused fixtures: `LOCAL PASS` |
| 17 | Server base execution host | Only configured host may execute; conflicting topology fails before start | Configuration fixture: `LOCAL PASS`; server contour `PENDING LIVE` |
| 18 | Upgrade active branches from old helpers | Master-owned cutover bypasses old locks, replaces managed files and commits each changed worktree before enabling v2, then removes obsolete state | Multi-worktree cutover fixture with preserved staged user change: `LOCAL PASS`; real old installation `PENDING LIVE` |
| 19 | Nested measurement/source capture and facade/broker/native | Signed context is a resource subset and cannot reacquire or expand parent guard | Python and Go nested-context tests: `LOCAL PASS` |
| 20 | Cleanup cannot stop live conflict | Bounded exact-base error; later command starts after activity ends without resetting error state | Drain fixture: `LOCAL PASS`; real 1C `PENDING LIVE` |
| 21 | Interrupted check/load | Never becomes passed/fresh evidence; later check/refresh is allowed normally | Verification/load checkpoint fixtures: `LOCAL PASS` |

## Delivery boundary

Source tests and `RegisterChange` prove only the registered source candidate.
`PublishDevelop`, installed refresh, file/server live runs and Release qualification
are separate states and require their own authorization and evidence.
