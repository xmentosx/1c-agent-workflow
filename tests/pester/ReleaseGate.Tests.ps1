BeforeAll {
    . (Join-Path $PSScriptRoot "TestSupport.ps1")
    $context = Initialize-WorkflowPesterContext
    $RepoRoot = $context.RepoRoot
}

Describe "Release gate scripts" {
    It "parses the local gate and E2E runner" {
        foreach ($relativePath in @("scripts\check.ps1", "scripts\invoke-develop-e2e.ps1", "scripts\invoke-release-e2e.ps1")) {
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
        $e2eText | Should -Match "\`$authoringOutcome -ne `"passed`""
        $e2eText | Should -Not -Match "runner-fallback-required"
        $e2eText | Should -Match "PATH_ACCESS_DENIED.*PATH_INVALID.*PATH_NOT_FOUND"
        $e2eText | Should -Match "vanessaAutomationArchiveSha256"
        $e2eText | Should -Match ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("VmFuZXNzYSDQv9GD0YLRjCDRgSDQv9GA0L7QsdC10LvQsNC80Lg=")))
        ([regex]::Matches($e2eText, 'Invoke-E2EHelper -Action "check-dev-branch"')).Count | Should -Be 4
        $e2eText | Should -Not -Match 'release-e2e-approve-vanessa-fixture'
        $e2eText | Should -Match 'RELEASE_E2E_RESUME_STATE_MISMATCH'
        $e2eText | Should -Match 'Restore-E2EInfobaseSnapshot'
        $e2eText | Should -Match 'runnerSha256'
        $e2eText | Should -Match 'Get-E2EStageFingerprint'
        $e2eText | Should -Match 'RELEASE_E2E_CHECKPOINT_UPGRADE_REQUIRED'
        $e2eText | Should -Match 'RELEASE_E2E_CACHE_CORRUPT'
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
        $lifecycleText | Should -Match '(?s)if \(\$snapshotCreated -and \$databaseRestored\).*?Remove-CompletedInfobaseSnapshot -SnapshotPath \$snapshotPath'
        $lifecycleText | Should -Match 'snapshot cleanup failed.*Snapshot retained'
        $developE2eText = Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\invoke-develop-e2e.ps1") -Raw -Encoding UTF8
        $developE2eText | Should -Match '(?s)& git -C \$Root commit -m \$Message \| Out-Null\s+if \(\$LASTEXITCODE -ne 0\) \{\s+\$remaining = @\(& git -C \$Root status --porcelain --untracked-files=no\)\s+if \(\$remaining\.Count -ne 0\) \{ throw "Unable to commit \$Message\." \}'
    }

    It "requires the lock-pinned annotated fork tag and explicit E2E stand" {
        $text = Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\check.ps1") -Raw -Encoding UTF8
        $text | Should -Match 'Pinned fork tag must exist locally and be annotated'
        $text | Should -Match 'release/\$tag'
        $text | Should -Match '\$effectiveMode mode requires -E2EProjectRoot'
        $text | Should -Match 'Get-CanonicalTextSha256 -Path \$catalogPath'
        $text | Should -Match 'compatibilityStatus'
        $text | Should -Match 'release-e2e-summary.json'
        $text | Should -Match '\$releaseHelperPath'
        $text | Should -Match '"-HelperPath", \$releaseHelperPath'
        $text | Should -Match '"-AiRulesSource", \$releaseRulesSource'
        $text | Should -Match 'Release E2E summary reports'
        $text | Should -Match 'maxConcurrentSessions'
        $text | Should -Match 'ownedProcessExitWaitMs'
        $text | Should -Match '\[Console\]::Error\.WriteLine\(\$failure\)'
        $runnerText = Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\invoke-release-e2e.ps1") -Raw -Encoding UTF8
        $runnerText | Should -Match 'SOURCE_INFOBASE_PATH must be a disposable snapshot inside the stand'
        $runnerText | Should -Match '\[Console\]::Error\.WriteLine\(\$failure\)'
        (Get-Content -LiteralPath (Join-Path $RepoRoot "docs\release-checklist.md") -Raw -Encoding UTF8) | Should -Match 'source-snapshot'
    }

    It "uses the default seed root for a legacy project config" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-release-seed-root-" + [guid]::NewGuid().ToString("N"))
        try {
            $seedRoot = Join-Path $tempRoot ".agent-1c\branch-seed\source"
            New-Item -ItemType Directory -Force -Path $seedRoot | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"schemaVersion":1}'
            Set-Content -LiteralPath (Join-Path $seedRoot "manifest.json") -Encoding UTF8 -Value '{"status":"ready","completedAt":"2026-07-30T00:00:00Z"}'

            $tokens = $null
            $errors = $null
            $runnerAst = [System.Management.Automation.Language.Parser]::ParseFile(
                (Join-Path $RepoRoot "scripts\invoke-release-e2e.ps1"),
                [ref]$tokens,
                [ref]$errors
            )
            @($errors) | Should -BeNullOrEmpty
            $functionAst = $runnerAst.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq "Get-E2ESeedManifest"
            }, $true)
            . ([scriptblock]::Create($functionAst.Extent.Text))

            $manifest = Get-E2ESeedManifest -MainRoot $tempRoot
            $manifest.path | Should -Be (Join-Path $seedRoot "manifest.json")
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "sets the noninteractive unsafe-action mode only in a disposable seed worktree" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-release-seed-env-" + [guid]::NewGuid().ToString("N"))
        $envPath = Join-Path $tempRoot ".dev.env"
        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            [IO.File]::WriteAllText(
                $envPath,
                "KEEP=value`r`nDEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP=manual-confirm`r`nDEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP=duplicate`r`n",
                [Text.UTF8Encoding]::new($false)
            )

            $tokens = $null
            $errors = $null
            $runnerAst = [System.Management.Automation.Language.Parser]::ParseFile(
                (Join-Path $RepoRoot "scripts\invoke-release-e2e.ps1"),
                [ref]$tokens,
                [ref]$errors
            )
            @($errors) | Should -BeNullOrEmpty
            $functionAst = $runnerAst.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq "Set-E2EDotEnvValue"
            }, $true)
            . ([scriptblock]::Create($functionAst.Extent.Text))

            Set-E2EDotEnvValue -Path $envPath -Name "DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP" -Value "skip"

            $lines = @([IO.File]::ReadAllLines($envPath, [Text.Encoding]::UTF8))
            $lines | Should -Contain "KEEP=value"
            @($lines | Where-Object { $_ -match '^DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP=' }) | Should -Be @(
                "DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP=skip"
            )
            $runnerText = Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\invoke-release-e2e.ps1") -Raw -Encoding UTF8
            $runnerText | Should -Match '(?s)Copy-Item.*?Set-E2EDotEnvValue.*?DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP.*?skip.*?initialize-dev-branch-runtime'
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "proves helper overlap from timestamps captured before process handles go stale" {
        $tokens = $null
        $errors = $null
        $runnerPath = Join-Path $RepoRoot "scripts\invoke-release-e2e.ps1"
        $runnerAst = [System.Management.Automation.Language.Parser]::ParseFile(
            $runnerPath,
            [ref]$tokens,
            [ref]$errors
        )
        @($errors) | Should -BeNullOrEmpty
        $functionAst = $runnerAst.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq "Test-E2EInvocationOverlap"
        }, $true)
        . ([scriptblock]::Create($functionAst.Extent.Text))

        $origin = [DateTime]::UtcNow
        Test-E2EInvocationOverlap -Invocations @(
            [pscustomobject]@{ process = $null; startedAtUtc = $origin; exitedAtUtc = $origin.AddSeconds(10) },
            [pscustomobject]@{ process = $null; startedAtUtc = $origin.AddSeconds(5); exitedAtUtc = $origin.AddSeconds(15) }
        ) | Should -BeTrue
        Test-E2EInvocationOverlap -Invocations @(
            [pscustomobject]@{ process = $null; startedAtUtc = $origin; exitedAtUtc = $origin.AddSeconds(5) },
            [pscustomobject]@{ process = $null; startedAtUtc = $origin.AddSeconds(5); exitedAtUtc = $origin.AddSeconds(10) }
        ) | Should -BeFalse
        Test-E2EInvocationOverlap -Invocations @(
            [pscustomobject]@{ process = $null; startedAtUtc = $origin; exitedAtUtc = $null },
            [pscustomobject]@{ process = $null; startedAtUtc = $origin; exitedAtUtc = $origin.AddSeconds(1) }
        ) | Should -BeFalse

        $runnerText = Get-Content -LiteralPath $runnerPath -Raw -Encoding UTF8
        $runnerText | Should -Match 'startedAtUtc\s*=\s*\$startedAtUtc'
        $runnerText | Should -Match '\$Invocation\.exitedAtUtc\s*=\s*\$exitedAtUtc'
        $functionAst.Extent.Text | Should -Not -Match '\.process|StartTime|ExitTime|\.Refresh\('
    }

    It "removes a closed disposable worktree before deleting its branch" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-release-seed-cleanup-" + [guid]::NewGuid().ToString("N"))
        $mainRoot = Join-Path $tempRoot "main"
        $worktreeRoot = Join-Path $tempRoot "worktree"
        $branch = "itldev/release-seed-cleanup"
        try {
            New-Item -ItemType Directory -Force -Path $mainRoot | Out-Null
            & git -C $mainRoot init *> $null
            & git -C $mainRoot config user.email "test@example.invalid"
            & git -C $mainRoot config user.name "ITL Test"
            Set-Content -LiteralPath (Join-Path $mainRoot "README.md") -Encoding ASCII -Value "fixture"
            & git -C $mainRoot add .
            & git -C $mainRoot commit -m "fixture" *> $null
            & git -C $mainRoot branch -M master
            & git -C $mainRoot worktree add --quiet -b $branch $worktreeRoot *> $null
            $LASTEXITCODE | Should -Be 0

            $tokens = $null
            $errors = $null
            $runnerAst = [System.Management.Automation.Language.Parser]::ParseFile(
                (Join-Path $RepoRoot "scripts\invoke-release-e2e.ps1"),
                [ref]$tokens,
                [ref]$errors
            )
            @($errors) | Should -BeNullOrEmpty
            $functionAst = $runnerAst.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq "Remove-E2ESeedDisposableBranch"
            }, $true)
            . ([scriptblock]::Create($functionAst.Extent.Text))
            function Invoke-E2EHelperAtRoot { }

            $cleanupErrors = New-Object System.Collections.Generic.List[string]
            $spec = [pscustomobject]@{ root = $worktreeRoot; name = "release-seed-cleanup"; branch = $branch }
            Remove-E2ESeedDisposableBranch -MainRoot $mainRoot -Spec $spec -CleanupErrors $cleanupErrors

            $cleanupErrors.Count | Should -Be 0
            Test-Path -LiteralPath $worktreeRoot | Should -BeFalse
            & git -C $mainRoot show-ref --verify --quiet "refs/heads/$branch"
            $LASTEXITCODE | Should -Be 1
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "restores the seed probe while the main worktree is already on master" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-release-seed-main-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            & git -C $tempRoot init *> $null
            & git -C $tempRoot config user.email "test@example.invalid"
            & git -C $tempRoot config user.name "ITL Test"
            Set-Content -LiteralPath (Join-Path $tempRoot "README.md") -Encoding ASCII -Value "baseline"
            & git -C $tempRoot add .
            & git -C $tempRoot commit -m "baseline" *> $null
            & git -C $tempRoot branch -M master
            $baselineCommit = (& git -C $tempRoot rev-parse HEAD).Trim()
            Add-Content -LiteralPath (Join-Path $tempRoot "README.md") -Encoding ASCII -Value "probe"
            & git -C $tempRoot add .
            & git -C $tempRoot commit -m "probe" *> $null

            $tokens = $null
            $errors = $null
            $runnerAst = [System.Management.Automation.Language.Parser]::ParseFile(
                (Join-Path $RepoRoot "scripts\invoke-release-e2e.ps1"),
                [ref]$tokens,
                [ref]$errors
            )
            @($errors) | Should -BeNullOrEmpty
            $functionAst = $runnerAst.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq "Restore-E2ESeedMainBranch"
            }, $true)
            . ([scriptblock]::Create($functionAst.Extent.Text))

            $cleanupErrors = New-Object System.Collections.Generic.List[string]
            Restore-E2ESeedMainBranch -MainRoot $tempRoot -MasterBranch "master" -MasterAfterSync $baselineCommit -CleanupErrors $cleanupErrors

            $cleanupErrors.Count | Should -Be 0
            (& git -C $tempRoot branch --show-current).Trim() | Should -Be "master"
            (& git -C $tempRoot rev-parse HEAD).Trim() | Should -Be $baselineCommit
            @(& git -C $tempRoot status --porcelain).Count | Should -Be 0
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
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
        $env:ITL_TEST_RELEASE_ONDEMAND_PROBE = "true"
        $env:ITL_TEST_RELEASE_SEED_PARALLEL = "true"
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
            Set-Content -LiteralPath (Join-Path $mainRoot ".gitignore") -Encoding ASCII -Value ".agent-1c/dev-branches/`n.agent-1c/runs/`n.agent-1c/release-e2e-actions.log`n.agent-1c/release-e2e-partial-list.txt`n.agents/`nbuild/`n"
            Set-Content -LiteralPath (Join-Path $mainRoot "README.md") -Encoding ASCII -Value "fixture"
            New-Item -ItemType Directory -Force -Path (Join-Path $mainRoot "src\cf\Ext"), (Join-Path $mainRoot ".agent-1c") | Out-Null
            $dependencyLock = [ordered]@{
                schemaVersion = 1
                mode = "fresh"
                dependencies = [ordered]@{
                    vanessaAutomation = [ordered]@{ source = "fixture-original" }
                }
            }
            Set-Content -LiteralPath (Join-Path $mainRoot ".agent-1c\dependency-lock.json") -Encoding UTF8 -Value ($dependencyLock | ConvertTo-Json -Depth 6)
            Set-Content -LiteralPath (Join-Path $mainRoot "src\cf\Configuration.xml") -Encoding UTF8 -Value @'
<?xml version="1.0" encoding="UTF-8"?>
<MetaDataObject>
  <Configuration>
    <Properties><Comment>fixture</Comment></Properties>
  </Configuration>
</MetaDataObject>
'@
            Set-Content -LiteralPath (Join-Path $mainRoot "src\cf\ConfigDumpInfo.xml") -Encoding UTF8 -Value "<ConfigDumpInfo>fixture</ConfigDumpInfo>"
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
                unsafeActionProtectionResolution = "branch-confirmed"
                unsafeActionProtectionConfirmed = $true
                unsafeActionProtectionConfirmedAt = "2026-07-24T00:00:00Z"
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
        if (($releaseCheckCount -lt 3 -and $VanessaFilterTags -ne "@itl_release_flat") -or ($releaseCheckCount -eq 3 -and $VanessaFilterTags)) { throw "release E2E must leave only the final canonical recovery run unfiltered" }
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
            $summary.maxConcurrentSessions | Should -Be 3
            $summary.ownedProcessExitWaitMs | Should -BeLessOrEqual 15000
            $summary.onDemandMcpTestFixture | Should -BeTrue
            $summary.seedParallelTestFixture | Should -BeTrue
            $summary.seedParallelBranchRuntimeConcurrent | Should -BeTrue
            $summary.seedParallelLiteRefreshConcurrent | Should -BeTrue
            $summary.seedParallelLiteRefreshSourceCallCount | Should -Be 0
            $summary.seedParallelTargetMasterCommit | Should -Match '^[a-f0-9]{40}$'
            $summary.extensionSmokeName | Should -Match '^ITLReleaseSmoke\d{14}$'
            $summary.cleanupFailures.Count | Should -Be 0
            $actions = Get-Content -LiteralPath (Join-Path $worktreeRoot ".agent-1c\release-e2e-actions.log") -Encoding UTF8
            $actions | Should -Contain "release-e2e-config-roundtrip"
            $actions | Should -Contain "release-e2e-extension-smoke"
            $actions | Should -Contain "release-e2e-prepare-ondemand"
            $actions | Should -Contain "stop-dev-branch-test-clients"
            @($actions | Where-Object { $_ -eq "check-dev-branch" }).Count | Should -Be 3
            $actions | Should -Not -Contain "release-e2e-approve-vanessa-fixture"
            @($actions | Where-Object { $_ -eq "release-e2e-config-roundtrip" }).Count | Should -Be 1
            @(& git -C $worktreeRoot status --porcelain).Count | Should -Be 0

            # Simulate a same-input workflow release: capability proofs reuse,
            # while verification/export/cleanup execute again and persist fresh
            # post-config state.
            $checkpointPath = Join-Path $worktreeRoot ".agent-1c\runs\release-e2e\workflow-release-e2e\checkpoint.json"
            $promotionCheckpoint = Get-Content -LiteralPath $checkpointPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $promotionCheckpoint.identity.workflowCommit = "1111111111111111111111111111111111111111"
            $postConfigStatePath = [string]$promotionCheckpoint.stateFiles.postConfig.stateCopyPath
            $postConfigState = Get-Content -LiteralPath $postConfigStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $postConfigState.unsafeActionProtectionConfirmed = $false
            $postConfigState.unsafeActionProtectionConfirmedAt = ""
            [System.IO.File]::WriteAllText($postConfigStatePath, (($postConfigState | ConvertTo-Json -Depth 16) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
            $promotionCheckpoint.stateFiles.postConfig.stateSha256 = (Get-FileHash -LiteralPath $postConfigStatePath -Algorithm SHA256).Hash.ToLowerInvariant()
            [System.IO.File]::WriteAllText($checkpointPath, (($promotionCheckpoint | ConvertTo-Json -Depth 16) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
            $promotionSummaryPath = Join-Path $tempRoot "promotion-summary.json"
            & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot "scripts\invoke-release-e2e.ps1") `
                -ProjectRoot $mainRoot -AiRulesSource $aiRulesRoot -HelperPath $helperPath -OutputPath $promotionSummaryPath -ResumeMode Auto
            $LASTEXITCODE | Should -Be 0
            $promotionSummary = Get-Content -LiteralPath $promotionSummaryPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $promotionSummary.crossReleaseReuse | Should -BeTrue
            foreach ($stageName in @("seed-parallel", "config-cadence", "config-roundtrip", "extension-smoke", "ondemand-mcp")) {
                $promotionSummary.stages.$stageName.execution | Should -Be "reused"
            }
            @($promotionSummary.executedStages) | Should -Contain "verification-refresh"
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
            foreach ($relative in @("scripts\invoke-release-e2e.ps1", "scripts\Build-ItlOnDemandMcp.ps1", "templates\dependency-lock.json")) {
                Copy-Item -LiteralPath (Join-Path $RepoRoot $relative) -Destination (Join-Path $workflowFixtureRoot $relative) -Force
            }
            & git -C $workflowFixtureRoot add --all
            & git -C $workflowFixtureRoot commit --allow-empty -m "test: use current capability-cache runner" *> $null
            $LASTEXITCODE | Should -Be 0
            (Get-FileHash -LiteralPath (Join-Path $workflowFixtureRoot "scripts\invoke-release-e2e.ps1") -Algorithm SHA256).Hash | Should -Be (Get-FileHash -LiteralPath (Join-Path $RepoRoot "scripts\invoke-release-e2e.ps1") -Algorithm SHA256).Hash
            $candidateOnDemandPath = Join-Path $workflowFixtureRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.ondemand-mcp.ps1"
            Add-Content -LiteralPath $candidateOnDemandPath -Encoding UTF8 -Value "# release candidate managed-package advance"
            & git -C $workflowFixtureRoot add -- ".agents/skills/1c-workflow/scripts/lib/agent-1c.ondemand-mcp.ps1"
            & git -C $workflowFixtureRoot commit -m "test: advance only managed on-demand helper" *> $null
            $LASTEXITCODE | Should -Be 0
            @(& git -C $workflowFixtureRoot diff-tree --no-commit-id --name-only -r HEAD) | Should -Be @(".agents/skills/1c-workflow/scripts/lib/agent-1c.ondemand-mcp.ps1")
            $installedOnDemandPath = Join-Path $worktreeRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.ondemand-mcp.ps1"
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $installedOnDemandPath) | Out-Null
            Copy-Item -LiteralPath $candidateOnDemandPath -Destination $installedOnDemandPath -Force
            (Get-FileHash -LiteralPath $installedOnDemandPath -Algorithm SHA256).Hash | Should -Be (Get-FileHash -LiteralPath $candidateOnDemandPath -Algorithm SHA256).Hash
            $checkpointBeforeManagedAdvance = Get-Content -LiteralPath $checkpointPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $managedAdvanceSummaryPath = Join-Path $tempRoot "managed-advance-summary.json"
            & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $workflowFixtureRoot "scripts\invoke-release-e2e.ps1") `
                -ProjectRoot $mainRoot -AiRulesSource $aiRulesRoot -HelperPath $helperPath -OutputPath $managedAdvanceSummaryPath -ResumeMode Auto
            $LASTEXITCODE | Should -Be 0
            $managedAdvanceSummary = Get-Content -LiteralPath $managedAdvanceSummaryPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $managedAdvanceSummary.crossReleaseReuse | Should -BeTrue
            foreach ($stageName in @("seed-parallel", "config-cadence", "config-roundtrip", "extension-smoke")) {
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
                $corruptEvidenceOutput = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot "scripts\invoke-release-e2e.ps1") `
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
                $upgradeOutput = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot "scripts\invoke-release-e2e.ps1") `
                    -ProjectRoot $mainRoot -AiRulesSource $aiRulesRoot -HelperPath $helperPath -OutputPath (Join-Path $tempRoot "upgrade-required.json") -ResumeMode Auto 2>&1
                $upgradeExitCode = $LASTEXITCODE
            } finally { $ErrorActionPreference = $previousPreference }
            $upgradeExitCode | Should -Not -Be 0
            ($upgradeOutput -join [Environment]::NewLine) | Should -Match "RELEASE_E2E_CHECKPOINT_UPGRADE_REQUIRED"
            [System.IO.File]::WriteAllText($checkpointPath, $checkpointV2Text, [System.Text.UTF8Encoding]::new($false))

            # Auto keeps only exact stage fingerprints across a new release.
            Add-Content -LiteralPath $helperPath -Encoding UTF8 -Value "# changed helper identity"
            $incrementalSummaryPath = Join-Path $tempRoot "incremental-summary.json"
            & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot "scripts\invoke-release-e2e.ps1") `
                -ProjectRoot $mainRoot -AiRulesSource $aiRulesRoot -HelperPath $helperPath -OutputPath $incrementalSummaryPath -ResumeMode Auto
            $LASTEXITCODE | Should -Be 0
            $incrementalSummary = Get-Content -LiteralPath $incrementalSummaryPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $incrementalSummary.crossReleaseReuse | Should -BeTrue
            @($incrementalSummary.invalidatedStages) | Should -Contain "config-cadence"
            $incrementalSummary.stages.'verification-refresh'.execution | Should -Be "reused"
            $incrementalSummary.stages.'verification-refresh'.reuseReason | Should -Match "current config-cadence"
            @($incrementalSummary.executedStages) | Should -Contain "result-cleanup"

            # Restart is the explicit destructive rollback path. It must accept
            # a clean externally advanced branch HEAD, while Auto above remains
            # fail-closed for identity or expected-HEAD drift.
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
            $env:ITL_TEST_RELEASE_SEED_PARALLEL = $oldSeedParallelFixture
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
