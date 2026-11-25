# Read-only comparison owned by the existing project-context path. No transport or state.
function Get-ItlSourceToolPayload {
    param([object]$Exchange,[string[]]$Tools)
    $request=Get-ItlCatalogField $Exchange 'request'
    $response=Get-ItlCatalogField $Exchange 'response'
    $params=Get-ItlCatalogField $request 'params'
    $method=Get-ItlCatalogField $request 'method'
    $native=$method -ceq 'mcpServer/tool/call'
    $tool=if($native){Get-ItlCatalogField $params 'tool'}else{Get-ItlCatalogField $params 'name'}
    if($method -cnotin @('tools/call','mcpServer/tool/call') -or
        $tool -cnotin $Tools -or
        $null -eq (Get-ItlCatalogField $request 'id') -or
        [string](Get-ItlCatalogField $request 'id') -cne [string](Get-ItlCatalogField $response 'id') -or
        $null -ne (Get-ItlCatalogField $response 'error')){throw 'SOURCE_EVIDENCE_PROTOCOL'}
    $result=Get-ItlCatalogField $response 'result'
    $isError=Get-ItlCatalogField $result 'isError' $false
    if($isError -isnot [bool] -or $isError){throw 'SOURCE_EVIDENCE_TOOL_ERROR'}
    $payload=Get-ItlCatalogField $result 'structuredContent'
    $text=@((Get-ItlCatalogField $result 'content' @())|Where-Object {(Get-ItlCatalogField $_ 'type') -ceq 'text'})
    if($text.Count -eq 1){
        $decoded=ConvertTo-Vibecoding1cMcpHashtable (ConvertFrom-Json -InputObject $text[0].text -ErrorAction Stop)
        if($null -ne $payload -and (Get-ItlCatalogHash $payload) -cne (Get-ItlCatalogHash $decoded)){throw 'SOURCE_EVIDENCE_AMBIGUOUS_PAYLOAD'}
        $payload=$decoded
    } elseif($text.Count -gt 1){throw 'SOURCE_EVIDENCE_AMBIGUOUS_PAYLOAD'}
    if($null -eq $payload -or $null -ne (Get-ItlCatalogField $payload 'error') -or
        (Get-ItlCatalogField $payload 'status') -in @('error','failed','unavailable') -or
        (Get-ItlCatalogField $payload 'indexing_status') -eq 'in_progress'){throw 'SOURCE_EVIDENCE_NOT_USABLE'}
    return [pscustomobject]@{payload=$payload;request=$request;tool=$tool;arguments=(Get-ItlCatalogField $params 'arguments' @{});native=$native;server=(Get-ItlCatalogField $params 'server');sessionId=(Get-ItlCatalogField $params 'threadId')}
}

function Compare-ItlProductSourceObservation {
    param([object]$Context,[ValidateSet('code','graph')][string]$Role,[object]$Observation)
    $intent=Get-ItlCatalogField $Context.endpointIntents $Role
    $result=[ordered]@{binding='unverified';clientActivation='unverified';versionConstraint='not-requested';reason='observation-missing';checkedAt=$null;continuation='Use the selected registry source, or continue with local code. No server patch or reindex is required.'}
    if(-not $intent){$result.reason=if((Get-ItlCatalogField $Context.roles[$Role] 'mode') -eq 'disabled'){'disabled'}else{'not-configured'};return $result}
    $pin=Get-ItlCatalogField $intent 'versionPin' @{}
    $wanted=Get-ItlCatalogField $pin 'configurationVersion'
    $published=Get-ItlCatalogField (Get-ItlCatalogField $intent 'registry') 'configurationVersion'
    if($wanted){$result.versionConstraint=if(-not $published){'unverified'}elseif($wanted -ceq $published){'matched'}else{'mismatch'}}
    if((Get-ItlCatalogField $pin 'revision') -or (Get-ItlCatalogField $pin 'revisionKind')){$result.versionConstraint='unverified'}
    if(-not $Observation){return $result}
    try {
        $date=[DateTimeOffset]::MinValue
        $checked=Get-ItlCatalogField $Observation 'checkedAt'
        if($checked -is [DateTime] -or $checked -is [DateTimeOffset]){$date=[DateTimeOffset]$checked}
        elseif(-not [DateTimeOffset]::TryParse([string]$checked,[ref]$date)){throw 'SOURCE_EVIDENCE_DATE'}
        $result.checkedAt=$date.ToUniversalTime().ToString('o')
        if((Get-ItlCatalogField $Observation 'endpoint') -cne $intent.url){$result.binding='mismatch';$result.reason='endpoint-mismatch';return $result}
        $meta=$null
        if(Get-ItlCatalogField $Observation 'metadata'){
            $metaTool=if($Role -eq 'code'){'stats'}else{'get_graph_project_status'}
            $meta=Get-ItlSourceToolPayload (Get-ItlCatalogField $Observation 'metadata') @($metaTool)
        }
        $readTools=if($Role -eq 'code'){@('get_module_structure','search_function')}else{@('search_code')}
        $read=Get-ItlSourceToolPayload (Get-ItlCatalogField $Observation 'read') $readTools
        $client=Get-ItlCatalogField $Observation 'client'
        $ids=@((Get-ItlCatalogField $client 'requestIds' @()))
        $canonical=if($Role -eq 'code'){'1c-code-metadata-mcp'}else{'1c-graph-metadata-mcp'}
        $native=$read.native -and $read.server -ceq $canonical -and $read.sessionId -ceq (Get-ItlCatalogField $client 'sessionId') -and $read.request.id -in $ids
        if($meta){$native=$native -and $meta.native -and $meta.server -ceq $canonical -and $meta.sessionId -ceq $read.sessionId -and $meta.request.id -in $ids -and $meta.request.id -cne $read.request.id}
        if((Get-ItlCatalogField $Observation 'transport') -ceq 'native-client' -and $native -and
            (Get-ItlCatalogField $client 'serverName') -ceq $canonical -and
            (Get-ItlCatalogField $client 'sessionId') -and (Get-ItlCatalogField $client 'loadedEndpoint') -ceq $intent.url){$result.clientActivation='matched'}
        $readData=Get-ItlCatalogField $read.payload 'data' $read.payload
        if((Get-ItlCatalogField $readData 'indexing_status') -eq 'in_progress'){throw 'SOURCE_EVIDENCE_NOT_USABLE'}
        $hasData=if($read.tool -eq 'get_module_structure'){@(Get-ItlCatalogKeys (Get-ItlCatalogField $read.payload 'data')).Count -gt 0}elseif($Role -eq 'graph'){
            (Get-ItlCatalogField $read.payload 'returned' 0) -gt 0 -and ((Get-ItlCatalogField $read.payload 'text') -or @((Get-ItlCatalogField $read.payload 'items' @())).Count -gt 0)
        }else{@((Get-ItlCatalogField $readData 'results' @())).Count -gt 0}
        if(-not $hasData){throw 'SOURCE_EVIDENCE_EMPTY_READ'}
        if($Role -eq 'graph'){
            if((Get-ItlCatalogField $read.arguments 'search_type') -cne 'fulltext'){throw 'SOURCE_EVIDENCE_NONDETERMINISTIC_READ'}
            $expected=Get-ItlCatalogField $intent 'expectedScope' @{}
            $wantedProject=Get-ItlCatalogField $expected 'nativeProjectId'
            if(-not $wantedProject){$result.reason='native-project-selector-not-configured';return $result}
            if((Get-ItlCatalogField $read.arguments 'project_id') -cne $wantedProject){$result.binding='mismatch';$result.reason='project-selector-mismatch';return $result}
            $actualScopes=@((Get-ItlCatalogField $read.payload 'context' @{}))
            if($meta){
                $project=Get-ItlCatalogField $meta.payload 'data' @{}
                $accessible=Get-ItlCatalogField $project 'is_accessible'
                if($accessible -isnot [bool] -or -not $accessible){throw 'SOURCE_EVIDENCE_NOT_USABLE'}
                if((Get-ItlCatalogField $meta.arguments 'project_id') -cne $wantedProject){$result.binding='mismatch';$result.reason='project-selector-mismatch';return $result}
                $actualScopes+=@($project)
            }
            foreach($actual in $actualScopes){
                foreach($pair in @(@('nativeProjectId','project_id'),@('namespace','mcp_namespace'))){
                    $wanted=Get-ItlCatalogField $expected $pair[0]
                    if(-not $wanted){continue}
                    $seen=Get-ItlCatalogField $actual $pair[1]
                    if(-not $seen){$result.reason='native-scope-unavailable';return $result}
                    if($seen -cne $wanted){$result.binding='mismatch';$result.reason=$pair[0]+'-mismatch';return $result}
                }
            }
        }
        # Scope belongs to the chosen registry source. Business product equality
        # and per-response index stamps are deliberately not admission conditions.
        $result.binding='matched';$result.reason='selected-source-read'
        $result.continuation=if($result.clientActivation -eq 'matched'){'Applies to the captured client session/time. Apply target project limitations and product applicability rules.'}else{'Endpoint read verified. Use existing client sync/reload and repeat a native scoped read.'}
    } catch {$result.reason='invalid-or-failed-observation'}
    return $result
}

function Read-ItlProductSourceObservations {
    param([object]$Context,[string]$Path)
    $output=[ordered]@{provenance='explicit-read-only-observation';status='unverified';roles=[ordered]@{}}
    try {
        $stream=$null;$reader=$null
        try {
            $stream=[IO.File]::Open([IO.Path]::GetFullPath($Path),[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
            if($stream.Length -gt 262144){throw 'SOURCE_EVIDENCE_TOO_LARGE'}
            $reader=[IO.BinaryReader]::new($stream)
            $bytes=$reader.ReadBytes([int]$stream.Length)
        } finally {if($reader){$reader.Dispose()}elseif($stream){$stream.Dispose()}}
        $text=([Text.UTF8Encoding]::new($false,$true)).GetString($bytes).TrimStart([char]0xfeff)
        $record=ConvertTo-Vibecoding1cMcpHashtable (ConvertFrom-Json -InputObject $text -ErrorAction Stop)
        if($record.schemaVersion -ne 1 -or $record.catalogRevision -cne $Context.catalogRevision -or $record.settingsHash -cne $Context.settingsHash){throw 'SOURCE_EVIDENCE_CONTEXT'}
        foreach($role in @('code','graph')){$output.roles[$role]=Compare-ItlProductSourceObservation $Context $role (Get-ItlCatalogField (Get-ItlCatalogField $record 'roles' @{}) $role)}
        $output.status='observed'
    } catch {$output.reason='invalid-or-different-context-observation'}
    return $output
}
