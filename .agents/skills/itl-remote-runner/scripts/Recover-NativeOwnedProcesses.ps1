param([Parameter(Mandatory = $true)][string]$ContextPath)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$OutputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $OutputEncoding
$context = Get-Content -LiteralPath $ContextPath -Raw -Encoding UTF8 | ConvertFrom-Json
$expectedNames = @('agent-1c.core.ps1','agent-1c.runtime-values.ps1','agent-1c.sessions.ps1','agent-1c.vanessa.ps1')
if (@($context.helpers.files).Count -eq 5) { $expectedNames += 'agent-1c.ports.ps1' }
if ($context.schemaVersion -ne 1 -or $context.cleanupId -cnotmatch '^[a-f0-9]{32}$' -or
    @($context.helpers.files).Count -ne $expectedNames.Count -or @($context.expectedProcesses).Count -eq 0) {
    throw 'NATIVE_RECOVERY_CLEANUP_CONTEXT_INVALID'
}
foreach ($name in $expectedNames) {
    $matches = @($context.helpers.files | Where-Object { [IO.Path]::GetFileName($_.path) -ceq $name })
    if ($matches.Count -ne 1 -or
        (Get-FileHash -LiteralPath $matches[0].path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $matches[0].sha256) {
        throw 'NATIVE_RECOVERY_HELPER_ARCHIVE_CHANGED'
    }
    . $matches[0].path
}
Initialize-OneCNativeRecoveryContext -ProjectRoot $context.project
$expected = @{}
foreach ($item in @($context.expectedProcesses)) {
    $pidValue = [int]$item.pid
    if ($pidValue -le 0 -or $expected.ContainsKey($pidValue) -or
        [string]::IsNullOrWhiteSpace([string]$item.processStartTime) -or
        [string]::IsNullOrWhiteSpace([string]$item.name) -or
        [string]::IsNullOrWhiteSpace([string]$item.executablePath)) {
        throw 'NATIVE_RECOVERY_CLEANUP_PROCESS_IDENTITY_INVALID'
    }
    $start = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string]$item.processStartTime,[ref]$start)) {
        throw 'NATIVE_RECOVERY_CLEANUP_PROCESS_IDENTITY_INVALID'
    }
    $expected[$pidValue] = [pscustomobject]@{
        pid=$pidValue; processStartTime=$start.UtcDateTime; name=[string]$item.name; executablePath=[IO.Path]::GetFullPath([string]$item.executablePath)
    }
}
$inventory = @(Get-OneCProcessInfo -RequireSuccess)
if (@($inventory | Where-Object { [string]::IsNullOrWhiteSpace($_.commandLine) }).Count) {
    throw 'NATIVE_RECOVERY_PROCESS_COMMAND_LINE_UNAVAILABLE'
}
$candidates = @($inventory | Where-Object {
    Test-OneCNativeProcessInRunScopes -ProcessInfo $_ -Scopes @($context.scopes)
})
if (@($candidates | Where-Object { -not $expected.ContainsKey([int]$_.processId) }).Count) {
    throw 'NATIVE_RECOVERY_OWNED_PROCESS_SET_CHANGED'
}
$verified = @()
foreach ($processInfo in $candidates) {
    $pidValue = [int]$processInfo.processId
    $proof = $expected[$pidValue]
    $actualStart = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string]$processInfo.processStartTime,[ref]$actualStart) -or
        [Math]::Abs(($actualStart.UtcDateTime - [DateTime]$proof.processStartTime).TotalSeconds) -ge 2 -or
        -not [string]::Equals([string]$processInfo.name,[string]$proof.name,[StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([IO.Path]::GetFullPath([string]$processInfo.executablePath),[string]$proof.executablePath,[StringComparison]::OrdinalIgnoreCase)) {
        throw "NATIVE_RECOVERY_OWNED_PROCESS_IDENTITY_CHANGED pid=$pidValue"
    }
    $verified += $processInfo
}
$stopped = @()
foreach ($processInfo in $verified) {
    Stop-Process -Id ([int]$processInfo.processId) -Force -ErrorAction Stop
    $stopped += [int]$processInfo.processId
}
foreach ($pidValue in $stopped) {
    $deadline = (Get-Date).AddSeconds(15)
    while ($null -ne (Get-Process -Id $pidValue -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 100
    }
    if ($null -ne (Get-Process -Id $pidValue -ErrorAction SilentlyContinue)) {
        throw "NATIVE_RECOVERY_OWNED_PROCESS_STOP_FAILED pid=$pidValue"
    }
}
$after = @(Get-OneCProcessInfo -RequireSuccess | Where-Object {
    Test-OneCNativeProcessInRunScopes -ProcessInfo $_ -Scopes @($context.scopes)
})
if ($after.Count) {
    throw "NATIVE_RECOVERY_OWNED_PROCESS_CLEANUP_UNCONFIRMED pids='$(@($after.processId) -join ',')'"
}
[pscustomobject]@{
    schemaVersion=1
    cleanupId=$context.cleanupId
    host=[Environment]::MachineName
    stoppedProcessIds=@($stopped)
    remainingOwnedProcessIds=@()
} | ConvertTo-Json -Depth 6 -Compress
