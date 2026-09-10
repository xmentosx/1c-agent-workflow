param([Parameter(Mandatory = $true)][string]$ContextPath)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$OutputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $OutputEncoding
$context = Get-Content -LiteralPath $ContextPath -Raw -Encoding UTF8 | ConvertFrom-Json
$expectedNames = @('agent-1c.core.ps1','agent-1c.runtime-values.ps1','agent-1c.sessions.ps1','agent-1c.vanessa.ps1')
if (@($context.helpers.files).Count -eq 5) { $expectedNames += 'agent-1c.ports.ps1' }
if ($context.schemaVersion -ne 1 -or $context.observationId -cnotmatch '^[a-f0-9]{32}$' -or
    @($context.helpers.files).Count -ne $expectedNames.Count -or $null -eq $context.serverInspectors) {
    throw 'NATIVE_RECOVERY_INSPECTION_CONTEXT_INVALID'
}
foreach ($name in $expectedNames) {
    $matches = @($context.helpers.files | Where-Object { [IO.Path]::GetFileName($_.path) -ceq $name })
    if ($matches.Count -ne 1 -or (Get-FileHash -LiteralPath $matches[0].path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $matches[0].sha256) {
        throw 'NATIVE_RECOVERY_HELPER_ARCHIVE_CHANGED'
    }
    . $matches[0].path
}
Initialize-OneCNativeRecoveryContext -ProjectRoot $context.project
$serverInspectors = @{}
foreach ($inspector in @($context.serverInspectors)) {
    if ($inspector.kind -cne 'server' -or [string]::IsNullOrWhiteSpace($inspector.path) -or
        -not [IO.Path]::IsPathRooted([string]$inspector.project) -or $inspector.provider.schemaVersion -ne 1 -or
        $inspector.provider.capability -cne 'recovery-observe' -or -not [IO.Path]::IsPathRooted([string]$inspector.provider.path) -or
        $inspector.provider.sha256 -cnotmatch '^[a-f0-9]{64}$') { throw 'NATIVE_RECOVERY_SERVER_INSPECTOR_INVALID' }
    $identity = Get-OneCInfoBaseIdentity -InfoBaseKind server -InfoBasePath $inspector.path
    if ($serverInspectors.ContainsKey($identity.key)) { throw 'NATIVE_RECOVERY_SERVER_INSPECTOR_AMBIGUOUS' }
    $providerItem = Get-Item -LiteralPath $inspector.provider.path -Force -ErrorAction Stop
    if ($providerItem.PSIsContainer -or ($providerItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
        (Get-FileHash -LiteralPath $inspector.provider.path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $inspector.provider.sha256) {
        throw 'NATIVE_RECOVERY_SERVER_INSPECTOR_CHANGED'
    }
    $serverInspectors[$identity.key] = $inspector
}
$observations = @()
foreach ($sample in 1..2) {
    $inventory = @(Get-OneCProcessInfo -RequireSuccess)
    if (@($inventory | Where-Object { [string]::IsNullOrWhiteSpace($_.commandLine) }).Count) {
        throw 'NATIVE_RECOVERY_PROCESS_COMMAND_LINE_UNAVAILABLE'
    }
    $resources = @()
    foreach ($base in $context.resources) {
        $matching = @($inventory | Where-Object {
            Test-OneCCommandLineInfoBasePath -CommandLine $_.commandLine -InfoBaseKind $base.kind -InfoBasePath $base.path
        })
        $owned = @($matching | Where-Object { Test-OneCNativeProcessInRunScopes -ProcessInfo $_ -Scopes @($context.scopes) })
        if ($base.kind -ceq 'file') {
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
            continue
        }
        if ($base.kind -cne 'server') { throw 'NATIVE_RECOVERY_INSPECTION_CONTEXT_INVALID' }
        $identity = Get-OneCInfoBaseIdentity -InfoBaseKind server -InfoBasePath $base.path
        if (-not $serverInspectors.ContainsKey($identity.key)) { throw 'NATIVE_RECOVERY_SERVER_INSPECTOR_REQUIRED' }
        $inspector = $serverInspectors[$identity.key]
        if ((Get-FileHash -LiteralPath $inspector.provider.path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $inspector.provider.sha256) {
            throw 'NATIVE_RECOVERY_SERVER_INSPECTOR_CHANGED'
        }
        $providerOutput = @(& (Join-Path $PSHOME 'powershell.exe') -NoProfile -NonInteractive -ExecutionPolicy Bypass `
            -File $inspector.provider.path -Operation recovery-observe -ProjectRoot $inspector.project `
            -InfoBasePath $base.path -ObservationId $context.observationId -Sample $sample 2>&1)
        if ($LASTEXITCODE -ne 0) { throw ('NATIVE_RECOVERY_SERVER_INSPECTION_FAILED: exitCode=' + $LASTEXITCODE) }
        try { $server = ($providerOutput -join [Environment]::NewLine) | ConvertFrom-Json }
        catch { throw ('NATIVE_RECOVERY_SERVER_INSPECTION_INVALID: ' + $_.Exception.Message) }
        $properties = @($server.PSObject.Properties.Name | Sort-Object)
        $serverSessionCount = 0
        if ($properties -join ',' -cne 'databasePresent,exclusive,infoBase,observationId,schemaVersion,sessionCount' -or
            $server.schemaVersion -ne 1 -or $server.observationId -cne $context.observationId -or
            $server.infoBase.kind -cne 'server' -or
            -not (Test-ItlOnDemandInfoBaseMatch -First $server.infoBase.path -Second $base.path) -or
            $server.databasePresent -isnot [bool] -or $server.exclusive -isnot [bool] -or
            -not [int]::TryParse([string]$server.sessionCount, [ref]$serverSessionCount) -or $serverSessionCount -lt 0 -or
            $server.exclusive -ne ($serverSessionCount -eq 0)) {
            throw 'NATIVE_RECOVERY_SERVER_INSPECTION_INVALID'
        }
        if ((Get-FileHash -LiteralPath $inspector.provider.path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $inspector.provider.sha256) {
            throw 'NATIVE_RECOVERY_SERVER_INSPECTOR_CHANGED'
        }
        $resources += [pscustomobject]@{kind='server';path=$base.path;databasePresent=[bool]$server.databasePresent
            directoryPresent=[bool]$server.databasePresent;exclusive=[bool]$server.exclusive;sessionCount=$serverSessionCount
            ownedProcessIds=@($owned | ForEach-Object { $_.processId })
            otherProcessIds=@($matching | Where-Object { $_.processId -notin @($owned | ForEach-Object { $_.processId }) } | ForEach-Object { $_.processId })}
    }
    $observations += [pscustomobject]@{observedAtUtc=[DateTime]::UtcNow.ToString('o');resources=$resources}
    if ($sample -eq 1) { Start-Sleep -Milliseconds 1000 }
}
[pscustomobject]@{schemaVersion=1;observationId=$context.observationId;host=[Environment]::MachineName;samples=$observations} | ConvertTo-Json -Depth 12 -Compress
