BeforeAll { . (Join-Path $PSScriptRoot 'WorkflowUpdateRollback.TestSupport.ps1') }

Describe 'Branch workflow finalization preserves unrelated index entries' -Tag 'WorkflowFinalize' {
It 'retires tracked Python cache through the branch owner and restores raw backups without touching business stages' -Tag 'PackageContent' {
        $fixture=New-FinalizationFixture -Root (Join-Path $TestDrive 'Пакет Python и конфликт бизнеса') -BusinessConflict -PackageCache
        & {
            . $helperPath -ProjectRoot $fixture.root -Action help *> $null
            $relative='.agents/skills/itl-remote-runner'
            $cache=$relative+'/scripts/__pycache__/module.cpython-313.pyc'
            $businessBefore=@(Get-GitPathList -Arguments @('ls-files','--stage','-z','--','src/cf')) -join "`0"
            $merge=(Get-GitOutput @('rev-parse','--path-format=absolute','--git-path','MERGE_HEAD')).Trim()
            $mergeBefore=(Get-FileHash -LiteralPath $merge).Hash
            $source=Join-Path $TestDrive 'Новая копия Python с пробелом'
            New-Item -ItemType Directory -Force -Path (Join-Path $source ($relative+'/scripts/__pycache__')) | Out-Null
            [IO.File]::WriteAllText((Join-Path $source ($relative+'/scripts/module.py')), "# new source`r`n", [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllBytes((Join-Path $source $cache), [byte[]]@(0,128,44))
            $before=Get-WorkflowUpdatePathState -RelativePath $relative
            $snapshot=New-WorkflowUpdateRollbackSnapshot -RelativePaths @($relative)
            try {
                Ensure-GitIgnore
                Copy-WorkflowManagedDirectory -SourceRoot $source -RelativePath $relative
                (Test-Path -LiteralPath (Join-Path $fixture.root $cache)) | Should -BeFalse
                $plan=New-WorkflowBranchCommitPlan -ManagedPathSpecs @($relative,'.gitignore')
                @($plan.managedPaths) | Should -Contain $cache
                Apply-WorkflowBranchCommitPlan -Plan $plan | Out-Null
                @(Get-GitPathList -Arguments @('ls-tree','-r','--name-only','-z','HEAD','--',$cache)) | Should -HaveCount 0
                @(Get-GitPathList -Arguments @('ls-files','-z','--',$cache)) | Should -HaveCount 0
                (@(Get-GitPathList -Arguments @('ls-files','--stage','-z','--','src/cf')) -join "`0") | Should -BeExactly $businessBefore
                (Get-FileHash -LiteralPath $merge).Hash | Should -BeExactly $mergeBefore
                [IO.File]::ReadAllText((Join-Path $fixture.root 'src/cf/Другой модуль.bsl')) | Should -BeExactly 'unstaged business'
                Restore-WorkflowUpdateRollbackSnapshot -Snapshot $snapshot
                (Get-WorkflowUpdatePathState -RelativePath $relative) | Should -BeExactly $before
                # A historical tracked cache is still part of the raw rollback.
                # It remains ignored for subsequent package/update admission.
                $ignored=Get-GitPathList -Arguments @('ls-files','--others','--ignored','--exclude-standard','-z','--',$cache)
                @($ignored) | Should -Contain $cache
                (@(Get-GitPathList -Arguments @('ls-files','--stage','-z','--','src/cf')) -join "`0") | Should -BeExactly $businessBefore
                (Get-FileHash -LiteralPath $merge).Hash | Should -BeExactly $mergeBefore
            } finally { Remove-WorkflowUpdateRollbackSnapshot -Snapshot $snapshot }
        }
    }

It 'refreshes copied equivalent bytes on a no-op plan while preserving real staged and unmerged business entries' {
        $fixture=New-FinalizationFixture -Root (Join-Path $TestDrive 'Неизменённый пакет и конфликт бизнеса') -BusinessConflict
        & {
            . $helperPath -ProjectRoot $fixture.root -Action help *> $null
            $businessBefore=@(Get-GitPathList -Arguments @('ls-files','--stage','-z','--','src/cf')) -join "`0"
            $merge=(Get-GitOutput @('rev-parse','--git-path','MERGE_HEAD')).Trim()
            if(-not [IO.Path]::IsPathRooted($merge)){$merge=Join-Path $fixture.root $merge}
            $mergeBefore=(Get-FileHash -LiteralPath $merge).Hash
            [IO.File]::WriteAllText((Join-Path $fixture.root 'AGENT-INSTALL.md'),"same package`r`n",[Text.UTF8Encoding]::new($false))
            @(Get-GitPathList -Arguments @('status','--porcelain=v1','-z','--untracked-files=no','--','AGENT-INSTALL.md')) | Should -Be @(' M AGENT-INSTALL.md')
            $plan=New-WorkflowBranchCommitPlan -ManagedPathSpecs @('AGENT-INSTALL.md')
            $plan.newHead|Should -BeExactly $plan.oldHead
            @($plan.managedPaths)|Should -HaveCount 0
            Apply-WorkflowBranchCommitPlan -Plan $plan|Out-Null
            @(Get-GitPathList -Arguments @('status','--porcelain=v1','-z','--untracked-files=no','--','AGENT-INSTALL.md')) | Should -HaveCount 0
            (@(Get-GitPathList -Arguments @('ls-files','--stage','-z','--','src/cf')) -join "`0") | Should -BeExactly $businessBefore
            (Get-FileHash -LiteralPath $merge).Hash | Should -BeExactly $mergeBefore
            [IO.File]::ReadAllText((Join-Path $fixture.root 'src/cf/Другой модуль.bsl'))|Should -BeExactly 'unstaged business'
            [IO.File]::ReadAllText((Join-Path $fixture.root 'AGENT-INSTALL.md'))|Should -BeExactly "same package`r`n"
        }
    }

It 'preserves late owned worktree or staged changes and every business stage when finalization refuses <Change>' -ForEach @(@{Change='worktree'},@{Change='staged'}) {
        $fixture=New-FinalizationFixture -Root (Join-Path $TestDrive ('Позднее изменение '+$Change)) -BusinessConflict
        & {
            . $helperPath -ProjectRoot $fixture.root -Action help *> $null
            $businessBefore=@(Get-GitPathList -Arguments @('ls-files','--stage','-z','--','src/cf')) -join "`0"
            $merge=(Get-GitOutput @('rev-parse','--path-format=absolute','--git-path','MERGE_HEAD')).Trim()
            $mergeBefore=(Get-FileHash -LiteralPath $merge).Hash
            $plan=New-WorkflowBranchCommitPlan -ManagedPathSpecs @('AGENT-INSTALL.md')
            [IO.File]::WriteAllText((Join-Path $fixture.root 'AGENT-INSTALL.md'),'late user package',[Text.UTF8Encoding]::new($false))
            if($Change -eq 'staged'){Invoke-Git @('add','--','AGENT-INSTALL.md')}
            $ownedBefore=@(Get-GitPathList -Arguments @('ls-files','--stage','-z','--','AGENT-INSTALL.md')) -join "`0"
            {Apply-WorkflowBranchCommitPlan -Plan $plan}|Should -Throw '*managed*'
            [IO.File]::ReadAllText((Join-Path $fixture.root 'AGENT-INSTALL.md'))|Should -BeExactly 'late user package'
            (@(Get-GitPathList -Arguments @('ls-files','--stage','-z','--','src/cf')) -join "`0") | Should -BeExactly $businessBefore
            (@(Get-GitPathList -Arguments @('ls-files','--stage','-z','--','AGENT-INSTALL.md')) -join "`0") | Should -BeExactly $ownedBefore
            $saved=Join-Path $TestDrive ('Сохранённые пользовательские байты '+$Change)
            [IO.File]::WriteAllBytes($saved,[IO.File]::ReadAllBytes((Join-Path $fixture.root 'AGENT-INSTALL.md')))
            Invoke-Git @('restore','--source=HEAD','--staged','--worktree','--','AGENT-INSTALL.md')
            Apply-WorkflowBranchCommitPlan -Plan $plan|Out-Null
            [IO.File]::ReadAllText($saved)|Should -BeExactly 'late user package'
            (@(Get-GitPathList -Arguments @('ls-files','--stage','-z','--','src/cf')) -join "`0") | Should -BeExactly $businessBefore
            @(Get-GitPathList -Arguments @('status','--porcelain=v1','-z','--untracked-files=no','--','AGENT-INSTALL.md'))|Should -HaveCount 0
            (Get-FileHash -LiteralPath $merge).Hash|Should -BeExactly $mergeBefore
        }
    }
}
