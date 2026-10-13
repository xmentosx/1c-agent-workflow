Describe "1C workflow development branch lifecycle checks" {
    BeforeAll { . (Join-Path $PSScriptRoot 'DevBranchLifecycleSupport.ps1') }

    Describe 'Fork continuation after a completed workflow update' {
        BeforeAll {
            function New-ForkWorkflowFixture {
                param([string]$Root, [int]$Updates = 1, [string[]]$AdditionalPaths = @())
                New-Item -ItemType Directory -Force -Path (Join-Path $Root '.agent-1c'), (Join-Path $Root 'src/cf') | Out-Null
                $utf8 = [Text.UTF8Encoding]::new($false)
                [IO.File]::WriteAllText((Join-Path $Root '.gitignore'), ".dev.env`n.agent-1c/snapshots/`n.agent-1c/tmp/`n.agent-1c/dev-branches/`n.agent-1c/fork-history/`n", $utf8)
                [IO.File]::WriteAllText((Join-Path $Root '.agent-1c/project.json'), '{"aiRules":{"tools":["codex"]}}', $utf8)
                [IO.File]::WriteAllText((Join-Path $Root '.agent-1c/dependency-lock.json'), '{"schemaVersion":1,"dependencies":{},"fixture":0}', $utf8)
                [IO.File]::WriteAllText((Join-Path $Root 'AGENT-INSTALL.md'), 'package 0', $utf8)
                [IO.File]::WriteAllText((Join-Path $Root 'src/cf/Модуль.bsl'), 'business baseline', $utf8)
                [IO.File]::WriteAllText((Join-Path $Root 'business.txt'), 'business baseline', $utf8)
                [IO.File]::WriteAllText((Join-Path $Root '.dev.env'), "CAVEMAN=On`nUSER_SETTING=original`n", $utf8)
                & git -C $Root init -q -b itldev/fork
                $LASTEXITCODE | Should -Be 0
                & git -C $Root config user.name 'Fork transition fixture'
                $LASTEXITCODE | Should -Be 0
                & git -C $Root config user.email 'fork@example.invalid'
                $LASTEXITCODE | Should -Be 0
                & git -C $Root add --all
                $LASTEXITCODE | Should -Be 0
                & git -C $Root commit -qm baseline
                $LASTEXITCODE | Should -Be 0
                $LASTEXITCODE | Should -Be 0
                $anchor = (& git -C $Root rev-parse HEAD).Trim()
                $lockSha = (Get-FileHash -LiteralPath (Join-Path $Root '.agent-1c/dependency-lock.json')).Hash.ToLowerInvariant()
                $completed = @()
                for ($number = 1; $number -le $Updates; $number++) {
                    $completed += & {
                        . $HelperPath -ProjectRoot $Root -Action help *> $null
                        $source = [pscustomobject]@{ root=$RepoRoot; commit=('a' * 40) }
                        $relativePaths = @('AGENT-INSTALL.md', '.agent-1c/dependency-lock.json', '.dev.env') + $AdditionalPaths
                        if($AdditionalPaths.Count){$relativePaths+=@('.ai-rules.json')}
                        $snapshot = New-WorkflowUpdateRollbackSnapshot -RelativePaths $relativePaths -SnapshotParent (Join-Path $Root '.agent-1c/snapshots/workflow-update')
                        Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase prepared
                        [IO.File]::WriteAllText((Join-Path $Root 'AGENT-INSTALL.md'), "package $number", $utf8)
                        [IO.File]::WriteAllText((Join-Path $Root '.agent-1c/dependency-lock.json'), ('{"schemaVersion":1,"dependencies":{},"fixture":' + $number + '}'), $utf8)
                        [IO.File]::WriteAllText((Join-Path $Root '.dev.env'), "CAVEMAN=auto`nUSER_SETTING=preserved`n", $utf8)
                        $managedPaths = @('AGENT-INSTALL.md', '.agent-1c/dependency-lock.json')
                        if($AdditionalPaths.Count){
                            $manifestFiles=@{}
                            foreach($relative in $AdditionalPaths){
                                $destination=Join-Path $Root $relative
                                New-Item -ItemType Directory -Force (Split-Path -Parent $destination) | Out-Null
                                [IO.File]::WriteAllText($destination,'new native file',$utf8)
                                # Placed-once OpenSpec scaffolding is intentionally
                                # absent from the upstream installed manifest.
                                if($relative -cnotin @(Get-AiRulesOpenSpecScaffoldPaths)){$manifestFiles[$relative]=@{source='content/native-fixture'}}
                            }
                            [IO.File]::WriteAllText((Join-Path $Root '.ai-rules.json'),(@{files=$manifestFiles}|ConvertTo-Json -Depth 5),$utf8)
                            $managedPaths+=@($AdditionalPaths)+@('.ai-rules.json')
                        }
                        $plan = New-WorkflowBranchCommitPlan -ManagedPathSpecs $managedPaths
                        Save-WorkflowBranchCommitPlanReceipt -Snapshot $snapshot -Plan $plan
                        Apply-WorkflowBranchCommitPlan -Plan $plan | Out-Null
                        Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase post-copy-complete
                        Retain-WorkflowUpdateRollbackSnapshot -Snapshot $snapshot
                    }
                }
                [pscustomobject]@{ root=$Root; anchor=$anchor; lockSha=$lockSha; completed=$completed; head=(& git -C $Root rev-parse HEAD).Trim() }
            }
        }

        It 'admits Release resume through the completed workflow owner without changing source or transaction evidence' {
            $fixture = New-ForkWorkflowFixture -Root (Join-Path $TestDrive 'Release после обновления') -Updates 2
            . (Join-Path $RepoRoot 'scripts/release-e2e/workflow-transition.ps1')
            . (Join-Path $RepoRoot 'scripts/release-e2e/admission.ps1')
            . (Join-Path $RepoRoot 'scripts/git-path-list.ps1')
            $tokens=$null; $errors=$null
            $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'scripts/invoke-release-e2e.ps1'),[ref]$tokens,[ref]$errors)
            $definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Test-E2EManagedRefreshHead'},$true)
            . ([scriptblock]::Create($definition.Extent.Text))
            $before=@(Get-ChildItem (Join-Path $fixture.root '.agent-1c/snapshots') -Recurse -File | ForEach-Object {($_.FullName + ':' + (Get-FileHash $_.FullName).Hash)})
            Test-E2EManagedRefreshHead -RepositoryRoot $fixture.root -CurrentHead $fixture.head -ExpectedHead $fixture.anchor -MasterHead $fixture.anchor -ExportPath 'src/cf' -WorkflowRoot $RepoRoot | Should -BeTrue
            (& git -C $fixture.root rev-parse HEAD).Trim() | Should -BeExactly $fixture.head
            @(& git -C $fixture.root status --porcelain) | Should -BeNullOrEmpty
            @(Get-ChildItem (Join-Path $fixture.root '.agent-1c/snapshots') -Recurse -File | ForEach-Object {($_.FullName + ':' + (Get-FileHash $_.FullName).Hash)}) | Should -Be $before
        }

        It 'admits a completed workflow update in the shared early decision and rejects its extra refresh without mutation' -Tag 'ReleaseAdmissionContract' {
            $fixture = New-ForkWorkflowFixture -Root (Join-Path $TestDrive 'Update потом refresh')
            . (Join-Path $RepoRoot 'scripts/git-path-list.ps1')
            . (Join-Path $RepoRoot 'scripts/release-e2e/workflow-transition.ps1')
            . (Join-Path $RepoRoot 'scripts/release-e2e/admission.ps1')
            $context=@{projectRoot=$fixture.root;worktreePath=$fixture.root;branch='itldev/fork';resumeMode='Auto';workflowRoot=$RepoRoot;
                currentHead=$fixture.head;masterHead=$fixture.anchor;worktreeClean=$true;exportPath='src/cf';workflowCommit='';workflowTree='';runnerSha256='';helperSha256='';aiRulesCommit='';projectConfigSha256='';clientSelection='current'}
            $checkpoint=@{schemaVersion=3;identity=@{projectRoot=$fixture.root;worktreePath=$fixture.root;branch='itldev/fork';clientSelection='previous'};expectedHead=$fixture.anchor;stages=@{}}
            $before=@(Get-ChildItem (Join-Path $fixture.root '.agent-1c/snapshots') -Recurse -File | ForEach-Object {($_.FullName+':'+(Get-FileHash $_.FullName).Hash)})
            $approved=Get-E2EReleaseCheckpointAdmission $context $checkpoint
            $approved.allowed | Should -BeTrue
            $approved.continuationProof | Should -BeNullOrEmpty
            & git -C $fixture.root checkout -q -b refresh-main $fixture.anchor
            [IO.File]::WriteAllText((Join-Path $fixture.root 'main.txt'),'main fixture',[Text.UTF8Encoding]::new($false))
            & git -C $fixture.root add -- main.txt
            & git -C $fixture.root commit -qm 'main advance'
            $context.masterHead=(& git -C $fixture.root rev-parse HEAD).Trim()
            & git -C $fixture.root checkout -q itldev/fork
            & git -C $fixture.root merge --no-ff -qm 'ordinary refresh after workflow update' refresh-main
            $LASTEXITCODE | Should -Be 0
            $context.currentHead=(& git -C $fixture.root rev-parse HEAD).Trim()
            $mergeHead=$context.currentHead
            $rejected=Get-E2EReleaseCheckpointAdmission $context $checkpoint
            $rejected.allowed | Should -BeFalse
            $rejected.code | Should -BeExactly 'RELEASE_E2E_RESUME_STATE_MISMATCH'
            (& git -C $fixture.root rev-parse HEAD).Trim() | Should -BeExactly $mergeHead
            @(& git -C $fixture.root status --porcelain) | Should -BeNullOrEmpty
            @(Get-ChildItem (Join-Path $fixture.root '.agent-1c/snapshots') -Recurse -File | ForEach-Object {($_.FullName+':'+(Get-FileHash $_.FullName).Hash)}) | Should -Be $before
        }

        It 'rejects Release workflow resume with <Fault>' -TestCases @(
            @{Fault='foreign commit'}, @{Fault='CF change'}, @{Fault='CFE change'},
            @{Fault='missing receipt'}, @{Fault='tampered backup'}, @{Fault='dirty lock'}
        ) {
            param($Fault)
            $fixture = New-ForkWorkflowFixture -Root (Join-Path $TestDrive ('Release отказ ' + $Fault))
            . (Join-Path $RepoRoot 'scripts/release-e2e/workflow-transition.ps1')
            switch ($Fault) {
                'missing receipt' { Remove-Item -LiteralPath (Join-Path $fixture.completed[0] 'branch-commit.json') }
                'tampered backup' {
                    $receipt=Get-Content (Join-Path $fixture.completed[0] 'transaction.json') -Raw -Encoding UTF8 | ConvertFrom-Json
                    $record=$receipt.records | Where-Object relativePath -EQ '.agent-1c/dependency-lock.json'
                    [IO.File]::AppendAllText((Join-Path $fixture.completed[0] $record.backupName),'tampered')
                }
                'dirty lock' { [IO.File]::AppendAllText((Join-Path $fixture.root '.agent-1c/dependency-lock.json'),' ') }
                default {
                    $path=switch($Fault){'CF change'{'src/cf/Модуль.bsl'} 'CFE change'{'src/cfe/Ext/Module.bsl'} default {'business.txt'}}
                    $full=Join-Path $fixture.root $path
                    New-Item -ItemType Directory -Force (Split-Path -Parent $full) | Out-Null
                    [IO.File]::WriteAllText($full,'foreign change',[Text.UTF8Encoding]::new($false))
                    & git -C $fixture.root add -- $path
                    & git -C $fixture.root commit -qm 'chore: update ITL workflow in development branch'
                    $LASTEXITCODE | Should -Be 0
                }
            }
            $head=(& git -C $fixture.root rev-parse HEAD).Trim()
            Test-E2ECompletedWorkflowTransition -RepositoryRoot $fixture.root -CurrentHead $head -ExpectedHead $fixture.anchor -WorkflowRoot $RepoRoot | Should -BeFalse
        }

        It 'accepts a consecutive retained update chain without changing the immutable anchor, business index or target settings' {
            $fixture = New-ForkWorkflowFixture -Root (Join-Path $TestDrive 'Продолжение fork с пробелом') -Updates 2
            $business = Join-Path $fixture.root 'src/cf/Модуль.bsl'
            [IO.File]::WriteAllText($business, 'staged business', [Text.UTF8Encoding]::new($false))
            & git -C $fixture.root add -- 'src/cf/Модуль.bsl'
            $LASTEXITCODE | Should -Be 0
            $index = (& git -C $fixture.root rev-parse ':src/cf/Модуль.bsl').Trim()
            [IO.File]::WriteAllText($business, 'unstaged business', [Text.UTF8Encoding]::new($false))
            $envPath = Join-Path $fixture.root '.dev.env'
            [IO.File]::AppendAllText($envPath, "LATER_USER_SETTING=keep`n", [Text.UTF8Encoding]::new($false))
            $envHash = (Get-FileHash $envPath).Hash
            $backups = @($fixture.completed | ForEach-Object { (Get-FileHash (Join-Path $_ 'transaction.json')).Hash })
            . $HelperPath -ProjectRoot $fixture.root -Action help *> $null
            Assert-DevBranchForkWorkflowTransition -OriginalCommit $fixture.anchor -OriginalDependencyLockSha256 $fixture.lockSha
            Get-CurrentCommit | Should -Be $fixture.head
            (Get-FileHash $envPath).Hash | Should -Be $envHash
            (& git -C $fixture.root rev-parse ':src/cf/Модуль.bsl').Trim() | Should -Be $index
            [IO.File]::ReadAllText($business) | Should -Be 'unstaged business'
            @($fixture.completed | ForEach-Object { (Get-FileHash (Join-Path $_ 'transaction.json')).Hash }) | Should -Be $backups
            $snapshot = [pscustomobject]@{ sourceCommit=$fixture.anchor; dependencyLockPath='immutable fork lock'; dependencyLockSha256=$fixture.lockSha }
            Install-DevBranchForkDependencyLock -Snapshot $snapshot -TargetProjectRoot $fixture.root | Should -Be (Join-Path $fixture.root '.agent-1c/dependency-lock.json')
        }

        It 'accepts new native files for all twelve current clients, legacy roots, client entries and the exact OpenSpec scaffold' {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $adapters=Get-ItlClientAdapterRegistry
            $adapters.Count | Should -Be 12
            $newPaths=@('CLAUDE.md','QWEN.md','.clinerules/native.md','.kimi/native.md','.kilocode/native.md') + @(Get-AiRulesOpenSpecScaffoldPaths)
            foreach($adapter in $adapters.Values){
                foreach($field in @('rulesPath','agentsPath','skillsPath','commandsPath')){
                    $leaf=if($field -eq 'skillsPath' -or ($field -eq 'commandsPath' -and $adapter.commandFormat -eq 'skill')){'new-native/SKILL.md'}else{'new-native.md'}
                    if([string]$adapter[$field]){$newPaths+=([string]$adapter[$field]+'/'+$leaf)}
                }
            }
            $newPaths=@($newPaths|Select-Object -Unique)
            $fixture=New-ForkWorkflowFixture -Root (Join-Path $TestDrive 'Все родные клиенты и scaffold') -AdditionalPaths $newPaths
            . $HelperPath -ProjectRoot $fixture.root -Action help *> $null
            Assert-DevBranchForkWorkflowTransition -OriginalCommit $fixture.anchor -OriginalDependencyLockSha256 $fixture.lockSha
            $entries=@(Get-AiRules1cManifestFileEntries|ForEach-Object{$_.target})
            foreach($path in $newPaths){
                Test-Path -LiteralPath (Join-Path $fixture.root $path) -PathType Leaf | Should -BeTrue
                if($path -cin @(Get-AiRulesOpenSpecScaffoldPaths)){$entries | Should -Not -Contain $path}
            }
            Get-CurrentCommit | Should -Be $fixture.head
        }

        It 'resumes the same public fork with updated target settings even after source business advances' {
            $fixture = New-ForkWorkflowFixture -Root (Join-Path $TestDrive 'Целевая ветка fork')
            $sourceRoot = Join-Path $TestDrive 'Исходная ветка fork'
            & git -C $fixture.root worktree add --quiet -b itldev/source $sourceRoot $fixture.anchor
            $LASTEXITCODE | Should -Be 0
            [IO.File]::WriteAllText((Join-Path $sourceRoot 'src/cf/Модуль.bsl'), 'later source business')
            & git -C $sourceRoot add -- 'src/cf/Модуль.bsl'
            $LASTEXITCODE | Should -Be 0
            & git -C $sourceRoot commit -qm 'later source business'
            $LASTEXITCODE | Should -Be 0
            $script:forkFixture = $fixture
            $script:forkSnapshot = [pscustomobject]@{
                sourceCommit=$fixture.anchor; sourceGitBranch='itldev/source'; targetGitBranch='itldev/fork'
                targetSafeName='fork'; targetWorktreePath=$fixture.root; forkId='original-fork'; artifactSha256=('d' * 64); artifactKind='file-1cd'
                dependencyLockSha256=$fixture.lockSha; dotEnvPath=(Join-Path $sourceRoot '.dev.env')
            }
            $script:forkTarget = [pscustomobject]@{
                devBranch='itldev/fork'; devBranchName='fork'; safeDevBranchName='fork'; initializationStatus='fork-failed'
                forkId='original-fork'; forkedFromCommit=$fixture.anchor; forkedFromBranch='itldev/source'
                forkSnapshotArtifactSha256=('d' * 64); forkSnapshotArtifactKind='file-1cd'; worktreePath=$fixture.root
                toolingInfoBaseGeneration='preserved-generation'; toolingMutationId='preserved-mutation'
            }
            New-Item -ItemType Directory -Force (Join-Path $fixture.root '.agent-1c/dev-branches') | Out-Null
            [IO.File]::WriteAllText((Join-Path $fixture.root '.agent-1c/dev-branches/fork.json'), ($script:forkTarget | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
            $envPath = Join-Path $fixture.root '.dev.env'
            [IO.File]::AppendAllText($envPath, "USER_LATER_EDIT=keep`n", [Text.UTF8Encoding]::new($false))
            $envHash = (Get-FileHash $envPath).Hash
            . $HelperPath -ProjectRoot $sourceRoot -Action help -DevBranchName fork *> $null
            Mock Read-DevBranchState { param($Name); if ($Name -eq 'fork') { $script:forkTarget } else { [pscustomobject]@{ devBranch='itldev/source' } } }
            Mock Assert-DevelopmentBranchWorktreeContext {}
            Mock Assert-DevBranchExtensionInitialized {}
            Mock Assert-DevBranchApplicationReady { param($State); $State }
            Mock Get-MainWorktreePath { $sourceRoot }
            Mock Resolve-DevBranchWorktreePath { $script:forkFixture.root }
            Mock Read-DevBranchForkSnapshot { $script:forkSnapshot }
            Mock Copy-KiloProjectConfigToWorktree {}
            Mock Invoke-ForkDevBranchRuntimeAfterSnapshot {
                param($Snapshot, $MainProjectRoot, $WorktreePath)
                $Snapshot.sourceCommit | Should -Be $script:forkFixture.anchor
                $Snapshot.forkId | Should -Be 'original-fork'
                $WorktreePath | Should -Be $script:forkFixture.root
            }
            Mock Write-DevBranchWorktreeOpenMessage {}
            Mock Open-AgentWorktreeBestEffort {}
            Mock Write-DevBranchRunUserReport {}
            Fork-DevBranch
            Should -Invoke Invoke-ForkDevBranchRuntimeAfterSnapshot -Times 1 -Exactly
            Should -Invoke Copy-KiloProjectConfigToWorktree -Times 0 -Exactly
            (Get-FileHash $envPath).Hash | Should -Be $envHash
            (& git -C $fixture.root rev-parse HEAD).Trim() | Should -Be $fixture.head
            (& git -C $sourceRoot rev-parse HEAD).Trim() | Should -Not -Be $fixture.anchor
            $preserved = Get-Content (Join-Path $fixture.root '.agent-1c/dev-branches/fork.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            $preserved.toolingInfoBaseGeneration | Should -Be 'preserved-generation'
            $preserved.toolingMutationId | Should -Be 'preserved-mutation'
        }

        It 'acknowledges a ready fork only across proved source workflow updates (business advance: <BusinessAdvance>)' -ForEach @(
            @{BusinessAdvance=$false}, @{BusinessAdvance=$true}
        ) {
            $fixture=New-ForkWorkflowFixture -Root (Join-Path $TestDrive ('Исходная готовая ветка '+$BusinessAdvance))
            $targetRoot=Join-Path $TestDrive ('Готовая целевая ветка '+$BusinessAdvance)
            & git -C $fixture.root worktree add --quiet -b itldev/ready $targetRoot $fixture.anchor
            $LASTEXITCODE | Should -Be 0
            if($BusinessAdvance){
                [IO.File]::WriteAllText((Join-Path $fixture.root 'src/cf/Модуль.bsl'),'new business')
                & git -C $fixture.root add -- 'src/cf/Модуль.bsl'
                $LASTEXITCODE | Should -Be 0
                & git -C $fixture.root commit -qm business
                $LASTEXITCODE | Should -Be 0
            }
            $script:readyForkTarget=[pscustomobject]@{devBranch='itldev/ready';devBranchName='ready';initializationStatus='ready';forkedFromCommit=$fixture.anchor;forkedFromBranch='itldev/fork';worktreePath=$targetRoot}
            . $HelperPath -ProjectRoot $fixture.root -Action help -DevBranchName ready *> $null
            Mock Read-DevBranchState {param($Name);if($Name -eq 'ready'){$script:readyForkTarget}else{[pscustomobject]@{devBranch='itldev/fork'}}}
            Mock Assert-DevelopmentBranchWorktreeContext {}
            Mock Assert-DevBranchExtensionInitialized {}
            Mock Assert-DevBranchApplicationReady {param($State);$State}
            Mock Get-MainWorktreePath {$fixture.root}
            Mock Resolve-DevBranchWorktreePath {$targetRoot}
            Mock Invoke-ForkDevBranchRuntimeAfterSnapshot {throw 'ready retry must not initialize again'}
            Mock Write-DevBranchWorktreeOpenMessage {}
            Mock Open-AgentWorktreeBestEffort {}
            Mock Write-DevBranchRunUserReport {}
            if($BusinessAdvance){ {Fork-DevBranch} | Should -Throw '*DEV_BRANCH_FORK_WORKFLOW_CHAIN_UNPROVEN*' }
            else { Fork-DevBranch;Should -Invoke Write-DevBranchRunUserReport -Times 1 -Exactly }
            Should -Invoke Invoke-ForkDevBranchRuntimeAfterSnapshot -Times 0 -Exactly
            $script:readyForkTarget.forkedFromCommit | Should -Be $fixture.anchor
        }

        It 'keeps a completed <Kind> restore and target generation on retry, with <Damage> evidence' -ForEach @(
            @{Kind='file';Damage='intact'}, @{Kind='server';Damage='intact'},
            @{Kind='file';Damage='history'}, @{Kind='file';Damage='baseline'}, @{Kind='server';Damage='launcher'}
        ) {
            $fixture = New-ForkWorkflowFixture -Root (Join-Path $TestDrive ("База fork $Kind $Damage"))
            $base = if ($Kind -eq 'file') { Join-Path $TestDrive 'Целевая база с пробелом' } else { 'Srvr="fixture-server";Ref="fork";' }
            $sourceHistory = Join-Path $TestDrive 'Исходная история с пробелом'
            New-Item -ItemType Directory -Force $sourceHistory | Out-Null
            $sourceState = [pscustomobject]@{ infoBaseKind=$Kind; devBranchInfoBasePath='source base'; lastVerificationStatus='passed'; resultTransferBaseline=@{branch='itldev/source';worktreePath='foreign source root';commit=$fixture.anchor} }
            $original = [pscustomobject]@{ createdAt='2026-10-01T00:00:00Z'; reader='fixture'; errorCount=1; signatureCount=1; signatures=@('original-error'); durationMs=2; logDirectory='source'; reason='source'; cache=[pscustomobject]@{status='hit';path='source';segmentCount=1} }
            [IO.File]::WriteAllText((Join-Path $sourceHistory 'source-state.json'), ($sourceState | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $sourceHistory 'event-log-baseline.json'), ($original | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
            $snapshot = [pscustomobject]@{
                forkId='retained-fork'; sourceCommit=$fixture.anchor; sourceGitBranch='itldev/source'; sourceBranchName='source'
                targetSafeName='fork'; targetBranchName='fork'; targetGitBranch='itldev/fork'; targetWorktreePath=$fixture.root
                infoBaseKind=$Kind; artifactKind=$(if($Kind -eq 'file'){'file-1cd'}else{'server-dt'}); artifactSha256=('a'*64)
                historyPath=$sourceHistory; historyFiles=@('source-state.json','event-log-baseline.json' | ForEach-Object { [pscustomobject]@{path=$_;sha256=(Get-FileHash (Join-Path $sourceHistory $_)).Hash.ToLowerInvariant()} })
                dependencyLockPath='immutable lock'; dependencyLockSha256=$fixture.lockSha; evidencePaths=[pscustomobject]@{}
            }
            . $HelperPath -ProjectRoot $fixture.root -Action help -DevBranchName fork -DevBranchInfoBasePath $base *> $null
            $history = Join-Path $fixture.root '.agent-1c/fork-history/retained-fork'
            Install-DevBranchForkHistory -Snapshot $snapshot -TargetHistoryRoot $history | Out-Null
            $state = New-ForkedDevBranchState -SourceState $sourceState -Snapshot $snapshot -TargetInfoBasePath $base -TargetHistoryRoot $history -MainProjectRoot $fixture.root
            $state.Contains('resultTransferBaseline') | Should -BeFalse -Because 'the target must not inherit the source branch lifecycle proof'
            $state.toolingInfoBaseGeneration='target-generation'
            $state.toolingMutationId='target-completed-mutation'
            $state.vanessaMcpSafeModeProof=@{generation='target-generation';fixture='preserved'}
            $state.launcherRegistered=$true
            $state.launcherInfoBaseId='target-launcher-id'
            $state.launcherListPath=Join-Path $TestDrive 'Список запуска.v8i'
            $connect=New-LauncherConnectString -InfoBaseKind $Kind -InfoBasePath $base
            [IO.File]::WriteAllText($state.launcherListPath, "[target]`nID=target-launcher-id`nConnect=$connect`n", [Text.UTF8Encoding]::new($false))
            $state.eventLogBaselinePath=Join-Path $fixture.root '.agent-1c/event-log-baselines/fork.json'
            $state.eventLogBaselineHash=Get-StringSha256 -Value 'original-error'
            $state.eventLogBaselineCreatedAt=$original.createdAt
            $original.logDirectory=if($Kind -eq 'file'){Join-Path $base '1Cv8Log'}else{''}
            $original.reason='fork-boundary';$original.cache.status='fork-history';$original.cache.path=''
            New-Item -ItemType Directory -Force (Split-Path -Parent $state.eventLogBaselinePath) | Out-Null
            [IO.File]::WriteAllText($state.eventLogBaselinePath, ($original | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
            if($Kind -eq 'file'){
                New-Item -ItemType Directory -Force $base | Out-Null
                [IO.File]::WriteAllText((Join-Path $base '1Cv8.1CD'), 'target native effects after restore')
                $baseHash=(Get-FileHash (Join-Path $base '1Cv8.1CD')).Hash
            }
            $statePath=Save-DevBranchInitializationState -SafeDevBranchName fork -State $state -Status fork-failed
            switch($Damage){
                'history' {[IO.File]::AppendAllText((Join-Path $history 'source-state.json'), ' ')}
                'baseline' {$original.signatures=@('changed');[IO.File]::WriteAllText($state.eventLogBaselinePath,($original|ConvertTo-Json))}
                'launcher' {[IO.File]::WriteAllText($state.launcherListPath,"[foreign]`nID=foreign`nConnect=$connect`n")}
            }
            $script:forkLauncher=[pscustomobject]@{registered=$true;name='target';folder='';id=$state.launcherInfoBaseId;listPath=$state.launcherListPath}
            Mock Assert-DevBranchForkInfoBaseIsolated {}
            Mock Restore-DevBranchForkInfoBase { throw 'Unexpected repeated native restore' }
            Mock Register-DevBranchInLauncher { $script:forkLauncher }
            Mock Sync-AiRules1cManagedIgnoredFilesFromMain {}
            Mock Sync-DevBranchContextToDotEnv {}
            Mock Invoke-DevBranchDefaultMcpSetup { throw 'fixture stop after proven restore' }
            if($Damage -eq 'intact'){
                { Initialize-ForkedDevBranchRuntime -Snapshot $snapshot -MainProjectRoot $fixture.root } | Should -Throw '*fixture stop after proven restore*'
                Should -Invoke Invoke-DevBranchDefaultMcpSetup -Times 1 -Exactly
            }else{
                { Initialize-ForkedDevBranchRuntime -Snapshot $snapshot -MainProjectRoot $fixture.root } | Should -Throw '*DEV_BRANCH_FORK_*'
                Should -Invoke Invoke-DevBranchDefaultMcpSetup -Times 0 -Exactly
            }
            Should -Invoke Restore-DevBranchForkInfoBase -Times 0 -Exactly
            $saved=Read-DevBranchStateFile -Path $statePath
            $saved.toolingInfoBaseGeneration | Should -Be 'target-generation'
            $saved.toolingMutationId | Should -Be 'target-completed-mutation'
            $saved.vanessaMcpSafeModeProof.fixture | Should -Be 'preserved'
            if($Kind -eq 'file'){(Get-FileHash (Join-Path $base '1Cv8.1CD')).Hash | Should -Be $baseHash}
        }

        It 'rejects a business commit authorized only by a forged <Authority> manifest and coherent receipt hashes' -ForEach @(
            @{Authority='backup';BusinessPath='src/cf/Модуль.bsl'}, @{Authority='new HEAD source';BusinessPath='src/cf/Модуль.bsl'},
            @{Authority='new HEAD generic';BusinessPath='business.txt'}, @{Authority='new generic path';BusinessPath='new-business.txt'},
            @{Authority='new OpenSpec business';BusinessPath='openspec/changes/business-proposal.md'}
        ) {
            $fixture=New-ForkWorkflowFixture -Root (Join-Path $TestDrive ('Подменённая область workflow '+$Authority))
            $businessPath=$BusinessPath
            $fakeManifest=(@{files=@{$businessPath=@{source='fake-rule'}}}|ConvertTo-Json -Depth 4)
            New-Item -ItemType Directory -Force (Split-Path -Parent (Join-Path $fixture.root $businessPath)) | Out-Null
            [IO.File]::WriteAllText((Join-Path $fixture.root $businessPath),'forged business change',[Text.UTF8Encoding]::new($false))
            & git -C $fixture.root add -- $businessPath
            $LASTEXITCODE | Should -Be 0
            if($Authority -ne 'backup'){
                [IO.File]::WriteAllText((Join-Path $fixture.root '.ai-rules.json'),$fakeManifest,[Text.UTF8Encoding]::new($false))
                & git -C $fixture.root add -- .ai-rules.json
                $LASTEXITCODE | Should -Be 0
            }
            & git -C $fixture.root commit --amend --no-edit --quiet
            $LASTEXITCODE | Should -Be 0
            $newHead=(& git -C $fixture.root rev-parse HEAD).Trim()
            $receiptPath=Join-Path $fixture.completed[0] 'transaction.json'
            $planPath=Join-Path $fixture.completed[0] 'branch-commit.json'
            $receipt=Get-Content $receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $plan=Get-Content $planPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $receipt.completedHead=$newHead
            $plan.newHead=$newHead
            $plan.candidateTree=(& git -C $fixture.root rev-parse 'HEAD^{tree}').Trim()
            $plan.managedPaths+=@($businessPath)
            $plan.managedPathSpecs+=@($businessPath)
            if($Authority -ne 'backup'){$plan.managedPaths+=@('.ai-rules.json');$plan.managedPathSpecs+=@('.ai-rules.json')}
            foreach($item in @(
                @{path=$businessPath;backup='item-900';text='business baseline'},
                @{path='.ai-rules.json';backup='item-901';text=$fakeManifest}
            )){
                $backupPath=Join-Path $fixture.completed[0] $item.backup
                $wasPresent=-not ($item.path -ceq $businessPath -and $Authority -in @('new generic path','new OpenSpec business'))
                if($wasPresent){[IO.File]::WriteAllText($backupPath,$item.text,[Text.UTF8Encoding]::new($false))}
                $receipt.records+=@([pscustomobject]@{relativePath=$item.path;existed=$wasPresent;wasDirectory=$false;backupName=$(if($wasPresent){$item.backup}else{''})})
                $receipt.beforePathState | Add-Member -NotePropertyName $item.path -NotePropertyValue $(if($wasPresent){'file:'+(Get-FileHash $backupPath).Hash.ToLowerInvariant()}else{'absent'})
            }
            [IO.File]::WriteAllText($receiptPath,($receipt|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText($planPath,($plan|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
            . $HelperPath -ProjectRoot $fixture.root -Action help *> $null
            $id=(Split-Path -Leaf $fixture.completed[0]).Substring('itl-workflow-update-completed-'.Length)
            $completed=Get-WorkflowUpdateCompletedSnapshot -SnapshotId $id
            Read-WorkflowBranchCommitPlanReceipt -Snapshot $completed.snapshot | Should -Not -BeNullOrEmpty
            {Assert-DevBranchForkWorkflowTransition -OriginalCommit $fixture.anchor -OriginalDependencyLockSha256 $fixture.lockSha} | Should -Throw '*DEV_BRANCH_FORK_WORKFLOW_BUSINESS_CHANGE*'
            Get-CurrentCommit | Should -Be $newHead
        }

        It 'rejects <Fault> instead of accepting an unproven fork workflow transition' -ForEach @(
            @{Fault='missing receipt';ExpectedFailure='*DEV_BRANCH_FORK_WORKFLOW_CHAIN_INVALID*'}, @{Fault='ambiguous receipt';ExpectedFailure='*DEV_BRANCH_FORK_WORKFLOW_CHAIN_UNPROVEN*'},
            @{Fault='tampered backup';ExpectedFailure='*WORKFLOW_UPDATE_ROLLBACK_BACKUP_INVALID*'}, @{Fault='foreign business commit';ExpectedFailure='*DEV_BRANCH_FORK_WORKFLOW_CHAIN_UNPROVEN*'},
            @{Fault='staged owned edit';ExpectedFailure='*DEV_BRANCH_FORK_WORKFLOW_DIRTY*'}, @{Fault='unstaged owned edit';ExpectedFailure='*DEV_BRANCH_FORK_WORKFLOW_DIRTY*'},
            @{Fault='wrong first lock';ExpectedFailure='*DEV_BRANCH_FORK_WORKFLOW_LOCK_UNPROVEN*'}, @{Fault='changed current lock';ExpectedFailure='*DEV_BRANCH_FORK_WORKFLOW_DIRTY*'},
            @{Fault='wrong branch identity';ExpectedFailure='*DEV_BRANCH_FORK_WORKFLOW_CHAIN_INVALID*'}
        ) {
            $fixture = New-ForkWorkflowFixture -Root (Join-Path $TestDrive ('Отказ fork '+$Fault))
            $receiptPath = Join-Path $fixture.completed[0] 'transaction.json'
            switch ($Fault) {
                'missing receipt' { Remove-Item -LiteralPath (Join-Path $fixture.completed[0] 'branch-commit.json') }
                'ambiguous receipt' {
                    $copy = Join-Path (Split-Path -Parent $fixture.completed[0]) ('itl-workflow-update-completed-'+[guid]::NewGuid().ToString('N'))
                    Copy-Item -LiteralPath $fixture.completed[0] -Destination $copy -Recurse
                    $receipt = Get-Content (Join-Path $copy 'transaction.json') -Raw -Encoding UTF8 | ConvertFrom-Json
                    $receipt.snapshotRoot = $copy.Replace('itl-workflow-update-completed-', 'itl-workflow-update-rollback-')
                    [IO.File]::WriteAllText((Join-Path $copy 'transaction.json'), ($receipt | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
                }
                'tampered backup' {
                    $receipt = Get-Content $receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
                    $record = $receipt.records | Where-Object relativePath -eq '.agent-1c/dependency-lock.json'
                    [IO.File]::AppendAllText((Join-Path $fixture.completed[0] $record.backupName), 'tamper')
                }
                'foreign business commit' {
                    [IO.File]::WriteAllText((Join-Path $fixture.root 'src/cf/Модуль.bsl'), 'later business')
                    & git -C $fixture.root add -- 'src/cf/Модуль.bsl'
                    $LASTEXITCODE | Should -Be 0
                    & git -C $fixture.root commit -qm business
                    $LASTEXITCODE | Should -Be 0
                }
                'staged owned edit' {
                    [IO.File]::WriteAllText((Join-Path $fixture.root 'AGENT-INSTALL.md'), 'staged package edit')
                    & git -C $fixture.root add -- AGENT-INSTALL.md
                    $LASTEXITCODE | Should -Be 0
                }
                'unstaged owned edit' { [IO.File]::WriteAllText((Join-Path $fixture.root 'AGENT-INSTALL.md'), 'unstaged package edit') }
                'wrong first lock' { $fixture.lockSha = 'f' * 64 }
                'changed current lock' { [IO.File]::AppendAllText((Join-Path $fixture.root '.agent-1c/dependency-lock.json'), ' ') }
                'wrong branch identity' {
                    $receipt = Get-Content $receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
                    $receipt.branchRef = 'refs/heads/itldev/foreign'
                    [IO.File]::WriteAllText($receiptPath, ($receipt | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
                }
            }
            . $HelperPath -ProjectRoot $fixture.root -Action help *> $null
            { Assert-DevBranchForkWorkflowTransition -OriginalCommit $fixture.anchor -OriginalDependencyLockSha256 $fixture.lockSha } | Should -Throw $ExpectedFailure
        }
    }
}
