BeforeAll { . (Join-Path $PSScriptRoot 'WorkflowUpdateRollback.TestSupport.ps1') }

Describe 'Legacy dependency handoff uses the existing update snapshot' -Tag G3DowngradeDependencyMode {
    It 'does not replay bundle writers after legacy <phase>' -ForEach @(@{phase='master-commit-ready'},@{phase='master-committed'}) {
        $fixture=New-WorkflowRollbackFixture -Root (Join-Path $TestDrive ('Legacy committed '+$phase))
        . $helperPath -ProjectRoot $fixture.root -Action help *> $null
        $template=ConvertTo-Agent1cHashtable (New-DefaultDependencyLockManifest)
        New-Item -ItemType Directory -Force -Path (Join-Path $fixture.root 'templates')|Out-Null
        $template.schemaVersion=1;$template.mode='fresh'
        Write-Utf8Text (Join-Path $fixture.root 'templates/dependency-lock.json') ($template|ConvertTo-Json -Depth 100)
        $template.mode='locked';Write-DependencyLockManifest $template
        $plan=Get-WorkflowDependencyPlan -SourceRoot $fixture.root
        $source=[pscustomobject]@{root=$repoRoot;commit=('b'*40);source='path';ref='master';repo='fixture'}
        $snapshot=New-WorkflowUpdateRollbackSnapshot -RelativePaths @('AGENT-INSTALL.md','templates','.agent-1c/project.json','.agent-1c/dependency-lock.json','.dev.env') -SnapshotParent (Join-Path $fixture.root '.agent-1c/snapshots/workflow-update')
        Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase prepared -Details @{dependencyPlan=$plan}
        Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase $phase
        Mock Invoke-AiRulesBaselineMigration {throw 'A commit checkpoint must not replay rules migration'}
        Mock Sync-WorkflowManagedDependencyLockEntries {throw 'A commit checkpoint must not replay dependency sync'}
        Mock Invoke-Agent1cFreshProcess {
            (Get-WorkflowUpdatePendingSnapshot).receipt.phase|Should -BeExactly $phase
            Assert-WorkflowUpdateSnapshotCurrentState -Pending (Get-WorkflowUpdatePendingSnapshot)
            [pscustomobject]@{exitCode=1}
        }
        {Complete-WorkflowUpdatePostCopyFromSnapshot -Snapshot $snapshot -Source $source}|Should -Throw '*master commit checkpoint is preserved*'
        Should -Invoke Invoke-AiRulesBaselineMigration -Times 0 -Exactly
        Should -Invoke Sync-WorkflowManagedDependencyLockEntries -Times 0 -Exactly
        Should -Invoke Invoke-Agent1cFreshProcess -Times 1 -Exactly
        (Get-WorkflowUpdatePendingSnapshot).receipt.phase|Should -BeExactly $phase
        Assert-WorkflowUpdateSnapshotCurrentState -Pending (Get-WorkflowUpdatePendingSnapshot)
    }
    It 'retains the rules owner refusal and honors SkipAiRules=<skip>' -ForEach @(@{skip=$false},@{skip=$true}) {
        $fixture=New-WorkflowRollbackFixture -Root (Join-Path $TestDrive ('Legacy rules boundary '+$skip))
        . $helperPath -ProjectRoot $fixture.root -Action help *> $null
        $template=ConvertTo-Agent1cHashtable (New-DefaultDependencyLockManifest)
        New-Item -ItemType Directory -Force -Path (Join-Path $fixture.root 'templates')|Out-Null
        $template.schemaVersion=1;$template.mode='fresh'
        Write-Utf8Text (Join-Path $fixture.root 'templates/dependency-lock.json') ($template|ConvertTo-Json -Depth 100)
        Write-DependencyLockManifest $template
        $source=[pscustomobject]@{root=$repoRoot;commit=('b'*40);source='path';ref='master';repo='fixture'}
        $plan=Get-WorkflowDependencyPlan -SourceRoot $fixture.root
        $snapshot=New-WorkflowUpdateRollbackSnapshot -RelativePaths @('AGENT-INSTALL.md','templates','.agent-1c/project.json','.agent-1c/dependency-lock.json','.dev.env') -SnapshotParent (Join-Path $fixture.root '.agent-1c/snapshots/workflow-update')
        Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase prepared -Details @{dependencyPlan=$plan}
        Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase post-copy-failed
        Mock Add-WorkflowDotEnvPolicySnapshotPaths {}
        Mock Invoke-AiRulesBaselineMigration { [pscustomobject]@{migrated=$false;suppressRegularUpdate=$true;status='not-newer';reason='fixture refusal'} }
        Mock Invoke-Agent1cFreshProcess { throw 'fixture child reached' }
        $SkipAiRules=$skip
        if($skip){
            {Complete-WorkflowUpdatePostCopyFromSnapshot -Snapshot $snapshot -Source $source}|Should -Throw '*fixture child reached*'
            Should -Invoke Invoke-AiRulesBaselineMigration -Times 0 -Exactly
            Should -Invoke Invoke-Agent1cFreshProcess -Times 1 -Exactly
        }else{
            {Complete-WorkflowUpdatePostCopyFromSnapshot -Snapshot $snapshot -Source $source}|Should -Throw '*ai_rules_1c migration is blocked (not-newer)*'
            Should -Invoke Invoke-AiRulesBaselineMigration -Times 1 -Exactly
            Should -Invoke Invoke-Agent1cFreshProcess -Times 0 -Exactly
        }
        $pending=Get-WorkflowUpdatePendingSnapshot
        $pending.receipt.phase|Should -BeExactly 'post-copy-failed'
        Assert-WorkflowUpdateSnapshotCurrentState -Pending $pending
    }
    It 'replaces an explicit modern mode exactly once in the child command without changing the parent arguments' {
        $fixture=New-WorkflowRollbackFixture -Root (Join-Path $TestDrive 'Legacy child arguments')
        . $helperPath -ProjectRoot $fixture.root -Action help *> $null
        $script:Agent1cReexecArguments=@('-Action','help','-DependencyMode','workflow','-LifecyclePhase','old-phase')
        Mock Invoke-ItlNativeProcessCapture {
            param($Arguments)
            @($Arguments|Where-Object {$_ -ieq '-DependencyMode'}).Count|Should -Be 1
            @($Arguments|Where-Object {$_ -ieq '-LifecyclePhase'}).Count|Should -Be 1
            ($Arguments -join '|')|Should -Match '-LifecyclePhase\|post-copy\|-DependencyMode\|locked$'
            $Arguments|Should -Not -Contain workflow
            $Arguments|Should -Not -Contain old-phase
            [pscustomobject]@{exitCode=0;stdout='';stderr=''}
        }
        $result=Invoke-Agent1cFreshProcess -AdditionalArguments @('-LifecyclePhase','post-copy','-DependencyMode','locked') -ReturnExitStatus
        $result.exitCode|Should -Be 0
        $script:Agent1cReexecArguments|Should -Contain workflow
        Should -Invoke Invoke-ItlNativeProcessCapture -Times 1 -Exactly
    }
    It 'hands readable settings to the fresh child and restores exact prior bytes after its failure' {
        $fixture=New-WorkflowRollbackFixture -Root (Join-Path $TestDrive 'Downgrade протокол с пробелом')
        . $helperPath -ProjectRoot $fixture.root -Action help *> $null
        $template=ConvertTo-Agent1cHashtable (New-DefaultDependencyLockManifest)
        New-Item -ItemType Directory -Force -Path (Join-Path $fixture.root 'templates')|Out-Null
        $template.schemaVersion=1;$template.mode='fresh'
        Write-Utf8Text (Join-Path $fixture.root 'templates/dependency-lock.json') ($template|ConvertTo-Json -Depth 100)
        $template.schemaVersion=2;$template.mode='workflow'
        Write-DependencyLockManifest $template
        $config=Read-Utf8Text $script:ConfigPath|ConvertFrom-Json
        $config|Add-Member -NotePropertyName dependencyMode -NotePropertyValue workflow -Force
        Write-Utf8Text $script:ConfigPath ($config|ConvertTo-Json -Depth 100)
        Set-DotEnvValues -Values @{DEPENDENCY_MODE='workflow'}
        Write-Utf8Text (Join-Path $fixture.root '.ai-rules.json') 'original rules manifest'
        $original=@{}
        foreach($rel in @('.agent-1c/project.json','.agent-1c/dependency-lock.json','.dev.env','.ai-rules.json')){
            $original[$rel]=[IO.File]::ReadAllBytes((Join-Path $fixture.root $rel))
        }
        $source=[pscustomobject]@{root=$repoRoot;commit=('b'*40);source='path';ref='master';repo='fixture'}
        $plan=Get-WorkflowDependencyPlan -SourceRoot $fixture.root
        $snapshot=New-WorkflowUpdateRollbackSnapshot -RelativePaths @('AGENT-INSTALL.md','templates','.agent-1c/project.json','.agent-1c/dependency-lock.json','.dev.env','.ai-rules.json') -SnapshotParent (Join-Path $fixture.root '.agent-1c/snapshots/workflow-update')
        Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase prepared -Details @{dependencyPlan=$plan}
        Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase post-copy-failed
        Mock Add-WorkflowDotEnvPolicySnapshotPaths {}
        Mock Invoke-AiRulesBaselineMigration {
            (Get-WorkflowDependencyPlan).workflowTransition|Should -BeTrue
            Write-Utf8Text (Join-Path $script:ProjectRoot '.ai-rules.json') 'selected legacy rules manifest'
            [pscustomobject]@{migrated=$true;suppressRegularUpdate=$true;status='migrated'}
        }
        Mock Invoke-Agent1cFreshProcess {
            param($AdditionalArguments)
            [Environment]::GetEnvironmentVariable('DEPENDENCY_MODE', 'Process')|Should -BeExactly 'locked'
            ($AdditionalArguments -join '|')|Should -BeExactly '-LifecyclePhase|post-copy|-DependencyMode|locked'
            (Read-DependencyLockManifest).mode|Should -BeExactly 'locked'
            (Read-Utf8Text $script:ConfigPath|ConvertFrom-Json).dependencyMode|Should -BeExactly 'locked'
            (Read-Utf8Text (Join-Path $script:ProjectRoot '.dev.env'))|Should -Match '(?m)^DEPENDENCY_MODE=locked\r?$'
            $pending=Get-WorkflowUpdatePendingSnapshot
            $pending.receipt.dependencyPlan.manifest.mode|Should -BeExactly 'workflow'
            Read-Utf8Text (Join-Path $script:ProjectRoot '.ai-rules.json')|Should -BeExactly 'selected legacy rules manifest'
            Assert-WorkflowUpdateSnapshotCurrentState -Pending $pending
            [pscustomobject]@{exitCode=1}
        }
        $previousMode=$env:DEPENDENCY_MODE
        try {
            $env:DEPENDENCY_MODE='workflow'
            {Complete-WorkflowUpdatePostCopyFromSnapshot -Snapshot $snapshot -Source $source}|Should -Throw '*Fresh workflow post-copy process failed*'
            $env:DEPENDENCY_MODE|Should -BeExactly 'workflow'
        } finally { $env:DEPENDENCY_MODE=$previousMode }
        Should -Invoke Invoke-Agent1cFreshProcess -Times 1 -Exactly
        Should -Invoke Invoke-AiRulesBaselineMigration -Times 1 -Exactly
        $pending=Get-WorkflowUpdatePendingSnapshot
        $pending.receipt.phase|Should -BeExactly 'post-copy-failed'
        Assert-WorkflowUpdateSnapshotCurrentState -Pending $pending
        Restore-WorkflowUpdateRollbackSnapshot -Snapshot $pending.snapshot
        foreach($rel in @($original.Keys)){
            [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $fixture.root $rel)))|Should -BeExactly ([Convert]::ToBase64String($original[$rel]))
        }
    }
}

Describe 'Workflow dependency transition snapshot' -Tag WorkflowDependencyTransaction {
    It 'captures one selection, ignores edited input after arm, and restores a retired hotfix at <phase>' -ForEach @(@{phase='post-copy-failed'},@{phase='post-copy-complete'}) {
        $root=Join-Path $TestDrive ('Dependency rollback project '+$phase)
        New-Item -ItemType Directory -Force -Path (Join-Path $root '.agent-1c') | Out-Null
        Copy-Item -LiteralPath (Join-Path $repoRoot 'templates') -Destination (Join-Path $root 'templates') -Recurse
        [IO.File]::WriteAllText((Join-Path $root '.agent-1c/project.json'),'{"dependencyMode":"locked","aiRules":{"tools":["codex"]}}',[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $root '.dev.env'),"DEPENDENCY_MODE=locked`n",[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $root '.gitignore'),".dev.env`n.agent-1c/snapshots/`nselection.json`n",[Text.UTF8Encoding]::new($false))
        & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            $baseline=New-DefaultDependencyLockManifest
            $pin=ConvertTo-Agent1cHashtable $baseline.dependencies.yaxunit
            $pin.version='26.1'; $pin.releaseTag='26.1'; $pin.sha256=('b'*64)
            $fix=@{reason='incident';dependencies=@{yaxunit=$pin}}
            $installed=New-WorkflowDependencyPlan -Template $baseline -Manifest $baseline -Selection @{hotfixes=@{incident=$fix}}
            Write-DependencyLockManifest $installed.manifest
            $before=[IO.File]::ReadAllBytes((Get-DependencyLockPath))
            & git -C $root init -q -b master
            & git -C $root config user.name 'Dependency Test'
            & git -C $root config user.email 'dependency@example.invalid'
            & git -C $root add --all
            & git -C $root commit -qm baseline
            $LASTEXITCODE | Should -Be 0
            $candidate=Join-Path $TestDrive 'Dependency target package'
            $compatRelative='.agents/skills/1c-workflow/assets/ondemand-mcp'
            New-Item -ItemType Directory -Force -Path (Join-Path $candidate 'templates'),(Join-Path $candidate $compatRelative) | Out-Null
            $target=ConvertTo-Agent1cHashtable $baseline
            $target.dependencies.yaxunit=$pin
            Write-Utf8Text -Path (Join-Path $candidate 'templates/dependency-lock.json') -Value ($target|ConvertTo-Json -Depth 100)
            Copy-Item (Join-Path $repoRoot "$compatRelative/compatibility.json") (Join-Path $candidate "$compatRelative/compatibility.json")
            $DependencySelectionFile=Join-Path $root 'selection.json'
            Write-Utf8Text -Path $DependencySelectionFile -Value (@{schemaVersion=1;worktrees=@(@{worktreePath=$root})}|ConvertTo-Json -Depth 10)
            $plan=Get-WorkflowDependencyPlan -SourceRoot $candidate
            @($plan.blocked).Count | Should -Be 0
            $plan.manifest.hotfixes.Count | Should -Be 0
            $source=[pscustomobject]@{root=$candidate;commit=('b'*40);ref='master';repo='fixture';source='path'}
            $snapshot=New-WorkflowUpdateRollbackSnapshot -RelativePaths @('templates','.agent-1c/dependency-lock.json','.agent-1c/project.json','.dev.env') -SnapshotParent (Join-Path $root '.agent-1c/snapshots/workflow-update')
            Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase prepared -Details @{dependencyPlan=$plan}
            $lateFix=ConvertTo-Agent1cHashtable $fix
            $lateFix.dependencies.yaxunit.version='27.1'
            Write-Utf8Text -Path $DependencySelectionFile -Value (@{schemaVersion=1;worktrees=@(@{worktreePath=$root;hotfixes=@{other=$lateFix}})}|ConvertTo-Json -Depth 30)
            Copy-Item (Join-Path $candidate 'templates/dependency-lock.json') (Join-Path $root 'templates/dependency-lock.json') -Force
            Update-WorkflowPackageLockEntry -Source $source | Out-Null
            Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase copy-complete
            (ConvertTo-Agent1cHashtable (Get-WorkflowDependencyPlan).manifest.hotfixes).Count | Should -Be 0
            Sync-WorkflowManagedDependencyLockEntries | Out-Null
            (Read-DependencyLockManifest).dependencies.workflowPackage.commit | Should -Be ('b'*40)
            (Read-DependencyLockManifest).dependencies.yaxunit.version | Should -Be '26.1'
            (ConvertTo-Agent1cHashtable (Read-DependencyLockManifest).hotfixes).Keys | Should -Not -Contain other
            Write-Utf8Text -Path (Join-Path $root 'unrelated.txt') -Value 'late user content'
            if ($phase -eq 'post-copy-complete') {
                & git -C $root add -- templates .agent-1c/dependency-lock.json .agent-1c/project.json
                & git -C $root commit -qm 'install new dependency selection'
                $LASTEXITCODE | Should -Be 0
                Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase post-copy-complete
                $snapshotId=(Split-Path -Leaf $snapshot.root).Substring('itl-workflow-update-rollback-'.Length)
                Retain-WorkflowUpdateRollbackSnapshot -Snapshot $snapshot | Out-Null
                Set-RollbackSourceFixture
                Restore-CompletedWorkflowUpdate -SnapshotId $snapshotId
            } else {
                Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase post-copy-failed
                Restore-WorkflowUpdateRollbackSnapshot -Snapshot $snapshot
            }
            [Convert]::ToBase64String([IO.File]::ReadAllBytes((Get-DependencyLockPath))) | Should -BeExactly ([Convert]::ToBase64String($before))
            (Read-DependencyLockManifest).hotfixes.incident.reason | Should -Be incident
            Read-Utf8Text -Path (Join-Path $root '.dev.env') | Should -BeExactly "DEPENDENCY_MODE=locked`n"
            Read-Utf8Text -Path (Join-Path $root 'unrelated.txt') | Should -BeExactly 'late user content'
        }
    }
}

Describe 'Dependency preflight drift' -Tag WorkflowDependencyTransaction {
    It 'preserves a changed input with initiallyExists=<exists> and prepares the original operation after replanning' -ForEach @(@{exists=$false},@{exists=$true}) {
        $root=Join-Path $TestDrive ('Preflight drift '+$exists)
        New-Item -ItemType Directory -Force -Path (Join-Path $root '.agent-1c') | Out-Null
        Copy-Item -LiteralPath (Join-Path $repoRoot 'templates') -Destination (Join-Path $root 'templates') -Recurse
        [IO.File]::WriteAllText((Join-Path $root '.gitignore'),".agent-1c/snapshots/`n",[Text.UTF8Encoding]::new($false))
        & git -C $root init -q -b master
        & git -C $root config user.name 'Dependency Drift Test'
        & git -C $root config user.email 'dependency@example.invalid'
        & git -C $root add --all
        & git -C $root commit -qm baseline
        & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            if($exists){Ensure-DependencyLockManifest}
            $plan=Get-WorkflowDependencyPlan -SourceRoot $repoRoot
            $source=[pscustomobject]@{root=$repoRoot;commit=('b'*40);source='path'}
            $snapshot=New-WorkflowUpdateRollbackSnapshot -RelativePaths @('.agent-1c/dependency-lock.json') -SnapshotParent (Join-Path $root '.agent-1c/snapshots/workflow-update')
            if(-not $exists){Ensure-DependencyLockManifest}
            [IO.File]::AppendAllText((Get-DependencyLockPath)," `n",[Text.UTF8Encoding]::new($false))
            $edited=[IO.File]::ReadAllBytes((Get-DependencyLockPath))
            {Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase prepared -Details @{dependencyPlan=$plan}} | Should -Throw '*DEPENDENCY_PREFLIGHT_DRIFT*'
            Test-Path -LiteralPath (Join-Path $snapshot.root 'transaction.json') | Should -BeFalse
            [Convert]::ToBase64String([IO.File]::ReadAllBytes((Get-DependencyLockPath))) | Should -BeExactly ([Convert]::ToBase64String($edited))
            Remove-WorkflowUpdateRollbackSnapshot -Snapshot $snapshot
            $plan=Get-WorkflowDependencyPlan -SourceRoot $repoRoot
            $snapshot=New-WorkflowUpdateRollbackSnapshot -RelativePaths @('.agent-1c/dependency-lock.json') -SnapshotParent (Join-Path $root '.agent-1c/snapshots/workflow-update')
            {Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase prepared -Details @{dependencyPlan=$plan}} | Should -Not -Throw
            [Convert]::ToBase64String([IO.File]::ReadAllBytes((Get-DependencyLockPath))) | Should -BeExactly ([Convert]::ToBase64String($edited))
        }
    }
}
