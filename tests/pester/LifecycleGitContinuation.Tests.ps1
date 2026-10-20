Describe 'Lifecycle Git continuation' -Tag 'LifecycleAutonomy' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        $HelperPath = $context.HelperPath
        $RepoRoot = $context.RepoRoot
        function New-ContinuationRepository {
            param([string]$Root)
            New-Item -ItemType Directory -Force -Path (Join-Path $Root 'docs/adr'),(Join-Path $Root 'src/cf') | Out-Null
            [IO.File]::WriteAllText((Join-Path $Root '.gitignore'), ".agent-1c/`n", [Text.UTF8Encoding]::new($false))
            foreach ($path in @('CONTEXT.md','docs/adr/решение.md','src/cf/Configuration.xml','src/cf/ConfigDumpInfo.xml','branch.txt')) {
                [IO.File]::WriteAllText((Join-Path $Root $path), 'baseline', [Text.UTF8Encoding]::new($false))
            }
            & git -C $Root init -q -b master
            & git -C $Root config user.name 'Lifecycle continuation'
            & git -C $Root config user.email 'continuation@example.invalid'
            & git -C $Root add --all
            & git -C $Root commit -qm baseline
            if ($LASTEXITCODE) { throw 'Cannot initialize continuation fixture' }
            return $Root
        }
    }

    It 'ignores reports with absent, current and legacy templates while retaining tracked handoffs and custom rules' {
        foreach ($template in @('absent','current','legacy')) {
            $root = New-ContinuationRepository (Join-Path $TestDrive "Отчёты с пробелом $template")
            New-Item -ItemType Directory -Force -Path (Join-Path $root 'handoffs/nested') | Out-Null
            [IO.File]::WriteAllText((Join-Path $root 'handoffs/tracked.md'),'tracked',[Text.UTF8Encoding]::new($false))
            & git -C $root add -- handoffs/tracked.md
            & git -C $root commit -qm 'tracked report'
            [IO.File]::WriteAllText((Join-Path $root 'handoffs/tracked.md'),'edited',[Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $root 'handoffs/report.md'),'отчёт',[Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $root 'handoffs/nested/data.json'),'{"value":"данные"}',[Text.UTF8Encoding]::new($false))
            $before=(Get-FileHash -LiteralPath (Join-Path $root 'handoffs/report.md')).Hash
            $jsonBefore=(Get-FileHash -LiteralPath (Join-Path $root 'handoffs/nested/data.json')).Hash
            [IO.File]::AppendAllText((Join-Path $root '.gitignore'),'/custom-local/',[Text.UTF8Encoding]::new($false))
            if ($template -ne 'absent') {
                New-Item -ItemType Directory -Force -Path (Join-Path $root 'templates') | Out-Null
                if ($template -eq 'current') { Copy-Item -LiteralPath (Join-Path $RepoRoot 'templates/gitignore.append') -Destination (Join-Path $root 'templates/gitignore.append') }
                else { [IO.File]::WriteAllText((Join-Path $root 'templates/gitignore.append'),".dev.env`n",[Text.UTF8Encoding]::new($false)) }
            }
            & {
                . $HelperPath -ProjectRoot $root -Action help *> $null
                Ensure-GitIgnore
                $first=[IO.File]::ReadAllBytes((Join-Path $root '.gitignore'))
                Ensure-GitIgnore
                [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $root '.gitignore'))) | Should -BeExactly ([Convert]::ToBase64String($first))
                @(Get-GitPathList -Arguments @('ls-files','--others','--exclude-standard','-z','--','handoffs')) | Should -HaveCount 0
                @(Get-GitPathList -Arguments @('diff','--name-only','-z','--','handoffs')) | Should -Contain 'handoffs/tracked.md'
                (Read-Utf8Lines -Path (Join-Path $root '.gitignore')) | Should -Contain '/custom-local/'
            }
            (Get-FileHash -LiteralPath (Join-Path $root 'handoffs/report.md')).Hash | Should -BeExactly $before
            (Get-FileHash -LiteralPath (Join-Path $root 'handoffs/nested/data.json')).Hash | Should -BeExactly $jsonBefore
        }
    }

    It 'admits independent staged, unstaged and untracked documents but retains strict clean Git for other operations' {
        $root=New-ContinuationRepository (Join-Path $TestDrive 'Документы после merge с пробелом')
        [IO.File]::WriteAllText((Join-Path $root 'CONTEXT.md'),'staged',[Text.UTF8Encoding]::new($false))
        & git -C $root add -- CONTEXT.md
        [IO.File]::WriteAllText((Join-Path $root 'CONTEXT.md'),'unstaged',[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $root 'docs/adr/новое решение.md'),'untracked',[Text.UTF8Encoding]::new($false))
        & {
            . $HelperPath -ProjectRoot $root -Action help *> $null
            $before=@(Get-GitPathList -Arguments @('ls-files','--stage','-z')) -join "`0"
            { Assert-RefreshGitInputs -Operation refresh-dev-branch -Phase post-merge } | Should -Not -Throw
            { Assert-RefreshGitInputs -Operation refresh-dev-branch-lite -Phase before-load } | Should -Not -Throw
            (@(Get-GitPathList -Arguments @('ls-files','--stage','-z')) -join "`0") | Should -BeExactly $before
            { Assert-CleanGit } | Should -Throw '*Git worktree is not clean*'
        }
    }

    It 'returns agent-owned continuation for branch creation without committing or hiding user changes' {
        $root=New-ContinuationRepository (Join-Path $TestDrive 'Создание ветки с пробелом')
        [IO.File]::WriteAllText((Join-Path $root 'branch.txt'),'task change',[Text.UTF8Encoding]::new($false))
        & {
            . $HelperPath -ProjectRoot $root -Action help *> $null
            $head=Get-CurrentCommit
            { Assert-CleanGit -Operation new-dev-branch } | Should -Throw '*Git worktree is not clean*'
            $script:RunRequiredAction | Should -Match '^prepare-lifecycle-git:'
            $script:RunBlockerOwner.paths | Should -Contain 'branch.txt'
            $script:RunBlockerRequiresUserDecision | Should -BeFalse
            $script:RunBlockerRetryOriginal | Should -BeTrue
            (Get-CurrentCommit) | Should -BeExactly $head
            $DevBranchName='acceptance'; $DevBranchKind='extension'
            { Get-DevWorkspacePlan } | Should -Throw '*Git worktree is not clean*'
            $script:RunBlockerOwner.operation | Should -Be 'new-extension-dev-branch'
        }
    }

    It 'blocks source, runtime, unknown paths and documentation declared as a verification input' {
        foreach ($path in @('src/cf/Configuration.xml','.agents/skills/custom.md','unknown.md','docs/adr/решение.md')) {
            $root=New-ContinuationRepository (Join-Path $TestDrive ('Входы с пробелом '+[guid]::NewGuid().ToString('N')))
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent (Join-Path $root $path)),(Join-Path $root 'tests') | Out-Null
            [IO.File]::WriteAllText((Join-Path $root 'tests/verification-suites.branch.json'),'{"schemaVersion":2,"obligations":[{"inputPaths":["./docs/adr/**"]}]}',[Text.UTF8Encoding]::new($false))
            & git -C $root add --all
            & git -C $root commit -qm 'declared input'
            [IO.File]::WriteAllText((Join-Path $root $path),'changed',[Text.UTF8Encoding]::new($false))
            & {
                . $HelperPath -ProjectRoot $root -Action help *> $null
                { Assert-RefreshGitInputs -Operation refresh-dev-branch -Phase before-load } | Should -Throw '*LIFECYCLE_GIT_INPUTS_CHANGED*'
                $script:RunBlockerOwner.paths | Should -Contain $path
                $script:RunRequiredAction | Should -Match '^prepare-lifecycle-git:'
                & git -C $root add -- $path
                { Assert-RefreshGitInputs -Operation refresh-dev-branch-lite -Phase before-load } | Should -Throw '*LIFECYCLE_GIT_INPUTS_CHANGED*'
            }
        }
    }

    It 'treats legacy catalog ownership as phase input and preserves rename source endpoints' {
        $root=New-ContinuationRepository (Join-Path $TestDrive 'Переименование и legacy с пробелом')
        New-Item -ItemType Directory -Force -Path (Join-Path $root 'tests') | Out-Null
        [IO.File]::WriteAllText((Join-Path $root 'tests/verification-suites.branch.json'),'{"schemaVersion":1,"suites":[{"ownerPaths":["docs/adr/**"]}]}',[Text.UTF8Encoding]::new($false))
        & git -C $root add --all
        & git -C $root commit -qm catalog
        & git -C $root mv -- src/cf/Configuration.xml 'docs/adr/копия с пробелом.md'
        & {
            . $HelperPath -ProjectRoot $root -Action help *> $null
            $changes=@(Get-LifecycleGitChanges)
            @($changes.path) | Should -Contain 'src/cf/Configuration.xml'
            @($changes.path) | Should -Contain 'docs/adr/копия с пробелом.md'
            { Assert-RefreshGitInputs -Operation refresh-dev-branch -Phase post-merge } | Should -Throw '*LIFECYCLE_GIT_INPUTS_CHANGED*'
            $script:RunBlockerOwner.paths | Should -Contain 'src/cf/Configuration.xml'
            $script:RunBlockerOwner.paths | Should -Contain 'docs/adr/копия с пробелом.md'
            (Get-LifecycleGitPathDisposition -Paths @('docs/adr/решение.md') -InputScopes @('.') -IndependentScopes @('docs')).kind | Should -Be 'input'
        }
    }

    It 'does not bypass an unfinished Git operation for independent documentation' {
        $root=New-ContinuationRepository (Join-Path $TestDrive 'Незавершённый rebase с пробелом')
        New-Item -ItemType Directory -Path (Join-Path $root '.git/rebase-merge') | Out-Null
        [IO.File]::WriteAllText((Join-Path $root 'CONTEXT.md'),'document',[Text.UTF8Encoding]::new($false))
        & {
            . $HelperPath -ProjectRoot $root -Action help *> $null
            { Assert-RefreshGitInputs -Operation refresh-dev-branch -Phase post-merge } | Should -Throw '*DEV_BRANCH_CHECKPOINT_GIT_OPERATION_IN_PROGRESS*'
            $script:RunRequiredAction | Should -Match '^prepare-lifecycle-git:'
        }
    }

    It 'returns exact catalog repair continuation when independent inputs cannot be classified' {
        $root=New-ContinuationRepository (Join-Path $TestDrive 'Ошибочный каталог с пробелом')
        New-Item -ItemType Directory -Force -Path (Join-Path $root 'tests') | Out-Null
        [IO.File]::WriteAllText((Join-Path $root 'tests/verification-suites.branch.json'),'{invalid',[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $root 'CONTEXT.md'),'document',[Text.UTF8Encoding]::new($false))
        & {
            . $HelperPath -ProjectRoot $root -Action help *> $null
            { Assert-RefreshGitInputs -Operation refresh-dev-branch -Phase before-load } | Should -Throw '*LIFECYCLE_GIT_INPUTS_UNCLASSIFIED*'
            $script:RunRequiredAction | Should -Match '^prepare-lifecycle-git:'
            $script:RunBlockerOwner.paths | Should -Contain (Join-Path $root 'tests/verification-suites.branch.json')
        }
    }

    It 'keeps unrelated staged entries and worktree bytes during a reviewed task-only commit and wrapper retry' {
        foreach ($requestedOperation in @('new-dev-branch','new-extension-dev-branch')) {
            $root=New-ContinuationRepository (Join-Path $TestDrive ('Коммит агента с пробелом '+$requestedOperation))
            [IO.File]::WriteAllText((Join-Path $root 'branch.txt'),'own task',[Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $root 'CONTEXT.md'),'foreign staged',[Text.UTF8Encoding]::new($false))
            & git -C $root add -- CONTEXT.md
            [IO.File]::WriteAllText((Join-Path $root 'CONTEXT.md'),'foreign unstaged',[Text.UTF8Encoding]::new($false))
            & {
                . $HelperPath -ProjectRoot $root -Action help *> $null
                $foreignIndex=@(Get-GitPathList -Arguments @('ls-files','--stage','-z','--','CONTEXT.md')) -join "`0"
                $foreignHash=(Get-FileHash -LiteralPath (Join-Path $root 'CONTEXT.md')).Hash
                { Assert-CleanGit -Operation $requestedOperation } | Should -Throw '*Git worktree is not clean*'
                Invoke-Git @('commit','--only','-m','reviewed task','--','branch.txt')
                (@(Get-GitPathList -Arguments @('ls-files','--stage','-z','--','CONTEXT.md')) -join "`0") | Should -BeExactly $foreignIndex
                (Get-FileHash -LiteralPath (Join-Path $root 'CONTEXT.md')).Hash | Should -BeExactly $foreignHash
                @(Get-GitPathList -Arguments @('diff-tree','--no-commit-id','--name-only','-r','-z','HEAD')) | Should -Be @('branch.txt')
                # The strict preflight still refuses to hide the foreign work.
                { Assert-CleanGit -Operation $requestedOperation } | Should -Throw '*Git worktree is not clean*'
                $script:RunBlockerOwner.paths | Should -Be @('CONTEXT.md')
            }
        }
    }

    It 'routes both branch creation commands and both refresh commands for every supported client, including native OpenCode' {
        & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            foreach($surface in @('master','dev')) {
                function Get-ItlCommandSurface { $surface }
                foreach($client in @(Get-SupportedAgentTargets)) {
                    $files=Get-ItlExpectedSurfaceFiles -Client $client -SourceRoot $RepoRoot
                    $names=if($surface -eq 'master'){@('itl-new-config-branch','itl-new-extension-branch')}else{@('itl-refresh','itl-refresh-lite')}
                    foreach($name in $names){
                        $content=@($files.Keys|Where-Object{$_ -match ('(^|/)'+[regex]::Escape($name)+'(/SKILL\.md|\.md)$')}|ForEach-Object{$files[$_]})
                        $content | Should -HaveCount 1 -Because "$surface/$client/$name"
                        $content[0] | Should -Match 'prepare-lifecycle-git:' -Because "$surface/$client/$name"
                        $content[0] | Should -Match 'lifecycle-git-continuation.md' -Because "$surface/$client/$name"
                    }
                }
            }
        }
    }

    It 'runs <requestedOperation> through post-load with documents appearing during dependencies, or rejects changed inputs: <inputChange>' -ForEach @(
        @{ requestedOperation='refresh-dev-branch'; inputChange=$false },
        @{ requestedOperation='refresh-dev-branch-lite'; inputChange=$false },
        @{ requestedOperation='refresh-dev-branch'; inputChange=$true },
        @{ requestedOperation='refresh-dev-branch-lite'; inputChange=$true }
    ) {
        $root=New-ContinuationRepository (Join-Path $TestDrive ('Refresh после merge с пробелом '+$requestedOperation+$inputChange))
        & git -C $root checkout -qb itldev/test
        [IO.File]::WriteAllText((Join-Path $root 'branch.txt'),'branch',[Text.UTF8Encoding]::new($false))
        & git -C $root commit -qam branch
        $branchCommit=(& git -C $root rev-parse HEAD).Trim()
        & git -C $root checkout -q master
        [IO.File]::WriteAllText((Join-Path $root 'master.txt'),'master',[Text.UTF8Encoding]::new($false))
        & git -C $root add -- master.txt
        & git -C $root commit -qm master
        $targetCommit=(& git -C $root rev-parse HEAD).Trim()
        & git -C $root checkout -q itldev/test
        & git -C $root merge -q --no-ff -m 'merge master' master
        $mergeCommit=(& git -C $root rev-parse HEAD).Trim()
        & {
            . $HelperPath -ProjectRoot $root -Action help *> $null
            $LifecyclePhase='post-merge'; $DevBranchName='test'
            $script:LoadCalls=0
            $script:ContinuationState=[pscustomobject]@{
                devBranch='itldev/test'; devBranchKind='configuration'; devBranchName='test'; safeDevBranchName='test'
                worktreePath=$root; devBranchInfoBasePath=(Join-Path $root '.agent-1c/fixture-base'); infoBaseKind='file'
                yaxunitApplicabilityBaseline=@{schemaVersion=1}; lastVerificationStatus='failed'
                pendingMergeOperation=$requestedOperation; pendingMergeBranch='itldev/test'; pendingMergeStage='merged'
                pendingMergeBranchCommit=$branchCommit; pendingMergeTargetCommit=$targetCommit
                pendingMergeCommit=$mergeCommit; pendingMergePostMergeHead=$mergeCommit; pendingMergeResult='merge-commit'
            }
            function Read-DevBranchState { $script:ContinuationState }
            function Update-DevBranchState {
                param($State,[hashtable]$Updates)
                foreach($key in $Updates.Keys){$State|Add-Member -NotePropertyName $key -NotePropertyValue $Updates[$key] -Force}
            }
            function Assert-DevelopmentBranchWorktreeContext {}
            function Assert-DevBranchExtensionInitialized {}
            function Sync-DevBranchContextToDotEnv {}
            function Sync-AiRules1cManagedIgnoredFilesFromMain {}
            function Sync-WorkflowManagedDependencyLockEntries {}
            function Update-VerificationSuiteInventory { [pscustomobject]@{yaxunit=@{legacyBaseline=$false};classificationComplete=$true;classificationIssues=@()} }
            function Install-VanessaAutomation {
                [IO.File]::WriteAllText((Join-Path $root 'CONTEXT.md'),'staged docs',[Text.UTF8Encoding]::new($false))
                Invoke-Git @('add','--','CONTEXT.md')
                [IO.File]::WriteAllText((Join-Path $root 'CONTEXT.md'),'unstaged docs',[Text.UTF8Encoding]::new($false))
                [IO.File]::WriteAllText((Join-Path $root 'docs/adr/новое решение.md'),'new docs',[Text.UTF8Encoding]::new($false))
                if($inputChange){[IO.File]::WriteAllText((Join-Path $root 'src/cf/Configuration.xml'),'changed during dependencies',[Text.UTF8Encoding]::new($false))}
                $script:DocumentIndex=@(Get-GitPathList -Arguments @('ls-files','--stage','-z','--','CONTEXT.md')) -join "`0"
            }
            function Get-RoctupMcpEnabled { $false }
            function Install-VanessaMcpArtifacts {}
            function Install-ItlOnDemandMcp {}
            function Invoke-DevBranchDefaultMcpSetup { param($State) $State }
            # This is the native adapter boundary: no real infobase is claimed.
            function Load-ConfigFromFiles {
                $script:LoadCalls++
                [IO.File]::WriteAllText((Join-Path $root 'src/cf/ConfigDumpInfo.xml'),'new cursor',[Text.UTF8Encoding]::new($false))
                [pscustomobject]@{currentCommit=(Get-CurrentCommit);loaded=$true}
            }
            function Invoke-DevBranchEnterpriseAutoUpdateIfLoaded {}
            function Invoke-DevBranchMcpRestartAfterInfobaseLoad { param($State) $State }
            function Sync-KiloItlCommandSurface {}
            function Invoke-AiRules1cManagedMcpConfigReconcile {}
            function Set-ItlOnDemandMcpSemanticReloadRequiredAction {}
            function Set-VerificationClassificationRequiredAction {}
            function New-LoadStateUpdates { @{} }
            function Get-VerificationClassificationInventoryPath { 'fixture-inventory.json' }
            function Get-VerificationState { [pscustomobject]@{status='failed';currentFingerprint='fixture';isFreshPassed=$false} }
            function Write-BaseUpdateResult {}
            function Write-DevBranchRunUserReport {}
            function Save-RefreshClassificationReportContext {}
            function Sync-Master { throw 'COMPLETED_MASTER_MUST_NOT_REPEAT' }
            function Invoke-NewDevBranchLifecycleMerge { throw 'COMPLETED_MERGE_MUST_NOT_REPEAT' }
            $failure=''
            try { Invoke-RefreshDevBranchCore -OperationName $requestedOperation } catch { $failure=$_.Exception.Message }
            if($inputChange){
                $failure | Should -Match 'LIFECYCLE_GIT_INPUTS_CHANGED'
                $script:LoadCalls | Should -Be 0
                $script:ContinuationState.pendingMergeOperation | Should -BeExactly $requestedOperation
                $script:RunBlockerOwner.phase | Should -Be 'before-load'
            }else{
                $failure | Should -BeNullOrEmpty
                $script:LoadCalls | Should -Be 1
                $script:ContinuationState.pendingMergeOperation | Should -BeNullOrEmpty
                $script:ContinuationState.lastRefreshMasterCommit | Should -BeExactly $targetCommit
                $script:ContinuationState.lastVerificationStatus | Should -Be 'failed'
                @(Get-GitPathList -Arguments @('diff-tree','--no-commit-id','--name-only','-r','-z','HEAD')) | Should -Be @('src/cf/ConfigDumpInfo.xml')
            }
            (@(Get-GitPathList -Arguments @('ls-files','--stage','-z','--','CONTEXT.md')) -join "`0") | Should -BeExactly $script:DocumentIndex
            [IO.File]::ReadAllText((Join-Path $root 'CONTEXT.md')) | Should -BeExactly 'unstaged docs'
            [IO.File]::ReadAllText((Join-Path $root 'docs/adr/новое решение.md')) | Should -BeExactly 'new docs'
        }
    }
}
