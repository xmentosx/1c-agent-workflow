# G2 contract only. No network, installed state, client writes or Cognee calls.
function Get-ItlCatalogField {
    param([AllowNull()][object]$Object, [string]$Name, [object]$Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return ,$Object[$Name] }
    } elseif ($Object.PSObject.Properties[$Name]) { return ,$Object.PSObject.Properties[$Name].Value }
    return ,$Default
}

function Get-ItlCatalogKeys {
    param([AllowNull()][object]$Object)
    if ($null -eq $Object) { return @() }
    if ($Object -is [System.Collections.IDictionary]) { return @($Object.Keys) }
    return @($Object.PSObject.Properties | ForEach-Object { $_.Name })
}

function ConvertTo-ItlCatalogCanonicalValue {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary] -or $Value.GetType().FullName -eq 'System.Management.Automation.PSCustomObject') {
        $result = [ordered]@{}
        $keys = [string[]]@(Get-ItlCatalogKeys $Value)
        [Array]::Sort($keys, [StringComparer]::Ordinal)
        foreach ($key in $keys) { $result[$key] = ConvertTo-ItlCatalogCanonicalValue (Get-ItlCatalogField $Value $key) }
        return $result
    }
    if ($Value -is [array]) {
        $items = @($Value | ForEach-Object { ConvertTo-ItlCatalogCanonicalValue $_ })
        return ,$items
    }
    return $Value
}

function Get-ItlCatalogHash {
    param([AllowNull()][object]$Value)
    $json = if ($null -eq $Value) { 'null' } else { ConvertTo-Json -InputObject (ConvertTo-ItlCatalogCanonicalValue $Value) -Depth 100 -Compress }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($json)))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-ItlCatalogSortedUnique {
    param([object[]]$Values)
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($value in $Values) { [void]$seen.Add([string]$value) }
    $items = [string[]]@($seen)
    [Array]::Sort($items, [StringComparer]::Ordinal)
    return $items
}

function Assert-ItlCatalogSchemaValue {
    # Evaluates the deliberately small vocabulary used by the package-owned schemas.
    # This is not an arbitrary/untrusted JSON Schema interpreter.
    param([AllowNull()][object]$Value, [object]$Schema, [object]$RootSchema, [string]$Path = '$')
    $ref = Get-ItlCatalogField $Schema '$ref'
    if ($ref) {
        if ([string]$ref -notmatch '^#/definitions/([A-Za-z0-9]+)$') { throw "CATALOG_SCHEMA: unsupported reference $ref" }
        $Schema = Get-ItlCatalogField (Get-ItlCatalogField $RootSchema 'definitions') $Matches[1]
        if ($null -eq $Schema) { throw "CATALOG_SCHEMA: missing definition $ref" }
    }
    $type = [string](Get-ItlCatalogField $Schema 'type')
    $isObject = $Value -is [System.Collections.IDictionary] -or $Value -is [pscustomobject]
    $isInteger = $Value -is [int] -or $Value -is [long] -or $Value -is [System.Numerics.BigInteger]
    $valid = switch ($type) {
        'object' { $isObject }
        'array' { $Value -is [array] }
        'string' { $Value -is [string] }
        'integer' { $isInteger }
        'boolean' { $Value -is [bool] }
        default { throw "CATALOG_SCHEMA: unsupported type '$type' at $Path" }
    }
    if (-not $valid) { throw "CATALOG_INVALID: $Path must be $type" }
    $enum = Get-ItlCatalogField $Schema 'enum'
    if ($null -ne $enum -and @($enum) -cnotcontains $Value) { throw "CATALOG_INVALID: $Path has unsupported value '$Value'" }
    if ($type -eq 'string') {
        $min = Get-ItlCatalogField $Schema 'minLength'
        $max = Get-ItlCatalogField $Schema 'maxLength'
        $pattern = Get-ItlCatalogField $Schema 'pattern'
        if ($null -ne $min -and $Value.Length -lt $min) { throw "CATALOG_INVALID: $Path is empty" }
        if ($null -ne $max -and $Value.Length -gt $max) { throw "CATALOG_INVALID: $Path exceeds maxLength" }
        if ($pattern -and $Value -cnotmatch $pattern) { throw "CATALOG_INVALID: $Path does not match $pattern" }
    }
    if ($type -eq 'integer') {
        $min = Get-ItlCatalogField $Schema 'minimum'
        if ($null -ne $min -and $Value -lt $min) { throw "CATALOG_INVALID: $Path must be >= $min" }
    }
    if ($type -eq 'array') {
        $min = Get-ItlCatalogField $Schema 'minItems'
        if ($null -ne $min -and $Value.Count -lt $min) { throw "CATALOG_INVALID: $Path needs at least $min items" }
        $seen = @{}
        for ($i = 0; $i -lt $Value.Count; $i++) {
            if (Get-ItlCatalogField $Schema 'uniqueItems' $false) {
                $key = Get-ItlCatalogHash $Value[$i]
                if ($seen.ContainsKey($key)) { throw "CATALOG_INVALID: $Path contains duplicate items" }
                $seen[$key] = $true
            }
            Assert-ItlCatalogSchemaValue $Value[$i] (Get-ItlCatalogField $Schema 'items') $RootSchema "$Path[$i]"
        }
    }
    if ($type -eq 'object') {
        $keys = @(Get-ItlCatalogKeys $Value)
        $min = Get-ItlCatalogField $Schema 'minProperties'
        if ($null -ne $min -and $keys.Count -lt $min) { throw "CATALOG_INVALID: $Path needs at least $min properties" }
        foreach ($required in @((Get-ItlCatalogField $Schema 'required' @()))) {
            if ($keys -cnotcontains $required) { throw "CATALOG_INVALID: $Path.$required is required" }
        }
        $properties = Get-ItlCatalogField $Schema 'properties' @{}
        $additional = Get-ItlCatalogField $Schema 'additionalProperties' $true
        foreach ($key in $keys) {
            $child = Get-ItlCatalogField $properties $key
            if ($null -ne $child) { Assert-ItlCatalogSchemaValue (Get-ItlCatalogField $Value $key) $child $RootSchema "$Path.$key" }
            elseif ($additional -is [bool]) {
                if (-not $additional) { throw "CATALOG_INVALID: unknown field $Path.$key" }
            } else { Assert-ItlCatalogSchemaValue (Get-ItlCatalogField $Value $key) $additional $RootSchema "$Path.$key" }
        }
    }
}

function Get-ItlCatalogIndex {
    param([object[]]$Items, [string]$IdField, [string]$Path)
    $index = @{}
    foreach ($item in $Items) {
        $id = [string](Get-ItlCatalogField $item $IdField)
        if ($index.ContainsKey($id)) { throw "CATALOG_INVALID: duplicate $Path.$IdField '$id'" }
        $index[$id] = $item
    }
    return $index
}

function Get-ItlCatalogComposition {
    param([object]$Relations, [string]$ProductId, [string[]]$Trail = @())
    if ($Trail -contains $ProductId) { throw "CATALOG_INVALID: product cycle $((@($Trail) + $ProductId) -join ' -> ')" }
    $result = @($ProductId)
    foreach ($relation in @((Get-ItlCatalogField $Relations 'relations' @()))) {
        if ($relation.type -eq 'contains' -and $relation.productId -eq $ProductId) {
            $result += @(Get-ItlCatalogComposition $Relations $relation.componentProductId (@($Trail) + $ProductId))
        }
    }
    return @(Get-ItlCatalogSortedUnique $result)
}

function Assert-ItlCatalogAcyclic {
    param([hashtable]$Edges, [string]$Id, [string[]]$Trail = @(), [hashtable]$Done)
    if ($Trail -contains $Id) { throw "CATALOG_INVALID: product cycle $((@($Trail) + $Id) -join ' -> ')" }
    if ($Done.ContainsKey($Id)) { return }
    foreach ($next in @($Edges[$Id])) {
        if ($next) { Assert-ItlCatalogAcyclic $Edges $next (@($Trail) + $Id) $Done }
    }
    $Done[$Id] = $true
}

function Assert-ItlProductCatalog {
    param([object]$Catalog, [object]$Relations, [object]$Registry,
        [string]$SchemaRoot = (Join-Path $PSScriptRoot '../../../../../templates/product-project-registry/schemas'))
    Assert-ItlCatalogBusinessData $Catalog 'catalog'
    Assert-ItlCatalogBusinessData $Relations 'product-relations'
    foreach ($pair in @(@('catalog', $Catalog), @('product-relations', $Relations))) {
        $schema = Get-Content -LiteralPath (Join-Path $SchemaRoot ($pair[0] + '.schema.json')) -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-ItlCatalogSchemaValue $pair[1] $schema $schema $pair[0]
    }
    if ((Get-ItlCatalogField $Registry 'schemaVersion') -ne 2) { throw 'CATALOG_INVALID: registry.schemaVersion must be 2' }
    $products = Get-ItlCatalogIndex @($Catalog.products) 'productId' 'products'
    $projects = Get-ItlCatalogIndex @($Catalog.projects) 'projectId' 'projects'
    $profiles = Get-ItlCatalogIndex @((Get-ItlCatalogField $Catalog 'profiles' @())) 'profileId' 'profiles'
    $sources = Get-ItlCatalogIndex @($Catalog.sources) 'sourceId' 'sources'
    $instances = Get-ItlCatalogIndex @($Catalog.instances) 'instanceId' 'instances'
    foreach ($record in @($Catalog.projects) + @((Get-ItlCatalogField $Catalog 'profiles' @()))) {
        if (-not $products.ContainsKey($record.productId)) { throw "CATALOG_INVALID: unknown productId '$($record.productId)'" }
        $profileId = Get-ItlCatalogField $record 'profileId'
        if ($profileId -and (Get-ItlCatalogKeys $record) -contains 'projectId') {
            if (-not $profiles.ContainsKey($profileId) -or $profiles[$profileId].productId -ne $record.productId) { throw "CATALOG_INVALID: incompatible profileId '$profileId'" }
        }
    }
    foreach ($record in @($Catalog.products) + @($Catalog.projects) + @((Get-ItlCatalogField $Catalog 'profiles' @()))) {
        Assert-ItlCatalogSettings $record $sources $instances 'catalog'
    }
    foreach ($source in @($Catalog.sources)) {
        $endpoint = $source.endpoint
        $hosts = @((Get-ItlCatalogField $Registry 'hosts' @()))
        if (-not $hosts.Count) { throw 'CATALOG_INVALID: business sources require registry schema-v2 hosts' }
        $hostEntry = @($hosts | Where-Object { $_.hostId -ceq $endpoint.hostId })
        if ($hostEntry.Count -ne 1) { throw "CATALOG_INVALID: sources.$($source.sourceId).endpoint.hostId is unknown/ambiguous" }
        $servers = @((Get-ItlCatalogField $hostEntry[0] 'servers' @()))
        $configId = Get-ItlCatalogField $endpoint 'configId'
        $server = @($servers | Where-Object { (Get-ItlCatalogField $_ 'id') -ceq $endpoint.serverId -and
            (-not $configId -or -not (Get-ItlCatalogField $_ 'configId') -or (Get-ItlCatalogField $_ 'configId') -ceq $configId) })
        if ($server.Count -ne 1) { throw "CATALOG_INVALID: sources.$($source.sourceId).endpoint.serverId is unknown/ambiguous" }
        $publishedConfigId = Get-ItlCatalogField $server[0] 'configId'
        if ($configId -and $publishedConfigId -and $configId -cne $publishedConfigId) { throw "CATALOG_INVALID: sources.$($source.sourceId).endpoint.configId does not match the published server" }
        if ($configId -and -not @((Get-ItlCatalogField $hostEntry[0] 'configurations' @()) | Where-Object { (Get-ItlCatalogField $_ 'id') -ceq $configId }).Count) {
            throw "CATALOG_INVALID: sources.$($source.sourceId).endpoint.configId is unknown"
        }
    }
    $edges = @{}
    foreach ($relation in @($Relations.relations)) {
        $targetField = switch ($relation.type) { 'derivedFrom' { 'fromProductId' }; 'contains' { 'componentProductId' }; 'requires' { 'requiredProductId' } }
        $target = [string](Get-ItlCatalogField $relation $targetField)
        foreach ($field in @('fromProductId', 'componentProductId', 'requiredProductId')) {
            if ($field -ne $targetField -and $null -ne (Get-ItlCatalogField $relation $field)) { throw "CATALOG_INVALID: relations.$($relation.type).$field is not the relation target" }
        }
        if (-not $products.ContainsKey($relation.productId) -or -not $products.ContainsKey($target)) { throw "CATALOG_INVALID: relations.$($relation.type) has unknown product reference '$target'" }
        $edges[$relation.productId] = @($edges[$relation.productId]) + $target
    }
    $done = @{}
    foreach ($id in $products.Keys) { Assert-ItlCatalogAcyclic $edges $id @() $done }
    foreach ($areaId in @(Get-ItlCatalogKeys $Relations.knowledgeAreas)) {
        $area = Get-ItlCatalogField $Relations.knowledgeAreas $areaId
        foreach ($id in @($area.availableIn) + @((Get-ItlCatalogField $area 'requiresProducts' @()))) {
            if (-not $products.ContainsKey($id)) { throw "CATALOG_INVALID: knowledgeAreas.$areaId references unknown product '$id'" }
        }
        $canonicalHome = Get-ItlCatalogField $area 'memoryHomeProductId'
        if ($canonicalHome -and @($area.availableIn) -cnotcontains $canonicalHome) { throw "CATALOG_INVALID: knowledgeAreas.$areaId.memoryHomeProductId must belong to availableIn" }
        $range = Get-ItlCatalogField $area 'versionRange'
        $min = Get-ItlCatalogField $range 'minVersion'
        $max = Get-ItlCatalogField $range 'maxVersion'
        if ($min -and $max -and [version]$min -gt [version]$max) { throw "CATALOG_INVALID: knowledgeAreas.$areaId.versionRange is reversed" }
    }
    return [pscustomobject]@{ products = $products; projects = $projects; profiles = $profiles; sources = $sources; instances = $instances }
}

function Assert-ItlCatalogBusinessData {
    param([AllowNull()][object]$Value, [string]$Path)
    if ($Value -is [System.Collections.IDictionary] -or $Value -is [pscustomobject]) {
        foreach ($key in @(Get-ItlCatalogKeys $Value)) {
            if ($key -in @('datasetId', 'datasetIds', 'dataset_id', 'dataset_ids', 'grants', 'acl', 'credentials', 'password', 'apiKey', 'api_key', 'accessToken', 'access_token', 'token', 'secret', 'secrets', 'receipt', 'receipts')) {
                throw "CATALOG_INVALID: $Path.$key belongs outside the business catalog"
            }
            Assert-ItlCatalogBusinessData (Get-ItlCatalogField $Value $key) "$Path.$key"
        }
    } elseif ($Value -is [array]) {
        for ($i = 0; $i -lt $Value.Count; $i++) { Assert-ItlCatalogBusinessData $Value[$i] "$Path[$i]" }
    } elseif ($Value -is [string] -and $Value -match '^https?://') {
        $uriValue = $null
        if ([uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uriValue) -and $uriValue.UserInfo) {
            throw "CATALOG_INVALID: $Path contains URL credentials; keep authentication outside the business catalog"
        }
    }
}

function Assert-ItlCatalogSettings {
    param([object]$Record, [hashtable]$Sources, [hashtable]$Instances, [string]$Path)
    $roles = Get-ItlCatalogField $Record 'roles' @{}
    foreach ($role in @(Get-ItlCatalogKeys $roles)) {
        if ($role -cnotin @('code', 'graph', 'productDocs')) { throw "CATALOG_INVALID: $Path.roles.$role is not a project role" }
        $setting = Get-ItlCatalogField $roles $role
        $mode = Get-ItlCatalogField $setting 'mode'
        $sourceId = Get-ItlCatalogField $setting 'sourceId'
        if ($mode -cnotin @('inherit', 'own', 'disabled')) { throw "CATALOG_INVALID: $Path.roles.$role.mode" }
        if ($mode -eq 'own') {
            if (-not $sourceId -or -not $Sources.ContainsKey($sourceId) -or $Sources[$sourceId].role -cne $role) { throw "CATALOG_INVALID: $Path.roles.$role.sourceId is missing/unknown/wrong role" }
        } elseif ($null -ne $sourceId) { throw "CATALOG_INVALID: $Path.roles.$role.sourceId is only valid for own" }
    }
    $links = Get-ItlCatalogField $Record 'links' @{}
    foreach ($kind in @(Get-ItlCatalogKeys $links)) {
        if ($kind -cnotin @('sppr', 'mantis')) { throw "CATALOG_INVALID: $Path.links.$kind" }
        $link = Get-ItlCatalogField $links $kind
        $instanceId = Get-ItlCatalogField $link 'instanceId'
        if (-not $instanceId -or -not $Instances.ContainsKey($instanceId) -or $Instances[$instanceId].type -cne $kind) { throw "CATALOG_INVALID: $Path.links.$kind.instanceId" }
        if ($kind -eq 'mantis') {
            $allowed = @($link.projectIds)
            foreach ($id in @((Get-ItlCatalogField $link 'searchProjectIds' $allowed))) {
                if ($allowed -notcontains $id) { throw "CATALOG_INVALID: $Path.links.mantis.searchProjectIds must be a subset of projectIds" }
            }
            $routes = Get-ItlCatalogField $link 'createRoutes' @{}
            foreach ($purpose in @(Get-ItlCatalogKeys $routes)) {
                if ($allowed -notcontains (Get-ItlCatalogField $routes $purpose)) { throw "CATALOG_INVALID: $Path.links.mantis.createRoutes.$purpose must belong to projectIds" }
            }
        }
    }
}

function Read-ItlProductCatalogSnapshot {
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot, [Parameter(Mandatory = $true)][string]$Commit)
    # Existing Git owner supplies quoting and UTF-8 transport. Blob IDs identify exact
    # committed bytes even though JSON parsing ignores whitespace/newline differences.
    $previousEncoding = [Console]::OutputEncoding
    $previousOutputEncoding = $OutputEncoding
    [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
    $OutputEncoding = [Text.UTF8Encoding]::new($false)
    try {
    $revision = ((Get-GitOutputAt -Root $RepositoryRoot -Arguments @('rev-parse', '--verify', '--end-of-options', "$Commit^{commit}")) -join "`n").Trim()
    if ($revision -notmatch '^[0-9a-f]{40,64}$') { throw 'CATALOG_INVALID: commit did not resolve to an immutable Git object' }
    $values = @{}
    $hashes = [ordered]@{}
    $paths = @('registry.json', 'catalog/catalog.json', 'catalog/product-relations.json')
    $objectNames = @($paths | ForEach-Object { "${revision}:$_" })
    # These are object identities, not path-list output. Resolve the three fixed
    # names together at the already pinned commit, before any blob is decoded.
    try { $objectIds = @(Get-GitOutputAt -Root $RepositoryRoot -Arguments (@('rev-parse', '--revs-only') + $objectNames)) }
    catch { throw "CATALOG_INVALID: cannot read $($paths -join ', ') at ${revision}: $($_.Exception.Message)" }
    if ($objectIds.Count -ne $paths.Count -or @($objectIds | Where-Object { $_ -notmatch '^[0-9a-f]{40,64}$' }).Count) {
        # Diagnose an incomplete query without accepting partial or reordered
        # identities. The normal path still launches only five Git reads.
        for ($i = 0; $i -lt $paths.Count; $i++) {
            try {
                $id = ((Get-GitOutputAt -Root $RepositoryRoot -Arguments @('rev-parse', '--verify', $objectNames[$i])) -join "`n").Trim()
                if ($id -notmatch '^[0-9a-f]{40,64}$') { throw 'invalid blob identity' }
            } catch { throw "CATALOG_INVALID: cannot read $($paths[$i]) at ${revision}: $($_.Exception.Message)" }
        }
        throw "CATALOG_INVALID: incomplete blob identities for $($paths -join ', ') at $revision"
    }
    for ($i = 0; $i -lt $paths.Count; $i++) {
        $path = $paths[$i]
        $objectName = "${revision}:$path"
        try {
            $hashes[$path] = $objectIds[$i]
            $text = (Get-GitOutputAt -Root $RepositoryRoot -Arguments @('show', $objectName)) -join "`n"
            $values[$path] = $text | ConvertFrom-Json -ErrorAction Stop
        } catch { throw "CATALOG_INVALID: cannot read $path at ${revision}: $($_.Exception.Message)" }
    }
    $null = Assert-ItlProductCatalog $values['catalog/catalog.json'] $values['catalog/product-relations.json'] $values['registry.json']
    return [pscustomobject]@{ catalogRevision = $revision; inputGitObjectIds = $hashes; catalog = $values['catalog/catalog.json']; relations = $values['catalog/product-relations.json']; registry = $values['registry.json'] }
    } finally { [Console]::OutputEncoding = $previousEncoding; $OutputEncoding = $previousOutputEncoding }
}

function Resolve-ItlCatalogArea {
    param([object]$Snapshot, [string]$ProductId, [object]$Rule, [hashtable]$Conditions = @{}, [string]$ProductVersion = '')
    Assert-ItlCatalogConditions $Conditions
    if (@($Rule.availableIn) -cnotcontains $ProductId) { return [pscustomobject]@{ status = 'not-applicable'; reason = 'product-not-in-availableIn' } }
    $composition = @(Get-ItlCatalogComposition $Snapshot.relations $ProductId)
    foreach ($required in @((Get-ItlCatalogField $Rule 'requiresProducts' @()))) {
        if ($composition -cnotcontains $required) { return [pscustomobject]@{ status = 'not-applicable'; reason = "missing-product:$required" } }
    }
    foreach ($condition in @((Get-ItlCatalogField $Rule 'conditions' @()))) {
        if (-not $Conditions.ContainsKey($condition)) { return [pscustomobject]@{ status = 'needs-review'; reason = "unknown-condition:$condition" } }
        if ($Conditions[$condition] -ne $true) { return [pscustomobject]@{ status = 'not-applicable'; reason = "condition-not-met:$condition" } }
    }
    $range = Get-ItlCatalogField $Rule 'versionRange'
    if ($null -ne $range) {
        $parsed = $null
        if (-not [version]::TryParse($ProductVersion, [ref]$parsed)) { return [pscustomobject]@{ status = 'needs-review'; reason = 'unknown-product-version' } }
        $min = Get-ItlCatalogField $range 'minVersion'
        $max = Get-ItlCatalogField $range 'maxVersion'
        if (($min -and $parsed -lt [version]$min) -or ($max -and $parsed -gt [version]$max)) { return [pscustomobject]@{ status = 'not-applicable'; reason = 'outside-version-range' } }
    }
    return [pscustomobject]@{ status = 'applicable'; reason = 'explicit-area-rule' }
}

function Resolve-ItlProductContext {
    param([object]$Snapshot, [Parameter(Mandatory = $true)][string]$ProjectId, [string]$ProfileId = '',
        [object]$Overrides = @{}, [hashtable]$Conditions = @{}, [string]$ProductVersion = '')
    Assert-ItlCatalogConditions $Conditions
    $index = Assert-ItlProductCatalog $Snapshot.catalog $Snapshot.relations $Snapshot.registry
    if (-not $index.projects.ContainsKey($ProjectId)) { throw "CATALOG_INVALID: unknown projectId '$ProjectId'" }
    $project = $index.projects[$ProjectId]
    $product = $index.products[$project.productId]
    if (-not $ProfileId) { $ProfileId = [string](Get-ItlCatalogField $project 'profileId' '') }
    $productProfile = $null
    if ($ProfileId) {
        if (-not $index.profiles.ContainsKey($ProfileId) -or $index.profiles[$ProfileId].productId -ne $product.productId) { throw "CATALOG_INVALID: incompatible profileId '$ProfileId'" }
        $productProfile = $index.profiles[$ProfileId]
    }
    Assert-ItlCatalogSettings $Overrides $index.sources $index.instances 'overrides'
    $layers = @(@{ name = 'local'; value = $Overrides }, @{ name = 'project'; value = $project }, @{ name = 'profile'; value = $productProfile }, @{ name = 'product'; value = $product })
    $roles = [ordered]@{}
    foreach ($role in @('code', 'graph', 'productDocs')) {
        $result = [ordered]@{ mode = 'inherit'; resolution = 'deferred'; provenance = $null; source = $null }
        foreach ($layer in $layers) {
            $entry = Get-ItlCatalogField (Get-ItlCatalogField $layer.value 'roles') $role
            if ($null -eq $entry -or $entry.mode -eq 'inherit') { continue }
            $result.mode = $entry.mode
            $result.provenance = $layer.name
            if ($entry.mode -eq 'disabled') { $result.resolution = 'disabled' }
            else {
                $result.resolution = 'resolved'
                $source = $index.sources[$entry.sourceId]
                $result.source = [ordered]@{ sourceId = $source.sourceId; role = $source.role; endpoint = $source.endpoint; namespace = (Get-ItlCatalogField $source 'namespace'); binding = (Get-ItlCatalogField $source 'binding') }
            }
            break
        }
        $roles[$role] = $result
    }
    $links = [ordered]@{}
    foreach ($kind in @('sppr', 'mantis')) {
        foreach ($layer in $layers) {
            $entry = Get-ItlCatalogField (Get-ItlCatalogField $layer.value 'links') $kind
            if ($null -ne $entry) { $links[$kind] = [ordered]@{ value = $entry; provenance = $layer.name }; break }
        }
    }
    $areas = @()
    $readProducts = @($product.productId)
    foreach ($areaId in @(Get-ItlCatalogSortedUnique @(Get-ItlCatalogKeys $Snapshot.relations.knowledgeAreas))) {
        $area = Get-ItlCatalogField $Snapshot.relations.knowledgeAreas $areaId
        if (@($area.availableIn) -cnotcontains $product.productId) { continue }
        $applicability = Resolve-ItlCatalogArea $Snapshot $product.productId $area $Conditions $ProductVersion
        $canonicalHome = Get-ItlCatalogField $area 'memoryHomeProductId'
        $areas += [ordered]@{ areaId = $areaId; status = $applicability.status; reason = $applicability.reason; memoryHomeProductId = $canonicalHome; requiresProducts = @((Get-ItlCatalogField $area 'requiresProducts' @())); conditions = @((Get-ItlCatalogField $area 'conditions' @())); versionRange = (Get-ItlCatalogField $area 'versionRange') }
        if ($canonicalHome -and $applicability.status -eq 'applicable') { $readProducts += $canonicalHome }
    }
    $settings = [ordered]@{ projectId = $ProjectId; productId = $product.productId; profileId = $ProfileId; roles = $roles; links = $links }
    $knowledge = [ordered]@{ productId = $product.productId; productVersion = $ProductVersion; conditionValues = $Conditions; knowledgeAreas = $areas; productReadCandidates = @(Get-ItlCatalogSortedUnique $readProducts) }
    return [pscustomobject]@{ projectId = $ProjectId; productId = $product.productId; profileId = $ProfileId; catalogRevision = $Snapshot.catalogRevision; inputGitObjectIds = $Snapshot.inputGitObjectIds; roles = $roles; links = $links; knowledgeContext = $knowledge; settingsHash = (Get-ItlCatalogHash $settings); knowledgeHash = (Get-ItlCatalogHash $knowledge) }
}

function Assert-ItlCatalogConditions {
    param([hashtable]$Conditions)
    foreach ($key in $Conditions.Keys) {
        if ($Conditions[$key] -isnot [bool]) { throw "CATALOG_INVALID: conditionValues.$key must be boolean" }
    }
}

function Resolve-ItlProductKnowledge {
    param([object]$Snapshot, [Parameter(Mandatory = $true)][string]$ProductId, [object]$Knowledge,
        [hashtable]$Conditions = @{}, [string]$ProductVersion = '')
    $index = Assert-ItlProductCatalog $Snapshot.catalog $Snapshot.relations $Snapshot.registry
    if (-not $index.products.ContainsKey($ProductId)) { throw "CATALOG_INVALID: unknown productId '$ProductId'" }
    $origin = Get-ItlCatalogField $Knowledge 'origin'
    $evidence = Get-ItlCatalogField $Knowledge 'evidence'
    $app = Get-ItlCatalogField $Knowledge 'applicability' @{}
    $areaIds = @((Get-ItlCatalogField $app 'knowledgeAreas' @()))
    $status = 'applicable'; $reason = 'explicit-verified-evidence'; $homes = @()
    $originValid = (Get-ItlCatalogField $origin 'source') -and (Get-ItlCatalogField $origin 'revision')
    $evidenceValid = @($evidence).Count -gt 0
    foreach ($item in @($evidence)) {
        if (-not (Get-ItlCatalogField $item 'source') -or -not (Get-ItlCatalogField $item 'revision') -or -not (Get-ItlCatalogField $item 'result')) { $evidenceValid = $false }
    }
    if (-not $areaIds.Count -or -not $originValid -or -not $evidenceValid -or (Get-ItlCatalogField $app 'verificationState') -cne 'verified') {
        $status = 'needs-review'; $reason = 'missing-verified-origin-applicability-evidence'
    }
    foreach ($areaId in $areaIds) {
        $rule = Get-ItlCatalogField $Snapshot.relations.knowledgeAreas $areaId
        if (-not $rule) { $status = 'needs-review'; $reason = "unknown-area:$areaId"; continue }
        $resolved = Resolve-ItlCatalogArea $Snapshot $ProductId $rule $Conditions $ProductVersion
        if ($resolved.status -eq 'not-applicable') { $status = $resolved.status; $reason = $resolved.reason; break }
        if ($resolved.status -eq 'needs-review') { $status = $resolved.status; $reason = $resolved.reason }
        $canonicalHome = Get-ItlCatalogField $rule 'memoryHomeProductId'
        if ($canonicalHome) { $homes += $canonicalHome } else { $homes += '' }
    }
    $noteRule = [pscustomobject]@{ availableIn = @($ProductId); requiresProducts = @((Get-ItlCatalogField $app 'requiresProducts' @())); conditions = @((Get-ItlCatalogField $app 'conditions' @())); versionRange = (Get-ItlCatalogField $app 'versionRange') }
    $resolved = Resolve-ItlCatalogArea $Snapshot $ProductId $noteRule $Conditions $ProductVersion
    if ($resolved.status -eq 'not-applicable' -or ($resolved.status -eq 'needs-review' -and $status -ne 'not-applicable')) { $status = $resolved.status; $reason = $resolved.reason }
    $productIds = Get-ItlCatalogField $app 'productIds'
    if ($null -ne $productIds -and @($productIds) -cnotcontains $ProductId) { $status = 'not-applicable'; $reason = 'outside-explicit-products' }
    $allowedFields = @('knowledgeAreas', 'requiresProducts', 'conditions', 'versionRange', 'verificationState', 'independentOfCustomization', 'productIds')
    if ($status -ne 'not-applicable' -and @(Get-ItlCatalogKeys $app | Where-Object { $_ -cnotin $allowedFields }).Count) { $status = 'needs-review'; $reason = 'unsupported-applicability-field' }
    $originProject = Get-ItlCatalogField $origin 'projectId'
    if ($status -ne 'not-applicable' -and $originProject) {
        if (-not $index.projects.ContainsKey($originProject) -or ((Get-ItlCatalogField $index.projects[$originProject] 'customized' $false) -and (Get-ItlCatalogField $app 'independentOfCustomization' $false) -ne $true)) {
            $status = 'needs-review'; $reason = 'customer-independence-unverified'
        }
    }
    $uniqueHomes = @(Get-ItlCatalogSortedUnique $homes)
    $homeId = $null
    $homeStatus = 'needs-review'
    if ($status -eq 'applicable' -and $uniqueHomes.Count -eq 1 -and $uniqueHomes[0]) { $homeId = $uniqueHomes[0]; $homeStatus = 'resolved' }
    return [pscustomobject]@{ status = $status; reason = $reason; memoryHomeProductId = $homeId; homeStatus = $homeStatus; catalogRevision = $Snapshot.catalogRevision; origin = $origin; applicability = $app; evidence = $evidence }
}
