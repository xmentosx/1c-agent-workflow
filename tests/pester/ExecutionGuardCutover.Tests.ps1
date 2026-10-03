Describe 'Execution guard one-time cutover' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        $script:cutover = Join-Path $context.RepoRoot '.agents/skills/1c-workflow/scripts/execution-guard-cutover.ps1'
    }

    It 'preserves stopped-operation evidence while enabling the new guard generation' {
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
        $second = & $cutover -ProjectRoot $root

        $result.status | Should -Be 'completed'
        $second.status | Should -Be 'completed'
        foreach ($relative in $oldRoots) {
            $record = Join-Path (Join-Path $root $relative) 'broken.json'
            Test-Path -LiteralPath $record -PathType Leaf | Should -BeTrue
            (Get-Content -LiteralPath $record -Raw -Encoding UTF8) | Should -Be '{not-json'
        }
        (Get-Content -LiteralPath $source -Raw -Encoding UTF8) | Should -Be '<Configuration/>'
        $marker = Get-Content -LiteralPath (Join-Path $root '.agent-1c/execution-guard-generation.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $marker.generation | Should -Be 'execution-guards-v2'
        @(Get-ChildItem -LiteralPath (Split-Path -Parent (Join-Path $root '.agent-1c/execution-guard-generation.json')) -File |
            Where-Object { $_.Name -like 'execution-guard-generation.json.*' }).Count | Should -Be 0
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

            { & $cutover -ProjectRoot $root } | Should -Throw '*EXECUTION_GUARD_CUTOVER_RUNTIME_OWNERSHIP_UNCONFIRMED*'

            (Get-Process -Id $process.Id -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
            Test-Path -LiteralPath (Join-Path $runtime 'foreign.json') -PathType Leaf | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $root '.agent-1c/execution-guard-generation.json') | Should -BeFalse
        } finally {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        }
    }

    It 'preserves an unreadable runtime record and refuses to enable a new generation' {
        $root = Join-Path $TestDrive 'Проект с повреждённым runtime'
        $runtime = Join-Path $root '.agent-1c/mcp/ondemand/roctup'
        New-Item -ItemType Directory -Path $runtime -Force | Out-Null
        $record = Join-Path $runtime 'broken.json'
        [IO.File]::WriteAllText($record, '{broken', [Text.UTF8Encoding]::new($false))
        { & $cutover -ProjectRoot $root } | Should -Throw '*EXECUTION_GUARD_CUTOVER_RUNTIME_STATE_INVALID*'
        (Get-Content -LiteralPath $record -Raw -Encoding UTF8) | Should -Be '{broken'
        Test-Path -LiteralPath (Join-Path $root '.agent-1c/execution-guard-generation.json') | Should -BeFalse
    }

    It 'defers before enabling v2 when a runtime record points to a live process' {
        $root = Join-Path $TestDrive 'Проект с работающим runtime'
        $runtime = Join-Path $root '.agent-1c/mcp/ondemand/roctup'
        New-Item -ItemType Directory -Path $runtime -Force | Out-Null
        $marker = 'itl-cutover-owned-' + [guid]::NewGuid().ToString('N')
        $shellPath = (Get-Process -Id $PID).Path
        $process = Start-Process -FilePath $shellPath -ArgumentList @('-NoProfile','-Command',"Start-Sleep -Seconds 30 # $marker") -PassThru -WindowStyle Hidden
        try {
            $statePath = Join-Path $runtime 'owned.json'
            $state = [ordered]@{schemaVersion=4;pid=$process.Id;processStartTime=$process.StartTime.ToUniversalTime().ToString('o')
                executablePath=$process.Path;ownershipMarkers=@($marker)
                testClientPid=0;testClientProcessStartTime='';testClientExecutablePath='';testClientOwnershipMarkers=@()}
            [IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
            for ($attempt = 0; $attempt -lt 20; $attempt++) {
                $observed = [string](Get-CimInstance Win32_Process -Filter "ProcessId=$($process.Id)" -ErrorAction SilentlyContinue).CommandLine
                if ($observed.Contains($marker)) { break }
                Start-Sleep -Milliseconds 50
            }
            $observed | Should -Match ([regex]::Escape($marker))
            { & $cutover -ProjectRoot $root } | Should -Throw '*EXECUTION_GUARD_CUTOVER_*RUNTIME*'
            Test-Path -LiteralPath $statePath -PathType Leaf | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $root '.agent-1c/execution-guard-generation.json') | Should -BeFalse
            (Get-Process -Id $process.Id -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        } finally {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        }
    }

    It 'fails package preflight before changing state or enabling v2' {
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

    It 'preserves the managed main worktree legacy runtime lease while enabling v2' {
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
        @($cutoverWarnings).Count | Should -Be 0
        $marker = Get-Content -LiteralPath (Join-Path $repo '.agent-1c/execution-guard-generation.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $marker.generation | Should -Be 'execution-guards-v2'
    }

    It 'updates every managed worktree with the source-owned runner before enabling v2' {
        $repo = Join-Path $TestDrive 'Главный проект'
        $branchRoot = Join-Path $TestDrive 'Ветка с пробелом'
        $unmanagedRoot = Join-Path $TestDrive 'Пользовательская ветка'
        $package = Join-Path $TestDrive 'Новый package'
        . (Join-Path $context.RepoRoot 'scripts/git-path-list.ps1')
        $cacheRelative='.agents/skills/itl-remote-runner/scripts/__pycache__/legacy.cpython-313.pyc'
        New-Item -ItemType Directory -Path $repo -Force | Out-Null
        & git -C $repo init --quiet
        & git -C $repo symbolic-ref HEAD refs/heads/master
        & git -C $repo config user.email 'cutover@example.invalid'
        & git -C $repo config user.name 'Execution Guard Cutover Test'
        $oldHelper = Join-Path $repo '.agents/skills/1c-workflow/scripts/agent-1c.ps1'
        New-Item -ItemType Directory -Path (Split-Path -Parent $oldHelper) -Force | Out-Null
        [IO.File]::WriteAllText($oldHelper, 'old helper', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path (Split-Path -Parent $oldHelper) 'old-only.ps1'), 'legacy helper', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path (Split-Path -Parent $oldHelper) 'stable.txt'), "same LF`n", [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $repo 'notes.txt'), 'original', [Text.UTF8Encoding]::new($false))
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent (Join-Path $repo $cacheRelative)) | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $repo $cacheRelative),[byte[]]@(0,255,13,10))
        [IO.File]::WriteAllText((Join-Path $repo '.gitignore'), ".agent-1c/`n", [Text.UTF8Encoding]::new($false))
        & git -C $repo -c core.safecrlf=false add --all
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
        [IO.File]::WriteAllText((Join-Path (Split-Path -Parent $newHelper) 'stable.txt'), "same LF`n", [Text.UTF8Encoding]::new($false))
        foreach ($relative in @('install-agent-1c-workflow.ps1', 'AGENT-INSTALL.md')) {
            [IO.File]::WriteAllText((Join-Path $package $relative), "v2:$relative", [Text.UTF8Encoding]::new($false))
        }
        [IO.File]::WriteAllText((Join-Path $branchRoot 'notes.txt'), 'user staged change', [Text.UTF8Encoding]::new($false))
        & git -C $branchRoot add notes.txt
        $trackedCheckpoint = Join-Path $branchRoot '.agent-1c/execution-checkpoints/legacy.json'
        $trackedMarkerTemporary = Join-Path $branchRoot '.agent-1c/execution-guard-generation.json.legacy.tmp'
        New-Item -ItemType Directory -Path (Split-Path -Parent $trackedCheckpoint) -Force | Out-Null
        [IO.File]::WriteAllText($trackedCheckpoint, '{"status":"resumed"}', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($trackedMarkerTemporary, 'temporary marker', [Text.UTF8Encoding]::new($false))
        & git -C $branchRoot add -f -- '.agent-1c/execution-checkpoints/legacy.json' '.agent-1c/execution-guard-generation.json.legacy.tmp'
        & git -C $branchRoot commit --quiet -m 'fixture: accidentally track execution runtime' -- '.agent-1c/execution-checkpoints/legacy.json' '.agent-1c/execution-guard-generation.json.legacy.tmp'

        $businessBefore=@(Get-RepositoryGitPathList -RepositoryRoot $branchRoot -Arguments @('ls-files','--stage','-z','--','notes.txt')) -join "`0"
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent (Join-Path $package $cacheRelative)) | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $package $cacheRelative),[byte[]]@(0,128,13,10))
        $looseCache='.agents/skills/itl-remote-runner/scripts/generated.pyc'
        [IO.File]::WriteAllBytes((Join-Path $package $looseCache),[byte[]]@(0,255,50))
        $pythonSource='.agents/skills/itl-remote-runner/scripts/module.py'
        [IO.File]::WriteAllText((Join-Path $package $pythonSource),"# source transport`r`n",[Text.UTF8Encoding]::new($false))
        $cacheBefore=(Get-FileHash -LiteralPath (Join-Path $package $cacheRelative)).Hash
        $unmanagedCacheBefore=(Get-FileHash -LiteralPath (Join-Path $unmanagedRoot $cacheRelative)).Hash
        # The managed add emits a successful Git stderr warning on Windows.
        [IO.File]::WriteAllText((Join-Path $package '.agents/skills/1c-workflow/v2.txt'), "v2`n", [Text.UTF8Encoding]::new($false))
        & git -C $repo config core.autocrlf true
        & git -C $repo config core.safecrlf warn

        $result = & $cutover -ProjectRoot $repo -PackageRoot $package -PrepareManagedWorktrees

        $result.worktrees | Should -HaveCount 2
        foreach($root in @($branchRoot)) {
            (Test-Path -LiteralPath (Join-Path $root $cacheRelative)) | Should -BeFalse
            (Test-Path -LiteralPath (Join-Path $root $looseCache)) | Should -BeFalse
            @(Get-RepositoryGitPathList -RepositoryRoot $root -Arguments @('ls-tree','-r','--name-only','-z','HEAD','--',$cacheRelative,$looseCache)) | Should -HaveCount 0
            (Get-FileHash -LiteralPath (Join-Path $root $pythonSource)).Hash | Should -BeExactly (Get-FileHash -LiteralPath (Join-Path $package $pythonSource)).Hash
        }
        (@(Get-RepositoryGitPathList -RepositoryRoot $branchRoot -Arguments @('ls-files','--stage','-z','--','notes.txt')) -join "`0") | Should -BeExactly $businessBefore
        (Get-FileHash -LiteralPath (Join-Path $package $cacheRelative)).Hash | Should -BeExactly $cacheBefore
        (Get-FileHash -LiteralPath (Join-Path $unmanagedRoot $cacheRelative)).Hash | Should -BeExactly $unmanagedCacheBefore
        (Get-FileHash -LiteralPath (Join-Path $repo $cacheRelative)).Hash | Should -BeExactly $unmanagedCacheBefore
        (Get-Content -LiteralPath (Join-Path $branchRoot '.agents/skills/1c-workflow/scripts/agent-1c.ps1') -Raw -Encoding UTF8) | Should -Be 'new v2 helper'
        Test-Path -LiteralPath (Join-Path $branchRoot '.agents/skills/1c-workflow/scripts/old-only.ps1') | Should -BeFalse
        (& git -C $branchRoot log -1 --pretty=%s) | Should -Be 'chore: activate execution guards v2'
        (& git -C $branchRoot status --porcelain) | Should -Be 'M  notes.txt'
        (Get-Content -LiteralPath (Join-Path $branchRoot 'notes.txt') -Raw -Encoding UTF8) | Should -Be 'user staged change'
        Test-Path -LiteralPath $trackedCheckpoint | Should -BeTrue
        Test-Path -LiteralPath $trackedMarkerTemporary | Should -BeTrue
        @(& git -C $branchRoot ls-files -- '.agent-1c/execution-checkpoints/legacy.json' '.agent-1c/execution-guard-generation.json.legacy.tmp') | Should -BeNullOrEmpty
        (Get-Content -LiteralPath (Join-Path $unmanagedRoot '.agents/skills/1c-workflow/scripts/agent-1c.ps1') -Raw -Encoding UTF8) | Should -Be 'old helper'
        Test-Path -LiteralPath (Join-Path $unmanagedRoot '.agent-1c/execution-guard-generation.json') | Should -BeFalse
        foreach ($root in @($repo, $branchRoot)) {
            $marker = Get-Content -LiteralPath (Join-Path $root '.agent-1c/execution-guard-generation.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            $marker.generation | Should -Be 'execution-guards-v2'
        }
    }
}
