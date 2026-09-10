Describe 'Explicit group source propagation and durable recipient progress' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        . $context.HelperPath -ProjectRoot $context.RepoRoot -Action help *> $null
        # Dot-sourcing introduces parameter locals in Pester's shared parent
        # scope. Let each case's script variables provide the invocation inputs.
        Remove-Variable BranchSyncRequestPath, DevBranchName, PeerDevBranchName -Scope Local
        $script:groupSaveImplementation = (Get-Command Save-BranchSourceSyncGroupPlan).ScriptBlock
    }
    BeforeEach {
        $script:groupRoot = Join-Path $TestDrive ('Группа веток ' + [guid]::NewGuid().ToString('N'))
        $script:primaryRoot = Join-Path $script:groupRoot 'Основная ветка'
        New-Item -ItemType Directory -Path (Join-Path $script:primaryRoot 'src/cf') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:primaryRoot 'docs') -Force | Out-Null
        Write-Utf8Text -Path (Join-Path $script:primaryRoot '.gitignore') -Value ".agent-1c/`n"
        Write-Utf8Text -Path (Join-Path $script:primaryRoot '.gitattributes') -Value "src/cf/** -text`n"
        Write-Utf8Text -Path (Join-Path $script:primaryRoot 'src/cf/Configuration.xml') -Value '<Configuration />'
        Write-Utf8Text -Path (Join-Path $script:primaryRoot 'src/cf/ConfigDumpInfo.xml') -Value 'base cursor'
        Write-Utf8Text -Path (Join-Path $script:primaryRoot 'src/cf/Общий модуль.bsl') -Value "База`r`n"
        Write-Utf8Text -Path (Join-Path $script:primaryRoot 'docs/local.txt') -Value 'base docs'
        Invoke-GitAt -Root $script:primaryRoot -Arguments @('init', '--quiet', '-b', 'itldev/primary')
        Invoke-GitAt -Root $script:primaryRoot -Arguments @('config', 'user.name', 'ITL fixture')
        Invoke-GitAt -Root $script:primaryRoot -Arguments @('config', 'user.email', 'itl@example.invalid')
        Invoke-GitAt -Root $script:primaryRoot -Arguments @('add', '.')
        Invoke-GitAt -Root $script:primaryRoot -Arguments @('commit', '--quiet', '-m', 'base')
        $script:groupProjects = [ordered]@{primary=$script:primaryRoot;'peer-a'=(Join-Path $script:groupRoot 'Ветка А');'peer-b'=(Join-Path $script:groupRoot 'Ветка Б')}
        foreach ($name in @('peer-a','peer-b')) {
            Invoke-GitAt -Root $script:primaryRoot -Arguments @('worktree', 'add', '--quiet', '-b', "itldev/$name", $script:groupProjects[$name], 'HEAD')
        }
        $script:groupHeads = @{}
        foreach ($name in $script:groupProjects.Keys) {
            $root = $script:groupProjects[$name]
            Write-Utf8Text -Path (Join-Path $root "src/cf/$name.bsl") -Value "Изменение $name`r`n"
            Write-Utf8Text -Path (Join-Path $root 'src/cf/ConfigDumpInfo.xml') -Value "cursor-$name"
            Write-Utf8Text -Path (Join-Path $root 'docs/local.txt') -Value "docs-$name"
            Invoke-GitAt -Root $root -Arguments @('add', 'src', 'docs')
            Invoke-GitAt -Root $root -Arguments @('commit', '--quiet', '-m', "$name input")
            $script:groupHeads[$name] = ([string](Get-GitOutputAt -Root $root -Arguments @('rev-parse','HEAD'))).Trim()
            $state = [pscustomobject]@{devBranchName=$name;devBranch="itldev/$name";worktreePath=$root;devBranchKind='configuration'
                initializationStatus='ready';infoBaseKind='file';devBranchInfoBasePath=(Join-Path $root 'База данных')}
            Write-Utf8Text -Path (Join-Path $root '.agent-1c/fixture-state.json') -Value ($state | ConvertTo-Json)
        }
        $script:DevBranchName = 'primary'; $script:PeerDevBranchName = ''
        $script:BranchSyncRequestPath = Join-Path $script:primaryRoot '.agent-1c/group-request.json'
        Write-Utf8Text -Path $script:BranchSyncRequestPath -Value (@{schemaVersion=1;peers=@('peer-a','peer-b');recipients=@('primary','peer-a','peer-b')} | ConvertTo-Json)
        Set-ProjectContext -Root $script:primaryRoot
        $script:groupLoads = @(); $script:groupReport = ''; $script:groupFailWrites = $false
        Mock Read-DevBranchState {
            param($Name)
            if (-not $Name) { $Name = (Get-CurrentBranch) -replace '^itldev/', '' }
            (Read-Utf8Text -Path (Join-Path $script:groupProjects[$Name] '.agent-1c/fixture-state.json')) | ConvertFrom-Json
        }
        Mock Update-DevBranchState {
            param($State, $Updates)
            foreach ($key in $Updates.Keys) { $State | Add-Member -NotePropertyName $key -NotePropertyValue $Updates[$key] -Force }
            Write-Utf8TextAtomic -Path (Join-Path $State.worktreePath '.agent-1c/fixture-state.json') -Value ($State | ConvertTo-Json -Depth 20)
        }
        Mock Get-ExportPath { 'src/cf' }
        Mock Ensure-GitIgnore {}
        Mock Repair-OneCSourceLineEndings {}
        # This fixture exercises real Git/transport/state recovery. The 1C
        # metadata validator and native database load have separate owners.
        Mock Assert-OneCConfigurationSourceIntegrity {}
        Mock Assert-DevBranchSourceSyncLifecycleReady {}
        Mock Get-ItlOnDemandRuntimeInstances { @() }
        Mock Get-ItlDatabaseAccessSettings { [pscustomobject]@{coordinator=(Join-Path $script:groupRoot 'Общая очередь');waitTimeoutSeconds=0;python=''} }
        Mock Assert-ItlBranchSourceSyncDatabaseAdmission {
            param($State)
            @($script:DevBranchMutationDatabaseAdmission.plan.syncParticipants | Where-Object { $_.branch -ceq $State.devBranch -and $_.project -ieq $script:ProjectRoot }).Count | Should -Be 1
        }
        Mock Invoke-BranchSourceSyncLoad {
            param($State, $ExportPath, $OtherBranch, $GroupId)
            $script:groupLoads += $State.devBranchName
            $fingerprint = [string](Get-ConfigSourceFingerprint -ExportPath $ExportPath).fingerprint
            Update-DevBranchState -State $State -Updates @{lastBranchSourceSyncGroupId=$GroupId;lastBranchSourceSyncGroupFingerprint=$fingerprint;lastBranchSourceSyncGroupCommit=(Get-CurrentCommit)}
            [pscustomobject]@{sourceFingerprint=$fingerprint;currentCommit=(Get-CurrentCommit)}
        }
        Mock Set-RunStage {}
        Mock Set-RunFailureContext {}
        Mock Write-AndSetRunUserReport { param($Lines) $script:groupReport = $Lines -join "`n" }
        $script:DevBranchMutationDatabaseAdmission = [pscustomobject]@{operation='sync-dev-branches';plan=(Get-ItlBranchSourceSyncDatabasePlan -State (Read-DevBranchState -Name primary));completed=$false}
    }
    AfterEach {
        $script:BranchSyncRequestPath = ''
        $script:DevBranchMutationDatabaseAdmission = $null
        Set-ProjectContext -Root $context.RepoRoot
    }

    It 'delivers the final union to all three recipients once with independent commits and original cursors' {
        Sync-DevBranches
        $script:groupLoads | Should -Be @('primary','peer-a','peer-b')
        $fingerprints = @()
        foreach ($name in $script:groupProjects.Keys) {
            Invoke-BranchSourceSyncProject -Root $script:groupProjects[$name] -ScriptBlock {
                foreach ($source in $script:groupProjects.Keys) { Test-Path (Join-Path $script:ProjectRoot "src/cf/$source.bsl") | Should -BeTrue }
                Read-Utf8Text (Join-Path $script:ProjectRoot 'src/cf/ConfigDumpInfo.xml') | Should -Be "cursor-$name"
                Read-Utf8Text (Join-Path $script:ProjectRoot 'docs/local.txt') | Should -Be "docs-$name"
                $parents = ([string](Get-GitOutput @('rev-list','--parents','-n','1','HEAD'))).Trim() -split ' '
                $parents | Should -HaveCount 2
                $parents[1] | Should -Be $script:groupHeads[$name]
                Assert-CleanGit
            }
            $fingerprints += Invoke-BranchSourceSyncProject -Root $script:groupProjects[$name] -ScriptBlock { [string](Get-ConfigSourceFingerprint -ExportPath 'src/cf').fingerprint }
        }
        @($fingerprints | Sort-Object -Unique) | Should -HaveCount 1
        (Read-DevBranchState -Name primary).pendingBranchSourceGroupId | Should -BeNullOrEmpty
        $script:groupReport | Should -Match 'успешно'
    }

    It 'collects both peer inputs into the initiator without distributing to unselected peers' {
        Write-Utf8Text -Path $script:BranchSyncRequestPath -Value (@{schemaVersion=1;peers=@('peer-a','peer-b');recipients=@('primary')} | ConvertTo-Json)
        $script:DevBranchMutationDatabaseAdmission.plan = Get-ItlBranchSourceSyncDatabasePlan -State (Read-DevBranchState -Name primary)
        Sync-DevBranches
        $script:groupLoads | Should -Be @('primary')
        foreach ($name in @('peer-a','peer-b')) {
            ([string](Get-GitOutputAt -Root $script:groupProjects[$name] -Arguments @('rev-parse','HEAD'))).Trim() | Should -Be $script:groupHeads[$name]
            Test-Path (Join-Path $script:primaryRoot "src/cf/$name.bsl") | Should -BeTrue
        }
        $script:groupReport | Should -Match 'только источник'
    }

    It 'builds recipient commits without touching the callers staged index or working files' {
        Write-Utf8Text -Path (Join-Path $script:primaryRoot 'docs/local.txt') -Value 'unrelated staged edit'
        Invoke-Git @('add','docs/local.txt')
        $index = Join-Path $script:primaryRoot '.git/index'
        $before = (Get-FileHash -LiteralPath $index -Algorithm SHA256).Hash
        $commit = New-BranchSourceSyncCommit -BaseCommit $script:groupHeads.primary -SourceTreeish $script:groupHeads['peer-a'] -ExportPath 'src/cf' -Message 'planned only'
        $commit | Should -Match '^[a-f0-9]{40}$'
        (Get-FileHash -LiteralPath $index -Algorithm SHA256).Hash | Should -Be $before
        Read-Utf8Text (Join-Path $script:primaryRoot 'docs/local.txt') | Should -Be 'unrelated staged edit'
        Test-Path (Join-Path $script:primaryRoot 'src/cf/peer-a.bsl') | Should -BeFalse
    }

    It 'retains all prior sources when a later peer conflicts and resumes staged resolution without early database loads' {
        foreach ($name in @('primary','peer-b')) {
            Write-Utf8Text -Path (Join-Path $script:groupProjects[$name] 'src/cf/Общий модуль.bsl') -Value "Изменение $name`r`n"
            Invoke-GitAt -Root $script:groupProjects[$name] -Arguments @('add','src/cf')
            Invoke-GitAt -Root $script:groupProjects[$name] -Arguments @('commit','--quiet','-m','conflicting input')
        }
        { Sync-DevBranches } | Should -Throw '*DEV_BRANCH_SOURCE_SYNC_CONFLICT:*'
        $script:groupLoads | Should -HaveCount 0
        Write-Utf8Text -Path (Join-Path $script:primaryRoot 'src/cf/Общий модуль.bsl') -Value "Изменение primary`r`nИзменение peer-b`r`n"
        Invoke-Git @('add','src/cf/Общий модуль.bsl')
        Sync-DevBranches
        $script:groupLoads | Should -Be @('primary','peer-a','peer-b')
        foreach ($root in $script:groupProjects.Values) {
            Read-Utf8Text (Join-Path $root 'src/cf/Общий модуль.bsl') | Should -Match 'primary\r\nИзменение peer-b'
            Test-Path (Join-Path $root 'src/cf/peer-a.bsl') | Should -BeTrue
        }
    }

    It 'reconciles a committed recipient after plan persistence fails without recreating completed commits' {
        Mock Save-BranchSourceSyncGroupPlan {
            param($Plan)
            if ($Plan.members[1].sourceStatus -eq 'committed' -and $null -eq $Plan.pending) { $script:groupFailWrites = $true }
            if ($script:groupFailWrites) { throw 'injected plan write failure' }
            & $script:groupSaveImplementation -Plan $Plan
        }
        { Sync-DevBranches } | Should -Throw '*injected plan write failure*'
        $script:groupLoads | Should -HaveCount 0
        $firstHead = Get-CurrentCommit
        $secondHead = ([string](Get-GitOutputAt -Root $script:groupProjects['peer-a'] -Arguments @('rev-parse','HEAD'))).Trim()
        Mock Save-BranchSourceSyncGroupPlan { param($Plan) & $script:groupSaveImplementation -Plan $Plan }
        Sync-DevBranches
        Get-CurrentCommit | Should -Be $firstHead
        ([string](Get-GitOutputAt -Root $script:groupProjects['peer-a'] -Arguments @('rev-parse','HEAD'))).Trim() | Should -Be $secondHead
        $script:groupLoads | Should -Be @('primary','peer-a','peer-b')
    }

    It 'uses the frozen lock set and rejects a changed group request before checkpoints' {
        Write-Utf8Text -Path $script:BranchSyncRequestPath -Value (@{schemaVersion=1;peers=@('peer-a');recipients=@('primary')} | ConvertTo-Json)
        @(Get-Agent1cLifecycleOperationLockScopes -RequestedAction sync-dev-branches) | Should -HaveCount 3
        { Sync-DevBranches } | Should -Throw '*DEV_BRANCH_SOURCE_SYNC_REQUEST_CHANGED*'
        foreach ($name in $script:groupProjects.Keys) {
            ([string](Get-GitOutputAt -Root $script:groupProjects[$name] -Arguments @('rev-parse','HEAD'))).Trim() | Should -Be $script:groupHeads[$name]
        }
        $script:groupLoads | Should -HaveCount 0
    }

    It 'reconciles a durable load receipt after the following plan write is lost without reloading that recipient' {
        Mock Save-BranchSourceSyncGroupPlan {
            param($Plan)
            if ($Plan.members[0].loadStatus -eq 'loaded') { $script:groupFailWrites = $true }
            if ($script:groupFailWrites) { throw 'injected receipt persistence interruption' }
            & $script:groupSaveImplementation -Plan $Plan
        }
        { Sync-DevBranches } | Should -Throw '*injected receipt persistence interruption*'
        $script:groupLoads | Should -Be @('primary')
        Mock Save-BranchSourceSyncGroupPlan { param($Plan) & $script:groupSaveImplementation -Plan $Plan }
        Sync-DevBranches
        $script:groupLoads | Should -Be @('primary','peer-a','peer-b')
        $script:groupReport | Should -Match 'успешно'
    }

    It 'retains completed recipients and refuses to invent a missing database completion receipt' {
        Mock Invoke-BranchSourceSyncLoad { throw 'native load outcome unknown' } -ParameterFilter { $State.devBranchName -eq 'peer-a' }
        { Sync-DevBranches } | Should -Throw '*native load outcome unknown*'
        $script:groupLoads | Should -Be @('primary')
        { Sync-DevBranches } | Should -Throw '*DEV_BRANCH_SOURCE_SYNC_LOAD_UNCONFIRMED*'
        $script:groupLoads | Should -Be @('primary')
        Should -Invoke Invoke-BranchSourceSyncLoad -Times 1 -Exactly -ParameterFilter { $State.devBranchName -eq 'peer-a' }
        $script:groupReport | Should -Not -Match 'успешно'
    }

    It 'rechecks completed recipient heads when the final marker cleanup was interrupted' {
        Mock Save-BranchSourceSyncGroupPlan {
            param($Plan)
            & $script:groupSaveImplementation -Plan $Plan
            if ($Plan.phase -eq 'complete') { throw 'injected final marker interruption' }
        }
        { Sync-DevBranches } | Should -Throw '*injected final marker interruption*'
        $peer = $script:groupProjects['peer-b']
        Write-Utf8Text -Path (Join-Path $peer 'docs/local.txt') -Value 'later work after completion'
        Invoke-GitAt -Root $peer -Arguments @('add','docs/local.txt')
        Invoke-GitAt -Root $peer -Arguments @('commit','--quiet','-m','later work')
        $laterHead = ([string](Get-GitOutputAt -Root $peer -Arguments @('rev-parse','HEAD'))).Trim()
        Mock Save-BranchSourceSyncGroupPlan { param($Plan) & $script:groupSaveImplementation -Plan $Plan }
        { Sync-DevBranches } | Should -Throw '*DEV_BRANCH_SOURCE_SYNC_COMPLETION_CHANGED*'
        $script:groupLoads | Should -Be @('primary','peer-a','peer-b')
        ([string](Get-GitOutputAt -Root $peer -Arguments @('rev-parse','HEAD'))).Trim() | Should -Be $laterHead
        $script:groupReport | Should -Not -Match 'успешно'
    }

    It 'preserves a foreign staged source blob even when working bytes equal the original source' {
        $source = Join-Path $script:primaryRoot 'src/cf/Общий модуль.bsl'
        $original = [IO.File]::ReadAllBytes($source)
        $commit = New-BranchSourceSyncCommit -BaseCommit $script:groupHeads.primary -SourceTreeish $script:groupHeads['peer-a'] -ExportPath 'src/cf' -Message 'pending transfer'
        Write-Utf8Text -Path $source -Value 'staged foreign change'
        Invoke-Git @('add','src/cf/Общий модуль.bsl')
        [IO.File]::WriteAllBytes($source, $original)
        $index = Join-Path $script:primaryRoot '.git/index'
        $before = (Get-FileHash -LiteralPath $index).Hash
        { Install-BranchSourceSyncTree -ExpectedHead $script:groupHeads.primary -PreviousSource $script:groupHeads.primary -DesiredCommit $commit -ExportPath 'src/cf' -CommitHead } | Should -Throw '*DEV_BRANCH_SOURCE_SYNC_FOREIGN_INDEX*'
        (Get-FileHash -LiteralPath $index).Hash | Should -Be $before
        [IO.File]::ReadAllBytes($source) | Should -Be $original
    }

    It 'rejects unrelated changes in the last peer before checkpointing any participant' {
        Write-Utf8Text -Path (Join-Path $script:primaryRoot 'src/cf/primary.bsl') -Value 'uncommitted primary source'
        Write-Utf8Text -Path (Join-Path $script:groupProjects['peer-b'] 'docs/local.txt') -Value 'unrelated peer work'
        { Sync-DevBranches } | Should -Throw '*DEV_BRANCH_SOURCE_SYNC_UNEXPECTED_PATHS*'
        Get-CurrentCommit | Should -Be $script:groupHeads.primary
        Read-Utf8Text (Join-Path $script:primaryRoot 'src/cf/primary.bsl') | Should -Be 'uncommitted primary source'
        $script:groupLoads | Should -HaveCount 0
    }

    It 'rejects malformed explicit group membership: <case>' -ForEach @(
        @{case='scalar peers';request=@{schemaVersion=1;peers='peer-a';recipients=@('primary')}}
        @{case='scalar recipients';request=@{schemaVersion=1;peers=@('peer-a');recipients='primary'}}
        @{case='duplicate alias';request=@{schemaVersion=1;peers=@('peer-a','itldev/PEER-A');recipients=@('primary')}}
        @{case='unknown recipient';request=@{schemaVersion=1;peers=@('peer-a');recipients=@('primary','peer-b')}}
        @{case='unknown option';request=@{schemaVersion=1;peers=@('peer-a');recipients=@('primary');all=$true}}
    ) {
        Write-Utf8Text -Path $script:BranchSyncRequestPath -Value ($request | ConvertTo-Json)
        { Get-BranchSourceSyncScope -State (Read-DevBranchState -Name primary) } | Should -Throw '*DEV_BRANCH_SOURCE_SYNC_*'
        Get-CurrentCommit | Should -Be $script:groupHeads.primary
    }
}
