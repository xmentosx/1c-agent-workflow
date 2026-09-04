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
