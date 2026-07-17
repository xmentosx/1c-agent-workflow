[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$AiRulesRoot,
    [string]$UpstreamCommit = "",
    [string]$ReportPath = "",
    [string]$OverlayRoot = "",
    [switch]$CheckOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$utf8 = New-Object System.Text.UTF8Encoding $false
$workflowRoot = Split-Path -Parent $PSScriptRoot
$overlayRoot = if ($OverlayRoot) { [IO.Path]::GetFullPath($OverlayRoot) } else { Join-Path $workflowRoot "templates\ai-rules-overlay" }
$manifestPath = Join-Path $overlayRoot "sections.json"
$targetTemplatePath = Join-Path $overlayRoot "AGENTS.md"

function ConvertTo-NativeArgument {
    param([string]$Value)
    if ($Value -notmatch '[\s"]') { return $Value }
    return '"' + $Value.Replace('"', '\"') + '"'
}

function Invoke-GitProcess {
    param([string[]]$Arguments, [switch]$AllowFailure)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "git"
    $psi.Arguments = (@($Arguments) | ForEach-Object { ConvertTo-NativeArgument -Value ([string]$_) }) -join " "
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $utf8
    $psi.StandardErrorEncoding = $utf8
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    [void]$process.Start()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    $result = [pscustomobject]@{ exitCode = $process.ExitCode; stdout = $stdout; stderr = $stderr }
    if (-not $AllowFailure -and $result.exitCode -ne 0) {
        throw "git $($Arguments -join ' ') failed with exit code $($result.exitCode): $($result.stderr.Trim())"
    }
    return $result
}

function Invoke-AiRulesGit {
    param([string[]]$Arguments, [switch]$AllowFailure)
    return Invoke-GitProcess -Arguments (@("-C", $script:AiRulesRootFull) + @($Arguments)) -AllowFailure:$AllowFailure
}

function Get-TextSha256 {
    param([string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($utf8.GetBytes($Text)))).Replace("-", "").ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-TopLevelSections {
    param([string]$Text)
    $matches = [regex]::Matches($Text, '(?m)^# ([^#\r\n].*)$')
    $result = [System.Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $matches.Count; $index++) {
        $start = $matches[$index].Index
        $end = if (($index + 1) -lt $matches.Count) { $matches[$index + 1].Index } else { $Text.Length }
        $sectionText = $Text.Substring($start, $end - $start)
        $result.Add([pscustomobject]@{
            heading = [string]$matches[$index].Groups[1].Value
            sha256 = Get-TextSha256 -Text $sectionText
            length = $sectionText.Length
        })
    }
    return @($result)
}

function Write-OverlayReport {
    param([object]$Payload, [string]$Path)
    $parent = Split-Path -Parent $Path
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    [IO.File]::WriteAllText($Path, (($Payload | ConvertTo-Json -Depth 12) + [Environment]::NewLine), $utf8)
}

function Test-WorktreeMatchesCommitPaths {
    param([string]$Commit, [string[]]$Paths)
    foreach ($path in @($Paths)) {
        $expected = Invoke-AiRulesGit -Arguments @("rev-parse", "$Commit`:$path") -AllowFailure
        $fullPath = Join-Path $script:AiRulesRootFull $path
        if ($expected.exitCode -ne 0) {
            if (Test-Path -LiteralPath $fullPath) { return $false }
            continue
        }
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { return $false }
        $actual = Invoke-AiRulesGit -Arguments @("hash-object", "--path=$path", $path)
        if ($actual.stdout.Trim() -ne $expected.stdout.Trim()) { return $false }
    }
    return $true
}

$script:AiRulesRootFull = [IO.Path]::GetFullPath($AiRulesRoot)
if (-not (Test-Path -LiteralPath (Join-Path $script:AiRulesRootFull ".git") -ErrorAction SilentlyContinue) -and
    -not (Test-Path -LiteralPath (Join-Path $script:AiRulesRootFull "AGENTS.md") -PathType Leaf)) {
    throw "AiRulesRoot is not a usable ai_rules_1c checkout: $script:AiRulesRootFull"
}
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf) -or -not (Test-Path -LiteralPath $targetTemplatePath -PathType Leaf)) {
    throw "AI rules overlay assets are incomplete under $overlayRoot"
}
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$baselineUpstream = [string]$manifest.baselineUpstreamCommit
$baselineRelease = [string]$manifest.baselineReleaseCommit
if (-not $UpstreamCommit) { $UpstreamCommit = $baselineUpstream }
$UpstreamCommit = (Invoke-AiRulesGit -Arguments @("rev-parse", "$UpstreamCommit^{commit}")).stdout.Trim()
foreach ($commit in @($baselineUpstream, $baselineRelease)) {
    [void](Invoke-AiRulesGit -Arguments @("cat-file", "-e", "$commit^{commit}"))
}

$branch = (Invoke-AiRulesGit -Arguments @("rev-parse", "--abbrev-ref", "HEAD")).stdout.Trim()
if ($branch -in @("main", "master", "HEAD")) {
    throw "AI rules overlay must run on a dedicated release/upgrade branch, never on '$branch'."
}
$head = (Invoke-AiRulesGit -Arguments @("rev-parse", "HEAD")).stdout.Trim()
$mergeBase = (Invoke-AiRulesGit -Arguments @("merge-base", $UpstreamCommit, $head)).stdout.Trim()
if ($mergeBase -ne $UpstreamCommit) {
    throw "Current branch is not based directly on upstream commit $UpstreamCommit (merge-base=$mergeBase)."
}
$mergeCommits = (Invoke-AiRulesGit -Arguments @("rev-list", "--merges", "$UpstreamCommit..$head")).stdout.Trim()
if ($mergeCommits) { throw "Release history after upstream contains merge commits; rebuild directly from upstream instead of merging/rebasing an old downstream release." }

$upstreamAgents = (Invoke-AiRulesGit -Arguments @("show", "$UpstreamCommit`:AGENTS.md")).stdout
$actualSections = @(Get-TopLevelSections -Text $upstreamAgents)
$expectedSections = @($manifest.sections)
$sectionLedger = [System.Collections.Generic.List[object]]::new()
$sectionBlockers = [System.Collections.Generic.List[string]]::new()
foreach ($expected in $expectedSections) {
    if ([string]$expected.disposition -notin @("keep", "drop", "rewrite")) {
        $sectionBlockers.Add("Invalid disposition '$($expected.disposition)' for section '$($expected.heading)'.")
        continue
    }
    $actual = @($actualSections | Where-Object { $_.heading -eq [string]$expected.heading } | Select-Object -First 1)
    $state = if ($actual.Count -eq 0) { "removed" } elseif ($actual[0].sha256 -eq [string]$expected.sha256) { "unchanged" } else { "changed" }
    $sectionLedger.Add([pscustomobject]@{ heading = [string]$expected.heading; state = $state; disposition = [string]$expected.disposition; owner = [string]$expected.owner; expectedSha256 = [string]$expected.sha256; actualSha256 = $(if ($actual.Count) { $actual[0].sha256 } else { "" }) })
    if ($state -ne "unchanged") { $sectionBlockers.Add("Upstream AGENTS.md section '$($expected.heading)' is $state and requires a new keep/drop/rewrite decision.") }
}
foreach ($actual in $actualSections) {
    if (@($expectedSections | Where-Object { [string]$_.heading -eq $actual.heading }).Count -eq 0) {
        $sectionLedger.Add([pscustomobject]@{ heading = $actual.heading; state = "added"; disposition = "unclassified"; owner = ""; expectedSha256 = ""; actualSha256 = $actual.sha256 })
        $sectionBlockers.Add("Upstream AGENTS.md added unclassified section '$($actual.heading)'.")
    }
}
foreach ($anchor in @($manifest.requiredUpstreamAnchors)) {
    if (-not $upstreamAgents.Contains([string]$anchor)) { $sectionBlockers.Add("Required upstream anchor disappeared: $anchor") }
}

$patchPaths = @((Invoke-AiRulesGit -Arguments @("diff", "--name-only", $baselineUpstream, $baselineRelease, "--", ".", ":(exclude)AGENTS.md")).stdout -split "`r?`n" | Where-Object { $_ })
$pathLedger = [System.Collections.Generic.List[object]]::new()
$pathBlockers = [System.Collections.Generic.List[string]]::new()
foreach ($path in $patchPaths) {
    $comparison = Invoke-AiRulesGit -Arguments @("diff", "--quiet", $baselineUpstream, $UpstreamCommit, "--", $path) -AllowFailure
    if ($comparison.exitCode -gt 1) { throw "Could not compare upstream path '$path': $($comparison.stderr.Trim())" }
    $state = if ($comparison.exitCode -eq 0) { "unchanged" } else { "changed" }
    $pathLedger.Add([pscustomobject]@{ path = $path; state = $state; disposition = [string]$manifest.downstreamPatch.disposition; owner = "baseline:$baselineRelease" })
    if ($state -ne "unchanged") { $pathBlockers.Add("Upstream changed downstream-owned path '$path'; classify it explicitly before rebuilding the release.") }
}

$allowedPaths = @($patchPaths + @([string]$manifest.targetPath))
$committedPaths = @((Invoke-AiRulesGit -Arguments @("diff", "--name-only", $UpstreamCommit, "HEAD", "--")).stdout -split "`r?`n" | Where-Object { $_ })
foreach ($path in $committedPaths) {
    if ($path -notin $allowedPaths) { $pathBlockers.Add("Release history changes unclassified path '$path'.") }
}
$dirtyEntries = @((Invoke-AiRulesGit -Arguments @("status", "--porcelain", "--untracked-files=all")).stdout -split "`r?`n" | Where-Object { $_ })
foreach ($entry in $dirtyEntries) {
    $path = if ($entry.Length -gt 3) { $entry.Substring(3) } else { $entry }
    if ($path -match ' -> (.+)$') { $path = [string]$Matches[1] }
    if ($path -notin $allowedPaths) { $pathBlockers.Add("Worktree has an unrelated change '$path'.") }
}

$targetText = [IO.File]::ReadAllText($targetTemplatePath, [Text.Encoding]::UTF8).Replace("`r`n", "`n")
if ($targetText.Length -gt [int]$manifest.maximumTargetCharacters) {
    $sectionBlockers.Add("Compact AGENTS.md is $($targetText.Length) characters; budget is $($manifest.maximumTargetCharacters).")
}
foreach ($anchor in @($manifest.requiredTargetAnchors)) {
    if (-not $targetText.Contains([string]$anchor)) { $sectionBlockers.Add("Compact AGENTS.md lost required anchor: $anchor") }
}

$reportPathFull = if ($ReportPath) { [IO.Path]::GetFullPath($ReportPath) } else { Join-Path $workflowRoot "build\ai-rules-overlay-report.json" }
$report = [ordered]@{
    schemaVersion = 1
    generatedAt = (Get-Date).ToString("o")
    aiRulesRoot = $script:AiRulesRootFull
    branch = $branch
    head = $head
    upstreamCommit = $UpstreamCommit
    baselineUpstreamCommit = $baselineUpstream
    baselineReleaseCommit = $baselineRelease
    targetPath = [string]$manifest.targetPath
    targetCharacters = $targetText.Length
    sections = @($sectionLedger)
    downstreamPaths = @($pathLedger)
    blockers = @($sectionBlockers) + @($pathBlockers)
    status = "checked"
}
if ($report.blockers.Count -gt 0) {
    $report.status = "blocked"
    Write-OverlayReport -Payload $report -Path $reportPathFull
    throw "AI rules release overlay is blocked. See $reportPathFull. $($report.blockers -join ' ')"
}

if (-not $CheckOnly) {
    $overlayApplied = Test-WorktreeMatchesCommitPaths -Commit $baselineRelease -Paths $patchPaths
    if (-not $overlayApplied) {
        if ($dirtyEntries.Count -gt 0 -or $head -ne $UpstreamCommit) {
            throw "Downstream patch is not fully applied, but the release worktree/history is not a clean upstream starting point. Recreate the release branch from $UpstreamCommit."
        }
        $patchResult = Invoke-AiRulesGit -Arguments @("diff", "--binary", $baselineUpstream, $baselineRelease, "--", ".", ":(exclude)AGENTS.md")
        $tempPatch = Join-Path ([IO.Path]::GetTempPath()) ("itl-ai-rules-overlay-" + [guid]::NewGuid().ToString("N") + ".patch")
        try {
            [IO.File]::WriteAllText($tempPatch, $patchResult.stdout, $utf8)
            [void](Invoke-AiRulesGit -Arguments @("apply", "--check", "--whitespace=nowarn", $tempPatch))
            [void](Invoke-AiRulesGit -Arguments @("apply", "--whitespace=nowarn", $tempPatch))
        } finally {
            Remove-Item -LiteralPath $tempPatch -Force -ErrorAction SilentlyContinue
        }
    }
    $targetPath = Join-Path $script:AiRulesRootFull ([string]$manifest.targetPath)
    [IO.File]::WriteAllText($targetPath, ($targetText.TrimEnd("`n") + "`n"), $utf8)
    foreach ($section in $expectedSections) {
        $owner = [string]$section.owner
        if ($owner -like "content/*" -and -not (Test-Path -LiteralPath (Join-Path $script:AiRulesRootFull $owner) -PathType Leaf)) {
            throw "Overlay owner is missing after generation: $owner"
        }
    }
    $report.status = "generated"
    $report.targetSha256 = Get-TextSha256 -Text ([IO.File]::ReadAllText($targetPath, [Text.Encoding]::UTF8).Replace("`r`n", "`n"))
    $patchReportPath = [IO.Path]::ChangeExtension($reportPathFull, ".patch")
    $baselineDiff = Invoke-AiRulesGit -Arguments @("diff", "--binary", $baselineUpstream, $baselineRelease, "--", ".", ":(exclude)AGENTS.md")
    $agentsDiff = Invoke-AiRulesGit -Arguments @("diff", "--binary", $UpstreamCommit, "--", [string]$manifest.targetPath)
    [IO.File]::WriteAllText($patchReportPath, ($baselineDiff.stdout.TrimEnd() + [Environment]::NewLine + $agentsDiff.stdout), $utf8)
    $report.patchReportPath = $patchReportPath
}
Write-OverlayReport -Payload $report -Path $reportPathFull
Write-Host "AI rules overlay $($report.status): $reportPathFull"
Write-Host "AGENTS.md characters: $($targetText.Length)"
