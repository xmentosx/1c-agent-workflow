# Loaded only after the explicit custom-gate return. Native selection and
# qualification keep their complete dependencies here.
. (Join-Path $PSScriptRoot "develop-e2e-qualification.ps1")

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
    $measured=@($observations | Where-Object {@($_.stages | Where-Object {
        $_.name -eq 'ai-rules-compatibility' -and $_.PSObject.Properties['metrics'] -and $_.metrics -and
        $_.metrics.PSObject.Properties['timingKind'] -and $_.metrics.PSObject.Properties['processDurationMs'] -and $_.metrics.timingKind -eq 'process-exit'
    }).Count -gt 0})
    if($measured.Count) {$observations=$measured}
    $needsFixture=@($Plan.stages | Where-Object {$_.id -like 'develop.*' -and $_.id -ne 'develop.static'}).Count -gt 0 -or [bool]$Plan.requireRelease
    $samples=@(foreach($run in $observations) {
        $stages=@($run.stages | Where-Object {$_.name -notlike 'develop-e2e-*' -and
            $_.name -ne 'pester' -and ($needsFixture -or $_.name -ne 'qualification-fixture-inputs')})
        $compat=0.0;$other=0.0
        foreach($stage in $stages) {
            if($stage.name -eq 'ai-rules-compatibility') {
                $duration=[double]$stage.durationMs
                if($stage.PSObject.Properties['metrics'] -and $stage.metrics -and $stage.metrics.PSObject.Properties['timingKind'] -and $stage.metrics.PSObject.Properties['processDurationMs'] -and $stage.metrics.timingKind -eq 'process-exit') {$duration=[double]$stage.metrics.processDurationMs}
                $compat=[math]::Max($compat,$duration/1000)
            }
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
        compatibilityTimingBasis=$(if($measured.Count){'process-exit'}else{'legacy-envelope-upper-bound'});
        pesterSeconds=$Preview.estimatedSeconds;executedFiles=$Preview.executedCount;reusedFiles=$Preview.reusedCount;
        fixtureInputsRequired=$needsFixture;planningOverheadSeconds=[int][math]::Ceiling($Preview.durationMs/1000);
        mandatoryRepeats=@($Preview.files | Where-Object {$_.execution -eq 'execute' -and $_.reason -like 'unqualified external*'} | Select-Object path,estimatedSeconds,reason);
        expensiveRepeats=@($Preview.files | Where-Object execution -eq execute | Sort-Object estimatedSeconds -Descending | Select-Object -First 10 path,estimatedSeconds,reason,changedInputs);
        repeatReasons=@($Preview.files | Where-Object execution -eq execute | Group-Object reason | ForEach-Object {[pscustomobject]@{reason=$_.Name;count=$_.Count}})}
}

function Get-DeliveryPlanTimingRuns {
    if (-not (Get-Command Get-DeliveryRunHistory -ErrorAction SilentlyContinue)) { return @() }
    # Read the existing bounded hot index, never the raw run directory. Filter
    # before limiting so a burst of Targeted runs cannot evict Develop samples.
    $history=Get-DeliveryRunHistory -Limit ([int]::MaxValue) -IncludeDetails
    # Each stage below selects its own five matching observations. Other Release
    # capabilities must not displace this stage's samples either.
    $history.lastRuns | Where-Object {$_.mode -cin @('Develop','Release') -and $_.status -ceq 'passed'}
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
                    elseif($stage.id -like 'release.*') {
                        $run=$_;$component=([string]$stage.id).Substring('release.'.Length)
                        # The gate stores component wall time in releaseE2E,
                        # while its ordinary stage is only the aggregate runner.
                        if($run.PSObject.Properties['releaseE2E'] -and $run.releaseE2E) {
                            @($run.releaseE2E.slowestStages | Where-Object {
                                $_.name -ceq $component -and $_.execution -ceq 'executed' -and $_.durationMs -gt 0
                            } | ForEach-Object {[double]$_.durationMs/1000})
                        }
                    }
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

function New-DeliveryNativeQualityPlanForCandidate {
    param(
        [Parameter(Mandatory = $true)][string]$CandidateRoot,
        [Parameter(Mandatory = $true)][string]$BaseCommit,
        [Parameter(Mandatory = $true)][string]$CandidateCommit,
        [Parameter(Mandatory = $true)][string]$CandidateTree,
        [switch]$RequireRelease,
        [string[]]$ReleaseCapability = @(),
        [switch]$AllowCustomGateFixture,
        [object]$ArtifactBinding = $null,
        [string[]]$Paths, [Diagnostics.Stopwatch]$Watch
    )
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
                $artifacts=ConvertTo-DevelopScenarioArtifactIdentity $inputs.inventory.external.artifacts $journey @($record.id)
                [pscustomobject]@{id=$record.id;execution=$record.execution;dependsOn=$record.dependsOn;applicable=$record.applicable;
                    artifactInputs=@($artifacts.PSObject.Properties | Where-Object {$_.Value -cne 'opaque-broker-not-executed'} | ForEach-Object Name);
                    selectionReasons=@(if($journeyPlan.PSObject.Properties['scenarioReasons']) {$journeyPlan.scenarioReasons.$journey | Where-Object {$record.id -in @($_.scenarios)}});
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
    $timingRuns=@(Get-DeliveryPlanTimingRuns)
    $plan | Add-Member -NotePropertyName timeEstimate -NotePropertyValue (Get-DeliveryPlanTimeEstimate -Plan $plan -Runs $timingRuns -StaticPreview $staticPreview)
    $plan.planId = Get-DeliveryCanonicalJsonSha256 -Value (Get-DeliveryPlanIdentity -Plan $plan)
    return $plan
}
