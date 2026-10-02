BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSupport.ps1')
    $context = Initialize-WorkflowPesterContext
    $helperPath = $context.HelperPath
    $repoRoot = $context.RepoRoot

    function New-WorkflowRollbackFixture {
        param([string]$Root, [switch]$PendingInterruption, [switch]$MetadataCachedPackage)
        New-Item -ItemType Directory -Force -Path (Join-Path $Root '.agent-1c/mcp'), (Join-Path $Root 'src/cf') | Out-Null
        [IO.File]::WriteAllText((Join-Path $Root '.agent-1c/project.json'), '{"aiRules":{"tools":["codex"]}}', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $Root '.gitignore'), ".dev.env`n.agent-1c/mcp/`n.agent-1c/snapshots/`n.agent-1c/tmp/`n", [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $Root 'AGENT-INSTALL.md'), 'old package', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $Root 'src/cf/Модуль.bsl'), 'business baseline', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $Root '.dev.env'), "CAVEMAN=On`n", [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $Root '.agent-1c/mcp/client-managed.json'), '{"owners":{"old":"keep"}}', [Text.UTF8Encoding]::new($false))
        & git -C $Root init -q -b master
        & git -C $Root config user.name 'Workflow Rollback Test'
        & git -C $Root config user.email 'rollback@example.invalid'
        if ($MetadataCachedPackage) {
            # Supported local Git settings make this timestamp-preserving,
            # same-size copy deterministic without changing ordinary fixtures.
            & git -C $Root config --local core.trustctime false
            & git -C $Root config --local core.checkStat minimal
            $packageTime = [DateTime]::new(2020, 1, 2, 3, 4, 5, [DateTimeKind]::Utc)
            [IO.File]::SetLastWriteTimeUtc((Join-Path $Root 'AGENT-INSTALL.md'), $packageTime)
        }
        & git -C $Root add --all
        & git -C $Root commit -qm baseline
        $LASTEXITCODE | Should -Be 0
        $beforeHead = (& git -C $Root rev-parse HEAD).Trim()
        $saved = & {
            . $helperPath -ProjectRoot $Root -Action help *> $null
            $source = [pscustomobject]@{ root=$repoRoot; commit=('b' * 40); ref='master'; repo='fixture'; source='path' }
            $snapshot = New-WorkflowUpdateRollbackSnapshot -RelativePaths @('AGENT-INSTALL.md', '.dev.env', '.agent-1c/mcp/client-managed.json') `
                -SnapshotParent (Join-Path $Root '.agent-1c/snapshots/workflow-update')
            Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase prepared
            [IO.File]::WriteAllText((Join-Path $Root 'AGENT-INSTALL.md'), 'new package', [Text.UTF8Encoding]::new($false))
            if ($MetadataCachedPackage) {
                [IO.File]::SetLastWriteTimeUtc((Join-Path $Root 'AGENT-INSTALL.md'), $packageTime)
            }
            if ($PendingInterruption) {
                Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase copy-complete
                Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase post-copy-running
            }
            [IO.File]::WriteAllText((Join-Path $Root '.dev.env'), "CAVEMAN=auto`n", [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $Root '.agent-1c/mcp/client-managed.json'), '{"owners":{"new":"keep"}}', [Text.UTF8Encoding]::new($false))
            if ($PendingInterruption) {
                return [pscustomobject]@{ id=(Split-Path -Leaf $snapshot.root).Substring('itl-workflow-update-rollback-'.Length); retained=$snapshot.root }
            }
            if ($MetadataCachedPackage) {
                # Fully read the setup's new bytes once; the rollback owner
                # must later detect the restored old bytes on its own.
                & git -C $Root add --renormalize -- AGENT-INSTALL.md
            } else {
                & git -C $Root add -- AGENT-INSTALL.md
            }
            & git -C $Root commit -qm update
            $LASTEXITCODE | Should -Be 0
            Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase post-copy-complete
            $retained = Retain-WorkflowUpdateRollbackSnapshot -Snapshot $snapshot
            [pscustomobject]@{ id=(Split-Path -Leaf $retained).Substring('itl-workflow-update-completed-'.Length); retained=$retained }
        }
        return [pscustomobject]@{ root=$Root; id=$saved.id; retained=$saved.retained; beforeHead=$beforeHead; updateHead=(& git -C $Root rev-parse HEAD).Trim() }
    }

    function Set-RollbackSourceFixture {
        Mock Resolve-WorkflowPackageSource { [pscustomobject]@{ root=$repoRoot; commit=('b' * 40); ref='master'; repo='fixture'; source='path' } }
        Mock Assert-WorkflowUpdateRecordedSource {}
    }

    function Write-ReconciliationDecisionFixture {
        param([object]$Status, [string]$Path)
        $report = Get-Content -LiteralPath $Status.reportPath -Raw | ConvertFrom-Json
        $decision = @{ schemaVersion=1; reportPath=$Status.reportPath; reportSha256=$Status.reportSha256; paths=@($report.paths | ForEach-Object {
            @{relativePath=$_.relativePath; observedState=$_.observedState; decision='resume-confirmed-helper-output'; reason='Fixture interrupted dotenv and client owner outputs exactly match their expected candidate bytes.'}
        }) }
        [IO.File]::WriteAllText($Path, ($decision | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    }
}

Describe 'Scoped reconciliation of an interrupted post-copy stage' {
    It 'preserves ambiguous bytes and acknowledges reviewed helper outputs without changing business staging or HEAD, then resumes the original owner' {
        $fixture = New-WorkflowRollbackFixture -Root (Join-Path $TestDrive 'Прерванный post-copy с пробелом') -PendingInterruption
        $business = Join-Path $fixture.root 'src/cf/Модуль.bsl'
        [IO.File]::WriteAllText($business, 'business staged', [Text.UTF8Encoding]::new($false))
        & git -C $fixture.root add -- 'src/cf/Модуль.bsl'
        $staged = (& git -C $fixture.root rev-parse ':src/cf/Модуль.bsl').Trim()
        [IO.File]::WriteAllText($business, 'business unstaged', [Text.UTF8Encoding]::new($false))
        . $helperPath -ProjectRoot $fixture.root -Action help *> $null
        Set-RollbackSourceFixture
        { Assert-WorkflowUpdateSnapshotCurrentState -Pending (Get-WorkflowUpdatePendingSnapshot) } | Should -Throw '*WORKFLOW_UPDATE_RECONCILIATION_REQUIRED*'
        $script:RunRequiredAction | Should -Match ([regex]::Escape('-Recovery status -SnapshotId ' + $fixture.id))
        $status = Get-WorkflowUpdateRecoveryStatus -SnapshotId $fixture.id
        $status.changedPathCount | Should -Be 2
        $report = Get-Content -LiteralPath $status.reportPath -Raw -Encoding UTF8 | ConvertFrom-Json
        [IO.File]::ReadAllText(($report.paths | Where-Object relativePath -eq '.dev.env').currentPath) | Should -Be "CAVEMAN=auto`n"
        [IO.File]::ReadAllText(($report.paths | Where-Object relativePath -eq '.dev.env').beforePath) | Should -Be "CAVEMAN=On`n"
        $decisionPath = Join-Path $fixture.root '.agent-1c/snapshots/decision.json'
        Write-ReconciliationDecisionFixture -Status $status -Path $decisionPath
        Complete-WorkflowUpdateReconciliation -SnapshotId $fixture.id -DecisionFile $decisionPath
        Assert-WorkflowUpdateSnapshotCurrentState -Pending (Get-WorkflowUpdatePendingSnapshot)
        Get-CurrentCommit | Should -Be $fixture.beforeHead
        [IO.File]::ReadAllText($business) | Should -Be 'business unstaged'
        (& git -C $fixture.root rev-parse ':src/cf/Модуль.bsl').Trim() | Should -Be $staged
        Mock Assert-WorkflowPackageUpdateContext {}
        Mock Invoke-Agent1cFreshProcess { [pscustomobject]@{ exitCode = 0 } }
        Mock Assert-WorkflowDevelopmentBranchRolloutComplete {}
        $previousSource = $env:ITL_WORKFLOW_SOURCE_PATH
        try {
            $env:ITL_WORKFLOW_SOURCE_PATH = ''
            Update-WorkflowPackage
        } finally { $env:ITL_WORKFLOW_SOURCE_PATH = $previousSource }
        Should -Invoke Invoke-Agent1cFreshProcess -Times 1 -Exactly
        Get-WorkflowUpdatePendingSnapshot | Should -BeNullOrEmpty
        (Get-WorkflowUpdateRecoveryStatus).retainedCount | Should -Be 1
    }

    It 'refuses an edit after the reviewed report and retains the original receipt and every current byte' {
        $fixture = New-WorkflowRollbackFixture -Root (Join-Path $TestDrive 'Поздняя правка после review') -PendingInterruption
        . $helperPath -ProjectRoot $fixture.root -Action help *> $null
        Set-RollbackSourceFixture
        $status = Get-WorkflowUpdateRecoveryStatus -SnapshotId $fixture.id
        $decisionPath = Join-Path $fixture.root '.agent-1c/snapshots/decision.json'
        Write-ReconciliationDecisionFixture -Status $status -Path $decisionPath
        $receiptPath = (Get-WorkflowUpdatePendingSnapshot).receiptPath
        $beforeHash = (Get-FileHash -LiteralPath $receiptPath).Hash
        [IO.File]::WriteAllText((Join-Path $fixture.root '.dev.env'), 'later user edit', [Text.UTF8Encoding]::new($false))
        { Complete-WorkflowUpdateReconciliation -SnapshotId $fixture.id -DecisionFile $decisionPath } | Should -Throw '*WORKFLOW_UPDATE_RECONCILIATION_CHANGED*'
        (Get-FileHash -LiteralPath $receiptPath).Hash | Should -Be $beforeHash
        [IO.File]::ReadAllText((Join-Path $fixture.root '.dev.env')) | Should -Be 'later user edit'
        Get-CurrentCommit | Should -Be $fixture.beforeHead
    }

    It 'rejects incomplete review and tampered report proof before acknowledging the transaction' {
        $fixture = New-WorkflowRollbackFixture -Root (Join-Path $TestDrive 'Неполный review post-copy') -PendingInterruption
        . $helperPath -ProjectRoot $fixture.root -Action help *> $null
        Set-RollbackSourceFixture
        $status = Get-WorkflowUpdateRecoveryStatus -SnapshotId $fixture.id
        $decisionPath = Join-Path $fixture.root '.agent-1c/snapshots/decision.json'
        Write-ReconciliationDecisionFixture -Status $status -Path $decisionPath
        $decision = Get-Content -LiteralPath $decisionPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $decision.paths = @($decision.paths | Select-Object -First 1)
        [IO.File]::WriteAllText($decisionPath, ($decision | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        { Complete-WorkflowUpdateReconciliation -SnapshotId $fixture.id -DecisionFile $decisionPath } | Should -Throw '*WORKFLOW_UPDATE_RECONCILIATION_DECISION_INVALID*'
        Write-ReconciliationDecisionFixture -Status $status -Path $decisionPath
        [IO.File]::AppendAllText($status.reportPath, ' ', [Text.UTF8Encoding]::new($false))
        { Complete-WorkflowUpdateReconciliation -SnapshotId $fixture.id -DecisionFile $decisionPath } | Should -Throw '*WORKFLOW_UPDATE_RECONCILIATION_REPORT_INVALID*'
        { Assert-WorkflowUpdateSnapshotCurrentState -Pending (Get-WorkflowUpdatePendingSnapshot) } | Should -Throw '*WORKFLOW_UPDATE_RECONCILIATION_REQUIRED*'
    }
}

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

Describe 'Branch workflow finalization preserves unrelated index entries' -Tag 'WorkflowFinalize' {
    BeforeAll {
        function New-FinalizationFixture {
            param([string]$Root, [switch]$BusinessConflict)
            $utf8=[Text.UTF8Encoding]::new($false)
            New-Item -ItemType Directory -Force -Path (Join-Path $Root '.agent-1c'),(Join-Path $Root 'src/cf') | Out-Null
            [IO.File]::WriteAllText((Join-Path $Root '.gitignore'),".agent-1c/tmp/`n.agent-1c/snapshots/`n",$utf8)
            [IO.File]::WriteAllText((Join-Path $Root '.agent-1c/project.json'),'{"aiRules":{"tools":["codex"]}}',$utf8)
            [IO.File]::WriteAllText((Join-Path $Root '.agent-1c/dependency-lock.json'),'{"schemaVersion":1,"dependencies":{}}',$utf8)
            [IO.File]::WriteAllText((Join-Path $Root 'AGENT-INSTALL.md'),"same package`n",$utf8)
            [IO.File]::WriteAllText((Join-Path $Root 'README.md'),"known readme`r`n",$utf8)
            [IO.File]::WriteAllText((Join-Path $Root 'DEVELOPER-GUIDE.ru.md'),"known guide`r`n",$utf8)
            [IO.File]::WriteAllText((Join-Path $Root 'VANESSA-TESTS-GUIDE.md'),'custom user document',$utf8)
            [IO.File]::WriteAllText((Join-Path $Root 'src/cf/Модуль.bsl'),'base',$utf8)
            [IO.File]::WriteAllText((Join-Path $Root 'src/cf/Другой модуль.bsl'),'baseline',$utf8)
            $known=@{ 'README.md'=@((Get-FileHash (Join-Path $Root 'README.md')).Hash); 'DEVELOPER-GUIDE.ru.md'=@((Get-FileHash (Join-Path $Root 'DEVELOPER-GUIDE.ru.md')).Hash); 'VANESSA-TESTS-GUIDE.md'=@('0'*64) }
            & git -C $Root init -q -b itldev/finalize;$LASTEXITCODE|Should -Be 0
            & git -C $Root config user.name 'Finalization fixture';$LASTEXITCODE|Should -Be 0
            & git -C $Root config user.email 'finalize@example.invalid';$LASTEXITCODE|Should -Be 0
            & git -C $Root config core.autocrlf true;$LASTEXITCODE|Should -Be 0
            & git -C $Root add --all;$LASTEXITCODE|Should -Be 0
            & git -C $Root commit -qm baseline;$LASTEXITCODE|Should -Be 0
            if($BusinessConflict){
                & git -C $Root checkout -qb other;$LASTEXITCODE|Should -Be 0
                [IO.File]::WriteAllText((Join-Path $Root 'src/cf/Модуль.bsl'),'other',$utf8)
                & git -C $Root commit -qam other;$LASTEXITCODE|Should -Be 0
                & git -C $Root checkout -q itldev/finalize;$LASTEXITCODE|Should -Be 0
                [IO.File]::WriteAllText((Join-Path $Root 'src/cf/Модуль.bsl'),'current',$utf8)
                & git -C $Root commit -qam current;$LASTEXITCODE|Should -Be 0
                & git -C $Root merge --no-edit other *> $null;$LASTEXITCODE|Should -Be 1
            }
            [IO.File]::WriteAllText((Join-Path $Root 'src/cf/Другой модуль.bsl'),'staged business',$utf8)
            & git -C $Root add -- 'src/cf/Другой модуль.bsl';$LASTEXITCODE|Should -Be 0
            [IO.File]::WriteAllText((Join-Path $Root 'src/cf/Другой модуль.bsl'),'unstaged business',$utf8)
            [pscustomobject]@{root=$Root;known=$known}
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
            $details.recoveryExecutorRoot=$repoRoot
            $details.recoveryExecutorCommit=('b'*40)
            Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase $phase -Details $details
            (Get-WorkflowUpdatePendingSnapshot).receipt.preUpdateHead|Should -BeExactly $before
            if($Owner -eq 'branch'){
                (Invoke-WorkflowDevelopmentBranchUpdate -Source $source).status|Should -BeExactly 'completed'
            }else{
                (Assert-WorkflowUpdateMasterCommitCheckpoint -Receipt (Get-WorkflowUpdatePendingSnapshot).receipt -Source $source).committed|Should -BeTrue
                & {$LifecyclePhase='post-copy';$OperationContinuation=$true;Update-WorkflowPackage}
            }
            Get-CurrentCommit|Should -BeExactly $committed
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
