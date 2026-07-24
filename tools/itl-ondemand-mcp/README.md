# itl-ondemand-mcp

Windows x64 stdio facade for the ITL branch-local ROCTUP and Vanessa UI MCP backends.

The executable is registered once in the active client's project MCP config. Its default gateway surface publishes only `resolve_tool` and `call_tool`; the versioned full compatibility catalog remains internal. `resolve_tool` searches that catalog without starting 1C. `call_tool` validates the selected inner tool and arguments, asks the private workflow broker to start a backend, initializes its Streamable HTTP MCP session, verifies the complete actual catalog, and only then forwards the call unchanged. Backend ports and processes never appear in client configuration. `--surface full` keeps the prior direct-catalog surface as a diagnostic fallback.

For Vanessa, the broker leases separate MCP-manager and TestClient ports, creates the reserved `itl-ondemand` TestClient profile, and starts Vanessa Automation with silent/fail-closed VanessaExt installation. Editor-only calls leave TestClient stopped. Before a TestClient-dependent call, the facade reuses a proven owned process or runs the shared capacity/license preflight, starts one owned process, proves its port, auto-connects the reserved profile, and requires a positive logical-connection postcondition. Foreign processes count toward capacity but are never claimed or stopped. The facade stops only owned processes on idle or stdio EOF and never edits unsafe-action protection automatically.

Every forwarded call appends schema-v2 evidence under `.agent-1c/mcp/ondemand/<family>/`. Evidence stores outcome/result code, catalog and instance identity, argument SHA, and—when applicable—the project-relative feature path, feature SHA, and scenario line. Failed calls also store a sanitized short result message and backend log path. Vanessa runtime/editor exception text is returned as `ITL_VANESSA_TOOL_RESULT_FAILED` even when the upstream MCP response incorrectly reports `IsError=false`; raw arguments, secrets, configuration content, successful result content, and scenario content are never persisted.

If a registered backend refuses a connection, the facade asks the private broker to compare the registered PID and port with the ownership record under the existing runtime/start locks. Only a dead PID or a verified owned PID with an unavailable port is stale; an unverified live PID fails closed. The broker atomically claims and removes the stale runtime, starts one replacement with a new instance ID, and the facade retries the original call once only when the compatibility contract marks it read-only/idempotent or it is in the conservative Vanessa idempotency policy. Other calls return `ITL_ONDEMAND_RECOVERY_ACTION_REQUIRED` with the old/new instance IDs and an explicit manual-review action; their outcome is treated as unknown and they are never replayed automatically.

Build the release asset from the repository root:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Build-ItlOnDemandMcp.ps1
```

The resulting SHA256 must be copied into `templates/dependency-lock.json` in the same workflow release that publishes the asset. Compatibility catalogs must be generated from a real backend `tools/list` response with `scripts/New-ItlOnDemandCatalog.ps1`; hand-authored catalogs are not release-qualified.
