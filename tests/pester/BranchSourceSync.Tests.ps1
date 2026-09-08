Describe "development branch source-only synchronization" {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        $RepoRoot = $context.RepoRoot
        $HelperPath = $context.HelperPath
    }

    It "combines only the 1C source root, preserves both cursors, and does not merge branch history" {
        $nonAscii = [string][char]0x0432
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-source-sync $nonAscii " + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot "src\cf") | Out-Null
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot "specs") | Out-Null
            & git -C $tempRoot init --quiet
            & git -C $tempRoot config user.name "ITL Test"
            & git -C $tempRoot config user.email "itl@example.invalid"
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\Configuration.xml") -Encoding UTF8 -Value "<Configuration />"
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\ConfigDumpInfo.xml") -Encoding UTF8 -Value "base-cursor"
            Set-Content -LiteralPath (Join-Path $tempRoot "specs\base.md") -Encoding UTF8 -Value "base"
            & git -C $tempRoot add --all
            & git -C $tempRoot commit --quiet -m "base"
            & git -C $tempRoot branch -M master

            & git -C $tempRoot checkout --quiet -b itldev/peer
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\peer.bsl") -Encoding UTF8 -Value "peer code"
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\ConfigDumpInfo.xml") -Encoding UTF8 -Value "peer-cursor"
            Set-Content -LiteralPath (Join-Path $tempRoot "specs\peer.md") -Encoding UTF8 -Value "peer spec"
            & git -C $tempRoot add --all
            & git -C $tempRoot commit --quiet -m "peer"
            $peerHead = (& git -C $tempRoot rev-parse HEAD).Trim()

            & git -C $tempRoot checkout --quiet -b itldev/primary master
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\primary.bsl") -Encoding UTF8 -Value "primary code"
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\ConfigDumpInfo.xml") -Encoding UTF8 -Value "primary-cursor"
            Set-Content -LiteralPath (Join-Path $tempRoot "specs\primary.md") -Encoding UTF8 -Value "primary spec"
            & git -C $tempRoot add --all
            & git -C $tempRoot commit --quiet -m "primary"
            $primaryHead = (& git -C $tempRoot rev-parse HEAD).Trim()

            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                function Assert-OneCConfigurationSourceIntegrity {}

                $merge = Invoke-BranchSourceMergeTree -PrimaryHead $primaryHead -PeerHead $peerHead
                Invoke-Git @("checkout", $merge.tree, "--", "src/cf")
                Restore-BranchSourceSyncCursor -Head $primaryHead -ExportPath "src/cf"
                $primaryCommit = Complete-PrimaryBranchSourceSyncCommit -PeerBranch "itldev/peer" -ExportPath "src/cf"
                $primarySnapshot = [pscustomobject]@{
                    primarySource = Test-Path -LiteralPath (Join-Path $tempRoot "src\cf\primary.bsl")
                    peerSource = Test-Path -LiteralPath (Join-Path $tempRoot "src\cf\peer.bsl")
                    cursor = (Get-Content -LiteralPath (Join-Path $tempRoot "src\cf\ConfigDumpInfo.xml") -Raw).Trim()
                    primarySpec = Test-Path -LiteralPath (Join-Path $tempRoot "specs\primary.md")
                    peerSpec = Test-Path -LiteralPath (Join-Path $tempRoot "specs\peer.md")
                }

                Invoke-Git @("checkout", "itldev/peer")
                $peerCommit = Copy-BranchSourceSyncResult -SourceCommit $primaryCommit -TargetHead $peerHead -SourceBranch "itldev/primary" -ExportPath "src/cf"
                [pscustomobject]@{
                    primaryCommit = $primaryCommit
                    peerCommit = $peerCommit
                    primarySnapshot = $primarySnapshot
                    peerPrimarySource = Test-Path -LiteralPath (Join-Path $tempRoot "src\cf\primary.bsl")
                    peerPeerSource = Test-Path -LiteralPath (Join-Path $tempRoot "src\cf\peer.bsl")
                    peerCursor = (Get-Content -LiteralPath (Join-Path $tempRoot "src\cf\ConfigDumpInfo.xml") -Raw).Trim()
                    peerPrimarySpec = Test-Path -LiteralPath (Join-Path $tempRoot "specs\primary.md")
                    peerPeerSpec = Test-Path -LiteralPath (Join-Path $tempRoot "specs\peer.md")
                }
            }

            $result.primarySnapshot.primarySource | Should -BeTrue
            $result.primarySnapshot.peerSource | Should -BeTrue
            $result.primarySnapshot.cursor | Should -Be "primary-cursor"
            $result.primarySnapshot.primarySpec | Should -BeTrue
            $result.primarySnapshot.peerSpec | Should -BeFalse
            $result.peerPrimarySource | Should -BeTrue
            $result.peerPeerSource | Should -BeTrue
            $result.peerCursor | Should -Be "peer-cursor"
            $result.peerPrimarySpec | Should -BeFalse
            $result.peerPeerSpec | Should -BeTrue
            & git -C $tempRoot merge-base --is-ancestor $peerHead $result.primaryCommit
            $LASTEXITCODE | Should -Be 1
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "reports only source conflicts even when other branch-local files also conflict" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-source-sync-conflict-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot "src\cf") | Out-Null
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot "specs") | Out-Null
            & git -C $tempRoot init --quiet
            & git -C $tempRoot config user.name "ITL Test"
            & git -C $tempRoot config user.email "itl@example.invalid"
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\module.bsl") -Encoding UTF8 -Value "base"
            Set-Content -LiteralPath (Join-Path $tempRoot "specs\feature.md") -Encoding UTF8 -Value "base"
            & git -C $tempRoot add --all
            & git -C $tempRoot commit --quiet -m "base"
            & git -C $tempRoot branch -M master
            & git -C $tempRoot checkout --quiet -b itldev/peer
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\module.bsl") -Encoding UTF8 -Value "peer"
            Set-Content -LiteralPath (Join-Path $tempRoot "specs\feature.md") -Encoding UTF8 -Value "peer"
            & git -C $tempRoot commit --quiet -am "peer"
            $peerHead = (& git -C $tempRoot rev-parse HEAD).Trim()
            & git -C $tempRoot checkout --quiet -b itldev/primary master
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\module.bsl") -Encoding UTF8 -Value "primary"
            Set-Content -LiteralPath (Join-Path $tempRoot "specs\feature.md") -Encoding UTF8 -Value "primary"
            & git -C $tempRoot commit --quiet -am "primary"
            $primaryHead = (& git -C $tempRoot rev-parse HEAD).Trim()

            $merge = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $result = Invoke-BranchSourceMergeTree -PrimaryHead $primaryHead -PeerHead $peerHead
                [pscustomobject]@{
                    allConflicts = @($result.conflictPaths)
                    sourceConflicts = @($result.conflictPaths | Where-Object { Test-RepoPathUnderRoot -RepoPath $_ -Root "src/cf" })
                }
            }
            @($merge.sourceConflicts) | Should -Be @("src/cf/module.bsl")
            @($merge.allConflicts) | Should -Contain "specs/feature.md"
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "checkpoints, commits, fingerprints, and loads both branches through the public action" {
        & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $PeerDevBranchName = "peer"
            $DevBranchName = ""
            $script:mockRoot = "primary-root"
            $script:checkpointRoots = @()
            $script:loadBranches = @()
            $primary = [pscustomobject]@{ devBranch = "itldev/primary"; devBranchName = "primary"; worktreePath = "primary-root" }
            $peer = [pscustomobject]@{ devBranch = "itldev/peer"; devBranchName = "peer"; worktreePath = "peer-root" }

            function Read-DevBranchState { param([string]$Name) if ($Name -eq "peer") { return $peer }; return $primary }
            function Assert-DevelopmentBranchWorktreeContext {}
            function Assert-DevBranchSourceSyncCompatibility { return "src/cf" }
            function Get-PendingBranchSourceSync { return $null }
            function Save-DevBranchCheckpoint { $script:checkpointRoots += $script:mockRoot }
            function Invoke-InProjectContext {
                param([string]$Root, [scriptblock]$ScriptBlock)
                $previous = $script:mockRoot
                try { $script:mockRoot = $Root; & $ScriptBlock } finally { $script:mockRoot = $previous }
            }
            function Get-CurrentCommit { if ($script:mockRoot -eq "peer-root") { return "peer-head" }; return "primary-head" }
            function Invoke-BranchSourceMergeTree { return [pscustomobject]@{ tree = "merged-tree"; conflictPaths = @() } }
            function Invoke-Git {}
            function Restore-BranchSourceSyncCursor {}
            function Assert-BranchSourceSyncChangesScoped {}
            function Complete-PrimaryBranchSourceSyncCommit { return "primary-combined" }
            function Copy-BranchSourceSyncResult { return "peer-combined" }
            function Get-ConfigSourceFingerprint { return [pscustomobject]@{ fingerprint = "same" } }
            function Invoke-BranchSourceSyncLoad { param([object]$State) $script:loadBranches += [string]$State.devBranch }
            function Add-RunUserReportLine {}
            function Write-AndSetRunUserReport {}
            function Set-RunStage {}

            Sync-DevBranches

            @($script:checkpointRoots) | Should -Be @("primary-root", "peer-root")
            @($script:loadBranches) | Should -Be @("itldev/primary", "itldev/peer")
        }
    }

    It "routes a helper-owned peer refresh before either branch is checkpointed" {
        $expectedPeerPath = "C:\work trees\$([char]0x0432) peer"
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $nonAscii = [string][char]0x0432
            $PeerDevBranchName = "peer"
            $DevBranchName = ""
            $script:RunErrorCategory = ""
            $script:RunRequiredAction = ""
            $script:RunDevBranch = ""
            $script:RunWorktreePath = ""
            $script:checkpointCalled = $false
            $primary = [pscustomobject]@{
                devBranch = "itldev/primary"; devBranchName = "primary"; worktreePath = "C:\work trees\$nonAscii primary"
            }
            $peer = [pscustomobject]@{
                devBranch = "itldev/peer"; devBranchName = "peer"; worktreePath = "C:\work trees\$nonAscii peer"
                pendingMergeOperation = "refresh-dev-branch-lite"; pendingMergeTargetCommit = ("a" * 40)
                pendingMergeStage = "conflicts"; pendingMergeConflictPaths = @("src/cf/Module.bsl")
            }

            function Read-DevBranchState { param([string]$Name) if ($Name -eq "peer") { return $peer }; return $primary }
            function Assert-DevelopmentBranchWorktreeContext {}
            function Assert-DevBranchSourceSyncCompatibility { return "src/cf" }
            function Save-DevBranchCheckpoint { $script:checkpointCalled = $true }
            function Set-RunDevBranchState {
                param([object]$State)
                $script:RunDevBranch = [string]$State.devBranch
                $script:RunWorktreePath = [string]$State.worktreePath
            }

            $message = ""
            try { Sync-DevBranches } catch { $message = $_.Exception.Message }
            [pscustomobject]@{
                message = $message
                category = $script:RunErrorCategory
                requiredAction = $script:RunRequiredAction
                devBranch = $script:RunDevBranch
                worktreePath = $script:RunWorktreePath
                checkpointCalled = $script:checkpointCalled
            }
        }

        $result.message | Should -Match "^DEV_BRANCH_SOURCE_SYNC_PENDING_REFRESH:"
        $result.message | Should -Match "role='peer'"
        $result.message | Should -Match "operation='refresh-dev-branch-lite'"
        $result.message | Should -Match ([regex]::Escape("src/cf/Module.bsl"))
        $result.category | Should -Be "merge-conflict"
        $result.requiredAction | Should -Match ([regex]::Escape("/itl-refresh-lite"))
        $result.requiredAction | Should -Match ([regex]::Escape($expectedPeerPath))
        $result.requiredAction | Should -Match ([regex]::Escape("repeat /itl-sync-branches"))
        $result.devBranch | Should -Be "itldev/peer"
        $result.worktreePath | Should -Be $expectedPeerPath
        $result.checkpointCalled | Should -BeFalse
    }

    It "asks before replacing a different helper-owned peer lifecycle operation" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $nonAscii = [string][char]0x0432
            $PeerDevBranchName = "peer"
            $DevBranchName = ""
            $script:RunErrorCategory = ""
            $script:RunRequiredAction = ""
            $script:checkpointCalled = $false
            $primary = [pscustomobject]@{
                devBranch = "itldev/primary"; devBranchName = "primary"; worktreePath = "C:\work trees\$nonAscii primary"
            }
            $peer = [pscustomobject]@{
                devBranch = "itldev/peer"; devBranchName = "peer"; worktreePath = "C:\work trees\$nonAscii peer"
                pendingMergeOperation = "close-dev-branch"; pendingMergeTargetCommit = ("b" * 40)
                pendingMergeStage = "conflicts"; pendingMergeConflictPaths = @("src/cf/Module.bsl")
            }

            function Read-DevBranchState { param([string]$Name) if ($Name -eq "peer") { return $peer }; return $primary }
            function Assert-DevelopmentBranchWorktreeContext {}
            function Assert-DevBranchSourceSyncCompatibility { return "src/cf" }
            function Save-DevBranchCheckpoint { $script:checkpointCalled = $true }
            function Set-RunDevBranchState {}

            $message = ""
            try { Sync-DevBranches } catch { $message = $_.Exception.Message }
            [pscustomobject]@{
                message = $message
                category = $script:RunErrorCategory
                requiredAction = $script:RunRequiredAction
                checkpointCalled = $script:checkpointCalled
            }
        }

        $result.message | Should -Match "^DEV_BRANCH_SOURCE_SYNC_PENDING_LIFECYCLE:"
        $result.message | Should -Match "operation='close-dev-branch'"
        $result.category | Should -Be "runner"
        $result.requiredAction | Should -Match "Ask the user whether to finish"
        $result.requiredAction | Should -Match "Do not abort"
        $result.checkpointCalled | Should -BeFalse
    }

    It "keeps an unowned Git operation fail-closed without advising an abort" {
        $nonAscii = [string][char]0x0432
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-source-sync unowned $nonAscii " + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            & git -C $tempRoot init --quiet
            $mergeHeadPath = (& git -C $tempRoot rev-parse --git-path MERGE_HEAD).Trim()
            if (-not [IO.Path]::IsPathRooted($mergeHeadPath)) { $mergeHeadPath = Join-Path $tempRoot $mergeHeadPath }
            Set-Content -LiteralPath $mergeHeadPath -Encoding ASCII -Value ("a" * 40)

            $message = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                try { Assert-DevBranchCheckpointGitState -Operation "sync-dev-branches"; "" } catch { $_.Exception.Message }
            }

            $message | Should -Match "^DEV_BRANCH_CHECKPOINT_GIT_OPERATION_IN_PROGRESS:"
            $message | Should -Match "owning workflow"
            $message | Should -Match "do not alter or abort"
            $message | Should -Not -Match "Complete or abort it first"
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "locks exactly the two participating branch worktrees" {
        $peerRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-source-sync-lock-" + [guid]::NewGuid().ToString("N"))
        & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $PeerDevBranchName = "itldev/peer"
            function Read-DevBranchState {
                param([string]$Name)
                $Name | Should -Be "peer"
                return [pscustomobject]@{ worktreePath = $peerRoot }
            }

            $scopes = @(Get-Agent1cLifecycleOperationLockScopes -RequestedAction "sync-dev-branches")
            $expected = @([IO.Path]::GetFullPath($RepoRoot), [IO.Path]::GetFullPath($peerRoot)) | Sort-Object { $_.ToLowerInvariant() }
            $scopes | Should -Be $expected
        }
    }
}
