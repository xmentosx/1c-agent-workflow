[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$RepositoryRoot = "",
    [string]$QualificationPath = "build\test-results\qualification\full.json",
    [string]$LockPath = "templates\dependency-lock.json",
    [string]$CheckedAt = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$utf8 = New-Object System.Text.UTF8Encoding $false
if (-not $RepositoryRoot) { $RepositoryRoot = Split-Path -Parent $PSScriptRoot }
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
if (-not [IO.Path]::IsPathRooted($QualificationPath)) { $QualificationPath = Join-Path $RepositoryRoot $QualificationPath }
if (-not [IO.Path]::IsPathRooted($LockPath)) { $LockPath = Join-Path $RepositoryRoot $LockPath }

if (@(& git -C $RepositoryRoot status --porcelain --untracked-files=no).Count -gt 0) {
    throw "Compatibility promotion requires a clean tracked workflow tree."
}
if (-not (Test-Path -LiteralPath $QualificationPath -PathType Leaf)) { throw "Workflow Full qualification is missing: $QualificationPath" }
if (-not (Test-Path -LiteralPath $LockPath -PathType Leaf)) { throw "Dependency lock is missing: $LockPath" }

$qualification = Get-Content -LiteralPath $QualificationPath -Raw -Encoding UTF8 | ConvertFrom-Json
$head = (& git -C $RepositoryRoot rev-parse HEAD).Trim().ToLowerInvariant()
$tree = (& git -C $RepositoryRoot rev-parse 'HEAD^{tree}').Trim().ToLowerInvariant()
if ([string]$qualification.kind -ne "itl-workflow-full-qualification" -or [string]$qualification.status -ne "passed" -or -not [bool]$qualification.reusable) {
    throw "Workflow qualification is not a reusable passed Full result."
}
if ([string]$qualification.repository.commit -ne $head -or [string]$qualification.repository.tree -ne $tree -or -not [bool]$qualification.repository.worktreeClean) {
    throw "Workflow qualification does not match the exact clean HEAD tree."
}
if ([int]$qualification.result.failed -ne 0 -or [int]$qualification.result.skipped -ne 0) {
    throw "Workflow qualification contains failed or skipped tests."
}

$lockText = [IO.File]::ReadAllText($LockPath, [Text.Encoding]::UTF8)
$lock = $lockText | ConvertFrom-Json
$entry = $lock.dependencies.aiRules1c
if ([string]$entry.compatibilityStatus -ne "pending" -or [string]$entry.compatibilityCheckedAt) {
    throw "aiRules1c lock must be pending with an empty compatibilityCheckedAt value."
}
foreach ($pair in @(
    @([string]$qualification.fork.repo, [string]$entry.repo, "repo"),
    @([string]$qualification.fork.tag, [string]$entry.ref, "tag"),
    @([string]$qualification.fork.commit, [string]$entry.commit, "commit"),
    @([string]$qualification.fork.upstreamRef, [string]$entry.upstreamRef, "upstreamRef"),
    @([string]$qualification.fork.upstreamCommit, [string]$entry.upstreamCommit, "upstreamCommit")
)) {
    if ($pair[0] -ne $pair[1]) { throw "Workflow qualification fork $($pair[2]) does not match the pending lock." }
}
$forkQualificationPath = [string]$qualification.fork.qualificationPath
if (-not (Test-Path -LiteralPath $forkQualificationPath -PathType Leaf)) { throw "Fork qualification referenced by workflow Full is missing." }
$forkQualificationHash = (Get-FileHash -LiteralPath $forkQualificationPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($forkQualificationHash -ne ([string]$qualification.fork.qualificationSha256).ToLowerInvariant()) {
    throw "Fork qualification hash differs from workflow Full evidence."
}

$checkedAtValue = if ($CheckedAt) { [DateTimeOffset]::Parse($CheckedAt).ToUniversalTime() } else { [DateTimeOffset]::UtcNow }
$finishedAt = [DateTimeOffset]::Parse([string]$qualification.finishedAt).ToUniversalTime()
if ($checkedAtValue -lt $finishedAt) { throw "compatibilityCheckedAt cannot precede the successful Full qualification." }
$timestamp = $checkedAtValue.ToString("yyyy-MM-ddTHH:mm:ssZ")
$pattern = '(?s)(?<prefix>"aiRules1c"\s*:\s*\{.*?"compatibilityStatus"\s*:\s*")pending(?<middle>".*?"compatibilityCheckedAt"\s*:\s*")(?<old>[^"]*)(?<suffix>")'
$match = [regex]::Match($lockText, $pattern)
if (-not $match.Success) { throw "Could not locate the pending aiRules1c compatibility fields without reformatting the lock." }
$updated = $lockText.Substring(0, $match.Index) + $match.Groups['prefix'].Value + "passed" + $match.Groups['middle'].Value + $timestamp + $match.Groups['suffix'].Value + $lockText.Substring($match.Index + $match.Length)

if ($PSCmdlet.ShouldProcess($LockPath, "promote aiRules1c compatibility to passed from exact Full evidence")) {
    [IO.File]::WriteAllText($LockPath, $updated, $utf8)
}
Write-Host "aiRules1c compatibility promoted from exact Full evidence: $timestamp"
Write-Host "Run targeted lock/overlay tests, commit only the promoted lock, then run Full once on the final tree."
