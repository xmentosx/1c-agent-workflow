BeforeAll {
    . (Join-Path $PSScriptRoot 'SourceDeliveryIncremental.TestSupport.ps1')
    . (Join-Path $RepoRoot 'scripts/develop-static-qualification.ps1')
    function New-ForkScopeFixture {
        $f=New-ScenarioPlanFixture
        $script:ForkScopeGo=$f.artifact
        $positive=Join-Path $f.root '.git/positive';$branch=Join-Path $f.root '.git/positive-branch'
        foreach($r in @($positive,$branch)) {[void][IO.Directory]::CreateDirectory((Join-Path $r '.agent-1c'));Copy-Item (Join-Path $f.stand '.agent-1c/project.json') (Join-Path $r '.agent-1c/project.json')}
        Copy-Item (Join-Path $f.stand '.dev.env') (Join-Path $positive '.dev.env')
        [IO.File]::WriteAllText((Join-Path $positive '.agent-1c/release-e2e.json'),(@{developWorktreePath=$branch}|ConvertTo-Json))
        [IO.File]::WriteAllText((Join-Path $f.stand '.agent-1c/release-e2e.json'),(@{developConfigurationRejection=@{positiveProjectRoot=$positive}}|ConvertTo-Json -Depth 5))
        foreach($dir in @('content/rules','tools')) {[void][IO.Directory]::CreateDirectory((Join-Path $f.rules $dir))}
        [IO.File]::WriteAllText((Join-Path $f.rules 'install.ps1'),"'audited fixture text installer'`n")
        [IO.File]::WriteAllText((Join-Path $f.rules 'content/rules/verification-policy.md'),"---`ndescription: policy`nalwaysApply: false`n---`nold body`n")
        [IO.File]::WriteAllText((Join-Path $f.rules 'content/rules/project-memory.md'),"byte-exact memory policy`n")
        [IO.File]::WriteAllText((Join-Path $f.rules 'content/rules/dev-standards-env.md'),("---`ndescription: env`n---`n"+'| `{UI_TESTING}` | `essential` |'+"`n"))
        [IO.File]::WriteAllText((Join-Path $f.rules 'tools/validate-rules.ps1'),"'static old'`n")
        & git -C $f.rules add --all; & git -C $f.rules commit --quiet -m 'fork base'
        $old=(& git -C $f.rules rev-parse HEAD).Trim();$oldTree=(& git -C $f.rules rev-parse 'HEAD^{tree}').Trim()
        & git -C $f.rules tag -a itl-fixture-r1 -m fixture
        $script:ForkInstallerBlob=(& git -C $f.rules rev-parse 'HEAD:install.ps1').Trim()
        $lock=Get-Content (Join-Path $f.root 'templates/dependency-lock.json') -Raw|ConvertFrom-Json
        $lock.dependencies|Add-Member aiRules1c ([pscustomobject]@{repo='fixture';ref='itl-fixture-r1';commit=$old;downstreamRevision=1;compatibilityStatus='passed';compatibilityCheckedAt='old'})
        [IO.File]::WriteAllText((Join-Path $f.root 'templates/dependency-lock.json'),($lock|ConvertTo-Json -Depth 12))
        & git -C $f.root add --all; & git -C $f.root commit --quiet -m 'bound fork baseline'
        $f.base=(& git -C $f.root rev-parse HEAD).Trim()
        Save-IncrementalJourneyProofs $f
        $f|Add-Member oldFork $old;$f|Add-Member oldForkTree $oldTree;$f|Add-Member positive $positive
        $f|Add-Member originalInputs @{}
        foreach($journey in @('upgrade','fresh')) {$f.originalInputs[$journey]=Get-DevelopE2EInputIdentity $f.root $journey $f.catalog $f.stand $f.rules kilocode -ArtifactBinding $f.binding}
        [IO.File]::AppendAllText((Join-Path $f.rules 'content/rules/verification-policy.md'),"new proportionate policy`n")
        [IO.File]::WriteAllText((Join-Path $f.rules 'tools/validate-rules.ps1'),"'static new'`n")
        & git -C $f.rules add --all; & git -C $f.rules commit --quiet -m 'guidance update'
        $new=(& git -C $f.rules rev-parse HEAD).Trim();$tree=(& git -C $f.rules rev-parse 'HEAD^{tree}').Trim()
        & git -C $f.rules tag -a itl-fixture-r2 -m fixture
        $lock.dependencies.aiRules1c.ref='itl-fixture-r2';$lock.dependencies.aiRules1c.commit=$new
        $lock.dependencies.aiRules1c.downstreamRevision=2;$lock.dependencies.aiRules1c.compatibilityStatus='pending';$lock.dependencies.aiRules1c.compatibilityCheckedAt=''
        [IO.File]::WriteAllText((Join-Path $f.root 'templates/dependency-lock.json'),($lock|ConvertTo-Json -Depth 12))
        & git -C $f.root add --all; & git -C $f.root commit --quiet -m 'fork lock update'
        $f|Add-Member newFork $new;$f|Add-Member newForkTree $tree
        return $f
    }
    function Get-ForkFixtureInputs($f,$Journey) {Get-DevelopE2EInputIdentity $f.root $Journey $f.catalog $f.stand $f.rules kilocode -ArtifactBinding $f.binding}
    function Save-ForkFixtureStatic($f) {
        $baseProof=Save-IncrementalStaticProof $f
        $source=Join-Path $f.root '.git/full.json';$q=Get-Content $source -Raw|ConvertFrom-Json
        $forkFull=Join-Path $f.root '.git/fork-full.json'
        [IO.File]::WriteAllText($forkFull,(@{kind='itl-ai-rules-full-qualification';status='passed';reusable=$true;repository=@{commit=$f.newFork;tree=$f.newForkTree;worktreeClean=$true}}|ConvertTo-Json -Depth 6))
        $bridge=Get-AiRulesNativeBridge $f.rules $f.oldFork $f.oldForkTree $f.newFork $f.newForkTree
        $receipt=@{schemaVersion=1;kind='itl-fork-transition-proof';status='passed';commit=$f.newFork;tree=$f.newForkTree;
            policySha256=Get-DevelopE2EInputFileSha256 (Join-Path $RepoRoot 'scripts/ai-rules-native-inputs.ps1') 'scripts/ai-rules-native-inputs.ps1';
            transitions=@(@{bridge=$bridge;clients=@(@{client='kilocode';status='passed';checkedGuidanceCount=1;preservedManagedUserFile=$true})})}
        $path=Join-Path $f.root '.git/fork-transitions.json'
        [IO.File]::WriteAllText($path,($receipt|ConvertTo-Json -Depth 15))
        $hash=(Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant();$name='fork-transitions-'+$hash+'.json'
        Copy-Item -LiteralPath $path -Destination (Join-Path $f.root ('.git/'+$name))
        $q|Add-Member fork ([pscustomobject]@{commit=$f.newFork;tree=$f.newForkTree;qualificationPath=$forkFull;qualificationSha256=(Get-FileHash $forkFull -Algorithm SHA256).Hash.ToLowerInvariant();transitionProof=@{path=$name;sha256=$hash}})
        $q.stages+=@{name='fork-check';status='passed'}
        [IO.File]::WriteAllText($source,($q|ConvertTo-Json -Depth 20))
        Save-DevelopE2ECurrentStaticProof $source ((& git -C $f.root rev-parse HEAD).Trim()) ((& git -C $f.root rev-parse 'HEAD^{tree}').Trim())
    }
}

Describe 'Native fork input scope and authenticated transition' {
    AfterEach { Exit-DeliveryPlanFixtureEnvironment -Snapshot $script:deliveryPlanFixtureEnvironment }

    BeforeEach {
        $script:deliveryPlanFixtureEnvironment=Enter-DeliveryPlanFixtureEnvironment

        Mock Get-DevelopE2EStandStateSha256 {'c'*64}
        $script:DeliverySupervisorCommit='1111111111111111111111111111111111111111'
        $script:DeliverySupervisorChannel='master';$script:DeliverySupervisorBootstrap=$false
        $script:DeliveryRequestedAiRulesSource='';$script:ResumePlan='';$script:ApproveLongPlan=''
        Mock Get-AiRulesAuditedGuidanceInstaller {$script:ForkInstallerBlob}
        $script:ForkScopeGo=(Get-Command go.exe -CommandType Application).Source
        Mock Get-Command {[pscustomobject]@{Source=$script:ForkScopeGo}} -ParameterFilter {$Name -contains 'go.exe'}
    }
    It 'plans all nine unchanged leaves for reuse but executes without current Full and transition proof' {
        $f=New-ForkScopeFixture
        $tree=(& git -C $f.root rev-parse 'HEAD^{tree}').Trim()
        $head=(& git -C $f.root rev-parse HEAD).Trim()
        $plan=New-DeliveryQualityPlanForCandidate -CandidateRoot $f.root -BaseCommit $f.base -CandidateCommit $head -CandidateTree $tree
        @($plan.stages|Where-Object {$_.id -in @('develop.upgrade','develop.fresh') -and $_.execution -eq 'reuse'}).Count|Should -Be 2
        $requests=@(Get-AiRulesTransitionRequests -WorkflowRoot $f.root -RulesRoot $f.rules -ProjectRoot $f.stand -AgentTarget kilocode -ArtifactBinding $f.binding)
        $requests.Count|Should -Be 1
        $requests[0].bridge.fromCommit|Should -BeExactly $f.oldFork
        @($requests[0].clients)|Should -Be @('kilocode')
        @(Get-AiRulesTransitionRequests -WorkflowRoot $f.root -RulesRoot $f.rules).Count|Should -Be 0
        $cache=Join-Path $f.root '.git/itl/develop-e2e-qualifications'
        $before=@(Get-ChildItem $cache -Recurse -File|ForEach-Object {(Get-FileHash $_.FullName -Algorithm SHA256).Hash}|Sort-Object)
        foreach($journey in @('upgrade','fresh')) {
            $inputIdentity=Get-ForkFixtureInputs $f $journey
            $inputIdentity|Should -Not -BeNullOrEmpty
            $planned=@(Get-DevelopScenarioReusePlan $f.root $tree $journey $inputIdentity $f.catalog -AllowPendingStatic)
            @($planned|Where-Object execution -ne reuse).Count|Should -Be 0 -Because ($planned|ConvertTo-Json -Depth 7 -Compress)
            @((Get-DevelopScenarioReusePlan $f.root $tree $journey $inputIdentity $f.catalog)|Where-Object execution -eq reuse).Count|Should -Be 0
        }
        $proof=Save-ForkFixtureStatic $f
        $proof|Should -Not -BeNullOrEmpty
        $count=0
        foreach($journey in @('upgrade','fresh')) {
            $current=Get-ForkFixtureInputs $f $journey
            $current.inventory.external.rulesCommit|Should -BeExactly $f.newFork
            $records=@(Get-DevelopScenarioReusePlan $f.root $tree $journey $current $f.catalog -StaticProof $proof)
            @($records|Where-Object execution -ne reuse).Count|Should -Be 0 -Because ($records|ConvertTo-Json -Depth 7 -Compress)
            $count+=@($records|Where-Object execution -eq reuse).Count
        }
        $count|Should -Be 9
        [void](Save-DevelopStaticQualification $f.root (Split-Path -Parent $proof.path) $tree)
        $restored=Join-Path $f.root '.git/restored-static'
        Restore-DevelopStaticQualification $f.root $restored $tree|Should -BeTrue
        $restoredProof=Save-DevelopE2ECurrentStaticProof (Join-Path $restored 'full.json') $head $tree
        Test-DevelopForkTransitionProof $restoredProof $f.originalInputs.fresh (Get-ForkFixtureInputs $f fresh) $head $tree|Should -BeTrue
        $after=@(Get-ChildItem $cache -Recurse -File|ForEach-Object {(Get-FileHash $_.FullName -Algorithm SHA256).Hash}|Sort-Object)
        ($after -join ',')|Should -BeExactly ($before -join ',')
        $saved=Get-Content -LiteralPath $proof.path -Raw|ConvertFrom-Json
        [IO.File]::AppendAllText((Join-Path (Split-Path -Parent $proof.path) $saved.fork.transitionProof.path),'tamper')
        Test-WorkflowCurrentStaticProof $proof ((& git -C $f.root rev-parse HEAD).Trim()) $tree|Should -BeFalse
        @((Get-DevelopScenarioReusePlan $f.root $tree fresh (Get-ForkFixtureInputs $f fresh) $f.catalog -StaticProof $proof)|Where-Object execution -eq reuse).Count|Should -Be 0
        # An unknown native change rejects all leaves. Historical fork receipts
        # must not create old-to-new probes when none of them can be consumed.
        [IO.File]::AppendAllText((Join-Path $f.root 'runtime.ps1'),"function Unknown-NativeInput {'new'}`n")
        & git -C $f.root add -- runtime.ps1; & git -C $f.root commit --quiet -m 'unknown native change'
        @(Get-AiRulesTransitionRequests -WorkflowRoot $f.root -RulesRoot $f.rules -ProjectRoot $f.stand -AgentTarget kilocode -ArtifactBinding $f.binding).Count|Should -Be 0
    }
    It 'keeps unknown, executable, metadata, layout and dirty fork changes exact' {
        $f=New-ForkScopeFixture
        $baseline=$f.newFork
        foreach($path in @('install.ps1','adapters/future.json','content/rules/added.md','content/rules/verification-policy.md','content/rules/project-memory.md','tools/future.ps1')) {
            & git -C $f.rules reset --hard --quiet $baseline
            $full=Join-Path $f.rules $path;[void][IO.Directory]::CreateDirectory((Split-Path -Parent $full))
            if($path -eq 'content/rules/verification-policy.md') {[IO.File]::WriteAllText($full,"---`ndescription: changed metadata`n---`nbody`n")}else{[IO.File]::AppendAllText($full,"changed native input`n")}
            & git -C $f.rules add --all; & git -C $f.rules commit --quiet -m 'negative owner input'
            Get-AiRulesNativeBridge $f.rules $f.oldFork $f.oldForkTree ((& git -C $f.rules rev-parse HEAD).Trim()) ((& git -C $f.rules rev-parse 'HEAD^{tree}').Trim())|Should -BeNullOrEmpty
        }
        & git -C $f.rules reset --hard --quiet $baseline
        [IO.File]::WriteAllText((Join-Path $f.rules 'content/rules/dev-standards-env.md'),"---`ndescription: env`n---`nunsupported UI capability`n")
        & git -C $f.rules add --all; & git -C $f.rules commit --quiet -m 'changed consumed policy signal'
        Get-AiRulesNativeBridge $f.rules $f.oldFork $f.oldForkTree ((& git -C $f.rules rev-parse HEAD).Trim()) ((& git -C $f.rules rev-parse 'HEAD^{tree}').Trim())|Should -BeNullOrEmpty
        & git -C $f.rules reset --hard --quiet $baseline
        [IO.File]::AppendAllText((Join-Path $f.rules 'content/rules/verification-policy.md'),'dirty')
        Get-AiRulesNativeBridge $f.rules $f.oldFork $f.oldForkTree $f.newFork $f.newForkTree|Should -BeNullOrEmpty
    }
    It 'authenticates nested positive state, native artifacts, lock identity and original fork trees before projection' {
        $f=New-ForkScopeFixture;$current=Get-ForkFixtureInputs $f fresh;$old=$f.originalInputs.fresh
        Test-DevelopScenarioEquivalentInput $f.root $old $current $f.base @('verification') $f.catalog|Should -BeTrue
        foreach($field in @('rulesTree','standStateSha256')) {
            $bad=$current|ConvertTo-Json -Depth 32|ConvertFrom-Json;$bad.inventory.external.$field='e'*64
            $bad.fingerprint=Get-DevelopE2ECanonicalJsonSha256 $bad.inventory
            Test-DevelopScenarioEquivalentInput $f.root $old $bad $f.base @('verification') $f.catalog|Should -BeFalse
        }
        $bad=$current|ConvertTo-Json -Depth 32|ConvertFrom-Json;$bad.inventory.external.artifacts.VANESSA_MCP_CLIENT_CFE_PATH='e'*64
        $bad.fingerprint=Get-DevelopE2ECanonicalJsonSha256 $bad.inventory
        Test-DevelopScenarioEquivalentInput $f.root $old $bad $f.base @('verification') $f.catalog|Should -BeFalse
        $bad=$current|ConvertTo-Json -Depth 32|ConvertFrom-Json;$bad.inventory.external.artifacts.ITL_ONDEMAND_MCP_SOURCE_BUILD_EXE='e'*64
        $bad.fingerprint=Get-DevelopE2ECanonicalJsonSha256 $bad.inventory
        Test-DevelopScenarioEquivalentInput $f.root $old $bad $f.base @('install') $f.catalog|Should -BeFalse
        $lockPath=Join-Path $f.root 'templates/dependency-lock.json';$bytes=[IO.File]::ReadAllBytes($lockPath)
        $lock=[Text.Encoding]::UTF8.GetString($bytes)|ConvertFrom-Json;$lock.dependencies.aiRules1c.commit='e'*40
        [IO.File]::WriteAllText($lockPath,($lock|ConvertTo-Json -Depth 12))
        Test-DevelopScenarioEquivalentInput $f.root $old (Get-ForkFixtureInputs $f fresh) $f.base @('verification') $f.catalog|Should -BeFalse
        [IO.File]::WriteAllBytes($lockPath,$bytes)
        [IO.File]::AppendAllText((Join-Path $f.positive '.dev.env'),"`nUI_TESTING=false`n")
        Test-DevelopScenarioEquivalentInput $f.root $old (Get-ForkFixtureInputs $f fresh) $f.base @('verification') $f.catalog|Should -BeFalse
    }
    It 'rejects rehashed transition records with missing client, failed checks, wrong policy or wrong native inputs' {
        $f=New-ForkScopeFixture;$proof=Save-ForkFixtureStatic $f
        $head=(& git -C $f.root rev-parse HEAD).Trim();$tree=(& git -C $f.root rev-parse 'HEAD^{tree}').Trim()
        $qText=[IO.File]::ReadAllText($proof.path)
        $q=$qText|ConvertFrom-Json;$receiptText=[IO.File]::ReadAllText((Join-Path (Split-Path -Parent $proof.path) $q.fork.transitionProof.path))
        foreach($case in @('client','failed','policy','native','fork-full')) {
            $q=$qText|ConvertFrom-Json;$r=$receiptText|ConvertFrom-Json
            switch($case) {
                client {$r.transitions[0].clients=@()}
                failed {$r.transitions[0].clients[0].status='failed'}
                policy {$r.policySha256='e'*64}
                native {$r.transitions[0].bridge.nativeSha256='e'*64}
                fork-full {$q.fork.qualificationSha256='e'*64}
            }
            $root=Join-Path $f.root ('.git/rehashed-'+$case);[void][IO.Directory]::CreateDirectory($root)
            $tmp=Join-Path $root 'receipt.json';[IO.File]::WriteAllText($tmp,($r|ConvertTo-Json -Depth 20))
            $hash=(Get-FileHash $tmp -Algorithm SHA256).Hash.ToLowerInvariant();$name='fork-transitions-'+$hash+'.json'
            Move-Item -LiteralPath $tmp -Destination (Join-Path $root $name)
            $q.fork.transitionProof.path=$name;$q.fork.transitionProof.sha256=$hash
            $full=Join-Path $root 'full.json';[IO.File]::WriteAllText($full,($q|ConvertTo-Json -Depth 20))
            Copy-Item -LiteralPath $proof.junitPath -Destination (Join-Path $root 'pester.xml')
            $bad=$proof|ConvertTo-Json -Depth 12|ConvertFrom-Json
            $bad.path=$full;$bad.sha256=(Get-FileHash $full -Algorithm SHA256).Hash.ToLowerInvariant();$bad.junitPath=Join-Path $root 'pester.xml'
            Test-DevelopForkTransitionProof $bad $f.originalInputs.fresh (Get-ForkFixtureInputs $f fresh) $head $tree|Should -BeFalse -Because $case
        }
    }
    It 'keeps a newer applicable native failure authoritative across a guidance-only fork transition' {
        $f=New-ForkScopeFixture;$proof=Save-ForkFixtureStatic $f
        $tree=(& git -C $f.root rev-parse 'HEAD^{tree}').Trim()
        $failureRoot=Join-Path $f.root '.git/itl/runs';[void][IO.Directory]::CreateDirectory($failureRoot)
        $run=@{schemaVersion=3;mode='Develop';status='failed';commit=$f.base;tree=(& git -C $f.root rev-parse ($f.base+'^{tree}')).Trim();finishedAt=[datetime]::UtcNow.AddSeconds(1).ToString('o');
            stages=@(@{name='develop-e2e-fresh';status='failed'});journeyInputIdentities=@{fresh=$f.originalInputs.fresh};journeyScenarioExecution=@{fresh=@('stale-export')}}
        [IO.File]::WriteAllText((Join-Path $failureRoot 'fixture-develop-failed.json'),($run|ConvertTo-Json -Depth 24))
        $records=@(Get-DevelopScenarioReusePlan $f.root $tree fresh (Get-ForkFixtureInputs $f fresh) $f.catalog -StaticProof $proof)
        @($records|Where-Object {$_.id -eq 'stale-export' -and $_.execution -eq 'execute'}).Count|Should -Be 1
        @($records|Where-Object {$_.id -eq 'close' -and $_.execution -eq 'reuse'}).Count|Should -Be 1
    }
}
