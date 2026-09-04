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
}

Describe 'Delivery v3 resource ledger' {
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
