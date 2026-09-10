Describe 'Master synchronization shares admission with branch refresh' {
    BeforeAll {
        Set-StrictMode -Version Latest
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        . $context.HelperPath -ProjectRoot $context.RepoRoot -Action help *> $null
        . (Join-Path $context.RepoRoot '.agents/skills/itl-remote-runner/scripts/DatabaseAccess.ps1')
        $python = (Get-Command python -CommandType Application | Select-Object -First 1).Source
    }
    BeforeEach {
        $savedEnvironment = [Environment]::GetEnvironmentVariables('Process')
        foreach ($name in @('ITL_INFOBASE_ACCESS_LEASE','ITL_DATABASE_CONTINUATION','BRANCH_SEED_ROOT','ITL_MASTER_PLAN_PROBE')) {
            [Environment]::SetEnvironmentVariable($name,$null,'Process')
        }
        $fixtureRoot = Join-Path $TestDrive ('Синхронизация общей базы ' + [guid]::NewGuid().ToString('N'))
        $script:masterRoot = Join-Path $fixtureRoot 'Главная ветка'
        $script:branchRoot = Join-Path $fixtureRoot 'Рабочая ветка'
        foreach ($root in @($masterRoot,$branchRoot)) {
            New-Item -ItemType Directory -Path (Join-Path $root '.agent-1c') -Force | Out-Null
            [IO.File]::WriteAllText((Join-Path $root '.agent-1c/project.json'),'{}',[Text.UTF8Encoding]::new($false))
        }
        $script:sourcePath = Join-Path $fixtureRoot 'Исходная общая база'
        $script:masterEnvPath = Join-Path $masterRoot '.dev.env'
        [IO.File]::WriteAllText($masterEnvPath,"INFOBASE_KIND=file`nSOURCE_INFOBASE_PATH=$sourcePath`nBRANCH_SEED_ROOT=Общий seed`nITL_MASTER_PLAN_PROBE=main-only`n",[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $branchRoot '.dev.env'),"INFOBASE_KIND=file`nSOURCE_INFOBASE_PATH=Исходный контекст ветки`n",[Text.UTF8Encoding]::new($false))
        $script:ProjectRoot = $branchRoot
        $script:ConfigPath = Join-Path $branchRoot '.agent-1c/project.json'
        $script:DependencyLockPath = Join-Path $branchRoot '.agent-1c/dependency-lock.json'
        $script:Config = [pscustomobject]@{source='branch-context'}
        Import-DotEnv -Path (Join-Path $branchRoot '.dev.env') -Overwrite
        $script:DevBranchMutationDatabaseAdmission = $null
        $script:OneCNativeOperationJournal = $null
        $script:DevBranchName = 'refresh'
        $script:DatabaseContinuationProtocol = 0
        $script:masterSettings = [pscustomobject]@{coordinator=(Join-Path $fixtureRoot 'Координатор');python=$python;waitTimeoutSeconds=0}
        $script:branchState = [pscustomobject]@{infoBaseKind='file';devBranchInfoBasePath=(Join-Path $branchRoot 'База ветки');mainWorktreePath=$masterRoot}
        Mock Get-MainWorktreePath { $script:masterRoot }
        Mock Get-ItlDatabaseAccessSettings { $script:masterSettings }
        Mock Get-ItlOnDemandRuntimeInstances { @() }
        Mock Read-DevBranchState { $script:branchState }
        Mock Assert-DevelopmentBranchWorktreeContext {}
        Mock Read-VanessaTestClientManifest { throw 'master synchronization does not run tests' }
        Mock Invoke-Designer { throw 'no native execution in admission fixture' }
        Mock Get-OneCInfoBaseSessionProcesses { @() }
        Mock Set-RunStage {}
    }
    AfterEach {
        try { Complete-ItlDevBranchMutationDatabaseAdmission $script:DevBranchMutationDatabaseAdmission }
        finally {
            Restore-ItlProcessEnvironment -Snapshot $savedEnvironment
        }
    }

    It 'plans the actual master context and restores every caller environment key on <outcome>' -TestCases @(
        @{outcome='success'}, @{outcome='invalid master config'}
    ) {
        param($outcome)
        $beforeEnvironment = [Environment]::GetEnvironmentVariables('Process')
        $beforeConfig = $script:Config
        if ($outcome -eq 'invalid master config') {
            [IO.File]::WriteAllText((Join-Path $masterRoot '.agent-1c/project.json'),'{broken')
            { Get-ItlMasterDatabasePlan } | Should -Throw
        } else {
            $plan = Get-ItlMasterDatabasePlan
            $plan.project | Should -Be $masterRoot
            $plan.source.path | Should -Be $sourcePath
            $plan.bases | Should -HaveCount 2
            $plan.bases[1].path | Should -BeLike (Join-Path $masterRoot 'Общий seed/*/infobase')
        }
        $script:ProjectRoot | Should -Be $branchRoot
        $script:ConfigPath | Should -Be (Join-Path $branchRoot '.agent-1c/project.json')
        $script:Config | Should -Be $beforeConfig
        $afterEnvironment = [Environment]::GetEnvironmentVariables('Process')
        @($afterEnvironment.Keys | Sort-Object) | Should -Be @($beforeEnvironment.Keys | Sort-Object)
        foreach ($key in $beforeEnvironment.Keys) { $afterEnvironment[$key] | Should -BeExactly $beforeEnvironment[$key] }
    }

    It '<operation> reserves source and seed before any native work, with branch resources only for refresh' -TestCases @(
        @{operation='sync-master';count=2}, @{operation='refresh-dev-branch';count=5}
    ) {
        param($operation,$count)
        $script:DevBranchMutationDatabaseAdmission = Start-ItlDevBranchMutationDatabaseAdmission -Operation $operation
        $admission = $script:DevBranchMutationDatabaseAdmission
        $admission.plan.bases | Should -HaveCount $count
        $admission.plan.bases.path | Should -Contain $sourcePath
        $admission.plan.masterPlan.project | Should -Be $masterRoot
        Assert-ItlDevBranchMutationDatabaseAdmission -Admission $admission -State (Get-ItlDevBranchMutationDatabaseState -Operation $operation)
        foreach ($base in $admission.plan.bases) {
            { Start-ItlDatabaseAccessHost -Python $python -Request @{schemaVersion=1;coordinator=$masterSettings.coordinator;bases=@($base);owner=@{operation='another-project'};timeout=0} } | Should -Throw '*WAIT_TIMEOUT*'
        }
        if ($operation -eq 'sync-master') {
            Should -Invoke Read-DevBranchState -Times 0
            $other = Start-ItlDatabaseAccessHost -Python $python -Request @{schemaVersion=1;coordinator=$masterSettings.coordinator;bases=@(@{kind='file';path=$branchState.devBranchInfoBasePath});owner=@{};timeout=0}
            Complete-ItlDatabaseAccessHost $other | Out-Null
        } else { $admission.plan.bases.path | Should -Contain $branchState.devBranchInfoBasePath }
        Should -Invoke Invoke-Designer -Times 0
        Publish-ItlDevBranchLifecycleCompletion -Admission $admission
        $ticketPath = Join-Path $masterSettings.coordinator ('tickets/' + $admission.owner.proof.ticket + '.json')
        $ticket = Get-Content -LiteralPath $ticketPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $ticket.status | Should -Be 'running'
        @($ticket.nativeJournal.producers.PSObject.Properties)[0].Value.completion.sha256 | Should -Match '^[a-f0-9]{64}$'
        Complete-ItlDevBranchMutationDatabaseAdmission $admission
        $next = Start-ItlDatabaseAccessHost -Python $python -Request @{schemaVersion=1;coordinator=$masterSettings.coordinator;bases=@($admission.plan.masterPlan.bases);owner=@{operation='next-sync'};timeout=0}
        Complete-ItlDatabaseAccessHost $next | Out-Null
    }

    It 'rejects a source change after preparation while retaining the original reservation' {
        $preparation = Get-ItlDevBranchMutationAdmissionPreparation -Operation sync-master
        $script:DevBranchMutationDatabaseAdmission = Start-ItlDevBranchMutationDatabaseAdmission -Operation sync-master -Preparation $preparation
        [IO.File]::WriteAllText($masterEnvPath,"INFOBASE_KIND=file`nSOURCE_INFOBASE_PATH=$(Join-Path $masterRoot 'Другая база')`n",[Text.UTF8Encoding]::new($false))
        { Assert-ItlDevBranchMutationDatabaseAdmission -Admission $script:DevBranchMutationDatabaseAdmission -State $null } | Should -Throw '*MUTATION_PLAN_CHANGED*'
        Should -Invoke Invoke-Designer -Times 0
    }

    It 'preserves empty Windows environment values both unchanged and overwritten by master planning' {
        $snapshot = [Environment]::GetEnvironmentVariables('Process')
        $snapshot['ITL_MASTER_PLAN_PROBE'] = ''
        $snapshot['ITL_UNCHANGED_EMPTY_PROBE'] = ''
        Restore-ItlProcessEnvironment -Snapshot $snapshot
        $before = [Environment]::GetEnvironmentVariables('Process')
        foreach ($key in @('ITL_MASTER_PLAN_PROBE', 'ITL_UNCHANGED_EMPTY_PROBE')) {
            $before.Contains($key) | Should -BeTrue
            $before[$key] | Should -BeExactly ''
        }
        $plan = Get-ItlMasterDatabasePlan
        $plan.source.path | Should -Be $sourcePath
        $after = [Environment]::GetEnvironmentVariables('Process')
        @($after.Keys | Sort-Object) | Should -Be @($before.Keys | Sort-Object)
        foreach ($key in $before.Keys) { $after[$key] | Should -BeExactly $before[$key] }
    }

    It 'does not reserve a fictitious file seed database for a server source' {
        $server = 'Srvr="test-server";Ref="Общая серверная база";'
        [IO.File]::WriteAllText($masterEnvPath,"INFOBASE_KIND=server`nSOURCE_INFOBASE_PATH=$server`n",[Text.UTF8Encoding]::new($false))
        $plan = Get-ItlMasterDatabasePlan
        $plan.bases | Should -HaveCount 1
        $plan.source.kind | Should -Be 'server'
        $plan.source.path | Should -Be $server
    }

    It 'waits for a foreign file-seed session before touching the previous artifact or manifest' {
        $script:DevBranchMutationDatabaseAdmission = Start-ItlDevBranchMutationDatabaseAdmission -Operation sync-master
        $script:seedDatabasePath = $script:DevBranchMutationDatabaseAdmission.plan.masterPlan.bases[1].path
        New-Item -ItemType Directory -Path $seedDatabasePath -Force | Out-Null
        $artifact = Join-Path $seedDatabasePath '1Cv8.1CD'
        [IO.File]::WriteAllBytes($artifact,[byte[]](1,2,3,4))
        $manifest = Join-Path (Split-Path $seedDatabasePath) 'manifest.json'
        [IO.File]::WriteAllText($manifest,'{"status":"ready","sentinel":"previous seed"}')
        Mock Get-OneCInfoBaseSessionProcesses { param($InfoBaseKind,$InfoBasePath) if ($InfoBasePath -eq $script:seedDatabasePath) { [pscustomobject]@{ProcessId=12345} } }
        Mock Open-BranchSeedWriterIntent { throw 'must wait before publishing seed writer intent' }
        Mock Stop-OneCInfoBaseSessionProcesses { throw 'foreign process must stay untouched' }
        Invoke-InProjectContext -Root $masterRoot -ScriptBlock {
            { New-BranchSeed -ConfigurationFingerprint 'candidate' } | Should -Throw '*EXTERNAL_SESSIONS_WAIT_TIMEOUT*'
        }
        [IO.File]::ReadAllBytes($artifact) | Should -Be @([byte]1,[byte]2,[byte]3,[byte]4)
        [IO.File]::ReadAllText($manifest) | Should -Be '{"status":"ready","sentinel":"previous seed"}'
        Should -Invoke Open-BranchSeedWriterIntent -Times 0
        Should -Invoke Invoke-Designer -Times 0
        Should -Invoke Stop-OneCInfoBaseSessionProcesses -Times 0
    }

    It 'checks the master connection again after clearing branch context and before a repository update' {
        $script:DevBranchMutationDatabaseAdmission = Start-ItlDevBranchMutationDatabaseAdmission -Operation sync-master
        Mock Assert-CleanGit {}
        Mock Checkout-Master {}
        Mock Clear-DevBranchContext { $env:SOURCE_INFOBASE_PATH = Join-Path $script:masterRoot 'Подмененный источник' }
        Mock Update-BaseFromRepository { throw 'must reject source drift before repository mutation' }
        Invoke-InProjectContext -Root $masterRoot -ScriptBlock {
            { Sync-Master -NoDelegate } | Should -Throw '*MASTER_PLAN_CHANGED*'
        }
        Should -Invoke Update-BaseFromRepository -Times 0
        Should -Invoke Invoke-Designer -Times 0
    }
}
