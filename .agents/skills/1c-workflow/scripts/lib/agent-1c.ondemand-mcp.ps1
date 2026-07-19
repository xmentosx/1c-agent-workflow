function Get-ItlOnDemandMcpAssetRoot {
    return (Join-Path (Split-Path -Parent $script:Agent1cScriptRoot) "assets\ondemand-mcp")
}

function Get-ItlOnDemandMcpCompatibility {
    $path = Join-Path (Get-ItlOnDemandMcpAssetRoot) "compatibility.json"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "ITL on-demand MCP compatibility manifest was not found: $path"
    }
    return (Read-Utf8Text -Path $path | ConvertFrom-Json)
}

function Get-ItlOnDemandCatalogCanonicalSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    $text = [System.IO.File]::ReadAllText($Path, (New-Object System.Text.UTF8Encoding $false))
    $normalized = $text.Replace("`r`n", "`n").Replace("`r", "`n")
    $bytes = (New-Object System.Text.UTF8Encoding $false).GetBytes($normalized)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Get-ItlOnDemandMcpFamilyDefinition {
    param([ValidateSet("roctup", "vanessa-ui")][string]$Family)

    $manifest = Get-ItlOnDemandMcpCompatibility
    $definition = Get-ConfigValueFromObject -Object $manifest -Path "families.$Family" -Default $null
    if ($null -eq $definition) {
        throw "ITL on-demand MCP family '$Family' is absent from compatibility.json."
    }
    $catalogPath = Join-Path (Get-ItlOnDemandMcpAssetRoot) ([string]$definition.catalog)
    if (-not (Test-Path -LiteralPath $catalogPath -PathType Leaf)) {
        throw "ITL on-demand MCP catalog was not found: $catalogPath"
    }
    $actualHash = Get-ItlOnDemandCatalogCanonicalSha256 -Path $catalogPath
    if ($actualHash -cne ([string]$definition.catalogSha256).ToLowerInvariant()) {
        throw "ITL_ONDEMAND_CATALOG_HASH_MISMATCH family='$Family' expected='$($definition.catalogSha256)' actual='$actualHash' path='$catalogPath'"
    }
    return [pscustomobject]@{
        family = $Family
        facadeVersion = [string]$manifest.facadeVersion
        serverName = [string]$definition.serverName
        backendVersions = $definition.backendVersions
        catalogPath = [System.IO.Path]::GetFullPath($catalogPath)
        catalogSha256 = $actualHash
    }
}

function Get-ItlOnDemandMcpInstallRoot {
    $base = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if ([string]::IsNullOrWhiteSpace($base)) {
        throw "LOCALAPPDATA is required for ITL on-demand MCP."
    }
    return (Join-Path $base "ITL\MCP\ondemand")
}

function Get-ItlOnDemandMcpExecutablePath {
    param([switch]$AllowMissing)

    $override = [Environment]::GetEnvironmentVariable("ITL_ONDEMAND_MCP_EXE")
    if (-not [string]::IsNullOrWhiteSpace($override)) {
        $resolved = Resolve-Agent1cFullPath -Path $override
        if ($AllowMissing -or (Test-Path -LiteralPath $resolved -PathType Leaf)) { return $resolved }
    }
    $manifest = Get-ItlOnDemandMcpCompatibility
    $path = Join-Path (Join-Path (Get-ItlOnDemandMcpInstallRoot) ([string]$manifest.facadeVersion)) "itl-ondemand-mcp-windows-amd64.exe"
    if ($AllowMissing -or (Test-Path -LiteralPath $path -PathType Leaf)) { return $path }
    throw "ITL on-demand MCP executable is not installed: $path. Run update-workflow after the matching workflow release asset is published."
}

function Install-ItlOnDemandMcp {
    param([switch]$ForceDownload)

    if (-not [Environment]::Is64BitOperatingSystem -or -not [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) {
        throw "ITL_ONDEMAND_UNSUPPORTED_PLATFORM: v1 supports Windows x64 only."
    }
    $entry = Get-DependencyLockEntry -Name "itlOndemandMcp"
    $version = [string](Get-ConfigValueFromObject -Object $entry -Path "version" -Default "")
    $url = [string](Get-ConfigValueFromObject -Object $entry -Path "url" -Default "")
    $sha256 = [string](Get-ConfigValueFromObject -Object $entry -Path "sha256" -Default "")
    $assetName = [string](Get-ConfigValueFromObject -Object $entry -Path "assetName" -Default "itl-ondemand-mcp-windows-amd64.exe")
    $manifest = Get-ItlOnDemandMcpCompatibility
    if (-not $version) { $version = [string]$manifest.facadeVersion }
    $targetDirectory = Join-Path (Get-ItlOnDemandMcpInstallRoot) $version
    $targetPath = Join-Path $targetDirectory $assetName

    # Source-repository development may use a locally built, SHA-verified artifact.
    $sourceRepositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $script:Agent1cScriptRoot "..\..\..\.."))
    $sourceBuild = Join-Path $sourceRepositoryRoot "tools\itl-ondemand-mcp\build\itl-ondemand-mcp-windows-amd64.exe"
    if (-not (Test-Path -LiteralPath (Join-Path $sourceRepositoryRoot ".git"))) { $sourceBuild = "" }
    if ((Test-Path -LiteralPath $sourceBuild -PathType Leaf) -and (-not $url -or $ForceDownload -eq $false)) {
        New-Item -ItemType Directory -Force -Path $targetDirectory | Out-Null
        Copy-Item -LiteralPath $sourceBuild -Destination $targetPath -Force
    } else {
        $needsDownload = $ForceDownload -or -not (Test-Path -LiteralPath $targetPath -PathType Leaf)
        if (-not $needsDownload -and $sha256) {
            $cachedHash = (Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash.ToLowerInvariant()
            $needsDownload = $cachedHash -cne $sha256.ToLowerInvariant()
        }
        if ($needsDownload) {
            if (-not $url -or -not $sha256) {
                throw "itlOndemandMcp.url and sha256 are required in .agent-1c/dependency-lock.json for installed projects."
            }
            New-Item -ItemType Directory -Force -Path $targetDirectory | Out-Null
            $temporaryPath = "$targetPath.download"
            try {
                Invoke-WebRequest -Uri $url -UseBasicParsing -OutFile $temporaryPath
                Move-Item -LiteralPath $temporaryPath -Destination $targetPath -Force
            } finally {
                Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
            }
        }
    }
    $actual = (Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($sha256 -and $actual -cne $sha256.ToLowerInvariant()) {
        throw "ITL on-demand MCP SHA256 mismatch. Expected '$sha256', actual '$actual'."
    }
    Write-Host "ITL on-demand MCP executable: $targetPath"
    Write-Host "ITL on-demand MCP SHA256: $actual"
    return [pscustomobject]@{ path = $targetPath; version = $version; sha256 = $actual }
}

function Get-ItlOnDemandMcpEndpointDescriptors {
    $executable = Get-ItlOnDemandMcpExecutablePath
    $helper = Resolve-Agent1cFullPath -Path $script:Agent1cScriptPath
    $root = Resolve-Agent1cFullPath -Path $script:ProjectRoot
    $endpoints = @()
    foreach ($family in @("roctup", "vanessa-ui")) {
        $definition = Get-ItlOnDemandMcpFamilyDefinition -Family $family
        $endpoints += [pscustomobject]@{
            name = $definition.serverName
            transport = "stdio"
            command = $executable
            args = @("serve", "--family", $family, "--project-root", $root, "--catalog", $definition.catalogPath, "--helper", $helper, "--idle-timeout", "10m")
            startupTimeoutSeconds = 20
            toolTimeoutSeconds = 600
        }
    }
    return @($endpoints)
}

function Write-ItlOnDemandMcpClientConfig {
    param([string]$Client = "")
    $executable = Get-ItlOnDemandMcpExecutablePath -AllowMissing
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
        Write-Warning "ITL on-demand MCP executable is missing; client facade entries were not written: $executable"
        return ""
    }
    $endpoints = Get-ItlOnDemandMcpEndpointDescriptors
    return (Write-ItlClientMcpEndpoints -Endpoints $endpoints -Owner "ondemand-facade" -Client $Client)
}

function Get-ItlOnDemandRuntimeRoot {
    return (Join-Path $script:ProjectRoot ".agent-1c\mcp\ondemand")
}

function Get-ItlOnDemandRuntimePath {
    param([string]$Family, [string]$InstanceId)
    return (Join-Path (Join-Path (Get-ItlOnDemandRuntimeRoot) $Family) "$InstanceId.json")
}

function Get-ItlOnDemandPortFamily {
    param([string]$Family)
    return $(if ($Family -eq "roctup") { "roctup-mcp" } else { "vanessa-mcp" })
}

function Get-ItlOnDemandPortKey {
    param([string]$Family, [object]$State, [string]$InstanceId)
    $base = Get-ItlBranchManagedPortKey -Family (Get-ItlOnDemandPortFamily -Family $Family) -State $State
    return "$base|instance=$InstanceId"
}

function Read-ItlOnDemandRuntimeState {
    param([string]$Family, [string]$InstanceId)
    $path = Get-ItlOnDemandRuntimePath -Family $Family -InstanceId $InstanceId
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try { return (Read-Utf8Text -Path $path | ConvertFrom-Json) } catch { return $null }
}

function Write-ItlOnDemandRuntimeState {
    param([object]$RuntimeState)
    $path = Get-ItlOnDemandRuntimePath -Family ([string]$RuntimeState.family) -InstanceId ([string]$RuntimeState.instanceId)
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
    $temporary = "$path.tmp-$PID"
    Write-Utf8Text -Path $temporary -Value (($RuntimeState | ConvertTo-Json -Depth 20) + [Environment]::NewLine)
    Move-Item -LiteralPath $temporary -Destination $path -Force
    return $path
}

function Test-ItlOnDemandOwnedProcess {
    param([object]$RuntimeState)
    $processId = ConvertTo-IntOrDefault -Value $RuntimeState.pid -Default 0
    if ($processId -le 0) { return $false }
    $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
    if ($null -eq $process) { return $false }
    try {
        $expected = [DateTimeOffset]::Parse([string]$RuntimeState.processStartTime).UtcDateTime
        if ([Math]::Abs(($process.StartTime.ToUniversalTime() - $expected).TotalSeconds) -ge 2) { return $false }
        $native = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$processId" -ErrorAction Stop
        $expectedExecutable = [string](Get-ConfigValueFromObject -Object $RuntimeState -Path "executablePath" -Default "")
        if (-not $expectedExecutable -or -not [string]::Equals([string]$native.ExecutablePath, $expectedExecutable, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
        $commandLine = [string]$native.CommandLine
        foreach ($marker in @($RuntimeState.ownershipMarkers)) {
            if (-not $marker -or $commandLine.IndexOf([string]$marker, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { return $false }
        }
        return $true
    } catch {
        return $false
    }
}

function Stop-ItlOnDemandBackendInstance {
    param([string]$Family, [string]$InstanceId)
    $runtimeState = Read-ItlOnDemandRuntimeState -Family $Family -InstanceId $InstanceId
    if ($null -eq $runtimeState) { return [pscustomobject]@{ status = "stopped"; family = $Family; instanceId = $InstanceId } }
    if (Test-ItlOnDemandOwnedProcess -RuntimeState $runtimeState) {
        Stop-Process -Id ([int]$runtimeState.pid) -Force -ErrorAction Stop
        Start-Sleep -Milliseconds 300
    }
    $portFamily = [string](Get-ConfigValueFromObject -Object $runtimeState -Path "portFamily" -Default (Get-ItlOnDemandPortFamily -Family $Family))
    $key = [string](Get-ConfigValueFromObject -Object $runtimeState -Path "portKey" -Default "")
    if (-not $key) {
        throw "ITL_ONDEMAND_OWNERSHIP_MISSING: runtime state has no port ownership key: $Family/$InstanceId"
    }
    Release-ItlManagedPortAllocation -Family $portFamily -Key $key
    $path = Get-ItlOnDemandRuntimePath -Family $Family -InstanceId $InstanceId
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    return [pscustomobject]@{ schemaVersion = 1; status = "stopped"; family = $Family; instanceId = $InstanceId; pid = 0; port = 0; url = "" }
}

function Start-ItlOnDemandBackendInstance {
    param([string]$Family, [string]$InstanceId, [string]$CatalogSha256)

    $existing = Read-ItlOnDemandRuntimeState -Family $Family -InstanceId $InstanceId
    if ($null -ne $existing -and (Test-ItlOnDemandOwnedProcess -RuntimeState $existing) -and (Test-TcpPortOpen -Port ([int]$existing.port))) {
        return $existing
    }
    if ($null -ne $existing) { Stop-ItlOnDemandBackendInstance -Family $Family -InstanceId $InstanceId | Out-Null }
    $state = Read-CurrentDevBranchStateForRoctupMcp -Operation "ITL on-demand MCP"
    $state = Ensure-DevBranchEnterpriseNormalized -State $state -Reason "legacy-preflight"
    $portFamily = Get-ItlOnDemandPortFamily -Family $Family
    $key = Get-ItlOnDemandPortKey -Family $Family -State $state -InstanceId $InstanceId
    $port = 0
    $result = $null
    try {
        if ($Family -eq "roctup") {
            $artifact = Install-RoctupMcpArtifact
            $range = Get-RoctupMcpPortRange
            $port = Resolve-ItlManagedPort -Family $portFamily -Key $key -Start $range.start -End $range.end -State $state -Subject "ROCTUP on-demand MCP port"
            $url = Get-RoctupMcpUrl -Port $port
            $result = Start-EnterpriseBackground -InfoBasePath $state.devBranchInfoBasePath -InfoBaseKind $state.infoBaseKind -EnterpriseArgs @("/Execute", $artifact.path, "/Cstartup;mode=embedded;port=$port")
            $version = [string]$artifact.version
            $ready = Wait-RoctupMcpPort -Port $port -TimeoutSeconds 30
        } else {
            $state = Ensure-VanessaMcpInstalled -State $state
            $vanessa = Get-VanessaAutomationState
            if (-not $vanessa.ready) { throw "Vanessa Automation runtime is not installed." }
            $range = Get-VanessaMcpPortRange
            $port = Resolve-ItlManagedPort -Family $portFamily -Key $key -Start $range.start -End $range.end -State $state -Subject "Vanessa on-demand MCP port"
            $url = Get-VanessaMcpUrl -Port $port
            $result = Start-EnterpriseBackground -InfoBasePath $state.devBranchInfoBasePath -InfoBaseKind $state.infoBaseKind -UseTestManager -EnterpriseArgs @("/Execute", $vanessa.epfPath, "/CrunMcp;mcpPort=$port")
            $clientVersion = [string](Get-StateValue -State $state -Name "vanessaMcpClientMcpVersion" -Default "")
            $vaVersion = [string](Get-StateValue -State $state -Name "vanessaMcpVaExtensionVersion" -Default "")
            $version = "clientMcp=$clientVersion;vaExtension=$vaVersion"
            $ready = Wait-VanessaMcpPort -Port $port -TimeoutSeconds 30
        }
        if (-not $ready) { throw "$Family on-demand MCP did not open port $port. Log: $($result.logPath)" }
    } catch {
        if ($null -ne $result -and $null -ne $result.process) { Stop-Process -Id $result.process.Id -Force -ErrorAction SilentlyContinue }
        if ($port -gt 0) { Release-ItlManagedPortAllocation -Family $portFamily -Key $key }
        throw
    }
    try {
        Set-ItlManagedPortAllocationStatus -Family $portFamily -Key $key -Status "running" -ProcessId $result.process.Id
        $process = Get-Process -Id $result.process.Id -ErrorAction Stop
        $runtimeState = [pscustomobject][ordered]@{
            schemaVersion = 1; status = "running"; family = $Family; instanceId = $InstanceId
            pid = $result.process.Id; processStartTime = $process.StartTime.ToUniversalTime().ToString("o")
            executablePath = (Resolve-Agent1cFullPath -Path (Get-PlatformPath))
            ownershipMarkers = @([string]$state.devBranchInfoBasePath, "port=$port")
            portFamily = $portFamily; portKey = $key
            port = $port; url = $url; backendVersion = $version; catalogSha256 = $CatalogSha256
            logPath = $result.logPath; startedAt = (Get-Date).ToUniversalTime().ToString("o")
        }
        Write-ItlOnDemandRuntimeState -RuntimeState $runtimeState | Out-Null
        return $runtimeState
    } catch {
        Stop-Process -Id $result.process.Id -Force -ErrorAction SilentlyContinue
        Release-ItlManagedPortAllocation -Family $portFamily -Key $key
        throw
    }
}

function Invoke-ItlOnDemandBackendBroker {
    param(
        [ValidateSet("ensure", "stop", "stop-all")][string]$Operation,
        [ValidateSet("roctup", "vanessa-ui")][string]$Family,
        [string]$InstanceId,
        [string]$CatalogSha256
    )
    $startHandle = $null
    if ($Operation -eq "ensure") {
        $startLockPath = Join-Path $script:ProjectRoot ".agent-1c\locks\ondemand-start.lock"
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $startLockPath) | Out-Null
        $startHandle = [System.IO.File]::Open($startLockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    }
    try {
    if ($Operation -eq "stop-all") {
        Stop-ItlOnDemandBackends -Family $Family
        $result = [pscustomobject]@{ schemaVersion = 1; status = "stopped"; family = $Family; instanceId = "*" }
    } elseif ($InstanceId -notmatch '^[a-f0-9]{32}$') {
        throw "Invalid on-demand MCP instance id."
    } elseif ($Operation -eq "ensure") {
        $result = Start-ItlOnDemandBackendInstance -Family $Family -InstanceId $InstanceId -CatalogSha256 $CatalogSha256
    } else {
        $result = Stop-ItlOnDemandBackendInstance -Family $Family -InstanceId $InstanceId
    }
    } finally {
        if ($null -ne $startHandle) { $startHandle.Dispose() }
    }
    $json = $result | ConvertTo-Json -Compress -Depth 20
    Write-Output "ITL_ONDEMAND_RESULT=$json"
}

function Get-ItlOnDemandRuntimeInstances {
    $root = Get-ItlOnDemandRuntimeRoot
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return @() }
    $items = @()
    foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -File -Filter "*.json" -ErrorAction SilentlyContinue) {
        try { $items += (Read-Utf8Text -Path $file.FullName | ConvertFrom-Json) } catch { }
    }
    return @($items)
}

function Stop-ItlOnDemandBackends {
    param([string]$Family = "")
    foreach ($item in @(Get-ItlOnDemandRuntimeInstances)) {
        if ($Family -and [string]$item.family -ne $Family) { continue }
        Stop-ItlOnDemandBackendInstance -Family ([string]$item.family) -InstanceId ([string]$item.instanceId) | Out-Null
    }
}

function Remove-ItlOnDemandStaleInstances {
    $removed = 0
    foreach ($item in @(Get-ItlOnDemandRuntimeInstances)) {
        if (Test-ItlOnDemandOwnedProcess -RuntimeState $item) { continue }
        $portFamily = [string](Get-ConfigValueFromObject -Object $item -Path "portFamily" -Default "")
        $portKey = [string](Get-ConfigValueFromObject -Object $item -Path "portKey" -Default "")
        if ($portFamily -and $portKey) {
            Release-ItlManagedPortAllocation -Family $portFamily -Key $portKey
        }
        $path = Get-ItlOnDemandRuntimePath -Family ([string]$item.family) -InstanceId ([string]$item.instanceId)
        if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force }
        $removed++
    }
    return $removed
}

function Invoke-ItlOnDemandStaleCleanupForStatus {
    $lifecycleHandle = $null
    $runtimeHandle = $null
    try {
        $lifecyclePath = Get-Agent1cLifecycleLockPath -WorktreePath $script:ProjectRoot
        $runtimePath = Get-Agent1cRuntimeMcpLockPath -WorktreePath $script:ProjectRoot
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $lifecyclePath) | Out-Null
        # Status remains observable during another lifecycle operation. Cleanup is
        # best-effort and runs only when lifecycle -> runtime exclusive order can
        # be obtained immediately without replacing the visible operation record.
        $lifecycleHandle = [System.IO.File]::Open($lifecyclePath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        $runtimeHandle = [System.IO.File]::Open($runtimePath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        return (Remove-ItlOnDemandStaleInstances)
    } catch [System.IO.IOException] {
        return 0
    } finally {
        if ($null -ne $runtimeHandle) { $runtimeHandle.Dispose() }
        if ($null -ne $lifecycleHandle) { $lifecycleHandle.Dispose() }
    }
}

function Write-ItlOnDemandMcpStatusLines {
    param([string]$Indent = "")
    $executable = Get-ItlOnDemandMcpExecutablePath -AllowMissing
    $installed = Test-Path -LiteralPath $executable -PathType Leaf
    Write-Host "${Indent}ITL on-demand MCP facade: $(if ($installed) { 'ready' } else { 'missing' })"
    Write-Host "${Indent}ITL on-demand MCP executable: $executable"
    $removed = Invoke-ItlOnDemandStaleCleanupForStatus
    if ($removed -gt 0) { Write-Host "${Indent}ITL on-demand MCP stale instances removed: $removed" }
    $instances = @(Get-ItlOnDemandRuntimeInstances)
    Write-Host "${Indent}ITL on-demand MCP backend instances: $($instances.Count)"
    foreach ($item in $instances) {
        $alive = Test-ItlOnDemandOwnedProcess -RuntimeState $item
        Write-Host "${Indent}  $($item.family)/$($item.instanceId): $(if ($alive) { 'running' } else { 'stale' }) pid=$($item.pid) port=$($item.port) log=$($item.logPath)"
    }
}
