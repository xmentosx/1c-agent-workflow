# itl-ondemand-mcp

Windows x64 stdio facade for the ITL branch-local ROCTUP and Vanessa UI MCP backends.

The executable is registered once in the active client's project MCP config. Its default gateway surface publishes only `resolve_tool` and `call_tool`; the versioned full compatibility catalog remains internal. `resolve_tool` searches that catalog without starting 1C. `call_tool` validates the selected inner tool and arguments, asks the private workflow broker to start a backend, initializes its Streamable HTTP MCP session, verifies the complete actual catalog, and only then forwards the call unchanged. Backend ports and processes never appear in client configuration. `--surface full` keeps the prior direct-catalog surface as a diagnostic fallback.

For Vanessa, the broker leases separate MCP-manager and TestClient ports, creates the reserved `itl-ondemand` TestClient profile, and starts Vanessa Automation with silent/fail-closed VanessaExt installation. The facade confirms VanessaExt before forwarding, rejects other profiles, verifies `connect_test_client` with a real postcondition, and stops both owned processes on idle or stdio EOF. It never edits unsafe-action protection automatically.

Build the release asset from the repository root:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Build-ItlOnDemandMcp.ps1
```

The resulting SHA256 must be copied into `templates/dependency-lock.json` in the same workflow release that publishes the asset. Compatibility catalogs must be generated from a real backend `tools/list` response with `scripts/New-ItlOnDemandCatalog.ps1`; hand-authored catalogs are not release-qualified.
