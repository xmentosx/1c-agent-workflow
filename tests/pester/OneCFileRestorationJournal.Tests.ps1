Describe 'Database owner retains source restoration obligations' {
    BeforeAll {
        Set-StrictMode -Version Latest
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        . $context.HelperPath -ProjectRoot $context.RepoRoot -Action help *> $null
        . (Join-Path $context.RepoRoot '.agents/skills/itl-remote-runner/scripts/DatabaseAccess.ps1')
        $script:restorationPython = (Get-Command python -CommandType Application | Select-Object -First 1).Source
        function Read-TestRestorationDuties {
            $record = Get-Content -LiteralPath (Join-Path $script:restorationAuthority ('tickets/' + $script:restorationOwner.proof.ticket + '.json')) -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($producer in $record.nativeJournal.producers.PSObject.Properties.Value) {
                foreach ($entry in $producer.restorations.PSObject.Properties.Value) {
                    Get-Content -LiteralPath (Join-Path $script:restorationAuthority $entry.path) -Raw -Encoding UTF8 | ConvertFrom-Json
                }
            }
        }
    }
    BeforeEach {
        $script:ProjectRoot = Join-Path $TestDrive ('Откат исходников ' + [guid]::NewGuid().ToString('N'))
        $script:restorationAuthority = Join-Path $script:ProjectRoot 'Общая очередь'
        $script:restorationExport = Join-Path $script:ProjectRoot 'Исходники конфигурации'
        New-Item -ItemType Directory -Force -Path $script:restorationExport | Out-Null
        $script:cursorPath = Join-Path $script:restorationExport 'ConfigDumpInfo.xml'
        $script:originalCursor = [Text.UTF8Encoding]::new($true).GetBytes("<Снимок>`r`nИсходные байты`r`n</Снимок>`r`n")
        [IO.File]::WriteAllBytes($script:cursorPath, $script:originalCursor)
        $script:restorationBase = [pscustomobject]@{kind='file';path=(Join-Path $script:ProjectRoot 'База ветки')}
        $script:restorationRequest = @{schemaVersion=1;coordinator=$script:restorationAuthority;bases=@($script:restorationBase);timeout=0;nativeJournalProtocol=1;owner=@{operation='source-load';project=$script:ProjectRoot}}
        $script:restorationOwner = Start-ItlDatabaseAccessHost -Python $script:restorationPython -Request $script:restorationRequest
        $script:OneCNativeOperationJournal = New-OneCNativeOperationJournal -Resources @($script:restorationBase) -Owner $script:restorationOwner
        $script:restoreNativeCalls = 0
        $script:restoreOutcome = 'success'
        Mock Update-DevBranchState {}
        Mock Invoke-Designer {
            $script:restoreNativeCalls++
            $script:LastNativeProcessStarted = $true
            $script:LastLogPath = 'fixture-native-' + $script:restoreNativeCalls + '.log'
            if ($script:restoreNativeCalls -eq 2) {
                [Convert]::ToBase64String([IO.File]::ReadAllBytes($script:cursorPath)) | Should -Be ([Convert]::ToBase64String($script:originalCursor))
                @(Read-TestRestorationDuties | Where-Object { $_.status -eq 'pending' }) | Should -HaveCount 1
            }
            [IO.File]::WriteAllText($script:cursorPath, 'accepted new cursor')
            if ($script:restoreOutcome -eq 'both-fail' -or ($script:restoreOutcome -eq 'partial-fails' -and $script:restoreNativeCalls -eq 1)) {
                throw 'fixture Designer load failed'
            }
        }
    }
    AfterEach {
        try {
            # Negative cases can deliberately terminate the owner with debt.
            # Close its exact pipe instead of sending another release to EOF.
            Close-ItlDatabaseAccessHost -Owner $script:restorationOwner
        } finally { $script:OneCNativeOperationJournal = $null }
    }

    It 'indexes its retained snapshot before mutation and releases only when the outer scope ends' {
        $savedCursor = New-ConfigDumpInfoLoadSnapshot -AbsoluteExportPath $script:restorationExport
        $pending = @(Read-TestRestorationDuties)
        $pending | Should -HaveCount 1
        $pending[0].status | Should -Be pending
        $pending[0].snapshotPath | Should -Be $savedCursor.backupPath
        $pending[0].helperInputs | Should -HaveCount 5
        @($pending[0].helperInputs | ForEach-Object { [IO.Path]::GetFileName($_.path) }) -join ',' |
            Should -Be 'agent-1c.core.ps1,agent-1c.runtime-values.ps1,agent-1c.sessions.ps1,agent-1c.vanessa.ps1,agent-1c.ports.ps1'
        foreach ($helper in $pending[0].helperInputs) {
            (Get-FileHash -LiteralPath $helper.path -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $helper.sha256
        }
        $savedCursor.backupPath | Should -Match 'restoration-snapshots'
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($savedCursor.backupPath)) | Should -Be ([Convert]::ToBase64String($script:originalCursor))
        [IO.File]::WriteAllText($script:cursorPath, 'temporary cursor')
        Restore-ConfigDumpInfoLoadSnapshot -Snapshot $savedCursor
        Test-OneCNativeOperationJournalReleased $script:OneCNativeOperationJournal | Should -BeFalse
        { Start-ItlDatabaseAccessHost -Python $script:restorationPython -Request $script:restorationRequest } | Should -Throw '*WAIT_TIMEOUT*'
        Restore-ConfigDumpInfoLoadSnapshot -Snapshot $savedCursor
        Remove-ConfigDumpInfoLoadSnapshot -Snapshot $savedCursor
        Test-OneCNativeOperationJournalReleased $script:OneCNativeOperationJournal | Should -BeTrue
        (Read-TestRestorationDuties).status | Should -Be restored
        Test-Path -LiteralPath $savedCursor.backupPath | Should -BeFalse
        (Complete-ItlDatabaseAccessHost -Owner $script:restorationOwner).status | Should -Be released
        $next = Start-ItlDatabaseAccessHost -Python $script:restorationPython -Request $script:restorationRequest
        Complete-ItlDatabaseAccessHost -Owner $next | Out-Null
    }

    It 'restores original absence and closes the duty even without a snapshot file' {
        [IO.File]::Delete($script:cursorPath)
        $savedCursor = New-ConfigDumpInfoLoadSnapshot -AbsoluteExportPath $script:restorationExport
        [IO.File]::WriteAllText($script:cursorPath, 'temporary cursor')
        Restore-ConfigDumpInfoLoadSnapshot -Snapshot $savedCursor
        Remove-ConfigDumpInfoLoadSnapshot -Snapshot $savedCursor
        Test-Path -LiteralPath $script:cursorPath | Should -BeFalse
        (Read-TestRestorationDuties).status | Should -Be restored
        Test-OneCNativeOperationJournalReleased $script:OneCNativeOperationJournal | Should -BeTrue
    }

    It 'retains recovery debt and the snapshot when rollback cannot be proved' {
        $savedCursor = New-ConfigDumpInfoLoadSnapshot -AbsoluteExportPath $script:restorationExport
        [IO.File]::WriteAllText($script:cursorPath, 'unrestored cursor')
        { Remove-ConfigDumpInfoLoadSnapshot -Snapshot $savedCursor } | Should -Throw '*RESTORATION_UNCONFIRMED*'
        $savedCursor.preserveBackup | Should -BeTrue
        Test-Path -LiteralPath $savedCursor.backupPath | Should -BeTrue
        (Read-TestRestorationDuties).status | Should -Be pending
        Test-OneCNativeOperationJournalReleased $script:OneCNativeOperationJournal | Should -BeFalse
        Close-ItlDatabaseAccessHost -Owner $script:restorationOwner
        $ticket = Get-Content -LiteralPath (Join-Path $script:restorationAuthority ('tickets/' + $script:restorationOwner.proof.ticket + '.json')) -Raw -Encoding UTF8 | ConvertFrom-Json
        $ticket.status | Should -Be 'needs-attention'
        { Start-ItlDatabaseAccessHost -Python $script:restorationPython -Request $script:restorationRequest } | Should -Throw '*RECOVERY_REQUIRED*'
    }

    It 'rejects a damaged snapshot before overwriting the current source' {
        $savedCursor = New-ConfigDumpInfoLoadSnapshot -AbsoluteExportPath $script:restorationExport
        [IO.File]::WriteAllText($script:cursorPath, 'current cursor')
        [IO.File]::WriteAllText($savedCursor.backupPath, 'damaged backup')
        { Restore-ConfigDumpInfoLoadSnapshot -Snapshot $savedCursor } | Should -Throw '*SNAPSHOT_CHANGED*'
        [IO.File]::ReadAllText($script:cursorPath) | Should -Be 'current cursor'
        Remove-ConfigDumpInfoLoadSnapshot -Snapshot $savedCursor -WarningAction SilentlyContinue
        Test-Path -LiteralPath $savedCursor.backupPath | Should -BeTrue
        Test-OneCNativeOperationJournalReleased $script:OneCNativeOperationJournal | Should -BeFalse
    }

    It 'keeps the ordinary <mode> load contract with <outcome>' -TestCases @(
        @{mode='Full';outcome='success';calls=1;resolution='committed'},
        @{mode='Partial';outcome='success';calls=1;resolution='committed'},
        @{mode='Auto';outcome='partial-fails';calls=2;resolution='committed'},
        @{mode='Auto';outcome='both-fail';calls=2;resolution='restored'}
    ) {
        param($mode,$outcome,$calls,$resolution)
        $script:restoreOutcome = $outcome
        $arguments = @{InfoBasePath=$script:restorationBase.path;InfoBaseKind='file';State=[pscustomobject]@{};AbsoluteExportPath=$script:restorationExport;ListFilePath='fixture-list';FileCount=1;Mode=$mode}
        if ($outcome -eq 'both-fail') { { Invoke-ConfigLoadWithFallback @arguments } | Should -Throw '*ITL_CONFIG_LOAD_FAILED*' }
        else { Invoke-ConfigLoadWithFallback @arguments | Out-Null }
        $script:restoreNativeCalls | Should -Be $calls
        $duty = Read-TestRestorationDuties
        $duty.policy | Should -Be 'on-failure'
        $duty.status | Should -Be $resolution
        if ($resolution -eq 'committed') { [IO.File]::ReadAllText($script:cursorPath) | Should -Be 'accepted new cursor' }
        else { [Convert]::ToBase64String([IO.File]::ReadAllBytes($script:cursorPath)) | Should -Be ([Convert]::ToBase64String($script:originalCursor)) }
        Test-OneCNativeOperationJournalReleased $script:OneCNativeOperationJournal | Should -BeTrue
    }

    It 'retains the outer verification rollback after an inner load has committed' {
        $savedCursor = New-ConfigDumpInfoLoadSnapshot -AbsoluteExportPath $script:restorationExport
        Invoke-ConfigLoadWithFallback -InfoBasePath $script:restorationBase.path -InfoBaseKind file -State ([pscustomobject]@{}) -AbsoluteExportPath $script:restorationExport -Mode Full | Out-Null
        @(Read-TestRestorationDuties | Where-Object { $_.status -eq 'committed' }) | Should -HaveCount 1
        Test-OneCNativeOperationJournalReleased $script:OneCNativeOperationJournal | Should -BeFalse
        Restore-ConfigDumpInfoLoadSnapshot -Snapshot $savedCursor
        Remove-ConfigDumpInfoLoadSnapshot -Snapshot $savedCursor
        Test-OneCNativeOperationJournalReleased $script:OneCNativeOperationJournal | Should -BeTrue
    }

    It 'does not mutate when its restoration intent cannot be acknowledged' {
        Mock Publish-ItlDatabaseRestorationDuty { throw 'fixture authority unavailable' } -ParameterFilter { $Record.status -eq 'pending' }
        { Invoke-ConfigLoadWithFallback -InfoBasePath $script:restorationBase.path -InfoBaseKind file -State ([pscustomobject]@{}) -AbsoluteExportPath $script:restorationExport -Mode Full } | Should -Throw '*authority unavailable*'
        Should -Invoke Invoke-Designer -Times 0
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($script:cursorPath)) | Should -Be ([Convert]::ToBase64String($script:originalCursor))
    }

    It 'does not retry a successful partial native load when its commit acknowledgement fails' {
        Mock Publish-ItlDatabaseRestorationDuty { throw 'fixture commit acknowledgement lost' } -ParameterFilter { $Record.status -eq 'committed' }
        { Invoke-ConfigLoadWithFallback -InfoBasePath $script:restorationBase.path -InfoBaseKind file -State ([pscustomobject]@{}) -AbsoluteExportPath $script:restorationExport -ListFilePath fixture -FileCount 1 -Mode Auto } | Should -Throw '*commit acknowledgement lost*'
        Should -Invoke Invoke-Designer -Times 1 -Exactly
        Test-OneCNativeOperationJournalReleased $script:OneCNativeOperationJournal | Should -BeFalse
    }
}
