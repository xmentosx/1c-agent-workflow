function Get-VerificationSelectionStateRoot {
    return (Resolve-ProjectPath ".agent-1c/verification-selection")
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
        return [pscustomobject]@{
            available = $false
            valid = $true
            classificationComplete = ($issues.Count -eq 0)
            issues = $issues
            fallbackReason = $(if ($issues.Count -gt 0) { $issues[0] } else { "No Vanessa application feature files require classification." })
            suites = @()
            assignments = $assignments
            suiteFingerprints = @()
            fingerprint = "legacy"
            catalogPaths = @()
        }
    }

    $suiteIds = New-Object "System.Collections.Generic.HashSet[string]" ([System.StringComparer]::OrdinalIgnoreCase)
    $suites = New-Object System.Collections.Generic.List[object]
    $fingerprintParts = New-Object System.Collections.Generic.List[string]
    try {
        foreach ($catalogPath in $catalogPaths) {
            $raw = Read-Utf8Text -Path $catalogPath
            $fingerprintParts.Add("$(Get-VerificationRepoRelativePath -Path $catalogPath)=$(Get-VerificationSelectionSha256 -Text $raw)")
            $catalog = $raw | ConvertFrom-Json
            if ([int](Get-VerificationCatalogValue -Value $catalog -Name "schemaVersion" -Default 0) -ne 1) {
                throw "VERIFICATION_SUITE_SCHEMA_UNSUPPORTED: '$catalogPath' must use schemaVersion=1."
            }
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
                $suites.Add([pscustomobject][ordered]@{
                    id = $id
                    purpose = $purpose
                    always = [bool](Get-VerificationCatalogValue -Value $suite -Name "always" -Default $false)
                    featurePaths = $featurePatterns
                    ownerPaths = $ownerPatterns
                    source = Get-VerificationRepoRelativePath -Path $catalogPath
                })
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
                $assignments.Add([pscustomobject]@{ path = $repoPath; suiteId = [string]$matches[0].id; purpose = [string]$matches[0].purpose; fullPath = $featureFile })
            }
        }
        foreach ($suite in @($suites.ToArray())) {
            if (@($assignments.ToArray() | Where-Object suiteId -eq $suite.id).Count -eq 0) {
                throw "VERIFICATION_SUITE_EMPTY: suite '$($suite.id)' does not match any current application feature file."
            }
        }
        $issues = @($assignments.ToArray() | Where-Object suiteId -eq "__unclassified__" | ForEach-Object { "Unclassified Vanessa feature: $($_.path)" })
        foreach ($assignment in @($assignments | Sort-Object path)) {
            $fingerprintParts.Add("$($assignment.path)=$($assignment.suiteId):$($assignment.purpose)")
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
                "assigned=$($assignedPaths -join ',')"
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
            assignments = @($assignments.ToArray())
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
            assignments = @()
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
    return @(Get-GitPathList -Arguments @("diff", "--name-only", "-z", "--no-renames", $BaseTree, $CurrentTree, "--") | Where-Object {
        $candidate = ([string]$_ -replace "\\", "/").TrimStart("/")
        @($scopePaths | Where-Object { $candidate -eq $_ -or $candidate.StartsWith("$_/", [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
    })
}

function New-VerificationSelectionPlan {
    param([string[]]$ApplicationFeatureFiles)

    $allFiles = @($ApplicationFeatureFiles | Sort-Object -Unique)
    $catalog = Read-VerificationSuiteCatalog -ApplicationFeatureFiles $allFiles
    $currentTree = ""
    try { $currentTree = Get-VerificationSelectionEffectiveTree } catch {}

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
            reason = "The complete catalog contains only explicit suites; ordinary Vanessa execution is not applicable."
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
            return (& $newFullPlan "Shared Vanessa support changed at '$changedPath'; the complete acceptance set is required.")
        }
        if ($changedPath -eq ".agent-1c/dependency-lock.json") {
            return (& $newFullPlan "The pinned verification runtime changed; the complete acceptance set is required.")
        }
        $ownerMatches = @($catalog.suites | Where-Object {
            $suite = $_
            @($suite.ownerPaths | Where-Object { Test-VerificationRepoPathPattern -Path $changedPath -Pattern $_ }).Count -gt 0
        })
        if ($ownerMatches.Count -eq 0) {
            return (& $newClassificationRequiredPlan "Changed verification-relevant path '$changedPath' has no suite owner.")
        }
        foreach ($suite in $ownerMatches) {
            if ($suite.purpose -eq "acceptance") { [void]$selectedIds.Add([string]$suite.id) }
        }
    }

    $selectedFiles = @($acceptanceAssignments | Where-Object { $selectedIds.Contains([string]$_.suiteId) } | Select-Object -ExpandProperty fullPath -Unique)
    if ($selectedFiles.Count -eq 0) {
        return [pscustomobject]@{
            mode = "reuse"
            reason = "Changed paths belong only to explicit suites; complete acceptance proof is reusable."
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

function Complete-VerificationSelectionProof {
    param([object]$Plan)

    if ($null -eq $Plan -or -not $Plan.catalogAvailable -or [string]::IsNullOrWhiteSpace([string]$Plan.currentTree)) { return }
    $root = Get-VerificationSelectionStateRoot
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    $value = [ordered]@{
        schemaVersion = 1
        tree = [string]$Plan.currentTree
        catalogFingerprint = [string]$Plan.catalogFingerprint
        acceptanceSuiteIds = @($Plan.acceptanceSuiteIds)
        acceptanceSuites = @(Get-VerificationCatalogValue -Value $Plan -Name "acceptanceSuites" -Default @())
        lastSelectedSuiteIds = @($Plan.selectedSuiteIds)
        lastMode = [string]$Plan.mode
        verifiedAt = (Get-Date).ToString("o")
    }
    Write-Utf8TextAtomic -Path (Join-Path $root "proof.json") -Value (($value | ConvertTo-Json -Depth 6) + [Environment]::NewLine)
}

function Update-VerificationSuiteInventory {
    param([string]$Reason = "refresh")

    $root = Get-VerificationSelectionStateRoot
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    $started = Get-Date
    try {
        $featurePath = Get-VanessaFeaturesPath
        $featureRoot = Resolve-ProjectPath $featurePath
        $applicationFiles = @(if (Test-Path -LiteralPath $featureRoot -PathType Container) {
            Get-VanessaApplicationFeatureFiles -FeaturePath $featurePath
        })
        $catalog = Read-VerificationSuiteCatalog -ApplicationFeatureFiles $applicationFiles
        $yaxunitModules = @(Get-YAxUnitModuleFiles)
        $yaxunitCatalog = Read-YAxUnitSuiteCatalog -ModuleFiles $yaxunitModules
        $issues = @(@($catalog.issues) + @($yaxunitCatalog.issues))
        $value = [ordered]@{
            schemaVersion = 2
            generatedAt = (Get-Date).ToString("o")
            reason = $Reason
            durationMs = [int64]((Get-Date) - $started).TotalMilliseconds
            classificationComplete = [bool]($catalog.classificationComplete -and $yaxunitCatalog.classificationComplete)
            classificationIssues = $issues
            vanessaClassificationComplete = [bool]$catalog.classificationComplete
            catalogAvailable = [bool]$catalog.available
            catalogValid = [bool]$catalog.valid
            fallbackReason = [string]$catalog.fallbackReason
            featureCount = $applicationFiles.Count
            suites = @($catalog.suites | ForEach-Object { [ordered]@{ id = $_.id; purpose = $_.purpose; always = $_.always } })
            assignments = @($catalog.assignments | ForEach-Object { [ordered]@{ path = $_.path; suiteId = $_.suiteId; purpose = $_.purpose } })
            yaxunit = [ordered]@{
                suitePresent = [bool](Test-YAxUnitSuitePresent)
                catalogAvailable = [bool]$yaxunitCatalog.available
                catalogValid = [bool]$yaxunitCatalog.valid
                classificationComplete = [bool]$yaxunitCatalog.classificationComplete
                moduleCount = $yaxunitModules.Count
                groups = @($yaxunitCatalog.groups | ForEach-Object { [ordered]@{ id = $_.id; purpose = $_.purpose } })
                assignments = @($yaxunitCatalog.assignments | ForEach-Object { [ordered]@{ path = $_.path; groupId = $_.groupId; purpose = $_.purpose } })
                registrationPaths = @($yaxunitCatalog.registrationPaths)
            }
        }
        Write-Utf8TextAtomic -Path (Join-Path $root "inventory.json") -Value (($value | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
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
            suites = @()
            assignments = @()
            yaxunit = [ordered]@{ suitePresent = $false; catalogAvailable = $false; catalogValid = $false; classificationComplete = $false; moduleCount = 0; groups = @(); assignments = @(); registrationPaths = @() }
        }
        Write-Utf8TextAtomic -Path (Join-Path $root "inventory.json") -Value (($value | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
        Write-Host "[WARN] Test classification inventory failed. Normal verification will stop before starting 1C. $($_.Exception.Message)"
        return [pscustomobject]$value
    }
}

function Get-VerificationClassificationInventoryPath {
    return (Join-Path (Get-VerificationSelectionStateRoot) "inventory.json")
}

function Set-VerificationClassificationRequiredAction {
    param([object]$Inventory)

    if ($null -eq $Inventory -or [bool]$Inventory.classificationComplete) { return }
    $existing = [string]$script:RunRequiredAction
    $action = "classify-tests-after-refresh: read .agents/skills/1c-workflow/references/verification-suite-selection.md and the inventory at $(Get-VerificationClassificationInventoryPath); update the branch test catalogs in this same agent task before reporting refresh complete"
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

    $inventory = Update-VerificationSuiteInventory -Reason $Reason
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
    $state = Read-DevBranchState -Name $DevBranchName
    Update-DevBranchState -State $state -Updates @{
        verificationClassificationStatus = "ready"
        verificationClassificationIssues = @()
        verificationClassificationInventoryPath = Get-VerificationClassificationInventoryPath
        verificationClassificationCheckedAt = (Get-Date).ToString("o")
    }
    Write-Host "Test classification is complete: Vanessa=$($inventory.featureCount) feature file(s); YAxUnit=$($inventory.yaxunit.moduleCount) module(s)."
    Write-Host "Inventory: $(Get-VerificationClassificationInventoryPath)"
    return $inventory
}

function Write-VerificationClassificationStatusLines {
    param([object]$State, [string]$Indent = "")

    $status = [string](Get-StateValue -State $State -Name "verificationClassificationStatus" -Default "unknown")
    Write-Host "${Indent}Test classification: $status"
    $inventoryPath = [string](Get-StateValue -State $State -Name "verificationClassificationInventoryPath" -Default "")
    if ($inventoryPath) { Write-Host "${Indent}Test classification inventory: $inventoryPath" }
    foreach ($issue in @(Get-StateValue -State $State -Name "verificationClassificationIssues" -Default @())) {
        Write-Host "${Indent}Test classification issue: $issue"
    }
}
