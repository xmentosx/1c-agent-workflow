BeforeAll {
    . (Join-Path $PSScriptRoot "TestSupport.ps1")
    $context = Initialize-WorkflowPesterContext
    $RepoRoot = $context.RepoRoot
    . (Join-Path $RepoRoot "scripts\git-path-list.ps1")
    . (Join-Path $RepoRoot "scripts\quality-contracts.ps1")
    . (Join-Path $RepoRoot "scripts\develop-e2e-qualification.ps1")

    function Write-Utf8Json {
        param([string]$Path, [object]$Value)
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
        [IO.File]::WriteAllText($Path, (($Value | ConvertTo-Json -Depth 16) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    }

    function Get-NonAsciiFixtureSegment {
        return -join ([char[]](0x041F, 0x0443, 0x0442, 0x044C))
    }

    function New-RouterFixture {
        param([string]$Root)
        New-Item -ItemType Directory -Force -Path $Root | Out-Null
        & git -C $Root init -b master *> $null
        & git -C $Root config user.name "ITL Test"
        & git -C $Root config user.email "itl-test@example.invalid"
        $testPath = Join-Path $Root "tests\pester\Fixture.Tests.ps1"
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $testPath) | Out-Null
        [IO.File]::WriteAllText($testPath, "Describe 'fixture' { It 'passes' { `$true | Should -BeTrue } }`n", [Text.UTF8Encoding]::new($false))
        $helperPath = Join-Path $Root ".agents\skills\1c-workflow\scripts\agent-1c.ps1"
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $helperPath) | Out-Null
        [IO.File]::WriteAllText($helperPath, "param([ValidateSet('status')][string]`$Action)`n", [Text.UTF8Encoding]::new($false))
        New-Item -ItemType Directory -Force -Path (Join-Path $Root "scripts") | Out-Null
        [IO.File]::WriteAllText((Join-Path $Root "scripts\check.ps1"), "param()`n", [Text.UTF8Encoding]::new($false))
        $catalog = [ordered]@{
            schemaVersion = 1
            continuationScopes = [ordered]@{ static=@('tests/pester/*'); gate=@('scripts/*'); develop=@('develop/*'); release=@('release/*') }
            developJourneys = [ordered]@{
                names = @('upgrade','fresh')
                fullPaths = @('scripts/check.ps1')
                routes = [ordered]@{
                    upgrade = [ordered]@{ contracts=@('live') }
                    fresh = [ordered]@{ contracts=@('live') }
                }
            }
            retiredTests = [ordered]@{}
            contracts = @([ordered]@{ id='live'; owner='fixture'; primaryTest='tests/pester/Fixture.Tests.ps1'; budgetSeconds=30; paths=@('fixture/*'); tests=@('tests/pester/Fixture.Tests.ps1') })
            lifecycleActions = [ordered]@{ journey=@('status'); boundary=@() }
        }
        Write-Utf8Json -Path (Join-Path $Root "tests\quality-contracts.json") -Value $catalog
        [IO.File]::WriteAllText((Join-Path $Root "README.md"), "base`n", [Text.UTF8Encoding]::new($false))
        & git -C $Root add -- .
        & git -C $Root commit -m base *> $null
        return (& git -C $Root rev-parse HEAD).Trim()
    }
}

Describe "Develop E2E journey qualification router" {
    It "validates exact journey names, exact full paths, and known route contracts" {
        $catalog = Get-QualityContractCatalog -RepositoryRoot $RepoRoot
        Test-QualityContractCatalog -RepositoryRoot $RepoRoot -Catalog $catalog | Should -BeTrue
        @($catalog.developJourneys.names) | Should -Be @('upgrade','fresh')
        @($catalog.developJourneys.fullPaths) | Should -Contain 'scripts/check.ps1'
        @($catalog.developJourneys.fullPaths) | Should -Contain 'scripts/source-delivery.ps1'
        @($catalog.developJourneys.fullPaths) | Should -Contain 'scripts/git-path-list.ps1'

        $invalid = $catalog | ConvertTo-Json -Depth 16 | ConvertFrom-Json
        $invalid.developJourneys.routes.upgrade.contracts = @('missing-owner')
        { Test-QualityContractCatalog -RepositoryRoot $RepoRoot -Catalog $invalid } | Should -Throw '*unknown quality contracts*'
        $invalid = $catalog | ConvertTo-Json -Depth 16 | ConvertFrom-Json
        $invalid.developJourneys.fullPaths = @('scripts/*.ps1')
        { Test-QualityContractCatalog -RepositoryRoot $RepoRoot -Catalog $invalid } | Should -Throw '*unique exact repository-relative paths*'
    }

    It "routes installed owners to both journeys and standalone CodeChecker to none" {
        $installed = Resolve-DevelopE2EJourneyPlan -RepositoryRoot $RepoRoot -ChangedPath @('.agents/skills/1c-workflow/scripts/lib/agent-1c.ondemand-mcp.ps1')
        $installed.reason | Should -Be 'quality-contract-route'
        @($installed.contracts) | Should -Be @('mcp-hosts')
        @($installed.journeys) | Should -Be @('upgrade','fresh')

        $standalone = Resolve-DevelopE2EJourneyPlan -RepositoryRoot $RepoRoot -ChangedPath @('vibecoding1c-mcp-host/codechecker-overlay/retry_policy.py')
        $standalone.reason | Should -Be 'no-develop-journey-route'
        @($standalone.contracts) | Should -Be @('standalone-mcp-host')
        @($standalone.journeys) | Should -BeNullOrEmpty
    }

    It "fails closed for unknown and orchestration paths but skips direct tests" {
        $unknownPath = "new-owner/unknown $(Get-NonAsciiFixtureSegment).ps1"
        $unknown = Resolve-DevelopE2EJourneyPlan -RepositoryRoot $RepoRoot -ChangedPath @($unknownPath)
        $unknown.reason | Should -Be 'unknown-paths-fail-closed'
        @($unknown.journeys) | Should -Be @('upgrade','fresh')
        @($unknown.unknownPaths) | Should -Be @($unknownPath)

        $orchestration = Resolve-DevelopE2EJourneyPlan -RepositoryRoot $RepoRoot -ChangedPath @('scripts/source-delivery.ps1')
        $orchestration.reason | Should -Be 'develop-orchestration-full-path'
        @($orchestration.matchedFullPaths) | Should -Be @('scripts/source-delivery.ps1')
        @($orchestration.journeys) | Should -Be @('upgrade','fresh')
        @(Resolve-DevelopE2EJourneyPlan -RepositoryRoot $RepoRoot -ChangedPath @('scripts/git-path-list.ps1') | Select-Object -ExpandProperty journeys) | Should -Be @('upgrade','fresh')

        $direct = Resolve-DevelopE2EJourneyPlan -RepositoryRoot $RepoRoot -ChangedPath @('tests/pester/DependencyLocks.Tests.ps1')
        $direct.reason | Should -Be 'direct-tests-only'
        @($direct.journeys) | Should -BeNullOrEmpty
    }

    It "reads BaseRef to HEAD paths through the NUL-safe Git helper" {
        $root = Join-Path ([IO.Path]::GetTempPath()) ("itl develop route $(Get-NonAsciiFixtureSegment) " + [guid]::NewGuid().ToString('N'))
        try {
            $base = New-RouterFixture -Root $root
            $emptyPlan = Resolve-DevelopE2EJourneyPlan -RepositoryRoot $root -BaseRef $base
            $emptyPlan.reason | Should -Be 'empty-range-fail-closed'
            @($emptyPlan.journeys) | Should -Be @('upgrade','fresh')
            $relativeChangedPath = "fixture/$(Get-NonAsciiFixtureSegment) with space.txt"
            $changedPath = Join-Path $root $relativeChangedPath.Replace('/', '\')
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $changedPath) | Out-Null
            [IO.File]::WriteAllText($changedPath, "change`n", [Text.UTF8Encoding]::new($false))
            & git -C $root add -- .
            & git -C $root commit -m change *> $null

            $plan = Resolve-DevelopE2EJourneyPlan -RepositoryRoot $root -BaseRef $base
            @($plan.paths) | Should -Contain $relativeChangedPath
            @($plan.contracts) | Should -Be @('live')
            @($plan.journeys) | Should -Be @('upgrade','fresh')

            $beforeDeletion = (& git -C $root rev-parse HEAD).Trim()
            Remove-Item -LiteralPath $changedPath -Force
            & git -C $root add -u -- .
            & git -C $root commit -m delete *> $null
            $deletionPlan = Resolve-DevelopE2EJourneyPlan -RepositoryRoot $root -BaseRef $beforeDeletion
            @($deletionPlan.paths) | Should -Contain $relativeChangedPath
            @($deletionPlan.journeys) | Should -Be @('upgrade','fresh')
        } finally {
            if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
        }
    }

    It "changes the stand-state hash when a tracked stand HEAD or cleanliness changes" {
        $root = Join-Path ([IO.Path]::GetTempPath()) ("itl develop stand state " + [guid]::NewGuid().ToString('N'))
        $developRoot = $root + '-develop'
        try {
            [void](New-RouterFixture -Root $root)
            $configPath = Join-Path $root '.agent-1c\release-e2e.json'
            Write-Utf8Json -Path $configPath -Value ([ordered]@{ developWorktreePath=$developRoot })
            & git -C $root add -- .agent-1c/release-e2e.json
            & git -C $root commit -m 'add stand config' *> $null
            & git -C $root worktree add -b itldev/develop-state $developRoot *> $null

            $cleanHash = Get-DevelopE2EStandStateSha256 -ProjectRoot $root
            Add-Content -LiteralPath (Join-Path $developRoot 'README.md') -Encoding UTF8 -Value 'dirty'
            $dirtyHash = Get-DevelopE2EStandStateSha256 -ProjectRoot $root
            $dirtyHash | Should -Not -Be $cleanHash
            & git -C $developRoot add README.md
            & git -C $developRoot commit -m 'advance stand' *> $null
            (Get-DevelopE2EStandStateSha256 -ProjectRoot $root) | Should -Not -Be $cleanHash
        } finally {
            if (Test-Path -LiteralPath $root) { & git -C $root worktree remove --force $developRoot *> $null }
            if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
            if (Test-Path -LiteralPath $developRoot) { Remove-Item -LiteralPath $developRoot -Recurse -Force }
        }
    }

    It "saves and restores only a hash-bound exact-tree passed route report" {
        $root = Join-Path ([IO.Path]::GetTempPath()) ("itl develop e2e cache $(Get-NonAsciiFixtureSegment) " + [guid]::NewGuid().ToString('N'))
        try {
            [void](New-RouterFixture -Root $root)
            $tree = (& git -C $root rev-parse 'HEAD^{tree}').Trim()
            $identitySha256 = 'a' * 64
            $standStateSha256 = 'c' * 64
            $plan = Resolve-DevelopE2EJourneyPlan -RepositoryRoot $root -ChangedPath @('fixture/change.txt')
            $upgradeReport = New-DevelopE2ERouteReport -RepositoryRoot $root -Plan $plan -Journey upgrade -IdentitySha256 $identitySha256 -StandStateSha256 $standStateSha256 -JourneyResult ([pscustomobject]@{ name='upgrade'; status='passed'; evidencePath='upgrade.json' })
            $freshReport = New-DevelopE2ERouteReport -RepositoryRoot $root -Plan $plan -Journey fresh -IdentitySha256 $identitySha256 -StandStateSha256 $standStateSha256 -JourneyResult ([pscustomobject]@{ name='fresh'; status='passed'; evidencePath='fresh.json' })
            $reportPath = Join-Path $root 'build\upgrade-route-report.json'
            $freshReportPath = Join-Path $root 'build\fresh-route-report.json'
            Write-Utf8Json -Path $reportPath -Value $upgradeReport
            Write-Utf8Json -Path $freshReportPath -Value $freshReport
            $cachePath = Save-DevelopE2EQualification -RepositoryRoot $root -ReportPath $reportPath -Tree $tree -Journey upgrade -IdentitySha256 $identitySha256 -StandStateSha256 $standStateSha256
            $freshCachePath = Save-DevelopE2EQualification -RepositoryRoot $root -ReportPath $freshReportPath -Tree $tree -Journey fresh -IdentitySha256 $identitySha256 -StandStateSha256 $standStateSha256
            $freshCachePath | Should -Not -Be $cachePath
            Test-Path -LiteralPath (Join-Path $freshCachePath 'route-report.json') | Should -BeTrue
            $manifest = Get-Content -LiteralPath (Join-Path $cachePath 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            $manifest.identity.tree | Should -Be $tree
            $manifest.identity.identitySha256 | Should -Be $identitySha256
            $manifest.identity.journey | Should -Be 'upgrade'
            $manifest.identity.reportSha256 | Should -Match '^[a-f0-9]{64}$'

            Remove-Item -LiteralPath $reportPath -Force
            Restore-DevelopE2EQualification -RepositoryRoot $root -OutputPath $reportPath -Tree $tree -Journey upgrade -IdentitySha256 $identitySha256 -StandStateSha256 $standStateSha256 | Should -BeTrue
            Test-DevelopE2ERouteReport -Path $reportPath -Tree $tree -Journey upgrade -IdentitySha256 $identitySha256 -StandStateSha256 $standStateSha256 | Should -BeTrue
            Test-DevelopE2ERouteReport -Path $reportPath -Tree $tree -Journey fresh -IdentitySha256 $identitySha256 -StandStateSha256 $standStateSha256 | Should -BeFalse
            Restore-DevelopE2EQualification -RepositoryRoot $root -OutputPath $reportPath -Tree $tree -Journey upgrade -IdentitySha256 $identitySha256 -StandStateSha256 ('d' * 64) | Should -BeFalse

            Add-Content -LiteralPath (Join-Path $cachePath 'route-report.json') -Encoding UTF8 -Value 'corrupt'
            Remove-Item -LiteralPath $reportPath -Force
            Restore-DevelopE2EQualification -RepositoryRoot $root -OutputPath $reportPath -Tree $tree -Journey upgrade -IdentitySha256 $identitySha256 -StandStateSha256 $standStateSha256 | Should -BeFalse
            Restore-DevelopE2EQualification -RepositoryRoot $root -OutputPath $reportPath -Tree $tree -Journey fresh -IdentitySha256 ('b' * 64) -StandStateSha256 $standStateSha256 | Should -BeFalse
            Restore-DevelopE2EQualification -RepositoryRoot $root -OutputPath $reportPath -Tree ('0' * 40) -Journey upgrade -IdentitySha256 $identitySha256 -StandStateSha256 $standStateSha256 | Should -BeFalse
        } finally {
            if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
        }
    }

    It "recomputes mutable stand identity after a journey before checkpointing it" {
        $check = Get-Content -LiteralPath (Join-Path $RepoRoot 'scripts\check.ps1') -Raw -Encoding UTF8
        $journeyInvocation = $check.IndexOf('Invoke-PowerShellChild -ScriptPath $developScript', [StringComparison]::Ordinal)
        $postJourneyIdentity = $check.IndexOf('$developIdentitySha256 = Get-DevelopE2EIdentitySha256', $journeyInvocation, [StringComparison]::Ordinal)
        $routeReport = $check.IndexOf('$routeReport = New-DevelopE2ERouteReport', $journeyInvocation, [StringComparison]::Ordinal)
        $routeSave = $check.IndexOf('Save-DevelopE2EQualification', $journeyInvocation, [StringComparison]::Ordinal)

        $journeyInvocation | Should -BeGreaterThan -1
        $postJourneyIdentity | Should -BeGreaterThan $journeyInvocation
        $routeReport | Should -BeGreaterThan $postJourneyIdentity
        $routeSave | Should -BeGreaterThan $routeReport
    }
}
