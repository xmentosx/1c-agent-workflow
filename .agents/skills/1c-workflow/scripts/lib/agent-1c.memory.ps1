# Scoped memory leaf of the existing MCP owner. No network or writes at import.
function Get-ItlMemoryHome {
    return (Join-Path (Get-Vibecoding1cMcpLocalHome) 'memory')
}

function Get-ItlMemoryPath {
    param([string]$Kind,[string]$Key='')
    if($Kind -notin @('identity','workspace','binding','pending','receipt','continuation','usage')){throw 'MEMORY_PATH_KIND'}
    $name=if($Key){Get-ItlCatalogHash $Key}else{'current'}
    return (Join-Path (Join-Path (Get-ItlMemoryHome) $Kind) ($name+'.json'))
}

function Get-ItlMemoryRecordKind {
    param([string]$Path)
    # Private records live in <home>/<kind>/[<workspace>/]<hash>.json.
    $parent=Split-Path -Parent $Path
    foreach($name in @((Split-Path -Leaf $parent),(Split-Path -Leaf (Split-Path -Parent $parent)))){
        if($name -in @('identity','workspace','binding','pending','receipt','continuation','source','usage')){return $name}
    }
    return 'record'
}

function Read-ItlMemoryJson {
    param([string]$Path,[object]$Default=$null,[ValidateRange(1024,4194304)][int]$MaxBytes=262144,[string]$Kind='')
    if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){return $Default}
    if(-not $Kind){$Kind=Get-ItlMemoryRecordKind $Path}
    # Another operation may hold or replace this record: that is a transient
    # state, repeated a bounded number of times and never reported as damage.
    $read=Read-ItlMemoryRecordText $Path $MaxBytes
    for($attempt=1;$read.state -eq 'busy' -and $attempt -lt 3;$attempt++){
        Start-Sleep -Milliseconds 60
        $read=Read-ItlMemoryRecordText $Path $MaxBytes
    }
    $invalid="MEMORY_RECORD_INVALID: kind=$Kind; the record is not valid UTF-8 JSON. Preserve it and restore a known valid owned copy, not a new identity."
    if($read.state -eq 'absent'){return $Default}
    if($read.state -eq 'busy'){throw "MEMORY_RECORD_BUSY: kind=$Kind; repeat the same operation; the record, IDs and pending are preserved."}
    if($read.state -eq 'oversized'){throw "MEMORY_RECORD_TOO_LARGE: kind=$Kind; the record exceeds its $MaxBytes byte bound. Preserve it; it is not read into the tool context."}
    if($read.state -ne 'ok'){throw $invalid}
    try{return ConvertTo-ItlCatalogCanonicalValue ($read.text|ConvertFrom-Json -ErrorAction Stop)}
    catch{throw $invalid}
}

function Read-ItlMemoryRecordText {
    param([string]$Path,[int]$MaxBytes)
    # One read attempt. state: ok (with text), absent, busy, oversized, invalid.
    $stream=$null;$reader=$null
    try{
        $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        if($stream.Length -gt $MaxBytes){return @{state='oversized'}}
        $reader=[IO.StreamReader]::new($stream,[Text.UTF8Encoding]::new($false,$true),$true)
        return @{state='ok';text=$reader.ReadToEnd()}
    }
    catch{
        # One handler with explicit type tests. Sibling typed catch clauses are
        # not reliable here: once this function had run often enough, Windows
        # PowerShell 5.1 sent the IOException of a held file to the
        # DirectoryNotFoundException clause and the record read as absent
        # (ScopedCogneeMemory busy-record regression).
        $cause=$_.Exception
        while($cause -is [Management.Automation.RuntimeException] -and $cause.InnerException){$cause=$cause.InnerException}
        if($cause -is [IO.FileNotFoundException] -or $cause -is [IO.DirectoryNotFoundException]){return @{state='absent'}}
        if($cause -is [IO.IOException] -or $cause -is [UnauthorizedAccessException]){return @{state='busy'}}
        return @{state='invalid'}
    }
    finally{if($reader){$reader.Dispose()}elseif($stream){$stream.Dispose()}}
}

function Read-ItlMemoryAppliedContext {
    param([Parameter(Mandatory=$true)][string]$Path)
    # The registry owner retains compatibility/proof bytes in this envelope.
    # They are not a memory note or tool context; keep the ordinary 256 KiB
    # record limit and bound only this owner-produced input at 4 MiB.
    return Read-ItlMemoryJson $Path -MaxBytes 4194304 -Kind 'applied-context'
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

function Get-ItlMemoryRootId {
    param([string]$Root)
    # One stable private ID per local checkout root.
    $root=[IO.Path]::GetFullPath($Root).TrimEnd('\','/')
    $record=Update-ItlMemoryJson (Get-ItlMemoryPath workspace $root.ToLowerInvariant()) {
        param($old)
        if($old){if($old.projectRoot -ine $root){throw 'MEMORY_WORKSPACE_MISMATCH'};return $old}
        return [ordered]@{schemaVersion=1;workspaceId=[guid]::NewGuid().ToString('N');projectRoot=$root}
    }
    return [string]$record.workspaceId
}

function Get-ItlMemoryMachineGuid {
    # An ordinary user can read this value on Windows 10/11/Server 2019+.
    try{
        $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,[Microsoft.Win32.RegistryView]::Registry64)
        try{
            $key=$base.OpenSubKey('SOFTWARE\Microsoft\Cryptography')
            if(-not $key){return ''}
            try{return [string]$key.GetValue('MachineGuid','')}finally{$key.Dispose()}
        }finally{$base.Dispose()}
    }catch{return ''}
}

function Get-ItlMemoryHostName {
    return [string][Environment]::MachineName
}

function Get-ItlMemoryHostId {
    # The host name separates cloned virtual machines that share one GUID.
    # No value means the host scope is unavailable; nothing is written.
    $guid=([string](Get-ItlMemoryMachineGuid)).Trim().ToLowerInvariant();$name=([string](Get-ItlMemoryHostName)).Trim().ToLowerInvariant()
    if(-not $guid -or -not $name){return ''}
    return (Get-ItlCatalogHash @($guid,$name))
}

function Get-ItlMemoryWorkspace {
    param([string]$ProjectRoot,[string]$PrincipalId,[string]$MainRoot='')
    if(-not $PrincipalId){throw 'MEMORY_IDENTITY_REQUIRED: map the authenticated Cognee principal explicitly.'}
    $root=[IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\','/')
    $machine=Update-ItlMemoryJson (Get-ItlMemoryPath identity) {
        param($old)
        if($old){return $old}
        return [ordered]@{schemaVersion=1;machineId=[guid]::NewGuid().ToString('N')}
    }
    # workspaceId stays the ID of this branch copy (pending, continuation and
    # the lifecycle cycle key). localProjectId is the main copy shared by all
    # of its branch copies and keys only the workspace dataset.
    $workspaceId=Get-ItlMemoryRootId $root
    $localProjectId=if($MainRoot){Get-ItlMemoryRootId $MainRoot}else{$workspaceId}
    return [ordered]@{workspaceId=$workspaceId;localProjectId=$localProjectId;hostId=(Get-ItlMemoryHostId);developerId=$PrincipalId;machineId=$machine.machineId;workplaceId=(Get-ItlCatalogHash @($PrincipalId,$machine.machineId));projectRoot=$root}
}

function Assert-ItlMemoryBindingCurrent {
    param([object]$Binding)
    if($Binding.schemaVersion -ne 1 -or $Binding.capability -cne 'scoped-cognee-memory-v1'){throw 'MEMORY_BINDING_UNSUPPORTED: reload the client; this memory server and the installed binding format differ.'}
    if($Binding.mode -ne 'enabled'){throw 'MEMORY_DISABLED: use the explicit memory setup; ordinary workflow remains available.'}
    $state=Read-ItlMemoryJson $Binding.cycleStatePath -Kind 'branch-state'
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
    $keys=@{taskCycle=$Binding.cycleId;workplace=$identity.workplaceId;project=$context.projectId;organization=$Binding.provider.organizationId}
    # A binding written before these identities has no workspace/host scope
    # until its owner extends it; the other scopes keep working.
    foreach($pair in @(@{kind='workspace';field='localProjectId'},@{kind='host';field='hostId'})){
        $value=[string](Get-ItlCatalogField $identity $pair.field '')
        if($value){$keys[$pair.kind]=$value}
    }
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
    if($Access -eq 'write' -and (-not $DatasetName -or $allowed.Count -ne 1)){throw 'MEMORY_DESTINATION_REQUIRED: select one dataset_name from memory_status destinations. A kept pending source is completed by remember with its note_id and that dataset_name, or discarded by retire_note(note_id).'}
    return $allowed
}

function Get-ItlMemoryPrivateScopes {
    param([object]$Binding)
    $identity=$Binding.identity
    $scopes=@(@{scopeKind='taskCycle';scopeId=$Binding.cycleId;workspaceId=$identity.workspaceId;label=('itl_task_'+$Binding.cycleId)})
    # workspace is the local project (main copy and its branch copies); host is
    # the machine. Both are lazy datasets shared under one technical account.
    $localProject=[string](Get-ItlCatalogField $identity 'localProjectId' '')
    if($localProject){$scopes+=@{scopeKind='workspace';scopeId=$localProject;label=('itl_workspace_'+$localProject)}}
    $scopes+=@{scopeKind='workplace';scopeId=$identity.workplaceId;label=('itl_workplace_'+$identity.workplaceId)}
    $hostId=[string](Get-ItlCatalogField $identity 'hostId' '')
    if($hostId){$scopes+=@{scopeKind='host';scopeId=$hostId;label=('itl_host_'+$hostId)}}
    return $scopes
}

function Find-ItlMemoryNativeDataset {
    param([object]$Binding,[string]$Label,[DateTime]$DeadlineUtc,[object]$Listing=$null)
    if(-not $Listing){$Listing=Invoke-ItlMemoryHttp $Binding.provider GET '/api/v1/datasets' -DeadlineUtc $DeadlineUtc}
    if($Listing.status -ne 200){throw 'MEMORY_DATASET_UNCONFIRMED: the native dataset list is unavailable, so absence is unproven; nothing was created. Repeat the same operation.'}
    return @(@($Listing.body)|Where-Object {$_.name -ceq $Label -and $_.ownerId -ceq $Binding.identity.developerId})
}

function Resolve-ItlMemoryPrivateDataset {
    param([object]$Binding,[string]$Label,[DateTime]$DeadlineUtc,[switch]$LookupOnly,[object]$Listing=$null)
    $private=@(Get-ItlMemoryPrivateScopes $Binding|Where-Object label -CEQ $Label)
    if($private.Count -ne 1){throw 'MEMORY_DESTINATION_REQUIRED: choose an explicit current private label or an admitted shared exact-ID mapping.'}
    $path=Get-ItlMemoryPath binding $Binding.projectRoot;$key=Get-ItlCatalogHash $Label
    $prior=Read-ItlMemoryJson $path;$reservation=Get-ItlCatalogField (Get-ItlCatalogField $prior 'datasetReservations') $key
    # Another copy or user of the same account may already own this dataset:
    # look it up by exact name and owner before any creation.
    $ambiguous='MEMORY_DATASET_AMBIGUOUS: several native datasets carry this exact name and owner. No further dataset was created; an operator keeps one before this scope is used.'
    $found=@(Find-ItlMemoryNativeDataset $Binding $Label $DeadlineUtc $Listing)
    if($found.Count -gt 1){throw $ambiguous}
    $native=if($found.Count){$found[0]}else{$null}
    if(-not $native){
        if($reservation){throw 'MEMORY_DATASET_UNCONFIRMED: confirm the earlier native creation under this ordinary owner; no duplicate dataset was created.'}
        if($LookupOnly){return $null}
        $null=Update-ItlMemoryJson $path {
            param($current)
            if($current.bindingId -cne $Binding.bindingId){throw 'MEMORY_STALE_CONTEXT'}
            if(-not $current.Contains('datasetReservations')){$current['datasetReservations']=[ordered]@{}}
            if($current.datasetReservations.Contains($key)){throw 'MEMORY_DATASET_UNCONFIRMED: another session owns the creation; reconcile its exact ID.'}
            $current.datasetReservations[$key]=@{state='sending';label=$Label};return $current
        }
        $response=Invoke-ItlMemoryHttp $Binding.provider POST '/api/v1/datasets' @{name=$Label} $DeadlineUtc
        if($response.status -eq 200 -or $response.status -eq 201){
            $found=@(Find-ItlMemoryNativeDataset $Binding $Label $DeadlineUtc)
            if($found.Count -gt 1){throw $ambiguous}
            if($found.Count -eq 1 -and [string]$found[0].id -ceq [string]$response.body.id){$native=$found[0]}
        }
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
        if(-not $current.Contains('datasetReservations')){$current['datasetReservations']=[ordered]@{}}
        $current.datasetReservations[$key]=@{state='confirmed';label=$Label;datasetId=$native.id}
        return $current
    }
    $Binding.provider.datasets=$updated.provider.datasets
    return $entry
}

function Sync-ItlMemorySharedPrivateDatasets {
    param([object]$Binding,[DateTime]$DeadlineUtc)
    # A reader adopts the workspace/host dataset another copy or user already
    # created; it never creates one. One list request serves both labels.
    $missing=@(Get-ItlMemoryPrivateScopes $Binding|Where-Object {$label=$_.label;$_.scopeKind -in @('workspace','host') -and @($Binding.provider.datasets|Where-Object label -CEQ $label).Count -eq 0})
    if(-not $missing.Count){return $true}
    try{
        $listing=Invoke-ItlMemoryHttp $Binding.provider GET '/api/v1/datasets' -DeadlineUtc $DeadlineUtc
        foreach($scope in $missing){$null=Resolve-ItlMemoryPrivateDataset $Binding $scope.label $DeadlineUtc -LookupOnly -Listing $listing}
        return $true
    }catch{return $false}
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
    # An intent says status=standing; the stored note says status=verified plus
    # a standing mark, so a copy on the previous workflow reads it as verified.
    $status=[string]$Note.status;$standing=($status -ceq 'standing') -or [bool](Get-ItlCatalogField $Note 'standing' $false)
    if($standing){$status='verified'}
    $value=@{
        fact=(Get-ItlCatalogField $Note 'fact' (Get-ItlCatalogField $Note 'data'))
        applicability=$Note.applicability;evidence=$Note.evidence;status=$status
        source=(Get-ItlCatalogField $origin 'source' (Get-ItlCatalogField $Note 'source' ''))
        revision=(Get-ItlCatalogField $origin 'revision' (Get-ItlCatalogField $Note 'revision' ''))
    }
    # Only present values extend the hash: notes, pending and receipts written
    # before title/standing keep their recorded value.
    $title=[string](Get-ItlCatalogField $Note 'title' '')
    if($title){$value['title']=$title}
    if($standing){$value['standing']=$true}
    return (Get-ItlCatalogHash $value)
}

function Get-ItlMemoryNoteTitle {
    param([object]$Note)
    # An explicit title, else the first sentence of the fact; safe as one
    # segment of a document name.
    $title=[string](Get-ItlCatalogField $Note 'title' '')
    if(-not $title){
        $title=@(([string](Get-ItlCatalogField $Note 'fact' (Get-ItlCatalogField $Note 'data' ''))).Trim() -split "\r?\n")[0]
        $sentence=[regex]::Match($title,('^(.+?[.!?'+[char]0x2026+'])(?:\s|$)'))
        if($sentence.Success){$title=$sentence.Groups[1].Value}
    }
    $title=[regex]::Replace([regex]::Replace($title,'[\p{C}/\\~"]+',' '),'\s+',' ').Trim()
    if($title.Length -gt 80){$title=$title.Substring(0,80).TrimEnd()}
    return $title
}

function Get-ItlMemoryNoteKey {
    param([string]$NoteId)
    return (Get-ItlCatalogHash $NoteId).Substring(0,8)
}

function Get-ItlMemoryDocumentName {
    param([object]$Note)
    # <status>~<knowledge area>~<title>~<id8>.txt. Cognee lists this name and
    # replaces it on every update, so one dataset listing is the index. The
    # original stays authoritative; the name is derived from it.
    $status=if(Get-ItlCatalogField $Note 'standing' $false){'standing'}else{[string]$Note.status}
    $area=''
    if($Note.scope.kind -eq 'product'){$area=[regex]::Replace([string](Get-ItlCatalogField $Note.applicability 'knowledgeArea' ''),'[\p{C}/\\~"\s]+','-')}
    $title=Get-ItlMemoryNoteTitle $Note;$key=Get-ItlMemoryNoteKey ([string]$Note.noteId)
    # The qualified server limit is 255 bytes with its own suffix; keep 200.
    while($title -and [Text.Encoding]::UTF8.GetByteCount(('{0}~{1}~{2}~{3}.txt' -f $status,$area,$title,$key)) -gt 200){$title=$title.Substring(0,$title.Length-1).TrimEnd()}
    return ('{0}~{1}~{2}~{3}.txt' -f $status,$area,$title,$key)
}

function ConvertFrom-ItlMemoryDocumentName {
    param([string]$Name)
    # $null is a note of the previous name format, not an error.
    $match=[regex]::Match([string]$Name,'^(candidate|verified|standing)~([^~]*)~([^~]*)~([0-9a-f]{8})(?:\.txt)?$')
    if(-not $match.Success){return $null}
    return @{status=$match.Groups[1].Value;area=$match.Groups[2].Value;title=$match.Groups[3].Value;key=$match.Groups[4].Value}
}

function Get-ItlMemoryLevelLimits {
    # Maxima per level in the order memory_status reports them:
    # standing notes returned in full / index rows.
    return [ordered]@{
        project=@{standing=5;index=30};workspace=@{standing=2;index=10};organization=@{standing=5;index=30}
        product=@{standing=3;index=20};host=@{standing=3;index=10};workplace=@{standing=3;index=10};taskCycle=@{standing=0;index=10}
    }
}

function Get-ItlMemoryDatasetRows {
    param([object]$Binding,[object]$Dataset,[DateTime]$DeadlineUtc,[object]$Response=$null)
    # One page of up to 1000 documents: ID, parsed name and last change.
    $listing=if($null -ne $Response){$Response}else{Invoke-ItlMemoryHttp $Binding.provider GET "/api/v1/datasets/$($Dataset.datasetId)/data?limit=1000" -DeadlineUtc $DeadlineUtc}
    if($listing.status -ne 200){throw 'MEMORY_DATASET_UNAVAILABLE: the dataset listing is unavailable; repeat the same operation.'}
    return @(foreach($item in @($listing.body)){
        $id=[string](Get-ItlCatalogField $item 'id' '')
        if($id -cnotmatch '^[a-fA-F0-9-]{36}$'){continue}
        @{dataId=$id;dataset=$Dataset;parsed=(ConvertFrom-ItlMemoryDocumentName ([string](Get-ItlCatalogField $item 'name' '')));updatedAt=[string](Get-ItlCatalogField $item 'updatedAt' (Get-ItlCatalogField $item 'createdAt' ''));note=$null}
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

function Test-ItlMemoryAreaApplicable {
    param([object]$Binding,[string]$Area,[string]$ProductId)
    # One rule for recall cards and for index rows of a product dataset.
    $rule=if($Area){Get-ItlCatalogField $Binding.memoryProjection.knowledgeAreas $Area}else{$null}
    if(-not $rule -or (Get-ItlCatalogField $rule 'memoryHomeProductId') -cne $ProductId){return $false}
    $result=Resolve-ItlCatalogArea $Binding.memoryProjection.snapshot $Binding.context.productId $rule (ConvertTo-Agent1cHashtable $Binding.context.knowledgeContext.conditionValues) ([string]$Binding.context.knowledgeContext.productVersion)
    return ($result.status -eq 'applicable')
}

function Test-ItlMemoryNoteApplicable {
    param([object]$Binding,[object]$Note)
    if($Note.status -ne 'verified'){return $false}
    $project=Get-ItlCatalogField $Note.applicability 'projectId'
    if($project -and $project -cne $Binding.context.projectId){return $false}
    if($Note.scope.kind -eq 'taskCycle' -and ($Note.scope.id -cne $Binding.cycleId -or (Get-ItlCatalogField $Note.origin 'projectId') -cne $Binding.context.projectId)){return $false}
    if($Note.scope.kind -eq 'product' -and -not (Test-ItlMemoryAreaApplicable $Binding ([string](Get-ItlCatalogField $Note.applicability 'knowledgeArea' '')) ([string]$Note.scope.id))){return $false}
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
    $rows=@(Get-ItlMemoryDatasetRows $Binding $Dataset $DeadlineUtc);$key=Get-ItlMemoryNoteKey $NoteId;$count=0
    # A current name carries the note key: read those originals first, then
    # names of the previous format. A name with another key is another note.
    $ordered=@($rows|Where-Object {$_.parsed -and $_.parsed.key -ceq $key})+@($rows|Where-Object {-not $_.parsed})
    foreach($row in $ordered){
        if($count++ -ge 24 -or [DateTime]::UtcNow -ge $DeadlineUtc){break}
        $id=$row.dataId
        $note=Get-ItlMemoryOriginal $Binding $Dataset $id $DeadlineUtc
        if($note -and $note.noteId -ceq $NoteId){return [ordered]@{dataId=$id;note=$note}}
    }
    # Absence in a bounded page is never permission to replay an uncertain write.
    return $null
}

function Invoke-ItlMemoryRemember {
    param([object]$Binding,[string]$Data,[string]$DatasetName,[string]$NoteId='', [object]$Applicability=@{},[object[]]$Evidence=@(),[string]$Status='candidate',[string]$Source='', [string]$Revision='',[string]$DataId='',[string]$Title='',[switch]$ContextHold)
    $deadline=[DateTime]::UtcNow.AddSeconds(60)
    if([string]::IsNullOrWhiteSpace($Data) -or [Text.Encoding]::UTF8.GetByteCount($Data) -gt 16384 -or $Status -notin @('candidate','verified','standing')){throw 'MEMORY_NOTE_INVALID: data is one non-empty fact up to 16 KiB; status is candidate, verified or standing.'}
    $Title=$Title.Trim()
    if($Title.Length -gt 80){throw 'MEMORY_NOTE_INVALID: title is at most 80 characters.'}
    if($Status -in @('verified','standing') -and $Evidence.Count -eq 0){throw 'MEMORY_EVIDENCE_REQUIRED: verified and standing need evidence [{source,reference}]; keep an unsupported assumption as candidate.'}
    foreach($proof in $Evidence){if(-not (Get-ItlCatalogField $proof 'source') -and -not (Get-ItlCatalogField $proof 'reference')){throw 'MEMORY_EVIDENCE_REQUIRED: evidence needs an identifiable source/reference.'}}
    if($DataId -and -not $NoteId){throw 'MEMORY_NOTE_ID_REQUIRED: pair the exact native data ID with the recalled note ID.'}
    $intent=[ordered]@{data=$Data;datasetName=$DatasetName;applicability=$Applicability;evidence=$Evidence;status=$Status;source=$Source;revision=$Revision;at=[DateTime]::UtcNow.ToString('o')}
    if($Title){$intent['title']=$Title}
    # The default ID ignores the destination: repeating the same fact with a
    # chosen dataset completes its pending record instead of leaving an orphan.
    if(-not $NoteId){$NoteId=Get-ItlCatalogHash @($Binding.identity.workspaceId,$Binding.context.projectId,$Data)}
    if($NoteId -cnotmatch '^[a-zA-Z0-9._-]{1,128}$'){throw 'MEMORY_NOTE_ID_INVALID'}
    $kept="The pending source is kept under note_id=$NoteId"
    $pendingPath=Join-Path (Join-Path (Join-Path (Get-ItlMemoryHome) 'pending') $Binding.identity.workspaceId) ((Get-ItlCatalogHash $NoteId)+'.json')
    $intentHash=Get-ItlMemoryIntentHash $intent
    $null=Update-ItlMemoryJson $pendingPath {param($old)
        $unresolved=$old -and $old.state -ne 'durable'
        $attempt=if($unresolved){Get-ItlCatalogField $old 'attempt'}else{$null}
        $replaced=@()
        if($unresolved -and $old.Contains('replacedIntents')){foreach($item in @($old['replacedIntents'])){if($item -is [Collections.IDictionary]){$replaced+=,$item}}}
        if($unresolved -and (Get-ItlMemoryIntentHash $old.intent) -cne $intentHash){
            # Only a sent attempt can have a backend effect. An unsent draft is
            # completed under its ID; its replaced intents stay private for audit.
            if($attempt){throw 'MEMORY_PENDING_CONFLICT: this pending note was already sent; reconcile it with memory_status(dataset_name, note_id) before changing it. Only an unsent draft is completed by remember with its note_id and a dataset_name, or discarded by retire_note(note_id).'}
            $replaced+=,$old.intent;if($replaced.Count -gt 4){$replaced=@($replaced[($replaced.Count-4)..($replaced.Count-1)])}
        }
        if($attempt -and ($old.intent.datasetName -cne $DatasetName -or $attempt.instanceId -cne $Binding.provider.instanceId -or $attempt.principalId -cne $Binding.identity.developerId)){throw 'MEMORY_DESTINATION_LOCKED: reconcile the original attempt before changing scope/provider; its source is preserved.'}
        $record=[ordered]@{schemaVersion=1;noteId=$NoteId;workspaceId=$Binding.identity.workspaceId;projectId=$Binding.context.projectId;cycleId=$Binding.cycleId;intent=$intent;state='pending';attempt=$attempt}
        if($replaced.Count){$record['replacedIntents']=$replaced}
        return $record
    }
    # The source survives even when destination/principal/readiness is rejected.
    if($ContextHold){throw "MEMORY_CONTEXT_CHANGED: the task cycle or project changed under this session, so nothing was written. Call memory_status, then repeat remember only if the fact belongs to the new context. $kept."}
    Assert-ItlMemoryBindingCurrent $Binding
    if($Status -eq 'standing' -and $Data.Length -gt 400){throw "MEMORY_STANDING_TOO_LONG: a standing rule is at most 400 characters. Shorten the fact or save it as verified. $kept."}
    $private=@(Get-ItlMemoryPrivateScopes $Binding|Where-Object label -CEQ $DatasetName)
    if($private.Count -and @($Binding.provider.datasets|Where-Object label -CEQ $DatasetName).Count -eq 0){
        Assert-ItlMemoryPrincipal $Binding $deadline
        $null=Resolve-ItlMemoryPrivateDataset $Binding $DatasetName $deadline
    }
    try{$datasets=@(Get-ItlMemoryScopes $Binding write $DatasetName ([string](Get-ItlCatalogField $Applicability 'knowledgeArea')))}
    catch{
        if($_.Exception.Message -notlike 'MEMORY_DESTINATION_REQUIRED*'){throw}
        throw "MEMORY_DESTINATION_REQUIRED: select one dataset_name from memory_status destinations. $kept`: repeat remember with that note_id and the dataset_name, or discard it with retire_note(note_id)."
    }
    $dataset=$datasets[0]
    if($dataset.scopeKind -eq 'product' -and (Get-ItlCatalogField $Binding.context.projectContext 'customized' $false) -and -not (Get-ItlCatalogField $Applicability 'independentOfCustomization' $false)){
        throw 'MEMORY_PROJECT_CANDIDATE: prove independence from customer customizations before a product write; the private pending source is retained.'
    }
    if($dataset.scopeKind -eq 'product' -and $Status -eq 'candidate'){throw 'MEMORY_PROJECT_CANDIDATE: keep an unverified product fact in a private task/project scope.'}
    if($Status -eq 'standing' -and $dataset.scopeKind -eq 'taskCycle'){throw "MEMORY_STANDING_SCOPE: a task note cannot be standing. Save it as verified, or choose a lasting destination. $kept."}
    Assert-ItlMemoryPrincipal $Binding $deadline
    if($Status -eq 'standing'){
        # The level limit counts current standing names of the target dataset;
        # this note itself may already be one of them.
        $limit=(Get-ItlMemoryLevelLimits)[$dataset.scopeKind].standing;$own=Get-ItlMemoryNoteKey $NoteId
        $others=@(Get-ItlMemoryDatasetRows $Binding $dataset $deadline|Where-Object {$_.parsed -and $_.parsed.status -ceq 'standing' -and $_.parsed.key -cne $own})
        if($others.Count -ge $limit){throw "MEMORY_STANDING_LIMIT: this level already holds its $limit standing notes. Move another one to verified (remember its note_id and data_id with status=verified) or save this fact as verified. $kept."}
    }
    $null=Update-ItlMemoryJson $pendingPath {param($old)
        if(-not $old -or $old.intent.datasetName -cne $DatasetName -or (Get-ItlMemoryIntentHash $old.intent) -cne $intentHash){throw 'MEMORY_PENDING_CONFLICT: another call changed this pending note; read it with memory_status(note_id) and repeat the intended remember once.'}
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
            $receipt=[ordered]@{schemaVersion=1;state='durable';noteId=$NoteId;datasetId=$dataset.datasetId;dataId=$found.dataId;contentHash=$intentHash;status=$Status}
            $null=Update-ItlMemoryJson $receiptPath {param($old) if((Get-ItlCatalogHash $old) -cne $existingHash){throw 'MEMORY_WRITE_IN_FLIGHT'};return $receipt}
            Complete-ItlMemoryPending $Binding $NoteId $intentHash
            return $receipt
        }
        # A confirmed existing original is updated precisely, never superseded
        # merely by a second semantic hit with no authoritative old-ID update.
        $existing['dataId']=$found.dataId
    }
    # standing is stored as verified plus a mark: a copy on the previous
    # workflow reads an ordinary verified note and ignores the extra fields.
    $note=[ordered]@{format='itl-memory-v1';noteId=$NoteId;fact=$Data;scope=@{kind=$dataset.scopeKind;id=$dataset.scopeId};date=[DateTime]::UtcNow.ToString('o');status=$(if($Status -eq 'standing'){'verified'}else{$Status});origin=@{projectId=$Binding.context.projectId;workspaceId=$Binding.identity.workspaceId;cycleId=$Binding.cycleId;source=$Source;revision=$Revision};applicability=$Applicability;evidence=$Evidence}
    if($Status -eq 'standing'){$note['standing']=$true}
    if($Title){$note['title']=$Title}
    $updating=[bool]($existing -and $existing.dataId -and $found)
    if($updating){$note['updatedByOrigin']=$note.origin;$note['origin']=$found.note.origin;$note['supersedes']=$found.note.noteId}
    $text=ConvertTo-Json -InputObject $note -Depth 40 -Compress
    $receipt=[ordered]@{schemaVersion=1;state='sending';attemptId=[guid]::NewGuid().ToString('N');noteId=$NoteId;datasetId=$dataset.datasetId;dataId=$(if($existing){Get-ItlCatalogField $existing 'dataId' ''}else{''});contentHash=$intentHash;status=$Status}
    $null=Update-ItlMemoryJson $receiptPath {
        param($old)
        if((Get-ItlCatalogHash $old) -cne $existingHash){throw 'MEMORY_WRITE_IN_FLIGHT: use exact status reconciliation, not a concurrent remember.'}
        return $receipt
    }
    try{
        # Content and its derived document name travel in one request, on
        # creation and on every update.
        $boundary='itl_'+[guid]::NewGuid().ToString('N')
        $file="--$boundary`r`nContent-Disposition: form-data; name=`"data`"; filename=`"$(Get-ItlMemoryDocumentName $note)`"`r`nContent-Type: text/plain; charset=utf-8`r`n`r`n$text`r`n"
        if($receipt.dataId){
            $result=Invoke-ItlMemoryHttp $Binding.provider PATCH "/api/v1/update?data_id=$($receipt.dataId)&dataset_id=$($dataset.datasetId)&chunk_level_diff=true" ($file+"--$boundary--`r`n") $deadline -ContentType ("multipart/form-data; boundary="+$boundary)
        }else{
            $fields=''
            foreach($field in @(@{name='datasetId';value=$dataset.datasetId},@{name='self_improvement';value='false'},@{name='run_in_background';value='false'})){
                $fields+="--$boundary`r`nContent-Disposition: form-data; name=`"$($field.name)`"`r`n`r`n$($field.value)`r`n"
            }
            $result=Invoke-ItlMemoryHttp $Binding.provider POST '/api/v1/remember' ($file+$fields+"--$boundary--`r`n") $deadline -ContentType ("multipart/form-data; boundary="+$boundary)
        }
        if($result.status -eq 409 -and -not $receipt.dataId){
            # A name is unique per note: the existing document is this note from
            # an earlier accepted request. Reconcile it by exact ID, no replay.
            $found=Find-ItlMemoryNativeNote $Binding $dataset $NoteId $deadline
            if($found){$receipt.dataId=$found.dataId;$receipt.state=if((Get-ItlMemoryIntentHash $found.note) -ceq $intentHash){'durable'}else{'unconfirmed'}}
            else{$receipt.state='rejected'}
        }
        elseif($result.status -ge 400 -and $result.status -lt 500){$receipt.state='rejected'}
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
    $receipt['operation']=if($updating){'updated'}else{'saved'}
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
    $null=Sync-ItlMemorySharedPrivateDatasets $Binding $deadline
    $allowed=@(Get-ItlMemoryScopes $Binding read);$selected=@($allowed)
    if($Datasets.Count){
        foreach($label in $Datasets){if(@($allowed|Where-Object label -CEQ $label).Count -ne 1){throw 'MEMORY_READ_SCOPE_DENIED'}}
        $selected=@($allowed|Where-Object {$Datasets -ccontains $_.label})
    }
    if(-not $selected.Count){return @{cards=@();coverage='unavailable';continuation='Prepare admitted dataset IDs/grants; no unscoped recall was sent.'}}
    $ids=@($selected|ForEach-Object {$_.datasetId}|Select-Object -Unique)
    $result=Invoke-ItlMemoryHttp $Binding.provider POST '/api/v1/recall' @{query=$Query;dataset_ids=$ids;search_type=$SearchType;top_k=24;only_context=$false} $deadline
    if($result.status -ne 200){return @{cards=@();coverage='unavailable';continuation='Preserve the scope and verify native access; required coverage remains incomplete.'}}
    # Native Cognee answers datasets without graph data by one system status
    # row instead of chunks. That is known absence, not unattributed results.
    $statusRows=@(@($result.body)|Where-Object {([string](Get-ItlCatalogField $_ 'source')) -ceq 'system' -and -not (Get-ItlCatalogField $_ 'dataset_id')})
    if($statusRows.Count -and $statusRows.Count -eq @($result.body).Count -and -not @($statusRows|Where-Object {([string](Get-ItlCatalogField $_ 'status')) -cne 'memory_warming_up'}).Count){
        return [ordered]@{cards=@();coverage='empty';backendStatus='memory_warming_up';sourceLookups=0;backendCalls=2;continuation='Selected datasets hold no indexed notes yet: absence, not partial coverage. A just-saved note may still be indexing; check it by exact memory_status.';context=@{projectId=$Binding.context.projectId;catalogRevision=$Binding.context.catalogRevision;cycleId=$Binding.cycleId}}
    }
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
        if(Get-ItlCatalogField $note 'standing' $false){$card['standing']=$true}
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
    $pending=@();$cycle=Read-ItlMemoryJson $Binding.cycleStatePath -Kind 'branch-state'
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
            $row=[ordered]@{noteId=$record.noteId;state=$record.state;datasetName=$label;status=[string](Get-ItlCatalogField $record.intent 'status' '');sent=[bool](Get-ItlCatalogField $record 'attempt');fact=$(if($NoteId){$record.intent.data}else{([string]$record.intent.data).Substring(0,[Math]::Min(180,([string]$record.intent.data).Length))});sourcePreserved=$true}
            if($NoteId){foreach($field in @('applicability','evidence','source','revision')){$row[$field]=Get-ItlCatalogField $record.intent $field}}
            $pending+=,$row
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
    })+@(Get-ItlMemoryScopes $Binding read|Where-Object {$_.scopeKind -notin @('taskCycle','workspace','workplace','host','product') -and @($_.permissions) -contains 'write'}|ForEach-Object {@{label=$_.label;scopeKind=$_.scopeKind;scopeId=$_.scopeId}})
    # One row per dataset: a product lists its writable knowledge areas.
    foreach($product in @(Get-ItlMemoryScopes $Binding read|Where-Object {$_.scopeKind -eq 'product' -and @($_.permissions) -contains 'write'})){
        $areas=@($Binding.context.knowledgeContext.knowledgeAreas|Where-Object {$_.status -eq 'applicable' -and $_.memoryHomeProductId -ceq $product.scopeId}|ForEach-Object {$_.areaId})
        if($areas.Count){$destinations+=@{label=$product.label;scopeKind=$product.scopeKind;scopeId=$product.scopeId;knowledgeAreas=$areas}}
    }
    $bindingState='current'
    try{Assert-ItlMemoryBindingCurrent $Binding}catch{$bindingState='stale-or-disabled';$destinations=@()}
    $receipts=@();$candidates=@();$receiptRoot=Join-Path (Get-ItlMemoryHome) 'receipt'
    if($bindingState -eq 'current' -and (Test-Path -LiteralPath $receiptRoot -PathType Container)){
        $readScopes=@(Get-ItlMemoryScopes $Binding read);$readIds=@($readScopes|ForEach-Object {$_.datasetId})
        foreach($file in @(Get-ChildItem -LiteralPath $receiptRoot -File -Filter '*.json'|Sort-Object LastWriteTimeUtc -Descending|Select-Object -First 24)){
            $record=Read-ItlMemoryJson $file.FullName
            if(-not $record -or $readIds -cnotcontains $record.datasetId -or ($NoteId -and $record.noteId -cne $NoteId)){continue}
            $expected=Get-ItlMemoryPath receipt (Get-ItlMemoryRecordKey $Binding $record.datasetId $record.noteId)
            if($expected -ine $file.FullName){continue}
            # recall never returns candidates, so this owner is the only place
            # a writer finds them again. Older receipts derive status from the
            # exact private source of the same note.
            $noteStatus=[string](Get-ItlCatalogField $record 'status' '');$source=$null
            if(-not $noteStatus -or $noteStatus -ceq 'candidate'){
                $source=Read-ItlMemoryJson (Join-Path (Join-Path (Join-Path (Get-ItlMemoryHome) 'source') $Binding.identity.workspaceId) ((Get-ItlCatalogHash $record.noteId)+'.json'))
                if($source -and $source.noteId -cne $record.noteId){$source=$null}
                if(-not $noteStatus -and $source){$noteStatus=[string](Get-ItlCatalogField $source.intent 'status' '')}
            }
            if($receipts.Count -lt 4){$receipts+=@{noteId=$record.noteId;datasetId=$record.datasetId;dataId=(Get-ItlCatalogField $record 'dataId' '');state=$record.state;status=$(if($noteStatus){$noteStatus}else{'unknown'});searchState=(Get-ItlCatalogField $record 'searchState' 'unverified');currentness='local receipt only'}}
            if($noteStatus -ceq 'candidate' -and $record.state -eq 'durable' -and $candidates.Count -lt 4){
                $fact=if($source){[string]$source.intent.data}else{''}
                if($fact.Length -gt 400){$fact=$fact.Substring(0,400)+'...'}
                $candidates+=@{noteId=$record.noteId;dataId=(Get-ItlCatalogField $record 'dataId' '');dataset=@($readScopes|Where-Object datasetId -CEQ $record.datasetId)[0].label;fact=$fact}
            }
            if($receipts.Count -ge 4 -and $candidates.Count -ge 4){break}
        }
    }
    $output=[ordered]@{pending=$pending;receipts=$receipts;candidates=$candidates;preservedSource=$preservedSource;continuation=$continuation;coverage='bounded-local; old task pending is history, not current';destinations=$destinations;currentCycleId=$currentCycle;bindingState=$bindingState}
    if($candidates.Count){$output.candidateAction='recall omits candidates. At user confirmation, a fresh passed check or before the final report: remember the same note_id and data_id with status=verified and evidence, or retire_note a disproved one.'}
    return $output
}

function Invoke-ItlMemoryReads {
    param([object]$Provider,[string[]]$Paths,[DateTime]$DeadlineUtc,[switch]$Raw)
    # At most two requests in flight, completed in request order. A failed or
    # late read is $null: its caller reports partial coverage.
    $pending=[object[]]::new($Paths.Count);$responses=[object[]]::new($Paths.Count);$started=0
    try{
        for($position=0;$position -lt $Paths.Count;$position++){
            while($started -lt $Paths.Count -and $started -le $position+1 -and [DateTime]::UtcNow -lt $DeadlineUtc){
                try{$pending[$started]=Invoke-ItlMemoryHttp $Provider GET $Paths[$started] -DeadlineUtc $DeadlineUtc -Raw:$Raw -Defer}catch{}
                $started++
            }
            if($pending[$position]){
                try{$responses[$position]=Complete-ItlMemoryHttp $pending[$position]}catch{}
                $pending[$position]=$null
            }
        }
    }finally{foreach($item in $pending){if($item){Close-ItlMemoryHttp $item}}}
    return ,$responses
}

function Measure-ItlMemoryStatusTokens {
    param([object]$Value)
    # The same counter as recall; an unmeasurable text keeps the conservative
    # byte bound (a token is at least one byte).
    $json=ConvertTo-Json -InputObject $Value -Depth 30 -Compress
    try{
        if(-not (Test-Path -LiteralPath 'Function:\Measure-ItlMemoryTokens')){. (Join-Path $PSScriptRoot 'agent-1c.memory-tokens.ps1')}
        $tokens=Measure-ItlMemoryTokens $json
        if($tokens.measurement -eq 'measured-encode-ordinary'){return [Math]::Max([int]$tokens.cl100k_base,[int]$tokens.o200k_base)}
    }catch{}
    return [Text.Encoding]::UTF8.GetByteCount($json)
}

function Get-ItlMemoryOverview {
    param([object]$Binding,[DateTime]$DeadlineUtc)
    # Standing notes in full plus an index of the other notes, from one listing
    # per admitted dataset. Originals are read only for standing notes and for
    # at most six names of the previous format. No cache between operations.
    $limits=Get-ItlMemoryLevelLimits;$partial=$false;$missing=@()
    $scopes=@(Get-ItlMemoryScopes $Binding read)
    $responses=Invoke-ItlMemoryReads $Binding.provider @($scopes|ForEach-Object {"/api/v1/datasets/$($_.datasetId)/data?limit=1000"}) $DeadlineUtc
    $rows=@()
    for($i=0;$i -lt $scopes.Count;$i++){
        try{
            if(-not $responses[$i]){throw 'MEMORY_DATASET_UNAVAILABLE'}
            $listed=@(Get-ItlMemoryDatasetRows $Binding $scopes[$i] $DeadlineUtc -Response $responses[$i])
            # A full page may hide further notes.
            if($listed.Count -ge 1000){$partial=$true}
            $rows+=$listed
        }catch{$partial=$true;$missing+=$scopes[$i].label}
    }
    # A product row of an inapplicable knowledge area is not this context's.
    $rows=@($rows|Where-Object {-not $_.parsed -or $_.dataset.scopeKind -ne 'product' -or (Test-ItlMemoryAreaApplicable $Binding $_.parsed.area ([string]$_.dataset.scopeId))})
    $order={param($items) @($items|Sort-Object @{Expression={if($_.parsed -and $_.parsed.status -ceq 'candidate'){1}else{0}}},@{Expression={$_.updatedAt};Descending=$true})}
    $levels=[ordered]@{}
    foreach($kind in $limits.Keys){$levels[$kind]=@{rows=@(& $order @($rows|Where-Object {$_.dataset.scopeKind -eq $kind}));more=0}}
    # Names of the previous format: status and title come from the original.
    $legacy=@(foreach($kind in $limits.Keys){$levels[$kind].rows|Where-Object {-not $_.parsed}})
    $readable=@($legacy|Select-Object -First 6)
    $originals=Invoke-ItlMemoryReads $Binding.provider @($readable|ForEach-Object {"/api/v1/datasets/$($_.dataset.datasetId)/data/$($_.dataId)/raw"}) $DeadlineUtc -Raw
    for($i=0;$i -lt $readable.Count;$i++){
        $row=$readable[$i];$note=$null
        try{if($originals[$i]){$note=Get-ItlMemoryOriginal $Binding $row.dataset $row.dataId $DeadlineUtc -Response $originals[$i]}else{$partial=$true}}catch{$partial=$true}
        if(-not $note){continue}
        $area=[string](Get-ItlCatalogField $note.applicability 'knowledgeArea' '')
        if($row.dataset.scopeKind -eq 'product' -and -not (Test-ItlMemoryAreaApplicable $Binding $area ([string]$row.dataset.scopeId))){continue}
        $row.note=$note
        $row.parsed=@{status=$(if(Get-ItlCatalogField $note 'standing' $false){'standing'}else{[string]$note.status});area=$area;title=(Get-ItlMemoryNoteTitle $note);key=(Get-ItlMemoryNoteKey ([string]$note.noteId))}
    }
    foreach($kind in $limits.Keys){
        $level=$levels[$kind]
        # An unread legacy name is counted, an unusable document is dropped.
        $level.more+=@($level.rows|Where-Object {-not $_.parsed -and $readable -notcontains $_}).Count
        $level.rows=@(& $order @($level.rows|Where-Object {$_.parsed}))
        $level.standing=@($level.rows|Where-Object {$_.parsed.status -ceq 'standing'}|Select-Object -First $limits[$kind].standing)
    }
    # Each standing note is confirmed and checked in full by its original.
    $candidates=@(foreach($kind in $limits.Keys){$levels[$kind].standing|Where-Object {-not $_.note}})
    $originals=Invoke-ItlMemoryReads $Binding.provider @($candidates|ForEach-Object {"/api/v1/datasets/$($_.dataset.datasetId)/data/$($_.dataId)/raw"}) $DeadlineUtc -Raw
    for($i=0;$i -lt $candidates.Count;$i++){
        $row=$candidates[$i]
        try{if($originals[$i]){$row.note=Get-ItlMemoryOriginal $Binding $row.dataset $row.dataId $DeadlineUtc -Response $originals[$i]}}catch{}
        if(-not $row.note){$partial=$true}
    }
    $standing=@();$index=@()
    foreach($kind in $limits.Keys){
        $level=$levels[$kind];$confirmed=@();$dropped=@()
        foreach($row in $level.standing){
            if(-not $row.note){continue} # unread: stays an index row under its listed name
            if(-not (Get-ItlCatalogField $row.note 'standing' $false)){$row.parsed.status=[string]$row.note.status;$row.parsed.title=Get-ItlMemoryNoteTitle $row.note;continue}
            if(-not (Test-ItlMemoryNoteApplicable $Binding $row.note)){$dropped+=,$row;continue}
            $confirmed+=,$row
            $standing+=,[ordered]@{level=$kind;dataset=$row.dataset.label;noteId=$row.note.noteId;dataId=$row.dataId;fact=$row.note.fact}
        }
        $rest=@(& $order @($level.rows|Where-Object {$confirmed -notcontains $_ -and $dropped -notcontains $_}))
        $shown=@($rest|Select-Object -First $limits[$kind].index)
        $level.more+=$rest.Count-$shown.Count
        if($shown.Count -or $level.more){
            $index+=,[ordered]@{level=$kind;notes=@($shown|ForEach-Object {$(if($_.parsed.title){$_.parsed.title}else{'(untitled)'})+$(if($_.parsed.status -cne 'verified'){' ['+$_.parsed.status+']'}else{''})});more=$level.more}
        }
    }
    return [ordered]@{standing=$standing;index=$index;coverage=$(if($partial){'partial'}else{'bounded'});unavailable=$missing}
}

function Get-ItlMemoryStatusOverview {
    param([object]$Binding)
    # Session start: the local part always, then the server part within one
    # bounded deadline. The task never depends on the server part.
    $output=Get-ItlMemoryLocalContext $Binding
    $output['standing']=@();$output['index']=@()
    if($output.bindingState -ne 'current'){$output['serverCoverage']='unavailable: the binding is stale or disabled; local part only';return $output}
    $deadline=[DateTime]::UtcNow.AddSeconds(15)
    try{
        Assert-ItlMemoryPrincipal $Binding $deadline
        $null=Sync-ItlMemorySharedPrivateDatasets $Binding $deadline
        $overview=Get-ItlMemoryOverview $Binding $deadline
    }catch{
        $code=($_.Exception.Message -split ':')[0];if($code -cnotmatch '^MEMORY_[A-Z_]+$'){$code='MEMORY_OPERATION_UNCONFIRMED'}
        $output['serverCoverage']="unavailable: $code; local part only. A missing index is not absence of knowledge; recall still applies"
        return $output
    }
    $output['serverCoverage']=$(if($overview.coverage -eq 'partial'){'partial: some datasets or originals were not read in time'+$(if(@($overview.unavailable).Count){' ('+(@($overview.unavailable) -join ', ')+')'}else{''})+'; not absence of knowledge'}else{'bounded'})
    $output['indexUse']='standing: rules in force. index: titles only, verified unless marked; read content with recall. more: further notes, find them with recall.'
    # 2000 tokens for the whole answer: standing notes first, then index rows,
    # in level order. Whatever does not fit is counted in more.
    $budget=2000;$used=(Measure-ItlMemoryStatusTokens $output)+40
    $moreOf={param($kind) $entry=@($output.index|Where-Object {$_.level -eq $kind});if(-not $entry.Count){$entry=@([ordered]@{level=$kind;notes=@();more=0});$output.index=@($output.index)+$entry};$entry[0]}
    foreach($note in @($overview.standing)){
        $cost=(Measure-ItlMemoryStatusTokens $note)+2
        if($used+$cost -le $budget){$output.standing=@($output.standing)+@($note);$used+=$cost}else{$omitted=& $moreOf $note.level;$omitted.more++;$used+=12}
    }
    foreach($level in @($overview.index)){
        $entry=& $moreOf $level.level;$entry.more+=$level.more;$used+=12
        foreach($title in @($level.notes)){
            $cost=(Measure-ItlMemoryStatusTokens $title)+1
            if($used+$cost -le $budget){$entry.notes=@($entry.notes)+@($title);$used+=$cost}else{$entry.more++}
        }
    }
    $output.index=@($output.index|Where-Object {@($_.notes).Count -or $_.more})
    # The estimate above is per item; converge on the measured whole answer.
    while((Measure-ItlMemoryStatusTokens $output) -gt $budget){
        $last=@($output.index|Where-Object {@($_.notes).Count})|Select-Object -Last 1
        if($last){$last.notes=@($last.notes|Select-Object -SkipLast 1);$last.more++;continue}
        if(@($output.standing).Count){
            $dropped=@($output.standing)[-1];$output.standing=@(@($output.standing)|Select-Object -SkipLast 1)
            $entry=& $moreOf $dropped.level;$entry.more++;continue
        }
        # Only the local part is left: keep continuation and pending, shed the
        # rest. memory_status(local_only=true) still returns it in full.
        $output['localTrimmed']='local part shortened for the 2000-token bound; local_only=true returns it in full'
        if(@($output.receipts).Count){$output.receipts=@();continue}
        if(@($output.candidates).Count){$output.candidates=@(@($output.candidates)|Select-Object -SkipLast 1);continue}
        if(@($output.index).Count){$output.index=@();continue}
        if(@($output.pending).Count -gt 1){$output.pending=@(@($output.pending)|Select-Object -SkipLast 1);continue}
        break
    }
    return $output
}

function Invoke-ItlMemoryStatus {
    param([object]$Binding,[string]$DatasetName='', [string]$NoteId='', [string]$DataId='',[switch]$LocalOnly,[switch]$History)
    if($LocalOnly -or (-not $DatasetName -and ($NoteId -or $DataId))){return Get-ItlMemoryLocalContext $Binding $NoteId -History:$History}
    if(-not $DatasetName){return Get-ItlMemoryStatusOverview $Binding}
    Assert-ItlMemoryBindingCurrent $Binding
    $deadline=[DateTime]::UtcNow.AddSeconds(60);Assert-ItlMemoryPrincipal $Binding $deadline
    $scope=@(if($History -and ($NoteId -or $DataId)){
        # History by exact ID: an old task cycle of this copy, or the per-copy
        # workspace dataset this copy used before workspace became the local
        # project. Such notes are not migrated and never join union recall.
        @($Binding.provider.datasets|Where-Object {$_.label -ceq $DatasetName -and $_.admitted -and @($_.permissions) -ccontains 'read' -and (
            ($_.scopeKind -eq 'taskCycle' -and $_.label -ceq ('itl_task_'+$_.scopeId) -and (Get-ItlCatalogField $_ 'workspaceId') -ceq $Binding.identity.workspaceId) -or
            ($_.scopeKind -eq 'workspace' -and $_.scopeId -ceq $Binding.identity.workspaceId -and $_.label -ceq ('itl_workspace_'+$_.scopeId)))})
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

function Remove-ItlMemoryUnsentDraft {
    param([object]$Binding,[string]$NoteId)
    # A draft without attempt never reached the backend. Discard it under its
    # record guard, keeping a private audit copy beside the preserved sources.
    $path=Join-Path (Join-Path (Join-Path (Get-ItlMemoryHome) 'pending') $Binding.identity.workspaceId) ((Get-ItlCatalogHash $NoteId)+'.json')
    $outcome=@{discarded=$false}
    if(Test-Path -LiteralPath $path){
        $null=Update-ItlMemoryJson $path {param($old)
            if(-not $old -or $old.state -eq 'durable' -or $old.noteId -cne $NoteId -or (Get-ItlCatalogField $old 'attempt')){return $old}
            $audit=Join-Path (Join-Path (Join-Path (Get-ItlMemoryHome) 'source') $Binding.identity.workspaceId) ((Get-ItlCatalogHash $NoteId)+'.discarded.json')
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $audit))
            $old['state']='discarded';$old['discardedAt']=[DateTime]::UtcNow.ToString('o')
            Write-Utf8TextAtomic $audit (ConvertTo-Json -InputObject $old -Depth 60 -Compress)
            $outcome.discarded=$true
            return $null
        } -RemoveWhenEmpty
    }
    return $outcome.discarded
}

function Invoke-ItlMemoryRetire {
    param([object]$Binding,[string]$DatasetName,[string]$NoteId,[string]$KnowledgeArea='',[string]$DataId='')
    Assert-ItlMemoryBindingCurrent $Binding
    $discarded=[ordered]@{state='discarded-unsent';noteId=$NoteId;auditPreserved=$true}
    if(-not $DatasetName){
        if(Remove-ItlMemoryUnsentDraft $Binding $NoteId){return $discarded}
        throw 'MEMORY_ARGUMENT_REQUIRED: name the dataset of a sent note (dataset_name, and data_id from its recall card); note_id alone discards only an own unsent pending draft.'
    }
    $deadline=[DateTime]::UtcNow.AddSeconds(60);Assert-ItlMemoryPrincipal $Binding $deadline
    $scopes=@(Get-ItlMemoryScopes $Binding write $DatasetName $KnowledgeArea);$dataset=$scopes[0]
    $key=Get-ItlMemoryRecordKey $Binding $dataset.datasetId $NoteId;$path=Get-ItlMemoryPath receipt $key
    $record=Read-ItlMemoryJson $path
    $exactId=if($DataId){$DataId}elseif($record){Get-ItlCatalogField $record 'dataId' ''}else{''}
    $found=if($exactId){$n=Get-ItlMemoryOriginal $Binding $dataset $exactId $deadline;if($n){@{dataId=$exactId;note=$n}}}else{Find-ItlMemoryNativeNote $Binding $dataset $NoteId $deadline}
    if(-not $found -and -not $record -and (Remove-ItlMemoryUnsentDraft $Binding $NoteId)){return $discarded}
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
    }
    # A retired note can never accept its unsent update; do not leave it pending.
    if($receipt.state -eq 'retired'){$null=Remove-ItlMemoryUnsentDraft $Binding $NoteId}
    return $receipt
}

function Add-ItlMemoryUsage {
    param([object]$Binding,[string]$Tool,[string]$SessionId,[string]$Outcome='ok',[object]$Result=$null)
    # Private call journal of this working copy: what was called and how it
    # ended, never the query or a fact. A journal failure changes no result.
    try{
        $entry=[ordered]@{at=[DateTime]::UtcNow.ToString('o');tool=$Tool;session=$SessionId;cycleId=[string](Get-ItlCatalogField $Binding 'cycleId' '');outcome=($Outcome -split ':')[0]}
        $kind=[regex]::Match($Outcome,'kind=([a-z-]+)')
        if($kind.Success){$entry['recordKind']=$kind.Groups[1].Value}
        if($Result -is [Collections.IDictionary]){
            if($Result.Contains('cards')){$entry['cards']=@($Result['cards']).Count}
            $state=[string](Get-ItlCatalogField $Result 'state' '');$operation=[string](Get-ItlCatalogField $Result 'operation' '')
            if($state -eq 'durable' -and $operation -in @('saved','updated')){$entry[$operation]=1}
            if($Tool -eq 'retire_note' -and $state -in @('retired','discarded-unsent')){$entry['retired']=1}
        }
        $workspaceId=[string]$Binding.identity.workspaceId
        $null=Update-ItlMemoryJson (Get-ItlMemoryPath usage $workspaceId) {param($old)
            $entries=@(if($old){@($old.entries)})+@($entry)
            if($entries.Count -gt 200){$entries=@($entries[($entries.Count-200)..($entries.Count-1)])}
            return [ordered]@{schemaVersion=1;workspaceId=$workspaceId;entries=$entries}
        }
    }catch{}
}

function Get-ItlMemoryUsageSummary {
    param([object]$Binding)
    # Read-only summary of the current task cycle for status and /itl-check.
    $cycleId=[string](Get-ItlCatalogField $Binding 'cycleId' '')
    $journal=Read-ItlMemoryJson (Get-ItlMemoryPath usage ([string]$Binding.identity.workspaceId))
    $entries=@(if($journal){@($journal.entries)|Where-Object {$_.cycleId -ceq $cycleId}})
    $summary=[ordered]@{cycleId=$cycleId;calls=$entries.Count;sessions=@($entries|ForEach-Object {$_.session}|Select-Object -Unique).Count}
    foreach($tool in @('memory_status','recall','remember','retire_note')){$summary[$tool]=@($entries|Where-Object tool -CEQ $tool).Count}
    foreach($counter in @('saved','updated','retired')){$summary[$counter]=@($entries|Where-Object {Get-ItlCatalogField $_ $counter}).Count}
    $failed=@($entries|Where-Object {$_.outcome -cne 'ok'})
    $summary['errors']=$failed.Count
    if($failed.Count){$summary['lastErrors']=@($failed|Select-Object -Last 3|ForEach-Object {$_.outcome+$(if(Get-ItlCatalogField $_ 'recordKind'){' ('+$_.recordKind+')'}else{''})})}
    return $summary
}

function Get-ItlMemoryUsageLine {
    param([string]$ProjectRoot)
    # Informational only: $null while memory is not enabled for this copy.
    $binding=Read-ItlMemoryJson (Get-ItlMemoryPath binding $ProjectRoot)
    if(-not $binding -or $binding.mode -ne 'enabled'){return $null}
    $summary=Get-ItlMemoryUsageSummary $binding
    return ('Memory (current task cycle): recall: {0}, remember: {1}; saved {2}, updated {3}, retired {4}, errors {5}.' -f $summary.recall,$summary.remember,$summary.saved,$summary.updated,$summary.retired,$summary.errors)
}