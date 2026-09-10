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
        $Specification.fileName -cnotmatch '^VAExtension\.1\.29-itl-r[0-9]+\.cfe$' -or
        $Specification.protocol -cne 'itl-file-code-v1') { throw 'VANESSA_BUILD_PAIRED_EXTENSION_CONTRACT_INVALID' }
    $extensionSource = Join-Path $SourceRoot 'lib/VAExtension'
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
        [int]$PostExitProbeSeconds = 60
    )
    if (@($Bases).Count -eq 0) { throw 'VANESSA_BUILD_NATIVE_RESOURCES_REQUIRED' }
    $probe = New-DesignerInvocationProbeState -LauncherProcessId 0
    $evidence = [pscustomobject]@{ record = $null }
    $result = $null
    $released = $false
    $additional = @($Bases | Select-Object -Skip 1 | ForEach-Object {
        [pscustomobject]@{ infoBaseKind = 'file'; infoBasePath = $_.path; requiredSessions = 1; expectedChildRole = ''; purpose = $Purpose }
    })
    try {
        $result = Invoke-WithOneCSessionAdmissionContext -InfoBaseKind file -InfoBasePath $Bases[0].path `
            -RequiredSessions 1 -Purpose $Purpose -AdditionalAdmissions $additional `
            -SessionWaitTimeoutSeconds 300 -ScriptBlock {
                $evidence.record = $script:OneCSessionLaunchContext.nativeOperationRecord
                Invoke-NativeProcessAndWaitResult -FilePath $FilePath -Arguments $Arguments `
                    -OneCCreateInfoBaseSyntax:$CreateInfoBase -TimeoutSeconds $TimeoutSeconds `
                    -CompletionGraceSeconds 0 -PostExitProbeSeconds $PostExitProbeSeconds -RequirePostExitProbeOnFailure `
                    -CompletionProbe {
                        param($context)
                        Test-OneCNativeInvocationReleased -ProbeState $probe -ProbeContext $context -LogPath ''
                    }
            }
    } finally {
        $scanReleased = $true
        if ($null -ne $probe.processScanProcess) { $scanReleased = [bool](Stop-DesignerProcessEnumeration -ProbeState $probe).confirmed }
        $released = $scanReleased -and [bool]$probe.processesReleaseConfirmed
        Confirm-OneCNativeOperationRelease -Record $evidence.record `
            -LauncherExited ([bool](Get-StateValue -State $result -Name 'launcherExited' -Default $false)) `
            -OwnedProcessesReleased $released -Evidence 'vanessa-build-owned-process-release'
    }
    if (-not $released -or $null -eq $result -or $result.timedOut -or $result.completionProbeFailed -or
        $result.postExitProbeTimedOut -or $result.launcherExitCode -ne 0) {
        throw "VANESSA_BUILD_NATIVE_STAGE_FAILED: purpose='$Purpose'; ownedReleased=$released; result=$($result | ConvertTo-Json -Depth 3 -Compress)"
    }
    return [pscustomobject]@{ purpose = $Purpose; ownedReleased = $released; exitCode = $result.launcherExitCode }
}
