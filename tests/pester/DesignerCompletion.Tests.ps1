Describe "1C Designer completion evidence" {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        $RepoRoot = $context.RepoRoot
        $HelperPath = $context.HelperPath
    }

    It "checks completion evidence once and stops after the launcher exits" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $script:ProbeCalls = 0
            $fakeProcess = [pscustomobject]@{
                Id = 4242
                HasExited = $true
                ExitCode = 0
            }
            $fakeProcess | Add-Member -MemberType ScriptMethod -Name Refresh -Value { }
            $fakeProcess | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param([int]$Milliseconds); return $true }
            function Start-Process { return $fakeProcess }

            $processResult = Invoke-NativeProcessAndWaitResult `
                -FilePath "fake.exe" `
                -Arguments @() `
                -TimeoutSeconds 5 `
                -CompletionGraceSeconds 0 `
                -CompletionProbe {
                    param($Context)
                    $script:ProbeCalls++
                    return $false
                }
            [pscustomobject]@{ processResult = $processResult; probeCalls = $script:ProbeCalls }
        }

        $result.probeCalls | Should -Be 1
        $result.processResult.launcherExited | Should -BeTrue
        $result.processResult.launcherExitCode | Should -Be 0
        $result.processResult.completedByProbe | Should -BeFalse
        $result.processResult.timedOut | Should -BeFalse
        $result.processResult.exitCode | Should -Be 0
    }

    It "accepts completion evidence observed on the launcher exit poll" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $fakeProcess = [pscustomobject]@{
                Id = 4243
                HasExited = $true
                ExitCode = 0
            }
            $fakeProcess | Add-Member -MemberType ScriptMethod -Name Refresh -Value { }
            $fakeProcess | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param([int]$Milliseconds); return $true }
            function Start-Process { return $fakeProcess }

            Invoke-NativeProcessAndWaitResult `
                -FilePath "fake.exe" `
                -Arguments @() `
                -TimeoutSeconds 5 `
                -CompletionGraceSeconds 0 `
                -CompletionProbe { return $true }
        }

        $result.launcherExited | Should -BeTrue
        $result.launcherExitCode | Should -Be 0
        $result.completedByProbe | Should -BeTrue
        $result.timedOut | Should -BeFalse
        $result.exitCode | Should -Be 0
    }

    It "allows only an explicit bounded probe window after launcher exit" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $script:ProbeCalls = 0
            $fakeProcess = [pscustomobject]@{
                Id = 4244
                HasExited = $true
                ExitCode = 0
            }
            $fakeProcess | Add-Member -MemberType ScriptMethod -Name Refresh -Value { }
            $fakeProcess | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param([int]$Milliseconds); return $true }
            function Start-Process { return $fakeProcess }

            $processResult = Invoke-NativeProcessAndWaitResult `
                -FilePath "fake.exe" `
                -Arguments @() `
                -TimeoutSeconds 5 `
                -CompletionGraceSeconds 0 `
                -PostExitProbeSeconds 2 `
                -CompletionProbe {
                    $script:ProbeCalls++
                    return ($script:ProbeCalls -ge 3)
                }
            [pscustomobject]@{ processResult = $processResult; probeCalls = $script:ProbeCalls }
        }

        $result.probeCalls | Should -Be 3
        $result.processResult.completedByProbe | Should -BeTrue
        $result.processResult.timedOut | Should -BeFalse
        $result.processResult.exitCode | Should -Be 0
    }

    It "marks an expired post-exit probe as a distinct failure condition" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $fakeProcess = [pscustomobject]@{
                Id = 4245
                HasExited = $true
                ExitCode = 0
            }
            $fakeProcess | Add-Member -MemberType ScriptMethod -Name Refresh -Value { }
            $fakeProcess | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param([int]$Milliseconds); return $true }
            function Start-Process { return $fakeProcess }

            Invoke-NativeProcessAndWaitResult `
                -FilePath "fake.exe" `
                -Arguments @() `
                -TimeoutSeconds 5 `
                -CompletionGraceSeconds 0 `
                -PostExitProbeSeconds 1 `
                -CompletionProbe { return $false }
        }

        $result.launcherExited | Should -BeTrue
        $result.launcherExitCode | Should -Be 0
        $result.completedByProbe | Should -BeFalse
        $result.postExitProbeTimedOut | Should -BeTrue
        $result.timedOut | Should -BeFalse
    }

    It "surfaces a completion probe exception and runs bounded owned cleanup" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $script:CleanupCalls = 0
            $script:StopCalls = 0
            $fakeProcess = [pscustomobject]@{
                Id = 4246
                HasExited = $true
                ExitCode = 0
            }
            $fakeProcess | Add-Member -MemberType ScriptMethod -Name Refresh -Value { }
            $fakeProcess | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param([int]$Milliseconds); return $true }
            function Start-Process { return $fakeProcess }
            function Stop-NativeProcessForSafety {
                param([object]$Process)
                $script:StopCalls++
                return [pscustomobject]@{ confirmed = $true; error = "" }
            }

            $processResult = Invoke-NativeProcessAndWaitResult `
                -FilePath "fake.exe" `
                -Arguments @() `
                -TimeoutSeconds 5 `
                -CompletionGraceSeconds 0 `
                -CompletionProbe { throw "completion-probe-sentinel" } `
                -OnTimeout { $script:CleanupCalls++ }
            [pscustomobject]@{
                processResult = $processResult
                cleanupCalls = $script:CleanupCalls
                stopCalls = $script:StopCalls
            }
        }

        $result.processResult.completionProbeFailed | Should -BeTrue
        $result.processResult.completionProbeErrorType | Should -Match 'RuntimeException$'
        $result.processResult.completionProbeErrorMessage | Should -Be 'completion-probe-sentinel'
        $result.processResult.terminationConfirmed | Should -BeTrue
        $result.processResult.timedOut | Should -BeFalse
        $result.cleanupCalls | Should -Be 1
        $result.stopCalls | Should -Be 1
    }

    It "returns a stable Designer failure for a completion probe exception" {
        $fixtureRoot = Join-Path $TestDrive "designer-probe-failure"
        $basePath = Join-Path $fixtureRoot "base"
        $platformPath = Join-Path $fixtureRoot "1cv8.exe"
        New-Item -ItemType Directory -Force -Path $basePath | Out-Null
        New-Item -ItemType File -Force -Path $platformPath | Out-Null
        New-Item -ItemType File -Force -Path (Join-Path $basePath "1Cv8.1CD") | Out-Null

        $message = & {
            . $HelperPath -ProjectRoot $fixtureRoot -Action help *> $null
            $script:Config = [pscustomobject]@{ platformPath = $platformPath; logsPath = "logs" }
            function Invoke-NativeProcessAndWaitResult {
                param(
                    [string]$FilePath, [string[]]$Arguments, [int]$TimeoutSeconds = 0,
                    [scriptblock]$OnTimeout = $null, [scriptblock]$CompletionProbe = $null,
                    [int]$CompletionGraceSeconds = 10, [int]$PostExitProbeSeconds = 0,
                    [int]$MaxWorkingSetMb = 0
                )
                return [pscustomobject]@{
                    processId = 4247; exitCode = 1; timedOut = $false
                    memoryLimitExceeded = $false; memoryMonitorFailed = $false; memoryMonitorError = ""
                    peakWorkingSetMb = 0; workingSetLimitMb = 0
                    terminationConfirmed = $true; terminationError = ""
                    completedByProbe = $false; postExitProbeTimedOut = $false
                    completionProbeFailed = $true
                    completionProbeErrorType = "System.InvalidOperationException"
                    completionProbeErrorMessage = "artifact-enumeration-sentinel"
                }
            }

            try {
                Invoke-Designer -InfoBasePath $basePath -InfoBaseKind file -DesignerArgs @("/UpdateDBCfg") 6>$null | Out-Null
                ""
            } catch {
                $_.Exception.Message
            }
        }

        $message | Should -Match '^DESIGNER_COMPLETION_PROBE_FAILED\b'
        $message | Should -Match "errorType='System.InvalidOperationException'"
        $message | Should -Match "detail='artifact-enumeration-sentinel'"
        $message | Should -Match 'terminationConfirmed=True'
    }

    It "tracks Designer descendants and the unique out log while ignoring unrelated 1C processes" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $logPath = Join-Path $TestDrive "owned-designer.log"
            $script:DesignerInventory = @(
                [pscustomobject]@{ Name = "1cv8.exe"; ProcessId = 8100; ParentProcessId = 100; CommandLine = "DESIGNER /Out other.log" },
                [pscustomobject]@{ Name = "1cv8.exe"; ProcessId = 8101; ParentProcessId = 8100; CommandLine = "DESIGNER" },
                [pscustomobject]@{ Name = "1cv8.exe"; ProcessId = 8102; ParentProcessId = 100; CommandLine = "DESIGNER /Out `"$logPath`"" },
                [pscustomobject]@{ Name = "1cv8.exe"; ProcessId = 8199; ParentProcessId = 100; CommandLine = "DESIGNER /Out unrelated.log" }
            )
            function Get-CimInstance {
                param([string]$ClassName, [string]$Filter, [object]$ErrorAction)
                return @($script:DesignerInventory)
            }

            $state = New-DesignerInvocationProbeState -LauncherProcessId 8100
            $active = Get-DesignerInvocationProcessState -ProbeState $state -LogPath $logPath
            $script:DesignerInventory = @()
            $state.nextProcessCheckAtUtc = [DateTime]::MinValue
            $released = Get-DesignerInvocationProcessState -ProbeState $state -LogPath $logPath
            [pscustomobject]@{
                active = $active
                released = $released
                tracked = @($state.trackedProcessIds)
            }
        }

        $result.active.querySucceeded | Should -BeTrue
        $result.active.active | Should -BeTrue
        @($result.active.processIds) | Should -Contain 8100
        @($result.active.processIds) | Should -Contain 8101
        @($result.active.processIds) | Should -Contain 8102
        @($result.active.processIds) | Should -Not -Contain 8199
        $result.released.active | Should -BeFalse
        @($result.tracked) | Should -Contain 8102
    }

    It "publishes active and stalled liveness evidence without changing the memory guard peak" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $logPath = Join-Path $TestDrive "designer-liveness.log"
            [System.IO.File]::WriteAllText($logPath, "start", (Get-Utf8Encoding))
            $script:RunStage = "config-load.designer"
            $script:LastProcessPeakWorkingSetMb = 777
            $startedAt = [DateTime]::new(2026, 7, 26, 12, 0, 0, [DateTimeKind]::Utc)
            $probeState = New-DesignerInvocationProbeState -LauncherProcessId 8200 -StallWarningSeconds 30 -StallTimeoutSeconds 60

            $first = Update-DesignerInvocationLiveness `
                -ProbeState $probeState `
                -ProcessState ([pscustomobject]@{
                    querySucceeded = $true; active = $true; processIds = @(8200)
                    cpuSampleAvailable = $true; cpuTime100ns = [int64]10000000
                    workingSetSampleAvailable = $true; workingSetMb = 512; detail = ""
                }) `
                -ProbeContext ([pscustomobject]@{
                    launcherExited = $false; observedAtUtc = $startedAt
                    timeoutRemainingSeconds = 3600
                }) `
                -LogPath $logPath `
                -WaitingDetail "Designer launcher is active"

            [System.IO.File]::WriteAllText($logPath, "start-progress", (Get-Utf8Encoding))
            $active = Update-DesignerInvocationLiveness `
                -ProbeState $probeState `
                -ProcessState ([pscustomobject]@{
                    querySucceeded = $true; active = $true; processIds = @(8200)
                    cpuSampleAvailable = $true; cpuTime100ns = [int64]20000000
                    workingSetSampleAvailable = $true; workingSetMb = 640; detail = ""
                }) `
                -ProbeContext ([pscustomobject]@{
                    launcherExited = $false; observedAtUtc = $startedAt.AddSeconds(10)
                    timeoutRemainingSeconds = 3590
                }) `
                -LogPath $logPath `
                -WaitingDetail "Designer launcher is active"

            $stalled = Update-DesignerInvocationLiveness `
                -ProbeState $probeState `
                -ProcessState ([pscustomobject]@{
                    querySucceeded = $true; active = $true; processIds = @(8200)
                    cpuSampleAvailable = $true; cpuTime100ns = [int64]20000000
                    workingSetSampleAvailable = $true; workingSetMb = 640; detail = ""
                }) `
                -ProbeContext ([pscustomobject]@{
                    launcherExited = $false; observedAtUtc = $startedAt.AddSeconds(41)
                    timeoutRemainingSeconds = 3559
                }) `
                -LogPath $logPath `
                -WaitingDetail "Designer launcher is active"

            [pscustomobject]@{
                first = $first
                active = $active
                stalled = $stalled
                memoryGuardPeak = $script:LastProcessPeakWorkingSetMb
            }
        }

        $result.first.liveness | Should -Be "running-active"
        $result.active.liveness | Should -Be "running-active"
        $result.active.cpuDeltaMilliseconds | Should -Be 1000
        $result.active.logGrowthBytes | Should -BeGreaterThan 0
        $result.active.stage | Should -Be "config-load.designer-running"
        $result.stalled.liveness | Should -Be "stalled-suspected"
        $result.stalled.noProgressSeconds | Should -Be 31
        $result.stalled.stallTimeoutRemainingSeconds | Should -Be 29
        $result.stalled.stage | Should -Be "config-load.designer-stalled-suspected"
        $result.memoryGuardPeak | Should -Be 777
    }

    It "clears Designer liveness before a non-monitor lifecycle stage" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $script:RunLiveness = "running-waiting-release"
            $script:RunNoProgressSeconds = 17
            $script:RunStallTimeoutRemainingSeconds = 583
            $script:RunTimeoutRemainingSeconds = 3583
            $script:RunOwnedProcessIds = @(9001)
            Set-RunStage -Stage "refresh.merge" -Detail "Merging master into the development branch."
            [pscustomobject]@{
                liveness = $script:RunLiveness
                noProgressSeconds = $script:RunNoProgressSeconds
                stallTimeoutRemainingSeconds = $script:RunStallTimeoutRemainingSeconds
                timeoutRemainingSeconds = $script:RunTimeoutRemainingSeconds
                ownedProcessIds = @($script:RunOwnedProcessIds)
            }
        }

        $result.liveness | Should -BeNullOrEmpty
        $result.noProgressSeconds | Should -Be 0
        $result.stallTimeoutRemainingSeconds | Should -Be 0
        $result.timeoutRemainingSeconds | Should -Be 0
        @($result.ownedProcessIds).Count | Should -Be 0
    }

    It "fails a sustained Designer stall and cleans up only exact tracked processes" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $script:StoppedDesignerIds = [System.Collections.Generic.List[int]]::new()
            $script:RunStage = "config-load.designer"
            $startedAt = [DateTime]::new(2026, 7, 26, 12, 0, 0, [DateTimeKind]::Utc)
            $probeState = New-DesignerInvocationProbeState `
                -LauncherProcessId 8250 `
                -StallWarningSeconds 30 `
                -StallTimeoutSeconds 60
            function Get-DesignerInvocationProcessState {
                return [pscustomobject]@{
                    querySucceeded = $true; active = $true; processIds = @(8250, 8251)
                    cpuSampleAvailable = $true; cpuTime100ns = [int64]10000000
                    workingSetSampleAvailable = $true; workingSetMb = 256; detail = ""
                }
            }
            function Test-DesignerInfoBaseReleased { return $false }
            function Get-Process {
                param([int]$Id, [object]$ErrorAction)
                return [pscustomobject]@{ Id = $Id; HasExited = $false }
            }
            function Stop-NativeProcessForSafety {
                param([object]$Process)
                $script:StoppedDesignerIds.Add([int]$Process.Id) | Out-Null
                return [pscustomobject]@{ confirmed = $true; error = "" }
            }

            Test-DesignerInvocationReleased `
                -ProbeState $probeState `
                -ProbeContext ([pscustomobject]@{
                    launcherExited = $false; observedAtUtc = $startedAt
                    timeoutRemainingSeconds = 3600; processId = 8250
                }) `
                -LogPath (Join-Path $TestDrive "stall-timeout.log") `
                -InfoBaseKind file `
                -InfoBasePath (Join-Path $TestDrive "base") `
                -OperationKind "dump-config-to-files" | Out-Null
            Test-DesignerInvocationReleased `
                -ProbeState $probeState `
                -ProbeContext ([pscustomobject]@{
                    launcherExited = $false; observedAtUtc = $startedAt.AddSeconds(61)
                    timeoutRemainingSeconds = 3539; processId = 8250
                }) `
                -LogPath (Join-Path $TestDrive "stall-timeout.log") `
                -InfoBaseKind file `
                -InfoBasePath (Join-Path $TestDrive "base") `
                -OperationKind "dump-config-to-files" | Out-Null

            [pscustomobject]@{
                exceeded = $probeState.stallTimeoutExceeded
                liveness = $probeState.lastObservation.liveness
                stage = $probeState.lastObservation.stage
                cleanup = $probeState.stallCleanup
                stopped = @($script:StoppedDesignerIds)
            }
        }

        $result.exceeded | Should -BeTrue
        $result.liveness | Should -Be "stalled-timeout"
        $result.stage | Should -Be "config-load.designer-stalled-timeout"
        $result.cleanup.confirmed | Should -BeTrue
        @($result.stopped) | Should -Be @(8250, 8251)
    }

    It "requires full infobase release by default and bypasses it only when explicitly allowed" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $script:InfoBaseReleaseChecks = 0
            function Get-DesignerInvocationProcessState {
                return [pscustomobject]@{
                    querySucceeded = $true; active = $false; processIds = @()
                    cpuSampleAvailable = $true; cpuTime100ns = [int64]0
                    workingSetSampleAvailable = $true; workingSetMb = 0; detail = ""
                }
            }
            function Test-DesignerInfoBaseReleased {
                $script:InfoBaseReleaseChecks++
                return $false
            }

            $context = [pscustomobject]@{
                launcherExited = $true; observedAtUtc = [DateTime]::UtcNow
                timeoutRemainingSeconds = 3600; postExitElapsedSeconds = 1; processId = 8270
            }
            $defaultState = New-DesignerInvocationProbeState -LauncherProcessId 8270
            $defaultState.processesReleaseConfirmed = $true
            $defaultResult = Test-DesignerInvocationReleased `
                -ProbeState $defaultState `
                -ProbeContext $context `
                -LogPath (Join-Path $TestDrive "default-release.log") `
                -InfoBaseKind file `
                -InfoBasePath (Join-Path $TestDrive "base") `
                -OperationKind "designer-command" 6>$null

            $compatibleState = New-DesignerInvocationProbeState -LauncherProcessId 8271
            $compatibleState.processesReleaseConfirmed = $true
            $compatibleResult = Test-DesignerInvocationReleased `
                -ProbeState $compatibleState `
                -ProbeContext $context `
                -LogPath (Join-Path $TestDrive "compatible-release.log") `
                -InfoBaseKind file `
                -InfoBasePath (Join-Path $TestDrive "base") `
                -OperationKind "dump-config-to-files" `
                -RequireInfoBaseRelease:$false 6>$null

            [pscustomobject]@{
                defaultResult = $defaultResult
                compatibleResult = $compatibleResult
                infoBaseReleaseChecks = $script:InfoBaseReleaseChecks
            }
        }

        $result.defaultResult | Should -BeFalse
        $result.compatibleResult | Should -BeTrue
        $result.infoBaseReleaseChecks | Should -Be 1
    }

    It "returns a stable Designer stall error after owned cleanup" {
        $fixtureRoot = Join-Path $TestDrive "designer-stall-call"
        $basePath = Join-Path $fixtureRoot "base"
        $platformPath = Join-Path $fixtureRoot "1cv8.exe"
        New-Item -ItemType Directory -Force -Path $basePath | Out-Null
        New-Item -ItemType File -Force -Path $platformPath | Out-Null
        New-Item -ItemType File -Force -Path (Join-Path $basePath "1Cv8.1CD") | Out-Null

        $result = & {
            . $HelperPath -ProjectRoot $fixtureRoot -Action help *> $null
            $script:Config = [pscustomobject]@{
                platformPath = $platformPath
                logsPath = "logs"
                designerStallWarningSeconds = 30
                designerStallTimeoutSeconds = 60
            }
            $script:StoppedDesignerIds = [System.Collections.Generic.List[int]]::new()
            function Get-DesignerInvocationProcessState {
                return [pscustomobject]@{
                    querySucceeded = $true; active = $true; processIds = @(8260, 8261)
                    cpuSampleAvailable = $true; cpuTime100ns = [int64]10000000
                    workingSetSampleAvailable = $true; workingSetMb = 256; detail = ""
                }
            }
            function Test-DesignerInfoBaseReleased { return $false }
            function Get-Process {
                param([int]$Id, [object]$ErrorAction)
                return [pscustomobject]@{ Id = $Id; HasExited = $false }
            }
            function Stop-NativeProcessForSafety {
                param([object]$Process)
                $script:StoppedDesignerIds.Add([int]$Process.Id) | Out-Null
                return [pscustomobject]@{ confirmed = $true; error = "" }
            }
            function Invoke-NativeProcessAndWaitResult {
                param(
                    [string]$FilePath, [string[]]$Arguments, [int]$TimeoutSeconds = 0,
                    [scriptblock]$OnTimeout = $null, [scriptblock]$CompletionProbe = $null,
                    [int]$CompletionGraceSeconds = 10, [int]$PostExitProbeSeconds = 0,
                    [int]$MaxWorkingSetMb = 0
                )
                $startedAt = [DateTime]::UtcNow
                & $CompletionProbe ([pscustomobject]@{
                    launcherExited = $false; observedAtUtc = $startedAt
                    timeoutRemainingSeconds = $TimeoutSeconds; processId = 8260
                }) | Out-Null
                & $CompletionProbe ([pscustomobject]@{
                    launcherExited = $false; observedAtUtc = $startedAt.AddSeconds(61)
                    timeoutRemainingSeconds = ($TimeoutSeconds - 61); processId = 8260
                }) | Out-Null
                return [pscustomobject]@{
                    processId = 8260; exitCode = 1; timedOut = $false
                    memoryLimitExceeded = $false; memoryMonitorFailed = $false
                    memoryMonitorError = ""; peakWorkingSetMb = 256
                    terminationConfirmed = $true; terminationError = ""
                    postExitProbeTimedOut = $false
                }
            }

            $message = try {
                Invoke-Designer -InfoBasePath $basePath -InfoBaseKind file -DesignerArgs @("/UpdateDBCfg") 6>$null | Out-Null
                ""
            } catch {
                $_.Exception.Message
            }
            [pscustomobject]@{ message = $message; stopped = @($script:StoppedDesignerIds) }
        }

        $result.message | Should -Match '^DESIGNER_STALL_TIMEOUT\b'
        $result.message | Should -Match 'stallTimeoutSeconds=60'
        $result.message | Should -Match 'ownedCleanupConfirmed=True'
        @($result.stopped) | Should -Be @(8260, 8261)
    }

    It "stops only tracked Designer processes during the hard-timeout cleanup" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $script:StoppedDesignerIds = [System.Collections.Generic.List[int]]::new()
            function Get-DesignerInvocationProcessState {
                return [pscustomobject]@{
                    querySucceeded = $true
                    active = $true
                    processIds = @(8301, 8302)
                    detail = ""
                }
            }
            function Get-Process {
                param([int]$Id, [object]$ErrorAction)
                return [pscustomobject]@{ Id = $Id; HasExited = $false }
            }
            function Stop-NativeProcessForSafety {
                param([object]$Process)
                $script:StoppedDesignerIds.Add([int]$Process.Id) | Out-Null
                return [pscustomobject]@{ confirmed = $true; error = "" }
            }

            $cleanup = Stop-DesignerInvocationOwnedProcesses `
                -ProbeState (New-DesignerInvocationProbeState -LauncherProcessId 8301 -StallWarningSeconds 30 -StallTimeoutSeconds 60) `
                -LogPath (Join-Path $TestDrive "owned-timeout.log")
            [pscustomobject]@{ cleanup = $cleanup; stopped = @($script:StoppedDesignerIds) }
        }

        $result.cleanup.attempted | Should -BeTrue
        $result.cleanup.confirmed | Should -BeTrue
        @($result.cleanup.processIds) | Should -Be @(8301, 8302)
        @($result.stopped) | Should -Be @(8301, 8302)
    }

    It "validates the configurable stall warning and fail-closed stall timeout" {
        $result = & {
            $savedDirect = $env:DESIGNER_STALL_WARNING_SECONDS
            $savedPrefixed = $env:AGENT_1C_DESIGNER_STALL_WARNING_SECONDS
            $savedTimeout = $env:DESIGNER_STALL_TIMEOUT_SECONDS
            $savedPrefixedTimeout = $env:AGENT_1C_DESIGNER_STALL_TIMEOUT_SECONDS
            try {
                $env:DESIGNER_STALL_WARNING_SECONDS = $null
                $env:AGENT_1C_DESIGNER_STALL_WARNING_SECONDS = $null
                $env:DESIGNER_STALL_TIMEOUT_SECONDS = $null
                $env:AGENT_1C_DESIGNER_STALL_TIMEOUT_SECONDS = $null
                . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
                $script:Config = [pscustomobject]@{}
                $defaultValue = Get-DesignerStallWarningSeconds
                $defaultTimeout = Get-DesignerStallTimeoutSeconds
                $script:Config = [pscustomobject]@{ designerStallWarningSeconds = 90 }
                $projectValue = Get-DesignerStallWarningSeconds
                $env:DESIGNER_STALL_WARNING_SECONDS = "45"
                $worktreeValue = Get-DesignerStallWarningSeconds
                $env:DESIGNER_STALL_WARNING_SECONDS = "10"
                $invalid = try { Get-DesignerStallWarningSeconds | Out-Null; "" } catch { $_.Exception.Message }
                $env:DESIGNER_STALL_WARNING_SECONDS = "300"
                $env:DESIGNER_STALL_TIMEOUT_SECONDS = "300"
                $invalidOrder = try { New-DesignerInvocationProbeState -LauncherProcessId 1 | Out-Null; "" } catch { $_.Exception.Message }
                [pscustomobject]@{
                    defaultValue = $defaultValue
                    defaultTimeout = $defaultTimeout
                    projectValue = $projectValue
                    worktreeValue = $worktreeValue
                    invalid = $invalid
                    invalidOrder = $invalidOrder
                }
            } finally {
                $env:DESIGNER_STALL_WARNING_SECONDS = $savedDirect
                $env:AGENT_1C_DESIGNER_STALL_WARNING_SECONDS = $savedPrefixed
                $env:DESIGNER_STALL_TIMEOUT_SECONDS = $savedTimeout
                $env:AGENT_1C_DESIGNER_STALL_TIMEOUT_SECONDS = $savedPrefixedTimeout
            }
        }

        $result.defaultValue | Should -Be 300
        $result.defaultTimeout | Should -Be 600
        $result.projectValue | Should -Be 90
        $result.worktreeValue | Should -Be 45
        $result.invalid | Should -Match "between 30 and 86400"
        $result.invalidOrder | Should -Match "must be greater"
    }

    It "waits for a combined repository and database update to release the infobase without depending on localized success text" {
        $fixtureRoot = Join-Path $TestDrive "repository-evidence"
        $basePath = Join-Path $fixtureRoot "base"
        $platformPath = Join-Path $fixtureRoot "1cv8.exe"
        New-Item -ItemType Directory -Force -Path $basePath | Out-Null
        New-Item -ItemType File -Force -Path $platformPath | Out-Null
        New-Item -ItemType File -Force -Path (Join-Path $basePath "1Cv8.1CD") | Out-Null

        $result = & {
            . $HelperPath -ProjectRoot $fixtureRoot -Action help *> $null
            $script:Config = [pscustomobject]@{
                platformPath = $platformPath
                logsPath = "logs"
                designerMaxWorkingSetMb = 0
                designerOperationTimeoutSeconds = 30
                designerDumpStabilitySeconds = 0
                completionPostExitTimeoutSeconds = 75
            }
            $script:ProbeBeforeEvidence = $null
            $script:ProbeWhileLocked = $null
            $script:ProbeAfterRelease = $null
            $script:CapturedTimeout = 0
            $script:CapturedPostExitProbeSeconds = 0
            function Invoke-NativeProcessAndWaitResult {
                param(
                    [string]$FilePath,
                    [string[]]$Arguments,
                    [int]$TimeoutSeconds = 0,
                    [scriptblock]$OnTimeout = $null,
                    [scriptblock]$CompletionProbe = $null,
                    [int]$CompletionGraceSeconds = 10,
                    [int]$PostExitProbeSeconds = 0,
                    [int]$MaxWorkingSetMb = 0
                )
                $script:CapturedTimeout = $TimeoutSeconds
                $script:CapturedPostExitProbeSeconds = $PostExitProbeSeconds
                $outIndex = [Array]::IndexOf($Arguments, "/Out")
                $logPath = [string]$Arguments[$outIndex + 1]
                $runningContext = [pscustomobject]@{
                    launcherExited = $false
                    launcherExitCode = 0
                    processId = 7001
                    postExitElapsedSeconds = 0
                }
                $exitedContext = [pscustomobject]@{
                    launcherExited = $true
                    launcherExitCode = 0
                    processId = 7001
                    postExitElapsedSeconds = 0
                }
                $script:ProbeBeforeEvidence = [bool](& $CompletionProbe $runningContext)
                $englishSuccess = "Configuration update from repository completed successfully.`r`nDatabase configuration update completed successfully."
                [System.IO.File]::WriteAllText($logPath, $englishSuccess, (Get-Utf8Encoding))
                $holder = [System.IO.File]::Open(
                    (Join-Path $basePath "1Cv8.1CD"),
                    [System.IO.FileMode]::Open,
                    [System.IO.FileAccess]::Read,
                    [System.IO.FileShare]::Read
                )
                try {
                    $script:ProbeWhileLocked = [bool](& $CompletionProbe $exitedContext)
                } finally {
                    $holder.Dispose()
                }
                Start-Sleep -Milliseconds 1100
                $script:ProbeAfterRelease = [bool](& $CompletionProbe $exitedContext)
                return [pscustomobject]@{
                    processId = 7001; exitCode = 0; timedOut = $false
                    memoryLimitExceeded = $false; memoryMonitorFailed = $false; memoryMonitorError = ""
                    peakWorkingSetMb = 0; workingSetLimitMb = 0
                    terminationConfirmed = $true; terminationError = ""; completedByProbe = $true
                    launcherExited = $true; launcherExitCode = 0
                }
            }

            $output = (& {
                Invoke-Designer `
                    -InfoBasePath $basePath `
                    -InfoBaseKind "file" `
                    -User "Admin" `
                    -Password "ib-secret" `
                    -DesignerArgs @(
                        "/ConfigurationRepositoryF", "tcp://repository",
                        "/ConfigurationRepositoryN", "developer",
                        "/ConfigurationRepositoryP", "repo-secret",
                        "/ConfigurationRepositoryUpdateCfg", "-force", "/UpdateDBCfg"
                    ) | Out-Null
            } 6>&1 | Out-String)
            [pscustomobject]@{
                output = $output
                before = $script:ProbeBeforeEvidence
                whileLocked = $script:ProbeWhileLocked
                afterRelease = $script:ProbeAfterRelease
                timeout = $script:CapturedTimeout
                postExitProbeSeconds = $script:CapturedPostExitProbeSeconds
            }
        }

        $result.before | Should -BeFalse
        $result.whileLocked | Should -BeFalse
        $result.afterRelease | Should -BeTrue
        $result.timeout | Should -Be 30
        $result.postExitProbeSeconds | Should -Be 30
        $result.output | Should -Not -Match "ib-secret"
        $result.output | Should -Not -Match "repo-secret"
        $result.output | Should -Match ([regex]::Escape("<hidden>"))
    }

    It "does not accept configuration update evidence until the file infobase is released" {
        $fixtureRoot = Join-Path $TestDrive "configuration-update-with-open-session"
        $basePath = Join-Path $fixtureRoot "base"
        $databasePath = Join-Path $basePath "1Cv8.1CD"
        $platformPath = Join-Path $fixtureRoot "1cv8.exe"
        New-Item -ItemType Directory -Force -Path $basePath | Out-Null
        New-Item -ItemType File -Force -Path $platformPath, $databasePath | Out-Null

        $result = & {
            . $HelperPath -ProjectRoot $fixtureRoot -Action help *> $null
            $script:Config = [pscustomobject]@{
                platformPath = $platformPath
                logsPath = "logs"
                designerMaxWorkingSetMb = 0
                designerOperationTimeoutSeconds = 30
                designerDumpStabilitySeconds = 0
                completionPostExitTimeoutSeconds = 9
            }
            $script:ProbePassed = $false
            $script:ProbeWhileLocked = $false
            $script:CapturedPostExitProbeSeconds = 0
            $script:DatabaseHolder = $null
            function Invoke-NativeProcessAndWaitResult {
                param(
                    [string]$FilePath, [string[]]$Arguments, [int]$TimeoutSeconds = 0,
                    [scriptblock]$OnTimeout = $null, [scriptblock]$CompletionProbe = $null,
                    [int]$CompletionGraceSeconds = 10, [int]$PostExitProbeSeconds = 0,
                    [int]$MaxWorkingSetMb = 0
                )
                $script:CapturedPostExitProbeSeconds = $PostExitProbeSeconds
                $outIndex = [Array]::IndexOf($Arguments, "/Out")
                $logPath = [string]$Arguments[$outIndex + 1]
                [System.IO.File]::WriteAllText($logPath, (Get-DesignerConfigurationUpdateSuccessText), (Get-Utf8Encoding))
                $context = [pscustomobject]@{
                    launcherExited = $true
                    launcherExitCode = 0
                    processId = 7005
                    postExitElapsedSeconds = 0
                }
                $script:ProbeWhileLocked = [bool](& $CompletionProbe $context)
                $script:DatabaseHolder.Dispose()
                $script:DatabaseHolder = $null
                Start-Sleep -Milliseconds 1100
                $script:ProbePassed = [bool](& $CompletionProbe $context)
                return [pscustomobject]@{
                    processId = 7005; exitCode = 0; timedOut = $false; postExitProbeTimedOut = $false
                    memoryLimitExceeded = $false; memoryMonitorFailed = $false; memoryMonitorError = ""
                    peakWorkingSetMb = 0; workingSetLimitMb = 0
                    terminationConfirmed = $true; terminationError = ""; completedByProbe = $script:ProbePassed
                    launcherExited = $true; launcherExitCode = 0
                }
            }

            $script:DatabaseHolder = [System.IO.File]::Open($databasePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
            try {
                $exclusiveRelease = Test-DesignerInfoBaseReleased -InfoBaseKind "file" -InfoBasePath $basePath
                Invoke-Designer -InfoBasePath $basePath -InfoBaseKind "file" -DesignerArgs @("/LoadConfigFromFiles", (Join-Path $fixtureRoot "src"), "/UpdateDBCfg") 6>$null | Out-Null
                [pscustomobject]@{
                    exclusiveRelease = $exclusiveRelease
                    probeWhileLocked = $script:ProbeWhileLocked
                    probePassed = $script:ProbePassed
                    postExitProbeSeconds = $script:CapturedPostExitProbeSeconds
                }
            } finally {
                if ($null -ne $script:DatabaseHolder) {
                    $script:DatabaseHolder.Dispose()
                }
            }
        }

        $result.exclusiveRelease | Should -BeFalse
        $result.probeWhileLocked | Should -BeFalse
        $result.probePassed | Should -BeTrue
        $result.postExitProbeSeconds | Should -Be 30
    }

    It "accepts a stable empty log after an extension configuration update exits successfully" {
        $fixtureRoot = Join-Path $TestDrive "extension-update-empty-log"
        $basePath = Join-Path $fixtureRoot "base"
        $platformPath = Join-Path $fixtureRoot "1cv8.exe"
        New-Item -ItemType Directory -Force -Path $basePath | Out-Null
        New-Item -ItemType File -Force -Path $platformPath, (Join-Path $basePath "1Cv8.1CD") | Out-Null

        $result = & {
            . $HelperPath -ProjectRoot $fixtureRoot -Action help *> $null
            $script:Config = [pscustomobject]@{
                platformPath = $platformPath
                logsPath = "logs"
                designerMaxWorkingSetMb = 0
                designerOperationTimeoutSeconds = 30
                designerDumpStabilitySeconds = 0
                completionPostExitTimeoutSeconds = 9
            }
            $script:ProbePassed = $false
            function Invoke-NativeProcessAndWaitResult {
                param(
                    [string]$FilePath, [string[]]$Arguments, [int]$TimeoutSeconds = 0,
                    [scriptblock]$OnTimeout = $null, [scriptblock]$CompletionProbe = $null,
                    [int]$CompletionGraceSeconds = 10, [int]$PostExitProbeSeconds = 0,
                    [int]$MaxWorkingSetMb = 0
                )
                $outIndex = [Array]::IndexOf($Arguments, "/Out")
                $logPath = [string]$Arguments[$outIndex + 1]
                [System.IO.File]::WriteAllText($logPath, "", (Get-Utf8Encoding))
                $context = [pscustomobject]@{
                    launcherExited = $true
                    launcherExitCode = 0
                    processId = 7007
                    postExitElapsedSeconds = 0
                }
                $script:ProbePassed = [bool](& $CompletionProbe $context)
                Start-Sleep -Milliseconds 1100
                $script:ProbePassed = [bool](& $CompletionProbe $context)
                return [pscustomobject]@{
                    processId = 7007; exitCode = 0; timedOut = $false; postExitProbeTimedOut = $false
                    memoryLimitExceeded = $false; memoryMonitorFailed = $false; memoryMonitorError = ""
                    peakWorkingSetMb = 0; workingSetLimitMb = 0
                    terminationConfirmed = $true; terminationError = ""; completedByProbe = $script:ProbePassed
                    launcherExited = $true; launcherExitCode = 0
                }
            }

            Invoke-Designer `
                -InfoBasePath $basePath `
                -InfoBaseKind "file" `
                -DesignerArgs @("/LoadConfigFromFiles", (Join-Path $fixtureRoot "src"), "-Extension", "Smoke", "/UpdateDBCfg") `
                6>$null | Out-Null
            $script:ProbePassed
        }

        $result | Should -BeTrue
    }

    It "reports a configuration post-exit evidence timeout instead of accepting exit code zero" {
        $fixtureRoot = Join-Path $TestDrive "configuration-post-exit-timeout"
        $basePath = Join-Path $fixtureRoot "base"
        $platformPath = Join-Path $fixtureRoot "1cv8.exe"
        New-Item -ItemType Directory -Force -Path $basePath | Out-Null
        New-Item -ItemType File -Force -Path $platformPath, (Join-Path $basePath "1Cv8.1CD") | Out-Null

        $message = & {
            . $HelperPath -ProjectRoot $fixtureRoot -Action help *> $null
            $script:Config = [pscustomobject]@{
                platformPath = $platformPath
                logsPath = "logs"
                designerMaxWorkingSetMb = 0
                designerOperationTimeoutSeconds = 30
                completionPostExitTimeoutSeconds = 11
            }
            function Invoke-NativeProcessAndWaitResult {
                return [pscustomobject]@{
                    processId = 7006; exitCode = 0; timedOut = $false; postExitProbeTimedOut = $true
                    memoryLimitExceeded = $false; memoryMonitorFailed = $false; memoryMonitorError = ""
                    peakWorkingSetMb = 0; workingSetLimitMb = 0
                    terminationConfirmed = $true; terminationError = ""; completedByProbe = $false
                    launcherExited = $true; launcherExitCode = 0
                }
            }
            try {
                Invoke-Designer -InfoBasePath $basePath -InfoBaseKind "file" -DesignerArgs @("/UpdateDBCfg") 6>$null | Out-Null
            } catch {
                return $_.Exception.Message
            }
            return ""
        }

        $message | Should -Match "^DESIGNER_POST_EXIT_PROBE_TIMEOUT "
        $message | Should -Match "operation=configuration-update"
        $message | Should -Match "timeoutSeconds=30"
    }

    It "assigns bounded completion evidence to every other Designer command family used by the helper" {
        $fixtureRoot = Join-Path $TestDrive "other-designer-commands"
        $basePath = Join-Path $fixtureRoot "base"
        $platformPath = Join-Path $fixtureRoot "1cv8.exe"
        New-Item -ItemType Directory -Force -Path $basePath | Out-Null
        New-Item -ItemType File -Force -Path $platformPath | Out-Null
        New-Item -ItemType File -Force -Path (Join-Path $basePath "1Cv8.1CD") | Out-Null

        $result = & {
            . $HelperPath -ProjectRoot $fixtureRoot -Action help *> $null
            $script:Config = [pscustomobject]@{
                platformPath = $platformPath
                logsPath = "logs"
                designerMaxWorkingSetMb = 0
                designerOperationTimeoutSeconds = 30
                designerDumpStabilitySeconds = 0
                completionPostExitTimeoutSeconds = 7
            }
            $script:Observed = [System.Collections.Generic.List[object]]::new()
            function Test-DesignerInvocationReleased {
                param(
                    [object]$ProbeState,
                    [object]$ProbeContext,
                    [string]$LogPath,
                    [string]$InfoBaseKind,
                    [string]$InfoBasePath,
                    [string]$OperationKind
                )
                return ($null -ne $ProbeContext -and [bool]$ProbeContext.launcherExited)
            }
            function Invoke-NativeProcessAndWaitResult {
                param(
                    [string]$FilePath,
                    [string[]]$Arguments,
                    [int]$TimeoutSeconds = 0,
                    [scriptblock]$OnTimeout = $null,
                    [scriptblock]$CompletionProbe = $null,
                    [int]$CompletionGraceSeconds = 10,
                    [int]$PostExitProbeSeconds = 0,
                    [int]$MaxWorkingSetMb = 0
                )
                $outIndex = [Array]::IndexOf($Arguments, "/Out")
                $logPath = [string]$Arguments[$outIndex + 1]
                $operationCandidates = @($Arguments | Where-Object { $_ -like "/*" -and $_ -notin @("/F", "/Out", "/DisableStartupMessages", "/DisableStartupDialogs", "/UpdateDBCfg") } | Select-Object -Last 1)
                $operation = if ($operationCandidates.Count -gt 0) { [string]$operationCandidates[0] } else { "unknown" }
                $targetPath = ""
                foreach ($command in @("/DumpCfg", "/DumpIB")) {
                    $index = [Array]::IndexOf($Arguments, $command)
                    if ($index -ge 0) { $operation = $command; $targetPath = [string]$Arguments[$index + 1]; break }
                }
                $externalIndex = [Array]::IndexOf($Arguments, "/LoadExternalDataProcessorOrReportFromFiles")
                if ($externalIndex -ge 0) {
                    $operation = "/LoadExternalDataProcessorOrReportFromFiles"
                    $targetPath = [string]$Arguments[$externalIndex + 2]
                }
                if ($targetPath) {
                    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $targetPath) | Out-Null
                    Set-Content -LiteralPath $targetPath -Encoding Byte -Value ([byte[]](1, 2, 3))
                } else {
                    $logText = $(if ([Array]::IndexOf($Arguments, "/UpdateDBCfg") -ge 0) { Get-DesignerConfigurationUpdateSuccessText } else { "completed" })
                    [System.IO.File]::WriteAllText($logPath, $logText, (Get-Utf8Encoding))
                }
                $probePassed = [bool](& $CompletionProbe ([pscustomobject]@{ launcherExited = $true; launcherExitCode = 0; processId = 7002 }))
                $script:Observed.Add([pscustomobject]@{ operation = $operation; timeout = $TimeoutSeconds; postExitProbeSeconds = $PostExitProbeSeconds; probePassed = $probePassed }) | Out-Null
                return [pscustomobject]@{
                    processId = 7002; exitCode = 0; timedOut = $false
                    memoryLimitExceeded = $false; memoryMonitorFailed = $false; memoryMonitorError = ""
                    peakWorkingSetMb = 0; workingSetLimitMb = 0
                    terminationConfirmed = $true; terminationError = ""; completedByProbe = $true
                    launcherExited = $true; launcherExitCode = 0
                }
            }

            $outputs = Join-Path $fixtureRoot "outputs"
            $commands = @(
                @("/LoadConfigFromFiles", (Join-Path $fixtureRoot "src"), "/UpdateDBCfg"),
                @("/LoadCfg", (Join-Path $fixtureRoot "input.cfe"), "-Extension", "Test", "/UpdateDBCfg"),
                @("/RestoreIB", (Join-Path $fixtureRoot "input.dt")),
                @("/ConfigurationRepositoryUnbindCfg", "-force"),
                @("/DumpDBCfgList", "-Extension", "Test"),
                @("/UpdateDBCfg"),
                @("/DumpCfg", (Join-Path $outputs "result.cf")),
                @("/DumpIB", (Join-Path $outputs "result.dt")),
                @("/LoadExternalDataProcessorOrReportFromFiles", (Join-Path $fixtureRoot "epf-src.xml"), (Join-Path $outputs "tool.epf"))
            )
            foreach ($commandArgs in $commands) {
                Invoke-Designer -InfoBasePath $basePath -InfoBaseKind "file" -DesignerArgs $commandArgs 6>$null | Out-Null
            }
            return @($script:Observed)
        }

        @($result).Count | Should -Be 9
        @($result | Where-Object { $_.timeout -ne 30 }).Count | Should -Be 0
        @($result | Where-Object {
            $expected = 30
            $_.postExitProbeSeconds -ne $expected
        }).Count | Should -Be 0
        @($result | Where-Object { -not $_.probePassed }).Count | Should -Be 0
    }

    It "checks a staged dump only after launcher exit and retains stability across probe calls" {
        $fixtureRoot = Join-Path $TestDrive "stable-staged-dump"
        $basePath = Join-Path $fixtureRoot "base"
        $platformPath = Join-Path $fixtureRoot "1cv8.exe"
        $dumpPath = Join-Path $fixtureRoot "staged"
        New-Item -ItemType Directory -Force -Path $basePath, $dumpPath | Out-Null
        New-Item -ItemType File -Force -Path $platformPath | Out-Null
        New-Item -ItemType File -Force -Path (Join-Path $basePath "1Cv8.1CD") | Out-Null

        $result = & {
            . $HelperPath -ProjectRoot $fixtureRoot -Action help *> $null
            $script:Config = [pscustomobject]@{
                platformPath = $platformPath
                logsPath = "logs"
                designerMaxWorkingSetMb = 0
                designerOperationTimeoutSeconds = 30
                designerDumpStabilitySeconds = 1
            }
            $script:DumpArtifactReady = $false
            $script:DumpArtifactCalls = 0
            $script:DumpArtifactWrittenAtTicks = 0
            $script:InfoBaseReleaseChecks = 0
            function Test-DesignerInfoBaseReleased {
                $script:InfoBaseReleaseChecks++
                return $false
            }
            function Get-DesignerDumpArtifactState {
                param([string]$Path)
                $script:DumpArtifactCalls++
                if (-not $script:DumpArtifactReady) {
                    return [pscustomobject]@{
                        ready = $false
                        signature = ""
                        fileCount = 0
                        totalBytes = [int64]0
                        latestWriteTimeUtcTicks = [int64]0
                    }
                }
                return [pscustomobject]@{
                    ready = $true
                    signature = "19409|664534671|$script:DumpArtifactWrittenAtTicks"
                    fileCount = 19409
                    totalBytes = [int64]664534671
                    latestWriteTimeUtcTicks = [int64]$script:DumpArtifactWrittenAtTicks
                }
            }
            function Invoke-NativeProcessAndWaitResult {
                param(
                    [string]$FilePath,
                    [string[]]$Arguments,
                    [int]$TimeoutSeconds = 0,
                    [scriptblock]$OnTimeout = $null,
                    [scriptblock]$CompletionProbe = $null,
                    [int]$CompletionGraceSeconds = 10,
                    [int]$PostExitProbeSeconds = 0,
                    [int]$MaxWorkingSetMb = 0
                )
                $script:CapturedDumpPostExitProbeSeconds = $PostExitProbeSeconds
                $runningContext = [pscustomobject]@{ launcherExited = $false; launcherExitCode = $null; processId = 7004 }
                foreach ($index in 1..8) {
                    (& $CompletionProbe $runningContext) | Should -BeFalse
                }
                $script:CallsWhileRunning = $script:DumpArtifactCalls

                $script:DumpArtifactReady = $true
                $script:DumpArtifactWrittenAtTicks = [DateTime]::UtcNow.Ticks
                $exitedContext = [pscustomobject]@{ launcherExited = $true; launcherExitCode = 0; processId = 7004 }
                $script:FirstExitedResult = [bool](& $CompletionProbe $exitedContext)
                $script:CallsAfterFirstExitProbe = $script:DumpArtifactCalls
                foreach ($index in 1..8) {
                    (& $CompletionProbe $exitedContext) | Should -BeFalse
                }
                $script:CallsAfterImmediateProbes = $script:DumpArtifactCalls

                Start-Sleep -Milliseconds 1100
                $script:StableExitedResult = [bool](& $CompletionProbe $exitedContext)
                return [pscustomobject]@{
                    processId = 7004; exitCode = 0; timedOut = $false
                    memoryLimitExceeded = $false; memoryMonitorFailed = $false; memoryMonitorError = ""
                    peakWorkingSetMb = 0; workingSetLimitMb = 0
                    terminationConfirmed = $true; terminationError = ""; completedByProbe = $script:StableExitedResult
                    launcherExited = $true; launcherExitCode = 0
                }
            }

            Invoke-Designer `
                -InfoBasePath $basePath `
                -InfoBaseKind "file" `
                -DesignerArgs @("/DumpConfigToFiles", $dumpPath, "-Format", "Hierarchical") 6>$null | Out-Null
            [pscustomobject]@{
                callsWhileRunning = $script:CallsWhileRunning
                firstExitedResult = $script:FirstExitedResult
                callsAfterFirstExitProbe = $script:CallsAfterFirstExitProbe
                callsAfterImmediateProbes = $script:CallsAfterImmediateProbes
                stableExitedResult = $script:StableExitedResult
                finalArtifactCalls = $script:DumpArtifactCalls
                postExitProbeSeconds = $script:CapturedDumpPostExitProbeSeconds
                infoBaseReleaseChecks = $script:InfoBaseReleaseChecks
            }
        }

        $result.callsWhileRunning | Should -Be 1
        $result.firstExitedResult | Should -BeFalse
        $result.callsAfterFirstExitProbe | Should -Be 1
        $result.callsAfterImmediateProbes | Should -Be 1
        $result.stableExitedResult | Should -BeTrue
        $result.finalArtifactCalls | Should -Be 2
        $result.postExitProbeSeconds | Should -Be 30
        $result.infoBaseReleaseChecks | Should -Be 0
    }

    It "ignores error words embedded in Designer metadata identifiers" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $logPath = Join-Path $TestDrive "metadata-identifiers.log"
            $decode = { param($value) [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($value)) }
            $metadataLines = @((& $decode "0J7QsdGJ0LDRj9Ck0L7RgNC80LAu0J7RiNC40LHQutCw0KHQvtC+0LHRidC10L3QuNGP0JLQodC70YPQttCx0YPQotC10YXQvdC40YfQtdGB0LrQvtC50J/QvtC00LTQtdGA0LbQutC4"), (& $decode "0J7QsdGA0LDQsdC+0YLQutCwLtCg0LDQsdC+0YLQsNCh0KDQtdC30YPQu9GM0YLQsNGC0LDQvNC40J7QsdC80LXQvdCwLtCk0L7RgNC80LAu0J7RiNC40LHQutC40JrQvtC90LLQtdGA0YLQsNGG0LjQuA=="), (& $decode "0J7QsdGA0LDQsdC+0YLQutCwLtCg0LDQsdC+0YLQsNCh0KDQtdC30YPQu9GM0YLQsNGC0LDQvNC40J7QsdC80LXQvdCwLtCc0LDQutC10YIu0KDQtdC60L7QvNC10L3QtNCw0YbQuNC40J7RiNC40LHQutCw0J/RgNC+0LLQtdC00LXQvdC40Y/QndC10J7QsdC90L7QstC70LXQvQ=="), "CommonForm.ErrorMessage", "Report.ErrorsCount")
            [System.IO.File]::WriteAllLines($logPath, $metadataLines, (Get-Utf8Encoding)); $metadataState = Get-DesignerLogTerminalState -LogPath $logPath -SuccessPattern ""
            $cases = @([pscustomobject]@{ text = (& $decode "0J7RiNC40LHQutCwOiDQvtC/0LXRgNCw0YbQuNGPINC90LUg0LLRi9C/0L7Qu9C90LXQvdCw"); expected = "failure" }, [pscustomobject]@{ text = "Error: operation aborted"; expected = "failure" }, [pscustomobject]@{ text = "Errors detected"; expected = "failure" }, [pscustomobject]@{ text = "Operation failed"; expected = "failure" }, [pscustomobject]@{ text = "0 errors"; expected = "pending" }, [pscustomobject]@{ text = "no errors"; expected = "pending" })
            $caseResults = foreach ($case in $cases) { [System.IO.File]::WriteAllText($logPath, $case.text, (Get-Utf8Encoding)); $state = Get-DesignerLogTerminalState -LogPath $logPath -SuccessPattern ""; [pscustomobject]@{ text = $case.text; expected = $case.expected; state = $state } }
            [pscustomobject]@{ metadataState = $metadataState; caseResults = @($caseResults) }
        }

        $result.metadataState.state | Should -Be "pending"
        $result.metadataState.detail | Should -BeNullOrEmpty
        foreach ($case in $result.caseResults) { $case.state.state | Should -Be $case.expected; $case.state.detail | Should -Be $(if ($case.expected -eq "failure") { $case.text } else { "" }) }
    }

    It "does not complete a live Designer process from a repository log error alone" {
        $fixtureRoot = Join-Path $TestDrive "repository-lock-error"
        $basePath = Join-Path $fixtureRoot "base"
        $platformPath = Join-Path $fixtureRoot "1cv8.exe"
        New-Item -ItemType Directory -Force -Path $basePath | Out-Null
        New-Item -ItemType File -Force -Path $platformPath | Out-Null
        New-Item -ItemType File -Force -Path (Join-Path $basePath "1Cv8.1CD") | Out-Null

        $message = & {
            . $HelperPath -ProjectRoot $fixtureRoot -Action help *> $null
            $script:Config = [pscustomobject]@{
                platformPath = $platformPath
                logsPath = "logs"
                designerMaxWorkingSetMb = 0
                designerOperationTimeoutSeconds = 30
            }
            function Invoke-NativeProcessAndWaitResult {
                param(
                    [string]$FilePath, [string[]]$Arguments, [int]$TimeoutSeconds = 0,
                    [scriptblock]$OnTimeout = $null, [scriptblock]$CompletionProbe = $null,
                    [int]$CompletionGraceSeconds = 10, [int]$PostExitProbeSeconds = 0,
                    [int]$MaxWorkingSetMb = 0
                )
                $outIndex = [Array]::IndexOf($Arguments, "/Out")
                $logPath = [string]$Arguments[$outIndex + 1]
                $lockError = -join ([char[]](1054, 1096, 1080, 1073, 1082, 1072, 32, 1073, 1083, 1086, 1082, 1080, 1088, 1086, 1074, 1082, 1080, 32, 1080, 1085, 1092, 1086, 1088, 1084, 1072, 1094, 1080, 1086, 1085, 1085, 1086, 1081, 32, 1073, 1072, 1079, 1099))
                [System.IO.File]::WriteAllText($logPath, $lockError, (Get-Utf8Encoding))
                $script:LiveErrorProbeResult = [bool](& $CompletionProbe ([pscustomobject]@{ launcherExited = $false; launcherExitCode = $null; processId = 7003; observedAtUtc = [DateTime]::UtcNow; elapsedSeconds = 1; timeoutSeconds = 30; timeoutRemainingSeconds = 29; launcherExitedAtUtc = $null; postExitProbeDeadlineUtc = $null; postExitElapsedSeconds = 0 }))
                return [pscustomobject]@{
                    processId = 7003; exitCode = 0; timedOut = $false
                    memoryLimitExceeded = $false; memoryMonitorFailed = $false; memoryMonitorError = ""
                    peakWorkingSetMb = 0; workingSetLimitMb = 0
                    terminationConfirmed = $true; terminationError = ""; completedByProbe = $true
                    launcherExited = $true; launcherExitCode = 0
                }
            }

            try {
                Invoke-Designer -InfoBasePath $basePath -InfoBaseKind "file" -DesignerArgs @("/ConfigurationRepositoryUpdateCfg", "-force") 6>$null | Out-Null
            } catch {
                return $_.Exception.Message
            }
            return ""
        }

        $script:LiveErrorProbeResult | Should -BeFalse
        $message | Should -Match "repository update failed"
        $message | Should -Match "Log:"
    }

    It "installs a complete configuration dump transactionally" {
        $fixtureRoot = Join-Path $TestDrive "transactional-dump"
        $targetPath = Join-Path $fixtureRoot "src\cf"
        New-Item -ItemType Directory -Force -Path $targetPath | Out-Null
        Set-Content -LiteralPath (Join-Path $targetPath "Configuration.xml") -Encoding UTF8 -Value "old-configuration"
        Set-Content -LiteralPath (Join-Path $targetPath "ConfigDumpInfo.xml") -Encoding UTF8 -Value "old-dump-info"
        Set-Content -LiteralPath (Join-Path $targetPath "Old.xml") -Encoding UTF8 -Value "old"

        $result = & {
            . $HelperPath -ProjectRoot $fixtureRoot -Action help *> $null
            function Get-ExportPath { return "src/cf" }
            function Get-SourceUsesRepository { return $false }
            function Get-SourceInfoBasePath { return (Join-Path $script:ProjectRoot "base") }
            function Get-InfoBaseKind { return "file" }
            function Invoke-Designer {
                param([string]$InfoBasePath, [string]$InfoBaseKind, [string[]]$DesignerArgs)
                $dumpIndex = [Array]::IndexOf($DesignerArgs, "/DumpConfigToFiles")
                $script:DumpTarget = [string]$DesignerArgs[$dumpIndex + 1]
                Set-Content -LiteralPath (Join-Path $script:DumpTarget "Configuration.xml") -Encoding UTF8 -Value "new-configuration"
                Set-Content -LiteralPath (Join-Path $script:DumpTarget "ConfigDumpInfo.xml") -Encoding UTF8 -Value "new-dump-info"
                Set-Content -LiteralPath (Join-Path $script:DumpTarget "New.xml") -Encoding UTF8 -Value "new"
                $script:LastLogPath = Join-Path $script:ProjectRoot "logs\dump.log"
            }

            $dumpResult = Dump-ConfigToFiles
            [pscustomobject]@{
                dumpResult = $dumpResult
                dumpTarget = $script:DumpTarget
                oldExists = Test-Path -LiteralPath (Join-Path $targetPath "Old.xml")
                newExists = Test-Path -LiteralPath (Join-Path $targetPath "New.xml")
                configuration = Get-Content -LiteralPath (Join-Path $targetPath "Configuration.xml") -Raw
                transactionRootExists = Test-Path -LiteralPath (Split-Path -Parent $script:DumpTarget)
            }
        }

        $result.dumpTarget | Should -Not -Be $targetPath
        $result.dumpTarget | Should -Be (Join-Path $fixtureRoot ".tx\c\s")
        $result.dumpResult.transactional | Should -BeTrue
        $result.oldExists | Should -BeFalse
        $result.newExists | Should -BeTrue
        $result.configuration | Should -Match "new-configuration"
        $result.transactionRootExists | Should -BeFalse
    }

    It "preserves the previous dump and diagnostic staging when the new dump fails" {
        $fixtureRoot = Join-Path $TestDrive "failed-transactional-dump"
        $targetPath = Join-Path $fixtureRoot "src\cf"
        New-Item -ItemType Directory -Force -Path $targetPath | Out-Null
        Set-Content -LiteralPath (Join-Path $targetPath "Configuration.xml") -Encoding UTF8 -Value "old-configuration"
        Set-Content -LiteralPath (Join-Path $targetPath "ConfigDumpInfo.xml") -Encoding UTF8 -Value "old-dump-info"

        $result = & {
            . $HelperPath -ProjectRoot $fixtureRoot -Action help *> $null
            function Get-ExportPath { return "src/cf" }
            function Get-SourceUsesRepository { return $false }
            function Get-SourceInfoBasePath { return (Join-Path $script:ProjectRoot "base") }
            function Get-InfoBaseKind { return "file" }
            function Invoke-Designer {
                param([string]$InfoBasePath, [string]$InfoBaseKind, [string[]]$DesignerArgs)
                $dumpIndex = [Array]::IndexOf($DesignerArgs, "/DumpConfigToFiles")
                $script:DumpTarget = [string]$DesignerArgs[$dumpIndex + 1]
                Set-Content -LiteralPath (Join-Path $script:DumpTarget "partial.tmp") -Encoding UTF8 -Value "partial"
                throw "simulated Designer failure"
            }

            $message = ""
            try { Dump-ConfigToFiles | Out-Null } catch { $message = $_.Exception.Message }
            [pscustomobject]@{
                message = $message
                oldConfiguration = Get-Content -LiteralPath (Join-Path $targetPath "Configuration.xml") -Raw
                stagingExists = Test-Path -LiteralPath (Split-Path -Parent $script:DumpTarget)
                partialExists = Test-Path -LiteralPath (Join-Path $script:DumpTarget "partial.tmp")
            }
        }

        $result.message | Should -Match "simulated Designer failure"
        $result.message | Should -Match "Diagnostic staging"
        $result.oldConfiguration | Should -Match "old-configuration"
        $result.stagingExists | Should -BeTrue
        $result.partialExists | Should -BeTrue
    }
}
