function Get-YAxUnitInstallRoot {
    $value = Get-Setting -EnvName "YAXUNIT_INSTALL_ROOT" -ConfigName "yaxunit.installRoot" -Default ".agent-1c/tools/yaxunit"
    return (Resolve-ProjectPath ([string]$value))
}

function Get-YAxUnitTestsPath {
    $value = Get-Setting -EnvName "YAXUNIT_TESTS_PATH" -ConfigName "yaxunit.testsPath" -Default "tests/yaxunit"
    $relative = ([string]$value).Replace("\", "/").Trim("/")
    if ([string]::IsNullOrWhiteSpace($relative) -or [System.IO.Path]::IsPathRooted([string]$value) -or $relative -match '(^|/)\.\.(/|$)') {
        throw "ITL_YAXUNIT_TEST_SOURCE_OUTSIDE_PROJECT: yaxunit.testsPath must be a project-relative path without '..'."
    }
    return $relative
}

function Get-YAxUnitReportsPath {
    $value = Get-Setting -EnvName "YAXUNIT_REPORTS_PATH" -ConfigName "yaxunit.reportsPath" -Default "build/test-results/yaxunit"
    return (Resolve-ProjectPath ([string]$value))
}

function Get-YAxUnitExtensionName {
    return "YAXUNIT"
}

function Get-YAxUnitTestsExtensionName {
    return [string](Get-Setting -EnvName "YAXUNIT_TESTS_EXTENSION_NAME" -ConfigName "yaxunit.testsExtensionName" -Default "tests")
}

function Get-YAxUnitSuiteCatalogPaths {
    return @(
        (Resolve-ProjectPath "tests/yaxunit-suites.shared.json"),
        (Resolve-ProjectPath "tests/yaxunit-suites.branch.json")
    )
}

function Get-YAxUnitCatalogValue {
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

function Get-YAxUnitModuleFiles {
    $root = Resolve-ProjectPath (Get-YAxUnitTestsPath)
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return @() }
    return @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter "Module.bsl" | Select-Object -ExpandProperty FullName | Sort-Object -Unique)
}

function Get-YAxUnitModuleNameFromPath {
    param([string]$Path)

    $normalized = ($Path -replace "\\", "/").TrimStart("/")
    $match = [regex]::Match($normalized, '(?i)(?:^|/)CommonModules/([^/]+)/Ext/Module\.bsl$')
    if (-not $match.Success) { return "" }
    return $match.Groups[1].Value
}

function Test-YAxUnitExecutableScenariosExport {
    param([string]$ModulePath)

    $text = Read-Utf8Text -Path (Resolve-ProjectPath $ModulePath)
    return [regex]::IsMatch($text, '(?im)^\s*Процедура\s+ИсполняемыеСценарии\s*\(\s*\)\s*Экспорт\b')
}

function Test-YAxUnitSelfRegisteredModule {
    param([string]$ModulePath)

    if (-not (Test-YAxUnitExecutableScenariosExport -ModulePath $ModulePath)) { return $false }
    $normalized = ($ModulePath -replace '\\', '/').TrimStart('/')
    $match = [regex]::Match($normalized, '(?i)^(.+)/CommonModules/([^/]+)/Ext/Module\.bsl$')
    if (-not $match.Success) { return $false }
    $metadataPath = Resolve-ProjectPath "$($match.Groups[1].Value)/CommonModules/$($match.Groups[2].Value).xml"
    if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) { return $false }
    try {
        $metadata = [xml](Read-Utf8Text -Path $metadataPath)
        $properties = $metadata.SelectSingleNode("/*[local-name()='MetaDataObject']/*[local-name()='CommonModule']/*[local-name()='Properties']")
        if ($null -eq $properties) { return $false }
        $serverCall = $properties.SelectSingleNode("*[local-name()='ServerCall']")
        if ($null -eq $serverCall -or $serverCall.InnerText.Trim() -ine 'false') { return $false }
        foreach ($context in @('Server', 'ClientManagedApplication', 'ClientOrdinaryApplication')) {
            $node = $properties.SelectSingleNode("*[local-name()='$context']")
            if ($null -ne $node -and $node.InnerText.Trim() -ieq 'true') { return $true }
        }
    } catch { return $false }
    return $false
}

function Test-YAxUnitRegistrationReference {
    param([string]$ModulePath, [string[]]$RegistrationTexts)

    $moduleName = Get-YAxUnitModuleNameFromPath -Path $ModulePath
    if (-not $moduleName) { return $false }
    $pattern = '(?i)(?<![\p{L}\p{N}_])' + [regex]::Escape($moduleName) + '\s*\.'
    foreach ($registrationText in @($RegistrationTexts)) {
        $withoutComments = [regex]::Replace([string]$registrationText, '(?m)//[^\r\n]*', '')
        if ([regex]::IsMatch($withoutComments, $pattern)) { return $true }
    }
    return $false
}

function Read-YAxUnitSuiteCatalog {
    param([string[]]$ModuleFiles = @())

    $catalogPaths = @(Get-YAxUnitSuiteCatalogPaths | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
    if ($catalogPaths.Count -eq 0) {
        $issues = @()
        $assignments = @()
        if (@($ModuleFiles).Count -gt 0) {
            $assignments = @($ModuleFiles | ForEach-Object {
                [pscustomobject]@{ path = Get-VerificationRepoRelativePath -Path $_; groupId = "__unclassified__"; purpose = ""; fullPath = $_ }
            })
            $issues = @("YAxUnit test modules exist, but tests/yaxunit-suites.shared.json or tests/yaxunit-suites.branch.json is missing.") +
                @($assignments | ForEach-Object { "Unclassified YAxUnit module: $($_.path)" })
        }
        return [pscustomobject]@{
            available = $false
            valid = $true
            classificationComplete = ($issues.Count -eq 0)
            issues = $issues
            groups = @()
            obligations = @()
            assignments = $assignments
            registrationPaths = @()
            notApplicable = @()
            catalogPaths = @()
        }
    }

    $groupIds = New-Object "System.Collections.Generic.HashSet[string]" ([System.StringComparer]::OrdinalIgnoreCase)
    $obligationIds = New-Object "System.Collections.Generic.HashSet[string]" ([System.StringComparer]::OrdinalIgnoreCase)
    $groups = New-Object System.Collections.Generic.List[object]
    $obligations = New-Object System.Collections.Generic.List[object]
    $registrationPaths = New-Object "System.Collections.Generic.HashSet[string]" ([System.StringComparer]::OrdinalIgnoreCase)
    $notApplicable = New-Object System.Collections.Generic.List[object]
    $notApplicablePaths = New-Object "System.Collections.Generic.HashSet[string]" ([System.StringComparer]::OrdinalIgnoreCase)
    try {
        foreach ($catalogPath in $catalogPaths) {
            $catalog = (Read-Utf8Text -Path $catalogPath) | ConvertFrom-Json
            $schemaVersion = [int](Get-YAxUnitCatalogValue -Value $catalog -Name "schemaVersion" -Default 0)
            if ($schemaVersion -notin @(1, 2)) {
                throw "YAXUNIT_SUITE_SCHEMA_UNSUPPORTED: '$catalogPath' must use schemaVersion=1 or 2."
            }
            $catalogGroups = New-Object System.Collections.Generic.List[object]
            foreach ($decision in @(Get-YAxUnitCatalogValue -Value $catalog -Name "notApplicable" -Default @())) {
                $path = ([string](Get-YAxUnitCatalogValue -Value $decision -Name "path" -Default "") -replace "\\", "/").TrimStart("/")
                $sourceOid = [string](Get-YAxUnitCatalogValue -Value $decision -Name "sourceOid" -Default "")
                $reason = [string](Get-YAxUnitCatalogValue -Value $decision -Name "reason" -Default "")
                if (-not $path -or [IO.Path]::IsPathRooted([string](Get-YAxUnitCatalogValue -Value $decision -Name "path" -Default "")) -or
                    $path -match '(^|/)\.\.(/|$)|[\*\?\[]' -or $path -notmatch '(?i)\.bsl$') {
                    throw "YAXUNIT_APPLICABILITY_PATH_INVALID: '$path' must be one exact repository-relative BSL path."
                }
                if ($sourceOid -notmatch '^[a-f0-9]{40}$' -or [string]::IsNullOrWhiteSpace($reason)) {
                    throw "YAXUNIT_APPLICABILITY_DECISION_INVALID: '$path' needs a sourceOid and a reason."
                }
                if (-not $notApplicablePaths.Add($path)) {
                    throw "YAXUNIT_APPLICABILITY_DUPLICATE: '$path' is declared more than once."
                }
                $notApplicable.Add([pscustomobject]@{ path = $path; sourceOid = $sourceOid; reason = $reason.Trim() })
            }
            foreach ($registrationPath in @(Get-YAxUnitCatalogValue -Value $catalog -Name "registrationPaths" -Default @())) {
                $normalizedRegistrationPath = ([string]$registrationPath -replace "\\", "/").TrimStart("/")
                $testsRoot = ((Get-YAxUnitTestsPath) -replace "\\", "/").Trim("/")
                if (-not $normalizedRegistrationPath -or [IO.Path]::IsPathRooted([string]$registrationPath) -or $normalizedRegistrationPath -match '(^|/)\.\.(/|$)' -or -not $normalizedRegistrationPath.StartsWith("$testsRoot/", [StringComparison]::OrdinalIgnoreCase)) {
                    throw "YAXUNIT_REGISTRATION_PATH_INVALID: '$registrationPath' must be inside '$testsRoot'."
                }
                [void]$registrationPaths.Add($normalizedRegistrationPath)
            }
            foreach ($group in @(Get-YAxUnitCatalogValue -Value $catalog -Name "groups" -Default @())) {
                $id = [string](Get-YAxUnitCatalogValue -Value $group -Name "id" -Default "")
                $purpose = [string](Get-YAxUnitCatalogValue -Value $group -Name "purpose" -Default "")
                if ($id -notmatch '^[a-z0-9][a-z0-9._-]*$') {
                    throw "YAXUNIT_SUITE_ID_INVALID: '$id' in '$catalogPath'."
                }
                if (-not $groupIds.Add($id)) {
                    throw "YAXUNIT_SUITE_ID_DUPLICATE: '$id'. Shared and branch catalogs are additive; ids must be unique."
                }
                if ($purpose -notin @("default-fast", "explicit-benchmark")) {
                    throw "YAXUNIT_SUITE_PURPOSE_INVALID: group '$id' must use purpose='default-fast' or purpose='explicit-benchmark'."
                }
                $modulePatterns = @(Get-YAxUnitCatalogValue -Value $group -Name "modulePaths" -Default @() | ForEach-Object { ([string]$_ -replace "\\", "/").TrimStart("/") } | Where-Object { $_ })
                if ($modulePatterns.Count -eq 0) {
                    throw "YAXUNIT_SUITE_MODULES_MISSING: group '$id' has no modulePaths."
                }
                $ownerPatterns = @(Get-YAxUnitCatalogValue -Value $group -Name "ownerPaths" -Default @() | ForEach-Object { ([string]$_ -replace "\\", "/").TrimStart("/") } | Where-Object { $_ })
                if ($ownerPatterns.Count -eq 0) {
                    throw "YAXUNIT_SUITE_OWNERS_MISSING: group '$id' has no ownerPaths."
                }
                $normalizedGroup = [pscustomobject][ordered]@{
                    id = $id
                    purpose = $purpose
                    modulePaths = $modulePatterns
                    ownerPaths = $ownerPatterns
                    source = Get-VerificationRepoRelativePath -Path $catalogPath
                }
                $groups.Add($normalizedGroup)
                $catalogGroups.Add($normalizedGroup)
            }
            foreach ($obligation in @(Read-VerificationObligationDecisions -Catalog $catalog -CatalogPath $catalogPath -Runner yaxunit -RetainedEntries @($catalogGroups.ToArray()))) {
                if (-not $obligationIds.Add([string]$obligation.id)) {
                    throw "VERIFICATION_OBLIGATION_ID_DUPLICATE: '$($obligation.id)' appears in more than one catalog."
                }
                $obligations.Add($obligation)
            }
        }

        $assignments = New-Object System.Collections.Generic.List[object]
        $issues = New-Object System.Collections.Generic.List[string]
        # One-off proof is checked by the common readiness assessor after
        # classification. A pending receipt must not prevent retained tests.
        foreach ($obligation in @($obligations.ToArray() | Where-Object { $_.retention -eq 'retained' -and -not $_.migratedFromSchema1 })) {
            $group = @($groups.ToArray() | Where-Object id -eq $obligation.groupId)[0]
            if (($obligation.cadence -eq 'explicit' -and $group.purpose -ne 'explicit-benchmark') -or
                ($obligation.cadence -in @('affected', 'handoff') -and $group.purpose -ne 'default-fast')) {
                $issues.Add("VERIFICATION_CADENCE_SELECTION_PENDING: obligation '$($obligation.id)' has cadence '$($obligation.cadence)' that the current YAxUnit selector cannot execute without changing its purpose. Preserve the group and choose a supported invocation route.")
            }
        }
        foreach ($moduleFile in @($ModuleFiles)) {
            $repoPath = Get-VerificationRepoRelativePath -Path $moduleFile
            if ($registrationPaths.Contains($repoPath)) {
                $assignments.Add([pscustomobject]@{ path = $repoPath; groupId = "__registration__"; purpose = "default-fast"; fullPath = $moduleFile })
                continue
            }
            $matches = @($groups | Where-Object {
                $candidate = $_
                @($candidate.modulePaths | Where-Object { Test-VerificationRepoPathPattern -Path $repoPath -Pattern $_ }).Count -gt 0
            })
            if ($matches.Count -gt 1) {
                throw "YAXUNIT_SUITE_MODULE_AMBIGUOUS: '$repoPath' matches groups '$(@($matches.id) -join ', ')'."
            }
            if ($matches.Count -eq 0) {
                $assignments.Add([pscustomobject]@{ path = $repoPath; groupId = "__unclassified__"; purpose = ""; fullPath = $moduleFile })
                $issues.Add("Unclassified YAxUnit module: $repoPath")
            } else {
                $obligation = @($obligations.ToArray() | Where-Object groupId -eq $matches[0].id)[0]
                $assignments.Add([pscustomobject]@{
                    path = $repoPath
                    groupId = [string]$matches[0].id
                    purpose = [string]$matches[0].purpose
                    obligationId = [string]$obligation.id
                    cadence = [string]$obligation.cadence
                    fullPath = $moduleFile
                })
            }
        }
        foreach ($group in @($groups.ToArray())) {
            if (@($assignments.ToArray() | Where-Object groupId -eq $group.id).Count -eq 0) {
                throw "YAXUNIT_SUITE_EMPTY: group '$($group.id)' does not match any current Module.bsl."
            }
        }

        $explicitAssignments = @($assignments.ToArray() | Where-Object purpose -eq "explicit-benchmark")
        foreach ($assignment in $explicitAssignments) {
            if (Test-YAxUnitExecutableScenariosExport -ModulePath ([string]$assignment.path)) {
                $issues.Add("Explicit benchmark module '$($assignment.path)' exports ИсполняемыеСценарии and would join ordinary YAxUnit execution.")
            }
        }
        foreach ($registrationRepoPath in @($registrationPaths)) {
            $registrationFullPath = Resolve-ProjectPath $registrationRepoPath
            if (-not (Test-Path -LiteralPath $registrationFullPath -PathType Leaf)) {
                $issues.Add("YAxUnit registration path does not exist: $registrationRepoPath")
                continue
            }
            $registrationText = Read-Utf8Text -Path $registrationFullPath
            foreach ($assignment in $explicitAssignments) {
                $moduleName = Get-YAxUnitModuleNameFromPath -Path ([string]$assignment.path)
                if (-not $moduleName) {
                    $issues.Add("Explicit benchmark module must use CommonModules/<name>/Ext/Module.bsl: $($assignment.path)")
                    continue
                }
                if (Test-YAxUnitRegistrationReference -ModulePath ([string]$assignment.path) -RegistrationTexts @($registrationText)) {
                    $issues.Add("Explicit benchmark module '$moduleName' is referenced by ordinary registration '$registrationRepoPath'.")
                }
            }
        }

        return [pscustomobject]@{
            available = $true
            valid = $true
            classificationComplete = ($issues.Count -eq 0)
            issues = @($issues.ToArray())
            groups = @($groups.ToArray())
            obligations = @($obligations.ToArray())
            assignments = @($assignments.ToArray())
            registrationPaths = @($registrationPaths)
            notApplicable = @($notApplicable.ToArray())
            catalogPaths = @($catalogPaths)
        }
    } catch {
        return [pscustomobject]@{
            available = $true
            valid = $false
            classificationComplete = $false
            issues = @($_.Exception.Message)
            groups = @()
            obligations = @()
            assignments = @()
            registrationPaths = @($registrationPaths)
            notApplicable = @($notApplicable.ToArray())
            catalogPaths = @($catalogPaths)
        }
    }
}

function Get-YAxUnitPinnedEntry {
    $entry = Get-DependencyLockEntry -Name "yaxunit"
    if ($null -eq $entry) {
        throw "ITL_YAXUNIT_WORKFLOW_PIN_INCOMPLETE: yaxunit is missing from .agent-1c/dependency-lock.json."
    }
    foreach ($field in @("version", "releaseTag", "assetName", "url", "sha256", "upstreamCommit")) {
        if ([string]::IsNullOrWhiteSpace([string](Get-ConfigValueFromObject -Object $entry -Path $field -Default ""))) {
            throw "ITL_YAXUNIT_WORKFLOW_PIN_INCOMPLETE: yaxunit.$field is missing from .agent-1c/dependency-lock.json."
        }
    }
    if ([string]$entry.sha256 -notmatch '^[a-fA-F0-9]{64}$') {
        throw "ITL_YAXUNIT_WORKFLOW_PIN_INCOMPLETE: yaxunit.sha256 is not a SHA-256 value."
    }
    if ([string]$entry.upstreamCommit -notmatch '^[a-fA-F0-9]{40}$') {
        throw "ITL_YAXUNIT_WORKFLOW_PIN_INCOMPLETE: yaxunit.upstreamCommit is not a full Git commit."
    }
    return $entry
}

function Get-YAxUnitArtifactDiagnosticBaseline {
    param([object]$PinnedEntry, [string]$ExtensionName)

    if ($ExtensionName -cne 'YAXUNIT') { return $null }
    $pin = [pscustomobject][ordered]@{
        version = '25.12'
        releaseTag = '25.12'
        assetName = 'YAxUnit-25.12.cfe'
        url = 'https://github.com/bia-technologies/yaxunit/releases/download/25.12/YAxUnit-25.12.cfe'
        sha256 = '805a2277c997a3c24be0b0d080696479e91e4a15ed7e27aaf3991a7346522d70'
        upstreamCommit = '15f7ae557d17b59bd80daad503efd8a3114690e5'
        source = 'upstream release asset'
    }
    foreach ($field in $pin.PSObject.Properties.Name) {
        $value = Get-StateValue -State $PinnedEntry -Name $field -Default $null
        if ($value -isnot [string] -or $value -cne $pin.$field) { return $null }
    }
    return [pscustomobject][ordered]@{
        id = 'yaxunit-25.12-vendor-diagnostics'
        version = 1
        extensionName = 'YAXUNIT'
        pin = $pin
    }
}

function Read-YAxUnitArtifactDiagnosticRaw {
    param([Parameter(Mandatory = $true)][string]$Path)

    $bytes = [IO.File]::ReadAllBytes($Path)
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { $sha256 = [BitConverter]::ToString($hasher.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant() }
    finally { $hasher.Dispose() }
    $original = ([Text.UTF8Encoding]::new($false, $true)).GetString($bytes)
    if ($original.Length -gt 0 -and $original[0] -eq [char]0xFEFF) { $original = $original.Substring(1) }
    if ($original.IndexOf([char]0xFEFF) -ge 0) { throw 'raw output contains an additional BOM' }
    $text = Read-DesignerBatchStrictUtf8Text -Path $Path
    $afterSha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($sha256 -cne $afterSha256 -or $original -cne $text) { throw 'raw output changed while reading' }
    return [pscustomobject]@{ text = $text; sha256 = $sha256 }
}

function Get-YAxUnitArtifactDiagnosticMultiset {
    param([string[]]$Lines)
    $counts = [Collections.Generic.Dictionary[string, int]]::new([StringComparer]::Ordinal)
    foreach ($line in $Lines) {
        if ($counts.ContainsKey($line)) { $counts[$line]++ } else { $counts.Add($line, 1) }
    }
    return @($counts.GetEnumerator() | ForEach-Object { [pscustomobject]@{ text = $_.Key; count = $_.Value } })
}

function Get-YAxUnitArtifactDiagnosticAssessment {
    param([object]$Baseline, [string]$Step, [object]$Verdict, [string]$SourceFingerprint, [string]$ExtensionName)

    $assessment = [pscustomobject][ordered]@{
        status = 'rejected'; applyAllowed = $false; cleanPassed = $false
        baseline = $null; step = $Step; sourceFingerprint = $SourceFingerprint; extensionName = $ExtensionName
        nativePassed = (Get-StateValue -State $Verdict -Name 'passed' -Default $null)
        exitCode = (Get-StateValue -State $Verdict -Name 'exitCode' -Default $null)
        resultCode = (Get-StateValue -State $Verdict -Name 'resultCode' -Default $null)
        raw = [pscustomobject]@{
            logPath = [string](Get-StateValue -State $Verdict -Name 'logPath' -Default '')
            logSha256 = ''; resultPath = [string](Get-StateValue -State $Verdict -Name 'resultPath' -Default '')
            resultSha256 = ''; lines = @(); multiset = @()
        }
        expected = $null; rejectionReason = ''
    }
    try {
        $canonical = Get-YAxUnitArtifactDiagnosticBaseline -PinnedEntry (Get-StateValue -State $Baseline -Name 'pin' -Default $null) -ExtensionName $ExtensionName
        if ($null -eq $canonical) { throw 'unsupported artifact pin or extension name' }
        $assessment.baseline = $canonical
        $baselineVersion = Get-StateValue -State $Baseline -Name 'version' -Default $null
        if ([string](Get-StateValue -State $Baseline -Name 'id' -Default '') -cne $canonical.id -or
            ($baselineVersion -isnot [int] -and $baselineVersion -isnot [long]) -or
            $baselineVersion -ne $canonical.version -or
            [string](Get-StateValue -State $Baseline -Name 'extensionName' -Default '') -cne $canonical.extensionName) {
            throw 'baseline identity was changed'
        }
        if ($SourceFingerprint -cne ('sha256:' + $canonical.pin.sha256)) { throw 'artifact source fingerprint does not match the pin' }
        $expectedExitCode = 0
        if ($Step -ceq 'applicability') {
            $expectedLines = @(
                'YAXUNIT: Не найден метод "ОбработкаОтображенияОшибки", указанный в аннотации метода "ЮТОбработкаОтображенияОшибки".'
                'YAXUNIT: Не найден метод "ErrorDisplayProcessing", указанный в аннотации метода "ЮТErrorDisplayProcessing".'
                'YAXUNIT: Не найден метод "ОбработкаОтображенияОшибки", указанный в аннотации метода "ЮТОбработкаОтображенияОшибки".'
                'YAXUNIT: Не найден метод "ErrorDisplayProcessing", указанный в аннотации метода "ЮТErrorDisplayProcessing".'
            )
        } elseif ($Step -ceq 'configuration') {
            $expectedExitCode = 101
            $expectedLines = @(
                'YAXUNIT Обработка.ЮТПомощникДляСозданияТестовыхДанных.Форма.Форма.Форма Отсутствует обработчик:  СнятьВсеФлажки "СнятьВсеФлажки"'
                'YAXUNIT Обработка.ЮТПомощникДляСозданияТестовыхДанных.Форма.Форма.Форма Отсутствует обработчик:  УстановитьВсеФлажки "УстановитьВсеФлажки"'
            )
        } else { throw 'check step has no vendor diagnostic baseline' }
        $assessment.expected = [pscustomobject]@{
            exitCode = $expectedExitCode; resultCode = $expectedExitCode
            multiset = @(Get-YAxUnitArtifactDiagnosticMultiset -Lines $expectedLines)
        }
        if ($assessment.nativePassed -isnot [bool] -or $assessment.nativePassed) { throw 'vendor diagnostics cannot be a clean native verdict' }
        foreach ($field in @('exitCode', 'resultCode')) {
            $code = $assessment.$field
            if (($code -isnot [int] -and $code -isnot [long]) -or $code -ne $expectedExitCode) { throw "unexpected $field" }
        }
        $assessment.raw.logSha256 = (Get-FileHash -LiteralPath $assessment.raw.logPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        $log = Read-YAxUnitArtifactDiagnosticRaw -Path $assessment.raw.logPath
        $assessment.raw.logSha256 = $log.sha256
        $rawLog = [regex]::Replace($log.text, '\r\n|\r', "`n")
        if ($rawLog.EndsWith("`n")) { $rawLog = $rawLog.Substring(0, $rawLog.Length - 1) }
        $assessment.raw.lines = @($rawLog -split "`n")
        $assessment.raw.multiset = @(Get-YAxUnitArtifactDiagnosticMultiset -Lines $assessment.raw.lines)
        # The pinned CFE also emits this complete applicability profile with
        # its native extension version label. Keep raw bytes and reject mixed
        # labels; this is not diagnostic text normalization or a version regex.
        if ($Step -ceq 'applicability' -and $assessment.raw.lines[0].StartsWith('YAXUNIT (25.12): ', [StringComparison]::Ordinal)) {
            $expectedLines = @($expectedLines | ForEach-Object { 'YAXUNIT (25.12)' + $_.Substring('YAXUNIT'.Length) })
            $assessment.expected.multiset = @(Get-YAxUnitArtifactDiagnosticMultiset -Lines $expectedLines)
        }
        $assessment.raw.resultSha256 = (Get-FileHash -LiteralPath $assessment.raw.resultPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        $result = Read-YAxUnitArtifactDiagnosticRaw -Path $assessment.raw.resultPath
        $assessment.raw.resultSha256 = $result.sha256
        $rawResult = [regex]::Replace($result.text, '\r\n|\r', "`n")
        if ($rawResult.EndsWith("`n")) { $rawResult = $rawResult.Substring(0, $rawResult.Length - 1) }
        if ($rawResult -cne [string]$expectedExitCode) { throw 'raw /DumpResult differs from the required code' }
        if ($assessment.raw.lines.Count -ne $expectedLines.Count -or $assessment.raw.multiset.Count -ne $assessment.expected.multiset.Count) {
            throw 'raw /Out diagnostic multiplicities differ from the baseline'
        }
        foreach ($expected in $assessment.expected.multiset) {
            $matches = @($assessment.raw.multiset | Where-Object { $_.text -ceq $expected.text -and $_.count -eq $expected.count })
            if ($matches.Count -ne 1) { throw 'raw /Out contains changed or unknown diagnostics' }
        }
        $assessment.status = 'vendor-warn'
        $assessment.applyAllowed = $true
    } catch { $assessment.rejectionReason = $_.Exception.Message }
    return $assessment
}

function Get-YAxUnitCfePath {
    $entry = Get-YAxUnitPinnedEntry
    return (Join-Path (Get-YAxUnitInstallRoot) ([string]$entry.assetName))
}

function Install-YAxUnit {
    $entry = Get-YAxUnitPinnedEntry
    $targetPath = Get-YAxUnitCfePath
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $targetPath) | Out-Null
    [void](Invoke-ItlImmutableFileAcquire `
        -Source (ConvertFrom-FileUri -Value ([string]$entry.url)) `
        -DestinationPath $targetPath `
        -ExpectedSha256 ([string]$entry.sha256).ToLowerInvariant() `
        -Label "YAxUnit CFE")
    Write-Host "YAxUnit $($entry.version) is ready: $targetPath"
    return $targetPath
}

function Ensure-YAxUnitForInit {
    Write-Host "YAxUnit is required for algorithmic unit tests; installing the workflow-pinned build automatically."
    return (Install-YAxUnit)
}

function Test-YAxUnitSuitePresent {
    $path = Resolve-ProjectPath (Get-YAxUnitTestsPath)
    if (-not (Test-Path -LiteralPath $path -ErrorAction SilentlyContinue)) {
        return $false
    }
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        throw "ITL_YAXUNIT_TEST_SOURCE_INVALID: YAXUNIT_TESTS_PATH must point to a hierarchical extension source directory: $path"
    }
    $configurationPath = Join-Path $path "Configuration.xml"
    if (-not (Test-Path -LiteralPath $configurationPath -PathType Leaf)) {
        throw "ITL_YAXUNIT_TEST_SOURCE_INVALID: Configuration.xml was not found in the test extension source: $path"
    }
    return $true
}

function Get-YAxUnitJunitSummary {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "ITL_YAXUNIT_REPORT_MISSING: JUnit report was not created: $Path"
    }
    $document = New-Object System.Xml.XmlDocument
    $document.Load($Path)
    $suites = @($document.SelectNodes("/*[local-name()='testsuites']/*[local-name()='testsuite'] | /*[local-name()='testsuite']"))
    if ($suites.Count -eq 0) {
        throw "ITL_YAXUNIT_REPORT_INVALID: JUnit report contains no test suites: $Path"
    }
    $tests = 0
    $failures = 0
    $errors = 0
    $skipped = 0
    foreach ($suite in $suites) {
        $tests += ConvertTo-IntOrDefault -Value $suite.GetAttribute("tests")
        $failures += ConvertTo-IntOrDefault -Value $suite.GetAttribute("failures")
        $errors += ConvertTo-IntOrDefault -Value $suite.GetAttribute("errors")
        $skipped += ConvertTo-IntOrDefault -Value $suite.GetAttribute("skipped")
    }
    if ($tests -le 0) {
        throw "ITL_YAXUNIT_ZERO_TESTS: YAxUnit produced a report but executed no tests: $Path"
    }
    return [pscustomobject][ordered]@{
        tests = $tests
        failures = $failures
        errors = $errors
        skipped = $skipped
        passed = ($failures -eq 0 -and $errors -eq 0)
    }
}

function Ensure-YAxUnitExtensions {
    param([object]$State)
    $State = Ensure-DevBranchToolingGeneration -State $State
    $extensionName = Get-YAxUnitExtensionName
    $testsExtensionName = Get-YAxUnitTestsExtensionName
    $testsPath = Resolve-ProjectPath (Get-YAxUnitTestsPath)
    [xml]$metadata = Read-Utf8Text -Path (Join-Path $testsPath "Configuration.xml")
    $nameNode = $metadata.SelectSingleNode("/*[local-name()='MetaDataObject']/*[local-name()='Configuration']/*[local-name()='Properties']/*[local-name()='Name']")
    if ($null -eq $nameNode -or $nameNode.InnerText -cne $testsExtensionName) {
        throw "ITL_YAXUNIT_TEST_EXTENSION_NAME_MISMATCH: configure yaxunit.testsExtensionName to match Configuration.xml before loading tests."
    }
    $source = Get-ConfigSourceFingerprint -ExportPath (Get-YAxUnitTestsPath)
    $entry = Get-YAxUnitPinnedEntry
    $cfePath = Install-YAxUnit
    $identity = Get-OneCInfoBaseIdentity -InfoBaseKind $State.infoBaseKind -InfoBasePath $State.devBranchInfoBasePath
    $proof = Get-StateValue $State "yaxunitInstallationProof" $null
    $runtime = @(Get-ToolingRuntimeExtensions -State $State -Names @($extensionName, $testsExtensionName))
    $engine = @($runtime | Where-Object { $_.name -ceq $extensionName }) | Select-Object -First 1
    $tests = @($runtime | Where-Object { $_.name -ceq $testsExtensionName }) | Select-Object -First 1
    $scopeMatches = $null -ne $proof -and (Get-StateValue $proof "schemaVersion" 0) -eq 1 -and
        [bool][string](Get-StateValue $proof "engineRuntimeHash" "") -and [bool][string](Get-StateValue $proof "testsRuntimeHash" "") -and
        [string](Get-StateValue $proof "engineName" "") -ceq $extensionName -and [string](Get-StateValue $proof "testsName" "") -ceq $testsExtensionName -and
        [string](Get-StateValue $proof "generation" "") -ceq [string]$State.toolingInfoBaseGeneration -and
        [string](Get-StateValue $proof "infoBaseKey" "") -ceq [string]$identity.key
    $engineMatches = $scopeMatches -and [string](Get-StateValue $proof "engineSha256" "") -ceq [string]$entry.sha256 -and
        (Test-ToolingRuntimeExtensionReady -Runtime $engine -Name $extensionName -ExpectedHash ([string](Get-StateValue $proof "engineRuntimeHash" "")) -RequireUnsafeMode -RequireUnsafeActionProtectionDisabled)
    $testsMatch = $scopeMatches -and [string](Get-StateValue $proof "testsFingerprint" "") -ceq [string]$source.fingerprint -and
        (Test-ToolingRuntimeExtensionReady -Runtime $tests -Name $testsExtensionName -ExpectedHash ([string](Get-StateValue $proof "testsRuntimeHash" "")))
    if ($engineMatches -and $testsMatch) { return $State }

    Stop-DevBranchRuntimeBeforeInfobaseMutation -State $State -Reason "YAxUnit extension synchronization"
    Update-DevBranchState -State $State -Updates @{ yaxunitInstallationProof = $null }
    $State | Add-Member -NotePropertyName yaxunitInstallationProof -NotePropertyValue $null -Force
    if (-not $engineMatches) {
        Invoke-GuardedCfeExtensionApply -InfoBasePath $State.devBranchInfoBasePath -InfoBaseKind $State.infoBaseKind `
            -CfePath $cfePath -ExtensionName $extensionName `
            -ArtifactDiagnosticBaseline (Get-YAxUnitArtifactDiagnosticBaseline -PinnedEntry $entry -ExtensionName $extensionName) | Out-Null
        Install-ItlOnDemandMcp | Out-Null
        [void](Set-VanessaMcpExtensionUnsafeMode -State $State -InfoBaseKind $State.infoBaseKind -InfoBasePath $State.devBranchInfoBasePath `
            -ExtensionName $extensionName -Artifact ([pscustomobject]@{ sha256 = [string]$entry.sha256 }) `
            -User ([string](Get-EnvValue -Name "IB_USER")) -Password ([string](Get-EnvValue -Name "IB_PASSWORD")) -Scope "yaxunit" -ReconcileYAxUnitProtections)
    }
    if (-not $testsMatch) {
        Invoke-ConfigLoadDesignerAttempt -InfoBasePath $State.devBranchInfoBasePath -InfoBaseKind $State.infoBaseKind `
            -ExtensionName $testsExtensionName -SourceFingerprint $source.fingerprint `
            -DesignerArgs @("/LoadConfigFromFiles", $testsPath, "-Extension", $testsExtensionName, "-Format", "Hierarchical", "/UpdateDBCfg") | Out-Null
    }
    $runtime = @(Get-ToolingRuntimeExtensions -State $State -Names @($extensionName, $testsExtensionName))
    $engine = @($runtime | Where-Object { $_.name -ceq $extensionName }) | Select-Object -First 1
    $tests = @($runtime | Where-Object { $_.name -ceq $testsExtensionName }) | Select-Object -First 1
    Assert-ToolingRuntimeExtensionReady -Runtime $engine -Name $extensionName -RequireUnsafeMode -RequireUnsafeActionProtectionDisabled
    Assert-ToolingRuntimeExtensionReady -Runtime $tests -Name $testsExtensionName
    Update-DevBranchState -State $State -Updates @{
        yaxunitInstallationProof = [pscustomobject]@{
            schemaVersion = 1; generation = [string]$State.toolingInfoBaseGeneration; infoBaseKey = [string]$identity.key
            engineName = $extensionName; testsName = $testsExtensionName
            engineSha256 = [string]$entry.sha256; engineRuntimeHash = [string]$engine.contentHash
            testsFingerprint = [string]$source.fingerprint; testsRuntimeHash = [string]$tests.contentHash; verifiedAt = (Get-Date).ToString("o")
        }
        toolingMutationId = [guid]::NewGuid().ToString("N")
        toolingMutationAt = (Get-Date).ToString("o")
    }
    return Read-DevBranchState -Name ([string]$State.devBranchName)
}

function Invoke-YAxUnitVerification {
    param([Parameter(Mandatory = $true)][object]$State)

    if (-not (Test-YAxUnitSuitePresent)) {
        $baseline = Get-StateValue -State $State -Name "yaxunitApplicabilityBaseline" -Default $null
        $legacy = [bool](Get-StateValue -State $baseline -Name "legacy" -Default $false)
        $reason = if ($legacy) {
            "The pre-upgrade branch state has no YAxUnit coverage; the managed legacy baseline is preserved. No new branch-owned BSL lacks an applicability decision."
        } else {
            "No YAxUnit suite is required by the classified branch-owned BSL changes."
        }
        Update-DevBranchState -State $State -Updates @{
            lastYAxUnitStatus = "not-applicable"
            lastYAxUnitReason = $reason
            lastYAxUnitTestAt = (Get-Date).ToString("o")
        }
        Write-Host "YAxUnit verification: not applicable; $(Get-YAxUnitTestsPath) is absent. $reason"
        return [pscustomobject]@{ status = "not-applicable"; tests = 0 }
    }

    $runDirectory = Join-Path (Get-YAxUnitReportsPath) ("run-" + (Get-Date).ToString("yyyyMMdd-HHmmss-fff"))
    New-Item -ItemType Directory -Force -Path $runDirectory | Out-Null
    $reportPath = Join-Path $runDirectory "junit.xml"
    $exitCodePath = Join-Path $runDirectory "exit-code.txt"
    $yaxunitLogPath = Join-Path $runDirectory "yaxunit.log"
    $configPath = Join-Path $runDirectory "config.json"
    $testsPath = Resolve-ProjectPath (Get-YAxUnitTestsPath)
    $extensionName = Get-YAxUnitExtensionName
    $testsExtensionName = Get-YAxUnitTestsExtensionName
    $entry = Get-YAxUnitPinnedEntry

    try {
        $State = Ensure-YAxUnitExtensions -State $State

        $config = [ordered]@{
            filter = [ordered]@{ extensions = @($testsExtensionName) }
            reportFormat = "jUnit"
            reportPath = $reportPath
            closeAfterTests = $true
            showReport = $false
            exitCode = $exitCodePath
            projectPath = $script:ProjectRoot
            workspacePath = $script:ProjectRoot
            logging = [ordered]@{ file = $yaxunitLogPath; level = "debug"; console = $false }
        }
        Write-Utf8TextAtomic -Path $configPath -Value (($config | ConvertTo-Json -Depth 10) + [Environment]::NewLine)
        $timeoutSeconds = ConvertTo-IntOrDefault -Value (Get-EnvValue -Name "YAXUNIT_TEST_TIMEOUT_SECONDS" -Default 1800) -Default 1800
        Set-RunStage -Stage "yaxunit.run" -Detail "Running YAxUnit verification."
        Invoke-Enterprise `
            -InfoBasePath ([string]$State.devBranchInfoBasePath) `
            -InfoBaseKind ([string]$State.infoBaseKind) `
            -EnterpriseArgs @("/C", "RunUnitTests=$configPath") `
            -TimeoutSeconds $timeoutSeconds | Out-Null

        Set-RunStage -Stage "yaxunit.postprocess" -Detail "Reading YAxUnit verification evidence."
        $summary = Get-YAxUnitJunitSummary -Path $reportPath
        if (-not $summary.passed) {
            throw "ITL_YAXUNIT_TESTS_FAILED: tests=$($summary.tests), failures=$($summary.failures), errors=$($summary.errors). Report: $reportPath"
        }
        $runnerExitCode = ""
        if (Test-Path -LiteralPath $exitCodePath -PathType Leaf) {
            $runnerExitCode = ([string](Read-Utf8Text -Path $exitCodePath)).Trim()
            if ($runnerExitCode -and $runnerExitCode -ne "0") {
                Write-Host "[WARN] YAxUnit exit-code file says '$runnerExitCode', while the authoritative JUnit report passed."
            }
        }
        $passedUpdates = @{
            lastYAxUnitStatus = "passed"
            lastYAxUnitReason = "JUnit report passed."
            lastYAxUnitTestAt = (Get-Date).ToString("o")
            lastYAxUnitReportPath = $reportPath
            lastYAxUnitLogPath = $yaxunitLogPath
            lastYAxUnitTests = $summary.tests
            lastYAxUnitFailures = $summary.failures
            lastYAxUnitErrors = $summary.errors
            lastYAxUnitSkipped = $summary.skipped
            lastYAxUnitRunnerExitCode = $runnerExitCode
            lastYAxUnitVersion = [string]$entry.version
            lastYAxUnitArtifactSha256 = ([string]$entry.sha256).ToLowerInvariant()
        }
        Add-VerificationComponentEvidenceUpdates -Updates $passedUpdates -State $State -Component 'yaxunit' -Status 'passed' -ArtifactPaths @($reportPath)
        Update-DevBranchState -State $State -Updates $passedUpdates
        Write-Host "YAxUnit verification passed: tests=$($summary.tests), skipped=$($summary.skipped). Report: $reportPath"
        return [pscustomobject]@{ status = "passed"; tests = $summary.tests; reportPath = $reportPath }
    } catch {
        $failure = $_
        try { $failedUpdates = @{
            lastYAxUnitStatus = "failed"
            lastYAxUnitReason = $failure.Exception.Message
            lastYAxUnitTestAt = (Get-Date).ToString("o")
            lastYAxUnitReportPath = $reportPath
            lastYAxUnitLogPath = $yaxunitLogPath
        }
        Add-VerificationComponentEvidenceUpdates -Updates $failedUpdates -State $State -Component 'yaxunit' -Status 'failed'
        Update-DevBranchState -State $State -Updates $failedUpdates
        } catch { Write-Warning "Could not persist YAxUnit failure state: $($_.Exception.Message)" }
        Set-RunFailureContextFromMessage -Message $failure.Exception.Message -RequestedAction "check-dev-branch"
        if (-not $script:RunRequiredAction) { Set-RunFailureContext -RequiredAction "/itl-verify-fix" }
        throw $failure
    }
}

function Write-YAxUnitStatusLines {
    param([object]$State, [string]$Indent = "")

    $status = [string](Get-StateValue -State $State -Name "lastYAxUnitStatus" -Default "")
    if (-not $status) { return }
    Write-Host "${Indent}Last YAxUnit status/tests: $status / $(Get-StateValue -State $State -Name 'lastYAxUnitTests' -Default 0)"
    $reportPath = [string](Get-StateValue -State $State -Name "lastYAxUnitReportPath" -Default "")
    if ($reportPath) { Write-Host "${Indent}Last YAxUnit report: $reportPath" }
}
