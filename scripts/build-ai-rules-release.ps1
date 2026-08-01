[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$AiRulesRoot,
    [string]$UpstreamCommit = "",
    [string]$ReportPath = "",
    [string]$OverlayRoot = "",
    [ValidateSet("Prepare", "Verify")]
    [string]$Mode = "Prepare",
    [switch]$CheckOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$utf8 = New-Object System.Text.UTF8Encoding $false
$workflowRoot = Split-Path -Parent $PSScriptRoot
$overlayRootFull = if ($OverlayRoot) { [IO.Path]::GetFullPath($OverlayRoot) } else { Join-Path $workflowRoot "templates\ai-rules-overlay" }
$manifestPath = Join-Path $overlayRootFull "sections.json"
if ($CheckOnly) { $Mode = "Verify" }

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

function Get-GitPathList {
    param([string[]]$Arguments)
    if ($Arguments.Count -eq 0) { return @() }
    $nulArguments = @($Arguments[0], "-z") + @($Arguments | Select-Object -Skip 1)
    $result = Invoke-AiRulesGit -Arguments (@("-c", "core.quotepath=false") + $nulArguments)
    if (-not $result.stdout) { return @() }
    return @($result.stdout.Split([char]0, [StringSplitOptions]::RemoveEmptyEntries) | Where-Object { $_ })
}

function Get-TextSha256 {
    param([string]$Text)
    $normalized = $Text.Replace("`r`n", "`n")
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($utf8.GetBytes($normalized)))).Replace("-", "").ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Get-GitTextSha256 {
    param([string]$Commit, [string]$Path)
    $result = Invoke-AiRulesGit -Arguments @("show", "$Commit`:$Path") -AllowFailure
    if ($result.exitCode -ne 0) { return "<absent>" }
    return Get-TextSha256 -Text $result.stdout
}

function Test-GitPathExists {
    param([string]$Commit, [string]$Path)
    return (Invoke-AiRulesGit -Arguments @("cat-file", "-e", "$Commit`:$Path") -AllowFailure).exitCode -eq 0
}

function Write-OverlayReport {
    param([object]$Payload, [string]$Path)
    $parent = Split-Path -Parent $Path
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    [IO.File]::WriteAllText($Path, (($Payload | ConvertTo-Json -Depth 16) + [Environment]::NewLine), $utf8)
}

function Add-Blocker {
    param([string]$Message)
    $script:Blockers.Add($Message)
}

$script:AiRulesRootFull = [IO.Path]::GetFullPath($AiRulesRoot)
[void](Invoke-AiRulesGit -Arguments @("rev-parse", "--git-dir"))
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "AI rules decision ledger is missing: $manifestPath"
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([int]$manifest.schemaVersion -ne 3) {
    throw "AI rules decision ledger schemaVersion must be 3."
}
$rootContractPath = Join-Path $overlayRootFull "root-contract.json"
if (-not (Test-Path -LiteralPath $rootContractPath -PathType Leaf)) {
    throw "AI rules root contract ledger is missing: $rootContractPath"
}
$rootContract = Get-Content -LiteralPath $rootContractPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([int]$rootContract.schemaVersion -ne 1) {
    throw "AI rules root contract ledger schemaVersion must be 1."
}

$baselineUpstream = (Invoke-AiRulesGit -Arguments @("rev-parse", "$([string]$manifest.baselineUpstreamCommit)^{commit}")).stdout.Trim()
$baselineRelease = (Invoke-AiRulesGit -Arguments @("rev-parse", "$([string]$manifest.baselineReleaseCommit)^{commit}")).stdout.Trim()
if (-not $UpstreamCommit) { $UpstreamCommit = [string]$manifest.intakeUpstreamCommit }
$UpstreamCommit = (Invoke-AiRulesGit -Arguments @("rev-parse", "$UpstreamCommit^{commit}")).stdout.Trim()
if ($UpstreamCommit -ne [string]$manifest.intakeUpstreamCommit) {
    throw "Requested upstream $UpstreamCommit differs from audited intake $($manifest.intakeUpstreamCommit)."
}

$branch = (Invoke-AiRulesGit -Arguments @("rev-parse", "--abbrev-ref", "HEAD")).stdout.Trim()
if ($branch -in @("main", "master", "HEAD")) {
    throw "AI rules intake must run on a dedicated release/upgrade branch, never on '$branch'."
}
$head = (Invoke-AiRulesGit -Arguments @("rev-parse", "HEAD")).stdout.Trim()
$mergeBase = (Invoke-AiRulesGit -Arguments @("merge-base", $UpstreamCommit, $head)).stdout.Trim()
if ($mergeBase -ne $UpstreamCommit) {
    throw "Current branch is not based directly on audited upstream $UpstreamCommit (merge-base=$mergeBase)."
}
$mergeCommits = (Invoke-AiRulesGit -Arguments @("rev-list", "--merges", "$UpstreamCommit..$head")).stdout.Trim()
if ($mergeCommits) {
    throw "Release history after upstream contains merge commits; rebuild linearly from $UpstreamCommit."
}

$script:Blockers = [Collections.Generic.List[string]]::new()
$managedTargets = @(
    [pscustomobject]@{
        path = [string]$manifest.targetPath
        template = "AGENTS.md"
        maximumCharacters = [int]$manifest.maximumTargetCharacters
        requiredAnchors = @($manifest.requiredTargetAnchors)
    }
)
foreach ($target in @($manifest.additionalTargets)) {
    $managedTargets += [pscustomobject]@{
        path = [string]$target.path
        template = [string]$target.template
        maximumCharacters = [int]$target.maximumCharacters
        requiredAnchors = @($target.requiredAnchors)
    }
}
$managedTargetPaths = @($managedTargets | ForEach-Object path)
foreach ($target in $managedTargets) {
    $templatePath = Join-Path $overlayRootFull $target.template
    if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) {
        Add-Blocker "Managed target template is missing: $($target.template)"
        continue
    }
    $text = [IO.File]::ReadAllText($templatePath, [Text.Encoding]::UTF8).Replace("`r`n", "`n")
    if ($target.maximumCharacters -gt 0 -and $text.Length -gt $target.maximumCharacters) {
        Add-Blocker "Managed target '$($target.path)' is $($text.Length) characters; budget is $($target.maximumCharacters)."
    }
    foreach ($anchor in $target.requiredAnchors) {
        if (-not $text.Contains([string]$anchor)) {
            Add-Blocker "Managed target '$($target.path)' lost required anchor: $anchor"
        }
    }
}

$upstreamAgents = (Invoke-AiRulesGit -Arguments @("show", "$UpstreamCommit`:AGENTS.md")).stdout
foreach ($anchor in @($manifest.requiredUpstreamAnchors)) {
    if (-not $upstreamAgents.Contains([string]$anchor)) {
        Add-Blocker "Required upstream anchor disappeared: $anchor"
    }
}

$rootMappings = @($rootContract.mappings)
$rootMappingsByAnchor = @{}
foreach ($mapping in $rootMappings) {
    $upstreamAnchor = [string]$mapping.upstreamAnchor
    $destination = [string]$mapping.destination
    $destinationAnchor = [string]$mapping.destinationAnchor
    $disposition = [string]$mapping.disposition
    if ([string]::IsNullOrWhiteSpace($upstreamAnchor) -or [string]::IsNullOrWhiteSpace($destination) -or [string]::IsNullOrWhiteSpace($destinationAnchor)) {
        Add-Blocker "Root contract mapping has an empty anchor or destination."
        continue
    }
    if ($rootMappingsByAnchor.ContainsKey($upstreamAnchor)) {
        Add-Blocker "Duplicate root contract mapping: $upstreamAnchor"
        continue
    }
    if ($disposition -notin @("compact-root", "on-demand", "user-rules", "intentional-exclusion")) {
        Add-Blocker "Invalid root contract disposition '$disposition' for '$upstreamAnchor'."
    }
    $rootMappingsByAnchor[$upstreamAnchor] = $mapping
    if ($upstreamAgents.IndexOf($upstreamAnchor, [StringComparison]::Ordinal) -lt 0) {
        Add-Blocker "Mapped upstream root anchor disappeared: $upstreamAnchor"
    }

    if ($disposition -eq "intentional-exclusion") { continue }
    $destinationText = ""
    $managedDestination = @($managedTargets | Where-Object path -eq $destination | Select-Object -First 1)
    if ($managedDestination.Count -gt 0) {
        $destinationTemplate = Join-Path $overlayRootFull ([string]$managedDestination[0].template)
        if (Test-Path -LiteralPath $destinationTemplate -PathType Leaf) {
            $destinationText = [IO.File]::ReadAllText($destinationTemplate, [Text.Encoding]::UTF8)
        }
    }
    else {
        $destinationResult = Invoke-AiRulesGit -Arguments @("show", "HEAD`:$destination") -AllowFailure
        if ($destinationResult.exitCode -eq 0) { $destinationText = [string]$destinationResult.stdout }
    }
    if (-not $destinationText) {
        Add-Blocker "Root contract destination is missing: $destination"
    }
    elseif ($destinationText.IndexOf($destinationAnchor, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
        Add-Blocker "Root contract destination '$destination' lost anchor: $destinationAnchor"
    }
}

$upstreamHeadings = @([regex]::Matches($upstreamAgents, '(?m)^## .+$') | ForEach-Object { $_.Value.TrimEnd("`r") })
foreach ($heading in $upstreamHeadings) {
    if (-not $rootMappingsByAnchor.ContainsKey($heading)) {
        Add-Blocker "Unmapped upstream root section: $heading"
    }
}

$upstreamChangedPaths = @(Get-GitPathList -Arguments @("diff", "--name-only", $baselineUpstream, $UpstreamCommit, "--"))
$baselineDownstreamPaths = @(Get-GitPathList -Arguments @("diff", "--name-only", $baselineUpstream, $baselineRelease, "--"))
$upstreamSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($path in $upstreamChangedPaths) { [void]$upstreamSet.Add($path) }
$baselineSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($path in $baselineDownstreamPaths) { [void]$baselineSet.Add($path) }
$requiredDecisionPaths = @($baselineDownstreamPaths + $upstreamChangedPaths | Sort-Object -Unique)

$decisionsByPath = @{}
foreach ($decision in @($manifest.pathDecisions)) {
    $path = [string]$decision.path
    if (-not $path) {
        Add-Blocker "Path decision has an empty path."
        continue
    }
    if ($decisionsByPath.ContainsKey($path)) {
        Add-Blocker "Duplicate path decision: $path"
        continue
    }
    if ([string]$decision.disposition -notin @("take-upstream", "carry-forward", "resolved", "downstream-only")) {
        Add-Blocker "Invalid disposition '$($decision.disposition)' for '$path'."
    }
    if ([string]::IsNullOrWhiteSpace([string]$decision.requirementId) -or [string]$decision.requirementId -notmatch '^[A-Z0-9][A-Z0-9-]+$') {
        Add-Blocker "Path decision lacks a valid requirementId: $path"
    }
    if ([string]::IsNullOrWhiteSpace([string]$decision.reason)) {
        Add-Blocker "Path decision lacks a reason: $path"
    }
    $decisionsByPath[$path] = $decision
}
foreach ($path in $requiredDecisionPaths) {
    if (-not $decisionsByPath.ContainsKey($path)) { Add-Blocker "Unclassified release path: $path" }
}
foreach ($path in @($decisionsByPath.Keys)) {
    $decision = $decisionsByPath[$path]
    $disposition = [string]$decision.disposition
    $knownPath = $upstreamSet.Contains($path) -or $baselineSet.Contains($path) -or (Test-GitPathExists -Commit $UpstreamCommit -Path $path)
    if (-not $knownPath -and $disposition -ne "downstream-only") {
        Add-Blocker "Decision for new path '$path' must use downstream-only."
    }
    if ($knownPath -and $disposition -eq "downstream-only") {
        Add-Blocker "downstream-only path already exists in upstream or baseline ledger: $path"
    }
    if ($disposition -eq "carry-forward" -and -not $baselineSet.Contains($path)) {
        Add-Blocker "carry-forward path is absent from the baseline release delta: $path"
    }
}

$reportPathFull = if ($ReportPath) { [IO.Path]::GetFullPath($ReportPath) } else { Join-Path $workflowRoot "build\ai-rules-overlay-report.json" }
$report = [ordered]@{
    schemaVersion = 3
    generatedAt = (Get-Date).ToString("o")
    mode = $Mode
    aiRulesRoot = $script:AiRulesRootFull
    branch = $branch
    head = $head
    upstreamCommit = $UpstreamCommit
    baselineUpstreamCommit = $baselineUpstream
    baselineReleaseCommit = $baselineRelease
    upstreamChangedCount = $upstreamChangedPaths.Count
    baselineDownstreamCount = $baselineDownstreamPaths.Count
    decisionCount = $decisionsByPath.Count
    rootContractMappingCount = $rootMappings.Count
    decisions = @()
    blockers = @()
    status = "checked"
}

if ($Mode -eq "Prepare" -and $script:Blockers.Count -eq 0) {
    $dirty = @(Get-GitPathList -Arguments @("status", "--porcelain", "--untracked-files=all"))
    if ($head -ne $UpstreamCommit -or $dirty.Count -gt 0) {
        Add-Blocker "Prepare requires a clean branch whose HEAD is exactly audited upstream $UpstreamCommit."
    }
    else {
        foreach ($decision in @($manifest.pathDecisions | Where-Object disposition -in @("carry-forward", "resolved"))) {
            $path = [string]$decision.path
            if ($path -in $managedTargetPaths) { continue }
            if ([string]$decision.disposition -eq "resolved" -and $upstreamSet.Contains($path)) { continue }
            if (Test-GitPathExists -Commit $baselineRelease -Path $path) {
                [void](Invoke-AiRulesGit -Arguments @("checkout", $baselineRelease, "--", $path))
            }
            else {
                [void](Invoke-AiRulesGit -Arguments @("rm", "--ignore-unmatch", "--", $path))
            }
        }
        foreach ($target in $managedTargets) {
            $templatePath = Join-Path $overlayRootFull $target.template
            $targetPath = Join-Path $script:AiRulesRootFull $target.path
            $text = [IO.File]::ReadAllText($templatePath, [Text.Encoding]::UTF8).Replace("`r`n", "`n").TrimEnd("`n") + "`n"
            [IO.File]::WriteAllText($targetPath, $text, $utf8)
        }
        $report.pendingResolvedPaths = @($manifest.pathDecisions | Where-Object disposition -in @("resolved", "downstream-only") | ForEach-Object path)
        $report.status = "prepared"
    }
}

if ($Mode -eq "Verify" -and $script:Blockers.Count -eq 0) {
    $dirty = @(Get-GitPathList -Arguments @("status", "--porcelain", "--untracked-files=all"))
    if ($dirty.Count -gt 0) { Add-Blocker "Verify requires a clean committed release checkout." }

    $committedPaths = @(Get-GitPathList -Arguments @("diff", "--name-only", $UpstreamCommit, "HEAD", "--"))
    foreach ($path in $committedPaths) {
        if (-not $decisionsByPath.ContainsKey($path)) { Add-Blocker "Release changes unclassified path: $path" }
    }

    foreach ($decision in @($manifest.pathDecisions)) {
        $path = [string]$decision.path
        $upstreamSha = Get-GitTextSha256 -Commit $UpstreamCommit -Path $path
        $resultSha = Get-GitTextSha256 -Commit "HEAD" -Path $path
        $baselineSha = Get-GitTextSha256 -Commit $baselineRelease -Path $path
        if ([string]$decision.upstreamSha256 -ne $upstreamSha) {
            Add-Blocker "Upstream SHA-256 mismatch for '$path'."
        }
        if ([string]$decision.baselineSha256 -ne $baselineSha) {
            Add-Blocker "Baseline SHA-256 mismatch for '$path'."
        }
        if ([string]$decision.resultSha256 -ne $resultSha) {
            Add-Blocker "Result SHA-256 mismatch for '$path'."
        }
        if ([string]$decision.disposition -eq "take-upstream" -and $resultSha -ne $upstreamSha) {
            Add-Blocker "take-upstream path differs from upstream: $path"
        }
        if ([string]$decision.disposition -eq "carry-forward" -and $resultSha -ne $baselineSha) {
            Add-Blocker "carry-forward path differs from baseline release: $path"
        }
        if ([string]$decision.disposition -eq "downstream-only" -and ($upstreamSha -ne "<absent>" -or $baselineSha -ne "<absent>" -or $resultSha -eq "<absent>")) {
            Add-Blocker "downstream-only path has invalid provenance: $path"
        }
        $report.decisions += [pscustomobject]@{
            path = $path
            requirementId = [string]$decision.requirementId
            disposition = [string]$decision.disposition
            upstreamSha256 = $upstreamSha
            baselineSha256 = $baselineSha
            resultSha256 = $resultSha
        }
    }

    foreach ($target in $managedTargets) {
        $templateText = [IO.File]::ReadAllText((Join-Path $overlayRootFull $target.template), [Text.Encoding]::UTF8)
        $expected = Get-TextSha256 -Text $templateText
        $actual = Get-GitTextSha256 -Commit "HEAD" -Path $target.path
        if ($actual -ne $expected) { Add-Blocker "Managed target differs from template: $($target.path)" }
    }
    if ($script:Blockers.Count -eq 0) { $report.status = "verified" }
}

$report.blockers = @($script:Blockers)
if ($script:Blockers.Count -gt 0) {
    $report.status = "blocked"
    Write-OverlayReport -Payload $report -Path $reportPathFull
    throw "AI rules release $Mode is blocked. See $reportPathFull. $($script:Blockers -join ' ')"
}

Write-OverlayReport -Payload $report -Path $reportPathFull
Write-Host "AI rules release $($report.status): $reportPathFull"
Write-Host "Upstream paths: $($upstreamChangedPaths.Count); baseline downstream paths: $($baselineDownstreamPaths.Count); decisions: $($decisionsByPath.Count)"
