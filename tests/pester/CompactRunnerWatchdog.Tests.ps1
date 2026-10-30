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

    It "fails a synchronously stale Designer status within the runner watchdog" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-compact-stale-status-" + [guid]::NewGuid().ToString("N"))
        $previousWarning = [Environment]::GetEnvironmentVariable("ITL_RUNNER_STATUS_STALE_WARNING_SECONDS", "Process")
        $previousTimeout = [Environment]::GetEnvironmentVariable("ITL_RUNNER_STATUS_STALE_TIMEOUT_SECONDS", "Process")
        $fixturePid = 0
        try {
            $scriptRoot = Join-Path $tempRoot ".agents\skills\1c-workflow\scripts"
            New-Item -ItemType Directory -Force -Path $scriptRoot | Out-Null
            Copy-RunnerFixture -Destination (Join-Path $scriptRoot "run-itl-command.ps1")
            Set-Content -LiteralPath (Join-Path $scriptRoot "agent-1c.ps1") -Encoding UTF8 -Value @'
param([string]$ProjectRoot,[string]$RunStatusPath,[string]$RunLogPath,[string]$Action)
$now = Get-Date
$payload = [ordered]@{ schemaVersion=1; status='running'; action=$Action; projectRoot=$ProjectRoot; pid=$PID; startedAt=$now.ToString('o'); updatedAt=$now.ToString('o'); stage='designer-wait'; stageDetail='completion probe entered'; liveness='running-waiting-release'; noProgressSeconds=4; stallTimeoutRemainingSeconds=0; timeoutRemainingSeconds=3596; exitCode=$null; errorMessage='' }
[IO.File]::WriteAllText($RunStatusPath,(($payload | ConvertTo-Json -Depth 5)+[Environment]::NewLine),(New-Object Text.UTF8Encoding $false))
Start-Sleep -Seconds 30
exit 0
'@
            [Environment]::SetEnvironmentVariable("ITL_RUNNER_STATUS_STALE_WARNING_SECONDS", "1", "Process")
            [Environment]::SetEnvironmentVariable("ITL_RUNNER_STATUS_STALE_TIMEOUT_SECONDS", "2", "Process")
            $stopwatch = [Diagnostics.Stopwatch]::StartNew()
            $processResult = Invoke-TestPowerShellFile -FilePath (Join-Path $scriptRoot "run-itl-command.ps1") -Arguments @("--", "-Action", "refresh-dev-branch")
            $stopwatch.Stop()

            $processResult.exitCode | Should -Not -Be 0
            $stopwatch.Elapsed.TotalSeconds | Should -BeLessThan 15
            $summary = ($processResult.stdout -join "`n") | ConvertFrom-Json
            $summary.status | Should -Be "failed"
            $summary.stage | Should -Be "runner.status-stale"
            $summary.liveness | Should -Be "failed-stale-status"
            $summary.error | Should -Match '^RUNNER_STATUS_STALE\b'
            $summary.noProgressSeconds | Should -BeGreaterThan 4
            $summary.timeoutRemainingSeconds | Should -Be 0
            $progress = $processResult.stderr -join "`n"
            $progress | Should -Match 'liveness=stale-status'
            $progress | Should -Match 'statusAge=[1-9][0-9]*s'
            ([regex]::Matches($progress, 'liveness=running-waiting-release')).Count | Should -BeLessOrEqual 1

            $status = Get-Content -LiteralPath $summary.statusPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $fixturePid = [int]$status.pid
            $status.errorCode | Should -Be "LIFECYCLE_OPERATION_STATUS_STALE"
            $status.stallTimeoutRemainingSeconds | Should -Be 0
            @(Get-Process -Id $fixturePid -ErrorAction SilentlyContinue).Count | Should -Be 0
        } finally {
            [Environment]::SetEnvironmentVariable("ITL_RUNNER_STATUS_STALE_WARNING_SECONDS", $previousWarning, "Process")
            [Environment]::SetEnvironmentVariable("ITL_RUNNER_STATUS_STALE_TIMEOUT_SECONDS", $previousTimeout, "Process")
            if ($fixturePid -gt 0) { Stop-Process -Id $fixturePid -Force -ErrorAction SilentlyContinue }
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "fails a synchronously stale helper status when liveness is empty" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-compact-stale-empty-liveness-" + [guid]::NewGuid().ToString("N"))
        $previousWarning = [Environment]::GetEnvironmentVariable("ITL_RUNNER_STATUS_STALE_WARNING_SECONDS", "Process")
        $previousTimeout = [Environment]::GetEnvironmentVariable("ITL_RUNNER_STATUS_STALE_TIMEOUT_SECONDS", "Process")
        $fixturePid = 0
        try {
            $scriptRoot = Join-Path $tempRoot ".agents\skills\1c-workflow\scripts"
            New-Item -ItemType Directory -Force -Path $scriptRoot | Out-Null
            Copy-RunnerFixture -Destination (Join-Path $scriptRoot "run-itl-command.ps1")
            Set-Content -LiteralPath (Join-Path $scriptRoot "agent-1c.ps1") -Encoding UTF8 -Value @'
param([string]$ProjectRoot,[string]$RunStatusPath,[string]$RunLogPath,[string]$Action)
$now = Get-Date
$payload = [ordered]@{ schemaVersion=1; status='running'; action=$Action; projectRoot=$ProjectRoot; pid=$PID; startedAt=$now.ToString('o'); updatedAt=$now.ToString('o'); stage='start'; stageDetail='Starting helper action refresh-dev-branch-lite'; liveness=''; noProgressSeconds=0; stallTimeoutRemainingSeconds=0; timeoutRemainingSeconds=0; exitCode=$null; errorMessage='' }
[IO.File]::WriteAllText($RunStatusPath,(($payload | ConvertTo-Json -Depth 5)+[Environment]::NewLine),(New-Object Text.UTF8Encoding $false))
Start-Sleep -Seconds 30
exit 0
'@
            [Environment]::SetEnvironmentVariable("ITL_RUNNER_STATUS_STALE_WARNING_SECONDS", "1", "Process")
            [Environment]::SetEnvironmentVariable("ITL_RUNNER_STATUS_STALE_TIMEOUT_SECONDS", "2", "Process")
            $stopwatch = [Diagnostics.Stopwatch]::StartNew()
            $processResult = Invoke-TestPowerShellFile -FilePath (Join-Path $scriptRoot "run-itl-command.ps1") -Arguments @("--", "-Action", "refresh-dev-branch-lite")
            $stopwatch.Stop()

            $processResult.exitCode | Should -Not -Be 0
            $stopwatch.Elapsed.TotalSeconds | Should -BeLessThan 15
            $summary = ($processResult.stdout -join "`n") | ConvertFrom-Json
            $summary.status | Should -Be "failed"
            $summary.stage | Should -Be "runner.status-stale"
            $summary.error | Should -Match '^RUNNER_STATUS_STALE\b'
            $status = Get-Content -LiteralPath $summary.statusPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $fixturePid = [int]$status.pid
            $status.errorCode | Should -Be "LIFECYCLE_OPERATION_STATUS_STALE"
            @(Get-Process -Id $fixturePid -ErrorAction SilentlyContinue).Count | Should -Be 0
        } finally {
            [Environment]::SetEnvironmentVariable("ITL_RUNNER_STATUS_STALE_WARNING_SECONDS", $previousWarning, "Process")
            [Environment]::SetEnvironmentVariable("ITL_RUNNER_STATUS_STALE_TIMEOUT_SECONDS", $previousTimeout, "Process")
            if ($fixturePid -gt 0) { Stop-Process -Id $fixturePid -Force -ErrorAction SilentlyContinue }
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "fails a live helper that exceeds the compact operation limit" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-compact-operation-timeout-" + [guid]::NewGuid().ToString("N"))
        $previousTimeout = [Environment]::GetEnvironmentVariable("ITL_RUNNER_OPERATION_TIMEOUT_SECONDS", "Process")
        $fixturePid = 0
        try {
            $scriptRoot = Join-Path $tempRoot ".agents\skills\1c-workflow\scripts"
            New-Item -ItemType Directory -Force -Path $scriptRoot | Out-Null
            Copy-RunnerFixture -Destination (Join-Path $scriptRoot "run-itl-command.ps1")
            Set-Content -LiteralPath (Join-Path $scriptRoot "agent-1c.ps1") -Encoding UTF8 -Value @'
param([string]$ProjectRoot,[string]$RunStatusPath,[string]$RunLogPath,[string]$Action)
while ($true) {
    $now = Get-Date
    $payload = [ordered]@{ schemaVersion=1; status='running'; action=$Action; projectRoot=$ProjectRoot; pid=$PID; startedAt=$now.ToString('o'); updatedAt=$now.ToString('o'); stage='start'; stageDetail='Starting helper action refresh-dev-branch-lite'; liveness=''; noProgressSeconds=0; stallTimeoutRemainingSeconds=0; timeoutRemainingSeconds=0; exitCode=$null; errorMessage='' }
    [IO.File]::WriteAllText($RunStatusPath,(($payload | ConvertTo-Json -Depth 5)+[Environment]::NewLine),(New-Object Text.UTF8Encoding $false))
    Start-Sleep -Milliseconds 400
}
'@
            [Environment]::SetEnvironmentVariable("ITL_RUNNER_OPERATION_TIMEOUT_SECONDS", "3", "Process")
            $stopwatch = [Diagnostics.Stopwatch]::StartNew()
            $processResult = Invoke-TestPowerShellFile -FilePath (Join-Path $scriptRoot "run-itl-command.ps1") -Arguments @("--", "-Action", "refresh-dev-branch-lite")
            $stopwatch.Stop()

            $processResult.exitCode | Should -Not -Be 0
            $stopwatch.Elapsed.TotalSeconds | Should -BeLessThan 15
            $summary = ($processResult.stdout -join "`n") | ConvertFrom-Json
            $summary.status | Should -Be "failed"
            $summary.stage | Should -Be "runner.operation-timeout"
            $summary.error | Should -Match '^RUNNER_OPERATION_TIMEOUT\b'
            $status = Get-Content -LiteralPath $summary.statusPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $fixturePid = [int]$status.pid
            $status.errorCode | Should -Be "LIFECYCLE_OPERATION_TIMEOUT"
            $status.liveness | Should -Be "failed-operation-timeout"
            @(Get-Process -Id $fixturePid -ErrorAction SilentlyContinue).Count | Should -Be 0
        } finally {
            [Environment]::SetEnvironmentVariable("ITL_RUNNER_OPERATION_TIMEOUT_SECONDS", $previousTimeout, "Process")
            if ($fixturePid -gt 0) { Stop-Process -Id $fixturePid -Force -ErrorAction SilentlyContinue }
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'rechecks the owned handoff after reading stale status and preserves the actual terminal failure' {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('itl runner передача с пробелом ' + [guid]::NewGuid().ToString('N'))
        $oldWarning = $env:ITL_RUNNER_STATUS_STALE_WARNING_SECONDS
        $oldStale = $env:ITL_RUNNER_STATUS_STALE_TIMEOUT_SECONDS
        try {
            $scriptRoot = Join-Path $tempRoot '.agents/skills/1c-workflow/scripts'
            $runnerPath = Join-Path $scriptRoot 'run-itl-command.ps1'
            Copy-RunnerFixture -Destination $runnerPath
            # Control the file-read interleaving, leaving watchdog decisions and
            # the helper's terminal result in the actual runner implementation.
            $readHook = @'
$script:HandoffInjected = $false
function Read-JsonFile {
    param([string]$Path)
    $observed = Read-JsonFileActual -Path $Path
    if ($null -ne $observed -and [string](Get-ObjectValue -Object $observed -Name 'stage' -Default '') -eq 'controlled-handoff' -and -not $script:HandoffInjected) {
        $script:HandoffInjected = $true
        $published = Read-JsonFileActual -Path $Path
        $published.updatedAt = [DateTimeOffset]::UtcNow.ToString('o')
        Write-JsonFileAtomic -Path $Path -Value $published
        [IO.File]::Delete($Path + '.heartbeat')
        [IO.File]::WriteAllText($Path + '.handoff', 'published')
    }
    return $observed
}
'@
            $runnerText = [IO.File]::ReadAllText($runnerPath).Replace('function Read-JsonFile {', 'function Read-JsonFileActual {')
            $runnerText = $runnerText.Replace('function Write-JsonFileAtomic {', ($readHook + "`nfunction Write-JsonFileAtomic {"))
            [IO.File]::WriteAllText($runnerPath, $runnerText, [Text.UTF8Encoding]::new($true))
            Set-Content -LiteralPath (Join-Path $scriptRoot 'agent-1c.ps1') -Encoding UTF8 -Value @'
param([string]$ProjectRoot,[string]$RunStatusPath,[string]$RunLogPath,[string]$Action)
$now = Get-Date
$payload = [ordered]@{ schemaVersion=1; status='running'; action=$Action; projectRoot=$ProjectRoot; pid=$PID; startedAt=$now.ToString('o'); updatedAt='2000-01-01T00:00:00Z'; stage='controlled-handoff'; stageDetail='journal scan complete'; liveness=''; noProgressSeconds=0; stallTimeoutRemainingSeconds=0; timeoutRemainingSeconds=0; exitCode=$null; errorMessage='' }
$initialHeartbeat=$RunStatusPath + '.heartbeat.initial'
[IO.File]::WriteAllText($initialHeartbeat, [string]$PID)
[IO.File]::SetLastWriteTimeUtc($initialHeartbeat, [datetime]'2000-01-01')
[IO.File]::Move($initialHeartbeat, ($RunStatusPath + '.heartbeat'))
# Publish the controlled stale state only after its sidecar is complete. A
# concurrent reader must not make the fixture's SetLastWriteTimeUtc fail.
[IO.File]::WriteAllText($RunStatusPath, ($payload | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
$deadline = [DateTime]::UtcNow.AddSeconds(8)
while (-not (Test-Path -LiteralPath ($RunStatusPath + '.handoff'))) {
    if ([DateTime]::UtcNow -ge $deadline) { throw 'CONTROLLED_HANDOFF_NOT_REACHED' }
    Start-Sleep -Milliseconds 50
}
Start-Sleep -Milliseconds 700
$payload.status='failed'; $payload.stage='fixture.actual-terminal'; $payload.updatedAt=(Get-Date).ToString('o'); $payload.exitCode=7; $payload.errorMessage='Настоящий отказ после журнала'
[IO.File]::WriteAllText($RunStatusPath, ($payload | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
exit 7
'@
            $env:ITL_RUNNER_STATUS_STALE_WARNING_SECONDS = '1'
            $env:ITL_RUNNER_STATUS_STALE_TIMEOUT_SECONDS = '2'
            $result = Invoke-TestPowerShellFile -FilePath $runnerPath -Arguments @('--', '-Action', 'check-dev-branch')
            $result.exitCode | Should -Be 7 -Because $result.combinedText
            $summary = ($result.stdout -join "`n") | ConvertFrom-Json
            Test-Path -LiteralPath ($summary.statusPath + '.handoff') | Should -BeTrue
            $summary.stage | Should -Be 'fixture.actual-terminal'
            $summary.error | Should -Be 'Настоящий отказ после журнала'
            $summary.status | Should -Be 'failed'
            $result.combinedText | Should -Not -Match 'RUNNER_STATUS_STALE'
        } finally {
            $env:ITL_RUNNER_STATUS_STALE_WARNING_SECONDS = $oldWarning
            $env:ITL_RUNNER_STATUS_STALE_TIMEOUT_SECONDS = $oldStale
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "accepts an owned heartbeat during a long silent helper phase" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl runner heartbeat путь " + [guid]::NewGuid().ToString("N"))
        $previousWarning = [Environment]::GetEnvironmentVariable("ITL_RUNNER_STATUS_STALE_WARNING_SECONDS", "Process")
        $previousStale = [Environment]::GetEnvironmentVariable("ITL_RUNNER_STATUS_STALE_TIMEOUT_SECONDS", "Process")
        $previousTimeout = [Environment]::GetEnvironmentVariable("ITL_RUNNER_OPERATION_TIMEOUT_SECONDS", "Process")
        try {
            $scriptRoot = Join-Path $tempRoot ".agents\skills\1c-workflow\scripts"
            New-Item -ItemType Directory -Force -Path $scriptRoot | Out-Null
            Copy-RunnerFixture -Destination (Join-Path $scriptRoot "run-itl-command.ps1")
            Set-Content -LiteralPath (Join-Path $scriptRoot "agent-1c.ps1") -Encoding UTF8 -Value @'
param([string]$ProjectRoot,[string]$RunStatusPath,[string]$RunLogPath,[string]$Action)
$now = Get-Date
$payload = [ordered]@{ schemaVersion=1; status='running'; action=$Action; projectRoot=$ProjectRoot; pid=$PID; startedAt=$now.ToString('o'); updatedAt=$now.ToString('o'); stage='long-copy'; stageDetail='copying'; liveness=''; noProgressSeconds=0; stallTimeoutRemainingSeconds=0; timeoutRemainingSeconds=0; exitCode=$null; errorMessage='' }
[IO.File]::WriteAllText($RunStatusPath,(($payload | ConvertTo-Json -Depth 5)+[Environment]::NewLine),(New-Object Text.UTF8Encoding $false))
$heartbeatPath = $RunStatusPath + '.heartbeat'
[IO.File]::WriteAllText($heartbeatPath,[string]$PID,[Text.Encoding]::ASCII)
for($i=0;$i -lt 5;$i++){ Start-Sleep -Milliseconds 650; [IO.File]::SetLastWriteTimeUtc($heartbeatPath,[DateTime]::UtcNow) }
$payload.status='succeeded'; $payload.stage='complete'; $payload.updatedAt=(Get-Date).ToString('o'); $payload.exitCode=0
[IO.File]::WriteAllText($RunStatusPath,(($payload | ConvertTo-Json -Depth 5)+[Environment]::NewLine),(New-Object Text.UTF8Encoding $false))
exit 0
'@
            [Environment]::SetEnvironmentVariable("ITL_RUNNER_STATUS_STALE_WARNING_SECONDS", "1", "Process")
            [Environment]::SetEnvironmentVariable("ITL_RUNNER_STATUS_STALE_TIMEOUT_SECONDS", "2", "Process")
            [Environment]::SetEnvironmentVariable("ITL_RUNNER_OPERATION_TIMEOUT_SECONDS", "8", "Process")
            $result = Invoke-TestPowerShellFile -FilePath (Join-Path $scriptRoot "run-itl-command.ps1") -Arguments @("--", "-Action", "check-dev-branch")
            $result.exitCode | Should -Be 0
            $summary = ($result.stdout -join "`n") | ConvertFrom-Json
            $summary.status | Should -Be 'succeeded'
            ($result.stderr -join "`n") | Should -Match 'liveness=helper-heartbeat'
            (Test-Path -LiteralPath ($summary.statusPath + '.heartbeat')) | Should -BeFalse
        } finally {
            [Environment]::SetEnvironmentVariable("ITL_RUNNER_STATUS_STALE_WARNING_SECONDS", $previousWarning, "Process")
            [Environment]::SetEnvironmentVariable("ITL_RUNNER_STATUS_STALE_TIMEOUT_SECONDS", $previousStale, "Process")
            [Environment]::SetEnvironmentVariable("ITL_RUNNER_OPERATION_TIMEOUT_SECONDS", $previousTimeout, "Process")
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "does not slide the action deadline when a phase repeats its remaining budget" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl deadline путь " + [guid]::NewGuid().ToString("N"))
        $previousTimeout = [Environment]::GetEnvironmentVariable("ITL_RUNNER_OPERATION_TIMEOUT_SECONDS", "Process")
        try {
            $scriptRoot = Join-Path $tempRoot ".agents\skills\1c-workflow\scripts"
            New-Item -ItemType Directory -Force -Path $scriptRoot | Out-Null
            Copy-RunnerFixture -Destination (Join-Path $scriptRoot "run-itl-command.ps1")
            Set-Content -LiteralPath (Join-Path $scriptRoot "agent-1c.ps1") -Encoding UTF8 -Value @'
param([string]$ProjectRoot,[string]$RunStatusPath,[string]$RunLogPath,[string]$Action)
for($i=0;$i -lt 20;$i++){
    $now=Get-Date
    $payload=[ordered]@{schemaVersion=1;status='running';action=$Action;projectRoot=$ProjectRoot;pid=$PID;startedAt=$now.ToString('o');updatedAt=$now.ToString('o');stage='designer-wait';stageDetail='waiting';liveness='running';noProgressSeconds=0;stallTimeoutRemainingSeconds=0;timeoutRemainingSeconds=3;exitCode=$null;errorMessage=''}
    [IO.File]::WriteAllText($RunStatusPath,(($payload | ConvertTo-Json -Depth 5)+[Environment]::NewLine),(New-Object Text.UTF8Encoding $false))
    Start-Sleep -Milliseconds 400
}
$payload.status='succeeded';$payload.exitCode=0
[IO.File]::WriteAllText($RunStatusPath,(($payload | ConvertTo-Json -Depth 5)+[Environment]::NewLine),(New-Object Text.UTF8Encoding $false))
exit 0
'@
            [Environment]::SetEnvironmentVariable("ITL_RUNNER_OPERATION_TIMEOUT_SECONDS", "2", "Process")
            $watch = [Diagnostics.Stopwatch]::StartNew()
            $result = Invoke-TestPowerShellFile -FilePath (Join-Path $scriptRoot "run-itl-command.ps1") -Arguments @("--", "-Action", "check-dev-branch")
            $watch.Stop()
            $result.exitCode | Should -Not -Be 0
            $summary = ($result.stdout -join "`n") | ConvertFrom-Json
            $summary.stage | Should -Be 'runner.operation-timeout'
            # Process startup and tree cleanup are outside the reserved phase deadline.
            # Observe that deadline itself, keeping the original repeated-budget fixture.
            $extensions = [regex]::Matches(($result.stderr -join "`n"), '(?m)^ITL timeout extension: source=phase-budget:designer-wait\|running\|; deadlineUtc=(?<deadline>[^;]+);')
            $extensions.Count | Should -Be 1 -Because ("the same phase must reserve its deadline once; outer invocation took {0:N3}s" -f $watch.Elapsed.TotalSeconds)
            $terminal = Get-Content -LiteralPath $summary.statusPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $terminal.operationTimeoutSource | Should -BeExactly 'phase-budget:designer-wait|running|'
            $terminal.operationDeadlineUtc | Should -BeExactly $extensions[0].Groups['deadline'].Value
        } finally {
            [Environment]::SetEnvironmentVariable("ITL_RUNNER_OPERATION_TIMEOUT_SECONDS", $previousTimeout, "Process")
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        # The stopped watch retains the original end-to-end bound after cleanup.
        $watch.Elapsed.TotalSeconds | Should -BeLessThan 7
        ($result.stderr -join "`n") | Should -Match 'ITL timeout extension: source=phase-budget:designer-wait\|running\|;'
    }

    It 'does not add a delayed status read to the published phase budget' {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('itl deadline задержка чтения ' + [guid]::NewGuid().ToString('N'))
        $previousTimeout = $env:ITL_RUNNER_OPERATION_TIMEOUT_SECONDS
        try {
            $scriptRoot = Join-Path $tempRoot '.agents/skills/1c-workflow/scripts'
            $runnerPath = Join-Path $scriptRoot 'run-itl-command.ps1'
            Copy-RunnerFixture -Destination $runnerPath
            # Preserve the first real status snapshot while reproducing a slow
            # read/scheduled runner. Its remaining budget belongs to publication,
            # not to the later instant at which the reader resumes.
            $readHook = @'
function Read-JsonFile {
    param([string]$Path)
    $observed = Read-JsonFileActual -Path $Path
    # Read-JsonFile also reads lifecycle records, which deliberately have a
    # phase rather than a stage. Delay only the original helper status.
    if ($observed -and (Get-ObjectValue -Object $observed -Name 'stage' -Default '') -eq 'designer-wait' -and -not (Test-Path -LiteralPath ($Path + '.delayed-read'))) {
        [IO.File]::WriteAllText($Path + '.delayed-read', [string]$observed.updatedAt)
        Start-Sleep -Seconds 3
    }
    return $observed
}
'@
            $runnerText = [IO.File]::ReadAllText($runnerPath).Replace('function Read-JsonFile {', 'function Read-JsonFileActual {')
            $runnerText = $runnerText.Replace('function Write-JsonFileAtomic {', ($readHook + "`nfunction Write-JsonFileAtomic {"))
            [IO.File]::WriteAllText($runnerPath, $runnerText, [Text.UTF8Encoding]::new($true))
            Set-Content -LiteralPath (Join-Path $scriptRoot 'agent-1c.ps1') -Encoding UTF8 -Value @'
param([string]$ProjectRoot,[string]$RunStatusPath,[string]$RunLogPath,[string]$Action)
for($i=0;$i -lt 20;$i++){
    $now=Get-Date
    $payload=[ordered]@{schemaVersion=1;status='running';action=$Action;projectRoot=$ProjectRoot;pid=$PID;startedAt=$now.ToString('o');updatedAt=$now.ToString('o');stage='designer-wait';stageDetail='waiting';liveness='running';noProgressSeconds=0;stallTimeoutRemainingSeconds=0;timeoutRemainingSeconds=3;exitCode=$null;errorMessage=''}
    [IO.File]::WriteAllText($RunStatusPath,(($payload | ConvertTo-Json -Depth 5)+[Environment]::NewLine),(New-Object Text.UTF8Encoding $false))
    Start-Sleep -Milliseconds 400
}
$payload.status='succeeded';$payload.exitCode=0
[IO.File]::WriteAllText($RunStatusPath,(($payload | ConvertTo-Json -Depth 5)+[Environment]::NewLine),(New-Object Text.UTF8Encoding $false))
exit 0
'@
            $env:ITL_RUNNER_OPERATION_TIMEOUT_SECONDS = '2'
            $watch = [Diagnostics.Stopwatch]::StartNew()
            $result = Invoke-TestPowerShellFile -FilePath $runnerPath -Arguments @('--', '-Action', 'check-dev-branch')
            $watch.Stop()
            $result.exitCode | Should -Not -Be 0
            $watch.Elapsed.TotalSeconds | Should -BeLessThan 7 -Because $result.combinedText
            $summary = ($result.stdout -join "`n") | ConvertFrom-Json
            $summary.stage | Should -Be 'runner.operation-timeout'
            Test-Path -LiteralPath ($summary.statusPath + '.delayed-read') | Should -BeTrue
            $phaseReport = @($result.stderr | Where-Object { $_ -match '^ITL timeout extension: source=phase-budget:' })
            $phaseReport.Count | Should -Be 1
            $deadlineMatch = [regex]::Match([string]$phaseReport[0], 'deadlineUtc=([^;]+);')
            $deadlineMatch.Success | Should -BeTrue
            $phaseDeadline = [DateTimeOffset]::Parse($deadlineMatch.Groups[1].Value)
            $publishedAt = [DateTimeOffset]::Parse([IO.File]::ReadAllText($summary.statusPath + '.delayed-read'))
            ($phaseDeadline - $publishedAt).TotalSeconds | Should -BeLessThan 3.2
        } finally {
            $env:ITL_RUNNER_OPERATION_TIMEOUT_SECONDS = $previousTimeout
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "does not replace terminal success while the helper is finishing cleanup" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl terminal status путь " + [guid]::NewGuid().ToString("N"))
        $previousWarning = [Environment]::GetEnvironmentVariable("ITL_RUNNER_STATUS_STALE_WARNING_SECONDS", "Process")
        $previousStale = [Environment]::GetEnvironmentVariable("ITL_RUNNER_STATUS_STALE_TIMEOUT_SECONDS", "Process")
        $previousTimeout = [Environment]::GetEnvironmentVariable("ITL_RUNNER_OPERATION_TIMEOUT_SECONDS", "Process")
        try {
            $scriptRoot = Join-Path $tempRoot ".agents\skills\1c-workflow\scripts"
            New-Item -ItemType Directory -Force -Path $scriptRoot | Out-Null
            Copy-RunnerFixture -Destination (Join-Path $scriptRoot "run-itl-command.ps1")
            Set-Content -LiteralPath (Join-Path $scriptRoot "agent-1c.ps1") -Encoding UTF8 -Value @'
param([string]$ProjectRoot,[string]$RunStatusPath,[string]$RunLogPath,[string]$Action)
$now=Get-Date
$payload=[ordered]@{schemaVersion=1;status='succeeded';action=$Action;projectRoot=$ProjectRoot;pid=$PID;startedAt=$now.ToString('o');updatedAt=$now.ToString('o');stage='complete';stageDetail='cleanup';liveness='';noProgressSeconds=0;stallTimeoutRemainingSeconds=0;timeoutRemainingSeconds=0;exitCode=0;errorMessage=''}
[IO.File]::WriteAllText($RunStatusPath,(($payload | ConvertTo-Json -Depth 5)+[Environment]::NewLine),(New-Object Text.UTF8Encoding $false))
Start-Sleep -Seconds 3
exit 0
'@
            [Environment]::SetEnvironmentVariable("ITL_RUNNER_STATUS_STALE_WARNING_SECONDS", "1", "Process")
            [Environment]::SetEnvironmentVariable("ITL_RUNNER_STATUS_STALE_TIMEOUT_SECONDS", "2", "Process")
            [Environment]::SetEnvironmentVariable("ITL_RUNNER_OPERATION_TIMEOUT_SECONDS", "8", "Process")
            $result = Invoke-TestPowerShellFile -FilePath (Join-Path $scriptRoot "run-itl-command.ps1") -Arguments @("--", "-Action", "check-dev-branch")
            $result.exitCode | Should -Be 0
            $summary = ($result.stdout -join "`n") | ConvertFrom-Json
            $summary.status | Should -Be 'succeeded'
        } finally {
            [Environment]::SetEnvironmentVariable("ITL_RUNNER_STATUS_STALE_WARNING_SECONDS", $previousWarning, "Process")
            [Environment]::SetEnvironmentVariable("ITL_RUNNER_STATUS_STALE_TIMEOUT_SECONDS", $previousStale, "Process")
            [Environment]::SetEnvironmentVariable("ITL_RUNNER_OPERATION_TIMEOUT_SECONDS", $previousTimeout, "Process")
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'honors terminal cleanup grace across the action deadline and bounds a stuck terminal helper: <Case>' -ForEach @(
        @{Case='exits';CleanupSeconds=10;ExpectedExit=0},
        @{Case='stuck';CleanupSeconds=90;ExpectedExit=1}
    ) {
        $caseCleanupSeconds = $CleanupSeconds
        $caseExpectedExit = $ExpectedExit
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('itl terminal deadline путь ' + [guid]::NewGuid().ToString('N'))
        $previousTimeout = $env:ITL_RUNNER_OPERATION_TIMEOUT_SECONDS
        try {
            $scriptRoot = Join-Path $tempRoot '.agents/skills/1c-workflow/scripts'
            New-Item -ItemType Directory -Force -Path $scriptRoot | Out-Null
            Copy-RunnerFixture -Destination (Join-Path $scriptRoot 'run-itl-command.ps1')
            $fixture = @'
param([string]$ProjectRoot,[string]$RunStatusPath,[string]$RunLogPath,[string]$Action)
$now=Get-Date
$payload=[ordered]@{schemaVersion=1;status='succeeded';action=$Action;projectRoot=$ProjectRoot;pid=$PID;startedAt=$now.ToString('o');updatedAt=$now.ToString('o');stage='complete';stageDetail='cleanup beyond action deadline';liveness='';exitCode=0;errorMessage=''}
[IO.File]::WriteAllText($RunStatusPath,($payload|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
Start-Sleep -Seconds __CLEANUP_SECONDS__
exit 0
'@
            Set-Content -LiteralPath (Join-Path $scriptRoot 'agent-1c.ps1') -Encoding UTF8 -Value $fixture.Replace('__CLEANUP_SECONDS__',[string]$caseCleanupSeconds)
            $env:ITL_RUNNER_OPERATION_TIMEOUT_SECONDS='8'
            $watch=[Diagnostics.Stopwatch]::StartNew()
            $result=Invoke-TestPowerShellFile -FilePath (Join-Path $scriptRoot 'run-itl-command.ps1') -Arguments @('--','-Action','check-dev-branch')
            $watch.Stop()
            $result.exitCode | Should -Be $caseExpectedExit -Because $result.combinedText
            $summary=($result.stdout -join "`n")|ConvertFrom-Json
            if($caseExpectedExit -eq 0){
                $summary.status|Should -Be succeeded
                $summary.stage|Should -Be complete
                $watch.Elapsed.TotalSeconds|Should -BeGreaterThan 8
            }else{
                $summary.status|Should -Be failed
                $summary.stage|Should -Be 'runner.operation-timeout'
                $summary.error|Should -Match 'terminal status.*bounded grace period'
                $watch.Elapsed.TotalSeconds|Should -BeLessThan 80
                $status=Get-Content -LiteralPath $summary.statusPath -Raw -Encoding UTF8|ConvertFrom-Json
                @(Get-Process -Id ([int]$status.pid) -ErrorAction SilentlyContinue).Count|Should -Be 0
            }
        } finally {
            $env:ITL_RUNNER_OPERATION_TIMEOUT_SECONDS=$previousTimeout
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "lets the helper own its published Designer stall budget before the runner watchdog fails" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-compact-stall-owner-" + [guid]::NewGuid().ToString("N"))
        $previousWarning = [Environment]::GetEnvironmentVariable("ITL_RUNNER_STATUS_STALE_WARNING_SECONDS", "Process")
        $previousTimeout = [Environment]::GetEnvironmentVariable("ITL_RUNNER_STATUS_STALE_TIMEOUT_SECONDS", "Process")
        try {
            $scriptRoot = Join-Path $tempRoot ".agents\skills\1c-workflow\scripts"
            New-Item -ItemType Directory -Force -Path $scriptRoot | Out-Null
            Copy-RunnerFixture -Destination (Join-Path $scriptRoot "run-itl-command.ps1")
            Set-Content -LiteralPath (Join-Path $scriptRoot "agent-1c.ps1") -Encoding UTF8 -Value @'
param([string]$ProjectRoot,[string]$RunStatusPath,[string]$RunLogPath,[string]$Action)
$now = Get-Date
$payload = [ordered]@{ schemaVersion=1; status='running'; action=$Action; projectRoot=$ProjectRoot; pid=$PID; startedAt=$now.ToString('o'); updatedAt=$now.ToString('o'); stage='designer-wait'; stageDetail='bounded completion probe'; liveness='probe-running'; noProgressSeconds=0; stallTimeoutRemainingSeconds=4; timeoutRemainingSeconds=60; exitCode=$null; errorMessage='' }
[IO.File]::WriteAllText($RunStatusPath,(($payload | ConvertTo-Json -Depth 5)+[Environment]::NewLine),(New-Object Text.UTF8Encoding $false))
Start-Sleep -Seconds 30
exit 0
'@
            [Environment]::SetEnvironmentVariable("ITL_RUNNER_STATUS_STALE_WARNING_SECONDS", "1", "Process")
            [Environment]::SetEnvironmentVariable("ITL_RUNNER_STATUS_STALE_TIMEOUT_SECONDS", "2", "Process")
            $stopwatch = [Diagnostics.Stopwatch]::StartNew()
            $processResult = Invoke-TestPowerShellFile -FilePath (Join-Path $scriptRoot "run-itl-command.ps1") -Arguments @("--", "-Action", "refresh-dev-branch")
            $stopwatch.Stop()

            $processResult.exitCode | Should -Not -Be 0
            $stopwatch.Elapsed.TotalSeconds | Should -BeGreaterOrEqual 4
            $stopwatch.Elapsed.TotalSeconds | Should -BeLessThan 15
            $summary = ($processResult.stdout -join "`n") | ConvertFrom-Json
            $summary.error | Should -Match 'effective watchdog 5s'
        } finally {
            [Environment]::SetEnvironmentVariable("ITL_RUNNER_STATUS_STALE_WARNING_SECONDS", $previousWarning, "Process")
            [Environment]::SetEnvironmentVariable("ITL_RUNNER_STATUS_STALE_TIMEOUT_SECONDS", $previousTimeout, "Process")
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "ignores a transient epoch timestamp while an atomic status replacement is unreadable" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-compact-status-epoch-" + [guid]::NewGuid().ToString("N"))
        try {
            $scriptRoot = Join-Path $tempRoot ".agents\skills\1c-workflow\scripts"
            New-Item -ItemType Directory -Force -Path $scriptRoot | Out-Null
            Copy-RunnerFixture -Destination (Join-Path $scriptRoot "run-itl-command.ps1")
            Set-Content -LiteralPath (Join-Path $scriptRoot "agent-1c.ps1") -Encoding UTF8 -Value @'
param([string]$ProjectRoot,[string]$RunStatusPath,[string]$RunLogPath,[string]$Action)
$running = [ordered]@{ schemaVersion=1; status='running'; action=$Action; projectRoot=$ProjectRoot; pid=$PID; stage='designer-wait'; stageDetail='atomic replacement window'; liveness='probe-running'; noProgressSeconds=0; stallTimeoutRemainingSeconds=10; timeoutRemainingSeconds=60; exitCode=$null; errorMessage='' }
[IO.File]::WriteAllText($RunStatusPath,(($running | ConvertTo-Json -Depth 5)+[Environment]::NewLine),(New-Object Text.UTF8Encoding $false))
[IO.File]::SetLastWriteTimeUtc($RunStatusPath,[DateTime]::FromFileTimeUtc(0))
Start-Sleep -Seconds 2
$now = Get-Date
$done = [ordered]@{ schemaVersion=1; status='succeeded'; action=$Action; projectRoot=$ProjectRoot; pid=$PID; startedAt=$now.ToString('o'); updatedAt=$now.ToString('o'); finishedAt=$now.ToString('o'); stage='complete'; stageDetail='done'; liveness=''; noProgressSeconds=0; stallTimeoutRemainingSeconds=0; timeoutRemainingSeconds=0; exitCode=0; errorMessage='' }
[IO.File]::WriteAllText($RunStatusPath,(($done | ConvertTo-Json -Depth 5)+[Environment]::NewLine),(New-Object Text.UTF8Encoding $false))
exit 0
'@
            $processResult = Invoke-TestPowerShellFile -FilePath (Join-Path $scriptRoot "run-itl-command.ps1") -Arguments @("--", "-Action", "refresh-dev-branch")

            $processResult.exitCode | Should -Be 0
            $summary = ($processResult.stdout -join "`n") | ConvertFrom-Json
            $summary.status | Should -Be "succeeded"
            ($processResult.stderr -join "`n") | Should -Not -Match 'MethodArgumentConversionInvalidCastArgument'
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "finalizes a running status when the helper process exits with an error" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-compact-running-exit-" + [guid]::NewGuid().ToString("N"))
        try {
            $scriptRoot = Join-Path $tempRoot ".agents\skills\1c-workflow\scripts"
            New-Item -ItemType Directory -Force -Path $scriptRoot | Out-Null
            Copy-RunnerFixture -Destination (Join-Path $scriptRoot "run-itl-command.ps1")
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

    It "cleans an exact lifecycle-owned Vanessa run after helper exit" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-compact-vanessa-recovery-" + [guid]::NewGuid().ToString("N"))
        try {
            $scriptRoot = Join-Path $tempRoot ".agents\skills\1c-workflow\scripts"
            New-Item -ItemType Directory -Force -Path $scriptRoot | Out-Null
            Copy-RunnerFixture -Destination (Join-Path $scriptRoot "run-itl-command.ps1")
            Set-Content -LiteralPath (Join-Path $scriptRoot "agent-1c.ps1") -Encoding UTF8 -Value @'
param(
    [string]$ProjectRoot,[string]$RunStatusPath,[string]$RunLogPath,[string]$Action,
    [string]$InterruptedVanessaInfoBasePath,[string]$InterruptedVanessaTestClientInfoBasePath,
    [string]$InterruptedVanessaRunParamsPath,[string]$InterruptedVanessaTestPorts
)
$utf8 = New-Object Text.UTF8Encoding $false
if ($Action -eq 'cleanup-interrupted-vanessa-run') {
    $marker = [ordered]@{ infoBasePath=$InterruptedVanessaInfoBasePath; testClientInfoBasePath=$InterruptedVanessaTestClientInfoBasePath; runParamsPath=$InterruptedVanessaRunParamsPath; testPorts=$InterruptedVanessaTestPorts }
    [IO.File]::WriteAllText((Join-Path $ProjectRoot 'cleanup-marker.json'),(($marker | ConvertTo-Json)+[Environment]::NewLine),$utf8)
    exit 0
}
$operationId = [guid]::NewGuid().ToString('N')
$paramsPath = Join-Path $ProjectRoot 'build\test-results\vanessa\fixture\VAParams.json'
$lifecyclePath = Join-Path $ProjectRoot '.agent-1c\locks\lifecycle-operation.json'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $paramsPath),(Split-Path -Parent $lifecyclePath) | Out-Null
[IO.File]::WriteAllText($paramsPath,'{}',$utf8)
$evidence = [ordered]@{ schemaVersion=2; operationId=$operationId; ownerPid=$PID; processId=$PID; projectRoot=$ProjectRoot; infoBasePath=(Join-Path $ProjectRoot '.agent-1c\infobases\vanessa-service'); testClientInfoBasePath=(Join-Path $ProjectRoot '.agent-1c\infobases\branch1'); runParamsPath=$paramsPath; testPorts=@(48054,48055) }
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
            $summary.error | Should -Match "Exact interrupted Vanessa process cleanup succeeded"

            $marker = Get-Content -LiteralPath (Join-Path $tempRoot "cleanup-marker.json") -Raw -Encoding UTF8 | ConvertFrom-Json
            $marker.infoBasePath | Should -Be (Join-Path $tempRoot ".agent-1c\infobases\vanessa-service")
            $marker.testClientInfoBasePath | Should -Be (Join-Path $tempRoot ".agent-1c\infobases\branch1")
            $marker.runParamsPath | Should -Be (Join-Path $tempRoot "build\test-results\vanessa\fixture\VAParams.json")
            $marker.testPorts | Should -Be "48054,48055"
            $lifecycle = Get-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\locks\lifecycle-operation.json") -Raw -Encoding UTF8 | ConvertFrom-Json
            $lifecycle.status | Should -Be "failed"
            $lifecycle.phase | Should -Be "runner.helper-exited"
            $lifecycle.errorCode | Should -Be "LIFECYCLE_OPERATION_HELPER_EXITED"
            $lifecycle.finishedAt | Should -Not -BeNullOrEmpty
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "recovers exact terminal lifecycle success when a reexec helper leaves status running" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-compact-terminal-lifecycle-" + [guid]::NewGuid().ToString("N"))
        try {
            $scriptRoot = Join-Path $tempRoot ".agents\skills\1c-workflow\scripts"
            New-Item -ItemType Directory -Force -Path $scriptRoot | Out-Null
            Copy-RunnerFixture -Destination (Join-Path $scriptRoot "run-itl-command.ps1")
            Set-Content -LiteralPath (Join-Path $scriptRoot "agent-1c.ps1") -Encoding UTF8 -Value @'
param([string]$ProjectRoot,[string]$RunStatusPath,[string]$RunLogPath,[string]$Action)
$utf8 = New-Object Text.UTF8Encoding $false
$operationId = [guid]::NewGuid().ToString('N')
$lifecyclePath = Join-Path $ProjectRoot '.agent-1c\locks\lifecycle-operation.json'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $lifecyclePath) | Out-Null
$status = [ordered]@{schemaVersion=1;status='running';action=$Action;projectRoot=$ProjectRoot;pid=$PID;stage='reexec';stageDetail='fresh helper started';userReport='preserve-me'}
[IO.File]::WriteAllText($RunStatusPath,(($status|ConvertTo-Json -Depth 8)+[Environment]::NewLine),$utf8)
$now = Get-Date
$lifecycle = [ordered]@{schemaVersion=1;status='succeeded';operationId=$operationId;action=$Action;projectRoot=$ProjectRoot;pid=$PID;startedAt=$now.ToString('o');phase='complete';detail='Lifecycle operation completed.';exitCode=0;errorCode='';errorMessage='';finishedAt=$now.ToString('o')}
[IO.File]::WriteAllText($lifecyclePath,(($lifecycle|ConvertTo-Json -Depth 8)+[Environment]::NewLine),$utf8)
exit 0
'@
            Push-Location $tempRoot
            try {
                $processResult = Invoke-TestPowerShellFile -FilePath (Join-Path $scriptRoot "run-itl-command.ps1") -Arguments @("--","-Action","refresh-dev-branch")
            } finally { Pop-Location }
            $processResult.exitCode | Should -Be 0
            $summary = ($processResult.stdout -join "`n") | ConvertFrom-Json
            $summary.status | Should -Be "succeeded"
            $summary.stage | Should -Be "complete"
            $summary.userReport | Should -BeExactly "preserve-me"
            $terminalStatus = Get-Content -LiteralPath $summary.statusPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $terminalStatus.status | Should -Be "succeeded"
            [int]$terminalStatus.exitCode | Should -Be 0
            $terminalStatus.stage | Should -Be "complete"
            $terminalLifecycle = Get-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\locks\lifecycle-operation.json") -Raw -Encoding UTF8 | ConvertFrom-Json
            $terminalLifecycle.status | Should -Be "succeeded"
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "fails closed when the helper exits successfully without any terminal status" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-compact-no-status-" + [guid]::NewGuid().ToString("N"))
        try {
            $scriptRoot = Join-Path $tempRoot ".agents\skills\1c-workflow\scripts"
            New-Item -ItemType Directory -Force -Path $scriptRoot | Out-Null
            Copy-RunnerFixture -Destination (Join-Path $scriptRoot "run-itl-command.ps1")
            Set-Content -LiteralPath (Join-Path $scriptRoot "agent-1c.ps1") -Encoding UTF8 -Value @'
param([string]$ProjectRoot,[string]$RunStatusPath,[string]$RunLogPath,[string]$Action)
$utf8 = New-Object Text.UTF8Encoding $false
$lifecyclePath = Join-Path $ProjectRoot '.agent-1c\locks\lifecycle-operation.json'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $lifecyclePath) | Out-Null
$old = (Get-Date).AddHours(-1)
$stale = [ordered]@{schemaVersion=1;status='succeeded';operationId=([guid]::NewGuid().ToString('N'));action=$Action;projectRoot=$ProjectRoot;pid=$PID;startedAt=$old.ToString('o');phase='complete';detail='stale terminal lifecycle';exitCode=0;finishedAt=$old.AddMinutes(1).ToString('o')}
[IO.File]::WriteAllText($lifecyclePath,(($stale|ConvertTo-Json -Depth 8)+[Environment]::NewLine),$utf8)
Write-Output 'helper exited without status'
exit 0
'@
            Push-Location $tempRoot
            try {
                $processResult = Invoke-TestPowerShellFile -FilePath (Join-Path $scriptRoot "run-itl-command.ps1") -Arguments @("--", "-Action", "refresh-dev-branch")
            } finally { Pop-Location }
            $processResult.exitCode | Should -Be 1; $output = $processResult.stdout
            $summary = ($output -join "`n") | ConvertFrom-Json
            $summary.status | Should -Be "failed"
            $summary.stage | Should -Be "runner.helper-exited"
            $summary.error | Should -Match "exited with code 0 before writing a terminal status"
            $status = Get-Content -LiteralPath $summary.statusPath -Raw -Encoding UTF8 | ConvertFrom-Json
            [int]$status.exitCode | Should -Be 1
            $status.finishedAt | Should -Not -BeNullOrEmpty
            # No status was published: the runner still owns the actual helper identity.
            $lifecycle = Get-Content -LiteralPath (Join-Path $tempRoot ".agent-1c/locks/lifecycle-operation.json") -Raw | ConvertFrom-Json
            [int]$status.pid | Should -BeGreaterThan 0
            [int]$status.pid | Should -Be ([int]$lifecycle.pid)
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'compact runner heartbeat handoff snapshot' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $context.RepoRoot '.agents/skills/1c-workflow/scripts/run-itl-command.ps1'), [ref]$tokens, [ref]$errors)
        foreach ($name in @('Get-ObjectValue', 'Read-JsonFile', 'Get-RunnerHeartbeatAgeSeconds', 'Get-RunStatusFreshness', 'Get-RunnerLivenessSnapshot')) {
            $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
            if ($null -eq $definition) { throw "Missing runner function: $name" }
            . ([scriptblock]::Create($definition.Extent.Text))
        }
    }

    It 'reads the new main status when publication and sidecar removal finish before heartbeat sampling' {
        $path = Join-Path $TestDrive 'передача статуса с пробелом.json'
        [IO.File]::WriteAllText($path, ('{"pid":' + $PID + ',"status":"running","stage":"check.event-log","updatedAt":"2000-01-01T00:00:00Z"}'))
        Mock Get-RunnerHeartbeatAgeSeconds {
            $record = [IO.File]::ReadAllText($StatusPath) | ConvertFrom-Json
            $record.updatedAt = [DateTimeOffset]::UtcNow.ToString('o')
            [IO.File]::WriteAllText($StatusPath, ($record | ConvertTo-Json))
            return [double]::PositiveInfinity
        }
        $snapshot = Get-RunnerLivenessSnapshot -StatusPath $path -HelperProcessId $PID -NotBeforeUtc ([DateTime]::UtcNow.AddMinutes(-1))
        $snapshot.ownedStatus | Should -BeTrue
        $snapshot.livenessAgeSeconds | Should -BeLessThan 2
        $snapshot.freshness.source | Should -Be 'updatedAt'
    }

    It 'keeps the previously sampled heartbeat when the main read precedes publication' {
        $script:snapshotReads = [Collections.Generic.List[string]]::new()
        Mock Get-RunnerHeartbeatAgeSeconds { $script:snapshotReads.Add('heartbeat'); return 0 }
        Mock Read-JsonFile { $script:snapshotReads.Add('status'); return [pscustomobject]@{ pid = $PID; updatedAt = '2000-01-01T00:00:00Z'; status = 'running' } }
        $snapshot = Get-RunnerLivenessSnapshot -StatusPath 'unused.json' -HelperProcessId $PID -NotBeforeUtc ([DateTime]::UtcNow)
        ($script:snapshotReads -join ',') | Should -Be 'heartbeat,status'
        $snapshot.statusAgeSeconds | Should -BeGreaterThan 120
        $snapshot.livenessAgeSeconds | Should -Be 0
    }

    It 'rejects a fresh foreign sidecar as proof that a stale helper is live' {
        $path = Join-Path $TestDrive 'чужой heartbeat.json'
        [IO.File]::WriteAllText($path, ('{"pid":' + $PID + ',"updatedAt":"2000-01-01T00:00:00Z"}'))
        [IO.File]::WriteAllText(($path + '.heartbeat'), '99999999')
        $snapshot = Get-RunnerLivenessSnapshot -StatusPath $path -HelperProcessId $PID -NotBeforeUtc ([DateTime]::UtcNow.AddMinutes(-1))
        $snapshot.livenessAgeSeconds | Should -BeGreaterThan 120
        [double]::IsPositiveInfinity($snapshot.heartbeatAgeSeconds) | Should -BeTrue
    }
}
