param([Parameter(Mandatory = $true)][string]$ContextPath)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$OutputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $OutputEncoding
$context = Get-Content -LiteralPath $ContextPath -Raw -Encoding UTF8 | ConvertFrom-Json
$expectedNames = @('agent-1c.core.ps1','agent-1c.runtime-values.ps1','agent-1c.sessions.ps1','agent-1c.vanessa.ps1')
if (@($context.helpers.files).Count -eq 5) { $expectedNames += 'agent-1c.ports.ps1' }
if ($context.schemaVersion -ne 1 -or $context.observationId -cnotmatch '^[a-f0-9]{32}$' -or
    @($context.helpers.files).Count -ne $expectedNames.Count) { throw 'NATIVE_RECOVERY_INSPECTION_CONTEXT_INVALID' }
foreach ($name in $expectedNames) {
    $matches = @($context.helpers.files | Where-Object { [IO.Path]::GetFileName($_.path) -ceq $name })
    if ($matches.Count -ne 1 -or (Get-FileHash -LiteralPath $matches[0].path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $matches[0].sha256) {
        throw 'NATIVE_RECOVERY_HELPER_ARCHIVE_CHANGED'
    }
    . $matches[0].path
}
Initialize-OneCNativeRecoveryContext -ProjectRoot $context.project
$observations = @()
foreach ($sample in 1..2) {
    $inventory = @(Get-OneCProcessInfo -RequireSuccess)
    if (@($inventory | Where-Object { [string]::IsNullOrWhiteSpace($_.commandLine) }).Count) {
        throw 'NATIVE_RECOVERY_PROCESS_COMMAND_LINE_UNAVAILABLE'
    }
    $resources = @()
    foreach ($base in $context.resources) {
        if ($base.kind -cne 'file') { throw 'NATIVE_RECOVERY_SERVER_INSPECTION_REQUIRED' }
        $matching = @($inventory | Where-Object {
            Test-OneCCommandLineInfoBasePath -CommandLine $_.commandLine -InfoBaseKind $base.kind -InfoBasePath $base.path
        })
        $owned = @($matching | Where-Object { Test-OneCNativeProcessInRunScopes -ProcessInfo $_ -Scopes @($context.scopes) })
        $databasePath = Join-Path $base.path '1Cv8.1CD'
        $exclusive = $false; $lease = $null
        try {
            if (Test-Path -LiteralPath $databasePath -PathType Leaf) {
                $lease = [IO.File]::Open($databasePath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
                $exclusive = $true
            }
        } catch [IO.IOException] { $exclusive = $false }
        finally { if ($null -ne $lease) { $lease.Dispose() } }
        $resources += [pscustomobject]@{kind=$base.kind;path=$base.path;databasePresent=(Test-Path -LiteralPath $databasePath -PathType Leaf)
            directoryPresent=(Test-Path -LiteralPath $base.path)
            exclusive=$exclusive;sessionCount=$matching.Count;ownedProcessIds=@($owned | ForEach-Object { $_.processId })
            otherProcessIds=@($matching | Where-Object { $_.processId -notin @($owned | ForEach-Object { $_.processId }) } | ForEach-Object { $_.processId })}
    }
    $observations += [pscustomobject]@{observedAtUtc=[DateTime]::UtcNow.ToString('o');resources=$resources}
    if ($sample -eq 1) { Start-Sleep -Milliseconds 1000 }
}
[pscustomobject]@{schemaVersion=1;observationId=$context.observationId;host=[Environment]::MachineName;samples=$observations} | ConvertTo-Json -Depth 12 -Compress
