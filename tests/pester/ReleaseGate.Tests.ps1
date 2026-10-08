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
        $checkText = Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\check.ps1") -Raw -Encoding UTF8
        $e2eText = Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\invoke-release-e2e.ps1") -Raw -Encoding UTF8
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
        (Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\release-e2e\ondemand-mcp.ps1") -Raw -Encoding UTF8) | Should -Match 'ondemand-mcp" -Version 5'
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
        $e2eText | Should -Match 'exact Targeted continuation after completed release'
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
        $e2eText | Should -Match 'RELEASE_E2E_CHECKPOINT_UPGRADE_REQUIRED'
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
        $e2eText | Should -Match '(?s)\$stageConfiguration = if \(\$Name -eq "server-reset"\).*?serverProjectRoot = Get-E2EReleaseConfigValue.*?stageConfiguration = \$stageConfiguration'
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

        $provision = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Invoke-DevelopTimedOperation' -and
                @($node.CommandElements | Where-Object { $_ -is [Management.Automation.Language.StringConstantExpressionAst] -and $_.Value -eq 'provision-project' }).Count -eq 1
        }, $true))
        $provision.Count | Should -Be 1
        $operation = @($provision[0].CommandElements | Where-Object { $_ -is [Management.Automation.Language.ScriptBlockExpressionAst] })
        $operation.Count | Should -Be 1
        & {
            $ProjectRoot = Join-Path $TestDrive 'Исходный стенд с пробелами'
            $FreshProjectsRoot = Join-Path $TestDrive 'Новые проекты с пробелами'
            $freshRoot = Join-Path $FreshProjectsRoot 'p Проект\новый'
            New-Item -ItemType Directory -Path (Join-Path $ProjectRoot '.agent-1c') -Force | Out-Null
            $sourceConfig = Join-Path $ProjectRoot '.agent-1c/project.json'
            $sourceEnv = Join-Path $ProjectRoot '.dev.env'
            [IO.File]::WriteAllText($sourceConfig, '{}', [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText($sourceEnv, "UI_TESTING=essential`r`nITL_VANESSA_TESTING=off`r`nUSER_SETTING=keep`r`nEXPORT_PATH=old`r`nITL_ACTIVE_CONTEXT_UPDATED_AT=old`r`n", [Text.UTF8Encoding]::new($true))
            $sourceEnvHash = (Get-FileHash -LiteralPath $sourceEnv).Hash
            $sourceConfigHash = (Get-FileHash -LiteralPath $sourceConfig).Hash
            $body = $operation[0].ScriptBlock.Extent.Text
            & ([scriptblock]::Create($body.Substring(1, $body.Length - 2)))
            $seed = [IO.File]::ReadAllLines((Join-Path $freshRoot '.dev.env'), [Text.Encoding]::UTF8)
            @($seed | Where-Object { $_ -match '^UI_TESTING=' }).Count | Should -Be 0
            $seed | Should -Contain 'ITL_VANESSA_TESTING=off'
            $seed | Should -Contain 'USER_SETTING=keep'
            $seed | Should -Contain 'SOURCE_INFOBASE_UNSAFE_ACTION_PROTECTION_MODE=confirmed'
            @($seed | Where-Object { $_ -match '^(EXPORT_PATH|ITL_ACTIVE_CONTEXT_UPDATED_AT)=' }).Count | Should -Be 0
            (Get-FileHash -LiteralPath $sourceEnv).Hash | Should -BeExactly $sourceEnvHash
            (Get-FileHash -LiteralPath $sourceConfig).Hash | Should -BeExactly $sourceConfigHash
            (Get-FileHash -LiteralPath (Join-Path $freshRoot '.agent-1c/project.json')).Hash | Should -BeExactly $sourceConfigHash
        }

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
        $check | Should -Match '(?s)\$script:developPlan = Resolve-DevelopE2EJourneyPlan.*?failFastOrder.*?Ensure-DevelopE2ERoute.*?Invoke-GateStage -Name "pester"'
        $check | Should -Match '(?s)if \(\$exactDevelopProof.*?\) \{.*?exact route-aware Develop qualification.*?\} else \{\s*\$qualificationRoot = \$developQualificationRoot'
        $check | Should -Not -Match '\$plannedJourneys = \$allJourneys'
        $check | Should -Match 'DEVELOP_E2E_CONTINUATION_REQUIRED: an unowned journey has no valid prior proof; refusing to widen the routed plan'
        $check | Should -Match '\$routeIdentitySha256 = if \(\$continued\) \{ \[string\]\$record\.identitySha256 \}'
        $check | Should -Match '\$baselineRouteIdentitySha256 = if \(\[string\]\$record\.execution -eq "continued"\) \{ \[string\]\$record\.identitySha256 \}'
        $check | Should -Match 'IdentitySha256 \$baselineRouteIdentitySha256 -StandStateSha256 \$developStandStateSha256'
        $check | Should -Match 'if \(-not \$BaseRef\) \{ throw "Develop E2E requires BaseRef'
        $check | Should -Match 'Restore-DevelopE2EQualification .*?-Journey \$Journey -IdentitySha256 \$identitySha256'
        $check | Should -Match 'Save-DevelopE2EQualification .*?-Journey \$Journey -IdentitySha256 \$identitySha256'
        $check | Should -Match 'schemaVersion = 4'
        $check | Should -Match '\[int\]\$baseline\.schemaVersion -in @\(3, 4\)'
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
            foreach ($relative in @("scripts\invoke-release-e2e.ps1", "scripts\source-delivery-process.ps1", "scripts\stand-env-identity.ps1", "scripts\Build-ItlOnDemandMcp.ps1", "templates\dependency-lock.json")) {
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

Describe 'Develop upgrade manifest continuation' {
    BeforeAll {
        . (Join-Path $RepoRoot 'scripts/git-path-list.ps1')
        $tokens=$null; $errors=$null
        $owner=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'scripts/invoke-develop-e2e.ps1'),[ref]$tokens,[ref]$errors)
        if ($errors) { throw 'Develop owner must parse' }
        foreach ($name in @('Read-CompactSummary','Repair-DevelopUpgradeManifestConflict','Invoke-DevelopUpgradeRefresh')) {
            $definition=$owner.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$false)
            . ([scriptblock]::Create($definition.Extent.Text))
        }
        function New-DevelopManifestMergeFixture {
            param([string]$Root,[string]$Case='valid')
            $utf8=[Text.UTF8Encoding]::new($false)
            $main=Join-Path $Root 'Стенд main'; $branch=Join-Path $Root 'Ветка r40'
            New-Item -ItemType Directory -Force -Path $main | Out-Null
            [void](Invoke-RepositoryGit $main @('init','--quiet','--initial-branch=master'))
            [void](Invoke-RepositoryGit $main @('config','user.email','tests@example.invalid'))
            [void](Invoke-RepositoryGit $main @('config','user.name','ITL Tests'))
            [void](Invoke-RepositoryGit $main @('config','core.autocrlf','false'))
            [IO.File]::WriteAllText((Join-Path $main '.gitignore'),".agents/`n.agent-1c/`nlogs/`n",$utf8)
            $rule='правило с пробелом.md'
            [IO.File]::WriteAllText((Join-Path $main $rule),"old rule`n",$utf8)
            [IO.File]::WriteAllText((Join-Path $main 'business.txt'),"base business`n",$utf8)
            $baseManifest=[ordered]@{
                protocol=1;source='controlled-fixture';version='itl-main-410951e7-r36';installedAt='2026-07-17T03:06:46Z';updatedAt='2026-09-23T14:05:54Z'
                tools=@('kilocode');language='ru';mcpServers=@('1C-docs-mcp')
                files=[ordered]@{$rule=@{source='content/rules/rule.md';installedHash=(Get-FileHash -LiteralPath (Join-Path $main $rule)).Hash.ToLowerInvariant()}}
                foreignFiles=@{kilocode=@('.kilo/commands/itl-status.md')}
                integrations=@{openspec=@{detected=$true;scaffolded=$true;artifactsBundleVersion='1.2.0';files=@('openspec/changes/README.md','openspec/specs/README.md')}}
            }
            [IO.File]::WriteAllText((Join-Path $main '.ai-rules.json'),($baseManifest|ConvertTo-Json -Depth 12),$utf8)
            [void](Invoke-RepositoryGit $main @('add','--all'))
            [void](Invoke-RepositoryGit $main @('commit','--quiet','-m','old r36 common baseline'))
            $base=(Invoke-RepositoryGit $main @('rev-parse','HEAD')).stdout.Trim()
            [void](Invoke-RepositoryGit $main @('worktree','add','--quiet','-b','itldev/fixture',$branch,$base))
            foreach ($rootPath in @($main,$branch)) {
                [IO.File]::WriteAllText((Join-Path $rootPath $rule),"same current rule`n",$utf8)
                $m=$baseManifest|ConvertTo-Json -Depth 12|ConvertFrom-Json
                $m.version='itl-main-c1fb8e6-r40'
                $m.updatedAt=if($rootPath -eq $main){'2026-10-03T05:20:27Z'}else{'2026-10-03T07:46:37Z'}
                $m.integrations.openspec.artifactsBundleVersion='1.13.1'
                $m.files.$rule.installedHash=(Get-FileHash -LiteralPath (Join-Path $rootPath $rule)).Hash.ToLowerInvariant()
                $m.foreignFiles.kilocode=@('.kilo/commands/itl-status.md',$(if($rootPath -eq $main){'.kilo/commands/itl-switch-client.md'}else{'.kilo/commands/itl-result.md'}))
                if ($rootPath -eq $branch) {
                    New-Item -ItemType Directory -Force -Path (Join-Path $branch 'openspec')|Out-Null
                    [IO.File]::WriteAllText((Join-Path $branch 'openspec/project.md'),"generated branch context`n",$utf8)
                    $m.files|Add-Member -NotePropertyName 'openspec/project.md' -NotePropertyValue @{source='<auto-generated:1c-rules>';installedHash=(Get-FileHash -LiteralPath (Join-Path $branch 'openspec/project.md')).Hash.ToLowerInvariant()}
                    $m.integrations.openspec|Add-Member -NotePropertyName projectMdGenerated -NotePropertyValue $true
                    if ($Case -eq 'unknown-top') {$m|Add-Member -NotePropertyName branchSecretPolicy -NotePropertyValue 'preserve me'}
                    if ($Case -eq 'unknown-integration') {$m.integrations|Add-Member -NotePropertyName branchPolicy -NotePropertyValue @{enabled=$true}}
                    if ($Case -eq 'branch-only-rule') {
                        [IO.File]::WriteAllText((Join-Path $branch 'branch-rule.md'),"branch custom rule`n",$utf8)
                        $m.files|Add-Member -NotePropertyName 'branch-rule.md' -NotePropertyValue @{source='content/rules/branch.md';installedHash=(Get-FileHash -LiteralPath (Join-Path $branch 'branch-rule.md')).Hash.ToLowerInvariant()}
                    }
                    if ($Case -eq 'version-mismatch') {$m.version='different controlled version'}
                } elseif ($Case -eq 'forged-hash') { $m.files.$rule.installedHash=('f'*64) }
                if ($Case -eq 'business-conflict') { [IO.File]::WriteAllText((Join-Path $rootPath 'business.txt'),("business "+$rootPath+"`n"),$utf8) }
                [IO.File]::WriteAllText((Join-Path $rootPath '.ai-rules.json'),($m|ConvertTo-Json -Depth 12),$utf8)
                [void](Invoke-RepositoryGit $rootPath @('add','--all'))
                [void](Invoke-RepositoryGit $rootPath @('commit','--quiet','-m','independent current workflow update'))
            }
            $target=(Invoke-RepositoryGit $main @('rev-parse','HEAD')).stdout.Trim()
            $before=(Invoke-RepositoryGit $branch @('rev-parse','HEAD')).stdout.Trim()
            $merge=Invoke-RepositoryGit $branch @('merge','--no-ff','--no-commit',$target) -AllowFailure
            $merge.exitCode|Should -Be 1
            @(Get-RepositoryGitPathList $branch @('diff','--name-only','--diff-filter=U','-z'))|Should -Contain '.ai-rules.json'
            $lib=Join-Path $branch '.agents/skills/1c-workflow/scripts/lib'
            New-Item -ItemType Directory -Force -Path $lib|Out-Null
            foreach ($name in @('runtime-values','core','vanessa','lifecycle','ai-rules-migration')) {
                Copy-Item -LiteralPath (Join-Path $RepoRoot ".agents/skills/1c-workflow/scripts/lib/agent-1c.$name.ps1") -Destination $lib
            }
            $statePath=Join-Path $main '.agent-1c/dev-branches/fixture.json'
            New-Item -ItemType Directory -Force -Path (Split-Path $statePath)|Out-Null
            [IO.File]::WriteAllText($statePath,(@{devBranch='itldev/fixture';devBranchName='fixture';safeDevBranchName='fixture';worktreePath=$branch;mainWorktreePath=$main}|ConvertTo-Json),$utf8)
            # The real installed transaction owner writes the pending fixture;
            # the source recovery never fabricates or edits this record.
            $module=New-Module -ArgumentList $branch -ScriptBlock {
                param($Root)
                $script:ProjectRoot=$Root
                foreach($name in @('runtime-values','core','vanessa','lifecycle','ai-rules-migration')){. (Join-Path $Root ".agents/skills/1c-workflow/scripts/lib/agent-1c.$name.ps1")}
            }
            try {
                & $module {
                    param($Before,$Target,$WrongParent)
                    $state=Read-DevBranchState -Name fixture
                    Set-PendingDevBranchMergeTransaction -State $state -Operation refresh-dev-branch -Branch itldev/fixture -BranchCommit $Before -TargetCommit $Target -Stage conflicts -AllowedPaths @(Get-DevBranchMergeIndexPaths) -ConflictPaths @(Get-DevBranchMergeUnmergedPaths)
                    if ($WrongParent) { Update-DevBranchState -State (Read-DevBranchState -Name fixture) -Updates @{pendingMergeTargetCommit=$WrongParent} }
                } $before $target $(if($Case -eq 'parent-mismatch'){$base}else{''})
            } finally {Remove-Module $module -ErrorAction SilentlyContinue}
            if ($Case -eq 'stage-mismatch') {
                $blob=(Invoke-RepositoryGit $branch @('rev-parse',($base+':.ai-rules.json'))).stdout.Trim()
                [void](Invoke-RepositoryGit $branch @('update-index','-z','--index-info') -StandardInput ("100644 $blob 3`t.ai-rules.json"+[char]0))
            }
            $logs=Join-Path $branch 'logs';New-Item -ItemType Directory $logs|Out-Null
            $stdout=Join-Path $logs 'initial failed.stdout.json';$stderr=Join-Path $logs 'initial failed.stderr.log'
            [IO.File]::WriteAllText($stdout,(@{action='refresh-dev-branch';status='failed';errorCategory='merge-conflict';requiredAction='agent-progressive-semantic-repair-run-git-add-repeat-same-itl-command-no-manual-commit'}|ConvertTo-Json -Compress),$utf8)
            [IO.File]::WriteAllText($stderr,$merge.stderr,$utf8)
            return @{main=$main;root=$branch;base=$base;branch=$before;target=$target;statePath=$statePath;result=[pscustomobject]@{exitCode=1;stdout=$stdout;stderr=$stderr};rule=$rule}
        }
    }

    It 'continues the same public refresh after the real three-block manifest conflict without promoting the first failure' {
        & {
            $fixture=New-DevelopManifestMergeFixture (Join-Path $TestDrive 'Публичный refresh')
            $script:manifestRefreshCalls=New-Object 'Collections.Generic.List[object]'
            $steps=New-Object 'Collections.Generic.List[object]'
            $rawBefore=(Get-FileHash -LiteralPath $fixture.result.stdout).Hash
            $stateBefore=(Get-FileHash -LiteralPath $fixture.statePath).Hash
            $otherBefore=@(Get-RepositoryGitPathList $fixture.root @('ls-files','--stage','-z')|Where-Object {$_ -notmatch "`t\.ai-rules\.json$"})
            function Invoke-InstalledAction {
                param($Name,$Root,$Action,$AdditionalArguments,$TimeoutSeconds,[switch]$AllowFailure)
                $script:manifestRefreshCalls.Add(@{name=$Name;root=$Root;action=$Action;arguments=@($AdditionalArguments);allowFailure=[bool]$AllowFailure})
                if($script:manifestRefreshCalls.Count -eq 1){$steps.Add(@{name=$Name;status='failed'});return $fixture.result}
                @(Get-RepositoryGitPathList $Root @('diff','--name-only','--diff-filter=U','-z')).Count|Should -Be 0
                # The simulated public owner alone completes the real merge;
                # the source repair is forbidden to create this commit.
                [void](Invoke-RepositoryGit $Root @('commit','--quiet','--no-edit'))
                $stdout=Join-Path (Split-Path $fixture.result.stdout) 'retry.stdout.json'
                [IO.File]::WriteAllText($stdout,'{"action":"refresh-dev-branch","status":"succeeded"}',[Text.UTF8Encoding]::new($false))
                $steps.Add(@{name=$Name;status='passed'})
                return [pscustomobject]@{exitCode=0;stdout=$stdout;stderr=$fixture.result.stderr}
            }
            $result=Invoke-DevelopUpgradeRefresh -Name upgrade-refresh-branch -Root $fixture.root -BranchName fixture
            $result.exitCode|Should -Be 0
            @($steps.status)|Should -Be @('failed','passed')
            @($script:manifestRefreshCalls.name)|Should -Be @('upgrade-refresh-branch','upgrade-refresh-branch-semantic-repair')
            @($script:manifestRefreshCalls.root|Select-Object -Unique)|Should -Be @($fixture.root)
            @($script:manifestRefreshCalls.action|Select-Object -Unique)|Should -Be @('refresh-dev-branch')
            @($script:manifestRefreshCalls|ForEach-Object {$_.arguments}).Count|Should -Be 0
            (Get-FileHash -LiteralPath $fixture.result.stdout).Hash|Should -BeExactly $rawBefore
            (Get-FileHash -LiteralPath $fixture.statePath).Hash|Should -BeExactly $stateBefore
            (Invoke-RepositoryGit $fixture.root @('rev-parse','HEAD^1')).stdout.Trim()|Should -BeExactly $fixture.branch
            (Invoke-RepositoryGit $fixture.root @('rev-parse','HEAD^2')).stdout.Trim()|Should -BeExactly $fixture.target
            (@(Get-RepositoryGitPathList $fixture.root @('ls-files','--stage','-z')|Where-Object {$_ -notmatch "`t\.ai-rules\.json$"})-join [char]0)|Should -BeExactly ($otherBefore-join [char]0)
            $m=Get-Content -LiteralPath (Join-Path $fixture.root '.ai-rules.json') -Raw -Encoding UTF8|ConvertFrom-Json
            $m.updatedAt|Should -BeExactly '2026-10-03T05:20:27Z'
            $m.integrations.openspec.projectMdGenerated|Should -BeTrue
            $m.files.'openspec/project.md'.source|Should -BeExactly '<auto-generated:1c-rules>'
            @($m.foreignFiles.kilocode)|Should -Be @('.kilo/commands/itl-status.md','.kilo/commands/itl-switch-client.md','.kilo/commands/itl-result.md')
            $body=Get-Content -LiteralPath (Join-Path $RepoRoot 'scripts/invoke-develop-e2e.ps1') -Raw -Encoding UTF8
            $body|Should -Match '(?s)Invoke-DevelopUpgradeRefresh -Name "upgrade-refresh-branch".*?Assert-FreshVerificationResult.*?upgrade-export.*?Assert-TrackedClean'
        }
    }

    It 'retains the original merge and failure for unsupported <Case> semantics' -ForEach @(
        @{Case='unknown-top'},@{Case='unknown-integration'},@{Case='branch-only-rule'},@{Case='forged-hash'},
        @{Case='business-conflict'},@{Case='parent-mismatch'},@{Case='stage-mismatch'},@{Case='version-mismatch'}
    ) {
        & {
            $fixture=New-DevelopManifestMergeFixture (Join-Path $TestDrive ("Отказ $Case")) $Case
            $before=(Get-FileHash -LiteralPath (Join-Path $fixture.root '.ai-rules.json')).Hash
            $stateBefore=(Get-FileHash -LiteralPath $fixture.statePath).Hash
            $indexBefore=@(Get-RepositoryGitPathList $fixture.root @('ls-files','--stage','-z'))-join [char]0
            $rawBefore=(Get-FileHash -LiteralPath $fixture.result.stdout).Hash
            $script:manifestRefusalCalls=0
            function Invoke-InstalledAction {param($Name,$Root,$Action,$AdditionalArguments,$TimeoutSeconds,[switch]$AllowFailure) $script:manifestRefusalCalls++;return $fixture.result}
            {Invoke-DevelopUpgradeRefresh -Name upgrade-refresh-branch -Root $fixture.root -BranchName fixture}|Should -Throw 'upgrade-refresh-branch failed with exit code 1*'
            $script:manifestRefusalCalls|Should -Be 1
            (Get-FileHash -LiteralPath (Join-Path $fixture.root '.ai-rules.json')).Hash|Should -BeExactly $before
            (Get-FileHash -LiteralPath $fixture.statePath).Hash|Should -BeExactly $stateBefore
            (@(Get-RepositoryGitPathList $fixture.root @('ls-files','--stage','-z'))-join [char]0)|Should -BeExactly $indexBefore
            (Get-FileHash -LiteralPath $fixture.result.stdout).Hash|Should -BeExactly $rawBefore
            (Invoke-RepositoryGit $fixture.root @('rev-parse','HEAD')).stdout.Trim()|Should -BeExactly $fixture.branch
            (Invoke-RepositoryGit $fixture.root @('rev-parse','MERGE_HEAD')).stdout.Trim()|Should -BeExactly $fixture.target
        }
    }

    It 'preserves a later manifest edit instead of overwriting the returned conflict' {
        $fixture=New-DevelopManifestMergeFixture (Join-Path $TestDrive 'Поздняя правка')
        $script:lateManifestPath=Join-Path $fixture.root '.ai-rules.json'
        $indexBefore=@(Get-RepositoryGitPathList $fixture.root @('ls-files','--stage','-z'))-join [char]0
        Mock Read-CompactSummary {
            param($ProcessResult)
            [IO.File]::AppendAllText($script:lateManifestPath,"`nuser late repair`n",[Text.UTF8Encoding]::new($false))
            [IO.File]::ReadAllText($ProcessResult.stdout,[Text.UTF8Encoding]::new($false))|ConvertFrom-Json
        }
        (Repair-DevelopUpgradeManifestConflict -Root $fixture.root -BranchName fixture -ProcessResult $fixture.result)|Should -BeFalse
        [IO.File]::ReadAllText($script:lateManifestPath)|Should -Match 'user late repair'
        (@(Get-RepositoryGitPathList $fixture.root @('ls-files','--stage','-z'))-join [char]0)|Should -BeExactly $indexBefore
        (Invoke-RepositoryGit $fixture.root @('rev-parse','HEAD')).stdout.Trim()|Should -BeExactly $fixture.branch
    }
}

Describe 'Unattended E2E client selection' {
    BeforeAll {
        . (Join-Path $RepoRoot 'scripts/stand-env-identity.ps1')
        function Get-E2ETestDefinition {
            param([string]$Path,[string]$Name)
            $tokens=$null;$errors=$null
            $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot $Path),[ref]$tokens,[ref]$errors)
            if($errors){throw 'Owner must parse'}
            $node=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $Name},$false)
            if(-not $node){throw "Missing owner $Name"};$node.Extent.Text
        }
        function New-E2EClientFixture {
            param([string]$Root,[string[]]$Clients=@('kilocode'))
            $helper=Join-Path $Root '.agents/skills/1c-workflow/scripts/run-itl-command.ps1'
            New-Item -ItemType Directory -Force -Path (Split-Path $helper),(Join-Path $Root '.agent-1c')|Out-Null
            [IO.File]::WriteAllText((Join-Path $Root '.agent-1c/project.json'),(@{aiRules=@{tools=$Clients}}|ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $Root '.ai-rules.json'),(@{tools=$Clients}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
            $providers=@"
`$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new(`$false)
`$forwarded=@(`$args|ForEach-Object{[string]`$_})
`$AgentTarget='';`$Action='';`$ProjectRoot=(Get-Location).Path
foreach(`$name in @('AgentTarget','Action','ProjectRoot')){`$i=[Array]::IndexOf(`$forwarded,'-'+`$name);if(`$i -ge 0){Set-Variable -Name `$name -Value `$forwarded[`$i+1]}}
function Get-AgentTargets {@((Get-Content -Raw -LiteralPath (Join-Path `$ProjectRoot '.agent-1c/project.json')|ConvertFrom-Json).aiRules.tools)}
function Get-AiRules1cProjectManifest {Get-Content -Raw -LiteralPath (Join-Path `$ProjectRoot '.ai-rules.json')|ConvertFrom-Json}
function Get-AiRules1cManifestToolNames {param(`$Manifest)@(`$Manifest.tools)}
function Get-InitAgentExecutionEnvironment {@{CODEX_THREAD_ID='ambient-codex'}}
function Resolve-InitAgentTargetFromExecutionContext {param(`$Environment,`$ProcessChain)'codex'}
function Get-InitAgentExecutionProcessChain {@()}
"@
            $owner=Get-E2ETestDefinition '.agents/skills/1c-workflow/scripts/lib/agent-1c.client-adapters.ps1' 'Get-ItlActiveClient'
            $result=@'
$selected=Get-ItlActiveClient
@{action=$Action;status='succeeded';agentTarget=$selected;root=$ProjectRoot;arguments=$forwarded}|ConvertTo-Json -Depth 4 -Compress
'@
            [IO.File]::WriteAllText($helper,($providers+"`r`n"+$owner+"`r`n"+$result),[Text.UTF8Encoding]::new($true))
            return $helper
        }
    }

    It 'selects the actual <Runner> root and resumes the same ambiguous operation explicitly' -ForEach @(@{Runner='Develop'},@{Runner='Release'}) {
        & {
            $root=Join-Path $TestDrive ("$Runner проект с пробелами")
            $HelperPath=New-E2EClientFixture $root
            $outputRoot=Join-Path $root 'logs';New-Item -ItemType Directory $outputRoot|Out-Null
            $steps=New-Object 'Collections.Generic.List[object]'
            $AgentTarget='';$activeJourney='upgrade';$script:activeStageDeadlineUtc=$null
            foreach($name in @('ConvertTo-DevelopProcessArgument','Invoke-DevelopProcess','Invoke-InstalledAction','Read-CompactSummary')){. ([scriptblock]::Create((Get-E2ETestDefinition 'scripts/invoke-develop-e2e.ps1' $name)))}
            foreach($name in @('ConvertTo-NativeArgument','Start-E2EHelperAtRoot','Complete-E2EHelperProcess')){. ([scriptblock]::Create((Get-E2ETestDefinition 'scripts/invoke-release-e2e.ps1' $name)))}
            function Invoke-SelectedFixture {
                if($Runner -eq 'Develop'){
                    $r=Invoke-InstalledAction -Name 'same-operation' -Root $root -Action status -TimeoutSeconds 30
                    return Read-CompactSummary $r
                }
                $invocation=Start-E2EHelperAtRoot -Root $root -Action status -LogPrefix 'same-operation'
                $r=Complete-E2EHelperProcess $invocation -TimeoutSeconds 30
                return Get-Content -Raw -LiteralPath $r.stdoutPath -Encoding UTF8|ConvertFrom-Json
            }
            $config=Join-Path $root '.agent-1c/project.json';$manifest=Join-Path $root '.ai-rules.json'
            $before=(Get-FileHash $config).Hash;$manifestBefore=(Get-FileHash $manifest).Hash
            $result=Invoke-SelectedFixture
            $result.agentTarget|Should -BeExactly 'kilocode';$result.root|Should -BeExactly $root
            @($result.arguments|Where-Object{$_ -ceq '-AgentTarget'}).Count|Should -Be 1
            (Get-FileHash $config).Hash|Should -BeExactly $before
            (Get-FileHash $manifest).Hash|Should -BeExactly $manifestBefore
            [IO.File]::WriteAllText($config,'{"aiRules":{"tools":["kilocode","codex"]}}',[Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText($manifest,'{"tools":["kilocode","codex"]}',[Text.UTF8Encoding]::new($false))
            $ambiguousHash=(Get-FileHash $config).Hash;$ambiguousManifestHash=(Get-FileHash $manifest).Hash
            {Invoke-SelectedFixture}|Should -Throw '*SOURCE_E2E_AGENT_TARGET_REQUIRED*same*command*-AgentTarget*'
            $AgentTarget='kilocode';(Invoke-SelectedFixture).agentTarget|Should -BeExactly 'kilocode'
            (Get-FileHash $config).Hash|Should -BeExactly $ambiguousHash
            (Get-FileHash $manifest).Hash|Should -BeExactly $ambiguousManifestHash
            [IO.File]::WriteAllText($config,'{"aiRules":{"tools":["kilocode"]}}',[Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText($manifest,'{"tools":["kilocode"]}',[Text.UTF8Encoding]::new($false))
            $unattachedConfigHash=(Get-FileHash $config).Hash;$unattachedManifestHash=(Get-FileHash $manifest).Hash
            $AgentTarget='codex'
            {Invoke-SelectedFixture}|Should -Throw '*failed with exit code*'
            (Get-Content (Join-Path $outputRoot 'same-operation.stderr.log') -Raw -Encoding UTF8)|Should -Match "ITL_CLIENT_NOT_ATTACHED: 'codex'"
            (Get-FileHash $config).Hash|Should -BeExactly $unattachedConfigHash
            (Get-FileHash $manifest).Hash|Should -BeExactly $unattachedManifestHash
            # Separate server targets resolve their own config, never the main Kilo root.
            $root=Join-Path $TestDrive ("$Runner server путь")
            $HelperPath=New-E2EClientFixture $root @('qwen');$AgentTarget=''
            (Invoke-SelectedFixture).agentTarget|Should -BeExactly 'qwen'
        }
    }

    It 'keeps the fresh journey on its bootstrap client despite an explicit upgrade client' {
        & {
            $root=Join-Path $TestDrive 'fresh путь с пробелами';$null=New-E2EClientFixture $root
            $outputRoot=Join-Path $root 'logs';New-Item -ItemType Directory $outputRoot|Out-Null
            $steps=New-Object 'Collections.Generic.List[object]';$activeJourney='fresh';$AgentTarget='codex'
            foreach($name in @('ConvertTo-DevelopProcessArgument','Invoke-DevelopProcess','Invoke-InstalledAction','Read-CompactSummary')){. ([scriptblock]::Create((Get-E2ETestDefinition 'scripts/invoke-develop-e2e.ps1' $name)))}
            (Read-CompactSummary (Invoke-InstalledAction -Name fresh -Root $root -Action status -TimeoutSeconds 30)).agentTarget|Should -BeExactly 'kilocode'
        }
    }

    It 'reloads an owned recovery write set through the actual checkpoint writer and canonical path validator' {
        & {
            foreach ($name in @('ConvertTo-E2EHashtable', 'Write-E2ECheckpoint')) {
                . ([scriptblock]::Create((Get-E2ETestDefinition 'scripts/invoke-release-e2e.ps1' $name)))
            }
            . (Join-Path $RepoRoot 'scripts/release-e2e/extension-recovery.ps1')
            $root = Join-Path $TestDrive 'checkpoint восстановление с пробелами'
            $checkpointPath = Join-Path $root '.agent-1c/runs/release-e2e/checkpoint.json'
            $paths = @('src/cfe/ITLReleaseSmoke/Languages/Русский.xml', 'src/cfe/ITLReleaseSmoke/Configuration.xml')
            $checkpoint = [ordered]@{
                schemaVersion = 3; runId = 'write-set-roundtrip'; expectedHead = ('a' * 40)
                extensionRecovery = [ordered]@{
                    writeSet = $paths
                    files = @([ordered]@{ path = $paths[0]; bytes = 31; sha256 = ('b' * 64) })
                    stopEvidence = [ordered]@{ launcherExited = $true; nativeQuiescent = $true }
                }
            }
            Write-E2ECheckpoint
            $reloaded = ConvertTo-E2EHashtable (Get-Content -LiteralPath $checkpointPath -Raw -Encoding UTF8 | ConvertFrom-Json)
            foreach ($path in @($reloaded.extensionRecovery.writeSet)) { $path | Should -BeOfType ([string]) }
            @($reloaded.extensionRecovery.writeSet) | Should -Be $paths
            $reloaded.extensionRecovery.files.path | Should -BeExactly $paths[0]
            $reloaded.extensionRecovery.files.bytes | Should -Be 31
            $reloaded.extensionRecovery.stopEvidence.launcherExited | Should -BeTrue
            $context = [ordered]@{
                projectRoot = $root; worktreePath = $root; commonGitPath = (Join-Path $root '.git')
                branch = 'itldev/fixture'; expectedHead = $reloaded.expectedHead
                checkpointPath = $checkpointPath; runId = $reloaded.runId
                infoBaseKind = 'file'; infoBasePath = (Join-Path $root '.agent-1c/infobases/fixture')
            }
            $set = Get-ReleaseExtensionRecoveryWriteSet -Context $context -ExtensionName 'ITLReleaseSmoke' -WriteSet @($reloaded.extensionRecovery.writeSet)
            @($set.paths) | Should -Be @($paths | Sort-Object)
            $set.root | Should -BeExactly (Join-Path $root 'src/cfe/ITLReleaseSmoke')
        }
    }
    It 'preserves scalar client identity through the actual immutable capability cache writer' {
        & {
            foreach($name in @('ConvertTo-E2EHashtable','Get-E2EGeneratedCommitRecords','Save-E2ECapabilityCache')){. ([scriptblock]::Create((Get-E2ETestDefinition 'scripts/invoke-release-e2e.ps1' $name)))}
            $ProjectRoot=Join-Path $TestDrive 'cache scalar путь с пробелами';$null=New-E2EClientFixture $ProjectRoot
            $clientSelectionIdentity=Get-SourceE2EClientIdentity -ProjectRoot $ProjectRoot -AgentTarget 'kilocode'
            $capabilityCacheRoot=Join-Path $ProjectRoot 'capability-cache'
            $checkpoint=[ordered]@{runId='scalar-identity';identity=[ordered]@{clientSelection=$clientSelectionIdentity};snapshots=[ordered]@{};stateFiles=[ordered]@{};stages=[ordered]@{};generatedCommits=@()}
            $manifestPath=Save-E2ECapabilityCache
            $saved=Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8|ConvertFrom-Json
            $saved.identity.clientSelection|Should -BeOfType ([string])
            $saved.identity.clientSelection|Should -BeExactly $clientSelectionIdentity
            $copied=ConvertTo-E2EHashtable $saved
            $copied.identity.clientSelection|Should -BeOfType ([string])
            $copied.identity.clientSelection|Should -BeExactly $clientSelectionIdentity
        }
    }
    It 'binds stage fingerprints and cache fallback to the client and actual server configuration' {
        & {
            $ProjectRoot=Join-Path $TestDrive 'fingerprint путь';$null=New-E2EClientFixture $ProjectRoot
            $server=Join-Path $TestDrive 'server fingerprint путь';$null=New-E2EClientFixture $server @('qwen')
            [IO.File]::WriteAllText((Join-Path $ProjectRoot '.agent-1c/release-e2e.json'),(@{serverWorktreePath=$server}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
            . (Join-Path $RepoRoot 'scripts/release-e2e/admission.ps1')
            foreach($name in @('Get-E2EStageAdmissionContext','Get-E2EStageFingerprint')){. ([scriptblock]::Create((Get-E2ETestDefinition 'scripts/invoke-release-e2e.ps1' $name)))}
            $workflowRoot=Join-Path $TestDrive 'recipe исходники';$stageModuleRoot=Join-Path $workflowRoot 'scripts/release-e2e'
            New-Item -ItemType Directory -Force $stageModuleRoot | Out-Null
            [IO.File]::WriteAllText((Join-Path $workflowRoot 'scripts/stand-env-identity.ps1'),'identity fixture',[Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $stageModuleRoot 'probe.ps1'),'probe fixture',[Text.UTF8Encoding]::new($false))
            $script:ReleaseE2EStageDefinitions=@{probe=@{version=1;dependsOn=@();paths=@();moduleFile='probe.ps1'}}
            $script:E2ETrackedInputFiles=@()
            function Get-E2EReleaseConfigValue {param($Name)''}
            $runnerSha256='runner';$workflowCommit='fixture';$aiRulesCommit='fork';$aiRulesTree='tree';$projectConfigSha256='config'
            $clientSelectionIdentity=Get-SourceE2EClientIdentity $ProjectRoot 'kilocode';$first=Get-E2EStageFingerprint probe
            $clientSelectionIdentity=Get-SourceE2EClientIdentity $ProjectRoot 'codex';(Get-E2EStageFingerprint probe)|Should -Not -Be $first
            $clientSelectionIdentity=Get-SourceE2EClientIdentity $ProjectRoot 'kilocode';(Get-E2EStageFingerprint probe)|Should -Be $first
            [IO.File]::WriteAllText((Join-Path $server '.agent-1c/project.json'),'{"aiRules":{"tools":["kilocode"]}}',[Text.UTF8Encoding]::new($false))
            $clientSelectionIdentity=Get-SourceE2EClientIdentity $ProjectRoot 'kilocode';(Get-E2EStageFingerprint probe)|Should -Not -Be $first
        }
    }

    It 'rejects old or differently selected cache proof even when source inputs are unchanged' {
        & {
            foreach($name in @('ConvertTo-E2EHashtable','Find-E2ECompletedCapabilityCache','Restore-E2EInterruptedCapabilityStage')){. ([scriptblock]::Create((Get-E2ETestDefinition 'scripts/invoke-release-e2e.ps1' $name)))}
            $capabilityCacheRoot=Join-Path $TestDrive 'cache client путь';New-Item -ItemType Directory $capabilityCacheRoot|Out-Null
            $manifest=Join-Path $capabilityCacheRoot 'manifest.json'
            $ProjectRoot=$TestDrive;$worktreePath=$TestDrive;$branch='itldev/probe';$aiRulesCommit='fork';$aiRulesTree='fork-tree';$projectConfigSha256='project'
            $workflowRoot=$RepoRoot;$workflowCommit='current';$workflowTree='current-tree';$serverResetConfigured=$false;$serverResetTestFixture=$false
            $clientSelectionIdentity='selected-kilo'
            $cache=@{schemaVersion=1;identity=@{projectRoot=$ProjectRoot;worktreePath=$worktreePath;branch=$branch;initialHead='initial';aiRulesCommit=$aiRulesCommit;aiRulesTree=$aiRulesTree;projectConfigSha256=$projectConfigSha256;workflowCommit='previous';runnerSha256='previous-runner';clientSelection=$clientSelectionIdentity};stages=@{};snapshots=@{};stateFiles=@{}}
            foreach($stage in @('seed-parallel','config-cadence','config-roundtrip','extension-smoke','ondemand-mcp')){$cache.stages[$stage]=@{status='passed';fingerprint='old';evidencePath=''}}
            foreach($snapshot in @('baseline','postConfig')){$cache.snapshots[$snapshot]=@{path='snapshot';sha256='snapshot-sha'};$cache.stateFiles[$snapshot]=@{stateCopyPath='state';stateSha256='state-sha';envCopyPath=''}}
            [IO.File]::WriteAllText($manifest,($cache|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
            $checkpoint=@{identity=@{initialHead='initial'};stages=@{'seed-parallel'=@{status='running'}}}
            function Get-WorkflowContinuationProof {param($RepositoryRoot,$QualifiedCommit,$CurrentCommit,$CurrentTree)$true}
            function Get-E2EStageFingerprint {param($Name,$RunnerSha256)'different-current-fingerprint'}
            function Test-E2EStageInputsUnchanged {param($Name,$QualifiedCommit)$true}
            function Assert-E2ECheckpointFile {param($Path,$Sha256,$Label)}
            function Write-E2ECheckpoint {}
            (Find-E2ECompletedCapabilityCache)|Should -BeExactly $manifest
            (Restore-E2EInterruptedCapabilityStage 'seed-parallel')|Should -BeTrue
            $checkpoint.stages['seed-parallel']=@{status='running'}
            $clientSelectionIdentity='selected-codex'
            (Find-E2ECompletedCapabilityCache)|Should -BeNullOrEmpty
            (Restore-E2EInterruptedCapabilityStage 'seed-parallel')|Should -BeFalse
            $clientSelectionIdentity='selected-kilo';$cache.identity.Remove('clientSelection')
            [IO.File]::WriteAllText($manifest,($cache|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
            (Find-E2ECompletedCapabilityCache)|Should -BeNullOrEmpty
            (Restore-E2EInterruptedCapabilityStage 'seed-parallel')|Should -BeFalse
            $checkpoint.stages['seed-parallel'].status|Should -BeExactly 'running'
        }
    }
}

Describe 'Shared Release budget projection' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        $budgetRepoRoot = $context.RepoRoot
        . (Join-Path $budgetRepoRoot 'scripts/quality-contracts.ps1')
        . (Join-Path $budgetRepoRoot 'scripts/source-delivery-process.ps1')
        function Get-BudgetOwnerAst {
            param([string]$RelativePath)
            $tokens = $null; $errors = $null
            $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $budgetRepoRoot $RelativePath), [ref]$tokens, [ref]$errors)
            if (@($errors).Count) { throw "Budget owner did not parse: $RelativePath" }
            return $ast
        }
    }

    It 'projects full and selected dependency budgets without broadening capability scope' {
        $stages = Get-QualityReleaseStageCatalog -RepositoryRoot $budgetRepoRoot
        $quality = Get-QualityContractCatalog -RepositoryRoot $budgetRepoRoot
        $full = Get-ReleaseE2EBudgetProjection -StageCatalog $stages -QualityCatalog $quality -RequireRelease
        $full.capabilities | Should -Be @($stages.stages.id)
        $full.fullStageSeconds | Should -Be 11700
        $full.enclosingOverheadSeconds | Should -Be 1140
        $full.e2eHardSeconds | Should -Be 12840
        $full.gateHardSeconds | Should -Be ($quality.budgets.fullHardSeconds + $full.e2eHardSeconds)
        $full.gateHardSeconds | Should -Be $quality.budgets.releaseHardSeconds
        $partial = Get-ReleaseE2EBudgetProjection -StageCatalog $stages -QualityCatalog $quality -ReleaseCapability @('extension-smoke','ondemand-mcp','verification-refresh','result-cleanup','extension-smoke')
        $partial.capabilities | Should -Be @('config-cadence','extension-smoke','ondemand-mcp','verification-refresh','result-cleanup')
        $partial.summedStageSeconds | Should -Be 8400
        $partial.e2eHardSeconds | Should -Be 9540
        $onlyMcp = Get-ReleaseE2EBudgetProjection -StageCatalog $stages -QualityCatalog $quality -ReleaseCapability 'ondemand-mcp'
        $onlyMcp.capabilities | Should -Be @('ondemand-mcp')
        $onlyMcp.e2eHardSeconds | Should -Be 2640
        $onlyMcp.gateHardSeconds | Should -Be $full.gateHardSeconds
        $none = Get-ReleaseE2EBudgetProjection -StageCatalog $stages -QualityCatalog $quality
        @($none.capabilities).Count | Should -Be 0
        $none.e2eHardSeconds | Should -Be 0
    }

    It 'keeps the old pinned supervisor allowance equal to the validated full projection' {
        $stages = Get-QualityReleaseStageCatalog -RepositoryRoot $budgetRepoRoot
        $quality = Get-QualityContractCatalog -RepositoryRoot $budgetRepoRoot
        $projection = Get-ReleaseE2EBudgetProjection -StageCatalog $stages -QualityCatalog $quality -RequireRelease
        # Exact legacy wire consumer: it only reads the serialized quality field.
        $oldCatalog = Get-Content -LiteralPath (Join-Path $budgetRepoRoot 'tests/quality-contracts.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $oldPinnedAllowance = [int]$oldCatalog.budgets.releaseHardSeconds + 300
        $oldPinnedAllowance | Should -Be ($projection.gateHardSeconds + 300)
        Get-SourceGateHardBudgetSeconds -Mode Release -WorkingRoot $budgetRepoRoot | Should -Be $oldPinnedAllowance
        Get-SourceGateSupervisionBudgetSeconds -Mode Release -WorkingRoot $budgetRepoRoot -PlanBudgetSeconds 8940 | Should -Be $oldPinnedAllowance
        Get-SourceGateSupervisionBudgetSeconds -Mode Release -WorkingRoot $budgetRepoRoot -PlanBudgetSeconds 16000 | Should -Be 16000
        $quality.budgets.releaseHardSeconds--
        { Get-ReleaseE2EBudgetProjection -StageCatalog $stages -QualityCatalog $quality -RequireRelease } | Should -Throw '*PROJECTION_MISMATCH*'
    }

    It 'retains old candidate budgets but rejects a malformed present contract and cycles' {
        $stages = Get-QualityReleaseStageCatalog -RepositoryRoot $budgetRepoRoot
        $quality = Get-QualityContractCatalog -RepositoryRoot $budgetRepoRoot
        $stages.PSObject.Properties.Remove('enclosingOverheadSeconds')
        ($stages.stages | Where-Object id -eq 'config-cadence').budgetSeconds = 1200
        $quality.budgets.releaseHardSeconds = 7200
        $old = Get-ReleaseE2EBudgetProjection -StageCatalog $stages -QualityCatalog $quality -ReleaseCapability 'extension-smoke'
        $old.usesLegacyModeBudget | Should -BeTrue
        $old.stageBudgets['config-cadence'] | Should -Be 1200
        $old.e2eHardSeconds | Should -Be 7200
        $old.gateHardSeconds | Should -Be 7200
        $stages | Add-Member -NotePropertyName enclosingOverheadSeconds -NotePropertyValue $null
        foreach ($bad in @($null, 0, -1, '1140', 1.5, [long]2147483648)) {
            $stages.enclosingOverheadSeconds = $bad
            { Get-ReleaseE2EBudgetProjection -StageCatalog $stages -QualityCatalog $quality -RequireRelease } | Should -Throw '*BUDGET_INVALID*'
        }
        $stages.enclosingOverheadSeconds = 1140
        ($stages.stages | Where-Object id -eq 'config-cadence').dependsOn = @('extension-smoke')
        { Resolve-QualityReleaseCapabilities -Catalog $stages -ReleaseCapability 'extension-smoke' } | Should -Throw '*DEPENDENCY_CYCLE*'
    }

    It 'passes the selected projection to the real child call and retains enclosing timeout clipping' {
        $ast = Get-BudgetOwnerAst -RelativePath 'scripts/check.ps1'
        $qualityCatalog = Get-QualityContractCatalog -RepositoryRoot $budgetRepoRoot
        $repoRoot = $budgetRepoRoot
        $effectiveMode = 'Release'
        $selectedReleaseCapabilities = @('extension-smoke','ondemand-mcp','verification-refresh','result-cleanup')
        $initialization = @($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.IfStatementAst] -and $_.Extent.Text.Contains('$releaseBudget = Get-ReleaseE2EBudgetProjection') })
        $initialization.Count | Should -Be 1
        . ([scriptblock]::Create($initialization[0].Extent.Text))
        $modeHardBudgetSeconds | Should -Be 15540
        $releaseE2EHardBudgetSeconds | Should -Be 9540
        $call = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Invoke-PowerShellChild' -and $node.Extent.Text.Contains('-LogName "release-e2e"') }, $true))
        $call.Count | Should -Be 1
        function Invoke-PowerShellChild {
            param($ScriptPath, $Arguments, $TimeoutSeconds, $NoProgressSeconds, $ProgressPaths, $LogName)
            [pscustomobject]@{ timeout=$TimeoutSeconds; noProgress=$NoProgressSeconds; name=$LogName }
        }
        $e2eScript = 'fixture'; $releaseE2EArguments = @(); $releaseProgressPaths = @()
        $observed = & ([scriptblock]::Create($call[0].Extent.Text))
        $observed.timeout | Should -Be 9540
        $observed.noProgress | Should -Be 900
        $wait = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Wait-PowerShellChildProcess' }, $true)
        $clip = @($wait.Body.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -in @('$remainingOverallSeconds', '$effectiveTimeoutSeconds') })
        $clip.Count | Should -Be 2
        $TimeoutSeconds = $observed.timeout
        $overallStopwatch = [pscustomobject]@{ Elapsed=[timespan]::FromSeconds(8600) }
        foreach ($statement in $clip) { . ([scriptblock]::Create($statement.Extent.Text)) }
        $effectiveTimeoutSeconds | Should -Be 6940
        $overallStopwatch = [pscustomobject]@{ Elapsed=[timespan]::FromSeconds(10) }
        foreach ($statement in $clip) { . ([scriptblock]::Create($statement.Extent.Text)) }
        $effectiveTimeoutSeconds | Should -Be 9540
    }

    It 'forwards the remaining original cadence deadline to the unchanged helper timeout owner' {
        $ast = Get-BudgetOwnerAst -RelativePath 'scripts/invoke-release-e2e.ps1'
        $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Complete-E2EHelperProcess' }, $true)
        . ([scriptblock]::Create($definition.Extent.Text))
        $process = [pscustomobject]@{ Handle=1; ExitCode=0; ExitTime=[DateTime]::UtcNow; timedWaits=[Collections.Generic.List[int]]::new() }
        $process | Add-Member ScriptMethod WaitForExit { param($milliseconds) if ($null -ne $milliseconds) { $this.timedWaits.Add([int]$milliseconds); return $true } }
        $process | Add-Member ScriptMethod Refresh {}
        $invocation = [pscustomobject]@{ process=$process; action='check-dev-branch'; stdoutPath='fixture.out'; stderrPath='fixture.err'; exitedAtUtc=$null }
        $script:activeStageName = 'config-cadence'
        $catalog = Get-QualityReleaseStageCatalog -RepositoryRoot $budgetRepoRoot
        $cadenceSeconds = [int]($catalog.stages | Where-Object id -eq 'config-cadence').budgetSeconds
        # A slow first metadata check consumes the observed fresh-check envelope.
        $remainingModelSeconds = $cadenceSeconds - 1773
        $script:activeStageDeadlineUtc = [DateTime]::UtcNow.AddSeconds($remainingModelSeconds)
        try {
            $result = Complete-E2EHelperProcess -Invocation $invocation -TimeoutSeconds 7200
            $result.exitCode | Should -Be 0
            $process.timedWaits.Count | Should -Be 1
            $process.timedWaits[0] | Should -BeGreaterThan 1773000
            $process.timedWaits[0] | Should -BeLessOrEqual ($remainingModelSeconds * 1000)
        } finally { $script:activeStageDeadlineUtc = $null; $script:activeStageName = '' }
    }
}

Describe 'Shared Release admission decisions' -Tag 'ReleaseAdmissionContract' {
    BeforeAll {
        . (Join-Path $RepoRoot 'scripts/git-path-list.ps1')
        . (Join-Path $RepoRoot 'scripts/release-qualification.ps1')
        . (Join-Path $RepoRoot 'scripts/release-e2e/workflow-transition.ps1')
        . (Join-Path $RepoRoot 'scripts/release-e2e/admission.ps1')
        function Get-AdmissionRunnerDefinition {
            param($Name)
            $tokens=$null;$errors=$null
            $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'scripts/invoke-release-e2e.ps1'),[ref]$tokens,[ref]$errors)
            if($errors){throw 'Release owner must parse'}
            $node=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $Name},$false)
            if(-not $node){throw "Missing Release owner $Name"};$node.Extent.Text
        }
        function New-AdmissionMergeFixture {
            param($Root,$CursorKind='')
            $utf8=[Text.UTF8Encoding]::new($false)
            New-Item -ItemType Directory -Force (Join-Path $Root 'src/cf'),(Join-Path $Root '.kilo'),(Join-Path $Root '.agent-1c') | Out-Null
            [IO.File]::WriteAllText((Join-Path $Root '.agent-1c/project.json'),'{"exportPath":"src/cf","aiRules":{"tools":["codex"]}}',$utf8)
            [IO.File]::WriteAllText((Join-Path $Root '.agent-1c/dependency-lock.json'),'{"schemaVersion":1,"dependencies":{}}',$utf8)
            [IO.File]::WriteAllText((Join-Path $Root 'src/cf/Configuration.xml'),'baseline',$utf8)
            & git -C $Root init -q -b master
            & git -C $Root config user.name 'Release merge admission'
            & git -C $Root config user.email 'merge@example.invalid'
            & git -C $Root add --all
            & git -C $Root commit -qm baseline
            & git -C $Root checkout -q -b itldev/admission
            [IO.File]::WriteAllText((Join-Path $Root 'branch.txt'),'branch workload',$utf8)
            & git -C $Root add -- branch.txt
            & git -C $Root commit -qm branch
            $anchor=(& git -C $Root rev-parse HEAD).Trim()
            & git -C $Root checkout -q master
            [IO.File]::WriteAllText((Join-Path $Root 'main.txt'),'main baseline',$utf8)
            & git -C $Root add -- main.txt
            & git -C $Root commit -qm main
            $main=(& git -C $Root rev-parse HEAD).Trim()
            & git -C $Root checkout -q itldev/admission
            & git -C $Root merge --no-ff -qm 'ordinary refresh' master
            if($LASTEXITCODE -ne 0){throw 'Original managed merge must exist'}
            if($CursorKind){
                [IO.File]::WriteAllText((Join-Path $Root 'src/cf/ConfigDumpInfo.xml'),'cursor',$utf8)
                & git -C $Root add -- src/cf/ConfigDumpInfo.xml
                if($CursorKind -eq 'state'){
                    [IO.File]::WriteAllText((Join-Path $Root '.kilo/kilo.json'),'{}',$utf8)
                    & git -C $Root add -- .kilo/kilo.json
                    & git -C $Root commit -qm 'chore: persist branch refresh state'
                }else{& git -C $Root commit -qm 'chore: persist branch configuration synchronization cursor'}
            }
            return @{root=$Root;head=(& git -C $Root rev-parse HEAD).Trim();anchor=$anchor;main=$main}
        }
    }

    It 'preserves the original managed <Kind> transition in early and runner predicates without changing Git' -ForEach @(@{Kind='merge'},@{Kind='cursor'},@{Kind='state'}) {
        $fixture=New-AdmissionMergeFixture (Join-Path $TestDrive ('Переход с пробелом '+$Kind)) $(if($Kind -eq 'merge'){''}else{$Kind})
        . ([scriptblock]::Create((Get-AdmissionRunnerDefinition 'Test-E2EManagedRefreshHead')))
        $context=@{projectRoot=$fixture.root;worktreePath=$fixture.root;branch='itldev/admission';resumeMode='Auto';workflowRoot=$RepoRoot;
            currentHead=$fixture.head;masterHead=$fixture.main;exportPath='src/cf';worktreeClean=$true;
            workflowCommit='';workflowTree='';runnerSha256='';helperSha256='';aiRulesCommit='';projectConfigSha256='';clientSelection='current'}
        $checkpoint=@{schemaVersion=3;expectedHead=$fixture.anchor;identity=@{projectRoot=$fixture.root;worktreePath=$fixture.root;branch='itldev/admission';clientSelection='previous'};stages=@{}}
        (Get-E2EReleaseCheckpointAdmission $context $checkpoint).allowed | Should -BeTrue
        Test-E2EManagedRefreshHead $fixture.root $fixture.head $fixture.anchor $fixture.main 'src/cf' $RepoRoot | Should -BeTrue
        (& git -C $fixture.root rev-parse HEAD).Trim() | Should -BeExactly $fixture.head
        @(& git -C $fixture.root status --porcelain) | Should -BeNullOrEmpty
    }

    It 'never reuses or rewrites a passed stage when cross-source continuation has no proof' {
        & {
            . ([scriptblock]::Create((Get-AdmissionRunnerDefinition 'Test-E2EStagePassed')))
            $checkpoint=@{stages=@{'ondemand-mcp'=@{status='passed';fingerprint='same';evidencePath=''}}}
            $crossReleaseReuse=$true;$releaseContinuationProof=$null;$previousRunnerSha256='previous';$continuationBoundaryStage=''
            $script:invalidatedStages=@();$script:invalidationDetails=@();$script:checkpointWrites=0
            function Get-E2EStageFingerprint {param($Name,$RunnerSha256)'same'}
            function Write-E2ECheckpoint {$script:checkpointWrites++}
            $before=$checkpoint|ConvertTo-Json -Depth 8
            Test-E2EStagePassed 'ondemand-mcp' | Should -BeFalse
            ($checkpoint|ConvertTo-Json -Depth 8) | Should -BeExactly $before
            $script:checkpointWrites | Should -Be 0
            $script:invalidationDetails[0].reason | Should -Match 'no exact Targeted proof'
        }
    }

    It 'keeps rebind eligibility pure and limits it to a proven earlier passed stage' {
        $record=@{status='passed';fingerprint='legacy'}
        $before=$record|ConvertTo-Json
        $beforeFailure=Get-E2EAdmissionStageDecision -Name 'config-cadence' -Record $record -CurrentFingerprint 'current' -LegacyFingerprint 'legacy' -CrossReleaseReuse $true -ContinuationProof @{kind='fixture'} -ContinuationBoundaryStage 'ondemand-mcp'
        $beforeFailure.action | Should -BeExactly 'rebind'
        (Get-E2EAdmissionStageDecision -Name 'extension-smoke' -Record $record -CurrentFingerprint 'current' -LegacyFingerprint 'legacy' -CrossReleaseReuse $true -ContinuationProof @{kind='fixture'} -ContinuationBoundaryStage 'config-cadence').action | Should -BeExactly 'rerun'
        $record.status='failed'
        (Get-E2EAdmissionStageDecision -Name 'config-cadence' -Record $record -CurrentFingerprint 'current' -LegacyFingerprint 'legacy' -CrossReleaseReuse $true -ContinuationProof @{kind='fixture'} -ContinuationBoundaryStage 'ondemand-mcp').action | Should -BeExactly 'rerun'
        $record.status='passed'
        ($record|ConvertTo-Json) | Should -BeExactly $before
    }

    It 'loads only isolated stage definitions and leaves ambient script registry and functions untouched' {
        $script:ReleaseE2EStageDefinitions=@{sentinel='outer'}
        $before=@(Get-Command Register-ReleaseE2EStageDefinition -ErrorAction SilentlyContinue)
        $definitions=Get-E2EAdmissionStageDefinitions $RepoRoot
        $definitions.Count | Should -Be 8
        $script:ReleaseE2EStageDefinitions.Count | Should -Be 1
        $script:ReleaseE2EStageDefinitions.sentinel | Should -BeExactly 'outer'
        @(Get-Command Register-ReleaseE2EStageDefinition -ErrorAction SilentlyContinue).Count | Should -Be $before.Count
    }

    It 'invalidates the changed stage and its dependency consumers while keeping unrelated schema 2 proof stable' {
        $root=Join-Path $TestDrive 'Fingerprint путь CRLF';$modules=Join-Path $root 'scripts/release-e2e'
        New-Item -ItemType Directory -Force $modules,(Join-Path $root 'input') | Out-Null
        $utf8=[Text.UTF8Encoding]::new($false)
        [IO.File]::WriteAllText((Join-Path $root 'scripts/stand-env-identity.ps1'),'environment owner',$utf8)
        foreach($name in @('base','child','unrelated')){[IO.File]::WriteAllText((Join-Path $modules "$name.ps1"),"stage $name",$utf8)}
        $shared=Join-Path $root 'input/Общий модуль.bsl'
        [IO.File]::WriteAllText($shared,"Процедура Первая()`r`nКонецПроцедуры`r`n",$utf8)
        [IO.File]::WriteAllText((Join-Path $root 'input/Другой.bsl'),'other',$utf8)
        $definitions=@{
            base=@{version=1;paths=@('input/Общий модуль.bsl');dependsOn=@();moduleFile='base.ps1'}
            child=@{version=1;paths=@();dependsOn=@('base');moduleFile='child.ps1'}
            unrelated=@{version=1;paths=@('input/Другой.bsl');dependsOn=@();moduleFile='unrelated.ps1'}
        }
        $context=@{workflowRoot=$root;stageModuleRoot=$modules;stageDefinitions=$definitions;trackedInputFilesProvided=$true;trackedInputFiles=@();
            aiRulesCommit='fork';aiRulesTree='fork-tree';projectConfigSha256='project';clientSelection='codex';serverConfiguration=@{}}
        $before=@{};foreach($name in @('base','child','unrelated')){$before[$name]=Get-E2EAdmissionStageFingerprint $context $name}
        [IO.File]::AppendAllText($shared, "// проверка`r`n", $utf8)
        (Get-E2EAdmissionStageFingerprint $context 'base') | Should -Not -Be $before.base
        (Get-E2EAdmissionStageFingerprint $context 'child') | Should -Not -Be $before.child
        (Get-E2EAdmissionStageFingerprint $context 'unrelated') | Should -BeExactly $before.unrelated
        $context.clientSelection='kilocode'
        (Get-E2EAdmissionStageFingerprint $context 'unrelated') | Should -Not -Be $before.unrelated
    }

    It 'rejects corrupted passed stage evidence before any checkpoint or evidence write' {
        $evidence=Join-Path $TestDrive 'Исходный receipt с пробелом.json'
        [IO.File]::WriteAllText($evidence,'unit receipt',[Text.UTF8Encoding]::new($false))
        $record=@{status='passed';fingerprint='same';evidencePath=$evidence;evidenceSha256=Get-E2EAdmissionFileSha256 $evidence}
        [IO.File]::AppendAllText($evidence,' tampered')
        $badHash=Get-E2EAdmissionFileSha256 $evidence
        {Assert-E2EAdmissionFile -Path $record.evidencePath -Sha256 $record.evidenceSha256 -Label 'stage evidence'} | Should -Throw '*RELEASE_E2E_CACHE_CORRUPT*'
        (Get-E2EAdmissionFileSha256 $evidence) | Should -BeExactly $badHash
        $record.fingerprint | Should -BeExactly 'same'
    }

    It 'preserves case-compatible SHA identity while requiring the exact selected client identity' {
        $context=@{projectRoot=$TestDrive;worktreePath=$TestDrive;branch='itldev/admission';resumeMode='Auto';workflowRoot=$RepoRoot;currentHead='same';masterHead='same';exportPath='src/cf';worktreeClean=$true;
            workflowCommit=('a'*40);workflowTree=('b'*40);runnerSha256=('c'*64);helperSha256=('d'*64);aiRulesCommit=('e'*40);projectConfigSha256=('f'*64);clientSelection='codex'}
        $identity=@{};foreach($name in @('projectRoot','worktreePath','branch','workflowCommit','workflowTree','runnerSha256','helperSha256','aiRulesCommit','projectConfigSha256','clientSelection')){$identity[$name]=$context[$name]}
        foreach($name in @('workflowCommit','workflowTree','runnerSha256','helperSha256','aiRulesCommit','projectConfigSha256')){$identity[$name]=$identity[$name].ToUpperInvariant()}
        $checkpoint=@{schemaVersion=3;expectedHead='same';identity=$identity}
        (Get-E2EReleaseCheckpointAdmission $context $checkpoint).exactIdentity | Should -BeTrue
        $identity.clientSelection='CODEX'
        $decision=Get-E2EReleaseCheckpointAdmission $context $checkpoint
        $decision.allowed | Should -BeTrue
        $decision.exactIdentity | Should -BeFalse
        $decision.continuationProof | Should -BeNullOrEmpty
    }
}
