[CmdletBinding()]
param(
    [string]$CtlPath = (Join-Path $env:ProgramFiles 'ITLand\AI Gateway Client\ai-gatewayctl.exe'),
    [ValidateRange(10, 1800)][int]$TimeoutSeconds = 300,
    [ValidateRange(1, 60)][int]$PollSeconds = 5,
    [ValidateRange(0, 600)][int]$PolicySettleSeconds = 30,
    [ValidateRange(1, 10)][int]$MaxStartAttempts = 3,
    [ValidateRange(1, 600)][int]$RestartAfterSeconds = 60
)
# Nightly AI Gateway Client maintenance before MCP indexing. The client applies a
# new published policy to its files but the running sing-box keeps the server set
# it started with, so a refresh is followed by a service restart. The step only
# reports: callers continue indexing whatever it returns.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Console]::OutputEncoding

function Invoke-AiGatewayCtl {
    param([string]$Command)
    # Windows PowerShell turns redirected native stderr into errors under Stop.
    $ErrorActionPreference = 'Continue'
    $global:LASTEXITCODE = 0
    $lines = @(& $CtlPath $Command 2>&1 | ForEach-Object { [string]$_ })
    return [pscustomobject]@{ exitCode = [int]$LASTEXITCODE; text = ($lines -join "`n") }
}

function Get-AiGatewayStatus {
    $result = Invoke-AiGatewayCtl -Command 'status'
    $status = [ordered]@{ service = ''; egress = ''; vpn = ''; revision = '' }
    foreach ($line in ($result.text -split "`r?`n")) {
        if ($line -match '^\s*Service:\s*(\S+)') { $status.service = $Matches[1] }
        elseif ($line -match '^\s*AI egress:\s*(\S+)') { $status.egress = $Matches[1] }
        elseif ($line -match '^\s*VPN:\s*(\S+)') { $status.vpn = $Matches[1] }
        elseif ($line -match '^\s*Policy revision:\s*(\S+)') { $status.revision = $Matches[1] }
    }
    return [pscustomobject]$status
}

function Test-AiGatewayHealthy {
    param([object]$Status)
    return ($Status.service -eq 'RUNNING' -and $Status.egress -eq 'vpn-auto' -and $Status.vpn -eq 'HEALTHY')
}

$watch = [Diagnostics.Stopwatch]::StartNew()
$result = [ordered]@{ status = ''; revisionBefore = ''; revisionAfter = ''; egress = ''; vpn = ''; startAttempts = 0; seconds = 0; message = '' }
$exitCode = 0
try {
    if (-not (Test-Path -LiteralPath $CtlPath -PathType Leaf)) {
        $result.status = 'skipped'
        $result.message = 'AI Gateway Client is not installed.'
    } else {
        $before = Get-AiGatewayStatus
        $result.revisionBefore = $before.revision
        $refresh = Invoke-AiGatewayCtl -Command 'refresh'
        if ($refresh.exitCode -ne 0) { $result.message = 'refresh exit code ' + $refresh.exitCode + '; restarting with the stored policy. ' }
        # The client confirms a refresh in the background; give it time to write the policy.
        Start-Sleep -Seconds $PolicySettleSeconds
        $stop = Invoke-AiGatewayCtl -Command 'stop'
        if ($stop.exitCode -ne 0) { throw "AI Gateway stop failed with exit code $($stop.exitCode)." }
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        $lastStart = [DateTime]::MinValue
        $status = $null
        while ($true) {
            if ($null -eq $status -or ($status.service -ne 'RUNNING' -and ((Get-Date) - $lastStart).TotalSeconds -ge $RestartAfterSeconds)) {
                if ($result.startAttempts -ge $MaxStartAttempts) { break }
                # A service left stopped would send AI traffic directly until reboot.
                $null = Invoke-AiGatewayCtl -Command 'start'
                $result.startAttempts++
                $lastStart = Get-Date
            }
            $status = Get-AiGatewayStatus
            if ((Test-AiGatewayHealthy -Status $status) -or (Get-Date) -ge $deadline) { break }
            Start-Sleep -Seconds $PollSeconds
        }
        $result.revisionAfter = $status.revision
        $result.egress = $status.egress
        $result.vpn = $status.vpn
        if (Test-AiGatewayHealthy -Status $status) {
            $result.status = 'restarted'
        } else {
            $result.status = 'degraded'
            $result.message += "AI egress did not return to the VPN pool within $TimeoutSeconds seconds (service=$($status.service), egress=$($status.egress), vpn=$($status.vpn))."
            $exitCode = 1
        }
    }
} catch {
    $result.status = 'failed'
    $result.message += $_.Exception.Message
    $exitCode = 1
}
$result.seconds = [int]$watch.Elapsed.TotalSeconds
$result.message = ([string]$result.message).Trim()
[Console]::Out.WriteLine(([pscustomobject]$result | ConvertTo-Json -Compress))
exit $exitCode
