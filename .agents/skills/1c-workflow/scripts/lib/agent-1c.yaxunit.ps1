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
        $cfePath = Install-YAxUnit
        Stop-DevBranchRuntimeBeforeInfobaseMutation -State $State -Reason "YAxUnit extension synchronization"
        Invoke-Designer `
            -InfoBasePath ([string]$State.devBranchInfoBasePath) `
            -InfoBaseKind ([string]$State.infoBaseKind) `
            -DesignerArgs @("/LoadCfg", $cfePath, "-Extension", $extensionName, "/UpdateDBCfg") | Out-Null
        Invoke-Designer `
            -InfoBasePath ([string]$State.devBranchInfoBasePath) `
            -InfoBaseKind ([string]$State.infoBaseKind) `
            -DesignerArgs @("/LoadConfigFromFiles", $testsPath, "-Extension", $testsExtensionName, "-Format", "Hierarchical", "/UpdateDBCfg") | Out-Null
        Install-ItlOnDemandMcp | Out-Null
        $artifact = [pscustomobject]@{ sha256 = ([string]$entry.sha256).ToLowerInvariant() }
        [void](Set-VanessaMcpExtensionUnsafeMode `
            -State $State `
            -InfoBaseKind ([string]$State.infoBaseKind) `
            -InfoBasePath ([string]$State.devBranchInfoBasePath) `
            -ExtensionName $extensionName `
            -Artifact $artifact `
            -User ([string](Get-EnvValue -Name "IB_USER" -Default "")) `
            -Password ([string](Get-EnvValue -Name "IB_PASSWORD" -Default "")) `
            -Scope "yaxunit" `
            -ReconcileYAxUnitProtections)

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
        Update-DevBranchState -State $State -Updates @{
            lastYAxUnitStatus = "failed"
            lastYAxUnitReason = $_.Exception.Message
            lastYAxUnitTestAt = (Get-Date).ToString("o")
            lastYAxUnitReportPath = $reportPath
            lastYAxUnitLogPath = $yaxunitLogPath
        }
        Set-RunFailureContext -Category "yaxunit" -RequiredAction "/itl-verify-fix"
        throw
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
