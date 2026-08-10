function Get-ItlOnDemandMcpWorkflowRoot {
    $mainHelperPath = ""
    if (Test-Path -LiteralPath (Join-Path $script:ProjectRoot ".git") -ErrorAction SilentlyContinue) {
        $mainWorktreePath = Get-MainWorktreePath
        $mainWorkflowRoot = Join-Path $mainWorktreePath ".agents\skills\1c-workflow"
        $mainHelperPath = Join-Path $mainWorkflowRoot "scripts\agent-1c.ps1"
        if (Test-Path -LiteralPath $mainHelperPath -PathType Leaf) {
            return (Resolve-Agent1cFullPath -Path $mainWorkflowRoot)
        }
    }

    $currentWorkflowRoot = Split-Path -Parent $script:Agent1cScriptRoot
    $currentHelperPath = Join-Path $currentWorkflowRoot "scripts\agent-1c.ps1"
    if (-not (Test-Path -LiteralPath $currentHelperPath -PathType Leaf)) {
        throw "ITL on-demand MCP workflow helper was not found in the main or current worktree. Main: $(if ($mainHelperPath) { $mainHelperPath } else { '<not available before Git initialization>' }). Current: $currentHelperPath"
    }
    return (Resolve-Agent1cFullPath -Path $currentWorkflowRoot)
}

function Get-ItlOnDemandMcpAssetRoot {
    return (Join-Path (Get-ItlOnDemandMcpWorkflowRoot) "assets\ondemand-mcp")
}

function Get-ItlOnDemandMcpCompatibility {
    $path = Join-Path (Get-ItlOnDemandMcpAssetRoot) "compatibility.json"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "ITL on-demand MCP compatibility manifest was not found: $path"
    }
    return (Read-Utf8Text -Path $path | ConvertFrom-Json)
}

function Sync-ItlOnDemandMcpDependencyLock {
    if ((Get-DependencyMode) -ne "fresh") {
        return $false
    }

    $template = New-DefaultDependencyLockManifest
    $entry = Get-ConfigValueFromObject -Object $template -Path "dependencies.itlOndemandMcp" -Default $null
    if ($null -eq $entry) {
        throw "templates/dependency-lock.json has no itlOndemandMcp entry."
    }

    $compatibility = Get-ItlOnDemandMcpCompatibility
    $templateVersion = [string](Get-ConfigValueFromObject -Object $entry -Path "version" -Default "")
    if (-not $templateVersion -or $templateVersion -cne [string]$compatibility.facadeVersion) {
        throw "ITL_ONDEMAND_TEMPLATE_COMPATIBILITY_MISMATCH: template='$templateVersion' compatibility='$($compatibility.facadeVersion)'."
    }

    Update-DependencyLockEntry -Name "itlOndemandMcp" -Values (ConvertTo-Agent1cHashtable -Object $entry)
    Write-Host "ITL on-demand MCP fresh lock synchronized to facade $templateVersion."
    return $true
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
    $override = [Environment]::GetEnvironmentVariable("ITL_ONDEMAND_MCP_INSTALL_ROOT")
    if (-not [string]::IsNullOrWhiteSpace($override)) {
        return (Resolve-Agent1cFullPath -Path $override)
    }
    $base = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if ([string]::IsNullOrWhiteSpace($base)) {
        throw "LOCALAPPDATA is required for ITL on-demand MCP."
    }
    return (Join-Path $base "ITL\MCP\ondemand")
}

function Get-ItlOnDemandMcpFacadeContract {
    $manifest = Get-ItlOnDemandMcpCompatibility
    $facadeVersionText = [string](Get-ConfigValueFromObject -Object $manifest -Path "facadeVersion" -Default "")
    $minimumVersionText = [string](Get-ConfigValueFromObject -Object $manifest -Path "minimumFacadeVersion" -Default "")
    try {
        $facadeVersion = [version]$facadeVersionText
        $minimumVersion = [version]$minimumVersionText
    } catch {
        throw "ITL_ONDEMAND_FACADE_VERSION_INVALID: facade='$facadeVersionText' minimum='$minimumVersionText'."
    }
    if ($facadeVersion -lt $minimumVersion) {
        throw "ITL_ONDEMAND_FACADE_BELOW_MINIMUM: facade='$facadeVersionText' minimum='$minimumVersionText'."
    }

    $entry = Get-DependencyLockEntry -Name "itlOndemandMcp"
    if ($null -eq $entry) {
        throw "ITL_ONDEMAND_DEPENDENCY_LOCK_MISSING: .agent-1c/dependency-lock.json has no itlOndemandMcp entry."
    }
    $lockedVersion = [string](Get-ConfigValueFromObject -Object $entry -Path "version" -Default "")
    $assetName = [string](Get-ConfigValueFromObject -Object $entry -Path "assetName" -Default "")
    $sha256 = [string](Get-ConfigValueFromObject -Object $entry -Path "sha256" -Default "")
    if ($lockedVersion -cne $facadeVersionText) {
        throw "ITL_ONDEMAND_FACADE_LOCK_MISMATCH: compatibility='$facadeVersionText' dependencyLock='$lockedVersion'."
    }
    if ($assetName -cne "itl-ondemand-mcp-windows-amd64.exe") {
        throw "ITL_ONDEMAND_FACADE_ASSET_INVALID: expected='itl-ondemand-mcp-windows-amd64.exe' actual='$assetName'."
    }
    if ($sha256 -notmatch '^[a-fA-F0-9]{64}$') {
        throw "ITL_ONDEMAND_FACADE_SHA256_INVALID: dependency lock must contain a 64-character SHA256."
    }

    return [pscustomobject]@{
        manifest = $manifest
        entry = $entry
        version = $facadeVersionText
        assetName = $assetName
        sha256 = $sha256.ToLowerInvariant()
    }
}

function Get-ItlOnDemandMcpExecutablePath {
    param([switch]$AllowMissing)

    $override = [Environment]::GetEnvironmentVariable("ITL_ONDEMAND_MCP_EXE")
    if (-not [string]::IsNullOrWhiteSpace($override)) {
        $resolved = Resolve-Agent1cFullPath -Path $override
        if ($AllowMissing -or (Test-Path -LiteralPath $resolved -PathType Leaf)) { return $resolved }
    }
    $contract = Get-ItlOnDemandMcpFacadeContract
    $path = Join-Path (Join-Path (Get-ItlOnDemandMcpInstallRoot) $contract.version) $contract.assetName
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -cne $contract.sha256) {
            throw "ITL_ONDEMAND_FACADE_INSTALLED_SHA256_MISMATCH: expected='$($contract.sha256)' actual='$actual' path='$path'. Run update-workflow to repair the installed facade."
        }
        return $path
    }
    if ($AllowMissing) { return $path }
    throw "ITL on-demand MCP executable is not installed: $path. Run update-workflow after the matching workflow release asset is published."
}

function Install-ItlOnDemandMcp {
    param([switch]$ForceDownload)

    if (-not [Environment]::Is64BitOperatingSystem -or -not [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) {
        throw "ITL_ONDEMAND_UNSUPPORTED_PLATFORM: v1 supports Windows x64 only."
    }
    $contract = Get-ItlOnDemandMcpFacadeContract
    $entry = $contract.entry
    $version = $contract.version
    $url = [string](Get-ConfigValueFromObject -Object $entry -Path "url" -Default "")
    $sha256 = $contract.sha256
    $assetName = $contract.assetName
    $targetDirectory = Join-Path (Get-ItlOnDemandMcpInstallRoot) $version
    $targetPath = Join-Path $targetDirectory $assetName

    # Source-repository development may use a locally built, SHA-verified artifact.
    $sourceRepositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $script:Agent1cScriptRoot "..\..\..\.."))
    # Publication candidates are exported without Git metadata. Treat the
    # canonical source-build location as usable only when its bytes match the
    # dependency lock, so candidates can qualify a not-yet-published release
    # without trusting an arbitrary local executable.
    $sourceBuildOverride = [Environment]::GetEnvironmentVariable("ITL_ONDEMAND_MCP_SOURCE_BUILD_EXE", "Process")
    if (-not [string]::IsNullOrWhiteSpace($sourceBuildOverride)) {
        try { $sourceBuild = [System.IO.Path]::GetFullPath($sourceBuildOverride) } catch {
            throw "ITL_ONDEMAND_SOURCE_BUILD_PATH_INVALID: '$sourceBuildOverride'."
        }
        if (-not (Test-Path -LiteralPath $sourceBuild -PathType Leaf)) {
            throw "ITL_ONDEMAND_SOURCE_BUILD_MISSING: $sourceBuild"
        }
    } else {
        $sourceBuild = Join-Path $sourceRepositoryRoot "tools\itl-ondemand-mcp\build\itl-ondemand-mcp-windows-amd64.exe"
    }
    if ($sourceBuild -and (Test-Path -LiteralPath $sourceBuild -PathType Leaf) -and $sha256) {
        $sourceHash = (Get-FileHash -LiteralPath $sourceBuild -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($sourceHash -cne $sha256.ToLowerInvariant()) {
            if (-not [string]::IsNullOrWhiteSpace($sourceBuildOverride)) {
                throw "ITL_ONDEMAND_SOURCE_BUILD_SHA256_MISMATCH: expected='$($sha256.ToLowerInvariant())' actual='$sourceHash' path='$sourceBuild'."
            }
            $sourceBuild = ""
        }
    }
    if ($sourceBuild -and (Test-Path -LiteralPath $sourceBuild -PathType Leaf) -and (-not $url -or $ForceDownload -eq $false)) {
        $copySourceBuild = $true
        if (Test-Path -LiteralPath $targetPath -PathType Leaf) {
            if (-not $sourceHash) {
                $sourceHash = (Get-FileHash -LiteralPath $sourceBuild -Algorithm SHA256).Hash.ToLowerInvariant()
            }
            $targetHash = (Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash.ToLowerInvariant()
            $copySourceBuild = $sourceHash -cne $targetHash
        }
        if ($copySourceBuild) {
            New-Item -ItemType Directory -Force -Path $targetDirectory | Out-Null
            Copy-Item -LiteralPath $sourceBuild -Destination $targetPath -Force
        }
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
    $workflowRoot = Get-ItlOnDemandMcpWorkflowRoot
    $helper = Resolve-Agent1cFullPath -Path (Join-Path $workflowRoot "scripts\agent-1c.ps1")
    $root = Resolve-Agent1cFullPath -Path $script:ProjectRoot
    $endpoints = @()
    foreach ($family in @("roctup", "vanessa-ui")) {
        $definition = Get-ItlOnDemandMcpFamilyDefinition -Family $family
        $endpoints += [pscustomobject]@{
            name = $definition.serverName
            transport = "stdio"
            command = $executable
            args = @("serve", "--family", $family, "--project-root", $root, "--catalog", $definition.catalogPath, "--helper", $helper, "--surface", "gateway", "--idle-timeout", "10m")
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

function Get-ItlOnDemandVanessaTestClientPortRange {
    $range = [string](Get-EnvValue -Name "VANESSA_MCP_TESTCLIENT_PORT_RANGE" -Default "")
    if ($range -match '^\s*(\d+)\s*(?:\.\.|-|:)\s*(\d+)\s*$') {
        $start = [int]$matches[1]
        $end = [int]$matches[2]
    } else {
        $start = 48151
        $end = 48250
    }
    if ($start -lt 1 -or $end -gt 65535 -or $start -gt $end) {
        throw "Invalid VANESSA_MCP_TESTCLIENT_PORT_RANGE: $start..$end"
    }
    return [pscustomobject]@{ start = $start; end = $end }
}

function Get-ItlOnDemandVanessaTestClientPortKey {
    param([object]$State, [string]$InstanceId)
    $base = Get-ItlBranchManagedPortKey -Family "vanessa-mcp-testclient" -State $State
    return "$base|instance=$InstanceId"
}

function New-ItlOnDemandVanessaParamsFile {
    param([object]$State, [string]$InstanceId, [int]$TestClientPort, [string]$VanessaVersion)

    $directory = Split-Path -Parent (Get-ItlOnDemandRuntimePath -Family "vanessa-ui" -InstanceId $InstanceId)
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $path = Join-Path $directory "$InstanceId.VAParams.json"
    $infoBaseKind = [string](Get-StateValue -State $State -Name "infoBaseKind" -Default (Get-InfoBaseKind))
    $infoBasePath = [string](Get-StateValue -State $State -Name "devBranchInfoBasePath" -Default "")
    $user = Get-EnvValue -Name "IB_USER"

    $profile = [ordered]@{}
    $profile[(ConvertFrom-Utf8Base64 "0JjQvNGP")] = "itl-ondemand"
    $profile[(ConvertFrom-Utf8Base64 "0KHQuNC90L7QvdC40Lw=")] = "ITL on-demand TestClient"
    $profile[(ConvertFrom-Utf8Base64 "0J/Rg9GC0YzQmtCY0L3RhNC+0LHQsNC30LU=")] = New-VanessaTestClientInfoBaseArg -InfoBaseKind $infoBaseKind -InfoBasePath $infoBasePath
    $profile[(ConvertFrom-Utf8Base64 "0J/QvtGA0YLQl9Cw0L/Rg9GB0LrQsNCi0LXRgdGC0JrQu9C40LXQvdGC0LA=")] = $TestClientPort
    $profile[(ConvertFrom-Utf8Base64 "0JTQvtC/0J/QsNGA0LDQvNC10YLRgNGL")] = New-VanessaTestClientAdditionalParams -User $user -Password (Get-EnvValue -Name "IB_PASSWORD")
    $profile[(ConvertFrom-Utf8Base64 "0KLQuNC/0JrQu9C40LXQvdGC0LA=")] = ConvertFrom-Utf8Base64 "0KLQvtC90LrQuNC5"
    $profile[(ConvertFrom-Utf8Base64 "0JjQvNGP0JrQvtC80L/RjNGO0YLQtdGA0LA=")] = "localhost"
    $profile[(ConvertFrom-Utf8Base64 "UElE0JrQu9C40LXQvdGC0LDQotC10YHRgtC40YDQvtCy0LDQvdC40Y8=")] = 0

    $testClients = [ordered]@{}
    $testClients[(ConvertFrom-Utf8Base64 "0JfQsNC/0YPRgdC60LDRgtGM0JrQu9C40LXQvdGC0KLQtdGB0YLQuNGA0L7QstCw0L3QuNGP0KHQnNCw0LrRgdC40LzQuNC30LjRgNC+0LLQsNC90L3Ri9C80J7QutC90L7QvA==")] = $true
    $testClients[(ConvertFrom-Utf8Base64 "0KLQsNC50LzQsNGD0YLQl9Cw0L/Rg9GB0LrQsDHQoQ==")] = ConvertTo-IntOrDefault -Value (Get-EnvValue -Name "VANESSA_TEST_CLIENT_STARTUP_TIMEOUT_SECONDS" -Default 300) -Default 300
    $testClients[(ConvertFrom-Utf8Base64 "0JfQsNC60YDRi9Cy0LDRgtGM0JrQu9C40LXQvdGC0KLQtdGB0YLQuNGA0L7QstCw0L3QuNGP0J/RgNC40L3Rg9C00LjRgtC10LvRjNC90L4=")] = $true
    $testClients[(ConvertFrom-Utf8Base64 "0JTQsNC90L3Ri9C10JrQu9C40LXQvdGC0L7QstCi0LXRgdGC0LjRgNC+0LLQsNC90LjRjw==")] = @($profile)

    $params = [ordered]@{
        Version = $VanessaVersion
        Lang = "ru"
        UseEditor = $true
        usevanessaeditor = $true
        useaddin = $true
        useaddinforscreencapture = $true
        QuitIfSilentInstallationAddinFails = $true
        DisableLoadTestClientsTable = $true
    }
    $params[(ConvertFrom-Utf8Base64 "0JrQu9C40LXQvdGC0KLQtdGB0YLQuNGA0L7QstCw0L3QuNGP")] = $testClients
    Write-Utf8Text -Path $path -Value (($params | ConvertTo-Json -Depth 10) + [Environment]::NewLine)
    return $path
}

function Get-ItlOnDemandOwnedTestClientProcesses {
    param([object]$RuntimeState)
    $port = ConvertTo-IntOrDefault -Value (Get-ConfigValueFromObject -Object $RuntimeState -Path "testClientPort" -Default 0) -Default 0
    $infoBase = [string](Get-ConfigValueFromObject -Object $RuntimeState -Path "infoBasePath" -Default "")
    if ($port -le 0 -or -not $infoBase) { return @() }
    $ownedPid = ConvertTo-IntOrDefault -Value (Get-ConfigValueFromObject -Object $RuntimeState -Path "testClientPid" -Default 0) -Default 0
    if ($ownedPid -gt 0) {
        try {
            $process = Get-Process -Id $ownedPid -ErrorAction Stop
            $native = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$ownedPid" -ErrorAction Stop
            $expected = [DateTimeOffset]::Parse([string]$RuntimeState.testClientProcessStartTime).UtcDateTime
            $expectedExecutable = [string](Get-ConfigValueFromObject -Object $RuntimeState -Path "testClientExecutablePath" -Default "")
            if ([Math]::Abs(($process.StartTime.ToUniversalTime() - $expected).TotalSeconds) -ge 2) { return @() }
            if (-not $expectedExecutable -or -not [string]::Equals([string]$native.ExecutablePath, $expectedExecutable, [System.StringComparison]::OrdinalIgnoreCase)) { return @() }
            $commandLine = [string]$native.CommandLine
            foreach ($marker in @($RuntimeState.testClientOwnershipMarkers)) {
                if (-not $marker -or $commandLine.IndexOf([string]$marker, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { return @() }
            }
            return @([pscustomobject]@{ process = $process; native = $native })
        } catch {
            return @()
        }
    }
    try { $startedAt = [DateTimeOffset]::Parse([string]$RuntimeState.processStartTime).UtcDateTime } catch { return @() }
    $expectedExecutable = [string](Get-ConfigValueFromObject -Object $RuntimeState -Path "executablePath" -Default "")
    $result = @()
    foreach ($native in @(Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue)) {
        $commandLine = [string]$native.CommandLine
        if ($commandLine -notmatch '(?i)/TESTCLIENT' -or $commandLine -notmatch ("(?i)-TPort\s+" + [regex]::Escape([string]$port) + "(?:\s|$)")) { continue }
        if ($commandLine.IndexOf($infoBase, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        if ($expectedExecutable -and -not [string]::Equals([string]$native.ExecutablePath, $expectedExecutable, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        $process = Get-Process -Id ([int]$native.ProcessId) -ErrorAction SilentlyContinue
        if ($null -eq $process -or $process.StartTime.ToUniversalTime() -lt $startedAt.AddSeconds(-2)) { continue }
        $result += [pscustomobject]@{ process = $process; native = $native }
    }
    return @($result)
}

function Wait-ItlOnDemandTestClientReady {
    param([System.Diagnostics.Process]$Process, [int]$TimeoutSeconds = 120)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $Process.Refresh()
        if ($Process.HasExited) { return $false }
        if ($Process.MainWindowHandle -ne [IntPtr]::Zero -or -not [string]::IsNullOrWhiteSpace([string]$Process.MainWindowTitle)) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

function Wait-ItlOnDemandTestClientPortReady {
    param([System.Diagnostics.Process]$Process, [int]$Port, [int]$TimeoutSeconds = 120)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $Process.Refresh()
        if ($Process.HasExited) { return $false }
        if (Test-TcpPortOpen -Port $Port -TimeoutMilliseconds 500) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

function Wait-ItlOnDemandProcessExit {
    param(
        [int]$ProcessId,
        [int]$TimeoutSeconds = 15,
        [int]$PollMilliseconds = 100
    )
    if ($ProcessId -le 0) { return $true }
    $deadline = (Get-Date).AddSeconds([Math]::Max(0, $TimeoutSeconds))
    do {
        if ($null -eq (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) { return $true }
        if ((Get-Date) -ge $deadline) { return $false }
        Start-Sleep -Milliseconds ([Math]::Max(1, $PollMilliseconds))
    } while ($true)
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

function Test-ItlOnDemandPortOwnedByProcess {
    param(
        [int]$Port,
        [int]$ProcessId
    )
    if ($Port -le 0 -or $ProcessId -le 0) { return $false }
    try {
        $listeners = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction Stop)
        if ($listeners.Count -eq 0) { return $false }
        if (@($listeners | Where-Object { [int]$_.OwningProcess -ne $ProcessId }).Count -gt 0) { return $false }
        return @($listeners | Where-Object { [int]$_.OwningProcess -eq $ProcessId }).Count -gt 0
    } catch {
        return $false
    }
}

function Get-ItlOnDemandManagedPortLeaseMatches {
    param(
        [string]$Family,
        [string]$Key,
        [string]$LeaseToken = ""
    )
    return @(Invoke-ItlPortRegistryLock -ScriptBlock {
        $registry = Read-ItlPortRegistry
        $allocations = @(ConvertTo-ItlPortAllocationArray (Get-ItlPortObjectValue -Object $registry -Name "allocations" -Default @()))
        return @($allocations | Where-Object {
            $allocationFamily = [string](Get-ItlPortObjectValue -Object $_ -Name "family" -Default "")
            $allocationKey = [string](Get-ItlPortObjectValue -Object $_ -Name "key" -Default "")
            $allocationToken = [string](Get-ItlPortObjectValue -Object $_ -Name "leaseToken" -Default "")
            $allocationFamily -eq $Family -and $allocationKey -eq $Key -and
                $(if ($LeaseToken) { $allocationToken -eq $LeaseToken } else { -not $allocationToken })
        })
    })
}

function Set-ItlOnDemandManagedPortLeaseStatus {
    param(
        [string]$Family,
        [string]$Key,
        [string]$LeaseToken,
        [string]$Status,
        [int]$ProcessId = 0
    )
    if (@(Get-ItlOnDemandManagedPortLeaseMatches -Family $Family -Key $Key -LeaseToken $LeaseToken).Count -ne 1) {
        throw "ITL_ONDEMAND_PORT_LEASE_MISMATCH: cannot update $Family/$Key with its recorded immutable lease token."
    }
    Set-ItlManagedPortAllocationStatus -Family $Family -Key $Key -Status $Status -ProcessId $ProcessId -LeaseToken $LeaseToken
    $updated = @(Get-ItlOnDemandManagedPortLeaseMatches -Family $Family -Key $Key -LeaseToken $LeaseToken)
    if ($updated.Count -ne 1 -or [string](Get-ItlPortObjectValue -Object $updated[0] -Name "status" -Default "") -ne $Status) {
        throw "ITL_ONDEMAND_PORT_LEASE_UPDATE_FAILED: status '$Status' was not persisted for $Family/$Key; runtime state and leases were retained."
    }
}

function Release-ItlOnDemandManagedPortLease {
    param(
        [string]$Family,
        [string]$Key,
        [string]$LeaseToken = ""
    )
    $matches = @(Get-ItlOnDemandManagedPortLeaseMatches -Family $Family -Key $Key -LeaseToken $LeaseToken)
    if ($matches.Count -eq 0) {
        $sameKey = @(Invoke-ItlPortRegistryLock -ScriptBlock {
            $registry = Read-ItlPortRegistry
            return @(ConvertTo-ItlPortAllocationArray (Get-ItlPortObjectValue -Object $registry -Name "allocations" -Default @()) | Where-Object {
                [string](Get-ItlPortObjectValue -Object $_ -Name "family" -Default "") -eq $Family -and
                    [string](Get-ItlPortObjectValue -Object $_ -Name "key" -Default "") -eq $Key
            })
        })
        if ($sameKey.Count -gt 0) {
            throw "ITL_ONDEMAND_PORT_LEASE_MISMATCH: refusing to release replacement or foreign lease for $Family/$Key."
        }
        return
    }
    if ($matches.Count -ne 1) {
        throw "ITL_ONDEMAND_PORT_LEASE_AMBIGUOUS: expected one owned lease for $Family/$Key, found $($matches.Count)."
    }
    Release-ItlManagedPortAllocation -Family $Family -Key $Key -LeaseToken $LeaseToken
    if (@(Get-ItlOnDemandManagedPortLeaseMatches -Family $Family -Key $Key -LeaseToken $LeaseToken).Count -gt 0) {
        throw "ITL_ONDEMAND_PORT_LEASE_RELEASE_FAILED: owned lease for $Family/$Key remains registered."
    }
}

function Stop-ItlOnDemandBackendInstance {
    param(
        [string]$Family,
        [string]$InstanceId,
        [switch]$StrictOwnership = $true
    )
    $path = Get-ItlOnDemandRuntimePath -Family $Family -InstanceId $InstanceId
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [pscustomobject]@{ status = "stopped"; family = $Family; instanceId = $InstanceId }
    }
    $claimedPath = "$path.removing-$([guid]::NewGuid().ToString('N'))"
    try {
        Move-Item -LiteralPath $path -Destination $claimedPath
    } catch {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            return [pscustomobject]@{ status = "stopped"; family = $Family; instanceId = $InstanceId }
        }
        throw
    }
    try {
        try { $runtimeState = Read-Utf8Text -Path $claimedPath | ConvertFrom-Json } catch {
            throw "ITL_ONDEMAND_RUNTIME_STATE_INVALID path='$path': $($_.Exception.Message)"
        }
        $ownedChildren = @(Get-ItlOnDemandOwnedTestClientProcesses -RuntimeState $runtimeState)
        $managerPid = ConvertTo-IntOrDefault -Value $runtimeState.pid -Default 0
        $managerProcess = $(if ($managerPid -gt 0) { Get-Process -Id $managerPid -ErrorAction SilentlyContinue } else { $null })
        $testClientPid = ConvertTo-IntOrDefault -Value (Get-ConfigValueFromObject -Object $runtimeState -Path "testClientPid" -Default 0) -Default 0
        $testClientProcess = $(if ($testClientPid -gt 0) { Get-Process -Id $testClientPid -ErrorAction SilentlyContinue } else { $null })
        $ownedManager = Test-ItlOnDemandOwnedProcess -RuntimeState $runtimeState
        if ($null -ne $managerProcess -and -not $ownedManager) {
            throw "ITL_ONDEMAND_OWNERSHIP_MISMATCH: refusing to stop unverified backend PID $managerPid for $Family/$InstanceId."
        }
        if ($null -ne $testClientProcess -and $ownedChildren.Count -eq 0) {
            throw "ITL_ONDEMAND_OWNERSHIP_MISMATCH: refusing to stop unverified TestClient PID $testClientPid for $Family/$InstanceId."
        }
        foreach ($child in $ownedChildren) {
            Stop-Process -Id $child.process.Id -Force -ErrorAction SilentlyContinue
        }
        if ($ownedManager) {
            Stop-Process -Id ([int]$runtimeState.pid) -Force -ErrorAction SilentlyContinue
        }
        foreach ($child in $ownedChildren) {
            if (-not (Wait-ItlOnDemandProcessExit -ProcessId $child.process.Id -TimeoutSeconds 15)) {
                throw "ITL_ONDEMAND_STOP_FAILED: owned TestClient PID $($child.process.Id) is still running; leases were retained."
            }
        }
        if ($ownedManager -and -not (Wait-ItlOnDemandProcessExit -ProcessId ([int]$runtimeState.pid) -TimeoutSeconds 15)) {
            throw "ITL_ONDEMAND_STOP_FAILED: owned backend PID $($runtimeState.pid) is still running; leases were retained."
        }
        $backendPort = ConvertTo-IntOrDefault -Value (Get-ConfigValueFromObject -Object $runtimeState -Path "port" -Default 0) -Default 0
        if ($backendPort -gt 0 -and (Test-TcpPortOpen -Port $backendPort)) {
            throw "ITL_ONDEMAND_STOP_FAILED: backend port $backendPort is still open for $Family/$InstanceId; leases were retained."
        }
        $ownedTestClientPort = ConvertTo-IntOrDefault -Value (Get-ConfigValueFromObject -Object $runtimeState -Path "testClientPort" -Default 0) -Default 0
        if ($ownedTestClientPort -gt 0 -and (Test-TcpPortOpen -Port $ownedTestClientPort)) {
            throw "ITL_ONDEMAND_STOP_FAILED: TestClient port $ownedTestClientPort is still open for $Family/$InstanceId; leases were retained."
        }
        $portFamily = [string](Get-ConfigValueFromObject -Object $runtimeState -Path "portFamily" -Default (Get-ItlOnDemandPortFamily -Family $Family))
        $key = [string](Get-ConfigValueFromObject -Object $runtimeState -Path "portKey" -Default "")
        if (-not $key) {
            throw "ITL_ONDEMAND_OWNERSHIP_MISSING: runtime state has no port ownership key: $Family/$InstanceId"
        }
        $portLeaseToken = [string](Get-ConfigValueFromObject -Object $runtimeState -Path "portLeaseToken" -Default "")
        Release-ItlOnDemandManagedPortLease -Family $portFamily -Key $key -LeaseToken $portLeaseToken
        $testClientPortFamily = [string](Get-ConfigValueFromObject -Object $runtimeState -Path "testClientPortFamily" -Default "")
        $testClientPortKey = [string](Get-ConfigValueFromObject -Object $runtimeState -Path "testClientPortKey" -Default "")
        $testClientPortLeaseToken = [string](Get-ConfigValueFromObject -Object $runtimeState -Path "testClientPortLeaseToken" -Default "")
        if ($testClientPortFamily -and $testClientPortKey) {
            Release-ItlOnDemandManagedPortLease -Family $testClientPortFamily -Key $testClientPortKey -LeaseToken $testClientPortLeaseToken
        }
        $paramsPath = [string](Get-ConfigValueFromObject -Object $runtimeState -Path "vanessaParamsPath" -Default "")
        if ($paramsPath -and (Test-Path -LiteralPath $paramsPath -PathType Leaf)) { Remove-Item -LiteralPath $paramsPath -Force }
        Remove-Item -LiteralPath $claimedPath -Force
        return [pscustomobject]@{ schemaVersion = 2; status = "stopped"; family = $Family; instanceId = $InstanceId; pid = 0; port = 0; testClientPort = 0; url = "" }
    } catch {
        if ((Test-Path -LiteralPath $claimedPath -PathType Leaf) -and -not (Test-Path -LiteralPath $path)) {
            Move-Item -LiteralPath $claimedPath -Destination $path
        }
        throw
    }
}

function Get-ItlOnDemandBackendRuntimeHealth {
    param([Parameter(Mandatory = $true)][object]$RuntimeState)

    $processId = ConvertTo-IntOrDefault -Value $RuntimeState.pid -Default 0
    $port = ConvertTo-IntOrDefault -Value $RuntimeState.port -Default 0
    if ($port -le 0) {
        return [pscustomobject]@{ stale = $false; status = "invalid-registration"; pidAlive = $false; portOpen = $false; owned = $false }
    }
    $portOpen = Test-TcpPortOpen -Port $port
    if ($processId -le 0) {
        $runtimeStatus = [string](Get-ConfigValueFromObject -Object $RuntimeState -Path "status" -Default "")
        $startingAtText = [string](Get-ConfigValueFromObject -Object $RuntimeState -Path "startingAt" -Default "")
        $startingAt = [datetime]::MinValue
        $startingAtKnown = [datetime]::TryParse($startingAtText, [ref]$startingAt)
        $startingRegistrationUnexpired = $runtimeStatus -eq "starting" -and
            (-not $startingAtKnown -or ((Get-Date).ToUniversalTime() - $startingAt.ToUniversalTime()).TotalSeconds -lt 300)
        return [pscustomobject]@{
            stale = -not $portOpen -and -not $startingRegistrationUnexpired
            status = $(if ($portOpen) { "startup-port-open-ownership-unverified" } elseif ($startingRegistrationUnexpired) { "startup-registration-unexpired" } else { "startup-no-process-port-closed" })
            pidAlive = $false; portOpen = $portOpen; owned = $false
        }
    }
    $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
    $pidAlive = $null -ne $process
    if (-not $pidAlive) {
        return [pscustomobject]@{
            stale = -not $portOpen
            status = $(if ($portOpen) { "pid-dead-port-open" } else { "pid-dead" })
            pidAlive = $false; portOpen = $portOpen; owned = $false
        }
    }
    $owned = Test-ItlOnDemandOwnedProcess -RuntimeState $RuntimeState
    if (-not $owned) {
        return [pscustomobject]@{ stale = $false; status = "ownership-unverified"; pidAlive = $true; portOpen = $portOpen; owned = $false }
    }
    if (-not $portOpen) {
        return [pscustomobject]@{ stale = $true; status = "owned-pid-port-unavailable"; pidAlive = $true; portOpen = $false; owned = $true }
    }
    return [pscustomobject]@{ stale = $false; status = "healthy"; pidAlive = $true; portOpen = $true; owned = $true }
}

function Recover-ItlOnDemandBackendInstance {
    param(
        [string]$Family,
        [string]$InstanceId,
        [string]$ReplacementInstanceId,
        [int]$ExpectedPid,
        [int]$ExpectedPort,
        [string]$CatalogSha256
    )

    $runtimeState = Read-ItlOnDemandRuntimeState -Family $Family -InstanceId $InstanceId
    if ($null -eq $runtimeState) {
        throw "ITL_ONDEMAND_RECOVERY_STATE_MISSING: no registered runtime for $Family/$InstanceId."
    }
    if ([int]$runtimeState.pid -ne $ExpectedPid -or [int]$runtimeState.port -ne $ExpectedPort) {
        throw "ITL_ONDEMAND_RECOVERY_IDENTITY_CHANGED: registered PID/port no longer match $Family/$InstanceId."
    }
    $health = Get-ItlOnDemandBackendRuntimeHealth -RuntimeState $runtimeState
    if (-not $health.stale) {
        throw "ITL_ONDEMAND_RECOVERY_NOT_STALE: status=$($health.status) pidAlive=$($health.pidAlive) portOpen=$($health.portOpen) owned=$($health.owned)."
    }
    Stop-ItlOnDemandBackendInstance -Family $Family -InstanceId $InstanceId -StrictOwnership | Out-Null
    return (Start-ItlOnDemandBackendInstance -Family $Family -InstanceId $ReplacementInstanceId -CatalogSha256 $CatalogSha256)
}

function Confirm-ItlOnDemandBackendRunning {
    param(
        [string]$Family,
        [string]$InstanceId,
        [int]$ExpectedPid,
        [int]$ExpectedPort,
        [string]$CatalogSha256
    )
    $runtimeState = Read-ItlOnDemandRuntimeState -Family $Family -InstanceId $InstanceId
    if ($null -eq $runtimeState) {
        throw "ITL_ONDEMAND_READINESS_STATE_MISSING: no registered runtime for $Family/$InstanceId."
    }
    if ([int]$runtimeState.pid -ne $ExpectedPid -or [int]$runtimeState.port -ne $ExpectedPort -or [string]$runtimeState.catalogSha256 -ne $CatalogSha256) {
        throw "ITL_ONDEMAND_READINESS_IDENTITY_CHANGED: registered PID/port/catalog no longer match $Family/$InstanceId."
    }
    if (-not (Test-ItlOnDemandOwnedProcess -RuntimeState $runtimeState)) {
        throw "ITL_ONDEMAND_OWNERSHIP_MISMATCH: backend PID $ExpectedPid is not strictly owned by $Family/$InstanceId; state and leases were retained."
    }
    if (-not (Test-ItlOnDemandPortOwnedByProcess -Port $ExpectedPort -ProcessId $ExpectedPid)) {
        throw "ITL_ONDEMAND_READINESS_IDENTITY_UNVERIFIED: port $ExpectedPort is not proven to be owned by backend PID $ExpectedPid; state and leases were retained."
    }
    $runningState = Set-ItlOnDemandRuntimeStateValues -RuntimeState $runtimeState -Values ([ordered]@{
        status = "running"
        readiness = "mcp-handshake-catalog-verified"
        runningAt = (Get-Date).ToUniversalTime().ToString("o")
        portOwnerPidVerified = $true
    })
    Set-ItlOnDemandManagedPortLeaseStatus `
        -Family ([string](Get-ConfigValueFromObject -Object $runningState -Path "portFamily" -Default "")) `
        -Key ([string](Get-ConfigValueFromObject -Object $runningState -Path "portKey" -Default "")) `
        -LeaseToken ([string](Get-ConfigValueFromObject -Object $runningState -Path "portLeaseToken" -Default "")) `
        -Status "running" `
        -ProcessId $ExpectedPid
    Write-ItlOnDemandRuntimeState -RuntimeState $runningState | Out-Null
    return $runningState
}

function Set-ItlOnDemandRuntimeStateValues {
    param([object]$RuntimeState, [System.Collections.IDictionary]$Values)
    $stateHash = ConvertTo-Agent1cHashtable -Object $RuntimeState
    foreach ($entry in $Values.GetEnumerator()) {
        $stateHash[[string]$entry.Key] = $entry.Value
    }
    return [pscustomobject]$stateHash
}

function Test-ItlOnDemandVanessaPlatformLicenseUnavailableLog {
    param([AllowNull()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try {
        $text = Read-Utf8Text -Path $Path
        $licenseCompositionMarker = ConvertFrom-Utf8Base64 "0YLQtdC60YPRidC40Lwg0YHQvtGB0YLQsNCy0L7QvCDQu9C40YbQtdC90LfQuNC5"
        return $text.IndexOf($licenseCompositionMarker, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
            $text -match '(?i)(license\s+(?:limit|is not available)|HTTP:\s*Forbidden)'
    } catch {
        return $false
    }
}

function Ensure-ItlOnDemandVanessaTestClient {
    param([string]$InstanceId)

    $runtimeState = Read-ItlOnDemandRuntimeState -Family "vanessa-ui" -InstanceId $InstanceId
    if ($null -eq $runtimeState) {
        throw "ITL_ONDEMAND_RUNTIME_STATE_MISSING: no registered runtime for vanessa-ui/$InstanceId."
    }
    if (-not (Test-ItlOnDemandOwnedProcess -RuntimeState $runtimeState) -or -not (Test-TcpPortOpen -Port ([int]$runtimeState.port))) {
        throw "ITL_ONDEMAND_OWNERSHIP_MISMATCH: Vanessa manager ownership/port is not proven for vanessa-ui/$InstanceId."
    }

    $state = Read-CurrentDevBranchStateForRoctupMcp -Operation "ITL on-demand Vanessa TestClient"
    $testClientPort = ConvertTo-IntOrDefault -Value (Get-ConfigValueFromObject -Object $runtimeState -Path "testClientPort" -Default 0) -Default 0
    $recordedPid = ConvertTo-IntOrDefault -Value (Get-ConfigValueFromObject -Object $runtimeState -Path "testClientPid" -Default 0) -Default 0
    $previousPid = 0
    $previousState = ""
    if ($testClientPort -le 0) {
        throw "ITL_ONDEMAND_OWNERSHIP_MISSING: runtime state has no Vanessa TestClient port."
    }

    if ($recordedPid -gt 0) {
        $recordedProcess = Get-Process -Id $recordedPid -ErrorAction SilentlyContinue
        $owned = @(Get-ItlOnDemandOwnedTestClientProcesses -RuntimeState $runtimeState)
        if ($null -ne $recordedProcess -and $owned.Count -eq 0) {
            throw "ITL_ONDEMAND_OWNERSHIP_MISMATCH: refusing to reuse or stop unverified TestClient PID $recordedPid for vanessa-ui/$InstanceId."
        }
        if ($owned.Count -eq 1 -and (Test-TcpPortOpen -Port $testClientPort)) {
            $runtimeState = Set-ItlOnDemandRuntimeStateValues -RuntimeState $runtimeState -Values @{
                schemaVersion = 4
                testClientState = "port-ready"
                testClientReused = $true
                previousTestClientPid = 0
                previousTestClientState = ""
            }
            Write-ItlOnDemandRuntimeState -RuntimeState $runtimeState | Out-Null
            return $runtimeState
        }
        if ($owned.Count -eq 1) {
            Stop-Process -Id $recordedPid -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 500
            if ($null -ne (Get-Process -Id $recordedPid -ErrorAction SilentlyContinue)) {
                throw "ITL_ONDEMAND_STOP_FAILED: owned TestClient PID $recordedPid is still running."
            }
        }
        $previousPid = $recordedPid
        $previousState = "exited"
        $runtimeState = Set-ItlOnDemandRuntimeStateValues -RuntimeState $runtimeState -Values @{
            schemaVersion = 4
            testClientState = "exited"
            testClientPid = 0
            testClientProcessStartTime = ""
            testClientExecutablePath = ""
            testClientOwnershipMarkers = @()
            testClientLogPath = ""
        }
        Write-ItlOnDemandRuntimeState -RuntimeState $runtimeState | Out-Null
    }

    $managerPid = ConvertTo-IntOrDefault -Value (Get-ConfigValueFromObject -Object $runtimeState -Path "pid" -Default 0) -Default 0
    if ((Test-VanessaTestPortOwnedByState -State $state -Port $testClientPort -ExcludeProcessId $managerPid) -or
        (Test-VanessaTestPortUsedByForeignProcess -State $state -Port $testClientPort -ExcludeProcessId $managerPid)) {
        throw "ITL_ONDEMAND_OWNERSHIP_MISMATCH: TestClient port $testClientPort is used by an unregistered process; it was not claimed or stopped."
    }
    $testClientResult = $null
    try {
        $testClientResult = Start-EnterpriseBackground `
            -InfoBasePath $state.devBranchInfoBasePath `
            -InfoBaseKind $state.infoBaseKind `
            -UseTestClient `
            -TestClientPort $testClientPort `
            -EnterpriseArgs @()
        $process = Get-Process -Id $testClientResult.process.Id -ErrorAction Stop
        $platformPath = Resolve-Agent1cFullPath -Path $testClientResult.executablePath
        $runtimeState = Set-ItlOnDemandRuntimeStateValues -RuntimeState $runtimeState -Values @{
            schemaVersion = 4
            testClientState = "process-started"
            testClientPid = $process.Id
            testClientProcessStartTime = $process.StartTime.ToUniversalTime().ToString("o")
            testClientExecutablePath = $platformPath
            testClientOwnershipMarkers = @([string]$state.devBranchInfoBasePath, "/TESTCLIENT", "-TPort $testClientPort")
            testClientLogPath = $testClientResult.logPath
            testClientReused = $false
            previousTestClientPid = $previousPid
            previousTestClientState = $previousState
        }
        Write-ItlOnDemandRuntimeState -RuntimeState $runtimeState | Out-Null
        if (-not (Wait-ItlOnDemandTestClientPortReady -Process $process -Port $testClientPort -TimeoutSeconds 120)) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            $runtimeState = Set-ItlOnDemandRuntimeStateValues -RuntimeState $runtimeState -Values @{
                testClientState = "exited"
            }
            Write-ItlOnDemandRuntimeState -RuntimeState $runtimeState | Out-Null
            if (Test-ItlOnDemandVanessaPlatformLicenseUnavailableLog -Path $testClientResult.logPath) {
                throw "ITL_VANESSA_PLATFORM_LICENSE_UNAVAILABLE: TestClient exited during startup and its safe log markers report an unavailable platform license."
            }
            throw "ITL_VANESSA_TESTCLIENT_NOT_CONNECTED: owned TestClient process did not open port $testClientPort. Log: $($testClientResult.logPath)"
        }
        Set-ItlOnDemandManagedPortLeaseStatus `
            -Family ([string](Get-ConfigValueFromObject -Object $runtimeState -Path "testClientPortFamily" -Default "")) `
            -Key ([string](Get-ConfigValueFromObject -Object $runtimeState -Path "testClientPortKey" -Default "")) `
            -LeaseToken ([string](Get-ConfigValueFromObject -Object $runtimeState -Path "testClientPortLeaseToken" -Default "")) `
            -Status "running" `
            -ProcessId $process.Id
        $runtimeState = Set-ItlOnDemandRuntimeStateValues -RuntimeState $runtimeState -Values @{
            testClientState = "port-ready"
        }
        Write-ItlOnDemandRuntimeState -RuntimeState $runtimeState | Out-Null
        return $runtimeState
    } catch {
        if ($null -ne $testClientResult -and $null -ne $testClientResult.process) {
            Stop-Process -Id $testClientResult.process.Id -Force -ErrorAction SilentlyContinue
        }
        throw
    }
}

function Start-ItlOnDemandBackendInstance {
    param([string]$Family, [string]$InstanceId, [string]$CatalogSha256)

    $existing = Read-ItlOnDemandRuntimeState -Family $Family -InstanceId $InstanceId
    if ($null -ne $existing -and (Test-ItlOnDemandOwnedProcess -RuntimeState $existing) -and (Test-TcpPortOpen -Port ([int]$existing.port))) {
        if (-not (Test-ItlOnDemandPortOwnedByProcess -Port ([int]$existing.port) -ProcessId ([int]$existing.pid))) {
            throw "ITL_ONDEMAND_READINESS_IDENTITY_UNVERIFIED: registered backend port is not owned by its PID; state and leases were retained."
        }
        if ([string]$existing.status -ne "running") {
            $existing = Set-ItlOnDemandRuntimeStateValues -RuntimeState $existing -Values ([ordered]@{
                status = "readiness"
                readiness = "tcp-port-owner-verified"
                readinessAt = (Get-Date).ToUniversalTime().ToString("o")
                portOwnerPidVerified = $true
            })
            Write-ItlOnDemandRuntimeState -RuntimeState $existing | Out-Null
        }
        return $existing
    }
    if ($null -ne $existing) { Stop-ItlOnDemandBackendInstance -Family $Family -InstanceId $InstanceId -StrictOwnership | Out-Null }
    $state = Read-CurrentDevBranchStateForRoctupMcp -Operation "ITL on-demand MCP"
    $state = Ensure-DevBranchEnterpriseNormalized -State $state -Reason "legacy-preflight"
    $portFamily = Get-ItlOnDemandPortFamily -Family $Family
    $key = Get-ItlOnDemandPortKey -Family $Family -State $state -InstanceId $InstanceId
    $port = 0
    $testClientPort = 0
    $testClientPortFamily = ""
    $testClientPortKey = ""
    $portLeaseToken = New-ItlManagedPortLeaseToken
    $testClientPortLeaseToken = ""
    $vanessaParamsPath = ""
    $version = ""
    $url = ""
    $runtimeState = $null
    $runtimeStatePersisted = $false
    $result = $null
    try {
        if ($Family -eq "roctup") {
            $artifact = Install-RoctupMcpArtifact
            $range = Get-RoctupMcpPortRange
            $portLease = Resolve-ItlManagedPortLease -Family $portFamily -Key $key -Start $range.start -End $range.end -State $state -Subject "ROCTUP on-demand MCP port" -LeaseToken $portLeaseToken
            $port = [int]$portLease.port
            $portLeaseToken = [string]$portLease.leaseToken
            $url = Get-RoctupMcpUrl -Port $port
            $version = [string]$artifact.version
        } else {
            if (-not [bool](Get-StateValue -State $state -Name "unsafeActionProtectionConfirmed" -Default $false)) {
                throw "ITL_VANESSA_UNSAFE_ACTION_PROTECTION_UNCONFIRMED: run configure-dev-branch-unsafe-action-protection for this worktree."
            }
            $state = Ensure-VanessaMcpInstalled -State $state
            $serviceInfoBase = Ensure-VanessaServiceInfoBase -State $state
            $state = Read-DevBranchState -Name (Get-StateValue -State $state -Name "devBranchName" -Default "")
            $vanessa = Get-VanessaAutomationState
            if (-not $vanessa.ready) { throw "Vanessa Automation runtime is not installed." }
            $range = Get-VanessaMcpPortRange
            $portLease = Resolve-ItlManagedPortLease -Family $portFamily -Key $key -Start $range.start -End $range.end -State $state -Subject "Vanessa on-demand MCP port" -LeaseToken $portLeaseToken
            $port = [int]$portLease.port
            $portLeaseToken = [string]$portLease.leaseToken
            $testClientPortFamily = "vanessa-mcp-testclient"
            $testClientPortKey = Get-ItlOnDemandVanessaTestClientPortKey -State $state -InstanceId $InstanceId
            $testClientPortLeaseToken = New-ItlManagedPortLeaseToken
            $testRange = Get-ItlOnDemandVanessaTestClientPortRange
            $testClientPortLease = Resolve-ItlManagedPortLease -Family $testClientPortFamily -Key $testClientPortKey -Start $testRange.start -End $testRange.end -State $state -Subject "Vanessa on-demand TestClient port" -LeaseToken $testClientPortLeaseToken
            $testClientPort = [int]$testClientPortLease.port
            $testClientPortLeaseToken = [string]$testClientPortLease.leaseToken
            $vanessaParamsPath = New-ItlOnDemandVanessaParamsFile -State $state -InstanceId $InstanceId -TestClientPort $testClientPort -VanessaVersion ([string]$vanessa.version)
            $url = Get-VanessaMcpUrl -Port $port
            $command = "runMcp;mcpPort=$port;VAParams=$vanessaParamsPath;QuietInstallVanessaExt;DisableFirstRunHelper;UseEditor=true;usevanessaeditor=true"
            $clientVersion = [string](Get-StateValue -State $state -Name "vanessaMcpClientMcpVersion" -Default "")
            $vaVersion = [string](Get-StateValue -State $state -Name "vanessaMcpVaExtensionVersion" -Default "")
            $definition = Get-ItlOnDemandMcpFamilyDefinition -Family "vanessa-ui"
            $automationVersion = [string](Get-ConfigValueFromObject -Object $definition.backendVersions -Path "vanessaAutomation" -Default $vanessa.version)
            $extVersion = [string](Get-ConfigValueFromObject -Object $definition.backendVersions -Path "vanessaExt" -Default "")
            $version = "clientMcp=$clientVersion;vaExtension=$vaVersion;vanessaAutomation=$automationVersion;vanessaExt=$extVersion"
            $vanessaSafeModeProof = Get-StateValue -State $state -Name "vanessaMcpSafeModeProof" -Default $null
        }
        $runtimeState = [pscustomobject][ordered]@{
            schemaVersion = 4; status = "starting"; family = $Family; instanceId = $InstanceId
            pid = 0; processStartTime = ""; executablePath = ""
            ownershipMarkers = @($(if ($Family -eq "vanessa-ui") { [string]$serviceInfoBase.path } else { [string]$state.devBranchInfoBasePath }), "port=$port")
            portFamily = $portFamily; portKey = $key; portLeaseToken = $portLeaseToken
            port = $port; url = $url; backendVersion = $version; catalogSha256 = $CatalogSha256
            readiness = "not-started"; readinessAt = ""; runningAt = ""; portOwnerPidVerified = $false
            vanessaAutomationCompatibilityVersion = $(if ($Family -eq "vanessa-ui") { [string]$vanessa.version } else { "" })
            vanessaAutomationDownstreamRevision = $(if ($Family -eq "vanessa-ui") { [string]$vanessa.downstreamRevision } else { "" })
            vanessaAutomationArchiveSha256 = $(if ($Family -eq "vanessa-ui") { [string]$vanessa.archiveSha256 } else { "" })
            vanessaAutomationEpfSha256 = $(if ($Family -eq "vanessa-ui") { [string]$vanessa.epfSha256 } else { "" })
            clientMcpSafeMode = $(if ($Family -eq "vanessa-ui") { [bool](Get-StateValue -State $vanessaSafeModeProof -Name "clientMcpSafeMode" -Default $true) } else { $null })
            vaExtensionSafeMode = $(if ($Family -eq "vanessa-ui") { [bool](Get-StateValue -State $vanessaSafeModeProof -Name "vaExtensionSafeMode" -Default $true) } else { $null })
            infoBasePath = [string]$state.devBranchInfoBasePath
            managerInfoBaseKind = $(if ($Family -eq "vanessa-ui") { [string]$serviceInfoBase.kind } else { [string]$state.infoBaseKind })
            managerInfoBasePath = $(if ($Family -eq "vanessa-ui") { [string]$serviceInfoBase.path } else { [string]$state.devBranchInfoBasePath })
            testClientProfile = $(if ($Family -eq "vanessa-ui") { "itl-ondemand" } else { "" })
            testClientPortFamily = $testClientPortFamily; testClientPortKey = $testClientPortKey; testClientPortLeaseToken = $testClientPortLeaseToken; testClientPort = $testClientPort
            testClientState = $(if ($Family -eq "vanessa-ui") { "not-started" } else { "" })
            testClientPid = 0; testClientProcessStartTime = ""; testClientExecutablePath = ""
            testClientOwnershipMarkers = @(); testClientLogPath = ""; vanessaParamsPath = $vanessaParamsPath
            logPath = ""; startingAt = (Get-Date).ToUniversalTime().ToString("o"); startedAt = ""
        }
        Write-ItlOnDemandRuntimeState -RuntimeState $runtimeState | Out-Null
        $runtimeStatePersisted = $true
        if ($Family -eq "roctup") {
            $result = Start-EnterpriseBackground -InfoBasePath $state.devBranchInfoBasePath -InfoBaseKind $state.infoBaseKind -EnterpriseArgs @("/Execute", $artifact.path, "/Cstartup;mode=embedded;port=$port")
        } else {
            $result = Start-EnterpriseBackground `
                -InfoBasePath $serviceInfoBase.path `
                -InfoBaseKind $serviceInfoBase.kind `
                -UseTestManager `
                -TestClientPort $testClientPort `
                -User $serviceInfoBase.user `
                -Password $serviceInfoBase.password `
                -EnterpriseArgs @("/Execute", $vanessa.epfPath, "/C$command")
        }
        $process = Get-Process -Id $result.process.Id -ErrorAction Stop
        $runtimeState = Set-ItlOnDemandRuntimeStateValues -RuntimeState $runtimeState -Values ([ordered]@{
            status = "process-started"
            pid = $result.process.Id
            processStartTime = $process.StartTime.ToUniversalTime().ToString("o")
            executablePath = (Resolve-Agent1cFullPath -Path $result.executablePath)
            logPath = $result.logPath
            startedAt = (Get-Date).ToUniversalTime().ToString("o")
        })
        Write-ItlOnDemandRuntimeState -RuntimeState $runtimeState | Out-Null
        Set-ItlOnDemandManagedPortLeaseStatus -Family $portFamily -Key $key -LeaseToken $portLeaseToken -Status "process-started" -ProcessId $result.process.Id
        $ready = $(if ($Family -eq "roctup") { Wait-RoctupMcpPort -Port $port -TimeoutSeconds 30 } else { Wait-VanessaMcpPort -Port $port -TimeoutSeconds 120 })
        if (-not $ready) { throw "$Family on-demand MCP did not open port $port. Log: $($result.logPath)" }
        if (-not (Test-ItlOnDemandPortOwnedByProcess -Port $port -ProcessId $result.process.Id)) {
            throw "ITL_ONDEMAND_READINESS_IDENTITY_UNVERIFIED: port $port is not proven to be owned by backend PID $($result.process.Id)."
        }
        $runtimeState = Set-ItlOnDemandRuntimeStateValues -RuntimeState $runtimeState -Values ([ordered]@{
            status = "readiness"
            readiness = "tcp-port-owner-verified"
            readinessAt = (Get-Date).ToUniversalTime().ToString("o")
            portOwnerPidVerified = $true
        })
        Write-ItlOnDemandRuntimeState -RuntimeState $runtimeState | Out-Null
        return $runtimeState
    } catch {
        $startupError = $_
        $canFinalizeCleanup = $true
        if ($null -ne $result -and $null -ne $result.process) {
            Stop-Process -Id $result.process.Id -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 500
            if ($null -ne (Get-Process -Id $result.process.Id -ErrorAction SilentlyContinue)) { $canFinalizeCleanup = $false }
        }
        if ($port -gt 0 -and (Test-TcpPortOpen -Port $port)) { $canFinalizeCleanup = $false }
        if ($testClientPort -gt 0 -and (Test-TcpPortOpen -Port $testClientPort)) { $canFinalizeCleanup = $false }
        if ($runtimeStatePersisted -and $canFinalizeCleanup) {
            try {
                Stop-ItlOnDemandBackendInstance -Family $Family -InstanceId $InstanceId -StrictOwnership | Out-Null
            } catch {
                throw "$($startupError.Exception.Message) Cleanup could not prove strict stop; runtime state and leases were retained: $($_.Exception.Message)"
            }
        } elseif (-not $runtimeStatePersisted -and $canFinalizeCleanup) {
            if ($port -gt 0) { Release-ItlOnDemandManagedPortLease -Family $portFamily -Key $key -LeaseToken $portLeaseToken }
            if ($testClientPortFamily -and $testClientPortKey) { Release-ItlOnDemandManagedPortLease -Family $testClientPortFamily -Key $testClientPortKey -LeaseToken $testClientPortLeaseToken }
            if ($vanessaParamsPath -and (Test-Path -LiteralPath $vanessaParamsPath -PathType Leaf)) {
                Remove-Item -LiteralPath $vanessaParamsPath -Force -ErrorAction SilentlyContinue
            }
        }
        if (-not $canFinalizeCleanup) {
            throw "$($startupError.Exception.Message) Cleanup could not prove process exit and closed ports; runtime state and leases were retained."
        }
        throw $startupError
    }
}

function Invoke-ItlOnDemandBackendBroker {
    param(
        [ValidateSet("ensure", "ensure-test-client", "mark-running", "recover", "stop", "stop-all")][string]$Operation,
        [ValidateSet("roctup", "vanessa-ui")][string]$Family,
        [string]$InstanceId,
        [string]$CatalogSha256,
        [string]$ReplacementInstanceId,
        [int]$ExpectedPid,
        [int]$ExpectedPort
    )
    $startHandle = $null
    if ($Operation -eq "ensure" -or $Operation -eq "ensure-test-client" -or $Operation -eq "mark-running" -or $Operation -eq "recover") {
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
    } elseif ($Operation -eq "ensure-test-client") {
        if ($Family -ne "vanessa-ui") {
            throw "ITL_ONDEMAND_ARGUMENTS_INVALID: ensure-test-client is available only for vanessa-ui."
        }
        $result = Ensure-ItlOnDemandVanessaTestClient -InstanceId $InstanceId
    } elseif ($Operation -eq "mark-running") {
        if ($ExpectedPid -le 0 -or $ExpectedPort -le 0) {
            throw "Invalid on-demand MCP readiness identity."
        }
        $result = Confirm-ItlOnDemandBackendRunning -Family $Family -InstanceId $InstanceId -ExpectedPid $ExpectedPid -ExpectedPort $ExpectedPort -CatalogSha256 $CatalogSha256
    } elseif ($Operation -eq "recover") {
        if ($ReplacementInstanceId -notmatch '^[a-f0-9]{32}$' -or $ReplacementInstanceId -eq $InstanceId -or $ExpectedPid -le 0 -or $ExpectedPort -le 0) {
            throw "Invalid on-demand MCP recovery identity."
        }
        $result = Recover-ItlOnDemandBackendInstance `
            -Family $Family `
            -InstanceId $InstanceId `
            -ReplacementInstanceId $ReplacementInstanceId `
            -ExpectedPid $ExpectedPid `
            -ExpectedPort $ExpectedPort `
            -CatalogSha256 $CatalogSha256
    } else {
        $result = Stop-ItlOnDemandBackendInstance -Family $Family -InstanceId $InstanceId -StrictOwnership
    }
    } finally {
        if ($null -ne $startHandle) { $startHandle.Dispose() }
    }
    $json = $result | ConvertTo-Json -Compress -Depth 20
    Write-Output "ITL_ONDEMAND_RESULT=$json"
}

function Test-ItlOnDemandInfoBaseMatch {
    param(
        [AllowNull()][string]$First,
        [AllowNull()][string]$Second
    )
    if ([string]::IsNullOrWhiteSpace($First) -or [string]::IsNullOrWhiteSpace($Second)) {
        return $false
    }
    $firstText = $First.Trim().TrimEnd('\', '/')
    $secondText = $Second.Trim().TrimEnd('\', '/')
    if ([string]::Equals($firstText, $secondText, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    if ([System.IO.Path]::IsPathRooted($firstText) -and [System.IO.Path]::IsPathRooted($secondText)) {
        try {
            return [string]::Equals(
                (Resolve-Agent1cFullPath -Path $firstText),
                (Resolve-Agent1cFullPath -Path $secondText),
                [System.StringComparison]::OrdinalIgnoreCase
            )
        } catch {
            return $false
        }
    }
    return $false
}

function Get-ItlOnDemandRuntimeInstances {
    param([switch]$Strict)
    $root = Get-ItlOnDemandRuntimeRoot
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return @() }
    $items = @()
    foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -File -Filter "*.json" -ErrorAction SilentlyContinue) {
        if ($file.Name -notmatch '^[a-f0-9]{32}\.json$') { continue }
        try {
            $items += (Read-Utf8Text -Path $file.FullName | ConvertFrom-Json)
        } catch {
            if ($Strict) {
                throw "ITL_ONDEMAND_RUNTIME_STATE_INVALID path='$($file.FullName)' error='$($_.Exception.Message)'"
            }
        }
    }
    return @($items)
}

function Stop-ItlOnDemandBackends {
    param(
        [string]$Family = "",
        [string]$InfoBasePath = "",
        [switch]$Strict
    )
    foreach ($item in @(Get-ItlOnDemandRuntimeInstances -Strict)) {
        if ($Family -and [string]$item.family -ne $Family) { continue }
        if ($InfoBasePath -and -not (Test-ItlOnDemandInfoBaseMatch -First ([string]$item.infoBasePath) -Second $InfoBasePath)) { continue }
        Stop-ItlOnDemandBackendInstance -Family ([string]$item.family) -InstanceId ([string]$item.instanceId) -StrictOwnership | Out-Null
    }
    $remaining = @(Get-ItlOnDemandRuntimeInstances -Strict | Where-Object {
        (-not $Family -or [string]$_.family -eq $Family) -and
        (-not $InfoBasePath -or (Test-ItlOnDemandInfoBaseMatch -First ([string]$_.infoBasePath) -Second $InfoBasePath))
    })
    if ($remaining.Count -gt 0) {
        $identities = @($remaining | ForEach-Object { "$([string]$_.family)/$([string]$_.instanceId)" })
        throw "ITL_ONDEMAND_DRAIN_FAILED remaining='$($identities -join ',')' infoBasePath='$InfoBasePath'"
    }
}

function Remove-ItlOnDemandStaleInstances {
    $removed = 0
    foreach ($item in @(Get-ItlOnDemandRuntimeInstances -Strict)) {
        $health = Get-ItlOnDemandBackendRuntimeHealth -RuntimeState $item
        if (-not $health.stale) { continue }
        Stop-ItlOnDemandBackendInstance -Family ([string]$item.family) -InstanceId ([string]$item.instanceId) -StrictOwnership | Out-Null
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
        $children = @(Get-ItlOnDemandOwnedTestClientProcesses -RuntimeState $item)
        $testClientText = $(if ([int]$item.testClientPort -gt 0) { " testClientPid=$(if ($children.Count -gt 0) { $children[0].process.Id } else { 0 }) testClientPort=$($item.testClientPort)" } else { "" })
        Write-Host "${Indent}  $($item.family)/$($item.instanceId): $(if ($alive) { 'running' } else { 'stale' }) pid=$($item.pid) port=$($item.port)$testClientText log=$($item.logPath)"
    }
}
