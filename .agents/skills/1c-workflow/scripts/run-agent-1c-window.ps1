Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$utf8 = New-Object System.Text.UTF8Encoding $false
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8

$ProjectRoot = (Get-Location).Path
$HelperPath = ""
$PollIntervalMilliseconds = 1000
$StatusStartTimeoutSeconds = 30
$MaxWaitSeconds = 3600
$KeepWindowOnFailure = $false
$AgentArgs = @()
$GitIndexLockPath = ""
$GitIndexLockPreExisted = $false

function Read-RequiredLauncherValue {
    param(
        [string[]]$Values,
        [int]$Index,
        [string]$Name
    )

    $nextIndex = $Index + 1
    if ($nextIndex -ge $Values.Count) {
        throw "Missing value for launcher parameter: $Name"
    }
    return [pscustomobject]@{
        index = $nextIndex
        value = [string]$Values[$nextIndex]
    }
}

function Normalize-Agent1cFullPathText {
    param([string]$Path)

    if ([string]::IsNullOrEmpty($Path)) {
        return $Path
    }

    $root = [System.IO.Path]::GetPathRoot($Path)
    $trimmed = $Path.TrimEnd("\", "/")
    if ([string]::IsNullOrEmpty($trimmed)) {
        return $Path
    }

    if ($root -and $trimmed -eq $root.TrimEnd("\", "/")) {
        return $root
    }
    return $trimmed
}

function Resolve-Agent1cFullPath {
    param([AllowNull()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }

    $full = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Path))
    if (Test-Path -LiteralPath $full -ErrorAction SilentlyContinue) {
        try {
            return (Normalize-Agent1cFullPathText -Path (Get-Item -LiteralPath $full -ErrorAction Stop).FullName)
        } catch {
        }
    }

    $segments = [System.Collections.Generic.List[string]]::new()
    $current = $full
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        if (Test-Path -LiteralPath $current -ErrorAction SilentlyContinue) {
            try {
                $resolved = (Get-Item -LiteralPath $current -ErrorAction Stop).FullName
                for ($i = $segments.Count - 1; $i -ge 0; $i--) {
                    $resolved = Join-Path $resolved $segments[$i]
                }
                return (Normalize-Agent1cFullPathText -Path $resolved)
            } catch {
            }
        }

        $parent = Split-Path -Parent $current
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $current) {
            break
        }

        $leaf = Split-Path -Leaf $current
        if (-not [string]::IsNullOrEmpty($leaf)) {
            $segments.Add($leaf) | Out-Null
        }
        $current = $parent
    }

    return (Normalize-Agent1cFullPathText -Path $full)
}

$rawArgs = @($args)
:parseArgs for ($i = 0; $i -lt $rawArgs.Count; $i++) {
    $arg = [string]$rawArgs[$i]
    if ($arg -eq "--") {
        if (($i + 1) -lt $rawArgs.Count) {
            $AgentArgs = @($rawArgs[($i + 1)..($rawArgs.Count - 1)])
        }
        break parseArgs
    }

    switch ($arg.ToLowerInvariant()) {
        "-projectroot" {
            $value = Read-RequiredLauncherValue -Values $rawArgs -Index $i -Name $arg
            $ProjectRoot = $value.value
            $i = $value.index
            continue
        }
        "-helperpath" {
            $value = Read-RequiredLauncherValue -Values $rawArgs -Index $i -Name $arg
            $HelperPath = $value.value
            $i = $value.index
            continue
        }
        "-pollintervalmilliseconds" {
            $value = Read-RequiredLauncherValue -Values $rawArgs -Index $i -Name $arg
            $PollIntervalMilliseconds = [int]$value.value
            $i = $value.index
            continue
        }
        "-statusstarttimeoutseconds" {
            $value = Read-RequiredLauncherValue -Values $rawArgs -Index $i -Name $arg
            $StatusStartTimeoutSeconds = [int]$value.value
            $i = $value.index
            continue
        }
        "-maxwaitseconds" {
            $value = Read-RequiredLauncherValue -Values $rawArgs -Index $i -Name $arg
            $MaxWaitSeconds = [int]$value.value
            $i = $value.index
            continue
        }
        "-keepwindowonfailure" {
            $KeepWindowOnFailure = $true
            continue
        }
        default {
            $AgentArgs = @($rawArgs[$i..($rawArgs.Count - 1)])
            break parseArgs
        }
    }
}

function ConvertTo-NativeCommandLineArgument {
    param([AllowNull()][string]$Argument)

    if ($null -eq $Argument -or $Argument.Length -eq 0) {
        return '""'
    }

    if ($Argument -notmatch '[\s"]') {
        return $Argument
    }

    $escaped = $Argument -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

function Join-NativeCommandLineArguments {
    param([string[]]$Arguments)

    $quoted = @()
    foreach ($arg in $Arguments) {
        $quoted += ConvertTo-NativeCommandLineArgument $arg
    }
    return ($quoted -join " ")
}

function ConvertTo-PowerShellLiteral {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) {
        return "''"
    }
    return "'" + ($Value -replace "'", "''") + "'"
}

function ConvertTo-PowerShellArgumentToken {
    param([AllowNull()][string]$Value)

    if ($Value -and $Value -match '^-[A-Za-z][A-Za-z0-9-]*$') {
        return $Value
    }
    return ConvertTo-PowerShellLiteral $Value
}

function Read-RunStatus {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf -ErrorAction SilentlyContinue)) {
        return $null
    }

    try {
        return ([System.IO.File]::ReadAllText($Path, $utf8) | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Get-RunStatusProperty {
    param(
        [AllowNull()][object]$Status,
        [string]$Name,
        [AllowNull()][object]$Default = $null
    )

    if ($null -eq $Status) {
        return $Default
    }

    $property = $Status.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $Default
    }

    if ($null -eq $property.Value) {
        return $Default
    }

    return $property.Value
}

function ConvertTo-IntOrDefault {
    param(
        [AllowNull()][object]$Value,
        [int]$Default = 0
    )

    if ($null -eq $Value) {
        return $Default
    }

    $text = ([string]$Value).Trim()
    if ($text -notmatch '^-?\d+$') {
        return $Default
    }

    try {
        return [int]$text
    } catch {
        return $Default
    }
}

function Get-AgentAction {
    for ($i = 0; $i -lt $AgentArgs.Count; $i++) {
        if ([string]$AgentArgs[$i] -ieq "-Action" -and ($i + 1) -lt $AgentArgs.Count) {
            return [string]$AgentArgs[$i + 1]
        }
    }

    return ""
}

function Get-GitIndexLockPath {
    $gitPath = Join-Path $projectRootFull ".git"
    if (Test-Path -LiteralPath $gitPath -PathType Leaf -ErrorAction SilentlyContinue) {
        try {
            $firstLine = [System.IO.File]::ReadLines($gitPath) | Select-Object -First 1
            if ($firstLine -match '^gitdir:\s*(.+)$') {
                $gitDir = $matches[1].Trim()
                if (-not [System.IO.Path]::IsPathRooted($gitDir)) {
                    $gitDir = Resolve-Agent1cFullPath -Path (Join-Path $projectRootFull $gitDir)
                }
                return (Join-Path $gitDir "index.lock")
            }
        } catch {
        }
    }

    return (Join-Path $gitPath "index.lock")
}

function Initialize-GitIndexLockTracking {
    $script:GitIndexLockPath = Get-GitIndexLockPath
    $script:GitIndexLockPreExisted = Test-Path -LiteralPath $script:GitIndexLockPath -PathType Leaf -ErrorAction SilentlyContinue
}

function Test-GitProcessRunning {
    return [bool](Get-Process -Name "git" -ErrorAction SilentlyContinue | Select-Object -First 1)
}

function Invoke-LauncherGitIndexLockCleanup {
    $lockPath = Get-GitIndexLockPath
    if (-not $lockPath -or -not (Test-Path -LiteralPath $lockPath -PathType Leaf -ErrorAction SilentlyContinue)) {
        return ""
    }

    if ($script:GitIndexLockPreExisted) {
        return "Git index lock was present before this launcher run and was left in place: $lockPath. Close active Git processes and remove it manually only if it is stale."
    }

    if (Test-GitProcessRunning) {
        return "Git index lock remains because git.exe is still running: $lockPath. Wait for Git to finish, then remove it manually only if it is stale."
    }

    try {
        Remove-Item -LiteralPath $lockPath -Force -ErrorAction Stop
        return "Removed Git index lock created during this failed launcher run: $lockPath"
    } catch {
        return "Git index lock cleanup failed for '$lockPath': $($_.Exception.Message). Close active Git processes and remove it manually only if it is stale."
    }
}

function Write-LauncherRunStatus {
    param(
        [ValidateSet("succeeded", "failed")]
        [string]$Status,
        [int]$ExitCode,
        [string]$ErrorMessage,
        [string]$Stage,
        [string]$StageDetail,
        [AllowNull()][object]$ExistingStatus = $null,
        [int]$HelperProcessId = 0
    )

    $now = Get-Date
    $startedAtText = [string](Get-RunStatusProperty -Status $ExistingStatus -Name "startedAt" -Default $startedAt.ToString("o"))
    $action = [string](Get-RunStatusProperty -Status $ExistingStatus -Name "action" -Default (Get-AgentAction))
    $lastLogPath = [string](Get-RunStatusProperty -Status $ExistingStatus -Name "lastLogPath" -Default "")
    $lastProcessId = ConvertTo-IntOrDefault -Value (Get-RunStatusProperty -Status $ExistingStatus -Name "lastProcessId" -Default 0) -Default 0
    $lastProcessTimedOut = [bool](Get-RunStatusProperty -Status $ExistingStatus -Name "lastProcessTimedOut" -Default $false)

    $pidValue = ConvertTo-IntOrDefault -Value (Get-RunStatusProperty -Status $ExistingStatus -Name "pid" -Default $HelperProcessId) -Default $HelperProcessId
    if ($pidValue -eq 0) {
        $pidValue = $PID
    }

    $payload = [ordered]@{
        schemaVersion = 1
        status = $Status
        action = $action
        projectRoot = $projectRootFull
        pid = $pidValue
        startedAt = $startedAtText
        updatedAt = $now.ToString("o")
        finishedAt = $now.ToString("o")
        exitCode = $ExitCode
        lastLogPath = $lastLogPath
        runLogPath = $logPath
        errorMessage = $ErrorMessage
        stage = $Stage
        stageDetail = $StageDetail
        lastProcessId = $lastProcessId
        lastProcessTimedOut = $lastProcessTimedOut
    }

    [System.IO.File]::WriteAllText($statusPath, (($payload | ConvertTo-Json -Depth 6) + [Environment]::NewLine), $utf8)
}

function Stop-ProcessIfRunning {
    param([int]$ProcessId)

    if ($ProcessId -le 0) {
        return
    }

    try {
        $target = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
        if ($null -ne $target -and -not $target.HasExited) {
            Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
        }
    } catch {
    }
}

function Fail-Launcher {
    param(
        [int]$ExitCode,
        [string]$Message,
        [string]$Stage,
        [string]$StageDetail,
        [AllowNull()][object]$ExistingStatus = $null,
        [int]$HelperProcessId = 0
    )

    $cleanupMessage = Invoke-LauncherGitIndexLockCleanup
    $fullMessage = $Message
    if ($cleanupMessage) {
        Write-Host $cleanupMessage
        $fullMessage = "$fullMessage $cleanupMessage"
    }

    $effectiveExitCode = if ($ExitCode -ne 0) { $ExitCode } else { 1 }
    Write-LauncherRunStatus `
        -Status "failed" `
        -ExitCode $effectiveExitCode `
        -ErrorMessage $fullMessage `
        -Stage $Stage `
        -StageDetail $StageDetail `
        -ExistingStatus $ExistingStatus `
        -HelperProcessId $HelperProcessId
    [Console]::Error.WriteLine($fullMessage)
    exit $effectiveExitCode
}

if ($AgentArgs.Count -gt 0 -and $AgentArgs[0] -eq "--") {
    if ($AgentArgs.Count -eq 1) {
        $AgentArgs = @()
    } else {
        $AgentArgs = @($AgentArgs[1..($AgentArgs.Count - 1)])
    }
}

$projectRootFull = Resolve-Agent1cFullPath -Path $ProjectRoot
if ($MaxWaitSeconds -lt 0) {
    throw "MaxWaitSeconds must be 0 or greater."
}
if (-not $HelperPath) {
    $HelperPath = Join-Path $PSScriptRoot "agent-1c.ps1"
}
$helperFull = Resolve-Agent1cFullPath -Path $HelperPath
if (-not (Test-Path -LiteralPath $helperFull -PathType Leaf)) {
    throw "Helper script was not found: $helperFull"
}

$runsRoot = Join-Path $projectRootFull ".agent-1c\runs"
New-Item -ItemType Directory -Force -Path $runsRoot | Out-Null
$runId = "{0}-{1}-{2}" -f (Get-Date -Format "yyyyMMdd-HHmmss-fff"), $PID, ([guid]::NewGuid().ToString("N").Substring(0, 8))
$runDir = Join-Path $runsRoot $runId
New-Item -ItemType Directory -Force -Path $runDir | Out-Null
$statusPath = Join-Path $runDir "status.json"
$logPath = Join-Path $runDir "console.log"
Initialize-GitIndexLockTracking

$powershell = (Get-Command powershell -ErrorAction SilentlyContinue | Select-Object -First 1).Source
if (-not $powershell) {
    throw "powershell.exe was not found."
}

$monitoredArgs = @(
    "-ProjectRoot", $projectRootFull,
    "-RunStatusPath", $statusPath,
    "-RunLogPath", $logPath
) + @($AgentArgs)
if ($KeepWindowOnFailure) {
    $monitoredArgs += "-PauseOnFailure"
}

$helperInvocation = "& " + (ConvertTo-PowerShellLiteral $helperFull) + " " + ((@($monitoredArgs) | ForEach-Object { ConvertTo-PowerShellArgumentToken $_ }) -join " ")
$commandText = @"
`$utf8 = New-Object System.Text.UTF8Encoding `$false
[Console]::InputEncoding = `$utf8
[Console]::OutputEncoding = `$utf8
`$OutputEncoding = `$utf8
`$ProgressPreference = 'SilentlyContinue'
`$ErrorActionPreference = 'Stop'
$helperInvocation *>&1 | Tee-Object -FilePath $(ConvertTo-PowerShellLiteral $logPath)
if (`$LASTEXITCODE -is [int]) { exit `$LASTEXITCODE }
if (`$?) { exit 0 } else { exit 1 }
"@

$argumentLine = Join-NativeCommandLineArguments @("-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", $commandText)

Write-Host "Starting ITL helper in external PowerShell window."
Write-Host "Run directory: $runDir"
Write-Host "Status file: $statusPath"
Write-Host "Console log: $logPath"

$process = Start-Process `
    -FilePath $powershell `
    -ArgumentList $argumentLine `
    -WorkingDirectory $projectRootFull `
    -WindowStyle Normal `
    -PassThru

if ($null -eq $process) {
    throw "Failed to start external PowerShell window."
}

$startedAt = Get-Date
$reportedMissingStatus = $false
while ($true) {
    $status = Read-RunStatus -Path $statusPath
    if ($null -ne $status -and @("succeeded", "failed") -contains ([string]$status.status)) {
        Write-Host "ITL helper finished: $($status.status)"
        Write-Host "Status file: $statusPath"
        Write-Host "Console log: $logPath"
        if ([string]$status.status -eq "failed") {
            if ($status.errorMessage) {
                [Console]::Error.WriteLine([string]$status.errorMessage)
            }
            $exitCode = 1
            if ($null -ne $status.exitCode) {
                $exitCode = [int]$status.exitCode
            }
            exit $exitCode
        }
        exit 0
    }

    $elapsedSeconds = ((Get-Date) - $startedAt).TotalSeconds
    if ($MaxWaitSeconds -gt 0 -and $elapsedSeconds -ge $MaxWaitSeconds) {
        $lastProcessId = ConvertTo-IntOrDefault -Value (Get-RunStatusProperty -Status $status -Name "lastProcessId" -Default 0) -Default 0
        Stop-ProcessIfRunning -ProcessId $lastProcessId
        Stop-ProcessIfRunning -ProcessId $process.Id
        $message = "External ITL helper timed out after $MaxWaitSeconds seconds before writing a terminal status. Log: $logPath"
        Fail-Launcher `
            -ExitCode 124 `
            -Message $message `
            -Stage "launcher.timeout" `
            -StageDetail $message `
            -ExistingStatus $status `
            -HelperProcessId $process.Id
    }

    if ($process.HasExited) {
        Start-Sleep -Milliseconds 200
        $status = Read-RunStatus -Path $statusPath
        if ($null -ne $status -and @("succeeded", "failed") -contains ([string]$status.status)) {
            continue
        }
        $exitCode = ConvertTo-IntOrDefault -Value $process.ExitCode -Default 1
        $message = "External ITL helper exited with code $($process.ExitCode) before writing a terminal status. Log: $logPath"
        Fail-Launcher `
            -ExitCode $exitCode `
            -Message $message `
            -Stage "launcher.helper-exited" `
            -StageDetail $message `
            -ExistingStatus $status `
            -HelperProcessId $process.Id
    }

    if (-not $reportedMissingStatus -and $elapsedSeconds -ge $StatusStartTimeoutSeconds) {
        Write-Host "Waiting for helper status file: $statusPath"
        $reportedMissingStatus = $true
    }

    Start-Sleep -Milliseconds $PollIntervalMilliseconds
}
