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

It 'retains native proof across copy cleanup changes but rejects a changed space admission input' {
    Mock Get-DevelopE2EStandStateSha256 {'c'*64}
    $f=New-ScenarioPlanFixture
    Mock Get-Command {[pscustomobject]@{Source=$f.artifact}} -ParameterFilter {$Name -contains 'go.exe'}
    $relative='scripts/source-e2e-storage.ps1';$path=Join-Path $f.root $relative
    Copy-Item -LiteralPath (Join-Path $RepoRoot $relative) -Destination $path
    $f.catalog.contracts[0].paths+=@($relative)
    [IO.File]::WriteAllText((Join-Path $f.root 'tests/quality-contracts.json'),($f.catalog|ConvertTo-Json -Depth 24))
    & git -C $f.root add --all;& git -C $f.root commit --quiet -m 'storage native input baseline'
    $f.base=(& git -C $f.root rev-parse HEAD).Trim()
    Save-IncrementalJourneyProofs $f
    $before=[Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($path))
    [IO.File]::WriteAllText($path,$before.Replace('-OperationTimeoutSec 2','-OperationTimeoutSec 3'),[Text.UTF8Encoding]::new($false))
    & git -C $f.root add --all;& git -C $f.root commit --quiet -m 'cleanup reader change'
    $commit=(& git -C $f.root rev-parse HEAD).Trim();$tree=(& git -C $f.root rev-parse 'HEAD^{tree}').Trim()
    $plan=New-DeliveryQualityPlanForCandidate -CandidateRoot $f.root -BaseCommit $f.base -CandidateCommit $commit -CandidateTree $tree -ArtifactBinding $f.binding
    @($plan.stages|Where-Object id -ne 'develop.static'|ForEach-Object execution) | Should -Be @('reuse','reuse')
    [IO.File]::WriteAllText($path,[Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($path)).Replace('$full=[IO.Path]::GetFullPath($Path)',"Write-Verbose 'changed space admission';`$full=[IO.Path]::GetFullPath(`$Path)"),[Text.UTF8Encoding]::new($false))
    & git -C $f.root add --all;& git -C $f.root commit --quiet -m 'space admission change'
    $commit=(& git -C $f.root rev-parse HEAD).Trim();$tree=(& git -C $f.root rev-parse 'HEAD^{tree}').Trim()
    $changed=New-DeliveryQualityPlanForCandidate -CandidateRoot $f.root -BaseCommit $f.base -CandidateCommit $commit -CandidateTree $tree -ArtifactBinding $f.binding
    @($changed.stages|Where-Object id -ne 'develop.static'|ForEach-Object execution) | Should -Be @('execute','execute')
}

It 'canonicalizes the actual sole client without hiding ambiguity, another client or unknown identity fields' {
    $root=Join-Path $TestDrive 'Клиент с пробелом';[void][IO.Directory]::CreateDirectory((Join-Path $root '.agent-1c'))
    $path=Join-Path $root '.agent-1c/project.json'
    [IO.File]::WriteAllText($path,'{"aiRules":{"tools":["kilocode"]}}')
    (Get-SourceE2EClientIdentity -ProjectRoot $root) | Should -BeExactly (Get-SourceE2EClientIdentity -ProjectRoot $root -AgentTarget kilocode)
    (Get-SourceE2EClientIdentity -ProjectRoot $root -AgentTarget codex) | Should -Not -BeExactly (Get-SourceE2EClientIdentity -ProjectRoot $root)
    [IO.File]::WriteAllText($path,'{"aiRules":{"tools":["kilocode","codex"]}}')
    {Resolve-SourceE2EAgentTarget -ProjectRoot $root} | Should -Throw '*AGENT_TARGET_REQUIRED*'
    $ambiguous=Get-SourceE2EClientIdentity -ProjectRoot $root
    {ConvertTo-DevelopEffectiveClientIdentity $ambiguous} | Should -Throw '*AGENT_TARGET_REQUIRED*'
    $unknown=$ambiguous|ConvertFrom-Json;$unknown|Add-Member -NotePropertyName future -NotePropertyValue 'unowned'
    {ConvertTo-DevelopEffectiveClientIdentity ($unknown|ConvertTo-Json -Depth 8 -Compress)} | Should -Throw '*IDENTITY_UNKNOWN*'
}

It 'uses the actual MCP writer ownership without selecting stale export or configuration rejection' {
    $f=New-IncrementalPlanFixture
    $catalog=Get-QualityContractCatalog $RepoRoot
    $relative='.agents/skills/1c-workflow/scripts/lib/agent-1c.client-adapters.ps1'
    $path=Join-Path $f.root $relative;[void][IO.Directory]::CreateDirectory((Split-Path $path))
    Copy-Item -LiteralPath (Join-Path $RepoRoot $relative) -Destination $path
    $f.catalog.contracts[0].paths+=@($relative)
    $f.catalog.developJourneys|Add-Member -NotePropertyName scenarios -NotePropertyValue $catalog.developJourneys.scenarios
    $f.catalog.developJourneys|Add-Member -NotePropertyName scenarioInputs -NotePropertyValue @($catalog.developJourneys.scenarioInputs|Where-Object path -eq $relative)
    & git -C $f.root add --all;& git -C $f.root commit --quiet -m 'real writer baseline'
    $base=(& git -C $f.root rev-parse HEAD).Trim()
    $bytes=[IO.File]::ReadAllBytes($path);$hasBom=$bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191
    $text=[IO.File]::ReadAllText($path);$tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors)
    $function=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Write-ItlClientMcpEndpoints'},$true)
    $text=$text.Insert($function.Body.EndBlock.Statements[0].Extent.StartOffset,"Write-Verbose 'writer regression'`n")
    [IO.File]::WriteAllText($path,$text,[Text.UTF8Encoding]::new($hasBom))
    $upgrade=Resolve-DevelopScenarioSelection $f.root $base @($relative) $f.catalog upgrade
    $fresh=Resolve-DevelopScenarioSelection $f.root $base @($relative) $f.catalog fresh
    @($upgrade.selected) | Should -Be @('update')
    @($fresh.selected) | Should -Be @('install','branch')
    $actual=Resolve-DevelopE2EJourneyPlanCore -RepositoryRoot $f.root -BaseRef $base -ChangedPath @($relative) -Catalog $catalog
    @($actual.journeys) | Should -Be @('upgrade','fresh')
    @($upgrade.selected) | Should -Not -Contain 'configuration-rejection'
    @($fresh.selected) | Should -Not -Contain 'stale-export'
    $original=Get-DevelopHistoricalSourceText $f.root $base $relative
    # A product-enabled or unknown stand cannot use the representative shortcut.
    Get-DevelopScenarioSourceProjection $relative $original fresh @('refresh') $catalog | Should -BeNullOrEmpty
    $before=Get-DevelopScenarioSourceProjection $relative $original fresh @('refresh') $catalog -NoProductContext $true
    $current=[Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($path))
    $after=Get-DevelopScenarioSourceProjection $relative $current fresh @('refresh') $catalog -NoProductContext $true
    $before | Should -BeExactly $after
    # A new ambient dependency invalidates the stateless representative contract.
    [IO.File]::WriteAllText($path,$text.Insert($function.Body.EndBlock.Statements[0].Extent.StartOffset,"Write-Verbose `$Action`n"),[Text.UTF8Encoding]::new($hasBom))
    $unknown=Resolve-DevelopScenarioSelection $f.root $base @($relative) $f.catalog fresh
    @($unknown.selected) | Should -Be @($catalog.developJourneys.scenarios.fresh.id)
}
}
