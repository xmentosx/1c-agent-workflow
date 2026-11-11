# Frozen readers of the workflow release before improve-scoped-memory-adoption
# (origin/develop ae4fdef8, agent-1c.memory.ps1). Tests dot-source them in a
# child scope to prove that a rolled-back or not yet updated copy still reads
# an extended binding and a standing note. Do not edit: this is the old reader.

function Assert-ItlMemoryBindingCurrent {
    param([object]$Binding)
    if($Binding.schemaVersion -ne 1 -or $Binding.capability -cne 'scoped-cognee-memory-v1'){throw 'MEMORY_BINDING_UNSUPPORTED'}
    if($Binding.mode -ne 'enabled'){throw 'MEMORY_DISABLED: use the explicit memory setup; ordinary workflow remains available.'}
    $state=Read-ItlMemoryJson $Binding.cycleStatePath
    $cycle=Get-ItlCatalogField $state 'memoryCycle'
    if(-not $cycle -or $cycle.current -cne $Binding.cycleId -or (Get-ItlCatalogField $cycle 'workspaceId') -cne $Binding.identity.workspaceId -or (Get-ItlCatalogField $cycle 'reserved') -or (Get-ItlCatalogField $state 'resetStatus') -eq 'resetting'){
        throw 'MEMORY_STALE_CONTEXT: reload the scoped binding after the existing lifecycle operation completes; old task history is not the new cycle.'
    }
    $applied=Read-ItlMemoryAppliedContext $Binding.appliedPath
    if(-not $applied -or $applied.contextHash -cne $Binding.registryContextHash -or (Get-ItlCatalogHash $applied.context) -cne $applied.contextHash){
        throw 'MEMORY_STALE_CONTEXT: run the existing catalog apply/resume, then explicit memory setup/reload; no new catalog fetch is performed here.'
    }
    $live=Read-ItlMemoryJson (Get-ItlMemoryPath binding $Binding.projectRoot)
    if(-not $live -or $live.mode -ne 'enabled' -or $live.bindingId -cne $Binding.bindingId){throw 'MEMORY_STALE_CONTEXT: this client retains an old/disabled binding; reload it.'}
}

function Get-ItlMemoryScopes {
    param([object]$Binding,[string]$Access='read',[string]$DatasetName='',[string]$KnowledgeArea='')
    if($Access -notin @('read','write')){throw 'MEMORY_ACCESS_INVALID'}
    $context=$Binding.context;$identity=$Binding.identity
    $keys=@{taskCycle=$Binding.cycleId;workspace=$identity.workspaceId;workplace=$identity.workplaceId;project=$context.projectId;organization=$Binding.provider.organizationId}
    $products=@($context.knowledgeContext.productReadCandidates)
    $allowed=@()
    foreach($entry in @($Binding.provider.datasets)){
        $kind=[string](Get-ItlCatalogField $entry 'scopeKind');$id=[string](Get-ItlCatalogField $entry 'scopeId')
        $matches=if($kind -eq 'product'){$products -ccontains $id}else{$keys.ContainsKey($kind) -and $keys[$kind] -ceq $id}
        if($kind -eq 'taskCycle' -and (Get-ItlCatalogField $entry 'workspaceId') -cne $identity.workspaceId){$matches=$false}
        if(-not $matches -or -not (Get-ItlCatalogField $entry 'admitted' $false) -or @($entry.permissions) -cnotcontains $Access){continue}
        if($DatasetName -and $entry.label -cne $DatasetName){continue}
        if($kind -eq 'product' -and $Access -eq 'write'){
            $areas=@($context.knowledgeContext.knowledgeAreas|Where-Object {$_.areaId -ceq $KnowledgeArea -and $_.status -eq 'applicable' -and $_.memoryHomeProductId -ceq $id})
            if($areas.Count -ne 1){continue}
        }
        if([string]$entry.datasetId -cnotmatch '^[a-fA-F0-9-]{36}$' -or -not $entry.ownerId){throw 'MEMORY_DATASET_UNVERIFIED: supply the native exact ID and owner, not a label lookup.'}
        $allowed+=,$entry
    }
    if($Access -eq 'write' -and (-not $DatasetName -or $allowed.Count -ne 1)){throw 'MEMORY_DESTINATION_REQUIRED: explicitly select one allowed dataset; keep an ambiguous fact as a private project/task candidate.'}
    return $allowed
}

function Get-ItlMemoryIntentHash {
    param([object]$Note)
    $origin=Get-ItlCatalogField $Note 'updatedByOrigin' (Get-ItlCatalogField $Note 'origin' @{})
    return (Get-ItlCatalogHash @{
        fact=(Get-ItlCatalogField $Note 'fact' (Get-ItlCatalogField $Note 'data'))
        applicability=$Note.applicability;evidence=$Note.evidence;status=$Note.status
        source=(Get-ItlCatalogField $origin 'source' (Get-ItlCatalogField $Note 'source' ''))
        revision=(Get-ItlCatalogField $origin 'revision' (Get-ItlCatalogField $Note 'revision' ''))
    })
}

function Get-ItlMemoryOriginal {
    param([object]$Binding,[object]$Dataset,[string]$DataId,[DateTime]$DeadlineUtc,[object]$Response=$null)
    if($DataId -cnotmatch '^[a-fA-F0-9-]{36}$'){return $null}
    $raw=if($null -ne $Response){Complete-ItlMemoryHttp $Response}else{Invoke-ItlMemoryHttp $Binding.provider GET "/api/v1/datasets/$($Dataset.datasetId)/data/$DataId/raw" -DeadlineUtc $DeadlineUtc -Raw}
    if($raw.status -eq 404){return $null}
    if($raw.status -ne 200){throw 'MEMORY_SOURCE_UNAVAILABLE: no current authorized original; do not use a cached fragment.'}
    try{$note=ConvertTo-ItlCatalogCanonicalValue ($raw.body|ConvertFrom-Json -ErrorAction Stop)}catch{return $null}
    if((Get-ItlCatalogField $note 'format') -cne 'itl-memory-v1' -or $note.scope.kind -cne $Dataset.scopeKind -or $note.scope.id -cne $Dataset.scopeId){return $null}
    return $note
}

function Test-ItlMemoryNoteApplicable {
    param([object]$Binding,[object]$Note)
    if($Note.status -ne 'verified'){return $false}
    $project=Get-ItlCatalogField $Note.applicability 'projectId'
    if($project -and $project -cne $Binding.context.projectId){return $false}
    if($Note.scope.kind -eq 'taskCycle' -and ($Note.scope.id -cne $Binding.cycleId -or (Get-ItlCatalogField $Note.origin 'projectId') -cne $Binding.context.projectId)){return $false}
    if($Note.scope.kind -eq 'product'){
        $area=Get-ItlCatalogField $Note.applicability 'knowledgeArea'
        $rule=Get-ItlCatalogField $Binding.memoryProjection.knowledgeAreas $area
        if(-not $rule -or (Get-ItlCatalogField $rule 'memoryHomeProductId') -cne $Note.scope.id){return $false}
        $result=Resolve-ItlCatalogArea $Binding.memoryProjection.snapshot $Binding.context.productId $rule (ConvertTo-Agent1cHashtable $Binding.context.knowledgeContext.conditionValues) ([string]$Binding.context.knowledgeContext.productVersion)
        if($result.status -ne 'applicable'){return $false}
    }
    $requiresProducts=Get-ItlCatalogField $Note.applicability 'requiresProducts' @()
    foreach($required in $requiresProducts){if(@($Binding.memoryProjection.composition) -cnotcontains $required){return $false}}
    $check=[ordered]@{availableIn=@($Binding.context.productId)}
    $available=Get-ItlCatalogField $Note.applicability 'availableIn'
    if($available){$check.availableIn=$available}
    foreach($field in @('conditions','versionRange')){$value=Get-ItlCatalogField $Note.applicability $field;if($value){$check[$field]=$value}}
    return ((Resolve-ItlCatalogArea $Binding.memoryProjection.snapshot $Binding.context.productId $check (ConvertTo-Agent1cHashtable $Binding.context.knowledgeContext.conditionValues) ([string]$Binding.context.knowledgeContext.productVersion)).status -eq 'applicable')
}
