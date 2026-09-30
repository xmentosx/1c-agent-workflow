BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSupport.ps1')
    $context = Initialize-WorkflowPesterContext
    $helperPath = $context.HelperPath
    $repoRoot = $context.RepoRoot

    function New-WorkflowRollbackFixture {
        param([string]$Root, [switch]$PendingInterruption)
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
            if ($PendingInterruption) {
                Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase copy-complete
                Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase post-copy-running
            }
            [IO.File]::WriteAllText((Join-Path $Root '.dev.env'), "CAVEMAN=auto`n", [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $Root '.agent-1c/mcp/client-managed.json'), '{"owners":{"new":"keep"}}', [Text.UTF8Encoding]::new($false))
            if ($PendingInterruption) {
                return [pscustomobject]@{ id=(Split-Path -Leaf $snapshot.root).Substring('itl-workflow-update-rollback-'.Length); retained=$snapshot.root }
            }
            & git -C $Root add -- AGENT-INSTALL.md
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
