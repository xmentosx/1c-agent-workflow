[CmdletBinding()]
param(
    [string]$RepositoryRoot = "",
    # Explicit run directory for fixtures; defaults to the common Git directory's itl\runs.
    [string]$RunRoot = "",
    [int]$Weeks = 4,
    [datetime]$Now = [DateTime]::UtcNow
)

# Read-only weekly report of the existing gate run records against the delivery
# targets in docs/package-architecture.md. It adds no collector or state: the
# records are the ones RegisterChange and publications already write.
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$utf8NoBom = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8NoBom

$targets = [ordered]@{ targetedP90Minutes = 10; publicationP90Minutes = 60; repeatedFailuresOnUnchangedTree = 0 }

if (-not $RepositoryRoot) { $RepositoryRoot = Split-Path -Parent $PSScriptRoot }
if (-not $RunRoot) {
    . (Join-Path $PSScriptRoot "git-path-list.ps1")
    $commonGit = Get-RepositoryCommonGitDirectory -RepositoryRoot $RepositoryRoot
    $RunRoot = Join-Path $commonGit "itl\runs"
}

function Get-MetricPercentile {
    param([double[]]$Values, [double]$Fraction)
    $sorted = @($Values | Sort-Object)
    if ($sorted.Count -eq 0) { return $null }
    $index = [int][Math]::Ceiling($Fraction * $sorted.Count) - 1
    return [Math]::Round($sorted[[Math]::Max(0, $index)], 1)
}

function Test-MetricTimeout {
    param([object]$Run)
    $text = "$([string]$Run.error) $(if ($Run.PSObject.Properties['failure'] -and $Run.failure) { [string]$Run.failure.detail })"
    return $text -match '(?i)budget|DEADLINE|no progress|exceeded its hard'
}

$weekStart = $Now.Date.AddDays(-(([int]$Now.DayOfWeek + 6) % 7)).AddDays(-7 * ([Math]::Max(1, $Weeks) - 1))
$runs = @(foreach ($file in @(Get-ChildItem -LiteralPath $RunRoot -Filter "*.json" -File -ErrorAction SilentlyContinue)) {
    try { $run = [IO.File]::ReadAllText($file.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json } catch { continue }
    if (-not $run.PSObject.Properties['startedAt'] -or -not $run.PSObject.Properties['durationMs'] -or -not $run.PSObject.Properties['mode']) { continue }
    $started = ([datetime]$run.startedAt).ToUniversalTime()
    if ($started -lt $weekStart) { continue }
    [pscustomobject]@{
        week = $started.Date.AddDays(-(([int]$started.DayOfWeek + 6) % 7)).ToString("yyyy-MM-dd")
        mode = [string]$run.mode; status = [string]$run.status; minutes = [double]$run.durationMs / 60000.0
        tree = $(if ($run.PSObject.Properties['tree']) { [string]$run.tree } else { "" })
        timeout = ([string]$run.status -ne "passed" -and (Test-MetricTimeout -Run $run))
    }
})

$report = foreach ($week in @($runs | Group-Object week | Sort-Object Name)) {
    $items = @($week.Group)
    $targeted = @($items | Where-Object mode -eq "Targeted")
    $passedTargeted = @($targeted | Where-Object status -eq "passed" | ForEach-Object { $_.minutes })
    # Publication time is every Develop/Release run spent on a tree that a
    # Release finally qualified, including failed retries of that tree.
    $qualified = @($items | Where-Object { $_.mode -eq "Release" -and $_.status -eq "passed" -and $_.tree } | ForEach-Object tree | Sort-Object -Unique)
    $publication = @(foreach ($tree in $qualified) {
        (@($runs | Where-Object { $_.tree -eq $tree -and $_.mode -in @("Develop", "Release") }) | Measure-Object minutes -Sum).Sum
    })
    $repeated = @($items | Where-Object { $_.status -ne "passed" -and $_.tree } | Group-Object mode, tree | Where-Object Count -ge 2)
    $failed = @($items | Where-Object status -ne "passed")
    [pscustomobject][ordered]@{
        week = $week.Name
        runs = $items.Count
        machineHours = [Math]::Round((($items | Measure-Object minutes -Sum).Sum) / 60, 1)
        failedHours = [Math]::Round((($failed | Measure-Object minutes -Sum).Sum) / 60, 1)
        targetedRuns = $targeted.Count
        targetedFailureRate = $(if ($targeted.Count) { [Math]::Round(@($targeted | Where-Object status -ne "passed").Count / $targeted.Count, 2) } else { $null })
        targetedTimeouts = @($targeted | Where-Object timeout).Count
        targetedP50Minutes = Get-MetricPercentile -Values $passedTargeted -Fraction 0.5
        targetedP90Minutes = Get-MetricPercentile -Values $passedTargeted -Fraction 0.9
        publications = $qualified.Count
        publicationP90Minutes = Get-MetricPercentile -Values $publication -Fraction 0.9
        repeatedFailuresOnUnchangedTree = $repeated.Count
    }
}

$latest = @($report | Select-Object -Last 1)
$status = if ($latest.Count -eq 0) { "no-runs" } else {
    $misses = @(
        if ($null -ne $latest[0].targetedP90Minutes -and $latest[0].targetedP90Minutes -gt $targets.targetedP90Minutes) { "targetedP90Minutes" }
        if ($null -ne $latest[0].publicationP90Minutes -and $latest[0].publicationP90Minutes -gt $targets.publicationP90Minutes) { "publicationP90Minutes" }
        if ($latest[0].repeatedFailuresOnUnchangedTree -gt $targets.repeatedFailuresOnUnchangedTree) { "repeatedFailuresOnUnchangedTree" }
    )
    if ($misses.Count) { "missed: " + ($misses -join ", ") } else { "met" }
}
[pscustomobject][ordered]@{ schemaVersion = 1; runRoot = $RunRoot; targets = $targets; latestWeek = $status; weeks = @($report) } | ConvertTo-Json -Depth 6
