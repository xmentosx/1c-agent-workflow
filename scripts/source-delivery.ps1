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
. (Join-Path $PSScriptRoot 'git-path-list.ps1')
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

function Get-DeliveryBootstrapTrackingCommit {
    param([Parameter(Mandatory = $true)][string]$Branch)
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $value = @(& git -C $candidateRoot rev-parse "refs/remotes/$Remote/$Branch" 2>$null)
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorActionPreference
    if ($exitCode -ne 0 -or $value.Count -ne 1 -or [string]$value[0] -notmatch '^[a-f0-9]{40}$') { return "" }
    return [string]$value[0]
}

function Test-DeliveryBootstrapAncestor {
    param([Parameter(Mandatory = $true)][string]$Ancestor, [Parameter(Mandatory = $true)][string]$Descendant)
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & git -C $candidateRoot merge-base --is-ancestor $Ancestor $Descendant 2>$null
    $isAncestor = $LASTEXITCODE -eq 0
    $ErrorActionPreference = $previousErrorActionPreference
    return $isAncestor
}

function Assert-DeliveryBootstrapPairedAssetSupport {
    param([Parameter(Mandatory = $true)][string]$SupervisorCommit)
    $lockPath = Join-Path $candidateRoot 'templates\dependency-lock.json'
    if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) { return }
    $lock = Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $mcp = if ($lock.dependencies -and $lock.dependencies.PSObject.Properties['vanessaMcp']) { $lock.dependencies.vanessaMcp } else { $null }
    $paired = if ($mcp -and $mcp.PSObject.Properties['vaExtension']) { $mcp.vaExtension } else { $null }
    if (-not $paired -or -not $paired.PSObject.Properties['url'] -or -not [string]$paired.url) { return }
    $component = Invoke-RepositoryGit -RepositoryRoot $candidateRoot -Arguments @('show', "${SupervisorCommit}:scripts/source-delivery-component.ps1") -AllowFailure
    if ($component.exitCode -ne 0 -or $component.stdout -notmatch 'function Copy-DeliveryVanessaPairedExtensionFromArchive') {
        throw "DELIVERY_SUPERVISOR_ASSET_UNSUPPORTED: supervisor '$SupervisorCommit' cannot publish the locked Vanessa ZIP and paired CFE. Create a new plan with a published develop supervisor that supports both assets."
    }
}

$supervisorRoot = ""
$supervisorPath = $localSupervisor
$supervisorCommit = ""
$bootstrapSupervisor = $true
try {
    $requestedChannel = if ($Action -in @("Plan", "PublishDevelop")) { "develop" } else { "master" }
    $selectedChannel = $requestedChannel
    $recordedSupervisor = ""
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
        $recordedChannel = if ($savedPlan.supervisor.PSObject.Properties.Name -contains "channel") { [string]$savedPlan.supervisor.channel } else { "" }
        if ($recordedChannel) {
            if ($recordedChannel -notin @("develop", "master") -or
                ($recordedChannel -ne $requestedChannel -and -not ($Action -eq "PublishDevelop" -and $recordedChannel -eq "master"))) {
                throw "DELIVERY_RESUME_PLAN_INVALID: supervisor channel '$recordedChannel' is incompatible with $Action."
            }
            $selectedChannel = $recordedChannel
        } else {
            $masterTip = Get-DeliveryBootstrapTrackingCommit -Branch "master"
            $developTip = Get-DeliveryBootstrapTrackingCommit -Branch "develop"
            if ($masterTip -and (Test-DeliveryBootstrapAncestor -Ancestor $recordedSupervisor -Descendant $masterTip)) {
                $selectedChannel = "master"
            } elseif ($requestedChannel -eq "develop" -and $developTip -and
                (Test-DeliveryBootstrapAncestor -Ancestor $recordedSupervisor -Descendant $developTip)) {
                $selectedChannel = "develop"
            } else {
                throw "DELIVERY_RESUME_SUPERVISOR_UNTRUSTED: recorded supervisor '$recordedSupervisor' is not an ancestor of a permitted authority channel."
            }
        }
    }
    $authorityTip = Get-DeliveryBootstrapTrackingCommit -Branch $selectedChannel
    if ($authorityTip) {
        $supervisorCommit = $authorityTip
        if ($ResumePlan) {
            if (-not (Test-DeliveryBootstrapAncestor -Ancestor $recordedSupervisor -Descendant $authorityTip)) {
                throw "DELIVERY_RESUME_SUPERVISOR_UNTRUSTED: recorded supervisor '$recordedSupervisor' is not an ancestor of origin/$selectedChannel '$authorityTip'."
            }
            $supervisorCommit = $recordedSupervisor
        }
        $previousErrorActionPreference = $ErrorActionPreference
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
    $customGateFixture = [bool]$GateScript -and
        [IO.Path]::GetFullPath($GateScript) -ne [IO.Path]::GetFullPath((Join-Path $candidateRoot "scripts\check.ps1"))
    if ($selectedChannel -eq "develop" -and $bootstrapSupervisor -and -not $customGateFixture) {
        throw "DELIVERY_DEVELOP_SUPERVISOR_UNAVAILABLE: origin/develop must contain a published source-delivery supervisor."
    }
    if ($ResumePlan -and $bootstrapSupervisor) {
        throw "DELIVERY_RESUME_SUPERVISOR_UNTRUSTED: the recorded supervisor is unavailable from origin/$selectedChannel."
    }
    if ($requestedChannel -eq 'develop' -and -not $customGateFixture -and $supervisorCommit) {
        Assert-DeliveryBootstrapPairedAssetSupport -SupervisorCommit $supervisorCommit
    }
    if (-not $supervisorCommit) {
        $previousErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        $supervisorCommit = @(& git -C $candidateRoot rev-parse HEAD 2>$null) | Select-Object -First 1
        $headExitCode = $LASTEXITCODE
        $ErrorActionPreference = $previousErrorActionPreference
        if ($headExitCode -ne 0 -or [string]$supervisorCommit -notmatch '^[a-f0-9]{40}$') {
            throw "Unable to resolve the bootstrap delivery supervisor from the source checkout."
        }
    }
    $arguments = @{}
    foreach ($entry in $PSBoundParameters.GetEnumerator()) { $arguments[$entry.Key] = $entry.Value }
    $arguments["RepositoryRoot"] = $candidateRoot
    $arguments["SupervisorCommit"] = $supervisorCommit
    $arguments["BootstrapSupervisor"] = $bootstrapSupervisor
    # The first published develop supervisor may predate this parameter. Pass
    # the selected authority channel only when that pinned script supports it.
    $tokens = $null
    $parseErrors = $null
    $supervisorAst = [Management.Automation.Language.Parser]::ParseFile($supervisorPath, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) { throw "Delivery supervisor script has parse errors: $supervisorPath" }
    if ($supervisorAst.ParamBlock -and @($supervisorAst.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq "SupervisorChannel" }).Count -gt 0) {
        $arguments["SupervisorChannel"] = $selectedChannel
    }
    & $supervisorPath @arguments
} finally {
    if ($supervisorRoot -and (Test-Path -LiteralPath $supervisorRoot -PathType Container)) {
        & git -C $candidateRoot worktree remove --force -- $supervisorRoot 2>$null
        if ($LASTEXITCODE -ne 0) { Write-Warning "Stable delivery supervisor worktree could not be removed: $supervisorRoot" }
    }
}
