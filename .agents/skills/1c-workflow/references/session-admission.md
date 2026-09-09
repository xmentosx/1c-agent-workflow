# Session admission and waiting

`ONEC_MAX_CONCURRENT_SESSIONS` bounds processes per exact infobase. Admission
counts external processes, serializes count-and-start, and reserves promised
TestClient slots. TestManager normally uses a separate service base. Its session
must not be counted as a session in the target TestClient base.

MCP and Vanessa verification wait for occupied capacity without stopping existing
sessions. Ordinary admission waits up to 300 seconds; a performance operation
uses its phase budget, cancellation file and original execution-host monotonic
deadline. The deadline is checked again before attempting native process start.
`ITL_ONEC_SESSION_WAIT` reports that work is waiting for capacity. An impossible
request, such as needing more sessions than the configured maximum, fails
immediately. A timeout is a scheduling failure; it is not proof of a product or
test defect. Do not raise the limit or stop other tasks to make admission pass.

Only a capacity rejection proven to precede any native start attempt can be
retried. Once native launch has been attempted, even an error resembling a
capacity error cannot authorize replay. Waiting releases the allocator between
attempts and cannot be combined with a destructive recovery callback. Nested
performance launchers retain the original deadline, rather than restarting its
clock when another process or transport is entered.

A single-process startup reservation ends when its exact leader exits, even if
the launching PowerShell is still alive. Reservations for promised TestClients
retain their existing owner lifetime; they are not removed merely because a
manager disappeared. Actual remaining processes continue to count against the
limit independently of reservations.

The portable launch and source-capture helpers import the target workspace's
`.dev.env` before session admission. Source-capture waiting and Designer execution
share the capture phase budget. A persistent owned client occupying the only
allowed slot can therefore leave capture waiting until timeout. Closing or
restarting it requires an adapter lifecycle contract that preserves the scenario;
it is not an automatic capacity-recovery action.

Session capacity is separate from ownership of an entire database operation.
The shared operation coordinator must also prevent another task from updating,
restoring or measuring the same database during a measurement series. Available
session capacity alone does not establish an isolated measurement environment.
