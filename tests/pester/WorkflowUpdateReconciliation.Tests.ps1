BeforeAll { . (Join-Path $PSScriptRoot 'WorkflowUpdateRollback.TestSupport.ps1') }

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

Describe 'Abandon of a failed uncommitted branch package update' {
    It 'returns only owned paths to their before bytes without the defective candidate, keeps evidence and repeats as a no-op' {
        $fixture = New-WorkflowRollbackFixture -Root (Join-Path $TestDrive 'Дефектный кандидат ветки') -PendingInterruption -Branch 'itldev/defect'
        $business = Join-Path $fixture.root 'src/cf/Модуль.bsl'
        [IO.File]::WriteAllText($business, 'business staged', [Text.UTF8Encoding]::new($false))
        & git -C $fixture.root add -- 'src/cf/Модуль.bsl'
        $staged = (& git -C $fixture.root rev-parse ':src/cf/Модуль.bsl').Trim()
        [IO.File]::WriteAllText($business, 'business unstaged', [Text.UTF8Encoding]::new($false))
        . $helperPath -ProjectRoot $fixture.root -Action help *> $null
        Mock Resolve-WorkflowPackageSource { [pscustomobject]@{ root=$repoRoot; commit=('c' * 40); ref='develop'; repo='fixture'; source='path' } }
        Mock Assert-WorkflowUpdateRecordedSource { throw 'the defective candidate checkout must not be required' }
        # Output written after the recorded checkpoint is ambiguous; nothing moves.
        { Abandon-PendingWorkflowBranchUpdate -SnapshotId $fixture.id } | Should -Throw '*WORKFLOW_UPDATE_ROLLBACK_RECONCILIATION_REQUIRED*'
        [IO.File]::ReadAllText((Join-Path $fixture.root 'AGENT-INSTALL.md')) | Should -Be 'new package'
        Get-WorkflowUpdatePendingSnapshot | Should -Not -BeNullOrEmpty
        # The branch owner records the failed state exactly as it does after a post-copy defect.
        $pending = Get-WorkflowUpdatePendingSnapshot
        Save-WorkflowUpdateSnapshotReceipt -Snapshot $pending.snapshot -Source ([pscustomobject]@{ root=$repoRoot; commit=('b' * 40) }) -Phase post-copy-failed
        Abandon-PendingWorkflowBranchUpdate -SnapshotId $fixture.id
        [IO.File]::ReadAllText((Join-Path $fixture.root 'AGENT-INSTALL.md')) | Should -Be 'old package'
        [IO.File]::ReadAllText((Join-Path $fixture.root '.dev.env')) | Should -Be "CAVEMAN=On`n"
        [IO.File]::ReadAllText((Join-Path $fixture.root '.agent-1c/mcp/client-managed.json')) | Should -Be '{"owners":{"old":"keep"}}'
        Get-CurrentCommit | Should -Be $fixture.beforeHead
        [IO.File]::ReadAllText($business) | Should -Be 'business unstaged'
        (& git -C $fixture.root rev-parse ':src/cf/Модуль.bsl').Trim() | Should -Be $staged
        Get-WorkflowUpdatePendingSnapshot | Should -BeNullOrEmpty
        $evidence = Join-Path $fixture.root ('.agent-1c/snapshots/workflow-update/itl-workflow-update-abandoned-' + $fixture.id)
        $result = Get-Content -LiteralPath (Join-Path $evidence 'abandon-result.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $result.sourceCommit | Should -Be ('b' * 40)
        $result.head | Should -Be $fixture.beforeHead
        Test-Path -LiteralPath (Join-Path $evidence 'transaction.json') -PathType Leaf | Should -BeTrue
        { Abandon-PendingWorkflowBranchUpdate -SnapshotId $fixture.id } | Should -Not -Throw
        (Get-WorkflowUpdateRecoveryStatus).retainedCount | Should -Be 0
    }

    It 'refuses master, committed phases and owned staging before any project byte changes' {
        foreach ($case in @('master', 'branch-commit-ready', 'staged')) {
            $branch = if ($case -eq 'master') { 'master' } else { 'itldev/defect' }
            $fixture = New-WorkflowRollbackFixture -Root (Join-Path $TestDrive ('Отказ отката ' + $case)) -PendingInterruption -Branch $branch
            . $helperPath -ProjectRoot $fixture.root -Action help *> $null
            Mock Resolve-WorkflowPackageSource { [pscustomobject]@{ root=$repoRoot; commit=('c' * 40); ref='develop'; repo='fixture'; source='path' } }
            Mock Assert-WorkflowUpdateRecordedSource {}
            $pending = Get-WorkflowUpdatePendingSnapshot
            $phase = if ($case -eq 'branch-commit-ready') { 'branch-commit-ready' } else { 'post-copy-failed' }
            Save-WorkflowUpdateSnapshotReceipt -Snapshot $pending.snapshot -Source ([pscustomobject]@{ root=$repoRoot; commit=('b' * 40) }) -Phase $phase
            if ($case -eq 'staged') { & git -C $fixture.root add -- 'AGENT-INSTALL.md' }
            $expected = @{ master='*WORKFLOW_UPDATE_ABANDON_SCOPE_INVALID*'; 'branch-commit-ready'='*WORKFLOW_UPDATE_RECONCILIATION_SCOPE_INVALID*'; staged='*WORKFLOW_UPDATE_ABANDON_INDEX_CHANGED*' }[$case]
            { Abandon-PendingWorkflowBranchUpdate -SnapshotId $fixture.id } | Should -Throw $expected
            [IO.File]::ReadAllText((Join-Path $fixture.root 'AGENT-INSTALL.md')) | Should -Be 'new package'
            [IO.File]::ReadAllText((Join-Path $fixture.root '.dev.env')) | Should -Be "CAVEMAN=auto`n"
            Get-WorkflowUpdatePendingSnapshot | Should -Not -BeNullOrEmpty
        }
    }
}
