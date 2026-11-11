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
    It 'preserves Git metadata and launcher bytes with locked <LockedRelativePath>, then completes cleanup after release' -TestCases @(
        @{ LockedRelativePath='1Cv8.1CD' },
        @{ LockedRelativePath='1Cv8Log/1Cv8.lgf' }
    ) {
        param([string]$LockedRelativePath)
        . (Join-Path $RepoRoot 'scripts/develop-e2e-cleanup.ps1')
        $root = Join-Path $TestDrive ('fresh cleanup ' + [char]0x0416)
        $main = Join-Path $root 'd-a1b2c3d4'; $branch = "$main-develop-golden"
        New-CleanupRepository -Root $main
        & git -C $main worktree add --quiet -b itldev/develop-golden $branch
        $databaseRoot = Join-Path $branch '.agent-1c/infobases/dev-branches/develop-golden'
        New-Item -ItemType Directory -Force -Path $databaseRoot | Out-Null
        $database = Join-Path $databaseRoot '1Cv8.1CD'
        [IO.File]::WriteAllText($database, 'diagnostic database placeholder')
        $launcher = Join-Path $root 'ibases.v8i'
        [IO.File]::WriteAllText($launcher, '[preserve launcher bytes]', [Text.UTF8Encoding]::new($false))
        $launcherHash = (Get-FileHash -LiteralPath $launcher).Hash
        $pointer = [IO.File]::ReadAllText((Join-Path $branch '.git'), [Text.Encoding]::UTF8)
        $lockedFile = Join-Path $databaseRoot $LockedRelativePath
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $lockedFile) | Out-Null
        if (-not (Test-Path -LiteralPath $lockedFile)) { [IO.File]::WriteAllText($lockedFile, 'diagnostic journal placeholder') }
        $held = [IO.File]::Open($lockedFile, 'Open', 'ReadWrite', 'None')
        try {
            { Remove-DevelopE2EStaleFreshProjects -FreshProjectsRoot $root -LauncherListPath $launcher } | Should -Throw '*FRESH_JOURNEY_IN_USE*'
            (& git -C $branch rev-parse --show-toplevel).Replace('/', '\') | Should -Be $branch
            $LASTEXITCODE | Should -Be 0
            [IO.File]::ReadAllText((Join-Path $branch '.git'), [Text.Encoding]::UTF8) | Should -BeExactly $pointer
            (Get-FileHash -LiteralPath $launcher).Hash | Should -Be $launcherHash
        } finally { $held.Dispose() }
        $result = Remove-DevelopE2EStaleFreshProjects -FreshProjectsRoot $root -LauncherListPath $launcher
        $result.removedProjects | Should -Be 1
        Test-Path -LiteralPath $main | Should -BeFalse
        Test-Path -LiteralPath $branch | Should -BeFalse
    }

    It 'protects a fresh worktree between lifecycle commands with its native Git lock and releases only its own lock' {
        . (Join-Path $RepoRoot 'scripts/develop-e2e-cleanup.ps1')
        $root = Join-Path $TestDrive 'fresh owner'; $main = Join-Path $root 'd-1234abcd'; $branch = "$main-develop-golden"
        New-CleanupRepository -Root $main
        & git -C $main worktree add --quiet -b itldev/develop-golden $branch
        $launcher = Join-Path $root 'ibases.v8i'
        [IO.File]::WriteAllText($launcher, '[preserve launcher bytes]')
        $lease = Lock-DevelopE2EFreshWorktree -ProjectRoot $main -BranchPath $branch
        try {
            # The previously published cleanup uses one --force. Native Git must
            # preserve the worktree even before that executor gains the guard.
            $legacyRemove = Invoke-RepositoryGit -RepositoryRoot $main -Arguments @('worktree','remove','--force','--',$branch) -AllowFailure
            $legacyRemove.exitCode | Should -Not -Be 0
            { Remove-DevelopE2EStaleFreshProjects -FreshProjectsRoot $root -LauncherListPath $launcher } | Should -Throw '*FRESH_JOURNEY_IN_USE*'
            (& git -C $branch rev-parse --show-toplevel).Replace('/', '\') | Should -Be $branch
            $LASTEXITCODE | Should -Be 0
            [IO.File]::ReadAllText($launcher) | Should -BeExactly '[preserve launcher bytes]'
            $foreign = [pscustomobject]@{projectRoot=$main;branchPath=$branch;reason='another owner'}
            { Unlock-DevelopE2EFreshWorktree -Lease $foreign } | Should -Throw '*ownership changed*'
            @(Get-DevelopE2ERegisteredWorktrees -ProjectRoot $main | Where-Object { $_.locked }).Count | Should -Be 1
        } finally { Unlock-DevelopE2EFreshWorktree -Lease $lease }
        (Remove-DevelopE2EStaleFreshProjects -FreshProjectsRoot $root -LauncherListPath $launcher).removedProjects | Should -Be 1
        Unlock-DevelopE2EFreshWorktree -Lease $lease # Owning close/cleanup may already have removed the project.
    }

    It 'removes a fresh project interrupted before Git initialization without querying a missing repository' {
        . (Join-Path $RepoRoot 'scripts/develop-e2e-cleanup.ps1')
        $root = Join-Path $TestDrive ('p ' + [string]::new([char[]]@(0x041f,0x0440,0x043e,0x0435,0x043a,0x0442)))
        $main = Join-Path $root 'd-6209d141'
        New-Item -ItemType Directory -Force -Path (Join-Path $main '.agent-1c') | Out-Null
        [IO.File]::WriteAllText((Join-Path $main 'AGENT-INSTALL.md'), 'bootstrap copy before git init')
        $launcher = Join-Path $root 'ibases.v8i'
        [IO.File]::WriteAllText($launcher, '[preserve launcher bytes]')
        $result = Remove-DevelopE2EStaleFreshProjects -FreshProjectsRoot $root -LauncherListPath $launcher
        $result.removedProjects | Should -Be 1
        Test-Path -LiteralPath $main | Should -BeFalse
        [IO.File]::ReadAllText($launcher) | Should -BeExactly '[preserve launcher bytes]'
    }

    It 'holds fresh protection from branch creation through the complete original journey and releases it in the terminal path' {
        $text = Get-Content -LiteralPath (Join-Path $RepoRoot 'scripts/invoke-develop-e2e.ps1') -Raw -Encoding UTF8
        $text.IndexOf('Lock-DevelopE2EFreshWorktree -ProjectRoot $freshRoot') | Should -BeGreaterThan $text.IndexOf('Name "create-dev-branch"')
        $text.IndexOf('Lock-DevelopE2EFreshWorktree -ProjectRoot $freshRoot') | Should -BeLessThan $text.IndexOf('Name "missing-suite-recovery"')
        $text | Should -Match '(?s)fresh-close.*?Unlock-DevelopE2EFreshWorktree.*?Remove-DevelopE2EFreshProject'
        $text | Should -Match '(?s)finally \{.*?Write-QualificationFixtureJson -Path \$OutputPath -Value \$payload\s+try \{ Unlock-DevelopE2EFreshWorktree'
    }

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

    It 'keeps the newest two unexpired registrations and removes idle supervisors this repository or no repository owns' {
        $container = Join-Path ([IO.Path]::GetTempPath()) ('itl cleanup registrations ' + [char]0x041F + ' ' + [guid]::NewGuid().ToString('N'))
        $temp = Join-Path $container 'temp root'; $root = Join-Path $container 'main repo'; $other = Join-Path $container 'other clone'
        $ids = @{}; foreach ($name in @('expired', 'fresh', 'fresh2', 'fresh3', 'foreign', 'orphan', 'otherClone', 'repository', 'supervisor', 'recentSupervisor', 'branchedSupervisor')) { $ids[$name] = [guid]::NewGuid().ToString('N') }
        $path = @{}; foreach ($name in $ids.Keys) { $path[$name] = Join-Path $temp "itl-source-$(if ($name -like '*upervisor') { 'supervisor' } else { 'register' })-$($ids[$name])" }
        try {
            [void][IO.Directory]::CreateDirectory($temp)
            New-CleanupRepository -Root $root
            New-CleanupRepository -Root $other
            & git -C $root worktree add --quiet -b "itl/register-$($ids.expired)" $path.expired
            & git -C $root worktree add --quiet -b "itl/register-$($ids.fresh)" $path.fresh
            & git -C $root worktree add --quiet -b "itl/register-$($ids.fresh2)" $path.fresh2
            & git -C $root worktree add --quiet -b "itl/register-$($ids.fresh3)" $path.fresh3
            & git -C $root worktree add --quiet -b "user/register-$($ids.foreign)" $path.foreign
            & git -C $other worktree add --quiet -b "itl/register-$($ids.otherClone)" $path.otherClone
            & git -C $root worktree add --quiet --detach $path.supervisor
            & git -C $root worktree add --quiet --detach $path.recentSupervisor
            & git -C $root worktree add --quiet -b "itl/supervisor-$($ids.branchedSupervisor)" $path.branchedSupervisor
            [void][IO.Directory]::CreateDirectory((Join-Path $path.orphan 'build'))
            Set-Content -LiteralPath (Join-Path $path.orphan '.git') -Encoding ASCII -Value ('gitdir: ' + (Join-Path $root '.git\worktrees\gone'))
            [void][IO.Directory]::CreateDirectory((Join-Path $path.repository '.git'))
            $old = [DateTime]::UtcNow.AddDays(-8)
            foreach ($name in @('expired', 'foreign', 'orphan', 'otherClone', 'repository', 'supervisor', 'branchedSupervisor')) { (Get-Item -LiteralPath $path[$name]).LastWriteTimeUtc = $old }
            (Get-Item -LiteralPath $path.fresh2).LastWriteTimeUtc = [DateTime]::UtcNow.AddHours(-1)
            (Get-Item -LiteralPath $path.fresh3).LastWriteTimeUtc = [DateTime]::UtcNow.AddHours(-2)
            $script:Root = $root
            function Invoke-DeliveryGit { param([string[]]$Arguments, [switch]$AllowFailure); Invoke-RepositoryGit -RepositoryRoot $script:Root -Arguments $Arguments -AllowFailure:$AllowFailure }
            . (Join-Path $RepoRoot 'scripts\source-delivery-cleanup.ps1')
            $result = Remove-SourceDeliveryStaleOperationWorktrees -TempRoot $temp -MinimumAgeHours 168
            @($result.entries | ForEach-Object path | Sort-Object) | Should -Be @(@($path.expired, $path.orphan, $path.supervisor, $path.fresh3) | Sort-Object)
            $result.retained | Should -Be 7
            foreach ($name in @('fresh', 'fresh2', 'foreign', 'otherClone', 'repository', 'recentSupervisor', 'branchedSupervisor')) { Test-Path -LiteralPath $path[$name] | Should -BeTrue -Because $name }
            @(& git -C $root branch --list "itl/register-$($ids.expired)").Count | Should -Be 0
            @(& git -C $root branch --list "itl/register-$($ids.fresh)").Count | Should -Be 1
            @(& git -C $root worktree list --porcelain | Where-Object { $_ -like "worktree *$($ids.expired)" }).Count | Should -Be 0
        } finally {
            foreach ($repo in @($root, $other)) { if (Test-Path -LiteralPath $repo) { foreach ($name in $path.Keys) { & git -C $repo worktree remove --force $path[$name] 2>$null } } }
            Remove-Item -LiteralPath $container -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'keeps the supervisor copy of a publication waiting for the delivery lock past the idle window and releases it when the owner exits' {
        # Reproduces 2026-11-10: a PublishDevelop waited ~98 minutes for the
        # lock and runs its pinned supervisor in-process, so no command line
        # names the copy; the owner's post-success cleanup deleted it and the
        # waiter failed on scripts\new-gate-stand.ps1 after the lock was free.
        $container = Join-Path ([IO.Path]::GetTempPath()) ('itl cleanup supervisor lease ' + [char]0x041F + ' ' + [guid]::NewGuid().ToString('N'))
        $temp = Join-Path $container ('temp root ' + [char]0x0416); $root = Join-Path $container ('main repo ' + [char]0x0416)
        $waiting = Join-Path $temp ('itl-source-supervisor-' + [guid]::NewGuid().ToString('N'))
        $reused = Join-Path $temp ('itl-source-supervisor-' + [guid]::NewGuid().ToString('N'))
        $waiter = $null
        try {
            [void][IO.Directory]::CreateDirectory($temp)
            New-CleanupRepository -Root $root
            New-Item -ItemType Directory -Force -Path (Join-Path $root 'scripts') | Out-Null
            Set-Content -LiteralPath (Join-Path $root 'scripts\new-gate-stand.ps1') -Encoding ASCII -Value 'exit 0'
            & git -C $root add --all; & git -C $root commit --quiet -m supervisor-shape
            foreach ($copy in @($waiting, $reused)) { & git -C $root worktree add --quiet --detach $copy }
            $script:Root = $root
            function Invoke-DeliveryGit { param([string[]]$Arguments, [switch]$AllowFailure); Invoke-RepositoryGit -RepositoryRoot $script:Root -Arguments $Arguments -AllowFailure:$AllowFailure }
            . (Join-Path $RepoRoot 'scripts\source-delivery-cleanup.ps1')
            $waiter = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 300') -WindowStyle Hidden -PassThru
            Write-SourceDeliverySupervisorLease -SupervisorRoot $waiting -ProcessId $waiter.Id | Should -BeTrue
            Write-SourceDeliverySupervisorLease -SupervisorRoot $reused -ProcessId $waiter.Id | Should -BeTrue
            # The reused copy's recorded owner started earlier: its PID now names another process.
            $reusedLease = Get-SourceDeliverySupervisorLeasePath -SupervisorRoot $reused
            $lease = Get-Content -LiteralPath $reusedLease -Raw -Encoding UTF8 | ConvertFrom-Json
            $lease.ownerProcessStartedAt = $waiter.StartTime.ToUniversalTime().AddHours(-3).ToString('o')
            [IO.File]::WriteAllText($reusedLease, ($lease | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
            (Get-Content -LiteralPath (Get-SourceDeliverySupervisorLeasePath -SupervisorRoot $waiting) -Raw -Encoding UTF8 | ConvertFrom-Json).supervisorRoot | Should -Be $waiting
            Test-SourceDeliveryPathInUse -Path $waiting | Should -BeFalse
            foreach ($copy in @($waiting, $reused)) { (Get-Item -LiteralPath $copy).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-98) }

            $result = Remove-SourceDeliveryStaleOperationWorktrees -TempRoot $temp -MinimumAgeHours 168

            @($result.entries | ForEach-Object path) | Should -Be @($reused)
            $result.retained | Should -Be 1
            Test-Path -LiteralPath (Join-Path $waiting 'scripts\new-gate-stand.ps1') -PathType Leaf | Should -BeTrue
            Test-Path -LiteralPath $reused | Should -BeFalse

            Stop-Process -Id $waiter.Id -Force; $waiter.WaitForExit(10000) | Should -BeTrue
            $released = Remove-SourceDeliveryStaleOperationWorktrees -TempRoot $temp -MinimumAgeHours 168
            @($released.entries | ForEach-Object path) | Should -Be @($waiting)
            Test-Path -LiteralPath $waiting | Should -BeFalse
            @(& git -C $root worktree list --porcelain | Where-Object { $_ -like 'worktree *itl-source-supervisor-*' }).Count | Should -Be 0
        } finally {
            if ($waiter -and -not $waiter.HasExited) { Stop-Process -Id $waiter.Id -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $root) { foreach ($copy in @($waiting, $reused)) { & git -C $root worktree remove --force $copy 2>$null } }
            Remove-Item -LiteralPath $container -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'leases a pinned supervisor copy to its own process before it waits for the delivery lock' {
        $supervisor = Join-Path $RepoRoot 'scripts\source-delivery-supervisor.ps1'
        $tokens = $null; $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($supervisor, [ref]$tokens, [ref]$parseErrors)
        @($parseErrors) | Should -BeNullOrEmpty
        $commands = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true))
        $lease = @($commands | Where-Object { $_.GetCommandName() -eq 'Write-SourceDeliverySupervisorLease' })
        $lease.Count | Should -Be 1
        $lease[0].Extent.Text | Should -Match '-SupervisorRoot \(Split-Path -Parent \$PSScriptRoot\)'
        $owner = $lease[0].Parent; while ($owner -and $owner -isnot [Management.Automation.Language.FunctionDefinitionAst]) { $owner = $owner.Parent }
        $owner | Should -BeNullOrEmpty
        $firstWait = @($commands | Where-Object { $_.GetCommandName() -in @('Enter-DeliveryOperation', 'Invoke-DeliveryDelegatedCleanupExecutor') } | ForEach-Object { $_.Extent.StartOffset } | Sort-Object)[0]
        $lease[0].Extent.StartOffset | Should -BeLessThan $firstWait
        # Status and cleanup-executor copies are not leased: only the exact temp shape is.
        . (Join-Path $RepoRoot 'scripts\source-delivery-cleanup.ps1')
        Write-SourceDeliverySupervisorLease -SupervisorRoot $RepoRoot | Should -BeFalse
    }

    It 'removes unregistered candidate remnants and dangling registrations but leaves registered candidates to the ledger' {
        $container = Join-Path $TestDrive ('remnants ' + [char]0x041F + ' ' + [guid]::NewGuid().ToString('N'))
        $temp = Join-Path $container 'temp root'; $root = Join-Path $container 'main repo'; $other = Join-Path $container 'other clone'
        $ids = @{}; foreach ($name in @('remnant', 'attribute', 'fresh', 'registered', 'otherClone', 'danglingRegister')) { $ids[$name] = [guid]::NewGuid().ToString('N') }
        $path = @{
            remnant = Join-Path $temp "itl-source-publish-develop-$($ids.remnant)"
            attribute = Join-Path $temp "itl-source-attribute-$($ids.attribute)"
            fresh = Join-Path $temp "itl-source-release-master-$($ids.fresh)"
            registered = Join-Path $temp "itl-source-publish-develop-$($ids.registered)"
            otherClone = Join-Path $temp "itl-source-plan-develop-$($ids.otherClone)"
            danglingRegister = Join-Path $temp "itl-source-register-$($ids.danglingRegister)"
        }
        try {
            [void][IO.Directory]::CreateDirectory($temp)
            New-CleanupRepository -Root $root
            New-CleanupRepository -Root $other
            & git -C $root worktree add --quiet -b "itl/publish-develop-$($ids.registered)" $path.registered
            & git -C $other worktree add --quiet -b "itl/plan-develop-$($ids.otherClone)" $path.otherClone
            # A partly failed worktree removal leaves files without the .git link.
            foreach ($name in @('remnant', 'attribute', 'fresh')) { [void][IO.Directory]::CreateDirectory((Join-Path $path[$name] 'build\test-results')) }
            [void][IO.Directory]::CreateDirectory((Join-Path $path.danglingRegister 'build'))
            Set-Content -LiteralPath (Join-Path $path.danglingRegister '.git') -Encoding ASCII -Value ('gitdir: ' + (Join-Path $container 'removed fixture\.git\worktrees\gone'))
            foreach ($name in @('remnant', 'attribute', 'registered', 'otherClone', 'danglingRegister')) { (Get-Item -LiteralPath $path[$name]).LastWriteTimeUtc = [DateTime]::UtcNow.AddHours(-2) }
            $script:Root = $root
            function Invoke-DeliveryGit { param([string[]]$Arguments, [switch]$AllowFailure); Invoke-RepositoryGit -RepositoryRoot $script:Root -Arguments $Arguments -AllowFailure:$AllowFailure }
            . (Join-Path $RepoRoot 'scripts\source-delivery-cleanup.ps1')
            $result = Remove-SourceDeliveryStaleOperationWorktrees -TempRoot $temp -MinimumAgeHours 168
            @($result.entries | ForEach-Object path | Sort-Object) | Should -Be @(@($path.remnant, $path.attribute, $path.danglingRegister) | Sort-Object)
            $result.retained | Should -Be 3
            foreach ($name in @('fresh', 'registered', 'otherClone')) { Test-Path -LiteralPath $path[$name] | Should -BeTrue -Because $name }
            @(& git -C $root branch --list "itl/publish-develop-$($ids.registered)").Count | Should -Be 1
        } finally {
            foreach ($repo in @($root, $other)) { if (Test-Path -LiteralPath $repo) { foreach ($name in $path.Keys) { & git -C $repo worktree remove --force $path[$name] 2>$null } } }
            Remove-Item -LiteralPath $container -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'removes only expired operation log directories and keeps a current one even in a manual sweep' {
        $temp = Join-Path $TestDrive ('logs ' + [char]0x0416 + ' temp')
        $old = @((Join-Path $temp ('itl-source-attribution-' + ('a' * 32))), (Join-Path $temp ('itl-gate-stand-logs-' + ('b' * 32))))
        $current = Join-Path $temp ('itl-gate-stand-logs-' + ('c' * 32))
        $foreign = @((Join-Path $temp 'itl-gate-stand-logs-not-generated'), (Join-Path $temp ('itl-source-attribution-' + ('d' * 32))))
        foreach ($path in @($old + $current + $foreign)) { [void][IO.Directory]::CreateDirectory($path); [IO.File]::WriteAllText((Join-Path $path 'step.stdout.log'), 'log') }
        [void][IO.Directory]::CreateDirectory((Join-Path $foreign[1] '.git'))
        foreach ($path in @($old + $foreign)) { (Get-Item -LiteralPath $path).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-2) }
        (Get-Item -LiteralPath $current).LastWriteTimeUtc = [DateTime]::UtcNow.AddHours(-2)
        . (Join-Path $RepoRoot 'scripts\source-delivery-cleanup.ps1')
        $result = Remove-SourceDeliveryExpiredOperationLogs -TempRoot $temp -MinimumAgeHours 0
        @($result.entries | ForEach-Object path | Sort-Object) | Should -Be @($old | Sort-Object)
        $result.retained | Should -Be 2
        foreach ($path in @($current) + $foreign) { Test-Path -LiteralPath $path | Should -BeTrue -Because $path }
    }

    It 'keeps only this clone''s newest unexpired superseded gate stand and removes the rest with their siblings' {
        $container = Join-Path $TestDrive ('stands ' + [char]0x0441)
        $env:ITL_GATE_STANDS_ROOT = $container
        try {
            . (Join-Path $RepoRoot 'scripts\source-delivery-release-recovery.ps1')
            . (Join-Path $RepoRoot 'scripts\source-delivery-cleanup.ps1')
            $script:cleanupCommon = Join-Path $TestDrive 'main clone\.git'
            function Get-DeliveryCommonGitDirectory { throw 'mocked per test' }
            Mock Get-DeliveryCommonGitDirectory { $script:cleanupCommon }
            $fixtureId = & { param($path, $repository) . $path; Get-GateStandFixtureId -Repository $repository } (Join-Path $RepoRoot 'scripts\new-gate-stand.ps1') $RepoRoot
            $current = Get-DeliveryGateStandRoot -CommonGitDirectory $script:cleanupCommon -FixtureId $fixtureId
            $stands = @{}
            foreach ($name in @('superseded', 'older', 'fresh', 'foreign', 'unowned')) { $stands[$name] = Join-Path $container ("$name " + [char]0x0441 + ' 0123abcd') }
            foreach ($root in @($current) + @($stands.Values)) {
                foreach ($path in @($root, ($root + '-positive'), ($root + '-workflow-develop-e2e'))) { [void][IO.Directory]::CreateDirectory((Join-Path $path '.agent-1c')) }
                [void][IO.File]::WriteAllText(($root + '.lock'), '')
            }
            foreach ($name in @('superseded', 'older', 'fresh')) { Set-DeliveryGateStandOwner -StandRoot $stands[$name] -CommonGitDirectory $script:cleanupCommon }
            Set-DeliveryGateStandOwner -StandRoot $current -CommonGitDirectory $script:cleanupCommon
            Set-DeliveryGateStandOwner -StandRoot $stands.foreign -CommonGitDirectory (Join-Path $TestDrive 'other clone\.git')
            foreach ($root in @($current, $stands.superseded, $stands.foreign, $stands.unowned)) { (Get-Item -LiteralPath $root).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-8) }
            (Get-Item -LiteralPath $stands.older).LastWriteTimeUtc = [DateTime]::UtcNow.AddHours(-1)
            $result = Remove-SourceDeliverySupersededGateStands -MinimumAgeHours 168
            @($result.entries | ForEach-Object path | Sort-Object) | Should -Be @(@($stands.superseded, $stands.older) | Sort-Object)
            @($result.entries | ForEach-Object directories) | Should -Be @(3, 3)
            foreach ($name in @('superseded', 'older')) { foreach ($suffix in @('', '-positive', '-workflow-develop-e2e', '.lock')) { Test-Path -LiteralPath ($stands[$name] + $suffix) | Should -BeFalse } }
            foreach ($root in @($current, $stands.fresh, $stands.foreign, $stands.unowned)) {
                foreach ($suffix in @('', '-positive', '-workflow-develop-e2e')) { Test-Path -LiteralPath ($root + $suffix) | Should -BeTrue -Because ($root + $suffix) }
            }
        } finally { Remove-Item Env:ITL_GATE_STANDS_ROOT -ErrorAction SilentlyContinue }
    }

    It 'removes only test artifacts an interrupted shard left in temp over an hour ago' {
        $temp = Join-Path $TestDrive ('temp ' + [char]0x0416)
        $id = 'abcdef0123456789abcdef0123456789'
        $old = @((Join-Path $temp "itl-ondemand-owner-$id"), (Join-Path $temp "itl deadline path $id"), (Join-Path $temp "itl-test-powershell-stdout-$id.log"))
        $fresh = Join-Path $temp "itl-merge-resume-$id"
        $foreign = @((Join-Path $temp 'itl-ondemand-owner-not-a-test'), (Join-Path $temp "itl-source-register-$id"), (Join-Path $temp "itl-test-powershell-stdout-$id.json"))
        foreach ($path in @($old[0], $old[1], $fresh, $foreign[0], $foreign[1])) { [void][IO.Directory]::CreateDirectory((Join-Path $path 'payload')) }
        foreach ($path in @($old[2], $foreign[2])) { [IO.File]::WriteAllText($path, 'x') }
        foreach ($path in @($old + $foreign)) { (Get-Item -LiteralPath $path).LastWriteTimeUtc = [DateTime]::UtcNow.AddHours(-2) }
        . (Join-Path $RepoRoot 'scripts\source-delivery-cleanup.ps1')
        $result = Remove-SourceDeliveryInterruptedTestArtifacts -TempRoot $temp
        @($result.entries | ForEach-Object path | Sort-Object) | Should -Be @($old | Sort-Object)
        foreach ($path in @($fresh) + $foreign) { Test-Path -LiteralPath $path | Should -BeTrue -Because $path }
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

    It 'keeps an unregistered candidate while a pending stand update in its recorded scope names it as source, then removes it' {
        # A failed stand-workflow-update precedes the plan, so its candidate has
        # no ledger record; the next PublishDevelop pre-operation cleanup must not
        # turn WORKFLOW_UPDATE_POST_COPY_INCOMPLETE into WORKFLOW_UPDATE_SOURCE_MISSING.
        $root = Join-Path ([IO.Path]::GetTempPath()) ('itl cleanup held repo ' + [guid]::NewGuid().ToString('N'))
        $stand = Join-Path $TestDrive ('stand ' + [char]0x0441 + [char]0x0442 + ' ' + [guid]::NewGuid().ToString('N'))
        $branchRoot = Join-Path $stand ('branch ' + [char]0x0416 + ' develop')
        $ids = @{}; foreach ($name in @('held', 'other', 'plain')) { $ids[$name] = [guid]::NewGuid().ToString('N') }
        $path = @{}; foreach ($name in $ids.Keys) { $path[$name] = Join-Path ([IO.Path]::GetTempPath()) "itl-source-publish-develop-$($ids[$name])" }
        try {
            New-CleanupRepository -Root $root
            foreach ($name in $ids.Keys) { & git -C $root worktree add --quiet -b "itl/publish-develop-$($ids[$name])" $path[$name] }
            foreach ($name in @('held', 'other')) {
                $scopePath = Join-Path $path[$name] 'build/test-results/delivery/stand-update-roots.json'
                [void][IO.Directory]::CreateDirectory((Split-Path -Parent $scopePath))
                [IO.File]::WriteAllText($scopePath, ([ordered]@{schemaVersion=1;projectRoot=$stand;sourceCommit='c';roots=@($branchRoot)} | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
            }
            $snapshot = Join-Path $branchRoot '.agent-1c/snapshots/workflow-update/itl-workflow-update-rollback-0001'
            [void][IO.Directory]::CreateDirectory($snapshot)
            [IO.File]::WriteAllText((Join-Path $snapshot 'transaction.json'), ([ordered]@{phase='post-copy-failed';sourceRoot=$path.held;sourceCommit='c'} | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
            $script:Root = $root
            function Invoke-DeliveryGit { param([string[]]$Arguments, [switch]$AllowFailure); Invoke-RepositoryGit -RepositoryRoot $script:Root -Arguments $Arguments -AllowFailure:$AllowFailure }
            . (Join-Path $RepoRoot 'scripts\source-delivery-cleanup.ps1')
            $result = Remove-SourceDeliveryStaleCandidateWorktrees
            @($result.entries | ForEach-Object path | Sort-Object) | Should -Be @(@($path.other, $path.plain) | Sort-Object)
            Test-Path -LiteralPath $path.held | Should -BeTrue
            # An unreadable receipt cannot prove that the candidate is released.
            [IO.File]::WriteAllText((Join-Path $snapshot 'transaction.json'), '{', [Text.UTF8Encoding]::new($false))
            (Remove-SourceDeliveryStaleCandidateWorktrees).removedWorktrees | Should -Be 0
            # Once the update owner completes or abandons, ordinary cleanup applies.
            Remove-Item -LiteralPath $snapshot -Recurse -Force
            $result = Remove-SourceDeliveryStaleCandidateWorktrees
            @($result.entries | ForEach-Object path) | Should -Be @($path.held)
        } finally {
            if (Test-Path -LiteralPath $root) { foreach ($candidate in $path.Values) { & git -C $root worktree remove --force $candidate 2>$null }; Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
            Remove-Item -LiteralPath @($path.Values) -Recurse -Force -ErrorAction SilentlyContinue
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

    It 'removes a stale delivery test fixture with its registration and supervisor worktrees but keeps one with a foreign worktree' {
        $fixturePrefix = 'itl delivery ' + [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('0L/Rg9GC0Yw=')) + ' '; $container = Join-Path $TestDrive 'operation fixtures'
        New-Item -ItemType Directory -Force -Path $container | Out-Null
        $fixtures = foreach ($name in @('stale', 'foreign')) {
            $root = Join-Path $container ($fixturePrefix + [guid]::NewGuid().ToString('N')); $remote = Join-Path $container ('itl-delivery-remote-' + [guid]::NewGuid().ToString('N') + '.git')
            New-CleanupRepository -Root $root | Out-Null; Set-Content (Join-Path $root 'README.md') 'base'; Set-Content (Join-Path $root 'fake-gate.ps1') 'exit 0'
            & git -C $root add --all | Out-Null; & git -C $root commit --quiet -m fixture-shape | Out-Null
            & git init --quiet --bare $remote | Out-Null; & git -C $root remote add origin $remote | Out-Null
            [pscustomobject]@{ name = $name; root = $root; remote = $remote }
        }
        $registerId = [guid]::NewGuid().ToString('N'); $register = Join-Path $container "itl-source-register-$registerId"
        $supervisor = Join-Path $container ('itl-source-supervisor-' + [guid]::NewGuid().ToString('N'))
        $foreignId = [guid]::NewGuid().ToString('N'); $foreign = Join-Path $container "itl-source-register-$foreignId"
        & git -C $fixtures[0].root worktree add --quiet -b "itl/register-$registerId" $register
        & git -C $fixtures[0].root worktree add --quiet --detach $supervisor
        & git -C $fixtures[1].root worktree add --quiet -b "user/register-$foreignId" $foreign
        . (Join-Path $RepoRoot 'scripts\source-delivery-cleanup.ps1')
        $result = Remove-SourceDeliveryStaleTestFixtures -TempRoot $container
        $result.removedFixtures | Should -Be 1; $result.removedWorktrees | Should -Be 2
        foreach ($path in @($fixtures[0].root, $fixtures[0].remote, $register, $supervisor)) { Test-Path -LiteralPath $path | Should -BeFalse -Because $path }
        foreach ($path in @($fixtures[1].root, $fixtures[1].remote, $foreign)) { Test-Path -LiteralPath $path | Should -BeTrue -Because $path }
    }

    It 'removes only closed exact release-seed archives' {
        $root = Join-Path $TestDrive 'e2e'; New-CleanupRepository -Root $root; $archiveRoot = Join-Path $root '.agent-1c\branch-archives'; $stale = Join-Path $archiveRoot 'release-seed-a-1234abcd\generation'; $active = Join-Path $archiveRoot 'release-seed-b-1234abcd\generation'; New-Item -ItemType Directory -Force -Path $stale, $active, (Join-Path $root '.agent-1c\dev-branches\release-seed-b-1234abcd') | Out-Null; Set-Content (Join-Path $stale 'infobase.dt') 'stale'; Set-Content (Join-Path $active 'infobase.dt') 'active'
        . (Join-Path $RepoRoot 'scripts\source-delivery-cleanup.ps1')
        $result = Remove-SourceDeliveryStaleReleaseSeedArchives -ProjectRoot $root
        $result.removedArchives | Should -Be 1; $result.freedBytes | Should -BeGreaterThan 0; Test-Path (Split-Path -Parent $stale) | Should -BeFalse; Test-Path (Split-Path -Parent $active) | Should -BeTrue
    }

    It 'removes expired non-Git Vanessa build work under a whitespace and non-ASCII root' {
        $root = Join-Path $TestDrive ("build with space-{0}" -f [char]0x0416); $owned = Join-Path $root 'deadbeef'; $legacy = Join-Path $root 'legacy-diagnostic'; $git = Join-Path $root '1234abcd'
        New-Item -ItemType Directory -Force -Path $owned | Out-Null; Set-Content -LiteralPath (Join-Path $owned 'result.bin') -Value 'owned'
        New-Item -ItemType Directory -Force -Path $legacy | Out-Null; Set-Content -LiteralPath (Join-Path $legacy 'result.bin') -Value 'legacy'
        New-CleanupRepository -Root $git
        . (Join-Path $RepoRoot 'scripts\source-delivery-cleanup.ps1')

        $result = Remove-SourceDeliveryStaleVanessaBuildWork -WorkRoot $root -MinimumAgeHours 0

        $result.removedDirectories | Should -Be 2; $result.freedBytes | Should -BeGreaterThan 0
        Test-Path -LiteralPath $owned | Should -BeFalse; Test-Path -LiteralPath $legacy | Should -BeFalse; Test-Path -LiteralPath $git | Should -BeTrue
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
        $manifest = @{ moved = @(
            @{ source = 'old-source'; destination = (Join-Path $agent 'old.bin') }
            @{ junction = $true; destination = (Join-Path $relocated 'live') }
        ) }
        [IO.File]::WriteAllText((Join-Path $preserved 'manifest.json'), ($manifest | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
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
        $again = Remove-SourceDeliveryExpiredArtifactHolds -SearchRoot $root -MinimumAgeHours 0
        $again.removedDirectories | Should -Be 0; $again.retained | Should -Be 0
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
        Mock Remove-SourceDeliveryStaleOperationWorktrees { [pscustomobject]@{ removedDirectories=0; retained=0; freedBytes=0 } }
        Mock Remove-SourceDeliverySupersededGateStands { [pscustomobject]@{ removedStands=0; retained=0; freedBytes=0 } }
        Mock Remove-SourceDeliveryInterruptedTestArtifacts { [pscustomobject]@{ removedItems=0; retained=0; freedBytes=0 } }
        Mock Remove-SourceDeliveryStaleTestFixtures { [pscustomobject]@{ removedFixtures=0; removedWorktrees=0 } }
        Mock Remove-SourceDeliveryStaleVanessaBuildWork { [pscustomobject]@{ removedDirectories=0; retained=0; freedBytes=0 } }
        Mock Remove-SourceDeliveryStaleReleaseRecoveryArtifacts { [pscustomobject]@{ removedDirectories=0; retained=0; freedBytes=0 } }
        Mock Remove-SourceDeliveryCompletedFixtureCopies { [pscustomobject]@{ removed=0; retained=0; removedBytes=0 } }
        Mock Remove-DevelopE2EStaleFreshProjects { [pscustomobject]@{ removedProjects=0 } }
        Mock Remove-DevelopE2EStaleLauncherRegistrations { 0 }
        Mock Remove-ReleaseE2EStaleLauncherRegistrations { 0 }
        Mock Remove-DevelopE2ELauncherListBackups { [pscustomobject]@{ retained=1; removed=0 } }
        Mock Get-DevelopE2ELauncherListPath { Join-Path $TestDrive 'ibases.v8i' }
        $result = Invoke-SourceDeliveryPostSuccessCleanup -FreshProjectsRoot $TestDrive
        $result.status | Should -Be 'completed-with-warnings'; @($result.warnings).Count | Should -Be 1; $result.warnings[0] | Should -Match 'candidate cleanup unavailable'
        Should -Invoke Remove-SourceDeliveryCompletedFixtureCopies -Times 1 -Exactly -ParameterFilter {$FreshProjectsRoot -eq $TestDrive}
        foreach ($step in @('Remove-SourceDeliveryStaleOperationWorktrees', 'Remove-SourceDeliverySupersededGateStands')) {
            Should -Invoke $step -Times 1 -Exactly -ParameterFilter {$MinimumAgeHours -eq 168}
        }
        Should -Invoke Remove-SourceDeliveryInterruptedTestArtifacts -Times 1 -Exactly -ParameterFilter {$MinimumAgeHours -eq 1}
    }

    It 'resolves develop and master cleanup executors from their exact remote channel commits' {
        $root = Join-Path $TestDrive ("cleanup channels with space-{0}" -f [char]0x0416)
        $remote = Join-Path $TestDrive ('cleanup-channels-' + [guid]::NewGuid().ToString('N') + '.git')
        try {
            New-CleanupRepository -Root $root
            $base = (& git -C $root rev-parse HEAD).Trim()
            & git init --quiet --bare $remote
            & git -C $root remote add origin $remote
            & git -C $root push --quiet origin HEAD:develop HEAD:master

            Set-Content -LiteralPath (Join-Path $root 'README.md') -Encoding UTF8 -Value 'develop executor'
            & git -C $root add README.md; & git -C $root commit --quiet -m develop-executor
            $developCommit = (& git -C $root rev-parse HEAD).Trim()
            & git -C $root push --quiet origin HEAD:develop

            & git -C $root switch --quiet -c master $base
            Set-Content -LiteralPath (Join-Path $root 'README.md') -Encoding UTF8 -Value 'master executor'
            & git -C $root add README.md; & git -C $root commit --quiet -m master-executor
            $masterCommit = (& git -C $root rev-parse HEAD).Trim()
            & git -C $root push --quiet origin HEAD:master
            & git -C $root fetch --quiet origin '+refs/heads/*:refs/remotes/origin/*'

            $script:Root = $root
            $script:Remote = 'origin'
            function Invoke-DeliveryGit {
                param([string[]]$Arguments, [switch]$AllowFailure, [AllowNull()][string]$StandardInput = $null)
                Invoke-RepositoryGit -RepositoryRoot $script:Root -Arguments $Arguments -AllowFailure:$AllowFailure -StandardInput $StandardInput
            }
            . (Join-Path $RepoRoot 'scripts\source-delivery-cleanup.ps1')

            (Resolve-DeliveryCleanupChannelCommit -Channel Develop).commit | Should -Be $developCommit
            (Resolve-DeliveryCleanupChannelCommit -Channel Master).commit | Should -Be $masterCommit
            { Resolve-DeliveryCleanupChannelCommit -Channel Develop -ExpectedCommit $masterCommit } | Should -Throw '*DELIVERY_CLEANUP_EXECUTOR_MOVED*'
        } finally {
            Remove-Item -LiteralPath $root, $remote -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'routes publication cleanup to the matching channel before and after the exact published commit' {
        . (Join-Path $RepoRoot 'scripts\source-delivery-cleanup.ps1')
        $script:DeliverySupervisorCommit = 'a' * 40
        function Read-DevelopPublicationAttempt { throw 'Fresh cleanup must not read a resume checkpoint' }
        function Publish-DevelopDeferringFailingEntries { throw 'must be mocked' }
        function Release-DevelopToMaster { throw 'must be mocked' }
        Mock Invoke-DeliveryChannelCleanupSafely {
            param($Channel, $Phase, $ExpectedCommit, [switch]$CompactState)
            [pscustomobject]@{ status='completed'; executor=[pscustomobject]@{ channel=$Channel.ToLowerInvariant(); commit=$ExpectedCommit; phase=$Phase } }
        }
        Mock Publish-DevelopDeferringFailingEntries { [pscustomobject]@{ status='published'; commit=('d' * 40) } }
        Mock Release-DevelopToMaster { [pscustomobject]@{ status='released'; masterCommit=('e' * 40) } }

        $published = Invoke-PublishDevelopWithCleanup
        @($published.cleanupRuns).Count | Should -Be 2
        @($published.cleanupRuns.executor.channel) | Should -Be @('develop', 'develop')
        Should -Invoke Invoke-DeliveryChannelCleanupSafely -Times 1 -ParameterFilter { $Channel -eq 'Develop' -and $Phase -eq 'post-operation' -and $ExpectedCommit -eq ('d' * 40) }

        $released = Invoke-ReleaseMasterWithCleanup
        @($released.cleanupRuns).Count | Should -Be 2
        @($released.cleanupRuns.executor.channel) | Should -Be @('master', 'master')
        Should -Invoke Invoke-DeliveryChannelCleanupSafely -Times 1 -ParameterFilter { $Channel -eq 'Master' -and $Phase -eq 'post-operation' -and $ExpectedCommit -eq ('e' * 40) }
    }

    It 'applies recovery-archive retention after a successful publication and reports its warnings' {
        . (Join-Path $RepoRoot 'scripts\source-delivery-cleanup.ps1')
        function Read-DevelopPublicationAttempt { $null }
        function Publish-DevelopDeferringFailingEntries { throw 'must be mocked' }
        function Invoke-DeliveryRecoveryCleanup { param($OperationAction) throw 'must be mocked' }
        Mock Invoke-DeliveryChannelCleanupSafely { [pscustomobject]@{ status='completed' } }
        Mock Publish-DevelopDeferringFailingEntries { [pscustomobject]@{ status='published'; commit=('d' * 40) } }
        Mock Invoke-DeliveryRecoveryCleanup { [pscustomobject]@{ status='completed'; removedFiles=2; freedBytes=10L; warnings=@(); entries=@() } }
        $published = Invoke-PublishDevelopWithCleanup
        $published.recoveryArchives.removedFiles | Should -Be 2
        $published.PSObject.Properties['deliveryStatus'] | Should -BeNullOrEmpty
        Should -Invoke Invoke-DeliveryRecoveryCleanup -Times 1 -Exactly -ParameterFilter { $OperationAction -eq 'PublishDevelop' }
        Mock Invoke-DeliveryRecoveryCleanup { throw 'archive locked' }
        $warned = Invoke-PublishDevelopWithCleanup 3>$null
        $warned.status | Should -Be 'published'
        $warned.deliveryStatus | Should -Be 'completed-with-cleanup-warnings'
        $warned.recoveryArchives.warnings | Should -Be @('archive locked')
    }

    It 'keeps the master authority lease separate from the delegated cleanup executor identity' {
        $supervisor = Get-Content -LiteralPath (Join-Path $RepoRoot 'scripts\source-delivery-supervisor.ps1') -Raw -Encoding UTF8
        $candidate = Get-Content -LiteralPath (Join-Path $RepoRoot 'scripts\source-delivery-candidate.ps1') -Raw -Encoding UTF8
        $cleanup = Get-Content -LiteralPath (Join-Path $RepoRoot 'scripts\source-delivery-cleanup.ps1') -Raw -Encoding UTF8

        $supervisor | Should -Match 'Invoke-PublishDevelopWithCleanup'
        $supervisor | Should -Match 'Invoke-ReleaseMasterWithCleanup'
        $supervisor | Should -Match 'CleanupChannel -eq "Auto"\) \{ "Develop" \}'
        $candidate | Should -Match 'Promote-AccumulatedDevelopToMaster[\s\S]+Invoke-PublishDevelopWithCleanup[\s\S]+Invoke-ReleaseMasterWithCleanup'
        $cleanup | Should -Match 'Resolve-DeliveryCleanupChannelCommit -Channel \$Channel -ExpectedCommit \$ExpectedCommit'
        $cleanup | Should -Match 'authoritySupervisorCommit = \$AuthorityCommit'
        $cleanup | Should -Match 'DELIVERY_CLEANUP_DELEGATION_INVALID'
        $cleanup | Should -Not -Match 'Enter-DeliveryOperation -Action'
    }
}
