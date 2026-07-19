# itl-ondemand-mcp

Windows x64 stdio facade for the ITL branch-local ROCTUP and Vanessa UI MCP backends.

The executable is registered once in the active client's project MCP config. It serves a versioned compatibility catalog locally; the first tool call asks the private workflow broker to start a backend, initializes its Streamable HTTP MCP session, verifies the complete actual catalog, and only then forwards the call. Backend ports and processes never appear in client configuration.

Build the release asset from the repository root:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Build-ItlOnDemandMcp.ps1
```

The resulting SHA256 must be copied into `templates/dependency-lock.json` in the same workflow release that publishes the asset. Compatibility catalogs must be generated from a real backend `tools/list` response with `scripts/New-ItlOnDemandCatalog.ps1`; hand-authored catalogs are not release-qualified.
