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

    It "requires repository terminal evidence and keeps secrets out of command output" {
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
                completionPostExitTimeoutSeconds = 75
            }
            $script:ProbeBeforeEvidence = $null
            $script:ProbeAfterEvidence = $null
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
                $context = [pscustomobject]@{ launcherExited = $true; launcherExitCode = 0; processId = 7001 }
                $script:ProbeBeforeEvidence = [bool](& $CompletionProbe $context)
                $successText = -join ([char[]](1054, 1073, 1085, 1086, 1074, 1083, 1077, 1085, 1080, 1077, 32, 1082, 1086, 1085, 1092, 1080, 1075, 1091, 1088, 1072, 1094, 1080, 1080, 32, 1080, 1079, 32, 1093, 1088, 1072, 1085, 1080, 1083, 1080, 1097, 1072, 32, 1091, 1089, 1087, 1077, 1096, 1085, 1086, 32, 1079, 1072, 1074, 1077, 1088, 1096, 1077, 1085, 1086))
                [System.IO.File]::WriteAllText($logPath, $successText, (Get-Utf8Encoding))
                $script:ProbeAfterEvidence = [bool](& $CompletionProbe $context)
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
                after = $script:ProbeAfterEvidence
                timeout = $script:CapturedTimeout
                postExitProbeSeconds = $script:CapturedPostExitProbeSeconds
            }
        }

        $result.before | Should -BeFalse
        $result.after | Should -BeTrue
        $result.timeout | Should -Be 30
        $result.postExitProbeSeconds | Should -Be 75
        $result.output | Should -Not -Match "ib-secret"
        $result.output | Should -Not -Match "repo-secret"
        $result.output | Should -Match ([regex]::Escape("<hidden>"))
    }

    It "accepts configuration update terminal evidence while another process holds the file infobase" {
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
            $script:CapturedPostExitProbeSeconds = 0
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
                $script:ProbePassed = [bool](& $CompletionProbe $context)
                return [pscustomobject]@{
                    processId = 7005; exitCode = 0; timedOut = $false; postExitProbeTimedOut = $false
                    memoryLimitExceeded = $false; memoryMonitorFailed = $false; memoryMonitorError = ""
                    peakWorkingSetMb = 0; workingSetLimitMb = 0
                    terminationConfirmed = $true; terminationError = ""; completedByProbe = $script:ProbePassed
                    launcherExited = $true; launcherExitCode = 0
                }
            }

            $holder = [System.IO.File]::Open($databasePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
            try {
                $exclusiveRelease = Test-DesignerInfoBaseReleased -InfoBaseKind "file" -InfoBasePath $basePath
                Invoke-Designer -InfoBasePath $basePath -InfoBaseKind "file" -DesignerArgs @("/LoadConfigFromFiles", (Join-Path $fixtureRoot "src"), "/UpdateDBCfg") 6>$null | Out-Null
                [pscustomobject]@{
                    exclusiveRelease = $exclusiveRelease
                    probePassed = $script:ProbePassed
                    postExitProbeSeconds = $script:CapturedPostExitProbeSeconds
                }
            } finally {
                $holder.Dispose()
            }
        }

        $result.exclusiveRelease | Should -BeFalse
        $result.probePassed | Should -BeTrue
        $result.postExitProbeSeconds | Should -Be 9
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
        $message | Should -Match "timeoutSeconds=11"
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
                $operationCandidates = @($Arguments | Where-Object { $_ -like "/*" -and $_ -notin @("/F", "/Out", "/DisableStartupMessages", "/UpdateDBCfg") } | Select-Object -Last 1)
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
            $expected = $(if ($_.operation -in @("/LoadConfigFromFiles", "/LoadCfg", "unknown")) { 7 } else { 30 })
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
            }
        }

        $result.callsWhileRunning | Should -Be 1
        $result.firstExitedResult | Should -BeFalse
        $result.callsAfterFirstExitProbe | Should -Be 2
        $result.callsAfterImmediateProbes | Should -Be 2
        $result.stableExitedResult | Should -BeTrue
        $result.finalArtifactCalls | Should -Be 3
        $result.postExitProbeSeconds | Should -Be 30
    }

    It "turns a repository lock error into a failing Designer result" {
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
                (& $CompletionProbe ([pscustomobject]@{ launcherExited = $true; launcherExitCode = 0; processId = 7003 })) | Should -BeTrue
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
