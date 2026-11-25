BeforeAll { . (Join-Path $PSScriptRoot 'WorkflowUpdateRollback.TestSupport.ps1') }

Describe 'Completed workflow rollback through the existing update owner' {
    It 'retains exact old settings and post-state without presenting a completed root as pending' {
        $fixture = New-WorkflowRollbackFixture -Root (Join-Path $TestDrive 'Сохранение workflow с пробелом')
        . $helperPath -ProjectRoot $fixture.root -Action help *> $null
        $saved = Get-WorkflowUpdateCompletedSnapshot -SnapshotId $fixture.id
        $saved.receipt.preUpdateHead | Should -Be $fixture.beforeHead
        $saved.receipt.completedHead | Should -Be $fixture.updateHead
        $saved.receipt.beforePathState.'.dev.env' | Should -Not -Be $saved.receipt.pathState.'.dev.env'
        Get-WorkflowUpdatePendingSnapshot | Should -BeNullOrEmpty
        (Get-WorkflowUpdateRecoveryStatus).retainedCount | Should -Be 1
        Assert-WorkflowUpdateSnapshotCurrentState -Pending $saved
    }

    It 'restores package and ignored settings while retaining business bytes and its staged index, then repeats idempotently' {
        $fixture = New-WorkflowRollbackFixture -Root (Join-Path $TestDrive 'Откат workflow с пробелом')
        $cachePath = Join-Path $fixture.root '.agent-1c/tools/openspec-cli/pinned/cli.js'
        New-Item -ItemType Directory -Force -Path (Split-Path $cachePath) | Out-Null
        [IO.File]::WriteAllText($cachePath, 'keep pinned CLI cache', [Text.UTF8Encoding]::new($false))
        $generationPath = Join-Path $fixture.root '.agent-1c/execution-guard-generation.json'
        [IO.File]::WriteAllText($generationPath, '{"generation":7}', [Text.UTF8Encoding]::new($false))
        $business = Join-Path $fixture.root 'src/cf/Модуль.bsl'
        [IO.File]::WriteAllText($business, 'business staged', [Text.UTF8Encoding]::new($false))
        & git -C $fixture.root add -- 'src/cf/Модуль.bsl'
        $staged = (& git -C $fixture.root rev-parse ':src/cf/Модуль.bsl').Trim()
        [IO.File]::WriteAllText($business, 'business unstaged', [Text.UTF8Encoding]::new($false))
        . $helperPath -ProjectRoot $fixture.root -Action help *> $null
        Set-RollbackSourceFixture
        Restore-CompletedWorkflowUpdate -SnapshotId $fixture.id
        $restoredHead = Get-CurrentCommit
        $restoredHead | Should -Not -Be $fixture.updateHead
        [IO.File]::ReadAllText((Join-Path $fixture.root 'AGENT-INSTALL.md')) | Should -Be 'old package'
        [IO.File]::ReadAllText((Join-Path $fixture.root '.dev.env')) | Should -Be "CAVEMAN=On`n"
        [IO.File]::ReadAllText((Join-Path $fixture.root '.agent-1c/mcp/client-managed.json')) | Should -Be '{"owners":{"old":"keep"}}'
        [IO.File]::ReadAllText($business) | Should -Be 'business unstaged'
        (& git -C $fixture.root rev-parse ':src/cf/Модуль.bsl').Trim() | Should -Be $staged
        (& git -C $fixture.root show 'HEAD:src/cf/Модуль.bsl') | Should -Be 'business baseline'
        @(Get-GitPathList -Arguments @('diff-tree', '--no-commit-id', '--name-only', '-r', '-z', $restoredHead)) | Should -Be @('AGENT-INSTALL.md')
        Get-WorkflowUpdatePendingSnapshot | Should -BeNullOrEmpty
        [IO.File]::ReadAllText($cachePath) | Should -Be 'keep pinned CLI cache'
        [IO.File]::ReadAllText($generationPath) | Should -Be '{"generation":7}'
        @(Get-GitPathList -Arguments @('ls-files', '--others', '--exclude-standard', '-z')) | Should -HaveCount 0
        $excludePath = Join-Path $fixture.root '.git/info/exclude'
        $excludeBefore = [IO.File]::ReadAllBytes($excludePath)
        Restore-CompletedWorkflowUpdate -SnapshotId $fixture.id
        Get-CurrentCommit | Should -Be $restoredHead
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($excludePath)) | Should -Be ([Convert]::ToBase64String($excludeBefore))
        (Get-WorkflowUpdateRecoveryStatus).retainedCount | Should -Be 2
    }

    It 'completed rollback restores prior tracked ignored package cache but never adopts untracked cache' -Tag 'PackageContentRollback' {
        $fixture=New-WorkflowRollbackFixture -Root (Join-Path $TestDrive 'Полный откат Python с пробелом') -PackageCache
        $tracked='.agents/skills/itl-remote-runner/scripts/__pycache__/tracked.pyc'
        $untracked='.agents/skills/itl-remote-runner/scripts/__pycache__/untracked.pyc'
        . $helperPath -ProjectRoot $fixture.root -Action help *> $null
        Set-RollbackSourceFixture
        $beforeTree=(Get-GitOutput @('rev-parse',($fixture.beforeHead+'^{tree}'))).Trim()
        $beforeRecords=@(Get-GitPathList -Arguments @('ls-tree','-r','-z',$fixture.beforeHead,'--',$tracked)) -join "`0"
        $beforeBlob=(Get-GitOutput @('rev-parse',($fixture.beforeHead+':'+$tracked))).Trim()
        @(Get-GitPathList -Arguments @('ls-tree','-r','--name-only','-z','HEAD','--',$tracked,$untracked)) | Should -HaveCount 0
        $business=Join-Path $fixture.root 'src/cf/Модуль.bsl'
        [IO.File]::WriteAllText($business,'business staged',[Text.UTF8Encoding]::new($false))
        Invoke-Git @('add','--','src/cf/Модуль.bsl')
        $businessBefore=@(Get-GitPathList -Arguments @('ls-files','--stage','-z','--','src/cf')) -join "`0"
        [IO.File]::WriteAllText($business,'business unstaged',[Text.UTF8Encoding]::new($false))
        Restore-CompletedWorkflowUpdate -SnapshotId $fixture.id
        [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $fixture.root $tracked))) | Should -BeExactly ([Convert]::ToBase64String([byte[]]@(0,255,13,10)))
        [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $fixture.root $untracked))) | Should -BeExactly ([Convert]::ToBase64String([byte[]]@(0,128,10,13)))
        (@(Get-GitPathList -Arguments @('ls-tree','-r','-z','HEAD','--',$tracked)) -join "`0") | Should -BeExactly $beforeRecords
        @(Get-GitPathList -Arguments @('ls-files','--stage','-z','--',$tracked)) | Should -Be @("100644 $beforeBlob 0`t$tracked")
        (Get-GitOutput @('rev-parse','HEAD^{tree}')).Trim() | Should -BeExactly $beforeTree
        @(Get-GitPathList -Arguments @('ls-files','-z','--',$untracked)) | Should -HaveCount 0
        (@(Get-GitPathList -Arguments @('ls-files','--stage','-z','--','src/cf')) -join "`0") | Should -BeExactly $businessBefore
        [IO.File]::ReadAllText($business) | Should -BeExactly 'business unstaged'
        $restoredHead=Get-CurrentCommit
        Restore-CompletedWorkflowUpdate -SnapshotId $fixture.id
        Get-CurrentCommit | Should -BeExactly $restoredHead
        (@(Get-GitPathList -Arguments @('ls-files','--stage','-z','--','src/cf')) -join "`0") | Should -BeExactly $businessBefore
        Get-WorkflowUpdatePendingSnapshot | Should -BeNullOrEmpty
    }

    It 'commits restored same-size package bytes when Git stat metadata remains unchanged' {
        $fixture = New-WorkflowRollbackFixture -Root (Join-Path $TestDrive 'Откат workflow с пробелом и сохранёнными метаданными') -MetadataCachedPackage
        $package = Join-Path $fixture.root 'AGENT-INSTALL.md'
        $packageTime = [DateTime]::new(2020, 1, 2, 3, 4, 5, [DateTimeKind]::Utc)
        (& git -C $fixture.root show ($fixture.beforeHead + ':AGENT-INSTALL.md')) | Should -Be 'old package'
        (& git -C $fixture.root show 'HEAD:AGENT-INSTALL.md') | Should -Be 'new package'
        (Get-Item -LiteralPath $package).Length | Should -Be 11
        [IO.File]::GetLastWriteTimeUtc($package).Ticks | Should -Be $packageTime.Ticks
        $business = Join-Path $fixture.root 'src/cf/Модуль.bsl'
        [IO.File]::WriteAllText($business, 'business staged', [Text.UTF8Encoding]::new($false))
        & git -C $fixture.root add -- 'src/cf/Модуль.bsl'
        $staged = (& git -C $fixture.root rev-parse ':src/cf/Модуль.bsl').Trim()
        [IO.File]::WriteAllText($business, 'business unstaged', [Text.UTF8Encoding]::new($false))
        . $helperPath -ProjectRoot $fixture.root -Action help *> $null
        Set-RollbackSourceFixture

        Restore-CompletedWorkflowUpdate -SnapshotId $fixture.id

        [IO.File]::ReadAllText($package) | Should -Be 'old package'
        [IO.File]::GetLastWriteTimeUtc($package).Ticks | Should -Be $packageTime.Ticks
        (& git -C $fixture.root show 'HEAD:AGENT-INSTALL.md') | Should -Be 'old package'
        $restoredHead = Get-CurrentCommit
        $restoredHead | Should -Not -Be $fixture.updateHead
        (& git -C $fixture.root rev-parse ':AGENT-INSTALL.md').Trim() | Should -Be ((& git -C $fixture.root rev-parse 'HEAD:AGENT-INSTALL.md').Trim())
        [IO.File]::ReadAllText($business) | Should -Be 'business unstaged'
        (& git -C $fixture.root rev-parse ':src/cf/Модуль.bsl').Trim() | Should -Be $staged
        (& git -C $fixture.root show 'HEAD:src/cf/Модуль.bsl') | Should -Be 'business baseline'
        @(Get-GitPathList -Arguments @('diff-tree', '--no-commit-id', '--name-only', '-r', '-z', $restoredHead)) | Should -Be @('AGENT-INSTALL.md')
        [IO.File]::ReadAllText((Join-Path $fixture.root '.dev.env')) | Should -Be "CAVEMAN=On`n"
        [IO.File]::ReadAllText((Join-Path $fixture.root '.agent-1c/mcp/client-managed.json')) | Should -Be '{"owners":{"old":"keep"}}'
        Get-WorkflowUpdatePendingSnapshot | Should -BeNullOrEmpty
    }

    It 'preserves a later change to <relative> before any rollback write' -ForEach @(
        @{relative='.dev.env'}, @{relative='.agent-1c/mcp/client-managed.json'}
    ) {
        $fixture = New-WorkflowRollbackFixture -Root (Join-Path $TestDrive ('Поздняя правка ' + [guid]::NewGuid().ToString('N')))
        $path = Join-Path $fixture.root $relative
        [IO.File]::WriteAllText($path, 'later user change', [Text.UTF8Encoding]::new($false))
        . $helperPath -ProjectRoot $fixture.root -Action help *> $null
        Set-RollbackSourceFixture
        { Restore-CompletedWorkflowUpdate -SnapshotId $fixture.id } | Should -Throw '*WORKFLOW_UPDATE_RECONCILIATION_REQUIRED*'
        [IO.File]::ReadAllText($path) | Should -Be 'later user change'
        [IO.File]::ReadAllText((Join-Path $fixture.root 'AGENT-INSTALL.md')) | Should -Be 'new package'
        Get-CurrentCommit | Should -Be $fixture.updateHead
        Get-WorkflowUpdatePendingSnapshot | Should -BeNullOrEmpty
    }

    It 'rejects corrupted old backup bytes instead of installing them' {
        $fixture = New-WorkflowRollbackFixture -Root (Join-Path $TestDrive 'Повреждённый backup workflow')
        . $helperPath -ProjectRoot $fixture.root -Action help *> $null
        Set-RollbackSourceFixture
        $saved = Get-WorkflowUpdateCompletedSnapshot -SnapshotId $fixture.id
        $record = @($saved.snapshot.records | Where-Object relativePath -EQ '.dev.env')[0]
        [IO.File]::WriteAllText($record.backupPath, 'corrupted backup', [Text.UTF8Encoding]::new($false))
        { Restore-CompletedWorkflowUpdate -SnapshotId $fixture.id } | Should -Throw '*WORKFLOW_UPDATE_ROLLBACK_BACKUP_INVALID*'
        Get-CurrentCommit | Should -Be $fixture.updateHead
        [IO.File]::ReadAllText((Join-Path $fixture.root '.dev.env')) | Should -Be "CAVEMAN=auto`n"
    }

    It 'continues an interrupted path restore but blocks a later edit before continuing it' {
        $fixture = New-WorkflowRollbackFixture -Root (Join-Path $TestDrive 'Прерванный откат workflow')
        . $helperPath -ProjectRoot $fixture.root -Action help *> $null
        Set-RollbackSourceFixture
        $script:realPathReplace = (Get-Command Invoke-WorkflowManagedPathReplace).ScriptBlock
        $script:restoreCalls = 0
        function Invoke-WorkflowManagedPathReplace {
            param([string]$SourcePath, [string]$TargetPath, [switch]$Directory)
            $script:restoreCalls++
            if ($script:restoreCalls -eq 2) { throw 'interrupted after first path' }
            & $script:realPathReplace -SourcePath $SourcePath -TargetPath $TargetPath -Directory:$Directory
        }
        { Restore-CompletedWorkflowUpdate -SnapshotId $fixture.id } | Should -Throw '*WORKFLOW_UPDATE_ROLLBACK_INCOMPLETE*interrupted after first path*'
        (Get-WorkflowUpdatePendingSnapshot).receipt.phase | Should -Be 'rollback-restoring'
        [IO.File]::ReadAllText((Join-Path $fixture.root 'AGENT-INSTALL.md')) | Should -Be 'old package'
        $envPath = Join-Path $fixture.root '.dev.env'
        [IO.File]::WriteAllText($envPath, 'late recovery edit', [Text.UTF8Encoding]::new($false))
        { Restore-CompletedWorkflowUpdate -SnapshotId $fixture.id } | Should -Throw '*WORKFLOW_UPDATE_ROLLBACK_RECONCILIATION_REQUIRED*'
        [IO.File]::ReadAllText($envPath) | Should -Be 'late recovery edit'
        [IO.File]::WriteAllText($envPath, "CAVEMAN=auto`n", [Text.UTF8Encoding]::new($false))
        Restore-CompletedWorkflowUpdate -SnapshotId $fixture.id
        [IO.File]::ReadAllText($envPath) | Should -Be "CAVEMAN=On`n"
        Get-WorkflowUpdatePendingSnapshot | Should -BeNullOrEmpty
    }

    It 'resumes a lost acknowledgement after the rollback commit ref moved but before the owned index was repaired' {
        $fixture = New-WorkflowRollbackFixture -Root (Join-Path $TestDrive 'Откат после update-ref')
        . $helperPath -ProjectRoot $fixture.root -Action help *> $null
        Set-RollbackSourceFixture
        $script:realRollbackGit = (Get-Command Invoke-Git).ScriptBlock
        $script:failRollbackReset = $true
        function Invoke-Git {
            param([string[]]$Arguments)
            if ($Arguments[0] -eq 'reset' -and $script:failRollbackReset) {
                $script:failRollbackReset = $false
                throw 'stopped after update-ref'
            }
            & $script:realRollbackGit $Arguments
        }
        { Restore-CompletedWorkflowUpdate -SnapshotId $fixture.id } | Should -Throw '*stopped after update-ref*'
        $candidateHead = Get-CurrentCommit
        $candidateHead | Should -Not -Be $fixture.updateHead
        (Get-WorkflowUpdatePendingSnapshot).receipt.phase | Should -Be 'rollback-commit-ready'
        Restore-CompletedWorkflowUpdate -SnapshotId $fixture.id
        Get-CurrentCommit | Should -Be $candidateHead
        @(Get-GitPathList -Arguments @('diff', '--cached', '--name-only', '-z')) | Should -HaveCount 0
        Get-WorkflowUpdatePendingSnapshot | Should -BeNullOrEmpty
    }
}
