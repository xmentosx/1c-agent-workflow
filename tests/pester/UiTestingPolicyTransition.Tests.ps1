BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $helperPath = Join-Path $repoRoot '.agents\skills\1c-workflow\scripts\agent-1c.ps1'
    function Set-TestUiTestingRulesFixture {
        param([string]$Root, [bool]$Supported)
        $files = [ordered]@{}
        foreach ($item in @(
            @{Target='.codex/rules/dev-standards-env.md'; Source='content/rules/dev-standards-env.md'}
        )) {
            $path = Join-Path $Root $item.Target
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
            $text = if ($Supported) { '| `{UI_TESTING}` | UI-testing mode: `essential` \| `auto` \| `manual` \| `off` | Defaulted | Empty = `essential` |' }
            else { '| `{UI_TESTING}` | UI-testing mode: `auto` \| `manual` \| `off` | Defaulted | Empty = `manual` |' }
            [IO.File]::WriteAllText($path, ($text + "`n"), [Text.UTF8Encoding]::new($false))
            $files[$item.Target] = @{source=$item.Source; installedHash=(Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant(); userModified=$false}
        }
        [IO.File]::WriteAllText((Join-Path $Root '.ai-rules.json'), ((@{version='owned-test-ui';files=$files} | ConvertTo-Json -Depth 8)+"`n"), [Text.UTF8Encoding]::new($false))
    }
}

Describe 'One-time essential UI policy transition' {
    It 'migrates manual in each existing root and preserves a later manual choice' {
        $root = Join-Path $TestDrive 'Проект UI с пробелом'
        $branch = Join-Path $TestDrive 'Ветка UI с пробелом'
        New-Item -ItemType Directory -Force -Path $root, $branch | Out-Null
        foreach ($path in @($root, $branch)) {
            [IO.File]::WriteAllText((Join-Path $path '.dev.env'), "UI_TESTING=MANUAL`r`nITL_VANESSA_TESTING=auto`r`nOTHER=Кириллица с пробелом`r`n", [Text.UTF8Encoding]::new($false))
        }
        $result = & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            function Get-DependencyLockEntry { param($Name) @{ commit = ('b' * 40) } }
            $master = Invoke-UiTestingPolicyTransition -EvaluatePackageEligibility -PreviousWorkflowCommit ('a' * 40)
            $branchResult = Invoke-InProjectContext -Root $branch -ScriptBlock {
                Invoke-UiTestingPolicyTransition -EvaluatePackageEligibility -PreviousWorkflowCommit ('a' * 40)
            }
            $path = Get-UiTestingPolicyReceiptPath
            $hash = (Get-FileHash -LiteralPath $path).Hash
            $text = Read-Utf8Text -Path (Join-Path $root '.dev.env')
            Write-Utf8TextAtomic -Path (Join-Path $root '.dev.env') -Value ($text.Replace('UI_TESTING=essential', 'UI_TESTING=manual'))
            Invoke-UiTestingPolicyTransition -EvaluatePackageEligibility -PreviousWorkflowCommit ('b' * 40) | Out-Null
            [pscustomobject]@{master=$master; branch=$branchResult; firstText=$text; finalText=(Read-Utf8Text -Path (Join-Path $root '.dev.env')); unchangedReceipt=((Get-FileHash -LiteralPath $path).Hash -ceq $hash)}
        }
        $result.master.converted | Should -BeTrue
        $result.branch.converted | Should -BeTrue
        $result.firstText | Should -Be "UI_TESTING=essential`r`nITL_VANESSA_TESTING=auto`r`nOTHER=Кириллица с пробелом`r`n"
        $result.finalText | Should -Match '(?m)^UI_TESTING=manual\r?$'
        $result.unchangedReceipt | Should -BeTrue
    }

    It 'preserves an explicit <Value> in an existing scope' -TestCases @(
        @{Value='off'}, @{Value='auto'}, @{Value='essential'}, @{Value='invalid'}
    ) {
        param($Value)
        $root = Join-Path $TestDrive ('Сохранённый UI ' + $Value)
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        $before = "UI_TESTING=$Value`nSECRET=keep`n"
        [IO.File]::WriteAllText((Join-Path $root '.dev.env'), $before, [Text.UTF8Encoding]::new($false))
        $result = & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            function Get-DependencyLockEntry { param($Name) @{ commit = ('b' * 40) } }
            $receipt = Invoke-UiTestingPolicyTransition -EvaluatePackageEligibility -PreviousWorkflowCommit ('a' * 40)
            [pscustomobject]@{receipt=$receipt; text=(Read-Utf8Text -Path (Join-Path $root '.dev.env'))}
        }
        $result.receipt.status | Should -Be 'completed'
        $result.receipt.converted | Should -BeFalse
        $result.text | Should -Be $before
    }

    It 'sets a persisted essential default for a new wizard scope with <Kind> value' -TestCases @(
        @{Kind='missing'; Line=''}, @{Kind='empty'; Line="UI_TESTING=`n"}
    ) {
        param($Kind, $Line)
        $root = Join-Path $TestDrive ('Новый UI ' + $Kind)
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        [IO.File]::WriteAllText((Join-Path $root '.dev.env'), ($Line + "OTHER=keep`n"), [Text.UTF8Encoding]::new($false))
        $result = & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            function Get-DependencyLockEntry { param($Name) @{ commit = ('b' * 40) } }
            $receipt = Invoke-UiTestingPolicyTransition -NewScope
            [pscustomobject]@{receipt=$receipt; text=(Read-Utf8Text -Path (Join-Path $root '.dev.env'))}
        }
        $result.receipt.status | Should -Be 'completed'
        $result.receipt.scopeKind | Should -Be 'new'
        $result.receipt.afterValue | Should -Be 'essential'
        $result.text | Should -Match '(?m)^UI_TESTING=essential\r?$'
        $result.text | Should -Match '(?m)^OTHER=keep\r?$'
    }

    It 'preserves explicit manual in a new scope and when its new branch inherits policy' {
        $root = Join-Path $TestDrive 'Новый manual UI'
        $branch = Join-Path $TestDrive 'Наследованный manual UI'
        New-Item -ItemType Directory -Force -Path $root, $branch | Out-Null
        [IO.File]::WriteAllText((Join-Path $root '.dev.env'), "UI_TESTING=manual`nOTHER=branch`n", [Text.UTF8Encoding]::new($false))
        $result = & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            function Get-DependencyLockEntry { param($Name) @{ commit = ('b' * 40) } }
            Invoke-UiTestingPolicyTransition -NewScope | Out-Null
            Copy-DotEnvToWorktree -WorktreePath $branch
            Invoke-InProjectContext -Root $branch -ScriptBlock {
                $receipt = Invoke-UiTestingPolicyTransition -EvaluatePackageEligibility -PreviousWorkflowCommit ('a' * 40)
                [pscustomobject]@{receipt=$receipt; text=(Read-Utf8Text -Path (Join-Path $script:ProjectRoot '.dev.env')); envHash=(Get-FileHash -LiteralPath (Join-Path $script:ProjectRoot '.dev.env')).Hash.ToLowerInvariant()}
            }
        }
        $result.text | Should -Be "UI_TESTING=manual`nOTHER=branch`n"
        $result.receipt.converted | Should -BeFalse
        $result.receipt.scopeKind | Should -Be 'new'
        $result.receipt.afterSha256 | Should -Be $result.envHash
        $result.receipt.inheritedReceiptSha256 | Should -Match '^[a-f0-9]{64}$'
    }

    It 'restores UI policy and its receipt together through the existing update rollback' {
        $root = Join-Path $TestDrive 'Откат UI с пробелом'
        New-Item -ItemType Directory -Force -Path (Join-Path $root '.agent-1c') | Out-Null
        $before = "UI_TESTING=manual`nITL_VANESSA_TESTING=manual`n"
        [IO.File]::WriteAllText((Join-Path $root '.dev.env'), $before, [Text.UTF8Encoding]::new($false))
        $result = & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            function Get-DependencyLockEntry { param($Name) @{ commit = ('b' * 40) } }
            $snapshot = New-WorkflowUpdateRollbackSnapshot -RelativePaths @('.dev.env', '.agent-1c/migrations/ui-testing-essential-v1.json') -SnapshotParent (Join-Path $root '.agent-1c/snapshots/workflow-update')
            Invoke-UiTestingPolicyTransition -EvaluatePackageEligibility -PreviousWorkflowCommit ('a' * 40) | Out-Null
            $during = Read-Utf8Text -Path (Join-Path $root '.dev.env')
            Restore-WorkflowUpdateRollbackSnapshot -Snapshot $snapshot
            Remove-WorkflowUpdateRollbackSnapshot -Snapshot $snapshot
            [pscustomobject]@{during=$during; text=(Read-Utf8Text -Path (Join-Path $root '.dev.env')); receiptExists=(Test-Path -LiteralPath (Get-UiTestingPolicyReceiptPath))}
        }
        $result.during | Should -Be "UI_TESTING=essential`nITL_VANESSA_TESTING=manual`n"
        $result.text | Should -Be $before
        $result.receiptExists | Should -BeFalse
    }

    It 'completes a transition interrupted after the env write without saving other env values' {
        $root = Join-Path $TestDrive 'Прерванный UI'
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        [IO.File]::WriteAllText((Join-Path $root '.dev.env'), "UI_TESTING=manual`nSECRET=private-value`n", [Text.UTF8Encoding]::new($false))
        $result = & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            function Get-DependencyLockEntry { param($Name) @{ commit = ('b' * 40) } }
            Invoke-UiTestingPolicyTransition | Out-Null
            $path = Get-UiTestingPolicyReceiptPath
            $receipt = Read-Utf8Text -Path $path | ConvertFrom-Json
            $receipt.status = 'applying'
            Write-Utf8TextAtomic -Path $path -Value ($receipt | ConvertTo-Json -Depth 6)
            $resumed = Invoke-UiTestingPolicyTransition
            [pscustomobject]@{receipt=$resumed; receiptText=(Read-Utf8Text -Path $path)}
        }
        $result.receipt.status | Should -Be 'completed'
        $result.receiptText | Should -Not -Match 'private-value|afterText'
    }

    It 'does not overwrite an edit after an interrupted transition' {
        $root = Join-Path $TestDrive 'Конфликт UI'
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        [IO.File]::WriteAllText((Join-Path $root '.dev.env'), "UI_TESTING=manual`n", [Text.UTF8Encoding]::new($false))
        $result = & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            function Get-DependencyLockEntry { param($Name) @{ commit = ('b' * 40) } }
            Invoke-UiTestingPolicyTransition | Out-Null
            $path = Get-UiTestingPolicyReceiptPath
            $receipt = Read-Utf8Text -Path $path | ConvertFrom-Json
            $receipt.status = 'applying'
            Write-Utf8TextAtomic -Path $path -Value ($receipt | ConvertTo-Json -Depth 6)
            Write-Utf8TextAtomic -Path (Join-Path $root '.dev.env') -Value "UI_TESTING=off`n"
            $errorText = ''
            try { Invoke-UiTestingPolicyTransition | Out-Null } catch { $errorText=$_.Exception.Message }
            [pscustomobject]@{errorText=$errorText; text=(Read-Utf8Text -Path (Join-Path $root '.dev.env'))}
        }
        $result.errorText | Should -Match 'UI_TESTING_POLICY_CONFLICT'
        $result.text | Should -Be "UI_TESTING=off`n"
    }

    It 'rejects ambiguous duplicate assignments before writing a receipt or env' {
        $root = Join-Path $TestDrive 'Два значения UI'
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        $before = "UI_TESTING=manual`nUI_TESTING=off`n"
        [IO.File]::WriteAllText((Join-Path $root '.dev.env'), $before, [Text.UTF8Encoding]::new($false))
        $result = & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            function Get-DependencyLockEntry { param($Name) @{ commit = ('b' * 40) } }
            $errorText = ''
            try { Invoke-UiTestingPolicyTransition | Out-Null } catch { $errorText=$_.Exception.Message }
            $blockedText = Read-Utf8Text -Path (Join-Path $root '.dev.env')
            $blockedReceiptExists = Test-Path -LiteralPath (Get-UiTestingPolicyReceiptPath)
            # Resolve the reported duplicate assignment, then repeat the original transition.
            Write-Utf8TextAtomic -Path (Join-Path $root '.dev.env') -Value "UI_TESTING=manual`n"
            $resumed = Invoke-UiTestingPolicyTransition
            [pscustomobject]@{errorText=$errorText; text=$blockedText; receiptExists=$blockedReceiptExists; resumed=$resumed; resumedText=(Read-Utf8Text -Path (Join-Path $root '.dev.env'))}
        }
        $result.errorText | Should -Match 'UI_TESTING_POLICY_AMBIGUOUS'
        $result.text | Should -Be $before
        $result.receiptExists | Should -BeFalse
        $result.resumed.status | Should -Be 'completed'
        $result.resumedText | Should -Be "UI_TESTING=essential`n"
    }
}

Describe 'Essential policy update integration' {
    It 'proves current and snapshot policy without a native command and preserves a later manual choice' {
        $root = Join-Path $TestDrive 'Правило без команды UI с пробелом'
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        Set-TestUiTestingRulesFixture -Root $root -Supported $true
        [IO.File]::WriteAllText((Join-Path $root '.dev.env'), "UI_TESTING=manual`nITL_VANESSA_TESTING=auto`n", [Text.UTF8Encoding]::new($false))
        $result = & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            function Get-DependencyLockEntry { param($Name) @{ commit = ('b' * 40) } }
            $snapshot = New-WorkflowUpdateRollbackSnapshot -RelativePaths @('.ai-rules.json','.codex') -SnapshotParent (Join-Path $root '.agent-1c/snapshots/workflow-update')
            Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source ([pscustomobject]@{root=$repoRoot;commit=('b'*40)}) -Phase post-copy-running
            $beforePathState = (Get-WorkflowUpdatePendingSnapshot).receipt.beforePathState
            $current = Get-AiRulesUiTestingPolicySupportState
            $before = Get-AiRulesUiTestingPolicySupportState -Snapshot $snapshot -BeforePathState $beforePathState
            $commands = @(Get-AiRules1cManifestFileEntries | Where-Object source -eq 'content/commands/uitests.md').Count
            $first = Invoke-UiTestingPolicyTransition -EvaluatePackageEligibility -PreviousWorkflowCommit ('a' * 40)
            $receiptHash = (Get-FileHash -LiteralPath (Get-UiTestingPolicyReceiptPath)).Hash
            $firstText = Read-Utf8Text -Path (Join-Path $root '.dev.env')
            Write-Utf8TextAtomic -Path (Join-Path $root '.dev.env') -Value ($firstText.Replace('UI_TESTING=essential','UI_TESTING=manual'))
            Invoke-UiTestingPolicyTransition -EvaluatePackageEligibility -PreviousWorkflowCommit ('b' * 40) | Out-Null
            [pscustomobject]@{current=$current;before=$before;commands=$commands;first=$first;firstText=$firstText;text=(Read-Utf8Text -Path (Join-Path $root '.dev.env'));sameReceipt=((Get-FileHash -LiteralPath (Get-UiTestingPolicyReceiptPath)).Hash -ceq $receiptHash)}
        }
        $result.commands | Should -Be 0
        $result.current | Should -Be 'supported'
        $result.before | Should -Be 'supported'
        $result.first.converted | Should -BeTrue
        $result.firstText | Should -Be "UI_TESTING=essential`nITL_VANESSA_TESTING=auto`n"
        $result.text | Should -Be "UI_TESTING=manual`nITL_VANESSA_TESTING=auto`n"
        $result.sameReceipt | Should -BeTrue
    }
    It 'keeps user-modified policy ownership unknown even when the installed hash still matches' {
        $root = Join-Path $TestDrive 'Изменённое правило UI с пробелом'
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        Set-TestUiTestingRulesFixture -Root $root -Supported $true
        $manifestPath = Join-Path $root '.ai-rules.json'
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $manifest.files.'.codex/rules/dev-standards-env.md'.userModified = $true
        [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        $result = & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            $entry = @(Get-AiRules1cManifestFileEntries)[0]
            $hashMatches = Test-AiRulesFileMatchesInstalledHash -Path (Join-Path $root $entry.target) -InstalledHash $entry.installedHash
            $snapshot = New-WorkflowUpdateRollbackSnapshot -RelativePaths @('.ai-rules.json','.codex') -SnapshotParent (Join-Path $root '.agent-1c/snapshots/workflow-update')
            Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source ([pscustomobject]@{root=$repoRoot;commit=('b'*40)}) -Phase post-copy-running
            [pscustomobject]@{hashMatches=$hashMatches;current=(Get-AiRulesUiTestingPolicySupportState);before=(Get-AiRulesUiTestingPolicySupportState -Snapshot $snapshot -BeforePathState (Get-WorkflowUpdatePendingSnapshot).receipt.beforePathState)}
        }
        $result.hashMatches | Should -BeTrue
        $result.current | Should -Be 'unknown'
        $result.before | Should -Be 'unknown'
    }
    It 'does not treat an owned UI command as the policy owner when the environment rule is absent' {
        $root = Join-Path $TestDrive 'Команда без правила UI с пробелом'
        $commandPath = Join-Path $root '.agents/skills/uitests/SKILL.md'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $commandPath) | Out-Null
        [IO.File]::WriteAllText($commandPath, '`UI_TESTING=essential`', [Text.UTF8Encoding]::new($false))
        $manifest = @{files=@{'.agents/skills/uitests/SKILL.md'=@{source='content/commands/uitests.md';installedHash=(Get-FileHash -LiteralPath $commandPath).Hash.ToLowerInvariant();userModified=$false}}}
        [IO.File]::WriteAllText((Join-Path $root '.ai-rules.json'), ($manifest | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        $result = & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            $snapshot = New-WorkflowUpdateRollbackSnapshot -RelativePaths @('.ai-rules.json','.agents/skills/uitests') -SnapshotParent (Join-Path $root '.agent-1c/snapshots/workflow-update')
            Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source ([pscustomobject]@{root=$repoRoot;commit=('b'*40)}) -Phase post-copy-running
            [pscustomobject]@{current=(Get-AiRulesUiTestingPolicySupportState);before=(Get-AiRulesUiTestingPolicySupportState -Snapshot $snapshot -BeforePathState (Get-WorkflowUpdatePendingSnapshot).receipt.beforePathState)}
        }
        $result.current | Should -Be 'unsupported'
        $result.before | Should -Be 'unsupported'
    }
    It 'uses the recorded <Kind> target and defers unsupported rules without losing same-package retry' -TestCases @(
        @{Kind='new'; Expected='essential'}, @{Kind='pinned-old'; Expected='manual'}, @{Kind='skip-then-upgrade'; Expected='essential'}, @{Kind='same-supported'; Expected='manual'}, @{Kind='unknown-before'; Expected='manual'}, @{Kind='incomplete-before'; Expected='manual'}, @{Kind='skip-empty'; Expected='essential'}
    ) {
        param($Kind, $Expected)
        $sourceRoot = $repoRoot
        if ($Kind -eq 'pinned-old') {
            $sourceRoot = Join-Path $TestDrive 'Старый закреплённый workflow с пробелом'
            $sourceLifecycle = Join-Path $sourceRoot '.agents/skills/1c-workflow/scripts/lib/agent-1c.lifecycle.ps1'
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $sourceLifecycle) | Out-Null
            [IO.File]::WriteAllText($sourceLifecycle, 'function Invoke-CavemanPolicyTransition { }', [Text.UTF8Encoding]::new($true))
        }
        $root = Join-Path $TestDrive ('Post-copy UI Кириллица с пробелом ' + $Kind)
        New-Item -ItemType Directory -Force -Path (Join-Path $root '.agent-1c') | Out-Null
        $manualText = "UI_TESTING=manual`nITL_VANESSA_TESTING=auto`nTOOL_BROWSER=auto`n"
        $before = if ($Kind -eq 'skip-empty') { $manualText.Replace('UI_TESTING=manual','UI_TESTING=') } else { $manualText }
        [IO.File]::WriteAllText((Join-Path $root '.dev.env'), $before, [Text.UTF8Encoding]::new($false))
        Set-TestUiTestingRulesFixture -Root $root -Supported ($Kind -in @('same-supported','unknown-before','incomplete-before'))
        $result = & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            foreach ($name in @('Ensure-OneCSessionLimitDotEnv','Ensure-Agent1cLifecycleLocksIgnored','Ensure-GitIgnore',
                'Ensure-ItlPinnedOpenSpecGitAttributes','Sync-ItlVanessaLibraries','Update-UserRules',
                'Sync-WorkflowManagedDependencyLockEntries','Install-YAxUnit','Update-RoctupMcp',
                'Sync-VanessaAutomationDependencyLock','Install-VanessaAutomation','Update-VanessaMcpArtifacts',
                'Sync-ItlOnDemandMcpDependencyLock','Install-ItlOnDemandMcp','Assert-AiRulesBaselineMigrationResult',
                'Update-AgentGuidanceBridge','Install-ItlUiTools','Sync-ItlClientSurfaces',
                'Sync-ItlClientUserEnvironment','Sync-KiloItlCommandSurface','Invoke-CavemanPolicyTransition')) {
                Set-Item -Path "Function:$name" -Value { }
            }
            function Get-WorkflowUpdateClientSurfacePaths { @() }
            function Get-AgentTargets { 'codex' }
            function Get-CavemanPolicyPreviousWorkflowCommit { if ($Kind -in @('skip-then-upgrade','same-supported','unknown-before','incomplete-before','skip-empty')) {'new-source'} else {'old-source'} }
            function Get-DependencyLockEntry { param($Name) @{ commit = 'new-source' } }
            function Get-AiRulesMigrationPlan { [pscustomobject]@{status='current'} }
            function Invoke-AiRulesBaselineMigration { [pscustomobject]@{migrated=$false;suppressRegularUpdate=$false} }
            function Update-AiRules1c { Set-TestUiTestingRulesFixture -Root $script:ProjectRoot -Supported $true }
            $source = [pscustomobject]@{root=$sourceRoot;commit=('a' * 40)}
            $ownedPaths = @('.dev.env','.ai-rules.json','.codex','.agents/skills/uitests')
            $snapshot = New-WorkflowUpdateRollbackSnapshot -RelativePaths $ownedPaths -SnapshotParent (Join-Path $root '.agent-1c/snapshots/workflow-update')
            Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase post-copy-running
            Add-WorkflowDotEnvPolicySnapshotPaths -Snapshot $snapshot -Pending (Get-WorkflowUpdatePendingSnapshot)
            $actualSnapshotPaths = @((Get-WorkflowUpdatePendingSnapshot).snapshot.records | ForEach-Object relativePath)
            if ($Kind -eq 'unknown-before') {
                $manifestBackup = @($snapshot.records | Where-Object relativePath -eq '.ai-rules.json')[0].backupPath
                [IO.File]::WriteAllText($manifestBackup, '{invalid-json', [Text.UTF8Encoding]::new($false))
            }
            if ($Kind -eq 'incomplete-before') {
                $pending = Get-WorkflowUpdatePendingSnapshot
                $manifestBackup = @($snapshot.records | Where-Object relativePath -eq '.ai-rules.json')[0].backupPath
                [IO.File]::WriteAllText($manifestBackup, '{"version":"old","files":{}}', [Text.UTF8Encoding]::new($false))
                $pending.receipt.beforePathState.PSObject.Properties.Remove('.ai-rules.json')
                Write-Utf8TextAtomic -Path $pending.receiptPath -Value ($pending.receipt | ConvertTo-Json -Depth 10)
            }
            $skipText = $null
            $skipReceipt = $null
            if ($Kind -in @('skip-then-upgrade','skip-empty')) {
                $SkipAiRules = $true
                Invoke-WorkflowPackageFilePostCopy | Out-Null
                $skipText = Read-Utf8Text -Path (Join-Path $root '.dev.env')
                $skipReceipt = Test-Path -LiteralPath (Get-UiTestingPolicyReceiptPath)
                Remove-WorkflowUpdateRollbackSnapshot -Snapshot $snapshot
                $snapshot = New-WorkflowUpdateRollbackSnapshot -RelativePaths $ownedPaths -SnapshotParent (Join-Path $root '.agent-1c/snapshots/workflow-update')
                Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase post-copy-running
                Add-WorkflowDotEnvPolicySnapshotPaths -Snapshot $snapshot -Pending (Get-WorkflowUpdatePendingSnapshot)
                $SkipAiRules = $false
            }
            $postCopy = @(Invoke-WorkflowPackageFilePostCopy)
            $text = Read-Utf8Text -Path (Join-Path $root '.dev.env')
            $receipt = if (Test-Path -LiteralPath (Get-UiTestingPolicyReceiptPath)) { Read-Utf8Text -Path (Get-UiTestingPolicyReceiptPath) | ConvertFrom-Json } else { $null }
            $laterText = $null
            $unchangedReceipt = $null
            if ($Kind -in @('skip-then-upgrade','skip-empty')) {
                $receiptHash = (Get-FileHash -LiteralPath (Get-UiTestingPolicyReceiptPath)).Hash
                Remove-WorkflowUpdateRollbackSnapshot -Snapshot $snapshot
                Write-Utf8TextAtomic -Path (Join-Path $root '.dev.env') -Value ($text.Replace('UI_TESTING=essential','UI_TESTING=manual'))
                $snapshot = New-WorkflowUpdateRollbackSnapshot -RelativePaths ($ownedPaths + @('.agent-1c/migrations/ui-testing-essential-v1.json')) -SnapshotParent (Join-Path $root '.agent-1c/snapshots/workflow-update')
                Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase post-copy-running
                Invoke-WorkflowPackageFilePostCopy | Out-Null
                $laterText = Read-Utf8Text -Path (Join-Path $root '.dev.env')
                $unchangedReceipt = (Get-FileHash -LiteralPath (Get-UiTestingPolicyReceiptPath)).Hash -ceq $receiptHash
            }
            foreach ($name in @('Get-WorkflowPackageCopyDirectoryPaths','Get-WorkflowPackageCopyFilePaths','Get-WorkflowUpdateEligibleLegacyPaths','Get-WorkflowUpdateManagedPathSpecs')) {
                Set-Item -Path "Function:$name" -Value { @() }
            }
            $snapshotPaths = @(Get-WorkflowUpdateSnapshotRelativePaths)
            Import-DotEnv -Path (Join-Path $root '.dev.env') -Overwrite
            $savedDecision = Get-ItlVerificationExecutionDecision -Component vanessa -Trigger command
            [pscustomobject]@{postCopy=$postCopy; paths=$snapshotPaths; text=$text; receipt=$receipt; actualSnapshotPaths=$actualSnapshotPaths; savedDecision=$savedDecision; skipText=$skipText; skipReceipt=$skipReceipt; laterText=$laterText; unchangedReceipt=$unchangedReceipt}
        }
        @($result.postCopy).Count | Should -Be 1
        $result.paths | Should -Contain '.agent-1c/migrations/ui-testing-essential-v1.json'
        $result.paths | Should -Contain '.dev.env'
        if ($Kind -notin @('pinned-old','unknown-before','incomplete-before')) {
            $result.receipt.status | Should -Be 'completed'
            $result.receipt.previousWorkflowCommit | Should -Be $(if ($Kind -in @('skip-then-upgrade','same-supported','unknown-before','incomplete-before','skip-empty')) {'new-source'} else {'old-source'})
            $result.actualSnapshotPaths | Should -Contain '.agent-1c/migrations/ui-testing-essential-v1.json'
        } else {
            $result.receipt | Should -BeNullOrEmpty
            if ($Kind -eq 'pinned-old') {
                $result.actualSnapshotPaths | Should -Not -Contain '.agent-1c/migrations/ui-testing-essential-v1.json'
            } else {
                $result.actualSnapshotPaths | Should -Contain '.agent-1c/migrations/ui-testing-essential-v1.json'
            }
        }
        if ($Kind -in @('skip-then-upgrade','skip-empty')) {
            $result.skipText | Should -Be $before
            $result.skipReceipt | Should -BeFalse
            $result.receipt.eligibility | Should -Be 'first-supported-ai-rules'
            $result.laterText | Should -Be $manualText
            $result.unchangedReceipt | Should -BeTrue
        }
        if ($Kind -eq 'same-supported') {
            $result.receipt.converted | Should -BeFalse
            $result.receipt.eligibility | Should -Be 'already-current-package'
        }
        if ($Kind -eq 'skip-empty') {
            $result.receipt.beforeValue | Should -Be ''
            $result.receipt.converted | Should -BeTrue
        }
        $result.text | Should -Be "UI_TESTING=$Expected`nITL_VANESSA_TESTING=auto`nTOOL_BROWSER=auto`n"
        $result.savedDecision.run | Should -BeTrue
    }
    It 'uses owned snapshot bytes for prior capability and rejects changed rules and a commented source declaration' {
        $root = Join-Path $TestDrive 'Доказательство UI с пробелом'
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        Set-TestUiTestingRulesFixture -Root $root -Supported $false
        $result = & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            $snapshot = New-WorkflowUpdateRollbackSnapshot -RelativePaths @('.ai-rules.json','.codex','.agents/skills/uitests') -SnapshotParent (Join-Path $root '.agent-1c/snapshots/workflow-update')
            Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source ([pscustomobject]@{root=$repoRoot;commit=('a'*40)}) -Phase post-copy-running
            $beforePathState = (Get-WorkflowUpdatePendingSnapshot).receipt.beforePathState
            Set-TestUiTestingRulesFixture -Root $root -Supported $true
            $current = Test-AiRulesUiTestingPolicySupport
            $before = Get-AiRulesUiTestingPolicySupportState -Snapshot $snapshot -BeforePathState $beforePathState
            $path = Join-Path $root '.codex/rules/dev-standards-env.md'
            [IO.File]::AppendAllText($path, "unowned semantic change`n", [Text.UTF8Encoding]::new($false))
            $altered = Test-AiRulesUiTestingPolicySupport
            $sourceRoot = Join-Path $TestDrive 'Комментарий функции UI'
            $sourcePath = Join-Path $sourceRoot '.agents/skills/1c-workflow/scripts/lib/agent-1c.lifecycle.ps1'
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $sourcePath) | Out-Null
            [IO.File]::WriteAllText($sourcePath, "<#`nfunction Invoke-UiTestingPolicyTransition { }`n#>`nfunction OldPolicy { }`n", [Text.UTF8Encoding]::new($true))
            $comment = Test-WorkflowSourceUiTestingPolicy -SourceRoot $sourceRoot
            Remove-WorkflowUpdateRollbackSnapshot -Snapshot $snapshot
            [pscustomobject]@{current=$current;before=$before;altered=$altered;comment=$comment}
        }
        $result.current | Should -BeTrue
        $result.before | Should -Be 'unsupported'
        $result.altered | Should -BeFalse
        $result.comment | Should -BeFalse
    }
    It 'preserves Unicode and non-setting lines when a quoted manual value is migrated' {
        $root = Join-Path $TestDrive 'Кавычки UI с пробелом'
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        $before = "# Мой режим`r`nUI_TESTING='MANUAL'`r`nCUSTOM=Строка с пробелом`r`n"
        [IO.File]::WriteAllText((Join-Path $root '.dev.env'), $before, [Text.UTF8Encoding]::new($false))
        $result = & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            function Get-DependencyLockEntry { param($Name) @{ commit = 'new-source' } }
            Invoke-UiTestingPolicyTransition -EvaluatePackageEligibility -PreviousWorkflowCommit 'old-source' | Out-Null
            Read-Utf8Text -Path (Join-Path $root '.dev.env')
        }
        $result | Should -Be ($before.Replace('MANUAL', 'essential'))
    }
}

Describe 'Essential policy interruption before the env write' {
    It 'resumes the original <Kind> transition from the applying receipt' -TestCases @(
        @{Kind='existing'; NewScope=$false; FirstSupportedRules=$false; Line="UI_TESTING=manual`n"},
        @{Kind='new-default'; NewScope=$true; FirstSupportedRules=$false; Line="OTHER=keep`n"},
        @{Kind='first-supported-default'; NewScope=$false; FirstSupportedRules=$true; Line="UI_TESTING=`nOTHER=keep`n"}
    ) {
        param($Kind, $NewScope, $FirstSupportedRules, $Line)
        $root = Join-Path $TestDrive ('До записи UI ' + $Kind)
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        [IO.File]::WriteAllText((Join-Path $root '.dev.env'), $Line, [Text.UTF8Encoding]::new($false))
        $result = & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            function Get-DependencyLockEntry { param($Name) @{ commit = 'new-source' } }
            $script:originalAtomicWrite = (Get-Item Function:Write-Utf8TextAtomic).ScriptBlock
            $script:failEnvWrite = $true
            $script:uiEnvPath = Join-Path $root '.dev.env'
            function Write-Utf8TextAtomic {
                param([string]$Path, [string]$Value)
                if ($Path -eq $script:uiEnvPath -and $script:failEnvWrite) { throw 'fixture-env-write-interruption' }
                & $script:originalAtomicWrite -Path $Path -Value $Value
            }
            $errorText=''
            try { Invoke-UiTestingPolicyTransition -NewScope:$NewScope -FirstSupportedRules:$FirstSupportedRules | Out-Null } catch { $errorText=$_.Exception.Message }
            $pending = Read-Utf8Text -Path (Get-UiTestingPolicyReceiptPath) | ConvertFrom-Json
            $beforeResume = Read-Utf8Text -Path $script:uiEnvPath
            $script:failEnvWrite = $false
            $completed = Invoke-UiTestingPolicyTransition -NewScope:$NewScope
            [pscustomobject]@{errorText=$errorText; pending=$pending; beforeResume=$beforeResume; completed=$completed; text=(Read-Utf8Text -Path $script:uiEnvPath)}
        }
        $result.errorText | Should -Match 'fixture-env-write-interruption'
        $result.pending.status | Should -Be 'applying'
        $result.beforeResume | Should -Be $Line
        $result.completed.status | Should -Be 'completed'
        $result.text | Should -Match '(?m)^UI_TESTING=essential\r?$'
    }

    It 'reports each updated scope without disclosing other dotenv values' {
        $root = Join-Path $TestDrive 'Отчёт UI master'
        $branch = Join-Path $TestDrive 'Отчёт UI branch'
        New-Item -ItemType Directory -Force -Path $root, $branch | Out-Null
        [IO.File]::WriteAllText((Join-Path $root '.dev.env'), "UI_TESTING=manual`nSECRET=private-value`n", [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $branch '.dev.env'), "UI_TESTING=off`nSECRET=private-value`n", [Text.UTF8Encoding]::new($false))
        $result = & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            function Get-DependencyLockEntry { param($Name) @{ commit = 'new-source' } }
            Invoke-UiTestingPolicyTransition -EvaluatePackageEligibility -PreviousWorkflowCommit 'old-source' | Out-Null
            Invoke-InProjectContext -Root $branch -ScriptBlock {
                Invoke-UiTestingPolicyTransition -EvaluatePackageEligibility -PreviousWorkflowCommit 'old-source' | Out-Null
            }
            function Write-AndSetRunUserReport { param($Lines) $script:capturedReport=@($Lines) -join "`n" }
            Write-WorkflowUpdateFollowUp -Source ([pscustomobject]@{ref='test';commit='new-source';source='local'}) -CommitResult ([pscustomobject]@{commit='project-head';created=$true}) -BranchReport ([pscustomobject]@{roots=@([pscustomobject]@{branch='itldev/test';status='completed';root=$branch})})
            $script:capturedReport
        }
        $result | Should -Match 'UI_TESTING master: manual → essential'
        $result | Should -Match 'UI_TESTING: сохранён off'
        $result | Should -Not -Match 'private-value'
    }
}

Describe 'Legacy parent handoff and UTF8 env boundary' {
    It 'continues an old snapshot through the new parent and rolls back its newly admitted receipt' {
        $root = Join-Path $TestDrive 'Старый updater UI с пробелом'
        New-Item -ItemType Directory -Force -Path (Join-Path $root '.agent-1c') | Out-Null
        $before = "UI_TESTING=manual`nOTHER=Кириллица с пробелом`n"
        [IO.File]::WriteAllText((Join-Path $root '.dev.env'), $before, [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $root '.agent-1c/dependency-lock.json'), ('{"dependencies":{"workflowPackage":{"commit":"'+('a'*40)+'"}}}'), [Text.UTF8Encoding]::new($false))
        $result = & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            function Get-DependencyLockEntry { param($Name) @{commit=('b'*40)} }
            $source = [pscustomobject]@{root=$repoRoot;commit=('b'*40)}
            # The old parent's original snapshot knows env/lock but not policy receipts.
            $snapshot = New-WorkflowUpdateRollbackSnapshot -RelativePaths @('.dev.env','.agent-1c/dependency-lock.json') -SnapshotParent (Join-Path $root '.agent-1c/snapshots/workflow-update')
            Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase post-copy-running
            $blocked=''
            try { Invoke-WorkflowPackageFilePostCopy | Out-Null } catch { $blocked=$_.Exception.Message }
            $blockedText=Read-Utf8Text -Path (Join-Path $root '.dev.env')
            $blockedReceipt=Test-Path -LiteralPath (Get-UiTestingPolicyReceiptPath)
            function Invoke-Agent1cFreshProcess {
                param($AdditionalArguments,[switch]$ReturnExitStatus)
                Assert-UiTestingPolicyUpdateSnapshot
                Invoke-UiTestingPolicyTransition -EvaluatePackageEligibility -PreviousWorkflowCommit (Get-CavemanPolicyPreviousWorkflowCommit) | Out-Null
                # Preserve the real parent error/save path after a child side effect.
                [pscustomobject]@{exitCode=1}
            }
            $failure=''
            try { Complete-WorkflowUpdatePostCopyFromSnapshot -Snapshot $snapshot -Source $source } catch { $failure=$_.Exception.Message }
            $pending=Get-WorkflowUpdatePendingSnapshot
            Assert-WorkflowUpdateSnapshotCurrentState -Pending $pending
            $paths=@($pending.snapshot.records | ForEach-Object relativePath)
            $during=Read-Utf8Text -Path (Join-Path $root '.dev.env')
            Restore-WorkflowUpdateRollbackSnapshot -Snapshot $pending.snapshot
            Remove-WorkflowUpdateRollbackSnapshot -Snapshot $pending.snapshot
            $restored=Read-Utf8Text -Path (Join-Path $root '.dev.env')
            $receiptAfterRollback=Test-Path -LiteralPath (Get-UiTestingPolicyReceiptPath)
            $retry=Invoke-UiTestingPolicyTransition -EvaluatePackageEligibility -PreviousWorkflowCommit ('a'*40)
            [pscustomobject]@{blocked=$blocked;blockedText=$blockedText;blockedReceipt=$blockedReceipt;failure=$failure;paths=$paths;during=$during;restored=$restored;receiptAfterRollback=$receiptAfterRollback;retry=$retry}
        }
        $result.blocked | Should -Match 'UI_TESTING_POLICY_LEGACY_SNAPSHOT'
        $result.blocked | Should -Match 'source|checkout'
        $result.blocked | Should -Match '\-Recovery update'
        $result.blocked | Should -Not -Match '\-Recovery restore'
        $result.blockedText | Should -Be $before
        $result.blockedReceipt | Should -BeFalse
        $result.failure | Should -Match 'Fresh workflow post-copy process failed'
        $result.paths | Should -Contain '.agent-1c/migrations/ui-testing-essential-v1.json'
        $result.paths | Should -Contain '.agent-1c/migrations/caveman-auto-v1.json'
        $result.during | Should -Match '(?m)^UI_TESTING=essential\r?$'
        $result.restored | Should -Be $before
        $result.receiptAfterRollback | Should -BeFalse
        $result.retry.converted | Should -BeTrue
    }

    It 'preserves a UTF8 BOM and exact unrelated bytes in a <Kind> transition and resume' -TestCases @(
        @{Kind='existing';NewScope=$false;Line="UI_TESTING=manual`r`nOTHER=Кириллица с пробелом`r`n"},
        @{Kind='new-default';NewScope=$true;Line="UI_TESTING=`r`nOTHER=Кириллица с пробелом`r`n"}
    ) {
        param($Kind,$NewScope,$Line)
        $root=Join-Path $TestDrive ('BOM UI с пробелом '+$Kind)
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        [IO.File]::WriteAllText((Join-Path $root '.dev.env'),$Line,[Text.UTF8Encoding]::new($true))
        $result=& {
            . $helperPath -ProjectRoot $root -Action help *> $null
            function Get-DependencyLockEntry {param($Name) @{commit=('b'*40)}}
            Invoke-UiTestingPolicyTransition -NewScope:$NewScope | Out-Null
            $path=Get-UiTestingPolicyReceiptPath
            $receipt=Read-Utf8Text -Path $path | ConvertFrom-Json
            $receipt.status='applying'
            Write-Utf8TextAtomic -Path $path -Value ($receipt | ConvertTo-Json -Depth 6)
            $resumed=Invoke-UiTestingPolicyTransition -NewScope:$NewScope
            [pscustomobject]@{receipt=$resumed;bytes=[IO.File]::ReadAllBytes((Join-Path $root '.dev.env'));hash=(Get-FileHash -LiteralPath (Join-Path $root '.dev.env')).Hash.ToLowerInvariant();text=(Read-Utf8Text -Path (Join-Path $root '.dev.env'))}
        }
        @($result.bytes[0..2]) | Should -Be @(239,187,191)
        $result.receipt.status | Should -Be 'completed'
        $result.hash | Should -Be $result.receipt.afterSha256
        $expected = if($NewScope){$Line.Replace('UI_TESTING=','UI_TESTING=essential')}else{$Line.Replace('UI_TESTING=manual','UI_TESTING=essential')}
        $result.text | Should -Be $expected
    }
}

Describe 'Legacy snapshot admission preserves a later writer' {
    It 'keeps the original transaction and a receipt edited after its backup was captured' {
        $root=Join-Path $TestDrive 'Поздняя правка UI snapshot'
        New-Item -ItemType Directory -Force -Path (Join-Path $root '.agent-1c/migrations') | Out-Null
        [IO.File]::WriteAllText((Join-Path $root '.dev.env'),"UI_TESTING=manual`n",[Text.UTF8Encoding]::new($false))
        $cavPath=Join-Path $root '.agent-1c/migrations/caveman-auto-v1.json'
        [IO.File]::WriteAllText($cavPath,'{"schemaVersion":1,"migrationId":"caveman-auto-v1","status":"completed","afterValue":"off"}',[Text.UTF8Encoding]::new($false))
        $later='{"schemaVersion":1,"migrationId":"caveman-auto-v1","status":"completed","afterValue":"later-user-value"}'
        $result=& {
            . $helperPath -ProjectRoot $root -Action help *> $null
            $snapshot=New-WorkflowUpdateRollbackSnapshot -RelativePaths @('.dev.env') -SnapshotParent (Join-Path $root '.agent-1c/snapshots/workflow-update')
            Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source ([pscustomobject]@{root=$repoRoot;commit=('b'*40)}) -Phase post-copy-running
            $pending=Get-WorkflowUpdatePendingSnapshot
            $before=(Get-FileHash -LiteralPath $pending.receiptPath).Hash
            $script:originalPathState=(Get-Item Function:Get-WorkflowUpdatePathState).ScriptBlock
            $script:receiptEditInjected=$false
            function Get-WorkflowUpdatePathState {
                param([string]$RelativePath,[string]$PhysicalPath)
                if($RelativePath -eq '.agent-1c/migrations/ui-testing-essential-v1.json' -and -not $script:receiptEditInjected){
                    $script:receiptEditInjected=$true
                    Write-Utf8TextAtomic -Path $cavPath -Value $later
                }
                & $script:originalPathState -RelativePath $RelativePath -PhysicalPath $PhysicalPath
            }
            $errorText=''
            try {Add-WorkflowDotEnvPolicySnapshotPaths -Snapshot $snapshot -Pending $pending}catch{$errorText=$_.Exception.Message}
            [pscustomobject]@{errorText=$errorText;receiptText=(Read-Utf8Text -Path $cavPath);unchanged=((Get-FileHash -LiteralPath $pending.receiptPath).Hash -ceq $before);recordCount=@($snapshot.records).Count;requiredAction=$script:RunRequiredAction}
        }
        $result.errorText | Should -Match 'WORKFLOW_UPDATE_RECONCILIATION_REQUIRED'
        $result.errorText | Should -Match 'caveman-auto-v1.json'
        $result.requiredAction | Should -Match 'Recovery status'
        $result.receiptText | Should -Be $later
        $result.unchanged | Should -BeTrue
        $result.recordCount | Should -Be 1
    }
}
