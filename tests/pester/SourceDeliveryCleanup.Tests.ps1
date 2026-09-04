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

    It 'preserves active and tracked-dirty generated candidate worktrees' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('itl cleanup protected repo ' + [guid]::NewGuid().ToString('N'))
        $activeId = [guid]::NewGuid().ToString('N'); $dirtyId = [guid]::NewGuid().ToString('N')
        $active = Join-Path ([IO.Path]::GetTempPath()) "itl-source-publish-develop-$activeId"; $dirty = Join-Path ([IO.Path]::GetTempPath()) "itl-source-publish-develop-$dirtyId"
        try {
            New-CleanupRepository -Root $root
            & git -C $root worktree add --quiet -b "itl/publish-develop-$activeId" $active
            & git -C $root worktree add --quiet -b "itl/publish-develop-$dirtyId" $dirty
            Set-Content -LiteralPath (Join-Path $dirty 'README.md') -Encoding ASCII -Value 'tracked drift'
            $script:Root = $root
            function Invoke-DeliveryGit { param([string[]]$Arguments, [switch]$AllowFailure); Invoke-RepositoryGit -RepositoryRoot $script:Root -Arguments $Arguments -AllowFailure:$AllowFailure }
            . (Join-Path $RepoRoot 'scripts\source-delivery-cleanup.ps1')
            $result = Remove-SourceDeliveryStaleCandidateWorktrees -PreservePaths @($active)
            $result.removedWorktrees | Should -Be 0; Test-Path -LiteralPath $active | Should -BeTrue; Test-Path -LiteralPath $dirty | Should -BeTrue
        } finally {
            if (Test-Path -LiteralPath $root) { & git -C $root worktree remove --force $active 2>$null; & git -C $root worktree remove --force $dirty 2>$null; Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
            Remove-Item -LiteralPath $active, $dirty -Recurse -Force -ErrorAction SilentlyContinue
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

    It 'removes only inactive exact source-delivery test fixtures and their candidates' {
        $fixturePrefix = 'itl delivery ' + [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('0L/Rg9GC0Yw=')) + ' '; $container = Join-Path $TestDrive 'temp'; $id = [guid]::NewGuid().ToString('N'); $root = Join-Path $container ($fixturePrefix + $id); $remote = Join-Path $container ('itl-delivery-remote-' + [guid]::NewGuid().ToString('N') + '.git'); $candidateId = [guid]::NewGuid().ToString('N'); $candidate = Join-Path $container "itl-source-publish-develop-$candidateId"; $parallel = Join-Path $container ('itl parallel worktree ' + [guid]::NewGuid().ToString('N')); $keep = Join-Path $container ($fixturePrefix + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $container | Out-Null; New-CleanupRepository -Root $root; Set-Content (Join-Path $root 'README.md') 'base'; Set-Content (Join-Path $root 'fake-gate.ps1') 'exit 0'; & git -C $root add --all; & git -C $root commit --quiet -m fixture-shape
        & git init --quiet --bare $remote; & git -C $root remote add origin $remote; & git -C $root worktree add --quiet -b "itl/publish-develop-$candidateId" $candidate; & git -C $root worktree add --quiet -b topic-two $parallel
        New-Item -ItemType Directory -Force -Path $keep | Out-Null
        . (Join-Path $RepoRoot 'scripts\source-delivery-cleanup.ps1')
        $result = Remove-SourceDeliveryStaleTestFixtures -TempRoot $container
        $result.removedFixtures | Should -Be 1; $result.removedWorktrees | Should -Be 2; Test-Path $root | Should -BeFalse; Test-Path $candidate | Should -BeFalse; Test-Path $parallel | Should -BeFalse; Test-Path $remote | Should -BeFalse; Test-Path $keep | Should -BeTrue
    }

    It 'removes only closed exact release-seed archives' {
        $root = Join-Path $TestDrive 'e2e'; New-CleanupRepository -Root $root; $archiveRoot = Join-Path $root '.agent-1c\branch-archives'; $stale = Join-Path $archiveRoot 'release-seed-a-1234abcd\generation'; $active = Join-Path $archiveRoot 'release-seed-b-1234abcd\generation'; New-Item -ItemType Directory -Force -Path $stale, $active, (Join-Path $root '.agent-1c\dev-branches\release-seed-b-1234abcd') | Out-Null; Set-Content (Join-Path $stale 'infobase.dt') 'stale'; Set-Content (Join-Path $active 'infobase.dt') 'active'
        . (Join-Path $RepoRoot 'scripts\source-delivery-cleanup.ps1')
        $result = Remove-SourceDeliveryStaleReleaseSeedArchives -ProjectRoot $root
        $result.removedArchives | Should -Be 1; $result.freedBytes | Should -BeGreaterThan 0; Test-Path (Split-Path -Parent $stale) | Should -BeFalse; Test-Path (Split-Path -Parent $active) | Should -BeTrue
    }

    It 'retains three managed launcher backups across legacy and current names' {
        $list = Join-Path $TestDrive 'ibases.v8i'; Set-Content $list '[base]'; foreach ($name in @('20260827-010101','20260827-010102','20260827-010103-100','20260827-010104-200')) { Set-Content "$list.$name.bak" $name }; Set-Content "$list.manual.bak" 'manual'
        . (Join-Path $RepoRoot 'scripts\develop-e2e-cleanup.ps1')
        $result = Remove-DevelopE2ELauncherListBackups -ListPath $list
        $result.retained | Should -Be 3; $result.removed | Should -Be 1; @(Get-ChildItem $TestDrive -File -Filter 'ibases.v8i.*.bak').Count | Should -Be 4; Test-Path "$list.manual.bak" | Should -BeTrue
    }

    It 'reports cleanup failures as warnings instead of changing publication success' {
        . (Join-Path $RepoRoot 'scripts\source-delivery-cleanup.ps1')
        Mock Remove-SourceDeliveryStaleCandidateWorktrees { throw 'candidate cleanup unavailable' }
        Mock Remove-SourceDeliveryStaleTestFixtures { [pscustomobject]@{ removedFixtures=0; removedWorktrees=0 } }
        Mock Remove-DevelopE2EStaleFreshProjects { [pscustomobject]@{ removedProjects=0 } }
        Mock Remove-DevelopE2EStaleLauncherRegistrations { 0 }
        Mock Remove-ReleaseE2EStaleLauncherRegistrations { 0 }
        Mock Remove-DevelopE2ELauncherListBackups { [pscustomobject]@{ retained=1; removed=0 } }
        Mock Get-DevelopE2ELauncherListPath { Join-Path $TestDrive 'ibases.v8i' }
        $result = Invoke-SourceDeliveryPostSuccessCleanup -FreshProjectsRoot $TestDrive
        $result.status | Should -Be 'completed-with-warnings'; @($result.warnings).Count | Should -Be 1; $result.warnings[0] | Should -Match 'candidate cleanup unavailable'
    }
}
