Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "stand-env-identity.ps1")
$script:DeliveryTrackedPathCache = @{}

function Get-DeliveryPlanningBudget {
    # One contract for completed planning and its nested static preview.
    [pscustomobject]@{ warningMilliseconds = 120000; hardMilliseconds = 300000 }
}

function Assert-DeliveryPlanningBudget {
    param([Parameter(Mandatory = $true)][long]$ElapsedMilliseconds)
    $budget = Get-DeliveryPlanningBudget
    $hardSeconds = $budget.hardMilliseconds / 1000
    $warningSeconds = $budget.warningMilliseconds / 1000
    if ($ElapsedMilliseconds -gt $budget.hardMilliseconds) {
        throw "DELIVERY_PLAN_BUDGET_EXCEEDED: planning took $([int]($ElapsedMilliseconds / 1000))s; hard limit is ${hardSeconds}s. Queue and checkpoint were preserved. Diagnose planning cost, then repeat the same Plan or publication command."
    }
    if ($ElapsedMilliseconds -gt $budget.warningMilliseconds) {
        Write-Warning "Delivery planning exceeded its ${warningSeconds}s target ($([int]($ElapsedMilliseconds / 1000))s); the valid plan remains usable within the ${hardSeconds}s hard limit."
    }
}

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
    $identity = [ordered]@{
        protocolVersion=1; supervisorCommit=[string]$Plan.supervisor.commit; supervisorChannel=[string]$Plan.supervisor.channel
        candidateCommit=[string]$Plan.candidate.commit; candidateTree=[string]$Plan.candidate.tree; baseCommit=[string]$Plan.candidate.baseCommit
        requireRelease=[bool]$Plan.requireRelease; releaseCapabilities=@($Plan.releaseCapabilities); paths=@($Plan.paths); contracts=@($Plan.contracts); stages=@($Plan.stages | ForEach-Object {
            [ordered]@{ id=[string]$_.id; version=[int]$_.version; mode=[string]$_.mode; dependsOn=@($_.dependsOn); budgetSeconds=[int]$_.budgetSeconds; alwaysExecute=[bool]($_.PSObject.Properties["alwaysExecute"] -and [bool]$_.alwaysExecute); inputFingerprint=[string]$_.inputFingerprint }
        })
    }
    if ($Plan.PSObject.Properties['releaseEnclosingOverheadSeconds']) {
        $identity['releaseEnclosingOverheadSeconds'] = [int]$Plan.releaseEnclosingOverheadSeconds
    }
    if ($Plan.PSObject.Properties['queue']) {
        $identity['queue'] = @($Plan.queue | ForEach-Object { [ordered]@{ id=[string]$_.id; base=[string]$_.base; head=[string]$_.head } })
    }
    if ($Plan.PSObject.Properties['calculator']) {
        $identity['calculator'] = $Plan.calculator
    }
    if ($Plan.PSObject.Properties['replacesPlanId']) { $identity['replacesPlanId'] = [string]$Plan.replacesPlanId }
    if ($Plan.PSObject.Properties['replanQueueScope']) { $identity['replanQueueScope'] = [string]$Plan.replanQueueScope }
    return $identity
}

function Set-DeliveryPlanQueue {
    param([Parameter(Mandatory = $true)][object]$Plan, [AllowEmptyCollection()][object[]]$Entries)
    $queue = @($Entries | Sort-Object id | ForEach-Object { [pscustomobject]@{ id=[string]$_.id; base=[string]$_.base; head=[string]$_.head } })
    $Plan | Add-Member -NotePropertyName queue -NotePropertyValue $queue -Force
    $Plan.planId = Get-DeliveryCanonicalJsonSha256 -Value (Get-DeliveryPlanIdentity -Plan $Plan)
}

function Get-DeliveryStageEvidencePath {
    param([Parameter(Mandatory = $true)][string]$StageId, [Parameter(Mandatory = $true)][string]$Fingerprint, [string]$EvidenceRoot = '')
    $safeStage = $StageId -replace '[^A-Za-z0-9._-]', '-'
    if (-not $EvidenceRoot) { $EvidenceRoot = Get-DeliveryEvidenceRoot }
    return Join-Path $EvidenceRoot "$safeStage\$Fingerprint\evidence.json"
}

function Test-DeliveryStageEvidence {
    param([Parameter(Mandatory = $true)][string]$StageId, [Parameter(Mandatory = $true)][string]$Fingerprint, [string]$EvidenceRoot = '', [ref]$InvalidReason)
    if ($InvalidReason) { $InvalidReason.Value = '' }
    $path = Get-DeliveryStageEvidencePath -StageId $StageId -Fingerprint $Fingerprint -EvidenceRoot $EvidenceRoot
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try {
        $record = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([int]$record.schemaVersion -ne 1 -or [string]$record.status -ne "passed" -or
            [string]$record.stageId -ne $StageId -or [string]$record.inputFingerprint -ne $Fingerprint) { throw "stage '$StageId', input '$Fingerprint': record schema, status or identity mismatch at '$path'" }
        if ([string]$record.proof.path) {
            $proofPath = [string]$record.proof.path
            if (-not (Test-Path -LiteralPath $proofPath -PathType Leaf)) { throw "stage '$StageId': proof '$proofPath' is missing; expected SHA256 '$([string]$record.proof.sha256)'" }
            $actualProofSha = Get-DeliveryFileSha256 -Path $proofPath
            if ($actualProofSha -ne ([string]$record.proof.sha256).ToLowerInvariant()) { throw "stage '$StageId': proof '$proofPath' SHA256 changed; expected '$([string]$record.proof.sha256)', actual '$actualProofSha'" }
        }
        return $record
    } catch {
        if ($InvalidReason) { $InvalidReason.Value = "evidence '$path': $($_.Exception.Message)" }
        return $null
    }
}

function Get-DeliveryPlanInvalidEvidence {
    param([Parameter(Mandatory = $true)][object]$Plan)
    $evidenceRoot = Get-DeliveryEvidenceRoot
    foreach ($stage in @($Plan.stages)) {
        if (-not [string]$stage.inputFingerprint) { continue }
        $path = Get-DeliveryStageEvidencePath -StageId ([string]$stage.id) -Fingerprint ([string]$stage.inputFingerprint) -EvidenceRoot $evidenceRoot
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $reason = ''
        $valid = Test-DeliveryStageEvidence -StageId ([string]$stage.id) -Fingerprint ([string]$stage.inputFingerprint) -EvidenceRoot $evidenceRoot -InvalidReason ([ref]$reason)
        if (-not $valid) { [pscustomobject]@{ stageId=[string]$stage.id; mode=[string]$stage.mode; fingerprint=[string]$stage.inputFingerprint; path=$path; sha256=(Get-DeliveryFileSha256 -Path $path); reason=$reason } }
    }
}

function Move-DeliveryRejectedEvidence {
    param([Parameter(Mandatory = $true)][object[]]$Evidence)
    # Only explicit replacement under the publication operation lease reaches
    # this repair. A valid immutable proof is never replaced or removed.
    foreach ($item in $Evidence) {
        if ((Get-DeliveryFileSha256 -Path ([string]$item.path)) -cne [string]$item.sha256 -or
            (Test-DeliveryStageEvidence -StageId ([string]$item.stageId) -Fingerprint ([string]$item.fingerprint))) {
            throw "DELIVERY_EVIDENCE_MOVED: '$([string]$item.path)' changed during repair; publication checkpoint and queue were preserved. Repeat the same PublishDevelop options to revalidate and continue its saved replacement; Status shows the current plan ID."
        }
        $root = Join-Path (Get-DeliveryCommonGitDirectory) 'itl/evidence-rejected/v1'
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        $destination = Join-Path $root (([string]$item.stageId -replace '[^A-Za-z0-9._-]','-')+'-'+[string]$item.fingerprint+'-'+[guid]::NewGuid().ToString('N'))
        $sourceDirectory = [IO.Path]::GetFullPath((Split-Path -Parent ([string]$item.path)))
        $destination = [IO.Path]::GetFullPath($destination)
        $evidencePrefix = [IO.Path]::GetFullPath((Get-DeliveryEvidenceRoot)).TrimEnd('\')+'\'
        $archivePrefix = [IO.Path]::GetFullPath($root).TrimEnd('\')+'\'
        if (-not $sourceDirectory.StartsWith($evidencePrefix,[StringComparison]::OrdinalIgnoreCase) -or -not $destination.StartsWith($archivePrefix,[StringComparison]::OrdinalIgnoreCase)) {
            throw 'DELIVERY_EVIDENCE_ARCHIVE_SCOPE: generated evidence paths left the common-Git evidence roots. Checkpoint and queue were preserved; restore the compatible evidence owner before continuing this publication.'
        }
        Move-Item -LiteralPath $sourceDirectory -Destination $destination
        [pscustomobject]@{ stageId=[string]$item.stageId; fingerprint=[string]$item.fingerprint; originalPath=[string]$item.path; archivePath=$destination; sha256=[string]$item.sha256; reason=[string]$item.reason }
    }
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
    $files = foreach ($relative in @(Select-QualityPaths -Paths $trackedPaths -Pattern $Pattern)) {
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
    return Get-QualityReleaseStageCatalog -RepositoryRoot $CandidateRoot
}

function Resolve-DeliveryRequiredReleaseCapabilities {
    param([Parameter(Mandatory = $true)][object]$Catalog, [switch]$RequireRelease, [string[]]$ReleaseCapability = @())
    return @(Resolve-QualityReleaseCapabilities -Catalog $Catalog -RequireRelease:$RequireRelease -ReleaseCapability $ReleaseCapability)
}

function Get-DeliverySupervisorChannel {
    $channel = Get-Variable -Name DeliverySupervisorChannel -Scope Script -ErrorAction SilentlyContinue
    if ($channel -and [string]$channel.Value -in @("develop", "master")) { return [string]$channel.Value }
    return "master"
}

function Get-DeliveryPlanEnvironmentIdentity {
    param([Parameter(Mandatory = $true)][ValidateSet("Develop", "Release")][string]$Mode)
    $standVariable = Get-Variable -Name E2EProjectRoot -Scope Script -ErrorAction SilentlyContinue
    $standRoot = if ($standVariable -and [string]$standVariable.Value) { [IO.Path]::GetFullPath([string]$standVariable.Value) } else { "" }
    $fileIdentity = [ordered]@{}
    if ($standRoot) {
        foreach ($relative in @(".agent-1c/project.json", ".agent-1c/release-e2e.json", ".dev.env")) {
            $path = Join-Path $standRoot $relative.Replace('/', '\')
            $fileIdentity[$relative] = $(if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                "missing"
            } elseif ($relative -eq ".dev.env") {
                Get-DeliveryStableDotEnvSha256 -Path $path
            } else {
                Get-DeliveryFileSha256 -Path $path
            })
        }
    }
    $preparedRulesVariable = Get-Variable -Name AiRulesSource -Scope Script -ErrorAction SilentlyContinue
    $requestedRulesVariable = Get-Variable -Name DeliveryRequestedAiRulesSource -Scope Script -ErrorAction SilentlyContinue
    $rulesRoot = if ($preparedRulesVariable -and [string]$preparedRulesVariable.Value) { [IO.Path]::GetFullPath([string]$preparedRulesVariable.Value) } elseif ($requestedRulesVariable -and [string]$requestedRulesVariable.Value) { [IO.Path]::GetFullPath([string]$requestedRulesVariable.Value) } else { "" }
    $rulesIdentity = [ordered]@{ commit=""; tree="" }
    if ($rulesRoot -and (Test-Path -LiteralPath $rulesRoot -PathType Container)) {
        $rulesIdentity.commit = (Invoke-RepositoryGit -RepositoryRoot $rulesRoot -Arguments @("rev-parse", "HEAD")).stdout.Trim()
        $rulesIdentity.tree = (Invoke-RepositoryGit -RepositoryRoot $rulesRoot -Arguments @("rev-parse", "HEAD^{tree}")).stdout.Trim()
    }
    $sourceBuild = [Environment]::GetEnvironmentVariable('ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE', 'Process')
    $sourceBuildSha256 = if (-not $sourceBuild) {
        'unset'
    } elseif (Test-Path -LiteralPath $sourceBuild -PathType Leaf) {
        Get-DeliveryFileSha256 -Path $sourceBuild
    } else {
        'missing'
    }
    $clientBuild = [Environment]::GetEnvironmentVariable('VANESSA_MCP_CLIENT_CFE_PATH', 'Process')
    $clientBuildSha256 = if (-not $clientBuild) { 'unset' } elseif (Test-Path -LiteralPath $clientBuild -PathType Leaf) { Get-DeliveryFileSha256 -Path $clientBuild } else { 'missing' }
    return [ordered]@{
        environmentIdentitySchemaVersion=3; mode=$Mode; standRoot=$standRoot; standFiles=$fileIdentity
        clientSelection = Get-SourceE2EClientIdentity -ProjectRoot $standRoot -AgentTarget ([string](Get-Variable -Name AgentTarget -ValueOnly -ErrorAction SilentlyContinue))
        aiRules=$rulesIdentity; vanessaSourceBuildSha256=$sourceBuildSha256
        clientMcpSourceBuildSha256=$clientBuildSha256
        powershell="$($PSVersionTable.PSEdition)-$($PSVersionTable.PSVersion)"
    }
}

function New-DeliveryQualityPlanForCandidate {
    param(
        [Parameter(Mandatory = $true)][string]$CandidateRoot,
        [Parameter(Mandatory = $true)][string]$BaseCommit,
        [Parameter(Mandatory = $true)][string]$CandidateCommit,
        [Parameter(Mandatory = $true)][string]$CandidateTree,
        [switch]$RequireRelease,
        [string[]]$ReleaseCapability = @(),
        [switch]$AllowCustomGateFixture,
        [object]$ArtifactBinding = $null
    )
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $paths = @(Get-RepositoryGitPathList -RepositoryRoot $CandidateRoot -Arguments @("diff", "--name-only", "--diff-filter=ACDMRT", "-z", "$BaseCommit...$CandidateCommit", "--"))
    $catalogPath = Join-Path $CandidateRoot "tests\quality-contracts.json"
    $gateVariable = Get-Variable -Name GateScript -Scope Script -ErrorAction SilentlyContinue
    $customGateRequested = [bool]$AllowCustomGateFixture -or ($gateVariable -and [string]$gateVariable.Value -and ((Split-Path -Leaf ([string]$gateVariable.Value)) -ne 'check.ps1'))
    if ($customGateRequested) {
        $gateIdentity = Get-DeliveryFileIdentity -Path $script:GateScript
        $stages = @(
            [pscustomobject][ordered]@{ id="develop.custom-gate"; version=1; mode="Develop"; dependsOn=@(); budgetSeconds=1; inputFingerprint=(Get-DeliveryCanonicalJsonSha256 -Value ([ordered]@{ paths=$paths; gate=$gateIdentity })); execution="execute"; reason="explicit custom gate fixture boundary" }
        )
        $customReleaseRequired = [bool]($RequireRelease -or @($ReleaseCapability).Count -gt 0)
        $customReleaseCapabilities = @()
        if ($customReleaseRequired) {
            $fixtureCatalogPath = Join-Path $CandidateRoot 'scripts\release-e2e\stages.json'
            $customReleaseCapabilities = if (Test-Path -LiteralPath $fixtureCatalogPath -PathType Leaf) {
                @(Resolve-DeliveryRequiredReleaseCapabilities -Catalog (Get-DeliveryReleaseStageCatalog -CandidateRoot $CandidateRoot) -RequireRelease:$RequireRelease -ReleaseCapability $ReleaseCapability)
            } else { @('custom-gate') }
            $stages += [pscustomobject][ordered]@{ id="release.custom-gate"; version=1; mode="Release"; dependsOn=@("develop.custom-gate"); budgetSeconds=1; inputFingerprint=(Get-DeliveryCanonicalJsonSha256 -Value ([ordered]@{ paths=$paths; gate=$gateIdentity; mode="Release" })); execution="execute"; reason="explicit custom gate fixture boundary" }
        }
        $watch.Stop()
        $plan = [pscustomobject][ordered]@{
            schemaVersion=1; kind="itl-delivery-plan"; planId=""; status="ready"; createdAt=[DateTime]::UtcNow.ToString("o")
            supervisor=[ordered]@{ commit=$script:DeliverySupervisorCommit; channel=(Get-DeliverySupervisorChannel); bootstrap=[bool]$script:DeliverySupervisorBootstrap }; candidate=[ordered]@{ commit=$CandidateCommit; tree=$CandidateTree; baseCommit=$BaseCommit }
            requireRelease=$customReleaseRequired; releaseCapabilities=@($customReleaseCapabilities); paths=$paths; contracts=@("custom-gate-fixture"); stages=$stages; executedBudgetSeconds=[int]$stages.Count; planningDurationMs=[int64]$watch.ElapsedMilliseconds
        }
        $plan.planId = Get-DeliveryCanonicalJsonSha256 -Value (Get-DeliveryPlanIdentity -Plan $plan)
        return $plan
    }
    $nativePath=Join-Path $PSScriptRoot 'delivery-native-plan.ps1'
    $nativeCommand=Get-Command New-DeliveryNativeQualityPlanForCandidate -CommandType Function -ErrorAction SilentlyContinue
    if(-not $nativeCommand -or $nativeCommand.ScriptBlock.File -cne $nativePath) {. $nativePath}
    return New-DeliveryNativeQualityPlanForCandidate @PSBoundParameters -Paths $paths -Watch $watch
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
    if ($ResumePlan -and [string]$Plan.planId -ne $ResumePlan) {
        $before=$null
        try { $before=Get-Content -LiteralPath (Join-Path (Get-DeliveryPlanRoot) "$ResumePlan.json") -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
        $differences=@()
        if ($before) {
            foreach ($field in @('commit','tree','baseCommit')) {
                if ([string]$before.candidate.$field -cne [string]$Plan.candidate.$field) { $differences += "candidate.$field expected '$([string]$before.candidate.$field)', actual '$([string]$Plan.candidate.$field)'" }
            }
            foreach ($stage in @($Plan.stages)) {
                $old=@($before.stages | Where-Object id -eq ([string]$stage.id))
                if ($old.Count -ne 1) { $differences += "stage '$([string]$stage.id)' added"; continue }
                foreach ($field in @('version','budgetSeconds','inputFingerprint')) {
                    if ([string]$old[0].$field -cne [string]$stage.$field) { $differences += "stage '$([string]$stage.id)' $field expected '$([string]$old[0].$field)', actual '$([string]$stage.$field)'" }
                }
            }
        }
        $detail=if($differences.Count){(@($differences | Select-Object -First 8) -join '; ')+$(if($differences.Count -gt 8){"; $($differences.Count-8) further changed inputs"})}else{"candidate '$([string]$Plan.candidate.commit)', tree '$([string]$Plan.candidate.tree)'; sealed policy or environment inputs changed"}
        $continuation = if ((Get-Variable -Name Action -ErrorAction SilentlyContinue) -and $Action -eq 'PublishDevelop') {
            "Review these inputs, then repeat the same PublishDevelop options with -Replan '$ResumePlan'."
        } else { 'Inspect source-delivery Status and continue through the original master publication owner.' }
        throw "DELIVERY_RESUME_PLAN_MISMATCH: requested '$ResumePlan', current '$([string]$Plan.planId)'; $detail. Original immutable plan and proof were preserved. $continuation"
    }
    if ([int]$Plan.executedBudgetSeconds -gt 3600 -and $ApproveLongPlan -ne [string]$Plan.planId) {
        throw "LONG_PLAN_APPROVAL_REQUIRED: plan '$([string]$Plan.planId)' has a hard-limit budget of $([int]$Plan.executedBudgetSeconds)s, not an expected duration (see timeEstimate); pass -ApproveLongPlan '$([string]$Plan.planId)'."
    }
}

function Get-DeliveryPlanGateBudgetSeconds {
    param([Parameter(Mandatory = $true)][object]$Plan, [Parameter(Mandatory = $true)][ValidateSet("Develop", "Release")][string]$Mode)
    $budget = 0
    foreach ($stage in @($Plan.stages | Where-Object { [string]$_.mode -eq $Mode -and [string]$_.execution -eq "execute" })) { $budget += [int]$stage.budgetSeconds }
    if ($Mode -eq 'Release' -and $Plan.PSObject.Properties['releaseEnclosingOverheadSeconds']) {
        $budget += [int]$Plan.releaseEnclosingOverheadSeconds
    }
    # A reused plan still gets a bounded supervisor pass that validates and
    # materializes exact-candidate qualification from immutable evidence.
    return [Math]::Max(900, $budget)
}

function Resolve-DeliveryPlanAiRulesSource {
    param([Parameter(Mandatory = $true)][string]$CandidateRoot)

    # PublishDevelop resolves the requested ai_rules checkout to the exact locked
    # controlled-fork worktree before it fingerprints Develop/Release runtime stages.
    # Plan must use the same effective checkout or its immutable planId cannot be
    # resumed by publication even when the candidate tree is unchanged.
    if ([bool]$script:DeliveryCustomGateBoundary) { return "" }
    $lockPath = Join-Path $CandidateRoot "templates\dependency-lock.json"
    if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) { return "" }
    $dependencies = (Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8 | ConvertFrom-Json).dependencies
    $aiRulesLock = if ($dependencies -and $dependencies.PSObject.Properties["aiRules1c"]) { $dependencies.aiRules1c } else { $null }
    if ($null -eq $aiRulesLock) { return "" }
    return Resolve-DeliveryAiRulesSource -Lock $aiRulesLock
}

function Invoke-DeliveryCandidatePlanCalculation {
    param([string]$CandidateRoot,[string]$BaseCommit,[string]$CandidateCommit,[string]$CandidateTree,
        [switch]$RequireRelease,[string[]]$ReleaseCapability=@(),[switch]$AllowCustomGateFixture)
    $arguments=@{CandidateRoot=$CandidateRoot;BaseCommit=$BaseCommit;CandidateCommit=$CandidateCommit;CandidateTree=$CandidateTree;
        RequireRelease=$RequireRelease;ReleaseCapability=$ReleaseCapability;AllowCustomGateFixture=$AllowCustomGateFixture}
    $calculator=Join-Path $CandidateRoot 'scripts/source-delivery-plan.ps1'
    if($AllowCustomGateFixture -or -not (Test-Path -LiteralPath $calculator -PathType Leaf)) {
        return New-DeliveryQualityPlanForCandidate @arguments
    }
    $head=(Invoke-RepositoryGit -RepositoryRoot $CandidateRoot -Arguments @('rev-parse','HEAD')).stdout.Trim()
    $tree=(Invoke-RepositoryGit -RepositoryRoot $CandidateRoot -Arguments @('rev-parse','HEAD^{tree}')).stdout.Trim()
    if($head -cne $CandidateCommit -or $tree -cne $CandidateTree -or
        @(Get-RepositoryGitPathList -RepositoryRoot $CandidateRoot -Arguments @('status','--porcelain=v1','--untracked-files=all','-z')).Count) {
        throw 'DELIVERY_PLAN_CANDIDATE_CHANGED: reconstruct the exact clean candidate before planning; queue and proof were preserved.'
    }
    $sha=Get-DeliveryFileSha256 $calculator
    # Only calculation is delegated. Child-scope definitions cannot replace the
    # published owner's queue, persistence, approval or execution functions.
    $plan=& {
        param($root,$options)
        foreach($module in @('quality-contracts.ps1','develop-e2e-qualification.ps1','source-delivery-plan.ps1','source-e2e-artifact-discovery.ps1')) {
            . (Join-Path $root ('scripts/'+$module))
        }
        New-DeliveryQualityPlanForCandidate @options
    } $CandidateRoot $arguments
    $valid=$false
    try {
        $valid=$plan.kind -ceq 'itl-delivery-plan' -and [int]$plan.schemaVersion -eq 1 -and
            $plan.candidate.commit -ceq $CandidateCommit -and $plan.candidate.tree -ceq $CandidateTree -and
            $plan.candidate.baseCommit -ceq $BaseCommit -and $plan.supervisor.commit -ceq $script:DeliverySupervisorCommit -and
            $plan.supervisor.channel -ceq (Get-DeliverySupervisorChannel) -and
            [bool]$plan.supervisor.bootstrap -eq [bool]$script:DeliverySupervisorBootstrap -and
            $plan.planId -ceq (Get-DeliveryCanonicalJsonSha256 (Get-DeliveryPlanIdentity $plan))
        if($valid -and $plan.status -eq 'ready') {
            $expected=@(if($RequireRelease -or $ReleaseCapability.Count) {
                Resolve-DeliveryRequiredReleaseCapabilities -Catalog (Get-DeliveryReleaseStageCatalog $CandidateRoot) -RequireRelease:$RequireRelease -ReleaseCapability $ReleaseCapability
            })
            $valid=(@($plan.releaseCapabilities) -join ',') -ceq ($expected -join ',') -and
                [bool]$plan.requireRelease -eq ($expected.Count -gt 0) -and
                (@($plan.stages | Where-Object mode -eq 'Release' | ForEach-Object id) -join ',') -ceq (@($expected|ForEach-Object{'release.'+$_}) -join ',')
        }
    } catch { $valid=$false }
    if(-not $valid) {
        throw 'DELIVERY_PLAN_CALCULATOR_INVALID: candidate calculation does not match the pinned identity; queue and proof were preserved.'
    }
    $after=(Invoke-RepositoryGit -RepositoryRoot $CandidateRoot -Arguments @('rev-parse','HEAD')).stdout.Trim()
    if($after -cne $CandidateCommit -or (Get-DeliveryFileSha256 $calculator) -cne $sha -or
        @(Get-RepositoryGitPathList -RepositoryRoot $CandidateRoot -Arguments @('status','--porcelain=v1','--untracked-files=all','-z')).Count) {
        throw 'DELIVERY_PLAN_CANDIDATE_CHANGED: calculation changed its pinned inputs; reconstruct the candidate and repeat planning.'
    }
    $plan | Add-Member -NotePropertyName calculator -NotePropertyValue ([ordered]@{protocolVersion=1;commit=$CandidateCommit;sha256=$sha})
    $plan.planId=Get-DeliveryCanonicalJsonSha256 (Get-DeliveryPlanIdentity $plan)
    return $plan
}

function Invoke-DeliveryCandidateComponentPlan {
    param([string]$CandidateRoot, [string]$CandidateCommit)
    $module = Join-Path $CandidateRoot 'scripts/source-delivery-component.ps1'
    if (-not (Test-Path -LiteralPath $module -PathType Leaf)) {
        return Get-OwnedComponentPublicationPlan -CandidateRoot $CandidateRoot -CandidateCommit $CandidateCommit
    }
    $head = (Invoke-WorktreeGit -Root $CandidateRoot -Arguments @('rev-parse','HEAD')).stdout.Trim()
    if ($head -cne $CandidateCommit -or @(Get-RepositoryGitPathList -RepositoryRoot $CandidateRoot -Arguments @('status','--porcelain=v1','--untracked-files=all','-z')).Count) {
        throw 'DELIVERY_PLAN_CANDIDATE_CHANGED: component inspection requires the exact clean candidate.'
    }
    $sha = Get-DeliveryFileSha256 $module
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($module,[ref]$tokens,[ref]$errors)
    if ($errors.Count) { throw 'DELIVERY_PLAN_COMPONENT_INSPECTOR_INVALID: candidate component module has parse errors.' }
    $definitions=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $n.Name -in @('Get-DeliveryRemoteAssetDigest','Get-DeliveryRemoteAssetState')},$true))
    # Historical candidates keep the published byte-verification path. Only
    # stateless remote inspection is delegated, never finalization or preflight.
    $result = if (@($definitions | Where-Object Name -eq 'Get-DeliveryRemoteAssetDigest').Count -eq 1 -and $definitions.Count -eq 2) {
        & {
            param($nodes,$root,$commit)
            foreach($node in $nodes) { . ([scriptblock]::Create($node.Extent.Text)) }
            Get-OwnedComponentPublicationPlan -CandidateRoot $root -CandidateCommit $commit
        } $definitions $CandidateRoot $CandidateCommit
    } else { Get-OwnedComponentPublicationPlan -CandidateRoot $CandidateRoot -CandidateCommit $CandidateCommit }
    $after=(Invoke-WorktreeGit -Root $CandidateRoot -Arguments @('rev-parse','HEAD')).stdout.Trim()
    if ($after -cne $CandidateCommit -or (Get-DeliveryFileSha256 $module) -cne $sha -or
        @(Get-RepositoryGitPathList -RepositoryRoot $CandidateRoot -Arguments @('status','--porcelain=v1','--untracked-files=all','-z')).Count) {
        throw 'DELIVERY_PLAN_CANDIDATE_CHANGED: component inspection changed its pinned inputs.'
    }
    return $result
}

function Add-DeliveryPreparationEstimate {
    param([object]$Plan, [object]$Preparation, [switch]$PendingCompatibility, [object]$CompletedPreparation)
    if (-not $Plan.PSObject.Properties['timeEstimate']) { return }
    $estimate = $Plan.timeEstimate
    $overhead = @('channel-cleanup-and-remote-finalization')
    if ($Preparation -and -not $CompletedPreparation) { $overhead += 'stand-preparation-and-capture' }
    if ($PendingCompatibility) { $overhead += 'preliminary-compatibility-Full' }
    $estimate | Add-Member -NotePropertyName gateEstimatedSeconds -NotePropertyValue $estimate.estimatedSeconds -Force
    $estimate | Add-Member -NotePropertyName unmeasuredPreparation -NotePropertyValue $overhead -Force
    $estimate | Add-Member -NotePropertyName preparationSpentSeconds -NotePropertyValue $(if ($CompletedPreparation -and $CompletedPreparation.PSObject.Properties['durationMs']) { [int][math]::Ceiling($CompletedPreparation.durationMs/1000) } else { 0 }) -Force
    # A main-gate subtotal is not a complete command ETA. Unknown preparatory
    # work stays explicit; hard allowances must never stand in for samples.
    $estimate.estimatedSeconds = $null
    $estimate.note = 'gateEstimatedSeconds is the main-gate subtotal only. Total remaining duration is unknown while unmeasuredPreparation is non-empty; preparationSpentSeconds has already elapsed. Hard limits are stop deadlines.'
    if ($Preparation) { $Plan | Add-Member -NotePropertyName standPreparation -NotePropertyValue $Preparation -Force }
}

function New-AccumulatedDeliveryPlan {
    param([switch]$RequireRelease,[switch]$PreviewOnly)
    Assert-CleanDeliveryWorktree
    [void](Invoke-DeliveryGit -Arguments @("fetch", $script:Remote, "develop"))
    $remoteBefore = Get-GitValue -Arguments @("rev-parse", "$script:Remote/develop")
    $snapshot = Get-SourceRegistrationSnapshot
    # Plan the same membership publication will use: deferred heads are excluded.
    # A legacy owner's readers (advisory Plan bridge) have no deferral records.
    $entries = @(if (Get-Command Get-PublishableQueueEntries -ErrorAction SilentlyContinue) { Get-PublishableQueueEntries -Entries @($snapshot.entries) } else { $snapshot.entries })
    if ($entries.Count -eq 0) { throw "There are no registered develop changes to plan." }
    $startPoint = if ($entries.Count -lt @($snapshot.entries).Count) { [string]$snapshot.remoteBefore } else { Get-SourceRegistrationStartPoint -Snapshot $snapshot }
    $worktree = $null
    try {
        $worktree = New-DeliveryWorktree -StartPoint $startPoint -Purpose "plan-develop"
        Add-QueuedRangesToCandidate -CandidateRoot $worktree.path -Entries $entries -PublishedDevelop $remoteBefore
        $candidate = (Invoke-WorktreeGit -Root $worktree.path -Arguments @("rev-parse", "HEAD")).stdout.Trim()
        $tree = (Invoke-WorktreeGit -Root $worktree.path -Arguments @("rev-parse", "HEAD^{tree}")).stdout.Trim()
        $componentPlan = Invoke-DeliveryCandidateComponentPlan -CandidateRoot $worktree.path -CandidateCommit $candidate
        [void](Assert-ComponentPublicationFinalizerPreflight -CandidateRoot $worktree.path -CandidateCommit $candidate -Plan $componentPlan)
        [void](Resolve-DeliveryPlanAiRulesSource -CandidateRoot $worktree.path)
        $plan = Invoke-DeliveryCandidatePlanCalculation -CandidateRoot $worktree.path -BaseCommit $remoteBefore -CandidateCommit $candidate -CandidateTree $tree -RequireRelease:$RequireRelease -ReleaseCapability @($componentPlan.requiredReleaseCapabilities) -AllowCustomGateFixture:$script:DeliveryCustomGateBoundary
        $preparation = if ($PreviewOnly -and -not (Get-Command Get-DeliveryStandPreparation -CommandType Function -ErrorAction SilentlyContinue)) {
            # The advisory bridge retains the published owner's authority.
            # An old owner cannot forecast stand preparation; do not load new
            # lifecycle operations into it or present an executable plan.
            [pscustomobject]@{status='unavailable-from-published-owner';requiresStateChange=$null}
        } else { Get-DeliveryStandPreparation -CandidateRoot $worktree.path -BaseCommit $remoteBefore -RequireRelease:([bool]($RequireRelease -or @($componentPlan.requiredReleaseCapabilities).Count)) }
        $pendingCompatibility = @($(if ($componentPlan.PSObject.Properties['components']) { $componentPlan.components }) | Where-Object { $_ -and $_.PSObject.Properties['name'] -and $_.name -ceq 'aiRules1c' -and $_.compatibilityPromotionRequired }).Count -gt 0
        Add-DeliveryPreparationEstimate -Plan $plan -Preparation $preparation -PendingCompatibility:$pendingCompatibility
        Set-DeliveryPlanQueue -Plan $plan -Entries $entries
        if ($preparation -and $preparation.requiresStateChange) {
            $plan | Add-Member -NotePropertyName resumable -NotePropertyValue $false -Force
            $plan | Add-Member -NotePropertyName continuation -NotePropertyValue 'Run PublishDevelop without ResumePlan to prepare the selected stand through its owners; it will freeze the executable plan afterward. Plan is read-only.' -Force
            return $plan
        }
        if($PreviewOnly) {
            $plan | Add-Member -NotePropertyName resumable -NotePropertyValue $false
            $plan | Add-Member -NotePropertyName plannerCompatibility -NotePropertyValue 'published planner predates candidate calculation or component inspection; advisory preview only, publication requires a supported replan under the published owner'
        } else {
            $plan | Add-Member -NotePropertyName path -NotePropertyValue (Save-DeliveryQualityPlan -Plan $plan)
        }
        return $plan
    } finally {
        if ($worktree) { Remove-DeliveryWorktree -Worktree $worktree }
        if($PreviewOnly) {Remove-DeliveryPreparedAiRulesWorktree}
    }
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
    if ($trees.Count -ne 1 -or $trees[0] -cne [string]$Plan.candidate.tree) { return $false }
    return Restore-DeliveryQualification -CandidateRoot $CandidateRoot -Tree $trees[0]
}
