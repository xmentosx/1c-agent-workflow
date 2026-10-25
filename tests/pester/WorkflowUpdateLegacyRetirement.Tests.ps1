BeforeAll { . (Join-Path $PSScriptRoot 'WorkflowUpdateRollback.TestSupport.ps1') }

Describe 'Branch workflow finalization preserves unrelated index entries' -Tag 'WorkflowFinalize' {
It 'snapshots only exact legacy files before removal and restores their bytes without adopting a custom guide' {
        $fixture=New-FinalizationFixture -Root (Join-Path $TestDrive 'Снимок старых файлов и свой текст')
        & {
            . $helperPath -ProjectRoot $fixture.root -Action help *> $null
            function Get-LegacyWorkflowManagedFileHashes {$fixture.known}
            $paths=@(Get-WorkflowUpdateSnapshotRelativePaths)
            $paths|Should -Contain 'README.md';$paths|Should -Contain 'DEVELOPER-GUIDE.ru.md'
            $paths|Should -Not -Contain 'VANESSA-TESTS-GUIDE.md'
            $snapshot=New-WorkflowUpdateRollbackSnapshot -RelativePaths $paths -SnapshotParent (Join-Path $fixture.root '.agent-1c/snapshots/workflow-update')
            Remove-LegacyWorkflowManagedFiles
            Test-Path (Join-Path $fixture.root 'README.md')|Should -BeFalse
            Restore-WorkflowUpdateRollbackSnapshot -Snapshot $snapshot
            (Get-FileHash (Join-Path $fixture.root 'README.md')).Hash|Should -BeExactly $fixture.known['README.md'][0]
            (Get-FileHash (Join-Path $fixture.root 'DEVELOPER-GUIDE.ru.md')).Hash|Should -BeExactly $fixture.known['DEVELOPER-GUIDE.ru.md'][0]
            [IO.File]::ReadAllText((Join-Path $fixture.root 'VANESSA-TESTS-GUIDE.md'))|Should -BeExactly 'custom user document'
        }
    }

It 'finishes known legacy retirement through the branch update owner with AlreadyAbsent=<AlreadyAbsent>' -ForEach @(@{AlreadyAbsent=$false},@{AlreadyAbsent=$true}) {
        $fixture=New-FinalizationFixture -Root (Join-Path $TestDrive ('Штатное завершение старых файлов '+$AlreadyAbsent)) -BusinessConflict
        & {
            . $helperPath -ProjectRoot $fixture.root -Action help -SkipAiRules *> $null
            function Get-LegacyWorkflowManagedFileHashes {$fixture.known}
            function Assert-WorkflowUpdateDevelopmentBranchRoot {}
            function Read-DevBranchState { [pscustomobject]@{devBranch='itldev/finalize';worktreePath=$fixture.root} }
            function Copy-WorkflowManagedDirectory {}
            function Copy-WorkflowManagedFile {}
            function Update-WorkflowPackageLockEntry {}
            function Get-WorkflowUpdateExpectedClientWritePaths {@()}
            function Invoke-WorkflowPackageFilePostCopy {[pscustomobject]@{aiRulesPathsBefore=@();clientSurfacePathsBefore=@()}}
            function Enable-WorkflowExecutionGuardForCurrentRoot {}
            function Set-ItlOnDemandMcpSemanticReloadRequiredAction {}
            $businessBefore=@(Get-GitPathList -Arguments @('ls-files','--stage','-z','--','src/cf')) -join "`0"
            $merge=(Get-GitOutput @('rev-parse','--git-path','MERGE_HEAD')).Trim()
            if(-not [IO.Path]::IsPathRooted($merge)){$merge=Join-Path $fixture.root $merge}
            $mergeBefore=(Get-FileHash -LiteralPath $merge).Hash
            $anchor=Get-CurrentCommit
            $lockSha=(Get-FileHash (Join-Path $fixture.root '.agent-1c/dependency-lock.json')).Hash.ToLowerInvariant()
            if($AlreadyAbsent){Remove-Item -LiteralPath (Join-Path $fixture.root 'README.md'),(Join-Path $fixture.root 'DEVELOPER-GUIDE.ru.md')}
            $result=Invoke-WorkflowDevelopmentBranchUpdate -Source ([pscustomobject]@{root=$repoRoot;commit=('a'*40);ref='master';repo='fixture';source='path'})
            $result.status|Should -BeExactly 'completed'
            @(Get-GitPathList -Arguments @('ls-tree','--name-only','-z','HEAD','--','README.md','DEVELOPER-GUIDE.ru.md'))|Should -HaveCount 0
            @(Get-GitPathList -Arguments @('status','--porcelain=v1','-z','--untracked-files=no','--','README.md','DEVELOPER-GUIDE.ru.md'))|Should -HaveCount 0
            (@(Get-GitPathList -Arguments @('ls-files','--stage','-z','--','src/cf')) -join "`0")|Should -BeExactly $businessBefore
            (Get-FileHash -LiteralPath $merge).Hash|Should -BeExactly $mergeBefore
            [IO.File]::ReadAllText((Join-Path $fixture.root 'VANESSA-TESTS-GUIDE.md'))|Should -BeExactly 'custom user document'
            $retained=@(Get-ChildItem (Join-Path $fixture.root '.agent-1c/snapshots/workflow-update') -Directory -Filter 'itl-workflow-update-completed-*')
            $retained|Should -HaveCount 1
            $receipt=Read-Utf8Text -Path (Join-Path $retained[0].FullName 'transaction.json')|ConvertFrom-Json
            @($receipt.records.relativePath)|Should -Contain 'README.md'
            @($receipt.records.relativePath)|Should -Not -Contain 'VANESSA-TESTS-GUIDE.md'
            Assert-DevBranchForkWorkflowTransition -OriginalCommit $anchor -OriginalDependencyLockSha256 $lockSha
        }
    }

It 'preserves a custom README arriving after snapshot capture and completes the same <Owner> update after preserving <Conflict>' -ForEach @(@{Owner='branch';Conflict='worktree'},@{Owner='master';Conflict='worktree'},@{Owner='branch';Conflict='staged'},@{Owner='master';Conflict='staged'}) {
        $fixture=New-FinalizationFixture -Root (Join-Path $TestDrive ('Поздний пользовательский README '+$Owner+' '+$Conflict)) -BusinessConflict:($Owner -eq 'branch')
        if($Owner -eq 'master'){
            & git -C $fixture.root restore --source=HEAD --staged --worktree -- src/cf;$LASTEXITCODE|Should -Be 0
            & git -C $fixture.root branch -M master;$LASTEXITCODE|Should -Be 0
        }
        & {
            . $helperPath -ProjectRoot $fixture.root -Action help -SkipAiRules *> $null
            $source=[pscustomobject]@{root=$repoRoot;commit=('a'*40);ref='master';repo='fixture';source='path'}
            function Get-LegacyWorkflowManagedFileHashes {$fixture.known}
            function Assert-WorkflowUpdateDevelopmentBranchRoot {}
            function Read-DevBranchState {[pscustomobject]@{devBranch='itldev/finalize';worktreePath=$fixture.root}}
            function Copy-WorkflowManagedDirectory {}
            $script:lateReadmeInjected=$false
            function Copy-WorkflowManagedFile {
                if(-not $script:lateReadmeInjected){
                    [IO.File]::WriteAllText((Join-Path $fixture.root 'README.md'),'late custom README',[Text.UTF8Encoding]::new($false))
                    if($Conflict -eq 'staged'){
                        Invoke-Git @('add','--','README.md')
                        $script:lateReadmeIndex=@(Get-GitPathList -Arguments @('ls-files','--stage','-z','--','README.md'))
                        $script:lateReadmeBlob=(Get-GitOutput @('rev-parse',':README.md')).Trim()
                        [IO.File]::WriteAllText((Join-Path $fixture.root 'README.md'),"known readme`r`n",[Text.UTF8Encoding]::new($false))
                    }
                    $script:lateReadmeInjected=$true
                }
            }
            function Update-WorkflowPackageLockEntry {}
            function Get-WorkflowUpdateExpectedClientWritePaths {@()}
            function Invoke-WorkflowPackageFilePostCopy {[pscustomobject]@{aiRulesPathsBefore=@();clientSurfacePathsBefore=@()}}
            function Enable-WorkflowExecutionGuardForCurrentRoot {}
            function Set-ItlOnDemandMcpSemanticReloadRequiredAction {}
            function Resolve-WorkflowPackageSource {$source}
            function Assert-WorkflowUpdateRecordedSource {}
            function Assert-WorkflowPackageUpdateContext {}
            function Resolve-WorkflowUpdateRecoveryExecutor {$null}
            function Assert-WorkflowDevelopmentBranchRolloutComplete {}
            function Invoke-WorkflowDevelopmentBranchRollout {[pscustomobject]@{roots=@()}}
            function Write-WorkflowUpdateFollowUp {}
            function Read-DependencyLockManifest {@{dependencies=@{workflowPackage=@{source='path';commit=('a'*40);ref='master';repo='fixture'}}}}
            function Invoke-Agent1cFreshProcess {
                & {$LifecyclePhase='post-copy';$OperationContinuation=$true;Update-WorkflowPackage}
                [pscustomobject]@{exitCode=0}
            }
            $headBefore=Get-CurrentCommit
            $indexBefore=@(Get-GitPathList -Arguments @('ls-files','--stage','-z')) -join "`0"
            if($Owner -eq 'master'){
                $snapshot=New-WorkflowUpdateRollbackSnapshot -RelativePaths @(Get-WorkflowUpdateSnapshotRelativePaths) -SnapshotParent (Join-Path $fixture.root '.agent-1c/snapshots/workflow-update')
                Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase prepared
                Copy-WorkflowManagedFile
                Remove-LegacyWorkflowManagedFiles
                Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase post-copy-running
                {Update-WorkflowPackage}|Should -Throw '*WORKFLOW_UPDATE_LEGACY_RETIREMENT_CHANGED*'
            }else{
                {Invoke-WorkflowDevelopmentBranchUpdate -Source $source}|Should -Throw '*WORKFLOW_UPDATE_LEGACY_RETIREMENT_CHANGED*'
            }
            if($Conflict -eq 'worktree'){
                [IO.File]::ReadAllText((Join-Path $fixture.root 'README.md'))|Should -BeExactly 'late custom README'
                (@(Get-GitPathList -Arguments @('ls-files','--stage','-z')) -join "`0")|Should -BeExactly $indexBefore
            }else{
                Test-Path (Join-Path $fixture.root 'README.md')|Should -BeFalse
                (@(Get-GitPathList -Arguments @('ls-files','--stage','-z','--','README.md')) -join "`0")|Should -BeExactly ($script:lateReadmeIndex -join "`0")
            }
            Get-CurrentCommit|Should -BeExactly $headBefore
            $pending=Get-WorkflowUpdatePendingSnapshot
            $pending.receipt.phase|Should -BeExactly 'post-copy-failed'
            $id=(Split-Path -Leaf $pending.snapshot.root).Substring('itl-workflow-update-rollback-'.Length)
            $saved=Join-Path $fixture.root '.agent-1c/tmp/preserved-user-readme.md'
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $saved)|Out-Null
            if($Conflict -eq 'worktree'){
                Copy-Item -LiteralPath (Join-Path $fixture.root 'README.md') -Destination $saved
                Remove-Item -LiteralPath (Join-Path $fixture.root 'README.md')
            }else{
                $blobs=Get-GitBlobBytesBatch -ObjectIds @($script:lateReadmeBlob)
                [IO.File]::WriteAllBytes($saved,[byte[]]$blobs[$script:lateReadmeBlob])
                Invoke-Git @('reset','--quiet','HEAD','--','README.md')
            }
            $status=Get-WorkflowUpdateRecoveryStatus -SnapshotId $id
            $status.changedPathCount|Should -Be $(if($Conflict -eq 'worktree'){1}else{0})
            $report=Read-Utf8Text -Path $status.reportPath|ConvertFrom-Json
            $decision=@{schemaVersion=1;reportPath=$status.reportPath;reportSha256=$status.reportSha256;paths=@($report.paths|ForEach-Object{
                @{relativePath=$_.relativePath;observedState=$_.observedState;decision='resume-confirmed-helper-output';reason="Preserved the late user document byte-for-byte at $saved; completed only the known legacy retirement output (absence)."}
            })}
            $decisionPath=Join-Path $fixture.root '.agent-1c/tmp/retirement-reconciliation.json'
            [IO.File]::WriteAllText($decisionPath,($decision|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
            if($Conflict -eq 'worktree'){Complete-WorkflowUpdateReconciliation -SnapshotId $id -DecisionFile $decisionPath}
            if($Owner -eq 'master'){Update-WorkflowPackage}else{(Invoke-WorkflowDevelopmentBranchUpdate -Source $source).status|Should -BeExactly 'completed'}
            Get-WorkflowUpdatePendingSnapshot|Should -BeNullOrEmpty
            [IO.File]::ReadAllText($saved)|Should -BeExactly 'late custom README'
            @(Get-GitPathList -Arguments @('ls-tree','--name-only','-z','HEAD','--','README.md'))|Should -HaveCount 0
            $businessBefore=@($indexBefore.Split([char]0)|Where-Object{$_ -match "`tsrc/cf/"}) -join "`0"
            (@(Get-GitPathList -Arguments @('ls-files','--stage','-z','--','src/cf')) -join "`0")|Should -BeExactly $businessBefore
            Copy-Item -LiteralPath $saved -Destination (Join-Path $fixture.root 'README.md')
            if($Conflict -eq 'staged'){
                $script:lateReadmeIndex[0]|Should -Match '^([0-7]{6}) [a-f0-9]+ 0\tREADME.md$'
                $mode=[regex]::Match($script:lateReadmeIndex[0],'^([0-7]{6}) ').Groups[1].Value
                Invoke-Git @('update-index','--add','--cacheinfo',("$mode,$($script:lateReadmeBlob),README.md"))
                (@(Get-GitPathList -Arguments @('ls-files','--stage','-z','--','README.md')) -join "`0")|Should -BeExactly ($script:lateReadmeIndex -join "`0")
                (Get-GitOutput @('hash-object','--','README.md')).Trim()|Should -BeExactly $script:lateReadmeBlob
                (@(Get-GitPathList -Arguments @('ls-files','--stage','-z','--','src/cf')) -join "`0")|Should -BeExactly $businessBefore
            }
            @(Get-WorkflowUpdateEligibleLegacyPaths)|Should -Not -Contain 'README.md'
            $rollbackError=if($Owner -eq 'branch'){'*WORKFLOW_UPDATE_ROLLBACK_PENDING_MERGE*'}else{'*WORKFLOW_UPDATE_RECONCILIATION_REQUIRED*'}
            {Restore-CompletedWorkflowUpdate -SnapshotId $id}|Should -Throw $rollbackError
            [IO.File]::ReadAllText((Join-Path $fixture.root 'README.md'))|Should -BeExactly 'late custom README'
        }
    }

It 'does not certify custom legacy bytes while recording <Phase>' -ForEach @(@{Phase='branch-commit-ready'},@{Phase='master-commit-ready'}) {
        $fixture=New-FinalizationFixture -Root (Join-Path $TestDrive ('Граница записи '+$Phase))
        & {
            . $helperPath -ProjectRoot $fixture.root -Action help *> $null
            function Get-LegacyWorkflowManagedFileHashes {$fixture.known}
            $source=[pscustomobject]@{root=$repoRoot;commit=('a'*40);ref='master';repo='fixture';source='path'}
            $snapshot=New-WorkflowUpdateRollbackSnapshot -RelativePaths @(Get-WorkflowUpdateSnapshotRelativePaths) -SnapshotParent (Join-Path $fixture.root '.agent-1c/snapshots/workflow-update')
            Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase prepared
            Remove-LegacyWorkflowManagedFiles
            Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase post-copy-running
            $before=(Get-FileHash (Join-Path $snapshot.root 'transaction.json')).Hash
            [IO.File]::WriteAllText((Join-Path $fixture.root 'README.md'),'late custom README',[Text.UTF8Encoding]::new($false))
            {Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase $Phase}|Should -Throw '*WORKFLOW_UPDATE_LEGACY_RETIREMENT_CHANGED*'
            (Get-FileHash (Join-Path $snapshot.root 'transaction.json')).Hash|Should -BeExactly $before
            $saved=Join-Path $TestDrive ('Сохранённый README '+$Phase)
            Copy-Item -LiteralPath (Join-Path $fixture.root 'README.md') -Destination $saved
            Remove-Item -LiteralPath (Join-Path $fixture.root 'README.md')
            Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase $Phase
            (Get-WorkflowUpdatePendingSnapshot).receipt.phase|Should -BeExactly $Phase
            [IO.File]::ReadAllText($saved)|Should -BeExactly 'late custom README'
        }
    }
}
