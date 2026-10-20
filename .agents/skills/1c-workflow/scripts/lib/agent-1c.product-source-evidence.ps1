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
    $result=[ordered]@{binding='unverified';indexedVersion='unverified';clientActivation='unverified';build='unverified';reason='observation-missing';checkedAt=$null;indexedSource=$null;continuation='Use the selected source only after scoped verification, or continue with local code; do not change the product or reindex automatically.'}
    if(-not $intent){$result.reason=if((Get-ItlCatalogField $Context.roles[$Role] 'mode') -eq 'disabled'){'disabled'}else{'not-configured'};return $result}
    if(-not $Observation){return $result}
    try {
        $date=[DateTimeOffset]::MinValue
        $checked=Get-ItlCatalogField $Observation 'checkedAt'
        if($checked -is [DateTime] -or $checked -is [DateTimeOffset]){$date=[DateTimeOffset]$checked}
        elseif(-not [DateTimeOffset]::TryParse([string]$checked,[ref]$date)){throw 'SOURCE_EVIDENCE_DATE'}
        $result.checkedAt=$date.ToUniversalTime().ToString('o')
        if((Get-ItlCatalogField $Observation 'endpoint') -cne $intent.url){$result.binding='mismatch';$result.reason='endpoint-mismatch';return $result}
        $metaTool=if($Role -eq 'code'){'stats'}else{'get_graph_project_status'}
        $readTools=if($Role -eq 'code'){@('get_module_structure','search_function')}else{@('search_code')}
        $meta=Get-ItlSourceToolPayload (Get-ItlCatalogField $Observation 'metadata') @($metaTool)
        $read=Get-ItlSourceToolPayload (Get-ItlCatalogField $Observation 'read') $readTools
        $client=Get-ItlCatalogField $Observation 'client'
        $ids=@((Get-ItlCatalogField $client 'requestIds' @()))
        $canonical=if($Role -eq 'code'){'1c-code-metadata-mcp'}else{'1c-graph-metadata-mcp'}
        if((Get-ItlCatalogField $Observation 'transport') -ceq 'native-client' -and
            $meta.native -and $read.native -and $meta.server -ceq $canonical -and $read.server -ceq $canonical -and
            $meta.sessionId -ceq (Get-ItlCatalogField $client 'sessionId') -and $read.sessionId -ceq $meta.sessionId -and
            (Get-ItlCatalogField $client 'serverName') -ceq $canonical -and
            (Get-ItlCatalogField $client 'sessionId') -and
            (Get-ItlCatalogField $client 'loadedEndpoint') -ceq $intent.url -and
            $meta.request.id -cne $read.request.id -and $meta.request.id -in $ids -and $read.request.id -in $ids){$result.clientActivation='matched'}
        if($Role -eq 'graph' -and (Get-ItlCatalogField $read.arguments 'search_type') -cne 'fulltext'){throw 'SOURCE_EVIDENCE_NONDETERMINISTIC_READ'}
        $readData=Get-ItlCatalogField $read.payload 'data' $read.payload
        if((Get-ItlCatalogField $readData 'indexing_status') -eq 'in_progress'){throw 'SOURCE_EVIDENCE_NOT_USABLE'}
        $hasData=if($read.tool -eq 'get_module_structure'){$null -ne (Get-ItlCatalogField $read.payload 'data')}elseif($Role -eq 'graph'){
            (Get-ItlCatalogField $read.payload 'returned' 0) -gt 0 -and
            ((Get-ItlCatalogField $read.payload 'text') -or @((Get-ItlCatalogField $read.payload 'items' @())).Count -gt 0)
        }else{@((Get-ItlCatalogField $readData 'results' @())).Count -gt 0}
        if(-not $hasData){throw 'SOURCE_EVIDENCE_EMPTY_READ'}
        $metaData=if($Role -eq 'code'){Get-ItlCatalogField $meta.payload 'data' @{}}else{$meta.payload}
        $identity=Get-ItlCatalogField $metaData 'sourceIdentity'
        $readIdentity=Get-ItlCatalogField $read.payload 'sourceIdentity'
        $expected=Get-ItlCatalogField $intent 'expectedIdentity' @{}
        # Supported Graph v2 status + read context proves a selected scope even
        # for inherited data. It supplies no indexed revision, so do not invent one.
        if($Role -eq 'graph' -and -not $identity){
            if(Get-ItlCatalogField $expected 'requireSourceKey' $false){$result.reason='sourceKey-unavailable';return $result}
            $project=Get-ItlCatalogField $meta.payload 'data' @{}
            $readContext=Get-ItlCatalogField $read.payload 'context' @{}
            foreach($pair in @(@('nativeProjectId','project_id'),@('namespace','mcp_namespace'))){
                $wanted=Get-ItlCatalogField $expected $pair[0]
                if(-not $wanted){$result.reason='source-mapping-unavailable';return $result}
                foreach($actual in @($project,$readContext)){
                    $seen=Get-ItlCatalogField $actual $pair[1]
                    if(-not $seen){$result.reason='native-scope-unavailable';return $result}
                    if($wanted -cne $seen){$result.binding='mismatch';$result.reason=$pair[0]+'-mismatch';return $result}
                }
                if($pair[0] -eq 'nativeProjectId' -and ((Get-ItlCatalogField $meta.arguments 'project_id') -cne $wanted -or (Get-ItlCatalogField $read.arguments 'project_id') -cne $wanted)){throw 'SOURCE_EVIDENCE_SCOPE_ARGUMENT'}
            }
            $accessible=Get-ItlCatalogField $project 'is_accessible'
            if((Get-ItlCatalogField $meta.payload 'contract_version') -cne '2.0' -or (Get-ItlCatalogField $read.payload 'contract_version') -cne '2.0' -or
                $accessible -isnot [bool] -or -not $accessible){throw 'SOURCE_EVIDENCE_NOT_USABLE'}
            $result.binding='matched';$result.reason='indexed-revision-unavailable';return $result
        }
        if((Get-ItlCatalogField $identity 'contractVersion') -ne 1 -or (Get-ItlCatalogField $readIdentity 'contractVersion') -ne 1){$result.reason='native-identity-unavailable';return $result}
        $stamp=[string](Get-ItlCatalogField $identity 'stamp' '')
        $sameStamp=$stamp -cmatch '^[a-f0-9]{64}$' -and (Get-ItlCatalogField $readIdentity 'stamp') -ceq $stamp -and
            (Get-ItlCatalogField $readIdentity 'generation') -ceq (Get-ItlCatalogField $identity 'generation')
        foreach($field in @('sourceKey','nativeProjectId','namespace')){
            $wanted=[string](Get-ItlCatalogField $expected $field '')
            foreach($actual in @($identity,$readIdentity)){
                $seen=[string](Get-ItlCatalogField $actual $field '')
                if(-not $seen -and [object]::ReferenceEquals($actual,$readIdentity) -and $sameStamp){continue}
                if($wanted -and $seen -and $wanted -cne $seen){$result.binding='mismatch';$result.reason=$field+'-mismatch';return $result}
                if($wanted -and -not $seen){$result.reason=$field+'-unavailable';return $result}
            }
        }
        if(-not (Get-ItlCatalogField $expected 'sourceKey') -or -not (Get-ItlCatalogField $identity 'nativeProjectId') -or
            ((Get-ItlCatalogField $readIdentity 'nativeProjectId') -and (Get-ItlCatalogField $readIdentity 'nativeProjectId') -cne $identity.nativeProjectId) -or
            ((Get-ItlCatalogField $readIdentity 'namespace') -and (Get-ItlCatalogField $readIdentity 'namespace') -cne (Get-ItlCatalogField $identity 'namespace'))){$result.reason='source-mapping-unavailable';return $result}
        if($Role -eq 'graph'){
            foreach($call in @($meta,$read)){
                if((Get-ItlCatalogField $call.arguments 'project_id') -cne $identity.nativeProjectId){throw 'SOURCE_EVIDENCE_SCOPE_ARGUMENT'}
            }
        }
        $result.binding='matched'
        $result.reason='indexed-revision-unavailable'
        $build=Get-ItlCatalogField $identity 'build'
        if((Get-ItlCatalogField $build 'digest') -match '^sha256:[a-f0-9]{64}$' -or (Get-ItlCatalogField $build 'sourceCommit') -match '^[a-f0-9]{40}$'){$result.build='observed'}
        $indexed=Get-ItlCatalogField $identity 'indexedSource'
        $revision=[string](Get-ItlCatalogField $indexed 'revision' '')
        $kind=[string](Get-ItlCatalogField $indexed 'revisionKind' '')
        $readIndexed=Get-ItlCatalogField $readIdentity 'indexedSource'
        if(-not $sameStamp -or (Get-ItlCatalogField $identity 'layer') -cne 'index' -or
            (Get-ItlCatalogField $readIdentity 'layer') -cne 'index' -or
            (Get-ItlCatalogField $readIdentity 'stamp') -cne $stamp -or
            (Get-ItlCatalogField $identity 'generation') -cne (Get-ItlCatalogField $readIdentity 'generation') -or
            ($null -ne $readIndexed -and (Get-ItlCatalogHash $indexed) -cne (Get-ItlCatalogHash $readIndexed))){$result.reason='index-stamp-unverified';return $result}
        if($revision -notmatch '^[a-f0-9]{64}$' -or $kind -cnotin @('code-source-inventory-sha256','content-sha256') -or
            (Get-ItlCatalogField $indexed 'provenance') -cne 'active-index-manifest' -or
            -not @((Get-ItlCatalogField $indexed 'extent' @())).Count){return $result}
        $version=[string](Get-ItlCatalogField $indexed 'configurationVersion' '')
        if($version.Length -gt 128 -or $version -match '[\x00-\x1f]'){throw 'SOURCE_EVIDENCE_VERSION'}
        $result.indexedSource=@{revisionKind=$kind;revision=$revision;configurationVersion=$version}
        $result.indexedVersion='matched';$result.reason='verified-observation'
        $pin=Get-ItlCatalogField $expected 'pin' @{}
        foreach($field in @('revisionKind','revision','configurationVersion')){
            $wanted=[string](Get-ItlCatalogField $pin $field '')
            if($wanted -and -not [string]$result.indexedSource[$field]){$result.indexedVersion='unverified';$result.reason='pin-unavailable';return $result}
            if($wanted -and $wanted -cne [string]$result.indexedSource[$field]){$result.indexedVersion='mismatch';$result.reason='pin-mismatch';return $result}
        }
        $result.continuation=if($result.clientActivation -eq 'matched'){'Observation applies to the captured client session and time; it is not a currentness guarantee.'}else{'Endpoint verified only. Use the existing client sync/reload and repeat a native scoped read.'}
    } catch {$result.indexedVersion='unverified';$result.reason='invalid-or-failed-observation'}
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
