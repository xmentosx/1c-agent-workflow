# Scoped memory leaf of the existing MCP owner. No network or writes at import.
function Get-ItlMemoryHome {
    return (Join-Path (Get-Vibecoding1cMcpLocalHome) 'memory')
}

function Get-ItlMemoryPath {
    param([string]$Kind,[string]$Key='')
    if($Kind -notin @('identity','workspace','binding','pending','receipt','continuation')){throw 'MEMORY_PATH_KIND'}
    $name=if($Key){Get-ItlCatalogHash $Key}else{'current'}
    return (Join-Path (Join-Path (Get-ItlMemoryHome) $Kind) ($name+'.json'))
}

function Read-ItlMemoryJson {
    param([string]$Path,[object]$Default=$null,[ValidateRange(1024,4194304)][int]$MaxBytes=262144)
    if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){return $Default}
    $stream=$null;$reader=$null
    try{
        $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        if($stream.Length -gt $MaxBytes){throw 'MEMORY_RECORD_TOO_LARGE'}
        $reader=[IO.StreamReader]::new($stream,[Text.UTF8Encoding]::new($false,$true),$true)
        return ConvertTo-ItlCatalogCanonicalValue ($reader.ReadToEnd()|ConvertFrom-Json -ErrorAction Stop)
    }
    catch [IO.FileNotFoundException]{return $Default}
    catch [IO.DirectoryNotFoundException]{return $Default}
    catch{throw 'MEMORY_RECORD_INVALID: preserve the record; restore a known valid owned copy, not a new identity.'}
    finally{if($reader){$reader.Dispose()}elseif($stream){$stream.Dispose()}}
}

function Read-ItlMemoryAppliedContext {
    param([Parameter(Mandatory=$true)][string]$Path)
    # The registry owner retains compatibility/proof bytes in this envelope.
    # They are not a memory note or tool context; keep the ordinary 256 KiB
    # record limit and bound only this owner-produced input at 4 MiB.
    return Read-ItlMemoryJson $Path -MaxBytes 4194304
}

function Update-ItlMemoryJson {
    param([string]$Path,[scriptblock]$Update,[switch]$RemoveWhenEmpty)
    # Stable companion of this one private record: never lock the replaceable
    # data inode across File.Replace. No workflow-wide/cross-owner lock or queue.
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    $handle=$null;$deadline=[DateTime]::UtcNow.AddSeconds(2)
    while(-not $handle){
        try{$handle=[IO.File]::Open(($Path+'.write'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}
        catch [IO.IOException]{if([DateTime]::UtcNow -ge $deadline){throw 'MEMORY_RECORD_BUSY: repeat the same operation; IDs and pending are preserved.'};Start-Sleep -Milliseconds 25}
    }
    try{
        $current=Read-ItlMemoryJson $Path
        $value=& $Update $current
        if($null -eq $value){
            if($RemoveWhenEmpty){[IO.File]::Delete($Path);return $null}
            throw 'MEMORY_RECORD_EMPTY: an owner update must retain its record.'
        }
        $text=ConvertTo-Json -InputObject $value -Depth 60 -Compress
        if([Text.Encoding]::UTF8.GetByteCount($text) -gt 262144){throw 'MEMORY_RECORD_TOO_LARGE'}
        Write-Utf8TextAtomic $Path ($text+[Environment]::NewLine)
        return $value
    }finally{$handle.Dispose()}
}

function Get-ItlMemoryWorkspace {
    param([string]$ProjectRoot,[string]$PrincipalId)
    if(-not $PrincipalId){throw 'MEMORY_IDENTITY_REQUIRED: map the authenticated Cognee principal explicitly.'}
    $root=[IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\','/')
    $machine=Update-ItlMemoryJson (Get-ItlMemoryPath identity) {
        param($old)
        if($old){return $old}
        return [ordered]@{schemaVersion=1;machineId=[guid]::NewGuid().ToString('N')}
    }
    $workspace=Update-ItlMemoryJson (Get-ItlMemoryPath workspace $root.ToLowerInvariant()) {
        param($old)
        if($old){if($old.projectRoot -ine $root){throw 'MEMORY_WORKSPACE_MISMATCH'};return $old}
        return [ordered]@{schemaVersion=1;workspaceId=[guid]::NewGuid().ToString('N');projectRoot=$root}
    }
    return [ordered]@{workspaceId=$workspace.workspaceId;developerId=$PrincipalId;machineId=$machine.machineId;workplaceId=(Get-ItlCatalogHash @($PrincipalId,$machine.machineId));projectRoot=$root}
}

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

function Get-ItlMemoryPrivateScopes {
    param([object]$Binding)
    return @(
        @{scopeKind='taskCycle';scopeId=$Binding.cycleId;workspaceId=$Binding.identity.workspaceId;label=('itl_task_'+$Binding.cycleId)},
        @{scopeKind='workspace';scopeId=$Binding.identity.workspaceId;label=('itl_workspace_'+$Binding.identity.workspaceId)},
        @{scopeKind='workplace';scopeId=$Binding.identity.workplaceId;label=('itl_workplace_'+$Binding.identity.workplaceId)}
    )
}

function Resolve-ItlMemoryPrivateDataset {
    param([object]$Binding,[string]$Label,[DateTime]$DeadlineUtc)
    $private=@(Get-ItlMemoryPrivateScopes $Binding|Where-Object label -CEQ $Label)
    if($private.Count -ne 1){throw 'MEMORY_DESTINATION_REQUIRED: choose an explicit current private label or an admitted shared exact-ID mapping.'}
    $path=Get-ItlMemoryPath binding $Binding.projectRoot;$key=Get-ItlCatalogHash $Label
    $prior=Read-ItlMemoryJson $path;$reservation=Get-ItlCatalogField (Get-ItlCatalogField $prior 'datasetReservations') $key
    $native=$null
    if($reservation){
        $list=Invoke-ItlMemoryHttp $Binding.provider GET '/api/v1/datasets' -DeadlineUtc $DeadlineUtc
        if($list.status -eq 200){$matches=@($list.body|Where-Object {$_.name -ceq $Label -and $_.ownerId -ceq $Binding.identity.developerId});if($matches.Count -eq 1){$native=$matches[0]}}
        if(-not $native){throw 'MEMORY_DATASET_UNCONFIRMED: confirm the earlier native creation under this ordinary owner; no duplicate dataset was created.'}
    }else{
        $null=Update-ItlMemoryJson $path {
            param($current)
            if($current.bindingId -cne $Binding.bindingId){throw 'MEMORY_STALE_CONTEXT'}
            if(-not $current.Contains('datasetReservations')){$current['datasetReservations']=[ordered]@{}}
            if($current.datasetReservations.Contains($key)){throw 'MEMORY_DATASET_UNCONFIRMED: another session owns the creation; reconcile its exact ID.'}
            $current.datasetReservations[$key]=@{state='sending';label=$Label};return $current
        }
        $response=Invoke-ItlMemoryHttp $Binding.provider POST '/api/v1/datasets' @{name=$Label} $DeadlineUtc
        if($response.status -eq 200 -or $response.status -eq 201){$native=$response.body}
    }
    if(-not $native -or $native.name -cne $Label -or $native.ownerId -cne $Binding.identity.developerId -or [string]$native.id -cnotmatch '^[a-fA-F0-9-]{36}$'){
        throw 'MEMORY_DATASET_UNCONFIRMED: preserve the native creation reservation; verify its exact ID/owner before retry.'
    }
    $entry=ConvertTo-ItlCatalogCanonicalValue $private[0]
    $entry['workspaceId']=$Binding.identity.workspaceId
    $entry['datasetId']=$native.id;$entry['ownerId']=$native.ownerId;$entry['admitted']=$true;$entry['permissions']=@('read','write')
    $updated=Update-ItlMemoryJson $path {
        param($current)
        if($current.bindingId -cne $Binding.bindingId){throw 'MEMORY_STALE_CONTEXT'}
        $current.provider.datasets=@($current.provider.datasets|Where-Object label -CNE $Label)+@($entry)
        $current.datasetReservations[$key]=@{state='confirmed';label=$Label;datasetId=$native.id}
        return $current
    }
    $Binding.provider.datasets=$updated.provider.datasets
    return $entry
}

function Invoke-ItlMemoryHttp {
    param([object]$Provider,[string]$Method,[string]$Path,[object]$Body=$null,[DateTime]$DeadlineUtc,[string]$ContentType='application/json',[switch]$Raw,[switch]$Defer)
    $remaining=[int][Math]::Min(60000,($DeadlineUtc-[DateTime]::UtcNow).TotalMilliseconds)
    if($remaining -le 0){throw 'MEMORY_DEADLINE'}
    $base=[uri]([string]$Provider.url)
    if($base.Scheme -notin @('http','https') -or $base.UserInfo -or $Path -notmatch '^/(?:api/v1/|openapi\.json$)'){throw 'MEMORY_ENDPOINT_INVALID'}
    $credentialPath=[IO.Path]::GetFullPath([string]$Provider.credentialFile)
    $privatePrefix=[IO.Path]::GetFullPath((Get-Vibecoding1cMcpLocalHome)).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if(-not $credentialPath.StartsWith($privatePrefix,[StringComparison]::OrdinalIgnoreCase)){throw 'MEMORY_CREDENTIAL_PRIVATE: store ordinary-account credentials inside the existing user-local MCP home, outside the project/reset tree.'}
    $credential=Read-ItlMemoryJson $credentialPath
    $apiKey=[string](Get-ItlCatalogField $credential 'apiKey' '')
    $accessToken=[string](Get-ItlCatalogField $credential 'accessToken' '')
    if([string]::IsNullOrWhiteSpace($apiKey) -and [string]::IsNullOrWhiteSpace($accessToken)){throw 'MEMORY_CREDENTIAL_REQUIRED: configure an ordinary-account apiKey privately (legacy accessToken is supported); no administrator credentials.'}
    Add-Type -AssemblyName System.Net.Http
    $handler=[Net.Http.HttpClientHandler]::new();$handler.AllowAutoRedirect=$false
    $client=[Net.Http.HttpClient]::new($handler);$client.Timeout=[TimeSpan]::FromMilliseconds($remaining)
    $request=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method),$base.AbsoluteUri.TrimEnd('/')+$Path)
    if(-not [string]::IsNullOrWhiteSpace($apiKey)){$request.Headers.Add('X-Api-Key',$apiKey)}
    else{$request.Headers.Authorization=[Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer',$accessToken)}
    $request.Headers.Accept.ParseAdd('application/json')
    if($null -ne $Body){
        $text=if($Body -is [string]){$Body}else{ConvertTo-Json -InputObject $Body -Depth 60 -Compress}
        $request.Content=[Net.Http.ByteArrayContent]::new([Text.Encoding]::UTF8.GetBytes($text))
        $request.Content.Headers.ContentType=[Net.Http.Headers.MediaTypeHeaderValue]::Parse($ContentType)
    }
    $pending=[pscustomobject]@{client=$client;handler=$handler;request=$request;response=$null;task=$null;deadline=$DeadlineUtc;raw=$Raw.IsPresent;closed=$false}
    try{$pending.task=$client.SendAsync($request,[Net.Http.HttpCompletionOption]::ResponseHeadersRead)}
    catch{Close-ItlMemoryHttp $pending;throw 'MEMORY_TRANSPORT_UNCONFIRMED'}
    if($Defer){return $pending}
    return (Complete-ItlMemoryHttp $pending)
}

function Close-ItlMemoryHttp {
    param([object]$Pending)
    if(-not (Get-ItlCatalogField $Pending 'client') -or $Pending.closed){return}
    $Pending.closed=$true
    # This operation owns only these HTTP requests, never another process.
    $Pending.client.CancelPendingRequests()
    if(-not $Pending.response -and $Pending.task -and $Pending.task.Status -eq [Threading.Tasks.TaskStatus]::RanToCompletion){$Pending.response=$Pending.task.GetAwaiter().GetResult()}
    if($Pending.response){$Pending.response.Dispose()}
    $Pending.request.Dispose();$Pending.client.Dispose();$Pending.handler.Dispose()
}

function Complete-ItlMemoryHttp {
    param([object]$Pending)
    # A synchronous transport can supply an already completed response.
    if(-not (Get-ItlCatalogField $Pending 'task')){return $Pending}
    try{
        $remaining=[int][Math]::Max(0,($Pending.deadline-[DateTime]::UtcNow).TotalMilliseconds)
        try{
            if(-not $remaining -or -not $Pending.task.Wait($remaining)){throw 'MEMORY_DEADLINE'}
            $Pending.response=$Pending.task.GetAwaiter().GetResult()
        }catch{throw 'MEMORY_TRANSPORT_UNCONFIRMED'}
        $status=[int]$Pending.response.StatusCode
        $stream=$Pending.response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $buffer=[byte[]]::new(8192);$memory=[IO.MemoryStream]::new()
        try{
            while($true){
                $remaining=[int][Math]::Max(0,($Pending.deadline-[DateTime]::UtcNow).TotalMilliseconds)
                if(-not $remaining){throw 'MEMORY_DEADLINE'}
                $read=$stream.ReadAsync($buffer,0,$buffer.Length)
                if(-not $read.Wait($remaining)){throw 'MEMORY_DEADLINE'}
                $n=$read.GetAwaiter().GetResult();if(-not $n){break}
                if($memory.Length+$n -gt 2097152){throw 'MEMORY_RESPONSE_BOUNDED'}
                $memory.Write($buffer,0,$n)
            }
            $text=[Text.UTF8Encoding]::new($false,$true).GetString($memory.ToArray())
        }finally{$stream.Dispose();$memory.Dispose()}
        $value=if($Pending.raw){$text}elseif($text){$text|ConvertFrom-Json -ErrorAction Stop}else{$null}
        return [pscustomobject]@{status=$status;body=$value}
    }finally{Close-ItlMemoryHttp $Pending}
}

function Get-ItlMemoryToolPolicy {
    param([object]$Provider=$null)
    $values=@([Environment]::GetEnvironmentVariable('TOOL_COGNEE','Process'),(Get-ItlCatalogField $Provider 'toolPolicy' 'auto'))
    $modes=@(foreach($value in $values){
        $mode=([string]$value).Trim().ToLowerInvariant()
        if(-not $mode){$mode='auto'}
        if($mode -notin @('off','auto','required')){throw 'MEMORY_TOOL_POLICY_INVALID: correct TOOL_COGNEE/common toolPolicy; no provider call was made.'}
        $mode
    })
    if($modes -contains 'off'){return 'off'}
    if($modes -contains 'required'){return 'required'}
    return 'auto'
}

function Assert-ItlMemoryPrincipal {
    param([object]$Binding,[DateTime]$DeadlineUtc)
    if((Get-ItlMemoryToolPolicy $Binding.provider) -eq 'off'){throw 'MEMORY_TOOL_OFF'}
    $me=Invoke-ItlMemoryHttp $Binding.provider GET '/api/v1/users/me' -DeadlineUtc $DeadlineUtc
    $super=Get-ItlCatalogField $me.body 'is_superuser'
    if($me.status -ne 200 -or [string](Get-ItlCatalogField $me.body 'id') -cne [string]$Binding.identity.developerId -or $super -isnot [bool] -or $super){
        throw 'MEMORY_PRINCIPAL_UNVERIFIED: map the authenticated ordinary principal; do not use administrator credentials.'
    }
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

function Complete-ItlMemoryPending {
    param([object]$Binding,[string]$NoteId,[string]$IntentHash)
    $path=Join-Path (Join-Path (Join-Path (Get-ItlMemoryHome) 'pending') $Binding.identity.workspaceId) ((Get-ItlCatalogHash $NoteId)+'.json')
    if(Test-Path -LiteralPath $path){
        $null=Update-ItlMemoryJson $path {param($old)
            if($old -and (Get-ItlMemoryIntentHash $old.intent) -ceq $IntentHash){
                $old['state']='durable'
                $source=Join-Path (Join-Path (Join-Path (Get-ItlMemoryHome) 'source') $Binding.identity.workspaceId) ((Get-ItlCatalogHash $NoteId)+'.json')
                [void][IO.Directory]::CreateDirectory((Split-Path -Parent $source))
                Write-Utf8TextAtomic $source (ConvertTo-Json -InputObject $old -Depth 60 -Compress)
                # Persist exact source, then delete while its stable private
                # record guard is held. No replacement/new writer
                # can be erased by a later unconditional Remove-Item.
                return $null
            }
            return $old
        } -RemoveWhenEmpty
    }
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

function Get-ItlMemoryRecordKey {
    param([object]$Binding,[string]$DatasetId,[string]$NoteId)
    return (Get-ItlCatalogHash @($Binding.provider.instanceId,$Binding.identity.developerId,$DatasetId,$NoteId))
}

function Find-ItlMemoryNativeNote {
    param([object]$Binding,[object]$Dataset,[string]$NoteId,[DateTime]$DeadlineUtc)
    $listing=Invoke-ItlMemoryHttp $Binding.provider GET "/api/v1/datasets/$($Dataset.datasetId)/data" -DeadlineUtc $DeadlineUtc
    if($listing.status -ne 200){throw 'MEMORY_DATASET_UNAVAILABLE'}
    $items=@($listing.body);$count=0
    foreach($item in $items){
        if($count++ -ge 24 -or [DateTime]::UtcNow -ge $DeadlineUtc){break}
        $id=[string](Get-ItlCatalogField $item 'id')
        $note=Get-ItlMemoryOriginal $Binding $Dataset $id $DeadlineUtc
        if($note -and $note.noteId -ceq $NoteId){return [ordered]@{dataId=$id;note=$note}}
    }
    # Absence in a bounded page is never permission to replay an uncertain write.
    return $null
}

function Invoke-ItlMemoryRemember {
    param([object]$Binding,[string]$Data,[string]$DatasetName,[string]$NoteId='', [object]$Applicability=@{},[object[]]$Evidence=@(),[string]$Status='candidate',[string]$Source='', [string]$Revision='',[string]$DataId='')
    $deadline=[DateTime]::UtcNow.AddSeconds(60)
    if([string]::IsNullOrWhiteSpace($Data) -or [Text.Encoding]::UTF8.GetByteCount($Data) -gt 16384 -or $Status -notin @('candidate','verified')){throw 'MEMORY_NOTE_INVALID'}
    if($Status -eq 'verified' -and $Evidence.Count -eq 0){throw 'MEMORY_EVIDENCE_REQUIRED: keep an unsupported assumption as candidate.'}
    foreach($proof in $Evidence){if(-not (Get-ItlCatalogField $proof 'source') -and -not (Get-ItlCatalogField $proof 'reference')){throw 'MEMORY_EVIDENCE_REQUIRED: evidence needs an identifiable source/reference.'}}
    if($DataId -and -not $NoteId){throw 'MEMORY_NOTE_ID_REQUIRED: pair the exact native data ID with the recalled note ID.'}
    $intent=[ordered]@{data=$Data;datasetName=$DatasetName;applicability=$Applicability;evidence=$Evidence;status=$Status;source=$Source;revision=$Revision;at=[DateTime]::UtcNow.ToString('o')}
    if(-not $NoteId){$NoteId=Get-ItlCatalogHash @($Binding.identity.workspaceId,$Binding.context.projectId,$DatasetName,$Data)}
    if($NoteId -cnotmatch '^[a-zA-Z0-9._-]{1,128}$'){throw 'MEMORY_NOTE_ID_INVALID'}
    $pendingPath=Join-Path (Join-Path (Join-Path (Get-ItlMemoryHome) 'pending') $Binding.identity.workspaceId) ((Get-ItlCatalogHash $NoteId)+'.json')
    $intentHash=Get-ItlMemoryIntentHash $intent
    $null=Update-ItlMemoryJson $pendingPath {param($old)
        if($old -and $old.state -ne 'durable' -and (Get-ItlMemoryIntentHash $old.intent) -cne $intentHash){throw 'MEMORY_PENDING_CONFLICT: reconcile this pending note before replacing its preserved source.'}
        $attempt=if($old -and $old.state -ne 'durable'){Get-ItlCatalogField $old 'attempt'}else{$null}
        if($attempt -and ($old.intent.datasetName -cne $DatasetName -or $attempt.instanceId -cne $Binding.provider.instanceId -or $attempt.principalId -cne $Binding.identity.developerId)){throw 'MEMORY_DESTINATION_LOCKED: reconcile the original attempt before changing scope/provider; its source is preserved.'}
        return [ordered]@{schemaVersion=1;noteId=$NoteId;workspaceId=$Binding.identity.workspaceId;projectId=$Binding.context.projectId;cycleId=$Binding.cycleId;intent=$intent;state='pending';attempt=$attempt}
    }
    # The source survives even when destination/principal/readiness is rejected.
    Assert-ItlMemoryBindingCurrent $Binding
    $private=@(Get-ItlMemoryPrivateScopes $Binding|Where-Object label -CEQ $DatasetName)
    if($private.Count -and @($Binding.provider.datasets|Where-Object label -CEQ $DatasetName).Count -eq 0){
        Assert-ItlMemoryPrincipal $Binding $deadline
        $null=Resolve-ItlMemoryPrivateDataset $Binding $DatasetName $deadline
    }
    $datasets=@(Get-ItlMemoryScopes $Binding write $DatasetName ([string](Get-ItlCatalogField $Applicability 'knowledgeArea')))
    $dataset=$datasets[0]
    if($dataset.scopeKind -eq 'product' -and (Get-ItlCatalogField $Binding.context.projectContext 'customized' $false) -and -not (Get-ItlCatalogField $Applicability 'independentOfCustomization' $false)){
        throw 'MEMORY_PROJECT_CANDIDATE: prove independence from customer customizations before a product write; the private pending source is retained.'
    }
    if($dataset.scopeKind -eq 'product' -and $Status -ne 'verified'){throw 'MEMORY_PROJECT_CANDIDATE: keep an unverified product fact in a private task/project scope.'}
    Assert-ItlMemoryPrincipal $Binding $deadline
    $null=Update-ItlMemoryJson $pendingPath {param($old)
        if($old.intent.datasetName -cne $DatasetName -or (Get-ItlMemoryIntentHash $old.intent) -cne $intentHash){throw 'MEMORY_PENDING_CONFLICT'}
        $oldAttempt=Get-ItlCatalogField $old 'attempt'
        if($oldAttempt -and $oldAttempt.datasetId -cne $dataset.datasetId){throw 'MEMORY_DESTINATION_LOCKED: preserve the original exact-ID attempt even if its label was remapped.'}
        $old['attempt']=@{instanceId=$Binding.provider.instanceId;principalId=$Binding.identity.developerId;datasetId=$dataset.datasetId}
        return $old
    }
    $key=Get-ItlMemoryRecordKey $Binding $dataset.datasetId $NoteId
    $receiptPath=Get-ItlMemoryPath receipt $key
    $existing=Read-ItlMemoryJson $receiptPath;$existingHash=Get-ItlCatalogHash $existing;$found=$null
    if($existing -and $existing.state -in @('retired','retirement-unconfirmed')){throw 'MEMORY_NOTE_RETIRED: resolve retirement status; use a new explicit ID for a new fact.'}
    if($DataId){
        if($existing -and $existing.dataId -and $existing.dataId -cne $DataId){throw 'MEMORY_NOTE_ID_MISMATCH'}
        $native=Get-ItlMemoryOriginal $Binding $dataset $DataId $deadline
        if(-not $native -or $native.noteId -cne $NoteId){throw 'MEMORY_EXACT_SOURCE_REQUIRED: preserve pending; no new POST replaces a missing or unauthorized original.'}
        if(-not $existing){$existing=@{state='durable';dataId=$DataId}}
        $found=@{note=$native;dataId=$DataId}
    }
    if($existing -and $existing.state -in @('sending','unconfirmed','indexing','durable')){
        if(-not $found){$found=if($existing.dataId){$n=Get-ItlMemoryOriginal $Binding $dataset $existing.dataId $deadline;if($n){@{note=$n;dataId=$existing.dataId}}}else{Find-ItlMemoryNativeNote $Binding $dataset $NoteId $deadline}}
        if(-not $found){return [ordered]@{state='unconfirmed';noteId=$NoteId;pending=$true;continuation='Use memory_status with this note ID; do not replay remember or switch provider.'}}
        if($found.note.noteId -cne $NoteId){throw 'MEMORY_NOTE_ID_MISMATCH'}
        if($existing.state -in @('sending','unconfirmed','indexing') -and (Get-ItlMemoryIntentHash $found.note) -cne $existing.contentHash){return @{state='unconfirmed';noteId=$NoteId;dataId=$found.dataId;pending=$true;continuation='The old original is still current; it does not prove rejection of the in-flight update. Reconcile without replay.'}}
        if((Get-ItlMemoryIntentHash $found.note) -ceq $intentHash){
            $receipt=[ordered]@{schemaVersion=1;state='durable';noteId=$NoteId;datasetId=$dataset.datasetId;dataId=$found.dataId;contentHash=$intentHash}
            $null=Update-ItlMemoryJson $receiptPath {param($old) if((Get-ItlCatalogHash $old) -cne $existingHash){throw 'MEMORY_WRITE_IN_FLIGHT'};return $receipt}
            Complete-ItlMemoryPending $Binding $NoteId $intentHash
            return $receipt
        }
        # A confirmed existing original is updated precisely, never superseded
        # merely by a second semantic hit with no authoritative old-ID update.
        $existing['dataId']=$found.dataId
    }
    $note=[ordered]@{format='itl-memory-v1';noteId=$NoteId;fact=$Data;scope=@{kind=$dataset.scopeKind;id=$dataset.scopeId};date=[DateTime]::UtcNow.ToString('o');status=$Status;origin=@{projectId=$Binding.context.projectId;workspaceId=$Binding.identity.workspaceId;cycleId=$Binding.cycleId;source=$Source;revision=$Revision};applicability=$Applicability;evidence=$Evidence}
    if($existing -and $existing.dataId -and $found){$note['updatedByOrigin']=$note.origin;$note['origin']=$found.note.origin;$note['supersedes']=$found.note.noteId}
    $text=ConvertTo-Json -InputObject $note -Depth 40 -Compress
    $receipt=[ordered]@{schemaVersion=1;state='sending';attemptId=[guid]::NewGuid().ToString('N');noteId=$NoteId;datasetId=$dataset.datasetId;dataId=$(if($existing){Get-ItlCatalogField $existing 'dataId' ''}else{''});contentHash=$intentHash}
    $null=Update-ItlMemoryJson $receiptPath {
        param($old)
        if((Get-ItlCatalogHash $old) -cne $existingHash){throw 'MEMORY_WRITE_IN_FLIGHT: use exact status reconciliation, not a concurrent remember.'}
        return $receipt
    }
    try{
        if($receipt.dataId){
            $boundary='itl_'+[guid]::NewGuid().ToString('N')
            $multipart="--$boundary`r`nContent-Disposition: form-data; name=`"data`"; filename=`"memory.txt`"`r`nContent-Type: text/plain; charset=utf-8`r`n`r`n$text`r`n--$boundary--`r`n"
            $result=Invoke-ItlMemoryHttp $Binding.provider PATCH "/api/v1/update?data_id=$($receipt.dataId)&dataset_id=$($dataset.datasetId)&chunk_level_diff=true" $multipart $deadline -ContentType ("multipart/form-data; boundary="+$boundary)
        }else{
            $form='raw_data='+[uri]::EscapeDataString($text)+'&datasetId='+[uri]::EscapeDataString($dataset.datasetId)+'&self_improvement=false&run_in_background=false'
            $result=Invoke-ItlMemoryHttp $Binding.provider POST '/api/v1/remember' $form $deadline -ContentType 'application/x-www-form-urlencoded'
        }
        if($result.status -ge 400 -and $result.status -lt 500){$receipt.state='rejected'}
        elseif($result.status -eq 200){
            $nativeIds=Get-ItlCatalogField $result.body 'items' @();$ids=@($nativeIds)
            if(-not $receipt.dataId -and $ids.Count -eq 1){$receipt.dataId=[string](Get-ItlCatalogField $ids[0] 'id')}
            $original=if($receipt.dataId){Get-ItlMemoryOriginal $Binding $dataset $receipt.dataId $deadline}else{$null}
            if(-not $original){$found=Find-ItlMemoryNativeNote $Binding $dataset $NoteId $deadline;if($found){$receipt.dataId=$found.dataId;$original=$found.note}}
            $receipt.state=if($original -and (Get-ItlMemoryIntentHash $original) -ceq $intentHash){'durable'}else{'unconfirmed'}
        }else{$receipt.state='unconfirmed'}
    }catch{$receipt.state='unconfirmed'}
    $null=Update-ItlMemoryJson $receiptPath {param($old)
        if((Get-ItlCatalogField $old 'attemptId') -cne $receipt.attemptId){throw 'MEMORY_WRITE_IN_FLIGHT'}
        return $receipt
    }
    if($receipt.state -eq 'durable'){Complete-ItlMemoryPending $Binding $NoteId $intentHash}
    $receipt['pending']=($receipt.state -ne 'durable');$receipt['searchState']='unverified'
    return $receipt
}

function Invoke-ItlMemoryRecall {
    param([object]$Binding,[string]$Query,[string[]]$Datasets=@(),[int]$TopK=8,[ValidateSet('CHUNKS','CHUNKS_LEXICAL')][string]$SearchType='CHUNKS')
    if([string]::IsNullOrWhiteSpace($Query) -or $Query.Length -gt 4096){throw 'MEMORY_QUERY_INVALID'}
    Assert-ItlMemoryBindingCurrent $Binding
    if($SearchType -ne 'CHUNKS'){
        $contract=Read-ItlMemoryJson (Join-Path $PSScriptRoot '../../assets/scoped-memory-policy.json')
        $qualifiedTypes=Get-ItlCatalogField $contract 'searchTypes' @('CHUNKS')
        if(@($qualifiedTypes) -cnotcontains $SearchType){throw 'MEMORY_SEARCH_TYPE_UNQUALIFIED'}
    }
    $deadline=[DateTime]::UtcNow.AddSeconds(20);Assert-ItlMemoryPrincipal $Binding $deadline
    $allowed=@(Get-ItlMemoryScopes $Binding read);$selected=@($allowed)
    if($Datasets.Count){
        foreach($label in $Datasets){if(@($allowed|Where-Object label -CEQ $label).Count -ne 1){throw 'MEMORY_READ_SCOPE_DENIED'}}
        $selected=@($allowed|Where-Object {$Datasets -ccontains $_.label})
    }
    if(-not $selected.Count){return @{cards=@();coverage='unavailable';continuation='Prepare admitted dataset IDs/grants; no unscoped recall was sent.'}}
    $ids=@($selected|ForEach-Object {$_.datasetId}|Select-Object -Unique)
    $result=Invoke-ItlMemoryHttp $Binding.provider POST '/api/v1/recall' @{query=$Query;dataset_ids=$ids;search_type=$SearchType;top_k=24;only_context=$false} $deadline
    if($result.status -ne 200){return @{cards=@();coverage='unavailable';continuation='Preserve the scope and verify native access; required coverage remains incomplete.'}}
    $cards=@();$seen=@{};$lookups=0;$bytes=0;$partial=$false
    if(-not (Test-Path -LiteralPath 'Function:\Measure-ItlMemoryTokens')){. (Join-Path $PSScriptRoot 'agent-1c.memory-tokens.ps1')}
    # D8 bounds tokens, not UTF-8 bytes. The native transport already bounds
    # raw originals; an exact named counter admits compact non-ASCII facts.
    # Cognee returns per-dataset groups, not a globally ranked top_k union.
    # Interleave admitted groups before applying the unchanged global cap so a
    # large product group cannot starve project/workspace/workplace originals.
    $groups=@();$candidates=@()
    foreach($scope in $selected){
        $group=@($result.body|Where-Object {([string](Get-ItlCatalogField $_ 'dataset_id')) -ceq $scope.datasetId})
        if($group.Count){$groups+=,@($group)}
    }
    for($rank=0;$rank -lt 24 -and $candidates.Count -lt 24;$rank++){
        foreach($group in $groups){
            if($rank -lt $group.Count){$candidates+=,$group[$rank];if($candidates.Count -eq 24){break}}
        }
    }
    if(@($result.body).Count -gt $candidates.Count){$partial=$true}
    $queue=@()
    foreach($chunk in $candidates){
        $dataset=@($selected|Where-Object datasetId -CEQ ([string](Get-ItlCatalogField $chunk 'dataset_id')))
        $id=[string](Get-ItlCatalogField (Get-ItlCatalogField $chunk 'metadata') 'data_id')
        if($dataset.Count -ne 1 -or $id -cnotmatch '^[a-fA-F0-9-]{36}$'){$partial=$true;continue}
        $key=$dataset[0].datasetId+':'+$id;if($seen.ContainsKey($key)){continue};$seen[$key]=$true
        $queue+=,@{dataset=$dataset[0];id=$id;pending=$null}
    }
    $started=0
    try{
    for($position=0;$position -lt $queue.Count;$position++){
        if([DateTime]::UtcNow -ge $deadline){$partial=$true;break}
        while($started -lt $queue.Count -and $started -le $position+1 -and [DateTime]::UtcNow -lt $deadline){
            $item=$queue[$started];$started++;$lookups++
            try{$item.pending=Invoke-ItlMemoryHttp $Binding.provider GET "/api/v1/datasets/$($item.dataset.datasetId)/data/$($item.id)/raw" -DeadlineUtc $deadline -Raw -Defer}
            catch{$partial=$true}
        }
        $item=$queue[$position];$dataset=@($item.dataset);$id=$item.id
        if(-not $item.pending){$partial=$true;continue}
        try{$note=Get-ItlMemoryOriginal $Binding $item.dataset $id $deadline -Response $item.pending}
        catch{$partial=$true;continue}
        finally{$item.pending=$null}
        if(-not $note -or -not (Test-ItlMemoryNoteApplicable $Binding $note)){$partial=$true;continue}
        $card=[ordered]@{noteId=$note.noteId;fact=$note.fact;status=$note.status;source=@{dataset=$dataset[0].label;dataId=$id};evidence=$note.evidence;applicability=$note.applicability}
        $next=@($cards)+@($card);$size=[Text.Encoding]::UTF8.GetByteCount((ConvertTo-Json -InputObject $next -Depth 30 -Compress))
        try{
            $candidateTokens=Measure-ItlMemoryTokens (ConvertTo-Json -InputObject $next -Depth 30 -Compress)
            $exceeded=if($candidateTokens.measurement -eq 'measured-encode-ordinary'){
                $candidateTokens.cl100k_base -gt 1600 -or $candidateTokens.o200k_base -gt 1600
            }else{$size -gt 1600} # retain the labelled conservative fallback
        }catch{$partial=$true;break}
        if($exceeded){$partial=$true;continue}
        $cards=$next;$bytes=$size
        if($cards.Count -ge [Math]::Min(8,[Math]::Max(1,$TopK))){$partial=$true;break}
    }
    }finally{foreach($item in $queue){if($item.pending){Close-ItlMemoryHttp $item.pending}}}
    $output=[ordered]@{cards=@($cards);coverage=$(if($partial){'partial'}else{'bounded'});rawCandidateCap=24;sourceLookups=$lookups;backendCalls=(2+$lookups);utf8Bytes=$bytes;tokenCounts=@{};context=@{projectId=$Binding.context.projectId;catalogRevision=$Binding.context.catalogRevision;cycleId=$Binding.cycleId}}
    # Bound the final serialized response, including provenance and metrics,
    # with the same actual token limit. Bytes remain a separate metric.
    while($true){
        try{
            $output.tokenCounts=Measure-ItlMemoryTokens (ConvertTo-Json -InputObject @($output.cards) -Depth 30 -Compress)
            # Only the decimal byte count changes: converge its serialized size
            # before measuring so the returned object is the measured object.
            do{
                $payload=ConvertTo-Json -InputObject $output -Depth 30 -Compress
                $size=[Text.Encoding]::UTF8.GetByteCount($payload)
                $stable=($output.utf8Bytes -eq $size);$output.utf8Bytes=$size
            }while(-not $stable)
            $responseTokens=Measure-ItlMemoryTokens $payload
            $exceeded=if($responseTokens.measurement -eq 'measured-encode-ordinary'){
                $responseTokens.cl100k_base -gt 1600 -or $responseTokens.o200k_base -gt 1600
            }else{$size -gt 1600}
        }catch{$output.cards=@();$output.coverage='partial';$output.tokenCounts=@{measurement='unavailable';continuation='repair the packaged tokenizer; no unmeasured cards returned'};break}
        if(-not @($output.cards).Count -or -not $exceeded){break}
        $output.cards=@($output.cards|Select-Object -SkipLast 1);$output.coverage='partial'
    }
    $output.utf8Bytes=[Text.Encoding]::UTF8.GetByteCount((ConvertTo-Json -InputObject $output -Depth 30 -Compress))
    return $output
}

function Get-ItlMemoryLocalContext {
    param([object]$Binding,[string]$NoteId='',[switch]$History)
    $directory=Join-Path (Join-Path (Get-ItlMemoryHome) 'pending') $Binding.identity.workspaceId
    $pending=@();$cycle=Read-ItlMemoryJson $Binding.cycleStatePath
    $currentCycle=[string](Get-ItlCatalogField (Get-ItlCatalogField $cycle 'memoryCycle') 'current' '')
    $applied=Read-ItlMemoryAppliedContext $Binding.appliedPath
    $project=if($applied){[string]$applied.context.projectId}else{[string]$Binding.context.projectId}
    if(Test-Path -LiteralPath $directory -PathType Container){
        $files=if($NoteId){Get-Item -LiteralPath (Join-Path $directory ((Get-ItlCatalogHash $NoteId)+'.json')) -ErrorAction SilentlyContinue}else{Get-ChildItem -LiteralPath $directory -File -Filter '*.json'|Sort-Object LastWriteTimeUtc -Descending|Select-Object -First 24}
        foreach($file in @($files)){
            $record=Read-ItlMemoryJson $file.FullName
            if(-not $record){continue}
            if($record.state -eq 'durable' -or $record.projectId -cne $project -or ($NoteId -and $record.noteId -cne $NoteId)){continue}
            $label=[string]$record.intent.datasetName
            $task=@($Binding.provider.datasets|Where-Object {$_.label -ceq $label -and $_.scopeKind -eq 'taskCycle'}).Count -gt 0 -or $label -like 'itl_task_*'
            if($task -and $record.cycleId -cne $currentCycle -and -not ($History -and $NoteId)){continue}
            $pending+=,[ordered]@{noteId=$record.noteId;state=$record.state;datasetName=$label;fact=$(if($NoteId){$record.intent.data}else{([string]$record.intent.data).Substring(0,[Math]::Min(180,([string]$record.intent.data).Length))});sourcePreserved=$true}
            if($pending.Count -ge 8){break}
        }
    }
    $preservedSource=$null
    if($NoteId){
        $sourcePath=Join-Path (Join-Path (Join-Path (Get-ItlMemoryHome) 'source') $Binding.identity.workspaceId) ((Get-ItlCatalogHash $NoteId)+'.json')
        $source=Read-ItlMemoryJson $sourcePath
        if($source -and $source.projectId -ceq $project -and ($source.intent.datasetName -notlike 'itl_task_*' -or $source.cycleId -ceq $currentCycle -or $History)){
            $preservedSource=@{noteId=$source.noteId;intent=$source.intent;backendCurrentness='unverified-local-source';history=($source.cycleId -cne $currentCycle)}
        }
    }
    $continuation=Read-ItlMemoryJson (Get-ItlMemoryPath continuation $Binding.identity.workspaceId)
    if($continuation -and ((Get-ItlCatalogField $continuation 'projectId') -cne $project -or (Get-ItlCatalogField $continuation 'cycleId') -cne $currentCycle)){$continuation=$null}
    $destinations=@(Get-ItlMemoryPrivateScopes $Binding|Where-Object {
        $privateLabel=$_.label;$mapped=@($Binding.provider.datasets|Where-Object label -CEQ $privateLabel)
        -not $mapped.Count -or ($mapped.Count -eq 1 -and $mapped[0].admitted -and @($mapped[0].permissions) -ccontains 'write')
    })+@(Get-ItlMemoryScopes $Binding read|Where-Object {$_.scopeKind -notin @('taskCycle','workspace','workplace','product') -and @($_.permissions) -contains 'write'}|ForEach-Object {@{label=$_.label;scopeKind=$_.scopeKind;scopeId=$_.scopeId}})
    foreach($area in @($Binding.context.knowledgeContext.knowledgeAreas|Where-Object {$_.status -eq 'applicable' -and $_.memoryHomeProductId})){
        $destinations+=@(Get-ItlMemoryScopes $Binding read|Where-Object {$_.scopeKind -eq 'product' -and $_.scopeId -ceq $area.memoryHomeProductId -and @($_.permissions) -contains 'write'}|ForEach-Object {@{label=$_.label;scopeKind=$_.scopeKind;scopeId=$_.scopeId;knowledgeArea=$area.areaId}})
    }
    $bindingState='current'
    try{Assert-ItlMemoryBindingCurrent $Binding}catch{$bindingState='stale-or-disabled';$destinations=@()}
    $receipts=@();$receiptRoot=Join-Path (Get-ItlMemoryHome) 'receipt'
    if($bindingState -eq 'current' -and (Test-Path -LiteralPath $receiptRoot -PathType Container)){
        $readIds=@(Get-ItlMemoryScopes $Binding read|ForEach-Object {$_.datasetId})
        foreach($file in @(Get-ChildItem -LiteralPath $receiptRoot -File -Filter '*.json'|Sort-Object LastWriteTimeUtc -Descending|Select-Object -First 24)){
            $record=Read-ItlMemoryJson $file.FullName
            if(-not $record -or $readIds -cnotcontains $record.datasetId -or ($NoteId -and $record.noteId -cne $NoteId)){continue}
            $expected=Get-ItlMemoryPath receipt (Get-ItlMemoryRecordKey $Binding $record.datasetId $record.noteId)
            if($expected -ine $file.FullName){continue}
            $receipts+=@{noteId=$record.noteId;datasetId=$record.datasetId;dataId=(Get-ItlCatalogField $record 'dataId' '');state=$record.state;searchState=(Get-ItlCatalogField $record 'searchState' 'unverified');currentness='local receipt only'}
            if($receipts.Count -ge 4){break}
        }
    }
    return [ordered]@{pending=$pending;receipts=$receipts;preservedSource=$preservedSource;continuation=$continuation;coverage='bounded-local; old task pending is history, not current';destinations=$destinations;currentCycleId=$currentCycle;bindingState=$bindingState}
}

function Invoke-ItlMemoryStatus {
    param([object]$Binding,[string]$DatasetName='', [string]$NoteId='', [string]$DataId='',[switch]$LocalOnly,[switch]$History)
    if($LocalOnly -or -not $DatasetName){return Get-ItlMemoryLocalContext $Binding $NoteId -History:$History}
    Assert-ItlMemoryBindingCurrent $Binding
    $deadline=[DateTime]::UtcNow.AddSeconds(60);Assert-ItlMemoryPrincipal $Binding $deadline
    $scope=@(if($History -and ($NoteId -or $DataId)){
        @($Binding.provider.datasets|Where-Object {$_.scopeKind -eq 'taskCycle' -and $_.label -ceq $DatasetName -and $_.label -ceq ('itl_task_'+$_.scopeId) -and (Get-ItlCatalogField $_ 'workspaceId') -ceq $Binding.identity.workspaceId -and $_.admitted -and @($_.permissions) -ccontains 'read'})
    }else{Get-ItlMemoryScopes $Binding read $DatasetName})
    if($scope.Count -ne 1){throw 'MEMORY_READ_SCOPE_DENIED'}
    $exact=$null
    if($DataId){
        $note=Get-ItlMemoryOriginal $Binding $scope[0] $DataId $deadline
        if(-not $note){return @{state='unverified-or-retired';history=[bool]$History}}
        if($NoteId -and $note.noteId -cne $NoteId){throw 'MEMORY_NOTE_ID_MISMATCH'}
        $NoteId=$note.noteId;$exact=@{dataId=$DataId;note=$note}
    }
    $key=Get-ItlMemoryRecordKey $Binding $scope[0].datasetId $NoteId
    $receipt=Read-ItlMemoryJson (Get-ItlMemoryPath receipt $key)
    $found=if($exact){$exact}elseif($receipt -and $receipt.dataId){$note=Get-ItlMemoryOriginal $Binding $scope[0] $receipt.dataId $deadline;if($note){@{dataId=$receipt.dataId;note=$note}}}else{Find-ItlMemoryNativeNote $Binding $scope[0] $NoteId $deadline}
    if(-not $found){return @{state='unconfirmed-or-retired';noteId=$NoteId;continuation='Retain pending; absence in a bounded lookup is not permission to replay remember.'}}
    if($found.note.noteId -cne $NoteId){throw 'MEMORY_NOTE_ID_MISMATCH'}
    if($receipt -and $receipt.state -in @('sending','unconfirmed','indexing') -and (Get-ItlMemoryIntentHash $found.note) -cne $receipt.contentHash){return @{state='unconfirmed';noteId=$NoteId;dataId=$found.dataId;pending=$true;continuation='Current original differs from the attempted update; preserve source and receipt, do not replay.'}}
    $receiptHash=Get-ItlCatalogHash $receipt
    $confirmed=@{schemaVersion=1;state='durable';noteId=$NoteId;datasetId=$scope[0].datasetId;dataId=$found.dataId;contentHash=(Get-ItlMemoryIntentHash $found.note)}
    $null=Update-ItlMemoryJson (Get-ItlMemoryPath receipt $key) {param($old)
        if((Get-ItlCatalogHash $old) -cne $receiptHash){throw 'MEMORY_WRITE_IN_FLIGHT'}
        return $confirmed
    }
    Complete-ItlMemoryPending $Binding $NoteId $confirmed.contentHash
    $status=Invoke-ItlMemoryHttp $Binding.provider GET "/api/v1/datasets/status?dataset=$($scope[0].datasetId)&pipeline=add_pipeline&pipeline=cognify_pipeline" -DeadlineUtc $deadline
    $pipelines=Get-ItlCatalogField $status.body $scope[0].datasetId
    $searchable=$status.status -eq 200 -and (Get-ItlCatalogField $pipelines 'add_pipeline') -eq 'DATASET_PROCESSING_COMPLETED' -and (Get-ItlCatalogField $pipelines 'cognify_pipeline') -eq 'DATASET_PROCESSING_COMPLETED'
    return @{state='durable';searchState=$(if($searchable){'indexed-dataset; per-note retrieval not asserted'}else{'indexing-or-unverified'});dataId=$found.dataId;noteId=$found.note.noteId;note=$found.note;applicable=(Test-ItlMemoryNoteApplicable $Binding $found.note);history=[bool]$History}
}

function Invoke-ItlMemoryRetire {
    param([object]$Binding,[string]$DatasetName,[string]$NoteId,[string]$KnowledgeArea='',[string]$DataId='')
    Assert-ItlMemoryBindingCurrent $Binding
    $deadline=[DateTime]::UtcNow.AddSeconds(60);Assert-ItlMemoryPrincipal $Binding $deadline
    $scopes=@(Get-ItlMemoryScopes $Binding write $DatasetName $KnowledgeArea);$dataset=$scopes[0]
    $key=Get-ItlMemoryRecordKey $Binding $dataset.datasetId $NoteId;$path=Get-ItlMemoryPath receipt $key
    $record=Read-ItlMemoryJson $path
    $exactId=if($DataId){$DataId}elseif($record){Get-ItlCatalogField $record 'dataId' ''}else{''}
    $found=if($exactId){$n=Get-ItlMemoryOriginal $Binding $dataset $exactId $deadline;if($n){@{dataId=$exactId;note=$n}}}else{Find-ItlMemoryNativeNote $Binding $dataset $NoteId $deadline}
    if(-not $found -or $found.note.noteId -cne $NoteId){throw 'MEMORY_RETIRE_UNVERIFIED: resolve the exact note first; never delete a whole dataset.'}
    $recordHash=Get-ItlCatalogHash $record
    $receipt=[ordered]@{schemaVersion=1;noteId=$NoteId;dataId=$found.dataId;datasetId=$dataset.datasetId;state='retirement-unconfirmed';source=$found.note}
    $null=Update-ItlMemoryJson $path {param($old)
        if((Get-ItlCatalogHash $old) -cne $recordHash){throw 'MEMORY_WRITE_IN_FLIGHT'};return $receipt
    }
    try{
        $result=Invoke-ItlMemoryHttp $Binding.provider POST '/api/v1/forget' @{datasetId=$dataset.datasetId;dataId=$found.dataId;memoryOnly=$false} $deadline
        $check=Invoke-ItlMemoryHttp $Binding.provider GET "/api/v1/datasets/$($dataset.datasetId)/data/$($found.dataId)/raw" -DeadlineUtc $deadline -Raw
        if($result.status -eq 200 -and $check.status -eq 404){$receipt.state='retired'}
    }catch{ $receipt.state='retirement-unconfirmed' }
    $null=Update-ItlMemoryJson $path {param($old)
        if($old.state -ne 'retirement-unconfirmed'){throw 'MEMORY_WRITE_IN_FLIGHT'};return $receipt
    };return $receipt
}
