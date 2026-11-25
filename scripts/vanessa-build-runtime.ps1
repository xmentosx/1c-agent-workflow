function New-VanessaBuildExecutionCopy {
    param(
        [string]$SourcePath, [string]$DestinationPath, [string]$ExpectedSha256,
        [switch]$SingleBuild
    )
    $actual = (Get-FileHash -LiteralPath $SourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -cne $ExpectedSha256) { throw 'VANESSA_BUILD_UPSTREAM_FLOW_HASH_MISMATCH' }
    $text = [IO.File]::ReadAllText($SourcePath, [Text.Encoding]::UTF8)
    $changes = @(
        ,@('КаталогБазы = ПолучитьИмяВременногоФайла();', ('УправлениеКонфигуратором.ПутьКПлатформе1С(ПолучитьПеременнуюСреды("PLATFORM_PATH"));' + [Environment]::NewLine + 'КаталогБазы = ПолучитьПеременнуюСреды("ITL_VANESSA_BUILD_SCRATCH_BASE");'))
    )
    if ($SingleBuild) {
        $changes += ,@(' Enterprise /F""" + КаталогБазы', ' Enterprise /N""" + ПолучитьПеременнуюСреды("ITL_VANESSA_BUILD_USER") + """ /F""" + КаталогБазы')
        $changes += ,@('ЗапуститьПриложение(СтрокаКоманды, , Ложь, retCode);', 'retCode = 0; // ITL: no directory window during a noninteractive build.')
        $cacheRead = 'Стр = Текст.Прочитать();'
        # A library whose patched module fails to compile drops out of the step cache.
        $cacheCheck = $cacheRead + [Environment]::NewLine + 'Если Найти(Стр, "ЯЗапускаюМониторингКаталогаДляВнешнихСобытийРасширение") = 0 Тогда ВызватьИсключение "VANESSA_BUILD_VAEXTENSION_STEPS_MISSING"; КонецЕсли;'
        foreach ($librarySteps in @(
            @('ЯЭмулируюВводТекста', 'VANESSA_BUILD_VANESSAEXT_STEPS_MISSING'),
            @('КликНаКартинку', 'VANESSA_BUILD_SIKULIX_STEPS_MISSING'),
            @('ЯДелаюКликПоЭлементуФормыUIAutomation', 'VANESSA_BUILD_UIAUTOMATION_STEPS_MISSING')
        )) {
            $cacheCheck += [Environment]::NewLine + 'Если Найти(Стр, "' + $librarySteps[0] + '") = 0 Тогда ВызватьИсключение "' + $librarySteps[1] + '"; КонецЕсли;'
        }
        $changes += ,@($cacheRead, $cacheCheck)
    } else {
        # Compile.os starts one Designer per processor in a fast burst. After about
        # 140 such launches the platform can refuse its license for a while even with
        # no other 1C process running; slower launches are not refused. Only that
        # refusal repeats the same idempotent load after a bounded pause.
        $changes += ,@('УправлениеКонфигуратором.ВыполнитьКоманду(ПараметрыЗапуска);', ((@(
            'ITLПаузаЛицензииМс = 15000; ITLПовторовЛицензии = 20; ITLПовторЛицензии = 0;'
            'Пока Истина Цикл'
            'Попытка'
            'УправлениеКонфигуратором.ВыполнитьКоманду(ПараметрыЗапуска);'
            'Прервать;'
            'Исключение'
            'ITLТекстOut = "";'
            'Если Новый Файл(ИмяФайлаOut).Существует() Тогда ITLЧтениеOut = Новый ЧтениеТекста(ИмяФайлаOut, "UTF-8"); ITLТекстOut = ITLЧтениеOut.Прочитать(); ITLЧтениеOut.Закрыть(); КонецЕсли;'
            'ITLПовторЛицензии = ITLПовторЛицензии + 1;'
            'Если ITLПовторЛицензии > ITLПовторовЛицензии Или Найти(ITLТекстOut, "Не найдена лицензия") = 0 Тогда ВызватьИсключение; КонецЕсли;'
            'Лог.Предупреждение("ITL: 1C license refused; the same load repeats in " + Строка(ITLПаузаЛицензииМс / 1000) + " s, retry " + Строка(ITLПовторЛицензии) + " of " + Строка(ITLПовторовЛицензии));'
            'Приостановить(ITLПаузаЛицензииМс);'
            'КонецПопытки;'
            'КонецЦикла;'
        )) -join [Environment]::NewLine))
    }
    foreach ($change in $changes) {
        if ([regex]::Matches($text, [regex]::Escape($change[0])).Count -ne 1) {
            throw "VANESSA_BUILD_EXECUTION_ADAPTER_MISMATCH: $SourcePath"
        }
        $text = $text.Replace($change[0], $change[1])
    }
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $DestinationPath))
    [IO.File]::WriteAllText($DestinationPath, $text, [Text.UTF8Encoding]::new($true))
    return [pscustomobject]@{
        sourcePath = $SourcePath; sourceSha256 = $actual; executionPath = $DestinationPath
        executionSha256 = (Get-FileHash -LiteralPath $DestinationPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function Invoke-VanessaBuildPairedExtension {
    param([string]$SourceRoot, [string]$WorkRoot, [string]$InfoBasePath, [string]$User, [object]$Specification)
    if ($Specification.sourcePath -cne 'lib/VAExtension' -or
        $Specification.fileName -cnotmatch '^VAExtension\.[0-9]+\.[0-9]+-itl-r[0-9]+\.cfe$' -or
        $Specification.protocol -cne 'itl-file-code-v1') { throw 'VANESSA_BUILD_PAIRED_EXTENSION_CONTRACT_INVALID' }
    $extensionSource = Join-Path $SourceRoot 'lib/VAExtension'
    $metadataPath = Join-Path $extensionSource 'Configuration.xml'
    if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) { throw 'VANESSA_BUILD_PAIRED_EXTENSION_METADATA_MISSING' }
    [xml]$metadata = [IO.File]::ReadAllText($metadataPath, [Text.Encoding]::UTF8)
    $versionNode = $metadata.SelectSingleNode("/*[local-name()='MetaDataObject']/*[local-name()='Configuration']/*[local-name()='Properties']/*[local-name()='Version']")
    $version = if ($null -ne $versionNode) { [string]$versionNode.InnerText } else { '' }
    if ($version -cnotmatch '^[0-9]+\.[0-9]+$' -or
        $Specification.fileName -cnotmatch ('^VAExtension\.' + [regex]::Escape($version) + '-itl-r[0-9]+\.cfe$')) {
        throw 'VANESSA_BUILD_PAIRED_EXTENSION_VERSION_MISMATCH'
    }
    $outputPath = Join-Path $WorkRoot $Specification.fileName
    Invoke-Designer -InfoBaseKind file -InfoBasePath $InfoBasePath -User $User -Password '' `
        -DesignerArgs @('/LoadConfigFromFiles', $extensionSource, '-Extension', 'VAExtension', '-Format', 'Hierarchical', '/UpdateDBCfg') | Out-Null
    Invoke-Designer -InfoBaseKind file -InfoBasePath $InfoBasePath -User $User -Password '' `
        -DesignerArgs @('/DumpCfg', $outputPath, '-Extension', 'VAExtension') | Out-Null
    if (-not (Test-Path -LiteralPath $outputPath -PathType Leaf) -or (Get-Item -LiteralPath $outputPath).Length -eq 0) {
        throw 'VANESSA_BUILD_PAIRED_EXTENSION_NOT_PRODUCED'
    }
    return [pscustomobject]@{
        path = $outputPath; sha256 = (Get-FileHash -LiteralPath $outputPath -Algorithm SHA256).Hash.ToLowerInvariant()
        protocol = $Specification.protocol
    }
}

function Get-VanessaBuildDatabasePlan {
    param([Parameter(Mandatory = $true)][string]$WorkRoot)
    $root = [IO.Path]::GetFullPath($WorkRoot)
    @('scratch-compile', 'scratch-single', 'base') | ForEach-Object {
        [pscustomobject]@{ kind = 'file'; path = (Join-Path $root $_) }
    }
}

function Invoke-VanessaBuildOwnedNative {
    param(
        [string]$FilePath, [string[]]$Arguments, [object[]]$Bases,
        [string]$Purpose, [switch]$CreateInfoBase,
        [int]$TimeoutSeconds = 3600,
        [int]$PostExitProbeSeconds = 60,
        [string]$RunParamsPath = '',
        # Returns a failure text for a live run; the run scope is then stopped
        # and the ordinary release probe still confirms its processes are gone.
        [scriptblock]$FailureProbe = $null
    )
    if (@($Bases).Count -eq 0) { throw 'VANESSA_BUILD_NATIVE_RESOURCES_REQUIRED' }
    if ((@($Arguments | Where-Object { $_ -ieq '/TESTMANAGER' }).Count -gt 0 -or $null -ne $FailureProbe) -and -not $RunParamsPath) { throw 'VANESSA_BUILD_NATIVE_RUN_SCOPE_REQUIRED' }
    $scopes = @(if ($RunParamsPath) { Get-OneCNativeRunProcessScopes -RunParamsPath $RunParamsPath -Resources $Bases })
    $probe = New-DesignerInvocationProbeState -LauncherProcessId 0 -OwnedProcessScopes $scopes
    $buildProbeFailure = [pscustomobject]@{ text = ''; stopError = '' }
    $evidence = [pscustomobject]@{ record = $null }
    $result = $null
    $released = $false
    $additional = @($Bases | Select-Object -Skip 1 | ForEach-Object {
        [pscustomobject]@{ infoBaseKind = 'file'; infoBasePath = $_.path; requiredSessions = 1; expectedChildRole = ''; purpose = $Purpose }
    })
    $outputRoot = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath([string]$Bases[0].path))
    $stdoutPath = Join-Path $outputRoot ($Purpose + '.stdout.log')
    $stderrPath = Join-Path $outputRoot ($Purpose + '.stderr.log')
    try {
        $result = Invoke-WithOneCSessionAdmissionContext -InfoBaseKind file -InfoBasePath $Bases[0].path `
            -RequiredSessions 1 -Purpose $Purpose -AdditionalAdmissions $additional `
            -SessionWaitTimeoutSeconds 300 -ScriptBlock {
                $evidence.record = $script:OneCSessionLaunchContext.nativeOperationRecord
                if ($null -ne $evidence.record) { $evidence.record.ownedProcessScopes = $scopes }
                Invoke-NativeProcessAndWaitResult -FilePath $FilePath -Arguments $Arguments `
                    -OneCCreateInfoBaseSyntax:$CreateInfoBase -TimeoutSeconds $TimeoutSeconds `
                    -StdoutPath $stdoutPath -StderrPath $stderrPath `
                    -CompletionGraceSeconds 0 -PostExitProbeSeconds $PostExitProbeSeconds -RequirePostExitProbeOnFailure `
                    -CompletionProbe {
                        param($context)
                        if ($null -ne $FailureProbe -and -not $buildProbeFailure.text -and -not $context.launcherExited) {
                            $failureText = [string](& $FailureProbe $context)
                            if ($failureText) {
                                $buildProbeFailure.text = $failureText
                                try { Stop-OwnVanessaRunScopeProcesses -Scopes $scopes | Out-Null } catch { $buildProbeFailure.stopError = $_.Exception.Message }
                            }
                        }
                        Test-OneCNativeInvocationReleased -ProbeState $probe -ProbeContext $context -LogPath ''
                    }
            }
    } finally {
        $scanReleased = $true
        if ($null -ne $probe.processScanProcess) { $scanReleased = [bool](Stop-DesignerProcessEnumeration -ProbeState $probe).confirmed }
        $released = $scanReleased -and [bool]$probe.processesReleaseConfirmed
        if ($CreateInfoBase -and $null -ne $result) {
            # The native creation owner takes a later live observation. Its
            # unresolved cleanup cannot be replaced by this earlier probe.
            $released = $released -and [bool](Get-StateValue -State $result -Name 'ownedProcessesReleased' -Default $false)
        }
        Confirm-OneCNativeOperationRelease -Record $evidence.record `
            -LauncherExited ([bool](Get-StateValue -State $result -Name 'launcherExited' -Default $false)) `
            -OwnedProcessesReleased $released -Evidence 'vanessa-build-owned-process-release'
    }
    if ($buildProbeFailure.text) {
        throw "VANESSA_BUILD_NATIVE_PROBE_FAILED: purpose='$Purpose'; failure='$($buildProbeFailure.text)'; ownedReleased=$released; stopError='$($buildProbeFailure.stopError)'; stdout='$stdoutPath'; stderr='$stderrPath'"
    }
    if (-not $released -or $null -eq $result -or $result.timedOut -or $result.completionProbeFailed -or
        $result.postExitProbeTimedOut -or $result.launcherExitCode -ne 0) {
        throw "VANESSA_BUILD_NATIVE_STAGE_FAILED: purpose='$Purpose'; ownedReleased=$released; stdout='$stdoutPath'; stderr='$stderrPath'; result=$($result | ConvertTo-Json -Depth 3 -Compress)"
    }
    return [pscustomobject]@{ purpose = $Purpose; ownedReleased = $released; exitCode = $result.launcherExitCode }
}

function Get-VanessaBuildEventLogSegmentLength {
    # A directory listing keeps the stale size of a segment that a live 1C
    # session holds open; only the file handle reports the appended records.
    param([Parameter(Mandatory = $true)][string]$Path)
    $stream = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
    try { return [int64]$stream.Length } finally { $stream.Dispose() }
}

function Get-VanessaBuildEventLogMark {
    param([Parameter(Mandatory = $true)][string]$InfoBasePath)
    $mark = @{}
    foreach ($segment in @(Get-ChildItem -LiteralPath (Join-Path $InfoBasePath '1Cv8Log') -File -Filter '*.lgp' -ErrorAction SilentlyContinue)) {
        $mark[$segment.Name] = Get-VanessaBuildEventLogSegmentLength -Path $segment.FullName
    }
    return $mark
}

function Get-VanessaBuildEventLogErrors {
    # Error-level records appended to the file infobase event log after Mark.
    param([Parameter(Mandatory = $true)][string]$InfoBasePath, [Parameter(Mandatory = $true)][hashtable]$Mark)
    $directory = Join-Path $InfoBasePath '1Cv8Log'
    if (-not (Test-Path -LiteralPath (Join-Path $directory '1Cv8.lgf') -PathType Leaf)) {
        throw "VANESSA_BUILD_EVENT_LOG_MISSING: '$directory'"
    }
    $selections = @(Get-ChildItem -LiteralPath $directory -File -Filter '*.lgp' | Sort-Object Name | ForEach-Object {
        $start = if ($Mark.ContainsKey($_.Name)) { [int64]$Mark[$_.Name] } else { [int64]0 }
        $length = Get-VanessaBuildEventLogSegmentLength -Path $_.FullName
        if ($length -gt $start) { [pscustomobject]@{ path = $_.FullName; startOffset = $start; endOffset = $length } }
    })
    if ($selections.Count -eq 0) { return @() }
    $state = [pscustomobject]@{ infoBaseKind = 'file'; devBranchInfoBasePath = $InfoBasePath }
    return @(Read-OneCEventLogDirectCore -State $state -Levels @('Error') -SegmentSelections $selections | ForEach-Object {
        (@($_.event, $_.metadata, $_.comment) | Where-Object { $_ }) -join ': '
    })
}

function Invoke-VanessaBuildThinClientCheck {
    # The thick-client MakeVASingle run cannot prove that client form modules
    # compile in the thin client used by every TESTMANAGER run. VA r11 passed
    # the build and then hung on the platform error dialog in Develop E2E.
    param(
        [Parameter(Mandatory = $true)][string]$EpfPath,
        [Parameter(Mandatory = $true)][object]$Base,
        [Parameter(Mandatory = $true)][string]$User,
        [Parameter(Mandatory = $true)][string]$WorkRoot,
        [ValidateRange(10, 3600)][int]$TimeoutSeconds = 300
    )
    if (-not (Test-Path -LiteralPath $EpfPath -PathType Leaf)) { throw "VANESSA_BUILD_THIN_CLIENT_FAILED: reason='epf-missing'; epf='$EpfPath'" }
    $thinClient = Resolve-EnterpriseClientExecutablePath -ClientType Thin
    $runDirectory = Join-Path ([IO.Path]::GetFullPath($WorkRoot)) 'thin-client-check'
    $featureDirectory = Join-Path $runDirectory 'features'
    [void][IO.Directory]::CreateDirectory($featureDirectory)
    # VAParams names one TestClient profile on the reserved base; with an empty
    # feature set no TestClient is launched, so an ephemeral free port suffices.
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    try { $listener.Start(); $port = [int]$listener.LocalEndpoint.Port } finally { $listener.Stop() }
    $topology = [pscustomobject]@{
        configured = $false; path = '<vanessa-build-thin-client-check>'; declaredTestClientCeiling = 1
        requiredTestClientSlots = 1; requiresExtensionTestClient = $false
        profiles = @([pscustomobject]@{ name = $User; user = $User; password = ''; synonym = ''; clientType = 'Thin' })
    }
    $paramsPath = New-VanessaParamsFile -FeaturePath $featureDirectory -RunDirectory $runDirectory `
        -StatusPath (Join-Path $runDirectory 'status.txt') `
        -State ([pscustomobject]@{ infoBaseKind = 'file'; devBranchInfoBasePath = $Base.path }) `
        -TestPort $port -TestPorts @($port) -TestClientTopology $topology -FilterTags ''
    $arguments = @('ENTERPRISE') + @(New-InfobaseArgs -Kind file -Path $Base.path -User $User -Password '') +
        @('/DisableStartupMessages', '/DisableStartupDialogs', '/TESTMANAGER', '/Out', (Join-Path $runDirectory 'thin-client.out.log'),
            '/Execute', $EpfPath, ('/C' + (New-VanessaStartFeaturePlayerCommand -ParamsPath $paramsPath)))
    # Unique names: the probe runs inside the native wait loop's scopes.
    $thinCheckBasePath = [string]$Base.path
    $thinCheckMark = Get-VanessaBuildEventLogMark -InfoBasePath $thinCheckBasePath
    $thinCheckTimeoutSeconds = $TimeoutSeconds
    $thinCheckPoll = [pscustomobject]@{ at = [DateTime]::MinValue; reads = 0; readError = '' }
    $thinCheckProbe = {
        param($context)
        if ([int]$context.elapsedSeconds -ge $thinCheckTimeoutSeconds) {
            return "timeout: TESTMANAGER did not close itself within $thinCheckTimeoutSeconds seconds; eventLogReads=$($thinCheckPoll.reads); lastReadError=$($thinCheckPoll.readError)"
        }
        if (([DateTime]::UtcNow - $thinCheckPoll.at).TotalSeconds -lt 2) { return '' }
        $thinCheckPoll.at = [DateTime]::UtcNow
        # A record still being written is read again after the run.
        $observed = @(try { Get-VanessaBuildEventLogErrors -InfoBasePath $thinCheckBasePath -Mark $thinCheckMark; $thinCheckPoll.reads++ } catch { $thinCheckPoll.readError = $_.Exception.Message })
        if ($observed.Count -gt 0) { return "event-log errors while TESTMANAGER was running" }
        return ''
    }
    $stage = $null
    $runFailure = ''
    try {
        $stage = Invoke-VanessaBuildOwnedNative -FilePath $thinClient -Arguments $arguments -Bases @($Base) `
            -Purpose 'vanessa-build-thin-client-check' -RunParamsPath $paramsPath `
            -TimeoutSeconds ($TimeoutSeconds + 120) -FailureProbe $thinCheckProbe
    } catch { $runFailure = $_.Exception.Message }
    $errors = @()
    $eventLogFailure = ''
    try { $errors = @(Get-VanessaBuildEventLogErrors -InfoBasePath $thinCheckBasePath -Mark $thinCheckMark) } catch { $eventLogFailure = $_.Exception.Message }
    if ($runFailure -or $eventLogFailure -or $errors.Count -gt 0) {
        throw "VANESSA_BUILD_THIN_CLIENT_FAILED: epf='$EpfPath'; errors=[$($errors -join ' | ')]; run='$runFailure'; eventLog='$eventLogFailure'"
    }
    return [pscustomobject]@{ purpose = $stage.purpose; ownedReleased = $stage.ownedReleased; exitCode = $stage.exitCode; eventLogErrors = 0 }
}
