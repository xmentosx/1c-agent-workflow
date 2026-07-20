function Get-Vibecoding1cMcpObjectValue {
    param(
        [AllowNull()][object]$Object,
        [string]$Name,
        [object]$Default = $null
    )

    if ($null -eq $Object) {
        return $Default
    }

    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) {
            $value = $Object[$Name]
            if ($null -ne $value -and ($value -is [array] -or ($value -is [System.Collections.IEnumerable] -and $value -isnot [string]) -or $value -is [System.Collections.IDictionary])) {
                return $value
            }
            if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) {
                return $value
            }
        }
        return $Default
    }

    $prop = $Object.PSObject.Properties[$Name]
    if ($null -ne $prop -and $null -ne $prop.Value) {
        if ($prop.Value -is [array] -or ($prop.Value -is [System.Collections.IEnumerable] -and $prop.Value -isnot [string]) -or $prop.Value -is [System.Collections.IDictionary]) {
            return $prop.Value
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$prop.Value)) {
            return $prop.Value
        }
    }

    return $Default
}

function ConvertTo-Vibecoding1cMcpArray {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) {
        return @()
    }
    if ($Value -is [array]) {
        return @($Value)
    }
    return @($Value)
}

function ConvertTo-Vibecoding1cMcpHashtable {
    param([AllowNull()][object]$Object)

    $hash = [ordered]@{}
    if ($null -eq $Object) {
        return $hash
    }

    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($key in $Object.Keys) {
            $hash[$key] = $Object[$key]
        }
        return $hash
    }

    foreach ($prop in $Object.PSObject.Properties) {
        $hash[$prop.Name] = $prop.Value
    }
    return $hash
}

function Get-Vibecoding1cMcpLocalHome {
    $override = [Environment]::GetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", "Process")
    if (-not [string]::IsNullOrWhiteSpace($override)) {
        return [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($override))
    }

    $localAppData = [Environment]::GetFolderPath("LocalApplicationData")
    if ([string]::IsNullOrWhiteSpace($localAppData)) {
        $localAppData = Join-Path ([System.IO.Path]::GetTempPath()) "ITL"
    } else {
        $localAppData = Join-Path $localAppData "ITL"
    }

    return (Join-Path (Join-Path $localAppData "MCP") "vibecoding1c")
}

function Get-Vibecoding1cMcpLocalPath {
    param([string]$Leaf)
    return (Join-Path (Get-Vibecoding1cMcpLocalHome) $Leaf)
}

function Read-Vibecoding1cMcpJsonFile {
    param(
        [string]$Path,
        [object]$Default
    )

    if (Test-Path -LiteralPath $Path -PathType Leaf -ErrorAction SilentlyContinue) {
        return (Read-Utf8Text -Path $Path | ConvertFrom-Json)
    }
    return $Default
}

function Write-Vibecoding1cMcpJsonFile {
    param(
        [string]$Path,
        [object]$Value
    )

    Write-Utf8Text -Path $Path -Value (($Value | ConvertTo-Json -Depth 20) + [Environment]::NewLine)
}

function Read-Vibecoding1cMcpState {
    $path = Get-Vibecoding1cMcpLocalPath -Leaf "state.json"
    $default = [pscustomobject]@{
        schemaVersion = 1
        version = ""
        model = $null
        servers = @()
        staleIndexes = @()
        keyHash = ""
        updatedAt = ""
    }
    return (Read-Vibecoding1cMcpJsonFile -Path $path -Default $default)
}

function Write-Vibecoding1cMcpState {
    param([object]$State)

    $stateHash = ConvertTo-Vibecoding1cMcpHashtable -Object $State
    $stateHash["schemaVersion"] = 1
    $stateHash["updatedAt"] = (Get-Date).ToString("o")
    New-Item -ItemType Directory -Force -Path (Get-Vibecoding1cMcpLocalHome) | Out-Null
    Write-Vibecoding1cMcpJsonFile -Path (Get-Vibecoding1cMcpLocalPath -Leaf "state.json") -Value $stateHash
    Write-Vibecoding1cMcpProjectState -State $stateHash
}

function Write-Vibecoding1cMcpProjectState {
    param([object]$State)

    $projectStatePath = Join-Path $script:ProjectRoot ".agent-1c\mcp\state.json"
    $context = Get-Vibecoding1cMcpScopeContext
    $servers = @()
    foreach ($server in ConvertTo-Vibecoding1cMcpArray (Get-Vibecoding1cMcpObjectValue -Object $State -Name "servers" -Default @())) {
        $scope = [string](Get-Vibecoding1cMcpObjectValue -Object $server -Name "scope" -Default "")
        if ($scope -eq "global") {
            continue
        }
        if (([string](Get-Vibecoding1cMcpObjectValue -Object $server -Name "projectSlug" -Default "")) -ne $context.projectSlug) {
            continue
        }
        $servers += $server
    }

    $payload = [ordered]@{
        schemaVersion = 1
        projectSlug = $context.projectSlug
        branchSlug = $context.branchSlug
        updatedAt = (Get-Date).ToString("o")
        model = (Get-Vibecoding1cMcpObjectValue -Object $State -Name "model" -Default $null)
        servers = $servers
        staleIndexes = (Get-Vibecoding1cMcpObjectValue -Object $State -Name "staleIndexes" -Default @())
    }

    Write-Vibecoding1cMcpJsonFile -Path $projectStatePath -Value $payload
}

function Read-Vibecoding1cMcpPortRegistry {
    $path = Get-Vibecoding1cMcpLocalPath -Leaf "ports.json"
    $default = [pscustomobject]@{
        schemaVersion = 1
        allocations = @()
        updatedAt = ""
    }
    return (Read-Vibecoding1cMcpJsonFile -Path $path -Default $default)
}

function Write-Vibecoding1cMcpPortRegistry {
    param([object]$Registry)

    $hash = ConvertTo-Vibecoding1cMcpHashtable -Object $Registry
    $hash["schemaVersion"] = 1
    $hash["updatedAt"] = (Get-Date).ToString("o")
    New-Item -ItemType Directory -Force -Path (Get-Vibecoding1cMcpLocalHome) | Out-Null
    Write-Vibecoding1cMcpJsonFile -Path (Get-Vibecoding1cMcpLocalPath -Leaf "ports.json") -Value $hash
}

function Invoke-Vibecoding1cMcpPortRegistryLock {
    param([scriptblock]$ScriptBlock)

    $localHome = Get-Vibecoding1cMcpLocalHome
    New-Item -ItemType Directory -Force -Path $localHome | Out-Null
    $lockPath = Join-Path $localHome "ports.lock"
    $stream = $null
    for ($attempt = 1; $attempt -le 50; $attempt++) {
        try {
            $stream = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            break
        } catch {
            Start-Sleep -Milliseconds 100
        }
    }
    if ($null -eq $stream) {
        throw "Cannot acquire vibecoding1c MCP port registry lock: $lockPath"
    }

    try {
        return (& $ScriptBlock)
    } finally {
        $stream.Close()
    }
}

function Get-Vibecoding1cMcpDefaultDistributionRepo {
    return "http://gitlabserv01.itland.local/root/MCP-vibecoding1c.git"
}

function Get-Vibecoding1cMcpDistributionRepo {
    $fromEnv = [string](Get-EnvValue -Name "VIBECODING1C_MCP_DISTRIBUTION_REPO" -Default "")
    if (-not [string]::IsNullOrWhiteSpace($fromEnv)) {
        return $fromEnv
    }

    return (Get-Vibecoding1cMcpDefaultDistributionRepo)
}

function Test-Vibecoding1cMcpDistributionPathOverride {
    if (-not [string]::IsNullOrWhiteSpace($McpDistributionPath)) {
        return $true
    }

    $fromEnv = [string](Get-EnvValue -Name "VIBECODING1C_MCP_DISTRIBUTION_PATH" -Default "")
    return (-not [string]::IsNullOrWhiteSpace($fromEnv))
}

function Get-Vibecoding1cMcpManagedDistributionRoot {
    return (Join-Path (Get-Vibecoding1cMcpLocalHome) "distribution")
}

function Get-Vibecoding1cMcpDistributionRoot {
    if (-not [string]::IsNullOrWhiteSpace($McpDistributionPath)) {
        return [System.IO.Path]::GetFullPath($McpDistributionPath)
    }

    $fromEnv = [string](Get-EnvValue -Name "VIBECODING1C_MCP_DISTRIBUTION_PATH" -Default "")
    if (-not [string]::IsNullOrWhiteSpace($fromEnv)) {
        return [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($fromEnv))
    }

    return (Get-Vibecoding1cMcpManagedDistributionRoot)
}

function Ensure-Vibecoding1cMcpDistribution {
    $distributionRoot = Get-Vibecoding1cMcpDistributionRoot
    if (Test-Vibecoding1cMcpDistributionPathOverride) {
        if (-not (Test-Path -LiteralPath $distributionRoot -PathType Container -ErrorAction SilentlyContinue)) {
            throw "vibecoding1c MCP distribution override path was not found: $distributionRoot"
        }
        return $distributionRoot
    }

    $repo = Get-Vibecoding1cMcpDistributionRepo
    $parent = Split-Path -Parent $distributionRoot
    New-Item -ItemType Directory -Force -Path $parent | Out-Null

    if (-not (Test-Path -LiteralPath $distributionRoot -PathType Container -ErrorAction SilentlyContinue)) {
        Write-Host "Cloning vibecoding1c MCP distribution: $repo"
        Write-Host "vibecoding1c MCP distribution path: $distributionRoot"
        Invoke-GitAt -Root $parent -Arguments @("clone", $repo, $distributionRoot)
        return $distributionRoot
    }

    if (-not (Test-Path -LiteralPath (Join-Path $distributionRoot ".git") -PathType Container -ErrorAction SilentlyContinue)) {
        throw "Managed vibecoding1c MCP distribution path exists but is not a Git checkout: $distributionRoot. Remove it or set VIBECODING1C_MCP_DISTRIBUTION_PATH."
    }

    Write-Host "Updating vibecoding1c MCP distribution: $distributionRoot"
    Invoke-GitAt -Root $distributionRoot -Arguments @("fetch", "--prune")
    $upstream = ""
    try {
        $upstream = ((Get-GitOutputAt -Root $distributionRoot -Arguments @("rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}")) -join "").Trim()
    } catch {
        $upstream = ""
    }

    if ($upstream) {
        Invoke-GitAt -Root $distributionRoot -Arguments @("merge", "--ff-only", $upstream)
    } else {
        Invoke-GitAt -Root $distributionRoot -Arguments @("pull", "--ff-only")
    }
    return $distributionRoot
}

function Get-Vibecoding1cMcpDefaultRegistryRepo {
    return "http://gitlabserv01.itland.local/root/MCP-vibecoding1c-registry.git"
}

function Get-Vibecoding1cMcpRegistryRepo {
    $fromEnv = [string](Get-EnvValue -Name "VIBECODING1C_MCP_REGISTRY_REPO" -Default "")
    if (-not [string]::IsNullOrWhiteSpace($fromEnv)) {
        return $fromEnv
    }

    $fromConfig = [string](Get-ConfigValue -Path "vibecoding1cMcp.registryRepo" -Default "")
    if (-not [string]::IsNullOrWhiteSpace($fromConfig)) {
        return $fromConfig
    }

    return (Get-Vibecoding1cMcpDefaultRegistryRepo)
}

function Test-Vibecoding1cMcpRegistryPathOverride {
    $fromEnv = [string](Get-EnvValue -Name "VIBECODING1C_MCP_REGISTRY_PATH" -Default "")
    return (-not [string]::IsNullOrWhiteSpace($fromEnv))
}

function Get-Vibecoding1cMcpManagedRegistryRoot {
    return (Join-Path (Get-Vibecoding1cMcpLocalHome) "registry")
}

function Get-Vibecoding1cMcpRegistryRoot {
    $fromEnv = [string](Get-EnvValue -Name "VIBECODING1C_MCP_REGISTRY_PATH" -Default "")
    if (-not [string]::IsNullOrWhiteSpace($fromEnv)) {
        return [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($fromEnv))
    }

    return (Get-Vibecoding1cMcpManagedRegistryRoot)
}

function Ensure-Vibecoding1cMcpRegistry {
    $registryRoot = Get-Vibecoding1cMcpRegistryRoot
    if (Test-Vibecoding1cMcpRegistryPathOverride) {
        if (-not (Test-Path -LiteralPath $registryRoot -PathType Container -ErrorAction SilentlyContinue)) {
            throw "vibecoding1c MCP registry override path was not found: $registryRoot"
        }
        return $registryRoot
    }

    $repo = Get-Vibecoding1cMcpRegistryRepo
    $parent = Split-Path -Parent $registryRoot
    New-Item -ItemType Directory -Force -Path $parent | Out-Null

    if (-not (Test-Path -LiteralPath $registryRoot -PathType Container -ErrorAction SilentlyContinue)) {
        Write-Host "Cloning vibecoding1c MCP registry: $repo"
        Write-Host "vibecoding1c MCP registry path: $registryRoot"
        Invoke-GitAt -Root $parent -Arguments @("clone", $repo, $registryRoot)
        return $registryRoot
    }

    if (-not (Test-Path -LiteralPath (Join-Path $registryRoot ".git") -PathType Container -ErrorAction SilentlyContinue)) {
        throw "Managed vibecoding1c MCP registry path exists but is not a Git checkout: $registryRoot. Remove it or set VIBECODING1C_MCP_REGISTRY_PATH."
    }

    Write-Host "Updating vibecoding1c MCP registry: $registryRoot"
    Invoke-GitAt -Root $registryRoot -Arguments @("fetch", "--prune")
    $upstream = ""
    try {
        $upstream = ((Get-GitOutputAt -Root $registryRoot -Arguments @("rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}")) -join "").Trim()
    } catch {
        $upstream = ""
    }

    if ($upstream) {
        Invoke-GitAt -Root $registryRoot -Arguments @("merge", "--ff-only", $upstream)
    } else {
        Invoke-GitAt -Root $registryRoot -Arguments @("pull", "--ff-only")
    }
    return $registryRoot
}

function Read-Vibecoding1cMcpRegistry {
    $registryPath = Join-Path (Get-Vibecoding1cMcpRegistryRoot) "registry.json"
    $default = [pscustomobject]@{
        schemaVersion = 2
        publishedAt = ""
        host = $null
        hosts = @()
        configurations = @()
        servers = @()
    }
    return (Read-Vibecoding1cMcpJsonFile -Path $registryPath -Default $default)
}

function Get-Vibecoding1cMcpRegistryHosts {
    param([object]$Registry)

    $hosts = @(ConvertTo-Vibecoding1cMcpArray (Get-Vibecoding1cMcpObjectValue -Object $Registry -Name "hosts" -Default @()))
    if ($hosts.Count -gt 0) {
        return @($hosts)
    }

    $hostInfo = Get-Vibecoding1cMcpObjectValue -Object $Registry -Name "host" -Default $null
    $hostId = [string](Get-Vibecoding1cMcpObjectValue -Object $hostInfo -Name "hostId" -Default "legacy-host")
    $baseUrl = [string](Get-Vibecoding1cMcpObjectValue -Object $hostInfo -Name "baseUrl" -Default "")
    $publishedAt = [string](Get-Vibecoding1cMcpObjectValue -Object $Registry -Name "publishedAt" -Default "")
    $configurations = @(ConvertTo-Vibecoding1cMcpArray (Get-Vibecoding1cMcpObjectValue -Object $Registry -Name "configurations" -Default @()))
    $servers = @(ConvertTo-Vibecoding1cMcpArray (Get-Vibecoding1cMcpObjectValue -Object $Registry -Name "servers" -Default @()))
    if ($configurations.Count -eq 0 -and $servers.Count -eq 0 -and -not $baseUrl) {
        return @()
    }

    return @([pscustomobject]@{
        hostId = $hostId
        baseUrl = $baseUrl
        publishedAt = $publishedAt
        configurations = $configurations
        servers = $servers
    })
}

function Copy-Vibecoding1cMcpRegistryChildHostMetadata {
    param(
        [object]$Child,
        [object]$HostEntry
    )

    $hash = ConvertTo-Vibecoding1cMcpHashtable -Object $Child
    $hostId = [string](Get-Vibecoding1cMcpObjectValue -Object $HostEntry -Name "hostId" -Default "")
    $publishedAt = [string](Get-Vibecoding1cMcpObjectValue -Object $HostEntry -Name "publishedAt" -Default "")
    $baseUrl = [string](Get-Vibecoding1cMcpObjectValue -Object $HostEntry -Name "baseUrl" -Default "")
    if (-not $hash.Contains("hostId") -or -not $hash["hostId"]) { $hash["hostId"] = $hostId }
    if (-not $hash.Contains("hostPublishedAt") -or -not $hash["hostPublishedAt"]) { $hash["hostPublishedAt"] = $publishedAt }
    if (-not $hash.Contains("publishedAt") -or -not $hash["publishedAt"]) { $hash["publishedAt"] = $publishedAt }
    if (-not $hash.Contains("hostBaseUrl") -or -not $hash["hostBaseUrl"]) { $hash["hostBaseUrl"] = $baseUrl }
    return [pscustomobject]$hash
}

function Get-Vibecoding1cMcpRegistryConfigurations {
    param([object]$Registry)

    $configurations = @()
    foreach ($hostEntry in Get-Vibecoding1cMcpRegistryHosts -Registry $Registry) {
        foreach ($configuration in ConvertTo-Vibecoding1cMcpArray (Get-Vibecoding1cMcpObjectValue -Object $hostEntry -Name "configurations" -Default @())) {
            $configurations += Copy-Vibecoding1cMcpRegistryChildHostMetadata -Child $configuration -HostEntry $hostEntry
        }
    }
    if ($configurations.Count -gt 0) {
        return @($configurations)
    }
    return @(ConvertTo-Vibecoding1cMcpArray (Get-Vibecoding1cMcpObjectValue -Object $Registry -Name "configurations" -Default @()))
}

function Get-Vibecoding1cMcpRegistryServers {
    param([object]$Registry)

    $servers = @()
    foreach ($hostEntry in Get-Vibecoding1cMcpRegistryHosts -Registry $Registry) {
        foreach ($server in ConvertTo-Vibecoding1cMcpArray (Get-Vibecoding1cMcpObjectValue -Object $hostEntry -Name "servers" -Default @())) {
            $servers += Copy-Vibecoding1cMcpRegistryChildHostMetadata -Child $server -HostEntry $hostEntry
        }
    }
    if ($servers.Count -gt 0) {
        return @($servers)
    }
    return @(ConvertTo-Vibecoding1cMcpArray (Get-Vibecoding1cMcpObjectValue -Object $Registry -Name "servers" -Default @()))
}

function Get-Vibecoding1cMcpSelectionPath {
    return (Join-Path $script:ProjectRoot ".agent-1c\mcp\vibecoding1c-selection.json")
}

function Get-Vibecoding1cMcpDefaultProvider {
    $value = [string](Get-EnvValue -Name "VIBECODING1C_MCP_PROVIDER" -Default (Get-ConfigValue -Path "vibecoding1cMcp.providerDefault" -Default "remote"))
    $normalized = $value.Trim().ToLowerInvariant()
    if ($normalized -eq "local") {
        return "local"
    }
    return "remote"
}

function Get-Vibecoding1cMcpDefaultLocalScope {
    $value = [string](Get-EnvValue -Name "VIBECODING1C_MCP_LOCAL_SCOPE" -Default (Get-ConfigValue -Path "vibecoding1cMcp.localScopeDefault" -Default "project"))
    $normalized = $value.Trim().ToLowerInvariant()
    if ($normalized -eq "branch") {
        return "branch"
    }
    return "project"
}

function Read-Vibecoding1cMcpSelection {
    $path = Get-Vibecoding1cMcpSelectionPath
    $defaultConfigId = [string](Get-EnvValue -Name "VIBECODING1C_MCP_CONFIG_ID" -Default (Get-ConfigValue -Path "vibecoding1cMcp.remoteConfigId" -Default ""))
    $defaultHostId = [string](Get-EnvValue -Name "VIBECODING1C_MCP_HOST_ID" -Default (Get-ConfigValue -Path "vibecoding1cMcp.remoteHostId" -Default ""))
    $default = [pscustomobject]@{
        schemaVersion = 1
        family = "vibecoding1c"
        defaultProvider = (Get-Vibecoding1cMcpDefaultProvider)
        remoteConfigId = $defaultConfigId
        remoteHostId = $defaultHostId
        localScopeDefault = (Get-Vibecoding1cMcpDefaultLocalScope)
        servers = @()
        updatedAt = ""
    }
    $selection = Read-Vibecoding1cMcpJsonFile -Path $path -Default $default
    $hash = ConvertTo-Vibecoding1cMcpHashtable -Object $selection
    if (-not $hash.Contains("schemaVersion")) { $hash["schemaVersion"] = 1 }
    $hash["family"] = "vibecoding1c"
    if (-not $hash.Contains("defaultProvider") -or -not $hash["defaultProvider"]) { $hash["defaultProvider"] = Get-Vibecoding1cMcpDefaultProvider }
    if (-not $hash.Contains("remoteConfigId")) { $hash["remoteConfigId"] = $defaultConfigId }
    if (-not $hash.Contains("remoteHostId")) { $hash["remoteHostId"] = $defaultHostId }
    if (-not $hash.Contains("localScopeDefault") -or -not $hash["localScopeDefault"]) { $hash["localScopeDefault"] = Get-Vibecoding1cMcpDefaultLocalScope }
    if (-not $hash.Contains("servers")) { $hash["servers"] = @() }
    return [pscustomobject]$hash
}

function Write-Vibecoding1cMcpSelection {
    param([object]$Selection)

    $hash = ConvertTo-Vibecoding1cMcpHashtable -Object $Selection
    $hash["schemaVersion"] = 1
    $hash["family"] = "vibecoding1c"
    $hash["updatedAt"] = (Get-Date).ToString("o")
    $path = Get-Vibecoding1cMcpSelectionPath
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
    Write-Vibecoding1cMcpJsonFile -Path $path -Value $hash
}

function Get-Vibecoding1cMcpSelectionEntry {
    param(
        [object]$Selection,
        [string]$ServerId
    )

    foreach ($entry in ConvertTo-Vibecoding1cMcpArray (Get-Vibecoding1cMcpObjectValue -Object $Selection -Name "servers" -Default @())) {
        if ([string](Get-Vibecoding1cMcpObjectValue -Object $entry -Name "id" -Default "") -eq $ServerId) {
            return $entry
        }
    }
    return $null
}

function Test-Vibecoding1cMcpConfigSpecificServerId {
    param([string]$Id)
    return ($Id -eq "code" -or $Id -eq "graph")
}

function Get-Vibecoding1cMcpServerScope {
    param([object]$Server)

    $id = [string](Get-Vibecoding1cMcpObjectValue -Object $Server -Name "id" -Default "")
    $scope = [string](Get-Vibecoding1cMcpObjectValue -Object $Server -Name "scope" -Default "")
    if ((Test-Vibecoding1cMcpConfigSpecificServerId -Id $id) -and ((-not $scope) -or $scope -eq "global")) {
        return "project"
    }
    if ($scope) {
        return $scope
    }
    return "global"
}

function Test-Vibecoding1cMcpServerNeedsRemoteConfig {
    param([object]$Server)

    $scope = Get-Vibecoding1cMcpServerScope -Server $Server
    $id = [string](Get-Vibecoding1cMcpObjectValue -Object $Server -Name "id" -Default "")
    return ($scope -eq "project" -or $id -eq "code" -or $id -eq "graph")
}

function Get-Vibecoding1cMcpSelectedProvider {
    param(
        [object]$Server,
        [object]$Selection
    )

    $id = [string](Get-Vibecoding1cMcpObjectValue -Object $Server -Name "id" -Default "")
    if ($id -eq "mantis") {
        return "remote"
    }
    if ($McpProvider -and ((-not $McpServerId) -or $McpServerId -eq $id)) {
        return $McpProvider
    }

    $entry = Get-Vibecoding1cMcpSelectionEntry -Selection $Selection -ServerId $id
    if ($entry) {
        $provider = [string](Get-Vibecoding1cMcpObjectValue -Object $entry -Name "provider" -Default "")
        if ($provider -eq "local" -or $provider -eq "remote") {
            return $provider
        }
    }

    $defaultProvider = [string](Get-Vibecoding1cMcpObjectValue -Object $Selection -Name "defaultProvider" -Default (Get-Vibecoding1cMcpDefaultProvider))
    if ($defaultProvider -eq "local") {
        return "local"
    }
    return "remote"
}

function Get-Vibecoding1cMcpSelectedLocalScope {
    param(
        [object]$Server,
        [object]$Selection
    )

    $id = [string](Get-Vibecoding1cMcpObjectValue -Object $Server -Name "id" -Default "")
    if ($McpLocalScope -and ((-not $McpServerId) -or $McpServerId -eq $id)) {
        return $McpLocalScope
    }

    $entry = Get-Vibecoding1cMcpSelectionEntry -Selection $Selection -ServerId $id
    if ($entry) {
        $scope = [string](Get-Vibecoding1cMcpObjectValue -Object $entry -Name "localScope" -Default "")
        if ($scope -eq "branch" -or $scope -eq "project") {
            return $scope
        }
    }

    return [string](Get-Vibecoding1cMcpObjectValue -Object $Selection -Name "localScopeDefault" -Default (Get-Vibecoding1cMcpDefaultLocalScope))
}

function Get-Vibecoding1cMcpSelectedConfigId {
    param(
        [object]$Server,
        [object]$Selection,
        [switch]$AllowPrompt
    )

    $id = [string](Get-Vibecoding1cMcpObjectValue -Object $Server -Name "id" -Default "")
    if ($McpConfigId -and ((-not $McpServerId) -or $McpServerId -eq $id)) {
        return $McpConfigId
    }

    $entry = Get-Vibecoding1cMcpSelectionEntry -Selection $Selection -ServerId $id
    if ($entry) {
        $configId = [string](Get-Vibecoding1cMcpObjectValue -Object $entry -Name "configId" -Default "")
        if ($configId) {
            return $configId
        }
    }

    if (Test-Vibecoding1cMcpServerNeedsRemoteConfig -Server $Server) {
        if (-not $AllowPrompt) {
            return ""
        }

        return (Read-Vibecoding1cMcpRemoteConfigChoice -Selection $Selection)
    }

    $selectionConfigId = [string](Get-Vibecoding1cMcpObjectValue -Object $Selection -Name "remoteConfigId" -Default "")
    if ($selectionConfigId) {
        return $selectionConfigId
    }

    return ""
}

function Get-Vibecoding1cMcpSelectedHostId {
    param(
        [object]$Server,
        [object]$Selection
    )

    $id = [string](Get-Vibecoding1cMcpObjectValue -Object $Server -Name "id" -Default "")
    if ($McpHostId -and ((-not $McpServerId) -or $McpServerId -eq $id)) {
        return $McpHostId
    }

    $entry = Get-Vibecoding1cMcpSelectionEntry -Selection $Selection -ServerId $id
    if ($entry) {
        $hostId = [string](Get-Vibecoding1cMcpObjectValue -Object $entry -Name "hostId" -Default "")
        if ($hostId) {
            return $hostId
        }
    }

    return ""
}

function Get-Vibecoding1cMcpEndpointUnavailableStatus {
    param([object]$Endpoint)

    $badStatuses = @("stopped", "missing", "unreachable", "unknown", "remote-disconnected")
    $status = ([string](Get-Vibecoding1cMcpObjectValue -Object $Endpoint -Name "status" -Default "")).Trim().ToLowerInvariant()
    if ($status -and $badStatuses -contains $status) {
        return $status
    }

    $health = ([string](Get-Vibecoding1cMcpObjectValue -Object $Endpoint -Name "health" -Default "")).Trim().ToLowerInvariant()
    if ($health -and $health -ne "unknown" -and $badStatuses -contains $health) {
        return $health
    }

    return ""
}

function Test-Vibecoding1cMcpEndpointUsableForClientConfig {
    param([object]$Endpoint)

    return -not [bool](Get-Vibecoding1cMcpEndpointUnavailableStatus -Endpoint $Endpoint)
}

function Format-Vibecoding1cMcpRemoteEndpointInfo {
    param([object]$Endpoint)

    $hostId = [string](Get-Vibecoding1cMcpObjectValue -Object $Endpoint -Name "hostId" -Default "<unknown-host>")
    $publishedAt = [string](Get-Vibecoding1cMcpObjectValue -Object $Endpoint -Name "hostPublishedAt" -Default (Get-Vibecoding1cMcpObjectValue -Object $Endpoint -Name "publishedAt" -Default ""))
    $url = [string](Get-Vibecoding1cMcpObjectValue -Object $Endpoint -Name "url" -Default "")
    $configId = [string](Get-Vibecoding1cMcpObjectValue -Object $Endpoint -Name "configId" -Default "")
    $status = [string](Get-Vibecoding1cMcpObjectValue -Object $Endpoint -Name "status" -Default "")
    $health = [string](Get-Vibecoding1cMcpObjectValue -Object $Endpoint -Name "health" -Default "")
    $configName = [string](Get-Vibecoding1cMcpObjectValue -Object $Endpoint -Name "configurationName" -Default "")
    $configVersion = [string](Get-Vibecoding1cMcpObjectValue -Object $Endpoint -Name "configurationVersion" -Default "")
    $model = [string](Get-Vibecoding1cMcpObjectValue -Object $Endpoint -Name "embeddingModel" -Default "")
    $indexedAt = [string](Get-Vibecoding1cMcpObjectValue -Object $Endpoint -Name "indexedAt" -Default "")
    $details = @("hostId=$hostId")
    if ($publishedAt) { $details += "publishedAt=$publishedAt" }
    if ($url) { $details += "url=$url" }
    if ($status) { $details += "status=$status" }
    if ($health) { $details += "health=$health" }
    if ($configId) { $details += "configId=$configId" }
    if ($configName) {
        $configurationText = $configName
        if ($configVersion) {
            $configurationText = "$configName $configVersion"
        }
        $details += "configuration=$configurationText"
    }
    if ($model) { $details += "model=$model" }
    if ($indexedAt) { $details += "indexedAt=$indexedAt" }
    $details += "freshness=$(Get-Vibecoding1cMcpEndpointFreshness -Endpoint $Endpoint)"
    return ($details -join "; ")
}

function Get-Vibecoding1cMcpAiRules1cClientName {
    param([string]$ServerId)

    switch ($ServerId) {
        "docs" { return "1C-docs-mcp" }
        "templates" { return "1c-templates-mcp" }
        "syntax" { return "1c-syntax-checker-mcp" }
        "codechecker" { return "1c-code-check-mcp" }
        "ssl" { return "1c-ssl-mcp" }
        "code" { return "1c-code-metadata-mcp" }
        "graph" { return "1c-graph-metadata-mcp" }
        "data" { return "1c-data-mcp" }
        "bookstack" { return "BookStack-product-docs-mcp" }
        "mantis" { return "itl-mantis-ticket-mcp" }
        default { return "" }
    }
}

function Get-Vibecoding1cMcpClientNames {
    param([string]$ServerId)

    $aiRules1cName = Get-Vibecoding1cMcpAiRules1cClientName -ServerId $ServerId
    if (-not $aiRules1cName) {
        return [ordered]@{}
    }
    return [ordered]@{
        aiRules1c = $aiRules1cName
    }
}

function Test-Vibecoding1cMcpLogicalServerAllowedForProject {
    param([string]$ServerId)

    if ($ServerId -eq "vanessa") {
        return $false
    }
    if ($ServerId -eq "bookstack" -and -not (Test-ProductDocsMcpAllowed)) {
        return $false
    }
    return $true
}

function Test-Vibecoding1cMcpServerAllowedForProject {
    param([object]$Server)

    $id = [string](Get-Vibecoding1cMcpObjectValue -Object $Server -Name "id" -Default "")
    return (Test-Vibecoding1cMcpLogicalServerAllowedForProject -ServerId $id)
}

function Test-Vibecoding1cMcpEndpointAllowedForProject {
    param([object]$Endpoint)

    $id = [string](Get-Vibecoding1cMcpObjectValue -Object $Endpoint -Name "id" -Default "")
    return (Test-Vibecoding1cMcpLogicalServerAllowedForProject -ServerId $id)
}

function Select-Vibecoding1cMcpAllowedStaleIndexes {
    param([object[]]$Values)

    if (Test-ProductDocsMcpAllowed) {
        return @($Values)
    }
    return @($Values | Where-Object { [string]$_ -ne "bookstack" })
}

function Write-Vibecoding1cMcpRemoteEndpointChoices {
    param(
        [object[]]$Candidates,
        [string]$ServerId,
        [string]$ConfigId
    )

    $suffix = if ($ConfigId) { " for configId '$ConfigId'" } else { "" }
    if ($null -eq $Candidates -or $Candidates.Count -eq 0) {
        Write-Host "  remote endpoints for '$ServerId'${suffix}: none found in registry"
        return
    }

    Write-Host "  remote endpoints for '$ServerId'${suffix}:"
    for ($i = 0; $i -lt $Candidates.Count; $i++) {
        Write-Host ("    {0}. {1}" -f ($i + 1), (Format-Vibecoding1cMcpRemoteEndpointInfo -Endpoint $Candidates[$i]))
    }
}

function Get-Vibecoding1cMcpRemoteEndpointCandidates {
    param(
        [object]$Server,
        [object]$Selection,
        [string]$ConfigId
    )

    $id = [string](Get-Vibecoding1cMcpObjectValue -Object $Server -Name "id" -Default "")
    $scope = Get-Vibecoding1cMcpServerScope -Server $Server
    $hostId = Get-Vibecoding1cMcpSelectedHostId -Server $Server -Selection $Selection
    $registry = Read-Vibecoding1cMcpRegistry
    $candidates = @()
    foreach ($endpoint in Get-Vibecoding1cMcpRegistryServers -Registry $registry) {
        if ([string](Get-Vibecoding1cMcpObjectValue -Object $endpoint -Name "family" -Default "") -ne "vibecoding1c") {
            continue
        }
        if ([string](Get-Vibecoding1cMcpObjectValue -Object $endpoint -Name "id" -Default "") -ne $id) {
            continue
        }
        if ([string](Get-Vibecoding1cMcpObjectValue -Object $endpoint -Name "scope" -Default "global") -ne $scope) {
            continue
        }
        if ($ConfigId -and ([string](Get-Vibecoding1cMcpObjectValue -Object $endpoint -Name "configId" -Default "")) -ne $ConfigId) {
            continue
        }
        if ($hostId -and ([string](Get-Vibecoding1cMcpObjectValue -Object $endpoint -Name "hostId" -Default "")) -ne $hostId) {
            continue
        }
        $candidates += $endpoint
    }
    return @($candidates)
}

function Get-Vibecoding1cMcpSelectionCompleteness {
    param(
        [object]$Selection,
        [switch]$RefreshRegistry
    )

    $reasons = @()
    $selectionPath = Get-Vibecoding1cMcpSelectionPath
    if (-not (Test-Path -LiteralPath $selectionPath -PathType Leaf -ErrorAction SilentlyContinue)) {
        $reasons += "selection file is missing"
    }

    $registryReady = $false
    $registryPath = Join-Path (Get-Vibecoding1cMcpRegistryRoot) "registry.json"
    $canValidateRegistryEndpoints = $RefreshRegistry -or (Test-Path -LiteralPath $registryPath -PathType Leaf -ErrorAction SilentlyContinue)
    foreach ($server in Select-Vibecoding1cMcpManifestServers) {
        $id = [string](Get-Vibecoding1cMcpObjectValue -Object $server -Name "id" -Default "")
        if (-not $id) {
            continue
        }

        $scope = Get-Vibecoding1cMcpServerScope -Server $server
        $provider = Get-Vibecoding1cMcpSelectedProvider -Server $server -Selection $Selection
        $entry = Get-Vibecoding1cMcpSelectionEntry -Selection $Selection -ServerId $id
        if ($null -eq $entry) {
            $canUseDefaultRemoteGlobal = ($scope -eq "global" -and $provider -eq "remote" -and -not (Test-Vibecoding1cMcpServerNeedsRemoteConfig -Server $server))
            if (-not $canUseDefaultRemoteGlobal) {
                $reasons += "$id/$scope has no per-server selection"
                continue
            }
        }

        if ($provider -eq "local") {
            continue
        }

        $configId = ""
        if (Test-Vibecoding1cMcpServerNeedsRemoteConfig -Server $server) {
            $configId = Get-Vibecoding1cMcpSelectedConfigId -Server $server -Selection $Selection
            if (-not $configId) {
                $reasons += "$id/$scope remote provider has no configId"
                continue
            }
        }

        if ($RefreshRegistry -and -not $registryReady) {
            Ensure-Vibecoding1cMcpRegistry | Out-Null
            $registryReady = $true
        }
        $hostId = Get-Vibecoding1cMcpSelectedHostId -Server $server -Selection $Selection
        if (-not $canValidateRegistryEndpoints) {
            continue
        }
        $candidates = @(Get-Vibecoding1cMcpRemoteEndpointCandidates -Server $server -Selection $Selection -ConfigId $configId)
        if ($candidates.Count -eq 0) {
            $hostSuffix = if ($hostId) { " for hostId '$hostId'" } else { "" }
            $reasons += "$id/$scope remote provider has no registry endpoint$hostSuffix"
            continue
        }

        $usableCandidates = @($candidates | Where-Object { Test-Vibecoding1cMcpEndpointUsableForClientConfig -Endpoint $_ })
        if ($usableCandidates.Count -eq 0) {
            $unavailable = (($candidates | ForEach-Object { Format-Vibecoding1cMcpRemoteEndpointInfo -Endpoint $_ }) -join " | ")
            $reasons += "$id/$scope remote provider has no usable endpoint: $unavailable"
            continue
        }
        if (-not $hostId -and $usableCandidates.Count -gt 1) {
            $reasons += "$id/$scope remote provider has multiple matching hosts and no hostId"
        }
    }

    return [pscustomobject]@{
        isComplete = ($reasons.Count -eq 0)
        reasons = @($reasons)
    }
}

function Test-Vibecoding1cMcpSelectionComplete {
    param(
        [object]$Selection,
        [switch]$RefreshRegistry
    )

    $result = Get-Vibecoding1cMcpSelectionCompleteness -Selection $Selection -RefreshRegistry:$RefreshRegistry
    return [bool]$result.isComplete
}

function Test-Vibecoding1cMcpSelectionNeedsLocalDistribution {
    param([object]$Selection)

    foreach ($server in Select-Vibecoding1cMcpManifestServers) {
        if ((Get-Vibecoding1cMcpSelectedProvider -Server $server -Selection $Selection) -eq "local") {
            return $true
        }
    }
    return $false
}

function Copy-Vibecoding1cMcpSelectionFromMainWorktree {
    param([string]$MainProjectRoot)

    $targetPath = Get-Vibecoding1cMcpSelectionPath
    if (Test-Path -LiteralPath $targetPath -PathType Leaf -ErrorAction SilentlyContinue) {
        return $true
    }

    if ([string]::IsNullOrWhiteSpace($MainProjectRoot)) {
        return $false
    }

    $sourcePath = Join-Path $MainProjectRoot ".agent-1c\mcp\vibecoding1c-selection.json"
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf -ErrorAction SilentlyContinue)) {
        return $false
    }

    $sourceFull = [System.IO.Path]::GetFullPath($sourcePath)
    $targetFull = [System.IO.Path]::GetFullPath($targetPath)
    if ($sourceFull -eq $targetFull) {
        return $true
    }

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $targetPath) | Out-Null
    Copy-Item -LiteralPath $sourcePath -Destination $targetPath -Force
    Write-Host "Inherited vibecoding1c MCP selection from main worktree: $sourcePath"
    return $true
}

function Read-Vibecoding1cMcpSelectionFromPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf -ErrorAction SilentlyContinue)) {
        return $null
    }

    try {
        return (Read-Utf8Text -Path $Path | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Test-Vibecoding1cMcpSelectionHasServerId {
    param(
        [object]$Selection,
        [string]$ServerId
    )

    if ($null -eq $Selection -or [string]::IsNullOrWhiteSpace($ServerId)) {
        return $false
    }

    return $null -ne (Get-Vibecoding1cMcpSelectionEntry -Selection $Selection -ServerId $ServerId)
}

function Invoke-Vibecoding1cMcpSetupSelectionInheritance {
    $targetPath = Get-Vibecoding1cMcpSelectionPath
    if (Test-Path -LiteralPath $targetPath -PathType Leaf -ErrorAction SilentlyContinue) {
        return
    }

    $currentBranch = ""
    try {
        $currentBranch = Get-CurrentBranch
    } catch {
        return
    }
    if ($currentBranch -notlike "itldev/*") {
        return
    }

    $mainProjectRoot = Get-MainWorktreePath
    if ([string]::IsNullOrWhiteSpace($mainProjectRoot) -or (Get-FullPathNormalized $mainProjectRoot) -eq (Get-FullPathNormalized $script:ProjectRoot)) {
        return
    }

    if (Copy-Vibecoding1cMcpSelectionFromMainWorktree -MainProjectRoot $mainProjectRoot) {
        $selection = Read-Vibecoding1cMcpSelection
        $selectionCompleteness = Get-Vibecoding1cMcpSelectionCompleteness -Selection $selection -RefreshRegistry
        if ($selectionCompleteness.isComplete) {
            Write-Host "Inherited complete vibecoding1c MCP selection for development worktree setup."
        }
    }
}

function Test-Vibecoding1cMcpProjectClientConfigContainsName {
    param([string]$ClientName)

    if ([string]::IsNullOrWhiteSpace($ClientName)) {
        return $false
    }

    $kiloPath = Get-Vibecoding1cMcpKiloConfigPath
    if (Test-Path -LiteralPath $kiloPath -PathType Leaf -ErrorAction SilentlyContinue) {
        try {
            $kilo = Read-Utf8Text -Path $kiloPath | ConvertFrom-Json
            if ($kilo.mcp -and @($kilo.mcp.PSObject.Properties.Name) -contains $ClientName) {
                return $true
            }
        } catch {
        }
    }

    $codexProjectPath = Get-Vibecoding1cMcpCodexProjectConfigPath
    if (Test-Path -LiteralPath $codexProjectPath -PathType Leaf -ErrorAction SilentlyContinue) {
        $text = Read-Utf8Text -Path $codexProjectPath
        if ($text -match ('(?m)^\[mcp_servers\."' + [regex]::Escape($ClientName) + '"\]\s*$') -or
            $text -match ('(?m)^\[mcp_servers\.' + [regex]::Escape($ClientName) + '\]\s*$')) {
            return $true
        }
    }

    return $false
}

function Test-Vibecoding1cMcpCodexConfigContainsName {
    param(
        [string]$Path,
        [string]$ClientName
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf -ErrorAction SilentlyContinue)) {
        return $false
    }
    $text = Read-Utf8Text -Path $Path
    return ($text -match ('(?m)^\[mcp_servers\."' + [regex]::Escape($ClientName) + '"\]\s*$') -or
        $text -match ('(?m)^\[mcp_servers\.' + [regex]::Escape($ClientName) + '\]\s*$'))
}

function Get-Vibecoding1cMcpProductDocsStatus {
    $allowed = Test-ProductDocsMcpAllowed
    $selection = Read-Vibecoding1cMcpSelection
    $selected = Test-Vibecoding1cMcpSelectionHasServerId -Selection $selection -ServerId "bookstack"
    $clientName = Get-Vibecoding1cMcpAiRules1cClientName -ServerId "bookstack"

    $activeClient = "<unconfigured>"
    $clientConfigured = $false
    try {
        $activeClient = Get-ItlActiveClient
        $adapter = Get-ItlClientAdapter -Client $activeClient
        $configPath = Join-Path $script:ProjectRoot $adapter.mcpPath
        if ($activeClient -eq "codex") {
            $clientConfigured = Test-Vibecoding1cMcpCodexConfigContainsName -Path $configPath -ClientName $clientName
        } elseif (Test-Path -LiteralPath $configPath -PathType Leaf -ErrorAction SilentlyContinue) {
            $config = Read-Utf8Text -Path $configPath | ConvertFrom-Json
            $containerName = $(if ($activeClient -in @("claude-code", "cursor")) { "mcpServers" } else { "mcp" })
            $container = $config.PSObject.Properties[$containerName].Value
            $clientConfigured = ($container -and @($container.PSObject.Properties.Name) -contains $clientName)
        }
    } catch {
        $clientConfigured = $false
    }

    $endpoint = @(Get-Vibecoding1cMcpCurrentEndpoints -IncludeGlobal | Where-Object {
        [string](Get-Vibecoding1cMcpObjectValue -Object $_ -Name "id" -Default "") -eq "bookstack"
    } | Select-Object -First 1)
    $reachable = $false
    $probe = "endpoint missing"
    if ($endpoint.Count -gt 0) {
        $url = [string](Get-Vibecoding1cMcpObjectValue -Object $endpoint[0] -Name "url" -Default "")
        $probe = $url
        try {
            $uri = [System.Uri]$url
            $port = if ($uri.IsDefaultPort) { if ($uri.Scheme -eq "https") { 443 } else { 80 } } else { $uri.Port }
            $client = New-Object System.Net.Sockets.TcpClient
            try {
                $async = $client.BeginConnect($uri.Host, $port, $null, $null)
                $reachable = $async.AsyncWaitHandle.WaitOne(500, $false)
                if ($reachable) {
                    $client.EndConnect($async)
                }
            } finally {
                $client.Close()
            }
        } catch {
            $reachable = $false
            $probe = "$url ($($_.Exception.Message))"
        }
    }

    return [pscustomobject][ordered]@{
        allowed = $allowed
        selected = $selected
        activeClient = $activeClient
        clientConfigured = $clientConfigured
        codexConfigured = ($activeClient -eq "codex" -and $clientConfigured)
        kiloConfigured = ($activeClient -eq "kilocode" -and $clientConfigured)
        reachable = $reachable
        probe = $probe
    }
}

function Write-Vibecoding1cMcpProductDocsStatusLines {
    param([string]$Indent = "")

    $status = Get-Vibecoding1cMcpProductDocsStatus
    Write-Host "${Indent}Product docs allowed for project: $($status.allowed)"
    Write-Host "${Indent}Product docs selected in MCP manifest: $($status.selected)"
    Write-Host "${Indent}Product docs effective client config: $($status.activeClient)=$($status.clientConfigured)"
    Write-Host "${Indent}Product docs endpoint reachable (bounded probe): $($status.reachable); $($status.probe)"
}

function Write-Vibecoding1cMcpProductDocsClientConfigWarning {
    if (-not (Test-ProductDocsMcpAllowed)) {
        return
    }

    $currentBranch = ""
    try {
        $currentBranch = Get-CurrentBranch
    } catch {
        return
    }
    if ($currentBranch -notlike "itldev/*") {
        return
    }

    $mainProjectRoot = Get-MainWorktreePath
    if ([string]::IsNullOrWhiteSpace($mainProjectRoot) -or (Get-FullPathNormalized $mainProjectRoot) -eq (Get-FullPathNormalized $script:ProjectRoot)) {
        return
    }

    $mainSelectionPath = Join-Path $mainProjectRoot ".agent-1c\mcp\vibecoding1c-selection.json"
    $mainSelection = Read-Vibecoding1cMcpSelectionFromPath -Path $mainSelectionPath
    if (-not (Test-Vibecoding1cMcpSelectionHasServerId -Selection $mainSelection -ServerId "bookstack")) {
        return
    }

    $clientName = Get-Vibecoding1cMcpAiRules1cClientName -ServerId "bookstack"
    if (Test-Vibecoding1cMcpProjectClientConfigContainsName -ClientName $clientName) {
        return
    }

    Write-Host "WARNING: PM5 product documentation MCP is selected in the main worktree but is missing from this development worktree client config: $clientName."
    Write-Host "Repair: powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action vibecoding1c-mcp-setup"
}

function Read-Vibecoding1cMcpRemoteHostChoice {
    param(
        [object[]]$Candidates,
        [string]$ServerId,
        [string]$ConfigId
    )

    $configSuffix = if ($ConfigId) { " for configId '$ConfigId'" } else { "" }
    if (-not (Test-InteractiveInputAvailable)) {
        throw "Remote vibecoding1c MCP server '$ServerId' has multiple matching hosts$configSuffix. Select one explicitly with -McpHostId <hostId>."
    }

    $matchSuffix = if ($ConfigId) { " and configId '$ConfigId'" } else { "" }
    Write-Host "Multiple remote vibecoding1c MCP hosts match server '$ServerId'${matchSuffix}:"
    for ($i = 0; $i -lt $Candidates.Count; $i++) {
        Write-Host ("  {0}. {1}" -f ($i + 1), (Format-Vibecoding1cMcpRemoteEndpointInfo -Endpoint $Candidates[$i]))
    }

    while ($true) {
        $answer = (Read-Host (Get-Agent1cUtf8Text "0JLRi9Cx0LXRgNC40YLQtSByZW1vdGUt0L/Rg9Cx0LvQuNC60LDRhtC40Y4gTUNQINC/0L4g0L3QvtC80LXRgNGDINC40LvQuCBob3N0SWQ=")).Trim()
        if (-not $answer) {
            continue
        }
        $index = 0
        if ([int]::TryParse($answer, [ref]$index) -and $index -ge 1 -and $index -le $Candidates.Count) {
            return [string](Get-Vibecoding1cMcpObjectValue -Object $Candidates[$index - 1] -Name "hostId" -Default "")
        }
        foreach ($candidate in $Candidates) {
            $hostId = [string](Get-Vibecoding1cMcpObjectValue -Object $candidate -Name "hostId" -Default "")
            if ($hostId -eq $answer) {
                return $hostId
            }
        }
        Write-Host "Unknown vibecoding1c MCP host: $answer"
    }
}

function Read-Vibecoding1cMcpRemoteConfigChoice {
    param([object]$Selection)

    Ensure-Vibecoding1cMcpRegistry | Out-Null
    $registry = Read-Vibecoding1cMcpRegistry
    $configs = @(Get-Vibecoding1cMcpRegistryConfigurations -Registry $registry)
    if ($configs.Count -eq 0) {
        throw "Remote vibecoding1c MCP registry has no configurations. Publish host registry first or choose local vibecoding1c MCP."
    }
    if ($configs.Count -eq 1) {
        $configId = [string](Get-Vibecoding1cMcpObjectValue -Object $configs[0] -Name "configId" -Default "")
        Write-Host ((Get-Agent1cUtf8Text "0J3QsNC50LTQtdC90LAg0LXQtNC40L3RgdGC0LLQtdC90L3QsNGPIHJlbW90ZS3QutC+0L3RhNC40LPRg9GA0LDRhtC40Y8gTUNQOiB7MH0=") -f $configId)
        return $configId
    }
    if (-not (Test-InteractiveInputAvailable)) {
        throw "Remote vibecoding1c MCP configuration must be selected explicitly. Run vibecoding1c-mcp-select -McpProvider remote -McpConfigId <configId>."
    }

    Write-Host "Available remote vibecoding1c MCP configurations:"
    for ($i = 0; $i -lt $configs.Count; $i++) {
        $config = $configs[$i]
        $configId = [string](Get-Vibecoding1cMcpObjectValue -Object $config -Name "configId" -Default "")
        $title = [string](Get-Vibecoding1cMcpObjectValue -Object $config -Name "title" -Default $configId)
        $source = [string](Get-Vibecoding1cMcpObjectValue -Object $config -Name "source" -Default "")
        $hostId = [string](Get-Vibecoding1cMcpObjectValue -Object $config -Name "hostId" -Default "")
        $publishedAt = [string](Get-Vibecoding1cMcpObjectValue -Object $config -Name "hostPublishedAt" -Default (Get-Vibecoding1cMcpObjectValue -Object $config -Name "publishedAt" -Default ""))
        $configurationName = [string](Get-Vibecoding1cMcpObjectValue -Object $config -Name "configurationName" -Default "")
        $configurationVersion = [string](Get-Vibecoding1cMcpObjectValue -Object $config -Name "configurationVersion" -Default "")
        Write-Host ("  {0}. {1} {2}" -f ($i + 1), $configId, $(if ($title -and $title -ne $configId) { "($title)" } else { "" }))
        if ($hostId -or $publishedAt) {
            Write-Host "     hostId=$(if ($hostId) { $hostId } else { '<unknown>' }) publishedAt=$(if ($publishedAt) { $publishedAt } else { '<unknown>' })"
        }
        if ($configurationName) {
            $configurationText = $configurationName
            if ($configurationVersion) {
                $configurationText = "$configurationName $configurationVersion"
            }
            Write-Host "     configuration=$configurationText"
        }
        if ($source) {
            Write-Host "     $source"
        }
    }

    while ($true) {
        $answer = (Read-Host (Get-Agent1cUtf8Text "0JLRi9Cx0LXRgNC40YLQtSDQutC+0L3RhNC40LPRg9GA0LDRhtC40Y4gTUNQINC/0L4g0L3QvtC80LXRgNGDINC40LvQuCBjb25maWdJZA==")).Trim()
        if (-not $answer) {
            continue
        }
        $index = 0
        if ([int]::TryParse($answer, [ref]$index) -and $index -ge 1 -and $index -le $configs.Count) {
            return [string](Get-Vibecoding1cMcpObjectValue -Object $configs[$index - 1] -Name "configId" -Default "")
        }
        foreach ($config in $configs) {
            $configId = [string](Get-Vibecoding1cMcpObjectValue -Object $config -Name "configId" -Default "")
            if ($configId -eq $answer) {
                return $configId
            }
        }
        Write-Host "Unknown vibecoding1c MCP configuration: $answer"
    }
}

function Resolve-Vibecoding1cMcpProjectRemoteConfigId {
    param([object]$Registry = $null)

    $configuredConfigId = [string](Get-EnvValue -Name "VIBECODING1C_MCP_CONFIG_ID" -Default (Get-ConfigValue -Path "vibecoding1cMcp.remoteConfigId" -Default ""))
    if (-not [string]::IsNullOrWhiteSpace($configuredConfigId)) {
        return $configuredConfigId.Trim()
    }

    if ($null -eq $Registry) {
        $Registry = Read-Vibecoding1cMcpRegistry
    }

    $baseVersion = Get-BaseConfigurationVersion
    $configurationMajor = if ($baseVersion -eq "PM4") { "4" } else { "5" }
    $matchingConfigIds = @(
        Get-Vibecoding1cMcpRegistryConfigurations -Registry $Registry |
            Where-Object {
                $version = [string](Get-Vibecoding1cMcpObjectValue -Object $_ -Name "configurationVersion" -Default "")
                $version -match ("^" + [regex]::Escape($configurationMajor) + "(?:\.|$)")
            } |
            ForEach-Object { [string](Get-Vibecoding1cMcpObjectValue -Object $_ -Name "configId" -Default "") } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique
    )
    if ($matchingConfigIds.Count -eq 1) {
        return $matchingConfigIds[0]
    }
    return ""
}

function ConvertTo-Vibecoding1cMcpLocalScopedServer {
    param(
        [object]$Server,
        [string]$LocalScope,
        [object]$Context
    )

    $id = [string](Get-Vibecoding1cMcpObjectValue -Object $Server -Name "id" -Default "")
    $hash = ConvertTo-Vibecoding1cMcpHashtable -Object $Server
    if ($LocalScope -eq "branch") {
        if (-not $Context.isDevelopmentBranch) {
            Write-Host "Local branch vibecoding1c MCP for '$id' was requested outside itldev/*; using project scope."
            return [pscustomobject]$hash
        }
        $hash["scope"] = "branch"
        $hash["mcpNameTemplate"] = "itl-{projectSlug}-{branchSlug}-$id"
        $hash["containerNameTemplate"] = "itl-{projectSlug}-{branchSlug}-$id"
        if ($hash.Contains("composeProjectTemplate")) {
            $hash["composeProjectTemplate"] = "itl-{projectSlug}-{branchSlug}-$id"
        }
    }
    return [pscustomobject]$hash
}

function Get-Vibecoding1cMcpCurrentSourceFingerprint {
    try {
        if (-not (Test-Path -LiteralPath (Join-Path $script:ProjectRoot ".git") -ErrorAction SilentlyContinue)) {
            return ""
        }
        $paths = @((Get-ExportPath))
        $parts = @()
        $parts += "commit=$(Get-CurrentCommit)"
        foreach ($path in $paths) {
            $normalized = ($path -replace "\\", "/").Trim("/")
            if ($normalized) {
                $parts += "$normalized=$(Get-GitObjectIdForHeadPath -RepoPath $normalized)"
            }
        }
        $status = Get-GitStatusForFingerprintPaths -PathSpec $paths
        if ($status) {
            $parts += "worktree=$status"
        } else {
            $parts += "worktree=<clean>"
        }
        return ($parts -join "|")
    } catch {
        return ""
    }
}

function Get-Vibecoding1cMcpEndpointFreshness {
    param([object]$Endpoint)

    $status = [string](Get-Vibecoding1cMcpObjectValue -Object $Endpoint -Name "status" -Default "")
    $health = [string](Get-Vibecoding1cMcpObjectValue -Object $Endpoint -Name "health" -Default "")
    if ($status -eq "indexing" -or $health -eq "indexing") {
        return "indexing"
    }

    $provider = [string](Get-Vibecoding1cMcpObjectValue -Object $Endpoint -Name "provider" -Default "local")
    if ($provider -eq "remote") {
        return "remote-shared"
    }

    $sourceFingerprint = [string](Get-Vibecoding1cMcpObjectValue -Object $Endpoint -Name "sourceFingerprint" -Default "")
    if (-not $sourceFingerprint) {
        return "unknown"
    }

    $currentFingerprint = Get-Vibecoding1cMcpCurrentSourceFingerprint
    if ($currentFingerprint -and $sourceFingerprint -eq $currentFingerprint) {
        return "fresh"
    }

    return "stale"
}

function New-Vibecoding1cMcpRemoteRuntime {
    param(
        [object]$Server,
        [object]$Selection,
        [switch]$AllowPrompt
    )

    $id = [string](Get-Vibecoding1cMcpObjectValue -Object $Server -Name "id" -Default "")
    $scope = Get-Vibecoding1cMcpServerScope -Server $Server
    $configId = ""
    if (Test-Vibecoding1cMcpServerNeedsRemoteConfig -Server $Server) {
        $configId = Get-Vibecoding1cMcpSelectedConfigId -Server $Server -Selection $Selection -AllowPrompt:$AllowPrompt
        if (-not $configId) {
            throw "Remote vibecoding1c MCP server '$id' requires explicit configuration selection. Run vibecoding1c-mcp-select -McpServerId $id -McpProvider remote -McpConfigId <configId>."
        }
    }

    $candidates = @(Get-Vibecoding1cMcpRemoteEndpointCandidates -Server $Server -Selection $Selection -ConfigId $configId)
    $usableCandidates = @($candidates | Where-Object { Test-Vibecoding1cMcpEndpointUsableForClientConfig -Endpoint $_ })
    if ($usableCandidates.Count -gt 0) {
        $candidates = $usableCandidates
    } elseif ($candidates.Count -gt 0) {
        $candidateText = (($candidates | ForEach-Object { Format-Vibecoding1cMcpRemoteEndpointInfo -Endpoint $_ }) -join " | ")
        Write-Host "Skipping remote vibecoding1c MCP server '$id': endpoint is not usable for client config. Candidates: $candidateText"
        return $null
    }
    if ($candidates.Count -gt 1) {
        if ($AllowPrompt) {
            $chosenHostId = Read-Vibecoding1cMcpRemoteHostChoice -Candidates $candidates -ServerId $id -ConfigId $configId
            $candidates = @($candidates | Where-Object { [string](Get-Vibecoding1cMcpObjectValue -Object $_ -Name "hostId" -Default "") -eq $chosenHostId })
        } else {
            $candidateText = (($candidates | ForEach-Object { Format-Vibecoding1cMcpRemoteEndpointInfo -Endpoint $_ }) -join " | ")
            $configSuffix = if ($configId) { " for configId '$configId'" } else { "" }
            throw "Remote vibecoding1c MCP server '$id' has multiple matching hosts$configSuffix. Select one explicitly with -McpHostId <hostId>. Candidates: $candidateText"
        }
    }

    if ($candidates.Count -eq 1) {
        $endpoint = $candidates[0]
        $context = Get-Vibecoding1cMcpScopeContext
        return [pscustomobject]@{
            id = $id
            scope = $scope
            name = [string](Get-Vibecoding1cMcpObjectValue -Object $endpoint -Name "name" -Default "itl-$id")
            containerName = ""
            internalPort = 0
            hostPort = 0
            url = [string](Get-Vibecoding1cMcpObjectValue -Object $endpoint -Name "url" -Default "")
            projectSlug = $context.projectSlug
            branchSlug = $context.branchSlug
            gitBranch = $context.gitBranch
            projectRoot = $script:ProjectRoot
            image = [string](Get-Vibecoding1cMcpObjectValue -Object $endpoint -Name "image" -Default "")
            family = "vibecoding1c"
            provider = "remote"
            clientNames = (Get-Vibecoding1cMcpObjectValue -Object $endpoint -Name "clientNames" -Default (Get-Vibecoding1cMcpClientNames -ServerId $id))
            hostId = [string](Get-Vibecoding1cMcpObjectValue -Object $endpoint -Name "hostId" -Default "")
            hostPublishedAt = [string](Get-Vibecoding1cMcpObjectValue -Object $endpoint -Name "hostPublishedAt" -Default (Get-Vibecoding1cMcpObjectValue -Object $endpoint -Name "publishedAt" -Default ""))
            hostBaseUrl = [string](Get-Vibecoding1cMcpObjectValue -Object $endpoint -Name "hostBaseUrl" -Default "")
            configId = $configId
            status = [string](Get-Vibecoding1cMcpObjectValue -Object $endpoint -Name "status" -Default "")
            health = [string](Get-Vibecoding1cMcpObjectValue -Object $endpoint -Name "health" -Default "")
            platformVersion = [string](Get-Vibecoding1cMcpObjectValue -Object $endpoint -Name "platformVersion" -Default "")
            bspVersion = [string](Get-Vibecoding1cMcpObjectValue -Object $endpoint -Name "bspVersion" -Default "")
            configurationName = [string](Get-Vibecoding1cMcpObjectValue -Object $endpoint -Name "configurationName" -Default "")
            configurationVersion = [string](Get-Vibecoding1cMcpObjectValue -Object $endpoint -Name "configurationVersion" -Default "")
            embeddingMode = [string](Get-Vibecoding1cMcpObjectValue -Object $endpoint -Name "embeddingMode" -Default "")
            embeddingModel = [string](Get-Vibecoding1cMcpObjectValue -Object $endpoint -Name "embeddingModel" -Default "")
            sourceCommit = [string](Get-Vibecoding1cMcpObjectValue -Object $endpoint -Name "sourceCommit" -Default "")
            sourceFingerprint = [string](Get-Vibecoding1cMcpObjectValue -Object $endpoint -Name "sourceFingerprint" -Default "")
            reportHash = [string](Get-Vibecoding1cMcpObjectValue -Object $endpoint -Name "reportHash" -Default "")
            indexedAt = [string](Get-Vibecoding1cMcpObjectValue -Object $endpoint -Name "indexedAt" -Default "")
        }
    }

    $configSuffix = $(if ($configId) { " for configId '$configId'" } else { "" })
    $hostSuffix = $(if ((Get-Vibecoding1cMcpSelectedHostId -Server $Server -Selection $Selection)) { " and selected hostId '$(Get-Vibecoding1cMcpSelectedHostId -Server $Server -Selection $Selection)'" } else { "" })
    Write-Host "Skipping remote vibecoding1c MCP server '$id': endpoint was not found in registry$configSuffix$hostSuffix."
    return $null
}

function Read-Vibecoding1cMcpProviderSelectionMode {
    while ($true) {
        $answer = (Read-Host (Get-Agent1cUtf8Text "0JLRi9Cx0LXRgNC40YLQtSDRgNC10LbQuNC8IE1DUDogcmVtb3RlINC00LvRjyDQstGB0LXRhSwgbG9jYWwg0LTQu9GPINCy0YHQtdGFINC/0L7QtNC00LXRgNC20LjQstCw0Y7RidC40YUgbG9jYWwg0YHQtdGA0LLQtdGA0L7QsiDQuNC70LggZWFjaCDQtNC70Y8g0LLRi9Cx0L7RgNCwINC/0L4g0LrQsNC20LTQvtC80YMg0YHQtdGA0LLQtdGA0YMgW3JlbW90ZV0=")).Trim().ToLowerInvariant()
        if (-not $answer) { return "remote" }
        if ($answer -in @("remote", "local", "each")) { return $answer }
        Write-Host (Get-Agent1cUtf8Text "0JLQstC10LTQuNGC0LUgcmVtb3RlLCBsb2NhbCDQuNC70LggZWFjaC4=")
    }
}

function Set-Vibecoding1cMcpSelection {
    Write-Section "Select vibecoding1c MCP"
    Ensure-GitIgnore
    $selection = Read-Vibecoding1cMcpSelection
    $selectionHash = ConvertTo-Vibecoding1cMcpHashtable -Object $selection
    $context = Get-Vibecoding1cMcpScopeContext
    $servers = @()

    $targetServers = @(Select-Vibecoding1cMcpManifestServers)
    $targetServerIds = @()
    foreach ($server in $targetServers) {
        $id = [string](Get-Vibecoding1cMcpObjectValue -Object $server -Name "id" -Default "")
        if ($McpServerId -and $id -ne $McpServerId) {
            continue
        }
        if ($id) {
            $targetServerIds += $id
        }
    }

    $providerMode = ""
    if (-not $McpProvider -and -not $McpServerId -and (Test-InteractiveInputAvailable)) {
        $providerMode = Read-Vibecoding1cMcpProviderSelectionMode
        if ($providerMode -ne "each") {
            $selectionHash["defaultProvider"] = $providerMode
        }
    }

    if ($McpProvider -and -not $McpServerId) {
        $selectionHash["defaultProvider"] = $McpProvider
    }
    if ($McpLocalScope -and -not $McpServerId) {
        $selectionHash["localScopeDefault"] = $McpLocalScope
    }
    if ($McpConfigId -and -not $McpServerId) {
        $selectionHash["remoteConfigId"] = $McpConfigId
    }
    if ($McpHostId -and -not $McpServerId) {
        $selectionHash["remoteHostId"] = $McpHostId
    }

    foreach ($entry in ConvertTo-Vibecoding1cMcpArray (Get-Vibecoding1cMcpObjectValue -Object $selection -Name "servers" -Default @())) {
        $entryId = [string](Get-Vibecoding1cMcpObjectValue -Object $entry -Name "id" -Default "")
        if ($targetServerIds -contains $entryId) {
            continue
        }
        $servers += $entry
    }

    foreach ($server in $targetServers) {
        $id = [string](Get-Vibecoding1cMcpObjectValue -Object $server -Name "id" -Default "")
        if ($targetServerIds -notcontains $id) {
            continue
        }

        $scope = Get-Vibecoding1cMcpServerScope -Server $server
        $title = [string](Get-Vibecoding1cMcpObjectValue -Object $server -Name "title" -Default $id)
        $existingEntry = Get-Vibecoding1cMcpSelectionEntry -Selection $selection -ServerId $id
        $existingProvider = if ($existingEntry) { [string](Get-Vibecoding1cMcpObjectValue -Object $existingEntry -Name "provider" -Default "") } else { "" }
        $existingConfigId = if ($existingEntry) { [string](Get-Vibecoding1cMcpObjectValue -Object $existingEntry -Name "configId" -Default "") } else { "" }
        $existingHostId = if ($existingEntry) { [string](Get-Vibecoding1cMcpObjectValue -Object $existingEntry -Name "hostId" -Default "") } else { "" }
        $existingLocalScope = if ($existingEntry) { [string](Get-Vibecoding1cMcpObjectValue -Object $existingEntry -Name "localScope" -Default "") } else { "" }
        Write-Host "vibecoding1c MCP server '$id' [$scope]: $title"
        if ($existingProvider -or $existingConfigId -or $existingHostId -or $existingLocalScope) {
            Write-Host "  current: provider=$(if ($existingProvider) { $existingProvider } else { '<default>' }) configId=$(if ($existingConfigId) { $existingConfigId } else { '<none>' }) hostId=$(if ($existingHostId) { $existingHostId } else { '<none>' }) localScope=$(if ($existingLocalScope) { $existingLocalScope } else { '<default>' })"
        } else {
            Write-Host "  current: <not selected>"
        }

        $provider = if ($McpProvider) {
            $McpProvider
        } elseif ($providerMode -eq "remote" -or $providerMode -eq "local") {
            $providerMode
        } elseif ($existingProvider -eq "remote" -or $existingProvider -eq "local") {
            $existingProvider
        } else {
            [string](Get-Vibecoding1cMcpObjectValue -Object $selectionHash -Name "defaultProvider" -Default "remote")
        }
        if ($id -eq "mantis") {
            $provider = "remote"
        }
        if (-not $McpProvider -and $id -ne "mantis" -and ($McpServerId -or $providerMode -eq "each") -and (Test-InteractiveInputAvailable)) {
            $answer = (Read-Host ((Get-Agent1cUtf8Text "0J/RgNC+0LLQsNC50LTQtdGAIE1DUC3RgdC10YDQstC10YDQsCAnezB9JyBbcmVtb3RlL2xvY2FsXSwg0L/QviDRg9C80L7Qu9GH0LDQvdC40Y4gezF9") -f $id, $provider)).Trim().ToLowerInvariant()
            if ($answer -eq "remote" -or $answer -eq "local") {
                $provider = $answer
            }
        }
        if ($id -eq "mantis") {
            $provider = "remote"
        }
        $localScope = if ($McpLocalScope) {
            $McpLocalScope
        } elseif ($existingLocalScope -eq "project" -or $existingLocalScope -eq "branch") {
            $existingLocalScope
        } else {
            [string](Get-Vibecoding1cMcpObjectValue -Object $selectionHash -Name "localScopeDefault" -Default "project")
        }
        if ($localScope -eq "branch" -and -not $context.isDevelopmentBranch) {
            $localScope = "project"
        }
        if ($provider -eq "local" -and -not $McpLocalScope -and (Test-Vibecoding1cMcpServerNeedsRemoteConfig -Server $server) -and (Test-InteractiveInputAvailable)) {
            $scopeChoices = if ($context.isDevelopmentBranch) { "project/branch" } else { "project" }
            $scopeAnswer = (Read-Host ((Get-Agent1cUtf8Text "0JvQvtC60LDQu9GM0L3QsNGPINC+0LHQu9Cw0YHRgtGMIE1DUC3RgdC10YDQstC10YDQsCAnezB9JyBbezF9XSwg0L/QviDRg9C80L7Qu9GH0LDQvdC40Y4gezJ9") -f $id, $scopeChoices, $localScope)).Trim().ToLowerInvariant()
            if ($scopeAnswer -eq "project" -or ($context.isDevelopmentBranch -and $scopeAnswer -eq "branch")) {
                $localScope = $scopeAnswer
            }
        }
        $requiresRemoteConfig = Test-Vibecoding1cMcpServerNeedsRemoteConfig -Server $server
        $configId = if ($McpConfigId) {
            $McpConfigId
        } elseif ($existingConfigId) {
            $existingConfigId
        } elseif ($requiresRemoteConfig) {
            ""
        } else {
            [string](Get-Vibecoding1cMcpObjectValue -Object $selectionHash -Name "remoteConfigId" -Default "")
        }
        if ($provider -eq "remote" -and $requiresRemoteConfig -and -not $configId) {
            $configId = Read-Vibecoding1cMcpRemoteConfigChoice -Selection $selection
        }
        $hostId = if ($McpHostId) {
            $McpHostId
        } elseif ($existingHostId) {
            $existingHostId
        } else {
            $bulkHostId = [string](Get-Vibecoding1cMcpObjectValue -Object $selectionHash -Name "remoteHostId" -Default "")
            if ((-not $McpServerId) -and $bulkHostId) { $bulkHostId } else { "" }
        }
        if ($provider -eq "remote") {
            Ensure-Vibecoding1cMcpRegistry | Out-Null
            $candidateSelection = [pscustomobject]$selectionHash
            $candidates = @(Get-Vibecoding1cMcpRemoteEndpointCandidates -Server $server -Selection $candidateSelection -ConfigId $configId)
            Write-Vibecoding1cMcpRemoteEndpointChoices -Candidates $candidates -ServerId $id -ConfigId $configId
            $usableCandidates = @($candidates | Where-Object { Test-Vibecoding1cMcpEndpointUsableForClientConfig -Endpoint $_ })
            if (-not $hostId -and $usableCandidates.Count -eq 1) {
                $hostId = [string](Get-Vibecoding1cMcpObjectValue -Object $usableCandidates[0] -Name "hostId" -Default "")
            } elseif (-not $hostId -and $usableCandidates.Count -gt 1 -and (Test-InteractiveInputAvailable)) {
                $hostId = Read-Vibecoding1cMcpRemoteHostChoice -Candidates $usableCandidates -ServerId $id -ConfigId $configId
            }
        }

        $servers += [ordered]@{
            id = $id
            family = "vibecoding1c"
            provider = $provider
            configId = $configId
            hostId = $hostId
            localScope = $localScope
            selectedAt = (Get-Date).ToString("o")
        }
    }

    $selectionHash["servers"] = $servers
    Write-Vibecoding1cMcpSelection -Selection $selectionHash
    Write-Host "vibecoding1c MCP selection: $(Get-Vibecoding1cMcpSelectionPath)"
    Write-Host "Default provider: $($selectionHash["defaultProvider"])"
    Write-Host "Remote configId: $(if ($selectionHash["remoteConfigId"]) { $selectionHash["remoteConfigId"] } else { '<not selected>' })"
    Write-Host "Remote hostId: $(if ($selectionHash["remoteHostId"]) { $selectionHash["remoteHostId"] } else { '<not selected>' })"
    Write-Host "Local scope default: $($selectionHash["localScopeDefault"])"
    if ($context.isDevelopmentBranch) {
        Write-Host "Current branch scope: $($context.branchSlug)"
    }
}

function Refresh-Vibecoding1cMcpRegistry {
    Write-Section "Refresh vibecoding1c MCP registry"
    Ensure-Vibecoding1cMcpRegistry | Out-Null
    $registry = Read-Vibecoding1cMcpRegistry
    Write-Host "vibecoding1c MCP registry: $(Get-Vibecoding1cMcpRegistryRoot)"
    Write-Host "Published at: $(Get-Vibecoding1cMcpObjectValue -Object $registry -Name 'publishedAt' -Default '<unknown>')"
    Write-Host "Hosts: $(@(Get-Vibecoding1cMcpRegistryHosts -Registry $registry).Count)"
    Write-Host "Configurations: $(@(Get-Vibecoding1cMcpRegistryConfigurations -Registry $registry).Count)"
    Write-Host "Servers: $(@(Get-Vibecoding1cMcpRegistryServers -Registry $registry).Count)"
}

function Read-Vibecoding1cMcpDotEnvFile {
    param([string]$Path)

    $values = [ordered]@{}
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf -ErrorAction SilentlyContinue)) {
        return $values
    }

    foreach ($line in Read-Utf8Lines -Path $Path) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith("#")) {
            continue
        }
        $idx = $trimmed.IndexOf("=")
        if ($idx -lt 1) {
            continue
        }
        $name = $trimmed.Substring(0, $idx).Trim()
        $value = $trimmed.Substring($idx + 1).Trim()
        if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        $values[$name] = $value
    }

    return $values
}

function Write-Vibecoding1cMcpDotEnvFile {
    param(
        [string]$Path,
        [System.Collections.IDictionary]$Values
    )

    $lines = @()
    if (Test-Path -LiteralPath $Path -PathType Leaf -ErrorAction SilentlyContinue) {
        $lines = @(Read-Utf8Lines -Path $Path)
    }

    $seen = @{}
    $updated = New-Object System.Collections.ArrayList
    foreach ($line in $lines) {
        $replacement = $line
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)=') {
            $name = $matches[1]
            if ($Values.Contains($name)) {
                $replacement = "$name=$($Values[$name])"
                $seen[$name] = $true
            }
        }
        [void]$updated.Add($replacement)
    }

    foreach ($name in @($Values.Keys | Sort-Object)) {
        if (-not $seen.ContainsKey($name)) {
            [void]$updated.Add("$name=$($Values[$name])")
        }
    }

    Write-Utf8Text -Path $Path -Value ((@($updated) -join [Environment]::NewLine) + [Environment]::NewLine)
}

function Get-Vibecoding1cMcpConfigContext {
    $distributionRoot = Get-Vibecoding1cMcpDistributionRoot
    $distributionConfigPath = Join-Path $distributionRoot "config.env"
    $localConfigPath = Get-Vibecoding1cMcpLocalPath -Leaf "config.env"
    $values = [ordered]@{}

    foreach ($source in @(
        (Read-Vibecoding1cMcpDotEnvFile -Path $distributionConfigPath),
        (Read-Vibecoding1cMcpDotEnvFile -Path $localConfigPath),
        (Read-Vibecoding1cMcpDotEnvFile -Path (Join-Path $script:ProjectRoot ".dev.env"))
    )) {
        foreach ($key in $source.Keys) {
            $values[$key] = $source[$key]
        }
    }

    return [pscustomobject]@{
        distributionRoot = $distributionRoot
        distributionConfigPath = $distributionConfigPath
        localConfigPath = $localConfigPath
        values = $values
    }
}

function Get-Vibecoding1cMcpConfigValue {
    param(
        [object]$Context,
        [string]$Name,
        [object]$Default = ""
    )

    $processValue = [Environment]::GetEnvironmentVariable($Name, "Process")
    if (-not [string]::IsNullOrWhiteSpace($processValue)) {
        return $processValue
    }

    $values = Get-Vibecoding1cMcpObjectValue -Object $Context -Name "values" -Default $null
    if ($null -ne $values -and $values.Contains($Name)) {
        $value = $values[$Name]
        if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
            return $value
        }
    }

    return $Default
}

function Get-Vibecoding1cMcpDefaultManifest {
    return [pscustomobject]@{
        schemaVersion = 1
        package = "vibecoding1c"
        servers = @(
            [ordered]@{
                id = "docs"
                title = "1C help search"
                scope = "global"
                mcpNameTemplate = "itl-1c-docs"
                containerNameTemplate = "itl-1c-docs"
                image = "comol/1c_help_mcp:{imageTag}"
                internalPort = 8003
                healthPath = "/mcp"
                embedding = $true
                env = @(
                    [ordered]@{ name = "LICENSE_KEY"; from = "LICENSE_KEY_HELP"; required = $true },
                    [ordered]@{ name = "USESSE"; value = "false" },
                    [ordered]@{ name = "OPENAI_API_BASE"; embedding = "base" },
                    [ordered]@{ name = "OPENAI_API_KEY"; embedding = "key" },
                    [ordered]@{ name = "OPENAI_MODEL"; embedding = "model" }
                )
                volumes = @(
                    [ordered]@{ from = "PATH_1C_BIN"; to = "/app/1c_bin"; required = $false }
                )
            },
            [ordered]@{
                id = "templates"
                title = "1C templates search"
                scope = "global"
                mcpNameTemplate = "itl-1c-templates"
                containerNameTemplate = "itl-1c-templates"
                image = "comol/template-search-mcp:{imageTag}"
                internalPort = 8004
                healthPath = "/mcp"
                embedding = $true
                env = @(
                    [ordered]@{ name = "LICENSE_KEY"; from = "LICENSE_KEY_TEMPLATES"; required = $true },
                    [ordered]@{ name = "USESSE"; value = "false" },
                    [ordered]@{ name = "OPENAI_API_BASE"; embedding = "base" },
                    [ordered]@{ name = "OPENAI_API_KEY"; embedding = "key" },
                    [ordered]@{ name = "OPENAI_MODEL"; embedding = "model" }
                )
                volumes = @()
            },
            [ordered]@{
                id = "syntax"
                title = "1C syntax check"
                scope = "global"
                mcpNameTemplate = "itl-1c-syntax"
                containerNameTemplate = "itl-1c-syntax"
                image = "comol/1c_syntaxcheck_mcp:latest"
                internalPort = 8002
                healthPath = "/mcp"
                embedding = $false
                env = @(
                    [ordered]@{ name = "LICENSE_KEY"; from = "LICENSE_KEY_SYNTAX"; required = $true },
                    [ordered]@{ name = "USESSE"; value = "false" }
                )
                volumes = @()
            },
            [ordered]@{
                id = "codechecker"
                title = "1C code checker"
                scope = "global"
                mcpNameTemplate = "itl-1c-codechecker"
                containerNameTemplate = "itl-1c-codechecker"
                image = "comol/1c-code-checker:latest"
                internalPort = 8007
                healthPath = "/mcp"
                embedding = $false
                env = @(
                    [ordered]@{ name = "LICENSE_KEY"; from = "LICENSE_KEY_CODECHECKER"; required = $true },
                    [ordered]@{ name = "ONEC_AI_TOKEN"; from = "ONEC_AI_TOKEN"; required = $false },
                    [ordered]@{ name = "USESSE"; value = "false" }
                )
                volumes = @()
            },
            [ordered]@{
                id = "ssl"
                title = "1C SSL search"
                scope = "global"
                mcpNameTemplate = "itl-1c-ssl"
                containerNameTemplate = "itl-1c-ssl"
                image = "comol/mcp_ssl_server:{imageTag}"
                internalPort = 8008
                healthPath = "/mcp"
                embedding = $true
                env = @(
                    [ordered]@{ name = "LICENSE_KEY"; from = "LICENSE_KEY_SSL"; required = $true },
                    [ordered]@{ name = "SSL_VERSION"; from = "SSL_VERSION"; required = $false },
                    [ordered]@{ name = "USESSE"; value = "false" },
                    [ordered]@{ name = "OPENAI_API_BASE"; embedding = "base" },
                    [ordered]@{ name = "OPENAI_API_KEY"; embedding = "key" },
                    [ordered]@{ name = "OPENAI_MODEL"; embedding = "model" }
                )
                volumes = @()
            },
            [ordered]@{
                id = "code"
                title = "Project code metadata search"
                scope = "project"
                mcpNameTemplate = "itl-{projectSlug}-code"
                containerNameTemplate = "itl-{projectSlug}-code"
                image = "comol/1c_code_metadata_mcp:{imageTag}"
                internalPort = 8000
                healthPath = "/mcp"
                embedding = $true
                env = @(
                    [ordered]@{ name = "LICENSE_KEY"; from = "LICENSE_KEY_CODEMETADATA"; required = $true },
                    [ordered]@{ name = "METADATA_PATH"; value = "/app/metadata" },
                    [ordered]@{ name = "CODE_PATH"; value = "/app/code" },
                    [ordered]@{ name = "RESET_CACHE"; from = "RESET_CACHE"; default = "false" },
                    [ordered]@{ name = "RESET_DATABASE"; from = "RESET_DATABASE"; default = "false" },
                    [ordered]@{ name = "USESSE"; value = "false" },
                    [ordered]@{ name = "OPENAI_API_BASE"; embedding = "base" },
                    [ordered]@{ name = "OPENAI_API_KEY"; embedding = "key" },
                    [ordered]@{ name = "OPENAI_MODEL"; embedding = "model" }
                )
                volumes = @(
                    [ordered]@{ from = "PATH_METADATA"; to = "/app/metadata"; required = $true },
                    [ordered]@{ from = "PATH_CODE"; to = "/app/code"; required = $true; fallback = "exportPath" },
                    [ordered]@{ from = "PATH_BASES"; to = "/app/chroma_db"; required = $false; subdir = "mcp_codemetadata"; fallback = "mcpBases" }
                )
            },
            [ordered]@{
                id = "graph"
                title = "Project graph metadata search"
                scope = "project"
                mcpNameTemplate = "itl-{projectSlug}-graph"
                containerNameTemplate = "itl-{projectSlug}-graph"
                compose = $true
                composePath = "Graph_metadata_search\docker-compose.yml"
                composeProjectTemplate = "itl-{projectSlug}-graph"
                internalPort = 8006
                healthPath = "/mcp"
                embedding = $true
                env = @(
                    [ordered]@{ name = "LICENSE_KEY"; from = "LICENSE_KEY_GRAPH"; required = $true },
                    [ordered]@{ name = "METADATA_HOST_PATH"; from = "PATH_METADATA"; required = $true },
                    [ordered]@{ name = "METADATA_FILES_HOST_PATH"; from = "PATH_CODE"; required = $true; fallback = "exportPath" },
                    [ordered]@{ name = "OPENAI_API_KEY"; from = "CHAT_API_KEY"; required = $false },
                    [ordered]@{ name = "OPENAI_API_BASE"; from = "CHAT_API_BASE"; required = $false },
                    [ordered]@{ name = "OPENAI_MODEL"; from = "CHAT_MODEL"; required = $false },
                    [ordered]@{ name = "OPENAI_EMBEDDING_API_KEY"; embedding = "key" },
                    [ordered]@{ name = "OPENAI_EMBEDDING_API_BASE"; embedding = "base" },
                    [ordered]@{ name = "OPENAI_EMBEDDING_MODEL"; embedding = "model" },
                    [ordered]@{ name = "MCP_PORT"; value = "8006" },
                    [ordered]@{ name = "MCP_USE_SSE"; value = "false" },
                    [ordered]@{ name = "RESET_DATABASE"; from = "RESET_DATABASE"; default = "false" },
                    [ordered]@{ name = "PROJECT_NAME"; value = "{projectSlug}" }
                )
                volumes = @()
            }
        )
    }
}

function Get-Vibecoding1cMcpBookStackServerDefinition {
    return [pscustomobject][ordered]@{
        id = "bookstack"
        title = "BookStack product documentation"
        scope = "global"
        image = "itl/bookstack-product-docs-mcp:local"
        internalPort = 8000
        mcpNameTemplate = "bookstack-product-docs"
        containerNameTemplate = "itl-bookstack-product-docs"
        env = @(
            [ordered]@{ name = "BOOKSTACK_BASE_URL"; from = "BOOKSTACK_BASE_URL"; required = $true },
            [ordered]@{ name = "BOOKSTACK_TOKEN_ID"; from = "BOOKSTACK_TOKEN_ID"; required = $true },
            [ordered]@{ name = "BOOKSTACK_TOKEN_SECRET"; from = "BOOKSTACK_TOKEN_SECRET"; required = $true },
            [ordered]@{ name = "BOOKSTACK_CACHE_PATH"; value = "/data/bookstack-cache.sqlite"; required = $false },
            [ordered]@{ name = "BOOKSTACK_REINDEX_INTERVAL_HOURS"; from = "BOOKSTACK_REINDEX_INTERVAL_HOURS"; default = "24"; required = $false },
            [ordered]@{ name = "BOOKSTACK_INDEX_ON_STARTUP"; from = "BOOKSTACK_INDEX_ON_STARTUP"; default = "true"; required = $false },
            [ordered]@{ name = "BOOKSTACK_MAX_INDEX_PAGES"; from = "BOOKSTACK_MAX_INDEX_PAGES"; required = $false },
            [ordered]@{ name = "RESET_DATABASE"; from = "BOOKSTACK_RESET_DATABASE"; default = "false"; required = $false },
            [ordered]@{ name = "BOOKSTACK_EMBEDDING_API_BASE"; embedding = "base"; required = $false },
            [ordered]@{ name = "BOOKSTACK_EMBEDDING_API_KEY"; embedding = "key"; required = $false },
            [ordered]@{ name = "BOOKSTACK_EMBEDDING_MODEL"; embedding = "model"; required = $false }
        )
        volumes = @()
    }
}

function Get-Vibecoding1cMcpMantisTicketServerDefinition {
    return [pscustomobject][ordered]@{
        id = "mantis"
        title = "Mantis ticket context"
        scope = "global"
        image = "itl/mantis-ticket-mcp:local"
        internalPort = 8000
        mcpNameTemplate = "itl-mantis-ticket-mcp"
        containerNameTemplate = "itl-mantis-ticket-mcp"
        env = @(
            [ordered]@{ name = "MANTIS_BASE_URL"; from = "MANTIS_BASE_URL"; required = $true },
            [ordered]@{ name = "MANTIS_API_TOKEN"; from = "MANTIS_API_TOKEN"; required = $true },
            [ordered]@{ name = "MANTIS_ATTACHMENT_CACHE_PATH"; value = "/data/attachments"; required = $false },
            [ordered]@{ name = "MANTIS_TIMEOUT_SECONDS"; from = "MANTIS_TIMEOUT_SECONDS"; default = "20"; required = $false },
            [ordered]@{ name = "MANTIS_MAX_ATTACHMENT_BYTES"; from = "MANTIS_MAX_ATTACHMENT_BYTES"; default = "26214400"; required = $false },
            [ordered]@{ name = "MANTIS_MAX_INLINE_TEXT_CHARS"; from = "MANTIS_MAX_INLINE_TEXT_CHARS"; default = "16000"; required = $false },
            [ordered]@{ name = "MANTIS_OCR_ENABLED"; from = "MANTIS_OCR_ENABLED"; default = "true"; required = $false },
            [ordered]@{ name = "MANTIS_OCR_LANGUAGES"; from = "MANTIS_OCR_LANGUAGES"; default = "rus,eng"; required = $false }
        )
        volumes = @()
    }
}

function Test-Vibecoding1cMcpBookStackVirtualServerEnabled {
    $configured = [string](Get-EnvValue -Name "VIBECODING1C_MCP_BOOKSTACK_ENABLED" -Default (Get-ConfigValue -Path "vibecoding1cMcp.bookStackProductDocsEnabled" -Default ""))
    if ($configured -match '^(1|true|yes|on)$') {
        return $true
    }
    if ($configured -match '^(0|false|no|off)$') {
        return $false
    }

    $registryPath = Join-Path (Get-Vibecoding1cMcpRegistryRoot) "registry.json"
    if (-not (Test-Path -LiteralPath $registryPath -PathType Leaf -ErrorAction SilentlyContinue)) {
        return $false
    }

    $registry = Read-Vibecoding1cMcpRegistry
    foreach ($endpoint in Get-Vibecoding1cMcpRegistryServers -Registry $registry) {
        if ([string](Get-Vibecoding1cMcpObjectValue -Object $endpoint -Name "family" -Default "") -ne "vibecoding1c") {
            continue
        }
        if ([string](Get-Vibecoding1cMcpObjectValue -Object $endpoint -Name "id" -Default "") -eq "bookstack") {
            return $true
        }
    }
    return $false
}

function Test-Vibecoding1cMcpMantisTicketVirtualServerEnabled {
    $configured = [string](Get-EnvValue -Name "VIBECODING1C_MCP_MANTIS_ENABLED" -Default (Get-ConfigValue -Path "vibecoding1cMcp.mantisTicketEnabled" -Default ""))
    if ($configured -match '^(1|true|yes|on)$') {
        return $true
    }
    if ($configured -match '^(0|false|no|off)$') {
        return $false
    }

    $registryPath = Join-Path (Get-Vibecoding1cMcpRegistryRoot) "registry.json"
    if (-not (Test-Path -LiteralPath $registryPath -PathType Leaf -ErrorAction SilentlyContinue)) {
        return $false
    }

    $registry = Read-Vibecoding1cMcpRegistry
    foreach ($endpoint in Get-Vibecoding1cMcpRegistryServers -Registry $registry) {
        if ([string](Get-Vibecoding1cMcpObjectValue -Object $endpoint -Name "family" -Default "") -ne "vibecoding1c") {
            continue
        }
        if ([string](Get-Vibecoding1cMcpObjectValue -Object $endpoint -Name "id" -Default "") -eq "mantis") {
            return $true
        }
    }
    return $false
}

function Add-Vibecoding1cMcpVirtualServersToManifest {
    param([object]$Manifest)

    $manifestHash = ConvertTo-Vibecoding1cMcpHashtable -Object $Manifest
    $servers = @(ConvertTo-Vibecoding1cMcpArray (Get-Vibecoding1cMcpObjectValue -Object $manifestHash -Name "servers" -Default @()))
    $hasBookStack = $false
    $hasMantis = $false
    foreach ($server in $servers) {
        $id = [string](Get-Vibecoding1cMcpObjectValue -Object $server -Name "id" -Default "")
        if ($id -eq "bookstack") {
            $hasBookStack = $true
        }
        if ($id -eq "mantis") {
            $hasMantis = $true
        }
    }
    if ((-not $hasBookStack) -and (Test-Vibecoding1cMcpBookStackVirtualServerEnabled)) {
        $servers += Get-Vibecoding1cMcpBookStackServerDefinition
    }
    if ((-not $hasMantis) -and (Test-Vibecoding1cMcpMantisTicketVirtualServerEnabled)) {
        $servers += Get-Vibecoding1cMcpMantisTicketServerDefinition
    }
    $manifestHash["servers"] = $servers
    return [pscustomobject]$manifestHash
}

function Read-Vibecoding1cMcpManifest {
    $distributionRoot = Get-Vibecoding1cMcpDistributionRoot
    $manifestPath = Join-Path $distributionRoot "vibecoding1c-mcp.manifest.json"
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf -ErrorAction SilentlyContinue) {
        return (Add-Vibecoding1cMcpVirtualServersToManifest -Manifest (Read-Utf8Text -Path $manifestPath | ConvertFrom-Json))
    }
    return (Add-Vibecoding1cMcpVirtualServersToManifest -Manifest (Get-Vibecoding1cMcpDefaultManifest))
}

function Get-Vibecoding1cMcpScopeContext {
    $projectSlug = ConvertTo-SafeName (Split-Path -Leaf $script:ProjectRoot)
    $gitBranch = ""
    try {
        if (Test-Path -LiteralPath (Join-Path $script:ProjectRoot ".git")) {
            $gitBranch = Get-CurrentBranch
        }
    } catch {
        $gitBranch = ""
    }

    $branchSlug = ""
    if ($gitBranch -like "itldev/*") {
        $branchSlug = ConvertTo-SafeName ($gitBranch.Substring("itldev/".Length))
    } elseif ($gitBranch) {
        $branchSlug = ConvertTo-SafeName $gitBranch
    } else {
        $branchSlug = "no-branch"
    }

    return [pscustomobject]@{
        projectRoot = $script:ProjectRoot
        projectSlug = $projectSlug
        gitBranch = $gitBranch
        branchSlug = $branchSlug
        isDevelopmentBranch = ($gitBranch -like "itldev/*")
    }
}

function Expand-Vibecoding1cMcpTemplate {
    param(
        [string]$Template,
        [object]$Context,
        [string]$ServerId = ""
    )

    $value = $Template
    $value = $value.Replace("{projectSlug}", [string](Get-Vibecoding1cMcpObjectValue -Object $Context -Name "projectSlug" -Default "project"))
    $value = $value.Replace("{branchSlug}", [string](Get-Vibecoding1cMcpObjectValue -Object $Context -Name "branchSlug" -Default "branch"))
    $value = $value.Replace("{serverId}", $ServerId)
    return $value
}

function Get-Vibecoding1cMcpImageName {
    param(
        [object]$Server,
        [object]$ConfigContext
    )

    $image = [string](Get-Vibecoding1cMcpObjectValue -Object $Server -Name "image" -Default "")
    $imageTag = [string](Get-Vibecoding1cMcpConfigValue -Context $ConfigContext -Name "IMAGE_TAG" -Default "latest")
    if ($imageTag -eq "light" -and $image -match ':latest$') {
        return $image
    }
    return $image.Replace("{imageTag}", $imageTag)
}

function Get-Vibecoding1cMcpPortRange {
    param([string]$Scope)

    switch ($Scope) {
        "global" { return [pscustomobject]@{ start = 18000; end = 18099 } }
        "project" { return [pscustomobject]@{ start = 18100; end = 18499 } }
        "branch" { return [pscustomobject]@{ start = 18500; end = 18999 } }
        "model" { return [pscustomobject]@{ start = 19000; end = 19049 } }
        default { throw "Unknown vibecoding1c MCP port scope: $Scope" }
    }
}

function Test-Vibecoding1cMcpDockerAvailable {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        return $false
    }
    & docker info *> $null
    return ($LASTEXITCODE -eq 0)
}

function Get-Vibecoding1cMcpDockerContainerStatus {
    param([string]$ContainerName)

    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        return ""
    }
    $output = & docker ps -a --filter "name=^/$ContainerName$" --format "{{.Names}}|{{.Status}}" 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $output) {
        return ""
    }
    foreach ($line in @($output)) {
        if ($line -like "$ContainerName|*") {
            return ($line.Substring($ContainerName.Length + 1))
        }
    }
    return ""
}

function Test-Vibecoding1cMcpDockerContainerExists {
    param([string]$ContainerName)
    return -not [string]::IsNullOrWhiteSpace((Get-Vibecoding1cMcpDockerContainerStatus -ContainerName $ContainerName))
}

function Remove-Vibecoding1cMcpStalePortAllocations {
    param([object]$Registry)

    $kept = @()
    foreach ($allocation in ConvertTo-Vibecoding1cMcpArray (Get-Vibecoding1cMcpObjectValue -Object $Registry -Name "allocations" -Default @())) {
        $port = ConvertTo-IntOrDefault -Value (Get-Vibecoding1cMcpObjectValue -Object $allocation -Name "port" -Default 0)
        $containerName = [string](Get-Vibecoding1cMcpObjectValue -Object $allocation -Name "containerName" -Default "")
        if ($containerName -and (Test-Vibecoding1cMcpDockerContainerExists -ContainerName $containerName)) {
            $kept += $allocation
            continue
        }
        if ($port -gt 0 -and -not (Test-TcpPortAvailable -Port $port)) {
            $kept += $allocation
            continue
        }
    }

    $hash = ConvertTo-Vibecoding1cMcpHashtable -Object $Registry
    $hash["allocations"] = $kept
    return [pscustomobject]$hash
}

function Resolve-Vibecoding1cMcpPort {
    param(
        [string]$Scope,
        [string]$Key,
        [string]$ServerId,
        [string]$ContainerName
    )

    $range = Get-Vibecoding1cMcpPortRange -Scope $Scope
    $context = Get-Vibecoding1cMcpScopeContext
    $state = [pscustomobject]@{
        stateProjectRoot = $script:ProjectRoot
        worktreePath = $script:ProjectRoot
        devBranchName = $context.branchSlug
        safeDevBranchName = $context.branchSlug
        devBranch = $context.gitBranch
    }
    return (Resolve-ItlManagedPort `
        -Family "vibecoding1c-mcp" `
        -Key $Key `
        -Start $range.start `
        -End $range.end `
        -State $state `
        -Scope $Scope `
        -ServerId $ServerId `
        -ContainerName $ContainerName `
        -Subject "vibecoding1c MCP host port")
}

function Resolve-Vibecoding1cMcpModelPort {
    if ((Test-Vibecoding1cMcpEmbeddingEndpoint -Port 1234) -or (Test-TcpPortAvailable -Port 1234)) {
        return 1234
    }
    return (Resolve-Vibecoding1cMcpPort -Scope "model" -Key "model:lm-studio" -ServerId "lm-studio" -ContainerName "")
}

function Get-Vibecoding1cMcpHardwareProfile {
    $gpuMemoryMb = 0
    if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
        try {
            $values = & nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>$null
            foreach ($value in @($values)) {
                $parsed = ConvertTo-IntOrDefault -Value $value -Default 0
                if ($parsed -gt $gpuMemoryMb) {
                    $gpuMemoryMb = $parsed
                }
            }
        } catch {
            $gpuMemoryMb = 0
        }
    }

    $ramGb = 0
    try {
        $computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $ramGb = [int][Math]::Round(([double]$computer.TotalPhysicalMemory / 1GB), 0)
    } catch {
        $ramGb = 0
    }

    return [pscustomobject]@{
        gpuMemoryMb = $gpuMemoryMb
        ramGb = $ramGb
    }
}

function Select-Vibecoding1cMcpEmbeddingModel {
    param(
        [int]$GpuMemoryMb = -1,
        [int]$RamGb = -1
    )

    if ($GpuMemoryMb -lt 0 -or $RamGb -lt 0) {
        $profile = Get-Vibecoding1cMcpHardwareProfile
        if ($GpuMemoryMb -lt 0) {
            $GpuMemoryMb = [int]$profile.gpuMemoryMb
        }
        if ($RamGb -lt 0) {
            $RamGb = [int]$profile.ramGb
        }
    }

    if ($GpuMemoryMb -ge 6144) {
        return [pscustomobject]@{ provider = "lm-studio"; mode = "gpu"; model = "Qwen3-Embedding-4B-GGUF"; quantization = "Q8_0"; modelId = "Qwen3-Embedding-4B-GGUF:Q8_0"; gpuMemoryMb = $GpuMemoryMb; ramGb = $RamGb }
    }
    if ($GpuMemoryMb -ge 4096) {
        return [pscustomobject]@{ provider = "lm-studio"; mode = "gpu"; model = "Qwen3-Embedding-4B-GGUF"; quantization = "Q6_K"; modelId = "Qwen3-Embedding-4B-GGUF:Q6_K"; gpuMemoryMb = $GpuMemoryMb; ramGb = $RamGb }
    }
    if ($GpuMemoryMb -ge 3072) {
        return [pscustomobject]@{ provider = "lm-studio"; mode = "gpu"; model = "Qwen3-Embedding-4B-GGUF"; quantization = "Q4_K_M"; modelId = "Qwen3-Embedding-4B-GGUF:Q4_K_M"; gpuMemoryMb = $GpuMemoryMb; ramGb = $RamGb }
    }
    if ($RamGb -gt 0 -and $RamGb -lt 16) {
        return [pscustomobject]@{ provider = "lm-studio"; mode = "cpu"; model = "intfloat/multilingual-e5-small"; quantization = ""; modelId = "intfloat/multilingual-e5-small"; gpuMemoryMb = $GpuMemoryMb; ramGb = $RamGb }
    }
    return [pscustomobject]@{ provider = "lm-studio"; mode = "cpu"; model = "intfloat/multilingual-e5-base"; quantization = ""; modelId = "intfloat/multilingual-e5-base"; gpuMemoryMb = $GpuMemoryMb; ramGb = $RamGb }
}

function Test-Vibecoding1cMcpEmbeddingEndpoint {
    param([int]$Port)

    try {
        $uri = "http://127.0.0.1:$Port/v1/models"
        Invoke-WebRequest -Uri $uri -UseBasicParsing -TimeoutSec 3 | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Ensure-Vibecoding1cMcpModel {
    Write-Section "vibecoding1c MCP embedding model"

    $state = Read-Vibecoding1cMcpState
    $stateHash = ConvertTo-Vibecoding1cMcpHashtable -Object $state
    $previousModel = Get-Vibecoding1cMcpObjectValue -Object (Get-Vibecoding1cMcpObjectValue -Object $state -Name "model" -Default $null) -Name "modelId" -Default ""
    $selection = Select-Vibecoding1cMcpEmbeddingModel
    $port = Resolve-Vibecoding1cMcpModelPort
    $apiBase = "http://host.docker.internal:$port/v1"
    $ready = Test-Vibecoding1cMcpEmbeddingEndpoint -Port $port
    $lms = Get-Command lms -ErrorAction SilentlyContinue
    $notes = @()

    if (-not $ready -and $lms) {
        try {
            & lms get $selection.model *> $null
            if ($LASTEXITCODE -ne 0) {
                $notes += "lms get returned exit code $LASTEXITCODE for $($selection.model)."
            }
        } catch {
            $notes += "lms get failed for $($selection.model): $($_.Exception.Message)"
        }
        try {
            & lms load $selection.model *> $null
            if ($LASTEXITCODE -ne 0) {
                $notes += "lms load returned exit code $LASTEXITCODE for $($selection.model)."
            }
        } catch {
            $notes += "lms load failed for $($selection.model): $($_.Exception.Message)"
        }
        try {
            & lms server start --port $port *> $null
            if ($LASTEXITCODE -ne 0) {
                $notes += "lms server start returned exit code $LASTEXITCODE on port $port."
            }
        } catch {
            $notes += "lms server start failed on port ${port}: $($_.Exception.Message)"
        }
        $ready = Test-Vibecoding1cMcpEmbeddingEndpoint -Port $port
    } elseif (-not $ready) {
        $notes += "LM Studio CLI 'lms' was not found. Install LM Studio, open it once, then rerun vibecoding1c-mcp-ensure-model."
    }

    if ($previousModel -and $previousModel -ne $selection.modelId) {
        $stateHash["staleIndexes"] = @("docs", "templates", "ssl", "code", "graph", "bookstack")
        Write-Host "Embedding model changed from $previousModel to $($selection.modelId). Affected indexes are marked stale; set RESET_DATABASE=true explicitly before reindexing."
    } elseif (-not $stateHash.Contains("staleIndexes")) {
        $stateHash["staleIndexes"] = @()
    }

    $stateHash["model"] = [ordered]@{
        provider = $selection.provider
        mode = $selection.mode
        model = $selection.model
        quantization = $selection.quantization
        modelId = $selection.modelId
        port = $port
        apiBase = $apiBase
        apiKey = "lm-studio"
        ready = [bool]$ready
        gpuMemoryMb = $selection.gpuMemoryMb
        ramGb = $selection.ramGb
        updatedAt = (Get-Date).ToString("o")
        notes = $notes
    }

    Write-Vibecoding1cMcpState -State $stateHash

    Write-Host "Selected embedding model: $($selection.modelId)"
    Write-Host "Embedding API base for containers: $apiBase"
    Write-Host "Embedding endpoint ready: $ready"
    foreach ($note in $notes) {
        Write-Host "NOTE: $note"
    }

    return [pscustomobject]$stateHash["model"]
}

function Get-Vibecoding1cMcpEmbeddingEnv {
    $state = Read-Vibecoding1cMcpState
    $model = Get-Vibecoding1cMcpObjectValue -Object $state -Name "model" -Default $null
    if ($null -eq $model) {
        $model = Ensure-Vibecoding1cMcpModel
    }

    return [pscustomobject]@{
        base = [string](Get-Vibecoding1cMcpObjectValue -Object $model -Name "apiBase" -Default "")
        key = [string](Get-Vibecoding1cMcpObjectValue -Object $model -Name "apiKey" -Default "lm-studio")
        model = [string](Get-Vibecoding1cMcpObjectValue -Object $model -Name "model" -Default "")
    }
}

function Resolve-Vibecoding1cMcpConfiguredPath {
    param(
        [object]$ConfigContext,
        [string]$Name,
        [string]$Fallback = "",
        [string]$Subdir = ""
    )

    $value = [string](Get-Vibecoding1cMcpConfigValue -Context $ConfigContext -Name $Name -Default "")
    if (-not $value -and $Fallback -eq "exportPath") {
        $value = Resolve-ProjectPath (Get-ExportPath)
    }
    if (-not $value -and $Fallback -eq "mcpBases") {
        $value = Join-Path $script:ProjectRoot ".agent-1c\mcp\bases"
    }
    if (-not $value) {
        return ""
    }
    $value = [Environment]::ExpandEnvironmentVariables($value)
    if (-not [System.IO.Path]::IsPathRooted($value)) {
        $value = Resolve-ProjectPath $value
    }
    if ($Subdir) {
        $value = Join-Path $value $Subdir
    }
    return [System.IO.Path]::GetFullPath($value)
}

function New-Vibecoding1cMcpServerRuntime {
    param(
        [object]$Server,
        [object]$Context,
        [object]$ConfigContext
    )

    $id = [string](Get-Vibecoding1cMcpObjectValue -Object $Server -Name "id" -Default "")
    $scope = Get-Vibecoding1cMcpServerScope -Server $Server
    $nameTemplate = [string](Get-Vibecoding1cMcpObjectValue -Object $Server -Name "mcpNameTemplate" -Default "itl-$id")
    $containerTemplate = [string](Get-Vibecoding1cMcpObjectValue -Object $Server -Name "containerNameTemplate" -Default $nameTemplate)
    $mcpName = Expand-Vibecoding1cMcpTemplate -Template $nameTemplate -Context $Context -ServerId $id
    $containerName = Expand-Vibecoding1cMcpTemplate -Template $containerTemplate -Context $Context -ServerId $id
    $portKey = "${scope}:$mcpName"
    $internalPort = ConvertTo-IntOrDefault -Value (Get-Vibecoding1cMcpObjectValue -Object $Server -Name "internalPort" -Default 0)
    $hostPort = 0
    if ($internalPort -gt 0) {
        $hostPort = Resolve-Vibecoding1cMcpPort -Scope $scope -Key $portKey -ServerId $id -ContainerName $containerName
    }

    $url = ""
    if ($hostPort -gt 0) {
        $url = "http://127.0.0.1:$hostPort/mcp"
    }

    return [pscustomobject]@{
        id = $id
        scope = $scope
        name = $mcpName
        containerName = $containerName
        internalPort = $internalPort
        hostPort = $hostPort
        url = $url
        projectSlug = $Context.projectSlug
        branchSlug = $Context.branchSlug
        gitBranch = $Context.gitBranch
        projectRoot = $Context.projectRoot
        family = "vibecoding1c"
        provider = "local"
        clientNames = (Get-Vibecoding1cMcpClientNames -ServerId $id)
        configId = ""
        health = ""
        sourceCommit = $(try { Get-CurrentCommit } catch { "" })
        sourceFingerprint = $(Get-Vibecoding1cMcpCurrentSourceFingerprint)
        reportHash = ""
        indexedAt = ""
        image = (Get-Vibecoding1cMcpImageName -Server $Server -ConfigContext $ConfigContext)
    }
}

function Resolve-Vibecoding1cMcpEnvironment {
    param(
        [object]$Server,
        [object]$Runtime,
        [object]$ConfigContext
    )

    $embedding = Get-Vibecoding1cMcpEmbeddingEnv
    $env = [ordered]@{}
    $missing = @()
    foreach ($entry in ConvertTo-Vibecoding1cMcpArray (Get-Vibecoding1cMcpObjectValue -Object $Server -Name "env" -Default @())) {
        $name = [string](Get-Vibecoding1cMcpObjectValue -Object $entry -Name "name" -Default "")
        if (-not $name) {
            continue
        }

        $value = ""
        $embeddingKind = [string](Get-Vibecoding1cMcpObjectValue -Object $entry -Name "embedding" -Default "")
        if ($embeddingKind) {
            $value = [string](Get-Vibecoding1cMcpObjectValue -Object $embedding -Name $embeddingKind -Default "")
        } elseif (Get-Vibecoding1cMcpObjectValue -Object $entry -Name "value" -Default $null) {
            $value = [string](Get-Vibecoding1cMcpObjectValue -Object $entry -Name "value" -Default "")
            $value = $value.Replace("{projectSlug}", [string](Get-Vibecoding1cMcpObjectValue -Object $Runtime -Name "projectSlug" -Default ""))
            $value = $value.Replace("{branchSlug}", [string](Get-Vibecoding1cMcpObjectValue -Object $Runtime -Name "branchSlug" -Default ""))
        } else {
            $from = [string](Get-Vibecoding1cMcpObjectValue -Object $entry -Name "from" -Default "")
            $fallback = [string](Get-Vibecoding1cMcpObjectValue -Object $entry -Name "fallback" -Default "")
            if ($from -like "PATH_*") {
                $value = Resolve-Vibecoding1cMcpConfiguredPath -ConfigContext $ConfigContext -Name $from -Fallback $fallback
            } else {
                $value = [string](Get-Vibecoding1cMcpConfigValue -Context $ConfigContext -Name $from -Default (Get-Vibecoding1cMcpObjectValue -Object $entry -Name "default" -Default ""))
            }
        }

        $required = ConvertTo-BoolSetting -Value (Get-Vibecoding1cMcpObjectValue -Object $entry -Name "required" -Default $false) -Default $false
        if ($required -and [string]::IsNullOrWhiteSpace($value)) {
            $missing += $name
            continue
        }
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $env[$name] = $value
        }
    }

    $id = [string](Get-Vibecoding1cMcpObjectValue -Object $Server -Name "id" -Default "")
    if ($id -eq "graph") {
        foreach ($fallback in @(
            [pscustomobject]@{ name = "OPENAI_API_KEY"; embeddingName = "key" },
            [pscustomobject]@{ name = "OPENAI_API_BASE"; embeddingName = "base" },
            [pscustomobject]@{ name = "OPENAI_MODEL"; embeddingName = "model" }
        )) {
            $current = ""
            if ($env.Contains($fallback.name)) {
                $current = [string]$env[$fallback.name]
            }
            if (-not [string]::IsNullOrWhiteSpace($current)) {
                continue
            }
            $value = [string](Get-Vibecoding1cMcpObjectValue -Object $embedding -Name $fallback.embeddingName -Default "")
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                $env[$fallback.name] = $value
            }
        }
    }

    return [pscustomobject]@{
        values = $env
        missing = $missing
    }
}

function Resolve-Vibecoding1cMcpVolumes {
    param(
        [object]$Server,
        [object]$ConfigContext
    )

    $volumes = @()
    $missing = @()
    foreach ($entry in ConvertTo-Vibecoding1cMcpArray (Get-Vibecoding1cMcpObjectValue -Object $Server -Name "volumes" -Default @())) {
        $from = [string](Get-Vibecoding1cMcpObjectValue -Object $entry -Name "from" -Default "")
        $to = [string](Get-Vibecoding1cMcpObjectValue -Object $entry -Name "to" -Default "")
        if (-not $from -or -not $to) {
            continue
        }
        $hostPath = Resolve-Vibecoding1cMcpConfiguredPath -ConfigContext $ConfigContext -Name $from -Fallback ([string](Get-Vibecoding1cMcpObjectValue -Object $entry -Name "fallback" -Default "")) -Subdir ([string](Get-Vibecoding1cMcpObjectValue -Object $entry -Name "subdir" -Default ""))
        $required = ConvertTo-BoolSetting -Value (Get-Vibecoding1cMcpObjectValue -Object $entry -Name "required" -Default $false) -Default $false
        if (-not $hostPath) {
            if ($required) {
                $missing += $from
            }
            continue
        }
        if ($required -and -not (Test-Path -LiteralPath $hostPath -ErrorAction SilentlyContinue)) {
            $missing += $from
            continue
        }
        New-Item -ItemType Directory -Force -Path $hostPath | Out-Null
        $volumes += [pscustomobject]@{ host = $hostPath; container = $to }
    }

    return [pscustomobject]@{
        values = $volumes
        missing = $missing
    }
}

function Set-Vibecoding1cMcpEndpointState {
    param(
        [object]$Runtime,
        [string]$Status,
        [string]$RuntimePath = "",
        [string]$ComposeProject = ""
    )

    $state = Read-Vibecoding1cMcpState
    $stateHash = ConvertTo-Vibecoding1cMcpHashtable -Object $state
    $servers = @()
    foreach ($server in ConvertTo-Vibecoding1cMcpArray (Get-Vibecoding1cMcpObjectValue -Object $state -Name "servers" -Default @())) {
        if ([string](Get-Vibecoding1cMcpObjectValue -Object $server -Name "name" -Default "") -ne $Runtime.name) {
            $servers += $server
        }
    }

    $servers += [ordered]@{
        id = $Runtime.id
        scope = $Runtime.scope
        name = $Runtime.name
        containerName = $Runtime.containerName
        internalPort = $Runtime.internalPort
        hostPort = $Runtime.hostPort
        url = $Runtime.url
        status = $Status
        family = "vibecoding1c"
        provider = [string](Get-Vibecoding1cMcpObjectValue -Object $Runtime -Name "provider" -Default "local")
        hostId = [string](Get-Vibecoding1cMcpObjectValue -Object $Runtime -Name "hostId" -Default "")
        hostPublishedAt = [string](Get-Vibecoding1cMcpObjectValue -Object $Runtime -Name "hostPublishedAt" -Default "")
        hostBaseUrl = [string](Get-Vibecoding1cMcpObjectValue -Object $Runtime -Name "hostBaseUrl" -Default "")
        configId = [string](Get-Vibecoding1cMcpObjectValue -Object $Runtime -Name "configId" -Default "")
        health = [string](Get-Vibecoding1cMcpObjectValue -Object $Runtime -Name "health" -Default "")
        platformVersion = [string](Get-Vibecoding1cMcpObjectValue -Object $Runtime -Name "platformVersion" -Default "")
        bspVersion = [string](Get-Vibecoding1cMcpObjectValue -Object $Runtime -Name "bspVersion" -Default "")
        configurationName = [string](Get-Vibecoding1cMcpObjectValue -Object $Runtime -Name "configurationName" -Default "")
        configurationVersion = [string](Get-Vibecoding1cMcpObjectValue -Object $Runtime -Name "configurationVersion" -Default "")
        embeddingMode = [string](Get-Vibecoding1cMcpObjectValue -Object $Runtime -Name "embeddingMode" -Default "")
        embeddingModel = [string](Get-Vibecoding1cMcpObjectValue -Object $Runtime -Name "embeddingModel" -Default "")
        sourceCommit = [string](Get-Vibecoding1cMcpObjectValue -Object $Runtime -Name "sourceCommit" -Default "")
        sourceFingerprint = [string](Get-Vibecoding1cMcpObjectValue -Object $Runtime -Name "sourceFingerprint" -Default "")
        reportHash = [string](Get-Vibecoding1cMcpObjectValue -Object $Runtime -Name "reportHash" -Default "")
        indexedAt = [string](Get-Vibecoding1cMcpObjectValue -Object $Runtime -Name "indexedAt" -Default "")
        freshness = [string](Get-Vibecoding1cMcpObjectValue -Object $Runtime -Name "freshness" -Default "")
        image = $Runtime.image
        projectSlug = $Runtime.projectSlug
        branchSlug = $Runtime.branchSlug
        gitBranch = $Runtime.gitBranch
        projectRoot = $Runtime.projectRoot
        runtimePath = $RuntimePath
        composeProject = $ComposeProject
        updatedAt = (Get-Date).ToString("o")
    }

    $stateHash["servers"] = $servers
    Write-Vibecoding1cMcpState -State $stateHash
}

function Start-Vibecoding1cMcpDockerRunServer {
    param(
        [object]$Server,
        [object]$Runtime,
        [object]$ConfigContext
    )

    $envResult = Resolve-Vibecoding1cMcpEnvironment -Server $Server -Runtime $Runtime -ConfigContext $ConfigContext
    $volumeResult = Resolve-Vibecoding1cMcpVolumes -Server $Server -ConfigContext $ConfigContext
    $missing = @($envResult.missing + $volumeResult.missing)
    if ($missing.Count -gt 0) {
        Write-Host "Skipping $($Runtime.name): missing required settings $($missing -join ', ')."
        Set-Vibecoding1cMcpEndpointState -Runtime $Runtime -Status "missing-settings"
        return
    }

    if (-not (Test-Vibecoding1cMcpDockerAvailable)) {
        Write-Host "Skipping $($Runtime.name): Docker is not available."
        Set-Vibecoding1cMcpEndpointState -Runtime $Runtime -Status "docker-unavailable"
        return
    }

    $existing = Get-Vibecoding1cMcpDockerContainerStatus -ContainerName $Runtime.containerName
    if ($existing) {
        & docker start $Runtime.containerName | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Docker failed to start existing container $($Runtime.containerName)."
        }
        Write-Host "Started existing MCP container: $($Runtime.containerName) -> $($Runtime.url)"
        Set-Vibecoding1cMcpEndpointState -Runtime $Runtime -Status "running"
        Set-ItlManagedPortAllocationStatus -Family "vibecoding1c-mcp" -Key "$($Runtime.scope):$($Runtime.name)" -Status "running"
        return
    }

    $args = @("run", "-d", "--name", $Runtime.containerName, "-p", "$($Runtime.hostPort):$($Runtime.internalPort)")
    $useGpu = ConvertTo-BoolSetting -Value (Get-Vibecoding1cMcpConfigValue -Context $ConfigContext -Name "USE_GPU" -Default $false) -Default $false
    if ($useGpu) {
        $args += @("--gpus", "all")
    }
    foreach ($key in @($envResult.values.Keys | Sort-Object)) {
        $args += @("-e", "$key=$($envResult.values[$key])")
    }
    foreach ($volume in $volumeResult.values) {
        $args += @("-v", "$($volume.host):$($volume.container)")
    }
    $args += $Runtime.image

    & docker @args | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Docker failed to create MCP container $($Runtime.containerName)."
    }

    Write-Host "Started MCP container: $($Runtime.containerName) -> $($Runtime.url)"
    Set-Vibecoding1cMcpEndpointState -Runtime $Runtime -Status "running"
    Set-ItlManagedPortAllocationStatus -Family "vibecoding1c-mcp" -Key "$($Runtime.scope):$($Runtime.name)" -Status "running"
}

function New-Vibecoding1cMcpScopedCompose {
    param(
        [object]$Server,
        [object]$Runtime,
        [object]$ConfigContext
    )

    $distributionRoot = [string](Get-Vibecoding1cMcpObjectValue -Object $ConfigContext -Name "distributionRoot" -Default (Get-Vibecoding1cMcpDistributionRoot))
    $composePath = [string](Get-Vibecoding1cMcpObjectValue -Object $Server -Name "composePath" -Default "")
    $sourceCompose = Join-Path $distributionRoot $composePath
    if (-not (Test-Path -LiteralPath $sourceCompose -PathType Leaf -ErrorAction SilentlyContinue)) {
        throw "Compose file was not found for $($Runtime.name): $sourceCompose"
    }

    $runtimeDir = Join-Path $script:ProjectRoot ".agent-1c\mcp\$($Runtime.scope)-$($Runtime.name)"
    New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null
    $targetCompose = Join-Path $runtimeDir "docker-compose.yml"
    $composeText = Read-Utf8Text -Path $sourceCompose
    $composeText = $composeText -replace '(?m)^\s*container_name:\s*neo4j\s*$', "    container_name: $($Runtime.containerName)-neo4j"
    $composeText = $composeText -replace '(?m)^\s*container_name:\s*1c_graph_metadata\s*$', "    container_name: $($Runtime.containerName)"
    $composeText = [regex]::Replace($composeText, '(?ms)^    ports:\r?\n      - "7474:7474"\r?\n      - "7687:7687"\r?\n', '')
    $composeText = $composeText -replace '"8006:8006"', "`"$($Runtime.hostPort):$($Runtime.internalPort)`""
    Write-Utf8Text -Path $targetCompose -Value $composeText

    $envResult = Resolve-Vibecoding1cMcpEnvironment -Server $Server -Runtime $Runtime -ConfigContext $ConfigContext
    if ($envResult.missing.Count -gt 0) {
        return [pscustomobject]@{
            ready = $false
            missing = $envResult.missing
            runtimeDir = $runtimeDir
            composePath = $targetCompose
            composeProject = ""
        }
    }

    $envPath = Join-Path $runtimeDir ".env"
    Write-Vibecoding1cMcpDotEnvFile -Path $envPath -Values $envResult.values
    $composeProjectTemplate = [string](Get-Vibecoding1cMcpObjectValue -Object $Server -Name "composeProjectTemplate" -Default $Runtime.name)
    $composeProject = Expand-Vibecoding1cMcpTemplate -Template $composeProjectTemplate -Context (Get-Vibecoding1cMcpScopeContext) -ServerId $Runtime.id
    return [pscustomobject]@{
        ready = $true
        missing = @()
        runtimeDir = $runtimeDir
        composePath = $targetCompose
        composeProject = $composeProject
    }
}

function Start-Vibecoding1cMcpComposeServer {
    param(
        [object]$Server,
        [object]$Runtime,
        [object]$ConfigContext
    )

    $compose = New-Vibecoding1cMcpScopedCompose -Server $Server -Runtime $Runtime -ConfigContext $ConfigContext
    if (-not $compose.ready) {
        Write-Host "Skipping $($Runtime.name): missing required settings $($compose.missing -join ', ')."
        Set-Vibecoding1cMcpEndpointState -Runtime $Runtime -Status "missing-settings" -RuntimePath $compose.runtimeDir -ComposeProject $compose.composeProject
        return
    }

    if (-not (Test-Vibecoding1cMcpDockerAvailable)) {
        Write-Host "Skipping $($Runtime.name): Docker is not available."
        Set-Vibecoding1cMcpEndpointState -Runtime $Runtime -Status "docker-unavailable" -RuntimePath $compose.runtimeDir -ComposeProject $compose.composeProject
        return
    }

    & docker compose -p $compose.composeProject -f $compose.composePath --env-file (Join-Path $compose.runtimeDir ".env") up -d | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Docker compose failed for MCP server $($Runtime.name)."
    }

    Write-Host "Started MCP compose project: $($compose.composeProject) -> $($Runtime.url)"
    Set-Vibecoding1cMcpEndpointState -Runtime $Runtime -Status "running" -RuntimePath $compose.runtimeDir -ComposeProject $compose.composeProject
    Set-ItlManagedPortAllocationStatus -Family "vibecoding1c-mcp" -Key "$($Runtime.scope):$($Runtime.name)" -Status "running"
}

function Get-Vibecoding1cMcpTargetScopes {
    $context = Get-Vibecoding1cMcpScopeContext
    switch ($McpScope) {
        "global" { return @("global") }
        "project" { return @("project") }
        "branch" { return @("branch") }
        "all" { return @("global", "project", "branch") }
        default {
            $scopes = @("global", "project")
            if ($context.isDevelopmentBranch) {
                $scopes += "branch"
            }
            return $scopes
        }
    }
}

function Select-Vibecoding1cMcpManifestServers {
    $manifest = Read-Vibecoding1cMcpManifest
    $targetScopes = Get-Vibecoding1cMcpTargetScopes
    $servers = @()
    foreach ($server in ConvertTo-Vibecoding1cMcpArray (Get-Vibecoding1cMcpObjectValue -Object $manifest -Name "servers" -Default @())) {
        $id = [string](Get-Vibecoding1cMcpObjectValue -Object $server -Name "id" -Default "")
        $scope = Get-Vibecoding1cMcpServerScope -Server $server
        if ($McpServerId -and $id -ne $McpServerId) {
            continue
        }
        if ($targetScopes -notcontains $scope) {
            continue
        }
        if (-not (Test-Vibecoding1cMcpServerAllowedForProject -Server $server)) {
            continue
        }
        $servers += $server
    }
    return $servers
}

function Rotate-Vibecoding1cMcpKeys {
    param([switch]$DistributionReady)

    Write-Section "vibecoding1c MCP rotate keys"

    if (-not $DistributionReady) {
        Ensure-Vibecoding1cMcpDistribution | Out-Null
    }

    $context = Get-Vibecoding1cMcpConfigContext
    $distributionConfigPath = [string]$context.distributionConfigPath
    if (-not (Test-Path -LiteralPath $distributionConfigPath -PathType Leaf -ErrorAction SilentlyContinue)) {
        throw "MCP distribution config.env was not found: $distributionConfigPath"
    }

    $sourceValues = Read-Vibecoding1cMcpDotEnvFile -Path $distributionConfigPath
    $rotated = [ordered]@{}
    foreach ($key in @($sourceValues.Keys | Sort-Object)) {
        if ($key -like "LICENSE_KEY_*" -or $key -eq "ONEC_AI_TOKEN") {
            $rotated[$key] = $sourceValues[$key]
        }
    }

    if ($rotated.Keys.Count -eq 0) {
        Write-Host "No license keys found in distribution config.env."
        return
    }

    Write-Vibecoding1cMcpDotEnvFile -Path $context.localConfigPath -Values $rotated
    $hashInput = (($rotated.Keys | Sort-Object | ForEach-Object { "$_=$($rotated[$_])" }) -join "`n")
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($hashInput)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $keyHash = ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant()
    $state = Read-Vibecoding1cMcpState
    $stateHash = ConvertTo-Vibecoding1cMcpHashtable -Object $state
    $stateHash["keyHash"] = $keyHash
    $stateHash["keyUpdatedAt"] = (Get-Date).ToString("o")
    Write-Vibecoding1cMcpState -State $stateHash

    Write-Host "Rotated MCP license keys into local config: $($context.localConfigPath)"
    Write-Host "Key hash: $keyHash"
}

function Start-Vibecoding1cMcp {
    param(
        [switch]$DistributionReady,
        [bool]$AllowPrompt = (Test-InteractiveInputAvailable)
    )

    Write-Section "Start vibecoding1c MCP"

    Ensure-GitIgnore
    $selection = Read-Vibecoding1cMcpSelection
    $context = Get-Vibecoding1cMcpScopeContext
    $selectedServers = @(Select-Vibecoding1cMcpManifestServers)
    $needsRegistry = $false
    $needsDistribution = $false
    $needsModel = $false
    foreach ($server in $selectedServers) {
        $provider = Get-Vibecoding1cMcpSelectedProvider -Server $server -Selection $selection
        if ($provider -eq "remote") {
            $needsRegistry = $true
        } else {
            $needsDistribution = $true
            if (ConvertTo-BoolSetting -Value (Get-Vibecoding1cMcpObjectValue -Object $server -Name "embedding" -Default $false) -Default $false) {
                $needsModel = $true
            }
        }
    }

    if ($needsRegistry) {
        Ensure-Vibecoding1cMcpRegistry | Out-Null
    }
    if ($needsDistribution -and -not $DistributionReady) {
        Ensure-Vibecoding1cMcpDistribution | Out-Null
    }
    if ($needsModel) {
        Ensure-Vibecoding1cMcpModel | Out-Null
    }

    $configContext = Get-Vibecoding1cMcpConfigContext
    foreach ($server in $selectedServers) {
        $provider = Get-Vibecoding1cMcpSelectedProvider -Server $server -Selection $selection
        if ($provider -eq "remote") {
            $runtime = New-Vibecoding1cMcpRemoteRuntime -Server $server -Selection $selection -AllowPrompt:$AllowPrompt
            if ($null -eq $runtime) {
                continue
            }
            $runtime | Add-Member -NotePropertyName freshness -NotePropertyValue (Get-Vibecoding1cMcpEndpointFreshness -Endpoint $runtime) -Force
            $unavailableStatus = Get-Vibecoding1cMcpEndpointUnavailableStatus -Endpoint $runtime
            if ($unavailableStatus) {
                Set-Vibecoding1cMcpEndpointState -Runtime $runtime -Status $unavailableStatus
                $runtimeHostId = [string](Get-Vibecoding1cMcpObjectValue -Object $runtime -Name "hostId" -Default "")
                $runtimeHostSuffix = if ($runtimeHostId) { " hostId=$runtimeHostId" } else { "" }
                Write-Host "Skipped unavailable remote vibecoding1c MCP endpoint: $($runtime.name)$runtimeHostSuffix status=$unavailableStatus -> $($runtime.url)"
                continue
            }
            Set-Vibecoding1cMcpEndpointState -Runtime $runtime -Status "running"
            $runtimeHostId = [string](Get-Vibecoding1cMcpObjectValue -Object $runtime -Name "hostId" -Default "")
            $runtimeHostSuffix = if ($runtimeHostId) { " hostId=$runtimeHostId" } else { "" }
            Write-Host "Connected remote vibecoding1c MCP endpoint: $($runtime.name)$runtimeHostSuffix -> $($runtime.url)"
            continue
        }

        $localScope = Get-Vibecoding1cMcpSelectedLocalScope -Server $server -Selection $selection
        $effectiveServer = ConvertTo-Vibecoding1cMcpLocalScopedServer -Server $server -LocalScope $localScope -Context $context
        $runtime = New-Vibecoding1cMcpServerRuntime -Server $effectiveServer -Context $context -ConfigContext $configContext
        if (ConvertTo-BoolSetting -Value (Get-Vibecoding1cMcpObjectValue -Object $effectiveServer -Name "compose" -Default $false) -Default $false) {
            Start-Vibecoding1cMcpComposeServer -Server $effectiveServer -Runtime $runtime -ConfigContext $configContext
        } else {
            Start-Vibecoding1cMcpDockerRunServer -Server $effectiveServer -Runtime $runtime -ConfigContext $configContext
        }
    }

    Write-Vibecoding1cMcpClientConfig
}

function Stop-Vibecoding1cMcp {
    Write-Section "Stop vibecoding1c MCP"

    $state = Read-Vibecoding1cMcpState
    $stateHash = ConvertTo-Vibecoding1cMcpHashtable -Object $state
    $context = Get-Vibecoding1cMcpScopeContext
    $targetScopes = Get-Vibecoding1cMcpTargetScopes
    $servers = @()
    foreach ($server in ConvertTo-Vibecoding1cMcpArray (Get-Vibecoding1cMcpObjectValue -Object $state -Name "servers" -Default @())) {
        $scope = [string](Get-Vibecoding1cMcpObjectValue -Object $server -Name "scope" -Default "")
        $name = [string](Get-Vibecoding1cMcpObjectValue -Object $server -Name "name" -Default "")
        if ($targetScopes -notcontains $scope) {
            $servers += $server
            continue
        }
        if ($scope -ne "global" -and ([string](Get-Vibecoding1cMcpObjectValue -Object $server -Name "projectSlug" -Default "")) -ne $context.projectSlug) {
            $servers += $server
            continue
        }
        if ($McpServerId -and ([string](Get-Vibecoding1cMcpObjectValue -Object $server -Name "id" -Default "")) -ne $McpServerId) {
            $servers += $server
            continue
        }

        $provider = [string](Get-Vibecoding1cMcpObjectValue -Object $server -Name "provider" -Default "local")
        if ($provider -eq "remote") {
            Write-Host "Disconnected remote vibecoding1c MCP endpoint from local config: $name"
        } else {
            $composeProject = [string](Get-Vibecoding1cMcpObjectValue -Object $server -Name "composeProject" -Default "")
            $runtimePath = [string](Get-Vibecoding1cMcpObjectValue -Object $server -Name "runtimePath" -Default "")
            if ($composeProject -and $runtimePath -and (Test-Vibecoding1cMcpDockerAvailable)) {
                $composePath = Join-Path $runtimePath "docker-compose.yml"
                if (Test-Path -LiteralPath $composePath -PathType Leaf -ErrorAction SilentlyContinue) {
                    & docker compose -p $composeProject -f $composePath --env-file (Join-Path $runtimePath ".env") down | Out-Null
                }
            } else {
                $containerName = [string](Get-Vibecoding1cMcpObjectValue -Object $server -Name "containerName" -Default "")
                if ($containerName -and (Test-Vibecoding1cMcpDockerAvailable) -and (Test-Vibecoding1cMcpDockerContainerExists -ContainerName $containerName)) {
                    & docker stop $containerName | Out-Null
                }
            }
        }

        $serverHash = ConvertTo-Vibecoding1cMcpHashtable -Object $server
        $serverHash["status"] = "stopped"
        $serverHash["updatedAt"] = (Get-Date).ToString("o")
        $servers += $serverHash
        if ($provider -ne "remote") {
            Set-ItlManagedPortAllocationStatus -Family "vibecoding1c-mcp" -Key "${scope}:$name" -Status "stopped"
        }
        Write-Host "Stopped MCP server: $name"
    }

    $stateHash["servers"] = $servers
    Write-Vibecoding1cMcpState -State $stateHash
    Write-Vibecoding1cMcpClientConfig
}

function Update-Vibecoding1cMcp {
    Write-Section "Update vibecoding1c MCP"

    try {
        Refresh-Vibecoding1cMcpRegistry
    } catch {
        Write-Host "WARNING: vibecoding1c MCP registry update failed: $($_.Exception.Message)"
    }

    Ensure-Vibecoding1cMcpDistribution | Out-Null
    if (Test-Path -LiteralPath (Join-Path (Get-Vibecoding1cMcpDistributionRoot) "config.env") -PathType Leaf -ErrorAction SilentlyContinue) {
        Rotate-Vibecoding1cMcpKeys -DistributionReady
    }
    $configContext = Get-Vibecoding1cMcpConfigContext
    if (-not (Test-Vibecoding1cMcpDockerAvailable)) {
        Write-Host "Docker is not available; image pull skipped."
        return
    }

    $pulled = @{}
    foreach ($server in ConvertTo-Vibecoding1cMcpArray (Get-Vibecoding1cMcpObjectValue -Object (Read-Vibecoding1cMcpManifest) -Name "servers" -Default @())) {
        $image = Get-Vibecoding1cMcpImageName -Server $server -ConfigContext $configContext
        if (-not $image -or $pulled.ContainsKey($image)) {
            continue
        }
        & docker pull $image | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "WARNING: docker pull failed for $image"
        } else {
            Write-Host "Pulled image: $image"
        }
        $pulled[$image] = $true
    }
}

function Invoke-DevBranchVibecoding1cMcpInheritance {
    param([string]$MainProjectRoot)

    try {
        if (-not (Copy-Vibecoding1cMcpSelectionFromMainWorktree -MainProjectRoot $MainProjectRoot)) {
            Write-Host "No vibecoding1c MCP selection found in main worktree; skipping automatic inheritance."
            return
        }

        $selection = Read-Vibecoding1cMcpSelection
        $selectionCompleteness = Get-Vibecoding1cMcpSelectionCompleteness -Selection $selection -RefreshRegistry
        if (-not $selectionCompleteness.isComplete) {
            Write-Warning "vibecoding1c MCP selection is incomplete; automatic inheritance was skipped."
            foreach ($reason in $selectionCompleteness.reasons) {
                Write-Host "  - $reason"
            }
            Write-Host "Run when ready:"
            Write-Host "  powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action vibecoding1c-mcp-setup"
            return
        }

        $needsLocalDistribution = Test-Vibecoding1cMcpSelectionNeedsLocalDistribution -Selection $selection
        if ($needsLocalDistribution) {
            Ensure-Vibecoding1cMcpDistribution | Out-Null
            if (Test-Path -LiteralPath (Join-Path (Get-Vibecoding1cMcpDistributionRoot) "config.env") -PathType Leaf -ErrorAction SilentlyContinue) {
                Rotate-Vibecoding1cMcpKeys -DistributionReady
            } else {
                Write-Host "Distribution config.env not found; key rotation skipped."
            }
        } else {
            Refresh-Vibecoding1cMcpRegistry
        }

        Start-Vibecoding1cMcp -DistributionReady:$needsLocalDistribution -AllowPrompt:$false
    } catch {
        Write-Warning "Automatic vibecoding1c MCP inheritance failed. $($_.Exception.Message)"
        Write-Host "Run when ready:"
        Write-Host "  powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action vibecoding1c-mcp-setup"
    }
}

function Setup-Vibecoding1cMcp {
    param([switch]$ForProjectInitialization)

    Write-Section "Setup vibecoding1c MCP"

    Ensure-GitIgnore
    Invoke-Vibecoding1cMcpSetupSelectionInheritance
    $selection = Read-Vibecoding1cMcpSelection
    $selectionCompleteness = Get-Vibecoding1cMcpSelectionCompleteness -Selection $selection -RefreshRegistry
    if ($Force -or -not $selectionCompleteness.isComplete) {
        if ($Force) {
            Write-Host "Force was specified; running vibecoding1c MCP selection before setup."
        } else {
            Write-Host "vibecoding1c MCP selection is missing or incomplete; running selection before setup."
            foreach ($reason in $selectionCompleteness.reasons) {
                Write-Host "  - $reason"
            }
        }
        if ($ForProjectInitialization) {
            $projectConfigId = Resolve-Vibecoding1cMcpProjectRemoteConfigId
            if ([string]::IsNullOrWhiteSpace($projectConfigId)) {
                throw "vibecoding1c MCP remote configuration could not be selected automatically for base configuration $(Get-BaseConfigurationVersion). Set vibecoding1cMcp.remoteConfigId explicitly or run vibecoding1c-mcp-select manually."
            }

            Write-Host "Automatically selected vibecoding1c MCP remote configId '$projectConfigId' for base configuration $(Get-BaseConfigurationVersion)."
            $previousProvider = $script:McpProvider
            $previousConfigId = $script:McpConfigId
            try {
                $script:McpProvider = "remote"
                $script:McpConfigId = $projectConfigId
                Set-Vibecoding1cMcpSelection
            } finally {
                $script:McpProvider = $previousProvider
                $script:McpConfigId = $previousConfigId
            }
        } else {
            Set-Vibecoding1cMcpSelection
        }
        $selection = Read-Vibecoding1cMcpSelection
    }

    $needsLocalDistribution = Test-Vibecoding1cMcpSelectionNeedsLocalDistribution -Selection $selection

    if ($needsLocalDistribution) {
        Ensure-Vibecoding1cMcpDistribution | Out-Null
        if (Test-Path -LiteralPath (Join-Path (Get-Vibecoding1cMcpDistributionRoot) "config.env") -PathType Leaf -ErrorAction SilentlyContinue) {
            Rotate-Vibecoding1cMcpKeys -DistributionReady
        } else {
            Write-Host "Distribution config.env not found; key rotation skipped."
        }
    } else {
        Refresh-Vibecoding1cMcpRegistry
    }
    Start-Vibecoding1cMcp -DistributionReady:$needsLocalDistribution
    Show-Vibecoding1cMcpStatus
}

function Get-Vibecoding1cMcpCurrentEndpoints {
    param([switch]$IncludeGlobal)

    $state = Read-Vibecoding1cMcpState
    $context = Get-Vibecoding1cMcpScopeContext
    $endpoints = @()
    foreach ($server in ConvertTo-Vibecoding1cMcpArray (Get-Vibecoding1cMcpObjectValue -Object $state -Name "servers" -Default @())) {
        if ([string](Get-Vibecoding1cMcpObjectValue -Object $server -Name "family" -Default "") -ne "vibecoding1c") {
            continue
        }
        if (-not (Test-Vibecoding1cMcpEndpointAllowedForProject -Endpoint $server)) {
            continue
        }
        $url = [string](Get-Vibecoding1cMcpObjectValue -Object $server -Name "url" -Default "")
        if (-not $url) {
            continue
        }
        if (-not (Test-Vibecoding1cMcpEndpointUsableForClientConfig -Endpoint $server)) {
            continue
        }
        $scope = [string](Get-Vibecoding1cMcpObjectValue -Object $server -Name "scope" -Default "")
        if ($scope -eq "global") {
            if ($IncludeGlobal) {
                $endpoints += $server
            }
            continue
        }
        if ([string](Get-Vibecoding1cMcpObjectValue -Object $server -Name "projectSlug" -Default "") -ne $context.projectSlug) {
            continue
        }
        if ($scope -eq "branch" -and [string](Get-Vibecoding1cMcpObjectValue -Object $server -Name "branchSlug" -Default "") -ne $context.branchSlug) {
            continue
        }
        $endpoints += $server
    }
    return $endpoints
}

function Get-Vibecoding1cMcpServerStatusKey {
    param(
        [string]$Id,
        [string]$Scope,
        [string]$Provider,
        [string]$ConfigId = "",
        [string]$HostId = ""
    )

    if (-not $Id -or -not $Scope -or -not $Provider) {
        return ""
    }
    return "$Id|$Scope|$Provider|$ConfigId|$HostId"
}

function Get-Vibecoding1cMcpCurrentStateServers {
    param([switch]$IncludeGlobal)

    $state = Read-Vibecoding1cMcpState
    $context = Get-Vibecoding1cMcpScopeContext
    $servers = @()
    foreach ($server in ConvertTo-Vibecoding1cMcpArray (Get-Vibecoding1cMcpObjectValue -Object $state -Name "servers" -Default @())) {
        if ([string](Get-Vibecoding1cMcpObjectValue -Object $server -Name "family" -Default "") -ne "vibecoding1c") {
            continue
        }
        if (-not (Test-Vibecoding1cMcpEndpointAllowedForProject -Endpoint $server)) {
            continue
        }
        $scope = [string](Get-Vibecoding1cMcpObjectValue -Object $server -Name "scope" -Default "")
        if ($scope -eq "global") {
            if ($IncludeGlobal) {
                $servers += $server
            }
            continue
        }
        if ([string](Get-Vibecoding1cMcpObjectValue -Object $server -Name "projectSlug" -Default "") -ne $context.projectSlug) {
            continue
        }
        if ($scope -eq "branch" -and [string](Get-Vibecoding1cMcpObjectValue -Object $server -Name "branchSlug" -Default "") -ne $context.branchSlug) {
            continue
        }
        $servers += $server
    }
    return $servers
}

function Format-Vibecoding1cMcpStatusList {
    param([object[]]$Items)

    if ($null -eq $Items -or $Items.Count -eq 0) {
        return "none"
    }
    return ($Items -join ", ")
}

function Get-Vibecoding1cMcpStatusSummary {
    $selection = Read-Vibecoding1cMcpSelection
    $context = Get-Vibecoding1cMcpScopeContext
    $activeEndpoints = @(Get-Vibecoding1cMcpCurrentEndpoints -IncludeGlobal)
    $currentServers = @(Get-Vibecoding1cMcpCurrentStateServers -IncludeGlobal)

    $activeByKey = @{}
    foreach ($endpoint in $activeEndpoints) {
        $key = Get-Vibecoding1cMcpServerStatusKey `
            -Id ([string](Get-Vibecoding1cMcpObjectValue -Object $endpoint -Name "id" -Default "")) `
            -Scope ([string](Get-Vibecoding1cMcpObjectValue -Object $endpoint -Name "scope" -Default "")) `
            -Provider ([string](Get-Vibecoding1cMcpObjectValue -Object $endpoint -Name "provider" -Default "local")) `
            -ConfigId ([string](Get-Vibecoding1cMcpObjectValue -Object $endpoint -Name "configId" -Default "")) `
            -HostId ([string](Get-Vibecoding1cMcpObjectValue -Object $endpoint -Name "hostId" -Default ""))
        if ($key) {
            $activeByKey[$key] = $endpoint
        }
    }

    $currentByKey = @{}
    foreach ($server in $currentServers) {
        $key = Get-Vibecoding1cMcpServerStatusKey `
            -Id ([string](Get-Vibecoding1cMcpObjectValue -Object $server -Name "id" -Default "")) `
            -Scope ([string](Get-Vibecoding1cMcpObjectValue -Object $server -Name "scope" -Default "")) `
            -Provider ([string](Get-Vibecoding1cMcpObjectValue -Object $server -Name "provider" -Default "local")) `
            -ConfigId ([string](Get-Vibecoding1cMcpObjectValue -Object $server -Name "configId" -Default "")) `
            -HostId ([string](Get-Vibecoding1cMcpObjectValue -Object $server -Name "hostId" -Default ""))
        if ($key -and -not $currentByKey.ContainsKey($key)) {
            $currentByKey[$key] = $server
        }
    }

    $active = @($activeEndpoints | Sort-Object @{ Expression = { Get-Vibecoding1cMcpObjectValue -Object $_ -Name "scope" -Default "" } }, @{ Expression = { Get-Vibecoding1cMcpObjectValue -Object $_ -Name "name" -Default "" } } | ForEach-Object {
        $name = [string](Get-Vibecoding1cMcpObjectValue -Object $_ -Name "name" -Default "")
        if (-not $name) { return }
        $provider = [string](Get-Vibecoding1cMcpObjectValue -Object $_ -Name "provider" -Default "local")
        $freshness = Get-Vibecoding1cMcpEndpointFreshness -Endpoint $_
        "$name/$provider/$freshness"
    } | Where-Object { $_ })

    $staleServers = @($activeEndpoints | ForEach-Object {
        $name = [string](Get-Vibecoding1cMcpObjectValue -Object $_ -Name "name" -Default "")
        if (-not $name) { return }
        $freshness = Get-Vibecoding1cMcpEndpointFreshness -Endpoint $_
        if ($freshness -eq "stale" -or $freshness -eq "indexing" -or $freshness -eq "unknown") {
            "$name/$freshness"
        }
    } | Where-Object { $_ })

    $missingConfigId = @()
    $skipped = @()
    foreach ($server in @(Select-Vibecoding1cMcpManifestServers)) {
        $id = [string](Get-Vibecoding1cMcpObjectValue -Object $server -Name "id" -Default "")
        if (-not $id) {
            continue
        }
        $provider = Get-Vibecoding1cMcpSelectedProvider -Server $server -Selection $selection
        $scope = Get-Vibecoding1cMcpServerScope -Server $server
        $configId = ""
        if ($provider -eq "remote") {
            if (Test-Vibecoding1cMcpServerNeedsRemoteConfig -Server $server) {
                $configId = Get-Vibecoding1cMcpSelectedConfigId -Server $server -Selection $selection
                if (-not $configId) {
                    $missingConfigId += "$id/$scope"
                    continue
                }
            }
        } else {
            $localScope = Get-Vibecoding1cMcpSelectedLocalScope -Server $server -Selection $selection
            $server = ConvertTo-Vibecoding1cMcpLocalScopedServer -Server $server -LocalScope $localScope -Context $context
            $scope = [string](Get-Vibecoding1cMcpObjectValue -Object $server -Name "scope" -Default $scope)
        }

        $hostId = $(if ($provider -eq "remote") { Get-Vibecoding1cMcpSelectedHostId -Server $server -Selection $selection } else { "" })
        $key = Get-Vibecoding1cMcpServerStatusKey -Id $id -Scope $scope -Provider $provider -ConfigId $configId -HostId $hostId
        if ($key -and $activeByKey.ContainsKey($key)) {
            continue
        }

        $reason = $(if ($provider -eq "remote") { "not-connected" } else { "not-started" })
        if ($key -and $currentByKey.ContainsKey($key)) {
            $current = $currentByKey[$key]
            $status = [string](Get-Vibecoding1cMcpObjectValue -Object $current -Name "status" -Default "")
            $url = [string](Get-Vibecoding1cMcpObjectValue -Object $current -Name "url" -Default "")
            if ($status) {
                $reason = $status
            } elseif (-not $url) {
                $reason = "missing-url"
            }
        }
        $skipped += "$id/$scope/$provider/$reason"
    }

    $state = Read-Vibecoding1cMcpState
    return [pscustomobject]@{
        active = @($active)
        skipped = @($skipped)
        staleServers = @($staleServers)
        missingConfigId = @($missingConfigId)
        staleIndexes = @(Select-Vibecoding1cMcpAllowedStaleIndexes -Values @(ConvertTo-Vibecoding1cMcpArray (Get-Vibecoding1cMcpObjectValue -Object $state -Name "staleIndexes" -Default @())))
    }
}

function Write-Vibecoding1cMcpSummaryLines {
    param(
        [object]$Summary,
        [string]$Indent = ""
    )

    Write-Host "${Indent}vibecoding1c MCP active servers: $(Format-Vibecoding1cMcpStatusList -Items $Summary.active)"
    Write-Host "${Indent}vibecoding1c MCP skipped servers: $(Format-Vibecoding1cMcpStatusList -Items $Summary.skipped)"
    Write-Host "${Indent}vibecoding1c MCP stale servers: $(Format-Vibecoding1cMcpStatusList -Items $Summary.staleServers)"
    Write-Host "${Indent}vibecoding1c MCP missing-configId servers: $(Format-Vibecoding1cMcpStatusList -Items $Summary.missingConfigId)"
    Write-Host "${Indent}vibecoding1c MCP stale indexes: $(Format-Vibecoding1cMcpStatusList -Items $Summary.staleIndexes)"
}

function ConvertTo-Vibecoding1cMcpTomlString {
    param([string]$Value)
    return '"' + ($Value.Replace("\", "\\").Replace('"', '\"')) + '"'
}

function Get-Vibecoding1cMcpEndpointClientName {
    param([object]$Endpoint)

    $clientNames = Get-Vibecoding1cMcpObjectValue -Object $Endpoint -Name "clientNames" -Default $null
    $aiRules1cName = [string](Get-Vibecoding1cMcpObjectValue -Object $clientNames -Name "aiRules1c" -Default "")
    if ($aiRules1cName) {
        return $aiRules1cName
    }

    $id = [string](Get-Vibecoding1cMcpObjectValue -Object $Endpoint -Name "id" -Default "")
    $fallback = Get-Vibecoding1cMcpAiRules1cClientName -ServerId $id
    if ($fallback) {
        return $fallback
    }

    return [string](Get-Vibecoding1cMcpObjectValue -Object $Endpoint -Name "name" -Default "")
}

function Get-Vibecoding1cMcpManifestServerById {
    param([string]$ServerId)

    foreach ($server in Select-Vibecoding1cMcpManifestServers) {
        if ([string](Get-Vibecoding1cMcpObjectValue -Object $server -Name "id" -Default "") -eq $ServerId) {
            return $server
        }
    }
    return $null
}

function Test-Vibecoding1cMcpEndpointMatchesSelection {
    param(
        [object]$Endpoint,
        [object]$Selection
    )

    $id = [string](Get-Vibecoding1cMcpObjectValue -Object $Endpoint -Name "id" -Default "")
    $server = Get-Vibecoding1cMcpManifestServerById -ServerId $id
    if ($null -eq $server) {
        return $true
    }

    $provider = [string](Get-Vibecoding1cMcpObjectValue -Object $Endpoint -Name "provider" -Default "local")
    $selectedProvider = Get-Vibecoding1cMcpSelectedProvider -Server $server -Selection $Selection
    if ($provider -ne $selectedProvider) {
        return $false
    }

    $scope = [string](Get-Vibecoding1cMcpObjectValue -Object $Endpoint -Name "scope" -Default "")
    if ($provider -eq "remote") {
        $selectedConfigId = Get-Vibecoding1cMcpSelectedConfigId -Server $server -Selection $Selection
        if ($selectedConfigId -and ([string](Get-Vibecoding1cMcpObjectValue -Object $Endpoint -Name "configId" -Default "")) -ne $selectedConfigId) {
            return $false
        }
        if ((Test-Vibecoding1cMcpServerNeedsRemoteConfig -Server $server) -and -not $selectedConfigId) {
            return $false
        }

        $selectedHostId = Get-Vibecoding1cMcpSelectedHostId -Server $server -Selection $Selection
        if ($selectedHostId -and ([string](Get-Vibecoding1cMcpObjectValue -Object $Endpoint -Name "hostId" -Default "")) -ne $selectedHostId) {
            return $false
        }
        return $true
    }

    $expectedScope = Get-Vibecoding1cMcpServerScope -Server $server
    if ($expectedScope -ne "global") {
        $context = Get-Vibecoding1cMcpScopeContext
        $localScope = Get-Vibecoding1cMcpSelectedLocalScope -Server $server -Selection $Selection
        $effectiveServer = ConvertTo-Vibecoding1cMcpLocalScopedServer -Server $server -LocalScope $localScope -Context $context
        $expectedScope = Get-Vibecoding1cMcpServerScope -Server $effectiveServer
    }

    return ($scope -eq $expectedScope)
}

function Get-Vibecoding1cMcpCodexHomeConfigPath {
    $userHome = [Environment]::GetFolderPath("UserProfile")
    if ([string]::IsNullOrWhiteSpace($userHome)) {
        $userHome = $HOME
    }
    return (Join-Path $userHome ".codex\config.toml")
}

function Get-Vibecoding1cMcpCodexProjectConfigPath {
    return (Join-Path $script:ProjectRoot ".codex\config.toml")
}

function Get-Vibecoding1cMcpKiloConfigPath {
    return (Join-Path $script:ProjectRoot ".kilo\kilo.json")
}

function Get-Vibecoding1cMcpClientConfigEndpointSet {
    $globalEndpoints = @(Get-Vibecoding1cMcpCurrentEndpoints -IncludeGlobal | Where-Object { [string](Get-Vibecoding1cMcpObjectValue -Object $_ -Name "scope" -Default "") -eq "global" })
    $localEndpoints = @(Get-Vibecoding1cMcpCurrentEndpoints | Where-Object { [string](Get-Vibecoding1cMcpObjectValue -Object $_ -Name "scope" -Default "") -ne "global" })

    return [pscustomobject]@{
        globalEndpoints = @($globalEndpoints)
        localEndpoints = @($localEndpoints)
        allEndpoints = @($globalEndpoints + $localEndpoints)
    }
}

function Get-Vibecoding1cMcpClientConfigClientNames {
    param([object[]]$Endpoints)

    $names = @()
    foreach ($endpoint in @(Select-Vibecoding1cMcpClientConfigEndpoints -Endpoints $Endpoints)) {
        $name = Get-Vibecoding1cMcpEndpointClientName -Endpoint $endpoint
        if ($name) {
            $names += $name
        }
    }
    return @($names | Select-Object -Unique)
}

function Get-Vibecoding1cMcpReadyClientConfigNames {
    $endpointSet = Get-Vibecoding1cMcpClientConfigEndpointSet
    return @(Get-Vibecoding1cMcpClientConfigClientNames -Endpoints $endpointSet.allEndpoints)
}

function Select-Vibecoding1cMcpClientConfigEndpoints {
    param([object[]]$Endpoints)

    $selection = Read-Vibecoding1cMcpSelection
    $selected = @($Endpoints | Where-Object { (Test-Vibecoding1cMcpEndpointAllowedForProject -Endpoint $_) -and (Test-Vibecoding1cMcpEndpointMatchesSelection -Endpoint $_ -Selection $selection) -and (Test-Vibecoding1cMcpEndpointUsableForClientConfig -Endpoint $_) })
    $byClientName = [ordered]@{}
    foreach ($endpoint in @($selected | Sort-Object @{ Expression = { Get-Vibecoding1cMcpEndpointClientName -Endpoint $_ } }, @{ Expression = { Get-Vibecoding1cMcpObjectValue -Object $_ -Name "name" -Default "" } })) {
        $clientName = Get-Vibecoding1cMcpEndpointClientName -Endpoint $endpoint
        if (-not $clientName) {
            continue
        }
        if ($byClientName.Contains($clientName)) {
            $duplicateRegistryName = [string](Get-Vibecoding1cMcpObjectValue -Object $endpoint -Name "name" -Default "")
            Write-Warning "Skipping duplicate vibecoding1c MCP client name '$clientName' from endpoint '$duplicateRegistryName'."
            continue
        }
        $byClientName[$clientName] = $endpoint
    }
    return @($byClientName.Values)
}

function Set-Vibecoding1cMcpManagedTextBlock {
    param(
        [string]$Path,
        [string]$BlockId,
        [string]$Body
    )

    $start = "# >>> vibecoding1c-mcp $BlockId"
    $end = "# <<< vibecoding1c-mcp $BlockId"
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

function Get-Vibecoding1cMcpTomlSectionValue {
    param(
        [string]$SectionText,
        [string]$Name
    )

    $escapedName = [regex]::Escape($Name)
    $match = [regex]::Match($SectionText, "(?im)^\s*$escapedName\s*=\s*[""']?(?<value>[^""'#\r\n]+)")
    if ($match.Success) {
        return $match.Groups["value"].Value.Trim()
    }
    return ""
}

function Test-Vibecoding1cMcpTomlSectionIsManaged {
    param([string]$SectionText)

    $managedBy = Get-Vibecoding1cMcpTomlSectionValue -SectionText $SectionText -Name "managedBy"
    if ($managedBy -ne "vibecoding1c-mcp") {
        return $false
    }

    $family = Get-Vibecoding1cMcpTomlSectionValue -SectionText $SectionText -Name "family"
    return ([string]::IsNullOrWhiteSpace($family) -or $family -eq "vibecoding1c")
}

function Remove-Vibecoding1cMcpCodexManagedEntries {
    param(
        [string]$Path,
        [string[]]$ClientNames
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf -ErrorAction SilentlyContinue)) {
        return @()
    }

    $text = Read-Utf8Text -Path $Path
    $removed = @()
    foreach ($clientName in @($ClientNames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)) {
        $escaped = [regex]::Escape($clientName)
        $patterns = @(
            "(?ms)^\[mcp_servers\.`"$escaped`"\]\r?\n.*?(?=^\[|^# >>> vibecoding1c-mcp|\z)",
            "(?ms)^\[mcp_servers\.$escaped\]\r?\n.*?(?=^\[|^# >>> vibecoding1c-mcp|\z)"
        )
        foreach ($pattern in $patterns) {
            $matches = @([regex]::Matches($text, $pattern) | Sort-Object Index -Descending)
            foreach ($match in $matches) {
                if (-not (Test-Vibecoding1cMcpTomlSectionIsManaged -SectionText $match.Value)) {
                    continue
                }

                $text = $text.Remove($match.Index, $match.Length)
                if ($removed -notcontains $clientName) {
                    $removed += $clientName
                }
            }
        }
    }

    if ($removed.Count -gt 0) {
        Write-Utf8Text -Path $Path -Value ($text.TrimEnd() + [Environment]::NewLine)
    }
    return @($removed)
}

function Remove-Vibecoding1cMcpDisallowedProductDocsClientConfig {
    param([string[]]$CodexPaths)

    if (Test-ProductDocsMcpAllowed) {
        return
    }

    $clientName = Get-Vibecoding1cMcpAiRules1cClientName -ServerId "bookstack"
    $removed = @()
    foreach ($path in @($CodexPaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)) {
        $removed += @(Remove-Vibecoding1cMcpCodexManagedEntries -Path $path -ClientNames @($clientName))
    }
    $removed = @($removed | Select-Object -Unique)
    if ($removed.Count -gt 0) {
        Write-Host "Removed PM5-only vibecoding1c MCP client entries for PM4 project: $($removed -join ', ')."
    }
}

function Write-Vibecoding1cMcpCodexConfig {
    param(
        [string]$Path,
        [string]$BlockId,
        [object[]]$Endpoints
    )

    $lines = New-Object System.Collections.ArrayList
    foreach ($endpoint in @(Select-Vibecoding1cMcpClientConfigEndpoints -Endpoints $Endpoints | Sort-Object @{ Expression = { Get-Vibecoding1cMcpEndpointClientName -Endpoint $_ } })) {
        $name = Get-Vibecoding1cMcpEndpointClientName -Endpoint $endpoint
        $url = [string](Get-Vibecoding1cMcpObjectValue -Object $endpoint -Name "url" -Default "")
        if (-not $name -or -not $url) {
            continue
        }
        [void]$lines.Add("[mcp_servers.$(ConvertTo-Vibecoding1cMcpTomlString $name)]")
        [void]$lines.Add("url = $(ConvertTo-Vibecoding1cMcpTomlString $url)")
        [void]$lines.Add("enabled = true")
        [void]$lines.Add("startup_timeout_sec = 20")
        [void]$lines.Add("tool_timeout_sec = 120")
        [void]$lines.Add("")
    }

    Set-Vibecoding1cMcpManagedTextBlock -Path $Path -BlockId $BlockId -Body ((@($lines) -join [Environment]::NewLine).TrimEnd())
}

function Write-Vibecoding1cMcpKiloConfig {
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
        $family = [string](Get-Vibecoding1cMcpObjectValue -Object $entry -Name "family" -Default "")
        if ($managedBy -eq "vibecoding1c-mcp" -and $family -eq "vibecoding1c") {
            $mcp.Remove($key)
        }
    }

    foreach ($endpoint in @(Select-Vibecoding1cMcpClientConfigEndpoints -Endpoints $Endpoints | Sort-Object @{ Expression = { Get-Vibecoding1cMcpEndpointClientName -Endpoint $_ } })) {
        $name = Get-Vibecoding1cMcpEndpointClientName -Endpoint $endpoint
        $url = [string](Get-Vibecoding1cMcpObjectValue -Object $endpoint -Name "url" -Default "")
        if (-not $name -or -not $url) {
            continue
        }
        $registryName = [string](Get-Vibecoding1cMcpObjectValue -Object $endpoint -Name "name" -Default "")
        $mcp[$name] = [ordered]@{
            type = "remote"
            url = $url
            enabled = $true
            timeout = 120000
            managedBy = "vibecoding1c-mcp"
            family = "vibecoding1c"
            logicalId = [string](Get-Vibecoding1cMcpObjectValue -Object $endpoint -Name "id" -Default "")
            registryName = $registryName
            scope = [string](Get-Vibecoding1cMcpObjectValue -Object $endpoint -Name "scope" -Default "")
            provider = [string](Get-Vibecoding1cMcpObjectValue -Object $endpoint -Name "provider" -Default "local")
            configId = [string](Get-Vibecoding1cMcpObjectValue -Object $endpoint -Name "configId" -Default "")
            freshness = (Get-Vibecoding1cMcpEndpointFreshness -Endpoint $endpoint)
        }
    }

    $config["mcp"] = $mcp
    Write-Vibecoding1cMcpJsonFile -Path $path -Value $config
}

function Write-Vibecoding1cMcpClientConfig {
    Write-Section "Write vibecoding1c MCP client config"

    Ensure-GitIgnore
    $endpointSet = Get-Vibecoding1cMcpClientConfigEndpointSet
    $client = Get-ItlActiveClient
    $endpoints = @($endpointSet.allEndpoints | ForEach-Object {
        $name = Get-Vibecoding1cMcpEndpointClientName -Endpoint $_
        $url = [string](Get-Vibecoding1cMcpObjectValue -Object $_ -Name "url" -Default "")
        if ($name -and $url) { [pscustomobject]@{ name = $name; url = $url } }
    })
    $path = Write-ItlClientMcpEndpoints -Endpoints $endpoints -Owner "vibecoding1c" -Client $client
    Write-Host "$client project MCP config: $path"
}

function Show-Vibecoding1cMcpStatus {
    Write-Section "vibecoding1c MCP status"

    $state = Read-Vibecoding1cMcpState
    $context = Get-Vibecoding1cMcpScopeContext
    $distributionRoot = Get-Vibecoding1cMcpDistributionRoot
    Write-Host "MCP local home: $(Get-Vibecoding1cMcpLocalHome)"
    Write-Host "MCP distribution: $distributionRoot"
    if (Test-Vibecoding1cMcpDistributionPathOverride) {
        Write-Host "MCP distribution source: explicit path override"
    } else {
        Write-Host "MCP distribution repo: $(Get-Vibecoding1cMcpDistributionRepo)"
        if (-not (Test-Path -LiteralPath $distributionRoot -PathType Container -ErrorAction SilentlyContinue)) {
            Write-Host "vibecoding1c MCP distribution checkout: missing; run vibecoding1c-mcp-setup or vibecoding1c-mcp-update to clone it."
        } elseif (-not (Test-Path -LiteralPath (Join-Path $distributionRoot ".git") -PathType Container -ErrorAction SilentlyContinue)) {
            Write-Host "vibecoding1c MCP distribution checkout: invalid; managed path exists but is not a Git checkout."
        } else {
            Write-Host "vibecoding1c MCP distribution checkout: present"
        }
    }
    Write-Host "vibecoding1c MCP registry: $(Get-Vibecoding1cMcpRegistryRoot)"
    if (Test-Vibecoding1cMcpRegistryPathOverride) {
        Write-Host "vibecoding1c MCP registry source: explicit path override"
    } else {
        Write-Host "vibecoding1c MCP registry repo: $(Get-Vibecoding1cMcpRegistryRepo)"
    }
    $selection = Read-Vibecoding1cMcpSelection
    Write-Host "vibecoding1c MCP selection: $(Get-Vibecoding1cMcpSelectionPath)"
    Write-Host "vibecoding1c MCP default provider: $(Get-Vibecoding1cMcpObjectValue -Object $selection -Name 'defaultProvider' -Default 'remote')"
    Write-Host "vibecoding1c MCP remote configId: $(Get-Vibecoding1cMcpObjectValue -Object $selection -Name 'remoteConfigId' -Default '<not selected>')"
    Write-Host "vibecoding1c MCP remote hostId: $(Get-Vibecoding1cMcpObjectValue -Object $selection -Name 'remoteHostId' -Default '<not selected>')"
    Write-Host "Project scope: $($context.projectSlug)"
    Write-Host "Branch scope: $($context.branchSlug)"

    $model = Get-Vibecoding1cMcpObjectValue -Object $state -Name "model" -Default $null
    if ($model) {
        Write-Host "Embedding model: $(Get-Vibecoding1cMcpObjectValue -Object $model -Name 'modelId' -Default '<unknown>')"
        Write-Host "Embedding API: $(Get-Vibecoding1cMcpObjectValue -Object $model -Name 'apiBase' -Default '<not set>')"
        Write-Host "Embedding ready: $(Get-Vibecoding1cMcpObjectValue -Object $model -Name 'ready' -Default $false)"
    } else {
        Write-Host "Embedding model: not configured"
    }

    $stale = @(Select-Vibecoding1cMcpAllowedStaleIndexes -Values @(ConvertTo-Vibecoding1cMcpArray (Get-Vibecoding1cMcpObjectValue -Object $state -Name "staleIndexes" -Default @())))
    if ($stale.Count -gt 0) {
        Write-Host "Stale indexes: $($stale -join ', ')"
        Write-Host "Reindex only after explicit RESET_DATABASE=true."
    } else {
        Write-Host "Stale indexes: none"
    }

    $summary = Get-Vibecoding1cMcpStatusSummary
    Write-Vibecoding1cMcpSummaryLines -Summary $summary
    Write-Vibecoding1cMcpProductDocsStatusLines
    Write-Vibecoding1cMcpProductDocsClientConfigWarning

    $endpoints = @(Get-Vibecoding1cMcpCurrentEndpoints -IncludeGlobal)
    if ($endpoints.Count -eq 0) {
        Write-Host "Active MCP names: none"
        Write-Host "Start with: powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action vibecoding1c-mcp-start"
        return
    }

    Write-Host "Active MCP names:"
    foreach ($endpoint in ($endpoints | Sort-Object @{ Expression = { Get-Vibecoding1cMcpObjectValue -Object $_ -Name "scope" -Default "" } }, @{ Expression = { Get-Vibecoding1cMcpObjectValue -Object $_ -Name "name" -Default "" } })) {
        $name = [string](Get-Vibecoding1cMcpObjectValue -Object $endpoint -Name "name" -Default "")
        $url = [string](Get-Vibecoding1cMcpObjectValue -Object $endpoint -Name "url" -Default "")
        $port = ConvertTo-IntOrDefault -Value (Get-Vibecoding1cMcpObjectValue -Object $endpoint -Name "hostPort" -Default 0)
        $live = $(if ($port -gt 0) { Test-TcpPortOpen -Port $port -TimeoutMilliseconds 200 } else { $false })
        $scope = [string](Get-Vibecoding1cMcpObjectValue -Object $endpoint -Name "scope" -Default "")
        $provider = [string](Get-Vibecoding1cMcpObjectValue -Object $endpoint -Name "provider" -Default "local")
        $hostId = [string](Get-Vibecoding1cMcpObjectValue -Object $endpoint -Name "hostId" -Default "")
        $hostPublishedAt = [string](Get-Vibecoding1cMcpObjectValue -Object $endpoint -Name "hostPublishedAt" -Default "")
        $configId = [string](Get-Vibecoding1cMcpObjectValue -Object $endpoint -Name "configId" -Default "")
        $health = [string](Get-Vibecoding1cMcpObjectValue -Object $endpoint -Name "health" -Default "")
        $indexedAt = [string](Get-Vibecoding1cMcpObjectValue -Object $endpoint -Name "indexedAt" -Default "")
        $configurationName = [string](Get-Vibecoding1cMcpObjectValue -Object $endpoint -Name "configurationName" -Default "")
        $configurationVersion = [string](Get-Vibecoding1cMcpObjectValue -Object $endpoint -Name "configurationVersion" -Default "")
        $embeddingModel = [string](Get-Vibecoding1cMcpObjectValue -Object $endpoint -Name "embeddingModel" -Default "")
        $freshness = Get-Vibecoding1cMcpEndpointFreshness -Endpoint $endpoint
        $metadata = @()
        if ($hostId) { $metadata += "hostId=$hostId" }
        if ($hostPublishedAt) { $metadata += "publishedAt=$hostPublishedAt" }
        if ($configurationName) {
            $configurationText = $configurationName
            if ($configurationVersion) {
                $configurationText = "$configurationName $configurationVersion"
            }
            $metadata += "configuration=$configurationText"
        }
        if ($embeddingModel) { $metadata += "model=$embeddingModel" }
        $healthText = if ($health) { $health } else { "<unknown>" }
        $configIdText = if ($configId) { $configId } else { "<none>" }
        $indexedAtText = if ($indexedAt) { $indexedAt } else { "<unknown>" }
        $metadataText = if ($metadata.Count -gt 0) { " " + ($metadata -join "; ") } else { "" }
        Write-Host "  $name [$scope/$provider] $url live=$live health=$healthText freshness=$freshness configId=$configIdText indexedAt=$indexedAtText$metadataText"
    }
    Write-Host "Restart: powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action vibecoding1c-mcp-start"
}

function Write-Vibecoding1cMcpStatusLines {
    param([string]$Indent = "")

    $state = Read-Vibecoding1cMcpState
    $model = Get-Vibecoding1cMcpObjectValue -Object $state -Name "model" -Default $null
    if ($model) {
        Write-Host "${Indent}vibecoding1c MCP embeddings: $(Get-Vibecoding1cMcpObjectValue -Object $model -Name 'modelId' -Default '<unknown>') ready=$(Get-Vibecoding1cMcpObjectValue -Object $model -Name 'ready' -Default $false)"
    } else {
        Write-Host "${Indent}vibecoding1c MCP embeddings: not configured"
    }

    Write-Vibecoding1cMcpSummaryLines -Summary (Get-Vibecoding1cMcpStatusSummary) -Indent $Indent
    Write-Vibecoding1cMcpProductDocsStatusLines -Indent $Indent
}
