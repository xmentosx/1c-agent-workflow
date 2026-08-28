function Get-AuxiliaryContourBranchKey {
    $branch = (Get-GitOutput @("branch", "--show-current")).Trim()
    if ([string]::IsNullOrWhiteSpace($branch)) { $branch = "detached" }
    return (ConvertTo-SafeName $branch)
}

function ConvertTo-AuxiliaryContourId {
    param([Parameter(Mandatory = $true)][string]$Name)

    $value = $Name.Trim().ToLowerInvariant()
    if ($value -notmatch '^[a-z0-9][a-z0-9-]{0,47}$') {
        throw "ITL_AUXILIARY_CONTOUR_NAME_INVALID: '$Name'. Use 1-48 lowercase latin letters, digits, and hyphens."
    }
    return $value
}

function Get-AuxiliaryContourDefinitions {
    $root = Get-ConfigValue -Path "auxiliaryContours" -Default $null
    if ($null -eq $root) { return @() }
    if ($root -is [System.Collections.IDictionary]) {
        $entries = @($root.GetEnumerator() | ForEach-Object { [pscustomobject]@{ name = [string]$_.Key; value = $_.Value } })
    } else {
        $entries = @($root.PSObject.Properties | ForEach-Object { [pscustomobject]@{ name = [string]$_.Name; value = $_.Value } })
    }

    $result = [System.Collections.Generic.List[object]]::new()
    $readWriteOwners = @{}
    $primaryPath = (Resolve-ProjectPath (Get-ExportPath)).TrimEnd('\', '/')
    foreach ($entry in $entries) {
        $id = ConvertTo-AuxiliaryContourId -Name $entry.name
        $raw = $entry.value
        if ($null -eq $raw) { throw "ITL_AUXILIARY_CONTOUR_INVALID: '$id' must be an object." }
        $baseMode = ([string](Get-StateValue -State $raw -Name "baseMode" -Default "managed-file")).Trim().ToLowerInvariant()
        if ($baseMode -notin @("managed-file", "attached-readonly", "attached-disposable")) {
            throw "ITL_AUXILIARY_BASE_MODE_INVALID: contour='$id' mode='$baseMode'."
        }
        $sourceMode = ([string](Get-StateValue -State $raw -Name "sourceMode" -Default "load-only")).Trim().ToLowerInvariant()
        if ($sourceMode -notin @("load-only", "read-write")) {
            throw "ITL_AUXILIARY_SOURCE_MODE_INVALID: contour='$id' mode='$sourceMode'."
        }
        $configurationPath = [string](Get-StateValue -State $raw -Name "configurationPath" -Default (Get-ExportPath))
        $absoluteConfigurationPath = Assert-ExportPathInsideProject -ExportPath $configurationPath
        if ($sourceMode -eq "read-write") {
            if ([string]::Equals($absoluteConfigurationPath.TrimEnd('\', '/'), $primaryPath, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "ITL_AUXILIARY_PRIMARY_SOURCE_READ_WRITE_FORBIDDEN: contour='$id' path='$configurationPath'."
            }
            $ownerKey = $absoluteConfigurationPath.ToLowerInvariant()
            if ($readWriteOwners.ContainsKey($ownerKey)) {
                throw "ITL_AUXILIARY_SOURCE_OWNER_CONFLICT: contours='$($readWriteOwners[$ownerKey]),$id' path='$configurationPath'."
            }
            $readWriteOwners[$ownerKey] = $id
        }
        $connectionRef = ([string](Get-StateValue -State $raw -Name "connectionRef" -Default $id)).Trim().ToUpperInvariant().Replace('-', '_')
        if ($connectionRef -notmatch '^[A-Z][A-Z0-9_]{0,47}$') {
            throw "ITL_AUXILIARY_CONNECTION_REF_INVALID: contour='$id' ref='$connectionRef'."
        }
        $tests = Get-StateValue -State $raw -Name "tests" -Default ([pscustomobject]@{})
        $mcp = Get-StateValue -State $raw -Name "mcp" -Default ([pscustomobject]@{})
        $extensions = @()
        foreach ($extension in @(Get-StateValue -State $raw -Name "extensions" -Default @())) {
            $extensionName = [string](Get-StateValue -State $extension -Name "name" -Default "")
            $extensionPath = [string](Get-StateValue -State $extension -Name "path" -Default "")
            if (-not $extensionName -or -not $extensionPath) {
                throw "ITL_AUXILIARY_EXTENSION_INVALID: contour='$id' requires extension name and path."
            }
            [void](Assert-ExportPathInsideProject -ExportPath $extensionPath)
            $extensions += [pscustomobject]@{ name = $extensionName; path = $extensionPath }
        }
        $testsIncludePrimary = [bool](Get-StateValue -State $tests -Name "includePrimary" -Default $true)
        $testsPath = [string](Get-StateValue -State $tests -Name "path" -Default "")
        if ($testsIncludePrimary -and $testsPath) {
            $primaryTests = (Resolve-ProjectPath (Get-ConfigValue -Path "testsPath" -Default "tests/features")).TrimEnd('\', '/')
            $contourTests = (Assert-ExportPathInsideProject -ExportPath $testsPath).TrimEnd('\', '/')
            $primaryPrefix = $primaryTests + [IO.Path]::DirectorySeparatorChar
            $contourPrefix = $contourTests + [IO.Path]::DirectorySeparatorChar
            if ([string]::Equals($primaryTests, $contourTests, [StringComparison]::OrdinalIgnoreCase) -or
                $contourTests.StartsWith($primaryPrefix, [StringComparison]::OrdinalIgnoreCase) -or
                $primaryTests.StartsWith($contourPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw "ITL_AUXILIARY_TEST_PATH_OVERLAP: contour='$id' primary='$primaryTests' contourTests='$contourTests'. Use disjoint suite roots."
            }
        }
        $result.Add([pscustomobject][ordered]@{
            name = $id
            displayName = [string](Get-StateValue -State $raw -Name "displayName" -Default $id)
            baseMode = $baseMode
            connectionRef = $connectionRef
            sourceMode = $sourceMode
            configurationPath = $configurationPath
            absoluteConfigurationPath = $absoluteConfigurationPath
            extensions = @($extensions)
            testsIncludePrimary = $testsIncludePrimary
            testsPath = $testsPath
            mcpRoctup = [bool](Get-StateValue -State $mcp -Name "roctup" -Default $false)
            mcpVanessaUi = [bool](Get-StateValue -State $mcp -Name "vanessaUi" -Default $false)
        })
    }
    return @($result.ToArray())
}

function Get-AuxiliaryContour {
    param([string]$Name = $AuxiliaryContourName)
    if ([string]::IsNullOrWhiteSpace($Name)) {
        throw "ITL_AUXILIARY_CONTOUR_REQUIRED: pass -AuxiliaryContourName."
    }
    $id = ConvertTo-AuxiliaryContourId -Name $Name
    $match = @(Get-AuxiliaryContourDefinitions | Where-Object { $_.name -ceq $id })
    if ($match.Count -ne 1) {
        throw "ITL_AUXILIARY_CONTOUR_NOT_FOUND: '$id'."
    }
    return $match[0]
}

function Get-AuxiliaryContourStatePath {
    param([Parameter(Mandatory = $true)][object]$Contour)
    $branchKey = Get-AuxiliaryContourBranchKey
    return (Join-Path $script:ProjectRoot ".agent-1c\auxiliary-contours\$branchKey\$($Contour.name).json")
}

function Read-AuxiliaryContourState {
    param([Parameter(Mandatory = $true)][object]$Contour)
    $path = Get-AuxiliaryContourStatePath -Contour $Contour
    if (-not (Test-Path -LiteralPath $path -PathType Leaf -ErrorAction SilentlyContinue)) { return $null }
    try { return (Read-Utf8Text -Path $path | ConvertFrom-Json) }
    catch { throw "ITL_AUXILIARY_STATE_INVALID: contour='$($Contour.name)' path='$path' error='$($_.Exception.Message)'" }
}

function Save-AuxiliaryContourState {
    param(
        [Parameter(Mandatory = $true)][object]$Contour,
        [Parameter(Mandatory = $true)][hashtable]$Updates,
        [switch]$Replace
    )
    $state = [ordered]@{}
    if (-not $Replace) {
        $existing = Read-AuxiliaryContourState -Contour $Contour
        if ($existing) { foreach ($property in $existing.PSObject.Properties) { $state[$property.Name] = $property.Value } }
    }
    foreach ($key in $Updates.Keys) { $state[$key] = $Updates[$key] }
    $state["schemaVersion"] = 1
    $state["contour"] = $Contour.name
    $state["branch"] = (Get-GitOutput @("branch", "--show-current")).Trim()
    $state["updatedAt"] = (Get-Date).ToString("o")
    $path = Get-AuxiliaryContourStatePath -Contour $Contour
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
    Write-Utf8TextAtomic -Path $path -Value (($state | ConvertTo-Json -Depth 12) + [Environment]::NewLine)
    return (Read-Utf8Text -Path $path | ConvertFrom-Json)
}

function Get-AuxiliaryContourConnection {
    param([Parameter(Mandatory = $true)][object]$Contour)
    if ($Contour.baseMode -eq "managed-file") {
        $branchKey = Get-AuxiliaryContourBranchKey
        $kind = "file"
        $path = Join-Path $script:ProjectRoot ".agent-1c\infobases\auxiliary\$branchKey\$($Contour.name)"
        $user = ""
        $password = ""
    } else {
        $prefix = "ITL_AUX_$($Contour.connectionRef)_"
        $kind = ([string](Get-EnvValue -Name ($prefix + "INFOBASE_KIND") -Default "")).Trim().ToLowerInvariant()
        $path = [string](Get-EnvValue -Name ($prefix + "INFOBASE_PATH") -Default "")
        $user = [string](Get-EnvValue -Name ($prefix + "USER") -Default "")
        $password = [string](Get-EnvValue -Name ($prefix + "PASSWORD") -Default "")
        if ($kind -notin @("file", "server") -or [string]::IsNullOrWhiteSpace($path)) {
            throw "ITL_AUXILIARY_CONNECTION_MISSING: contour='$($Contour.name)' requires ${prefix}INFOBASE_KIND and ${prefix}INFOBASE_PATH in .dev.env."
        }
        if ($kind -eq "file") { $path = Resolve-Agent1cFullPath -Path $path }
    }
    $identityText = "$kind`0$path"
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $identityHash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($identityText)))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
    return [pscustomobject][ordered]@{ kind = $kind; path = $path; user = $user; password = $password; identityHash = $identityHash }
}

function Assert-AuxiliaryContourMutationAllowed {
    param([Parameter(Mandatory = $true)][object]$Contour, [string]$Operation)
    if ($Contour.baseMode -eq "attached-readonly") {
        throw "ITL_AUXILIARY_READONLY_MUTATION_FORBIDDEN: contour='$($Contour.name)' operation='$Operation'."
    }
}

function Ensure-AuxiliaryManagedInfoBase {
    param([Parameter(Mandatory = $true)][object]$Contour, [Parameter(Mandatory = $true)][object]$Connection)
    if ($Contour.baseMode -ne "managed-file") { Assert-InfoBaseAvailable -Kind $Connection.kind -Path $Connection.path -SettingName "auxiliary contour '$($Contour.name)'"; return }
    $databasePath = Join-Path $Connection.path "1Cv8.1CD"
    if (Test-Path -LiteralPath $databasePath -PathType Leaf -ErrorAction SilentlyContinue) { return }
    if (Test-Path -LiteralPath $Connection.path -PathType Container -ErrorAction SilentlyContinue) {
        if (@(Get-ChildItem -LiteralPath $Connection.path -Force -ErrorAction Stop).Count -gt 0) {
            throw "ITL_AUXILIARY_MANAGED_INFOBASE_INVALID: '$($Connection.path)' is non-empty without 1Cv8.1CD."
        }
    } else { New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Connection.path) | Out-Null }
    $platformPath = Get-PlatformPath
    $logsPath = Resolve-ProjectPath (Get-ConfigValue -Path "logsPath" -Default "logs/1c")
    New-Item -ItemType Directory -Force -Path $logsPath | Out-Null
    $logPath = New-TimestampedFilePath -Directory $logsPath -Prefix "1c-aux-$($Contour.name)-create-" -Extension ".log"
    $arguments = @("CREATEINFOBASE", (New-FileInfoBaseConnectionString -Path $Connection.path), "/DisableStartupDialogs", "/Out", $logPath)
    $nativeArguments = @($arguments)
    $result = Invoke-WithOneCSessionAdmissionContext -InfoBaseKind "file" -InfoBasePath $Connection.path -RequiredSessions 1 -Purpose "auxiliary-infobase-create" -ScriptBlock {
        Invoke-NativeProcessAndWaitResult -FilePath $platformPath -Arguments $nativeArguments -OneCCreateInfoBaseSyntax -TimeoutSeconds 300
    }
    if ($result.timedOut -or $result.exitCode -ne 0 -or -not (Test-Path -LiteralPath $databasePath -PathType Leaf)) {
        throw "ITL_AUXILIARY_INFOBASE_CREATE_FAILED: contour='$($Contour.name)' exitCode=$($result.exitCode) timedOut=$($result.timedOut) log='$logPath'."
    }
}

function Stop-AuxiliaryContourRuntimeBeforeMutation {
    param([Parameter(Mandatory = $true)][object]$Contour, [Parameter(Mandatory = $true)][object]$Connection, [string]$Reason)
    Set-RunStage -Stage "auxiliary.stop-runtime" -Detail "Stopping exact auxiliary infobase runtime before $Reason."
    Stop-ItlOnDemandBackends -InfoBasePath $Connection.path -Strict
    Stop-OneCInfoBaseSessionProcesses -InfoBaseKind $Connection.kind -InfoBasePath $Connection.path -Reason $Reason | Out-Null
    $remaining = @(Get-OneCInfoBaseSessionProcesses -InfoBaseKind $Connection.kind -InfoBasePath $Connection.path)
    if ($remaining.Count -gt 0) { throw "ITL_AUXILIARY_RUNTIME_DRAIN_FAILED: contour='$($Contour.name)' remaining=$($remaining.Count)." }
}

function Get-AuxiliaryContourFingerprint {
    param([Parameter(Mandatory = $true)][object]$Contour)
    $configuration = Get-ConfigSourceFingerprint -ExportPath $Contour.configurationPath
    $extensions = @()
    foreach ($extension in @($Contour.extensions)) {
        $source = Get-ConfigSourceFingerprint -ExportPath $extension.path
        $extensions += [pscustomobject]@{ name = $extension.name; path = $extension.path; fingerprint = $source.fingerprint }
    }
    $payload = @($configuration.fingerprint) + @($extensions | ForEach-Object { "$($_.name)`0$($_.fingerprint)" })
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $combined = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($payload -join "`n"))))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
    return [pscustomobject]@{ combined = "v1|aux-source-sha256|$combined"; configuration = $configuration; extensions = @($extensions) }
}

function Assert-AuxiliaryContourReady {
    param([Parameter(Mandatory = $true)][object]$Contour, [string]$Operation)
    $connection = Get-AuxiliaryContourConnection -Contour $Contour
    $state = Read-AuxiliaryContourState -Contour $Contour
    $source = Get-AuxiliaryContourFingerprint -Contour $Contour
    if (-not $state -or [string](Get-StateValue -State $state -Name "readinessStatus" -Default "") -ne "ready" -or
        [string](Get-StateValue -State $state -Name "connectionIdentityHash" -Default "") -cne $connection.identityHash -or
        [string](Get-StateValue -State $state -Name "sourceFingerprint" -Default "") -cne $source.combined) {
        throw "ITL_AUXILIARY_INFOBASE_NOT_READY: contour='$($Contour.name)' operation='$Operation' requiredAction=update-auxiliary-contour."
    }
    return [pscustomobject]@{ contour = $Contour; connection = $connection; state = $state; source = $source }
}

function Sync-AuxiliaryContourMcpClientConfig {
    param([Parameter(Mandatory = $true)][object]$Contour)
    if (-not $Contour.mcpRoctup -and -not $Contour.mcpVanessaUi) { return }
    try { Write-ItlOnDemandMcpClientConfig -Client (Get-ItlActiveClient) | Out-Null }
    catch { Write-Warning "Auxiliary contour is ready, but MCP client reconciliation is incomplete: $($_.Exception.Message)" }
}

function Update-AuxiliaryContour {
    $contour = Get-AuxiliaryContour
    Assert-AuxiliaryContourMutationAllowed -Contour $contour -Operation "update"
    $connection = Get-AuxiliaryContourConnection -Contour $contour
    Ensure-AuxiliaryManagedInfoBase -Contour $contour -Connection $connection
    $source = Get-AuxiliaryContourFingerprint -Contour $contour
    $state = Read-AuxiliaryContourState -Contour $contour
    if ($state -and [string](Get-StateValue -State $state -Name "readinessStatus" -Default "") -eq "ready" -and
        [string](Get-StateValue -State $state -Name "connectionIdentityHash" -Default "") -ceq $connection.identityHash -and
        [string](Get-StateValue -State $state -Name "sourceFingerprint" -Default "") -ceq $source.combined) {
        Sync-AuxiliaryContourMcpClientConfig -Contour $contour
        Write-Host "Auxiliary contour '$($contour.name)' is already current."
        return
    }
    Save-AuxiliaryContourState -Contour $contour -Updates @{
        readinessStatus = "pending"; connectionIdentityHash = $connection.identityHash; sourceFingerprint = ""
        lastVerificationStatus = "stale"; lastVerificationFingerprint = ""; lastError = ""
    } | Out-Null
    Stop-AuxiliaryContourRuntimeBeforeMutation -Contour $contour -Connection $connection -Reason "auxiliary configuration load"
    try {
        $configLoad = Invoke-ConfigLoadWithFallback -InfoBasePath $connection.path -InfoBaseKind $connection.kind -State $null -AbsoluteExportPath $contour.absoluteConfigurationPath -ListFilePath "" -FileCount $source.configuration.fileCount -Mode "Full" -User $connection.user -Password $connection.password
        foreach ($extension in @($contour.extensions)) {
            $absoluteExtensionPath = Assert-ExportPathInsideProject -ExportPath $extension.path
            $extensionSource = Get-ConfigSourceFingerprint -ExportPath $extension.path
            Invoke-ConfigLoadWithFallback -InfoBasePath $connection.path -InfoBaseKind $connection.kind -State $null -AbsoluteExportPath $absoluteExtensionPath -ListFilePath "" -FileCount $extensionSource.fileCount -ExtensionName $extension.name -Mode "Full" -User $connection.user -Password $connection.password | Out-Null
        }
        $epfPath = Ensure-DevBranchAutoUpdateEpfs
        $normalization = Invoke-Enterprise -InfoBasePath $connection.path -InfoBaseKind $connection.kind -User $connection.user -Password $connection.password -EnterpriseArgs @("/Execute", $epfPath) -TimeoutSeconds (Get-DevBranchAutoUpdateTimeoutSeconds)
        Save-AuxiliaryContourState -Contour $contour -Updates @{
            readinessStatus = "ready"; connectionIdentityHash = $connection.identityHash; sourceFingerprint = $source.combined
            configurationFingerprint = $source.configuration.fingerprint; extensionFingerprints = @($source.extensions)
            lastLoadStatus = $configLoad.configLoadStatus; lastLoadMode = $configLoad.loadModeUsed
            enterpriseNormalizationStatus = "passed"; enterpriseNormalizedAt = (Get-Date).ToString("o")
            lastLogPath = $normalization; lastUpdatedAt = (Get-Date).ToString("o"); lastError = ""
        } | Out-Null
    } catch {
        Save-AuxiliaryContourState -Contour $contour -Updates @{ readinessStatus = "failed"; enterpriseNormalizationStatus = "failed"; lastError = $_.Exception.Message; lastLogPath = $script:LastLogPath } | Out-Null
        throw
    }
    Sync-AuxiliaryContourMcpClientConfig -Contour $contour
    Write-Host "Auxiliary contour updated: $($contour.name) -> $($connection.kind):$($connection.path)"
}

function Invoke-AuxiliaryConfigurationDump {
    param([object]$Contour, [object]$Connection)
    if ($Contour.sourceMode -ne "read-write") { throw "ITL_AUXILIARY_DUMP_LOAD_ONLY_FORBIDDEN: contour='$($Contour.name)'." }
    $target = $Contour.absoluteConfigurationPath
    $transaction = Initialize-Agent1cProjectTransactionSlot -Kind "c" -Target $target
    $targetExisted = Test-Path -LiteralPath $target -PathType Container -ErrorAction SilentlyContinue
    $targetMoved = $false; $installed = $false
    try {
        New-Item -ItemType Directory -Force -Path $transaction.stage | Out-Null
        Invoke-Designer -InfoBasePath $Connection.path -InfoBaseKind $Connection.kind -User $Connection.user -Password $Connection.password -DesignerArgs @("/DumpConfigToFiles", $transaction.stage, "-Format", "Hierarchical") | Out-Null
        $dumpState = Get-DesignerDumpArtifactState -Path $transaction.stage
        if (-not $dumpState.ready) { throw "Auxiliary dump did not create complete Configuration.xml and ConfigDumpInfo.xml." }
        if ($targetExisted) { Move-Item -LiteralPath $target -Destination $transaction.backup; $targetMoved = $true }
        Move-Item -LiteralPath $transaction.stage -Destination $target; $installed = $true
        Complete-Agent1cProjectTransactionSlot -Paths $transaction
    } catch {
        $original = $_.Exception.Message
        if ($installed -and (Test-Path -LiteralPath $target)) { Remove-Item -LiteralPath $target -Recurse -Force }
        if ($targetMoved -and (Test-Path -LiteralPath $transaction.backup)) { Move-Item -LiteralPath $transaction.backup -Destination $target }
        throw "ITL_AUXILIARY_DUMP_FAILED: $original staging='$($transaction.slot)'"
    }
}

function Dump-AuxiliaryContour {
    $contour = Get-AuxiliaryContour
    Assert-AuxiliaryContourMutationAllowed -Contour $contour -Operation "dump"
    if ($contour.sourceMode -ne "read-write") { throw "ITL_AUXILIARY_DUMP_LOAD_ONLY_FORBIDDEN: contour='$($contour.name)'." }
    $connection = Get-AuxiliaryContourConnection -Contour $contour
    Stop-AuxiliaryContourRuntimeBeforeMutation -Contour $contour -Connection $connection -Reason "auxiliary configuration dump"
    Invoke-AuxiliaryConfigurationDump -Contour $contour -Connection $connection
    $source = Get-AuxiliaryContourFingerprint -Contour $contour
    Save-AuxiliaryContourState -Contour $contour -Updates @{ readinessStatus = "ready"; connectionIdentityHash = $connection.identityHash; sourceFingerprint = $source.combined; lastDumpAt = (Get-Date).ToString("o"); lastVerificationStatus = "stale"; lastVerificationFingerprint = ""; lastLogPath = $script:LastLogPath } | Out-Null
    Write-Host "Auxiliary configuration dumped transactionally: $($contour.configurationPath)"
}

function Check-AuxiliaryContour {
    $contour = Get-AuxiliaryContour
    if ($contour.baseMode -ne "attached-readonly") { Update-AuxiliaryContour }
    $ready = Assert-AuxiliaryContourReady -Contour $contour -Operation "check"
    Invoke-AuxiliaryContourVanessaTests -ReadyContext $ready -TestSet $AuxiliaryTestSet
}

function Get-AuxiliaryVerificationFingerprint {
    param([Parameter(Mandatory = $true)][object]$ReadyContext, [Parameter(Mandatory = $true)][string[]]$FeaturePaths)
    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add([string]$ReadyContext.source.combined)
    foreach ($path in @($FeaturePaths)) {
        $featureSource = Get-ConfigSourceFingerprint -ExportPath $path
        $parts.Add("$path`0$($featureSource.fingerprint)")
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($parts.ToArray() -join "`n"))))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
    return "v1|aux-verification-sha256|$hash"
}

function Update-ActiveVanessaVerificationState {
    param([Parameter(Mandatory = $true)][object]$State, [Parameter(Mandatory = $true)][hashtable]$Updates)
    if (-not $script:ActiveAuxiliaryVanessaContext) {
        Update-DevBranchState -State $State -Updates $Updates
        return
    }
    $copy = @{}
    foreach ($key in $Updates.Keys) { $copy[$key] = $Updates[$key] }
    $copy["lastAuxiliarySuite"] = [string]$script:ActiveAuxiliaryVanessaContext.suite
    $copy["lastAuxiliarySuiteFingerprint"] = [string]$script:ActiveAuxiliaryVanessaContext.verificationFingerprint
    Save-AuxiliaryContourState -Contour $script:ActiveAuxiliaryVanessaContext.contour -Updates $copy | Out-Null
}

function Export-AuxiliaryContourResult {
    $contour = Get-AuxiliaryContour
    if ($contour.baseMode -eq "attached-readonly") {
        $connection = Get-AuxiliaryContourConnection -Contour $contour
        Assert-InfoBaseAvailable -Kind $connection.kind -Path $connection.path -SettingName "auxiliary contour '$($contour.name)'"
        $ready = [pscustomobject]@{ contour = $contour; connection = $connection; state = Read-AuxiliaryContourState -Contour $contour; source = Get-AuxiliaryContourFingerprint -Contour $contour }
    } else {
        $ready = Assert-AuxiliaryContourReady -Contour $contour -Operation "CF export"
    }
    $verificationStatus = [string](Get-StateValue -State $ready.state -Name "lastVerificationStatus" -Default "")
    $verificationFingerprint = [string](Get-StateValue -State $ready.state -Name "lastVerificationFingerprint" -Default "")
    $requiredFeaturePaths = @()
    if ($contour.testsIncludePrimary) { $requiredFeaturePaths += Get-VanessaFeaturesPath }
    if ($contour.testsPath) { $requiredFeaturePaths += $contour.testsPath }
    $currentVerificationFingerprint = if ($requiredFeaturePaths.Count -gt 0) { Get-AuxiliaryVerificationFingerprint -ReadyContext $ready -FeaturePaths $requiredFeaturePaths } else { "" }
    if (($verificationStatus -ne "passed" -or -not $currentVerificationFingerprint -or $verificationFingerprint -cne $currentVerificationFingerprint) -and -not $AllowUnverifiedResult) {
        throw "ITL_AUXILIARY_RESULT_UNVERIFIED: contour='$($contour.name)' requiredAction=check-auxiliary-contour or pass -AllowUnverifiedResult."
    }
    $artifactDir = Resolve-ProjectPath ((Get-ConfigValue -Path "artifactsPath" -Default "build/result") + "/auxiliary/$($contour.name)")
    New-Item -ItemType Directory -Force -Path $artifactDir | Out-Null
    $resultPath = Join-Path $artifactDir ("$($contour.name)-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".cf")
    Invoke-Designer -InfoBasePath $ready.connection.path -InfoBaseKind $ready.connection.kind -User $ready.connection.user -Password $ready.connection.password -DesignerArgs @("/DumpCfg", $resultPath) | Out-Null
    $manifestPath = $resultPath + ".manifest.json"
    $manifest = [ordered]@{ schemaVersion = 1; kind = "auxiliary-cf"; contour = $contour.name; resultPath = $resultPath; sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $resultPath).Hash.ToLowerInvariant(); sourceFingerprint = $ready.source.combined; connectionIdentityHash = $ready.connection.identityHash; verificationStatus = $verificationStatus; verificationFingerprint = $verificationFingerprint; currentVerificationFingerprint = $currentVerificationFingerprint; unverifiedOverride = [bool]$AllowUnverifiedResult; commit = Get-CurrentCommit; createdAt = (Get-Date).ToString("o") }
    Write-Utf8TextAtomic -Path $manifestPath -Value (($manifest | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
    Save-AuxiliaryContourState -Contour $contour -Updates @{ lastResultPath = $resultPath; lastResultManifestPath = $manifestPath; lastResultAt = (Get-Date).ToString("o"); lastLogPath = $script:LastLogPath } | Out-Null
    Set-RunResultArtifacts -ResultPath $resultPath -ResultManifestPath $manifestPath
    Write-Host "Auxiliary CF saved: $resultPath"
    Write-Host "Auxiliary CF manifest: $manifestPath"
}

function Reset-AuxiliaryContour {
    $contour = Get-AuxiliaryContour
    if ($contour.baseMode -ne "managed-file") { throw "ITL_AUXILIARY_RESET_MANAGED_ONLY: contour='$($contour.name)'." }
    $connection = Get-AuxiliaryContourConnection -Contour $contour
    Stop-AuxiliaryContourRuntimeBeforeMutation -Contour $contour -Connection $connection -Reason "auxiliary contour reset"
    $expectedRoot = Resolve-ProjectPath (".agent-1c/infobases/auxiliary/" + (Get-AuxiliaryContourBranchKey))
    $resolved = Resolve-Agent1cFullPath -Path $connection.path
    $prefix = $expectedRoot.TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw "ITL_AUXILIARY_RESET_SCOPE_INVALID: '$resolved'." }
    $archivePath = ""
    if (Test-Path -LiteralPath $resolved -PathType Container) {
        $archiveRoot = Resolve-ProjectPath (".agent-1c/auxiliary-archives/" + (Get-AuxiliaryContourBranchKey))
        New-Item -ItemType Directory -Force -Path $archiveRoot | Out-Null
        $archivePath = Join-Path $archiveRoot ("$($contour.name)-" + (Get-Date -Format "yyyyMMdd-HHmmss-fff"))
        Move-Item -LiteralPath $resolved -Destination $archivePath
    }
    $statePath = Get-AuxiliaryContourStatePath -Contour $contour
    if (Test-Path -LiteralPath $statePath -PathType Leaf) { Remove-Item -LiteralPath $statePath -Force }
    Write-Host "Managed auxiliary contour reset: $($contour.name). Archived infobase: $(if ($archivePath) { $archivePath } else { '<base was absent>' }). Run update-auxiliary-contour to recreate it."
}

function Show-AuxiliaryContoursStatus {
    $definitions = @(Get-AuxiliaryContourDefinitions)
    if ($definitions.Count -eq 0) { Write-Host "Auxiliary contours: not configured."; return }
    Write-Host "Auxiliary contours: $($definitions.Count)"
    foreach ($contour in $definitions) {
        $state = Read-AuxiliaryContourState -Contour $contour
        $status = [string](Get-StateValue -State $state -Name "readinessStatus" -Default "not-updated")
        $verification = [string](Get-StateValue -State $state -Name "lastVerificationStatus" -Default "not-run")
        $connectionText = "unresolved"
        try { $connection = Get-AuxiliaryContourConnection -Contour $contour; $connectionText = "$($connection.kind):$($connection.path)" }
        catch { $connectionText = "WARN: $($_.Exception.Message)" }
        Write-Host "  $($contour.name): base=$($contour.baseMode) source=$($contour.sourceMode) ready=$status tests=$verification mcp(roctup=$($contour.mcpRoctup),vanessa=$($contour.mcpVanessaUi))"
        Write-Host "    connection=$connectionText source=$($contour.configurationPath)"
    }
}

function Invoke-AuxiliaryContourVanessaTests {
    param([Parameter(Mandatory = $true)][object]$ReadyContext, [string]$TestSet = "")
    $normalizedSet = if ([string]::IsNullOrWhiteSpace($TestSet)) { "all" } else { $TestSet.Trim().ToLowerInvariant() }
    $suites = [System.Collections.Generic.List[object]]::new()
    $primaryPath = Get-VanessaFeaturesPath
    if ($ReadyContext.contour.testsIncludePrimary -and $normalizedSet -in @("primary", "all")) {
        $suites.Add([pscustomobject]@{ name = "primary"; path = $primaryPath })
    }
    if ($ReadyContext.contour.testsPath -and $normalizedSet -in @("contour", "all")) {
        $suites.Add([pscustomobject]@{ name = "contour"; path = $ReadyContext.contour.testsPath })
    }
    if ($suites.Count -eq 0) {
        throw "ITL_AUXILIARY_TEST_SET_EMPTY: contour='$($ReadyContext.contour.name)' set='$normalizedSet'."
    }
    $requiredSuites = @()
    if ($ReadyContext.contour.testsIncludePrimary) { $requiredSuites += "primary" }
    if ($ReadyContext.contour.testsPath) { $requiredSuites += "contour" }
    $selectedSuiteNames = @($suites.ToArray() | ForEach-Object { [string]$_.name })
    $canonical = (($requiredSuites.Count -eq $selectedSuiteNames.Count) -and @($requiredSuites | Where-Object { $selectedSuiteNames -notcontains $_ }).Count -eq 0)
    $featurePaths = @($suites.ToArray() | ForEach-Object { [string]$_.path })
    $verificationFingerprint = Get-AuxiliaryVerificationFingerprint -ReadyContext $ReadyContext -FeaturePaths $featurePaths
    $previousContext = $script:ActiveAuxiliaryVanessaContext
    $previousSkipEventLog = $script:ItlSkipEventLogForVerification
    try {
        $script:ItlSkipEventLogForVerification = $true
        foreach ($suite in $suites.ToArray()) {
            $reportsPath = (Get-ConfigValue -Path "testResultsPath" -Default "build/test-results/vanessa") + "/auxiliary/$($ReadyContext.contour.name)/$($suite.name)"
            $script:ActiveAuxiliaryVanessaContext = [pscustomobject]@{
                contour = $ReadyContext.contour
                suite = $suite.name
                featuresPath = $suite.path
                reportsPath = $reportsPath
                verificationFingerprint = $verificationFingerprint
            }
            Run-DevBranchTests
        }
    } catch {
        Save-AuxiliaryContourState -Contour $ReadyContext.contour -Updates @{ lastVerificationStatus = "failed"; lastVerificationFingerprint = $verificationFingerprint; lastVerificationError = $_.Exception.Message; lastVerificationAt = (Get-Date).ToString("o") } | Out-Null
        throw
    } finally {
        $script:ActiveAuxiliaryVanessaContext = $previousContext
        $script:ItlSkipEventLogForVerification = $previousSkipEventLog
    }
    $proofStatus = if ($canonical) { "passed" } else { "diagnostic" }
    Save-AuxiliaryContourState -Contour $ReadyContext.contour -Updates @{ lastVerificationStatus = $proofStatus; lastVerificationFingerprint = $(if ($canonical) { $verificationFingerprint } else { "" }); lastVerificationCompositeFingerprint = $verificationFingerprint; lastVerificationSuites = $selectedSuiteNames; lastVerificationRequiredSuites = $requiredSuites; lastVerificationAt = (Get-Date).ToString("o"); lastVerificationError = "" } | Out-Null
    Write-Host "Auxiliary Vanessa verification finished: contour=$($ReadyContext.contour.name) suites=$($selectedSuiteNames -join ',') proof=$proofStatus."
}
