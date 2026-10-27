BeforeAll { . (Join-Path $PSScriptRoot 'SourceDeliveryIncremental.TestSupport.ps1') }

Describe 'Incremental delivery acceptance' {
    AfterEach { Exit-DeliveryPlanFixtureEnvironment -Snapshot $script:deliveryPlanFixtureEnvironment }

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

It 'scopes the actual dependency synchronizer to its callers without repeating independent export and close scenarios' {
    $f=New-IncrementalPlanFixture
    $catalog=Get-QualityContractCatalog $RepoRoot
    $relative='.agents/skills/1c-workflow/scripts/lib/agent-1c.core.ps1'
    $path=Join-Path $f.root $relative;[void][IO.Directory]::CreateDirectory((Split-Path $path))
    Copy-Item -LiteralPath (Join-Path $RepoRoot $relative) -Destination $path
    & git -C $f.root add --all; & git -C $f.root commit --quiet -m 'real dependency owner'
    $base=(& git -C $f.root rev-parse HEAD).Trim()
    $original=[Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($path))
    $source=$original.TrimStart([char]0xfeff);$tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
    $node=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Sync-WorkflowManagedDependencyLockEntries'},$true)
    $changed=$source.Insert($node.Body.EndBlock.Statements[0].Extent.StartOffset,"Write-Verbose 'dependency regression'`n")
    [IO.File]::WriteAllText($path,$changed,[Text.UTF8Encoding]::new($original.StartsWith([string][char]0xfeff)))
    $materialized=[Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($path))
    $route=Resolve-DevelopE2EJourneyPlanCore $f.root $base @($relative) $catalog
    @($route.scenarios.fresh) | Should -Be @('install','branch','verification','refresh')
    @($route.scenarioReasons.fresh.functions) | Should -Be @('Sync-WorkflowManagedDependencyLockEntries')
    (Get-DevelopScenarioSourceProjection $relative $original fresh @('stale-export','close') $catalog) |
        Should -BeExactly (Get-DevelopScenarioSourceProjection $relative $materialized fresh @('stale-export','close') $catalog)
    [IO.File]::WriteAllText($path,$changed+"`nWrite-Verbose `$script:newAmbientDependency`n",[Text.UTF8Encoding]::new($original.StartsWith([string][char]0xfeff)))
    $route=Resolve-DevelopE2EJourneyPlanCore $f.root $base @($relative) $catalog
    @($route.scenarios.fresh) | Should -Be @($catalog.developJourneys.scenarios.fresh.id)
    @($route.scenarioReasons.fresh.fallback) | Should -Be @('ambient-or-top-level-change')
}

It 'retains ambient and top-level refusal while analyzing changed functions only' {
    $before='function Untouched { $global:existing }; function Changed { param($value) $local=1; foreach($item in @(1)) { $local += $item }; return $value+$local+$script:shared }'
    $after=$before.Replace('$local=1','$local=2')
    @(Get-DevelopChangedFunctions $before $after) | Should -Be @('Changed')
    Get-DevelopChangedFunctions $before ($after.Replace('$script:shared','$script:newDependency')) | Should -BeNullOrEmpty
    Get-DevelopChangedFunctions $before ($after+"`nWrite-Verbose 'new top-level behavior'") | Should -BeNullOrEmpty
    Get-DevelopChangedFunctions $before ([string][char]0xfeff+$after) | Should -BeNullOrEmpty
    @(Get-DevelopChangedFunctions $before ($before+"`r`n")) | Should -BeNullOrEmpty
}

It 'selects changed behavior, preserves prerequisite closure and reuses independent scenario proof (<Function>)' -ForEach @(
    @{Function='Change-Update';Journey='upgrade';Execute=@('update')},
    @{Function='Change-Export';Journey='fresh';Execute=@('install','branch','verification','stale-export')},
    @{Function='Change-Mcp';Journey='fresh';Execute=@('install')}
) {
    param($Function,$Journey,$Execute)
    Mock Get-DevelopE2EStandStateSha256 {'c'*64}
    $f=New-ScenarioPlanFixture
    Mock Get-Command {[pscustomobject]@{Source=$f.artifact}} -ParameterFilter {$Name -contains 'go.exe'}
    # Save real complete identities after substituting only the native Go host.
    Save-IncrementalJourneyProofs $f
    Set-ScenarioFixtureChange $f $Function
    $head=(& git -C $f.root rev-parse HEAD).Trim();$tree=(& git -C $f.root rev-parse 'HEAD^{tree}').Trim()
    $plan=New-DeliveryQualityPlanForCandidate -CandidateRoot $f.root -BaseCommit $f.base -CandidateCommit $head -CandidateTree $tree
    $stage=@($plan.stages|Where-Object id -eq "develop.$Journey")[0]
    @($stage.scenarios | Where-Object execution -ne 'reuse' | ForEach-Object id) | Should -Be $Execute
    @($stage.scenarios | ForEach-Object selectionReasons | ForEach-Object functions) | Should -Contain $Function
    @($stage.scenarios | Where-Object execution -eq 'reuse').Count | Should -BeGreaterThan 0
    foreach($record in @($stage.scenarios | Where-Object execution -eq 'reuse')) {$record.evidenceCommit|Should -BeExactly $f.base}
    $estimate=Get-DeliveryPlanTimeEstimate $plan @()
    @($estimate.stages|Where-Object id -eq "develop.$Journey")[0].basis | Should -Be 'scenario-workload-not-yet-measured'
    if($Function -eq 'Change-Mcp') {
        @($plan.stages.id) | Should -Be @('develop.static','develop.upgrade','develop.fresh')
        @($stage.scenarios|Where-Object {$_.id -in @('stale-export','close','refresh') -and $_.execution -ne 'reuse'}).Count | Should -Be 0
    }
}
}
