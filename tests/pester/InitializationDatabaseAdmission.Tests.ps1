Describe 'Initialization reserves database scope before runtime lifecycle locks' {
    BeforeAll {
        Set-StrictMode -Version Latest
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        . $context.HelperPath -ProjectRoot $context.RepoRoot -Action help *> $null
        . (Join-Path $context.RepoRoot '.agents/skills/itl-remote-runner/scripts/DatabaseAccess.ps1')
        $script:initRealServicePlan = (Get-Command Get-VanessaServiceInfoBasePlan).ScriptBlock
        $script:initRealSourcePlan = (Get-Command Get-ItlSourceDatabasePlan).ScriptBlock
        $script:initPython = (Get-Command python -CommandType Application | Select-Object -First 1).Source
        Remove-Variable DevBranchName,DevBranch,DevBranchInfoBasePath,DevBranchKind,RuntimeRoot,MainWorktreePath -Scope Local -ErrorAction SilentlyContinue
    }
    BeforeEach {
        $script:initRoot = Join-Path $TestDrive ('Подготовка общей базы ' + [guid]::NewGuid().ToString('N'))
        $script:initMain = Join-Path $script:initRoot 'Основной проект'
        $script:initTarget = Join-Path $script:initRoot 'Новая ветка'
        New-Item -ItemType Directory -Force $script:initMain,$script:initTarget | Out-Null
        Set-ProjectContext -Root $script:initMain
        $script:initAuthority = Join-Path $script:initRoot 'Общая очередь'
        $script:initBase = Join-Path $script:initTarget 'База ветки'
        $script:initSource = Join-Path $script:initMain 'Исходная база'
        $script:initKind = 'file'; $script:initHasSeed = $true
        $script:initEvents = @(); $script:initLockHeld = $true
        $script:initBranch = 'itldev/new'; $script:initStateFile = ''
        $script:DevBranchName = 'new'; $script:DevBranch = 'itldev/new'; $script:DevBranchKind = 'configuration'
        $script:DevBranchInfoBasePath = $script:initBase
        $script:RuntimeRoot = ''; $script:MainWorktreePath = $script:initMain
        $script:DevBranchMutationDatabaseAdmission = $null; $script:OneCNativeOperationJournal = $null
        $script:InitDatabaseSettingsReady = $false; $script:DatabaseContinuationProtocol = 0
        $script:initOldLease = [Environment]::GetEnvironmentVariable('ITL_INFOBASE_ACCESS_LEASE','Process')
        $script:initOldContinuation = [Environment]::GetEnvironmentVariable('ITL_DATABASE_CONTINUATION','Process')
        [Environment]::SetEnvironmentVariable('ITL_INFOBASE_ACCESS_LEASE',$null,'Process')
        [Environment]::SetEnvironmentVariable('ITL_DATABASE_CONTINUATION',$null,'Process')
        Mock Get-InfoBaseKind { $script:initKind }
        Mock Get-SourceInfoBasePath { $script:initSource }
        Mock Get-CurrentBranch { $script:initBranch }
        Mock Get-MainWorktreePath { $script:initMain }
        Mock Find-DevBranchStateFile { $script:initStateFile }
        Mock Get-PreparedExtensionDevBranchState { $null }
        Mock Read-BranchSeedManifest { if ($script:initHasSeed) { [pscustomobject]@{sourceKey='fixture'} } }
        Mock Assert-DevelopmentBranchWorktreeContext {}
        Mock Assert-MasterWorktreeContext {}
        Mock Get-ItlOnDemandRuntimeInstances { @() }
        Mock Get-ItlDatabaseAccessSettings { [pscustomobject]@{coordinator=$script:initAuthority;python=$script:initPython;waitTimeoutSeconds=0} }
        Mock Get-ItlSourceDatabasePlan { [pscustomobject]@{project=$script:initMain;source=[pscustomobject]@{kind='file';path=$script:initSource};bases=@([pscustomobject]@{kind='file';path=$script:initSource})} }
        Mock Get-VanessaServiceInfoBasePlan {
            param($State,$CandidateGeneration)
            $generation = if ($CandidateGeneration) { $CandidateGeneration } else { 'a'*32 }
            [pscustomobject]@{kind='file';generation=$generation;path=(Join-Path $script:ProjectRoot ".agent-1c/infobases/vanessa-service-$generation")}
        }
        Mock Set-RunStage {}
        Mock Complete-Agent1cLifecycleOperation { $script:initEvents += 'git-complete' }
        Mock Exit-Agent1cLifecycleOperation { $script:initEvents += 'git-unlock'; $script:initLockHeld = $false }
        Mock Enter-Agent1cLifecycleOperation {
            param($RequestedAction)
            $script:initEvents += "lock:$RequestedAction"
            $script:DevBranchMutationDatabaseAdmission.owner.closed | Should -BeFalse
            Assert-ItlDatabaseAccessHost -Owner $script:DevBranchMutationDatabaseAdmission.owner
            $script:initLockHeld = $true
        }
    }
    AfterEach {
        try { Complete-ItlDevBranchMutationDatabaseAdmission -Admission $script:DevBranchMutationDatabaseAdmission }
        finally {
            $script:DevBranchMutationDatabaseAdmission = $null
            [Environment]::SetEnvironmentVariable('ITL_INFOBASE_ACCESS_LEASE',$script:initOldLease,'Process')
            [Environment]::SetEnvironmentVariable('ITL_DATABASE_CONTINUATION',$script:initOldContinuation,'Process')
            Set-ProjectContext -Root $context.RepoRoot
        }
    }

    It 'waits for a new target without acquiring its lifecycle lock or a manager lease' {
        $holder = Start-ItlDatabaseAccessHost -Python $script:initPython -Request @{schemaVersion=1;coordinator=$script:initAuthority;bases=@(@{kind='file';path=$script:initBase});owner=@{};timeout=0}
        try {
            { Enter-ItlInitializationDatabasePhase -Operation initialize-dev-branch-runtime } | Should -Throw '*WAIT_TIMEOUT*'
            $script:initLockHeld | Should -BeFalse
            Should -Invoke Enter-Agent1cLifecycleOperation -Times 0 -Exactly
            $manager = Join-Path $script:initMain ('.agent-1c/infobases/vanessa-service-' + ('a'*32))
            $other = Start-ItlDatabaseAccessHost -Python $script:initPython -Request @{schemaVersion=1;coordinator=$script:initAuthority;bases=@(@{kind='file';path=$manager});owner=@{};timeout=0}
            Complete-ItlDatabaseAccessHost $other | Out-Null
        } finally { Complete-ItlDatabaseAccessHost $holder | Out-Null }
    }

    It 'holds both future target and manager for nested native callers until initialization completes' {
        Enter-ItlInitializationDatabasePhase -Operation initialize-dev-branch-runtime
        $script:initEvents | Should -Be @('git-complete','git-unlock','lock:initialize-dev-branch-runtime')
        $admission = $script:DevBranchMutationDatabaseAdmission
        $admission.plan.bases | Should -HaveCount 2
        foreach ($base in $admission.plan.bases) {
            { Start-ItlDatabaseAccessHost -Python $script:initPython -Request @{schemaVersion=1;coordinator=$script:initAuthority;bases=@($base);owner=@{};timeout=0} } | Should -Throw '*WAIT_TIMEOUT*'
        }
        $child = Start-ItlDatabaseAccessHost -Python $script:initPython -Request @{schemaVersion=1;coordinator=$script:initAuthority;bases=$admission.plan.bases;owner=@{operation='native-child'};timeout=0;nativeJournalProtocol=1;inherited=$admission.owner.proof}
        Complete-ItlDatabaseAccessHost $child | Out-Null
        Assert-ItlDatabaseAccessHost -Owner $admission.owner
        Publish-ItlDevBranchLifecycleCompletion -Admission $admission
        Complete-ItlDevBranchMutationDatabaseAdmission -Admission $admission
        $next = Start-ItlDatabaseAccessHost -Python $script:initPython -Request @{schemaVersion=1;coordinator=$script:initAuthority;bases=$admission.plan.bases;owner=@{};timeout=0}
        Complete-ItlDatabaseAccessHost $next | Out-Null
    }

    It 'rechecks target inputs after waiting and never applies work to a newly selected database' {
        $admission = Start-ItlDevBranchMutationDatabaseAdmission -Operation initialize-dev-branch-runtime
        $script:DevBranchMutationDatabaseAdmission = $admission
        $script:DevBranchInfoBasePath = Join-Path $script:initTarget 'Другая база'
        { Assert-ItlDevBranchMutationDatabaseAdmission -Admission $admission -State (Get-ItlInitializationDatabaseState) } | Should -Throw '*MUTATION_PLAN_CHANGED*'
    }

    It 'rejects environment changes across the lock handoff before initialization can start' {
        Mock Enter-Agent1cLifecycleOperation {
            Set-Content -LiteralPath (Join-Path $script:ProjectRoot '.dev.env') -Value 'ONEC_INFOBASE_PATH=changed' -Encoding UTF8
        }
        { Enter-ItlInitializationDatabasePhase -Operation initialize-dev-branch-runtime } | Should -Throw '*LIFECYCLE_INPUT_CHANGED*'
        $script:DevBranchMutationDatabaseAdmission.completed | Should -BeTrue
        $next = Start-ItlDatabaseAccessHost -Python $script:initPython -Request @{schemaVersion=1;coordinator=$script:initAuthority;bases=@(@{kind='file';path=$script:initBase});owner=@{};timeout=0}
        Complete-ItlDatabaseAccessHost $next | Out-Null
    }

    It 'retains the saved service generation when resuming an interrupted initialization' {
        $generation = 'b'*32
        $manager = Join-Path $script:initMain ".agent-1c/infobases/vanessa-service-$generation"
        New-Item -ItemType Directory -Force $manager | Out-Null
        @{schemaVersion=1;generation=$generation;templateSha256=('c'*64);serviceUser='service'} | ConvertTo-Json | Set-Content (Join-Path $manager '.itl-service-template.json') -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $manager '1Cv8.1CD') -Value 'fixture' -Encoding UTF8
        $script:initStateFile = Join-Path $script:initMain 'resume.json'
        @{initializationStatus='failed';vanessaServiceInfoBaseSchemaVersion=3;vanessaServiceInfoBaseGeneration=$generation;vanessaServiceInfoBasePath=$manager;vanessaServiceInfoBaseTemplateSha256=('c'*64);vanessaServiceInfoBaseUser='service'} | ConvertTo-Json | Set-Content $script:initStateFile -Encoding UTF8
        Mock Get-VanessaServiceInfoBaseTemplate { [pscustomobject]@{path='fixture.dt';sha256=('c'*64);user='service';password=''} }
        Mock Get-VanessaServiceInfoBasePlan { param($State,$CandidateGeneration) & $script:initRealServicePlan -State $State -CandidateGeneration $CandidateGeneration }
        Enter-ItlInitializationDatabasePhase -Operation initialize-dev-branch-runtime
        $script:DevBranchMutationDatabaseAdmission.plan.servicePlan.reuse | Should -BeTrue
        $script:DevBranchMutationDatabaseAdmission.plan.servicePlan.generation | Should -Be $generation
        $script:DevBranchMutationDatabaseAdmission.plan.bases | Should -HaveCount 2
        # A later runtime assertion must see the same saved manager, not plan a
        # fresh generation from a minimal target-only state.
        Assert-ItlDevBranchMutationDatabaseAdmission -Admission $script:DevBranchMutationDatabaseAdmission -State (Get-ItlInitializationDatabaseState)
        $snapshot = [pscustomobject]@{targetBranchName='new';targetSafeName='new';targetGitBranch='itldev/new';targetWorktreePath=$script:initMain;sourceCommit='fixture';forkId='fixture';sourceGitBranch='itldev/source';sourceBranchName='source';artifactSha256=('d'*64);artifactKind='file-1cd'}
        $forkState = New-ForkedDevBranchState -SourceState ([pscustomobject]@{vanessaServiceInfoBasePath='C:\foreign manager'}) -Snapshot $snapshot -TargetInfoBasePath $script:initBase -TargetHistoryRoot (Join-Path $script:initMain 'history') -MainProjectRoot $script:initMain -TargetState (Get-ItlInitializationDatabaseState)
        $forkState.vanessaServiceInfoBasePath | Should -Be $manager
        (Get-VanessaServiceInfoBasePlan -State ([pscustomobject]$forkState)).inputSha256 | Should -Be $script:DevBranchMutationDatabaseAdmission.plan.servicePlan.inputSha256
    }

    It 'retains server target identity while keeping its manager a separate file database' {
        $script:initKind = 'server'; $script:DevBranchInfoBasePath = 'server/База новой ветки'
        Mock Get-OneCNativeServerRecoveryInspector {
            [pscustomobject]@{schemaVersion=1;path='provider.ps1';sha256=('a' * 64);capability='recovery-observe'}
        }
        $admission = Start-ItlDevBranchMutationDatabaseAdmission -Operation initialize-dev-branch-runtime
        $script:DevBranchMutationDatabaseAdmission = $admission
        $admission.plan.target.kind | Should -Be server
        $admission.plan.target.path | Should -Be 'server/База новой ветки'
        @($admission.plan.bases | Where-Object kind -eq file) | Should -HaveCount 1
        Should -Invoke Get-OneCNativeServerRecoveryInspector -Times 1 -Exactly
    }

    It 'uses the provider runtime root for an adopted workspace and rejects a different root' {
        $script:RuntimeRoot = Join-Path $script:initMain '.agent-1c/workspaces/new'
        $state = Get-ItlInitializationDatabaseState -Operation adopt-dev-worktree
        $state.devBranchInfoBasePath | Should -Be (Join-Path $script:RuntimeRoot 'infobase')
        $script:RuntimeRoot = Join-Path $script:initMain 'Чужой runtime'
        { Get-ItlInitializationDatabaseState -Operation adopt-dev-worktree } | Should -Throw '*WORKSPACE_RUNTIME_ROOT_CHANGED*'
    }

    It 'plans initialization only after the wizard establishes the source connection' {
        Mock Get-ItlSourceDatabasePlan { & $script:initRealSourcePlan }
        Get-ItlDevBranchMutationAdmissionPreparation -Operation init-project | Should -BeNullOrEmpty
        $script:InitDatabaseSettingsReady = $true
        Enter-ItlInitializationDatabasePhase -Operation init-project
        $script:DevBranchMutationDatabaseAdmission.plan.target.path | Should -Be $script:initSource
        $script:DevBranchMutationDatabaseAdmission.plan.bases | Should -HaveCount 2
        Test-Path -LiteralPath (Join-Path $script:initMain '.git') | Should -BeFalse
        $script:initEvents | Should -Be @('git-complete','git-unlock','lock:init-project')
    }

    It 'reserves the source only for the legacy seed-creation phase' {
        Get-ItlDevBranchMutationAdmissionPreparation -Operation new-dev-branch | Should -BeNullOrEmpty
        $script:initHasSeed = $false
        $admission = Start-ItlDevBranchMutationDatabaseAdmission -Operation new-dev-branch
        $script:DevBranchMutationDatabaseAdmission = $admission
        $admission.plan.target.path | Should -Be $script:initSource
        $admission.plan.bases | Should -HaveCount 1
    }

    It 'does not reserve an unrelated source when resuming an already prepared extension branch' {
        $script:initHasSeed = $false
        Mock Get-PreparedExtensionDevBranchState { [pscustomobject]@{initializationStatus='ready'} }
        Get-ItlDevBranchMutationAdmissionPreparation -Operation new-extension-dev-branch | Should -BeNullOrEmpty
    }

    It 'resolves the fork source from the current branch instead of the requested target name' {
        $script:initBranch = 'itldev/source'
        Mock Read-DevBranchState { param($Name) [pscustomobject]@{name=$Name} }
        (Get-ItlDevBranchMutationDatabaseState -Operation fork-dev-branch).name | Should -Be source
    }

    It 'hands off from the source lease to the target before taking target lifecycle locks' {
        $script:initHasSeed = $false
        $script:DevBranchMutationDatabaseAdmission = Start-ItlDevBranchMutationDatabaseAdmission -Operation new-dev-branch
        $sourceOwner = $script:DevBranchMutationDatabaseAdmission.owner
        $seed = [pscustomobject]@{disposed=$false}
        $seed | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $this.disposed=$true }
        Mock Initialize-DevBranchRuntime {
            $script:initEvents += 'runtime'
            $script:DevBranchMutationDatabaseAdmission.owner.public.owner.project | Should -Be $script:initTarget
            $other = Start-ItlDatabaseAccessHost -Python $script:initPython -Request @{schemaVersion=1;coordinator=$script:initAuthority;bases=@(@{kind='file';path=$script:initSource});owner=@{};timeout=0}
            Complete-ItlDatabaseAccessHost $other | Out-Null
        }
        Invoke-DevBranchRuntimeAfterGitPhase -DevBranchKind configuration -GitBranch itldev/new -MainProjectRoot $script:initMain -WorktreePath $script:initTarget -BranchSeedLease $seed
        $sourceOwner.closed | Should -BeTrue
        $seed.disposed | Should -BeTrue
        $script:initEvents | Should -Be @('git-complete','git-unlock','lock:initialize-dev-branch-runtime','runtime')
        $script:ProjectRoot | Should -Be $script:initMain
    }

    It 'releases a completed fork snapshot source before waiting for its occupied target' {
        $script:initHasSeed = $false
        $script:DevBranchMutationDatabaseAdmission = Start-ItlDevBranchMutationDatabaseAdmission -Operation new-dev-branch
        $sourceOwner = $script:DevBranchMutationDatabaseAdmission.owner
        $holder = Start-ItlDatabaseAccessHost -Python $script:initPython -Request @{schemaVersion=1;coordinator=$script:initAuthority;bases=@(@{kind='file';path=$script:initBase});owner=@{};timeout=0}
        Mock Initialize-ForkedDevBranchRuntime {}
        try {
            { Invoke-ForkDevBranchRuntimeAfterSnapshot -Snapshot ([pscustomobject]@{targetSafeName='new'}) -MainProjectRoot $script:initMain -WorktreePath $script:initTarget } | Should -Throw '*WAIT_TIMEOUT*'
            $sourceOwner.closed | Should -BeTrue
            $script:initLockHeld | Should -BeFalse
            Should -Invoke Enter-Agent1cLifecycleOperation -Times 0 -Exactly
            Should -Invoke Initialize-ForkedDevBranchRuntime -Times 0 -Exactly
            $other = Start-ItlDatabaseAccessHost -Python $script:initPython -Request @{schemaVersion=1;coordinator=$script:initAuthority;bases=@(@{kind='file';path=$script:initSource});owner=@{};timeout=0}
            Complete-ItlDatabaseAccessHost $other | Out-Null
        } finally { Complete-ItlDatabaseAccessHost $holder | Out-Null }
    }
}
