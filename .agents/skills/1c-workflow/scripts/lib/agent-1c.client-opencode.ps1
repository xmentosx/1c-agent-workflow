# OpenCode project-layer interpretation belongs to clientcfg. Physical ownership
# remains in client-managed.json; effective reads never grant write permission.
function Get-ItlOpenCodeOperationConfigPaths {
    $paths = @(Get-ItlClientMcpConfigPaths -Client opencode)
    $mode = Get-Variable -Name ItlOpenCodeOperationConfigPathsMode -Scope Script -ErrorAction SilentlyContinue
    if ($mode -and $mode.Value -eq 'legacy-root') { return @($paths[0]) }
    return $paths
}

function Get-ItlOpenCodeConfigRelativePath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $paths = @(Get-ItlClientMcpConfigPaths -Client opencode)
    $relative = @('opencode.json', 'opencode.jsonc', '.opencode/opencode.json', '.opencode/opencode.jsonc')
    for ($i = 0; $i -lt $paths.Count; $i++) {
        if ([string]::Equals([IO.Path]::GetFullPath($Path), $paths[$i], [StringComparison]::OrdinalIgnoreCase)) { return $relative[$i] }
    }
    throw "CLIENT_MCP_OWNER_STATE_INVALID: '$Path' is outside the supported OpenCode project config paths. Preserve it and reconcile the original operation."
}

function ConvertTo-ItlOpenCodeSemanticValue {
    param([AllowNull()][object]$Value)
    if ($Value -is [Collections.IDictionary]) {
        $map = [Collections.Hashtable]::new([StringComparer]::Ordinal)
        foreach ($key in $Value.Keys) { $map[$key] = ConvertTo-ItlOpenCodeSemanticValue -Value $Value[$key] }
        return $map
    }
    if ($Value -is [array]) { return ,@($Value | ForEach-Object { ConvertTo-ItlOpenCodeSemanticValue -Value $_ }) }
    return ,$Value
}

function Merge-ItlOpenCodeMcpValue {
    param([AllowNull()][object]$Earlier, [AllowNull()][object]$Later)
    # Qualified native OpenCode merge: recurse object fields, replace arrays and
    # scalars. This projection is never serialized back over a physical layer.
    if ($Earlier -is [Collections.IDictionary] -and $Later -is [Collections.IDictionary]) {
        $result = [Collections.Hashtable]::new([StringComparer]::Ordinal)
        foreach ($key in $Earlier.Keys) { $result[$key] = $Earlier[$key] }
        foreach ($key in $Later.Keys) {
            $result[$key] = if ($result.Contains($key)) { Merge-ItlOpenCodeMcpValue -Earlier $result[$key] -Later $Later[$key] } else { $Later[$key] }
        }
        return $result
    }
    return ,$Later
}

function Get-ItlOpenCodeMcpView {
    $layers = @(); $entries = [Collections.Hashtable]::new([StringComparer]::Ordinal); $provenance = [Collections.Hashtable]::new([StringComparer]::Ordinal)
    foreach ($path in @(Get-ItlOpenCodeOperationConfigPaths)) {
        $state = Get-ItlMcpFileState -Path $path
        $text = if ($state -eq 'absent') { '{}' + [Environment]::NewLine } else {
            # Keep the BOM as a text character so atomic UTF-8 output round-trips it.
            [Text.UTF8Encoding]::new($false, $true).GetString([IO.File]::ReadAllBytes($path))
        }
        if ($state -ne 'absent' -and (Get-ItlMcpTextState -Text $text) -cne $state) {
            throw "CLIENT_MCP_FINAL_SET_CHANGED: '$path' changed while reading. Preserve it and repeat the original reconciliation."
        }
        $document = Read-ItlJsoncDocument -Text $text
        if ($document.Root.Kind -ne 'object') { throw "CLIENT_MCP_CONTAINER_INVALID: '$path' must contain a project config object. Preserve it and reconcile before retrying." }
        $config = ConvertTo-ItlOpenCodeSemanticValue -Value $document.Value
        $container = [Collections.Hashtable]::new([StringComparer]::Ordinal)
        if ($config.Contains('mcp')) {
            if ($config['mcp'] -isnot [Collections.IDictionary]) { throw "CLIENT_MCP_CONTAINER_INVALID: '$path' has a non-object mcp; preserve it and reconcile before retrying." }
            $container = $config['mcp']
        }
        foreach ($name in @($container.Keys)) {
            $entries[$name] = if ($entries.Contains($name)) { Merge-ItlOpenCodeMcpValue -Earlier $entries[$name] -Later $container[$name] } else { $container[$name] }
            if (-not $provenance.Contains($name)) { $provenance[$name] = @() }
            $provenance[$name] = @($provenance[$name]) + @([pscustomobject]@{path=$path; relativePath=(Get-ItlOpenCodeConfigRelativePath -Path $path); value=$container[$name]})
        }
        $layers += [pscustomobject]@{path=$path;relativePath=(Get-ItlOpenCodeConfigRelativePath -Path $path);state=$state;text=$text;entries=$container}
    }
    return [pscustomobject]@{entries=$entries;provenance=$provenance;layers=$layers}
}

function Get-ItlOpenCodeMcpBindings {
    param([Parameter(Mandatory = $true)][object]$State, [string]$OwnerKey = '')
    $owners = ConvertTo-Vibecoding1cMcpHashtable -Object (Get-Vibecoding1cMcpObjectValue -Object $State -Name owners -Default ([ordered]@{}))
    $pathOwners = ConvertTo-Vibecoding1cMcpHashtable -Object (Get-Vibecoding1cMcpObjectValue -Object $State -Name pathOwners -Default ([ordered]@{}))
    $keys = @(@($owners.Keys) + @($pathOwners.Keys) | Where-Object { $_ -like 'opencode/*' -and (-not $OwnerKey -or $_ -ceq $OwnerKey) } | Select-Object -Unique)
    foreach ($key in $keys) {
        # Legacy names-only ownership always means root JSON, never all layers.
        foreach ($name in @($owners[$key] | Where-Object { $_ } | Select-Object -Unique)) {
            [pscustomobject]@{ownerKey=[string]$key;relativePath='opencode.json';name=[string]$name}
        }
        if (-not $pathOwners.Contains($key)) { continue }
        $paths = ConvertTo-Vibecoding1cMcpHashtable -Object $pathOwners[$key]
        foreach ($relative in $paths.Keys) {
            if ([string]$relative -cnotin @('opencode.jsonc','.opencode/opencode.json','.opencode/opencode.jsonc')) {
                throw "CLIENT_MCP_OWNER_STATE_INVALID: '$relative' is not a canonical nested OpenCode ownership path. Preserve the state and reconcile its original owner."
            }
            foreach ($name in @($paths[$relative] | Where-Object { $_ } | Select-Object -Unique)) {
                [pscustomobject]@{ownerKey=[string]$key;relativePath=[string]$relative;name=[string]$name}
            }
        }
    }
}

function Set-ItlOpenCodeMcpOwnerBindings {
    param([object]$State, [string]$OwnerKey, [object[]]$Bindings)
    if (-not $State.Contains('owners')) { $State['owners'] = [ordered]@{} }
    if (-not $State.Contains('pathOwners')) { $State['pathOwners'] = [ordered]@{} }
    $owners = ConvertTo-Vibecoding1cMcpHashtable -Object $State['owners']
    $paths = [ordered]@{}
    $owners[$OwnerKey] = @($Bindings | Where-Object relativePath -EQ 'opencode.json' | ForEach-Object { $_.name } | Select-Object -Unique)
    foreach ($binding in @($Bindings | Where-Object relativePath -NE 'opencode.json')) {
        if (-not $paths.Contains($binding.relativePath)) { $paths[$binding.relativePath] = @() }
        $paths[$binding.relativePath] = @(@($paths[$binding.relativePath]) + @($binding.name) | Select-Object -Unique)
    }
    $pathOwners = ConvertTo-Vibecoding1cMcpHashtable -Object $State['pathOwners']
    if ($paths.Count) { $pathOwners[$OwnerKey] = $paths } else { $pathOwners.Remove($OwnerKey) }
    $State['owners'] = $owners; $State['pathOwners'] = $pathOwners
}

function Write-ItlOpenCodeMcpEndpoints {
    param([object[]]$Endpoints, [string]$Owner, [string[]]$PreserveOwnedKeys = @(), [string[]]$FinalSetOwnerKeys = @(), [AllowNull()][object]$ExpectedInputStates = $null, [string]$ExpectedOwnerState = '', [object[]]$PreparedClaims = @(), [object[]]$FinalSetClaims = @(), [switch]$PlanOnly, [switch]$ReturnReceipt, [switch]$RemoveLegacyManagedEntries)
    if ($RemoveLegacyManagedEntries -and ($Owner -cne 'branch-runtime' -or @($Endpoints).Count)) {
        throw 'CLIENT_MCP_LEGACY_CLEANUP_INVALID: legacy marker cleanup requires the original empty branch-runtime reconciliation; repeat Remove-ItlLegacyBranchMcpEntries.'
    }
    $view = Get-ItlOpenCodeMcpView
    $ownerPath = Get-ItlManagedMcpStatePath
    $beforeOwnerState = Get-ItlMcpFileState -Path $ownerPath
    $state = Read-ItlManagedMcpState
    if ((Get-ItlMcpFileState -Path $ownerPath) -cne $beforeOwnerState) { throw 'CLIENT_MCP_FINAL_SET_CHANGED: ownership changed while parsing its captured state. Preserve it and repeat the original reconciliation.' }
    if ($ExpectedOwnerState -and $beforeOwnerState -cne $ExpectedOwnerState) { throw 'CLIENT_MCP_FINAL_SET_CHANGED: ownership changed after final-set planning. Preserve it and repeat the original reconciliation.' }
    $stateKey = "opencode/$Owner"
    $allBindings = @(Get-ItlOpenCodeMcpBindings -State $state)
    $bindings = @($allBindings | Where-Object { $_.ownerKey -ceq $stateKey -and $_.relativePath -in @($view.layers.relativePath) })
    $nextBindings = @($bindings | Where-Object { $_.name -in $PreserveOwnedKeys })
    $claims = @(); $writes = [ordered]@{}; $deferredOwnerRelease = $false
    foreach ($layer in $view.layers) { $writes[$layer.relativePath] = $layer.text }
    $existingLayers = @($view.layers | Where-Object state -NE 'absent')
    $defaultLayer = if ($existingLayers.Count) { $existingLayers[-1] } else { $view.layers[0] }
    foreach ($endpoint in $Endpoints) {
        $name = [string]$endpoint.name
        $candidates = @($bindings | Where-Object { (ConvertTo-ItlClientMcpKey -Name $_.name -Client opencode) -ceq $name })
        if (-not $candidates.Count) { $candidates = @($allBindings | Where-Object { (ConvertTo-ItlClientMcpKey -Name $_.name -Client opencode) -ceq $name -and $_.relativePath -in @($view.layers.relativePath) }) }
        $candidatePaths = @($candidates | ForEach-Object { $_.relativePath } | Select-Object -Unique)
        $candidateNames = @($candidates | ForEach-Object { $_.name } | Select-Object -Unique)
        $prepared = @($PreparedClaims | Where-Object name -CEQ $name)
        if ($prepared.Count -gt 1) { throw 'CLIENT_MCP_FINAL_SET_INVALID: several physical preflight claims for one endpoint; rebuild the original final set.' }
        if ($candidateNames.Count -gt 1) { throw "CLIENT_MCP_OWNER_CONFLICT: several proved keys map to '$name'; preserve their policy and reconcile the original owner before retrying." }
        if ($candidatePaths.Count -gt 1) { throw "CLIENT_MCP_OWNER_CONFLICT: '$name' has several physical owners. Preserve the files and reconcile the original owner before retrying." }
        $layer = if ($candidatePaths.Count) { @($view.layers | Where-Object relativePath -CEQ $candidatePaths[0])[0] } else { $defaultLayer }
        if ($prepared.Count) {
            $admittedRelative = Get-ItlOpenCodeConfigRelativePath -Path $prepared[0].path
            if ($candidatePaths.Count -and $candidatePaths[0] -cne $admittedRelative) { throw 'CLIENT_MCP_FINAL_SET_CHANGED: endpoint physical ownership differs from its admitted plan; preserve it and repeat the original reconciliation.' }
            $layer = @($view.layers | Where-Object relativePath -CEQ $admittedRelative)[0]
        }
        $previousName = if ($layer.entries.Contains($name) -or -not $candidateNames.Count) { $name } else { [string]$candidateNames[0] }
        $contributions = @(@($view.provenance[$name]) + @($(if ($previousName -cne $name) { $view.provenance[$previousName] })) | Where-Object { $_ })
        foreach ($contribution in $contributions) {
            if ($null -eq $contribution) { continue }
            $proof = @($allBindings | Where-Object { $_.relativePath -ceq $contribution.relativePath -and $_.name -in @($name,$previousName) })
            if (-not $proof.Count -or $contribution.relativePath -cne $layer.relativePath) {
                throw "CLIENT_MCP_USER_COLLISION: '$name' has an unowned or overriding contribution in '$($contribution.relativePath)'. Preserve all four configs and resolve that key explicitly, then repeat the original reconciliation. No MCP config or ownership was written."
            }
        }
        $entry = ConvertTo-ItlClientMcpEntry -Endpoint $endpoint -Owner $Owner -Client opencode
        if ($prepared.Count) { $entry = ConvertTo-Vibecoding1cMcpHashtable -Object $prepared[0].entry }
        $previous = if ($layer.entries.Contains($previousName)) { ConvertTo-Vibecoding1cMcpHashtable -Object $layer.entries[$previousName] } else { [ordered]@{} }
        foreach ($policy in @('enabled','disabled')) { if ($previous.Contains($policy)) { $entry[$policy] = $previous[$policy] } }
        foreach ($key in $previous.Keys) {
            if (-not $entry.Contains($key) -and $key -notin @('url','httpUrl','command','args','env','environment','transport','type','timeout','lifecycle','managedBy','family')) { $entry[$key] = $previous[$key] }
        }
        $shared = @($allBindings | Where-Object { $_.relativePath -ceq $layer.relativePath -and $_.name -ceq $previousName -and $_.ownerKey -cne $stateKey -and $_.ownerKey -notin $FinalSetOwnerKeys })
        if ($shared.Count) {
            if ($previousName -cne $name) { throw "CLIENT_MCP_OWNER_CONFLICT: shared alias '$previousName' cannot be renamed by one owner. Reconcile the complete owner cohort before retrying." }
            $desired = [ordered]@{}; $desired[$name] = $entry
            if ((Get-ItlMcpOwnedSemanticSignature -Container $desired -Names @($name)) -cne (Get-ItlMcpOwnedSemanticSignature -Container $layer.entries -Names @($name))) {
                throw "CLIENT_MCP_OWNER_CONFLICT: '$name' in '$($layer.relativePath)' has another owner with different settings. Preserve it and reconcile the original owner."
            }
        }
        $text = [string]$writes[$layer.relativePath]
        if ($previousName -cne $name -and $layer.entries.Contains($previousName)) {
            # Rename only the quoted key span; retain the original object and its
            # inline user comments before editing the authorized transport fields.
            $document = Read-ItlJsoncDocument -Text $text
            $mcpNodes = @($document.Root.Members | Where-Object Name -CEQ 'mcp')
            if ($mcpNodes.Count -ne 1) { throw 'CLIENT_JSONC_AMBIGUOUS_PROPERTY: mcp has ambiguous physical ownership; preserve the file and reconcile it.' }
            $members = @($mcpNodes[0].Value.Members | Where-Object Name -CEQ $previousName)
            if ($members.Count -ne 1) { throw 'CLIENT_JSONC_AMBIGUOUS_PROPERTY: owned key is duplicated; preserve the file and reconcile it.' }
            $member = $members[0]
            $quotedName = ConvertTo-Json -InputObject $name -Compress
            $text = $text.Remove($member.Start,$member.NameEnd-$member.Start).Insert($member.Start,$quotedName)
        }
        if ($layer.entries.Contains($previousName)) {
            foreach ($key in @($previous.Keys | Where-Object { $_ -in @('url','httpUrl','command','args','env','environment','transport','type','timeout','lifecycle','managedBy','family') -and -not $entry.Contains($_) })) {
                $text = Remove-ItlJsoncObjectProperty -Text $text -PropertyPath @('mcp',$name,[string]$key)
            }
            foreach ($key in $entry.Keys) { $text = Set-ItlJsoncObjectProperty -Text $text -PropertyPath @('mcp',$name,[string]$key) -Value $entry[$key] }
        } else { $text = Set-ItlJsoncObjectProperty -Text $text -PropertyPath @('mcp',$name) -Value $entry }
        $writes[$layer.relativePath] = $text
        $nextBindings += [pscustomobject]@{ownerKey=$stateKey;relativePath=$layer.relativePath;name=$name}
        $claims += [pscustomobject]@{path=$layer.path;name=$name;entry=$entry}
    }
    # Old explicit markers prove only deletion at the captured physical path.
    # They are never added to current or next persisted ownership bindings.
    $legacyRemovals = @()
    if ($RemoveLegacyManagedEntries) {
        foreach ($layer in $view.layers) {
            foreach ($name in $layer.entries.Keys) {
                $managedBy = [string](Get-Vibecoding1cMcpObjectValue -Object $layer.entries[$name] -Name managedBy -Default '')
                if ($managedBy -in @('itl-branch-mcp','vanessa-mcp','vanessa-ui-mcp') -and
                    -not @($bindings | Where-Object { $_.relativePath -ceq $layer.relativePath -and $_.name -ceq $name }).Count) {
                    $legacyRemovals += [pscustomobject]@{ownerKey=$stateKey;relativePath=$layer.relativePath;name=[string]$name}
                }
            }
        }
    }
    foreach ($binding in @($bindings) + @($legacyRemovals)) {
        if (@($nextBindings | Where-Object { $_.relativePath -ceq $binding.relativePath -and $_.name -ceq $binding.name }).Count) { continue }
        $physicalPath = Join-Path $script:ProjectRoot $binding.relativePath
        $receivers = @($FinalSetClaims | Where-Object { $_.ownerKey -cne $stateKey -and $_.path -ieq $physicalPath -and $_.name -ceq (ConvertTo-ItlClientMcpKey -Name $binding.name -Client opencode) })
        if ($receivers.Count) {
            $confirmed = @($allBindings | Where-Object {
                $proof = $_
                @($receivers | Where-Object { $_.ownerKey -ceq $proof.ownerKey -and $_.name -ceq $proof.name -and $proof.relativePath -ceq $binding.relativePath }).Count -gt 0
            })
            if (-not $confirmed.Count) {
                # A pending receiver can preserve the old marker contribution,
                # but cannot turn this deletion-only proof into durable ownership.
                if (-not @($legacyRemovals | Where-Object { $_.relativePath -ceq $binding.relativePath -and $_.name -ceq $binding.name }).Count) { $nextBindings += $binding }
                $deferredOwnerRelease = $true
                continue
            }
        }
        if (@($allBindings | Where-Object { $_.ownerKey -cne $stateKey -and $_.relativePath -ceq $binding.relativePath -and $_.name -ceq $binding.name }).Count) { continue }
        $writes[$binding.relativePath] = Remove-ItlJsoncObjectProperty -Text ([string]$writes[$binding.relativePath]) -PropertyPath @('mcp',[string]$binding.name)
    }
    foreach ($binding in @($nextBindings | Where-Object { $_.name -in $PreserveOwnedKeys -and $_.name -notin @($Endpoints | ForEach-Object { $_.name }) })) {
        $layer = @($view.layers | Where-Object relativePath -CEQ $binding.relativePath)[0]
        if ($layer.entries.Contains($binding.name)) { $claims += [pscustomobject]@{path=$layer.path;name=$binding.name;entry=$layer.entries[$binding.name]} }
    }
    # A legacy recovery executor cannot drop future physical claims outside its
    # recorded root-only scope. It also cannot write those future project layers.
    $nextBindings += @($allBindings | Where-Object { $_.ownerKey -ceq $stateKey -and $_.relativePath -notin @($view.layers.relativePath) })
    $inputStates = [ordered]@{}
    foreach ($path in @(Get-ItlClientMcpConfigPaths -Client opencode)) {
        $layer = @($view.layers | Where-Object path -EQ $path)
        $inputStates[$path] = if ($layer.Count) { $layer[0].state } else { Get-ItlMcpFileState -Path $path }
        if ($null -ne $ExpectedInputStates -and ($path -notin @($ExpectedInputStates.Keys) -or $ExpectedInputStates[$path] -cne $inputStates[$path])) { throw "CLIENT_MCP_FINAL_SET_CHANGED: '$path' changed after final-set planning. Preserve it and repeat the original reconciliation." }
    }
    $fileChanges = @()
    foreach ($layer in $view.layers) {
        if ([string]$writes[$layer.relativePath] -ceq $layer.text) { continue }
        Assert-ItlClientConfigWritable -Client opencode -Path $layer.path
        $fileChanges += [pscustomobject]@{path=$layer.path;relativePath=$layer.relativePath;text=[string]$writes[$layer.relativePath];fileState=(Get-ItlMcpTextState -Text ([string]$writes[$layer.relativePath]))}
    }
    $planEntries = [ordered]@{}
    foreach ($claim in $claims) { $planEntries[$claim.name] = $claim.entry }
    $primary = if ($fileChanges.Count) { $fileChanges[0].path } else { $defaultLayer.path }
    $plan = [pscustomobject]@{path=$primary;ownerKey=$stateKey;entries=$planEntries;claims=$claims;inputStates=$inputStates;fileChanges=$fileChanges;beforeFileState=$inputStates[$primary];beforeOwnerState=$beforeOwnerState}
    if ($PlanOnly) { return $plan }
    foreach ($path in $inputStates.Keys) {
        if ((Get-ItlMcpFileState -Path $path) -cne $inputStates[$path]) { throw "CLIENT_MCP_FINAL_SET_CHANGED: '$path' changed before the first write. Preserve it and repeat the original reconciliation." }
    }
    if ((Get-ItlMcpFileState -Path $ownerPath) -cne $beforeOwnerState) { throw 'CLIENT_MCP_FINAL_SET_CHANGED: ownership changed before the first write. Preserve it and repeat the original reconciliation.' }
    foreach ($change in $fileChanges) {
        foreach ($path in $inputStates.Keys) {
            if ((Get-ItlMcpFileState -Path $path) -cne $inputStates[$path]) { throw "CLIENT_MCP_FINAL_SET_CHANGED: '$path' changed before its write; completed writes remain owned. Preserve current files and repeat the original owner recovery." }
        }
        if ((Get-ItlMcpFileState -Path $ownerPath) -cne $beforeOwnerState) { throw 'CLIENT_MCP_FINAL_SET_CHANGED: ownership changed during write; preserve current files and repeat the original owner recovery.' }
        Write-Utf8TextAtomic -Path $change.path -Value $change.text
        if ((Get-ItlMcpFileState -Path $change.path) -cne $change.fileState) { throw 'CLIENT_MCP_FINAL_SET_WRITE_UNCONFIRMED: preserve the before/current files through the original owner recovery.' }
        $inputStates[$change.path] = $change.fileState
        # Confirm physical ownership after each file so a later interrupted write
        # remains recoverable by the same owner, not a newly invented transaction.
        $completedBindings = @($nextBindings | Where-Object { $_.relativePath -ceq $change.relativePath }) + @(Get-ItlOpenCodeMcpBindings -State $state -OwnerKey $stateKey | Where-Object { $_.relativePath -cne $change.relativePath })
        Set-ItlOpenCodeMcpOwnerBindings -State $state -OwnerKey $stateKey -Bindings $completedBindings
        Write-ItlManagedMcpState -State $state
        $beforeOwnerState = Get-ItlMcpTextState -Text (($state | ConvertTo-Json -Depth 12) + [Environment]::NewLine)
        if ((Get-ItlMcpFileState -Path $ownerPath) -cne $beforeOwnerState) { throw 'CLIENT_MCP_FINAL_SET_WRITE_UNCONFIRMED: physical ownership write differs; preserve current files through the original owner recovery.' }
        Register-ItlClientMcpSemanticChange -Client opencode -Owner $Owner -Path $change.path
    }
    foreach ($path in $inputStates.Keys) {
        if ((Get-ItlMcpFileState -Path $path) -cne $inputStates[$path]) { throw "CLIENT_MCP_FINAL_SET_CHANGED: '$path' changed before ownership confirmation; preserve current files and repeat the original owner recovery." }
    }
    if ((Get-ItlMcpFileState -Path $ownerPath) -cne $beforeOwnerState) { throw 'CLIENT_MCP_FINAL_SET_CHANGED: ownership changed before confirmation; preserve it and repeat the original owner recovery.' }
    Set-ItlOpenCodeMcpOwnerBindings -State $state -OwnerKey $stateKey -Bindings $nextBindings
    Write-ItlManagedMcpState -State $state
    $expectedOwnerState = Get-ItlMcpTextState -Text (($state | ConvertTo-Json -Depth 12) + [Environment]::NewLine)
    if ($ReturnReceipt) { return [pscustomobject]@{path=$primary;fileState=$inputStates[$primary];fileStates=$inputStates;ownerState=$expectedOwnerState;deferredOwnerRelease=$deferredOwnerRelease} }
    return $primary
}
