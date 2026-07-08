function ConvertTo-ItlBranchMcpSafeSegment {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return "default"
    }

    try {
        return (ConvertTo-SafeName $Value)
    } catch {
        $safe = ([string]$Value).ToLowerInvariant() -replace '[^a-z0-9._-]+', '-'
        $safe = $safe.Trim("-")
        if (-not $safe) {
            return "default"
        }
        return $safe
    }
}

function Get-ItlBranchMcpProjectSegment {
    $leaf = Split-Path -Leaf $script:ProjectRoot
    return (ConvertTo-ItlBranchMcpSafeSegment $leaf)
}

function Get-ItlBranchMcpStateSafeName {
    param([object]$State)

    $safeName = Get-StateValue -State $State -Name "safeDevBranchName" -Default ""
    if ($safeName) {
        return (ConvertTo-ItlBranchMcpSafeSegment $safeName)
    }

    $devBranchName = Get-StateValue -State $State -Name "devBranchName" -Default "dev-branch"
    return (ConvertTo-ItlBranchMcpSafeSegment $devBranchName)
}

function Get-RoctupMcpEnabled {
    return (ConvertTo-YesNoBool -Value (Get-EnvValue -Name "ROCTUP_MCP_ENABLED" -Default "true") -Default $true)
}

function Get-RoctupMcpAutoStart {
    return (ConvertTo-YesNoBool -Value (Get-EnvValue -Name "ROCTUP_MCP_AUTO_START" -Default "true") -Default $true)
}

function Get-RoctupMcpRequired {
    return (ConvertTo-YesNoBool -Value (Get-EnvValue -Name "ROCTUP_MCP_REQUIRED" -Default "false") -Default $false)
}

function Get-VanessaMcpAutoStart {
    return (ConvertTo-YesNoBool -Value (Get-EnvValue -Name "VANESSA_MCP_AUTO_START" -Default "true") -Default $true)
}

function Get-RoctupMcpInstallRoot {
    $value = Get-Setting -EnvName "ROCTUP_MCP_INSTALL_ROOT" -ConfigName "roctupMcpToolkit.installRoot" -Default ".agent-1c/tools/roctup-mcp-toolkit"
    return (Resolve-ProjectPath ([string]$value))
}

function Get-RoctupMcpConfiguredEpfPath {
    $value = Get-Setting -EnvName "ROCTUP_MCP_TOOLKIT_EPF" -ConfigName "roctupMcpToolkit.epfPath" -Default ""
    if (-not $value) {
        return ""
    }

    $path = [Environment]::ExpandEnvironmentVariables(([string]$value).Trim())
    if (-not [System.IO.Path]::IsPathRooted($path)) {
        $path = Resolve-ProjectPath $path
    }
    if (Test-Path -LiteralPath $path -PathType Leaf -ErrorAction SilentlyContinue) {
        return [System.IO.Path]::GetFullPath($path)
    }
    return ""
}

function Get-RoctupMcpAssetName {
    $isLinux = $false
    try {
        $isLinux = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Linux)
    } catch {
        $isLinux = $false
    }

    if ($isLinux) {
        return "MCP_Toolkit_linux.epf"
    }
    if (-not [Environment]::Is64BitOperatingSystem) {
        return "MCP_Toolkit_x86.epf"
    }
    return "MCP_Toolkit.epf"
}

function Find-RoctupMcpEpf {
    $configured = Get-RoctupMcpConfiguredEpfPath
    if ($configured) {
        return $configured
    }

    $installRoot = Get-RoctupMcpInstallRoot
    foreach ($assetName in @((Get-RoctupMcpAssetName), "MCP_Toolkit.epf", "MCP_Toolkit_x86.epf", "MCP_Toolkit_linux.epf")) {
        $path = Join-Path $installRoot $assetName
        if (Test-Path -LiteralPath $path -PathType Leaf -ErrorAction SilentlyContinue) {
            return [System.IO.Path]::GetFullPath($path)
        }
    }
    return ""
}

function Get-RoctupMcpPortRange {
    $range = [string](Get-EnvValue -Name "ROCTUP_MCP_PORT_RANGE" -Default "")
    if ($range -match '^\s*(\d+)\s*(?:\.\.|-|:)\s*(\d+)\s*$') {
        $start = [int]$matches[1]
        $end = [int]$matches[2]
    } else {
        $start = ConvertTo-IntOrDefault -Value (Get-EnvValue -Name "ROCTUP_MCP_PORT_START" -Default 6003) -Default 6003
        $end = ConvertTo-IntOrDefault -Value (Get-EnvValue -Name "ROCTUP_MCP_PORT_END" -Default 6102) -Default 6102
    }

    if ($start -lt 1 -or $end -gt 65535 -or $start -gt $end) {
        throw "Invalid ROCTUP MCP port range: $start..$end"
    }

    return [pscustomobject]@{
        start = $start
        end = $end
    }
}

function Get-RoctupMcpUrl {
    param([int]$Port)
    return "http://127.0.0.1:$Port/mcp"
}

function Get-RoctupMcpHealthUrl {
    param([int]$Port)
    return "http://127.0.0.1:$Port/health"
}

function Get-RoctupMcpReleaseAssetInfo {
    $assetName = Get-RoctupMcpAssetName
    if ((Get-DependencyMode) -eq "locked") {
        $locked = Get-DependencyLockEntry -Name "roctupMcpToolkit"
        $version = [string](Get-ConfigValueFromObject -Object $locked -Path "version" -Default "")
        $lockedAssetName = [string](Get-ConfigValueFromObject -Object $locked -Path "assetName" -Default "")
        $url = [string](Get-ConfigValueFromObject -Object $locked -Path "url" -Default "")
        $sha256 = [string](Get-ConfigValueFromObject -Object $locked -Path "sha256" -Default "")
        if (-not $version -or -not $lockedAssetName -or -not $url -or -not $sha256) {
            throw "Dependency mode is locked, but roctupMcpToolkit.version, assetName, url, and sha256 must all be set in .agent-1c/dependency-lock.json."
        }
        return [pscustomobject]@{
            url = $url
            name = $lockedAssetName
            version = $version
            expectedSha256 = $sha256
            source = "dependency-lock"
        }
    }

    $asset = Get-GitHubReleaseAssetInfo `
        -Repository "ROCTUP/1c-mcp-toolkit" `
        -AssetNameLike $assetName `
        -OverrideEnvName "ROCTUP_MCP_TOOLKIT_EPF_URL" `
        -DefaultFileName $assetName
    $asset | Add-Member -NotePropertyName expectedSha256 -NotePropertyValue "" -Force
    return $asset
}

function Save-RoctupMcpArtifact {
    param([object]$AssetInfo)

    $installRoot = Get-RoctupMcpInstallRoot
    New-Item -ItemType Directory -Force -Path $installRoot | Out-Null
    $targetPath = Join-Path $installRoot ([string]$AssetInfo.name)
    $source = [string]$AssetInfo.url

    Write-Host "ROCTUP MCP artifact source: $source"
    $localSource = ConvertFrom-FileUri -Value $source
    if (Test-Path -LiteralPath $localSource -PathType Leaf -ErrorAction SilentlyContinue) {
        Copy-Item -LiteralPath $localSource -Destination $targetPath -Force
    } else {
        Invoke-WebRequest -Uri $source -UseBasicParsing -OutFile $targetPath
    }

    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $targetPath).Hash.ToLowerInvariant()
    Write-Host "ROCTUP MCP artifact SHA256: $hash"

    $expected = [string](Get-ConfigValueFromObject -Object $AssetInfo -Path "expectedSha256" -Default "")
    if ($expected) {
        $expected = $expected.ToLowerInvariant()
        if ($hash -eq $expected) {
            Write-Host "ROCTUP MCP artifact hash matches dependency lock."
        } elseif ((Get-DependencyMode) -eq "locked") {
            throw "ROCTUP MCP artifact SHA256 mismatch in locked dependency mode. Expected $expected, got $hash."
        } else {
            Write-Host "[WARN] ROCTUP MCP artifact hash differs from expected metadata. Actual SHA256 is logged above."
        }
    }

    Update-DependencyLockEntry -Name "roctupMcpToolkit" -Values @{
        version = [string]$AssetInfo.version
        assetName = [string]$AssetInfo.name
        url = $source
        sha256 = $hash
        source = [string]$AssetInfo.source
    }

    return [pscustomobject]@{
        path = $targetPath
        version = [string]$AssetInfo.version
        assetName = [string]$AssetInfo.name
        sha256 = $hash
        source = [string]$AssetInfo.source
    }
}

function Install-RoctupMcpSkillsDirectory {
    param(
        [string]$Version,
        [string]$InstallRoot,
        [string]$RepoRelativePath = "skills",
        [string]$TargetRelativePath = ""
    )

    $ref = if ($Version) { $Version } else { "main" }
    $escapedPath = [System.Uri]::EscapeDataString($RepoRelativePath).Replace("%2F", "/")
    $escapedRef = [System.Uri]::EscapeDataString($ref)
    $uri = "https://api.github.com/repos/ROCTUP/1c-mcp-toolkit/contents/$escapedPath`?ref=$escapedRef"
    $items = @(Invoke-RestMethod -Uri $uri -Headers @{ "User-Agent" = "1c-agent-workflow" })
    foreach ($item in $items) {
        if ([string]$item.type -eq "dir") {
            $childTarget = if ($TargetRelativePath) { Join-Path $TargetRelativePath ([string]$item.name) } else { [string]$item.name }
            Install-RoctupMcpSkillsDirectory -Version $Version -InstallRoot $InstallRoot -RepoRelativePath ([string]$item.path) -TargetRelativePath $childTarget
            continue
        }
        if ([string]$item.type -ne "file") {
            continue
        }

        $targetRelative = if ($TargetRelativePath) { Join-Path $TargetRelativePath ([string]$item.name) } else { [string]$item.name }
        $targetPath = Join-Path (Join-Path $InstallRoot "skills") $targetRelative
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $targetPath) | Out-Null
        Invoke-WebRequest -Uri ([string]$item.download_url) -UseBasicParsing -OutFile $targetPath
    }
}

function Install-RoctupMcpSkillsBestEffort {
    param(
        [string]$Version,
        [string]$InstallRoot
    )

    try {
        Install-RoctupMcpSkillsDirectory -Version $Version -InstallRoot $InstallRoot
        Write-Host "ROCTUP MCP skills cached under: $(Join-Path $InstallRoot 'skills')"
    } catch {
        Write-Warning "Could not cache ROCTUP MCP skills. The EPF is installed, but on-demand ROCTUP skill references may be unavailable until the next update-roctup-mcp. $($_.Exception.Message)"
    }
}

function Save-RoctupMcpInstallSettingsToDotEnv {
    param(
        [string]$EpfPath,
        [string]$Version = "",
        [string]$Sha256 = ""
    )

    Set-DotEnvValues -Values @{
        ROCTUP_MCP_TOOLKIT_EPF = $EpfPath
        ROCTUP_MCP_VERSION = $Version
        ROCTUP_MCP_SHA256 = $Sha256
    }
    Import-DotEnv -Path (Join-Path $script:ProjectRoot ".dev.env") -Overwrite
}

function Install-RoctupMcpArtifact {
    param([switch]$ForceDownload)

    $existingEpf = Find-RoctupMcpEpf
    if ($existingEpf -and -not $ForceDownload) {
        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $existingEpf).Hash.ToLowerInvariant()
        if ((Get-DependencyMode) -eq "locked") {
            $locked = Get-DependencyLockEntry -Name "roctupMcpToolkit"
            $expected = [string](Get-ConfigValueFromObject -Object $locked -Path "sha256" -Default "")
            if (-not $expected) {
                throw "Dependency mode is locked, but roctupMcpToolkit.sha256 is empty in .agent-1c/dependency-lock.json."
            }
            if ($hash -ne $expected.ToLowerInvariant()) {
                throw "ROCTUP MCP artifact SHA256 mismatch in locked dependency mode. Expected $expected, got $hash. Artifact: $existingEpf"
            }
        }

        $version = [string](Get-Setting -EnvName "ROCTUP_MCP_VERSION" -ConfigName "roctupMcpToolkit.version" -Default "")
        Save-RoctupMcpInstallSettingsToDotEnv -EpfPath $existingEpf -Version $version -Sha256 $hash
        return [pscustomobject]@{
            path = $existingEpf
            version = $version
            assetName = Split-Path -Leaf $existingEpf
            sha256 = $hash
            source = "existing artifact"
        }
    }

    $asset = Get-RoctupMcpReleaseAssetInfo
    $artifact = Save-RoctupMcpArtifact -AssetInfo $asset
    Save-RoctupMcpInstallSettingsToDotEnv -EpfPath $artifact.path -Version $artifact.version -Sha256 $artifact.sha256
    Install-RoctupMcpSkillsBestEffort -Version $artifact.version -InstallRoot (Get-RoctupMcpInstallRoot)
    return $artifact
}

function Install-RoctupMcp {
    Write-Section "Install ROCTUP MCP Toolkit"

    $artifact = Install-RoctupMcpArtifact
    Write-Host "ROCTUP MCP EPF: $($artifact.path)"
    if ($artifact.version) {
        Write-Host "ROCTUP MCP version: $($artifact.version)"
    }
}

function Update-RoctupMcp {
    Write-Section "Update ROCTUP MCP Toolkit"

    $artifact = Install-RoctupMcpArtifact -ForceDownload
    Write-Host "ROCTUP MCP EPF: $($artifact.path)"
    if ($artifact.version) {
        Write-Host "ROCTUP MCP version: $($artifact.version)"
    }
}

function Get-RoctupMcpReservedPorts {
    param([object]$CurrentState)

    $currentSafeName = Get-StateValue -State $CurrentState -Name "safeDevBranchName" -Default ""
    $ports = @{}
    foreach ($file in Get-DevBranchStateFiles) {
        try {
            $state = Read-DevBranchStateFile -Path $file.FullName
            $safeName = Get-StateValue -State $state -Name "safeDevBranchName" -Default ""
            if ($currentSafeName -and $safeName -eq $currentSafeName) {
                continue
            }

            $port = ConvertTo-IntOrDefault -Value (Get-StateValue -State $state -Name "roctupMcpPort" -Default 0)
            if ($port -gt 0) {
                $ports[$port] = $true
            }
        } catch {
        }
    }

    return $ports
}

function Resolve-RoctupMcpPort {
    param([object]$State)

    $reserved = Get-RoctupMcpReservedPorts -CurrentState $State
    $savedPort = ConvertTo-IntOrDefault -Value (Get-StateValue -State $State -Name "roctupMcpPort" -Default 0)
    $savedPid = ConvertTo-IntOrDefault -Value (Get-StateValue -State $State -Name "roctupMcpPid" -Default 0)
    $savedProcess = Get-ProcessByIdOrNull -ProcessId $savedPid

    if ($RoctupMcpPort -gt 0) {
        if ($reserved.ContainsKey($RoctupMcpPort)) {
            throw "Requested ROCTUP MCP port $RoctupMcpPort is already reserved by another development branch."
        }
        if (-not (Test-TcpPortAvailable -Port $RoctupMcpPort)) {
            throw "Requested ROCTUP MCP port $RoctupMcpPort is already occupied."
        }
        return $RoctupMcpPort
    }

    if ($savedPort -gt 0 -and -not $reserved.ContainsKey($savedPort)) {
        if ((Test-TcpPortAvailable -Port $savedPort) -or ($null -ne $savedProcess)) {
            return $savedPort
        }
    }

    $range = Get-RoctupMcpPortRange
    for ($port = $range.start; $port -le $range.end; $port++) {
        if ($reserved.ContainsKey($port)) {
            continue
        }
        if (Test-TcpPortAvailable -Port $port) {
            return $port
        }
    }

    throw "No free ROCTUP MCP port found in range $($range.start)..$($range.end). Stop another branch MCP server or override ROCTUP_MCP_PORT_RANGE."
}

function Get-RoctupMcpRuntimeInfo {
    param([object]$State)

    $pidValue = ConvertTo-IntOrDefault -Value (Get-StateValue -State $State -Name "roctupMcpPid" -Default 0)
    $port = ConvertTo-IntOrDefault -Value (Get-StateValue -State $State -Name "roctupMcpPort" -Default 0)
    $savedStatus = [string](Get-StateValue -State $State -Name "roctupMcpStatus" -Default "")
    $process = Get-ProcessByIdOrNull -ProcessId $pidValue
    $portOpen = $false
    if ($port -gt 0) {
        $portOpen = Test-TcpPortOpen -Port $port
    }

    $status = "stopped"
    if ($null -ne $process -and $portOpen) {
        $status = "running"
    } elseif ($null -ne $process) {
        $status = "process-running-port-closed"
    } elseif ($portOpen) {
        $status = "port-open-unknown-process"
    } elseif (@("failed", "skipped", "disabled") -contains $savedStatus) {
        $status = $savedStatus
    }

    return [pscustomobject]@{
        status = $status
        processAlive = ($null -ne $process)
        pid = $pidValue
        port = $port
        url = $(if ($port -gt 0) { Get-RoctupMcpUrl -Port $port } else { "" })
        healthUrl = $(if ($port -gt 0) { Get-RoctupMcpHealthUrl -Port $port } else { "" })
        portOpen = $portOpen
    }
}

function Save-RoctupMcpRuntimeSettingsToDotEnv {
    param(
        [int]$Port,
        [string]$Url,
        [string]$HealthUrl
    )

    Set-DotEnvValues -Values @{
        ROCTUP_MCP_PORT = $(if ($Port -gt 0) { [string]$Port } else { "" })
        ROCTUP_MCP_URL = $Url
        ROCTUP_MCP_HEALTH_URL = $HealthUrl
    }
    Import-DotEnv -Path (Join-Path $script:ProjectRoot ".dev.env") -Overwrite
}

function Wait-RoctupMcpPort {
    param(
        [int]$Port,
        [int]$TimeoutSeconds = 30
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-TcpPortOpen -Port $Port -TimeoutMilliseconds 500) {
            return $true
        }
        Start-Sleep -Milliseconds 500
    }

    return $false
}

function Read-CurrentDevBranchStateForRoctupMcp {
    param([string]$Operation)

    $currentBranch = Get-CurrentBranch
    if ($currentBranch -notlike "itldev/*") {
        throw "$Operation must be run from an active itldev/* development branch worktree. Current branch: $(if ($currentBranch) { $currentBranch } else { '<none>' })"
    }

    $state = Read-DevBranchState -Name ""
    Assert-CurrentProjectRootMatchesDevBranchState -State $state -Operation $Operation
    return $state
}

function Start-RoctupMcpForState {
    param(
        [object]$State,
        [switch]$Quiet
    )

    if (-not (Get-RoctupMcpEnabled)) {
        Update-DevBranchState -State $State -Updates @{
            roctupMcpStatus = "disabled"
            roctupMcpError = ""
            roctupMcpUpdatedAt = (Get-Date).ToString("o")
        }
        $state = Read-DevBranchState -Name (Get-StateValue -State $State -Name "devBranchName" -Default "")
        Write-ItlBranchMcpClientConfig -State $state
        if (-not $Quiet) {
            Write-Host "ROCTUP MCP is disabled by ROCTUP_MCP_ENABLED=false."
        }
        return $state
    }

    $runtime = Get-RoctupMcpRuntimeInfo -State $State
    if ($runtime.processAlive -and $runtime.portOpen) {
        Save-RoctupMcpRuntimeSettingsToDotEnv -Port $runtime.port -Url $runtime.url -HealthUrl $runtime.healthUrl
        Update-DevBranchState -State $State -Updates @{
            roctupMcpStatus = "running"
            roctupMcpError = ""
            roctupMcpUpdatedAt = (Get-Date).ToString("o")
        }
        $state = Read-DevBranchState -Name (Get-StateValue -State $State -Name "devBranchName" -Default "")
        Write-ItlBranchMcpClientConfig -State $state
        if (-not $Quiet) {
            Write-Host "ROCTUP MCP process is already running for this branch."
            Write-RoctupMcpStatusLines -State $state
        }
        return $state
    }

    $artifact = Install-RoctupMcpArtifact
    $port = Resolve-RoctupMcpPort -State $State
    $url = Get-RoctupMcpUrl -Port $port
    $healthUrl = Get-RoctupMcpHealthUrl -Port $port
    Save-RoctupMcpRuntimeSettingsToDotEnv -Port $port -Url $url -HealthUrl $healthUrl
    Update-DevBranchState -State $State -Updates @{
        roctupMcpPort = $port
        roctupMcpUrl = $url
        roctupMcpHealthUrl = $healthUrl
        roctupMcpEpfPath = $artifact.path
        roctupMcpVersion = $artifact.version
        roctupMcpSha256 = $artifact.sha256
        roctupMcpStatus = "starting"
        roctupMcpError = ""
        roctupMcpUpdatedAt = (Get-Date).ToString("o")
    }
    $state = Read-DevBranchState -Name (Get-StateValue -State $State -Name "devBranchName" -Default "")

    $command = "startup;mode=embedded;port=$port"
    $result = Start-EnterpriseBackground `
        -InfoBasePath $state.devBranchInfoBasePath `
        -InfoBaseKind $state.infoBaseKind `
        -EnterpriseArgs @("/Execute", $artifact.path, "/C$command")

    Update-DevBranchState -State $state -Updates @{
        roctupMcpPort = $port
        roctupMcpUrl = $url
        roctupMcpHealthUrl = $healthUrl
        roctupMcpPid = $result.process.Id
        roctupMcpStartedAt = (Get-Date).ToString("o")
        roctupMcpLogPath = $result.logPath
        roctupMcpStatus = "starting"
        roctupMcpError = ""
        roctupMcpUpdatedAt = (Get-Date).ToString("o")
    }
    $state = Read-DevBranchState -Name (Get-StateValue -State $state -Name "devBranchName" -Default "")

    if (-not (Wait-RoctupMcpPort -Port $port -TimeoutSeconds 30)) {
        $message = "ROCTUP MCP process was started, but port $port did not become reachable within 30 seconds. PID: $($result.process.Id). Log: $($result.logPath)"
        Update-DevBranchState -State $state -Updates @{
            roctupMcpStatus = "failed"
            roctupMcpError = $message
            roctupMcpUpdatedAt = (Get-Date).ToString("o")
        }
        throw $message
    }

    Update-DevBranchState -State $state -Updates @{
        roctupMcpStatus = "running"
        roctupMcpError = ""
        roctupMcpUpdatedAt = (Get-Date).ToString("o")
    }
    $state = Read-DevBranchState -Name (Get-StateValue -State $state -Name "devBranchName" -Default "")
    Write-ItlBranchMcpClientConfig -State $state

    if (-not $Quiet) {
        Write-Host "ROCTUP MCP started."
        Write-RoctupMcpStatusLines -State $state
        Write-RoctupMcpClientSnippets -State $state
    }
    return $state
}

function Start-RoctupMcp {
    Write-Section "Start ROCTUP MCP Toolkit"

    $state = Read-CurrentDevBranchStateForRoctupMcp -Operation "start-roctup-mcp"
    Start-RoctupMcpForState -State $state | Out-Null
}

function Stop-RoctupMcpForState {
    param(
        [object]$State,
        [switch]$Quiet
    )

    $runtime = Get-RoctupMcpRuntimeInfo -State $State
    $updates = @{
        roctupMcpPid = ""
        roctupMcpStatus = "stopped"
        roctupMcpStoppedAt = (Get-Date).ToString("o")
        roctupMcpUpdatedAt = (Get-Date).ToString("o")
    }

    if ($runtime.processAlive) {
        if (-not $Quiet) {
            Write-Host "Stopping ROCTUP MCP process: PID $($runtime.pid)"
        }
        Stop-Process -Id $runtime.pid -Force -ErrorAction Stop
        Start-Sleep -Milliseconds 500
        Update-DevBranchState -State $State -Updates $updates
        $state = Read-DevBranchState -Name (Get-StateValue -State $State -Name "devBranchName" -Default "")
        Write-ItlBranchMcpClientConfig -State $state
        return $true
    }

    Update-DevBranchState -State $State -Updates $updates
    $state = Read-DevBranchState -Name (Get-StateValue -State $State -Name "devBranchName" -Default "")
    Write-ItlBranchMcpClientConfig -State $state
    if (-not $Quiet) {
        Write-Host "ROCTUP MCP is not running for this branch."
    }
    return $false
}

function Stop-RoctupMcp {
    Write-Section "Stop ROCTUP MCP Toolkit"

    $state = Read-CurrentDevBranchStateForRoctupMcp -Operation "stop-roctup-mcp"
    Stop-RoctupMcpForState -State $state | Out-Null
}

function Write-RoctupMcpClientSnippets {
    param([object]$State)

    $safeName = Get-ItlBranchMcpStateSafeName -State $State
    $project = Get-ItlBranchMcpProjectSegment
    $port = ConvertTo-IntOrDefault -Value (Get-StateValue -State $State -Name "roctupMcpPort" -Default 0)
    $url = Get-StateValue -State $State -Name "roctupMcpUrl" -Default $(if ($port -gt 0) { Get-RoctupMcpUrl -Port $port } else { "" })
    if (-not $url) {
        return
    }

    $serverName = "itl-$project-$safeName-roctup"
    Write-Host "MCP server name: $serverName"
    Write-Host "MCP streamable-http URL: $url"
}

function Write-RoctupMcpStatusLines {
    param(
        [object]$State,
        [string]$Indent = ""
    )

    $runtime = Get-RoctupMcpRuntimeInfo -State $State
    $status = Get-StateValue -State $State -Name "roctupMcpStatus" -Default ""
    if (-not $status -and $runtime.port -le 0) {
        Write-Host "${Indent}ROCTUP MCP: not configured"
        return
    }

    Write-Host "${Indent}ROCTUP MCP: $($runtime.status)"
    if ($runtime.port -gt 0) {
        Write-Host "${Indent}ROCTUP MCP port: $($runtime.port)"
        Write-Host "${Indent}ROCTUP MCP URL: $($runtime.url)"
    }
    if ($runtime.pid -gt 0) {
        Write-Host "${Indent}ROCTUP MCP PID: $($runtime.pid)"
    }
    $logPath = Get-StateValue -State $State -Name "roctupMcpLogPath" -Default ""
    if ($logPath) {
        Write-Host "${Indent}ROCTUP MCP log: $logPath"
    }
    $errorMessage = Get-StateValue -State $State -Name "roctupMcpError" -Default ""
    if ($errorMessage) {
        Write-Host "${Indent}ROCTUP MCP error: $errorMessage"
    }
}

function Show-RoctupMcpStatus {
    Write-Section "ROCTUP MCP Toolkit status"

    $state = Read-CurrentDevBranchStateForRoctupMcp -Operation "roctup-mcp-status"
    Write-RoctupMcpStatusLines -State $state
    Write-RoctupMcpClientSnippets -State $state
}

function Get-ItlBranchMcpEndpointEntries {
    param([object]$State)

    $entries = @()
    $safeName = Get-ItlBranchMcpStateSafeName -State $State
    $project = Get-ItlBranchMcpProjectSegment
    $devBranchName = Get-StateValue -State $State -Name "devBranchName" -Default $safeName

    $roctupRuntime = Get-RoctupMcpRuntimeInfo -State $State
    if ($roctupRuntime.status -eq "running" -and $roctupRuntime.url) {
        $entries += [pscustomobject]@{
            name = "itl-$project-$safeName-roctup"
            family = "roctup"
            url = $roctupRuntime.url
            timeout = 120000
            devBranchName = $devBranchName
            safeDevBranchName = $safeName
        }
    }

    $vanessaRuntime = Get-VanessaMcpRuntimeInfo -State $State
    if ($vanessaRuntime.status -eq "running" -and $vanessaRuntime.url) {
        $entries += [pscustomobject]@{
            name = "VanessaAutomation-$safeName"
            family = "vanessa"
            url = $vanessaRuntime.url
            timeout = 120000
            devBranchName = $devBranchName
            safeDevBranchName = $safeName
        }
    }

    return @($entries)
}

function Set-ItlBranchMcpManagedTextBlock {
    param(
        [string]$Path,
        [string]$Body
    )

    $start = "# >>> itl-branch-mcp"
    $end = "# <<< itl-branch-mcp"
    $text = ""
    if (Test-Path -LiteralPath $Path -PathType Leaf -ErrorAction SilentlyContinue) {
        $text = Read-Utf8Text -Path $Path
    }
    $pattern = "(?ms)^" + [regex]::Escape($start) + ".*?^" + [regex]::Escape($end) + "\r?\n?"
    $text = [regex]::Replace($text, $pattern, "")
    $block = $start + [Environment]::NewLine + $Body.TrimEnd() + [Environment]::NewLine + $end + [Environment]::NewLine
    if ($text -and -not $text.EndsWith([Environment]::NewLine)) {
        $text += [Environment]::NewLine
    }
    Write-Utf8Text -Path $Path -Value ($text + $block)
}

function Write-ItlBranchMcpCodexConfig {
    param([object[]]$Endpoints)

    $path = Join-Path $script:ProjectRoot ".codex\config.toml"
    $lines = New-Object System.Collections.ArrayList
    foreach ($endpoint in @($Endpoints | Sort-Object @{ Expression = { [string]$_.name } })) {
        if (-not $endpoint.name -or -not $endpoint.url) {
            continue
        }
        [void]$lines.Add("[mcp_servers.$(ConvertTo-Vibecoding1cMcpTomlString ([string]$endpoint.name))]")
        [void]$lines.Add("url = $(ConvertTo-Vibecoding1cMcpTomlString ([string]$endpoint.url))")
        [void]$lines.Add("enabled = true")
        [void]$lines.Add("startup_timeout_sec = 20")
        [void]$lines.Add("tool_timeout_sec = 120")
        [void]$lines.Add("")
    }

    Set-ItlBranchMcpManagedTextBlock -Path $path -Body ((@($lines) -join [Environment]::NewLine).TrimEnd())
    return $path
}

function Write-ItlBranchMcpKiloConfig {
    param([object[]]$Endpoints)

    $path = Get-Vibecoding1cMcpKiloConfigPath
    $config = [ordered]@{}
    if (Test-Path -LiteralPath $path -PathType Leaf -ErrorAction SilentlyContinue) {
        $current = Read-Utf8Text -Path $path | ConvertFrom-Json
        $config = ConvertTo-Vibecoding1cMcpHashtable -Object $current
    }

    $mcp = [ordered]@{}
    if ($config.Contains("mcp")) {
        $mcp = ConvertTo-Vibecoding1cMcpHashtable -Object $config["mcp"]
    }

    foreach ($key in @($mcp.Keys)) {
        $entry = $mcp[$key]
        $managedBy = [string](Get-Vibecoding1cMcpObjectValue -Object $entry -Name "managedBy" -Default "")
        if (@("itl-branch-mcp", "vanessa-mcp") -contains $managedBy) {
            $mcp.Remove($key)
        }
    }

    foreach ($endpoint in @($Endpoints | Sort-Object @{ Expression = { [string]$_.name } })) {
        if (-not $endpoint.name -or -not $endpoint.url) {
            continue
        }
        $mcp[[string]$endpoint.name] = [ordered]@{
            type = "remote"
            url = [string]$endpoint.url
            enabled = $true
            timeout = [int]$endpoint.timeout
            managedBy = "itl-branch-mcp"
            family = [string]$endpoint.family
            scope = "branch"
            devBranchName = [string]$endpoint.devBranchName
            safeDevBranchName = [string]$endpoint.safeDevBranchName
        }
    }

    $config["mcp"] = $mcp
    Write-Vibecoding1cMcpJsonFile -Path $path -Value $config
    return $path
}

function Write-ItlBranchMcpClientConfig {
    param([object]$State)

    Ensure-GitIgnore
    $endpoints = @(Get-ItlBranchMcpEndpointEntries -State $State)
    $codexPath = Write-ItlBranchMcpCodexConfig -Endpoints $endpoints
    $kiloPath = Write-ItlBranchMcpKiloConfig -Endpoints $endpoints
    if ($endpoints.Count -gt 0) {
        Write-Host "Branch MCP Codex config: $codexPath"
        Write-Host "Branch MCP Kilo config: $kiloPath"
    }
}

function Invoke-DevBranchDefaultMcpSetup {
    param([object]$State)

    $state = $State
    if (Get-RoctupMcpAutoStart) {
        try {
            Write-Section "Auto-start ROCTUP MCP"
            $state = Start-RoctupMcpForState -State $state -Quiet
        } catch {
            $message = $_.Exception.Message
            Write-Warning "ROCTUP MCP auto-start failed. $message"
            Update-DevBranchState -State $state -Updates @{
                roctupMcpStatus = "failed"
                roctupMcpError = $message
                roctupMcpUpdatedAt = (Get-Date).ToString("o")
            }
            if (Get-RoctupMcpRequired) {
                throw
            }
            $state = Read-DevBranchState -Name (Get-StateValue -State $state -Name "devBranchName" -Default "")
        }
    } else {
        Update-DevBranchState -State $state -Updates @{
            roctupMcpStatus = "skipped"
            roctupMcpError = ""
            roctupMcpUpdatedAt = (Get-Date).ToString("o")
        }
        $state = Read-DevBranchState -Name (Get-StateValue -State $state -Name "devBranchName" -Default "")
    }

    if (Get-VanessaMcpAutoStart) {
        try {
            Write-Section "Auto-start Vanessa MCP"
            Start-VanessaMcp
            $state = Read-DevBranchState -Name (Get-StateValue -State $state -Name "devBranchName" -Default "")
        } catch {
            $message = $_.Exception.Message
            Write-Warning "Vanessa MCP auto-start failed. $message"
            Update-DevBranchState -State $state -Updates @{
                vanessaMcpStatus = "failed"
                vanessaMcpError = $message
                vanessaMcpUpdatedAt = (Get-Date).ToString("o")
            }
            $state = Read-DevBranchState -Name (Get-StateValue -State $state -Name "devBranchName" -Default "")
        }
    } else {
        Update-DevBranchState -State $state -Updates @{
            vanessaMcpStatus = "skipped"
            vanessaMcpError = ""
            vanessaMcpUpdatedAt = (Get-Date).ToString("o")
        }
        $state = Read-DevBranchState -Name (Get-StateValue -State $state -Name "devBranchName" -Default "")
    }

    Write-ItlBranchMcpClientConfig -State $state
    return (Read-DevBranchState -Name (Get-StateValue -State $state -Name "devBranchName" -Default ""))
}

function Invoke-DevBranchMcpRestartAfterInfobaseLoad {
    param(
        [object]$State,
        [object]$LoadResult,
        [string]$Reason = "infobase load"
    )

    if (-not $LoadResult.loaded) {
        return (Read-DevBranchState -Name (Get-StateValue -State $State -Name "devBranchName" -Default ""))
    }

    $state = Read-DevBranchState -Name (Get-StateValue -State $State -Name "devBranchName" -Default "")
    $roctupRuntime = Get-RoctupMcpRuntimeInfo -State $state
    if ($roctupRuntime.processAlive) {
        Write-Host "Restarting ROCTUP MCP after $Reason."
        Stop-RoctupMcpForState -State $state -Quiet | Out-Null
        $state = Read-DevBranchState -Name (Get-StateValue -State $state -Name "devBranchName" -Default "")
        try {
            $state = Start-RoctupMcpForState -State $state -Quiet
        } catch {
            $message = $_.Exception.Message
            Write-Warning "ROCTUP MCP restart failed. $message"
            Update-DevBranchState -State $state -Updates @{
                roctupMcpStatus = "failed"
                roctupMcpError = $message
                roctupMcpUpdatedAt = (Get-Date).ToString("o")
            }
            if (Get-RoctupMcpRequired) {
                throw
            }
            $state = Read-DevBranchState -Name (Get-StateValue -State $state -Name "devBranchName" -Default "")
        }
    }

    $vanessaRuntime = Get-VanessaMcpRuntimeInfo -State $state
    if ($vanessaRuntime.processAlive) {
        Write-Host "Restarting Vanessa MCP after $Reason."
        Stop-VanessaMcpForState -State $state -Quiet | Out-Null
        try {
            Start-VanessaMcp
            $state = Read-DevBranchState -Name (Get-StateValue -State $state -Name "devBranchName" -Default "")
        } catch {
            $message = $_.Exception.Message
            Write-Warning "Vanessa MCP restart failed. $message"
            Update-DevBranchState -State $state -Updates @{
                vanessaMcpStatus = "failed"
                vanessaMcpError = $message
                vanessaMcpUpdatedAt = (Get-Date).ToString("o")
            }
            $state = Read-DevBranchState -Name (Get-StateValue -State $state -Name "devBranchName" -Default "")
        }
    }

    Write-ItlBranchMcpClientConfig -State $state
    return (Read-DevBranchState -Name (Get-StateValue -State $state -Name "devBranchName" -Default ""))
}

function Test-ItlPathUnderDirectory {
    param(
        [string]$Path,
        [string]$Directory
    )

    if (-not $Path -or -not $Directory) {
        return $false
    }

    $resolvedPath = Get-FullPathNormalized $Path
    $resolvedDir = Get-FullPathNormalized $Directory
    if (-not $resolvedPath -or -not $resolvedDir) {
        return $false
    }
    return ($resolvedPath -eq $resolvedDir -or $resolvedPath.StartsWith($resolvedDir + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase) -or $resolvedPath.StartsWith($resolvedDir + "/", [System.StringComparison]::OrdinalIgnoreCase))
}

function Assert-DevBranchToolArtifactExportGuard {
    param(
        [object]$State,
        [ValidateSet("configuration", "extension")]
        [string]$ContentKind,
        [string]$ResultPath = ""
    )

    $toolsRoot = Resolve-ProjectPath ".agent-1c/tools"
    $forbiddenNames = @("client_mcp", "VAExtension")
    if ($ContentKind -eq "extension") {
        $extensionName = Require-DevBranchExtensionName -State $State
        if ($forbiddenNames -contains $extensionName) {
            throw "Refusing to export tool extension '$extensionName'. Vanessa MCP extensions client_mcp and VAExtension are runtime tooling, not product artifacts."
        }
    }

    $pathsToCheck = @()
    if ($ResultPath) {
        $pathsToCheck += $ResultPath
    }
    $extensionExportPath = Get-StateValue -State $State -Name "extensionExportPath" -Default ""
    if ($extensionExportPath) {
        $pathsToCheck += (Resolve-ProjectPath $extensionExportPath)
    }
    foreach ($path in $pathsToCheck) {
        if (Test-ItlPathUnderDirectory -Path $path -Directory $toolsRoot) {
            throw "Refusing to export result under runtime tools directory: $path"
        }
    }

    $roctupEpf = Get-StateValue -State $State -Name "roctupMcpEpfPath" -Default ""
    if ($ResultPath -and $roctupEpf -and ((Get-FullPathNormalized $ResultPath) -eq (Get-FullPathNormalized $roctupEpf))) {
        throw "Refusing to export ROCTUP MCP EPF as a product artifact: $ResultPath"
    }
}
