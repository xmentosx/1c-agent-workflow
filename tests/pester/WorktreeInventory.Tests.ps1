BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSupport.ps1')
    $context = Initialize-WorkflowPesterContext
    $HelperPath = $context.HelperPath
}

Describe 'Git worktree inventory for workflow rollout' {
    It 'retries a deferred root without reapplying a completed root' {
        $root = Join-Path $TestDrive 'Основной проект rollout'
        $free = Join-Path $TestDrive 'Готовая ветка'
        $busy = Join-Path $TestDrive 'Занятая ветка'
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        & git -C $root init --quiet
        & git -C $root symbolic-ref HEAD refs/heads/master
        & git -C $root config user.email 'rollout@example.invalid'
        & git -C $root config user.name 'Rollout Fixture'
        [IO.File]::WriteAllText((Join-Path $root '.gitignore'), ".agent-1c/snapshots/`n.agent-1c/locks/`n", [Text.UTF8Encoding]::new($false))
        $lock = Join-Path $root '.agent-1c/dependency-lock.json'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $lock) | Out-Null
        [IO.File]::WriteAllText((Join-Path $root '.agent-1c/project.json'), '{"aiRules":{"tools":[]}}', [Text.UTF8Encoding]::new($false))
        $candidate = '2' * 40
        [IO.File]::WriteAllText($lock, ('{"dependencies":{"workflowPackage":{"commit":"' + $candidate + '"}}}'), [Text.UTF8Encoding]::new($false))
        & git -C $root add --all
        & git -C $root commit --quiet -m base
        & git -C $root branch itldev/free
        & git -C $root branch itldev/busy
        & git -C $root worktree add --quiet $free itldev/free
        & git -C $root worktree add --quiet $busy itldev/busy
        $busyLock = Join-Path $busy '.agent-1c/locks/lifecycle.lock'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $busyLock) | Out-Null
        $handle = [IO.File]::Open($busyLock, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try {
            $proof = & {
                . $HelperPath -ProjectRoot $root -Action help *> $null
                $script:rolloutCalls = @()
                $script:rolloutBranchRoot = ''
                function Invoke-InProjectContext { param([string]$Root,[scriptblock]$ScriptBlock)
                    $script:rolloutBranchRoot = $Root
                    & $ScriptBlock
                }
                function Invoke-WorkflowDevelopmentBranchUpdate { param([object]$Source)
                    $script:rolloutCalls += $script:rolloutBranchRoot
                    [pscustomobject]@{ status='completed'; commit=(Get-GitOutputAt -Root $script:rolloutBranchRoot -Arguments @('rev-parse','HEAD')).Trim() }
                }
                $source = [pscustomobject]@{root='C:\candidate source';repo='repo';ref='pin';commit=$candidate;source='path'}
                $first = Invoke-WorkflowDevelopmentBranchRollout -Source $source
                [pscustomobject]@{ first=$first; source=$source; calls=@($script:rolloutCalls) }
            }
            @($proof.first.roots | Where-Object branch -eq 'itldev/free')[0].status | Should -Be 'completed'
            @($proof.first.roots | Where-Object branch -eq 'itldev/busy')[0].status | Should -Be 'deferred'
            $proof.calls | Should -HaveCount 1
            $proof.calls[0] | Should -Be $free
        } finally { $handle.Dispose() }
        $retry = & {
            . $HelperPath -ProjectRoot $root -Action help *> $null
            $script:rolloutCalls = @()
            $script:rolloutBranchRoot = ''
            function Invoke-InProjectContext { param([string]$Root,[scriptblock]$ScriptBlock)
                $script:rolloutBranchRoot = $Root
                & $ScriptBlock
            }
            function Invoke-WorkflowDevelopmentBranchUpdate { param([object]$Source)
                $script:rolloutCalls += $script:rolloutBranchRoot
                [pscustomobject]@{ status='completed'; commit=(Get-GitOutputAt -Root $script:rolloutBranchRoot -Arguments @('rev-parse','HEAD')).Trim() }
            }
            $source = [pscustomobject]@{root='C:\candidate source';repo='repo';ref='pin';commit=$candidate;source='path'}
            $report = Invoke-WorkflowDevelopmentBranchRollout -Source $source
            Assert-WorkflowDevelopmentBranchRolloutComplete -SourceCommit $candidate | Out-Null
            [pscustomobject]@{ report=$report; calls=@($script:rolloutCalls) }
        }
        @($retry.report.roots | Where-Object status -eq 'completed') | Should -HaveCount 2
        $retry.calls | Should -HaveCount 1
        $retry.calls[0] | Should -Be $busy
    }

    It 'keeps Cyrillic and whitespace paths and branch identity from porcelain -z' {
        $root = Join-Path $TestDrive 'Главный проект с пробелом'
        $branchRoot = Join-Path $TestDrive 'Рабочая ветка с пробелом'
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        & git -C $root init --quiet
        & git -C $root symbolic-ref HEAD refs/heads/master
        & git -C $root config user.email 'inventory@example.invalid'
        & git -C $root config user.name 'ITL Inventory Test'
        [IO.File]::WriteAllText((Join-Path $root 'fixture.txt'), 'fixture', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $root '.gitignore'), ".agent-1c/client-surface.json`n.codex/commands/itl-test.md`n", [Text.UTF8Encoding]::new($false))
        & git -C $root add fixture.txt .gitignore
        & git -C $root commit --quiet -m 'fixture'
        & git -C $root branch itldev/cyrillic
        & git -C $root worktree add --quiet $branchRoot itldev/cyrillic
        $LASTEXITCODE | Should -Be 0

        $items = & { . $HelperPath -ProjectRoot $root -Action help *> $null; @(Get-GitWorktrees) }
        $items | Should -HaveCount 2
        $main = @($items | Where-Object branch -eq 'master')[0]
        $branch = @($items | Where-Object branch -eq 'itldev/cyrillic')[0]
        [IO.Path]::GetFullPath($main.path) | Should -Be ([IO.Path]::GetFullPath($root))
        [IO.Path]::GetFullPath($branch.path) | Should -Be ([IO.Path]::GetFullPath($branchRoot))
        $branch.detached | Should -BeFalse

        $lockPath = Join-Path $branchRoot '.agent-1c/locks/lifecycle.lock'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $lockPath) | Out-Null
        $busyHandle = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try {
            $busyInventory = & { . $HelperPath -ProjectRoot $root -Action help *> $null; @(Get-WorkflowUpdateWorktreeInventory) }
            @($busyInventory | Where-Object branch -eq 'itldev/cyrillic')[0].eligibility | Should -Be 'deferred'
            @($busyInventory | Where-Object branch -eq 'itldev/cyrillic')[0].reason | Should -Be 'active-lifecycle-lock'
        } finally { $busyHandle.Dispose() }

        $runtimePath = Join-Path $branchRoot ('.agent-1c/mcp/ondemand/vanessa/' + ('a' * 32) + '.json')
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $runtimePath) | Out-Null
        [IO.File]::WriteAllText($runtimePath, ('{"pid":' + $PID + '}'), [Text.UTF8Encoding]::new($false))
        $runtimeInventory = & { . $HelperPath -ProjectRoot $root -Action help *> $null; @(Get-WorkflowUpdateWorktreeInventory) }
        @($runtimeInventory | Where-Object branch -eq 'itldev/cyrillic')[0].reason | Should -Be 'runtime-process-active-or-unconfirmed'
        [IO.File]::WriteAllText($runtimePath, '{broken', [Text.UTF8Encoding]::new($false))
        $invalidRuntimeInventory = & { . $HelperPath -ProjectRoot $root -Action help *> $null; @(Get-WorkflowUpdateWorktreeInventory) }
        $invalidRuntime = @($invalidRuntimeInventory | Where-Object branch -eq 'itldev/cyrillic')[0]
        $invalidRuntime.eligibility | Should -Be 'deferred'
        $invalidRuntime.reason | Should -Match 'WORKFLOW_UPDATE_RUNTIME_STATE_INVALID'
        Remove-Item -LiteralPath $runtimePath -Force

        [IO.File]::WriteAllText((Join-Path $branchRoot '.agent-1c/locks/lifecycle-operation.json'), '{"status":"running","action":"refresh-dev-branch"}', [Text.UTF8Encoding]::new($false))
        $stoppedInventory = & { . $HelperPath -ProjectRoot $root -Action help *> $null; @(Get-WorkflowUpdateWorktreeInventory) }
        $stopped = @($stoppedInventory | Where-Object branch -eq 'itldev/cyrillic')[0]
        $stopped.eligibility | Should -Be 'eligible'
        $stopped.pendingAction | Should -Be 'refresh-dev-branch'
        @($stoppedInventory | Where-Object kind -eq 'master')[0].eligibility | Should -Be 'eligible'
        $stopped.continuation | Should -Match 'original command'

        $dependencyLockPath = Join-Path $branchRoot '.agent-1c/dependency-lock.json'
        [IO.File]::WriteAllText($dependencyLockPath, '{"dependencies":{"workflowPackage":{"commit":"1111111111111111111111111111111111111111"}}}', [Text.UTF8Encoding]::new($false))
        & git -C $branchRoot add -- .agent-1c/dependency-lock.json
        & git -C $branchRoot commit --quiet -m 'fixture workflow lock'
        $matchingLockInventory = & { . $HelperPath -ProjectRoot $root -Action help *> $null; @(Get-WorkflowUpdateWorktreeInventory -TargetCommit '1111111111111111111111111111111111111111') }
        $matchingLock = @($matchingLockInventory | Where-Object branch -eq 'itldev/cyrillic')[0]
        $matchingLock.eligibility | Should -Be 'eligible' -Because 'the lock alone does not prove that rules and clients were installed'
        $matchingLock.installedWorkflowCommit | Should -Be $matchingLock.targetWorkflowCommit
        $matchingLock.pendingAction | Should -Be 'refresh-dev-branch'

        [IO.File]::WriteAllText((Join-Path $branchRoot 'fixture.txt'), 'branch business change', [Text.UTF8Encoding]::new($false))
        & git -C $branchRoot add fixture.txt
        & git -C $branchRoot commit --quiet -m 'branch business change'
        [IO.File]::WriteAllText((Join-Path $root 'fixture.txt'), 'master business change', [Text.UTF8Encoding]::new($false))
        & git -C $root add fixture.txt
        & git -C $root commit --quiet -m 'master business change'
        & git -C $branchRoot merge --no-edit master *> $null
        $LASTEXITCODE | Should -Not -Be 0
        $mergeHeadPath = (& git -C $branchRoot rev-parse --git-path MERGE_HEAD).Trim()
        Test-Path -LiteralPath $mergeHeadPath -PathType Leaf | Should -BeTrue
        $mergeInventory = & { . $HelperPath -ProjectRoot $root -Action help *> $null; @(Get-WorkflowUpdateWorktreeInventory) }
        $mergeScope = @($mergeInventory | Where-Object branch -eq 'itldev/cyrillic')[0]
        $mergeScope.eligibility | Should -Be 'eligible'
        $mergeScope.pendingAction | Should -Be 'refresh-dev-branch'

        [IO.File]::WriteAllText((Join-Path $branchRoot 'fixture.txt'), 'unrelated business edit', [Text.UTF8Encoding]::new($false))
        $unrelatedInventory = & { . $HelperPath -ProjectRoot $root -Action help *> $null; @(Get-WorkflowUpdateWorktreeInventory) }
        @($unrelatedInventory | Where-Object branch -eq 'itldev/cyrillic')[0].eligibility | Should -Be 'eligible'

        $generatedPath = Join-Path $branchRoot '.codex/commands/itl-test.md'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $generatedPath) | Out-Null
        [IO.File]::WriteAllText($generatedPath, 'recorded ignored client file', [Text.UTF8Encoding]::new($false))
        $recordedHash = (Get-FileHash -LiteralPath $generatedPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $clientStatePath = Join-Path $branchRoot '.agent-1c/client-surface.json'
        [IO.File]::WriteAllText($clientStatePath,
            ('{"clients":{"codex":{"files":{".codex/commands/itl-test.md":"' + $recordedHash + '"}}}}'),
            [Text.UTF8Encoding]::new($false))
        $matchingClientInventory = & { . $HelperPath -ProjectRoot $root -Action help *> $null; @(Get-WorkflowUpdateWorktreeInventory) }
        @($matchingClientInventory | Where-Object branch -eq 'itldev/cyrillic')[0].eligibility | Should -Be 'eligible'
        [IO.File]::WriteAllText($generatedPath, 'changed ignored client file', [Text.UTF8Encoding]::new($false))
        $ignoredClientInventory = & { . $HelperPath -ProjectRoot $root -Action help *> $null; @(Get-WorkflowUpdateWorktreeInventory) }
        $ignoredClient = @($ignoredClientInventory | Where-Object branch -eq 'itldev/cyrillic')[0]
        $ignoredClient.eligibility | Should -Be 'blocked'
        $ignoredClient.conflictPaths | Should -Contain '.codex/commands/itl-test.md'
        Remove-Item -LiteralPath $generatedPath, $clientStatePath -Force

        $ownedPath = Join-Path $branchRoot '.agents/skills/1c-workflow/scripts/local-repair.ps1'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ownedPath) | Out-Null
        [IO.File]::WriteAllText($ownedPath, 'user edit', [Text.UTF8Encoding]::new($false))
        $conflictInventory = & { . $HelperPath -ProjectRoot $root -Action help *> $null; @(Get-WorkflowUpdateWorktreeInventory) }
        $conflict = @($conflictInventory | Where-Object branch -eq 'itldev/cyrillic')[0]
        $conflict.eligibility | Should -Be 'blocked'
        $conflict.reason | Should -Be 'workflow-write-set-conflict'
        $conflict.conflictPaths | Should -Contain '.agents/skills/1c-workflow/scripts/local-repair.ps1'

        Remove-Item -LiteralPath $ownedPath -Force
        [IO.File]::WriteAllText((Join-Path $branchRoot '.ai-rules.json'), '{"files":{".cursor/rules-1c/custom.md":{"source":"content/rules/custom.md"}}}', [Text.UTF8Encoding]::new($false))
        $rulesPath = Join-Path $branchRoot '.cursor/rules-1c/custom.md'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $rulesPath) | Out-Null
        [IO.File]::WriteAllText($rulesPath, 'user edit in rules surface', [Text.UTF8Encoding]::new($false))
        $rulesInventory = & { . $HelperPath -ProjectRoot $root -Action help *> $null; @(Get-WorkflowUpdateWorktreeInventory) }
        $rules = @($rulesInventory | Where-Object branch -eq 'itldev/cyrillic')[0]
        $rules.eligibility | Should -Be 'blocked'
        $rules.reason | Should -Be 'workflow-write-set-conflict'
        $rules.conflictPaths | Should -Contain '.cursor/rules-1c/custom.md'

        Remove-Item -LiteralPath $rulesPath -Force
        Remove-Item -LiteralPath (Join-Path $branchRoot '.ai-rules.json') -Force
        [IO.File]::WriteAllText((Join-Path $branchRoot '.agent-1c/locks/lifecycle-operation.json'), '{broken json', [Text.UTF8Encoding]::new($false))
        $ambiguousInventory = & { . $HelperPath -ProjectRoot $root -Action help *> $null; @(Get-WorkflowUpdateWorktreeInventory) }
        $ambiguous = @($ambiguousInventory | Where-Object branch -eq 'itldev/cyrillic')[0]
        $ambiguous.eligibility | Should -Be 'blocked'
        $ambiguous.reason | Should -Match 'WORKFLOW_UPDATE_OPERATION_STATE_INVALID'
        @($ambiguousInventory | Where-Object kind -eq 'master')[0].eligibility | Should -Be 'eligible'
    }
}

Describe 'Sealed branch patch retirement through the rollout owner' {
    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $branchRoot = Join-Path $root 'Ветка с пробелом'
        New-Item -ItemType Directory -Force -Path $branchRoot | Out-Null
        . $helperPath -ProjectRoot $root -Action help *> $null
        $script:conflicts = @('.agents/skills/1c-workflow/scripts/lib/agent-1c.lifecycle.ps1')
        $script:patchSteps = @()
        $source = [pscustomobject]@{root='C:\exact candidate';repo='repo';ref='develop';commit=('c'*40);source='path'}
        Mock Get-WorkflowUpdateWorktreeInventory {
            [pscustomobject]@{kind='development';root=$branchRoot;branch='itldev/test';eligibility='blocked';reason='workflow-write-set-conflict';conflictPaths=$script:conflicts;head=('a'*40);installedWorkflowCommit=('b'*40);continuation='fixture continuation'}
        }
        Mock Invoke-InProjectContext { param($Root,$ScriptBlock) & $ScriptBlock }
        Mock Get-WorkflowRolloutClients { @() }
        Mock Test-WorkflowRolloutClients { $true }
        Mock Get-AgentTargets { @() }
        Mock Ensure-Agent1cLifecycleLocksIgnored {}
        Mock Get-WorkflowUpdateRootRuntimeBusyReason { '' }
        Mock Invoke-WorkflowLocalPatchStep {
            param($Step)
            $script:patchSteps += $Step
            if ($Step -eq 'Plan') { [pscustomobject]@{preserve=$false;paths=@('.agents/skills/1c-workflow/scripts/lib/agent-1c.lifecycle.ps1')} }
        }
        Mock Invoke-WorkflowDevelopmentBranchUpdate {
            param($Source, $LocalPatchPlan)
            $LocalPatchPlan.paths | Should -Contain '.agents/skills/1c-workflow/scripts/lib/agent-1c.lifecycle.ps1'
            Invoke-WorkflowLocalPatchStep -Step Complete -Plan $LocalPatchPlan
            [pscustomobject]@{status='completed';commit=('d'*40)}
        }
        Mock Get-DependencyLockEntry { @{commit=('b'*40)} }
    }

    It 'revalidates under the lease and retires through the existing owner' {
        $result = Invoke-WorkflowDevelopmentBranchRollout -Source $source
        $result.roots[0].status | Should -Be 'completed'
        $script:patchSteps | Should -Be @('Plan','Plan','Retire','Complete')
        Should -Invoke Invoke-WorkflowDevelopmentBranchUpdate -Times 1 -Exactly
    }

    It 'preserves an additional workflow edit outside the sealed patch' {
        $script:conflicts += '.agents/skills/1c-workflow/scripts/foreign.ps1'
        $result = Invoke-WorkflowDevelopmentBranchRollout -Source $source
        $result.roots[0].status | Should -Be 'blocked'
        $script:patchSteps | Should -Be @('Plan')
        Should -Invoke Invoke-WorkflowDevelopmentBranchUpdate -Times 0 -Exactly
    }

    It 'returns the patch through its owner when the candidate was not installed' {
        Mock Invoke-WorkflowDevelopmentBranchUpdate { throw 'copy fixture failure' }
        $result = Invoke-WorkflowDevelopmentBranchRollout -Source $source
        $result.roots[0].status | Should -Be 'blocked'
        $script:patchSteps | Should -Be @('Plan','Plan','Retire','Undo')
    }

    It 'retains the patch archive once copying succeeded and post-copy needs recovery' {
        Mock Invoke-WorkflowDevelopmentBranchUpdate { throw 'post-copy fixture failure' }
        Mock Get-DependencyLockEntry { @{commit=('c'*40)} }
        $result = Invoke-WorkflowDevelopmentBranchRollout -Source $source
        $result.roots[0].status | Should -Be 'blocked'
        $script:patchSteps | Should -Be @('Plan','Plan','Retire','Complete')
    }
}

Describe 'Additive client membership through the branch rollout transaction' {
    BeforeAll {
        $candidate = Join-Path $TestDrive 'Чистый источник клиентов'
        $templateParent = Join-Path $candidate '.agents/skills/1c-workflow'
        New-Item -ItemType Directory -Force -Path $templateParent | Out-Null
        Copy-Item -LiteralPath (Join-Path $context.RepoRoot '.agents/skills/1c-workflow/kilo-command-templates') -Destination $templateParent -Recurse
        . $helperPath -ProjectRoot $candidate -Action help *> $null
        Invoke-GitAt -Root $candidate -Arguments @('init','-q','-b','develop')
        Invoke-GitAt -Root $candidate -Arguments @('config','user.name','Client source fixture')
        Invoke-GitAt -Root $candidate -Arguments @('config','user.email','source@example.invalid')
        Invoke-GitAt -Root $candidate -Arguments @('config','maintenance.auto','false')
        Invoke-GitAt -Root $candidate -Arguments @('config','gc.auto','0')
        Invoke-GitAt -Root $candidate -Arguments @('add','--all')
        Invoke-GitAt -Root $candidate -Arguments @('commit','-qm','pinned command templates')
        $script:clientRolloutSource = [pscustomobject]@{root=$candidate;commit=(Get-GitOutputAt -Root $candidate -Arguments @('rev-parse','HEAD')).Trim();repo='fixture';ref='develop';source='path'}
    }
    BeforeEach {
        $root = Join-Path $TestDrive ('Основной проект клиентов ' + [guid]::NewGuid().ToString('N'))
        $branch1 = $root + '-ветка 1'
        $branch2 = $root + '-ветка 2'
        $utf8 = [Text.UTF8Encoding]::new($false)
        New-Item -ItemType Directory -Force -Path (Join-Path $root '.agent-1c'), (Join-Path $root 'src/cf') | Out-Null
        [IO.File]::WriteAllText((Join-Path $root '.agent-1c/project.json'), '{"masterBranch":"master","aiRules":{"tools":["codex"],"modelTiersByClient":{"codex":{"light":"keep/codex"},"kilocode":{"light":"keep/kilo"}}}}', $utf8)
        [IO.File]::WriteAllText((Join-Path $root '.agent-1c/dependency-lock.json'), ('{"dependencies":{"workflowPackage":{"commit":"' + $script:clientRolloutSource.commit + '"}}}'), $utf8)
        [IO.File]::WriteAllText((Join-Path $root '.gitignore'), ".agent-1c/snapshots/`n.agent-1c/locks/`n.agent-1c/tmp/`n.agent-1c/mcp/`n.agent-1c/client-surface.json`n.mcp.json`n.cursor/mcp.json`n.codex/config.toml`n.kilo/kilo.json`n", $utf8)
        [IO.File]::WriteAllText((Join-Path $root 'src/cf/Модуль с пробелом.bsl'), 'baseline', $utf8)
        & git -C $root init -q -b master
        & git -C $root config user.name 'Client rollout fixture'
        & git -C $root config user.email 'rollout@example.invalid'
        # Synthetic repositories must not start host-configured background Git
        # maintenance during commit or retain a maintenance child after cleanup.
        & git -C $root config maintenance.auto false
        & git -C $root config gc.auto 0
        & git -C $root add --all
        & git -C $root commit -qm baseline
        & git -C $root worktree add -q -b itldev/one $branch1
        & git -C $root worktree add -q -b itldev/two $branch2
        $LASTEXITCODE | Should -Be 0
        . $helperPath -ProjectRoot $root -Action help *> $null
        $source = $script:clientRolloutSource
        $script:rolloutFailure = ''
        $script:installedClientSets = @()
        $script:inventoryClientSets = @()
        $script:realApplyClientPlan = ${function:Apply-WorkflowBranchCommitPlan}
        Mock Read-DevBranchState { @{devBranch=(Get-CurrentBranch)} }
        Mock Assert-WorkflowUpdateDevelopmentBranchRoot {}
        Mock Get-PendingDevBranchMergeTransaction { $null }
        Mock Resolve-WorkflowUpdateLegacyExecutor { $null }
        Mock Get-WorkflowDependencyPlan { @{schemaVersion=1} }
        Mock Assert-WorkflowDependencyPlan {}
        Mock Get-AiRulesBaselineTarget { @{isConfigured=$true;repo='fixture';ref='fixture';commit=('3'*40)} }
        Mock Assert-WorkflowUpdateRulesRootReady {}
        Mock Sync-AiRules1cCheckout { $context.RepoRoot }
        Mock Get-WorkflowPackageCopyDirectoryPaths { @() }
        Mock Get-WorkflowPackageCopyFilePaths { @() }
        Mock Remove-LegacyWorkflowManagedFiles {}
        Mock Get-WorkflowUpdateEligibleLegacyPaths { @() }
        Mock Assert-WorkflowUpdateLegacyRetirementSnapshot {}
        Mock Add-WorkflowDotEnvPolicySnapshotPaths {}
        Mock Enable-WorkflowExecutionGuardForCurrentRoot {}
        Mock Set-ItlOnDemandMcpSemanticReloadRequiredAction {}
        Mock Invoke-WorkflowLocalPatchStep {}
        Mock Write-ItlOnDemandMcpClientConfig { $null }
        Mock Sync-ItlUiToolsMcp { $null }
        Mock Sync-ItlClientRequiredPackage {}
        Mock Get-AiRulesCandidateInstallInventory {
            param($Checkout, $Tools)
            $script:inventoryClientSets += ,@($Tools)
            foreach ($client in $Tools) { ".fixture-rules/$client.md" }
        }
        Mock Invoke-WorkflowPackageFilePostCopy {
            $clients = @(Get-AgentTargets)
            $script:installedClientSets += ,@($clients)
            $pending = Get-WorkflowUpdatePendingSnapshot
            $planned = @($pending.snapshot.records.relativePath)
            $files = [ordered]@{}
            foreach ($client in $clients) {
                $relative = ".fixture-rules/$client.md"
                $planned | Should -Contain $relative
                $files[$relative] = @{installedHash='fixture'}
                Write-Utf8Text -Path (Join-Path $script:ProjectRoot $relative) -Value "rules for $client"
                foreach ($expected in @(Get-WorkflowUpdateExpectedClientWritePaths -SourceRoot $source.root -Clients @($client))) {
                    $planned | Should -Contain $expected
                }
                Write-ItlClientMcpEndpoints -Client $client -Owner rollout-fixture -Endpoints @(@{
                    name='fixture-branch';transport='stdio';command='powershell';args=@('-ProjectRoot',$script:ProjectRoot)
                }) | Out-Null
            }
            Write-Utf8Text -Path (Join-Path $script:ProjectRoot '.ai-rules.json') -Value ((@{tools=$clients;files=$files}) | ConvertTo-Json -Depth 8)
            Sync-ItlClientSurfaces -SourceRoot $source.root
            if ($script:rolloutFailure -eq 'omit-rule') {
                $script:rolloutFailure=''
                Remove-Item -LiteralPath (Join-Path $script:ProjectRoot '.fixture-rules/cursor.md')
            }
            if ($script:rolloutFailure -eq 'post-copy') { $script:rolloutFailure=''; throw 'fixture interruption after client membership changed' }
            [pscustomobject]@{aiRulesPathsBefore=@();clientSurfacePathsBefore=@()}
        }
        Mock Apply-WorkflowBranchCommitPlan {
            param($Plan,$PendingMergeState)
            if ($script:rolloutFailure -eq 'before-commit') { $script:rolloutFailure=''; throw 'fixture interruption before commit' }
            & $script:realApplyClientPlan -Plan $Plan -PendingMergeState $PendingMergeState
        }
    }

    It 'invalidates legacy completed and same-package client changes, preserves dirty work and extra clients, then repeats without commits' {
        $initial = Invoke-WorkflowDevelopmentBranchRollout -Source $source
        @($initial.roots.status) | Should -Be @('completed','completed') -Because ($initial | ConvertTo-Json -Depth 8 -Compress)
        # Simulate a real schema-1 report produced before client-set evidence existed.
        foreach ($entry in $initial.roots) { $entry.PSObject.Properties.Remove('clients') }
        Write-Utf8Text -Path (Join-Path $root '.agent-1c/snapshots/workflow-update-rollout.json') -Value ($initial | ConvertTo-Json -Depth 8)
        { Assert-WorkflowDevelopmentBranchRolloutComplete -SourceCommit $source.commit } | Should -Throw '*CLIENTS_INCOMPLETE*repeat update-workflow*'
        $script:installedClientSets = @()
        $legacyRetry = Invoke-WorkflowDevelopmentBranchRollout -Source $source
        @($legacyRetry.roots.status) | Should -Be @('completed','completed')
        $script:installedClientSets.Count | Should -Be 2

        Invoke-InProjectContext -Root $branch1 -ScriptBlock {
            Set-ProjectAiRulesClients -Clients @('codex','kilocode')
            Invoke-Git @('add','--','.agent-1c/project.json')
            Invoke-Git @('commit','-qm','branch-local client')
        }
        $business = Join-Path $branch1 'src/cf/Модуль с пробелом.bsl'
        [IO.File]::WriteAllText($business, 'staged business', $utf8)
        Invoke-GitAt -Root $branch1 -Arguments @('add','--','src/cf/Модуль с пробелом.bsl')
        (Get-GitOutputAt -Root $branch1 -Arguments @('show',':src/cf/Модуль с пробелом.bsl')).Trim() | Should -Be 'staged business'
        [IO.File]::WriteAllText($business, 'unstaged business', $utf8)
        [IO.File]::WriteAllText((Join-Path $branch1 'src/cf/Новый файл.bsl'), 'untracked business', $utf8)
        $indexBefore = Invoke-InProjectContext -Root $branch1 -ScriptBlock { @(Get-GitPathList -Arguments @('ls-files','--stage','-z','--','src/cf')) -join "`0" }
        Write-Utf8Text -Path (Join-Path $branch1 '.mcp.json') -Value '{"customSetting":7,"mcpServers":{"foreign":{"url":"https://user.invalid"}}}'
        Set-ProjectAiRulesClients -Clients @('codex','cursor','claude-code')
        Read-ProjectConfig
        Invoke-Git @('add','--','.agent-1c/project.json')
        Invoke-Git @('commit','-qm','attach master clients')
        $report = Invoke-WorkflowDevelopmentBranchRollout -Source $source
        @($report.roots.status) | Should -Be @('completed','completed')
        @($report.roots | Where-Object root -EQ $branch1)[0].clients | Should -Contain 'kilocode'
        foreach ($branch in @($branch1,$branch2)) {
            $clients = @(Get-WorkflowRolloutClients -Root $branch)
            $clients | Should -Contain 'cursor'
            $clients | Should -Contain 'claude-code'
            Test-WorkflowRolloutClients -Root $branch -Clients $clients -RequiredClients @('codex','cursor','claude-code') -SourceRoot $source.root | Should -BeTrue
            $mcp = Get-Content -LiteralPath (Join-Path $branch '.mcp.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            $mcp.mcpServers.'fixture-branch'.args | Should -Contain $branch
            $cursor = Get-Content -LiteralPath (Join-Path $branch '.cursor/mcp.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            $cursor.mcpServers.'fixture-branch'.args | Should -Contain $branch
            $config = Get-Content -LiteralPath (Join-Path $branch '.agent-1c/project.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            $config.aiRules.modelTiersByClient.codex.light | Should -Be 'keep/codex'
            $config.aiRules.modelTiersByClient.kilocode.light | Should -Be 'keep/kilo'
        }
        $mcp = Get-Content -LiteralPath (Join-Path $branch1 '.mcp.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $mcp.customSetting | Should -Be 7
        $mcp.mcpServers.foreign.url | Should -Be 'https://user.invalid'
        [IO.File]::ReadAllText($business) | Should -Be 'unstaged business'
        [IO.File]::ReadAllText((Join-Path $branch1 'src/cf/Новый файл.bsl')) | Should -Be 'untracked business'
        (Invoke-InProjectContext -Root $branch1 -ScriptBlock { @(Get-GitPathList -Arguments @('ls-files','--stage','-z','--','src/cf')) -join "`0" }) | Should -BeExactly $indexBefore
        $heads = @($branch1,$branch2 | ForEach-Object { (Get-GitOutputAt -Root $_ -Arguments @('rev-parse','HEAD')).Trim() })
        $script:installedClientSets = @()
        $noOpWatch = [Diagnostics.Stopwatch]::StartNew()
        Invoke-WorkflowDevelopmentBranchRollout -Source $source | Out-Null
        $noOpWatch.Stop()
        Write-Host "Two-root client rollout no-op: $($noOpWatch.ElapsedMilliseconds) ms."
        Assert-WorkflowDevelopmentBranchRolloutComplete -SourceCommit $source.commit | Out-Null
        $script:installedClientSets.Count | Should -Be 0
        @($branch1,$branch2 | ForEach-Object { (Get-GitOutputAt -Root $_ -Arguments @('rev-parse','HEAD')).Trim() }) | Should -Be $heads
        # Missing ignored config must invalidate a current completed report too.
        Remove-Item -LiteralPath (Join-Path $branch2 '.cursor/mcp.json')
        { Assert-WorkflowDevelopmentBranchRolloutComplete -SourceCommit $source.commit } | Should -Throw '*CLIENTS_INCOMPLETE*'
        Invoke-WorkflowDevelopmentBranchRollout -Source $source | Out-Null
        Test-Path -LiteralPath (Join-Path $branch2 '.cursor/mcp.json') | Should -BeTrue
    }

    It 'finishes the pinned membership after <Phase>, then adds a newly requested client in a separate snapshot' -ForEach @(@{Phase='post-copy'},@{Phase='before-commit'}) {
        $script:rolloutFailure = $Phase
        Invoke-InProjectContext -Root $branch1 -ScriptBlock {
            { Invoke-WorkflowDevelopmentBranchUpdate -Source $source -MasterClients @('codex','cursor') } | Should -Throw '*fixture interruption*'
            $pending = Get-WorkflowUpdatePendingSnapshot
            $pending.receipt.clientMembership.target | Should -Be @('codex','cursor')
            $originalSnapshot = $pending.snapshot.root
            $before = $pending.receipt.beforePathState | ConvertTo-Json -Depth 8 -Compress
            Invoke-WorkflowDevelopmentBranchUpdate -Source $source -MasterClients @('codex','cursor','claude-code') | Out-Null
            @(Get-AgentTargets) | Should -Be @('codex','cursor','claude-code')
            Get-WorkflowUpdatePendingSnapshot | Should -BeNullOrEmpty
            $retained = Join-Path (Split-Path $originalSnapshot) ((Split-Path -Leaf $originalSnapshot).Replace('rollback-','completed-'))
            $oldReceipt = Get-Content -LiteralPath (Join-Path $retained 'transaction.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            $oldReceipt.clientMembership.target | Should -Be @('codex','cursor')
            ($oldReceipt.beforePathState | ConvertTo-Json -Depth 8 -Compress) | Should -BeExactly $before
            @($oldReceipt.records.relativePath) | Should -Not -Contain '.mcp.json'
        }
        @($script:installedClientSets | ForEach-Object { $_ -join ',' }) | Should -Contain 'codex,cursor'
        $script:installedClientSets[-1] | Should -Be @('codex','cursor','claude-code')
    }

    It 'recovers a legacy receipt without membership before adding clients' {
        Invoke-InProjectContext -Root $branch1 -ScriptBlock {
            $script:rolloutFailure = 'post-copy'
            { Invoke-WorkflowDevelopmentBranchUpdate -Source $source } | Should -Throw '*fixture interruption*'
            $pending = Get-WorkflowUpdatePendingSnapshot
            $pending.receipt.PSObject.Properties.Name | Should -Not -Contain 'clientMembership'
            $patch = @{id='recovered-patch'}
            Invoke-WorkflowDevelopmentBranchUpdate -Source $source -MasterClients @('codex','cursor','claude-code') -LocalPatchPlan $patch | Out-Null
            Should -Invoke Invoke-WorkflowLocalPatchStep -Times 0 -Exactly -ParameterFilter { $Step -eq 'Bind' -and $null -ne $Plan }
            Should -Invoke Invoke-WorkflowLocalPatchStep -Times 1 -Exactly -ParameterFilter { $Step -eq 'Complete' -and $null -ne $Plan }
            @(Get-AgentTargets) | Should -Be @('codex','cursor','claude-code')
            Get-WorkflowUpdatePendingSnapshot | Should -BeNullOrEmpty
        }
        @($script:installedClientSets | ForEach-Object { $_ -join ',' }) | Should -Be @('codex','codex','codex,cursor,claude-code')
    }

    It 'retains the pinned target when restarting an untouched <Phase> transaction (new package: <NewPackage>)' -ForEach @(
        @{Phase='prepared';NewPackage=$false},@{Phase='copying';NewPackage=$false},
        @{Phase='prepared';NewPackage=$true},@{Phase='copying';NewPackage=$true}
    ) {
        Invoke-InProjectContext -Root $branch1 -ScriptBlock {
            $snapshot = New-WorkflowUpdateRollbackSnapshot -RelativePaths @(Get-WorkflowUpdateSnapshotRelativePaths -SourceRoot $source.root `
                -Clients @('codex','cursor') -AiRulesPathsAfter @('.fixture-rules/codex.md','.fixture-rules/cursor.md')) `
                -SnapshotParent (Join-Path $script:ProjectRoot '.agent-1c/snapshots/workflow-update')
            Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase prepared `
                -Details @{clientMembership=@{schemaVersion=1;before=@('codex');target=@('codex','cursor')}}
            if ($Phase -eq 'copying') { Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase copying }
            if ($NewPackage) {
                $next = Join-Path $TestDrive ('Следующий источник ' + $Phase)
                Invoke-GitAt -Root $TestDrive -Arguments @('clone','-q','--shared','--',$source.root,$next)
                Invoke-GitAt -Root $next -Arguments @('config','user.name','Next client source')
                Invoke-GitAt -Root $next -Arguments @('config','user.email','next@example.invalid')
                Invoke-GitAt -Root $next -Arguments @('config','maintenance.auto','false')
                Invoke-GitAt -Root $next -Arguments @('config','gc.auto','0')
                Write-Utf8Text -Path (Join-Path $next 'candidate.txt') -Value 'next exact package'
                Invoke-GitAt -Root $next -Arguments @('add','--','candidate.txt')
                Invoke-GitAt -Root $next -Arguments @('commit','-qm','next package')
                $source = [pscustomobject]@{root=$next;commit=(Get-GitOutputAt -Root $next -Arguments @('rev-parse','HEAD')).Trim();repo='fixture';ref='develop';source='path'}
            }
            # Cursor was already pinned, even if it is no longer requested by master.
            Invoke-WorkflowDevelopmentBranchUpdate -Source $source -MasterClients @('codex','claude-code') | Out-Null
            @(Get-AgentTargets) | Should -Be @('codex','cursor','claude-code')
            Get-WorkflowUpdatePendingSnapshot | Should -BeNullOrEmpty
        }
        $script:installedClientSets[0] | Should -Be @('codex','cursor')
        $script:installedClientSets[-1] | Should -Be @('codex','cursor','claude-code')
    }

    It 'preserves the empty write-set when rules are skipped and completes the original addition on retry with rules' {
        Invoke-InProjectContext -Root $branch1 -ScriptBlock {
            $SkipAiRules = $true
            { Invoke-WorkflowDevelopmentBranchUpdate -Source $source -MasterClients @('codex','cursor') } | Should -Throw '*CLIENTS_REQUIRE_RULES*without -SkipAiRules*'
            @(Get-AgentTargets) | Should -Be @('codex')
            Get-WorkflowUpdatePendingSnapshot | Should -BeNullOrEmpty
            $SkipAiRules = $false
            Invoke-WorkflowDevelopmentBranchUpdate -Source $source -MasterClients @('codex','cursor') | Out-Null
            @(Get-AgentTargets) | Should -Be @('codex','cursor')
        }
    }

    It 'preserves a late MCP edit and the original membership snapshot instead of treating it as completed' {
        Invoke-InProjectContext -Root $branch1 -ScriptBlock {
            $script:rolloutFailure = 'post-copy'
            { Invoke-WorkflowDevelopmentBranchUpdate -Source $source -MasterClients @('codex','cursor') } | Should -Throw '*fixture interruption*'
            $pending = Get-WorkflowUpdatePendingSnapshot
            $before = [IO.File]::ReadAllText($pending.receiptPath)
            Write-Utf8Text -Path (Join-Path $script:ProjectRoot '.cursor/mcp.json') -Value '{"mcpServers":{"foreign":{"url":"https://late.invalid"}}}'
            { Invoke-WorkflowDevelopmentBranchUpdate -Source $source -MasterClients @('codex','cursor','claude-code') } | Should -Throw '*WORKFLOW_UPDATE_RECONCILIATION_REQUIRED*'
            [IO.File]::ReadAllText($pending.receiptPath) | Should -BeExactly $before
            Read-Utf8Text -Path (Join-Path $script:ProjectRoot '.cursor/mcp.json') | Should -Match 'https://late.invalid'
            @(Get-AgentTargets) | Should -Not -Contain 'claude-code'
        }
    }

    It 'preserves a client added during planning and completes the additive set after the prepare-drift continuation' {
        Invoke-InProjectContext -Root $branch1 -ScriptBlock {
            Mock Get-AiRulesCandidateInstallInventory {
                param($Checkout,$Tools)
                Set-ProjectAiRulesClients -Clients @('codex','kilocode')
                Invoke-Git @('add','--','.agent-1c/project.json')
                Invoke-Git @('commit','-qm','concurrent branch client')
                foreach ($client in $Tools) { ".fixture-rules/$client.md" }
            }
            { Invoke-WorkflowDevelopmentBranchUpdate -Source $source -MasterClients @('codex','cursor') } | Should -Throw '*WORKFLOW_UPDATE_PREPARE_DRIFT*repeat update-workflow*'
            Read-ProjectConfig
            @(Get-AgentTargets) | Should -Be @('codex','kilocode')
            Get-WorkflowUpdatePendingSnapshot | Should -BeNullOrEmpty
            Mock Get-AiRulesCandidateInstallInventory { param($Checkout,$Tools); foreach ($client in $Tools) { ".fixture-rules/$client.md" } }
            Invoke-WorkflowDevelopmentBranchUpdate -Source $source -MasterClients @('codex','cursor') | Out-Null
            @(Get-AgentTargets) | Should -Be @('codex','kilocode','cursor')
        }
    }

    It 'does not commit an incomplete installer result and finishes the pinned inventory on retry' {
        Invoke-InProjectContext -Root $branch1 -ScriptBlock {
            $head = Get-CurrentCommit
            $script:rolloutFailure = 'omit-rule'
            { Invoke-WorkflowDevelopmentBranchUpdate -Source $source -MasterClients @('codex','cursor') } | Should -Throw '*CLIENTS_INCOMPLETE*planned rules file*cursor*'
            Get-CurrentCommit | Should -BeExactly $head
            (Get-WorkflowUpdatePendingSnapshot).receipt.phase | Should -Be 'post-copy-failed'
            Invoke-WorkflowDevelopmentBranchUpdate -Source $source -MasterClients @('codex','cursor') | Out-Null
            @(Get-AgentTargets) | Should -Be @('codex','cursor')
            Test-Path -LiteralPath (Join-Path $script:ProjectRoot '.fixture-rules/cursor.md') | Should -BeTrue
            Get-WorkflowUpdatePendingSnapshot | Should -BeNullOrEmpty
        }
    }
}
