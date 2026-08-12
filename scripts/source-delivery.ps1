[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("RegisterChange", "Status", "PublishDevelop", "ReleaseMaster")]
    [string]$Action,
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$Remote = "origin",
    [string]$QueueId = "",
    [string]$BaseRef = "",
    [string[]]$CoverageContract = @(),
    [string]$AiRulesSource = "",
    [string]$E2EProjectRoot = "",
    [string]$GateScript = "",
    [string]$ComponentFinalizerScript = "",
    [string]$Version = "",
    [ValidateSet("Auto", "Restart")]
    [string]$ReleaseResumeMode = "Auto",
    [switch]$RequireRelease
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
. (Join-Path $PSScriptRoot "git-path-list.ps1")
. (Join-Path $PSScriptRoot "release-qualification.ps1")

$script:Root = [System.IO.Path]::GetFullPath($RepositoryRoot)
. (Join-Path (Split-Path -Parent $PSScriptRoot) ".agents\skills\1c-workflow\scripts\lib\agent-1c.immutable-download.ps1")
$script:Remote = $Remote
$script:GateScript = if ($GateScript) { [System.IO.Path]::GetFullPath($GateScript) } else { Join-Path $script:Root "scripts\check.ps1" }
$script:ComponentFinalizerScript = if ($ComponentFinalizerScript) { [System.IO.Path]::GetFullPath($ComponentFinalizerScript) } else { "" }
$script:QueueRoot = "refs/itl/develop-queue"

function Invoke-DeliveryGit {
    param([string[]]$Arguments, [switch]$AllowFailure, [AllowNull()][string]$StandardInput = $null)
    return Invoke-RepositoryGit -RepositoryRoot $script:Root -Arguments $Arguments -AllowFailure:$AllowFailure -StandardInput $StandardInput
}

function Get-GitValue {
    param([string[]]$Arguments)
    return (Invoke-DeliveryGit -Arguments $Arguments).stdout.Trim()
}

function Assert-CleanDeliveryWorktree {
    $status = (Invoke-DeliveryGit -Arguments @("status", "--porcelain", "--untracked-files=all")).stdout
    if ($status) { throw "Source delivery requires a clean worktree. Commit or move unrelated changes first." }
}

function Invoke-WorktreeGit {
    param([string]$Root, [string[]]$Arguments, [switch]$AllowFailure)
    return Invoke-RepositoryGit -RepositoryRoot $Root -Arguments $Arguments -AllowFailure:$AllowFailure
}

function Get-DeliveryCommonGitDirectory {
    $value = Get-GitValue -Arguments @("rev-parse", "--path-format=absolute", "--git-common-dir")
    if ([IO.Path]::IsPathRooted($value)) { return [IO.Path]::GetFullPath($value) }
    return [IO.Path]::GetFullPath((Join-Path $script:Root $value))
}

. (Join-Path $PSScriptRoot "source-delivery-process.ps1")
. (Join-Path $PSScriptRoot "source-delivery-queue.ps1")
. (Join-Path $PSScriptRoot "source-delivery-component.ps1")
. (Join-Path $PSScriptRoot "source-delivery-candidate.ps1")

[void](Invoke-DeliveryGit -Arguments @("rev-parse", "--git-dir"))
if ($RequireRelease -and $Action -ne "PublishDevelop") {
    throw "-RequireRelease is valid only with -Action PublishDevelop."
}
$script:ActiveOperation = $null
try {
    if ($Action -in @("PublishDevelop", "ReleaseMaster")) { [void](Enter-DeliveryOperation -Action $Action) }
    $result = switch ($Action) {
        "RegisterChange" { Register-SourceChange }
        "Status" { [pscustomobject]@{ status = "ok"; queue = @(Get-QueueEntries); activeOperation = (Get-DeliveryOperationStatus); runHistory = (Get-DeliveryRunHistory) } }
        "PublishDevelop" { Publish-AccumulatedDevelop }
        "ReleaseMaster" { Release-DevelopToMaster }
    }
    $result | ConvertTo-Json -Depth 8
} finally {
    Exit-DeliveryOperation
}
