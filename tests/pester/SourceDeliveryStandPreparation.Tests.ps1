BeforeAll {
    . (Join-Path $PSScriptRoot 'SourceDeliveryPlan.TestSupport.ps1')
    . (Join-Path $RepoRoot 'scripts/source-delivery-process.ps1')
    . (Join-Path $RepoRoot 'scripts/source-delivery-release-recovery.ps1')
    function Import-StandTestOwner {
        param([string]$Path,[string[]]$Names)
        $tokens=$null;$errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot $Path),[ref]$tokens,[ref]$errors)
        if ($errors.Count) { throw 'Owner must parse' }
        foreach ($name in $Names) {
            $node=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true))[0]
            . ([scriptblock]::Create($node.Extent.Text.Replace('function '+$name+' {','function script:'+$name+' {')))
        }
        return $ast
    }
    $null=Import-StandTestOwner '.agents/skills/1c-workflow/scripts/lib/agent-1c.core.ps1' @('Get-ConfigValueFromObject','Get-Utf8Encoding','Read-Utf8Text','Write-Utf8TextAtomic')
    $null=Import-StandTestOwner '.agents/skills/1c-workflow/scripts/lib/agent-1c.lifecycle.ps1' @('Resolve-WorkflowUpdateRolloutScope','Invoke-WorkflowDevelopmentBranchRollout','Assert-WorkflowDevelopmentBranchRolloutComplete')
    $null=Import-StandTestOwner 'scripts/source-delivery-component.ps1' @('ConvertTo-DeliveryNativeArgument')
    $null=Import-StandTestOwner 'scripts/source-delivery-cleanup.ps1' @('Invoke-PublishDevelopWithCleanup','Add-DeliveryCleanupResults')
    $script:publisherAst=Import-StandTestOwner 'scripts/source-delivery-candidate.ps1' @()
    $script:prepareDecision=@($script:publisherAst.FindAll({param($n)
        $n -is [Management.Automation.Language.IfStatementAst] -and $n.Extent.Text -match '^if \(-not \$frozenPlan -and'
    },$true) | Where-Object { $_.Extent.Text -match 'Invoke-DeliveryStandPreparation' })[0]
    function Write-DevelopPublicationAttempt { param($Attempt) $script:savedAttempt=$Attempt | ConvertTo-Json -Depth 32 | ConvertFrom-Json }
}

Describe 'Frozen resume does not repeat completed best-effort garbage collection' {
    BeforeEach {
        $script:ResumePlan='frozen';$script:cleanupCalls=@()
        $script:cleanupCheckpoint=[pscustomobject]@{planId='frozen';preOperationCleanup=[pscustomobject]@{status='completed'}}
        function Read-DevelopPublicationAttempt { $script:cleanupCheckpoint }
        function Invoke-DeliveryChannelCleanupSafely { param($Channel,$Phase,$ExpectedCommit) $script:cleanupCalls+=@($Phase);[pscustomobject]@{status='completed';phase=$Phase} }
        function Publish-DevelopDeferringFailingEntries { [pscustomobject]@{commit='candidate'} }
    }
    It 'reuses only garbage collection while retaining publication and final cleanup' {
        $result=Invoke-PublishDevelopWithCleanup
        $result.commit | Should -Be 'candidate'
        $result.cleanupRuns[0].status | Should -Be 'reused'
        $script:cleanupCalls | Should -Be @('post-operation')
    }
    It 'runs cleanup again for a new plan, legacy checkpoint or incomplete earlier cleanup' {
        foreach($case in @('changed','legacy','warning')) {
            $script:cleanupCalls=@()
            $script:cleanupCheckpoint=[pscustomobject]@{planId='frozen';preOperationCleanup=[pscustomobject]@{status='completed'}}
            if($case -eq 'changed'){$script:cleanupCheckpoint.planId='different'}
            if($case -eq 'legacy'){$script:cleanupCheckpoint.PSObject.Properties.Remove('preOperationCleanup')}
            if($case -eq 'warning'){$script:cleanupCheckpoint.preOperationCleanup.status='completed-with-warnings'}
            Invoke-PublishDevelopWithCleanup | Out-Null
            $script:cleanupCalls | Should -Be @('pre-operation','post-operation')
        }
    }
}

Describe 'Selected workflow rollout remains with the lifecycle owner' {
    BeforeEach {
        $script:ProjectRoot=Join-Path $TestDrive 'master'
        $script:selectedRoot=Join-Path $TestDrive 'selected'
        $script:otherRoot=Join-Path $TestDrive 'other'
        @($script:ProjectRoot,$script:selectedRoot,$script:otherRoot) | ForEach-Object { [void][IO.Directory]::CreateDirectory($_) }
        $script:selectionScope=[pscustomobject]@{schemaVersion=1;projectRoot=$script:ProjectRoot;sourceCommit='exact';roots=@($script:selectedRoot)}
        function Get-GitWorktrees { @(@{path=$script:ProjectRoot;branch='master'},@{path=$script:selectedRoot;branch='itldev/selected'},@{path=$script:otherRoot;branch='itldev/other'}) }
        function Get-WorkflowUpdateWorktreeInventory {
            param($TargetCommit,[string[]]$SelectedRoot=@())
            $script:inspectedRoots=@($SelectedRoot)
            foreach($root in @($script:selectedRoot,$script:otherRoot)) {
                if ($SelectedRoot -and $root -notin $SelectedRoot) { continue }
                [pscustomobject]@{kind='development';root=$root;branch=('itldev/'+(Split-Path -Leaf $root));eligibility='eligible';reason='';continuation='';conflictPaths=@();installedWorkflowCommit='old';head='old'}
            }
        }
        function Get-Agent1cLifecycleLockPath { param($WorktreePath) Join-Path $WorktreePath '.agent-1c/locks/lifecycle.lock' }
        function Ensure-Agent1cLifecycleLocksIgnored {}
        function Wait-Agent1cLockSet { [pscustomobject]@{handles=@()} }
        function Get-WorkflowUpdateRootRuntimeBusyReason { '' }
        function Invoke-InProjectContext { param($Root,$ScriptBlock) $script:updatedRoots+=@($Root); [pscustomobject]@{status='completed';commit='updated'} }
        function Get-WorkflowUpdateBranchContinuation { '' }
        function Get-WorkflowDependencySelectionInput { $null }
        $script:updatedRoots=@()
    }
    It 'updates only selected roots and rejects that report as proof of a full rollout' {
        $source=[pscustomobject]@{root='payload';commit='exact';rolloutScope=$script:selectionScope}
        $report=Invoke-WorkflowDevelopmentBranchRollout $source
        $script:updatedRoots | Should -Be @($script:selectedRoot)
        $script:inspectedRoots | Should -Be @($script:selectedRoot)
        $report.roots.root | Should -Be $script:selectedRoot
        { Assert-WorkflowDevelopmentBranchRolloutComplete exact -RolloutScope $script:selectionScope } | Should -Not -Throw
        { Assert-WorkflowDevelopmentBranchRolloutComplete exact } | Should -Throw '*SCOPE_MISMATCH*'
        $script:updatedRoots=@()
        Invoke-WorkflowDevelopmentBranchRollout ([pscustomobject]@{root='payload';commit='exact'}) | Out-Null
        $script:updatedRoots | Should -Be @($script:selectedRoot,$script:otherRoot)
        { Assert-WorkflowDevelopmentBranchRolloutComplete exact } | Should -Not -Throw
    }
    It 'resumes the recorded scope without a mutable input file and rejects expansion or source drift' {
        $file=Join-Path $TestDrive 'scope.json'
        $script:selectionScope | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $file -Encoding UTF8
        $saved=Resolve-WorkflowUpdateRolloutScope exact -InputFile $file
        (Resolve-WorkflowUpdateRolloutScope exact -RecordedScope $saved).roots | Should -Be @($script:selectedRoot)
        $script:selectionScope.roots+=@($script:otherRoot)
        $script:selectionScope | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $file -Encoding UTF8
        { Resolve-WorkflowUpdateRolloutScope exact -RecordedScope $saved -InputFile $file } | Should -Throw '*SCOPE_CHANGED*'
        { Resolve-WorkflowUpdateRolloutScope changed -RecordedScope $saved } | Should -Throw '*IDENTITY_MISMATCH*'
    }
    It 'rejects foreign, absent, duplicate and non-development roots before a writer is called' {
        foreach($roots in @(@($script:ProjectRoot),@((Join-Path $TestDrive 'missing')),@($script:selectedRoot,$script:selectedRoot))) {
            $script:selectionScope.roots=$roots
            { Resolve-WorkflowUpdateRolloutScope exact -RecordedScope $script:selectionScope } | Should -Throw '*WORKFLOW_UPDATE_SCOPE_*'
        }
        $script:updatedRoots | Should -BeNullOrEmpty
    }
}

Describe 'Read-only stand requirements use the checker fixture closure' {
    It 'selects both capsule branches, excludes context references and detects admission drift without writing' {
        $script:DeliveryCustomGateBoundary=$false
        $seed=Join-Path $TestDrive 'inventory seed'
        [void][IO.Directory]::CreateDirectory((Join-Path $seed '.agent-1c'))
        & git -C $seed init -q -b master
        & git -C $seed -c user.name=Fixture -c user.email=fixture@example.invalid commit --allow-empty -qm baseline
        $LASTEXITCODE | Should -Be 0
        $head=(& git -C $seed rev-parse HEAD).Trim()
        $branches=@()
        foreach($name in @('develop','release','context-only')) {
            $branch=Join-Path $TestDrive ('inventory '+$name)
            & git -C $seed worktree add -q -b ('itldev/'+$name) $branch
            $LASTEXITCODE | Should -Be 0
            [void][IO.Directory]::CreateDirectory((Join-Path $branch '.agent-1c'))
            $branches+=@($branch)
        }
        $config=[ordered]@{developWorktreePath=$branches[0];worktreePath=$branches[1];readOnlyReceiptReference=$branches[2];qualificationFixtures=[ordered]@{}}
        foreach($phase in @('Develop','Release')) {
            $branch=if($phase -eq 'Develop'){$branches[0]}else{$branches[1]}
            $path=Join-Path $seed ($phase+'.capsule.json')
            [ordered]@{sourceBranchRoot=$branch;masterCommit=$head;branchCommit=$head} | ConvertTo-Json | Set-Content -LiteralPath $path -Encoding UTF8
            $config.qualificationFixtures[$phase]=[ordered]@{path=$path;sha256=(Get-FileHash $path).Hash}
        }
        $configPath=Join-Path $seed '.agent-1c/release-e2e.json'
        $config | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $configPath -Encoding UTF8
        foreach($root in @($seed)+$branches) {
            '{"dependencies":{"workflowPackage":{"commit":"old"}}}' | Set-Content -LiteralPath (Join-Path $root '.agent-1c/dependency-lock.json') -Encoding UTF8
        }
        $script:E2EProjectRoot=$seed
        $before=(Get-FileHash $configPath).Hash
        function Invoke-WorktreeGit { param($Root,$Arguments,[switch]$AllowFailure) Invoke-RepositoryGit -RepositoryRoot $Root -Arguments $Arguments -AllowFailure:$AllowFailure }
        $requirements=Get-DeliveryStandPreparation -CandidateRoot $RepoRoot -BaseCommit HEAD
        $requirements.roots | Should -Be (@($branches[0],$branches[1]) | Sort-Object)
        $requirements.roots | Should -Not -Contain $branches[2]
        $requirements.requiresWorkflowUpdate | Should -BeTrue
        $requirements.capsules.phase | Should -Be @('Release','Develop')
        $candidate=(& git -C $RepoRoot rev-parse HEAD).Trim()
        foreach($root in @($seed)+$branches[0..1]) {
            @{dependencies=@{workflowPackage=@{commit=$candidate}}} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $root '.agent-1c/dependency-lock.json') -Encoding UTF8
        }
        $requirements=Get-DeliveryStandPreparation -CandidateRoot $RepoRoot -BaseCommit HEAD
        $requirements.requiresStateChange | Should -BeFalse
        & git -C $branches[0] -c user.name=Fixture -c user.email=fixture@example.invalid commit --allow-empty -qm drift
        $LASTEXITCODE | Should -Be 0
        $requirements=Get-DeliveryStandPreparation -CandidateRoot $RepoRoot -BaseCommit HEAD
        $requirements.requiresStateChange | Should -BeTrue
        $requirements.requiresWorkflowUpdate | Should -BeFalse
        (Get-FileHash $configPath).Hash | Should -Be $before
        $script:E2EProjectRoot=$null
    }
}

Describe 'A compatibility promotion does not make the stand stale' {
    It 'maps only a compatibility-only promotion to its unpromoted candidate' {
        $repo=Join-Path $TestDrive ('promotion путь '+[guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory((Join-Path $repo 'templates'))
        & git -C $repo init -q
        $lockPath=Join-Path $repo 'templates/dependency-lock.json'
        function Write-FixtureLock { param($Status,$CheckedAt,$Ref) [IO.File]::WriteAllText($lockPath,(@{dependencies=@{aiRules1c=@{ref=$Ref;compatibilityStatus=$Status;compatibilityCheckedAt=$CheckedAt}}}|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false)) }
        function New-FixtureCommit { param($Message) & git -C $repo add --all; & git -C $repo -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm $Message; (& git -C $repo rev-parse HEAD).Trim() }
        Write-FixtureLock 'pending' '' 'r1'; Set-Content -LiteralPath (Join-Path $repo 'workflow.ps1') -Value 'one'
        $candidate=New-FixtureCommit 'candidate'
        Write-FixtureLock 'passed' '2026-10-28T00:00:00Z' 'r1'
        $promotion=New-FixtureCommit 'promote'
        & git -C $repo switch -q --detach $candidate
        Write-FixtureLock 'passed' '2026-10-28T01:00:00Z' 'r1'
        $retryPromotion=New-FixtureCommit 'promote again'
        & git -C $repo switch -q --detach $candidate
        Write-FixtureLock 'passed' '2026-10-28T00:00:00Z' 'r2'
        $otherDependency=New-FixtureCommit 'different fork'
        & git -C $repo switch -q --detach $promotion
        Set-Content -LiteralPath (Join-Path $repo 'workflow.ps1') -Value 'two'
        $packageChange=New-FixtureCommit 'package change'
        function Invoke-WorktreeGit { param($Root,$Arguments,[switch]$AllowFailure) Invoke-RepositoryGit -RepositoryRoot $Root -Arguments $Arguments -AllowFailure:$AllowFailure }

        Get-DeliveryWorkflowPackageBase -CandidateRoot $repo -Commit $promotion | Should -Be $candidate
        Get-DeliveryWorkflowPackageBase -CandidateRoot $repo -Commit $retryPromotion | Should -Be $candidate
        Get-DeliveryWorkflowPackageBase -CandidateRoot $repo -Commit $candidate | Should -Be (Get-DeliveryWorkflowPackageBase -CandidateRoot $repo -Commit $promotion)
        Get-DeliveryWorkflowPackageBase -CandidateRoot $repo -Commit $otherDependency | Should -Be $otherDependency
        Get-DeliveryWorkflowPackageBase -CandidateRoot $repo -Commit $packageChange | Should -Be $packageChange
        Get-DeliveryWorkflowPackageBase -CandidateRoot $repo -Commit ('f'*40) | Should -Be ('f'*40)
    }
}

Describe 'Stand owners prepare before plan fingerprints are frozen' {
    BeforeEach {
        $script:DeliveryCustomGateBoundary=$false
        $script:standCandidate=Join-Path $TestDrive ('candidate путь '+[guid]::NewGuid().ToString('N'))
        $script:standRoot=Join-Path $TestDrive ('stand путь '+[guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory((Join-Path $script:standCandidate 'scripts'))
        [void][IO.Directory]::CreateDirectory($script:standRoot)
        $script:order=Join-Path $script:standRoot 'order.txt'
        $capsule=Join-Path $script:standRoot 'capsule.json'
        [IO.File]::WriteAllText($capsule,'immutable baseline',[Text.UTF8Encoding]::new($false))
        $script:standPreparation=[pscustomobject]@{projectRoot=$script:standRoot;sourceCommit='candidate';roots=@($script:standRoot);requiresWorkflowUpdate=$true;capsules=@([pscustomobject]@{phase='Develop';path=$capsule;sha256=(Get-FileHash $capsule).Hash;root=$script:standRoot;needsAdmission=$false})}
        $updater=@'
param($ProjectRoot,$SourceRoot,$WorkflowUpdateBranchRootsFile)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$scope=Get-Content -LiteralPath $WorkflowUpdateBranchRootsFile -Raw -Encoding UTF8 | ConvertFrom-Json
if($scope.projectRoot -ine $ProjectRoot -or $scope.roots.Count -ne 1 -or $scope.roots[0] -ine $ProjectRoot){throw 'wrong scope'}
Add-Content -LiteralPath (Join-Path $ProjectRoot 'order.txt') -Value 'update' -Encoding UTF8
[IO.File]::WriteAllText((Join-Path $ProjectRoot 'installed.txt'),'candidate',[Text.UTF8Encoding]::new($false))
[Console]::WriteLine($ProjectRoot)
'@
        $capture=@'
param($Action,$ProjectRoot,$Phase,$AgentTarget,[switch]$AcknowledgeWorkflowUpdate,$OutputPath)
$ErrorActionPreference='Stop'
# Mirrors the real fixture owner's operation contract.
if(-not $ProjectRoot -or -not $OutputPath){throw 'Fixture operation requires -ProjectRoot and -OutputPath'}
if($Action -cne 'Capture' -or -not $AcknowledgeWorkflowUpdate){throw 'wrong owner invocation'}
Add-Content -LiteralPath (Join-Path $ProjectRoot 'order.txt') -Value 'capture' -Encoding UTF8
if(Test-Path -LiteralPath (Join-Path $ProjectRoot 'business-drift.txt')){throw 'FIXTURE_SEED_CHANGED'}
if(-not(Test-Path -LiteralPath (Join-Path $ProjectRoot 'installed.txt'))){throw 'update must finish first'}
'@
        [IO.File]::WriteAllText((Join-Path $script:standCandidate 'scripts/update-installed-workflow.ps1'),$updater,[Text.UTF8Encoding]::new($true))
        [IO.File]::WriteAllText((Join-Path $script:standCandidate 'scripts/source-e2e-fixture.ps1'),$capture,[Text.UTF8Encoding]::new($true))
        function Get-DeliveryStandPreparation { $script:standPreparation }
        function Assert-DeliveryReleaseStandReady { Add-Content -LiteralPath $script:order -Value 'readiness' -Encoding UTF8 }
        $script:AgentTarget='codex';$script:ResumePlan='';$script:ApproveLongPlan='';$script:Action='PublishDevelop'
    }
    It 'prepares through native owners before freezing, then resumes without replan and blocks unexpected drift' {
        $RequireRelease=$true;$frozenPlan=$null;$priorAttempt=$null;$Replan='';$remoteBefore='base'
        $worktree=[pscustomobject]@{path=$script:standCandidate};$attempt=[pscustomobject]@{phase='candidate-built'}
        $standReadyBeforePlan=$false
        Mock Invoke-DeliveryReleaseStandRecovery { Add-Content -LiteralPath $script:order -Value 'recovery' -Encoding UTF8 }
        & ([scriptblock]::Create($script:prepareDecision.Extent.Text))
        @(Get-Content $script:order) | Should -Be @('recovery','update','capture','readiness')
        $script:savedAttempt.standPreparation.status | Should -Be 'passed'
        # The fixture double above is only as strict as the real owner it mirrors.
        [IO.File]::ReadAllText((Join-Path $RepoRoot 'scripts/source-e2e-fixture.ps1')) | Should -Match ([regex]::Escape('Fixture operation requires -ProjectRoot and -OutputPath'))
        $stdout=Join-Path $script:standCandidate 'build/test-results/delivery/stand-workflow-update.stdout.log'
        ([Text.UTF8Encoding]::new($false,$true).GetString([IO.File]::ReadAllBytes($stdout))).TrimEnd("`r","`n") | Should -BeExactly $script:standRoot
        (Get-FileHash $script:standPreparation.capsules[0].path).Hash | Should -Be $script:standPreparation.capsules[0].sha256
        $plan=[pscustomobject]@{planId='prepared';status='ready';executedBudgetSeconds=1;stages=@();candidate=@{commit='candidate';tree='tree';baseCommit='base'}}
        $plan | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $TestDrive 'prepared.json') -Encoding UTF8
        $script:ResumePlan=$plan.planId
        { Assert-DeliveryQualityPlanMayRun $plan } | Should -Not -Throw
        $priorAttempt=[pscustomobject]@{planId=$plan.planId};$frozenPlan=$plan
        & ([scriptblock]::Create($script:prepareDecision.Extent.Text))
        @(Get-Content $script:order) | Should -HaveCount 4
        $plan.planId='unexpected-stand-change'
        Mock Get-DeliveryPlanRoot { $TestDrive }
        { Assert-DeliveryQualityPlanMayRun $plan } | Should -Throw '*DELIVERY_RESUME_PLAN_MISMATCH*'
        @(Get-Content $script:order) | Should -HaveCount 4
    }
    It 'preserves the unplanned checkpoint and immutable capsule on owner rejection; the same scope can continue' {
        [IO.File]::WriteAllText((Join-Path $script:standRoot 'business-drift.txt'),'unexpected')
        $attempt=[pscustomobject]@{phase='candidate-built'}
        { Invoke-DeliveryStandPreparation $script:standCandidate $script:standPreparation $attempt } | Should -Throw '*PREPARATION_FAILED*'
        $script:savedAttempt.standPreparation.status | Should -Be 'running'
        (Get-FileHash $script:standPreparation.capsules[0].path).Hash | Should -Be $script:standPreparation.capsules[0].sha256
        Remove-Item -LiteralPath (Join-Path $script:standRoot 'business-drift.txt')
        { Invoke-DeliveryStandPreparation $script:standCandidate $script:standPreparation $attempt } | Should -Not -Throw
        $script:savedAttempt.standPreparation.status | Should -Be 'passed'
        $script:standPreparation.roots+=@('foreign-root')
        { Invoke-DeliveryStandPreparation $script:standCandidate $script:standPreparation $attempt } | Should -Throw '*PREPARATION_CHANGED*'
    }
    It 'keeps preparation before calculation and saving in the actual publisher' {
        $publisher=@($script:publisherAst.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Publish-AccumulatedDevelop'},$false))[0]
        $calls=@($publisher.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst]},$true))
        $prepare=@($calls | Where-Object { $_.GetCommandName() -ceq 'Invoke-DeliveryStandPreparation' })[0]
        $calculate=@($calls | Where-Object { $_.GetCommandName() -ceq 'Invoke-DeliveryCandidatePlanCalculation' })[0]
        $save=@($calls | Where-Object { $_.GetCommandName() -ceq 'Save-DeliveryQualityPlan' })[0]
        $prepare.Extent.StartOffset | Should -BeLessThan $calculate.Extent.StartOffset
        $calculate.Extent.StartOffset | Should -BeLessThan $save.Extent.StartOffset
    }
}
