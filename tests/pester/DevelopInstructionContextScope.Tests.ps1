BeforeAll {
    . (Join-Path $PSScriptRoot 'SourceDeliveryPlan.TestSupport.ps1')
    function New-InstructionContextFixture {
        param([bool]$Positive=$false,[string]$Context='disabled')
        $f=New-IncrementalPlanFixture;$script:Root=$f.root
        $actual=Get-QualityContractCatalog $RepoRoot
        $f.catalog.developJourneys|Add-Member scenarios $actual.developJourneys.scenarios
        $f.catalog.developJourneys|Add-Member scenarioInputs @($actual.developJourneys.scenarioInputs|Where-Object path -eq '.agents/skills/1c-workflow/scripts/lib/agent-1c.product-project-context.ps1')
        [IO.File]::WriteAllText((Join-Path $f.stand '.agent-1c/project.json'),'{"aiRules":{"tools":["kilocode"]}}')
        foreach($relative in @('.agents/skills/1c-workflow/SKILL.md','.agents/skills/1c-workflow-fast/SKILL.md','.agents/skills/1c-workflow/scripts/lib/agent-1c.product-project-context.ps1')) {
            $target=Join-Path $f.root $relative;[void][IO.Directory]::CreateDirectory((Split-Path $target))
            Copy-Item -LiteralPath (Join-Path $RepoRoot $relative) -Destination $target
            $f.catalog.contracts[0].paths+=@($relative)
        }
        if($Positive) {
            $positiveRoot=Join-Path $f.root '.git/positive';[void][IO.Directory]::CreateDirectory((Join-Path $positiveRoot '.agent-1c'))
            foreach($relative in @('.agent-1c/project.json','.agent-1c/release-e2e.json','.dev.env')) {Copy-Item -LiteralPath (Join-Path $f.stand $relative) -Destination (Join-Path $positiveRoot $relative)}
            $positiveDevelop=Join-Path $f.root '.git/positive-develop';[void][IO.Directory]::CreateDirectory((Join-Path $positiveDevelop '.agent-1c'))
            Copy-Item -LiteralPath (Join-Path $positiveRoot '.agent-1c/project.json') -Destination (Join-Path $positiveDevelop '.agent-1c/project.json')
            [IO.File]::WriteAllText((Join-Path $positiveRoot '.agent-1c/release-e2e.json'),(@{developWorktreePath=$positiveDevelop}|ConvertTo-Json))
            [IO.File]::WriteAllText((Join-Path $f.stand '.agent-1c/release-e2e.json'),(@{developConfigurationRejection=@{positiveProjectRoot=$positiveRoot}}|ConvertTo-Json -Depth 6))
        }
        switch($Context) {
            'enabled' {[IO.File]::WriteAllText((Join-Path $f.stand '.agent-1c/project.json'),'{"aiRules":{"tools":["kilocode"]},"productProject":{"projectId":"example"}}')}
            'pending' {[void][IO.Directory]::CreateDirectory((Join-Path $f.stand '.agent-1c/mcp'));[IO.File]::WriteAllText((Join-Path $f.stand '.agent-1c/mcp/product-context-operation.json'),'{}')}
            'unknown' {$branch=Join-Path $f.root '.git/unknown-branch';[void][IO.Directory]::CreateDirectory($branch);[IO.File]::WriteAllText((Join-Path $f.stand '.agent-1c/release-e2e.json'),(@{developWorktreePath=$branch}|ConvertTo-Json))}
        }
        [IO.File]::WriteAllText((Join-Path $f.root 'tests/quality-contracts.json'),($f.catalog|ConvertTo-Json -Depth 24))
        & git -C $f.root add --all;& git -C $f.root commit --quiet -m 'instruction and product input baseline'
        $f.base=(& git -C $f.root rev-parse HEAD).Trim()
        return $f
    }
    function Set-ProductContextScopeChange($Fixture) {
        $path=Join-Path $Fixture.root '.agents/skills/1c-workflow/scripts/lib/agent-1c.product-project-context.ps1'
        $text=[IO.File]::ReadAllText($path);$tokens=$null;$errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors)
        $node=$ast.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -eq 'Get-ItlProductProjectPublisherContext'}
        $bytes=[IO.File]::ReadAllBytes($path);$bom=$bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191
        [IO.File]::WriteAllText($path,$text.Insert($node.Body.EndBlock.Statements[0].Extent.StartOffset,"Write-Verbose 'changed product publisher'`n"),[Text.UTF8Encoding]::new($bom))
    }
}

Describe 'Consumed native instruction and product inputs' {
    BeforeEach {
        Mock Get-DevelopE2EStandStateSha256 {'c'*64}
    }
    It 'reuses all authenticated scenarios after main guidance content changes while binding presence and fast-skill runtime content' {
        $f=New-InstructionContextFixture
        Mock Get-Command {[pscustomobject]@{Source=$f.artifact}} -ParameterFilter {$Name -contains 'go.exe'}
        Save-IncrementalJourneyProofs $f
        $old=Get-DevelopE2EInputIdentity $f.root fresh $f.catalog $f.stand $f.rules kilocode -ArtifactBinding $f.binding
        $relative='.agents/skills/1c-workflow/SKILL.md';$path=Join-Path $f.root $relative
        [IO.File]::AppendAllText($path,"`nAdditional main agent guidance.`n")
        & git -C $f.root add --all;& git -C $f.root commit --quiet -m 'main guidance content'
        $tree=(& git -C $f.root rev-parse 'HEAD^{tree}').Trim()
        $route=Resolve-DevelopE2EJourneyPlanCore $f.root $f.base @($relative) (Get-QualityContractCatalog $RepoRoot)
        $route | Should -Not -BeNullOrEmpty
        @($route.journeys) | Should -BeNullOrEmpty
        foreach($journey in @('fresh','upgrade')) {
            $now=Get-DevelopE2EInputIdentity $f.root $journey $f.catalog $f.stand $f.rules kilocode -ArtifactBinding $f.binding
            $records=@(Get-DevelopScenarioReusePlan $f.root $tree $journey $now $f.catalog -AllowPendingStatic)
            @($records|Where-Object execution -ne reuse) | Should -BeNullOrEmpty -Because ($records|Select-Object id,reuseDiagnostics|ConvertTo-Json -Depth 5 -Compress)
        }
        $now=Get-DevelopE2EInputIdentity $f.root fresh $f.catalog $f.stand $f.rules kilocode -ArtifactBinding $f.binding
        $tampered=$old|ConvertTo-Json -Depth 32|ConvertFrom-Json
        ($tampered.inventory.inputs|Where-Object path -eq $relative).sha256='e'*64
        $tampered.fingerprint=Get-DevelopE2ECanonicalJsonSha256 $tampered.inventory
        Test-DevelopScenarioEquivalentInput $f.root $tampered $now $f.base @('verification') $f.catalog | Should -BeFalse
        $fast='.agents/skills/1c-workflow-fast/SKILL.md'
        [IO.File]::AppendAllText((Join-Path $f.root $fast),"`nChanged fast provenance.`n")
        $changed=Get-DevelopE2EInputIdentity $f.root fresh $f.catalog $f.stand $f.rules kilocode -ArtifactBinding $f.binding
        Test-DevelopScenarioEquivalentInput $f.root $old $changed $f.base @('verification') $f.catalog | Should -BeFalse
        Get-DevelopJourneyExcludedScope $fast fresh | Should -BeNullOrEmpty
        Remove-Item -LiteralPath $path
        Test-DevelopJourneyUnaffectedPath $f.root $relative $f.base fresh | Should -BeFalse
        Get-DevelopE2EInputIdentity $f.root fresh $f.catalog $f.stand $f.rules kilocode -ArtifactBinding $f.binding | Should -BeNullOrEmpty
        Test-DevelopJourneyUnaffectedPath $f.root $relative '' fresh | Should -BeFalse
    }

    It 'reuses product-only changes for a known disabled context across all roots (positive=<Positive>)' -TestCases @(@{Positive=$false},@{Positive=$true}) {
        param($Positive)
        $f=New-InstructionContextFixture -Positive $Positive
        Mock Get-Command {[pscustomobject]@{Source=$f.artifact}} -ParameterFilter {$Name -contains 'go.exe'}
        Save-IncrementalJourneyProofs $f
        $old=Get-DevelopE2EInputIdentity $f.root fresh $f.catalog $f.stand $f.rules kilocode -ArtifactBinding $f.binding
        Set-ProductContextScopeChange $f
        & git -C $f.root add --all;& git -C $f.root commit --quiet -m 'product-only publisher change'
        $tree=(& git -C $f.root rev-parse 'HEAD^{tree}').Trim()
        foreach($journey in @('fresh','upgrade')) {
            $now=Get-DevelopE2EInputIdentity $f.root $journey $f.catalog $f.stand $f.rules kilocode -ArtifactBinding $f.binding
            $now.inventory.external.productContext.known | Should -BeTrue
            $now.inventory.external.productContext.disabled | Should -BeTrue
            if($Positive) {$now.positiveInputIdentity.inventory.external.root | Should -BeExactly ((Join-Path $f.root '.git/positive').ToLowerInvariant())}
            @((Get-DevelopScenarioReusePlan $f.root $tree $journey $now $f.catalog -AllowPendingStatic)|Where-Object execution -ne reuse) | Should -BeNullOrEmpty
        }
        $path=Join-Path $f.root '.agents/skills/1c-workflow/scripts/lib/agent-1c.product-project-context.ps1'
        $knownBytes=[IO.File]::ReadAllBytes($path)
        [IO.File]::AppendAllText($path,"`nfunction New-UnknownProductFunction { 'new input' }`n")
        $unknown=Get-DevelopE2EInputIdentity $f.root fresh $f.catalog $f.stand $f.rules kilocode -ArtifactBinding $f.binding
        Test-DevelopScenarioEquivalentInput $f.root $old $unknown $f.base @('verification') $f.catalog | Should -BeFalse
        [IO.File]::WriteAllBytes($path,$knownBytes)
        [IO.File]::AppendAllText($path,"`nWrite-Output 'new ambient execution'`n")
        $ambient=Get-DevelopE2EInputIdentity $f.root fresh $f.catalog $f.stand $f.rules kilocode -ArtifactBinding $f.binding
        Test-DevelopScenarioEquivalentInput $f.root $old $ambient $f.base @('verification') $f.catalog | Should -BeFalse
        if($Positive) {
            [IO.File]::WriteAllBytes($path,$knownBytes)
            [IO.File]::WriteAllText((Join-Path $f.root '.git/positive/.agent-1c/project.json'),'{"aiRules":{"tools":["kilocode"]},"productProject":{"projectId":"enabled-positive"}}')
            $enabled=Get-DevelopE2EInputIdentity $f.root fresh $f.catalog $f.stand $f.rules kilocode -ArtifactBinding $f.binding
            $enabled.inventory.external.productContext.disabled | Should -BeFalse
            Test-DevelopScenarioEquivalentInput $f.root $old $enabled $f.base @('verification') $f.catalog | Should -BeFalse
        }
    }

    It 'retains native execution with unchanged <Context> product context' -TestCases @(@{Context='enabled'},@{Context='pending'},@{Context='unknown'}) {
        param($Context)
        $f=New-InstructionContextFixture -Context $Context
        Mock Get-Command {[pscustomobject]@{Source=$f.artifact}} -ParameterFilter {$Name -contains 'go.exe'}
        Save-IncrementalJourneyProofs $f
        Set-ProductContextScopeChange $f
        & git -C $f.root add --all;& git -C $f.root commit --quiet -m 'bound product change'
        $tree=(& git -C $f.root rev-parse 'HEAD^{tree}').Trim()
        $now=Get-DevelopE2EInputIdentity $f.root fresh $f.catalog $f.stand $f.rules kilocode -ArtifactBinding $f.binding
        $now.inventory.external.productContext.disabled | Should -BeFalse
        @((Get-DevelopScenarioReusePlan $f.root $tree fresh $now $f.catalog -AllowPendingStatic)|Where-Object execution -eq reuse) | Should -BeNullOrEmpty
    }
}
