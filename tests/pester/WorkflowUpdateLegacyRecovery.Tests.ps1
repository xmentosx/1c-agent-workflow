BeforeAll {
        . (Join-Path $PSScriptRoot 'WorkflowUpdateRollback.TestSupport.ps1')
        # Cache only immutable historical source/compiled definitions in this
        # worker. Every case still creates its own repositories, commits and
        # incident by executing the real historical updater below.
        $script:legacyUpdaterSource = $null
        $script:legacyHelperTexts = @{}
        function Get-LegacyHelperText {
            param([string]$Commit, [string]$Relative)
            $key = $Commit + ':' + $Relative
            if (-not $script:legacyHelperTexts.ContainsKey($key)) {
                $blob=(& git -C $repoRoot rev-parse ($key)).Trim()
                $script:legacyHelperTexts[$key]=[Text.Encoding]::UTF8.GetString((Get-GitBlobBytesBatch -Root $repoRoot -ObjectIds @($blob))[$blob])
            }
            return $script:legacyHelperTexts[$key]
        }
        function Get-LegacyHelperDefinitions {
            param([string]$Commit, [string]$Relative, [string[]]$Names)
            $parseErrors=$null
            $ast=[Management.Automation.Language.Parser]::ParseInput((Get-LegacyHelperText -Commit $Commit -Relative $Relative),[ref]$null,[ref]$parseErrors)
            @($parseErrors).Count | Should -Be 0
            foreach($name in $Names) {
                $matches=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true))
                $matches.Count | Should -Be 1
                [scriptblock]::Create($matches[0].Extent.Text)
            }
        }
        function New-LegacyRawCopyFixture {
            # -PrepareOnly leaves the project at the published old HEAD for a
            # case that executes its own historical parent.
            param([string]$Root, [string]$Candidate, [string]$Executor,
                [string]$LegacyCommit = '6bb6932802f78f8699b06ed49b69eba14dceff09', [switch]$PrepareOnly)
            foreach ($directory in @($Root,$Candidate,$Executor)) {
                New-Item -ItemType Directory -Force -Path $directory | Out-Null
                & git -C $directory init -q -b master
                & git -C $directory config user.name 'Legacy Copy Test'
                & git -C $directory config user.email 'legacy-copy@example.invalid'
                & git -C $directory config core.autocrlf false
            }
            foreach ($relative in @(@(Get-WorkflowPackageCopyDirectoryPaths | ForEach-Object { $_ + '/SKILL.md' }) +
                @(Get-WorkflowPackageCopyFilePaths) + @('.agents/skills/1c-workflow/scripts/agent-1c.ps1','.agents/skills/1c-workflow/scripts/lib/agent-1c.local-patch.ps1','templates/USER-RULES.append.md'))) {
                $path=Join-Path $Candidate $relative
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
                [IO.File]::WriteAllText($path, 'candidate bytes', [Text.UTF8Encoding]::new($false))
            }
            $relative='.agents/skills/1c-workflow/scripts/lib/agent-1c.lifecycle.ps1'
            if (-not $PrepareOnly -and $null -eq $script:legacyUpdaterSource) {
                $definitions=@(Get-LegacyHelperDefinitions -Commit $LegacyCommit -Relative $relative -Names @('Update-WorkflowPackage','New-WorkflowUpdateRollbackSnapshot','Remove-WorkflowUpdateRollbackSnapshot'))
                $script:legacyUpdaterSource=[pscustomobject]@{definitions=$definitions}
            }
            $oldText=Get-LegacyHelperText -Commit $LegacyCommit -Relative $relative
            $path=Join-Path $Candidate $relative
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
            [IO.File]::WriteAllText($path, 'function Save-WorkflowUpdateSnapshotReceipt {}', [Text.UTF8Encoding]::new($false))
            & git -C $Candidate add --all
            & git -C $Candidate commit -qm candidate
            $candidateCommit=(& git -C $Candidate rev-parse HEAD).Trim()
            foreach ($item in @(Get-ChildItem -LiteralPath $Candidate -Force | Where-Object Name -NE '.git')) {
                Copy-Item -LiteralPath $item.FullName -Destination $Root -Recurse -Force
                Copy-Item -LiteralPath $item.FullName -Destination $Executor -Recurse -Force
            }
            & git -C $Executor add --all
            & git -C $Executor commit -qm executor
            [IO.File]::WriteAllText((Join-Path $Root $relative), $oldText, [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $Root 'AGENT-INSTALL.md'),'old package',[Text.UTF8Encoding]::new($false))
            New-Item -ItemType Directory -Force -Path (Join-Path $Root '.agent-1c'),(Join-Path $Root 'src/cf') | Out-Null
            [IO.File]::WriteAllText((Join-Path $Root '.gitignore'), ".agent-1c/snapshots/`n.dev.env`ntemplates/custom.secret`n", [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $Root 'src/cf/Продукт.bsl'),'unchanged product',[Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $Root '.agent-1c/project.json'),'{"aiRules":{"tools":["codex"]}}',[Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $Root '.agent-1c/dependency-lock.json'),'{"schemaVersion":1,"dependencies":{"workflowPackage":{"repo":"fixture","ref":"develop","commit":"6bb6932802f78f8699b06ed49b69eba14dceff09","source":"git","updatedAt":"before"},"custom":{"value":"keep"}}}',[Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $Root '.dev.env'),'CUSTOM=Сохранить настройки',[Text.UTF8Encoding]::new($false))
            & git -C $Root add --all
            & git -C $Root commit -qm baseline
            # Preserve a retirement archive and the distinct retirement commit,
            # as in the incident. Recovery must never reset either boundary.
            [IO.File]::WriteAllText((Join-Path $Root '.agents/skills/1c-workflow/scripts/lib/agent-1c.local-patch.ps1'),'retired patch',[Text.UTF8Encoding]::new($false))
            & git -C $Root add --all
            & git -C $Root commit -qm 'chore: retire temporary ITL workflow patch'
            $archive=Join-Path $Root '.agent-1c/snapshots/workflow-incidents/retired/patch.json'
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $archive) | Out-Null
            [IO.File]::WriteAllText($archive,'retained retirement evidence',[Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $Candidate 'templates/new-managed.txt'),'new package file',[Text.UTF8Encoding]::new($false))
            & git -C $Candidate add --all
            & git -C $Candidate commit -qm 'new managed file'
            $candidateCommit=(& git -C $Candidate rev-parse HEAD).Trim()
            $source=[pscustomobject]@{root=$Candidate;commit=$candidateCommit;repo='fixture';ref='develop';source='git'}
            if ($PrepareOnly) { return [pscustomobject]@{source=$source;archive=$archive} }
            $currentUpdate=(Get-Item Function:Update-WorkflowPackage).ScriptBlock
            # Execute the REAL pre-transaction updater and its temporary-backup
            # functions. Only dependency provisioning and its child boundary are
            # stubbed. The missing receipt/backup is produced, not prearranged.
            & {
                foreach($definition in $script:legacyUpdaterSource.definitions) { . $definition }
                $oldRemove=(Get-Item Function:Remove-WorkflowUpdateRollbackSnapshot).ScriptBlock
                function Remove-WorkflowUpdateRollbackSnapshot {
                    param($Snapshot)
                    $script:legacyRemovedBackup=$Snapshot.root
                    & $oldRemove -Snapshot $Snapshot
                }
                function Resolve-WorkflowPackageSource { $source }
                # This parent's cached checkout is gone, so the copied post-copy
                # owner must keep the reviewed source-side recovery.
                function Get-WorkflowPackageLegacyTempRoot { Join-Path $TestDrive 'no legacy parent source' }
                function Assert-WorkflowSourceAiRulesInstallable {}
                function Invoke-WorkflowLocalPatchStep {}
                function Invoke-Agent1cFreshProcess {
                    $LifecyclePhase='post-copy'; $OperationContinuation=$true
                    & $currentUpdate
                }
                { Update-WorkflowPackage } | Should -Throw '*WORKFLOW_UPDATE_POST_COPY_RECEIPT_MISSING*Automatic adoption was refused*SOURCE_MISSING*'
            }
            [IO.File]::WriteAllText((Join-Path $Root 'templates/custom.secret'),'current ignored custom bytes',[Text.UTF8Encoding]::new($false))
            New-Item -ItemType Directory -Force -Path (Join-Path $Root 'handoffs') | Out-Null
            [IO.File]::WriteAllText((Join-Path $Root 'handoffs/keep.md'),'unrelated untracked evidence',[Text.UTF8Encoding]::new($false))
            return [pscustomobject]@{source=$source;executor=[pscustomobject]@{root=$Executor;commit=(& git -C $Executor rev-parse HEAD).Trim()};archive=$archive;removedBackup=$script:legacyRemovedBackup}
        }
}

Describe 'Legacy raw-copy recovery without receipt or backup' {
    BeforeEach {
        $root=Join-Path $TestDrive ('Legacy проект с пробелом '+[guid]::NewGuid().ToString('N'))
        . $helperPath -ProjectRoot $root -Action help *> $null
        $fixture=New-LegacyRawCopyFixture -Root $root -Candidate ($root+' candidate') -Executor ($root+' executor')
        $script:legacyFixture=$fixture
        $script:Agent1cScriptRoot=Join-Path $fixture.executor.root '.agents/skills/1c-workflow/scripts'
        $script:Agent1cScriptPath=Join-Path $script:Agent1cScriptRoot 'agent-1c.ps1'
        $WorkflowUpdateLegacySourceRoot=$fixture.source.root
        $WorkflowUpdateRecovery='legacy-status'
        $LifecyclePhase=''
        $SkipAiRules=$true
        Mock Resolve-WorkflowPackageSource { $script:legacyFixture.executor }
        Mock Get-WorkflowUpdateExpectedClientWritePaths { @() }
        Mock Assert-WorkflowSourceAiRulesInstallable {}
        Mock Get-WorkflowDependencyPlan { [pscustomobject]@{} }
        Mock Assert-WorkflowDependencyPlan {}
        Mock Add-WorkflowDotEnvPolicySnapshotPaths {}
        Mock Invoke-WorkflowDevelopmentBranchRollout { throw 'Adjacent worktree must not be updated' }
        Mock Assert-WorkflowDevelopmentBranchRolloutComplete { throw 'No branch acceptance is implied' }
    }
    It 'adopts the real legacy copy, runs post-copy/owner commit and repeats without a new commit' {
        Test-Path -LiteralPath (Join-Path $root '.agent-1c/snapshots/workflow-update') | Should -BeFalse
        $fixture.removedBackup | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath $fixture.removedBackup | Should -BeFalse
        { Assert-WorkflowTrackedGitClean } | Should -Throw '*not clean*'
        $review=Start-WorkflowLegacyCopyRecovery -Review
        $decision=Join-Path $root '.agent-1c/snapshots/legacy-decision.json'
        Write-Utf8TextAtomic -Path $decision -Value (@{reportPath=$review.reportPath;reportSha256=$review.reportSha256;decision='adopt-observed-legacy-copy'} | ConvertTo-Json)
        $WorkflowUpdateReconciliationFile=$decision
        Start-WorkflowLegacyCopyRecovery | Should -Be 'pending'
        $pending=Get-WorkflowUpdatePendingSnapshot
        $pending.receipt.beforePathState.'AGENT-INSTALL.md' | Should -BeExactly (Get-WorkflowUpdatePathState -RelativePath 'AGENT-INSTALL.md')
        $pending.receipt.legacyCopyRecovery.beforeBoundary | Should -Match 'historical pre-copy bytes unavailable'
        Test-Path -LiteralPath (Join-Path $pending.snapshot.root 'observed-index') | Should -BeTrue
        Mock Invoke-WorkflowPackageFilePostCopy {
            [IO.File]::WriteAllText((Join-Path $script:ProjectRoot 'AGENT-INSTALL.md'),'post-copy completed',[Text.UTF8Encoding]::new($false))
            [pscustomobject]@{aiRulesPathsBefore=@();clientSurfacePathsBefore=@()}
        }
        Mock Enable-WorkflowExecutionGuardForCurrentRoot {}
        Mock Set-ItlOnDemandMcpSemanticReloadRequiredAction {}
        Mock Write-WorkflowUpdateFollowUp {}
        Mock Invoke-Agent1cFreshProcess {
            $savedPhase=$LifecyclePhase; $savedContinuation=$OperationContinuation
            try { $LifecyclePhase='post-copy';$OperationContinuation=$true; Update-WorkflowPackage *> $null }
            finally { $LifecyclePhase=$savedPhase;$OperationContinuation=$savedContinuation }
            [pscustomobject]@{exitCode=0}
        }
        $WorkflowUpdateRecovery='legacy-copy'
        $reexec=@(Get-Agent1cReexecArguments)
        $reexec | Should -Contain '-WorkflowUpdateRecovery'
        $reexec[[Array]::IndexOf($reexec,'-WorkflowUpdateRecovery')+1] | Should -Be 'legacy-copy'
        $previousSource=$env:ITL_WORKFLOW_SOURCE_PATH
        try {
            $env:ITL_WORKFLOW_SOURCE_PATH=$fixture.executor.root
            Update-WorkflowPackage
        } finally { $env:ITL_WORKFLOW_SOURCE_PATH=$previousSource }
        Get-WorkflowUpdatePendingSnapshot | Should -BeNullOrEmpty
        $head=Get-CurrentCommit
        Assert-WorkflowTrackedGitClean
        Start-WorkflowLegacyCopyRecovery | Should -Be 'completed'
        Get-CurrentCommit | Should -BeExactly $head
        Read-Utf8Text -Path $fixture.archive | Should -BeExactly 'retained retirement evidence'
        Get-WorkflowUpdatePathState -RelativePath '.dev.env' | Should -BeExactly $pending.receipt.beforePathState.'.dev.env'
        Read-Utf8Text -Path (Join-Path $root '.dev.env') | Should -BeExactly 'CUSTOM=Сохранить настройки'
        Read-Utf8Text -Path (Join-Path $root 'src/cf/Продукт.bsl') | Should -BeExactly 'unchanged product'
        Read-Utf8Text -Path (Join-Path $root 'templates/new-managed.txt') | Should -BeExactly 'new package file'
        Read-Utf8Text -Path (Join-Path $root 'templates/custom.secret') | Should -BeExactly 'current ignored custom bytes'
        Read-Utf8Text -Path (Join-Path $root 'handoffs/keep.md') | Should -BeExactly 'unrelated untracked evidence'
        Should -Invoke Invoke-WorkflowPackageFilePostCopy -Times 1 -Exactly
        Should -Invoke Invoke-WorkflowDevelopmentBranchRollout -Times 0 -Exactly
        $id=(Split-Path -Leaf $pending.snapshot.root).Substring('itl-workflow-update-rollback-'.Length)
        Restore-CompletedWorkflowUpdate -SnapshotId $id
        Read-Utf8Text -Path (Join-Path $root 'AGENT-INSTALL.md') | Should -BeExactly 'candidate bytes'
        Assert-WorkflowTrackedGitClean
    }
    It 'refuses <Kind> without a receipt or managed writes' -ForEach @(
        @{Kind='changed-package';ExpectedCategory='LEGACY_PAYLOAD_CHANGED'},@{Kind='staged-product';ExpectedCategory='LEGACY_INDEX_CHANGED'},@{Kind='foreign-product';ExpectedCategory='LEGACY_FOREIGN_CHANGE'},@{Kind='unknown-untracked';ExpectedCategory='LEGACY_UNTRACKED_OWNER'},@{Kind='changed-lock';ExpectedCategory='LEGACY_LOCK_CHANGED'},@{Kind='dirty-source';ExpectedCategory='SOURCE_CHANGED'},@{Kind='wrong-source';ExpectedCategory='SOURCE_CHANGED'},@{Kind='missing-source';ExpectedCategory='SOURCE_MISSING'},@{Kind='dirty-executor';ExpectedCategory='SOURCE_CHANGED'}
    ) {
        switch($Kind) {
            'changed-package' { [IO.File]::WriteAllText((Join-Path $root 'AGENT-INSTALL.md'),'foreign edit') }
            'staged-product' { [IO.File]::WriteAllText((Join-Path $root 'src/cf/Продукт.bsl'),'staged product'); & git -C $root add --all -- src }
            'foreign-product' { [IO.File]::WriteAllText((Join-Path $root 'src/cf/Продукт.bsl'),'foreign product') }
            'unknown-untracked' { [IO.File]::WriteAllText((Join-Path $root 'templates/unknown.txt'),'unknown existing bytes') }
            'changed-lock' { $lock=Read-DependencyLockManifest;$lock.dependencies.custom.value='foreign';Write-DependencyLockManifest $lock }
            'dirty-source' { [IO.File]::WriteAllText((Join-Path $fixture.source.root 'AGENT-INSTALL.md'),'dirty candidate') }
            'wrong-source' { & git -C $fixture.source.root checkout -q --detach HEAD~1 }
            'missing-source' { $WorkflowUpdateLegacySourceRoot=$root+' missing source' }
            'dirty-executor' { [IO.File]::WriteAllText((Join-Path $fixture.executor.root 'AGENT-INSTALL.md'),'dirty executor') }
        }
        $head=Get-CurrentCommit
        $indexBefore=@(Get-GitPathList -Arguments @('ls-files','--stage','-z')) -join "`0"
        $preserved=@{}
        foreach($relative in @('AGENT-INSTALL.md','src/cf/Продукт.bsl','.agent-1c/dependency-lock.json','templates')) {
            $preserved[$relative]=Get-WorkflowUpdatePathState -RelativePath $relative
        }
        { Start-WorkflowLegacyCopyRecovery -Review } | Should -Throw "*WORKFLOW_UPDATE_$ExpectedCategory*"
        Get-CurrentCommit | Should -BeExactly $head
        (@(Get-GitPathList -Arguments @('ls-files','--stage','-z')) -join "`0") | Should -BeExactly $indexBefore
        foreach($relative in $preserved.Keys) { Get-WorkflowUpdatePathState -RelativePath $relative | Should -BeExactly $preserved[$relative] }
        Get-WorkflowUpdatePendingSnapshot | Should -BeNullOrEmpty
    }
    It 'rejects late <Kind> drift against the reviewed state' -ForEach @(@{Kind='head'},@{Kind='index'},@{Kind='settings'},@{Kind='report'},@{Kind='source'},@{Kind='package'}) {
        $review=Start-WorkflowLegacyCopyRecovery -Review
        $decision=Join-Path $root '.agent-1c/snapshots/legacy-decision.json'
        Write-Utf8TextAtomic -Path $decision -Value (@{reportPath=$review.reportPath;reportSha256=$review.reportSha256;decision='adopt-observed-legacy-copy'} | ConvertTo-Json)
        $WorkflowUpdateReconciliationFile=$decision
        switch($Kind) {
            'head' { & git -C $root commit --allow-empty -qm 'late head' }
            'index' { [IO.File]::WriteAllText((Join-Path $root 'src/cf/Продукт.bsl'),'late staged'); & git -C $root add --all -- src }
            'settings' { [IO.File]::WriteAllText((Join-Path $root '.dev.env'),'late custom settings') }
            'report' { [IO.File]::AppendAllText($review.reportPath,' ') }
            'source' { [IO.File]::WriteAllText((Join-Path $fixture.source.root 'AGENT-INSTALL.md'),'late source edit') }
            'package' { [IO.File]::WriteAllText((Join-Path $root 'AGENT-INSTALL.md'),'late package edit') }
        }
        { Start-WorkflowLegacyCopyRecovery } | Should -Throw '*WORKFLOW_UPDATE_*'
        Get-WorkflowUpdatePendingSnapshot | Should -BeNullOrEmpty
    }
    It 'retains backup and refuses unconfirmed post-copy even with child exit <ChildExit>' -ForEach @(@{ChildExit=7},@{ChildExit=0}) {
        $review=Start-WorkflowLegacyCopyRecovery -Review
        $WorkflowUpdateReconciliationFile=Join-Path $root '.agent-1c/snapshots/legacy-decision.json'
        Write-Utf8TextAtomic -Path $WorkflowUpdateReconciliationFile -Value (@{reportPath=$review.reportPath;reportSha256=$review.reportSha256;decision='adopt-observed-legacy-copy'} | ConvertTo-Json)
        Start-WorkflowLegacyCopyRecovery | Should -Be 'pending'
        $pending=Get-WorkflowUpdatePendingSnapshot
        # The same captured bytes at the armed boundary must survive a process
        # interruption before copy-complete was acknowledged. No recopy is due.
        Save-WorkflowUpdateSnapshotReceipt -Snapshot $pending.snapshot -Source $fixture.source -Phase prepared
        $WorkflowUpdateRecovery='legacy-copy'
        $script:legacyChildExit=$ChildExit
        Mock Invoke-Agent1cFreshProcess { [pscustomobject]@{exitCode=$script:legacyChildExit} }
        $previousSource=$env:ITL_WORKFLOW_SOURCE_PATH
        try {
            $env:ITL_WORKFLOW_SOURCE_PATH=$fixture.executor.root
            { Update-WorkflowPackage } | Should -Throw '*WORKFLOW_UPDATE_POST_COPY_INCOMPLETE*'
        } finally { $env:ITL_WORKFLOW_SOURCE_PATH=$previousSource }
        (Get-WorkflowUpdatePendingSnapshot).receipt.phase | Should -Be 'post-copy-failed'
        Should -Invoke Invoke-Agent1cFreshProcess -Times 1 -Exactly
        Test-Path -LiteralPath $pending.snapshot.root | Should -BeTrue
        Start-WorkflowLegacyCopyRecovery | Should -Be 'pending'
        (Get-WorkflowUpdatePendingSnapshot).snapshot.root | Should -BeExactly $pending.snapshot.root
    }
}

Describe 'Ordinary update started by the published r33 helper' {
    BeforeAll {
        # The published master before the transactional updater. Its own
        # updater, copy and lock writers run below; only the process boundary
        # and dependency provisioning are stubbed.
        $script:r33Commit = '69c0863bfe3bd837543267f122e81a28dcfa5488'
        . $helperPath -ProjectRoot (Join-Path $TestDrive 'r33 definitions') -Action help *> $null
        $script:r33Definitions = @(
            Get-LegacyHelperDefinitions -Commit $script:r33Commit -Relative '.agents/skills/1c-workflow/scripts/lib/agent-1c.lifecycle.ps1' -Names @('Update-WorkflowPackage','Copy-WorkflowManagedDirectory','Copy-WorkflowManagedFile')
            Get-LegacyHelperDefinitions -Commit $script:r33Commit -Relative '.agents/skills/1c-workflow/scripts/lib/agent-1c.core.ps1' -Names @('Ensure-DependencyLockManifest','Write-DependencyLockManifest')
        )
        function Invoke-R33ParentUpdate {
            param([object]$Source, [string]$LegacySourceRoot)
            $currentDefinitions = @{}
            foreach ($name in @('Update-WorkflowPackage','Copy-WorkflowManagedDirectory','Copy-WorkflowManagedFile','Ensure-DependencyLockManifest','Write-DependencyLockManifest')) {
                $currentDefinitions[$name] = (Get-Item "Function:$name").ScriptBlock
            }
            & {
                foreach ($definition in $script:r33Definitions) { . $definition }
                function Get-WorkflowPackageLegacyTempRoot { $LegacySourceRoot }
                function Invoke-Agent1cFreshProcess {
                    param([string]$ScriptPath, [string[]]$AdditionalArguments, [switch]$ReturnExitStatus, [switch]$ResumeParentAfterSuccess)
                    $script:r33Children.Add([pscustomobject]@{scriptPath=$ScriptPath;returnStatus=[bool]$ReturnExitStatus}) | Out-Null
                    & {
                        # The fresh process loads the copied (current) helper.
                        foreach ($name in $currentDefinitions.Keys) { Set-Item -Path "Function:$name" -Value $currentDefinitions[$name] }
                        $LifecyclePhase = 'post-copy'; $OperationContinuation = $true
                        Update-WorkflowPackage
                    }
                    if ($ReturnExitStatus) { return [pscustomobject]@{exitCode=0} }
                    # The r33 parent exits with its child's code.
                    throw 'R33_PARENT_EXIT:0'
                }
                Update-WorkflowPackage
            }
        }
    }
    BeforeEach {
        $root=Join-Path $TestDrive ('r33 проект с пробелом '+[guid]::NewGuid().ToString('N'))
        . $helperPath -ProjectRoot $root -Action help *> $null
        $script:r33Fixture=New-LegacyRawCopyFixture -Root $root -Candidate ($root+' кэш старого помощника') -Executor ($root+' executor') -LegacyCommit $script:r33Commit -PrepareOnly
        $script:r33Children=[System.Collections.Generic.List[object]]::new()
        $LifecyclePhase=''
        $WorkflowUpdateRecovery=''
        $SkipAiRules=$true
        Mock Resolve-WorkflowPackageSource { $script:r33Fixture.source }
        Mock Get-WorkflowUpdateExpectedClientWritePaths { @() }
        Mock Assert-WorkflowSourceAiRulesInstallable {}
        Mock Get-WorkflowDependencyPlan { [pscustomobject]@{} }
        Mock Assert-WorkflowDependencyPlan {}
        Mock Add-WorkflowDotEnvPolicySnapshotPaths {}
        Mock Invoke-WorkflowPackageFilePostCopy {
            [IO.File]::WriteAllText((Join-Path $script:ProjectRoot 'AGENT-INSTALL.md'),'post-copy completed',[Text.UTF8Encoding]::new($false))
            [pscustomobject]@{aiRulesPathsBefore=@();clientSurfacePathsBefore=@()}
        }
        Mock Enable-WorkflowExecutionGuardForCurrentRoot {}
        Mock Set-ItlOnDemandMcpSemanticReloadRequiredAction {}
        Mock Write-WorkflowUpdateFollowUp {}
        Mock Invoke-WorkflowDevelopmentBranchRollout { [pscustomobject]@{roots=@()} }
        Mock Assert-WorkflowDevelopmentBranchRolloutComplete {}
    }
    It 'adopts the exact copy, commits master and rolls out to development worktrees in one command' {
        $source=$script:r33Fixture.source
        $headBefore=Get-CurrentCommit
        { Invoke-R33ParentUpdate -Source $source -LegacySourceRoot $source.root } | Should -Throw 'R33_PARENT_EXIT:0'
        Get-WorkflowUpdatePendingSnapshot | Should -BeNullOrEmpty
        Get-CurrentCommit | Should -Not -Be $headBefore
        Assert-WorkflowTrackedGitClean
        # Post-copy runs once more from the parent's exact clean source.
        $script:r33Children.Count | Should -Be 2
        $script:r33Children[1].returnStatus | Should -BeTrue
        $script:r33Children[1].scriptPath | Should -BeExactly (Join-Path $source.root '.agents/skills/1c-workflow/scripts/agent-1c.ps1')
        Should -Invoke Invoke-WorkflowPackageFilePostCopy -Times 1 -Exactly
        Should -Invoke Invoke-WorkflowDevelopmentBranchRollout -Times 1 -Exactly -ParameterFilter { [string]$Source.commit -ceq [string]$script:r33Fixture.source.commit }
        Should -Invoke Assert-WorkflowDevelopmentBranchRolloutComplete -ParameterFilter { $SourceCommit -ceq [string]$script:r33Fixture.source.commit }
        Read-Utf8Text -Path (Join-Path $root 'templates/new-managed.txt') | Should -BeExactly 'new package file'
        Read-Utf8Text -Path (Join-Path $root '.dev.env') | Should -BeExactly 'CUSTOM=Сохранить настройки'
        Read-Utf8Text -Path (Join-Path $root 'src/cf/Продукт.bsl') | Should -BeExactly 'unchanged product'
        Read-Utf8Text -Path $script:r33Fixture.archive | Should -BeExactly 'retained retirement evidence'
        (Read-DependencyLockManifest).dependencies.custom.value | Should -Be 'keep'
        $completed=@(Get-ChildItem -LiteralPath (Join-Path $root '.agent-1c/snapshots/workflow-update') -Directory -Filter 'itl-workflow-update-completed-*')
        $completed | Should -HaveCount 1
        $id=$completed[0].Name.Substring('itl-workflow-update-completed-'.Length)
        $receipt=(Get-WorkflowUpdateCompletedSnapshot -SnapshotId $id).receipt
        $receipt.legacyCopyRecovery.scope | Should -BeExactly 'legacy-parent-handoff'
        $receipt.legacyCopyRecovery.observedHead | Should -BeExactly $headBefore
        # Restore returns the observed copy, never the pre-incident commit.
        $script:Agent1cScriptRoot=Join-Path $source.root '.agents/skills/1c-workflow/scripts'
        Restore-CompletedWorkflowUpdate -SnapshotId $id
        Read-Utf8Text -Path (Join-Path $root 'AGENT-INSTALL.md') | Should -BeExactly 'candidate bytes'
        Assert-WorkflowTrackedGitClean
    }
    It 'keeps the reviewed recovery when <Kind>' -ForEach @(
        @{Kind='the parent source moved';ExpectedCategory='SOURCE_MISSING'},
        @{Kind='the parent source is dirty';ExpectedCategory='SOURCE_CHANGED'}
    ) {
        $source=$script:r33Fixture.source
        $legacyRoot=$source.root
        if ($Kind -eq 'the parent source moved') { $legacyRoot=$root+' missing source' }
        if ($Kind -eq 'the parent source is dirty') { [IO.File]::WriteAllText((Join-Path $source.root 'templates/new-managed.txt'),'dirty parent source',[Text.UTF8Encoding]::new($false)) }
        $headBefore=Get-CurrentCommit
        { Invoke-R33ParentUpdate -Source $source -LegacySourceRoot $legacyRoot } |
            Should -Throw "*WORKFLOW_UPDATE_POST_COPY_RECEIPT_MISSING*legacy-status*Automatic adoption was refused*WORKFLOW_UPDATE_$ExpectedCategory*"
        Get-CurrentCommit | Should -BeExactly $headBefore
        Get-WorkflowUpdatePendingSnapshot | Should -BeNullOrEmpty
        Test-Path -LiteralPath (Join-Path $root '.agent-1c/snapshots/workflow-update') | Should -BeFalse
        Should -Invoke Invoke-WorkflowDevelopmentBranchRollout -Times 0 -Exactly
    }
}
