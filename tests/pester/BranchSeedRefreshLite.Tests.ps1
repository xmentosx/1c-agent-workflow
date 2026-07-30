Describe "latest-only branch seed and two-level refresh" {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        $RepoRoot = $context.RepoRoot
        $HelperPath = $context.HelperPath
    }

    It "keeps one latest file seed and transfers signatures without raw 1Cv8Log" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-seed-latest-" + [guid]::NewGuid().ToString("N"))
        try {
            $sourceRoot = Join-Path $tempRoot "source база"
            $seedRoot = Join-Path $tempRoot "общий seed"
            New-Item -ItemType Directory -Force -Path (Join-Path $sourceRoot "1Cv8Log") | Out-Null
            [IO.File]::WriteAllBytes((Join-Path $sourceRoot "1Cv8.1CD"), [byte[]](1, 2, 3))
            [IO.File]::WriteAllBytes((Join-Path $sourceRoot "1Cv8Log\1Cv8.lgf"), [byte[]](9, 9))

            $result = & {
                . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
                function Get-BranchSeedRoot { return $seedRoot }
                function Get-InfoBaseKind { return "file" }
                function Get-SourceInfoBasePath { return $sourceRoot }
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
                $second = New-BranchSeed -ConfigurationFingerprint "old" -ConfigurationFileCount 1 -DumpConfigurationFromSeed
                [pscustomobject]@{
                    firstSyncId = [string]$first.syncId
                    secondSyncId = [string]$second.syncId
                    manifest = $second
                    artifacts = @(Get-ChildItem -LiteralPath $seedRoot -Recurse -File -Filter "1Cv8.1CD")
                    rawLogs = @(Get-ChildItem -LiteralPath $seedRoot -Recurse -Directory -Filter "1Cv8Log")
                    baseline = Read-Utf8Text -Path ([string]$second.baselinePath) | ConvertFrom-Json
                    artifactBytes = [IO.File]::ReadAllBytes([string]$second.artifactPath)
                }
            }

            $result.firstSyncId | Should -Not -Be $result.secondSyncId
            $result.manifest.status | Should -Be "ready"
            $result.manifest.configurationFingerprint | Should -Be "fingerprint"
            @($result.artifacts).Count | Should -Be 1
            @($result.rawLogs).Count | Should -Be 0
            @($result.baseline.signatures) | Should -Be @("ошибка один", "error two")
            @($result.artifactBytes) | Should -Be @([byte]4, [byte]5, [byte]6, [byte]7)
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
param([string]$Operation,[string]$ProjectRoot,[string]$SourceInfoBasePath)
if ($Operation -eq "capabilities") {
    [pscustomobject]@{ schemaVersion = 2; capabilities = @("restore-seed","event-log-baseline") } | ConvertTo-Json -Compress
    exit 0
}
if ($Operation -eq "event-log-baseline") {
    [pscustomobject]@{ schemaVersion = 2; errorCount = 2; signatures = @("server error","ошибка сервера"); cacheStatus = "hit"; sourceKey = "server" } | ConvertTo-Json -Compress
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
                $baseline = Get-SourceEventLogSeedBaseline
                @($baseline.signatures) | Should -Be @("server error", "ошибка сервера")
                $baseline.cache.status | Should -Be "hit"
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
            function Sync-DevBranchContextToDotEnv {}
            function Assert-CleanGit {}
            function Sync-Master { $script:syncCalls++ }
            function Get-CurrentBranch { return "itldev/lite" }
            function Get-MasterBranch { return "master" }
            function Get-GitOutput { return $sha }
            function Update-DevBranchState {}
            function Set-RunStage {}
            function Merge-MasterPreservingBranchConfigDumpInfo {
                param([string]$MasterBranch)
                $script:mergedCommit = $MasterBranch
            }
            function Restart-Agent1cAfterDevBranchMerge { throw "STOP_AFTER_MERGE" }

            { Invoke-RefreshDevBranchCore -OperationName "refresh-dev-branch-lite" } | Should -Throw "*STOP_AFTER_MERGE*"
            $script:syncCalls | Should -Be 0
            $script:mergedCommit | Should -Be $sha

            $script:mergedCommit = ""
            { Invoke-RefreshDevBranchCore -SynchronizeMaster -OperationName "refresh-dev-branch" } | Should -Throw "*STOP_AFTER_MERGE*"
            $script:syncCalls | Should -Be 1
            $script:mergedCommit | Should -Be $sha
        }
    }
}
