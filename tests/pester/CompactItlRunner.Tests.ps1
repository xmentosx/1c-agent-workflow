Describe "compact ITL command runner" {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        $RepoRoot = $context.RepoRoot
        $RunnerSource = Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\run-itl-command.ps1"
        $TimeoutPolicySource = Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\itl-runner-timeout.ps1"
        function Copy-RunnerFixture {
            param([string]$Destination)
            $scriptRoot = Split-Path -Parent $Destination
            $libRoot = Join-Path $scriptRoot "lib"
            New-Item -ItemType Directory -Force -Path $libRoot | Out-Null
            Copy-Item -LiteralPath $RunnerSource -Destination $Destination
            Copy-Item -LiteralPath $TimeoutPolicySource -Destination (Join-Path $libRoot "itl-runner-timeout.ps1")
            Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $TimeoutPolicySource) 'itl-powershell-environment.ps1') -Destination $libRoot
        }
    }

    It "removes only the PowerShell Core module root while launching the Windows PowerShell helper" {
        $runnerText = Get-Content -LiteralPath $RunnerSource -Raw -Encoding UTF8
        $runnerText | Should -Match '\$resetModulePathForWindowsPowerShell = \[string\]\$PSVersionTable\.PSEdition -eq "Core"'
        $runnerText | Should -Match '\$env:PSModulePath = Get-ItlWindowsPowerShellModulePath -ModulePath \$originalPowerShellModulePath'
        . (Join-Path (Split-Path -Parent $TimeoutPolicySource) 'itl-powershell-environment.ps1')
        $parentModulePath=$env:PSModulePath
        $coreHome=Join-Path $TestDrive 'Core runtime путь'
        $userModules=Join-Path $TestDrive 'User modules путь'
        $desktopModules=Join-Path $TestDrive 'Windows PowerShell Modules'
        $inputModulePath=@($userModules,((Join-Path $coreHome 'Modules').ToUpperInvariant()+'\'),$desktopModules) -join ';'
        Get-ItlWindowsPowerShellModulePath -ModulePath $inputModulePath -ParentEdition Core -ParentHome $coreHome |
            Should -BeExactly (@($userModules,$desktopModules) -join ';')
        Get-ItlWindowsPowerShellModulePath -ModulePath $inputModulePath -ParentEdition Desktop -ParentHome $coreHome |
            Should -BeExactly $inputModulePath
        $env:PSModulePath | Should -BeExactly $parentModulePath
        $runnerText | Should -Match 'function Start-CompactHelperProcess'
        $runnerText | Should -Match 'CreateJobObject'
        $runnerText | Should -Match 'JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE'
        $runnerText | Should -Match 'PROC_THREAD_ATTRIBUTE_JOB_LIST'
        $runnerText | Should -Match 'CREATE_NEW_PROCESS_GROUP'
        $runnerText | Should -Match 'SetConsoleCtrlHandler'
        $runnerText | Should -Not -Match 'AssignProcessToJobObject'
        (Get-Content -LiteralPath $TimeoutPolicySource -Raw -Encoding UTF8) | Should -Match 'ITL_RUNNER_OPERATION_TIMEOUT_SECONDS'
        $runnerText | Should -Match 'finally \{[\s\S]*?\$env:PSModulePath = \$originalPowerShellModulePath'
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($RunnerSource, [ref]$tokens, [ref]$errors) | Out-Null
        @($errors).Count | Should -Be 0
    }

    It "kills the helper process tree when the compact runner is aborted" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl compact job abort путь " + [guid]::NewGuid().ToString("N"))
        $runnerProcess = $null
        $helperPid = 0
        $childPid = 0
        try {
            $scriptRoot = Join-Path $tempRoot ".agents\skills\1c-workflow\scripts"
            New-Item -ItemType Directory -Force -Path $scriptRoot | Out-Null
            Copy-RunnerFixture -Destination (Join-Path $scriptRoot "run-itl-command.ps1")
            Set-Content -LiteralPath (Join-Path $scriptRoot "agent-1c.ps1") -Encoding UTF8 -Value @'
param([string]$ProjectRoot,[string]$RunStatusPath,[string]$RunLogPath,[string]$Action)
$utf8 = New-Object Text.UTF8Encoding $false
$child = Start-Process -FilePath "powershell" -ArgumentList @("-NoProfile", "-Command", "Start-Sleep -Seconds 120") -WindowStyle Hidden -PassThru
[IO.File]::WriteAllText((Join-Path $ProjectRoot "child-pid.txt"), ([string]$child.Id + [Environment]::NewLine), $utf8)
$now = Get-Date
$payload = [ordered]@{ schemaVersion=1; status='running'; action=$Action; projectRoot=$ProjectRoot; pid=$PID; startedAt=$now.ToString('o'); updatedAt=$now.ToString('o'); stage='start'; stageDetail='owned child running'; liveness=''; noProgressSeconds=0; stallTimeoutRemainingSeconds=0; timeoutRemainingSeconds=0; exitCode=$null; errorMessage='' }
[IO.File]::WriteAllText($RunStatusPath,(($payload | ConvertTo-Json -Depth 5)+[Environment]::NewLine),$utf8)
while ($true) { Start-Sleep -Seconds 1 }
'@
            $runnerStdout = Join-Path $tempRoot "runner.stdout.log"
            $runnerStderr = Join-Path $tempRoot "runner.stderr.log"
            $runnerPath = Join-Path $scriptRoot "run-itl-command.ps1"
            $quoteArgument = {
                param([string]$Value)
                if ($Value -match '[\s"]') { return '"' + ($Value -replace '"', '\"') + '"' }
                return $Value
            }
            $runnerProcess = Start-Process -FilePath "powershell" `
                -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (& $quoteArgument $runnerPath), "--", "-Action", "refresh-dev-branch-lite") `
                -WorkingDirectory $tempRoot `
                -RedirectStandardOutput $runnerStdout `
                -RedirectStandardError $runnerStderr `
                -WindowStyle Hidden `
                -PassThru
            $deadline = (Get-Date).AddSeconds(20)
            $statusPath = ""
            while ((Get-Date) -lt $deadline) {
                $statusFile = @(Get-ChildItem -LiteralPath (Join-Path $tempRoot ".agent-1c\runs") -Filter status.json -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1)
                $childPidPath = Join-Path $tempRoot "child-pid.txt"
                if ($statusFile.Count -eq 1 -and (Test-Path -LiteralPath $childPidPath -PathType Leaf)) {
                    try { $status = Get-Content -LiteralPath $statusFile[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $status = $null }
                    if ($null -ne $status -and [int]$status.pid -gt 0) {
                        $statusPath = $statusFile[0].FullName
                        $helperPid = [int]$status.pid
                        $childPid = [int]((Get-Content -LiteralPath $childPidPath -Encoding UTF8 | Select-Object -First 1))
                        break
                    }
                }
                Start-Sleep -Milliseconds 100
            }
            $helperPid | Should -BeGreaterThan 0
            $childPid | Should -BeGreaterThan 0
            @(Get-Process -Id $helperPid -ErrorAction SilentlyContinue).Count | Should -Be 1
            @(Get-Process -Id $childPid -ErrorAction SilentlyContinue).Count | Should -Be 1

            Stop-Process -Id $runnerProcess.Id -Force
            $runnerProcess.WaitForExit(10000) | Out-Null
            $goneDeadline = (Get-Date).AddSeconds(10)
            while ((Get-Date) -lt $goneDeadline) {
                $helperAlive = @(Get-Process -Id $helperPid -ErrorAction SilentlyContinue).Count
                $childAlive = @(Get-Process -Id $childPid -ErrorAction SilentlyContinue).Count
                if ($helperAlive -eq 0 -and $childAlive -eq 0) { break }
                Start-Sleep -Milliseconds 100
            }
            @(Get-Process -Id $helperPid -ErrorAction SilentlyContinue).Count | Should -Be 0
            @(Get-Process -Id $childPid -ErrorAction SilentlyContinue).Count | Should -Be 0
        } finally {
            if ($null -ne $runnerProcess -and -not $runnerProcess.HasExited) {
                Stop-Process -Id $runnerProcess.Id -Force -ErrorAction SilentlyContinue
            }
            if ($helperPid -gt 0) { Stop-Process -Id $helperPid -Force -ErrorAction SilentlyContinue }
            if ($childPid -gt 0) { Stop-Process -Id $childPid -Force -ErrorAction SilentlyContinue }
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "survives a real Win32 Ctrl+C in the supported entrypoint helper console" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-compact-real-ctrlc-" + [guid]::NewGuid().ToString("N"))
        $runnerProcess = $null
        $neighborProcess = $null
        $neighborHelperPid = 0
        try {
            $scriptRoot = Join-Path $tempRoot ".agents\skills\1c-workflow\scripts"
            $runnerPath = Join-Path $scriptRoot "run-itl-command.ps1"
            $helperPath = Join-Path $scriptRoot "agent-1c.ps1"
            $signalerPath = Join-Path $tempRoot "send-ctrlc.ps1"
            $runnerStdout = Join-Path $tempRoot "runner.stdout.log"
            $runnerStderr = Join-Path $tempRoot "runner.stderr.log"
            $signalResultPath = Join-Path $tempRoot "signal-result.json"
            New-Item -ItemType Directory -Force -Path $scriptRoot | Out-Null
            Copy-RunnerFixture -Destination $runnerPath
            Set-Content -LiteralPath $helperPath -Encoding UTF8 -Value @'
param(
    [string]$ProjectRoot,[string]$RunStatusPath,[string]$RunLogPath,[string]$Action,
    [string]$InterruptedVanessaInfoBasePath,[string]$InterruptedVanessaRunParamsPath,[string]$InterruptedVanessaTestPorts
)
$utf8 = New-Object Text.UTF8Encoding $false
if ($Action -eq 'cleanup-interrupted-vanessa-run') {
    $marker = [ordered]@{ infoBasePath=$InterruptedVanessaInfoBasePath; runParamsPath=$InterruptedVanessaRunParamsPath; testPorts=$InterruptedVanessaTestPorts; cleanupPid=$PID }
    [IO.File]::WriteAllText((Join-Path $ProjectRoot 'cleanup-marker.json'),(($marker | ConvertTo-Json)+[Environment]::NewLine),$utf8)
    exit 0
}
$operationId = [guid]::NewGuid().ToString('N')
$paramsPath = Join-Path $ProjectRoot 'build\test-results\vanessa\ctrlc\VAParams.json'
$lifecyclePath = Join-Path $ProjectRoot '.agent-1c\locks\lifecycle-operation.json'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $paramsPath),(Split-Path -Parent $lifecyclePath) | Out-Null
[IO.File]::WriteAllText($paramsPath,'{}',$utf8)
$evidence = [ordered]@{ schemaVersion=1; operationId=$operationId; ownerPid=$PID; processId=$PID; projectRoot=$ProjectRoot; infoBasePath=(Join-Path $ProjectRoot '.agent-1c\infobases\branch1'); runParamsPath=$paramsPath; testPorts=@(48054,48055) }
$lifecycle = [ordered]@{ schemaVersion=1; status='running'; operationId=$operationId; action=$Action; projectRoot=$ProjectRoot; worktreePath=$ProjectRoot; pid=$PID; continuationPid=0; phase='vanessa.run'; activeVanessaRun=$evidence }
$status = [ordered]@{ schemaVersion=1; status='running'; action=$Action; projectRoot=$ProjectRoot; pid=$PID; stage='vanessa.run'; activeVanessaRun=$evidence }
[IO.File]::WriteAllText($lifecyclePath,(($lifecycle | ConvertTo-Json -Depth 8)+[Environment]::NewLine),$utf8)
[IO.File]::WriteAllText($RunStatusPath,(($status | ConvertTo-Json -Depth 8)+[Environment]::NewLine),$utf8)
while ($true) { Start-Sleep -Seconds 1 }
'@
            Set-Content -LiteralPath $signalerPath -Encoding UTF8 -Value @'
param([int]$HelperPid,[string]$ResultPath)
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class ItlCtrlC {
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool FreeConsole();
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool AttachConsole(uint processId);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool SetConsoleCtrlHandler(IntPtr handler, bool add);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool GenerateConsoleCtrlEvent(uint ctrlEvent, uint processGroupId);
}
"@
[ItlCtrlC]::FreeConsole() | Out-Null
$attached = [ItlCtrlC]::AttachConsole([uint32]$HelperPid)
$ignored = $false
$signaled = $false
if ($attached) {
    $ignored = [ItlCtrlC]::SetConsoleCtrlHandler([IntPtr]::Zero, $true)
    # CTRL_C_EVENT cannot be scoped to a nonzero process-group id. After attaching
    # to the helper's dedicated console, group 0 targets the processes on that console.
    $signaled = [ItlCtrlC]::GenerateConsoleCtrlEvent(0, 0)
    Start-Sleep -Milliseconds 500
}
[ItlCtrlC]::FreeConsole() | Out-Null
$result = [ordered]@{ attached=$attached; ignored=$ignored; signaled=$signaled }
[IO.File]::WriteAllText($ResultPath,(($result | ConvertTo-Json)+[Environment]::NewLine),(New-Object Text.UTF8Encoding $false))
if (-not $attached -or -not $signaled) { exit 1 }
exit 0
'@

            $runnerProcess = Start-Process -FilePath "powershell" `
                -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $runnerPath, "--", "-Action", "check-dev-branch") `
                -WorkingDirectory $tempRoot `
                -RedirectStandardOutput $runnerStdout `
                -RedirectStandardError $runnerStderr `
                -WindowStyle Hidden `
                -PassThru
            $statusPath = ""
            $status = $null
            $stageDeadline = (Get-Date).AddSeconds(20)
            while ((Get-Date) -lt $stageDeadline) {
                $statusFile = @(Get-ChildItem -LiteralPath (Join-Path $tempRoot ".agent-1c\runs") -Filter status.json -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1)
                if ($statusFile.Count -eq 1) {
                    try { $status = Get-Content -LiteralPath $statusFile[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $status = $null }
                    if ($null -ne $status -and [string]$status.stage -eq "vanessa.run") {
                        $statusPath = $statusFile[0].FullName
                        break
                    }
                }
                Start-Sleep -Milliseconds 100
            }
            $statusPath | Should -Not -BeNullOrEmpty
            $helperPid = [int]$status.pid
            $helperPid | Should -BeGreaterThan 0

            $neighborRoot = Join-Path $tempRoot 'neighbor'
            $neighborScriptRoot = Join-Path $neighborRoot '.agents/skills/1c-workflow/scripts'
            New-Item -ItemType Directory -Force -Path $neighborScriptRoot | Out-Null
            $neighborRunner = Join-Path $neighborScriptRoot 'run-itl-command.ps1'
            Copy-RunnerFixture -Destination $neighborRunner
            Copy-Item -LiteralPath $helperPath -Destination (Join-Path $neighborScriptRoot 'agent-1c.ps1')
            $neighborProcess = Start-Process -FilePath 'powershell' `
                -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$neighborRunner,'--','-Action','check-dev-branch') `
                -WorkingDirectory $neighborRoot -WindowStyle Hidden `
                -RedirectStandardOutput (Join-Path $neighborRoot 'stdout.log') `
                -RedirectStandardError (Join-Path $neighborRoot 'stderr.log') -PassThru
            $neighborStatusPath = ''
            $neighborDeadline = (Get-Date).AddSeconds(20)
            while ((Get-Date) -lt $neighborDeadline) {
                $neighborStatusFile = @(Get-ChildItem -LiteralPath (Join-Path $neighborRoot '.agent-1c/runs') -Filter status.json -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1)
                if ($neighborStatusFile.Count -eq 1) {
                    try { $neighborStatus = Get-Content -LiteralPath $neighborStatusFile[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $neighborStatus = $null }
                    if ($neighborStatus -and $neighborStatus.stage -eq 'vanessa.run') {
                        $neighborStatusPath = $neighborStatusFile[0].FullName
                        $neighborHelperPid = [int]$neighborStatus.pid
                        break
                    }
                }
                Start-Sleep -Milliseconds 100
            }
            $neighborStatusPath | Should -Not -BeNullOrEmpty
            $neighborHelperPid | Should -BeGreaterThan 0

            $signaler = Start-Process -FilePath "powershell" `
                -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $signalerPath, "-HelperPid", $helperPid, "-ResultPath", $signalResultPath) `
                -WindowStyle Hidden `
                -Wait `
                -PassThru
            $signaler.ExitCode | Should -Be 0
            $signal = Get-Content -LiteralPath $signalResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $signal.attached | Should -BeTrue
            $signal.signaled | Should -BeTrue

            $runnerDeadline = (Get-Date).AddSeconds(20)
            while (-not $runnerProcess.HasExited -and (Get-Date) -lt $runnerDeadline) { Start-Sleep -Milliseconds 100 }
            $runnerProcess.HasExited | Should -BeTrue
            $runnerProcess.WaitForExit()
            $summary = (Get-Content -LiteralPath $runnerStdout -Raw -Encoding UTF8).Trim() | ConvertFrom-Json
            $summary.status | Should -Be "failed"
            $summary.stage | Should -Be "runner.helper-exited"
            $summary.error | Should -Match "Exact interrupted Vanessa process cleanup succeeded"
            $terminalStatus = Get-Content -LiteralPath $statusPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $terminalStatus.status | Should -Be "failed"
            $terminalStatus.finishedAt | Should -Not -BeNullOrEmpty
            $terminalLifecycle = Get-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\locks\lifecycle-operation.json") -Raw -Encoding UTF8 | ConvertFrom-Json
            $terminalLifecycle.status | Should -Be "failed"
            $terminalLifecycle.phase | Should -Be "runner.helper-exited"
            Test-Path -LiteralPath (Join-Path $tempRoot "cleanup-marker.json") -PathType Leaf | Should -BeTrue
            $neighborProcess.Refresh()
            $neighborProcess.HasExited | Should -BeFalse
            Get-Process -Id $neighborHelperPid -ErrorAction Stop | Should -Not -BeNullOrEmpty
            $neighborStatus = Get-Content -LiteralPath $neighborStatusPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $neighborStatus.status | Should -Be 'running'
            $neighborLifecycle = Get-Content -LiteralPath (Join-Path $neighborRoot '.agent-1c/locks/lifecycle-operation.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            $neighborLifecycle.status | Should -Be 'running'
            Test-Path -LiteralPath (Join-Path $neighborRoot 'cleanup-marker.json') | Should -BeFalse
        } finally {
            if ($neighborHelperPid -gt 0) { Stop-Process -Id $neighborHelperPid -Force -ErrorAction SilentlyContinue }
            if ($neighborProcess) {
                if (-not $neighborProcess.WaitForExit(15000)) { $neighborProcess.Kill(); $neighborProcess.WaitForExit() }
                $neighborProcess.Dispose()
            }
            if ($null -ne $runnerProcess -and -not $runnerProcess.HasExited) {
                Stop-Process -Id $runnerProcess.Id -Force -ErrorAction SilentlyContinue
            }
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
