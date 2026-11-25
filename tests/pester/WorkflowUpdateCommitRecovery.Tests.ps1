BeforeAll { . (Join-Path $PSScriptRoot 'WorkflowUpdateRollback.TestSupport.ps1') }

Describe 'Branch workflow finalization preserves unrelated index entries' -Tag 'WorkflowFinalize' {
It 'replays a ready receipt after the <Owner> commit without requiring the retired original index entries' -ForEach @(@{Owner='branch'},@{Owner='master'}) {
        $fixture=New-FinalizationFixture -Root (Join-Path $TestDrive ('Подтверждение после коммита '+$Owner)) -BusinessConflict:($Owner -eq 'branch')
        if($Owner -eq 'master'){
            & git -C $fixture.root restore --source=HEAD --staged --worktree -- src/cf;$LASTEXITCODE|Should -Be 0
            & git -C $fixture.root branch -M master;$LASTEXITCODE|Should -Be 0
        }
        & {
            . $helperPath -ProjectRoot $fixture.root -Action help -SkipAiRules *> $null
            function Get-LegacyWorkflowManagedFileHashes {$fixture.known}
            function Assert-WorkflowUpdateDevelopmentBranchRoot {}
            function Read-DevBranchState {[pscustomobject]@{devBranch='itldev/finalize';worktreePath=$fixture.root}}
            function Assert-WorkflowUpdateRecordedSource {}
            function Enable-WorkflowExecutionGuardForCurrentRoot {}
            function Set-ItlOnDemandMcpSemanticReloadRequiredAction {}
            function Invoke-WorkflowDevelopmentBranchRollout {[pscustomobject]@{roots=@()}}
            function Write-WorkflowUpdateFollowUp {}
            function Read-DependencyLockManifest {@{dependencies=@{workflowPackage=@{source='path';commit=('a'*40);ref='master';repo='fixture'}}}}
            function Invoke-WorkflowPackageFilePostCopy {throw 'A committed checkpoint must not replay file post-copy.'}
            $readyMcpRefresh=@{calls=0}
            function Refresh-Vibecoding1cMcpRegistry {$readyMcpRefresh.calls++;throw 'A ready checkpoint must not refresh the registry.'}
            $selectionPath=Get-Vibecoding1cMcpSelectionPath
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $selectionPath)|Out-Null
            Write-Utf8Text -Path $selectionPath -Value '{}'
            $source=[pscustomobject]@{root=$repoRoot;commit=('a'*40);ref='master';repo='fixture';source='path'}
            $before=Get-CurrentCommit
            $businessBefore=@(Get-GitPathList -Arguments @('ls-files','--stage','-z','--','src/cf')) -join "`0"
            # Both original-backup and originally-absent/immutable-HEAD proofs
            # must survive the successful commit removing the stage-zero entry.
            if($Owner -eq 'master'){Remove-LegacyWorkflowManagedFiles}
            $snapshot=New-WorkflowUpdateRollbackSnapshot -RelativePaths @(Get-WorkflowUpdateSnapshotRelativePaths) -SnapshotParent (Join-Path $fixture.root '.agent-1c/snapshots/workflow-update')
            @($snapshot.records.relativePath)|Should -Contain 'README.md'
            Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase prepared
            Remove-LegacyWorkflowManagedFiles
            $details=@{}
            if($Owner -eq 'branch'){
                $phase='branch-commit-ready'
                $plan=New-WorkflowBranchCommitPlan -ManagedPathSpecs @('README.md','DEVELOPER-GUIDE.ru.md')
                Save-WorkflowBranchCommitPlanReceipt -Snapshot $snapshot -Plan $plan
                Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase $phase
                Apply-WorkflowBranchCommitPlan -Plan $plan|Out-Null
            }else{
                $phase='master-commit-ready'
                $details=@{preCommitHead=$before;plannedChangePaths=@('README.md','DEVELOPER-GUIDE.ru.md');aiRulesPathsBefore=@();clientSurfacePathsBefore=@()}
                Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase $phase -Details $details
                (Commit-WorkflowUpdate -Source $source).created|Should -BeTrue
            }
            $committed=Get-CurrentCommit
            $committed|Should -Not -BeExactly $before
            @(Get-GitPathList -Arguments @('ls-files','--stage','-z','--','README.md','DEVELOPER-GUIDE.ru.md'))|Should -HaveCount 0
            # This is the same ready-phase receipt rewrite used by IM6 when a
            # new executor resumes the pinned candidate after a lost ACK.
            Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase $phase -Details @{
                recoveryExecutorRoot=$repoRoot;recoveryExecutorCommit=('b'*40)
            }
            (Get-WorkflowUpdatePendingSnapshot).receipt.preUpdateHead|Should -BeExactly $before
            if($Owner -eq 'branch'){
                (Invoke-WorkflowDevelopmentBranchUpdate -Source $source).status|Should -BeExactly 'completed'
            }else{
                (Assert-WorkflowUpdateMasterCommitCheckpoint -Receipt (Get-WorkflowUpdatePendingSnapshot).receipt -Source $source).committed|Should -BeTrue
                & {$LifecyclePhase='post-copy';$OperationContinuation=$true;Update-WorkflowPackage}
            }
            Get-CurrentCommit|Should -BeExactly $committed
            $readyMcpRefresh.calls|Should -Be 0
            Get-WorkflowUpdatePendingSnapshot|Should -BeNullOrEmpty
            (@(Get-GitPathList -Arguments @('ls-files','--stage','-z','--','src/cf')) -join "`0")|Should -BeExactly $businessBefore
            $retained=@(Get-ChildItem (Join-Path $fixture.root '.agent-1c/snapshots/workflow-update') -Directory -Filter 'itl-workflow-update-completed-*')
            $retained|Should -HaveCount 1
            $id=$retained[0].Name.Substring('itl-workflow-update-completed-'.Length)
            (Get-WorkflowUpdateCompletedSnapshot -SnapshotId $id).receipt.completedHead|Should -BeExactly $committed
        }
    }

It 'rejects a forged fork transition which <Change> even with a complete consistent update capsule' -ForEach @(@{Change='deletes a custom README'},@{Change='rewrites a known README'}) {
        $fixture=New-FinalizationFixture -Root (Join-Path $TestDrive ('Недопустимый переход '+$Change))
        & {
            . $helperPath -ProjectRoot $fixture.root -Action help *> $null
            function Get-LegacyWorkflowManagedFileHashes {$fixture.known}
            $path=Join-Path $fixture.root 'README.md'
            if($Change -eq 'deletes a custom README'){
                [IO.File]::WriteAllText($path,'custom README',[Text.UTF8Encoding]::new($false))
                Invoke-Git @('add','--','README.md');Invoke-Git @('commit','-qm','custom README')
            }
            $anchor=Get-CurrentCommit
            $lockSha=(Get-FileHash (Join-Path $fixture.root '.agent-1c/dependency-lock.json')).Hash.ToLowerInvariant()
            $source=[pscustomobject]@{root=$repoRoot;commit=('a'*40);ref='master';repo='fixture';source='path'}
            $snapshot=New-WorkflowUpdateRollbackSnapshot -RelativePaths @('README.md','.agent-1c/dependency-lock.json') -SnapshotParent (Join-Path $fixture.root '.agent-1c/snapshots/workflow-update')
            Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase prepared
            if($Change -eq 'deletes a custom README'){Remove-Item -LiteralPath $path}else{[IO.File]::WriteAllText($path,'rewritten legacy doc',[Text.UTF8Encoding]::new($false))}
            $plan=New-WorkflowBranchCommitPlan -ManagedPathSpecs @('README.md','.agent-1c/dependency-lock.json')
            Save-WorkflowBranchCommitPlanReceipt -Snapshot $snapshot -Plan $plan
            Apply-WorkflowBranchCommitPlan -Plan $plan|Out-Null
            Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase post-copy-complete
            $retained=Retain-WorkflowUpdateRollbackSnapshot -Snapshot $snapshot
            $id=(Split-Path -Leaf $retained).Substring('itl-workflow-update-completed-'.Length)
            $completed=Get-WorkflowUpdateCompletedSnapshot -SnapshotId $id
            (Read-WorkflowBranchCommitPlanReceipt -Snapshot $completed.snapshot).newHead|Should -BeExactly $plan.newHead
            {Assert-DevBranchForkWorkflowTransition -OriginalCommit $anchor -OriginalDependencyLockSha256 $lockSha}|Should -Throw '*DEV_BRANCH_FORK_WORKFLOW_BUSINESS_CHANGE*'
        }
    }

It 'never adopts a custom or staged README from its basename: <Case>' -ForEach @(@{Case='custom-existing'},@{Case='custom-deleted'},@{Case='staged-deletion'},@{Case='staged-content'},@{Case='unmerged'}) {
        $fixture=New-FinalizationFixture -Root (Join-Path $TestDrive ('Чужой README '+$Case))
        & {
            . $helperPath -ProjectRoot $fixture.root -Action help *> $null
            function Get-LegacyWorkflowManagedFileHashes {$fixture.known}
            $path=Join-Path $fixture.root 'README.md'
            if($Case -like 'custom-*'){
                [IO.File]::WriteAllText($path,'user-owned README',[Text.UTF8Encoding]::new($false))
                Invoke-Git @('add','--','README.md');Invoke-Git @('commit','-qm','user readme')
                if($Case -eq 'custom-deleted'){Remove-Item -LiteralPath $path}
            }elseif($Case -eq 'staged-deletion'){
                Invoke-Git @('rm','--','README.md')
            }elseif($Case -eq 'staged-content'){
                [IO.File]::WriteAllText($path,'staged user README',[Text.UTF8Encoding]::new($false));Invoke-Git @('add','--','README.md');Remove-Item -LiteralPath $path
            }else{
                $blob=(Get-GitOutput @('rev-parse','HEAD:README.md')).Trim()
                Invoke-Git @('update-index','--force-remove','--','README.md')
                $records="100644 $blob 1`tREADME.md`0"+"100644 $blob 2`tREADME.md`0"+"100644 $blob 3`tREADME.md`0"
                # Native PS5 string piping appends CRLF; index-info requires
                # only the three exact NUL-delimited records, without a fourth line.
                $start=[Diagnostics.ProcessStartInfo]::new()
                $start.FileName='git'
                $start.Arguments=Join-NativeCommandLineArguments -Arguments @('-C',$fixture.root,'update-index','-z','--index-info')
                $start.UseShellExecute=$false;$start.CreateNoWindow=$true
                $start.RedirectStandardInput=$true;$start.RedirectStandardError=$true
                $start.StandardErrorEncoding=[Text.UTF8Encoding]::new($false)
                $process=[Diagnostics.Process]::new();$process.StartInfo=$start
                try{
                    $process.Start()|Should -BeTrue
                    $inputBytes=[Text.UTF8Encoding]::new($false).GetBytes($records)
                    $process.StandardInput.BaseStream.Write($inputBytes,0,$inputBytes.Length)
                    $process.StandardInput.BaseStream.Flush();$process.StandardInput.Close()
                    $errorText=$process.StandardError.ReadToEnd();$process.WaitForExit()
                    $process.ExitCode|Should -Be 0 -Because $errorText
                }finally{$process.Dispose()}
                $stages=@(Get-GitPathList -Arguments @('ls-files','--stage','-z','--','README.md'))
                $stages|Should -Be @("100644 $blob 1`tREADME.md","100644 $blob 2`tREADME.md","100644 $blob 3`tREADME.md")
                Remove-Item -LiteralPath $path
            }
            $indexBefore=@(Get-GitPathList -Arguments @('ls-files','--stage','-z','--','README.md')) -join "`0"
            @(Get-WorkflowUpdateEligibleLegacyPaths)|Should -Not -Contain 'README.md'
            @(Get-WorkflowUpdateDeletedLegacyPaths)|Should -Not -Contain 'README.md'
            @(Get-WorkflowUpdateSnapshotRelativePaths)|Should -Not -Contain 'README.md'
            Remove-LegacyWorkflowManagedFiles
            (@(Get-GitPathList -Arguments @('ls-files','--stage','-z','--','README.md')) -join "`0")|Should -BeExactly $indexBefore
            if($Case -eq 'custom-existing'){[IO.File]::ReadAllText($path)|Should -BeExactly 'user-owned README'}
        }
    }

It 'detects staged user edits before deleting exact known working bytes in the explicitly inspected root' {
        $fixture=New-FinalizationFixture -Root (Join-Path $TestDrive 'Явно проверяемый корень')
        & {
            . $helperPath -ProjectRoot $fixture.root -Action help *> $null
            function Get-LegacyWorkflowManagedFileHashes {$fixture.known}
            $path=Join-Path $fixture.root 'README.md'
            [IO.File]::WriteAllText($path,'staged user README',[Text.UTF8Encoding]::new($false));Invoke-Git @('add','--','README.md')
            [IO.File]::WriteAllText($path,"known readme`r`n",[Text.UTF8Encoding]::new($false))
            $previousRoot=$script:ProjectRoot
            try{$script:ProjectRoot=$repoRoot;@(Get-WorkflowUpdateRootWriteSetConflicts -Root $fixture.root)|Should -Contain 'README.md'}finally{$script:ProjectRoot=$previousRoot}
            (Get-FileHash $path).Hash|Should -BeExactly $fixture.known['README.md'][0]
        }
    }
}
