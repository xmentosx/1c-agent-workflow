BeforeAll {
    . (Join-Path $PSScriptRoot "TestSupport.ps1")
    $context = Initialize-WorkflowPesterContext
    $RepoRoot = $context.RepoRoot
}

Describe "Release routing preflight" {
It "parses the local gate and E2E runner" {
        foreach ($relativePath in @("scripts\check.ps1", "scripts\invoke-develop-e2e.ps1", "scripts\invoke-release-e2e.ps1", "scripts\release-e2e\admission.ps1")) {
            $tokens = $null
            $errors = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile(
                (Join-Path $RepoRoot $relativePath),
                [ref]$tokens,
                [ref]$errors
            )
            @($errors) | Should -BeNullOrEmpty
        }
        $checkText = Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\check.ps1") -Raw -Encoding UTF8
        $e2eText = Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\invoke-release-e2e.ps1") -Raw -Encoding UTF8
        $admissionText = Get-Content -LiteralPath (Join-Path $RepoRoot 'scripts\release-e2e\admission.ps1') -Raw -Encoding UTF8
        $e2eText | Should -Match "FromBase64String"
        $e2eText | Should -Not -Match "Функционал: Четыре независимых"
        $e2eText | Should -Match '"-VanessaFeaturePath", \$vanessaFixture\.path'
        $e2eText | Should -Match "\`$authoringOutcome -ne `"passed`""
        $e2eText | Should -Not -Match "runner-fallback-required"
        $e2eText | Should -Match "run_scenario:cold.*get_vanessa_automation_state:cold.*get_test_results:cold.*run_scenario:hot.*run_scenario:from-line-cold.*open_feature_file:secondary.*select_scenario:secondary.*run_scenario:selected"
        $e2eText | Should -Match 'vanessa-secondary-feature'
        $e2eText | Should -Match 'publicToolCount = 2'
        $checkText | Should -Match 'onDemandRoctupPublicToolCount -ne 2'
        $probeText = Get-Content -LiteralPath (Join-Path $RepoRoot "tools\itl-ondemand-mcp\cmd\itl-ondemand-probe\main.go") -Raw -Encoding UTF8
        $probeText | Should -Match 'gatewayPublicToolCount = 2'
        $probeText | Should -Match 'item.count != gatewayPublicToolCount'
        (Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\release-e2e\ondemand-mcp.ps1") -Raw -Encoding UTF8) | Should -Match 'ondemand-mcp" -Version 6'
        $e2eText | Should -Match '"-verify-missing-state-recovery"'
        $probeText | Should -Match 'verifySessionMissingStateRecovery\(ctx, runtimeRoot, \*item.state'
        $recoveryProbeText = Get-Content -LiteralPath (Join-Path $RepoRoot 'tools\itl-ondemand-mcp\cmd\itl-ondemand-probe\missing_state.go') -Raw -Encoding UTF8
        $recoveryProbeText | Should -Match 'return verifyMissingStateRecovery\(ctx, root, current, call, exited\)'
        foreach ($predicate in @('passed', 'sameConnection', 'originalProcessesGone')) {
            $e2eText | Should -Match ([regex]::Escape('-not [bool]$familyEvidence.missingStateRecovery.' + $predicate))
        }
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
        $e2eText | Should -Match 'Resolve-QualityReleaseCapabilities -Catalog \$releaseStageCatalog -RequireRelease:\(\$requestedCapabilities.Count -eq 0\) -ReleaseCapability \$requestedCapabilities'
        $e2eText | Should -Match 'if \(Test-ReleaseE2ECapabilitySelected -Name "ondemand-mcp"\)'
        $checkText | Should -Match 'ReleaseCapabilities'
        ([regex]::Matches($checkText, '\$selectedReleaseCapabilities\s*=\s*@\(\$ReleaseCapabilities -split')).Count | Should -Be 1
        $checkText.IndexOf('$selectedReleaseCapabilities = @($ReleaseCapabilities -split') | Should -BeLessThan $checkText.IndexOf('Push-Location $repoRoot')
        $e2eText | Should -Match 'Get-WorkflowContinuationProof'
        $e2eText | Should -Match 'previousRunnerSha256'
        $e2eText | Should -Match 'continuationBoundaryStage'
        $e2eText | Should -Match 'Get-E2EAdmissionStageDecision -Name \$Name'
        $admissionText | Should -Match 'exact Targeted continuation after completed release'
        $e2eText | Should -Match '\$verificationRefreshPassed = Test-E2EStagePassed -Name "verification-refresh"'
        $e2eText | Should -Match 'invalidationDetails'
        $e2eText | Should -Match 'if \(\(\$executedStages -contains "config-cadence"\) -or \$crossReleaseReuse -or -not \$verificationRefreshPassed\)'
        $e2eText | Should -Match '(?s)Set-E2EStageStatus -Name "verification-refresh" -Status "running".*?Invoke-E2EHelper -Action "check-dev-branch" -TimeoutSeconds 7200 -AdditionalArguments @\(\s*"-ConfigLoadMode", "Auto"'
        $resultCleanupBlock = [regex]::Match($e2eText, '(?s)\$resultPassed = Test-E2EStagePassed -Name "result-cleanup".*?\n\s*\$sealedCapabilityPath =').Value
        $resultCleanupBlock | Should -Match 'Invoke-E2EHelper -Action "status" -TimeoutSeconds 120\s*\r?\n'
        $resultCleanupBlock | Should -Match 'Invoke-E2EHelper -Action "export-dev-branch-result" -TimeoutSeconds 7200\s*\| Out-Null'
        $resultCleanupBlock | Should -Not -Match 'VanessaFeaturePath'
        $e2eText | Should -Not -Match 'if \(\$crossReleaseReuse -and \$executedStages -notcontains "config-cadence"\)'
        $e2eText | Should -Match 'if \(\$checkpointWasResumed\) \{\s*\$resultPassed = \$false'
        $e2eText | Should -Match 'Get-E2EReleaseCheckpointAdmission -Context \$admissionContext -Checkpoint \$checkpoint'
        $admissionText | Should -Match 'RELEASE_E2E_CHECKPOINT_UPGRADE_REQUIRED'
        $e2eText | Should -Match 'RELEASE_E2E_CACHE_CORRUPT'
        $e2eText | Should -Match 'workflowTree'
        $e2eText | Should -Match 'Register-E2EGeneratedCommit'
        $e2eText | Should -Match 'git -C \$worktreePath diff --cached --quiet -- tests/features/ITLReleaseFourFlat.feature'
        $e2eText | Should -Match 'Sync-E2EWorktreeFromMaster'
        $e2eText | Should -Match 'release-preflight-sync-master'
        $e2eText | Should -Match 'Invoke-E2ESeedParallelProof -MainRoot .*? -PreflightMasterHead \$preflightSeedMasterHead'
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
        $e2eText | Should -Match '(?s)LogPrefix "seed-parallel-repository-lock-cleanup".*?\$stateB = Get-E2EBranchStateAtRoot -Root \$worktreeB -Name \$nameB.*?return \[ordered\]'
        $e2eText | Should -Match 'RELEASE_E2E_CONFIG_REPOSITORY_CLEANUP_FAILED:'
        $e2eText | Should -Match 'Primary failure: \$\(\$repositoryLockError\.Exception\.Message\)'
        $e2eText | Should -Not -Match 'AppendAllText\(\$configurationPathB'
        $e2eText | Should -Match 'Primary failure: \$proofError'
        $seedStageText = Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\release-e2e\seed-parallel.ps1") -Raw -Encoding UTF8
        $seedStageText | Should -Match 'seed-parallel" -Version 6'
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
        $e2eText | Should -Match 'serverProjectRoot = Get-E2EReleaseConfigValue'
        $e2eText | Should -Match 'Get-E2EAdmissionStageFingerprint -Context \(Get-E2EStageAdmissionContext\) -Name \$Name'
        $admissionText | Should -Match '(?s)\$stageConfiguration = if \(\$Name -eq ''server-reset''\) \{ \$Context.serverConfiguration \}.*?stageConfiguration = \$stageConfiguration'
        $e2eText | Should -Match '(?s)Test-ReleaseE2ECapabilitySelected -Name "server-reset"\) -and \$serverResetConfigured\).*?Assert-E2EServerResetStandConfigured.*?Test-ReleaseE2ECapabilitySelected -Name "seed-parallel"'
        $e2eText | Should -Match '(?s)\$seedParallelEvidence = Invoke-E2ESeedParallelProof.*?WriteAllText\(\s*\$seedParallelEvidencePath.*?if \(\[string\]\$seedParallelEvidence\.status'
        $e2eText | Should -Match '(?s)serverResetDisposition\.status -eq "unverified".*?status = "unverified".*?passed = \$false'
        $e2eText | Should -Match 'serverResetReason = \[string\]\(Get-E2ERecordValue'
        $e2eText | Should -Match 'seedParallelServerResetArchivePath = \[string\]\(Get-E2ERecordValue'
        $checkText | Should -Not -Match '-not \[bool\]\$e2eSummary\.seedParallelServerResetPassed -or'
        $checkText | Should -Match 'serverResetStatus -ne "unverified"'
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
        $developE2eText | Should -Match '(?s)Invoke-DevelopUpgradeRefresh -Name "upgrade-refresh-branch".*?Set-DevelopStandVanessaFeature -Root \$standBranchRoot.*?Invoke-DevelopPlannedCheck -Name "upgrade-check" -Root \$standBranchRoot'
    }

It "routes Develop E2E journeys independently and reports schema 3 with explicit executed coverage" {
        $path = Join-Path $RepoRoot "scripts\invoke-develop-e2e.ps1"
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
        @($errors) | Should -BeNullOrEmpty
        $journeyParameter = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq "Journey" }
        $journeyParameter | Should -Not -BeNullOrEmpty
        $journeyParameter.DefaultValue.SafeGetValue() | Should -Be "all"
        @($journeyParameter.Attributes | Where-Object TypeName -match "ValidateSet" | Select-Object -ExpandProperty PositionalArguments | ForEach-Object SafeGetValue) | Should -Be @("upgrade", "fresh", "all")

        $provision = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Invoke-DevelopTimedOperation' -and
                @($node.CommandElements | Where-Object { $_ -is [Management.Automation.Language.StringConstantExpressionAst] -and $_.Value -eq 'provision-project' }).Count -eq 1
        }, $true))
        $provision.Count | Should -Be 1
        $operation = @($provision[0].CommandElements | Where-Object { $_ -is [Management.Automation.Language.ScriptBlockExpressionAst] })
        $operation.Count | Should -Be 1
        & {
            # Execute the real entrypoint's imports as well as its extracted body.
            # This catches missing production wiring instead of supplying test-only helpers.
            $workflowScriptsRoot = Join-Path $RepoRoot 'scripts'
            foreach ($statement in $ast.EndBlock.Statements) {
                if ($statement -is [Management.Automation.Language.PipelineAst] -and
                    $statement.PipelineElements.Count -eq 1 -and
                    $statement.PipelineElements[0] -is [Management.Automation.Language.CommandAst] -and
                    $statement.PipelineElements[0].InvocationOperator -eq [Management.Automation.Language.TokenKind]::Dot) {
                    . ([scriptblock]::Create($statement.Extent.Text.Replace('$PSScriptRoot', '$workflowScriptsRoot')))
                }
            }
            $ProjectRoot = Join-Path $TestDrive 'Исходный стенд с пробелами'
            $freshTemplateRoot = $ProjectRoot
            $CandidateRoot = $RepoRoot; $AiRulesSource = $RepoRoot; $AgentTarget = 'kilocode'
            $outputRoot = Join-Path $TestDrive 'fresh proof'
            New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
            $freshSourceFixturePath = Join-Path $outputRoot 'fresh-source-fixture.json'
            $ownedSourceRoot = Join-Path $TestDrive 'owned source fixture'
            New-Item -ItemType Directory -Force -Path (Join-Path $ownedSourceRoot '.agent-1c') | Out-Null
            $ownedSourceDatabase = Join-Path $ownedSourceRoot 'owned base'
            $prepareCalls = New-Object Collections.Generic.List[object]
            function Invoke-DevelopProcess {
                param($Name,$WorkingRoot,$ScriptPath,$Arguments,$TimeoutSeconds)
                $prepareCalls.Add(@{name=$Name;script=$ScriptPath;arguments=$Arguments})
                [IO.File]::WriteAllText($freshSourceFixturePath, (@{projectRoot=$ownedSourceRoot;branchRoot=(Join-Path $ownedSourceRoot 'branch')}|ConvertTo-Json), [Text.UTF8Encoding]::new($false))
            }
            $FreshProjectsRoot = Join-Path $TestDrive 'Новые проекты с пробелами'
            $freshRoot = Join-Path $FreshProjectsRoot 'p Проект\новый'
            New-Item -ItemType Directory -Path (Join-Path $ProjectRoot '.agent-1c') -Force | Out-Null
            $sourceConfig = Join-Path $ProjectRoot '.agent-1c/project.json'
            $sourceEnv = Join-Path $ProjectRoot '.dev.env'
            [IO.File]::WriteAllText($sourceConfig, '{}', [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText($sourceEnv, "UI_TESTING=essential`r`nITL_VANESSA_TESTING=off`r`nUSER_SETTING=keep`r`nEXPORT_PATH=old`r`nITL_ACTIVE_CONTEXT_UPDATED_AT=old`r`n", [Text.UTF8Encoding]::new($true))
            Copy-Item -LiteralPath $sourceConfig -Destination (Join-Path $ownedSourceRoot '.agent-1c/project.json')
            [IO.File]::WriteAllText((Join-Path $ownedSourceRoot '.dev.env'), ([IO.File]::ReadAllText($sourceEnv)+"SOURCE_INFOBASE_PATH=$ownedSourceDatabase`r`n"), [Text.UTF8Encoding]::new($true))
            $sourceEnvHash = (Get-FileHash -LiteralPath $sourceEnv).Hash
            $sourceConfigHash = (Get-FileHash -LiteralPath $sourceConfig).Hash
            $body = $operation[0].ScriptBlock.Extent.Text
            $script:freshFixtureUse = $null
            try { & ([scriptblock]::Create($body.Substring(1, $body.Length - 2))) }
            finally { if ($script:freshFixtureUse) { $script:freshFixtureUse.Dispose(); $script:freshFixtureUse = $null } }
            $seed = [IO.File]::ReadAllLines((Join-Path $freshRoot '.dev.env'), [Text.Encoding]::UTF8)
            @($seed | Where-Object { $_ -match '^UI_TESTING=' }).Count | Should -Be 0
            $seed | Should -Contain 'ITL_VANESSA_TESTING=off'
            $seed | Should -Contain 'USER_SETTING=keep'
            $seed | Should -Contain 'SOURCE_INFOBASE_UNSAFE_ACTION_PROTECTION_MODE=confirmed'
            $prepareCalls.Count | Should -Be 1
            $prepareCalls[0].script | Should -BeExactly (Join-Path $CandidateRoot 'scripts/source-e2e-fixture.ps1')
            $prepareCalls[0].arguments | Should -Contain 'Prepare'
            $prepareCalls[0].arguments | Should -Contain $ProjectRoot
            $seed | Should -Contain "SOURCE_INFOBASE_PATH=$ownedSourceDatabase"
            @($seed | Where-Object { $_ -match '^(EXPORT_PATH|ITL_ACTIVE_CONTEXT_UPDATED_AT)=' }).Count | Should -Be 0
            (Get-FileHash -LiteralPath $sourceEnv).Hash | Should -BeExactly $sourceEnvHash
            (Get-FileHash -LiteralPath $sourceConfig).Hash | Should -BeExactly $sourceConfigHash
            (Get-FileHash -LiteralPath (Join-Path $freshRoot '.agent-1c/project.json')).Hash | Should -BeExactly $sourceConfigHash
        }

        $text = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        $text | Should -Match '\$requestedJourneys = if \(\$Journey -eq "all"\) \{ @\("upgrade", "fresh"\) \} else \{ @\(\$Journey\) \}'
        $text | Should -Match 'if \(\$requestedJourneys -contains "upgrade"\)'
        $text | Should -Match 'if \(\$requestedJourneys -contains "fresh"\)'
        $text | Should -Match '(?s)if \(\$requestedJourneys -contains "upgrade"\).*?Invoke-DevelopWorkflowUpdate -Root \$ProjectRoot -CandidateRoot \$CandidateRoot -AgentTarget \$AgentTarget.*?\$journeys\.upgrade\.status = "passed"'
        $text | Should -Match '(?s)if \(\$requestedJourneys -contains "fresh"\).*?Invoke-DevelopProcess -Name "fresh-bootstrap-init-project".*?\$journeys\.fresh\.status = "passed"'
        $text | Should -Match 'schemaVersion = 3'
        $text | Should -Match 'coverage = @\(\$scenarioSelection\[\$requestedJourney\]\)'
        $text | Should -Match 'Assert-DevelopScenarioCompletion -Catalog \$scenarioCatalog -Journey upgrade'
        $text | Should -Match 'Assert-DevelopScenarioCompletion -Catalog \$scenarioCatalog -Journey fresh'
        foreach ($field in @("requestedJourneys", "journeys", "activeJourney", "steps", "operationTimings", "error")) {
            $text | Should -Match ([regex]::Escape($field + " ="))
        }
        $text | Should -Match '\$journeys\[\$activeJourney\]\.status = "failed"'
        $text | Should -Match 'Remove-DevelopE2EFreshProject -FreshProjectsRoot \$FreshProjectsRoot -Path \$freshRoot -BranchPath \$freshBranchRoot'

        $check = Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\check.ps1") -Raw -Encoding UTF8
        $check | Should -Match 'Resolve-DevelopE2EJourneyPlan -RepositoryRoot \$repoRoot -BaseRef \$BaseRef'
        $check | Should -Match '\$exactDevelopProof = Test-DevelopQualification -Commit \$commit -Tree \$tree -FullProof \$developFullProof'
        $check | Should -Match 'Add-ReusedStage -Name "develop-e2e" -Reason "exact route-aware Develop qualification"'
        $check | Should -Match '(?s)\$script:developPlan = Resolve-DevelopE2EJourneyPlan.*?failFastOrder.*?Ensure-DevelopE2ERoute.*?Invoke-GateStage -Name "pester"'
        $check | Should -Match '(?s)if \(\$exactDevelopProof.*?\) \{.*?exact route-aware Develop qualification.*?\} else \{\s*\$qualificationRoot = \$developQualificationRoot'
        $check | Should -Not -Match '\$plannedJourneys = \$allJourneys'
        $check | Should -Match 'DEVELOP_E2E_CONTINUATION_REQUIRED: an unowned journey has no valid prior proof; refusing to widen the routed plan'
        $check | Should -Match '\$routeIdentitySha256 = if \(\$continued\) \{ \[string\]\$record\.identitySha256 \}'
        $check | Should -Match '\$baselineRouteIdentitySha256 = if \(\$record\.PSObject\.Properties\[''execution''\] -and \[string\]\$record\.execution -eq "continued"\) \{ \[string\]\$record\.identitySha256 \}'
        $check | Should -Match 'IdentitySha256 \$baselineRouteIdentitySha256 -StandStateSha256 \$developStandStateSha256'
        $check | Should -Match 'if \(-not \$BaseRef\) \{ throw "Develop E2E requires BaseRef'
        $check | Should -Match 'Restore-DevelopE2EQualification .*?-Journey \$Journey -IdentitySha256 \$identitySha256'
        $check | Should -Match 'Save-DevelopE2EQualification .*?-Journey \$Journey -IdentitySha256 \$identitySha256'
        $check | Should -Match 'develop-e2e-qualification\.ps1'
        $tokens=$null; $errors=$null
        $module=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'scripts/develop-e2e-qualification.ps1'),[ref]$tokens,[ref]$errors)
        @($errors) | Should -BeNullOrEmpty
        $writer=$module.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Write-DevelopQualification'},$true)
        $writer.Extent.Text | Should -Match 'schemaVersion = 4'
        $check | Should -Match '\[int\]\$baseline\.schemaVersion -in @\(3, 4\)'
        $check | Should -Match 'execution = "continued"'
        $check | Should -Match 'ExpectedIdentitySha256'
        $check | Should -Match 'ExpectedStandStateSha256'
        $check | Should -Match 'Get-DevelopE2EStandStateSha256 -ProjectRoot \$E2EProjectRoot'
        $check | Should -Match 'Get-DevelopE2EIdentitySha256 -ReleaseContext \$releaseContext'
        $check | Should -Match 'Resolve-DevelopE2EJourneyPlan -RepositoryRoot \$repoRoot -ChangedPath @\(\$continuation\.paths\)'
    }
}
