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

    It 'removes expired non-Git Vanessa build work under a whitespace and non-ASCII root' {
        $root = Join-Path $TestDrive ("build with space-{0}" -f [char]0x0416); $owned = Join-Path $root 'deadbeef'; $git = Join-Path $root '1234abcd'; $unknown = Join-Path $root 'source-copy'
        New-Item -ItemType Directory -Force -Path $owned | Out-Null; Set-Content -LiteralPath (Join-Path $owned 'result.bin') -Value 'owned'
        New-CleanupRepository -Root $git
        New-Item -ItemType Directory -Force -Path $unknown | Out-Null
        . (Join-Path $RepoRoot 'scripts\source-delivery-cleanup.ps1')

        $result = Remove-SourceDeliveryStaleVanessaBuildWork -WorkRoot $root -MinimumAgeHours 0

        $result.removedDirectories | Should -Be 1; $result.freedBytes | Should -BeGreaterThan 0
        Test-Path -LiteralPath $owned | Should -BeFalse; Test-Path -LiteralPath $git | Should -BeTrue; Test-Path -LiteralPath $unknown | Should -BeTrue
    }

    It 'removes only exact release quarantine and disposable preserved evidence' {
        $temp = Join-Path $TestDrive ("temporary data with space-{0}" -f [char]0x0416)
        $quarantine = Join-Path $temp 'itl-quarantine\workflow-release-e2e-snapshots-20260912'
        $near = Join-Path $temp 'itl-quarantine\manual-snapshots'
        $preserved = Join-Path $temp 'itl-release-e2e-preserved-20260911-171249'
        $agent = Join-Path $preserved '.agent-1c'
        $build = Join-Path $preserved 'build'
        $relocated = Join-Path $preserved 'relocated-main'
        foreach ($directory in @($quarantine, $near, $agent, $build, $relocated)) {
            New-Item -ItemType Directory -Force -Path $directory | Out-Null
        }
        Set-Content -LiteralPath (Join-Path $quarantine 'release-e2e-extension-run.dt') -Value 'snapshot'; Set-Content -LiteralPath (Join-Path $quarantine 'release-e2e-extension-run.dt.state.json') -Value '{}'
        Set-Content -LiteralPath (Join-Path $near 'release-e2e-extension-run.dt') -Value 'keep'; Set-Content -LiteralPath (Join-Path $agent 'old.bin') -Value 'agent'; Set-Content -LiteralPath (Join-Path $build 'old.bin') -Value 'build'; Set-Content -LiteralPath (Join-Path $relocated 'live.bin') -Value 'live'
        [IO.File]::WriteAllText((Join-Path $preserved 'manifest.json'), (@{ moved = @(@{ junction = $true; destination = (Join-Path $relocated 'live') }) } | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
        . (Join-Path $RepoRoot 'scripts\source-delivery-cleanup.ps1')

        $result = Remove-SourceDeliveryStaleReleaseRecoveryArtifacts -TempRoot $temp -MinimumAgeHours 0

        $result.removedDirectories | Should -Be 3; Test-Path -LiteralPath $quarantine | Should -BeFalse
        Test-Path -LiteralPath $agent | Should -BeFalse; Test-Path -LiteralPath $build | Should -BeFalse
        Test-Path -LiteralPath $near | Should -BeTrue; Test-Path -LiteralPath $relocated | Should -BeTrue
    }

    It 'keeps the newest passed and every failed ai-rules migration snapshot' {
        $root = Join-Path $TestDrive ("migration project with space-{0}" -f [char]0x0416); New-CleanupRepository -Root $root; $runs = Join-Path $root '.agent-1c\runs'
        $names = @('ai-rules-migration-20260901-010101-001', 'ai-rules-migration-20260902-010101-001', 'ai-rules-migration-20260903-010101-001')
        foreach ($name in $names) { $path = Join-Path $runs $name; New-Item -ItemType Directory -Force -Path $path | Out-Null; Set-Content -LiteralPath (Join-Path $path 'migration-report.json') -Value '{"status":"passed"}' }
        $failed = Join-Path $runs 'ai-rules-migration-20260831-010101-001'; New-Item -ItemType Directory -Force -Path $failed | Out-Null; Set-Content -LiteralPath (Join-Path $failed 'migration-report.json') -Value '{"status":"failed"}'
        for ($index = 0; $index -lt $names.Count; $index++) { (Get-Item -LiteralPath (Join-Path $runs $names[$index])).LastWriteTimeUtc = [DateTime]::UtcNow.AddHours(-10 + $index) }
        . (Join-Path $RepoRoot 'scripts\source-delivery-cleanup.ps1')

        $result = Remove-SourceDeliveryOldAiRulesMigrationSnapshots -ProjectRoot $root -MinimumAgeHours 0 -Keep 1

        $result.removedDirectories | Should -Be 2; Test-Path -LiteralPath (Join-Path $runs $names[2]) | Should -BeTrue; Test-Path -LiteralPath $failed | Should -BeTrue
    }

    It 'removes only build output from an exact expired artifact hold' {
        $root = Join-Path $TestDrive ("storage with space-{0}" -f [char]0x0416)
        $hold = Join-Path $root 'PM5-corp-branch-artifact-hold-20260821-1815'
        $build = Join-Path $hold 'build'
        $testResults = Join-Path $build 'test-results'
        $handoffs = Join-Path $hold 'handoffs'
        foreach ($directory in @($testResults, $handoffs)) {
            New-Item -ItemType Directory -Force -Path $directory | Out-Null
        }
        Set-Content -LiteralPath (Join-Path $testResults 'result.xml') -Value '<testsuite />'
        Set-Content -LiteralPath (Join-Path $handoffs 'keep.md') -Value 'keep'
        . (Join-Path $RepoRoot 'scripts\source-delivery-cleanup.ps1')

        $result = Remove-SourceDeliveryExpiredArtifactHolds -SearchRoot $root -MinimumAgeHours 0

        $result.removedDirectories | Should -Be 1; Test-Path -LiteralPath $build | Should -BeFalse; Test-Path -LiteralPath $handoffs | Should -BeTrue
    }

    It 'retains three managed launcher backups across legacy and current names' {
        $list = Join-Path $TestDrive 'ibases.v8i'; Set-Content $list '[base]'; foreach ($name in @('20260827-010101','20260827-010102','20260827-010103-100','20260827-010104-200')) { Set-Content "$list.$name.bak" $name }; Set-Content "$list.manual.bak" 'manual'
        . (Join-Path $RepoRoot 'scripts\develop-e2e-cleanup.ps1')
        $result = Remove-DevelopE2ELauncherListBackups -ListPath $list
        $result.retained | Should -Be 3; $result.removed | Should -Be 1; @(Get-ChildItem $TestDrive -File -Filter 'ibases.v8i.*.bak').Count | Should -Be 4; Test-Path "$list.manual.bak" | Should -BeTrue
    }

    It 'restores only tracked changes from a failed Develop E2E run that started clean' {
        $root = Join-Path $TestDrive 'develop tracked cleanup'
        New-CleanupRepository -Root $root
        . (Join-Path $RepoRoot 'scripts\develop-e2e-cleanup.ps1')
        $startHead = ((& git -C $root rev-parse HEAD) -join '').Trim()
        Set-Content -LiteralPath (Join-Path $root 'README.md') -Encoding ASCII -Value 'failed update'
        & git -C $root add README.md
        Set-Content -LiteralPath (Join-Path $root 'new-runtime.log') -Encoding ASCII -Value 'keep untracked evidence'

        $result = Restore-DevelopE2ETrackedState -Root $root -StartHead $startHead -ExpectedBranch 'develop'

        $result.status | Should -Be 'restored'
        (& git -C $root status --porcelain --untracked-files=no) | Should -BeNullOrEmpty
        (Get-Content -LiteralPath (Join-Path $root 'README.md') -Raw).Trim() | Should -Be 'fixture'
        Test-Path -LiteralPath (Join-Path $root 'new-runtime.log') | Should -BeTrue
    }

    It 'wires failed Develop cleanup to both the master and isolated branch worktrees' {
        $implementation = Get-Content -LiteralPath (Join-Path $RepoRoot 'scripts\invoke-develop-e2e.ps1') -Raw -Encoding UTF8
        $implementation | Should -Match ([regex]::Escape('Restore-DevelopE2ETrackedState -Root $ProjectRoot'))
        $implementation | Should -Match ([regex]::Escape('Restore-DevelopE2ETrackedState -Root $standBranchRoot'))
        $implementation | Should -Match ([regex]::Escape('upgrade-refresh-branch-current'))
        $implementation | Should -Match ([regex]::Escape('-ExpectedMasterCommit'))
    }

    It 'reports cleanup failures as warnings instead of changing publication success' {
        . (Join-Path $RepoRoot 'scripts\source-delivery-cleanup.ps1')
        Mock Remove-SourceDeliveryStaleCandidateWorktrees { throw 'candidate cleanup unavailable' }
        Mock Remove-SourceDeliveryStaleTestFixtures { [pscustomobject]@{ removedFixtures=0; removedWorktrees=0 } }
        Mock Remove-SourceDeliveryStaleVanessaBuildWork { [pscustomobject]@{ removedDirectories=0; retained=0; freedBytes=0 } }
        Mock Remove-SourceDeliveryStaleReleaseRecoveryArtifacts { [pscustomobject]@{ removedDirectories=0; retained=0; freedBytes=0 } }
        Mock Remove-DevelopE2EStaleFreshProjects { [pscustomobject]@{ removedProjects=0 } }
        Mock Remove-DevelopE2EStaleLauncherRegistrations { 0 }
        Mock Remove-ReleaseE2EStaleLauncherRegistrations { 0 }
        Mock Remove-DevelopE2ELauncherListBackups { [pscustomobject]@{ retained=1; removed=0 } }
        Mock Get-DevelopE2ELauncherListPath { Join-Path $TestDrive 'ibases.v8i' }
        $result = Invoke-SourceDeliveryPostSuccessCleanup -FreshProjectsRoot $TestDrive
        $result.status | Should -Be 'completed-with-warnings'; @($result.warnings).Count | Should -Be 1; $result.warnings[0] | Should -Match 'candidate cleanup unavailable'
    }
}
