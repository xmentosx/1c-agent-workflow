Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$utf8 = New-Object System.Text.UTF8Encoding $false
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8

$windowed = $false
$helperArgs = [System.Collections.Generic.List[string]]::new()
$afterSeparator = $false
foreach ($argument in @($args)) {
    $text = [string]$argument
    if (-not $afterSeparator -and $text -eq "-Windowed") {
        $windowed = $true
        continue
    }
    if (-not $afterSeparator -and $text -eq "--") {
        $afterSeparator = $true
        continue
    }
    $helperArgs.Add($text)
}

function Get-ArgumentValue {
    param([string[]]$Arguments, [string]$Name)
    for ($index = 0; $index -lt $Arguments.Count; $index++) {
        if ([string]$Arguments[$index] -ieq $Name) {
            if (($index + 1) -ge $Arguments.Count) { throw "Missing value for $Name." }
            return [string]$Arguments[$index + 1]
        }
    }
    return ""
}

function Limit-Text {
    param([AllowNull()][object]$Value, [int]$Length)
    $text = if ($null -eq $Value) { "" } else { [string]$Value }
    if ($text.Length -le $Length) { return $text }
    return $text.Substring(0, [Math]::Max(0, $Length - 3)) + "..."
}

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Write-JsonFileAtomic {
    param([string]$Path, [object]$Value)
    $temporary = "$Path.tmp-$PID-$([guid]::NewGuid().ToString('N'))"
    [System.IO.File]::WriteAllText($temporary, (($Value | ConvertTo-Json -Depth 10) + [Environment]::NewLine), $utf8)
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Resolve-NormalizedPath {
    param([AllowNull()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
    return [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
}

function Test-SamePath {
    param([string]$First, [string]$Second)
    if (-not $First -or -not $Second) { return $false }
    return [string]::Equals(
        (Resolve-NormalizedPath -Path $First),
        (Resolve-NormalizedPath -Path $Second),
        [System.StringComparison]::OrdinalIgnoreCase
    )
}

function ConvertTo-PowerShellLiteral {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) { return '$null' }
    return "'" + $Value.Replace("'", "''") + "'"
}

function ConvertTo-PowerShellArgumentToken {
    param([AllowNull()][string]$Value)
    if ($Value -and $Value -match '^-[A-Za-z][A-Za-z0-9-]*$') { return $Value }
    return (ConvertTo-PowerShellLiteral -Value $Value)
}

function Get-ObjectValue {
    param([object]$Object, [string]$Name, [object]$Default = $null)
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    return $property.Value
}

function Set-ObjectValue {
    param(
        [object]$Object,
        [string]$Name,
        [AllowNull()][object]$Value
    )
    $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
}

function Get-RunnerOwnedLifecycleRecord {
    param(
        [string]$Path,
        [int]$HelperProcessId,
        [string]$Action,
        [string]$ProjectRoot
    )
    $record = Read-JsonFile -Path $Path
    if ($null -eq $record -or [string](Get-ObjectValue -Object $record -Name "status" -Default "") -ne "running" -or
        [int](Get-ObjectValue -Object $record -Name "pid" -Default 0) -ne $HelperProcessId -or
        [string](Get-ObjectValue -Object $record -Name "action" -Default "") -ne $Action -or
        -not (Test-SamePath -First ([string](Get-ObjectValue -Object $record -Name "projectRoot" -Default "")) -Second $ProjectRoot)) {
        return $null
    }
    return $record
}

function Get-InterruptedVanessaRunEvidence {
    param(
        [object]$LifecycleRecord,
        [object]$RunStatus,
        [int]$HelperProcessId,
        [string]$ProjectRoot
    )
    $evidence = Get-ObjectValue -Object $LifecycleRecord -Name "activeVanessaRun" -Default $null
    if ($null -eq $evidence) { return [pscustomobject]@{ present = $false; valid = $false; reason = ""; evidence = $null } }
    $operationId = [string](Get-ObjectValue -Object $LifecycleRecord -Name "operationId" -Default "")
    $continuationPid = [int](Get-ObjectValue -Object $LifecycleRecord -Name "continuationPid" -Default 0)
    $expectedProcessId = if ($continuationPid -gt 0) { $continuationPid } else { $HelperProcessId }
    $ports = @((Get-ObjectValue -Object $evidence -Name "testPorts" -Default @()) | ForEach-Object { [int]$_ } | Select-Object -Unique)
    $paramsPath = [string](Get-ObjectValue -Object $evidence -Name "runParamsPath" -Default "")
    $projectPrefix = (Resolve-NormalizedPath -Path $ProjectRoot) + [System.IO.Path]::DirectorySeparatorChar
    $resolvedParamsPath = Resolve-NormalizedPath -Path $paramsPath
    $reason = ""
    if ([int](Get-ObjectValue -Object $evidence -Name "schemaVersion" -Default 0) -ne 1 -or
        [string](Get-ObjectValue -Object $evidence -Name "operationId" -Default "") -cne $operationId -or
        [int](Get-ObjectValue -Object $evidence -Name "ownerPid" -Default 0) -ne $HelperProcessId -or
        [int](Get-ObjectValue -Object $evidence -Name "processId" -Default 0) -ne $expectedProcessId -or
        -not (Test-SamePath -First ([string](Get-ObjectValue -Object $evidence -Name "projectRoot" -Default "")) -Second $ProjectRoot) -or
        -not $resolvedParamsPath.StartsWith($projectPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-Path -LiteralPath $resolvedParamsPath -PathType Leaf) -or
        -not [string](Get-ObjectValue -Object $evidence -Name "infoBasePath" -Default "") -or
        $ports.Count -eq 0 -or @($ports | Where-Object { $_ -le 0 -or $_ -gt 65535 }).Count -gt 0) {
        $reason = "exact lifecycle Vanessa evidence is incomplete or inconsistent"
    }
    $statusEvidence = Get-ObjectValue -Object $RunStatus -Name "activeVanessaRun" -Default $null
    if (-not $reason -and $null -ne $statusEvidence -and
        [string](Get-ObjectValue -Object $statusEvidence -Name "operationId" -Default "") -cne $operationId) {
        $reason = "run status and lifecycle operation identify different Vanessa runs"
    }
    return [pscustomobject]@{ present = $true; valid = -not [bool]$reason; reason = $reason; evidence = $evidence; ports = @($ports) }
}

function Invoke-InterruptedVanessaRunRecovery {
    param(
        [string]$HelperPath,
        [string]$ProjectRoot,
        [object]$EvidenceResult,
        [string]$LogPath
    )
    $evidence = $EvidenceResult.evidence
    $recoveryArguments = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $HelperPath,
        "-ProjectRoot", $ProjectRoot,
        "-Action", "cleanup-interrupted-vanessa-run",
        "-InterruptedVanessaInfoBasePath", ([string]$evidence.infoBasePath),
        "-InterruptedVanessaRunParamsPath", ([string]$evidence.runParamsPath),
        "-InterruptedVanessaTestPorts", (@($EvidenceResult.ports) -join ',')
    )
    $output = @(& powershell @recoveryArguments 2>&1)
    $recoveryExitCode = if ($LASTEXITCODE -is [int]) { [int]$LASTEXITCODE } else { 1 }
    if ($output.Count -gt 0) {
        [System.IO.File]::AppendAllText(
            $LogPath,
            ([Environment]::NewLine + "[runner interrupted Vanessa cleanup]" + [Environment]::NewLine + ($output -join [Environment]::NewLine) + [Environment]::NewLine),
            $utf8
        )
    }
    return [pscustomobject]@{ succeeded = $recoveryExitCode -eq 0; exitCode = $recoveryExitCode }
}

function Complete-RunnerOwnedLifecycleRecord {
    param([string]$Path, [object]$Record, [int]$ExitCode, [string]$Message)
    $now = (Get-Date).ToString("o")
    Set-ObjectValue -Object $Record -Name "status" -Value "failed"
    Set-ObjectValue -Object $Record -Name "updatedAt" -Value $now
    Set-ObjectValue -Object $Record -Name "finishedAt" -Value $now
    Set-ObjectValue -Object $Record -Name "phase" -Value "runner.helper-exited"
    Set-ObjectValue -Object $Record -Name "detail" -Value $Message
    Set-ObjectValue -Object $Record -Name "exitCode" -Value $ExitCode
    Set-ObjectValue -Object $Record -Name "errorCode" -Value "LIFECYCLE_OPERATION_HELPER_EXITED"
    Set-ObjectValue -Object $Record -Name "errorMessage" -Value $Message
    Write-JsonFileAtomic -Path $Path -Value $Record
}

function Find-LauncherRunDirectory {
    param([object[]]$Output, [datetime]$StartedAt, [string]$RunsRoot)
    foreach ($line in @($Output)) {
        if ([string]$line -match '^Run directory:\s*(.+?)\s*$') {
            $candidate = [string]$Matches[1]
            if (Test-Path -LiteralPath $candidate -PathType Container) { return $candidate }
        }
    }
    $candidate = @(Get-ChildItem -LiteralPath $RunsRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.CreationTime -ge $StartedAt.AddSeconds(-2) } |
        Sort-Object CreationTime -Descending |
        Select-Object -First 1)
    if ($candidate.Count -gt 0) { return [string]$candidate[0].FullName }
    return ""
}

$allowedActions = @(
    "new-dev-branch", "new-extension-dev-branch", "adopt-dev-worktree", "close-dev-branch", "check-dev-branch",
    "init-dev-branch-extension", "update-dev-branch-base", "verify-dev-branch",
    "refresh-dev-branch", "refresh-dev-branch-lite", "sync-master", "export-dev-branch-result", "update-workflow",
    "itl-switch-client"
)
$action = Get-ArgumentValue -Arguments @($helperArgs) -Name "-Action"
if ($action -notin $allowedActions) {
    throw "run-itl-command.ps1 accepts only compact ITL actions: $($allowedActions -join ', ')."
}
foreach ($reserved in @("-RunStatusPath", "-RunLogPath", "-ProjectRoot")) {
    if (@($helperArgs | Where-Object { [string]$_ -ieq $reserved }).Count -gt 0) {
        throw "$reserved is owned by run-itl-command.ps1 and cannot be passed through."
    }
}
$branchActions = @("new-dev-branch", "new-extension-dev-branch", "adopt-dev-worktree", "close-dev-branch")
if ($windowed -ne ($action -in $branchActions)) {
    throw "Branch creation actions require -Windowed; other compact ITL actions must not use it."
}

$projectRoot = [System.IO.Path]::GetFullPath((Get-Location).Path)
$runsRoot = Join-Path $projectRoot ".agent-1c\runs"
New-Item -ItemType Directory -Force -Path $runsRoot | Out-Null
$startedAt = Get-Date
$exitCode = 1
$runDirectory = ""
$statusPath = ""
$logPath = ""

if ($windowed) {
    $launcherPath = Join-Path $PSScriptRoot "run-agent-1c-window.ps1"
    $launcherOutput = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $launcherPath -- @($helperArgs) 2>&1)
    $exitCode = if ($LASTEXITCODE -is [int]) { [int]$LASTEXITCODE } else { 1 }
    $runDirectory = Find-LauncherRunDirectory -Output $launcherOutput -StartedAt $startedAt -RunsRoot $runsRoot
    if ($runDirectory) {
        $statusPath = Join-Path $runDirectory "status.json"
        $logPath = Join-Path $runDirectory "console.log"
    } else {
        $runDirectory = Join-Path $runsRoot ("compact-{0}-{1}" -f (Get-Date -Format "yyyyMMdd-HHmmss-fff"), ([guid]::NewGuid().ToString("N").Substring(0, 8)))
        New-Item -ItemType Directory -Force -Path $runDirectory | Out-Null
        $statusPath = Join-Path $runDirectory "status.json"
        $logPath = Join-Path $runDirectory "console.log"
        [System.IO.File]::WriteAllText($logPath, ((@($launcherOutput) -join [Environment]::NewLine) + [Environment]::NewLine), $utf8)
    }
} else {
    $runDirectory = Join-Path $runsRoot ("compact-{0}-{1}" -f (Get-Date -Format "yyyyMMdd-HHmmss-fff"), ([guid]::NewGuid().ToString("N").Substring(0, 8)))
    New-Item -ItemType Directory -Force -Path $runDirectory | Out-Null
    $statusPath = Join-Path $runDirectory "status.json"
    $logPath = Join-Path $runDirectory "console.log"
    [System.IO.File]::WriteAllText($logPath, "", $utf8)
    $helperPath = Join-Path $PSScriptRoot "agent-1c.ps1"
    $monitoredArgs = @("-ProjectRoot", $projectRoot, "-RunStatusPath", $statusPath, "-RunLogPath", $logPath) + @($helperArgs)
    $helperInvocation = "& " + (ConvertTo-PowerShellLiteral -Value $helperPath) + " " + ((@($monitoredArgs) | ForEach-Object { ConvertTo-PowerShellArgumentToken -Value ([string]$_) }) -join " ")
    $commandText = @"
`$utf8 = New-Object System.Text.UTF8Encoding `$false
[Console]::InputEncoding = `$utf8
[Console]::OutputEncoding = `$utf8
`$OutputEncoding = `$utf8
`$ProgressPreference = 'SilentlyContinue'
`$ErrorActionPreference = 'Stop'
`$helperExitCode = 1
try {
    $helperInvocation *>&1 | ForEach-Object {
        [IO.File]::AppendAllText($(ConvertTo-PowerShellLiteral -Value $logPath), ([string]`$_ + [Environment]::NewLine), `$utf8)
    }
    `$pipelineSucceeded = `$?
    if (`$LASTEXITCODE -is [int]) { `$helperExitCode = [int]`$LASTEXITCODE }
    elseif (`$pipelineSucceeded) { `$helperExitCode = 0 }
} catch {
    [Console]::Error.WriteLine(`$_.Exception.Message)
    [IO.File]::AppendAllText($(ConvertTo-PowerShellLiteral -Value $logPath), (`$_.Exception.Message + [Environment]::NewLine), `$utf8)
    `$helperExitCode = 1
}
[Environment]::Exit(`$helperExitCode)
"@
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($commandText))
    $helperProcess = Start-Process `
        -FilePath "powershell" `
        -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-EncodedCommand", $encodedCommand) `
        -WorkingDirectory $projectRoot `
        -WindowStyle Hidden `
        -PassThru
    if ($null -eq $helperProcess) {
        throw "Failed to start compact ITL helper: $helperPath"
    }
    $lastProgressStage = ""
    $lastProgressAt = [DateTime]::MinValue
    while (-not $helperProcess.HasExited) {
        $currentStatus = Read-JsonFile -Path $statusPath
        $currentStage = [string](Get-ObjectValue -Object $currentStatus -Name "stage" -Default "")
        $stageChanged = $currentStage -and $currentStage -ne $lastProgressStage
        $heartbeatDue = $currentStage -and ([DateTime]::UtcNow - $lastProgressAt).TotalSeconds -ge 30
        if ($stageChanged -or $heartbeatDue) {
            $lastProgressStage = $currentStage
            $lastProgressAt = [DateTime]::UtcNow
            $elapsed = [int][Math]::Floor(((Get-Date) - $startedAt).TotalSeconds)
            $detail = Limit-Text -Value (Get-ObjectValue -Object $currentStatus -Name "stageDetail" -Default "") -Length 300
            $liveness = [string](Get-ObjectValue -Object $currentStatus -Name "liveness" -Default "")
            $noProgressSeconds = [int](Get-ObjectValue -Object $currentStatus -Name "noProgressSeconds" -Default 0)
            $timeoutRemainingSeconds = [int](Get-ObjectValue -Object $currentStatus -Name "timeoutRemainingSeconds" -Default 0)
            [Console]::Error.WriteLine("ITL progress: stage=$currentStage; elapsed=${elapsed}s; liveness=$liveness; noProgress=${noProgressSeconds}s; timeoutRemaining=${timeoutRemainingSeconds}s; detail=$detail")
        }
        $helperProcess.WaitForExit(500) | Out-Null
    }
    $helperProcess.WaitForExit()
    $exitCode = [int]$helperProcess.ExitCode
}

$status = Read-JsonFile -Path $statusPath
if ([string](Get-ObjectValue -Object $status -Name "status" -Default "") -eq "failed" -and $exitCode -eq 0) { $exitCode = [Math]::Max(1, [int](Get-ObjectValue -Object $status -Name "exitCode" -Default 1)) }
if ($null -eq $status -or [string](Get-ObjectValue -Object $status -Name "status" -Default "") -notin @("succeeded", "failed")) {
    $now = Get-Date
    $effectiveExitCode = if ($exitCode -ne 0) { $exitCode } else { 1 }
    $previousStage = [string](Get-ObjectValue -Object $status -Name "stage" -Default "")
    $message = "ITL helper exited with code $exitCode before writing a terminal status. Log: $logPath"
    if (-not $windowed) {
        $lifecyclePath = Join-Path $projectRoot ".agent-1c\locks\lifecycle-operation.json"
        $lifecycleRecord = Get-RunnerOwnedLifecycleRecord -Path $lifecyclePath -HelperProcessId $helperProcess.Id -Action $action -ProjectRoot $projectRoot
        if ($null -ne $lifecycleRecord) {
            $evidenceResult = Get-InterruptedVanessaRunEvidence -LifecycleRecord $lifecycleRecord -RunStatus $status -HelperProcessId $helperProcess.Id -ProjectRoot $projectRoot
            if ($evidenceResult.present -and $evidenceResult.valid) {
                $recovery = Invoke-InterruptedVanessaRunRecovery -HelperPath $helperPath -ProjectRoot $projectRoot -EvidenceResult $evidenceResult -LogPath $logPath
                $message += if ($recovery.succeeded) {
                    " Exact interrupted Vanessa run cleanup succeeded."
                } else {
                    " Exact interrupted Vanessa run cleanup failed with code $($recovery.exitCode); broad cleanup was not attempted."
                }
            } elseif ($evidenceResult.present) {
                $message += " Interrupted Vanessa cleanup was not attempted because $($evidenceResult.reason); broad cleanup was not attempted."
            }
            Complete-RunnerOwnedLifecycleRecord -Path $lifecyclePath -Record $lifecycleRecord -ExitCode $effectiveExitCode -Message $message
        }
    }
    $detail = if ($previousStage) { "$message Last recorded stage: $previousStage." } else { $message }
    if ($null -eq $status) {
        $status = [pscustomobject][ordered]@{
            schemaVersion = 1
            action = $action
            projectRoot = $projectRoot
            pid = 0
            launcherPid = 0
            startedAt = $startedAt.ToString("o")
            lastLogPath = ""
            runLogPath = $logPath
        }
    }
    Set-ObjectValue -Object $status -Name "schemaVersion" -Value 1
    Set-ObjectValue -Object $status -Name "status" -Value "failed"
    Set-ObjectValue -Object $status -Name "action" -Value $action
    Set-ObjectValue -Object $status -Name "updatedAt" -Value $now.ToString("o")
    Set-ObjectValue -Object $status -Name "finishedAt" -Value $now.ToString("o")
    Set-ObjectValue -Object $status -Name "exitCode" -Value $effectiveExitCode
    Set-ObjectValue -Object $status -Name "runLogPath" -Value $logPath
    Set-ObjectValue -Object $status -Name "errorMessage" -Value $message
    Set-ObjectValue -Object $status -Name "errorCategory" -Value "runner"
    Set-ObjectValue -Object $status -Name "requiredAction" -Value ""
    Set-ObjectValue -Object $status -Name "stage" -Value "runner.helper-exited"
    Set-ObjectValue -Object $status -Name "stageDetail" -Value $detail
    $exitCode = $effectiveExitCode
}
$errorText = Limit-Text -Value (Get-ObjectValue -Object $status -Name "errorMessage" -Default "") -Length 1400
$errorCategory = [string](Get-ObjectValue -Object $status -Name "errorCategory" -Default "")
$requiredAction = [string](Get-ObjectValue -Object $status -Name "requiredAction" -Default "")
$devBranch = [string](Get-ObjectValue -Object $status -Name "devBranch" -Default "")
$worktreePath = [string](Get-ObjectValue -Object $status -Name "worktreePath" -Default "")
$extensionInitializationStatus = [string](Get-ObjectValue -Object $status -Name "extensionInitializationStatus" -Default "")
$userReport = [string](Get-ObjectValue -Object $status -Name "userReport" -Default "")
$resultPath = [string](Get-ObjectValue -Object $status -Name "resultPath" -Default "")
$resultManifestPath = [string](Get-ObjectValue -Object $status -Name "resultManifestPath" -Default "")
$logTail = ""
if ($exitCode -ne 0 -and (Test-Path -LiteralPath $logPath -PathType Leaf)) {
    $logTail = ((Get-Content -LiteralPath $logPath -Tail 80 -Encoding UTF8 -ErrorAction SilentlyContinue) -join [Environment]::NewLine)
}
$confirmationRequired = $false
if ($action -eq "export-dev-branch-result" -and ($errorText + "`n" + $logTail) -match '(?i)AllowUnverifiedResult|unverified|verification.*missing') {
    $confirmationRequired = $true
}
$nextAction = if ($exitCode -eq 0 -and $requiredAction) {
    $requiredAction
} elseif ($exitCode -eq 0) {
    "none"
} elseif ($confirmationRequired) {
    "Ask the developer for explicit confirmation, then rerun with -AllowUnverifiedResult."
} elseif ($requiredAction) {
    $requiredAction
} elseif ($errorCategory -eq "runner") {
    "Read only the last 80 lines of console.log and address the reported runner failure."
} elseif ($errorCategory) {
    "/itl-verify-fix"
} else {
    "Read only the last 80 lines of console.log and address the reported failure."
}
$artifacts = [System.Collections.Generic.List[string]]::new()
foreach ($candidate in @($resultPath, $resultManifestPath, (Get-ObjectValue -Object $status -Name "lastLogPath" -Default ""), $logPath, $statusPath)) {
    if ($candidate -and -not $artifacts.Contains([string]$candidate)) { $artifacts.Add([string]$candidate) }
}

$summary = [ordered]@{
    action = $action
    status = [string]$status.status
    stage = Limit-Text -Value $status.stage -Length 240
    stageDetail = Limit-Text -Value $status.stageDetail -Length 800
    confirmationRequired = $confirmationRequired
    nextAction = $nextAction
    artifacts = @($artifacts)
    error = $errorText
    errorCategory = $errorCategory
    requiredAction = $requiredAction
    devBranch = $devBranch
    worktreePath = $worktreePath
    extensionInitializationStatus = $extensionInitializationStatus
    userReport = $userReport
    resultPath = $resultPath
    resultManifestPath = $resultManifestPath
    liveness = [string](Get-ObjectValue -Object $status -Name "liveness" -Default "")
    noProgressSeconds = [int](Get-ObjectValue -Object $status -Name "noProgressSeconds" -Default 0)
    timeoutRemainingSeconds = [int](Get-ObjectValue -Object $status -Name "timeoutRemainingSeconds" -Default 0)
    ownedProcessIds = @((Get-ObjectValue -Object $status -Name "ownedProcessIds" -Default @()))
    cpuDeltaMilliseconds = [int](Get-ObjectValue -Object $status -Name "cpuDeltaMilliseconds" -Default 0)
    workingSetMb = [int](Get-ObjectValue -Object $status -Name "workingSetMb" -Default 0)
    logGrowthBytes = [int64](Get-ObjectValue -Object $status -Name "logGrowthBytes" -Default 0)
    logPath = $logPath
    statusPath = $statusPath
}

foreach ($property in @($summary.Keys)) {
    $status | Add-Member -NotePropertyName $property -NotePropertyValue $summary[$property] -Force
}
[System.IO.File]::WriteAllText($statusPath, (($status | ConvertTo-Json -Depth 8) + [Environment]::NewLine), $utf8)
$summaryText = $summary | ConvertTo-Json -Depth 8 -Compress
if ($summaryText.Length -gt 4000) {
    $summary.error = Limit-Text -Value $summary.error -Length 400
    $summary.stageDetail = Limit-Text -Value $summary.stageDetail -Length 300
    if ([string]$summary.status -eq "succeeded" -and $summary.userReport) {
        $summary.artifacts = @(
            @($resultPath, $resultManifestPath, $statusPath) |
                Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
                Select-Object -Unique
        )
    }
    $summaryText = $summary | ConvertTo-Json -Depth 8 -Compress
}
if ($summaryText.Length -gt 4000) { throw "Compact ITL summary exceeded 4000 characters." }
Write-Output $summaryText
[Environment]::Exit($exitCode)
