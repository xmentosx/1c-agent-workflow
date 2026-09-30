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
