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

function Get-ObjectValue {
    param([object]$Object, [string]$Name, [object]$Default = $null)
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    return $property.Value
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
    "new-dev-branch", "new-extension-dev-branch", "check-dev-branch",
    "refresh-dev-branch", "export-dev-branch-result", "update-workflow",
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
$branchActions = @("new-dev-branch", "new-extension-dev-branch")
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
    & powershell -NoProfile -ExecutionPolicy Bypass -File $helperPath @monitoredArgs *>&1 |
        ForEach-Object { [System.IO.File]::AppendAllText($logPath, ([string]$_ + [Environment]::NewLine), $utf8) }
    $exitCode = if ($LASTEXITCODE -is [int]) { [int]$LASTEXITCODE } else { 1 }
}

$status = Read-JsonFile -Path $statusPath
if ($null -eq $status) {
    $status = [pscustomobject][ordered]@{
        schemaVersion = 1
        status = $(if ($exitCode -eq 0) { "succeeded" } else { "failed" })
        action = $action
        stage = ""
        stageDetail = ""
        errorMessage = $(if ($exitCode -eq 0) { "" } else { "ITL helper did not produce status.json; inspect console.log." })
        exitCode = $exitCode
        lastLogPath = ""
    }
}

$errorText = Limit-Text -Value (Get-ObjectValue -Object $status -Name "errorMessage" -Default "") -Length 1400
$errorCategory = [string](Get-ObjectValue -Object $status -Name "errorCategory" -Default "")
$requiredAction = [string](Get-ObjectValue -Object $status -Name "requiredAction" -Default "")
$authoringStatus = [string](Get-ObjectValue -Object $status -Name "authoringStatus" -Default "")
$authoringStatePath = [string](Get-ObjectValue -Object $status -Name "authoringStatePath" -Default "")
$logTail = ""
if ($exitCode -ne 0 -and (Test-Path -LiteralPath $logPath -PathType Leaf)) {
    $logTail = ((Get-Content -LiteralPath $logPath -Tail 80 -Encoding UTF8 -ErrorAction SilentlyContinue) -join [Environment]::NewLine)
}
$confirmationRequired = $false
if ($action -eq "export-dev-branch-result" -and ($errorText + "`n" + $logTail) -match '(?i)AllowUnverifiedResult|unverified|verification.*missing') {
    $confirmationRequired = $true
}
$nextAction = if ($exitCode -eq 0) {
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
foreach ($candidate in @((Get-ObjectValue -Object $status -Name "lastLogPath" -Default ""), $authoringStatePath, $logPath, $statusPath)) {
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
    authoringStatus = $authoringStatus
    authoringStatePath = $authoringStatePath
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
    $summaryText = $summary | ConvertTo-Json -Depth 8 -Compress
}
if ($summaryText.Length -gt 4000) { throw "Compact ITL summary exceeded 4000 characters." }
Write-Output $summaryText
[Environment]::Exit($exitCode)
