function Get-VerificationSelectionStateRoot {
    return (Resolve-ProjectPath ".agent-1c/verification-selection")
}

function Get-VerificationScenarioMigrationBaselinePath {
    return (Join-Path (Get-VerificationSelectionStateRoot) "scenario-migration-baseline.json")
}

function Get-VerificationCatalogValue {
    param(
        [AllowNull()][object]$Value,
        [string]$Name,
        [AllowNull()][object]$Default = $null
    )

    if ($null -eq $Value) { return $Default }
    $property = $Value.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function Get-VerificationSuiteCatalogPaths {
    return @(
        (Resolve-ProjectPath "tests/verification-suites.shared.json"),
        (Resolve-ProjectPath "tests/verification-suites.branch.json")
    )
}

function Get-VerificationDeclaredInputScopes {
    $catalogPaths = @(Get-VerificationSuiteCatalogPaths)
    if (Get-Command Get-YAxUnitSuiteCatalogPaths -ErrorAction SilentlyContinue) {
        $catalogPaths += @(Get-YAxUnitSuiteCatalogPaths)
    }
    $scopes = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($catalogPath in @($catalogPaths | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })) {
        $catalog = Read-Utf8Text -Path $catalogPath | ConvertFrom-Json -ErrorAction Stop
        if ([int](Get-VerificationCatalogValue -Value $catalog -Name 'schemaVersion' -Default 0) -ne 2) { continue }
        foreach ($obligation in @(Get-VerificationCatalogValue -Value $catalog -Name 'obligations' -Default @())) {
            foreach ($input in @(Get-VerificationCatalogValue -Value $obligation -Name 'inputPaths' -Default @())) {
                $normalized = ([string]$input -replace '\\', '/').Trim()
                if (-not $normalized -or [IO.Path]::IsPathRooted($normalized) -or
                    $normalized.StartsWith('/') -or $normalized -match '(^|/)\.\.(/|$)|:') {
                    throw "VERIFICATION_OBLIGATION_INPUT_INVALID: '$normalized' in '$catalogPath' is not a repository-relative path."
                }
                $wildcardAt = $normalized.IndexOfAny([char[]]@('*', '?', '['))
                if ($wildcardAt -ge 0) {
                    $prefix = $normalized.Substring(0, $wildcardAt)
                    $slash = $prefix.LastIndexOf('/')
                    if ($slash -lt 1) {
                        throw "VERIFICATION_OBLIGATION_INPUT_INVALID: '$normalized' has no bounded directory before its wildcard."
                    }
                    $normalized = $prefix.Substring(0, $slash)
                }
                [void]$scopes.Add($normalized.TrimEnd('/'))
            }
        }
    }
    return @($scopes | Sort-Object)
}

function Read-VerificationObligationDecisions {
    param(
        [Parameter(Mandatory = $true)][object]$Catalog,
        [Parameter(Mandatory = $true)][string]$CatalogPath,
        [Parameter(Mandatory = $true)][ValidateSet('vanessa', 'yaxunit')][string]$Runner,
        [AllowEmptyCollection()][object[]]$RetainedEntries = @()
    )

    $schema = [int](Get-VerificationCatalogValue -Value $Catalog -Name 'schemaVersion' -Default 0)
    if ($schema -notin @(1, 2)) {
        throw "VERIFICATION_OBLIGATION_SCHEMA_UNSUPPORTED: '$CatalogPath' must use schemaVersion=1 or 2."
    }
    $entryId = if ($Runner -eq 'vanessa') { 'suiteId' } else { 'groupId' }
    $proofType = if ($Runner -eq 'vanessa') { 'vanessa-junit' } else { 'yaxunit-junit' }
    if ($schema -eq 1) {
        return @($RetainedEntries | ForEach-Object {
            [pscustomobject][ordered]@{
                id = "$Runner/$($_.id)"
                expectedResult = 'The retained test passes.'
                inputPaths = @($_.ownerPaths)
                admissibleProof = @($proofType)
                retention = 'retained'
                retentionReason = 'Existing schema-1 suite is preserved.'
                cadence = $(if ($_.purpose -in @('explicit', 'explicit-benchmark')) { 'explicit' } else { 'affected' })
                $entryId = [string]$_.id
                source = Get-VerificationRepoRelativePath -Path $CatalogPath
                migratedFromSchema1 = $true
            }
        })
    }

    $decisions = New-Object System.Collections.Generic.List[object]
    $ids = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($decision in @(Get-VerificationCatalogValue -Value $Catalog -Name 'obligations' -Default @())) {
        $id = [string](Get-VerificationCatalogValue -Value $decision -Name 'id' -Default '')
        $expected = [string](Get-VerificationCatalogValue -Value $decision -Name 'expectedResult' -Default '')
        $inputs = @((Get-VerificationCatalogValue -Value $decision -Name 'inputPaths' -Default @()) | ForEach-Object { [string]$_ -replace '\\', '/' } | Where-Object { $_ })
        $proof = @((Get-VerificationCatalogValue -Value $decision -Name 'admissibleProof' -Default @()) | ForEach-Object { [string]$_ } | Where-Object { $_ })
        $retention = [string](Get-VerificationCatalogValue -Value $decision -Name 'retention' -Default '')
        $reason = [string](Get-VerificationCatalogValue -Value $decision -Name 'retentionReason' -Default '')
        $cadence = [string](Get-VerificationCatalogValue -Value $decision -Name 'cadence' -Default '')
        $boundEntry = [string](Get-VerificationCatalogValue -Value $decision -Name $entryId -Default '')
        if ($id -notmatch '^[a-z0-9][a-z0-9._-]*$' -or -not $ids.Add($id)) {
            throw "VERIFICATION_OBLIGATION_ID_INVALID: '$id' is missing, invalid or duplicated in '$CatalogPath'."
        }
        if ([string]::IsNullOrWhiteSpace($expected) -or $inputs.Count -eq 0 -or $proof.Count -eq 0) {
            throw "VERIFICATION_OBLIGATION_INCOMPLETE: '$id' needs expectedResult, inputPaths and admissibleProof."
        }
        foreach ($inputPath in $inputs) {
            if ([IO.Path]::IsPathRooted($inputPath) -or $inputPath -match '(^|/)\.\.(/|$)|:' -or $inputPath.StartsWith('/')) {
                throw "VERIFICATION_OBLIGATION_INPUT_INVALID: '$id' has an unsafe inputPath '$inputPath'."
            }
        }
        if (@($proof | Where-Object { $_ -notmatch '^[a-z0-9][a-z0-9._-]*$' }).Count -gt 0) {
            throw "VERIFICATION_OBLIGATION_PROOF_INVALID: '$id' has an invalid admissibleProof type."
        }
        if ($retention -notin @('retained', 'one-off') -or $cadence -notin @('affected', 'handoff', 'explicit')) {
            throw "VERIFICATION_OBLIGATION_DECISION_INVALID: '$id' needs retention=retained|one-off and cadence=affected|handoff|explicit."
        }
        if ($retention -eq 'one-off' -and ($boundEntry -or [string]::IsNullOrWhiteSpace($reason))) {
            throw "VERIFICATION_OBLIGATION_RETENTION_INVALID: one-off '$id' needs a reason and no $entryId."
        }
        if ($retention -eq 'retained' -and -not $boundEntry) {
            throw "VERIFICATION_OBLIGATION_RETENTION_INVALID: retained '$id' needs $entryId."
        }
        if ($boundEntry -and @($RetainedEntries | Where-Object { $_.id -eq $boundEntry }).Count -ne 1) {
            throw "VERIFICATION_OBLIGATION_BINDING_INVALID: '$id' names unknown $entryId '$boundEntry'."
        }
        if ($boundEntry -and $proofType -notin $proof) {
            throw "VERIFICATION_OBLIGATION_PROOF_INVALID: retained '$id' needs '$proofType' in admissibleProof."
        }
        $decisions.Add([pscustomobject][ordered]@{
            id = $id
            expectedResult = $expected.Trim()
            inputPaths = $inputs
            admissibleProof = $proof
            retention = $retention
            retentionReason = $reason.Trim()
            cadence = $cadence
            $entryId = $boundEntry
            source = Get-VerificationRepoRelativePath -Path $CatalogPath
            migratedFromSchema1 = $false
        })
    }
    foreach ($entry in $RetainedEntries) {
        if (@($decisions.ToArray() | Where-Object { $_.$entryId -eq $entry.id }).Count -ne 1) {
            throw "VERIFICATION_OBLIGATION_BINDING_INVALID: retained $Runner entry '$($entry.id)' needs exactly one obligation."
        }
    }
    return @($decisions.ToArray())
}

function Get-VerificationObligationInputIdentity {
    param(
        [Parameter(Mandatory = $true)][object]$Obligation,
        [string]$Treeish = (Get-VerificationSelectionEffectiveTree)
    )

    if ([string]::IsNullOrWhiteSpace($Treeish)) {
        throw 'VERIFICATION_OBLIGATION_TREE_MISSING: exact checked source tree is required for proof identity.'
    }
    $parts = [Collections.Generic.List[string]]::new()
    foreach ($declared in @($Obligation.inputPaths | ForEach-Object { ([string]$_ -replace '\\', '/').Trim('/') } | Sort-Object -Unique)) {
        if (-not $declared -or [IO.Path]::IsPathRooted($declared) -or $declared -match '(^|/)\.\.(/|$)|:') {
            throw "VERIFICATION_OBLIGATION_INPUT_INVALID: '$declared' cannot be used for proof identity."
        }
        $matches = @()
        $wildcardAt = $declared.IndexOfAny([char[]]@('*', '?', '['))
        if ($wildcardAt -ge 0) {
            $prefix = $declared.Substring(0, $wildcardAt)
            $slash = $prefix.LastIndexOf('/')
            if ($slash -lt 1) {
                throw "VERIFICATION_OBLIGATION_INPUT_INVALID: '$declared' has no bounded directory before its wildcard."
            }
            $prefix = $prefix.Substring(0, $slash)
            $matches = @(Get-GitPathList -Arguments @('ls-tree', '-r', '-z', '--name-only', $Treeish, '--', $prefix) |
                Where-Object { Test-VerificationRepoPathPattern -Path $_ -Pattern $declared } | Sort-Object -Unique)
        } else {
            $matches = @($declared)
        }
        $parts.Add("pattern=$declared")
        if ($matches.Count -eq 0) { $parts.Add('matching-files=<none>') }
        foreach ($path in $matches) {
            $oid = Get-GitObjectIdForTreePath -Treeish $Treeish -RepoPath $path
            $parts.Add("$path=$oid")
        }
    }
    return (Get-VerificationSelectionSha256 -Text ((@('obligation-inputs-v1') + @($parts)) -join "`n"))
}

function Get-VerificationOneOffObligations {
    $result = [Collections.Generic.List[object]]::new()
    $catalogPaths = @(
        @(Get-VerificationSuiteCatalogPaths | ForEach-Object { [pscustomobject]@{ path = $_; runner = 'vanessa'; entries = 'suites' } }) +
        @(Get-YAxUnitSuiteCatalogPaths | ForEach-Object { [pscustomobject]@{ path = $_; runner = 'yaxunit'; entries = 'groups' } })
    )
    foreach ($item in $catalogPaths) {
        if (-not (Test-Path -LiteralPath $item.path -PathType Leaf)) { continue }
        $catalog = Read-Utf8Text -Path $item.path | ConvertFrom-Json -ErrorAction Stop
        if ([int](Get-VerificationCatalogValue -Value $catalog -Name 'schemaVersion' -Default 0) -ne 2) { continue }
        $retained = @((Get-VerificationCatalogValue -Value $catalog -Name $item.entries -Default @()) | ForEach-Object {
            [pscustomobject]@{ id = [string](Get-VerificationCatalogValue -Value $_ -Name 'id' -Default '') }
        })
        foreach ($obligation in @(Read-VerificationObligationDecisions -Catalog $catalog -CatalogPath $item.path -Runner $item.runner -RetainedEntries $retained)) {
            if ($obligation.retention -eq 'one-off') { $result.Add($obligation) }
        }
    }
    $ids = @($result | Select-Object -ExpandProperty id)
    if (@($ids | Sort-Object -Unique).Count -ne $ids.Count) {
        throw 'VERIFICATION_ONE_OFF_ID_DUPLICATE: obligation ids must be unique across Vanessa and YAxUnit catalogs.'
    }
    return @($result.ToArray())
}

function Get-VerificationOneOffProofPath {
    param([Parameter(Mandatory = $true)][string]$ObligationId)
    if ($ObligationId -notmatch '^[a-z0-9][a-z0-9._-]*$') {
        throw "VERIFICATION_ONE_OFF_ID_INVALID: '$ObligationId'."
    }
    return (Join-Path (Get-VerificationSelectionStateRoot) "one-off/$ObligationId.json")
}

function Get-VerificationOneOffObligationHash {
    param([Parameter(Mandatory = $true)][object]$Obligation)
    $parts = @(
        'one-off-obligation-v1',
        "id=$($Obligation.id)",
        "expected=$($Obligation.expectedResult)",
        "inputs=$(@($Obligation.inputPaths | Sort-Object) -join ',')",
        "proof=$(@($Obligation.admissibleProof | Sort-Object) -join ',')"
    )
    return (Get-VerificationSelectionSha256 -Text ($parts -join "`n"))
}

function Assert-VerificationOneOffJUnitEvidence {
    param([Parameter(Mandatory = $true)][string]$Path)

    [xml]$junit = Read-Utf8Text -Path $Path
    $cases = @($junit.SelectNodes("//*[local-name()='testcase']"))
    if ($cases.Count -eq 0 -or @($junit.SelectNodes("//*[local-name()='failure' or local-name()='error' or local-name()='skipped']")).Count -gt 0) {
        throw 'JUnit has zero executed cases, failures, errors or skipped cases'
    }
    foreach ($suite in @($junit.SelectNodes("//*[local-name()='testsuite']"))) {
        foreach ($attribute in @('tests', 'failures', 'errors', 'skipped')) {
            $value = [string]$suite.GetAttribute($attribute)
            if ($value -and ($value -notmatch '^\d+$' -or ($attribute -eq 'tests' -and [int]$value -eq 0) -or ($attribute -ne 'tests' -and [int]$value -gt 0))) {
                throw "JUnit has an invalid or nonzero $attribute summary"
            }
        }
    }
}

function Get-VerificationOneOffCheckerIdentity {
    param([Parameter(Mandatory = $true)][string]$ProofType)

    # Bind the actual validity checks, not the whole package, reporting code,
    # invocation settings or a permission expiry. JUnit fixes affect JUnit
    # receipts; unrelated observed-runtime proof does not depend on that parser.
    $names = @('Get-VerificationOneOffProofAssessment', 'Get-VerificationOneOffObligationHash',
        'Get-VerificationObligationInputIdentity', 'Get-VerificationLoadedBaseIdentity',
        'Get-VerificationRepoRelativePath', 'Get-VerificationCatalogValue')
    if ($ProofType -in @('vanessa-junit', 'yaxunit-junit')) {
        $names += @('Assert-VerificationOneOffJUnitEvidence', 'Assert-VerificationArtifactReferences')
    }
    if ($ProofType -eq 'yaxunit-junit') { $names += 'Get-YAxUnitJunitSummary' }
    if ($ProofType -eq 'event-log') {
        $names += @('Test-DevBranchEventLogAfterVanessa', 'Read-DevBranchEventLogErrors',
            'Read-DevBranchEventLogCursorInfo', 'Get-DevBranchEventLogDeltaSelection',
            'Read-OneCEventLogDirect', 'Read-OneCEventLogViaFallback',
            'ConvertFrom-OneCEventLogRecord', 'ConvertFrom-OneCEventLogDate',
            'Resolve-DevBranchEventLogDebt', 'Assert-VerificationComponentEvidence',
            'Assert-VerificationArtifactReferences')
    }
    $parts = @('one-off-checker-v1', "proofType=$ProofType")
    foreach ($name in $names) {
        $command = Get-Command -Name $name -CommandType Function -ErrorAction Stop
        $parts += "$name=$($command.ScriptBlock.ToString().Replace("`r`n", "`n"))"
    }
    return Get-VerificationSelectionSha256 -Text ($parts -join "`n")
}

function Get-VerificationOneOffProofAssessment {
    param(
        [Parameter(Mandatory = $true)][object]$Obligation,
        [Parameter(Mandatory = $true)][object]$State,
        [string]$Treeish = '',
        [AllowNull()][object]$Proof = $null
    )
    $path = Get-VerificationOneOffProofPath -ObligationId ([string]$Obligation.id)
    $issue = "VERIFICATION_ONE_OFF_PROOF_PENDING: obligation '$($Obligation.id)' needs complete observed evidence."
    if ($null -eq $Proof -and -not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [pscustomobject]@{ passed = $false; issue = $issue; path = $path }
    }
    try {
        $proof = if ($null -ne $Proof) { $Proof } else { Read-Utf8Text -Path $path | ConvertFrom-Json -ErrorAction Stop }
        if (-not $Treeish) { $Treeish = Get-VerificationSelectionEffectiveTree }
        if ([int](Get-VerificationCatalogValue -Value $proof -Name 'schemaVersion' -Default 0) -ne 1 -or
            [string]$proof.status -cne 'passed' -or [string]$proof.obligationId -cne [string]$Obligation.id -or
            [string]$proof.obligationHash -cne (Get-VerificationOneOffObligationHash -Obligation $Obligation) -or
            [string]$proof.expectedResult -cne [string]$Obligation.expectedResult -or
            [string]$proof.proofType -cnotin @($Obligation.admissibleProof) -or
            [string]::IsNullOrWhiteSpace([string]$proof.actualResult) -or
            [string]::IsNullOrWhiteSpace([string]$proof.providerId) -or
            [string]::IsNullOrWhiteSpace([string]$proof.runnerVersion) -or
            @($proof.steps).Count -eq 0) {
            throw 'receipt is incomplete or does not match the declared obligation'
        }
        if ([string]$proof.inputIdentity -cne (Get-VerificationObligationInputIdentity -Obligation $Obligation -Treeish $Treeish) -or
            [string]$proof.loadedBaseIdentity -cne (Get-VerificationLoadedBaseIdentity -State $State)) {
            throw 'checked inputs or loaded test infobase changed'
        }
        if ([string](Get-VerificationCatalogValue -Value $proof -Name 'checkerIdentity' -Default '') -cne
            (Get-VerificationOneOffCheckerIdentity -ProofType ([string]$proof.proofType))) {
            throw 'relevant one-off checker changed or its identity is unknown; begin a new observed proof with the current checker'
        }
        $evidenceFull = Resolve-ProjectPath ([string]$proof.evidencePath)
        [void](Get-VerificationRepoRelativePath -Path $evidenceFull)
        if (-not (Test-Path -LiteralPath $evidenceFull -PathType Leaf) -or
            (Get-FileHash -LiteralPath $evidenceFull -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$proof.evidenceSha256) {
            throw 'observed evidence document changed or is missing'
        }
        $evidence = Read-Utf8Text -Path $evidenceFull | ConvertFrom-Json -ErrorAction Stop
        foreach ($field in @('obligationId', 'runToken', 'expectedResult', 'status', 'proofType', 'actualResult', 'providerId', 'runnerVersion')) {
            if ([string](Get-VerificationCatalogValue -Value $evidence -Name $field -Default '') -cne
                [string](Get-VerificationCatalogValue -Value $proof -Name $field -Default '')) {
                throw "receipt no longer matches observed evidence field '$field'"
            }
        }
        if (@($evidence.steps).Count -ne @($proof.steps).Count -or
            @($evidence.artifactPaths).Count -ne @($proof.artifacts).Count) {
            throw 'receipt no longer matches observed steps or artifacts'
        }
        for ($index = 0; $index -lt @($proof.steps).Count; $index++) {
            if ([string]$evidence.steps[$index].action -cne [string]$proof.steps[$index].action -or
                [string]$evidence.steps[$index].actual -cne [string]$proof.steps[$index].actual) {
                throw 'receipt no longer matches an observed step'
            }
        }
        foreach ($step in @($proof.steps)) {
            if ([string]::IsNullOrWhiteSpace([string]$step.action) -or [string]::IsNullOrWhiteSpace([string]$step.actual)) {
                throw 'observed steps are incomplete'
            }
        }
        for ($index = 0; $index -lt @($proof.artifacts).Count; $index++) {
            $artifact = $proof.artifacts[$index]
            $full = Resolve-ProjectPath ([string]$artifact.path)
            $relative = Get-VerificationRepoRelativePath -Path $full
            $declaredRelative = Get-VerificationRepoRelativePath -Path (Resolve-ProjectPath ([string]$evidence.artifactPaths[$index]))
            if ($relative -cne $declaredRelative) { throw 'receipt no longer matches an observed artifact path' }
            if (-not (Test-Path -LiteralPath $full -PathType Leaf) -or
                (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$artifact.sha256) {
                throw "artifact changed or is missing: $relative"
            }
        }
        if (@($proof.artifacts).Count -eq 0) { throw 'no observed artifact was retained' }
        if ([string]$proof.proofType -in @('vanessa-junit', 'yaxunit-junit')) {
            $junitPath = Resolve-ProjectPath ([string]$proof.artifacts[0].path)
            Assert-VerificationOneOffJUnitEvidence -Path $junitPath
        }
        return [pscustomobject]@{ passed = $true; issue = ''; path = $path }
    } catch {
        return [pscustomobject]@{ passed = $false; issue = "VERIFICATION_ONE_OFF_PROOF_INVALID: obligation '$($Obligation.id)': $($_.Exception.Message)"; path = $path }
    }
}

function Start-VerificationOneOffProof {
    param(
        [Parameter(Mandatory = $true)][string]$ObligationId,
        [switch]$Force
    )

    $matches = @(Get-VerificationOneOffObligations | Where-Object id -eq $ObligationId)
    if ($matches.Count -ne 1) {
        throw "VERIFICATION_ONE_OFF_OBLIGATION_MISSING: '$ObligationId' must name one schema-2 one-off obligation."
    }
    $state = Read-DevBranchState -Name $DevBranchName
    Assert-DevelopmentBranchWorktreeContext -State $state -Operation 'begin-one-off-proof'
    $obligation = $matches[0]
    $path = Get-VerificationOneOffProofPath -ObligationId $ObligationId
    if (-not $Force) {
        $existing = Get-VerificationOneOffProofAssessment -Obligation $obligation -State $state
        if ($existing.passed) {
            return [pscustomobject]@{ status = 'passed'; reused = $true; path = $path; obligationId = $ObligationId }
        }
    }
    $draft = [ordered]@{
        schemaVersion = 1
        status = 'pending'
        obligationId = $ObligationId
        obligationHash = Get-VerificationOneOffObligationHash -Obligation $obligation
        expectedResult = [string]$obligation.expectedResult
        admissibleProof = @($obligation.admissibleProof)
        inputIdentity = Get-VerificationObligationInputIdentity -Obligation $obligation
        loadedBaseIdentity = Get-VerificationLoadedBaseIdentity -State $state
        checkerIdentities = [ordered]@{}
        runToken = [guid]::NewGuid().ToString('N')
        startedAt = (Get-Date).ToUniversalTime().ToString('o')
    }
    foreach ($proofType in @($obligation.admissibleProof)) {
        $draft.checkerIdentities[$proofType] = Get-VerificationOneOffCheckerIdentity -ProofType $proofType
    }
    Write-Utf8TextAtomic -Path $path -Value (($draft | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
    return [pscustomobject]@{ status = 'pending'; reused = $false; path = $path; runToken = $draft.runToken; expectedResult = $draft.expectedResult; inputIdentity = $draft.inputIdentity; loadedBaseIdentity = $draft.loadedBaseIdentity }
}

function Complete-VerificationOneOffProof {
    param([Parameter(Mandatory = $true)][string]$EvidencePath)

    $evidenceFull = Resolve-ProjectPath $EvidencePath
    $evidenceRelative = Get-VerificationRepoRelativePath -Path $evidenceFull
    if (-not (Test-Path -LiteralPath $evidenceFull -PathType Leaf)) {
        throw "VERIFICATION_ONE_OFF_EVIDENCE_MISSING: '$evidenceRelative'."
    }
    $evidence = Read-Utf8Text -Path $evidenceFull | ConvertFrom-Json -ErrorAction Stop
    $id = [string](Get-VerificationCatalogValue -Value $evidence -Name 'obligationId' -Default '')
    $path = Get-VerificationOneOffProofPath -ObligationId $id
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "VERIFICATION_ONE_OFF_DRAFT_MISSING: begin-one-off-proof for '$id' before recording a result."
    }
    $draft = Read-Utf8Text -Path $path | ConvertFrom-Json -ErrorAction Stop
    $obligation = @(Get-VerificationOneOffObligations | Where-Object id -eq $id)
    if ($obligation.Count -ne 1 -or [string]$draft.status -cne 'pending' -or
        [string]$draft.runToken -cne [string]$evidence.runToken -or
        [string]$draft.obligationHash -cne (Get-VerificationOneOffObligationHash -Obligation $obligation[0]) -or
        [string]$draft.expectedResult -cne [string]$evidence.expectedResult -or
        [string]$evidence.status -cne 'passed' -or
        [string]$evidence.proofType -cnotin @($obligation[0].admissibleProof) -or
        [string]::IsNullOrWhiteSpace([string]$evidence.actualResult) -or
        [string]::IsNullOrWhiteSpace([string]$evidence.providerId) -or
        [string]::IsNullOrWhiteSpace([string]$evidence.runnerVersion) -or
        @($evidence.steps).Count -eq 0) {
        throw "VERIFICATION_ONE_OFF_EVIDENCE_INVALID: '$id' has no matching pending run, complete result or admissible proof."
    }
    foreach ($step in @($evidence.steps)) {
        if ([string]::IsNullOrWhiteSpace([string]$step.action) -or [string]::IsNullOrWhiteSpace([string]$step.actual)) {
            throw "VERIFICATION_ONE_OFF_EVIDENCE_INVALID: '$id' needs observed action and actual result for every step."
        }
    }
    $state = Read-DevBranchState -Name $DevBranchName
    Assert-DevelopmentBranchWorktreeContext -State $state -Operation 'complete-one-off-proof'
    if ([string]$draft.inputIdentity -cne (Get-VerificationObligationInputIdentity -Obligation $obligation[0]) -or
        [string]$draft.loadedBaseIdentity -cne (Get-VerificationLoadedBaseIdentity -State $state)) {
        throw "VERIFICATION_ONE_OFF_CONTEXT_CHANGED: '$id' source or loaded test infobase changed after begin-one-off-proof; repeat the observed run in the current context."
    }
    $checkerIdentity = Get-VerificationOneOffCheckerIdentity -ProofType ([string]$evidence.proofType)
    $draftIdentities = Get-VerificationCatalogValue -Value $draft -Name 'checkerIdentities' -Default $null
    if ([string](Get-VerificationCatalogValue -Value $draftIdentities -Name ([string]$evidence.proofType) -Default '') -cne $checkerIdentity) {
        throw "VERIFICATION_ONE_OFF_CHECKER_CHANGED: '$id' relevant checker changed or the pending receipt has no compatible identity; repeat begin-one-off-proof and the observed run with the current checker."
    }
    $artifacts = [Collections.Generic.List[object]]::new()
    foreach ($artifactPath in @($evidence.artifactPaths)) {
        $artifactFull = Resolve-ProjectPath ([string]$artifactPath)
        $artifactRelative = Get-VerificationRepoRelativePath -Path $artifactFull
        if (-not (Test-Path -LiteralPath $artifactFull -PathType Leaf)) {
            throw "VERIFICATION_ONE_OFF_ARTIFACT_MISSING: '$artifactRelative'."
        }
        $artifacts.Add([ordered]@{ path = $artifactRelative; sha256 = (Get-FileHash -LiteralPath $artifactFull -Algorithm SHA256).Hash.ToLowerInvariant() })
    }
    if ($artifacts.Count -eq 0) {
        throw "VERIFICATION_ONE_OFF_ARTIFACT_MISSING: '$id' needs a retained result artifact."
    }
    $proof = [ordered]@{
        schemaVersion = 1; status = 'passed'; obligationId = $id
        obligationHash = [string]$draft.obligationHash
        expectedResult = [string]$draft.expectedResult
        inputIdentity = [string]$draft.inputIdentity
        loadedBaseIdentity = [string]$draft.loadedBaseIdentity
        checkerIdentity = $checkerIdentity
        runToken = [string]$draft.runToken
        startedAt = [string]$draft.startedAt
        completedAt = (Get-Date).ToUniversalTime().ToString('o')
        proofType = [string]$evidence.proofType
        actualResult = [string]$evidence.actualResult
        providerId = [string]$evidence.providerId
        runnerVersion = [string]$evidence.runnerVersion
        steps = @($evidence.steps)
        limitations = [string](Get-VerificationCatalogValue -Value $evidence -Name 'limitations' -Default '')
        invocationProvenance = Get-VerificationCatalogValue -Value $evidence -Name 'invocationProvenance' -Default $null
        evidencePath = $evidenceRelative
        evidenceSha256 = (Get-FileHash -LiteralPath $evidenceFull -Algorithm SHA256).Hash.ToLowerInvariant()
        artifacts = @($artifacts.ToArray())
    }
    # Check the complete candidate before the single atomic transition from
    # pending to passed. A crash cannot expose an unassessed passed receipt.
    $assessment = Get-VerificationOneOffProofAssessment -Obligation $obligation[0] -State $state -Proof ([pscustomobject]$proof)
    if (-not $assessment.passed) { throw $assessment.issue }
    Write-Utf8TextAtomic -Path $path -Value (($proof | ConvertTo-Json -Depth 12) + [Environment]::NewLine)
    return [pscustomobject]@{ status = 'passed'; obligationId = $id; path = $path; inputIdentity = $proof.inputIdentity }
}

function Test-VerificationRepoPathPattern {
    param(
        [string]$Path,
        [string]$Pattern
    )

    $normalizedPath = ($Path -replace "\\", "/").TrimStart("/")
    $normalizedPattern = ($Pattern -replace "\\", "/").TrimStart("/")
    if ([string]::IsNullOrWhiteSpace($normalizedPattern)) { return $false }
    $wildcard = [System.Management.Automation.WildcardPattern]::new(
        $normalizedPattern,
        [System.Management.Automation.WildcardOptions]::IgnoreCase
    )
    return $wildcard.IsMatch($normalizedPath)
}

function Get-VerificationRepoRelativePath {
    param([string]$Path)

    $root = (Resolve-Agent1cFullPath -Path $script:ProjectRoot).TrimEnd("\", "/")
    $fullPath = Resolve-Agent1cFullPath -Path $Path
    if (-not $fullPath.StartsWith(($root + "\"), [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "VERIFICATION_SUITE_PATH_OUTSIDE_PROJECT: $fullPath"
    }
    return ($fullPath.Substring($root.Length + 1) -replace "\\", "/")
}

function Get-VerificationSelectionSha256 {
    param([string]$Text)

    $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Get-VerificationAcceptanceScenarioLimit {
    return 8
}

function Get-VerificationScenarioCadenceHint {
    param([string[]]$Tags)

    foreach ($tagValue in @($Tags)) {
        $tag = ([string]$tagValue).TrimStart("@").ToLowerInvariant()
        if ($tag -match '^(ab_|diag_)' -or $tag -match '(benchmark|profiling|measurement)') {
            return "explicit"
        }
    }
    return "acceptance"
}

function Get-VerificationScenarioFingerprint {
    param([object]$Scenario)

    $exampleRows = if ($null -ne $Scenario.exampleRows -and $null -ne $Scenario.exampleRows.PSObject.Methods["ToArray"]) { @($Scenario.exampleRows.ToArray()) } else { @($Scenario.exampleRows) }
    $steps = if ($null -ne $Scenario.steps -and $null -ne $Scenario.steps.PSObject.Methods["ToArray"]) { @($Scenario.steps.ToArray()) } else { @($Scenario.steps) }
    $exampleParts = @()
    foreach ($row in $exampleRows) {
        $exampleParts += (@($row.PSObject.Properties | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join "`t")
    }
    $parts = @(
        "name=$([string]$Scenario.name)",
        "outline=$([bool]$Scenario.isOutline)",
        "steps=$($steps -join "`n")",
        "examples=$($exampleParts -join "`n")"
    )
    return (Get-VerificationSelectionSha256 -Text ($parts -join "`n"))
}

function Get-VerificationScenarioAnalysis {
    param(
        [string[]]$ApplicationFeatureFiles,
        [object[]]$Assignments
    )

    if (-not (Get-Command Get-VanessaFeatureScenarioDefinitions -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ scenarios = @(); issues = @(); migrationRequired = $false }
    }

    $assignmentByPath = @{}
    foreach ($assignment in @($Assignments)) { $assignmentByPath[[string]$assignment.path] = $assignment }
    $scenarios = New-Object System.Collections.Generic.List[object]
    foreach ($scenario in @(Get-VanessaFeatureScenarioDefinitions -FeatureFiles $ApplicationFeatureFiles)) {
        $path = Get-VerificationRepoRelativePath -Path ([string]$scenario.source)
        $assignment = if ($assignmentByPath.ContainsKey($path)) { $assignmentByPath[$path] } else { $null }
        $tags = @($scenario.tags | ForEach-Object { "@" + ([string]$_).TrimStart("@") })
        $scenarios.Add([pscustomobject][ordered]@{
            path = $path
            line = [int](Get-VerificationCatalogValue -Value $scenario -Name "sourceLine" -Default 0)
            name = [string]$scenario.name
            tags = $tags
            suiteId = $(if ($null -ne $assignment) { [string]$assignment.suiteId } else { "__unclassified__" })
            purpose = $(if ($null -ne $assignment) { [string]$assignment.purpose } else { "" })
            obligationId = $(if ($null -ne $assignment) { [string](Get-VerificationCatalogValue -Value $assignment -Name 'obligationId' -Default '') } else { '' })
            cadence = $(if ($null -ne $assignment) { [string](Get-VerificationCatalogValue -Value $assignment -Name 'cadence' -Default '') } else { '' })
            cadenceHint = Get-VerificationScenarioCadenceHint -Tags $tags
            fingerprint = Get-VerificationScenarioFingerprint -Scenario $scenario
        })
    }

    $issues = New-Object System.Collections.Generic.List[string]
    $acceptanceLimit = Get-VerificationAcceptanceScenarioLimit
    $scopeGroups = @($scenarios.ToArray() | Where-Object { -not $_.purpose -or $_.purpose -eq "acceptance" } | Group-Object {
        if ($_.suiteId -eq "__unclassified__") { "$($_.suiteId):$($_.path)" } else { $_.suiteId }
    })
    foreach ($group in $scopeGroups) {
        if ($group.Count -le $acceptanceLimit) { continue }
        $paths = @($group.Group.path | Sort-Object -Unique)
        $suiteLabel = if ($group.Group[0].suiteId -eq "__unclassified__") { "unclassified feature" } else { "acceptance suite '$($group.Group[0].suiteId)'" }
        $issues.Add("VERIFICATION_SUITE_ACCEPTANCE_SCOPE_TOO_BROAD: $suiteLabel contains $($group.Count) scenarios across '$($paths -join "', '")'; maximum is $acceptanceLimit. The agent must preserve scenario behavior, split coherent owners/cadences into separately selectable feature files and suites, and move diagnostics, A/B checks, profiling, benchmarks, and measurement launchers to purpose='explicit'.")
    }

    foreach ($group in @($scenarios.ToArray() | Where-Object { $_.purpose -eq "acceptance" -and $_.cadenceHint -eq "explicit" } | Group-Object path)) {
        $names = @($group.Group | Select-Object -First 3 | ForEach-Object { "'$($_.name)'" })
        $issues.Add("VERIFICATION_SUITE_MIXED_CADENCE: acceptance feature '$($group.Name)' contains $($group.Count) diagnostic/A-B/profiling/benchmark/measurement scenario(s), including $($names -join ', '). The agent must move them unchanged to separately selectable purpose='explicit' feature files and suites.")
    }

    return [pscustomobject]@{
        scenarios = @($scenarios.ToArray())
        issues = @($issues.ToArray())
        migrationRequired = ($issues.Count -gt 0)
    }
}

function Read-VerificationSuiteCatalog {
    param([string[]]$ApplicationFeatureFiles)

    $catalogPaths = @(Get-VerificationSuiteCatalogPaths | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
    if ($catalogPaths.Count -eq 0) {
        $issues = @()
        $assignments = @()
        if (@($ApplicationFeatureFiles).Count -gt 0) {
            $assignments = @($ApplicationFeatureFiles | ForEach-Object {
                [pscustomobject]@{ path = Get-VerificationRepoRelativePath -Path $_; suiteId = "__unclassified__"; purpose = ""; fullPath = $_ }
            })
            $issues = @("Vanessa feature files exist, but tests/verification-suites.shared.json or tests/verification-suites.branch.json is missing.") +
                @($assignments | ForEach-Object { "Unclassified Vanessa feature: $($_.path)" })
        }
        $scenarioAnalysis = Get-VerificationScenarioAnalysis -ApplicationFeatureFiles $ApplicationFeatureFiles -Assignments $assignments
        $issues = @($issues + @($scenarioAnalysis.issues))
        return [pscustomobject]@{
            available = $false
            valid = $true
            classificationComplete = ($issues.Count -eq 0)
            issues = $issues
            fallbackReason = $(if ($issues.Count -gt 0) { $issues[0] } else { "No Vanessa application feature files require classification." })
            suites = @()
            obligations = @()
            assignments = $assignments
            scenarios = @($scenarioAnalysis.scenarios)
            migrationRequired = [bool]$scenarioAnalysis.migrationRequired
            suiteFingerprints = @()
            fingerprint = "legacy"
            catalogPaths = @()
        }
    }

    $suiteIds = New-Object "System.Collections.Generic.HashSet[string]" ([System.StringComparer]::OrdinalIgnoreCase)
    $obligationIds = New-Object "System.Collections.Generic.HashSet[string]" ([System.StringComparer]::OrdinalIgnoreCase)
    $suites = New-Object System.Collections.Generic.List[object]
    $obligations = New-Object System.Collections.Generic.List[object]
    $fingerprintParts = New-Object System.Collections.Generic.List[string]
    try {
        foreach ($catalogPath in $catalogPaths) {
            $raw = Read-Utf8Text -Path $catalogPath
            $fingerprintParts.Add("$(Get-VerificationRepoRelativePath -Path $catalogPath)=$(Get-VerificationSelectionSha256 -Text $raw)")
            $catalog = $raw | ConvertFrom-Json
            $schemaVersion = [int](Get-VerificationCatalogValue -Value $catalog -Name "schemaVersion" -Default 0)
            if ($schemaVersion -notin @(1, 2)) {
                throw "VERIFICATION_SUITE_SCHEMA_UNSUPPORTED: '$catalogPath' must use schemaVersion=1 or 2."
            }
            $catalogSuites = New-Object System.Collections.Generic.List[object]
            foreach ($suite in @(Get-VerificationCatalogValue -Value $catalog -Name "suites" -Default @())) {
                $id = [string](Get-VerificationCatalogValue -Value $suite -Name "id" -Default "")
                $purpose = [string](Get-VerificationCatalogValue -Value $suite -Name "purpose" -Default "")
                if ($id -notmatch '^[a-z0-9][a-z0-9._-]*$') {
                    throw "VERIFICATION_SUITE_ID_INVALID: '$id' in '$catalogPath'."
                }
                if (-not $suiteIds.Add($id)) {
                    throw "VERIFICATION_SUITE_ID_DUPLICATE: '$id'. Shared and branch catalogs are additive; ids must be unique."
                }
                if ($purpose -notin @("acceptance", "explicit")) {
                    throw "VERIFICATION_SUITE_PURPOSE_INVALID: suite '$id' must use purpose='acceptance' or purpose='explicit'."
                }
                $featurePatterns = @(Get-VerificationCatalogValue -Value $suite -Name "featurePaths" -Default @() | ForEach-Object { ([string]$_ -replace "\\", "/").TrimStart("/") } | Where-Object { $_ })
                if ($featurePatterns.Count -eq 0) {
                    throw "VERIFICATION_SUITE_FEATURES_MISSING: suite '$id' has no featurePaths."
                }
                $ownerPatterns = @(Get-VerificationCatalogValue -Value $suite -Name "ownerPaths" -Default @() | ForEach-Object { ([string]$_ -replace "\\", "/").TrimStart("/") } | Where-Object { $_ })
                if ($ownerPatterns.Count -eq 0) {
                    throw "VERIFICATION_SUITE_OWNERS_MISSING: suite '$id' has no ownerPaths."
                }
                $normalizedSuite = [pscustomobject][ordered]@{
                    id = $id
                    purpose = $purpose
                    always = [bool](Get-VerificationCatalogValue -Value $suite -Name "always" -Default $false)
                    featurePaths = $featurePatterns
                    ownerPaths = $ownerPatterns
                    source = Get-VerificationRepoRelativePath -Path $catalogPath
                }
                $suites.Add($normalizedSuite)
                $catalogSuites.Add($normalizedSuite)
            }
            foreach ($obligation in @(Read-VerificationObligationDecisions -Catalog $catalog -CatalogPath $catalogPath -Runner vanessa -RetainedEntries @($catalogSuites.ToArray()))) {
                if (-not $obligationIds.Add([string]$obligation.id)) {
                    throw "VERIFICATION_OBLIGATION_ID_DUPLICATE: '$($obligation.id)' appears in more than one catalog."
                }
                $obligations.Add($obligation)
            }
        }

        $assignments = New-Object System.Collections.Generic.List[object]
        foreach ($featureFile in @($ApplicationFeatureFiles)) {
            $repoPath = Get-VerificationRepoRelativePath -Path $featureFile
            $matches = @($suites | Where-Object {
                $candidate = $_
                @($candidate.featurePaths | Where-Object { Test-VerificationRepoPathPattern -Path $repoPath -Pattern $_ }).Count -gt 0
            })
            if ($matches.Count -gt 1) {
                throw "VERIFICATION_SUITE_FEATURE_AMBIGUOUS: '$repoPath' matches suites '$(@($matches.id) -join ', ')'."
            }
            if ($matches.Count -eq 0) {
                $assignments.Add([pscustomobject]@{ path = $repoPath; suiteId = "__unclassified__"; purpose = "acceptance"; fullPath = $featureFile })
            } else {
                $obligation = @($obligations.ToArray() | Where-Object suiteId -eq $matches[0].id)[0]
                $assignments.Add([pscustomobject]@{
                    path = $repoPath
                    suiteId = [string]$matches[0].id
                    purpose = [string]$matches[0].purpose
                    obligationId = [string]$obligation.id
                    cadence = [string]$obligation.cadence
                    fullPath = $featureFile
                })
            }
        }
        foreach ($suite in @($suites.ToArray())) {
            if (@($assignments.ToArray() | Where-Object suiteId -eq $suite.id).Count -eq 0) {
                throw "VERIFICATION_SUITE_EMPTY: suite '$($suite.id)' does not match any current application feature file."
            }
        }
        $issues = @($assignments.ToArray() | Where-Object suiteId -eq "__unclassified__" | ForEach-Object { "Unclassified Vanessa feature: $($_.path)" })
        $scenarioAnalysis = Get-VerificationScenarioAnalysis -ApplicationFeatureFiles $ApplicationFeatureFiles -Assignments @($assignments.ToArray())
        $issues = @($issues + @($scenarioAnalysis.issues))
        # Classification describes the planned coverage. A missing one-off
        # result belongs to readiness assessment, not this preflight: retained
        # runners must still be allowed to produce their own current proof.
        foreach ($obligation in @($obligations.ToArray() | Where-Object { $_.retention -eq 'retained' -and -not $_.migratedFromSchema1 })) {
            $suite = @($suites.ToArray() | Where-Object id -eq $obligation.suiteId)[0]
            if (($obligation.cadence -eq 'explicit' -and $suite.purpose -ne 'explicit') -or
                ($obligation.cadence -in @('affected', 'handoff') -and $suite.purpose -ne 'acceptance')) {
                $issues += "VERIFICATION_CADENCE_SELECTION_PENDING: obligation '$($obligation.id)' has cadence '$($obligation.cadence)' that the current Vanessa selector cannot execute without changing its purpose. Preserve the suite and choose a supported invocation route."
            }
        }
        foreach ($assignment in @($assignments | Sort-Object path)) {
            $fingerprintParts.Add("$($assignment.path)=$($assignment.suiteId):$($assignment.purpose):$($assignment.obligationId):$($assignment.cadence)")
        }
        $suiteFingerprints = @($suites.ToArray() | ForEach-Object {
            $suite = $_
            $assignedPaths = @($assignments.ToArray() | Where-Object suiteId -eq $suite.id | Select-Object -ExpandProperty path | Sort-Object)
            $semanticParts = @(
                "id=$($suite.id)",
                "purpose=$($suite.purpose)",
                "always=$([bool]$suite.always)",
                "features=$(@($suite.featurePaths | Sort-Object) -join ',')",
                "owners=$(@($suite.ownerPaths | Sort-Object) -join ',')",
                "assigned=$($assignedPaths -join ',')",
                "scenarios=$(@($scenarioAnalysis.scenarios | Where-Object suiteId -eq $suite.id | Select-Object -ExpandProperty fingerprint | Sort-Object) -join ',')"
            )
            [pscustomobject]@{ id = [string]$suite.id; purpose = [string]$suite.purpose; fingerprint = Get-VerificationSelectionSha256 -Text ($semanticParts -join "`n") }
        })
        return [pscustomobject]@{
            available = $true
            valid = $true
            classificationComplete = ($issues.Count -eq 0)
            issues = $issues
            fallbackReason = ""
            suites = @($suites.ToArray())
            obligations = @($obligations.ToArray())
            assignments = @($assignments.ToArray())
            scenarios = @($scenarioAnalysis.scenarios)
            migrationRequired = [bool]$scenarioAnalysis.migrationRequired
            suiteFingerprints = $suiteFingerprints
            fingerprint = Get-VerificationSelectionSha256 -Text ($fingerprintParts -join "`n")
            catalogPaths = @($catalogPaths)
        }
    } catch {
        return [pscustomobject]@{
            available = $true
            valid = $false
            classificationComplete = $false
            issues = @($_.Exception.Message)
            fallbackReason = $_.Exception.Message
            suites = @()
            obligations = @()
            assignments = @()
            scenarios = @()
            migrationRequired = $false
            suiteFingerprints = @()
            fingerprint = "invalid"
            catalogPaths = @($catalogPaths)
        }
    }
}

function Get-VerificationSelectionEffectiveTree {
    $changedPaths = @(Get-VerificationWorkingTreeChangePaths -PathSpec @(Get-VerificationFingerprintScopePaths))
    $treeish = New-VerificationEffectiveTree -ChangedPaths $changedPaths
    $tree = ([string](Get-GitOutput @("rev-parse", "$treeish^{tree}"))).Trim()
    if ($tree -notmatch '^[a-f0-9]{40}$') {
        throw "VERIFICATION_SELECTION_TREE_INVALID: $tree"
    }
    return $tree
}

function Read-VerificationSelectionProof {
    $path = Join-Path (Get-VerificationSelectionStateRoot) "proof.json"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try { return (Read-Utf8Text -Path $path | ConvertFrom-Json) } catch { return $null }
}

function Get-VerificationSelectionChangedPaths {
    param(
        [string]$BaseTree,
        [string]$CurrentTree
    )

    if ($BaseTree -notmatch '^[a-f0-9]{40}$' -or $CurrentTree -notmatch '^[a-f0-9]{40}$') {
        throw "VERIFICATION_SELECTION_TREE_INVALID"
    }
    & git -C $script:ProjectRoot cat-file -e "$BaseTree^{tree}" 2>$null
    if ($LASTEXITCODE -ne 0) { throw "VERIFICATION_SELECTION_BASE_TREE_MISSING: $BaseTree" }
    $scopePaths = @(Get-VerificationFingerprintScopePaths | ForEach-Object { ([string]$_ -replace "\\", "/").Trim("/") } | Where-Object { $_ })
    $changed = @(Get-GitPathList -Arguments @("diff", "--name-only", "-z", "--no-renames", $BaseTree, $CurrentTree, "--") | Where-Object {
        $candidate = ([string]$_ -replace "\\", "/").TrimStart("/")
        @($scopePaths | Where-Object { $candidate -eq $_ -or $candidate.StartsWith("$_/", [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
    })
    if ($changed -contains '.agent-1c/dependency-lock.json' -and
        (Get-VerificationRelevantDependencyLockFingerprint -Treeish $BaseTree) -ceq
        (Get-VerificationRelevantDependencyLockFingerprint -Treeish $CurrentTree)) {
        return @($changed | Where-Object { $_ -cne '.agent-1c/dependency-lock.json' })
    }
    return $changed
}

function Get-VerificationAcceptedMasterInput {
    param([string[]]$ChangedPaths, [string]$CurrentTree)

    $result = [pscustomobject]@{
        available = $false; reference = ''; masterTip = ''; acceptedCommit = ''; branchHead = ''
        importedPaths = @(); branchPaths = @($ChangedPaths); reason = ''
    }
    try {
        if ($CurrentTree -notmatch '^[a-f0-9]{40}$') { throw 'Invalid effective tree.' }
        $branch = ([string](Get-GitOutput @('branch', '--show-current'))).Trim()
        if ($branch -notlike 'itldev/*') { throw 'Accepted master input requires a managed development branch.' }
        $masterRef = "refs/heads/$(Get-MasterBranch)"
        $masterTip = ([string](Get-GitOutput @('rev-parse', '--verify', "$masterRef^{commit}"))).Trim()
        $branchHead = ([string](Get-GitOutput @('rev-parse', '--verify', 'HEAD^{commit}'))).Trim()
        if ($masterTip -notmatch '^[a-f0-9]{40}$' -or $branchHead -notmatch '^[a-f0-9]{40}$') { throw 'Invalid master or branch commit.' }
        # Freeze both tips before finding ancestry. A newer master tip is not
        # necessarily accepted; multiple merge bases do not establish one source.
        $acceptedCommit = ([string](Get-GitOutput @('merge-base', '--all', $masterTip, $branchHead))).Trim()
        if ($acceptedCommit -notmatch '^[a-f0-9]{40}$') { throw 'No unique accepted master ancestor.' }
        $roots = @((Get-ExportPath), (Get-ExtensionsPath) | ForEach-Object {
            (Get-VerificationRepoRelativePath -Path (Resolve-ProjectPath $_)).TrimEnd('/')
        } | Sort-Object -Unique)
        $literalRoots = @($roots | ForEach-Object { ":(literal)$_" })
        # NUL-delimited names and --no-renames preserve deletion/addition pairs.
        # Comparing trees includes staged and unstaged content without touching
        # the user's index; a modified imported module remains branch-owned.
        $different = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($path in @(Get-GitPathList -Arguments (@('diff', '--name-only', '-z', '--no-renames', '--no-ext-diff', '--no-textconv', $acceptedCommit, $CurrentTree, '--') + $literalRoots))) {
            [void]$different.Add([string]$path)
        }
        $imported = @($ChangedPaths | Where-Object {
            $path = [string]$_
            @($roots | Where-Object { $path.StartsWith("$_/", [StringComparison]::Ordinal) }).Count -gt 0 -and
                -not $different.Contains($path)
        })
        $result.available = $true
        $result.reference = $masterRef; $result.masterTip = $masterTip
        $result.acceptedCommit = $acceptedCommit; $result.branchHead = $branchHead
        $result.importedPaths = $imported
        $result.branchPaths = @($ChangedPaths | Where-Object { $_ -cnotin $imported })
        $result.reason = 'Imported paths exactly match the unique accepted master ancestor in the effective tree.'
    } catch {
        $result.reason = $_.Exception.Message
    }
    return $result
}

function Get-VerificationLegacySourceBaseline {
    if (-not (Get-Command Read-DevBranchState -ErrorAction SilentlyContinue) -or
        -not (Get-Command Get-StateValue -ErrorAction SilentlyContinue)) { return $null }
    try {
        $branchVariable = Get-Variable -Name DevBranchName -Scope Script -ErrorAction SilentlyContinue
        $branchName = if ($null -ne $branchVariable) { [string]$branchVariable.Value } else { '' }
        $state = Read-DevBranchState -Name $branchName
        $baseline = Get-StateValue -State $state -Name 'yaxunitApplicabilityBaseline' -Default $null
    } catch { return $null }
    if ($null -eq $baseline -or -not [bool](Get-StateValue -State $baseline -Name 'legacy' -Default $false)) { return $null }
    $commit = [string](Get-StateValue -State $baseline -Name 'commit' -Default '')
    if ([int](Get-StateValue -State $baseline -Name 'schemaVersion' -Default 0) -ne 1 -or
        $commit -notmatch '^[a-f0-9]{40}$') {
        throw 'YAXUNIT_APPLICABILITY_BASELINE_MISSING: the managed branch needs its workflow adoption baseline.'
    }
    return $baseline
}

function Test-VerificationLegacySourcePath {
    param([object]$Baseline, [string]$CurrentTree, [string]$Path)

    if ($null -eq $Baseline) { return $false }
    $roots = Get-VerificationConfigurationMetadataRoots
    $sourceRoots = @(@($roots.configurationRoots) + @($roots.extensionRoots) | Where-Object { $_ } | Sort-Object -Unique)
    if (@($sourceRoots | Where-Object { $Path.StartsWith("$_/", [StringComparison]::OrdinalIgnoreCase) }).Count -eq 0) { return $false }
    $currentOid = Get-GitObjectIdForTreePath -Treeish $CurrentTree -RepoPath $Path
    $adoptionOid = Get-GitObjectIdForTreePath -Treeish ([string]$Baseline.commit) -RepoPath $Path
    if ($currentOid -ceq $adoptionOid) { return $true }
    $legacySourceOids = if ($Baseline.PSObject.Properties['legacySourceOids']) { @($Baseline.legacySourceOids) } else { @() }
    return @($legacySourceOids | Where-Object { $_.path -ieq $Path -and $_.sourceOid -ceq $currentOid }).Count -gt 0
}

function Get-VerificationConfigurationMetadataRoots {
    $configurationRoots = [Collections.Generic.List[string]]::new()
    $extensionRoots = [Collections.Generic.List[string]]::new()
    $normalize = {
        param([string]$Path)
        if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
        return (($Path -replace "\\", "/").Trim("/"))
    }

    $primaryConfigurationRoot = if (Get-Command Get-ExportPath -ErrorAction SilentlyContinue) { Get-ExportPath } else { "src/cf" }
    $primaryExtensionsRoot = if (Get-Command Get-ExtensionsPath -ErrorAction SilentlyContinue) { Get-ExtensionsPath } else { "src/cfe" }
    $configurationRoots.Add((& $normalize $primaryConfigurationRoot))
    $extensionRoots.Add((& $normalize $primaryExtensionsRoot))
    if (Get-Command Get-AuxiliaryContourDefinitions -ErrorAction SilentlyContinue) {
        try {
            foreach ($contour in @(Get-AuxiliaryContourDefinitions)) {
                $configurationPath = & $normalize ([string](Get-StateValue -State $contour -Name "configurationPath" -Default ""))
                if ($configurationPath) { $configurationRoots.Add($configurationPath) }
                $extensionsProperty = $contour.PSObject.Properties["extensions"]
                $extensions = if ($null -eq $extensionsProperty -or $null -eq $extensionsProperty.Value) { @() } else { @($extensionsProperty.Value) }
                foreach ($extension in $extensions) {
                    $extensionPath = & $normalize ([string](Get-StateValue -State $extension -Name "path" -Default ""))
                    if ($extensionPath) { $extensionRoots.Add($extensionPath) }
                }
            }
        } catch {
            # Auxiliary definitions are optional for primary verification. An
            # invalid declaration is rejected by its own admission path.
        }
    }
    return [pscustomobject]@{
        configurationRoots = @($configurationRoots | Where-Object { $_ } | Sort-Object -Unique)
        extensionRoots = @($extensionRoots | Where-Object { $_ } | Sort-Object -Unique)
        primaryExtensionsRoot = (& $normalize $primaryExtensionsRoot)
    }
}

function Test-VerificationConfigurationMetadataPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [ValidateSet("ConfigDumpInfo.xml", "Configuration.xml")][string]$FileName
    )
    $normalized = (($Path -replace "\\", "/").TrimStart("/"))
    $roots = Get-VerificationConfigurationMetadataRoots
    foreach ($root in @($roots.configurationRoots)) {
        if ($normalized -ceq "$root/$FileName") { return $true }
    }
    foreach ($root in @($roots.extensionRoots)) {
        if ($normalized -ceq "$root/$FileName") { return $true }
        # The configured primary extension path is a container; each immediate
        # child is one extension dump root.
        if ($root -ceq $roots.primaryExtensionsRoot -and
            $normalized -match ('^' + [regex]::Escape($root) + '/[^/]+/' + [regex]::Escape($FileName) + '$')) {
            return $true
        }
    }
    return $false
}

function New-VerificationSelectionPlan {
    param(
        [string[]]$ApplicationFeatureFiles,
        [switch]$YAxUnitVerificationPlanned,
        [switch]$RequireObservedReceipts
    )

    $allFiles = @($ApplicationFeatureFiles | Sort-Object -Unique)
    $catalog = Read-VerificationSuiteCatalog -ApplicationFeatureFiles $allFiles
    $currentTree = ""
    try { $currentTree = Get-VerificationSelectionEffectiveTree } catch {}
    $acceptedMasterInput = $null

    $newFullPlan = {
        param([string]$Reason)
        $fullFiles = @(if ($catalog.available -and $catalog.valid) {
            @($catalog.assignments | Where-Object purpose -eq "acceptance" | Select-Object -ExpandProperty fullPath -Unique)
        } else {
            $allFiles
        })
        if ($fullFiles.Count -eq 0) { $fullFiles = $allFiles }
        [pscustomobject]@{
            mode = "full"
            reason = $Reason
            selectedFeatureFiles = $fullFiles
            selectedSuiteIds = @($catalog.assignments | Where-Object purpose -eq "acceptance" | Select-Object -ExpandProperty suiteId -Unique)
            acceptanceSuiteIds = @($catalog.assignments | Where-Object purpose -eq "acceptance" | Select-Object -ExpandProperty suiteId -Unique)
            acceptanceSuites = @($catalog.suiteFingerprints | Where-Object purpose -eq "acceptance")
            catalogFingerprint = [string]$catalog.fingerprint
            currentTree = $currentTree
            catalogAvailable = [bool]($catalog.available -and $catalog.valid)
            acceptedMasterInput = $acceptedMasterInput
        }
    }

    $newClassificationRequiredPlan = {
        param([string]$Reason)
        [pscustomobject]@{
            mode = "classification-required"
            reason = $Reason
            selectedFeatureFiles = @()
            selectedSuiteIds = @()
            acceptanceSuiteIds = @()
            acceptanceSuites = @()
            catalogFingerprint = [string]$catalog.fingerprint
            currentTree = $currentTree
            catalogAvailable = [bool]($catalog.available -and $catalog.valid)
            acceptedMasterInput = $acceptedMasterInput
        }
    }

    if (-not $catalog.available) { return (& $newClassificationRequiredPlan $catalog.fallbackReason) }
    if (-not $catalog.valid) { return (& $newClassificationRequiredPlan "Catalog is invalid: $($catalog.fallbackReason)") }
    if (-not $catalog.classificationComplete) { return (& $newClassificationRequiredPlan (@($catalog.issues) -join "; ")) }

    $acceptanceAssignments = @($catalog.assignments | Where-Object purpose -eq "acceptance")
    $acceptanceSuiteIds = @($acceptanceAssignments | Select-Object -ExpandProperty suiteId -Unique)
    $acceptanceSuites = @($catalog.suiteFingerprints | Where-Object purpose -eq "acceptance")
    if ($acceptanceAssignments.Count -eq 0) {
        return [pscustomobject]@{
            mode = "reuse"
            reason = "The complete catalog has no retained acceptance suite; ordinary Vanessa execution is not applicable. One-off obligations remain subject to readiness assessment."
            selectedFeatureFiles = @()
            selectedSuiteIds = @()
            acceptanceSuiteIds = @()
            acceptanceSuites = @()
            catalogFingerprint = [string]$catalog.fingerprint
            currentTree = $currentTree
            catalogAvailable = $true
        }
    }
    if (-not $currentTree) { return (& $newFullPlan "Effective Git tree could not be created.") }

    $proof = Read-VerificationSelectionProof
    if ($null -eq $proof -or [int](Get-VerificationCatalogValue -Value $proof -Name "schemaVersion" -Default 0) -ne 1) {
        return (& $newFullPlan "No compatible complete suite proof exists yet.")
    }
    $provedSuites = @(Get-VerificationCatalogValue -Value $proof -Name "acceptanceSuites" -Default @())
    if ($RequireObservedReceipts) {
        $state = Read-DevBranchState -Name $DevBranchName
        try { $targetIdentity = Get-VerificationRetainedTargetIdentity -State $state }
        catch { return (& $newFullPlan $_.Exception.Message) }
        $receipts = @(Get-VerificationCatalogValue -Value $proof -Name 'suiteEvidence' -Default @())
        foreach ($id in $acceptanceSuiteIds) {
            $receipt = @($receipts | Where-Object id -eq $id)
            $obligation = @($catalog.obligations | Where-Object suiteId -eq $id)[0]
            if ($receipt.Count -ne 1 -or [string]$receipt[0].status -cne 'passed' -or
                [string]::IsNullOrWhiteSpace([string]$receipt[0].loadedBaseIdentity) -or
                [string]$receipt[0].targetIdentity -cne $targetIdentity -or
                [string]$receipt[0].checkerIdentity -cne (Get-VerificationRetainedCheckerIdentity) -or
                [string]$receipt[0].obligationHash -cne (Get-VerificationOneOffObligationHash -Obligation $obligation) -or
                [string]$receipt[0].runtimeIdentity -cne (Get-VerificationRelevantDependencyLockFingerprint -Treeish $currentTree)) {
                return (& $newFullPlan "Retained suite '$id' needs current observed receipt identity; the permitted unfiltered runner supplies it.")
            }
            try {
                Assert-VerificationArtifactReferences -Artifacts @($receipt[0].artifacts) -JUnit
                Assert-VerificationRecordedSuiteCoverage -Receipt $receipt[0]
                $provedSuite = @($provedSuites | Where-Object id -eq $id)
                $currentSuite = @($acceptanceSuites | Where-Object id -eq $id)
                if ($provedSuite.Count -ne 1 -or $currentSuite.Count -ne 1) {
                    throw "Retained suite '$id' has unknown suite fingerprint compatibility."
                }
                # Old observed proof remains evidence for the previous feature;
                # existing changed-input selection schedules only its owner.
                # Current mapping is required here only for unchanged features.
                if ([string]$provedSuite[0].fingerprint -ceq [string]$currentSuite[0].fingerprint) {
                    Assert-VerificationRetainedSuiteCoverage -Receipt $receipt[0] -Catalog $catalog
                }
            }
            catch { return (& $newFullPlan $_.Exception.Message) }
        }
    }
    if ($provedSuites.Count -eq 0) {
        return (& $newFullPlan "Previous proof has no per-suite fingerprints.")
    }
    $provedSuiteIds = @($provedSuites | ForEach-Object { [string](Get-VerificationCatalogValue -Value $_ -Name "id" -Default "") })
    if (@($provedSuiteIds | Where-Object { $_ -and $_ -notin $acceptanceSuiteIds }).Count -gt 0) {
        return (& $newFullPlan "An acceptance suite was removed or changed to explicit; safe full acceptance fallback is required.")
    }

    try {
        $changedPaths = @(Get-VerificationSelectionChangedPaths -BaseTree ([string](Get-VerificationCatalogValue -Value $proof -Name "tree" -Default "")) -CurrentTree $currentTree)
    } catch {
        return (& $newFullPlan $_.Exception.Message)
    }
    if ($changedPaths.Count -eq 0) {
        return [pscustomobject]@{
            mode = "reuse"
            reason = "No verification-relevant changes were found; complete acceptance proof is reusable."
            selectedFeatureFiles = @()
            selectedSuiteIds = @()
            acceptanceSuiteIds = $acceptanceSuiteIds
            acceptanceSuites = $acceptanceSuites
            catalogFingerprint = [string]$catalog.fingerprint
            currentTree = $currentTree
            catalogAvailable = $true
        }
    }

    $yaxunitCatalog = $null
    if ($YAxUnitVerificationPlanned) {
        $yaxunitCatalog = Read-YAxUnitSuiteCatalog -ModuleFiles @(Get-YAxUnitModuleFiles)
        if (-not [bool]$yaxunitCatalog.classificationComplete) {
            return (& $newClassificationRequiredPlan ("YAxUnit classification is incomplete: " + (@($yaxunitCatalog.issues) -join "; ")))
        }
    }

    $acceptedMasterInput = Get-VerificationAcceptedMasterInput -ChangedPaths $changedPaths -CurrentTree $currentTree
    $legacyBaseline = Get-VerificationLegacySourceBaseline
    $fullReasons = [Collections.Generic.List[string]]::new()
    $classificationReasons = [Collections.Generic.List[string]]::new()
    $legacyPathCount = 0
    $selectedIds = New-Object "System.Collections.Generic.HashSet[string]" ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($suiteProof in $acceptanceSuites) {
        $prior = @($provedSuites | Where-Object { [string](Get-VerificationCatalogValue -Value $_ -Name "id" -Default "") -eq [string]$suiteProof.id })
        if ($prior.Count -ne 1 -or [string](Get-VerificationCatalogValue -Value $prior[0] -Name "fingerprint" -Default "") -cne [string]$suiteProof.fingerprint) {
            [void]$selectedIds.Add([string]$suiteProof.id)
        }
    }
    foreach ($suite in @($catalog.suites | Where-Object { $_.purpose -eq "acceptance" -and $_.always })) { [void]$selectedIds.Add([string]$suite.id) }
    $catalogRepoPaths = @($catalog.catalogPaths | ForEach-Object { Get-VerificationRepoRelativePath -Path $_ })
    $yaxunitRoot = ((Get-YAxUnitTestsPath) -replace "\\", "/").Trim("/")
    $yaxunitCatalogRepoPaths = @(Get-YAxUnitSuiteCatalogPaths | ForEach-Object { Get-VerificationRepoRelativePath -Path $_ })
    $featureRoot = ((Get-VanessaFeaturesPath) -replace "\\", "/").Trim("/")
    $metadataRoots = Get-VerificationConfigurationMetadataRoots
    $productRoots = @(@($metadataRoots.configurationRoots) + @($metadataRoots.extensionRoots) | Where-Object { $_ })
    foreach ($changedPathValue in $changedPaths) {
        $changedPath = ([string]$changedPathValue -replace "\\", "/").TrimStart("/")
        if ($changedPath -in $catalogRepoPaths) { continue }
        if ($changedPath -in $yaxunitCatalogRepoPaths -or ($yaxunitRoot -and $changedPath.StartsWith("$yaxunitRoot/", [System.StringComparison]::OrdinalIgnoreCase))) { continue }
        $featureAssignment = @($catalog.assignments | Where-Object path -eq $changedPath)
        if ($featureAssignment.Count -eq 1) {
            if ($featureAssignment[0].purpose -eq "acceptance") { [void]$selectedIds.Add([string]$featureAssignment[0].suiteId) }
            continue
        }
        if ($featureRoot -and $changedPath.StartsWith("$featureRoot/", [System.StringComparison]::OrdinalIgnoreCase)) {
            $fullReasons.Add("Shared Vanessa support changed at '$changedPath'; the complete acceptance set is required.")
            continue
        }
        $declaredObligations = @((Get-VerificationCatalogValue -Value $catalog -Name 'obligations' -Default @()) | Where-Object {
            $obligation = $_
            $obligation.retention -eq 'retained' -and $obligation.suiteId -and
                @($obligation.inputPaths | Where-Object { Test-VerificationRepoPathPattern -Path $changedPath -Pattern $_ }).Count -gt 0
        })
        $isProductPath = @($productRoots | Where-Object {
            $changedPath -eq $_ -or $changedPath.StartsWith("$_/", [System.StringComparison]::OrdinalIgnoreCase)
        }).Count -gt 0
        if ($declaredObligations.Count -gt 0 -and -not $isProductPath) {
            foreach ($obligation in $declaredObligations) {
                if ($obligation.cadence -eq 'affected') { [void]$selectedIds.Add([string]$obligation.suiteId) }
            }
            continue
        }
        if ($changedPath -eq ".agent-1c/dependency-lock.json") {
            $fullReasons.Add("The pinned verification runtime changed; the complete acceptance set is required.")
            continue
        }
        if ($changedPath -in @(
            '.agents/skills/1c-workflow/scripts/lib/agent-1c.vanessa.ps1',
            '.agents/skills/1c-workflow/scripts/lib/agent-1c.yaxunit.ps1',
            '.agents/skills/1c-workflow/scripts/lib/agent-1c.verification-selection.ps1',
            '.agents/skills/1c-workflow/scripts/lib/agent-1c.verification-modes.ps1'
        )) {
            $fullReasons.Add("The verification owner changed at '$changedPath'; the complete acceptance set is required.")
            continue
        }
        if (Test-VerificationConfigurationMetadataPath -Path $changedPath -FileName "ConfigDumpInfo.xml") {
            # ConfigDumpInfo is the dump cursor maintained by 1C. It carries no
            # independent semantic owner and must not force a suite assignment.
            continue
        }
        if (Test-VerificationConfigurationMetadataPath -Path $changedPath -FileName "Configuration.xml") {
            $fullReasons.Add("Shared configuration metadata changed at '$changedPath'; the complete acceptance set is required.")
            continue
        }
        $ownerMatches = @($catalog.suites | Where-Object {
            $suite = $_
            @($suite.ownerPaths | Where-Object { Test-VerificationRepoPathPattern -Path $changedPath -Pattern $_ }).Count -gt 0
        })
        if ($ownerMatches.Count -eq 0) {
            $oneOffOwnerMatches = @((Get-VerificationCatalogValue -Value $catalog -Name 'obligations' -Default @()) | Where-Object {
                $obligation = $_
                $obligation.retention -eq 'one-off' -and
                    @($obligation.inputPaths | Where-Object { Test-VerificationRepoPathPattern -Path $changedPath -Pattern $_ }).Count -gt 0
            })
            if ($oneOffOwnerMatches.Count -gt 0) { continue }
            $yaxunitOwnerMatches = @(if ($YAxUnitVerificationPlanned -and $null -ne $yaxunitCatalog) {
                $yaxunitCatalog.groups | Where-Object {
                    $group = $_
                    $group.purpose -eq "default-fast" -and
                        @($group.ownerPaths | Where-Object { Test-VerificationRepoPathPattern -Path $changedPath -Pattern $_ }).Count -gt 0
                }
            })
            if ($yaxunitOwnerMatches.Count -gt 0) { continue }
            if ($changedPath -cin $acceptedMasterInput.importedPaths) { continue }
            if (Test-VerificationLegacySourcePath -Baseline $legacyBaseline -CurrentTree $currentTree -Path $changedPath) {
                $legacyPathCount++
                continue
            }
            $classificationReasons.Add("Changed verification-relevant path '$changedPath' has no suite owner.")
            continue
        }
        foreach ($suite in $ownerMatches) {
            if ($suite.purpose -eq "acceptance") { [void]$selectedIds.Add([string]$suite.id) }
        }
    }

    # A full-suite reason may not conceal another, branch-owned unclassified
    # path. Evaluate the entire delta before deciding whether execution is ready.
    if ($classificationReasons.Count -gt 0) { return (& $newClassificationRequiredPlan ($classificationReasons -join '; ')) }
    if ($acceptedMasterInput.importedPaths.Count -gt 0) {
        $fullReasons.Add("Accepted master input at '$($acceptedMasterInput.acceptedCommit)' requires complete existing acceptance coverage; imported paths=$($acceptedMasterInput.importedPaths.Count). No new master tests were authored.")
    }
    if ($legacyPathCount -gt 0) {
        $fullReasons.Add("Pre-adoption branch source requires complete existing acceptance coverage; legacy paths=$legacyPathCount. No new branch tests are required for unchanged legacy content.")
    }
    if ($fullReasons.Count -gt 0) { return (& $newFullPlan ($fullReasons -join '; ')) }

    $selectedFiles = @($acceptanceAssignments | Where-Object { $selectedIds.Contains([string]$_.suiteId) } | Select-Object -ExpandProperty fullPath -Unique)
    if ($selectedFiles.Count -eq 0) {
        return [pscustomobject]@{
            mode = "reuse"
            reason = "Changed paths are covered by planned YAxUnit or explicit Vanessa suites; complete acceptance proof is reusable."
            selectedFeatureFiles = @()
            selectedSuiteIds = @()
            acceptanceSuiteIds = $acceptanceSuiteIds
            acceptanceSuites = $acceptanceSuites
            catalogFingerprint = [string]$catalog.fingerprint
            currentTree = $currentTree
            catalogAvailable = $true
        }
    }
    return [pscustomobject]@{
        mode = "incremental"
        reason = "Reused complete proof for unchanged suites; changed paths selected: $($changedPaths.Count)."
        selectedFeatureFiles = $selectedFiles
        selectedSuiteIds = @($selectedIds | Sort-Object)
        acceptanceSuiteIds = $acceptanceSuiteIds
        acceptanceSuites = $acceptanceSuites
        catalogFingerprint = [string]$catalog.fingerprint
        currentTree = $currentTree
        catalogAvailable = $true
    }
}

function Get-VerificationRetainedTargetIdentity {
    param([object]$State)
    # Scoped source freshness is checked separately. Keep the exact target and
    # runtime generations strict without invalidating an unaffected suite when
    # another object's current bytes were legitimately reloaded into that target.
    foreach ($name in @('stateProjectRoot', 'infoBaseKind', 'devBranchInfoBasePath',
        'toolingInfoBaseGeneration', 'vanessaServiceInfoBaseGeneration')) {
        if (-not [string](Get-StateValue -State $State -Name $name -Default '')) {
            throw "VERIFICATION_RETAINED_TARGET_UNVERIFIED: '$name' is unknown; repeat the normal permitted verification through its existing target/tooling owner."
        }
    }
    $base = Get-OneCInfoBaseIdentity -InfoBaseKind ([string]$State.infoBaseKind) -InfoBasePath ([string]$State.devBranchInfoBasePath)
    $fields = @('stateProjectRoot', 'infoBaseKind', 'devBranchInfoBasePath',
        'devBranchKind', 'extensionName', 'safeDevBranchName',
        'toolingInfoBaseGeneration', 'vanessaServiceInfoBaseGeneration',
        'vanessaServiceInfoBaseKind', 'vanessaServiceInfoBasePath',
        'vanessaServiceInfoBaseSchemaVersion', 'vanessaServiceInfoBaseTemplateSha256',
        'vanessaServiceInfoBaseUser',
        'connectionIdentityHash')
    $parts = @('retained-target-v1', "normalizedConnectionHash=$(Get-VerificationSelectionSha256 -Text ([string]$base.key))") + @($fields | ForEach-Object {
        "$_=$([string](Get-StateValue -State $State -Name $_ -Default ''))"
    })
    if ($script:ActiveAuxiliaryVanessaContext) {
        if (-not [string](Get-StateValue -State $State -Name 'connectionIdentityHash' -Default '')) {
            throw 'VERIFICATION_RETAINED_TARGET_UNVERIFIED: auxiliary connection identity is unknown; preserve its existing qualified owner.'
        }
        $context = $script:ActiveAuxiliaryVanessaContext
        $parts += @('scope=auxiliary', "auxiliaryName=$($context.contour.name)",
            "auxiliaryBaseMode=$($context.contour.baseMode)", "auxiliarySuite=$($context.suite)")
    } else { $parts += 'scope=primary' }
    return Get-VerificationSelectionSha256 -Text ($parts -join "`n")
}

function Get-VerificationRetainedCheckerIdentity {
    $parts = @('retained-checker-v1', (Get-VerificationOneOffCheckerIdentity -ProofType 'vanessa-junit'))
    foreach ($name in @('Get-VerificationRetainedTargetIdentity', 'Get-VerificationCurrentProofAssessment',
        'Get-VerificationSuiteJUnitCoverage', 'Assert-VerificationRecordedSuiteCoverage', 'Assert-VerificationRetainedSuiteCoverage',
        'Get-VanessaFeatureScenarioDefinitions', 'Get-VanessaJunitSummary')) {
        $command = Get-Command -Name $name -CommandType Function -ErrorAction Stop
        $parts += "$name=$($command.ScriptBlock.ToString().Replace("`r`n", "`n"))"
    }
    return Get-VerificationSelectionSha256 -Text ($parts -join "`n")
}

function Get-VerificationSuiteJUnitCoverage {
    param([object]$Catalog, [string[]]$SelectedSuiteIds, [object]$JUnit, [switch]$IgnoreUnselectedCases)

    # Pinned Vanessa replaces the temporary filename with the feature header
    # and optionally prefixes its first relative directory. Resolve cases
    # against every declared suite, including unselected suites: a shared
    # title and scenario cannot establish which source actually ran.
    $featureRoot = Resolve-ProjectPath (Get-VanessaFeaturesPath)
    $bindings = @{}
    foreach ($assignment in @($Catalog.assignments)) {
        $relative = ([string]$assignment.fullPath).Substring($featureRoot.TrimEnd([char[]]@('\','/')).Length).TrimStart([char[]]@('\','/')).Replace('\','/')
        foreach ($scenario in @(Get-VanessaFeatureScenarioDefinitions -FeatureFiles @($assignment.fullPath))) {
            $featureName = [string]$scenario.featureName
            $qualifiedName = if ($relative.Contains('/')) { $relative.Split('/')[0] + '.' + $featureName } else { $featureName }
            $names = @(if ($scenario.isOutline) { $scenario.junitNames.ToArray() } else { [string]$scenario.name })
            foreach ($name in $names) {
                $key = "$($assignment.path)`n$($scenario.sourceLine)`n$name"
                if (-not $bindings.ContainsKey($key)) {
                    $bindings[$key] = [pscustomobject]@{suiteId=[string]$assignment.suiteId;path=[string]$assignment.path;line=[int]$scenario.sourceLine;featureName=$featureName;qualifiedName=$qualifiedName;name=[string]$name;expected=0;observed=0;ambiguous=$false}
                }
                $bindings[$key].expected++
            }
        }
    }
    $unmapped = 0
    foreach ($case in @($JUnit.testCases)) {
        $matches = @($bindings.Values | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_.featureName) -and
            [string]$case.name -ceq $_.name -and
            ([string]$case.className -ceq $_.featureName -or [string]$case.className -ceq $_.qualifiedName)
        })
        if ($matches.Count -eq 1) {
            if ($matches[0].suiteId -in $SelectedSuiteIds) { $matches[0].observed++ }
            elseif (-not $IgnoreUnselectedCases) { $unmapped++ }
        }
        elseif ($matches.Count -gt 1) { foreach ($match in $matches) { $match.ambiguous=$true } }
        elseif (-not $IgnoreUnselectedCases) { $unmapped++ }
    }
    return @($SelectedSuiteIds | ForEach-Object {
        $id = $_
        $items = @($bindings.Values | Where-Object suiteId -eq $id | Sort-Object path,line,name)
        $expected = 0; $observed = 0; $issues = @()
        foreach ($item in $items) {
            $expected += $item.expected; $observed += $item.observed
            if ($item.ambiguous) { $issues += "ambiguous scenario '$($item.path):$($item.line)'" }
            elseif ($item.observed -ne $item.expected) { $issues += "missing or duplicate scenario '$($item.path):$($item.line)' expected=$($item.expected) observed=$($item.observed)" }
        }
        if ($expected -eq 0) { $issues += 'unobserved selected suite has no native scenario identity' }
        if ($unmapped -gt 0) { $issues += "$unmapped unmapped JUnit testcase(s)" }
        [pscustomobject]@{
            schemaVersion=1;id=$id;status=$(if($issues.Count -eq 0){'passed'}else{'partial'})
            expectedCaseFingerprint=Get-VerificationSelectionSha256 -Text (@($items | ForEach-Object { "$($_.path)`t$($_.line)`t$($_.featureName)`t$($_.name)`t$($_.expected)" }) -join "`n")
            expectedCount=$expected;observedCount=$observed;issue=($issues -join '; ')
        }
    })
}

function Assert-VerificationRecordedSuiteCoverage {
    param([object]$Receipt)
    $coverage = Get-VerificationCatalogValue -Value $Receipt -Name 'coverage' -Default $null
    if ($null -eq $coverage -or [int]$coverage.schemaVersion -ne 1 -or [string]$coverage.status -cne 'passed' -or
        [string]$coverage.id -cne [string]$Receipt.id -or
        [string]$coverage.expectedCaseFingerprint -notmatch '^[a-f0-9]{64}$' -or
        [int]$coverage.expectedCount -le 0 -or [int]$coverage.observedCount -ne [int]$coverage.expectedCount) {
        throw "VERIFICATION_RETAINED_COVERAGE_PENDING: suite '$($Receipt.id)' has no observed per-suite coverage."
    }
}

function Assert-VerificationRetainedSuiteCoverage {
    param([object]$Receipt, [object]$Catalog)
    Assert-VerificationRecordedSuiteCoverage -Receipt $Receipt
    $coverage = $Receipt.coverage
    $junit = Get-VanessaJunitSummary -ReportPaths @($Receipt.artifacts | ForEach-Object { Resolve-ProjectPath ([string]$_.path) })
    $actual = @(Get-VerificationSuiteJUnitCoverage -Catalog $Catalog -SelectedSuiteIds @([string]$Receipt.id) -JUnit $junit -IgnoreUnselectedCases)[0]
    if ([string]$actual.status -cne 'passed' -or [string]$actual.expectedCaseFingerprint -cne [string]$coverage.expectedCaseFingerprint -or
        [int]$actual.expectedCount -ne [int]$coverage.expectedCount -or [int]$actual.observedCount -ne [int]$coverage.observedCount) {
        throw "VERIFICATION_RETAINED_COVERAGE_PENDING: suite '$($Receipt.id)' coverage is missing or ambiguous: $($actual.issue)"
    }
}

function New-VerificationArtifactReferences {
    param([string[]]$Paths)
    return @($Paths | ForEach-Object {
        $full = Resolve-ProjectPath $_
        $relative = Get-VerificationRepoRelativePath -Path $full
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "Verification artifact is missing: $relative" }
        [pscustomobject]@{ path = $relative; sha256 = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant() }
    })
}

function Assert-VerificationArtifactReferences {
    param([object[]]$Artifacts, [switch]$JUnit)
    if (@($Artifacts).Count -eq 0) { throw 'No observed artifact was retained.' }
    foreach ($artifact in @($Artifacts)) {
        $full = Resolve-ProjectPath ([string]$artifact.path)
        [void](Get-VerificationRepoRelativePath -Path $full)
        if (-not (Test-Path -LiteralPath $full -PathType Leaf) -or
            (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$artifact.sha256) {
            throw "Verification artifact changed or is missing: $($artifact.path)"
        }
        if ($JUnit) { Assert-VerificationOneOffJUnitEvidence -Path $full }
    }
}

function Add-VerificationComponentEvidenceUpdates {
    param([hashtable]$Updates, [object]$State, [string]$Component, [string]$Status,
        [string[]]$ArtifactPaths = @(), [object]$EventLogObservation = $null, [string]$RunDirectory = '')

    $receipts = [ordered]@{}
    $existing = Get-StateValue -State $State -Name 'lastVerificationComponentEvidence' -Default $null
    if ($null -ne $existing) { foreach ($property in $existing.PSObject.Properties) { $receipts[$property.Name] = $property.Value } }
    if ($Component -eq 'event-log' -and $Status -eq 'passed') {
        if ($null -eq $EventLogObservation -or [string]$EventLogObservation.status -ne 'passed' -or
            [int]$EventLogObservation.newErrorCount -ne 0) { throw 'Passed event-log proof needs the actual clean observation.' }
        $path = Join-Path $RunDirectory 'event-log-observation.json'
        Write-Utf8TextAtomic -Path $path -Value (($EventLogObservation | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
        $ArtifactPaths = @($path)
    }
    $proofType = if ($Component -eq 'event-log') { 'event-log' } else { 'yaxunit-junit' }
    $receipts[$Component] = [pscustomobject]@{
        schemaVersion = 1; component = $Component; status = $Status
        inputFingerprint = Get-VerificationFingerprint
        loadedBaseIdentity = Get-VerificationLoadedBaseIdentity -State $State
        checkerIdentity = Get-VerificationOneOffCheckerIdentity -ProofType $proofType
        artifacts = @(if ($Status -eq 'passed') { New-VerificationArtifactReferences -Paths $ArtifactPaths })
        limitations = 'The observed component and exact loaded target only; other obligations are assessed independently.'
        observedAt = (Get-Date).ToUniversalTime().ToString('o')
    }
    $Updates['lastVerificationComponentEvidence'] = [pscustomobject]$receipts
}

function Assert-VerificationComponentEvidence {
    param([object]$State, [string]$Component, [string]$Fingerprint)
    $receipts = Get-StateValue -State $State -Name 'lastVerificationComponentEvidence' -Default $null
    $receipt = Get-VerificationCatalogValue -Value $receipts -Name $Component -Default $null
    $proofType = if ($Component -eq 'event-log') { 'event-log' } else { 'yaxunit-junit' }
    if ($null -eq $receipt -or [int]$receipt.schemaVersion -ne 1 -or [string]$receipt.status -cne 'passed' -or
        [string]$receipt.component -cne $Component -or [string]$receipt.inputFingerprint -cne $Fingerprint -or
        [string]$receipt.loadedBaseIdentity -cne (Get-VerificationLoadedBaseIdentity -State $State) -or
        [string]$receipt.checkerIdentity -cne (Get-VerificationOneOffCheckerIdentity -ProofType $proofType)) {
        throw "VERIFICATION_COMPONENT_PROOF_PENDING: '$Component' needs current evidence for the exact loaded target."
    }
    Assert-VerificationArtifactReferences -Artifacts @($receipt.artifacts)
    if ($Component -eq 'yaxunit') {
        $summary = Get-YAxUnitJunitSummary -Path (Resolve-ProjectPath ([string]$receipt.artifacts[0].path))
        if (-not $summary.passed) { throw 'VERIFICATION_COMPONENT_PROOF_INVALID: the retained YAxUnit report did not pass its authoritative parser.' }
    }
    if ($Component -eq 'event-log') {
        $observed = Read-Utf8Text -Path (Resolve-ProjectPath ([string]$receipt.artifacts[0].path)) | ConvertFrom-Json -ErrorAction Stop
        if ([string]$observed.status -cne 'passed' -or
            [int](Get-VerificationCatalogValue -Value $observed -Name 'newErrorCount' -Default -1) -ne 0 -or
            [string]::IsNullOrWhiteSpace([string]$observed.scanMode) -or [string]$observed.scanMode -in @('failed', 'skipped') -or
            [string](Get-StateValue -State $State -Name 'eventLogDebtStatus' -Default '') -eq 'failed') {
            throw 'VERIFICATION_COMPONENT_PROOF_INVALID: event-log evidence is not a clean current observation.'
        }
    }
}

function Get-VerificationCurrentProofAssessment {
    param([object]$State, [string]$Fingerprint)

    $issues = [Collections.Generic.List[string]]::new()
    $oneOffIssues = [Collections.Generic.List[string]]::new()
    try {
        $currentTree = Get-VerificationSelectionEffectiveTree
        # Pure assessment: never initialize a baseline, load an infobase or start a runner.
        foreach ($content in @(
            [pscustomobject]@{ kind = 'configuration'; path = Get-ExportPath }
            $(if ((Get-DevBranchKind -State $State) -eq 'extension') {
                [pscustomobject]@{ kind = 'extension'; path = Get-DevBranchExtensionExportPath -State $State }
            })
        )) {
            if ($null -eq $content) { continue }
            $loaded = [string](Get-StateValue -State $State -Name (Get-DesignerFingerprintFieldName -ContentKind $content.kind) -Default '')
            if (-not $loaded -or $loaded -cne [string](Get-ConfigSourceFingerprint -ExportPath $content.path).fingerprint) {
                throw "VERIFICATION_LOADED_INPUT_STALE: '$($content.kind)' does not match the current source. Repeat the normal authorized update before assessment."
            }
        }
        if ([string](Get-StateValue -State $State -Name 'configLoadStatus' -Default '') -notin @('passed', 'fallback-succeeded') -or
            -not (Test-DevBranchEnterpriseNormalizationProved -State $State)) {
            throw 'VERIFICATION_LOADED_INPUT_UNVERIFIED: the existing application readiness proof is incomplete.'
        }
        $files = @(Get-VanessaApplicationFeatureFiles -FeaturePath (Get-VanessaFeaturesPath))
        $catalog = Read-VerificationSuiteCatalog -ApplicationFeatureFiles $files
        $yaxCatalog = Read-YAxUnitSuiteCatalog -ModuleFiles @(Get-YAxUnitModuleFiles)
        if (-not $catalog.classificationComplete -or -not $yaxCatalog.classificationComplete) {
            throw "VERIFICATION_CLASSIFICATION_REQUIRED: $(@(@($catalog.issues) + @($yaxCatalog.issues)) -join '; ')"
        }
        $oneOff = @(Get-VerificationOneOffObligations)
        $applicability = Get-YAxUnitProductionApplicability -Catalog $yaxCatalog -State $State -ReadOnly -OneOffObligations $oneOff
        if (-not $applicability.classificationComplete) { throw ($applicability.issues -join '; ') }
        Assert-VerificationComponentEvidence -State $State -Component 'event-log' -Fingerprint $Fingerprint
        foreach ($obligation in $oneOff) {
            $assessment = Get-VerificationOneOffProofAssessment -Obligation $obligation -State $State -Treeish $currentTree
            if (-not $assessment.passed) { $oneOffIssues.Add([string]$assessment.issue) }
        }
        $proof = Read-VerificationSelectionProof
        foreach ($suite in @($catalog.suiteFingerprints | Where-Object purpose -eq 'acceptance')) {
            $obligation = @($catalog.obligations | Where-Object suiteId -eq $suite.id)[0]
            $oldSuite = @(Get-VerificationCatalogValue -Value $proof -Name 'acceptanceSuites' -Default @() | Where-Object id -eq $suite.id)
            $receipt = @(Get-VerificationCatalogValue -Value $proof -Name 'suiteEvidence' -Default @() | Where-Object id -eq $suite.id)
            if ($oldSuite.Count -ne 1 -or [string]$oldSuite[0].fingerprint -cne [string]$suite.fingerprint -or
                $receipt.Count -ne 1 -or [int]$receipt[0].schemaVersion -ne 1 -or [string]$receipt[0].status -cne 'passed' -or
                [string]$receipt[0].obligationHash -cne (Get-VerificationOneOffObligationHash -Obligation $obligation) -or
                [string]$receipt[0].inputIdentity -cne (Get-VerificationObligationInputIdentity -Obligation $obligation -Treeish $currentTree) -or
                [string]$receipt[0].runtimeIdentity -cne (Get-VerificationRelevantDependencyLockFingerprint -Treeish $currentTree) -or
                [string]::IsNullOrWhiteSpace([string]$receipt[0].loadedBaseIdentity) -or
                [string]$receipt[0].targetIdentity -cne (Get-VerificationRetainedTargetIdentity -State $State) -or
                [string]$receipt[0].checkerIdentity -cne (Get-VerificationRetainedCheckerIdentity)) {
                throw "VERIFICATION_RETAINED_PROOF_PENDING: suite '$($suite.id)' needs a current unfiltered observed JUnit result."
            }
            Assert-VerificationArtifactReferences -Artifacts @($receipt[0].artifacts) -JUnit
            Assert-VerificationRetainedSuiteCoverage -Receipt $receipt[0] -Catalog $catalog
        }
        if (@($yaxCatalog.groups | Where-Object purpose -eq 'default-fast').Count -gt 0 -or
            @($applicability.decisions | Where-Object decision -eq 'required').Count -gt 0) {
            Assert-VerificationComponentEvidence -State $State -Component 'yaxunit' -Fingerprint $Fingerprint
        }
        # Empty classified inventory is not a zero-test success. There must be
        # observed current work or a real retained acceptance obligation.
        if ($oneOff.Count -eq 0 -and @($catalog.suiteFingerprints | Where-Object purpose -eq 'acceptance').Count -eq 0 -and
            @($yaxCatalog.groups | Where-Object purpose -eq 'default-fast').Count -eq 0) {
            throw 'VERIFICATION_OBLIGATIONS_MISSING: no observed obligation establishes whole result readiness.'
        }
    } catch { $issues.Add($_.Exception.Message) }
    return [pscustomobject]@{ passed = ($issues.Count -eq 0 -and $oneOffIssues.Count -eq 0); issues = @($issues.ToArray()); oneOffIssues = @($oneOffIssues.ToArray()) }
}

function Complete-VerificationSelectionProof {
    param([object]$Plan, [object]$State = $null, [string]$RunDirectory = '', [string]$Status = 'passed')

    if ($null -eq $Plan -or -not $Plan.catalogAvailable -or [string]::IsNullOrWhiteSpace([string]$Plan.currentTree)) { return }
    $root = Get-VerificationSelectionStateRoot
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    $old = Read-VerificationSelectionProof
    $suiteEvidence = @(Get-VerificationCatalogValue -Value $old -Name 'suiteEvidence' -Default @())
    if ($null -ne $State -and $RunDirectory -and $Plan.mode -ne 'reuse') {
        $junit = Get-VanessaJunitSummary -RunDirectory $RunDirectory
        $artifacts = @(if ($Status -eq 'passed') { New-VerificationArtifactReferences -Paths @($junit.files | ForEach-Object { [string]$_.path }) })
        if ($Status -eq 'passed') { Assert-VerificationArtifactReferences -Artifacts $artifacts -JUnit }
        $catalog = Read-VerificationSuiteCatalog -ApplicationFeatureFiles @(Get-VanessaApplicationFeatureFiles -FeaturePath (Get-VanessaFeaturesPath))
        if ($Status -eq 'passed' -and [string]$catalog.fingerprint -cne [string]$Plan.catalogFingerprint) {
            throw 'VERIFICATION_CATALOG_CHANGED_DURING_RUN: preserve the JUnit result and repeat the original check against the current declared obligations.'
        }
        $coverage = @(if ($Status -eq 'passed') { Get-VerificationSuiteJUnitCoverage -Catalog $catalog -SelectedSuiteIds @($Plan.selectedSuiteIds) -JUnit $junit })
        foreach ($id in @($Plan.selectedSuiteIds)) {
            $obligation = @($catalog.obligations | Where-Object suiteId -eq $id)[0]
            $suiteCoverage = @($coverage | Where-Object id -eq $id)
            $suiteStatus = if ($Status -eq 'passed' -and ($suiteCoverage.Count -ne 1 -or $suiteCoverage[0].status -ne 'passed')) { 'partial' } else { $Status }
            $suiteEvidence = @($suiteEvidence | Where-Object id -ne $id) + @([pscustomobject]@{
                schemaVersion = 1; id = $id; status = $suiteStatus
                coverage = $(if ($suiteCoverage.Count -eq 1) { $suiteCoverage[0] } else { $null })
                coverageIssue = $(if ($suiteCoverage.Count -eq 1) { [string]$suiteCoverage[0].issue } else { '' })
                obligationHash = Get-VerificationOneOffObligationHash -Obligation $obligation
                inputIdentity = Get-VerificationObligationInputIdentity -Obligation $obligation -Treeish ([string]$Plan.currentTree)
                runtimeIdentity = Get-VerificationRelevantDependencyLockFingerprint -Treeish ([string]$Plan.currentTree)
                loadedBaseIdentity = Get-VerificationLoadedBaseIdentity -State $State
                targetIdentity = Get-VerificationRetainedTargetIdentity -State $State
                checkerIdentity = Get-VerificationRetainedCheckerIdentity
                artifacts = $artifacts
            })
        }
    }
    $value = [ordered]@{
        schemaVersion = 1
        tree = [string]$Plan.currentTree
        catalogFingerprint = [string]$Plan.catalogFingerprint
        acceptanceSuiteIds = @($Plan.acceptanceSuiteIds)
        acceptanceSuites = @(Get-VerificationCatalogValue -Value $Plan -Name "acceptanceSuites" -Default @())
        suiteEvidence = $suiteEvidence
        lastSelectedSuiteIds = @($Plan.selectedSuiteIds)
        lastMode = [string]$Plan.mode
        acceptedMasterInput = Get-VerificationCatalogValue -Value $Plan -Name 'acceptedMasterInput' -Default $null
        verifiedAt = (Get-Date).ToString("o")
    }
    Write-Utf8TextAtomic -Path (Join-Path $root "proof.json") -Value (($value | ConvertTo-Json -Depth 10) + [Environment]::NewLine)
}

function Get-YAxUnitProductionApplicability {
    param([object]$Catalog, [object]$State = $null, [switch]$ReadOnly, [object[]]$OneOffObligations = @())

    $state = if ($null -ne $State) { $State } else { Read-DevBranchState -Name $DevBranchName }
    $baseline = Get-StateValue -State $state -Name "yaxunitApplicabilityBaseline" -Default $null
    $roots = Get-VerificationConfigurationMetadataRoots
    $sourceRoots = @(@($roots.configurationRoots) + @($roots.extensionRoots) | Where-Object { $_ } | Sort-Object -Unique)
    try {
        $currentTree = Get-VerificationSelectionEffectiveTree
    } catch {
        $projectRootVariable = Get-Variable -Name ProjectRoot -Scope Script -ErrorAction SilentlyContinue
        if ($null -eq $projectRootVariable -or -not $projectRootVariable.Value -or
            (Test-Path -LiteralPath (Join-Path $projectRootVariable.Value ".git"))) { throw }
        # Classification also runs in projects that contain only Vanessa features.
        # With no Git or production source root there is no BSL applicability to decide.
        # Any source root still needs Git's exact change and object-id evidence.
        $presentSourceRoots = @($sourceRoots | Where-Object { Test-Path -LiteralPath (Resolve-ProjectPath $_) })
        if ($presentSourceRoots.Count -gt 0) {
            throw "YAXUNIT_APPLICABILITY_BASELINE_MISSING: a Git repository is required to classify production BSL changes."
        }
        return [pscustomobject]@{
            classificationComplete = $true; issues = @(); decisions = @()
            legacy = $false; baselineCommit = ""; currentTree = ""
        }
    }
    if ($null -eq $baseline) {
        if ($ReadOnly) { throw 'YAXUNIT_APPLICABILITY_BASELINE_MISSING: classification must first record the exact adoption baseline.' }
        # An existing branch may run check-dev-branch before its first refresh.
        # Preserve its exact dirty BSL content as well as its committed HEAD.
        $adoptionCommit = ([string](Get-GitOutput @("rev-parse", "HEAD^{commit}"))).Trim()
        if ($adoptionCommit -notmatch '^[a-f0-9]{40}$') {
            throw "YAXUNIT_APPLICABILITY_BASELINE_MISSING: cannot identify the branch HEAD for workflow adoption."
        }
        $adoptionTree = ([string](Get-GitOutput @("rev-parse", "$adoptionCommit^{tree}"))).Trim()
        $legacySources = [Collections.Generic.List[object]]::new()
        foreach ($changedPathValue in @(Get-VerificationSelectionChangedPaths -BaseTree $adoptionTree -CurrentTree $currentTree)) {
            $path = ([string]$changedPathValue -replace "\\", "/").TrimStart("/")
            if (@($sourceRoots | Where-Object { $path.StartsWith("$_/", [StringComparison]::OrdinalIgnoreCase) }).Count -eq 0) { continue }
            $sourceOid = Get-GitObjectIdForTreePath -Treeish $currentTree -RepoPath $path
            if ($sourceOid -match '^[a-f0-9]{40}$') {
                $legacySources.Add([pscustomobject]@{ path = $path; sourceOid = $sourceOid })
            }
        }
        $baseline = [pscustomobject][ordered]@{
            schemaVersion = 1
            commit = $adoptionCommit
            legacy = $true
            legacySourceOids = @($legacySources.ToArray())
            recordedAt = (Get-Date).ToString("o")
        }
        Update-DevBranchState -State $state -Updates @{ yaxunitApplicabilityBaseline = $baseline }
    }
    $baselineCommit = [string](Get-StateValue -State $baseline -Name "commit" -Default "")
    if ([int](Get-StateValue -State $baseline -Name "schemaVersion" -Default 0) -ne 1 -or
        $baselineCommit -notmatch '^[a-f0-9]{40}$') {
        throw "YAXUNIT_APPLICABILITY_BASELINE_MISSING: the managed branch needs its workflow adoption baseline."
    }
    $baselineTree = ([string](Get-GitOutput @("rev-parse", "$baselineCommit^{tree}"))).Trim()
    $legacySourceOids = if ($baseline.PSObject.Properties["legacySourceOids"]) { @($baseline.legacySourceOids) } else { @() }
    $changedPaths = @(Get-VerificationSelectionChangedPaths -BaseTree $baselineTree -CurrentTree $currentTree)
    $acceptedMasterInput = Get-VerificationAcceptedMasterInput -ChangedPaths $changedPaths -CurrentTree $currentTree
    $issues = [Collections.Generic.List[string]]::new()
    $decisions = [Collections.Generic.List[object]]::new()
    $registrationTexts = [Collections.Generic.List[string]]::new()
    foreach ($registrationPath in @(Get-VerificationCatalogValue -Value $Catalog -Name "registrationPaths" -Default @())) {
        $registrationText = Read-Utf8Text -Path (Resolve-ProjectPath ([string]$registrationPath))
        $registrationTexts.Add($registrationText)
    }
    foreach ($changedPathValue in $changedPaths) {
        $path = ([string]$changedPathValue -replace "\\", "/").TrimStart("/")
        if ($path -notmatch '(?i)\.bsl$' -or $path -cin @($acceptedMasterInput.importedPaths)) { continue }
        if (@($sourceRoots | Where-Object { $path.StartsWith("$_/", [StringComparison]::OrdinalIgnoreCase) }).Count -eq 0) { continue }
        $sourceOid = Get-GitObjectIdForTreePath -Treeish $currentTree -RepoPath $path
        if ($sourceOid -notmatch '^[a-f0-9]{40}$') { continue } # A deleted module has no new behavior to cover.
        if (@($legacySourceOids | Where-Object {
            $_.path -ieq $path -and $_.sourceOid -ceq $sourceOid
        }).Count -gt 0) { continue }
        $groups = @($Catalog.groups | Where-Object {
            $group = $_
            $group.purpose -eq "default-fast" -and
                @($group.ownerPaths | Where-Object { Test-VerificationRepoPathPattern -Path $path -Pattern $_ }).Count -gt 0
        })
        $declared = @((Get-VerificationCatalogValue -Value $Catalog -Name "notApplicable" -Default @()) | Where-Object { $_.path -ieq $path })
        if ($groups.Count -gt 0 -and $declared.Count -gt 0) {
            $issues.Add("YAxUnit applicability for '$path' is ambiguous: both a default-fast group and notApplicable are declared.")
            continue
        }
        if ($groups.Count -gt 0) {
            if (-not (Test-YAxUnitSuitePresent)) {
                $issues.Add("YAxUnit is required for '$path', but the hierarchical test extension is absent.")
                continue
            }
            foreach ($group in $groups) {
                $modules = @($Catalog.assignments | Where-Object { $_.groupId -eq $group.id -and $_.purpose -eq "default-fast" })
                foreach ($module in $modules) {
                    if (-not (Test-YAxUnitRegistrationReference -ModulePath ([string]$module.path) -RegistrationTexts @($registrationTexts.ToArray())) -and
                        -not (Test-YAxUnitSelfRegisteredModule -ModulePath ([string]$module.path))) {
                        $issues.Add("YAxUnit default-fast module '$($module.path)' for '$path' has neither an ordinary registration reference nor a discoverable exported ИсполняемыеСценарии.")
                    }
                }
            }
            $decisions.Add([pscustomobject]@{ path = $path; sourceOid = $sourceOid; decision = "required"; groupIds = @($groups.id) })
            continue
        }
        $oneOff = @($oneOffObligations | Where-Object {
            @($_.inputPaths | Where-Object { Test-VerificationRepoPathPattern -Path $path -Pattern $_ }).Count -gt 0
        })
        if ($declared.Count -eq 0 -and $oneOff.Count -gt 0) {
            $decisions.Add([pscustomobject]@{ path = $path; sourceOid = $sourceOid; decision = 'one-off'; obligationIds = @($oneOff.id) })
        } elseif ($declared.Count -eq 1 -and [string]$declared[0].sourceOid -ceq $sourceOid) {
            $decisions.Add([pscustomobject]@{ path = $path; sourceOid = $sourceOid; decision = "not-applicable"; reason = [string]$declared[0].reason })
        } else {
            $issues.Add("YAxUnit applicability for '$path' is unclassified or stale. Current sourceOid=$sourceOid. Reuse a sufficient default-fast group, classify a sufficient current one-off obligation, or declare notApplicable with this exact sourceOid and a reason.")
        }
    }
    return [pscustomobject]@{
        classificationComplete = ($issues.Count -eq 0)
        issues = @($issues.ToArray())
        decisions = @($decisions.ToArray())
        legacy = [bool](Get-StateValue -State $baseline -Name "legacy" -Default $false)
        baselineCommit = $baselineCommit
        currentTree = $currentTree
    }
}

function Update-VerificationSuiteInventory {
    param([string]$Reason = "refresh", [switch]$EvaluateApplicability)

    $root = Get-VerificationSelectionStateRoot
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    $started = Get-Date
    try {
        $featurePath = if ($script:ActiveAuxiliaryVanessaContext) {
            Get-VanessaFeaturesPath
        } else {
            Get-VanessaConfiguredFeaturesPath
        }
        $featureRoot = Resolve-ProjectPath $featurePath
        $applicationFiles = @(if (Test-Path -LiteralPath $featureRoot -PathType Container) {
            Get-VanessaApplicationFeatureFiles -FeaturePath $featurePath
        })
        $catalog = Read-VerificationSuiteCatalog -ApplicationFeatureFiles $applicationFiles
        $yaxunitModules = @(Get-YAxUnitModuleFiles)
        $yaxunitCatalog = Read-YAxUnitSuiteCatalog -ModuleFiles $yaxunitModules
        $applicability = if ($EvaluateApplicability -and $catalog.classificationComplete -and $yaxunitCatalog.classificationComplete) {
            Get-YAxUnitProductionApplicability -Catalog $yaxunitCatalog -OneOffObligations @(Get-VerificationOneOffObligations)
        } else {
            [pscustomobject]@{ classificationComplete = $true; issues = @(); decisions = @(); legacy = $false; baselineCommit = ""; currentTree = "" }
        }
        $issues = @(@($catalog.issues) + @($yaxunitCatalog.issues) + @($applicability.issues))
        $value = [ordered]@{
            schemaVersion = 2
            generatedAt = (Get-Date).ToString("o")
            reason = $Reason
            durationMs = [int64]((Get-Date) - $started).TotalMilliseconds
            classificationComplete = [bool]($catalog.classificationComplete -and $yaxunitCatalog.classificationComplete -and $applicability.classificationComplete)
            classificationIssues = $issues
            vanessaClassificationComplete = [bool]$catalog.classificationComplete
            catalogAvailable = [bool]$catalog.available
            catalogValid = [bool]$catalog.valid
            fallbackReason = [string]$catalog.fallbackReason
            featureCount = $applicationFiles.Count
            scenarioCount = @($catalog.scenarios).Count
            acceptanceScenarioLimit = Get-VerificationAcceptanceScenarioLimit
            suites = @($catalog.suites | ForEach-Object { [ordered]@{ id = $_.id; purpose = $_.purpose; always = $_.always } })
            obligations = @($catalog.obligations | ForEach-Object { [ordered]@{
                id = $_.id; expectedResult = $_.expectedResult; inputPaths = @($_.inputPaths)
                admissibleProof = @($_.admissibleProof); retention = $_.retention
                retentionReason = $_.retentionReason; cadence = $_.cadence; suiteId = $_.suiteId
            } })
            assignments = @($catalog.assignments | ForEach-Object { [ordered]@{ path = $_.path; suiteId = $_.suiteId; purpose = $_.purpose } })
            scenarios = @($catalog.scenarios | ForEach-Object { [ordered]@{ path = $_.path; line = $_.line; name = $_.name; tags = @($_.tags); suiteId = $_.suiteId; purpose = $_.purpose; cadenceHint = $_.cadenceHint; fingerprint = $_.fingerprint } })
            scenarioMigrationRequired = [bool]$catalog.migrationRequired
            yaxunit = [ordered]@{
                suitePresent = [bool](Test-YAxUnitSuitePresent)
                catalogAvailable = [bool]$yaxunitCatalog.available
                catalogValid = [bool]$yaxunitCatalog.valid
                classificationComplete = [bool]($yaxunitCatalog.classificationComplete -and $applicability.classificationComplete)
                moduleCount = $yaxunitModules.Count
                groups = @($yaxunitCatalog.groups | ForEach-Object { [ordered]@{ id = $_.id; purpose = $_.purpose } })
                assignments = @($yaxunitCatalog.assignments | ForEach-Object { [ordered]@{ path = $_.path; groupId = $_.groupId; purpose = $_.purpose } })
                registrationPaths = @($yaxunitCatalog.registrationPaths)
                applicability = @($applicability.decisions)
                legacyBaseline = [bool]$applicability.legacy
                baselineCommit = [string]$applicability.baselineCommit
            }
        }
        Write-Utf8TextAtomic -Path (Join-Path $root "inventory.json") -Value (($value | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
        if ($Reason -match '(?i)refresh|post-merge') {
            $baselinePath = Get-VerificationScenarioMigrationBaselinePath
            if ($value.scenarioMigrationRequired) {
                $baseline = [ordered]@{
                    schemaVersion = 1
                    createdAt = (Get-Date).ToString("o")
                    reason = $Reason
                    scenarios = @($catalog.scenarios | ForEach-Object { [ordered]@{ name = $_.name; fingerprint = $_.fingerprint } })
                }
                Write-Utf8TextAtomic -Path $baselinePath -Value (($baseline | ConvertTo-Json -Depth 5) + [Environment]::NewLine)
            } elseif (Test-Path -LiteralPath $baselinePath -PathType Leaf) {
                Remove-Item -LiteralPath $baselinePath -Force
            }
        }
        Write-Host "Test classification inventory: Vanessa=$($applicationFiles.Count) feature file(s), YAxUnit=$($yaxunitModules.Count) module(s), status=$(if ($value.classificationComplete) { 'ready' } else { 'classification-required' }), duration=$($value.durationMs) ms."
        return [pscustomobject]$value
    } catch {
        $value = [ordered]@{
            schemaVersion = 2
            generatedAt = (Get-Date).ToString("o")
            reason = $Reason
            durationMs = [int64]((Get-Date) - $started).TotalMilliseconds
            classificationComplete = $false
            classificationIssues = @($_.Exception.Message)
            vanessaClassificationComplete = $false
            catalogAvailable = $false
            catalogValid = $false
            fallbackReason = $_.Exception.Message
            featureCount = 0
            scenarioCount = 0
            acceptanceScenarioLimit = Get-VerificationAcceptanceScenarioLimit
            suites = @()
            assignments = @()
            scenarios = @()
            scenarioMigrationRequired = $false
            yaxunit = [ordered]@{ suitePresent = $false; catalogAvailable = $false; catalogValid = $false; classificationComplete = $false; moduleCount = 0; groups = @(); assignments = @(); registrationPaths = @(); applicability = @(); legacyBaseline = $false; baselineCommit = "" }
        }
        Write-Utf8TextAtomic -Path (Join-Path $root "inventory.json") -Value (($value | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
        Write-Host "[WARN] Test classification inventory failed. Normal verification will stop before starting 1C. $($_.Exception.Message)"
        return [pscustomobject]$value
    }
}

function Assert-VerificationScenarioMigrationPreserved {
    param([object]$Inventory)

    $baselinePath = Get-VerificationScenarioMigrationBaselinePath
    if (-not (Test-Path -LiteralPath $baselinePath -PathType Leaf)) { return }
    $baseline = Read-Utf8Text -Path $baselinePath | ConvertFrom-Json
    if ([int](Get-VerificationCatalogValue -Value $baseline -Name "schemaVersion" -Default 0) -ne 1) {
        throw "VERIFICATION_SUITE_MIGRATION_BASELINE_INVALID: $baselinePath"
    }
    $before = @($baseline.scenarios | ForEach-Object { [string]$_.fingerprint } | Sort-Object)
    $after = @($Inventory.scenarios | ForEach-Object { [string]$_.fingerprint } | Sort-Object)
    $difference = @(Compare-Object -ReferenceObject $before -DifferenceObject $after)
    if ($difference.Count -gt 0) {
        Set-RunFailureContext -Category "missing-suite" -RequiredAction "restore-scenario-behavior-and-complete-test-classification"
        throw "VERIFICATION_SUITE_MIGRATION_CHANGED_SCENARIOS: classification migration must only move intact scenarios and cadence tags; scenario behavior differs from the post-refresh baseline at '$baselinePath'."
    }
    Remove-Item -LiteralPath $baselinePath -Force
}

function Get-VerificationClassificationInventoryPath {
    return (Join-Path (Get-VerificationSelectionStateRoot) "inventory.json")
}

function Set-VerificationClassificationRequiredAction {
    param([object]$Inventory)

    if ($null -eq $Inventory -or [bool]$Inventory.classificationComplete) { return }
    $existing = [string]$script:RunRequiredAction
    $action = "classify-tests-after-refresh: read .agents/skills/1c-workflow/references/verification-suite-selection.md and the inventory at $(Get-VerificationClassificationInventoryPath); in this same agent task classify changed BSL and tests, preserve scenario behavior when splitting mixed files, update branch catalogs, and validate classification before reporting refresh complete"
    if ($existing -and $existing -notmatch '^classify-tests-after-refresh:') {
        $action += "; then also follow: $existing"
    }
    $script:RunRequiredAction = $action
}

function Assert-VerificationClassificationReady {
    param(
        [string]$Reason = "verification preflight",
        [switch]$RequireVanessa,
        [switch]$RequireYAxUnit
    )

    $inventory = Update-VerificationSuiteInventory -Reason $Reason -EvaluateApplicability
    $ready = (-not $RequireVanessa -or [bool]$inventory.vanessaClassificationComplete) -and
        (-not $RequireYAxUnit -or [bool]$inventory.yaxunit.classificationComplete)
    if (-not $ready) {
        try {
            $state = Read-DevBranchState -Name $DevBranchName
            Update-DevBranchState -State $state -Updates @{
                verificationClassificationStatus = "required"
                verificationClassificationIssues = @($inventory.classificationIssues)
                verificationClassificationInventoryPath = Get-VerificationClassificationInventoryPath
                verificationClassificationCheckedAt = (Get-Date).ToString("o")
            }
        } catch {
            Write-Host "[WARN] Test classification state could not be persisted: $($_.Exception.Message)"
        }
        Set-RunFailureContext -Category "missing-suite" -RequiredAction "classify-tests-and-repeat-original-itl-command"
        $detail = @($inventory.classificationIssues) -join "; "
        throw "ITL_TEST_CLASSIFICATION_REQUIRED: $detail Inventory: $(Get-VerificationClassificationInventoryPath)"
    }
    return $inventory
}

function Test-VerificationClassification {
    Set-RunStage -Stage "verification.classification" -Detail "Validating Vanessa and YAxUnit test classification without starting 1C."
    $inventory = Assert-VerificationClassificationReady -Reason "explicit classification validation" -RequireVanessa -RequireYAxUnit
    Assert-VerificationScenarioMigrationPreserved -Inventory $inventory
    $state = Read-DevBranchState -Name $DevBranchName
    Update-DevBranchState -State $state -Updates @{
        verificationClassificationStatus = "ready"
        verificationClassificationIssues = @()
        verificationClassificationInventoryPath = Get-VerificationClassificationInventoryPath
        verificationClassificationCheckedAt = (Get-Date).ToString("o")
    }
    Write-VerificationClassificationRunUserReport -State $state -Inventory $inventory
    Write-Host "Test classification is complete: Vanessa=$($inventory.featureCount) feature file(s); YAxUnit=$($inventory.yaxunit.moduleCount) module(s)."
    Write-Host "Inventory: $(Get-VerificationClassificationInventoryPath)"
    return $inventory
}

function Write-VerificationClassificationStatusLines {
    param([object]$State, [string]$Indent = "")

    $status = [string](Get-StateValue -State $State -Name "verificationClassificationStatus" -Default "unknown")
    Write-Host "${Indent}Test classification: $status"
    $applicabilityBaseline = Get-StateValue -State $State -Name "yaxunitApplicabilityBaseline" -Default $null
    if ([bool](Get-StateValue -State $applicabilityBaseline -Name "legacy" -Default $false)) {
        Write-Host "${Indent}YAxUnit coverage: legacy baseline; unchanged pre-upgrade BSL has no new unit-test obligation."
    }
    $inventoryPath = [string](Get-StateValue -State $State -Name "verificationClassificationInventoryPath" -Default "")
    if ($inventoryPath) { Write-Host "${Indent}Test classification inventory: $inventoryPath" }
    foreach ($issue in @(Get-StateValue -State $State -Name "verificationClassificationIssues" -Default @())) {
        Write-Host "${Indent}Test classification issue: $issue"
    }
}
