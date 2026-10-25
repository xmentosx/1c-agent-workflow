BeforeAll { . (Join-Path $PSScriptRoot 'SourceDeliveryIncremental.TestSupport.ps1') }

Describe 'Incremental delivery acceptance' {
BeforeEach {
        $script:DeliverySupervisorCommit = '1111111111111111111111111111111111111111'
        $script:DeliverySupervisorChannel = 'master'
        $script:DeliverySupervisorBootstrap = $false
        $script:ResumePlan = ''
        $script:ApproveLongPlan = ''
        $script:E2EProjectRoot = ''
        $script:AiRulesSource = ''
        $script:DeliveryRequestedAiRulesSource = ''
        $script:developAncestorRoutes = @{}
        $script:developJourneyInputs = @{}
        $script:developCurrentStaticProof = $null
        $script:sourceE2EArtifactBinding = $null
        $script:sourceE2EArtifactBindingPath = ''
    }

It 'plans real Git changes with the exact native selection (<Change>)' -TestCases @(
        @{Change='owned-test';Expected=@('develop.static')},
        @{Change='update-only';Expected=@('develop.static','develop.upgrade')},
        @{Change='fresh-only';Expected=@('develop.static','develop.fresh')},
        @{Change='rejection-only';Expected=@('develop.static','develop.upgrade')},
        @{Change='artifact-discovery';Expected=@('develop.static')},
        @{Change='shared-stand';Expected=@('develop.static','develop.upgrade','develop.fresh')},
        @{Change='shared';Expected=@('develop.static','develop.upgrade','develop.fresh')}
    ) {
        param($Change,$Expected)
        $f=New-IncrementalPlanFixture; $script:Root=$f.root
        $script:GateScript=Join-Path $f.root 'scripts/check.ps1'
        $script:E2EProjectRoot=$f.stand; $script:AiRulesSource=$f.rules; $script:AgentTarget='kilocode'
        # Only native host observations are substituted. Catalog, Git diff,
        # router, input hashes, proof discovery and planner are production code.
        Mock Get-DevelopE2EStandStateSha256 {'c'*64}
        Mock Get-Command {[pscustomobject]@{Source=$f.artifact}} -ParameterFilter {$Name -contains 'go.exe'}
        Save-IncrementalJourneyProofs $f
        $path=switch($Change) {
            'owned-test' {'tests/pester/Runtime.Tests.ps1'}
            'update-only' {'.agents/skills/1c-workflow/scripts/lib/agent-1c.lifecycle.ps1'}
            'fresh-only' {'scripts/invoke-develop-e2e.ps1'}
            'rejection-only' {'scripts/develop-configuration-rejection.ps1'}
            'artifact-discovery' {'scripts/stand-env-identity.ps1'}
            'shared-stand' {'scripts/stand-env-identity.ps1'}
            'shared' {'runtime.ps1'}
        }
        $physical=Join-Path $f.root $path; $text=[IO.File]::ReadAllText($physical)
        $bytes=[IO.File]::ReadAllBytes($physical)
        $hasBom=$bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191
        if($Change -in @('update-only','fresh-only','artifact-discovery','shared-stand')) {
            $functionName=switch($Change){'update-only'{'Update-WorkflowPackage'}'fresh-only'{'Get-BranchWorktree'}'artifact-discovery'{'Find-SourceE2EArtifactBinding'}'shared-stand'{'Get-DevelopPositiveStandRoot'}}
            $tokens=$null; $errors=$null
            $ast=[Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors)
            $node=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $functionName},$true)
            $text=$text.Insert($node.Body.EndBlock.Statements[0].Extent.StartOffset,"Write-Verbose 'incremental change'`n    ")
        } else {$text+="`nWrite-Output 'incremental change'`n"}
        [IO.File]::WriteAllText($physical,$text,[Text.UTF8Encoding]::new($hasBom))
        if($Change -eq 'shared') {
            [IO.File]::AppendAllText((Join-Path $f.root 'tests/pester/Runtime.Tests.ps1'),"`n# regression for the changed runtime`n")
        }
        & git -C $f.root add --all; & git -C $f.root commit --quiet -m $Change
        $commit=(& git -C $f.root rev-parse HEAD).Trim(); $tree=(& git -C $f.root rev-parse 'HEAD^{tree}').Trim()
        $plan=New-DeliveryQualityPlanForCandidate -CandidateRoot $f.root -BaseCommit $f.base -CandidateCommit $commit -CandidateTree $tree -ArtifactBinding $f.binding
        @($plan.stages.id) | Should -Be $Expected
        @($plan.stages | Where-Object execution -eq 'execute').Count | Should -Be $Expected.Count
        foreach($stage in @($plan.stages | Where-Object id -ne 'develop.static')) {
            @($stage.reuseDiagnostics.code) | Should -Contain 'INPUTS_NOT_EQUIVALENT'
            @($stage.reuseDiagnostics.inputs) | Should -Contain "source:$path"
        }
        $plan.requireRelease | Should -BeFalse
    }

It 'keeps the actual catalog native-free for isolated Pester changes including mixed test owners' {
        foreach($paths in @(
            @('tests/pester/WorkflowUpdateRollback.Tests.ps1'),
            @('tests/pester/SourceUpgradeHandoff.Tests.ps1','tests/pester/ArtifactRetentionAndBranchDeletion.Tests.ps1')
        )) {
            $route=Resolve-DevelopE2EJourneyPlan -RepositoryRoot $RepoRoot -ChangedPath $paths
            @($route.journeys).Count | Should -Be 0
            $selection=Resolve-QualityContractsForPaths -Catalog (Get-QualityContractCatalog $RepoRoot) -Paths $paths
            foreach($path in $paths) { @($selection.tests) | Should -Contain $path }
        }
    }

It 'selects only planner regressions for discovery changes without native fixture or publication suites' {
    $catalog=Get-QualityContractCatalog -RepositoryRoot $RepoRoot
    $path='scripts/source-e2e-artifact-discovery.ps1'
    $selection=Resolve-QualityContractsForPaths -Catalog $catalog -Paths @($path)
    @($selection.unknownPaths) | Should -BeNullOrEmpty
    @($selection.tests) | Should -Be @('tests/pester/DeliveryCandidatePlanBridge.Tests.ps1','tests/pester/DeliveryCatalogInputScope.Tests.ps1','tests/pester/DeliveryGoInputScope.Tests.ps1','tests/pester/DeliveryScenarioAuthentication.Tests.ps1','tests/pester/DeliveryScenarioComposition.Tests.ps1','tests/pester/DeliveryScenarioSelection.Tests.ps1','tests/pester/DeliverySetupInputScope.Tests.ps1','tests/pester/SourceDeliveryIncremental.Tests.ps1','tests/pester/SourceDeliveryPlan.Tests.ps1')
    $route=Resolve-DevelopE2EJourneyPlan -RepositoryRoot $RepoRoot -ChangedPath @($path) -Catalog $catalog
    @($route.journeys) | Should -BeNullOrEmpty
    @($route.unknownPaths) | Should -BeNullOrEmpty
}
}
