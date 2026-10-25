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

It 'routes scenarios through the real checker and a native child, then reuses the composed proof without launching again' {
    Mock Get-DevelopE2EStandStateSha256 {'c'*64}
    $f=New-ScenarioPlanFixture
    Mock Get-Command {[pscustomobject]@{Source=$f.artifact}} -ParameterFilter {$Name -contains 'go.exe'}
    Save-IncrementalJourneyProofs $f
    Set-ScenarioFixtureChange $f 'Change-Mcp'
    $repoRoot=$f.root;$qualityCatalog=$f.catalog;$tree=(& git -C $f.root rev-parse 'HEAD^{tree}').Trim()
    $outputRoot=Join-Path $f.root '.git/output';[void][IO.Directory]::CreateDirectory($outputRoot)
    $FreshProjectsRoot='C:\itlj'
    $script:releaseContext=$null;$script:aiRulesRelease=$null
    $script:developQualificationRoot=Join-Path $f.root '.git/current';[void][IO.Directory]::CreateDirectory($script:developQualificationRoot)
    $script:developCurrentStaticProof=Save-IncrementalStaticProof $f
    $script:developRulesSource=$f.rules;$script:developJourneyInputs=@{};$script:developAncestorRoutes=@{}
    $script:sourceE2EArtifactBinding=Find-SourceE2EArtifactBinding -RepositoryRoot $f.root
    $script:sourceE2EArtifactBindingPath=Join-Path $f.root '.git/binding.json'
    [IO.File]::WriteAllText($script:sourceE2EArtifactBindingPath,($script:sourceE2EArtifactBinding|ConvertTo-Json -Depth 8))
    $script:developScript=Join-Path $f.root '.git/native-scenario-child.ps1'
    $child=@'
param($CandidateRoot,$ProjectRoot,$AiRulesSource,$OutputPath,$Journey,$Scenario,$FreshProjectsRoot,$AgentTarget,$ArtifactBindingPath)
$ErrorActionPreference='Stop'
$binding=Get-Content -LiteralPath $ArtifactBindingPath -Raw -Encoding UTF8|ConvertFrom-Json
foreach($entry in $binding.paths.PSObject.Properties){if(-not (Test-Path -LiteralPath $entry.Value -PathType Leaf)){throw 'binding lost'}}
$tree=(& git -C $CandidateRoot rev-parse 'HEAD^{tree}').Trim()
$value=@{schemaVersion=3;kind='itl-develop-e2e';status='passed';candidate=@{tree=$tree};requestedJourneys=@($Journey);journeys=@(@{name=$Journey;status='passed';coverage=@($Scenario.Split(','))})}
[IO.File]::WriteAllText($OutputPath,($value|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
[IO.File]::AppendAllText((Join-Path $CandidateRoot '.git/native-launches.log'),"$Journey=$Scenario;binding=$(@($binding.paths.PSObject.Properties).Count)`n")
'@
    [IO.File]::WriteAllText($script:developScript,$child,[Text.UTF8Encoding]::new($false))
    Mock Get-DevelopE2EIdentitySha256 {'a'*64}
    Mock Invoke-PowerShellChild {
        & (Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe') -NoLogo -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @Arguments
        if($LASTEXITCODE -ne 0){throw 'native scenario child failed'}
    }
    $routePlan=Resolve-DevelopE2EJourneyPlan -RepositoryRoot $f.root -BaseRef $f.base
    Ensure-DevelopE2ERoute -Journey fresh -Plan $routePlan -DeferForStatic | Should -BeNullOrEmpty
    Should -Invoke Invoke-PowerShellChild -Times 0 -Exactly
    $path=Ensure-DevelopE2ERoute -Journey fresh -Plan $routePlan
    $report=Get-Content $path -Raw -Encoding UTF8|ConvertFrom-Json
    $report.schemaVersion | Should -Be 2
    @($report.result.scenarioEvidence | Where-Object execution -eq 'executed' | ForEach-Object id) | Should -Be @('install')
    @($report.result.scenarioEvidence | Where-Object execution -eq 'reused').Count | Should -Be 5
    (Get-Content (Join-Path $f.root '.git/native-launches.log') -Raw).Trim() | Should -BeExactly 'fresh=install;binding=3'
    $sha=(Get-FileHash $path).Hash
    $again=Ensure-DevelopE2ERoute -Journey fresh -Plan $routePlan
    (Get-FileHash $again).Hash | Should -BeExactly $sha
    Should -Invoke Invoke-PowerShellChild -Times 1 -Exactly
    $script:developScenarioExecution.ContainsKey('fresh') | Should -BeFalse
    Test-DevelopE2ERouteReport -Path $again -Tree $tree -Journey fresh -IdentitySha256 ('a'*64) -StandStateSha256 ('c'*64) | Should -BeTrue
    $firstTree=$tree;$firstPath=Join-Path $f.root '.git/first-composition.json';Copy-Item $path $firstPath
    $firstNative=@($report.result.scenarioEvidence|Where-Object execution -eq 'executed')[0].path
    $originalVerification=@($report.result.scenarioEvidence|Where-Object id -eq 'verification')[0].path
    $runtime=Join-Path $f.root 'runtime.ps1'
    [IO.File]::WriteAllText($runtime,[IO.File]::ReadAllText($runtime).Replace("function Change-Mcp {'v2'}","function Change-Mcp {'v3'}"))
    & git -C $f.root add -- runtime.ps1;& git -C $f.root commit --quiet -m 'next producer change'
    $tree=(& git -C $f.root rev-parse 'HEAD^{tree}').Trim()
    $script:developCurrentStaticProof=Save-IncrementalStaticProof $f
    $next=Ensure-DevelopE2ERoute -Journey fresh -Plan (Resolve-DevelopE2EJourneyPlan -RepositoryRoot $f.root -BaseRef $f.base)
    $report=Get-Content $next -Raw -Encoding UTF8|ConvertFrom-Json
    @($report.result.scenarioEvidence|Where-Object id -eq 'verification')[0].path | Should -BeExactly $originalVerification
    Should -Invoke Invoke-PowerShellChild -Times 2 -Exactly
    # The next complete certificate has no dependency on the previous changed
    # producer's execution. Its unchanged scenarios point directly at the leaf.
    [IO.File]::AppendAllText($firstNative,'corruption')
    Test-DevelopE2ERouteReport -Path $firstPath -Tree $firstTree -Journey fresh -IdentitySha256 ('a'*64) -StandStateSha256 ('c'*64) | Should -BeFalse
    Test-DevelopE2ERouteReport -Path $next -Tree $tree -Journey fresh -IdentitySha256 ('a'*64) -StandStateSha256 ('c'*64) | Should -BeTrue
    $native=@($report.result.scenarioEvidence|Where-Object execution -eq 'executed')[0].path
    [IO.File]::AppendAllText($native,'corruption')
    Test-DevelopE2ERouteReport -Path $next -Tree $tree -Journey fresh -IdentitySha256 ('a'*64) -StandStateSha256 ('c'*64) | Should -BeFalse
}

It 'checkpoints a native subset without granting full qualification and composes it only after complete static (<NativeJourney>)' -TestCases @(@{NativeJourney='fresh'},@{NativeJourney='all'}) {
    param($NativeJourney)
    Mock Get-DevelopE2EStandStateSha256 {'c'*64}
    $f=New-ScenarioPlanFixture
    Mock Get-Command {[pscustomobject]@{Source=$f.artifact}} -ParameterFilter {$Name -contains 'go.exe'}
    Save-IncrementalJourneyProofs $f
    Set-ScenarioFixtureChange $f 'Change-Mcp'
    $repoRoot=$f.root;$qualityCatalog=$f.catalog;$tree=(& git -C $f.root rev-parse 'HEAD^{tree}').Trim()
    $binding=Find-SourceE2EArtifactBinding -RepositoryRoot $f.root
    $inputs=Get-DevelopE2EInputIdentity -RepositoryRoot $f.root -Journey fresh -Catalog $f.catalog -ProjectRoot $f.stand -AiRulesSource $f.rules -AgentTarget kilocode -ArtifactBinding $binding
    $rawPath=Join-Path $f.root '.git/subset.json'
    $raw=@{schemaVersion=3;kind='itl-develop-e2e';status='passed';candidate=@{tree=$tree};requestedJourneys=@('fresh');journeys=@(@{name='fresh';status='passed';coverage=@('install')})}
    if($NativeJourney -eq 'all') {$raw.requestedJourneys=@('upgrade','fresh');$raw.journeys+=@(@{name='upgrade';status='passed';coverage=@('update')})}
    [IO.File]::WriteAllText($rawPath,($raw|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    $cache=Save-DevelopScenarioExecution -RepositoryRoot $f.root -RawPath $rawPath -Journey fresh -Before $inputs -After $inputs -Catalog $f.catalog
    $cache | Should -Not -BeNullOrEmpty
    $partial=Join-Path $cache 'route-report.json'
    Test-DevelopE2ERouteReport -Path $partial -Tree $tree -Journey fresh -IdentitySha256 $inputs.fingerprint -StandStateSha256 ('c'*64) | Should -BeFalse
    Test-DevelopE2ERouteReport -Path $partial -Tree $tree -Journey fresh -IdentitySha256 $inputs.fingerprint -StandStateSha256 ('c'*64) -RequiredScenario install | Should -BeTrue
    Test-DevelopE2ERouteReport -Path $partial -Tree $tree -Journey fresh -IdentitySha256 $inputs.fingerprint -StandStateSha256 ('c'*64) -RequiredScenario verification | Should -BeFalse
    $script:developQualificationRoot=Join-Path $f.root '.git/current';[void][IO.Directory]::CreateDirectory($script:developQualificationRoot)
    $outputRoot=Join-Path $f.root '.git/output';[void][IO.Directory]::CreateDirectory($outputRoot)
    $FreshProjectsRoot='C:\itlj';$script:developRulesSource=$f.rules;$script:sourceE2EArtifactBinding=$binding
    $script:developJourneyInputs=@{};$script:developAncestorRoutes=@{};$script:developCurrentStaticProof=$null
    $script:releaseContext=$null;$script:aiRulesRelease=$null
    $plan=Resolve-DevelopE2EJourneyPlan -RepositoryRoot $f.root -BaseRef $f.base
    Mock Get-DevelopE2EIdentitySha256 {'a'*64}
    Mock Invoke-PowerShellChild {throw 'UNEXPECTED_NATIVE_JOURNEY'}
    {Ensure-DevelopE2ERoute -Journey fresh -Plan $plan} | Should -Throw '*SCENARIO_STATIC_REQUIRED*'
    $script:developCurrentStaticProof=Save-IncrementalStaticProof $f
    $full=Ensure-DevelopE2ERoute -Journey fresh -Plan $plan
    (Get-Content $full -Raw -Encoding UTF8|ConvertFrom-Json).schemaVersion | Should -Be 2
    Test-DevelopE2ERouteReport -Path $full -Tree $tree -Journey fresh -IdentitySha256 ('a'*64) -StandStateSha256 ('c'*64) | Should -BeTrue
    Should -Invoke Invoke-PowerShellChild -Times 0 -Exactly
}
}
