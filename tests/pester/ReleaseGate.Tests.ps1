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
        $e2eText | Should -Match "run_scenario:cold.*get_VanessaAutomation_state:cold.*get_test_results:cold.*run_scenario:hot.*run_scenario:from-line-cold.*open_feature_file:secondary.*select_scenario:secondary.*run_scenario:selected"
        $e2eText | Should -Match 'vanessa-secondary-feature'
        (Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\release-e2e\ondemand-mcp.ps1") -Raw -Encoding UTF8) | Should -Match 'ondemand-mcp" -Version 3'
        $e2eText | Should -Not -Match "load_features:directory"
        $e2eText | Should -Match "clientMcpSafeMode"
        $e2eText | Should -Match "vaExtensionSafeMode"
        $e2eText | Should -Match "vanessaAutomationArchiveSha256"
        $e2eText | Should -Match ([regex]::Escape('FromBase64String("VmFuZXNzYSDQv9GD0YLRjCDRgSDQv9GA0L7QsdC10LvQsNC80Lg=")'))
        $e2eText | Should -Match ([regex]::Escape('FromBase64String("I2xhbmd1YWdlOiBydQoK0KTRg9C90LrRhtC40L7QvdCw0Ls6IFZhbmVzc2EgVUkgTUNQIGNvbGQgcGF0aCBBCgrQodGG0LXQvdCw0YDQuNC5OiBNQ1AgY29sZCBBCgnQmCDQn9Cw0YPQt9CwIDAuMQo=")'))
        $e2eText | Should -Not -Match 'Функционал: Vanessa UI MCP cold path'
        $e2eText | Should -Match '\$vanessaSmokeEvidenceRoot = Join-Path \$worktreePath "build\\test-results\\release-e2e"'
        $e2eText | Should -Not -Match '\$vanessaSmokeDirectory = Join-Path \$outputRoot'
        ([regex]::Matches($e2eText, 'Invoke-E2EHelper -Action "check-dev-branch"')).Count | Should -Be 4
        $e2eText | Should -Not -Match 'release-e2e-approve-vanessa-fixture'
        $e2eText | Should -Match 'RELEASE_E2E_RESUME_STATE_MISMATCH'
        $e2eText | Should -Match 'Restore-E2EInfobaseSnapshot'
        $e2eText | Should -Match '\$actualStatePath = \[string\]\(Get-E2EState\)\.path'
        $e2eText | Should -Match '\$actualEnvPath = Join-Path \$worktreePath "\.dev\.env"'
        $e2eText | Should -Not -Match 'Destination \(\[string\]\$Record\.actualEnvPath\)'
        $e2eText | Should -Match 'runnerSha256'
        $e2eText | Should -Match 'Get-E2ECanonicalTextSha256 -Path \$PSCommandPath'
        $e2eText | Should -Match 'Get-E2ECanonicalTextSha256 -Path \$path'
        $e2eText | Should -Match 'Get-E2EStageFingerprint'
        $e2eText | Should -Match 'Get-WorkflowContinuationProof'
        $e2eText | Should -Match 'previousRunnerSha256'
        $e2eText | Should -Match 'continuationBoundaryStage'
        $e2eText | Should -Match 'exact Targeted continuation after completed release'
        $e2eText | Should -Match '\$verificationRefreshPassed = Test-E2EStagePassed -Name "verification-refresh"'
        $e2eText | Should -Match 'if \(\(\$executedStages -contains "config-cadence"\) -or \$crossReleaseReuse -or -not \$verificationRefreshPassed\)'
        $e2eText | Should -Match '(?s)Set-E2EStageStatus -Name "verification-refresh" -Status "running".*?Invoke-E2EHelper -Action "check-dev-branch" -TimeoutSeconds 7200 -AdditionalArguments @\(\s*"-ConfigLoadMode", "Full"'
        $resultCleanupBlock = [regex]::Match($e2eText, '(?s)\$resultPassed = Test-E2EStagePassed -Name "result-cleanup".*?\n\s*\$sealedCapabilityPath =').Value
        $resultCleanupBlock | Should -Match 'Invoke-E2EHelper -Action "status" -TimeoutSeconds 120\s*\r?\n'
        $resultCleanupBlock | Should -Match 'Invoke-E2EHelper -Action "export-dev-branch-result" -TimeoutSeconds 7200\s*\| Out-Null'
        $resultCleanupBlock | Should -Not -Match 'VanessaFeaturePath'
        $e2eText | Should -Not -Match 'if \(\$crossReleaseReuse -and \$executedStages -notcontains "config-cadence"\)'
        $e2eText | Should -Match 'if \(\$checkpointWasResumed\) \{ \$resultPassed = \$false'
        $e2eText | Should -Match 'RELEASE_E2E_CHECKPOINT_UPGRADE_REQUIRED'
        $e2eText | Should -Match 'RELEASE_E2E_CACHE_CORRUPT'
        $e2eText | Should -Match 'workflowTree'
        $e2eText | Should -Match 'Register-E2EGeneratedCommit'
        $e2eText | Should -Match 'Sync-E2EWorktreeFromMaster'
        $e2eText | Should -Match 'Invoke-E2EHelper -Action "refresh-dev-branch"'
        $e2eText | Should -Match '\$generatedCommitRecords = @\(Get-E2EGeneratedCommitRecords -Value \$cache\["generatedCommits"\]\)'
        $e2eText | Should -Match 'RELEASE_E2E_CACHE_CORRUPT: generated commit record has no commit SHA'
        $e2eText | Should -Match 'Get-E2EGeneratedCommitRecords -Value \$cache\["generatedCommits"\]'
        $e2eText | Should -Match 'Action "refresh-all-dev-branches"'
        $e2eText | Should -Match '\[IO\.File\]::WriteAllText\(\$probePath, "ITL Release seed parallel`r`n"'
        $e2eText | Should -Not -Match '\[IO\.File\]::WriteAllText\(\$probePath, "ITL Release seed parallel \$suffix'
        $e2eText | Should -Match 'Action "reset-dev-branch"'
        $e2eText | Should -Match 'Action "release-e2e-config-repository-lock-roundtrip"'
        $e2eText | Should -Match 'New-E2ERepositoryLockProbeCommit -Root \$worktreeB'
        $e2eText | Should -Match 'LogPrefix "seed-parallel-repository-lock-cleanup"'
        $e2eText | Should -Match 'RELEASE_E2E_CONFIG_REPOSITORY_CLEANUP_FAILED:'
        $e2eText | Should -Match 'Primary failure: \$\(\$repositoryLockError\.Exception\.Message\)'
        $e2eText | Should -Not -Match 'AppendAllText\(\$configurationPathB'
        $e2eText | Should -Match 'Primary failure: \$proofError'
        $seedStageText = Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\release-e2e\seed-parallel.ps1") -Raw -Encoding UTF8
        $seedStageText | Should -Match 'seed-parallel" -Version 5'
        $seedStageText | Should -Match 'src/cf/CommonModules/\[\^/\]\+/Ext/Module\\\.bsl'
        $seedStageText | Should -Match 'Get-RepositoryGitPathList.*"-z"'
        $seedStageText | Should -Not -Match 'tests/'
        $serverResetStageText = Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\release-e2e\server-reset.ps1") -Raw -Encoding UTF8
        $serverResetStageText | Should -Match 'server-reset" -Version 1 -Paths'
        $serverResetStageText | Should -Not -Match 'DependsOn'
        $e2eText | Should -Match 'Invoke-E2EServerResetProof'
        $e2eText | Should -Match 'serverProjectRoot'
        $e2eText | Should -Match '(?s)Set-E2EStageStatus -Name "seed-parallel" -Status "passed".*?Test-E2EStagePassed -Name "server-reset"'
        $e2eText | Should -Match 'Set-E2EStageStatus -Name "server-reset" -Status "failed" -ErrorText \$_\.Exception\.Message'
        $e2eText | Should -Match '(?s)\$stageConfiguration = if \(\$Name -eq "server-reset"\).*?serverProjectRoot = Get-E2EReleaseConfigValue.*?stageConfiguration = \$stageConfiguration'
        $e2eText | Should -Match '(?s)if \(-not \$seedParallelTestFixture\).*?Assert-E2EServerResetStandConfigured.*?Test-E2EStagePassed -Name "seed-parallel"'
        $lifecycleSource = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.lifecycle.ps1") -Raw -Encoding UTF8
        $lifecycleSource | Should -Match '/ConfigurationRepositoryLock'
        $lifecycleSource | Should -Match '/ConfigurationRepositoryUnLock'
        $lifecycleSource | Should -Match '\$Operation, "-Objects", \$ObjectListPath'
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
        $developE2eText | Should -Match 'DEVELOP_E2E_ISOLATED_STAND_REQUIRED'
        $developE2eText | Should -Match 'developDevBranchName'
        $developE2eText | Should -Match 'developWorktreePath'
        $developE2eText | Should -Match 'Develop and Release worktree paths must differ'
        $developE2eText | Should -Match '(?s)Invoke-InstalledAction -Name "upgrade-refresh-branch".*?Set-DevelopStandVanessaFeature -Root \$standBranchRoot.*?Invoke-InstalledAction -Name "upgrade-check"'
    }

    It "owns and idempotently commits the upgrade-journey Vanessa fixture" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-develop-feature-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            & git -C $tempRoot init *> $null
            & git -C $tempRoot config user.email "test@example.invalid"
            & git -C $tempRoot config user.name "ITL Test"
            Set-Content -LiteralPath (Join-Path $tempRoot "README.md") -Encoding ASCII -Value "fixture"
            & git -C $tempRoot add README.md
            & git -C $tempRoot commit -m "fixture" *> $null

            $tokens = $null
            $errors = $null
            $runnerAst = [System.Management.Automation.Language.Parser]::ParseFile(
                (Join-Path $RepoRoot "scripts\invoke-develop-e2e.ps1"),
                [ref]$tokens,
                [ref]$errors
            )
            @($errors) | Should -BeNullOrEmpty
            foreach ($functionName in @("Add-FreshVanessaFeature", "Set-DevelopStandVanessaFeature")) {
                $functionAst = $runnerAst.Find({
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -eq $functionName
                }, $true)
                . ([scriptblock]::Create($functionAst.Extent.Text))
            }

            Set-DevelopStandVanessaFeature -Root $tempRoot
            $firstHead = (& git -C $tempRoot rev-parse HEAD).Trim()
            & git -C $tempRoot ls-files --error-unmatch -- tests/features/ITLDevelopJourney.feature *> $null
            $LASTEXITCODE | Should -Be 0
            (& git -C $tempRoot log -1 --pretty=%s).Trim() | Should -Be "test: seed develop E2E Vanessa fixture"
            @(& git -C $tempRoot status --porcelain).Count | Should -Be 0

            Set-DevelopStandVanessaFeature -Root $tempRoot
            (& git -C $tempRoot rev-parse HEAD).Trim() | Should -Be $firstHead
            @(& git -C $tempRoot status --porcelain).Count | Should -Be 0
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "routes Develop E2E upgrade and fresh journeys independently and reports schema 2 state" {
        $path = Join-Path $RepoRoot "scripts\invoke-develop-e2e.ps1"
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
        @($errors) | Should -BeNullOrEmpty
        $journeyParameter = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq "Journey" }
        $journeyParameter | Should -Not -BeNullOrEmpty
        $journeyParameter.DefaultValue.SafeGetValue() | Should -Be "all"
        @($journeyParameter.Attributes | Where-Object TypeName -match "ValidateSet" | Select-Object -ExpandProperty PositionalArguments | ForEach-Object SafeGetValue) | Should -Be @("upgrade", "fresh", "all")

        $text = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        $text | Should -Match '\$requestedJourneys = if \(\$Journey -eq "all"\) \{ @\("upgrade", "fresh"\) \} else \{ @\(\$Journey\) \}'
        $text | Should -Match 'if \(\$requestedJourneys -contains "upgrade"\)'
        $text | Should -Match 'if \(\$requestedJourneys -contains "fresh"\)'
        $text | Should -Match '(?s)if \(\$requestedJourneys -contains "upgrade"\).*?Invoke-InstalledAction -Name "upgrade-update-workflow".*?\$journeys\.upgrade\.status = "passed"'
        $text | Should -Match '(?s)if \(\$requestedJourneys -contains "fresh"\).*?Invoke-DevelopProcess -Name "fresh-bootstrap-init-project".*?\$journeys\.fresh\.status = "passed"'
        $text | Should -Match 'schemaVersion = 2'
        foreach ($field in @("requestedJourneys", "journeys", "activeJourney", "steps", "operationTimings", "error")) {
            $text | Should -Match ([regex]::Escape($field + " ="))
        }
        $text | Should -Match '\$journeys\[\$activeJourney\]\.status = "failed"'
        $text | Should -Match 'Remove-DevelopE2EFreshProject -FreshProjectsRoot \$FreshProjectsRoot -Path \$freshRoot -BranchPath \$freshBranchRoot'

        $check = Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\check.ps1") -Raw -Encoding UTF8
        $check | Should -Match 'Resolve-DevelopE2EJourneyPlan -RepositoryRoot \$repoRoot -BaseRef \$BaseRef'
        $check | Should -Match '\$exactDevelopProof = Test-DevelopQualification -Commit \$commit -Tree \$tree -FullProof \$developFullProof'
        $check | Should -Match 'Add-ReusedStage -Name "develop-e2e" -Reason "exact route-aware Develop qualification"'
        $check | Should -Match '(?s)if \(\$exactDevelopProof.*?\) \{.*?exact route-aware Develop qualification.*?\} else \{\s*\$developPlan = Resolve-DevelopE2EJourneyPlan'
        $check | Should -Not -Match '\$plannedJourneys = \$allJourneys'
        $check | Should -Match 'DEVELOP_E2E_CONTINUATION_REQUIRED: an unowned journey has no valid prior proof; refusing to widen the routed plan'
        $check | Should -Match '\$routeIdentitySha256 = if \(\$continued\) \{ \[string\]\$record\.identitySha256 \}'
        $check | Should -Match '\$baselineRouteIdentitySha256 = if \(\[string\]\$record\.execution -eq "continued"\) \{ \[string\]\$record\.identitySha256 \}'
        $check | Should -Match 'IdentitySha256 \$baselineRouteIdentitySha256 -StandStateSha256 \$developStandStateSha256'
        $check | Should -Match 'if \(-not \$BaseRef\) \{ throw "Develop E2E requires BaseRef'
        $check | Should -Match 'Restore-DevelopE2EQualification .*?-Journey \$journey -IdentitySha256 \$developIdentitySha256'
        $check | Should -Match 'Save-DevelopE2EQualification .*?-Journey \$journey -IdentitySha256 \$developIdentitySha256'
        $check | Should -Match 'schemaVersion = 3'
        $check | Should -Match 'execution = "continued"'
        $check | Should -Match 'ExpectedIdentitySha256'
        $check | Should -Match 'ExpectedStandStateSha256'
        $check | Should -Match 'Get-DevelopE2EStandStateSha256 -ProjectRoot \$E2EProjectRoot'
        $check | Should -Match 'Get-DevelopE2EIdentitySha256 -ReleaseContext \$releaseContext'
        $check | Should -Match 'Resolve-DevelopE2EJourneyPlan -RepositoryRoot \$repoRoot -ChangedPath @\(\$continuation\.paths\)'
    }

    It "records backward-compatible structured timings for fresh journey operations" {
        $path = Join-Path $RepoRoot "scripts\invoke-develop-e2e.ps1"
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
        @($errors) | Should -BeNullOrEmpty
        $functionAst = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Invoke-DevelopTimedOperation"
        }, $true)
        $functionAst | Should -Not -BeNullOrEmpty
        . ([scriptblock]::Create($functionAst.Extent.Text))

        $timings = New-Object System.Collections.Generic.List[object]
        (Invoke-DevelopTimedOperation -Timings $timings -Name "fixture-pass" -Operation { "result" }) | Should -Be "result"
        $timings.Count | Should -Be 1
        $timings[0].name | Should -Be "fixture-pass"
        $timings[0].status | Should -Be "passed"
        $timings[0].startedAt | Should -Not -BeNullOrEmpty
        $timings[0].finishedAt | Should -Not -BeNullOrEmpty
        [int64]$timings[0].durationMs | Should -BeGreaterOrEqual 0
        $timings[0].error | Should -BeNullOrEmpty

        { Invoke-DevelopTimedOperation -Timings $timings -Name "fixture-fail" -Operation { throw "timed failure" } } | Should -Throw "*timed failure*"
        $timings.Count | Should -Be 2
        $timings[1].status | Should -Be "failed"
        $timings[1].error | Should -Be "timed failure"

        $text = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        $text | Should -Match 'schemaVersion = 2'
        $text | Should -Match '(?s)if \(\$requestedJourneys -contains "fresh"\).*?\$freshTimings = \$journeys\.fresh\.operationTimings.*?Invoke-DevelopTimedOperation -Timings \$freshTimings -Name "provision-project".*?Invoke-DevelopTimedOperation -Timings \$freshTimings -Name "close-and-cleanup"'
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

    It "does not overwrite the Designer fingerprint invalidation after a release snapshot restore" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-release-restore-order-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            $snapshotPath = Join-Path $tempRoot "snapshot.dt"
            Set-Content -LiteralPath $snapshotPath -Value "fixture"

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
                $node.Name -eq "Restore-E2EInfobaseSnapshot"
            }, $true)
            . ([scriptblock]::Create($functionAst.Extent.Text))

            $script:worktreePath = $tempRoot
            $calls = [System.Collections.Generic.List[string]]::new()
            function Assert-E2ECheckpointFile { param($Path, $Sha256, $Label) }
            function Restore-E2EStateFiles { param($Record) $calls.Add("state") }
            function Invoke-E2EHelper { param($Action, $TimeoutSeconds, $AdditionalArguments) $calls.Add("helper:$Action") }

            Restore-E2EInfobaseSnapshot `
                -Snapshot ([pscustomobject]@{ path = $snapshotPath; sha256 = "fixture" }) `
                -StateFiles ([pscustomobject]@{})

            @($calls) | Should -Be @("state", "helper:release-e2e-restore")
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
            Set-Content -LiteralPath (Join-Path $mainRoot ".gitignore") -Encoding ASCII -Value ".agent-1c/dev-branches/`n.agent-1c/runs/`n.agent-1c/snapshots/`n.agent-1c/release-e2e-actions.log`n.agent-1c/release-e2e-partial-list.txt`n.agents/`nbuild/`n"
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
                worktreePath = $worktreeRoot
                unsafeActionProtectionResolution = "branch-confirmed"
                unsafeActionProtectionConfirmed = $true
                unsafeActionProtectionConfirmedAt = "2026-07-24T00:00:00Z"
                lastVerificationStatus = "missing"
            }
            Set-Content -LiteralPath (Join-Path $worktreeRoot ".agent-1c\dev-branches\workflow-release-e2e.json") -Encoding UTF8 -Value ($state | ConvertTo-Json -Depth 6)
            Set-Content -LiteralPath $helperPath -Encoding UTF8 -Value @'
[CmdletBinding()]
param([string]$ProjectRoot, [string]$Action, [string]$DevBranchName, [string]$ExtensionName, [string]$ReleaseAiRulesSource, [string]$VanessaFeaturePath, [string]$VanessaFilterTags, [string]$ReleaseSnapshotPath, [switch]$PreserveReleaseSnapshotApplicationProof, [ValidateSet("Auto", "Partial", "Full")][string]$ConfigLoadMode = "Auto", [string]$InternalOnDemandOperation, [string]$InternalOnDemandFamily)
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
        if ($releaseCheckCount -gt 3 -and $ConfigLoadMode -ne "Full") { throw "release E2E verification refresh must establish a full configuration load" }
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

            # A missing server stand is rejected before any expensive stage.
            $preflightSummaryPath = Join-Path $tempRoot "server-preflight-failure-summary.json"
            $env:ITL_TEST_RELEASE_SEED_PARALLEL = "false"
            $previousPreference = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
            try {
                $preflightOutput = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot "scripts\invoke-release-e2e.ps1") `
                    -ProjectRoot $mainRoot -AiRulesSource $aiRulesRoot -HelperPath $helperPath -OutputPath $preflightSummaryPath 2>&1
                $preflightExitCode = $LASTEXITCODE
            } finally {
                $ErrorActionPreference = $previousPreference
                $env:ITL_TEST_RELEASE_SEED_PARALLEL = "true"
            }
            $preflightExitCode | Should -Not -Be 0
            Test-Path -LiteralPath $preflightSummaryPath -PathType Leaf | Should -BeTrue -Because ($preflightOutput -join [Environment]::NewLine)
            $preflightSummary = Get-Content -LiteralPath $preflightSummaryPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $preflightSummary.error | Should -Match '^RELEASE_E2E_SERVER_STAND_REQUIRED'
            @($preflightSummary.executedStages) | Should -BeNullOrEmpty

            # Fail between the file and server reset capabilities. The next run
            # must resume at server-reset without repeating seed-parallel.
            $serverFailureSummaryPath = Join-Path $tempRoot "server-reset-failure-summary.json"
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

            # Auto keeps only exact stage fingerprints across a new release.
            Add-Content -LiteralPath $helperPath -Encoding UTF8 -Value "# changed helper identity"
            $incrementalSummaryPath = Join-Path $tempRoot "incremental-summary.json"
            & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $workflowFixtureRoot "scripts\invoke-release-e2e.ps1") `
                -ProjectRoot $mainRoot -AiRulesSource $aiRulesRoot -HelperPath $helperPath -OutputPath $incrementalSummaryPath -ResumeMode Auto
            $LASTEXITCODE | Should -Be 0
            $incrementalSummary = Get-Content -LiteralPath $incrementalSummaryPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $incrementalSummary.crossReleaseReuse | Should -BeTrue
            @($incrementalSummary.invalidatedStages) | Should -Contain "config-cadence"
            $incrementalSummary.stages.'verification-refresh'.execution | Should -Be "executed"
            @($incrementalSummary.executedStages) | Should -Contain "verification-refresh"
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
            & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $workflowFixtureRoot "scripts\invoke-release-e2e.ps1") `
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
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
