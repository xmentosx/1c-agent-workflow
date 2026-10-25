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
