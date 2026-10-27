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
            @($catalog.suites[0].ownerPaths) | Should -Be @(
                'src/cf/**','tests/features/**','tests/verification-suites.shared.json','tests/verification-suites.branch.json',
                '.agent-1c/dependency-lock.json',
                '.agents/skills/1c-workflow/scripts/lib/agent-1c.vanessa.ps1',
                '.agents/skills/1c-workflow/scripts/lib/agent-1c.yaxunit.ps1',
                '.agents/skills/1c-workflow/scripts/lib/agent-1c.verification-selection.ps1',
                '.agents/skills/1c-workflow/scripts/lib/agent-1c.verification-change.ps1',
                '.agents/skills/1c-workflow/scripts/lib/agent-1c.verification-modes.ps1')
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
