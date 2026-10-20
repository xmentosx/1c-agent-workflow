# The existing registry operation owns this pinned view. No background worker.
function Get-ItlProductProjectBinding {
    $binding=Get-ConfigValue -Path 'productProject' -Default $null
    if($null -eq $binding){return $null}
    Assert-ItlProductProjectBindingValue $binding
    return ConvertTo-ItlCatalogCanonicalValue $binding
}

function Assert-ItlProductProjectBindingValue {
    param([object]$Binding)
    Assert-ItlCatalogBusinessData $Binding 'productProject'
    if((Get-ItlCatalogField $binding 'schemaVersion') -ne 1 -or (Get-ItlCatalogField $binding 'requiredCapability') -cne 'product-project-registry-v1'){
        throw 'CATALOG_BINDING_CAPABILITY: this helper cannot use the binding schema/capability; use a compatible workflow or its owned compatibility restore before downgrade.'
    }
    foreach($field in @('projectId','productId')){if([string](Get-ItlCatalogField $binding $field '') -cnotmatch '^[a-z0-9][a-z0-9._-]*$'){throw "CATALOG_BINDING_INVALID: $field is required; choose the project explicitly without guessing from a directory or MCP URL."}}
    if((Get-ItlCatalogField $binding 'profileId') -and [string]$binding.profileId -cnotmatch '^[a-z0-9][a-z0-9._-]*$'){throw 'CATALOG_BINDING_INVALID: profileId must be a stable catalog ID.'}
    foreach($key in @(Get-ItlCatalogKeys $binding)){if($key -cnotin @('schemaVersion','requiredCapability','projectId','productId','profileId')){throw "CATALOG_BINDING_INVALID: unsupported binding field '$key'; use a compatible helper before changing the tracked schema."}}
}

function Read-ItlProductProjectConfig {
    $path=[IO.Path]::GetFullPath($script:ConfigPath)
    $prefix=[IO.Path]::GetFullPath($script:ProjectRoot).TrimEnd('\')+'\'
    if(-not $path.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'CATALOG_BINDING_PATH: the selected common project config must be inside this local project; preserve external config and use an in-project configuration for association.'}
    if(-not (Test-Path -LiteralPath $path -PathType Leaf)){return [ordered]@{}}
    return ConvertTo-ItlCatalogCanonicalValue (Read-Utf8Text $path|ConvertFrom-Json -ErrorAction Stop)
}

function Set-ItlProductProjectBinding {
    param([AllowNull()][object]$Binding,[AllowNull()][object]$Expected,[object]$RestoreFile=$null,[scriptblock]$OnBeforeWrite)
    $before=Get-ItlMcpFileState $script:ConfigPath
    $config=Read-ItlProductProjectConfig
    if((Get-ItlCatalogHash (Get-ItlCatalogField $config 'productProject')) -cne (Get-ItlCatalogHash $Expected)){throw 'CATALOG_BINDING_CONFLICT: the tracked association changed after preview; preserve it and resolve the pinned operation before resume/restore.'}
    if((Get-ItlCatalogHash (Get-ItlCatalogField $config 'productProject')) -ceq (Get-ItlCatalogHash $Binding)){return}
    if($null -eq $Binding){$config.Remove('productProject')}else{
        Assert-ItlProductProjectBindingValue $Binding
        $config['productProject']=$Binding
    }
    $text=($config|ConvertTo-Json -Depth 40)+[Environment]::NewLine
    $remove=$false
    # Exact rollback is safe only while the whole file still matches our write.
    # Otherwise retain later unrelated settings through the normal property merge.
    if($RestoreFile -and $before -ceq $RestoreFile.afterState){
        $remove=$RestoreFile.beforeState -ceq 'absent'
        $text=[string]$RestoreFile.beforeText
        $original=if($remove){@{}}else{$text.TrimStart([char]0xfeff)|ConvertFrom-Json -ErrorAction Stop}
        if((-not $remove -and (Get-ItlMcpTextState $text) -cne $RestoreFile.beforeState) -or (Get-ItlCatalogHash (Get-ItlCatalogField $original 'productProject')) -cne (Get-ItlCatalogHash $Binding)){throw 'CATALOG_BINDING_CONFLICT: saved descriptor does not match the pinned restore intent; retain the operation and resolve its receipt.'}
    }
    if($OnBeforeWrite){
        # Decode bytes directly to retain a possible UTF-8 BOM in the saved text.
        $beforeText=if($before -eq 'absent'){$null}else{(Get-Utf8Encoding).GetString([IO.File]::ReadAllBytes($script:ConfigPath))}
        & $OnBeforeWrite ([ordered]@{beforeState=$before;beforeText=$beforeText;afterState=$(if($remove){'absent'}else{Get-ItlMcpTextState $text})})
    }
    if((Get-ItlMcpFileState $script:ConfigPath) -cne $before){throw 'CATALOG_BINDING_CONFLICT: project config changed while composing the binding; preserve that edit and repeat the original recovery.'}
    if($remove){Remove-Item -LiteralPath $script:ConfigPath -ErrorAction Stop}
    elseif((Get-ItlMcpTextState $text) -cne $before){Write-Utf8TextAtomic $script:ConfigPath $text}
    Read-ProjectConfig
}

function Read-ItlProductProjectSetting {
    param([ValidateSet('binding','selection')][string]$Kind)
    if($Kind -eq 'binding'){return Get-ItlCatalogField (Read-ItlProductProjectConfig) 'productProject'}
    return Get-ItlCatalogField (Read-Vibecoding1cMcpSelection) 'productProject'
}

function Set-ItlProductProjectSetting {
    param([ValidateSet('binding','selection')][string]$Kind,[object]$Value,[object]$Expected,[object]$RestoreFile=$null,[scriptblock]$OnBeforeWrite)
    if($Kind -eq 'binding'){Set-ItlProductProjectBinding -Binding $Value -Expected $Expected -RestoreFile $RestoreFile -OnBeforeWrite $OnBeforeWrite;return}
    $path=Get-Vibecoding1cMcpSelectionPath;$before=Get-ItlMcpFileState $path
    $selection=ConvertTo-ItlCatalogCanonicalValue (Read-Vibecoding1cMcpJsonFile -Path $path -Default @{})
    # Preserve the historical native intent of a pre-existing empty file;
    # a new catalog-only file never persists reader-inferred MCP defaults.
    if($before -ne 'absent' -and $selection.Count -eq 0){$selection=ConvertTo-ItlCatalogCanonicalValue (Read-Vibecoding1cMcpSelection)}
    $current=Get-ItlCatalogField $selection 'productProject'
    if((Get-ItlCatalogHash $current) -cne (Get-ItlCatalogHash $Expected)){throw 'CATALOG_SELECTION_CONFLICT: local catalog preferences changed after preview; preserve them and resolve the pinned operation.'}
    if((Get-ItlCatalogHash $current) -ceq (Get-ItlCatalogHash $Value)){return}
    if($null -eq $Value){$selection.Remove('productProject')}else{$selection['productProject']=$Value}
    if((Get-ItlMcpFileState $path) -cne $before){throw 'CATALOG_SELECTION_CONFLICT: selection changed during composition; no preferences were written.'}
    if($selection.Count){Write-Vibecoding1cMcpJsonFile -Path $path -Value $selection}
    else{Remove-Item -LiteralPath $path -ErrorAction Stop}
}

function Get-ItlProductProjectStartupDisposition {
    param([string]$RequestedAction,[string]$CatalogMode='', [string]$BrokerOperation='', [string]$WorkflowRecovery='')
    if($BrokerOperation){return 'inherited-broker'}
    if($CatalogMode -or $WorkflowRecovery){return 'explicit-recovery'}
    if($RequestedAction -eq 'init-project'){return 'bootstrap'}
    # These runtime owners intentionally do not acquire a new lifecycle guard.
    if($RequestedAction -in @('start-vanessa-profile','stop-vanessa-profile')){return 'inherited-runtime'}
    if(-not (Test-Agent1cActionRequiresLifecycleLock $RequestedAction)){return 'diagnostic'}
    return 'project-operation'
}

function Read-ItlProductProjectSnapshot {
    $operation=Get-Variable ItlMcpRegistryOperation -Scope Script -ErrorAction SilentlyContinue
    if(-not $operation){throw 'CATALOG_OPERATION_CONTEXT_REQUIRED: enter the existing registry operation before reading the catalog.'}
    $state=$operation.Value
    if($state.Contains('catalogAttempted') -and $state.catalogAttempted){
        if($state.catalogError){throw $state.catalogError}
        return $state.catalogSnapshot
    }
    $state['catalogAttempted']=$true;$state['catalogSnapshot']=$null;$state['catalogError']=$null
    $state.attempted=$true
    $refreshError=$null
    try{$null=Update-Vibecoding1cMcpRegistryCheckout -DeadlineUtc ([DateTime]::UtcNow.AddSeconds(10))}catch{$refreshError=$_.Exception}
    try{
        $commit='HEAD'
        if($refreshError){
            $reference=Get-ItlCatalogField (Read-ItlProductProjectSetting selection) 'catalogRevision'
            if($reference -cmatch '^(?:[a-f0-9]{40}|[a-f0-9]{64})$'){$commit=$reference}
        }
        $snapshot=Read-ItlProductCatalogSnapshot -RepositoryRoot (Get-Vibecoding1cMcpRegistryRoot) -Commit $commit
        $snapshot|Add-Member -NotePropertyName stale -NotePropertyValue ([bool]$refreshError) -Force
        $state.catalogSnapshot=$snapshot;$state.snapshot=$snapshot.registry
        if($refreshError){$state.error=$refreshError}
        return $snapshot
    }catch{
        $state.catalogError=[InvalidOperationException]::new('CATALOG_REFRESH_UNAVAILABLE: no validated new snapshot; use the previous applied context with a freshness warning or explicit setup when no valid baseline exists.',$_.Exception)
        $state.error=$state.catalogError
        throw $state.catalogError
    }
}

function Get-ItlProductProjectOperationContext {
    $operation=Get-Variable ItlMcpRegistryOperation -Scope Script -ErrorAction SilentlyContinue
    if(-not $operation){return $null}
    if(-not $operation.Value.Contains('productContexts')){$operation.Value['productContexts']=@{}}
    $key=[IO.Path]::GetFullPath($script:ProjectRoot).TrimEnd('\').ToLowerInvariant()
    if(-not $operation.Value.productContexts.ContainsKey($key) -and (Get-ItlCatalogField $operation.Value 'catalogSnapshot')){
        $binding=Get-ItlProductProjectBinding
        if($binding){
            $preferences=ConvertTo-Vibecoding1cMcpHashtable (Read-ItlProductProjectSetting selection)
            $effective=Get-ItlProductProjectEffectiveSnapshot $operation.Value.catalogSnapshot $preferences
            $context=Resolve-ItlProductProjectRuntimeContext -Snapshot $effective.snapshot -Binding $binding -Overrides (Get-ItlCatalogField $preferences 'overrides' @{}) -Conditions (ConvertTo-Agent1cHashtable (Get-ItlCatalogField $preferences 'conditionValues' @{})) -ProductVersion (Get-ItlCatalogField $preferences 'productVersion' '')
            $context['catalogPublication']=$effective.publication
            $context['registryMetadata']=$operation.Value.snapshot
            $operation.Value.productContexts[$key]=$context
        }
    }
    return $operation.Value.productContexts[$key]
}

function Set-ItlProductProjectOperationContext {
    param([object]$Context)
    $operation=Get-Variable ItlMcpRegistryOperation -Scope Script -ErrorAction SilentlyContinue
    if(-not $operation){throw 'CATALOG_OPERATION_CONTEXT_REQUIRED: use the existing registry operation for a pinned context.'}
    if(-not $operation.Value.Contains('productContexts')){$operation.Value['productContexts']=@{}}
    $key=[IO.Path]::GetFullPath($script:ProjectRoot).TrimEnd('\').ToLowerInvariant()
    $operation.Value.productContexts[$key]=$Context
}

function Resolve-ItlProductProjectEndpointIntent {
    param([object]$Source,[object]$Registry)
    $id=[string]$Source.endpoint.serverId
    $scope=if($Source.role -in @('code','graph')){'project'}else{'global'}
    $selection=@{servers=@(@{id=$id;hostId=$Source.endpoint.hostId;configId=(Get-ItlCatalogField $Source.endpoint 'configId' '')})}
    $server=@{id=$id;scope=$scope}
    $candidates=@(Get-Vibecoding1cMcpRemoteEndpointCandidates -Server $server -Selection $selection -IgnoreSelectedHost -ConfigId (Get-ItlCatalogField $Source.endpoint 'configId' '') -Registry $Registry | Where-Object {$_.hostId -ceq $Source.endpoint.hostId})
    if($candidates.Count -ne 1){throw "CATALOG_SOURCE_BINDING_INVALID: source '$($Source.sourceId)' does not have one exact host/server/config binding; retain the applied context and inspect registry metadata."}
    $candidate=$candidates[0]
    $url=[string](Get-ItlCatalogField $candidate 'url' '')
    $viewId=[string](Get-ItlCatalogField $Source.binding 'viewId' '')
    if((Get-ItlCatalogField $Source.binding 'mode') -eq 'view'){
        if($Source.role -ne 'productDocs' -or -not $viewId){throw 'CATALOG_SOURCE_BINDING_INVALID: a docs view requires its explicit view ID.'}
        $views=@((Get-ItlCatalogField $candidate 'viewBindings' @())|Where-Object {(Get-ItlCatalogField $_ 'viewId') -ceq $viewId})
        if($views.Count -ne 1 -or (Get-ItlCatalogField $views[0] 'capability') -cne 'product-docs-view-v1'){throw "CATALOG_SOURCE_VIEW_UNAVAILABLE: '$viewId' is not published by this exact endpoint; an unscoped URL cannot replace it."}
        $url=[string]$views[0].url
        $parentAddress=[Uri]$candidate.url;$viewAddress=[Uri]$url
        if($parentAddress.Scheme -cne $viewAddress.Scheme -or $parentAddress.Authority -cne $viewAddress.Authority){throw 'CATALOG_SOURCE_VIEW_UNAVAILABLE: the published view changes this source public origin.'}
    }
    $address=$null
    if(-not [Uri]::TryCreate($url,[UriKind]::Absolute,[ref]$address) -or $address.Scheme -notin @('http','https') -or $address.UserInfo -or $address.Fragment){throw 'CATALOG_SOURCE_URL_INVALID: the registry must publish an HTTP MCP URL without embedded credentials or fragments.'}
    return [ordered]@{sourceId=$Source.sourceId;role=$Source.role;hostId=$Source.endpoint.hostId;serverId=$id;configId=(Get-ItlCatalogField $Source.endpoint 'configId');namespace=(Get-ItlCatalogField $Source 'namespace');viewId=$viewId;url=$url;scope='whole-source';readiness='unverified';declaredVersion=(Get-ItlCatalogField $candidate 'configurationVersion');sourceFingerprint=(Get-ItlCatalogField $candidate 'sourceFingerprint')}
}

function Resolve-ItlProductProjectRuntimeContext {
    param([object]$Snapshot,[object]$Binding,[object]$Overrides=@{},[hashtable]$Conditions=@{},[string]$ProductVersion='')
    $context=ConvertTo-ItlCatalogCanonicalValue (Resolve-ItlProductContext -Snapshot $Snapshot -ProjectId $Binding.projectId -ProfileId (Get-ItlCatalogField $Binding 'profileId' '') -Overrides $Overrides -Conditions $Conditions -ProductVersion $ProductVersion)
    if($context.productId -cne $Binding.productId){throw 'CATALOG_PRODUCT_CHANGED: registry and tracked base product disagree; automatic update cannot switch the product or infobase.'}
    $products=@($Snapshot.catalog.products|Where-Object {$_.productId -ceq $context.productId})
    $projects=@($Snapshot.catalog.projects|Where-Object {$_.projectId -ceq $context.projectId})
    $context['productName']=$products[0].name;$context['projectName']=$projects[0].name
    $context['baseConfigurationVersion']=Get-ItlCatalogField $products[0] 'baseConfigurationVersion'
    $context['endpointIntents']=[ordered]@{}
    foreach($role in @('code','graph','productDocs')){
        if($context.roles[$role].resolution -eq 'resolved'){$context.endpointIntents[$role]=Resolve-ItlProductProjectEndpointIntent $context.roles[$role].source $Snapshot.registry}
    }
    return $context
}

function Get-ItlProductProjectEffectiveSnapshot {
    param([object]$Snapshot,[object]$Preferences)
    $effective=$Snapshot;$overlays=@()
    foreach($pending in @(ConvertTo-Vibecoding1cMcpArray (Get-ItlCatalogField $Preferences 'pendingCatalogRecords' @()))){
        if($pending.collection -notin @('products','projects')){throw 'CATALOG_PENDING_RECORD_INVALID: only explicit product/project drafts are supported here.'}
        $field=Get-ItlCatalogRecordKey $pending.collection
        $id=[string](Get-ItlCatalogField $pending.record $field)
        $current=Get-ItlCatalogRecord $Snapshot.catalog $pending.collection $id
        if($current -and ((Get-ItlCatalogHash $current) -ceq (Get-ItlCatalogHash $pending.record) -or $pending.status -eq 'saved')){continue}
        if((Get-ItlCatalogHash $current) -cne $pending.baseRecordHash){throw 'CATALOG_PENDING_RECORD_CONFLICT: the public record changed; review the saved draft through catalog create/preview without replacing its ID.'}
        if(-not $overlays.Count){$effective=ConvertTo-ItlCatalogCanonicalValue $Snapshot}
        $effective.catalog=Set-ItlCatalogRecord $effective.catalog $pending.collection $pending.record
        $overlays+=@(@{collection=$pending.collection;recordId=$id;recordHash=(Get-ItlCatalogHash $pending.record);status=$pending.status})
    }
    if($overlays.Count){$null=Assert-ItlProductCatalog $effective.catalog $effective.relations $effective.registry}
    return [pscustomobject]@{snapshot=$effective;publication=@{state=$(if($overlays.Count){'local-pending'}else{'published'});baseRevision=$Snapshot.catalogRevision;localRecords=$overlays}}
}

function New-ItlProductProjectPreview {
    param([object]$Context,[string[]]$Clients,[switch]$IncludeClientSurfaces)
    $endpointSet=Get-Vibecoding1cMcpClientConfigEndpointSet -ProductContext $Context
    $Context=ConvertTo-ItlCatalogCanonicalValue $Context
    $Context['catalogIncludesClientSurfaces']=$IncludeClientSurfaces.IsPresent
    $Context['nativeRoleOverrides']=Get-ItlCatalogField $endpointSet 'roleOverrides' @{}
    $requests=@(Write-Vibecoding1cMcpClientConfig -Clients $Clients -EndpointSet $endpointSet -ReturnRequests -UsePinnedCatalog -IncludeClientSurfaces:$IncludeClientSurfaces)
    $preferences=ConvertTo-Vibecoding1cMcpHashtable (Read-ItlProductProjectSetting selection)
    $overrides=ConvertTo-Vibecoding1cMcpHashtable (Get-ItlCatalogField $preferences 'clientOverrides' @{})
    $applied=Read-ItlProductProjectRecord applied
    $ownerState=Read-ItlManagedMcpState
    $lastWritten=Get-ItlCatalogField $ownerState 'lastWritten' @{}
    $whatIf=@(foreach($request in $requests){
        $copy=ConvertTo-ItlCatalogCanonicalValue $request;$key="$($request.client)/$($request.owner)"
        $copy['acceptedOwnedKeys']=@(Get-ItlManagedMcpOwnerKeys -Client $request.client -Owner $request.owner)
        $copy['preserveOwnedKeys']=@()
        [pscustomobject]$copy
    })
    $inputs=@($script:ConfigPath,(Get-Vibecoding1cMcpSelectionPath))
    $plan=Write-ItlClientMcpEndpointSet -Requests $whatIf -AdditionalInputPaths $inputs -PreserveUserChanges -ReturnPlan
    $changes=@(foreach($request in $requests){
        $key="$($request.client)/$($request.owner)";$entries=Read-ItlClientMcpEntries $request.client
        $projection=@($plan.projections|Where-Object {$_.client -eq $request.client -and $_.owner -eq $request.owner})[0]
        $owned=@(Get-ItlManagedMcpOwnerKeys -Client $request.client -Owner $request.owner)
        $names=@(@($owned)+@($request.endpoints|ForEach-Object {ConvertTo-ItlClientMcpKey $_.name $request.client})|Select-Object -Unique)
        $previousProof=Get-ItlCatalogField (Get-ItlCatalogField $applied 'proof' @{}) $key @{}
        $baseline=Get-ItlCatalogField $lastWritten $key @{}
        foreach($name in $names){
            $current=Get-ItlMcpOwnedSemanticSignature $entries @($name)
            $desired=Get-ItlMcpOwnedSemanticSignature $projection.entries @($name)
            $old=Get-ItlCatalogField (Get-ItlCatalogField $previousProof 'signatures' @{}) $name
            $explicit=$name -in @($overrides[$key])
            $unownedCollision=$entries.Contains($name) -and $name -notin $owned -and $name -in @($request.endpoints|ForEach-Object {ConvertTo-ItlClientMcpKey $_.name $request.client})
            if($current -ceq $desired -and -not $explicit -and -not $unownedCollision){continue}
            $status='managed-change'
            if($explicit){$status='local-override'}
            elseif($old -and $current -cne $old){$status=if($desired -cne $old -and $current -cne $desired){'conflict'}else{'local-override'}}
            elseif(-not $old -and $entries.Contains($name) -and ($name -notin $owned -or (Get-ItlCatalogField $baseline $name) -cne (Get-StringSha256 $current))){$status='local-override'}
            elseif(-not $entries.Contains($name)){$status='addition'}
            elseif(-not $projection.entries.Contains($name)){$status='retirement'}
            [pscustomobject]@{client=$request.client;owner=$request.owner;name=$name;status=$status;owned=($name -in $owned)}
        }
    })
    # Private plans contain native entries; the user-facing projection below
    # intentionally contains no headers, env values or other private fields.
    return [pscustomobject]@{context=$Context;endpointSet=$endpointSet;requests=$requests;plan=$plan;preferences=$preferences;changes=$changes;applied=$applied;settingsIntentHash=(Get-ItlCatalogHash @{settings=$Context.settingsHash;clients=@($Clients|Sort-Object -Unique);roleOverrides=$Context.nativeRoleOverrides;endpoints=@($endpointSet.allEndpoints|ForEach-Object {@{name=(Get-Vibecoding1cMcpEndpointClientName $_);url=$_.url;timeout=(Get-ItlCatalogField $_ 'toolTimeoutSeconds' 300)}})})}
}

function Show-ItlProductProjectPreview {
    param([object]$Preview)
    [pscustomobject]@{project=$Preview.context.projectName;product=$Preview.context.productName;catalogRevision=$Preview.context.catalogRevision;changes=@($Preview.changes|Select-Object client,name,status);activeClientContext='unverified';integrationState='intent-unverified'}
}

function Resolve-ItlProductProjectPreviewDecision {
    param([object]$Preview,[ValidateSet('','keep-local','registry','defer')][string]$Decision='', [bool]$AllowPrompt=$false)
    $conflicts=@($Preview.changes|Where-Object status -eq conflict)
    if($conflicts.Count -and -not $Decision){
        if(-not $AllowPrompt){throw 'CATALOG_CONFLICT_NEEDS_USER_ACTION: no settings or main phase were started. Run catalog preview and choose keep-local, registry or defer, then repeat the original command.'}
        Show-ItlProductProjectPreview $Preview|Format-List|Out-Host
        $answer=(Read-Host 'Catalog conflict: keep-local / registry / defer').Trim().ToLowerInvariant()
        if($answer -notin @('keep-local','registry','defer')){throw 'CATALOG_CONFLICT_NEEDS_USER_ACTION: no valid decision was supplied; no settings or main phase were started.'}
        $Decision=$answer
    }
    if($Decision -eq 'defer' -and -not $Preview.applied){throw 'CATALOG_DEFER_BASELINE_MISSING: first association has no applied baseline; cancel it or select the project explicitly after resolving local settings.'}
    $preferences=ConvertTo-ItlCatalogCanonicalValue $Preview.preferences
    $overrides=ConvertTo-Vibecoding1cMcpHashtable (Get-ItlCatalogField $preferences 'clientOverrides' @{})
    foreach($change in @($Preview.changes)){
        $key="$($change.client)/$($change.owner)"
        if(($change.status -eq 'local-override' -and ($Decision -ne 'registry' -or -not $change.owned)) -or ($change.status -eq 'conflict' -and $Decision -ne 'registry')){
            $overrides[$key]=@(@($overrides[$key])+@($change.name)|Where-Object {$_}|Select-Object -Unique)
        }elseif($change.status -in @('conflict','local-override') -and $Decision -eq 'registry'){$overrides[$key]=@($overrides[$key]|Where-Object {$_ -cne $change.name})}
    }
    $preferences['clientOverrides']=$overrides
    if($Decision -eq 'defer'){$preferences['defer']=@{settingsIntentHash=$Preview.settingsIntentHash;knowledgeHash=$Preview.context.knowledgeHash;catalogRevision=$Preview.applied.catalogRevision}}
    elseif($preferences.Contains('defer')){$preferences.Remove('defer')}
    $requests=@(foreach($original in $Preview.requests){
        $request=ConvertTo-ItlCatalogCanonicalValue $original;$key="$($request.client)/$($request.owner)"
        $owned=@(Get-ItlManagedMcpOwnerKeys -Client $request.client -Owner $request.owner)
        $request['preserveOwnedKeys']=@($owned|Where-Object {$_ -in @($overrides[$key])})
        $request['endpoints']=@($request.endpoints|Where-Object {(ConvertTo-ItlClientMcpKey $_.name $request.client) -notin @($overrides[$key])})
        $request['acceptedOwnedKeys']=@($Preview.changes|Where-Object {$_.client -eq $request.client -and $_.owner -eq $request.owner -and $_.status -in @('conflict','local-override') -and $_.owned -and $Decision -eq 'registry'}|ForEach-Object {$_.name})
        [pscustomobject]$request
    })
    $context=if($Decision -eq 'defer'){ConvertTo-ItlCatalogCanonicalValue $Preview.applied.context}else{ConvertTo-ItlCatalogCanonicalValue $Preview.context}
    $context['nativeClientOverrides']=$overrides
    $preferences['catalogRevision']=$context.catalogRevision
    $context['settingsIntentHash']=if($Decision -eq 'defer'){Get-ItlCatalogField $Preview.applied.context 'settingsIntentHash'}else{$Preview.settingsIntentHash}
    $proofRequests=$null
    if($Decision -eq 'defer'){$proofRequests=$requests;$requests=@()}
    return [pscustomobject]@{context=$context;requests=$requests;preferences=$preferences;proofRequests=$proofRequests;deferred=($Decision -eq 'defer')}
}

function Set-ItlProductProjectAppliedContext {
    param([object]$Applied,[string]$Reason='')
    if(-not $Applied -or (Get-ItlCatalogHash $Applied.context) -cne $Applied.contextHash){throw 'CATALOG_BASELINE_MISSING: no valid applied context is available; use catalog preview/select after restoring access, without guessing IDs or changing the infobase.'}
    $state=(Get-Variable ItlMcpRegistryOperation -Scope Script).Value
    $state.snapshot=Get-ItlCatalogField $Applied.context 'registryMetadata'
    if(-not $state.snapshot){throw 'CATALOG_BASELINE_MISSING: the saved context has no pinned endpoint metadata; repeat explicit setup with a validated catalog.'}
    # Retain one effective revision. An observed latest tip is not the deferred
    # context and must not leak through nested legacy endpoint consumers.
    try{$state.catalogSnapshot=Read-ItlProductCatalogSnapshot (Get-Vibecoding1cMcpRegistryRoot) $Applied.catalogRevision;$state.catalogError=$null}
    catch{$state.catalogSnapshot=$null;$state.catalogError=[InvalidOperationException]::new('CATALOG_PINNED_OBJECT_UNAVAILABLE: use the saved selected projection; full old catalog objects are unavailable.')}
    $state['catalogAttempted']=$true;$state.attempted=$true
    $state['warningShown']=$true
    Set-ItlProductProjectOperationContext $Applied.context
    if($Reason){Write-Warning $Reason}
}

function Initialize-ItlProductProjectContext {
    param([ValidateSet('','keep-local','registry','defer')][string]$Decision='', [bool]$AllowPrompt=$false,[switch]$IncludeClientSurfaces)
    $operation=Read-ItlProductProjectRecord operation
    if($operation -and $operation.status -notin @('completed','restored','cancelled')){throw 'CATALOG_OPERATION_PENDING: the main phase was not started. Use -Action vibecoding1c-mcp-status -CatalogAction status, then vibecoding1c-mcp-select -CatalogAction resume or restore on the pinned operation.'}
    $binding=Get-ItlProductProjectBinding
    if(-not $binding){return}
    $applied=Read-ItlProductProjectRecord applied
    $preferences=ConvertTo-Vibecoding1cMcpHashtable (Read-ItlProductProjectSetting selection)
    try{
        $snapshot=Read-ItlProductProjectSnapshot
        $effective=Get-ItlProductProjectEffectiveSnapshot $snapshot $preferences
        $context=Resolve-ItlProductProjectRuntimeContext -Snapshot $effective.snapshot -Binding $binding -Overrides (Get-ItlCatalogField $preferences 'overrides' @{}) -Conditions (ConvertTo-Agent1cHashtable (Get-ItlCatalogField $preferences 'conditionValues' @{})) -ProductVersion (Get-ItlCatalogField $preferences 'productVersion' '')
        $context['catalogPublication']=$effective.publication
    }catch{
        if($applied -and $applied.context.projectId -ceq $binding.projectId -and $applied.context.productId -ceq $binding.productId){Set-ItlProductProjectAppliedContext $applied ('Catalog refresh/validation failed; continuing with applied revision '+$applied.catalogRevision+'. Freshness and current native readiness are unverified.');return}
        throw
    }
    if((Get-ItlCatalogField $snapshot 'stale' $false) -and $applied){Set-ItlProductProjectAppliedContext $applied 'Catalog is offline; the validated applied revision is retained without client writes.';return}
    if(Get-ItlCatalogField $snapshot 'stale' $false){Write-Warning 'Catalog is offline; this root is materialized from a validated cached Git snapshot. Freshness and native readiness are unverified.'}
    $family=Get-ConfigValue -Path baseConfigurationVersion -Default ''
    if($family -and $context.baseConfigurationVersion -and $family -cne $context.baseConfigurationVersion){throw 'CATALOG_PRODUCT_FAMILY_CHANGED: automatic catalog update cannot change the local product family or infobase; review the project record before continuing.'}
    $context['registryMetadata']=$snapshot.registry
    $clients=@(Get-ConfigValue -Path aiRules.tools -Default @()|Where-Object {$_}|Select-Object -Unique)
    if(-not $clients.Count){$clients=@(Get-ItlActiveClient)}
    $cachedInputs=Get-ItlCatalogField $applied 'noOpInputs'
    if(-not $Decision -and $applied -and $applied.configurationState -eq 'configured' -and $cachedInputs -and
        (Get-ItlProductProjectResolvedHash $applied.context) -ceq (Get-ItlProductProjectResolvedHash $context) -and
        (-not $IncludeClientSurfaces -or (Get-ItlCatalogField $cachedInputs 'includeClientSurfaces' $false))){
        $currentInputs=Get-ItlProductProjectNoOpInputs $applied.proof -IncludeClientSurfaces:([bool](Get-ItlCatalogField $cachedInputs 'includeClientSurfaces' $false))
        if((Get-ItlCatalogHash $cachedInputs) -ceq (Get-ItlCatalogHash $currentInputs)){Set-ItlProductProjectOperationContext $applied.context;return}
    }
    $preview=New-ItlProductProjectPreview $context $clients -IncludeClientSurfaces:$IncludeClientSurfaces
    $defer=Get-ItlCatalogField $preferences 'defer'
    if(-not $Decision -and $applied -and $defer -and $defer.settingsIntentHash -ceq $preview.settingsIntentHash -and $defer.knowledgeHash -ceq $context.knowledgeHash){Set-ItlProductProjectAppliedContext $applied 'Catalog update remains explicitly deferred; the applied revision and local overrides are retained.';return}
    $chosen=Resolve-ItlProductProjectPreviewDecision $preview -Decision $Decision -AllowPrompt:$AllowPrompt
    $privateChanged=(Get-ItlCatalogHash $preferences) -cne (Get-ItlCatalogHash $chosen.preferences)
    $hasClientChanges=@($preview.changes|Where-Object {($_.status -in @('managed-change','addition','retirement','conflict')) -or ($_.status -eq 'local-override' -and $_.owned -and $Decision -eq 'registry')}).Count -gt 0
    if(-not $chosen.deferred -and -not $hasClientChanges){$chosen.proofRequests=$chosen.requests;$chosen.requests=@()}
    $same=$applied -and $applied.context.settingsHash -ceq $chosen.context.settingsHash -and $applied.context.knowledgeHash -ceq $chosen.context.knowledgeHash -and (Get-ItlCatalogField $applied.context 'settingsIntentHash') -ceq $chosen.context.settingsIntentHash -and $applied.catalogRevision -ceq $chosen.context.catalogRevision
    if($same -and -not $privateChanged -and -not $hasClientChanges){
        $newInputs=Get-ItlProductProjectNoOpInputs $applied.proof -IncludeClientSurfaces:$IncludeClientSurfaces
        if((Get-ItlCatalogHash $cachedInputs) -cne (Get-ItlCatalogHash $newInputs)){$applied['noOpInputs']=$newInputs;Write-ItlProductProjectRecord applied $applied}
        Set-ItlProductProjectOperationContext $chosen.context;return
    }
    $null=Invoke-ItlProductProjectClientApply -Context $chosen.context -Requests $chosen.requests -ProofRequests $chosen.proofRequests -SavePrivateSelection:$privateChanged -PrivateSelection $chosen.preferences -ExpectedInputStates $preview.plan.fileStates -ExpectedOwnerState $preview.plan.ownerState
    if($chosen.deferred){Set-ItlProductProjectAppliedContext (Read-ItlProductProjectRecord applied) 'Catalog changes deferred; current local settings were preserved on the prior revision.'}
    else{Set-ItlProductProjectOperationContext $chosen.context;if($hasClientChanges){Write-Host 'Catalog settings applied. Reload the client/new session and verify tools before treating the active MCP context as updated.'}else{Write-Host 'Catalog context updated; client MCP settings unchanged.'}}
}

function Get-ItlProductProjectResolvedHash {
    param([object]$Context)
    $projection=[ordered]@{}
    foreach($field in @('catalogRevision','projectId','productId','profileId','roles','links','knowledgeContext','settingsHash','knowledgeHash','endpointIntents','baseConfigurationVersion','projectName','productName','catalogPublication','inputGitObjectIds')){$projection[$field]=Get-ItlCatalogField $Context $field}
    return Get-ItlCatalogHash $projection
}

function Get-ItlProductProjectNoOpInputs {
    param([object]$Proof,[switch]$IncludeClientSurfaces)
    $paths=@($script:ConfigPath,(Get-Vibecoding1cMcpSelectionPath),(Get-ItlManagedMcpStatePath),(Join-Path $script:ProjectRoot '.dev.env'),(Get-Vibecoding1cMcpLocalPath 'state.json'),(Get-Vibecoding1cMcpLocalPath 'config.env'),(Join-Path (Get-Vibecoding1cMcpDistributionRoot) 'vibecoding1c-mcp.manifest.json'),(Join-Path (Get-Vibecoding1cMcpDistributionRoot) 'config.env'))
    foreach($key in @(Get-ItlCatalogKeys $Proof)){$paths+=@($Proof[$key].paths)}
    $paths+=Join-Path $script:ProjectRoot '.agent-1c/dependency-lock.json'
    foreach($leaf in @('core','client-adapters','client-opencode','client-jsonc','vibecoding1c-mcp','ondemand-mcp','product-catalog','product-project-runtime','product-project-context')){$paths+=Join-Path $PSScriptRoot "agent-1c.$leaf.ps1"}
    foreach($relative in @('../../assets/ondemand-mcp/compatibility.json','../../assets/ondemand-mcp/roctup.catalog.json','../../assets/ondemand-mcp/vanessa-ui.catalog.json')){$paths+=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot $relative))}
    $files=[ordered]@{};foreach($path in @($paths|Where-Object {$_}|Sort-Object -Unique)){$files[$path]=Get-ItlMcpFileState $path}
    $invocation=[ordered]@{}
    foreach($name in @('McpScope','McpServerId','McpProvider','McpConfigId','McpHostId','McpLocalScope','AgentTarget')){$variable=Get-Variable $name -ErrorAction SilentlyContinue;$invocation[$name]=if($variable){$variable.Value}else{$null}}
    foreach($entry in [Environment]::GetEnvironmentVariables('Process').GetEnumerator()){if([string]$entry.Key -like 'VIBECODING1C_MCP_*'){$invocation[[string]$entry.Key]=[string]$entry.Value}}
    # Only hashes persist; any input change returns to full preview.
    return [ordered]@{files=$files;invocationHash=(Get-ItlCatalogHash $invocation);includeClientSurfaces=$IncludeClientSurfaces.IsPresent}
}

function Get-ItlProductProjectSetupContext {
    # Setup may resume after a long unattended init. It must retain the choice
    # made before that phase, rather than refreshing it half way through.
    if(-not (Get-ItlProductProjectBinding)){return $null}
    $pending=Read-ItlProductProjectRecord operation
    if($pending -and $pending.status -notin @('completed','restored','cancelled')){throw 'CATALOG_OPERATION_PENDING: use catalog status/resume/restore before MCP setup.'}
    $context=Get-ItlProductProjectOperationContext
    if($context){return $context}
    $applied=Read-ItlProductProjectRecord applied
    if($applied){
        $binding=Get-ItlProductProjectBinding
        if($applied.context.projectId -cne $binding.projectId -or $applied.context.productId -cne $binding.productId){throw 'CATALOG_BINDING_CONFLICT: the saved init context differs from the tracked binding; use explicit catalog preview/select.'}
        Set-ItlProductProjectAppliedContext $applied
    }else{Initialize-ItlProductProjectContext}
    return Get-ItlProductProjectOperationContext
}

function Test-ItlProductProjectCatalogRole {
    param([string]$ServerId,[object]$Selection)
    if($ServerId -notin @('code','graph','bookstack')){return $false}
    $entry=Get-Vibecoding1cMcpSelectionEntry -Selection $Selection -ServerId $ServerId
    return (Get-Vibecoding1cMcpSelectedProvider -Server @{id=$ServerId} -Selection $Selection) -ne 'local' -and -not (Get-Vibecoding1cMcpObjectValue -Object $entry -Name catalogOverride -Default $false)
}

function Assert-ItlProductProjectPackageCompatibility {
    param([string]$SourceRoot)
    $binding=Get-ItlProductProjectBinding
    if(-not $binding){return}
    $path=Join-Path $SourceRoot '.agents/skills/1c-workflow/assets/product-project-compatibility.json'
    $compatible=$false
    if(Test-Path -LiteralPath $path -PathType Leaf){
        try{
            $descriptor=Read-Utf8Text $path|ConvertFrom-Json -ErrorAction Stop
            $capabilities=Get-ItlCatalogField $descriptor 'capabilities' @()
            $compatible=(Get-ItlCatalogField $descriptor 'schemaVersion') -eq 1 -and $binding.requiredCapability -cin @($capabilities)
        }catch{$compatible=$false}
    }
    if(-not $compatible){throw 'CATALOG_PACKAGE_INCOMPATIBLE: no helper files were replaced. Preserve the binding and use the current helper -Action vibecoding1c-mcp-select -CatalogAction restore-compatible, then repeat update-workflow with the same requested package. A legacy permissive parser cannot validate this capability.'}
}

function Get-ItlProductProjectIntegrationIntent {
    param([object]$Context,[ValidateSet('mantis-search','mantis-create','sppr-exact')][string]$Operation,[string]$Purpose='', [int]$IssueId=0,[int]$ExplicitProjectId=0)
    if($Operation -eq 'mantis-search' -and $IssueId -gt 0){return [pscustomobject]@{status='ready';issueId=$IssueId;filters=@{};provenance='explicit-issue-id';scopeIsAccessControl=$false}}
    $kind=if($Operation -eq 'sppr-exact'){'sppr'}else{'mantis'}
    $link=Get-ItlCatalogField $Context.links $kind
    $value=Get-ItlCatalogField $link 'value'
    if($Operation -eq 'mantis-search'){
        $ids=Get-ItlCatalogField $value 'searchProjectIds' @()
        $hasScope=@(Get-ItlCatalogKeys $value) -ccontains 'searchProjectIds'
        $filters=if($hasScope){@{project_ids=@($ids)}}else{@{}}
        return [pscustomobject]@{status=$(if($hasScope){'ready'}else{'global'});filters=$filters;provenance=(Get-ItlCatalogField $link 'provenance');scopeIsAccessControl=$false}
    }
    if($Operation -eq 'mantis-create'){
        $id=if($ExplicitProjectId -gt 0){$ExplicitProjectId}else{Get-ItlCatalogField (Get-ItlCatalogField $value 'createRoutes' @{}) $Purpose}
        return [pscustomobject]@{status=$(if($id){'ready'}else{'needs-input'});projectId=$id;purpose=$Purpose;provenance=$(if($ExplicitProjectId -gt 0){'explicit-operation'}else{Get-ItlCatalogField $link 'provenance'});continuation=$(if(-not $id){'Ask for the Mantis project for this creation only; do not guess from search scopes or save it as a default.'}else{''})}
    }
    return [pscustomobject]@{status=$(if($value){'linked'}else{'unlinked'});exactLink=$value;provenance=(Get-ItlCatalogField $link 'provenance');similarity='independent-search-evidence';nativeReadiness='unverified'}
}

function New-ItlProductProjectMantisWriteArguments {
    param([object]$Context,[string]$Purpose,[Parameter(Mandatory=$true)][string]$OperationId,[Parameter(Mandatory=$true)][object[]]$Steps,[int]$ExplicitProjectId=0)
    if([string]::IsNullOrWhiteSpace($OperationId)){throw 'CATALOG_MANTIS_OPERATION_REQUIRED: retain the existing writer operation ID across retries.'}
    $prepared=@($Steps|ForEach-Object {ConvertTo-ItlCatalogCanonicalValue $_})
    foreach($step in $prepared){
        if($step.action -ne 'create_issue'){continue}
        # An explicit operation payload has priority; no writer, operation
        # journal or idempotency policy is implemented here.
        if(Get-ItlCatalogField $step 'project_id'){continue}
        $route=Get-ItlProductProjectIntegrationIntent $Context mantis-create -Purpose $Purpose -ExplicitProjectId $ExplicitProjectId
        if($route.status -ne 'ready'){throw 'CATALOG_MANTIS_ROUTE_REQUIRED: ask for the target project for this operation only, then retry with the same operation ID; no write was sent.'}
        $step['project_id']=$route.projectId
    }
    return [pscustomobject]@{operation_id=$OperationId;steps=$prepared}
}
