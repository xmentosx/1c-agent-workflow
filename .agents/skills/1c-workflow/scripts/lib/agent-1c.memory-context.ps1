# Context/client integration belongs to the existing MCP owner.
function Assert-ItlMemoryProvider {
    param([object]$Provider,[string]$ProjectRoot)
    $contract=Read-ItlMemoryJson (Join-Path $PSScriptRoot '../../assets/scoped-memory-policy.json')
    $additionalProfiles=Get-ItlCatalogField $contract 'additionalQualifiedProfiles' @()
    $profiles=@(@{profile=$contract.profile;qualificationResultSha256=$contract.qualificationResultSha256})+@($additionalProfiles)
    $matchingProfiles=@($profiles|Where-Object {
        (Get-ItlCatalogField $_ 'profile') -ceq (Get-ItlCatalogField $Provider 'profile') -and
        (Get-ItlCatalogField $_ 'qualificationResultSha256') -ceq (Get-ItlCatalogField $Provider 'qualificationResultSha256')
    })
    if(-not $Provider -or $matchingProfiles.Count -ne 1 -or
       -not (Get-ItlCatalogField $Provider 'instanceId') -or -not (Get-ItlCatalogField $Provider 'principalId') -or
       -not (Get-ItlCatalogField $Provider 'organizationId') -or @((Get-ItlCatalogKeys $Provider)) -cnotcontains 'datasets'){
        throw 'MEMORY_PROFILE_UNQUALIFIED: select an explicitly qualified common profile and exact ordinary principal; a changed deployment needs capability qualification before enable.'
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
           (Get-ItlCatalogField $entry 'scopeKind') -notin @('taskCycle','workspace','workplace','host','product','project','organization') -or
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

function Test-ItlMemoryIdentityComplete {
    param([object]$Identity)
    $keys=@(Get-ItlCatalogKeys $Identity)
    return ($keys -ccontains 'localProjectId' -and $keys -ccontains 'hostId')
}

function Sync-ItlMemoryContext {
    param([object]$Context,[object]$Snapshot=$null)
    $path=Get-ItlMemoryPath binding $script:ProjectRoot
    $old=Read-ItlMemoryJson $path
    if(-not $old -or $old.mode -ne 'enabled'){return}
    $state=Read-ItlMemoryJson $old.cycleStatePath -Kind 'branch-state'
    $cycle=Get-ItlCatalogField $state 'memoryCycle'
    if(-not $cycle -or $cycle.reserved -or (Get-ItlCatalogField $state 'resetStatus') -eq 'resetting'){return}
    if(-not $Context){$applied=Read-ItlMemoryAppliedContext $old.appliedPath;if($applied){$Context=$applied.context}}
    if(-not $Context){return}
    $hash=Get-ItlCatalogHash $Context
    # A binding of the previous workflow has no local-project/host identity.
    # Its owner extends it in place before the unchanged-context exit below;
    # the format version stays 1 so a rolled-back helper still reads it.
    $extend=-not (Test-ItlMemoryIdentityComplete $old.identity)
    $hostId=[string](Get-ItlCatalogField $old.identity 'hostId' '')
    if(-not $hostId){$hostId=Get-ItlMemoryHostId}
    $fillHost=-not $extend -and $hostId -and -not (Get-ItlCatalogField $old.identity 'hostId' '')
    if($hash -ceq $old.registryContextHash -and $cycle.current -ceq $old.cycleId -and -not $extend -and -not $fillHost){return}
    $localProjectId=[string](Get-ItlCatalogField $old.identity 'localProjectId' '')
    if(-not $localProjectId){
        $mainRoot=[string](Get-ItlCatalogField $state 'mainWorktreePath' '')
        $localProjectId=if($mainRoot){Get-ItlMemoryRootId $mainRoot}else{[string]$old.identity.workspaceId}
    }
    $projection=$old.memoryProjection
    if($Context.knowledgeHash -cne $old.context.knowledgeHash){$projection=Get-ItlMemoryProjection $Context $Snapshot}
    # A new bindingId is issued only for a new task cycle, another project or
    # product, and once for the identity extension: that one refusal makes a
    # server process of the previous workflow reload. Everything else (rules,
    # policy proof, settings, knowledge areas) is updated in place and picked
    # up by the running server, which rereads this record before each call.
    $rotate=$extend -or $cycle.current -cne $old.cycleId -or $Context.projectId -cne $old.context.projectId -or $Context.productId -cne $old.context.productId
    $null=Update-ItlMemoryJson $path {
        param($current)
        if(-not $current -or $current.mode -ne 'enabled' -or $current.bindingId -cne $old.bindingId){throw 'MEMORY_BINDING_CONFLICT: retain the other owner update and repeat setup.'}
        $current['context']=$Context;$current['registryContextHash']=$hash;$current['memoryProjection']=$projection
        $current['cycleId']=$cycle.current
        $current.identity['localProjectId']=$localProjectId;$current.identity['hostId']=$hostId
        if($rotate){$current['bindingId']=[guid]::NewGuid().ToString('N')}
        return $current
    }
}

function Resolve-ItlMemoryLiveBinding {
    param([object]$Held,[object]$Live)
    # The memory server rereads its one private binding before each call. The
    # same bindingId is an in-place owner update. Another bindingId of the same
    # working copy is followed, and the caller is told; a cycle or project
    # change additionally holds the first write until memory_status.
    if(-not $Live){throw 'MEMORY_STALE_CONTEXT: the binding record is gone; run the explicit memory setup and reload the client.'}
    if((Get-ItlCatalogField $Live 'schemaVersion') -ne 1 -or (Get-ItlCatalogField $Live 'capability') -cne 'scoped-cognee-memory-v1'){
        throw 'MEMORY_BINDING_UNSUPPORTED: reload the client; this memory server predates the installed binding format.'
    }
    if($Live.bindingId -ceq $Held.bindingId){return @{binding=$Live;contextChanged=$null;holdWrites=$false}}
    if([string]$Live.projectRoot -ine [string]$Held.projectRoot -or $Live.identity.workspaceId -cne $Held.identity.workspaceId){
        throw 'MEMORY_STALE_CONTEXT: this client holds the binding of another working copy; reload it.'
    }
    if($Live.mode -ne 'enabled'){throw 'MEMORY_DISABLED: use the explicit memory setup; ordinary workflow remains available.'}
    $state=Read-ItlMemoryJson $Live.cycleStatePath -Kind 'branch-state'
    $cycle=Get-ItlCatalogField $state 'memoryCycle'
    if(-not $cycle -or (Get-ItlCatalogField $cycle 'reserved') -or (Get-ItlCatalogField $state 'resetStatus') -eq 'resetting'){
        throw 'MEMORY_STALE_CONTEXT: a branch reset is in progress; repeat the call after the lifecycle operation completes.'
    }
    $cycleChanged=$Live.cycleId -cne $Held.cycleId;$projectChanged=$Live.context.projectId -cne $Held.context.projectId
    $reason=if($cycleChanged){'cycle'}elseif($projectChanged){'project'}elseif($Live.context.productId -cne $Held.context.productId){'product'}else{'binding'}
    $hold=$cycleChanged -or $projectChanged
    $changed=[ordered]@{reason=$reason;previousCycleId=[string]$Held.cycleId;cycleId=[string]$Live.cycleId;projectId=[string]$Live.context.projectId}
    $changed['continuation']=if($hold){'This session now reads the new context. The first write is refused until memory_status: call it, then repeat remember only if the fact belongs to the new context.'}else{'This session now uses the updated binding; no action is needed.'}
    return @{binding=$Live;contextChanged=$changed;holdWrites=$hold}
}

function Get-ItlMemoryClientEndpoint {
    param([string]$Client)
    $binding=Read-ItlMemoryJson (Get-ItlMemoryPath binding $script:ProjectRoot)
    if($binding -and $binding.mode -eq 'enabled' -and -not (Test-ItlMemoryIdentityComplete $binding.identity)){
        # Every owner rewrite of the client configuration, update-workflow
        # included, extends a binding of the previous workflow once.
        try{Sync-ItlMemoryContext -Context $null;$binding=Read-ItlMemoryJson (Get-ItlMemoryPath binding $script:ProjectRoot)}catch{}
    }
    if(-not $binding -or $binding.mode -ne 'enabled' -or -not (Get-ItlCatalogField $binding.policyProofs $Client)){return $null}
    try{$null=Get-ItlMemoryPolicyProof $binding.policyProofs[$Client].path $script:ProjectRoot $Client}catch{return $null}
    return [ordered]@{name='itl-scoped-cognee';transport='stdio';command='powershell.exe';args=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $script:Agent1cScriptRoot 'cognee-memory-mcp.ps1'),'-BindingPath',(Get-ItlMemoryPath binding $script:ProjectRoot),'-Client',$Client);env=@{};startupTimeoutSeconds=20;toolTimeoutSeconds=65;owner='itl'}
}

function Invoke-ItlMemorySetup {
    param([ValidateSet('auto','enable','disable','status','checkpoint')][string]$Mode,[string]$SettingsPath='', [string]$PolicyPath='', [string]$Client='', [object]$Checkpoint=$null)
    $bindingPath=Get-ItlMemoryPath binding $script:ProjectRoot
    $commonSettings=Join-Path (Get-ItlMemoryHome) 'provider.json'
    if($Mode -eq 'auto'){
        # Called only by explicit association / completion of a new init, never Startup.
        try{
            $old=Read-ItlMemoryJson $bindingPath
            if((Get-ItlMemoryToolPolicy) -eq 'off' -or ($old -and $old.mode -eq 'disabled')){
                return @{mode='disabled';preference='off';memoryEnabled=$false}
            }
            . Import-ItlProductProject
            $applied=Read-ItlProductProjectRecord applied
            if(-not $applied -or (Get-ItlCatalogField $applied 'configurationState') -ne 'configured'){throw 'MEMORY_APPLIED_CONTEXT_REQUIRED'}
            $selection=Read-ItlProductProjectSetting selection
            if((Get-ItlCatalogField $selection 'memoryEnabled') -ceq $false){return @{mode='disabled';preference='off';memoryEnabled=$false}}
            if(@(Get-ItlCatalogKeys $selection) -ccontains 'memoryOptIn' -and -not (Get-ItlCatalogField $selection 'memoryOptIn') -and -not $old){
                throw 'MEMORY_LEGACY_PREFERENCE_UNRESOLVED: use explicit setup; an old automatic default is not a proven user refusal.'
            }
            if(-not $SettingsPath){$SettingsPath=$commonSettings}
            if(-not (Test-Path -LiteralPath $SettingsPath -PathType Leaf)){throw 'MEMORY_CONNECTION_UNCONFIGURED'}
            if(-not $Client){$Client=Get-ItlActiveClient}
            $inputProvider=Read-ItlMemoryJson $SettingsPath
            if((Get-ItlMemoryToolPolicy $inputProvider) -eq 'off'){
                if($old -and $old.mode -eq 'enabled'){return Invoke-ItlMemorySetup disable -Client $Client}
                return @{mode='disabled';preference='off';memoryEnabled=$false}
            }
            if(-not $PolicyPath){
                if(-not (Test-Path -LiteralPath 'Function:\Get-ItlClientAdapter')){. (Join-Path $PSScriptRoot 'agent-1c.client-adapters.ps1')}
                $manifest=Read-ItlMemoryJson (Join-Path $script:ProjectRoot '.ai-rules.json') -MaxBytes 4194304
                $rules=([string](Get-ItlClientAdapter -Client $Client).rulesPath).TrimEnd('/')+'/'
                $paths=@(Get-ItlCatalogKeys (Get-ItlCatalogField $manifest 'files')|Where-Object {
                    $_.Replace('\','/').StartsWith($rules,[StringComparison]::OrdinalIgnoreCase) -and
                    (Get-ItlCatalogField (Get-ItlCatalogField $manifest.files $_) 'source') -ceq 'content/rules/project-memory.md'
                })
                if($paths.Count -ne 1){throw 'MEMORY_POLICY_UNQUALIFIED'}
                $PolicyPath=Join-Path $script:ProjectRoot $paths[0]
            }
            if($old -and $old.mode -eq 'enabled' -and -not (Test-ItlMemoryIdentityComplete $old.identity)){
                # Extend a binding of the previous workflow before the
                # unchanged-configuration exit below.
                Sync-ItlMemoryContext -Context $null;$old=Read-ItlMemoryJson $bindingPath
            }
            if($old -and $old.mode -eq 'enabled' -and $old.registryContextHash -ceq $applied.contextHash -and (Get-ItlCatalogField $old 'settingsHash') -ceq (Get-ItlCatalogHash $inputProvider) -and (Get-ItlCatalogField $old.policyProofs $Client)){
                $null=Get-ItlMemoryPolicyProof $PolicyPath $script:ProjectRoot $Client
                return @{mode='configured';preference='on';nativeReadiness='unverified until actual client calls'}
            }
            return Invoke-ItlMemorySetup enable -SettingsPath $SettingsPath -PolicyPath $PolicyPath -Client $Client
        }catch{
            $code=($_.Exception.Message -split ':')[0]
            if($code -cnotmatch '^(MEMORY|CATALOG|CLIENT_MCP)_[A-Z_]+$'){$code='MEMORY_SETUP_UNAVAILABLE'}
            return @{mode=$(if($code -eq 'MEMORY_TOOL_OFF'){'disabled'}else{'unavailable'});preference=$(if($code -eq 'MEMORY_TOOL_OFF'){'off'}else{'on'});reason=$code;memoryEnabled=$false;continuation='Use the existing memory setup/reload or pinned resume/owned restore. Independent catalog work remains available.'}
        }
    }
    if($Mode -eq 'enable' -and -not (Get-Variable ItlMcpRegistryOperation -Scope Script -ErrorAction SilentlyContinue)){
        . Import-ItlProductProject
        return Invoke-Vibecoding1cMcpRegistryOperation {
            Invoke-ItlMemorySetup -Mode $Mode -SettingsPath $SettingsPath -PolicyPath $PolicyPath -Client $Client -Checkpoint $Checkpoint
        }
    }
    $bindingPath=Get-ItlMemoryPath binding $script:ProjectRoot
    if($Mode -eq 'status'){
        $binding=Read-ItlMemoryJson $bindingPath
        if((Get-ItlMemoryToolPolicy (Get-ItlCatalogField $binding 'provider')) -eq 'off'){return @{mode='disabled';preference='off';memoryEnabled=$false;datasetsPreserved=$true}}
        if(-not $binding){return @{mode='unconfigured';preference='on';memoryEnabled=$false;continuation='Associate a project and configure the common qualified connection through setup; status performs no enrollment.'}}
        if($binding.mode -eq 'disabled'){return @{mode='disabled';preference='off';memoryEnabled=$false;datasetsPreserved=$true}}
        # The call journal is read-only here; a damaged journal never hides status.
        $usage=try{Get-ItlMemoryUsageSummary $binding}catch{@{unavailable=($_.Exception.Message -split ':')[0]}}
        return @{mode=$binding.mode;context=(Get-ItlMemoryLocalContext $binding);usage=$usage;readiness='native/tool-catalog unverified until actual scoped calls; configuration is not live acceptance'}
    }
    if($Mode -eq 'disable'){
        $null=Update-ItlMemoryJson $bindingPath {param($old)
            if(-not $old){$old=@{schemaVersion=1;projectRoot=$script:ProjectRoot;provider=@{instanceId=''};identity=@{developerId=''};policyProofs=@{};datasetReservations=@{}}}
            $old['mode']='disabled';$old['bindingId']=[guid]::NewGuid().ToString('N');return $old
        }
        Write-Vibecoding1cMcpClientConfig -Client $Client
        return @{mode='disabled';datasetsPreserved=$true;continuation='Reload the client. Private pending/receipts and External MCP remain owned and preserved.'}
    }
    if($Mode -eq 'checkpoint'){
        $binding=Read-ItlMemoryJson $bindingPath;Assert-ItlMemoryBindingCurrent $binding
        if([Text.Encoding]::UTF8.GetByteCount((ConvertTo-Json $Checkpoint -Depth 10 -Compress)) -gt 4096){throw 'MEMORY_CHECKPOINT_TOO_LARGE: retain references/next step, not a transcript.'}
        $value=[ordered]@{schemaVersion=1;projectId=$binding.context.projectId;cycleId=$binding.cycleId;goal=(Get-ItlCatalogField $Checkpoint 'goal' '');constraints=(Get-ItlCatalogField $Checkpoint 'constraints' @());nextStep=(Get-ItlCatalogField $Checkpoint 'nextStep' '');proofs=(Get-ItlCatalogField $Checkpoint 'proofs' @())}
        return (Update-ItlMemoryJson (Get-ItlMemoryPath continuation $binding.identity.workspaceId) {param($old) return $value})
    }
    if(-not $SettingsPath -or -not $PolicyPath -or -not $Client){throw 'MEMORY_SETUP_INPUT: provide the common ordinary-user settings, qualified installed policy and client; no per-scope wizard.'}
    $provider=Read-ItlMemoryJson $SettingsPath
    Assert-ItlMemoryProvider $provider $script:ProjectRoot
    $commonProvider=ConvertTo-ItlCatalogCanonicalValue $provider
    if((Get-ItlMemoryToolPolicy $provider) -eq 'off'){throw 'MEMORY_TOOL_OFF'}
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
    # The lifecycle branch record already names the main copy of a branch copy.
    $identity=Get-ItlMemoryWorkspace $script:ProjectRoot $provider.principalId -MainRoot ([string](Get-ItlCatalogField $branch 'mainWorktreePath' ''))
    $updates=Get-ItlMemoryCycleUpdates $branch initial $identity.workspaceId
    if((Get-ItlCatalogField $branch 'resetStatus') -eq 'resetting'){throw 'MEMORY_CYCLE_UNAVAILABLE: finish the existing reset before enabling its task scope.'}
    # Existing lifecycle writer owns initial allocation without reset/init/1C.
    if((Get-ItlCatalogHash (Get-ItlCatalogField $branch 'memoryCycle')) -cne (Get-ItlCatalogHash $updates.memoryCycle)){Update-DevBranchState -State $branch -Updates $updates;$branch=Read-DevBranchState -Name $DevBranchName}
    $old=Read-ItlMemoryJson $bindingPath
    $reservations=[ordered]@{}
    if($old -and $old.provider.instanceId -ceq $provider.instanceId -and $old.identity.developerId -ceq $provider.principalId){
        # Retain confirmed lazy private IDs across disable/enable. Shared mapping
        # remains the explicit operator input, not inferred from old labels.
        $privateKinds=@('taskCycle','workspace','workplace','host')
        $private=@($old.provider.datasets|Where-Object scopeKind -In $privateKinds)
        $providedPrivate=@($provider.datasets|Where-Object scopeKind -In $privateKinds)
        $privateLabels=@($private|ForEach-Object {$_.label})
        $private=@(foreach($entry in $private){$explicit=@($providedPrivate|Where-Object label -CEQ $entry.label);if($explicit.Count){$explicit}else{$entry}})+@($providedPrivate|Where-Object {$privateLabels -cnotcontains $_.label})
        $provider.datasets=@($provider.datasets|Where-Object scopeKind -NotIn $privateKinds)+$private
        $reservations=Get-ItlCatalogField $old 'datasetReservations' ([ordered]@{})
    }
    Assert-ItlMemoryProvider $provider $script:ProjectRoot
    $proofs=if($old){ConvertTo-ItlCatalogCanonicalValue (Get-ItlCatalogField $old 'policyProofs' ([ordered]@{}))}else{[ordered]@{}};$proofs[$Client]=$policy
    # Repeating enable for the same copy, cycle, project and product keeps the
    # bindingId: a running server follows the in-place update. A disabled or
    # not yet extended binding gets a new one.
    $sameBinding=$old -and $old.mode -eq 'enabled' -and (Test-ItlMemoryIdentityComplete $old.identity) -and $old.identity.workspaceId -ceq $identity.workspaceId -and
        $old.cycleId -ceq $branch.memoryCycle.current -and $old.context.projectId -ceq $context.projectId -and $old.context.productId -ceq $context.productId
    $bindingId=if($sameBinding){[string]$old.bindingId}else{[guid]::NewGuid().ToString('N')}
    $binding=[ordered]@{schemaVersion=1;capability='scoped-cognee-memory-v1';mode='enabled';bindingId=$bindingId;projectRoot=$script:ProjectRoot;identity=$identity;cycleId=$branch.memoryCycle.current;cycleStatePath=$branch.statePath;appliedPath=(Get-ItlProductProjectPath applied);registryContextHash=$applied.contextHash;context=$context;memoryProjection=$projection;provider=$provider;settingsHash=(Get-ItlCatalogHash $commonProvider);policyProofs=$proofs;datasetReservations=$reservations}
    Assert-ItlMemoryPrincipal $binding ([DateTime]::UtcNow.AddSeconds(20))
    if([IO.Path]::GetFullPath($SettingsPath) -ine [IO.Path]::GetFullPath($commonSettings)){
        $null=Update-ItlMemoryJson $commonSettings {param($current) return $commonProvider}
    }
    $null=Update-ItlMemoryJson $bindingPath {param($current) if((Get-ItlCatalogHash $current) -cne (Get-ItlCatalogHash $old)){throw 'MEMORY_BINDING_CONFLICT'};return $binding}
    # The same client plan/receipts/conflict/restore owner writes this endpoint.
    Write-Vibecoding1cMcpClientConfig -Client $Client
    return @{mode='configured';workspaceId=$identity.workspaceId;cycleId=$binding.cycleId;nativeReadiness='principal verified; scopes/write/tool-catalog require their actual calls';continuation='Reload the client and call memory_status; configured is not installed G5 acceptance.'}
}
