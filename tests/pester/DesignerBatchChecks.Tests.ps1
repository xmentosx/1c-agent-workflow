BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $helperPath = Join-Path $repoRoot '.agents/skills/1c-workflow/scripts/agent-1c.ps1'
}

Describe 'Designer Gate 6 batch verdict' {
    It 'leaves an unavailable platform target unverified before any editable mutation' {
        $root = Join-Path $TestDrive ('Недоступная база 1С ' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        $actual = & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            $script:calls = [Collections.Generic.List[object]]::new()
            function Invoke-Designer {
                param($InfoBasePath,$InfoBaseKind,$User,$Password,[string[]]$DesignerArgs)
                $script:calls.Add(@($DesignerArgs))
                throw '1cv8.exe was not found for the authorized test target'
            }
            $errorText = try {
                Invoke-ConfigLoadDesignerAttempt -InfoBasePath 'C:\Недоступная база 1С' -InfoBaseKind file -RequireGate6 `
                    -SourceFingerprint 'source' -DesignerArgs @('/LoadConfigFromFiles',$root,'/UpdateDBCfg') -User '' -Password '' | Out-Null
                ''
            } catch { $_.Exception.Message }
            [pscustomobject]@{ error=$errorText; calls=@($script:calls.ToArray()) }
        }
        $actual.error | Should -Match 'GATE6_SNAPSHOT_FAILED.*unverified.*repeat the original operation'
        $actual.calls | Should -HaveCount 1
        @($actual.calls[0]) | Should -Contain '/DumpIB'
        @($actual.calls[0]) | Should -Not -Contain '/LoadConfigFromFiles'
        @($actual.calls[0]) | Should -Not -Contain '/UpdateDBCfg'
    }

    It 'keeps the enclosing exact-target snapshot and its recovery duty under the original owner' {
        $root = Join-Path $TestDrive ('Общий snapshot 1С ' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        $snapshotPath = Join-Path $root 'Исходная база.dt'
        [IO.File]::WriteAllBytes($snapshotPath, [byte[]](5,6,7))
        $actual = & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            $script:OneCNativeOperationJournal = New-OneCNativeOperationJournal
            $state = [pscustomobject]@{ infoBaseKind='file'; devBranchInfoBasePath='C:\База 1С' }
            $duty = Register-OneCDatabaseRestorationDuty -State $state -SnapshotPath $snapshotPath -Policy always
            $script:calls = [Collections.Generic.List[object]]::new()
            $script:failModules = $false
            function Get-PlatformPath { 'fixture-1cv8.exe' }
            function Invoke-Designer {
                param($InfoBasePath,$InfoBaseKind,$User,$Password,$NativeEffectContract,[string[]]$DesignerArgs)
                $script:calls.Add(@($DesignerArgs))
                $script:LastLogPath = Join-Path $script:ProjectRoot ("borrowed-$($script:calls.Count).log")
                $log = if ($script:failModules -and $DesignerArgs[0] -eq '/CheckModules') { 'Не найден метод.' } else { 'Ошибок: 0; предупреждений: 0' }
                [IO.File]::WriteAllText($script:LastLogPath,$log,[Text.UTF8Encoding]::new($false))
                $index = [Array]::IndexOf($DesignerArgs,'/DumpResult')
                if ($index -ge 0) { [IO.File]::WriteAllText($DesignerArgs[$index+1],'0',[Text.UTF8Encoding]::new($false)) }
            }
            $args = @('/LoadConfigFromFiles',$root,'/UpdateDBCfg')
            $passed = Invoke-ConfigLoadDesignerAttempt -InfoBasePath $state.devBranchInfoBasePath -InfoBaseKind file -RequireGate6 `
                -SourceFingerprint 'source' -DesignerArgs $args -User '' -Password ''
            $passedCalls = @($script:calls.ToArray())
            $script:calls.Clear()
            $script:failModules = $true
            $failure = try {
                Invoke-ConfigLoadDesignerAttempt -InfoBasePath $state.devBranchInfoBasePath -InfoBaseKind file -RequireGate6 `
                    -SourceFingerprint 'source' -DesignerArgs $args -User '' -Password '' | Out-Null
                ''
            } catch { $_.Exception.Message }
            $script:OneCNativeOperationJournal = $null
            [pscustomobject]@{ passed=$passed; passedCalls=$passedCalls; failedCalls=@($script:calls.ToArray()); failure=$failure; duty=$duty.payload; hash=(Get-FileHash -LiteralPath $snapshotPath).Hash.ToLowerInvariant() }
        }
        $actual.passedCalls | Should -HaveCount 4
        $actual.failedCalls | Should -HaveCount 2
        $actual.failure | Should -Match 'GATE6_CHECK_FAILED'
        $actual.duty.status | Should -Be 'pending'
        $actual.duty.policy | Should -Be 'always'
        $actual.hash | Should -Be $actual.duty.snapshotSha256
        $actual.passed.editableLoad.snapshot.ownedByCheckedLoad | Should -BeFalse
        $actual.passed.editableLoad.snapshot.path | Should -Be $snapshotPath
        @($actual.passedCalls | ForEach-Object { $_[0] }) | Should -Not -Contain '/DumpIB'
        @($actual.failedCalls | ForEach-Object { $_[0] }) | Should -Not -Contain '/RestoreIB'
    }

    It 'rejects a <Defect> enclosing snapshot before editable mutation without creating an ambient journal' -TestCases @(
        @{ Defect='changed DT'; expected='missing or changed' },
        @{ Defect='wrong target'; expected='another infobase' },
        @{ Defect='changed duty'; expected='restoration duty' }
    ) {
        param($Defect, $expected)
        $root = Join-Path $TestDrive ('Явный snapshot Кириллица ' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        $snapshotPath = Join-Path $root 'Исходная база 1С.dt'
        [IO.File]::WriteAllBytes($snapshotPath, [byte[]](5,6,7))
        $actual = & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            $script:calls = [Collections.Generic.List[object]]::new()
            function Invoke-Designer {
                param($InfoBasePath,$InfoBaseKind,$User,$Password,$NativeEffectContract,[string[]]$DesignerArgs)
                $script:calls.Add(@($DesignerArgs))
                throw 'Invalid enclosing snapshot must be rejected before a native call'
            }
            $snapshot = [pscustomobject]@{
                path=$snapshotPath;sha256=(Get-FileHash -LiteralPath $snapshotPath).Hash.ToLowerInvariant()
                infoBaseKind='file';infoBasePath=(Join-Path $root 'Ветка 1С');duty=$null
            }
            $exactTarget = $snapshot.infoBasePath
            switch ($Defect) {
                'changed DT' { [IO.File]::WriteAllBytes($snapshotPath,[byte[]](8,9,10)) }
                'wrong target' { $snapshot.infoBasePath = Join-Path $root 'Чужая база 1С' }
                'changed duty' {
                    $snapshot.duty = [pscustomobject]@{payload=[pscustomobject]@{
                        kind='infobase-snapshot';status='pending';infoBase=[pscustomobject]@{kind='file';path=$exactTarget}
                        snapshotPath=$snapshotPath;snapshotSha256=('f'*64)
                    }}
                }
            }
            $beforeHash = (Get-FileHash -LiteralPath $snapshotPath).Hash
            $failure = try {
                Invoke-ConfigLoadDesignerAttempt -InfoBasePath $exactTarget -InfoBaseKind file -RequireGate6 -SourceFingerprint 'source' `
                    -EnclosingSnapshot $snapshot -DesignerArgs @('/LoadConfigFromFiles',$root,'/UpdateDBCfg') -User '' -Password '' | Out-Null
                ''
            } catch { $_.Exception.Message }
            [pscustomobject]@{
                failure=$failure;calls=@($script:calls.ToArray());journalPresent=($null-ne $script:OneCNativeOperationJournal)
                beforeHash=$beforeHash;afterHash=(Get-FileHash -LiteralPath $snapshotPath).Hash
                snapshotExists=(Test-Path -LiteralPath $snapshotPath)
            }
        }
        $actual.failure | Should -Match ('GATE6_SNAPSHOT_CHANGED.*'+[regex]::Escape($expected))
        $actual.calls | Should -HaveCount 0
        $actual.journalPresent | Should -BeFalse
        $actual.snapshotExists | Should -BeTrue
        $actual.afterHash | Should -Be $actual.beforeHash
    }

    It 'retains an exact snapshot and both diagnostics when the native rollback fails' {
        $root = Join-Path $TestDrive ('Отказ восстановления 1С ' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        $actual = & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            $script:OneCNativeOperationJournal = New-OneCNativeOperationJournal
            $script:calls = [Collections.Generic.List[object]]::new()
            function Get-PlatformPath { 'fixture-1cv8.exe' }
            function Invoke-Designer {
                param($InfoBasePath,$InfoBaseKind,$User,$Password,$NativeEffectContract,$RestorationDuty,[string[]]$DesignerArgs)
                $script:calls.Add(@($DesignerArgs))
                if ($DesignerArgs[0] -eq '/DumpIB') { [IO.File]::WriteAllBytes($DesignerArgs[1],[byte[]](1,2,3)) }
                if ($DesignerArgs[0] -eq '/RestoreIB') { throw 'native restore failure' }
                $script:LastLogPath = Join-Path $script:ProjectRoot ("failed-$($script:calls.Count).log")
                $log = if ($DesignerArgs[0] -eq '/CheckModules') { 'Не найден метод исходной конфигурации.' } else { 'Ошибок: 0; предупреждений: 0' }
                [IO.File]::WriteAllText($script:LastLogPath,$log,[Text.UTF8Encoding]::new($false))
                $index = [Array]::IndexOf($DesignerArgs,'/DumpResult')
                if ($index -ge 0) { [IO.File]::WriteAllText($DesignerArgs[$index+1],'0',[Text.UTF8Encoding]::new($false)) }
            }
            $failure = try {
                Invoke-ConfigLoadDesignerAttempt -InfoBasePath 'C:\База 1С' -InfoBaseKind file -RequireGate6 -SourceFingerprint 'source' `
                    -DesignerArgs @('/LoadConfigFromFiles',$root,'/UpdateDBCfg') -User '' -Password '' | Out-Null
                ''
            } catch { $_.Exception.Message }
            $duty = $script:OneCNativeOperationJournal.restorations[0].payload
            $script:OneCNativeOperationJournal = $null
            [pscustomobject]@{ failure=$failure; calls=@($script:calls.ToArray()); duty=$duty; snapshotExists=(Test-Path -LiteralPath $duty.snapshotPath); failureLog=$script:LastLogPath }
        }
        $actual.failure | Should -Match 'GATE6_SNAPSHOT_RECOVERY_FAILED.*GATE6_CHECK_FAILED.*native restore failure'
        $actual.calls | Should -HaveCount 4
        @($actual.calls | ForEach-Object { $_[0] }) | Should -Not -Contain '/UpdateDBCfg'
        $actual.duty.status | Should -Be 'pending'
        $actual.snapshotExists | Should -BeTrue
        Get-Content -LiteralPath $actual.failureLog -Raw -Encoding UTF8 | Should -Match 'Не найден метод'
    }

    It 'restores before checking a CFE that changed during load and completes the stable original artifact on retry' {
        $root = Join-Path $TestDrive ('Изменённый CFE 1С ' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        $cfePath = Join-Path $root 'Служебное расширение.cfe'
        [IO.File]::WriteAllBytes($cfePath,[byte[]](1,2,3))
        $expectedSha = (Get-FileHash -LiteralPath $cfePath).Hash.ToLowerInvariant()
        $actual = & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            $script:calls = [Collections.Generic.List[object]]::new()
            $script:changeCfe = $true
            function Get-PlatformPath { 'fixture-1cv8.exe' }
            function Invoke-Designer {
                param($InfoBasePath,$InfoBaseKind,$User,$Password,$NativeEffectContract,$RestorationDuty,[string[]]$DesignerArgs)
                $script:calls.Add(@($DesignerArgs))
                if ($DesignerArgs[0] -eq '/DumpIB') { [IO.File]::WriteAllBytes($DesignerArgs[1],[byte[]](5,6,7)) }
                if ($DesignerArgs[0] -eq '/LoadCfg' -and $script:changeCfe) { [IO.File]::WriteAllBytes($cfePath,[byte[]](3,2,1)) }
                $script:LastLogPath = Join-Path $script:ProjectRoot ("cfe-$($script:calls.Count).log")
                [IO.File]::WriteAllText($script:LastLogPath,'Ошибок: 0; предупреждений: 0',[Text.UTF8Encoding]::new($false))
                $index = [Array]::IndexOf($DesignerArgs,'/DumpResult')
                if ($index -ge 0) { [IO.File]::WriteAllText($DesignerArgs[$index+1],'0',[Text.UTF8Encoding]::new($false)) }
            }
            $failure = try {
                Invoke-GuardedCfeExtensionApply -InfoBasePath 'C:\База 1С' -InfoBaseKind file -CfePath $cfePath -ExtensionName Canary -User '' -Password '' | Out-Null
                ''
            } catch { $_.Exception.Message }
            $failedCalls = @($script:calls.ToArray())
            [IO.File]::WriteAllBytes($cfePath,[byte[]](1,2,3))
            $script:changeCfe = $false
            $script:calls.Clear()
            $passed = Invoke-GuardedCfeExtensionApply -InfoBasePath 'C:\База 1С' -InfoBaseKind file -CfePath $cfePath -ExtensionName Canary -User '' -Password ''
            [pscustomobject]@{ failure=$failure; failedCalls=$failedCalls; passed=$passed; passedCalls=@($script:calls.ToArray()) }
        }
        $actual.failure | Should -Match 'GATE6_SOURCE_CHANGED'
        $actual.failedCalls | Should -HaveCount 3
        @($actual.failedCalls | ForEach-Object { $_[0] }) | Should -Be @('/DumpIB','/LoadCfg','/RestoreIB')
        $actual.passed.gate6Evidence.sourceFingerprint | Should -Be ('sha256:'+$expectedSha)
        $actual.passedCalls | Should -HaveCount 6
        @($actual.passedCalls[5]) | Should -Contain '/UpdateDBCfg'
    }

    It 'does not roll back a successful apply after losing its snapshot completion acknowledgement' {
        $root = Join-Path $TestDrive ('Подтверждение применения 1С ' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        $actual = & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            $script:OneCNativeOperationJournal = New-OneCNativeOperationJournal
            $script:calls = [Collections.Generic.List[object]]::new()
            function Get-PlatformPath { 'fixture-1cv8.exe' }
            function Complete-OneCDatabaseRestorationDuty {
                param($Duty,$Resolution)
                $Duty.payload.status = $Resolution
                throw 'completion acknowledgement lost'
            }
            function Invoke-Designer {
                param($InfoBasePath,$InfoBaseKind,$User,$Password,$NativeEffectContract,$RestorationDuty,[string[]]$DesignerArgs)
                $script:calls.Add(@($DesignerArgs))
                if ($DesignerArgs[0] -eq '/DumpIB') { [IO.File]::WriteAllBytes($DesignerArgs[1],[byte[]](1,2,3)) }
                $script:LastLogPath = Join-Path $script:ProjectRoot ("ack-$($script:calls.Count).log")
                [IO.File]::WriteAllText($script:LastLogPath,'Ошибок: 0; предупреждений: 0',[Text.UTF8Encoding]::new($false))
                $index = [Array]::IndexOf($DesignerArgs,'/DumpResult')
                if ($index -ge 0) { [IO.File]::WriteAllText($DesignerArgs[$index+1],'0',[Text.UTF8Encoding]::new($false)) }
            }
            $failure = try {
                Invoke-ConfigLoadDesignerAttempt -InfoBasePath 'C:\База 1С' -InfoBaseKind file -RequireGate6 -SourceFingerprint 'source' `
                    -DesignerArgs @('/LoadConfigFromFiles',$root,'/UpdateDBCfg') -User '' -Password '' | Out-Null
                ''
            } catch { $_.Exception.Message }
            $duty = $script:OneCNativeOperationJournal.restorations[0].payload
            $script:OneCNativeOperationJournal = $null
            [pscustomobject]@{ failure=$failure; calls=@($script:calls.ToArray()); duty=$duty; snapshotExists=(Test-Path -LiteralPath $duty.snapshotPath) }
        }
        $actual.failure | Should -Match 'completion acknowledgement lost'
        $actual.calls | Should -HaveCount 5
        @($actual.calls | ForEach-Object { $_[0] }) | Should -Be @('/DumpIB','/LoadConfigFromFiles','/CheckModules','/CheckConfig','/UpdateDBCfg')
        $actual.duty.status | Should -Be 'committed'
        $actual.snapshotExists | Should -BeTrue
    }

    It 'selects main configuration checks for metadata and modules, but not a binary-only delta' {
        $result = & {
            . $helperPath -ProjectRoot $TestDrive -Action help *> $null
            [pscustomobject]@{
                module = Test-MainConfigurationGate6Required -ChangeSet ([pscustomobject]@{ files=@('CommonModules/Logic/Ext/Module.bsl'); requiresFullLoad=$false })
                metadata = Test-MainConfigurationGate6Required -ChangeSet ([pscustomobject]@{ files=@('Catalogs/Items/Items.xml'); requiresFullLoad=$false })
                binary = Test-MainConfigurationGate6Required -ChangeSet ([pscustomobject]@{ files=@('Templates/Logo/Picture.png'); requiresFullLoad=$false })
                unknown = Test-MainConfigurationGate6Required -ChangeSet ([pscustomobject]@{ files=@(); requiresFullLoad=$true })
            }
        }
        $result.module | Should -BeTrue
        $result.metadata | Should -BeTrue
        $result.binary | Should -BeFalse
        $result.unknown | Should -BeTrue
    }

    It 'checks a main configuration before apply and preserves the unselected direct path' {
        $root = Join-Path $TestDrive ('Основная конфигурация ' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        $actual = & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            $script:calls = [Collections.Generic.List[object]]::new()
            $script:failModules = $true
            function Get-PlatformPath { 'fixture-1cv8.exe' }
            function Invoke-Designer {
                param($InfoBasePath,$InfoBaseKind,$User,$Password,$NativeEffectContract,$RestorationDuty,[string[]]$DesignerArgs)
                $script:calls.Add(@($DesignerArgs))
                if ($DesignerArgs[0] -eq '/DumpIB') { [IO.File]::WriteAllBytes($DesignerArgs[1], [byte[]](1,2,3)) }
                $script:LastLogPath = Join-Path $script:ProjectRoot ("main-$($script:calls.Count).log")
                $log = if ($script:failModules -and $DesignerArgs -contains '/CheckModules') { 'Не найден метод исходной конфигурации.' } else { 'Ошибок: 0; предупреждений: 0' }
                [IO.File]::WriteAllText($script:LastLogPath, $log, [Text.UTF8Encoding]::new($false))
                $index = [Array]::IndexOf($DesignerArgs, '/DumpResult')
                if ($index -ge 0) { [IO.File]::WriteAllText($DesignerArgs[$index + 1], '0', [Text.UTF8Encoding]::new($false)) }
            }
            $args = @('/LoadConfigFromFiles', $root, '-Format', 'Hierarchical', '/UpdateDBCfg')
            $missingIdentity = try { Invoke-ConfigLoadDesignerAttempt -InfoBasePath 'C:\База 1С' -InfoBaseKind file -DesignerArgs $args -RequireGate6 -SourceFingerprint '' -User '' -Password '' | Out-Null; '' } catch { $_.Exception.Message }
            $callsWithoutIdentity = $script:calls.Count
            $failure = try { Invoke-ConfigLoadDesignerAttempt -InfoBasePath 'C:\База 1С' -InfoBaseKind file -DesignerArgs $args -RequireGate6 -SourceFingerprint 'main-source' -User '' -Password '' | Out-Null; '' } catch { $_.Exception.Message }
            $failed = @($script:calls.ToArray())
            $script:calls.Clear()
            $script:failModules = $false
            $passed = Invoke-ConfigLoadDesignerAttempt -InfoBasePath 'C:\База 1С' -InfoBaseKind file -DesignerArgs $args -RequireGate6 -SourceFingerprint 'main-source' -User '' -Password ''
            $checked = @($script:calls.ToArray())
            $script:calls.Clear()
            $unselected = Invoke-ConfigLoadDesignerAttempt -InfoBasePath 'C:\База 1С' -InfoBaseKind file -DesignerArgs $args -SourceFingerprint 'binary-source' -User '' -Password ''
            [pscustomobject]@{ missingIdentity=$missingIdentity; callsWithoutIdentity=$callsWithoutIdentity; failure=$failure; failed=$failed; passed=$passed; checked=$checked; unselected=$unselected; direct=@($script:calls.ToArray()) }
        }
        $actual.missingIdentity | Should -Match 'GATE6_SOURCE_IDENTITY_REQUIRED'
        $actual.callsWithoutIdentity | Should -Be 0
        $actual.failure | Should -Match 'GATE6_CHECK_FAILED.*modules.*Не найден метод'
        $actual.failed | Should -HaveCount 4
        @($actual.failed[0]) | Should -Contain '/DumpIB'
        @($actual.failed[1]) | Should -Not -Contain '/UpdateDBCfg'
        @($actual.failed[2]) | Should -Contain '/CheckModules'
        @($actual.failed[3]) | Should -Contain '/RestoreIB'
        $actual.passed.steps | Should -HaveCount 2
        $actual.passed.editableLoad.sourceFingerprint | Should -Be 'main-source'
        $actual.passed.editableLoad.logSha256 | Should -Match '^[a-f0-9]{64}$'
        $actual.checked | Should -HaveCount 5
        @($actual.checked[4]) | Should -Contain '/UpdateDBCfg'
        $actual.direct | Should -HaveCount 1
        @($actual.direct[0]) | Should -Contain '/UpdateDBCfg'
    }

    It 'restores the exact partial-load cursor after a failed check and then completes the same load' {
        $root = Join-Path $TestDrive ('Повтор основной конфигурации ' + [guid]::NewGuid().ToString('N'))
        $source = Join-Path $root 'src/cf'
        New-Item -ItemType Directory -Force -Path $source | Out-Null
        $cursor = Join-Path $source 'ConfigDumpInfo.xml'
        $original = [Text.UTF8Encoding]::new($false).GetBytes("старый курсор`r`n")
        [IO.File]::WriteAllBytes($cursor, $original)
        $actual = & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            $script:calls = [Collections.Generic.List[object]]::new()
            $script:failModules = $true
            function Get-PlatformPath { 'fixture-1cv8.exe' }
            function Invoke-Designer {
                param($InfoBasePath,$InfoBaseKind,$User,$Password,$NativeEffectContract,$RestorationDuty,[string[]]$DesignerArgs)
                $script:calls.Add(@($DesignerArgs))
                if ($DesignerArgs[0] -eq '/DumpIB') { [IO.File]::WriteAllBytes($DesignerArgs[1], [byte[]](1,2,3)) }
                if ($DesignerArgs[0] -eq '/LoadConfigFromFiles') {
                    [IO.File]::WriteAllBytes($cursor, [Text.UTF8Encoding]::new($false).GetBytes('new cursor'))
                }
                $script:LastLogPath = Join-Path $script:ProjectRoot ("retry-$($script:calls.Count).log")
                $log = if ($script:failModules -and $DesignerArgs -contains '/CheckModules') { 'Не найден метод исходной конфигурации.' } else { 'Ошибок: 0; предупреждений: 0' }
                [IO.File]::WriteAllText($script:LastLogPath, $log, [Text.UTF8Encoding]::new($false))
                $index = [Array]::IndexOf($DesignerArgs, '/DumpResult')
                if ($index -ge 0) { [IO.File]::WriteAllText($DesignerArgs[$index + 1], '0', [Text.UTF8Encoding]::new($false)) }
            }
            $parameters = @{
                InfoBasePath='C:\База 1С'; InfoBaseKind='file'; AbsoluteExportPath=$source
                ListFilePath=(Join-Path $root 'list.txt'); FileCount=1; SourceFingerprint='main-source'
                ContentKind='configuration'; RequireGate6=$true; Mode='Partial'; User=''; Password=''
            }
            $failure = try { Invoke-ConfigLoadWithFallback @parameters | Out-Null; '' } catch { $_.Exception.Message }
            $failedCalls = @($script:calls.ToArray())
            $cursorAfterFailure = [IO.File]::ReadAllBytes($cursor)
            $script:calls.Clear()
            $script:failModules = $false
            $passed = Invoke-ConfigLoadWithFallback @parameters
            [pscustomobject]@{ failure=$failure; failedCalls=$failedCalls; cursorAfterFailure=$cursorAfterFailure; passed=$passed; passedCalls=@($script:calls.ToArray()) }
        }
        $actual.failure | Should -Match 'GATE6_CHECK_FAILED.*modules'
        $actual.failedCalls | Should -HaveCount 4
        @($actual.failedCalls[0]) | Should -Contain '/DumpIB'
        @($actual.failedCalls[3]) | Should -Contain '/RestoreIB'
        $actual.cursorAfterFailure | Should -Be $original
        $actual.passed.configLoadStatus | Should -Be 'passed'
        $actual.passedCalls | Should -HaveCount 5
        @($actual.passedCalls[4]) | Should -Contain '/UpdateDBCfg'
    }

    It 'routes a tooling CFE through the common checks and binds its source SHA before apply' {
        $root = Join-Path $TestDrive ('Служебный CFE ' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        $cfe = Join-Path $root 'Инструмент 1С.cfe'
        [IO.File]::WriteAllBytes($cfe, [byte[]](1, 2, 3))
        $actual = & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            $script:calls = [Collections.Generic.List[object]]::new()
            function Get-PlatformPath { 'fixture-1cv8.exe' }
            function Invoke-Designer {
                param($InfoBasePath,$InfoBaseKind,$User,$Password,$NativeEffectContract,$RestorationDuty,[string[]]$DesignerArgs)
                $script:calls.Add(@($DesignerArgs))
                if ($DesignerArgs[0] -eq '/DumpIB') { [IO.File]::WriteAllBytes($DesignerArgs[1], [byte[]](1,2,3)) }
                $script:LastLogPath = Join-Path $script:ProjectRoot ("tooling-$($script:calls.Count).log")
                [IO.File]::WriteAllText($script:LastLogPath, 'Ошибок: 0; предупреждений: 0', [Text.UTF8Encoding]::new($false))
                $index = [Array]::IndexOf($DesignerArgs, '/DumpResult')
                if ($index -ge 0) { [IO.File]::WriteAllText($DesignerArgs[$index + 1], '0', [Text.UTF8Encoding]::new($false)) }
            }
            $result = Invoke-GuardedCfeExtensionApply -InfoBasePath 'C:\База 1С' -InfoBaseKind file `
                -CfePath $cfe -ExtensionName 'YAXUNIT' -User '' -Password ''
            [pscustomobject]@{ result=$result; calls=@($script:calls.ToArray()) }
        }
        $actual.result.gate6Evidence.sourceFingerprint | Should -Be ('sha256:' + (Get-FileHash -LiteralPath $cfe -Algorithm SHA256).Hash.ToLowerInvariant())
        $actual.result.gate6Evidence.editableLoad.logSha256 | Should -Match '^[a-f0-9]{64}$'
        Test-Path -LiteralPath $actual.result.gate6Evidence.evidencePath -PathType Leaf | Should -BeTrue
        (Get-Content -LiteralPath $actual.result.gate6Evidence.evidencePath -Raw -Encoding UTF8 | ConvertFrom-Json).steps.Count | Should -Be 3
        $actual.calls | Should -HaveCount 6
        @($actual.calls[0]) | Should -Contain '/DumpIB'
        @($actual.calls[1]) | Should -Not -Contain '/UpdateDBCfg'
        @($actual.calls[3]) | Should -Contain '/CheckCanApplyConfigurationExtensions'
        @($actual.calls[5]) | Should -Contain '/UpdateDBCfg'
    }

    It 'requires all three fresh signals and never lets a success fragment hide a later diagnostic' {
        $root = Join-Path $TestDrive ('Проверка платформы ' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        $resultPath = Join-Path $root 'Результат 1С.txt'
        $logPath = Join-Path $root 'Журнал 1С.txt'
        $result = & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            [IO.File]::WriteAllText($resultPath, "0`n", [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText($logPath, "Проверка завершена. Ошибок не обнаружено; предупреждений: 0`n", [Text.UTF8Encoding]::new($false))
            $clean = Get-DesignerBatchCheckVerdict -ExitCode 0 -ResultPath $resultPath -LogPath $logPath
            [IO.File]::WriteAllText($logPath, "Ошибок: 0; предупреждений: 1`nОшибок не обнаружено. Не найден метод Поставщика`n", [Text.UTF8Encoding]::new($false))
            $mixed = Get-DesignerBatchCheckVerdict -ExitCode 0 -ResultPath $resultPath -LogPath $logPath
            [IO.File]::WriteAllText($logPath, "Ошибок: 0; предупреждений: 01`n", [Text.UTF8Encoding]::new($false))
            $leadingZero = Get-DesignerBatchCheckVerdict -ExitCode 0 -ResultPath $resultPath -LogPath $logPath
            [IO.File]::WriteAllText($logPath, "Ошибок: 0; предупреждений: 0`n", [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText($resultPath, "1`n", [Text.UTF8Encoding]::new($false))
            $batchFailed = Get-DesignerBatchCheckVerdict -ExitCode 0 -ResultPath $resultPath -LogPath $logPath
            [IO.File]::WriteAllText($resultPath, "not-a-number`n", [Text.UTF8Encoding]::new($false))
            $invalid = Get-DesignerBatchCheckVerdict -ExitCode 0 -ResultPath $resultPath -LogPath $logPath
            Remove-Item -LiteralPath $resultPath -Force
            $missing = Get-DesignerBatchCheckVerdict -ExitCode 0 -ResultPath $resultPath -LogPath $logPath
            [IO.File]::WriteAllText($resultPath, "0`n", [Text.UTF8Encoding]::new($false))
            $exitFailed = Get-DesignerBatchCheckVerdict -ExitCode 5 -ResultPath $resultPath -LogPath $logPath
            [IO.File]::WriteAllBytes($logPath, [byte[]]@(0xFF, 0xFE, 0xFF))
            $invalidEncoding = Get-DesignerBatchCheckVerdict -ExitCode 0 -ResultPath $resultPath -LogPath $logPath
            [pscustomobject]@{ clean=$clean; mixed=$mixed; leadingZero=$leadingZero; batchFailed=$batchFailed; invalid=$invalid; missing=$missing; exitFailed=$exitFailed; invalidEncoding=$invalidEncoding }
        }
        $result.clean.passed | Should -BeTrue
        $result.mixed.passed | Should -BeFalse
        @($result.mixed.diagnostics) | Should -HaveCount 2
        $result.leadingZero.passed | Should -BeFalse
        $result.batchFailed.passed | Should -BeFalse
        $result.invalid.passed | Should -BeFalse
        $result.missing.passed | Should -BeFalse
        $result.exitFailed.passed | Should -BeFalse
        $result.invalidEncoding.passed | Should -BeFalse
        @($result.invalidEncoding.reasons) -join ' ' | Should -Match '/Out cannot be decoded'
    }

    It 'checks a loaded extension before the first database apply and stops on a missing intercepted method' {
        $root = Join-Path $TestDrive ('Расширение 1С ' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        $result = & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            $script:calls = [System.Collections.Generic.List[object]]::new()
            $script:failApplicability = $true
            function Get-PlatformPath { 'fixture-1cv8.exe' }
            function Invoke-Designer {
                param($InfoBasePath, $InfoBaseKind, $User, $Password, $NativeEffectContract, $RestorationDuty, [string[]]$DesignerArgs)
                $script:calls.Add(@($DesignerArgs))
                if ($DesignerArgs[0] -eq '/DumpIB') { [IO.File]::WriteAllBytes($DesignerArgs[1], [byte[]](1,2,3)) }
                $script:LastLogPath = Join-Path $script:ProjectRoot ("designer-$($script:calls.Count).log")
                $log = if ($script:failApplicability -and $DesignerArgs -contains '/CheckCanApplyConfigurationExtensions') {
                    'Ошибок не обнаружено. Не найден метод исходной конфигурации.'
                } else { 'Ошибок не обнаружено. Предупреждений: 0' }
                [IO.File]::WriteAllText($script:LastLogPath, $log, [Text.UTF8Encoding]::new($false))
                $resultIndex = [Array]::IndexOf($DesignerArgs, '/DumpResult')
                if ($resultIndex -ge 0) {
                    [IO.File]::WriteAllText($DesignerArgs[$resultIndex + 1], '0', [Text.UTF8Encoding]::new($false))
                }
            }
            $args = @('/LoadConfigFromFiles', 'C:\source с пробелом', '-Extension', 'Расширение', '-Format', 'Hierarchical', '/UpdateDBCfg')
            $missingName = ''
            try {
                Invoke-ConfigLoadWithFallback -InfoBasePath 'C:\база 1С' -InfoBaseKind file -AbsoluteExportPath 'C:\source с пробелом' `
                    -ContentKind extension -ExtensionName '' -Mode Full | Out-Null
            } catch { $missingName = $_.Exception.Message }
            $failure = ''
            try {
                Invoke-ConfigLoadDesignerAttempt -InfoBasePath 'C:\база 1С' -InfoBaseKind file -DesignerArgs $args `
                    -ExtensionName 'Расширение' -SourceFingerprint 'exact-source' -User '' -Password '' | Out-Null
            } catch { $failure = $_.Exception.Message }
            $failedCalls = @($script:calls.ToArray())
            $script:calls.Clear()
            $script:failApplicability = $false
            $passed = Invoke-ConfigLoadDesignerAttempt -InfoBasePath 'C:\база 1С' -InfoBaseKind file -DesignerArgs $args `
                -ExtensionName 'Расширение' -SourceFingerprint 'exact-source' -User '' -Password ''
            [pscustomobject]@{ missingName=$missingName; failure=$failure; failedCalls=$failedCalls; passed=$passed; passedCalls=@($script:calls.ToArray()) }
        }
        $result.missingName | Should -Match 'GATE6_EXTENSION_NAME_REQUIRED'
        $result.failure | Should -Match 'GATE6_CHECK_FAILED.*applicability.*Не найден метод'
        $result.failedCalls | Should -HaveCount 5
        @($result.failedCalls[0]) | Should -Contain '/DumpIB'
        @($result.failedCalls[1]) | Should -Not -Contain '/UpdateDBCfg'
        @($result.failedCalls[2]) | Should -Contain '/CheckModules'
        @($result.failedCalls[3]) | Should -Contain '/CheckCanApplyConfigurationExtensions'
        @($result.failedCalls[4]) | Should -Contain '/RestoreIB'
        $result.passed.steps | Should -HaveCount 3
        $result.passed.sourceFingerprint | Should -Be 'exact-source'
        $result.passedCalls | Should -HaveCount 6
        @($result.passedCalls[5]) | Should -Contain '/UpdateDBCfg'
    }

    It 'continues the original extension load after a source repair without a failed-check full-load fallback' {
        $root = Join-Path $TestDrive ('Повтор загрузки 1С ' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        $result = & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            $script:calls = [System.Collections.Generic.List[object]]::new()
            $script:missingMethod = $true
            $script:failApply = $false
            $script:cursorRestores = 0
            function Get-PlatformPath { 'fixture-1cv8.exe' }
            function New-ConfigDumpInfoLoadSnapshot { [pscustomobject]@{ path=(Join-Path $script:ProjectRoot 'ConfigDumpInfo.xml'); existed=$false; backupPath=''; preserveBackup=$false } }
            function Restore-ConfigDumpInfoLoadSnapshot { param($Snapshot) $script:cursorRestores++ }
            function Remove-ConfigDumpInfoLoadSnapshot { param($Snapshot) }
            function Complete-OneCFileRestorationDuty { param($Snapshot,$Resolution) }
            function Invoke-Designer {
                param($InfoBasePath, $InfoBaseKind, $User, $Password, $NativeEffectContract, $RestorationDuty, [string[]]$DesignerArgs)
                $script:calls.Add(@($DesignerArgs))
                if ($DesignerArgs[0] -eq '/DumpIB') { [IO.File]::WriteAllBytes($DesignerArgs[1], [byte[]](1,2,3)) }
                if ($script:failApply -and $DesignerArgs -contains '/UpdateDBCfg') { throw 'simulated database apply failure' }
                $script:LastLogPath = Join-Path $script:ProjectRoot ("load-$($script:calls.Count).log")
                $log = if ($script:missingMethod -and $DesignerArgs -contains '/CheckCanApplyConfigurationExtensions') {
                    'Ошибок не обнаружено. Не найден метод исходной конфигурации.'
                } else { 'Ошибок не обнаружено. Предупреждений: 0' }
                [IO.File]::WriteAllText($script:LastLogPath, $log, [Text.UTF8Encoding]::new($false))
                $resultIndex = [Array]::IndexOf($DesignerArgs, '/DumpResult')
                if ($resultIndex -ge 0) { [IO.File]::WriteAllText($DesignerArgs[$resultIndex + 1], '0', [Text.UTF8Encoding]::new($false)) }
            }
            $parameters = @{
                InfoBasePath = 'C:\база 1С'; InfoBaseKind = 'file'; State = [pscustomobject]@{}
                AbsoluteExportPath = $root; ListFilePath = (Join-Path $root 'list.txt')
                FileCount = 1; SourceFingerprint = 'first-source'; ContentKind = 'extension'
                ExtensionName = 'Расширение'; Mode = 'Auto'; User = ''; Password = ''
            }
            $firstError = ''
            try { Invoke-ConfigLoadWithFallback @parameters | Out-Null } catch { $firstError = $_.Exception.Message }
            $firstRestores = $script:cursorRestores
            $firstCalls = @($script:calls.ToArray())
            $script:calls.Clear()
            $script:missingMethod = $false
            $script:failApply = $true
            $applyError = ''
            try { Invoke-ConfigLoadWithFallback @parameters | Out-Null } catch { $applyError = $_.Exception.Message }
            $applyCalls = @($script:calls.ToArray())
            $script:calls.Clear()
            $script:failApply = $false
            $parameters.SourceFingerprint = 'repaired-source'
            $second = Invoke-ConfigLoadWithFallback @parameters
            [pscustomobject]@{ firstError=$firstError; firstRestores=$firstRestores; firstCalls=$firstCalls; applyError=$applyError; applyCalls=$applyCalls; second=$second; secondCalls=@($script:calls.ToArray()) }
        }
        $result.firstError | Should -Match 'GATE6_CHECK_FAILED.*applicability'
        $result.firstRestores | Should -Be 1
        $result.firstCalls | Should -HaveCount 5
        @($result.firstCalls[0]) | Should -Contain '/DumpIB'
        @($result.firstCalls[1]) | Should -Contain '-partial'
        @($result.firstCalls[4]) | Should -Contain '/RestoreIB'
        $result.applyError | Should -Match 'simulated database apply failure'
        $result.applyCalls | Should -HaveCount 7
        @($result.applyCalls[6]) | Should -Contain '/RestoreIB'
        $result.second.configLoadStatus | Should -Be 'passed'
        $result.second.gate6Evidence.sourceFingerprint | Should -Be 'repaired-source'
        $result.secondCalls | Should -HaveCount 6
        @($result.secondCalls[5]) | Should -Contain '/UpdateDBCfg'
    }
}
