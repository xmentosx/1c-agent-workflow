# Explicit setup/authoring UI. Ordinary startup never loads this leaf.
function Get-ItlProductProjectChoices {
    param([object]$Snapshot,[ValidateSet('projects','products')][string]$Collection='projects',[int]$Limit=10)
    $field=Get-ItlCatalogRecordKey $Collection
    return @($Snapshot.catalog.$Collection|Sort-Object -Property $field|Select-Object -First $Limit|ForEach-Object {[pscustomobject]@{id=(Get-ItlCatalogField $_ $field);name=$_.name;productId=(Get-ItlCatalogField $_ 'productId')}})
}

function Save-ItlProductProjectDraft {
    param([object]$Snapshot,[ValidateSet('products','projects')][string]$Collection,[object]$Record)
    $field=Get-ItlCatalogRecordKey $Collection;$id=[string](Get-ItlCatalogField $Record $field)
    $prospective=Set-ItlCatalogRecord $Snapshot.catalog $Collection $Record
    $null=Assert-ItlProductCatalog $prospective $Snapshot.relations $Snapshot.registry
    $originalPreferences=Read-ItlProductProjectSetting selection
    $preferences=ConvertTo-Vibecoding1cMcpHashtable $originalPreferences
    $allPending=@(ConvertTo-Vibecoding1cMcpArray (Get-ItlCatalogField $preferences 'pendingCatalogRecords' @()))
    $retained=@($allPending|Where-Object {$_.collection -eq $Collection -and (Get-ItlCatalogField $_.record $field) -ceq $id -and $_.status -ne 'saved'})
    $pending=@($allPending|Where-Object {$_ -and -not ($_.collection -eq $Collection -and (Get-ItlCatalogField $_.record $field) -ceq $id)})
    $draft=@{collection=$Collection;record=$Record;baseRevision=$(if($retained.Count){$retained[0].baseRevision}else{$Snapshot.catalogRevision});baseRecordHash=$(if($retained.Count){$retained[0].baseRecordHash}else{Get-ItlCatalogHash (Get-ItlCatalogRecord $Snapshot.catalog $Collection $id)});status='unsubmitted';confirmedRevision=$null}
    $desired=ConvertTo-ItlCatalogCanonicalValue $preferences;$desired['pendingCatalogRecords']=@($pending)+@($draft)
    # Stable ID and original base survive a lost push response or interruption.
    Set-ItlProductProjectSetting selection $desired $originalPreferences
    $saved=Save-ItlCatalogRecord -RepositoryRoot (Get-Vibecoding1cMcpRegistryRoot) -BaseCommit $draft.baseRevision -Collection $Collection -Record $Record
    $draft.status=[string]$saved.status;$draft.confirmedRevision=Get-ItlCatalogField $saved 'catalogRevision'
    $current=ConvertTo-Vibecoding1cMcpHashtable (Read-ItlProductProjectSetting selection)
    $next=ConvertTo-ItlCatalogCanonicalValue $current
    $next['pendingCatalogRecords']=@($pending)+@($draft)
    Set-ItlProductProjectSetting selection $next $current
    if($saved.status -eq 'saved'){
        $verified=Get-ItlCatalogField $saved 'verifiedSnapshot'
        if(-not $verified -or $verified.catalogRevision -cne $saved.catalogRevision){throw 'CATALOG_SAVE_PROOF_MISSING: publication was reported without its exact read-back snapshot; the stable draft is retained.'}
        $state=(Get-Variable ItlMcpRegistryOperation -Scope Script).Value
        $state['catalogAttempted']=$true;$state['catalogSnapshot']=$verified;$state['catalogError']=$null;$state.snapshot=$verified.registry;$state.attempted=$true;$state.error=$null
    }
    return [pscustomobject]@{status=$saved.status;recordId=$id;catalogRevision=$draft.confirmedRevision;publicationOutcome=$saved.outcome}
}

function New-ItlProductProjectDraft {
    param([object]$Snapshot,[string]$RecordPath='', [bool]$AllowPrompt=$false,[int]$Limit=10)
    $preferences=Read-ItlProductProjectSetting selection
    $existing=@(ConvertTo-Vibecoding1cMcpArray (Get-ItlCatalogField $preferences 'pendingCatalogRecords' @())|Where-Object {$_.collection -eq 'projects' -and $_.status -ne 'saved'})
    if(-not $RecordPath -and $existing.Count){return Save-ItlProductProjectDraft $Snapshot projects $existing[0].record}
    $record=if($RecordPath){ConvertTo-ItlCatalogCanonicalValue (Read-Utf8Text (Resolve-ProjectPath $RecordPath)|ConvertFrom-Json -ErrorAction Stop)}else{[ordered]@{}}
    if(-not (Get-ItlCatalogField $record 'projectId')){$record['projectId']='project-'+[guid]::NewGuid().ToString('N')}
    if(-not (Get-ItlCatalogField $record 'name')){if(-not $AllowPrompt){throw 'CATALOG_PROJECT_NAME_REQUIRED: provide a project record with its name.'};$record['name']=Read-InitRequired 'Project name'}
    if(-not (Get-ItlCatalogField $record 'productId')){
        if(-not $AllowPrompt){throw 'CATALOG_PRODUCT_REQUIRED: choose the base product explicitly; no ID is inferred from the local directory or MCP endpoint.'}
        Get-ItlProductProjectChoices $Snapshot products $Limit|Format-Table|Out-Host
        $record['productId']=Read-InitRequired 'Base product ID'
    }
    if(Get-ItlCatalogRecord $Snapshot.catalog projects $record.projectId){throw 'CATALOG_PROJECT_EXISTS: create cannot replace an existing project; select its ID or use explicit catalog editing.'}
    return Save-ItlProductProjectDraft $Snapshot projects $record
}

function Select-ItlProductProjectCandidate {
    param([string]$ProjectId='', [string]$ProfileId='', [string]$RecordPath='', [bool]$AllowPrompt=$false,[int]$Limit=10,[switch]$ReadOnly)
    if(-not $ProjectId -and -not $AllowPrompt){throw 'CATALOG_PROJECT_REQUIRED: choose an existing published project with -CatalogProjectId (JSON init: projectId), then repeat the same operation. If absent, prepare and publish it through catalog create separately. No project was inferred.'}
    $raw=Read-ItlProductProjectSnapshot
    $preferences=ConvertTo-Vibecoding1cMcpHashtable (Read-ItlProductProjectSetting selection)
    $effective=Get-ItlProductProjectEffectiveSnapshot $raw $preferences
    if(-not $ProjectId){
        $choices=if($ReadOnly){$effective.snapshot}else{$raw}
        Get-ItlProductProjectChoices $choices projects $Limit|Format-Table|Out-Host
        $ProjectId=Read-InitRequired 'Published project ID (required; cancel to stop the transition)'
    }
    if($ProjectId -eq 'new'){
        if($ReadOnly){throw 'CATALOG_PREVIEW_READ_ONLY: use catalog create/select explicitly before previewing a new record.'}
        throw 'CATALOG_PROJECT_CREATE_SEPARATE: select an existing published project. Use catalog create separately, review its inherited settings and project links, publish it, then repeat this operation.'
    }
    $project=Get-ItlCatalogRecord $effective.snapshot.catalog projects $ProjectId
    if(-not $project){throw "CATALOG_PROJECT_UNKNOWN: '$ProjectId' is absent from the validated catalog and retained local drafts."}
    $product=Get-ItlCatalogRecord $effective.snapshot.catalog products $project.productId
    if(-not $ReadOnly){
        $related=@($effective.publication.localRecords|Where-Object {($_.collection -eq 'projects' -and $_.recordId -ceq $ProjectId) -or ($_.collection -eq 'products' -and $_.recordId -ceq $project.productId)})
        if($related.Count -or -not (Get-ItlCatalogRecord $raw.catalog projects $ProjectId)){
            throw 'CATALOG_PROJECT_NOT_PUBLISHED: retained drafts are available for preview only. Complete catalog create/save publication, then repeat the same selection; drafts and the current installation are preserved.'
        }
        # Unrelated retained drafts do not block a published project and are
        # not silently applied or discarded by its runtime association.
        $effective=[pscustomobject]@{snapshot=$raw;publication=@{state='published';baseRevision=$raw.catalogRevision;localRecords=@()}}
        $project=Get-ItlCatalogRecord $raw.catalog projects $ProjectId
        $product=Get-ItlCatalogRecord $raw.catalog products $project.productId
    }
    $family=Get-ItlCatalogField $product 'baseConfigurationVersion'
    if(-not $family){
        throw 'CATALOG_PRODUCT_FAMILY_REQUIRED: complete and publish the selected product metadata separately, then repeat this operation; PM4/PM5 is never inferred or edited during selection.'
    }
    $binding=[ordered]@{schemaVersion=1;requiredCapability='product-project-registry-v1';projectId=$ProjectId;productId=$project.productId}
    if($ProfileId){$binding['profileId']=$ProfileId}
    $context=Resolve-ItlProductProjectRuntimeContext $effective.snapshot $binding -Overrides (Get-ItlCatalogField $preferences 'overrides' @{}) -Conditions (ConvertTo-Agent1cHashtable (Get-ItlCatalogField $preferences 'conditionValues' @{})) -ProductVersion (Get-ItlCatalogField $preferences 'productVersion' '')
    $context['registryMetadata']=$raw.registry;$context['catalogPublication']=$effective.publication
    return [pscustomobject]@{binding=$binding;context=$context;preferences=$preferences}
}

function Invoke-ItlProductProjectAssociation {
    param([object]$Candidate,[string]$Decision='', [bool]$AllowPrompt=$false,[switch]$IncludeClientSurfaces)
    $family=Get-ConfigValue -Path baseConfigurationVersion -Default ''
    if($family -and $family -cne $Candidate.context.baseConfigurationVersion){throw 'CATALOG_PRODUCT_FAMILY_CHANGED: association cannot change the current configuration family, initialize or reset the database.'}
    $clients=@(Get-ConfigValue -Path aiRules.tools -Default @()|Where-Object {$_}|Select-Object -Unique)
    if(-not $clients.Count){$clients=@(Get-ItlActiveClient)}
    $preview=New-ItlProductProjectPreview $Candidate.context $clients -IncludeClientSurfaces:$IncludeClientSurfaces
    if($AllowPrompt){Show-ItlProductProjectPreview $preview|Format-List|Out-Host}
    $chosen=Resolve-ItlProductProjectPreviewDecision $preview -Decision $Decision -AllowPrompt:$AllowPrompt
    $result=Invoke-ItlProductProjectClientApply $chosen.context $chosen.requests -BindProject -DesiredBinding $Candidate.binding -SavePrivateSelection -PrivateSelection $chosen.preferences -ExpectedInputStates $preview.plan.fileStates -ExpectedOwnerState $preview.plan.ownerState -ProofRequests $chosen.proofRequests
    Set-ItlProductProjectOperationContext $chosen.context
    . Import-ItlMemory
    $memory=@(foreach($memoryClient in $clients){Invoke-ItlMemorySetup auto -Client $memoryClient})
    return [pscustomobject]@{status=$result.status;projectId=$Candidate.binding.projectId;productId=$Candidate.binding.productId;publication=$Candidate.context.catalogPublication.state;activeClientContext='unverified';memorySetup=$memory}
}

function Invoke-ItlProductProjectCommand {
    param([ValidateSet('list','preview','select','create','sync','context')][string]$Mode,[string]$ProjectId='', [string]$ProfileId='', [string]$RecordPath='', [string]$Decision='', [int]$Limit=10,[bool]$AllowPrompt=$false,[switch]$AsJson)
    if($Mode -eq 'context'){
        $applied=Read-ItlProductProjectRecord applied
        if(-not $applied){$report=[pscustomobject]@{status='unbound';continuation='Use catalog select/preview explicitly.'}}
        else {
            $context=$applied.context
            $sourceObservations=$null
            if($RecordPath){
                . (Join-Path $PSScriptRoot 'agent-1c.product-source-evidence.ps1')
                $sourceObservations=Read-ItlProductSourceObservations $context $RecordPath
            }
            $integrationDefaults=@{mantisSearch=(Get-ItlProductProjectIntegrationIntent $context mantis-search);mantisCreateRoutes=(Get-ItlCatalogField (Get-ItlCatalogField (Get-ItlCatalogField $context.links 'mantis') 'value') 'createRoutes' @{});sppr=(Get-ItlProductProjectIntegrationIntent $context sppr-exact)}
            $report=[pscustomobject]@{projectDifferences=(Get-ItlCatalogField $context 'projectContext');sources=@(Get-ItlProductProjectSourceSummary $context);project=$context.projectName;projectId=$context.projectId;product=$context.productName;productId=$context.productId;catalogRevision=$applied.catalogRevision;publication=(Get-ItlCatalogField $context 'catalogPublication');roles=@($context.roles.Keys|ForEach-Object {@{role=$_;mode=$context.roles[$_].mode;resolution=$context.roles[$_].resolution;sourceId=(Get-ItlCatalogField $context.roles[$_].source 'sourceId');nativeReadiness='unverified'}});links=$context.links;integrationDefaults=$integrationDefaults;nativeRoleOverrides=(Get-ItlCatalogField $context 'nativeRoleOverrides' @{});clientOverrideCount=@(Get-ItlCatalogKeys (Get-ItlCatalogField $context 'nativeClientOverrides' @{})).Count;activeClientContext='unverified'}
            if($RecordPath){$report|Add-Member -NotePropertyName sourceObservations -NotePropertyValue $sourceObservations}
        }
        # The public CLI must not let PowerShell collapse nested source details.
        # Internal consumers keep the same DTO; serialize only on explicit output.
        if($AsJson){return ($report|ConvertTo-Json -Depth 20 -Compress)}
        return $report
    }
    Invoke-Vibecoding1cMcpRegistryOperation {
        if($Mode -eq 'sync'){Initialize-ItlProductProjectContext -Decision $Decision -AllowPrompt:$AllowPrompt;return}
        $pending=Read-ItlProductProjectRecord operation
        if($pending -and $pending.status -notin @('completed','restored','cancelled')){Invoke-ItlProductProjectRecovery status;return}
        if($Mode -eq 'list'){
            $raw=Read-ItlProductProjectSnapshot
            $effective=Get-ItlProductProjectEffectiveSnapshot $raw (Read-ItlProductProjectSetting selection)
            Get-ItlProductProjectChoices $effective.snapshot projects $Limit
            return
        }
        if($Mode -eq 'create'){New-ItlProductProjectDraft (Read-ItlProductProjectSnapshot) -RecordPath $RecordPath -AllowPrompt:$AllowPrompt -Limit $Limit;return}
        $candidate=Select-ItlProductProjectCandidate -ProjectId $ProjectId -ProfileId $ProfileId -RecordPath $RecordPath -AllowPrompt:$AllowPrompt -Limit $Limit -ReadOnly:($Mode -eq 'preview')
        if($Mode -eq 'preview'){
            $clients=@(Get-ConfigValue -Path aiRules.tools -Default @()|Where-Object {$_})
            if(-not $clients.Count){$clients=@(Get-ItlActiveClient)}
            Show-ItlProductProjectPreview (New-ItlProductProjectPreview $candidate.context $clients)
            return
        }
        Invoke-ItlProductProjectAssociation $candidate -Decision $Decision -AllowPrompt:$AllowPrompt
    }
}

function Read-ItlProductProjectInitFamily {
    $script:PreparedCatalogCandidate=Select-ItlProductProjectCandidate -ProjectId $CatalogProjectId -ProfileId $CatalogProfileId -RecordPath $CatalogRecordPath -AllowPrompt:$true -Limit $CatalogLimit
    return $script:PreparedCatalogCandidate.context.baseConfigurationVersion
}

function Resolve-ItlProductProjectInitAnswers {
    param([object]$Answers)
    $id=[string](Get-AnswerValue -Answers $Answers -Names @('projectId','catalogProjectId') -Default '')
    $mode=[string](Get-AnswerValue -Answers $Answers -Names @('catalogMode') -Default '')
    if($id -and $mode -eq 'legacy'){throw 'CATALOG_INIT_MODE_CONFLICT: legacy answers cannot also request a catalog project.'}
    $profile=[string](Get-AnswerValue -Answers $Answers -Names @('catalogProfileId','profileId') -Default '')
    if(-not $id){
        $binding=Get-ItlProductProjectBinding
        if($binding){$id=$binding.projectId;$profile=[string](Get-ItlCatalogField $binding 'profileId' '')}
    }
    if(-not $id){throw 'CATALOG_PROJECT_REQUIRED: initialization requires projectId from the published registry. Prepare a missing project separately and repeat the same initialization before native work.'}
    if(-not $script:PreparedCatalogCandidate -or $script:PreparedCatalogCandidate.binding.projectId -cne $id -or [string](Get-ItlCatalogField $script:PreparedCatalogCandidate.binding 'profileId' '') -cne $profile){$script:PreparedCatalogCandidate=Select-ItlProductProjectCandidate -ProjectId $id -ProfileId $profile -AllowPrompt:$false}
    return $script:PreparedCatalogCandidate
}

function Save-ItlProductProjectInitBinding {
    param([object]$Answers)
    if((Get-AnswerValue -Answers $Answers -Names @('catalogMode') -Default 'legacy') -ne 'catalog'){return}
    $candidate=$script:PreparedCatalogCandidate
    if(-not $candidate){throw 'CATALOG_PROJECT_REQUIRED: resolve the selected catalog record before saving initialization settings.'}
    $candidate.context['configurationStage']='binding-only'
    $preferences=ConvertTo-ItlCatalogCanonicalValue $candidate.preferences
    $preferences['catalogRevision']=$candidate.context.catalogRevision
    $state=Read-ItlManagedMcpState
    $owners=ConvertTo-Vibecoding1cMcpHashtable (Get-ItlCatalogField $state 'owners' @{})
    $clients=@(Get-ConfigValue -Path aiRules.tools -Default @()|Where-Object {$_})
    $proofRequests=@(foreach($key in $owners.Keys){
        $parts=([string]$key).Split('/',2)
        if($parts.Count -eq 2 -and $parts[0] -in $clients){@{client=$parts[0];owner=$parts[1];endpoints=@()}}
    })
    $null=Invoke-ItlProductProjectClientApply $candidate.context @() -BindProject -DesiredBinding $candidate.binding -SavePrivateSelection -PrivateSelection $preferences -ProofRequests $proofRequests
    Set-ItlProductProjectOperationContext $candidate.context
}

function Get-ItlProductProjectTransitionSelection {
    param([object]$RecordedSelection=$null)
    if(Get-ItlProductProjectBinding){return $null}
    $select={
        $id=[string](Get-ItlCatalogField $RecordedSelection 'projectId' $CatalogProjectId)
        $profile=[string](Get-ItlCatalogField $RecordedSelection 'profileId' $CatalogProfileId)
        $script:PreparedCatalogCandidate=Select-ItlProductProjectCandidate -ProjectId $id -ProfileId $profile -AllowPrompt:(Test-InteractiveInputAvailable) -Limit $CatalogLimit
        $candidate=$script:PreparedCatalogCandidate
        $family=Get-ConfigValue -Path baseConfigurationVersion -Default ''
        if($family -and $family -cne $candidate.context.baseConfigurationVersion){throw 'CATALOG_PRODUCT_FAMILY_CHANGED: select a published project matching the installed configuration family, then repeat the same transition. No association or database change was applied; preserve any existing update snapshot.'}
        $selection=@{projectId=$candidate.binding.projectId;profileId=(Get-ItlCatalogField $candidate.binding 'profileId' '');catalogRevision=$candidate.context.catalogRevision;settingsHash=$candidate.context.settingsHash}
        if($RecordedSelection -and (Get-ItlCatalogHash $selection) -cne (Get-ItlCatalogHash $RecordedSelection)){
            throw 'CATALOG_TRANSITION_SELECTION_CHANGED: the recorded project or registry settings changed. Preserve the update snapshot; restore/reconcile it through update-workflow, then repeat selection. No new context was applied.'
        }
        return $selection
    }
    Invoke-Vibecoding1cMcpRegistryOperation {
        if($RecordedSelection){
            $revision=[string](Get-ItlCatalogField $RecordedSelection 'catalogRevision' '')
            if($revision -cnotmatch '^(?:[a-f0-9]{40}|[a-f0-9]{64})$'){throw 'CATALOG_TRANSITION_SELECTION_INVALID: preserve the update receipt and recover its exact recorded registry revision through the existing update owner.'}
            $state=(Get-Variable ItlMcpRegistryOperation -Scope Script).Value
            if((Get-ItlCatalogField $state 'catalogAttempted' $false) -and $state.catalogSnapshot.catalogRevision -cne $revision){throw 'CATALOG_TRANSITION_SELECTION_CHANGED: this operation already pinned a different registry revision; preserve its snapshot and repeat through the update recovery owner.'}
            # Reuse the existing operation pin, not whatever tip was published
            # between pre-copy and the fresh child. Original hash guards remain.
            $state['catalogPinnedRevision']=$revision
        }
        if($script:LifecycleOperationIsContinuation -and (Test-InteractiveInputAvailable)){
            . (Join-Path $PSScriptRoot 'agent-1c.product-project-console.ps1')
            Invoke-ItlProductProjectCallerInput -Body $select
        }else{& $select}
    }
}

function Test-ItlProductProjectTransitionSource {
    param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$SourceRoot)
    if(-not $SourceRoot){return $false}
    $path=Join-Path $SourceRoot '.agents/skills/1c-workflow/scripts/lib/agent-1c.product-project-ui.ps1'
    if(-not (Test-Path -LiteralPath $path -PathType Leaf)){return $false}
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput((Read-Utf8Text $path),[ref]$tokens,[ref]$errors)
    if(@($errors).Count){throw 'CATALOG_TRANSITION_SOURCE_INVALID: preserve the installation and restore the exact valid workflow source before repeating the update.'}
    return $null -ne $ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Get-ItlProductProjectTransitionSelection'},$true)
}

function Invoke-ItlProductProjectPostUpdateOffer {
    # Compatibility entry for an older caller: this is now a required
    # association, never a swallowed warning or an accepted "later" outcome.
    if(Get-ItlProductProjectBinding){return}
    $null=Get-ItlProductProjectTransitionSelection
    Invoke-Vibecoding1cMcpRegistryOperation {
        $apply={Invoke-ItlProductProjectAssociation $script:PreparedCatalogCandidate -Decision $CatalogDecision -AllowPrompt:(Test-InteractiveInputAvailable) -IncludeClientSurfaces}
        if($script:LifecycleOperationIsContinuation -and (Test-InteractiveInputAvailable)){
            . (Join-Path $PSScriptRoot 'agent-1c.product-project-console.ps1')
            Invoke-ItlProductProjectCallerInput -Body $apply
        }else{& $apply}
    } | Out-Host
}
