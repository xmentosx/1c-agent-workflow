Describe "compact ITL command runner" {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        $RepoRoot = $context.RepoRoot
        $RunnerSource = Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\run-itl-command.ps1"
    }

    It "stores full output and returns a bounded successful summary" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-compact-success-" + [guid]::NewGuid().ToString("N"))
        try {
            $scriptRoot = Join-Path $tempRoot ".agents\skills\1c-workflow\scripts"
            New-Item -ItemType Directory -Force -Path $scriptRoot | Out-Null
            Copy-Item -LiteralPath $RunnerSource -Destination (Join-Path $scriptRoot "run-itl-command.ps1")
            Set-Content -LiteralPath (Join-Path $scriptRoot "agent-1c.ps1") -Encoding UTF8 -Value @'
param([string]$ProjectRoot,[string]$RunStatusPath,[string]$RunLogPath,[string]$Action)
$payload = [ordered]@{ schemaVersion=1; status='succeeded'; action=$Action; stage='complete'; stageDetail='done'; errorMessage=''; exitCode=0; lastLogPath=''; userReport="## Результат`n- Browser: включён`n- Рекомендация: выполните /reload" }
[IO.File]::WriteAllText($RunStatusPath,(($payload | ConvertTo-Json -Depth 5)+[Environment]::NewLine),(New-Object Text.UTF8Encoding $false))
Write-Output 'Проверка UTF-8 журнала'
Write-Output ('x' * 12000)
exit 0
'@
            $processResult = Invoke-TestPowerShellFile -FilePath (Join-Path $scriptRoot "run-itl-command.ps1") -Arguments @("--", "-Action", "check-dev-branch"); $processResult.exitCode | Should -Be 0; $output = $processResult.stdout
            $text = ($output -join "`n")
            $text.Length | Should -BeLessOrEqual 4000
            $summary = $text | ConvertFrom-Json
            $summary.action | Should -Be "check-dev-branch"
            $summary.status | Should -Be "succeeded"
            $summary.confirmationRequired | Should -BeFalse
            (Get-Item -LiteralPath $summary.logPath).Length | Should -BeGreaterThan 10000
            (Get-Content -LiteralPath $summary.logPath -Raw -Encoding UTF8) | Should -Match 'Проверка UTF-8 журнала'
            $status = Get-Content -LiteralPath $summary.statusPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $summary.userReport | Should -BeExactly $status.userReport
            $status.nextAction | Should -Be "none"
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "returns absolute result paths and artifacts in the successful export summary" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-compact-result-" + [guid]::NewGuid().ToString("N"))
        try {
            $scriptRoot = Join-Path $tempRoot ".agents\skills\1c-workflow\scripts"
            $resultRoot = Join-Path $tempRoot "Результаты работы"
            $resultPath = Join-Path $resultRoot "branch1.cf"
            $manifestPath = "$resultPath.manifest.json"
            New-Item -ItemType Directory -Force -Path $scriptRoot, $resultRoot | Out-Null
            Set-Content -LiteralPath $resultPath -Encoding UTF8 -Value "artifact"
            Set-Content -LiteralPath $manifestPath -Encoding UTF8 -Value "{}"
            Copy-Item -LiteralPath $RunnerSource -Destination (Join-Path $scriptRoot "run-itl-command.ps1")
            $fixture = @"
param([string]`$ProjectRoot,[string]`$RunStatusPath,[string]`$RunLogPath,[string]`$Action)
`$report = "## Результат ветки``n- Файл: $resultPath``n- Манифест: $manifestPath"
`$payload = [ordered]@{ schemaVersion=1; status='succeeded'; action=`$Action; stage='complete'; stageDetail='done'; errorMessage=''; exitCode=0; lastLogPath=''; userReport=`$report; resultPath='$resultPath'; resultManifestPath='$manifestPath' }
[IO.File]::WriteAllText(`$RunStatusPath,((`$payload | ConvertTo-Json -Depth 5)+[Environment]::NewLine),(New-Object Text.UTF8Encoding `$false))
exit 0
"@
            Set-Content -LiteralPath (Join-Path $scriptRoot "agent-1c.ps1") -Encoding UTF8 -Value $fixture

            $processResult = Invoke-TestPowerShellFile -FilePath (Join-Path $scriptRoot "run-itl-command.ps1") -Arguments @("--", "-Action", "export-dev-branch-result"); $processResult.exitCode | Should -Be 0; $output = $processResult.stdout
            $summary = ($output -join "`n") | ConvertFrom-Json
            $status = Get-Content -LiteralPath $summary.statusPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $summary.resultPath | Should -Be $status.resultPath
            $summary.resultManifestPath | Should -Be $status.resultManifestPath
            @($summary.artifacts) | Should -Contain $status.resultPath
            @($summary.artifacts) | Should -Contain $status.resultManifestPath
            $summary.userReport | Should -BeExactly $status.userReport
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "reports bounded live stage progress on stderr while keeping stdout as compact JSON" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-compact-progress-" + [guid]::NewGuid().ToString("N"))
        try {
            $scriptRoot = Join-Path $tempRoot ".agents\skills\1c-workflow\scripts"
            New-Item -ItemType Directory -Force -Path $scriptRoot | Out-Null
            Copy-Item -LiteralPath $RunnerSource -Destination (Join-Path $scriptRoot "run-itl-command.ps1")
            Set-Content -LiteralPath (Join-Path $scriptRoot "agent-1c.ps1") -Encoding UTF8 -Value @'
param([string]$ProjectRoot,[string]$RunStatusPath,[string]$RunLogPath,[string]$Action)
$now = Get-Date
$running = [ordered]@{ schemaVersion=1; status='running'; action=$Action; stage='designer.wait'; stageDetail='Waiting for owned 1C processes and infobase release.'; errorMessage=''; exitCode=$null; lastLogPath=''; liveness='stalled-suspected'; noProgressSeconds=300; timeoutRemainingSeconds=3300 }
[IO.File]::WriteAllText($RunStatusPath,(($running | ConvertTo-Json -Depth 5)+[Environment]::NewLine),(New-Object Text.UTF8Encoding $false))
Start-Sleep -Milliseconds 1200
$done = [ordered]@{ schemaVersion=1; status='succeeded'; action=$Action; stage='complete'; stageDetail='done'; errorMessage=''; exitCode=0; lastLogPath=''; userReport='done' }
[IO.File]::WriteAllText($RunStatusPath,(($done | ConvertTo-Json -Depth 5)+[Environment]::NewLine),(New-Object Text.UTF8Encoding $false))
exit 0
'@
            $processResult = Invoke-TestPowerShellFile -FilePath (Join-Path $scriptRoot "run-itl-command.ps1") -Arguments @("--", "-Action", "refresh-dev-branch"); $processResult.exitCode | Should -Be 0
            $summary = ($processResult.stdout -join "`n") | ConvertFrom-Json
            $summary.status | Should -Be "succeeded"
            $progress = $processResult.stderr -join "`n"
            $normalizedProgress = $progress -replace "\s+", ""
            $normalizedProgress | Should -Match "ITLprogress:stage=designer.wait;"
            $normalizedProgress | Should -Match "liveness=stalled-suspected"
            $normalizedProgress | Should -Match "noProgress=300s"
            $normalizedProgress | Should -Match "timeoutRemaining=3300s"
            $normalizedProgress | Should -Match "Waitingforowned1Cprocesses"
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "finalizes a running status when the helper process exits with an error" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-compact-running-exit-" + [guid]::NewGuid().ToString("N"))
        try {
            $scriptRoot = Join-Path $tempRoot ".agents\skills\1c-workflow\scripts"
            New-Item -ItemType Directory -Force -Path $scriptRoot | Out-Null
            Copy-Item -LiteralPath $RunnerSource -Destination (Join-Path $scriptRoot "run-itl-command.ps1")
            Set-Content -LiteralPath (Join-Path $scriptRoot "agent-1c.ps1") -Encoding UTF8 -Value @'
param([string]$ProjectRoot,[string]$RunStatusPath,[string]$RunLogPath,[string]$Action)
$now = Get-Date
$payload = [ordered]@{ schemaVersion=1; status='running'; action=$Action; projectRoot=$ProjectRoot; startedAt=$now.ToString('o'); updatedAt=$now.ToString('o'); finishedAt=$null; stage='reexec'; stageDetail='Starting child helper.'; errorMessage=''; exitCode=$null; lastLogPath='C:\logs\designer.log' }
[IO.File]::WriteAllText($RunStatusPath,(($payload | ConvertTo-Json -Depth 5)+[Environment]::NewLine),(New-Object Text.UTF8Encoding $false))
Write-Output 'child parameter binding failed'
exit 7
'@
            $processResult = Invoke-TestPowerShellFile -FilePath (Join-Path $scriptRoot "run-itl-command.ps1") -Arguments @("--", "-Action", "refresh-dev-branch"); $processResult.exitCode | Should -Be 7; $output = $processResult.stdout
            $text = ($output -join "`n")
            $text.Length | Should -BeLessOrEqual 4000
            $summary = $text | ConvertFrom-Json
            $summary.status | Should -Be "failed"
            $summary.stage | Should -Be "runner.helper-exited"
            $summary.errorCategory | Should -Be "runner"
            $summary.error | Should -Match "exited with code 7 before writing a terminal status"
            $summary.nextAction | Should -Match "runner failure"

            $status = Get-Content -LiteralPath $summary.statusPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $status.status | Should -Be "failed"
            [int]$status.exitCode | Should -Be 7
            $status.finishedAt | Should -Not -BeNullOrEmpty
            $status.stageDetail | Should -Match "Last recorded stage: reexec"
            $status.lastLogPath | Should -Be "C:\logs\designer.log"
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "recovers an exact lifecycle-owned Vanessa run after helper exit" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-compact-vanessa-recovery-" + [guid]::NewGuid().ToString("N"))
        try {
            $scriptRoot = Join-Path $tempRoot ".agents\skills\1c-workflow\scripts"
            New-Item -ItemType Directory -Force -Path $scriptRoot | Out-Null
            Copy-Item -LiteralPath $RunnerSource -Destination (Join-Path $scriptRoot "run-itl-command.ps1")
            Set-Content -LiteralPath (Join-Path $scriptRoot "agent-1c.ps1") -Encoding UTF8 -Value @'
param(
    [string]$ProjectRoot,[string]$RunStatusPath,[string]$RunLogPath,[string]$Action,
    [string]$InterruptedVanessaInfoBasePath,[string]$InterruptedVanessaRunParamsPath,[string]$InterruptedVanessaTestPorts
)
$utf8 = New-Object Text.UTF8Encoding $false
if ($Action -eq 'cleanup-interrupted-vanessa-run') {
    $marker = [ordered]@{ infoBasePath=$InterruptedVanessaInfoBasePath; runParamsPath=$InterruptedVanessaRunParamsPath; testPorts=$InterruptedVanessaTestPorts }
    [IO.File]::WriteAllText((Join-Path $ProjectRoot 'cleanup-marker.json'),(($marker | ConvertTo-Json)+[Environment]::NewLine),$utf8)
    exit 0
}
$operationId = [guid]::NewGuid().ToString('N')
$paramsPath = Join-Path $ProjectRoot 'build\test-results\vanessa\fixture\VAParams.json'
$lifecyclePath = Join-Path $ProjectRoot '.agent-1c\locks\lifecycle-operation.json'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $paramsPath),(Split-Path -Parent $lifecyclePath) | Out-Null
[IO.File]::WriteAllText($paramsPath,'{}',$utf8)
$evidence = [ordered]@{ schemaVersion=1; operationId=$operationId; ownerPid=$PID; processId=$PID; projectRoot=$ProjectRoot; infoBasePath=(Join-Path $ProjectRoot '.agent-1c\infobases\branch1'); runParamsPath=$paramsPath; testPorts=@(48054,48055) }
$lifecycle = [ordered]@{ schemaVersion=1; status='running'; operationId=$operationId; action=$Action; projectRoot=$ProjectRoot; worktreePath=$ProjectRoot; pid=$PID; continuationPid=0; phase='vanessa.run'; activeVanessaRun=$evidence }
$status = [ordered]@{ schemaVersion=1; status='running'; action=$Action; projectRoot=$ProjectRoot; pid=$PID; stage='vanessa.run'; activeVanessaRun=$evidence }
[IO.File]::WriteAllText($lifecyclePath,(($lifecycle | ConvertTo-Json -Depth 8)+[Environment]::NewLine),$utf8)
[IO.File]::WriteAllText($RunStatusPath,(($status | ConvertTo-Json -Depth 8)+[Environment]::NewLine),$utf8)
exit 0
'@

            Push-Location $tempRoot
            try {
                $processResult = Invoke-TestPowerShellFile -FilePath (Join-Path $scriptRoot "run-itl-command.ps1") -Arguments @("--", "-Action", "check-dev-branch")
            } finally {
                Pop-Location
            }
            $processResult.exitCode | Should -Be 1
            $summary = ($processResult.stdout -join "`n") | ConvertFrom-Json
            $summary.status | Should -Be "failed"
            $summary.stage | Should -Be "runner.helper-exited"
            $summary.error | Should -Match "Exact interrupted Vanessa run cleanup succeeded"

            $marker = Get-Content -LiteralPath (Join-Path $tempRoot "cleanup-marker.json") -Raw -Encoding UTF8 | ConvertFrom-Json
            $marker.infoBasePath | Should -Be (Join-Path $tempRoot ".agent-1c\infobases\branch1")
            $marker.runParamsPath | Should -Be (Join-Path $tempRoot "build\test-results\vanessa\fixture\VAParams.json")
            $marker.testPorts | Should -Be "48054,48055"
            $lifecycle = Get-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\locks\lifecycle-operation.json") -Raw -Encoding UTF8 | ConvertFrom-Json
            $lifecycle.status | Should -Be "failed"
            $lifecycle.phase | Should -Be "runner.helper-exited"
            $lifecycle.errorCode | Should -Be "LIFECYCLE_OPERATION_HELPER_EXITED"
            $lifecycle.finishedAt | Should -Not -BeNullOrEmpty
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "survives a real Win32 Ctrl+C in the supported entrypoint helper console" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-compact-real-ctrlc-" + [guid]::NewGuid().ToString("N"))
        $runnerProcess = $null
        try {
            $scriptRoot = Join-Path $tempRoot ".agents\skills\1c-workflow\scripts"
            $runnerPath = Join-Path $scriptRoot "run-itl-command.ps1"
            $helperPath = Join-Path $scriptRoot "agent-1c.ps1"
            $signalerPath = Join-Path $tempRoot "send-ctrlc.ps1"
            $runnerStdout = Join-Path $tempRoot "runner.stdout.log"
            $runnerStderr = Join-Path $tempRoot "runner.stderr.log"
            $signalResultPath = Join-Path $tempRoot "signal-result.json"
            New-Item -ItemType Directory -Force -Path $scriptRoot | Out-Null
            Copy-Item -LiteralPath $RunnerSource -Destination $runnerPath
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
            $summary.error | Should -Match "Exact interrupted Vanessa run cleanup succeeded"
            $terminalStatus = Get-Content -LiteralPath $statusPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $terminalStatus.status | Should -Be "failed"
            $terminalStatus.finishedAt | Should -Not -BeNullOrEmpty
            $terminalLifecycle = Get-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\locks\lifecycle-operation.json") -Raw -Encoding UTF8 | ConvertFrom-Json
            $terminalLifecycle.status | Should -Be "failed"
            $terminalLifecycle.phase | Should -Be "runner.helper-exited"
            Test-Path -LiteralPath (Join-Path $tempRoot "cleanup-marker.json") -PathType Leaf | Should -BeTrue
        } finally {
            if ($null -ne $runnerProcess -and -not $runnerProcess.HasExited) {
                Stop-Process -Id $runnerProcess.Id -Force -ErrorAction SilentlyContinue
            }
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "fails closed when the helper exits successfully without any terminal status" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-compact-no-status-" + [guid]::NewGuid().ToString("N"))
        try {
            $scriptRoot = Join-Path $tempRoot ".agents\skills\1c-workflow\scripts"
            New-Item -ItemType Directory -Force -Path $scriptRoot | Out-Null
            Copy-Item -LiteralPath $RunnerSource -Destination (Join-Path $scriptRoot "run-itl-command.ps1")
            Set-Content -LiteralPath (Join-Path $scriptRoot "agent-1c.ps1") -Encoding UTF8 -Value @'
param([string]$ProjectRoot,[string]$RunStatusPath,[string]$RunLogPath,[string]$Action)
Write-Output 'helper exited without status'
exit 0
'@
            $processResult = Invoke-TestPowerShellFile -FilePath (Join-Path $scriptRoot "run-itl-command.ps1") -Arguments @("--", "-Action", "refresh-dev-branch"); $processResult.exitCode | Should -Be 1; $output = $processResult.stdout
            $summary = ($output -join "`n") | ConvertFrom-Json
            $summary.status | Should -Be "failed"
            $summary.stage | Should -Be "runner.helper-exited"
            $summary.error | Should -Match "exited with code 0 before writing a terminal status"
            $status = Get-Content -LiteralPath $summary.statusPath -Raw -Encoding UTF8 | ConvertFrom-Json
            [int]$status.exitCode | Should -Be 1
            $status.finishedAt | Should -Not -BeNullOrEmpty
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "returns the refresh user report byte-for-byte without exposing the diagnostic log" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-compact-refresh-" + [guid]::NewGuid().ToString("N"))
        try {
            $scriptRoot = Join-Path $tempRoot ".agents\skills\1c-workflow\scripts"
            New-Item -ItemType Directory -Force -Path $scriptRoot | Out-Null
            Copy-Item -LiteralPath $RunnerSource -Destination (Join-Path $scriptRoot "run-itl-command.ps1")
            Set-Content -LiteralPath (Join-Path $scriptRoot "agent-1c.ps1") -Encoding UTF8 -Value @'
param([string]$ProjectRoot,[string]$RunStatusPath,[string]$RunLogPath,[string]$Action)
$report = "## Обновление ветки разработки`n- Результат: успешно`n- Ветка: itldev/perf1`n- Enterprise-автообновление: выполнено`n`n## MCP`n- Kilo Browser Automation: включена`n`n## Инструкции и рекомендации`n- Выполните /reload.`n- Выполните /itl-check."
$payload = [ordered]@{ schemaVersion=1; status='succeeded'; action=$Action; stage='complete'; stageDetail='done'; errorMessage=''; exitCode=0; lastLogPath=''; userReport=$report }
[IO.File]::WriteAllText($RunStatusPath,(($payload | ConvertTo-Json -Depth 5)+[Environment]::NewLine),(New-Object Text.UTF8Encoding $false))
Write-Output 'DIAGNOSTIC_SECRET_SHOULD_STAY_IN_CONSOLE_LOG'
exit 0
'@
            $processResult = Invoke-TestPowerShellFile -FilePath (Join-Path $scriptRoot "run-itl-command.ps1") -Arguments @("--", "-Action", "refresh-dev-branch"); $processResult.exitCode | Should -Be 0; $output = $processResult.stdout
            $text = ($output -join "`n")
            $text.Length | Should -BeLessOrEqual 4000
            $summary = $text | ConvertFrom-Json
            $summary.action | Should -Be "refresh-dev-branch"
            $summary.status | Should -Be "succeeded"
            $status = Get-Content -LiteralPath $summary.statusPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $summary.userReport | Should -BeExactly $status.userReport
            $text | Should -Not -Match "DIAGNOSTIC_SECRET_SHOULD_STAY_IN_CONSOLE_LOG"
            (Get-Content -LiteralPath $summary.logPath -Raw -Encoding UTF8) | Should -Match "DIAGNOSTIC_SECRET_SHOULD_STAY_IN_CONSOLE_LOG"
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "normalizes a zero helper exit and marks an unverified export as requiring confirmation" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-compact-confirm-" + [guid]::NewGuid().ToString("N"))
        try {
            $scriptRoot = Join-Path $tempRoot ".agents\skills\1c-workflow\scripts"
            New-Item -ItemType Directory -Force -Path $scriptRoot | Out-Null
            Copy-Item -LiteralPath $RunnerSource -Destination (Join-Path $scriptRoot "run-itl-command.ps1")
            Set-Content -LiteralPath (Join-Path $scriptRoot "agent-1c.ps1") -Encoding UTF8 -Value @'
param([string]$ProjectRoot,[string]$RunStatusPath,[string]$RunLogPath,[string]$Action)
$payload = [ordered]@{ schemaVersion=1; status='failed'; action=$Action; stage='verification'; stageDetail='missing'; errorMessage='Fresh verification is missing. Rerun with -AllowUnverifiedResult.'; exitCode=1; lastLogPath='' }
[IO.File]::WriteAllText($RunStatusPath,(($payload | ConvertTo-Json -Depth 5)+[Environment]::NewLine),(New-Object Text.UTF8Encoding $false))
Write-Output 'unverified export refused'
exit 0
'@
            $processResult = Invoke-TestPowerShellFile -FilePath (Join-Path $scriptRoot "run-itl-command.ps1") -Arguments @("--", "-Action", "export-dev-branch-result"); $processResult.exitCode | Should -Be 1; $output = $processResult.stdout
            $summary = ($output -join "`n") | ConvertFrom-Json
            $summary.confirmationRequired | Should -BeTrue
            $summary.nextAction | Should -Match 'explicit confirmation'
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "delegates branch creation to the existing window launcher contract" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-compact-window-" + [guid]::NewGuid().ToString("N"))
        try {
            $scriptRoot = Join-Path $tempRoot ".agents\skills\1c-workflow\scripts"
            $runRoot = Join-Path $tempRoot ".agent-1c\runs\fixture"
            New-Item -ItemType Directory -Force -Path $scriptRoot, $runRoot | Out-Null
            Copy-Item -LiteralPath $RunnerSource -Destination (Join-Path $scriptRoot "run-itl-command.ps1")
            Set-Content -LiteralPath (Join-Path $scriptRoot "run-agent-1c-window.ps1") -Encoding UTF8 -Value @"
`$payload = [ordered]@{ schemaVersion=1; status='succeeded'; action='new-dev-branch'; stage='complete'; stageDetail='done'; errorMessage=''; exitCode=0; lastLogPath=''; userReport="## Ветка разработки`n- Ветка: itldev/demo`n- Kilo Browser Automation: отключена`n- Рекомендация: откройте worktree" }
[IO.File]::WriteAllText('$($runRoot.Replace("'", "''"))\status.json',((`$payload | ConvertTo-Json -Depth 5)+[Environment]::NewLine),(New-Object Text.UTF8Encoding `$false))
[IO.File]::WriteAllText('$($runRoot.Replace("'", "''"))\console.log','full branch log',(New-Object Text.UTF8Encoding `$false))
Write-Output 'Run directory: $runRoot'
exit 0
"@
            $processResult = Invoke-TestPowerShellFile -FilePath (Join-Path $scriptRoot "run-itl-command.ps1") -Arguments @("-Windowed", "--", "-Action", "new-dev-branch", "-DevBranchName", "demo"); $processResult.exitCode | Should -Be 0; $output = $processResult.stdout
            $summary = ($output -join "`n") | ConvertFrom-Json
            $summary.action | Should -Be "new-dev-branch"
            $summary.logPath | Should -Be (Join-Path $runRoot "console.log")
            $status = Get-Content -LiteralPath (Join-Path $runRoot "status.json") -Raw -Encoding UTF8 | ConvertFrom-Json
            $summary.userReport | Should -BeExactly $status.userReport
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "returns a successful pending extension branch with a structured agent next step" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-compact-extension-pending-" + [guid]::NewGuid().ToString("N"))
        try {
            $scriptRoot = Join-Path $tempRoot ".agents\skills\1c-workflow\scripts"
            $runRoot = Join-Path $tempRoot ".agent-1c\runs\fixture"
            $worktree = Join-Path $tempRoot "worktrees\demo"
            New-Item -ItemType Directory -Force -Path $scriptRoot, $runRoot | Out-Null
            Copy-Item -LiteralPath $RunnerSource -Destination (Join-Path $scriptRoot "run-itl-command.ps1")
            Set-Content -LiteralPath (Join-Path $scriptRoot "run-agent-1c-window.ps1") -Encoding UTF8 -Value @"
`$payload = [ordered]@{ schemaVersion=1; status='succeeded'; action='new-extension-dev-branch'; stage='extension-init.pending'; stageDetail='waiting'; errorMessage=''; exitCode=0; lastLogPath=''; requiredAction='Уточните режим расширения в чате; не показывайте PowerShell.'; devBranch='itldev/demo'; worktreePath='$($worktree.Replace("'", "''"))'; extensionInitializationStatus='pending'; userReport="## Ветка разработки`n- Тип: расширение`n- Инициализация расширения: ожидает настройки`n`n## Инструкции и рекомендации`n- Уточните режим расширения в чате." }
[IO.File]::WriteAllText('$($runRoot.Replace("'", "''"))\status.json',((`$payload | ConvertTo-Json -Depth 5)+[Environment]::NewLine),(New-Object Text.UTF8Encoding `$false))
[IO.File]::WriteAllText('$($runRoot.Replace("'", "''"))\console.log','pending branch log',(New-Object Text.UTF8Encoding `$false))
Write-Output 'Run directory: $runRoot'
exit 0
"@
            $processResult = Invoke-TestPowerShellFile -FilePath (Join-Path $scriptRoot "run-itl-command.ps1") -Arguments @("-Windowed", "--", "-Action", "new-extension-dev-branch", "-DevBranchName", "demo"); $processResult.exitCode | Should -Be 0; $output = $processResult.stdout
            $summary = ($output -join "`n") | ConvertFrom-Json
            $status = Get-Content -LiteralPath (Join-Path $runRoot "status.json") -Raw -Encoding UTF8 | ConvertFrom-Json
            $summary.status | Should -Be "succeeded"
            $summary.nextAction | Should -Be $status.requiredAction
            $summary.devBranch | Should -Be "itldev/demo"
            $summary.worktreePath | Should -Be $worktree
            $summary.extensionInitializationStatus | Should -Be "pending"
            $summary.userReport | Should -BeExactly $status.userReport
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "returns a structured Vanessa test-contract failure without requiring the log tail" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-compact-test-contract-" + [guid]::NewGuid().ToString("N"))
        try {
            $scriptRoot = Join-Path $tempRoot ".agents\skills\1c-workflow\scripts"
            New-Item -ItemType Directory -Force -Path $scriptRoot | Out-Null
            Copy-Item -LiteralPath $RunnerSource -Destination (Join-Path $scriptRoot "run-itl-command.ps1")
            Set-Content -LiteralPath (Join-Path $scriptRoot "agent-1c.ps1") -Encoding UTF8 -Value @'
param([string]$ProjectRoot,[string]$RunStatusPath,[string]$RunLogPath,[string]$Action)
$payload = [ordered]@{ schemaVersion=1; status='failed'; action=$Action; stage='vanessa.failed'; stageDetail='undefined step'; errorMessage='undefined step'; exitCode=1; lastLogPath=''; errorCategory='unsupported-step'; requiredAction='/itl-verify-fix' }
[IO.File]::WriteAllText($RunStatusPath,(($payload | ConvertTo-Json -Depth 5)+[Environment]::NewLine),(New-Object Text.UTF8Encoding $false))
exit 1
'@
            $processResult = Invoke-TestPowerShellFile -FilePath (Join-Path $scriptRoot "run-itl-command.ps1") -Arguments @("--", "-Action", "check-dev-branch"); $processResult.exitCode | Should -Be 1; $output = $processResult.stdout
            $summary = ($output -join "`n") | ConvertFrom-Json
            $summary.errorCategory | Should -Be "unsupported-step"
            $summary.requiredAction | Should -Be "/itl-verify-fix"
            $summary.nextAction | Should -Be "/itl-verify-fix"
            @($summary.PSObject.Properties.Name) | Should -Not -Contain "authoringStatus"
            @($summary.PSObject.Properties.Name) | Should -Not -Contain "authoringStatePath"
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
