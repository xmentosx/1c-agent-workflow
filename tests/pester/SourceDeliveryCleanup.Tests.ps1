BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSupport.ps1')
    $context = Initialize-WorkflowPesterContext
    $RepoRoot = $context.RepoRoot
    . (Join-Path $RepoRoot 'scripts\git-path-list.ps1')

    function New-CleanupRepository {
        param([string]$Root)
        New-Item -ItemType Directory -Force -Path $Root | Out-Null
        & git -C $Root init --quiet -b develop
        & git -C $Root config user.name 'ITL Test'
        & git -C $Root config user.email 'itl-test@example.invalid'
        Set-Content -LiteralPath (Join-Path $Root 'README.md') -Encoding ASCII -Value 'fixture'
        & git -C $Root add README.md; & git -C $Root commit --quiet -m fixture
    }
}

Describe 'Source delivery post-success cleanup' {
    It 'removes only exact generated delivery candidate worktrees' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('itl cleanup repo ' + [guid]::NewGuid().ToString('N'))
        $id = [guid]::NewGuid().ToString('N'); $candidate = Join-Path ([IO.Path]::GetTempPath()) "itl-source-publish-develop-$id"; $keep = Join-Path ([IO.Path]::GetTempPath()) ('user-worktree-' + [guid]::NewGuid().ToString('N'))
        try {
            New-CleanupRepository -Root $root
            & git -C $root worktree add --quiet -b "itl/publish-develop-$id" $candidate
            & git -C $root worktree add --quiet -b user/keep $keep
            $script:Root = $root
            function Invoke-DeliveryGit { param([string[]]$Arguments, [switch]$AllowFailure); Invoke-RepositoryGit -RepositoryRoot $script:Root -Arguments $Arguments -AllowFailure:$AllowFailure }
            . (Join-Path $RepoRoot 'scripts\source-delivery-cleanup.ps1')
            $result = Remove-SourceDeliveryStaleCandidateWorktrees
            $result.removedWorktrees | Should -Be 1; Test-Path -LiteralPath $candidate | Should -BeFalse; Test-Path -LiteralPath $keep | Should -BeTrue
        } finally {
            if (Test-Path -LiteralPath $root) { & git -C $root worktree remove --force $keep 2>$null; Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
            Remove-Item -LiteralPath $candidate, $keep -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'removes only an exact generated release seed under the explicit seed root' {
        $container = Join-Path ([IO.Path]::GetTempPath()) ('itl seed root ' + [guid]::NewGuid().ToString('N')); $root = Join-Path $container 'main'; $id = '1234abcd'; $seed = Join-Path $container "itlsa-$id"; $keep = Join-Path $container 'itlsa-not-a-seed'
        try {
            New-CleanupRepository -Root $root
            & git -C $root worktree add --quiet -b "itldev/release-seed-a-$id" $seed
            & git -C $root worktree add --quiet -b user/keep $keep
            . (Join-Path $RepoRoot 'scripts\source-delivery-cleanup.ps1')
            $result = Remove-SourceDeliveryStaleReleaseSeeds -ProjectRoot $root -SeedRoot $container
            $result.removedWorktrees | Should -Be 1; Test-Path -LiteralPath $seed | Should -BeFalse; Test-Path -LiteralPath $keep | Should -BeTrue
        } finally {
            if (Test-Path -LiteralPath $root) { & git -C $root worktree remove --force $keep 2>$null }
            Remove-Item -LiteralPath $container -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'reports cleanup failures as warnings instead of changing publication success' {
        . (Join-Path $RepoRoot 'scripts\source-delivery-cleanup.ps1')
        Mock Remove-SourceDeliveryStaleCandidateWorktrees { throw 'candidate cleanup unavailable' }
        Mock Remove-DevelopE2EStaleFreshProjects { [pscustomobject]@{ removedProjects=0 } }
        Mock Remove-DevelopE2EStaleLauncherRegistrations { 0 }
        Mock Remove-ReleaseE2EStaleLauncherRegistrations { 0 }
        Mock Remove-DevelopE2ELauncherListBackups { [pscustomobject]@{ retained=1; removed=0 } }
        Mock Get-DevelopE2ELauncherListPath { Join-Path $TestDrive 'ibases.v8i' }
        $result = Invoke-SourceDeliveryPostSuccessCleanup -FreshProjectsRoot $TestDrive
        $result.status | Should -Be 'completed-with-warnings'; @($result.warnings).Count | Should -Be 1; $result.warnings[0] | Should -Match 'candidate cleanup unavailable'
    }
}
