[CmdletBinding()]
param(
    [string]$CodeCheckerUrl = "http://dev-ermakov.itland.local:18003/mcp",
    [string]$CodeUrl = "http://dev-ermakov.itland.local:18100/mcp",
    [string]$GraphUrl = "http://dev-ermakov.itland.local:18101/mcp"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$proxyScript = Join-Path $repoRoot "vibecoding1c-mcp-host\tools-list-proxy\mcp-tools-list-proxy.js"
$contractPath = Join-Path $repoRoot "vibecoding1c-mcp-host\tools-list-proxy\tools-contract.json"
$logRoot = Join-Path $repoRoot "build\tools-list-proxy-smoke"
New-Item -ItemType Directory -Force -Path $logRoot | Out-Null
$specs = @(
    [pscustomobject]@{ id = "codechecker"; directUrl = $CodeCheckerUrl; proxyUrl = "http://127.0.0.1:23991/mcp"; port = 23991; smokeTool = "fetch_its" },
    [pscustomobject]@{ id = "code"; directUrl = $CodeUrl; proxyUrl = "http://127.0.0.1:23992/mcp"; port = 23992; smokeTool = "stats" },
    [pscustomobject]@{ id = "graph"; directUrl = $GraphUrl; proxyUrl = "http://127.0.0.1:23993/mcp"; port = 23993; smokeTool = "get_indexing_status" }
)

function ConvertFrom-McpResponse {
    param([string]$Text)
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line.StartsWith("data:")) { return ($line.Substring(5).Trim() | ConvertFrom-Json) }
    }
    return ($Text | ConvertFrom-Json)
}

function Open-McpConnection {
    param([string]$Url)
    $headers = @{ Accept = "application/json, text/event-stream" }
    $body = [ordered]@{
        jsonrpc = "2.0"; id = 1; method = "initialize"
        params = [ordered]@{ protocolVersion = "2025-03-26"; capabilities = [ordered]@{}; clientInfo = [ordered]@{ name = "itl-tools-proxy-smoke"; version = "1" } }
    } | ConvertTo-Json -Depth 8 -Compress
    $response = Invoke-WebRequest -UseBasicParsing -Uri $Url -Method Post -ContentType "application/json" -Headers $headers -Body $body -TimeoutSec 30
    $sessionId = [string]$response.Headers["mcp-session-id"]
    if ($sessionId) { $headers["mcp-session-id"] = $sessionId }
    $effectiveUrl = $response.BaseResponse.ResponseUri.AbsoluteUri
    $notification = '{"jsonrpc":"2.0","method":"notifications/initialized"}'
    Invoke-WebRequest -UseBasicParsing -Uri $effectiveUrl -Method Post -ContentType "application/json" -Headers $headers -Body $notification -TimeoutSec 30 | Out-Null
    return [pscustomobject]@{ url = $effectiveUrl; headers = $headers }
}

function Invoke-McpJsonRpc {
    param([object]$Connection, [object]$Payload)
    $body = $Payload | ConvertTo-Json -Depth 20 -Compress
    $response = Invoke-WebRequest -UseBasicParsing -Uri $Connection.url -Method Post -ContentType "application/json" -Headers $Connection.headers -Body $body -TimeoutSec 60
    return [pscustomobject]@{ payload = (ConvertFrom-McpResponse -Text $response.Content); content = $response.Content }
}

function Remove-McpDescriptionFields {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [string] -or $Value -is [ValueType]) { return $Value }
    if ($Value -is [System.Collections.IDictionary]) {
        $copy = [ordered]@{}
        foreach ($key in @($Value.Keys | ForEach-Object { [string]$_ } | Sort-Object -CaseSensitive)) {
            if ([string]$key -eq "description") { continue }
            $copy[[string]$key] = Remove-McpDescriptionFields -Value $Value[$key]
        }
        return $copy
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        return @($Value | ForEach-Object { Remove-McpDescriptionFields -Value $_ })
    }
    $copy = [ordered]@{}
    foreach ($property in @($Value.PSObject.Properties | Sort-Object Name -CaseSensitive)) {
        if ($property.Name -eq "description") { continue }
        $copy[$property.Name] = Remove-McpDescriptionFields -Value $property.Value
    }
    return $copy
}

function Get-McpToolContractJson {
    param([object[]]$Tools)
    $contracts = foreach ($tool in $Tools) {
        $contract = [ordered]@{
            name = [string]$tool.name
            inputSchema = Remove-McpDescriptionFields -Value $tool.inputSchema
        }
        if ($null -ne $tool.PSObject.Properties["outputSchema"]) {
            $contract.outputSchema = Remove-McpDescriptionFields -Value $tool.outputSchema
        }
        if ($null -ne $tool.PSObject.Properties["annotations"]) {
            $contract.annotations = Remove-McpDescriptionFields -Value $tool.annotations
        }
        [pscustomobject]$contract
    }
    return ($contracts | ConvertTo-Json -Depth 100 -Compress)
}

$processes = @()
try {
    foreach ($spec in $specs) {
        $arguments = @(
            $proxyScript, "--listen-port", [string]$spec.port,
            "--upstream-url", $spec.directUrl, "--server-id", $spec.id,
            "--contract-path", $contractPath
        )
        $stdoutPath = Join-Path $logRoot "$($spec.id).stdout.log"
        $stderrPath = Join-Path $logRoot "$($spec.id).stderr.log"
        Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
        $processes += Start-Process -FilePath "node" -ArgumentList $arguments -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru
    }
    Start-Sleep -Seconds 3
    for ($index = 0; $index -lt $specs.Count; $index++) {
        $processes[$index].Refresh()
        if ($processes[$index].HasExited) {
            $stderrPath = Join-Path $logRoot "$($specs[$index].id).stderr.log"
            throw "Proxy process for '$($specs[$index].id)' exited early: $((Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue).Trim())"
        }
        $health = Invoke-RestMethod -Uri ("http://127.0.0.1:{0}/health" -f $specs[$index].port) -TimeoutSec 10
        if ($health.serverId -ne $specs[$index].id) { throw "Unexpected proxy health response on port $($specs[$index].port)." }
    }

    $results = @()
    $totalDirect = 0
    $totalProxy = 0
    foreach ($spec in $specs) {
        $direct = Open-McpConnection -Url $spec.directUrl
        $proxy = Open-McpConnection -Url $spec.proxyUrl
        $listPayload = [ordered]@{ jsonrpc = "2.0"; id = 2; method = "tools/list"; params = [ordered]@{} }
        $directList = Invoke-McpJsonRpc -Connection $direct -Payload $listPayload
        $proxyList = Invoke-McpJsonRpc -Connection $proxy -Payload $listPayload
        [IO.File]::WriteAllText((Join-Path $logRoot "$($spec.id).tools-list.txt"), $proxyList.content, (New-Object Text.UTF8Encoding $false))
        $directTools = @($directList.payload.result.tools)
        $proxyTools = @($proxyList.payload.result.tools)
        $directJson = $directTools | ConvertTo-Json -Depth 50 -Compress
        $proxyJson = $proxyTools | ConvertTo-Json -Depth 50 -Compress
        $totalDirect += $directJson.Length
        $totalProxy += $proxyJson.Length
        if ((@($directTools.name) -join "`n") -ne (@($proxyTools.name) -join "`n")) { throw "Tool names differ for $($spec.id)." }
        $directContract = Get-McpToolContractJson -Tools $directTools
        $proxyContract = Get-McpToolContractJson -Tools $proxyTools
        [IO.File]::WriteAllText((Join-Path $logRoot "$($spec.id).direct-contract.json"), $directContract, (New-Object Text.UTF8Encoding $false))
        [IO.File]::WriteAllText((Join-Path $logRoot "$($spec.id).proxy-contract.json"), $proxyContract, (New-Object Text.UTF8Encoding $false))
        if ($directContract -cne $proxyContract) { throw "Tool JSON Schema or annotations differ for $($spec.id)." }
        $overBudget = @($proxyTools | Where-Object { ([string]$_.description).Length -gt 160 })
        if ($overBudget.Count -gt 0) { throw "Proxy description budget failed for $($spec.id): $(($overBudget | ForEach-Object { $_.name + '=' + ([string]$_.description).Length }) -join ', ')." }
        $tool = @($proxyTools | Where-Object name -eq $spec.smokeTool | Select-Object -First 1)
        if ($tool.Count -ne 1) { throw "Smoke tool '$($spec.smokeTool)' was not found for $($spec.id)." }
        $requiredProperty = $tool[0].inputSchema.PSObject.Properties["required"]
        if ($null -ne $requiredProperty -and @($requiredProperty.Value).Count -gt 0) { throw "Smoke tool '$($spec.smokeTool)' unexpectedly requires arguments." }
        $call = Invoke-McpJsonRpc -Connection $proxy -Payload ([ordered]@{ jsonrpc = "2.0"; id = 3; method = "tools/call"; params = [ordered]@{ name = $spec.smokeTool; arguments = [ordered]@{} } })
        if ($null -ne $call.payload.PSObject.Properties["error"]) { throw "tools/call failed for $($spec.id)/$($spec.smokeTool): $($call.payload.error | ConvertTo-Json -Compress)" }
        $results += [pscustomobject]@{
            server = $spec.id; tools = $proxyTools.Count; directChars = $directJson.Length; proxyChars = $proxyJson.Length
            reductionPercent = [Math]::Round((1 - ($proxyJson.Length / [double]$directJson.Length)) * 100, 1)
            smokeTool = $spec.smokeTool; call = "passed"
        }
    }
    $results += [pscustomobject]@{
        server = "TOTAL"; tools = ($results.tools | Measure-Object -Sum).Sum; directChars = $totalDirect; proxyChars = $totalProxy
        reductionPercent = [Math]::Round((1 - ($totalProxy / [double]$totalDirect)) * 100, 1)
        smokeTool = "three tools/call requests"; call = "passed"
    }
    $results | Format-Table -AutoSize
} finally {
    foreach ($process in $processes) {
        if ($null -ne $process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
    }
}
