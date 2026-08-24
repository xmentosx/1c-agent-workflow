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

function Get-ProjectSetting {
    param([string]$ProjectRoot, [string]$Name)

    $dotEnvPath = Join-Path $ProjectRoot ".dev.env"
    if (Test-Path -LiteralPath $dotEnvPath -PathType Leaf) {
        foreach ($line in @(Get-Content -LiteralPath $dotEnvPath -Encoding UTF8 -ErrorAction SilentlyContinue)) {
            if ([string]$line -notmatch ("^\s*" + [regex]::Escape($Name) + "\s*=\s*(.*?)\s*$")) { continue }
            $value = [string]$Matches[1]
            if ($value.Length -ge 2 -and (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'")))) {
                $value = $value.Substring(1, $value.Length - 2)
            }
            return $value
        }
    }
    return [string]([Environment]::GetEnvironmentVariable($Name, "Process"))
}

function Resolve-ItlResponseStyle {
    param([string]$ProjectRoot)

    $mode = (Get-ProjectSetting -ProjectRoot $ProjectRoot -Name "CAVEMAN").Trim().ToLowerInvariant()
    if ($mode -notin @("on", "auto", "off")) { $mode = "on" }
    $level = (Get-ProjectSetting -ProjectRoot $ProjectRoot -Name "CAVEMAN_LEVEL").Trim().ToLowerInvariant()
    if ($level -notin @("lite", "full", "ultra")) { $level = "full" }
    $active = $mode -in @("on", "auto")
    return [ordered]@{
        mode = $mode
        level = $level
        active = $active
        profile = $(if ($active) { "caveman-$level" } else { "normal" })
        taskClass = "execution"
    }
}

function Resolve-UpdateWorkflowProjectRoot {
    param(
        [string]$InvocationRoot,
        [string]$Action
    )

    if ($Action -ne "update-workflow") { return $InvocationRoot }

    $branchOutput = @(& git -C $InvocationRoot branch --show-current 2>&1)
    if ($LASTEXITCODE -ne 0) { return $InvocationRoot }
    $currentBranch = ([string]($branchOutput -join "")).Trim()
    if ($currentBranch -notlike "itldev/*") { return $InvocationRoot }

    $worktreeOutput = @(& git -c core.quotepath=false -C $InvocationRoot worktree list --porcelain 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Cannot resolve the master worktree for update-workflow from development branch '$currentBranch'."
    }

    $masterWorktrees = [System.Collections.Generic.List[string]]::new()
    $currentPath = ""
    $currentWorktreeBranch = ""
    foreach ($lineValue in @($worktreeOutput) + @("")) {
        $line = [string]$lineValue
        if (-not $line) {
            if ($currentPath -and $currentWorktreeBranch -eq "master") {
                $masterWorktrees.Add($currentPath)
            }
            $currentPath = ""
            $currentWorktreeBranch = ""
            continue
        }
        if ($line.StartsWith("worktree ", [System.StringComparison]::Ordinal)) {
            $currentPath = $line.Substring("worktree ".Length)
        } elseif ($line.StartsWith("branch refs/heads/", [System.StringComparison]::Ordinal)) {
            $currentWorktreeBranch = $line.Substring("branch refs/heads/".Length)
        }
    }

    if ($masterWorktrees.Count -ne 1) {
        throw "update-workflow from development branch '$currentBranch' requires exactly one checked-out master worktree; found $($masterWorktrees.Count)."
    }
    $masterRoot = Resolve-NormalizedPath -Path $masterWorktrees[0]
    if (-not (Test-Path -LiteralPath (Join-Path $masterRoot ".git") -ErrorAction SilentlyContinue)) {
        throw "Resolved master worktree is not an initialized Git worktree: $masterRoot"
    }

    [Console]::Error.WriteLine("ITL update-workflow target: branch=$currentBranch; masterWorktree=$masterRoot")
    return $masterRoot
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
    param(
        [string]$Path,
        [object]$Record,
        [int]$ExitCode,
        [string]$Message,
        [string]$Phase = "runner.helper-exited",
        [string]$ErrorCode = "LIFECYCLE_OPERATION_HELPER_EXITED"
    )
    $now = (Get-Date).ToString("o")
    Set-ObjectValue -Object $Record -Name "status" -Value "failed"
    Set-ObjectValue -Object $Record -Name "updatedAt" -Value $now
    Set-ObjectValue -Object $Record -Name "finishedAt" -Value $now
    Set-ObjectValue -Object $Record -Name "phase" -Value $Phase
    Set-ObjectValue -Object $Record -Name "detail" -Value $Message
    Set-ObjectValue -Object $Record -Name "exitCode" -Value $ExitCode
    Set-ObjectValue -Object $Record -Name "errorCode" -Value $ErrorCode
    Set-ObjectValue -Object $Record -Name "errorMessage" -Value $Message
    Write-JsonFileAtomic -Path $Path -Value $Record
}

function Get-PositiveRunnerSetting {
    param([string]$Name, [int]$Default)

    $raw = [string][Environment]::GetEnvironmentVariable($Name, "Process")
    if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
    [int]$parsed = 0
    if (-not [int]::TryParse($raw, [ref]$parsed) -or $parsed -lt 1) {
        throw "$Name must be a positive integer; actual='$raw'."
    }
    return $parsed
}

function Get-RunStatusFreshness {
    param(
        [object]$Status,
        [string]$Path,
        [DateTime]$NotBeforeUtc = [DateTime]::MinValue
    )

    $nowUtc = [DateTimeOffset]::UtcNow
    $updatedAtText = [string](Get-ObjectValue -Object $Status -Name "updatedAt" -Default "")
    [DateTimeOffset]$updatedAt = [DateTimeOffset]::MinValue
    if ($updatedAtText -and [DateTimeOffset]::TryParse($updatedAtText, [ref]$updatedAt)) {
        $age = ($nowUtc - $updatedAt.ToUniversalTime()).TotalSeconds
        if ($age -ge -5) {
            $boundedAge = [Math]::Min([double][int]::MaxValue, [Math]::Max([double]0, [double]$age))
            return [pscustomobject]@{ ageSeconds = $boundedAge; source = "updatedAt"; updatedAt = $updatedAtText }
        }
    }

    $file = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($null -ne $file) {
        # Atomic replacement can expose a transient Windows epoch timestamp.
        # A run-specific status file cannot legitimately predate this runner.
        if ($NotBeforeUtc -ne [DateTime]::MinValue -and $file.LastWriteTimeUtc -lt $NotBeforeUtc) {
            return [pscustomobject]@{ ageSeconds = 0; source = "file-last-write-invalid"; updatedAt = $updatedAtText }
        }
        $age = ([DateTime]::UtcNow - $file.LastWriteTimeUtc).TotalSeconds
        $boundedAge = [Math]::Min([double][int]::MaxValue, [Math]::Max([double]0, [double]$age))
        return [pscustomobject]@{ ageSeconds = $boundedAge; source = "file-last-write"; updatedAt = $updatedAtText }
    }
    return [pscustomobject]@{ ageSeconds = 0; source = "unavailable"; updatedAt = $updatedAtText }
}

function Stop-RunnerOwnedProcessTree {
    param([Parameter(Mandatory = $true)][System.Diagnostics.Process]$Process)

    $errors = [System.Collections.Generic.List[string]]::new()
    try { $Process.Refresh() } catch {}
    if ($Process.HasExited) {
        return [pscustomobject]@{ confirmed = $true; error = "" }
    }
    try {
        & taskkill.exe /PID ([string]$Process.Id) /T /F *> $null
    } catch {
        $errors.Add($_.Exception.Message) | Out-Null
    }
    try { $Process.WaitForExit(10000) | Out-Null } catch { $errors.Add($_.Exception.Message) | Out-Null }
    try { $Process.Refresh() } catch {}
    if (-not $Process.HasExited) {
        try {
            Stop-Process -Id $Process.Id -Force -ErrorAction Stop
            $Process.WaitForExit(10000) | Out-Null
        } catch {
            $errors.Add($_.Exception.Message) | Out-Null
        }
    }
    try { $Process.Refresh() } catch {}
    return [pscustomobject]@{
        confirmed = [bool]$Process.HasExited
        error = ($errors -join "; ")
    }
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
    "begin-verification-repair", "init-dev-branch-extension", "update-dev-branch-base", "verify-dev-branch",
    "refresh-dev-branch", "refresh-dev-branch-lite", "refresh-all-dev-branches", "reset-dev-branch", "lock-config-repository-objects", "sync-master", "export-dev-branch-result", "update-workflow",
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

$invocationRoot = [System.IO.Path]::GetFullPath((Get-Location).Path)
$responseStyle = Resolve-ItlResponseStyle -ProjectRoot $invocationRoot
[Console]::Error.WriteLine("ITL response-style: mode=$($responseStyle.mode); level=$($responseStyle.level); active=$(([string]$responseStyle.active).ToLowerInvariant()); profile=$($responseStyle.profile); task=execution")
$projectRoot = Resolve-UpdateWorkflowProjectRoot -InvocationRoot $invocationRoot -Action $action
$runsRoot = Join-Path $projectRoot ".agent-1c\runs"
New-Item -ItemType Directory -Force -Path $runsRoot | Out-Null
$startedAt = Get-Date
$exitCode = 1
$runDirectory = ""
$statusPath = ""
$logPath = ""
$runnerFailureMessage = ""
$runnerFailureNoProgressSeconds = 0

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
    $staleWarningSeconds = Get-PositiveRunnerSetting -Name "ITL_RUNNER_STATUS_STALE_WARNING_SECONDS" -Default 45
    $staleTimeoutSeconds = Get-PositiveRunnerSetting -Name "ITL_RUNNER_STATUS_STALE_TIMEOUT_SECONDS" -Default 120
    if ($staleTimeoutSeconds -le $staleWarningSeconds) {
        throw "ITL_RUNNER_STATUS_STALE_TIMEOUT_SECONDS must be greater than ITL_RUNNER_STATUS_STALE_WARNING_SECONDS."
    }
    $originalPowerShellModulePath = $env:PSModulePath
    $resetModulePathForWindowsPowerShell = [string]$PSVersionTable.PSEdition -eq "Core"
    try {
        # Start-Process preserves PowerShell Core's module path verbatim. Remove
        # only the Core runtime module root before launching Windows PowerShell
        # so its built-in modules (including Get-FileHash) can autoload.
        if ($resetModulePathForWindowsPowerShell) {
            $coreModuleRoot = [IO.Path]::GetFullPath((Join-Path $PSHOME "Modules")).TrimEnd('\')
            $compatibleModuleRoots = @($originalPowerShellModulePath -split ';' | Where-Object {
                if ([string]::IsNullOrWhiteSpace($_)) { return $false }
                try { return -not [string]::Equals([IO.Path]::GetFullPath($_).TrimEnd('\'), $coreModuleRoot, [StringComparison]::OrdinalIgnoreCase) }
                catch { return $true }
            })
            $env:PSModulePath = $compatibleModuleRoots -join ';'
        }
        $helperProcess = Start-Process `
            -FilePath "powershell" `
            -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-EncodedCommand", $encodedCommand) `
            -WorkingDirectory $projectRoot `
            -WindowStyle Hidden `
            -PassThru
    } finally {
        if ($resetModulePathForWindowsPowerShell) {
            if ($null -eq $originalPowerShellModulePath) { Remove-Item Env:PSModulePath -ErrorAction SilentlyContinue }
            else { $env:PSModulePath = $originalPowerShellModulePath }
        }
    }
    if ($null -eq $helperProcess) {
        throw "Failed to start compact ITL helper: $helperPath"
    }
    $lastProgressStage = ""
    $lastProgressLiveness = ""
    $lastProgressAt = [DateTime]::MinValue
    while (-not $helperProcess.HasExited) {
        $currentStatus = Read-JsonFile -Path $statusPath
        $currentStage = [string](Get-ObjectValue -Object $currentStatus -Name "stage" -Default "")
        $publishedLiveness = [string](Get-ObjectValue -Object $currentStatus -Name "liveness" -Default "")
        $freshness = Get-RunStatusFreshness -Status $currentStatus -Path $statusPath -NotBeforeUtc ($startedAt.ToUniversalTime().AddSeconds(-5))
        $statusAgeSeconds = [int][Math]::Floor([double]$freshness.ageSeconds)
        $publishedStallRemainingSeconds = [int](Get-ObjectValue -Object $currentStatus -Name "stallTimeoutRemainingSeconds" -Default 0)
        # The helper owns the operation-specific stall budget. A generic runner
        # watchdog must not preempt a live Designer probe before that budget can
        # expire and publish its own terminal diagnosis.
        $effectiveStaleTimeoutSeconds = if ($publishedStallRemainingSeconds -gt 0) {
            [Math]::Max($staleTimeoutSeconds, $publishedStallRemainingSeconds + $staleWarningSeconds)
        } else {
            $staleTimeoutSeconds
        }
        $staleStatus = $publishedLiveness -and $statusAgeSeconds -ge $staleWarningSeconds
        $displayLiveness = if ($staleStatus) { "stale-status" } else { $publishedLiveness }
        $stageChanged = $currentStage -and $currentStage -ne $lastProgressStage
        $livenessChanged = $currentStage -and $displayLiveness -ne $lastProgressLiveness
        $heartbeatDue = $currentStage -and ([DateTime]::UtcNow - $lastProgressAt).TotalSeconds -ge 30
        if ($stageChanged -or $livenessChanged -or $heartbeatDue) {
            $lastProgressStage = $currentStage
            $lastProgressLiveness = $displayLiveness
            $lastProgressAt = [DateTime]::UtcNow
            $elapsed = [int][Math]::Floor(((Get-Date) - $startedAt).TotalSeconds)
            $detail = Limit-Text -Value (Get-ObjectValue -Object $currentStatus -Name "stageDetail" -Default "") -Length 300
            $publishedNoProgressSeconds = [int](Get-ObjectValue -Object $currentStatus -Name "noProgressSeconds" -Default 0)
            $publishedTimeoutRemainingSeconds = [int](Get-ObjectValue -Object $currentStatus -Name "timeoutRemainingSeconds" -Default 0)
            $noProgressSeconds = if ($staleStatus) { $publishedNoProgressSeconds + $statusAgeSeconds } else { $publishedNoProgressSeconds }
            $stallRemainingSeconds = if ($staleStatus) { [Math]::Max(0, $publishedStallRemainingSeconds - $statusAgeSeconds) } else { $publishedStallRemainingSeconds }
            $timeoutRemainingSeconds = if ($staleStatus) { [Math]::Max(0, $publishedTimeoutRemainingSeconds - $statusAgeSeconds) } else { $publishedTimeoutRemainingSeconds }
            $freshnessDetail = if ($staleStatus) { "statusAge=${statusAgeSeconds}s; freshnessSource=$($freshness.source); publishedLiveness=$publishedLiveness; " } else { "" }
            [Console]::Error.WriteLine("ITL progress: stage=$currentStage; elapsed=${elapsed}s; liveness=$displayLiveness; noProgress=${noProgressSeconds}s; stallTimeoutRemaining=${stallRemainingSeconds}s; timeoutRemaining=${timeoutRemainingSeconds}s; ${freshnessDetail}detail=$detail")
        }
        if ($publishedLiveness -and $statusAgeSeconds -ge $effectiveStaleTimeoutSeconds) {
            $runnerFailureNoProgressSeconds = [int](Get-ObjectValue -Object $currentStatus -Name "noProgressSeconds" -Default 0) + $statusAgeSeconds
            $updatedAt = [string]$freshness.updatedAt
            $runnerFailureMessage = "RUNNER_STATUS_STALE status.json was not updated for ${statusAgeSeconds}s (effective watchdog ${effectiveStaleTimeoutSeconds}s) while helper PID $($helperProcess.Id) reported liveness '$publishedLiveness' at stage '$currentStage' (updatedAt='$updatedAt'). The runner stopped only its helper process tree."
            $termination = Stop-RunnerOwnedProcessTree -Process $helperProcess
            if (-not $termination.confirmed) {
                throw "$runnerFailureMessage Helper process tree termination was not confirmed: $($termination.error)"
            }
            break
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
    $message = if ($runnerFailureMessage) { $runnerFailureMessage } else { "ITL helper exited with code $exitCode before writing a terminal status. Log: $logPath" }
    $runnerStage = if ($runnerFailureMessage) { "runner.status-stale" } else { "runner.helper-exited" }
    $runnerErrorCode = if ($runnerFailureMessage) { "LIFECYCLE_OPERATION_STATUS_STALE" } else { "LIFECYCLE_OPERATION_HELPER_EXITED" }
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
            Complete-RunnerOwnedLifecycleRecord -Path $lifecyclePath -Record $lifecycleRecord -ExitCode $effectiveExitCode -Message $message -Phase $runnerStage -ErrorCode $runnerErrorCode
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
    Set-ObjectValue -Object $status -Name "errorCode" -Value $runnerErrorCode
    Set-ObjectValue -Object $status -Name "errorCategory" -Value "runner"
    Set-ObjectValue -Object $status -Name "requiredAction" -Value ""
    Set-ObjectValue -Object $status -Name "stage" -Value $runnerStage
    Set-ObjectValue -Object $status -Name "stageDetail" -Value $detail
    if ($runnerFailureMessage) {
        Set-ObjectValue -Object $status -Name "liveness" -Value "failed-stale-status"
        Set-ObjectValue -Object $status -Name "noProgressSeconds" -Value $runnerFailureNoProgressSeconds
        Set-ObjectValue -Object $status -Name "stallTimeoutRemainingSeconds" -Value 0
        Set-ObjectValue -Object $status -Name "timeoutRemainingSeconds" -Value 0
    }
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
$nextAction = if ($exitCode -eq 0 -and $requiredAction) {
    $requiredAction
} elseif ($exitCode -eq 0) {
    "none"
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
    responseStyle = $responseStyle
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
