# Selection is stateless. Installed records, exceptions and transition decisions
# remain in the project lock and the existing per-root update transaction.
function Get-WorkflowDependencyFingerprint {
    param([AllowNull()][object]$Entry)
    $identity = Get-WorkflowDependencyIdentity -Entry $Entry
    $text = ConvertTo-Json -InputObject $identity -Depth 100 -Compress
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-WorkflowDependencyIdentity {
    param([AllowNull()][object]$Entry)
    if ($null -eq $Entry) { return $null }
    if ($Entry -is [Collections.IDictionary] -or $Entry -is [pscustomobject]) {
        $map = ConvertTo-Agent1cHashtable -Object $Entry
        $identity = [ordered]@{}
        $fields = @('version','compatibilityVersion','downstreamRevision','repo','ref','commit','upstreamCommit',
            'assetName','releaseTag','integrity','packageLockSha256','sha256','epfSha256',
            'manifestSha256','patchSha256','protocol','os','arch','sourceRegistry','source','images','profiles')
        foreach ($key in @($map.Keys | Sort-Object)) {
            $value = $map[$key]
            if ([string]$key -eq 'source' -and [string]$value -notmatch '^(npm:|pypi:)') { continue }
            if ([string]$key -in @('images','profiles')) {
                $identity[[string]$key] = ConvertTo-DependencyLockComparableValue -Value $value
                continue
            }
            if ($fields -contains [string]$key -or [string]$key -in @('sdk','clientMcp','vaExtension','correspondingSource')) {
                $identity[[string]$key] = Get-WorkflowDependencyIdentity -Entry $value
            }
        }
        return [pscustomobject]$identity
    }
    if ($Entry -is [Collections.IEnumerable] -and $Entry -isnot [string]) {
        return ,@($Entry | ForEach-Object { Get-WorkflowDependencyIdentity -Entry $_ })
    }
    return $Entry
}

function Get-WorkflowDependencyOrigin {
    param([object]$Entry)
    $repo = [string](Get-ConfigValueFromObject -Object $Entry -Path 'repo' -Default '')
    if ($repo) { return $repo.TrimEnd('/').ToLowerInvariant().Replace('.git','') }
    $url = [string](Get-ConfigValueFromObject -Object $Entry -Path 'url' -Default '')
    if ($url -match '^(https?://[^/]+/[^/]+/[^/]+)/releases/') { return $Matches[1].ToLowerInvariant() }
    $source = [string](Get-ConfigValueFromObject -Object $Entry -Path 'source' -Default '')
    if ($source -match '^(npm:.+)@[^@]+$') { return $Matches[1] }
    if ($source -match '^(pypi:[^=]+)==') { return $Matches[1] }
    $registry = [string](Get-ConfigValueFromObject -Object $Entry -Path 'sourceRegistry' -Default '')
    return $registry
}

function Compare-WorkflowDependencyBuild {
    param([object]$First, [object]$Second)
    # Result: equal, newer, older, incomparable. Hash equality alone never
    # orders different bytes sharing a version.
    if ((Get-WorkflowDependencyFingerprint $First) -ceq (Get-WorkflowDependencyFingerprint $Second)) { return 'equal' }
    $a = ConvertTo-Agent1cHashtable -Object $First
    $b = ConvertTo-Agent1cHashtable -Object $Second
    $aVersion = [string](Get-ConfigValueFromObject $a 'version' '')
    $bVersion = [string](Get-ConfigValueFromObject $b 'version' '')
    $aRevision = [string](Get-ConfigValueFromObject $a 'downstreamRevision' '')
    $bRevision = [string](Get-ConfigValueFromObject $b 'downstreamRevision' '')
    if (-not $aRevision -and [string](Get-ConfigValueFromObject $a 'releaseTag' '') -match 'itl-r(\d+)$') { $aRevision = $Matches[1] }
    if (-not $bRevision -and [string](Get-ConfigValueFromObject $b 'releaseTag' '') -match 'itl-r(\d+)$') { $bRevision = $Matches[1] }
    if ($aVersion -or $bVersion -or $aRevision -or $bRevision) {
        $originA = Get-WorkflowDependencyOrigin $a
        $originB = Get-WorkflowDependencyOrigin $b
        if (-not $originA -or $originA -cne $originB) { return 'incomparable' }
        $versionA = $null; $versionB = $null
        if ($aVersion -or $bVersion) {
            if (-not [version]::TryParse($aVersion.TrimStart('v'), [ref]$versionA) -or
                -not [version]::TryParse($bVersion.TrimStart('v'), [ref]$versionB)) { return 'incomparable' }
            if ($versionA -gt $versionB) { return 'newer' }
            if ($versionA -lt $versionB) { return 'older' }
        }
        if ($aRevision -or $bRevision) {
            $revisionA = 0L; $revisionB = 0L
            if (-not [long]::TryParse(($aRevision -replace '^itl-r',''), [ref]$revisionA) -or
                -not [long]::TryParse(($bRevision -replace '^itl-r',''), [ref]$revisionB)) { return 'incomparable' }
            if ($revisionA -gt $revisionB) { return 'newer' }
            if ($revisionA -lt $revisionB) { return 'older' }
        }
        return 'incomparable'
    }
    $results = @()
    foreach ($key in @($b.Keys)) {
        if ($b[$key] -isnot [Collections.IDictionary] -and $b[$key] -isnot [pscustomobject]) { continue }
        if (-not $a.Contains($key)) { return 'incomparable' }
        $results += Compare-WorkflowDependencyBuild -First $a[$key] -Second $b[$key]
    }
    if ($results.Count -eq 0 -or $results -contains 'incomparable' -or
        ($results -contains 'newer' -and $results -contains 'older')) { return 'incomparable' }
    if ($results -contains 'newer') { return 'newer' }
    if ($results -contains 'older') { return 'older' }
    return 'incomparable'
}

function Get-WorkflowDependencySelectionInput {
    param([string]$Root = $script:ProjectRoot)
    $setting = Get-Variable -Name DependencySelectionFile -ErrorAction SilentlyContinue
    if ($null -eq $setting -or -not [string]$setting.Value) { return $null }
    $path = Resolve-Agent1cFullPath -Path ([string]$setting.Value)
    $document = Read-Utf8Text -Path $path | ConvertFrom-Json -ErrorAction Stop
    if ([int](Get-ConfigValueFromObject $document 'schemaVersion' 0) -ne 1) {
        throw "DEPENDENCY_SELECTION_FILE_INVALID: expected schemaVersion=1 at '$path'."
    }
    $matches = @(@(Get-ConfigValueFromObject $document 'worktrees' @()) | Where-Object {
        $scopeRoot = [string](Get-ConfigValueFromObject $_ 'worktreePath' '')
        $scopeRoot -and (Get-FullPathNormalized $scopeRoot) -eq (Get-FullPathNormalized $Root)
    })
    if ($matches.Count -gt 1) { throw "DEPENDENCY_SELECTION_SCOPE_AMBIGUOUS: '$path' repeats '$Root'." }
    if ($matches.Count -eq 0) { return $null }
    return $matches[0]
}

function Assert-WorkflowDependencySelectionScopes {
    param([string[]]$Roots)
    if (-not $DependencySelectionFile) { return }
    $path = Resolve-Agent1cFullPath -Path $DependencySelectionFile
    $document = Read-Utf8Text -Path $path | ConvertFrom-Json -ErrorAction Stop
    $scopes = @(Get-ConfigValueFromObject $document 'worktrees' @())
    if ([int](Get-ConfigValueFromObject $document 'schemaVersion' 0) -ne 1 -or $scopes.Count -eq 0) {
        throw "DEPENDENCY_SELECTION_FILE_INVALID: '$path' requires schemaVersion=1 and nonempty worktrees."
    }
    $allowed = @($Roots | ForEach-Object { Get-FullPathNormalized $_ })
    $seen = @{}
    foreach ($scope in $scopes) {
        $root = [string](Get-ConfigValueFromObject $scope 'worktreePath' '')
        if (-not $root -or -not [IO.Path]::IsPathRooted($root) -or $allowed -notcontains (Get-FullPathNormalized $root)) {
            throw "DEPENDENCY_SELECTION_SCOPE_UNKNOWN: '$root' is not an update target. Correct worktreePath in '$path', then repeat update-workflow."
        }
        $key = Get-FullPathNormalized $root
        if ($seen.ContainsKey($key)) { throw "DEPENDENCY_SELECTION_SCOPE_AMBIGUOUS: '$path' repeats '$root'." }
        $seen[$key] = $true
    }
}

function Assert-WorkflowOpenSpecResource {
    param([object]$Entry, [object]$Resource)
    $packageText = [string](Get-ConfigValueFromObject $Resource 'packageJson' '')
    $lockText = [string](Get-ConfigValueFromObject $Resource 'packageLockJson' '')
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $actual = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($lockText)))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
    if (-not $packageText -or -not $lockText -or $actual -ine [string]$Entry.packageLockSha256) {
        throw 'DEPENDENCY_HOTFIX_OPENSPEC_RESOURCE_REQUIRED: supply resources.openSpecCli.packageJson and packageLockJson with the selected packageLockSha256.'
    }
    $package = $packageText | ConvertFrom-Json -ErrorAction Stop
    $lock = ($lockText -replace '"":\s*\{', '"__packageRoot__": {') | ConvertFrom-Json -ErrorAction Stop
    $pinned = Get-ConfigValueFromObject $lock 'packages.node_modules/@fission-ai/openspec' $null
    if ([string]$package.dependencies.'@fission-ai/openspec' -cne [string]$Entry.version -or
        [string]$pinned.version -cne [string]$Entry.version -or [string]$pinned.integrity -cne [string]$Entry.integrity) {
        throw 'DEPENDENCY_HOTFIX_OPENSPEC_RESOURCE_CONFLICT: resource files, version and integrity disagree.'
    }
}

function Assert-WorkflowDependencyHotfix {
    param([string]$Id, [object]$Hotfix, [object]$Template)
    $reason = [string](Get-ConfigValueFromObject $Hotfix 'reason' '')
    $entries = ConvertTo-Agent1cHashtable -Object (Get-ConfigValueFromObject $Hotfix 'dependencies' $null)
    if (-not $reason -or $entries.Count -eq 0) {
        throw "DEPENDENCY_HOTFIX_INCOMPLETE: '$Id' requires reason and dependencies. Supply a complete selection file or remove this hotfix with update-workflow -DependencySelectionFile."
    }
    $templateEntries = ConvertTo-Agent1cHashtable -Object (Get-ConfigValueFromObject $Template 'dependencies' $null)
    foreach ($name in @($entries.Keys)) {
        if ($name -eq 'workflowPackage' -or -not $templateEntries.Contains($name)) {
            throw "DEPENDENCY_HOTFIX_OWNER_INVALID: '$name' is not a managed component."
        }
        $missing = @(Get-MissingDependencyLockValuePaths -Current $entries[$name] -Template $templateEntries[$name] -Prefix $name)
        if ($missing.Count -gt 0) { throw "DEPENDENCY_HOTFIX_INCOMPLETE: '$Id' missing $($missing -join ', ')." }
    }
    $families = @()
    if ($entries.Contains('roctupMcpToolkit')) { $families += 'roctup' }
    if ($entries.Contains('vanessaAutomation') -or $entries.Contains('vanessaMcp')) {
        if (-not $entries.Contains('vanessaAutomation') -or -not $entries.Contains('vanessaMcp')) {
            throw "DEPENDENCY_HOTFIX_PAIR_REQUIRED: '$Id' must contain vanessaAutomation and the complete vanessaMcp pair."
        }
        $families += 'vanessa-ui'
    }
    foreach ($family in $families) {
        $definition = Get-ConfigValueFromObject $Hotfix "compatibility.families.$family" $null
        $catalog = [string](Get-ConfigValueFromObject $definition 'catalog' '')
        $hash = [string](Get-ConfigValueFromObject $definition 'catalogSha256' '')
        $body = [string](Get-ConfigValueFromObject $Hotfix "catalogs.$family" '')
        if (-not $definition -or -not $catalog -or $hash -notmatch '^[a-fA-F0-9]{64}$' -or -not $body) {
            throw "DEPENDENCY_HOTFIX_CATALOG_REQUIRED: '$Id/$family' requires its compatibility definition, canonical catalog text and SHA256."
        }
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $actual = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($body.Replace("`r`n","`n").Replace("`r","`n"))))).Replace('-','').ToLowerInvariant() }
        finally { $sha.Dispose() }
        if ($actual -cne $hash.ToLowerInvariant()) { throw "DEPENDENCY_HOTFIX_CATALOG_HASH_MISMATCH: '$Id/$family'." }
        $catalogDocument = $body | ConvertFrom-Json -ErrorAction Stop
        $tools = @(Get-ConfigValueFromObject $catalogDocument 'tools' @())
        if ([string](Get-ConfigValueFromObject $catalogDocument 'family' '') -cne $family -or $tools.Count -eq 0) {
            throw "DEPENDENCY_HOTFIX_CATALOG_INVALID: '$Id/$family' requires a nonempty tools/list catalog for that family."
        }
        $declaredVersions = ConvertTo-Json (ConvertTo-DependencyLockComparableValue (Get-ConfigValueFromObject $definition 'backendVersions' $null)) -Depth 100 -Compress
        $catalogVersions = ConvertTo-Json (ConvertTo-DependencyLockComparableValue (Get-ConfigValueFromObject $catalogDocument 'backendVersions' $null)) -Depth 100 -Compress
        if ($declaredVersions -cne $catalogVersions) { throw "DEPENDENCY_HOTFIX_CATALOG_VERSION_MISMATCH: '$Id/$family'." }
        if ($family -eq 'roctup' -and [string]$definition.backendVersions.roctup -cne [string]$entries.roctupMcpToolkit.version) {
            throw "DEPENDENCY_HOTFIX_BACKEND_VERSION_MISMATCH: '$Id/roctup'."
        }
        if ($family -eq 'vanessa-ui') {
            foreach ($pair in @(@('clientMcp','vanessaMcp.clientMcp.version'),@('vaExtension','vanessaMcp.vaExtension.version'),@('vanessaAutomation','vanessaAutomation.version'))) {
                if ([string](Get-ConfigValueFromObject $definition "backendVersions.$($pair[0])" '') -cne [string](Get-ConfigValueFromObject $entries $pair[1] '')) {
                    throw "DEPENDENCY_HOTFIX_BACKEND_VERSION_MISMATCH: '$Id/$($pair[0])'."
                }
            }
            foreach ($pair in @(@('archiveSha256','sha256'),@('epfSha256','epfSha256'),@('manifestSha256','manifestSha256'),@('patchSha256','patchSha256'))) {
                if ([string](Get-ConfigValueFromObject $definition "vanessaAutomationArtifact.$($pair[0])" '') -cne [string](Get-ConfigValueFromObject $entries "vanessaAutomation.$($pair[1])" '')) {
                    throw "DEPENDENCY_HOTFIX_PAIRED_HASH_MISMATCH: '$Id/$($pair[0])'."
                }
            }
            if ([string](Get-ConfigValueFromObject $definition 'pairedExtensionArtifact.sha256' '') -cne [string]$entries.vanessaMcp.vaExtension.sha256) {
                throw "DEPENDENCY_HOTFIX_PAIRED_HASH_MISMATCH: '$Id/vaExtension'."
            }
        }
    }
    foreach ($family in @((ConvertTo-Agent1cHashtable (Get-ConfigValueFromObject $Hotfix 'compatibility.families' $null)).Keys)) {
        if ($families -notcontains $family) { throw "DEPENDENCY_HOTFIX_COMPATIBILITY_OWNER_INVALID: '$Id' does not own '$family'." }
    }
    if (-not $entries.Contains('itlOndemandMcp') -and
        ($null -ne (Get-ConfigValueFromObject $Hotfix 'compatibility.facadeVersion' $null) -or
         $null -ne (Get-ConfigValueFromObject $Hotfix 'compatibility.minimumFacadeVersion' $null))) {
        throw "DEPENDENCY_HOTFIX_COMPATIBILITY_OWNER_INVALID: '$Id' must include the facade entry to change its compatibility."
    }
    foreach ($name in @((ConvertTo-Agent1cHashtable (Get-ConfigValueFromObject $Hotfix 'resources' $null)).Keys)) {
        if (-not $entries.Contains($name)) { throw "DEPENDENCY_HOTFIX_RESOURCE_OWNER_INVALID: '$Id' does not own '$name'." }
    }
    if ($entries.Contains('openSpecCli')) {
        Assert-WorkflowOpenSpecResource -Entry $entries.openSpecCli -Resource (Get-ConfigValueFromObject $Hotfix 'resources.openSpecCli' $null)
    }
    if ($entries.Contains('windowsMcp') -and ([string]$entries.windowsMcp.sha256 -notmatch '^[a-fA-F0-9]{64}$' -or
        [string]$entries.windowsMcp.url -notmatch '^https://.+\.whl$')) {
        throw "DEPENDENCY_HOTFIX_WINDOWS_MCP_WHEEL_REQUIRED: '$Id' requires an exact HTTPS wheel URL and SHA256."
    }
    if ($entries.Contains('itlOndemandMcp') -and
        [string](Get-ConfigValueFromObject $Hotfix 'compatibility.facadeVersion' '') -cne [string]$entries.itlOndemandMcp.version) {
        throw "DEPENDENCY_HOTFIX_FACADE_MANIFEST_REQUIRED: '$Id' requires compatibility for its selected facade version."
    }
}

function New-WorkflowDependencyPlan {
    param([object]$Template, [object]$Manifest, [object]$InstalledTemplate = $null, [object]$Selection = $null, [object]$Compatibility = $null)
    if ($null -eq $InstalledTemplate) { $InstalledTemplate = $Template }
    $baseline = ConvertTo-Agent1cHashtable -Object (Get-ConfigValueFromObject $Template 'dependencies' $null)
    $oldBaseline = ConvertTo-Agent1cHashtable -Object (Get-ConfigValueFromObject $InstalledTemplate 'dependencies' $null)
    $result = ConvertTo-Agent1cHashtable -Object $Manifest
    $entries = ConvertTo-Agent1cHashtable -Object (Get-ConfigValueFromObject $Manifest 'dependencies' $null)
    $hotfixes = ConvertTo-Agent1cHashtable -Object (Get-ConfigValueFromObject $Manifest 'hotfixes' $null)
    $previousHotfixes = ConvertTo-Agent1cHashtable -Object $hotfixes
    if ($null -ne $Selection -and $null -ne (Get-ConfigValueFromObject $Selection 'hotfixes' $null)) {
        $hotfixes = ConvertTo-Agent1cHashtable -Object $Selection.hotfixes
    }
    $decisions = ConvertTo-Agent1cHashtable -Object (Get-ConfigValueFromObject $Selection 'decisions' $null)
    if ($null -ne $Selection -and $null -ne (Get-ConfigValueFromObject $Selection 'hotfixes' $null)) {
        foreach ($oldId in @($previousHotfixes.Keys)) {
            if (-not $hotfixes.Contains($oldId)) {
                foreach ($name in @((ConvertTo-Agent1cHashtable -Object $previousHotfixes[$oldId].dependencies).Keys)) {
                    $decisions[$name] = 'workflow'
                }
            }
        }
    }
    $states = @(); $blocked = @(); $covered = @{}; $retained = [ordered]@{}
    foreach ($id in @($hotfixes.Keys)) {
        $hotfix = $hotfixes[$id]
        $fixEntries = ConvertTo-Agent1cHashtable -Object (Get-ConfigValueFromObject $hotfix 'dependencies' $null)
        try { Assert-WorkflowDependencyHotfix -Id $id -Hotfix $hotfix -Template $Template }
        catch {
            $blocked += [pscustomobject]@{component=$id;components=@($fixEntries.Keys);reason=$_.Exception.Message;choices=@('workflow','qualified hotfix')}
            $retained[$id]=$hotfix
            foreach ($name in @($fixEntries.Keys)) { $covered[$name]=$id }
            continue
        }
        $comparisons = @($fixEntries.Keys | ForEach-Object { Compare-WorkflowDependencyBuild $baseline[$_] $fixEntries[$_] })
        if ($comparisons -notcontains 'newer' -and $comparisons -notcontains 'older') {
            foreach ($family in @((ConvertTo-Agent1cHashtable (Get-ConfigValueFromObject $hotfix 'compatibility.families' $null)).Keys)) {
                if ([string](Get-ConfigValueFromObject $Compatibility "families.$family.catalogSha256" '') -cne
                    [string](Get-ConfigValueFromObject $hotfix "compatibility.families.$family.catalogSha256" '')) {
                    $comparisons += 'incomparable'
                }
            }
        }
        $decision = if ($decisions.Contains($id)) { [string]$decisions[$id] } else { '' }
        $retire = ($comparisons -notcontains 'older' -and $comparisons -notcontains 'incomparable') -or $decision -eq 'workflow'
        if ($comparisons -contains 'incomparable' -and $decision -ne 'workflow' -and $decision -ne 'hotfix') {
            $blocked += [pscustomobject]@{ component=$id; components=@($fixEntries.Keys); reason='same-version bytes or incomparable build lineage'; choices=@('workflow','hotfix') }
        }
        foreach ($name in @($fixEntries.Keys)) {
            if ($covered.ContainsKey($name)) {
                $blocked += [pscustomobject]@{component=$id;components=@($name);reason="DEPENDENCY_HOTFIX_OVERLAP: '$name' belongs to more than one exception.";choices=@('workflow','one qualified hotfix')}
            }
            $covered[$name] = $id
        }
        if (-not $retire) {
            $retained[$id] = $hotfix
            foreach ($name in @($fixEntries.Keys)) { $entries[$name] = $fixEntries[$name] }
        }
        $states += [pscustomobject]@{ component=$id; selection=$(if($retire){'workflow'}else{'hotfix'}); reason=[string]$hotfix.reason }
    }
    foreach ($name in @($baseline.Keys)) {
        if ($name -eq 'workflowPackage') { continue }
        if ($covered.ContainsKey($name) -and $retained.Contains($covered[$name])) { continue }
        if ($entries.Contains($name) -and $oldBaseline.Contains($name) -and
            (Get-WorkflowDependencyFingerprint $entries[$name]) -cne (Get-WorkflowDependencyFingerprint $oldBaseline[$name]) -and
            -not $covered.ContainsKey($name)) {
            $decision = [string](Get-ConfigValueFromObject $decisions $name '')
            # A schema-2 record already carries the baseline identity admitted
            # by its previous transaction; it is not a new custom-pin question.
            $recorded = [string](Get-ConfigValueFromObject $Manifest "baselineFingerprints.$name" '')
            if ($recorded -ne (Get-WorkflowDependencyFingerprint $entries[$name]) -and $decision -ne 'workflow') {
                $blocked += [pscustomobject]@{ component=$name; reason='legacy custom pin'; choices=@('workflow','qualified hotfix') }
            }
        }
        $merged = Merge-WorkflowManagedDependencyLockValue -Current $(if($entries.Contains($name)){$entries[$name]}else{$null}) -Template $baseline[$name]
        $entries[$name] = $merged.value
    }
    $fingerprints = [ordered]@{}
    foreach ($name in @($baseline.Keys)) {
        if ($name -ne 'workflowPackage') { $fingerprints[$name] = Get-WorkflowDependencyFingerprint $entries[$name] }
    }
    $result['schemaVersion'] = 2
    $result['mode'] = 'workflow'
    $result['dependencies'] = $entries
    $result['hotfixes'] = $retained
    $result['baselineFingerprints'] = $fingerprints
    return [pscustomobject]@{ manifest=$result; installed=$Manifest; blocked=@($blocked); states=@($states); decisions=$decisions }
}

function Get-WorkflowDependencyPlan {
    param([string]$SourceRoot = '')
    $pending = $null
    if (Get-Command Get-WorkflowUpdatePendingSnapshot -ErrorAction SilentlyContinue) {
        $pending = Get-WorkflowUpdatePendingSnapshot
        if ($null -ne $pending) {
            $saved = Get-ConfigValueFromObject $pending.receipt 'dependencyPlan' $null
            if ($null -ne $saved -and (-not $SourceRoot -or
                (Get-FullPathNormalized $SourceRoot) -eq (Get-FullPathNormalized ([string]$pending.receipt.sourceRoot)))) {
                return $saved
            }
        }
    }
    $memoKey = ''
    if (-not $SourceRoot -and $null -eq $pending) {
        # Memoize pure selection by complete input bytes, never timestamps.
        # Decode a private copy for each caller; no runtime/proof is cached.
        $templatePath = Get-WorkflowTemplatePath -Name 'dependency-lock.json'
        $compatibilityPath = Join-Path (Get-ItlOnDemandMcpAssetRoot) 'compatibility.json'
        $selectionVariable = Get-Variable -Name DependencySelectionFile -ErrorAction SilentlyContinue
        $selectionPath = if ($null -ne $selectionVariable -and [string]$selectionVariable.Value) { Resolve-Agent1cFullPath -Path ([string]$selectionVariable.Value) } else { '' }
        $parts = @($script:ProjectRoot,$templatePath,$compatibilityPath,$selectionPath)
        foreach ($path in @($templatePath,(Get-DependencyLockPath),$compatibilityPath,$selectionPath)) {
            $parts += $(if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) { (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash } else { '<absent>' })
        }
        $memoKey = $parts -join '|'
        $memo = Get-Variable -Name WorkflowDependencyPlanMemo -Scope Script -ErrorAction SilentlyContinue
        if ($null -ne $memo -and [string]$memo.Value.key -ceq $memoKey) { return ($memo.Value.json | ConvertFrom-Json) }
    }
    if (-not $SourceRoot) {
        # A fresh post-copy process consumes the exact decision armed by the
        # original update owner, not a potentially edited input file.
        $template = New-DefaultDependencyLockManifest
        $installed = $template
        # Backward-compatible decoding of a transaction created before this
        # contract: its original templates are already captured by the owner.
        if ($null -ne $pending) {
            $record = @($pending.snapshot.records | Where-Object { ([string]$_.relativePath).Replace('\','/') -eq 'templates' } | Select-Object -First 1)
            if ($record.Count -eq 1 -and [bool]$record[0].existed) {
                $oldTemplate = Join-Path ([string]$record[0].backupPath) 'dependency-lock.json'
                if (Test-Path -LiteralPath $oldTemplate -PathType Leaf) { $installed = Read-Utf8Text -Path $oldTemplate | ConvertFrom-Json }
            }
        }
        $compatibilityPath = Join-Path (Get-ItlOnDemandMcpAssetRoot) 'compatibility.json'
        $compatibility = if (Test-Path -LiteralPath $compatibilityPath -PathType Leaf) { Read-Utf8Text -Path $compatibilityPath | ConvertFrom-Json } else { $null }
        $plan = New-WorkflowDependencyPlan -Template $template -InstalledTemplate $installed -Manifest (Read-DependencyLockManifest) -Selection (Get-WorkflowDependencySelectionInput) -Compatibility $compatibility
        $plan | Add-Member -NotePropertyName workflowTransition -NotePropertyValue ($null -ne $pending)
        if ($memoKey) { $script:WorkflowDependencyPlanMemo = @{key=$memoKey;json=($plan | ConvertTo-Json -Depth 100 -Compress)} }
        return $plan
    }
    $path = Join-Path $SourceRoot 'templates/dependency-lock.json'
    $target = Read-Utf8Text -Path $path | ConvertFrom-Json -ErrorAction Stop
    $compatibilityPath = Join-Path $SourceRoot '.agents/skills/1c-workflow/assets/ondemand-mcp/compatibility.json'
    $compatibility = if (Test-Path -LiteralPath $compatibilityPath -PathType Leaf) { Read-Utf8Text -Path $compatibilityPath | ConvertFrom-Json } else { $null }
    $lockPath = Get-DependencyLockPath
    $inputExists = Test-Path -LiteralPath $lockPath -PathType Leaf
    $inputHash = ''
    if ($inputExists) {
        $inputBytes = [IO.File]::ReadAllBytes($lockPath)
        $inputText = ([Text.UTF8Encoding]::new($false,$true)).GetString($inputBytes).TrimStart([char]0xfeff)
        $inputManifest = $inputText | ConvertFrom-Json -ErrorAction Stop
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $inputHash = ([BitConverter]::ToString($sha.ComputeHash($inputBytes))).Replace('-','').ToLowerInvariant() }
        finally { $sha.Dispose() }
    } else { $inputManifest = New-DefaultDependencyLockManifest }
    $plan = New-WorkflowDependencyPlan -Template $target -InstalledTemplate (New-DefaultDependencyLockManifest) -Manifest $inputManifest -Selection (Get-WorkflowDependencySelectionInput) -Compatibility $compatibility
    $plan | Add-Member -NotePropertyName workflowTransition -NotePropertyValue $true
    $plan | Add-Member -NotePropertyName inputLockExists -NotePropertyValue ([bool]$inputExists)
    $plan | Add-Member -NotePropertyName inputLockSha256 -NotePropertyValue $inputHash
    return $plan
}

function Assert-WorkflowDependencyPlan {
    param([object]$Plan, [switch]$ReadOnly)
    if (@($Plan.blocked).Count -eq 0) { return }
    if ($ReadOnly) {
        throw 'DEPENDENCY_SELECTION_REQUIRED: the selected component needs review. Run update-workflow from master to obtain the dependency decision report, apply the explicit choice through that owner, then repeat this operation. Diagnostics have not changed dependencies or written a report.'
    }
    $reportPath = Join-Path $script:ProjectRoot '.agent-1c/snapshots/dependency-selection.json'
    Ensure-Agent1cLifecycleLocksIgnored -WorktreePath $script:ProjectRoot
    $report = [ordered]@{ schemaVersion=1; worktreePath=$script:ProjectRoot; blocked=@($Plan.blocked); installed=$Plan.installed; proposed=$Plan.manifest }
    Write-Utf8TextAtomic -Path $reportPath -Value (($report | ConvertTo-Json -Depth 100) + [Environment]::NewLine)
    throw "DEPENDENCY_SELECTION_REQUIRED: review '$reportPath'; supply decisions or a complete compatible hotfix with -DependencySelectionFile <UTF-8 JSON> and repeat the original helper operation. Current dependencies have not been replaced."
}

function Get-WorkflowDependencySyncManifest {
    param([object]$Plan, [object]$Before)
    $manifest = ConvertTo-Agent1cHashtable -Object $Plan.manifest
    $manifest['dependencies'] = ConvertTo-Agent1cHashtable -Object $manifest.dependencies
    # These records prove actual installation and belong to their installers.
    foreach ($name in @('workflowPackage','aiRules1c')) {
        $installed = Get-ConfigValueFromObject $Before "dependencies.$name" $null
        if ($null -ne $installed) { $manifest.dependencies[$name] = $installed }
    }
    return $manifest
}

function Get-WorkflowDependencyEntry {
    param([string]$Name, [AllowNull()][object]$Plan = $null)
    if ($Name -eq 'workflowPackage') { return Get-DependencyLockEntry -Name $Name }
    if ($null -eq $Plan) { $Plan = Get-WorkflowDependencyPlan }
    $related = @($plan.blocked | Where-Object {
        ($_.component -eq $Name -and $null -eq $_.PSObject.Properties['components']) -or
        @(Get-ConfigValueFromObject $_ 'components' @()) -contains $Name
    })
    if ($related.Count -gt 0) { Assert-WorkflowDependencyPlan -Plan $plan -ReadOnly }
    $entry = Get-ConfigValueFromObject $plan.manifest "dependencies.$Name" $null
    if ($null -eq $entry) { return $null }
    # Preserve the JSON object contract of the former lock getter for callers
    # which inspect PSObject properties, including nested paired records.
    return ($entry | ConvertTo-Json -Depth 100 -Compress | ConvertFrom-Json)
}

function Show-WorkflowDependencySelection {
    $plan = Get-WorkflowDependencyPlan
    $baseline = New-DefaultDependencyLockManifest
    $hotfixes = ConvertTo-Agent1cHashtable $plan.manifest.hotfixes
    foreach ($name in @(Get-WorkflowManagedDependencyLockEntryNames -TemplateManifest $baseline)) {
        $standard = Get-ConfigValueFromObject $baseline "dependencies.$name" $null
        $selected = Get-ConfigValueFromObject $plan.manifest "dependencies.$name" $null
        $selectedFixes = @($hotfixes.Values | Where-Object { $null -ne (Get-ConfigValueFromObject $_ "dependencies.$name" $null) })
        [pscustomobject]@{
            component=$name
            workflow=(Get-WorkflowDependencyIdentity $standard)
            selected=(Get-WorkflowDependencyIdentity $selected)
            hotfix=($selectedFixes.Count -gt 0)
            reason=(@($selectedFixes | ForEach-Object { $_.reason }) -join '; ')
        }
    }
    if (@($plan.blocked).Count -gt 0) { Write-Warning "Dependency selection needs review: run update-workflow -DependencySelectionFile with the decisions for this worktree." }
}

function Get-WorkflowHotfixResource {
    param([string]$Name)
    $plan = Get-WorkflowDependencyPlan
    $hotfixes = ConvertTo-Agent1cHashtable $plan.manifest.hotfixes
    foreach ($id in @($hotfixes.Keys)) {
        if (@($plan.blocked | Where-Object { $_.component -eq $id }).Count -gt 0) { continue }
        $resource = Get-ConfigValueFromObject $hotfixes[$id] "resources.$Name" $null
        if ($null -ne $resource) { return $resource }
    }
    return $null
}

function Get-WorkflowHotfixCatalog {
    param([string]$Family, [AllowNull()][object]$Plan = $null)
    if ($null -eq $Plan) { $Plan = Get-WorkflowDependencyPlan }
    $hotfixes = ConvertTo-Agent1cHashtable -Object $plan.manifest.hotfixes
    foreach ($id in @($hotfixes.Keys)) {
        if (@($plan.blocked | Where-Object { $_.component -eq $id }).Count -gt 0) { continue }
        $definition = Get-ConfigValueFromObject $hotfixes[$id] "compatibility.families.$Family" $null
        if ($null -ne $definition) {
            return [pscustomobject]@{ definition=$definition; text=[string](Get-ConfigValueFromObject $hotfixes[$id] "catalogs.$Family" '') }
        }
    }
    return $null
}
