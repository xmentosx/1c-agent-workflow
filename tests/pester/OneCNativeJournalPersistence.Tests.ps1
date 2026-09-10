Describe 'Durable native intent before process creation' {
    BeforeAll {
        Set-StrictMode -Version Latest
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        . $context.HelperPath -ProjectRoot $context.RepoRoot -Action help *> $null
        . (Join-Path $context.RepoRoot '.agents/skills/itl-remote-runner/scripts/DatabaseAccess.ps1')
        $script:persistencePython = (Get-Command python -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    }
    BeforeEach {
        $script:journalRoot = Join-Path $TestDrive ('Журнал с пробелом ' + [guid]::NewGuid().ToString('N'))
        $script:journalBase = Join-Path $journalRoot 'Тестовая база'
        $request = @{schemaVersion=1;coordinator=$journalRoot;bases=@(@{kind='file';path=$journalBase});timeout=0;nativeJournalProtocol=1;owner=@{operation='test-manager-run';project=$journalRoot}}
        $script:journalOwner = Start-ItlDatabaseAccessHost -Python $persistencePython -Request $request
        $script:OneCNativeOperationJournal = New-OneCNativeOperationJournal -Resources @([pscustomobject]@{kind='file';path=$journalBase}) -Owner $journalOwner
        $script:OneCSessionLaunchContext = $null
        Mock Assert-OneCNativeOperationJournalOwner {}
        Mock Remove-OneCSessionReservation {}
        Mock Invoke-OneCSessionAdmissionSet { param($Admissions,$StartProcess) & $StartProcess }
    }
    AfterEach {
        if ($null -ne $journalOwner -and -not $journalOwner.closed) { Complete-ItlDatabaseAccessHost -Owner $journalOwner -CleanupErrors @('fixture complete; no native processes were started') | Out-Null }
        $script:OneCNativeOperationJournal = $null
    }

    It 'records uncertain native start with the complete captured scope before the launcher is called' {
        $script:observedBeforeLaunch = $null
        {
            Invoke-WithOneCSessionAdmissionContext -InfoBaseKind file -InfoBasePath $journalBase -ScriptBlock {
                $record = $script:OneCSessionLaunchContext.nativeOperationRecord
                $record.ownedProcessScopes = @([pscustomobject]@{schemaVersion=1;role='test-client';kind='file';path=$journalBase;runParamsPath='retained parameters';runParamsSha256=('b'*64);testPorts=@(53941,53942);password='extra-scope-secret'})
                # This test targets persistence, not the separately tested file hash boundary.
                Mock Get-FileHash { [pscustomobject]@{Hash=('b'*64)} }
                Invoke-OneCSessionProcessStart -StartProcess {
                    $record = $script:OneCSessionLaunchContext.nativeOperationRecord
                    $path = $record.persistedPath
                    $script:observedBeforeLaunch = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
                    throw 'native start outcome unknown'
                }
            }
        } | Should -Throw '*native start outcome unknown*'
        $observedBeforeLaunch.startAttempted | Should -BeTrue
        $observedBeforeLaunch.processId | Should -Be 0
        $observedBeforeLaunch.resources[0].path | Should -Be $journalBase
        $observedBeforeLaunch.ownedProcessScopes[0].testPorts | Should -Be @(53941,53942)
        $observedBeforeLaunch.helperInputs | Should -HaveCount 4
        foreach ($helper in $observedBeforeLaunch.helperInputs) {
            $helper.path | Should -Match 'native-helper-generations[\\/][a-f0-9]{64}[\\/]agent-1c\.'
            Test-Path -LiteralPath $helper.path -PathType Leaf | Should -BeTrue
        }
        $observedBeforeLaunch.recoveryRequiresLiveVerification | Should -BeTrue
        $observedBeforeLaunch | ConvertTo-Json -Depth 12 | Should -Not -Match 'private-inheritance-secret|extra-scope-secret'
        $observedBeforeLaunch | ConvertTo-Json -Depth 12 | Should -Not -Match ([regex]::Escape($journalOwner.proof.token))
        Test-OneCNativeOperationJournalReleased $script:OneCNativeOperationJournal | Should -BeFalse
    }

    It 'persists native intent when the admitted owner omits optional operation and project labels' {
        Complete-ItlDatabaseAccessHost -Owner $journalOwner | Out-Null
        $request = @{schemaVersion=1;coordinator=$journalRoot;bases=@(@{kind='file';path=$journalBase});timeout=0;nativeJournalProtocol=1;owner=@{}}
        $script:journalOwner = Start-ItlDatabaseAccessHost -Python $persistencePython -Request $request
        $script:OneCNativeOperationJournal = New-OneCNativeOperationJournal -Resources @([pscustomobject]@{kind='file';path=$journalBase}) -Owner $journalOwner
        {
            Invoke-WithOneCSessionAdmissionContext -InfoBaseKind file -InfoBasePath $journalBase -ScriptBlock {
                Invoke-OneCSessionProcessStart -StartProcess { throw 'native outcome unknown without labels' }
            }
        } | Should -Throw '*native outcome unknown without labels*'
        $record = $script:OneCNativeOperationJournal.entries[0]
        $saved = Get-Content -LiteralPath $record.persistedPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $saved.operation | Should -Be ''
        $saved.project | Should -Be ''
        $saved.startAttempted | Should -BeTrue
        $saved.ticket | Should -Be $journalOwner.proof.ticket
        (Complete-ItlDatabaseAccessHost -Owner $journalOwner).status | Should -Be 'needs-attention'
    }

    It 'does not start a native process when durable intent cannot be written' {
        $script:nativeStarts = 0
        Mock Publish-ItlDatabaseNativeOperation { throw 'journal storage unavailable' } -ParameterFilter { $Record.startAttempted }
        {
            Invoke-WithOneCSessionAdmissionContext -InfoBaseKind file -InfoBasePath $journalBase -ScriptBlock {
                Invoke-OneCSessionProcessStart -StartProcess { $script:nativeStarts++ }
            }
        } | Should -Throw '*journal storage unavailable*'
        $nativeStarts | Should -Be 0
        $script:OneCNativeOperationJournal.entries[0].startAttempted | Should -BeFalse
        Test-OneCNativeOperationJournalReleased $script:OneCNativeOperationJournal | Should -BeTrue
    }

    It 'does not start a native process when its recovery generation cannot be retained' {
        $script:nativeStarts = 0
        Mock Save-OneCNativeRecoveryHelpers { throw 'recovery helper archive unavailable' }
        {
            Invoke-WithOneCSessionAdmissionContext -InfoBaseKind file -InfoBasePath $journalBase -ScriptBlock {
                Invoke-OneCSessionProcessStart -StartProcess { $script:nativeStarts++ }
            }
        } | Should -Throw '*recovery helper archive unavailable*'
        $nativeStarts | Should -Be 0
        $script:OneCNativeOperationJournal.entries | Should -HaveCount 0
        Test-OneCNativeOperationJournalReleased $script:OneCNativeOperationJournal | Should -BeTrue
    }

    It 'resolves the PowerShell archive through the authoritative Python journal index' {
        Invoke-WithOneCSessionAdmissionContext -InfoBaseKind file -InfoBasePath $journalBase -ScriptBlock {}
        $runtime = Join-Path $context.RepoRoot '.agents/skills/itl-remote-runner/scripts'
        $code = @'
import json, sys
sys.path.insert(0, sys.argv[1])
from itl_remote.access import Coordinator
from itl_remote.native_journal import inspect
coordinator = Coordinator(sys.argv[2])
record = next(r for r in coordinator.records() if r['ticket'] == sys.argv[3])
bundle = inspect(coordinator, record, resolve_helpers=True)
assert len(bundle['helperGenerations']) == 1
print(json.dumps({'helperGeneration': next(iter(bundle['helperGenerations'].values())), 'requiresLiveVerification': bundle['requiresLiveVerification']}))
'@
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $persistencePython
        $startInfo.Arguments = Join-NativeCommandLineArguments -Arguments @('-B','-X','utf8','-c',$code,$runtime,$journalRoot,$journalOwner.proof.ticket)
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
        $startInfo.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
        $process = [Diagnostics.Process]::Start($startInfo)
        try {
            $stdout = $process.StandardOutput.ReadToEnd()
            $stderr = $process.StandardError.ReadToEnd()
            $process.WaitForExit()
            $process.ExitCode | Should -Be 0 -Because $stderr
            $observed = $stdout | ConvertFrom-Json
            $observed.helperGeneration.generation | Should -Match '^[a-f0-9]{64}$'
            $observed.helperGeneration.files | Should -HaveCount 4
            $observed.requiresLiveVerification | Should -BeTrue
        } finally { $process.Dispose() }
    }

    It 'persists build callers that attach the owner after constructing the journal' {
        $script:OneCNativeOperationJournal = New-OneCNativeOperationJournal -Resources @([pscustomobject]@{kind='file';path=$journalBase})
        $script:OneCNativeOperationJournal.owner = $journalOwner
        Invoke-WithOneCSessionAdmissionContext -InfoBaseKind file -InfoBasePath $journalBase -ScriptBlock {
            Invoke-OneCSessionProcessStart -StartProcess { [pscustomobject]@{Id=5321} }
        } | Out-Null
        $record = $script:OneCNativeOperationJournal.entries[0]
        $path = $record.persistedPath
        $saved = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        $saved.processId | Should -Be 5321
        $saved.ticket | Should -Be $journalOwner.proof.ticket
        $saved.resources[0].path | Should -Be $journalBase
    }

    It 'keeps inherited journals separate and records withdrawn release observations atomically' {
        $first = $script:OneCNativeOperationJournal
        Invoke-WithOneCSessionAdmissionContext -InfoBaseKind file -InfoBasePath $journalBase -ScriptBlock {
            Invoke-OneCSessionProcessStart -StartProcess { [pscustomobject]@{Id=4321;Password='do-not-serialize-process'} }
        } | Out-Null
        $record = $first.entries[0]
        $path = $record.persistedPath
        $script:OneCNativeOperationJournal = New-OneCNativeOperationJournal -Resources $first.resources -Owner $journalOwner
        Invoke-WithOneCSessionAdmissionContext -InfoBaseKind file -InfoBasePath $journalBase -ScriptBlock {
            Invoke-OneCSessionProcessStart -StartProcess { [pscustomobject]@{Id=4322} }
        } | Out-Null
        $secondRecord = $script:OneCNativeOperationJournal.entries[0]
        $secondPath = $secondRecord.persistedPath
        $path | Should -Not -Be $secondPath
        Confirm-OneCNativeOperationRelease -Record $record -LauncherExited $true -OwnedProcessesReleased $true -Evidence 'live scoped observations'
        $path = $record.persistedPath
        (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json).quiescenceConfirmed | Should -BeTrue
        Confirm-OneCNativeOperationRelease -Record $record -LauncherExited $true -OwnedProcessesReleased $false -Evidence 'owned child observed'
        $path = $record.persistedPath
        $saved = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        $saved.quiescenceConfirmed | Should -BeFalse
        $saved.releaseEvidence | Should -Be ''
        $saved.processId | Should -Be 4321
        (Get-Content -LiteralPath $secondPath -Raw -Encoding UTF8 | ConvertFrom-Json).processId | Should -Be 4322
        Get-Content -LiteralPath $path -Raw -Encoding UTF8 | Should -Not -Match 'do-not-serialize-process|private-inheritance-secret'
        @(Get-ChildItem -LiteralPath (Split-Path -Parent $path) -Force | Where-Object Extension -in @('.tmp','.bak')) | Should -HaveCount 0
    }
}
