BeforeAll {
    . (Join-Path $PSScriptRoot "TestSupport.ps1")
    $context = Initialize-WorkflowPesterContext
    $RepoRoot = $context.RepoRoot
}

Describe "Release gate scripts" {
    It "parses the local gate and E2E runner" {
        foreach ($relativePath in @("scripts\check.ps1", "scripts\invoke-release-e2e.ps1")) {
            $tokens = $null
            $errors = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile(
                (Join-Path $RepoRoot $relativePath),
                [ref]$tokens,
                [ref]$errors
            )
            @($errors) | Should -BeNullOrEmpty
        }
        $e2eText = Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\invoke-release-e2e.ps1") -Raw -Encoding UTF8
        $e2eText | Should -Match "FromBase64String"
        $e2eText | Should -Not -Match "Функционал: Четыре независимых"
        $e2eText | Should -Match '"-VanessaFeaturePath", \$vanessaFixture\.path'
        ([regex]::Matches($e2eText, 'Invoke-E2EHelper -Action "check-dev-branch"')).Count | Should -Be 3
        $e2eText | Should -Match 'RELEASE_E2E_RESUME_STATE_MISMATCH'
        $e2eText | Should -Match 'Restore-E2EInfobaseSnapshot'
        $e2eText | Should -Match 'runnerSha256'
        $e2eText | Should -Match 'workflowTree'
        $e2eText | Should -Match 'Register-E2EGeneratedCommit'
        $e2eText | Should -Match 'Sync-E2EWorktreeFromMaster'
        $e2eText | Should -Match 'Invoke-E2EHelper -Action "refresh-dev-branch"'
        $e2eText | Should -Match ([regex]::Escape('.agent-1c\runs\release-e2e'))
        (Get-Content -LiteralPath (Join-Path $RepoRoot "templates\gitignore.append") -Raw -Encoding UTF8) | Should -Match ([regex]::Escape('.agent-1c/runs/'))
        $lifecycleText = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.lifecycle.ps1") -Raw -Encoding UTF8
        $lifecycleText | Should -Match '1c-form-scaffold\\scripts\\form-add\.ps1'
        $lifecycleText | Should -Match '1c-template-manage\\scripts\\add-template\.ps1'
        $lifecycleText | Should -Match 'formContentPreserved'
        $lifecycleText | Should -Match 'explicitMetadataUpdatesPassed'
        $lifecycleText | Should -Match 'SetMainSKD'
        $lifecycleText | Should -Match 'Run-DevBranchTests'
        $lifecycleText | Should -Match 'extensionUiTestClientPassed'
        $lifecycleText | Should -Match '(?s)Restore-ReleaseE2EExtensionLocalState\s+if \(Test-Path -LiteralPath \$smokeRoot.*?Remove-Item -LiteralPath \$smokeRoot -Recurse -Force\s+}\s+\s*if \(@\(& git -C \$script:ProjectRoot status --porcelain\)\.Count -ne 0\)'
    }

    It "requires the lock-pinned annotated fork tag and explicit E2E stand" {
        $text = Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\check.ps1") -Raw -Encoding UTF8
        $text | Should -Match 'Pinned fork tag must exist locally and be annotated'
        $text | Should -Match 'release/\$tag'
        $text | Should -Match 'Release mode requires -E2EProjectRoot'
        $text | Should -Match 'Get-CanonicalTextSha256 -Path \$catalogPath'
        $text | Should -Match 'compatibilityStatus'
        $text | Should -Match 'release-e2e-summary.json'
        $text | Should -Match '\$releaseHelperPath'
        $text | Should -Match '"-HelperPath", \$releaseHelperPath'
        $text | Should -Match '"-AiRulesSource", \$releaseRulesSource'
        $text | Should -Match 'Release E2E summary reports'
        $text | Should -Match '\[Console\]::Error\.WriteLine\(\$failure\)'
        $runnerText = Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\invoke-release-e2e.ps1") -Raw -Encoding UTF8
        $runnerText | Should -Match 'SOURCE_INFOBASE_PATH must be a disposable snapshot inside the stand'
        $runnerText | Should -Match '\[Console\]::Error\.WriteLine\(\$failure\)'
        (Get-Content -LiteralPath (Join-Path $RepoRoot "docs\release-checklist.md") -Raw -Encoding UTF8) | Should -Match 'source-snapshot'
    }
}

Describe "Release E2E orchestration" {
    It "runs config and extension roundtrips, fresh verification, export, hash validation, and MCP cleanup" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-release-e2e-test-" + [guid]::NewGuid().ToString("N"))
        $mainRoot = Join-Path $tempRoot "main"
        $worktreeRoot = Join-Path $tempRoot "worktree"
        $helperPath = Join-Path $tempRoot "fake-helper.ps1"
        $aiRulesRoot = Join-Path $tempRoot "ai-rules"
        $summaryPath = Join-Path $tempRoot "release-summary.json"
        $oldOnDemandFixture = $env:ITL_TEST_RELEASE_ONDEMAND_PROBE
        $env:ITL_TEST_RELEASE_ONDEMAND_PROBE = "true"
        try {
            New-Item -ItemType Directory -Force -Path $mainRoot, $aiRulesRoot | Out-Null
            & git -C $aiRulesRoot init *> $null
            & git -C $aiRulesRoot config user.email "test@example.invalid"
            & git -C $aiRulesRoot config user.name "ITL Test"
            Set-Content -LiteralPath (Join-Path $aiRulesRoot "README.md") -Encoding ASCII -Value "controlled fork fixture"
            & git -C $aiRulesRoot add .
            & git -C $aiRulesRoot commit -m "fixture" *> $null
            & git -C $mainRoot init *> $null
            & git -C $mainRoot config user.email "test@example.invalid"
            & git -C $mainRoot config user.name "ITL Test"
            Set-Content -LiteralPath (Join-Path $mainRoot ".gitignore") -Encoding ASCII -Value ".agent-1c/dev-branches/`n.agent-1c/runs/`n.agent-1c/release-e2e-actions.log`n.agent-1c/release-e2e-partial-list.txt`nbuild/`n"
            Set-Content -LiteralPath (Join-Path $mainRoot "README.md") -Encoding ASCII -Value "fixture"
            New-Item -ItemType Directory -Force -Path (Join-Path $mainRoot "src\cf\Ext") | Out-Null
            Set-Content -LiteralPath (Join-Path $mainRoot "src\cf\Configuration.xml") -Encoding UTF8 -Value @'
<?xml version="1.0" encoding="UTF-8"?>
<MetaDataObject>
  <Configuration>
    <Properties><Comment>fixture</Comment></Properties>
  </Configuration>
</MetaDataObject>
'@
            Set-Content -LiteralPath (Join-Path $mainRoot "src\cf\Ext\ParentConfigurations.bin") -Encoding Byte -Value ([byte[]](1, 2, 3, 4))
            & git -C $mainRoot add .
            & git -C $mainRoot commit -m "fixture" *> $null
            & git -C $mainRoot branch -M master
            $previousPreference = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
            try {
                & git -C $mainRoot worktree add -b "itldev/workflow-release-e2e" $worktreeRoot *> $null
                $worktreeExit = $LASTEXITCODE
            } finally {
                $ErrorActionPreference = $previousPreference
            }
            $worktreeExit | Should -Be 0

            $sourceSnapshot = Join-Path $mainRoot ".agent-1c\infobases\source-snapshot"
            New-Item -ItemType Directory -Force -Path $sourceSnapshot, (Join-Path $worktreeRoot ".agent-1c\dev-branches") | Out-Null
            Set-Content -LiteralPath (Join-Path $sourceSnapshot "1Cv8.1CD") -Encoding ASCII -Value "fixture infobase"
            Set-Content -LiteralPath (Join-Path $mainRoot ".dev.env") -Encoding UTF8 -Value "SOURCE_INFOBASE_PATH=$sourceSnapshot"
            $config = [ordered]@{ schemaVersion = 1; devBranchName = "workflow-release-e2e"; worktreePath = $worktreeRoot }
            Set-Content -LiteralPath (Join-Path $mainRoot ".agent-1c\release-e2e.json") -Encoding UTF8 -Value ($config | ConvertTo-Json)
            $state = [ordered]@{
                devBranchName = "workflow-release-e2e"
                devBranch = "itldev/workflow-release-e2e"
                worktreePath = $worktreeRoot
                lastVerificationStatus = "missing"
            }
            Set-Content -LiteralPath (Join-Path $worktreeRoot ".agent-1c\dev-branches\workflow-release-e2e.json") -Encoding UTF8 -Value ($state | ConvertTo-Json -Depth 6)
            Set-Content -LiteralPath $helperPath -Encoding UTF8 -Value @'
[CmdletBinding()]
param([string]$ProjectRoot, [string]$Action, [string]$DevBranchName, [string]$ExtensionName, [string]$ReleaseAiRulesSource, [string]$VanessaFeaturePath, [string]$VanessaFilterTags, [string]$ReleaseSnapshotPath, [ValidateSet("Auto", "Partial", "Full")][string]$ConfigLoadMode = "Auto", [string]$InternalOnDemandOperation, [string]$InternalOnDemandFamily)
$actionLogPath = Join-Path $ProjectRoot ".agent-1c\release-e2e-actions.log"
Add-Content -LiteralPath $actionLogPath -Encoding UTF8 -Value $Action
if ($InternalOnDemandOperation -eq "stop-all") {
    Add-Content -LiteralPath $actionLogPath -Encoding UTF8 -Value "ondemand-stop-all:$InternalOnDemandFamily"
    exit 0
}
$statePath = Join-Path $ProjectRoot ".agent-1c\dev-branches\workflow-release-e2e.json"
$state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
switch ($Action) {
    "check-dev-branch" {
        $firstRun = -not $state.PSObject.Properties["lastConfigDesignerLoadedAt"]
        $previousCheckCount = if ($state.PSObject.Properties["releaseCheckCount"]) { [int]$state.releaseCheckCount } else { 0 }
        $releaseCheckCount = $previousCheckCount + 1
        $isStopOnErrorProbe = ($releaseCheckCount -eq 2)
        if ($firstRun -and $ConfigLoadMode -ne "Partial") { throw "first release E2E check must request Partial" }
        if ($VanessaFilterTags -ne "@itl_release_flat") { throw "release E2E must filter the four flat scenarios" }
        if ([System.IO.Path]::GetFileName($VanessaFeaturePath) -ne "ITLReleaseFourFlat.feature") { throw "release E2E must run the dedicated four-scenario feature file" }
        $listPath = Join-Path $ProjectRoot ".agent-1c\release-e2e-partial-list.txt"
        Set-Content -LiteralPath $listPath -Encoding UTF8 -Value "Configuration.xml"
        $reportPath = Join-Path $ProjectRoot "build\test-results\vanessa\mock"
        New-Item -ItemType Directory -Force -Path $reportPath | Out-Null
        $failureCount = if ($isStopOnErrorProbe) { 1 } else { 0 }
        Set-Content -LiteralPath (Join-Path $reportPath "junit.xml") -Encoding UTF8 -Value "<testsuite tests=`"4`" failures=`"$failureCount`" errors=`"0`"><testcase name=`"one`"/><testcase name=`"two`"/><testcase name=`"three`"/><testcase name=`"four`"/></testsuite>"
        $state | Add-Member -NotePropertyName configLoadStatus -NotePropertyValue "passed" -Force
        $state | Add-Member -NotePropertyName lastConfigLoadMode -NotePropertyValue "partial" -Force
        $state | Add-Member -NotePropertyName lastConfigBaseUpdateListFile -NotePropertyValue $listPath -Force
        $metadataChanged = $releaseCheckCount -in @(1, 3)
        $designerLoadedAt = if ($releaseCheckCount -eq 3) { "2026-07-14T00:00:03Z" } else { "2026-07-14T00:00:01Z" }
        $state | Add-Member -NotePropertyName lastConfigDesignerLoadedAt -NotePropertyValue $designerLoadedAt -Force
        $state | Add-Member -NotePropertyName designerInvoked -NotePropertyValue ([bool]$metadataChanged) -Force
        $state | Add-Member -NotePropertyName enterpriseInvoked -NotePropertyValue ([bool]$metadataChanged) -Force
        $state | Add-Member -NotePropertyName lastVanessaReportPath -NotePropertyValue $reportPath -Force
        $state | Add-Member -NotePropertyName lastVanessaPostProcessDurationMs -NotePropertyValue 25 -Force
        $state | Add-Member -NotePropertyName releaseCheckCount -NotePropertyValue $releaseCheckCount -Force
        $state | Add-Member -NotePropertyName lastVerificationStatus -NotePropertyValue "passed" -Force
        $state | Add-Member -NotePropertyName lastVerifiedAt -NotePropertyValue ([DateTime]::UtcNow.ToString("o")) -Force
        $state | Add-Member -NotePropertyName lastVerifiedCommit -NotePropertyValue ((& git -C $ProjectRoot rev-parse HEAD).Trim()) -Force
        Set-Content -LiteralPath $statePath -Encoding UTF8 -Value ($state | ConvertTo-Json -Depth 8)
        if ($isStopOnErrorProbe) { [Environment]::Exit(1) }
    }
    "release-e2e-snapshot" {
        $snapshotPath = Join-Path $ProjectRoot $ReleaseSnapshotPath
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $snapshotPath) | Out-Null
        Set-Content -LiteralPath $snapshotPath -Encoding ASCII -Value "mock infobase snapshot"
    }
    "release-e2e-restore" {
        $snapshotPath = Join-Path $ProjectRoot $ReleaseSnapshotPath
        if (-not (Test-Path -LiteralPath $snapshotPath -PathType Leaf)) { throw "mock snapshot is missing" }
    }
    "release-e2e-config-roundtrip" {
        [xml]$configuration = Get-Content -LiteralPath (Join-Path $ProjectRoot "src\cf\Configuration.xml") -Raw -Encoding UTF8
        $comment = [string]$configuration.MetaDataObject.Configuration.Properties.Comment
        $evidence = [ordered]@{
            schemaVersion = 2
            actualComment = $comment
            expectedComment = $comment
            parentConfigurationsPresentInDump = (Test-Path -LiteralPath (Join-Path $ProjectRoot "src\cf\Ext\ParentConfigurations.bin") -PathType Leaf)
        }
        $evidencePath = Join-Path $ProjectRoot "build\test-results\release-e2e\config-roundtrip.json"
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $evidencePath) | Out-Null
        Set-Content -LiteralPath $evidencePath -Encoding UTF8 -Value ($evidence | ConvertTo-Json -Depth 5)
    }
    "release-e2e-extension-smoke" {
        if ($env:ITL_TEST_FAIL_RELEASE_EXTENSION -eq "true") {
            [Console]::Error.WriteLine("simulated extension smoke failure")
            exit 1
        }
        $evidence = [ordered]@{
            schemaVersion = 2
            extensionName = $ExtensionName
            emptyInitialized = $true
            cfeCreated = $true
            cfeInitialized = $true
            databaseRestored = $true
            repeatedFormOperationsIdempotent = $true
            repeatedTemplateOperationsIdempotent = $true
            formContentPreserved = $true
            formModulePreserved = $true
            templateContentPreserved = $true
            explicitMetadataUpdatesPassed = $true
            formRegistrationCount = 1
            templateRegistrationCount = 1
            extensionUiTestClientPassed = $true
            extensionUiJunitTests = 1
            extensionUiReportPath = (Join-Path $ProjectRoot "build\test-results\vanessa\extension-ui")
        }
        $evidencePath = Join-Path $ProjectRoot "build\test-results\release-e2e\extension-smoke.json"
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $evidencePath) | Out-Null
        Set-Content -LiteralPath $evidencePath -Encoding UTF8 -Value ($evidence | ConvertTo-Json -Depth 5)
    }
    "status" {
        if ([System.IO.Path]::GetFileName($VanessaFeaturePath) -ne "ITLReleaseFourFlat.feature") { throw "release E2E status must use the verified feature scope" }
        Write-Host "Verification fresh passed: True"
    }
    "export-dev-branch-result" {
        if ([System.IO.Path]::GetFileName($VanessaFeaturePath) -ne "ITLReleaseFourFlat.feature") { throw "release E2E export must use the verified feature scope" }
        $resultRoot = Join-Path $ProjectRoot "build\result"
        New-Item -ItemType Directory -Force -Path $resultRoot | Out-Null
        $artifact = Join-Path $resultRoot "fixture.cf"
        Set-Content -LiteralPath $artifact -Encoding ASCII -Value "fixture artifact"
        $hash = (Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash.ToLowerInvariant()
        $manifest = [ordered]@{ artifact = [ordered]@{ path = $artifact; sha256 = $hash }; verification = [ordered]@{ freshPassed = $true }; unverifiedOverride = $false }
        Set-Content -LiteralPath "$artifact.manifest.json" -Encoding UTF8 -Value ($manifest | ConvertTo-Json -Depth 8)
        $state | Add-Member -NotePropertyName lastResultPath -NotePropertyValue $artifact -Force
        Set-Content -LiteralPath $statePath -Encoding UTF8 -Value ($state | ConvertTo-Json -Depth 8)
    }
    "stop-dev-branch-test-clients" { }
    default { throw "unexpected action: $Action" }
}
'@

            # Fail once at the extension stage after the expensive configuration
            # stages have passed, then prove Auto resume reuses those checkpoints.
            $failureSummaryPath = Join-Path $tempRoot "release-failure-summary.json"
            $oldFailureFlag = $env:ITL_TEST_FAIL_RELEASE_EXTENSION
            $env:ITL_TEST_FAIL_RELEASE_EXTENSION = "true"
            $previousPreference = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
            try {
                & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot "scripts\invoke-release-e2e.ps1") `
                    -ProjectRoot $mainRoot -AiRulesSource $aiRulesRoot -HelperPath $helperPath -OutputPath $failureSummaryPath *> $null
                $failureExitCode = $LASTEXITCODE
            } finally {
                $ErrorActionPreference = $previousPreference
                $env:ITL_TEST_FAIL_RELEASE_EXTENSION = $oldFailureFlag
            }
            $failureExitCode | Should -Not -Be 0
            $failureSummary = Get-Content -LiteralPath $failureSummaryPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $failureSummary.status | Should -Be "failed"
            $failureSummary.error | Should -Match "release-e2e-extension-smoke failed with exit code 1"
            @($failureSummary.executedStages) | Should -Contain "config-cadence"
            @($failureSummary.executedStages) | Should -Contain "config-roundtrip"

            & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot "scripts\invoke-release-e2e.ps1") `
                -ProjectRoot $mainRoot -AiRulesSource $aiRulesRoot -HelperPath $helperPath -OutputPath $summaryPath -ResumeMode Auto
            $LASTEXITCODE | Should -Be 0
            $summary = Get-Content -LiteralPath $summaryPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $summary.status | Should -Be "passed"
            $summary.schemaVersion | Should -Be 2
            $summary.checkpointWasResumed | Should -BeTrue
            @($summary.resumedStages) | Should -Contain "config-cadence"
            @($summary.resumedStages) | Should -Contain "config-roundtrip"
            @($summary.executedStages) | Should -Contain "extension-smoke"
            @($summary.executedStages) | Should -Contain "ondemand-mcp"
            @($summary.executedStages) | Should -Contain "result-cleanup"
            $summary.sourceSnapshotPath | Should -Be $sourceSnapshot
            $summary.artifactSha256 | Should -Not -BeNullOrEmpty
            $summary.configLoadMode | Should -Be "partial"
            $summary.testOnlyCommit | Should -Not -BeNullOrEmpty
            $summary.vanessaJUnitTests | Should -Be 4
            $summary.stopOnErrorProbeCommit | Should -Not -BeNullOrEmpty
            $summary.stopOnErrorRecoveryCommit | Should -Be (& git -C $worktreeRoot rev-parse HEAD).Trim()
            $summary.stopOnErrorProbeTests | Should -Be 4
            ($summary.stopOnErrorProbeFailures + $summary.stopOnErrorProbeErrors) | Should -Be 1
            $summary.vanessaPostProcessDurationMs | Should -BeLessOrEqual 30000
            $summary.expectedComment | Should -Match '^ITL release E2E partial root roundtrip '
            $summary.roundtripParentConfigurationsPresent | Should -BeTrue
            $summary.extensionEmptyInitialized | Should -BeTrue
            $summary.extensionCfeCreated | Should -BeTrue
            $summary.extensionCfeInitialized | Should -BeTrue
            $summary.extensionDatabaseRestored | Should -BeTrue
            $summary.extensionFormOperationsIdempotent | Should -BeTrue
            $summary.extensionTemplateOperationsIdempotent | Should -BeTrue
            $summary.extensionFormContentPreserved | Should -BeTrue
            $summary.extensionFormModulePreserved | Should -BeTrue
            $summary.extensionTemplateContentPreserved | Should -BeTrue
            $summary.extensionExplicitMetadataUpdatesPassed | Should -BeTrue
            $summary.extensionFormRegistrationCount | Should -Be 1
            $summary.extensionTemplateRegistrationCount | Should -Be 1
            $summary.extensionUiTestClientPassed | Should -BeTrue
            $summary.extensionUiJunitTests | Should -Be 1
            $summary.onDemandRoctupToolCount | Should -Be 13
            $summary.onDemandVanessaToolCount | Should -Be 38
            $summary.onDemandVanessaInstances | Should -Be 2
            $summary.onDemandVanessaSecondSurvived | Should -BeTrue
            $summary.onDemandMcpTestFixture | Should -BeTrue
            $summary.extensionSmokeName | Should -Match '^ITLReleaseSmoke\d{14}$'
            $summary.cleanupFailures.Count | Should -Be 0
            $actions = Get-Content -LiteralPath (Join-Path $worktreeRoot ".agent-1c\release-e2e-actions.log") -Encoding UTF8
            $actions | Should -Contain "release-e2e-config-roundtrip"
            $actions | Should -Contain "release-e2e-extension-smoke"
            $actions | Should -Contain "stop-dev-branch-test-clients"
            @($actions | Where-Object { $_ -eq "check-dev-branch" }).Count | Should -Be 3
            @($actions | Where-Object { $_ -eq "release-e2e-config-roundtrip" }).Count | Should -Be 1
            @(& git -C $worktreeRoot status --porcelain).Count | Should -Be 0

            # Auto refuses a changed helper identity, while explicit Restart
            # uses the recorded baseline rollback and starts a new exact run.
            Add-Content -LiteralPath $helperPath -Encoding UTF8 -Value "# changed helper identity"
            $previousPreference = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
            try {
                $identityOutput = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot "scripts\invoke-release-e2e.ps1") `
                    -ProjectRoot $mainRoot -AiRulesSource $aiRulesRoot -HelperPath $helperPath -OutputPath (Join-Path $tempRoot "identity-mismatch.json") -ResumeMode Auto 2>&1
                $identityExitCode = $LASTEXITCODE
            } finally {
                $ErrorActionPreference = $previousPreference
            }
            $identityExitCode | Should -Not -Be 0
            ($identityOutput -join [Environment]::NewLine) | Should -Match "RELEASE_E2E_RESUME_STATE_MISMATCH"

            # Releases created before the ignored runtime-state location used a
            # tracked-worktree-visible checkpoint directory. Restart must allow
            # only that exact owned directory long enough to validate and roll
            # it back, then return the worktree to a clean state.
            $preferredRunRoot = Join-Path $worktreeRoot ".agent-1c\runs\release-e2e\workflow-release-e2e"
            $legacyRunRoot = Join-Path $worktreeRoot ".agent-1c\release-e2e-runs\workflow-release-e2e"
            $preferredCheckpointPath = Join-Path $preferredRunRoot "checkpoint.json"
            $checkpointJson = Get-Content -LiteralPath $preferredCheckpointPath -Raw -Encoding UTF8
            $checkpointJson = $checkpointJson.Replace($preferredRunRoot.Replace('\', '\\'), $legacyRunRoot.Replace('\', '\\'))
            [System.IO.File]::WriteAllText($preferredCheckpointPath, $checkpointJson, [System.Text.UTF8Encoding]::new($false))
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $legacyRunRoot) | Out-Null
            Move-Item -LiteralPath $preferredRunRoot -Destination $legacyRunRoot
            @(& git -C $worktreeRoot status --porcelain --untracked-files=all).Count | Should -BeGreaterThan 0

            $restartSummaryPath = Join-Path $tempRoot "restart-summary.json"
            & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot "scripts\invoke-release-e2e.ps1") `
                -ProjectRoot $mainRoot -AiRulesSource $aiRulesRoot -HelperPath $helperPath -OutputPath $restartSummaryPath -ResumeMode Restart
            $LASTEXITCODE | Should -Be 0
            $restartSummary = Get-Content -LiteralPath $restartSummaryPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $restartSummary.status | Should -Be "passed"
            $restartSummary.checkpointWasResumed | Should -BeFalse
            @($restartSummary.executedStages) | Should -Contain "config-cadence"
            Test-Path -LiteralPath $legacyRunRoot | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $preferredRunRoot "checkpoint.json") -PathType Leaf | Should -BeTrue

            # A corrupt checkpoint must be refused before any expensive stage.
            $checkpointPath = Join-Path $worktreeRoot ".agent-1c\runs\release-e2e\workflow-release-e2e\checkpoint.json"
            Set-Content -LiteralPath $checkpointPath -Encoding UTF8 -Value "{broken"
            $previousPreference = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
            try {
                $mismatchOutput = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot "scripts\invoke-release-e2e.ps1") `
                    -ProjectRoot $mainRoot -AiRulesSource $aiRulesRoot -HelperPath $helperPath -OutputPath (Join-Path $tempRoot "mismatch.json") 2>&1
                $mismatchExitCode = $LASTEXITCODE
            } finally {
                $ErrorActionPreference = $previousPreference
            }
            $mismatchExitCode | Should -Not -Be 0
            ($mismatchOutput -join [Environment]::NewLine) | Should -Match "RELEASE_E2E_RESUME_STATE_MISMATCH"
            @(& git -C $worktreeRoot status --porcelain).Count | Should -Be 0
        } finally {
            $env:ITL_TEST_RELEASE_ONDEMAND_PROBE = $oldOnDemandFixture
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
