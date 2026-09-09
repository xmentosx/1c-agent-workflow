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
