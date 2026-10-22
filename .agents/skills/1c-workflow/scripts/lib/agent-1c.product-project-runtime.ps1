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
        if($Kind -eq 'applied' -and ($record.catalogRevision -cnotmatch '^(?:[a-f0-9]{40}|[a-f0-9]{64})$' -or $record.catalogRevision -cne $record.context.catalogRevision -or $record.contextHash -cne (Get-ItlCatalogHash $record.context))){throw 'applied context/hash/revision is invalid'}
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

function Get-ItlProductProjectSettingPlans {
    param([object]$Operation)
    foreach($kind in @('binding','selection')){
        $field=if($kind -eq 'binding'){'binding'}else{'privateSelection'}
        $plan=Get-ItlCatalogField $Operation $field
        if($plan -and $plan.enabled){$plan['kind']=$kind;Write-Output -NoEnumerate $plan}
    }
}

function Assert-ItlProductProjectNotCancelled {
    param([string]$OperationId)
    $cancel=Read-ItlProductProjectRecord cancel
    if($cancel -and $cancel.operationId -ceq $OperationId){throw [OperationCanceledException]::new('CATALOG_CANCEL_REQUESTED: completed writes remain owned; use catalog resume or restore.')}
}

function Invoke-ItlProductProjectClientApply {
    param([object]$Context,[object[]]$Requests,
        [ValidateSet('apply','resume','restore','cancel')][string]$Mode='apply',
        [AllowNull()][object]$DesiredBinding=$null,[switch]$BindProject,
        [object]$PrivateSelection=$null,[switch]$SavePrivateSelection,
        [object]$ExpectedInputStates=$null,[string]$ExpectedOwnerState='',
        [object[]]$ProofRequests=$null,[switch]$RestoreCompatibility,[object]$BindingRestoreFile=$null)
    $operation=Read-ItlProductProjectRecord 'operation'
    if ($Mode -eq 'apply') {
        if ($operation -and $operation.status -notin @('completed','restored','cancelled')) { throw 'CATALOG_OPERATION_PENDING: use status/resume/restore on the pinned operation; latest tip cannot replace it.' }
        if(-not $Context -or -not $Context.catalogRevision){throw 'CATALOG_CONTEXT_REQUIRED: preview a validated pinned catalog context before apply.'}
        if($BindProject -and $null -ne $DesiredBinding){Assert-ItlProductProjectBindingValue $DesiredBinding}
        if($null -ne $ExpectedInputStates){
            $expected=ConvertTo-Vibecoding1cMcpHashtable $ExpectedInputStates
            foreach($path in $expected.Keys){if((Get-ItlMcpFileState $path) -cne $expected[$path]){throw 'CLIENT_MCP_PREVIEW_CHANGED: input changed after the decision; repeat preview before applying.'}}
        }
        if($ExpectedOwnerState -and (Get-ItlMcpFileState (Get-ItlManagedMcpStatePath)) -cne $ExpectedOwnerState){throw 'CLIENT_MCP_PREVIEW_CHANGED: ownership changed after the decision; repeat preview.'}
        $operation=[ordered]@{schemaVersion=1;projectRoot=$script:ProjectRoot;operationId=[guid]::NewGuid().ToString('N');status='planning';direction='forward';prepared=$false;context=$Context;requests=$Requests;restoreRequests=@();expectedProof=@{};beforeProof=@{};receipts=@();activeWrite=$null;beforeApplied=(Read-ItlProductProjectRecord 'applied');restoreCompatibility=$RestoreCompatibility.IsPresent}
        $beforeBinding=Get-ItlCatalogField (Read-ItlProductProjectConfig) 'productProject'
        $operation['binding']=[ordered]@{enabled=$BindProject.IsPresent;before=$beforeBinding;desired=$DesiredBinding;expected=$beforeBinding;active=$false;target=$null;restoreFile=$BindingRestoreFile}
        $beforeSelection=Read-ItlProductProjectSetting selection
        $operation['privateSelection']=[ordered]@{enabled=$SavePrivateSelection.IsPresent;before=$beforeSelection;desired=$PrivateSelection;expected=$beforeSelection;active=$false;target=$null}
        $operation['previewInputStates']=$(if($null -ne $ExpectedInputStates){ConvertTo-Vibecoding1cMcpHashtable $ExpectedInputStates}else{$null})
        $operation['previewOwnerState']=$ExpectedOwnerState
        if(@($Requests).Count -eq 0 -and $operation.beforeApplied){
            $operation.expectedProof=ConvertTo-ItlCatalogCanonicalValue $operation.beforeApplied.proof
            $operation.beforeProof=ConvertTo-ItlCatalogCanonicalValue $operation.beforeApplied.proof
        }
        if($null -ne $ProofRequests){
            $operation.expectedProof=Get-ItlProductProjectClientProof $ProofRequests;$operation.beforeProof=ConvertTo-ItlCatalogCanonicalValue $operation.expectedProof
            if(@($Requests).Count -eq 0){$operation.restoreRequests=@(New-ItlProductProjectRestoreRequests $ProofRequests)}
        }
    } elseif (-not $operation) { throw 'CATALOG_OPERATION_MISSING: preview a new operation; no client state was changed.' }
    if($Mode -eq 'cancel'){
        $activeSettings=@(Get-ItlProductProjectSettingPlans $operation|Where-Object active)
        if(@($operation.receipts).Count -or $operation.activeWrite -or $activeSettings.Count){$operation.status='partial';Write-ItlProductProjectRecord 'operation' $operation;return [pscustomobject]@{status='needs-recovery';operationId=$operation.operationId;continuation='Use catalog resume or restore; completed writes remain owned.'}}
        $operation.status='cancelled';Write-ItlProductProjectRecord 'operation' $operation
        return [pscustomobject]@{status='cancelled';operationId=$operation.operationId}
    }
    if($Mode -in @('resume','restore')){
        if($operation.status -eq 'completed' -and $Mode -eq 'resume'){
            $compatible=Get-ItlCatalogField $operation 'restoreCompatibility' $false
            # A completed plan is not evidence that its applied marker still
            # exists and is valid. Compatibility restore may intentionally
            # retain an older marker or remove it altogether.
            try{
                $applied=Read-ItlProductProjectRecord applied
                $expected=if($compatible){Get-ItlCatalogField (Get-ItlCatalogField $operation.beforeApplied 'compatibilityBaseline') 'applied'}else{@{operationId=$operation.operationId;catalogRevision=$operation.context.catalogRevision;contextHash=(Get-ItlCatalogHash $operation.context)}}
                if($expected){
                    if(-not $applied -or $applied.operationId -cne $expected.operationId -or $applied.catalogRevision -cne $expected.catalogRevision -or $applied.contextHash -cne $expected.contextHash){throw 'Applied marker does not match the completed operation outcome.'}
                }elseif($applied){throw 'Compatibility restore expected no applied marker.'}
            }catch{
                throw 'CATALOG_COMPLETED_RESUME_NEEDS_RESTORE: the completed operation has no matching valid applied context. No files were changed. Inspect -Action vibecoding1c-mcp-status -CatalogAction status, then use -Action vibecoding1c-mcp-select -CatalogAction restore on the saved operation and repeat the original command.'
            }
            return [pscustomobject]@{status=$(if($compatible){'compatible-restored'}else{'configured'});operationId=$operation.operationId;catalogRevision=$operation.context.catalogRevision}
        }
        if($operation.status -in @('cancelled','restored')){return [pscustomobject]@{status=$operation.status;operationId=$operation.operationId}}
        if(-not $operation.prepared){$ExpectedInputStates=Get-ItlCatalogField $operation 'previewInputStates';$ExpectedOwnerState=[string](Get-ItlCatalogField $operation 'previewOwnerState' '')}
        foreach($settingPlan in @(Get-ItlProductProjectSettingPlans $operation)){
            $current=Read-ItlProductProjectSetting $settingPlan.kind
            if((Get-ItlCatalogHash $current) -cne (Get-ItlCatalogHash $settingPlan.expected)){
                if(-not $settingPlan.active -or (Get-ItlCatalogHash $current) -cne (Get-ItlCatalogHash $settingPlan.target)){throw 'CATALOG_SETTING_CONFLICT: owned preferences are neither the durable input nor intended write; preserve them before resume/restore.'}
                $settingPlan.expected=$current;$settingPlan.active=$false
                Write-ItlProductProjectRecord operation $operation
            }
        }
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
            $operation.expectedProof=ConvertTo-Vibecoding1cMcpHashtable (Get-ItlCatalogField $operation.beforeApplied 'proof' @{})
            $updatedProof=Get-ItlProductProjectClientProof $preparedSet.requests
            foreach($key in @(Get-ItlCatalogKeys $updatedProof)){$operation.expectedProof[$key]=$updatedProof[$key]}
            $operation['beforeProof']=ConvertTo-ItlCatalogCanonicalValue $operation.expectedProof
            $operation['inputStates']=ConvertTo-Vibecoding1cMcpHashtable $preparedSet.fileStates
            $operation.prepared=$true
        }else{Assert-ItlProductProjectClientProof $operation.expectedProof}
        $operation.status='applying';Write-ItlProductProjectRecord 'operation' $operation
    }
    $beforeWrite={
        param($intent)
        Assert-ItlProductProjectNotCancelled $operation.operationId
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
        $inputs=@(foreach($settingPlan in @(Get-ItlProductProjectSettingPlans $operation)){if($settingPlan.kind -eq 'binding'){$script:ConfigPath}else{Get-Vibecoding1cMcpSelectionPath}})
        $protectForward=($Mode -eq 'apply' -or -not $operation.prepared) -and -not (Get-ItlCatalogField $operation 'restoreCompatibility' $false)
        if (@($Requests).Count) { $null=Write-ItlClientMcpEndpointSet -Requests $Requests -AdditionalInputPaths $inputs -ExpectedInputStates $ExpectedInputStates -ExpectedOwnerState $ExpectedOwnerState -PreserveUserChanges:$protectForward -OnPrepared $prepared -OnBeforeWrite $beforeWrite -OnReceipt $receipt }
        elseif($Mode -eq 'apply') { $operation.status='applying';Write-ItlProductProjectRecord 'operation' $operation }
        Assert-ItlProductProjectClientProof $operation.expectedProof
        foreach($settingPlan in @(Get-ItlProductProjectSettingPlans $operation)){
            Assert-ItlProductProjectNotCancelled $operation.operationId
            $settingPlan.target=if($operation.direction -eq 'restore'){$settingPlan.before}else{$settingPlan.desired}
            $settingPlan.active=$true
            Write-ItlProductProjectRecord operation $operation
            $restoreFile=if($operation.direction -eq 'restore'){Get-ItlCatalogField $settingPlan 'fileReceipt'}else{Get-ItlCatalogField $settingPlan 'restoreFile'}
            $saveFileReceipt={
                param($fileReceipt)
                if(-not (Get-ItlCatalogField $settingPlan 'fileReceipt')){
                    $settingPlan['fileReceipt']=$fileReceipt
                    Write-ItlProductProjectRecord operation $operation
                }
            }
            Set-ItlProductProjectSetting -Kind $settingPlan.kind -Value $settingPlan.target -Expected $settingPlan.expected -RestoreFile $restoreFile -OnBeforeWrite $saveFileReceipt
            $settingPlan.expected=$settingPlan.target;$settingPlan.active=$false
            $operation.receipts=@($operation.receipts)+@(@{kind=$settingPlan.kind})
            Write-ItlProductProjectRecord operation $operation
        }
        if($operation.direction -eq 'restore'){
            Assert-ItlProductProjectClientProof $operation.beforeProof
            if($operation.beforeApplied){Write-ItlProductProjectRecord 'applied' $operation.beforeApplied}
            else { $path=Get-ItlProductProjectPath 'applied';if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path} }
            $operation.status='restored'
        }else{
            Assert-ItlProductProjectNotCancelled $operation.operationId
            $stage=if((Get-ItlCatalogField $Context 'configurationStage') -eq 'binding-only'){'binding-only'}else{'configured'}
            $applied=[ordered]@{schemaVersion=1;projectRoot=$script:ProjectRoot;operationId=$operation.operationId;catalogRevision=$Context.catalogRevision;context=$Context;proof=$operation.expectedProof;configurationState=$stage;activeClientContext='unverified';contextHash=(Get-ItlCatalogHash $Context)}
            $baseline=Get-ItlCatalogField $operation.beforeApplied 'compatibilityBaseline'
            if(-not $baseline){$baseline=@{requests=$operation.restoreRequests;binding=(Get-ItlCatalogField (Get-ItlCatalogField $operation 'binding') 'before');bindingFile=(Get-ItlCatalogField (Get-ItlCatalogField $operation 'binding') 'fileReceipt');selection=(Get-ItlCatalogField (Get-ItlCatalogField $operation 'privateSelection') 'before');applied=$operation.beforeApplied}}
            $applied['compatibilityBaseline']=$baseline
            if(Get-Command Get-ItlProductProjectNoOpInputs -ErrorAction SilentlyContinue){$applied['noOpInputs']=Get-ItlProductProjectNoOpInputs $operation.expectedProof -IncludeClientSurfaces:([bool](Get-ItlCatalogField $Context 'catalogIncludesClientSurfaces' $false))}
            if(Get-ItlCatalogField $operation 'restoreCompatibility' $false){
                $original=Get-ItlCatalogField $baseline 'applied'
                if($original){Write-ItlProductProjectRecord applied $original}
                else{$path=Get-ItlProductProjectPath applied;if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path}}
            }else{Write-ItlProductProjectRecord 'applied' $applied}
            $operation.status='completed'
        }
        Write-ItlProductProjectRecord 'operation' $operation
        return [pscustomobject]@{status=$(if($operation.direction -eq 'restore'){'restored'}elseif(Get-ItlCatalogField $operation 'restoreCompatibility' $false){'compatible-restored'}else{'configured'});operationId=$operation.operationId;catalogRevision=$Context.catalogRevision;activeClientContext='unverified'}
    } catch {
        $activeSettings=@(Get-ItlProductProjectSettingPlans $operation|Where-Object active)
        $operation.status=if(@($operation.receipts).Count -or $operation.activeWrite -or $activeSettings.Count){'partial'}elseif($_.Exception -is [OperationCanceledException]){'cancelled'}else{'prepared'}
        Write-ItlProductProjectRecord 'operation' $operation
        throw
    }
}

function Invoke-ItlProductProjectCompatibilityRestore {
    $operation=Read-ItlProductProjectRecord operation
    if($operation -and $operation.status -notin @('completed','restored','cancelled')){throw 'CATALOG_OPERATION_PENDING: finish pinned resume/restore before requesting compatibility restore.'}
    $applied=Read-ItlProductProjectRecord applied
    $baseline=Get-ItlCatalogField $applied 'compatibilityBaseline'
    if(-not $baseline -or (Get-ItlCatalogField $baseline 'binding')){throw 'CATALOG_COMPAT_BASELINE_UNAVAILABLE: retain the current compatible helper and binding; no proven pre-association baseline is available for a managed downgrade.'}
    $requests=@(ConvertTo-Vibecoding1cMcpArray (Get-ItlCatalogField $baseline 'requests' @()))
    $keys=@($requests|ForEach-Object {"$($_.client)/$($_.owner)"})
    foreach($key in @(Get-ItlCatalogKeys $applied.proof)){
        if($key -notin $keys){$proof=$applied.proof[$key];$requests+=@(@{client=$proof.client;owner=$proof.owner;endpoints=@()})}
    }
    $inputs=[ordered]@{}
    foreach($path in @($script:ConfigPath,(Get-Vibecoding1cMcpSelectionPath))+@($requests|ForEach-Object {Get-ItlClientMcpConfigPaths $_.client})){$inputs[$path]=Get-ItlMcpFileState $path}
    $ownerState=Get-ItlMcpFileState (Get-ItlManagedMcpStatePath)
    Assert-ItlProductProjectClientProof $applied.proof
    $result=Invoke-ItlProductProjectClientApply -Context $applied.context -Requests $requests -BindProject -DesiredBinding (Get-ItlCatalogField $baseline 'binding') -SavePrivateSelection -PrivateSelection (Get-ItlCatalogField $baseline 'selection') -ExpectedInputStates $inputs -ExpectedOwnerState $ownerState -RestoreCompatibility -BindingRestoreFile (Get-ItlCatalogField $baseline 'bindingFile')
    return [pscustomobject]@{status='compatible-restored';operationId=$result.operationId;activeClientContext='unverified';continuation='Repeat the original update-workflow; reload the client and verify active tools separately.'}
}

function Invoke-ItlProductProjectRecovery {
    param([ValidateSet('status','resume','restore','cancel','restore-compatible')][string]$Mode='status')
    if($Mode -eq 'restore-compatible'){return Invoke-ItlProductProjectCompatibilityRestore}
    if($Mode -in @('resume','restore')){return Invoke-ItlProductProjectClientApply -Mode $Mode}
    $recordError=''
    try{$operation=Read-ItlProductProjectRecord operation}catch{if($Mode -ne 'status'){throw};$operation=$null;$recordError='invalid-operation'}
    try{$applied=Read-ItlProductProjectRecord applied}catch{if($Mode -ne 'status'){throw};$applied=$null;$recordError+=' invalid-applied'}
    if($Mode -eq 'cancel'){
        if(-not $operation -or $operation.status -in @('completed','restored','cancelled')){return [pscustomobject]@{status='idle';cancellationRequested=$false}}
        Write-ItlProductProjectRecord cancel @{schemaVersion=1;projectRoot=$script:ProjectRoot;operationId=$operation.operationId}
        return [pscustomobject]@{status='cancel-requested';operationId=$operation.operationId;continuation='The current write may complete. Use -Action vibecoding1c-mcp-select -CatalogAction resume or restore after it stops.'}
    }
    return [pscustomobject]@{
        status=$(if($recordError){$recordError.Trim()}elseif($operation){$operation.status}else{'unbound'})
        operationId=$(if($operation){$operation.operationId}else{$null})
        catalogRevision=$(if($operation){$operation.context.catalogRevision}elseif($applied){$applied.catalogRevision}else{$null})
        completedWrites=$(if($operation){@($operation.receipts).Count}else{0})
        pendingWrite=$(if($operation){$null -ne $operation.activeWrite -or @(Get-ItlProductProjectSettingPlans $operation|Where-Object active).Count -gt 0}else{$false})
        activeClientContext='unverified'
        continuation='Use -Action vibecoding1c-mcp-select -CatalogAction resume|restore; status is read-only and never refreshes the catalog.'
    }
}
