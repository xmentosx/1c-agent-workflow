Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$utf8 = New-Object System.Text.UTF8Encoding $false
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8

$ProjectRoot = (Get-Location).Path
$HelperPath = ""
$PollIntervalMilliseconds = 1000
$StatusStartTimeoutSeconds = 30
$KeepWindowOnFailure = $false
$AgentArgs = @()

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

if ($AgentArgs.Count -gt 0 -and $AgentArgs[0] -eq "--") {
    if ($AgentArgs.Count -eq 1) {
        $AgentArgs = @()
    } else {
        $AgentArgs = @($AgentArgs[1..($AgentArgs.Count - 1)])
    }
}

$projectRootFull = [System.IO.Path]::GetFullPath($ProjectRoot)
if (-not $HelperPath) {
    $HelperPath = Join-Path $PSScriptRoot "agent-1c.ps1"
}
$helperFull = [System.IO.Path]::GetFullPath($HelperPath)
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

    if ($process.HasExited) {
        Start-Sleep -Milliseconds 200
        $status = Read-RunStatus -Path $statusPath
        if ($null -ne $status -and @("succeeded", "failed") -contains ([string]$status.status)) {
            continue
        }
        throw "External ITL helper exited with code $($process.ExitCode) before writing a terminal status. Log: $logPath"
    }

    if (-not $reportedMissingStatus -and ((Get-Date) - $startedAt).TotalSeconds -ge $StatusStartTimeoutSeconds) {
        Write-Host "Waiting for helper status file: $statusPath"
        $reportedMissingStatus = $true
    }

    Start-Sleep -Milliseconds $PollIntervalMilliseconds
}
