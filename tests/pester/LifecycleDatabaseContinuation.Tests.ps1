Describe 'Lifecycle database admission survives a fresh helper process' {
    BeforeAll {
        Set-StrictMode -Version Latest
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        . $context.HelperPath -ProjectRoot $context.RepoRoot -Action help *> $null
        . (Join-Path $context.RepoRoot '.agents/skills/itl-remote-runner/scripts/DatabaseAccess.ps1')
        $python = (Get-Command python -CommandType Application | Select-Object -First 1).Source
    }
    BeforeEach {
        $script:ProjectRoot = Join-Path $TestDrive ('Передача общей базы ' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:ProjectRoot | Out-Null
        $script:DevBranchName = 'continuation'
        $script:DevBranchMutationDatabaseAdmission = $null
        $script:OneCNativeOperationJournal = $null
        $script:DatabaseContinuationProtocol = 0
        $script:OperationContinuation = $false
        $savedProof = [Environment]::GetEnvironmentVariable('ITL_INFOBASE_ACCESS_LEASE', 'Process')
        $savedContinuation = [Environment]::GetEnvironmentVariable('ITL_DATABASE_CONTINUATION', 'Process')
        [Environment]::SetEnvironmentVariable('ITL_INFOBASE_ACCESS_LEASE', $null, 'Process')
        [Environment]::SetEnvironmentVariable('ITL_DATABASE_CONTINUATION', $null, 'Process')
        $script:continuationState = [pscustomobject]@{infoBaseKind='file';devBranchName='continuation';devBranchInfoBasePath=(Join-Path $script:ProjectRoot 'Целевая база')}
        $script:continuationSettings = [pscustomobject]@{coordinator=(Join-Path $script:ProjectRoot 'Общая очередь');python=$python;waitTimeoutSeconds=0}
        $script:continuationTemplate = [pscustomobject]@{path=(Join-Path $script:ProjectRoot 'Исходный шаблон.dt');sha256=('1'*64);user='Runner';password=''}
        Mock Read-DevBranchState { $script:continuationState }
        Mock Assert-DevelopmentBranchWorktreeContext {}
        Mock Get-ItlDatabaseAccessSettings { $script:continuationSettings }
        Mock Get-ItlOnDemandRuntimeInstances { @() }
        Mock Get-VanessaServiceInfoBaseTemplate { $script:continuationTemplate }
        Mock Read-VanessaTestClientManifest { throw 'reset and refresh must not execute test profiles' }
        Mock Invoke-Designer { throw 'this protocol fixture does not launch 1C' }
    }
    AfterEach {
        try { Complete-ItlDevBranchMutationDatabaseAdmission $script:DevBranchMutationDatabaseAdmission }
        finally {
            [Environment]::SetEnvironmentVariable('ITL_INFOBASE_ACCESS_LEASE', $savedProof, 'Process')
            [Environment]::SetEnvironmentVariable('ITL_DATABASE_CONTINUATION', $savedContinuation, 'Process')
            $script:DatabaseContinuationProtocol = 0
            $script:OperationContinuation = $false
        }
    }

    It 'records reset phases through the real owner pipe and preserves the original inputs' {
        Mock Get-MainWorktreePath { $script:ProjectRoot }
        $script:DevBranchMutationDatabaseAdmission = Start-ItlDevBranchMutationDatabaseAdmission -Operation reset-dev-branch
        $admission = $script:DevBranchMutationDatabaseAdmission
        $archive = Join-Path $script:ProjectRoot '.agent-1c/branch-archives/continuation/Исходный архив'
        New-Item -ItemType Directory -Path $archive -Force | Out-Null
        $manifestPath = Join-Path $archive 'manifest.json'
        [IO.File]::WriteAllText($manifestPath, '{"fixture":"original archive"}')
        $seed = [pscustomobject]@{schemaVersion=1;sourceKey='source';syncId='original';artifactKind='file-1cd'
            artifactPath=(Join-Path $script:ProjectRoot 'Исходный seed/1Cv8.1CD');artifactSha256=('a'*64);artifactBytes=123
            configurationFingerprint='original-master';baselinePath=(Join-Path $script:ProjectRoot 'Исходный seed/baseline.json')
            baselineHash='';baselineSha256=('b'*64)}
        $updates = @{devBranch='itldev/continuation';resetOldHead=('1'*40);resetMasterCommit=('2'*40)
            resetMasterTree=('3'*40);resetMasterConfigTreeObjectId=('4'*40);resetMasterFingerprint='original-master'
            resetArchivePath=$archive;resetSeedIdentity=$seed;resetNewHead='';resetPhase='archive-pending'}
        foreach ($entry in $updates.GetEnumerator()) { $continuationState | Add-Member -NotePropertyName $entry.Key -NotePropertyValue $entry.Value -Force }
        $ticketPath = Join-Path $continuationSettings.coordinator ('tickets/' + $admission.owner.proof.ticket + '.json')
        $phases = @('archive-pending','archive-complete','git-reset-complete','runtime-initializing','complete')
        $sequence = 0
        foreach ($phase in $phases) {
            $continuationState.resetPhase = $phase
            if ($phase -eq 'git-reset-complete') { $continuationState.resetNewHead = '5'*40 }
            Publish-DevBranchResetCheckpoint -State $continuationState
            $sequence++
            $ticket = Get-Content -LiteralPath $ticketPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $ticket.status | Should -Be 'running'
            $producer = @($ticket.nativeJournal.producers.PSObject.Properties)[0].Value
            $producer.resetCheckpoints | Should -HaveCount $sequence
            $indexed = $producer.resetCheckpoints[-1]
            $recordPath = Join-Path $continuationSettings.coordinator $indexed.path
            (Get-FileHash -LiteralPath $recordPath -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $indexed.sha256
            $record = Get-Content -LiteralPath $recordPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $record.context.phase | Should -Be $phase
            $record.context.seed.syncId | Should -Be 'original'
            $record.context.masterCommit | Should -Be ('2'*40)
            $record.context.archivePath | Should -Be $archive
            $effective = Get-DevBranchResetRecoveryState -State $continuationState -Context $record.context
            $effective.resetPhase | Should -Be $phase
            if ($phase -ne 'complete') {
                $ahead = $continuationState | ConvertTo-Json -Depth 15 | ConvertFrom-Json
                $ahead.resetPhase = $phases[$sequence]
                if ($ahead.resetPhase -eq 'git-reset-complete') { $ahead.resetNewHead = '5'*40 }
                $effective = Get-DevBranchResetRecoveryState -State $ahead -Context $record.context
                $effective.resetPhase | Should -Be $phase
                $ahead.resetPhase | Should -Be $phases[$sequence]
                $ahead.resetMasterCommit = 'e'*40
                { Get-DevBranchResetRecoveryState -State $ahead -Context $record.context } | Should -Throw '*RECOVERY_INPUT_CHANGED*'
            }
            { Start-ItlDatabaseAccessHost -Python $python -Request @{schemaVersion=1;coordinator=$continuationSettings.coordinator;bases=@($admission.plan.target);owner=@{operation='another-chat'};timeout=0} } | Should -Throw '*WAIT_TIMEOUT*'
        }
        Publish-ItlDevBranchLifecycleCompletion -Admission $admission
        Complete-ItlDevBranchMutationDatabaseAdmission $admission
        $next = Start-ItlDatabaseAccessHost -Python $python -Request @{schemaVersion=1;coordinator=$continuationSettings.coordinator;bases=@($admission.plan.target);owner=@{operation='another-chat'};timeout=0}
        Complete-ItlDatabaseAccessHost $next | Out-Null
        Should -Invoke Invoke-Designer -Times 0
    }

    It 'reserves a replacement before <operation> even when its current manager is reusable' -TestCases @(
        @{operation='reset-dev-branch'}, @{operation='refresh-dev-branch-lite'}
    ) {
        param($operation)
        $generation = 'a'*32
        $servicePath = Get-VanessaServiceInfoBasePath -State $continuationState -Generation $generation
        New-Item -ItemType Directory -Path $servicePath -Force | Out-Null
        [pscustomobject]@{schemaVersion=1;generation=$generation;templateSha256=$continuationTemplate.sha256;serviceUser=$continuationTemplate.user} |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $servicePath '.itl-service-template.json') -Encoding UTF8
        foreach ($entry in @{vanessaServiceInfoBaseSchemaVersion=3;vanessaServiceInfoBaseGeneration=$generation;
            vanessaServiceInfoBaseTemplateSha256=$continuationTemplate.sha256;vanessaServiceInfoBaseUser=$continuationTemplate.user;vanessaServiceInfoBasePath=$servicePath}.GetEnumerator()) {
            $continuationState | Add-Member -NotePropertyName $entry.Key -NotePropertyValue $entry.Value
        }
        $script:DevBranchMutationDatabaseAdmission = Start-ItlDevBranchMutationDatabaseAdmission -Operation $operation
        $admission = $script:DevBranchMutationDatabaseAdmission
        $admission.plan.servicePlan.reuse | Should -BeTrue
        $admission.plan.bases | Should -HaveCount 3
        $admission.plan.serviceReserveGeneration | Should -Not -Be $generation
        $reservedPath = Get-VanessaServiceInfoBasePath -State $continuationState -Generation $admission.plan.serviceReserveGeneration
        $admission.plan.bases.path | Should -Contain $reservedPath
        Test-Path -LiteralPath $reservedPath | Should -BeFalse
        Assert-ItlDevBranchMutationDatabaseAdmission -Admission $admission -State $continuationState
        foreach ($base in $admission.plan.bases) {
            { Start-ItlDatabaseAccessHost -Python $python -Request @{schemaVersion=1;coordinator=$continuationSettings.coordinator;bases=@($base);owner=@{operation='other-chat'};timeout=0} } | Should -Throw '*WAIT_TIMEOUT*'
        }
        Should -Invoke Read-VanessaTestClientManifest -Times 0
        Should -Invoke Invoke-Designer -Times 0
    }

    It 'a fresh helper selects the reserved generation after template drift and retains the outer reservation' {
        $operation = 'refresh-dev-branch-lite'
        $script:DevBranchMutationDatabaseAdmission = Start-ItlDevBranchMutationDatabaseAdmission -Operation $operation
        $admission = $script:DevBranchMutationDatabaseAdmission
        $statePath = Join-Path $script:ProjectRoot 'Состояние продолжения.json'
        $outputPath = Join-Path $script:ProjectRoot 'Результат продолжения.json'
        $continuationState | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8
        $settingsPath = Join-Path $script:ProjectRoot 'Параметры очереди.json'
        $continuationSettings | ConvertTo-Json | Set-Content -LiteralPath $settingsPath -Encoding UTF8
        $childPath = Join-Path $script:ProjectRoot 'Новый помощник.ps1'
        Set-Content -LiteralPath $childPath -Encoding UTF8 -Value @'
param([string]$HelperPath, [string]$RepoRoot, [string]$FixtureRoot, [string]$StatePath, [string]$SettingsPath, [string]$OutputPath)
$ErrorActionPreference = 'Stop'
. $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
$DatabaseContinuationProtocol = 1
$OperationContinuation = $true
$script:ProjectRoot = $FixtureRoot
$script:DevBranchName = 'continuation'
function Read-DevBranchState { Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json }
function Assert-DevelopmentBranchWorktreeContext {}
function Get-ItlDatabaseAccessSettings { Get-Content -LiteralPath $SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json }
function Get-ItlOnDemandRuntimeInstances { @() }
function Get-VanessaServiceInfoBaseTemplate { [pscustomobject]@{path=(Join-Path $FixtureRoot 'Новый шаблон.dt');sha256=('2'*64);user='Runner';password=''} }
$admission = $null
try {
    $admission = Start-ItlDevBranchMutationDatabaseAdmission -Operation refresh-dev-branch-lite
    Assert-ItlDevBranchMutationDatabaseAdmission -Admission $admission -State (Read-DevBranchState)
    Publish-ItlDevBranchLifecycleCompletion -Admission $admission
    [pscustomobject]@{continuation=$admission.continuation;generation=$admission.plan.servicePlan.generation;bases=@($admission.plan.bases)} |
        ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
} finally { Complete-ItlDevBranchMutationDatabaseAdmission $admission }
'@
        [IO.File]::WriteAllText($childPath, [IO.File]::ReadAllText($childPath), [Text.UTF8Encoding]::new($true))
        $result = Invoke-TestPowerShellFile -FilePath $childPath -Arguments @('-HelperPath',$context.HelperPath,'-RepoRoot',$context.RepoRoot,'-FixtureRoot',$script:ProjectRoot,'-StatePath',$statePath,'-SettingsPath',$settingsPath,'-OutputPath',$outputPath)
        $result.exitCode | Should -Be 0 -Because $result.combinedText
        $child = Get-Content -LiteralPath $outputPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $child.generation | Should -Be $admission.plan.serviceReserveGeneration
        $child.continuation.reference.ticket | Should -Be $admission.continuation.reference.ticket
        $child.continuation.reference.producerId | Should -Not -Be $admission.continuation.reference.producerId
        @($child.bases.path | Sort-Object) | Should -Be @($admission.plan.bases.path | Sort-Object)
        foreach ($base in $admission.plan.bases) {
            { Start-ItlDatabaseAccessHost -Python $python -Request @{schemaVersion=1;coordinator=$continuationSettings.coordinator;bases=@($base);owner=@{operation='competing-branch'};timeout=0} } | Should -Throw '*WAIT_TIMEOUT*'
        }
        $ticketPath = Join-Path $continuationSettings.coordinator ('tickets/' + $admission.owner.proof.ticket + '.json')
        $ticket = Get-Content -LiteralPath $ticketPath -Raw -Encoding UTF8 | ConvertFrom-Json
        @($ticket.nativeJournal.producers.PSObject.Properties) | Should -HaveCount 2
        Publish-ItlDevBranchLifecycleCompletion -Admission $admission
        Complete-ItlDevBranchMutationDatabaseAdmission $admission
        $next = Start-ItlDatabaseAccessHost -Python $python -Request @{schemaVersion=1;coordinator=$continuationSettings.coordinator;bases=@($admission.plan.bases);owner=@{operation='next-chat'};timeout=0}
        Complete-ItlDatabaseAccessHost $next | Out-Null
        [Environment]::GetEnvironmentVariable('ITL_DATABASE_CONTINUATION', 'Process') | Should -BeNullOrEmpty
    }

    It 'rejects a child target change before publishing a second producer plan' {
        $script:DevBranchMutationDatabaseAdmission = Start-ItlDevBranchMutationDatabaseAdmission -Operation refresh-dev-branch-lite
        $DatabaseContinuationProtocol = 1
        $OperationContinuation = $true
        $continuationState.devBranchInfoBasePath = Join-Path $script:ProjectRoot 'Подмененная база'
        { Get-ItlDevBranchMutationAdmissionPreparation -Operation refresh-dev-branch-lite } | Should -Throw '*NATIVE_CONTINUATION_PLAN_CHANGED*'
        Should -Invoke Invoke-Designer -Times 0
    }
}
