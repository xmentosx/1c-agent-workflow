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
$tools=@(
    @{name='remember';description='Save one scoped fact. Choose an explicit destination from memory_status. Preserve returned unconfirmed IDs; never retry blindly or switch provider.';inputSchema=@{type='object';properties=@{data=@{type='string';maxLength=16384};dataset_name=@{type='string'};note_id=@{type='string'};data_id=@{type='string'};status=@{type='string';enum=@('candidate','verified')};applicability=@{type='object'};evidence=@{type='array';items=@{type='object'}};source=@{type='string'};revision=@{type='string'}};required=@('data');additionalProperties=$false}},
    @{name='recall';description='Search allowed datasets once: CHUNKS for meaning, CHUNKS_LEXICAL for exact terms. Current originals only; partial is not absence.';inputSchema=@{type='object';properties=@{query=@{type='string';maxLength=4096};datasets=@{type='array';items=@{type='string'}};search_type=@{type='string';enum=@('CHUNKS','CHUNKS_LEXICAL')};top_k=@{type='integer';minimum=1;maximum=8}};required=@('query');additionalProperties=$false}},
    @{name='memory_status';description='Read compact private continuation/pending even offline; with dataset/note/data ID reconcile the exact original. Optional checkpoint stores only goal/constraints/next step/proof refs.';inputSchema=@{type='object';properties=@{dataset_name=@{type='string'};note_id=@{type='string'};data_id=@{type='string'};local_only=@{type='boolean'};history=@{type='boolean'};checkpoint=@{type='object'}};additionalProperties=$false}},
    @{name='retire_note';description='Retire one precisely identified note with native rights. Never deletes a dataset.';inputSchema=@{type='object';properties=@{dataset_name=@{type='string'};note_id=@{type='string'};data_id=@{type='string'};knowledge_area=@{type='string'}};required=@('dataset_name','note_id');additionalProperties=$false}}
)
while($null -ne ($line=[Console]::ReadLine())){
    $message=$null
    try{
        if([Text.Encoding]::UTF8.GetByteCount($line) -gt 65536){throw 'MEMORY_REQUEST_TOO_LARGE'}
        $message=ConvertTo-ItlCatalogCanonicalValue ($line|ConvertFrom-Json -ErrorAction Stop)
        if(-not $message.Contains('id')){continue}
        $result=$null
        switch([string]$message.method){
            'initialize' {$result=@{protocolVersion='2025-03-26';serverInfo=@{name='itl-scoped-cognee';version='1'};capabilities=@{tools=@{}};instructions='Qualified scoped memory only. Six logical areas, one write, one union recall. Read private continuation/pending before relying on backend; do not treat config as durable success.'}}
            'ping' {$result=@{}}
            'tools/list' {$result=@{tools=$tools}}
            'tools/call' {
                $proof=Get-ItlCatalogField $binding.policyProofs $Client
                if(-not $proof){throw 'MEMORY_POLICY_UNQUALIFIED'}
                $null=Get-ItlMemoryPolicyProof $proof.path $binding.projectRoot $Client
                $arguments=Get-ItlCatalogField $message.params 'arguments' @{}
                $name=[string]$message.params.name
                $tool=@($tools|Where-Object name -CEQ $name)
                if($tool.Count -ne 1){throw 'MEMORY_TOOL_UNKNOWN'}
                foreach($key in @(Get-ItlCatalogKeys $arguments)){if($key -cnotin @(Get-ItlCatalogKeys $tool[0].inputSchema.properties)){throw 'MEMORY_ARGUMENT_UNKNOWN'}}
                $requiredKeys=Get-ItlCatalogField $tool[0].inputSchema 'required' @()
                foreach($key in $requiredKeys){if(-not (Get-ItlCatalogField $arguments $key)){throw 'MEMORY_ARGUMENT_REQUIRED'}}
                $evidence=Get-ItlCatalogField $arguments 'evidence' @()
                $requestedDatasets=Get-ItlCatalogField $arguments 'datasets' @()
                $value=switch($name){
                    'remember' {Invoke-ItlMemoryRemember $binding ([string]$arguments.data) ([string](Get-ItlCatalogField $arguments 'dataset_name' '')) ([string](Get-ItlCatalogField $arguments 'note_id' '')) (Get-ItlCatalogField $arguments 'applicability' @{}) $evidence ([string](Get-ItlCatalogField $arguments 'status' 'candidate')) ([string](Get-ItlCatalogField $arguments 'source' '')) ([string](Get-ItlCatalogField $arguments 'revision' '')) ([string](Get-ItlCatalogField $arguments 'data_id' ''))}
                    'recall' {Invoke-ItlMemoryRecall $binding ([string]$arguments.query) $requestedDatasets ([int](Get-ItlCatalogField $arguments 'top_k' 8)) -SearchType ([string](Get-ItlCatalogField $arguments 'search_type' 'CHUNKS'))}
                    'memory_status' {if(Get-ItlCatalogField $arguments 'checkpoint'){Assert-ItlMemoryBindingCurrent $binding;Invoke-ItlMemorySetup checkpoint -Checkpoint $arguments.checkpoint}else{Invoke-ItlMemoryStatus $binding ([string](Get-ItlCatalogField $arguments 'dataset_name' '')) ([string](Get-ItlCatalogField $arguments 'note_id' '')) ([string](Get-ItlCatalogField $arguments 'data_id' '')) -LocalOnly:([bool](Get-ItlCatalogField $arguments 'local_only' $false)) -History:([bool](Get-ItlCatalogField $arguments 'history' $false))}}
                    'retire_note' {Invoke-ItlMemoryRetire $binding $arguments.dataset_name $arguments.note_id ([string](Get-ItlCatalogField $arguments 'knowledge_area' '')) ([string](Get-ItlCatalogField $arguments 'data_id' ''))}
                }
                $result=@{content=@(@{type='text';text=(ConvertTo-Json -InputObject $value -Depth 40 -Compress)});isError=$false}
            }
            default {throw 'MEMORY_METHOD_UNKNOWN'}
        }
        [Console]::WriteLine((ConvertTo-Json -InputObject @{jsonrpc='2.0';id=$message.id;result=$result} -Depth 60 -Compress))
    }catch{
        $errorCode=($_.Exception.Message -split ':')[0]
        if($errorCode -cnotmatch '^MEMORY_[A-Z_]+$'){$errorCode='MEMORY_OPERATION_UNCONFIRMED'}
        $id=if($message -and $message.Contains('id')){$message.id}else{$null}
        [Console]::WriteLine((ConvertTo-Json -InputObject @{jsonrpc='2.0';id=$id;error=@{code=-32000;message=$errorCode;data=@{continuation='Retain private pending/receipts. Check memory_status or existing catalog/lifecycle recovery; do not widen scope or replay an uncertain write.'}}} -Depth 10 -Compress))
    }
}
