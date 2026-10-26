BeforeAll {
    . (Join-Path $PSScriptRoot "TestSupport.ps1")
    $context = Initialize-WorkflowPesterContext
    $RepoRoot = $context.RepoRoot
}

Describe "Release gate scripts" {
    It 'preserves native Release bootstrap Unicode stdout and formatted error bytes' {
        $observation = & {
            param([string]$SourceRoot, [string]$ReleaseEntryPath, [string]$FixtureRoot)
            $ErrorActionPreference = 'Stop'
            New-Item -ItemType Directory -Force -Path $FixtureRoot | Out-Null
            $tokens = $null; $errors = $null
            $entryAst = [Management.Automation.Language.Parser]::ParseFile($ReleaseEntryPath, [ref]$tokens, [ref]$errors)
            if (@($errors).Count -ne 0) { throw 'Release entrypoint parse failed' }
            $boundary = @($entryAst.EndBlock.Statements | Where-Object {
                $_ -is [Management.Automation.Language.PipelineAst] -and
                $_.PipelineElements[0] -is [Management.Automation.Language.CommandAst] -and
                $_.PipelineElements[0].InvocationOperator -eq [Management.Automation.Language.TokenKind]::Dot
            }) | Select-Object -First 1
            if ($null -eq $boundary) { throw 'Release entrypoint bootstrap boundary was not found' }
            # Execute the production bootstrap only. No imported module or Release body runs.
            $bootstrap = $entryAst.Extent.Text.Substring($entryAst.ParamBlock.Extent.EndOffset,
                $boundary.Extent.StartOffset - $entryAst.ParamBlock.Extent.EndOffset)
            $childPath = Join-Path $FixtureRoot 'Ошибка с пробелом.ps1'
            $childText = @'
            # Reproduce the observed OEM866 initial host, independently of the caller console.
            [Console]::InputEncoding = [Text.Encoding]::GetEncoding(866)
            [Console]::OutputEncoding = [Text.Encoding]::GetEncoding(866)
            $OutputEncoding = [Text.Encoding]::GetEncoding(866)
'@ + [Environment]::NewLine + $bootstrap + [Environment]::NewLine + @'
            Write-Output ('ITL_RELEASE_STDOUT|' + $PSVersionTable.PSVersion.Major + '|' + $PSCommandPath + '|Проверка вывода')
            [Console]::Error.WriteLine('ITL_RELEASE_STDERR|Проверка ошибки')
            throw 'ITL_RELEASE_THROW|Ошибка границы'
'@
            [IO.File]::WriteAllText($childPath, $childText, [Text.UTF8Encoding]::new($true))
            $checkAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'scripts/check.ps1'), [ref]$tokens, [ref]$errors)
            if (@($errors).Count -ne 0) { throw 'Shared child helper parse failed' }
            foreach ($name in @('ConvertTo-NativeArgument', 'Start-PowerShellChildProcess', 'Stop-GateChildProcessTree', 'Wait-PowerShellChildProcess')) {
                $definition = $checkAst.Find({ param($node)
                    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name
                }, $false)
                if ($null -eq $definition) { throw "Missing shared child helper: $name" }
                Invoke-Expression $definition.Extent.Text
            }
            # Match check.ps1's caller-side UTF-8 contract without relying on test-host defaults.
            $originalInputEncoding = [Console]::InputEncoding
            $originalOutputEncoding = [Console]::OutputEncoding
            $originalPipelineEncoding = $OutputEncoding
            $utf8 = [Text.UTF8Encoding]::new($false)
            $repoRoot = $FixtureRoot
            $outputRoot = Join-Path $FixtureRoot 'out'
            New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
            $modeHardBudgetSeconds = 30
            $overallStopwatch = [Diagnostics.Stopwatch]::StartNew()
            $child = $null
            try {
                [Console]::InputEncoding = $utf8; [Console]::OutputEncoding = $utf8; $OutputEncoding = $utf8
                $child = Start-PowerShellChildProcess -ScriptPath $childPath -LogName 'release-bootstrap'
                $failure = ''
                try { Wait-PowerShellChildProcess -Child $child -TimeoutSeconds 30 -NoProgressSeconds 10 }
                catch { $failure = $_.Exception.Message }
                $child.process.Refresh()
                $observation = [ordered]@{
                    exitCode = [int]$child.process.ExitCode; failure = $failure
                    childPath = $childPath; stdoutPath = $child.stdoutPath; stderrPath = $child.stderrPath
                    childScriptSha256 = (Get-FileHash -LiteralPath $childPath -Algorithm SHA256).Hash.ToLowerInvariant()
                    entrypointSha256 = (Get-FileHash -LiteralPath $ReleaseEntryPath -Algorithm SHA256).Hash.ToLowerInvariant()
                    callerRuntime = $PSVersionTable.PSVersion.ToString()
                }
                [IO.File]::WriteAllText((Join-Path $outputRoot 'observation.json'), ($observation | ConvertTo-Json -Depth 4), $utf8)
                $strictUtf8 = [Text.UTF8Encoding]::new($false, $true)
                $observation.stdout = $strictUtf8.GetString([IO.File]::ReadAllBytes($child.stdoutPath))
                $observation.stderr = $strictUtf8.GetString([IO.File]::ReadAllBytes($child.stderrPath))
                return [pscustomobject]$observation
            } finally {
                if ($null -ne $child) { Stop-GateChildProcessTree -Process $child.process }
                [Console]::InputEncoding = $originalInputEncoding
                [Console]::OutputEncoding = $originalOutputEncoding
                $OutputEncoding = $originalPipelineEncoding
            }
        } $RepoRoot (Join-Path $RepoRoot 'scripts/invoke-release-e2e.ps1') (Join-Path $TestDrive 'Release путь с пробелом')
        $observation.exitCode | Should -Be 1
        $observation.failure | Should -Match 'failed with exit code 1'
        $observation.stdout.TrimEnd("`r", "`n") | Should -BeExactly ('ITL_RELEASE_STDOUT|5|' + $observation.childPath + '|Проверка вывода')
        $observation.stderr | Should -Match ([regex]::Escape('ITL_RELEASE_STDERR|Проверка ошибки'))
        $observation.stderr | Should -Match ([regex]::Escape('ITL_RELEASE_THROW|Ошибка границы'))
        $observation.stdout | Should -Not -Match ([string][char]0xFFFD)
        $observation.stderr | Should -Not -Match ([string][char]0xFFFD)
    }
    It "replays one generated commit once when two capability records share its SHA" {
        & {
            $source = Join-Path $TestDrive "replay источник"
            $target = Join-Path $TestDrive "replay приёмник"
            New-Item -ItemType Directory -Force -Path $source | Out-Null
            & git -C $source init --quiet
            & git -C $source config user.email 'tests@example.invalid'
            & git -C $source config user.name 'ITL Tests'
            [IO.File]::WriteAllText((Join-Path $source 'fixture.txt'), "base`n", [Text.UTF8Encoding]::new($false))
            & git -C $source add -- fixture.txt
            & git -C $source commit --quiet -m base
            $base = (& git -C $source rev-parse HEAD).Trim()
            [IO.File]::WriteAllText((Join-Path $source 'fixture.txt'), "generated`n", [Text.UTF8Encoding]::new($false))
            & git -C $source commit --quiet -am generated
            $oldCommit = (& git -C $source rev-parse HEAD).Trim()
            & git clone --quiet --no-local $source $target
            & git -C $target config user.email 'tests@example.invalid'
            & git -C $target config user.name 'ITL Tests'
            & git -C $target reset --quiet --hard $base

            $manifest = Join-Path $TestDrive 'capability-cache.json'
            [IO.File]::WriteAllText($manifest, '{"schemaVersion":1}', [Text.UTF8Encoding]::new($false))
            $script:replayCache = [ordered]@{
                schemaVersion = 1
                identity = [ordered]@{ initialHead = $base; runnerSha256 = ('a' * 64) }
                generatedCommits = @(
                    [ordered]@{ kind = 'configuration-comment'; commit = $oldCommit },
                    [ordered]@{ kind = 'vanessa-fixture'; commit = $oldCommit }
                )
                stages = [ordered]@{}
                snapshots = [ordered]@{}
                stateFiles = [ordered]@{}
                configEvidence = [ordered]@{}
            }
            $checkpoint = [ordered]@{ generatedCommits = @(); expectedHead = $base; stages = [ordered]@{} }
            $worktreePath = $target
            function ConvertTo-E2EHashtable { param($Value) return $script:replayCache }
            function Get-E2EGeneratedCommitRecords { param($Value) return $Value }
            function Write-E2ECheckpoint {}
            $tokens = $null; $errors = $null
            $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'scripts\invoke-release-e2e.ps1'), [ref]$tokens, [ref]$errors)
            $definition = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Import-E2ECapabilityCache' }, $true))[0]
            Invoke-Expression $definition.Extent.Text
            try {
                Import-E2ECapabilityCache -ManifestPath $manifest
                $newCommit = (& git -C $target rev-parse HEAD).Trim()
                $newCommit | Should -Not -Be $base
                @(& git -C $target rev-list "$base..HEAD").Count | Should -Be 1
                @($checkpoint.generatedCommits).Count | Should -Be 2
                @($checkpoint.generatedCommits | ForEach-Object { $_.commit } | Select-Object -Unique) | Should -Be @($newCommit)
                @($checkpoint.generatedCommits | ForEach-Object { $_.kind }) | Should -Be @('configuration-comment', 'vanessa-fixture')
                (& git -C $target status --porcelain) | Should -BeNullOrEmpty
            } finally {
                Remove-Variable -Name replayCache -Scope Script -ErrorAction SilentlyContinue
            }
        }
    }

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
        $developE2eText | Should -Match '(?s)Invoke-DevelopUpgradeRefresh -Name "upgrade-refresh-branch".*?Set-DevelopStandVanessaFeature -Root \$standBranchRoot.*?Invoke-InstalledAction -Name "upgrade-check"'
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
            foreach ($functionName in @("Add-FreshVanessaFeature", "Add-FreshVerificationCatalog", "Set-DevelopStandVanessaFeature")) {
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
            & git -C $tempRoot ls-files --error-unmatch -- tests/verification-suites.branch.json *> $null
            $LASTEXITCODE | Should -Be 0
            $catalog = Get-Content -LiteralPath (Join-Path $tempRoot "tests\verification-suites.branch.json") -Raw -Encoding UTF8 | ConvertFrom-Json
            @($catalog.suites).Count | Should -Be 1
            $catalog.suites[0].purpose | Should -Be "acceptance"
            @($catalog.suites[0].featurePaths) | Should -Be @("tests/features/*.feature")
            @($catalog.suites[0].ownerPaths) | Should -Be @("src/cf/Configuration.xml")
            (& git -C $tempRoot log -1 --pretty=%s).Trim() | Should -Be "test: seed develop E2E Vanessa fixture"
            $feature = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes((Join-Path $tempRoot "tests\features\ITLDevelopJourney.feature")))
            $contextIndex = $feature.IndexOf("Контекст:")
            $scenarioIndex = $feature.IndexOf("Сценарий:")
            $contextIndex | Should -BeGreaterThan -1
            $scenarioIndex | Should -BeGreaterThan $contextIndex
            ([regex]::Matches($feature, '(?m)^Сценарий:')).Count | Should -Be 2
            $feature | Should -Match 'Пауза 0\.1'
            $feature | Should -Not -Match '(?s)Сценарий: Базовая работает\s+Контекст:'
            @(& git -C $tempRoot status --porcelain).Count | Should -Be 0

            Set-DevelopStandVanessaFeature -Root $tempRoot
            (& git -C $tempRoot rev-parse HEAD).Trim() | Should -Be $firstHead
            @(& git -C $tempRoot status --porcelain).Count | Should -Be 0
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
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

    It "retains structured pass and failure timings for fresh operations in the scoped report" {
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
        $text | Should -Match 'schemaVersion = 3'
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
        $text | Should -Match 'onDemandRoctupPublicToolCount -ne 2'
        $text | Should -Match 'onDemandVanessaPublicToolCount -ne 2'
        $text | Should -Match 'ownedProcessExitWaitMs'
        $text | Should -Match '\[Console\]::Error\.WriteLine\(\$failure\)'
        $runnerText = Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\invoke-release-e2e.ps1") -Raw -Encoding UTF8
        $runnerText | Should -Match 'SOURCE_INFOBASE_PATH must be a disposable snapshot inside the stand'
        $runnerText | Should -Match '\[Console\]::Error\.WriteLine\(\$failure\)'
        (Get-Content -LiteralPath (Join-Path $RepoRoot "docs\release-checklist.md") -Raw -Encoding UTF8) | Should -Match 'source-snapshot'
        $releaseChecklist = Get-Content -LiteralPath (Join-Path $RepoRoot "docs\release-checklist.md") -Raw -Encoding UTF8
        $releaseChecklist | Should -Match 'signed nested contexts'
        $releaseChecklist | Should -Match 'An idle\s+backend owns no database resource'
        $releaseChecklist | Should -Not -Match 'finish_database_access'
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

    It "classifies an absent server stand as unverified without disabling configured server proof" {
        . (Join-Path $RepoRoot "scripts\release-e2e\common.ps1")
        . (Join-Path $RepoRoot "scripts\release-e2e\server-reset.ps1")

        $absent = Get-ReleaseE2EServerResetDisposition
        $absent.status | Should -Be "unverified"
        $absent.configured | Should -BeFalse

        $partial = Get-ReleaseE2EServerResetDisposition -ServerProjectRoot "server-root"
        $partial.status | Should -Be "invalid"

        $configured = Get-ReleaseE2EServerResetDisposition -ServerProjectRoot "server-root" -ServerWorktreePath "server-worktree" -ServerDevBranchName "release-server"
        $configured.status | Should -Be "configured"
        $configured.configured | Should -BeTrue
    }
}
