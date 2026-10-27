BeforeAll {
    . (Join-Path $PSScriptRoot 'SourceDeliveryPlan.TestSupport.ps1')
    $catalogPath='.agents/skills/1c-workflow/scripts/lib/agent-1c.product-catalog.ps1'
    function New-ProductCatalogScopeFixture {
        param([bool]$Positive=$false)
        $f=New-IncrementalPlanFixture;$script:Root=$f.root
        $actual=Get-QualityContractCatalog $RepoRoot
        $f.catalog.developJourneys|Add-Member scenarios $actual.developJourneys.scenarios
        $f.catalog.developJourneys|Add-Member scenarioInputs @($actual.developJourneys.scenarioInputs|Where-Object path -eq $catalogPath)
        $f.catalog.contracts[0].paths+=@($catalogPath)
        $target=Join-Path $f.root $catalogPath;[void][IO.Directory]::CreateDirectory((Split-Path $target))
        $current=[IO.File]::ReadAllText((Join-Path $RepoRoot $catalogPath))
        $before=$current.Replace("        # The schema-v2 publisher uses configId; retain id for earlier catalog fixtures/readers.`r`n",'').Replace("        # The schema-v2 publisher uses configId; retain id for earlier catalog fixtures/readers.`n",'')
        $before=$before.Replace("(Get-ItlCatalogField `$_ 'configId' (Get-ItlCatalogField `$_ 'id'))","(Get-ItlCatalogField `$_ 'id')")
        $before|Should -Not -BeExactly $current
        [IO.File]::WriteAllText($target,$before,[Text.UTF8Encoding]::new($true))
        [IO.File]::WriteAllText((Join-Path $f.stand '.agent-1c/project.json'),'{"aiRules":{"tools":["kilocode"]}}')
        if($Positive) {
            $positiveRoot=Join-Path $f.root '.git/positive'
            [void][IO.Directory]::CreateDirectory((Join-Path $positiveRoot '.agent-1c'))
            foreach($path in @('.agent-1c/project.json','.agent-1c/release-e2e.json','.dev.env')) {Copy-Item (Join-Path $f.stand $path) (Join-Path $positiveRoot $path)}
            $positiveDevelop=Join-Path $f.root '.git/positive-develop'
            [void][IO.Directory]::CreateDirectory((Join-Path $positiveDevelop '.agent-1c'))
            Copy-Item (Join-Path $positiveRoot '.agent-1c/project.json') (Join-Path $positiveDevelop '.agent-1c/project.json')
            [IO.File]::WriteAllText((Join-Path $positiveRoot '.agent-1c/release-e2e.json'),(@{developWorktreePath=$positiveDevelop}|ConvertTo-Json))
            [IO.File]::WriteAllText((Join-Path $f.stand '.agent-1c/release-e2e.json'),(@{developConfigurationRejection=@{positiveProjectRoot=$positiveRoot}}|ConvertTo-Json -Depth 6))
        }
        [IO.File]::WriteAllText((Join-Path $f.root 'tests/quality-contracts.json'),($f.catalog|ConvertTo-Json -Depth 24))
        & git -C $f.root add --all;& git -C $f.root commit --quiet -m 'original catalog configuration identity'
        $f.base=(& git -C $f.root rev-parse HEAD).Trim()
        $f|Add-Member currentCatalog $current
        return $f
    }
    function Set-ProductCatalogScopeCurrent {
        param($Fixture)
        [IO.File]::WriteAllText((Join-Path $Fixture.root $catalogPath),$Fixture.currentCatalog,[Text.UTF8Encoding]::new($true))
        & git -C $Fixture.root add --all;& git -C $Fixture.root commit --quiet -m 'schema-v2 configId with legacy id fallback'
    }
}
Describe 'Disabled product catalog native scope' {
    AfterEach { Exit-DeliveryPlanFixtureEnvironment -Snapshot $script:deliveryPlanFixtureEnvironment }
    BeforeEach {
        $script:deliveryPlanFixtureEnvironment=Enter-DeliveryPlanFixtureEnvironment
        $script:DeliverySupervisorCommit='1111111111111111111111111111111111111111'
        $script:DeliverySupervisorChannel='master';$script:DeliverySupervisorBootstrap=$false
        $script:ResumePlan='';$script:ApproveLongPlan=''
        $script:DeliveryRequestedAiRulesSource='';$script:developAncestorRoutes=@{};$script:developJourneyInputs=@{}
        $script:developCurrentStaticProof=$null;$script:sourceE2EArtifactBinding=$null;$script:sourceE2EArtifactBindingPath=''
        Mock Get-DevelopE2EStandStateSha256 {'c'*64}
    }
    It 'reuses authenticated catalog validation changes for every disabled native scenario (positive=<Positive>)' -TestCases @(@{Positive=$false},@{Positive=$true}) {
        param($Positive)
        $f=New-ProductCatalogScopeFixture -Positive $Positive
        Mock Get-Command {[pscustomobject]@{Source=$f.artifact}} -ParameterFilter {$Name -contains 'go.exe'}
        Save-IncrementalJourneyProofs $f
        $old=Get-DevelopE2EInputIdentity $f.root fresh $f.catalog $f.stand $f.rules kilocode -ArtifactBinding $f.binding
        Set-ProductCatalogScopeCurrent $f
        $tree=(& git -C $f.root rev-parse 'HEAD^{tree}').Trim()
        foreach($journey in @('fresh','upgrade')) {
            $now=Get-DevelopE2EInputIdentity $f.root $journey $f.catalog $f.stand $f.rules kilocode -ArtifactBinding $f.binding
            $now.inventory.external.productContext.known|Should -BeTrue
            $now.inventory.external.productContext.disabled|Should -BeTrue
            @((Get-DevelopScenarioReusePlan $f.root $tree $journey $now $f.catalog -AllowPendingStatic)|Where-Object execution -ne reuse)|Should -BeNullOrEmpty
        }
        $script:E2EProjectRoot=$f.stand;$script:AiRulesSource=$f.rules;$script:AgentTarget='kilocode'
        $script:GateScript=Join-Path $f.root 'scripts/check.ps1'
        $head=(& git -C $f.root rev-parse HEAD).Trim()
        $plan=New-DeliveryQualityPlanForCandidate -CandidateRoot $f.root -BaseCommit $f.base -CandidateCommit $head -CandidateTree $tree -ArtifactBinding $f.binding
        $native=@($plan.stages|Where-Object {$_.id -in @('develop.fresh','develop.upgrade')})
        $native.Count|Should -Be 2
        @($native|Where-Object execution -ne reuse)|Should -BeNullOrEmpty
        @($native.scenarios|Where-Object execution -ne reuse)|Should -BeNullOrEmpty
        $file=Join-Path $f.root $catalogPath
        foreach($case in @('shared-helper','unknown-function','top-level','historical-sha')) {
            $changed=switch($case) {
                'shared-helper' {$f.currentCatalog.Replace('function Get-ItlCatalogKeys {',"function Get-ItlCatalogKeys { Write-Output 'changed shared helper';")}
                'unknown-function' {$f.currentCatalog+"`nfunction Unknown-CatalogEntry { 'new' }`n"}
                'top-level' {$f.currentCatalog+"`nWrite-Output 'new ambient work'`n"}
                default {$f.currentCatalog}
            }
            [IO.File]::WriteAllText($file,$changed,[Text.UTF8Encoding]::new($true))
            $now=Get-DevelopE2EInputIdentity $f.root fresh $f.catalog $f.stand $f.rules kilocode -ArtifactBinding $f.binding
            $prior=$old|ConvertTo-Json -Depth 32|ConvertFrom-Json
            if($case -eq 'historical-sha'){($prior.inventory.inputs|Where-Object path -eq $catalogPath).sha256='e'*64;$prior.fingerprint=Get-DevelopE2ECanonicalJsonSha256 $prior.inventory}
            Test-DevelopScenarioEquivalentInput $f.root $prior $now $f.base @('verification') $f.catalog|Should -BeFalse -Because $case
        }
    }
    It 'retains native catalog execution for <Context> context' -TestCases @(@{Context='enabled'},@{Context='pending'},@{Context='unknown'},@{Context='positive-enabled'},@{Context='develop-enabled'},@{Context='positive-develop-enabled'}) {
        param($Context)
        $f=New-ProductCatalogScopeFixture -Positive ($Context -in @('positive-enabled','positive-develop-enabled'))
        switch($Context) {
            'enabled' {[IO.File]::WriteAllText((Join-Path $f.stand '.agent-1c/project.json'),'{"productProject":{"projectId":"bound"}}')}
            'pending' {[void][IO.Directory]::CreateDirectory((Join-Path $f.stand '.agent-1c/mcp'));[IO.File]::WriteAllText((Join-Path $f.stand '.agent-1c/mcp/product-context-operation.json'),'{}')}
            'unknown' {[IO.File]::WriteAllText((Join-Path $f.stand '.agent-1c/release-e2e.json'),(@{developWorktreePath=(Join-Path $f.root '.git/missing-target')}|ConvertTo-Json))}
            'positive-enabled' {[IO.File]::WriteAllText((Join-Path $f.root '.git/positive/.agent-1c/project.json'),'{"productProject":{"projectId":"positive"}}')}
            'positive-develop-enabled' {[IO.File]::WriteAllText((Join-Path $f.root '.git/positive-develop/.agent-1c/project.json'),'{"productProject":{"projectId":"positive-develop"}}')}
            'develop-enabled' {
                $develop=Join-Path $f.root '.git/develop';[void][IO.Directory]::CreateDirectory((Join-Path $develop '.agent-1c'))
                [IO.File]::WriteAllText((Join-Path $develop '.agent-1c/project.json'),'{"productProject":{"projectId":"develop"}}')
                [IO.File]::WriteAllText((Join-Path $f.stand '.agent-1c/release-e2e.json'),(@{developWorktreePath=$develop}|ConvertTo-Json))
            }
        }
        Mock Get-Command {[pscustomobject]@{Source=$f.artifact}} -ParameterFilter {$Name -contains 'go.exe'}
        Save-IncrementalJourneyProofs $f
        Set-ProductCatalogScopeCurrent $f
        $tree=(& git -C $f.root rev-parse 'HEAD^{tree}').Trim()
        foreach($journey in @('fresh','upgrade')) {
            $now=Get-DevelopE2EInputIdentity $f.root $journey $f.catalog $f.stand $f.rules kilocode -ArtifactBinding $f.binding
            $now.inventory.external.productContext.disabled|Should -BeFalse
            @((Get-DevelopScenarioReusePlan $f.root $tree $journey $now $f.catalog -AllowPendingStatic)|Where-Object execution -eq reuse)|Should -BeNullOrEmpty
        }
    }
    It 'returns before catalog validation on disabled startup while retaining pending-operation refusal' {
        $t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot '.agents/skills/1c-workflow/scripts/lib/agent-1c.product-project-context.ps1'),[ref]$t,[ref]$e)
        @($e)|Should -BeNullOrEmpty
        $definitions=@($ast.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -in @('Initialize-ItlProductProjectContext','Get-ItlProductProjectBinding')}|ForEach-Object {$_.Extent.Text})
        $definitions.Count|Should -Be 2
        & {
            foreach($definition in $definitions){. ([scriptblock]::Create($definition))}
            function Get-ConfigValue {return $null}
            function Read-ItlProductProjectRecord {param($Name);if($Name -ne 'operation'){throw 'Disabled startup read context'};return $null}
            function Read-ItlProductProjectSnapshot {throw 'Disabled startup read catalog'}
            function Assert-ItlProductCatalog {throw 'Disabled startup validated catalog'}
            {Initialize-ItlProductProjectContext}|Should -Not -Throw
            function Read-ItlProductProjectRecord {return @{status='started'}}
            {Initialize-ItlProductProjectContext}|Should -Throw '*CATALOG_OPERATION_PENDING*'
        }
    }
}
