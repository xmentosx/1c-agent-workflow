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
    [string]$AgentTarget = "",
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
    [string]$Replan = "",
    [ValidateSet('Current', 'Frozen')]
    [string]$ReplanQueueScope = 'Current',
    [string]$ApproveLongPlan = "",
    [switch]$RetryBlockedStage,
    [switch]$RequireRelease
)

$deliveryInvocationWatch = [Diagnostics.Stopwatch]::StartNew()
$deliveryPlanResult = $null
$deliveryPlanTiming = [ordered]@{}

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$deliveryUtf8 = New-Object Text.UTF8Encoding($false)
[Console]::InputEncoding = $deliveryUtf8
[Console]::OutputEncoding = $deliveryUtf8
$OutputEncoding = $deliveryUtf8
if (-not $RepositoryRoot) { $RepositoryRoot = Split-Path -Parent $PSScriptRoot }
$candidateRoot = [IO.Path]::GetFullPath($RepositoryRoot)
. (Join-Path $PSScriptRoot 'git-path-list.ps1')
. (Join-Path $PSScriptRoot 'source-proof-json.ps1')
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

function Assert-DeliveryBootstrapAgentTargetSupport {
    param([object]$SupervisorAst, [string]$SupervisorCommit, [Collections.IDictionary]$BoundParameters)
    if ($BoundParameters.Keys -notcontains 'AgentTarget') { return }
    if ($SupervisorAst.ParamBlock -and @($SupervisorAst.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'AgentTarget' }).Count -gt 0) { return }
    throw "DELIVERY_E2E_CLIENT_OPTION_UNSUPPORTED: pinned supervisor '$SupervisorCommit' predates -AgentTarget. Publish the source-only E2E client-selection support through the existing delivery channel, then repeat this same explicit command. For that support publication only, omit -AgentTarget when each target has one configured client and it is the intended client. Do not switch supervisor authority or silently drop an explicit selection."
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
    $requestedChannel = if ($Action -eq 'Cleanup') {
        if ($CleanupChannel -eq 'Master') { 'master' } else { 'develop' }
    } elseif ($Action -in @("RegisterChange", "Plan", "PublishDevelop")) { "develop" } else { "master" }
    $selectedChannel = $requestedChannel
    $recordedSupervisor = ""
    $transferFrozenReplan = $false
    $replanCheckpointSha256 = ''
    if ($Replan -and ($Action -ne 'PublishDevelop' -or $ResumePlan)) { throw '-Replan is valid only for PublishDevelop and cannot be combined with -ResumePlan.' }
    if ($ReplanQueueScope -ne 'Current' -and -not $Replan) { throw '-ReplanQueueScope Frozen requires -Replan.' }
    $activeAttempt = $null
    if ($Action -eq 'PublishDevelop') {
        $commonGitPath = Resolve-DeliveryBootstrapCommonGitDirectory -RepositoryRoot $candidateRoot
        $activeAttemptPath = Join-Path $commonGitPath 'itl/publication-attempts/develop.json'
        if (Test-Path -LiteralPath $activeAttemptPath -PathType Leaf) {
            try { $activeAttempt = Get-Content -LiteralPath $activeAttemptPath -Raw -Encoding UTF8 | ConvertFrom-Json }
            catch { throw "DELIVERY_CHECKPOINT_INVALID: '$activeAttemptPath': $($_.Exception.Message). The checkpoint and queue were preserved." }
        }
        if ($Replan) {
            $ResumePlan = $Replan
            if ($ReplanQueueScope -eq 'Frozen') {
                if (-not $activeAttempt -or -not $activeAttempt.PSObject.Properties['planId']) { throw 'DELIVERY_REPLAN_CHECKPOINT_CHANGED: Frozen requires an active original checkpoint.' }
                if ([string]$activeAttempt.planId -ceq $Replan) {
                    $transferFrozenReplan = $true
                    $replanCheckpointSha256 = Get-DeliveryFileSha256 -Path $activeAttemptPath
                } elseif ($activeAttempt.PSObject.Properties['replacesPlanId'] -and [string]$activeAttempt.replacesPlanId -ceq $Replan -and
                    $activeAttempt.PSObject.Properties['replanQueueScope'] -and [string]$activeAttempt.replanQueueScope -ceq 'Frozen') {
                    $ResumePlan = [string]$activeAttempt.planId
                } else { throw 'DELIVERY_REPLAN_CHECKPOINT_CHANGED: Frozen requires the original checkpoint or its frozen replacement.' }
            }
        }
        elseif (-not $ResumePlan -and $activeAttempt -and $activeAttempt.PSObject.Properties['planId'] -and [string]$activeAttempt.planId) {
            $activePlanPath = Join-Path $commonGitPath "itl/plans/v1/$([string]$activeAttempt.planId).json"
            $activePlan = Get-Content -LiteralPath $activePlanPath -Raw -Encoding UTF8 | ConvertFrom-Json
            # Unpublished custom-gate fixtures retain their bootstrap boundary.
            if (-not [bool]$activePlan.supervisor.bootstrap) {
                $ResumePlan = [string]$activeAttempt.planId
                $PSBoundParameters['ResumePlan'] = $ResumePlan
            }
        }
    }
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
        if ($Action -eq 'PublishDevelop' -and -not $Replan -and -not $savedPlan.PSObject.Properties['queue'] -and $activeAttempt) {
            if (-not $activeAttempt.PSObject.Properties['planId'] -or [string]$activeAttempt.planId -cne $ResumePlan) {
                throw "DELIVERY_LEGACY_CHECKPOINT_CHANGED: requested '$ResumePlan'; active checkpoint has another plan. Both immutable plans and the queue were preserved; continue the active plan shown by Status."
            }
            $expected = @($activeAttempt.queue | Sort-Object id | ForEach-Object { "$($_.id)|$($_.base)|$($_.head)" }) -join "`n"
            $pairs = @{}
            $refs = (Invoke-RepositoryGit -RepositoryRoot $candidateRoot -Arguments @('for-each-ref','--format=%(refname) %(objectname)','refs/itl/develop-queue')).stdout
            foreach ($line in @($refs -split '\r?\n' | Where-Object { $_ })) {
                if ($line -match '^refs/itl/develop-queue/(.+)/(base|head) ([a-f0-9]{40})$') {
                    if (-not $pairs.ContainsKey($Matches[1])) { $pairs[$Matches[1]] = @{} }
                    $pairs[$Matches[1]][$Matches[2]] = $Matches[3]
                }
            }
            $actual = @($pairs.Keys | Sort-Object | ForEach-Object { "$($_)|$($pairs[$_]['base'])|$($pairs[$_]['head'])" }) -join "`n"
            if ($actual -cne $expected) {
                throw "DELIVERY_LEGACY_PLAN_INPUT_CHANGED: queue membership differs from frozen plan '$ResumePlan'. The historical controller was not invoked; its checkpoint and proof were preserved. Review the new registrations, then repeat the same PublishDevelop options with -Replan '$ResumePlan' to create a replacement under the recorded authority."
            }
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
    if ($transferFrozenReplan) { $selectedChannel = 'develop' }
    $authorityTip = Get-DeliveryBootstrapTrackingCommit -Branch $selectedChannel
    if ($authorityTip) {
        $supervisorCommit = $authorityTip
        if ($ResumePlan) {
            if (-not (Test-DeliveryBootstrapAncestor -Ancestor $recordedSupervisor -Descendant $authorityTip)) {
                throw "DELIVERY_RESUME_SUPERVISOR_UNTRUSTED: recorded supervisor '$recordedSupervisor' is not an ancestor of origin/$selectedChannel '$authorityTip'."
            }
            if (-not $transferFrozenReplan) { $supervisorCommit = $recordedSupervisor }
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
    if ($Action -in @('RegisterChange','PublishDevelop')) {
        $queueModule=Join-Path (Split-Path -Parent $supervisorPath) 'source-delivery-queue.ps1'
        $queueDecoder=$null
        if (Test-Path -LiteralPath $queueModule) {
            $queueAst=[Management.Automation.Language.Parser]::ParseFile($queueModule,[ref]$tokens,[ref]$parseErrors)
            $queueDecoder=$queueAst.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-SourceRegistrationSnapshot'},$true)
        }
        if (-not $queueDecoder -and (Invoke-RepositoryGit -RepositoryRoot $candidateRoot -Arguments @('show-ref','--verify','refs/itl/develop-candidate/state') -AllowFailure).exitCode -eq 0) {
            throw "DELIVERY_LEGACY_CONTROLLER_PROTOCOL: recorded controller '$supervisorCommit' predates the accepted candidate protocol. Its closed plan cannot write the new queue. Continue current PublishDevelop without that closed ResumePlan; retain the compatible queue decoder in a functional rollback. Accepted commits, immutable plans and proof were preserved."
        }
    }
    Assert-DeliveryBootstrapAgentTargetSupport -SupervisorAst $supervisorAst -SupervisorCommit $supervisorCommit -BoundParameters $arguments
    if ($ReplanQueueScope -eq 'Frozen') {
        foreach ($requiredParameter in @('ReplanQueueScope','ReplanCheckpointSha256')) {
            if (@($supervisorAst.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq $requiredParameter }).Count -eq 0) {
                throw "DELIVERY_FROZEN_REPLAN_UNSUPPORTED: published supervisor '$supervisorCommit' lacks frozen recovery support. Publish support separately, then repeat this command; the original checkpoint and queue were preserved."
            }
        }
        if ($transferFrozenReplan) { $arguments['ReplanCheckpointSha256'] = $replanCheckpointSha256 }
    } else { $arguments.Remove('ReplanQueueScope') }
    if ($Replan -and @($supervisorAst.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Replan' }).Count -eq 0) {
        if ($savedPlan.PSObject.Properties['queue']) { throw "DELIVERY_REPLAN_UNSUPPORTED: recorded supervisor '$supervisorCommit' cannot replace this frozen plan. Its checkpoint and queue were preserved." }
        if ($activeAttempt -and [string]$activeAttempt.planId -cne $Replan) { throw "DELIVERY_REPLAN_CHECKPOINT_CHANGED: continue active plan '$([string]$activeAttempt.planId)' before replacing another plan." }
        # An explicit legacy replacement uses that owner's original rebuild;
        # its immutable original plan/evidence and all queue refs are retained.
        $arguments.Remove('Replan')
    }
    if ($supervisorAst.ParamBlock -and @($supervisorAst.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq "SupervisorChannel" }).Count -gt 0) {
        $arguments["SupervisorChannel"] = $selectedChannel
    }
    $ownerPlanModule=Join-Path (Split-Path -Parent $supervisorPath) 'source-delivery-plan.ps1'
    $legacyCalculator=$false
    if($Action -eq 'Plan' -and -not $customGateFixture -and (Test-Path -LiteralPath $ownerPlanModule)) {
        $ownerPlanSource=[IO.File]::ReadAllText($ownerPlanModule)
        # Opaque/historical supervisors keep their own Plan protocol. Only the
        # standard module promises the readers used by the advisory bridge.
        $legacyCalculator=$ownerPlanSource -match '(?m)^function New-AccumulatedDeliveryPlan \{' -and
            $ownerPlanSource.Contains('Get-SourceRegistrationSnapshot') -and
            $ownerPlanSource.Contains('Get-SourceRegistrationStartPoint') -and
            ($ownerPlanSource -notmatch '(?m)^function Invoke-DeliveryCandidatePlanCalculation \{' -or
             $ownerPlanSource -notmatch '(?m)^function Invoke-DeliveryCandidateComponentPlan \{')
    }
    # Non-Plan options still reach the owner's normal validation. The read-only
    # bridge accepts only the standard planning interface, including RequireRelease.
    $planOptions=@('Action','RepositoryRoot','Remote','AiRulesSource','E2EProjectRoot','AgentTarget','FreshProjectsRoot','RequireRelease')
    if(@($PSBoundParameters.Keys | Where-Object {$_ -notin $planOptions}).Count) {$legacyCalculator=$false}
    $deliveryPlanTiming['supervisorPreparationDurationMs'] = $deliveryInvocationWatch.ElapsedMilliseconds
    $deliverySupervisedPlanWatch = [Diagnostics.Stopwatch]::StartNew()
    if($legacyCalculator) {
        $readerArguments=@{Action='Status'}
        foreach($name in @('RepositoryRoot','Remote','SupervisorCommit','SupervisorChannel','BootstrapSupervisor','AiRulesSource','E2EProjectRoot','AgentTarget','FreshProjectsRoot')) {
            if($arguments.ContainsKey($name)) {$readerArguments[$name]=$arguments[$name]}
        }
        $plan=& {
            param($owner,$readerOptions,$module,$release)
            # Load the pinned owner's readers once. Queue reconstruction and
            # preflight remain its functions; the preview cannot persist a plan.
            . $owner @readerOptions > $null
            . $module
            New-AccumulatedDeliveryPlan -RequireRelease:$release -PreviewOnly
        } $supervisorPath $readerArguments (Join-Path $PSScriptRoot 'source-delivery-plan.ps1') ([bool]$RequireRelease)
        $deliveryPlanResult = $plan
    } elseif ($Action -eq 'Plan') {
        $deliveryPlanJson = & $supervisorPath @arguments
        $deliveryPlanResult = ($deliveryPlanJson -join [Environment]::NewLine) | ConvertFrom-Json
    } else { & $supervisorPath @arguments }
    $deliveryPlanTiming['supervisedPlanDurationMs'] = $deliverySupervisedPlanWatch.ElapsedMilliseconds
} finally {
    $deliveryCleanupWatch = [Diagnostics.Stopwatch]::StartNew()
    if ($supervisorRoot -and (Test-Path -LiteralPath $supervisorRoot -PathType Container)) {
        & git -C $candidateRoot worktree remove --force -- $supervisorRoot 2>$null
        if ($LASTEXITCODE -ne 0) { Write-Warning "Stable delivery supervisor worktree could not be removed: $supervisorRoot" }
    }
}

if ($Action -eq 'Plan' -and $null -ne $deliveryPlanResult) {
    $deliveryPlanTiming['supervisorCleanupDurationMs'] = $deliveryCleanupWatch.ElapsedMilliseconds
    $deliveryPlanTiming['invocationDurationMs'] = $deliveryInvocationWatch.ElapsedMilliseconds
    $deliveryPlanResult | Add-Member -NotePropertyName invocationTiming -NotePropertyValue ([pscustomobject]$deliveryPlanTiming) -Force
    $deliveryPlanResult | ConvertTo-Json -Depth 24
}
