BeforeAll { . (Join-Path $PSScriptRoot 'SourceDeliveryPlan.TestSupport.ps1') }

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
            'shared' {'runtime.ps1'}
        }
        $physical=Join-Path $f.root $path; $text=[IO.File]::ReadAllText($physical)
        if($Change -in @('update-only','fresh-only')) {
            $functionName=if($Change -eq 'update-only'){'Update-WorkflowPackage'}else{'Get-BranchWorktree'}
            $tokens=$null; $errors=$null
            $ast=[Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors)
            $node=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $functionName},$true)
            $text=$text.Insert($node.Body.EndBlock.Statements[0].Extent.StartOffset,"Write-Verbose 'incremental change'`n    ")
        } else {$text+="`nWrite-Output 'incremental change'`n"}
        [IO.File]::WriteAllText($physical,$text,[Text.UTF8Encoding]::new($true))
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

It 'reuses an unchanged upgrade through real planner and checker only after current static and rejects drift' {
        $f=New-IncrementalPlanFixture; $script:Root=$f.root
        $script:GateScript=Join-Path $f.root 'scripts/check.ps1'
        $script:E2EProjectRoot=$f.stand; $script:AiRulesSource=$f.rules; $script:AgentTarget='kilocode'
        Mock Get-DevelopE2EStandStateSha256 {'c'*64}
        Mock Get-Command {[pscustomobject]@{Source=$f.artifact}} -ParameterFilter {$Name -contains 'go.exe'}
        Save-IncrementalJourneyProofs $f
        $runner=Join-Path $f.root 'scripts/invoke-develop-e2e.ps1'
        $text=[IO.File]::ReadAllText($runner).Replace('Fresh journey branch worktree was not registered:','Fresh branch fixture was not registered:')
        [IO.File]::WriteAllText($runner,$text,[Text.UTF8Encoding]::new($true))
        & git -C $f.root add --all; & git -C $f.root commit --quiet -m 'fresh implementation change'
        $commit=(& git -C $f.root rev-parse HEAD).Trim(); $tree=(& git -C $f.root rev-parse 'HEAD^{tree}').Trim()
        # An accumulated range may select both routes even when an intermediate
        # candidate already proved upgrade. Discovery must reuse that proof.
        $base=(& git -C $f.root rev-parse "$($f.base)~1").Trim()
        $args=@{CandidateRoot=$f.root;BaseCommit=$base;CandidateCommit=$commit;CandidateTree=$tree;ArtifactBinding=$f.binding}
        $plan=New-DeliveryQualityPlanForCandidate @args
        @($plan.stages.id) | Should -Be @('develop.static','develop.upgrade','develop.fresh')
        @($plan.stages.execution) | Should -Be @('execute','reuse','execute')
        $original=Join-Path $f.root '.git/upgrade.json'; $sha=(Get-FileHash $original).Hash
        $repoRoot=$f.root; $qualityCatalog=$f.catalog
        $script:developQualificationRoot=Join-Path $f.root '.git/current';[void][IO.Directory]::CreateDirectory($script:developQualificationRoot)
        $script:releaseContext=[pscustomobject]@{};$script:aiRulesRelease=[pscustomobject]@{}
        $script:developRulesSource=$f.rules;$script:sourceE2EArtifactBinding=$f.binding;$script:stages=@()
        Mock Get-DevelopE2EIdentitySha256 {'a'*64}
        Mock Add-ReusedStage {}
        Mock Invoke-PowerShellChild {throw 'UNEXPECTED_NATIVE_JOURNEY'}
        $routePlan=Resolve-DevelopE2EJourneyPlan -RepositoryRoot $f.root -BaseRef $base
        Ensure-DevelopE2ERoute -Journey upgrade -Plan $routePlan -DeferForStatic | Should -BeNullOrEmpty
        $script:developCurrentStaticProof=Save-IncrementalStaticProof $f
        $route=Ensure-DevelopE2ERoute -Journey upgrade -Plan $routePlan
        (Get-FileHash $route).Hash | Should -BeExactly $sha
        (Get-Content $route -Raw|ConvertFrom-Json).repository.commit | Should -BeExactly $f.base
        Should -Invoke Invoke-PowerShellChild -Times 0 -Exactly
        # Actual environment drift must invalidate the same planner proof.
        [IO.File]::AppendAllText((Join-Path $f.stand '.dev.env'),"UI_TESTING=changed`n")
        $changed=New-DeliveryQualityPlanForCandidate @args
        $upgrade=@($changed.stages|Where-Object id -eq 'develop.upgrade')[0]
        $upgrade.execution | Should -Be 'execute'
        @($upgrade.reuseDiagnostics.inputs) | Should -Contain 'external:uiPolicySha256'
        ($upgrade.reuseDiagnostics|ConvertTo-Json -Depth 8) | Should -Not -Match 'UI_TESTING=changed'
        $identity=Get-DeliveryCanonicalJsonSha256 (Get-DeliveryPlanIdentity $changed)
        $upgrade.reuseDiagnostics=@()
        (Get-DeliveryCanonicalJsonSha256 (Get-DeliveryPlanIdentity $changed)) | Should -BeExactly $identity
        $script:AiRulesSource=''
        $missing=New-DeliveryQualityPlanForCandidate @args
        $missingUpgrade=@($missing.stages|Where-Object id -eq 'develop.upgrade')[0]
        $missingUpgrade.execution | Should -Be 'execute'
        @($missingUpgrade.reuseDiagnostics.code) | Should -Contain 'BINDING_LOCATION_MISSING'
        @($missingUpgrade.reuseDiagnostics.inputs) | Should -Contain 'AiRulesSource'
    }
}
