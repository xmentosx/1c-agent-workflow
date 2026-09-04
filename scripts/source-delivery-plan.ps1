Set-StrictMode -Version Latest
$script:DeliveryTrackedPathCache = @{}

function Get-DeliveryPlanRoot {
    $root = Join-Path (Get-DeliveryCommonGitDirectory) "itl\plans\v1"
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    return $root
}

function Get-DeliveryEvidenceRoot {
    $root = Join-Path (Get-DeliveryCommonGitDirectory) "itl\evidence\v1"
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    return $root
}

function Get-DeliveryCanonicalJsonSha256 {
    param([Parameter(Mandatory = $true)][object]$Value)
    $json = $Value | ConvertTo-Json -Depth 24 -Compress
    return Get-DeliveryTextSha256 -Text $json
}

function Get-DeliveryPlanIdentity {
    param([Parameter(Mandatory = $true)][object]$Plan)
    return [ordered]@{
        protocolVersion=1; supervisorCommit=[string]$Plan.supervisor.commit
        candidateCommit=[string]$Plan.candidate.commit; candidateTree=[string]$Plan.candidate.tree; baseCommit=[string]$Plan.candidate.baseCommit
        requireRelease=[bool]$Plan.requireRelease; paths=@($Plan.paths); contracts=@($Plan.contracts); stages=@($Plan.stages | ForEach-Object {
            [ordered]@{ id=[string]$_.id; version=[int]$_.version; mode=[string]$_.mode; dependsOn=@($_.dependsOn); budgetSeconds=[int]$_.budgetSeconds; alwaysExecute=[bool]($_.PSObject.Properties["alwaysExecute"] -and [bool]$_.alwaysExecute); inputFingerprint=[string]$_.inputFingerprint }
        })
    }
}

function Get-DeliveryStageEvidencePath {
    param([Parameter(Mandatory = $true)][string]$StageId, [Parameter(Mandatory = $true)][string]$Fingerprint)
    $safeStage = $StageId -replace '[^A-Za-z0-9._-]', '-'
    return Join-Path (Get-DeliveryEvidenceRoot) "$safeStage\$Fingerprint\evidence.json"
}

function Test-DeliveryStageEvidence {
    param([Parameter(Mandatory = $true)][string]$StageId, [Parameter(Mandatory = $true)][string]$Fingerprint)
    $path = Get-DeliveryStageEvidencePath -StageId $StageId -Fingerprint $Fingerprint
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try {
        $record = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([int]$record.schemaVersion -ne 1 -or [string]$record.status -ne "passed" -or
            [string]$record.stageId -ne $StageId -or [string]$record.inputFingerprint -ne $Fingerprint) { return $null }
        if ([string]$record.proof.path) {
            $proofPath = [string]$record.proof.path
            if (-not (Test-Path -LiteralPath $proofPath -PathType Leaf) -or
                (Get-DeliveryFileSha256 -Path $proofPath) -ne ([string]$record.proof.sha256).ToLowerInvariant()) { return $null }
        }
        return $record
    } catch { return $null }
}

function Save-DeliveryStageEvidence {
    param(
        [Parameter(Mandatory = $true)][object]$Stage,
        [Parameter(Mandatory = $true)][string]$CandidateCommit,
        [Parameter(Mandatory = $true)][string]$CandidateTree,
        [string]$ProofPath = ""
    )
    $path = Get-DeliveryStageEvidencePath -StageId ([string]$Stage.id) -Fingerprint ([string]$Stage.inputFingerprint)
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $existing = Test-DeliveryStageEvidence -StageId ([string]$Stage.id) -Fingerprint ([string]$Stage.inputFingerprint)
        if ($existing) { return $existing }
        throw "DELIVERY_STAGE_EVIDENCE_CORRUPT: refusing to overwrite immutable evidence '$path'."
    }
    $directory = Split-Path -Parent $path
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $proof = [ordered]@{ path = ""; sha256 = "" }
    if ($ProofPath) {
        if (-not (Test-Path -LiteralPath $ProofPath -PathType Leaf)) { throw "Stage proof is missing: $ProofPath" }
        $extension = [IO.Path]::GetExtension($ProofPath)
        if (-not $extension) { $extension = ".json" }
        $immutableProof = Join-Path $directory ("proof" + $extension)
        Copy-Item -LiteralPath $ProofPath -Destination $immutableProof -Force
        $proof.path = $immutableProof
        $proof.sha256 = Get-DeliveryFileSha256 -Path $immutableProof
    }
    $record = [ordered]@{
        schemaVersion = 1
        kind = "itl-delivery-stage-evidence"
        status = "passed"
        stageId = [string]$Stage.id
        stageVersion = [int]$Stage.version
        inputFingerprint = [string]$Stage.inputFingerprint
        supervisorCommit = $script:DeliverySupervisorCommit
        candidate = [ordered]@{ commit=$CandidateCommit; tree=$CandidateTree }
        proof = $proof
        savedAt = [DateTime]::UtcNow.ToString("o")
    }
    $temporary = "$path.$([guid]::NewGuid().ToString('N')).tmp"
    [IO.File]::WriteAllText($temporary, (($record | ConvertTo-Json -Depth 12) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $path -Force
    return [pscustomobject]$record
}

function Get-DeliveryMatchedFiles {
    param([Parameter(Mandatory = $true)][string]$CandidateRoot, [Parameter(Mandatory = $true)][string[]]$Pattern)
    $root = [IO.Path]::GetFullPath($CandidateRoot).TrimEnd('\', '/')
    if (-not $script:DeliveryTrackedPathCache.ContainsKey($root)) {
        $script:DeliveryTrackedPathCache[$root] = @(Get-RepositoryGitPathList -RepositoryRoot $root -Arguments @("ls-files", "-z", "--"))
    }
    $trackedPaths = @($script:DeliveryTrackedPathCache[$root])
    $files = foreach ($relativePath in $trackedPaths) {
        $relative = ([string]$relativePath).Replace('\', '/')
        $matched = $false
        foreach ($item in $Pattern) {
            if (Test-QualityPathPattern -Path $relative -Pattern ([string]$item)) { $matched = $true; break }
        }
        if (-not $matched) { continue }
        $fullPath = Join-Path $root $relative.Replace('/', '\')
        if (Test-Path -LiteralPath $fullPath -PathType Leaf) { Get-Item -LiteralPath $fullPath }
    }
    return @($files | Sort-Object FullName -Unique)
}

function Get-DeliveryInputFingerprint {
    param(
        [Parameter(Mandatory = $true)][string]$StageId,
        [Parameter(Mandatory = $true)][int]$Version,
        [Parameter(Mandatory = $true)][string]$CandidateRoot,
        [string[]]$Pattern = @(),
        [string[]]$ExactPath = @(),
        [string[]]$DependencyFingerprint = @(),
        [object]$ExternalIdentity = $null
    )
    $root = [IO.Path]::GetFullPath($CandidateRoot).TrimEnd('\', '/')
    $matchedFiles = @()
    if (@($Pattern).Count -gt 0) { $matchedFiles += @(Get-DeliveryMatchedFiles -CandidateRoot $root -Pattern $Pattern) }
    foreach ($relativePath in @($ExactPath | Sort-Object -Unique)) {
        $fullPath = Join-Path $root ([string]$relativePath).Replace('/', '\')
        if (Test-Path -LiteralPath $fullPath -PathType Leaf) { $matchedFiles += Get-Item -LiteralPath $fullPath }
    }
    $inputs = @($matchedFiles | Sort-Object FullName -Unique | ForEach-Object {
        [ordered]@{
            path = $_.FullName.Substring($root.Length).TrimStart('\', '/').Replace('\', '/')
            sha256 = Get-DeliveryFileSha256 -Path $_.FullName
        }
    })
    return Get-DeliveryCanonicalJsonSha256 -Value ([ordered]@{
        stageId=$StageId; version=$Version; inputs=$inputs
        dependencyFingerprint=@($DependencyFingerprint | Sort-Object)
        externalIdentity=$ExternalIdentity
    })
}

function Get-DeliveryReleaseStageCatalog {
    param([Parameter(Mandatory = $true)][string]$CandidateRoot)
    $path = Join-Path $CandidateRoot "scripts\release-e2e\stages.json"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Release stage catalog is missing: $path" }
    $catalog = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([int]$catalog.schemaVersion -ne 1 -or @($catalog.stages).Count -eq 0) { throw "Release stage catalog must use schemaVersion 1 and contain stages." }
    $ids = @($catalog.stages | ForEach-Object { [string]$_.id })
    if (@($ids | Sort-Object -Unique).Count -ne $ids.Count) { throw "Release stage catalog ids must be unique." }
    foreach ($stage in @($catalog.stages)) {
        if (-not [string]$stage.id -or [int]$stage.version -le 0 -or [int]$stage.budgetSeconds -le 0 -or @($stage.paths).Count -eq 0) {
            throw "Release stage definitions require id, version, budgetSeconds, and paths."
        }
        foreach ($dependency in @($stage.dependsOn)) { if ([string]$dependency -notin $ids) { throw "Release stage '$($stage.id)' has unknown dependency '$dependency'." } }
    }
    return $catalog
}

function Get-DeliveryPlanEnvironmentIdentity {
    param([Parameter(Mandatory = $true)][ValidateSet("Develop", "Release")][string]$Mode)
    $standVariable = Get-Variable -Name E2EProjectRoot -Scope Script -ErrorAction SilentlyContinue
    $standRoot = if ($standVariable -and [string]$standVariable.Value) { [IO.Path]::GetFullPath([string]$standVariable.Value) } else { "" }
    $fileIdentity = [ordered]@{}
    if ($standRoot) {
        foreach ($relative in @(".agent-1c/project.json", ".agent-1c/release-e2e.json", ".dev.env")) {
            $path = Join-Path $standRoot $relative.Replace('/', '\')
            $fileIdentity[$relative] = $(if(Test-Path -LiteralPath $path -PathType Leaf){Get-DeliveryFileSha256 -Path $path}else{"missing"})
        }
    }
    $preparedRulesVariable = Get-Variable -Name AiRulesSource -Scope Script -ErrorAction SilentlyContinue
    $requestedRulesVariable = Get-Variable -Name DeliveryRequestedAiRulesSource -Scope Script -ErrorAction SilentlyContinue
    $rulesRoot = if ($preparedRulesVariable -and [string]$preparedRulesVariable.Value) { [IO.Path]::GetFullPath([string]$preparedRulesVariable.Value) } elseif ($requestedRulesVariable -and [string]$requestedRulesVariable.Value) { [IO.Path]::GetFullPath([string]$requestedRulesVariable.Value) } else { "" }
    $rulesIdentity = [ordered]@{ root=$rulesRoot; commit=""; tree="" }
    if ($rulesRoot -and (Test-Path -LiteralPath $rulesRoot -PathType Container)) {
        $rulesIdentity.commit = (Invoke-RepositoryGit -RepositoryRoot $rulesRoot -Arguments @("rev-parse", "HEAD")).stdout.Trim()
        $rulesIdentity.tree = (Invoke-RepositoryGit -RepositoryRoot $rulesRoot -Arguments @("rev-parse", "HEAD^{tree}")).stdout.Trim()
    }
    return [ordered]@{ mode=$Mode; standRoot=$standRoot; standFiles=$fileIdentity; aiRules=$rulesIdentity; powershell="$($PSVersionTable.PSEdition)-$($PSVersionTable.PSVersion)" }
}

function New-DeliveryQualityPlanForCandidate {
    param(
        [Parameter(Mandatory = $true)][string]$CandidateRoot,
        [Parameter(Mandatory = $true)][string]$BaseCommit,
        [Parameter(Mandatory = $true)][string]$CandidateCommit,
        [Parameter(Mandatory = $true)][string]$CandidateTree,
        [switch]$RequireRelease,
        [switch]$AllowCustomGateFixture
    )
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $paths = @(Get-RepositoryGitPathList -RepositoryRoot $CandidateRoot -Arguments @("diff", "--name-only", "--diff-filter=ACDMRT", "-z", "$BaseCommit...$CandidateCommit", "--"))
    $catalogPath = Join-Path $CandidateRoot "tests\quality-contracts.json"
    $gateVariable = Get-Variable -Name GateScript -Scope Script -ErrorAction SilentlyContinue
    $customGateRequested = [bool]$AllowCustomGateFixture -or ($gateVariable -and [string]$gateVariable.Value -and (Split-Path -Leaf ([string]$gateVariable.Value) -ne 'check.ps1'))
    if ($customGateRequested) {
        $gateIdentity = Get-DeliveryFileIdentity -Path $script:GateScript
        $stages = @(
            [pscustomobject][ordered]@{ id="develop.custom-gate"; version=1; mode="Develop"; dependsOn=@(); budgetSeconds=1; inputFingerprint=(Get-DeliveryCanonicalJsonSha256 -Value ([ordered]@{ paths=$paths; gate=$gateIdentity })); execution="execute"; reason="explicit custom gate fixture boundary" }
        )
        if ($RequireRelease) {
            $stages += [pscustomobject][ordered]@{ id="release.custom-gate"; version=1; mode="Release"; dependsOn=@("develop.custom-gate"); budgetSeconds=1; inputFingerprint=(Get-DeliveryCanonicalJsonSha256 -Value ([ordered]@{ paths=$paths; gate=$gateIdentity; mode="Release" })); execution="execute"; reason="explicit custom gate fixture boundary" }
        }
        $watch.Stop()
        $plan = [pscustomobject][ordered]@{
            schemaVersion=1; kind="itl-delivery-plan"; planId=""; status="ready"; createdAt=[DateTime]::UtcNow.ToString("o")
            supervisor=[ordered]@{ commit=$script:DeliverySupervisorCommit; bootstrap=[bool]$script:DeliverySupervisorBootstrap }; candidate=[ordered]@{ commit=$CandidateCommit; tree=$CandidateTree; baseCommit=$BaseCommit }
            requireRelease=[bool]$RequireRelease; paths=$paths; contracts=@("custom-gate-fixture"); stages=$stages; executedBudgetSeconds=[int]$stages.Count; planningDurationMs=[int64]$watch.ElapsedMilliseconds
        }
        $plan.planId = Get-DeliveryCanonicalJsonSha256 -Value (Get-DeliveryPlanIdentity -Plan $plan)
        return $plan
    }
    $catalog = Get-QualityContractCatalog -RepositoryRoot $CandidateRoot
    [void](Test-QualityContractCatalog -RepositoryRoot $CandidateRoot -Catalog $catalog)
    $selection = Resolve-QualityContractsForPaths -Catalog $catalog -Paths $paths
    if (@($selection.unknownPaths).Count -gt 0) {
        $watch.Stop()
        $blockedStages = @($selection.unknownPaths | Sort-Object -Unique | ForEach-Object {
            [pscustomobject][ordered]@{ id="owner.$(([string]$_) -replace '[^A-Za-z0-9._-]', '-')"; version=1; mode="Plan"; dependsOn=@(); budgetSeconds=0; inputFingerprint=""; execution="blocked"; reason="QUALITY_OWNER_MISSING: $_" }
        })
        $plan = [pscustomobject][ordered]@{
            schemaVersion=1; kind="itl-delivery-plan"; planId=""; status="blocked"; createdAt=[DateTime]::UtcNow.ToString("o")
            supervisor=[ordered]@{ commit=$script:DeliverySupervisorCommit; bootstrap=[bool]$script:DeliverySupervisorBootstrap }; candidate=[ordered]@{ commit=$CandidateCommit; tree=$CandidateTree; baseCommit=$BaseCommit }
            requireRelease=[bool]$RequireRelease; paths=@($paths); contracts=@(); stages=$blockedStages; blockers=@($selection.unknownPaths | ForEach-Object { "QUALITY_OWNER_MISSING: $_" })
            executedBudgetSeconds=0; planningDurationMs=[int64]$watch.ElapsedMilliseconds
        }
        $plan.planId = Get-DeliveryCanonicalJsonSha256 -Value (Get-DeliveryPlanIdentity -Plan $plan)
        return $plan
    }
    $journeyPlan = Resolve-DevelopE2EJourneyPlan -RepositoryRoot $CandidateRoot -ChangedPath $paths -Catalog $catalog
    if (@($journeyPlan.unknownPaths).Count -gt 0) { throw "QUALITY_OWNER_MISSING: $(@($journeyPlan.unknownPaths) -join ', ')" }
    $stages = [Collections.Generic.List[object]]::new()
    $developEnvironment = Get-DeliveryPlanEnvironmentIdentity -Mode Develop
    $staticFingerprint = Get-DeliveryInputFingerprint -StageId "develop.static" -Version 1 -CandidateRoot $CandidateRoot -Pattern @("tests/quality-contracts.json", "scripts/invoke-pester-shards.ps1", "scripts/run-pester-shard.ps1") -ExactPath (@($paths) + @($selection.tests))
    $staticProof = Test-DeliveryStageEvidence -StageId "develop.static" -Fingerprint $staticFingerprint
    $stages.Add([pscustomobject][ordered]@{ id="develop.static"; version=1; mode="Develop"; dependsOn=@(); budgetSeconds=900; inputFingerprint=$staticFingerprint; execution=$(if($staticProof){"reuse"}else{"execute"}); reason=$(if($staticProof){"matching stage evidence"}else{"selected owner tests and static qualification"}) }) | Out-Null
    foreach ($journey in @($journeyPlan.journeys)) {
        $routeContractIds = @($catalog.developJourneys.routes.$journey.contracts | ForEach-Object { [string]$_ })
        $routePatterns = @($catalog.contracts | Where-Object { [string]$_.id -in $routeContractIds } | ForEach-Object { @($_.paths) })
        $stageId = "develop.$journey"
        $fingerprint = Get-DeliveryInputFingerprint -StageId $stageId -Version 1 -CandidateRoot $CandidateRoot -Pattern $routePatterns -ExternalIdentity $developEnvironment
        $proof = Test-DeliveryStageEvidence -StageId $stageId -Fingerprint $fingerprint
        $stages.Add([pscustomobject][ordered]@{ id=$stageId; version=1; mode="Develop"; dependsOn=@("develop.static"); budgetSeconds=$(if($journey -eq "upgrade"){1200}else{2100}); inputFingerprint=$fingerprint; execution=$(if($proof){"reuse"}else{"execute"}); reason=$(if($proof){"matching stage evidence"}else{"owner-selected Develop journey"}) }) | Out-Null
    }
    if ($RequireRelease) {
        $releaseCatalog = Get-DeliveryReleaseStageCatalog -CandidateRoot $CandidateRoot
        $releaseEnvironment = Get-DeliveryPlanEnvironmentIdentity -Mode Release
        $fingerprints = @{}
        foreach ($definition in @($releaseCatalog.stages)) {
            $dependencies = @($definition.dependsOn | ForEach-Object { [string]$fingerprints[[string]$_] })
            $stageId = "release.$([string]$definition.id)"
            $fingerprint = Get-DeliveryInputFingerprint -StageId $stageId -Version ([int]$definition.version) -CandidateRoot $CandidateRoot -Pattern @($definition.paths) -DependencyFingerprint $dependencies -ExternalIdentity $releaseEnvironment
            $fingerprints[[string]$definition.id] = $fingerprint
            $alwaysExecute = $definition.PSObject.Properties["alwaysExecute"] -and [bool]$definition.alwaysExecute
            $proof = if ($alwaysExecute) { $null } else { Test-DeliveryStageEvidence -StageId $stageId -Fingerprint $fingerprint }
            $stages.Add([pscustomobject][ordered]@{ id=$stageId; version=[int]$definition.version; mode="Release"; dependsOn=@($definition.dependsOn | ForEach-Object { "release.$_" }); budgetSeconds=[int]$definition.budgetSeconds; alwaysExecute=[bool]$alwaysExecute; inputFingerprint=$fingerprint; execution=$(if($proof){"reuse"}else{"execute"}); reason=$(if($alwaysExecute){"freshness and cleanup contract"}elseif($proof){"matching stage evidence"}else{"required Release capability"}) }) | Out-Null
        }
    }
    $watch.Stop()
    if ($watch.Elapsed.TotalSeconds -gt 30) { throw "DELIVERY_PLAN_BUDGET_EXCEEDED: planning took $([int]$watch.Elapsed.TotalSeconds)s; hard limit is 30s." }
    $executedBudget = 0
    foreach ($stage in @($stages)) { if ([string]$stage.execution -eq "execute") { $executedBudget += [int]$stage.budgetSeconds } }
    $plan = [pscustomobject][ordered]@{
        schemaVersion=1; kind="itl-delivery-plan"; planId=""; status="ready"; createdAt=[DateTime]::UtcNow.ToString("o")
        supervisor=[ordered]@{ commit=$script:DeliverySupervisorCommit; bootstrap=[bool]$script:DeliverySupervisorBootstrap }
        candidate=[ordered]@{ commit=$CandidateCommit; tree=$CandidateTree; baseCommit=$BaseCommit }
        requireRelease=[bool]$RequireRelease; paths=@($paths); contracts=@($selection.contracts | ForEach-Object { [string]$_.id }); stages=@($stages)
        executedBudgetSeconds=$executedBudget; planningDurationMs=[int64]$watch.ElapsedMilliseconds
    }
    $plan.planId = Get-DeliveryCanonicalJsonSha256 -Value (Get-DeliveryPlanIdentity -Plan $plan)
    return $plan
}

function Save-DeliveryQualityPlan {
    param([Parameter(Mandatory = $true)][object]$Plan)
    $path = Join-Path (Get-DeliveryPlanRoot) ("$([string]$Plan.planId).json")
    $json = ($Plan | ConvertTo-Json -Depth 20) + [Environment]::NewLine
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $existing = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        if ((Get-DeliveryCanonicalJsonSha256 -Value (Get-DeliveryPlanIdentity -Plan $existing)) -ne (Get-DeliveryCanonicalJsonSha256 -Value (Get-DeliveryPlanIdentity -Plan $Plan))) { throw "DELIVERY_PLAN_IMMUTABILITY_VIOLATION: $path" }
        return $path
    }
    $temporary = "$path.$([guid]::NewGuid().ToString('N')).tmp"
    [IO.File]::WriteAllText($temporary, $json, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $path
    return $path
}

function Assert-DeliveryQualityPlanMayRun {
    param([Parameter(Mandatory = $true)][object]$Plan)
    if ([string]$Plan.status -eq "blocked") { throw (@($Plan.blockers) -join "; ") }
    if ($ResumePlan -and [string]$Plan.planId -ne $ResumePlan) { throw "DELIVERY_RESUME_PLAN_MISMATCH: requested '$ResumePlan', current '$([string]$Plan.planId)'." }
    if ([int]$Plan.executedBudgetSeconds -gt 3600 -and $ApproveLongPlan -ne [string]$Plan.planId) {
        throw "LONG_PLAN_APPROVAL_REQUIRED: plan '$([string]$Plan.planId)' requires $([int]$Plan.executedBudgetSeconds)s; pass -ApproveLongPlan '$([string]$Plan.planId)'."
    }
}

function Get-DeliveryPlanGateBudgetSeconds {
    param([Parameter(Mandatory = $true)][object]$Plan, [Parameter(Mandatory = $true)][ValidateSet("Develop", "Release")][string]$Mode)
    $budget = 0
    foreach ($stage in @($Plan.stages | Where-Object { [string]$_.mode -eq $Mode -and [string]$_.execution -eq "execute" })) { $budget += [int]$stage.budgetSeconds }
    # A reused plan still gets a bounded supervisor pass that validates and
    # materializes exact-candidate qualification from immutable evidence.
    return [Math]::Max(900, $budget)
}

function New-AccumulatedDeliveryPlan {
    param([switch]$RequireRelease)
    Assert-CleanDeliveryWorktree
    [void](Invoke-DeliveryGit -Arguments @("fetch", $script:Remote, "develop"))
    $remoteBefore = Get-GitValue -Arguments @("rev-parse", "$script:Remote/develop")
    $entries = @(Get-QueueEntries)
    if ($entries.Count -eq 0) { throw "There are no registered develop changes to plan." }
    $worktree = $null
    try {
        $worktree = New-DeliveryWorktree -StartPoint "$script:Remote/develop" -Purpose "plan-develop"
        Add-QueuedRangesToCandidate -CandidateRoot $worktree.path -Entries $entries
        $candidate = (Invoke-WorktreeGit -Root $worktree.path -Arguments @("rev-parse", "HEAD")).stdout.Trim()
        $tree = (Invoke-WorktreeGit -Root $worktree.path -Arguments @("rev-parse", "HEAD^{tree}")).stdout.Trim()
        $plan = New-DeliveryQualityPlanForCandidate -CandidateRoot $worktree.path -BaseCommit $remoteBefore -CandidateCommit $candidate -CandidateTree $tree -RequireRelease:$RequireRelease
        $plan | Add-Member -NotePropertyName path -NotePropertyValue (Save-DeliveryQualityPlan -Plan $plan)
        return $plan
    } finally { if ($worktree) { Remove-DeliveryWorktree -Worktree $worktree } }
}

function Invoke-DeliveryDiagnosticFull {
    param([string]$AiRulesSource, [string]$E2EProjectRoot)
    Assert-CleanDeliveryWorktree
    Invoke-SourceGate -Mode "Full" -WorkingRoot $script:Root
    return [pscustomobject]@{ status="passed"; action="DiagnoseFull"; candidate=(Get-GitValue -Arguments @("rev-parse", "HEAD")); published=$false }
}

function Save-DeliveryPlanGateEvidence {
    param([Parameter(Mandatory = $true)][object]$Plan, [Parameter(Mandatory = $true)][string]$CandidateRoot, [Parameter(Mandatory = $true)][ValidateSet("Develop", "Release")][string]$Mode)
    $summaryPath = Join-Path $CandidateRoot "build\test-results\local\check-summary.json"
    if (-not (Test-Path -LiteralPath $summaryPath -PathType Leaf)) { return }
    $summary = Get-Content -LiteralPath $summaryPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $candidateCommit = [string]$Plan.candidate.commit; $candidateTree = [string]$Plan.candidate.tree
    $releaseSummary = $null
    if ($Mode -eq "Release" -and [string]$summary.e2eReportPath -and (Test-Path -LiteralPath ([string]$summary.e2eReportPath) -PathType Leaf)) {
        $releaseSummary = Get-Content -LiteralPath ([string]$summary.e2eReportPath) -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    foreach ($stage in @($Plan.stages | Where-Object mode -eq $Mode)) {
        $proofPath = $summaryPath
        if ([string]$stage.id -eq "develop.upgrade") { $proofPath = Join-Path $CandidateRoot "build\test-results\qualification\develop-e2e-upgrade.json" }
        elseif ([string]$stage.id -eq "develop.fresh") { $proofPath = Join-Path $CandidateRoot "build\test-results\qualification\develop-e2e-fresh.json" }
        elseif ([string]$stage.id -like "release.*" -and $releaseSummary -and $releaseSummary.PSObject.Properties["stages"]) {
            $nestedName = ([string]$stage.id).Substring(8)
            $nested = $releaseSummary.stages.PSObject.Properties[$nestedName]
            if (-not $nested -or [string]$nested.Value.status -ne "passed") { continue }
            if ([string]$nested.Value.evidencePath) { $proofPath = [string]$nested.Value.evidencePath }
        }
        [void](Save-DeliveryStageEvidence -Stage $stage -CandidateCommit $candidateCommit -CandidateTree $candidateTree -ProofPath $proofPath)
    }
}

function Restore-DeliveryPlanQualification {
    param([Parameter(Mandatory = $true)][object]$Plan, [Parameter(Mandatory = $true)][string]$CandidateRoot)
    $reusedDevelop = @($Plan.stages | Where-Object { [string]$_.mode -eq "Develop" -and [string]$_.execution -eq "reuse" })
    if ($reusedDevelop.Count -eq 0) { return $false }
    $records = @($reusedDevelop | ForEach-Object { Test-DeliveryStageEvidence -StageId ([string]$_.id) -Fingerprint ([string]$_.inputFingerprint) })
    if ($records.Count -ne $reusedDevelop.Count -or @($records | Where-Object { -not $_ }).Count -gt 0) { return $false }
    $trees = @($records | ForEach-Object { [string]$_.candidate.tree } | Sort-Object -Unique)
    if ($trees.Count -ne 1 -or $trees[0] -notmatch '^[a-f0-9]{40}$') { return $false }
    return Restore-DeliveryQualification -CandidateRoot $CandidateRoot -Tree $trees[0]
}
