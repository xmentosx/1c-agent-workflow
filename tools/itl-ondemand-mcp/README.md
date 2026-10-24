# itl-ondemand-mcp

Windows x64 stdio facade for the ITL branch-local ROCTUP and Vanessa UI MCP backends.

The executable is registered once in the active client's project MCP config. Its default gateway surface publishes `resolve_tool` and `call_tool`; the versioned full compatibility catalog remains internal. `resolve_tool` searches that catalog without starting 1C. For parameterized calls, `call_tool.argumentsJson` carries one JSON-encoded inner object so schema-restricting model clients cannot erase unknown nested property names; `arguments={}` remains the no-argument object form, and the two forms are mutually exclusive. The facade parses and validates the selected inner tool arguments, acquires an execution guard for that one call, asks the private workflow broker to start a backend, initializes its Streamable HTTP MCP session, verifies the complete actual catalog, and only then forwards the call unchanged. Backend ports and processes never appear in client configuration. `--surface full` keeps the prior direct-catalog surface as a diagnostic fallback; it uses the same call-scoped execution boundary.

For Vanessa, the broker leases separate MCP-manager and TestClient ports, creates the reserved `itl-ondemand` TestClient profile, and starts Vanessa Automation with silent/fail-closed VanessaExt installation. Editor-only calls leave TestClient stopped. Before a TestClient-dependent call, the facade reuses a proven owned process or runs the shared capacity/license preflight, starts one owned process, proves its port, auto-connects the reserved profile, and requires a positive logical-connection postcondition. A capacity failure permits one shared exact-dev-infobase cleanup and one admission retry; source-infobase, other-branch, and ambiguous processes remain fail-closed. Idle or stdio-EOF cleanup remains ownership-scoped and unsafe-action protection is never edited automatically.

Every forwarded call appends schema-v3 evidence under `.agent-1c/mcp/ondemand/<family>/`. Evidence stores outcome/result code, catalog and instance identity, argument SHA, and—when applicable—the project-relative feature path, feature SHA, and scenario line. Failed calls also store a sanitized short result message and backend log path. Vanessa runtime/editor exception text is returned as `ITL_VANESSA_TOOL_RESULT_FAILED` even when the upstream MCP response incorrectly reports `IsError=false`; raw arguments, secrets, configuration content, successful result content, and scenario content are never persisted.

If its runtime JSON disappears between completed calls, the same facade may
recover its backend without replacing the external MCP connection. The broker
returns an original launch snapshot in memory; it is carried only inside the
existing execution invocation. Recovery first checks quiescence and the exact
PID/start/EXE/base/manager/port/TestClient/lease proofs under the inherited guard.
The existing cleanup owner stops only those processes, proves exit and closed
ports, releases their immutable leases, then starts a new instance. Missing or
conflicting proof, an unconfirmed native call, a foreign exact-base session or a
reappeared registration returns an owner continuation without restart. Missing
JSON is never reconstructed as evidence. A modifying call with unknown outcome
is never automatically replayed. Existing registered-state recovery keeps its
own contract; legacy callers without the retained snapshot cannot use this new
missing-state authority.

Every MCP tool request owns one phase deadline, including the existing default
ten-minute phase when metadata is absent. Nested broker calls inherit its
remaining time without restarting it or extending a shorter parent deadline.
The five-minute fallback still applies to broker calls outside a request phase;
cleanup retains its separate bounded owner budget. Unknown modifying outcomes
are never replayed merely because a deadline expired.

If native cleanup is unconfirmed, the original execution keeps its guard. Before
dispatching a new call, the facade retries its existing owned stop under that
same signed execution; only confirmed cleanup permits a new execution. Cleanup
debt from an idle stop is likewise reconciled before backend startup. An idle
stop encountering a registration already removed by lifecycle continues through
the existing guarded retained-launch cleanup, rather than treating removal as
either a cleanup receipt or a permanent failure.
Retained cleanup distinguishes unknown exact-base sessions from registered
warm peers of either family. A peer is preserved only after exact process/start,
executable/markers, database, listener, current registration and lease checks.
Unknown, replaced or ambiguous ownership still retains the original guard.

For both families the agent can call `call_tool` with
`name="itl_recover_connection", arguments={}`. This facade-owned operation is
discoverable through `resolve_tool` without starting 1C and is also exposed on
the full surface. It uses the existing stop owner, including a retained execution,
then initializes and verifies a usable backend under a fresh call guard. Its
cleanup, admission and cold readiness share the existing request-phase budget
(ten minutes by default or the caller's remaining phase); it never restarts that
budget or extends a shorter caller deadline. Startup phases report elapsed and
remaining milliseconds; broker errors preserve cancellation and bounded redacted
output even when the helper exits without a result marker. No
PID, base, lease or foreign instance selector is accepted, and no previous tool
operation is replayed. An unknown modifying outcome remains unknown even when
the connection is recovered; inspect its effect before deciding to issue it again.
The gateway remains two tools; its call description adds only the recovery route.

Connection cleanup can cross chat lifetimes without restarting the Desktop app.
Each facade exposes a project-local, generation/creation-identity-bound mailbox
under its family's `connections/` directory. A same-resource waiter asks the old
runtime to finish retained cleanup using its original signed execution; a busy
runtime is left alone. Requests and responses are prefixed so neither current
nor older runtime-registration scanners interpret them as backend instances.
The mailbox holds no database keys and is not admission authority. Its failure
warns and leaves same-connection recovery available.
The mailbox polls its own request directory five times per second while the
facade lives; it starts no native process and adds no client schema/context.

The private `repair-connections` broker operation is an admission-recovery
adapter for obsolete facades lacking a live mailbox. It checks the configured
caller, exact project/helper/family, versioned executable, opened process
creation identity, guard supervisor and complete resource set. It waits for
private preparation children, stops only proven exact-base workflow backends
while the old supervisor remains alive, then closes the obsolete facade and
supervisor through the shared process-cleanup helper. No guards or leases are
manually deleted; normal OS admission continues. Diagnostic receipts preserve
an interrupted call's unknown outcome and never replay it. The agent resolves
that outcome through observable effects and resumes; it asks the user only for
a remaining concrete consequential choice. This adapter has no hard-coded
version and never starts another App Server, global manager or elevated process.

Primary errors retain their dispatch outcome. When upstream succeeds but cleanup
fails, the response remains an error and includes the successful content and
structured upstream result. Existing evidence records retain the execution ID
and append sanitized `cleanup-failed` events for call finalization and idle
cleanup; successful payloads are returned to the client, never persisted there.
An already completed stop can be confirmed from the original launch proof only
when all original processes and ports are gone and no replacement lease exists.

Successfully forwarded progress notifications append separate events to
`<instance>.progress.jsonl`, correlated by `progressEvidenceId`. The completion
record's `progressNotificationsForwarded` is a snapshot at that moment, not a
claim that asynchronous notification handlers have drained. Internal unique
tokens isolate consecutive calls that reuse a caller token; the caller still
receives its original token. Routes remain valid for late notifications until
their backend session closes. Arbitrary progress text and caller tokens are not
persisted. This avoids blocking final results on guessed notification delays.

If a registered backend refuses a connection, the facade asks the private broker to compare the registered PID and port with the ownership record under the existing runtime/start locks. Only a dead PID or a verified owned PID with an unavailable port is stale; an unverified live PID fails closed. The broker atomically claims and removes the stale runtime, starts one replacement with a new instance ID, and the facade retries the original call once only when the compatibility contract marks it read-only/idempotent or it is in the conservative Vanessa idempotency policy. Other calls return `ITL_ONDEMAND_RECOVERY_ACTION_REQUIRED` with the old/new instance IDs and an explicit manual-review action; their outcome is treated as unknown and they are never replayed automatically.

The performance adapter supplies `_meta.itlPhaseRemainingMs` on tool calls to
carry its remaining phase budget through HTTP and broker startup. Ordinary calls
retain a ten-minute request budget; inherited budgets may extend to 24 hours and
never extend an earlier caller deadline. HTTP transport has no separate shorter
wall-clock cap. `--cleanup-timeout` controls owned EOF shutdown (default one
minute); forced shutdown remains unproven cleanup at the adapter boundary.

Each forwarded call acquires the `execution-guards-v2` resource set before any
backend/native work and releases it after the atomic result and owned cleanup.
The warmed idle backend is deliberately independent of database ownership and
never keeps a resource between calls. Nested broker/native work receives a
signed execution context and must stay within the outer call's declared resource
set; it neither reacquires nor expands the guard. Same-base calls wait visibly,
different-base calls remain independent, and diagnostic JSON is never lock
authority. A timeout or interruption cancels and drains only the exact owned
call/process tree; historical failure state does not block a later call. Shared
server-base execution requires one configured execution host and rejects an
ambiguous multi-host plan before launch.

Private stdio runtimes may stop a proven idle backend without a new database
admission. The local call gate excludes preparation, calls and recovery; the
native owner validates the retained launch identity under a per-instance file
lease. Vanessa uses this path only after the registered TestClient process and
listener are gone. A live child falls back to guarded cleanup; interactive
profiles and unresolved persistent/arbitrary activity keep their guarded path.
The process-only schema cannot authorize launch, recovery, bulk stop or a
database context, and old helpers reject it rather than silently downgrading.
Before this stop attempt, the facade retires its local HTTP transport and closes
the SDK session without a network DELETE. Its receive loop ends while native
ports remain reserved; no late close request can reach a replacement listener.
The live-child fallback retains the native owner and its guarded continuation.

`close_test_client` confirms the original child's physical exit before returning
success and releasing its call guard. Its nested `complete-test-client-close`
operation can finish only that exact owned child; manager, port reservations and
last registered recovery identity remain. Logical disconnect is unchanged.
Every runtime mutation reserves its sorted instance set before reading state.
The canonical record remains visible until confirmed cleanup, and stale writes,
replacement identity and unfinished legacy removal claims cannot report clean
completion. There is no database-wide or startup lock on idle manager cleanup.

Interactive profiles use a persistent owner bound to their caller identity.
A failed stop retains ownership for an explicit retry. Terminal facade shutdown
confirms bounded owned cleanup, closes its MCP transport and records the failure
result. A caller must not reuse another execution's signed context to bypass
waiting. The local source build and matching dependency lock
are preparatory evidence; publishing this component still requires its exact
source and executable to pass Release E2E for ROCTUP and Vanessa.

The `designer-agent-safe-mode` stdin subcommand also accepts a transient
`projectTestsCapability` issued by the opted-in project tooling owner. Its UTF-8
payload and HMAC use the existing live execution context and bind the exact
registered test extension, content proof, infobase, Designer process, listener
and SSH key. The facade generates the five fixed connect/set SafeMode/get/
disconnect/shutdown commands; caller-supplied commands and protection changes
are refused. The nested guard cannot reacquire or enlarge its parent's resources.
This is separate from the unchanged fixed tooling-extension sequences. See
[project test settings](../../.agents/skills/1c-workflow/references/yaxunit-tests.md).

Build the release asset from the repository root:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Build-ItlOnDemandMcp.ps1
```

The resulting SHA256 must be copied into `templates/dependency-lock.json` in the same workflow release that publishes the asset. Compatibility catalogs must be generated from a real backend `tools/list` response with `scripts/New-ItlOnDemandCatalog.ps1`; hand-authored catalogs are not release-qualified.

The existing `ondemand-mcp` E2E stage also requires the Vanessa probe's
`-verify-missing-state-recovery` evidence. On the isolated stand it removes only
its bound runtime record, calls the original `manage_test_client(connect)` on
the same external session, checks the replacement through a window-list call,
and independently observes that both original native PIDs have exited. It never
stops processes or restores runtime JSON itself. Missing proof fails acceptance;
the normal facade owner retains responsibility for cleanup and continuation.
The report includes the original record's SHA256 and safe instance fields,
without lease tokens. Probe unit tests do not qualify real 1C recovery.

Smoke may include a normal idle restart. Before fault injection, the probe makes
one read-only call on the original session and binds its current runtime record.
Instance and artifact identity must remain unchanged; the injection still checks
the exact freshly bound PID/port values and refuses contradictory records.

A previously armed idle callback becomes a no-op after terminal close or a newer
call supersedes its generation. It must not request database admission with an
expired context after waiting for recovery, or discard pending cleanup evidence.
The explicit owned-stop path still owns native cleanup and its confirmation;
guarded idle cleanup retains admission and its post-admission generation check.
