# Product context operation: owned by the existing registry/client/lifecycle path.
# This file is loaded only for an explicit setup or an already bound project.

function Get-ItlProductProjectPath {
    param([ValidateSet('applied','operation','cancel')][string]$Kind)
    return (Join-Path $script:ProjectRoot ('.agent-1c/mcp/product-context-' + $Kind + '.json'))
}

function Read-ItlProductProjectRecord {
    param([string]$Kind)
    $path=Get-ItlProductProjectPath $Kind
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try {
        $record=ConvertTo-ItlCatalogCanonicalValue (Read-Utf8Text -Path $path | ConvertFrom-Json -ErrorAction Stop)
        if ($record.schemaVersion -ne 1) { throw 'unsupported schema' }
        if ([IO.Path]::GetFullPath([string]$record.projectRoot).TrimEnd('\') -ine [IO.Path]::GetFullPath($script:ProjectRoot).TrimEnd('\')) { throw 'record belongs to another root' }
        return $record
    } catch { throw "CATALOG_LOCAL_RECORD_INVALID: $Kind; use catalog status/owned recovery without deleting IDs or client files." }
}

function Write-ItlProductProjectRecord {
    param([string]$Kind,[object]$Record)
    $path=Get-ItlProductProjectPath $Kind
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
    Write-Utf8TextAtomic -Path $path -Value ((ConvertTo-Json -InputObject $Record -Depth 100)+[Environment]::NewLine)
}

function ConvertFrom-ItlCatalogClientEntry {
    param([string]$Name,[object]$Entry)
    $get={param($key,$default) Get-Vibecoding1cMcpObjectValue -Object $Entry -Name $key -Default $default}
    $url=[string](& $get 'url' (& $get 'serverUrl' (& $get 'server_url' (& $get 'httpUrl' ''))))
    $result=[ordered]@{name=$Name;url=$url;transport='remote';toolTimeoutSeconds=120;startupTimeoutSeconds=20}
    if (-not $url) {
        $command=& $get 'command' ''
        $arguments=@(& $get 'args' @())
        if ($command -is [array]) { $parts=@($command);$command=$parts[0];$arguments=@($parts | Select-Object -Skip 1) }
        if (-not $command) { throw "CATALOG_RESTORE_FORMAT: cannot losslessly represent '$Name'; retain it as an explicit local override." }
        $result.transport='stdio';$result['command']=[string]$command;$result['args']=$arguments
        $result['env']=(& $get 'env' (& $get 'environment' @{}))
    }
    $milliseconds=& $get 'timeout' $null
    $result.toolTimeoutSeconds=[int](& $get 'tool_timeout_sec' $(if($milliseconds){[Math]::Max(1,[int]$milliseconds/1000)}else{120}))
    $result.startupTimeoutSeconds=[int](& $get 'startup_timeout_sec' 20)
    return [pscustomobject]$result
}

function Get-ItlProductProjectClientProof {
    param([object[]]$Requests)
    $proof=[ordered]@{}
    foreach($request in $Requests){
        $client=[string]$request.client;$owner=[string]$request.owner
        $names=@(@(Get-ItlManagedMcpOwnerKeys -Client $client -Owner $owner)+@($request.endpoints | ForEach-Object {ConvertTo-ItlClientMcpKey -Name $_.name -Client $client}) | Select-Object -Unique)
        $preserve=@(Get-Vibecoding1cMcpObjectValue -Object $request -Name 'preserveOwnedKeys' -Default @())
        $names=@($names | Where-Object {$_ -notin $preserve})
        $entries=Read-ItlClientMcpEntries -Client $client
        $signatures=[ordered]@{}
        foreach($name in $names){$signatures[$name]=Get-ItlMcpOwnedSemanticSignature -Container $entries -Names @($name)}
        $proof["$client/$owner"]=[ordered]@{client=$client;owner=$owner;names=$names;signatures=$signatures;paths=@(Get-ItlClientMcpConfigPaths -Client $client);container=[string](Get-ItlClientAdapter -Client $client).mcpContainer}
    }
    return $proof
}

function Assert-ItlProductProjectClientProof {
    param([object]$Proof)
    foreach($key in @(Get-ItlCatalogKeys $Proof)){
        $entry=Get-ItlCatalogField $Proof $key
        $entries=Read-ItlClientMcpEntries -Client $entry.client
        foreach($name in @($entry.names)){
            $current=Get-ItlMcpOwnedSemanticSignature -Container $entries -Names @($name)
            if($current -cne $entry.signatures[$name]){throw "CATALOG_CLIENT_CONFLICT: $key/$name changed after its receipt; preserve the edit and resolve this owner before resume/restore."}
        }
    }
}

function New-ItlProductProjectRestoreRequests {
    param([object[]]$Requests)
    return @($Requests | ForEach-Object {
        $client=$_.client;$owner=$_.owner;$entries=Read-ItlClientMcpEntries -Client $client
        $preserve=@(Get-Vibecoding1cMcpObjectValue -Object $_ -Name 'preserveOwnedKeys' -Default @())
        $names=@(Get-ItlManagedMcpOwnerKeys -Client $client -Owner $owner | Where-Object {$_ -notin $preserve})
        $endpoints=@(foreach($name in $names){if($entries.Contains($name)){ConvertFrom-ItlCatalogClientEntry $name $entries[$name]}})
        $restoreEntries=[ordered]@{}
        foreach($name in $names){
            if(-not $entries.Contains($name)){continue}
            $native=[ordered]@{entry=$entries[$name]}
            $adapter=Get-ItlClientAdapter $client
            if($adapter.mcpFormat -eq 'toml'){
                $text=Read-Utf8Text -Path (Join-Path $script:ProjectRoot $adapter.mcpPath)
                $token='(?:'+[regex]::Escape((ConvertTo-Vibecoding1cMcpTomlString $name))+'|'+[regex]::Escape($name)+"|'"+[regex]::Escape($name)+"')"
                $native['tomlText']=(@([regex]::Matches($text,'(?ms)^\s*\[mcp_servers\.'+$token+'(?:\.[^\]]+)?\][^\r\n]*\r?\n.*?(?=^\s*\[|^# >>>|^# <<<|\z)')|ForEach-Object {$_.Value.TrimEnd()}) -join [Environment]::NewLine)
            }
            $restoreEntries[$name]=$native
        }
        [pscustomobject]@{client=$client;owner=$owner;endpoints=$endpoints;preserveOwnedKeys=$preserve;restoreEntries=$restoreEntries}
    })
}

function Set-ItlProductProjectStepProof {
    param([object]$Proof,[string]$Client,[string]$Owner,[object]$Entries)
    $source=$Proof["$Client/$Owner"]
    foreach($key in @(Get-ItlCatalogKeys $Proof)){
        $target=$Proof[$key]
        if($target.container -cne $source.container -or -not @($target.paths | Where-Object {$_ -in @($source.paths)}).Count){continue}
        foreach($name in @($target.names)){
            if($name -in @($source.names)){$target.signatures[$name]=Get-ItlMcpOwnedSemanticSignature -Container $Entries -Names @($name)}
        }
    }
}

function Invoke-ItlProductProjectClientApply {
    param([object]$Context,[object[]]$Requests,
        [ValidateSet('apply','resume','restore','cancel')][string]$Mode='apply')
    $operation=Read-ItlProductProjectRecord 'operation'
    if ($Mode -eq 'apply') {
        if ($operation -and $operation.status -notin @('completed','restored','cancelled')) { throw 'CATALOG_OPERATION_PENDING: use status/resume/restore on the pinned operation; latest tip cannot replace it.' }
        if(-not $Context -or -not $Context.catalogRevision){throw 'CATALOG_CONTEXT_REQUIRED: preview a validated pinned catalog context before apply.'}
        $operation=[ordered]@{schemaVersion=1;projectRoot=$script:ProjectRoot;operationId=[guid]::NewGuid().ToString('N');status='planning';direction='forward';prepared=$false;context=$Context;requests=$Requests;restoreRequests=@();expectedProof=@{};beforeProof=@{};receipts=@();activeWrite=$null;beforeApplied=(Read-ItlProductProjectRecord 'applied')}
    } elseif (-not $operation) { throw 'CATALOG_OPERATION_MISSING: preview a new operation; no client state was changed.' }
    if($Mode -eq 'cancel'){
        if(@($operation.receipts).Count -or $operation.activeWrite){$operation.status='partial';Write-ItlProductProjectRecord 'operation' $operation;return [pscustomobject]@{status='needs-recovery';operationId=$operation.operationId;continuation='Use catalog resume or restore; completed writes remain owned.'}}
        $operation.status='cancelled';Write-ItlProductProjectRecord 'operation' $operation
        return [pscustomobject]@{status='cancelled';operationId=$operation.operationId}
    }
    if($Mode -in @('resume','restore')){
        if($operation.status -eq 'completed' -and $Mode -eq 'resume'){return [pscustomobject]@{status='configured';operationId=$operation.operationId;catalogRevision=$operation.context.catalogRevision}}
        if($operation.status -in @('cancelled','restored')){return [pscustomobject]@{status=$operation.status;operationId=$operation.operationId}}
        if($operation.activeWrite){
            $null=Confirm-ItlClientMcpPreparedWrite $operation.activeWrite
            Set-ItlProductProjectStepProof $operation.expectedProof $operation.activeWrite.client $operation.activeWrite.owner (Read-ItlClientMcpEntries $operation.activeWrite.client)
            $operation.receipts=@($operation.receipts)+@(@{client=$operation.activeWrite.client;owner=$operation.activeWrite.owner;reconciled=$true;direction=$operation.direction})
            $operation.activeWrite=$null
            Write-ItlProductProjectRecord 'operation' $operation
        }
        Assert-ItlProductProjectClientProof $operation.expectedProof
        $Context=$operation.context
        if($Mode -eq 'restore'){$operation.direction='restore'}
        $Requests=if($operation.direction -eq 'restore'){@($operation.restoreRequests)}else{@($operation.requests)}
        $Requests=@($Requests|Where-Object {$null -ne $_})
        $cancelPath=Get-ItlProductProjectPath cancel
        if(Test-Path -LiteralPath $cancelPath){Remove-Item -LiteralPath $cancelPath}
    }
    $prepared={
        param($preparedSet)
        if(-not $operation.prepared){
            $operation.requests=@($preparedSet.requests)
            $operation.restoreRequests=@(New-ItlProductProjectRestoreRequests $preparedSet.requests)
            $operation.expectedProof=Get-ItlProductProjectClientProof $preparedSet.requests
            $operation['beforeProof']=ConvertTo-ItlCatalogCanonicalValue $operation.expectedProof
            $operation['inputStates']=ConvertTo-Vibecoding1cMcpHashtable $preparedSet.fileStates
            $operation.prepared=$true
        }else{Assert-ItlProductProjectClientProof $operation.expectedProof}
        $operation.status='applying';Write-ItlProductProjectRecord 'operation' $operation
    }
    $beforeWrite={
        param($intent)
        $cancel=Read-ItlProductProjectRecord cancel
        if($cancel -and $cancel.operationId -ceq $operation.operationId){throw [OperationCanceledException]::new('CATALOG_CANCEL_REQUESTED: completed writes remain owned; use catalog resume or restore.')}
        Assert-ItlProductProjectClientProof $operation.expectedProof
        $intent.beforeFiles=ConvertTo-Vibecoding1cMcpHashtable $intent.beforeFiles
        $operation.activeWrite=ConvertTo-ItlCatalogCanonicalValue $intent
        $afterProof=ConvertTo-ItlCatalogCanonicalValue $operation.expectedProof
        Set-ItlProductProjectStepProof $afterProof $intent.client $intent.owner $intent.plan.afterEntries
        $operation['stepAfterProof']=$afterProof
        Write-ItlProductProjectRecord 'operation' $operation
    }
    $receipt={
        param($step)
        $operation.receipts=@($operation.receipts)+@(@{client=$step.client;owner=$step.owner;step=$step.step;path=$step.path;fileState=$step.fileStates[$step.path];ownerState=$step.ownerState})
        $operation.expectedProof=$operation.stepAfterProof
        $operation.activeWrite=$null
        $operation.status='partial';Write-ItlProductProjectRecord 'operation' $operation
    }
    try {
        if (@($Requests).Count) { $null=Write-ItlClientMcpEndpointSet -Requests $Requests -PreserveUserChanges:($Mode -eq 'apply' -or -not $operation.prepared) -OnPrepared $prepared -OnBeforeWrite $beforeWrite -OnReceipt $receipt }
        elseif($Mode -eq 'apply') { $operation.status='applying';Write-ItlProductProjectRecord 'operation' $operation }
        Assert-ItlProductProjectClientProof $operation.expectedProof
        if($operation.direction -eq 'restore'){
            Assert-ItlProductProjectClientProof $operation.beforeProof
            if($operation.beforeApplied){Write-ItlProductProjectRecord 'applied' $operation.beforeApplied}
            else { $path=Get-ItlProductProjectPath 'applied';if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path} }
            $operation.status='restored'
        }else{
            $applied=[ordered]@{schemaVersion=1;projectRoot=$script:ProjectRoot;operationId=$operation.operationId;catalogRevision=$Context.catalogRevision;context=$Context;proof=$operation.expectedProof;configurationState='configured';activeClientContext='unverified';contextHash=(Get-ItlCatalogHash $Context)}
            Write-ItlProductProjectRecord 'applied' $applied
            $operation.status='completed'
        }
        Write-ItlProductProjectRecord 'operation' $operation
        return [pscustomobject]@{status=$(if($operation.direction -eq 'restore'){'restored'}else{'configured'});operationId=$operation.operationId;catalogRevision=$Context.catalogRevision;activeClientContext='unverified'}
    } catch {
        $operation.status=if(@($operation.receipts).Count -or $operation.activeWrite){'partial'}elseif($_.Exception -is [OperationCanceledException]){'cancelled'}else{'prepared'}
        Write-ItlProductProjectRecord 'operation' $operation
        throw
    }
}

function Invoke-ItlProductProjectRecovery {
    param([ValidateSet('status','resume','restore','cancel')][string]$Mode='status')
    if($Mode -in @('resume','restore')){return Invoke-ItlProductProjectClientApply -Mode $Mode}
    $operation=Read-ItlProductProjectRecord operation
    $applied=Read-ItlProductProjectRecord applied
    if($Mode -eq 'cancel'){
        if(-not $operation -or $operation.status -in @('completed','restored','cancelled')){return [pscustomobject]@{status='idle';cancellationRequested=$false}}
        Write-ItlProductProjectRecord cancel @{schemaVersion=1;projectRoot=$script:ProjectRoot;operationId=$operation.operationId}
        return [pscustomobject]@{status='cancel-requested';operationId=$operation.operationId;continuation='The current write may complete. Use -Action vibecoding1c-mcp-select -CatalogAction resume or restore after it stops.'}
    }
    return [pscustomobject]@{
        status=$(if($operation){$operation.status}else{'unbound'})
        operationId=$(if($operation){$operation.operationId}else{$null})
        catalogRevision=$(if($operation){$operation.context.catalogRevision}elseif($applied){$applied.catalogRevision}else{$null})
        completedWrites=$(if($operation){@($operation.receipts).Count}else{0})
        pendingWrite=$(if($operation){$null -ne $operation.activeWrite}else{$false})
        activeClientContext='unverified'
        continuation='Use -Action vibecoding1c-mcp-select -CatalogAction resume|restore; status is read-only and never refreshes the catalog.'
    }
}
