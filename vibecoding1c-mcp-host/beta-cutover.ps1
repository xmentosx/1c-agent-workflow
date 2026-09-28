function Get-BetaProjectIndexSettings {
    param([object]$Config, [object]$Server)
    # This opt-in belongs exclusively to new beta Code/Graph generations.
    if ([string](Get-ObjectValue -Object $Server -Name "channel" -Default "stable") -ne "beta" -or
        [string](Get-ObjectValue -Object $Server -Name "id" -Default "") -notin @("code", "graph")) { return $null }
    $settings = Get-ObjectValue -Object $Config -Name "betaProjectIndex" -Default $null
    if ($null -eq $settings) { return $null }
    $generation = [string](Get-ObjectValue -Object $settings -Name "generation" -Default "")
    if ($generation -notmatch '^[a-z0-9][a-z0-9-]{0,47}$') {
        throw "betaProjectIndex.generation must be a distinct lowercase generation name (1-48 letters, digits or hyphens). Keep the old generation for rollback."
    }
    return $settings
}

function Get-BetaProjectVolumes {
    param([object]$Config, [object]$Server, [object]$ConfigState)
    $settings = Get-BetaProjectIndexSettings -Config $Config -Server $Server
    if ($null -eq $settings) { return @() }
    $configId = [string](Get-ObjectValue -Object $ConfigState -Name "configId" -Default "")
    $serverId = [string]$Server.id
    $container = Expand-Template -Template ([string]$Server.containerNameTemplate) -ConfigId $configId -ServerId $serverId
    if (-not $configId -or $container -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_.-]+$') { throw "Fresh beta volumes require an exact project/container identity." }
    $prefix = "$container-$($settings.generation)"
    if ($serverId -eq "code") { return @([pscustomobject]@{ name = "$prefix-index"; container = "/app/chroma_db"; role = "index" }) }
    return @(
        [pscustomobject]@{ name = "$prefix-neo4j"; container = "/data"; role = "neo4j" },
        [pscustomobject]@{ name = "$prefix-state"; container = "/app/data"; role = "state" }
    )
}

function Initialize-BetaProjectVolumes {
    param([object]$Config, [object]$Context, [switch]$InspectOnly, [switch]$RequireExisting)
    $settings = Get-BetaProjectIndexSettings -Config $Config -Server $Context.betaServer
    $embedding = Get-HostEmbeddingSettings -Config $Config -Server $Context.betaServer
    foreach ($volume in @(Get-BetaProjectVolumes -Config $Config -Server $Context.betaServer -ConfigState $Context.configState)) {
        $labels = [ordered]@{
            "itl.beta.host" = [string](Get-ObjectValue -Object $Config -Name "hostId" -Default "vibecoding1c-mcp-host")
            "itl.beta.config" = [string]$Context.configId
            "itl.beta.server" = [string]$Context.serverId
            "itl.beta.generation" = [string]$settings.generation
            "itl.beta.model" = [string]$embedding.model
        }
        $names = @(Invoke-DockerCommandCapture -Arguments @("volume", "ls", "--format", "{{.Name}}", "--filter", "name=^$([regex]::Escape($volume.name))$") -TimeoutSec 60 -Description "locate beta volume $($volume.name)")
        if ($names -notcontains $volume.name) {
            if ($RequireExisting) { throw "Beta volume '$($volume.name)' is missing. Restore this generation or run an explicitly planned beta cutover; refusing an implicit empty index." }
            if ($InspectOnly) { continue }
            $arguments = @("volume", "create", "--driver", "local")
            foreach ($label in $labels.Keys) { $arguments += @("--label", "$label=$($labels[$label])") }
            Invoke-DockerCommandChecked -Arguments ($arguments + $volume.name) -TimeoutSec 60 -Description "create beta volume $($volume.name)"
        }
        $json = @(Invoke-DockerCommandCapture -Arguments @("volume", "inspect", $volume.name) -TimeoutSec 60 -Description "inspect beta volume $($volume.name)") -join ""
        $decoded = ConvertFrom-Json -InputObject $json
        $items = @($decoded)
        if ($items.Count -ne 1 -or $items[0].Driver -ne "local" -or
            @((Convert-ToHash -Object $items[0].Options).Keys).Count -gt 0) {
            throw "Beta volume '$($volume.name)' must be an ordinary local Linux Docker volume, without bind/driver options. Use a new generation; existing data is retained."
        }
        foreach ($label in $labels.Keys) {
            if ([string](Get-ObjectValue -Object $items[0].Labels -Name $label -Default "") -ne $labels[$label]) {
                throw "Beta volume '$($volume.name)' ownership/model differs ($label). Use a new generation; existing data is retained."
            }
        }
    }
}

function Set-BetaGraphVolumeComposeText {
    param([string]$ComposeText, [string]$Neo4jVolume, [string]$StateVolume)
    $neo4jMount = '"${NEO4J_DATA_PATH:-./data/neo4j_data}:/data"'
    $stateMount = '"${GRAPH_STATE_PATH:-./data/mcp_state}:/app/data"'
    if ($ComposeText -match '(?m)^volumes:' -or
        ([regex]::Matches($ComposeText, [regex]::Escape($neo4jMount))).Count -ne 1 -or
        ([regex]::Matches($ComposeText, [regex]::Escape($stateMount))).Count -ne 1) {
        throw "Beta Graph compose storage contract changed. Reconcile its data mounts before cutover; stable data is retained."
    }
    $result = $ComposeText.Replace($neo4jMount, '"itl_beta_neo4j:/data"').Replace($stateMount, '"itl_beta_state:/app/data"')
    $anchor = '      EMBEDDING_MODEL: ${EMBEDDING_MODEL:-qwen/qwen3-embedding-8b}'
    if (-not $result.Contains($anchor)) { throw "Beta Graph compose embedding contract changed." }
    $result = $result.Replace($anchor, "$anchor`n      EMBEDDING_PROVIDER: remote`n      EMBEDDING_ALLOW_OFFLINE_FALLBACK: `"false`"")
    return "$($result.TrimEnd())`n`nvolumes:`n  itl_beta_neo4j:`n    external: true`n    name: $Neo4jVolume`n  itl_beta_state:`n    external: true`n    name: $StateVolume`n"
}

function Assert-BetaProjectVolumesReady {
    param([object]$Config, [object]$Server, [object]$ConfigState)
    if ($null -eq (Get-BetaProjectIndexSettings -Config $Config -Server $Server)) { return }
    $context = [pscustomobject]@{ betaServer = $Server; configState = $ConfigState; configId = $ConfigState.configId; serverId = $Server.id }
    Initialize-BetaProjectVolumes -Config $Config -Context $context -InspectOnly -RequireExisting
}

function Assert-BetaProjectContainerMounts {
    param([object]$Config, [object]$Server, [object]$ConfigState, [object]$Runtime)
    foreach ($volume in @(Get-BetaProjectVolumes -Config $Config -Server $Server -ConfigState $ConfigState)) {
        $container = if ($volume.role -eq "neo4j") { "$($Runtime.containerName)-neo4j" } else { [string]$Runtime.containerName }
        $json = @(Invoke-DockerCommandCapture -Arguments @("inspect", "-f", "{{json .Mounts}}", $container) -TimeoutSec 60 -Description "verify beta Linux volume for $container") -join ""
        $mounts = ConvertFrom-Json -InputObject $json
        $matches = @($mounts | Where-Object { [string]$_.Destination -eq $volume.container })
        if ($matches.Count -ne 1 -or $matches[0].Type -ne "volume" -or $matches[0].Name -ne $volume.name) {
            throw "Beta container '$container' must mount owned Linux volume '$($volume.name)' at '$($volume.container)'. Refusing a different generation or Windows bind."
        }
    }
}

function Get-BetaCodeDatabasePath {
    param([object]$Activity, [string]$FileName)
    $project = [string](Get-ObjectValue -Object $Activity -Name "metadataProjectId" -Default "")
    $generation = [string](Get-ObjectValue -Object $Activity -Name "metadataGenerationId" -Default "")
    $database = "/app/chroma_db/$FileName"
    if ($project -or $generation) {
        if ($project -notmatch '^[a-zA-Z0-9_-]+$' -or $generation -notmatch '^[a-zA-Z0-9_-]+$') {
            throw "Code metadata generation identity is invalid; inspect stats before retrying beta-preflight."
        }
        $database = "/app/chroma_db/projects/$project/generations/$generation/$FileName"
    }
    return $database
}

function Get-BetaCodeMetadataInventory {
    param([string]$ContainerName, [object]$Activity)
    $database = Get-BetaCodeDatabasePath -Activity $Activity -FileName "metadata_details.db"
    # Read the published database only. Do not import the server or start its indexer.
    $probe = "import json,sqlite3,sys; c=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True); print(json.dumps([r[0] for r in c.execute('SELECT full_path FROM objects ORDER BY full_path')],ensure_ascii=True))"
    $lines = @(Invoke-DockerCommandCapture -Arguments @("exec", $ContainerName, "python", "-c", $probe, $database) -TimeoutSec 60 -Description "read Code metadata identities for beta coverage")
    $rows = @(As-Array (ConvertFrom-Json -InputObject ($lines -join "`n")))
    $expected = Get-ObjectValue -Object $Activity.coverage -Name "objects" -Default $null
    if ($null -eq $expected -or $rows.Count -ne [long]$expected) {
        throw "Code metadata inventory disagrees with stats (rows=$($rows.Count), stats=$expected); wait for indexing to finish and rerun beta-preflight."
    }
    $keys = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $rejected = @()
    foreach ($row in $rows) {
        if ($row -isnot [string] -or [string]::IsNullOrWhiteSpace($row)) { throw "Code metadata inventory contains an invalid row." }
        # Legacy report parsing can promote scalar values and multiline descriptions
        # into objects. Real full_path values are qualified 1C identifier segments.
        if ($row -cmatch '^[\p{L}_][\p{L}\p{M}\p{Nd}_]*(\.[\p{L}_][\p{L}\p{M}\p{Nd}_]*)+$') {
            if (-not $keys.Add($row)) { throw "Code metadata inventory contains duplicate identities." }
        } else { $rejected += $row }
    }
    return [pscustomobject]@{ keys = @($keys); rejected = @($rejected); total = $rows.Count }
}

function Get-BetaCodeFormInventory {
    param([string]$ContainerName, [object]$Activity)
    $database = Get-BetaCodeDatabasePath -Activity $Activity -FileName "form_index.db"
    $probe = "import json,sqlite3,sys; c=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True); print(json.dumps([dict(zip(('object','name','path'),r)) for r in c.execute('SELECT object_name,form_name,file_path FROM forms ORDER BY object_name,form_name')],ensure_ascii=True))"
    $lines = @(Invoke-DockerCommandCapture -Arguments @("exec", $ContainerName, "python", "-c", $probe, $database) -TimeoutSec 60 -Description "read Code form identities for beta coverage")
    $rows = @(As-Array (ConvertFrom-Json -InputObject ($lines -join "`n")))
    $expected = Get-ObjectValue -Object $Activity.coverage -Name "forms" -Default $null
    if ($null -eq $expected -or $rows.Count -ne [long]$expected) { throw "Code form inventory disagrees with stats; wait for indexing to finish and rerun beta-preflight." }
    $keys = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($row in $rows) {
        if (-not $row.object -or -not $row.name -or -not $row.path -or -not $keys.Add("$($row.object).$($row.name)|$($row.path)")) {
            throw "Code form inventory contains invalid or duplicate identities."
        }
    }
    return [pscustomobject]@{ rows = $rows; total = $rows.Count }
}

function New-BetaCodeSourceContext {
    param([string]$ContainerName)
    $root = Get-BetaContainerMountSource -ContainerName $ContainerName -Destination "/app/code"
    # Only the pinned type/folder vocabulary comes from the image. XML is examined
    # independently below; the production metadata parser is not a coverage oracle.
    $probe = "import json,sys; sys.path.insert(0,'/app/src'); from config_report.settings import load_settings; print(json.dumps([dict(name=s.report_plural,folders=s.folder_names,tags=s.xml_element_names) for s in load_settings(None).object_types],ensure_ascii=True))"
    $lines = @(Invoke-DockerCommandCapture -Arguments @("exec", $ContainerName, "python", "-c", $probe) -TimeoutSec 60 -Description "read pinned Code source vocabulary")
    return @{ root = [IO.Path]::GetFullPath($root); types = @(As-Array (ConvertFrom-Json -InputObject ($lines -join "`n"))); files = @{}; xml = @{} }
}

function Get-BetaCodeSourcePath {
    param([object]$Source, [string]$RelativePath)
    if ([IO.Path]::IsPathRooted($RelativePath) -or $RelativePath -match '(^|[\\/])\.\.([\\/]|$)') { throw "Unsafe Code source path; inspect the inventory before retrying." }
    $path = [IO.Path]::GetFullPath((Join-Path $Source.root $RelativePath))
    if (-not $path.StartsWith($Source.root.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw "Code source path leaves its root." }
    return $path
}

function Set-BetaCodeSourceObservation {
    param([object]$Source, [string]$Path, [string]$Value)
    if ($Source.files.ContainsKey($Path)) {
        $before = $Source.files[$Path]
        if ($before -cne $Value) {
            if ($before -eq 'absent' -or $Value -eq 'absent' -or ($before -ne 'present' -and $Value -ne 'present')) {
                throw "Code source changed during coverage verification; wait for a coherent export and retry beta-preflight."
            }
            if ($Value -eq 'present') { return }
        }
    }
    $Source.files[$Path] = $Value
}

function Read-BetaCodeSourceFile {
    param([object]$Source, [string]$Path, [switch]$Xml)
    # File.Exists hides access and I/O errors. Only explicit not-found is absence.
    $stream = $null
    try {
        $stream = [IO.File]::OpenRead($Path)
    } catch [IO.FileNotFoundException] { Set-BetaCodeSourceObservation -Source $Source -Path $Path -Value 'absent'; return $false
    } catch [IO.DirectoryNotFoundException] { Set-BetaCodeSourceObservation -Source $Source -Path $Path -Value 'absent'; return $false }
    try {
        if ($Xml) {
            $memory = New-Object IO.MemoryStream
            try { $stream.CopyTo($memory); $bytes = $memory.ToArray() } finally { $memory.Dispose() }
            $sha = [Security.Cryptography.SHA256]::Create()
            try { Set-BetaCodeSourceObservation -Source $Source -Path $Path -Value ([Convert]::ToBase64String($sha.ComputeHash($bytes))) } finally { $sha.Dispose() }
            $document = New-Object Xml.XmlDocument
            $document.XmlResolver = $null
            $settings = New-Object Xml.XmlReaderSettings
            $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
            $input = New-Object IO.MemoryStream(,$bytes)
            $reader = [Xml.XmlReader]::Create($input, $settings)
            try { $document.Load($reader) } finally { $reader.Dispose(); $input.Dispose() }
            $Source.xml[$Path] = $document
        } else { Set-BetaCodeSourceObservation -Source $Source -Path $Path -Value 'present' }
        return $true
    } finally { $stream.Dispose() }
}

function Get-BetaCodeSourceXml {
    param([object]$Source, [string]$Path)
    if (-not $Source.xml.ContainsKey($Path)) {
        if (-not (Read-BetaCodeSourceFile -Source $Source -Path $Path -Xml)) { throw "Required Code XML is absent: $Path. Restore a coherent source export before retrying." }
    }
    return ,$Source.xml[$Path]
}

function Get-BetaXmlChildren {
    param([object]$Node, [string[]]$Tags)
    if ($null -ne $Node) { @($Node.ChildNodes | Where-Object { $_ -is [Xml.XmlElement] -and $Tags -ccontains $_.LocalName }) }
}

function Get-BetaXmlName {
    param([object]$Node)
    $properties = @(Get-BetaXmlChildren -Node $Node -Tags 'Properties')
    if ($properties.Count -gt 1) { throw "Ambiguous XML Properties in Code source." }
    if ($properties.Count -eq 1) {
        $names = @(Get-BetaXmlChildren -Node $properties[0] -Tags 'Name')
        if ($names.Count -ne 1) { throw "Missing or ambiguous XML Name in Code source." }
        return $names[0].InnerText.Trim()
    }
    return $Node.InnerText.Trim()
}

function Resolve-BetaCodeSourceIdentity {
    param([object]$Source, [string]$Identity)
    $parts = $Identity.Split('.')
    $types = @($Source.types | Where-Object { $_.name -ceq $parts[0] })
    if ($parts.Count % 2 -ne 0 -or $types.Count -ne 1) { throw "Unsupported Code source identity '$Identity'; inspect source/parser differences before retrying." }
    $type = $types[0]
    $paths = @()
    foreach ($folder in $type.folders) {
        $path = Get-BetaCodeSourcePath -Source $Source -RelativePath "$folder/$($parts[1]).xml"
        # Many missing members share a root. Cache first observations, then verify
        # every observed file again once at the end of the coverage transaction.
        $exists = if ($Source.files.ContainsKey($path)) { $Source.files[$path] -ne 'absent' } else { Read-BetaCodeSourceFile -Source $Source -Path $path -Xml }
        if ($exists) { $paths += $path }
    }
    if ($paths.Count -gt 1) { throw "Ambiguous XML files for '$Identity'." }
    if ($paths.Count -eq 0) {
        if (-not $Source.ContainsKey('declarations')) {
            $config = Get-BetaCodeSourceXml -Source $Source -Path (Get-BetaCodeSourcePath -Source $Source -RelativePath 'Configuration.xml')
            $payload = @(Get-BetaXmlChildren -Node $config.DocumentElement -Tags 'Configuration')
            if ($payload.Count -ne 1) { throw "Invalid Configuration.xml while resolving '$Identity'." }
            $groups = @(Get-BetaXmlChildren -Node $payload[0] -Tags 'ChildObjects')
            if ($groups.Count -ne 1) { throw "Missing or ambiguous Configuration.xml declarations." }
            $Source.declarations = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
            foreach ($entry in $groups[0].ChildNodes) {
                if ($entry -is [Xml.XmlElement]) { [void]$Source.declarations.Add("$($entry.LocalName)|$(Get-BetaXmlName -Node $entry)") }
            }
        }
        foreach ($tag in $type.tags) {
            if ($Source.declarations.Contains("$tag|$($parts[1])")) { throw "Declared Code object '$Identity' has no XML file; restore a coherent export before retrying." }
        }
        return [pscustomobject]@{ status = 'absent'; canonical = $null }
    }
    $xml = Get-BetaCodeSourceXml -Source $Source -Path $paths[0]
    $nodes = @(Get-BetaXmlChildren -Node $xml.DocumentElement -Tags $type.tags)
    if ($nodes.Count -ne 1) { throw "Invalid XML object for '$Identity'." }
    $node = $nodes[0]
    $name = Get-BetaXmlName -Node $node
    if ($name -ine $parts[1]) { throw "XML object name disagrees with '$Identity'." }
    $canonical = "$($parts[0]).$name"
    $tags = @{ Реквизиты = 'Attribute'; ТабличныеЧасти = 'TabularSection'; Формы = 'Form'; Команды = 'Command'; Макеты = 'Template'; ЗначенияПеречисления = 'EnumValue'; Измерения = 'Dimension'; Ресурсы = 'Resource'; Подсистемы = 'Subsystem' }
    for ($i = 2; $i -lt $parts.Count; $i += 2) {
        if (-not $tags.ContainsKey($parts[$i])) { throw "Unsupported XML collection in '$Identity'." }
        $groups = @(Get-BetaXmlChildren -Node $node -Tags 'ChildObjects')
        if ($groups.Count -gt 1) { throw "Ambiguous XML ChildObjects in '$Identity'." }
        $children = @()
        if ($groups.Count -eq 1) { $children = @(Get-BetaXmlChildren -Node $groups[0] -Tags $tags[$parts[$i]] | Where-Object { (Get-BetaXmlName -Node $_) -ieq $parts[$i + 1] }) }
        if ($children.Count -eq 0) { return [pscustomobject]@{ status = 'absent'; canonical = $null } }
        if ($children.Count -ne 1) { throw "Ambiguous XML member in '$Identity'." }
        $node = $children[0]
        $canonical += ".$($parts[$i]).$(Get-BetaXmlName -Node $node)"
    }
    return [pscustomobject]@{ status = 'present'; canonical = $canonical }
}

function Assert-BetaCodeSourceUnchanged {
    param([object]$Source)
    foreach ($path in @($Source.files.Keys)) {
        $before = $Source.files[$path]
        [void](Read-BetaCodeSourceFile -Source $Source -Path $path -Xml:($before -notin @('present', 'absent')))
        if ($Source.files[$path] -cne $before) { throw "Code source changed during coverage verification; wait for a coherent export and retry beta-preflight." }
    }
}

function Assert-BetaCodeIndexCoverage {
    param([object]$OldActivity, [object]$NewActivity, [switch]$Fresh, [object]$Source)
    if ($Fresh) {
        # Different model token budgets change chunk counts, but must retain source coverage.
        foreach ($field in @("modules")) {
            $oldCount = Get-ObjectValue -Object $OldActivity.coverage -Name $field -Default $null
            $newCount = Get-ObjectValue -Object $NewActivity.coverage -Name $field -Default $null
            if ($null -eq $oldCount -or $null -eq $newCount -or [long]$newCount -lt [long]$oldCount) {
                throw "Fresh beta Code source coverage '$field' is missing or below the stable baseline. Stable data is retained for rollback."
            }
        }
        $oldInventory = Get-ObjectValue -Object $OldActivity -Name "metadataInventory" -Default $null
        $newInventory = Get-ObjectValue -Object $NewActivity -Name "metadataInventory" -Default $null
        if ($null -eq $oldInventory -or $null -eq $newInventory) {
            throw "Fresh beta Code metadata identities are missing; rerun beta-preflight with current host tooling."
        }
        if (@($newInventory.rejected).Count -gt 0) {
            throw "Fresh beta Code metadata contains malformed object identities. Inspect the parser; stable data is retained for rollback."
        }
        $newKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        foreach ($key in @($newInventory.keys)) { [void]$newKeys.Add([string]$key) }
        $missing = @($oldInventory.keys | Where-Object { -not $newKeys.Contains([string]$_) })
        foreach ($key in $missing) {
            if ($null -eq $Source) { throw "Fresh beta Code lost $($missing.Count) metadata object identities; current XML evidence is required before retrying." }
            $resolved = Resolve-BetaCodeSourceIdentity -Source $Source -Identity $key
            if ($resolved.status -ne 'absent' -and -not $newKeys.Contains([string]$resolved.canonical)) {
                throw "Fresh beta Code lost metadata object identity '$key' present in current XML. Inspect the parser before retrying; stable data is retained for rollback."
            }
        }
        $oldForms = Get-ObjectValue -Object $OldActivity -Name "formInventory" -Default $null
        $newForms = Get-ObjectValue -Object $NewActivity -Name "formInventory" -Default $null
        if ($null -eq $oldForms -or $null -eq $newForms) { throw "Fresh beta Code form identities are missing; rerun beta-preflight with current host tooling." }
        $oldFormKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        $newFormKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        foreach ($row in $oldForms.rows) { [void]$oldFormKeys.Add("$($row.object).$($row.name)|$($row.path)") }
        foreach ($row in $newForms.rows) { [void]$newFormKeys.Add("$($row.object).$($row.name)|$($row.path)") }
        foreach ($pair in @(@{ rows = $oldForms.rows; keys = $newFormKeys; expected = $false }, @{ rows = $newForms.rows; keys = $oldFormKeys; expected = $true })) {
            foreach ($row in $pair.rows) {
                if ($pair.keys.Contains("$($row.object).$($row.name)|$($row.path)")) { continue }
                if ($null -eq $Source -or -not $row.path.StartsWith('/app/code/', [StringComparison]::Ordinal)) { throw "Code form needs verifiable current source coverage; inspect its source path before retrying." }
                $path = Get-BetaCodeSourcePath -Source $Source -RelativePath $row.path.Substring(10)
                $exists = Read-BetaCodeSourceFile -Source $Source -Path $path
                if ($exists -ne $pair.expected) { throw "Fresh beta Code form identity '$($row.object).$($row.name)' disagrees with current source coverage. Inspect the form parser before retrying; stable data is retained for rollback." }
            }
        }
        if ($null -ne $Source) { Assert-BetaCodeSourceUnchanged -Source $Source }
    }
    $oldCollections = Convert-ToHash -Object $OldActivity.collections
    $newCollections = Convert-ToHash -Object $NewActivity.collections
    foreach ($key in $oldCollections.Keys) {
        $minimum = if ($Fresh) { [Math]::Min(1, [int]$oldCollections[$key]) } else { [int]$oldCollections[$key] }
        if (-not $newCollections.Contains($key) -or [int]$newCollections[$key] -lt $minimum) {
            throw "Beta CodeMetadata collection '$key' lost indexed records after migration."
        }
    }
}

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
    if ($ServerId -eq "codechecker") {
        $upstreamImage = [string](Get-ObjectValue -Object $betaServer -Name "upstreamImage" -Default "")
        if ($upstreamImage -notmatch '^comol/1c-code-checker@sha256:[a-f0-9]{64}$' -or [string]$runtime.image -notmatch '^itl/1c-codechecker-beta:[a-z0-9.-]+$') {
            throw "Beta CodeChecker requires the pinned upstream image and a local compatibility image."
        }
    } elseif (-not ([string]$runtime.image).Contains("@sha256:")) {
        throw "Beta '$ServerId' image is not pinned by digest."
    }
    $envValues = Resolve-ServerEnv -Config $Config -Server $betaServer -ConfigState $configState
    if ($ServerId -in @("templates", "code", "graph") -and [string](Get-ObjectValue -Object $envValues -Name "RESET_DATABASE" -Default "false") -notmatch '^(?i:false|0|no|off)$') {
        throw "Beta '$ServerId' would reset a retained database."
    }
    if ($ServerId -eq "syntax" -and [string](Get-ObjectValue -Object $envValues -Name "FULLINDEX" -Default "") -notmatch '^(?i:false|0|no|off)$') {
        throw "Beta Syntax must start with FULLINDEX=false."
    }
    $freshProjectIndex = $null -ne (Get-BetaProjectIndexSettings -Config $Config -Server $betaServer)
    if ($ServerId -in @("templates", "code", "graph") -and -not $freshProjectIndex) {
        $oldModel = [string](Get-ObjectValue -Object $old -Name "embeddingModel" -Default "")
        if ($oldModel -and $oldModel -ne [string]$runtime.embeddingModel) { throw "Beta '$ServerId' would change embedding model from '$oldModel' to '$($runtime.embeddingModel)'." }
    }
    return [pscustomobject]@{ serverId = $ServerId; configId = $ConfigId; scope = $scope; old = $old; betaServer = $betaServer; configState = $configState; runtime = $runtime; freshProjectIndex = $freshProjectIndex }
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
    param([object[]]$OldTools, [object[]]$BetaTools, [switch]$CheckOutputs)
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
        if ($CheckOutputs) {
            $oldOutput = Get-ObjectValue -Object $old -Name "outputSchema" -Default $null
            if ($null -eq $oldOutput) { continue }
            $newOutput = Get-ObjectValue -Object $new -Name "outputSchema" -Default $null
            if ($null -eq $newOutput) { throw "Beta tool '$name' removed its output schema." }
            $oldOutputRequired = @((As-Array (Get-ObjectValue -Object $oldOutput -Name "required" -Default @())) | ForEach-Object { [string]$_ })
            $newOutputRequired = @((As-Array (Get-ObjectValue -Object $newOutput -Name "required" -Default @())) | ForEach-Object { [string]$_ })
            $removedRequired = @($oldOutputRequired | Where-Object { $_ -notin $newOutputRequired })
            if ($removedRequired.Count -gt 0) { throw "Beta tool '$name' no longer guarantees output fields: $($removedRequired -join ', ')." }
            $oldOutputProperties = Get-ObjectValue -Object $oldOutput -Name "properties" -Default $null
            $newOutputProperties = Get-ObjectValue -Object $newOutput -Name "properties" -Default $null
            foreach ($property in @((Convert-ToHash -Object $oldOutputProperties).GetEnumerator())) {
                $newProperty = Get-ObjectValue -Object $newOutputProperties -Name $property.Key -Default $null
                if ($null -eq $newProperty) { throw "Beta tool '$name' removed output field '$($property.Key)'." }
                $oldType = [string](Get-ObjectValue -Object $property.Value -Name "type" -Default "")
                $newType = [string](Get-ObjectValue -Object $newProperty -Name "type" -Default "")
                if ($oldType -and $newType -and $oldType -ne $newType) { throw "Beta tool '$name' changed output type of '$($property.Key)' from '$oldType' to '$newType'." }
            }
        }
    }
}

function Assert-BetaDocsFunctionalCall {
    param([string]$Url)
    $connection = Open-HostMcpConnection -Url $Url
    $response = Invoke-HostMcpTool -Connection $connection -Name "docsearch" -Arguments ([ordered]@{ query = "String" })
    $structured = Get-ObjectValue -Object $response -Name "structuredContent" -Default $null
    $legacyResult = Get-ObjectValue -Object $structured -Name "result" -Default $null
    if ($legacyResult -isnot [string] -or [string]::IsNullOrWhiteSpace($legacyResult)) {
        throw "Beta Docs docsearch did not preserve a nonempty structuredContent.result string."
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
        $indexError = [string](Get-ObjectValue -Object $indexing -Name "error" -Default "")
        if ($indexError) { throw "Code indexing failed: $indexError" }
        return [pscustomobject]@{
            running = [bool](Get-ObjectValue -Object $indexing -Name "running" -Default $false)
            phase = [string](Get-ObjectValue -Object $indexing -Name "phase" -Default "")
            collections = $collections
            coverage = [pscustomobject]@{
                modules = Get-ObjectValue -Object (Get-ObjectValue -Object $data -Name "structural_index" -Default $null) -Name "modules" -Default $null
                objects = Get-ObjectValue -Object (Get-ObjectValue -Object $data -Name "metadata_details" -Default $null) -Name "objects" -Default $null
                forms = Get-ObjectValue -Object (Get-ObjectValue -Object $data -Name "form_index" -Default $null) -Name "forms" -Default $null
            }
            metadataProjectId = [string](Get-ObjectValue -Object (Get-ObjectValue -Object $data -Name "generation" -Default $null) -Name "project_id" -Default "")
            metadataGenerationId = [string](Get-ObjectValue -Object (Get-ObjectValue -Object (Get-ObjectValue -Object $data -Name "generation" -Default $null) -Name "published" -Default $null) -Name "generation_id" -Default "")
        }
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
    if ($Context.serverId -eq "codechecker") { $serverContract["legacyCodeCheckerResult"] = $true }
    if ($Context.serverId -eq "syntax") { $serverContract["legacySyntaxJsonl"] = $true }
    if ($Context.serverId -eq "docs") { $serverContract["legacyDocsResult"] = $true }
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
    $mounts = ConvertFrom-Json -InputObject $json
    $matches = @($mounts | Where-Object { [string]$_.Destination -eq $Destination })
    if ($matches.Count -ne 1) { throw "Expected one '$Destination' mount on '$ContainerName', found $($matches.Count)." }
    return [string]$matches[0].Source
}

function Wait-BetaFreshIndexReady {
    param([object]$Context, [int]$TimeoutSeconds = 7200)
    $freshProjectIndex = [bool](Get-ObjectValue -Object $Context -Name "freshProjectIndex" -Default $false)
    if ($Context.serverId -notin @("docs", "ssl") -and -not $freshProjectIndex) { return }
    $url = "http://localhost:$($Context.runtime.hostPort)/ready"
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastError = ""
    do {
        try {
            $response = Invoke-WebRequest -UseBasicParsing -Uri $url -TimeoutSec 20
            if ([int]$response.StatusCode -eq 200) {
                if ($freshProjectIndex) {
                    $activity = Get-BetaConfigurationIndexActivity -ServerId $Context.serverId -Url ([string]$Context.runtime.url)
                    if ($activity.running) { throw "Beta index is still running ($($activity.phase))." }
                }
                Write-Host "Fresh beta index ready: server=$($Context.serverId) configId=$($Context.configId)"
                return
            }
            $lastError = "HTTP $($response.StatusCode)"
        } catch {
            if ($_.Exception.Message -match 'Code indexing failed:|Graph background task .* failed') { throw }
            $lastError = $_.Exception.Message
        }
        if ((Get-Date) -ge $deadline) { break }
        Start-Sleep -Seconds 10
    } while ($true)
    throw "Fresh beta '$($Context.serverId)' index was not ready within $TimeoutSeconds seconds: $lastError"
}

function Wait-BetaCandidateReady {
    param([object]$Context)
    # At the observed rate (~3 docs/s), the 25,536-document Help corpus needs over two hours.
    $budgetSeconds = if ($Context.serverId -eq "docs") { 10800 } else { 7200 }
    $deadline = (Get-Date).AddSeconds($budgetSeconds)
    [void](Wait-HostMcpReadyConnection -Url ([string]$Context.runtime.url) -ServerId $Context.serverId -ConfigId $Context.configId -TimeoutSeconds $budgetSeconds -RetrySeconds 10)
    $freshIndexBudgetSeconds = if ($Context.serverId -eq "docs" -or [bool](Get-ObjectValue -Object $Context -Name "freshProjectIndex" -Default $false)) {
        [int][Math]::Max(1, [Math]::Ceiling(($deadline - (Get-Date)).TotalSeconds))
    } else { 7200 }
    Wait-BetaFreshIndexReady -Context $Context -TimeoutSeconds $freshIndexBudgetSeconds
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
    if ([bool](Get-ObjectValue -Object $Context -Name "freshProjectIndex" -Default $false)) {
        Initialize-BetaProjectVolumes -Config $Config -Context $Context
        return
    }
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
    if ($context.freshProjectIndex) {
        Ensure-HostEmbeddingModel -Config $Config -Server $context.betaServer
        Initialize-BetaProjectVolumes -Config $Config -Context $context -InspectOnly
    }
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
        Ensure-ToolsListProxyImage -Config $Config
        if ($TargetServerId -eq "graph") { Ensure-DockerImageAvailable -Image ([string]$context.betaServer.neo4jImage) }
        $latestIndexActivity = Get-BetaConfigurationIndexActivity -ServerId $TargetServerId -Url ([string]$context.old.directUrl)
        if ($null -ne $latestIndexActivity) {
            if ($latestIndexActivity.running) { throw "Stable '$TargetServerId' began indexing after preflight; cutover would interrupt it." }
            $preflight.oldIndexActivity = $latestIndexActivity
        }
        if ($TargetServerId -eq "code" -and $context.freshProjectIndex) {
            $inventory = Get-BetaCodeMetadataInventory -ContainerName $context.old.containerName -Activity $preflight.oldIndexActivity
            $preflight.oldIndexActivity | Add-Member -NotePropertyName metadataInventory -NotePropertyValue $inventory -Force
            $forms = Get-BetaCodeFormInventory -ContainerName $context.old.containerName -Activity $preflight.oldIndexActivity
            $preflight.oldIndexActivity | Add-Member -NotePropertyName formInventory -NotePropertyValue $forms -Force
        }
        $oldStopped = $false
        $stateChanged = $false
        try {
            $oldStopped = $true
            Stop-StableForBetaCutover -Context $context
            Copy-BetaDataSnapshot -Config $Config -Context $context
            if ($TargetServerId -eq "graph") {
                Start-ComposeServer -Config $Config -Server $context.betaServer -Runtime $context.runtime -ConfigState $context.configState
            } else {
                Start-DockerServer -Config $Config -Server $context.betaServer -Runtime $context.runtime -ConfigState $context.configState -PreparedBetaImage
            }
            Wait-BetaCandidateReady -Context $context
            $betaTools = @(Get-HostMcpToolsList -Url ([string]$context.runtime.url))
            Assert-BetaToolsAcceptOldCalls -OldTools $preflight.oldTools -BetaTools $betaTools
            $betaIndexActivity = Get-BetaConfigurationIndexActivity -ServerId $TargetServerId -Url ([string]$context.runtime.url)
            if ($null -ne $betaIndexActivity -and $betaIndexActivity.running) { throw "Beta '$TargetServerId' started configuration indexing ($($betaIndexActivity.phase)); refusing a full reindex." }
            if ($TargetServerId -eq "code") {
                $source = $null
                if ($context.freshProjectIndex) {
                    $inventory = Get-BetaCodeMetadataInventory -ContainerName $context.runtime.containerName -Activity $betaIndexActivity
                    $betaIndexActivity | Add-Member -NotePropertyName metadataInventory -NotePropertyValue $inventory -Force
                    $forms = Get-BetaCodeFormInventory -ContainerName $context.runtime.containerName -Activity $betaIndexActivity
                    $betaIndexActivity | Add-Member -NotePropertyName formInventory -NotePropertyValue $forms -Force
                    $source = New-BetaCodeSourceContext -ContainerName $context.runtime.containerName
                }
                Assert-BetaCodeIndexCoverage -OldActivity $preflight.oldIndexActivity -NewActivity $betaIndexActivity -Fresh:$context.freshProjectIndex -Source $source
            }
            $health = Get-HostServerFunctionalHealth -Server $context.runtime
            if ($health.status -eq "degraded") { throw "Beta functional health failed: $($health.message)" }
            $context.runtime.proxyContractPath = New-BetaProxyContract -Config $Config -Context $context
            Enable-ToolsListProxyForRuntime -Config $Config -Runtime $context.runtime
            $publicTools = @(Get-HostMcpToolsList -Url "http://localhost:$($context.runtime.proxyPort)/mcp")
            Assert-BetaToolsAcceptOldCalls -OldTools $preflight.oldTools -BetaTools $publicTools -CheckOutputs
            if ($TargetServerId -eq "docs") {
                Assert-BetaDocsFunctionalCall -Url "http://localhost:$($context.runtime.proxyPort)/mcp"
            }
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
