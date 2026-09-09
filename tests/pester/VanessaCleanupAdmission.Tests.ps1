Describe 'Vanessa cleanup database admission' {
    BeforeAll {
        $repo = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
        $lib = Join-Path $repo '.agents/skills/1c-workflow/scripts/lib'
        foreach ($name in @('core', 'runtime-values', 'lifecycle', 'roctup-mcp', 'vanessa', 'ondemand-mcp')) {
            . (Join-Path $lib ("agent-1c.$name.ps1"))
        }
        . (Join-Path $repo '.agents/skills/itl-remote-runner/scripts/DatabaseAccess.ps1')
        $python = (Get-Command python -CommandType Application | Select-Object -First 1).Source
    }
    BeforeEach {
        $script:ProjectRoot = Join-Path $TestDrive ('Очистка общей базы ' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:ProjectRoot | Out-Null
        $script:DevBranchName = 'cleanup'
        $script:VanessaCleanupDatabaseAdmission = $null
        $script:cleanupState = [pscustomobject]@{infoBaseKind='file';devBranchInfoBasePath=(Join-Path $script:ProjectRoot 'Целевая база');vanessaServiceInfoBasePath=(Join-Path $script:ProjectRoot 'Служебная база');worktreePath=$script:ProjectRoot}
        $script:cleanupRuntimes = @()
        $settings = [pscustomobject]@{coordinator=(Join-Path $script:ProjectRoot 'Общий координатор');python=$python;waitTimeoutSeconds=0}
        Mock Get-ItlDatabaseAccessSettings { $settings }
        Mock Read-DevBranchState { $script:cleanupState }
        Mock Assert-DevelopmentBranchWorktreeContext { }
        Mock Get-ItlOnDemandRuntimeInstances { $script:cleanupRuntimes }
        Mock Test-VanessaInteractiveProfileHasOwner { $false }
        Mock Invoke-DevBranchVanessaRuntimeRelease { [pscustomobject]@{status='released'} }
        $competingRequest = [ordered]@{schemaVersion=1;coordinator=$settings.coordinator;timeout=0;bases=@(@{kind='file';path=$script:cleanupState.devBranchInfoBasePath});owner=@{operation='competing-cleanup'}}
    }
    AfterEach {
        if ($null -ne $script:VanessaCleanupDatabaseAdmission -and -not $script:VanessaCleanupDatabaseAdmission.completed) {
            Complete-ItlVanessaCleanupDatabaseAdmission $script:VanessaCleanupDatabaseAdmission
        }
    }

    It 'reserves the target and recorded manager databases and excludes unrelated runtimes' {
        $manager = Join-Path $script:ProjectRoot 'Старый менеджер'
        $script:cleanupRuntimes = @(
            [pscustomobject]@{family='vanessa-ui';infoBasePath=$script:cleanupState.devBranchInfoBasePath;infoBaseKind='file';managerInfoBasePath=$manager;managerInfoBaseKind='file'},
            [pscustomobject]@{family='vanessa-ui';infoBasePath=(Join-Path $TestDrive 'Чужая база');infoBaseKind='file';managerInfoBasePath=(Join-Path $TestDrive 'Чужой менеджер');managerInfoBaseKind='file'}
        )
        $plan = Get-ItlVanessaCleanupDatabasePlan $script:cleanupState
        $plan.bases.Count | Should -Be 3
        @($plan.bases.path) | Should -Contain $manager
        @($plan.bases.path) | Should -Not -Contain (Join-Path $TestDrive 'Чужая база')
        $script:VanessaCleanupDatabaseAdmission = Start-ItlVanessaCleanupDatabaseAdmission
        { Start-ItlDatabaseAccessHost -Python $python -Request $competingRequest } | Should -Throw '*WAIT_TIMEOUT*'
        Stop-DevBranchTestClients
        Complete-ItlVanessaCleanupDatabaseAdmission $script:VanessaCleanupDatabaseAdmission
        $next = Start-ItlDatabaseAccessHost -Python $python -Request $competingRequest
        try { (Complete-ItlDatabaseAccessHost $next).status | Should -Be released } finally { Close-ItlDatabaseAccessHost $next }
        Should -Invoke Invoke-DevBranchVanessaRuntimeRelease -Times 1
    }

    It 'waits on the database without taking local locks or stopping native clients' {
        $holder = Start-ItlDatabaseAccessHost -Python $python -Request $competingRequest
        try {
            { Start-ItlVanessaCleanupDatabaseAdmission } | Should -Throw '*WAIT_TIMEOUT*'
            Test-Path -LiteralPath (Join-Path $script:ProjectRoot '.agent-1c/locks/lifecycle.lock') | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $script:ProjectRoot '.agent-1c/locks/runtime-mcp.lock') | Should -BeFalse
            Should -Invoke Invoke-DevBranchVanessaRuntimeRelease -Times 0
        } finally { Complete-ItlDatabaseAccessHost $holder | Out-Null }
    }

    It 'rejects a new manager after waiting and releases the proven unstarted operation' {
        $script:VanessaCleanupDatabaseAdmission = Start-ItlVanessaCleanupDatabaseAdmission
        $script:cleanupState.vanessaServiceInfoBasePath = Join-Path $script:ProjectRoot 'Замененный менеджер'
        { Stop-DevBranchTestClients } | Should -Throw '*CLEANUP_PLAN_CHANGED*'
        Should -Invoke Invoke-DevBranchVanessaRuntimeRelease -Times 0
        Complete-ItlVanessaCleanupDatabaseAdmission $script:VanessaCleanupDatabaseAdmission
        $next = Start-ItlDatabaseAccessHost -Python $python -Request $competingRequest
        try { (Complete-ItlDatabaseAccessHost $next).status | Should -Be released } finally { Close-ItlDatabaseAccessHost $next }
    }

    It 'retains recovery debt when native cleanup cannot be confirmed' {
        $script:VanessaCleanupDatabaseAdmission = Start-ItlVanessaCleanupDatabaseAdmission
        Mock Invoke-DevBranchVanessaRuntimeRelease { throw 'native stop failed' }
        { Stop-DevBranchTestClients } | Should -Throw '*native stop failed*'
        { Complete-ItlVanessaCleanupDatabaseAdmission $script:VanessaCleanupDatabaseAdmission } | Should -Throw '*NATIVE_CLEANUP_UNCONFIRMED*'
        { Start-ItlDatabaseAccessHost -Python $python -Request $competingRequest } | Should -Throw '*RECOVERY_REQUIRED*'
    }

    It 'delegates explicit profile stop before admission and never falls back after its failure' {
        Mock Test-VanessaInteractiveProfileHasOwner { $true }
        Mock Stop-DevBranchVanessaInteractiveProfile {
            Test-Path -LiteralPath $settings.coordinator | Should -BeFalse
            throw 'profile cleanup unconfirmed'
        }
        { Start-ItlVanessaCleanupDatabaseAdmission } | Should -Throw '*profile cleanup unconfirmed*'
        Should -Invoke Invoke-DevBranchVanessaRuntimeRelease -Times 0
        Test-Path -LiteralPath $settings.coordinator | Should -BeFalse
    }

    It 'reuses a live outer reservation and never releases that parent on cleanup' {
        $competingRequest.bases += @{kind='file';path=$script:cleanupState.vanessaServiceInfoBasePath}
        $parent = Start-ItlDatabaseAccessHost -Python $python -Request $competingRequest
        $previous = [Environment]::GetEnvironmentVariable('ITL_INFOBASE_ACCESS_LEASE', 'Process')
        try {
            [Environment]::SetEnvironmentVariable('ITL_INFOBASE_ACCESS_LEASE', ($parent.proof | ConvertTo-Json -Compress -Depth 10), 'Process')
            $script:VanessaCleanupDatabaseAdmission = Start-ItlVanessaCleanupDatabaseAdmission
            Stop-DevBranchTestClients
            Complete-ItlVanessaCleanupDatabaseAdmission $script:VanessaCleanupDatabaseAdmission
            Assert-ItlDatabaseAccessHost $parent
            { Start-ItlDatabaseAccessHost -Python $python -Request $competingRequest } | Should -Throw '*WAIT_TIMEOUT*'
        } finally {
            [Environment]::SetEnvironmentVariable('ITL_INFOBASE_ACCESS_LEASE', $previous, 'Process')
            Complete-ItlDatabaseAccessHost $parent | Out-Null
        }
    }

    It 'finishes owner-mediated profile stop before taking a new cleanup reservation' {
        $script:profileStopFinished = $false
        Mock Test-VanessaInteractiveProfileHasOwner { $true }
        Mock Stop-DevBranchVanessaInteractiveProfile {
            Test-Path -LiteralPath $settings.coordinator | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $script:ProjectRoot '.agent-1c/locks/runtime-mcp.lock') | Should -BeFalse
            $script:profileStopFinished = $true
        }
        $script:VanessaCleanupDatabaseAdmission = Start-ItlVanessaCleanupDatabaseAdmission
        $script:profileStopFinished | Should -BeTrue
        Assert-ItlDatabaseAccessHost $script:VanessaCleanupDatabaseAdmission.owner
        Complete-ItlVanessaCleanupDatabaseAdmission $script:VanessaCleanupDatabaseAdmission
    }

    It 'keeps database admission before the actual helper lifecycle entrypoint' {
        $source = Get-Content -LiteralPath (Join-Path $repo '.agents/skills/1c-workflow/scripts/agent-1c.ps1') -Raw
        $source.IndexOf('$script:VanessaCleanupDatabaseAdmission = Start-ItlVanessaCleanupDatabaseAdmission') | Should -BeLessThan $source.IndexOf('    Enter-Agent1cLifecycleOperation `')
    }
}
