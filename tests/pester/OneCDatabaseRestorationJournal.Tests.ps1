Describe 'Database snapshot duties survive native and caller failures' {
    BeforeAll {
        Set-StrictMode -Version Latest
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        . $context.HelperPath -ProjectRoot $context.RepoRoot -Action help *> $null
        . (Join-Path $context.RepoRoot '.agents/skills/itl-remote-runner/scripts/DatabaseAccess.ps1')
        $script:dtPython = (Get-Command python -CommandType Application | Select-Object -First 1).Source
    }
    BeforeEach {
        $script:ProjectRoot = Join-Path $TestDrive ('Восстановление базы ' + [guid]::NewGuid().ToString('N'))
        $script:dtBase = [pscustomobject]@{kind='file';path=(Join-Path $script:ProjectRoot 'Целевая база')}
        $script:dtState = [pscustomobject]@{infoBaseKind='file';devBranchInfoBasePath=$dtBase.path}
        $script:dtSnapshot = Join-Path $script:ProjectRoot '.agent-1c/snapshots/Исходный снимок.dt'
        New-Item -ItemType Directory -Force -Path (Split-Path $dtSnapshot), $dtBase.path | Out-Null
        [IO.File]::WriteAllBytes($dtSnapshot, [byte[]](1,2,3,4,5))
        $script:dtRequest = @{schemaVersion=1;coordinator=(Join-Path $script:ProjectRoot 'Общая очередь');bases=@($dtBase);timeout=0;nativeJournalProtocol=1;owner=@{operation='init-dev-branch-extension';project=$script:ProjectRoot}}
        $script:dtOwner = Start-ItlDatabaseAccessHost -Python $script:dtPython -Request $dtRequest
        $script:OneCNativeOperationJournal = New-OneCNativeOperationJournal -Resources @($dtBase) -Owner $dtOwner
        $script:OneCSessionLaunchContext = $null
        $script:Config = [pscustomobject]@{logsPath='logs';designerMaxWorkingSetMb=0;designerOperationTimeoutSeconds=30;designerDumpStabilitySeconds=0}
        $script:dtOutcome = 'success'
        $script:dtNativeCalls = 0
        $script:dtObservedReadLease = $false
        Mock Get-PlatformPath { $script:dtPython }
        Mock Assert-InfoBaseAvailable {}
        Mock Stop-DevBranchRuntimeBeforeInfobaseMutation {}
        Mock Reset-DevBranchToolingProof {}
        Mock Invoke-OneCSessionAdmissionSet { param($Admissions,$StartProcess) & $StartProcess }
        Mock Remove-OneCSessionReservation {}
        Mock Test-DesignerInvocationReleased {
            param($ProbeState)
            $ProbeState.processesReleaseConfirmed = $script:dtOutcome -ne 'surviving-child'
            return $ProbeState.processesReleaseConfirmed
        }
        Mock Invoke-NativeProcessAndWaitResult {
            param($Arguments,$CompletionProbe)
            $script:dtNativeCalls++
            $stream = $null
            try { $stream = [IO.File]::Open($script:dtSnapshot,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite) }
            catch [IO.IOException] { $script:dtObservedReadLease = $true }
            finally { if ($null -ne $stream) { $stream.Dispose() } }
            Invoke-OneCSessionProcessStart -StartProcess { [pscustomobject]@{Id=7312} } | Out-Null
            $outIndex = [Array]::IndexOf($Arguments,'/Out')
            [IO.File]::WriteAllText($Arguments[$outIndex+1], 'completed')
            & $CompletionProbe ([pscustomobject]@{processId=7312;launcherExited=$true;launcherExitCode=0}) | Out-Null
            [pscustomobject]@{processId=7312;launcherExited=$true;exitCode=$(if($script:dtOutcome -eq 'failed') {1} else {0});timedOut=$false
                memoryLimitExceeded=$false;memoryMonitorFailed=$false;terminationError='';postExitProbeTimedOut=($script:dtOutcome -eq 'surviving-child')}
        }
    }
    AfterEach {
        try { Close-ItlDatabaseAccessHost -Owner $dtOwner }
        finally { $script:OneCNativeOperationJournal = $null; $script:OneCSessionLaunchContext = $null }
    }

    It 'captures lifecycle context before accepting the DT duty and rejects changed baseline source' {
        $script:dtState | Add-Member -NotePropertyName devBranchName -NotePropertyValue branch1
        $script:dtState | Add-Member -NotePropertyName safeDevBranchName -NotePropertyValue branch1
        $script:dtState | Add-Member -NotePropertyName worktreePath -NotePropertyValue $script:ProjectRoot
        $statePath = Join-Path $script:ProjectRoot '.agent-1c/dev-branches/branch1.json'
        New-Item -ItemType Directory -Force -Path (Split-Path $statePath) | Out-Null
        $dtState | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8
        $script:contextPlatform = Join-Path $script:ProjectRoot '1cv8.exe'
        [IO.File]::WriteAllText($contextPlatform,'fixture platform identity; never executed')
        Mock Get-PlatformPath { $script:contextPlatform }
        $source = Join-Path $script:ProjectRoot 'src/cfe/TestExtension'
        $reference = New-OneCExtensionRecoveryContext -State $dtState -SnapshotPath $dtSnapshot -SourcePath $source -SourceExisted $false
        $duty = Register-OneCDatabaseRestorationDuty -State $dtState -SnapshotPath $dtSnapshot -RecoveryContext $reference
        $duty.payload.recoveryContext.sha256 | Should -Be (Get-FileHash -LiteralPath $reference.path -Algorithm SHA256).Hash.ToLowerInvariant()
        $manifest = Get-Content -LiteralPath $reference.path -Raw -Encoding UTF8 | ConvertFrom-Json
        $manifest.state.destination | Should -Be $statePath
        $manifest.environment.existed | Should -BeFalse
        $manifest.source.existed | Should -BeFalse
        { New-OneCExtensionRecoveryContext -State $dtState -SnapshotPath $dtSnapshot -SourcePath $source -SourceExisted $false } | Should -Throw '*CONTEXT_ALREADY_EXISTS*'
        New-Item -ItemType Directory -Force -Path $source | Out-Null
        { New-OneCExtensionRecoveryContext -State $dtState -SnapshotPath $dtSnapshot -SourcePath $source -SourceExisted $false } | Should -Throw '*BASELINE_CHANGED*'
    }

    It 'retains the snapshot and admission through repeated restores until the caller completes rollback' {
        $duty = Register-OneCDatabaseRestorationDuty -State $dtState -SnapshotPath $dtSnapshot
        $duty.payload.snapshotPath | Should -Be $dtSnapshot
        { Remove-CompletedInfobaseSnapshot -SnapshotPath $dtSnapshot } | Should -Throw '*SNAPSHOT_STILL_REQUIRED*'
        Restore-DevBranchInfobaseFromSnapshot -State $dtState -SnapshotPath $dtSnapshot
        $firstRestore = $duty.payload.restoreOperation
        $firstRestore | Should -Match '^[a-f0-9]{32}/[a-f0-9]{32}$'
        $duty.payload.status | Should -Be pending
        $dtObservedReadLease | Should -BeTrue
        { Start-ItlDatabaseAccessHost -Python $dtPython -Request $dtRequest } | Should -Throw '*WAIT_TIMEOUT*'
        Restore-DevBranchInfobaseFromSnapshot -State $dtState -SnapshotPath $dtSnapshot
        $duty.payload.restoreOperation | Should -Not -Be $firstRestore
        Complete-OneCDatabaseRestorationDuty -Duty $duty
        Remove-CompletedInfobaseSnapshot -SnapshotPath $dtSnapshot
        Test-Path -LiteralPath $dtSnapshot | Should -BeFalse
        Test-OneCNativeOperationJournalReleased $script:OneCNativeOperationJournal | Should -BeTrue
        (Complete-ItlDatabaseAccessHost -Owner $dtOwner).status | Should -Be released
        $next = Start-ItlDatabaseAccessHost -Python $dtPython -Request $dtRequest
        Complete-ItlDatabaseAccessHost -Owner $next | Out-Null
    }

    It 'does not claim restoration after <outcome>' -TestCases @(@{outcome='failed';error='*exit code 1*'},@{outcome='surviving-child';error='*POST_EXIT_PROBE_TIMEOUT*'}) {
        param($outcome,$error)
        $script:dtOutcome = $outcome
        $duty = Register-OneCDatabaseRestorationDuty -State $dtState -SnapshotPath $dtSnapshot
        { Restore-DevBranchInfobaseFromSnapshot -State $dtState -SnapshotPath $dtSnapshot } | Should -Throw $error
        $dtNativeCalls | Should -Be 1
        $duty.payload.restoreOperation | Should -Be ''
        $duty.payload.status | Should -Be pending
        Test-Path -LiteralPath $dtSnapshot | Should -BeTrue
        Test-OneCNativeOperationJournalReleased $script:OneCNativeOperationJournal | Should -BeFalse
        (Complete-ItlDatabaseAccessHost -Owner $dtOwner).status | Should -Be 'needs-attention'
        { Start-ItlDatabaseAccessHost -Python $dtPython -Request $dtRequest } | Should -Throw '*RECOVERY_REQUIRED*'
    }

    It 'rejects a changed target before draining sessions or invalidating tooling proof' {
        $duty = Register-OneCDatabaseRestorationDuty -State $dtState -SnapshotPath $dtSnapshot
        $foreignState = [pscustomobject]@{infoBaseKind='file';devBranchInfoBasePath=(Join-Path $script:ProjectRoot 'Чужая база')}
        { Restore-DevBranchInfobaseFromSnapshot -State $foreignState -SnapshotPath $dtSnapshot } | Should -Throw '*NATIVE_INPUT_CHANGED*'
        Should -Invoke Stop-DevBranchRuntimeBeforeInfobaseMutation -Times 0
        Should -Invoke Reset-DevBranchToolingProof -Times 0
        $dtNativeCalls | Should -Be 0
    }

    It 'rejects changed DT bytes before draining sessions or starting 1C' {
        $duty = Register-OneCDatabaseRestorationDuty -State $dtState -SnapshotPath $dtSnapshot
        [IO.File]::WriteAllBytes($dtSnapshot,[byte[]](9,8,7))
        { Restore-DevBranchInfobaseFromSnapshot -State $dtState -SnapshotPath $dtSnapshot } | Should -Throw '*SNAPSHOT_CHANGED*'
        Should -Invoke Stop-DevBranchRuntimeBeforeInfobaseMutation -Times 0
        $dtNativeCalls | Should -Be 0
        $duty.payload.status | Should -Be pending
    }

    It 'retains the snapshot when the completion acknowledgement is lost' {
        $duty = Register-OneCDatabaseRestorationDuty -State $dtState -SnapshotPath $dtSnapshot -Policy on-failure
        Mock Publish-ItlDatabaseRestorationDuty { throw 'fixture acknowledgement lost' } -ParameterFilter { $Record.status -eq 'committed' }
        { Complete-OneCDatabaseRestorationDuty -Duty $duty -Resolution committed } | Should -Throw '*acknowledgement lost*'
        { Remove-CompletedInfobaseSnapshot -SnapshotPath $dtSnapshot } | Should -Throw '*SNAPSHOT_STILL_REQUIRED*'
        Test-Path -LiteralPath $dtSnapshot | Should -BeTrue
        $dtNativeCalls | Should -Be 0
    }
}
