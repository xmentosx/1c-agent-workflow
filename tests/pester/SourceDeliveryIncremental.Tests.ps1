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
    @($selection.tests) | Should -Be @('tests/pester/SourceDeliveryIncremental.Tests.ps1','tests/pester/SourceDeliveryPlan.Tests.ps1')
    $route=Resolve-DevelopE2EJourneyPlan -RepositoryRoot $RepoRoot -ChangedPath @($path) -Catalog $catalog
    @($route.journeys) | Should -BeNullOrEmpty
    @($route.unknownPaths) | Should -BeNullOrEmpty
}

It 'delegates only remote component inspection from a clean pinned candidate (<Case>)' -TestCases @(
    @{Case='exact'},@{Case='dirty'},@{Case='mutation'},@{Case='historical'}
) {
    param($Case)
    & {
        $f=New-IncrementalPlanFixture
        $module=Join-Path $f.root 'scripts/source-delivery-component.ps1'
        $inspector='function Get-DeliveryRemoteAssetDigest { }; function Get-DeliveryRemoteAssetState { [pscustomobject]@{status="matched";sha256=("a"*64)} }'
        if($Case -eq 'mutation') {$inspector='function Get-DeliveryRemoteAssetDigest { }; function Get-DeliveryRemoteAssetState { [IO.File]::AppendAllText("'+$module.Replace('"','""')+'","# mutation"); [pscustomobject]@{status="matched"} }'}
        if($Case -eq 'historical') {$inspector='# historical module without a digest inspector'}
        [IO.File]::WriteAllText($module,$inspector,[Text.UTF8Encoding]::new($true))
        & git -C $f.root add --all; & git -C $f.root commit --quiet -m 'candidate component inspector'
        $head=(& git -C $f.root rev-parse HEAD).Trim()
        function Invoke-WorktreeGit {param($Root,$Arguments); Invoke-RepositoryGit -RepositoryRoot $Root -Arguments $Arguments}
        function Get-DeliveryRemoteAssetState { [pscustomobject]@{status='historical-byte-check'} }
        function Get-OwnedComponentPublicationPlan {
            param($CandidateRoot,$CandidateCommit)
            $remote=Get-DeliveryRemoteAssetState
            [pscustomobject]@{status='planned';candidateCommit=$CandidateCommit;requiredReleaseCapabilities=@('extension-smoke');remote=$remote}
        }
        if($Case -eq 'dirty') {[IO.File]::AppendAllText($module,'# dirty input')}
        if($Case -in @('dirty','mutation')) {
            {Invoke-DeliveryCandidateComponentPlan -CandidateRoot $f.root -CandidateCommit $head} | Should -Throw '*CANDIDATE_CHANGED*'
        } else {
            $plan=Invoke-DeliveryCandidateComponentPlan -CandidateRoot $f.root -CandidateCommit $head
            $plan.candidateCommit | Should -BeExactly $head
            @($plan.requiredReleaseCapabilities) | Should -Be @('extension-smoke')
            $plan.remote.status | Should -BeExactly $(if($Case -eq 'historical') {'historical-byte-check'} else {'matched'})
            (Get-DeliveryRemoteAssetState).status | Should -BeExactly 'historical-byte-check' -Because 'candidate query definitions cannot escape their child scope'
        }
    }
}

It 'uses the pinned candidate calculator through the native legacy <LegacyPart> Plan shim without changing authority or saved proof' -TestCases @(@{LegacyPart='calculator'},@{LegacyPart='component-inspection'}) {
        param($LegacyPart)
        $f=New-IncrementalPlanFixture; $script:Root=$f.root
        $modules=@('quality-contracts.ps1','develop-e2e-qualification.ps1','develop-journey-inputs.ps1','develop-e2e-scenarios.ps1','stand-env-identity.ps1','source-delivery-plan.ps1','source-e2e-artifact-discovery.ps1','git-path-list.ps1')
        foreach($name in $modules) {Copy-Item -LiteralPath (Join-Path $RepoRoot ('scripts/'+$name)) -Destination (Join-Path $f.root ('scripts/'+$name)) -Force}
        $f.catalog.contracts[0].paths+=@($modules|ForEach-Object{'scripts/'+$_})
        [IO.File]::WriteAllText((Join-Path $f.root 'tests/quality-contracts.json'),($f.catalog|ConvertTo-Json -Depth 16))
        $names=@('New-DeliveryWorktree','Remove-DeliveryWorktree','Get-DeliveryTextSha256','Get-DeliveryFileIdentity','Get-DeliveryFileSha256',
            'Invoke-DeliveryGit','Invoke-WorktreeGit','Get-GitValue','Get-DeliveryCommonGitDirectory')
        $definitions=@(foreach($file in @('source-delivery-supervisor.ps1','source-delivery-candidate.ps1')) {
            $t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot ('scripts/'+$file)),[ref]$t,[ref]$e)
            $ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in $names},$true)|ForEach-Object{$_.Extent.Text}
        }) -join "`n"
        $legacy=@'
param($Action,$RepositoryRoot,$SupervisorCommit,$SupervisorChannel,[switch]$BootstrapSupervisor,$AiRulesSource='',$E2EProjectRoot='',$Remote='origin')
. (Join-Path $PSScriptRoot 'git-path-list.ps1')
$script:Root=$RepositoryRoot;$script:Remote=$Remote;$script:DeliverySupervisorCommit=$SupervisorCommit;$script:DeliverySupervisorChannel=$SupervisorChannel;$script:DeliverySupervisorBootstrap=[bool]$BootstrapSupervisor;$script:DeliveryCustomGateBoundary=$false
function Assert-CleanDeliveryWorktree {
    if(@(Get-RepositoryGitPathList -RepositoryRoot $script:Root -Arguments @('status','--porcelain=v1','-z')).Count) {throw 'dirty fixture'}
}

function Get-SourceRegistrationSnapshot {
    [pscustomobject]@{entries=@([pscustomobject]@{id='test';base=(Get-GitValue -Arguments @('rev-parse','origin/develop'));head=(Get-GitValue -Arguments @('rev-parse','HEAD'))})}
}
function Get-SourceRegistrationStartPoint {param($Snapshot); $Snapshot.entries[0].head}
function Add-QueuedRangesToCandidate {param($CandidateRoot,$Entries,$PublishedDevelop)}
function Get-OwnedComponentPublicationPlan {param($CandidateRoot,$CandidateCommit); [pscustomobject]@{requiredReleaseCapabilities=@()}}
function Assert-ComponentPublicationFinalizerPreflight {
    param($CandidateRoot,$CandidateCommit,$Plan)
    [IO.File]::AppendAllText((Join-Path $script:Root '.git/preflight.log'),"preflight`n")
}
function Remove-DeliveryPreparedAiRulesWorktree {}
'@
        $legacy+="`n"+$definitions+@'

if($Action -eq 'Plan') {
    $base=Get-GitValue -Arguments @('rev-parse','origin/develop');$head=Get-GitValue -Arguments @('rev-parse','HEAD');$tree=Get-GitValue -Arguments @('rev-parse','HEAD^{tree}')
    $plan=[pscustomobject]@{schemaVersion=1;kind='itl-delivery-plan';planId=('c'*64);status='ready';supervisor=@{commit=$SupervisorCommit;channel='develop';bootstrap=$false};
        candidate=@{commit=$head;tree=$tree;baseCommit=$base};requireRelease=$false;releaseCapabilities=@();paths=@('runtime.ps1');contracts=@('runtime');
        stages=@(@{id='develop.static';mode='Develop';version=1;dependsOn=@();budgetSeconds=2400;inputFingerprint=('a'*64);execution='execute';reason='legacy policy'});
        queue=@(@{id='test';base=$base;head=$head});executedBudgetSeconds=2400;planningDurationMs=1}
    $dir=Join-Path (Get-DeliveryCommonGitDirectory) 'itl/plans/v1';[void][IO.Directory]::CreateDirectory($dir)
    $path=Join-Path $dir ($plan.planId+'.json')
    [IO.File]::WriteAllText($path,($plan|ConvertTo-Json -Depth 16))
    [IO.File]::WriteAllText((Join-Path $dir 'legacy.sha256'),(Get-FileHash -LiteralPath $path).Hash)
    $plan | ConvertTo-Json -Depth 16
}
'@
        [IO.File]::WriteAllText((Join-Path $f.root 'scripts/source-delivery-supervisor.ps1'),$legacy,[Text.UTF8Encoding]::new($true))
        $publishedCalculator=Join-Path $f.root 'scripts/source-delivery-plan.ps1'
        $legacyFunction=if($LegacyPart -eq 'calculator') {'Invoke-DeliveryCandidatePlanCalculation'} else {'Invoke-DeliveryCandidateComponentPlan'}
        [IO.File]::WriteAllText($publishedCalculator,([IO.File]::ReadAllText($publishedCalculator).Replace(('function '+$legacyFunction+' {'),'function Legacy-CalculationPlaceholder {')),[Text.UTF8Encoding]::new($true))
        $f.catalog.contracts[0].paths+='scripts/source-delivery-supervisor.ps1'
        [IO.File]::WriteAllText((Join-Path $f.root 'tests/quality-contracts.json'),($f.catalog|ConvertTo-Json -Depth 16))
        & git -C $f.root add --all; & git -C $f.root commit --quiet -m 'legacy published owner'
        $published=(& git -C $f.root rev-parse HEAD).Trim()
        & git -C $f.root update-ref refs/remotes/origin/develop $published
        $calculator=Join-Path $f.root 'scripts/source-delivery-plan.ps1'
        $text=[IO.File]::ReadAllText($calculator).Replace('complete static inventory with per-file proof reuse','candidate policy selected')
        [IO.File]::WriteAllText($calculator,$text,[Text.UTF8Encoding]::new($true))
        & git -C $f.root add --all; & git -C $f.root commit --quiet -m 'new candidate policy'
        $head=(& git -C $f.root rev-parse HEAD).Trim()
        # A frozen legacy plan already exists. A read-only preview must not
        # recalculate it, overwrite its bytes, or save a resumable replacement.
        $savedRoot=Join-Path $f.root '.git/itl/plans/v1'
        [void][IO.Directory]::CreateDirectory($savedRoot)
        $savedPath=Join-Path $savedRoot (('c'*64)+'.json')
        [IO.File]::WriteAllText($savedPath,'{"legacy":"immutable proof"}')
        $savedSha=(Get-FileHash -LiteralPath $savedPath).Hash
        # A local bare remote keeps the production fetch in the preview path.
        $bare=Join-Path $f.root '.git/remote.git'; & git init --bare --quiet $bare
        & git -C $f.root remote add origin $bare
        & git -C $f.root push --quiet origin "${published}:refs/heads/develop"
        $worker=Join-Path $f.root '.git/inspect.ps1';$output=Join-Path $f.root '.git/plan.json'
        $scriptText="& '"+(Join-Path $RepoRoot 'scripts/source-delivery.ps1').Replace("'","''")+"' -Action Plan -RepositoryRoot '"+$f.root.Replace("'","''")+"' | Set-Content -LiteralPath '"+$output.Replace("'","''")+"' -Encoding UTF8"
        [IO.File]::WriteAllText($worker,$scriptText,[Text.UTF8Encoding]::new($true))
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $worker
        $LASTEXITCODE | Should -Be 0
        $plan=Get-Content -LiteralPath $output -Raw -Encoding UTF8|ConvertFrom-Json
        $plan.resumable | Should -BeFalse
        $plan.invocationTiming.invocationDurationMs | Should -BeGreaterThan 0
        $plan.invocationTiming.invocationDurationMs | Should -BeGreaterThan $plan.planningDurationMs
        $plan.invocationTiming.supervisorPreparationDurationMs | Should -BeGreaterThan 0
        $plan.invocationTiming.supervisedPlanDurationMs | Should -BeGreaterThan 0
        $plan.invocationTiming.supervisorCleanupDurationMs | Should -BeGreaterThan 0
        $plan.calculator.commit | Should -BeExactly $head
        $plan.stages[0].reason | Should -BeExactly 'candidate policy selected'
        (Get-FileHash -LiteralPath $savedPath).Hash | Should -BeExactly $savedSha
        Test-Path (Join-Path $savedRoot 'legacy.sha256') | Should -BeFalse -Because 'the old Plan must never run'
        @(Get-Content -LiteralPath (Join-Path $f.root '.git/preflight.log')).Count | Should -Be 1
        Test-Path (Join-Path $savedRoot ($plan.planId+'.json')) | Should -BeFalse
        (& git -C $f.root rev-parse origin/develop).Trim() | Should -BeExactly $published
        (& git -C $f.root rev-parse HEAD).Trim() | Should -BeExactly $head
        @(Get-RepositoryGitPathList -RepositoryRoot $f.root -Arguments @('status','--porcelain=v1','-z')).Count | Should -Be 0
        # The same accepted parent calculator is used by new Plan and delivery;
        # changed candidate bytes must be rejected before either can save a plan.
        [IO.File]::AppendAllText($calculator,"`n# uncommitted input drift")
        {Invoke-DeliveryCandidatePlanCalculation -CandidateRoot $f.root -BaseCommit $published -CandidateCommit $head -CandidateTree $plan.candidate.tree} | Should -Throw '*CANDIDATE_CHANGED*'
        [IO.File]::WriteAllText($calculator,"function New-DeliveryQualityPlanForCandidate { [pscustomobject]@{kind='itl-delivery-plan';schemaVersion=1;candidate=@{commit=('b'*40);tree=('d'*40);baseCommit=('e'*40)}} }",[Text.UTF8Encoding]::new($true))
        & git -C $f.root add --all; & git -C $f.root commit --quiet -m 'invalid calculator envelope'
        $badHead=(& git -C $f.root rev-parse HEAD).Trim();$badTree=(& git -C $f.root rev-parse 'HEAD^{tree}').Trim()
        {Invoke-DeliveryCandidatePlanCalculation -CandidateRoot $f.root -BaseCommit $published -CandidateCommit $badHead -CandidateTree $badTree} | Should -Throw '*CALCULATOR_INVALID*'
        # A self-consistent calculator hash cannot waive the parent's required
        # component capabilities, even if its own policy proposes no Release.
        $t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($text,[ref]$t,[ref]$e)
        $node=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'New-DeliveryQualityPlanForCandidate'},$true)
        $withoutRelease=$text.Insert($node.Body.EndBlock.Statements[0].Extent.StartOffset,'$RequireRelease=$false; $ReleaseCapability=@(); ')
        [IO.File]::WriteAllText($calculator,$withoutRelease,[Text.UTF8Encoding]::new($true))
        [void][IO.Directory]::CreateDirectory((Join-Path $f.root 'scripts/release-e2e'))
        Copy-Item -LiteralPath (Join-Path $RepoRoot 'scripts/release-e2e/stages.json') -Destination (Join-Path $f.root 'scripts/release-e2e/stages.json')
        $f.catalog.budgets=(Get-QualityContractCatalog $RepoRoot).budgets
        $f.catalog.contracts[0].paths+='scripts/release-e2e/stages.json'
        [IO.File]::WriteAllText((Join-Path $f.root 'tests/quality-contracts.json'),($f.catalog|ConvertTo-Json -Depth 16))
        & git -C $f.root add --all; & git -C $f.root commit --quiet -m 'calculator cannot waive parent capabilities'
        $badHead=(& git -C $f.root rev-parse HEAD).Trim();$badTree=(& git -C $f.root rev-parse 'HEAD^{tree}').Trim()
        {Invoke-DeliveryCandidatePlanCalculation -CandidateRoot $f.root -BaseCommit $published -CandidateCommit $badHead -CandidateTree $badTree -RequireRelease} | Should -Throw '*CALCULATOR_INVALID*'
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


BeforeAll {
    function New-ScenarioPlanFixture {
        $f=New-IncrementalPlanFixture
        $actual=Get-QualityContractCatalog $RepoRoot
        $f.catalog.developJourneys | Add-Member -NotePropertyName scenarios -NotePropertyValue $actual.developJourneys.scenarios
        $rules=@([pscustomobject]@{path='runtime.ps1';functions=[pscustomobject]@{
            'Change-Update'=@('upgrade.update');'Change-Export'=@('fresh.stale-export');'Change-Mcp'=@('upgrade.update','fresh.install')}})
        $f.catalog.developJourneys | Add-Member -NotePropertyName scenarioInputs -NotePropertyValue $rules
        [IO.File]::WriteAllText((Join-Path $f.root 'runtime.ps1'),"function Change-Update {'v1'}`nfunction Change-Export {'v1'}`nfunction Change-Mcp {'v1'}`n")
        [IO.File]::WriteAllText((Join-Path $f.stand '.agent-1c/project.json'),'{"aiRules":{"tools":["kilocode"]}}')
        [IO.File]::WriteAllText((Join-Path $f.root 'tests/quality-contracts.json'),($f.catalog|ConvertTo-Json -Depth 24))
        & git -C $f.root add --all; & git -C $f.root commit --quiet -m 'scenario baseline'
        $f.base=(& git -C $f.root rev-parse HEAD).Trim()
        $script:Root=$f.root;$script:GateScript=Join-Path $f.root 'scripts/check.ps1'
        $script:E2EProjectRoot=$f.stand;$script:AiRulesSource=$f.rules;$script:AgentTarget='kilocode'
        foreach($relative in @('build/third-party/vanessa-automation/1-r1/archive.zip','build/third-party/client-mcp/client.cfe','tools/itl-ondemand-mcp/build/mcp.exe')) {
            $cache=Join-Path $f.root $relative;[void][IO.Directory]::CreateDirectory((Split-Path $cache));Copy-Item -LiteralPath $f.artifact -Destination $cache
        }
        [IO.File]::AppendAllText((Join-Path $f.root '.git/info/exclude'),"`n/build/`n/tools/itl-ondemand-mcp/build/`n")
        Save-IncrementalJourneyProofs $f
        return $f
    }
    function Set-ScenarioFixtureChange {
        param($Fixture,$Function)
        $path=Join-Path $Fixture.root 'runtime.ps1'
        $text=[IO.File]::ReadAllText($path).Replace("function $Function {'v1'}","function $Function {'v2'}")
        [IO.File]::WriteAllText($path,$text)
        & git -C $Fixture.root add -- runtime.ps1; & git -C $Fixture.root commit --quiet -m $Function
    }
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
