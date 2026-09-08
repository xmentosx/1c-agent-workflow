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
        $supervisorCommit = [string]$remoteMaster[0]
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
