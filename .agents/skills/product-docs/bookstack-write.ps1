# This on-demand client sends the personal credential only on the write tool call.
[CmdletBinding(DefaultParameterSetName='Preview')]
param(
    [Parameter(Mandatory)][uri]$Endpoint,
    [Parameter(Mandatory, ParameterSetName='Preview')]
    [Parameter(Mandatory, ParameterSetName='Apply')][string]$DraftPath,
    [Parameter(Mandatory, ParameterSetName='Apply')][string]$Confirmation,
    [Parameter(Mandatory, ParameterSetName='Source')][ValidateRange(1,2147483647)][int]$ReadSource,
    [Parameter(Mandatory, ParameterSetName='Credential')][switch]$SetCredential
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
if ([Environment]::OSVersion.Platform -ne 'Win32NT') { throw 'Personal BookStack credentials require Windows DPAPI.' }
# A Windows PowerShell child started by a different edition can inherit its module search path.
Import-Module (Join-Path $PSHOME 'Modules/Microsoft.PowerShell.Security/Microsoft.PowerShell.Security.psd1') -Scope Local
if ($Endpoint.Scheme -notin 'http','https' -or $Endpoint.UserInfo -or $Endpoint.Fragment -or
    $Endpoint.AbsolutePath -cnotmatch '^/(?:views/[a-z0-9._-]+/)?mcp/?$' -or
    ($Endpoint.Query -and ($Endpoint.Query -cnotmatch '^\?view=[a-z0-9._-]+$' -or $Endpoint.AbsolutePath -like '/views/*'))) {
    throw 'Use the exact global or scoped BookStack MCP URL from the active project client configuration.'
}
$origin = $Endpoint.GetLeftPart([UriPartial]::Authority)
$store = Join-Path $env:LOCALAPPDATA 'ITL/BookStack'
$credentialPath = Join-Path $store 'personal.clixml'

function Save-PersonalCredential {
    # Get-Credential supports Windows PowerShell desktop and interactive terminals.
    $credential = Get-Credential -Message "Personal BookStack API token for $origin. Enter Token ID as username and Token Secret as password."
    if (-not $credential -or -not $credential.UserName -or -not $credential.Password.Length) {
        throw 'Credential entry cancelled. Run the same preview when ready.'
    }
    [void][IO.Directory]::CreateDirectory($store)
    $temp = Join-Path $store ([guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [pscustomobject]@{Origin=$origin; Credential=$credential} | Export-Clixml -LiteralPath $temp
        if ([IO.File]::Exists($credentialPath)) {
            if (-not $SetCredential) { return } # Another first-use prompt already completed.
            [IO.File]::Replace($temp, $credentialPath, [System.Management.Automation.Language.NullString]::Value)
        } else {
            try { [IO.File]::Move($temp, $credentialPath) }
            catch [IO.IOException] { if (-not [IO.File]::Exists($credentialPath)) { throw } }
        }
    } finally {
        if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) }
    }
}

if ($SetCredential) { Save-PersonalCredential; return }
$change = if ($ReadSource) { @{page_id=$ReadSource} } else {
    [IO.File]::ReadAllText((Resolve-Path -LiteralPath $DraftPath).ProviderPath, [Text.UTF8Encoding]::new($false,$true)) | ConvertFrom-Json
}
if (-not [IO.File]::Exists($credentialPath)) {
    try { Save-PersonalCredential }
    catch { throw "Personal token entry did not complete ($($_.FullyQualifiedErrorId)). In your own PowerShell run & '$PSCommandPath' -Endpoint '$Endpoint' -SetCredential, then repeat the preview." }
}
$saved = Import-Clixml -LiteralPath $credentialPath
if ($saved.Origin -cne $origin) {
    throw "The saved token belongs to another MCP origin. Verify the configured server. Use -SetCredential interactively to replace the personal binding."
}

Add-Type -AssemblyName System.Net.Http
$handler = [Net.Http.HttpClientHandler]::new()
$handler.AllowAutoRedirect = $false
$http = [Net.Http.HttpClient]::new($handler)
$http.Timeout = [TimeSpan]::FromSeconds(120)
function Invoke-BookStackRpc($Message, [switch]$Personal) {
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post, $Endpoint)
    try {
        $request.Headers.Add('Accept','application/json, text/event-stream')
        if ($protocol) { $request.Headers.Add('MCP-Protocol-Version',$protocol) }
        if ($Personal) {
            $pair = $saved.Credential.UserName + ':' + $saved.Credential.GetNetworkCredential().Password
            if ($pair -cnotmatch '^[!-9;-~]+:[!-9;-~]+$') { throw 'Invalid personal token format. Replace it with -SetCredential.' }
            $request.Headers.Add('X-BookStack-Token',$pair)
        }
        $request.Content = [Net.Http.StringContent]::new(($Message | ConvertTo-Json -Depth 12 -Compress),[Text.Encoding]::UTF8,'application/json')
        $response = $http.SendAsync($request).GetAwaiter().GetResult()
        try {
            if (-not $response.IsSuccessStatusCode) { throw "BookStack MCP HTTP $([int]$response.StatusCode). Check the configured endpoint." }
            if (-not $Message.ContainsKey('id')) { return }
            $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
            $raw = [Text.Encoding]::UTF8.GetString($bytes)
            if ($response.Content.Headers.ContentType.MediaType -eq 'text/event-stream') {
                foreach ($event in ($raw -split '\r?\n\r?\n')) {
                    $lines = @($event -split '\r?\n' | Where-Object { $_ -clike 'data:*' } | ForEach-Object { $_.Substring(5).TrimStart(' ') })
                    if (-not $lines.Count) { continue }
                    $reply = ($lines -join [Environment]::NewLine) | ConvertFrom-Json
                    if ($reply.id -eq $Message.id) { break }
                }
            } else { $reply = $raw | ConvertFrom-Json }
            if ($reply.id -ne $Message.id -or $reply.error -or -not $reply.result) {
                throw 'BookStack MCP did not accept the request. Check the endpoint and installed write capability.'
            }
            return $reply.result
        } finally { $response.Dispose() }
    } finally { $request.Dispose() }
}
try {
    $protocol = ''
    $init = Invoke-BookStackRpc @{jsonrpc='2.0'; id=1; method='initialize'; params=@{protocolVersion='2025-03-26'; capabilities=@{}; clientInfo=@{name='itl-bookstack-write'; version='1'}}}
    $protocol = [string]$init.protocolVersion
    Invoke-BookStackRpc @{jsonrpc='2.0'; method='notifications/initialized'}
    $arguments = @{change=$change}
    if ($PSCmdlet.ParameterSetName -eq 'Apply') { $arguments.confirmation = $Confirmation }
    $result = Invoke-BookStackRpc @{jsonrpc='2.0'; id=2; method='tools/call'; params=@{name='write_page'; arguments=$arguments}} -Personal
    if (-not $result.structuredContent -or $result.isError) { throw 'BookStack MCP write tool unavailable. Check its deployed version.' }
    $result.structuredContent | ConvertTo-Json -Depth 12
} finally { $http.Dispose() }
