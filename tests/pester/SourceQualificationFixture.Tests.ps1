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
        $published=(Invoke-RepositoryGit -RepositoryRoot $RepoRoot -Arguments @('rev-parse','refs/remotes/origin/develop')).stdout.Trim()
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
    It 'rejects a successful launcher without an actual database file' {
        Mock Invoke-NativeProcessAndWaitResult {[pscustomobject]@{timedOut=$false;exitCode=0}}
        {New-SourceQualificationInfoBase -BranchRoot $script:createBranch -BranchName negative -PlatformPath unused}|Should -Throw '*FIXTURE_CREATE_FAILED*'
    }
    It 'rejects a foreign state path before guard admission' {
        Write-QualificationFixtureJson -Path (Join-Path $script:createBranch '.agent-1c/dev-branches/negative.json') -Value @{infoBaseKind='file';devBranchName='negative';devBranchInfoBasePath=(Join-Path $TestDrive 'foreign')}
        {New-SourceQualificationInfoBase -BranchRoot $script:createBranch -BranchName negative -PlatformPath unused}|Should -Throw '*FIXTURE_CREATE_TARGET_INVALID*'
        Should -Invoke Invoke-WithOneCSessionAdmissionContext -Times 0
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

    It 'preserves the negative pending/cursor/baseline and exact source while excluding foreign refs and runtime ownership' {
        $seed=New-QualificationSeed -Root (Join-Path $TestDrive 'capsule paths')
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
        Should -Invoke Invoke-SourceFixtureInstalledAction -Times 1 -ParameterFilter {$Action -eq 'release-e2e-snapshot'}
        Should -Invoke Invoke-SourceFixtureInstalledAction -Times 1 -ParameterFilter {$Action -eq 'qualification-create-infobase' -and $Arguments[1] -eq 'negative'}
        Should -Invoke Invoke-SourceFixtureInstalledAction -Times 1 -ParameterFilter {$Action -eq 'release-e2e-restore' -and $Arguments -contains '-PreserveReleaseSnapshotApplicationProof'}
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
                'release-e2e-restore'{if($script:failRestore){$script:failRestore=$false;throw 'original restore failure; target retained'}}
                'update-workflow'{Write-Utf8Text -Path (Join-Path $Root '.agent-1c/dependency-lock.json') -Value ('{"dependencies":{"workflowPackage":{"commit":"'+$script:fixtureCandidateCommit+'"}}}')}
                'refresh-dev-branch'{
                    $i=[Array]::IndexOf($Arguments,'-ExpectedMasterCommit')
                    Invoke-RepositoryGit -RepositoryRoot $Root -Arguments @('merge','--ff-only',$Arguments[$i+1])|Out-Null
                }
                default{throw "Unexpected action $Action"}
            }
            return [pscustomobject]@{stdout='mock';stderr='mock';durationMs=12}
        }
        $receipt=Join-Path $TestDrive 'release-fixture.json'
        $options=@{ProjectRoot=$seed.project;Phase='Release';CandidateRoot=$RepoRoot;ProjectsRoot=(Join-Path $TestDrive 'release owned projects');AiRulesSource=$RepoRoot;ReceiptPath=$receipt}
        {New-SourceE2EFixtureProject @options}|Should -Throw '*original restore failure*'
        $failed=Read-QualificationFixtureJson -Path $receipt
        $failed.claim.status|Should -BeExactly 'materializing'
        $ready=New-SourceE2EFixtureProject @options
        Write-QualificationFixtureJson -Path $receipt -Value $ready
        $ready.projectRoot|Should -Not -Be $failed.projectRoot
        Test-Path -LiteralPath $failed.projectRoot -PathType Container|Should -BeTrue
        $ready.claim.status|Should -BeExactly 'ready'
        $installed=Read-QualificationFixtureJson -Path (Join-Path $ready.branchRoot '.agent-1c/dependency-lock.json')
        $installed.dependencies.workflowPackage.commit|Should -BeExactly $script:fixtureCandidateCommit
        $continued=New-SourceE2EFixtureProject @options
        $continued.execution|Should -BeExactly 'continued'
        $continued.projectRoot|Should -BeExactly $ready.projectRoot
        Should -Invoke Invoke-SourceFixtureInstalledAction -Times 1 -ParameterFilter {$Action -eq 'release-e2e-snapshot'}
        Should -Invoke Invoke-SourceFixtureInstalledAction -Times 2 -ParameterFilter {$Action -eq 'release-e2e-restore'}
        Should -Invoke Invoke-SourceFixtureInstalledAction -Times 1 -ParameterFilter {$Action -eq 'update-workflow'}
        Should -Invoke Invoke-SourceFixtureInstalledAction -Times 1 -ParameterFilter {$Action -eq 'refresh-dev-branch'}
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
                . (Join-Path $RepoRoot 'scripts/source-e2e-create-infobase.ps1')
                $script:ProjectRoot=$root
                $script:OneCSessionLaunchContext=$null
                $script:OneCNativeOperationJournal=New-OneCNativeOperationJournal -Resources @()
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
