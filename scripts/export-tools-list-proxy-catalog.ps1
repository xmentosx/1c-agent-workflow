[CmdletBinding()]
param(
    [string]$HostName = "dev-ermakov.itland.local",
    [string]$OutputDirectory = "",
    [string[]]$ApproveServers = @("codechecker", "code", "graph")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repoRoot "build\tools-list-proxy-audit" }
$catalogScript = Join-Path $repoRoot "vibecoding1c-mcp-host\tools-list-proxy\mcp-tools-list-catalog.js"
$contractPath = Join-Path $repoRoot "vibecoding1c-mcp-host\tools-list-proxy\tools-contract.json"
$specs = @(
    "docs=http://$HostName`:18000/mcp",
    "templates=http://$HostName`:18001/mcp",
    "syntax=http://$HostName`:18002/mcp",
    "codechecker=http://$HostName`:18003/mcp",
    "ssl=http://$HostName`:18004/mcp",
    "bookstack=http://$HostName`:18005/mcp",
    "mantis=http://$HostName`:18006/mcp",
    "code=http://$HostName`:18100/mcp",
    "graph=http://$HostName`:18101/mcp"
)
$arguments = @($catalogScript, "--output-dir", $OutputDirectory, "--contract-path", $contractPath, "--approve-servers", ($ApproveServers -join ","))
foreach ($spec in $specs) { $arguments += @("--endpoint", $spec) }
& node @arguments
if ($LASTEXITCODE -ne 0) { throw "MCP tools/list catalog export failed with exit code $LASTEXITCODE." }
Write-Host "Catalog: $(Join-Path $OutputDirectory 'catalog.json')"
Write-Host "Report: $(Join-Path $OutputDirectory 'report.md')"
Write-Host "Approval candidates: $(Join-Path $OutputDirectory 'approved-descriptions.candidate.json')"
