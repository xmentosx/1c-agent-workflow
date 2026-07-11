[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ProjectRoot,
    [string]$HelperPath = "",
    [string]$OutputPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)
$configPath = Join-Path $ProjectRoot ".agent-1c\release-e2e.json"
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    throw "Dedicated E2E stand config is missing: $configPath. Start from templates/release-e2e.example.json."
}
$config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
$devBranchName = [string]$config.devBranchName
$worktreePath = [System.IO.Path]::GetFullPath([string]$config.worktreePath)
if (-not $devBranchName -or -not (Test-Path -LiteralPath $worktreePath -PathType Container)) {
    throw "release-e2e.json must contain an existing worktreePath and devBranchName."
}
if (-not $HelperPath) {
    $HelperPath = Join-Path $worktreePath ".agents\skills\1c-workflow\scripts\agent-1c.ps1"
}
$HelperPath = [System.IO.Path]::GetFullPath($HelperPath)
if (-not (Test-Path -LiteralPath $HelperPath -PathType Leaf)) {
    throw "ITL helper was not found for the E2E stand: $HelperPath"
}
if (-not $OutputPath) {
    $OutputPath = Join-Path $ProjectRoot "build\test-results\release-e2e\release-e2e-summary.json"
}
$OutputPath = [System.IO.Path]::GetFullPath($OutputPath)
$outputRoot = Split-Path -Parent $OutputPath
New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
$startedAt = [DateTime]::UtcNow
$failure = $null
$cleanupFailures = @()
$resultManifestPath = ""
$artifactPath = ""
$artifactSha256 = ""
$verifiedAt = ""
$verifiedCommit = ""

function ConvertTo-NativeArgument {
    param([string]$Value)
    if ($null -eq $Value) { return '""' }
    return '"' + $Value.Replace('"', '\"') + '"'
}

function Invoke-E2EHelper {
    param(
        [string]$Action,
        [int]$TimeoutSeconds,
        [switch]$AllowFailure
    )
    $stdoutPath = Join-Path $outputRoot ($Action + ".stdout.log")
    $stderrPath = Join-Path $outputRoot ($Action + ".stderr.log")
    $parts = @(
        "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", (ConvertTo-NativeArgument $HelperPath),
        "-ProjectRoot", (ConvertTo-NativeArgument $worktreePath),
        "-Action", (ConvertTo-NativeArgument $Action),
        "-DevBranchName", (ConvertTo-NativeArgument $devBranchName)
    )
    $process = Start-Process -FilePath "powershell.exe" -ArgumentList ($parts -join " ") `
        -WorkingDirectory $worktreePath -WindowStyle Hidden -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath -PassThru
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        try { $process.Kill() } catch {}
        if ($AllowFailure) { return [pscustomobject]@{ exitCode = -1; stdoutPath = $stdoutPath; stderrPath = $stderrPath } }
        throw "$Action timed out after $TimeoutSeconds seconds."
    }
    $process.WaitForExit()
    $process.Refresh()
    $exitCode = [int]$process.ExitCode
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "$Action failed with exit code $exitCode. See $stdoutPath and $stderrPath"
    }
    return [pscustomobject]@{ exitCode = $exitCode; stdoutPath = $stdoutPath; stderrPath = $stderrPath }
}

function Get-E2EState {
    $roots = @($ProjectRoot, $worktreePath) | Sort-Object -Unique
    foreach ($root in $roots) {
        $stateRoot = Join-Path $root ".agent-1c\dev-branches"
        foreach ($file in @(Get-ChildItem -LiteralPath $stateRoot -File -Filter "*.json" -ErrorAction SilentlyContinue)) {
            try {
                $state = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                if ([string]$state.devBranchName -eq $devBranchName -or [string]$state.devBranch -eq "itldev/$devBranchName") {
                    return [pscustomobject]@{ value = $state; path = $file.FullName }
                }
            } catch {}
        }
    }
    throw "Development branch state was not found for E2E branch '$devBranchName'."
}

try {
    $branch = (& git -C $worktreePath branch --show-current).Trim()
    if ($LASTEXITCODE -ne 0 -or $branch -notlike "itldev/*") {
        throw "E2E worktree must be an itldev/* Git worktree: $worktreePath"
    }
    if (@(& git -C $worktreePath status --porcelain).Count -gt 0) {
        throw "E2E worktree must be clean before release verification."
    }
    [void](Get-E2EState)

    Invoke-E2EHelper -Action "check-dev-branch" -TimeoutSeconds 7200 | Out-Null
    $statusResult = Invoke-E2EHelper -Action "status" -TimeoutSeconds 120
    $statusText = Get-Content -LiteralPath $statusResult.stdoutPath -Raw -Encoding UTF8
    if ($statusText -notmatch '(?im)^Verification fresh passed:\s*True\s*$') {
        throw "E2E /itl-check did not produce fresh passed verification."
    }

    $stateRecord = Get-E2EState
    $state = $stateRecord.value
    if ([string]$state.lastVerificationStatus -ne "passed") {
        throw "E2E state does not record passed verification."
    }
    $verifiedAt = [string]$state.lastVerifiedAt
    $verifiedCommit = [string]$state.lastVerifiedCommit
    if (-not $verifiedAt -or ([DateTime]::Parse($verifiedAt).ToUniversalTime() -lt $startedAt)) {
        throw "E2E verification is not fresh for the current Release run."
    }

    Invoke-E2EHelper -Action "export-dev-branch-result" -TimeoutSeconds 7200 | Out-Null
    $stateRecord = Get-E2EState
    $state = $stateRecord.value
    $artifactPath = [string]$state.lastResultPath
    if (-not $artifactPath -or -not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
        throw "E2E export artifact was not recorded or does not exist."
    }
    $resultManifestPath = "$artifactPath.manifest.json"
    if (-not (Test-Path -LiteralPath $resultManifestPath -PathType Leaf)) {
        throw "E2E result manifest was not created: $resultManifestPath"
    }
    $manifest = Get-Content -LiteralPath $resultManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not [bool]$manifest.verification.freshPassed -or [bool]$manifest.unverifiedOverride) {
        throw "E2E result manifest does not prove fresh passed verification without override."
    }
    $artifactSha256 = (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($artifactSha256 -ne ([string]$manifest.artifact.sha256).ToLowerInvariant()) {
        throw "E2E artifact SHA256 does not match its result manifest."
    }
} catch {
    $failure = $_.Exception.Message
} finally {
    foreach ($action in @("stop-vanessa-mcp", "stop-roctup-mcp")) {
        try {
            $cleanup = Invoke-E2EHelper -Action $action -TimeoutSeconds 180 -AllowFailure
            if ($cleanup.exitCode -ne 0) { $cleanupFailures += "$action exit=$($cleanup.exitCode)" }
        } catch {
            $cleanupFailures += "$action $($_.Exception.Message)"
        }
    }
    if ($cleanupFailures.Count -gt 0 -and -not $failure) {
        $failure = "E2E cleanup failed: $($cleanupFailures -join '; ')"
    }

    $summary = [ordered]@{
        schemaVersion = 1
        status = $(if ($failure) { "failed" } else { "passed" })
        startedAt = $startedAt.ToString("o")
        finishedAt = [DateTime]::UtcNow.ToString("o")
        projectRoot = $ProjectRoot
        worktreePath = $worktreePath
        devBranchName = $devBranchName
        verifiedAt = $verifiedAt
        verifiedCommit = $verifiedCommit
        artifactPath = $artifactPath
        artifactSha256 = $artifactSha256
        resultManifestPath = $resultManifestPath
        cleanupFailures = @($cleanupFailures)
        error = $failure
    }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($OutputPath, ($summary | ConvertTo-Json -Depth 8), $utf8NoBom)
}

if ($failure) {
    Write-Error $failure
    exit 1
}
Write-Host "Release E2E passed. Summary: $OutputPath"

