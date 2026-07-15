Describe "1C Designer memory guard" {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        $RepoRoot = $context.RepoRoot
        $HelperPath = $context.HelperPath
        $CorePath = Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.core.ps1"
        $LifecyclePath = Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.lifecycle.ps1"
        $PowerShellPath = (Get-Process -Id $PID).Path
    }

    It "resolves default project worktree and disabled limits with strict validation" {
        $result = & {
            $savedDirect = $env:DESIGNER_MAX_WORKING_SET_MB
            $savedPrefixed = $env:AGENT_1C_DESIGNER_MAX_WORKING_SET_MB
            try {
                $env:DESIGNER_MAX_WORKING_SET_MB = $null
                $env:AGENT_1C_DESIGNER_MAX_WORKING_SET_MB = $null
                . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null

                $script:Config = [pscustomobject]@{}
                $defaultValue = Get-DesignerMaxWorkingSetMb

                $script:Config = [pscustomobject]@{ designerMaxWorkingSetMb = 6144 }
                $projectValue = Get-DesignerMaxWorkingSetMb

                $env:DESIGNER_MAX_WORKING_SET_MB = "4096"
                $worktreeValue = Get-DesignerMaxWorkingSetMb

                $env:DESIGNER_MAX_WORKING_SET_MB = "0"
                $disabledValue = Get-DesignerMaxWorkingSetMb
                $disabledStatus = (& { Write-DesignerMemoryLimitStatusLine } 6>&1 | Out-String).Trim()

                $invalidMessages = @()
                foreach ($invalidValue in @("-1", "1.5", "not-a-number")) {
                    $env:DESIGNER_MAX_WORKING_SET_MB = $invalidValue
                    try {
                        Get-DesignerMaxWorkingSetMb | Out-Null
                    } catch {
                        $invalidMessages += $_.Exception.Message
                    }
                }

                [pscustomobject]@{
                    defaultValue = $defaultValue
                    projectValue = $projectValue
                    worktreeValue = $worktreeValue
                    disabledValue = $disabledValue
                    disabledStatus = $disabledStatus
                    invalidMessages = @($invalidMessages)
                }
            } finally {
                $env:DESIGNER_MAX_WORKING_SET_MB = $savedDirect
                $env:AGENT_1C_DESIGNER_MAX_WORKING_SET_MB = $savedPrefixed
            }
        }

        $result.defaultValue | Should -Be 10240
        $result.projectValue | Should -Be 6144
        $result.worktreeValue | Should -Be 4096
        $result.disabledValue | Should -Be 0
        $result.disabledStatus | Should -Match "Designer memory limit: disabled"
        $result.invalidMessages.Count | Should -Be 3
        $result.invalidMessages | ForEach-Object { $_ | Should -Match "must be an integer between 0 and 1048576" }
    }

    It "kills a growing child process quickly and reports its peak and limit" {
        $childPath = Join-Path $TestDrive "grow-memory.ps1"
        @'
$chunks = New-Object System.Collections.Generic.List[byte[]]
while ($true) {
    $chunk = New-Object byte[] (8MB)
    for ($index = 0; $index -lt $chunk.Length; $index += 4096) { $chunk[$index] = 1 }
    $chunks.Add($chunk)
    Start-Sleep -Milliseconds 20
}
'@ | Set-Content -LiteralPath $childPath -Encoding UTF8

        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $watch = [System.Diagnostics.Stopwatch]::StartNew()
            $processResult = Invoke-NativeProcessAndWaitResult `
                -FilePath $PowerShellPath `
                -Arguments @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $childPath) `
                -MaxWorkingSetMb 128
            $watch.Stop()
            [pscustomobject]@{ processResult = $processResult; elapsedSeconds = $watch.Elapsed.TotalSeconds }
        }

        $result.processResult.exitCode | Should -Be -2
        $result.processResult.memoryLimitExceeded | Should -BeTrue
        $result.processResult.memoryMonitorFailed | Should -BeFalse
        $result.processResult.peakWorkingSetMb | Should -BeGreaterThan 128
        $result.processResult.workingSetLimitMb | Should -Be 128
        $result.processResult.terminationConfirmed | Should -BeTrue
        $result.elapsedSeconds | Should -BeLessThan 10
        Start-Sleep -Milliseconds 100
        Get-Process -Id $result.processResult.processId -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }

    It "keeps successful and disabled low-memory process paths unchanged" {
        $childPath = Join-Path $TestDrive "small-process.ps1"
        'Start-Sleep -Milliseconds 100; exit 0' | Set-Content -LiteralPath $childPath -Encoding UTF8

        $results = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $guarded = Invoke-NativeProcessAndWaitResult `
                -FilePath $PowerShellPath `
                -Arguments @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $childPath) `
                -MaxWorkingSetMb 512
            $disabled = Invoke-NativeProcessAndWaitResult `
                -FilePath $PowerShellPath `
                -Arguments @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $childPath) `
                -MaxWorkingSetMb 0
            [pscustomobject]@{ guarded = $guarded; disabled = $disabled }
        }

        $results.guarded.exitCode | Should -Be 0
        $results.guarded.memoryLimitExceeded | Should -BeFalse
        $results.guarded.peakWorkingSetMb | Should -BeGreaterThan 0
        $results.disabled.exitCode | Should -Be 0
        $results.disabled.memoryLimitExceeded | Should -BeFalse
        $results.disabled.workingSetLimitMb | Should -Be 0
        $results.disabled.peakWorkingSetMb | Should -Be 0
    }

    It "fails closed when a live process working set cannot be sampled" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $fakeProcess = [pscustomobject]@{ Id = 424242; HasExited = $false; ExitCode = 0 }
            $fakeProcess | Add-Member -MemberType ScriptMethod -Name Refresh -Value { throw "working set unavailable" }
            function Start-Process {
                param($FilePath, $ArgumentList, $WorkingDirectory, $WindowStyle, [switch]$PassThru)
                return $fakeProcess
            }
            $script:SafetyStopCalls = 0
            function Stop-NativeProcessForSafety {
                param([object]$Process)
                $script:SafetyStopCalls++
                return [pscustomobject]@{ confirmed = $true; error = "" }
            }

            $processResult = Invoke-NativeProcessAndWaitResult -FilePath "fake.exe" -Arguments @() -MaxWorkingSetMb 64
            [pscustomobject]@{ processResult = $processResult; safetyStopCalls = $script:SafetyStopCalls }
        }

        $result.safetyStopCalls | Should -Be 1
        $result.processResult.exitCode | Should -Be -3
        $result.processResult.memoryMonitorFailed | Should -BeTrue
        $result.processResult.memoryMonitorError | Should -Match "working set unavailable"
        $result.processResult.terminationConfirmed | Should -BeTrue
    }

    It "passes the effective limit only to automated Designer and emits stable errors" {
        $fixtureRoot = Join-Path $TestDrive "designer-call"
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
                designerMaxWorkingSetMb = 321
            }
            $script:CapturedLimit = -1
            $script:FakeFailure = "limit"
            function Invoke-NativeProcessAndWaitResult {
                param(
                    [string]$FilePath,
                    [string[]]$Arguments,
                    [int]$TimeoutSeconds = 0,
                    [scriptblock]$OnTimeout = $null,
                    [scriptblock]$CompletionProbe = $null,
                    [int]$CompletionGraceSeconds = 10,
                    [int]$MaxWorkingSetMb = 0
                )
                $script:CapturedLimit = $MaxWorkingSetMb
                $script:LastNativeProcessStarted = $true
                $script:LastProcessId = 9876
                $isMonitorFailure = ($script:FakeFailure -eq "monitor")
                $script:LastProcessMemoryLimitExceeded = -not $isMonitorFailure
                $script:LastProcessPeakWorkingSetMb = 322
                $script:LastProcessWorkingSetLimitMb = $MaxWorkingSetMb
                return [pscustomobject]@{
                    processId = 9876
                    exitCode = $(if ($isMonitorFailure) { -3 } else { -2 })
                    timedOut = $false
                    memoryLimitExceeded = (-not $isMonitorFailure)
                    memoryMonitorFailed = $isMonitorFailure
                    memoryMonitorError = $(if ($isMonitorFailure) { "working set unavailable" } else { "" })
                    peakWorkingSetMb = 322
                    workingSetLimitMb = $MaxWorkingSetMb
                    terminationConfirmed = $true
                    terminationError = ""
                    completedByProbe = $false
                }
            }

            $limitMessage = ""
            try {
                Invoke-Designer -InfoBasePath $basePath -InfoBaseKind file -DesignerArgs @("/UpdateDBCfg") 6>$null | Out-Null
            } catch {
                $limitMessage = $_.Exception.Message
            }
            $script:FakeFailure = "monitor"
            $monitorMessage = ""
            try {
                Invoke-Designer -InfoBasePath $basePath -InfoBaseKind file -DesignerArgs @("/UpdateDBCfg") 6>$null | Out-Null
            } catch {
                $monitorMessage = $_.Exception.Message
            }
            [pscustomobject]@{
                capturedLimit = $script:CapturedLimit
                limitMessage = $limitMessage
                monitorMessage = $monitorMessage
            }
        }

        $result.capturedLimit | Should -Be 321
        $result.limitMessage | Should -Match '^DESIGNER_MEMORY_LIMIT_EXCEEDED\b'
        $result.limitMessage | Should -Match 'pid=9876 limitMb=321 peakWorkingSetMb=322'
        $result.limitMessage | Should -Match 'log='
        $result.monitorMessage | Should -Match '^DESIGNER_MEMORY_MONITOR_FAILED\b'
        $result.monitorMessage | Should -Match "detail='working set unavailable'"

        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($CorePath, [ref]$tokens, [ref]$errors)
        $functions = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
        ($functions | Where-Object Name -eq "Invoke-Designer").Extent.Text | Should -Match 'MaxWorkingSetMb'
        ($functions | Where-Object Name -eq "Invoke-DesignerInteractive").Extent.Text | Should -Not -Match 'MaxWorkingSetMb'
        ($functions | Where-Object Name -eq "Invoke-Enterprise").Extent.Text | Should -Not -Match 'MaxWorkingSetMb'
    }

    It "writes the last Designer memory diagnostics to run status" {
        $statusPath = Join-Path $TestDrive "run-status.json"
        $status = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $RunStatusPath = $statusPath
            $RunLogPath = ""
            $script:LastLogPath = "C:\logs\designer.log"
            $script:LastProcessId = 1234
            $script:LastProcessTimedOut = $false
            $script:LastProcessMemoryLimitExceeded = $true
            $script:LastProcessPeakWorkingSetMb = 10241
            $script:LastProcessWorkingSetLimitMb = 10240
            Write-RunStatus -Status failed -ExitCode 1 -ErrorMessage "DESIGNER_MEMORY_LIMIT_EXCEEDED"
            Get-Content -Raw -Encoding UTF8 $statusPath | ConvertFrom-Json
        }

        $status.lastProcessId | Should -Be 1234
        $status.lastProcessMemoryLimitExceeded | Should -BeTrue
        $status.lastProcessPeakWorkingSetMb | Should -Be 10241
        $status.lastProcessWorkingSetLimitMb | Should -Be 10240
        $status.lastLogPath | Should -Be "C:\logs\designer.log"
    }

    It "does not run full fallback after either memory guard failure" {
        foreach ($errorCode in @("DESIGNER_MEMORY_LIMIT_EXCEEDED", "DESIGNER_MEMORY_MONITOR_FAILED")) {
            foreach ($extensionName in @("", "TestExtension")) {
                $result = & {
                    . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
                    $script:DesignerCalls = 0
                    $script:StateUpdates = @{}
                    $script:CapturedStage = ""
                    function Invoke-Designer {
                        $script:DesignerCalls++
                        $script:LastNativeProcessStarted = $true
                        $script:LastLogPath = "C:\logs\partial.log"
                        $script:LastProcessMemoryLimitExceeded = ($errorCode -eq "DESIGNER_MEMORY_LIMIT_EXCEEDED")
                        $script:LastProcessPeakWorkingSetMb = 10241
                        $script:LastProcessWorkingSetLimitMb = 10240
                        throw "$errorCode pid=123 limitMb=10240 peakWorkingSetMb=10241 log=C:\logs\partial.log"
                    }
                    function Update-DevBranchState {
                        param([object]$State, [hashtable]$Updates)
                        $script:StateUpdates = $Updates
                    }
                    function Set-RunStage {
                        param([string]$Stage, [string]$Detail)
                        $script:CapturedStage = $Stage
                    }

                    $message = ""
                    try {
                        Invoke-ConfigLoadWithFallback `
                            -InfoBasePath "C:\base" `
                            -InfoBaseKind file `
                            -State ([pscustomobject]@{}) `
                            -AbsoluteExportPath "C:\src" `
                            -ListFilePath "C:\list.txt" `
                            -FileCount 1 `
                            -ExtensionName $extensionName `
                            -Mode Auto 3>$null 6>$null | Out-Null
                    } catch {
                        $message = $_.Exception.Message
                    }
                    [pscustomobject]@{
                        calls = $script:DesignerCalls
                        updates = $script:StateUpdates
                        stage = $script:CapturedStage
                        message = $message
                    }
                }

                $result.calls | Should -Be 1
                $expectedStatus = if ($errorCode -eq "DESIGNER_MEMORY_LIMIT_EXCEEDED") { "memory-limit-exceeded" } else { "memory-monitor-failed" }
                $result.updates.configLoadStatus | Should -Be $expectedStatus
                $result.updates.lastConfigLoadMode | Should -Be "partial"
                $result.updates.lastConfigFullFallbackLogPath | Should -Be ""
                $result.updates.ContainsKey("lastConfigBaseUpdatedCommit") | Should -BeFalse
                $result.updates.lastDesignerPeakWorkingSetMb | Should -Be 10241
                $result.stage | Should -Be "config-load.$expectedStatus"
                $result.message | Should -Match "^$errorCode\b"
            }
        }
    }

    It "preserves the existing full fallback for ordinary Designer failures" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $script:DesignerCalls = 0
            function Invoke-Designer {
                $script:DesignerCalls++
                $script:LastNativeProcessStarted = $true
                $script:LastLogPath = if ($script:DesignerCalls -eq 1) { "C:\logs\partial.log" } else { "C:\logs\full.log" }
                if ($script:DesignerCalls -eq 1) { throw "ordinary Designer failure" }
            }

            $load = Invoke-ConfigLoadWithFallback `
                -InfoBasePath "C:\base" `
                -InfoBaseKind file `
                -State ([pscustomobject]@{}) `
                -AbsoluteExportPath "C:\src" `
                -ListFilePath "C:\list.txt" `
                -FileCount 1 `
                -Mode Auto 3>$null 6>$null
            [pscustomobject]@{ calls = $script:DesignerCalls; load = $load }
        }

        $result.calls | Should -Be 2
        $result.load.loadModeUsed | Should -Be "full-fallback"
        $result.load.configLoadStatus | Should -Be "fallback-succeeded"
    }

    It "keeps the package defaults and Fast inventory discoverable" {
        $projectTemplate = Get-Content -Raw -Encoding UTF8 (Join-Path $RepoRoot "templates\project.json") | ConvertFrom-Json
        $envTemplate = Get-Content -Raw -Encoding UTF8 (Join-Path $RepoRoot "templates\dev.env.example")
        $checkText = Get-Content -Raw -Encoding UTF8 (Join-Path $RepoRoot "scripts\check.ps1")
        $coreText = Get-Content -Raw -Encoding UTF8 $CorePath
        $lifecycleText = Get-Content -Raw -Encoding UTF8 $LifecyclePath

        $projectTemplate.designerMaxWorkingSetMb | Should -Be 10240
        $envTemplate | Should -Match "DESIGNER_MAX_WORKING_SET_MB"
        $checkText | Should -Match ([regex]::Escape(".\tests\pester\DesignerMemoryGuard.Tests.ps1"))
        $coreText | Should -Match "DESIGNER_MEMORY_MONITOR_FAILED"
        $lifecycleText | Should -Match "memory-limit-exceeded"
    }
}
