BeforeAll { . (Join-Path $PSScriptRoot 'SourceDeliveryIncremental.TestSupport.ps1') }

Describe 'Incremental delivery acceptance' {
    AfterEach { Exit-DeliveryPlanFixtureEnvironment -Snapshot $script:deliveryPlanFixtureEnvironment }
It 'binds every synthetic plan and scope fixture to one environment owner and restores it after failure' {
    foreach($name in @('ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE','VANESSA_MCP_CLIENT_CFE_PATH','ITL_ONDEMAND_MCP_SOURCE_BUILD_EXE')) {[Environment]::GetEnvironmentVariable($name,'Process')|Should -BeNullOrEmpty}
    $files=@('SourceDeliveryPlan','SourceDeliveryIncremental','DeliveryCandidatePlanBridge','DeliveryCatalogInputScope','DeliveryGoInputScope','DeliveryScenarioAuthentication','DeliveryScenarioComposition','DeliveryScenarioSelection','DeliverySetupInputScope','DevelopForkInputScope','DevelopBrokerInputScope','DevelopInstructionContextScope')
    foreach($name in $files) {
        $tokens=$null;$errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot ($name+'.Tests.ps1')),[ref]$tokens,[ref]$errors)
        @($errors)|Should -BeNullOrEmpty
        foreach($statement in $ast.EndBlock.Statements) {
            if($statement -isnot [Management.Automation.Language.PipelineAst]){continue}
            $command=$statement.PipelineElements[0]
            if($command -isnot [Management.Automation.Language.CommandAst] -or $command.GetCommandName() -ne 'Describe'){continue}
            $block=@($command.CommandElements|Where-Object {$_ -is [Management.Automation.Language.ScriptBlockExpressionAst]})[-1].ScriptBlock
            $hooks=@(foreach($s in $block.EndBlock.Statements){if($s -is [Management.Automation.Language.PipelineAst]){$c=$s.PipelineElements[0];if($c -is [Management.Automation.Language.CommandAst]){$c}}})
            @($hooks|Where-Object {$_.GetCommandName() -eq 'BeforeEach'}).Count|Should -Be 1
            @($hooks|Where-Object {$_.GetCommandName() -eq 'AfterEach'}).Count|Should -Be 1
            $body=$block.Extent.Text
            $body|Should -Match 'BeforeEach\s*\{\s*\$script:deliveryPlanFixtureEnvironment=Enter-DeliveryPlanFixtureEnvironment'
            $body|Should -Match 'AfterEach \{ Exit-DeliveryPlanFixtureEnvironment -Snapshot \$script:deliveryPlanFixtureEnvironment \}'
        }
    }
    $prior=Enter-DeliveryPlanFixtureEnvironment
    try {
        $segment=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('0KLQtdGB0YIg0L/Rg9GC0Yw='))
        foreach($name in $prior.Keys){[Environment]::SetEnvironmentVariable($name,('C:\'+$segment+'\'+$name),'Process')}
        $snapshot=Enter-DeliveryPlanFixtureEnvironment
        try {
            foreach($name in $snapshot.Keys){[Environment]::GetEnvironmentVariable($name,'Process')|Should -BeNullOrEmpty}
            throw 'original fixture failure'
        } catch { $_.Exception.Message|Should -Be 'original fixture failure' }
        finally { Exit-DeliveryPlanFixtureEnvironment $snapshot }
        foreach($name in $snapshot.Keys){[Environment]::GetEnvironmentVariable($name,'Process')|Should -BeExactly $snapshot[$name]}
    } finally { Exit-DeliveryPlanFixtureEnvironment $prior }
}

It 'isolates real candidate artifacts in the native fixture and restores their exact environment afterward' {
    $child=Join-Path $TestDrive 'fixture environment.ps1'
    $body=@'
param([string]$RepositoryRoot)
$ErrorActionPreference='Stop'
Import-Module Pester -RequiredVersion 5.8.0
$names=@('ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE','VANESSA_MCP_CLIENT_CFE_PATH','ITL_ONDEMAND_MCP_SOURCE_BUILD_EXE')
$expected=@{}
foreach($name in $names) {
    $expected[$name]=Join-Path $PSScriptRoot ($name+' invalid candidate artifact')
    [IO.File]::WriteAllText($expected[$name],'foreign candidate bytes')
    [Environment]::SetEnvironmentVariable($name,$expected[$name],'Process')
}
$config=New-PesterConfiguration
$config.Run.Path=Join-Path $RepositoryRoot 'tests/pester/SourceDeliveryIncremental.Tests.ps1'
$config.Filter.FullName='*plans real Git changes with the exact native selection*'
$config.Run.PassThru=$true
$config.Output.Verbosity='Normal'
$result=Invoke-Pester -Configuration $config
if($result.PassedCount -ne 7 -or $result.FailedCount -or $result.FailedContainersCount){throw ('Original native selection did not pass with foreign candidate artifacts. passed='+$result.PassedCount+'; failed='+$result.FailedCount)}
foreach($name in $names) {
    if([Environment]::GetEnvironmentVariable($name,'Process') -cne $expected[$name]){throw ('Fixture leaked environment: '+$name)}
    if([IO.File]::ReadAllText($expected[$name]) -cne 'foreign candidate bytes'){throw 'Fixture modified a foreign artifact.'}
}
'@
    [IO.File]::WriteAllText($child,$body,[Text.UTF8Encoding]::new($true))
    $result=Invoke-TestPowerShellFile -FilePath $child -Arguments @('-RepositoryRoot',$RepoRoot)
    $result.exitCode | Should -Be 0 -Because $result.combinedText
}
BeforeEach {
        $script:deliveryPlanFixtureEnvironment=Enter-DeliveryPlanFixtureEnvironment

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
