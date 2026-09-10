Describe 'Auxiliary operations share database ownership and preserve foreign sessions' {
    BeforeAll {
        Set-StrictMode -Version Latest
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        . $context.HelperPath -ProjectRoot $context.RepoRoot -Action help *> $null
        . (Join-Path $context.RepoRoot '.agents/skills/itl-remote-runner/scripts/DatabaseAccess.ps1')
        $python = (Get-Command python -CommandType Application | Select-Object -First 1).Source
    }
    BeforeEach {
        $script:ProjectRoot = Join-Path $TestDrive ('Дополнительная общая база ' + [guid]::NewGuid().ToString('N'))
        $script:DevBranchName = 'check'
        $script:DevBranchMutationDatabaseAdmission = $null
        $script:OneCNativeOperationJournal = $null
        $script:ActiveAuxiliaryVanessaContext = $null
        $script:primaryState = [pscustomobject]@{infoBaseKind='file';devBranchInfoBasePath=(Join-Path $script:ProjectRoot 'Основная база');vanessaServiceInfoBasePath=(Join-Path $script:ProjectRoot 'Старый менеджер');devBranchName='check'}
        $script:auxPath = Join-Path $script:ProjectRoot 'Целевая база'
        $script:otherPath = Join-Path $script:ProjectRoot 'Другая база профиля'
        $script:externalSessions = @()
        $script:ownedRuntimes = @()
        $settings = [pscustomobject]@{coordinator=(Join-Path $script:ProjectRoot 'Координатор');python=$python;waitTimeoutSeconds=0}
        $originalProof = [Environment]::GetEnvironmentVariable('ITL_INFOBASE_ACCESS_LEASE', 'Process')
        [Environment]::SetEnvironmentVariable('ITL_INFOBASE_ACCESS_LEASE', $null, 'Process')
        Mock Read-DevBranchState { $script:primaryState }
        Mock Assert-DevelopmentBranchWorktreeContext {}
        Mock Get-ItlDatabaseAccessSettings { $settings }
        Mock Get-ItlOnDemandRuntimeInstances { $script:ownedRuntimes }
        Mock Get-ItlOnDemandRuntimeDatabaseConnections { param($FallbackTarget) @($FallbackTarget) }
        Mock Read-VanessaTestClientManifest { [pscustomobject]@{profiles=@([pscustomobject]@{name='A';contour='primary'},[pscustomobject]@{name='B';contour='other'})} }
        Mock Get-AuxiliaryContour { param($Name) [pscustomobject]@{name=$(if ($Name) {$Name} else {'aux'});baseMode='managed-file'} }
        Mock Get-AuxiliaryContourConnection { param($Contour) [pscustomobject]@{kind='file';path=$(if ($Contour.name -eq 'aux') {$script:auxPath} else {$script:otherPath});user='';password=''} }
        Mock Assert-AuxiliaryContourReady { throw 'not ready until the authorized update finishes' }
        Mock Get-OneCInfoBaseSessionProcesses { $script:externalSessions }
        Mock Stop-OneCInfoBaseSessionProcesses { throw 'must never stop foreign sessions' }
        Mock Stop-ItlOnDemandBackends { $script:ownedRuntimes = @() }
        Mock Invoke-DevBranchVanessaRuntimeRelease {}
        Mock Get-OwnVanessaTestProcesses { @() }
        Mock Get-RoctupMcpRuntimeInfo { [pscustomobject]@{processAlive=$false} }
        Mock Set-RunStage {}
        $script:contour = Get-AuxiliaryContour
    }
    AfterEach {
        try { Complete-ItlDevBranchMutationDatabaseAdmission $script:DevBranchMutationDatabaseAdmission }
        finally { [Environment]::SetEnvironmentVariable('ITL_INFOBASE_ACCESS_LEASE', $originalProof, 'Process') }
    }

    It 'admits only auxiliary resources for standalone <operation> without requiring primary state' -TestCases @(
        @{operation='update-auxiliary-contour'},@{operation='dump-auxiliary-contour'},
        @{operation='export-auxiliary-contour-result'},@{operation='reset-auxiliary-contour'}
    ) {
        param($operation)
        Mock Read-DevBranchState { throw 'independent contour does not have primary branch state' }
        $script:DevBranchMutationDatabaseAdmission = Start-ItlDevBranchMutationDatabaseAdmission -Operation $operation
        $plan = $script:DevBranchMutationDatabaseAdmission.plan
        $plan.bases | Should -HaveCount 1
        $plan.target.path | Should -Be $auxPath
        $plan.servicePlan | Should -BeNullOrEmpty
        Assert-ItlDevBranchMutationDatabaseAdmission -Admission $script:DevBranchMutationDatabaseAdmission -State $null
        Should -Invoke Read-DevBranchState -Times 0
        $competitor = @{schemaVersion=1;coordinator=$settings.coordinator;bases=@(@{kind='file';path=$auxPath});owner=@{};timeout=0}
        { Start-ItlDatabaseAccessHost -Python $python -Request $competitor } | Should -Throw '*WAIT_TIMEOUT*'
        Complete-ItlDevBranchMutationDatabaseAdmission $script:DevBranchMutationDatabaseAdmission
        $next = Start-ItlDatabaseAccessHost -Python $python -Request $competitor
        Complete-ItlDatabaseAccessHost $next | Out-Null
    }

    It 'plans auxiliary tests before readiness and includes primary tooling, both managers and every profile target' {
        $script:DevBranchMutationDatabaseAdmission = Start-ItlDevBranchMutationDatabaseAdmission -Operation check-auxiliary-contour
        $plan = $script:DevBranchMutationDatabaseAdmission.plan
        $plan.bases | Should -HaveCount 5
        $plan.target.path | Should -Be $auxPath
        $plan.serviceTarget.path | Should -Be $primaryState.devBranchInfoBasePath
        foreach ($path in @($auxPath,$otherPath,$primaryState.devBranchInfoBasePath,$primaryState.vanessaServiceInfoBasePath,$plan.servicePlan.path)) {
            $plan.bases.path | Should -Contain $path
        }
        Assert-ItlDevBranchMutationDatabaseAdmission -Admission $script:DevBranchMutationDatabaseAdmission -State $primaryState
        Should -Invoke Assert-AuxiliaryContourReady -Times 0
        $script:ActiveAuxiliaryVanessaContext = [pscustomobject]@{contour=$contour}
        { Get-VanessaTestClientProfileConnection -Profile ([pscustomobject]@{name='A';contour='primary'}) -DefaultState $primaryState } | Should -Throw '*not ready until*'
        Should -Invoke Assert-AuxiliaryContourReady -Times 1
    }

    It 'waits for the auxiliary owner before any runtime cleanup or lifecycle lock' {
        $holder = Start-ItlDatabaseAccessHost -Python $python -Request @{schemaVersion=1;coordinator=$settings.coordinator;bases=@(@{kind='file';path=$auxPath});owner=@{operation='measurement'};timeout=0}
        try {
            { Start-ItlDevBranchMutationDatabaseAdmission -Operation update-auxiliary-contour } | Should -Throw '*WAIT_TIMEOUT*'
            Should -Invoke Stop-ItlOnDemandBackends -Times 0
            Should -Invoke Stop-OneCInfoBaseSessionProcesses -Times 0
            Test-Path -LiteralPath (Join-Path $script:ProjectRoot '.agent-1c/locks/lifecycle.lock') | Should -BeFalse
        } finally { Complete-ItlDatabaseAccessHost $holder | Out-Null }
    }

    It 'rejects target drift before stopping any runtime' {
        $script:DevBranchMutationDatabaseAdmission = Start-ItlDevBranchMutationDatabaseAdmission -Operation update-auxiliary-contour
        $originalConnection = Get-AuxiliaryContourConnection -Contour $contour
        $script:auxPath = Join-Path $script:ProjectRoot 'Подмененная база'
        { Stop-AuxiliaryContourRuntimeBeforeMutation -Contour $contour -Connection $originalConnection -Reason update } | Should -Throw '*MUTATION_PLAN_CHANGED*'
        Should -Invoke Stop-ItlOnDemandBackends -Times 0
    }

    It 'waits for foreign sessions without stopping them and releases only its own finished drain' {
        $script:DevBranchMutationDatabaseAdmission = Start-ItlDevBranchMutationDatabaseAdmission -Operation update-auxiliary-contour
        $script:externalSessions = @([pscustomobject]@{processId=9201})
        { Stop-AuxiliaryContourRuntimeBeforeMutation -Contour $contour -Connection (Get-AuxiliaryContourConnection -Contour $contour) -Reason update } | Should -Throw '*EXTERNAL_SESSIONS_WAIT_TIMEOUT*'
        Should -Invoke Stop-OneCInfoBaseSessionProcesses -Times 0
        $externalSessions | Should -HaveCount 1
        Test-OneCNativeOperationJournalReleased $script:DevBranchMutationDatabaseAdmission.journal | Should -BeTrue
        Complete-ItlDevBranchMutationDatabaseAdmission $script:DevBranchMutationDatabaseAdmission
    }

    It 'retains the database reservation after uncertain owned cleanup' {
        $script:DevBranchMutationDatabaseAdmission = Start-ItlDevBranchMutationDatabaseAdmission -Operation reset-auxiliary-contour
        Mock Stop-ItlOnDemandBackends { throw 'owned stop uncertain' }
        { Stop-AuxiliaryContourRuntimeBeforeMutation -Contour $contour -Connection (Get-AuxiliaryContourConnection -Contour $contour) -Reason reset } | Should -Throw '*owned stop uncertain*'
        { Complete-ItlDevBranchMutationDatabaseAdmission $script:DevBranchMutationDatabaseAdmission } | Should -Throw '*NATIVE_CLEANUP_UNCONFIRMED*'
        { Start-ItlDatabaseAccessHost -Python $python -Request @{schemaVersion=1;coordinator=$settings.coordinator;bases=@(@{kind='file';path=$auxPath});owner=@{};timeout=0} } | Should -Throw '*RECOVERY_REQUIRED*'
        Should -Invoke Stop-OneCInfoBaseSessionProcesses -Times 0
    }

    It 'admits primary tooling cleanup during auxiliary checks but excludes other profile databases' {
        $script:DevBranchMutationDatabaseAdmission = Start-ItlDevBranchMutationDatabaseAdmission -Operation check-auxiliary-contour
        Stop-DevBranchRuntimeBeforeInfobaseMutation -State $primaryState -Reason 'primary tooling'
        { Stop-DevBranchRuntimeBeforeInfobaseMutation -State $primaryState -InfoBasePath $otherPath -Reason 'unrelated profile mutation' } | Should -Throw '*NATIVE_TARGET_NOT_RESERVED*'
        Should -Invoke Invoke-DevBranchVanessaRuntimeRelease -Times 1
        Should -Invoke Stop-OneCInfoBaseSessionProcesses -Times 0
    }

    It 'requires admitted ownership before a direct auxiliary drain' {
        { Stop-AuxiliaryContourRuntimeBeforeMutation -Contour $contour -Connection (Get-AuxiliaryContourConnection -Contour $contour) -Reason update } | Should -Throw '*MUTATION_ADMISSION_REQUIRED*'
        Should -Invoke Stop-ItlOnDemandBackends -Times 0
    }

    It 'keeps the complete operation set aligned between entrypoint, start and plan validation' {
        $expected = @('update-dev-branch-base','lock-config-repository-objects','check-dev-branch','verify-dev-branch','update-auxiliary-contour','check-auxiliary-contour','dump-auxiliary-contour','export-auxiliary-contour-result','reset-auxiliary-contour','export-dev-branch-result','dump-dev-branch-extension','repair-dev-branch-tooling','init-dev-branch-extension','release-e2e-extension-smoke')
        foreach ($name in @('Start-ItlDevBranchMutationDatabaseAdmission','Get-ItlDevBranchMutationDatabasePlan')) {
            $values = @((Get-Command $name).Parameters['Operation'].Attributes | Where-Object { $_ -is [Management.Automation.ValidateSetAttribute] } | ForEach-Object { $_.ValidValues })
            @($values | Sort-Object) | Should -Be @($expected | Sort-Object)
        }
        $entry = Get-Content -LiteralPath $context.HelperPath -Raw -Encoding UTF8
        $match = [regex]::Match($entry, "if \(\`$requestedLifecycleAction -in @\((?<actions>[^\r\n]+)\)\)")
        $match.Success | Should -BeTrue
        $values = @([regex]::Matches($match.Groups['actions'].Value, "'(?<name>[^']+)'" ) | ForEach-Object { $_.Groups['name'].Value })
        @($values | Sort-Object) | Should -Be @($expected | Sort-Object)
    }
}
