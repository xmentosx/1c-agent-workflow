# Context/client integration belongs to the existing MCP owner.
function Assert-ItlMemoryProvider {
    param([object]$Provider,[string]$ProjectRoot)
    $contract=Read-ItlMemoryJson (Join-Path $PSScriptRoot '../../assets/scoped-memory-policy.json')
    if(-not $Provider -or (Get-ItlCatalogField $Provider 'profile') -cne $contract.profile -or
       (Get-ItlCatalogField $Provider 'qualificationResultSha256') -cne $contract.qualificationResultSha256 -or
       -not (Get-ItlCatalogField $Provider 'instanceId') -or -not (Get-ItlCatalogField $Provider 'principalId') -or
       -not (Get-ItlCatalogField $Provider 'organizationId') -or @((Get-ItlCatalogKeys $Provider)) -cnotcontains 'datasets'){
        throw 'MEMORY_PROFILE_UNQUALIFIED: select the frozen G1 profile and exact ordinary principal; a changed deployment needs capability qualification before enable.'
    }
    $url=$null
    if(-not [uri]::TryCreate([string]$Provider.url,[UriKind]::Absolute,[ref]$url) -or $url.Scheme -notin @('http','https') -or $url.UserInfo -or $url.Query -or $url.Fragment -or $url.AbsolutePath -ne '/') {throw 'MEMORY_ENDPOINT_INVALID'}
    $privateMcpPrefix=[IO.Path]::GetFullPath((Get-Vibecoding1cMcpLocalHome)).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    $project=[IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    $credential=[IO.Path]::GetFullPath([string]$Provider.credentialFile)
    if($privateMcpPrefix.StartsWith($project,[StringComparison]::OrdinalIgnoreCase) -or -not $credential.StartsWith($privateMcpPrefix,[StringComparison]::OrdinalIgnoreCase)){throw 'MEMORY_CREDENTIAL_PRIVATE: use the existing user-local MCP home outside the project, never Git or reset state.'}
    $ids=@{};$labels=@{}
    foreach($entry in @($Provider.datasets)){
        $id=[guid]::Empty
        $admission=Get-ItlCatalogField $entry 'admitted'
        if(-not [guid]::TryParse([string](Get-ItlCatalogField $entry 'datasetId'),[ref]$id) -or -not (Get-ItlCatalogField $entry 'ownerId') -or
           (Get-ItlCatalogField $entry 'scopeKind') -notin @('taskCycle','workspace','workplace','product','project','organization') -or
           -not (Get-ItlCatalogField $entry 'scopeId') -or -not (Get-ItlCatalogField $entry 'label') -or
           $admission -isnot [bool] -or (@($entry.permissions).Count -eq 0 -and $admission) -or @($entry.permissions|Where-Object {$_ -cnotin @('read','write')}).Count){throw 'MEMORY_DATASET_UNVERIFIED'}
        if($ids.ContainsKey($entry.datasetId) -or $labels.ContainsKey($entry.label)){throw 'MEMORY_MAPPING_AMBIGUOUS: exact IDs and labels must each map to one scope.'}
        $ids[$entry.datasetId]=$true;$labels[$entry.label]=$true
    }
}

function Get-ItlMemoryPolicyProof {
    param([string]$Path,[string]$ProjectRoot,[string]$Client='')
    $full=[IO.Path]::GetFullPath($Path);$prefix=[IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if(-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'MEMORY_POLICY_SCOPE: select the installed project-memory rule inside this project.'}
    $text=Read-Utf8Text $full
    $match=[regex]::Match($text,'(?s)<!-- ITL-SCOPED-MEMORY-V1 -->\s*(.*?)\s*<!-- /ITL-SCOPED-MEMORY-V1 -->')
    $contract=Read-ItlMemoryJson (Join-Path $PSScriptRoot '../../assets/scoped-memory-policy.json')
    $manifest=Read-ItlMemoryJson (Join-Path $ProjectRoot '.ai-rules.json') -MaxBytes 4194304
    $lock=Read-ItlMemoryJson (Join-Path $ProjectRoot '.agent-1c/dependency-lock.json')
    $pin=Get-ItlCatalogField (Get-ItlCatalogField $lock 'dependencies') 'aiRules1c'
    $relative=$full.Substring($prefix.Length).Replace('\','/')
    $owned=Get-ItlCatalogField (Get-ItlCatalogField $manifest 'files') $relative
    if(-not (Test-Path -LiteralPath 'Function:\Test-AiRulesFileMatchesInstalledHash')){. (Join-Path $PSScriptRoot 'agent-1c.ai-rules-migration.ps1')}
    if((Get-ItlCatalogField $pin 'commit') -cne $contract.rulesCandidateCommit -or
       (Get-ItlCatalogField $owned 'source') -cne 'content/rules/project-memory.md' -or
       (Get-ItlCatalogField $owned 'userModified' $false) -or
       ($Client -and @($manifest.tools) -cnotcontains $Client) -or
       -not (Test-AiRulesFileMatchesInstalledHash -Path $full -InstalledHash ([string](Get-ItlCatalogField $owned 'installedHash' '')))){
        throw 'MEMORY_POLICY_UNQUALIFIED: use the owner-installed matching fork candidate; retain legacy mode until its manifest/pin and installed rule agree. Do not patch an installed rule.'
    }
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$hash=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($match.Groups[1].Value.Replace("`r`n","`n"))))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
    if(-not $match.Success -or $hash -cne $contract.clauseSha256){throw 'MEMORY_POLICY_UNQUALIFIED: use the compatible controlled-fork candidate and reload; r47 does not enable scoped Cognee. No installed policy was changed.'}
    return @{path=$full;clauseSha256=$contract.clauseSha256;capability='scoped-cognee-memory-v1';sourceCommit=$pin.commit}
}

function Get-ItlMemoryProjection {
    param([object]$Context,[object]$Snapshot)
    if(-not $Snapshot -or $Snapshot.catalogRevision -cne $Context.catalogRevision){throw 'MEMORY_REGISTRY_PROJECTION: use the existing pinned registry operation; do not fetch another catalog.'}
    $rules=[ordered]@{}
    foreach($area in @($Context.knowledgeContext.knowledgeAreas)){
        $rule=Get-ItlCatalogField $Snapshot.relations.knowledgeAreas $area.areaId
        if($rule){$rules[$area.areaId]=ConvertTo-ItlCatalogCanonicalValue $rule}
    }
    $composition=@(Get-ItlCatalogComposition $Snapshot.relations $Context.productId)
    $relations=@($Snapshot.relations.relations|Where-Object {$composition -ccontains $_.productId})
    return @{knowledgeAreas=$rules;composition=$composition;snapshot=@{relations=@{relations=$relations}}}
}

function Sync-ItlMemoryContext {
    param([object]$Context,[object]$Snapshot=$null)
    $path=Get-ItlMemoryPath binding $script:ProjectRoot
    $old=Read-ItlMemoryJson $path
    if(-not $old -or $old.mode -ne 'enabled'){return}
    $state=Read-ItlMemoryJson $old.cycleStatePath
    $cycle=Get-ItlCatalogField $state 'memoryCycle'
    if(-not $cycle -or $cycle.reserved -or (Get-ItlCatalogField $state 'resetStatus') -eq 'resetting'){return}
    if(-not $Context){$applied=Read-ItlMemoryJson $old.appliedPath;if($applied){$Context=$applied.context}}
    if(-not $Context){return}
    $hash=Get-ItlCatalogHash $Context
    if($hash -ceq $old.registryContextHash -and $cycle.current -ceq $old.cycleId){return}
    $projection=$old.memoryProjection
    if($Context.knowledgeHash -cne $old.context.knowledgeHash){$projection=Get-ItlMemoryProjection $Context $Snapshot}
    $null=Update-ItlMemoryJson $path {
        param($current)
        if(-not $current -or $current.mode -ne 'enabled' -or $current.bindingId -cne $old.bindingId){throw 'MEMORY_BINDING_CONFLICT: retain the other owner update and repeat setup.'}
        $current['context']=$Context;$current['registryContextHash']=$hash;$current['memoryProjection']=$projection
        $current['cycleId']=$cycle.current;$current['bindingId']=[guid]::NewGuid().ToString('N')
        return $current
    }
}

function Get-ItlMemoryClientEndpoint {
    param([string]$Client)
    $binding=Read-ItlMemoryJson (Get-ItlMemoryPath binding $script:ProjectRoot)
    if(-not $binding -or $binding.mode -ne 'enabled' -or -not (Get-ItlCatalogField $binding.policyProofs $Client)){return $null}
    try{$null=Get-ItlMemoryPolicyProof $binding.policyProofs[$Client].path $script:ProjectRoot $Client}catch{return $null}
    return [ordered]@{name='itl-scoped-cognee';transport='stdio';command='powershell.exe';args=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $script:Agent1cScriptRoot 'cognee-memory-mcp.ps1'),'-BindingPath',(Get-ItlMemoryPath binding $script:ProjectRoot),'-Client',$Client);env=@{};startupTimeoutSeconds=20;toolTimeoutSeconds=65;owner='itl'}
}

function Invoke-ItlMemorySetup {
    param([ValidateSet('enable','disable','status','checkpoint')][string]$Mode,[string]$SettingsPath='', [string]$PolicyPath='', [string]$Client='', [object]$Checkpoint=$null)
    if($Mode -eq 'enable' -and -not (Get-Variable ItlMcpRegistryOperation -Scope Script -ErrorAction SilentlyContinue)){
        . Import-ItlProductProject
        return Invoke-Vibecoding1cMcpRegistryOperation {
            Invoke-ItlMemorySetup -Mode $Mode -SettingsPath $SettingsPath -PolicyPath $PolicyPath -Client $Client -Checkpoint $Checkpoint
        }
    }
    $bindingPath=Get-ItlMemoryPath binding $script:ProjectRoot
    if($Mode -eq 'status'){
        $binding=Read-ItlMemoryJson $bindingPath
        if(-not $binding){return @{mode='legacy';memoryEnabled=$false;continuation='Optional: associate a project, then explicitly enable qualified scoped memory.'}}
        return @{mode=$binding.mode;context=(Get-ItlMemoryLocalContext $binding);readiness='native/tool-catalog unverified until actual scoped calls; configuration is not live acceptance'}
    }
    if($Mode -eq 'disable'){
        if(Test-Path -LiteralPath $bindingPath){$null=Update-ItlMemoryJson $bindingPath {param($old) $old['mode']='disabled';$old['bindingId']=[guid]::NewGuid().ToString('N');return $old}}
        Write-Vibecoding1cMcpClientConfig -Client $Client
        return @{mode='disabled';datasetsPreserved=$true;continuation='Reload the client. Private pending/receipts and External MCP remain owned and preserved.'}
    }
    if($Mode -eq 'checkpoint'){
        $binding=Read-ItlMemoryJson $bindingPath;Assert-ItlMemoryBindingCurrent $binding
        if([Text.Encoding]::UTF8.GetByteCount((ConvertTo-Json $Checkpoint -Depth 10 -Compress)) -gt 4096){throw 'MEMORY_CHECKPOINT_TOO_LARGE: retain references/next step, not a transcript.'}
        $value=[ordered]@{schemaVersion=1;projectId=$binding.context.projectId;cycleId=$binding.cycleId;goal=(Get-ItlCatalogField $Checkpoint 'goal' '');constraints=(Get-ItlCatalogField $Checkpoint 'constraints' @());nextStep=(Get-ItlCatalogField $Checkpoint 'nextStep' '');proofs=(Get-ItlCatalogField $Checkpoint 'proofs' @())}
        return (Update-ItlMemoryJson (Get-ItlMemoryPath continuation $binding.identity.workspaceId) {param($old) return $value})
    }
    if(-not $SettingsPath -or -not $PolicyPath -or -not $Client){throw 'MEMORY_OPT_IN_INPUT: provide one private ordinary-user settings file, installed qualified policy and client; no per-scope wizard or automatic enable.'}
    $provider=Read-ItlMemoryJson $SettingsPath
    Assert-ItlMemoryProvider $provider $script:ProjectRoot
    if([Environment]::GetEnvironmentVariable('TOOL_COGNEE','Process') -eq 'off' -or (Get-ItlCatalogField $provider 'toolPolicy' 'auto') -eq 'off'){throw 'MEMORY_TOOL_OFF'}
    $policy=Get-ItlMemoryPolicyProof $PolicyPath $script:ProjectRoot $Client
    . Import-ItlProductProject
    $context=Get-ItlProductProjectOperationContext
    $applied=Read-ItlProductProjectRecord applied
    if(-not $context){if($applied){$context=$applied.context}else{throw 'MEMORY_ASSOCIATION_REQUIRED: select/apply a registry project first; memory setup does not select it again.'}}
    if(-not $applied -or $applied.contextHash -cne (Get-ItlCatalogHash $context)){throw 'MEMORY_APPLIED_CONTEXT_REQUIRED: finish the existing catalog apply/recovery before memory opt-in.'}
    $operation=Get-Variable ItlMcpRegistryOperation -Scope Script -ErrorAction SilentlyContinue
    $snapshot=if($operation){Get-ItlCatalogField $operation.Value 'catalogSnapshot'}else{$null}
    if(-not $snapshot){
        # Hydrate the validated applied revision through its existing owner.
        # Explicit memory opt-in must not refresh or substitute the latest tip.
        Set-ItlProductProjectAppliedContext -Applied $applied
        $snapshot=Get-ItlCatalogField $operation.Value 'catalogSnapshot'
    }
    if(-not $snapshot){throw 'MEMORY_REGISTRY_PROJECTION: run explicit setup under the existing pinned catalog operation; memory does not fetch.'}
    $projection=Get-ItlMemoryProjection $context $snapshot
    $branch=Read-DevBranchState -Name $DevBranchName
    Assert-CurrentProjectRootMatchesDevBranchState $branch 'memory-enable'
    $identity=Get-ItlMemoryWorkspace $script:ProjectRoot $provider.principalId
    $updates=Get-ItlMemoryCycleUpdates $branch initial $identity.workspaceId
    if((Get-ItlCatalogField $branch 'resetStatus') -eq 'resetting'){throw 'MEMORY_CYCLE_UNAVAILABLE: finish the existing reset before enabling its task scope.'}
    # Existing lifecycle writer owns initial allocation without reset/init/1C.
    if((Get-ItlCatalogHash (Get-ItlCatalogField $branch 'memoryCycle')) -cne (Get-ItlCatalogHash $updates.memoryCycle)){Update-DevBranchState -State $branch -Updates $updates;$branch=Read-DevBranchState -Name $DevBranchName}
    $old=Read-ItlMemoryJson $bindingPath
    $reservations=[ordered]@{}
    if($old -and $old.provider.instanceId -ceq $provider.instanceId -and $old.identity.developerId -ceq $provider.principalId){
        # Retain confirmed lazy private IDs across disable/enable. Shared mapping
        # remains the explicit operator input, not inferred from old labels.
        $private=@($old.provider.datasets|Where-Object scopeKind -In @('taskCycle','workspace','workplace'))
        $providedPrivate=@($provider.datasets|Where-Object scopeKind -In @('taskCycle','workspace','workplace'))
        $privateLabels=@($private|ForEach-Object {$_.label})
        $private=@(foreach($entry in $private){$explicit=@($providedPrivate|Where-Object label -CEQ $entry.label);if($explicit.Count){$explicit}else{$entry}})+@($providedPrivate|Where-Object {$privateLabels -cnotcontains $_.label})
        $provider.datasets=@($provider.datasets|Where-Object scopeKind -NotIn @('taskCycle','workspace','workplace'))+$private
        $reservations=Get-ItlCatalogField $old 'datasetReservations' ([ordered]@{})
    }
    Assert-ItlMemoryProvider $provider $script:ProjectRoot
    $proofs=if($old){ConvertTo-ItlCatalogCanonicalValue (Get-ItlCatalogField $old 'policyProofs' ([ordered]@{}))}else{[ordered]@{}};$proofs[$Client]=$policy
    $binding=[ordered]@{schemaVersion=1;capability='scoped-cognee-memory-v1';mode='enabled';bindingId=[guid]::NewGuid().ToString('N');projectRoot=$script:ProjectRoot;identity=$identity;cycleId=$branch.memoryCycle.current;cycleStatePath=$branch.statePath;appliedPath=(Get-ItlProductProjectPath applied);registryContextHash=$applied.contextHash;context=$context;memoryProjection=$projection;provider=$provider;policyProofs=$proofs;datasetReservations=$reservations}
    Assert-ItlMemoryPrincipal $binding ([DateTime]::UtcNow.AddSeconds(20))
    $null=Update-ItlMemoryJson $bindingPath {param($current) if((Get-ItlCatalogHash $current) -cne (Get-ItlCatalogHash $old)){throw 'MEMORY_BINDING_CONFLICT'};return $binding}
    # The same client plan/receipts/conflict/restore owner writes this endpoint.
    Write-Vibecoding1cMcpClientConfig -Client $Client
    return @{mode='configured';workspaceId=$identity.workspaceId;cycleId=$binding.cycleId;nativeReadiness='principal verified; scopes/write/tool-catalog require their actual calls';continuation='Reload the client and call memory_status; configured is not installed G5 acceptance.'}
}
