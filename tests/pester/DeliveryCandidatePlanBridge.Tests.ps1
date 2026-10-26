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
        $modules=@('quality-contracts.ps1','develop-e2e-qualification.ps1','ai-rules-native-inputs.ps1','develop-journey-inputs.ps1','develop-e2e-scenarios.ps1','stand-env-identity.ps1','source-delivery-plan.ps1','delivery-native-plan.ps1','source-e2e-artifact-discovery.ps1','git-path-list.ps1')
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
        $text=[IO.File]::ReadAllText($calculator)
        $nativeCalculator=Join-Path $f.root 'scripts/delivery-native-plan.ps1'
        $nativeText=[IO.File]::ReadAllText($nativeCalculator).Replace('complete static inventory with per-file proof reuse','candidate policy selected')
        [IO.File]::WriteAllText($nativeCalculator,$nativeText,[Text.UTF8Encoding]::new($true))
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
        $t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($nativeText,[ref]$t,[ref]$e)
        $node=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'New-DeliveryNativeQualityPlanForCandidate'},$true)
        $withoutRelease=$nativeText.Insert($node.Body.EndBlock.Statements[0].Extent.StartOffset,'$RequireRelease=$false; $ReleaseCapability=@(); ')
        [IO.File]::WriteAllText($calculator,$text,[Text.UTF8Encoding]::new($true))
        [IO.File]::WriteAllText($nativeCalculator,$withoutRelease,[Text.UTF8Encoding]::new($true))
        [void][IO.Directory]::CreateDirectory((Join-Path $f.root 'scripts/release-e2e'))
        Copy-Item -LiteralPath (Join-Path $RepoRoot 'scripts/release-e2e/stages.json') -Destination (Join-Path $f.root 'scripts/release-e2e/stages.json')
        $f.catalog.budgets=(Get-QualityContractCatalog $RepoRoot).budgets
        $f.catalog.contracts[0].paths+='scripts/release-e2e/stages.json'
        [IO.File]::WriteAllText((Join-Path $f.root 'tests/quality-contracts.json'),($f.catalog|ConvertTo-Json -Depth 16))
        & git -C $f.root add --all; & git -C $f.root commit --quiet -m 'calculator cannot waive parent capabilities'
        $badHead=(& git -C $f.root rev-parse HEAD).Trim();$badTree=(& git -C $f.root rev-parse 'HEAD^{tree}').Trim()
        {Invoke-DeliveryCandidatePlanCalculation -CandidateRoot $f.root -BaseCommit $published -CandidateCommit $badHead -CandidateTree $badTree -RequireRelease} | Should -Throw '*CALCULATOR_INVALID*'
    }
}
