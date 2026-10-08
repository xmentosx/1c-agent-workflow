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
        New-Item -ItemType Directory -Force -Path (Join-Path $Root "src\cf"), (Join-Path $Root "tests\features") | Out-Null
        [IO.File]::WriteAllText((Join-Path $Root "src\cf\Configuration.xml"), "<Configuration />`n", [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $Root "tests\features\fixture.feature"), "# language: ru`n", [Text.UTF8Encoding]::new($false))
        $catalog = [ordered]@{
            schemaVersion = 1
            pesterWorkers = [ordered]@{ targetedImplicitDefault=4 }
            continuationScopes = [ordered]@{ static=@('tests/pester/*'); deliveryPostGate=@('post-gate/*'); gate=@('scripts/*'); develop=@('develop/*'); release=@('release/*') }
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
    BeforeAll {
        . (Join-Path $RepoRoot 'scripts/release-qualification.ps1')
        function New-AncestorJourneyFixture {
            $root = Join-Path $TestDrive ('ancestor ' + (Get-NonAsciiFixtureSegment) + ' ' + [guid]::NewGuid().ToString('N'))
            [void](New-RouterFixture -Root $root)
            $catalog = Get-QualityContractCatalog -RepositoryRoot $root
            $catalog.continuationScopes.gate += 'tests/quality-contracts.json'
            $catalog | Add-Member -NotePropertyName budgets -NotePropertyValue ([pscustomobject]@{releaseHardSeconds=14940})
            Write-Utf8Json -Path (Join-Path $root 'tests/quality-contracts.json') -Value $catalog
            $runtime = Join-Path $root ('.agents/skills/1c-workflow/scripts/runtime ' + (Get-NonAsciiFixtureSegment) + '.ps1')
            [IO.File]::WriteAllText($runtime, "'original runtime'`r`n", [Text.UTF8Encoding]::new($true))
            & git -C $root add --all; & git -C $root commit --quiet -m 'captured journey inputs'
            $commit = (& git -C $root rev-parse HEAD).Trim(); $tree = (& git -C $root rev-parse 'HEAD^{tree}').Trim()
            $external = [ordered]@{complete=$true;standStateSha256=('c'*64);runtime=('r'*64);artifacts=@(('a'*64),('b'*64));environment=('e'*64)}
            $inputs = Get-DevelopE2EInputIdentity -RepositoryRoot $root -Journey fresh -Catalog $catalog -ExternalBinding $external
            $inputs | Should -Not -BeNullOrEmpty
            $plan = Resolve-DevelopE2EJourneyPlan -RepositoryRoot $root -ChangedPath @('fixture/change.txt')
            $report = New-DevelopE2ERouteReport -RepositoryRoot $root -Plan $plan -Journey fresh -IdentitySha256 ('a'*64) -StandStateSha256 ('c'*64) -JourneyResult ([pscustomobject]@{name='fresh';status='passed'})
            $reportPath = Join-Path $root '.git/original-report.json'
            Write-Utf8Json -Path $reportPath -Value $report
            $cache = Save-DevelopE2EQualification -RepositoryRoot $root -ReportPath $reportPath -Tree $tree -Journey fresh -IdentitySha256 ('a'*64) -StandStateSha256 ('c'*64) -InputIdentity $inputs
            return [pscustomobject]@{root=$root;catalog=$catalog;external=$external;inputs=$inputs;commit=$commit;tree=$tree;cache=$cache;runtime=$runtime;reportSha=(Get-FileHash -LiteralPath (Join-Path $cache 'route-report.json')).Hash}
        }
        function Publish-AncestorFixtureTargeted {
            param([object]$Fixture)
            $commit = (& git -C $Fixture.root rev-parse HEAD).Trim(); $tree = (& git -C $Fixture.root rev-parse 'HEAD^{tree}').Trim()
            $run = [ordered]@{schemaVersion=3;mode='Targeted';status='passed';exitCode=0;commit=$commit;tree=$tree;finishedAt=[datetime]::UtcNow.ToString('o');stages=@(@{name='pester';status='passed'},@{name='tracked-state';status='passed'},@{name='git-diff-check';status='passed'})}
            Write-Utf8Json -Path (Join-Path $Fixture.root '.git/itl/runs/fixture-targeted-proof.json') -Value $run
            return $tree
        }
        function Find-AncestorFixtureProof {
            param([object]$Fixture,[string]$Tree)
            $inputs = Get-DevelopE2EInputIdentity -RepositoryRoot $Fixture.root -Journey fresh -Catalog $Fixture.catalog -ExternalBinding $Fixture.external
            Get-DevelopE2EAncestorQualification -RepositoryRoot $Fixture.root -Tree $Tree -Journey fresh -IdentitySha256 ('a'*64) -StandStateSha256 ('c'*64) -InputIdentity $inputs
        }
    }

    It 'continues a real Git ancestor after a Release-only budget change and preserves original report bytes' {
        $f = New-AncestorJourneyFixture
        $f.catalog.budgets.releaseHardSeconds = 15540
        Write-Utf8Json -Path (Join-Path $f.root 'tests/quality-contracts.json') -Value $f.catalog
        & git -C $f.root add --all; & git -C $f.root commit --quiet -m 'Release budget only'
        $tree = Publish-AncestorFixtureTargeted -Fixture $f
        $tree | Should -Not -Be $f.tree
        $currentInputs = Get-DevelopE2EInputIdentity -RepositoryRoot $f.root -Journey fresh -Catalog $f.catalog -ExternalBinding $f.external
        $currentInputs.fingerprint | Should -BeExactly $f.inputs.fingerprint
        $proof = Find-AncestorFixtureProof -Fixture $f -Tree $tree
        $proof | Should -Not -BeNullOrEmpty
        $proof.report.repository.commit | Should -BeExactly $f.commit
        $proof.report.repository.tree | Should -BeExactly $f.tree
        (Get-FileHash -LiteralPath $proof.reportPath).Hash | Should -BeExactly $f.reportSha
        $proof.continuation.currentTree | Should -BeExactly $tree
    }

    It 'requires an actual exact Targeted proof and refuses changed runtime or external bindings' {
        $f = New-AncestorJourneyFixture
        [IO.File]::WriteAllText((Join-Path $f.root 'tests/pester/control.Tests.ps1'), '# changed static fixture', [Text.UTF8Encoding]::new($false))
        & git -C $f.root add --all; & git -C $f.root commit --quiet -m 'static fixture only'
        $tree = (& git -C $f.root rev-parse 'HEAD^{tree}').Trim()
        Find-AncestorFixtureProof -Fixture $f -Tree $tree | Should -BeNullOrEmpty
        [void](Publish-AncestorFixtureTargeted -Fixture $f)
        Find-AncestorFixtureProof -Fixture $f -Tree $tree | Should -Not -BeNullOrEmpty
        $f.external.environment='f'*64
        Find-AncestorFixtureProof -Fixture $f -Tree $tree | Should -BeNullOrEmpty
        $f.external.environment='e'*64
        [IO.File]::AppendAllText($f.runtime, "'changed runtime'`r`n", [Text.UTF8Encoding]::new($false))
        & git -C $f.root add --all; & git -C $f.root commit --quiet -m 'runtime changed'
        $tree = Publish-AncestorFixtureTargeted -Fixture $f
        Find-AncestorFixtureProof -Fixture $f -Tree $tree | Should -BeNullOrEmpty
    }

    It 'keeps Develop budget and owner routing visible and falls back for incomplete legacy bindings' {
        $f = New-AncestorJourneyFixture
        $f.catalog.developJourneys.routes.fresh | Add-Member -NotePropertyName hardSeconds -NotePropertyValue 3600
        $changed = Get-DevelopE2EInputIdentity -RepositoryRoot $f.root -Journey fresh -Catalog $f.catalog -ExternalBinding $f.external
        $changed.fingerprint | Should -Not -Be $f.inputs.fingerprint
        $f.external.complete=$false
        Get-DevelopE2EInputIdentity -RepositoryRoot $f.root -Journey fresh -Catalog $f.catalog -ExternalBinding $f.external | Should -BeNullOrEmpty
        $manifestPath=Join-Path $f.cache 'manifest.json'; $manifest=Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8|ConvertFrom-Json
        $manifest.schemaVersion=1
        Write-Utf8Json -Path $manifestPath -Value $manifest
        $f.catalog=Get-QualityContractCatalog -RepositoryRoot $f.root; $f.external.complete=$true
        Find-AncestorFixtureProof -Fixture $f -Tree $f.tree | Should -BeNullOrEmpty
        $restored=Join-Path $f.root '.git/legacy-exact.json'
        Restore-DevelopE2EQualification -RepositoryRoot $f.root -OutputPath $restored -Tree $f.tree -Journey fresh -IdentitySha256 ('a'*64) -StandStateSha256 ('c'*64) | Should -BeTrue
    }

    It 'refuses corrupt cached proof and a newer comparable failed journey while allowing a static failure' {
        $f=New-AncestorJourneyFixture
        [IO.File]::WriteAllText((Join-Path $f.root 'tests/pester/control.Tests.ps1'), '# static', [Text.UTF8Encoding]::new($false))
        & git -C $f.root add --all; & git -C $f.root commit --quiet -m 'static only'
        $tree=Publish-AncestorFixtureTargeted -Fixture $f
        $commit=(& git -C $f.root rev-parse HEAD).Trim()
        $run=[ordered]@{schemaVersion=1;mode='Develop';status='failed';commit=$commit;tree=$tree;finishedAt=[datetime]::UtcNow.AddSeconds(1).ToString('o');stages=@(@{name='pester';status='failed'})}
        $runPath=Join-Path $f.root '.git/itl/runs/new-develop-failure.json';Write-Utf8Json -Path $runPath -Value $run
        Find-AncestorFixtureProof -Fixture $f -Tree $tree | Should -Not -BeNullOrEmpty
        $run.stages=@(@{name='develop-e2e-fresh';status='failed'});Write-Utf8Json -Path $runPath -Value $run
        Find-AncestorFixtureProof -Fixture $f -Tree $tree | Should -BeNullOrEmpty
        $run['journeyInputIdentities']=@{fresh=$f.inputs};Write-Utf8Json -Path $runPath -Value $run
        Find-AncestorFixtureProof -Fixture $f -Tree $tree | Should -BeNullOrEmpty
        $other=Get-DevelopE2EInputIdentity -RepositoryRoot $f.root -Journey fresh -Catalog $f.catalog -ExternalBinding ([ordered]@{complete=$true;environment='different failed environment'})
        $run.journeyInputIdentities.fresh=$other;Write-Utf8Json -Path $runPath -Value $run
        Find-AncestorFixtureProof -Fixture $f -Tree $tree | Should -Not -BeNullOrEmpty
        Remove-Item -LiteralPath $runPath
        [IO.File]::AppendAllText((Join-Path $f.cache 'route-report.json'), 'corrupt', [Text.UTF8Encoding]::new($false))
        Find-AncestorFixtureProof -Fixture $f -Tree $tree | Should -BeNullOrEmpty
    }

    It 'roundtrips complete ancestor provenance through the actual current qualification writer and reader' {
        $f=New-AncestorJourneyFixture
        $f.catalog.budgets.releaseHardSeconds=15540
        Write-Utf8Json -Path (Join-Path $f.root 'tests/quality-contracts.json') -Value $f.catalog
        & git -C $f.root add --all; & git -C $f.root commit --quiet -m 'Release-only budget'
        $tree=Publish-AncestorFixtureTargeted -Fixture $f
        $commit=(& git -C $f.root rev-parse HEAD).Trim()
        $proof=Find-AncestorFixtureProof -Fixture $f -Tree $tree
        $proof | Should -Not -BeNullOrEmpty
        $t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'scripts/check.ps1'),[ref]$t,[ref]$e)
        foreach($name in @('Get-RelativeRepositoryPath','Write-DevelopQualification','Test-DevelopQualification')){
            $definition=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
            . ([scriptblock]::Create($definition.Extent.Text))
        }
        $repoRoot=$f.root;$qualityCatalog=$f.catalog;$E2EProjectRoot=$f.root;$AgentTarget='kilocode'
        $aiRulesRelease=[pscustomobject]@{sourceRoot=$f.root};$resolvedAiRulesSource=$f.root
        $qualificationFullPath=Join-Path $f.root '.git/current-full.json'
        $developQualificationFullPath=Join-Path $f.root '.git/current-develop.json'
        Write-Utf8Json -Path $qualificationFullPath -Value @{status='passed';repository=@{commit=$commit;tree=$tree}}
        $record=[ordered]@{path=$proof.reportPath;sha256=$proof.sha256;evidenceCommit=$f.commit;evidenceTree=$f.tree;identitySha256=('a'*64);standStateSha256=('c'*64);execution='continued';inputIdentity=$proof.inputIdentity;continuation=$proof.continuation}
        $records=[ordered]@{fresh=$record}
        $plan=[pscustomobject]@{kind='itl-develop-e2e-journey-plan';journeys=@('fresh')}
        $combined=Join-Path $f.root '.git/current-combined.json'
        Write-Utf8Json -Path $combined -Value @{kind='itl-develop-e2e-combined';status='passed';candidate=@{tree=$tree};plan=$plan;journeys=$records}
        [void](Write-DevelopQualification -Commit $commit -Tree $tree -ReportPath $combined -IdentitySha256 ('a'*64) -JourneyRecords $records -Plan $plan)
        Mock Get-DevelopE2EInputIdentity {$f.inputs}
        (Test-DevelopQualification -Commit $commit -Tree $tree -ExpectedIdentitySha256 ('a'*64) -ExpectedStandStateSha256 ('c'*64)).reuseKind | Should -BeExactly 'exact-commit'
        $saved=Get-Content -LiteralPath $developQualificationFullPath -Raw -Encoding UTF8|ConvertFrom-Json
        (Get-DevelopE2ECanonicalJsonSha256 -Value $saved.journeys.fresh.inputIdentity.inventory) | Should -BeExactly $f.inputs.fingerprint
        $saved.journeys.fresh.continuation.targetedRunSha256='0'*64
        Write-Utf8Json -Path $developQualificationFullPath -Value $saved
        Test-DevelopQualification -Commit $commit -Tree $tree -ExpectedIdentitySha256 ('a'*64) -ExpectedStandStateSha256 ('c'*64) | Should -BeNullOrEmpty
        (Get-FileHash -LiteralPath $proof.reportPath).Hash | Should -BeExactly $f.reportSha
    }

    It 'invalidates a complete physical binding when only the persisted UI policy alias changes' {
        $f=New-AncestorJourneyFixture
        New-Item -ItemType Directory -Force -Path (Join-Path $f.root '.agent-1c') | Out-Null
        Write-Utf8Json -Path (Join-Path $f.root '.agent-1c/project.json') -Value @{aiRules=@{tools=@('kilocode')}}
        Write-Utf8Json -Path (Join-Path $f.root '.agent-1c/release-e2e.json') -Value @{developWorktreePath=$f.root}
        $artifact=Join-Path $f.root '.git/native fixture bytes.bin'
        [IO.File]::WriteAllBytes($artifact,[byte[]](0,1,2,3))
        $envPath=Join-Path $f.root '.dev.env'
        [IO.File]::WriteAllText($envPath,"PLATFORM_PATH=$artifact`r`nAGENT_1C_UI_TESTING=off`r`n",[Text.UTF8Encoding]::new($true))
        Mock Get-DevelopE2EStandStateSha256 {'c'*64}
        Mock Get-Command {[pscustomobject]@{Source=$artifact}} -ParameterFilter {$Name -contains 'go.exe'}
        $keys=@('ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE','VANESSA_MCP_CLIENT_CFE_PATH','ITL_ONDEMAND_MCP_SOURCE_BUILD_EXE')
        $previous=@{}
        try {
            foreach($key in $keys){$previous[$key]=[Environment]::GetEnvironmentVariable($key,'Process');[Environment]::SetEnvironmentVariable($key,$artifact,'Process')}
            $before=Get-DevelopE2EInputIdentity -RepositoryRoot $f.root -Journey fresh -Catalog $f.catalog -ProjectRoot $f.root -AiRulesSource $f.root -AgentTarget kilocode
            $before | Should -Not -BeNullOrEmpty
            $stable=Get-DeliveryStableDotEnvSha256 -Path $envPath
            [IO.File]::WriteAllText($envPath,"PLATFORM_PATH=$artifact`r`nAGENT_1C_UI_TESTING=essential`r`n",[Text.UTF8Encoding]::new($true))
            (Get-DeliveryStableDotEnvSha256 -Path $envPath) | Should -BeExactly $stable
            $after=Get-DevelopE2EInputIdentity -RepositoryRoot $f.root -Journey fresh -Catalog $f.catalog -ProjectRoot $f.root -AiRulesSource $f.root -AgentTarget kilocode
            $after | Should -Not -BeNullOrEmpty
            $after.fingerprint | Should -Not -Be $before.fingerprint
            $after.inventory.external.uiPolicySha256 | Should -Not -Be $before.inventory.external.uiPolicySha256
            $after.inventory.external.processEnvironmentSha256 | Should -BeExactly $before.inventory.external.processEnvironmentSha256
        } finally {foreach($key in $keys){[Environment]::SetEnvironmentVariable($key,$previous[$key],'Process')}}
    }

    It 'orders the actual tracked input inventory ordinally across PowerShell host collation rules' {
        $f=New-AncestorJourneyFixture
        $path=Join-Path $f.root '.agents/skills/1c-workflow-fast/SKILL.md'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path)|Out-Null
        [IO.File]::WriteAllText($path,"# Unicode input $([char]0x041F)`r`n",[Text.UTF8Encoding]::new($true))
        & git -C $f.root add --all; & git -C $f.root commit --quiet -m 'hyphen versus slash input'
        $identity=Get-DevelopE2EInputIdentity -RepositoryRoot $f.root -Journey fresh -Catalog $f.catalog -ExternalBinding $f.external
        $identity | Should -Not -BeNullOrEmpty
        @($identity.inventory.inputs).Count | Should -Be 4
        $identity.inventory.inputs[0].path | Should -BeExactly '.agents/skills/1c-workflow-fast/SKILL.md'
        $identity.inventory.inputs[1].path | Should -BeExactly '.agents/skills/1c-workflow/scripts/agent-1c.ps1'
    }
    It "validates exact journey names, exact full paths, and known route contracts" {
        $catalog = Get-QualityContractCatalog -RepositoryRoot $RepoRoot
        Test-QualityContractCatalog -RepositoryRoot $RepoRoot -Catalog $catalog | Should -BeTrue
        @($catalog.developJourneys.names) | Should -Be @('upgrade','fresh')
        @($catalog.developJourneys.fullPaths) | Should -Not -Contain 'scripts/check.ps1'
        @($catalog.developJourneys.fullPaths) | Should -Contain 'scripts/git-path-list.ps1'
        @($catalog.developJourneys.fullPaths) | Should -Not -Contain 'scripts/develop-e2e-qualification.ps1'
        @($catalog.developJourneys.fullPaths) | Should -Not -Contain 'tests/quality-contracts.json'
        foreach ($leaf in @('scripts/source-delivery.ps1','scripts/source-delivery-process.ps1','scripts/source-delivery-queue.ps1','scripts/source-delivery-component.ps1','scripts/source-delivery-candidate.ps1')) {
            @($catalog.developJourneys.fullPaths) | Should -Not -Contain $leaf
        }

        $invalid = $catalog | ConvertTo-Json -Depth 16 | ConvertFrom-Json
        $invalid.developJourneys.routes.upgrade.contracts = @('missing-owner')
        { Test-QualityContractCatalog -RepositoryRoot $RepoRoot -Catalog $invalid } | Should -Throw '*unknown quality contracts*'
        $invalid = $catalog | ConvertTo-Json -Depth 16 | ConvertFrom-Json
        $invalid.developJourneys.fullPaths = @('scripts/*.ps1')
        { Test-QualityContractCatalog -RepositoryRoot $RepoRoot -Catalog $invalid } | Should -Throw '*unique exact repository-relative paths*'
    }

    It "routes each installed owner to the journey that exercises its behavior" {
        $installed = Resolve-DevelopE2EJourneyPlan -RepositoryRoot $RepoRoot -ChangedPath @('.agents/skills/1c-workflow/scripts/lib/agent-1c.ondemand-mcp.ps1')
        $installed.reason | Should -Be 'quality-contract-route'
        @($installed.contracts) | Should -Be @('mcp-hosts')
        @($installed.journeys) | Should -Be @('fresh')
        @(Resolve-DevelopE2EJourneyPlan -RepositoryRoot $RepoRoot -ChangedPath @('templates/dependency-lock.json') | Select-Object -ExpandProperty journeys) | Should -Be @('fresh')
        @(Resolve-DevelopE2EJourneyPlan -RepositoryRoot $RepoRoot -ChangedPath @('scripts/build-ai-rules-release.ps1') | Select-Object -ExpandProperty journeys) | Should -Be @('upgrade')
        @(Resolve-DevelopE2EJourneyPlan -RepositoryRoot $RepoRoot -ChangedPath @('.agents/skills/1c-workflow/scripts/lib/agent-1c.verification-modes.ps1') | Select-Object -ExpandProperty journeys) | Should -Be @('upgrade','fresh')

        $standalone = Resolve-DevelopE2EJourneyPlan -RepositoryRoot $RepoRoot -ChangedPath @('vibecoding1c-mcp-host/codechecker-overlay/retry_policy.py')
        $standalone.reason | Should -Be 'no-develop-journey-route'
        @($standalone.contracts) | Should -Be @('standalone-mcp-host')
        @($standalone.journeys) | Should -BeNullOrEmpty

        foreach ($leaf in @('process','queue','component')) {
            $path = "scripts/source-delivery-$leaf.ps1"
            $plan = Resolve-DevelopE2EJourneyPlan -RepositoryRoot $RepoRoot -ChangedPath @($path)
            $plan.reason | Should -Be 'no-develop-journey-route'
            @($plan.contracts) | Should -Be @("source-delivery-$leaf")
            @($plan.journeys) | Should -BeNullOrEmpty
        }
        $entrypoint = Resolve-DevelopE2EJourneyPlan -RepositoryRoot $RepoRoot -ChangedPath @('scripts/source-delivery.ps1')
        @($entrypoint.contracts) | Should -Be @('source-delivery-entrypoint'); @($entrypoint.journeys) | Should -BeNullOrEmpty
        $candidate = Resolve-DevelopE2EJourneyPlan -RepositoryRoot $RepoRoot -ChangedPath @('scripts/source-delivery-candidate.ps1')
        @($candidate.contracts) | Should -Be @('source-delivery-candidate'); @($candidate.journeys) | Should -BeNullOrEmpty
        $cleanup = Resolve-DevelopE2EJourneyPlan -RepositoryRoot $RepoRoot -ChangedPath @('scripts/develop-e2e-cleanup.ps1')
        @($cleanup.contracts) | Should -Be @('source-delivery-cleanup'); @($cleanup.journeys) | Should -BeNullOrEmpty
    }

    It "continues source OpenSpec Markdown with exact Targeted proof but rejects executable and configuration neighbors" {
        . (Join-Path $RepoRoot 'scripts/release-qualification.ps1')
        $catalog = Get-QualityContractCatalog -RepositoryRoot $RepoRoot
        $fixtureRoot = Join-Path $TestDrive ("OpenSpec continuation $(Get-NonAsciiFixtureSegment) with spaces")
        New-RouterFixture -Root $fixtureRoot | Out-Null
        Copy-Item -LiteralPath (Join-Path $RepoRoot 'tests/quality-contracts.json') -Destination (Join-Path $fixtureRoot 'tests/quality-contracts.json')
        & git -C $fixtureRoot add -- tests/quality-contracts.json
        & git -C $fixtureRoot commit -m 'use production continuation catalog' *> $null
        $base = (& git -C $fixtureRoot rev-parse HEAD).Trim()
        $docPaths = @(
            'openspec/changes/upgrade-ai-rules-upstream-20a083e5/test-plan.md',
            'openspec/changes/upgrade-ai-rules-upstream-20a083e5/evidence/gate6-r41-qualification.md'
        )
        foreach ($relative in $docPaths) {
            $path = Join-Path $fixtureRoot $relative
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
            [IO.File]::WriteAllText($path, "# Source acceptance record`n", [Text.UTF8Encoding]::new($false))
        }
        & git -C $fixtureRoot add -- @docPaths
        & git -C $fixtureRoot commit -m 'record source acceptance' *> $null
        $commit = (& git -C $fixtureRoot rev-parse HEAD).Trim()
        $tree = (& git -C $fixtureRoot rev-parse 'HEAD^{tree}').Trim()
        $arguments = @{ RepositoryRoot=$fixtureRoot; QualifiedCommit=$base; CurrentCommit=$commit; CurrentTree=$tree }
        Get-WorkflowContinuationProof @arguments | Should -BeNullOrEmpty
        $runPath = Join-Path (Get-RepositoryCommonGitDirectory -RepositoryRoot $fixtureRoot) 'itl/runs/20261007-000000-000-targeted-fixture.json'
        $run = [ordered]@{
            schemaVersion=3; id=[guid]::NewGuid().ToString('N'); mode='Targeted'; status='passed'; exitCode=0
            commit=$commit; tree=$tree; startedAt='2026-10-07T00:00:00Z'; finishedAt='2026-10-07T00:00:01Z'
            durationMs=1000; stages=@(
                @{ name='pester'; status='passed' },
                @{ name='git-diff-check'; status='passed' },
                @{ name='tracked-state'; status='passed' }
            )
        }
        Write-Utf8Json -Path $runPath -Value $run
        $proof = Get-WorkflowContinuationProof @arguments
        $proof | Should -Not -BeNullOrEmpty
        @($proof.paths | Sort-Object) | Should -Be @($docPaths | Sort-Object)
        @($proof.scopes) | Should -Be @('static')
        $proof.targetedRunSha256 | Should -Be (Get-FileHash -LiteralPath $runPath).Hash.ToLowerInvariant()
        Test-RecordedWorkflowContinuation -Record $proof -Commit $commit -Tree $tree | Should -BeTrue
        $journeyPlan = Resolve-DevelopE2EJourneyPlan -RepositoryRoot $RepoRoot -ChangedPath @($proof.paths) -Catalog $catalog
        $journeyPlan.reason | Should -Be 'no-develop-journey-route'
        @($journeyPlan.journeys) | Should -BeNullOrEmpty

        $run.tree = '0' * 40
        Write-Utf8Json -Path $runPath -Value $run
        Get-WorkflowContinuationProof @arguments | Should -BeNullOrEmpty
        $run.tree = $tree
        Write-Utf8Json -Path $runPath -Value $run
        [IO.File]::AppendAllText($runPath, ' ', [Text.UTF8Encoding]::new($false))
        Test-RecordedWorkflowContinuation -Record $proof -Commit $commit -Tree $tree | Should -BeFalse

        foreach ($relative in @(
            'openspec/changes/upgrade-ai-rules-upstream-20a083e5/hook.ps1',
            'openspec/changes/upgrade-ai-rules-upstream-20a083e5/config.yaml',
            'openspec/changes/upgrade-ai-rules-upstream-20a083e5/config.json'
        )) {
            $previous = (& git -C $fixtureRoot rev-parse HEAD).Trim()
            [IO.File]::WriteAllText((Join-Path $fixtureRoot $relative), 'unclassified input', [Text.UTF8Encoding]::new($false))
            & git -C $fixtureRoot add -- $relative
            & git -C $fixtureRoot commit -m 'add non-Markdown neighbor' *> $null
            $run.commit = (& git -C $fixtureRoot rev-parse HEAD).Trim()
            $run.tree = (& git -C $fixtureRoot rev-parse 'HEAD^{tree}').Trim()
            Write-Utf8Json -Path $runPath -Value $run
            Get-ExactTargetedRunProof -RepositoryRoot $fixtureRoot -Commit $run.commit -Tree $run.tree | Should -Not -BeNullOrEmpty
            Get-WorkflowContinuationProof -RepositoryRoot $fixtureRoot -QualifiedCommit $previous -CurrentCommit $run.commit -CurrentTree $run.tree | Should -BeNullOrEmpty -Because $relative
        }
        @(Get-RepositoryGitPathList -RepositoryRoot $fixtureRoot -Arguments @('diff', '--name-only', '-z', 'HEAD', '--')).Count | Should -Be 0
    }

    It "blocks unknown ownership, fails closed for orchestration paths, and skips direct tests" {
        $unknownPath = "new-owner/unknown $(Get-NonAsciiFixtureSegment).ps1"
        { Resolve-DevelopE2EJourneyPlan -RepositoryRoot $RepoRoot -ChangedPath @($unknownPath) } | Should -Throw '*QUALITY_OWNER_MISSING*'

        $orchestration = Resolve-DevelopE2EJourneyPlan -RepositoryRoot $RepoRoot -ChangedPath @('scripts/invoke-develop-e2e.ps1')
        $orchestration.reason | Should -Be 'develop-orchestration-full-path'
        @($orchestration.matchedFullPaths) | Should -Be @('scripts/invoke-develop-e2e.ps1')
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

    It "ignores unrelated clean HEAD advances but invalidates tracked dirt and runtime content changes" {
        $root = Join-Path ([IO.Path]::GetTempPath()) ("itl develop stand state " + [guid]::NewGuid().ToString('N'))
        $developRoot = $root + '-develop'
        try {
            [void](New-RouterFixture -Root $root)
            $configPath = Join-Path $root '.agent-1c\release-e2e.json'
            Write-Utf8Json -Path $configPath -Value ([ordered]@{ developWorktreePath=$developRoot })
            & git -C $root add -- .agent-1c/release-e2e.json
            & git -C $root commit -m 'add stand config' *> $null
            & git -C $root worktree add --quiet -b itldev/develop-state $developRoot *> $null

            $previousPreference = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Stop'
                $cleanState = Get-DevelopE2EStandContentState -ProjectRoot $root
            } finally {
                $ErrorActionPreference = $previousPreference
            }
            [string]$cleanState.repositories[0].content.'src/cfe' | Should -Be ''
            [string]$cleanState.repositories[1].content.'src/cfe' | Should -Be ''
            $cleanHash = Get-DevelopE2ECanonicalJsonSha256 -Value $cleanState
            $legacyState = [ordered]@{ schemaVersion=1; repositories=@(
                [ordered]@{ role='master'; path=[IO.Path]::GetFullPath($root).ToLowerInvariant(); head=(& git -C $root rev-parse HEAD).Trim(); trackedClean=$true },
                [ordered]@{ role='develop'; path=[IO.Path]::GetFullPath($developRoot).ToLowerInvariant(); head=(& git -C $developRoot rev-parse HEAD).Trim(); trackedClean=$true }
            ) }
            $legacyHash = Get-DevelopE2ECanonicalJsonSha256 -Value $legacyState
            Add-Content -LiteralPath (Join-Path $developRoot 'README.md') -Encoding UTF8 -Value 'dirty'
            $dirtyHash = Get-DevelopE2EStandStateSha256 -ProjectRoot $root
            $dirtyHash | Should -Not -Be $cleanHash
            & git -C $developRoot add README.md
            & git -C $developRoot commit -m 'advance stand' *> $null
            (Get-DevelopE2EStandStateSha256 -ProjectRoot $root) | Should -Be $cleanHash
            Test-DevelopE2ELegacyStandContinuation -ProjectRoot $root -RecordedSha256 $legacyHash | Should -BeTrue

            Add-Content -LiteralPath (Join-Path $developRoot 'src\cf\Configuration.xml') -Encoding UTF8 -Value '<!-- runtime change -->'
            & git -C $developRoot add src/cf/Configuration.xml
            & git -C $developRoot commit -m 'change runtime content' *> $null
            (Get-DevelopE2EStandStateSha256 -ProjectRoot $root) | Should -Not -Be $cleanHash
            Test-DevelopE2ELegacyStandContinuation -ProjectRoot $root -RecordedSha256 $legacyHash | Should -BeFalse
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
        $helperStart = $check.IndexOf('function Ensure-DevelopE2ERoute', [StringComparison]::Ordinal)
        $helperEnd = $check.IndexOf('function ConvertTo-NativeArgument', $helperStart, [StringComparison]::Ordinal)
        $journeyInvocation = $check.IndexOf('Invoke-PowerShellChild -ScriptPath $script:developScript', $helperStart, [StringComparison]::Ordinal)
        $postJourneyIdentity = $check.IndexOf('$identitySha256 = Get-DevelopE2EIdentitySha256', $journeyInvocation, [StringComparison]::Ordinal)
        $routeReport = $check.IndexOf('$routeReport = New-DevelopE2ERouteReport', $journeyInvocation, [StringComparison]::Ordinal)
        $routeSave = $check.IndexOf('Save-DevelopE2EQualification', $journeyInvocation, [StringComparison]::Ordinal)
        $ensureCall = $check.IndexOf('$routePath = Ensure-DevelopE2ERoute', $helperEnd, [StringComparison]::Ordinal)
        $postStageIdentity = $check.IndexOf('$developIdentitySha256 = Get-DevelopE2EIdentitySha256', $ensureCall, [StringComparison]::Ordinal)
        $routeValidation = $check.IndexOf('Test-DevelopE2ERouteReport -Path $routePath', $postStageIdentity, [StringComparison]::Ordinal)

        $helperStart | Should -BeGreaterThan -1
        $helperEnd | Should -BeGreaterThan $helperStart
        $journeyInvocation | Should -BeGreaterThan -1
        $postJourneyIdentity | Should -BeGreaterThan $journeyInvocation
        $routeReport | Should -BeGreaterThan $postJourneyIdentity
        $routeSave | Should -BeGreaterThan $routeReport
        $ensureCall | Should -BeGreaterThan $helperEnd
        $postStageIdentity | Should -BeGreaterThan $ensureCall
        $routeValidation | Should -BeGreaterThan $postStageIdentity
    }

    It "scopes the client MCP build source to E2E and restores it after project overwrite and failure" {
        . (Join-Path $RepoRoot 'scripts/stand-env-identity.ps1')
        $names = @('VANESSA_MCP_CLIENT_CFE_PATH', 'ITL_VANESSA_MCP_CLIENT_SOURCE_BUILD_CFE')
        $saved = @{}
        foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
        try {
            $root = Join-Path $TestDrive 'Нативный источник E2E с пробелом'
            [void][IO.Directory]::CreateDirectory($root)
            $candidate = Join-Path $root 'client_mcp.v0.6.5-itl-r1.cfe'
            [IO.File]::WriteAllBytes($candidate, [Text.Encoding]::UTF8.GetBytes('scoped input bytes'))
            $hash = (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash
            [Environment]::SetEnvironmentVariable($names[0], $candidate, 'Process')
            [Environment]::SetEnvironmentVariable($names[1], 'previous-owner-source', 'Process')
            $scope = Enter-SourceE2EClientMcpBuildScope
            try {
                [Environment]::SetEnvironmentVariable($names[0], 'old-persisted-project-path', 'Process')
                [Environment]::GetEnvironmentVariable($names[1], 'Process') | Should -BeExactly $candidate
                throw 'original E2E stage failed'
            } catch {
                $_.Exception.Message | Should -BeExactly 'original E2E stage failed'
            } finally {
                Exit-SourceE2EClientMcpBuildScope -Scope $scope
            }
            [Environment]::GetEnvironmentVariable($names[1], 'Process') | Should -BeExactly 'previous-owner-source'
            (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash | Should -BeExactly $hash
        } finally {
            foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
        }
    }

    It "does not inject an absent client MCP source and confines scope wiring to actual E2E stages" {
        . (Join-Path $RepoRoot 'scripts/stand-env-identity.ps1')
        $names = @('VANESSA_MCP_CLIENT_CFE_PATH', 'ITL_VANESSA_MCP_CLIENT_SOURCE_BUILD_CFE')
        $saved = @{}
        foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
        try {
            [Environment]::SetEnvironmentVariable($names[0], $null, 'Process')
            [Environment]::SetEnvironmentVariable($names[1], 'foreign-inherited-source', 'Process')
            $scope = Enter-SourceE2EClientMcpBuildScope
            try { [Environment]::GetEnvironmentVariable($names[1], 'Process') | Should -BeNullOrEmpty }
            finally { Exit-SourceE2EClientMcpBuildScope -Scope $scope }
            [Environment]::GetEnvironmentVariable($names[1], 'Process') | Should -BeExactly 'foreign-inherited-source'
        } finally {
            foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
        }
        foreach ($name in @('invoke-develop-e2e.ps1','invoke-release-e2e.ps1')) {
            $tokens=$null; $errors=$null
            $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot ('scripts/' + $name)),[ref]$tokens,[ref]$errors)
            @($errors) | Should -BeNullOrEmpty
            foreach ($commandName in @('Enter-SourceE2EClientMcpBuildScope','Exit-SourceE2EClientMcpBuildScope')) {
                $calls=@($ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq $commandName },$true))
                $calls.Count | Should -Be 1
                $parent=$calls[0].Parent
                while($parent -and $parent -isnot [Management.Automation.Language.TryStatementAst]){$parent=$parent.Parent}
                $parent | Should -Not -BeNullOrEmpty
                $block=if($commandName -like 'Enter-*'){$parent.Body}else{$parent.Finally}
                $calls[0].Extent.StartOffset | Should -BeGreaterOrEqual $block.Extent.StartOffset
                $calls[0].Extent.EndOffset | Should -BeLessOrEqual $block.Extent.EndOffset
            }
        }
        (Get-Content -LiteralPath (Join-Path $RepoRoot 'scripts/check.ps1') -Raw -Encoding UTF8) | Should -Not -Match 'Enter-SourceE2EClientMcpBuildScope'
    }
    It "passes the scoped client MCP source to the real Release preflight refresh child before checkpointing" {
        . (Join-Path $RepoRoot 'scripts/stand-env-identity.ps1')
        $tokens=$null; $errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'scripts/invoke-release-e2e.ps1'),[ref]$tokens,[ref]$errors)
        @($errors) | Should -BeNullOrEmpty
        $call=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Sync-E2EWorktreeFromMaster'},$true))[0]
        $scopeTry=$call.Parent
        while($scopeTry -and $scopeTry -isnot [Management.Automation.Language.TryStatementAst]){$scopeTry=$scopeTry.Parent}
        $scopeTry | Should -Not -BeNullOrEmpty
        $scopeTry.Body.Statements[0].Extent.Text | Should -Match 'Enter-SourceE2EClientMcpBuildScope'
        $scopeTry.Finally.Extent.Text | Should -Match 'Exit-SourceE2EClientMcpBuildScope'
        $sync=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Sync-E2EWorktreeFromMaster'},$true)
        . ([scriptblock]::Create($sync.Extent.Text))
        $base=Join-Path $TestDrive 'Подготовка Release с пробелом'
        $worktreePath=Join-Path $base 'Рабочая ветка'
        [void][IO.Directory]::CreateDirectory((Join-Path $worktreePath '.agent-1c'))
        & git -C $worktreePath init -b master *> $null
        & git -C $worktreePath config user.name 'ITL Test'
        & git -C $worktreePath config user.email 'test@example.invalid'
        [IO.File]::WriteAllText((Join-Path $worktreePath '.gitignore'), "/.agent-1c/`n/.dev.env`n",[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $worktreePath 'baseline.txt'),'before',[Text.Encoding]::ASCII)
        & git -C $worktreePath add .gitignore baseline.txt
        & git -C $worktreePath commit -m 'test: original branch baseline' *> $null
        & git -C $worktreePath branch itldev/preflight
        [IO.File]::WriteAllText((Join-Path $worktreePath 'baseline.txt'),'new master',[Text.Encoding]::ASCII)
        & git -C $worktreePath add baseline.txt
        & git -C $worktreePath commit -m 'test: pending preflight master refresh' *> $null
        & git -C $worktreePath checkout --quiet itldev/preflight *> $null
        $LASTEXITCODE | Should -Be 0
        Copy-Item -LiteralPath (Join-Path $RepoRoot 'templates/project.json') -Destination (Join-Path $worktreePath '.agent-1c/project.json')
        $candidate=Join-Path $base 'client_mcp.v0.6.5-itl-r1.cfe'
        [IO.File]::WriteAllBytes($candidate,[Text.Encoding]::UTF8.GetBytes('native candidate fixture'))
        $oldPath=Join-Path $base 'old shared d109/client_mcp.cfe'
        [IO.File]::WriteAllText((Join-Path $worktreePath '.dev.env'),"VANESSA_MCP_CLIENT_CFE_PATH=$oldPath`r`n",[Text.UTF8Encoding]::new($true))
        $childPath=Join-Path $base 'Дочерний helper.ps1'
        $childResultPath=Join-Path $base 'Дочерний результат.json'
        $childLines=@(
            'param([string]$HelperPath,[string]$ProjectRoot,[string]$ResultPath)',
            '$ErrorActionPreference="Stop"',
            '. $HelperPath -ProjectRoot $ProjectRoot -Action help *> $null',
            'Save-VanessaAutomationSettingsToDotEnv -EpfPath (Join-Path $ProjectRoot "fixture.epf") -Version "fixture" *> $null',
            '[IO.File]::WriteAllText($ResultPath, (([ordered]@{ source=[Environment]::GetEnvironmentVariable("ITL_VANESSA_MCP_CLIENT_SOURCE_BUILD_CFE","Process"); setting=Get-EnvValue -Name "VANESSA_MCP_CLIENT_CFE_PATH" } | ConvertTo-Json)),[Text.UTF8Encoding]::new($false))'
        )
        [IO.File]::WriteAllText($childPath,($childLines -join "`r`n"),[Text.UTF8Encoding]::new($true))
        function Invoke-E2EHelper {
            param([string]$Action,[int]$TimeoutSeconds)
            $Action | Should -BeExactly 'refresh-dev-branch'
            $TimeoutSeconds | Should -Be 7200
            & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $childPath -HelperPath (Join-Path $RepoRoot '.agents/skills/1c-workflow/scripts/agent-1c.ps1') -ProjectRoot $worktreePath -ResultPath $childResultPath *> (Join-Path $base 'preflight-child.log')
            $LASTEXITCODE | Should -Be 0
            & git -C $worktreePath merge --ff-only master *> $null
            $LASTEXITCODE | Should -Be 0
        }
        $names=@('VANESSA_MCP_CLIENT_CFE_PATH','ITL_VANESSA_MCP_CLIENT_SOURCE_BUILD_CFE')
        $saved=@{}
        foreach($name in $names){$saved[$name]=[Environment]::GetEnvironmentVariable($name,'Process')}
        try {
            [Environment]::SetEnvironmentVariable($names[0],$candidate,'Process')
            [Environment]::SetEnvironmentVariable($names[1],'previous-owner-source','Process')
            try {
                . ([scriptblock]::Create($scopeTry.Body.Statements[0].Extent.Text))
                (Sync-E2EWorktreeFromMaster) | Should -BeTrue
            } finally {
                . ([scriptblock]::Create($scopeTry.Finally.Statements[0].Extent.Text))
            }
            $result=Get-Content -LiteralPath $childResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $result.source | Should -BeExactly $candidate
            $result.setting | Should -BeExactly $oldPath
            [Environment]::GetEnvironmentVariable($names[1],'Process') | Should -BeExactly 'previous-owner-source'
        } finally {
            foreach($name in $names){[Environment]::SetEnvironmentVariable($name,$saved[$name],'Process')}
        }
    }

    It "restores the client MCP source on an actual Release rejection before preflight" {
        $names=@('VANESSA_MCP_CLIENT_CFE_PATH','ITL_VANESSA_MCP_CLIENT_SOURCE_BUILD_CFE')
        $saved=@{}
        foreach($name in $names){$saved[$name]=[Environment]::GetEnvironmentVariable($name,'Process')}
        try {
            [Environment]::SetEnvironmentVariable($names[0],(Join-Path $TestDrive 'Новый кандидат с пробелом/client_mcp.cfe'),'Process')
            [Environment]::SetEnvironmentVariable($names[1],'previous-owner-source','Process')
            { & (Join-Path $RepoRoot 'scripts/invoke-release-e2e.ps1') -ProjectRoot (Join-Path $TestDrive 'Стенд без настроек') -AiRulesSource $RepoRoot } | Should -Throw '*Dedicated E2E stand config is missing*'
            [Environment]::GetEnvironmentVariable($names[1],'Process') | Should -BeExactly 'previous-owner-source'
        } finally {
            foreach($name in $names){[Environment]::SetEnvironmentVariable($name,$saved[$name],'Process')}
        }
    }
    It "keeps Develop proof identity across helper-owned env changes and invalidates semantic changes" {
        . (Join-Path $RepoRoot 'scripts/stand-env-identity.ps1')
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'scripts/check.ps1'), [ref]$tokens, [ref]$errors)
        @($errors) | Should -BeNullOrEmpty
        $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-DevelopE2EIdentitySha256' }, $true)
        $definition | Should -Not -BeNullOrEmpty
        . ([scriptblock]::Create($definition.Extent.Text))

        $stand = Join-Path $TestDrive ("proof $(Get-NonAsciiFixtureSegment) with spaces")
        $configRoot = Join-Path $stand '.agent-1c'
        New-Item -ItemType Directory -Force -Path $configRoot | Out-Null
        [IO.File]::WriteAllText((Join-Path $configRoot 'project.json'), '{}', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $configRoot 'release-e2e.json'), '{}', [Text.UTF8Encoding]::new($false))
        $envPath = Join-Path $stand '.dev.env'
        $context = [pscustomobject]@{ artifacts=[pscustomobject]@{ vanessaAutomation=[pscustomobject]@{ sha256='a' * 64 } }; managedPackage=[pscustomobject]@{ sha256='b' * 64 } }
        $fork = [pscustomobject]@{ commit='c' * 40; tree='d' * 40; tag='test-tag' }
        [IO.File]::WriteAllText($envPath, "PLATFORM_PATH=C:\1cv8`nITL_ACTIVE_CONTEXT_UPDATED_AT=first`nROCTUP_MCP_PORT=6001`n", [Text.UTF8Encoding]::new($false))
        $before = Get-DevelopE2EIdentitySha256 -ReleaseContext $context -ForkIdentity $fork -ProjectRoot $stand
        $kiloIdentity = Get-DevelopE2EIdentitySha256 -ReleaseContext $context -ForkIdentity $fork -ProjectRoot $stand -AgentTarget kilocode
        (Get-DevelopE2EIdentitySha256 -ReleaseContext $context -ForkIdentity $fork -ProjectRoot $stand -AgentTarget codex) | Should -Not -Be $kiloIdentity
        [IO.File]::WriteAllText($envPath, "PLATFORM_PATH=C:\1cv8`nITL_ACTIVE_CONTEXT_UPDATED_AT=second`nROCTUP_MCP_PORT=6002`nEXPORT_PATH=src/cf`n", [Text.UTF8Encoding]::new($false))
        (Get-DevelopE2EIdentitySha256 -ReleaseContext $context -ForkIdentity $fork -ProjectRoot $stand) | Should -Be $before
        [IO.File]::WriteAllText($envPath, "PLATFORM_PATH=C:\new-1cv8`nITL_ACTIVE_CONTEXT_UPDATED_AT=third`n", [Text.UTF8Encoding]::new($false))
        (Get-DevelopE2EIdentitySha256 -ReleaseContext $context -ForkIdentity $fork -ProjectRoot $stand) | Should -Not -Be $before
    }

    It "accepts writer-produced documentation qualification with continued routes while rejecting invalid evidence" {
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'scripts/check.ps1'), [ref]$tokens, [ref]$errors)
        @($errors) | Should -BeNullOrEmpty
        foreach ($name in @('Get-RelativeRepositoryPath', 'Write-DevelopQualification', 'Test-DevelopQualification')) {
            $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
            . ([scriptblock]::Create($definition.Extent.Text))
        }
        . (Join-Path $RepoRoot 'scripts/release-qualification.ps1')
        $sourceRoot = $RepoRoot
        $repoRoot = Join-Path $TestDrive ("qualification $(Get-NonAsciiFixtureSegment) with spaces")
        $baseCommit = New-RouterFixture -Root $repoRoot
        $baseTree = (& git -C $repoRoot rev-parse 'HEAD^{tree}').Trim()
        $oldIdentity = 'a' * 64
        $currentIdentity = 'b' * 64
        $standHash = 'c' * 64
        $runtimePlan = Resolve-DevelopE2EJourneyPlan -RepositoryRoot $repoRoot -ChangedPath @('fixture/change.txt')
        $records = [ordered]@{}
        foreach ($journey in @('upgrade', 'fresh')) {
            $routePath = Join-Path $repoRoot "build/$journey.json"
            $route = New-DevelopE2ERouteReport -RepositoryRoot $repoRoot -Plan $runtimePlan -Journey $journey -IdentitySha256 $oldIdentity -StandStateSha256 $standHash -JourneyResult ([pscustomobject]@{ name=$journey; status='passed' })
            Write-Utf8Json -Path $routePath -Value $route
            $records[$journey] = [ordered]@{
                path=$routePath; sha256=(Get-FileHash -LiteralPath $routePath).Hash.ToLowerInvariant()
                evidenceCommit=$baseCommit; evidenceTree=$baseTree
                identitySha256=$oldIdentity; standStateSha256=$standHash; execution='continued'
            }
        }
        Add-Content -LiteralPath (Join-Path $repoRoot 'README.md') -Value 'documentation change'
        & git -C $repoRoot add -- README.md
        & git -C $repoRoot commit -m documentation *> $null
        $commit = (& git -C $repoRoot rev-parse HEAD).Trim()
        $tree = (& git -C $repoRoot rev-parse 'HEAD^{tree}').Trim()
        $plan = Resolve-DevelopE2EJourneyPlan -RepositoryRoot $sourceRoot -ChangedPath @('.agents/skills/1c-workflow/references/tooling-recovery.md')
        @($plan.journeys) | Should -BeNullOrEmpty
        $qualificationFullPath = Join-Path $repoRoot 'build/qualification/full.json'
        $developQualificationFullPath = Join-Path $repoRoot 'build/qualification/develop.json'
        Write-Utf8Json -Path $qualificationFullPath -Value @{ status='passed'; repository=@{ commit=$commit; tree=$tree } }
        $combinedPath = Join-Path $repoRoot 'build/combined.json'
        $combined = [ordered]@{ kind='itl-develop-e2e-combined'; status='passed'; candidate=@{ tree=$tree }; plan=$plan; journeys=$records }
        Write-Utf8Json -Path $combinedPath -Value $combined
        $qualification = Write-DevelopQualification -Commit $commit -Tree $tree -ReportPath $combinedPath -IdentitySha256 $currentIdentity -JourneyRecords $records -Plan $plan
        $validJson = Get-Content -LiteralPath $developQualificationFullPath -Raw -Encoding UTF8
        $arguments = @{ Commit=$commit; Tree=$tree; ExpectedIdentitySha256=$currentIdentity; ExpectedStandStateSha256=$standHash }

        (Test-DevelopQualification @arguments).reuseKind | Should -Be 'exact-commit'
        foreach ($defect in @('route-hash', 'route-identity', 'unplanned-execution', 'missing-planned-route', 'unknown-planned-route', 'duplicate-planned-route')) {
            $invalid = $validJson | ConvertFrom-Json
            switch ($defect) {
                'route-hash' { $invalid.journeys.upgrade.sha256 = '0' * 64 }
                'route-identity' { $invalid.journeys.upgrade.identitySha256 = '0' * 64 }
                'unplanned-execution' { $invalid.journeys.upgrade.execution = 'executed' }
                'missing-planned-route' { $invalid.plan.journeys = @('upgrade'); $invalid.journeys.PSObject.Properties.Remove('upgrade') }
                'unknown-planned-route' { $invalid.plan.journeys = @('unknown') }
                'duplicate-planned-route' { $invalid.plan.journeys = @('upgrade', 'upgrade') }
            }
            $combined.plan = $invalid.plan
            Write-Utf8Json -Path (Join-Path $repoRoot $invalid.e2e.path) -Value $combined
            $invalid.e2e.sha256 = (Get-FileHash -LiteralPath (Join-Path $repoRoot $invalid.e2e.path)).Hash.ToLowerInvariant()
            Write-Utf8Json -Path $developQualificationFullPath -Value $invalid
            Test-DevelopQualification @arguments | Should -BeNullOrEmpty -Because $defect
        }
        # Restore the writer's report and prove runtime stand changes and file tampering remain blocking.
        Copy-Item -LiteralPath $combinedPath -Destination (Join-Path $repoRoot $qualification.e2e.path) -Force
        [IO.File]::WriteAllText($developQualificationFullPath, $validJson, [Text.UTF8Encoding]::new($false))
        $arguments.ExpectedStandStateSha256 = 'd' * 64
        Test-DevelopQualification @arguments | Should -BeNullOrEmpty
        $arguments.ExpectedStandStateSha256 = $standHash
        (Test-DevelopQualification @arguments).reuseKind | Should -Be 'exact-commit'
        Add-Content -LiteralPath $records.fresh.path -Value 'tampered'
        Test-DevelopQualification @arguments | Should -BeNullOrEmpty
    }
}
