BeforeAll {
    $script:RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    . (Join-Path $script:RepoRoot 'scripts/new-gate-stand.ps1')
    . (Join-Path $script:RepoRoot 'scripts/source-delivery-release-recovery.ps1')
    $script:FixtureRoot = Join-Path $script:RepoRoot 'tests/fixtures/gate-stand'
    function Get-DeliveryCommonGitDirectory { throw 'mocked per test' }
}

Describe 'Per-clone gate stand selection' {
    BeforeEach {
        $script:standsRoot = Join-Path $TestDrive ('stands ' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        $env:ITL_GATE_STANDS_ROOT = $script:standsRoot
        $script:clone = Join-Path $TestDrive 'clone repo'
        Mock Get-DeliveryCommonGitDirectory { Join-Path $script:clone '.git' }
        $script:fixtureId = Get-GateStandFixtureId -Repository $script:RepoRoot
        $script:cloneStand = Get-DeliveryGateStandRoot -CommonGitDirectory (Join-Path $script:clone '.git') -FixtureId $script:fixtureId
    }
    AfterEach { Remove-Item Env:ITL_GATE_STANDS_ROOT -ErrorAction SilentlyContinue }

    It 'derives one stand per clone and fixture with whitespace and Cyrillic' {
        (Split-Path -Parent $script:cloneStand) | Should -Be $script:standsRoot
        $script:cloneStand | Should -Match '\s'
        $script:cloneStand | Should -Match '[^\x00-\x7F]'
        $script:cloneStand | Should -BeLike ('* ' + $script:fixtureId.Substring(0, 8))
    }

    It 'keeps both default bootstrap roots within 35 characters for a long Unicode clone path' {
        Remove-Item Env:ITL_GATE_STANDS_ROOT
        $common = 'C:\Users\xment\OneDrive\' + (-join ([char[]](0x0414,0x043E,0x043A,0x0443,0x043C,0x0435,0x043D,0x0442,0x044B))) + '\1c-agent-workflow\.git'
        $root = Get-DeliveryGateStandRoot -CommonGitDirectory $common -FixtureId $script:fixtureId
        $root.Length | Should -BeLessOrEqual 35
        ($root + '-positive').Length | Should -BeLessOrEqual 35
        $root | Should -Match '\s'
        $root | Should -Match '[^\x00-\x7F]'
        Get-DeliveryGateStandRoot -CommonGitDirectory $common.ToUpperInvariant() -FixtureId $script:fixtureId | Should -Be $root
        Get-DeliveryGateStandRoot -CommonGitDirectory ('D:' + $common.Substring(2)) -FixtureId $script:fixtureId | Should -Not -Be $root
        Get-DeliveryGateStandRoot -CommonGitDirectory $common -FixtureId ('f' * 40) | Should -Not -Be $root
    }

    It 'keeps a requested stand of the current fixture and builds nothing' {
        $requested = Join-Path $TestDrive ('own ' + [char]0x0421)
        [void][IO.Directory]::CreateDirectory((Join-Path $requested '.agent-1c'))
        Write-GateStandMarker -StandRoot $requested -PositiveRoot ($requested + '-positive') -FixtureId $script:fixtureId
        Mock Start-DeliveryProcess { throw 'must not build' }
        Resolve-DeliveryGateStand -Requested $requested | Should -Be $requested
    }

    It 'retains the old stand when the baseline preparation recipe changes' {
        Mock Get-FileHash { [pscustomobject]@{Hash='a'*64} }
        $old=Get-DeliveryGateStandRoot -CommonGitDirectory (Join-Path $script:clone '.git') -FixtureId $script:fixtureId
        Mock Get-FileHash { [pscustomobject]@{Hash='b'*64} }
        $new=Get-DeliveryGateStandRoot -CommonGitDirectory (Join-Path $script:clone '.git') -FixtureId $script:fixtureId
        $new | Should -Not -Be $old
    }

    It 'replaces a legacy stand with the completed clone stand and warns' {
        $legacy = Join-Path $TestDrive 'legacy pm5'
        [void][IO.Directory]::CreateDirectory((Join-Path $legacy '.agent-1c'))
        [void][IO.Directory]::CreateDirectory((Join-Path $script:cloneStand '.agent-1c'))
        Write-GateStandMarker -StandRoot $script:cloneStand -PositiveRoot ($script:cloneStand + '-positive') -FixtureId $script:fixtureId
        Mock Start-DeliveryProcess { throw 'must not build' }
        $output = @(Resolve-DeliveryGateStand -Requested $legacy 3>&1)
        @($output | Where-Object { $_ -is [string] }) | Should -Be @($script:cloneStand)
        (@($output | Where-Object { $_ -is [Management.Automation.WarningRecord] }) -join "`n") | Should -Match 'DELIVERY_GATE_STAND_REPLACED'
    }

    It 'refuses an incomplete clone stand with a continuation instead of reusing or overwriting it: <part>' -ForEach @(@{ part = 'stand' }, @{ part = 'positive twin' }) {
        $partial = if ($part -eq 'stand') { $script:cloneStand } else { $script:cloneStand + '-positive' }
        [void][IO.Directory]::CreateDirectory((Join-Path $partial '.agent-1c'))
        Mock Start-DeliveryProcess { throw 'must not build' }
        { Resolve-DeliveryGateStand -Requested '' } | Should -Throw '*DELIVERY_GATE_STAND_INCOMPLETE*remove it*repeat the same command*'
    }

    It 'builds a missing clone stand once through the builder and accepts only its completion marker' {
        Mock Start-DeliveryProcess {
            $line = $ArgumentList
            $line | Should -Match 'new-gate-stand\.ps1'
            $line | Should -Match ([regex]::Escape($script:cloneStand))
            [void][IO.Directory]::CreateDirectory((Join-Path $script:cloneStand '.agent-1c'))
            Write-GateStandMarker -StandRoot $script:cloneStand -PositiveRoot ($script:cloneStand + '-positive') -FixtureId $script:fixtureId
            [pscustomobject]@{ process = (Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', 'exit 0' -WindowStyle Hidden -PassThru); jobHandle = [IntPtr]::Zero }
        }
        Resolve-DeliveryGateStand -Requested '' -AiRulesSource 'C:\fork' | Should -Be $script:cloneStand
        Should -Invoke Start-DeliveryProcess -Times 1 -Exactly
        Resolve-DeliveryGateStand -Requested '' | Should -Be $script:cloneStand
        Should -Invoke Start-DeliveryProcess -Times 1 -Exactly
    }
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
    It 'prepares the catalog before bootstrap and passes only supported selection parameters: <SupportsCatalog>' -TestCases @(@{SupportsCatalog=$false},@{SupportsCatalog=$true}) {
        param($SupportsCatalog)
        $SourceRoot=Join-Path $TestDrive ('published-'+$SupportsCatalog)
        [void][IO.Directory]::CreateDirectory($SourceRoot)
        $extra=if($SupportsCatalog){',[string]$CatalogProjectId'}else{''}
        Set-Content -LiteralPath (Join-Path $SourceRoot 'install-agent-1c-workflow.ps1') -Value ('param([string]$ProjectRoot,[string]$SourceRoot,[string]$InitMode,[string]$AgentTarget,[switch]$SkipWorkflowSourceFreshnessCheck'+$extra+')')
        $root=Join-Path $TestDrive ('stand-'+$SupportsCatalog)
        $script:Platform='C:\platform\1cv8.exe';$script:AgentTarget='kilocode';$script:AiRulesSource=''
        Mock New-GateStandSnapshot { [pscustomobject]@{path='C:\snapshot';user='svc'} }
        Mock Invoke-GateStandChild {
            (Get-Content -LiteralPath (Join-Path $WorkingRoot '.dev.env') -Raw) | Should -Match 'VIBECODING1C_MCP_REGISTRY_REPO=.*qualification-catalog'
            Test-Path -LiteralPath (Join-Path $WorkingRoot '.agent-1c/mcp/qualification-catalog/.git') | Should -BeTrue
            $Arguments | Should -Not -Contain '-CatalogDecision'
            if($SupportsCatalog){$Arguments | Should -Contain '-CatalogProjectId'}else{$Arguments | Should -Not -Contain '-CatalogProjectId'}
        }
        Initialize-GateStandProject -ProjectRoot $root -Fixture (Read-GateStandFixture -Root $script:FixtureRoot) -Label 'test'
        Should -Invoke Invoke-GateStandChild -Times 1 -Exactly
    }

    It 'keeps the completion marker out of the stand worktree so Prepare sees a clean seed' {
        $root = Join-Path $TestDrive ('marker ' + [char]0x0421)
        [void][IO.Directory]::CreateDirectory($root)
        & git -C $root init -q
        Write-GateStandMarker -StandRoot $root -PositiveRoot ($root + '-positive') -FixtureId ('a' * 40)
        @(& git -C $root status --porcelain --untracked-files=all).Count | Should -Be 0
        (Read-GateStandMarker -StandRoot $root).fixtureId | Should -Be ('a' * 40)
    }

    It 'refuses a stand or positive twin beyond the configured-init path budget before any native work' {
        { Assert-GateStandPathBudget -Path ('C:\g\abcdef12 ' + [char]0x0441 + ' c688c8be-positive') } | Should -Not -Throw
        { Assert-GateStandPathBudget -Path 'C:\itl-gate-stands\1c-agent-workflow Stand c688c8be-positive' } | Should -Throw '*GATE_STAND_PATH_TOO_LONG*'
    }

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
