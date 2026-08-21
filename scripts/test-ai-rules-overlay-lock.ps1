[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$AiRulesRoot,
    [string]$OverlayPath = "",
    [string]$WorkingDirectory = "",
    [switch]$KeepArtifacts
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$utf8 = [Text.UTF8Encoding]::new($false)

function Get-NormalizedTextSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    $text = [IO.File]::ReadAllText($Path, $utf8).Replace("`r`n", "`n")
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($utf8.GetBytes($text)))).Replace("-", "").ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

$rulesRoot = [IO.Path]::GetFullPath($AiRulesRoot)
if (-not (Test-Path -LiteralPath (Join-Path $rulesRoot ".git"))) {
    throw "ai_rules_1c overlay-lock verification requires a Git checkout: $rulesRoot"
}
if (-not $OverlayPath) {
    $OverlayPath = Join-Path $repositoryRoot "templates\ai-rules-overlay\sections.json"
}
$OverlayPath = [IO.Path]::GetFullPath($OverlayPath)
$ledger = Get-Content -LiteralPath $OverlayPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([int]$ledger.schemaVersion -ne 3 -or @($ledger.pathDecisions).Count -eq 0) {
    throw "ai_rules_1c overlay ledger must use schema 3 and contain path decisions: $OverlayPath"
}

$status = @(& git -C $rulesRoot status --porcelain --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $status.Count -gt 0) {
    throw "ai_rules_1c overlay-lock verification requires a clean checkout: $rulesRoot"
}
$head = (& git -C $rulesRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $head -notmatch '^[a-f0-9]{40}$') {
    throw "Unable to resolve the ai_rules_1c checkout commit: $rulesRoot"
}

$workRoot = if ($WorkingDirectory) {
    [IO.Path]::GetFullPath($WorkingDirectory)
} else {
    Join-Path ([IO.Path]::GetTempPath()) ("itl-ai-rules-overlay-lock-" + [guid]::NewGuid().ToString("N"))
}
$archivePath = Join-Path $workRoot "rules.zip"
$extractedRoot = Join-Path $workRoot "rules"
try {
    New-Item -ItemType Directory -Force -Path $workRoot | Out-Null
    & git -C $rulesRoot archive --format=zip --output=$archivePath HEAD
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
        throw "Unable to archive exact ai_rules_1c Git bytes at $head."
    }
    Expand-Archive -LiteralPath $archivePath -DestinationPath $extractedRoot -Force

    $seen = @{}
    foreach ($decision in @($ledger.pathDecisions)) {
        $path = ([string]$decision.path).Replace('\', '/')
        $expected = ([string]$decision.resultSha256).ToLowerInvariant()
        if (-not $path -or $seen.ContainsKey($path)) { throw "Overlay ledger contains an empty or duplicate path: '$path'." }
        $seen[$path] = $true
        $candidatePath = [IO.Path]::GetFullPath((Join-Path $extractedRoot $path.Replace('/', [IO.Path]::DirectorySeparatorChar)))
        $prefix = $extractedRoot.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
        if (-not $candidatePath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Overlay ledger path escapes the archived rules root: $path"
        }
        if ($expected -eq '<absent>') {
            if (Test-Path -LiteralPath $candidatePath) { throw "Locked ai_rules_1c contains a path declared absent by the overlay: $path" }
            continue
        }
        if ($expected -notmatch '^[a-f0-9]{64}$') { throw "Overlay resultSha256 is invalid for $path`: $expected" }
        if (-not (Test-Path -LiteralPath $candidatePath -PathType Leaf)) { throw "Locked ai_rules_1c is missing overlay result path: $path" }
        # sections.json uses the same UTF-8 + LF-normalized text identity as
        # build-ai-rules-release.ps1, independent of checkout line endings.
        $actual = Get-NormalizedTextSha256 -Path $candidatePath
        if ($actual -cne $expected) {
            throw "Locked ai_rules_1c does not match overlay result for $path. expected='$expected'; actual='$actual'; commit='$head'."
        }
    }

    [pscustomobject]@{ status = "passed"; commit = $head; decisions = $seen.Count; overlayPath = $OverlayPath }
} finally {
    if (-not $KeepArtifacts -and (Test-Path -LiteralPath $workRoot)) {
        Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
    } elseif ($KeepArtifacts) {
        Write-Host "Overlay-lock artifacts retained: $workRoot"
    }
}
