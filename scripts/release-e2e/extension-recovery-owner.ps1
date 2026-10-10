# Adapters for the existing Release runner/checkpoint and snapshot owner.
# This file owns no additional journal, lease, installed action or stage result.

function Get-E2EExtensionWriteSet {
    param([Parameter(Mandatory = $true)][string]$ExtensionName)
    $prefix = "src/cfe/$ExtensionName/"
    return @(@(
        'ConfigDumpInfo.xml', 'Configuration.xml', 'Languages/Русский.xml',
        'DataProcessors/ITLReleaseSmokeProcessor.xml',
        'DataProcessors/ITLReleaseSmokeProcessor/Ext/ManagerModule.bsl',
        'DataProcessors/ITLReleaseSmokeProcessor/Ext/ObjectModule.bsl',
        'DataProcessors/ITLReleaseSmokeProcessor/Forms/MainForm.xml',
        'DataProcessors/ITLReleaseSmokeProcessor/Forms/MainForm/Ext/Form.xml',
        'DataProcessors/ITLReleaseSmokeProcessor/Forms/MainForm/Ext/Form/Module.bsl',
        'DataProcessors/ITLReleaseSmokeProcessor/Templates/SmokeTemplate.xml',
        'DataProcessors/ITLReleaseSmokeProcessor/Templates/SmokeTemplate/Ext/Template.txt',
        'Reports/ITLReleaseSmokeReport.xml',
        'Reports/ITLReleaseSmokeReport/Ext/ManagerModule.bsl',
        'Reports/ITLReleaseSmokeReport/Ext/ObjectModule.bsl',
        'Reports/ITLReleaseSmokeReport/Templates/MainDataCompositionSchema.xml',
        'Reports/ITLReleaseSmokeReport/Templates/MainDataCompositionSchema/Ext/Template.xml'
    ) | ForEach-Object { $prefix + $_ })
}

function Get-E2EExtensionRecoveryContext {
    param([Parameter(Mandatory = $true)][object]$Record)
    $state = (Get-E2EState).value
    $common = (& git -C $worktreePath rev-parse --git-common-dir).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $common) { throw 'Release recovery common Git identity is unavailable.' }
    if (-not [IO.Path]::IsPathRooted($common)) { $common = Join-Path $worktreePath $common }
    return [ordered]@{
        projectRoot = $ProjectRoot; worktreePath = $worktreePath
        commonGitPath = [IO.Path]::GetFullPath($common)
        branch = $branch; expectedHead = [string]$Record.expectedHead
        checkpointPath = $checkpointPath; runId = [string]$Record.runId
        infoBaseKind = [string]$state.infoBaseKind
        infoBasePath = [string]$state.devBranchInfoBasePath
    }
}

function Save-E2EExtensionRuntimeFiles {
    param([Parameter(Mandatory = $true)][object]$Ownership)
    $Ownership['runtimeFiles'] = Get-ReleaseExtensionRecoveryRuntimeFiles -Checkpoint $checkpoint -Context (Get-E2EExtensionRecoveryContext -Record $checkpoint)
}

function Assert-E2EExtensionRecoveryCompatibility {
    param([Parameter(Mandatory = $true)][object]$Record, [AllowNull()][object]$Ownership)
    $identity = $Record.identity
    if (-not (Test-E2ETextSha256Compatible -Path $HelperPath -ExpectedSha256 ([string]$identity.helperSha256)) -or
        (Get-E2EFileSha256 -Path (Join-Path $worktreePath '.agent-1c/project.json')) -cne [string]$identity.projectConfigSha256 -or
        (Get-SourceE2EClientIdentity -ProjectRoot $ProjectRoot -AgentTarget $AgentTarget) -cne [string]$identity.clientSelection) {
        throw 'RELEASE_EXTENSION_RECOVERY_COMPATIBILITY: helper, project or client selection changed.'
    }
    $forkCommit = (& git -C $AiRulesSource rev-parse HEAD).Trim()
    $forkTree = (& git -C $AiRulesSource rev-parse 'HEAD^{tree}').Trim()
    if ($LASTEXITCODE -ne 0 -or $forkCommit -cne [string]$identity.aiRulesCommit -or $forkTree -cne [string]$identity.aiRulesTree) {
        throw 'RELEASE_EXTENSION_RECOVERY_COMPATIBILITY: controlled fork changed.'
    }
    # PSScriptRoot belongs to this adapter, not to the runner.
    $sourceRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $sourceCommit = (& git -C $sourceRoot rev-parse HEAD).Trim()
    $sourceTree = (& git -C $sourceRoot rev-parse 'HEAD^{tree}').Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Release recovery source identity is unavailable.' }
    if ($sourceCommit -cne [string]$identity.workflowCommit -and
        -not (Get-WorkflowContinuationProof -RepositoryRoot $sourceRoot -QualifiedCommit ([string]$identity.workflowCommit) -CurrentCommit $sourceCommit -CurrentTree $sourceTree)) {
        throw 'RELEASE_EXTENSION_RECOVERY_COMPATIBILITY: source continuation is not qualified.'
    }
    # The stateless recovery contract is the single owner of sealed runtime
    # state/env path and hash validation before any restoration.
}

function Assert-E2EExtensionTargetQuiescent {
    param([Parameter(Mandatory = $true)][object]$Context)
    if ([string]$Context.infoBaseKind -ne 'file') { throw 'Release extension recovery requires its exact file stand.' }
    $target = ([IO.Path]::GetFullPath([string]$Context.infoBasePath)).TrimEnd('\', '/')
    if (-not (Get-Command Test-DesignerInfoBaseReleased -ErrorAction SilentlyContinue) -or
        -not (Get-Command Test-OneCCommandLineInfoBasePath -ErrorAction SilentlyContinue)) {
        $libraryRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) '.agents/skills/1c-workflow/scripts/lib'
        . (Join-Path $libraryRoot 'agent-1c.core.ps1')
        . (Join-Path $libraryRoot 'agent-1c.sessions.ps1')
    }
    # A failed inventory is unknown, never an empty/closed native writer proof.
    foreach ($native in @(Get-CimInstance Win32_Process -Filter "Name='1cv8.exe' OR Name='1cv8c.exe'" -ErrorAction Stop)) {
        if (Test-OneCCommandLineInfoBasePath -CommandLine ([string]$native.CommandLine) -InfoBaseKind 'file' -InfoBasePath $target) {
            throw "Release recovery target still has native activity (PID $($native.ProcessId))."
        }
    }
    if (-not (Test-DesignerInfoBaseReleased -InfoBaseKind 'file' -InfoBasePath $target)) {
        throw 'Release recovery exact database has not been released; native quiescence is unknown.'
    }
}

function Get-E2EAbandonedExtensionStopEvidence {
    param([Parameter(Mandatory = $true)][object]$Context, [Parameter(Mandatory = $true)][object]$Ownership)
    $invocation = $Ownership.invocation
    if ($null -eq $invocation -or [int]$invocation.childProcessId -le 0) { throw 'Release extension invocation was not persisted.' }
    $originalCreation = [DateTimeOffset]::Parse([string]$invocation.childStartedAtUtc).UtcDateTime
    $child = Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$invocation.childProcessId)" -ErrorAction Stop
    if ($null -ne $child) {
        if ($null -eq $child.CreationDate) { throw 'Release extension child creation identity is unavailable.' }
        if ([Math]::Abs(($child.CreationDate.ToUniversalTime() - $originalCreation).TotalMilliseconds) -lt 1) {
            throw 'Release extension child is still active; recovery cannot take its files.'
        }
    }
    Assert-E2EExtensionTargetQuiescent -Context $Context
    $record = [ordered]@{}
    foreach ($name in @('runId', 'projectRoot', 'worktreePath', 'branch', 'infoBaseKind', 'infoBasePath')) { $record[$name] = [string]$Context[$name] }
    $record.action = 'release-e2e-extension-smoke'
    $record.childProcessId = [int]$invocation.childProcessId
    $record.childStartedAtUtc = [string]$invocation.childStartedAtUtc
    $record.launcherExited = $true; $record.nativeQuiescent = $true
    $record.checkedAtUtc = [DateTime]::UtcNow.ToString('o')
    $path = Join-Path $releaseRunRoot ('extension-stop-' + [guid]::NewGuid().ToString('N') + '.json')
    [IO.File]::WriteAllText($path, ($record | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    $record.evidencePath = $path; $record.evidenceSha256 = Get-E2EFileSha256 -Path $path
    return $record
}

function Get-E2EExtensionStopEvidence {
    param([Parameter(Mandatory = $true)][object]$Context, [Parameter(Mandatory = $true)][object]$Invocation)
    if (-not [bool]$Invocation.nativeQuiescent -or $null -eq $Invocation.exitedAtUtc) {
        throw 'Release extension child/native job has not been proven stopped.'
    }
    Assert-E2EExtensionTargetQuiescent -Context $Context
    $record = [ordered]@{
        runId = [string]$Context.runId; projectRoot = [string]$Context.projectRoot
        worktreePath = [string]$Context.worktreePath; branch = [string]$Context.branch
        infoBaseKind = [string]$Context.infoBaseKind; infoBasePath = [string]$Context.infoBasePath
        action = 'release-e2e-extension-smoke'; childProcessId = [int]$Invocation.process.Id
        childStartedAtUtc = $Invocation.startedAtUtc.ToString('o')
        launcherExited = $true; nativeQuiescent = $true
        checkedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    $path = Join-Path $releaseRunRoot ('extension-stop-' + [guid]::NewGuid().ToString('N') + '.json')
    [IO.File]::WriteAllText($path, ($record | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    $record.evidencePath = $path
    $record.evidenceSha256 = Get-E2EFileSha256 -Path $path
    return $record
}

function Invoke-E2EInterruptedExtensionRecovery {
    if (-not (Test-Path -LiteralPath $checkpointPath -PathType Leaf)) { return }
    $script:checkpoint = ConvertTo-E2EHashtable (Get-Content -LiteralPath $checkpointPath -Raw -Encoding UTF8 | ConvertFrom-Json)
    if (-not $checkpoint.Contains('extensionRecovery') -or [string]$checkpoint.extensionRecovery.status -in @('recovered', 'completed')) { return }
    $context = Get-E2EExtensionRecoveryContext -Record $checkpoint
    $compatibility = { param($ctx, $record, $owned) Assert-E2EExtensionRecoveryCompatibility -Record $record -Ownership $owned }
    if ([string]$checkpoint.extensionRecovery.status -eq 'declared') {
        $checkpoint['extensionRecovery'] = Complete-ReleaseExtensionRecoveryOwnership -Ownership $checkpoint.extensionRecovery `
            -Checkpoint $checkpoint -Context $context -AssertCompatibility $compatibility `
            -GetStopEvidence { param($ctx, $owned) Get-E2EAbandonedExtensionStopEvidence -Context $ctx -Ownership $owned }
        Write-E2ECheckpoint
    }
    $ownership = Resolve-ReleaseExtensionRecoveryOwnership -Checkpoint $checkpoint -Context $context -AssertCompatibility $compatibility
    $stop = {
        if ($null -ne (Get-ReleaseExtensionRecoveryValue $ownership 'approvedLegacyManifest') -and $null -ne (Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$ownership.invocation.childProcessId)" -ErrorAction Stop)) {
            throw 'Legacy child PID is present; its unavailable creation identity cannot be inferred.'
        }
        Assert-E2EExtensionTargetQuiescent -Context $context
        return $ownership.stopEvidence
    }
    $restore = {
        $script:inExtensionRecovery = $true
        $script:lastRecoveryRestoreInvocation = $null
        try { Restore-E2EInfobaseSnapshot -Snapshot $checkpoint.snapshots.postConfig -StateFiles $checkpoint.stateFiles.postConfig }
        finally {
            # The same snapshot may be replayed after an uncertain restore ACK.
            # This records observed owner output without claiming native success.
            if ($null -ne $script:lastRecoveryRestoreInvocation -and $script:lastRecoveryRestoreInvocation.nativeQuiescent) {
                Save-E2EExtensionRuntimeFiles -Ownership $ownership
                Write-E2ECheckpoint
            }
            $script:inExtensionRecovery = $false
        }
    }
    $result = Invoke-ReleaseExtensionRecovery -Checkpoint $checkpoint -Context $context -Ownership $ownership `
        -ArchiveRoot (Join-Path $worktreePath ('.agent-1c/runs/release-extension-recovery/' + $context.runId)) `
        -AssertCompatibility $compatibility -GetStopEvidence $stop -RestoreSnapshot $restore
    $ownership['status'] = 'recovered'
    $ownership['recoveryResult'] = $result
    Write-E2ECheckpoint
    return $result
}
