[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$BindingPath,[Parameter(Mandatory=$true)][string]$Client)
Set-StrictMode -Version 2
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
[Console]::InputEncoding=[Text.UTF8Encoding]::new($false,$true)
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$OutputEncoding=[Console]::OutputEncoding
# Native clients can inherit a PowerShell 7 module path. Policy hash checks
# require the utility functions from this process's own PowerShell runtime.
Import-Module (Join-Path $PSHOME 'Modules/Microsoft.PowerShell.Utility/Microsoft.PowerShell.Utility.psd1') -ErrorAction Stop
foreach($leaf in @('agent-1c.core.ps1','agent-1c.vibecoding1c-mcp.ps1','agent-1c.product-catalog.ps1','agent-1c.memory.ps1','agent-1c.memory-context.ps1')){. (Join-Path $PSScriptRoot ('lib/'+$leaf))}
$binding=Read-ItlMemoryJson $BindingPath
if(-not $binding -or [IO.Path]::GetFullPath($BindingPath) -ine [IO.Path]::GetFullPath((Get-ItlMemoryPath binding $binding.projectRoot))){throw 'MEMORY_BINDING_PATH: use the existing owner-provided private locator.'}
$script:ProjectRoot=$binding.projectRoot
if($binding.mode -eq 'enabled' -and -not (Test-ItlMemoryIdentityComplete $binding.identity)){
    # A binding written by the previous workflow: its owner extends it once,
    # whichever of update-workflow and this first new server comes first.
    try{Sync-ItlMemoryContext -Context $null;$extended=Read-ItlMemoryJson $BindingPath;if($extended){$binding=$extended}}catch{}
}
# One journal session per server process. The two values below live only in
# this process: the context change still to be reported, and the hold on the
# first write after a task cycle or project change.
$sessionId=[guid]::NewGuid().ToString('N');$contextNotice=$null;$writeHold=$false
$tools=@(
    @{name='remember';description='Call in the same turn after a user correction, a rejected approach, a non-obvious finding or a standing condition. One fact. Choose one dataset_name from memory_status by lifetime and reach: task for this cycle, workspace for this local copy, project across branches/copies, product with registry area and independent evidence, workplace for its practices, host for machine facts, organization across products. Give conditions/version where relevant. User statements use status=verified or standing (always/never) with evidence {source:"user",reference:"chat <date>"}; candidate is only an unproven hypothesis and recall never returns it. Organization standing needs explicit user direction. Correct with note_id and data_id from the recall card; finish an unsent pending draft by note_id. Reconcile unconfirmed IDs exactly.';inputSchema=@{type='object';properties=@{data=@{type='string';maxLength=16384};dataset_name=@{type='string'};note_id=@{type='string'};data_id=@{type='string'};status=@{type='string';enum=@('candidate','verified','standing')};title=@{type='string';maxLength=80};applicability=@{type='object'};evidence=@{type='array';items=@{type='object'}};source=@{type='string'};revision=@{type='string'}};required=@('data');additionalProperties=$false}},
    @{name='recall';description='Search before designing a 1C change, in unfamiliar areas and when context is missing. Omit datasets for the admitted union. Use project_id alone for one admitted project as reference. CHUNKS for meaning, CHUNKS_LEXICAL for exact terms. Verify branch code before claiming a recalled fix is present. On temporary failure, read the exact original or retry once if needed. Recall again in the next eligible turn. Coverage may be partial.';inputSchema=@{type='object';properties=@{query=@{type='string';maxLength=4096};datasets=@{type='array';items=@{type='string'}};project_id=@{type='string'};search_type=@{type='string';enum=@('CHUNKS','CHUNKS_LEXICAL')};top_k=@{type='integer';minimum=1;maximum=8}};required=@('query');additionalProperties=$false}},
    @{name='memory_status';description='Call once at session start and after a contextChanged notice: private continuation and pending, standing rules in full and a title index of the other notes, candidates marked. Destination readState is admitted, not_created or unknown; see serverCoverage. local_only=true reads only private state, offline. With dataset_name and note_id or data_id reconcile the exact original. Optional checkpoint stores only goal/constraints/next step/proof refs.';inputSchema=@{type='object';properties=@{dataset_name=@{type='string'};note_id=@{type='string'};data_id=@{type='string'};local_only=@{type='boolean'};history=@{type='boolean'};checkpoint=@{type='object'}};additionalProperties=$false}},
    @{name='retire_note';description='Call when a note is outdated or contradicts a checked source: note_id with dataset_name and data_id from its recall card retires that one note with native rights. note_id alone discards an own unsent pending draft and keeps a private audit copy. Never deletes a dataset.';inputSchema=@{type='object';properties=@{dataset_name=@{type='string'};note_id=@{type='string'};data_id=@{type='string'};knowledge_area=@{type='string'}};required=@('note_id');additionalProperties=$false}}
)
while($null -ne ($line=[Console]::ReadLine())){
    $message=$null;$calledTool='';$recallWatch=$null;$recallBudget=$null;$trace=[ordered]@{}
    try{
        if([Text.Encoding]::UTF8.GetByteCount($line) -gt 65536){throw 'MEMORY_REQUEST_TOO_LARGE'}
        # A .NET client whose console input is UTF-8 prefixes its first line
        # with a byte order mark.
        $line=$line.TrimStart([char]0xFEFF)
        $message=ConvertTo-ItlCatalogCanonicalValue ($line|ConvertFrom-Json -ErrorAction Stop)
        if(-not $message.Contains('id')){continue}
        $result=$null
        switch([string]$message.method){
            'initialize' {$result=@{protocolVersion='2025-03-26';serverInfo=@{name='itl-scoped-cognee';version='1'};capabilities=@{tools=@{}};instructions='Qualified scoped memory only. Seven logical areas, one write, one union recall. Call memory_status first: private continuation/pending, standing rules and the note index; do not treat config as durable success.'}}
            'ping' {$result=@{}}
            'tools/list' {$result=@{tools=$tools}}
            'tools/call' {
                $name=[string]$message.params.name
                $tool=@($tools|Where-Object name -CEQ $name)
                if($tool.Count -ne 1){throw 'MEMORY_TOOL_UNKNOWN'}
                $calledTool=$name
                if($name -ceq 'recall'){$recallWatch=[Diagnostics.Stopwatch]::StartNew()}
                # The binding owner may have updated the record since the last
                # call: follow it instead of refusing until a client reload.
                $live=Resolve-ItlMemoryLiveBinding $binding (Read-ItlMemoryJson $BindingPath)
                $binding=$live.binding
                if($live.contextChanged){$contextNotice=$live.contextChanged;if($live.holdWrites){$writeHold=$true}}
                $proof=Get-ItlCatalogField $binding.policyProofs $Client
                if(-not $proof){throw 'MEMORY_POLICY_UNQUALIFIED'}
                $null=Get-ItlMemoryPolicyProof $proof.path $binding.projectRoot $Client
                $arguments=Get-ItlCatalogField $message.params 'arguments' @{}
                foreach($key in @(Get-ItlCatalogKeys $arguments)){if($key -cnotin @(Get-ItlCatalogKeys $tool[0].inputSchema.properties)){throw 'MEMORY_ARGUMENT_UNKNOWN'}}
                $requiredKeys=Get-ItlCatalogField $tool[0].inputSchema 'required' @()
                foreach($key in $requiredKeys){if(-not (Get-ItlCatalogField $arguments $key)){throw 'MEMORY_ARGUMENT_REQUIRED'}}
                $evidence=Get-ItlCatalogField $arguments 'evidence' @()
                $requestedDatasets=Get-ItlCatalogField $arguments 'datasets' @()
                $held='MEMORY_CONTEXT_CHANGED: the task cycle or project changed under this session, so nothing was written. Call memory_status, then repeat the write only if it belongs to the new context.'
                $value=switch($name){
                    # A held remember still saves its private pending source.
                    'remember' {Invoke-ItlMemoryRemember $binding ([string]$arguments.data) ([string](Get-ItlCatalogField $arguments 'dataset_name' '')) ([string](Get-ItlCatalogField $arguments 'note_id' '')) (Get-ItlCatalogField $arguments 'applicability' @{}) $evidence ([string](Get-ItlCatalogField $arguments 'status' 'candidate')) ([string](Get-ItlCatalogField $arguments 'source' '')) ([string](Get-ItlCatalogField $arguments 'revision' '')) ([string](Get-ItlCatalogField $arguments 'data_id' '')) -Title ([string](Get-ItlCatalogField $arguments 'title' '')) -ContextHold:$writeHold}
                    'recall' {
                        $recallBudget=[DateTime]::UtcNow.AddSeconds(20)
                        $selector=@{}
                        $argumentKeys=@(Get-ItlCatalogKeys $arguments)
                        if($argumentKeys -ccontains 'project_id'){
                            if($argumentKeys -ccontains 'datasets'){throw 'MEMORY_ARGUMENT_INVALID: use one registry project_id without datasets.'}
                            $selector['ReferenceProjectId']=Get-ItlCatalogField $arguments 'project_id'
                        }
                        Invoke-ItlMemoryRecall $binding ([string]$arguments.query) $requestedDatasets ([int](Get-ItlCatalogField $arguments 'top_k' 8)) -SearchType ([string](Get-ItlCatalogField $arguments 'search_type' 'CHUNKS')) -Trace $trace -DeadlineUtc $recallBudget @selector
                    }
                    'memory_status' {
                        if(Get-ItlCatalogField $arguments 'checkpoint'){
                            if($writeHold){throw $held}
                            Assert-ItlMemoryBindingCurrent $binding;Invoke-ItlMemorySetup checkpoint -Checkpoint $arguments.checkpoint
                        }else{
                            Invoke-ItlMemoryStatus $binding ([string](Get-ItlCatalogField $arguments 'dataset_name' '')) ([string](Get-ItlCatalogField $arguments 'note_id' '')) ([string](Get-ItlCatalogField $arguments 'data_id' '')) -LocalOnly:([bool](Get-ItlCatalogField $arguments 'local_only' $false)) -History:([bool](Get-ItlCatalogField $arguments 'history' $false))
                            $writeHold=$false
                        }
                    }
                    'retire_note' {
                        if($writeHold){throw $held}
                        Invoke-ItlMemoryRetire $binding ([string](Get-ItlCatalogField $arguments 'dataset_name' '')) ([string]$arguments.note_id) ([string](Get-ItlCatalogField $arguments 'knowledge_area' '')) ([string](Get-ItlCatalogField $arguments 'data_id' ''))
                    }
                }
                if($contextNotice -and $value -is [Collections.IDictionary]){$value['contextChanged']=$contextNotice;$contextNotice=$null}
                if($recallWatch){$trace['elapsedMs']=$recallWatch.ElapsedMilliseconds}
                Add-ItlMemoryUsage $binding $name $sessionId 'ok' $value $trace
                $result=@{content=@(@{type='text';text=(ConvertTo-Json -InputObject $value -Depth 40 -Compress)});isError=$false}
            }
            default {throw 'MEMORY_METHOD_UNKNOWN'}
        }
        [Console]::WriteLine((ConvertTo-Json -InputObject @{jsonrpc='2.0';id=$message.id;result=$result} -Depth 60 -Compress))
    }catch{
        $text=[string]$_.Exception.Message
        $errorCode=($text -split ':')[0]
        $continuation='Retain private pending/receipts. Check memory_status or existing catalog/lifecycle recovery; do not widen scope or replay an uncertain write.'
        # Owner messages are fixed texts naming the way forward; anything else
        # stays behind the generic code.
        if($errorCode -cmatch '^MEMORY_[A-Z_]+$'){$detail=$text.Substring($errorCode.Length).TrimStart(':',' ');if($detail){$continuation=$detail}}
        else{
            # The client log keeps the unexpected cause; the model sees the code.
            [Console]::Error.WriteLine(('itl-scoped-cognee: '+$_.Exception.GetType().Name+': '+$text.Substring(0,[Math]::Min(300,$text.Length))+' @ '+(@($_.ScriptStackTrace -split "`n")[0])))
            $errorCode='MEMORY_OPERATION_UNCONFIRMED';$text=$errorCode
        }
        if($recallWatch){
            $trace['elapsedMs']=$recallWatch.ElapsedMilliseconds
            if(-not $trace.Contains('failureStage')){$trace['failureStage']='validation'}
            if($errorCode -in @('MEMORY_DEADLINE','MEMORY_TRANSPORT_UNCONFIRMED')){
                $timedOut=$errorCode -eq 'MEMORY_DEADLINE' -or $text -ceq 'MEMORY_TRANSPORT_UNCONFIRMED: deadline'
                $reason=if($timedOut){'The search in this turn timed out.'}else{'This call ended with a transport failure.'}
                $continuation="$reason Coverage is unknown. If needed, read a known original with memory_status(dataset_name, data_id) or retry recall once with the same admitted set. After another failure continue with available sources and report the gap. Use fresh recall in the next eligible turn."
                $trace['failureKind']=if($timedOut){'operation_deadline'}else{'transport'}
            }
        }
        if($calledTool){Add-ItlMemoryUsage $binding $calledTool $sessionId $text -Trace $trace}
        $data=@{continuation=$continuation}
        if($contextNotice){$data['contextChanged']=$contextNotice}
        $id=if($message -and $message.Contains('id')){$message.id}else{$null}
        [Console]::WriteLine((ConvertTo-Json -InputObject @{jsonrpc='2.0';id=$id;error=@{code=-32000;message=$errorCode;data=$data}} -Depth 10 -Compress))
    }
}
