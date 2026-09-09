BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSupport.ps1')
    $context = Initialize-WorkflowPesterContext
    $RepoRoot = $context.RepoRoot

    function Get-DeliveryTextSha256 {
        param([string]$Text)
        $sha = [Security.Cryptography.SHA256]::Create()
        try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-', '').ToLowerInvariant() }
        finally { $sha.Dispose() }
    }
    function Get-DeliveryCanonicalJsonSha256 {
        param([object]$Value)
        Get-DeliveryTextSha256 -Text ($Value | ConvertTo-Json -Depth 24 -Compress)
    }
    function Get-DeliveryFileSha256 { param([string]$Path); (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
    function Get-DeliveryCommonGitDirectory { (& git -C $script:Root rev-parse --path-format=absolute --git-common-dir).Trim() }
    function Test-SourceDeliveryPathInUse { param([string]$Path); return $false }
    function Invoke-RepositoryGit {
        param([string]$RepositoryRoot,[string[]]$Arguments,[switch]$AllowFailure)
        $output = @(& git -C $RepositoryRoot @Arguments 2>&1); [pscustomobject]@{ exitCode=$LASTEXITCODE; stdout=($output -join [Environment]::NewLine); stderr='' }
    }
    function Invoke-SourceDeliveryPostSuccessCleanup {
        param([string]$FreshProjectsRoot,[string]$E2EProjectRoot,[string[]]$PreservePaths)
        [pscustomobject]@{ status='completed'; warnings=@() }
    }
    . (Join-Path $RepoRoot 'scripts\source-delivery-resources.ps1')

    function New-LedgerRepository {
        $nonAscii = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('0L/Rg9GC0Yw='))
        $root = Join-Path $TestDrive ("ledger repo $nonAscii " + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        & git -C $root init --quiet -b develop
        $script:Root = $root
        return $root
    }

    # Exercise the producer's actual path assignments without starting its E2E.
    $releaseAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'scripts/invoke-release-e2e.ps1'), [ref]$null, [ref]$null)
    $pathAssignments = @($releaseAst.FindAll({
        param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left.Extent.Text -in @('$safeRunName', '$preferredReleaseRunRoot', '$legacyReleaseRunRoot')
    }, $false) | Sort-Object { $_.Extent.StartOffset } | ForEach-Object { $_.Extent.Text })
    $pathFunction = $releaseAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Set-E2ERunPaths' }, $false)
    $script:ReleaseProducerPathSetup = ($pathAssignments + @($pathFunction.Extent.Text)) -join "`n"

    function New-ReleaseSnapshotFixture {
        param([string]$Layout = 'preferred', [string]$Snapshot = 'baseline', [string]$RelativePath = '')
        $root = New-LedgerRepository
        & git -C $root config user.name 'ITL Test'; & git -C $root config user.email 'itl-test@example.invalid'
        [IO.File]::WriteAllText((Join-Path $root 'tracked.txt'), 'clean', [Text.UTF8Encoding]::new($false))
        & git -C $root add -- tracked.txt; & git -C $root commit --quiet -m base
        $paths = & {
            param($worktreePath, $Layout)
            $devBranchName = 'workflow-release-e2e'
            . ([scriptblock]::Create($script:ReleaseProducerPathSetup))
            Set-E2ERunPaths -Root $(if ($Layout -eq 'legacy-run') { $legacyReleaseRunRoot } else { $preferredReleaseRunRoot })
            [pscustomobject]@{ baseline = $script:baselineSnapshotPath; postConfig = $script:postConfigSnapshotPath }
        } $root $Layout
        $path = if ($Snapshot -eq 'baseline') { $paths.baseline } else { $paths.postConfig }
        if ($Layout -eq 'legacy-flat') { $path = Join-Path $root '.agent-1c/snapshots/release-e2e-old.dt' }
        if ($RelativePath) { $path = [IO.Path]::GetFullPath((Join-Path $root $RelativePath)) }
        New-Item -ItemType Directory -Path (Split-Path $path) -Force | Out-Null
        [IO.File]::WriteAllText($path, 'owned snapshot', [Text.UTF8Encoding]::new($false))
        $identity = [ordered]@{ path = $path; sha256 = (Get-DeliveryFileSha256 -Path $path); worktreePath = $root }
        $id = Register-DeliveryResource -PlanId 'old-plan' -Kind release-snapshot -Owner release-e2e -Identity $identity -State cleanup-pending
        [pscustomobject]@{ root = $root; path = $path; identity = $identity; resourceId = $id }
    }
}

Describe 'Delivery v3 resource ledger' {
    It 'journals known resources from a failed report before optional artifacts exist' {
        $root=New-LedgerRepository
        $output=Join-Path $root 'build/test-results/local'
        New-Item -ItemType Directory -Path $output -Force | Out-Null
        $reportPath=Join-Path $output 'partial-release.json'
        $report=[ordered]@{status='failed';projectRoot=$root;artifactRetention=[ordered]@{}}
        [IO.File]::WriteAllText($reportPath,($report | ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $output 'check-summary.json'),(@{e2eReportPath=$reportPath} | ConvertTo-Json),[Text.UTF8Encoding]::new($false))
        foreach ($mode in @('Develop','Release')) {
            @(Register-DeliveryGateResources -Plan ([pscustomobject]@{planId='partial'}) -CandidateRoot $root -Mode $mode -Failed).Count | Should -Be 1
        }
        @((Read-DeliveryResourceLedger).resources | Where-Object kind -eq 'reusable-stand').Count | Should -Be 2
        $report.status='passed'
        [IO.File]::WriteAllText($reportPath,($report | ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))
        { Register-DeliveryGateResources -Plan ([pscustomobject]@{planId='partial'}) -CandidateRoot $root -Mode Release } | Should -Throw '*retainedResultArtifact*'
    }

    It 'keeps failed-gate journaling best effort while successful-gate journaling remains mandatory' {
        $root=New-LedgerRepository
        Mock Register-DeliveryGateResourcesCore { throw 'ledger write unavailable' }
        Register-DeliveryGateResources -Plan ([pscustomobject]@{planId='partial'}) -CandidateRoot $root -Mode Release -Failed -WarningAction SilentlyContinue | Should -BeNullOrEmpty
        { Register-DeliveryGateResources -Plan ([pscustomobject]@{planId='partial'}) -CandidateRoot $root -Mode Release } | Should -Throw '*ledger write unavailable*'
    }

    It 'retains only the two newest failed plans and never longer than seven days' {
        New-LedgerRepository | Out-Null
        foreach ($id in 1..3) { Register-DeliveryResource -PlanId "plan-$id" -Kind 'candidate-worktree' -Owner 'delivery' -Identity ([ordered]@{ path=(Join-Path $TestDrive "candidate-$id") }) -State retained | Out-Null }
        $ledger = Read-DeliveryResourceLedger
        for ($index=0; $index -lt 3; $index++) {
            $ledger.resources[$index].updatedAt = [DateTime]::UtcNow.AddHours(-3 + $index).ToString('o')
            $ledger.resources[$index].retainUntil = [DateTime]::UtcNow.AddDays(6).ToString('o')
        }
        $ledger.resources[2].retainUntil = [DateTime]::UtcNow.AddMinutes(-1).ToString('o')
        Write-DeliveryResourceLedger -Ledger $ledger | Out-Null
        Update-DeliveryFailedPlanRetention
        $states = Read-DeliveryResourceLedger
        @($states.resources | Where-Object state -eq 'retained' | Select-Object -ExpandProperty planId) | Should -Be @('plan-2')
        @($states.resources | Where-Object state -eq 'cleanup-pending' | Select-Object -ExpandProperty planId | Sort-Object) | Should -Be @('plan-1','plan-3')
    }

    It 'reads JSON timestamps independently of the current culture' {
        New-LedgerRepository | Out-Null
        Register-DeliveryResource -PlanId 'culture-plan' -Kind 'candidate-worktree' -Owner 'delivery' -Identity ([ordered]@{ path=(Join-Path $TestDrive 'culture-candidate') }) -State retained | Out-Null
        $previousCulture = [Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('ru-RU')
            { Update-DeliveryFailedPlanRetention } | Should -Not -Throw
            { Get-DeliveryResourceLedgerSummary } | Should -Not -Throw
        } finally {
            [Threading.Thread]::CurrentThread.CurrentCulture = $previousCulture
        }
    }

    It 'turns a stale active candidate into retained state and preserves its path' {
        $root = New-LedgerRepository; $active = Join-Path $root 'active-resource'; New-Item -ItemType Directory -Force -Path $active | Out-Null
        Register-DeliveryResource -PlanId 'active-plan' -Kind 'candidate-worktree' -Owner 'delivery' -Identity ([ordered]@{ path=$active }) -State active | Out-Null
        $script:capturedPreserve = @()
        Mock Invoke-SourceDeliveryPostSuccessCleanup { param($FreshProjectsRoot,$E2EProjectRoot,$PreservePaths); $script:capturedPreserve=@($PreservePaths); [pscustomobject]@{status='completed';warnings=@()} }
        Invoke-DeliveryCleanupSweep -FreshProjectsRoot $root | Out-Null
        @($script:capturedPreserve) | Should -Contain $active
        (Read-DeliveryResourceLedger).resources[0].state | Should -Be 'retained'
    }

    It 'turns housekeeping failure into retryable debt and clears it after a successful retry' {
        $root = New-LedgerRepository; $script:returnWarning = $true
        Mock Invoke-SourceDeliveryPostSuccessCleanup { [pscustomobject]@{ status=$(if($script:returnWarning){'completed-with-warnings'}else{'completed'}); warnings=$(if($script:returnWarning){@('fixture cleanup failure')}else{@()}) } }
        $first = Invoke-DeliveryCleanupSweep -FreshProjectsRoot $root -Phase post-operation
        $first.status | Should -Be 'completed-with-warnings'; $first.debt.pending | Should -Be 1; $first.debt.entries[0].lastError | Should -Match 'fixture cleanup failure'
        $script:returnWarning = $false
        $second = Invoke-DeliveryCleanupSweep -FreshProjectsRoot $root -Phase pre-operation
        $second.status | Should -Be 'completed'; $second.debt.pending | Should -Be 0
    }

    It 'removes missing cleanup resources idempotently and reports debt size and next attempt' {
        $root = New-LedgerRepository; $missing = Join-Path $root 'itl-source-publish-develop-00000000000000000000000000000000'
        Register-DeliveryResource -PlanId 'failed-plan' -Kind 'candidate-worktree' -Owner 'delivery' -Identity ([ordered]@{ path=$missing }) -State cleanup-pending | Out-Null
        Mock Invoke-SourceDeliveryPostSuccessCleanup { [pscustomobject]@{status='completed';warnings=@()} }
        Invoke-DeliveryCleanupSweep -FreshProjectsRoot $root | Out-Null; Invoke-DeliveryCleanupSweep -FreshProjectsRoot $root | Out-Null
        $ledger = Read-DeliveryResourceLedger; @($ledger.resources).Count | Should -Be 1; $ledger.resources[0].state | Should -Be 'removed'; [int]$ledger.resources[0].cleanupAttempts | Should -Be 1
        $summary = Get-DeliveryResourceLedgerSummary; $summary.pending | Should -Be 0; $summary.nextAttempt | Should -Match 'PublishDevelop'
    }

    It 'removes only a SHA-matched owned Release snapshot and leaves the reusable worktree' {
        $root = New-LedgerRepository
        & git -C $root config user.name 'ITL Test'; & git -C $root config user.email 'itl-test@example.invalid'
        [IO.File]::WriteAllText((Join-Path $root 'tracked.txt'), 'clean', [Text.UTF8Encoding]::new($false)); & git -C $root add tracked.txt; & git -C $root commit --quiet -m base
        $snapshotRoot = Join-Path $root '.agent-1c\snapshots'; New-Item -ItemType Directory -Force -Path $snapshotRoot | Out-Null
        $snapshot = Join-Path $snapshotRoot 'release-e2e-old.dt'; [IO.File]::WriteAllText($snapshot, 'owned snapshot', [Text.UTF8Encoding]::new($false))
        $identity = [ordered]@{ path=$snapshot; sha256=(Get-DeliveryFileSha256 -Path $snapshot); worktreePath=$root }
        Register-DeliveryResource -PlanId 'expired-plan' -Kind 'release-snapshot' -Owner 'release-e2e' -Identity $identity -State cleanup-pending | Out-Null
        Mock Invoke-SourceDeliveryPostSuccessCleanup { [pscustomobject]@{status='completed';warnings=@()} }
        $result = Invoke-DeliveryCleanupSweep -FreshProjectsRoot $root
        $result.status | Should -Be 'completed'; Test-Path -LiteralPath $snapshot | Should -BeFalse; Test-Path -LiteralPath $root | Should -BeTrue
        (Read-DeliveryResourceLedger).resources[0].state | Should -Be 'removed'
    }
}

Describe 'Release snapshot cleanup ownership and retention' {
    It 'cleans the actual producer <Layout> <Snapshot> path and preserves the worktree' -TestCases @(
        @{ Layout = 'preferred'; Snapshot = 'baseline' }, @{ Layout = 'preferred'; Snapshot = 'post-config' },
        @{ Layout = 'legacy-run'; Snapshot = 'baseline' }, @{ Layout = 'legacy-run'; Snapshot = 'post-config' }
    ) {
        param($Layout, $Snapshot)
        $fixture = New-ReleaseSnapshotFixture -Layout $Layout -Snapshot $Snapshot
        $result = Invoke-DeliveryCleanupSweep -FreshProjectsRoot $fixture.root
        $result.status | Should -Be 'completed'
        Test-Path -LiteralPath $fixture.path | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $fixture.root 'tracked.txt') | Should -BeTrue
        $resource = (Read-DeliveryResourceLedger).resources | Where-Object resourceId -eq $fixture.resourceId
        $resource.state | Should -Be 'removed'
        $again = Invoke-DeliveryCleanupSweep -FreshProjectsRoot $fixture.root
        $again.debt.pending | Should -Be 0
    }

    It 'preserves a pending snapshot while another record has <State> ownership, then cleans it after release' -TestCases @(
        @{ State = 'retained' }, @{ State = 'active' }
    ) {
        param($State)
        $fixture = New-ReleaseSnapshotFixture -Layout legacy-flat
        $newId = Register-DeliveryResource -PlanId 'new-plan' -Kind release-snapshot -Owner release-e2e -Identity $fixture.identity -State $State -RetainUntil ([DateTime]::UtcNow.AddDays(6))
        Invoke-DeliveryCleanupSweep -FreshProjectsRoot $fixture.root | Out-Null
        Test-Path -LiteralPath $fixture.path | Should -BeTrue
        $ledger = Read-DeliveryResourceLedger
        ($ledger.resources | Where-Object resourceId -eq $newId).state | Should -Be $State
        ($ledger.resources | Where-Object resourceId -eq $fixture.resourceId).state | Should -Be 'cleanup-pending'
        Set-DeliveryResourceState -ResourceId $newId -State cleanup-pending | Out-Null
        Invoke-DeliveryCleanupSweep -FreshProjectsRoot $fixture.root | Out-Null
        Test-Path -LiteralPath $fixture.path | Should -BeFalse
    }

    It 'rejects unowned layout <RelativePath>' -TestCases @(
        @{ RelativePath = '../foreign-snapshot.dt' },
        @{ RelativePath = '.agent-1c/runs/release-e2e-other/run/snapshots/baseline.dt' },
        @{ RelativePath = '.agent-1c/runs/release-e2e/run/snapshots/manual-backup.dt' },
        @{ RelativePath = '.agent-1c/runs/release-e2e/run/nested/snapshots/baseline.dt' },
        @{ RelativePath = '.agent-1c/snapshots/unowned.dt' }
    ) {
        param($RelativePath)
        $fixture = New-ReleaseSnapshotFixture -RelativePath $RelativePath
        $result = Invoke-DeliveryCleanupSweep -FreshProjectsRoot $fixture.root
        $result.status | Should -Be 'completed-with-warnings'
        ($result.warnings -join ' ') | Should -Match 'outside the owned Release snapshot root'
        [IO.File]::ReadAllText($fixture.path) | Should -Be 'owned snapshot'
        ((Read-DeliveryResourceLedger).resources | Where-Object resourceId -eq $fixture.resourceId).state | Should -Be 'cleanup-pending'
    }

    It 'preserves <Failure> evidence instead of deleting the snapshot' -TestCases @(
        @{ Failure = 'changed-sha'; Error = 'snapshot SHA differs' },
        @{ Failure = 'dirty-worktree'; Error = 'tracked drift' },
        @{ Failure = 'active-process'; Error = 'active process' }
    ) {
        param($Failure, $Error)
        $fixture = New-ReleaseSnapshotFixture
        if ($Failure -eq 'changed-sha') { [IO.File]::WriteAllText($fixture.path, 'changed snapshot', [Text.UTF8Encoding]::new($false)) }
        if ($Failure -eq 'dirty-worktree') { [IO.File]::WriteAllText((Join-Path $fixture.root 'tracked.txt'), 'dirty', [Text.UTF8Encoding]::new($false)) }
        if ($Failure -eq 'active-process') { Mock Test-SourceDeliveryPathInUse { $true } }
        $result = Invoke-DeliveryCleanupSweep -FreshProjectsRoot $fixture.root
        $result.status | Should -Be 'completed-with-warnings'
        ($result.warnings -join ' ') | Should -Match $Error
        Test-Path -LiteralPath $fixture.path | Should -BeTrue
    }

    It 'does not follow a snapshot-directory junction to a foreign file with the same SHA' {
        $fixture = New-ReleaseSnapshotFixture
        $directory = Split-Path $fixture.path
        $foreign = Join-Path $TestDrive ('foreign target ' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $foreign | Out-Null
        $foreignSnapshot = Join-Path $foreign 'baseline.dt'
        [IO.File]::WriteAllText($foreignSnapshot, 'owned snapshot', [Text.UTF8Encoding]::new($false))
        Remove-Item -LiteralPath $fixture.path -Force
        Remove-Item -LiteralPath $directory -Force
        New-Item -ItemType Junction -Path $directory -Target $foreign | Out-Null
        try {
            $result = Invoke-DeliveryCleanupSweep -FreshProjectsRoot $fixture.root
            $result.status | Should -Be 'completed-with-warnings'
            ($result.warnings -join ' ') | Should -Match 'reparse point'
            [IO.File]::ReadAllText($foreignSnapshot) | Should -Be 'owned snapshot'
        } finally {
            $junction = Get-Item -LiteralPath $directory -Force
            if ($junction.LinkType -eq 'Junction') { $junction.Delete() }
        }
    }

    It 'cleans an expired retained snapshot without requiring a manual ledger rewrite' {
        $fixture = New-ReleaseSnapshotFixture
        $newId = Register-DeliveryResource -PlanId 'expired-retention' -Kind release-snapshot -Owner release-e2e -Identity $fixture.identity -State retained -RetainUntil ([DateTime]::UtcNow.AddMinutes(-1))
        $result = Invoke-DeliveryCleanupSweep -FreshProjectsRoot $fixture.root
        $result.status | Should -Be 'completed'
        Test-Path -LiteralPath $fixture.path | Should -BeFalse
        ((Read-DeliveryResourceLedger).resources | Where-Object resourceId -eq $newId).state | Should -Be 'removed'
    }

    It 'retires obsolete records for a reused filename in the same sweep after the matching owner removes it' {
        $fixture = New-ReleaseSnapshotFixture
        [IO.File]::WriteAllText($fixture.path, 'new snapshot generation', [Text.UTF8Encoding]::new($false))
        $newIdentity = [ordered]@{ path = $fixture.path; sha256 = (Get-DeliveryFileSha256 -Path $fixture.path); worktreePath = $fixture.root }
        Register-DeliveryResource -PlanId 'new-plan' -Kind release-snapshot -Owner release-e2e -Identity $newIdentity -State cleanup-pending | Out-Null
        $result = Invoke-DeliveryCleanupSweep -FreshProjectsRoot $fixture.root
        $result.status | Should -Be 'completed'
        $result.debt.pending | Should -Be 0
        Test-Path -LiteralPath $fixture.path | Should -BeFalse
        @((Read-DeliveryResourceLedger).resources | Where-Object { $_.kind -eq 'release-snapshot' -and $_.state -eq 'removed' }).Count | Should -Be 2
    }
}
