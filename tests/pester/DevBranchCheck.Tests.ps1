BeforeAll {
    . (Join-Path $PSScriptRoot 'DevBranchLifecycleSupport.ps1')
    . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
    function Get-VerificationModel { 'cumulative' }
    . (Join-Path $RepoRoot 'scripts/git-path-list.ps1')
}

Describe 'Check lifecycle and cursor ownership' {
    It 'rejects a selected missing profile through the public check before any load' {
        $root = Join-Path $TestDrive 'Public check проект с пробелом'
        foreach ($relative in @('.agent-1c/dev-branches', 'tests/features')) {
            New-Item -ItemType Directory -Force -Path (Join-Path $root $relative) | Out-Null
        }
        Set-Content -LiteralPath (Join-Path $root '.agent-1c/project.json') -Encoding UTF8 -Value '{"masterBranch":"master","testsPath":"tests/features","vanessaAutomation":{"testClientManifestPath":"tests/vanessa-testclients.json"}}'
        Set-Content -LiteralPath (Join-Path $root '.dev.env') -Encoding UTF8 -Value "ITL_VERIFICATION_MODEL=cumulative`nITL_VANESSA_TESTING=auto`nITL_YAXUNIT_TESTING=off"
        Set-Content -LiteralPath (Join-Path $root 'tests/features/Selected.feature') -Encoding UTF8 -Value "# language: ru`nФункционал: Selected`nСценарий: Selected`n  Дано я подключаю профиль TestClient `"Required`""
        Set-Content -LiteralPath (Join-Path $root 'tests/verification-suites.branch.json') -Encoding UTF8 -Value '{"schemaVersion":1,"suites":[{"id":"selected","purpose":"acceptance","featurePaths":["tests/features/Selected.feature"],"ownerPaths":["src/cf/**"]}]}'
        Set-Content -LiteralPath (Join-Path $root 'tests/vanessa-testclients.json') -Encoding UTF8 -Value '{"schemaVersion":1,"maxConcurrency":1,"profiles":[{"name":"Other"}]}'
        & git -C $root init -q -b master
        & git -C $root -c user.name=Check -c user.email=check@example.invalid add --all
        & git -C $root -c user.name=Check -c user.email=check@example.invalid commit -qm baseline
        $LASTEXITCODE | Should -Be 0
        & git -C $root switch -q -c itldev/demo
        $state = @{devBranchName='demo'; safeDevBranchName='demo'; devBranch='itldev/demo'; devBranchKind='configuration'; worktreePath=$root; infoBaseKind='file'; devBranchInfoBasePath=(Join-Path $root 'ib')}
        Set-Content -LiteralPath (Join-Path $root '.agent-1c/dev-branches/demo.json') -Encoding UTF8 -Value ($state | ConvertTo-Json)
        $run = Invoke-Agent1cEntrypointProbe -ProbeId 'check-selected-profile-preflight' -HelperPath $HelperPath -ProjectRoot $root -Action 'check-dev-branch' -Arguments @{ RunStatusPath='.agent-1c/runs/check.json' }
        $run.exitCode | Should -Be 1 -Because $run.combinedText
        $status = Get-Content -LiteralPath (Join-Path $root '.agent-1c/runs/check.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $status.errorCategory | Should -Be 'runner' -Because $run.combinedText
        $status.requiredAction | Should -Be '/itl-verify-fix'
        $run.combinedText | Should -Match 'ITL_VANESSA_TESTCLIENT_PROFILES_MISSING.*Required'
        $status.stage | Should -Not -Match 'update|designer'
        Test-Path -LiteralPath (Join-Path $root 'ib') | Should -BeFalse
    }

    It "restores the project dump cursor before <operation> verification when the caller directory differs" -TestCases @(
        @{ operation = 'check' },
        @{ operation = 'export' }
    ) {
        param([string]$operation)
        $targetRoot = Join-Path $TestDrive "Рабочий проект $operation"
        $callerRoot = Join-Path $TestDrive "Чужой каталог $operation"
        foreach ($root in @($targetRoot, $callerRoot)) {
            New-Item -ItemType Directory -Path (Join-Path $root 'src/cf') -Force | Out-Null
        }
        $targetCursor = Join-Path $targetRoot 'src/cf/ConfigDumpInfo.xml'
        $callerCursor = Join-Path $callerRoot 'src/cf/ConfigDumpInfo.xml'
        $utf8Bom = [Text.UTF8Encoding]::new($true)
        $originalBytes = [byte[]](@($utf8Bom.GetPreamble()) + @($utf8Bom.GetBytes("<Версия>исходная</Версия>`r`n")))
        $foreignBytes = [Text.Encoding]::UTF8.GetBytes("<Версия>чужая</Версия>`n")
        [IO.File]::WriteAllBytes($targetCursor, $originalBytes)
        [IO.File]::WriteAllBytes($callerCursor, $foreignBytes)
        $originalBase64 = [Convert]::ToBase64String($originalBytes)
        $foreignBase64 = [Convert]::ToBase64String($foreignBytes)

        $result = & {
            . $HelperPath -ProjectRoot $targetRoot -Action help *> $null
            function Get-VerificationModel { 'cumulative' }
            $state = [pscustomobject]@{ devBranch = 'itldev/branch1'; devBranchName = 'branch1'; safeDevBranchName = 'branch1'; devBranchInfoBasePath = 'C:\base'; infoBaseKind = 'file' }
            $script:OneCNativeOperationJournal = New-OneCNativeOperationJournal
            $script:CursorChangedByLoad = $false
            $script:CursorAtVerification = [Collections.Generic.List[string]]::new()
            function Read-DevBranchState { $state }
            function Assert-DevelopmentBranchWorktreeContext {}
            function Assert-DevBranchExtensionInitialized {}
            function Assert-SingleManagedExtensionArtifact {}
            function Sync-DevBranchContextToDotEnv {}
            function Get-DevBranchKind { 'configuration' }
            function Get-ExportPath { 'src/cf' }
            function Repair-OneCSourceLineEndings {}
            function Get-ConfigRepositoryTransferPlan { [pscustomobject]@{ baseCommit = 'master-commit'; items = @(); unresolvedPaths = @() } }
            function Get-CurrentCommit { 'base-commit' }
            function Get-GitCommitOrEmpty { 'master-commit' }
            function Get-VerificationState {
                $script:CursorAtVerification.Add([Convert]::ToBase64String([IO.File]::ReadAllBytes($targetCursor)))
                [pscustomobject]@{ isFreshPassed = $true; effectiveStatus = 'passed'; currentFingerprint = 'v3|fixture'; verifiedFingerprint = 'v3|fixture' }
            }
            function Confirm-UnverifiedProceed { $false }
            function Invoke-DevBranchVanessaRuntimeRelease {}
            function Assert-VanessaVerificationPreflight {}
            function Test-ItlFullVerificationProofEligible { $true }
            # Keep this fixture focused on the real ProjectRoot dump cursor.
            function Assert-VerificationClassificationReady {}
            function Ensure-DevBranchEventLogBaseline { param($State) $State }
            function Ensure-DevBranchEventLogPendingCursor { [pscustomobject]@{ path = 'cursor.json'; capturedAt = [datetime]'2026-07-28T00:00:00Z' } }
            function Write-NativeLoadCursor {
                # Native loading updates the real ProjectRoot cursor independently
                # of the caller's working directory and the snapshot resolver.
                [IO.File]::WriteAllBytes($targetCursor, [Text.Encoding]::UTF8.GetBytes('<Версия>загруженная</Версия>'))
                $script:CursorChangedByLoad = [Convert]::ToBase64String([IO.File]::ReadAllBytes($targetCursor)) -cne $originalBase64
            }
            function Update-DevBranchBase { Write-NativeLoadCursor }
            function Invoke-ItlVerificationCycle { $script:CursorAtVerification.Add([Convert]::ToBase64String([IO.File]::ReadAllBytes($targetCursor))) }
            function Load-ConfigFromFiles { Write-NativeLoadCursor; [pscustomobject]@{ currentCommit = 'base-commit'; sourceFingerprint = 'config-fingerprint' } }
            function New-LoadStateUpdates { @{} }
            function Invoke-DevBranchEnterpriseAutoUpdateIfLoaded {}
            function Add-VerificationStaleIfNeeded {}
            function Update-DevBranchState {}
            function Invoke-DevBranchMcpRestartAfterInfobaseLoad { param($State) $State }
            function Assert-DevBranchToolArtifactExportGuard {}
            function Export-DevBranchResultFile { Join-Path $targetRoot 'result.cf' }
            function Test-GitHasChanges { $false }
            function Get-VerificationWorkingTreeChangePaths { @() }
            function Get-VerificationFingerprintScopePaths { @('src/cf') }
            function New-ResultManifest { Join-Path $targetRoot 'result.cf.manifest.json' }

            $previousNativeDirectory = [Environment]::CurrentDirectory
            Push-Location -LiteralPath $callerRoot
            try {
                [Environment]::CurrentDirectory = $callerRoot
                if ($operation -eq 'check') { Invoke-DevBranchCheck } else { Export-DevBranchResult 6>$null }
            } finally {
                [Environment]::CurrentDirectory = $previousNativeDirectory
                Pop-Location
            }
            [pscustomobject]@{
                loadChangedCursor = $script:CursorChangedByLoad
                verificationCursors = @($script:CursorAtVerification)
                targetBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($targetCursor))
                callerBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($callerCursor))
                journal = $script:OneCNativeOperationJournal
            }
        }

        $result.loadChangedCursor | Should -BeTrue
        $result.verificationCursors.Count | Should -BeGreaterThan 0
        foreach ($cursor in $result.verificationCursors) { $cursor | Should -BeExactly $originalBase64 }
        $result.targetBytes | Should -BeExactly $originalBase64
        $result.callerBytes | Should -BeExactly $foreignBase64
        $result.journal.restorations.Count | Should -Be 1
        $duty = $result.journal.restorations[0].payload
        $duty.destination | Should -BeExactly $targetCursor
        $duty.status | Should -Be 'restored'
        Test-Path -LiteralPath $duty.snapshotPath | Should -BeFalse
    }

    It "reconciles a verified failed-refresh recovery before another refresh or after check verification" {
        $refreshMatch = [regex]::Match($HelperText, "(?s)function\s+Invoke-RefreshDevBranchCore\s*\{(?<body>.*?)(?=`r?`nfunction\s+Refresh-DevBranch\s*\{)")
        $refreshMatch.Success | Should -BeTrue
        $refreshBody = $refreshMatch.Groups["body"].Value
        $refreshReconcileIndex = $refreshBody.IndexOf("Complete-PendingDevBranchRefreshAfterVerifiedRecovery")
        $refreshResumeIndex = $refreshBody.IndexOf("Resume-DevBranchLifecycleMergeIfPresent")
        $refreshReconcileIndex | Should -BeGreaterOrEqual 0
        $refreshResumeIndex | Should -BeGreaterThan $refreshReconcileIndex

        $checkMatch = [regex]::Match($HelperText, "(?s)function\s+Invoke-DevBranchCheck\s*\{(?<body>.*?)(?=`r?`nfunction\s+Check-DevBranch\s*\{)")
        $checkMatch.Success | Should -BeTrue
        $checkBody = $checkMatch.Groups["body"].Value
        $verificationIndex = $checkBody.IndexOf("Invoke-ItlVerificationCycle")
        $checkReconcileIndex = $checkBody.IndexOf("Complete-PendingDevBranchRefreshAfterVerifiedRecovery")
        $verificationIndex | Should -BeGreaterOrEqual 0
        $checkReconcileIndex | Should -BeGreaterThan $verificationIndex
    }
}

Describe "Named scenario repair round" {
    It "uses one owned load and attempt for diagnostic and unfiltered proof" {
        $VerificationTrigger = 'repair'
        $RepairSessionId = 'scenario-session'
        $VanessaFeaturePath = 'tests/features/Named.feature'
        $VanessaFilterTags = ''
        $script:scenarioPhases = [Collections.Generic.List[bool]]::new()
        $state = [pscustomobject]@{ lastVerificationEvidenceKind = 'full' }
        Mock Assert-ItlVerificationRepairScope {}
        Mock Read-DevBranchState { $state }
        Mock Get-DevBranchKind { 'configuration' }
        Mock Get-ExportPath { 'src/cf' }
        Mock Resolve-Agent1cFullPath { param($Path) $Path }
        Mock New-ConfigDumpInfoLoadSnapshot { [pscustomobject]@{} }
        Mock Restore-ConfigDumpInfoLoadSnapshot {}
        Mock Remove-ConfigDumpInfoLoadSnapshot {}
        Mock Invoke-DevBranchVanessaRuntimeRelease {}
        Mock Assert-VanessaVerificationPreflight {}
        Mock Test-ItlFullVerificationProofEligible { $script:scenarioPhases.Count -gt 0 }
        Mock Get-ItlMatchingVerificationRepairSession { [pscustomobject]@{ kind='scenario-loop'; sessionId='scenario-session' } }
        Mock Test-ItlDiagnosticVerificationScope { $true }
        Mock Get-ItlVerificationExecutionDecision { [pscustomobject]@{ run=$true } }
        # Classification is delegated in this repair-phase sequencing fixture;
        # the preflight owner tests exercise its rejection and continuation.
        Mock Repair-OneCSourceLineEndings {}
        Mock Assert-VerificationClassificationReady {}
        Mock Use-ItlVerificationRepairAttempt {}
        Mock Ensure-DevBranchEventLogBaseline { $state }
        Mock Ensure-DevBranchEventLogPendingCursor { [pscustomobject]@{path='cursor';capturedAt=[datetime]::UtcNow} }
        Mock Update-DevBranchBase {}
        Mock Invoke-ItlVerificationCycle {
            param($Trigger, $ExplicitComponents, $ScenarioDiagnosticOnly, $EventLogCursorPath, $EventLogBoundaryAt, $EventLogCursorScope)
            $script:scenarioPhases.Add([bool]$ScenarioDiagnosticOnly)
        }
        Mock Complete-PendingDevBranchRefreshAfterVerifiedRecovery {}
        Mock Get-VerificationState { [pscustomobject]@{ status='passed'; isFreshPassed=$true } }
        Mock Complete-ItlVerificationRepairSession {}
        Mock Complete-ItlVerificationRepairFailure {}

        Invoke-DevBranchCheck

        @($script:scenarioPhases.ToArray()) | Should -Be @($true, $false)
        Should -Invoke Use-ItlVerificationRepairAttempt -Times 1 -Exactly
        Should -Invoke Update-DevBranchBase -Times 1 -Exactly
        Should -Invoke Complete-ItlVerificationRepairSession -Times 1 -Exactly
    }
}

Describe 'Git tree object lookup' {
    It 'answers every path of an immutable tree from one listing exactly like rev-parse' {
        # 2026-10-27 Develop upgrade: two git processes per src/cf file for a
        # wildcard proof input outlasted the runner's stale-status watchdog.
        $tree = (& git -C $RepoRoot rev-parse 'HEAD:tests').Trim()
        $paths = @(& git -C $RepoRoot -c core.quotepath=false ls-tree -r --name-only $tree -- pester | Select-Object -First 25) +
            @('pester', 'pester/', 'pester\TestSupport.ps1', 'pester/Нет такого файла.ps1')
        Mock Get-GitPathList { @(Get-GitPathListAt -Root $RepoRoot -Arguments $Arguments) }
        foreach ($path in $paths) {
            $normalized = ($path -replace '\\', '/').Trim('/')
            $expected = (& git -C $RepoRoot -c core.quotepath=false rev-parse --verify --quiet "${tree}:$normalized")
            if ($LASTEXITCODE -ne 0) { $expected = '<missing>' }
            Get-GitObjectIdForTreePath -Treeish $tree -RepoPath $path | Should -BeExactly ([string]$expected).Trim() -Because $path
        }
        Should -Invoke Get-GitPathList -Times 1 -Exactly
    }
}

Describe 'Check duration journal' {
    It 'reports component durations and keeps a bounded project journal shared by branches' {
        $main = Join-Path $TestDrive 'Основной проект с пробелом'
        New-Item -ItemType Directory -Force -Path $main | Out-Null
        $state = [pscustomobject]@{ devBranch = 'itldev/demo'; mainWorktreePath = $main }

        Start-ItlCheckTiming
        Set-ItlCheckTimingValue -Name platformMs -Value 65000
        Set-ItlCheckTimingValue -Name vanessaMs -Value 120000
        Set-ItlCheckTimingValue -Name selectionMode -Value 'incremental'
        $text = Format-DevBranchCheckDurationText -Timing (Get-ItlCheckTimingSnapshot)
        $text | Should -Match 'загрузка 1 мин 5 с'
        $text | Should -Match 'Vanessa 2 мин 0 с'
        $text | Should -Not -Match 'YAxUnit'
        $text | Should -Match 'наборы Vanessa: incremental'

        $path = Get-ItlCheckHistoryPath -State $state
        $path | Should -BeExactly (Join-Path $main '.agent-1c\verification-selection\check-history.jsonl')
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
        $old = 1..600 | ForEach-Object { '{"at":"2026-11-01T00:00:00Z","branch":"itldev/other","status":"passed","totalMs":' + ($_ * 1000) + ',"selectionMode":"full"}' }
        [IO.File]::WriteAllText($path, (($old -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))
        Add-ItlCheckHistoryRecord -State $state -Status 'passed' -Trigger 'command'
        $lines = @(Get-Content -LiteralPath $path -Encoding UTF8 | Where-Object { $_.Trim() })
        $lines.Count | Should -Be 500
        $last = $lines[-1] | ConvertFrom-Json
        $last.branch | Should -BeExactly 'itldev/demo'
        $last.platformMs | Should -Be 65000
        $last.selectionMode | Should -BeExactly 'incremental'

        $status = @(Write-ItlCheckHistoryStatusLines -State $state 6>&1 | ForEach-Object { [string]$_ })
        @($status | Where-Object { $_ -like 'Check *: passed, *(load 65s, Vanessa 120s); Vanessa suites incremental' }).Count | Should -Be 1
        @($status | Where-Object { $_ -match '^Project check median: \d+s over 500 passed runs; full Vanessa selections: 499 of 500$' }).Count | Should -Be 1
    }

    It 'never fails the check when the journal cannot be written' {
        $main = Join-Path $TestDrive 'Проект с занятым журналом'
        New-Item -ItemType Directory -Force -Path (Join-Path $main '.agent-1c') | Out-Null
        # A file where the journal directory belongs makes every write fail.
        [IO.File]::WriteAllText((Join-Path $main '.agent-1c\verification-selection'), 'not a directory', [Text.UTF8Encoding]::new($false))
        Start-ItlCheckTiming
        { Add-ItlCheckHistoryRecord -State ([pscustomobject]@{ devBranch = 'itldev/demo'; mainWorktreePath = $main }) -Status 'failed' -Trigger 'command' 3>$null } | Should -Not -Throw
        Test-Path -LiteralPath (Join-Path $main '.agent-1c\verification-selection') -PathType Leaf | Should -BeTrue
    }

    It 'records per-feature Vanessa seconds from the run JUnit' {
        $main = Join-Path $TestDrive 'Журнал фич с пробелом'
        $run = Join-Path $main 'build\test-results\vanessa\run 1'
        New-Item -ItemType Directory -Force -Path $run | Out-Null
        [IO.File]::WriteAllText((Join-Path $run 'junit.xml'), @'
<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
	<testsuite name="Канбан: операции" tests="2" failures="0" time="1855.4"><testcase name="a" time="1855.4"/></testsuite>
	<testsuite name="Закрытие доски" tests="1" failures="1" time="72.1"><testcase name="b" time="72.1"/></testsuite>
	<testsuite name="Пустая" tests="0" time="0"/>
</testsuites>
'@, [Text.UTF8Encoding]::new($true))
        $state = [pscustomobject]@{ devBranch = 'itldev/demo'; mainWorktreePath = $main }
        Start-ItlCheckTiming
        Set-ItlCheckTimingValue -Name vanessaRunDirectory -Value $run
        Add-ItlCheckHistoryRecord -State $state -Status 'partial' -Trigger 'command'
        $last = (@(Get-Content -LiteralPath (Get-ItlCheckHistoryPath -State $state) -Encoding UTF8 | Where-Object { $_.Trim() })[-1]) | ConvertFrom-Json
        @($last.vanessaFeatureSeconds.PSObject.Properties.Name) | Should -Be @('Канбан: операции', 'Закрытие доски')
        $last.vanessaFeatureSeconds.'Канбан: операции' | Should -Be 1856
        $last.vanessaFeatureSeconds.'Закрытие доски' | Should -Be 73
    }

    It 'sizes the Vanessa run budget from recorded feature durations: <case>' -ForEach @(
        @{ case = 'no history'; history = @(); setting = $null; seconds = 1800; source = 'default' },
        @{ case = 'long selected features'; history = @(@{ 'Канбан: операции' = 2000; 'Закрытие доски' = 100 }, @{ 'Канбан: операции' = 1800 }); setting = $null; seconds = 3270; source = 'history of 2 of 3 selected features' },
        @{ case = 'capped'; history = @(@{ 'Канбан: операции' = 20000 }); setting = $null; seconds = 7200; source = 'history of 1 of 3 selected features' },
        @{ case = 'explicit setting'; history = @(@{ 'Канбан: операции' = 20000 }); setting = '900'; seconds = 900; source = 'setting VANESSA_TEST_TIMEOUT_SECONDS' }
    ) {
        # PM5 itldev/branch4, 2026-11-16/17: green Vanessa runs of 2700-3500 s
        # failed the fixed 1800 s default; the agent raised it per process.
        $main = Join-Path $TestDrive ('Бюджет Vanessa ' + $case)
        $features = Join-Path $main 'tests\features'
        New-Item -ItemType Directory -Force -Path $features | Out-Null
        $files = @()
        foreach ($title in @('Канбан: операции', 'Закрытие доски', 'Новая фича')) {
            $file = Join-Path $features ($title.Replace(':', '') + '.feature')
            [IO.File]::WriteAllText($file, "#language: ru`n`n@tree`nФункционал: $title`n`nСценарий: проверка`n", [Text.UTF8Encoding]::new($true))
            $files += $file
        }
        $state = [pscustomobject]@{ devBranch = 'itldev/demo'; mainWorktreePath = $main }
        $journal = Get-ItlCheckHistoryPath -State $state
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $journal) | Out-Null
        $lines = @($history | ForEach-Object { [ordered]@{ at = '2026-11-17T00:00:00Z'; branch = 'itldev/other'; status = 'passed'; vanessaFeatureSeconds = $_ } | ConvertTo-Json -Compress -Depth 4 })
        [IO.File]::WriteAllText($journal, (($lines + @('not json')) -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
        $saved = [Environment]::GetEnvironmentVariable('VANESSA_TEST_TIMEOUT_SECONDS', 'Process')
        try {
            [Environment]::SetEnvironmentVariable('VANESSA_TEST_TIMEOUT_SECONDS', $setting, 'Process')
            $budget = Get-VanessaRunTimeoutBudget -FeatureFiles $files -State $state
        } finally {
            [Environment]::SetEnvironmentVariable('VANESSA_TEST_TIMEOUT_SECONDS', $saved, 'Process')
        }
        $budget.seconds | Should -Be $seconds
        $budget.source | Should -BeExactly $source
    }
}