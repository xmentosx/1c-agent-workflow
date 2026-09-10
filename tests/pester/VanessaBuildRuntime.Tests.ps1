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
                if ($Failure -eq 'launch') { throw 'native start outcome unknown' }
                $process = [pscustomobject]@{ Id = 6100; HasExited = $true; ExitCode = $(if ($Failure -eq 'exit') { 7 } else { 0 }) }
                $process | Add-Member ScriptMethod Refresh {}
                $process | Add-Member ScriptMethod WaitForExit { param([int]$Milliseconds) $true }
                return $process
            }
            function Receive-DesignerProcessEnumeration {
                param($ProbeState, $LogPath)
                $inventory = @([pscustomobject]@{ Name = '1cv8c.exe'; ProcessId = 6200; ParentProcessId = 1; CommandLine = 'ENTERPRISE /Out foreign.log' })
                if ($Failure -eq 'child') {
                    $inventory += [pscustomobject]@{ Name = '1cv8.exe'; ProcessId = 6101; ParentProcessId = 6100; CommandLine = 'DESIGNER' }
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
                $spec = [pscustomobject]@{sourcePath='lib/VAExtension';fileName='VAExtension.1.29-itl-r11.cfe';protocol='itl-file-code-v1'}
                Invoke-VanessaBuildPairedExtension -SourceRoot (Join-Path $Root 'src') -WorkRoot $Root -InfoBasePath (Join-Path $Root 'base') -User 'service' -Specification $spec
            } (Join-Path $TestDrive ('Неудачная сборка ' + $failure)) $failure
        } | Should -Throw
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
            'ЗапуститьПриложение(СтрокаКоманды, , Ложь, retCode);', 'retCode = 0; // ITL: no directory window during a noninteractive build.')
        $execution | Should -BeExactly $expected
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

Describe 'Build database queue resource set' {
    It 'excludes competitors from each scratch and service base, admits an unrelated base and releases the entire set' {
        $root = Join-Path $TestDrive 'Очередь сборки с пробелом'
        [void][IO.Directory]::CreateDirectory($root)
        & {
            param($Root)
            . $script:BuildRuntimeHelper -ProjectRoot $Root -Action help *> $null
            . $script:BuildRuntimeModule
            . (Join-Path $script:BuildRuntimeRepo '.agents/skills/itl-remote-runner/scripts/DatabaseAccess.ps1')
            $bases = @(Get-VanessaBuildDatabasePlan $Root)
            $bases | Should -HaveCount 3
            $request = @{ schemaVersion = 1; coordinator = (Join-Path $Root 'coordinator'); bases = $bases; timeout = 0; owner = @{ operation = 'build'; project = $Root } }
            $holder = Start-ItlDatabaseAccessHost -Request $request
            try {
                foreach ($base in $bases) {
                    $competitor = @{ schemaVersion = 1; coordinator = $request.coordinator; bases = @($base); timeout = 0; owner = @{ operation = 'competing-build'; project = $Root } }
                    { Start-ItlDatabaseAccessHost -Request $competitor } | Should -Throw '*WAIT_TIMEOUT*'
                }
                $independent = @{ schemaVersion = 1; coordinator = $request.coordinator; bases = @(@{ kind = 'file'; path = (Join-Path $Root 'other') }); timeout = 0; owner = @{ operation = 'other'; project = $Root } }
                $other = Start-ItlDatabaseAccessHost -Request $independent
                try { (Complete-ItlDatabaseAccessHost $other).status | Should -Be released } finally { Close-ItlDatabaseAccessHost $other }
                (Complete-ItlDatabaseAccessHost $holder).status | Should -Be released
            } finally { Close-ItlDatabaseAccessHost $holder }
            $next = Start-ItlDatabaseAccessHost -Request $request
            try { (Complete-ItlDatabaseAccessHost $next).status | Should -Be released } finally { Close-ItlDatabaseAccessHost $next }
        } $root
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
        $builder | Should -Match 'Get-GitPathList.*-z'
        $builder | Should -Match 'if \(\$KeepWork -or -not \$nativeCleanupConfirmed\)'
    }
}
