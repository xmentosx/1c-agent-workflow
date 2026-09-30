BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $helperPath = Join-Path $repoRoot '.agents\skills\1c-workflow\scripts\agent-1c.ps1'
}

Describe 'One-time Caveman policy transition' {
    It 'restores branch-only environment after a project-context update' {
        $root = Join-Path $TestDrive ('Основной контекст ' + [guid]::NewGuid().ToString('N'))
        $branch = Join-Path $TestDrive ('Контекст ветки ' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $root, $branch | Out-Null
        [IO.File]::WriteAllText((Join-Path $root '.dev.env'), "AGENT_TOOLS=codex`n", [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $branch '.dev.env'), "AGENT_TOOLS=cursor`nITL_BRANCH_ONLY_SETTING=branch`n", [Text.UTF8Encoding]::new($false))
        $before = [Environment]::GetEnvironmentVariable('ITL_BRANCH_ONLY_SETTING', 'Process')
        try {
            [Environment]::SetEnvironmentVariable('ITL_BRANCH_ONLY_SETTING', $null, 'Process')
            $result = & {
                . $helperPath -ProjectRoot $root -Action help *> $null
                $inside = Invoke-InProjectContext -Root $branch -ScriptBlock {
                    [pscustomobject]@{
                        tools = [Environment]::GetEnvironmentVariable('AGENT_TOOLS', 'Process')
                        branchOnly = [Environment]::GetEnvironmentVariable('ITL_BRANCH_ONLY_SETTING', 'Process')
                    }
                }
                [pscustomobject]@{
                    inside = $inside
                    afterTools = [Environment]::GetEnvironmentVariable('AGENT_TOOLS', 'Process')
                    afterBranchOnly = [Environment]::GetEnvironmentVariable('ITL_BRANCH_ONLY_SETTING', 'Process')
                }
            }
            $result.inside.tools | Should -Be 'cursor'
            $result.inside.branchOnly | Should -Be 'branch'
            $result.afterTools | Should -Be 'codex'
            $result.afterBranchOnly | Should -BeNullOrEmpty
        } finally { [Environment]::SetEnvironmentVariable('ITL_BRANCH_ONLY_SETTING', $before, 'Process') }
    }

    It 'converts an old case-insensitive on once and preserves a later explicit on' {
        $root = Join-Path $TestDrive ('Старый проект ' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        [IO.File]::WriteAllText((Join-Path $root '.dev.env'), "OTHER=keep`r`nCAVEMAN=ON`r`nCAVEMAN_LEVEL=ultra`r`n", [Text.UTF8Encoding]::new($false))
        $result = & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            function Get-DependencyLockEntry { param($Name) return @{ commit = ('a' * 40) } }
            $first = Invoke-CavemanPolicyTransition
            $afterFirst = Read-Utf8Text -Path (Join-Path $root '.dev.env')
            Write-Utf8TextAtomic -Path (Join-Path $root '.dev.env') -Value ($afterFirst.Replace('CAVEMAN=auto', 'CAVEMAN=on'))
            $second = Invoke-CavemanPolicyTransition
            [pscustomobject]@{ first = $first; second = $second; text = (Read-Utf8Text -Path (Join-Path $root '.dev.env')) }
        }
        $result.first.converted | Should -BeTrue
        $result.first.status | Should -Be 'completed'
        $result.second.converted | Should -BeTrue
        $result.text | Should -Match '(?m)^CAVEMAN=on\r?$'
        $result.text | Should -Match '(?m)^CAVEMAN_LEVEL=ultra\r?$'
        $result.text | Should -Match '(?m)^OTHER=keep\r?$'
    }

    It 'uses the previous package pin to preserve an intentional on from an already current project' {
        $oldRoot = Join-Path $TestDrive ('Прежний пакет ' + [guid]::NewGuid().ToString('N'))
        $currentRoot = Join-Path $TestDrive ('Текущий пакет ' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path @($oldRoot, $currentRoot) | Out-Null
        [IO.File]::WriteAllText((Join-Path $oldRoot '.dev.env'), "CAVEMAN=ON`n", [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $currentRoot '.dev.env'), "CAVEMAN=ON`n", [Text.UTF8Encoding]::new($false))
        $result = & {
            . $helperPath -ProjectRoot $oldRoot -Action help *> $null
            function Get-DependencyLockEntry { param($Name) return @{ commit = ('b' * 40) } }
            $old = Invoke-CavemanPolicyTransition -EvaluatePackageEligibility -PreviousWorkflowCommit ('a' * 40)
            $oldText = Read-Utf8Text -Path (Join-Path $oldRoot '.dev.env')
            $script:ProjectRoot = $currentRoot
            $current = Invoke-CavemanPolicyTransition -EvaluatePackageEligibility -PreviousWorkflowCommit ('b' * 40)
            $currentText = Read-Utf8Text -Path (Join-Path $currentRoot '.dev.env')
            [pscustomobject]@{ old = $old; oldText = $oldText; current = $current; currentText = $currentText }
        }
        $result.old.eligibility | Should -Be 'older-package'
        $result.old.converted | Should -BeTrue
        $result.oldText | Should -Be "CAVEMAN=auto`n"
        $result.current.eligibility | Should -Be 'already-current-package'
        $result.current.converted | Should -BeFalse
        $result.currentText | Should -Be "CAVEMAN=ON`n"
    }

    It 'reads the previous workflow commit only from the owned pre-copy snapshot' {
        $root = Join-Path $TestDrive ('Снимок Caveman ' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        $backup = Join-Path $root 'dependency-lock.before.json'
        [IO.File]::WriteAllText($backup, ('{"dependencies":{"workflowPackage":{"commit":"' + ('a' * 40) + '"}}}'), [Text.UTF8Encoding]::new($false))
        $result = & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            function Get-WorkflowUpdatePendingSnapshot { [pscustomobject]@{ snapshot = [pscustomobject]@{ records = @([pscustomobject]@{ relativePath = '.agent-1c/dependency-lock.json'; existed = $true; wasDirectory = $false; backupPath = $backup }) } } }
            $commit = Get-CavemanPolicyPreviousWorkflowCommit
            Remove-Item -LiteralPath $backup -Force
            $errorText = ''
            try { Get-CavemanPolicyPreviousWorkflowCommit | Out-Null } catch { $errorText = $_.Exception.Message }
            [pscustomobject]@{ commit = $commit; errorText = $errorText }
        }
        $result.commit | Should -Be ('a' * 40)
        $result.errorText | Should -Match 'CAVEMAN_POLICY_PROVENANCE_MISSING'
    }

    It 'restores the original dotenv and receipt through the existing update transaction' {
        $root = Join-Path $TestDrive ('Откат Caveman ' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path (Join-Path $root '.agent-1c') | Out-Null
        [IO.File]::WriteAllText((Join-Path $root '.dev.env'), "CAVEMAN=On`nOTHER=keep`n", [Text.UTF8Encoding]::new($false))
        $result = & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            function Get-DependencyLockEntry { param($Name) return @{ commit = ('b' * 40) } }
            $snapshot = New-WorkflowUpdateRollbackSnapshot -RelativePaths @('.dev.env', '.agent-1c/migrations/caveman-auto-v1.json') -SnapshotParent (Join-Path $root '.agent-1c/snapshots/workflow-update')
            Invoke-CavemanPolicyTransition -EvaluatePackageEligibility -PreviousWorkflowCommit ('a' * 40) | Out-Null
            $during = Read-Utf8Text -Path (Join-Path $root '.dev.env')
            Restore-WorkflowUpdateRollbackSnapshot -Snapshot $snapshot
            Remove-WorkflowUpdateRollbackSnapshot -Snapshot $snapshot
            [pscustomobject]@{
                during = $during
                after = Read-Utf8Text -Path (Join-Path $root '.dev.env')
                receiptExists = Test-Path -LiteralPath (Get-CavemanPolicyReceiptPath) -PathType Leaf
            }
        }
        $result.during | Should -Match '^CAVEMAN=auto'
        $result.after | Should -Be "CAVEMAN=On`nOTHER=keep`n"
        $result.receiptExists | Should -BeFalse
    }

    It 'reports each completed root policy without reading other dotenv values' {
        $root = Join-Path $TestDrive ('Отчёт Caveman ' + [guid]::NewGuid().ToString('N'))
        $branch = Join-Path $TestDrive ('Отчёт ветки ' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path @($root, $branch) | Out-Null
        [IO.File]::WriteAllText((Join-Path $root '.dev.env'), "CAVEMAN=On`nSECRET=do-not-report`n", [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $branch '.dev.env'), "CAVEMAN=off`nSECRET=do-not-report`n", [Text.UTF8Encoding]::new($false))
        $result = & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            function Get-DependencyLockEntry { param($Name) return @{ commit = ('b' * 40) } }
            Invoke-CavemanPolicyTransition -EvaluatePackageEligibility -PreviousWorkflowCommit ('a' * 40) | Out-Null
            Copy-CavemanPolicyReceiptToWorktree -WorktreePath $branch
            function Write-AndSetRunUserReport { param($Lines) $script:capturedReport = @($Lines) -join "`n" }
            Write-WorkflowUpdateFollowUp -Source ([pscustomobject]@{ ref = 'test'; commit = ('b' * 40); source = 'local' }) -CommitResult ([pscustomobject]@{ commit = 'project-head'; created = $true }) -BranchReport ([pscustomobject]@{ roots = @([pscustomobject]@{ branch = 'itldev/test'; status = 'completed'; root = $branch }) })
            $script:capturedReport
        }
        $result | Should -Match 'Caveman master: On → auto'
        $result | Should -Match 'Caveman: сохранён off'
        $result | Should -Not -Match 'do-not-report'
    }

    It 'records an old off scope without changing it and lets a new branch inherit intentional on' {
        $root = Join-Path $TestDrive ('Новый проект ' + [guid]::NewGuid().ToString('N'))
        $branch = Join-Path $TestDrive ('Новая ветка ' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path @($root, $branch) | Out-Null
        [IO.File]::WriteAllText((Join-Path $root '.dev.env'), "CAVEMAN=off`n", [Text.UTF8Encoding]::new($false))
        $result = & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            function Get-DependencyLockEntry { param($Name) return @{ commit = ('b' * 40) } }
            $old = Invoke-CavemanPolicyTransition
            Write-Utf8TextAtomic -Path (Join-Path $root '.dev.env') -Value "CAVEMAN=on`n"
            Copy-DotEnvToWorktree -WorktreePath $branch
            Invoke-InProjectContext -Root $branch -ScriptBlock {
                $inherited = Invoke-CavemanPolicyTransition
                [pscustomobject]@{ inherited = $inherited; text = (Read-Utf8Text -Path (Join-Path $script:ProjectRoot '.dev.env')) }
            }
        }
        $result.inherited.status | Should -Be 'completed'
        $result.text | Should -Be "CAVEMAN=on`n"
    }

    It 'records the branch dotenv after branch-specific settings are applied' {
        $root = Join-Path $TestDrive ('Исходный Caveman ' + [guid]::NewGuid().ToString('N'))
        $branch = Join-Path $TestDrive ('Ветка Caveman ' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path @($root, $branch) | Out-Null
        [IO.File]::WriteAllText((Join-Path $root '.dev.env'), "CAVEMAN=On`nBASE=master`n", [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $branch '.dev.env'), "CAVEMAN=on`nBASE=branch with spaces`n", [Text.UTF8Encoding]::new($false))
        $result = & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            function Get-DependencyLockEntry { param($Name) return @{ commit = ('e' * 40) } }
            $master = Invoke-CavemanPolicyTransition
            Copy-CavemanPolicyReceiptToWorktree -WorktreePath $branch
            $branchReceiptPath = Get-CavemanPolicyReceiptPath -Root $branch
            $branchReceipt = Read-Utf8Text -Path $branchReceiptPath | ConvertFrom-Json
            $branchHash = (Get-FileHash -LiteralPath (Join-Path $branch '.dev.env') -Algorithm SHA256).Hash.ToLowerInvariant()
            $receiptHash = (Get-FileHash -LiteralPath $branchReceiptPath -Algorithm SHA256).Hash
            Copy-CavemanPolicyReceiptToWorktree -WorktreePath $branch
            [pscustomobject]@{
                master = $master
                branch = $branchReceipt
                branchHash = $branchHash
                receiptUnchanged = ((Get-FileHash -LiteralPath $branchReceiptPath -Algorithm SHA256).Hash -eq $receiptHash)
                envText = Read-Utf8Text -Path (Join-Path $branch '.dev.env')
            }
        }
        $result.master.converted | Should -BeTrue
        $result.branch.scopeKind | Should -Be 'new'
        $result.branch.converted | Should -BeFalse
        $result.branch.beforeValue | Should -Be 'on'
        $result.branch.afterSha256 | Should -Be $result.branchHash
        $result.branch.inheritedReceiptSha256 | Should -Match '^[0-9a-f]{64}$'
        $result.receiptUnchanged | Should -BeTrue
        $result.envText | Should -Match 'BASE=branch with spaces'
    }

    It 'reconciles an interrupted transition by its expected hashes without storing dotenv contents' {
        $root = Join-Path $TestDrive ('Прерванный проект ' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        [IO.File]::WriteAllText((Join-Path $root '.dev.env'), "CAVEMAN=On`nSECRET=value`n", [Text.UTF8Encoding]::new($false))
        $result = & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            function Get-DependencyLockEntry { param($Name) return @{ commit = ('c' * 40) } }
            $first = Invoke-CavemanPolicyTransition
            $receiptPath = Get-CavemanPolicyReceiptPath
            $receipt = Read-Utf8Text -Path $receiptPath | ConvertFrom-Json
            $receipt.status = 'applying'
            Write-Utf8TextAtomic -Path $receiptPath -Value ($receipt | ConvertTo-Json -Depth 6)
            $resumed = Invoke-CavemanPolicyTransition
            [pscustomobject]@{ resumed = $resumed; receiptText = (Read-Utf8Text -Path $receiptPath) }
        }
        $result.resumed.status | Should -Be 'completed'
        $result.receiptText | Should -Not -Match 'SECRET=value'
        $result.receiptText | Should -Not -Match 'afterText'
    }

    It 'does not overwrite an edit made after a prepared receipt' {
        $root = Join-Path $TestDrive ('Конфликт настройки ' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        [IO.File]::WriteAllText((Join-Path $root '.dev.env'), "CAVEMAN=On`n", [Text.UTF8Encoding]::new($false))
        $result = & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            function Get-DependencyLockEntry { param($Name) return @{ commit = ('d' * 40) } }
            $first = Invoke-CavemanPolicyTransition
            $receiptPath = Get-CavemanPolicyReceiptPath
            $receipt = Read-Utf8Text -Path $receiptPath | ConvertFrom-Json
            $receipt.status = 'applying'
            Write-Utf8TextAtomic -Path $receiptPath -Value ($receipt | ConvertTo-Json -Depth 6)
            Write-Utf8TextAtomic -Path (Join-Path $root '.dev.env') -Value "CAVEMAN=off`n"
            $errorText = ''
            try { Invoke-CavemanPolicyTransition | Out-Null } catch { $errorText = $_.Exception.Message }
            [pscustomobject]@{ errorText = $errorText; envText = (Read-Utf8Text -Path (Join-Path $root '.dev.env')) }
        }
        $result.errorText | Should -Match 'CAVEMAN_POLICY_CONFLICT'
        $result.envText | Should -Be "CAVEMAN=off`n"
    }
}
