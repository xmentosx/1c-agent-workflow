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
    [string]$SupervisorCommit = "",
    [switch]$BootstrapSupervisor,
    [switch]$RetryBlockedStage,
    [switch]$RequireRelease
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
Import-Module Microsoft.PowerShell.Utility -ErrorAction Stop
if (-not $RepositoryRoot) { throw "Stable delivery supervisor requires an explicit candidate RepositoryRoot." }
. (Join-Path $PSScriptRoot "git-path-list.ps1")
. (Join-Path $PSScriptRoot "release-qualification.ps1")
. (Join-Path $PSScriptRoot "quality-contracts.ps1")
. (Join-Path $PSScriptRoot "develop-e2e-qualification.ps1")

$script:Root = [System.IO.Path]::GetFullPath($RepositoryRoot)
. (Join-Path (Split-Path -Parent $PSScriptRoot) ".agents\skills\1c-workflow\scripts\lib\agent-1c.immutable-download.ps1")
$script:Remote = $Remote
$script:DeliveryRequestedAiRulesSource = $AiRulesSource
$script:DeliveryPreparedAiRulesWorktree = ""
$script:DeliveryPreparedAiRulesRepository = ""
$script:GateScript = if ($GateScript) { [System.IO.Path]::GetFullPath($GateScript) } else { Join-Path $script:Root "scripts\check.ps1" }
$script:ComponentFinalizerScript = if ($ComponentFinalizerScript) { [System.IO.Path]::GetFullPath($ComponentFinalizerScript) } else { "" }
$script:CompatibilityPromoterScript = if ($CompatibilityPromoterScript) { [System.IO.Path]::GetFullPath($CompatibilityPromoterScript) } else { Join-Path $script:Root "scripts\promote-ai-rules-compatibility.ps1" }
$script:QueueRoot = "refs/itl/develop-queue"
$script:DeliverySupervisorCommit = $SupervisorCommit
$script:DeliverySupervisorBootstrap = [bool]$BootstrapSupervisor
$script:DeliveryCustomGateBoundary = [bool]$GateScript -and $script:GateScript -ne (Join-Path $script:Root "scripts\check.ps1")

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
. (Join-Path $PSScriptRoot "source-delivery-plan.ps1")
. (Join-Path $PSScriptRoot "source-delivery-resources.ps1")
. (Join-Path $PSScriptRoot "source-delivery-candidate.ps1")
. (Join-Path $PSScriptRoot "source-delivery-cleanup.ps1")

[void](Invoke-DeliveryGit -Arguments @("rev-parse", "--git-dir"))
if ($RequireRelease -and $Action -notin @("Plan", "PublishDevelop")) { throw "-RequireRelease is valid only with -Action Plan or PublishDevelop." }
if ($RetryBlockedStage -and $Action -ne "PublishDevelop") { throw "-RetryBlockedStage is valid only with -Action PublishDevelop." }
if ($ResumePlan -and $Action -notin @("PublishDevelop", "PromoteRelease", "ReleaseMaster")) { throw "-ResumePlan is valid only for a publication action." }
if ($ApproveLongPlan -and $Action -notin @("PublishDevelop", "PromoteRelease", "ReleaseMaster")) { throw "-ApproveLongPlan is valid only for a publication action." }
if ($StatusDetail -ne "Summary" -and $Action -ne "Status") { throw "-StatusDetail is valid only with -Action Status." }

$script:ActiveOperation = $null
try {
    if ($Action -in @("Cleanup", "PublishDevelop", "PromoteRelease", "ReleaseMaster")) {
        [void](Enter-DeliveryOperation -Action $Action)
        if ($Action -ne "Cleanup" -and -not $script:DeliveryCustomGateBoundary) {
            [void](Invoke-DeliveryCleanupSweep -FreshProjectsRoot $FreshProjectsRoot -E2EProjectRoot $E2EProjectRoot -Phase "pre-operation")
        }
    }
    $result = switch ($Action) {
        "RegisterChange" { Register-SourceChange }
        "Status" {
            $history = Get-DeliveryRunHistory -Limit $(if ($StatusDetail -eq "Summary") { 3 } else { 20 }) -IncludeDetails:($StatusDetail -eq "Full")
            $attempt = Read-DevelopPublicationAttempt
            [pscustomobject]@{
                status = "ok"
                supervisor = [pscustomobject]@{ commit=$script:DeliverySupervisorCommit; bootstrap=[bool]$script:DeliverySupervisorBootstrap }
                queue = @(Get-QueueEntries | ForEach-Object { [pscustomobject]@{ id=$_.id; base=$_.base; head=$_.head } })
                activeOperation = (Get-DeliveryOperationStatus)
                publicationAttempt = $(if ($attempt) { [pscustomobject]@{ phase=$attempt.phase; planId=$(if ($attempt.PSObject.Properties.Name -contains 'planId') { [string]$attempt.planId } else { '' }); candidate=$attempt.candidate; tree=$attempt.tree; startedAt=$attempt.startedAt; requireRelease=[bool]$attempt.requireRelease; failures=$(if ($attempt.PSObject.Properties.Name -contains 'failures') { $attempt.failures } else { @() }) } } else { $null })
                cleanupDebt = (Get-DeliveryResourceLedgerSummary)
                runHistory = $history
            }
        }
        "Plan" { New-AccumulatedDeliveryPlan -RequireRelease:$RequireRelease }
        "Cleanup" { Invoke-DeliveryCleanupSweep -FreshProjectsRoot $FreshProjectsRoot -E2EProjectRoot $E2EProjectRoot -Phase "manual" }
        "DiagnoseFull" { Invoke-DeliveryDiagnosticFull -AiRulesSource $AiRulesSource -E2EProjectRoot $E2EProjectRoot }
        "PublishDevelop" { Publish-AccumulatedDevelop }
        "PromoteRelease" { Promote-AccumulatedDevelopToMaster }
        "ReleaseMaster" { Release-DevelopToMaster }
    }
    if ($Action -in @("PublishDevelop", "PromoteRelease", "ReleaseMaster") -and -not $script:DeliveryCustomGateBoundary -and $result -and [string]$result.status -in @("published", "released")) {
        $cleanup = Invoke-DeliveryCleanupSweep -FreshProjectsRoot $FreshProjectsRoot -E2EProjectRoot $E2EProjectRoot -Phase "post-operation"
        $result | Add-Member -NotePropertyName cleanup -NotePropertyValue $cleanup -Force
        if ([string]$cleanup.status -eq "completed-with-warnings") {
            $result | Add-Member -NotePropertyName deliveryStatus -NotePropertyValue "completed-with-cleanup-warnings" -Force
        }
    }
    $result | ConvertTo-Json -Depth 16
} finally {
    Remove-DeliveryPreparedAiRulesWorktree
    Exit-DeliveryOperation
}
