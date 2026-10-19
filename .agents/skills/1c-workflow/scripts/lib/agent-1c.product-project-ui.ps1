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
    $raw=Read-ItlProductProjectSnapshot
    $preferences=ConvertTo-Vibecoding1cMcpHashtable (Read-ItlProductProjectSetting selection)
    $effective=Get-ItlProductProjectEffectiveSnapshot $raw $preferences
    if(-not $ProjectId){
        if(-not $AllowPrompt){throw 'CATALOG_PROJECT_REQUIRED: select/create the project before unattended initialization; no association or defer was inferred.'}
        Get-ItlProductProjectChoices $effective.snapshot projects $Limit|Format-Table|Out-Host
        $ProjectId=Read-InitRequired 'Project ID (or new)'
    }
    if($ProjectId -eq 'new'){
        if($ReadOnly){throw 'CATALOG_PREVIEW_READ_ONLY: use catalog create/select explicitly before previewing a new record.'}
        $created=New-ItlProductProjectDraft $effective.snapshot -RecordPath $RecordPath -AllowPrompt:$AllowPrompt -Limit $Limit
        $ProjectId=$created.recordId
        $raw=Read-ItlProductProjectSnapshot
        $preferences=ConvertTo-Vibecoding1cMcpHashtable (Read-ItlProductProjectSetting selection)
        $effective=Get-ItlProductProjectEffectiveSnapshot $raw $preferences
    }
    $project=Get-ItlCatalogRecord $effective.snapshot.catalog projects $ProjectId
    if(-not $project){throw "CATALOG_PROJECT_UNKNOWN: '$ProjectId' is absent from the validated catalog and retained local drafts."}
    $product=Get-ItlCatalogRecord $effective.snapshot.catalog products $project.productId
    $family=Get-ItlCatalogField $product 'baseConfigurationVersion'
    if(-not $family){
        if(-not $AllowPrompt -or $ReadOnly){throw 'CATALOG_PRODUCT_FAMILY_REQUIRED: complete the selected product metadata before unattended initialization; PM4/PM5 is never inferred from its ID or name.'}
        $product=ConvertTo-ItlCatalogCanonicalValue $product;$product['baseConfigurationVersion']=Read-InitBaseConfigurationVersion
        $null=Save-ItlProductProjectDraft $raw products $product
        $raw=Read-ItlProductProjectSnapshot;$preferences=ConvertTo-Vibecoding1cMcpHashtable (Read-ItlProductProjectSetting selection);$effective=Get-ItlProductProjectEffectiveSnapshot $raw $preferences
    }
    $binding=[ordered]@{schemaVersion=1;requiredCapability='product-project-registry-v1';projectId=$ProjectId;productId=$project.productId}
    if($ProfileId){$binding['profileId']=$ProfileId}
    $context=Resolve-ItlProductProjectRuntimeContext $effective.snapshot $binding -Overrides (Get-ItlCatalogField $preferences 'overrides' @{}) -Conditions (ConvertTo-Agent1cHashtable (Get-ItlCatalogField $preferences 'conditionValues' @{})) -ProductVersion (Get-ItlCatalogField $preferences 'productVersion' '')
    $context['registryMetadata']=$raw.registry;$context['catalogPublication']=$effective.publication
    return [pscustomobject]@{binding=$binding;context=$context;preferences=$preferences}
}

function Invoke-ItlProductProjectAssociation {
    param([object]$Candidate,[string]$Decision='', [bool]$AllowPrompt=$false)
    $family=Get-ConfigValue -Path baseConfigurationVersion -Default ''
    if($family -and $family -cne $Candidate.context.baseConfigurationVersion){throw 'CATALOG_PRODUCT_FAMILY_CHANGED: association cannot change the current configuration family, initialize or reset the database.'}
    $clients=@(Get-ConfigValue -Path aiRules.tools -Default @()|Where-Object {$_}|Select-Object -Unique)
    if(-not $clients.Count){$clients=@(Get-ItlActiveClient)}
    $preview=New-ItlProductProjectPreview $Candidate.context $clients
    if($AllowPrompt){Show-ItlProductProjectPreview $preview|Format-List|Out-Host}
    $chosen=Resolve-ItlProductProjectPreviewDecision $preview -Decision $Decision -AllowPrompt:$AllowPrompt
    if(-not $chosen.preferences.Contains('memoryOptIn')){$chosen.preferences['memoryOptIn']=$false}
    $result=Invoke-ItlProductProjectClientApply $chosen.context $chosen.requests -BindProject -DesiredBinding $Candidate.binding -SavePrivateSelection -PrivateSelection $chosen.preferences -ExpectedInputStates $preview.plan.fileStates -ExpectedOwnerState $preview.plan.ownerState -ProofRequests $chosen.proofRequests
    Set-ItlProductProjectOperationContext $chosen.context
    return [pscustomobject]@{status=$result.status;projectId=$Candidate.binding.projectId;productId=$Candidate.binding.productId;publication=$Candidate.context.catalogPublication.state;activeClientContext='unverified';memorySetup='separate-opt-in'}
}

function Invoke-ItlProductProjectCommand {
    param([ValidateSet('list','preview','select','create','sync','context')][string]$Mode,[string]$ProjectId='', [string]$ProfileId='', [string]$RecordPath='', [string]$Decision='', [int]$Limit=10,[bool]$AllowPrompt=$false)
    if($Mode -eq 'context'){
        $applied=Read-ItlProductProjectRecord applied
        if(-not $applied){return [pscustomobject]@{status='unbound';continuation='Use catalog select/preview explicitly.'}}
        $context=$applied.context
        $integrationDefaults=@{mantisSearch=(Get-ItlProductProjectIntegrationIntent $context mantis-search);mantisCreateRoutes=(Get-ItlCatalogField (Get-ItlCatalogField (Get-ItlCatalogField $context.links 'mantis') 'value') 'createRoutes' @{});sppr=(Get-ItlProductProjectIntegrationIntent $context sppr-exact)}
        return [pscustomobject]@{project=$context.projectName;projectId=$context.projectId;product=$context.productName;productId=$context.productId;catalogRevision=$applied.catalogRevision;publication=(Get-ItlCatalogField $context 'catalogPublication');roles=@($context.roles.Keys|ForEach-Object {@{role=$_;mode=$context.roles[$_].mode;resolution=$context.roles[$_].resolution;sourceId=(Get-ItlCatalogField $context.roles[$_].source 'sourceId');nativeReadiness='unverified'}});links=$context.links;integrationDefaults=$integrationDefaults;nativeRoleOverrides=(Get-ItlCatalogField $context 'nativeRoleOverrides' @{});clientOverrideCount=@(Get-ItlCatalogKeys (Get-ItlCatalogField $context 'nativeClientOverrides' @{})).Count;activeClientContext='unverified'}
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
    if(-not $id -and $mode -ne 'catalog'){return $null} # Explicit legacy JSON/config route remains compatible.
    if($mode -eq 'legacy'){throw 'CATALOG_INIT_MODE_CONFLICT: legacy answers cannot also request a catalog project.'}
    if(-not $id){throw 'CATALOG_PROJECT_REQUIRED: catalog initialization requires an explicit project ID before unattended work.'}
    $profile=[string](Get-AnswerValue -Answers $Answers -Names @('catalogProfileId','profileId') -Default '')
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
    if(-not $preferences.Contains('memoryOptIn')){$preferences['memoryOptIn']=$false}
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

function Invoke-ItlProductProjectPostUpdateOffer {
    # The updater has already completed its package receipt and commit. A
    # separate association outcome must never turn that success into failure.
    if((Get-ItlProductProjectBinding) -or -not (Test-InteractiveInputAvailable)){return}
    $preferences=Read-ItlProductProjectSetting selection
    if((Get-ItlCatalogField $preferences 'associationOffer') -eq 'later'){return}
    try{
        $answer=[string](Read-InitOptional 'Workflow updated. Associate this local project with the catalog: choose / new / later (empty keeps it unchanged)')
        switch($answer.Trim().ToLowerInvariant()){
            'later' {
                $desired=ConvertTo-Vibecoding1cMcpHashtable $preferences;$desired['associationOffer']='later'
                Set-ItlProductProjectSetting selection $desired $preferences
                Write-Host 'Package update completed; catalog association explicitly deferred. Use catalog select when ready.'
            }
            'choose' {Invoke-ItlProductProjectCommand select -AllowPrompt:$true}
            'new' {Invoke-ItlProductProjectCommand select -ProjectId new -AllowPrompt:$true}
            default {Write-Host 'Package update completed; catalog association unchanged. No consent or defer was recorded.'}
        }
    }catch{Write-Warning ('Package update completed; catalog association needs a separate continuation: '+$_.Exception.Message)}
}
