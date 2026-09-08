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
            assignments = $assignments
            registrationPaths = @()
            catalogPaths = @()
        }
    }

    $groupIds = New-Object "System.Collections.Generic.HashSet[string]" ([System.StringComparer]::OrdinalIgnoreCase)
    $groups = New-Object System.Collections.Generic.List[object]
    $registrationPaths = New-Object "System.Collections.Generic.HashSet[string]" ([System.StringComparer]::OrdinalIgnoreCase)
    try {
        foreach ($catalogPath in $catalogPaths) {
            $catalog = (Read-Utf8Text -Path $catalogPath) | ConvertFrom-Json
            if ([int](Get-YAxUnitCatalogValue -Value $catalog -Name "schemaVersion" -Default 0) -ne 1) {
                throw "YAXUNIT_SUITE_SCHEMA_UNSUPPORTED: '$catalogPath' must use schemaVersion=1."
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
                $groups.Add([pscustomobject][ordered]@{
                    id = $id
                    purpose = $purpose
                    modulePaths = $modulePatterns
                    ownerPaths = $ownerPatterns
                    source = Get-VerificationRepoRelativePath -Path $catalogPath
                })
            }
        }

        $assignments = New-Object System.Collections.Generic.List[object]
        $issues = New-Object System.Collections.Generic.List[string]
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
                $assignments.Add([pscustomobject]@{ path = $repoPath; groupId = [string]$matches[0].id; purpose = [string]$matches[0].purpose; fullPath = $moduleFile })
            }
        }
        foreach ($group in @($groups.ToArray())) {
            if (@($assignments.ToArray() | Where-Object groupId -eq $group.id).Count -eq 0) {
                throw "YAXUNIT_SUITE_EMPTY: group '$($group.id)' does not match any current Module.bsl."
            }
        }

        $explicitAssignments = @($assignments.ToArray() | Where-Object purpose -eq "explicit-benchmark")
        if ($explicitAssignments.Count -gt 0 -and $registrationPaths.Count -eq 0) {
            $issues.Add("Explicit benchmark groups require registrationPaths so ordinary YAxUnit registration can be checked.")
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
                if ($moduleName -and $registrationText.IndexOf($moduleName, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
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
            assignments = @($assignments.ToArray())
            registrationPaths = @($registrationPaths)
            catalogPaths = @($catalogPaths)
        }
    } catch {
        return [pscustomobject]@{
            available = $true
            valid = $false
            classificationComplete = $false
            issues = @($_.Exception.Message)
            groups = @()
            assignments = @()
            registrationPaths = @($registrationPaths)
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
        Invoke-Designer -InfoBasePath $State.devBranchInfoBasePath -InfoBaseKind $State.infoBaseKind `
            -DesignerArgs @("/LoadCfg", $cfePath, "-Extension", $extensionName, "/UpdateDBCfg") | Out-Null
        Install-ItlOnDemandMcp | Out-Null
        [void](Set-VanessaMcpExtensionUnsafeMode -State $State -InfoBaseKind $State.infoBaseKind -InfoBasePath $State.devBranchInfoBasePath `
            -ExtensionName $extensionName -Artifact ([pscustomobject]@{ sha256 = [string]$entry.sha256 }) `
            -User ([string](Get-EnvValue -Name "IB_USER")) -Password ([string](Get-EnvValue -Name "IB_PASSWORD")) -Scope "yaxunit" -ReconcileYAxUnitProtections)
    }
    if (-not $testsMatch) {
        Invoke-Designer -InfoBasePath $State.devBranchInfoBasePath -InfoBaseKind $State.infoBaseKind `
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
        Update-DevBranchState -State $State -Updates @{
            lastYAxUnitStatus = "not-applicable"
            lastYAxUnitReason = "No hierarchical test extension exists at $(Get-YAxUnitTestsPath)."
            lastYAxUnitTestAt = (Get-Date).ToString("o")
        }
        Write-Host "YAxUnit verification: not applicable; $(Get-YAxUnitTestsPath) is absent."
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
        Invoke-Enterprise `
            -InfoBasePath ([string]$State.devBranchInfoBasePath) `
            -InfoBaseKind ([string]$State.infoBaseKind) `
            -EnterpriseArgs @("/C", "RunUnitTests=$configPath") `
            -TimeoutSeconds $timeoutSeconds | Out-Null

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
        Update-DevBranchState -State $State -Updates @{
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
        Write-Host "YAxUnit verification passed: tests=$($summary.tests), skipped=$($summary.skipped). Report: $reportPath"
        return [pscustomobject]@{ status = "passed"; tests = $summary.tests; reportPath = $reportPath }
    } catch {
        $failure = $_
        try { Update-DevBranchState -State $State -Updates @{
            lastYAxUnitStatus = "failed"
            lastYAxUnitReason = $failure.Exception.Message
            lastYAxUnitTestAt = (Get-Date).ToString("o")
            lastYAxUnitReportPath = $reportPath
            lastYAxUnitLogPath = $yaxunitLogPath
        } } catch { Write-Warning "Could not persist YAxUnit failure state: $($_.Exception.Message)" }
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
