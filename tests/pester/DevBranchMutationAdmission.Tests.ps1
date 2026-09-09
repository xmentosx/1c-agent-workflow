Describe 'Development database update owns shared admission before native work' {
    BeforeAll {
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
        $script:mutationRuntimes = @()
        $script:mutationExternalSessions = @()
        $settings = [pscustomobject]@{ coordinator=(Join-Path $script:ProjectRoot 'Общий координатор'); python=$python; waitTimeoutSeconds=0 }
        $originalProof = [Environment]::GetEnvironmentVariable('ITL_INFOBASE_ACCESS_LEASE', 'Process')
        [Environment]::SetEnvironmentVariable('ITL_INFOBASE_ACCESS_LEASE', $null, 'Process')
        Mock Get-ItlDatabaseAccessSettings { $settings }
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
}
