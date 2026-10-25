function Get-VerificationModel {
    $value = ([string](Get-EnvValue -Name 'ITL_VERIFICATION_MODEL')).Trim().ToLowerInvariant()
    if (-not $value) { return 'change' }
    if ($value -notin @('change', 'cumulative')) {
        throw 'VERIFICATION_MODEL_INVALID: ITL_VERIFICATION_MODEL must be change or cumulative. Correct the setting and repeat the original command.'
    }
    return $value
}

function Get-VerificationChangePath {
    return (Join-Path (Get-VerificationSelectionStateRoot) 'current-change.json')
}

function Archive-VerificationChangeForReset {
    param([Parameter(Mandatory=$true)][object]$State)
    $path=Get-VerificationChangePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
    # Only the completed reset owner retires a task; ordinary planning cannot.
    $archive=[string](Get-StateValue $State 'resetArchivePath' '')
    if (-not $archive -or -not (Test-Path -LiteralPath $archive -PathType Container)) { throw 'VERIFICATION_CHANGE_RESET_ARCHIVE_MISSING: resume the original reset owner; preserve current acceptance.' }
    $saved=Join-Path (Get-VerificationSelectionStateRoot) ('changes/reset-' + [string]$State.resetNewHead + '.json')
    Write-Utf8TextAtomic -Path $saved -Value (Read-Utf8Text -Path $path)
    if ((Get-FileHash -LiteralPath $saved -Algorithm SHA256).Hash -cne (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash) { throw 'VERIFICATION_CHANGE_RESET_ARCHIVE_CHANGED: preserve current acceptance and resume reset.' }
    Remove-Item -LiteralPath $path -Force
}

function Read-VerificationChange {
    $path = Get-VerificationChangePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    $value = Read-Utf8Text -Path $path | ConvertFrom-Json -ErrorAction Stop
    if ([int]$value.schemaVersion -ne 1 -or [string]$value.model -cne 'change') {
        throw 'VERIFICATION_CHANGE_INVALID: preserve current-change.json and restore it through its verification owner.'
    }
    if ([string](Get-VerificationCatalogValue -Value $value -Name scopeIdentity -Default '') -cne (Get-VerificationChangeScopeIdentity -Change $value)) { throw 'VERIFICATION_CHANGE_RECORD_CHANGED: preserve the impact plan; repeat begin-verification-change through its owner instead of editing runtime state.' }
    return $value
}

function Get-VerificationChangeScopeIdentity {
    param([Parameter(Mandatory=$true)][object]$Change)
    $criteria = @($Change.criteria | ForEach-Object {
        [ordered]@{id=$_.id;expectedResult=$_.expectedResult;decision=$_.decision;reason=(Get-VerificationCatalogValue -Value $_ -Name reason -Default '');checkIds=@(Get-VerificationCatalogValue -Value $_ -Name checkIds -Default @())}
    })
    $value=[ordered]@{taskId=$Change.taskId;baseTree=$Change.baseTree;tree=$Change.tree;targetIdentity=$Change.targetIdentity;checkerIdentity=$Change.checkerIdentity;checks=@($Change.checks);paths=@($Change.paths);criteria=$criteria;requirements=@($Change.requirements);planArtifact=$Change.planArtifact;retainedDispositions=@($Change.retainedDispositions);inheritedEvidence=@(Get-VerificationCatalogValue -Value $Change -Name inheritedEvidence -Default @());priorAcceptedArtifact=(Get-VerificationCatalogValue -Value $Change -Name priorAcceptedArtifact -Default $null)}
    return (Get-VerificationSelectionSha256 -Text ($value|ConvertTo-Json -Depth 16 -Compress))
}

function Get-VerificationChangeCheckerIdentity {
    $parts = @('verification-change-v1')
    foreach ($command in @(Get-Command -CommandType Function '*-VerificationChange*' | Sort-Object Name)) {
        $parts += "$($command.Name)=$($command.Definition.Replace("`r`n", "`n"))"
    }
    return (Get-VerificationSelectionSha256 -Text ($parts -join "`n"))
}

function Assert-VerificationChangeCurrent {
    param([Parameter(Mandatory = $true)][object]$Change)
    if ([string]$Change.tree -cne (Get-VerificationSelectionEffectiveTree) -or
        [string]$Change.checkerIdentity -cne (Get-VerificationChangeCheckerIdentity)) {
        throw 'VERIFICATION_CHANGE_STALE: source or its assessor changed. Preserve evidence, update the impact plan with begin-verification-change, then repeat the original command; the accepted base is unchanged.'
    }
    if (@($Change.requirements).Count -gt 0) { Assert-VerificationArtifactReferences -Artifacts @($Change.requirements) }
    Assert-VerificationArtifactReferences -Artifacts @($Change.planArtifact)
    $inherited=@(Get-VerificationCatalogValue -Value $Change -Name inheritedEvidence -Default @())
    if ($inherited.Count -gt 0 -and ($Change.status -ne 'accepted' -or $null -eq (Read-VerificationChangeAcceptedRecord -Change $Change -Current))) { Assert-VerificationArtifactReferences -Artifacts $inherited }
}

function Read-VerificationChangeAcceptedRecord {
    param([Parameter(Mandatory=$true)][object]$Change, [switch]$Current)
    if (-not $Change.acceptedArtifact) { return $null }
    Assert-VerificationArtifactReferences -Artifacts @($Change.acceptedArtifact)
    $accepted = Read-Utf8Text -Path (Resolve-ProjectPath ([string]$Change.acceptedArtifact.path)) | ConvertFrom-Json
    Assert-VerificationArtifactReferences -Artifacts @($accepted.observedArtifacts)
    if ($accepted.status -cne 'accepted' -or [string]$accepted.scopeIdentity -cne (Get-VerificationChangeScopeIdentity -Change $accepted)) {
        throw 'VERIFICATION_CHANGE_ACCEPTED_INVALID: preserve the accepted archive and restore it through the verification owner.'
    }
    $matchesCurrent=[string]$accepted.runToken -ceq [string]$Change.runToken -and [string]$accepted.scopeIdentity -ceq [string]$Change.scopeIdentity
    if ($Current -and -not $matchesCurrent) { return $null }
    if (-not $matchesCurrent) {
        $prior=Get-VerificationCatalogValue -Value $Change -Name priorAcceptedArtifact -Default $null
        if ($null -eq $prior -or [string]$prior.path -cne [string]$Change.acceptedArtifact.path -or [string]$prior.sha256 -cne [string]$Change.acceptedArtifact.sha256 -or [string]$accepted.tree -cne [string]$Change.baseTree) { throw 'VERIFICATION_CHANGE_BASE_CHANGED: preserve the frozen prior accepted base; restore the current record through its owner.' }
    }
    return $accepted
}

function Assert-VerificationChangeReady {
    param([Parameter(Mandatory=$true)][object]$State)
    $change=Read-VerificationChange
    if ($null -eq $change) {
        Set-RunFailureContext -Category missing-suite -RequiredAction 'prepare-current-change-plan-and-repeat-original-itl-command'
        throw 'VERIFICATION_CHANGE_REQUIRED: use begin-verification-change to inspect the full unaccepted delta, prepare its impact plan, then repeat with -VerificationEvidencePath <plan.json>; no history or criteria will be discarded.'
    }
    Assert-VerificationChangeCurrent -Change $change
    if ([string]$change.targetIdentity -cne (Get-VerificationRetainedTargetIdentity -State $State)) { throw 'VERIFICATION_CHANGE_TARGET_CHANGED: prepare and observe the current plan on the exact authorized target.' }
    return $change
}

function Get-VerificationChangeBaseTree {
    param([Parameter(Mandatory = $true)][object]$State, [AllowNull()][object]$Previous)
    if ($null -ne $Previous) {
        if ($Previous.acceptedArtifact) {
            $accepted = Read-VerificationChangeAcceptedRecord -Change $Previous
            return [string]$accepted.tree
        }
        return [string]$Previous.baseTree
    }
    # Adopt only an existing successful owner boundary, never the caller's HEAD.
    $proof = Read-VerificationSelectionProof
    if ([string](Get-StateValue -State $State -Name 'lastVerificationStatus' -Default '') -ceq 'passed' -and
        [string](Get-StateValue -State $State -Name 'lastVerifiedFingerprint' -Default '') -and $null -ne $proof -and
        [string]$proof.tree -match '^[a-f0-9]{40}$') {
        foreach ($receipt in @($proof.suiteEvidence)) {
            if ([string]$receipt.status -cne 'passed') { throw 'VERIFICATION_CHANGE_BASE_UNVERIFIED: prior suite failed; resolve its existing continuation first.' }
            Assert-VerificationArtifactReferences -Artifacts @($receipt.artifacts) -JUnit
        }
        return [string]$proof.tree
    }
    $base = Get-DevBranchResultTransferBaseCommit -State $State
    $tree = ([string](Get-GitOutput @('rev-parse', "$base^{tree}"))).Trim()
    if ($tree -notmatch '^[a-f0-9]{40}$') { throw 'VERIFICATION_CHANGE_BASE_MISSING: restore the branch lifecycle baseline through its existing owner; do not adopt HEAD as a verified base.' }
    return $tree
}

function Get-VerificationChangeChecks {
    param([Parameter(Mandatory = $true)][object]$Plan)
    $checks = @($Plan.checks)
    if ($checks.Count -eq 0) { throw 'VERIFICATION_CHANGE_CHECKS_MISSING: declare sufficient current checks and their expected results in the impact plan.' }
    $catalog = Read-VerificationSuiteCatalog -ApplicationFeatureFiles @(Get-VanessaApplicationFeatureFiles -FeaturePath (Get-VanessaFeaturesPath))
    $yax = Read-YAxUnitSuiteCatalog -ModuleFiles @(Get-YAxUnitModuleFiles)
    $result = @()
    foreach ($check in $checks) {
        $suiteId=[string](Get-VerificationCatalogValue -Value $check -Name 'suiteId' -Default '')
        $groupId=[string](Get-VerificationCatalogValue -Value $check -Name 'groupId' -Default '')
        if ($suiteId -and $groupId) { throw 'VERIFICATION_CHANGE_RETAINED_AMBIGUOUS: reference exactly one suiteId or groupId.' }
        if ($suiteId -or $groupId) {
            $bound = @(if ($suiteId) { $catalog.obligations | Where-Object { $_.suiteId -ceq $suiteId } } else { $yax.obligations | Where-Object { $_.groupId -ceq $groupId } })
            if ($bound.Count -ne 1 -or $bound[0].retention -cne 'retained') { throw 'VERIFICATION_CHANGE_RETAINED_UNKNOWN: reference an existing retained suiteId or groupId; do not invent its result.' }
            $entry = @(if ($suiteId) { $catalog.suites | Where-Object id -CEQ $suiteId } else { $yax.groups | Where-Object id -CEQ $groupId })
            if ($entry.Count -ne 1 -or $entry[0].purpose -notin @('acceptance','default-fast')) { throw 'VERIFICATION_CHANGE_RETAINED_EXPLICIT: reference normal acceptance/default-fast coverage, or capture the existing named diagnostic run through a current one-off JUnit receipt. Its diagnostic status alone cannot accept the task.' }
            $result += $bound[0]
            continue
        }
        if (-not (Get-VerificationCatalogValue -Value $check -Name 'retention' -Default '')) { $check | Add-Member retention 'one-off' }
        if (-not (Get-VerificationCatalogValue -Value $check -Name 'retentionReason' -Default '')) { $check | Add-Member retentionReason 'Current change evidence; retention is decided separately.' }
        if (-not (Get-VerificationCatalogValue -Value $check -Name 'cadence' -Default '')) { $check | Add-Member cadence 'explicit' }
        if ([string]$check.retention -cne 'one-off') { throw 'VERIFICATION_CHANGE_CHECK_INVALID: reference retained coverage by suiteId/groupId, or declare an observed one-off check.' }
        $result += @(Read-VerificationObligationDecisions -Catalog ([pscustomobject]@{schemaVersion=2;obligations=@($check)}) -CatalogPath (Get-VerificationChangePath) -Runner vanessa)
    }
    if (@($result.id | Sort-Object -Unique).Count -ne $result.Count) { throw 'VERIFICATION_CHANGE_CHECK_DUPLICATE: check ids must be unique.' }
    $scopes=@(Get-VerificationFingerprintScopePaths | ForEach-Object { ([string]$_ -replace '\\','/').TrimEnd('/') })
    foreach ($check in $result) {
        foreach ($pattern in @($check.inputPaths)) {
            $prefix=([string]$pattern -replace '[*?\[].*$', '').TrimEnd('/')
            if (@($scopes | Where-Object { $prefix -ieq $_ -or $prefix.StartsWith(([string]$_).TrimEnd('/')+'/',[StringComparison]::OrdinalIgnoreCase) }).Count -eq 0) { throw "VERIFICATION_CHANGE_INPUT_SCOPE_REQUIRED: '$pattern' is outside the known 1C/test input envelope. Declare its bounded inputPaths through the existing verification catalog before preparing this plan; ignored or unsnapshotted inputs cannot prove the current code." }
        }
    }
    return $result
}

function Start-VerificationChange {
    param([string]$EvidencePath = '')
    if ((Get-VerificationModel) -cne 'change') { throw 'VERIFICATION_CHANGE_MODEL: select ITL_VERIFICATION_MODEL=change before preparing a change plan.' }
    $state = Read-DevBranchState -Name $DevBranchName
    Assert-DevelopmentBranchWorktreeContext -State $state -Operation 'begin-verification-change'
    if (-not $EvidencePath) {
        $previous = Read-VerificationChange
        $base = Get-VerificationChangeBaseTree -State $state -Previous $previous
        $tree = Get-VerificationSelectionEffectiveTree
        return [pscustomobject]@{
            model='change';status='planning';baseTree=$base;tree=$tree
            changedPaths=@(Get-VerificationSelectionChangedPaths -BaseTree $base -CurrentTree $tree)
            taskId=(Get-VerificationCatalogValue -Value $previous -Name taskId -Default '')
            criteria=@(Get-VerificationCatalogValue -Value $previous -Name criteria -Default @())
            requirementPaths=@(Get-VerificationCatalogValue -Value $previous -Name requirements -Default @() | ForEach-Object path)
        }
    }
    $full = Resolve-ProjectPath $EvidencePath
    $relative = Get-VerificationRepoRelativePath -Path $full
    $plan = Read-Utf8Text -Path $full | ConvertFrom-Json -ErrorAction Stop
    if ([string]$plan.taskId -notmatch '^[a-z0-9][a-z0-9._-]*$') { throw 'VERIFICATION_CHANGE_TASK_INVALID: use a stable taskId for this feature and its acceptance.' }
    $previous = Read-VerificationChange
    if ($null -ne $previous -and [string]$previous.taskId -cne [string]$plan.taskId -and -not [bool](Get-VerificationChangeTaskAssessment -Change $previous).accepted) {
        throw 'VERIFICATION_CHANGE_TASK_PENDING: finish or explicitly resolve the previous task acceptance; a new task name cannot discard its remaining criteria.'
    }
    Repair-OneCSourceLineEndings | Out-Null
    $base = Get-VerificationChangeBaseTree -State $state -Previous $previous
    $tree = Get-VerificationSelectionEffectiveTree
    $changed = @(Get-VerificationSelectionChangedPaths -BaseTree $base -CurrentTree $tree)
    $checks = @(Get-VerificationChangeChecks -Plan $plan)
    foreach ($known in @(Get-VerificationCatalogOneOffObligations)) {
        $current = @($checks | Where-Object id -eq $known.id)
        if ($current.Count -gt 0 -and ((Get-VerificationOneOffObligationHash -Obligation $current[0]) -cne (Get-VerificationOneOffObligationHash -Obligation $known))) {
            throw 'VERIFICATION_CHANGE_EXISTING_CHECK_CHANGED: a current plan cannot silently redefine an existing one-off obligation.'
        }
    }
    $coverage = @($plan.paths)
    foreach ($path in $changed) {
        $entry = @($coverage | Where-Object { [string]$_.path -ceq $path })
        if ($entry.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$entry[0].reason)) {
            throw "VERIFICATION_CHANGE_PATH_PENDING: '$path' needs one impact decision, reason and sufficient checkIds; update the plan and repeat begin-verification-change."
        }
        $ids = @($entry[0].checkIds)
        if ($ids.Count -eq 0 -or @($ids | Where-Object { $_ -notin @($checks.id) }).Count -gt 0) {
            throw "VERIFICATION_CHANGE_PATH_UNCOVERED: '$path' has no declared current check."
        }
        foreach ($id in $ids) {
            $check = @($checks | Where-Object id -eq $id)[0]
            if (@($check.inputPaths | Where-Object { Test-VerificationRepoPathPattern -Path $path -Pattern $_ }).Count -eq 0) {
                throw "VERIFICATION_CHANGE_PATH_UNCOVERED: '$id' does not cover '$path'."
            }
        }
    }
    if (@($coverage | Where-Object { [string]$_.path -cnotin $changed }).Count -gt 0) {
        throw 'VERIFICATION_CHANGE_SCOPE_CHANGED: path decisions must describe exactly the helper-owned unaccepted delta, including deletions and uncommitted edits.'
    }
    $requirements = @(New-VerificationArtifactReferences -Paths @(Get-VerificationCatalogValue -Value $plan -Name requirementPaths -Default @() | ForEach-Object { Resolve-ProjectPath ([string]$_) }))
    if ($null -ne $previous -and [string]$previous.taskId -ceq [string]$plan.taskId) {
        $oldPaths = @($previous.requirements | ForEach-Object path)
        if (@($oldPaths | Where-Object { $_ -notin @($requirements.path) }).Count -gt 0) {
            throw 'VERIFICATION_CHANGE_REQUIREMENTS_OMITTED: preserve the referenced task requirements; a new plan cannot hide acceptance by changing documents.'
        }
    }
    if (($requirements.Count -eq 0 -and ([string]::IsNullOrWhiteSpace([string](Get-VerificationCatalogValue -Value $plan -Name taskDescription -Default '')) -or [string]::IsNullOrWhiteSpace([string](Get-VerificationCatalogValue -Value $plan -Name sourceReference -Default '')))) -or @($plan.criteria).Count -eq 0) { throw 'VERIFICATION_CHANGE_ACCEPTANCE_MISSING: reference existing task requirements and list every acceptance criterion, including pending ones.' }
    $sameTask = $null -ne $previous -and [string]$previous.taskId -ceq [string]$plan.taskId
    $previousCriteria = @(if ($sameTask) { Get-VerificationCatalogValue -Value $previous -Name 'criteria' -Default @() })
    $acceptedPrevious = if ($sameTask -and $previous.acceptedArtifact) { Read-VerificationChangeAcceptedRecord -Change $previous } else { $null }
    $requiredIds = @($previousCriteria | ForEach-Object { [string]$_.id })
    if ($null -eq $previous) { $requiredIds += @(Get-VerificationCatalogOneOffObligations | ForEach-Object { [string]$_.id }) }
    foreach ($artifact in $requirements) {
        $text = Read-Utf8Text -Path (Resolve-ProjectPath ([string]$artifact.path))
        $requiredIds += @([regex]::Matches($text, '\bAC-\d+\b') | ForEach-Object Value | Select-Object -Unique)
    }
    $criteria = @($plan.criteria)
    $inheritedEvidence = @()
    if (@($criteria.id | Sort-Object -Unique).Count -ne $criteria.Count -or @($requiredIds | Where-Object { $_ -cnotin @($criteria.id) }).Count -gt 0) {
        throw 'VERIFICATION_CHANGE_ACCEPTANCE_INCOMPLETE: preserve every prior and declared AC criterion; omission does not waive acceptance.'
    }
    foreach ($criterion in $criteria) {
        if (-not $criterion.id -or [string]::IsNullOrWhiteSpace([string]$criterion.expectedResult) -or $criterion.decision -notin @('check','pending','unaffected')) {
            throw 'VERIFICATION_CHANGE_CRITERION_INVALID: each criterion needs id, expectedResult and decision=check|pending|unaffected.'
        }
        $prior = @($previousCriteria | Where-Object id -eq $criterion.id)
        $known = @(Get-VerificationCatalogOneOffObligations | Where-Object id -eq $criterion.id)
        if ($known.Count -eq 1 -and ([string]$criterion.expectedResult -cne [string]$known[0].expectedResult -or ($criterion.decision -eq 'check' -and $criterion.id -notin @($criterion.checkIds)))) {
            throw 'VERIFICATION_CHANGE_EXISTING_ACCEPTANCE_CHANGED: preserve the declared expected result and observe that named obligation; an unrelated check cannot close it.'
        }
        if ($prior.Count -eq 1 -and [string]$prior[0].expectedResult -cne [string]$criterion.expectedResult) { throw 'VERIFICATION_CHANGE_REQUIREMENT_CHANGED: do not silently replace an accepted criterion; resolve the requirement change explicitly first.' }
        if ($criterion.decision -eq 'check' -and (@($criterion.checkIds).Count -eq 0 -or @($criterion.checkIds | Where-Object { $_ -notin @($checks.id) }).Count -gt 0)) {
            throw 'VERIFICATION_CHANGE_CRITERION_UNCOVERED: a checked criterion must reference current checkIds.'
        }
        $acceptedCriterion = @(if ($null -ne $acceptedPrevious) { $acceptedPrevious.criteria | Where-Object { $_.id -ceq $criterion.id -and $_.passed -and $_.expectedResult -ceq $criterion.expectedResult } })
        $inherited = $false
        if ($null -eq $previous -and $criterion.decision -eq 'unaffected' -and $known.Count -eq 1) {
            # Initial adoption only: validate the old receipt against unchanged
            # declared inputs and the exact still-loaded target before loading.
            $oldAssessment=Get-VerificationOneOffProofAssessment -Obligation $known[0] -State $state -Treeish $tree
            if ($oldAssessment.passed) {
                $receipt=Read-Utf8Text -Path $oldAssessment.path | ConvertFrom-Json
                $inputs=@($oldAssessment.path,(Resolve-ProjectPath ([string]$receipt.evidencePath)))+@($receipt.artifacts|ForEach-Object{Resolve-ProjectPath ([string]$_.path)})
                $inheritedEvidence+=@(New-VerificationArtifactReferences -Paths $inputs)
                $inherited=$true
            }
        }
        if ($sameTask -and $null -eq $acceptedPrevious -and $criterion.decision -eq 'unaffected' -and $known.Count -eq 1 -and
            [string]$previous.targetIdentity -ceq (Get-VerificationRetainedTargetIdentity -State $state) -and [string]$previous.checkerIdentity -ceq (Get-VerificationChangeCheckerIdentity) -and
            @($previousCriteria | Where-Object { $_.id -ceq $criterion.id -and $_.decision -ceq 'unaffected' }).Count -eq 1) {
            $priorEvidence=@(Get-VerificationCatalogValue -Value $previous -Name inheritedEvidence -Default @())
            $oldPath=Get-VerificationRepoRelativePath -Path (Get-VerificationOneOffProofPath -ObligationId $criterion.id)
            if (@($priorEvidence | Where-Object path -CEQ $oldPath).Count -eq 1 -and
                (Get-VerificationObligationInputIdentity -Obligation $known[0] -Treeish $previous.tree) -ceq (Get-VerificationObligationInputIdentity -Obligation $known[0] -Treeish $tree)) {
                Assert-VerificationArtifactReferences -Artifacts $priorEvidence
                $inheritedEvidence += $priorEvidence
                $inherited=$true
            }
        }
        if ($criterion.decision -eq 'unaffected' -and ([string]::IsNullOrWhiteSpace([string]$criterion.reason) -or (-not $inherited -and ($null -eq $acceptedPrevious -or [string]$acceptedPrevious.targetIdentity -cne (Get-VerificationRetainedTargetIdentity -State $state) -or $acceptedCriterion.Count -ne 1)))) {
            throw 'VERIFICATION_CHANGE_REUSE_UNPROVED: unaffected needs an accepted prior criterion and an explicit impact rationale.'
        }
    }
    foreach ($criterion in $criteria) { $criterion | Add-Member -NotePropertyName passed -NotePropertyValue ($criterion.decision -eq 'unaffected') -Force }
    foreach ($decision in @(Get-VerificationCatalogValue -Value $plan -Name 'retainedDispositions' -Default @())) {
        if (-not $decision.suiteId -or $decision.decision -notin @('run','unaffected') -or [string]::IsNullOrWhiteSpace([string]$decision.reason)) { throw 'VERIFICATION_CHANGE_SUITE_INVALID: every retained-suite disposition needs an existing suite, decision and reason.' }
    }
    $acceptedArtifact = Get-VerificationCatalogValue -Value $previous -Name 'acceptedArtifact' -Default $null
    $value = [pscustomobject][ordered]@{
        schemaVersion=1; model='change'; taskId=[string]$plan.taskId; status='pending'; runToken=[guid]::NewGuid().ToString('N')
        baseTree=$base; tree=$tree; targetIdentity=(Get-VerificationRetainedTargetIdentity -State $state)
        checkerIdentity=(Get-VerificationChangeCheckerIdentity); checks=$checks; paths=$coverage; criteria=$criteria
        requirements=$requirements; planArtifact=@(New-VerificationArtifactReferences -Paths @($full))[0]
        inheritedEvidence=$inheritedEvidence
        retainedDispositions=@(Get-VerificationCatalogValue -Value $plan -Name 'retainedDispositions' -Default @()); priorAcceptedArtifact=$acceptedArtifact; acceptedArtifact=$acceptedArtifact; taskAccepted=$false
    }
    # Failed/pending observations cannot disappear merely by preparing another plan.
    if ($null -ne $previous -and $previous.status -eq 'pending' -and @($previous.checks.id | Where-Object { $_ -notin @($checks.id) }).Count -gt 0) {
        throw 'VERIFICATION_CHANGE_CHECK_PENDING: preserve pending checks and failures when updating the impact plan.'
    }
    $value | Add-Member -NotePropertyName scopeIdentity -NotePropertyValue (Get-VerificationChangeScopeIdentity -Change $value)
    Write-Utf8TextAtomic -Path (Get-VerificationChangePath) -Value (($value | ConvertTo-Json -Depth 16) + "`n")
    return $value
}

function Get-VerificationChangeSelectionPlan {
    param([Parameter(Mandatory = $true)][object]$Plan)
    $change = Read-VerificationChange
    if ($null -eq $change) { return $Plan }
    Assert-VerificationChangeCurrent -Change $change
    if ($Plan.mode -eq 'classification-required') { return $Plan }
    $catalog = Read-VerificationSuiteCatalog -ApplicationFeatureFiles @(Get-VanessaApplicationFeatureFiles -FeaturePath (Get-VanessaFeaturesPath))
    $run = @($Plan.selectedSuiteIds)
    foreach ($decision in @($change.retainedDispositions)) {
        if ($decision.suiteId -notin @($Plan.acceptanceSuiteIds) -or $decision.decision -notin @('run','unaffected') -or -not $decision.reason) {
            throw 'VERIFICATION_CHANGE_SUITE_INVALID: declare an existing retained suite, run|unaffected and impact rationale.'
        }
        if ($decision.decision -eq 'unaffected') {
            if ($Plan.mode -eq 'full') { throw 'VERIFICATION_CHANGE_FULL_REQUIRED: the existing runtime/shared-input/full-coverage reason cannot be narrowed by an impact declaration.' }
            if (@($catalog.suites | Where-Object { $_.id -ceq $decision.suiteId -and $_.always }).Count -gt 0) { throw 'VERIFICATION_CHANGE_ALWAYS_REQUIRED: preserve the suite always policy; run its existing coverage before completing this change.' }
            $old = Read-VerificationSelectionProof
            $receipt = @($old.suiteEvidence | Where-Object id -eq $decision.suiteId)
            if ($receipt.Count -ne 1 -or $receipt[0].status -cne 'passed') { throw 'VERIFICATION_CHANGE_SUITE_UNPROVED: missing/failed retained coverage cannot be declared unaffected.' }
            Assert-VerificationArtifactReferences -Artifacts @($receipt[0].artifacts) -JUnit
            $run = @($run | Where-Object { $_ -cne [string]$decision.suiteId })
        }
    }
    $Plan.selectedSuiteIds = $run
    $Plan.selectedFeatureFiles = @($catalog.assignments | Where-Object { $_.suiteId -in $run } | Select-Object -ExpandProperty fullPath -Unique)
    if ($run.Count -eq 0) { $Plan.mode='reuse' } elseif ($run.Count -lt @($Plan.acceptanceSuiteIds).Count) { $Plan.mode='incremental' }
    return $Plan
}

function Get-VerificationChangeTaskAssessment {
    param([Parameter(Mandatory=$true)][object]$Change)
    $accepted=$null
    if ($Change.status -eq 'accepted' -and $Change.acceptedArtifact) {
        $accepted=Read-VerificationChangeAcceptedRecord -Change $Change -Current
    }
    $remaining = @(if ($null -ne $accepted) { $accepted.criteria | Where-Object { -not $_.passed } | ForEach-Object id }
        else { $Change.criteria | Where-Object decision -ne 'unaffected' | ForEach-Object id })
    return [pscustomobject]@{accepted=($null -ne $accepted -and $remaining.Count -eq 0);remaining=$remaining}
}

function Get-VerificationChangeAssessment {
    param([Parameter(Mandatory = $true)][object]$State, [string]$Fingerprint)
    try {
        $change = Assert-VerificationChangeReady -State $State
        $files = @(Get-VanessaApplicationFeatureFiles -FeaturePath (Get-VanessaFeaturesPath))
        $selection=Get-VerificationChangeSelectionPlan -Plan (New-VerificationCumulativeSelectionPlan -ApplicationFeatureFiles $files -YAxUnitVerificationPlanned -RequireObservedReceipts)
        if ($selection.mode -eq 'classification-required' -or @($selection.selectedSuiteIds).Count -gt 0) { throw "VERIFICATION_CHANGE_RETAINED_RUN_DUE: $($selection.reason) Resolve classification and run the normal unfiltered check; current plan preparation cannot substitute for its observed retained result." }
        $unaffected = @($change.retainedDispositions | Where-Object decision -eq 'unaffected' | ForEach-Object { [string]$_.suiteId })
        $assessment = Get-VerificationCumulativeProofAssessment -State $State -Fingerprint $Fingerprint -OneOffOverride @($change.checks | Where-Object retention -eq 'one-off') -UnaffectedSuiteIds $unaffected
        $task=Get-VerificationChangeTaskAssessment -Change $change
        $assessment | Add-Member -NotePropertyName taskAccepted -NotePropertyValue ([bool]$task.accepted) -Force
        $assessment | Add-Member -NotePropertyName acceptanceRemaining -NotePropertyValue @($task.remaining) -Force
        return $assessment
    } catch {
        return [pscustomobject]@{passed=$false;issues=@($_.Exception.Message);oneOffIssues=@();taskAccepted=$false;acceptanceRemaining=@()}
    }
}

function Complete-VerificationChange {
    if ((Get-VerificationModel) -cne 'change') { throw 'VERIFICATION_CHANGE_MODEL: completion belongs to the change model.' }
    $state = Read-DevBranchState -Name $DevBranchName
    Assert-DevelopmentBranchWorktreeContext -State $state -Operation 'complete-verification-change'
    $assessment = Get-VerificationChangeAssessment -State $state -Fingerprint (Get-VerificationFingerprint)
    if (-not $assessment.passed) { throw "VERIFICATION_CHANGE_PENDING: $(@($assessment.issues + $assessment.oneOffIssues) -join '; '). Satisfy the missing current check, then repeat complete-verification-change; do not restart successful checks." }
    $change = Read-VerificationChange
    if ($change.status -eq 'accepted') {
        $completed = Read-VerificationChangeAcceptedRecord -Change $change -Current
        if ($null -ne $completed) { return [pscustomobject]@{model='change';changeStatus='accepted';taskId=$completed.taskId;taskAccepted=[bool]$completed.taskAccepted;remaining=@($completed.criteria | Where-Object { -not $_.passed } | ForEach-Object id)} }
    }
    foreach ($criterion in @($change.criteria)) {
        $criterion | Add-Member -NotePropertyName passed -NotePropertyValue ($criterion.decision -in @('check','unaffected')) -Force
    }
    $archived = @()
    $allInputs = @((Resolve-ProjectPath ([string]$change.planArtifact.path))) + @($change.requirements | ForEach-Object { Resolve-ProjectPath ([string]$_.path) }) +
        @(Get-VerificationCatalogValue -Value $change -Name inheritedEvidence -Default @() | ForEach-Object { Resolve-ProjectPath ([string]$_.path) })
    foreach ($check in @($change.checks)) {
        if ($check.retention -eq 'one-off') {
            $proofPath = Get-VerificationOneOffProofPath -ObligationId ([string]$check.id)
            $proof = Read-Utf8Text -Path $proofPath | ConvertFrom-Json
            $inputs = @($proofPath, (Resolve-ProjectPath ([string]$proof.evidencePath))) + @($proof.artifacts | ForEach-Object { Resolve-ProjectPath ([string]$_.path) })
        } elseif ((Get-VerificationCatalogValue -Value $check -Name 'suiteId' -Default '')) {
            $proofPath = Join-Path (Get-VerificationSelectionStateRoot) 'proof.json'
            $proof = @(Read-VerificationSelectionProof | ForEach-Object suiteEvidence | Where-Object id -eq $check.suiteId)[0]
            $inputs = @($proofPath) + @($proof.artifacts | ForEach-Object { Resolve-ProjectPath ([string]$_.path) })
        } else {
            $proofPath = Join-Path (Get-VerificationSelectionStateRoot) ('changes/' + [string]$change.runToken + '/yaxunit.json')
            $proof = Get-StateValue -State (Get-StateValue -State $state -Name 'lastVerificationComponentEvidence' -Default $null) -Name yaxunit -Default $null
            Write-Utf8TextAtomic -Path $proofPath -Value ($proof | ConvertTo-Json -Depth 10)
            $inputs = @($proofPath) + @($proof.artifacts | ForEach-Object { Resolve-ProjectPath ([string]$_.path) })
        }
        $allInputs += $inputs
    }
    foreach ($inputPath in @($allInputs | Select-Object -Unique)) {
            $hash=(Get-FileHash -LiteralPath $inputPath -Algorithm SHA256).Hash.ToLowerInvariant()
            $copy=Join-Path (Get-VerificationSelectionStateRoot) ('changes/' + [string]$change.runToken + '/' + $hash + '.evidence')
            [IO.Directory]::CreateDirectory((Split-Path -Parent $copy)) | Out-Null
            [IO.File]::Copy($inputPath, $copy, $true)
            if ((Get-FileHash -LiteralPath $copy -Algorithm SHA256).Hash.ToLowerInvariant() -cne $hash) { throw 'VERIFICATION_CHANGE_ARCHIVE_CHANGED: preserve the original artifacts and repeat completion.' }
            $archived += @(New-VerificationArtifactReferences -Paths @($copy))
    }
    $change | Add-Member -NotePropertyName observedArtifacts -NotePropertyValue $archived -Force
    $change.status='accepted'
    $change.taskAccepted=@($change.criteria | Where-Object { -not $_.passed }).Count -eq 0
    $history = Join-Path (Get-VerificationSelectionStateRoot) ('changes/' + [string]$change.runToken + '.json')
    Write-Utf8TextAtomic -Path $history -Value (($change | ConvertTo-Json -Depth 16) + "`n")
    # write-tree objects from an uncommitted accepted increment are otherwise
    # unreachable. One local ref per worktree pins the authoritative latest base.
    $sourceRef='refs/itl/verification-change/' + (Get-VerificationSelectionSha256 -Text (Get-FullPathNormalized $script:ProjectRoot))
    Invoke-Git @('update-ref','--create-reflog',$sourceRef,[string]$change.tree)
    $change.acceptedArtifact=@(New-VerificationArtifactReferences -Paths @($history))[0]
    Write-Utf8TextAtomic -Path (Get-VerificationChangePath) -Value (($change | ConvertTo-Json -Depth 16) + "`n")
    return [pscustomobject]@{model='change';changeStatus='accepted';taskId=$change.taskId;taskAccepted=$change.taskAccepted;remaining=@($change.criteria | Where-Object { -not $_.passed } | ForEach-Object id)}
}
