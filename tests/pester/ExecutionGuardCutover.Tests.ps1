Describe 'Execution guard one-time cutover' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        $script:cutover = Join-Path $context.RepoRoot '.agents/skills/1c-workflow/scripts/execution-guard-cutover.ps1'
    }

    It 'removes obsolete protocol state without inspecting ticket semantics or touching user data' {
        $root = Join-Path $TestDrive 'Проект со stale tickets'
        $oldRoots = @(
            '.agent-1c/infobase-access/tickets',
            '.agent-1c/database-access/indexes',
            '.agent-1c/native-recovery/pins',
            '.agent-1c/recovery/archives'
        )
        foreach ($relative in $oldRoots) {
            $path = Join-Path $root $relative
            New-Item -ItemType Directory -Path $path -Force | Out-Null
            [IO.File]::WriteAllText((Join-Path $path 'broken.json'), '{not-json', [Text.UTF8Encoding]::new($false))
        }
        $source = Join-Path $root 'src/cf/Configuration.xml'
        New-Item -ItemType Directory -Path (Split-Path -Parent $source) -Force | Out-Null
        [IO.File]::WriteAllText($source, '<Configuration/>', [Text.UTF8Encoding]::new($false))

        $result = & $cutover -ProjectRoot $root

        $result.status | Should -Be 'completed'
        foreach ($relative in $oldRoots) { Test-Path -LiteralPath (Join-Path $root $relative) | Should -BeFalse }
        (Get-Content -LiteralPath $source -Raw -Encoding UTF8) | Should -Be '<Configuration/>'
        $marker = Get-Content -LiteralPath (Join-Path $root '.agent-1c/execution-guard-generation.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $marker.generation | Should -Be 'execution-guards-v2'
    }

    It 'does not stop a live process when exact ownership markers are absent' {
        $root = Join-Path $TestDrive 'Проект с чужим процессом'
        $runtime = Join-Path $root '.agent-1c/mcp/ondemand/roctup'
        New-Item -ItemType Directory -Path $runtime -Force | Out-Null
        $shellPath = (Get-Process -Id $PID).Path
        $process = Start-Process -FilePath $shellPath -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 30') -PassThru -WindowStyle Hidden
        try {
            $state = [ordered]@{schemaVersion=4;pid=$process.Id;processStartTime=$process.StartTime.ToUniversalTime().ToString('o')
                executablePath=$process.Path;ownershipMarkers=@('marker-not-present-in-command-line')
                testClientPid=0;testClientProcessStartTime='';testClientExecutablePath='';testClientOwnershipMarkers=@()}
            [IO.File]::WriteAllText((Join-Path $runtime 'foreign.json'), ($state | ConvertTo-Json), [Text.UTF8Encoding]::new($false))

            & $cutover -ProjectRoot $root -WarningVariable warnings | Out-Null

            (Get-Process -Id $process.Id -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
            ($warnings -join "`n") | Should -Match 'exact ownership could not be proven'
        } finally {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        }
    }

    It 'fails package preflight before deleting obsolete state or enabling v2' {
        $repo = Join-Path $TestDrive 'Проект с неполным package'
        $package = Join-Path $TestDrive 'Неполный package'
        New-Item -ItemType Directory -Path $repo, $package -Force | Out-Null
        & git -C $repo init --quiet
        & git -C $repo config user.email 'cutover@example.invalid'
        & git -C $repo config user.name 'Execution Guard Cutover Test'
        [IO.File]::WriteAllText((Join-Path $repo '.gitignore'), ".agent-1c/`n", [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $repo 'fixture.txt'), 'fixture', [Text.UTF8Encoding]::new($false))
        & git -C $repo add --all
        & git -C $repo commit --quiet -m 'fixture'
        $legacyState = Join-Path $repo '.agent-1c/database-access/old.json'
        New-Item -ItemType Directory -Path (Split-Path -Parent $legacyState) -Force | Out-Null
        [IO.File]::WriteAllText($legacyState, '{}', [Text.UTF8Encoding]::new($false))

        { & $cutover -ProjectRoot $repo -PackageRoot $package -PrepareManagedWorktrees } |
            Should -Throw '*EXECUTION_GUARD_CUTOVER_PACKAGE_MISSING*'

        Test-Path -LiteralPath $legacyState | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $repo '.agent-1c/execution-guard-generation.json') | Should -BeFalse
    }

    It 'allows the managed main worktree to finish cutover under its legacy parent runtime lease' {
        $repo = Join-Path $TestDrive 'Главный проект с legacy runtime lease'
        New-Item -ItemType Directory -Path $repo -Force | Out-Null
        & git -C $repo init --quiet
        & git -C $repo symbolic-ref HEAD refs/heads/master
        & git -C $repo config user.email 'cutover@example.invalid'
        & git -C $repo config user.name 'Execution Guard Cutover Test'
        foreach ($relative in @(
            '.agents/skills/1c-workflow', '.agents/skills/1c-workflow-fast', '.agents/skills/product-docs',
            '.agents/skills/itl-roctup-1c-data', '.agents/skills/itl-vanessa-ui-mcp', '.agents/skills/itl-remote-runner',
            '.agents/skills/itl-remote-agent', '.agents/skills/itl-performance', 'docs/itl-workflow', 'templates'
        )) {
            $directory = Join-Path $repo $relative
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
            [IO.File]::WriteAllText((Join-Path $directory 'fixture.txt'), 'fixture', [Text.UTF8Encoding]::new($false))
        }
        foreach ($relative in @('install-agent-1c-workflow.ps1', 'AGENT-INSTALL.md')) {
            [IO.File]::WriteAllText((Join-Path $repo $relative), 'fixture', [Text.UTF8Encoding]::new($false))
        }
        [IO.File]::WriteAllText((Join-Path $repo '.gitignore'), ".agent-1c/`n", [Text.UTF8Encoding]::new($false))
        & git -C $repo add --all
        & git -C $repo commit --quiet -m 'fixture'

        $legacyLock = Join-Path $repo '.agent-1c/locks/runtime-mcp.lock'
        New-Item -ItemType Directory -Path (Split-Path -Parent $legacyLock) -Force | Out-Null
        $legacyHandle = [IO.File]::Open($legacyLock, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try {
            $result = & $cutover -ProjectRoot $repo -PackageRoot $repo -PrepareManagedWorktrees -WarningVariable cutoverWarnings
        } finally {
            $legacyHandle.Dispose()
        }

        $result.status | Should -Be 'completed'
        Test-Path -LiteralPath $legacyLock | Should -BeTrue
        ($cutoverWarnings -join "`n") | Should -Match "current operation's held legacy runtime lock"
        $marker = Get-Content -LiteralPath (Join-Path $repo '.agent-1c/execution-guard-generation.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $marker.generation | Should -Be 'execution-guards-v2'
    }

    It 'updates every managed worktree with the source-owned runner before enabling v2' {
        $repo = Join-Path $TestDrive 'Главный проект'
        $branchRoot = Join-Path $TestDrive 'Ветка с пробелом'
        $unmanagedRoot = Join-Path $TestDrive 'Пользовательская ветка'
        $package = Join-Path $TestDrive 'Новый package'
        New-Item -ItemType Directory -Path $repo -Force | Out-Null
        & git -C $repo init --quiet
        & git -C $repo symbolic-ref HEAD refs/heads/master
        & git -C $repo config user.email 'cutover@example.invalid'
        & git -C $repo config user.name 'Execution Guard Cutover Test'
        $oldHelper = Join-Path $repo '.agents/skills/1c-workflow/scripts/agent-1c.ps1'
        New-Item -ItemType Directory -Path (Split-Path -Parent $oldHelper) -Force | Out-Null
        [IO.File]::WriteAllText($oldHelper, 'old helper', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path (Split-Path -Parent $oldHelper) 'old-only.ps1'), 'legacy helper', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $repo 'notes.txt'), 'original', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $repo '.gitignore'), ".agent-1c/`n", [Text.UTF8Encoding]::new($false))
        & git -C $repo add --all
        & git -C $repo commit --quiet -m 'fixture'
        & git -C $repo branch 'itldev/cutover'
        & git -C $repo worktree add --quiet $branchRoot 'itldev/cutover'
        & git -C $repo branch 'feature/user-owned'
        & git -C $repo worktree add --quiet $unmanagedRoot 'feature/user-owned'

        $managedDirectories = @(
            '.agents/skills/1c-workflow', '.agents/skills/1c-workflow-fast', '.agents/skills/product-docs',
            '.agents/skills/itl-roctup-1c-data', '.agents/skills/itl-vanessa-ui-mcp', '.agents/skills/itl-remote-runner',
            '.agents/skills/itl-remote-agent', '.agents/skills/itl-performance', 'docs/itl-workflow', 'templates'
        )
        foreach ($relative in $managedDirectories) {
            $directory = Join-Path $package $relative
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
            [IO.File]::WriteAllText((Join-Path $directory 'v2.txt'), "v2:$relative", [Text.UTF8Encoding]::new($false))
        }
        $newHelper = Join-Path $package '.agents/skills/1c-workflow/scripts/agent-1c.ps1'
        New-Item -ItemType Directory -Path (Split-Path -Parent $newHelper) -Force | Out-Null
        [IO.File]::WriteAllText($newHelper, 'new v2 helper', [Text.UTF8Encoding]::new($false))
        foreach ($relative in @('install-agent-1c-workflow.ps1', 'AGENT-INSTALL.md')) {
            [IO.File]::WriteAllText((Join-Path $package $relative), "v2:$relative", [Text.UTF8Encoding]::new($false))
        }
        [IO.File]::WriteAllText((Join-Path $branchRoot 'notes.txt'), 'user staged change', [Text.UTF8Encoding]::new($false))
        & git -C $branchRoot add notes.txt

        $result = & $cutover -ProjectRoot $repo -PackageRoot $package -PrepareManagedWorktrees

        $result.worktrees | Should -HaveCount 2
        (Get-Content -LiteralPath (Join-Path $branchRoot '.agents/skills/1c-workflow/scripts/agent-1c.ps1') -Raw -Encoding UTF8) | Should -Be 'new v2 helper'
        Test-Path -LiteralPath (Join-Path $branchRoot '.agents/skills/1c-workflow/scripts/old-only.ps1') | Should -BeFalse
        (& git -C $branchRoot log -1 --pretty=%s) | Should -Be 'chore: activate execution guards v2'
        (& git -C $branchRoot status --porcelain) | Should -Be 'M  notes.txt'
        (Get-Content -LiteralPath (Join-Path $branchRoot 'notes.txt') -Raw -Encoding UTF8) | Should -Be 'user staged change'
        (Get-Content -LiteralPath (Join-Path $unmanagedRoot '.agents/skills/1c-workflow/scripts/agent-1c.ps1') -Raw -Encoding UTF8) | Should -Be 'old helper'
        Test-Path -LiteralPath (Join-Path $unmanagedRoot '.agent-1c/execution-guard-generation.json') | Should -BeFalse
        foreach ($root in @($repo, $branchRoot)) {
            $marker = Get-Content -LiteralPath (Join-Path $root '.agent-1c/execution-guard-generation.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            $marker.generation | Should -Be 'execution-guards-v2'
        }
    }
}
