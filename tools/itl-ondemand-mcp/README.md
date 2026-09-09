# itl-ondemand-mcp

Windows x64 stdio facade for the ITL branch-local ROCTUP and Vanessa UI MCP backends.

The executable is registered once in the active client's project MCP config. Its default gateway surface publishes only `resolve_tool` and `call_tool`; the versioned full compatibility catalog remains internal. `resolve_tool` searches that catalog without starting 1C. For parameterized calls, `call_tool.argumentsJson` carries one JSON-encoded inner object so schema-restricting model clients cannot erase unknown nested property names; `arguments={}` remains the no-argument and backward-compatible object form, and the two forms are mutually exclusive. The facade parses and validates the selected inner tool arguments, asks the private workflow broker to start a backend, initializes its Streamable HTTP MCP session, verifies the complete actual catalog, and only then forwards the call unchanged. Backend ports and processes never appear in client configuration. `--surface full` keeps the prior direct-catalog surface as a diagnostic fallback.

For Vanessa, the broker leases separate MCP-manager and TestClient ports, creates the reserved `itl-ondemand` TestClient profile, and starts Vanessa Automation with silent/fail-closed VanessaExt installation. Editor-only calls leave TestClient stopped. Before a TestClient-dependent call, the facade reuses a proven owned process or runs the shared capacity/license preflight, starts one owned process, proves its port, auto-connects the reserved profile, and requires a positive logical-connection postcondition. A capacity failure permits one shared exact-dev-infobase cleanup and one admission retry; source-infobase, other-branch, and ambiguous processes remain fail-closed. Idle or stdio-EOF cleanup remains ownership-scoped and unsafe-action protection is never edited automatically.

Every forwarded call appends schema-v3 evidence under `.agent-1c/mcp/ondemand/<family>/`. Evidence stores outcome/result code, catalog and instance identity, argument SHA, and—when applicable—the project-relative feature path, feature SHA, and scenario line. Failed calls also store a sanitized short result message and backend log path. Vanessa runtime/editor exception text is returned as `ITL_VANESSA_TOOL_RESULT_FAILED` even when the upstream MCP response incorrectly reports `IsError=false`; raw arguments, secrets, configuration content, successful result content, and scenario content are never persisted.

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

Facade 0.4.11 reserves its target and manager databases through the shared
filesystem coordinator before taking the local runtime lock. It retains that
reservation while its native backend exists. Nested broker work inherits a
private proof and registers its participation; conflicting projects and chats
wait outside the runtime lock. Uncertain native cleanup requires recovery and
cannot be hidden by closing a process or a pipe. Inherited work requires the
participant-aware protocol on both sides; incompatible versions reject it before
launch. Shared coordination across hosts requires the same configured authority
and database identities, rather than separate local default directories.

Interactive profiles use a persistent owner bound to their caller identity.
A failed stop retains ownership for an explicit retry. Terminal facade shutdown
closes its own MCP transport even when native cleanup fails, retaining database
recovery evidence and the failure result. A caller must not reuse another task's
owner ID to bypass waiting. The local source build and matching dependency lock
are preparatory evidence; publishing this component still requires its exact
source and executable to pass Release E2E for ROCTUP and Vanessa.

Build the release asset from the repository root:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Build-ItlOnDemandMcp.ps1
```

The resulting SHA256 must be copied into `templates/dependency-lock.json` in the same workflow release that publishes the asset. Compatibility catalogs must be generated from a real backend `tools/list` response with `scripts/New-ItlOnDemandCatalog.ps1`; hand-authored catalogs are not release-qualified.
