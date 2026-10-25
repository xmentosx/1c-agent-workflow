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

It 'reuses an unchanged upgrade through real planner and checker only after current static and rejects drift' {
        $f=New-IncrementalPlanFixture; $script:Root=$f.root
        $script:GateScript=Join-Path $f.root 'scripts/check.ps1'
        $script:E2EProjectRoot=$f.stand; $script:AiRulesSource=$f.rules; $script:AgentTarget='kilocode'
        Mock Get-DevelopE2EStandStateSha256 {'c'*64}
        Mock Get-Command {[pscustomobject]@{Source=$f.artifact}} -ParameterFilter {$Name -contains 'go.exe'}
        Save-IncrementalJourneyProofs $f
        # Exercise automatic discovery at the real default artifact paths,
        # rather than handing the planner an already-complete binding.
        [IO.File]::AppendAllText((Join-Path $f.root '.git/info/exclude'),"`n/build/`n/tools/itl-ondemand-mcp/build/`n")
        foreach($relative in @('build/third-party/vanessa-automation/1-r1/archive.zip','build/third-party/client-mcp/client.cfe','tools/itl-ondemand-mcp/build/mcp.exe')) {
            $cachePath=Join-Path $f.root $relative
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $cachePath))
            Copy-Item -LiteralPath $f.artifact -Destination $cachePath
        }
        $runner=Join-Path $f.root 'scripts/invoke-develop-e2e.ps1'
        $text=[IO.File]::ReadAllText($runner).Replace('Fresh journey branch worktree was not registered:','Fresh branch fixture was not registered:')
        [IO.File]::WriteAllText($runner,$text,[Text.UTF8Encoding]::new($true))
        $discovery=Join-Path $f.root 'scripts/stand-env-identity.ps1'
        $text=[Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($discovery))
        $text=$text.Replace('$lockPath=Join-Path $RepositoryRoot','Write-Verbose ''artifact lookup changed''; $lockPath=Join-Path $RepositoryRoot')
        [IO.File]::WriteAllBytes($discovery,[Text.Encoding]::UTF8.GetBytes($text))
        & git -C $f.root add --all; & git -C $f.root commit --quiet -m 'fresh implementation change'
        $commit=(& git -C $f.root rev-parse HEAD).Trim(); $tree=(& git -C $f.root rev-parse 'HEAD^{tree}').Trim()
        # An accumulated range may select both routes even when an intermediate
        # candidate already proved upgrade. Discovery must reuse that proof.
        $base=(& git -C $f.root rev-parse "$($f.base)~1").Trim()
        $args=@{CandidateRoot=$f.root;BaseCommit=$base;CandidateCommit=$commit;CandidateTree=$tree}
        $plan=New-DeliveryQualityPlanForCandidate @args
        @($plan.stages.id) | Should -Be @('develop.static','develop.upgrade','develop.fresh')
        @($plan.stages.execution) | Should -Be @('execute','reuse','execute') -Because (@($plan.stages | Where-Object id -ne 'develop.static' | ForEach-Object reuseDiagnostics) | ConvertTo-Json -Depth 8 -Compress)
        $original=Join-Path $f.root '.git/upgrade.json'; $sha=(Get-FileHash $original).Hash
        $repoRoot=$f.root; $qualityCatalog=$f.catalog
        $script:developQualificationRoot=Join-Path $f.root '.git/current';[void][IO.Directory]::CreateDirectory($script:developQualificationRoot)
        $script:releaseContext=[pscustomobject]@{};$script:aiRulesRelease=[pscustomobject]@{}
        $script:developRulesSource=$f.rules;$script:sourceE2EArtifactBinding=Find-SourceE2EArtifactBinding -RepositoryRoot $f.root;$script:stages=@()
        $script:sourceE2EArtifactBinding.paths.VANESSA_MCP_CLIENT_CFE_PATH | Should -BeExactly (Join-Path $f.root 'build/third-party/client-mcp/client.cfe')
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

It 'authenticates source on every reuse while comparing each file pair once per lookup' {
    Mock Get-DevelopE2EStandStateSha256 {'c'*64}
    $f=New-ScenarioPlanFixture
    Mock Get-Command {[pscustomobject]@{Source=$f.artifact}} -ParameterFilter {$Name -contains 'go.exe'}
    Save-IncrementalJourneyProofs $f
    $recorded=Get-DevelopE2EInputIdentity -RepositoryRoot $f.root -Journey upgrade -Catalog $f.catalog -ProjectRoot $f.stand -AiRulesSource $f.rules -AgentTarget kilocode -ArtifactBinding $f.binding
    Set-ScenarioFixtureChange $f 'Change-Update'
    $tree=(& git -C $f.root rev-parse 'HEAD^{tree}').Trim()
    $current=Get-DevelopE2EInputIdentity -RepositoryRoot $f.root -Journey upgrade -Catalog $f.catalog -ProjectRoot $f.stand -AiRulesSource $f.rules -AgentTarget kilocode -ArtifactBinding $f.binding
    $script:changedFunctionImplementation=(Get-Item Function:Get-DevelopChangedFunctions).ScriptBlock
    Mock Get-DevelopChangedFunctions { param($Before,$After) & $script:changedFunctionImplementation $Before $After }
    $records=@(Get-DevelopScenarioReusePlan -RepositoryRoot $f.root -Tree $tree -Journey upgrade -InputIdentity $current -Catalog $f.catalog -AllowPendingStatic)
    @($records|Where-Object execution -eq execute|ForEach-Object id) | Should -Be @('update')
    @($records|Where-Object execution -eq reuse).Count | Should -Be 2
    Should -Invoke Get-DevelopChangedFunctions -Times 1 -Exactly
    # A new invocation must not inherit any prior source comparison result.
    $null=Get-DevelopScenarioReusePlan -RepositoryRoot $f.root -Tree $tree -Journey upgrade -InputIdentity $current -Catalog $f.catalog -AllowPendingStatic
    Should -Invoke Get-DevelopChangedFunctions -Times 2 -Exactly
    $lookupContext=@{changedFunctions=@{}}
    Test-DevelopScenarioEquivalentInput $f.root $recorded $current $f.base @('configuration-rejection') $f.catalog -LookupContext $lookupContext | Should -BeTrue
    Should -Invoke Get-DevelopChangedFunctions -Times 3 -Exactly
    $path=Join-Path $f.root 'runtime.ps1'
    [IO.File]::AppendAllText($path,"`nWrite-Verbose 'late source drift'`n")
    Test-DevelopScenarioEquivalentInput $f.root $recorded $current $f.base @('configuration-rejection') $f.catalog -LookupContext $lookupContext | Should -BeFalse
    Should -Invoke Get-DevelopChangedFunctions -Times 3 -Exactly
    $drift=Get-DevelopE2EInputIdentity -RepositoryRoot $f.root -Journey upgrade -Catalog $f.catalog -ProjectRoot $f.stand -AiRulesSource $f.rules -AgentTarget kilocode -ArtifactBinding $f.binding
    1..2|ForEach-Object {Test-DevelopScenarioEquivalentInput $f.root $recorded $drift $f.base @('configuration-rejection') $f.catalog -LookupContext $lookupContext | Should -BeFalse}
    Should -Invoke Get-DevelopChangedFunctions -Times 4 -Exactly
}

It 'retains verification, rollback, artifact and unknown-input rejection in scenario reuse' {
    Mock Get-DevelopE2EStandStateSha256 {'c'*64}
    $f=New-ScenarioPlanFixture
    Mock Get-Command {[pscustomobject]@{Source=$f.artifact}} -ParameterFilter {$Name -contains 'go.exe'}
    $old=Get-DevelopE2EInputIdentity -RepositoryRoot $f.root -Journey fresh -Catalog $f.catalog -ProjectRoot $f.stand -AiRulesSource $f.rules -AgentTarget kilocode -ArtifactBinding $f.binding
    foreach($key in @('platformSha256','rulesCommit','uiPolicySha256','artifacts','freshProjectsRoot','futureInput')) {
        $changed=$old|ConvertTo-Json -Depth 24|ConvertFrom-Json
        $changed.inventory.external|Add-Member -NotePropertyName $key -NotePropertyValue 'different' -Force
        $changed.fingerprint=Get-DevelopE2ECanonicalJsonSha256 $changed.inventory
        Test-DevelopScenarioEquivalentInput $f.root $old $changed $f.base @('install') $f.catalog | Should -BeFalse
    }
    $source=Join-Path $f.root 'runtime.ps1';[IO.File]::AppendAllText($source,"`nWrite-Output 'unknown shared side effect'`n")
    $now=Get-DevelopE2EInputIdentity -RepositoryRoot $f.root -Journey fresh -Catalog $f.catalog -ProjectRoot $f.stand -AiRulesSource $f.rules -AgentTarget kilocode -ArtifactBinding $f.binding
    Test-DevelopScenarioEquivalentInput $f.root $old $now $f.base @('install') $f.catalog | Should -BeFalse
    $catalog=Get-QualityContractCatalog $RepoRoot
    @((Get-DevelopScenarioCatalog $catalog fresh|Where-Object id -eq 'stale-export').dependsOn)|Should -Be @('verification')
    @((Get-DevelopScenarioCatalog $catalog fresh|Where-Object id -eq 'close').dependsOn)|Should -Be @('verification')
    @($catalog.developJourneys.scenarios.upgrade.id)|Should -Contain 'configuration-rejection'
    $legacyPlan=[pscustomobject]@{kind='itl-develop-e2e-journey-plan';journeys=@('fresh')}
    {New-DevelopE2ERouteReport -RepositoryRoot $f.root -Plan $legacyPlan -Journey fresh -IdentitySha256 ('a'*64) -StandStateSha256 ('c'*64) -JourneyResult ([pscustomobject]@{name='fresh';status='passed';coverage=@('install')})} | Should -Throw '*SCENARIO_COVERAGE_REQUIRED*'
    $failureRoot=Join-Path $f.root '.git/itl/runs';[void][IO.Directory]::CreateDirectory($failureRoot)
    $report=Get-Content (Join-Path $f.root '.git/fresh.json') -Raw -Encoding UTF8|ConvertFrom-Json
    $tree=(& git -C $f.root rev-parse 'HEAD^{tree}').Trim()
    $run=@{schemaVersion=3;mode='Develop';status='failed';commit=$f.base;tree=$tree;finishedAt=[datetime]::UtcNow.AddSeconds(1).ToString('o');
        stages=@(@{name='develop-e2e-fresh';status='failed'});journeyInputIdentities=@{fresh=$old};journeyScenarioExecution=@{fresh=@('install')}}
    $failurePath=Join-Path $failureRoot 'fixture-develop-failed.json'
    [IO.File]::WriteAllText($failurePath,($run|ConvertTo-Json -Depth 24))
    Test-DevelopE2ENewerJourneyFailure -RepositoryRoot $f.root -Report $report -CurrentCommit $f.base -CurrentTree $tree -InputIdentity $old -RequiredScenario verification | Should -BeFalse
    Test-DevelopE2ENewerJourneyFailure -RepositoryRoot $f.root -Report $report -CurrentCommit $f.base -CurrentTree $tree -InputIdentity $old -RequiredScenario install | Should -BeTrue
    $run.journeyScenarioExecution.fresh=@('unknown-owner')
    [IO.File]::WriteAllText($failurePath,($run|ConvertTo-Json -Depth 24))
    Test-DevelopE2ENewerJourneyFailure -RepositoryRoot $f.root -Report $report -CurrentCommit $f.base -CurrentTree $tree -InputIdentity $old -RequiredScenario verification | Should -BeTrue
}

It 'rejects an unprojectable native consumer before expensive source comparison without granting proof' {
    Mock Get-DevelopE2EStandStateSha256 {'c'*64}
    $f=New-ScenarioPlanFixture
    Mock Get-Command {[pscustomobject]@{Source=$f.artifact}} -ParameterFilter {$Name -contains 'go.exe'}
    $f.catalog.contracts[0].paths+=@('native-consumer.ps1')
    [IO.File]::WriteAllText((Join-Path $f.root 'tests/quality-contracts.json'),($f.catalog|ConvertTo-Json -Depth 24))
    $path=Join-Path $f.root 'native-consumer.ps1'
    [IO.File]::WriteAllText($path,"Write-Output 'original native consumer'")
    & git -C $f.root add --all; & git -C $f.root commit --quiet -m 'native consumer baseline'
    Save-IncrementalJourneyProofs $f
    [IO.File]::AppendAllText($path,"`nWrite-Output 'changed native consumer'")
    & git -C $f.root add --all; & git -C $f.root commit --quiet -m 'native consumer change'
    $tree=(& git -C $f.root rev-parse 'HEAD^{tree}').Trim()
    $now=Get-DevelopE2EInputIdentity -RepositoryRoot $f.root -Journey fresh -Catalog $f.catalog -ProjectRoot $f.stand -AiRulesSource $f.rules -AgentTarget kilocode -ArtifactBinding $f.binding
    Mock Test-DevelopScenarioEquivalentInput {throw 'Unprojectable inputs must reject before expensive comparison'}
    $records=@(Get-DevelopScenarioReusePlan $f.root $tree fresh $now $f.catalog -AllowPendingStatic)
    @($records|Where-Object execution -eq reuse).Count | Should -Be 0
    @($records|ForEach-Object reuseDiagnostics|ForEach-Object code) | Should -Contain 'NATIVE_CONSUMER_INPUT_CHANGED'
    Should -Invoke Test-DevelopScenarioEquivalentInput -Times 0 -Exactly
}
}
