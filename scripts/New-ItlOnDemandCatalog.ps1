[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet("roctup", "vanessa-ui")][string]$Family,
    [Parameter(Mandatory = $true)][string]$BackendVersionsJson,
    [Parameter(Mandatory = $true)][string]$ToolsListPath,
    [Parameter(Mandatory = $true)][string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$utf8 = New-Object System.Text.UTF8Encoding $false

$source = Get-Content -LiteralPath $ToolsListPath -Raw -Encoding UTF8 | ConvertFrom-Json
$pages = @($source)
$tools = @()
for ($index = 0; $index -lt $pages.Count; $index++) {
    $page = $pages[$index]
    if ($null -eq $page.result -or $null -eq $page.result.tools) {
        throw "Input must contain one real MCP tools/list JSON-RPC response or an array of paginated responses."
    }
    $tools += @($page.result.tools)
    $nextCursor = ""
    if ($page.result.PSObject.Properties.Name -contains "nextCursor") {
        $nextCursor = [string]$page.result.nextCursor
    }
    if ($index -lt ($pages.Count - 1) -and -not $nextCursor) {
        throw "tools/list page $($index + 1) has no nextCursor but more captured pages follow."
    }
    if ($index -eq ($pages.Count - 1) -and $nextCursor) {
        throw "The captured tools/list is incomplete; final nextCursor is '$nextCursor'."
    }
}
if ($tools.Count -eq 0) {
    throw "The tools/list response contains no tools."
}

$names = @{}
foreach ($tool in $tools) {
    if ([string]::IsNullOrWhiteSpace([string]$tool.name) -or $null -eq $tool.inputSchema) {
        throw "Every tool must contain name and inputSchema."
    }
    if ($names.ContainsKey([string]$tool.name)) {
        throw "Duplicate tool name: $($tool.name)"
    }
    $names[[string]$tool.name] = $true
}

$backendVersions = $BackendVersionsJson | ConvertFrom-Json
$catalog = [ordered]@{
    schemaVersion = 1
    family = $Family
    backendVersions = $backendVersions
    generatedFrom = "mcp-tools-list"
    capturedAt = [DateTime]::UtcNow.ToString("o")
    tools = @($tools | Sort-Object name)
}
$directory = Split-Path -Parent $OutputPath
if ($directory) {
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
}
$json = ($catalog | ConvertTo-Json -Depth 100).Replace("`r`n", "`n").Replace("`r", "`n")
[System.IO.File]::WriteAllText($OutputPath, ($json + "`n"), $utf8)
$hash = (Get-FileHash -LiteralPath $OutputPath -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Host "Catalog: $OutputPath"
Write-Host "Tools: $($tools.Count)"
Write-Host "SHA256: $hash"
