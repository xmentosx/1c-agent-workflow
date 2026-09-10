Describe 'Development database update owns shared admission before native work' {
    BeforeAll {
        Set-StrictMode -Version Latest
        $repo = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
        $lib = Join-Path $repo '.agents/skills/1c-workflow/scripts/lib'
        foreach ($name in @('core', 'runtime-values', 'sessions', 'lifecycle', 'roctup-mcp', 'vanessa', 'ondemand-mcp')) {
            . (Join-Path $lib ("agent-1c.$name.ps1"))
        }
        . (Join-Path $repo '.agents/skills/itl-remote-runner/scripts/DatabaseAccess.ps1')
        $python = (Get-Command python -CommandType Application | Select-Object -First 1).Source
    }
    BeforeEach {
        $script:ProjectRoot = Join-Path $TestDrive ('Обновление общей базы ' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:ProjectRoot | Out-Null
        $script:DevBranchName = 'update'
        $script:DevBranchMutationDatabaseAdmission = $null
        $script:OneCNativeOperationJournal = $null
        $script:OneCSessionLaunchContext = $null
        $script:mutationState = [pscustomobject]@{ infoBaseKind='file'; devBranchInfoBasePath=(Join-Path $script:ProjectRoot 'Целевая база'); vanessaServiceInfoBasePath=(Join-Path $script:ProjectRoot 'Служебная база'); worktreePath=$script:ProjectRoot }
        $script:mutationState | Add-Member -NotePropertyName devBranchKind -NotePropertyValue 'configuration'
        $script:mutationState | Add-Member -NotePropertyName initializationStatus -NotePropertyValue 'ready'
        $script:repositorySourcePath = Join-Path $script:ProjectRoot 'Общая исходная база'
        $script:mutationRuntimes = @()
        $script:mutationExternalSessions = @()
        $settings = [pscustomobject]@{ coordinator=(Join-Path $script:ProjectRoot 'Общий координатор'); python=$python; waitTimeoutSeconds=0 }
        $originalProof = [Environment]::GetEnvironmentVariable('ITL_INFOBASE_ACCESS_LEASE', 'Process')
        [Environment]::SetEnvironmentVariable('ITL_INFOBASE_ACCESS_LEASE', $null, 'Process')
        Mock Get-ItlDatabaseAccessSettings { $settings }
        Mock Get-SourceUsesRepository { $true }
        Mock Get-InfoBaseKind { 'file' }
        Mock Get-SourceInfoBasePath { $script:repositorySourcePath }
        Mock Read-DevBranchState { $script:mutationState }
        Mock Assert-DevelopmentBranchWorktreeContext {}
        Mock Get-ItlOnDemandRuntimeInstances { $script:mutationRuntimes }
        Mock Test-VanessaInteractiveProfileHasOwner { $true }
        Mock Stop-DevBranchVanessaInteractiveProfile { throw 'must wait for this owner, not stop it' }
        Mock Invoke-DevBranchVanessaRuntimeRelease {}
        Mock Stop-ItlOnDemandBackends {}
        Mock Get-RoctupMcpRuntimeInfo { [pscustomobject]@{ processAlive=$false } }
        Mock Get-OwnVanessaTestProcesses { @() }
        Mock Get-OneCInfoBaseSessionProcesses { $script:mutationExternalSessions }
        Mock Stop-OneCInfoBaseSessionProcesses { throw 'must not stop foreign sessions' }
        Mock Set-RunStage {}
        Mock Invoke-OneCSessionAdmissionSet { param($Admissions, $StartProcess) & $StartProcess }
        Mock Remove-OneCSessionReservation {}
        $competingRequest = [ordered]@{ schemaVersion=1; coordinator=$settings.coordinator; timeout=0; bases=@(@{kind='file';path=$script:mutationState.devBranchInfoBasePath}); owner=@{operation='competing-update'} }
    }
    AfterEach {
        try {
            if ($null -ne $script:DevBranchMutationDatabaseAdmission -and -not $script:DevBranchMutationDatabaseAdmission.completed) {
                Complete-ItlDevBranchMutationDatabaseAdmission $script:DevBranchMutationDatabaseAdmission
            }
        } finally { [Environment]::SetEnvironmentVariable('ITL_INFOBASE_ACCESS_LEASE', $originalProof, 'Process') }
    }

    It 'waits for another database owner without local locks or stopping its manual profile' {
        $holder = Start-ItlDatabaseAccessHost -Python $python -Request $competingRequest
        try {
            { Start-ItlDevBranchMutationDatabaseAdmission } | Should -Throw '*WAIT_TIMEOUT*'
            Test-Path -LiteralPath (Join-Path $script:ProjectRoot '.agent-1c/locks/lifecycle.lock') | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $script:ProjectRoot '.agent-1c/locks/runtime-mcp.lock') | Should -BeFalse
            Should -Invoke Stop-DevBranchVanessaInteractiveProfile -Times 0 -Exactly
            Should -Invoke Invoke-DevBranchVanessaRuntimeRelease -Times 0 -Exactly
        } finally { Complete-ItlDatabaseAccessHost $holder | Out-Null }
    }

    It 'reserves recorded managers and releases a skipped update without native debt' {
        $script:DevBranchMutationDatabaseAdmission = Start-ItlDevBranchMutationDatabaseAdmission
        $admission = $script:DevBranchMutationDatabaseAdmission
        $admission.plan.bases.Count | Should -Be 2
        @($admission.plan.bases.path) | Should -Contain $script:mutationState.vanessaServiceInfoBasePath
        { Start-ItlDatabaseAccessHost -Python $python -Request $competingRequest } | Should -Throw '*WAIT_TIMEOUT*'
        Complete-ItlDevBranchMutationDatabaseAdmission $admission
        $script:OneCNativeOperationJournal | Should -BeNullOrEmpty
        [Environment]::GetEnvironmentVariable('ITL_INFOBASE_ACCESS_LEASE', 'Process') | Should -BeNullOrEmpty
        $next = Start-ItlDatabaseAccessHost -Python $python -Request $competingRequest
        Complete-ItlDatabaseAccessHost $next | Out-Null
    }

    It 'coordinates <operation> from planning through native completion' -TestCases @(
        @{operation='export-dev-branch-result';resources=2}, @{operation='dump-dev-branch-extension';resources=1},
        @{operation='update1cbase';resources=2}, @{operation='loadfrom1cbase';resources=1}, @{operation='getconfigfiles';resources=1}
    ) {
        param($operation, $resources)
        $holder = Start-ItlDatabaseAccessHost -Python $python -Request $competingRequest
        try {
            { Start-ItlDevBranchMutationDatabaseAdmission -Operation $operation } | Should -Throw '*WAIT_TIMEOUT*'
            Test-Path -LiteralPath (Join-Path $script:ProjectRoot '.agent-1c/locks/lifecycle.lock') | Should -BeFalse
            Should -Invoke Stop-OneCInfoBaseSessionProcesses -Times 0
        } finally { Complete-ItlDatabaseAccessHost $holder | Out-Null }
        $script:DevBranchMutationDatabaseAdmission = Start-ItlDevBranchMutationDatabaseAdmission -Operation $operation
        $admission = $script:DevBranchMutationDatabaseAdmission
        $admission.plan.bases | Should -HaveCount $resources
        Assert-ItlDevBranchMutationDatabaseAdmission -Admission $admission -State $script:mutationState
        Invoke-WithOneCSessionAdmissionContext -InfoBaseKind file -InfoBasePath $script:mutationState.devBranchInfoBasePath -Purpose export-fixture -ScriptBlock {
            Invoke-OneCSessionProcessStart -StartProcess { [pscustomobject]@{Id=9876} }
        } | Out-Null
        Test-OneCNativeOperationJournalReleased $admission.journal | Should -BeFalse
        { Start-ItlDatabaseAccessHost -Python $python -Request $competingRequest } | Should -Throw '*WAIT_TIMEOUT*'
        Confirm-OneCNativeOperationRelease -Record $admission.journal.entries[0] -LauncherExited $true -OwnedProcessesReleased $true -Evidence 'fixture-scoped-release'
        # Native exit does not end the caller's export/validation/manifest scope.
        { Start-ItlDatabaseAccessHost -Python $python -Request $competingRequest } | Should -Throw '*WAIT_TIMEOUT*'
        Complete-ItlDevBranchMutationDatabaseAdmission $admission
        $next = Start-ItlDatabaseAccessHost -Python $python -Request $competingRequest
        Complete-ItlDatabaseAccessHost $next | Out-Null
    }

    It 'does not reserve an unrelated manager for a read-only extension dump' {
        $managerRequest = @{schemaVersion=1;coordinator=$settings.coordinator;timeout=0;bases=@(@{kind='file';path=$script:mutationState.vanessaServiceInfoBasePath});owner=@{operation='independent-manager'}}
        $holder = Start-ItlDatabaseAccessHost -Python $python -Request $managerRequest
        try {
            $script:DevBranchMutationDatabaseAdmission = Start-ItlDevBranchMutationDatabaseAdmission -Operation dump-dev-branch-extension
            $script:DevBranchMutationDatabaseAdmission.plan.bases.path | Should -Be $script:mutationState.devBranchInfoBasePath
            Should -Invoke Invoke-DevBranchVanessaRuntimeRelease -Times 0
        } finally { Complete-ItlDatabaseAccessHost $holder | Out-Null }
    }

    It 'rejects target drift after waiting before any runtime cleanup' {
        $script:DevBranchMutationDatabaseAdmission = Start-ItlDevBranchMutationDatabaseAdmission
        $script:mutationState.devBranchInfoBasePath = Join-Path $script:ProjectRoot 'Другая база'
        { Stop-DevBranchRuntimeBeforeInfobaseMutation $script:mutationState } | Should -Throw '*MUTATION_PLAN_CHANGED*'
        Should -Invoke Invoke-DevBranchVanessaRuntimeRelease -Times 0 -Exactly
        Test-OneCNativeOperationJournalReleased $script:DevBranchMutationDatabaseAdmission.journal | Should -BeTrue
    }

    It 'rejects an unreserved native target before launch and preserves the previous context' {
        $script:DevBranchMutationDatabaseAdmission = Start-ItlDevBranchMutationDatabaseAdmission
        {
            Invoke-WithOneCSessionAdmissionContext -InfoBaseKind file -InfoBasePath (Join-Path $TestDrive 'Чужая база') -ScriptBlock {
                throw 'must not enter the launch body'
            }
        } | Should -Throw '*NATIVE_TARGET_NOT_RESERVED*'
        $script:OneCSessionLaunchContext | Should -BeNullOrEmpty
        Test-OneCNativeOperationJournalReleased $script:DevBranchMutationDatabaseAdmission.journal | Should -BeTrue
    }

    It 'keeps native launch uncertainty as recovery debt and restores the private context' {
        $script:DevBranchMutationDatabaseAdmission = Start-ItlDevBranchMutationDatabaseAdmission
        {
            Invoke-WithOneCSessionAdmissionContext -InfoBaseKind file -InfoBasePath $script:mutationState.devBranchInfoBasePath -ScriptBlock {
                Invoke-OneCSessionProcessStart -StartProcess { throw 'unknown native launch' }
            }
        } | Should -Throw '*unknown native launch*'
        { Complete-ItlDevBranchMutationDatabaseAdmission $script:DevBranchMutationDatabaseAdmission } | Should -Throw '*NATIVE_CLEANUP_UNCONFIRMED*'
        $script:OneCNativeOperationJournal | Should -BeNullOrEmpty
        [Environment]::GetEnvironmentVariable('ITL_INFOBASE_ACCESS_LEASE', 'Process') | Should -BeNullOrEmpty
        { Start-ItlDatabaseAccessHost -Python $python -Request $competingRequest } | Should -Throw '*RECOVERY_REQUIRED*'
    }

    It 'preserves foreign sessions after strict owned cleanup and can release its own reservation' {
        $script:DevBranchMutationDatabaseAdmission = Start-ItlDevBranchMutationDatabaseAdmission
        $script:mutationExternalSessions = @([pscustomobject]@{processId=9876})
        { Stop-DevBranchRuntimeBeforeInfobaseMutation $script:mutationState } | Should -Throw '*EXTERNAL_SESSIONS_WAIT_TIMEOUT*'
        Should -Invoke Stop-OneCInfoBaseSessionProcesses -Times 0 -Exactly
        Test-OneCNativeOperationJournalReleased $script:DevBranchMutationDatabaseAdmission.journal | Should -BeTrue
    }

    It 'retains failed owner cleanup instead of falling back to stopping all database clients' {
        $script:DevBranchMutationDatabaseAdmission = Start-ItlDevBranchMutationDatabaseAdmission
        Mock Invoke-DevBranchVanessaRuntimeRelease { throw 'owned stop uncertain' }
        { Stop-DevBranchRuntimeBeforeInfobaseMutation $script:mutationState } | Should -Throw '*owned stop uncertain*'
        Should -Invoke Stop-OneCInfoBaseSessionProcesses -Times 0 -Exactly
        { Complete-ItlDevBranchMutationDatabaseAdmission $script:DevBranchMutationDatabaseAdmission } | Should -Throw '*NATIVE_CLEANUP_UNCONFIRMED*'
    }

    It 'keeps inherited ownership with its original parent after the update finishes' {
        $parentRequest = [ordered]@{ schemaVersion=1; coordinator=$settings.coordinator; timeout=0; bases=(Get-ItlDevBranchMutationDatabasePlan $script:mutationState).bases; owner=@{operation='parent-measurement'} }
        $parent = Start-ItlDatabaseAccessHost -Python $python -Request $parentRequest
        $parentProof = $parent.proof | ConvertTo-Json -Depth 40 -Compress
        try {
            [Environment]::SetEnvironmentVariable('ITL_INFOBASE_ACCESS_LEASE', $parentProof, 'Process')
            $script:DevBranchMutationDatabaseAdmission = Start-ItlDevBranchMutationDatabaseAdmission
            Complete-ItlDevBranchMutationDatabaseAdmission $script:DevBranchMutationDatabaseAdmission
            [Environment]::GetEnvironmentVariable('ITL_INFOBASE_ACCESS_LEASE', 'Process') | Should -Be $parentProof
            { Start-ItlDatabaseAccessHost -Python $python -Request $competingRequest } | Should -Throw '*WAIT_TIMEOUT*'
        } finally { Complete-ItlDatabaseAccessHost $parent | Out-Null }
    }

    It 'does not release the parent after inherited native cleanup becomes uncertain' {
        $parentRequest = [ordered]@{ schemaVersion=1; coordinator=$settings.coordinator; timeout=0; bases=(Get-ItlDevBranchMutationDatabasePlan $script:mutationState).bases; owner=@{operation='parent-measurement'} }
        $parent = Start-ItlDatabaseAccessHost -Python $python -Request $parentRequest
        try {
            [Environment]::SetEnvironmentVariable('ITL_INFOBASE_ACCESS_LEASE', ($parent.proof | ConvertTo-Json -Depth 40 -Compress), 'Process')
            $script:DevBranchMutationDatabaseAdmission = Start-ItlDevBranchMutationDatabaseAdmission
            {
                Invoke-WithOneCSessionAdmissionContext -InfoBaseKind file -InfoBasePath $script:mutationState.devBranchInfoBasePath -ScriptBlock {
                    Invoke-OneCSessionProcessStart -StartProcess { throw 'inherited native start outcome unknown' }
                }
            } | Should -Throw '*inherited native start outcome unknown*'
            { Complete-ItlDevBranchMutationDatabaseAdmission $script:DevBranchMutationDatabaseAdmission } | Should -Throw '*NATIVE_CLEANUP_UNCONFIRMED*'
            (Complete-ItlDatabaseAccessHost $parent).status | Should -Be 'needs-attention'
        } finally { Close-ItlDatabaseAccessHost $parent }
    }

    It 'places update admission before lifecycle locks and release before success' {
        $entry = Get-Content (Join-Path $repo '.agents/skills/1c-workflow/scripts/agent-1c.ps1') -Raw -Encoding UTF8
        $entry.IndexOf('Start-ItlDevBranchMutationDatabaseAdmission -Operation') | Should -BeLessThan $entry.IndexOf('Enter-Agent1cLifecycleOperation `')
        $entry.IndexOf('Complete-ItlDevBranchMutationDatabaseAdmission -Admission') | Should -BeLessThan $entry.IndexOf('Complete-Agent1cLifecycleOperation -Status "succeeded"')
    }

    It 'reserves the repository source base without reserving branch or Vanessa manager bases' -TestCases @(
        @{ sourceKind = 'file' }, @{ sourceKind = 'server' }
    ) {
        param($sourceKind)
        Mock Get-InfoBaseKind { $sourceKind }
        if ($sourceKind -eq 'server') { $script:repositorySourcePath = 'test-server\ОбщаяБаза' }
        $script:DevBranchMutationDatabaseAdmission = Start-ItlDevBranchMutationDatabaseAdmission -Operation 'lock-config-repository-objects'
        $admission = $script:DevBranchMutationDatabaseAdmission
        @($admission.plan.bases).Count | Should -Be 1
        $admission.plan.target.kind | Should -Be $sourceKind
        $admission.plan.target.path | Should -Be $script:repositorySourcePath
        $branchOwner = Start-ItlDatabaseAccessHost -Python $python -Request $competingRequest
        Complete-ItlDatabaseAccessHost $branchOwner | Out-Null
        $sourceRequest = [ordered]@{ schemaVersion=1; coordinator=$settings.coordinator; timeout=0; bases=$admission.plan.bases; owner=@{project='another-project';operation='source-measurement'} }
        { Start-ItlDatabaseAccessHost -Python $python -Request $sourceRequest } | Should -Throw '*WAIT_TIMEOUT*'
        Complete-ItlDevBranchMutationDatabaseAdmission $admission
        $next = Start-ItlDatabaseAccessHost -Python $python -Request $sourceRequest
        Complete-ItlDatabaseAccessHost $next | Out-Null
    }

    It 'waits for source ownership before lifecycle entry without stopping another session' {
        $sourceRequest = [ordered]@{ schemaVersion=1; coordinator=$settings.coordinator; timeout=0; bases=@(@{kind='file';path=$script:repositorySourcePath}); owner=@{project='another-project';operation='source-profile'} }
        $holder = Start-ItlDatabaseAccessHost -Python $python -Request $sourceRequest
        try {
            { Start-ItlDevBranchMutationDatabaseAdmission -Operation 'lock-config-repository-objects' } | Should -Throw '*WAIT_TIMEOUT*'
            Test-Path -LiteralPath (Join-Path $script:ProjectRoot '.agent-1c/locks/lifecycle.lock') | Should -BeFalse
            Should -Invoke Stop-DevBranchVanessaInteractiveProfile -Times 0 -Exactly
            Should -Invoke Stop-OneCInfoBaseSessionProcesses -Times 0 -Exactly
        } finally { Complete-ItlDatabaseAccessHost $holder | Out-Null }
    }

    It 'rechecks the source target after waiting rather than comparing only the branch database' {
        $script:DevBranchMutationDatabaseAdmission = Start-ItlDevBranchMutationDatabaseAdmission -Operation 'lock-config-repository-objects'
        $script:repositorySourcePath = Join-Path $script:ProjectRoot 'Другая исходная база'
        { Assert-ItlDevBranchMutationDatabaseAdmission -Admission $script:DevBranchMutationDatabaseAdmission -State $script:mutationState } | Should -Throw '*MUTATION_PLAN_CHANGED*'
    }

    It 'keeps the same source lease through root and object requests until the caller releases it' {
        $script:DevBranchMutationDatabaseAdmission = Start-ItlDevBranchMutationDatabaseAdmission -Operation 'lock-config-repository-objects'
        $script:sourceCompetingRequest = [ordered]@{ schemaVersion=1; coordinator=$settings.coordinator; timeout=0; bases=$script:DevBranchMutationDatabaseAdmission.plan.bases; owner=@{project='another-project';operation='repository-lock'} }
        $script:phaseProofs = [Collections.Generic.List[string]]::new()
        $script:RunStatusPath = ''; $script:RunUserReport = ''
        Mock Repair-OneCSourceLineEndings {}
        Mock Get-ExportPath { 'src/cf' }
        Mock Get-EnvValue { '' }
        Mock New-RepositoryConnectionArgs { @() }
        Mock Get-ConfigRepositoryTransferPlan {
            [pscustomobject]@{ baseCommit='base'; unresolvedPaths=@(); rootLockRequiredBy=@('Константа.Новая'); items=@(
                [pscustomobject]@{name='Конфигурация';scope='partial'}, [pscustomobject]@{name='Константа.Новая';scope='full'}
            ) }
        }
        Mock Invoke-Designer {
            $script:phaseProofs.Add([Environment]::GetEnvironmentVariable('ITL_INFOBASE_ACCESS_LEASE', 'Process'))
            { Start-ItlDatabaseAccessHost -Python $python -Request $script:sourceCompetingRequest } | Should -Throw '*WAIT_TIMEOUT*'
            $script:LastLogPath = Join-Path $script:ProjectRoot ('native-' + $script:phaseProofs.Count + '.log')
            $text = if ($script:phaseProofs.Count -eq 1) {
                "---- Начало операции с хранилищем конфигурации ----`nОбъект захвачен для редактирования: Конфигурация`n---- Операция с хранилищем конфигурации завершена ----"
            } else {
                "Объекты, отсутствующие в обеих конфигурациях:`nКонстанта.Новая`n---- Начало операции с хранилищем конфигурации ----`n---- Операция с хранилищем конфигурации завершена ----"
            }
            Write-Utf8Text -Path $script:LastLogPath -Value $text
        }
        Lock-ConfigRepositoryObjects 6>$null
        @($script:phaseProofs).Count | Should -Be 2
        $script:phaseProofs[0] | Should -Not -BeNullOrEmpty
        $script:phaseProofs[1] | Should -Be $script:phaseProofs[0]
        { Start-ItlDatabaseAccessHost -Python $python -Request $script:sourceCompetingRequest } | Should -Throw '*WAIT_TIMEOUT*'
        Complete-ItlDevBranchMutationDatabaseAdmission $script:DevBranchMutationDatabaseAdmission
        $next = Start-ItlDatabaseAccessHost -Python $python -Request $script:sourceCompetingRequest
        Complete-ItlDatabaseAccessHost $next | Out-Null
    }

    It 'leaves unsupported repository diagnostics to the action without acquiring a database owner' {
        Mock Get-SourceUsesRepository { $false }
        Mock Start-ItlDatabaseAccessHost { throw 'must not acquire a source owner' }
        Start-ItlDevBranchMutationDatabaseAdmission -Operation 'lock-config-repository-objects' | Should -BeNullOrEmpty
        Should -Invoke Start-ItlDatabaseAccessHost -Times 0 -Exactly
    }

    Context 'source synchronization admits both participants together' {
        BeforeEach {
            $script:PeerDevBranchName = 'itldev/peer'
            $script:mutationState | Add-Member -NotePropertyName devBranchName -NotePropertyValue 'update' -Force
            $script:mutationState | Add-Member -NotePropertyName devBranch -NotePropertyValue 'itldev/update' -Force
            $script:peerRoot = Join-Path $script:ProjectRoot 'Другая ветка'
            New-Item -ItemType Directory -Path $script:peerRoot | Out-Null
            $script:peerState = [pscustomobject]@{devBranch='itldev/peer';devBranchName='peer';worktreePath=$script:peerRoot
                infoBaseKind='file';devBranchInfoBasePath=(Join-Path $script:peerRoot 'Рабочая база')
                vanessaServiceInfoBasePath=(Join-Path $script:peerRoot 'Служебная база')}
            $script:ConfigPath = Join-Path $script:ProjectRoot '.agent-1c/project.json'
            $script:DependencyLockPath = Join-Path $script:ProjectRoot '.agent-1c/dependency-lock.json'
            $script:Config = [pscustomobject]@{}
            Mock Read-DevBranchState { param($Name) if ($Name -eq 'peer') { $script:peerState } else { $script:mutationState } }
            Mock Assert-DevBranchSourceSyncCompatibility { 'src/cf' }
            $peerRequest = @{schemaVersion=1;coordinator=$settings.coordinator;timeout=0
                bases=@(@{kind='file';path=$script:peerState.devBranchInfoBasePath});owner=@{operation='peer-measurement'}}
        }

        It 'waits on the second base without keeping the first or taking local locks' {
            $holder = Start-ItlDatabaseAccessHost -Python $python -Request $peerRequest
            try {
                { Start-ItlDevBranchMutationDatabaseAdmission -Operation sync-dev-branches } | Should -Throw '*WAIT_TIMEOUT*'
                $independent = Start-ItlDatabaseAccessHost -Python $python -Request $competingRequest
                Complete-ItlDatabaseAccessHost $independent | Out-Null
                Test-Path (Join-Path $script:ProjectRoot '.agent-1c/locks/lifecycle.lock') | Should -BeFalse
                Test-Path (Join-Path $script:peerRoot '.agent-1c/locks/lifecycle.lock') | Should -BeFalse
                Should -Invoke Invoke-DevBranchVanessaRuntimeRelease -Times 0
            } finally { Complete-ItlDatabaseAccessHost $holder | Out-Null }
            $script:DevBranchMutationDatabaseAdmission = Start-ItlDevBranchMutationDatabaseAdmission -Operation sync-dev-branches
            $script:DevBranchMutationDatabaseAdmission.plan.bases | Should -HaveCount 4
            { Start-ItlDatabaseAccessHost -Python $python -Request $competingRequest } | Should -Throw '*WAIT_TIMEOUT*'
            { Start-ItlDatabaseAccessHost -Python $python -Request $peerRequest } | Should -Throw '*WAIT_TIMEOUT*'
            Complete-ItlDevBranchMutationDatabaseAdmission $script:DevBranchMutationDatabaseAdmission
            $next = Start-ItlDatabaseAccessHost -Python $python -Request $peerRequest
            Complete-ItlDatabaseAccessHost $next | Out-Null
        }

        It 'uses one reservation when both branches point at the same database and manager' {
            $script:peerState.devBranchInfoBasePath = $script:mutationState.devBranchInfoBasePath
            $script:peerState.vanessaServiceInfoBasePath = $script:mutationState.vanessaServiceInfoBasePath
            $script:DevBranchMutationDatabaseAdmission = Start-ItlDevBranchMutationDatabaseAdmission -Operation sync-dev-branches
            $script:DevBranchMutationDatabaseAdmission.plan.bases | Should -HaveCount 2
            $script:DevBranchMutationDatabaseAdmission.plan.syncParticipants | Should -HaveCount 2
            Invoke-InProjectContext -Root $script:peerRoot -ScriptBlock {
                Assert-ItlBranchSourceSyncDatabaseAdmission -State $script:peerState
            }
        }

        It 'permits the peer drain but never substitutes its reserved manager as a mutation target' {
            $script:DevBranchMutationDatabaseAdmission = Start-ItlDevBranchMutationDatabaseAdmission -Operation sync-dev-branches
            Invoke-InProjectContext -Root $script:peerRoot -ScriptBlock {
                Stop-DevBranchRuntimeBeforeInfobaseMutation -State $script:peerState
                { Stop-DevBranchRuntimeBeforeInfobaseMutation -State $script:peerState -InfoBasePath $script:peerState.vanessaServiceInfoBasePath } | Should -Throw '*NATIVE_TARGET_NOT_RESERVED*'
                { Stop-DevBranchRuntimeBeforeInfobaseMutation -State $script:peerState -InfoBasePath $script:mutationState.devBranchInfoBasePath } | Should -Throw '*NATIVE_TARGET_NOT_RESERVED*'
            }
            Should -Invoke Invoke-DevBranchVanessaRuntimeRelease -Times 1 -Exactly
            Should -Invoke Stop-OneCInfoBaseSessionProcesses -Times 0
        }

        It 'rejects peer <field> drift before cleanup' -TestCases @(
            @{field='devBranchInfoBasePath'}, @{field='vanessaServiceInfoBasePath'}, @{field='devBranch'}
        ) {
            param($field)
            $script:DevBranchMutationDatabaseAdmission = Start-ItlDevBranchMutationDatabaseAdmission -Operation sync-dev-branches
            $script:peerState.$field = Join-Path $script:peerRoot 'Измененный адрес'
            Invoke-InProjectContext -Root $script:peerRoot -ScriptBlock {
                { Stop-DevBranchRuntimeBeforeInfobaseMutation -State $script:peerState } | Should -Throw '*MUTATION_PLAN_CHANGED*'
            }
            Should -Invoke Invoke-DevBranchVanessaRuntimeRelease -Times 0
        }

        It 'rejects different queue authorities and restores environment even when peer planning fails' {
            $saved = [Environment]::GetEnvironmentVariable('ITL_SYNC_PLAN_PEER_ONLY', 'Process')
            try {
                [Environment]::SetEnvironmentVariable('ITL_SYNC_PLAN_PEER_ONLY', $null, 'Process')
                [IO.File]::WriteAllText((Join-Path $script:peerRoot '.dev.env'), 'ITL_SYNC_PLAN_PEER_ONLY=peer')
                Mock Get-ItlDatabaseAccessSettings {
                    if ($script:ProjectRoot -eq $script:peerRoot) {
                        return [pscustomobject]@{coordinator=(Join-Path $script:peerRoot 'Другая очередь');python=$python;waitTimeoutSeconds=0}
                    }
                    $settings
                }
                { Start-ItlDevBranchMutationDatabaseAdmission -Operation sync-dev-branches } | Should -Throw '*SYNC_COORDINATOR_MISMATCH*'
                $script:ProjectRoot | Should -Be $script:mutationState.worktreePath
                [Environment]::GetEnvironmentVariable('ITL_SYNC_PLAN_PEER_ONLY', 'Process') | Should -BeNullOrEmpty
                Should -Invoke Invoke-DevBranchVanessaRuntimeRelease -Times 0
            } finally { [Environment]::SetEnvironmentVariable('ITL_SYNC_PLAN_PEER_ONLY', $saved, 'Process') }
        }

        It 'requires an aggregate admission for direct synchronization before changing source' {
            Mock Assert-DevBranchSourceSyncLifecycleReady {}
            Mock Save-DevBranchCheckpoint { throw 'must not modify source' }
            { Sync-DevBranches } | Should -Throw '*MUTATION_ADMISSION_REQUIRED*'
            Should -Invoke Save-DevBranchCheckpoint -Times 0
        }

        Context 'group admission' {
            BeforeEach {
                $script:PeerDevBranchName = ''
                $script:thirdRoot = Join-Path $script:mutationState.worktreePath 'Третья ветка'
                New-Item -ItemType Directory -Path $script:thirdRoot | Out-Null
                $script:thirdState = [pscustomobject]@{devBranch='itldev/third';devBranchName='third';worktreePath=$script:thirdRoot
                    infoBaseKind='file';devBranchInfoBasePath=(Join-Path $script:thirdRoot 'Рабочая база')
                    vanessaServiceInfoBasePath=(Join-Path $script:thirdRoot 'Служебная база')}
                Mock Read-DevBranchState {
                    param($Name)
                    switch ($Name) { 'peer' { $script:peerState }; 'third' { $script:thirdState }; default { $script:mutationState } }
                }
                $script:BranchSyncRequestPath = Join-Path $script:ProjectRoot '.agent-1c/group.json'
                Write-Utf8Text -Path $script:BranchSyncRequestPath -Value (@{schemaVersion=1;peers=@('peer','third');recipients=@('update','peer','third')} | ConvertTo-Json)
                $thirdRequest = @{schemaVersion=1;coordinator=$settings.coordinator;timeout=0
                    bases=@(@{kind='file';path=$script:thirdState.devBranchInfoBasePath});owner=@{operation='third-measurement'}}
            }
            AfterEach { $script:BranchSyncRequestPath = '' }

            It 'waits on the last participant without retaining earlier databases and admits all six resources after release' {
                $holder = Start-ItlDatabaseAccessHost -Python $python -Request $thirdRequest
                try {
                    { Start-ItlDevBranchMutationDatabaseAdmission -Operation sync-dev-branches } | Should -Throw '*WAIT_TIMEOUT*'
                    foreach ($request in @($competingRequest, $peerRequest)) {
                        $independent = Start-ItlDatabaseAccessHost -Python $python -Request $request
                        Complete-ItlDatabaseAccessHost $independent | Out-Null
                    }
                    foreach ($root in @($script:mutationState.worktreePath,$script:peerRoot,$script:thirdRoot)) {
                        Test-Path (Join-Path $root '.agent-1c/locks/lifecycle.lock') | Should -BeFalse
                    }
                    Should -Invoke Invoke-DevBranchVanessaRuntimeRelease -Times 0
                } finally { Complete-ItlDatabaseAccessHost $holder | Out-Null }
                $script:DevBranchMutationDatabaseAdmission = Start-ItlDevBranchMutationDatabaseAdmission -Operation sync-dev-branches
                $script:DevBranchMutationDatabaseAdmission.plan.bases | Should -HaveCount 6
                $script:DevBranchMutationDatabaseAdmission.plan.syncParticipants | Should -HaveCount 3
                { Start-ItlDatabaseAccessHost -Python $python -Request $thirdRequest } | Should -Throw '*WAIT_TIMEOUT*'
                Complete-ItlDevBranchMutationDatabaseAdmission $script:DevBranchMutationDatabaseAdmission
                $next = Start-ItlDatabaseAccessHost -Python $python -Request $thirdRequest
                Complete-ItlDatabaseAccessHost $next | Out-Null
            }

            It 'rejects a changed manager in the last participant before draining any runtime' {
                $script:DevBranchMutationDatabaseAdmission = Start-ItlDevBranchMutationDatabaseAdmission -Operation sync-dev-branches
                $script:thirdState.vanessaServiceInfoBasePath = Join-Path $script:thirdRoot 'Другой менеджер'
                Invoke-InProjectContext -Root $script:thirdRoot -ScriptBlock {
                    { Stop-DevBranchRuntimeBeforeInfobaseMutation -State $script:thirdState } | Should -Throw '*MUTATION_PLAN_CHANGED*'
                }
                Should -Invoke Invoke-DevBranchVanessaRuntimeRelease -Times 0
            }
        }
    }

    It 'includes repository locking in the same pre-lifecycle admission route' {
        $entry = Get-Content (Join-Path $repo '.agents/skills/1c-workflow/scripts/agent-1c.ps1') -Raw -Encoding UTF8
        $operations = @('update-dev-branch-base', 'lock-config-repository-objects', 'check-dev-branch', 'verify-dev-branch', 'update-auxiliary-contour', 'check-auxiliary-contour', 'dump-auxiliary-contour', 'export-auxiliary-contour-result', 'reset-auxiliary-contour', 'export-dev-branch-result', 'dump-dev-branch-extension', 'repair-dev-branch-tooling', 'init-dev-branch-extension', 'release-e2e-extension-smoke', 'reset-dev-branch', 'refresh-dev-branch-lite', 'refresh-dev-branch', 'sync-master', 'update1cbase', 'loadfrom1cbase', 'getconfigfiles', 'deploy-and-test', 'sync-dev-branches', 'initialize-dev-branch-runtime', 'adopt-dev-worktree', 'new-dev-branch', 'new-extension-dev-branch', 'fork-dev-branch', 'init-project')
        $entry | Should -Match ([regex]::Escape("if (`$requestedLifecycleAction -in @('" + ($operations -join "', '") + "'))"))
        foreach ($command in @('Get-ItlDevBranchMutationDatabasePlan', 'Start-ItlDevBranchMutationDatabaseAdmission')) {
            $supported = (Get-Command $command).Parameters['Operation'].Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } | ForEach-Object ValidValues
            @($supported | Sort-Object) | Should -Be @($operations | Sort-Object)
        }
    }
}
