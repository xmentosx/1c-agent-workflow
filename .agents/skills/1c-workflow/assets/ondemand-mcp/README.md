# On-demand MCP compatibility assets

`compatibility.json` is the release allow-list for backend versions and exact MCP tool catalogs. Installed-project `fresh` mode may select only versions present here.

Generate a catalog from the complete, real MCP `tools/list` result (including all pages):

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\New-ItlOnDemandCatalog.ps1 `
  -Family roctup `
  -BackendVersionsJson '{"roctup":"v1.7.1"}' `
  -ToolsListPath <captured-tools-list.json> `
  -OutputPath .\.agents\skills\1c-workflow\assets\ondemand-mcp\catalogs\roctup-v1.7.1.json
```

Update the manifest SHA256 and run the live compatibility Release gate in the same change. Catalog SHA256 is calculated from UTF-8 text normalized to LF, so Git line-ending conversion does not change catalog identity. Do not admit an upstream version from source inspection or a manually reconstructed schema alone.
