BeforeAll {
    . (Join-Path $PSScriptRoot "TestSupport.ps1")
    $context = Initialize-WorkflowPesterContext
    $RepoRoot = $context.RepoRoot
}

Describe "Release E2E orchestration" {
    It "runs config and extension roundtrips, fresh verification, export, hash validation, and MCP cleanup" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-release-e2e-test-" + [guid]::NewGuid().ToString("N"))
        $mainRoot = Join-Path $tempRoot "main"
        $worktreeRoot = Join-Path $tempRoot "worktree"
        $helperPath = Join-Path $tempRoot "fake-helper.ps1"
        $aiRulesRoot = Join-Path $tempRoot "ai-rules"
        $workflowFixtureRoot = Join-Path $tempRoot "workflow-source"
        $summaryPath = Join-Path $tempRoot "release-summary.json"
        $oldOnDemandFixture = $env:ITL_TEST_RELEASE_ONDEMAND_PROBE
        $oldSeedParallelFixture = $env:ITL_TEST_RELEASE_SEED_PARALLEL
        $oldServerResetFixture = $env:ITL_TEST_RELEASE_SERVER_RESET_FIXTURE
        $env:ITL_TEST_RELEASE_ONDEMAND_PROBE = "true"
        $env:ITL_TEST_RELEASE_SEED_PARALLEL = "true"
        $env:ITL_TEST_RELEASE_SERVER_RESET_FIXTURE = "true"
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
            Set-Content -LiteralPath (Join-Path $mainRoot ".gitignore") -Encoding ASCII -Value ".agent-1c/dev-branches/`n.agent-1c/runs/`n.agent-1c/snapshots/`n.agent-1c/infobases/`n.dev.env`n.agent-1c/release-e2e-actions.log`n.agent-1c/release-e2e-partial-list.txt`n.agents/`nbuild/`n"
            Set-Content -LiteralPath (Join-Path $mainRoot "README.md") -Encoding ASCII -Value "fixture"
            New-Item -ItemType Directory -Force -Path (Join-Path $mainRoot "src\cf\Ext"), (Join-Path $mainRoot "src\cf\CommonModules\ITLRepositoryProbe\Ext"), (Join-Path $mainRoot ".agent-1c"), (Join-Path $mainRoot "tests\features") | Out-Null
            $dependencyLock = [ordered]@{
                schemaVersion = 1
                mode = "fresh"
                dependencies = [ordered]@{
                    vanessaAutomation = [ordered]@{ source = "fixture-original" }
                }
            }
            Set-Content -LiteralPath (Join-Path $mainRoot ".agent-1c\dependency-lock.json") -Encoding UTF8 -Value ($dependencyLock | ConvertTo-Json -Depth 6)
            Copy-Item -LiteralPath (Join-Path $RepoRoot "templates\project.json") -Destination (Join-Path $mainRoot ".agent-1c\project.json")
            $fixtureProjectPath = Join-Path $mainRoot ".agent-1c\project.json"
            $fixtureProject = Get-Content -LiteralPath $fixtureProjectPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $fixtureProject.aiRules.tools = @("kilocode")
            [IO.File]::WriteAllText($fixtureProjectPath, ($fixtureProject | ConvertTo-Json -Depth 16), [Text.UTF8Encoding]::new($false))
            Set-Content -LiteralPath (Join-Path $mainRoot "src\cf\Configuration.xml") -Encoding UTF8 -Value @'
<?xml version="1.0" encoding="UTF-8"?>
<MetaDataObject>
  <Configuration>
    <Properties><Comment>fixture</Comment></Properties>
  </Configuration>
</MetaDataObject>
'@
            Set-Content -LiteralPath (Join-Path $mainRoot "src\cf\ConfigDumpInfo.xml") -Encoding UTF8 -Value "<ConfigDumpInfo>fixture</ConfigDumpInfo>"
            [IO.File]::WriteAllBytes((Join-Path $mainRoot "src\cf\Ext\ParentConfigurations.bin"), [byte[]](1, 2, 3, 4))
            [IO.File]::WriteAllText((Join-Path $mainRoot "src\cf\CommonModules\ITLRepositoryProbe.xml"), '<MetaDataObject><CommonModule><Properties><Name>ITLRepositoryProbe</Name></Properties></CommonModule></MetaDataObject>', [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $mainRoot "src\cf\CommonModules\ITLRepositoryProbe\Ext\Module.bsl"), "Процедура Проверка() Экспорт`r`nКонецПроцедуры`r`n", [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllBytes(
                (Join-Path $mainRoot "tests\features\workflow-release-e2e.feature"),
                [Convert]::FromBase64String('I2xhbmd1YWdlOiBydQoK0Jgg0Y8g0LLRi9C/0L7Qu9C90Y/RjiDQutC+0LQg0LLRgdGC0YDQvtC10L3QvdC+0LPQviDRj9C30YvQutCwINC90LAg0YHQtdGA0LLQtdGA0LUK')
            )
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
                devBranchKind = "configuration"
                infoBaseKind = "file"
                devBranchInfoBasePath = (Join-Path $worktreeRoot '.agent-1c/infobases/workflow-release-e2e')
                worktreePath = $worktreeRoot
                unsafeActionProtectionResolution = "branch-confirmed"
                unsafeActionProtectionConfirmed = $true
                unsafeActionProtectionConfirmedAt = "2026-07-24T00:00:00Z"
                lastVerificationStatus = "missing"
            }
            # The recovery owner binds the same disposable native target even
            # when this fixture's helper represents Designer actions in-process.
            [void][IO.Directory]::CreateDirectory($state.devBranchInfoBasePath)
            [IO.File]::WriteAllText((Join-Path $state.devBranchInfoBasePath '1Cv8.1CD'), 'fixture infobase', [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $worktreeRoot '.dev.env'), ("INFOBASE_KIND=file`nINFOBASE_PATH=" + $state.devBranchInfoBasePath + "`nSOURCE_INFOBASE_PATH=$sourceSnapshot`n"), [Text.UTF8Encoding]::new($false))
            Set-Content -LiteralPath (Join-Path $worktreeRoot ".agent-1c\dev-branches\workflow-release-e2e.json") -Encoding UTF8 -Value ($state | ConvertTo-Json -Depth 6)
            Set-Content -LiteralPath $helperPath -Encoding UTF8 -Value @'
[CmdletBinding()]
param([string]$ProjectRoot, [string]$Action, [string]$AgentTarget, [string]$DevBranchName, [string]$ExtensionName, [string]$ReleaseAiRulesSource, [string]$VanessaFeaturePath, [string]$VanessaFilterTags, [string]$ReleaseSnapshotPath, [switch]$PreserveReleaseSnapshotApplicationProof, [ValidateSet("Auto", "Partial", "Full")][string]$ConfigLoadMode = "Auto", [string]$InternalOnDemandOperation, [string]$InternalOnDemandFamily)
if ($Action -and $AgentTarget -cne "kilocode") { throw "The unattended fixture helper must receive its configured Kilo client explicitly." }
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
        if (($releaseCheckCount -lt 3 -and $VanessaFilterTags -ne "@itl_release_flat") -or ($releaseCheckCount -eq 3 -and $VanessaFilterTags)) { throw "release E2E must leave only the final canonical recovery run unfiltered" }
        if ($releaseCheckCount -le 3 -and [System.IO.Path]::GetFileName($VanessaFeaturePath) -ne "ITLReleaseFourFlat.feature") { throw "release E2E capability checks must run the dedicated four-scenario feature file" }
        if ($releaseCheckCount -gt 3 -and $VanessaFeaturePath) { throw "release E2E verification refresh must be unfiltered" }
if ($releaseCheckCount -gt 3 -and $ConfigLoadMode -ne "Auto") { throw "release E2E verification refresh must route unchanged payload through automatic load selection" }
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
        $state | Add-Member -NotePropertyName lastVerificationStatus -NotePropertyValue $(if ($VanessaFeaturePath) { "partial" } else { "passed" }) -Force
        $state | Add-Member -NotePropertyName lastVerifiedAt -NotePropertyValue ([DateTime]::UtcNow.ToString("o")) -Force
        $state | Add-Member -NotePropertyName lastVerifiedCommit -NotePropertyValue ((& git -C $ProjectRoot rev-parse HEAD).Trim()) -Force
        Set-Content -LiteralPath $statePath -Encoding UTF8 -Value ($state | ConvertTo-Json -Depth 8)
        if ($metadataChanged) {
            Set-Content -LiteralPath (Join-Path $ProjectRoot "src\cf\ConfigDumpInfo.xml") -Encoding UTF8 -Value "<ConfigDumpInfo>cursor-$releaseCheckCount</ConfigDumpInfo>"
        }
        if ($isStopOnErrorProbe) { [Environment]::Exit(1) }
    }
    "release-e2e-snapshot" {
        $snapshotPath = Join-Path $ProjectRoot $ReleaseSnapshotPath
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $snapshotPath) | Out-Null
        Set-Content -LiteralPath $snapshotPath -Encoding ASCII -Value "mock infobase snapshot"
    }
    "release-e2e-restore" {
        if (-not $PreserveReleaseSnapshotApplicationProof) { throw "Release E2E must preserve the immutable snapshot/state application proof." }
        $snapshotPath = Join-Path $ProjectRoot $ReleaseSnapshotPath
        if (-not (Test-Path -LiteralPath $snapshotPath -PathType Leaf)) { throw "mock snapshot is missing" }
    }
    "release-e2e-prepare-ondemand" {
        $lockPath = Join-Path $ProjectRoot ".agent-1c\dependency-lock.json"
        $lock = Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $lock.dependencies.vanessaAutomation.source = "release-e2e-current-package-pin"
        Set-Content -LiteralPath $lockPath -Encoding UTF8 -Value ($lock | ConvertTo-Json -Depth 12)
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
        if ($VanessaFeaturePath) { throw "release E2E status must preserve the fresh full verification scope" }
        Write-Host "Verification fresh passed: True"
    }
    "export-dev-branch-result" {
        if ($VanessaFeaturePath) { throw "release E2E export must preserve the fresh full verification scope" }
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
    "refresh-dev-branch" {
        & git -C $ProjectRoot merge --no-edit master *> $null
        if ($LASTEXITCODE -ne 0) { throw "fixture refresh-dev-branch merge failed" }
    }
    "stop-dev-branch-test-clients" { }
    default { throw "unexpected action: $Action" }
}
'@

            # Fail between the file and server reset capabilities. The next run
            # must resume at server-reset without repeating seed-parallel.
            $sourceCandidateOutputRoot = Join-Path $tempRoot "source-candidate-output"
            $serverFailureSummaryPath = Join-Path $sourceCandidateOutputRoot "server-reset-failure-summary.json"
            $oldServerFailureFlag = $env:ITL_TEST_RELEASE_SERVER_RESET_FAILURE
            $env:ITL_TEST_RELEASE_SERVER_RESET_FAILURE = "true"
            $previousPreference = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
            try {
                $serverFailureOutput = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot "scripts\invoke-release-e2e.ps1") `
                    -ProjectRoot $mainRoot -AiRulesSource $aiRulesRoot -HelperPath $helperPath -OutputPath $serverFailureSummaryPath 2>&1
                $serverFailureExitCode = $LASTEXITCODE
            } finally {
                $ErrorActionPreference = $previousPreference
                $env:ITL_TEST_RELEASE_SERVER_RESET_FAILURE = $oldServerFailureFlag
            }
            $serverFailureExitCode | Should -Not -Be 0
            Test-Path -LiteralPath $serverFailureSummaryPath -PathType Leaf | Should -BeTrue -Because ($serverFailureOutput -join [Environment]::NewLine)
            $serverFailureSummary = Get-Content -LiteralPath $serverFailureSummaryPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $serverFailureSummary.error | Should -Match '^RELEASE_E2E_TEST_SERVER_RESET_FAILURE'
            $serverFailureSummary.stages.'seed-parallel'.status | Should -Be "passed"
            $serverFailureSummary.stages.'server-reset'.status | Should -Be "failed"
            @($serverFailureSummary.executedStages) | Should -Be @("seed-parallel", "server-reset")
            $interruptedCheckpointPath = Join-Path $worktreeRoot ".agent-1c\runs\release-e2e\workflow-release-e2e\checkpoint.json"
            $interruptedCheckpoint = Get-Content -LiteralPath $interruptedCheckpointPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $persistentEvidenceRoot = Join-Path $worktreeRoot ".agent-1c\runs\release-e2e\workflow-release-e2e\evidence"
            [string]$interruptedCheckpoint.stages.'seed-parallel'.evidencePath | Should -Be (Join-Path $persistentEvidenceRoot "seed-parallel.json")
            Test-Path -LiteralPath ([string]$interruptedCheckpoint.stages.'seed-parallel'.evidencePath) -PathType Leaf | Should -BeTrue
            (Get-FileHash -LiteralPath ([string]$interruptedCheckpoint.stages.'seed-parallel'.evidencePath) -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be ([string]$interruptedCheckpoint.stages.'seed-parallel'.evidenceSha256)
            Remove-Item -LiteralPath $sourceCandidateOutputRoot -Recurse -Force

            # Fail once at the extension stage after the expensive configuration
            # stages have passed, then prove Auto resume reuses those checkpoints.
            $failureSummaryPath = Join-Path $tempRoot "release-failure-summary.json"
            $oldFailureFlag = $env:ITL_TEST_FAIL_RELEASE_EXTENSION
            $env:ITL_TEST_FAIL_RELEASE_EXTENSION = "true"
            $previousPreference = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
            try {
                $failureOutput = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot "scripts\invoke-release-e2e.ps1") `
                    -ProjectRoot $mainRoot -AiRulesSource $aiRulesRoot -HelperPath $helperPath -OutputPath $failureSummaryPath 2>&1
                $failureExitCode = $LASTEXITCODE
            } finally {
                $ErrorActionPreference = $previousPreference
                $env:ITL_TEST_FAIL_RELEASE_EXTENSION = $oldFailureFlag
            }
            $failureExitCode | Should -Not -Be 0
            Test-Path -LiteralPath $failureSummaryPath -PathType Leaf | Should -BeTrue -Because ($failureOutput -join [Environment]::NewLine)
            $failureSummary = Get-Content -LiteralPath $failureSummaryPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $failureSummary.status | Should -Be "failed"
            $failureSummary.error | Should -Match "release-e2e-extension-smoke failed with exit code 1"
            @($failureSummary.resumedStages) | Should -Contain "seed-parallel"
            @($failureSummary.executedStages) | Should -Not -Contain "seed-parallel"
            @($failureSummary.executedStages) | Should -Contain "server-reset"
            @($failureSummary.executedStages) | Should -Contain "config-cadence"
            @($failureSummary.executedStages) | Should -Contain "config-roundtrip"
            $targetMarkerStep = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('0Jgg0Y8g0LLRi9C/0L7Qu9C90Y/RjiDQutC+0LQg0LLRgdGC0YDQvtC10L3QvdC+0LPQviDRj9C30YvQutCwINC90LAg0YHQtdGA0LLQtdGA0LUgKNCg0LDRgdGI0LjRgNC10L3QuNC1KQ=='))
            [IO.File]::ReadAllText((Join-Path $worktreeRoot "tests\features\workflow-release-e2e.feature"), [Text.Encoding]::UTF8) | Should -Match ([regex]::Escape($targetMarkerStep))
            $releaseCatalog = Get-Content -LiteralPath (Join-Path $worktreeRoot "tests\verification-suites.branch.json") -Raw -Encoding UTF8 | ConvertFrom-Json
            @($releaseCatalog.suites).Count | Should -Be 1
            $releaseCatalog.suites[0].purpose | Should -Be "acceptance"
            @($releaseCatalog.suites[0].featurePaths) | Should -Be @("tests/features/*.feature")
            @($releaseCatalog.suites[0].ownerPaths) | Should -Be @("src/cf/Configuration.xml")

            $staleResultRoot = Join-Path $worktreeRoot "build\result"
            $staleSnapshotRoot = Join-Path $worktreeRoot ".agent-1c\snapshots"
            $staleCacheRoot = Join-Path $worktreeRoot ".agent-1c\runs\release-e2e-capabilities\workflow-release-e2e\obsolete-cache"
            New-Item -ItemType Directory -Force -Path $staleResultRoot, $staleSnapshotRoot, $staleCacheRoot | Out-Null
            Set-Content -LiteralPath (Join-Path $staleResultRoot "obsolete.cf") -Encoding ASCII -Value "obsolete result"
            Set-Content -LiteralPath (Join-Path $staleResultRoot "obsolete.cf.manifest.json") -Encoding ASCII -Value "obsolete manifest"
            Set-Content -LiteralPath (Join-Path $staleSnapshotRoot "release-e2e-obsolete.dt") -Encoding ASCII -Value "obsolete release snapshot"
            Set-Content -LiteralPath (Join-Path $staleSnapshotRoot "extension-init-obsolete.dt") -Encoding ASCII -Value "obsolete extension snapshot"
            Set-Content -LiteralPath (Join-Path $staleSnapshotRoot "user-backup.dt") -Encoding ASCII -Value "unrelated snapshot"
            Set-Content -LiteralPath (Join-Path $staleCacheRoot "orphan.bin") -Encoding ASCII -Value "obsolete cache"

            & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot "scripts\invoke-release-e2e.ps1") `
                -ProjectRoot $mainRoot -AiRulesSource $aiRulesRoot -HelperPath $helperPath -OutputPath $summaryPath -ResumeMode Auto
            $LASTEXITCODE | Should -Be 0
            $summary = Get-Content -LiteralPath $summaryPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $summary.status | Should -Be "passed"
            $summary.schemaVersion | Should -Be 3
            $summary.durationMs | Should -BeGreaterThan 0
            $summary.checkpointWasResumed | Should -BeTrue
            @($summary.resumedStages) | Should -Contain "config-cadence"
            @($summary.resumedStages) | Should -Contain "config-roundtrip"
            @($summary.executedStages) | Should -Contain "extension-smoke"
            @($summary.executedStages) | Should -Contain "ondemand-mcp"
            @($summary.executedStages) | Should -Contain "result-cleanup"
            $summary.stages.'config-cadence'.proofDurationMs | Should -BeGreaterOrEqual 0
            @($summary.stages.'config-cadence'.attempts).Count | Should -BeGreaterThan 0
            $summary.sourceSnapshotPath | Should -Be $sourceSnapshot
            $summary.artifactSha256 | Should -Not -BeNullOrEmpty
            $summary.artifactRetention.status | Should -Be "passed"
            $summary.artifactRetention.removedFiles | Should -Be 4
            $summary.artifactRetention.removedDirectories | Should -Be 1
            Test-Path -LiteralPath (Join-Path $staleResultRoot "obsolete.cf") | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $staleResultRoot "obsolete.cf.manifest.json") | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $staleSnapshotRoot "release-e2e-obsolete.dt") | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $staleSnapshotRoot "extension-init-obsolete.dt") | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $staleSnapshotRoot "user-backup.dt") | Should -BeTrue
            Test-Path -LiteralPath ([string]$summary.artifactPath) -PathType Leaf | Should -BeTrue
            Test-Path -LiteralPath ([string]$summary.resultManifestPath) -PathType Leaf | Should -BeTrue
            $summary.configLoadMode | Should -Be "partial"
            $summary.testOnlyCommit | Should -Not -BeNullOrEmpty
            $summary.vanessaJUnitTests | Should -Be 4
            $summary.stopOnErrorProbeCommit | Should -Not -BeNullOrEmpty
            $summary.stopOnErrorRecoveryCommit | Should -Not -BeNullOrEmpty
            $summary.partialConfigDumpInfoCommit | Should -Match '^[a-f0-9]{40}$'
            $summary.recoveryConfigDumpInfoCommit | Should -Be (& git -C $worktreeRoot rev-parse HEAD).Trim()
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
            $summary.onDemandRoctupPublicToolCount | Should -Be 2
            $summary.onDemandVanessaPublicToolCount | Should -Be 2
            $summary.onDemandVanessaInstances | Should -Be 2
            $summary.onDemandVanessaSecondSurvived | Should -BeTrue
            $summary.onDemandVanessaSerializedHandoff | Should -BeTrue
            $summary.maxConcurrentSessions | Should -Be 3
            $summary.ownedProcessExitWaitMs | Should -BeLessOrEqual 15000
            $summary.onDemandMcpTestFixture | Should -BeTrue
            $summary.seedParallelTestFixture | Should -BeTrue
            $summary.seedParallelBranchRuntimeConcurrent | Should -BeTrue
            $summary.seedParallelLiteRefreshConcurrent | Should -BeTrue
            $summary.seedParallelRefreshAllPassed | Should -BeTrue
            $summary.seedParallelDirtyCheckpointPassed | Should -BeTrue
            $summary.seedParallelFileResetPassed | Should -BeTrue
            $summary.seedParallelRepositoryLockRoundtripPassed | Should -BeTrue
            $summary.seedParallelServerResetPassed | Should -BeTrue
            $summary.serverResetStatus | Should -Be "passed"
            $summary.seedParallelLiteRefreshSourceCallCount | Should -Be 0
            $summary.seedParallelTargetMasterCommit | Should -Match '^[a-f0-9]{40}$'
            $summary.extensionSmokeName | Should -Match '^ITLReleaseSmoke\d{14}$'
            $summary.cleanupFailures.Count | Should -Be 0
            $actions = Get-Content -LiteralPath (Join-Path $worktreeRoot ".agent-1c\release-e2e-actions.log") -Encoding UTF8
            $actions | Should -Contain "release-e2e-config-roundtrip"
            $actions | Should -Contain "release-e2e-extension-smoke"
            $actions | Should -Contain "release-e2e-prepare-ondemand"
            $actions | Should -Contain "stop-dev-branch-test-clients"
            @($actions | Where-Object { $_ -eq "check-dev-branch" }).Count | Should -Be 4
            $actions | Should -Not -Contain "release-e2e-approve-vanessa-fixture"
            @($actions | Where-Object { $_ -eq "release-e2e-config-roundtrip" }).Count | Should -Be 1
            @(& git -C $worktreeRoot status --porcelain).Count | Should -Be 0

            # Repeat the same workflow release: all successful evidence reuses,
            # while cleanup alone executes again.
            $checkpointPath = Join-Path $worktreeRoot ".agent-1c\runs\release-e2e\workflow-release-e2e\checkpoint.json"
            $promotionSummaryPath = Join-Path $tempRoot "promotion-summary.json"
            & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot "scripts\invoke-release-e2e.ps1") `
                -ProjectRoot $mainRoot -AiRulesSource $aiRulesRoot -HelperPath $helperPath -OutputPath $promotionSummaryPath -ResumeMode Auto
            $LASTEXITCODE | Should -Be 0
            $promotionSummary = Get-Content -LiteralPath $promotionSummaryPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $promotionSummary.crossReleaseReuse | Should -BeFalse
            foreach ($stageName in @("seed-parallel", "server-reset", "config-cadence", "config-roundtrip", "extension-smoke", "ondemand-mcp")) {
                $promotionSummary.stages.$stageName.execution | Should -Be "reused"
            }
            @($promotionSummary.executedStages).Count | Should -Be 1
            @($promotionSummary.executedStages) | Should -Contain "result-cleanup"
            @($promotionSummary.invalidatedStages) | Should -Contain "result-cleanup"
            $promotionState = Get-Content -LiteralPath (Join-Path $worktreeRoot ".agent-1c\dev-branches\workflow-release-e2e.json") -Raw -Encoding UTF8 | ConvertFrom-Json
            $promotionState.unsafeActionProtectionConfirmed | Should -BeTrue
            $promotedActions = Get-Content -LiteralPath (Join-Path $worktreeRoot ".agent-1c\release-e2e-actions.log") -Encoding UTF8
            @($promotedActions | Where-Object { $_ -eq "check-dev-branch" }).Count | Should -Be 4
            @($promotedActions | Where-Object { $_ -eq "release-e2e-config-roundtrip" }).Count | Should -Be 1
            $sealedCheckpoint = Get-Content -LiteralPath $checkpointPath -Raw -Encoding UTF8 | ConvertFrom-Json
            [string]$sealedCheckpoint.stages.'config-roundtrip'.evidencePath | Should -Match ([regex]::Escape(".agent-1c\runs\release-e2e-capabilities\"))
            Test-Path -LiteralPath ([string]$sealedCheckpoint.capabilityCache.manifestPath) -PathType Leaf | Should -BeTrue

            # Advance a real workflow candidate by changing only the managed
            # on-demand helper. Develop has already updated the installed copy;
            # Release must promote to a new rollback baseline while reusing all
            # unaffected immutable capability proofs.
            & git clone --quiet --no-local $RepoRoot $workflowFixtureRoot
            $LASTEXITCODE | Should -Be 0
            & git -C $workflowFixtureRoot config user.email "test@example.invalid"
            & git -C $workflowFixtureRoot config user.name "ITL Test"
            foreach ($relative in @(
                ".agents\skills\1c-workflow\scripts",
                ".agents\skills\1c-workflow\assets\ondemand-mcp",
                "scripts\release-e2e",
                "tools\itl-ondemand-mcp"
            )) {
                Copy-Item -LiteralPath (Join-Path $RepoRoot $relative) -Destination (Split-Path -Parent (Join-Path $workflowFixtureRoot $relative)) -Recurse -Force
            }
            foreach ($relative in @("scripts\invoke-release-e2e.ps1", "scripts\source-delivery-process.ps1", "scripts\stand-env-identity.ps1", "scripts\Build-ItlOnDemandMcp.ps1", "templates\dependency-lock.json", "tests\quality-contracts.json")) {
                Copy-Item -LiteralPath (Join-Path $RepoRoot $relative) -Destination (Join-Path $workflowFixtureRoot $relative) -Force
            }
            & git -C $workflowFixtureRoot add --all
            & git -C $workflowFixtureRoot commit --allow-empty -m "test: use current capability-cache runner" *> $null
            $LASTEXITCODE | Should -Be 0
            (Get-FileHash -LiteralPath (Join-Path $workflowFixtureRoot "scripts\invoke-release-e2e.ps1") -Algorithm SHA256).Hash | Should -Be (Get-FileHash -LiteralPath (Join-Path $RepoRoot "scripts\invoke-release-e2e.ps1") -Algorithm SHA256).Hash
            (Get-FileHash -LiteralPath (Join-Path $workflowFixtureRoot "scripts\stand-env-identity.ps1") -Algorithm SHA256).Hash | Should -Be (Get-FileHash -LiteralPath (Join-Path $RepoRoot "scripts\stand-env-identity.ps1") -Algorithm SHA256).Hash
            $candidateOnDemandPath = Join-Path $workflowFixtureRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.ondemand-mcp.ps1"
            Add-Content -LiteralPath $candidateOnDemandPath -Encoding UTF8 -Value "# release candidate managed-package advance"
            & git -C $workflowFixtureRoot add -- ".agents/skills/1c-workflow/scripts/lib/agent-1c.ondemand-mcp.ps1"
            & git -C $workflowFixtureRoot commit -m "test: advance only managed on-demand helper" *> $null
            $LASTEXITCODE | Should -Be 0
            $workflowCandidateCommit = (& git -C $workflowFixtureRoot rev-parse HEAD).Trim()
            $workflowCandidateTree = (& git -C $workflowFixtureRoot rev-parse 'HEAD^{tree}').Trim()
            $workflowCommonGit = (& git -C $workflowFixtureRoot rev-parse --path-format=absolute --git-common-dir).Trim()
            $targetedRunRoot = Join-Path $workflowCommonGit "itl\runs"
            New-Item -ItemType Directory -Force -Path $targetedRunRoot | Out-Null
            $targetedRun = [ordered]@{ schemaVersion=1; mode='Targeted'; status='passed'; exitCode=0; commit=$workflowCandidateCommit; tree=$workflowCandidateTree; finishedAt=[DateTime]::UtcNow.ToString('o'); stages=@([ordered]@{name='pester';status='passed'},[ordered]@{name='tracked-state';status='passed'},[ordered]@{name='git-diff-check';status='passed'}) }
            [IO.File]::WriteAllText((Join-Path $targetedRunRoot "fixture-targeted-continuation.json"), (($targetedRun | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
            @(& git -C $workflowFixtureRoot diff-tree --no-commit-id --name-only -r HEAD) | Should -Be @(".agents/skills/1c-workflow/scripts/lib/agent-1c.ondemand-mcp.ps1")
            $installedOnDemandPath = Join-Path $worktreeRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.ondemand-mcp.ps1"
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $installedOnDemandPath) | Out-Null
            Copy-Item -LiteralPath $candidateOnDemandPath -Destination $installedOnDemandPath -Force
            (Get-FileHash -LiteralPath $installedOnDemandPath -Algorithm SHA256).Hash | Should -Be (Get-FileHash -LiteralPath $candidateOnDemandPath -Algorithm SHA256).Hash
            Set-Content -LiteralPath (Join-Path $mainRoot "managed-workflow-refresh.txt") -Encoding ASCII -Value "managed refresh"
            & git -C $mainRoot add managed-workflow-refresh.txt; & git -C $mainRoot commit -m "test: install managed workflow refresh" *> $null
            $standMasterHead = (& git -C $mainRoot rev-parse HEAD).Trim()
            $checkpointExpectedHead = [string](Get-Content -LiteralPath $checkpointPath -Raw -Encoding UTF8 | ConvertFrom-Json).expectedHead
            & git -C $worktreeRoot merge --no-edit master *> $null
            $managedRefreshMergeHead = (& git -C $worktreeRoot rev-parse HEAD).Trim()
            $managedRefreshParents = @((& git -C $worktreeRoot rev-list --parents -n 1 $managedRefreshMergeHead).Trim() -split '\s+')
            $managedRefreshParents | Should -Be @($managedRefreshMergeHead, $checkpointExpectedHead, $standMasterHead)
            Set-Content -LiteralPath (Join-Path $worktreeRoot "src\cf\ConfigDumpInfo.xml") -Encoding UTF8 -Value "<ConfigDumpInfo>managed-refresh-cursor</ConfigDumpInfo>"
            & git -C $worktreeRoot add -- "src/cf/ConfigDumpInfo.xml"
            & git -C $worktreeRoot commit -m "chore: persist branch configuration synchronization cursor" *> $null
            $LASTEXITCODE | Should -Be 0
            $managedRefreshCursorParents = @((& git -C $worktreeRoot rev-list --parents -n 1 HEAD).Trim() -split '\s+')
            $managedRefreshCursorParents | Should -Be @((& git -C $worktreeRoot rev-parse HEAD).Trim(), $managedRefreshMergeHead)
            $checkpointBeforeManagedAdvance = Get-Content -LiteralPath $checkpointPath -Raw -Encoding UTF8 | ConvertFrom-Json
            . (Join-Path $RepoRoot 'scripts\release-qualification.ps1')
            $managedContinuation = Get-WorkflowContinuationProof -RepositoryRoot $workflowFixtureRoot -QualifiedCommit ([string]$checkpointBeforeManagedAdvance.identity.workflowCommit) -CurrentCommit $workflowCandidateCommit -CurrentTree $workflowCandidateTree
            $managedContinuation | Should -Not -BeNullOrEmpty
            $managedContinuation.paths | Should -Contain '.agents/skills/1c-workflow/scripts/lib/agent-1c.ondemand-mcp.ps1'
            $actualContinuationCatalog = Get-Content -LiteralPath (Join-Path $workflowFixtureRoot 'tests\quality-contracts.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            @($actualContinuationCatalog.continuationScopes.PSObject.Properties | ForEach-Object { @($_.Value) } | Where-Object {
                Test-WorkflowContinuationPattern -Path '.agents/skills/1c-workflow/scripts/lib/agent-1c.foreign-sibling.ps1' -Pattern ([string]$_)
            }).Count | Should -Be 0
            $targetedFixturePath = Join-Path $targetedRunRoot 'fixture-targeted-continuation.json'
            $targetedFixtureBytes = [IO.File]::ReadAllBytes($targetedFixturePath)
            $targetedFixtureSha256 = (Get-FileHash -LiteralPath $targetedFixturePath -Algorithm SHA256).Hash
            Remove-Item -LiteralPath $targetedFixturePath
            try {
                Get-WorkflowContinuationProof -RepositoryRoot $workflowFixtureRoot -QualifiedCommit ([string]$checkpointBeforeManagedAdvance.identity.workflowCommit) -CurrentCommit $workflowCandidateCommit -CurrentTree $workflowCandidateTree | Should -BeNullOrEmpty
            } finally { [IO.File]::WriteAllBytes($targetedFixturePath, $targetedFixtureBytes) }
            (Get-FileHash -LiteralPath $targetedFixturePath -Algorithm SHA256).Hash | Should -Be $targetedFixtureSha256
            $managedAdvanceSummaryPath = Join-Path $tempRoot "managed-advance-summary.json"
            & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $workflowFixtureRoot "scripts\invoke-release-e2e.ps1") `
                -ProjectRoot $mainRoot -AiRulesSource $aiRulesRoot -HelperPath $helperPath -OutputPath $managedAdvanceSummaryPath -ResumeMode Auto
            $LASTEXITCODE | Should -Be 0
            $managedAdvanceSummary = Get-Content -LiteralPath $managedAdvanceSummaryPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $managedAdvanceSummary.crossReleaseReuse | Should -BeTrue
            foreach ($stageName in @("seed-parallel", "server-reset", "config-cadence", "config-roundtrip", "extension-smoke")) {
                @($managedAdvanceSummary.resumedStages) | Should -Contain $stageName
                $managedAdvanceSummary.stages.$stageName.execution | Should -Be "reused"
            }
            @($managedAdvanceSummary.executedStages) | Should -Contain "ondemand-mcp"
            @($managedAdvanceSummary.executedStages) | Should -Contain "verification-refresh"
            @($managedAdvanceSummary.executedStages) | Should -Contain "result-cleanup"
            $checkpointAfterManagedAdvance = Get-Content -LiteralPath $checkpointPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $checkpointAfterManagedAdvance.schemaVersion | Should -Be 3
            $checkpointAfterManagedAdvance.runId | Should -Not -Be $checkpointBeforeManagedAdvance.runId
            $checkpointAfterManagedAdvance.identity.workflowCommit | Should -Be (& git -C $workflowFixtureRoot rev-parse HEAD).Trim()
            Test-Path -LiteralPath ([string]$checkpointAfterManagedAdvance.capabilityCache.manifestPath) -PathType Leaf | Should -BeTrue

            # A cross-release attempt can fail after capability reuse but before
            # verification-refresh. Its same-commit Auto retry must not lose the
            # pending refresh merely because crossReleaseReuse is now false.
            $checkpointAfterManagedAdvance.stages.PSObject.Properties.Remove("verification-refresh")
            $checkpointAfterManagedAdvance.stages.'result-cleanup'.status = "failed"
            $checkpointAfterManagedAdvance.status = "failed"
            [IO.File]::WriteAllText($checkpointPath, (($checkpointAfterManagedAdvance | ConvertTo-Json -Depth 32) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
            $sameCommitResumeSummaryPath = Join-Path $tempRoot "same-commit-refresh-summary.json"
            & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $workflowFixtureRoot "scripts\invoke-release-e2e.ps1") `
                -ProjectRoot $mainRoot -AiRulesSource $aiRulesRoot -HelperPath $helperPath -OutputPath $sameCommitResumeSummaryPath -ResumeMode Auto
            $LASTEXITCODE | Should -Be 0
            $sameCommitResumeSummary = Get-Content -LiteralPath $sameCommitResumeSummaryPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $sameCommitResumeSummary.crossReleaseReuse | Should -BeFalse
            @($sameCommitResumeSummary.executedStages) | Should -Contain "verification-refresh"
            @($sameCommitResumeSummary.executedStages) | Should -Contain "result-cleanup"
            foreach ($stageName in @("seed-parallel", "server-reset", "config-cadence", "config-roundtrip", "extension-smoke", "ondemand-mcp")) {
                @($sameCommitResumeSummary.executedStages) | Should -Not -Contain $stageName
            }
            $checkpointAfterManagedAdvance = Get-Content -LiteralPath $checkpointPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $legacyCache = Get-Content -LiteralPath ([string]$checkpointAfterManagedAdvance.capabilityCache.manifestPath) -Raw -Encoding UTF8 | ConvertFrom-Json
            $legacyCache.stages.'seed-parallel'.fingerprint = "legacy-raw-checkout-fingerprint"
            $legacyCache.identity.helperSha256 = (Get-FileHash -LiteralPath $helperPath -Algorithm SHA256).Hash.ToLowerInvariant()
            $legacyCache.identity.helperSha256 | Should -Not -Be $checkpointAfterManagedAdvance.identity.helperSha256
            [IO.File]::WriteAllText(([string]$checkpointAfterManagedAdvance.capabilityCache.manifestPath), (($legacyCache | ConvertTo-Json -Depth 16) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))

            # A harness-only repair after a completed release starts at fresh
            # verification/cleanup. It must not rerun any passed capability.
            $candidateRunnerPath = Join-Path $workflowFixtureRoot "scripts\invoke-release-e2e.ps1"
            Add-Content -LiteralPath $candidateRunnerPath -Encoding UTF8 -Value "# fixture interrupted harness attempt"
            & git -C $workflowFixtureRoot add -- "scripts/invoke-release-e2e.ps1"
            & git -C $workflowFixtureRoot commit -m "test: record interrupted release harness" *> $null
            $LASTEXITCODE | Should -Be 0
            $interruptedHarnessCommit = (& git -C $workflowFixtureRoot rev-parse HEAD).Trim()
            $interruptedHarnessTree = (& git -C $workflowFixtureRoot rev-parse 'HEAD^{tree}').Trim()
            $interruptedRunnerSha256 = (Get-FileHash -LiteralPath $candidateRunnerPath -Algorithm SHA256).Hash.ToLowerInvariant()
            Add-Content -LiteralPath $candidateRunnerPath -Encoding UTF8 -Value "# fixture harness-only repair"
            & git -C $workflowFixtureRoot add -- "scripts/invoke-release-e2e.ps1"
            & git -C $workflowFixtureRoot commit -m "test: repair only the release harness" *> $null
            $LASTEXITCODE | Should -Be 0
            $harnessCommit = (& git -C $workflowFixtureRoot rev-parse HEAD).Trim()
            $harnessTree = (& git -C $workflowFixtureRoot rev-parse 'HEAD^{tree}').Trim()
            $harnessTargetedRun = [ordered]@{ schemaVersion=1; mode='Targeted'; status='passed'; exitCode=0; commit=$harnessCommit; tree=$harnessTree; finishedAt=[DateTime]::UtcNow.ToString('o'); stages=@([ordered]@{name='pester';status='passed'},[ordered]@{name='tracked-state';status='passed'},[ordered]@{name='git-diff-check';status='passed'}) }
            [IO.File]::WriteAllText((Join-Path $targetedRunRoot "fixture-harness-targeted-continuation.json"), (($harnessTargetedRun | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
            $legacyCheckpoint = Get-Content -LiteralPath $checkpointPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $legacyCheckpoint.identity.workflowCommit = $interruptedHarnessCommit
            $legacyCheckpoint.identity.workflowTree = $interruptedHarnessTree
            $legacyCheckpoint.identity.runnerSha256 = $interruptedRunnerSha256
            $legacyCheckpoint.stateFiles.baseline.actualEnvPath = [pscustomobject]@{ Length = 67 }
            $legacyCheckpoint.stateFiles.postConfig.actualEnvPath = [pscustomobject]@{ Length = 67 }
            $legacyCheckpoint.stages.'seed-parallel'.status = "running"
            $legacyCheckpoint.stages.'seed-parallel'.execution = "executed"
            [IO.File]::WriteAllText($checkpointPath, (($legacyCheckpoint | ConvertTo-Json -Depth 16) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
            $harnessSummaryPath = Join-Path $tempRoot "harness-continuation\summary.json"
            & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $candidateRunnerPath `
                -ProjectRoot $mainRoot -AiRulesSource $aiRulesRoot -HelperPath $helperPath -OutputPath $harnessSummaryPath -ResumeMode Auto
            $LASTEXITCODE | Should -Be 0
            $harnessSummary = Get-Content -LiteralPath $harnessSummaryPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($stageName in @("seed-parallel", "server-reset", "config-cadence", "config-roundtrip", "extension-smoke", "ondemand-mcp")) {
                @($harnessSummary.resumedStages) | Should -Contain $stageName
                $harnessSummary.stages.$stageName.execution | Should -Be "reused"
                @($harnessSummary.executedStages) | Should -Not -Contain $stageName
            }
            @($harnessSummary.executedStages) | Should -Contain "verification-refresh"
            @($harnessSummary.executedStages) | Should -Contain "result-cleanup"
            Test-Path -LiteralPath (Join-Path $RepoRoot "System.Collections.Specialized.OrderedDictionary") | Should -BeFalse

            # The same commit can be materialized with LF or CRLF in another
            # checkout. Line endings alone must not invalidate stage proof.
            foreach ($path in @(
                $candidateRunnerPath,
                (Join-Path $workflowFixtureRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.vanessa.ps1")
            )) {
                $text = [IO.File]::ReadAllText($path, [Text.UTF8Encoding]::new($false))
                $normalized = $text.Replace("`r`n", "`n").Replace("`r", "`n")
                $materialized = if ($text.Contains("`r`n")) { $normalized } else { $normalized.Replace("`n", "`r`n") }
                [IO.File]::WriteAllText($path, $materialized, [Text.UTF8Encoding]::new($false))
            }
            $materializationSummaryPath = Join-Path $tempRoot "materialization-summary.json"
            & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $candidateRunnerPath `
                -ProjectRoot $mainRoot -AiRulesSource $aiRulesRoot -HelperPath $helperPath -OutputPath $materializationSummaryPath -ResumeMode Auto
            $LASTEXITCODE | Should -Be 0
            $materializationSummary = Get-Content -LiteralPath $materializationSummaryPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($stageName in @("seed-parallel", "server-reset", "config-cadence", "config-roundtrip", "extension-smoke", "ondemand-mcp")) {
                $materializationSummary.stages.$stageName.execution | Should -Be "reused"
                @($materializationSummary.executedStages) | Should -Not -Contain $stageName
            }

            # A declared reusable stage with corrupt evidence must fail closed
            # before any capability action is invoked.
            $checkpointBytes = [System.IO.File]::ReadAllBytes($checkpointPath)
            $checkpointForCorruption = Get-Content -LiteralPath $checkpointPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $evidencePath = [string]$checkpointForCorruption.stages.'config-roundtrip'.evidencePath
            $evidenceBytes = [System.IO.File]::ReadAllBytes($evidencePath)
            Add-Content -LiteralPath $evidencePath -Encoding UTF8 -Value "corrupt"
            $roundtripCountBeforeCorruption = @($actions | Where-Object { $_ -eq "release-e2e-config-roundtrip" }).Count
            $extensionCountBeforeCorruption = @($actions | Where-Object { $_ -eq "release-e2e-extension-smoke" }).Count
            $previousPreference = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
            try {
                $corruptEvidenceOutput = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $workflowFixtureRoot "scripts\invoke-release-e2e.ps1") `
                    -ProjectRoot $mainRoot -AiRulesSource $aiRulesRoot -HelperPath $helperPath -OutputPath (Join-Path $tempRoot "corrupt-evidence-summary.json") -ResumeMode Auto 2>&1
                $corruptEvidenceExitCode = $LASTEXITCODE
            } finally {
                $ErrorActionPreference = $previousPreference
                [System.IO.File]::WriteAllBytes($evidencePath, $evidenceBytes)
                [System.IO.File]::WriteAllBytes($checkpointPath, $checkpointBytes)
            }
            $corruptEvidenceExitCode | Should -Not -Be 0
            ($corruptEvidenceOutput -join [Environment]::NewLine) | Should -Match "RELEASE_E2E_CACHE_CORRUPT"
            $actionsAfterCorruption = Get-Content -LiteralPath (Join-Path $worktreeRoot ".agent-1c\release-e2e-actions.log") -Encoding UTF8
            @($actionsAfterCorruption | Where-Object { $_ -eq "release-e2e-config-roundtrip" }).Count | Should -Be $roundtripCountBeforeCorruption
            @($actionsAfterCorruption | Where-Object { $_ -eq "release-e2e-extension-smoke" }).Count | Should -Be $extensionCountBeforeCorruption

            # Legacy checkpoints require one explicit scripted Restart migration.
            $checkpointV2Text = Get-Content -LiteralPath $checkpointPath -Raw -Encoding UTF8
            $legacyCheckpoint = $checkpointV2Text | ConvertFrom-Json
            $legacyCheckpoint.schemaVersion = 1
            [System.IO.File]::WriteAllText($checkpointPath, (($legacyCheckpoint | ConvertTo-Json -Depth 16) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
            $previousPreference = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
            try {
                $upgradeOutput = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $workflowFixtureRoot "scripts\invoke-release-e2e.ps1") `
                    -ProjectRoot $mainRoot -AiRulesSource $aiRulesRoot -HelperPath $helperPath -OutputPath (Join-Path $tempRoot "upgrade-required.json") -ResumeMode Auto 2>&1
                $upgradeExitCode = $LASTEXITCODE
            } finally { $ErrorActionPreference = $previousPreference }
            $upgradeExitCode | Should -Not -Be 0
            ($upgradeOutput -join [Environment]::NewLine) | Should -Match "RELEASE_E2E_CHECKPOINT_UPGRADE_REQUIRED"
            [System.IO.File]::WriteAllText($checkpointPath, $checkpointV2Text, [System.Text.UTF8Encoding]::new($false))

            # A harness-only repair must not invalidate independent runtime proof.
            Add-Content -LiteralPath $helperPath -Encoding UTF8 -Value "# changed helper identity"
            $incrementalSummaryPath = Join-Path $tempRoot "incremental-summary.json"
            & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $workflowFixtureRoot "scripts\invoke-release-e2e.ps1") `
                -ProjectRoot $mainRoot -AiRulesSource $aiRulesRoot -HelperPath $helperPath -OutputPath $incrementalSummaryPath -ResumeMode Auto
            $LASTEXITCODE | Should -Be 0
            $incrementalSummary = Get-Content -LiteralPath $incrementalSummaryPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $incrementalSummary.crossReleaseReuse | Should -BeTrue
            @($incrementalSummary.invalidatedStages) | Should -Not -Contain "config-cadence"
            $incrementalSummary.stages.'config-cadence'.execution | Should -Be "reused"
            @($incrementalSummary.executedStages) | Should -Not -Contain "config-cadence"
            $incrementalSummary.stages.'verification-refresh'.execution | Should -Be "executed"
            @($incrementalSummary.executedStages) | Should -Contain "verification-refresh"
            @($incrementalSummary.executedStages) | Should -Contain "result-cleanup"

            # Restart is the explicit destructive rollback path. It must accept
            # a clean externally advanced branch HEAD, while Auto above remains
            # fail-closed for identity or expected-HEAD drift.
            Add-Content -LiteralPath (Join-Path $mainRoot ".gitignore") -Encoding ASCII -Value ".agent-1c/execution-guard-generation.json"
            & git -C $mainRoot add .gitignore
            & git -C $mainRoot commit -m "fixture: ignore current execution generation" *> $null
            $LASTEXITCODE | Should -Be 0
            Add-Content -LiteralPath (Join-Path $worktreeRoot "README.md") -Encoding ASCII -Value "external clean advance"
            & git -C $worktreeRoot add README.md
            & git -C $worktreeRoot commit -m "test: externally advance clean E2E branch" *> $null
            $LASTEXITCODE | Should -Be 0
            @(& git -C $worktreeRoot status --porcelain --untracked-files=all).Count | Should -Be 0

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
            [IO.File]::WriteAllText(
                (Join-Path $worktreeRoot ".agent-1c\execution-guard-generation.json"),
                '{"schemaVersion":1,"generation":"release-restart-fixture"}',
                [Text.UTF8Encoding]::new($false)
            )
            @(& git -C $worktreeRoot status --porcelain --untracked-files=all).Count | Should -BeGreaterThan 0

            $restartSummaryPath = Join-Path $tempRoot "restart-summary.json"
            & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $workflowFixtureRoot "scripts\invoke-release-e2e.ps1") `
                -ProjectRoot $mainRoot -AiRulesSource $aiRulesRoot -HelperPath $helperPath -OutputPath $restartSummaryPath -ResumeMode Restart
            $LASTEXITCODE | Should -Be 0
            $restartSummary = Get-Content -LiteralPath $restartSummaryPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $restartSummary.status | Should -Be "passed"
            $restartSummary.checkpointWasResumed | Should -BeFalse
            @($restartSummary.executedStages) | Should -Contain "config-cadence"
            Test-Path -LiteralPath $legacyRunRoot | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $preferredRunRoot "checkpoint.json") -PathType Leaf | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $worktreeRoot ".agent-1c\execution-guard-generation.json") -PathType Leaf | Should -BeTrue
            (& git -C $worktreeRoot check-ignore ".agent-1c/execution-guard-generation.json") | Should -Be ".agent-1c/execution-guard-generation.json"
            @(& git -C $worktreeRoot status --porcelain --untracked-files=all).Count | Should -Be 0

            # A configured server proof remains testable, but omitting the
            # server stand must produce explicit unverified evidence and pass.
            $optionalServerCheckpoint = Get-Content -LiteralPath (Join-Path $preferredRunRoot "checkpoint.json") -Raw -Encoding UTF8 | ConvertFrom-Json
            $optionalServerCheckpoint.stages.PSObject.Properties.Remove("server-reset")
            [IO.File]::WriteAllText((Join-Path $preferredRunRoot "checkpoint.json"), (($optionalServerCheckpoint | ConvertTo-Json -Depth 32) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
            $optionalServerSummaryPath = Join-Path $tempRoot "optional-server-summary.json"
            $env:ITL_TEST_RELEASE_SERVER_RESET_FIXTURE = "false"
            try {
                & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $workflowFixtureRoot "scripts\invoke-release-e2e.ps1") `
                    -ProjectRoot $mainRoot -AiRulesSource $aiRulesRoot -HelperPath $helperPath -OutputPath $optionalServerSummaryPath -ResumeMode Auto
                $LASTEXITCODE | Should -Be 0
            } finally {
                $env:ITL_TEST_RELEASE_SERVER_RESET_FIXTURE = "true"
            }
            $optionalServerSummary = Get-Content -LiteralPath $optionalServerSummaryPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $optionalServerSummary.serverResetConfigured | Should -BeFalse
            $optionalServerSummary.serverResetStatus | Should -Be "unverified"
            $optionalServerSummary.seedParallelServerResetPassed | Should -BeFalse
            @($optionalServerSummary.executedStages) | Should -Not -Contain "server-reset"

            # A frozen qualification copy has a restored branch DB, not a live
            # source DB. Its branch-only scope must pass the public runner while
            # full/seed/recovery admission retains the original prerequisite.
            $sourceDatabase = Join-Path $sourceSnapshot '1Cv8.1CD'
            $sourceDatabaseBytes = [IO.File]::ReadAllBytes($sourceDatabase)
            Remove-Item -LiteralPath $sourceDatabase
            try {
                $frozenSummaryPath = Join-Path $tempRoot 'frozen-source-summary.json'
                & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $workflowFixtureRoot 'scripts\invoke-release-e2e.ps1') `
                    -ProjectRoot $mainRoot -AiRulesSource $aiRulesRoot -HelperPath $helperPath -OutputPath $frozenSummaryPath `
                    -Capabilities 'config-cadence,extension-smoke,ondemand-mcp' -ResumeMode Auto
                $LASTEXITCODE | Should -Be 0
                $frozenSummary = Get-Content -LiteralPath $frozenSummaryPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $frozenSummary.status | Should -BeExactly 'passed'
                @($frozenSummary.selectedCapabilities | Sort-Object) | Should -Be @('config-cadence','extension-smoke','ondemand-mcp')
                @($frozenSummary.executedStages) | Should -Not -Contain 'seed-parallel'
                @($frozenSummary.resumedStages) | Should -Not -Contain 'seed-parallel'
                Test-Path -LiteralPath $sourceDatabase | Should -BeFalse
                $headBeforeRefusal = (& git -C $worktreeRoot rev-parse HEAD).Trim()
                foreach ($scope in @('all','seed-parallel','recovery')) {
                    $scopeArguments = @()
                    if ($scope -eq 'seed-parallel') { $scopeArguments += @('-Capabilities','seed-parallel') }
                    if ($scope -eq 'recovery') { $scopeArguments += '-RecoverInterruptedExtensionOnly' }
                    $previousPreference = $ErrorActionPreference
                    $ErrorActionPreference = 'Continue'
                    try {
                        $missingSourceOutput = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $workflowFixtureRoot 'scripts\invoke-release-e2e.ps1') `
                            -ProjectRoot $mainRoot -AiRulesSource $aiRulesRoot -HelperPath $helperPath -OutputPath (Join-Path $tempRoot ('missing-source-'+$scope+'.json')) @scopeArguments 2>&1
                        $missingSourceExit = $LASTEXITCODE
                    } finally { $ErrorActionPreference = $previousPreference }
                    $missingSourceExit | Should -Not -Be 0
                    ($missingSourceOutput -join [Environment]::NewLine) | Should -Match 'Dedicated E2E source snapshot does not contain 1Cv8.1CD'
                    (& git -C $worktreeRoot rev-parse HEAD).Trim() | Should -BeExactly $headBeforeRefusal
                }
            } finally { [IO.File]::WriteAllBytes($sourceDatabase, $sourceDatabaseBytes) }

            # A corrupt checkpoint must be refused before any expensive stage.
            $checkpointPath = Join-Path $worktreeRoot ".agent-1c\runs\release-e2e\workflow-release-e2e\checkpoint.json"
            Set-Content -LiteralPath $checkpointPath -Encoding UTF8 -Value "{broken"
            $previousPreference = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
            try {
                $mismatchOutput = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $workflowFixtureRoot "scripts\invoke-release-e2e.ps1") `
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
            $env:ITL_TEST_RELEASE_SEED_PARALLEL = $oldSeedParallelFixture
            $env:ITL_TEST_RELEASE_SERVER_RESET_FIXTURE = $oldServerResetFixture
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
