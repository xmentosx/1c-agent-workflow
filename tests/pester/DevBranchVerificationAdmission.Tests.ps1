Describe 'Full branch checks retain one complete database admission' {
    BeforeAll {
        Set-StrictMode -Version Latest
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        . $context.HelperPath -ProjectRoot $context.RepoRoot -Action help *> $null
        . (Join-Path $context.RepoRoot '.agents/skills/itl-remote-runner/scripts/DatabaseAccess.ps1')
        $python = (Get-Command python -CommandType Application | Select-Object -First 1).Source
    }
    BeforeEach {
        $script:ProjectRoot = Join-Path $TestDrive ('Проверка общей базы ' + [guid]::NewGuid().ToString('N'))
        $script:DevBranchName = 'check'
        $script:DevBranchMutationDatabaseAdmission = $null
        $script:OneCNativeOperationJournal = $null
        $script:checkState = [pscustomobject]@{infoBaseKind='file';devBranchInfoBasePath=(Join-Path $script:ProjectRoot 'Основная база');vanessaServiceInfoBasePath=(Join-Path $script:ProjectRoot 'Старый менеджер');devBranchName='check'}
        $script:auxPath = Join-Path $script:ProjectRoot 'Дополнительная база'
        $settings = [pscustomobject]@{coordinator=(Join-Path $script:ProjectRoot 'Координатор');python=$python;waitTimeoutSeconds=0}
        $originalProof = [Environment]::GetEnvironmentVariable('ITL_INFOBASE_ACCESS_LEASE', 'Process')
        [Environment]::SetEnvironmentVariable('ITL_INFOBASE_ACCESS_LEASE', $null, 'Process')
        Mock Read-DevBranchState { $script:checkState }
        Mock Assert-DevelopmentBranchWorktreeContext {}
        Mock Get-ItlDatabaseAccessSettings { $settings }
        Mock Get-ItlOnDemandRuntimeInstances { @() }
        Mock Read-VanessaTestClientManifest { [pscustomobject]@{profiles=@([pscustomobject]@{name='A';contour='primary'},[pscustomobject]@{name='B';contour='aux'})} }
        Mock Get-AuxiliaryContour { param($Name) [pscustomobject]@{name=$Name} }
        Mock Assert-AuxiliaryContourReady { [pscustomobject]@{connection=[pscustomobject]@{kind='file';path=$script:auxPath;user='';password=''}} }
        Mock Invoke-Designer { throw 'no native work allowed in admission fixture' }
    }
    AfterEach {
        try { Complete-ItlDevBranchMutationDatabaseAdmission $script:DevBranchMutationDatabaseAdmission }
        finally { [Environment]::SetEnvironmentVariable('ITL_INFOBASE_ACCESS_LEASE', $originalProof, 'Process') }
    }

    It 'reserves target, old and planned managers and all profile databases through <operation> completion' -TestCases @(
        @{operation='check-dev-branch'}, @{operation='verify-dev-branch'}, @{operation='release-e2e-extension-smoke'}
    ) {
        param($operation)
        $script:DevBranchMutationDatabaseAdmission = Start-ItlDevBranchMutationDatabaseAdmission -Operation $operation
        $admission = $script:DevBranchMutationDatabaseAdmission
        $admission.plan.bases | Should -HaveCount 4
        $admission.plan.bases.path | Should -Contain $auxPath
        $admission.plan.bases.path | Should -Contain $checkState.vanessaServiceInfoBasePath
        $admission.plan.bases.path | Should -Contain $admission.plan.servicePlan.path
        Test-Path -LiteralPath $admission.plan.servicePlan.path | Should -BeFalse
        Assert-ItlDevBranchMutationDatabaseAdmission -Admission $admission -State $checkState
        foreach ($base in $admission.plan.bases) {
            $request = @{schemaVersion=1;coordinator=$settings.coordinator;bases=@($base);owner=@{operation='other-chat'};timeout=0}
            { Start-ItlDatabaseAccessHost -Python $python -Request $request } | Should -Throw '*WAIT_TIMEOUT*'
        }
        $unrelated = Start-ItlDatabaseAccessHost -Python $python -Request @{schemaVersion=1;coordinator=$settings.coordinator;bases=@(@{kind='file';path=(Join-Path $script:ProjectRoot 'Независимая база')});owner=@{};timeout=0}
        Complete-ItlDatabaseAccessHost $unrelated | Out-Null
        Should -Invoke Invoke-Designer -Times 0
        Complete-ItlDevBranchMutationDatabaseAdmission $admission
        $next = Start-ItlDatabaseAccessHost -Python $python -Request @{schemaVersion=1;coordinator=$settings.coordinator;bases=@(@{kind='file';path=$auxPath});owner=@{};timeout=0}
        Complete-ItlDatabaseAccessHost $next | Out-Null
    }

    It 'reserves primary and both service generations for <operation> without reading test profiles' -TestCases @(
        @{operation='repair-dev-branch-tooling'}, @{operation='init-dev-branch-extension'}
    ) {
        param($operation)
        Mock Read-VanessaTestClientManifest { throw 'invalid test manifest must not block tooling repair' }
        Mock Assert-VanessaVerificationPreflight { throw 'tooling repair does not run test classification' }
        $preparation = Get-ItlDevBranchMutationAdmissionPreparation -Operation $operation -CheckSourcePreflight
        $script:DevBranchMutationDatabaseAdmission = Start-ItlDevBranchMutationDatabaseAdmission -Operation $operation -Preparation $preparation
        $admission = $script:DevBranchMutationDatabaseAdmission
        $admission.plan.bases | Should -HaveCount 3
        $admission.plan.bases.path | Should -Contain $checkState.devBranchInfoBasePath
        $admission.plan.bases.path | Should -Contain $checkState.vanessaServiceInfoBasePath
        $admission.plan.bases.path | Should -Contain $admission.plan.servicePlan.path
        $admission.plan.bases.path | Should -Not -Contain $auxPath
        Assert-ItlDevBranchMutationDatabaseAdmission -Admission $admission -State $checkState
        foreach ($base in $admission.plan.bases) {
            { Start-ItlDatabaseAccessHost -Python $python -Request @{schemaVersion=1;coordinator=$settings.coordinator;bases=@($base);owner=@{operation='other-chat'};timeout=0} } | Should -Throw '*WAIT_TIMEOUT*'
        }
        $other = Start-ItlDatabaseAccessHost -Python $python -Request @{schemaVersion=1;coordinator=$settings.coordinator;bases=@(@{kind='file';path=$auxPath});owner=@{};timeout=0}
        Complete-ItlDatabaseAccessHost $other | Out-Null
        Should -Invoke Read-VanessaTestClientManifest -Times 0
        Should -Invoke Assert-VanessaVerificationPreflight -Times 0
        Should -Invoke Invoke-Designer -Times 0
    }

    It 'waits before repair when the <resource> database is owned elsewhere' -TestCases @(
        @{resource='primary'}, @{resource='old-service'}, @{resource='new-service'}
    ) {
        param($resource)
        $preparation = Get-ItlDevBranchMutationAdmissionPreparation -Operation repair-dev-branch-tooling
        $path = switch ($resource) {
            'primary' { $checkState.devBranchInfoBasePath }
            'old-service' { $checkState.vanessaServiceInfoBasePath }
            'new-service' { $preparation.plan.servicePlan.path }
        }
        $holder = Start-ItlDatabaseAccessHost -Python $python -Request @{schemaVersion=1;coordinator=$settings.coordinator;bases=@(@{kind='file';path=$path});owner=@{operation='other-project'};timeout=0}
        try {
            { Start-ItlDevBranchMutationDatabaseAdmission -Operation repair-dev-branch-tooling -Preparation $preparation } | Should -Throw '*WAIT_TIMEOUT*'
            Test-Path -LiteralPath $preparation.plan.servicePlan.path | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $script:ProjectRoot '.agent-1c/locks/lifecycle.lock') | Should -BeFalse
            Should -Invoke Invoke-Designer -Times 0
        } finally { Complete-ItlDatabaseAccessHost $holder | Out-Null }
    }

    It 'retains the admitted repair until <outcome> without issuing an early recovery receipt' -TestCases @(
        @{outcome='success'}, @{outcome='extension-failure'}
    ) {
        param($outcome)
        $script:repairOutcome = $outcome
        $script:DevBranchMutationDatabaseAdmission = Start-ItlDevBranchMutationDatabaseAdmission -Operation repair-dev-branch-tooling
        Mock Read-CurrentDevBranchStateForVanessaMcp { $script:checkState }
        Mock Stop-DevBranchRuntimeBeforeInfobaseMutation {
            $script:DevBranchMutationDatabaseAdmission.completed | Should -BeFalse
        }
        Mock Ensure-VanessaMcpInstalled {
            $admitted = $script:DevBranchMutationDatabaseAdmission
            foreach ($base in $admitted.plan.bases) {
                { Start-ItlDatabaseAccessHost -Python $python -Request @{schemaVersion=1;coordinator=$settings.coordinator;bases=@($base);owner=@{};timeout=0} } | Should -Throw '*WAIT_TIMEOUT*'
            }
            $script:checkState
        }
        Mock Test-YAxUnitSuitePresent { $true }
        Mock Ensure-YAxUnitExtensions {
            if ($script:repairOutcome -eq 'extension-failure') { throw 'fixture extension did not activate' }
        }
        Mock Set-RunUserReport {}
        Mock Update-DevBranchState { throw 'unchanged tooling must not receive a new receipt' }
        if ($outcome -eq 'extension-failure') { { Repair-DevBranchTooling } | Should -Throw '*did not activate*' }
        else { Repair-DevBranchTooling }
        $script:DevBranchMutationDatabaseAdmission.completed | Should -BeFalse
        Should -Invoke Stop-DevBranchRuntimeBeforeInfobaseMutation -Times 1 -Exactly
        Should -Invoke Ensure-VanessaMcpInstalled -Times 1 -Exactly
        Should -Invoke Update-DevBranchState -Times 0
        Complete-ItlDevBranchMutationDatabaseAdmission $script:DevBranchMutationDatabaseAdmission
        $next = Start-ItlDatabaseAccessHost -Python $python -Request @{schemaVersion=1;coordinator=$settings.coordinator;bases=@(@{kind='file';path=$checkState.devBranchInfoBasePath});owner=@{};timeout=0}
        Complete-ItlDatabaseAccessHost $next | Out-Null
    }

    It 'waits for an auxiliary database before taking lifecycle locks or creating a service generation' {
        $holder = Start-ItlDatabaseAccessHost -Python $python -Request @{schemaVersion=1;coordinator=$settings.coordinator;bases=@(@{kind='file';path=$auxPath});owner=@{};timeout=0}
        try {
            { Start-ItlDevBranchMutationDatabaseAdmission -Operation check-dev-branch } | Should -Throw '*WAIT_TIMEOUT*'
            Test-Path -LiteralPath (Join-Path $script:ProjectRoot '.agent-1c/locks/lifecycle.lock') | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $script:ProjectRoot '.agent-1c/infobases') | Should -BeFalse
            Should -Invoke Invoke-Designer -Times 0
        } finally { Complete-ItlDatabaseAccessHost $holder | Out-Null }
    }

    It 'rejects a changed auxiliary address before work under the admitted plan' {
        $script:DevBranchMutationDatabaseAdmission = Start-ItlDevBranchMutationDatabaseAdmission -Operation check-dev-branch
        $script:auxPath = Join-Path $script:ProjectRoot 'Подмененная база'
        { Assert-ItlDevBranchMutationDatabaseAdmission -Admission $script:DevBranchMutationDatabaseAdmission -State $checkState } | Should -Throw '*MUTATION_PLAN_CHANGED*'
        Should -Invoke Invoke-Designer -Times 0
    }

    It 'does not extend an inherited parent lease to an unreserved profile database' {
        $parent = Start-ItlDatabaseAccessHost -Python $python -Request @{schemaVersion=1;coordinator=$settings.coordinator;bases=@(@{kind='file';path=$checkState.devBranchInfoBasePath});owner=@{};timeout=0}
        try {
            [Environment]::SetEnvironmentVariable('ITL_INFOBASE_ACCESS_LEASE', ($parent.proof | ConvertTo-Json -Depth 10 -Compress), 'Process')
            { Start-ItlDevBranchMutationDatabaseAdmission -Operation verify-dev-branch } | Should -Throw '*INHERITANCE_INVALID*'
            Should -Invoke Invoke-Designer -Times 0
        } finally { Complete-ItlDatabaseAccessHost $parent | Out-Null }
    }

    It 'routes both check entrypoints through admission before lifecycle and release after the action' {
        $entry = Get-Content -LiteralPath $context.HelperPath -Raw -Encoding UTF8
        $entry | Should -Match "requestedLifecycleAction -in @\([^\r\n]*'check-dev-branch'[^\r\n]*'verify-dev-branch'"
        $entry.IndexOf('Start-ItlDevBranchMutationDatabaseAdmission -Operation') | Should -BeLessThan $entry.IndexOf('Enter-Agent1cLifecycleOperation `')
        $entry.IndexOf('Complete-ItlDevBranchMutationDatabaseAdmission -Admission') | Should -BeGreaterThan $entry.IndexOf('"verify-dev-branch" { Verify-DevBranch }')
        $entry.IndexOf('Complete-ItlDevBranchMutationDatabaseAdmission -Admission') | Should -BeLessThan $entry.IndexOf('Complete-Agent1cLifecycleOperation -Status "succeeded"')
    }
}
