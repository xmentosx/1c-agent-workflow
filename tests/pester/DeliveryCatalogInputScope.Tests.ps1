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

It 'keeps authenticated scenario proof through routing-policy additions and still rejects changed workloads and artifact hashes' {
    Mock Get-DevelopE2EStandStateSha256 {'c'*64}
    $f=New-ScenarioPlanFixture
    Mock Get-Command {[pscustomobject]@{Source=$f.artifact}} -ParameterFilter {$Name -contains 'go.exe'}
    Save-IncrementalJourneyProofs $f
    $old=Get-DevelopE2EInputIdentity -RepositoryRoot $f.root -Journey upgrade -Catalog $f.catalog -ProjectRoot $f.stand -AiRulesSource $f.rules -AgentTarget kilocode -ArtifactBinding $f.binding
    $original=Join-Path $f.root '.git/upgrade.json';$originalHash=(Get-FileHash $original).Hash
    $baselineTree=(& git -C $f.root rev-parse 'HEAD^{tree}').Trim()
    $rawPath=Join-Path $f.root '.git/policy-baseline.json'
    $raw=@{schemaVersion=3;status='passed';candidate=@{tree=$baselineTree};requestedJourneys=@('upgrade');journeys=@(@{name='upgrade';status='passed';coverage=@($f.catalog.developJourneys.scenarios.upgrade.id)})}
    [IO.File]::WriteAllText($rawPath,($raw|ConvertTo-Json -Depth 8))
    Save-DevelopScenarioExecution $f.root $rawPath upgrade $old $old $f.catalog | Should -Not -BeNullOrEmpty
    $old=$old | ConvertTo-Json -Depth 32 | ConvertFrom-Json
    # New ownership for an unchanged node is routing metadata, not new native work.
    $f.catalog.developJourneys.scenarioInputs[0].functions | Add-Member -NotePropertyName 'Untouched-Owner' -NotePropertyValue @('fresh.install')
    [IO.File]::WriteAllText((Join-Path $f.root 'tests/quality-contracts.json'),($f.catalog|ConvertTo-Json -Depth 24))
    & git -C $f.root add --all; & git -C $f.root commit --quiet -m 'classify an independent owner'
    $tree=(& git -C $f.root rev-parse 'HEAD^{tree}').Trim()
    $current=Get-DevelopE2EInputIdentity -RepositoryRoot $f.root -Journey upgrade -Catalog $f.catalog -ProjectRoot $f.stand -AiRulesSource $f.rules -AgentTarget kilocode -ArtifactBinding $f.binding
    (Get-DevelopScenarioWorkloadHash $old.inventory.contract) | Should -BeExactly (Get-DevelopScenarioWorkloadHash $current.inventory.contract)
    $catalogBefore=Get-DevelopHistoricalSourceText $f.root $f.base 'tests/quality-contracts.json'
    $catalogAfter=[IO.File]::ReadAllText((Join-Path $f.root 'tests/quality-contracts.json'))
    (Get-DevelopScenarioSourceProjection 'tests/quality-contracts.json' $catalogBefore upgrade @('update') $f.catalog) |
        Should -BeExactly (Get-DevelopScenarioSourceProjection 'tests/quality-contracts.json' $catalogAfter upgrade @('update') $f.catalog)
    Test-DevelopScenarioEquivalentInput $f.root $old $current $f.base @('update') $f.catalog | Should -BeTrue
    $records=@(Get-DevelopScenarioReusePlan $f.root $tree upgrade $current $f.catalog -AllowPendingStatic)
    @($records|Where-Object execution -eq reuse).Count | Should -Be 3 -Because ($records | ConvertTo-Json -Depth 10 -Compress)
    @($records|Where-Object {$_.proof.report.schemaVersion -eq 3}).Count | Should -Be 3
    (Get-FileHash $original).Hash | Should -BeExactly $originalHash
    Test-DevelopScenarioEquivalentInput $f.root $old $current $f.base @('update') $f.catalog | Should -BeTrue
    $changed=$current|ConvertTo-Json -Depth 32|ConvertFrom-Json
    $changed.inventory.external.artifacts.ITL_ONDEMAND_MCP_SOURCE_BUILD_EXE='d'*64
    $changed.fingerprint=Get-DevelopE2ECanonicalJsonSha256 $changed.inventory
    Test-DevelopScenarioEquivalentInput $f.root $old $changed $f.base @('update') $f.catalog | Should -BeFalse
    $changed=$current|ConvertTo-Json -Depth 32|ConvertFrom-Json
    $changed.inventory.contract.scenarios[0].operations+=@('new-native-assertion')
    $changed.fingerprint=Get-DevelopE2ECanonicalJsonSha256 $changed.inventory
    Test-DevelopScenarioEquivalentInput $f.root $old $changed $f.base @('update') $f.catalog | Should -BeFalse
    # The current route, not the old classification, decides source equivalence.
    Set-ScenarioFixtureChange $f 'Change-Update'
    $changed=Get-DevelopE2EInputIdentity -RepositoryRoot $f.root -Journey upgrade -Catalog $f.catalog -ProjectRoot $f.stand -AiRulesSource $f.rules -AgentTarget kilocode -ArtifactBinding $f.binding
    Test-DevelopScenarioEquivalentInput $f.root $old $changed $f.base @('update') $f.catalog | Should -BeFalse
    Test-DevelopScenarioEquivalentInput $f.root $old $changed $f.base @('configuration-rejection') $f.catalog | Should -BeTrue
    $changed=$current|ConvertTo-Json -Depth 32|ConvertFrom-Json
    $changed.inventory.external.artifacts.ITL_ONDEMAND_MCP_SOURCE_BUILD_EXE='d'*64
    $changed.fingerprint=Get-DevelopE2ECanonicalJsonSha256 $changed.inventory
    Mock Test-DevelopScenarioEquivalentInput {throw 'Different artifacts must be rejected before workload/source projection'}
    $records=@(Get-DevelopScenarioReusePlan $f.root $tree upgrade $changed $f.catalog -AllowPendingStatic)
    @($records|Where-Object execution -eq reuse).Count | Should -Be 0
    @($records|ForEach-Object reuseDiagnostics|ForEach-Object code) | Should -Contain 'ARTIFACT_INPUTS_CHANGED'
    Should -Invoke Test-DevelopScenarioEquivalentInput -Times 0 -Exactly
}

It 'keeps Pester routing edits outside native workload but rejects unknown catalog fields' {
    Mock Get-DevelopE2EStandStateSha256 {'c'*64}
    $f=New-ScenarioPlanFixture
    Mock Get-Command {[pscustomobject]@{Source=$f.artifact}} -ParameterFilter {$Name -contains 'go.exe'}
    $old=Get-DevelopE2EInputIdentity -RepositoryRoot $f.root -Journey fresh -Catalog $f.catalog -ProjectRoot $f.stand -AiRulesSource $f.rules -AgentTarget kilocode -ArtifactBinding $f.binding
    $f.catalog.contracts[0].tests+=@('tests/pester/Future.Tests.ps1')
    $f.catalog|Add-Member -NotePropertyName pesterWorkers -NotePropertyValue @{qualificationImplicitDefault=2} -Force
    $path=Join-Path $f.root 'tests/quality-contracts.json'
    [IO.File]::WriteAllText($path,($f.catalog|ConvertTo-Json -Depth 24))
    $now=Get-DevelopE2EInputIdentity -RepositoryRoot $f.root -Journey fresh -Catalog $f.catalog -ProjectRoot $f.stand -AiRulesSource $f.rules -AgentTarget kilocode -ArtifactBinding $f.binding
    Test-DevelopScenarioEquivalentInput $f.root $old $now $f.base @('install') $f.catalog | Should -BeTrue
    $f.catalog|Add-Member -NotePropertyName unknownNativePolicy -NotePropertyValue 'must bind'
    [IO.File]::WriteAllText($path,($f.catalog|ConvertTo-Json -Depth 24))
    $now=Get-DevelopE2EInputIdentity -RepositoryRoot $f.root -Journey fresh -Catalog $f.catalog -ProjectRoot $f.stand -AiRulesSource $f.rules -AgentTarget kilocode -ArtifactBinding $f.binding
    Test-DevelopScenarioEquivalentInput $f.root $old $now $f.base @('install') $f.catalog | Should -BeFalse
}

It 'keeps the linked MCP reference under static proof without exempting unknown references or unauthenticated source' {
    Mock Get-DevelopE2EStandStateSha256 {'c'*64}
    $f=New-ScenarioPlanFixture
    Mock Get-Command {[pscustomobject]@{Source=$f.artifact}} -ParameterFilter {$Name -contains 'go.exe'}
    $relative='.agents/skills/1c-workflow/references/mcp.md'
    $path=Join-Path $f.root $relative
    [void][IO.Directory]::CreateDirectory((Split-Path $path))
    Copy-Item -LiteralPath (Join-Path $RepoRoot $relative) -Destination $path
    $f.catalog.contracts[0].paths+=@($relative)
    [IO.File]::WriteAllText((Join-Path $f.root 'tests/quality-contracts.json'),($f.catalog|ConvertTo-Json -Depth 24))
    & git -C $f.root add --all; & git -C $f.root commit --quiet -m 'MCP reference baseline'
    $f.base=(& git -C $f.root rev-parse HEAD).Trim()
    Save-IncrementalJourneyProofs $f
    $old=Get-DevelopE2EInputIdentity -RepositoryRoot $f.root -Journey fresh -Catalog $f.catalog -ProjectRoot $f.stand -AiRulesSource $f.rules -AgentTarget kilocode -ArtifactBinding $f.binding
    [IO.File]::AppendAllText($path,"`nUpdated broker recovery instructions.`n")
    & git -C $f.root add --all; & git -C $f.root commit --quiet -m 'MCP reference documentation'
    $tree=(& git -C $f.root rev-parse 'HEAD^{tree}').Trim()
    $selected=Resolve-DevelopE2EJourneyPlanCore -RepositoryRoot $f.root -BaseRef $f.base -ChangedPath @($relative) -Catalog $f.catalog
    @($selected.journeys) | Should -BeNullOrEmpty
    $now=Get-DevelopE2EInputIdentity -RepositoryRoot $f.root -Journey fresh -Catalog $f.catalog -ProjectRoot $f.stand -AiRulesSource $f.rules -AgentTarget kilocode -ArtifactBinding $f.binding
    $records=@(Get-DevelopScenarioReusePlan $f.root $tree fresh $now $f.catalog -AllowPendingStatic)
    @($records|Where-Object execution -eq reuse).Count | Should -Be 6
    $tampered=$old|ConvertTo-Json -Depth 32|ConvertFrom-Json
    ($tampered.inventory.inputs|Where-Object path -eq $relative).sha256='e'*64
    $tampered.fingerprint=Get-DevelopE2ECanonicalJsonSha256 $tampered.inventory
    Test-DevelopScenarioEquivalentInput $f.root $tampered $now $f.base @('verification') $f.catalog | Should -BeFalse
    $unknown='.agents/skills/1c-workflow/references/unknown-native.md'
    [IO.File]::WriteAllText((Join-Path $f.root $unknown),'unknown native input')
    & git -C $f.root add --all; & git -C $f.root commit --quiet -m 'unknown reference'
    $now=Get-DevelopE2EInputIdentity -RepositoryRoot $f.root -Journey fresh -Catalog $f.catalog -ProjectRoot $f.stand -AiRulesSource $f.rules -AgentTarget kilocode -ArtifactBinding $f.binding
    Test-DevelopScenarioEquivalentInput $f.root $old $now $f.base @('verification') $f.catalog | Should -BeFalse
}
}
