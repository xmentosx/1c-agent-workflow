BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSupport.ps1')
    $context = Initialize-WorkflowPesterContext
    $script:SharedExportHelper = $context.HelperPath

    function Invoke-SharedBaseExportFixture {
        param([string]$Kind = 'configuration', [string]$Failure = '', [string]$Operation = 'export')
        $root = Join-Path $TestDrive (([guid]::NewGuid().ToString('N')) + '/Экспорт с пробелом')
        $base = Join-Path $root 'База с пробелом'
        New-Item -ItemType Directory -Path $base -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $root '1cv8.exe'), (Join-Path $base '1Cv8.1CD') -Force | Out-Null
        & {
            param($Root, $Base, $Kind, $Failure, $Operation)
            . $script:SharedExportHelper -ProjectRoot $Root -Action help *> $null
            $script:Config = [pscustomobject]@{
                platformPath = (Join-Path $Root '1cv8.exe'); logsPath = 'logs'; artifactsPath = 'Результаты экспорта'
                designerMaxWorkingSetMb = 0; designerOperationTimeoutSeconds = 30
                designerDumpStabilitySeconds = 0; completionPostExitTimeoutSeconds = 5
            }
            $script:CaseFailure = $Failure
            $script:ProbePassed = $false
            $script:OneCNativeOperationJournal = New-OneCNativeOperationJournal
            $script:ReleaseProbeRequests = 0
            $script:NativeArguments = @()
            $script:OutputPath = ''
            $script:FixtureState = [pscustomobject]@{
                devBranchName = 'Ветка теста'; safeDevBranchName = 'Ветка теста'; devBranch = 'itldev/fixture'
                devBranchInfoBasePath = $Base; infoBaseKind = 'file'
            }
            $script:VerificationReads = 0
            $script:LoadRequests = 0
            $script:PublishedManifest = ''
            function Read-DevBranchState { $script:FixtureState }
            function Assert-DevelopmentBranchWorktreeContext {}
            function Assert-DevBranchExtensionInitialized {}
            function Assert-SingleManagedExtensionArtifact {}
            function Repair-OneCSourceLineEndings {}
            function Sync-DevBranchContextToDotEnv {}
            function Get-DevBranchKind { $Kind }
            function Get-ExportPath { 'src/cf' }
            function Assert-ExtensionFilesReady { 'src/cfe/ТестовоеРасширение' }
            function Get-ConfigRepositoryTransferPlan { [pscustomobject]@{ baseCommit = 'master'; items = @(); unresolvedPaths = @() } }
            function Get-CurrentCommit { 'fixture-commit' }
            function Get-GitCommitOrEmpty { 'master-commit' }
            function Get-VerificationState {
                $script:VerificationReads++
                $fingerprint = if ($script:CaseFailure -eq 'source-changed' -and $script:VerificationReads -ge 3) { 'changed' } else { 'v3|fixture' }
                $fresh = -not ($script:CaseFailure -eq 'verification-lost' -and $script:VerificationReads -ge 3)
                [pscustomobject]@{
                    status = 'passed'; effectiveStatus = $(if ($fresh) { 'passed' } else { 'stale' }); isFreshPassed = $fresh
                    verifiedCommit = 'fixture-commit'; currentCommit = 'fixture-commit'
                    verifiedFingerprint = 'v3|fixture'; currentFingerprint = $fingerprint
                    verifiedAt = '2026-09-09T00:00:00Z'; reportPath = 'report'; logPath = 'verification.log'; reason = 'fixture'
                }
            }
            function New-ConfigDumpInfoLoadSnapshot { [pscustomobject]@{} }
            function Restore-ConfigDumpInfoLoadSnapshot {}
            function Remove-ConfigDumpInfoLoadSnapshot {}
            function Load-ConfigFromFiles {
                $script:LoadRequests++
                [pscustomobject]@{ loaded = $false; currentCommit = 'fixture-commit'; sourceFingerprint = 'config-fingerprint' }
            }
            function New-LoadStateUpdates { @{} }
            function Invoke-DevBranchEnterpriseAutoUpdateIfLoaded {}
            function Add-VerificationStaleIfNeeded {}
            function Update-DevBranchState {
                param([object]$State, [hashtable]$Updates)
                if ($Updates.ContainsKey('lastResultManifestPath')) { $script:PublishedManifest = $Updates.lastResultManifestPath }
            }
            function Invoke-DevBranchMcpRestartAfterInfobaseLoad { param([object]$State) $State }
            function Assert-DevBranchToolArtifactExportGuard {}
            function Test-GitHasChanges { $false }
            function Get-VerificationWorkingTreeChangePaths { @() }
            function Get-VerificationFingerprintScopePaths { @('src/cf', 'src/cfe', 'tests/features') }
            function Require-DevBranchExtensionName { return 'ТестовоеРасширение' }
            function Receive-DesignerProcessEnumeration {
                param([object]$ProbeState, [string]$LogPath)
                $releaseChecked = [bool]$ProbeState.infoBaseReleaseDatabasePath
                if ($releaseChecked) { $script:ReleaseProbeRequests++ }
                $inventory = @([pscustomobject]@{
                    Name = '1cv8c.exe'; ProcessId = 89765; ParentProcessId = 100
                    CommandLine = "ENTERPRISE /F `"$Base`" /Out unrelated-roctup.log"
                })
                if ($script:CaseFailure -eq 'owned-process-active') {
                    $inventory += [pscustomobject]@{
                        Name = '1cv8.exe'; ProcessId = 87005; ParentProcessId = 100
                        CommandLine = "DESIGNER /Out `"$LogPath`""
                    }
                }
                [pscustomobject]@{
                    status = 'completed'; processes = $inventory; infoBaseReleaseChecked = $releaseChecked
                    infoBaseReleased = ($releaseChecked -and (Test-DesignerInfoBaseReleased -InfoBaseKind file -InfoBasePath $Base))
                }
            }
            function Invoke-OneCSessionAdmissionSet { param($Admissions, $StartProcess) & $StartProcess }
            function Invoke-NativeProcessAndWaitResult {
                param(
                    [string]$FilePath, [string[]]$Arguments, [int]$TimeoutSeconds,
                    [scriptblock]$OnTimeout, [scriptblock]$CompletionProbe,
                    [int]$CompletionGraceSeconds, [int]$PostExitProbeSeconds, [int]$MaxWorkingSetMb
                )
                Invoke-OneCSessionProcessStart -StartProcess { [pscustomobject]@{ Id = 87005 } } | Out-Null
                $script:NativeArguments = @($Arguments)
                $logPath = $Arguments[[Array]::IndexOf($Arguments, '/Out') + 1]
                $outputIndex = [Array]::IndexOf($Arguments, '/DumpCfg')
                if ($outputIndex -lt 0) { $outputIndex = [Array]::IndexOf($Arguments, '/DumpIB') }
                $script:OutputPath = $Arguments[$outputIndex + 1]
                New-Item -ItemType Directory -Path (Split-Path $script:OutputPath) -Force | Out-Null
                $text = if ($script:CaseFailure -eq 'empty-output') { '' } else { 'compiled fixture output' }
                [IO.File]::WriteAllText($script:OutputPath, $text, [Text.UTF8Encoding]::new($false))
                $log = if ($script:CaseFailure -eq 'log-error') { 'Error saving configuration' } else { 'Configuration saved successfully' }
                [IO.File]::WriteAllText($logPath, $log, [Text.UTF8Encoding]::new($false))
                $exitCode = if ($script:CaseFailure -eq 'nonzero-exit') { 1 } else { 0 }
                $probeContext = [pscustomobject]@{
                    launcherExited = $true; launcherExitCode = $exitCode; processId = 87005; postExitElapsedSeconds = 0
                }
                foreach ($attempt in 1..40) {
                    $script:ProbePassed = [bool](& $CompletionProbe $probeContext)
                    if ($script:ProbePassed) { break }
                    Start-Sleep -Milliseconds 100
                }
                [pscustomobject]@{
                    processId = 87005; exitCode = $exitCode; timedOut = $false
                    postExitProbeTimedOut = (-not $script:ProbePassed); completedByProbe = $script:ProbePassed
                    memoryLimitExceeded = $false; memoryMonitorFailed = $false; memoryMonitorError = ''
                    peakWorkingSetMb = 0; workingSetLimitMb = 0; terminationConfirmed = $true; terminationError = ''
                    launcherExited = $true; launcherExitCode = $exitCode
                }
            }
            $databasePath = Join-Path $Base '1Cv8.1CD'
            $holder = [IO.File]::Open($databasePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
            try {
                $lockedBefore = -not (Test-DesignerInfoBaseReleased -InfoBaseKind file -InfoBasePath $Base)
                $errorMessage = ''
                $path = ''
                try {
                    if ($Operation -eq 'public-export') {
                        Export-DevBranchResult 6>$null
                        $path = $script:RunResultPath
                    } elseif ($Operation -eq 'export') {
                        $state = [pscustomobject]@{ safeDevBranchName = 'Ветка теста' }
                        $path = Export-DevBranchResultFile -State $state -InfoBasePath $Base -InfoBaseKind file -ContentKind $Kind 6>$null
                    } else {
                        $arguments = if ($Operation -eq 'dump-ib') {
                            @('/DumpIB', (Join-Path $Root 'snapshot.dt'))
                        } else {
                            @('/DumpCfg', (Join-Path $Root 'mixed.cf'), '/UpdateDBCfg')
                        }
                        Invoke-Designer -InfoBasePath $Base -InfoBaseKind file -DesignerArgs $arguments 6>$null | Out-Null
                    }
                } catch { $errorMessage = $_.Exception.Message }
                [pscustomobject]@{
                    error = $errorMessage; outputPath = $path; nativeArguments = $script:NativeArguments
                    probePassed = $script:ProbePassed; releaseProbeRequests = $script:ReleaseProbeRequests
                    lockedBefore = $lockedBefore
                    lockedAfter = (-not (Test-DesignerInfoBaseReleased -InfoBaseKind file -InfoBasePath $Base))
                    holderOpen = $holder.CanRead
                    manifestPath = $script:PublishedManifest
                    manifestFiles = @(Get-ChildItem -LiteralPath $Root -Filter '*.manifest.json' -Recurse)
                    loadRequests = $script:LoadRequests; verificationReads = $script:VerificationReads
                    nativeReleased = (Test-OneCNativeOperationJournalReleased -Journal $script:OneCNativeOperationJournal)
                    nativeRecordCount = $script:OneCNativeOperationJournal.entries.Count
                }
            } finally { $holder.Dispose() }
        } $root $base $Kind $Failure $Operation
    }
}

Describe 'Designer exports with another infobase session' {
    It 'completes public <Kind> export with skipped load, fresh proof and the official manifest' -TestCases @(
        @{ Kind = 'configuration'; ResultKind = 'cf' }, @{ Kind = 'extension'; ResultKind = 'cfe' }
    ) {
        param($Kind, $ResultKind)
        $result = Invoke-SharedBaseExportFixture -Kind $Kind -Operation public-export
        $result.error | Should -Be ''
        $result.loadRequests | Should -Be 1
        $result.verificationReads | Should -Be 3
        $manifest = Get-Content -LiteralPath $result.manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $manifest.operation | Should -Be 'export-dev-branch-result'
        $manifest.artifact.kind | Should -Be $ResultKind
        $manifest.artifact.path | Should -Be $result.outputPath
        $manifest.artifact.sha256 | Should -Be (Get-FileHash -LiteralPath $result.outputPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $manifest.verification.decision | Should -Be 'fresh-passed'
        $manifest.verification.freshPassed | Should -BeTrue
        $manifest.verification.verifiedFingerprint | Should -Be 'v3|fixture'
        $manifest.source.configFingerprint | Should -Be 'config-fingerprint'
        $result.manifestFiles.Count | Should -Be 1
        $result.lockedAfter | Should -BeTrue
        $result.holderOpen | Should -BeTrue
        $result.releaseProbeRequests | Should -Be 0
        $result.nativeRecordCount | Should -Be 1
        $result.nativeReleased | Should -BeTrue
    }

    It 'does not publish a manifest after <Failure>' -TestCases @(
        @{ Failure = 'source-changed'; Error = 'content changed during artifact export' },
        @{ Failure = 'verification-lost'; Error = 'verification was lost during artifact export' },
        @{ Failure = 'nonzero-exit'; Error = 'failed with exit code 1' },
        @{ Failure = 'owned-process-active'; Error = '^DESIGNER_POST_EXIT_PROBE_TIMEOUT' }
    ) {
        param($Failure, $Error)
        $result = Invoke-SharedBaseExportFixture -Operation public-export -Failure $Failure
        $result.error | Should -Match $Error
        $result.outputPath | Should -Be ''
        $result.manifestPath | Should -Be ''
        $result.manifestFiles.Count | Should -Be 0
        $result.lockedAfter | Should -BeTrue
        $result.holderOpen | Should -BeTrue
        $result.nativeRecordCount | Should -Be 1
        $result.nativeReleased | Should -Be ($Failure -ne 'owned-process-active')
    }

    It 'completes <Kind> export while the other session keeps the infobase open' -TestCases @(
        @{ Kind = 'configuration'; Extension = '.cf' }, @{ Kind = 'extension'; Extension = '.cfe' }
    ) {
        param($Kind, $Extension)
        $result = Invoke-SharedBaseExportFixture -Kind $Kind
        $result.error | Should -Be ''
        $result.probePassed | Should -BeTrue
        [IO.Path]::GetExtension($result.outputPath) | Should -Be $Extension
        [IO.File]::ReadAllText($result.outputPath) | Should -Be 'compiled fixture output'
        $result.lockedBefore | Should -BeTrue
        $result.lockedAfter | Should -BeTrue
        $result.holderOpen | Should -BeTrue
        $result.releaseProbeRequests | Should -Be 0
        if ($Kind -eq 'extension') { $result.nativeArguments | Should -Contain 'ТестовоеРасширение' }
    }

    It 'rejects <Failure> even with an output file and a surviving unrelated session' -TestCases @(
        @{ Failure = 'empty-output'; Error = '^DESIGNER_POST_EXIT_PROBE_TIMEOUT' },
        @{ Failure = 'owned-process-active'; Error = '^DESIGNER_POST_EXIT_PROBE_TIMEOUT' },
        @{ Failure = 'log-error'; Error = 'failed: Error saving configuration' },
        @{ Failure = 'nonzero-exit'; Error = 'failed with exit code 1' }
    ) {
        param($Failure, $Error)
        $result = Invoke-SharedBaseExportFixture -Failure $Failure
        $result.error | Should -Match $Error
        $result.outputPath | Should -Be ''
        $result.lockedAfter | Should -BeTrue
        $result.holderOpen | Should -BeTrue
    }

    It 'preserves exclusive-release evidence for <Operation>' -TestCases @(
        @{ Operation = 'dump-ib' }, @{ Operation = 'mixed-dump-and-update' }
    ) {
        param($Operation)
        $result = Invoke-SharedBaseExportFixture -Operation $Operation
        $result.error | Should -Match '^DESIGNER_POST_EXIT_PROBE_TIMEOUT'
        $result.probePassed | Should -BeFalse
        $result.releaseProbeRequests | Should -BeGreaterThan 0
        $result.lockedAfter | Should -BeTrue
        $result.holderOpen | Should -BeTrue
    }
}
