BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    . (Join-Path $repoRoot 'scripts/source-e2e-manifest-repair.ps1')
    . (Join-Path $repoRoot 'scripts/develop-configuration-rejection.ps1')
    . (Join-Path $repoRoot 'scripts/stand-env-identity.ps1')
    . (Join-Path $repoRoot 'scripts/develop-e2e-qualification.ps1')
    foreach ($group in @(
        @{path='scripts/invoke-develop-e2e.ps1';names=@('Read-CompactSummary','Invoke-DevelopUpgradeRefresh','Assert-FreshVerificationResult','Add-FreshVerificationCatalog')},
        @{path='scripts/check.ps1';names=@('Get-DevelopE2EIdentitySha256')},
        @{path='.agents/skills/1c-workflow/scripts/lib/agent-1c.lifecycle.ps1';names=@('Write-ConfigLoadRejectionEvidence')},
        @{path='.agents/skills/1c-workflow/scripts/lib/agent-1c.core.ps1';names=@('Normalize-Agent1cFullPathText','Resolve-Agent1cFullPath','Set-RunResultArtifacts','Read-DesignerBatchStrictUtf8Text')},
        @{path='.agents/skills/1c-workflow/scripts/lib/agent-1c.sessions.ps1';names=@('Test-OneCNativeOperationJournalReleased')}
    )) {
        $tokens=$null; $errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot $group.path),[ref]$tokens,[ref]$errors)
        if ($errors.Count) { throw ($errors | Out-String) }
        foreach ($name in $group.names) {
            $definition=$ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$true) | Where-Object Name -CEQ $name
            . ([scriptblock]::Create($definition.Extent.Text))
        }
    }
    function New-TimestampedFilePath([string]$Directory,[string]$Prefix,[string]$Extension) {
        Join-Path $Directory ($Prefix + '-' + [guid]::NewGuid().ToString('N') + $Extension)
    }
    function Assert-TrackedClean([string]$Root,[string]$Label) {
        if ($script:fixtureDirty) { throw 'Tracked fixture changed' }
    }
    function Invoke-InstalledAction {
        param([string]$Name,[string]$Root,[string]$Action,[string[]]$AdditionalArguments=@(),[int]$TimeoutSeconds,[switch]$AllowFailure)
        $script:refreshArguments=@($AdditionalArguments)
        return $script:refreshResult
    }
    function Write-RejectionJson([string]$Path,[object]$Value) {
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path)) | Out-Null
        [IO.File]::WriteAllText($Path,($Value | ConvertTo-Json -Depth 12 -Compress),[Text.UTF8Encoding]::new($false))
    }
    function New-RejectionFixture {
        $root=Join-Path $TestDrive ('Git ' + (-join [char[]](0x041F,0x0440,0x043E,0x0435,0x043A,0x0442)) + ' ' + [guid]::NewGuid().ToString('N'))
        $source=Join-Path $root 'src/cf/CommonModules/Reproducer/Ext/Module.bsl'
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($source)) | Out-Null
        [IO.File]::WriteAllText($source,'Registers.MissingProperty.CreateRecordSet();',[Text.UTF8Encoding]::new($true))
        $logs=Join-Path $root 'logs/1c'
        [IO.Directory]::CreateDirectory($logs) | Out-Null
        $result=Join-Path $logs 'check.result'; $log=Join-Path $logs 'check.log'; $restore=Join-Path $logs 'restore.log'
        [IO.File]::WriteAllText($result,'101'); [IO.File]::WriteAllText($log,'Reproducer: incorrect reference MissingProperty')
        [IO.File]::WriteAllText($restore,'Restore completed')
        $diagnostic='Reproducer: incorrect reference MissingProperty'
        $message="GATE6_CHECK_FAILED: step=configuration; process exit=101; /DumpResult=101; result=$result; log=$log; diagnostics=$diagnostic. Do not apply the database configuration; correct or adjudicate the source findings and repeat the original operation."
        $failure=[Management.Automation.ErrorRecord]::new([Exception]::new($message),'fixture',[Management.Automation.ErrorCategory]::InvalidData,$null)
        $failure.Exception.Data['ItlConfigLoadSnapshotRestored']=[pscustomobject]@{
            projectRoot=$root;infoBaseKind='file';infoBasePath=(Join-Path $root 'base');snapshotSha256=('a'*64);
            cursorRestored=$true;applyStarted=$false;sourceFingerprint=('v2|git-tree-sha256|'+'b'*64);restorationLogPath=$restore
            nativeOperationsReleased=$true
        }
        $console=Join-Path $root 'console.log'
        $hostLines=@(Write-ConfigLoadRejectionEvidence -Failure $failure 6>&1 | ForEach-Object { [string]$_ })
        [IO.File]::WriteAllText($console,($hostLines -join [Environment]::NewLine),[Text.UTF8Encoding]::new($false))
        $summary=[pscustomobject]@{action='refresh-dev-branch';status='failed';error=$message;logPath=$console;resultPath=$script:RunResultPath}
        $stdout=Join-Path $root 'stdout.log'; Write-RejectionJson $stdout $summary
        Write-RejectionJson (Join-Path $root '.agent-1c/dev-branches/fixture.json') @{
            devBranchInfoBasePath=(Join-Path $root 'base');infoBaseKind='file';pendingMergeOperation='refresh-dev-branch';pendingMergeStage='merged'
        }
        $receiptPath=(Get-ChildItem -LiteralPath $logs -Filter '1c-gate6-rejection-*.json').FullName
        return @{Root=$root;Expected=[pscustomobject]@{sourcePath='src/cf/CommonModules/Reproducer/Ext/Module.bsl';
            sourceSha256=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant();diagnostic=$diagnostic};
            Result=[pscustomobject]@{exitCode=1;stdout=$stdout;stderr=(Join-Path $root 'stderr.log')};Receipt=$receiptPath;Summary=$summary;Failure=$failure;Log=$log;Source=$source}
    }
    function Assert-FixtureRejection([hashtable]$Fixture) {
        Assert-DevelopConfigurationRejection -ProcessResult $Fixture.Result -Expected $Fixture.Expected -Root $Fixture.Root -BranchName fixture
    }
    function Add-BoundedRejectionStatus([hashtable]$Fixture) {
        $receipt=Get-Content -LiteralPath $Fixture.Receipt -Raw -Encoding UTF8 | ConvertFrom-Json
        $receipt.failure += ' ' + ('Original native finding remains rejected. ' * 40)
        Write-RejectionJson $Fixture.Receipt $receipt
        $Fixture.Summary.error=$receipt.failure.Substring(0,1397)+'...'
        Write-RejectionJson $Fixture.Result.stdout $Fixture.Summary
        $terminal=[pscustomobject]@{projectRoot=$Fixture.Root;action=$Fixture.Summary.action;status='failed';exitCode=1;
            logPath=$Fixture.Summary.logPath;resultPath=$Fixture.Receipt;error=$Fixture.Summary.error;errorMessage=$receipt.failure}
        $statusPath=Join-Path (Split-Path -Parent $Fixture.Summary.logPath) 'status.json'
        Write-RejectionJson $statusPath $terminal
        return @{Path=$statusPath;Status=$terminal}
    }
}

Describe 'Configuration finding is a negative workflow acceptance, never a positive verification' {
    BeforeEach {
        $script:fixtureDirty=$false
        $script:OneCNativeOperationJournal=[pscustomobject]@{entries=@();restorations=@([pscustomobject]@{payload=@{status='restored'}})}
    }
    It 'accepts the exact original failure only with refusal, rollback, native release and continuation evidence' {
        $fixture=New-RejectionFixture
        $before=(Get-FileHash -LiteralPath $fixture.Source).Hash
        $accepted=Assert-FixtureRejection $fixture
        $accepted.status | Should -BeExactly 'passed'
        $accepted.expectedOutcome | Should -BeExactly 'configuration-rejected'
        $fixture.Summary.status | Should -BeExactly 'failed'
        (Get-FileHash -LiteralPath $fixture.Source).Hash | Should -BeExactly $before
    }
    It 'keeps the ordinary public refresh argument list empty and retains one Full mode through negative retry' {
        $fixture=New-RejectionFixture
        $script:refreshResult=$fixture.Result
        $fixture.Result.exitCode=0
        Write-RejectionJson $fixture.Result.stdout @{action='refresh-dev-branch';status='succeeded'}
        [void](Invoke-DevelopUpgradeRefresh -Name positive -Root $fixture.Root -BranchName fixture)
        $script:refreshArguments.Count | Should -Be 0
        $fixture.Result.exitCode=1
        Write-RejectionJson $fixture.Result.stdout $fixture.Summary
        [void](Invoke-DevelopUpgradeRefresh -Name negative -Root $fixture.Root -BranchName fixture -ExpectedConfigurationRejection $fixture.Expected)
        $script:refreshArguments | Should -Be @('-ConfigLoadMode','Full')
        [void](Invoke-DevelopUpgradeRefresh -Name retry -Root $fixture.Root -BranchName fixture -ExpectedConfigurationRejection $fixture.Expected -AdditionalArguments $script:refreshArguments -AfterSemanticRepair)
        $script:refreshArguments | Should -Be @('-ConfigLoadMode','Full')
    }
    It 'accepts the current structured result artifact when reexec did not capture child host output' {
        $fixture=New-RejectionFixture
        [IO.File]::WriteAllText($fixture.Summary.logPath,'Parent console: continuing through the current helper.')
        $fixture.Summary.resultPath | Should -BeExactly $fixture.Receipt
        (Assert-FixtureRejection $fixture).status | Should -BeExactly 'passed'
    }
    It 'binds a 1400-character compact error to the full current terminal failure and native receipt' {
        $fixture=New-RejectionFixture
        $fixture.Summary.action='check-dev-branch'
        $bound=Add-BoundedRejectionStatus $fixture
        $fixture.Summary.error.Length | Should -Be 1400
        $bound.Status.errorMessage.Length | Should -BeGreaterThan 1400
        $proof=Assert-DevelopConfigurationRejection -ProcessResult $fixture.Result -Expected $fixture.Expected -Root $fixture.Root -BranchName fixture -ExpectedAction 'check-dev-branch'
        $proof.status | Should -BeExactly 'passed'
        $proof.proof.failure | Should -BeExactly $bound.Status.errorMessage
        $fixture.Summary.status | Should -BeExactly 'failed'
    }
    It 'requires a merged pending refresh only on the refresh path, not on a fresh branch production check' {
        $fixture=New-RejectionFixture
        $fixture.Summary.action='check-dev-branch'
        Write-RejectionJson $fixture.Result.stdout $fixture.Summary
        # A freshly built gate stand branch has never refreshed or merged.
        Write-RejectionJson (Join-Path $fixture.Root '.agent-1c/dev-branches/fixture.json') @{ devBranchInfoBasePath=(Join-Path $fixture.Root 'base');infoBaseKind='file' }
        (Assert-DevelopConfigurationRejection -ProcessResult $fixture.Result -Expected $fixture.Expected -Root $fixture.Root -BranchName fixture -ExpectedAction 'check-dev-branch').status | Should -BeExactly 'passed'
        $refresh=New-RejectionFixture
        Write-RejectionJson (Join-Path $refresh.Root '.agent-1c/dev-branches/fixture.json') @{ devBranchInfoBasePath=(Join-Path $refresh.Root 'base');infoBaseKind='file' }
        {Assert-FixtureRejection $refresh} | Should -Throw '*DEVELOP_NEGATIVE_TARGET_OR_CONTINUATION_CHANGED*'
    }
    It 'refuses bounded errors without the current terminal status' {
        $fixture=New-RejectionFixture
        $bound=Add-BoundedRejectionStatus $fixture
        Remove-Item -LiteralPath $bound.Path
        {Assert-FixtureRejection $fixture} | Should -Throw '*ROLLBACK_UNPROVEN*'
    }
    It 'refuses bounded errors with a different terminal <field>' -ForEach @(
        @{field='projectRoot';value='C:\another project'},@{field='action';value='another-action'},
        @{field='status';value='succeeded'},@{field='exitCode';value=0},
        @{field='logPath';value='C:\another console.log'},@{field='resultPath';value='C:\another receipt.json'},
        @{field='error';value='another display failure'},@{field='errorMessage';value='another full failure'}
    ) {
        $fixture=New-RejectionFixture
        $bound=Add-BoundedRejectionStatus $fixture
        $bound.Status.$field=$value;Write-RejectionJson $bound.Path $bound.Status
        {Assert-FixtureRejection $fixture} | Should -Throw '*ROLLBACK_UNPROVEN*'
    }
    It 'retains rollback and native hash requirements with a bounded error' {
        $fixture=New-RejectionFixture
        [void](Add-BoundedRejectionStatus $fixture)
        $receipt=Get-Content -LiteralPath $fixture.Receipt -Raw -Encoding UTF8 | ConvertFrom-Json
        $receipt.cursorRestored=$false;Write-RejectionJson $fixture.Receipt $receipt
        {Assert-FixtureRejection $fixture} | Should -Throw '*ROLLBACK_UNPROVEN*'
        $receipt.cursorRestored=$true;Write-RejectionJson $fixture.Receipt $receipt
        [IO.File]::AppendAllText($fixture.Log,' changed')
        {Assert-FixtureRejection $fixture} | Should -Throw '*ARTIFACT_CHANGED*'
    }
    It 'refuses a console marker without a current structured result artifact' {
        $fixture=New-RejectionFixture
        $fixture.Summary.resultPath=''; Write-RejectionJson $fixture.Result.stdout $fixture.Summary
        { Assert-FixtureRejection $fixture } | Should -Throw '*ROLLBACK_UNPROVEN*'
    }
    It 'rejects a successful refresh instead of silently losing the negative reproducer' {
        $fixture=New-RejectionFixture; $fixture.Result.exitCode=0
        { Assert-FixtureRejection $fixture } | Should -Throw '*UNEXPECTED_RESULT*'
    }
    It 'requires explicit production refusal before ordinary refresh on a purpose-aware helper' {
        $fixture=New-RejectionFixture
        $helper=Join-Path $fixture.Root '.agents/skills/1c-workflow/scripts/agent-1c.ps1'
        [void][IO.Directory]::CreateDirectory((Split-Path $helper))
        [IO.File]::WriteAllText($helper,'param([string]$ResultPurpose)')
        $fixture.Summary.action='check-dev-branch';Write-RejectionJson $fixture.Result.stdout $fixture.Summary
        $ok=Join-Path $fixture.Root 'refresh-ok.json';Write-RejectionJson $ok @{action='refresh-dev-branch';status='succeeded'}
        $script:negativeResult=$fixture.Result;$script:ordinaryResult=[pscustomobject]@{exitCode=0;stdout=$ok}
        $script:actions=[Collections.Generic.List[string]]::new()
        Mock Invoke-InstalledAction {
            $script:actions.Add($Action)
            if($Action -ceq 'check-dev-branch'){
                $AdditionalArguments | Should -Be @('-ResultPurpose','production','-ConfigLoadMode','Full')
                $AllowFailure | Should -BeTrue
                return $script:negativeResult
            }
            $AdditionalArguments | Should -Be @('-ConfigLoadMode','Full')
            return $script:ordinaryResult
        }
        $proof=Invoke-DevelopConfigurationRejectionScenario -Root $fixture.Root -BranchName fixture -Expected $fixture.Expected
        @($script:actions) | Should -Be @('check-dev-branch','refresh-dev-branch')
        $proof.productionAction | Should -BeExactly 'check-dev-branch'
        $proof.developmentRefresh | Should -BeExactly 'succeeded'
    }
    It 'never refreshes after unexpected production success' {
        $fixture=New-RejectionFixture
        $helper=Join-Path $fixture.Root '.agents/skills/1c-workflow/scripts/agent-1c.ps1'
        [void][IO.Directory]::CreateDirectory((Split-Path $helper));[IO.File]::WriteAllText($helper,'param([string]$ResultPurpose)')
        $fixture.Result.exitCode=0;$script:negativeResult=$fixture.Result
        Mock Invoke-InstalledAction {return $script:negativeResult}
        {Invoke-DevelopConfigurationRejectionScenario -Root $fixture.Root -BranchName fixture -Expected $fixture.Expected} | Should -Throw '*UNEXPECTED_RESULT*'
        Should -Invoke Invoke-InstalledAction -Times 0 -ParameterFilter {$Action -eq 'refresh-dev-branch'}
    }
    It 'preserves the legacy refresh refusal on a helper without the purpose parameter' {
        $fixture=New-RejectionFixture;$script:refreshResult=$fixture.Result
        (Invoke-DevelopConfigurationRejectionScenario -Root $fixture.Root -BranchName fixture -Expected $fixture.Expected).status | Should -BeExactly 'passed'
        $script:refreshArguments | Should -Be @('-ConfigLoadMode','Full')
    }
    It 'checks the exact finding in the hashed native log with all declared diagnostic artifacts' {
        $fixture=New-RejectionFixture
        $receipt=Get-Content $fixture.Receipt -Raw -Encoding UTF8 | ConvertFrom-Json
        $diagnostic='Reproducer '+(-join [char[]](0x041F,0x0440,0x043E,0x0435,0x043A,0x0442))+': incorrect reference MissingProperty'
        [IO.File]::WriteAllText($fixture.Log,$diagnostic,[Text.UTF8Encoding]::new($false))
        $fixture.Expected.diagnostic=$diagnostic
        $receipt.artifacts[1].sha256=(Get-FileHash $fixture.Log -Algorithm SHA256).Hash.ToLowerInvariant()
        foreach($field in @('diagnostics','legacyContextAssessment')){
            $path=Join-Path $fixture.Root ($field+'.json');Write-RejectionJson $path @{kind=$field}
            $sha=(Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant()
            $value=if($field -ceq 'diagnostics'){@{path=$path;sha256=$sha}}else{@{evidencePath=$path;evidenceSha256=$sha}}
            $receipt | Add-Member -NotePropertyName $field -NotePropertyValue $value -Force
            $receipt.artifacts+=@{path=$path;sha256=$sha}
        }
        Write-RejectionJson $fixture.Receipt $receipt
        (Assert-FixtureRejection $fixture).status | Should -BeExactly 'passed'
        $receipt.artifacts+=@{path=$fixture.Log;sha256=(Get-FileHash $fixture.Log -Algorithm SHA256).Hash.ToLowerInvariant()}
        Write-RejectionJson $fixture.Receipt $receipt
        {Assert-FixtureRejection $fixture} | Should -Throw '*NATIVE_PROOF_MISSING*'
    }
    It 'rejects failed development continuation after a proven production refusal' {
        $fixture=New-RejectionFixture
        $helper=Join-Path $fixture.Root '.agents/skills/1c-workflow/scripts/agent-1c.ps1'
        [void][IO.Directory]::CreateDirectory((Split-Path $helper));[IO.File]::WriteAllText($helper,'param([string]$ResultPurpose)')
        $fixture.Summary.action='check-dev-branch';Write-RejectionJson $fixture.Result.stdout $fixture.Summary
        $script:negativeResult=$fixture.Result
        Mock Invoke-InstalledAction {return $script:negativeResult}
        {Invoke-DevelopConfigurationRejectionScenario -Root $fixture.Root -BranchName fixture -Expected $fixture.Expected} | Should -Throw '*upgrade-refresh-branch failed*'
    }
    It 'rejects another finding or changed source bytes' {
        $fixture=New-RejectionFixture; $fixture.Expected.diagnostic='Another incorrect reference MissingProperty'
        { Assert-FixtureRejection $fixture } | Should -Throw '*DIAGNOSTIC_CHANGED*'
        $fixture=New-RejectionFixture; [IO.File]::AppendAllText($fixture.Source,' changed')
        { Assert-FixtureRejection $fixture } | Should -Throw '*SOURCE_CHANGED*'
    }
    It 'rejects missing rollback, attempted apply or unreleased native work' -ForEach @(
        @{field='snapshotRestored';value=$false},@{field='cursorRestored';value=$false},
        @{field='applyStarted';value=$true},@{field='nativeOperationsReleased';value=$false}
    ) {
        $fixture=New-RejectionFixture
        $receipt=Get-Content -LiteralPath $fixture.Receipt -Raw -Encoding UTF8 | ConvertFrom-Json
        $receipt.$field=$value; Write-RejectionJson $fixture.Receipt $receipt
        { Assert-FixtureRejection $fixture } | Should -Throw '*ROLLBACK_UNPROVEN*'
    }
    It 'rejects changed native evidence and dirty tracked state' {
        $fixture=New-RejectionFixture; [IO.File]::AppendAllText($fixture.Log,' changed')
        { Assert-FixtureRejection $fixture } | Should -Throw '*ARTIFACT_CHANGED*'
        $fixture=New-RejectionFixture; $script:fixtureDirty=$true
        { Assert-FixtureRejection $fixture } | Should -Throw '*Tracked fixture changed*'
    }
    It 'does not emit a rejection receipt for an unconfirmed cursor restoration or an attempted apply' {
        foreach ($field in @('cursorRestored','applyStarted')) {
            $fixture=New-RejectionFixture
            $fixture.Failure.Exception.Data['ItlConfigLoadSnapshotRestored'].$field=($field -eq 'applyStarted')
            $script:RunResultPath=''
            $output=Write-ConfigLoadRejectionEvidence -Failure $fixture.Failure 6>&1 | Out-String
            $output | Should -Not -Match 'GATE6_REJECTION_EVIDENCE'
            $script:RunResultPath | Should -BeNullOrEmpty
        }
    }
    It 'records unconfirmed native release and refuses to qualify it' {
        $script:OneCNativeOperationJournal.entries=@([pscustomobject]@{startAttempted=$true;quiescenceConfirmed=$false})
        $fixture=New-RejectionFixture
        { Assert-FixtureRejection $fixture } | Should -Throw '*ROLLBACK_UNPROVEN*'
    }
    It 'accepts confirmed owned native release when ordinary dispatch has no optional journal' {
        $script:OneCNativeOperationJournal=$null
        $fixture=New-RejectionFixture
        (Assert-FixtureRejection $fixture).status | Should -BeExactly 'passed'
        $fixture.Failure.Exception.Data['ItlConfigLoadSnapshotRestored'].nativeOperationsReleased=$false
        $lines=@(Write-ConfigLoadRejectionEvidence -Failure $fixture.Failure 6>&1 | ForEach-Object { [string]$_ })
        $path=($lines | Where-Object { $_ -like 'GATE6_REJECTION_EVIDENCE: *' }) -replace '^GATE6_REJECTION_EVIDENCE: ',''
        (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).nativeOperationsReleased | Should -BeFalse
    }
    It 'retains the failed refresh continuation instead of declaring the merge complete' {
        $fixture=New-RejectionFixture
        $path=Join-Path $fixture.Root '.agent-1c/dev-branches/fixture.json'
        $state=Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        $state.pendingMergeStage=''; Write-RejectionJson $path $state
        { Assert-FixtureRejection $fixture } | Should -Throw '*TARGET_OR_CONTINUATION_CHANGED*'
    }
    It 'requires an independent positive stand and forbids chained negative stands' {
        $root=Join-Path $TestDrive 'positive'
        Write-RejectionJson (Join-Path $root '.agent-1c/release-e2e.json') @{developDevBranchName='golden';developWorktreePath=(Join-Path $root 'branch')}
        $config=[pscustomobject]@{developConfigurationRejection=[pscustomobject]@{positiveProjectRoot=$root}}
        Get-DevelopPositiveStandRoot -ProjectRoot (Join-Path $TestDrive 'negative') -Config $config | Should -BeExactly $root
        { Get-DevelopPositiveStandRoot -ProjectRoot $root -Config $config } | Should -Throw '*POSITIVE_STAND_REQUIRED*'
        Write-RejectionJson (Join-Path $root '.agent-1c/release-e2e.json') $config
        { Get-DevelopPositiveStandRoot -ProjectRoot (Join-Path $TestDrive 'negative') -Config $config } | Should -Throw '*RECURSION_FORBIDDEN*'
    }
    It 'binds both positive repositories to the stand content identity and dirty-state guard' {
        $root=Join-Path $TestDrive 'identity'
        $repositories=@('negative','negative-branch','positive','positive-branch')
        foreach ($name in $repositories) {
            $path=Join-Path $root $name
            [IO.Directory]::CreateDirectory((Join-Path $path 'src/cf')) | Out-Null
            & git -C $path init --quiet -b master
            & git -C $path config user.name fixture
            & git -C $path config user.email fixture@example.invalid
            [IO.File]::WriteAllText((Join-Path $path 'src/cf/Configuration.xml'),'baseline')
            & git -C $path add --all
            & git -C $path commit --quiet -m baseline
            if ($LASTEXITCODE) { throw 'Identity fixture Git setup failed' }
        }
        $negative=Join-Path $root 'negative'; $positive=Join-Path $root 'positive'; $branch=Join-Path $root 'positive-branch'
        Write-RejectionJson (Join-Path $positive '.agent-1c/release-e2e.json') @{developWorktreePath=$branch}
        Write-RejectionJson (Join-Path $negative '.agent-1c/release-e2e.json') @{developWorktreePath=(Join-Path $root 'negative-branch');developConfigurationRejection=@{positiveProjectRoot=$positive}}
        @(Get-DevelopE2EStandRepositories -ProjectRoot $negative | Select-Object -ExpandProperty role) | Should -Be @('master','develop','positiveMaster','positiveDevelop')
        $context=@{artifacts=@{vanessaAutomation=@{sha256=('a'*64)}};managedPackage=@{sha256=('b'*64)}}
        $fork=@{commit=('c'*40);tree=('d'*40);tag='fixture'}
        $identity=Get-DevelopE2EIdentitySha256 -ReleaseContext $context -ForkIdentity $fork -ProjectRoot $negative
        [IO.File]::WriteAllText((Join-Path $positive '.dev.env'),'PLATFORM_PATH=C:\changed-platform\1cv8.exe')
        (Get-DevelopE2EIdentitySha256 -ReleaseContext $context -ForkIdentity $fork -ProjectRoot $negative) | Should -Not -BeExactly $identity
        $before=Get-DevelopE2EStandStateSha256 -ProjectRoot $negative
        [IO.File]::AppendAllText((Join-Path $branch 'src/cf/Configuration.xml'),' change')
        { Get-DevelopE2EStandContentState -ProjectRoot $negative -RequireClean } | Should -Throw '*tracked changes*'
        & git -C $branch add --all
        & git -C $branch commit --quiet -m change
        (Get-DevelopE2EStandStateSha256 -ProjectRoot $negative) | Should -Not -BeExactly $before
    }
}

Describe 'Negative configuration fixture uses the current change owner before production check' {
    BeforeEach {
        $script:planFixture=New-RejectionFixture
        $root=$script:planFixture.Root
        $helper=Join-Path $root 'change-helper.ps1'
        [IO.File]::WriteAllText($helper,'param([ValidateSet("begin-verification-change")][string]$Action)')
        $script:changeHelper=Get-Command $helper
        $script:planningView=@{model='change';status='planning';baseTree=('a'*40);tree=('b'*40);taskId='';criteria=@();requirementPaths=@();changedPaths=@(
            '.agent-1c/dependency-lock.json','.agents/skills/1c-workflow/scripts/lib/agent-1c.verification-change.ps1',
            'src/cf/ConfigDumpInfo.xml','tests/features/ITLDevelopJourney.feature','tests/verification-suites.branch.json')}
        $script:planningConsole=Join-Path $root 'planning-console.log'
        $script:inspectionOutput=Join-Path $root 'planning-summary.json'
        Write-RejectionJson $script:inspectionOutput @{action='begin-verification-change';status='succeeded';logPath=$script:planningConsole}
        $script:submittedPlan=$null
        $script:planningCalls=0
        Mock Invoke-InstalledAction {
            $Action|Should -BeExactly 'begin-verification-change'
            $script:planningCalls++
            if(-not $AdditionalArguments){
                Write-RejectionJson $script:planningConsole $script:planningView
                return [pscustomobject]@{exitCode=0;stdout=$script:inspectionOutput}
            }
            $AdditionalArguments[0]|Should -BeExactly '-VerificationEvidencePath'
            $script:submittedPlan=Get-Content -LiteralPath $AdditionalArguments[1] -Raw -Encoding UTF8|ConvertFrom-Json
            return [pscustomobject]@{exitCode=0;stdout=$script:inspectionOutput}
        }
    }
    It 'plans the complete current delta through the installed owner without accepting or loading it' {
        Initialize-DevelopConfigurationRejectionPlan -Root $script:planFixture.Root -Expected $script:planFixture.Expected -HelperCommand $script:changeHelper
        $script:planningCalls|Should -Be 2
        @($script:submittedPlan.paths.path)|Should -Be $script:planningView.changedPaths
        $script:submittedPlan.checks[0].inputPaths|Should -Contain $script:planFixture.Expected.sourcePath
        $script:submittedPlan.criteria[0].expectedResult|Should -Match ([regex]::Escape($script:planFixture.Expected.diagnostic))
        $script:submittedPlan.retainedDispositions.Count|Should -Be 0
        Should -Invoke Invoke-InstalledAction -Times 0 -ParameterFilter {$Action -ne 'begin-verification-change'}
    }
    It 'preserves an inherited <field> before writing or submitting another plan' -ForEach @(
        @{field='taskId';value='unfinished-task'},@{field='criteria';value=@(@{id='AC-old'})},@{field='requirementPaths';value=@('openspec/old.md')}
    ) {
        $script:planningView[$field]=$value
        {Initialize-DevelopConfigurationRejectionPlan -Root $script:planFixture.Root -Expected $script:planFixture.Expected -HelperCommand $script:changeHelper}|Should -Throw '*CHANGE_SCOPE_UNSUPPORTED*'
        $script:planningCalls|Should -Be 1
        $script:submittedPlan|Should -BeNullOrEmpty
    }
    It 'refuses an unreviewed delta instead of giving it blanket coverage' {
        $script:planningView.changedPaths+=@('src/cfe/Foreign/Module.bsl')
        {Initialize-DevelopConfigurationRejectionPlan -Root $script:planFixture.Root -Expected $script:planFixture.Expected -HelperCommand $script:changeHelper}|Should -Throw '*CHANGE_SCOPE_UNSUPPORTED*'
        $script:submittedPlan|Should -BeNullOrEmpty
    }
    It 'refuses changed reproducer bytes before submitting the plan' {
        [IO.File]::AppendAllText($script:planFixture.Source,' changed')
        {Initialize-DevelopConfigurationRejectionPlan -Root $script:planFixture.Root -Expected $script:planFixture.Expected -HelperCommand $script:changeHelper}|Should -Throw '*SOURCE_CHANGED*'
        $script:submittedPlan|Should -BeNullOrEmpty
    }
    It 'preserves an explicitly cumulative project without creating a change task' {
        Write-RejectionJson $script:inspectionOutput @{action='begin-verification-change';status='failed';error='VERIFICATION_CHANGE_MODEL: select ITL_VERIFICATION_MODEL=change before preparing a change plan.'}
        Mock Invoke-InstalledAction {return [pscustomobject]@{exitCode=1;stdout=$script:inspectionOutput}}
        Initialize-DevelopConfigurationRejectionPlan -Root $script:planFixture.Root -Expected $script:planFixture.Expected -HelperCommand $script:changeHelper
        $script:submittedPlan|Should -BeNullOrEmpty
        Should -Invoke Invoke-InstalledAction -Times 1
    }
    It 'retains an unrelated inspection failure rather than continuing production' {
        Write-RejectionJson $script:inspectionOutput @{action='begin-verification-change';status='failed';error='VERIFICATION_CHANGE_BASE_UNVERIFIED: prior suite failed'}
        Mock Invoke-InstalledAction {return [pscustomobject]@{exitCode=1;stdout=$script:inspectionOutput}}
        {Initialize-DevelopConfigurationRejectionPlan -Root $script:planFixture.Root -Expected $script:planFixture.Expected -HelperCommand $script:changeHelper}|Should -Throw '*CHANGE_INSPECTION_FAILED*BASE_UNVERIFIED*'
        $script:submittedPlan|Should -BeNullOrEmpty
    }
    It 'plans, runs the original check and accepts only after its fresh result assertion' {
        $root=$script:planFixture.Root
        $helper=Join-Path $root '.agents/skills/1c-workflow/scripts/agent-1c.ps1'
        [void][IO.Directory]::CreateDirectory((Split-Path $helper))
        [IO.File]::WriteAllText($helper,'param([ValidateSet("begin-verification-change")][string]$Action)')
        $script:planActions=[Collections.Generic.List[string]]::new()
        Mock Invoke-InstalledAction {
            $Root|Should -BeExactly $script:planFixture.Root
            $script:planActions.Add($Action)
            if($Action -ceq 'begin-verification-change' -and -not $AdditionalArguments){Write-RejectionJson $script:planningConsole $script:planningView}
            if($AdditionalArguments){$script:submittedPlan=Get-Content $AdditionalArguments[1] -Raw -Encoding UTF8|ConvertFrom-Json}
            [pscustomobject]@{exitCode=0;stdout=$script:inspectionOutput}
        }
        Mock Assert-FreshVerificationResult {$script:planActions.Add('assert-fresh')}
        [void](Invoke-DevelopPlannedCheck -Name fresh-check -Root $root)
        @($script:planActions)|Should -Be @('begin-verification-change','begin-verification-change','check-dev-branch','assert-fresh','complete-verification-change')
        $script:submittedPlan.checks[0].suiteId|Should -BeExactly 'itl-develop-journey'
        @($script:submittedPlan.paths.path)|Should -Be $script:planningView.changedPaths
        $script:submittedPlan.criteria[0].decision|Should -BeExactly 'check'
        Add-FreshVerificationCatalog -Root $root
        $catalog=Get-Content (Join-Path $root 'tests/verification-suites.branch.json') -Raw -Encoding UTF8|ConvertFrom-Json
        $catalog.schemaVersion|Should -Be 1
        $catalog.suites[0].id|Should -BeExactly 'itl-develop-journey'
        $catalog.suites[0].ownerPaths|Should -Contain '.agents/skills/1c-workflow/scripts/lib/agent-1c.verification-change.ps1'
        $script:submittedPlan.criteria[0].checkIds|Should -Be @('vanessa/itl-develop-journey')
    }
    It 'does not accept a check rejected by the original freshness assertion' {
        $root=$script:planFixture.Root
        $helper=Join-Path $root '.agents/skills/1c-workflow/scripts/agent-1c.ps1'
        [void][IO.Directory]::CreateDirectory((Split-Path $helper))
        [IO.File]::WriteAllText($helper,'param([ValidateSet("begin-verification-change")][string]$Action)')
        Mock Invoke-InstalledAction {
            if($Action -ceq 'begin-verification-change' -and -not $AdditionalArguments){Write-RejectionJson $script:planningConsole $script:planningView}
            [pscustomobject]@{exitCode=0;stdout=$script:inspectionOutput}
        }
        Mock Assert-FreshVerificationResult {throw 'Verification status lacks a fresh passed fingerprint.'}
        {Invoke-DevelopPlannedCheck -Name fresh-check -Root $root}|Should -Throw '*fresh passed fingerprint*'
        Should -Invoke Invoke-InstalledAction -Times 0 -ParameterFilter {$Action -eq 'complete-verification-change'}
    }
    It 'preserves an existing unrelated task or criterion (<task>)' -ForEach @(
        @{task='foreign-task';priorCriteria=@()},
        @{task='develop-journey';priorCriteria=@(@{id='AC-existing';expectedResult='Keep the original requirement';decision='pending'})}
    ) {
        $root=$script:planFixture.Root
        $helper=Join-Path $root '.agents/skills/1c-workflow/scripts/agent-1c.ps1'
        [void][IO.Directory]::CreateDirectory((Split-Path $helper))
        [IO.File]::WriteAllText($helper,'param([ValidateSet("begin-verification-change")][string]$Action)')
        $script:planningView.taskId=$task;$script:planningView.criteria=$priorCriteria
        {Invoke-DevelopPlannedCheck -Name fresh-check -Root $root}|Should -Throw '*CHANGE_SCOPE_UNSUPPORTED*'
        $script:submittedPlan|Should -BeNullOrEmpty
        Should -Invoke Invoke-InstalledAction -Times 0 -ParameterFilter {$Action -eq 'check-dev-branch' -or $Action -eq 'complete-verification-change'}
    }
    It 'retains the ordinary check without change completion for an explicit cumulative project' {
        $root=$script:planFixture.Root
        $helper=Join-Path $root '.agents/skills/1c-workflow/scripts/agent-1c.ps1'
        [void][IO.Directory]::CreateDirectory((Split-Path $helper))
        [IO.File]::WriteAllText($helper,'param([ValidateSet("begin-verification-change")][string]$Action)')
        Write-RejectionJson $script:inspectionOutput @{action='begin-verification-change';status='failed';error='VERIFICATION_CHANGE_MODEL: select ITL_VERIFICATION_MODEL=change before preparing a change plan.'}
        Mock Invoke-InstalledAction {[pscustomobject]@{exitCode=$(if($Action -eq 'begin-verification-change'){1}else{0});stdout=$script:inspectionOutput}}
        Mock Assert-FreshVerificationResult {}
        [void](Invoke-DevelopPlannedCheck -Name fresh-check -Root $root)
        Should -Invoke Invoke-InstalledAction -Times 1 -ParameterFilter {$Action -eq 'check-dev-branch'}
        Should -Invoke Invoke-InstalledAction -Times 0 -ParameterFilter {$Action -eq 'complete-verification-change'}
        Should -Invoke Assert-FreshVerificationResult -Times 1
    }
}

Describe 'Verification inspection console payload' {
    BeforeAll {
        function InspectionMetadata {
            param([ValidateSet('begin-verification-change')][string]$Action)
        }
    }
    BeforeEach {
        $script:inspectRoot=Join-Path $TestDrive ('inspection '+(-join [char[]](0x041F,0x0443,0x0442,0x044C))+' with spaces')
        $script:inspectConsole=Join-Path $script:inspectRoot '.agent-1c/runs/inspect/console.log'
        [void][IO.Directory]::CreateDirectory((Split-Path $script:inspectConsole))
        $script:inspectionPayload=@{model='change';status='planning';baseTree=('a'*40);tree=('b'*40);changedPaths=@();taskId='';criteria=@();requirementPaths=@()}
        $summary=Join-Path $script:inspectRoot 'compact.stdout.log'
        Write-RejectionJson $summary @{action='begin-verification-change';status='succeeded';logPath=$script:inspectConsole}
        $script:inspectionProcess=[pscustomobject]@{exitCode=0;stdout=$summary}
        Mock Invoke-InstalledAction {$script:inspectionProcess}
    }
    It 'reads the planning payload after the original catalog diagnostics' {
        $text="Skipping remote vibecoding1c MCP server 'docs': endpoint was not found in registry.`r`nCatalog settings applied. Reload the client/new session.`r`n"+($script:inspectionPayload|ConvertTo-Json -Depth 8 -Compress)+"`r`n"
        [IO.File]::WriteAllText($script:inspectConsole,$text,[Text.UTF8Encoding]::new($false))
        $view=Get-DevelopVerificationChangeInspection -Root $script:inspectRoot -Name inspect -HelperCommand (Get-Command InspectionMetadata)
        $view.model | Should -BeExactly 'change'
        $view.baseTree | Should -BeExactly ('a'*40)
        $view.tree | Should -BeExactly ('b'*40)
    }
    It 'retains malformed payload, unsupported scope and invalid UTF-8 refusal: <Case>' -TestCases @(@{Case='malformed'},@{Case='scope'},@{Case='utf8'}) {
        param($Case)
        $text=$script:inspectionPayload|ConvertTo-Json -Depth 8 -Compress
        if($Case -eq 'malformed'){$text+="`n{broken"}
        if($Case -eq 'scope'){$script:inspectionPayload.model='cumulative';$text=$script:inspectionPayload|ConvertTo-Json -Depth 8 -Compress}
        [IO.File]::WriteAllText($script:inspectConsole,$text,[Text.UTF8Encoding]::new($false))
        if($Case -eq 'utf8'){[IO.File]::WriteAllBytes($script:inspectConsole,[byte[]](255))}
        {Get-DevelopVerificationChangeInspection -Root $script:inspectRoot -Name inspect -HelperCommand (Get-Command InspectionMetadata)} | Should -Throw
    }
}
