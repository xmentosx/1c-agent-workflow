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

It 'keeps Go test and README changes native-free while preserving runtime and embed invalidation' {
    Mock Get-DevelopE2EStandStateSha256 {'c'*64}
    $f=New-ScenarioPlanFixture
    Mock Get-Command {[pscustomobject]@{Source=$f.artifact}} -ParameterFilter {$Name -contains 'go.exe'}
    $catalog=Get-QualityContractCatalog $RepoRoot
    $paths=@('tools/itl-ondemand-mcp/main.go','tools/itl-ondemand-mcp/main_test.go','tools/itl-ondemand-mcp/README.md')
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'scripts/Build-ItlOnDemandMcp.ps1') -Destination (Join-Path $f.root 'scripts/Build-ItlOnDemandMcp.ps1')
    foreach($path in $paths) {
        $full=Join-Path $f.root $path;[void][IO.Directory]::CreateDirectory((Split-Path $full))
        [IO.File]::WriteAllText($full,"package main`n")
    }
    $f.catalog.contracts[0].paths+=@($paths)+@('tools/itl-ondemand-mcp/*')
    [IO.File]::WriteAllText((Join-Path $f.root 'tests/quality-contracts.json'),($f.catalog|ConvertTo-Json -Depth 24))
    & git -C $f.root add --all; & git -C $f.root commit --quiet -m 'native Go baseline'
    $base=(& git -C $f.root rev-parse HEAD).Trim()
    $f.base=$base
    Save-IncrementalJourneyProofs $f
    foreach($path in $paths[1..2]) {
        [IO.File]::AppendAllText((Join-Path $f.root $path),"// static-only change`n")
        $route=Resolve-DevelopE2EJourneyPlanCore $f.root $base @($path) $catalog
        @($route.journeys).Count | Should -Be 0
        $before=Get-DevelopHistoricalSourceText $f.root $base $path
        $after=[IO.File]::ReadAllText((Join-Path $f.root $path))
        (Get-DevelopScenarioSourceProjection $path $before fresh @('verification') $catalog -RepositoryRoot $f.root -Commit $base) |
            Should -BeExactly (Get-DevelopScenarioSourceProjection $path $after fresh @('verification') $catalog -RepositoryRoot $f.root)
        @((Resolve-QualityContractsForPaths $catalog @($path)).tests).Count | Should -BeGreaterThan 0
        & git -C $f.root add --all; & git -C $f.root commit --quiet -m 'static-only Go input'
        $tree=(& git -C $f.root rev-parse 'HEAD^{tree}').Trim()
        $current=Get-DevelopE2EInputIdentity -RepositoryRoot $f.root -Journey fresh -Catalog $f.catalog -ProjectRoot $f.stand -AiRulesSource $f.rules -AgentTarget kilocode -ArtifactBinding $f.binding
        $records=@(Get-DevelopScenarioReusePlan $f.root $tree fresh $current $f.catalog -AllowPendingStatic)
        @($records|Where-Object execution -eq reuse).Count | Should -Be 6 -Because ($records|ConvertTo-Json -Depth 8 -Compress)
    }
    [IO.File]::WriteAllText((Join-Path $f.root 'tools/itl-ondemand-mcp/added_test.go'),"package main`n")
    Remove-Item -LiteralPath (Join-Path $f.root $paths[1])
    & git -C $f.root add --all; & git -C $f.root commit --quiet -m 'add and retire static Go regressions'
    $tree=(& git -C $f.root rev-parse 'HEAD^{tree}').Trim()
    $current=Get-DevelopE2EInputIdentity -RepositoryRoot $f.root -Journey fresh -Catalog $f.catalog -ProjectRoot $f.stand -AiRulesSource $f.rules -AgentTarget kilocode -ArtifactBinding $f.binding
    @((Get-DevelopScenarioReusePlan $f.root $tree fresh $current $f.catalog -AllowPendingStatic)|Where-Object execution -eq reuse).Count | Should -Be 6
    $runtime=Join-Path $f.root $paths[0]
    [IO.File]::AppendAllText($runtime,"// changed broker runtime`n")
    @(Resolve-DevelopE2EJourneyPlanCore $f.root $base @($paths[0]) $catalog).journeys | Should -Contain 'fresh'
    $builder=Join-Path $f.root 'scripts/Build-ItlOnDemandMcp.ps1'
    $originalBuilder=[IO.File]::ReadAllBytes($builder)
    [IO.File]::AppendAllText($builder,"`nGet-Content 'tools/itl-ondemand-mcp/README.md'`n")
    Test-DevelopGoBuildOnlyPath $f.root $paths[2] | Should -BeFalse
    [IO.File]::WriteAllBytes($builder,$originalBuilder)
    [IO.File]::AppendAllText($runtime,"//go:embed README.md`n")
    Test-DevelopGoBuildOnlyPath $f.root $paths[2] | Should -BeFalse
    @(Resolve-DevelopE2EJourneyPlanCore $f.root $base @($paths[2]) $catalog).journeys | Should -Contain 'fresh'
}

It 'reuses only broker-independent scenarios after an actual locked broker and Go source change (positive=<PositiveStand>)' -TestCases @(@{PositiveStand=$false},@{PositiveStand=$true}) {
    param($PositiveStand)
    Mock Get-DevelopE2EStandStateSha256 {'c'*64}
    $f=New-ScenarioPlanFixture
    Mock Get-Command {[pscustomobject]@{Source=$f.artifact}} -ParameterFilter {$Name -contains 'go.exe'}
    if($PositiveStand) {
        $positive=Join-Path $f.root '.git/positive'
        [void][IO.Directory]::CreateDirectory((Join-Path $positive '.agent-1c'))
        foreach($relative in @('.agent-1c/project.json','.agent-1c/release-e2e.json','.dev.env')) {
            Copy-Item -LiteralPath (Join-Path $f.stand $relative) -Destination (Join-Path $positive $relative)
        }
        $positiveDevelop=Join-Path $f.root '.git/positive-develop'
        [void][IO.Directory]::CreateDirectory((Join-Path $positiveDevelop '.agent-1c'))
        Copy-Item -LiteralPath (Join-Path $positive '.agent-1c/project.json') -Destination (Join-Path $positiveDevelop '.agent-1c/project.json')
        [IO.File]::WriteAllText((Join-Path $positive '.agent-1c/release-e2e.json'),(@{developWorktreePath=$positiveDevelop}|ConvertTo-Json))
        [IO.File]::WriteAllText((Join-Path $f.stand '.agent-1c/release-e2e.json'),(@{developConfigurationRejection=@{positiveProjectRoot=$positive}}|ConvertTo-Json -Depth 6))
    }
    $guidance=@('advanced-actions','verification-change','verification-result','verification-suite-selection'|ForEach-Object {'.agents/skills/1c-workflow/references/'+$_+'.md'})
    foreach($relative in $guidance) {
        $target=Join-Path $f.root $relative;[void][IO.Directory]::CreateDirectory((Split-Path $target))
        Copy-Item -LiteralPath (Join-Path $RepoRoot $relative) -Destination $target
    }
    # Bind the added guidance inputs to static ownership, as the actual catalog does.
    $f.catalog.contracts[0].paths+=@('tools/itl-ondemand-mcp/main.go')+$guidance
    [IO.File]::WriteAllText((Join-Path $f.root 'tests/quality-contracts.json'),($f.catalog|ConvertTo-Json -Depth 24))
    $source=Join-Path $f.root 'tools/itl-ondemand-mcp/main.go'
    [void][IO.Directory]::CreateDirectory((Split-Path $source))
    [IO.File]::WriteAllText($source,"package main`nfunc main() {}")
    & git -C $f.root add --all; & git -C $f.root commit --quiet -m 'broker baseline'
    $f.base=(& git -C $f.root rev-parse HEAD).Trim()
    Save-IncrementalJourneyProofs $f
    $old=Get-DevelopE2EInputIdentity -RepositoryRoot $f.root -Journey fresh -Catalog $f.catalog -ProjectRoot $f.stand -AiRulesSource $f.rules -AgentTarget kilocode -ArtifactBinding $f.binding
    $broker=Join-Path $f.root '.git/new-broker.exe'
    [IO.File]::WriteAllBytes($broker,[byte[]](4,5,6,7))
    $f.binding.paths.ITL_ONDEMAND_MCP_SOURCE_BUILD_EXE=$broker
    $lockPath=Join-Path $f.root 'templates/dependency-lock.json'
    $lock=Get-Content $lockPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $lock.dependencies.itlOndemandMcp.sha256=(Get-FileHash $broker).Hash.ToLowerInvariant()
    $lock.dependencies.itlOndemandMcp.version='2'
    [IO.File]::WriteAllText($lockPath,($lock|ConvertTo-Json -Depth 8))
    [IO.File]::AppendAllText($source,"`n// changed native broker implementation")
    foreach($relative in $guidance) {[IO.File]::AppendAllText((Join-Path $f.root $relative),"`nChanged agent guidance, same native consumer.`n")}
    & git -C $f.root add --all; & git -C $f.root commit --quiet -m 'new locked broker'
    $tree=(& git -C $f.root rev-parse 'HEAD^{tree}').Trim()
    $now=Get-DevelopE2EInputIdentity -RepositoryRoot $f.root -Journey fresh -Catalog $f.catalog -ProjectRoot $f.stand -AiRulesSource $f.rules -AgentTarget kilocode -ArtifactBinding $f.binding
    $now | Should -Not -BeNullOrEmpty
    $records=@(Get-DevelopScenarioReusePlan $f.root $tree fresh $now $f.catalog -AllowPendingStatic)
    Test-DevelopScenarioEquivalentInput $f.root $old $now $f.base @('verification') $f.catalog | Should -BeTrue
    @($records|Where-Object execution -eq reuse|ForEach-Object id) | Should -Be @('stale-export','close') -Because ($records|Select-Object id,execution,reuseDiagnostics|ConvertTo-Json -Depth 6 -Compress)
    @($records|Where-Object execution -eq setup|ForEach-Object id) | Should -Be @('verification')
    @($records|Where-Object execution -eq execute|ForEach-Object id) | Should -Be @('install','branch','refresh')
    foreach($scenario in @('install','branch','refresh','future-scenario')) {
        Test-DevelopArtifactIdentityDifference $old $now fresh @($scenario) | Should -BeTrue
    }
    Test-DevelopArtifactIdentityDifference $old $now fresh | Should -BeTrue
    Test-DevelopArtifactIdentityDifference $old $now upgrade @('update') | Should -BeTrue
    $changedInputs=@()
    Test-DevelopArtifactIdentityDifference $old $now upgrade @('update') -ChangedInputs ([ref]$changedInputs) | Should -BeTrue
    $changedInputs | Should -Be @('artifact:ITL_ONDEMAND_MCP_SOURCE_BUILD_EXE')
    $upgrade=Get-DevelopE2EInputIdentity $f.root upgrade $f.catalog $f.stand $f.rules kilocode -ArtifactBinding $f.binding
    $upgradeRecords=@(Get-DevelopScenarioReusePlan $f.root $tree upgrade $upgrade $f.catalog -AllowPendingStatic)
    $expectedUpgrade=if($PositiveStand){@('update','configuration-rejection','verification-export')}else{@('update','verification-export')}
    @($upgradeRecords|Where-Object execution -eq execute|ForEach-Object id) | Should -Be $expectedUpgrade
    if(-not $PositiveStand) { @($upgradeRecords|Where-Object execution -eq 'not-applicable'|ForEach-Object id) | Should -Be @('configuration-rejection') }
    @($upgradeRecords|ForEach-Object reuseDiagnostics|Where-Object code -eq 'ARTIFACT_INPUTS_CHANGED'|ForEach-Object inputs|Sort-Object -Unique) | Should -Be @('artifact:ITL_ONDEMAND_MCP_SOURCE_BUILD_EXE')

    # A change to a native consumer is still bound, even for these scenarios.
    $runner=Join-Path $f.root 'scripts/invoke-develop-e2e.ps1'
    $runnerBytes=[IO.File]::ReadAllBytes($runner)
    [IO.File]::AppendAllText($runner,"`nWrite-Output 'new shared native consumer'`n")
    $consumerChanged=Get-DevelopE2EInputIdentity -RepositoryRoot $f.root -Journey fresh -Catalog $f.catalog -ProjectRoot $f.stand -AiRulesSource $f.rules -AgentTarget kilocode -ArtifactBinding $f.binding
    Test-DevelopScenarioEquivalentInput $f.root $old $consumerChanged $f.base @('verification') $f.catalog | Should -BeFalse
    [IO.File]::WriteAllBytes($runner,$runnerBytes)
    foreach($artifact in @('ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE','VANESSA_MCP_CLIENT_CFE_PATH','futureArtifact')) {
        $different=$now|ConvertTo-Json -Depth 32|ConvertFrom-Json
        $different.inventory.external.artifacts|Add-Member -NotePropertyName $artifact -NotePropertyValue ('e'*64) -Force
        $different.fingerprint=Get-DevelopE2ECanonicalJsonSha256 $different.inventory
        Test-DevelopScenarioEquivalentInput $f.root $old $different $f.base @('verification') $f.catalog | Should -BeFalse
        $changedInputs=@()
        Test-DevelopArtifactIdentityDifference $old $different fresh @('verification') -ChangedInputs ([ref]$changedInputs) | Should -BeTrue
        $changedInputs | Should -Be @('artifact:'+$artifact)

    }
    if($PositiveStand) {
        [IO.File]::AppendAllText((Join-Path $positive '.dev.env'),"`nUI_TESTING=false`n")
        $standChanged=Get-DevelopE2EInputIdentity -RepositoryRoot $f.root -Journey fresh -Catalog $f.catalog -ProjectRoot $f.stand -AiRulesSource $f.rules -AgentTarget kilocode -ArtifactBinding $f.binding
        Test-DevelopScenarioEquivalentInput $f.root $old $standChanged $f.base @('verification') $f.catalog | Should -BeFalse
    }
    # A tampered physical broker is rejected when taking the CURRENT binding;
    # a scenario projection never replaces that exact-byte admission.
    [IO.File]::AppendAllText($broker,'tamper')
    {Get-SourceE2EArtifactBindingHashes $f.root $f.binding} | Should -Throw '*HASH_MISMATCH*'
}
}
