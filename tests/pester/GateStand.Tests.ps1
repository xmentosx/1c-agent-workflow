BeforeAll {
    $script:RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    . (Join-Path $script:RepoRoot 'scripts/new-gate-stand.ps1')
    $script:FixtureRoot = Join-Path $script:RepoRoot 'tests/fixtures/gate-stand'
}

Describe 'Minimal gate stand fixture' {
    It 'is a supported, editable configuration without product objects' {
        $fixture = Read-GateStandFixture -Root $script:FixtureRoot
        $cf = Join-Path $script:FixtureRoot $fixture.configurationPath
        $support = [IO.File]::ReadAllText((Join-Path $cf 'Ext/ParentConfigurations.bin'), [Text.Encoding]::UTF8)
        $support | Should -Match '^\{6,0,1,'
        $support | Should -Match '"1\.0\.0\.1","ITL",'
        $names = @(Get-ChildItem -LiteralPath $cf -Recurse -File | ForEach-Object { $_.FullName.Substring($cf.Length) })
        # No PM5 prefix; Release requires one mapped common module.
        @($names | Where-Object { $_ -match ([char]0x0443 + [char]0x043F + [char]0x043E + '_') }).Count | Should -Be 0
        @($names | Where-Object { $_ -match '^[\\/]CommonModules[\\/][^\\/]+[\\/]Ext[\\/]Module\.bsl$' }).Count | Should -BeGreaterOrEqual 1
        $root = [IO.File]::ReadAllText((Join-Path $cf 'Configuration.xml'), [Text.Encoding]::UTF8)
        ([regex]::Matches($root, '<Comment(\s[^>]*)?\s*/>|<Comment(\s[^>]*)?>.*?</Comment>')).Count | Should -Be 1
        $bytes = [IO.File]::ReadAllBytes((Join-Path $cf 'Configuration.xml'))
        $bytes[0..2] | Should -Be @(0xEF, 0xBB, 0xBF)
    }

    It 'defines every standard-subsystems entry point the bundled auto-update EPF calls' {
        $fixture = Read-GateStandFixture -Root $script:FixtureRoot
        $cf = Join-Path $script:FixtureRoot $fixture.configurationPath
        $epfSource = Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot '.agents/skills/1c-workflow/tools/auto-update/source') -Recurse -Filter 'Module.bsl' |
            ForEach-Object { [IO.File]::ReadAllText($_.FullName, [Text.Encoding]::UTF8) }
        $entries = @($fixture.autoUpdateEntryPoints)
        $modules = @($entries | ForEach-Object { ($_ -split '\.')[0] } | Sort-Object -Unique)
        # Any call into these module families must be covered by the fixture.
        $called = @([regex]::Matches(($epfSource -join "`n"), '\b(' + (($modules | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')\w*\.(\w+)\(') |
            ForEach-Object { $_.Value.TrimEnd('(') } | Sort-Object -Unique)
        $called | Should -Be @($entries | Sort-Object)
        foreach ($entry in $entries) {
            $module, $method = $entry -split '\.'
            $text = [IO.File]::ReadAllText((Join-Path $cf "CommonModules/$module/Ext/Module.bsl"), [Text.Encoding]::UTF8)
            $text | Should -Match ('\b' + [regex]::Escape($method) + '\([^)]*\)\s+\S+')
        }
    }

    It 'keeps the negative diagnostic bound to a handler the positive form module defines' {
        $fixture = Read-GateStandFixture -Root $script:FixtureRoot
        $positive = [IO.File]::ReadAllText((Join-Path (Join-Path $script:FixtureRoot $fixture.configurationPath) ([string]$fixture.negative.sourcePath).Substring(7)), [Text.Encoding]::UTF8)
        $negative = [IO.File]::ReadAllText((Join-Path $script:FixtureRoot $fixture.negative.replacementPath), [Text.Encoding]::UTF8)
        $handler = [regex]::Match([string]$fixture.negative.diagnostic, '"([^"]+)"$').Groups[1].Value
        $handler | Should -Not -BeNullOrEmpty
        $positive | Should -Match ([regex]::Escape($handler) + '\(')
        $negative | Should -Not -Match ([regex]::Escape($handler) + '\(')
    }
}

Describe 'Gate stand builder' {
    It 'refuses a non-empty target before any native work' {
        $root = Join-Path $TestDrive 'stand with space'
        [void][IO.Directory]::CreateDirectory($root)
        { Assert-GateStandTarget -Path $root } | Should -Not -Throw
        Set-Content -LiteralPath (Join-Path $root 'foreign.txt') -Value 'x'
        { Assert-GateStandTarget -Path $root } | Should -Throw '*GATE_STAND_TARGET_NOT_EMPTY*'
    }

    It 'installs only a clean published workflow source so Capture can admit the baseline' {
        $repo = Join-Path $TestDrive ('src ' + [char]0x041F)
        [void][IO.Directory]::CreateDirectory($repo)
        & git -C $repo init -q; & git -C $repo config user.email t@t; & git -C $repo config user.name t
        Set-Content -LiteralPath (Join-Path $repo 'a.txt') -Value 'a'; & git -C $repo add -A; & git -C $repo commit -qm a
        & git -C $repo update-ref refs/remotes/origin/develop HEAD
        (Resolve-GateStandSource -Requested $repo).temporary | Should -BeFalse
        Set-Content -LiteralPath (Join-Path $repo 'a.txt') -Value 'dirty'
        { Resolve-GateStandSource -Requested $repo } | Should -Throw '*GATE_STAND_SOURCE_UNPUBLISHED*'
        & git -C $repo commit -qam b
        { Resolve-GateStandSource -Requested $repo } | Should -Throw '*GATE_STAND_SOURCE_UNPUBLISHED*'
    }

    It 'configures an in-stand source without repository or interactive protection prompts' {
        $settings = New-GateStandProjectSettings -ProjectRoot $TestDrive -SnapshotPath 'C:\s p\snapshot' -Platform 'C:\p\1cv8.exe' -User 'svc' -Agent 'kilocode'
        $settings.project.sourceUsesRepository | Should -BeFalse
        $settings.project.aiRules.tools | Should -Be @('kilocode')
        $env = @($settings.env)
        foreach ($expected in @('SOURCE_INFOBASE_PATH=C:\s p\snapshot', 'SOURCE_USES_REPOSITORY=false', 'IB_USER=svc', 'PLATFORM_PATH=C:\p\1cv8.exe',
            'SOURCE_INFOBASE_UNSAFE_ACTION_PROTECTION_MODE=confirmed', 'DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP=skip')) {
            @($env | Where-Object { $_ -ceq $expected }).Count | Should -Be 1
        }
        @($env | Where-Object { $_ -like 'SOURCE_INFOBASE_PATH=*' }).Count | Should -Be 1
    }

    It 'records the rejection contract only on the negative stand' {
        $rejection = [ordered]@{ sourcePath = 'src/cf/x.bsl'; sourceSha256 = 'a' * 64; diagnostic = 'd' * 30; positiveProjectRoot = 'C:\p' }
        $negative = New-GateStandReleaseConfig -DevelopBranch 'd' -DevelopWorktree 'C:\d' -ReleaseBranch 'r' -ReleaseWorktree 'C:\r' -Rejection $rejection
        $positive = New-GateStandReleaseConfig -DevelopBranch 'g' -DevelopWorktree 'C:\g' -ReleaseBranch 's' -ReleaseWorktree 'C:\s' -Rejection $null
        $negative.developConfigurationRejection.positiveProjectRoot | Should -Be 'C:\p'
        $negative.preserveWorktreePaths | Should -Be @('C:\d')
        $positive.Contains('developConfigurationRejection') | Should -BeFalse
    }

    It 'commits the Release marker with native module bytes and the exact YAxUnit source oid' {
        $fixture = Read-GateStandFixture -Root $script:FixtureRoot
        $worktree = Join-Path $TestDrive ('w ' + [char]0x041F)
        $module = Join-Path $worktree ([string]$fixture.release.modulePath)
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $module))
        Copy-Item -LiteralPath (Join-Path (Join-Path $script:FixtureRoot $fixture.configurationPath) ([string]$fixture.release.modulePath).Substring(7)) -Destination $module
        [void][IO.Directory]::CreateDirectory((Join-Path $worktree 'tests'))
        & git -C $worktree init -q; & git -C $worktree config user.email t@t; & git -C $worktree config user.name t
        & git -C $worktree add -A; & git -C $worktree commit -qm base
        Add-GateStandReleaseFixture -Worktree $worktree -Fixture $fixture
        @(& git -C $worktree status --porcelain).Count | Should -Be 0
        $bytes = [IO.File]::ReadAllBytes($module)
        $bytes[0..2] | Should -Be @(0xEF, 0xBB, 0xBF)
        $text = [IO.File]::ReadAllText($module, [Text.Encoding]::UTF8)
        $text | Should -Match 'ITLReleaseE2E'
        ($text -replace "`r`n", '') | Should -Not -Match "`n"
        $yaxunit = Get-Content -LiteralPath (Join-Path $worktree 'tests/yaxunit-suites.branch.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $yaxunit.notApplicable[0].sourceOid | Should -Be ((& git -C $worktree rev-parse "HEAD:$($fixture.release.modulePath)").Trim())
        Test-Path -LiteralPath (Join-Path $worktree $fixture.release.featurePath) | Should -BeTrue
    }
}
