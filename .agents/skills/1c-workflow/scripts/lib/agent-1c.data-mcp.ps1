function Get-DataMcpExtensionName {
    return "OneMCP"
}

function Get-DataMcpHttpServiceName {
    return "APA_MCP"
}

function Get-DataMcpHttpServiceRootUrl {
    return "mcp"
}

function Get-DataMcpAiRules1cClientName {
    return "1c-data-mcp"
}

function Get-DataMcpRuntimeRoot {
    return (Resolve-ProjectPath ".agent-1c/tools/data-mcp")
}

function Get-DataMcpArchivePath {
    $distributionRoot = Ensure-Vibecoding1cMcpDistribution
    $archivePath = Join-Path $distributionRoot "MCP_1C_Distr.zip"
    if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf -ErrorAction SilentlyContinue)) {
        throw "MCP_1C_Distr.zip was not found in vibecoding1c MCP distribution: $archivePath"
    }
    return $archivePath
}

function Expand-DataMcpArchive {
    param([string]$ArchivePath)

    if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf -ErrorAction SilentlyContinue)) {
        throw "Data MCP archive was not found: $ArchivePath"
    }

    $hash = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $extractRoot = Join-Path (Join-Path (Get-DataMcpRuntimeRoot) "extract") $hash
    if (Test-Path -LiteralPath $extractRoot -PathType Container -ErrorAction SilentlyContinue) {
        return $extractRoot
    }

    New-Item -ItemType Directory -Force -Path $extractRoot | Out-Null
    Expand-Archive -LiteralPath $ArchivePath -DestinationPath $extractRoot -Force
    return $extractRoot
}

function Find-DataMcpToolsXmlPath {
    param([string]$ExtractRoot)

    foreach ($file in Get-ChildItem -LiteralPath $ExtractRoot -Recurse -File -Filter "*.xml" -ErrorAction SilentlyContinue) {
        $text = Read-Utf8Text -Path $file.FullName
        if ($text.Contains("CatalogObject.APA_Инструменты")) {
            return $file.FullName
        }
    }

    throw "APA_Инструменты XML was not found in Data MCP archive extract: $ExtractRoot"
}

function Find-DataMcpCfePath {
    param([string]$ExtractRoot)

    $file = @(Get-ChildItem -LiteralPath $ExtractRoot -Recurse -File -Filter "OneMCP.cfe" -ErrorAction SilentlyContinue | Select-Object -First 1)[0]
    if ($null -eq $file) {
        throw "OneMCP.cfe was not found in Data MCP archive extract: $ExtractRoot"
    }
    return $file.FullName
}

function Convert-DataMcpToolsXmlText {
    param([string]$Text)

    $doc = New-Object System.Xml.XmlDocument
    $doc.PreserveWhitespace = $true
    try {
        $doc.LoadXml($Text)
    } catch {
        throw "Data MCP tools XML could not be parsed before patch. $($_.Exception.Message)"
    }

    $changed = 0
    foreach ($node in $doc.SelectNodes("//*[local-name()='CatalogObject.APA_Инструменты']//*[local-name()='Description']")) {
        if ([string]$node.InnerText -eq "vcvalidatequery") {
            $node.InnerText = "validatequery"
            $changed += 1
        }
    }

    $patched = $doc.OuterXml
    if ($changed -eq 0) {
        throw "Data MCP tools XML does not contain APA_Инструменты description vcvalidatequery to patch."
    }
    if ($patched.Contains("vcvalidatequery")) {
        throw "Data MCP tools XML still contains vcvalidatequery after patch."
    }
    if (-not $patched.Contains("validatequery")) {
        throw "Data MCP tools XML does not contain validatequery after patch."
    }
    return $patched
}

function Prepare-DataMcpToolsXml {
    param([string]$SourcePath)

    $preparedDir = Join-Path (Get-DataMcpRuntimeRoot) "prepared"
    New-Item -ItemType Directory -Force -Path $preparedDir | Out-Null
    $preparedPath = Join-Path $preparedDir "APA_Инструменты.xml"
    $patched = Convert-DataMcpToolsXmlText -Text (Read-Utf8Text -Path $SourcePath)
    Write-Utf8Text -Path $preparedPath -Value $patched
    return $preparedPath
}

function Ensure-DataMcpPackage {
    $archivePath = Get-DataMcpArchivePath
    $extractRoot = Expand-DataMcpArchive -ArchivePath $archivePath
    $cfePath = Find-DataMcpCfePath -ExtractRoot $extractRoot

    $toolsXmlSourcePath = Find-DataMcpToolsXmlPath -ExtractRoot $extractRoot
    $toolsXmlPath = Prepare-DataMcpToolsXml -SourcePath $toolsXmlSourcePath

    return [pscustomobject]@{
        archivePath = $archivePath
        extractRoot = $extractRoot
        cfePath = $cfePath
        toolsXmlSourcePath = $toolsXmlSourcePath
        toolsXmlPath = $toolsXmlPath
    }
}

function Install-DataMcpExtension {
    param(
        [object]$State,
        [string]$CfePath
    )

    if (-not (Test-Path -LiteralPath $CfePath -PathType Leaf -ErrorAction SilentlyContinue)) {
        throw "Data MCP CFE was not found: $CfePath"
    }

    Write-Host "Installing Data MCP extension '$(Get-DataMcpExtensionName)' from: $CfePath"
    return (Invoke-Designer `
        -InfoBasePath $State.devBranchInfoBasePath `
        -InfoBaseKind $State.infoBaseKind `
        -DesignerArgs @("/LoadCfg", $CfePath, "-Extension", (Get-DataMcpExtensionName), "/UpdateDBCfg"))
}

function Get-DataMcpToolsLoaderRootFile {
    return (Join-Path $script:ProjectRoot ".agents\skills\1c-workflow\tools\data-mcp-tools-loader\DataMcpToolsLoader.xml")
}

function Get-DataMcpToolsLoaderEpfPath {
    return (Resolve-ProjectPath ".agent-1c/tools/data-mcp/DataMcpToolsLoader.epf")
}

function Ensure-DataMcpToolsLoaderEpf {
    param([object]$State)

    $sourceRoot = Get-DataMcpToolsLoaderRootFile
    if (-not (Test-Path -LiteralPath $sourceRoot -PathType Leaf -ErrorAction SilentlyContinue)) {
        throw "Data MCP tools loader source was not found: $sourceRoot"
    }

    $epfPath = Get-DataMcpToolsLoaderEpfPath
    $needsBuild = -not (Test-Path -LiteralPath $epfPath -PathType Leaf -ErrorAction SilentlyContinue)
    if (-not $needsBuild) {
        $epfFile = Get-Item -LiteralPath $epfPath
        $sourceNewest = @(Get-ChildItem -LiteralPath (Split-Path -Parent $sourceRoot) -Recurse -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1)[0]
        if ($null -ne $sourceNewest -and $sourceNewest.LastWriteTime -gt $epfFile.LastWriteTime) {
            $needsBuild = $true
        }
    }

    if ($needsBuild) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $epfPath) | Out-Null
        Invoke-Designer `
            -InfoBasePath $State.devBranchInfoBasePath `
            -InfoBaseKind $State.infoBaseKind `
            -DesignerArgs @("/LoadExternalDataProcessorOrReportFromFiles", $sourceRoot, $epfPath) | Out-Null
    }

    return $epfPath
}

function Invoke-DataMcpToolsLoader {
    param(
        [object]$State,
        [string]$ToolsXmlPath
    )

    if (-not (Test-Path -LiteralPath $ToolsXmlPath -PathType Leaf -ErrorAction SilentlyContinue)) {
        throw "Data MCP tools XML was not found: $ToolsXmlPath"
    }

    $runRoot = Resolve-ProjectPath "build/data-mcp-tools-loader"
    New-Item -ItemType Directory -Force -Path $runRoot | Out-Null
    $runDirectory = Join-Path $runRoot ("load-" + (Get-Date -Format "yyyyMMdd-HHmmss-fff"))
    New-Item -ItemType Directory -Force -Path $runDirectory | Out-Null
    $paramsPath = Join-Path $runDirectory "DataMcpToolsLoadParams.json"
    $outputPath = Join-Path $runDirectory "DataMcpToolsLoad.json"

    $payload = [ordered]@{
        toolsXmlPath = $ToolsXmlPath
        outputPath = $outputPath
    }
    Write-Utf8Text -Path $paramsPath -Value (($payload | ConvertTo-Json -Depth 5) + [Environment]::NewLine)

    $epfPath = Ensure-DataMcpToolsLoaderEpf -State $State
    $command = "DataMcpToolsLoad;Params=$paramsPath"
    try {
        Invoke-Enterprise `
            -InfoBasePath $State.devBranchInfoBasePath `
            -InfoBaseKind $State.infoBaseKind `
            -EnterpriseArgs @("/Execute", $epfPath, "/C$command") `
            -TimeoutSeconds (ConvertTo-IntOrDefault -Value (Get-EnvValue -Name "DATA_MCP_TOOLS_LOAD_TIMEOUT_SECONDS" -Default 120) -Default 120) | Out-Null
    } catch {
        if (Test-Path -LiteralPath $outputPath -PathType Leaf -ErrorAction SilentlyContinue) {
            $diagnostic = Read-Utf8Text -Path $outputPath | ConvertFrom-Json
            if ([string]$diagnostic.status -eq "failure") {
                throw "Data MCP tools loader failed. Output: $outputPath. Error: $($diagnostic.errorMessage). Details: $($diagnostic.errorDetails)"
            }
        }
        throw
    }

    if (-not (Test-Path -LiteralPath $outputPath -PathType Leaf -ErrorAction SilentlyContinue)) {
        throw "Data MCP tools loader did not create output file: $outputPath"
    }

    $result = Read-Utf8Text -Path $outputPath | ConvertFrom-Json
    if ([string]$result.status -ne "passed") {
        throw "Data MCP tools loader did not pass. Output: $outputPath. Status: $($result.status)"
    }

    return $outputPath
}

function Set-DataMcpXmlAttribute {
    param(
        [System.Xml.XmlElement]$Element,
        [string]$Name,
        [string]$Value
    )

    if ($Element.HasAttribute($Name)) {
        $Element.SetAttribute($Name, $Value)
    } else {
        [void]$Element.SetAttribute($Name, $Value)
    }
}

function Get-DataMcpChildElement {
    param(
        [System.Xml.XmlNode]$Parent,
        [string]$LocalName
    )

    foreach ($child in $Parent.ChildNodes) {
        if ($child.NodeType -eq [System.Xml.XmlNodeType]::Element -and $child.LocalName -eq $LocalName) {
            return $child
        }
    }
    return $null
}

function Enable-DataMcpHttpService {
    param([string]$PublicationDir)

    if (-not $PublicationDir) {
        throw "Publication directory is empty; cannot patch Data MCP HTTP service."
    }

    $vrdPath = Join-Path $PublicationDir "default.vrd"
    if (-not (Test-Path -LiteralPath $vrdPath -PathType Leaf -ErrorAction SilentlyContinue)) {
        throw "Publication default.vrd was not found: $vrdPath"
    }

    $doc = New-Object System.Xml.XmlDocument
    $doc.PreserveWhitespace = $false
    $doc.Load($vrdPath)

    $point = $doc.DocumentElement
    if ($null -eq $point) {
        throw "Publication default.vrd has no document element: $vrdPath"
    }

    $ns = $point.NamespaceURI
    $httpServices = Get-DataMcpChildElement -Parent $point -LocalName "httpServices"
    if ($null -eq $httpServices) {
        $httpServices = $doc.CreateElement("httpServices", $ns)
        [void]$point.AppendChild($httpServices)
    }

    Set-DataMcpXmlAttribute -Element $httpServices -Name "publishByDefault" -Value "false"
    if (-not $httpServices.HasAttribute("publishExtensionsByDefault")) {
        Set-DataMcpXmlAttribute -Element $httpServices -Name "publishExtensionsByDefault" -Value "false"
    }

    $serviceName = Get-DataMcpHttpServiceName
    $service = $null
    foreach ($child in $httpServices.ChildNodes) {
        if ($child.NodeType -eq [System.Xml.XmlNodeType]::Element -and
            $child.LocalName -eq "service" -and
            [string]$child.GetAttribute("name") -eq $serviceName) {
            $service = $child
            break
        }
    }

    if ($null -eq $service) {
        $service = $doc.CreateElement("service", $ns)
        [void]$httpServices.AppendChild($service)
    }

    Set-DataMcpXmlAttribute -Element $service -Name "name" -Value $serviceName
    Set-DataMcpXmlAttribute -Element $service -Name "rootUrl" -Value (Get-DataMcpHttpServiceRootUrl)
    Set-DataMcpXmlAttribute -Element $service -Name "enable" -Value "true"
    Set-DataMcpXmlAttribute -Element $service -Name "reuseSessions" -Value "autouse"
    Set-DataMcpXmlAttribute -Element $service -Name "sessionMaxAge" -Value "20"
    Set-DataMcpXmlAttribute -Element $service -Name "poolSize" -Value "10"
    Set-DataMcpXmlAttribute -Element $service -Name "poolTimeout" -Value "5"

    $settings = New-Object System.Xml.XmlWriterSettings
    $settings.Encoding = Get-Utf8Encoding
    $settings.Indent = $true
    $settings.OmitXmlDeclaration = $false
    $writer = [System.Xml.XmlWriter]::Create($vrdPath, $settings)
    try {
        $doc.Save($writer)
    } finally {
        $writer.Close()
    }

    Write-Host "Data MCP HTTP service published in: $vrdPath"
    return $vrdPath
}

function Join-DataMcpEndpointUrl {
    param([string]$PublicationUrl)

    if (-not $PublicationUrl) {
        return ""
    }
    return ($PublicationUrl.TrimEnd("/") + "/hs/" + (Get-DataMcpHttpServiceRootUrl))
}

function Test-DataMcpEndpointReachable {
    param([string]$Url)

    if (-not $Url) {
        return $false
    }

    $timeout = ConvertTo-IntOrDefault -Value (Get-EnvValue -Name "DATA_MCP_ENDPOINT_TIMEOUT_SECONDS" -Default 5) -Default 5
    try {
        Invoke-WebRequest -Uri $Url -Method Get -TimeoutSec $timeout -UseBasicParsing | Out-Null
        return $true
    } catch {
        $response = $_.Exception.Response
        if ($null -ne $response) {
            $statusCode = [int]$response.StatusCode
            if (@(400, 405, 406, 415) -contains $statusCode) {
                return $true
            }
            if (@(401, 403, 404) -contains $statusCode) {
                return $false
            }
        }
        return $false
    }
}

function Get-DataMcpEndpointRuntimeName {
    $context = Get-Vibecoding1cMcpScopeContext
    return "itl-$($context.projectSlug)-$($context.branchSlug)-data"
}

function Remove-DataMcpEndpointState {
    $state = Read-Vibecoding1cMcpState
    $stateHash = ConvertTo-Vibecoding1cMcpHashtable -Object $state
    $context = Get-Vibecoding1cMcpScopeContext
    $servers = @()
    foreach ($server in ConvertTo-Vibecoding1cMcpArray (Get-Vibecoding1cMcpObjectValue -Object $state -Name "servers" -Default @())) {
        $isCurrentDataEndpoint = (
            [string](Get-Vibecoding1cMcpObjectValue -Object $server -Name "id" -Default "") -eq "data" -and
            [string](Get-Vibecoding1cMcpObjectValue -Object $server -Name "scope" -Default "") -eq "branch" -and
            [string](Get-Vibecoding1cMcpObjectValue -Object $server -Name "projectSlug" -Default "") -eq $context.projectSlug -and
            [string](Get-Vibecoding1cMcpObjectValue -Object $server -Name "branchSlug" -Default "") -eq $context.branchSlug
        )
        if (-not $isCurrentDataEndpoint) {
            $servers += $server
        }
    }

    $stateHash["servers"] = $servers
    Write-Vibecoding1cMcpState -State $stateHash
}

function Set-DataMcpEndpointState {
    param(
        [object]$State,
        [string]$EndpointUrl
    )

    if (-not $EndpointUrl) {
        throw "Data MCP endpoint URL is empty."
    }

    $mcpState = Read-Vibecoding1cMcpState
    $stateHash = ConvertTo-Vibecoding1cMcpHashtable -Object $mcpState
    $context = Get-Vibecoding1cMcpScopeContext
    $runtimeName = Get-DataMcpEndpointRuntimeName
    $servers = @()
    foreach ($server in ConvertTo-Vibecoding1cMcpArray (Get-Vibecoding1cMcpObjectValue -Object $mcpState -Name "servers" -Default @())) {
        if ([string](Get-Vibecoding1cMcpObjectValue -Object $server -Name "name" -Default "") -ne $runtimeName) {
            $servers += $server
        }
    }

    $servers += [ordered]@{
        id = "data"
        scope = "branch"
        name = $runtimeName
        containerName = ""
        internalPort = 0
        hostPort = 0
        url = $EndpointUrl
        status = "running"
        family = "vibecoding1c"
        provider = "local"
        projectSlug = $context.projectSlug
        branchSlug = $context.branchSlug
        gitBranch = $context.gitBranch
        clientNames = [ordered]@{ aiRules1c = (Get-DataMcpAiRules1cClientName) }
        configId = ""
        health = "reachable"
        sourceCommit = $(try { if (Test-Path -LiteralPath (Join-Path $script:ProjectRoot ".git") -ErrorAction SilentlyContinue) { Get-CurrentCommit } else { "" } } catch { "" })
        sourceFingerprint = $(Get-Vibecoding1cMcpCurrentSourceFingerprint)
        reportHash = ""
        indexedAt = (Get-Date).ToString("o")
        image = ""
        publicationUrl = (Get-StateValue -State $State -Name "publicationUrl" -Default "")
    }

    $stateHash["servers"] = $servers
    Write-Vibecoding1cMcpState -State $stateHash
}

function Install-DevBranchDataMcpBestEffort {
    param(
        [object]$State,
        [string]$PublicationUrl,
        [string]$PublicationDir
    )

    $endpointUrl = Join-DataMcpEndpointUrl -PublicationUrl $PublicationUrl
    $installedAt = (Get-Date).ToString("o")
    $extensionInstalled = $false
    $toolsLoaded = $false
    $publicationPatched = $false

    if (-not $PublicationUrl) {
        return @{
            dataMcpStatus = "skipped"
            dataMcpEndpointUrl = ""
            dataMcpExtensionInstalled = $false
            dataMcpToolsLoaded = $false
            dataMcpPublicationPatched = $false
            dataMcpError = ""
            dataMcpInstalledAt = ""
        }
    }

    try {
        Write-Section "Install branch Data MCP"
        $package = Ensure-DataMcpPackage
        Install-DataMcpExtension -State $State -CfePath $package.cfePath | Out-Null
        $extensionInstalled = $true

        Invoke-DataMcpToolsLoader -State $State -ToolsXmlPath $package.toolsXmlPath | Out-Null
        $toolsLoaded = $true

        Enable-DataMcpHttpService -PublicationDir $PublicationDir | Out-Null
        $publicationPatched = $true

        if (-not (Test-DataMcpEndpointReachable -Url $endpointUrl)) {
            throw "Data MCP endpoint is not reachable without authentication: $endpointUrl"
        }

        Set-DataMcpEndpointState -State $State -EndpointUrl $endpointUrl
        Write-Vibecoding1cMcpClientConfig

        Write-Host "Data MCP endpoint connected: $endpointUrl"
        return @{
            dataMcpStatus = "running"
            dataMcpEndpointUrl = $endpointUrl
            dataMcpExtensionInstalled = $true
            dataMcpToolsLoaded = $true
            dataMcpPublicationPatched = $true
            dataMcpError = ""
            dataMcpInstalledAt = $installedAt
        }
    } catch {
        $message = $_.Exception.Message
        Write-Warning "Data MCP setup failed; development branch creation continues. $message"
        try {
            Remove-DataMcpEndpointState
            Write-Vibecoding1cMcpClientConfig
        } catch {
            Write-Warning "Could not remove stale Data MCP client config. $($_.Exception.Message)"
        }

        return @{
            dataMcpStatus = "failed"
            dataMcpEndpointUrl = $endpointUrl
            dataMcpExtensionInstalled = $extensionInstalled
            dataMcpToolsLoaded = $toolsLoaded
            dataMcpPublicationPatched = $publicationPatched
            dataMcpError = $message
            dataMcpInstalledAt = ""
        }
    }
}

function Write-DataMcpStatusLines {
    param(
        [object]$State,
        [string]$Indent = ""
    )

    $status = Get-StateValue -State $State -Name "dataMcpStatus" -Default ""
    $url = Get-StateValue -State $State -Name "dataMcpEndpointUrl" -Default ""
    $errorText = Get-StateValue -State $State -Name "dataMcpError" -Default ""
    if (-not $status -and -not $url -and -not $errorText) {
        return
    }

    Write-Host "${Indent}Data MCP: $(if ($status) { $status } else { '<unknown>' })"
    if ($url) {
        Write-Host "${Indent}Data MCP endpoint: $url"
    }
    if ($errorText) {
        Write-Host "${Indent}Data MCP error: $errorText"
    }
}
