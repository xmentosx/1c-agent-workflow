Describe 'Scoped Cognee source contract (G4, no native G5)' {
    BeforeAll {
        $RepoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
        foreach($leaf in @('runtime-values','core','vanessa','vibecoding1c-mcp','product-catalog','memory','memory-context','lifecycle')){
            . (Join-Path $RepoRoot ".agents/skills/1c-workflow/scripts/lib/agent-1c.$leaf.ps1")
        }
        $savedHome=$env:VIBECODING1C_MCP_LOCAL_HOME
        $NativeMemoryHttp=${function:Invoke-ItlMemoryHttp}
        function New-MemoryFixture {
            $script:ProjectRoot=Join-Path $TestDrive ('Проект с пробелом '+[guid]::NewGuid().ToString('N'))
            [void][IO.Directory]::CreateDirectory($script:ProjectRoot)
            $env:VIBECODING1C_MCP_LOCAL_HOME=Join-Path $TestDrive ('Личное состояние '+[guid]::NewGuid().ToString('N'))
            $identity=Get-ItlMemoryWorkspace $script:ProjectRoot 'ordinary-user'
            $cycle=[guid]::NewGuid().ToString('N')
            $context=@{projectId='customer';productId='prof';catalogRevision='published-sha';knowledgeHash='knowledge';projectContext=@{customized=$true};knowledgeContext=@{productReadCandidates=@('corp');knowledgeAreas=@();conditionValues=@{};productVersion='5.0'}}
            $b=[ordered]@{schemaVersion=1;capability='scoped-cognee-memory-v1';mode='enabled';bindingId='b1';projectRoot=$script:ProjectRoot;cycleStatePath=(Join-Path $script:ProjectRoot 'cycle.json');appliedPath=(Join-Path $script:ProjectRoot 'applied.json');cycleId=$cycle;registryContextHash=(Get-ItlCatalogHash $context);context=$context;identity=$identity;provider=@{instanceId='fixture';organizationId='org';datasets=@()};memoryProjection=@{knowledgeAreas=@{};composition=@();snapshot=@{relations=@{relations=@()}}}}
            $scopes=@(Get-ItlMemoryPrivateScopes $b)+@(@{scopeKind='product';scopeId='corp';label='itl_product_corp'},@{scopeKind='project';scopeId='customer';label='itl_project_customer'},@{scopeKind='organization';scopeId='org';label='itl_org_org'})
            foreach($s in $scopes){$s.datasetId=[guid]::NewGuid().ToString();$s.ownerId='ordinary-user';$s.permissions=@('read','write');$s.admitted=$true}
            $b.provider.datasets=$scopes
            Write-Utf8TextAtomic $b.cycleStatePath (@{memoryCycle=@{current=$cycle;reserved='';workspaceId=$identity.workspaceId}}|ConvertTo-Json)
            Write-Utf8TextAtomic $b.appliedPath (@{context=$context;contextHash=$b.registryContextHash}|ConvertTo-Json -Depth 20)
            $null=Update-ItlMemoryJson (Get-ItlMemoryPath binding $b.projectRoot) {param($old) return $b}
            $script:Calls=[Collections.Generic.List[object]]::new();$script:Originals=@{};$script:BodyLoss=$false
            return $b
        }
        function Install-MemoryPolicyFixture {
            param([string]$Root)
            $relative='.cursor/rules/project-memory.mdc'
            $policy=Join-Path $Root $relative
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $policy))
            Copy-Item -LiteralPath (Join-Path $RepoRoot 'tests/fixtures/scoped-memory/project-memory.md') -Destination $policy
            $contract=Read-ItlMemoryJson (Join-Path $RepoRoot '.agents/skills/1c-workflow/assets/scoped-memory-policy.json')
            [void][IO.Directory]::CreateDirectory((Join-Path $Root '.agent-1c'))
            $manifest=@{tools=@('cursor');files=@{}}
            $manifest.files[$relative]=@{source='content/rules/project-memory.md';installedHash=(Get-FileHash -LiteralPath $policy -Algorithm SHA256).Hash.ToLowerInvariant();userModified=$false}
            Write-Utf8TextAtomic (Join-Path $Root '.ai-rules.json') ($manifest|ConvertTo-Json -Depth 12)
            Write-Utf8TextAtomic (Join-Path $Root '.agent-1c/dependency-lock.json') (@{schemaVersion=1;dependencies=@{aiRules1c=@{commit=$contract.rulesCandidateCommit}}}|ConvertTo-Json -Depth 10)
            return $policy
        }
        function Get-ProjectDataset {param($b) @($b.provider.datasets|Where-Object scopeKind -EQ 'project')[0]}
    }
    BeforeEach {
        $b=New-MemoryFixture
        Mock Invoke-ItlMemoryHttp {
            param($Provider,$Method,$Path,$Body,$DeadlineUtc,$ContentType,$Raw)
            $script:Calls.Add(@{method=$Method;path=$Path;body=$Body})
            if($Path -eq '/api/v1/users/me'){return @{status=200;body=@{id='ordinary-user';is_superuser=$false}}}
            if($Path -eq '/api/v1/remember'){
                $parts=@{};foreach($p in $Body.Split('&')){$kv=$p.Split('=',2);$parts[$kv[0]]=[uri]::UnescapeDataString($kv[1])}
                $note=$parts.raw_data|ConvertFrom-Json;$id=[guid]::NewGuid().ToString()
                $script:Originals[$id]=$parts.raw_data
                if($script:BodyLoss){throw 'MEMORY_TRANSPORT_UNCONFIRMED'}
                return @{status=200;body=@{items=@(@{id=$id})}}
            }
            if($Path -match '/data/([^/]+)/raw$'){
                $id=$Matches[1];if($script:Originals.ContainsKey($id)){return @{status=200;body=$script:Originals[$id]}}
                return @{status=404;body=''}
            }
            if($Path -match '/data$'){return @{status=200;body=@($script:Originals.Keys|ForEach-Object {@{id=$_}})}}
            if($Method -eq 'PATCH'){
                $id=([regex]::Match($Path,'data_id=([^&]+)')).Groups[1].Value
                $script:Originals[$id]=($Body -split "`r`n`r`n",2)[1] -replace "`r`n--itl_.*$",''
                return @{status=200;body=@{status='incremental'}}
            }
            if($Path -like '/api/v1/datasets/status*'){return @{status=200;body=@{}}}
            if($Path -eq '/api/v1/forget'){$script:Originals.Remove($Body.dataId);return @{status=200;body=@{}}}
            throw "unexpected fixture call $Method $Path"
        }
    }
    AfterAll {$env:VIBECODING1C_MCP_LOCAL_HOME=$savedHome}

    It 'binds the scoped memory policy to the same fork candidate as the installer pin' {
        $contract=Read-ItlMemoryJson (Join-Path $RepoRoot '.agents/skills/1c-workflow/assets/scoped-memory-policy.json')
        $lock=Read-ItlMemoryJson (Join-Path $RepoRoot 'templates/dependency-lock.json')
        $contract.rulesCandidateCommit | Should -BeExactly $lock.dependencies.aiRules1c.commit
        # The new candidate cannot inherit historical G5 proof for its MO changes.
        $contract.candidateStatus | Should -Match 'MO and publication pending'
    }

    It 'resolves six areas, rejects implicit writes and does not infer a product home' {
        @(Get-ItlMemoryScopes $b read).Count | Should -Be 6
        $persisted=Read-ItlMemoryJson (Get-ItlMemoryPath binding $b.projectRoot)
        $destinations=@((Invoke-ItlMemoryStatus $persisted -LocalOnly).destinations)
        @($destinations|Where-Object {-not $_.label -or -not $_.scopeKind -or -not $_.scopeId}).Count | Should -Be 0
        @($destinations|Where-Object scopeKind -EQ project)[0].label | Should -BeExactly 'itl_project_customer'
        @($destinations|Where-Object scopeKind -EQ organization)[0].label | Should -BeExactly 'itl_org_org'
        {Get-ItlMemoryScopes $b write} | Should -Throw '*MEMORY_DESTINATION_REQUIRED*'
        {Get-ItlMemoryScopes $b write 'itl_product_corp' 'planning'} | Should -Throw '*MEMORY_DESTINATION_REQUIRED*'
        $b.context.knowledgeContext.knowledgeAreas=@(@{areaId='planning';status='applicable';memoryHomeProductId='corp'})
        @(Get-ItlMemoryScopes $b write 'itl_product_corp' 'planning').Count | Should -Be 1
        $b.provider.datasets[0].scopeId='old-cycle'
        @(Get-ItlMemoryScopes $b read).Count | Should -Be 5
    }
    It 'keeps workspace/workplace stable without allocating six datasets' {
        $again=Get-ItlMemoryWorkspace $b.projectRoot 'ordinary-user'
        $again.workspaceId | Should -Be $b.identity.workspaceId
        $again.workplaceId | Should -Be $b.identity.workplaceId
        $copy=Get-ItlMemoryWorkspace (Join-Path $TestDrive 'Независимая копия') 'ordinary-user'
        $copy.workspaceId | Should -Not -Be $again.workspaceId
        $copy.workplaceId | Should -Be $again.workplaceId
        $copiedState=@{memoryCycle=@{current=$b.cycleId;reserved='';workspaceId=$again.workspaceId}}
        $first=Get-ItlMemoryCycleUpdates $copiedState initial $copy.workspaceId
        $first.memoryCycle.current | Should -Not -Be $b.cycleId
        $first.memoryCycle.workspaceId | Should -Be $copy.workspaceId
        (Get-ItlMemoryCycleUpdates $first initial $copy.workspaceId).memoryCycle.current | Should -Be $first.memoryCycle.current
        $script:Calls.Count | Should -Be 0
    }
    It 'retains an ambiguous destination in private pending with no backend write' {
        {Invoke-ItlMemoryRemember $b 'Проверенная особенность' ''} | Should -Throw '*MEMORY_DESTINATION_REQUIRED*'
        $local=Invoke-ItlMemoryStatus $b -LocalOnly
        @($local.pending).Count | Should -Be 1
        $local.pending[0].fact | Should -Be 'Проверенная особенность'
        $script:Calls.Count | Should -Be 0
    }
    It 'reconciles accepted body loss after restart without replaying remember' {
        $script:BodyLoss=$true
        $r=Invoke-ItlMemoryRemember $b 'Непустой факт' 'itl_project_customer' 'body-loss'
        $r.state | Should -Be 'unconfirmed'
        (Invoke-ItlMemoryStatus $b -LocalOnly).pending.Count | Should -Be 1
        $r=Invoke-ItlMemoryRemember $b 'Непустой факт' 'itl_project_customer' 'body-loss'
        $r.state | Should -Be 'durable'
        @($script:Calls|Where-Object path -EQ '/api/v1/remember').Count | Should -Be 1
        @((Invoke-ItlMemoryStatus $b -LocalOnly).pending).Count | Should -Be 0
        (Invoke-ItlMemoryStatus $b -NoteId body-loss -LocalOnly).preservedSource.intent.data | Should -Be 'Непустой факт'
        (Invoke-ItlMemoryStatus $b -LocalOnly).receipts[0].dataId | Should -Be $r.dataId
    }
    It 'updates the exact original when evidence/status change even with the same fact' {
        $r=Invoke-ItlMemoryRemember $b 'Stable fact' 'itl_project_customer' 'same-fact'
        $r.state | Should -Be 'durable'
        # A fresh ordinary reader may know the native ID without a local receipt.
        $key=Get-ItlMemoryRecordKey $b (Get-ProjectDataset $b).datasetId same-fact
        Remove-Item -LiteralPath (Get-ItlMemoryPath receipt $key)
        $r=Invoke-ItlMemoryRemember $b 'Stable fact' 'itl_project_customer' 'same-fact' @{} @(@{source='test'}) verified -DataId $r.dataId
        $r.state | Should -Be 'durable'
        ($script:Originals[$r.dataId]|ConvertFrom-Json).status | Should -Be 'verified'
        @($script:Calls|Where-Object method -EQ 'PATCH').Count | Should -Be 1
        @($script:Calls|Where-Object method -EQ 'PATCH')[0].body | Should -Match 'Content-Disposition: form-data; name="data"; filename="memory.txt"'
        @($script:Calls|Where-Object path -EQ '/api/v1/remember').Count | Should -Be 1
    }
    It 'retains a changed unresolved pending instead of overwriting its source' {
        $script:BodyLoss=$true
        $null=Invoke-ItlMemoryRemember $b 'First' 'itl_project_customer' 'pending'
        {Invoke-ItlMemoryRemember $b 'Second' 'itl_project_customer' 'pending'} | Should -Throw '*MEMORY_PENDING_CONFLICT*'
        {Invoke-ItlMemoryRemember $b 'First' 'itl_org_org' 'pending'} | Should -Throw '*MEMORY_DESTINATION_LOCKED*'
        (Invoke-ItlMemoryStatus $b -LocalOnly).pending[0].fact | Should -Be 'First'
    }
    It 'reserves one cycle across repeated reset/resume and invalidates an old client' {
        $state=@{memoryCycle=@{current=$b.cycleId;reserved='';workspaceId=$b.identity.workspaceId}}
        $reserved=Get-ItlMemoryCycleUpdates $state reserve
        $state.memoryCycle=$reserved.memoryCycle
        (Get-ItlMemoryCycleUpdates $state reserve).memoryCycle.reserved | Should -Be $state.memoryCycle.reserved
        Write-Utf8TextAtomic $b.cycleStatePath ($state|ConvertTo-Json)
        {Assert-ItlMemoryBindingCurrent $b} | Should -Throw '*MEMORY_STALE_CONTEXT*'
        $next=Get-ItlMemoryCycleUpdates $state complete
        $next.memoryCycle.current | Should -Be $state.memoryCycle.reserved
        $next.memoryCycle.reserved | Should -Be ''
    }
    It 'refuses a stale registry context before sending recall' {
        $b.registryContextHash='other'
        {Invoke-ItlMemoryRecall $b 'query'} | Should -Throw '*MEMORY_STALE_CONTEXT*'
        $script:Calls.Count | Should -Be 0
    }
    It 'returns current authorized originals instead of stale CHUNKS and caps scope' {
        $r=Invoke-ItlMemoryRemember $b 'Current fact' 'itl_project_customer' 'current' @{} @(@{source='proof'}) verified
        $dataset=Get-ProjectDataset $b
        $script:BudgetOriginalIds=@($r.dataId)
        foreach($number in 2..8){
            $other=Invoke-ItlMemoryRemember $b ('Current fact '+$number+': validate the object identifier before the fixture operation.') 'itl_project_customer' ('current-'+$number) @{} @(@{source='proof'}) verified
            $script:BudgetOriginalIds+=,$other.dataId
        }
        Mock Invoke-ItlMemoryHttp {param($Provider,$Method,$Path,$Body)
            $script:Calls.Add(@{method=$Method;path=$Path;body=$Body})
            @{status=200;body=@($script:BudgetOriginalIds|ForEach-Object {@{text='Wrong stale chunk';dataset_id=$dataset.datasetId;metadata=@{data_id=$_}}})}
        } -ParameterFilter {$Path -eq '/api/v1/recall'}
        $recall=Invoke-ItlMemoryRecall $b query
        $recall.cards[0].fact | Should -Be 'Current fact'
        $recall.cards.Count | Should -Be 8
        $recall.sourceLookups | Should -Be 8
        $call=@($script:Calls|Where-Object path -EQ '/api/v1/recall')
        $call.Count | Should -Be 1
        $call[0].body.dataset_ids.Count | Should -Be 6
        $call[0].body.search_type | Should -Be CHUNKS
        $call[0].body.top_k | Should -Be 24
        # D8 is 1600 actual tokens, not 1600 UTF-8 bytes. Preserve the
        # native failure: eight applicable current facts must not become two.
        $payload=ConvertTo-Json -InputObject $recall -Depth 40 -Compress
        $recall.utf8Bytes | Should -Be ([Text.Encoding]::UTF8.GetByteCount($payload))
        $recall.utf8Bytes | Should -BeGreaterThan 1600
        . (Join-Path $RepoRoot '.agents/skills/1c-workflow/scripts/lib/agent-1c.memory-tokens.ps1')
        $payloadTokens=Measure-ItlMemoryTokens $payload
        $payloadTokens.measurement | Should -Be 'measured-encode-ordinary'
        $payloadTokens.cl100k_base | Should -BeLessOrEqual 1600
        $payloadTokens.o200k_base | Should -BeLessOrEqual 1600

        # The native multi-dataset response can contain top_k rows per dataset.
        # Preserve the original eight authorized originals and all assertions above.
        $product=@($b.provider.datasets|Where-Object scopeKind -EQ product)[0]
        $script:GroupedRecallChunks=@()
        foreach($number in 1..24){
            $id=[guid]::NewGuid().ToString()
            $note=$script:Originals[$r.dataId]|ConvertFrom-Json
            $note.noteId='corp-only-'+$number
            $note.scope=[pscustomobject]@{kind='product';id='corp'}
            $note.applicability=[pscustomobject]@{availableIn=@('corp');knowledgeArea='planning'}
            $script:Originals[$id]=ConvertTo-Json $note -Depth 30 -Compress
            $script:GroupedRecallChunks+=,@{text='Untrusted grouped fragment';dataset_id=$product.datasetId;metadata=@{data_id=$id}}
        }
        $script:GroupedRecallChunks+=@($script:BudgetOriginalIds|ForEach-Object {@{text='Wrong stale chunk';dataset_id=$dataset.datasetId;metadata=@{data_id=$_}}})
        Mock Invoke-ItlMemoryHttp {
            param($Provider,$Method,$Path,$Body)
            $script:Calls.Add(@{method=$Method;path=$Path;body=$Body})
            @{status=200;body=@($script:GroupedRecallChunks)}
        } -ParameterFilter {$Path -eq '/api/v1/recall'}
        $grouped=Invoke-ItlMemoryRecall $b query
        $grouped.cards.Count | Should -Be 8
        $grouped.cards[0].noteId | Should -Be current
        $grouped.sourceLookups | Should -BeLessOrEqual 24
        @($script:Calls|Where-Object path -EQ '/api/v1/recall').Count | Should -Be 2
        $lexical=Invoke-ItlMemoryRecall $b 'Object.ErrorCode' -SearchType CHUNKS_LEXICAL
        $lexical.cards.Count | Should -Be 8
        @($script:Calls|Where-Object path -EQ '/api/v1/recall')[-1].body.search_type | Should -BeExactly CHUNKS_LEXICAL
        $lexical.PSObject.Properties.Name | Should -Not -Contain reformulation

    }
    It 'retires one exact note without deleting the dataset' {
        $r=Invoke-ItlMemoryRemember $b 'Retire me' 'itl_project_customer' 'old'
        $key=Get-ItlMemoryRecordKey $b (Get-ProjectDataset $b).datasetId old
        Remove-Item -LiteralPath (Get-ItlMemoryPath receipt $key)
        (Invoke-ItlMemoryRetire $b 'itl_project_customer' old -DataId $r.dataId).state | Should -Be retired
        $script:Originals.ContainsKey($r.dataId) | Should -BeFalse
        @($script:Calls|Where-Object method -EQ DELETE).Count | Should -Be 0
    }
    It 'reconciles pending through status without a second write' {
        $script:BodyLoss=$true
        $null=Invoke-ItlMemoryRemember $b 'Status recovery' 'itl_project_customer' 'status'
        (Invoke-ItlMemoryStatus $b 'itl_project_customer' status).state | Should -Be durable
        @((Invoke-ItlMemoryStatus $b -LocalOnly).pending).Count | Should -Be 0
        @($script:Calls|Where-Object path -EQ '/api/v1/remember').Count | Should -Be 1
    }
    It 'does not create a duplicate private dataset after an uncertain creation' {
        $private=@(Get-ItlMemoryPrivateScopes $b)[0]
        $b.provider.datasets=@($b.provider.datasets|Where-Object scopeKind -NE taskCycle)
        $null=Update-ItlMemoryJson (Get-ItlMemoryPath binding $b.projectRoot) {param($old) return $b}
        Mock Invoke-ItlMemoryHttp {throw 'MEMORY_TRANSPORT_UNCONFIRMED'} -ParameterFilter {$Path -eq '/api/v1/datasets' -and $Method -eq 'POST'}
        {Resolve-ItlMemoryPrivateDataset $b $private.label ([DateTime]::UtcNow.AddSeconds(60))} | Should -Throw '*UNCONFIRMED*'
        Mock Invoke-ItlMemoryHttp {@{status=200;body=@(@{name=$private.label;id=[guid]::NewGuid().ToString();ownerId='foreign-owner'})}} -ParameterFilter {$Path -eq '/api/v1/datasets' -and $Method -eq 'GET'}
        {Resolve-ItlMemoryPrivateDataset $b $private.label ([DateTime]::UtcNow.AddSeconds(60))} | Should -Throw '*MEMORY_DATASET_UNCONFIRMED*'
        Should -Invoke Invoke-ItlMemoryHttp -Times 1 -Exactly -ParameterFilter {$Path -eq '/api/v1/datasets' -and $Method -eq 'POST'}
    }
    It 'preserves permanent pending through reset but hides old task pending' {
        $private=@(Get-ItlMemoryPrivateScopes $b)[0]
        $script:BodyLoss=$true
        $null=Invoke-ItlMemoryRemember $b 'Task source' $private.label 'old-task'
        $null=Invoke-ItlMemoryRemember $b 'Workspace source' @((Get-ItlMemoryPrivateScopes $b)|Where-Object scopeKind -EQ workspace)[0].label 'workspace'
        Write-Utf8TextAtomic $b.cycleStatePath (@{memoryCycle=@{current='next-cycle';reserved=''}}|ConvertTo-Json)
        $local=Invoke-ItlMemoryStatus $b -LocalOnly
        @($local.pending).Count | Should -Be 1
        $local.pending[0].fact | Should -Be 'Workspace source'
    }
    It 'binds policy to the actual approved installed clause and rejects legacy r47' {
        $policy=Install-MemoryPolicyFixture $b.projectRoot
        (Get-ItlMemoryPolicyProof $policy $b.projectRoot).capability | Should -Be scoped-cognee-memory-v1
        Write-Utf8TextAtomic $policy 'Legacy rules without qualified route'
        {Get-ItlMemoryPolicyProof $policy $b.projectRoot} | Should -Throw '*MEMORY_POLICY_UNQUALIFIED*'
    }
    It 'uses a private credential locator and rejects ambiguous dataset identity' {
        $contract=Read-ItlMemoryJson (Join-Path $RepoRoot '.agents/skills/1c-workflow/assets/scoped-memory-policy.json')
        $b.provider.profile=$contract.profile;$b.provider.qualificationResultSha256=$contract.qualificationResultSha256
        $b.provider.principalId=$b.identity.developerId;$b.provider.url='https://memory.invalid/'
        $b.provider.credentialFile=Join-Path $env:VIBECODING1C_MCP_LOCAL_HOME 'credential.json'
        {Assert-ItlMemoryProvider $b.provider $b.projectRoot} | Should -Not -Throw
        $b.provider.toolPolicy='INVALID'
        {Assert-ItlMemoryPrincipal $b ([DateTime]::UtcNow.AddSeconds(2))} | Should -Throw '*MEMORY_TOOL_POLICY_INVALID*'
        $b.provider.toolPolicy='OFF'
        {Assert-ItlMemoryPrincipal $b ([DateTime]::UtcNow.AddSeconds(2))} | Should -Throw '*MEMORY_TOOL_OFF*'
        $script:Calls.Count | Should -Be 0
        $b.provider.toolPolicy='auto'
        $b.provider.datasets[0].admitted=$false
        {Assert-ItlMemoryProvider $b.provider $b.projectRoot} | Should -Not -Throw
        @(Get-ItlMemoryScopes $b read).Count | Should -Be 5
        $b.provider.datasets+=@($b.provider.datasets[0])
        {Assert-ItlMemoryProvider $b.provider $b.projectRoot} | Should -Throw '*MEMORY_MAPPING_AMBIGUOUS*'
        $b.provider.credentialFile=Join-Path $b.projectRoot 'secret.json'
        {Assert-ItlMemoryProvider $b.provider $b.projectRoot} | Should -Throw '*MEMORY_CREDENTIAL_PRIVATE*'
    }
    It 'counts named encodings against frozen official tokenizer vectors without Python at runtime' {
        . (Join-Path $RepoRoot '.agents/skills/1c-workflow/scripts/lib/agent-1c.memory-tokens.ps1')
        $vectors=Read-ItlMemoryJson (Join-Path $RepoRoot 'tests/fixtures/scoped-memory/token-vectors.json')
        foreach($v in $vectors.vectors){
            $m=Measure-ItlMemoryTokens $v.text
            $m.cl100k_base | Should -Be $v.cl100k_base -Because $v.text
            $m.o200k_base | Should -Be $v.o200k_base -Because $v.text
        }
        (Measure-ItlMemoryTokens ([char]0xD83D+[string][char]0xDE00)).measurement | Should -Be unknown-non-BMP
    }
    It 'uses the registry resolver for canonical home and excludes ERP-dependent facts in PROF' {
        $rule=@{availableIn=@('prof');memoryHomeProductId='corp'}
        $b.memoryProjection.knowledgeAreas=@{planning=$rule}
        $note=@{status='verified';scope=@{kind='product';id='corp'};applicability=@{knowledgeArea='planning'}}
        Test-ItlMemoryNoteApplicable $b $note | Should -BeTrue
        $note.applicability.requiresProducts=@('erp')
        Test-ItlMemoryNoteApplicable $b $note | Should -BeFalse
        $note.applicability.Remove('requiresProducts');$rule.Remove('memoryHomeProductId')
        Test-ItlMemoryNoteApplicable $b $note | Should -BeFalse
        $note.scope.kind='project';$note.scope.id='customer';$note.applicability.requiresProducts=@('erp')
        Test-ItlMemoryNoteApplicable $b $note | Should -BeFalse
        $note.applicability.Remove('requiresProducts');$note.scope.kind='taskCycle';$note.origin=@{projectId='another-project'}
        Test-ItlMemoryNoteApplicable $b $note | Should -BeFalse
        $note.origin.projectId=$b.context.projectId;$note.scope.id='prior-cycle'
        Test-ItlMemoryNoteApplicable $b $note | Should -BeFalse
        $note.scope.id=$b.cycleId
        Test-ItlMemoryNoteApplicable $b $note | Should -BeTrue
    }
    It 'contributes a qualified stdio endpoint to the existing plan and disables without deleting data' {
        foreach($leaf in @('client-adapters','client-opencode','jsonc')){. (Join-Path $RepoRoot ".agents/skills/1c-workflow/scripts/lib/agent-1c.$leaf.ps1")}
        $policy=Install-MemoryPolicyFixture $b.projectRoot
        $b.policyProofs=@{cursor=(Get-ItlMemoryPolicyProof $policy $b.projectRoot)}
        $script:Agent1cScriptRoot=Join-Path $RepoRoot '.agents/skills/1c-workflow/scripts'
        $script:Config=[pscustomobject]@{};$script:ItlMcpRegistryOperation=@{error=$null}
        $null=Update-ItlMemoryJson (Get-ItlMemoryPath binding $b.projectRoot) {param($old) return $b}
        $requests=Write-Vibecoding1cMcpClientConfig -Client cursor -ReturnRequests -EndpointSet @{allEndpoints=@()}
        $memory=@($requests|Where-Object owner -EQ scoped-memory)
        $memory.Count | Should -Be 1
        $memory[0].endpoints[0].transport | Should -Be stdio
        $memory[0].endpoints[0].args | Should -Contain (Get-ItlMemoryPath binding $b.projectRoot)
        Mock Write-Vibecoding1cMcpClientConfig {}
        (Invoke-ItlMemorySetup disable -Client cursor).datasetsPreserved | Should -BeTrue
        (Read-ItlMemoryJson (Get-ItlMemoryPath binding $b.projectRoot)).mode | Should -Be disabled
        Get-ItlMemoryClientEndpoint cursor | Should -BeNullOrEmpty
        (Read-ItlMemoryJson (Get-ItlMemoryPath binding $b.projectRoot)).provider.datasets.Count | Should -Be 6
    }
    It 'blocks old package copy and accepts the same compatibility request after owned disable' {
        . (Join-Path $RepoRoot '.agents/skills/1c-workflow/scripts/lib/agent-1c.product-project-context.ps1')
        Mock Get-ItlProductProjectBinding {$null}
        Mock Write-Vibecoding1cMcpClientConfig {}
        {Assert-ItlProductProjectPackageCompatibility -SourceRoot $b.projectRoot} | Should -Throw '*MEMORY_PACKAGE_INCOMPATIBLE*'
        $null=Invoke-ItlMemorySetup disable -Client cursor
        {Assert-ItlProductProjectPackageCompatibility -SourceRoot $b.projectRoot} | Should -Not -Throw
    }
    It 'initializes an existing branch once through its state owner and preserves IDs across disable-enable' {
        . Import-ItlProductProject
        $contract=Read-ItlMemoryJson (Join-Path $RepoRoot '.agents/skills/1c-workflow/assets/scoped-memory-policy.json')
        $b.provider.profile=$contract.profile;$b.provider.qualificationResultSha256=$contract.qualificationResultSha256
        $b.provider.principalId=$b.identity.developerId;$b.provider.url='https://memory.invalid/'
        $b.provider.credentialFile=Join-Path $env:VIBECODING1C_MCP_LOCAL_HOME 'credential.json'
        $settings=Join-Path $env:VIBECODING1C_MCP_LOCAL_HOME 'provider.json'
        $rootMemory=Join-Path $b.projectRoot 'memory.md'
        Write-Utf8TextAtomic $rootMemory '# Existing strict project rules: preserve exact bytes.'
        $originalHash=(Get-FileHash -LiteralPath $rootMemory -Algorithm SHA256).Hash
        Write-Utf8TextAtomic $settings ($b.provider|ConvertTo-Json -Depth 30)
        $policy=Install-MemoryPolicyFixture $b.projectRoot
        $script:DevBranchName='fixture'
        $script:InitialState=[pscustomobject]@{statePath=$b.cycleStatePath;worktreePath=$b.projectRoot}
        # The public memory entrypoint has no pre-seeded registry operation.
        # Reuse its validated applied SHA through the registry owner, not HEAD
        # or a second refresh when constructing the memory projection.
        Remove-Variable ItlMcpRegistryOperation -Scope Script -ErrorAction SilentlyContinue
        $b.context['registryMetadata']=@{schemaVersion=1}
        $b.registryContextHash=Get-ItlCatalogHash $b.context
        $script:MemoryAppliedSnapshot=@{catalogRevision=$b.context.catalogRevision;relations=@{relations=@();knowledgeAreas=@{}}}
        Mock Get-ItlProductProjectOperationContext {$b.context}
        Mock Read-ItlProductProjectRecord {@{configurationState='configured';catalogRevision=$b.context.catalogRevision;context=$b.context;contextHash=$b.registryContextHash}}
        Mock Get-Vibecoding1cMcpRegistryRoot {$TestDrive}
        Mock Read-ItlProductCatalogSnapshot {
            param($RepositoryRoot,$Commit)
            $Commit | Should -BeExactly $b.context.catalogRevision
            return $script:MemoryAppliedSnapshot
        }
        Mock Update-Vibecoding1cMcpRegistryCheckout {throw 'Memory enable must not refresh the registry'}
        Mock Read-DevBranchState {$script:InitialState}
        Mock Assert-CurrentProjectRootMatchesDevBranchState {}
        Mock Update-DevBranchState {param($State,$Updates)
            $script:InitialState|Add-Member -MemberType NoteProperty -Name memoryCycle -Value $Updates.memoryCycle -Force
            Write-Utf8TextAtomic $State.statePath (@{memoryCycle=$Updates.memoryCycle}|ConvertTo-Json)
        }
        Mock Write-Vibecoding1cMcpClientConfig {}
        Write-Utf8TextAtomic (Join-Path (Get-ItlMemoryHome) 'provider.json') ($b.provider|ConvertTo-Json -Depth 30)
        Remove-Item -LiteralPath (Get-ItlMemoryPath binding $b.projectRoot)
        $first=Invoke-ItlMemorySetup auto -Client cursor
        $first.mode | Should -BeExactly configured -Because ($first|ConvertTo-Json -Compress)
        (Read-ItlMemoryJson (Get-ItlMemoryPath binding $b.projectRoot)).settingsHash | Should -BeExactly (Get-ItlCatalogHash (Read-ItlMemoryJson (Join-Path (Get-ItlMemoryHome) 'provider.json')))
        $repeat=Invoke-ItlMemorySetup auto -Client cursor -SettingsPath $settings -PolicyPath $policy
        $repeat.mode | Should -BeExactly configured

        $first.mode | Should -Be configured
        $null=Invoke-ItlMemorySetup disable -Client cursor
        (Invoke-ItlMemorySetup auto -Client cursor -SettingsPath $settings -PolicyPath $policy).mode | Should -BeExactly disabled
        $second=Invoke-ItlMemorySetup enable -Client cursor -SettingsPath $settings -PolicyPath $policy
        $second.cycleId | Should -Be $first.cycleId
        $second.workspaceId | Should -Be $first.workspaceId
        (Get-FileHash -LiteralPath $rootMemory -Algorithm SHA256).Hash | Should -Be $originalHash
        Should -Invoke Update-DevBranchState -Times 1 -Exactly
        Should -Invoke Read-ItlProductCatalogSnapshot -Times 2 -Exactly
        Should -Invoke Update-Vibecoding1cMcpRegistryCheckout -Times 0 -Exactly
        @($script:Calls|Where-Object {$_.method -ne 'GET' -or $_.path -ne '/api/v1/users/me'}).Count | Should -Be 0
    }
    It 'serializes two local sessions without losing records or misreading an active writer' {
        $path=Get-ItlMemoryPath continuation $b.identity.workspaceId
        $null=Update-ItlMemoryJson $path {param($old) return @{count=0}}
        $jobs=@()
        try {
            foreach($i in 1..2){
                $jobs+=Start-Job -ScriptBlock {
                    param($Repo,$Record)
                    $ErrorActionPreference='Stop'
                    foreach($leaf in @('core','product-catalog','memory')){. (Join-Path $Repo ".agents/skills/1c-workflow/scripts/lib/agent-1c.$leaf.ps1")}
                    foreach($n in 1..20){$null=Update-ItlMemoryJson $Record {param($old) $old.count++;return $old}}
                } -ArgumentList $RepoRoot,$path
            }
            $done=$jobs|Wait-Job -Timeout 20
            @($done).Count | Should -Be 2
            foreach($job in $jobs){$null=Receive-Job $job -ErrorAction Stop;$job.State | Should -Be Completed}
            (Read-ItlMemoryJson $path).count | Should -Be 40
        }finally{$jobs|Stop-Job;$jobs|Remove-Job -Force}
    }
    It 'uses bounded UTF-8 REST transport on PS5 against an isolated wire fixture, not Cognee' {
        $ready=Join-Path $TestDrive 'wire-ready.txt'
        $job=Start-Job -ScriptBlock {
            param($Ready)
            $ErrorActionPreference='Stop'
            $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
            try {
                $listener.Start();[IO.File]::WriteAllText($Ready,[string]$listener.LocalEndpoint.Port)
                foreach($n in 1..5){
                    if($n -eq 4){continue} # consumed together with request 3
                    $peer=$listener.AcceptTcpClient();$peer.ReceiveTimeout=10000
                    try {
                        $stream=$peer.GetStream();$header=''
                        while(-not $header.EndsWith("`r`n`r`n")){$v=$stream.ReadByte();if($v -lt 0 -or $header.Length -gt 16000){throw 'fixture header'};$header+=[char]$v}
                        $length=[int]([regex]::Match($header,'(?i)Content-Length: (\d+)')).Groups[1].Value
                        if($header -match '(?i)Expect: 100-continue'){$ack=[Text.Encoding]::ASCII.GetBytes("HTTP/1.1 100 Continue`r`n`r`n");$stream.Write($ack,0,$ack.Length)}
                        $body=[byte[]]::new($length);$offset=0
                        while($offset -lt $length){$read=$stream.Read($body,$offset,$length-$offset);if(-not $read){throw 'fixture EOF'};$offset+=$read}
                        if($n -le 2){
                            $json=@{echo=[Text.Encoding]::UTF8.GetString($body);bearerPresent=($header -match '(?i)Authorization: Bearer harmless-fixture-token');authorizationPresent=($header -match '(?im)^Authorization:');apiKeyPresent=($header -match '(?im)^X-Api-Key: harmless-fixture-api-key\r?$')}|ConvertTo-Json -Compress
                            $bytes=[Text.Encoding]::UTF8.GetBytes($json)
                            $prefix=[Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: application/json; charset=utf-8`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`n`r`n")
                            $stream.Write($prefix,0,$prefix.Length);$stream.Write($bytes,0,$bytes.Length)
                        }elseif($n -eq 3){
                            # Neither deferred GET can finish until the second is in flight.
                            $secondPeer=$listener.AcceptTcpClient();$secondPeer.ReceiveTimeout=10000
                            try{
                                $secondStream=$secondPeer.GetStream();$secondHeader=''
                                while(-not $secondHeader.EndsWith("`r`n`r`n")){$v=$secondStream.ReadByte();if($v -lt 0){throw 'second fixture EOF'};$secondHeader+=[char]$v}
                                foreach($pair in @(@{stream=$secondStream;sequence=4},@{stream=$stream;sequence=3})){
                                    $bytes=[Text.Encoding]::UTF8.GetBytes((@{sequence=$pair.sequence}|ConvertTo-Json -Compress))
                                    $prefix=[Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`n`r`n")
                                    $pair.stream.Write($prefix,0,$prefix.Length);$pair.stream.Write($bytes,0,$bytes.Length)
                                }
                            }finally{$secondPeer.Dispose()}
                        }else{while($stream.ReadByte() -ge 0){};return 'bounded-peer-closed'}
                    }finally{$peer.Dispose()}
                }
            }finally{$listener.Stop()}
        } -ArgumentList $ready
        try {
            $until=[DateTime]::UtcNow.AddSeconds(10)
            while(-not (Test-Path -LiteralPath $ready) -and [DateTime]::UtcNow -lt $until){Start-Sleep -Milliseconds 25}
            Test-Path -LiteralPath $ready | Should -BeTrue
            $provider=@{url=('http://127.0.0.1:'+([IO.File]::ReadAllText($ready))+'/');credentialFile=(Join-Path $env:VIBECODING1C_MCP_LOCAL_HOME 'credential.json')}
            Write-Utf8TextAtomic $provider.credentialFile '{"accessToken":"harmless-fixture-token"}'
            $result=& $NativeMemoryHttp $provider POST '/api/v1/remember' @{text='Точный UTF-8 путь с пробелом'} ([DateTime]::UtcNow.AddSeconds(5))
            $result.status | Should -Be 200
            ($result.body.echo|ConvertFrom-Json).text | Should -Be 'Точный UTF-8 путь с пробелом'
            $result.body.bearerPresent | Should -BeTrue
            $result.body.apiKeyPresent | Should -BeFalse
            Write-Utf8TextAtomic $provider.credentialFile '{"apiKey":"harmless-fixture-api-key","accessToken":"harmless-fixture-token"}'
            $keyResult=& $NativeMemoryHttp $provider POST '/api/v1/remember' @{text='Тот же путь с ключом API'} ([DateTime]::UtcNow.AddSeconds(5))
            $keyResult.status | Should -Be 200
            ($keyResult.body.echo|ConvertFrom-Json).text | Should -Be 'Тот же путь с ключом API'
            $keyResult.body.apiKeyPresent | Should -BeTrue
            $keyResult.body.authorizationPresent | Should -BeFalse
            $firstPending=& $NativeMemoryHttp $provider GET '/api/v1/raw/one' -DeadlineUtc ([DateTime]::UtcNow.AddSeconds(5)) -Raw -Defer
            $secondPending=& $NativeMemoryHttp $provider GET '/api/v1/raw/two' -DeadlineUtc ([DateTime]::UtcNow.AddSeconds(5)) -Raw -Defer
            try{
                $firstCurrent=Complete-ItlMemoryHttp $firstPending
                $secondCurrent=Complete-ItlMemoryHttp $secondPending
                ($firstCurrent.body|ConvertFrom-Json).sequence | Should -Be 3
                ($secondCurrent.body|ConvertFrom-Json).sequence | Should -Be 4
            }finally{Close-ItlMemoryHttp $firstPending;Close-ItlMemoryHttp $secondPending}
            {& $NativeMemoryHttp $provider POST '/api/v1/recall' @{query='test'} ([DateTime]::UtcNow.AddMilliseconds(250))} | Should -Throw '*MEMORY_TRANSPORT_UNCONFIRMED*'
            $null=$job|Wait-Job -Timeout 10
            $job.State | Should -Be Completed
            (Receive-Job $job -ErrorAction Stop) | Should -Be bounded-peer-closed
        }finally{$job|Stop-Job;$job|Remove-Job -Force}
    }
    It 'serves UTF-8 local status and compact tools in a real PS5 stdio process' {
        $policy=Install-MemoryPolicyFixture $b.projectRoot
        $b.policyProofs=@{cursor=(Get-ItlMemoryPolicyProof $policy $b.projectRoot)}
        $null=Update-ItlMemoryJson (Get-ItlMemoryPath binding $b.projectRoot) {param($old) return $b}
        {Invoke-ItlMemoryRemember $b 'Путь с пробелом и кириллицей' '' 'unicode'} | Should -Throw '*MEMORY_DESTINATION_REQUIRED*'
        $inputLines=@(
            @{jsonrpc='2.0';id=1;method='initialize'},
            @{jsonrpc='2.0';id=2;method='tools/list'},
            @{jsonrpc='2.0';id=3;method='tools/call';params=@{name='memory_status';arguments=@{local_only=$true;note_id='unicode'}}}
        )|ForEach-Object {ConvertTo-Json -InputObject $_ -Depth 8 -Compress}
        $wrapper=Join-Path $b.projectRoot 'Проверка stdio.ps1'
        $frontend=Join-Path $RepoRoot '.agents/skills/1c-workflow/scripts/cognee-memory-mcp.ps1'
        $body=@'
param($InputJson,$Frontend,$Binding)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
. (Join-Path (Split-Path $Frontend) 'lib/agent-1c.core.ps1')
. (Join-Path (Split-Path $Frontend) 'lib/agent-1c.vanessa.ps1')
$psi=[Diagnostics.ProcessStartInfo]::new()
$psi.FileName='powershell.exe';$psi.Arguments=Join-NativeCommandLineArguments @('-NoProfile','-NonInteractive','-File',$Frontend,'-BindingPath',$Binding,'-Client','cursor')
$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
$psi.RedirectStandardInput=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
$psi.StandardOutputEncoding=[Text.UTF8Encoding]::new($false);$psi.StandardErrorEncoding=[Text.UTF8Encoding]::new($false)
$p=[Diagnostics.Process]::new();$p.StartInfo=$psi
try {
    [void]$p.Start();$out=$p.StandardOutput.ReadToEndAsync();$err=$p.StandardError.ReadToEndAsync()
    $bytes=[Convert]::FromBase64String($InputJson)
    $p.StandardInput.BaseStream.Write($bytes,0,$bytes.Length);$p.StandardInput.Close()
    if(-not $p.WaitForExit(10000)){throw 'fixture child timeout'}
    [Console]::Write($out.GetAwaiter().GetResult());[Console]::Error.Write($err.GetAwaiter().GetResult())
    exit $p.ExitCode
}finally{if(-not $p.HasExited){$null=Stop-NativeProcessForSafety -Process $p};$p.Dispose()}
'@
        [IO.File]::WriteAllText($wrapper,$body,[Text.UTF8Encoding]::new($true))
        $script:Agent1cCoreRoot=Join-Path $RepoRoot '.agents/skills/1c-workflow/scripts/lib'
        $native=Invoke-ItlNativeProcessCapture -FilePath powershell.exe -Arguments @('-NoProfile','-NonInteractive','-File',$wrapper,'-InputJson',[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($inputLines -join "`n")+"`n")),'-Frontend',$frontend,'-Binding',(Get-ItlMemoryPath binding $b.projectRoot)) -WorkingDirectory $b.projectRoot -TimeoutSeconds 20
        $native.exitCode | Should -Be 0 -Because $native.stderr
        Write-Utf8TextAtomic (Join-Path $RepoRoot 'build/test-results/g4/stdio-windows.jsonl') $native.stdout
        $lines=@($native.stdout.Trim() -split "`r?`n"|ForEach-Object {$_|ConvertFrom-Json})
        $lines.Count | Should -Be 3
        $lines[1].result.tools.Count | Should -Be 4
        ($lines[2].result.content[0].text|ConvertFrom-Json).pending[0].fact | Should -Be 'Путь с пробелом и кириллицей'
    }
}
