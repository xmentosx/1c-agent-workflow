Describe "latest-only branch seed and two-level refresh" {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        $RepoRoot = $context.RepoRoot
        $HelperPath = $context.HelperPath
    }

    It "keeps one latest file seed with DoNotCopy marker and transfers signatures without raw 1Cv8Log" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-seed-latest-" + [guid]::NewGuid().ToString("N"))
        try {
            $sourceRoot = Join-Path $tempRoot "source база"
            $seedRoot = Join-Path $tempRoot "общий seed"
            New-Item -ItemType Directory -Force -Path (Join-Path $sourceRoot "1Cv8Log") | Out-Null
            [IO.File]::WriteAllBytes((Join-Path $sourceRoot "1Cv8.1CD"), [byte[]](1, 2, 3))
            Set-Content -LiteralPath (Join-Path $sourceRoot "DoNotCopy.txt") -Encoding ASCII -Value "source-marker-one"
            [IO.File]::WriteAllBytes((Join-Path $sourceRoot "1Cv8Log\1Cv8.lgf"), [byte[]](9, 9))

            $result = & {
                . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
                function Get-BranchSeedRoot { return $seedRoot }
                function Get-InfoBaseKind { return "file" }
                function Get-SourceInfoBasePath { return $sourceRoot }
                function Get-SourceUsesRepository { return $false }
                function Get-MainWorktreePath { return $RepoRoot }
                function Get-SourceEventLogSeedBaseline {
                    return [ordered]@{
                        schemaVersion = 2; createdAt = (Get-Date).ToString("o"); reason = "source-seed"
                        reader = "direct-stream"; logDirectory = (Join-Path $sourceRoot "1Cv8Log")
                        errorCount = 2; signatureCount = 2; signatures = @("ошибка один", "error two")
                        durationMs = 5
                        cache = [ordered]@{ status = "hit"; path = (Join-Path $tempRoot "cache.json"); sourceKey = "cache-key"; segmentCount = 1 }
                        failureEvidence = ""
                    }
                }
                function Dump-ConfigToFilesFromInfoBase {
                    param([string]$InfoBasePath, [string]$InfoBaseKind)
                    New-Item -ItemType Directory -Force -Path (Join-Path $InfoBasePath "1Cv8Log") | Out-Null
                    [IO.File]::WriteAllBytes((Join-Path $InfoBasePath "1Cv8Log\1Cv8.lgf"), [byte[]](7, 7))
                    return [pscustomobject]@{ exportPath = "src/cf" }
                }
                function Get-ConfigSourceFingerprint {
                    return [pscustomobject]@{ fingerprint = "fingerprint"; fileCount = 7 }
                }

                $first = New-BranchSeed -ConfigurationFingerprint "old" -ConfigurationFileCount 1 -DumpConfigurationFromSeed
                [IO.File]::WriteAllBytes((Join-Path $sourceRoot "1Cv8.1CD"), [byte[]](4, 5, 6, 7))
                Set-Content -LiteralPath (Join-Path $sourceRoot "DoNotCopy.txt") -Encoding ASCII -Value "source-marker-two"
                $second = New-BranchSeed -ConfigurationFingerprint "old" -ConfigurationFileCount 1 -DumpConfigurationFromSeed
                $branchInfoBasePath = Join-Path $tempRoot "branch base"
                Restore-DevBranchFromSeed -DevBranchName "feature" -DevBranchInfoBasePath $branchInfoBasePath | Out-Null
                [pscustomobject]@{
                    firstSyncId = [string]$first.syncId
                    secondSyncId = [string]$second.syncId
                    manifest = $second
                    artifacts = @(Get-ChildItem -LiteralPath $seedRoot -Recurse -File -Filter "1Cv8.1CD")
                    rawLogs = @(Get-ChildItem -LiteralPath $seedRoot -Recurse -Directory -Filter "1Cv8Log")
                    baseline = Read-Utf8Text -Path ([string]$second.baselinePath) | ConvertFrom-Json
                    artifactBytes = [IO.File]::ReadAllBytes([string]$second.artifactPath)
                    seedMarker = Get-Content -LiteralPath (Join-Path (Split-Path -Parent ([string]$second.artifactPath)) "DoNotCopy.txt") -Raw
                    branchMarker = Get-Content -LiteralPath (Join-Path $branchInfoBasePath "DoNotCopy.txt") -Raw
                }
            }

            $result.firstSyncId | Should -Not -Be $result.secondSyncId
            $result.manifest.status | Should -Be "ready"
            $result.manifest.configurationFingerprint | Should -Be "fingerprint"
            @($result.artifacts).Count | Should -Be 1
            @($result.rawLogs).Count | Should -Be 0
            $result.seedMarker.Trim() | Should -Be "source-marker-two"
            $result.branchMarker.Trim() | Should -Be "source-marker-two"
            @($result.baseline.signatures) | Should -Be @("ошибка один", "error two")
            @($result.artifactBytes) | Should -Be @([byte]4, [byte]5, [byte]6, [byte]7)
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "locally unbinds a copied repository-backed file seed before its validation dump" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-seed-repository-unbind-" + [guid]::NewGuid().ToString("N"))
        try {
            $sourceRoot = Join-Path $tempRoot "source база"
            $seedRoot = Join-Path $tempRoot "общий seed"
            New-Item -ItemType Directory -Force -Path $sourceRoot | Out-Null
            [IO.File]::WriteAllBytes((Join-Path $sourceRoot "1Cv8.1CD"), [byte[]](1, 2, 3))

            $result = & {
                . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
                $script:unbindCalls = @()
                $script:unbindObservedBeforeDump = $false
                function Get-BranchSeedRoot { return $seedRoot }
                function Get-InfoBaseKind { return "file" }
                function Get-SourceInfoBasePath { return $sourceRoot }
                function Get-SourceUsesRepository { return $true }
                function Get-MainWorktreePath { return $RepoRoot }
                function Get-SourceEventLogSeedBaseline {
                    return [ordered]@{
                        schemaVersion = 2; createdAt = (Get-Date).ToString("o"); reason = "source-seed"
                        reader = "direct-stream"; logDirectory = ""; errorCount = 0; signatureCount = 0
                        signatures = @(); durationMs = 0
                        cache = [ordered]@{ status = "empty"; path = ""; sourceKey = ""; segmentCount = 0 }
                        failureEvidence = ""
                    }
                }
                function Invoke-Designer {
                    param(
                        [string]$InfoBasePath,
                        [string]$InfoBaseKind,
                        [string[]]$DesignerArgs
                    )
                    $script:unbindCalls += [pscustomobject]@{
                        infoBasePath = $InfoBasePath
                        infoBaseKind = $InfoBaseKind
                        designerArgs = @($DesignerArgs)
                    }
                }
                function Dump-ConfigToFilesFromInfoBase {
                    param([string]$InfoBasePath, [string]$InfoBaseKind)
                    $script:unbindObservedBeforeDump = $script:unbindCalls.Count -eq 1
                    return [pscustomobject]@{ exportPath = "src/cf" }
                }
                function Get-ConfigSourceFingerprint {
                    return [pscustomobject]@{ fingerprint = "detached"; fileCount = 1 }
                }

                $manifest = New-BranchSeed -ConfigurationFingerprint "attached" -ConfigurationFileCount 1 -DumpConfigurationFromSeed
                [pscustomobject]@{
                    manifest = $manifest
                    unbindCalls = @($script:unbindCalls)
                    unbindObservedBeforeDump = $script:unbindObservedBeforeDump
                    artifactExists = Test-Path -LiteralPath ([string]$manifest.artifactPath) -PathType Leaf
                }
            }

            $result.manifest.status | Should -Be "ready"
            $result.manifest.configurationFingerprint | Should -Be "detached"
            $result.unbindCalls.Count | Should -Be 1
            $result.unbindCalls[0].infoBasePath | Should -Be (Split-Path -Parent ([string]$result.manifest.artifactPath))
            $result.unbindCalls[0].infoBaseKind | Should -Be "file"
            @($result.unbindCalls[0].designerArgs) | Should -Be @("/ConfigurationRepositoryUnbindCfg", "-force")
            $result.unbindObservedBeforeDump | Should -BeTrue
            $result.artifactExists | Should -BeTrue
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "fails closed after replacement failure and requires explicit rebuild recovery" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-seed-failed-" + [guid]::NewGuid().ToString("N"))
        try {
            $sourceRoot = Join-Path $tempRoot "source"
            $seedRoot = Join-Path $tempRoot "seed"
            New-Item -ItemType Directory -Force -Path $sourceRoot | Out-Null
            [IO.File]::WriteAllBytes((Join-Path $sourceRoot "1Cv8.1CD"), [byte[]](1))

            $result = & {
                . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
                function Get-BranchSeedRoot { return $seedRoot }
                function Get-InfoBaseKind { return "file" }
                function Get-SourceInfoBasePath { return $sourceRoot }
                function Get-SourceUsesRepository { return $false }
                function Get-MainWorktreePath { return $RepoRoot }
                function Get-SourceEventLogSeedBaseline {
                    return [ordered]@{
                        schemaVersion = 2; createdAt = (Get-Date).ToString("o"); reason = "source-seed"
                        reader = "direct-stream"; logDirectory = ""; errorCount = 0; signatureCount = 0
                        signatures = @(); durationMs = 0
                        cache = [ordered]@{ status = "empty"; path = ""; sourceKey = ""; segmentCount = 0 }
                        failureEvidence = ""
                    }
                }
                function Dump-ConfigToFilesFromInfoBase { throw "mock seed dump failure" }
                $failure = ""
                try { New-BranchSeed -ConfigurationFingerprint "x" -DumpConfigurationFromSeed | Out-Null } catch { $failure = $_.Exception.Message }
                $manifestAfterFailure = Read-BranchSeedManifest
                $ensureFailure = ""
                try { Ensure-BranchSeed -Policy EnsureCompatible -ConfigurationFingerprint "x" | Out-Null } catch { $ensureFailure = $_.Exception.Message }
                $restoreFailure = ""
                try { Restore-DevBranchFromSeed -DevBranchName "one" -DevBranchInfoBasePath (Join-Path $tempRoot "branch") | Out-Null } catch { $restoreFailure = $_.Exception.Message }

                function Dump-ConfigToFilesFromInfoBase { return [pscustomobject]@{ exportPath = "src/cf" } }
                function Get-ConfigSourceFingerprint { return [pscustomobject]@{ fingerprint = "x"; fileCount = 1 } }
                $recovered = Ensure-BranchSeed -Policy Rebuild -ConfigurationFingerprint "x"
                [pscustomobject]@{
                    failure = $failure
                    failedStatus = [string]$manifestAfterFailure.status
                    ensureFailure = $ensureFailure
                    restoreFailure = $restoreFailure
                    rebuildMarkerExistsAfterFailure = Test-Path -LiteralPath (Get-BranchSeedPaths).rebuildMarkerPath
                    recoveredStatus = [string]$recovered.status
                }
            }

            $result.failure | Should -Match "mock seed dump failure"
            $result.failedStatus | Should -Be "failed"
            $result.ensureFailure | Should -Match "BRANCH_SEED_FAILED"
            $result.restoreFailure | Should -Match "BRANCH_SEED_FAILED"
            $result.rebuildMarkerExistsAfterFailure | Should -BeFalse
            $result.recoveredStatus | Should -Be "ready"
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "reuses only compatible seed for EnsureCompatible and rebuilds for Rebuild" {
        & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $script:seedBuilds = 0
            function Read-BranchSeedManifest {
                return [pscustomobject]@{ status = "ready"; configurationFingerprint = "same"; artifactPath = "seed" }
            }
            function Test-BranchSeedArtifactReady { return $true }
            function New-BranchSeed {
                $script:seedBuilds++
                return [pscustomobject]@{ status = "ready"; configurationFingerprint = "new" }
            }

            Ensure-BranchSeed -Policy EnsureCompatible -ConfigurationFingerprint "same" | Out-Null
            $script:seedBuilds | Should -Be 0
            Ensure-BranchSeed -Policy EnsureCompatible -ConfigurationFingerprint "changed" | Out-Null
            $script:seedBuilds | Should -Be 1
            Ensure-BranchSeed -Policy Rebuild -ConfigurationFingerprint "changed" | Out-Null
            $script:seedBuilds | Should -Be 2
        }
    }

    It "waits for active seed readers before writer replacement and has no source-copy fallback" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-seed-lease-" + [guid]::NewGuid().ToString("N"))
        try {
            & {
                . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
                function Get-BranchSeedRoot { return $tempRoot }
                function Get-InfoBaseKind { return "file" }
                function Get-SourceInfoBasePath { return (Join-Path $tempRoot "source") }
                $reader = Open-BranchSeedLease -Mode read
                try {
                    { Open-BranchSeedLease -Mode write -TimeoutSeconds 1 } | Should -Throw "*BRANCH_SEED_LEASE_TIMEOUT*"
                } finally {
                    $reader.Dispose()
                }
                $writer = Open-BranchSeedLease -Mode write -TimeoutSeconds 1
                $writer.Dispose()
                $paths = Get-BranchSeedPaths
                Set-Content -LiteralPath $paths.rebuildMarkerPath -Encoding ASCII -Value "{}"
                try {
                    { Open-BranchSeedLease -Mode read -TimeoutSeconds 1 } | Should -Throw "*BRANCH_SEED_LEASE_TIMEOUT*"
                } finally {
                    Remove-Item -LiteralPath $paths.rebuildMarkerPath -Force
                }

                $lifecycleText = Read-Utf8Text -Path (Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.lifecycle.ps1")
                $lifecycleText | Should -Not -Match ([regex]::Escape('Copy-Item -LiteralPath $source -Destination $DevBranchInfoBasePath -Recurse'))
                $lifecycleText | Should -Match "Restore-DevBranchFromSeed"
            }
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "requires server provider schema v2 restore and baseline capabilities" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-server-provider-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            $providerPath = Join-Path $tempRoot "provider.ps1"
            Set-Content -LiteralPath $providerPath -Encoding UTF8 -Value @'
param([string]$Operation,[string]$ProjectRoot,[string]$SourceInfoBasePath,[int]$EventLogLookbackDays)
if ($Operation -eq "capabilities") {
    [pscustomobject]@{ schemaVersion = 2; capabilities = @("restore-seed","event-log-baseline","event-log-baseline-lookback") } | ConvertTo-Json -Compress
    exit 0
}
if ($Operation -eq "event-log-baseline") {
    [pscustomobject]@{ schemaVersion = 2; errorCount = 2; signatures = @("server error","ошибка сервера"); cacheStatus = "hit"; sourceKey = "server"; lookbackDays = $EventLogLookbackDays; windowStart = "bounded" } | ConvertTo-Json -Compress
    exit 0
}
exit 1
'@
            & {
                . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
                function Get-ConfigValue { return $providerPath }
                function Resolve-ProjectPath { return $providerPath }
                $contract = Get-BranchSeedServerProviderCapabilities
                $contract.schemaVersion | Should -Be 2
                @($contract.capabilities) | Should -Contain "restore-seed"
                @($contract.capabilities) | Should -Contain "event-log-baseline"
                function Get-InfoBaseKind { return "server" }
                function Get-SourceInfoBasePath { return "server\base" }
                function Get-SourceEventLogLookbackDays { return 7 }
                $baseline = Get-SourceEventLogSeedBaseline
                @($baseline.signatures) | Should -Be @("server error", "ошибка сервера")
                $baseline.cache.status | Should -Be "hit"
                $baseline.lookbackDays | Should -Be 7
                $baseline.windowStart | Should -Be "bounded"
            }

            Set-Content -LiteralPath $providerPath -Encoding UTF8 -Value @'
param([string]$Operation,[string]$ProjectRoot)
[pscustomobject]@{ schemaVersion = 1; capabilities = @("copy") } | ConvertTo-Json -Compress
'@
            & {
                . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
                function Get-ConfigValue { return $providerPath }
                function Resolve-ProjectPath { return $providerPath }
                { Get-BranchSeedServerProviderCapabilities } | Should -Throw "*SERVER_SEED_PROVIDER_UPGRADE_REQUIRED*"
            }
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "passes full and lite refresh modes separately and lite has branch-only lock scope" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-refresh-mode-" + [guid]::NewGuid().ToString("N"))
        $branchRoot = $tempRoot + "-branch"
        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot "tracked.txt") -Encoding ASCII -Value "x"
            & git -C $tempRoot init *> $null
            & git -C $tempRoot config user.email "test@example.com"
            & git -C $tempRoot config user.name "Test User"
            & git -C $tempRoot add tracked.txt
            & git -C $tempRoot commit -m init *> $null
            & git -C $tempRoot branch -M master
            & git -C $tempRoot worktree add --quiet -b itldev/lite $branchRoot master *> $null

            & {
                . $HelperPath -ProjectRoot $branchRoot -Action help *> $null
                $script:modes = @()
                function Invoke-RefreshDevBranchCore {
                    param([switch]$SynchronizeMaster, [string]$OperationName)
                    $script:modes += [pscustomobject]@{ synchronize = [bool]$SynchronizeMaster; operation = $OperationName }
                }
                Refresh-DevBranch
                Refresh-DevBranchLite
                $script:modes.Count | Should -Be 2
                $script:modes[0].synchronize | Should -BeTrue
                $script:modes[0].operation | Should -Be "refresh-dev-branch"
                $script:modes[1].synchronize | Should -BeFalse
                $script:modes[1].operation | Should -Be "refresh-dev-branch-lite"

                @(Get-Agent1cLifecycleOperationLockScopes -RequestedAction "refresh-dev-branch-lite") | Should -Be @([IO.Path]::GetFullPath($branchRoot))
                @(Get-Agent1cLifecycleOperationLockScopes -RequestedAction "initialize-dev-branch-runtime") | Should -Be @([IO.Path]::GetFullPath($branchRoot))
                @(Get-Agent1cLifecycleOperationLockScopes -RequestedAction "refresh-dev-branch").Count | Should -Be 2
                @(Get-Agent1cLifecycleOperationLockScopes -RequestedAction "release-e2e-config-repository-lock-roundtrip").Count | Should -Be 2
            }
        } finally {
            Remove-Item -LiteralPath $branchRoot -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "releases the main branch-creation lock and keeps runtime reporting in the same process" {
        $lifecycleText = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.lifecycle.ps1") -Raw -Encoding UTF8
        $runtimeSection = [regex]::Match(
            $lifecycleText,
            '(?s)function Invoke-DevBranchRuntimeAfterGitPhase \{.*?(?=\r?\nfunction New-DevBranchCore)'
        ).Value
        $runtimeSection | Should -Not -BeNullOrEmpty
        $runtimeSection | Should -Match '(?s)Complete-Agent1cLifecycleOperation.*Exit-Agent1cLifecycleOperation.*Invoke-InProjectContext.*Enter-Agent1cLifecycleOperation.*Initialize-DevBranchRuntime'
        $runtimeSection | Should -Not -Match '&\s*powershell'
    }

    It "merges the exact captured master SHA and lite never calls source sync" {
        & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $script:LifecyclePhase = ""
            $script:syncCalls = 0
            $script:mergedCommit = ""
            $sha = "1234567890abcdef1234567890abcdef12345678"
            $state = [pscustomobject]@{
                devBranch = "itldev/lite"
                devBranchName = "lite"
                devBranchKind = "configuration"
            }
            function Read-DevBranchState { return $state }
            function Assert-DevelopmentBranchWorktreeContext {}
            function Assert-DevBranchExtensionInitialized {}
            function Save-DevBranchCheckpoint {}
            function Sync-DevBranchContextToDotEnv {}
            function Assert-CleanGit {}
            function Sync-Master { $script:syncCalls++ }
            function Get-CurrentBranch { return "itldev/lite" }
            function Get-MasterBranch { return "master" }
            function Get-GitOutput { return $sha }
            function Update-DevBranchState {}
            function Set-RunStage {}
            function Invoke-NewDevBranchLifecycleMerge {
                param([object]$State, [string]$Operation, [string]$TargetCommit, [string]$ConflictStage)
                $script:mergedCommit = $TargetCommit
                throw "STOP_AFTER_MERGE"
            }

            { Invoke-RefreshDevBranchCore -OperationName "refresh-dev-branch-lite" } | Should -Throw "*STOP_AFTER_MERGE*"
            $script:syncCalls | Should -Be 0
            $script:mergedCommit | Should -Be $sha

            $script:mergedCommit = ""
            { Invoke-RefreshDevBranchCore -SynchronizeMaster -OperationName "refresh-dev-branch" } | Should -Throw "*STOP_AFTER_MERGE*"
            $script:syncCalls | Should -Be 1
            $script:mergedCommit | Should -Be $sha
        }
    }

    It "checkpoints staged unstaged untracked and deleted paths while excluding ignored runtime" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-refresh-checkpoint-пробел " + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            & git -C $tempRoot init *> $null
            & git -C $tempRoot config user.name "ITL Test"
            & git -C $tempRoot config user.email "itl@example.invalid"
            Set-Content -LiteralPath (Join-Path $tempRoot ".gitignore") -Encoding UTF8 -Value "ignored/"
            foreach ($name in @("staged.txt", "unstaged.txt", "deleted.txt")) {
                Set-Content -LiteralPath (Join-Path $tempRoot $name) -Encoding UTF8 -Value "base"
            }
            & git -C $tempRoot add --all
            & git -C $tempRoot commit -m "base" *> $null

            Set-Content -LiteralPath (Join-Path $tempRoot "staged.txt") -Encoding UTF8 -Value "staged"
            & git -C $tempRoot add -- "staged.txt"
            Set-Content -LiteralPath (Join-Path $tempRoot "unstaged.txt") -Encoding UTF8 -Value "unstaged"
            Remove-Item -LiteralPath (Join-Path $tempRoot "deleted.txt")
            Set-Content -LiteralPath (Join-Path $tempRoot "новый файл.txt") -Encoding UTF8 -Value "new"
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot "ignored") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot "ignored\runtime.log") -Encoding UTF8 -Value "runtime"

            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $checkpoint = Save-DevBranchCheckpoint -Operation "refresh-dev-branch-lite"
                $headAfterCheckpoint = Get-CurrentCommit
                $second = Save-DevBranchCheckpoint -Operation "refresh-dev-branch-lite"
                $gitDir = (Get-GitOutput @("rev-parse", "--git-dir")).Trim()
                if (-not [IO.Path]::IsPathRooted($gitDir)) { $gitDir = Join-Path $tempRoot $gitDir }
                Set-Content -LiteralPath (Join-Path $gitDir "CHERRY_PICK_HEAD") -Encoding ASCII -Value $headAfterCheckpoint
                $blocked = ""
                try { Save-DevBranchCheckpoint -Operation "refresh-dev-branch-lite" | Out-Null } catch { $blocked = $_.Exception.Message }
                Remove-Item -LiteralPath (Join-Path $gitDir "CHERRY_PICK_HEAD") -Force
                [pscustomobject]@{
                    checkpoint = $checkpoint
                    headAfterCheckpoint = $headAfterCheckpoint
                    second = $second
                    blocked = $blocked
                    message = (Get-GitOutput @("log", "-1", "--pretty=%s")).Trim()
                }
            }

            $result.checkpoint | Should -Be $result.headAfterCheckpoint
            $result.second | Should -Be ""
            $result.message | Should -Be "chore: checkpoint before branch refresh"
            $result.blocked | Should -Match "CHERRY_PICK|cherry-pick"
            @(& git -C $tempRoot status --porcelain).Count | Should -Be 0
            @(& git -C $tempRoot ls-files -- "новый файл.txt").Count | Should -Be 1
            @(& git -C $tempRoot ls-files -- "ignored/runtime.log").Count | Should -Be 0
            Test-Path -LiteralPath (Join-Path $tempRoot "deleted.txt") | Should -BeFalse
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "syncs master once limits refresh-all to two workers and aggregates isolated failures" {
        $entrypointText = Get-Content -LiteralPath $HelperPath -Raw -Encoding UTF8
        $lifecycleText = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.lifecycle.ps1") -Raw -Encoding UTF8
        $entrypointText | Should -Match '\[ValidateRange\(1, 2\)\]\[int\]\$MaxParallelBranches = 2'
        $entrypointText | Should -Match 'Add-Agent1cReexecArgument -Arguments \$arguments -Name "ExpectedMasterCommit"'
        $lifecycleText | Should -Match '\$runner = Join-Path \$script:Agent1cScriptRoot "run-itl-command\.ps1"'
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-refresh-all-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $script:SyncCalls = 0
                $script:Started = [System.Collections.Generic.List[string]]::new()
                $script:Processes = [System.Collections.Generic.List[object]]::new()
                $script:MaxObserved = 0
                function Assert-MasterWorktreeContext {}
                function Assert-CleanGit {}
                function Sync-Master { $script:SyncCalls++ }
                function Get-CurrentCommit { "1234567890abcdef1234567890abcdef12345678" }
                function Get-ActiveReadyDevBranchTargets {
                    [pscustomobject]@{ errors = @(); targets = @(
                        [pscustomobject]@{ name = "one"; branch = "itldev/one"; worktreePath = $tempRoot },
                        [pscustomobject]@{ name = "two"; branch = "itldev/two"; worktreePath = $tempRoot },
                        [pscustomobject]@{ name = "three"; branch = "itldev/three"; worktreePath = $tempRoot }
                    ) }
                }
                function Start-RefreshAllBranchProcess {
                    param([object]$Target, [string]$MasterCommit, [string]$OutputRoot)
                    foreach ($existing in @($script:Processes)) { $existing.process.Refresh() }
                    $active = @($script:Processes | Where-Object { -not $_.process.HasExited }).Count
                    if (($active + 1) -gt $script:MaxObserved) { $script:MaxObserved = $active + 1 }
                    $script:Started.Add([string]$Target.branch) | Out-Null
                    $stdout = Join-Path $OutputRoot ("$($Target.name).json")
                    $stderr = Join-Path $OutputRoot ("$($Target.name).log")
                    $isFailure = [string]$Target.name -eq "two"
                    $payload = [ordered]@{ status = $(if ($isFailure) { "failed" } else { "succeeded" }); error = $(if ($isFailure) { "fixture conflict" } else { "" }); userReport = "branch $($Target.name)" }
                    [IO.File]::WriteAllText($stdout, (($payload | ConvertTo-Json) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
                    [IO.File]::WriteAllText($stderr, "", [Text.UTF8Encoding]::new($false))
                    # A valid compact terminal summary owns the outcome even when
                    # the parallel process observer retains a mismatched native
                    # code. A terminal failure remains failed with native exit 0.
                    $exit = if ([string]$Target.name -eq "one") { 1 } else { 0 }
                    $stdoutLock = [IO.File]::Open($stdout, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
                    $process = [pscustomobject]@{ startedAt = Get-Date; exitCode = $exit; stdoutLock = $stdoutLock }
                    $process | Add-Member -MemberType ScriptProperty -Name HasExited -Value { ((Get-Date) - $this.startedAt).TotalMilliseconds -ge 700 }
                    $process | Add-Member -MemberType ScriptMethod -Name Refresh -Value {}
                    $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {
                        if ($null -ne $this.stdoutLock) { $this.stdoutLock.Dispose(); $this.stdoutLock = $null }
                    }
                    $process | Add-Member -MemberType ScriptMethod -Name Dispose -Value {
                        if ($null -ne $this.stdoutLock) { $this.stdoutLock.Dispose(); $this.stdoutLock = $null }
                    }
                    $entry = [pscustomobject]@{ target = $Target; process = $process; stdout = $stdout; stderr = $stderr; startedAt = Get-Date }
                    $script:Processes.Add($entry) | Out-Null
                    return $entry
                }
                function Set-RunStage {}
                $failure = ""
                try { Refresh-AllDevBranches 6>$null } catch { $failure = $_.Exception.Message }
                foreach ($entry in @($script:Processes)) { try { $entry.process.Dispose() } catch {} }
                [pscustomobject]@{ syncCalls = $script:SyncCalls; started = @($script:Started); maxObserved = $script:MaxObserved; failure = $failure; report = $script:RunUserReport }
            }

            $result.syncCalls | Should -Be 1
            @($result.started) | Should -Be @("itldev/one", "itldev/two", "itldev/three")
            $result.maxObserved | Should -Be 2
            $result.failure | Should -Match "REFRESH_ALL_BRANCH_FAILURE"
            $result.report | Should -Match "itldev/one: succeeded"
            $result.report | Should -Match "itldev/two: failed: fixture conflict"
            $result.report | Should -Match "itldev/three: succeeded"
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
