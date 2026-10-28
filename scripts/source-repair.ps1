[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('Start', 'Run', 'Finish')][string]$Action,
    [string]$RepairRoot = '',
    [string]$E2EProjectRoot = '',
    [string]$AiRulesSource = '',
    [string]$AgentTarget = '',
    [string]$FreshProjectsRoot = 'C:\itlj',
    [ValidateSet('', 'upgrade', 'fresh')][string]$Journey = '',
    [string]$Scenario = '',
    [string[]]$Test = @(),
    [switch]$Unproven,
    [ValidateRange(1, 4)][int]$PesterWorkers = 3,
    [string]$QueueId = '',
    [string[]]$CoverageContract = @(),
    [string]$ApproveLongPlan = ''
)

# Repair loop for a failed frozen develop publication. It owns no state: the
# publication checkpoint, queue, plan, proof stores and stands stay with their
# existing owners. Run executes only the named failed checks from the repair
# worktree; Finish performs the one registration and frozen replacement.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$utf8 = New-Object Text.UTF8Encoding($false)
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8

. (Join-Path $PSScriptRoot 'git-path-list.ps1')
$script:ToolRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$script:CommonGit = Get-RepositoryCommonGitDirectory -RepositoryRoot $script:ToolRoot
function Get-DeliveryCommonGitDirectory { return $script:CommonGit }
. (Join-Path $PSScriptRoot 'source-delivery-process.ps1')
. (Join-Path $PSScriptRoot 'source-e2e-artifact-discovery.ps1')
. (Join-Path $PSScriptRoot 'stand-env-identity.ps1')
. (Join-Path $PSScriptRoot 'quality-contracts.ps1')

function Get-RepairGitValue {
    param([string]$Root, [string[]]$Arguments)
    return (Invoke-RepositoryGit -RepositoryRoot $Root -Arguments $Arguments).stdout.Trim()
}

function Test-RepairAncestor {
    param([string]$Root, [string]$Ancestor, [string]$Descendant)
    return (Invoke-RepositoryGit -RepositoryRoot $Root -Arguments @('merge-base', '--is-ancestor', $Ancestor, $Descendant) -AllowFailure).exitCode -eq 0
}

function Assert-RepairNoActiveDelivery {
    $operation = Get-DeliveryOperationStatus
    if ($operation -and [string]$operation.status -ceq 'running') {
        throw "REPAIR_DELIVERY_ACTIVE: $($operation.action) operation '$($operation.id)' (owner PID $($operation.ownerPid)) is running and owns the stands. Wait for it to finish or fail, then repeat the same command."
    }
}

function Get-RepairAttempt {
    $path = Join-Path $script:CommonGit 'itl\publication-attempts\develop.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'REPAIR_NO_PUBLICATION: no develop publication checkpoint exists; repair applies only to a failed PublishDevelop.' }
    $attempt = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([int]$attempt.schemaVersion -ne 1 -or [string]$attempt.candidate -notmatch '^[a-f0-9]{40}$' -or [string]$attempt.planId -notmatch '^[a-f0-9]{64}$') {
        throw "REPAIR_PUBLICATION_UNSUPPORTED: '$path' has no candidate/plan identity this repair loop can extend."
    }
    if (-not $attempt.PSObject.Properties['replanQueueScope'] -or [string]$attempt.replanQueueScope -cne 'Frozen') {
        throw 'REPAIR_PUBLICATION_NOT_FROZEN: freeze the publication first through PublishDevelop -Replan <plan> -ReplanQueueScope Frozen.'
    }
    return $attempt
}

function Resolve-RepairRoot {
    param([object]$Attempt, [switch]$AllowAccepted)
    if (-not $RepairRoot) { throw 'REPAIR_ROOT_REQUIRED: pass -RepairRoot printed by -Action Start.' }
    $root = [IO.Path]::GetFullPath($RepairRoot)
    if (-not (Test-Path -LiteralPath (Join-Path $root '.git'))) { throw "REPAIR_ROOT_INVALID: '$root' is not a Git worktree." }
    if ((Get-RepositoryCommonGitDirectory -RepositoryRoot $root) -ine $script:CommonGit) { throw "REPAIR_ROOT_FOREIGN: '$root' belongs to another repository." }
    $head = Get-RepairGitValue $root @('rev-parse', 'HEAD')
    # After an accepted replacement the new candidate contains the pinned head.
    $accepted = $AllowAccepted -and @($Attempt.queue | Where-Object { [string]$_.head -ceq $head }).Count -eq 1
    if (-not $accepted -and -not (Test-RepairAncestor $root ([string]$Attempt.candidate) $head)) {
        throw "REPAIR_BASE_CHANGED: '$root' does not contain the current publication candidate $($Attempt.candidate). Repeat -Action Start to bring it forward."
    }
    if (@(Get-RepositoryGitPathList -RepositoryRoot $root -Arguments @('status', '--porcelain=v1', '--untracked-files=all', '-z')).Count) {
        throw 'REPAIR_UNCOMMITTED: commit the repair locally first. A local commit needs no registration; proof is saved only for a clean committed tree.'
    }
    return [pscustomobject]@{ root = $root; head = $head }
}

function Invoke-RepairChild {
    param([string]$Root, [string]$ScriptPath, [string[]]$Arguments = @(), [string]$LogName, [int]$TimeoutSeconds = 0)
    $stdout = Join-Path $script:OutputRoot ($LogName + '.stdout.log')
    $stderr = Join-Path $script:OutputRoot ($LogName + '.stderr.log')
    $parts = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (ConvertTo-GitProcessArgument $ScriptPath))
    foreach ($argument in @($Arguments)) { $parts += (ConvertTo-GitProcessArgument ([string]$argument)) }
    $modulePath = $env:PSModulePath
    $core = [string]$PSVersionTable.PSEdition -eq 'Core'
    try {
        # Windows PowerShell children must not inherit Core-only module roots.
        if ($core) {
            $coreModules = [IO.Path]::GetFullPath((Join-Path $PSHOME 'Modules')).TrimEnd('\')
            $env:PSModulePath = @($modulePath -split ';' | Where-Object {
                $_ -and -not [string]::Equals(([IO.Path]::GetFullPath($_).TrimEnd('\')), $coreModules, [StringComparison]::OrdinalIgnoreCase)
            }) -join ';'
        }
        $process = Start-Process -FilePath 'powershell.exe' -ArgumentList ($parts -join ' ') -WorkingDirectory $Root -WindowStyle Hidden `
            -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
    } finally { if ($core) { $env:PSModulePath = $modulePath } }
    $null = $process.Handle
    Write-Host "[$LogName] log: $stdout"
    $finished = if ($TimeoutSeconds -gt 0) { $process.WaitForExit($TimeoutSeconds * 1000) } else { $process.WaitForExit(); $true }
    if (-not $finished) {
        & taskkill.exe /PID ([int]$process.Id) /T /F *> $null
        try { $process.WaitForExit() } catch {}
        throw "REPAIR_CHILD_TIMEOUT: $LogName exceeded its $TimeoutSeconds second owner budget. See $stdout and $stderr."
    }
    $process.WaitForExit()
    return [pscustomobject]@{ exitCode = [int]$process.ExitCode; stdout = $stdout; stderr = $stderr }
}

function Write-RepairChildFailure {
    param([object]$Result, [string]$Label)
    $tail = if (Test-Path -LiteralPath $Result.stderr -PathType Leaf) { @([IO.File]::ReadAllLines($Result.stderr, [Text.Encoding]::UTF8) | Select-Object -Last 20) -join [Environment]::NewLine } else { '' }
    Write-Host "$Label failed (exit $($Result.exitCode)). stdout: $($Result.stdout)"
    if ($tail) { Write-Host $tail }
}

function New-RepairOutputRoot {
    param([string]$Root)
    $path = Join-Path $Root ('build\test-results\repair\' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))
    [void][IO.Directory]::CreateDirectory($path)
    return $path
}

function Get-RepairQueueId {
    param([object]$Attempt, [string]$Head)
    # A repeated Finish keeps the id already accepted for this exact head.
    $member = @($Attempt.queue | Where-Object { [string]$_.head -ceq $Head })
    $id = if ($QueueId) { $QueueId } elseif ($member.Count -eq 1) { [string]$member[0].id } else { 'repair-' + ([string]$Attempt.candidate).Substring(0, 8) }
    if ($id -cnotmatch '^[a-z0-9][a-z0-9._-]*$') { throw 'REPAIR_QUEUE_ID_INVALID: use lowercase letters, digits, dot, underscore or dash.' }
    return $id
}

function Show-RepairFailure {
    param([object]$Attempt)
    $read = Read-DeliveryRunHotIndex -IgnoreSourceStamp
    if ([string]$read.status -cne 'ready') { Write-Host "Run index is $($read.status); inspect source-delivery Status for the failed stage."; return }
    $run = @($read.index.entries | Where-Object { [string]$_.commit -ceq [string]$Attempt.candidate -and [string]$_.mode -ne 'Targeted' } |
        Sort-Object { ConvertTo-DeliveryUtcDateTime -Value $_.startedAt } | Select-Object -Last 1)
    if (-not $run.Count) { Write-Host 'No gate run is recorded for this candidate yet.'; return }
    Write-Host "Last $($run[0].mode) run for the candidate: $($run[0].status) at $($run[0].startedAt)."
    foreach ($stage in @($run[0].stages | Where-Object { [string]$_.status -eq 'failed' })) {
        Write-Host "  failed stage '$($stage.name)': $($stage.reason)"
        if ($stage.PSObject.Properties['detail'] -and $stage.detail) { Write-Host "    $($stage.detail)" }
    }
}

function Invoke-RepairStart {
    Assert-RepairNoActiveDelivery
    $attempt = Get-RepairAttempt
    $candidate = [string]$attempt.candidate
    $short = $candidate.Substring(0, 8)
    $root = if ($RepairRoot) { [IO.Path]::GetFullPath($RepairRoot) } else {
        $main = Split-Path -Parent $script:CommonGit
        Join-Path (Split-Path -Parent $main) ((Split-Path -Leaf $main) + '-repair')
    }
    if (Test-Path -LiteralPath $root) {
        if ((Get-RepositoryCommonGitDirectory -RepositoryRoot $root) -ine $script:CommonGit) { throw "REPAIR_ROOT_FOREIGN: '$root' exists and belongs to another repository." }
        $head = Get-RepairGitValue $root @('rev-parse', 'HEAD')
        if (-not (Test-RepairAncestor $root $candidate $head)) {
            # An accepted replacement merges the repair into a new candidate;
            # bring the repair branch forward without rewriting its commits.
            if (-not (Test-RepairAncestor $root $head $candidate)) { throw "REPAIR_DIVERGED: '$root' has commits outside candidate $short. Remove that worktree or pass another -RepairRoot." }
            [void](Invoke-RepositoryGit -RepositoryRoot $root -Arguments @('merge', '--ff-only', '--quiet', $candidate))
        }
    } else {
        $branch = "itl/repair/$short"
        [void](Invoke-RepositoryGit -RepositoryRoot $script:ToolRoot -Arguments @('worktree', 'add', '-b', $branch, $root, $candidate))
    }
    Write-Host "Repair worktree: $root"
    Write-Host "Publication plan $($attempt.planId), candidate $candidate."
    Show-RepairFailure -Attempt $attempt
    Write-Host 'Fix and commit locally there, then repeat only the failed check:'
    Write-Host "  source-repair.ps1 -Action Run -RepairRoot `"$root`" -Test <File.Tests.ps1>"
    Write-Host "  source-repair.ps1 -Action Run -RepairRoot `"$root`" -Journey <upgrade|fresh> -E2EProjectRoot <stand> -AiRulesSource <fork> -AgentTarget <client>"
    Write-Host 'A repeated journey run narrows itself to scenarios without proof for the current tree. Before Finish, run -Unproven with the same stand options.'
    return [pscustomobject]@{ status = 'ready'; repairRoot = $root; candidate = $candidate; planId = [string]$attempt.planId }
}

function Invoke-RepairTests {
    param([string]$Root, [string[]]$Names)
    # powershell.exe -File passes a comma list as one string.
    $tests = @(foreach ($name in @($Names | ForEach-Object { ([string]$_).Split(',') } | Where-Object { $_.Trim() })) {
        $leaf = Split-Path -Leaf ([string]$name).Trim()
        $relative = 'tests/pester/' + $leaf
        if (-not (Test-Path -LiteralPath (Join-Path $Root $relative) -PathType Leaf)) { throw "REPAIR_TEST_MISSING: $relative" }
        $relative
    })
    $selectionPath = Join-Path $script:OutputRoot 'pester-selection.json'
    # Schema 1 adds no selection inputs, so each passed file is stored under the
    # same shard key that the complete static inventory consumes.
    $selection = [ordered]@{ schemaVersion = 1; paths = @('<repair>'); contracts = @(); tests = @($tests | Sort-Object -Unique) }
    [IO.File]::WriteAllText($selectionPath, ($selection | ConvertTo-Json -Depth 4), $utf8)
    $arguments = @('-RepositoryRoot', $Root, '-OutputRoot', $script:OutputRoot, '-JunitPath', (Join-Path $script:OutputRoot 'pester.junit.xml'),
        '-SelectionPath', $selectionPath, '-WorkerCount', [string]$PesterWorkers)
    if ($AiRulesSource) { $arguments += @('-AiRulesSource', [IO.Path]::GetFullPath($AiRulesSource)) }
    $result = Invoke-RepairChild -Root $Root -ScriptPath (Join-Path $Root 'scripts\invoke-pester-shards.ps1') -Arguments $arguments -LogName 'pester'
    $summaryPath = Join-Path $script:OutputRoot 'pester-shards\summary.json'
    $summary = if (Test-Path -LiteralPath $summaryPath -PathType Leaf) { Get-Content -LiteralPath $summaryPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
    $passed = $result.exitCode -eq 0 -and $summary -and [string]$summary.status -eq 'passed'
    if (-not $passed) { Write-RepairChildFailure -Result $result -Label 'Pester' }
    return [pscustomobject]@{ status = $(if ($passed) { 'passed' } else { 'failed' }); tests = @($selection.tests); summary = $summaryPath }
}

function Get-RepairUnprovenTests {
    param([string]$Root)
    # The shard owner decides reuse; repeat only the files it would execute.
    $arguments = @('-RepositoryRoot', $Root, '-OutputRoot', (Join-Path $script:OutputRoot 'plan'), '-JunitPath', (Join-Path $script:OutputRoot 'plan\junit.xml'), '-PlanOnly')
    if ($AiRulesSource) { $arguments += @('-AiRulesSource', [IO.Path]::GetFullPath($AiRulesSource)) }
    $result = Invoke-RepairChild -Root $Root -ScriptPath (Join-Path $Root 'scripts\invoke-pester-shards.ps1') -Arguments $arguments -LogName 'pester-plan'
    $text = [IO.File]::ReadAllText($result.stdout, [Text.Encoding]::UTF8)
    $start = $text.IndexOf('{')
    if ($result.exitCode -ne 0 -or $start -lt 0) { Write-RepairChildFailure -Result $result -Label 'Pester plan'; throw 'REPAIR_PESTER_PLAN_FAILED: the shard owner could not plan the static inventory.' }
    $plan = $text.Substring($start) | ConvertFrom-Json
    return @($plan.files | Where-Object { [string]$_.execution -eq 'execute' } | ForEach-Object { Split-Path -Leaf ([string]$_.path) })
}

function Get-RepairJourneyScenarios {
    param([string]$Root, [string]$Name, [string]$Stand)
    $catalog = Get-Content -LiteralPath (Join-Path $Root 'tests\quality-contracts.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $ids = @($catalog.developJourneys.scenarios.$Name | ForEach-Object { [string]$_.id })
    $descriptor = Get-Content -LiteralPath (Join-Path $Stand '.agent-1c\release-e2e.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    # The journey owner omits the negative scenario when the stand declares none.
    if (-not $descriptor.PSObject.Properties['developConfigurationRejection']) { $ids = @($ids | Where-Object { $_ -ne 'configuration-rejection' }) }
    return $ids
}

function Get-RepairJourneyEvidence {
    param([string]$Root, [string]$Name)
    # Read only this repair worktree's own journey reports, oldest first.
    $tree = Get-RepairGitValue $Root @('rev-parse', 'HEAD^{tree}')
    $proven = @(); $latest = $null
    $reports = Join-Path $Root 'build\test-results\repair'
    $paths = if (Test-Path -LiteralPath $reports -PathType Container) { @(Get-ChildItem -LiteralPath $reports -Directory | Sort-Object Name | ForEach-Object { Join-Path $_.FullName "develop-e2e-$Name-raw.json" } | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }) } else { @() }
    foreach ($path in $paths) {
        $report = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        $journey = @($report.journeys | Where-Object { [string]$_.name -eq $Name })
        if ($journey.Count -ne 1) { continue }
        $latest = [pscustomobject]@{ report = $report; journey = $journey[0] }
        # The journey owner stored reusable proof only for a clean passed tree.
        if ([string]$report.status -eq 'passed' -and [string]$report.candidate.tree -ceq $tree -and (Test-Path -LiteralPath "$path.$Name.qualification.json" -PathType Leaf)) {
            $proven += @($journey[0].coverage)
        }
    }
    # A negative scenario that already passed in the latest failed run waits for
    # -Unproven, so the next repair repeats only the part that failed.
    $deferred = @()
    if ($latest -and [string]$latest.report.status -ne 'passed' -and $latest.journey.PSObject.Properties['configurationRejection'] -and
        [string]$latest.journey.configurationRejection.status -eq 'passed') { $deferred = @('configuration-rejection') }
    return [pscustomobject]@{ proven = @($proven | Sort-Object -Unique); deferred = $deferred }
}

function Invoke-RepairJourney {
    param([string]$Root, [string]$Name, [string]$Selection = '', [switch]$Unproven)
    if (-not $E2EProjectRoot -or -not $AiRulesSource) { throw 'REPAIR_STAND_REQUIRED: pass the same -E2EProjectRoot, -AiRulesSource and -AgentTarget as the publication.' }
    $stand = [IO.Path]::GetFullPath($E2EProjectRoot)
    $fork = [IO.Path]::GetFullPath($AiRulesSource)
    if (-not $Selection) {
        $all = @(Get-RepairJourneyScenarios -Root $Root -Name $Name -Stand $stand)
        $evidence = Get-RepairJourneyEvidence -Root $Root -Name $Name
        $open = @($all | Where-Object { $_ -notin $evidence.proven })
        if (-not $open.Count) {
            Write-Host "Develop ${Name}: every scenario already has reusable proof for this tree."
            return [pscustomobject]@{ status = 'passed'; journey = $Name; scenario = ''; raw = ''; reusableProof = $true; skipped = $true }
        }
        $narrowed = @(if ($Unproven) { $open } else { $open | Where-Object { $_ -notin $evidence.deferred } })
        if ($narrowed.Count) { $open = $narrowed }
        # Dependencies are expanded by the journey owner.
        if ($open.Count -lt $all.Count) { $Selection = $open -join ',' }
        Write-Host "Develop ${Name}: scenarios $($open -join ', ')."
    }
    $missing = ''
    $binding = Find-SourceE2EArtifactBinding -RepositoryRoot $Root -MissingInput ([ref]$missing)
    if (-not $binding) { throw "REPAIR_ARTIFACT_MISSING: locked artifact '$missing' was not found by SHA. Set that environment variable to the exact locked file, or let one gate run prepare it, then repeat." }
    $bindingPath = Join-Path $script:OutputRoot 'source-e2e-artifacts.json'
    [IO.File]::WriteAllText($bindingPath, ($binding | ConvertTo-Json -Depth 5), $utf8)
    $fixture = Join-Path $Root 'scripts\source-e2e-fixture.ps1'
    # Mirror the gate: both phase baselines are captured before Develop identity.
    $captures = @(@('Release', $stand, 'fixture-release'), @('Develop', $stand, 'fixture-develop'))
    $positive = Get-DevelopPositiveStandRoot -ProjectRoot $stand -Config (Get-Content -LiteralPath (Join-Path $stand '.agent-1c\release-e2e.json') -Raw -Encoding UTF8 | ConvertFrom-Json)
    if ($positive) { $captures += , @('Develop', $positive, 'fixture-positive') }
    foreach ($capture in $captures) {
        $arguments = @('-Action', 'Capture', '-Phase', $capture[0], '-ProjectRoot', $capture[1], '-AgentTarget', $AgentTarget, '-OutputPath', (Join-Path $script:OutputRoot ($capture[2] + '-capsule.json')))
        $result = Invoke-RepairChild -Root $Root -ScriptPath $fixture -Arguments $arguments -LogName $capture[2] -TimeoutSeconds 7800
        if ($result.exitCode -ne 0) { Write-RepairChildFailure -Result $result -Label $capture[2]; return [pscustomobject]@{ status = 'failed'; journey = $Name; stage = $capture[2] } }
    }
    $catalog = Get-Content -LiteralPath (Join-Path $Root 'tests\quality-contracts.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $rawPath = Join-Path $script:OutputRoot "develop-e2e-$Name-raw.json"
    $arguments = @('-CandidateRoot', $Root, '-ProjectRoot', $stand, '-AiRulesSource', $fork, '-OutputPath', $rawPath, '-Journey', $Name,
        '-FreshProjectsRoot', $FreshProjectsRoot, '-ArtifactBindingPath', $bindingPath)
    if ($Selection) { $arguments += @('-Scenario', $Selection) }
    if ($AgentTarget) { $arguments += @('-AgentTarget', $AgentTarget) }
    $result = Invoke-RepairChild -Root $Root -ScriptPath (Join-Path $Root 'scripts\invoke-develop-e2e.ps1') -Arguments $arguments -LogName "develop-e2e-$Name" `
        -TimeoutSeconds (Get-DevelopE2EJourneyHardBudgetSeconds -Catalog $catalog -Journey $Name)
    $raw = if (Test-Path -LiteralPath $rawPath -PathType Leaf) { Get-Content -LiteralPath $rawPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
    $passed = $result.exitCode -eq 0 -and $raw -and [string]$raw.status -eq 'passed'
    if (-not $passed) { Write-RepairChildFailure -Result $result -Label "Develop $Name" }
    # invoke-develop-e2e stores reusable scenario proof only for a clean tree
    # with complete unchanged inputs; otherwise the final gate executes it.
    $proof = "$rawPath.$Name.qualification.json"
    $reusable = $passed -and (Test-Path -LiteralPath $proof -PathType Leaf)
    if ($passed -and -not $reusable) { Write-Host 'Journey passed, but no reusable proof was stored; the final gate will execute it again.' }
    return [pscustomobject]@{ status = $(if ($passed) { 'passed' } else { 'failed' }); journey = $Name; scenario = $Selection; raw = $rawPath; reusableProof = $reusable }
}

function Invoke-RepairRun {
    if (-not $Test.Count -and -not $Journey -and -not $Unproven) { throw 'REPAIR_TARGET_REQUIRED: name the failed -Test files and/or -Journey, or use -Unproven before Finish.' }
    if ($Scenario -and -not $Journey) { throw 'REPAIR_SCENARIO_REQUIRES_JOURNEY' }
    Assert-RepairNoActiveDelivery
    $attempt = Get-RepairAttempt
    $repair = Resolve-RepairRoot -Attempt $attempt
    $script:OutputRoot = New-RepairOutputRoot -Root $repair.root
    $tests = @($Test)
    $journeys = @(if ($Journey) { $Journey })
    if ($Unproven) {
        if (-not $E2EProjectRoot -or -not $AiRulesSource) { throw 'REPAIR_STAND_REQUIRED: -Unproven also runs journeys; pass the publication -E2EProjectRoot, -AiRulesSource and -AgentTarget.' }
        $tests += @(Get-RepairUnprovenTests -Root $repair.root)
        if (-not $Journey) { $journeys = @('upgrade', 'fresh') }
        Write-Host "Unproven: $(@($tests | Where-Object { $_ }).Count) Pester file(s); journeys $($journeys -join ', ')."
    }
    $results = @()
    if (@($tests | Where-Object { $_ }).Count) { $results += Invoke-RepairTests -Root $repair.root -Names $tests }
    foreach ($name in $journeys) {
        # Stop at the first failure: later checks may depend on its repair.
        if (@($results | Where-Object status -ne 'passed').Count) { break }
        $results += Invoke-RepairJourney -Root $repair.root -Name $name -Selection $Scenario -Unproven:$Unproven
    }
    $status = if (@($results | Where-Object status -ne 'passed').Count) { 'failed' } else { 'passed' }
    if ($status -eq 'passed') { Write-Host "Passed at $($repair.head). Run -Unproven before -Action Finish so the final gate only confirms." }
    return [pscustomobject]@{ status = $status; head = $repair.head; output = $script:OutputRoot; results = $results }
}

function Invoke-RepairFinish {
    if (-not $E2EProjectRoot -or -not $AiRulesSource) { throw 'REPAIR_STAND_REQUIRED: pass the same -E2EProjectRoot, -AiRulesSource and -AgentTarget as the publication.' }
    Assert-RepairNoActiveDelivery
    $attempt = Get-RepairAttempt
    $repair = Resolve-RepairRoot -Attempt $attempt -AllowAccepted
    $id = Get-RepairQueueId -Attempt $attempt -Head $repair.head
    $pin = "$id@$($repair.head)"
    $accepted = @($attempt.queue | Where-Object { [string]$_.id -ceq $id -and [string]$_.head -ceq $repair.head }).Count -eq 1
    # A repeated Finish after an accepted replacement continues it with the
    # same original plan and pin; the supervisor re-validates both.
    $replan = if ($accepted) { [string]$attempt.replacesPlanId } else { [string]$attempt.planId }
    if (-not $accepted -and $repair.head -ceq [string]$attempt.candidate) { throw 'REPAIR_EMPTY: the repair worktree has no commits beyond the candidate.' }
    $script:OutputRoot = New-RepairOutputRoot -Root $repair.root
    $delivery = Join-Path $repair.root 'scripts\source-delivery.ps1'
    $registered = (Invoke-RepositoryGit -RepositoryRoot $repair.root -Arguments @('rev-parse', '--verify', '--quiet', "refs/itl/develop-queue/$id/head") -AllowFailure).stdout.Trim()
    if (-not $accepted -and $registered -cne $repair.head) {
        $arguments = @('-Action', 'RegisterChange', '-RepositoryRoot', $repair.root, '-QueueId', $id, '-BaseRef', [string]$attempt.candidate)
        if ($CoverageContract.Count) { $arguments += @('-CoverageContract', ($CoverageContract -join ',')) }
        $result = Invoke-RepairChild -Root $repair.root -ScriptPath $delivery -Arguments $arguments -LogName 'register'
        if ($result.exitCode -ne 0) { Write-RepairChildFailure -Result $result -Label 'RegisterChange'; return [pscustomobject]@{ status = 'failed'; stage = 'register'; pin = $pin } }
    }
    $arguments = @('-Action', 'PublishDevelop', '-RepositoryRoot', $repair.root, '-AiRulesSource', ([IO.Path]::GetFullPath($AiRulesSource)),
        '-E2EProjectRoot', ([IO.Path]::GetFullPath($E2EProjectRoot)), '-FreshProjectsRoot', $FreshProjectsRoot,
        '-Replan', $replan, '-ReplanQueueScope', 'Frozen', '-FrozenRepair', $pin)
    if ($AgentTarget) { $arguments += @('-AgentTarget', $AgentTarget) }
    if ($attempt.PSObject.Properties['fullReleaseRequested'] -and [bool]$attempt.fullReleaseRequested) { $arguments += '-RequireRelease' }
    if ($ApproveLongPlan) { $arguments += @('-ApproveLongPlan', $ApproveLongPlan) }
    $result = Invoke-RepairChild -Root $repair.root -ScriptPath $delivery -Arguments $arguments -LogName 'publish'
    if ($result.exitCode -ne 0) {
        Write-RepairChildFailure -Result $result -Label 'PublishDevelop'
        Write-Host 'If the plan needs long-plan approval, repeat Finish with -ApproveLongPlan <planId>. After another gate failure, repeat Start for the new candidate.'
    }
    return [pscustomobject]@{ status = $(if ($result.exitCode -eq 0) { 'published' } else { 'failed' }); stage = 'publish'; pin = $pin; replan = $replan; stdout = $result.stdout }
}

$result = switch ($Action) {
    'Start' { Invoke-RepairStart }
    'Run' { Invoke-RepairRun }
    'Finish' { Invoke-RepairFinish }
}
$result | ConvertTo-Json -Depth 6
if ([string]$result.status -eq 'failed') { exit 1 }
