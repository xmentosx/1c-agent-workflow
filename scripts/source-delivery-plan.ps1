Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "stand-env-identity.ps1")
$script:DeliveryTrackedPathCache = @{}

function Assert-DeliveryPlanningBudget {
    param([Parameter(Mandatory = $true)][long]$ElapsedMilliseconds)
    if ($ElapsedMilliseconds -gt 120000) {
        throw "DELIVERY_PLAN_BUDGET_EXCEEDED: planning took $([int]($ElapsedMilliseconds / 1000))s; hard limit is 120s. Queue and checkpoint were preserved. Diagnose planning cost, then repeat the same Plan or publication command."
    }
    if ($ElapsedMilliseconds -gt 30000) {
        Write-Warning "Delivery planning exceeded its 30s target ($([int]($ElapsedMilliseconds / 1000))s); the valid plan remains usable within the 120s hard limit."
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

function Get-DeliveryStaticObservedSeconds {
    param([object]$Run)
    $intervals=@($Run.stages | Where-Object {$_.name -notlike 'develop-e2e-*' -and $_.durationMs -gt 0})
    if(-not $intervals.Count -or @($intervals | Where-Object {-not $_.PSObject.Properties['startedAt'] -or -not $_.PSObject.Properties['finishedAt']}).Count) { return $null }
    $end=$null; $seconds=0.0
    foreach($interval in @($intervals | Sort-Object {[datetimeoffset]$_.startedAt})) {
        $start=[datetimeoffset]$interval.startedAt; $finish=[datetimeoffset]$interval.finishedAt
        if($finish -lt $start) { return $null }
        if($null -eq $end -or $start -gt $end) { $seconds+=($finish-$start).TotalSeconds }
        elseif($finish -gt $end) { $seconds+=($finish-$end).TotalSeconds }
        if($null -eq $end -or $finish -gt $end) { $end=$finish }
    }
    return $seconds
}


function Get-DeliveryStaticWorkloadPreview {
    param([string]$CandidateRoot,[object]$Catalog,[string]$BaseCommit)
    $runner=Join-Path $CandidateRoot 'scripts/invoke-pester-shards.ps1'
    if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) { return $null }
    $workers=Resolve-PesterWorkerCount -Mode Develop -RequestedWorkerCount 3 -Explicit $false -Catalog $Catalog
    $output=Join-Path $CandidateRoot 'build/delivery-plan-static'
    $rules=[string](Get-Variable AiRulesSource -ValueOnly -ErrorAction SilentlyContinue)
    # Same digest, runtime observation, legacy lookup, SHA and path checks as
    # execution; PlanOnly never starts a test worker or restores/promotes proof.
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        $preview=& $runner -RepositoryRoot $CandidateRoot -OutputRoot $output -JunitPath (Join-Path $output 'unused.xml') -AiRulesSource $rules -WorkerCount $workers -PlanOnly -BaseRef $BaseCommit
        return (($preview -join [Environment]::NewLine) | ConvertFrom-Json)
    }
    # Full/Develop use Desktop. Core has a different string sort order and must
    # not predict misses using a differently ordered digest inventory.
    [void][IO.Directory]::CreateDirectory($output)
    $name=Join-Path $output ([guid]::NewGuid().ToString('N'))
    $arguments=@('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$runner,'-RepositoryRoot',$CandidateRoot,
        '-OutputRoot',$output,'-JunitPath',(Join-Path $output 'unused.xml'),'-AiRulesSource',$rules,
        '-WorkerCount',[string]$workers,'-PlanOnly','-BaseRef',$BaseCommit)
    $job=$null
    try {
        $job=Start-DeliveryProcess -ArgumentList (($arguments | ForEach-Object {ConvertTo-GitProcessArgument $_}) -join ' ') -WorkingDirectory $CandidateRoot -StandardOutputPath ($name+'.json') -StandardErrorPath ($name+'.stderr.log')
        if(-not $job.process.WaitForExit(120000)) {throw 'Static reuse preview exceeded the unchanged 120-second planning deadline.'}
        $job.process.WaitForExit()
        if($job.process.ExitCode -ne 0) {throw ('Static reuse preview failed: '+[IO.File]::ReadAllText(($name+'.stderr.log'),[Text.Encoding]::UTF8))}
        return (Get-Content -LiteralPath ($name+'.json') -Raw -Encoding UTF8 | ConvertFrom-Json)
    } finally {
        if($job) {Close-DeliveryProcessJob -JobHandle $job.jobHandle -Process $job.process;$job.process.Dispose()}
    }
}

function Get-DeliveryStaticReuseEstimate {
    param([object]$Preview,[object]$Plan,[object[]]$Runs)
    $observations=@($Runs | Where-Object {$_.mode -ceq 'Develop' -and $_.status -ceq 'passed'} | Select-Object -First 5)
    $needsFixture=@($Plan.stages | Where-Object {$_.id -like 'develop.*' -and $_.id -ne 'develop.static'}).Count -gt 0 -or [bool]$Plan.requireRelease
    $samples=@(foreach($run in $observations) {
        $stages=@($run.stages | Where-Object {$_.name -notlike 'develop-e2e-*' -and
            $_.name -ne 'pester' -and ($needsFixture -or $_.name -ne 'qualification-fixture-inputs')})
        $compat=0.0;$other=0.0
        foreach($stage in $stages) {
            if($stage.name -eq 'ai-rules-compatibility') {$compat=[math]::Max($compat,[double]$stage.durationMs/1000)}
            else {$other += [double]$stage.durationMs/1000}
        }
        [math]::Max([double]$Preview.estimatedSeconds,$compat)+$other+[double]$Preview.durationMs/1000
    })
    $samples=@($samples | Sort-Object)
    $seconds=$null
    if($samples.Count) {
        $middle=[int][math]::Floor($samples.Count/2)
        $seconds=[int][math]::Ceiling($(if($samples.Count%2){$samples[$middle]}else{($samples[$middle-1]+$samples[$middle])/2}))
    }
    return [pscustomobject]@{estimatedSeconds=$seconds;sampleCount=$samples.Count;basis='current-shard-reuse-and-historical-overhead';
        pesterSeconds=$Preview.estimatedSeconds;executedFiles=$Preview.executedCount;reusedFiles=$Preview.reusedCount;
        fixtureInputsRequired=$needsFixture;planningOverheadSeconds=[int][math]::Ceiling($Preview.durationMs/1000);
        mandatoryRepeats=@($Preview.files | Where-Object {$_.execution -eq 'execute' -and $_.reason -like 'unqualified external*'} | Select-Object path,estimatedSeconds,reason);
        expensiveRepeats=@($Preview.files | Where-Object execution -eq execute | Sort-Object estimatedSeconds -Descending | Select-Object -First 10 path,estimatedSeconds,reason,changedInputs);
        repeatReasons=@($Preview.files | Where-Object execution -eq execute | Group-Object reason | ForEach-Object {[pscustomobject]@{reason=$_.Name;count=$_.Count}})}
}

function Get-DeliveryPlanTimeEstimate {
    param([object]$Plan,[AllowEmptyCollection()][object[]]$Runs=@(),[object]$StaticPreview)
    $details=@(foreach($stage in $Plan.stages) {
        $samples=@()
        $staticDetail=$null
        if($stage.execution -eq 'reuse') { $seconds=0; $basis='reuse-after-current-static' }
        elseif($stage.id -eq 'develop.static' -and $StaticPreview) {
            $staticDetail=Get-DeliveryStaticReuseEstimate -Preview $StaticPreview -Plan $Plan -Runs $Runs
            $seconds=$staticDetail.estimatedSeconds;$basis=$staticDetail.basis
            $samples=@(1..([int]$staticDetail.sampleCount) | Where-Object {$staticDetail.sampleCount -gt 0})
        }
        else {
            $name=([string]$stage.id).Replace('develop.','develop-e2e-')
            $scenarioRecords=@()
            if(($stage -is [Collections.IDictionary] -and $stage.Contains('scenarios')) -or $stage.PSObject.Properties['scenarios']) {$scenarioRecords=@($stage.scenarios)}
            $workload=@($scenarioRecords | Where-Object {$_.execution -in @('execute','setup')} | ForEach-Object id | Sort-Object)
            $samples=@($Runs | Where-Object {$_.mode -ceq $stage.mode -and $_.status -ceq 'passed'} |
                ForEach-Object {
                    if($stage.id -eq 'develop.static') { Get-DeliveryStaticObservedSeconds -Run $_ }
                    else {
                        $run=$_;$journey=([string]$stage.id).Replace('develop.','')
                        $hasScope=($run -is [Collections.IDictionary] -and $run.Contains('journeyScenarioExecution')) -or $run.PSObject.Properties['journeyScenarioExecution']
                        if($hasScope) {
                            $scopes=$run.journeyScenarioExecution
                            $hasJourney=($scopes -is [Collections.IDictionary] -and $scopes.Contains($journey)) -or $scopes.PSObject.Properties[$journey]
                            # Composition alone is not a native timing sample.
                            if(-not $hasJourney -or -not @($scopes.$journey).Count) {return}
                            if($scenarioRecords.Count -and (@($scopes.$journey | Sort-Object) -join ',') -cne ($workload -join ',')) {return}
                        } elseif($scenarioRecords.Count -and @($scenarioRecords | Where-Object {$_.execution -notin @('execute','setup')}).Count) {return}
                        @($run.stages | Where-Object {$_.name -ceq $name -and $_.status -ceq 'passed' -and $_.durationMs -gt 0} | ForEach-Object {[double]$_.durationMs/1000})
                    }
                } | Where-Object {$null -ne $_ -and $_ -gt 0} | Select-Object -First 5 | Sort-Object)
            $seconds=$null; $basis=$(if($scenarioRecords.Count){'scenario-workload-not-yet-measured'}else{'unknown'})
            if($samples.Count) {
                $middle=[int][math]::Floor($samples.Count/2)
                $seconds=[int][math]::Ceiling($(if($samples.Count%2){$samples[$middle]}else{($samples[$middle-1]+$samples[$middle])/2}))
                $basis='historical-stage-median-advisory'
            }
        }
        $detail=[pscustomobject]@{id=$stage.id;estimatedSeconds=$seconds;sampleCount=$samples.Count;basis=$basis;hardLimitSeconds=$stage.budgetSeconds}
        if($staticDetail) {$detail | Add-Member -NotePropertyName workload -NotePropertyValue $staticDetail}
        $detail
    })
    $unknown=@($details | Where-Object {$null -eq $_.estimatedSeconds})
    $known=[int](($details | Measure-Object estimatedSeconds -Sum).Sum)
    return [pscustomobject]@{kind='advisory-stage-estimate';estimatedSeconds=$(if($unknown.Count){$null}else{$known});
        knownStageSeconds=$known;unknownStages=@($unknown | ForEach-Object {$_.id});hardLimitSeconds=$Plan.executedBudgetSeconds;stages=$details;
        note='Hard limits are stop deadlines, not expected duration. Historical samples do not predict cache misses or a changed workload.'}
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
            supervisor=[ordered]@{ commit=$script:DeliverySupervisorCommit; channel=(Get-DeliverySupervisorChannel); bootstrap=[bool]$script:DeliverySupervisorBootstrap }; candidate=[ordered]@{ commit=$CandidateCommit; tree=$CandidateTree; baseCommit=$BaseCommit }
            requireRelease=[bool]($RequireRelease -or @($ReleaseCapability).Count -gt 0); releaseCapabilities=@($ReleaseCapability | Sort-Object -Unique); paths=@($paths); contracts=@(); stages=$blockedStages; blockers=@($selection.unknownPaths | ForEach-Object { "QUALITY_OWNER_MISSING: $_" })
            executedBudgetSeconds=0; planningDurationMs=[int64]$watch.ElapsedMilliseconds
        }
        $plan.planId = Get-DeliveryCanonicalJsonSha256 -Value (Get-DeliveryPlanIdentity -Plan $plan)
        return $plan
    }
    $journeyPlan = Resolve-DevelopE2EJourneyPlanCore -RepositoryRoot $CandidateRoot -BaseRef $BaseCommit -ChangedPath $paths -Catalog $catalog
    if (@($journeyPlan.unknownPaths).Count -gt 0) { throw "QUALITY_OWNER_MISSING: $(@($journeyPlan.unknownPaths) -join ', ')" }
    $stages = [Collections.Generic.List[object]]::new()
    $developEnvironment = Get-DeliveryPlanEnvironmentIdentity -Mode Develop
    # Resolve this invocation's authoritative common Git directory once. Proof
    # contents and their SHA are still read and validated for every stage.
    $evidenceRoot = Get-DeliveryEvidenceRoot
    # Static qualification stays current. Journey reuse has its own complete
    # shared input contract; legacy evidence retains the exact-tree fallback.
    $staticFingerprint = Get-DeliveryInputFingerprint -StageId "develop.static" -Version 1 -CandidateRoot $CandidateRoot -Pattern @("tests/quality-contracts.json", "scripts/invoke-pester-shards.ps1", "scripts/run-pester-shard.ps1") -ExactPath (@($paths) + @($selection.tests)) -ExternalIdentity ([ordered]@{ candidateTree=$CandidateTree })
    $staticProof = Test-DeliveryStageEvidence -StageId "develop.static" -Fingerprint $staticFingerprint -EvidenceRoot $evidenceRoot
    $staticReusable = $staticProof -and [string]$staticProof.candidate.tree -ceq $CandidateTree
    $stages.Add([pscustomobject][ordered]@{ id="develop.static"; version=1; mode="Develop"; dependsOn=@(); budgetSeconds=[int]$catalog.budgets.fullHardSeconds; inputFingerprint=$staticFingerprint; execution=$(if($staticReusable){"reuse"}else{"execute"}); reason=$(if($staticReusable){"reuse"}else{"complete static inventory with per-file proof reuse"}) }) | Out-Null
    $missingArtifact=''
    if(@($journeyPlan.journeys).Count -and $null -eq $ArtifactBinding) {
        $ArtifactBinding=Find-SourceE2EArtifactBinding -RepositoryRoot $CandidateRoot -SearchRoot @($script:Root) -MissingInput ([ref]$missingArtifact)
    }
    if($ArtifactBinding) { [void](Get-SourceE2EArtifactBindingHashes -RepositoryRoot $CandidateRoot -Binding $ArtifactBinding) }
    foreach ($journey in @($journeyPlan.journeys)) {
        $scenarioRecords=@()
        $stageId = "develop.$journey"
        $reuseDiagnostics=[Collections.Generic.List[object]]::new()
        $standVariable = Get-Variable -Name E2EProjectRoot -Scope Script -ErrorAction SilentlyContinue
        $rulesVariable = Get-Variable -Name AiRulesSource -Scope Script -ErrorAction SilentlyContinue
        $agentVariable = Get-Variable -Name AgentTarget -Scope Script -ErrorAction SilentlyContinue
        $inputs=if($missingArtifact) {
            Add-DevelopReuseDiagnostic -Diagnostics $reuseDiagnostics -Code 'ARTIFACT_BINDING_MISSING' -Inputs @($missingArtifact)
            $null
        } else {
            Get-DevelopE2EInputIdentity -RepositoryRoot $CandidateRoot -Journey $journey -Catalog $catalog -ProjectRoot $(if ($standVariable) { [string]$standVariable.Value } else { '' }) -AiRulesSource $(if ($rulesVariable) { [string]$rulesVariable.Value } else { '' }) -AgentTarget $(if ($agentVariable) { [string]$agentVariable.Value } else { '' }) -ArtifactBinding $ArtifactBinding -Diagnostics $reuseDiagnostics
        }
        if ($inputs) {
            $fingerprint = [string]$inputs.fingerprint
            if($catalog.developJourneys.PSObject.Properties['scenarios']) {
                $scenarioRecords=@(Get-DevelopScenarioReusePlan $CandidateRoot $CandidateTree $journey $inputs $catalog -AllowPendingStatic -ProjectRoot $(if($standVariable){[string]$standVariable.Value}else{''}))
                $reusable=@($scenarioRecords | Where-Object {$_.execution -in @('execute','setup')}).Count -eq 0
                $fingerprint=Get-DeliveryCanonicalJsonSha256 ([ordered]@{inputs=$inputs.fingerprint;scenarios=$catalog.developJourneys.scenarios.$journey;scope=$catalog.developJourneys.scenarioInputs})
            } else {
                $ancestor = Get-DevelopE2EAncestorQualification -RepositoryRoot $CandidateRoot -Tree $CandidateTree -Journey $journey -StandStateSha256 ([string]$inputs.inventory.external.standStateSha256) -InputIdentity $inputs -AllowPendingStatic -Diagnostics $reuseDiagnostics
                $reusable = $null -ne $ancestor
            }
        } else {
            Add-DevelopReuseDiagnostic -Diagnostics $reuseDiagnostics -Code 'COMPLETE_BINDING_UNAVAILABLE'
            $routeContractIds = @($catalog.developJourneys.routes.$journey.contracts | ForEach-Object { [string]$_ })
            $routePatterns = @($catalog.contracts | Where-Object { [string]$_.id -in $routeContractIds } | ForEach-Object { @($_.paths) })
            $fingerprint = Get-DeliveryInputFingerprint -StageId $stageId -Version 1 -CandidateRoot $CandidateRoot -Pattern $routePatterns -ExternalIdentity ([ordered]@{ candidateTree=$CandidateTree; environment=$developEnvironment })
            $proof = Test-DeliveryStageEvidence -StageId $stageId -Fingerprint $fingerprint -EvidenceRoot $evidenceRoot
            $reusable = $proof -and [string]$proof.candidate.tree -ceq $CandidateTree
        }
        $stages.Add([pscustomobject][ordered]@{ id=$stageId; version=1; mode="Develop"; dependsOn=@("develop.static"); budgetSeconds=(Get-DevelopE2EJourneyHardBudgetSeconds -Catalog $catalog -Journey $journey); inputFingerprint=$fingerprint; execution=$(if($reusable){"reuse"}else{"execute"}); reason=$(if($reusable -and $inputs){"verified applicable ancestor inputs; current static proof required"}elseif($reusable){"matching exact-tree stage evidence"}elseif(-not $inputs){"complete binding unavailable; no matching exact-tree proof"}else{"no eligible ancestor for current workload/environment and proof requirements"}) }) | Out-Null
        $stages[$stages.Count-1] | Add-Member -NotePropertyName reuseDiagnostics -NotePropertyValue @($reuseDiagnostics.ToArray())
        if($scenarioRecords.Count) {
            $view=@(foreach($record in $scenarioRecords) {
                [pscustomobject]@{id=$record.id;execution=$record.execution;dependsOn=$record.dependsOn;applicable=$record.applicable;
                    evidenceCommit=$(if($record.proof){$record.proof.report.repository.commit}else{''});
                    evidenceSha256=$(if($record.proof){$record.proof.sha256}else{''});reuseDiagnostics=@($record.reuseDiagnostics | Select-Object -First 1);
                    omittedDiagnosticCount=[math]::Max(0,@($record.reuseDiagnostics).Count-1)}
            })
            $stages[$stages.Count-1] | Add-Member -NotePropertyName scenarios -NotePropertyValue $view
        }
    }
    $orderedReleaseCapabilities = @()
    $releaseEnclosingOverhead = $null
    if ($RequireRelease -or @($ReleaseCapability).Count -gt 0) {
    $releaseCatalog = Get-DeliveryReleaseStageCatalog -CandidateRoot $CandidateRoot
    $orderedReleaseCapabilities = @(Resolve-DeliveryRequiredReleaseCapabilities -Catalog $releaseCatalog -RequireRelease:$RequireRelease -ReleaseCapability $ReleaseCapability)
    if ($orderedReleaseCapabilities.Count -gt 0) {
        if ($releaseCatalog.PSObject.Properties['enclosingOverheadSeconds']) {
            $releaseBudget = Get-ReleaseE2EBudgetProjection -StageCatalog $releaseCatalog -QualityCatalog $catalog -ReleaseCapability $orderedReleaseCapabilities
            $releaseEnclosingOverhead = [int]$releaseBudget.enclosingOverheadSeconds
        }
        $releaseEnvironment = Get-DeliveryPlanEnvironmentIdentity -Mode Release
        $fingerprints = @{}
        foreach ($definition in @($releaseCatalog.stages | Where-Object { [string]$_.id -in $orderedReleaseCapabilities })) {
            $dependencies = @($definition.dependsOn | ForEach-Object { [string]$fingerprints[[string]$_] })
            $stageId = "release.$([string]$definition.id)"
            $fingerprint = Get-DeliveryInputFingerprint -StageId $stageId -Version ([int]$definition.version) -CandidateRoot $CandidateRoot -Pattern @($definition.paths) -DependencyFingerprint $dependencies -ExternalIdentity $releaseEnvironment
            $fingerprints[[string]$definition.id] = $fingerprint
            $alwaysExecute = $definition.PSObject.Properties["alwaysExecute"] -and [bool]$definition.alwaysExecute
            $proof = if ($alwaysExecute) { $null } else { Test-DeliveryStageEvidence -StageId $stageId -Fingerprint $fingerprint -EvidenceRoot $evidenceRoot }
            $stages.Add([pscustomobject][ordered]@{ id=$stageId; version=[int]$definition.version; mode="Release"; dependsOn=@($definition.dependsOn | ForEach-Object { "release.$_" }); budgetSeconds=[int]$definition.budgetSeconds; alwaysExecute=[bool]$alwaysExecute; inputFingerprint=$fingerprint; execution=$(if($proof){"reuse"}else{"execute"}); reason=$(if($alwaysExecute){"freshness and cleanup contract"}elseif($proof){"matching stage evidence"}else{"required Release capability"}) }) | Out-Null
        }
    }
    }
    $staticPreview=Get-DeliveryStaticWorkloadPreview -CandidateRoot $CandidateRoot -Catalog $catalog -BaseCommit $BaseCommit
    $watch.Stop()
    Assert-DeliveryPlanningBudget -ElapsedMilliseconds $watch.ElapsedMilliseconds
    [int64]$executedBudget = 0
    foreach ($stage in @($stages)) { if ([string]$stage.execution -eq "execute") { $executedBudget += [int]$stage.budgetSeconds } }
    $plan = [pscustomobject][ordered]@{
        schemaVersion=1; kind="itl-delivery-plan"; planId=""; status="ready"; createdAt=[DateTime]::UtcNow.ToString("o")
        supervisor=[ordered]@{ commit=$script:DeliverySupervisorCommit; channel=(Get-DeliverySupervisorChannel); bootstrap=[bool]$script:DeliverySupervisorBootstrap }
        candidate=[ordered]@{ commit=$CandidateCommit; tree=$CandidateTree; baseCommit=$BaseCommit }
        requireRelease=[bool]($orderedReleaseCapabilities.Count -gt 0); releaseCapabilities=$orderedReleaseCapabilities; paths=@($paths); contracts=@($selection.contracts | ForEach-Object { [string]$_.id }); stages=@($stages)
        executedBudgetSeconds=$executedBudget; planningDurationMs=[int64]$watch.ElapsedMilliseconds
    }
    if ($null -ne $releaseEnclosingOverhead) {
        $plan | Add-Member -NotePropertyName releaseEnclosingOverheadSeconds -NotePropertyValue $releaseEnclosingOverhead
        $plan.executedBudgetSeconds += $releaseEnclosingOverhead
    }
    $timingRuns=@()
    if(Get-Command Get-DeliveryRunHistory -ErrorAction SilentlyContinue) {
        $timingRuns=@((Get-DeliveryRunHistory -Limit 32 -IncludeDetails).lastRuns)
    }
    $plan | Add-Member -NotePropertyName timeEstimate -NotePropertyValue (Get-DeliveryPlanTimeEstimate -Plan $plan -Runs $timingRuns -StaticPreview $staticPreview)
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

function New-AccumulatedDeliveryPlan {
    param([switch]$RequireRelease,[switch]$PreviewOnly)
    Assert-CleanDeliveryWorktree
    [void](Invoke-DeliveryGit -Arguments @("fetch", $script:Remote, "develop"))
    $remoteBefore = Get-GitValue -Arguments @("rev-parse", "$script:Remote/develop")
    $snapshot = Get-SourceRegistrationSnapshot
    $entries = @($snapshot.entries)
    if ($entries.Count -eq 0) { throw "There are no registered develop changes to plan." }
    $worktree = $null
    try {
        $worktree = New-DeliveryWorktree -StartPoint (Get-SourceRegistrationStartPoint -Snapshot $snapshot) -Purpose "plan-develop"
        Add-QueuedRangesToCandidate -CandidateRoot $worktree.path -Entries $entries -PublishedDevelop $remoteBefore
        $candidate = (Invoke-WorktreeGit -Root $worktree.path -Arguments @("rev-parse", "HEAD")).stdout.Trim()
        $tree = (Invoke-WorktreeGit -Root $worktree.path -Arguments @("rev-parse", "HEAD^{tree}")).stdout.Trim()
        $componentPlan = Get-OwnedComponentPublicationPlan -CandidateRoot $worktree.path -CandidateCommit $candidate
        [void](Assert-ComponentPublicationFinalizerPreflight -CandidateRoot $worktree.path -CandidateCommit $candidate -Plan $componentPlan)
        [void](Resolve-DeliveryPlanAiRulesSource -CandidateRoot $worktree.path)
        $plan = Invoke-DeliveryCandidatePlanCalculation -CandidateRoot $worktree.path -BaseCommit $remoteBefore -CandidateCommit $candidate -CandidateTree $tree -RequireRelease:$RequireRelease -ReleaseCapability @($componentPlan.requiredReleaseCapabilities) -AllowCustomGateFixture:$script:DeliveryCustomGateBoundary
        Set-DeliveryPlanQueue -Plan $plan -Entries $entries
        if($PreviewOnly) {
            $plan | Add-Member -NotePropertyName resumable -NotePropertyValue $false
            $plan | Add-Member -NotePropertyName plannerCompatibility -NotePropertyValue 'published calculator predates candidate delegation; advisory preview only, publication requires a supported replan under the published owner'
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
