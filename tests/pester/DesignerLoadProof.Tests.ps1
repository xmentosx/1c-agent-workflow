Describe "1C Designer load proof invalidation" {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        $HelperPath = $context.HelperPath
    }

    It "reloads A after an interrupted B load invalidates the previous A proof" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-load-proof-recovery-" + [guid]::NewGuid().ToString("N"))
        try {
            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $statePath = Save-DevBranchState -SafeDevBranchName "proof-recovery" -State @{
                    safeDevBranchName = "proof-recovery"
                    devBranchName = "proof-recovery"
                    lastConfigDesignerFingerprint = "fingerprint-a"
                    configLoadStatus = "passed"
                    enterpriseNormalizationStatus = "passed"
                }
                $script:SourceFingerprint = "fingerprint-b"
                $script:ChangedFiles = @("Configuration.xml")
                $script:LoadAttempts = 0
                $script:ObservedProofs = @()
                $script:ObservedModes = @()
                function Get-ConfigSourceFingerprint {
                    [pscustomobject]@{ fingerprint = $script:SourceFingerprint; fileCount = 1; absoluteExportPath = "C:\src" }
                }
                function Get-ConfigLoadChangeSet {
                    [pscustomobject]@{ files = @($script:ChangedFiles); baseCommit = "base"; currentCommit = "head"; absoluteExportPath = "C:\src" }
                }
                function Get-CurrentCommit { "head" }
                function New-ConfigLoadListFile { "C:\load-list.txt" }
                function Stop-DevBranchRuntimeBeforeInfobaseMutation {}
                function Invoke-ConfigLoadWithFallback {
                    param(
                        [string]$InfoBasePath,
                        [string]$InfoBaseKind,
                        [object]$State,
                        [string]$AbsoluteExportPath,
                        [string]$ListFilePath,
                        [int]$FileCount,
                        [string]$ExtensionName,
                        [string]$Mode,
                        [switch]$ResetConfigDumpInfo
                    )
                    $script:LoadAttempts++
                    $persisted = Read-DevBranchStateFile -Path $statePath
                    $script:ObservedProofs += , [pscustomobject]@{
                        inMemory = [string](Get-StateValue -State $State -Name "lastConfigDesignerFingerprint" -Default "")
                        persisted = [string](Get-StateValue -State $persisted -Name "lastConfigDesignerFingerprint" -Default "")
                        status = [string](Get-StateValue -State $persisted -Name "configLoadStatus" -Default "")
                    }
                    $script:ObservedModes += $Mode
                    if ($script:LoadAttempts -eq 1) {
                        throw "simulated Designer interruption"
                    }
                    [pscustomobject]@{
                        lastLogPath = "C:\full.log"
                        loadModeUsed = "full"
                        partialLogPath = ""
                        fullFallbackLogPath = "C:\full.log"
                        configLoadStatus = "passed"
                        partialError = ""
                        fullFallbackError = ""
                    }
                }

                $firstMessage = ""
                try {
                    Load-ConfigFromFiles -InfoBasePath "C:\base" -InfoBaseKind file -State (Read-DevBranchStateFile -Path $statePath) -ExportPath "src/cf" 6>$null | Out-Null
                } catch {
                    $firstMessage = $_.Exception.Message
                }
                $afterFailure = Read-DevBranchStateFile -Path $statePath

                $script:SourceFingerprint = "fingerprint-a"
                $script:ChangedFiles = @()
                $recovery = Load-ConfigFromFiles -InfoBasePath "C:\base" -InfoBaseKind file -State $afterFailure -ExportPath "src/cf" 3>$null 6>$null
                $afterRecovery = Read-DevBranchStateFile -Path $statePath
                [pscustomobject]@{
                    firstMessage = $firstMessage
                    afterFailureFingerprint = [string](Get-StateValue -State $afterFailure -Name "lastConfigDesignerFingerprint" -Default "")
                    afterFailureStatus = $afterFailure.configLoadStatus
                    observedProofs = @($script:ObservedProofs)
                    observedModes = @($script:ObservedModes)
                    recovery = $recovery
                    finalFingerprint = $afterRecovery.lastConfigDesignerFingerprint
                    finalStatus = $afterRecovery.configLoadStatus
                }
            }

            $result.firstMessage | Should -Match "simulated Designer interruption"
            $result.afterFailureFingerprint | Should -Be ""
            $result.afterFailureStatus | Should -Be "pending"
            $result.observedProofs.Count | Should -Be 2
            @($result.observedProofs | Where-Object { $_.inMemory -or $_.persisted -or $_.status -ne "pending" }).Count | Should -Be 0
            $result.observedModes | Should -Be @("Auto", "Full")
            $result.recovery.loadReason | Should -Be "designer-proof-invalidated-full-load"
            $result.finalFingerprint | Should -Be "fingerprint-a"
            $result.finalStatus | Should -Be "passed"
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "keeps only the matching extension proof invalid after a failed load" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-extension-load-proof-" + [guid]::NewGuid().ToString("N"))
        try {
            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $statePath = Save-DevBranchState -SafeDevBranchName "extension-proof" -State @{
                    safeDevBranchName = "extension-proof"
                    devBranchName = "extension-proof"
                    lastConfigDesignerFingerprint = "config-a"
                    lastExtensionDesignerFingerprint = "extension-a"
                    configLoadStatus = "passed"
                    enterpriseNormalizationStatus = "passed"
                }
                function Write-Utf8Text { throw "branch state must use the atomic writer" }
                function Get-ConfigSourceFingerprint { [pscustomobject]@{ fingerprint = "extension-b"; fileCount = 1; absoluteExportPath = "C:\src\cfe\Demo" } }
                function Get-ConfigLoadChangeSet { [pscustomobject]@{ files = @("Configuration.xml"); baseCommit = "base"; currentCommit = "head"; absoluteExportPath = "C:\src\cfe\Demo" } }
                function Get-CurrentCommit { "head" }
                function New-ConfigLoadListFile { "C:\extension-list.txt" }
                function Stop-DevBranchRuntimeBeforeInfobaseMutation {}
                function Invoke-ConfigLoadWithFallback { throw "simulated extension load failure" }

                $message = ""
                try {
                    Load-ConfigFromFiles -InfoBasePath "C:\base" -InfoBaseKind file -State (Read-DevBranchStateFile -Path $statePath) -ExportPath "src/cfe/Demo" -ContentKind extension -ExtensionName Demo 6>$null | Out-Null
                } catch {
                    $message = $_.Exception.Message
                }
                [pscustomobject]@{ message = $message; state = (Read-DevBranchStateFile -Path $statePath) }
            }

            $result.message | Should -Match "simulated extension load failure"
            $result.state.lastConfigDesignerFingerprint | Should -Be "config-a"
            $result.state.lastExtensionDesignerFingerprint | Should -Be ""
            $result.state.configLoadStatus | Should -Be "pending"
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "keeps the proof invalid when partial and full fallback both fail" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-fallback-load-proof-" + [guid]::NewGuid().ToString("N"))
        try {
            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $statePath = Save-DevBranchState -SafeDevBranchName "fallback-proof" -State @{
                    safeDevBranchName = "fallback-proof"
                    devBranchName = "fallback-proof"
                    lastConfigDesignerFingerprint = "fingerprint-a"
                    configLoadStatus = "passed"
                    enterpriseNormalizationStatus = "passed"
                }
                $script:DesignerCalls = @()
                $script:ObservedFingerprints = @()
                function Get-ConfigSourceFingerprint { [pscustomobject]@{ fingerprint = "fingerprint-b"; fileCount = 1; absoluteExportPath = "C:\src" } }
                function Get-ConfigLoadChangeSet { [pscustomobject]@{ files = @("Configuration.xml"); baseCommit = "base"; currentCommit = "head"; absoluteExportPath = "C:\src" } }
                function Get-CurrentCommit { "head" }
                function New-ConfigLoadListFile { "C:\load-list.txt" }
                function Stop-DevBranchRuntimeBeforeInfobaseMutation {}
                function New-ConfigDumpInfoLoadSnapshot { [pscustomobject]@{ path = "C:\ConfigDumpInfo.xml"; existed = $false; backupPath = ""; preserveBackup = $false } }
                function Restore-ConfigDumpInfoLoadSnapshot {}
                function Remove-ConfigDumpInfoLoadSnapshot {}
                function Invoke-Designer {
                    param([string]$InfoBasePath, [string]$InfoBaseKind, [string[]]$DesignerArgs)
                    $script:DesignerCalls += , @($DesignerArgs)
                    $script:ObservedFingerprints += [string](Get-StateValue -State (Read-DevBranchStateFile -Path $statePath) -Name "lastConfigDesignerFingerprint" -Default "")
                    $script:LastLogPath = "C:\designer-$($script:DesignerCalls.Count).log"
                    $script:LastNativeProcessStarted = $true
                    throw "designer failure $($script:DesignerCalls.Count)"
                }

                $message = ""
                try {
                    Load-ConfigFromFiles -InfoBasePath "C:\base" -InfoBaseKind file -State (Read-DevBranchStateFile -Path $statePath) -ExportPath "src/cf" 3>$null 6>$null | Out-Null
                } catch {
                    $message = $_.Exception.Message
                }
                [pscustomobject]@{
                    message = $message
                    state = Read-DevBranchStateFile -Path $statePath
                    calls = @($script:DesignerCalls)
                    observedFingerprints = @($script:ObservedFingerprints)
                }
            }

            $result.message | Should -Match "both failed"
            $result.calls.Count | Should -Be 2
            $result.calls[0] | Should -Contain "-listFile"
            $result.calls[0] | Should -Contain "/UpdateDBCfg"
            $result.calls[1] | Should -Not -Contain "-listFile"
            $result.calls[1] | Should -Contain "/UpdateDBCfg"
            @($result.observedFingerprints | Where-Object { $_ }).Count | Should -Be 0
            $result.state.lastConfigDesignerFingerprint | Should -Be ""
            $result.state.configLoadStatus | Should -Be "fallback-failed"
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "keeps a successful unchanged proof without writing pending state" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-unchanged-load-proof-" + [guid]::NewGuid().ToString("N"))
        try {
            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $statePath = Save-DevBranchState -SafeDevBranchName "unchanged-proof" -State @{
                    safeDevBranchName = "unchanged-proof"
                    devBranchName = "unchanged-proof"
                    lastConfigDesignerFingerprint = "fingerprint-a"
                    configLoadStatus = "passed"
                    enterpriseNormalizationStatus = "passed"
                }
                function Get-ConfigSourceFingerprint { [pscustomobject]@{ fingerprint = "fingerprint-a"; fileCount = 1; absoluteExportPath = "C:\src" } }
                function Get-CurrentCommit { "head" }
                function Get-ConfigLoadChangeSet { throw "Git diff must not run for an unchanged proof" }
                function Stop-DevBranchRuntimeBeforeInfobaseMutation { throw "runtime drain must not run for an unchanged proof" }
                function Invoke-ConfigLoadWithFallback { throw "Designer must not run for an unchanged proof" }

                $load = Load-ConfigFromFiles -InfoBasePath "C:\base" -InfoBaseKind file -State (Read-DevBranchStateFile -Path $statePath) -ExportPath "src/cf" 6>$null
                [pscustomobject]@{ load = $load; state = (Read-DevBranchStateFile -Path $statePath) }
            }

            $result.load.loaded | Should -BeFalse
            $result.load.designerInvoked | Should -BeFalse
            $result.load.loadReason | Should -Be "source-fingerprint-match"
            $result.state.lastConfigDesignerFingerprint | Should -Be "fingerprint-a"
            $result.state.configLoadStatus | Should -Be "passed"
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "backfills application readiness and tree proof for an unchanged N-1 state" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-unchanged-load-proof-upgrade-" + [guid]::NewGuid().ToString("N"))
        try {
            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $statePath = Save-DevBranchState -SafeDevBranchName "unchanged-proof-upgrade" -State @{
                    safeDevBranchName = "unchanged-proof-upgrade"
                    devBranchName = "unchanged-proof-upgrade"
                    lastConfigDesignerFingerprint = "fingerprint-a"
                    enterpriseNormalizationStatus = "passed"
                }
                function Get-ConfigSourceFingerprint {
                    [pscustomobject]@{ fingerprint = "fingerprint-a"; treeObjectId = ("a" * 40); fileCount = 1; absoluteExportPath = "C:\src" }
                }
                function Get-CurrentCommit { "head" }
                function Get-ConfigLoadChangeSet { throw "Git diff must not run for an unchanged proof" }
                function Stop-DevBranchRuntimeBeforeInfobaseMutation { throw "runtime drain must not run for an unchanged proof" }
                function Invoke-ConfigLoadWithFallback { throw "Designer must not run for an unchanged proof" }

                $state = Read-DevBranchStateFile -Path $statePath
                $load = Load-ConfigFromFiles -InfoBasePath "C:\base" -InfoBaseKind file -State $state -ExportPath "src/cf" 6>$null
                $updates = New-LoadStateUpdates -LoadResult $load -ContentKind configuration
                Update-DevBranchState -State $state -Updates $updates
                [pscustomobject]@{ load = $load; state = (Read-DevBranchStateFile -Path $statePath) }
            }

            $result.load.loaded | Should -BeFalse
            $result.load.designerInvoked | Should -BeFalse
            $result.state.configLoadStatus | Should -Be "passed"
            $result.state.lastConfigDesignerTreeObjectId | Should -Be ("a" * 40)
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "always invokes Designer for an explicit Full load even when the fingerprint matches" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-explicit-full-load-" + [guid]::NewGuid().ToString("N"))
        try {
            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $script:LoadCalls = 0
                function Get-ConfigSourceFingerprint {
                    [pscustomobject]@{ fingerprint = "fingerprint-a"; treeObjectId = ("a" * 40); fileCount = 1; absoluteExportPath = "C:\src" }
                }
                function Get-ConfigLoadChangeSet {
                    [pscustomobject]@{ files = @(); currentCommit = "head"; absoluteExportPath = "C:\src"; requiresFullLoad = $false }
                }
                function Get-CurrentCommit { "head" }
                function Stop-DevBranchRuntimeBeforeInfobaseMutation {}
                function Invoke-ConfigLoadWithFallback {
                    param([string]$Mode, [switch]$ResetConfigDumpInfo)
                    $script:LoadCalls++
                    $script:ResetConfigDumpInfo = [bool]$ResetConfigDumpInfo
                    [pscustomobject]@{
                        lastLogPath = "C:\full.log"; loadModeUsed = $Mode.ToLowerInvariant(); partialLogPath = ""
                        fullFallbackLogPath = ""; configLoadStatus = "passed"; partialError = ""; fullFallbackError = ""
                    }
                }
                $state = [pscustomobject]@{
                    lastConfigDesignerFingerprint = "fingerprint-a"
                    lastConfigDesignerTreeObjectId = ("a" * 40)
                    configLoadStatus = "passed"
                    enterpriseNormalizationStatus = "passed"
                }
                $load = Load-ConfigFromFiles -InfoBasePath "C:\base" -InfoBaseKind file -State $state -ExportPath "src/cf" -Mode Full 6>$null
                [pscustomobject]@{ load = $load; calls = $script:LoadCalls; resetConfigDumpInfo = $script:ResetConfigDumpInfo }
            }

            $result.calls | Should -Be 1
            $result.load.designerInvoked | Should -BeTrue
            $result.load.loadModeUsed | Should -Be "full"
            $result.load.loadReason | Should -Be "explicit-full-load"
            $result.resetConfigDumpInfo | Should -BeTrue
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "preserves the canonical Git-tree fingerprint without mutating the user index" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-load-proof-fingerprint-" + [guid]::NewGuid().ToString("N"))
        try {
            $export = Join-Path $tempRoot "src\cf"
            New-Item -ItemType Directory -Force -Path $export | Out-Null
            Set-Content -LiteralPath (Join-Path $export "Configuration.xml") -Encoding UTF8 -Value "<Configuration />"
            & git -C $tempRoot init --quiet
            & git -C $tempRoot config user.email "itl-tests@example.invalid"
            & git -C $tempRoot config user.name "ITL Tests"
            & git -C $tempRoot add -- src/cf
            & git -C $tempRoot commit --quiet -m "baseline"

            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $clean = Get-ConfigSourceFingerprint -ExportPath "src/cf"
                Set-Content -LiteralPath (Join-Path $export "Configuration.xml") -Encoding UTF8 -Value "<Configuration><Comment>changed</Comment></Configuration>"
                $cachedBefore = @(Get-GitPathList -Arguments @("diff", "--cached", "--name-only", "-z", "--"))
                $dirty = Get-ConfigSourceFingerprint -ExportPath "src/cf"
                $cachedAfter = @(Get-GitPathList -Arguments @("diff", "--cached", "--name-only", "-z", "--"))
                & git -C $tempRoot add -- src/cf
                $staged = Get-ConfigSourceFingerprint -ExportPath "src/cf"
                & git -C $tempRoot commit --quiet -m "changed"
                $committed = Get-ConfigSourceFingerprint -ExportPath "src/cf"
                [pscustomobject]@{
                    clean = $clean.fingerprint
                    dirty = $dirty.fingerprint
                    staged = $staged.fingerprint
                    committed = $committed.fingerprint
                    cachedBefore = @($cachedBefore)
                    cachedAfter = @($cachedAfter)
                }
            }

            $result.clean | Should -Match '^v2\|git-tree-sha256\|[0-9a-f]{64}$'
            $result.dirty | Should -Not -Be $result.clean
            $result.staged | Should -Be $result.dirty
            $result.committed | Should -Be $result.dirty
            @($result.cachedBefore).Count | Should -Be 0
            @($result.cachedAfter).Count | Should -Be 0
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
