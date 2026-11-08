BeforeAll {
    $script:AdmissionFixturePythonOverride = $env:ITL_PYTHON_EXECUTABLE
    if (-not $env:ITL_PYTHON_EXECUTABLE) { $env:ITL_PYTHON_EXECUTABLE = (Get-Command python -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source }
    . (Join-Path $PSScriptRoot 'TestSupport.ps1')
    $context = Initialize-WorkflowPesterContext
    $script:BuildRuntimeRepo = $context.RepoRoot
    $script:BuildRuntimeHelper = $context.HelperPath
    $script:BuildRuntimeModule = Join-Path $context.RepoRoot 'scripts/vanessa-build-runtime.ps1'
    . $script:BuildRuntimeModule

    function Invoke-BuildNativeFixture {
        param([string]$Failure = '')
        $root = Join-Path $TestDrive (([guid]::NewGuid().ToString('N')) + '/Сборка с пробелом')
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        & {
            param($Root, $Failure)
            . $script:BuildRuntimeHelper -ProjectRoot $Root -Action help *> $null
            . $script:BuildRuntimeModule
            $script:OneCNativeOperationJournal = New-OneCNativeOperationJournal
            $script:BuildAdmissions = @()
            function Invoke-OneCSessionAdmissionSet {
                param($Admissions, $StartProcess)
                $script:BuildAdmissions = @($Admissions)
                & $StartProcess
            }
            function Publish-Agent1cLifecycleOperationProcessEvidence {}
            function Start-Process {
                param($FilePath, $ArgumentList, $WorkingDirectory, $WindowStyle, [switch]$PassThru,
                    $RedirectStandardOutput, $RedirectStandardError)
                if ($Failure -eq 'launch') { throw 'native start outcome unknown' }
                # A completed redirected native launch creates both streams,
                # even when the launcher writes no output.
                [IO.File]::WriteAllText($RedirectStandardOutput, '')
                [IO.File]::WriteAllText($RedirectStandardError, '')
                $script:BuildMockLaunchBirth = [DateTime]::UtcNow
                $process = [pscustomobject]@{ Id = 6100; Handle = [IntPtr]::Zero; ProcessName = 'oscript'; StartTime = $script:BuildMockLaunchBirth;
                    ExitTime = [DateTime]::UtcNow; HasExited = $true; ExitCode = $(if ($Failure -eq 'exit') { 7 } else { 0 }) }
                $process | Add-Member ScriptMethod Refresh {}
                $process | Add-Member ScriptMethod WaitForExit { param([int]$Milliseconds) $true }
                return $process
            }
            function Receive-DesignerProcessEnumeration {
                param($ProbeState, $LogPath)
                $inventory = @([pscustomobject]@{ Name = '1cv8c.exe'; ProcessId = 6200; ParentProcessId = 1; CommandLine = 'ENTERPRISE /Out foreign.log' })
                if ($Failure -eq 'child') {
                    $inventory += [pscustomobject]@{ Name = '1cv8.exe'; ProcessId = 6101; ParentProcessId = 6100;
                        CreationDate = $script:BuildMockLaunchBirth; CommandLine = 'DESIGNER' }
                }
                [pscustomobject]@{ status = 'completed'; processes = $inventory; infoBaseReleaseChecked = $false; infoBaseReleased = $false }
            }
            $errorMessage = ''
            try {
                $bases = @(Get-VanessaBuildDatabasePlan $Root)
                Invoke-VanessaBuildOwnedNative -FilePath 'oscript.exe' -Arguments @('fixture.os') `
                    -Bases @($bases[1], $bases[2]) -Purpose 'test-build-single' -TimeoutSeconds 3 -PostExitProbeSeconds 3 6>$null | Out-Null
            } catch { $errorMessage = $_.Exception.Message }
            [pscustomobject]@{
                error = $errorMessage
                released = (Test-OneCNativeOperationJournalReleased $script:OneCNativeOperationJournal)
                records = $script:OneCNativeOperationJournal.entries.Count
                admissions = $script:BuildAdmissions
            }
        } $root $Failure
    }
}

AfterAll { $env:ITL_PYTHON_EXECUTABLE = $script:AdmissionFixturePythonOverride }

Describe 'Paired Vanessa extension native build ownership' {
    It 'uses the guarded Designer for the exact source and records the produced paired artifact' {
        $result = & {
            param($Root)
            $script:PairedCalls = @()
            function Invoke-Designer {
                param($InfoBaseKind,$InfoBasePath,$User,$Password,$DesignerArgs)
                $script:PairedCalls += [pscustomobject]@{ path=$InfoBasePath; user=$User; args=$DesignerArgs }
                if ($DesignerArgs[0] -eq '/DumpCfg') { [IO.File]::WriteAllBytes($DesignerArgs[1], [byte[]]@(1,2,3,4)) }
            }
            [void][IO.Directory]::CreateDirectory($Root)
            $metadataPath = Join-Path $Root 'src/lib/VAExtension/Configuration.xml'
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $metadataPath))
            [IO.File]::WriteAllText($metadataPath, '<MetaDataObject><Configuration><Properties><Version>1.29</Version></Properties></Configuration></MetaDataObject>')
            $spec = [pscustomobject]@{sourcePath='lib/VAExtension';fileName='VAExtension.1.29-itl-r11.cfe';protocol='itl-file-code-v1'}
            $artifact = Invoke-VanessaBuildPairedExtension -SourceRoot (Join-Path $Root 'src') -WorkRoot $Root -InfoBasePath (Join-Path $Root 'base') -User 'service' -Specification $spec
            [pscustomobject]@{ artifact=$artifact; calls=$script:PairedCalls }
        } (Join-Path $TestDrive 'Расширение с пробелом')
        $result.calls | Should -HaveCount 2
        $result.calls[0].args[0] | Should -Be '/LoadConfigFromFiles'
        $result.calls[0].args[1] | Should -Be (Join-Path $TestDrive 'Расширение с пробелом/src/lib/VAExtension')
        $result.calls[0].args[-1] | Should -Be '/UpdateDBCfg'
        $result.calls[1].args[-1] | Should -Be 'VAExtension'
        $result.calls[0].path | Should -Be $result.calls[1].path
        $result.artifact.sha256 | Should -Be (Get-FileHash $result.artifact.path -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    It 'does not report an extension artifact after a failed or empty native build: <failure>' -TestCases @(@{failure='load'},@{failure='dump'},@{failure='missing'},@{failure='empty'}) {
        param($failure)
        {
            & {
                param($Root,$Failure)
                function Invoke-Designer {
                    param($InfoBaseKind,$InfoBasePath,$User,$Password,$DesignerArgs)
                    if (($Failure -eq 'load' -and $DesignerArgs[0] -eq '/LoadConfigFromFiles') -or ($Failure -eq 'dump' -and $DesignerArgs[0] -eq '/DumpCfg')) { throw ('NATIVE_' + $Failure) }
                    if ($Failure -eq 'empty' -and $DesignerArgs[0] -eq '/DumpCfg') { [IO.File]::WriteAllBytes($DesignerArgs[1],[byte[]]@()) }
                }
                [void][IO.Directory]::CreateDirectory($Root)
                $metadataPath = Join-Path $Root 'src/lib/VAExtension/Configuration.xml'
                [void][IO.Directory]::CreateDirectory((Split-Path -Parent $metadataPath))
                [IO.File]::WriteAllText($metadataPath, '<MetaDataObject><Configuration><Properties><Version>1.29</Version></Properties></Configuration></MetaDataObject>')
                $spec = [pscustomobject]@{sourcePath='lib/VAExtension';fileName='VAExtension.1.29-itl-r11.cfe';protocol='itl-file-code-v1'}
                Invoke-VanessaBuildPairedExtension -SourceRoot (Join-Path $Root 'src') -WorkRoot $Root -InfoBasePath (Join-Path $Root 'base') -User 'service' -Specification $spec
            } (Join-Path $TestDrive ('Неудачная сборка ' + $failure)) $failure
        } | Should -Throw
    }
    It 'rejects a paired CFE filename that disagrees with the source extension version' {
        $root = Join-Path $TestDrive 'version-mismatch'
        $metadataPath = Join-Path $root 'src/lib/VAExtension/Configuration.xml'
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $metadataPath))
        [IO.File]::WriteAllText($metadataPath, '<MetaDataObject><Configuration><Properties><Version>1.32</Version></Properties></Configuration></MetaDataObject>')
        $spec = [pscustomobject]@{sourcePath='lib/VAExtension';fileName='VAExtension.1.29-itl-r1.cfe';protocol='itl-file-code-v1'}
        { Invoke-VanessaBuildPairedExtension -SourceRoot (Join-Path $root 'src') -WorkRoot $root -InfoBasePath (Join-Path $root 'base') -User 'service' -Specification $spec } |
            Should -Throw '*VANESSA_BUILD_PAIRED_EXTENSION_VERSION_MISMATCH*'
    }
}

Describe 'Pinned upstream build execution adapters' {
    BeforeEach {
        $fixtureRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $source = Join-Path $fixtureRoot 'Исходники с пробелом/MakeVASingle.os'
        $destination = Join-Path $fixtureRoot 'Исполнение с пробелом/MakeVASingle.os'
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $source))
        $original = @'
КаталогБазы = ПолучитьИмяВременногоФайла();
СтрокаКоманды = "tool Enterprise /F""" + КаталогБазы;
ЗапуститьПриложение(СтрокаКоманды, , Истина, retCode);
Стр = Текст.Прочитать();
ЗапуститьПриложение(СтрокаКоманды, , Ложь, retCode);
'@
        [IO.File]::WriteAllText($source, $original, [Text.UTF8Encoding]::new($true))
        $hash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    It 'preserves pinned source bytes and synchronous Enterprise execution while selecting the owned base and service user' {
        $result = New-VanessaBuildExecutionCopy -SourcePath $source -DestinationPath $destination -ExpectedSha256 $hash -SingleBuild
        (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $hash
        $execution = [IO.File]::ReadAllText($destination, [Text.Encoding]::UTF8)
        $expected = $original.Replace('КаталогБазы = ПолучитьИмяВременногоФайла();', ('УправлениеКонфигуратором.ПутьКПлатформе1С(ПолучитьПеременнуюСреды("PLATFORM_PATH"));' + [Environment]::NewLine + 'КаталогБазы = ПолучитьПеременнуюСреды("ITL_VANESSA_BUILD_SCRATCH_BASE");')).Replace(
            ' Enterprise /F""" + КаталогБазы', ' Enterprise /N""" + ПолучитьПеременнуюСреды("ITL_VANESSA_BUILD_USER") + """ /F""" + КаталогБазы').Replace(
            'ЗапуститьПриложение(СтрокаКоманды, , Ложь, retCode);', 'retCode = 0; // ITL: no directory window during a noninteractive build.').Replace(
            'Стр = Текст.Прочитать();', ('Стр = Текст.Прочитать();' + [Environment]::NewLine + 'Если Найти(Стр, "ЯЗапускаюМониторингКаталогаДляВнешнихСобытийРасширение") = 0 Тогда ВызватьИсключение "VANESSA_BUILD_VAEXTENSION_STEPS_MISSING"; КонецЕсли;' +
                [Environment]::NewLine + 'Если Найти(Стр, "ЯЭмулируюВводТекста") = 0 Тогда ВызватьИсключение "VANESSA_BUILD_VANESSAEXT_STEPS_MISSING"; КонецЕсли;' +
                [Environment]::NewLine + 'Если Найти(Стр, "КликНаКартинку") = 0 Тогда ВызватьИсключение "VANESSA_BUILD_SIKULIX_STEPS_MISSING"; КонецЕсли;' +
                [Environment]::NewLine + 'Если Найти(Стр, "ЯДелаюКликПоЭлементуФормыUIAutomation") = 0 Тогда ВызватьИсключение "VANESSA_BUILD_UIAUTOMATION_STEPS_MISSING"; КонецЕсли;'))
        $execution | Should -BeExactly $expected
        # Every patched step library that can drop out of the cache on a compile failure is required.
        foreach ($marker in @('VAEXTENSION', 'VANESSAEXT', 'SIKULIX', 'UIAUTOMATION')) {
            $execution | Should -Match ('VANESSA_BUILD_' + $marker + '_STEPS_MISSING')
        }
        $result.sourceSha256 | Should -Be $hash
        $result.executionSha256 | Should -Be (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    It 'rejects unpinned source before creating an execution copy' {
        { New-VanessaBuildExecutionCopy -SourcePath $source -DestinationPath $destination -ExpectedSha256 ('0' * 64) -SingleBuild } | Should -Throw '*UPSTREAM_FLOW_HASH_MISMATCH*'
        Test-Path -LiteralPath $destination | Should -BeFalse
    }
    It 'rejects ambiguous replacement sites before overwriting an existing execution copy' {
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $destination))
        [IO.File]::WriteAllText($destination, 'keep existing copy')
        [IO.File]::AppendAllText($source, "`nКаталогБазы = ПолучитьИмяВременногоФайла();", [Text.Encoding]::UTF8)
        $changedHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
        { New-VanessaBuildExecutionCopy -SourcePath $source -DestinationPath $destination -ExpectedSha256 $changedHash -SingleBuild } | Should -Throw '*EXECUTION_ADAPTER_MISMATCH*'
        [IO.File]::ReadAllText($destination) | Should -BeExactly 'keep existing copy'
    }
}

Describe 'Build native descendants and complete session admissions' {
    It 'does not replace a later failed creation release check with earlier build evidence' {
        $observed = & {
            . $script:BuildRuntimeHelper -ProjectRoot $script:BuildRuntimeRepo -Action help *> $null
            . $script:BuildRuntimeModule
            $script:OneCNativeOperationJournal = New-OneCNativeOperationJournal
            function Invoke-NativeProcessAndWaitResult {
                $probe.processesReleaseConfirmed = $true
                $script:OneCSessionLaunchContext.nativeOperationRecord.startAttempted = $true
                return [pscustomobject]@{launcherExited=$true;launcherExitCode=0;exitCode=-4;ownedProcessesReleased=$false;timedOut=$false;completionProbeFailed=$false;postExitProbeTimedOut=$false}
            }
            $message = ''
            try {
                Invoke-VanessaBuildOwnedNative -FilePath fake.exe -Arguments @('CREATEINFOBASE','File="C:\fixture";') `
                    -Bases @([pscustomobject]@{kind='file';path='C:\fixture'}) -Purpose create-fixture -CreateInfoBase | Out-Null
            } catch { $message = $_.Exception.Message }
            [pscustomobject]@{message=$message;released=(Test-OneCNativeOperationJournalReleased $script:OneCNativeOperationJournal)}
        }
        $observed.message | Should -Match 'VANESSA_BUILD_NATIVE_STAGE_FAILED'
        $observed.released | Should -BeFalse
    }

    It 'admits both single-build bases and confirms release with an unrelated client still alive' {
        $result = Invoke-BuildNativeFixture
        $result.error | Should -Be ''
        $result.released | Should -BeTrue
        $result.records | Should -Be 1
        $result.admissions | Should -HaveCount 2
        @($result.admissions | Where-Object requiredSessions -ne 1) | Should -HaveCount 0
        $result.admissions[0].infoBasePath | Should -Match 'Сборка с пробелом.*scratch-single$'
        $result.admissions[1].infoBasePath | Should -Match 'Сборка с пробелом.*base$'
    }
    It 'retains ownership when a 1C descendant survives the OneScript launcher' {
        $result = Invoke-BuildNativeFixture -Failure child
        $result.error | Should -Match 'VANESSA_BUILD_NATIVE_STAGE_FAILED'
        $result.released | Should -BeFalse
    }
    It 'reports a failed launcher even after successful descendant cleanup' {
        $result = Invoke-BuildNativeFixture -Failure exit
        $result.error | Should -Match 'VANESSA_BUILD_NATIVE_STAGE_FAILED'
        $result.released | Should -BeTrue
    }
    It 'does not release a launch whose native outcome is unknown' {
        $result = Invoke-BuildNativeFixture -Failure launch
        $result.error | Should -Match 'native start outcome unknown'
        $result.released | Should -BeFalse
    }
}
Describe 'Thin-client compile check of the built single EPF' {
    BeforeAll {
        $script:R11CompileError = '{ВнешняяОбработка.VanessaAutomationsingle.Форма.MCPVA.Форма(3625,22)}: Тип не определен (ХешированиеДанных)'
        function New-ThinCheckEventLog {
            param([string]$Base)
            $directory = Join-Path $Base '1Cv8Log'
            [void][IO.Directory]::CreateDirectory($directory)
            $lgf = "1CV8LOG(ver 2.0)`r`n917deeb7-e32c-43a6-8c84-f005c26a16e2`r`n`r`n" +
                "{1,90345aec-6d0e-480e-b724-7074cd4dd38b,""itl_vanessa_service"",1},`r`n{3,""1CV8C"",1},`r`n" +
                "{4,""_`$Session`$_.Start"",2},`r`n{4,""_`$PerformError`$_"",7}"
            [IO.File]::WriteAllText((Join-Path $directory '1Cv8.lgf'), $lgf, [Text.UTF8Encoding]::new($true))
            [IO.File]::WriteAllText((Join-Path $directory '20261102000000.lgp'), "1CV8LOG(ver 2.0)`r`n0c441db2-48fe-481d-acb3-139046310c2d`r`n", [Text.UTF8Encoding]::new($true))
        }
        function Add-ThinCheckEventRecord {
            param([string]$Base, [string]$Level, [int]$EventId, [string]$Comment)
            # Same sequential 8.3.27 record shape as the r11 smoke event log.
            $record = ",`r`n{20261107143635,N,`r`n{0,0},2,1,2,1,$EventId,$Level,""$($Comment.Replace('"', '""'))"",0,`r`n{""U""},"""",0,0,0,1,0,`r`n{0}`r`n}"
            [IO.File]::AppendAllText((Join-Path $Base '1Cv8Log/20261102000000.lgp'), $record, [Text.UTF8Encoding]::new($false))
        }
        function Invoke-ThinCheckFixture {
            param([string]$Mode)
            $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '/Сборка VA с пробелом')
            $base = Join-Path $root 'base'
            $platformBin = Join-Path $root 'Платформа 1С/bin'
            [void][IO.Directory]::CreateDirectory($platformBin)
            foreach ($name in @('1cv8.exe', '1cv8c.exe')) { [IO.File]::WriteAllBytes((Join-Path $platformBin $name), [byte[]]@()) }
            $epf = Join-Path $root 'out/Temp/DistribVanessaAutomationsingle/vanessa-automation-single.epf'
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $epf))
            [IO.File]::WriteAllBytes($epf, [byte[]]@(1))
            New-ThinCheckEventLog -Base $base
            # The qualification base already holds an older error before the check.
            Add-ThinCheckEventRecord -Base $base -Level E -EventId 7 -Comment 'build-time error before the check'
            $savedPlatform = $env:PLATFORM_PATH
            try {
                $env:PLATFORM_PATH = Join-Path $platformBin '1cv8.exe'
                & {
                    param($Root, $FixtureBase, $Epf, $FixtureMode)
                    . $script:BuildRuntimeHelper -ProjectRoot $Root -Action help *> $null
                    . $script:BuildRuntimeModule
                    $script:ThinCall = $null
                    function Invoke-VanessaBuildOwnedNative {
                        param($FilePath, $Arguments, $Bases, $Purpose, $TimeoutSeconds, $RunParamsPath, $FailureProbe)
                        $script:ThinCall = [pscustomobject]@{ file = $FilePath; arguments = $Arguments; bases = $Bases; purpose = $Purpose
                            timeout = $TimeoutSeconds; params = $RunParamsPath; probe = '' }
                        $elapsed = 3
                        switch ($FixtureMode) {
                            'r11-before-19f5ade5' {
                                Add-ThinCheckEventRecord -Base $FixtureBase -Level I -EventId 2 -Comment ''
                                Add-ThinCheckEventRecord -Base $FixtureBase -Level E -EventId 7 -Comment $script:R11CompileError
                            }
                            'current-r11' { Add-ThinCheckEventRecord -Base $FixtureBase -Level I -EventId 2 -Comment '' }
                            'hang' { $elapsed = $TimeoutSeconds - 120 }
                            'error-after-probe' { }
                        }
                        $script:ThinCall.probe = [string](& $FailureProbe ([pscustomobject]@{ elapsedSeconds = $elapsed; launcherExited = $false }))
                        if ($FixtureMode -eq 'error-after-probe') { Add-ThinCheckEventRecord -Base $FixtureBase -Level E -EventId 7 -Comment 'error written while closing' }
                        if ($script:ThinCall.probe) { throw "VANESSA_BUILD_NATIVE_PROBE_FAILED: purpose='$Purpose'; failure='$($script:ThinCall.probe)'" }
                        return [pscustomobject]@{ purpose = $Purpose; ownedReleased = $true; exitCode = 0 }
                    }
                    $message = ''
                    $stage = $null
                    try {
                        $stage = Invoke-VanessaBuildThinClientCheck -EpfPath $Epf -Base ([pscustomobject]@{ kind = 'file'; path = $FixtureBase }) `
                            -User 'itl_vanessa_service' -WorkRoot $Root -TimeoutSeconds 240
                    } catch { $message = $_.Exception.Message }
                    $params = if ($script:ThinCall -and $script:ThinCall.params) { [IO.File]::ReadAllText($script:ThinCall.params, [Text.Encoding]::UTF8) | ConvertFrom-Json } else { $null }
                    [pscustomobject]@{ error = $message; stage = $stage; call = $script:ThinCall; params = $params; root = $Root; epf = $Epf; base = $FixtureBase }
                } $root $base $epf $Mode
            } finally { $env:PLATFORM_PATH = $savedPlatform }
        }
    }

    It 'fails the build with the event-log compile error of the r11 EPF before 19f5ade5' {
        $result = Invoke-ThinCheckFixture -Mode 'r11-before-19f5ade5'
        $result.error | Should -Match '^VANESSA_BUILD_THIN_CLIENT_FAILED'
        $result.error.Contains($script:R11CompileError) | Should -BeTrue
        $result.error | Should -Match 'event-log errors while TESTMANAGER was running'
        $result.error | Should -Not -Match 'build-time error before the check'
        $result.call.probe | Should -Not -BeNullOrEmpty
    }
    It 'passes the current r11 EPF that writes no error records' {
        $result = Invoke-ThinCheckFixture -Mode 'current-r11'
        $result.error | Should -Be ''
        $result.stage.purpose | Should -Be 'vanessa-build-thin-client-check'
        $result.stage.eventLogErrors | Should -Be 0
    }
    It 'fails a TESTMANAGER that does not close itself within the check timeout' {
        $result = Invoke-ThinCheckFixture -Mode 'hang'
        $result.error | Should -Match '^VANESSA_BUILD_THIN_CLIENT_FAILED'
        $result.error | Should -Match 'timeout: TESTMANAGER did not close itself within 240 seconds'
    }
    It 'reads the event log again after the run for records the live probe did not see' {
        $result = Invoke-ThinCheckFixture -Mode 'error-after-probe'
        $result.call.probe | Should -Be ''
        $result.error | Should -Match '^VANESSA_BUILD_THIN_CLIENT_FAILED.*error written while closing'
    }
    It 'reads records that a live session appends through a still-open segment handle' {
        $base = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '/Живая база с пробелом')
        New-ThinCheckEventLog -Base $base
        $mark = Get-VanessaBuildEventLogMark -InfoBasePath $base
        $segment = Join-Path $base '1Cv8Log/20261102000000.lgp'
        # 1C keeps the segment open for its whole session; a directory listing
        # then reports the size from before the run.
        $writer = [IO.FileStream]::new($segment, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
        try {
            $bytes = [Text.UTF8Encoding]::new($false).GetBytes(",`r`n{20261107143635,N,`r`n{0,0},2,1,2,1,7,E,""$script:R11CompileError"",0,`r`n{""U""},"""",0,0,0,1,0,`r`n{0}`r`n}")
            $writer.Write($bytes, 0, $bytes.Length)
            $writer.Flush()
            $errors = @(& {
                param($Base, $Mark)
                . $script:BuildRuntimeHelper -ProjectRoot $Base -Action help *> $null
                . $script:BuildRuntimeModule
                Get-VanessaBuildEventLogErrors -InfoBasePath $Base -Mark $Mark
            } $base $mark)
        } finally { $writer.Dispose() }
        $errors | Should -HaveCount 1
        $errors[0].Contains($script:R11CompileError) | Should -BeTrue
    }
    It 'opens the exact EPF in the thin client as a run-scoped TESTMANAGER with an empty feature set' {
        $result = Invoke-ThinCheckFixture -Mode 'current-r11'
        $call = $result.call
        $call.file | Should -Be (Join-Path $result.root 'Платформа 1С/bin/1cv8c.exe')
        $call.purpose | Should -Be 'vanessa-build-thin-client-check'
        $call.timeout | Should -Be 360
        @($call.bases) | Should -HaveCount 1
        $call.bases[0].path | Should -Be $result.base
        $call.arguments[0] | Should -Be 'ENTERPRISE'
        $call.arguments | Should -Contain '/TESTMANAGER'
        $call.arguments[[array]::IndexOf($call.arguments, '/F') + 1] | Should -Be $result.base
        $call.arguments[[array]::IndexOf($call.arguments, '/N') + 1] | Should -Be 'itl_vanessa_service'
        $call.arguments[[array]::IndexOf($call.arguments, '/Execute') + 1] | Should -Be $result.epf
        $call.arguments[-1] | Should -Be ('/CStartFeaturePlayer;QuietInstallVanessaExt;DisableFirstRunHelper;VAParams=' + $call.params)
        $call.params | Should -Be (Join-Path $result.root 'thin-client-check/VAParams.json')
        @($result.params.FeaturesToRun) | Should -HaveCount 0
        $result.params.'ЗавершитьРаботуСистемы' | Should -BeTrue
        $clients = @($result.params.'КлиентТестирования'.'ДанныеКлиентовТестирования')
        $clients | Should -HaveCount 1
        $clients[0].'ПутьКИнфобазе'.Contains($result.base) | Should -BeTrue
    }
}

Describe 'Owned build native failure probe' {
    It 'requires a run scope for a failure probe' {
        { Invoke-VanessaBuildOwnedNative -FilePath 'x.exe' -Arguments @('ENTERPRISE') -Bases @([pscustomobject]@{ kind = 'file'; path = 'C:\fixture' }) `
            -Purpose 'probe' -FailureProbe { 'x' } } | Should -Throw '*VANESSA_BUILD_NATIVE_RUN_SCOPE_REQUIRED*'
    }
    It 'stops the owned run scope on a probe failure and still confirms release' {
        $root = Join-Path $TestDrive (([guid]::NewGuid().ToString('N')) + '/Проверка клиента с пробелом')
        $result = & {
            param($Root)
            . $script:BuildRuntimeHelper -ProjectRoot $Root -Action help *> $null
            . $script:BuildRuntimeModule
            $base = Join-Path $Root 'base'
            [void][IO.Directory]::CreateDirectory($base)
            $paramsPath = Join-Path $Root 'thin-client-check/VAParams.json'
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $paramsPath))
            $connection = ConvertTo-Json -InputObject (New-VanessaTestClientInfoBaseArg -InfoBaseKind file -InfoBasePath $base)
            $params = '{"КлиентТестирования":{"ДанныеКлиентовТестирования":[{"ПутьКИнфобазе":' + $connection + ',"ПортЗапускаТестКлиента":48123}]}}'
            [IO.File]::WriteAllText($paramsPath, $params, [Text.UTF8Encoding]::new($false))
            $script:OneCNativeOperationJournal = New-OneCNativeOperationJournal
            $script:ThinStopped = $false
            $script:ThinStopScopes = @()
            function Invoke-OneCSessionAdmissionSet { param($Admissions, $StartProcess) & $StartProcess }
            function Publish-Agent1cLifecycleOperationProcessEvidence {}
            function Stop-OwnVanessaRunScopeProcesses { param($Scopes) $script:ThinStopped = $true; $script:ThinStopScopes = @($Scopes) }
            function Start-Process {
                param($FilePath, $ArgumentList, $WorkingDirectory, $WindowStyle, [switch]$PassThru, $RedirectStandardOutput, $RedirectStandardError)
                [IO.File]::WriteAllText($RedirectStandardOutput, '')
                [IO.File]::WriteAllText($RedirectStandardError, '')
                $process = [pscustomobject]@{ Id = 6300; Handle = [IntPtr]::Zero; ProcessName = '1cv8c'; StartTime = [DateTime]::UtcNow; ExitTime = [DateTime]::UtcNow; ExitCode = 1 }
                $process | Add-Member ScriptProperty HasExited { [bool]$script:ThinStopped }
                $process | Add-Member ScriptMethod Refresh {}
                $process | Add-Member ScriptMethod WaitForExit { param([int]$Milliseconds) Start-Sleep -Milliseconds 20; [bool]$script:ThinStopped }
                return $process
            }
            function Receive-DesignerProcessEnumeration {
                param($ProbeState, $LogPath)
                [pscustomobject]@{ status = 'completed'; processes = @([pscustomobject]@{ Name = '1cv8c.exe'; ProcessId = 6200; ParentProcessId = 1; CommandLine = 'ENTERPRISE /Out foreign.log' })
                    infoBaseReleaseChecked = $false; infoBaseReleased = $false }
            }
            $message = ''
            try {
                Invoke-VanessaBuildOwnedNative -FilePath '1cv8c.exe' -Arguments @('ENTERPRISE', '/TESTMANAGER') `
                    -Bases @([pscustomobject]@{ kind = 'file'; path = $base }) -Purpose 'thin-probe' -RunParamsPath $paramsPath `
                    -TimeoutSeconds 20 -PostExitProbeSeconds 10 -FailureProbe { param($context) 'compile failure observed' } 6>$null | Out-Null
            } catch { $message = $_.Exception.Message }
            [pscustomobject]@{ error = $message; stopped = $script:ThinStopped; scopes = $script:ThinStopScopes; paramsPath = $paramsPath
                released = (Test-OneCNativeOperationJournalReleased $script:OneCNativeOperationJournal) }
        } $root
        $result.error | Should -Match "^VANESSA_BUILD_NATIVE_PROBE_FAILED: purpose='thin-probe'; failure='compile failure observed'; ownedReleased=True"
        $result.stopped | Should -BeTrue
        $managers = @($result.scopes | Where-Object role -eq 'test-manager')
        $managers | Should -HaveCount 1
        $managers[0].runParamsPath | Should -Be $result.paramsPath
        $result.released | Should -BeTrue
    }
}




Describe 'Build service-template and cleanup contract' {
    It 'uses the existing service template without editing user or platform protection configuration' {
        $builder = Get-Content (Join-Path $script:BuildRuntimeRepo 'scripts/build-vanessa-automation-patched.ps1') -Raw -Encoding UTF8
        $worker = Get-Content (Join-Path $script:BuildRuntimeRepo 'scripts/run-vanessa-build-runtime.ps1') -Raw -Encoding UTF8
        $module = Get-Content $script:BuildRuntimeModule -Raw -Encoding UTF8
        ($builder + $worker + $module) | Should -Not -Match 'conf\.cfg|DisableUnsafeActionProtection|ScopedUnsafeActionProtectionBypass'
        $worker | Should -Match 'Get-VanessaServiceInfoBaseTemplate'
        $worker | Should -Match '/RestoreIB'
        $worker | Should -Match 'Get-VanessaBuildDatabasePlan'
        $worker | Should -Match 'Test-OneCNativeOperationJournalReleased'
        # The thin client must load the produced EPF before the paired extension changes the base.
        $worker | Should -Match "(?s)'vanessa-build-single'.*Invoke-VanessaBuildThinClientCheck -Base \`$buildBases\[2\].*Invoke-VanessaBuildPairedExtension"
        $builder | Should -Match 'Get-GitPathList.*-z'
        $builder | Should -Match 'if \(\$KeepWork -or -not \$nativeCleanupConfirmed\)'
    }
}
