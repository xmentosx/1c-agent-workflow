BeforeAll { . (Join-Path $PSScriptRoot 'WorkflowUpdateRollback.TestSupport.ps1') }

Describe 'OpenCode project inputs stay rollback-owned and Git-foreign' -Tag 'OpenCodeSnapshot' {
    BeforeAll {
        function New-OpenCodeSnapshotFixture {
            param([string]$Root, [switch]$TrackedConfig, [switch]$Master)
            $utf8 = [Text.UTF8Encoding]::new($false)
            New-Item -ItemType Directory -Force -Path (Join-Path $Root '.agent-1c'), (Join-Path $Root '.opencode/agent'), (Join-Path $Root 'src/cf') | Out-Null
            [IO.File]::WriteAllText((Join-Path $Root '.agent-1c/project.json'), '{"masterBranch":"master","aiRules":{"tools":["opencode"]}}', $utf8)
            [IO.File]::WriteAllText((Join-Path $Root '.ai-rules.json'), '{"tools":["opencode"],"files":{}}', $utf8)
            [IO.File]::WriteAllText((Join-Path $Root '.gitignore'), ".dev.env`n.agent-1c/mcp/`n.agent-1c/snapshots/`n.agent-1c/tmp/`n.agent-1c/runs/`nopencode.json`nopencode.jsonc`n.opencode/opencode.json`n.opencode/opencode.jsonc`n", $utf8)
            [IO.File]::WriteAllText((Join-Path $Root 'AGENT-INSTALL.md'), 'old package', $utf8)
            [IO.File]::WriteAllText((Join-Path $Root '.opencode/agent/itl-routine.md'), 'old managed agent', $utf8)
            [IO.File]::WriteAllText((Join-Path $Root 'src/cf/Модуль.bsl'), 'business baseline', $utf8)
            [IO.File]::WriteAllText((Join-Path $Root 'opencode.jsonc'), "{`r`n // Комментарий пользователя`r`n `"mcp`": {},`r`n}`r`n", [Text.UTF8Encoding]::new($true))
            [IO.File]::WriteAllText((Join-Path $Root '.opencode/opencode.json'), '{"theme":"user-theme","mcp":{}}', $utf8)
            $branch = if ($Master) { 'master' } else { 'itldev/opencode-snapshot' }
            & git -C $Root init -q -b $branch; $LASTEXITCODE | Should -Be 0
            & git -C $Root config user.name 'OpenCode snapshot fixture'
            & git -C $Root config user.email 'opencode@example.invalid'
            & git -C $Root config core.autocrlf false
            & git -C $Root add --all; $LASTEXITCODE | Should -Be 0
            if ($TrackedConfig) { & git -C $Root add -f -- opencode.jsonc .opencode/opencode.json; $LASTEXITCODE | Should -Be 0 }
            & git -C $Root commit -qm baseline; $LASTEXITCODE | Should -Be 0
            return $Root
        }
    }

    It 'captures four physical inputs including absence and completes exact rollback after a late edit is preserved' {
        $root = New-OpenCodeSnapshotFixture -Root (Join-Path $TestDrive 'Четыре слоя и точный откат')
        . $helperPath -ProjectRoot $root -Action help *> $null
        Set-RollbackSourceFixture
        $relative = @(Get-WorkflowUpdateClientConfigRelativePaths -Client opencode)
        $relative | Should -Be @('opencode.json','opencode.jsonc','.opencode/opencode.json','.opencode/opencode.jsonc')
        $inventory = @(Get-WorkflowUpdateSnapshotRelativePaths -SourceRoot $repoRoot)
        foreach ($path in $relative) { $inventory | Should -Contain $path }
        $migrationInventory = @(Get-AiRulesMigrationSnapshotRelativePaths)
        foreach ($path in $relative) { $migrationInventory | Should -Contain $path }
        $before = @{}; foreach ($path in $relative) { $before[$path] = Get-ItlMcpFileState -Path (Join-Path $root $path) }
        $source = [pscustomobject]@{ root=$repoRoot;commit=('b'*40);ref='master';repo='fixture';source='path' }
        $snapshot = New-WorkflowUpdateRollbackSnapshot -RelativePaths (@('AGENT-INSTALL.md') + $relative) -SnapshotParent (Join-Path $root '.agent-1c/snapshots/workflow-update')
        Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase prepared
        foreach ($path in $relative) { [IO.File]::WriteAllText((Join-Path $root $path), '{"mcp":{"owned":{"url":"https://candidate.invalid"}}}', [Text.UTF8Encoding]::new($false)) }
        [IO.File]::WriteAllText((Join-Path $root 'AGENT-INSTALL.md'), 'new package', [Text.UTF8Encoding]::new($false))
        $plan = New-WorkflowBranchCommitPlan -ManagedPathSpecs (@('AGENT-INSTALL.md','.opencode') + $relative)
        $plan.managedPaths | Should -Be @('AGENT-INSTALL.md')
        Save-WorkflowBranchCommitPlanReceipt -Snapshot $snapshot -Plan $plan
        Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase branch-commit-ready
        Apply-WorkflowBranchCommitPlan -Plan (Read-WorkflowBranchCommitPlanReceipt -Snapshot $snapshot) | Out-Null
        Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase post-copy-complete
        $retained = Retain-WorkflowUpdateRollbackSnapshot -Snapshot $snapshot
        $id = (Split-Path -Leaf $retained).Substring('itl-workflow-update-completed-'.Length)
        $business = Join-Path $root 'src/cf/Модуль.bsl'
        [IO.File]::WriteAllText($business, 'business staged', [Text.UTF8Encoding]::new($false))
        & git -C $root add -- 'src/cf/Модуль.bsl'; $LASTEXITCODE | Should -Be 0
        $businessIndex = @(Get-GitPathList -Arguments @('ls-files','--stage','-z','--','src/cf/Модуль.bsl'))
        [IO.File]::WriteAllText($business, 'business unstaged', [Text.UTF8Encoding]::new($false))
        $latePath = Join-Path $root '.opencode/opencode.jsonc'
        $candidate = [IO.File]::ReadAllBytes($latePath)
        [IO.File]::WriteAllText($latePath, '// поздняя пользовательская правка', [Text.UTF8Encoding]::new($true))
        $lateHash = (Get-FileHash -LiteralPath $latePath).Hash
        { Restore-CompletedWorkflowUpdate -SnapshotId $id } | Should -Throw '*WORKFLOW_UPDATE_RECONCILIATION_REQUIRED*'
        (Get-FileHash -LiteralPath $latePath).Hash | Should -Be $lateHash
        $preserved = Join-Path $root '.agent-1c/snapshots/preserved-user-config.txt'
        [IO.File]::WriteAllBytes($preserved, [IO.File]::ReadAllBytes($latePath))
        # The user's late edit is preserved separately; restore only the exact
        # recorded candidate bytes, then repeat the original public rollback.
        [IO.File]::WriteAllBytes($latePath, $candidate)
        Restore-CompletedWorkflowUpdate -SnapshotId $id
        foreach ($path in $relative) { Get-ItlMcpFileState -Path (Join-Path $root $path) | Should -Be $before[$path] }
        (Get-FileHash -LiteralPath $preserved).Hash | Should -Be $lateHash
        [IO.File]::ReadAllText((Join-Path $root 'AGENT-INSTALL.md')) | Should -Be 'old package'
        [IO.File]::ReadAllText($business) | Should -Be 'business unstaged'
        @(Get-GitPathList -Arguments @('ls-files','--stage','-z','--','src/cf/Модуль.bsl')) | Should -Be $businessIndex
        $restoredHead = Get-CurrentCommit
        Restore-CompletedWorkflowUpdate -SnapshotId $id
        Get-CurrentCommit | Should -Be $restoredHead
        Get-WorkflowUpdatePendingSnapshot | Should -BeNullOrEmpty
    }

    It 'preserves tracked read-only layer bytes and staged entries even beneath a managed directory spec' {
        $root = New-OpenCodeSnapshotFixture -Root (Join-Path $TestDrive 'Чужой tracked слой с пробелом') -TrackedConfig
        . $helperPath -ProjectRoot $root -Action help *> $null
        $config = Join-Path $root '.opencode/opencode.json'
        [IO.File]::WriteAllText($config, '{"theme":"staged user theme"}', [Text.UTF8Encoding]::new($false))
        & git -C $root add -- .opencode/opencode.json; $LASTEXITCODE | Should -Be 0
        $indexBefore = @(Get-GitPathList -Arguments @('ls-files','--stage','-z','--','.opencode/opencode.json','opencode.jsonc'))
        [IO.File]::WriteAllText($config, '{"theme":"unstaged user theme"}', [Text.UTF8Encoding]::new($false))
        $hashBefore = (Get-FileHash -LiteralPath $config).Hash
        [IO.File]::WriteAllText((Join-Path $root '.opencode/agent/itl-routine.md'), 'new managed agent', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $root 'AGENT-INSTALL.md'), 'new package', [Text.UTF8Encoding]::new($false))
        $specs = @('AGENT-INSTALL.md','.opencode') + @(Get-WorkflowUpdateClientConfigRelativePaths -Client opencode)
        $plan = New-WorkflowBranchCommitPlan -ManagedPathSpecs $specs
        @($plan.managedPaths | Sort-Object) | Should -Be @('.opencode/agent/itl-routine.md','AGENT-INSTALL.md')
        Apply-WorkflowBranchCommitPlan -Plan $plan | Out-Null
        (Get-FileHash -LiteralPath $config).Hash | Should -Be $hashBefore
        @(Get-GitPathList -Arguments @('ls-files','--stage','-z','--','.opencode/opencode.json','opencode.jsonc')) | Should -Be $indexBefore
        (& git -C $root show 'HEAD:.opencode/opencode.json') | Should -Be '{"theme":"user-theme","mcp":{}}'
        # Existing no-op finalization must not refresh or reject the foreign index.
        Apply-WorkflowBranchCommitPlan -Plan (New-WorkflowBranchCommitPlan -ManagedPathSpecs $specs) | Out-Null
        @(Get-GitPathList -Arguments @('ls-files','--stage','-z','--','.opencode/opencode.json','opencode.jsonc')) | Should -Be $indexBefore
    }

    It 'keeps the master dirty guard strict without adopting a captured config and continues after scoped reconciliation' {
        $root = New-OpenCodeSnapshotFixture -Root (Join-Path $TestDrive 'Master и чужая конфигурация') -TrackedConfig -Master
        . $helperPath -ProjectRoot $root -Action help *> $null
        $config = Join-Path $root '.opencode/opencode.json'
        $before = [IO.File]::ReadAllBytes($config)
        $snapshot = New-WorkflowUpdateRollbackSnapshot -RelativePaths @('AGENT-INSTALL.md','.opencode') -SnapshotParent (Join-Path $root '.agent-1c/snapshots/workflow-update')
        # Supply the same positive snapshot directory contribution as the real
        # master owner. This must not redefine its child config as Git-owned.
        Mock Get-WorkflowUpdateManagedPathSpecs { @($snapshot.records | ForEach-Object relativePath) }
        [IO.File]::WriteAllText($config, '{"theme":"late user theme"}', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $root 'AGENT-INSTALL.md'), 'new package', [Text.UTF8Encoding]::new($false))
        $head = Get-CurrentCommit; $index = @(Get-GitPathList -Arguments @('ls-files','--stage','-z'))
        $source = [pscustomobject]@{root=$repoRoot;commit=('b'*40);ref='master';repo='fixture';source='path'}
        { Commit-WorkflowUpdate -Source $source } | Should -Throw '*outside its managed allowlist*'
        Get-CurrentCommit | Should -Be $head
        @(Get-GitPathList -Arguments @('ls-files','--stage','-z')) | Should -Be $index
        $preserved = Join-Path $root '.agent-1c/snapshots/master-user-config.txt'
        [IO.File]::WriteAllBytes($preserved, [IO.File]::ReadAllBytes($config))
        [IO.File]::WriteAllBytes($config, $before)
        (Commit-WorkflowUpdate -Source $source).created | Should -BeTrue
        [IO.File]::ReadAllText($preserved) | Should -Be '{"theme":"late user theme"}'
        @(Get-GitPathList -Arguments @('ls-files','--stage','-z','--','.opencode/opencode.json','opencode.jsonc')) | Should -HaveCount 2
        @(Get-GitPathList -Arguments @('diff-tree','--no-commit-id','--name-only','-r','-z','HEAD')) | Should -Be @('AGENT-INSTALL.md')
    }

    It 'admits missing inputs in the existing parent receipt before a failed child and retains exact rollback bytes' {
        $root = New-OpenCodeSnapshotFixture -Root (Join-Path $TestDrive 'Старый parent OpenCode с пробелом')
        . $helperPath -ProjectRoot $root -Action help *> $null
        $source = [pscustomobject]@{root=$repoRoot;commit=('b'*40);ref='master';repo='fixture';source='path'}
        $snapshot = New-WorkflowUpdateRollbackSnapshot -RelativePaths @('AGENT-INSTALL.md','opencode.json') -SnapshotParent (Join-Path $root '.agent-1c/snapshots/workflow-update')
        Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase post-copy-running
        $receiptBefore = (Get-FileHash -LiteralPath (Get-WorkflowUpdatePendingSnapshot).receiptPath).Hash
        { Invoke-WorkflowPackageFilePostCopy } | Should -Throw '*WORKFLOW_UPDATE_MCP_LEGACY_SNAPSHOT*'
        $script:RunRequiredAction | Should -Match '\-Recovery update'
        (Get-FileHash -LiteralPath (Get-WorkflowUpdatePendingSnapshot).receiptPath).Hash | Should -Be $receiptBefore
        $relative = @(Get-WorkflowUpdateClientConfigRelativePaths -Client opencode)
        $before = @{};foreach($path in $relative){$before[$path]=Get-ItlMcpFileState -Path (Join-Path $root $path)}
        Mock Invoke-Agent1cFreshProcess {
            Assert-WorkflowUpdateMcpConfigSnapshot -Pending (Get-WorkflowUpdatePendingSnapshot)
            [IO.File]::WriteAllText((Join-Path $script:ProjectRoot '.opencode/opencode.jsonc'), '{"mcp":{"fixture":{}}}', [Text.UTF8Encoding]::new($false))
            [pscustomobject]@{exitCode=1}
        }
        { Complete-WorkflowUpdatePostCopyFromSnapshot -Snapshot $snapshot -Source $source } | Should -Throw '*Fresh workflow post-copy process failed*'
        $pending = Get-WorkflowUpdatePendingSnapshot
        Assert-WorkflowUpdateSnapshotCurrentState -Pending $pending
        foreach($path in $relative){ @($pending.snapshot.records | ForEach-Object relativePath) | Should -Contain $path; $pending.receipt.beforePathState.PSObject.Properties.Name | Should -Contain $path }
        Restore-WorkflowUpdateRollbackSnapshot -Snapshot $pending.snapshot
        foreach($path in $relative){Get-ItlMcpFileState -Path (Join-Path $root $path) | Should -Be $before[$path]}
    }

    It 'scopes <Kind> target config selection to this invocation and restores the previous executor context on failure' -ForEach @(@{Kind='new';Expected=4},@{Kind='old';Expected=1}) {
        $root = New-OpenCodeSnapshotFixture -Root (Join-Path $TestDrive ('Scoped target с пробелом ' + $Kind))
        . $helperPath -ProjectRoot $root -Action help *> $null
        $sourceRoot = $repoRoot
        if ($Kind -eq 'old') {
            $sourceRoot = Join-Path $TestDrive 'Old scoped source'
            New-Item -ItemType Directory -Force -Path $sourceRoot | Out-Null
        }
        $source = [pscustomobject]@{root=$sourceRoot;commit=('a'*40);ref='master';repo='fixture';source='path'}
        $snapshot = New-WorkflowUpdateRollbackSnapshot -RelativePaths (@('AGENT-INSTALL.md') + @(Get-WorkflowUpdateClientConfigRelativePaths -Client opencode)) -SnapshotParent (Join-Path $root '.agent-1c/snapshots/workflow-update')
        Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase post-copy-running
        Add-WorkflowDotEnvPolicySnapshotPaths -Snapshot $snapshot -Pending (Get-WorkflowUpdatePendingSnapshot)
        # This fixture delegates dotenv policy and injects failure at the next owner.
        # Migration and rollback are exercised by their policy contract fixtures.
        Mock Invoke-VerificationModelPolicyTransition {}
        Mock Restore-UnfinishedForkCopiedMcpOwnership { throw ('observed path count=' + @(Get-ItlOpenCodeOperationConfigPaths).Count) }
        if ($Kind -eq 'old') { $script:ItlOpenCodeOperationConfigPathsMode = 'layered' }
        else { Remove-Variable -Name ItlOpenCodeOperationConfigPathsMode -Scope Script -ErrorAction SilentlyContinue }
        try {
            { Invoke-WorkflowPackageFilePostCopy } | Should -Throw ('*observed path count=' + $Expected + '*')
            if ($Kind -eq 'old') { $script:ItlOpenCodeOperationConfigPathsMode | Should -Be 'layered' }
            else { Get-Variable -Name ItlOpenCodeOperationConfigPathsMode -Scope Script -ErrorAction SilentlyContinue | Should -BeNullOrEmpty }
        } finally { Remove-Variable -Name ItlOpenCodeOperationConfigPathsMode -Scope Script -ErrorAction SilentlyContinue }
    }
    It 'does not expand a pinned old target from the newer recovery executor or a comment resembling its capability' {
        $root = New-OpenCodeSnapshotFixture -Root (Join-Path $TestDrive 'Закреплённый старый target')
        . $helperPath -ProjectRoot $root -Action help *> $null
        $oldSource = Join-Path $TestDrive 'Старый source с пробелом'
        $oldOwner = Join-Path $oldSource '.agents/skills/1c-workflow/scripts/lib/agent-1c.client-adapters.ps1'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $oldOwner) | Out-Null
        [IO.File]::WriteAllText($oldOwner, '# function Get-ItlClientMcpConfigPaths { }', [Text.UTF8Encoding]::new($true))
        Test-WorkflowSourceLayeredOpenCodeConfig -SourceRoot $oldSource | Should -BeFalse
        $source = [pscustomobject]@{root=$oldSource;commit=('a'*40);ref='master';repo='fixture';source='path'}
        $snapshot = New-WorkflowUpdateRollbackSnapshot -RelativePaths @('AGENT-INSTALL.md','opencode.json') -SnapshotParent (Join-Path $root '.agent-1c/snapshots/workflow-update')
        Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase post-copy-running
        Add-WorkflowDotEnvPolicySnapshotPaths -Snapshot $snapshot -Pending (Get-WorkflowUpdatePendingSnapshot)
        Assert-WorkflowUpdateMcpConfigSnapshot -Pending (Get-WorkflowUpdatePendingSnapshot)
        @($snapshot.records | ForEach-Object relativePath) | Should -Not -Contain 'opencode.jsonc'
        @($snapshot.records | ForEach-Object relativePath) | Should -Not -Contain '.opencode/opencode.json'
        @($snapshot.records | ForEach-Object relativePath) | Should -Not -Contain '.opencode/opencode.jsonc'
    }
}
