Describe 'Release stand recovery cutover' {
    BeforeAll {
        $script:RecoveryScript = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'scripts\rebuild-release-e2e-stand.ps1'
    }
    It 'keeps the damaged stand and checkpoint while switching only after a verified fork' {
        $root = Join-Path $TestDrive 'release recovery путь'
        $project = Join-Path $root 'project'
        $old = Join-Path $root 'old branch'
        $fixture = Join-Path $root 'fixture branch'
        $target = Join-Path $root 'new branch'
        New-Item -ItemType Directory -Force -Path $project | Out-Null
        & git -C $project init -b master | Out-Null
        & git -C $project config user.email tests@example.invalid
        & git -C $project config user.name Tests
        $marker = Join-Path $project 'tests\features\workflow-release-e2e.feature'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $marker) | Out-Null
        [IO.File]::WriteAllText($marker, "# fixture`n", [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $project '.gitignore'), ".agent-1c/`n", [Text.UTF8Encoding]::new($false))
        $helper = Join-Path $project '.agents\skills\1c-workflow\scripts\run-itl-command.ps1'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $helper) | Out-Null
        $fakeHelper = @'
$destination = $env:ITL_TEST_RECOVERY_TARGET_ROOT
& git -C (Get-Location).Path worktree add --quiet -b itldev/rebuilt $destination HEAD
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$state = Join-Path $destination '.agent-1c\dev-branches\rebuilt.json'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $state) | Out-Null
[IO.File]::WriteAllText($state, '{"unsafeActionProtectionConfirmed":true}', [Text.UTF8Encoding]::new($false))
'@
        [IO.File]::WriteAllText($helper, $fakeHelper, [Text.UTF8Encoding]::new($true))
        & git -C $project add -- .
        & git -C $project commit -m fixture | Out-Null
        & git -C $project worktree add --quiet -b itldev/old $old master
        & git -C $project worktree add --quiet -b itldev/fixture $fixture master
        $configPath = Join-Path $project '.agent-1c\release-e2e.json'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $configPath) | Out-Null
        $original = [ordered]@{ schemaVersion=1; devBranchName='old'; worktreePath=$old; developWorktreePath='preserved' }
        [IO.File]::WriteAllText($configPath, ($original | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        $checkpoint = Join-Path $old '.agent-1c\runs\release-e2e\old\checkpoint.json'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $checkpoint) | Out-Null
        [IO.File]::WriteAllText($checkpoint, '{"damaged":true}', [Text.UTF8Encoding]::new($false))
        $env:ITL_TEST_RECOVERY_TARGET_ROOT = $target
        try {
            $fixtureCheckpoint = Join-Path $fixture '.agent-1c\runs\release-e2e\fixture\checkpoint.json'
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $fixtureCheckpoint) | Out-Null
            [IO.File]::WriteAllText($fixtureCheckpoint, '{"unsafe":true}', [Text.UTF8Encoding]::new($false))
            { & $script:RecoveryScript -E2EProjectRoot $project -FixtureWorktree $fixture -NewDevBranchName rebuilt } |
                Should -Throw '*Fixture source has a Release checkpoint*'
            (Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json).worktreePath | Should -Be $old
            Test-Path -LiteralPath $target | Should -BeFalse
            Remove-Item -LiteralPath $fixtureCheckpoint -Force

            $result = & $RecoveryScript -E2EProjectRoot $project -FixtureWorktree $fixture -NewDevBranchName rebuilt
            $result.status | Should -Be 'recovered'
            $newConfig = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $newConfig.devBranchName | Should -Be 'rebuilt'
            $newConfig.worktreePath | Should -Be $target
            $newConfig.developWorktreePath | Should -Be 'preserved'
            (Get-Content -LiteralPath $result.configBackup -Raw -Encoding UTF8 | ConvertFrom-Json).worktreePath | Should -Be $old
            Test-Path -LiteralPath $checkpoint -PathType Leaf | Should -BeTrue
            (Get-Content -LiteralPath $checkpoint -Raw -Encoding UTF8) | Should -Be '{"damaged":true}'
        } finally {
            Remove-Item Env:ITL_TEST_RECOVERY_TARGET_ROOT -ErrorAction SilentlyContinue
            foreach ($path in @($target, $fixture, $old)) {
                if (Test-Path -LiteralPath $path) { & git -C $project worktree remove --force $path 2>$null | Out-Null }
            }
        }
    }
}
