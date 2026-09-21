[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("RegisterChange", "Status", "Plan", "Cleanup", "DiagnoseFull", "PublishDevelop", "PromoteRelease", "ReleaseMaster")]
    [string]$Action,
    [string]$RepositoryRoot = "",
    [string]$Remote = "origin",
    [string]$QueueId = "",
    [string]$BaseRef = "",
    [string[]]$CoverageContract = @(),
    [string]$AiRulesSource = "",
    [string]$E2EProjectRoot = "",
    [string]$FreshProjectsRoot = "C:\itlj",
    [string]$GateScript = "",
    [string]$ComponentFinalizerScript = "",
    [string]$CompatibilityPromoterScript = "",
    [string]$Version = "",
    [ValidateSet("Auto", "Develop", "Master")]
    [string]$CleanupChannel = "Auto",
    [ValidateSet("Summary", "Runs", "Full")]
    [string]$StatusDetail = "Summary",
    [ValidateSet("Auto", "Restart")]
    [string]$ReleaseResumeMode = "Auto",
    [string]$ResumePlan = "",
    [string]$ApproveLongPlan = "",
    [switch]$RetryBlockedStage,
    [switch]$RequireRelease
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
if (-not $RepositoryRoot) { $RepositoryRoot = Split-Path -Parent $PSScriptRoot }
$candidateRoot = [IO.Path]::GetFullPath($RepositoryRoot)
$localSupervisor = Join-Path $PSScriptRoot "source-delivery-supervisor.ps1"
if (-not (Test-Path -LiteralPath $localSupervisor -PathType Leaf)) { throw "Delivery supervisor is missing: $localSupervisor" }

# Status reports the current source checkout and must not bootstrap a detached
# supervisor worktree. Besides being unnecessary for diagnostics, that
# bootstrap performs worktree add/remove mutations in the repository being
# inspected.
if ($Action -eq "Status") {
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $statusSupervisorCommit = @(& git -C $candidateRoot rev-parse HEAD 2>$null) | Select-Object -First 1
    $statusHeadExitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorActionPreference
    if ($statusHeadExitCode -ne 0 -or [string]$statusSupervisorCommit -notmatch '^[a-f0-9]{40}$') {
        throw "Unable to resolve the inspected repository HEAD for read-only delivery status."
    }
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $statusAuthorityCommit = @(& git -C $candidateRoot rev-parse "refs/remotes/$Remote/master" 2>$null) | Select-Object -First 1
    $statusAuthorityExitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorActionPreference
    $statusAuthorityBootstrap = $true
    if ($statusAuthorityExitCode -eq 0 -and [string]$statusAuthorityCommit -match '^[a-f0-9]{40}$') {
        $ErrorActionPreference = "Continue"
        & git -C $candidateRoot cat-file -e "$statusAuthorityCommit`:scripts/source-delivery-supervisor.ps1" 2>$null
        $statusAuthorityBootstrap = $LASTEXITCODE -ne 0
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($statusAuthorityBootstrap) {
        $statusAuthorityCommit = [string]$statusSupervisorCommit
    }
    $statusArguments = @{}
    foreach ($entry in $PSBoundParameters.GetEnumerator()) { $statusArguments[$entry.Key] = $entry.Value }
    $statusArguments["RepositoryRoot"] = $candidateRoot
    $statusArguments["SupervisorCommit"] = [string]$statusAuthorityCommit
    $statusArguments["StatusReaderCommit"] = [string]$statusSupervisorCommit
    $statusArguments["BootstrapSupervisor"] = $statusAuthorityBootstrap
    & $localSupervisor @statusArguments
    return
}

function Resolve-DeliveryBootstrapCommonGitDirectory {
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot)

    $dotGit = Join-Path $RepositoryRoot ".git"
    if (Test-Path -LiteralPath $dotGit -PathType Container) { return [IO.Path]::GetFullPath($dotGit) }
    if (-not (Test-Path -LiteralPath $dotGit -PathType Leaf)) { throw "DELIVERY_RESUME_PLAN_INVALID: .git entry is unavailable." }
    $pointer = [IO.File]::ReadAllText($dotGit, [Text.UTF8Encoding]::new($false)).Trim()
    if ($pointer -notmatch '^gitdir:\s*(.+)$') { throw "DELIVERY_RESUME_PLAN_INVALID: .git worktree pointer is invalid." }
    $gitDirectory = [string]$Matches[1]
    if (-not [IO.Path]::IsPathRooted($gitDirectory)) { $gitDirectory = Join-Path $RepositoryRoot $gitDirectory }
    $gitDirectory = [IO.Path]::GetFullPath($gitDirectory)
    $commonPointer = Join-Path $gitDirectory "commondir"
    if (-not (Test-Path -LiteralPath $commonPointer -PathType Leaf)) { return $gitDirectory }
    $commonDirectory = [IO.File]::ReadAllText($commonPointer, [Text.UTF8Encoding]::new($false)).Trim()
    if (-not $commonDirectory) { throw "DELIVERY_RESUME_PLAN_INVALID: Git common-directory pointer is empty." }
    if (-not [IO.Path]::IsPathRooted($commonDirectory)) { $commonDirectory = Join-Path $gitDirectory $commonDirectory }
    return [IO.Path]::GetFullPath($commonDirectory)
}

$supervisorRoot = ""
$supervisorPath = $localSupervisor
$supervisorCommit = ""
$bootstrapSupervisor = $true
try {
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $remoteMaster = @(& git -C $candidateRoot rev-parse "refs/remotes/$Remote/master" 2>$null)
    $remoteMasterExitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorActionPreference
    if ($remoteMasterExitCode -eq 0 -and $remoteMaster.Count -eq 1 -and $remoteMaster[0] -match '^[a-f0-9]{40}$') {
        $currentMasterCommit = [string]$remoteMaster[0]
        $supervisorCommit = $currentMasterCommit
        if ($ResumePlan) {
            if ($ResumePlan -notmatch '^[a-f0-9]{64}$') { throw "DELIVERY_RESUME_PLAN_INVALID: plan id must be a lowercase SHA256." }
            $commonGitPath = Resolve-DeliveryBootstrapCommonGitDirectory -RepositoryRoot $candidateRoot
            $resumePlanPath = Join-Path $commonGitPath "itl\plans\v1\$ResumePlan.json"
            if (-not (Test-Path -LiteralPath $resumePlanPath -PathType Leaf)) { throw "DELIVERY_RESUME_PLAN_MISSING: $resumePlanPath" }
            try { $savedPlan = Get-Content -LiteralPath $resumePlanPath -Raw -Encoding UTF8 | ConvertFrom-Json }
            catch { throw "DELIVERY_RESUME_PLAN_INVALID: saved plan is unreadable: $($_.Exception.Message)" }
            $recordedSupervisor = [string]$savedPlan.supervisor.commit
            if ([int]$savedPlan.schemaVersion -ne 1 -or [string]$savedPlan.kind -ne "itl-delivery-plan" -or
                [string]$savedPlan.planId -cne $ResumePlan -or $recordedSupervisor -notmatch '^[a-f0-9]{40}$') {
                throw "DELIVERY_RESUME_PLAN_INVALID: saved plan identity or supervisor commit is invalid."
            }
            $ErrorActionPreference = "Continue"
            & git -C $candidateRoot merge-base --is-ancestor $recordedSupervisor $currentMasterCommit 2>$null
            $trustedSupervisor = $LASTEXITCODE -eq 0
            $ErrorActionPreference = $previousErrorActionPreference
            if (-not $trustedSupervisor) {
                throw "DELIVERY_RESUME_SUPERVISOR_UNTRUSTED: recorded supervisor '$recordedSupervisor' is not an ancestor of origin/master '$currentMasterCommit'."
            }
            $supervisorCommit = $recordedSupervisor
        }
        $ErrorActionPreference = "Continue"
        & git -C $candidateRoot cat-file -e "$supervisorCommit`:scripts/source-delivery-supervisor.ps1" 2>$null
        $supervisorExists = $LASTEXITCODE -eq 0
        $ErrorActionPreference = $previousErrorActionPreference
        if ($supervisorExists) {
            $supervisorRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-source-supervisor-" + [guid]::NewGuid().ToString("N"))
            & git -C $candidateRoot worktree add --quiet --detach $supervisorRoot $supervisorCommit
            if ($LASTEXITCODE -ne 0) { throw "Unable to create the stable delivery supervisor worktree at '$supervisorRoot'." }
            $supervisorPath = Join-Path $supervisorRoot "scripts\source-delivery-supervisor.ps1"
            $bootstrapSupervisor = $false
        }
    }
    if (-not $supervisorCommit) {
        $ErrorActionPreference = "Continue"
        $supervisorCommit = @(& git -C $candidateRoot rev-parse HEAD 2>$null) | Select-Object -First 1
        $ErrorActionPreference = $previousErrorActionPreference
    }
    $arguments = @{}
    foreach ($entry in $PSBoundParameters.GetEnumerator()) { $arguments[$entry.Key] = $entry.Value }
    $arguments["RepositoryRoot"] = $candidateRoot
    $arguments["SupervisorCommit"] = $supervisorCommit
    $arguments["BootstrapSupervisor"] = $bootstrapSupervisor
    & $supervisorPath @arguments
} finally {
    if ($supervisorRoot -and (Test-Path -LiteralPath $supervisorRoot -PathType Container)) {
        & git -C $candidateRoot worktree remove --force -- $supervisorRoot 2>$null
        if ($LASTEXITCODE -ne 0) { Write-Warning "Stable delivery supervisor worktree could not be removed: $supervisorRoot" }
    }
}
