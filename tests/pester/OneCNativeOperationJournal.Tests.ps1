Describe 'Aggregate database ownership tracks native attempts independently of capacity' {
    BeforeAll {
        $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $lib = Join-Path $repo '.agents/skills/1c-workflow/scripts/lib'
        . (Join-Path $lib 'agent-1c.core.ps1')
        . (Join-Path $lib 'agent-1c.runtime-values.ps1')
        . (Join-Path $lib 'agent-1c.sessions.ps1')
    }
    BeforeEach {
        $script:OneCNativeOperationJournal = New-OneCNativeOperationJournal
        $script:OneCSessionLaunchContext = $null
        $script:journalBase = Join-Path $TestDrive 'База с пробелом'
        Mock Remove-OneCSessionReservation {}
        Mock Invoke-OneCSessionAdmissionSet { param($Admissions, $StartProcess) & $StartProcess }
    }
    AfterEach { $script:OneCNativeOperationJournal = $null }

    It 'permits release after preparation or capacity failure before any native start' {
        Mock Invoke-OneCSessionAdmissionSet { throw (New-OneCSessionCapacityError -Message 'no capacity') }
        {
            Invoke-WithOneCSessionAdmissionContext -InfoBaseKind file -InfoBasePath $journalBase -ScriptBlock {
                Invoke-OneCSessionProcessStart -StartProcess { throw 'must not launch' }
            }
        } | Should -Throw '*no capacity*'
        $script:OneCNativeOperationJournal.entries.Count | Should -Be 1
        $script:OneCNativeOperationJournal.entries[0].startAttempted | Should -BeFalse
        Test-OneCNativeOperationJournalReleased $script:OneCNativeOperationJournal | Should -BeTrue
    }

    It 'retains an uncertain native launch even when no process handle was returned' {
        {
            Invoke-WithOneCSessionAdmissionContext -InfoBaseKind file -InfoBasePath $journalBase -ScriptBlock {
                Invoke-OneCSessionProcessStart -StartProcess { throw 'launch outcome unknown' }
            }
        } | Should -Throw '*launch outcome unknown*'
        $script:OneCNativeOperationJournal.entries[0].startAttempted | Should -BeTrue
        $script:OneCNativeOperationJournal.entries[0].processId | Should -Be 0
        Test-OneCNativeOperationJournalReleased $script:OneCNativeOperationJournal | Should -BeFalse
        $script:OneCSessionLaunchContext | Should -BeNullOrEmpty
    }

    It 'does not release a background process when its launcher command returns' {
        $process = Invoke-WithOneCSessionAdmissionContext -InfoBaseKind file -InfoBasePath $journalBase -KeepReservation -ScriptBlock {
            Invoke-OneCSessionProcessStart -StartProcess { [pscustomobject]@{ Id = 1234 } }
        }
        $process.Id | Should -Be 1234
        $record = $script:OneCNativeOperationJournal.entries[0]
        [object]::ReferenceEquals($record.process, $process) | Should -BeTrue
        Test-OneCNativeOperationJournalReleased $script:OneCNativeOperationJournal | Should -BeFalse
    }

    It 'requires both launcher and descendant proof for release: <Case>' -TestCases @(
        @{ Case = 'launcher only'; Launcher = $true; Descendants = $false; Evidence = 'probe'; Released = $false },
        @{ Case = 'descendants only'; Launcher = $false; Descendants = $true; Evidence = 'probe'; Released = $false },
        @{ Case = 'missing evidence'; Launcher = $true; Descendants = $true; Evidence = ''; Released = $false },
        @{ Case = 'confirmed owned release'; Launcher = $true; Descendants = $true; Evidence = 'owned probe'; Released = $true }
    ) {
        param($Launcher, $Descendants, $Evidence, $Released)
        Invoke-WithOneCSessionAdmissionContext -InfoBaseKind file -InfoBasePath $journalBase -ScriptBlock {
            Invoke-OneCSessionProcessStart -StartProcess { [pscustomobject]@{ Id = 1234 } }
        } | Out-Null
        Confirm-OneCNativeOperationRelease -Record $script:OneCNativeOperationJournal.entries[0] `
            -LauncherExited $Launcher -OwnedProcessesReleased $Descendants -Evidence $Evidence
        Test-OneCNativeOperationJournalReleased $script:OneCNativeOperationJournal | Should -Be $Released
    }

    It 'withdraws prior release proof if a later observation finds owned work' {
        Invoke-WithOneCSessionAdmissionContext -InfoBaseKind file -InfoBasePath $journalBase -ScriptBlock {
            Invoke-OneCSessionProcessStart -StartProcess { [pscustomobject]@{ Id = 1234 } }
        } | Out-Null
        $record = $script:OneCNativeOperationJournal.entries[0]
        Confirm-OneCNativeOperationRelease -Record $record -LauncherExited $true -OwnedProcessesReleased $true -Evidence 'first observation'
        Confirm-OneCNativeOperationRelease -Record $record -LauncherExited $true -OwnedProcessesReleased $false -Evidence 'owned child appeared'
        Test-OneCNativeOperationJournalReleased $script:OneCNativeOperationJournal | Should -BeFalse
        $record.releaseEvidence | Should -Be ''
    }

    It 'keeps nested operations separate and retains the unresolved sibling' {
        Invoke-WithOneCSessionAdmissionContext -InfoBaseKind file -InfoBasePath $journalBase -Purpose parent -ScriptBlock {
            $parent = $script:OneCSessionLaunchContext
            Invoke-WithOneCSessionAdmissionContext -InfoBaseKind file -InfoBasePath $journalBase -Purpose child -ScriptBlock {
                Invoke-OneCSessionProcessStart -StartProcess { [pscustomobject]@{ Id = 1235 } }
            } | Out-Null
            [object]::ReferenceEquals($script:OneCSessionLaunchContext, $parent) | Should -BeTrue
            Invoke-OneCSessionProcessStart -StartProcess { [pscustomobject]@{ Id = 1234 } }
        } | Out-Null
        $records = $script:OneCNativeOperationJournal.entries
        $records.Count | Should -Be 2
        $records[0].id | Should -Not -Be $records[1].id
        Confirm-OneCNativeOperationRelease -Record $records[0] -LauncherExited $true -OwnedProcessesReleased $true -Evidence 'parent proof'
        Test-OneCNativeOperationJournalReleased $script:OneCNativeOperationJournal | Should -BeFalse
        Confirm-OneCNativeOperationRelease -Record $records[1] -LauncherExited $true -OwnedProcessesReleased $true -Evidence 'child proof'
        Test-OneCNativeOperationJournalReleased $script:OneCNativeOperationJournal | Should -BeTrue
    }
}

Describe 'CREATEINFOBASE completion retains aggregate ownership through native release' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        . $context.HelperPath -ProjectRoot $context.RepoRoot -Action help *> $null
    }
    BeforeEach {
        $script:OneCNativeOperationJournal = New-OneCNativeOperationJournal
        $script:OneCSessionLaunchContext = $null
        $script:createBase = Join-Path $TestDrive 'База создания с пробелом'
        $script:createProcess = [pscustomobject]@{Id=45451;HasExited=$true;ExitCode=0}
        $script:createProcess | Add-Member ScriptMethod Refresh {}
        $script:createProcess | Add-Member ScriptMethod WaitForExit { param($Milliseconds) return $true }
        Mock Start-Process { $script:createProcess }
        Mock Invoke-OneCSessionAdmissionSet { param($Admissions, $StartProcess) & $StartProcess }
        Mock Remove-OneCSessionReservation {}
        Mock Publish-Agent1cLifecycleOperationProcessEvidence {}
        Mock Get-DesignerInvocationProcessState { [pscustomobject]@{querySucceeded=$true;active=$false} }
        Mock Stop-Process { throw 'No observed process may be stopped by a successful release probe.' }
    }
    AfterEach {
        $script:OneCNativeOperationJournal = $null
        $script:OneCSessionLaunchContext = $null
    }

    It 'records clean release while preserving native exit <Code>' -TestCases @(@{Code=0},@{Code=7}) {
        param($Code)
        $script:createProcess.ExitCode = $Code
        $result = Invoke-WithOneCSessionAdmissionContext -InfoBaseKind file -InfoBasePath $createBase -Purpose vanessa-service-infobase-create -ScriptBlock {
            Invoke-NativeProcessAndWaitResult -FilePath fake.exe -Arguments @('CREATEINFOBASE',(New-FileInfoBaseConnectionString -Path $createBase)) `
                -OneCCreateInfoBaseSyntax -TimeoutSeconds 5 -PostExitProbeSeconds 3 -CompletionGraceSeconds 0 -CompletionProbe { $true }
        }
        $result.exitCode | Should -Be $Code
        $result.launcherExitCode | Should -Be $Code
        $result.ownedProcessesReleased | Should -BeTrue
        $record = $script:OneCNativeOperationJournal.entries[0]
        $record.processId | Should -Be 45451
        $record.launcherExited | Should -BeTrue
        $record.releaseEvidence | Should -Be 'create-infobase-owned-process-release'
        Test-OneCNativeOperationJournalReleased $script:OneCNativeOperationJournal | Should -BeTrue
        Should -Invoke Get-DesignerInvocationProcessState -Times 2 -Exactly:$false
        Should -Invoke Stop-Process -Times 0
    }

    It 'does not authorize RestoreIB when the launcher exits but its child remains' {
        Mock Get-DesignerInvocationProcessState { [pscustomobject]@{querySucceeded=$true;active=$true} }
        $result = Invoke-WithOneCSessionAdmissionContext -InfoBaseKind file -InfoBasePath $createBase -ScriptBlock {
            Invoke-NativeProcessAndWaitResult -FilePath fake.exe -Arguments @('CREATEINFOBASE',(New-FileInfoBaseConnectionString -Path $createBase)) `
                -OneCCreateInfoBaseSyntax -TimeoutSeconds 5 -PostExitProbeSeconds 1
        }
        $result.launcherExitCode | Should -Be 0
        $result.exitCode | Should -Not -Be 0
        $result.ownedProcessesReleased | Should -BeFalse
        $result.terminationError | Should -Be 'CREATEINFOBASE_OWNED_PROCESS_RELEASE_UNCONFIRMED'
        $script:OneCNativeOperationJournal.entries[0].launcherExited | Should -BeTrue
        Test-OneCNativeOperationJournalReleased $script:OneCNativeOperationJournal | Should -BeFalse
        Should -Invoke Stop-Process -Times 0
    }

    It 'retains creation debt after a failed live process query' {
        Mock Get-DesignerInvocationProcessState { throw 'live inventory unavailable' }
        {
            Invoke-WithOneCSessionAdmissionContext -InfoBaseKind file -InfoBasePath $createBase -ScriptBlock {
                Invoke-NativeProcessAndWaitResult -FilePath fake.exe -Arguments @('CREATEINFOBASE',(New-FileInfoBaseConnectionString -Path $createBase)) `
                    -OneCCreateInfoBaseSyntax -TimeoutSeconds 5 -PostExitProbeSeconds 1
            }
        } | Should -Throw '*live inventory unavailable*'
        $script:OneCNativeOperationJournal.entries[0].launcherExited | Should -BeTrue
        Test-OneCNativeOperationJournalReleased $script:OneCNativeOperationJournal | Should -BeFalse
    }

    It 'retains an uncertain creation attempt without replay or inferred release' {
        Mock Start-Process { throw 'creation launch outcome unknown' }
        {
            Invoke-WithOneCSessionAdmissionContext -InfoBaseKind file -InfoBasePath $createBase -ScriptBlock {
                Invoke-NativeProcessAndWaitResult -FilePath fake.exe -Arguments @('CREATEINFOBASE',(New-FileInfoBaseConnectionString -Path $createBase)) `
                    -OneCCreateInfoBaseSyntax -TimeoutSeconds 5 -PostExitProbeSeconds 1
            }
        } | Should -Throw '*creation launch outcome unknown*'
        Should -Invoke Start-Process -Times 1 -Exactly
        Should -Invoke Get-DesignerInvocationProcessState -Times 0
        $script:OneCNativeOperationJournal.entries[0].startAttempted | Should -BeTrue
        Test-OneCNativeOperationJournalReleased $script:OneCNativeOperationJournal | Should -BeFalse
    }
}
