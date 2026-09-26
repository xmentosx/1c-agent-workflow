function Get-BetaCutoverContext {
    param([object]$Config, [string]$ServerId, [string]$ConfigId)
    if (-not $ServerId) { throw "Beta cutover requires -ServerId." }
    $stableManifest = Read-DistributionManifest -Config $Config
    $betaManifest = Read-DistributionManifest -Config $Config -Channel beta
    $stable = @(As-Array (Get-ObjectValue -Object $stableManifest -Name "servers" -Default @()) | Where-Object { [string]$_.id -eq $ServerId })
    $beta = @(As-Array (Get-ObjectValue -Object $betaManifest -Name "servers" -Default @()) | Where-Object { [string]$_.id -eq $ServerId })
    if ($stable.Count -ne 1 -or $beta.Count -ne 1) { throw "Both distribution manifests must define exactly one '$ServerId' server." }
    $stableServer = $stable[0]
    $betaServer = $beta[0]
    $scope = Get-ServerScope -Server $stableServer
    if ($scope -ne (Get-ServerScope -Server $betaServer)) { throw "Beta '$ServerId' changes server scope." }
    if ($scope -eq "project" -and -not $ConfigId) { throw "Project MCP '$ServerId' requires -ConfigId." }
    if ($scope -eq "global" -and $ConfigId) { throw "Global MCP '$ServerId' does not accept -ConfigId." }
    if ([string](Get-ObjectValue -Object $betaServer -Name "channel" -Default "") -ne "beta") { throw "Beta '$ServerId' is not marked as beta." }
    if ([string](Get-ObjectValue -Object $betaServer -Name "mcpNameTemplate" -Default "") -ne [string](Get-ObjectValue -Object $stableServer -Name "mcpNameTemplate" -Default "")) {
        throw "Beta '$ServerId' changes the public MCP name."
    }
    $old = Get-TrackedHostServerForIdentity -Config $Config -ServerId $ServerId -Scope $scope -ConfigId $ConfigId
    if ($null -eq $old) { throw "Stable '$ServerId' is not tracked for configId '$ConfigId'." }
    if ([string](Get-ObjectValue -Object $old -Name "channel" -Default "stable") -ne "stable") { throw "'$ServerId' is already selected for beta or has an unknown channel." }
    if ((Get-HostContainerPublishState -ContainerName ([string]$old.containerName)) -ne "running") { throw "Stable container '$($old.containerName)' is not running." }
    $configState = $null
    if ($scope -eq "project") {
        $configStates = @(As-Array (Get-ObjectValue -Object (Read-HostState -Config $Config) -Name "configurations" -Default @()) | Where-Object { [string]$_.configId -eq $ConfigId })
        if ($configStates.Count -ne 1) { throw "Exactly one tracked configuration '$ConfigId' is required." }
        $configState = $configStates[0]
    }
    $runtime = New-ServerRuntime -Config $Config -Server $betaServer -Index 0 -ConfigState $configState
    $runtime.hostPort = [int]$old.hostPort
    $runtime.url = [string](Get-ObjectValue -Object $old -Name "directUrl" -Default "")
    if (-not $runtime.url) {
        $baseUrl = ([string](Get-ObjectValue -Object $Config -Name "baseUrl" -Default "http://localhost")).TrimEnd("/")
        $runtime.url = "$baseUrl`:$($runtime.hostPort)/mcp"
    }
    $runtime.proxyContainerName = [string](Get-ObjectValue -Object $old -Name "proxyContainerName" -Default "$($old.containerName)-tools-list-proxy")
    if ($runtime.name -ne [string]$old.name -or $runtime.containerName -eq [string]$old.containerName) {
        throw "Beta '$ServerId' must keep the public name and use a distinct container."
    }
    if (-not ([string]$runtime.image).Contains("@sha256:")) { throw "Beta '$ServerId' image is not pinned by digest." }
    $envValues = Resolve-ServerEnv -Config $Config -Server $betaServer -ConfigState $configState
    if ($ServerId -in @("templates", "code", "graph") -and [string](Get-ObjectValue -Object $envValues -Name "RESET_DATABASE" -Default "false") -notmatch '^(?i:false|0|no|off)$') {
        throw "Beta '$ServerId' would reset a retained database."
    }
    if ($ServerId -eq "syntax" -and [string](Get-ObjectValue -Object $envValues -Name "FULLINDEX" -Default "") -notmatch '^(?i:false|0|no|off)$') {
        throw "Beta Syntax must start with FULLINDEX=false."
    }
    if ($ServerId -in @("templates", "code", "graph")) {
        $oldModel = [string](Get-ObjectValue -Object $old -Name "embeddingModel" -Default "")
        if ($oldModel -and $oldModel -ne [string]$runtime.embeddingModel) { throw "Beta '$ServerId' would change embedding model from '$oldModel' to '$($runtime.embeddingModel)'." }
    }
    return [pscustomobject]@{ serverId = $ServerId; configId = $ConfigId; scope = $scope; old = $old; betaServer = $betaServer; configState = $configState; runtime = $runtime }
}

function Get-HostMcpToolsList {
    param([string]$Url)
    $connection = Open-HostMcpConnection -Url $Url
    $tools = @()
    $cursor = ""
    do {
        $params = [ordered]@{}
        if ($cursor) { $params["cursor"] = $cursor }
        $payload = [ordered]@{ jsonrpc = "2.0"; id = [int]$connection.nextId; method = "tools/list"; params = $params }
        $connection.nextId = [int]$connection.nextId + 1
        $response = Invoke-WebRequest -UseBasicParsing -Uri $connection.url -Method Post -ContentType "application/json" -Headers $connection.headers -Body ($payload | ConvertTo-Json -Depth 12 -Compress) -TimeoutSec 60
        $body = ConvertFrom-HostMcpResponse -Text $response.Content
        if ($null -ne $body.PSObject.Properties["error"]) { throw "MCP tools/list failed: $($body.error | ConvertTo-Json -Depth 10 -Compress)" }
        $result = Get-ObjectValue -Object $body -Name "result" -Default $null
        if ($null -eq $result) { throw "MCP tools/list returned no result." }
        $tools += @(As-Array (Get-ObjectValue -Object $result -Name "tools" -Default @()))
        $cursor = [string](Get-ObjectValue -Object $result -Name "nextCursor" -Default "")
    } while ($cursor)
    if ($tools.Count -eq 0) { throw "MCP tools/list returned no tools from $Url." }
    return $tools
}

function Assert-BetaToolsAcceptOldCalls {
    param([object[]]$OldTools, [object[]]$BetaTools)
    $byName = @{}
    foreach ($tool in $BetaTools) {
        $name = [string](Get-ObjectValue -Object $tool -Name "name" -Default "")
        if (-not $name -or $byName.ContainsKey($name)) { throw "Beta MCP has an empty or duplicate tool name '$name'." }
        $byName[$name] = $tool
    }
    foreach ($old in $OldTools) {
        $name = [string](Get-ObjectValue -Object $old -Name "name" -Default "")
        if (-not $byName.ContainsKey($name)) { throw "Beta MCP removed old tool '$name'." }
        $new = $byName[$name]
        $oldInput = Get-ObjectValue -Object $old -Name "inputSchema" -Default $null
        $newInput = Get-ObjectValue -Object $new -Name "inputSchema" -Default $null
        $oldRequired = @((As-Array (Get-ObjectValue -Object $oldInput -Name "required" -Default @())) | ForEach-Object { [string]$_ })
        $newRequired = @((As-Array (Get-ObjectValue -Object $newInput -Name "required" -Default @())) | ForEach-Object { [string]$_ })
        $addedRequired = @($newRequired | Where-Object { $_ -notin $oldRequired })
        if ($addedRequired.Count -gt 0) { throw "Beta tool '$name' adds required arguments: $($addedRequired -join ', ')." }
        $oldProperties = Get-ObjectValue -Object $oldInput -Name "properties" -Default $null
        $newProperties = Get-ObjectValue -Object $newInput -Name "properties" -Default $null
        foreach ($property in @((Convert-ToHash -Object $oldProperties).GetEnumerator())) {
            $newProperty = Get-ObjectValue -Object $newProperties -Name $property.Key -Default $null
            if ($null -eq $newProperty) { throw "Beta tool '$name' removed argument '$($property.Key)'." }
            $oldType = [string](Get-ObjectValue -Object $property.Value -Name "type" -Default "")
            $newType = [string](Get-ObjectValue -Object $newProperty -Name "type" -Default "")
            if ($oldType -and $newType -and $oldType -ne $newType) { throw "Beta tool '$name' changed type of '$($property.Key)' from '$oldType' to '$newType'." }
        }
    }
}

function Get-BetaConfigurationIndexActivity {
    param([string]$ServerId, [string]$Url)
    if ($ServerId -notin @("code", "graph")) { return $null }
    $connection = Open-HostMcpConnection -Url $Url
    $tool = $(if ($ServerId -eq "code") { "stats" } else { "get_indexing_status" })
    $result = Invoke-HostMcpTool -Connection $connection -Name $tool
    $payload = Get-ObjectValue -Object $result -Name "structuredContent" -Default $null
    if ($null -eq $payload) { throw "'$ServerId' index status has no structuredContent." }
    $nested = Get-ObjectValue -Object $payload -Name "result" -Default $null
    if ($nested -is [string]) { $payload = $nested | ConvertFrom-Json }
    if ($ServerId -eq "code") {
        $data = Get-ObjectValue -Object $payload -Name "data" -Default $null
        $indexing = Get-ObjectValue -Object $data -Name "indexing" -Default $null
        $collections = Get-ObjectValue -Object $data -Name "collections" -Default $null
        if ($null -eq $indexing -or $null -eq $collections) { throw "Code stats did not expose indexing state and collection counts." }
        return [pscustomobject]@{ running = [bool](Get-ObjectValue -Object $indexing -Name "running" -Default $false); phase = [string](Get-ObjectValue -Object $indexing -Name "phase" -Default ""); collections = $collections }
    }
    $tasks = Get-ObjectValue -Object $payload -Name "background_tasks" -Default $null
    if ($null -eq $tasks) { throw "Graph get_indexing_status did not expose background_tasks." }
    $running = [bool](Get-ObjectValue -Object $payload -Name "any_running" -Default $false)
    foreach ($task in (Convert-ToHash -Object $tasks).GetEnumerator()) {
        $status = [string](Get-ObjectValue -Object $task.Value -Name "status" -Default "")
        if ($status -match '^(?i:running|pending|in_progress|processing)$') { $running = $true }
        if ($status -match '^(?i:failed|error)$') { throw "Graph background task '$($task.Key)' failed." }
    }
    return [pscustomobject]@{ running = $running; phase = "background_tasks"; collections = $null }
}

function New-BetaProxyContract {
    param([object]$Config, [object]$Context)
    $settings = Get-ToolsListProxySettings -Config $Config
    Ensure-ToolsListProxyImage -Config $Config
    $runtime = $Context.runtime
    $upstream = "http://host.docker.internal:$($runtime.hostPort)/mcp"
    $lines = @(Invoke-DockerCommandCapture -Arguments @("run", "--rm", "--add-host", "host.docker.internal:host-gateway", $settings.image, "--probe", "--upstream-url", $upstream, "--server-id", $Context.serverId) -TimeoutSec 180 -Description "probe beta tools contract for $($Context.serverId)")
    $probe = ($lines | Where-Object { $_ -match '^\{' } | Select-Object -Last 1 | ConvertFrom-Json)
    if ($null -eq $probe -or -not [string](Get-ObjectValue -Object $probe -Name "structuralSha256" -Default "")) { throw "Beta tools contract probe returned no structural hash." }
    $sourceContract = Read-JsonFile -Path $settings.contractPath
    $serverContract = [ordered]@{
        toolCount = [int]$probe.toolCount
        structuralSha256 = [string]$probe.structuralSha256
        toolNames = @($probe.toolNames)
        noArgumentTools = @($probe.noArgumentTools)
        toolDescriptions = [ordered]@{}
    }
    $servers = [ordered]@{}
    $servers[[string]$Context.serverId] = $serverContract
    $contract = [ordered]@{ schemaVersion = 2; approvedAt = (Get-Date).ToString("o"); descriptionPolicy = (Get-ObjectValue -Object $sourceContract -Name "descriptionPolicy" -Default $null); servers = $servers }
    $path = Join-Path (Join-Path (Get-StateRoot -Config $Config) "beta-proxy-contracts") "$($runtime.containerName).json"
    Write-JsonFile -Path $path -Value $contract
    return $path
}

function Get-BetaContainerMountSource {
    param([string]$ContainerName, [string]$Destination)
    $json = @(Invoke-DockerCommandCapture -Arguments @("inspect", "-f", "{{json .Mounts}}", $ContainerName) -TimeoutSec 60 -Description "inspect mounts for $ContainerName") -join ""
    $mounts = @($json | ConvertFrom-Json)
    $matches = @($mounts | Where-Object { [string]$_.Destination -eq $Destination })
    if ($matches.Count -ne 1) { throw "Expected one '$Destination' mount on '$ContainerName', found $($matches.Count)." }
    return [string]$matches[0].Source
}

function Wait-BetaFreshIndexReady {
    param([object]$Context, [int]$TimeoutSeconds = 7200)
    if ($Context.serverId -notin @("docs", "ssl")) { return }
    $url = "http://localhost:$($Context.runtime.hostPort)/ready"
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastError = ""
    do {
        try {
            $response = Invoke-WebRequest -UseBasicParsing -Uri $url -TimeoutSec 20
            if ([int]$response.StatusCode -eq 200) {
                Write-Host "Fresh beta index ready: server=$($Context.serverId) configId=$($Context.configId)"
                return
            }
            $lastError = "HTTP $($response.StatusCode)"
        } catch { $lastError = $_.Exception.Message }
        if ((Get-Date) -ge $deadline) { break }
        Start-Sleep -Seconds 10
    } while ($true)
    throw "Fresh beta '$($Context.serverId)' index was not ready within $TimeoutSeconds seconds: $lastError"
}

function Assert-BetaPathUnderStateRoot {
    param([object]$Config, [string]$Path)
    $root = [IO.Path]::GetFullPath((Get-StateRoot -Config $Config)).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $resolved = [IO.Path]::GetFullPath($Path)
    if (-not $resolved.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Beta data path is outside the host state root: $resolved"
    }
    return $resolved
}

function Get-BetaVolumePath {
    param([object]$Config, [object]$Context, [string]$ContainerPath)
    $volumes = @(As-Array (Get-ObjectValue -Object $Context.betaServer -Name "volumes" -Default @()))
    $match = @($volumes | Where-Object { [string]$_.to -eq $ContainerPath })
    if ($match.Count -ne 1 -or [string]$match[0].from -ne "PATH_BASES") { throw "Beta '$($Context.serverId)' has no unambiguous PATH_BASES mount for '$ContainerPath'." }
    $values = Get-HostLocalValues -Config $Config -ConfigState $Context.configState
    $path = [string]$values["PATH_BASES"]
    if (-not $path) { throw "PATH_BASES is missing for '$($Context.serverId)'." }
    if ($Context.scope -eq "project") {
        $path = Join-Path (Join-Path $path (ConvertTo-HostPathSegment -Value $Context.configId -Default "config")) (ConvertTo-HostPathSegment -Value $Context.serverId -Default "server")
    }
    $subdir = [string](Get-ObjectValue -Object $match[0] -Name "subdir" -Default "")
    if ($subdir) { $path = Join-Path $path $subdir }
    return (Assert-BetaPathUnderStateRoot -Config $Config -Path $path)
}

function Copy-BetaHostDirectory {
    param([object]$Config, [string]$Source, [string]$Destination)
    $destinationPath = Assert-BetaPathUnderStateRoot -Config $Config -Path $Destination
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) { throw "Stable data source is missing: $Source" }
    if (Test-Path -LiteralPath $destinationPath) { throw "Beta data destination already exists: $destinationPath. Resolve an earlier attempt before retrying." }
    New-Item -ItemType Directory -Force -Path $destinationPath | Out-Null
    $result = Invoke-ProcessWithTimeout -FilePath "robocopy" -Arguments @($Source, $destinationPath, "/E", "/R:2", "/W:2", "/NFL", "/NDL", "/NP") -TimeoutSec 14400 -Description "copy stable MCP data to beta snapshot"
    if ([int]$result.exitCode -ge 8) { throw "MCP data copy failed with robocopy exit code $($result.exitCode)." }
    if (@(Get-ChildItem -LiteralPath $destinationPath -Force).Count -eq 0) { throw "Beta data snapshot is empty: $destinationPath" }
}

function Copy-BetaContainerDirectory {
    param([object]$Config, [string]$ContainerName, [string]$ContainerPath, [string]$Destination)
    $destinationPath = Assert-BetaPathUnderStateRoot -Config $Config -Path $Destination
    if (Test-Path -LiteralPath $destinationPath) { throw "Beta data destination already exists: $destinationPath. Resolve an earlier attempt before retrying." }
    New-Item -ItemType Directory -Force -Path $destinationPath | Out-Null
    Invoke-DockerCommandChecked -Arguments @("cp", "${ContainerName}:$($ContainerPath.TrimEnd('/'))/.", $destinationPath) -TimeoutSec 14400 -Description "copy $ContainerName $ContainerPath to beta snapshot"
    if (@(Get-ChildItem -LiteralPath $destinationPath -Force).Count -eq 0) { throw "Beta data snapshot is empty: $destinationPath" }
}

function Stop-StableForBetaCutover {
    param([object]$Context)
    $oldName = [string]$Context.old.containerName
    Invoke-DockerCommandChecked -Arguments @("update", "--restart", "no", $oldName) -TimeoutSec 60 -Description "disable stable restart for $oldName"
    Invoke-DockerCommandChecked -Arguments @("stop", $oldName) -TimeoutSec 180 -Description "stop stable $oldName"
    if ($Context.serverId -eq "graph") {
        $neo4jName = "$oldName-neo4j"
        if ((Get-HostContainerPublishState -ContainerName $neo4jName) -ne "running") { throw "Stable Neo4j '$neo4jName' is not running." }
        Invoke-DockerCommandChecked -Arguments @("update", "--restart", "no", $neo4jName) -TimeoutSec 60 -Description "disable stable restart for $neo4jName"
        Invoke-DockerCommandChecked -Arguments @("stop", $neo4jName) -TimeoutSec 180 -Description "stop stable $neo4jName"
    }
}

function Copy-BetaDataSnapshot {
    param([object]$Config, [object]$Context)
    $oldName = [string]$Context.old.containerName
    switch ($Context.serverId) {
        "code" {
            $source = Get-BetaContainerMountSource -ContainerName $oldName -Destination "/app/chroma_db"
            $destination = Get-BetaVolumePath -Config $Config -Context $Context -ContainerPath "/app/chroma_db"
            Copy-BetaHostDirectory -Config $Config -Source $source -Destination $destination
        }
        "templates" {
            $destination = Get-BetaVolumePath -Config $Config -Context $Context -ContainerPath "/app/chroma_db"
            Copy-BetaContainerDirectory -Config $Config -ContainerName $oldName -ContainerPath "/app/chroma_db" -Destination $destination
        }
        "graph" {
            $root = Assert-BetaPathUnderStateRoot -Config $Config -Path (Join-Path (Join-Path (Get-StateRoot -Config $Config) "bases") (Join-Path $Context.configId "graph-beta"))
            Copy-BetaContainerDirectory -Config $Config -ContainerName "$oldName-neo4j" -ContainerPath "/data" -Destination (Join-Path $root "neo4j-data")
            Copy-BetaContainerDirectory -Config $Config -ContainerName $oldName -ContainerPath "/app/data" -Destination (Join-Path $root "mcp-state")
        }
    }
}

function Restore-StableAfterBetaFailure {
    param([object]$Config, [object]$Context, [switch]$StateChanged)
    $runtime = $Context.runtime
    $betaName = [string]$runtime.containerName
    $backup = [string](Get-ObjectValue -Object $runtime -Name "proxyBackupName" -Default "")
    if ($backup) {
        $proxyName = [string]$runtime.proxyContainerName
        [void](Invoke-DockerCommand -Arguments @("rm", "-f", $proxyName) -Quiet -TimeoutSec 120)
    }
    if ($Context.serverId -eq "graph") {
        $runtimePath = [string](Get-ObjectValue -Object $runtime -Name "runtimePath" -Default "")
        if ($runtimePath) {
            Invoke-DockerCommandChecked -Arguments @("compose", "-p", $runtime.composeProject, "-f", (Join-Path $runtimePath "docker-compose.yml"), "--env-file", (Join-Path $runtimePath ".env"), "down") -TimeoutSec 240 -Description "stop beta Graph"
        }
    } elseif ((Get-HostContainerPublishState -ContainerName $betaName) -ne "missing") {
        Invoke-DockerCommandChecked -Arguments @("rm", "-f", $betaName) -TimeoutSec 180 -Description "stop beta $betaName"
    }
    $oldName = [string]$Context.old.containerName
    if ($Context.serverId -eq "graph") {
        Invoke-DockerCommandChecked -Arguments @("update", "--restart", "unless-stopped", "$oldName-neo4j") -TimeoutSec 60 -Description "restore stable Neo4j restart policy"
        Invoke-DockerCommandChecked -Arguments @("start", "$oldName-neo4j") -TimeoutSec 180 -Description "restart stable Neo4j"
    }
    Invoke-DockerCommandChecked -Arguments @("update", "--restart", "unless-stopped", $oldName) -TimeoutSec 60 -Description "restore stable restart policy"
    Invoke-DockerCommandChecked -Arguments @("start", $oldName) -TimeoutSec 180 -Description "restart stable $oldName"
    [void](Wait-HostMcpReadyConnection -Url ([string]$Context.old.directUrl) -ServerId $Context.serverId -ConfigId $Context.configId -TimeoutSeconds 600)
    if ($backup) {
        Invoke-DockerCommandChecked -Arguments @("rename", $backup, $proxyName) -TimeoutSec 60 -Description "restore stable tools proxy"
        Invoke-DockerCommandChecked -Arguments @("start", $proxyName) -TimeoutSec 120 -Description "restart stable tools proxy"
    }
    if ($StateChanged) {
        Update-HostStateServers -Config $Config -ServerStates @($Context.old)
        Publish-Registry -Config $Config
    }
}

function Invoke-BetaPreflight {
    param([object]$Config, [string]$TargetServerId, [string]$TargetConfigId)
    if (-not $TargetServerId) { throw "beta-preflight requires -ServerId." }
    Ensure-HostPrerequisites -Config $Config
    Ensure-Distribution -Config $Config
    $context = Get-BetaCutoverContext -Config $Config -ServerId $TargetServerId -ConfigId $TargetConfigId
    if (-not (Test-ToolsListProxyTarget -Config $Config -ServerId $TargetServerId)) { throw "Beta cutover requires the existing public tools-list proxy for '$TargetServerId'." }
    $oldDirectUrl = [string](Get-ObjectValue -Object $context.old -Name "directUrl" -Default "")
    if (-not $oldDirectUrl) { throw "Stable '$TargetServerId' has no tracked direct URL." }
    $proxyName = [string](Get-ObjectValue -Object $context.old -Name "proxyContainerName" -Default "")
    if (-not $proxyName -or (Get-HostContainerPublishState -ContainerName $proxyName) -ne "running") { throw "Stable '$TargetServerId' has no running public proxy." }
    $upstreamUrl = "http://host.docker.internal:$($context.old.hostPort)/mcp"
    if (-not (Test-ToolsListProxyReady -Port ([int]$context.old.proxyPort) -ExpectedServerId $TargetServerId -ExpectedUpstreamUrl $upstreamUrl)) {
        throw "Stable '$TargetServerId' public proxy is not qualified."
    }
    if ($context.serverId -eq "graph" -and (Get-HostContainerPublishState -ContainerName "$($context.old.containerName)-neo4j") -ne "running") {
        throw "Stable Graph Neo4j is not running."
    }
    $oldTools = @(Get-HostMcpToolsList -Url $oldDirectUrl)
    $oldIndexActivity = Get-BetaConfigurationIndexActivity -ServerId $TargetServerId -Url $oldDirectUrl
    if ($null -ne $oldIndexActivity -and $oldIndexActivity.running) { throw "Stable '$TargetServerId' configId '$TargetConfigId' is indexing ($($oldIndexActivity.phase)); cutover would interrupt it." }
    Write-Host "Beta preflight passed: server=$TargetServerId configId=$TargetConfigId oldTools=$($oldTools.Count) publicName=$($context.old.name) publicUrl=$($context.old.url) betaImage=$($context.runtime.image)"
    return [pscustomobject]@{ context = $context; oldTools = $oldTools; oldIndexActivity = $oldIndexActivity }
}

function Invoke-BetaCutover {
    param([object]$Config, [string]$TargetServerId, [string]$TargetConfigId)
    if ($DryRun) { throw "Use -Action beta-preflight for read-only qualification; beta-cutover does not support -DryRun." }
    $lease = Enter-McpHostMaintenanceLock -Config $Config -Operation "beta-cutover:${TargetServerId}:$TargetConfigId" -WaitSeconds 0
    if (-not $lease.acquired) { throw "MCP host maintenance is active: $($lease.path)" }
    try {
        $preflight = Invoke-BetaPreflight -Config $Config -TargetServerId $TargetServerId -TargetConfigId $TargetConfigId
        $context = $preflight.context
        Assert-RegistryPushPreflight -Config $Config
        Ensure-ServerDockerImageAvailable -Server $context.betaServer -Image ([string]$context.runtime.image)
        if ($TargetServerId -eq "graph") { Ensure-DockerImageAvailable -Image ([string]$context.betaServer.neo4jImage) }
        $oldStopped = $false
        $stateChanged = $false
        try {
            $oldStopped = $true
            Stop-StableForBetaCutover -Context $context
            Copy-BetaDataSnapshot -Config $Config -Context $context
            if ($TargetServerId -eq "graph") {
                Start-ComposeServer -Config $Config -Server $context.betaServer -Runtime $context.runtime -ConfigState $context.configState
            } else {
                Start-DockerServer -Config $Config -Server $context.betaServer -Runtime $context.runtime -ConfigState $context.configState
            }
            [void](Wait-HostMcpReadyConnection -Url ([string]$context.runtime.url) -ServerId $TargetServerId -ConfigId $TargetConfigId -TimeoutSeconds 7200 -RetrySeconds 10)
            Wait-BetaFreshIndexReady -Context $context
            $betaTools = @(Get-HostMcpToolsList -Url ([string]$context.runtime.url))
            Assert-BetaToolsAcceptOldCalls -OldTools $preflight.oldTools -BetaTools $betaTools
            $betaIndexActivity = Get-BetaConfigurationIndexActivity -ServerId $TargetServerId -Url ([string]$context.runtime.url)
            if ($null -ne $betaIndexActivity -and $betaIndexActivity.running) { throw "Beta '$TargetServerId' started configuration indexing ($($betaIndexActivity.phase)); refusing a full reindex." }
            if ($TargetServerId -eq "code") {
                $oldCollections = Convert-ToHash -Object $preflight.oldIndexActivity.collections
                $betaCollections = Convert-ToHash -Object $betaIndexActivity.collections
                foreach ($key in $oldCollections.Keys) {
                    if (-not $betaCollections.Contains($key) -or [int]$betaCollections[$key] -lt [int]$oldCollections[$key]) {
                        throw "Beta CodeMetadata collection '$key' lost indexed records after snapshot migration."
                    }
                }
            }
            $health = Get-HostServerFunctionalHealth -Server $context.runtime
            if ($health.status -eq "degraded") { throw "Beta functional health failed: $($health.message)" }
            $context.runtime.proxyContractPath = New-BetaProxyContract -Config $Config -Context $context
            Enable-ToolsListProxyForRuntime -Config $Config -Runtime $context.runtime
            $context.runtime.health = "running"
            $context.runtime | Add-Member -NotePropertyName betaCutoverAt -NotePropertyValue (Get-Date).ToString("o") -Force
            $publishedRuntime = Convert-ToHash -Object $context.runtime
            if ($publishedRuntime.Contains("proxyBackupName")) { $publishedRuntime.Remove("proxyBackupName") }
            Update-HostStateServers -Config $Config -ServerStates @($publishedRuntime)
            $stateChanged = $true
            Publish-Registry -Config $Config
            $backup = [string](Get-ObjectValue -Object $context.runtime -Name "proxyBackupName" -Default "")
            if ($backup) { Invoke-DockerCommandChecked -Arguments @("rm", "-f", $backup) -TimeoutSec 120 -Description "remove qualified old tools proxy backup" }
            Write-Host "Beta cutover complete: server=$TargetServerId configId=$TargetConfigId publicName=$($context.runtime.name) publicUrl=$($context.runtime.url) oldContainer=$($context.old.containerName) betaContainer=$($context.runtime.containerName) oldData=retained"
        } catch {
            $failure = $_
            if ($oldStopped) {
                try { Restore-StableAfterBetaFailure -Config $Config -Context $context -StateChanged:$stateChanged }
                catch { throw "Beta cutover failed: $($failure.Exception.Message). Automatic stable restoration also failed: $($_.Exception.Message)" }
            }
            throw $failure
        }
    } finally {
        Exit-McpHostMaintenanceLock -Lease $lease
    }
}
