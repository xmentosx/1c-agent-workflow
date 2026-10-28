BeforeAll {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    . (Join-Path $RepoRoot 'scripts/source-e2e-fixture.ps1')
    . (Join-Path $RepoRoot 'scripts/source-e2e-create-infobase.ps1')
    function New-QualificationSeed {
        param([string]$Root)
        $project=Join-Path $Root 'seed';$branch=Join-Path $Root 'seed-branch'
        [void][IO.Directory]::CreateDirectory((Join-Path $project '.agent-1c'))
        Invoke-RepositoryGit -RepositoryRoot $project -Arguments @('init','-b','master')|Out-Null
        Invoke-RepositoryGit -RepositoryRoot $project -Arguments @('config','user.name','Tests')|Out-Null
        Invoke-RepositoryGit -RepositoryRoot $project -Arguments @('config','user.email','tests@example.invalid')|Out-Null
        Write-Utf8Text -Path (Join-Path $project '.agent-1c/project.json') -Value '{"aiRules":{"tools":["kilocode"]}}'
        # A source candidate can predate the current published tip. Its sealed
        # N-1 fixture must use a published ancestor of that candidate too.
        $published=(Invoke-RepositoryGit -RepositoryRoot $RepoRoot -Arguments @('merge-base','HEAD','refs/remotes/origin/develop')).stdout.Trim()
        $ignore=(Invoke-RepositoryGit -RepositoryRoot $RepoRoot -Arguments @('show',($published+':templates/gitignore.append'))).stdout
        Write-Utf8Text -Path (Join-Path $project '.gitignore') -Value $ignore
        Write-Utf8Text -Path (Join-Path $project '.agent-1c/dependency-lock.json') -Value ('{"dependencies":{"workflowPackage":{"commit":"'+$published+'"}}}')
        Write-Utf8Text -Path (Join-Path $project 'src/cf/invalid.bsl') -Value 'original negative source'
        Invoke-RepositoryGit -RepositoryRoot $project -Arguments @('add','--all')|Out-Null
        Invoke-RepositoryGit -RepositoryRoot $project -Arguments @('commit','-m','seed')|Out-Null
        Invoke-RepositoryGit -RepositoryRoot $project -Arguments @('branch','unrelated-user-task')|Out-Null
        Invoke-RepositoryGit -RepositoryRoot $project -Arguments @('checkout','--detach','HEAD')|Out-Null
        Write-Utf8Text -Path (Join-Path $project 'pending-object.txt') -Value 'required historical pending endpoint'
        Invoke-RepositoryGit -RepositoryRoot $project -Arguments @('add','--','pending-object.txt')|Out-Null
        Invoke-RepositoryGit -RepositoryRoot $project -Arguments @('commit','-m','pending endpoint')|Out-Null
        $pendingCommit=(Invoke-RepositoryGit -RepositoryRoot $project -Arguments @('rev-parse','HEAD')).stdout.Trim()
        Invoke-RepositoryGit -RepositoryRoot $project -Arguments @('checkout','master')|Out-Null
        Invoke-RepositoryGit -RepositoryRoot $project -Arguments @('worktree','add','-b','itldev/negative',$branch,'master')|Out-Null
        $config=@{schemaVersion=1;developDevBranchName='negative';developWorktreePath=$branch;devBranchName='release';worktreePath=(Join-Path $Root 'unused-release')}
        Write-QualificationFixtureJson -Path (Join-Path $project '.agent-1c/release-e2e.json') -Value $config
        $state=@{devBranchName='negative';safeDevBranchName='negative';devBranch='itldev/negative';worktreePath=$branch;mainWorktreePath=$project;infoBaseKind='file';devBranchKind='configuration';devBranchInfoBasePath=(Join-Path $branch '.agent-1c/infobases/negative');pendingMergeOperation='refresh-dev-branch';pendingMergeStage='merged';pendingMergeCommit=((Invoke-RepositoryGit -RepositoryRoot $branch -Arguments @('rev-parse','HEAD')).stdout.Trim());eventLogPendingCursor=@{position=17;at='2026-10-12T01:02:03.1234567+03:00'};lastConfigDesignerFingerprint='';lastConfigDesignerTreeObjectId='';sourceFingerprint='';roctupMcpPid='999999';vanessaMcpPort=6123;vanessaMcpSafeModeProof=@{status='passed'};launcherRegistered=$true;lastVerifiedCommit=('b'*40);verifiedFingerprint='old-green'}
        Write-QualificationFixtureJson -Path (Join-Path $branch '.agent-1c/dev-branches/negative.json') -Value $state
        Write-Utf8Text -Path (Join-Path $state.devBranchInfoBasePath '1Cv8.1CD') -Value 'synthetic original database bytes'
        foreach($item in @($project,$branch)){Write-Utf8Text -Path (Join-Path $item '.dev.env') -Value ('INFOBASE_KIND=file'+"`nINFOBASE_PATH="+(Join-Path $item '.agent-1c/infobases/source')+"`nPLATFORM_PATH=C:\platform\1cv8.exe`nROCTUP_MCP_PORT=6123`nITL_ACTIVE_PROJECT_ROOT="+$project+"`n")}
        $state.pendingMergeCommit=$pendingCommit
        Write-QualificationFixtureJson -Path (Join-Path $branch '.agent-1c/dev-branches/negative.json') -Value $state
        return [pscustomobject]@{project=$project;branch=$branch;pendingCommit=$pendingCommit}
    }
    function Add-SeedWorkflowUpdate {
        param([string]$Root,[string]$Value,[string]$ChangedPath='AGENT-INSTALL.md')
        $script:ProjectRoot=$Root
        $source=[pscustomobject]@{root=$RepoRoot;commit=('b'*40);ref='develop';repo='fixture';source='path'}
        $snapshot=New-WorkflowUpdateRollbackSnapshot -RelativePaths @($ChangedPath,'.dev.env') -SnapshotParent (Join-Path $Root '.agent-1c/snapshots/workflow-update')
        Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase prepared
        Write-Utf8Text -Path (Join-Path $Root $ChangedPath) -Value $Value
        [IO.File]::AppendAllText((Join-Path $Root '.dev.env'),("WORKFLOW_FIXTURE_VALUE="+$Value+"`n"),[Text.UTF8Encoding]::new($false))
        Invoke-RepositoryGit -RepositoryRoot $Root -Arguments @('add','--',$ChangedPath)|Out-Null
        Invoke-RepositoryGit -RepositoryRoot $Root -Arguments @('commit','-m','owned workflow fixture update')|Out-Null
        Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase post-copy-complete
        return Retain-WorkflowUpdateRollbackSnapshot -Snapshot $snapshot
    }
}

Describe 'Owned qualification native database creation before restore' {
    BeforeEach {
        $parent=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $project=Join-Path $parent 'project';$branch=Join-Path $parent 'branch'
        [void][IO.Directory]::CreateDirectory($project)
        Invoke-RepositoryGit -RepositoryRoot $project -Arguments @('init','-b','master')|Out-Null
        Invoke-RepositoryGit -RepositoryRoot $project -Arguments @('config','user.name','Tests')|Out-Null
        Invoke-RepositoryGit -RepositoryRoot $project -Arguments @('config','user.email','tests@example.invalid')|Out-Null
        Write-Utf8Text -Path (Join-Path $project 'seed.txt') -Value 'seed'
        Invoke-RepositoryGit -RepositoryRoot $project -Arguments @('add','--all')|Out-Null
        Invoke-RepositoryGit -RepositoryRoot $project -Arguments @('commit','-m','seed')|Out-Null
        Invoke-RepositoryGit -RepositoryRoot $project -Arguments @('worktree','add','--detach',$branch,'HEAD')|Out-Null
        $script:createBranch=$branch;$script:createBase=Join-Path $branch '.agent-1c/infobases/test base Пример'
        Write-QualificationFixtureJson -Path (Join-Path $parent 'qualification-fixture.json') -Value @{kind='itl-qualification-fixture-target';status='materializing';projectRoot=$project;branchRoot=$branch}
        Write-QualificationFixtureJson -Path (Join-Path $branch '.agent-1c/dev-branches/negative.json') -Value @{infoBaseKind='file';devBranchName='negative';devBranchInfoBasePath=$script:createBase}
        Mock Invoke-WithOneCSessionAdmissionContext {param($InfoBaseKind,$InfoBasePath,$RequiredSessions,$Purpose,$ScriptBlock) & $ScriptBlock}
        Mock Invoke-NativeProcessAndWaitResult {param($FilePath,$Arguments,$OneCCreateInfoBaseSyntax,$TimeoutSeconds)
            Write-Utf8Text -Path (Join-Path $script:createBase '1Cv8.1CD') -Value 'native-result fixture'
            return [pscustomobject]@{timedOut=$false;exitCode=0}
        }
    }
    It 'admits exactly the owned base and uses native CREATEINFOBASE with the shared connection quoting contract' {
        $result=New-SourceQualificationInfoBase -BranchRoot $script:createBranch -BranchName negative -PlatformPath 'C:\Platform\1cv8.exe'
        $result.infoBasePath|Should -BeExactly $script:createBase
        (Read-Utf8Text -Path (Join-Path $script:createBase '1Cv8.1CD'))|Should -BeExactly 'native-result fixture'
        Should -Invoke Invoke-WithOneCSessionAdmissionContext -Times 1 -ParameterFilter {$InfoBaseKind -eq 'file' -and $InfoBasePath -ceq $script:createBase -and $RequiredSessions -eq 1 -and $Purpose -eq 'qualification-infobase-create'}
        Should -Invoke Invoke-NativeProcessAndWaitResult -Times 1 -ParameterFilter {$Arguments[0] -ceq 'CREATEINFOBASE' -and $Arguments[1] -ceq (New-FileInfoBaseConnectionString -Path $script:createBase) -and $OneCCreateInfoBaseSyntax -and $TimeoutSeconds -eq 300}
    }
    It 'retains an existing partial base and refuses another native launch' {
        Write-Utf8Text -Path (Join-Path $script:createBase 'partial.txt') -Value 'keep original failure'
        {New-SourceQualificationInfoBase -BranchRoot $script:createBranch -BranchName negative -PlatformPath unused}|Should -Throw '*FIXTURE_CREATE_TARGET_EXISTS*'
        (Read-Utf8Text -Path (Join-Path $script:createBase 'partial.txt'))|Should -BeExactly 'keep original failure'
        Should -Invoke Invoke-NativeProcessAndWaitResult -Times 0
    }
    It 'retires Release only with an exact archived database: <scenario>' -ForEach @(@{scenario='valid'},@{scenario='archive-corrupt'},@{scenario='database-changed'},@{scenario='locked'}) -Tag archive_inactive {
        $candidate='a'*40;$capsule='b'*64;$claimPath=Join-Path $parent 'qualification-fixture.json'
        $claim=Read-QualificationFixtureJson -Path $claimPath
        $claim|Add-Member phase Release;$claim|Add-Member candidateCommit $candidate;$claim|Add-Member capsuleSha256 $capsule
        Write-QualificationFixtureJson -Path $claimPath -Value $claim
        $database=Join-Path $script:createBase '1Cv8.1CD';Write-Utf8Text -Path $database -Value 'unique inactive database'
        $diagnostics=Join-Path $TestDrive 'archive Пример';[void][IO.Directory]::CreateDirectory($diagnostics)
        $relative=$database.Substring($parent.Length+1).Replace('\','/');$sha=(Get-FileHash -LiteralPath $database).Hash.ToLowerInvariant()
        Write-QualificationFixtureJson -Path (Join-Path $diagnostics 'cleanup-proof.json') -Value @{kind='itl-fixture-copy-cleanup-proof';reason='archive-inactive-qualification';copyRoot=$parent;candidateCommit=$candidate;phase='Release';capsule=@{sha256=$capsule}}
        $index=Join-Path $diagnostics 'recovery-index.json'
        Write-QualificationFixtureJson -Path $index -Value @(@{path=$relative;sha256=$sha;retainedSource=$null})
        Add-Type -AssemblyName System.IO.Compression
        $stream=[IO.File]::Create((Join-Path $diagnostics 'recovery.zip'));$zip=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create)
        try {$output=$zip.CreateEntry($relative).Open();$bytes=[Text.Encoding]::UTF8.GetBytes($(if($scenario -eq 'archive-corrupt'){'corrupt archived bytes'}else{'unique inactive database'}));try {$output.Write($bytes,0,$bytes.Length)}finally{$output.Dispose()}}finally{$zip.Dispose();$stream.Dispose()}
        $script:disposalGuardRoot=Join-Path $parent 'custom guard root'
        Mock Get-OneCExecutionGuardSettings {[pscustomobject]@{root=$script:disposalGuardRoot;python='';waitTimeoutSeconds=5}}
        $handle=$null
        try {
            if($scenario -eq 'database-changed'){Write-Utf8Text -Path $database -Value 'new state must survive'}
            if($scenario -eq 'locked'){$handle=[IO.File]::Open($database,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)}
            $disposalParameters=@{BranchRoot=$branch;CandidateCommit=$candidate;ArchivedInactive=$true;RecoveryArchiveIndex=$index}
            if($scenario -eq 'valid'){
                (Remove-SourceQualificationDatabases @disposalParameters).status|Should -BeExactly 'disposed'
                Test-Path -LiteralPath $database|Should -BeFalse
            }else{
                {Remove-SourceQualificationDatabases @disposalParameters}|Should -Throw
                Test-Path -LiteralPath $database|Should -BeTrue
                (Read-QualificationFixtureJson -Path $claimPath).status|Should -BeExactly 'materializing'
            }
        }finally{if($handle){$handle.Dispose()}}
    }
    It 'rejects a successful launcher without an actual database file' {
        Mock Invoke-NativeProcessAndWaitResult {[pscustomobject]@{timedOut=$false;exitCode=0}}
        {New-SourceQualificationInfoBase -BranchRoot $script:createBranch -BranchName negative -PlatformPath unused}|Should -Throw '*FIXTURE_CREATE_FAILED*'
    }
    It 'rejects a foreign state path before guard admission' {
        Write-QualificationFixtureJson -Path (Join-Path $script:createBranch '.agent-1c/dev-branches/negative.json') -Value @{infoBaseKind='file';devBranchName='negative';devBranchInfoBasePath=(Join-Path $TestDrive 'foreign')}
        {New-SourceQualificationInfoBase -BranchRoot $script:createBranch -BranchName negative -PlatformPath unused}|Should -Throw '*FIXTURE_CREATE_TARGET_INVALID*'
        Should -Invoke Invoke-WithOneCSessionAdmissionContext -Times 0
    }
    It 'disposes only derived Develop database bytes with real guard and file ownership: <scenario>' -ForEach @(
        @{scenario='ready'},@{scenario='materializing'},@{scenario='locked'},@{scenario='foreign-candidate'},@{scenario='release'},
        @{scenario='seed-cache'},@{scenario='seed-reader-locked'},@{scenario='seed-cache-foreign'}
    ) {
        $candidate='a'*40
        $claimPath=Join-Path $parent 'qualification-fixture.json'
        $claim=Read-QualificationFixtureJson -Path $claimPath
        $claim|Add-Member phase $(if($scenario -eq 'release'){'Release'}else{'Develop'})
        $claim|Add-Member candidateCommit $candidate
        $claim.status=if($scenario -eq 'materializing'){'materializing'}else{'ready'}
        Write-QualificationFixtureJson -Path $claimPath -Value $claim
        $database=Join-Path $script:createBase '1Cv8.1CD'
        Write-Utf8Text -Path $database -Value 'derived database bytes'
        $snapshot=Join-Path $branch '.agent-1c/snapshots/seed.dt'
        Write-Utf8Text -Path $snapshot -Value 'immutable snapshot'
        $log=Join-Path $parent 'preparation-logs/restore.log'
        Write-Utf8Text -Path $log -Value 'original restore evidence'
        $foreign=Join-Path $parent 'project/.agent-1c/infobases/user/1Cv8.1CD'
        Write-Utf8Text -Path $foreign -Value 'seed database bytes'
        $cacheDatabase=$null; $cachePaths=$null
        if($scenario -like 'seed-*'){
            $cacheRoot=Join-Path $project ('.agent-1c/branch-seed/'+('c'*64))
            $cacheDatabase=Join-Path $cacheRoot 'infobase/1Cv8.1CD'
            Write-Utf8Text -Path $cacheDatabase -Value 'derived branch seed cache bytes'
            Write-QualificationFixtureJson -Path (Join-Path $cacheRoot 'manifest.json') -Value @{
                schemaVersion=1;status='ready';sourceKey=('c'*64);artifactKind='file-1cd'
                artifactPath=$(if($scenario -eq 'seed-cache-foreign'){$foreign}else{$cacheDatabase})
            }
            $cachePaths=@{root=$cacheRoot;leasePath=(Join-Path $cacheRoot 'seed.lease');writerIntentPath=(Join-Path $cacheRoot 'seed.writer.lock');rebuildMarkerPath=(Join-Path $cacheRoot 'rebuild.marker.json')}
        }
        $script:disposalGuardRoot=Join-Path $parent 'custom guard root'
        Mock Get-OneCExecutionGuardSettings {[pscustomobject]@{root=$script:disposalGuardRoot;python='';waitTimeoutSeconds=5}}
        $handle=$null
        try {
            if($scenario -eq 'seed-reader-locked'){
                $handle=Open-BranchSeedLease -Paths $cachePaths -Mode read -TimeoutSeconds 1
                {Remove-SourceQualificationDatabases -BranchRoot $branch -CandidateCommit $candidate}|Should -Throw '*BRANCH_SEED_LEASE_TIMEOUT*'
                Test-Path -LiteralPath $database|Should -BeTrue
                Test-Path -LiteralPath $cacheDatabase|Should -BeTrue
                $handle.Dispose();$handle=$null
            }
            if($scenario -eq 'locked'){
                $handle=[IO.File]::Open($database,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
                {Remove-SourceQualificationDatabases -BranchRoot $branch -CandidateCommit $candidate}|Should -Throw
                (Read-QualificationFixtureJson -Path $claimPath).status|Should -BeExactly 'ready'
                $handle.Dispose();$handle=$null
            }
            if($scenario -eq 'seed-cache-foreign'){
                {Remove-SourceQualificationDatabases -BranchRoot $branch -CandidateCommit $candidate}|Should -Throw '*FIXTURE_SEED_CACHE_OWNERSHIP_INVALID*'
                Test-Path -LiteralPath $database|Should -BeTrue
                Test-Path -LiteralPath $cacheDatabase|Should -BeTrue
            } elseif($scenario -in @('foreign-candidate','release')){
                $expected=if($scenario -eq 'foreign-candidate'){'b'*40}else{$candidate}
                {Remove-SourceQualificationDatabases -BranchRoot $branch -CandidateCommit $expected}|Should -Throw '*FIXTURE_DISPOSE_OWNERSHIP_INVALID*'
                Test-Path -LiteralPath $database|Should -BeTrue
                Test-Path -LiteralPath $script:disposalGuardRoot|Should -BeFalse
            } else {
                $result=Remove-SourceQualificationDatabases -BranchRoot $branch -CandidateCommit $candidate
                $result.status|Should -BeExactly 'disposed'
                @($result.removedDatabases).Count|Should -Be $(if($cacheDatabase){2}else{1})
                if($cacheDatabase){Test-Path -LiteralPath $cacheDatabase|Should -BeFalse; Test-Path -LiteralPath (Join-Path $cachePaths.root 'manifest.json')|Should -BeTrue}
                Test-Path -LiteralPath $database|Should -BeFalse
                Test-Path -LiteralPath $script:disposalGuardRoot|Should -BeTrue
                (Read-QualificationFixtureJson -Path $claimPath).status|Should -BeExactly 'disposed'
                {Remove-SourceQualificationDatabases -BranchRoot $branch -CandidateCommit $candidate}|Should -Not -Throw
            }
            (Read-Utf8Text -Path $snapshot)|Should -BeExactly 'immutable snapshot'
            (Read-Utf8Text -Path $log)|Should -BeExactly 'original restore evidence'
            (Read-Utf8Text -Path $foreign)|Should -BeExactly 'seed database bytes'
        } finally {if($handle){$handle.Dispose()}}
    }
}

Describe 'Initial restore credentials of a new owned database' {
    It 'uses no seed credentials only during first RestoreIB and preserves env ownership after failure=<failure>, foreign=<foreign>' -ForEach @(@{failure=$false;foreign=$false},@{failure=$true;foreign=$false},@{failure=$false;foreign=$true}) {
        $parent=Join-Path $TestDrive ('initial restore '+$failure);$root=Join-Path $parent 'branch'
        [void][IO.Directory]::CreateDirectory($root)
        Write-QualificationFixtureJson -Path (Join-Path $parent 'qualification-fixture.json') -Value @{kind='itl-qualification-fixture-target';status='materializing';branchRoot=$root}
        $envPath=Join-Path $root '.dev.env'
        $original=[Text.UTF8Encoding]::new($true).GetPreamble()+[Text.UTF8Encoding]::new($false).GetBytes("# keep`r`nIB_USER=seed user`r`nIB_PASSWORD=fixture secret`r`nOTHER=unchanged`r`n")
        [IO.File]::WriteAllBytes($envPath,$original)
        $oldUser=$env:IB_USER;$oldPassword=$env:IB_PASSWORD
        try {
            $env:IB_USER='inherited user';$env:IB_PASSWORD='inherited secret'
            Mock Invoke-SourceFixtureInstalledAction {
                param($Root,$Action)
                $Action|Should -BeExactly 'release-e2e-restore'
                $text=Read-Utf8Text -Path (Join-Path $Root '.dev.env')
                $text|Should -Not -Match '(?m)^IB_(USER|PASSWORD)='
                $text|Should -Match 'OTHER=unchanged'
                $env:IB_USER|Should -BeNullOrEmpty;$env:IB_PASSWORD|Should -BeNullOrEmpty
                if($foreign){$text=$text.Replace('OTHER=unchanged','OTHER=unexpected')}
                Write-Utf8Text -Path (Join-Path $Root '.dev.env') -Value ($text+"ITL_ACTIVE_DEV_BRANCH=itldev/negative`r`nVANESSA_MCP_PORT=12345`r`n")
                if($failure){throw 'original restore failure'}
                return [pscustomobject]@{exitCode=0}
            }
            if($foreign){{Invoke-SourceFixtureInitialRestore -Root $root -Arguments @('-DevBranchName','negative') -AgentTarget kilocode -LogRoot $root}|Should -Throw '*FIXTURE_INITIAL_ENV_CHANGED*'}
            elseif($failure){{Invoke-SourceFixtureInitialRestore -Root $root -Arguments @('-DevBranchName','negative') -AgentTarget kilocode -LogRoot $root}|Should -Throw '*original restore failure*'}
            else{(Invoke-SourceFixtureInitialRestore -Root $root -Arguments @('-DevBranchName','negative') -AgentTarget kilocode -LogRoot $root).exitCode|Should -Be 0}
            if($foreign){(Read-Utf8Text -Path $envPath)|Should -Match 'OTHER=unexpected'}
            else{[Convert]::ToBase64String([IO.File]::ReadAllBytes($envPath))|Should -BeExactly ([Convert]::ToBase64String($original))}
            $env:IB_USER|Should -BeExactly 'inherited user';$env:IB_PASSWORD|Should -BeExactly 'inherited secret'
            Should -Invoke Invoke-SourceFixtureInstalledAction -Times 1
        }finally{$env:IB_USER=$oldUser;$env:IB_PASSWORD=$oldPassword}
    }
}

Describe 'Owned qualification fixture capsule and lifecycle context' {
    BeforeEach {
        Mock Invoke-SourceFixtureInstalledAction {
            param($Root,$Action,$Arguments,$AgentTarget,$LogRoot,$TimeoutSeconds)
            if($Action -eq 'release-e2e-snapshot'){
                $index=[Array]::IndexOf($Arguments,'-ReleaseSnapshotPath')
                Write-Utf8Text -Path (Join-Path $Root $Arguments[$index+1]) -Value 'synthetic database snapshot; never live acceptance'
            }
            if($Action -eq 'qualification-create-infobase'){
                $state=Read-QualificationFixtureJson -Path (Join-Path $Root ('.agent-1c/dev-branches/'+$Arguments[1]+'.json'))
                Write-Utf8Text -Path (Join-Path $state.devBranchInfoBasePath '1Cv8.1CD') -Value 'synthetic native create result; never live acceptance'
            }
            if($Action -eq 'release-e2e-restore'){
                $state=Read-QualificationFixtureJson -Path (Join-Path $Root ('.agent-1c/dev-branches/'+$Arguments[1]+'.json'))
                if(-not (Test-Path -LiteralPath (Join-Path $state.devBranchInfoBasePath '1Cv8.1CD'))){throw 'RestoreIB requires native creation first'}
            }
            return [pscustomobject]@{stdout='mock';stderr='mock';durationMs=12}
        }
    }

    It 'records a clone failure before the first Git write and reclaims only its owned factory files' {
        $seed=New-QualificationSeed -Root (Join-Path $TestDrive 'early failure seed')
        $receipt=Join-Path $TestDrive 'early-failure.json';$projects=Join-Path $TestDrive 'failed factory Пример'
        Mock Invoke-RepositoryGit {throw 'original clone failure'} -ParameterFilter {$Arguments[0] -eq 'clone'}
        {New-SourceE2EFixtureProject -ProjectRoot $seed.project -Phase Develop -CandidateRoot $RepoRoot -ProjectsRoot $projects -ReceiptPath $receipt}|Should -Throw '*original clone failure*'
        $failed=Read-QualificationFixtureJson -Path $receipt
        $failed.claim.status|Should -BeExactly 'preparation-failed'
        $failed.claim.preparationFailure.error|Should -BeExactly 'original clone failure'
        Test-Path -LiteralPath $failed.projectRoot|Should -BeFalse
        $lease=Open-SourceE2EFixtureUse -ProjectRoot $failed.projectRoot
        $lease.Dispose()
        $result=Remove-CompletedSourceE2ECopies -ProjectsRoot $projects -CandidateRoot $RepoRoot -DiagnosticRoot (Join-Path $TestDrive 'failure evidence') -IncludeLegacy
        $result.removed|Should -Be 1
        Test-Path -LiteralPath $failed.claim.copyRoot|Should -BeFalse
        (Read-QualificationFixtureJson -Path (Join-Path $result.entries[0].diagnostics 'qualification-fixture.json')).preparationFailure.error|Should -BeExactly 'original clone failure'
        Test-Path -LiteralPath $seed.project|Should -BeTrue
    }

    It 'prepares a stand through the publisher with a native lifecycle update and the real Capture owner, then resumes without new admission' {
        $seed=New-QualificationSeed -Root (Join-Path $TestDrive 'Сквозная подготовка стенда')
        $descriptor=Get-SourceE2EFixtureCapsule -ProjectRoot $seed.project -Phase Develop
        $configPath=Join-Path $seed.project '.agent-1c/release-e2e.json'
        $candidate=Join-Path $TestDrive 'кандидат публикации'
        Invoke-RepositoryGit -RepositoryRoot $RepoRoot -Arguments @('worktree','add','--detach',$candidate,'HEAD')|Out-Null
        try {
            # Only the stand update is a test double; it still writes real
            # lifecycle transactions in a separate process. Capture is the
            # candidate's own owner script invoked with the publisher's argv.
            $updater=@'
param($ProjectRoot,$SourceRoot,$WorkflowUpdateBranchRootsFile)
$ErrorActionPreference='Stop'
. (Join-Path $SourceRoot 'scripts/git-path-list.ps1')
$lib=Join-Path $SourceRoot '.agents/skills/1c-workflow/scripts/lib'
. (Join-Path $lib 'agent-1c.core.ps1'); . (Join-Path $lib 'agent-1c.lifecycle.ps1')
$scope=[IO.File]::ReadAllText($WorkflowUpdateBranchRootsFile,[Text.UTF8Encoding]::new($false))|ConvertFrom-Json
foreach($root in @($ProjectRoot)+@($scope.roots)){
    $script:ProjectRoot=$root
    $source=[pscustomobject]@{root=$SourceRoot;commit=('c'*40);ref='develop';repo='fixture';source='path'}
    $snapshot=New-WorkflowUpdateRollbackSnapshot -RelativePaths @('AGENT-INSTALL.md','.dev.env') -SnapshotParent (Join-Path $root '.agent-1c/snapshots/workflow-update')
    Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase prepared
    [IO.File]::WriteAllText((Join-Path $root 'AGENT-INSTALL.md'),'candidate package',[Text.UTF8Encoding]::new($false))
    [IO.File]::AppendAllText((Join-Path $root '.dev.env'),"WORKFLOW_FIXTURE_VALUE=candidate`n",[Text.UTF8Encoding]::new($false))
    Invoke-RepositoryGit -RepositoryRoot $root -Arguments @('add','--','AGENT-INSTALL.md')|Out-Null
    Invoke-RepositoryGit -RepositoryRoot $root -Arguments @('commit','-m','candidate workflow update')|Out-Null
    Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase post-copy-complete
    $null=Retain-WorkflowUpdateRollbackSnapshot -Snapshot $snapshot
}
'@
            [IO.File]::WriteAllText((Join-Path $candidate 'scripts/update-installed-workflow.ps1'),$updater,[Text.UTF8Encoding]::new($true))
            & {
                . (Join-Path $RepoRoot 'scripts/source-delivery-release-recovery.ps1')
                $tokens=$null;$errors=$null
                $component=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'scripts/source-delivery-component.ps1'),[ref]$tokens,[ref]$errors)
                . ([scriptblock]::Create(@($component.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'ConvertTo-DeliveryNativeArgument'},$true))[0].Extent.Text))
                # Checkpoint persistence and the Pester warmup have their own owners and tests.
                function Write-DevelopPublicationAttempt { param($Attempt) }
                function Start-DeliveryStandPrewarm { param($CandidateRoot) $null }
                function Get-DeliveryCanonicalJsonSha256 { param($Value) $Value|ConvertTo-Json -Depth 24 -Compress }
                $preparation=[pscustomobject]@{projectRoot=$seed.project;sourceCommit='candidate';roots=@($seed.branch);requiresWorkflowUpdate=$true
                    capsules=@([pscustomobject]@{phase='Develop';path=$descriptor.path;sha256=$descriptor.sha256;root=$seed.branch;needsAdmission=$false})}
                $attempt=[pscustomobject]@{phase='candidate-built'}
                Invoke-DeliveryStandPreparation $candidate $preparation $attempt
                $attempt.standPreparation.status|Should -Be 'passed'
                @($attempt.standPreparation.steps.name)|Should -Be @('stand-workflow-update','stand-capture-Develop')
                $admission=(Read-QualificationFixtureJson -Path $configPath).qualificationFixtures.Develop.workflowUpdateAdmission
                # The publisher's next plan treats these exact heads as admitted.
                $admission.master.head|Should -Be (Invoke-RepositoryGit -RepositoryRoot $seed.project -Arguments @('rev-parse','HEAD')).stdout.Trim()
                $admission.branch.head|Should -Be (Invoke-RepositoryGit -RepositoryRoot $seed.branch -Arguments @('rev-parse','HEAD')).stdout.Trim()
                @($admission.master.receipts).Count|Should -Be 1
                @($admission.branch.receipts).Count|Should -Be 1
                (Get-FileHash -LiteralPath $descriptor.path -Algorithm SHA256).Hash|Should -Be $descriptor.sha256
                $configSha=(Get-FileHash -LiteralPath $configPath).Hash
                # A later preparation finds nothing to update or admit; Capture
                # then verifies the stored admission instead of rewriting it.
                $preparation.requiresWorkflowUpdate=$false
                $resumed=[pscustomobject]@{phase='candidate-built'}
                Invoke-DeliveryStandPreparation $candidate $preparation $resumed
                @($resumed.standPreparation.steps.name)|Should -Be @('stand-capture-Develop')
                (Get-FileHash -LiteralPath $configPath).Hash|Should -Be $configSha
            }
        } finally {
            Invoke-RepositoryGit -RepositoryRoot $RepoRoot -Arguments @('worktree','remove','--force',$candidate) -AllowFailure|Out-Null
        }
    }

    It 'admits only exact owner receipts and keeps capsule, DT, baseline and semantic workload unchanged' {
        $seed=New-QualificationSeed -Root (Join-Path $TestDrive 'Продолжение Capture with spaces')
        $first=Get-SourceE2EFixtureCapsule -ProjectRoot $seed.project -Phase Develop
        $capsuleSha=(Get-FileHash -LiteralPath $first.path).Hash
        $dt=Join-Path (Split-Path -Parent $first.path) 'infobase.dt';$dtSha=(Get-FileHash -LiteralPath $dt).Hash
        $manifest=Read-QualificationFixtureJson -Path $first.path
        $null=Add-SeedWorkflowUpdate -Root $seed.project -Value one
        $null=Add-SeedWorkflowUpdate -Root $seed.project -Value two
        $null=Add-SeedWorkflowUpdate -Root $seed.branch -Value branch
        {Get-SourceE2EFixtureCapsule -ProjectRoot $seed.project -Phase Develop}|Should -Throw '*FIXTURE_SEED_CHANGED*'
        $continued=Get-SourceE2EFixtureCapsule -ProjectRoot $seed.project -Phase Develop -AcknowledgeWorkflowUpdate
        @($continued.workflowUpdateAdmission.master.receipts).Count|Should -Be 2
        @($continued.workflowUpdateAdmission.branch.receipts).Count|Should -Be 1
        (Get-SourceE2EFixtureCapsule -ProjectRoot $seed.project -Phase Develop).sha256|Should -BeExactly $first.sha256
        $configPath=Join-Path $seed.project '.agent-1c/release-e2e.json'
        $configSha=(Get-FileHash -LiteralPath $configPath).Hash
        foreach($alias in @($seed.project.Replace('\','/'),($seed.project.Replace('\','/')+'/./'))){
            (Get-SourceE2EFixtureCapsule -ProjectRoot $alias -Phase Develop).sha256|Should -BeExactly $first.sha256
            (Get-FileHash -LiteralPath $configPath).Hash|Should -BeExactly $configSha
        }
        (Get-FileHash -LiteralPath $first.path).Hash|Should -BeExactly $capsuleSha
        (Get-FileHash -LiteralPath $dt).Hash|Should -BeExactly $dtSha
        (Read-QualificationFixtureJson -Path $first.path).workflowCommit|Should -BeExactly $manifest.workflowCommit
        Should -Invoke Invoke-SourceFixtureInstalledAction -Times 1 -ParameterFilter {$Action -eq 'release-e2e-snapshot'}
        $null=Add-SeedWorkflowUpdate -Root $seed.project -Value three
        {Get-SourceE2EFixtureCapsule -ProjectRoot $seed.project -Phase Develop}|Should -Throw '*FIXTURE_SEED_CHANGED*'
        {Get-SourceE2EFixtureCapsule -ProjectRoot $seed.project -Phase Develop -AcknowledgeWorkflowUpdate}|Should -Not -Throw
    }

    It 'rejects acknowledgement after <damage> and preserves the old capsule/config' -ForEach @(
        @{damage='foreign-commit'},@{damage='business-in-receipt'},@{damage='backup'},@{damage='receipt'},
        @{damage='environment'},@{damage='database'},@{damage='semantic-state'},@{damage='config'}
    ) {
        $seed=New-QualificationSeed -Root (Join-Path $TestDrive ('Отказ Capture '+$damage))
        $first=Get-SourceE2EFixtureCapsule -ProjectRoot $seed.project -Phase Develop
        $configPath=Join-Path $seed.project '.agent-1c/release-e2e.json'
        $snapshot=Add-SeedWorkflowUpdate -Root $seed.project -Value update -ChangedPath $(if($damage -eq 'business-in-receipt'){'src/cf/invalid.bsl'}else{'AGENT-INSTALL.md'})
        switch($damage){
            'foreign-commit' {Write-Utf8Text -Path (Join-Path $seed.project 'foreign.txt') -Value foreign;Invoke-RepositoryGit -RepositoryRoot $seed.project -Arguments @('add','--','foreign.txt')|Out-Null;Invoke-RepositoryGit -RepositoryRoot $seed.project -Arguments @('commit','-m','foreign')|Out-Null}
            'backup' {[IO.File]::AppendAllText((Join-Path $snapshot 'item-1'),'tamper')}
            'receipt' {$p=Join-Path $snapshot 'transaction.json';$r=Read-QualificationFixtureJson -Path $p;$r.branchRef='refs/heads/foreign';Write-QualificationFixtureJson -Path $p -Value $r}
            'environment' {[IO.File]::AppendAllText((Join-Path $seed.project '.dev.env'),"UNOWNED=changed`n")}
            'database' {Write-Utf8Text -Path (Join-Path $seed.branch '.agent-1c/infobases/negative/1Cv8.1CD') -Value changed}
            'semantic-state' {$p=Join-Path $seed.branch '.agent-1c/dev-branches/negative.json';$s=Read-QualificationFixtureJson -Path $p;$s.eventLogPendingCursor.position=18;Write-QualificationFixtureJson -Path $p -Value $s}
            'config' {$c=Read-QualificationFixtureJson -Path $configPath;$c.devBranchName='foreign';Write-QualificationFixtureJson -Path $configPath -Value $c}
        }
        $before=Read-Utf8Text -Path $configPath
        {Get-SourceE2EFixtureCapsule -ProjectRoot $seed.project -Phase Develop -AcknowledgeWorkflowUpdate}|Should -Throw
        (Read-Utf8Text -Path $configPath)|Should -BeExactly $before
        (Get-FileHash -LiteralPath $first.path).Hash.ToLowerInvariant()|Should -BeExactly $first.sha256
    }

    It 'requires an existing capsule and rejects acknowledgement combined with recapture' {
        $seed=New-QualificationSeed -Root (Join-Path $TestDrive 'Capture options')
        {Get-SourceE2EFixtureCapsule -ProjectRoot $seed.project -Phase Develop -AcknowledgeWorkflowUpdate}|Should -Throw '*FIXTURE_EXISTING_CAPSULE_REQUIRED*'
        {Get-SourceE2EFixtureCapsule -ProjectRoot $seed.project -Phase Develop -AcknowledgeWorkflowUpdate -Recapture}|Should -Throw '*FIXTURE_CAPTURE_OPTIONS_CONFLICT*'
    }

    It 'keeps ordinary Capture strict after acknowledgement when <damage> changes' -ForEach @(
        @{damage='environment'},@{damage='database'},@{damage='cursor'},@{damage='context'},@{damage='receipt-sha'}
    ) {
        $seed=New-QualificationSeed -Root (Join-Path $TestDrive ('Признанный seed '+$damage))
        $statePath=Join-Path $seed.branch '.agent-1c/dev-branches/negative.json'
        $contextPath=Join-Path $seed.branch '.agent-1c/runs/baseline.json'
        Write-Utf8Text -Path $contextPath -Value 'original context'
        $state=Read-QualificationFixtureJson -Path $statePath
        $state|Add-Member -NotePropertyName eventLogBaselinePath -NotePropertyValue $contextPath
        Write-QualificationFixtureJson -Path $statePath -Value $state
        $first=Get-SourceE2EFixtureCapsule -ProjectRoot $seed.project -Phase Develop
        $snapshot=Add-SeedWorkflowUpdate -Root $seed.project -Value update
        $null=Get-SourceE2EFixtureCapsule -ProjectRoot $seed.project -Phase Develop -AcknowledgeWorkflowUpdate
        switch($damage){
            'environment' {[IO.File]::AppendAllText((Join-Path $seed.project '.dev.env'),"UNOWNED=changed`n")}
            'database' {Write-Utf8Text -Path (Join-Path $seed.branch '.agent-1c/infobases/negative/1Cv8.1CD') -Value changed}
            'cursor' {$state.eventLogPendingCursor.position=18;Write-QualificationFixtureJson -Path $statePath -Value $state}
            'context' {Write-Utf8Text -Path $contextPath -Value 'changed context'}
            'receipt-sha' {$p=Join-Path $snapshot 'transaction.json';$r=Read-QualificationFixtureJson -Path $p;$r.updatedAt='tampered';Write-QualificationFixtureJson -Path $p -Value $r}
        }
        {Get-SourceE2EFixtureCapsule -ProjectRoot $seed.project -Phase Develop}|Should -Throw
        (Get-FileHash -LiteralPath $first.path).Hash.ToLowerInvariant()|Should -BeExactly $first.sha256
    }

    It 'preserves the negative pending/cursor/baseline and exact source while excluding foreign refs and runtime ownership' {
        $seed=New-QualificationSeed -Root (Join-Path $TestDrive 'capsule paths')
        $seedBase=Join-Path $seed.branch '.agent-1c/infobases/negative'
        [IO.File]::AppendAllText((Join-Path $seed.project '.dev.env'), ("SOURCE_INFOBASE_PATH=$seedBase`n"), [Text.UTF8Encoding]::new($false))
        $originalState=Read-Utf8Text -Path (Join-Path $seed.branch '.agent-1c/dev-branches/negative.json')
        $originalSource=(Get-FileHash -LiteralPath (Join-Path $seed.branch 'src/cf/invalid.bsl')).Hash
        $fixture=New-SourceE2EFixtureProject -ProjectRoot $seed.project -Phase Develop -CandidateRoot $RepoRoot -ProjectsRoot (Join-Path $TestDrive 'stand with spaces')
        foreach($item in @($seed.project,$seed.branch,$fixture.projectRoot,$fixture.branchRoot)){Assert-SourceFixtureGitClean -Root $item}
        $state=Read-QualificationFixtureJson -Path (Join-Path $fixture.branchRoot '.agent-1c/dev-branches/negative.json')
        $state.pendingMergeOperation|Should -BeExactly 'refresh-dev-branch'
        $state.pendingMergeStage|Should -BeExactly 'merged'
        $state.pendingMergeCommit|Should -BeExactly $seed.pendingCommit
        (Invoke-RepositoryGit -RepositoryRoot $fixture.branchRoot -Arguments @('cat-file','-t',$seed.pendingCommit)).stdout.Trim()|Should -BeExactly 'commit'
        $state.eventLogPendingCursor.position|Should -Be 17
        $state.eventLogPendingCursor.at|Should -BeExactly '2026-10-12T01:02:03.1234567+03:00'
        $state.lastConfigDesignerFingerprint|Should -BeExactly ''
        $state.lastConfigDesignerTreeObjectId|Should -BeExactly ''
        $state.sourceFingerprint|Should -BeExactly ''
        $state.devBranchInfoBasePath.StartsWith($fixture.branchRoot,[StringComparison]::OrdinalIgnoreCase)|Should -BeTrue
        $state.mainWorktreePath|Should -BeExactly $fixture.projectRoot
        @($state.PSObject.Properties.Name)|Should -Not -Contain 'roctupMcpPid'
        @($state.PSObject.Properties.Name)|Should -Not -Contain 'vanessaMcpPort'
        $state.vanessaMcpSafeModeProof|Should -BeNullOrEmpty
        $state.lastVerifiedCommit|Should -BeExactly ''
        $state.launcherRegistered|Should -BeFalse
        $state.verificationStatus|Should -BeExactly 'stale'
        (Get-FileHash -LiteralPath (Join-Path $fixture.branchRoot 'src/cf/invalid.bsl')).Hash|Should -BeExactly $originalSource
        (Read-Utf8Text -Path (Join-Path $seed.branch '.agent-1c/dev-branches/negative.json'))|Should -BeExactly $originalState
        (Invoke-RepositoryGit -RepositoryRoot $fixture.projectRoot -Arguments @('for-each-ref','--format=%(refname)','refs/heads')).stdout|Should -Not -Match '(?m)^refs/heads/unrelated-user-task$'
        $envText=Read-Utf8Text -Path (Join-Path $fixture.branchRoot '.dev.env')
        $envText|Should -Not -Match 'ROCTUP_MCP_PORT|ITL_ACTIVE_PROJECT_ROOT'
        $envText|Should -Match ([regex]::Escape('INFOBASE_PATH='+$state.devBranchInfoBasePath))
        (Read-Utf8Text -Path (Join-Path $fixture.projectRoot '.dev.env')) | Should -Match ([regex]::Escape('SOURCE_INFOBASE_PATH='+$state.devBranchInfoBasePath))
        Should -Invoke Invoke-SourceFixtureInstalledAction -Times 1 -ParameterFilter {$Action -eq 'release-e2e-snapshot'}
        Should -Invoke Invoke-SourceFixtureInstalledAction -Times 1 -ParameterFilter {$Action -eq 'qualification-create-infobase' -and $Arguments[1] -eq 'negative'}
        Should -Invoke Invoke-SourceFixtureInstalledAction -Times 1 -ParameterFilter {$Action -eq 'release-e2e-restore' -and $Arguments -contains '-PreserveReleaseSnapshotApplicationProof'}
        Write-Utf8Text -Path (Join-Path $seedBase '1Cv8.1CD') -Value 'unexpected seed write during fresh close'
        {Get-SourceE2EFixtureCapsule -ProjectRoot $seed.project -Phase Develop} | Should -Throw '*FIXTURE_SEED_CHANGED*'
    }

    It 'copies only the exact normalization receipt from a registered historical worktree and remaps its state reference' {
        $seed=New-QualificationSeed -Root (Join-Path $TestDrive 'historical receipt')
        $historical=Join-Path $TestDrive 'Старый worktree receipt'
        Invoke-RepositoryGit -RepositoryRoot $seed.project -Arguments @('worktree','add','-b','itldev/historical',$historical,'master')|Out-Null
        $receipt=Join-Path $historical '.agent-1c/runs/auto-update/old.result.json'
        Write-QualificationFixtureJson -Path $receipt -Value @{schemaVersion=1;status='passed';updateResult='НеТребуется'}
        $statePath=Join-Path $seed.branch '.agent-1c/dev-branches/negative.json'
        $state=Read-QualificationFixtureJson -Path $statePath
        $state|Add-Member -NotePropertyName lastEnterpriseAutoUpdateResultPath -NotePropertyValue $receipt
        Write-QualificationFixtureJson -Path $statePath -Value $state
        $original=Read-Utf8Text -Path $statePath
        $originalReceipt=Read-Utf8Text -Path $receipt
        $fixture=New-SourceE2EFixtureProject -ProjectRoot $seed.project -Phase Develop -CandidateRoot $RepoRoot -ProjectsRoot (Join-Path $TestDrive 'receipt owned')
        $copiedState=Read-QualificationFixtureJson -Path (Join-Path $fixture.branchRoot '.agent-1c/dev-branches/negative.json')
        $copiedState.lastEnterpriseAutoUpdateResultPath.StartsWith($fixture.branchRoot+'\',[StringComparison]::OrdinalIgnoreCase)|Should -BeTrue
        (Read-Utf8Text -Path $copiedState.lastEnterpriseAutoUpdateResultPath)|Should -BeExactly $originalReceipt
        (Read-Utf8Text -Path $statePath)|Should -BeExactly $original
        (Read-Utf8Text -Path $receipt)|Should -BeExactly $originalReceipt
        (Invoke-RepositoryGit -RepositoryRoot $fixture.projectRoot -Arguments @('for-each-ref','--format=%(refname)','refs/heads')).stdout|Should -Not -Match '(?m)^refs/heads/itldev/historical$'
        Write-QualificationFixtureJson -Path $receipt -Value @{schemaVersion=1;status='failed';updateResult='Изменено'}
        {Get-SourceE2EFixtureCapsule -ProjectRoot $seed.project -Phase Develop}|Should -Throw '*FIXTURE_SEED_CHANGED*'
        Should -Invoke Invoke-SourceFixtureInstalledAction -Times 1 -ParameterFilter {$Action -eq 'release-e2e-snapshot'}
    }

    It 'rejects a receipt outside registered seed worktrees before taking another database snapshot' {
        $seed=New-QualificationSeed -Root (Join-Path $TestDrive 'foreign receipt')
        $foreign=Join-Path $TestDrive 'Чужой проект/.agent-1c/runs/auto-update/old.result.json'
        Write-QualificationFixtureJson -Path $foreign -Value @{schemaVersion=1;status='passed'}
        $statePath=Join-Path $seed.branch '.agent-1c/dev-branches/negative.json'
        $state=Read-QualificationFixtureJson -Path $statePath
        $state|Add-Member -NotePropertyName lastEnterpriseAutoUpdateResultPath -NotePropertyValue $foreign
        Write-QualificationFixtureJson -Path $statePath -Value $state
        {Get-SourceE2EFixtureCapsule -ProjectRoot $seed.project -Phase Develop}|Should -Throw '*FIXTURE_CONTEXT_OUTSIDE_SEED*'
        Should -Invoke Invoke-SourceFixtureInstalledAction -Times 0 -ParameterFilter {$Action -eq 'release-e2e-snapshot'}
        Test-Path -LiteralPath $foreign|Should -BeTrue
    }

    It 'rejects tampered snapshot before creating a target and gives the preserved capsule to its owner' {
        $seed=New-QualificationSeed -Root (Join-Path $TestDrive 'tamper')
        $descriptor=Get-SourceE2EFixtureCapsule -ProjectRoot $seed.project -Phase Develop
        Write-Utf8Text -Path (Join-Path (Split-Path -Parent $descriptor.path) 'infobase.dt') -Value 'tampered'
        {New-SourceE2EFixtureProject -ProjectRoot $seed.project -Phase Develop -CandidateRoot $RepoRoot -ProjectsRoot (Join-Path $TestDrive 'must stay absent')}|Should -Throw '*FIXTURE_ARTIFACT_SHA_MISMATCH*'
        Test-Path -LiteralPath (Join-Path $TestDrive 'must stay absent')|Should -BeFalse
        Should -Invoke Invoke-SourceFixtureInstalledAction -Times 0 -ParameterFilter {$Action -eq 'release-e2e-restore'}
    }

    It 'repeats Develop from the same capsule in a new owned project without capturing another database' {
        $seed=New-QualificationSeed -Root (Join-Path $TestDrive 'repeat')
        $projects=Join-Path $TestDrive 'owned repeated projects'
        $first=New-SourceE2EFixtureProject -ProjectRoot $seed.project -Phase Develop -CandidateRoot $RepoRoot -ProjectsRoot $projects
        # A previous attempt has progressed; the next one must still use the baseline.
        Write-Utf8Text -Path (Join-Path $first.branchRoot 'src/cf/invalid.bsl') -Value 'changed by previous owned attempt'
        $second=New-SourceE2EFixtureProject -ProjectRoot $seed.project -Phase Develop -CandidateRoot $RepoRoot -ProjectsRoot $projects
        $second.projectRoot|Should -Not -Be $first.projectRoot
        $second.capsule.sha256|Should -BeExactly $first.capsule.sha256
        (Read-Utf8Text -Path (Join-Path $second.branchRoot 'src/cf/invalid.bsl'))|Should -BeExactly 'original negative source'
        Should -Invoke Invoke-SourceFixtureInstalledAction -Times 1 -ParameterFilter {$Action -eq 'release-e2e-snapshot'}
        Should -Invoke Invoke-SourceFixtureInstalledAction -Times 2 -ParameterFilter {$Action -eq 'release-e2e-restore'}
    }

    It 'recovers independent Develop targets from exact capsule while missing live seed remains unavailable' {
        $seed=New-QualificationSeed -Root (Join-Path $TestDrive 'sealed recovery seed Пример')
        $descriptor=Get-SourceE2EFixtureCapsule -ProjectRoot $seed.project -Phase Develop
        $manifest=Read-QualificationFixtureCapsule $descriptor.path $descriptor.sha256
        $stateBefore=Read-Utf8Text (Join-Path $seed.branch '.agent-1c/dev-branches/negative.json')
        Remove-Item -LiteralPath $manifest.sourceDatabase.path
        $projects=Join-Path $TestDrive 'sealed recovery targets Пример'
        $options=@{ProjectRoot=$seed.project;Phase='Develop';CandidateRoot=$RepoRoot;ProjectsRoot=$projects}
        {New-SourceE2EFixtureProject @options}|Should -Throw
        Test-Path -LiteralPath $projects|Should -BeFalse
        Should -Invoke Invoke-SourceFixtureInstalledAction -Times 0 -ParameterFilter {$Action -eq 'release-e2e-restore'}
        $options.CapsulePath=$descriptor.path;$options.CapsuleSha256=$descriptor.sha256;$options.DatabaseBudgetBytes=4096L
        $script:fixtureAvailable=0L
        Mock Get-SourceE2EVolumeSpace { [pscustomobject]@{volume='fixture-volume';availableBytes=$script:fixtureAvailable} }
        {New-SourceE2EFixtureProject @options}|Should -Throw '*SOURCE_E2E_SPACE_INSUFFICIENT*same explicit Prepare*CapsulePath*'
        Test-Path -LiteralPath $projects|Should -BeFalse
        $script:fixtureAvailable=1GB
        $first=New-SourceE2EFixtureProject @options
        Write-Utf8Text (Join-Path $first.branchRoot 'src/cf/invalid.bsl') 'retained failed workload'
        $second=New-SourceE2EFixtureProject @options
        $second.projectRoot|Should -Not -Be $first.projectRoot
        $second.claim.status|Should -Be ready
        $second.claim.sourceAdmission|Should -BeExactly 'sealed-capsule'
        $second.claim.databaseBytesBasis|Should -BeExactly 'declared-capacity-budget'
        $second.claim.databaseBytes|Should -Be 4096
        (Read-Utf8Text (Join-Path $second.branchRoot 'src/cf/invalid.bsl'))|Should -BeExactly 'original negative source'
        (Read-Utf8Text (Join-Path $first.branchRoot 'src/cf/invalid.bsl'))|Should -BeExactly 'retained failed workload'
        $restored=Read-QualificationFixtureJson (Join-Path $second.branchRoot '.agent-1c/dev-branches/negative.json')
        $restored.pendingMergeCommit|Should -BeExactly $seed.pendingCommit
        $restored.eventLogPendingCursor.position|Should -Be 17
        (Read-Utf8Text (Join-Path $seed.branch '.agent-1c/dev-branches/negative.json'))|Should -BeExactly $stateBefore
        Test-Path -LiteralPath $manifest.sourceDatabase.path|Should -BeFalse
        (Get-FileHash -LiteralPath $descriptor.path).Hash.ToLowerInvariant()|Should -BeExactly $descriptor.sha256
        Should -Invoke Invoke-SourceFixtureInstalledAction -Times 1 -ParameterFilter {$Action -eq 'release-e2e-snapshot'}
        Should -Invoke Invoke-SourceFixtureInstalledAction -Times 2 -ParameterFilter {$Action -eq 'release-e2e-restore'}
    }

    It 'rejects incomplete recovery inputs, Release, wrong source and altered capsule before materialization' {
        $seed=New-QualificationSeed -Root (Join-Path $TestDrive 'sealed recovery refusals Пример')
        $descriptor=Get-SourceE2EFixtureCapsule -ProjectRoot $seed.project -Phase Develop
        $projects=Join-Path $TestDrive 'recovery must stay absent Пример'
        $options=@{ProjectRoot=$seed.project;Phase='Develop';CandidateRoot=$RepoRoot;ProjectsRoot=$projects;CapsulePath=$descriptor.path;CapsuleSha256=$descriptor.sha256;DatabaseBudgetBytes=4096L}
        foreach($damage in @('missing-sha','missing-budget','tiny-budget','release','wrong-source','wrong-sha')){
            $bad=$options.Clone()
            switch($damage){
                'missing-sha'{$bad.CapsuleSha256=''}
                'missing-budget'{$bad.DatabaseBudgetBytes=0}
                'tiny-budget'{$bad.DatabaseBudgetBytes=1}
                'release'{$bad.Phase='Release'}
                'wrong-source'{$bad.ProjectRoot=Join-Path $TestDrive 'different seed'}
                'wrong-sha'{$bad.CapsuleSha256='0'*64}
            }
            {New-SourceE2EFixtureProject @bad}|Should -Throw
            Test-Path -LiteralPath $projects|Should -BeFalse
        }
        Write-Utf8Text (Join-Path (Split-Path -Parent $descriptor.path) 'infobase.dt') 'tampered snapshot'
        {New-SourceE2EFixtureProject @options}|Should -Throw '*FIXTURE_ARTIFACT_SHA_MISMATCH*'
        Test-Path -LiteralPath $projects|Should -BeFalse
        Should -Invoke Invoke-SourceFixtureInstalledAction -Times 0 -ParameterFilter {$Action -eq 'qualification-create-infobase' -or $Action -eq 'release-e2e-restore'}
    }

    It 'rejects insufficient storage before materialization, then completes the original Prepare after capacity recovers' {
        $seed=New-QualificationSeed -Root (Join-Path $TestDrive 'space recovery Пример')
        $script:fixtureAvailable=0L
        Mock Get-SourceE2EVolumeSpace {param($Path) [pscustomobject]@{volume='fixture-volume';availableBytes=$script:fixtureAvailable}}
        {New-SourceE2EFixtureProject -ProjectRoot $seed.project -Phase Develop -CandidateRoot $RepoRoot -ProjectsRoot (Join-Path $TestDrive 'space target Пример') -AgentTarget kilocode}|Should -Throw '*SOURCE_E2E_SPACE_INSUFFICIENT*ResumePlan*'
        Should -Invoke Invoke-SourceFixtureInstalledAction -Times 0 -ParameterFilter {$Action -eq 'qualification-create-infobase' -or $Action -eq 'release-e2e-restore'}
        $script:fixtureAvailable=1GB
        $fixture=New-SourceE2EFixtureProject -ProjectRoot $seed.project -Phase Develop -CandidateRoot $RepoRoot -ProjectsRoot (Join-Path $TestDrive 'space target Пример') -AgentTarget kilocode
        $fixture.claim.status|Should -BeExactly 'ready'
        $fixture.claim.schemaVersion|Should -Be 2
        $fixture.claim.workflowCommonGit|Should -BeExactly (Get-RepositoryCommonGitDirectory -RepositoryRoot $RepoRoot)
        Should -Invoke Invoke-SourceFixtureInstalledAction -Times 1 -ParameterFilter {$Action -eq 'qualification-create-infobase'}
        Should -Invoke Invoke-SourceFixtureInstalledAction -Times 1 -ParameterFilter {$Action -eq 'release-e2e-restore'}
    }
    It 'rejects an unpublished baseline before the installed snapshot or database owner runs' {
        $seed=New-QualificationSeed -Root (Join-Path $TestDrive 'unpublished baseline')
        foreach($root in @($seed.project,$seed.branch)) {
            $path=Join-Path $root '.agent-1c/dependency-lock.json'
            $lock=Read-QualificationFixtureJson -Path $path
            $lock.dependencies.workflowPackage.commit=('b'*40)
            Write-QualificationFixtureJson -Path $path -Value $lock
        }
        Invoke-RepositoryGit -RepositoryRoot $seed.project -Arguments @('add','--all')|Out-Null
        Invoke-RepositoryGit -RepositoryRoot $seed.project -Arguments @('commit','-m','unpublished seed baseline')|Out-Null
        Invoke-RepositoryGit -RepositoryRoot $seed.branch -Arguments @('add','--all')|Out-Null
        Invoke-RepositoryGit -RepositoryRoot $seed.branch -Arguments @('commit','-m','unpublished branch baseline')|Out-Null
        { Export-SourceE2EFixtureCapsule -ProjectRoot $seed.project -Phase Develop }|Should -Throw '*FIXTURE_BASELINE_NOT_PUBLISHED*'
        Should -Invoke Invoke-SourceFixtureInstalledAction -Times 0
    }

    It 'retains ordinary fork cleanup while qualification restores only its declared unfinished operation' {
        $state=@{pendingMergeOperation='refresh-dev-branch';eventLogPendingCursor=17;roctupMcpPid=123;userField='retained'}
        Remove-DevBranchForkTransientState -State $state|Out-Null
        $state.ContainsKey('pendingMergeOperation')|Should -BeFalse
        $state.ContainsKey('eventLogPendingCursor')|Should -BeFalse
        $state.ContainsKey('roctupMcpPid')|Should -BeFalse
        $state.userField|Should -BeExactly 'retained'
    }

    It 'detects a changed database seed and recaptures through its owner without editing the old capsule' {
        $seed=New-QualificationSeed -Root (Join-Path $TestDrive 'changed database')
        $first=Get-SourceE2EFixtureCapsule -ProjectRoot $seed.project -Phase Develop
        $originalSha=(Get-FileHash -LiteralPath $first.path).Hash
        $state=Read-QualificationFixtureJson -Path (Join-Path $seed.branch '.agent-1c/dev-branches/negative.json')
        Write-Utf8Text -Path (Join-Path $state.devBranchInfoBasePath '1Cv8.1CD') -Value 'declared new database seed'
        {Get-SourceE2EFixtureCapsule -ProjectRoot $seed.project -Phase Develop}|Should -Throw '*FIXTURE_SEED_CHANGED*'
        $second=Get-SourceE2EFixtureCapsule -ProjectRoot $seed.project -Phase Develop -Recapture
        $second.sha256|Should -Not -Be $first.sha256
        $second.path|Should -Not -Be $first.path
        (Get-FileHash -LiteralPath $first.path).Hash|Should -BeExactly $originalSha
        Should -Invoke Invoke-SourceFixtureInstalledAction -Times 2 -ParameterFilter {$Action -eq 'release-e2e-snapshot'}
    }

    It 'continues a failed Release preparation in a new owned target and resumes the completed candidate without another restore' {
        $seed=New-QualificationSeed -Root (Join-Path $TestDrive 'release continuation')
        $longRelative='src/cf/DataProcessors/РегистрацияИзмененийДляОбменаДанными/Forms/УзлыРегистрацииОбъекта/Ext/Form/Items/ДеревоУзловОбменаКонтекстноеМенюИнвертироватьПометкуВсемУзлам/Picture.png'
        $longSeedPath=Join-Path $seed.project $longRelative
        $longSeedPath.Length|Should -BeGreaterThan 260
        [void][IO.Directory]::CreateDirectory(('\\?\'+(Split-Path -Parent $longSeedPath)))
        [IO.File]::WriteAllBytes(('\\?\'+$longSeedPath),[byte[]]@(0,127,255))
        Invoke-RepositoryGit -RepositoryRoot $seed.project -Arguments @('config','core.longpaths','true')|Out-Null
        Invoke-RepositoryGit -RepositoryRoot $seed.project -Arguments @('add','--',$longRelative)|Out-Null
        Invoke-RepositoryGit -RepositoryRoot $seed.project -Arguments @('commit','-m','retain exact long Unicode workload')|Out-Null
        $configPath=Join-Path $seed.project '.agent-1c/release-e2e.json'
        $config=Read-QualificationFixtureJson -Path $configPath
        $config.devBranchName='negative';$config.worktreePath=$seed.branch
        Write-QualificationFixtureJson -Path $configPath -Value $config
        $script:failRestore=$true
        $script:fixtureCandidateCommit=(Invoke-RepositoryGit -RepositoryRoot $RepoRoot -Arguments @('rev-parse','HEAD')).stdout.Trim()
        Mock Invoke-SourceFixtureInstalledAction {
            param($Root,$Action,$Arguments,$AgentTarget,$LogRoot,$TimeoutSeconds)
            switch($Action){
                'release-e2e-snapshot'{$i=[Array]::IndexOf($Arguments,'-ReleaseSnapshotPath');Write-Utf8Text -Path (Join-Path $Root $Arguments[$i+1]) -Value 'synthetic release database'}
                'qualification-create-infobase'{$state=Read-QualificationFixtureJson -Path (Join-Path $Root ('.agent-1c/dev-branches/'+$Arguments[1]+'.json'));Write-Utf8Text -Path (Join-Path $state.devBranchInfoBasePath '1Cv8.1CD') -Value 'synthetic native create result'}
                'release-e2e-restore'{{Open-SourceE2EFixtureUse -ProjectRoot (Join-Path (Split-Path -Parent $Root) 'project')}|Should -Throw '*FIXTURE_COPY_IN_USE*';if($script:failRestore){$script:failRestore=$false;throw 'original restore failure; target retained'}}
                'update-workflow'{Write-Utf8Text -Path (Join-Path $Root '.agent-1c/dependency-lock.json') -Value ('{"dependencies":{"workflowPackage":{"commit":"'+$script:fixtureCandidateCommit+'"}}}')}
                'refresh-dev-branch'{throw 'Full refresh requires a source database absent from this sealed fixture; preserve the native reproducer.'}
                'refresh-dev-branch-lite'{
                    $i=[Array]::IndexOf($Arguments,'-ExpectedMasterCommit')
                    Invoke-RepositoryGit -RepositoryRoot $Root -Arguments @('merge','--ff-only',$Arguments[$i+1])|Out-Null
                }
                default{throw "Unexpected action $Action"}
            }
            $stdout='mock'
            if($Action -eq 'update-workflow'){
                $stdout=Join-Path $LogRoot 'update-workflow.mock.stdout.log'
                Write-Utf8Text -Path $stdout -Value '{"action":"update-workflow","status":"succeeded"}'
            }
            return [pscustomobject]@{exitCode=0;stdout=$stdout;stderr='mock';durationMs=12}
        }
        $receipt=Join-Path $TestDrive 'release-fixture.json'
        $options=@{ProjectRoot=$seed.project;Phase='Release';CandidateRoot=$RepoRoot;ProjectsRoot=(Join-Path $TestDrive 'release owned projects');AiRulesSource=$RepoRoot;ReceiptPath=$receipt}
        {New-SourceE2EFixtureProject @options}|Should -Throw '*original restore failure*'
        $failed=Read-QualificationFixtureJson -Path $receipt
        $failed.claim.status|Should -BeExactly 'preparation-failed'
        $failed.claim.preparationFailure.error|Should -BeExactly 'original restore failure; target retained'
        $ready=New-SourceE2EFixtureProject @options
        Write-QualificationFixtureJson -Path $receipt -Value $ready
        $ready.projectRoot|Should -Not -Be $failed.projectRoot
        Test-Path -LiteralPath $failed.projectRoot -PathType Container|Should -BeTrue
        $ready.claim.status|Should -BeExactly 'ready'
        @($ready.claim.PSObject.Properties.Name)|Should -Not -Contain 'sourceAdmission'
        @($ready.claim.PSObject.Properties.Name)|Should -Not -Contain 'databaseBytesBasis'
        (Invoke-RepositoryGit -RepositoryRoot $ready.projectRoot -Arguments @('config','--local','--get','core.longpaths')).stdout.Trim()|Should -BeExactly 'true'
        [Convert]::ToBase64String([IO.File]::ReadAllBytes(('\\?\'+(Join-Path $ready.branchRoot $longRelative))))|Should -BeExactly 'AH//'
        (Invoke-RepositoryGit -RepositoryRoot $ready.branchRoot -Arguments @('show','HEAD:src/cf/invalid.bsl')).stdout.Trim()|Should -BeExactly 'original negative source'
        Test-Path -LiteralPath (Join-Path $ready.projectRoot '.agent-1c/infobases/source-snapshot')|Should -BeFalse
        $installed=Read-QualificationFixtureJson -Path (Join-Path $ready.branchRoot '.agent-1c/dependency-lock.json')
        $installed.dependencies.workflowPackage.commit|Should -BeExactly $script:fixtureCandidateCommit
        $continued=New-SourceE2EFixtureProject @options
        $continued.execution|Should -BeExactly 'continued'
        $continued.projectRoot|Should -BeExactly $ready.projectRoot
        Should -Invoke Invoke-SourceFixtureInstalledAction -Times 1 -ParameterFilter {$Action -eq 'release-e2e-snapshot'}
        Should -Invoke Invoke-SourceFixtureInstalledAction -Times 2 -ParameterFilter {$Action -eq 'release-e2e-restore'}
        Should -Invoke Invoke-SourceFixtureInstalledAction -Times 1 -ParameterFilter {$Action -eq 'update-workflow'}
        Should -Invoke Invoke-SourceFixtureInstalledAction -Times 0 -ParameterFilter {$Action -eq 'refresh-dev-branch'}
        Should -Invoke Invoke-SourceFixtureInstalledAction -Times 1 -ParameterFilter {$Action -eq 'refresh-dev-branch-lite' -and '-ExpectedMasterCommit' -in $Arguments}
    }

    It 'rejects path escape and writes no state into an unclaimed target' {
        {Resolve-QualificationFixtureChild -Root $TestDrive -RelativePath '../foreign.json'}|Should -Throw '*FIXTURE_PATH_ESCAPE*'
        $seed=New-QualificationSeed -Root (Join-Path $TestDrive 'ownership')
        $descriptor=Get-SourceE2EFixtureCapsule -ProjectRoot $seed.project -Phase Develop
        $target=Join-Path $TestDrive 'unclaimed';$branch=Join-Path $TestDrive 'foreign branch'
        {Install-QualificationFixtureContext -ManifestPath $descriptor.path -Sha256 $descriptor.sha256 -TargetProjectRoot $target -TargetBranchRoot $branch}|Should -Throw
        Test-Path -LiteralPath $branch|Should -BeFalse
    }
}

Describe 'Qualification native child transport' {
    It 'retains locked output with an owner continuation and completes the same read after the writer releases it' {
        $path=Join-Path $TestDrive ('output '+[char]0x041F+' with spaces.txt')
        $value=[string][char]0x041F+[char]0x0440+[char]0x0438+[char]0x0432+[char]0x0435+[char]0x0442
        $bytes=[Text.UTF8Encoding]::new($false).GetBytes($value)
        $writer=[IO.File]::Open($path,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::Read)
        try {
            $writer.Write($bytes,0,$bytes.Length)
            $timer=[Diagnostics.Stopwatch]::StartNew()
            {Complete-NativeRedirectedOutput -Paths @($path) -TimeoutSeconds 1}|Should -Throw '*NATIVE_PROCESS_OUTPUT_NOT_RELEASED*repeat the original operation*'
            $timer.Elapsed.TotalSeconds|Should -BeLessThan 5
            Test-Path -LiteralPath $path|Should -BeTrue
        } finally {$writer.Dispose()}
        Complete-NativeRedirectedOutput -Paths @($path)
        (Read-Utf8Text -Path $path)|Should -BeExactly $value
    }

    It 'returns complete Unicode stdout and stderr from the actual shared native owner through <entry> after a failing child exits' -ForEach @(@{entry='installed'},@{entry='source'}) {
        $root=Join-Path $TestDrive ('native owner '+[char]0x041F+' with spaces')
        [void][IO.Directory]::CreateDirectory($root)
        $child=Join-Path $root 'burst child.ps1'
        $body=@'
$u=[Text.UTF8Encoding]::new($false);[Console]::OutputEncoding=$u;$OutputEncoding=$u
$payload=([string][char]0x041F+[char]0x0440+'x')*8192
[Console]::Out.WriteLine($payload+':stdout')
[Console]::Error.WriteLine($payload+':stderr')
exit 23
'@
        [IO.File]::WriteAllText($child,$body,[Text.UTF8Encoding]::new($true))
        $helper=Join-Path $RepoRoot '.agents/skills/1c-workflow/scripts/agent-1c.ps1'
        $observed=& {
            if($entry -eq 'installed'){
                . $helper -ProjectRoot $root -Action help *> $null
            }else{
                $probe=Join-Path $root 'source probe.ps1';$receipt=Join-Path $root 'source result.json'
                $probeBody=@'
param($RepositoryRoot,$Root,$ChildPath,$ResultPath)
$ErrorActionPreference='Stop'
. (Join-Path $RepositoryRoot 'scripts/source-e2e-create-infobase.ps1')
Initialize-SourceQualificationNativeContext -Root $Root
$stdout=Join-Path $Root 'stdout.txt';$stderr=Join-Path $Root 'stderr.txt'
$result=Invoke-NativeProcessAndWaitResult -FilePath (Join-Path $PSHOME 'powershell.exe') -Arguments @('-NoProfile','-File',$ChildPath) -TimeoutSeconds 30 -StdoutPath $stdout -StderrPath $stderr
Write-QualificationFixtureJson -Path $ResultPath -Value @{exitCode=$result.exitCode;stdout=(Read-Utf8Text -Path $stdout);stderr=(Read-Utf8Text -Path $stderr)}
'@
                [IO.File]::WriteAllText($probe,$probeBody,[Text.UTF8Encoding]::new($true))
                & (Join-Path $PSHOME 'powershell.exe') -NoProfile -File $probe -RepositoryRoot $RepoRoot -Root $root -ChildPath $child -ResultPath $receipt *> $null
                if($LASTEXITCODE -ne 0){throw 'Standalone source native probe failed'}
                return (Read-QualificationFixtureJson -Path $receipt)
            }
            $stdout=Join-Path $root 'stdout.txt';$stderr=Join-Path $root 'stderr.txt'
            $result=Invoke-NativeProcessAndWaitResult -FilePath (Join-Path $PSHOME 'powershell.exe') -Arguments @('-NoProfile','-File',$child) -TimeoutSeconds 30 -StdoutPath $stdout -StderrPath $stderr
            [pscustomobject]@{exitCode=$result.exitCode;stdout=(Read-Utf8Text -Path $stdout);stderr=(Read-Utf8Text -Path $stderr)}
        }
        $payload=([string][char]0x041F+[char]0x0440+'x')*8192
        $observed.exitCode|Should -Be 23
        $observed.stdout|Should -BeExactly ($payload+':stdout'+[Environment]::NewLine)
        $observed.stderr|Should -BeExactly ($payload+':stderr'+[Environment]::NewLine)
    }

    It 'retains the actual <action> child exit and exact Unicode arguments/stdout/stderr at its public entrypoint' -ForEach @(
        @{action='release-e2e-restore';relative='.agents/skills/1c-workflow/scripts/agent-1c.ps1';internalAction=$true},
        @{action='update-workflow';relative='.agents/skills/1c-workflow/scripts/run-itl-command.ps1';internalAction=$false}
    ) {
        $root=Join-Path $TestDrive ('transport '+[char]0x041F+[char]0x0443+[char]0x0442+[char]0x044C+' '+$action)
        $runner=Join-Path $root $relative
        Write-Utf8Text -Path (Join-Path $root '.agent-1c/project.json') -Value '{"aiRules":{"tools":["kilocode"]}}'
        $unicode=[string][char]0x041F+[char]0x0440+[char]0x0438+[char]0x0432+[char]0x0435+[char]0x0442
        $body=@'
$u=[Text.UTF8Encoding]::new($false);[Console]::OutputEncoding=$u;$OutputEncoding=$u
Write-Output (ConvertTo-Json -InputObject @($args) -Compress)
[Console]::Error.WriteLine('UNICODE_PLACEHOLDER')
exit 23
'@
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $runner))
        [IO.File]::WriteAllText($runner,$body.Replace('UNICODE_PLACEHOLDER',$unicode),[Text.UTF8Encoding]::new($true))
        $logs=Join-Path $root 'logs'
        $argument=$unicode+' path "quoted" \'
        {Invoke-SourceFixtureInstalledAction -Root $root -Action $action -Arguments @('-Marker',$argument) -LogRoot $logs -TimeoutSeconds 30}|Should -Throw '*exit=23*'
        $stdout=@(Get-ChildItem -LiteralPath $logs -Filter '*.stdout.log' -File)
        $stderr=@(Get-ChildItem -LiteralPath $logs -Filter '*.stderr.log' -File)
        $stdout.Count|Should -Be 1;$stderr.Count|Should -Be 1
        $argv=ConvertFrom-DeliveryProofJson -Json (Read-Utf8Text -Path $stdout[0].FullName)
        $argv[[Array]::IndexOf($argv,'-Marker')+1]|Should -BeExactly $argument
        $argv[[Array]::IndexOf($argv,'-Action')+1]|Should -BeExactly $action
        if($internalAction){$argv[[Array]::IndexOf($argv,'-ProjectRoot')+1]|Should -BeExactly $root}
        else{$argv[0]|Should -BeExactly '--';$argv|Should -Not -Contain '-ProjectRoot'}
        (Read-Utf8Text -Path $stderr[0].FullName).Trim()|Should -BeExactly $unicode
    }
}

Describe 'Stable qualification factory action dispatch' {
    BeforeEach {
        Mock Invoke-SourceFixtureRefresh { [pscustomobject]@{route='guarded-refresh'} }
        Mock Invoke-SourceFixtureInstalledProcess { [pscustomobject]@{route='native-process'} }
        $script:expectedCommit='a'*40
    }

    It 'routes the unchanged <Action> factory call through the shared continuation' -ForEach @(
        @{Action='refresh-dev-branch'},@{Action='refresh-dev-branch-lite'}
    ) {
        $root=Join-Path $TestDrive 'factory branch'
        $logs=Join-Path $TestDrive 'retained logs'
        $script:dispatchExpectedRoot=$root
        $script:dispatchExpectedLogs=$logs
        $script:dispatchExpectedAction=$Action
        $result=Invoke-SourceFixtureInstalledAction -Root $root -Action $Action -Arguments @('-DevBranchName','fixture','-ExpectedMasterCommit',$script:expectedCommit) -AgentTarget kilocode -LogRoot $logs -TimeoutSeconds 5400
        $result.route|Should -BeExactly 'guarded-refresh'
        Should -Invoke Invoke-SourceFixtureRefresh -Times 1 -Exactly -ParameterFilter {
            $Root -ceq $script:dispatchExpectedRoot -and $BranchName -ceq 'fixture' -and $ExpectedMasterCommit -ceq $script:expectedCommit -and
            $Action -ceq $script:dispatchExpectedAction -and $AgentTarget -ceq 'kilocode' -and $LogRoot -ceq $script:dispatchExpectedLogs
        }
        Should -Invoke Invoke-SourceFixtureInstalledProcess -Times 0 -Exactly
    }

    It 'sends the continuation child directly to the native process without recursive routing' {
        $expectedArguments=@('-DevBranchName','fixture','-ExpectedMasterCommit',$script:expectedCommit)
        $result=Invoke-SourceFixtureInstalledAction -Root $TestDrive -Action refresh-dev-branch-lite -Arguments $expectedArguments -LogRoot $TestDrive -TimeoutSeconds 5400 -AllowFailure
        $result.route|Should -BeExactly 'native-process'
        Should -Invoke Invoke-SourceFixtureRefresh -Times 0 -Exactly
        Should -Invoke Invoke-SourceFixtureInstalledProcess -Times 1 -Exactly -ParameterFilter {
            $Action -ceq 'refresh-dev-branch-lite' -and $AllowFailure -and $TimeoutSeconds -eq 5400 -and
            ($Arguments -join '|') -ceq ('-DevBranchName|fixture|-ExpectedMasterCommit|'+$script:expectedCommit)
        }
    }

    It 'preserves ordinary dispatch for unsupported <Case> instead of acquiring repair authority' -ForEach @(
        @{Case='other action';Action='release-e2e-restore';Arguments=@('-DevBranchName','fixture','-ExpectedMasterCommit',('a'*40));Seconds=5400},
        @{Case='extra option';Action='refresh-dev-branch-lite';Arguments=@('-DevBranchName','fixture','-ExpectedMasterCommit',('a'*40),'-ConfigLoadMode','Full');Seconds=5400},
        @{Case='another budget';Action='refresh-dev-branch-lite';Arguments=@('-DevBranchName','fixture','-ExpectedMasterCommit',('a'*40));Seconds=7200},
        @{Case='missing target';Action='refresh-dev-branch-lite';Arguments=@('-DevBranchName','fixture');Seconds=5400},
        @{Case='invalid target';Action='refresh-dev-branch-lite';Arguments=@('-DevBranchName','fixture','-ExpectedMasterCommit','not-a-commit');Seconds=5400}
    ) {
        $result=Invoke-SourceFixtureInstalledAction -Root $TestDrive -Action $Action -Arguments $Arguments -LogRoot $TestDrive -TimeoutSeconds $Seconds
        $result.route|Should -BeExactly 'native-process'
        Should -Invoke Invoke-SourceFixtureRefresh -Times 0 -Exactly
        Should -Invoke Invoke-SourceFixtureInstalledProcess -Times 1 -Exactly
    }
}
