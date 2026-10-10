BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    . (Join-Path $repoRoot 'scripts/develop-configuration-rejection.ps1')
    . (Join-Path $repoRoot 'scripts/stand-env-identity.ps1')
    . (Join-Path $repoRoot 'scripts/develop-e2e-qualification.ps1')
    foreach ($group in @(
        @{path='scripts/invoke-develop-e2e.ps1';names=@('Read-CompactSummary','Invoke-DevelopUpgradeRefresh')},
        @{path='scripts/check.ps1';names=@('Get-DevelopE2EIdentitySha256')},
        @{path='.agents/skills/1c-workflow/scripts/lib/agent-1c.lifecycle.ps1';names=@('Write-ConfigLoadRejectionEvidence')},
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
        $summary=[pscustomobject]@{action='refresh-dev-branch';status='failed';error=$message;logPath=$console}
        $stdout=Join-Path $root 'stdout.log'; Write-RejectionJson $stdout $summary
        Write-RejectionJson (Join-Path $root '.agent-1c/dev-branches/fixture.json') @{
            devBranchInfoBasePath=(Join-Path $root 'base');infoBaseKind='file';pendingMergeOperation='refresh-dev-branch';pendingMergeStage='merged'
        }
        $receiptPath=(Get-ChildItem -LiteralPath $logs -Filter '1c-gate6-rejection-*.json').FullName
        return @{Root=$root;Expected=[pscustomobject]@{sourcePath='src/cf/CommonModules/Reproducer/Ext/Module.bsl';
            sourceSha256=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant();diagnostic=$diagnostic};
            Result=[pscustomobject]@{exitCode=1;stdout=$stdout};Receipt=$receiptPath;Summary=$summary;Failure=$failure;Log=$log;Source=$source}
    }
    function Assert-FixtureRejection([hashtable]$Fixture) {
        Assert-DevelopConfigurationRejection -ProcessResult $Fixture.Result -Expected $Fixture.Expected -Root $Fixture.Root -BranchName fixture
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
    It 'rejects a successful refresh instead of silently losing the negative reproducer' {
        $fixture=New-RejectionFixture; $fixture.Result.exitCode=0
        { Assert-FixtureRejection $fixture } | Should -Throw '*UNEXPECTED_RESULT*'
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
            $output=Write-ConfigLoadRejectionEvidence -Failure $fixture.Failure 6>&1 | Out-String
            $output | Should -Not -Match 'GATE6_REJECTION_EVIDENCE'
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
