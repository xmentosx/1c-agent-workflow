param([Parameter(Mandatory = $true)][string]$ContextPath)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$OutputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $OutputEncoding
$context = Get-Content -LiteralPath $ContextPath -Raw -Encoding UTF8 | ConvertFrom-Json
$privateProof = [Console]::In.ReadLine() | ConvertFrom-Json
if ($context.schemaVersion -ne 1 -or $context.restoreId -cnotmatch '^[a-f0-9]{32}$' -or
    $privateProof.purpose -cne 'recovery' -or $privateProof.ticket -cne $context.duty.ticket) {
    throw 'NATIVE_RECOVERY_RESTORE_CONTEXT_INVALID'
}
$expectedNames = @('agent-1c.core.ps1','agent-1c.runtime-values.ps1','agent-1c.sessions.ps1','agent-1c.vanessa.ps1','agent-1c.ports.ps1')
if (@($context.helpers.files).Count -ne $expectedNames.Count) { throw 'NATIVE_RECOVERY_HELPER_ARCHIVE_CHANGED' }
foreach ($name in $expectedNames) {
    $matches = @($context.helpers.files | Where-Object { [IO.Path]::GetFileName($_.path) -ceq $name })
    if ($matches.Count -ne 1 -or (Get-FileHash -LiteralPath $matches[0].path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $matches[0].sha256) {
        throw 'NATIVE_RECOVERY_HELPER_ARCHIVE_CHANGED'
    }
    . $matches[0].path
}
if ((Get-FileHash -LiteralPath $context.bridge.path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $context.bridge.sha256) {
    throw 'NATIVE_RECOVERY_DATABASE_BRIDGE_CHANGED'
}
$pinned = [Collections.Generic.List[object]]::new()
$owner = $null
try {
    # Hold the original DT and context files read-only throughout native restore.
    foreach ($artifact in @(@{path=$context.duty.snapshotPath;sha256=$context.duty.snapshotSha256},
            $context.duty.recoveryContext)) {
        $pinned.Add([IO.File]::Open($artifact.path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read))
        if ((Get-FileHash -LiteralPath $artifact.path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $artifact.sha256) { throw 'RESTORATION_CONTEXT_ARTIFACT_CHANGED' }
    }
    $manifest = Get-Content -LiteralPath $context.duty.recoveryContext.path -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($artifact in @($manifest.state,$manifest.configuration,$manifest.environment)) {
        if (-not $artifact.snapshotPath) { continue }
        $pinned.Add([IO.File]::Open($artifact.snapshotPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read))
        if ((Get-FileHash -LiteralPath $artifact.snapshotPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $artifact.sha256) { throw 'RESTORATION_CONTEXT_ARTIFACT_CHANGED' }
    }
    if ((Get-FileHash -LiteralPath $manifest.platform.path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $manifest.platform.sha256) { throw 'RESTORATION_CONTEXT_ARTIFACT_CHANGED' }
    $configuration = Get-Content -LiteralPath $manifest.configuration.snapshotPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $configuration | Add-Member -NotePropertyName logsPath -NotePropertyValue $context.output -Force
    Initialize-OneCNativeRecoveryContext -ProjectRoot $context.duty.project -Configuration $configuration -DatabaseAccessBridgePath $context.bridge.path
    # Credentials come from the captured environment, not the new caller's DB.
    foreach ($name in @('IB_USER','IB_PASSWORD','AGENT_1C_IB_USER','AGENT_1C_IB_PASSWORD')) {
        [Environment]::SetEnvironmentVariable($name,$null,'Process')
    }
    if ($manifest.environment.existed) { Import-DotEnv -Path $manifest.environment.snapshotPath -Overwrite }
    [Environment]::SetEnvironmentVariable('PLATFORM_PATH',$manifest.platform.path,'Process')
    . $context.bridge.path
    $request = @{schemaVersion=1;coordinator=$privateProof.coordinator;bases=@($context.duty.resources);timeout=0
        inherited=$privateProof;purpose='recovery';nativeJournalProtocol=1
        owner=@{operation='workflow-native-restore';project=$context.duty.project}}
    $owner = Start-ItlDatabaseAccessHost -Request $request -Python $context.python
    $privateProof = $null
    $script:OneCNativeOperationJournal = New-OneCNativeOperationJournal -Resources @($context.duty.resources) -Owner $owner
    $state = [pscustomobject]@{infoBaseKind=$context.duty.infoBase.kind;devBranchInfoBasePath=$context.duty.infoBase.path}
    $duty = Register-OneCDatabaseRestorationDuty -State $state -SnapshotPath $context.duty.snapshotPath -RecoveryContext $context.duty.recoveryContext
    Invoke-Designer -InfoBaseKind $state.infoBaseKind -InfoBasePath $state.devBranchInfoBasePath -DesignerArgs @('/RestoreIB',$context.duty.snapshotPath) -RestorationDuty $duty | Out-Null
    Complete-OneCDatabaseRestorationDuty -Duty $duty
    $release = Complete-ItlDatabaseAccessHost -Owner $owner
    if ($release.status -cne 'released' -or -not $release.inherited) { throw 'NATIVE_RECOVERY_RESTORE_PARTICIPANT_UNCONFIRMED' }
    $result = [ordered]@{schemaVersion=1;restoreId=$context.restoreId;originalDuty=($context.duty.journalId+'/'+$context.duty.id)
        restoredDuty=($duty.payload.journalId+'/'+$duty.payload.id);restoreOperation=$duty.payload.restoreOperation
        snapshotSha256=$duty.payload.snapshotSha256;infoBase=$duty.payload.infoBase;host=[Environment]::MachineName}
    [IO.File]::WriteAllText((Join-Path $context.output ($context.restoreId+'.result.json')),($result | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
} finally {
    if ($null -ne $owner -and -not $owner.closed) { Close-ItlDatabaseAccessHost -Owner $owner }
    foreach ($stream in $pinned) { $stream.Dispose() }
}
