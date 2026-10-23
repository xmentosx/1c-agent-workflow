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

It 'uses the pinned candidate calculator through the native legacy Plan shim without changing authority or saved proof' {
        $f=New-IncrementalPlanFixture; $script:Root=$f.root
        $modules=@('quality-contracts.ps1','develop-e2e-qualification.ps1','develop-journey-inputs.ps1','stand-env-identity.ps1','source-delivery-plan.ps1','source-e2e-artifact-discovery.ps1','git-path-list.ps1')
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
        [IO.File]::WriteAllText($publishedCalculator,([IO.File]::ReadAllText($publishedCalculator).Replace('function Invoke-DeliveryCandidatePlanCalculation {','function Legacy-CandidateCalculationPlaceholder {')),[Text.UTF8Encoding]::new($true))
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
}
