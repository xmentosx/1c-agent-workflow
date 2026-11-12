Describe 'Scoped Cognee source contract (G4, no native G5)' {
    BeforeAll {
        $RepoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
        foreach($leaf in @('runtime-values','core','vanessa','vibecoding1c-mcp','product-catalog','memory','memory-context','lifecycle')){
            . (Join-Path $RepoRoot ".agents/skills/1c-workflow/scripts/lib/agent-1c.$leaf.ps1")
        }
        $savedHome=$env:VIBECODING1C_MCP_LOCAL_HOME
        $NativeMemoryHttp=${function:Invoke-ItlMemoryHttp}
        $NativeMachineGuid=${function:Get-ItlMemoryMachineGuid}
        function New-MemoryFixture {
            # -KeepBackend adds a second working copy on the same fixture server
            # and private home; -MainRoot makes it a branch copy of that main
            # copy; -LazyShared leaves its workspace/host datasets unmapped.
            param([string]$ProjectId='customer',[string]$MainRoot='',[switch]$KeepBackend,[switch]$LazyShared)
            $script:ProjectRoot=Join-Path $TestDrive ('Проект с пробелом '+[guid]::NewGuid().ToString('N'))
            [void][IO.Directory]::CreateDirectory($script:ProjectRoot)
            if(-not $KeepBackend){$env:VIBECODING1C_MCP_LOCAL_HOME=Join-Path $TestDrive ('Личное состояние '+[guid]::NewGuid().ToString('N'))}
            $identity=Get-ItlMemoryWorkspace $script:ProjectRoot 'ordinary-user' -MainRoot $MainRoot
            $cycle=[guid]::NewGuid().ToString('N')
            $context=@{projectId=$ProjectId;productId='prof';catalogRevision='published-sha';knowledgeHash='knowledge';projectContext=@{customized=$true};knowledgeContext=@{productReadCandidates=@('corp');knowledgeAreas=@();conditionValues=@{};productVersion='5.0'}}
            $b=[ordered]@{schemaVersion=1;capability='scoped-cognee-memory-v1';mode='enabled';bindingId='b1';projectRoot=$script:ProjectRoot;cycleStatePath=(Join-Path $script:ProjectRoot 'cycle.json');appliedPath=(Join-Path $script:ProjectRoot 'applied.json');cycleId=$cycle;registryContextHash=(Get-ItlCatalogHash $context);context=$context;identity=$identity;provider=@{instanceId='fixture';organizationId='org';datasets=@()};memoryProjection=@{knowledgeAreas=@{};composition=@();snapshot=@{relations=@{relations=@()}}}}
            if(-not $KeepBackend){
                $script:Calls=[Collections.Generic.List[object]]::new();$script:Originals=@{};$script:BodyLoss=$false
                # Fixture server state: document name, dataset and change order
                # per data ID; shared dataset IDs per label; native dataset list.
                $script:Names=@{};$script:DocDatasets=@{};$script:Updated=@{};$script:Clock=0;$script:NativeDatasets=@();$script:SharedDatasetIds=@{}
            }
            $private=@(Get-ItlMemoryPrivateScopes $b|Where-Object {-not $LazyShared -or $_.scopeKind -notin @('workspace','host')})
            $scopes=$private+@(@{scopeKind='product';scopeId='corp';label='itl_product_corp'},@{scopeKind='project';scopeId=$ProjectId;label=('itl_project_'+$ProjectId)},@{scopeKind='organization';scopeId='org';label='itl_org_org'})
            foreach($s in $scopes){
                # One native dataset per label, whichever copy maps it.
                if(-not $script:SharedDatasetIds.ContainsKey($s.label)){$script:SharedDatasetIds[$s.label]=[guid]::NewGuid().ToString()}
                $s.datasetId=$script:SharedDatasetIds[$s.label];$s.ownerId='ordinary-user';$s.permissions=@('read','write');$s.admitted=$true
            }
            $b.provider.datasets=$scopes
            Write-Utf8TextAtomic $b.cycleStatePath (@{memoryCycle=@{current=$cycle;reserved='';workspaceId=$identity.workspaceId};mainWorktreePath=$MainRoot}|ConvertTo-Json)
            Write-Utf8TextAtomic $b.appliedPath (@{context=$context;contextHash=$b.registryContextHash}|ConvertTo-Json -Depth 20)
            $null=Update-ItlMemoryJson (Get-ItlMemoryPath binding $b.projectRoot) {param($old) return $b}
            return $b
        }
        function Add-FixtureNote {
            # Places one stored note on the fixture server without a remember
            # call. -LegacyName stores it as a copy on the previous workflow
            # does after an update: under the constant name "memory".
            param($Dataset,[string]$NoteId,[string]$Fact,[string]$Status='verified',[string]$Title='',[string]$Area='',[switch]$Standing,[switch]$LegacyName)
            $note=[ordered]@{format='itl-memory-v1';noteId=$NoteId;fact=$Fact;scope=@{kind=$Dataset.scopeKind;id=$Dataset.scopeId};date='2026-11-11T10:00:00Z';status=$Status;origin=@{projectId='customer';workspaceId='other-copy';cycleId='other-cycle';source='';revision=''};applicability=@{};evidence=@(@{source='user';reference='chat 2026-11-11'})}
            if($Area){$note.applicability=@{knowledgeArea=$Area}}
            if($Standing){$note['standing']=$true}
            if($Title){$note['title']=$Title}
            $id=[guid]::NewGuid().ToString()
            $script:Originals[$id]=ConvertTo-Json -InputObject $note -Depth 20 -Compress
            $script:Names[$id]=if($LegacyName){'memory'}else{(Get-ItlMemoryDocumentName $note) -replace '\.txt$',''}
            $script:DocDatasets[$id]=$Dataset.datasetId;$script:Updated[$id]=(++$script:Clock)
            return $id
        }
        function Get-ScopeDataset {param($b,[string]$Kind) @($b.provider.datasets|Where-Object scopeKind -EQ $Kind)[0]}
        $MemoryFrontend=Join-Path $RepoRoot '.agents/skills/1c-workflow/scripts/cognee-memory-mcp.ps1'
        function Start-MemoryServer {
            # The real stdio server of one working copy, kept open between
            # requests as a native client keeps it.
            param([string]$BindingPath)
            $psi=[Diagnostics.ProcessStartInfo]::new()
            $psi.FileName='powershell.exe';$psi.Arguments=Join-NativeCommandLineArguments @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$MemoryFrontend,'-BindingPath',$BindingPath,'-Client','cursor')
            $psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
            $psi.RedirectStandardInput=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
            $psi.StandardOutputEncoding=[Text.UTF8Encoding]::new($false);$psi.StandardErrorEncoding=[Text.UTF8Encoding]::new($false)
            $process=[Diagnostics.Process]::new();$process.StartInfo=$psi;[void]$process.Start()
            return @{process=$process;stderr=$process.StandardError.ReadToEndAsync();id=0}
        }
        function Invoke-MemoryServerCall {
            # Returns the tool result, or the JSON-RPC error object.
            param($Server,[string]$Tool,[hashtable]$Arguments=@{})
            $Server.id++
            $line=ConvertTo-Json -InputObject @{jsonrpc='2.0';id=$Server.id;method='tools/call';params=@{name=$Tool;arguments=$Arguments}} -Depth 8 -Compress
            $wire=[Text.Encoding]::UTF8.GetBytes($line+"`n")
            $Server.process.StandardInput.BaseStream.Write($wire,0,$wire.Length);$Server.process.StandardInput.BaseStream.Flush()
            $read=$Server.process.StandardOutput.ReadLineAsync()
            if(-not $read.Wait(30000)){throw 'memory server did not answer in 30 seconds'}
            $answer=$read.GetAwaiter().GetResult()
            if($null -eq $answer){throw ('memory server closed stdio: '+$Server.stderr.GetAwaiter().GetResult())}
            $message=$answer|ConvertFrom-Json
            if($message.PSObject.Properties['error']){return $message.error}
            return ($message.result.content[0].text|ConvertFrom-Json)
        }
        function Stop-MemoryServer {
            param($Server)
            # Returns what the server wrote to stderr: its unexpected causes.
            try{
                $Server.process.StandardInput.Close()
                if(-not $Server.process.WaitForExit(10000)){$null=Stop-NativeProcessForSafety -Process $Server.process}
                if($Server.stderr.Wait(5000)){return [string]$Server.stderr.GetAwaiter().GetResult()}
                return ''
            }finally{$Server.process.Dispose()}
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
        function Mock-IndexedFixtureNotes {
            Mock Invoke-ItlMemoryHttp {
                $script:Calls.Add(@{method=$Method;path=$Path;body=$Body})
                $hits=@($script:DocDatasets.Keys|Where-Object {$Body.dataset_ids -contains $script:DocDatasets[$_]}|ForEach-Object {
                    @{dataset_id=$script:DocDatasets[$_];metadata=@{data_id=$_}}
                })
                return @{status=200;body=$hits}
            } -ParameterFilter {$Path -eq '/api/v1/recall'}
        }
        function Get-ProjectDataset {param($b) @($b.provider.datasets|Where-Object scopeKind -EQ 'project')[0]}
    }
    BeforeEach {
        # A fixed machine identity: the host scope must not depend on the runner.
        Mock Get-ItlMemoryMachineGuid {'fixture-machine-guid'}
        Mock Get-ItlMemoryHostName {'FIXTURE-HOST'}
        $b=New-MemoryFixture
        # The fixture repeats the qualified Cognee 1.6.5 behaviour (evidence
        # metadata-qualification-2026-11-11): a note is one uploaded file, the
        # listed name is its file name without extension and follows every
        # update, metadata never changes, a second document of the same name is
        # 409 on creation only, POST /datasets returns the existing dataset.
        Mock Invoke-ItlMemoryHttp {
            param($Provider,$Method,$Path,$Body,$DeadlineUtc,$ContentType,$Raw)
            $script:Calls.Add(@{method=$Method;path=$Path;body=$Body})
            if($Path -eq '/api/v1/users/me'){return @{status=200;body=@{id='ordinary-user';is_superuser=$false}}}
            if($Path -eq '/api/v1/datasets' -and $Method -eq 'GET'){
                $listed=@($script:NativeDatasets)
                return @{status=200;body=$(if($Raw){ConvertTo-Json -InputObject $listed -Compress}else{,$listed})}
            }
            if($Path -eq '/api/v1/datasets' -and $Method -eq 'POST'){
                $existing=@($script:NativeDatasets|Where-Object {$_.name -ceq $Body.name})
                if(-not $existing.Count){$existing=@(@{name=$Body.name;id=[guid]::NewGuid().ToString();ownerId='ordinary-user'});$script:NativeDatasets+=$existing}
                return @{status=200;body=$existing[0]}
            }
            $file=[regex]::Match([string]$Body,'(?s)name="data"; filename="([^"]*)"\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n(.*?)\r\n--itl_')
            if($Path -eq '/api/v1/remember'){
                $ContentType | Should -Match '^multipart/form-data; boundary=itl_'
                $datasetId=[regex]::Match($Body,'name="datasetId"\r\n\r\n([^\r]*)\r\n').Groups[1].Value
                $name=$file.Groups[1].Value -replace '\.txt$',''
                $taken=@($script:Names.Keys|Where-Object {$script:Names[$_] -ceq $name -and $script:DocDatasets[$_] -ceq $datasetId})
                if($taken.Count){return @{status=409;body=@{detail='Document already exists; use the update endpoint';data_id=$taken[0]}}}
                $id=[guid]::NewGuid().ToString()
                $script:Originals[$id]=$file.Groups[2].Value;$script:Names[$id]=$name;$script:DocDatasets[$id]=$datasetId;$script:Updated[$id]=(++$script:Clock)
                if($script:BodyLoss){throw 'MEMORY_TRANSPORT_UNCONFIRMED'}
                return @{status=200;body=@{items=@(@{id=$id})}}
            }
            if($Path -match '/data/([^/]+)/raw$'){
                $id=$Matches[1];if($script:Originals.ContainsKey($id)){return @{status=200;body=$script:Originals[$id]}}
                return @{status=404;body=''}
            }
            if($Path -match '/datasets/([^/]+)/data\?limit=1000$'){
                # A document a test stored without a dataset is listed everywhere;
                # without a name it carries the previous constant name.
                $listed=$Matches[1]
                return @{status=200;body=@($script:Originals.Keys|Where-Object {-not $script:DocDatasets.ContainsKey($_) -or $script:DocDatasets[$_] -ceq $listed}|ForEach-Object {
                    @{id=$_;name=$(if($script:Names.ContainsKey($_)){$script:Names[$_]}else{'memory'});updatedAt=('2026-11-11T10:{0:00}:{1:00}' -f [Math]::Floor([int]$script:Updated[$_]/60),([int]$script:Updated[$_]%60))}
                })}
            }
            if($Method -eq 'PATCH'){
                $id=([regex]::Match($Path,'data_id=([^&]+)')).Groups[1].Value
                $script:Originals[$id]=$file.Groups[2].Value;$script:Names[$id]=$file.Groups[1].Value -replace '\.txt$','';$script:Updated[$id]=(++$script:Clock)
                return @{status=200;body=@{status='incremental'}}
            }
            if($Path -eq '/api/v1/recall'){return @{status=200;body=@()}}
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

    It 'resolves seven areas, rejects implicit writes and does not infer a product home' {
        # A real applied G3 record retains client compatibility/proof bytes;
        # it is larger than a memory note without enlarging the tool context.
        $applied=Read-ItlMemoryJson $b.appliedPath
        $applied.compatibilityBaseline=@{clientSettings=('ж' * 135600)}
        Write-Utf8TextAtomic $b.appliedPath ($applied|ConvertTo-Json -Depth 20)
        (Get-Item -LiteralPath $b.appliedPath).Length | Should -BeGreaterThan 262144
        $appliedHash=(Get-FileHash -LiteralPath $b.appliedPath -Algorithm SHA256).Hash
        {Read-ItlMemoryJson $b.appliedPath} | Should -Throw '*MEMORY_RECORD_TOO_LARGE: kind=record*'
        {Assert-ItlMemoryBindingCurrent $b} | Should -Not -Throw
        {Sync-ItlMemoryContext} | Should -Not -Throw
        @(Get-ItlMemoryScopes $b read).Count | Should -Be 7
        @(Get-ItlMemoryScopes $b read|ForEach-Object {$_.scopeKind}|Sort-Object) | Should -Be @('host','organization','product','project','taskCycle','workplace','workspace')
        $persisted=Read-ItlMemoryJson (Get-ItlMemoryPath binding $b.projectRoot)
        $local=Invoke-ItlMemoryStatus $persisted -LocalOnly
        [Text.Encoding]::UTF8.GetByteCount(($local|ConvertTo-Json -Depth 20 -Compress)) | Should -BeLessThan 8192
        (Get-FileHash -LiteralPath $b.appliedPath -Algorithm SHA256).Hash | Should -BeExactly $appliedHash
        $destinations=@($local.destinations)
        @($destinations|Where-Object {-not $_.label -or -not $_.scopeKind -or -not $_.scopeId}).Count | Should -Be 0
        @($destinations|Where-Object scopeKind -EQ project)[0].label | Should -BeExactly 'itl_project_customer'
        @($destinations|Where-Object scopeKind -EQ organization)[0].label | Should -BeExactly 'itl_org_org'
        $local.Contains('writeGuidance') | Should -BeFalse
        {Get-ItlMemoryScopes $b write} | Should -Throw '*MEMORY_DESTINATION_REQUIRED*'
        {Get-ItlMemoryScopes $b write 'itl_product_corp' 'planning'} | Should -Throw '*MEMORY_DESTINATION_REQUIRED*'
        $b.context.knowledgeContext.knowledgeAreas=@(@{areaId='planning';status='applicable';memoryHomeProductId='corp'})
        @(Get-ItlMemoryScopes $b write 'itl_product_corp' 'planning').Count | Should -Be 1
        $b.provider.datasets[0].scopeId='old-cycle'
        @(Get-ItlMemoryScopes $b read).Count | Should -Be 6
    }
    It 'keeps workspace/workplace stable without allocating datasets' {
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
        @($script:Calls|Where-Object method -EQ 'PATCH')[0].body | Should -Match 'Content-Disposition: form-data; name="data"; filename="verified~~Stable fact~[0-9a-f]{8}\.txt"'
        @($script:Calls|Where-Object path -EQ '/api/v1/remember').Count | Should -Be 1
    }
    It 'lists own durable candidates until the same note is verified with evidence' {
        # recall drops candidates; a 2026-11-08 pilot left a user decision as
        # an unreachable candidate. Local status is the writer's way back.
        $hypothesis=Invoke-ItlMemoryRemember $b 'Гипотеза о причине' 'itl_project_customer' 'hypothesis'
        $hypothesis.state | Should -Be 'durable'
        $legacy=Invoke-ItlMemoryRemember $b 'Старая квитанция' 'itl_project_customer' 'legacy-candidate'
        $legacyPath=Get-ItlMemoryPath receipt (Get-ItlMemoryRecordKey $b (Get-ProjectDataset $b).datasetId 'legacy-candidate')
        $null=Update-ItlMemoryJson $legacyPath {param($old) [ordered]@{schemaVersion=1;state=$old.state;noteId=$old.noteId;datasetId=$old.datasetId;dataId=$old.dataId;contentHash=$old.contentHash}}
        $null=Invoke-ItlMemoryRemember $b 'Checked fact' 'itl_project_customer' 'checked' @{} @(@{source='user';reference='task confirmation'}) verified
        $local=Invoke-ItlMemoryStatus $b -LocalOnly
        @($local.candidates.noteId|Sort-Object) | Should -Be @('hypothesis','legacy-candidate')
        $card=@($local.candidates|Where-Object noteId -EQ 'hypothesis')[0]
        $card.fact | Should -BeExactly 'Гипотеза о причине'
        $card.dataId | Should -Be $hypothesis.dataId
        $card.dataset | Should -BeExactly 'itl_project_customer'
        @($local.candidates|Where-Object noteId -EQ 'legacy-candidate')[0].fact | Should -BeExactly 'Старая квитанция'
        $local.candidateAction | Should -Match 'status=verified and evidence'
        @($local.receipts|Where-Object noteId -EQ 'checked')[0].status | Should -Be 'verified'
        $verified=Invoke-ItlMemoryRemember $b 'Гипотеза о причине' 'itl_project_customer' 'hypothesis' @{} @(@{source='check';reference='passed /itl-check'}) verified -DataId $hypothesis.dataId
        $verified.state | Should -Be 'durable'
        $null=Invoke-ItlMemoryRetire $b 'itl_project_customer' 'legacy-candidate'
        $local=Invoke-ItlMemoryStatus $b -LocalOnly
        @($local.candidates).Count | Should -Be 0
        $local.Contains('candidateAction') | Should -BeFalse
        @($local.receipts|Where-Object noteId -EQ 'hypothesis')[0].status | Should -Be 'verified'
    }
    It 'retains a changed unresolved pending instead of overwriting its source' {
        $script:BodyLoss=$true
        $null=Invoke-ItlMemoryRemember $b 'First' 'itl_project_customer' 'pending'
        {Invoke-ItlMemoryRemember $b 'Second' 'itl_project_customer' 'pending'} | Should -Throw '*MEMORY_PENDING_CONFLICT*'
        {Invoke-ItlMemoryRemember $b 'First' 'itl_org_org' 'pending'} | Should -Throw '*MEMORY_DESTINATION_LOCKED*'
        (Invoke-ItlMemoryStatus $b -LocalOnly).pending[0].fact | Should -Be 'First'
        (Invoke-ItlMemoryStatus $b -LocalOnly).pending[0].sent | Should -BeTrue
        {Invoke-ItlMemoryRetire $b '' 'pending'} | Should -Throw '*MEMORY_ARGUMENT_REQUIRED*'
    }
    It 'completes or discards an unsent draft under its ID after a stale client rejection' {
        # Pilot 2026-11-08: a stale facade kept a candidate draft that could be
        # neither verified under its ID nor closed, so a second ID was needed.
        $stale=Read-ItlMemoryJson (Get-ItlMemoryPath binding $b.projectRoot);$stale.bindingId='old-client'
        $fact='Клиентский режим редактора плана — легаси'
        {Invoke-ItlMemoryRemember $stale $fact '' 'draft'} | Should -Throw '*MEMORY_STALE_CONTEXT*'
        $evidence=@(@{source='user';reference='task confirmation'})
        {Invoke-ItlMemoryRemember $stale $fact 'itl_project_customer' 'draft' @{} $evidence verified} | Should -Throw '*MEMORY_STALE_CONTEXT*'
        $script:Calls.Count | Should -Be 0
        $draft=(Invoke-ItlMemoryStatus $b -NoteId draft -LocalOnly).pending[0]
        $draft.sent | Should -BeFalse
        $draft.status | Should -Be 'verified'
        $draft.evidence[0].reference | Should -Be 'task confirmation'
        $r=Invoke-ItlMemoryRemember $b $fact 'itl_project_customer' 'draft' @{} $evidence verified
        $r.state | Should -Be 'durable'
        ($script:Originals[$r.dataId]|ConvertFrom-Json).status | Should -Be 'verified'
        @($script:Calls|Where-Object path -EQ '/api/v1/remember').Count | Should -Be 1
        @((Invoke-ItlMemoryStatus $b -LocalOnly).pending).Count | Should -Be 0
        $sourceRoot=Join-Path (Join-Path (Get-ItlMemoryHome) 'source') $b.identity.workspaceId
        $saved=Read-ItlMemoryJson (Join-Path $sourceRoot ((Get-ItlCatalogHash 'draft')+'.json'))
        $saved.intent.status | Should -Be 'verified'
        $saved.replacedIntents[0].status | Should -Be 'candidate'
        @($saved.replacedIntents).Count | Should -Be 1
        $saved.replacedIntents[0].datasetName | Should -Be ''

        {Invoke-ItlMemoryRemember $stale 'Заменённый черновик' '' 'replaced'} | Should -Throw '*MEMORY_STALE_CONTEXT*'
        {Invoke-ItlMemoryRetire $stale '' 'replaced'} | Should -Throw '*MEMORY_STALE_CONTEXT*'
        $calls=$script:Calls.Count
        (Invoke-ItlMemoryRetire $b '' 'replaced').state | Should -Be 'discarded-unsent'
        $script:Calls.Count | Should -Be $calls
        @((Invoke-ItlMemoryStatus $b -LocalOnly).pending).Count | Should -Be 0
        (Read-ItlMemoryJson (Join-Path $sourceRoot ((Get-ItlCatalogHash 'replaced')+'.discarded.json'))).intent.data | Should -Be 'Заменённый черновик'
        {Invoke-ItlMemoryRetire $b '' 'replaced'} | Should -Throw '*MEMORY_ARGUMENT_REQUIRED*'
        {Invoke-ItlMemoryRemember $stale 'Черновик с назначением' '' 'named'} | Should -Throw '*MEMORY_STALE_CONTEXT*'
        (Invoke-ItlMemoryRetire $b 'itl_project_customer' 'named').state | Should -Be 'discarded-unsent'
        @((Invoke-ItlMemoryStatus $b -LocalOnly).pending).Count | Should -Be 0
    }
    It 'lets only one of two competing unsent drafts reach the backend' {
        $script:RaceBinding=$b;$script:Race=$true
        Mock Assert-ItlMemoryBindingCurrent {
            if($script:Race){$script:Race=$false;$null=Invoke-ItlMemoryRemember $script:RaceBinding 'Победитель' 'itl_project_customer' 'race' @{} @(@{source='user'}) verified}
        }
        {Invoke-ItlMemoryRemember $b 'Проигравший' 'itl_project_customer' 'race'} | Should -Throw '*MEMORY_PENDING_CONFLICT*'
        @($script:Calls|Where-Object path -EQ '/api/v1/remember').Count | Should -Be 1
        @($script:Originals.Values|ForEach-Object {($_|ConvertFrom-Json).fact}) | Should -Be @('Победитель')
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
        $call[0].body.dataset_ids.Count | Should -Be 7
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
    It 'reports native warming-up status as empty memory, not partial coverage' {
        # Exact native shape observed from the qualified deployment while every
        # admitted dataset was still empty (2026-11-06 pilot branches).
        Mock Invoke-ItlMemoryHttp {param($Provider,$Method,$Path,$Body)
            $script:Calls.Add(@{method=$Method;path=$Path;body=$Body})
            @{status=200;body=@(@{source='system';status='memory_warming_up';text='Memory is still warming up: no knowledge graph data exists yet for the requested datasets.';datapoint_count=0;threshold=1;error_class=$null;error_message=$null})}
        } -ParameterFilter {$Path -eq '/api/v1/recall'}
        $empty=Invoke-ItlMemoryRecall $b 'PM5 задачи пакетная выдача'
        @($empty.cards).Count | Should -Be 0
        $empty.coverage | Should -BeExactly empty
        $empty.backendStatus | Should -BeExactly memory_warming_up
        $empty.sourceLookups | Should -Be 0
        @($script:Calls|Where-Object path -Like '*/raw').Count | Should -Be 0

        # An unknown system status stays conservative.
        Mock Invoke-ItlMemoryHttp {param($Provider,$Method,$Path,$Body)
            @{status=200;body=@(@{source='system';status='something_else';datapoint_count=0})}
        } -ParameterFilter {$Path -eq '/api/v1/recall'}
        (Invoke-ItlMemoryRecall $b query).coverage | Should -BeExactly partial
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
        $qwen=Get-ItlCatalogField $contract 'additionalQualifiedProfiles' @()
        @($qwen).Count | Should -Be 1
        $qwen[0].embeddingModel | Should -Be 'qwen/qwen3-embedding-8b'
        $qwen[0].embeddingDimensions | Should -Be 4096
        $nativeProofPath=Join-Path $RepoRoot $qwen[0].qualificationResultPath
        (Get-FileHash -LiteralPath $nativeProofPath -Algorithm SHA256).Hash.ToLowerInvariant() | Should -BeExactly $qwen[0].qualificationResultSha256
        $nativeProof=Read-ItlMemoryJson $nativeProofPath
        $nativeProof.nativeCompletedOriginals | Should -Be 50
        $nativeProof.embeddingDimensions | Should -Be 4096
        $nativeProof.releaseAdmission | Should -BeFalse
        $b.provider.profile=$qwen[0].profile;$b.provider.qualificationResultSha256=$qwen[0].qualificationResultSha256
        {Assert-ItlMemoryProvider $b.provider $b.projectRoot} | Should -Not -Throw
        $b.provider.profile=$contract.profile
        {Assert-ItlMemoryProvider $b.provider $b.projectRoot} | Should -Throw '*MEMORY_PROFILE_UNQUALIFIED*'
        $b.provider.profile=$qwen[0].profile;$b.provider.qualificationResultSha256=$contract.qualificationResultSha256
        {Assert-ItlMemoryProvider $b.provider $b.projectRoot} | Should -Throw '*MEMORY_PROFILE_UNQUALIFIED*'
        $b.provider.profile='unqualified-provider';$b.provider.qualificationResultSha256=$qwen[0].qualificationResultSha256
        {Assert-ItlMemoryProvider $b.provider $b.projectRoot} | Should -Throw '*MEMORY_PROFILE_UNQUALIFIED*'
        $b.provider.profile=$contract.profile;$b.provider.qualificationResultSha256=$contract.qualificationResultSha256
        $b.provider.toolPolicy='INVALID'
        {Assert-ItlMemoryPrincipal $b ([DateTime]::UtcNow.AddSeconds(2))} | Should -Throw '*MEMORY_TOOL_POLICY_INVALID*'
        $b.provider.toolPolicy='OFF'
        {Assert-ItlMemoryPrincipal $b ([DateTime]::UtcNow.AddSeconds(2))} | Should -Throw '*MEMORY_TOOL_OFF*'
        $script:Calls.Count | Should -Be 0
        $b.provider.toolPolicy='auto'
        $b.provider.datasets[0].admitted=$false
        {Assert-ItlMemoryProvider $b.provider $b.projectRoot} | Should -Not -Throw
        @(Get-ItlMemoryScopes $b read).Count | Should -Be 6
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
        (Read-ItlMemoryJson (Get-ItlMemoryPath binding $b.projectRoot)).provider.datasets.Count | Should -Be 7
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

        # Repeating enable with changed connection settings updates the same
        # binding in place: a running server follows it without a reload.
        $firstBinding=Read-ItlMemoryJson (Get-ItlMemoryPath binding $b.projectRoot)
        $firstBinding.identity.localProjectId | Should -BeExactly $firstBinding.identity.workspaceId
        $changedSettings=Read-ItlMemoryJson $settings;$changedSettings.toolPolicy='required'
        Write-Utf8TextAtomic $settings ($changedSettings|ConvertTo-Json -Depth 30)
        $null=Invoke-ItlMemorySetup enable -Client cursor -SettingsPath $settings -PolicyPath $policy
        $updatedBinding=Read-ItlMemoryJson (Get-ItlMemoryPath binding $b.projectRoot)
        $updatedBinding.settingsHash | Should -Not -Be $firstBinding.settingsHash
        $updatedBinding.bindingId | Should -BeExactly $firstBinding.bindingId

        $first.mode | Should -Be configured
        $null=Invoke-ItlMemorySetup disable -Client cursor
        (Read-ItlMemoryJson (Get-ItlMemoryPath binding $b.projectRoot)).bindingId | Should -Not -Be $firstBinding.bindingId
        (Invoke-ItlMemorySetup auto -Client cursor -SettingsPath $settings -PolicyPath $policy).mode | Should -BeExactly disabled
        $second=Invoke-ItlMemorySetup enable -Client cursor -SettingsPath $settings -PolicyPath $policy
        $second.cycleId | Should -Be $first.cycleId
        $second.workspaceId | Should -Be $first.workspaceId
        (Read-ItlMemoryJson (Get-ItlMemoryPath binding $b.projectRoot)).bindingId | Should -Not -Be $firstBinding.bindingId
        (Get-FileHash -LiteralPath $rootMemory -Algorithm SHA256).Hash | Should -Be $originalHash
        Should -Invoke Update-DevBranchState -Times 1 -Exactly
        # One pinned snapshot per enable: the first, the in-place repeat, the re-enable.
        Should -Invoke Read-ItlProductCatalogSnapshot -Times 3 -Exactly
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
param($InputJson,$Frontend,$Binding,$InheritedPSModulePath)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
. (Join-Path (Split-Path $Frontend) 'lib/agent-1c.core.ps1')
. (Join-Path (Split-Path $Frontend) 'lib/agent-1c.vanessa.ps1')
$psi=[Diagnostics.ProcessStartInfo]::new()
$psi.FileName='powershell.exe';$psi.Arguments=Join-NativeCommandLineArguments @('-NoProfile','-NonInteractive','-File',$Frontend,'-BindingPath',$Binding,'-Client','cursor')
$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
$psi.EnvironmentVariables['PSModulePath']=$InheritedPSModulePath
$psi.RedirectStandardInput=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
$psi.StandardOutputEncoding=[Text.UTF8Encoding]::new($false);$psi.StandardErrorEncoding=[Text.UTF8Encoding]::new($false)
$p=[Diagnostics.Process]::new();$p.StartInfo=$psi
try {
    [void]$p.Start();$err=$p.StandardError.ReadToEndAsync();$clock=[Diagnostics.Stopwatch]::StartNew()
    $bytes=[Convert]::FromBase64String($InputJson)
    # Keep stdio open between requests, as the native client does. Retain the
    # same three messages, Unicode path and ten-second child budget.
    $lines=([Text.UTF8Encoding]::new($false,$true)).GetString($bytes).TrimEnd("`r","`n") -split "`r?`n"
    $answers=[Collections.Generic.List[string]]::new()
    foreach($line in $lines){
        $wire=[Text.Encoding]::UTF8.GetBytes($line+"`n")
        $p.StandardInput.BaseStream.Write($wire,0,$wire.Length);$p.StandardInput.BaseStream.Flush()
        $read=$p.StandardOutput.ReadLineAsync()
        $remaining=[Math]::Max(1,10000-[int]$clock.ElapsedMilliseconds)
        if(-not $read.Wait($remaining)){throw 'fixture child timeout'}
        $answer=$read.GetAwaiter().GetResult();if($null -eq $answer){throw 'fixture child closed stdio'}
        $answers.Add($answer)
    }
    $p.StandardInput.Close()
    if(-not $p.WaitForExit([Math]::Max(1,10000-[int]$clock.ElapsedMilliseconds))){throw 'fixture child timeout'}
    [Console]::Write(($answers -join "`n")+"`n");[Console]::Error.Write($err.GetAwaiter().GetResult())
    exit $p.ExitCode
}finally{if(-not $p.HasExited){$null=Stop-NativeProcessForSafety -Process $p};$p.Dispose()}
'@
        [IO.File]::WriteAllText($wrapper,$body,[Text.UTF8Encoding]::new($true))
        $script:Agent1cCoreRoot=Join-Path $RepoRoot '.agents/skills/1c-workflow/scripts/lib'
        $native=Invoke-ItlNativeProcessCapture -FilePath powershell.exe -Arguments @('-NoProfile','-NonInteractive','-File',$wrapper,'-InputJson',[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($inputLines -join "`n")+"`n")),'-Frontend',$frontend,'-Binding',(Get-ItlMemoryPath binding $b.projectRoot),'-InheritedPSModulePath',$env:PSModulePath) -WorkingDirectory $b.projectRoot -TimeoutSeconds 20
        $native.exitCode | Should -Be 0 -Because $native.stderr
        Write-Utf8TextAtomic (Join-Path $RepoRoot 'build/test-results/g4/stdio-windows.jsonl') $native.stdout
        $lines=@($native.stdout.Trim() -split "`r?`n"|ForEach-Object {$_|ConvertFrom-Json})
        $lines.Count | Should -Be 3
        $lines[1].result.tools.Count | Should -Be 4
        @($lines[1].result.tools|Where-Object name -EQ remember)[0].description | Should -Match 'status=verified.*with evidence.*candidate is only an unproven hypothesis and recall never returns it.*unsent pending draft'
        $retire=@($lines[1].result.tools|Where-Object name -EQ retire_note)[0]
        @($retire.inputSchema.required) | Should -Be @('note_id')
        $retire.description | Should -Match 'note_id alone discards an own unsent pending draft'
        ($lines[2].result.content[0].text|ConvertFrom-Json).pending[0].fact | Should -Be 'Путь с пробелом и кириллицей'
        $remember=@($lines[1].result.tools|Where-Object name -EQ remember)[0]
        @($remember.inputSchema.properties.status.enum) | Should -Be @('candidate','verified','standing')
        $remember.inputSchema.properties.title.maxLength | Should -Be 80
        $remember.description | Should -Match 'In the same turn after a user correction|Call in the same turn after a user correction'
        $remember.description | Should -Match 'source:"user",reference:"chat <date>"'
        $remember.description | Should -Match 'note_id and data_id from the recall card'
        @($lines[1].result.tools|Where-Object name -EQ recall)[0].description | Should -Match 'before designing a 1C change.*unfamiliar areas.*Omit datasets for the admitted union'
        @($lines[1].result.tools|Where-Object name -EQ memory_status)[0].description | Should -Match 'once at session start and after a contextChanged notice'
        $retire.description | Should -Match 'outdated or contradicts a checked source'
        $lines[0].result.instructions | Should -Match 'Seven logical areas'
        # R56 adds scope choice, readState and the retry continuation. The
        # always-loaded text grows 1,721 -> 2,205 bytes and tools/list grows
        # 2,955 -> 3,439 bytes. Keep examples and exact-read procedure on demand.
        $alwaysOn=(@($lines[1].result.tools|ForEach-Object {$_.description.Length})|Measure-Object -Sum).Sum+$lines[0].result.instructions.Length
        $alwaysOn | Should -BeLessOrEqual 2250
        $schemaBytes=[Text.Encoding]::UTF8.GetByteCount((ConvertTo-Json -InputObject $lines[1].result -Depth 20 -Compress))
        $schemaBytes | Should -BeLessOrEqual 3500
    }

    # improve-scoped-memory-adoption
    It 'tells a busy, an oversized and a damaged private record apart' {
        $path=Get-ItlMemoryPath continuation $b.identity.workspaceId
        $null=Update-ItlMemoryJson $path {param($old) return @{projectId=$b.context.projectId;cycleId=$b.cycleId;goal='цель задачи'}}
        # Another operation holds the record during the first attempt only.
        $script:Holder=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        Mock Start-Sleep {$script:Holder.Dispose()}
        try{(Invoke-ItlMemoryStatus $b -LocalOnly).continuation.goal | Should -Be 'цель задачи'}finally{$script:Holder.Dispose()}
        Should -Invoke Start-Sleep -Times 1 -Exactly
        # Held through every attempt: a transient code, not a damaged record.
        Mock Start-Sleep {}
        $script:Holder=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        try{{Invoke-ItlMemoryStatus $b -LocalOnly} | Should -Throw '*MEMORY_RECORD_BUSY: kind=continuation*repeat the same operation*'}finally{$script:Holder.Dispose()}
        Should -Invoke Start-Sleep -Times 3 -Exactly
        (Invoke-ItlMemoryStatus $b -LocalOnly).continuation.goal | Should -Be 'цель задачи'
        [IO.File]::WriteAllText($path,'{ "goal": ')
        {Invoke-ItlMemoryStatus $b -LocalOnly} | Should -Throw '*MEMORY_RECORD_INVALID: kind=continuation*'
        [IO.File]::WriteAllText($path,('{"goal":"'+('x'*270000)+'"}'))
        {Invoke-ItlMemoryStatus $b -LocalOnly} | Should -Throw '*MEMORY_RECORD_TOO_LARGE: kind=continuation*'
        Remove-Item -LiteralPath $path
        [IO.File]::WriteAllText($b.cycleStatePath,'not json')
        {Assert-ItlMemoryBindingCurrent $b} | Should -Throw '*MEMORY_RECORD_INVALID: kind=branch-state*'
    }
    It 'keys the workspace scope by the local project and keeps the branch-copy identity' {
        $main=$b.projectRoot
        $one=New-MemoryFixture -MainRoot $main -KeepBackend -LazyShared
        $two=New-MemoryFixture -MainRoot $main -KeepBackend -LazyShared
        $otherMain=Get-ItlMemoryWorkspace (Join-Path $TestDrive ('Другая основная копия '+[guid]::NewGuid().ToString('N'))) 'ordinary-user'
        $one.identity.workspaceId | Should -Not -Be $two.identity.workspaceId
        $one.identity.localProjectId | Should -BeExactly $b.identity.workspaceId
        $two.identity.localProjectId | Should -BeExactly $b.identity.workspaceId
        $otherMain.localProjectId | Should -BeExactly $otherMain.workspaceId
        $otherMain.localProjectId | Should -Not -Be $b.identity.workspaceId
        # The main copy keeps its dataset name; its branch copies share it.
        $workspaceLabel='itl_workspace_'+$b.identity.workspaceId
        foreach($copy in @($b,$one,$two)){@(Get-ItlMemoryPrivateScopes $copy|Where-Object scopeKind -EQ workspace)[0].label | Should -BeExactly $workspaceLabel}
        # Branch state, the task scope and pending stay keyed by the copy.
        {Assert-ItlMemoryBindingCurrent $one} | Should -Not -Throw
        @(Get-ItlMemoryPrivateScopes $one|Where-Object scopeKind -EQ taskCycle)[0].workspaceId | Should -BeExactly $one.identity.workspaceId
        {Invoke-ItlMemoryRemember $one 'Черновик первой ветки' '' 'draft-one'} | Should -Throw '*MEMORY_DESTINATION_REQUIRED*'
        @((Invoke-ItlMemoryStatus $one -LocalOnly).pending).Count | Should -Be 1
        @((Invoke-ItlMemoryStatus $two -LocalOnly).pending).Count | Should -Be 0
        # The first workspace note creates the one dataset; the other copy adopts it.
        $evidence=@(@{source='user';reference='chat 2026-11-11'})
        $saved=Invoke-ItlMemoryRemember $one 'Стенд локального проекта общий для веток.' $workspaceLabel 'shared-stand' @{} $evidence verified
        $saved.state | Should -Be durable
        $status=Invoke-ItlMemoryStatus $two
        $status.serverCoverage | Should -Be bounded
        @($status.index|Where-Object level -EQ workspace)[0].notes | Should -Be @('Стенд локального проекта общий для веток.')
        $second=Invoke-ItlMemoryRemember $two 'Вторая ветка видит тот же стенд.' $workspaceLabel 'second-copy' @{} $evidence verified
        $second.state | Should -Be durable
        $second.datasetId | Should -BeExactly $saved.datasetId
        @($script:Calls|Where-Object {$_.method -eq 'POST' -and $_.path -eq '/api/v1/datasets'}).Count | Should -Be 1
        @($script:NativeDatasets|Where-Object {$_.name -ceq $workspaceLabel}).Count | Should -Be 1
    }
    It 'extends a binding of the previous workflow in place and rotates its ID once' {
        $path=Get-ItlMemoryPath binding $b.projectRoot
        $null=Invoke-ItlMemorySetup checkpoint -Checkpoint @{goal='Задача до обновления';nextStep='следующий шаг'}
        $null=Update-ItlMemoryJson $path {param($current)
            $current.identity.Remove('localProjectId');$current.identity.Remove('hostId')
            $current.provider.datasets=@($current.provider.datasets|Where-Object scopeKind -NE host)
            return $current
        }
        $legacy=Read-ItlMemoryJson $path
        # Until its owner extends it, workspace and host are unavailable and
        # every other scope keeps working.
        @(Get-ItlMemoryScopes $legacy read|ForEach-Object {$_.scopeKind}|Sort-Object) | Should -Be @('organization','product','project','taskCycle','workplace')
        @(Get-ItlMemoryPrivateScopes $legacy|ForEach-Object {$_.scopeKind}) | Should -Be @('taskCycle','workplace')
        {Assert-ItlMemoryBindingCurrent $legacy} | Should -Not -Throw
        Sync-ItlMemoryContext
        $extended=Read-ItlMemoryJson $path
        $extended.bindingId | Should -Not -Be $legacy.bindingId
        $extended.schemaVersion | Should -Be 1
        $extended.cycleId | Should -BeExactly $legacy.cycleId
        $extended.identity.workspaceId | Should -BeExactly $legacy.identity.workspaceId
        $extended.identity.localProjectId | Should -BeExactly $legacy.identity.workspaceId
        $extended.identity.hostId | Should -BeExactly (Get-ItlMemoryHostId)
        @(Get-ItlMemoryScopes $extended read|ForEach-Object {$_.scopeKind}) | Should -Contain workspace
        # The unchanged-context path does not rotate again.
        Sync-ItlMemoryContext
        (Read-ItlMemoryJson $path).bindingId | Should -BeExactly $extended.bindingId
        # The update keeps the continuation of the current task cycle.
        (Invoke-ItlMemoryStatus $extended -LocalOnly).continuation.goal | Should -Be 'Задача до обновления'
        & {
            # The reader of the previous workflow: the one refusal that makes a
            # still-running old server reload, and a rolled-back helper that
            # reads the extended record while ignoring the new fields.
            . (Join-Path $RepoRoot 'tests/fixtures/scoped-memory/previous-reader.ps1')
            {Assert-ItlMemoryBindingCurrent $legacy} | Should -Throw '*MEMORY_STALE_CONTEXT*'
            {Assert-ItlMemoryBindingCurrent $extended} | Should -Not -Throw
            @(Get-ItlMemoryScopes $extended read|ForEach-Object {$_.scopeKind}|Sort-Object) | Should -Be @('organization','product','project','taskCycle','workplace','workspace')
        }
        # A branch copy is extended with the ID of its main copy, also through
        # the owner rewrite of the client configuration that update-workflow runs.
        $branch=New-MemoryFixture -MainRoot $b.projectRoot -KeepBackend
        $branchPath=Get-ItlMemoryPath binding $branch.projectRoot
        $null=Update-ItlMemoryJson $branchPath {param($current) $current.identity.Remove('localProjectId');$current.identity.Remove('hostId');return $current}
        Get-ItlMemoryClientEndpoint cursor | Should -BeNullOrEmpty
        $extendedBranch=Read-ItlMemoryJson $branchPath
        $extendedBranch.bindingId | Should -Not -Be 'b1'
        $extendedBranch.identity.localProjectId | Should -BeExactly $b.identity.workspaceId
        $extendedBranch.identity.workspaceId | Should -BeExactly $branch.identity.workspaceId
    }
    It 'keeps the binding ID across owner updates and issues a new one for a new cycle, project or product' {
        $path=Get-ItlMemoryPath binding $b.projectRoot
        # Registry knowledge or revision of the same project and product.
        $changed=ConvertTo-ItlCatalogCanonicalValue $b.context;$changed.catalogRevision='next-published-sha'
        Sync-ItlMemoryContext -Context $changed
        $current=Read-ItlMemoryJson $path
        $current.bindingId | Should -BeExactly 'b1'
        $current.context.catalogRevision | Should -BeExactly 'next-published-sha'
        $current.registryContextHash | Should -BeExactly (Get-ItlCatalogHash $changed)
        # Branch reset: a new task cycle.
        Write-Utf8TextAtomic $b.cycleStatePath (@{memoryCycle=@{current='next-cycle';reserved='';workspaceId=$b.identity.workspaceId};mainWorktreePath=''}|ConvertTo-Json)
        Sync-ItlMemoryContext -Context $changed
        $afterReset=Read-ItlMemoryJson $path
        $afterReset.bindingId | Should -Not -Be 'b1'
        $afterReset.cycleId | Should -BeExactly 'next-cycle'
        $project=ConvertTo-ItlCatalogCanonicalValue $changed;$project.projectId='other-customer'
        Sync-ItlMemoryContext -Context $project
        $afterProject=Read-ItlMemoryJson $path
        $afterProject.bindingId | Should -Not -Be $afterReset.bindingId
        $product=ConvertTo-ItlCatalogCanonicalValue $project;$product.productId='corp'
        Sync-ItlMemoryContext -Context $product
        $afterProduct=Read-ItlMemoryJson $path
        $afterProduct.bindingId | Should -Not -Be $afterProject.bindingId
        Sync-ItlMemoryContext -Context $product
        (Read-ItlMemoryJson $path).bindingId | Should -BeExactly $afterProduct.bindingId
    }
    It 'follows an updated binding of the same copy and refuses another copy, disabled memory and a reset' {
        $path=Get-ItlMemoryPath binding $b.projectRoot
        $held=Read-ItlMemoryJson $path
        $rewrite={param([scriptblock]$Change) $null=Update-ItlMemoryJson $path {param($current) & $Change $current;return $current};Read-ItlMemoryJson $path}
        # Policy acknowledgement or settings changed in place: no notice, and
        # recall runs on the fresh record without a client reload.
        $live=Resolve-ItlMemoryLiveBinding $held (& $rewrite {param($c) $c['settingsHash']='changed-settings'})
        $live.contextChanged | Should -BeNullOrEmpty
        $live.holdWrites | Should -BeFalse
        $live.binding.settingsHash | Should -BeExactly 'changed-settings'
        (Invoke-ItlMemoryRecall $live.binding 'запрос после обновления').coverage | Should -BeExactly bounded
        # A re-enabled or extended binding of the same cycle is followed silently for writes.
        $next=Resolve-ItlMemoryLiveBinding $held (& $rewrite {param($c) $c['bindingId']='b2'})
        $next.contextChanged.reason | Should -BeExactly binding
        $next.holdWrites | Should -BeFalse
        $held=$next.binding
        # A reset in progress is still refused.
        Write-Utf8TextAtomic $b.cycleStatePath (@{memoryCycle=@{current=$b.cycleId;reserved='next-cycle';workspaceId=$b.identity.workspaceId};resetStatus='resetting'}|ConvertTo-Json)
        {Resolve-ItlMemoryLiveBinding $held (& $rewrite {param($c) $c['bindingId']='b3'})} | Should -Throw '*MEMORY_STALE_CONTEXT*reset is in progress*'
        Write-Utf8TextAtomic $b.cycleStatePath (@{memoryCycle=@{current='next-cycle';reserved='';workspaceId=$b.identity.workspaceId}}|ConvertTo-Json)
        $reset=Resolve-ItlMemoryLiveBinding $held (& $rewrite {param($c) $c['cycleId']='next-cycle'})
        $reset.contextChanged.reason | Should -BeExactly cycle
        $reset.contextChanged.previousCycleId | Should -BeExactly $b.cycleId
        $reset.contextChanged.cycleId | Should -BeExactly 'next-cycle'
        $reset.holdWrites | Should -BeTrue
        $held=$reset.binding
        $moved=Resolve-ItlMemoryLiveBinding $held (& $rewrite {param($c) $c['bindingId']='b4';$c.context['projectId']='other-customer'})
        $moved.contextChanged.reason | Should -BeExactly project
        $moved.holdWrites | Should -BeTrue
        $held=$moved.binding
        $product=Resolve-ItlMemoryLiveBinding $held (& $rewrite {param($c) $c['bindingId']='b5';$c.context['productId']='corp'})
        $product.contextChanged.reason | Should -BeExactly product
        $product.holdWrites | Should -BeFalse
        $held=$product.binding
        {Resolve-ItlMemoryLiveBinding $held (& $rewrite {param($c) $c['bindingId']='b6';$c.identity['workspaceId']='another-copy'})} | Should -Throw '*MEMORY_STALE_CONTEXT*another working copy*'
        {Resolve-ItlMemoryLiveBinding $held (& $rewrite {param($c) $c.identity['workspaceId']=$b.identity.workspaceId;$c['mode']='disabled'})} | Should -Throw '*MEMORY_DISABLED*'
        {Resolve-ItlMemoryLiveBinding $held (& $rewrite {param($c) $c['mode']='enabled';$c['schemaVersion']=2})} | Should -Throw '*MEMORY_BINDING_UNSUPPORTED*reload the client*'
        {Resolve-ItlMemoryLiveBinding $held $null} | Should -Throw '*MEMORY_STALE_CONTEXT*'
    }
    It 'reports a context change and holds the first write until memory_status in a real stdio process' {
        $policy=Install-MemoryPolicyFixture $b.projectRoot
        $b.policyProofs=@{cursor=(Get-ItlMemoryPolicyProof $policy $b.projectRoot)}
        $path=Get-ItlMemoryPath binding $b.projectRoot
        $null=Update-ItlMemoryJson $path {param($old) return $b}
        $server=Start-MemoryServer $path
        try{
            $opened=Invoke-MemoryServerCall $server memory_status @{local_only=$true}
            $opened.bindingState | Should -BeExactly current -Because (ConvertTo-Json -InputObject $opened -Depth 6 -Compress)
            # The owner updates the record in place: the open session follows it.
            $null=Update-ItlMemoryJson $path {param($current) $current['settingsHash']='changed-settings';return $current}
            $same=Invoke-MemoryServerCall $server memory_status @{local_only=$true}
            $same.bindingState | Should -BeExactly current
            $same.PSObject.Properties['contextChanged'] | Should -BeNullOrEmpty
            # While the branch is being reset nothing is accepted.
            Write-Utf8TextAtomic $b.cycleStatePath (@{memoryCycle=@{current=$b.cycleId;reserved='next-cycle';workspaceId=$b.identity.workspaceId};resetStatus='resetting';mainWorktreePath=''}|ConvertTo-Json)
            (Invoke-MemoryServerCall $server remember @{data='Факт во время сброса';note_id='during-reset'}).message | Should -BeExactly 'MEMORY_STALE_CONTEXT'
            # The reset completes and the owner binds the new task cycle.
            Write-Utf8TextAtomic $b.cycleStatePath (@{memoryCycle=@{current='next-cycle';reserved='';workspaceId=$b.identity.workspaceId};mainWorktreePath=''}|ConvertTo-Json)
            Sync-ItlMemoryContext
            (Read-ItlMemoryJson $path).bindingId | Should -Not -Be 'b1'
            $late=Invoke-MemoryServerCall $server remember @{data='Поздний факт старого чата';note_id='late'}
            $late.message | Should -BeExactly 'MEMORY_CONTEXT_CHANGED'
            $late.data.continuation | Should -Match 'memory_status.*note_id=late'
            $late.data.contextChanged.reason | Should -BeExactly cycle
            $late.data.contextChanged.previousCycleId | Should -BeExactly $b.cycleId
            $late.data.contextChanged.cycleId | Should -BeExactly 'next-cycle'
            (Invoke-MemoryServerCall $server retire_note @{note_id='late'}).message | Should -BeExactly 'MEMORY_CONTEXT_CHANGED'
            # memory_status reports the change once, keeps the source and lifts the hold.
            $status=Invoke-MemoryServerCall $server memory_status @{local_only=$true}
            $status.contextChanged.reason | Should -BeExactly cycle
            $status.currentCycleId | Should -BeExactly 'next-cycle'
            @($status.pending|Where-Object noteId -EQ 'late').Count | Should -Be 1
            $accepted=Invoke-MemoryServerCall $server remember @{data='Поздний факт старого чата';note_id='late'}
            $accepted.message | Should -BeExactly 'MEMORY_DESTINATION_REQUIRED'
            $accepted.data.continuation | Should -Match 'note_id=late.*retire_note\(note_id\)'
            $accepted.data.PSObject.Properties['contextChanged'] | Should -BeNullOrEmpty
            (Invoke-MemoryServerCall $server retire_note @{note_id='late'}).state | Should -BeExactly 'discarded-unsent'
            # The copy is bound to another project: the first write is held again.
            $other=ConvertTo-ItlCatalogCanonicalValue (Read-ItlMemoryJson $path).context;$other.projectId='other-customer'
            Write-Utf8TextAtomic $b.appliedPath (@{context=$other;contextHash=(Get-ItlCatalogHash $other)}|ConvertTo-Json -Depth 20)
            Sync-ItlMemoryContext -Context $other
            $moved=Invoke-MemoryServerCall $server remember @{data='Факт прежнего проекта';note_id='moved';dataset_name='itl_org_org'}
            $moved.message | Should -BeExactly 'MEMORY_CONTEXT_CHANGED'
            $moved.data.contextChanged.reason | Should -BeExactly project
            (Invoke-MemoryServerCall $server memory_status @{local_only=$true}).contextChanged.reason | Should -BeExactly project
            $null=Update-ItlMemoryJson $path {param($current) $current['mode']='disabled';$current['bindingId']='disabled-binding';return $current}
            (Invoke-MemoryServerCall $server memory_status @{local_only=$true}).message | Should -BeExactly 'MEMORY_DISABLED'
        }finally{$serverErrors=Stop-MemoryServer $server}
        # Every refusal above is an owner code: nothing unexpected was logged.
        $serverErrors | Should -BeNullOrEmpty
        # One journal session per server process; codes only, no fact text.
        $usagePath=Get-ItlMemoryPath usage $b.identity.workspaceId
        $journal=Read-ItlMemoryJson $usagePath
        @($journal.entries).Count | Should -Be 11
        @($journal.entries|ForEach-Object {$_.session}|Select-Object -Unique).Count | Should -Be 1
        @($journal.entries|Where-Object {$_.outcome -ceq 'MEMORY_CONTEXT_CHANGED'}).Count | Should -Be 3
        @($journal.entries|Where-Object {$_.tool -ceq 'retire_note' -and (Get-ItlCatalogField $_ 'retired')}).Count | Should -Be 1
        @($journal.entries|ForEach-Object {$_.cycleId}|Select-Object -Unique) | Should -Be @($b.cycleId,'next-cycle')
        [IO.File]::ReadAllText($usagePath,[Text.Encoding]::UTF8) | Should -Not -Match 'Поздний|Факт|старого чата'
    }
    It 'extends a previous-workflow binding when the new server starts' {
        # update-workflow may leave the client configuration untouched; the
        # first server of the new workflow then extends the binding itself.
        $policy=Install-MemoryPolicyFixture $b.projectRoot
        $b.policyProofs=@{cursor=(Get-ItlMemoryPolicyProof $policy $b.projectRoot)}
        $b.identity.Remove('localProjectId');$b.identity.Remove('hostId')
        $b.provider.datasets=@($b.provider.datasets|Where-Object scopeKind -NE host)
        $path=Get-ItlMemoryPath binding $b.projectRoot
        $null=Update-ItlMemoryJson $path {param($old) return $b}
        $server=Start-MemoryServer $path
        try{
            $status=Invoke-MemoryServerCall $server memory_status @{local_only=$true}
            $status.bindingState | Should -BeExactly current -Because (ConvertTo-Json -InputObject $status -Depth 6 -Compress)
            @($status.destinations|ForEach-Object {$_.scopeKind}) | Should -Contain workspace
            @($status.destinations|ForEach-Object {$_.scopeKind}) | Should -Contain host
        }finally{$serverErrors=Stop-MemoryServer $server}
        $serverErrors | Should -BeNullOrEmpty
        $extended=Read-ItlMemoryJson $path
        $extended.bindingId | Should -Not -Be 'b1'
        $extended.schemaVersion | Should -Be 1
        $extended.identity.localProjectId | Should -BeExactly $b.identity.workspaceId
        $extended.identity.hostId | Should -Match '^[0-9a-f]{64}$'
    }
    It 'keeps continuation per branch copy and task cycle' {
        $main=$b.projectRoot
        $one=New-MemoryFixture -MainRoot $main -KeepBackend
        $null=Invoke-ItlMemorySetup checkpoint -Checkpoint @{goal='Задача первой ветки';nextStep='шаг 1'}
        $two=New-MemoryFixture -MainRoot $main -KeepBackend
        $null=Invoke-ItlMemorySetup checkpoint -Checkpoint @{goal='Задача второй ветки';nextStep='шаг 2'}
        (Invoke-ItlMemoryStatus $one -LocalOnly).continuation.goal | Should -Be 'Задача первой ветки'
        (Invoke-ItlMemoryStatus $two -LocalOnly).continuation.goal | Should -Be 'Задача второй ветки'
        Test-Path -LiteralPath (Get-ItlMemoryPath continuation $one.identity.workspaceId) | Should -BeTrue
        # Reset of the second copy: its previous continuation is not current.
        Write-Utf8TextAtomic $two.cycleStatePath (@{memoryCycle=@{current='next-cycle';reserved='';workspaceId=$two.identity.workspaceId};mainWorktreePath=$main}|ConvertTo-Json)
        Sync-ItlMemoryContext
        $afterReset=Read-ItlMemoryJson (Get-ItlMemoryPath binding $two.projectRoot)
        $afterReset.cycleId | Should -BeExactly 'next-cycle'
        (Invoke-ItlMemoryStatus $afterReset -LocalOnly).continuation | Should -BeNullOrEmpty
        (Invoke-ItlMemoryStatus $one -LocalOnly).continuation.goal | Should -Be 'Задача первой ветки'
    }
    It 'stores a standing rule as verified with a mark and moves it in place' {
        $evidence=@(@{source='user';reference='chat 2026-11-11'})
        $fact='В этом проекте никогда не меняй режим на клиенте.'
        {Invoke-ItlMemoryRemember $b $fact 'itl_project_customer' 'rule' @{} @() standing} | Should -Throw '*MEMORY_EVIDENCE_REQUIRED*'
        $rule=Invoke-ItlMemoryRemember $b $fact 'itl_project_customer' 'rule' @{} $evidence standing -Title 'Режим на клиенте'
        $rule.state | Should -Be durable
        $rule.operation | Should -Be saved
        $stored=$script:Originals[$rule.dataId]|ConvertFrom-Json
        $stored.status | Should -BeExactly verified
        $stored.standing | Should -BeTrue
        $stored.title | Should -BeExactly 'Режим на клиенте'
        $script:Names[$rule.dataId] | Should -Match '^standing~~Режим на клиенте~[0-9a-f]{8}$'
        & {
            # A copy on the previous workflow reads an ordinary verified note.
            . (Join-Path $RepoRoot 'tests/fixtures/scoped-memory/previous-reader.ps1')
            $seen=Get-ItlMemoryOriginal $b (Get-ProjectDataset $b) $rule.dataId ([DateTime]::UtcNow.AddSeconds(5))
            $seen.status | Should -BeExactly verified
            Test-ItlMemoryNoteApplicable $b $seen | Should -BeTrue
        }
        # verified <-> standing is an update of the same note.
        $plain=Invoke-ItlMemoryRemember $b $fact 'itl_project_customer' 'rule' @{} $evidence verified -DataId $rule.dataId -Title 'Режим на клиенте'
        $plain.dataId | Should -BeExactly $rule.dataId
        $plain.operation | Should -Be updated
        ($script:Originals[$rule.dataId]|ConvertFrom-Json).PSObject.Properties['standing'] | Should -BeNullOrEmpty
        $script:Names[$rule.dataId] | Should -Match '^verified~~Режим на клиенте~'
        $again=Invoke-ItlMemoryRemember $b $fact 'itl_project_customer' 'rule' @{} $evidence standing -DataId $rule.dataId -Title 'Режим на клиенте'
        $again.state | Should -Be durable
        $script:Names[$rule.dataId] | Should -Match '^standing~~'
        @($script:Calls|Where-Object path -EQ '/api/v1/remember').Count | Should -Be 1
        $guess=Invoke-ItlMemoryRemember $b 'Возможно, причина в индексе.' 'itl_project_customer' 'guess'
        $script:Names[$guess.dataId] | Should -Match '^candidate~~Возможно, причина в индексе\.~'
        # A long fact, the task scope and a sixth project rule are refused with
        # the way forward; the pending source is kept each time.
        {Invoke-ItlMemoryRemember $b ('я'*401) 'itl_project_customer' 'long' @{} $evidence standing} | Should -Throw '*MEMORY_STANDING_TOO_LONG*save it as verified*note_id=long*'
        (Invoke-ItlMemoryStatus $b -NoteId long -LocalOnly).pending[0].status | Should -BeExactly standing
        $taskLabel=@(Get-ItlMemoryPrivateScopes $b)[0].label
        {Invoke-ItlMemoryRemember $b 'Правило только этой задачи.' $taskLabel 'task-rule' @{} $evidence standing} | Should -Throw '*MEMORY_STANDING_SCOPE*'
        foreach($number in 2..5){(Invoke-ItlMemoryRemember $b "Правило проекта номер $number." 'itl_project_customer' "rule-$number" @{} $evidence standing).state | Should -Be durable}
        {Invoke-ItlMemoryRemember $b 'Шестое правило проекта.' 'itl_project_customer' 'rule-6' @{} $evidence standing} | Should -Throw '*MEMORY_STANDING_LIMIT*status=verified*note_id=rule-6*'
        (Invoke-ItlMemoryStatus $b -NoteId rule-6 -LocalOnly).pending[0].sent | Should -BeFalse
        # At the limit an existing standing note is still updated, and the
        # refused one is saved as verified under the same ID.
        (Invoke-ItlMemoryRemember $b ($fact+' Уточнено пользователем.') 'itl_project_customer' 'rule' @{} $evidence standing -DataId $rule.dataId).state | Should -Be durable
        (Invoke-ItlMemoryRemember $b 'Шестое правило проекта.' 'itl_project_customer' 'rule-6' @{} $evidence verified).state | Should -Be durable
        {Invoke-ItlMemoryRemember $b 'Факт' 'itl_project_customer' 'titled' @{} $evidence verified -Title ('т'*81)} | Should -Throw '*MEMORY_NOTE_INVALID*80 characters*'
    }
    It 'derives a unique bounded document name and reconciles a name conflict by exact ID' {
        $evidence=@(@{source='user';reference='chat 2026-11-11'})
        $title=('Очень длинный заголовок заметки проекта '*3).Substring(0,79)+'я'
        $one=Invoke-ItlMemoryRemember $b 'Первая заметка.' 'itl_project_customer' 'same-1' @{} $evidence verified -Title $title
        $two=Invoke-ItlMemoryRemember $b 'Вторая заметка.' 'itl_project_customer' 'same-2' @{} $evidence verified -Title $title
        $one.state | Should -Be durable
        $two.state | Should -Be durable
        $script:Names[$one.dataId] | Should -Not -Be $script:Names[$two.dataId]
        foreach($name in @($script:Names[$one.dataId],$script:Names[$two.dataId])){
            [Text.Encoding]::UTF8.GetByteCount($name+'.txt') | Should -BeLessOrEqual 200
            $name | Should -Not -Match '[/\\]'
        }
        $parsed=ConvertFrom-ItlMemoryDocumentName $script:Names[$one.dataId]
        $parsed.status | Should -BeExactly verified
        $parsed.title | Should -BeExactly $title
        $parsed.key | Should -BeExactly (Get-ItlMemoryNoteKey 'same-1')
        # A product name carries its knowledge area; a long one is cut to the bound.
        $productNote=@{noteId='area-note';status='verified';fact='Факт.';title=$title;scope=@{kind='product';id='corp'};applicability=@{knowledgeArea=('область-планирования-'*3)}}
        $productName=Get-ItlMemoryDocumentName $productNote
        [Text.Encoding]::UTF8.GetByteCount($productName) | Should -BeLessOrEqual 200
        (ConvertFrom-ItlMemoryDocumentName $productName).area | Should -BeExactly ('область-планирования-'*3)
        $productNote.title='';$productNote.applicability.knowledgeArea='planning'
        Get-ItlMemoryDocumentName $productNote | Should -Match '^verified~planning~Факт\.~[0-9a-f]{8}\.txt$'
        # Without a title: the first sentence, with path separators removed.
        $path=Invoke-ItlMemoryRemember $b 'Путь C:\База/Каталог ~ и "кавычки". Второе предложение.' 'itl_project_customer' 'path'
        $parsedPath=ConvertFrom-ItlMemoryDocumentName $script:Names[$path.dataId]
        $parsedPath.status | Should -BeExactly candidate
        $parsedPath.title | Should -BeExactly 'Путь C: База Каталог и кавычки .'
        # The name follows an update of status and title.
        $null=Invoke-ItlMemoryRemember $b 'Путь исправлен.' 'itl_project_customer' 'path' @{} $evidence verified -DataId $path.dataId -Title 'Путь к базе'
        $script:Names[$path.dataId] | Should -Match '^verified~~Путь к базе~[0-9a-f]{8}$'
        # A name of the previous format is unknown, never an error.
        ConvertFrom-ItlMemoryDocumentName 'memory' | Should -BeNullOrEmpty
        ConvertFrom-ItlMemoryDocumentName 'verified~no-key' | Should -BeNullOrEmpty
        # A lost local receipt: the server answers 409 for the taken name and
        # the same note is reconciled by its exact ID, not written twice.
        Remove-Item -LiteralPath (Get-ItlMemoryPath receipt (Get-ItlMemoryRecordKey $b (Get-ProjectDataset $b).datasetId 'same-1'))
        $documents=@($script:Originals.Keys).Count
        $repeat=Invoke-ItlMemoryRemember $b 'Первая заметка.' 'itl_project_customer' 'same-1' @{} $evidence verified -Title $title
        $repeat.state | Should -Be durable
        $repeat.dataId | Should -BeExactly $one.dataId
        @($script:Originals.Keys).Count | Should -Be $documents
        @((Invoke-ItlMemoryStatus $b -LocalOnly).pending).Count | Should -Be 0
    }
    It 'completes the pending record of a fact once its destination is chosen' {
        $evidence=@(@{source='user';reference='chat 2026-11-11'})
        $fact='Регистр заполняется документом, а не обработкой.'
        {Invoke-ItlMemoryRemember $b $fact '' '' @{} $evidence verified} | Should -Throw '*MEMORY_DESTINATION_REQUIRED*note_id=*repeat remember*retire_note(note_id)*'
        $pending=@((Invoke-ItlMemoryStatus $b -LocalOnly).pending)
        $pending.Count | Should -Be 1
        $saved=Invoke-ItlMemoryRemember $b $fact 'itl_project_customer' '' @{} $evidence verified
        $saved.state | Should -Be durable
        $saved.noteId | Should -BeExactly $pending[0].noteId
        @((Invoke-ItlMemoryStatus $b -LocalOnly).pending).Count | Should -Be 0
        @(Get-ChildItem -LiteralPath (Join-Path (Join-Path (Get-ItlMemoryHome) 'pending') $b.identity.workspaceId) -File -Filter '*.json').Count | Should -Be 0
        # The messages name both ways out of a kept pending note.
        {Get-ItlMemoryScopes $b write} | Should -Throw '*remember with its note_id*retire_note(note_id)*'
        {Invoke-ItlMemoryRemember $b 'Факт без назначения' '' 'stuck'} | Should -Throw '*note_id=stuck*'
        $script:BodyLoss=$true
        $null=Invoke-ItlMemoryRemember $b 'Отправленный факт' 'itl_project_customer' 'sent'
        {Invoke-ItlMemoryRemember $b 'Изменённый факт' 'itl_project_customer' 'sent'} | Should -Throw '*MEMORY_PENDING_CONFLICT*memory_status(dataset_name, note_id)*remember with its note_id*retire_note(note_id)*'
        $script:BodyLoss=$false
        # An unsent draft changes destination and content under its ID.
        (Invoke-ItlMemoryRemember $b 'Факт с выбранным назначением' 'itl_org_org' 'stuck' @{} $evidence verified).state | Should -Be durable
        @((Invoke-ItlMemoryStatus $b -LocalOnly).pending|Where-Object noteId -EQ 'stuck').Count | Should -Be 0
    }
    It 'returns standing notes in full and an index from listings without reading ordinary originals' {
        $project=Get-ProjectDataset $b;$product=Get-ScopeDataset $b product
        $b.memoryProjection.knowledgeAreas=@{planning=@{availableIn=@('prof');memoryHomeProductId='corp'}}
        $rule=Add-FixtureNote $project 'rule' 'В этом проекте никогда не меняй режим на клиенте.' -Standing -Title 'Режим на клиенте'
        $null=Add-FixtureNote $project 'plain' 'Регистр заполняется документом.' -Title 'Заполнение регистра'
        $null=Add-FixtureNote $project 'guess' 'Возможно, причина в индексе.' -Status candidate
        $legacy=Add-FixtureNote $project 'legacy' 'Заметка, обновлённая прежней версией. Подробности.' -LegacyName
        $null=Add-FixtureNote $product 'area-ok' 'Особенность планирования.' -Area planning -Title 'Планирование'
        $null=Add-FixtureNote $product 'area-no' 'Особенность продаж.' -Area sales -Title 'Продажи'
        # A stale name: an older copy turned this note back into a plain one.
        $stale=Add-FixtureNote $project 'stale' 'Бывшее правило.' -Title 'Бывшее правило'
        $script:Names[$stale]=$script:Names[$stale] -replace '^verified','standing'
        $status=Invoke-ItlMemoryStatus $b
        $status.serverCoverage | Should -BeExactly bounded
        $status.bindingState | Should -BeExactly current
        @($status.standing).Count | Should -Be 1
        $status.standing[0].noteId | Should -BeExactly rule
        $status.standing[0].dataId | Should -BeExactly $rule
        $status.standing[0].level | Should -BeExactly project
        $status.standing[0].dataset | Should -BeExactly 'itl_project_customer'
        $status.standing[0].fact | Should -BeExactly 'В этом проекте никогда не меняй режим на клиенте.'
        # Verified before candidate, newest first; a candidate is marked.
        @($status.index|Where-Object level -EQ project)[0].notes | Should -Be @('Бывшее правило','Заметка, обновлённая прежней версией.','Заполнение регистра','Возможно, причина в индексе. [candidate]')
        # A product row of an inapplicable knowledge area is not listed.
        @($status.index|Where-Object level -EQ product)[0].notes | Should -Be @('Планирование')
        # Index rows carry no identifiers.
        (ConvertTo-Json -InputObject $status.index -Depth 6) | Should -Not -Match 'plain|guess|area-ok|[0-9a-f]{8}-[0-9a-f]{4}-'
        # Originals: the two names claiming standing and the one legacy name.
        $raw=@($script:Calls|Where-Object {$_.path -like '*/raw'}|ForEach-Object {$_.path})
        $raw.Count | Should -Be 3
        foreach($id in @($rule,$legacy,$stale)){($raw -join ' ') | Should -Match $id}
        # local_only stays the offline path with its previous shape.
        $calls=$script:Calls.Count
        $local=Invoke-ItlMemoryStatus $b -LocalOnly
        $script:Calls.Count | Should -Be $calls
        $local.Contains('standing') | Should -BeFalse
        # One unreadable dataset is partial coverage, named.
        $organization=Get-ScopeDataset $b organization
        Mock Invoke-ItlMemoryHttp {@{status=500;body=$null}} -ParameterFilter {$Path -eq "/api/v1/datasets/$($organization.datasetId)/data?limit=1000"}
        $partial=Invoke-ItlMemoryStatus $b
        $partial.serverCoverage | Should -Match '^partial:.*itl_org_org.*not absence of knowledge'
        @($partial.standing).Count | Should -Be 1
        # An unreachable server leaves the local part and says so.
        Mock Invoke-ItlMemoryHttp {throw 'MEMORY_TRANSPORT_UNCONFIRMED'} -ParameterFilter {$Path -eq '/api/v1/users/me'}
        $offline=Invoke-ItlMemoryStatus $b
        $offline.serverCoverage | Should -Match '^unavailable: MEMORY_TRANSPORT_UNCONFIRMED.*not absence of knowledge'
        $offline.bindingState | Should -BeExactly current
        @($offline.standing).Count | Should -Be 0
        @($offline.index).Count | Should -Be 0
    }
    It 'bounds the whole status answer at 2000 tokens with project standing notes first' {
        . (Join-Path $RepoRoot '.agents/skills/1c-workflow/scripts/lib/agent-1c.memory-tokens.ps1')
        $b.memoryProjection.knowledgeAreas=@{planning=@{availableIn=@('prof');memoryHomeProductId='corp'}}
        $limits=Get-ItlMemoryLevelLimits
        @($limits.Keys) | Should -Be @('project','workspace','organization','product','host','workplace','taskCycle')
        $rule=('Постоянное правило работы с конфигурацией клиента и его стендом. '*8).Substring(0,400)
        # Every level filled to its maxima, plus five notes over each index limit.
        foreach($kind in $limits.Keys){
            $dataset=Get-ScopeDataset $b $kind;$area=if($kind -eq 'product'){'planning'}else{''}
            for($number=1;$number -le $limits[$kind].standing;$number++){$null=Add-FixtureNote $dataset "$kind-rule-$number" $rule -Standing -Title "Правило $kind $number" -Area $area}
            for($number=1;$number -le $limits[$kind].index+5;$number++){$null=Add-FixtureNote $dataset "$kind-note-$number" 'Обычная заметка.' -Title ("Заголовок обычной заметки уровня $kind номер $number с подробностями и уточнениями").PadRight(80,'я').Substring(0,80) -Area $area}
        }
        $status=Invoke-ItlMemoryStatus $b
        $tokens=Measure-ItlMemoryTokens (ConvertTo-Json -InputObject $status -Depth 30 -Compress)
        $tokens.measurement | Should -BeExactly 'measured-encode-ordinary'
        $tokens.cl100k_base | Should -BeLessOrEqual 2000
        $tokens.o200k_base | Should -BeLessOrEqual 2000
        # The bound is used, not merely respected.
        [Math]::Max($tokens.cl100k_base,$tokens.o200k_base) | Should -BeGreaterThan 1700
        # Standing notes come first and in level order, project first.
        @($status.standing).Count | Should -BeGreaterThan 0
        $status.standing[0].level | Should -BeExactly project
        $order=@($limits.Keys);$positions=@($status.standing|ForEach-Object {[Array]::IndexOf($order,$_.level)})
        ($positions -join ',') | Should -BeExactly ((@($positions|Sort-Object)) -join ',')
        # What did not fit is reported per level as more.
        foreach($kind in $limits.Keys){
            $entry=@($status.index|Where-Object level -EQ $kind)
            $entry.Count | Should -Be 1 -Because $kind
            $entry[0].more | Should -BeGreaterThan 0 -Because $kind
        }
        $shown=(@($status.index|ForEach-Object {@($_.notes).Count})|Measure-Object -Sum).Sum
        $counted=(@($status.index|ForEach-Object {$_.more})|Measure-Object -Sum).Sum
        ($shown+$counted+@($status.standing).Count) | Should -Be 176
        # Only originals of standing notes are read: at most the level maxima.
        @($script:Calls|Where-Object {$_.path -like '*/raw'}).Count | Should -Be 21
    }
    It 'cuts an overfull project index at its level limit and counts the rest' {
        $project=Get-ProjectDataset $b
        foreach($number in 1..45){$null=Add-FixtureNote $project "note-$number" 'Обычная заметка.' -Title "Заметка $number"}
        $status=Invoke-ItlMemoryStatus $b
        $entry=@($status.index|Where-Object level -EQ project)[0]
        @($entry.notes).Count | Should -Be 30
        $entry.more | Should -Be 15
        $entry.notes[0] | Should -BeExactly 'Заметка 45'
        $entry.notes[29] | Should -BeExactly 'Заметка 16'
        @($script:Calls|Where-Object {$_.path -like '*/raw'}).Count | Should -Be 0
        # More than six names of the previous format: six are read, the rest counted.
        foreach($number in 1..8){$null=Add-FixtureNote (Get-ScopeDataset $b organization) "old-$number" "Старая заметка $number." -LegacyName}
        $legacy=@((Invoke-ItlMemoryStatus $b).index|Where-Object level -EQ organization)[0]
        @($legacy.notes).Count | Should -Be 6
        $legacy.more | Should -Be 2
        @($script:Calls|Where-Object {$_.path -like '*/raw'}).Count | Should -Be 6
    }
    It 'lists one destination per dataset with the knowledge areas of a product' {
        $b.context.knowledgeContext.knowledgeAreas=@(1..20|ForEach-Object {@{areaId="area-$_";status='applicable';memoryHomeProductId='corp'}})
        $status=Invoke-ItlMemoryStatus $b -LocalOnly
        $destinations=@($status.destinations)
        $product=@($destinations|Where-Object scopeKind -EQ product)
        $product.Count | Should -Be 1
        $product[0].label | Should -BeExactly 'itl_product_corp'
        @($product[0].knowledgeAreas).Count | Should -Be 20
        @($destinations|Group-Object {$_.label}|Where-Object Count -GT 1).Count | Should -Be 0
        @($destinations|ForEach-Object {$_.scopeKind}|Sort-Object) | Should -Be @('host','organization','product','project','taskCycle','workplace','workspace')
        $status.writeGuidance | Should -Match 'applicability\.independentOfCustomization=true'
        Should -Invoke Invoke-ItlMemoryHttp -Times 0 -Exactly
    }
    It 'recalls verified product knowledge in a dependent project and keeps the source project note local' {
        $writer=New-MemoryFixture -ProjectId 'core-development'
        $reader=New-MemoryFixture -ProjectId 'dependent-development' -KeepBackend
        $writer.context.productId='corp'
        $writer.context.projectContext.customized=$false
        $area=@{availableIn=@('corp','prof');requiresProducts=@('corp');memoryHomeProductId='corp'}
        $relations=@{relations=@(@{type='contains';productId='prof';componentProductId='corp'})}
        foreach($binding in @($writer,$reader)){
            $snapshot=@{relations=$relations}
            $decision=Resolve-ItlCatalogArea $snapshot $binding.context.productId $area
            $decision.status | Should -BeExactly applicable
            $binding.context.knowledgeContext.knowledgeAreas=@(@{areaId='planning';status=$decision.status;memoryHomeProductId='corp'})
            $binding.memoryProjection=@{knowledgeAreas=@{planning=$area};snapshot=$snapshot;composition=@(Get-ItlCatalogComposition $relations $binding.context.productId)}
        }
        $localProject=Get-ProjectDataset $writer
        $reader.provider.datasets+=@($localProject)
        $status=Invoke-ItlMemoryStatus $writer -LocalOnly
        $status.writeGuidance | Should -Match 'confirmed product knowledge.*dataset_name.*applicability\.knowledgeArea.*project or its team'
        $status.writeGuidance | Should -Not -Match 'independentOfCustomization'
        $productDestination=@($status.destinations|Where-Object {$_.scopeKind -ceq 'product' -and $_.knowledgeAreas -ccontains 'planning'})
        $productDestination.Count | Should -Be 1
        $evidence=@(@{source='user';reference='chat 2026-11-12'})
        $shared=Invoke-ItlMemoryRemember $writer 'Общее правило расчёта планов.' $productDestination[0].label 'product-planning' @{knowledgeArea='planning'} $evidence verified
        $local=Invoke-ItlMemoryRemember $writer 'Локальное правило команды планирования.' $localProject.label 'project-planning' @{} $evidence verified
        $shared.state | Should -BeExactly durable
        $local.state | Should -BeExactly durable
        Mock-IndexedFixtureNotes
        $query='правила планирования'
        @((Invoke-ItlMemoryRecall $writer $query).cards|ForEach-Object {$_.source.dataId}) | Should -Contain $local.dataId
        $recalled=Invoke-ItlMemoryRecall $reader $query
        @($recalled.cards|ForEach-Object {$_.source.dataId}) | Should -Be @($shared.dataId)
        $recalled.cards[0].noteId | Should -BeExactly 'product-planning'
        $search=@($script:Calls|Where-Object path -EQ '/api/v1/recall')[-1]
        $search.body.dataset_ids | Should -Contain (Get-ScopeDataset $writer product).datasetId
        $search.body.dataset_ids | Should -Not -Contain $localProject.datasetId
    }
    It 'distinguishes an uncreated task destination from a readable project in a fresh branch' {
        Mock-IndexedFixtureNotes
        $task=Get-ScopeDataset $b taskCycle
        $null=Update-ItlMemoryJson (Get-ItlMemoryPath binding $b.projectRoot) {param($current)
            $current.provider.datasets=@($current.provider.datasets|Where-Object scopeKind -NE taskCycle)
            return $current
        }
        $b.provider.datasets=@($b.provider.datasets|Where-Object scopeKind -NE taskCycle)
        $project=Get-ProjectDataset $b
        $id=Add-FixtureNote $project 'shared-decision' 'Подтвержденное правило проекта.'
        $local=Invoke-ItlMemoryStatus $b -LocalOnly
        ($local.destinations|Where-Object scopeKind -EQ taskCycle).readState | Should -BeExactly 'unknown'
        ($local.destinations|Where-Object scopeKind -EQ project).readState | Should -BeExactly 'admitted'
        Should -Invoke Invoke-ItlMemoryHttp -Times 0 -Exactly
        $status=Invoke-ItlMemoryStatus $b
        ($status.destinations|Where-Object scopeKind -EQ taskCycle).readState | Should -BeExactly 'not_created'
        $status.serverCoverage | Should -BeExactly 'bounded'
        $recall=Invoke-ItlMemoryRecall $b 'общий проект'
        $recall.cards[0].source.dataId | Should -BeExactly $id
        $recall.coverage | Should -BeExactly 'bounded'
        {Invoke-ItlMemoryRecall $b 'общий проект' @($project.label,$task.label)} |
            Should -Throw "*MEMORY_READ_SCOPE_DENIED*$($task.label)*does not exist*"
        {Invoke-ItlMemoryRecall $b 'общий проект' @($project.label,'itl_task_foreign')} |
            Should -Throw '*MEMORY_READ_SCOPE_DENIED*itl_task_foreign*outside the admitted read set*'
        Should -Invoke Invoke-ItlMemoryHttp -Times 1 -Exactly -ParameterFilter {$Path -eq '/api/v1/recall'}
        Should -Invoke Invoke-ItlMemoryHttp -Times 2 -Exactly -ParameterFilter {$Path -eq '/api/v1/datasets' -and $Method -eq 'GET'}
    }

    It 'finds the same project original across copies and still applies machine-readable conditions' {
        Mock-IndexedFixtureNotes
        $proof=@(@{source='test';reference='checked fixture diff'})
        $b.memoryProjection.composition=@('erp')
        $project=Get-ProjectDataset $b
        $saved=Invoke-ItlMemoryRemember $b 'Исправление применимо вместе с ERP.' $project.label 'erp-fix' @{requiresProducts=@('erp')} $proof verified
        $saved.state | Should -BeExactly 'durable'
        $other=New-MemoryFixture -KeepBackend
        $other.context.knowledgeContext.productVersion | Should -BeExactly $b.context.knowledgeContext.productVersion
        (Invoke-ItlMemoryStatus $other $project.label -DataId $saved.dataId).applicable | Should -BeFalse
        @( (Invoke-ItlMemoryRecall $other 'Исправление').cards ).Count | Should -Be 0
        $other.memoryProjection.composition=@('erp')
        (Invoke-ItlMemoryRecall $other 'Исправление').cards[0].source.dataId | Should -BeExactly $saved.dataId
    }

    It 'adopts an existing workplace from a sibling branch for search and exact reads' {
        Mock-IndexedFixtureNotes
        $main=$b.projectRoot
        $one=New-MemoryFixture -KeepBackend -MainRoot $main
        $two=New-MemoryFixture -KeepBackend -MainRoot $main
        foreach($copy in @($one,$two)){
            $copy.provider.datasets=@($copy.provider.datasets|Where-Object scopeKind -NE workplace)
            $null=Update-ItlMemoryJson (Get-ItlMemoryPath binding $copy.projectRoot) {param($old) return $copy}
        }
        $label=(Get-ItlMemoryPrivateScopes $one|Where-Object scopeKind -EQ workplace).label
        $proof=@(@{source='user';reference='chat'})
        $saved=Invoke-ItlMemoryRemember $one 'Практика рабочего места.' $label 'workplace-practice' @{} $proof verified
        $saved.state | Should -BeExactly 'durable'
        $saved.scopeKind | Should -BeExactly 'workplace'
        (Invoke-ItlMemoryRecall $two 'практика').cards[0].source.dataId | Should -BeExactly $saved.dataId
        (Invoke-ItlMemoryStatus $two $label -DataId $saved.dataId).dataId | Should -BeExactly $saved.dataId
        Should -Invoke Invoke-ItlMemoryHttp -Times 1 -Exactly -ParameterFilter {$Path -eq '/api/v1/datasets' -and $Method -eq 'POST'}
    }

    It 'returns the admitted project and explains a failed discovery without a second listing' {
        Mock-IndexedFixtureNotes
        $b=New-MemoryFixture -LazyShared
        $project=Get-ProjectDataset $b
        $id=Add-FixtureNote $project 'project-coverage' 'Проектное решение.'
        $label=(Get-ItlMemoryPrivateScopes $b|Where-Object scopeKind -EQ workspace).label
        Mock Invoke-ItlMemoryHttp {@{status=503;body=$null}} -ParameterFilter {$Path -eq '/api/v1/datasets'}
        $trace=@{}
        $recall=Invoke-ItlMemoryRecall $b 'проектное решение' -Trace $trace
        $recall.cards[0].source.dataId | Should -BeExactly $id
        $recall.coverage | Should -BeExactly 'partial'
        ($recall.coverageIssues|Where-Object scopeKind -EQ workspace).reason | Should -BeExactly 'listing_unavailable'
        $trace.stageMs.Keys | Should -Be @('principal','discovery','search','originals')
        Should -Invoke Invoke-ItlMemoryHttp -Times 1 -Exactly -ParameterFilter {$Path -eq '/api/v1/datasets'}
        {Invoke-ItlMemoryRecall $b 'проектное решение' @($project.label,$label)} |
            Should -Throw "*MEMORY_READ_SCOPE_DENIED*$label*could not be verified*"
        $status=Invoke-ItlMemoryStatus $b
        ($status.destinations|Where-Object scopeKind -EQ workspace).readState | Should -BeExactly 'unknown'
        $status.serverCoverage | Should -Match '^partial: .*workspace=listing_unavailable'
        Should -Invoke Invoke-ItlMemoryHttp -Times 1 -Exactly -ParameterFilter {$Path -eq '/api/v1/recall'}
        Should -Invoke Invoke-ItlMemoryHttp -Times 3 -Exactly -ParameterFilter {$Path -eq '/api/v1/datasets'}
    }

    It 'keeps a verified workspace mapping when a later scope cannot be adopted' {
        Mock-IndexedFixtureNotes
        $b=New-MemoryFixture -LazyShared
        $workspace=(Get-ItlMemoryPrivateScopes $b|Where-Object scopeKind -EQ workspace)
        $workspace.datasetId=[guid]::NewGuid().ToString()
        $hostScope=Get-ItlMemoryPrivateScopes $b|Where-Object scopeKind -EQ host
        $script:NativeDatasets=@(@{name=$workspace.label;id=$workspace.datasetId;ownerId='ordinary-user'})+
            @(1..2|ForEach-Object {@{name=$hostScope.label;id=[guid]::NewGuid().ToString();ownerId='ordinary-user'}})
        $id=Add-FixtureNote $workspace 'checked-workspace' 'Факт рабочей копии.'
        $recall=Invoke-ItlMemoryRecall $b 'копия'
        $recall.cards[0].source.dataId | Should -BeExactly $id
        ($recall.coverageIssues|Where-Object scopeKind -EQ host).reason | Should -BeExactly 'dataset_unverified'
        $live=Read-ItlMemoryJson (Get-ItlMemoryPath binding $b.projectRoot)
        @(Get-ItlMemoryScopes $live read $workspace.label)[0].datasetId | Should -BeExactly $workspace.datasetId
        @(Get-ItlMemoryScopes $live read $hostScope.label).Count | Should -Be 0
        Should -Invoke Invoke-ItlMemoryHttp -Times 1 -Exactly -ParameterFilter {$Path -eq '/api/v1/datasets' -and $Method -eq 'GET'}
        Should -Invoke Invoke-ItlMemoryHttp -Times 0 -Exactly -ParameterFilter {$Path -eq '/api/v1/datasets' -and $Method -eq 'POST'}
    }

    It 'does not start search when discovery exhausts the remaining operation deadline' {
        $b=New-MemoryFixture -LazyShared
        Mock Invoke-ItlMemoryHttp {
            $remaining=($DeadlineUtc-[DateTime]::UtcNow).TotalMilliseconds
            if($remaining -gt 0){Start-Sleep -Milliseconds ([int]$remaining+10)}
            throw 'MEMORY_TRANSPORT_UNCONFIRMED: deadline'
        } -ParameterFilter {$Path -eq '/api/v1/datasets'}
        $trace=@{}
        {Invoke-ItlMemoryRecall $b 'query' -Trace $trace -DeadlineUtc ([DateTime]::UtcNow.AddMilliseconds(500))} |
            Should -Throw '*MEMORY_DEADLINE*'
        $trace.failureStage | Should -BeExactly 'discovery'
        Should -Invoke Invoke-ItlMemoryHttp -Times 0 -Exactly -ParameterFilter {$Path -eq '/api/v1/recall'}
    }

    It 'closes a hung native listing once per operation while recall and status still read the project' {
        Mock-IndexedFixtureNotes
        $b=New-MemoryFixture -LazyShared
        $project=Get-ProjectDataset $b
        $id=Add-FixtureNote $project 'bounded-discovery' 'Статус проектной заметки.'
        $ready=Join-Path $TestDrive 'discovery-port.txt'
        $job=Start-Job -ArgumentList $ready -ScriptBlock {
            param($Ready)
            $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
            $listener.Start()
            try{
                [IO.File]::WriteAllText($Ready,[string]$listener.LocalEndpoint.Port)
                foreach($operation in 1..2){
                    $peer=$listener.AcceptTcpClient();$peer.ReceiveTimeout=7000
                    try{
                        $stream=$peer.GetStream()
                        $header=''
                        while(-not $header.EndsWith("`r`n`r`n")){
                            $v=$stream.ReadByte()
                            if($v -lt 0 -or $header.Length -gt 8000){throw 'bad fixture request'}
                            $header+=[char]$v
                        }
                        if($header -notmatch '^GET /api/v1/datasets HTTP/'){throw 'unexpected request'}
                        if($stream.ReadByte() -ne -1){throw 'listing remained open'}
                        'closed'
                    }finally{$peer.Dispose()}
                }
                if($listener.Pending()){throw 'listing was retried'}
            }finally{$listener.Stop()}
        }
        try{
            $until=[DateTime]::UtcNow.AddSeconds(10)
            while(-not (Test-Path -LiteralPath $ready) -and [DateTime]::UtcNow -lt $until){Start-Sleep -Milliseconds 25}
            $b.provider.url='http://127.0.0.1:'+([IO.File]::ReadAllText($ready))+'/'
            $b.provider.credentialFile=Join-Path $env:VIBECODING1C_MCP_LOCAL_HOME 'credential.json'
            Write-Utf8TextAtomic $b.provider.credentialFile '{"apiKey":"fixture"}'
            $script:ListingBudgets=[Collections.Generic.List[double]]::new()
            Mock Invoke-ItlMemoryHttp {
                param($Provider,$Method,$Path,$DeadlineUtc,$Raw)
                $script:ListingBudgets.Add(($DeadlineUtc-[DateTime]::UtcNow).TotalSeconds)
                & $NativeMemoryHttp $Provider $Method $Path -DeadlineUtc $DeadlineUtc -Raw:$Raw
            } -ParameterFilter {$Path -eq '/api/v1/datasets'}
            $trace=@{}
            $recall=Invoke-ItlMemoryRecall $b 'проектная заметка' -Trace $trace
            $recall.cards[0].source.dataId | Should -BeExactly $id
            $recall.coverage | Should -BeExactly 'partial'
            ($recall.coverageIssues|Where-Object scopeKind -EQ workspace).reason | Should -BeExactly 'discovery_deadline'
            $trace.stageMs.discovery | Should -BeLessThan 3000
            $watch=[Diagnostics.Stopwatch]::StartNew()
            $status=Invoke-ItlMemoryStatus $b
            $watch.Elapsed.TotalSeconds | Should -BeLessThan 15
            ($status.destinations|Where-Object scopeKind -EQ workspace).readState | Should -BeExactly 'unknown'
            $status.serverCoverage | Should -Match '^partial: .*workspace=discovery_deadline'
            ($status.index|Where-Object level -EQ project).notes | Should -Contain 'Статус проектной заметки.'
            $null=$job|Wait-Job -Timeout 5
            @(Receive-Job $job -ErrorAction Stop) | Should -Be @('closed','closed')
            foreach($budget in $script:ListingBudgets){$budget | Should -BeLessOrEqual 2}
            Should -Invoke Invoke-ItlMemoryHttp -Times 2 -Exactly -ParameterFilter {$Path -eq '/api/v1/datasets'}
        }finally{$job|Stop-Job;$job|Remove-Job -Force}
    }

    It 'derives one host scope per machine and host name without elevation' {
        # The real unelevated read of this runner.
        & $NativeMachineGuid | Should -Match '^[0-9a-fA-F-]{36}$'
        $first=Get-ItlMemoryHostId
        $first | Should -Match '^[0-9a-f]{64}$'
        $b.identity.hostId | Should -BeExactly $first
        # Another Windows profile on the same machine has its own private home.
        $home1=$env:VIBECODING1C_MCP_LOCAL_HOME
        try{
            $env:VIBECODING1C_MCP_LOCAL_HOME=Join-Path $TestDrive ('Другой профиль '+[guid]::NewGuid().ToString('N'))
            $other=Get-ItlMemoryWorkspace (Join-Path $TestDrive 'Проект другого пользователя') 'ordinary-user'
        }finally{$env:VIBECODING1C_MCP_LOCAL_HOME=$home1}
        $other.hostId | Should -BeExactly $first
        $other.machineId | Should -Not -Be $b.identity.machineId
        $other.workplaceId | Should -Not -Be $b.identity.workplaceId
        # A cloned virtual machine keeps the GUID and differs by host name.
        Mock Get-ItlMemoryHostName {'CLONED-VM'}
        Get-ItlMemoryHostId | Should -Not -Be $first
        # No machine identifier: only the host scope is unavailable.
        Mock Get-ItlMemoryMachineGuid {''}
        Get-ItlMemoryHostId | Should -BeExactly ''
        $b.identity=Get-ItlMemoryWorkspace $b.projectRoot 'ordinary-user'
        $b.identity.hostId | Should -BeExactly ''
        @(Get-ItlMemoryPrivateScopes $b|ForEach-Object {$_.scopeKind}) | Should -Be @('taskCycle','workspace','workplace')
        @(Get-ItlMemoryScopes $b read).Count | Should -Be 6
    }
    It 'adopts an existing lazy dataset and rejects an ambiguous one without creating another' {
        $label=@(Get-ItlMemoryPrivateScopes $b|Where-Object scopeKind -EQ host)[0].label
        $path=Get-ItlMemoryPath binding $b.projectRoot
        $unmap={
            $b.provider.datasets=@($b.provider.datasets|Where-Object label -CNE $label)
            $null=Update-ItlMemoryJson $path {param($old) $old.provider.datasets=@($old.provider.datasets|Where-Object label -CNE $label);if($old.Contains('datasetReservations')){$old.Remove('datasetReservations')};return $old}
        }
        $posts={@($script:Calls|Where-Object {$_.method -eq 'POST' -and $_.path -eq '/api/v1/datasets'}).Count}
        $deadline=[DateTime]::UtcNow.AddSeconds(60)
        # Another user of the same account created it: found by name and owner.
        & $unmap
        $script:NativeDatasets=@(@{name=$label;id=[guid]::NewGuid().ToString();ownerId='ordinary-user'},@{name=$label;id=[guid]::NewGuid().ToString();ownerId='foreign-owner'})
        (Resolve-ItlMemoryPrivateDataset $b $label $deadline).datasetId | Should -BeExactly $script:NativeDatasets[0].id
        & $posts | Should -Be 0
        @((Read-ItlMemoryJson $path).provider.datasets|Where-Object label -CEQ $label)[0].datasetId | Should -BeExactly $script:NativeDatasets[0].id
        # A reader never creates a dataset.
        & $unmap;$script:NativeDatasets=@()
        Resolve-ItlMemoryPrivateDataset $b $label $deadline -LookupOnly | Should -BeNullOrEmpty
        & $posts | Should -Be 0
        # A writer creates it once and confirms the single match.
        $created=Resolve-ItlMemoryPrivateDataset $b $label $deadline
        & $posts | Should -Be 1
        @($script:NativeDatasets).Count | Should -Be 1
        $created.datasetId | Should -BeExactly $script:NativeDatasets[0].id
        # Two matches after a creation: refused, and never created again.
        & $unmap;$script:NativeDatasets=@()
        Mock Invoke-ItlMemoryHttp {
            $script:Calls.Add(@{method=$Method;path=$Path;body=$Body})
            $script:NativeDatasets=@(@{name=$Body.name;id=[guid]::NewGuid().ToString();ownerId='ordinary-user'},@{name=$Body.name;id=[guid]::NewGuid().ToString();ownerId='ordinary-user'})
            return @{status=200;body=$script:NativeDatasets[0]}
        } -ParameterFilter {$Path -eq '/api/v1/datasets' -and $Method -eq 'POST'}
        {Resolve-ItlMemoryPrivateDataset $b $label $deadline} | Should -Throw '*MEMORY_DATASET_AMBIGUOUS*'
        & $posts | Should -Be 2
        {Resolve-ItlMemoryPrivateDataset $b $label $deadline} | Should -Throw '*MEMORY_DATASET_AMBIGUOUS*'
        & $posts | Should -Be 2
        @((Read-ItlMemoryJson $path).provider.datasets|Where-Object label -CEQ $label).Count | Should -Be 0
    }
    It 'shows a host note to another project on the same machine' {
        $evidence=@(@{source='user';reference='chat 2026-11-11'})
        $hostDataset=Get-ScopeDataset $b host
        $script:NativeDatasets=@(@{name=$hostDataset.label;id=$hostDataset.datasetId;ownerId='ordinary-user'})
        $saved=Invoke-ItlMemoryRemember $b 'Платформа 8.3.27 установлена в D:\1cv8.' $hostDataset.label 'platform' @{} $evidence verified
        $saved.state | Should -Be durable
        $other=New-MemoryFixture -ProjectId 'other-customer' -KeepBackend -LazyShared
        $other.identity.hostId | Should -BeExactly $b.identity.hostId
        @(Get-ItlMemoryScopes $other read|ForEach-Object {$_.scopeKind}) | Should -Not -Contain host
        $status=Invoke-ItlMemoryStatus $other
        @($status.index|Where-Object level -EQ host)[0].notes | Should -Be @('Платформа 8.3.27 установлена в D: 1cv8.')
        @($status.destinations|Where-Object scopeKind -EQ host)[0].label | Should -BeExactly $hostDataset.label
        # recall of the other project reads the same host dataset.
        $fresh=New-MemoryFixture -ProjectId 'third-customer' -KeepBackend -LazyShared
        Mock Invoke-ItlMemoryHttp {
            param($Provider,$Method,$Path,$Body)
            $script:Calls.Add(@{method=$Method;path=$Path;body=$Body})
            @{status=200;body=@(@{text='fragment';dataset_id=$hostDataset.datasetId;metadata=@{data_id=$saved.dataId}})}
        } -ParameterFilter {$Path -eq '/api/v1/recall'}
        $recall=Invoke-ItlMemoryRecall $fresh 'платформа на этой машине'
        $recall.cards[0].noteId | Should -BeExactly platform
        @($script:Calls|Where-Object path -EQ '/api/v1/recall')[-1].body.dataset_ids | Should -Contain $hostDataset.datasetId
        @($script:Calls|Where-Object {$_.method -eq 'POST' -and $_.path -eq '/api/v1/datasets'}).Count | Should -Be 0
        (Get-ItlMemoryLevelLimits).host.standing | Should -Be 3
        (Get-ItlMemoryLevelLimits).host.index | Should -Be 10
    }
    It 'runs the session-start, write and journal paths under the strict mode of the real server' {
        # cognee-memory-mcp.ps1 sets StrictMode 2: there a missing key or a
        # member of $null throws, which ordinary in-process tests do not see.
        # The binding is the persisted record, as the server reads it.
        $evidence=@(@{source='user';reference='chat 2026-11-11'})
        $path=Get-ItlMemoryPath binding $b.projectRoot
        $null=Update-ItlMemoryJson $path {param($current) $current.memoryProjection.knowledgeAreas=@{planning=@{availableIn=@('prof');memoryHomeProductId='corp'}};return $current}
        $project=Get-ProjectDataset $b;$product=Get-ScopeDataset $b product
        $rule=Add-FixtureNote $project 'rule' 'Никогда не меняй режим на клиенте.' -Standing -Title 'Режим на клиенте'
        $null=Add-FixtureNote $project 'guess' 'Возможно, причина в индексе.' -Status candidate
        $null=Add-FixtureNote $project 'legacy' 'Заметка прежней версии.' -LegacyName
        $null=Add-FixtureNote $product 'area-ok' 'Особенность планирования.' -Area planning -Title 'Планирование'
        $null=Add-FixtureNote $product 'area-no' 'Особенность продаж.' -Area sales -Title 'Продажи'
        # A workspace dataset that another copy created, not yet adopted here.
        $workspace=Get-ScopeDataset $b workspace
        $script:NativeDatasets=@(@{name=$workspace.label;id=$workspace.datasetId;ownerId='ordinary-user'})
        $null=Update-ItlMemoryJson $path {param($current) $current.provider.datasets=@($current.provider.datasets|Where-Object scopeKind -NE workspace);return $current}
        $strict=& {
            Set-StrictMode -Version 2
            $live=Resolve-ItlMemoryLiveBinding (Read-ItlMemoryJson $path) (Read-ItlMemoryJson $path)
            $binding=$live.binding
            $status=Invoke-ItlMemoryStatus $binding
            $saved=Invoke-ItlMemoryRemember $binding 'Правило под строгим режимом.' 'itl_project_customer' 'strict-rule' @{} $evidence standing -Title 'Строгий режим'
            $moved=Invoke-ItlMemoryRemember $binding 'Правило под строгим режимом.' 'itl_project_customer' 'strict-rule' @{} $evidence verified -DataId $saved.dataId
            $draft=try{Invoke-ItlMemoryRemember $binding 'Черновик без назначения' '' 'strict-draft' -ContextHold}catch{$_.Exception.Message}
            $recall=Invoke-ItlMemoryRecall $binding 'строгий режим'
            Add-ItlMemoryUsage $binding remember 'strict-session' 'ok' $saved
            Add-ItlMemoryUsage $binding recall 'strict-session' 'MEMORY_RECORD_BUSY: kind=receipt; repeat the same operation'
            $discarded=Invoke-ItlMemoryRetire $binding '' 'strict-draft'
            $retired=Invoke-ItlMemoryRetire $binding 'itl_project_customer' 'strict-rule'
            @{status=$status;saved=$saved;moved=$moved;draft=$draft;recall=$recall;summary=(Get-ItlMemoryUsageSummary $binding);line=(Get-ItlMemoryUsageLine $binding.projectRoot);discarded=$discarded;retired=$retired;local=(Invoke-ItlMemoryStatus $binding -LocalOnly)}
        }
        $strict.status.serverCoverage | Should -BeExactly bounded
        $strict.status.standing[0].dataId | Should -BeExactly $rule
        @($strict.status.index|Where-Object level -EQ project)[0].notes | Should -Be @('Заметка прежней версии.','Возможно, причина в индексе. [candidate]')
        @($strict.status.index|Where-Object level -EQ product)[0].notes | Should -Be @('Планирование')
        @($strict.status.destinations|Where-Object scopeKind -EQ workspace)[0].label | Should -BeExactly $workspace.label
        $strict.saved.state | Should -Be durable
        $strict.moved.operation | Should -Be updated
        $strict.draft | Should -Match '^MEMORY_CONTEXT_CHANGED'
        $strict.recall.coverage | Should -BeExactly bounded
        $strict.summary.saved | Should -Be 1
        $strict.summary.lastErrors[0] | Should -BeExactly 'MEMORY_RECORD_BUSY (receipt)'
        $strict.line | Should -Match 'recall: 1, remember: 1'
        $strict.discarded.state | Should -BeExactly 'discarded-unsent'
        $strict.retired.state | Should -BeExactly retired
        @($strict.local.destinations).Count | Should -BeGreaterThan 5
    }
    It 'journals each call without its text and summarizes the current cycle' {
        $evidence=@(@{source='user';reference='chat 2026-11-11'})
        $recall=Invoke-ItlMemoryRecall $b 'секретный запрос о клиенте'
        Add-ItlMemoryUsage $b recall 'session-1' 'ok' $recall
        $saved=Invoke-ItlMemoryRemember $b 'Факт для журнала.' 'itl_project_customer' 'journal' @{} $evidence verified
        Add-ItlMemoryUsage $b remember 'session-1' 'ok' $saved
        $updated=Invoke-ItlMemoryRemember $b 'Факт для журнала, уточнённый.' 'itl_project_customer' 'journal' @{} $evidence verified -DataId $saved.dataId
        $updated.operation | Should -Be updated
        Add-ItlMemoryUsage $b remember 'session-1' 'ok' $updated
        $trace=@{elapsedMs=900;stageMs=@{principal=20;discovery=30;search=800};failureStage='search';failureKind='transport'}
        Add-ItlMemoryUsage $b recall 'session-2' 'MEMORY_SOURCE_UNAVAILABLE: no current authorized original; do not use a cached fragment.' -Trace $trace
        Add-ItlMemoryUsage $b memory_status 'session-2' 'MEMORY_RECORD_INVALID: kind=pending; the record is not valid UTF-8 JSON.'
        Add-ItlMemoryUsage $b retire_note 'session-2' 'ok' (Invoke-ItlMemoryRetire $b 'itl_project_customer' 'journal')
        $path=Get-ItlMemoryPath usage $b.identity.workspaceId
        [IO.File]::ReadAllText($path,[Text.Encoding]::UTF8) | Should -Not -Match 'секретный|клиенте|Факт для журнала'
        $journal=Read-ItlMemoryJson $path
        @($journal.entries).Count | Should -Be 6
        $journal.entries[0].tool | Should -BeExactly recall
        $journal.entries[0].session | Should -BeExactly 'session-1'
        $journal.entries[0].cycleId | Should -BeExactly $b.cycleId
        $journal.entries[0].cards | Should -Be 0
        $journal.entries[1].scopeKind | Should -BeExactly project
        $journal.entries[2].scopeKind | Should -BeExactly project
        $journal.entries[0].Contains('elapsedMs') | Should -BeFalse
        $journal.entries[3].elapsedMs | Should -Be 900
        $journal.entries[3].stageMs.search | Should -Be 800
        $journal.entries[3].failureStage | Should -BeExactly search
        $journal.entries[3].readOutcome | Should -BeExactly failed
        $journal.entries[3].outcome | Should -BeExactly 'MEMORY_SOURCE_UNAVAILABLE'
        $journal.entries[4].outcome | Should -BeExactly 'MEMORY_RECORD_INVALID'
        $journal.entries[4].recordKind | Should -BeExactly pending
        $summary=Get-ItlMemoryUsageSummary $b
        $summary.recall | Should -Be 2
        $summary.remember | Should -Be 2
        $summary.saved | Should -Be 1
        $summary.updated | Should -Be 1
        $summary.retired | Should -Be 1
        $summary.errors | Should -Be 2
        $summary.sessions | Should -Be 2
        $summary.lastErrors[-1] | Should -BeExactly 'MEMORY_RECORD_INVALID (pending)'
        # vibecoding1c-mcp-status shows the same summary.
        (Invoke-ItlMemorySetup status).usage.recall | Should -Be 2
        # Another task cycle starts from zero; the journal keeps 200 entries.
        $nextCycle=ConvertTo-ItlCatalogCanonicalValue $b;$nextCycle.cycleId='next-cycle'
        $null=Update-ItlMemoryJson $path {param($old) $old.entries=@($old.entries)+@(1..197|ForEach-Object {[ordered]@{at='2026-11-11T10:00:00Z';tool='recall';session='session-3';cycleId='next-cycle';outcome='ok';cards=0}});return $old}
        foreach($number in 1..3){Add-ItlMemoryUsage $nextCycle recall 'session-3' 'ok' @{cards=@()}}
        $bounded=@((Read-ItlMemoryJson $path).entries)
        $bounded.Count | Should -Be 200
        # The oldest entries leave first: six of the first cycle, then 197+3.
        @($bounded|Where-Object {$_.cycleId -ceq $b.cycleId}).Count | Should -Be 0
        (Get-ItlMemoryUsageSummary $nextCycle).recall | Should -Be 200
        (Get-ItlMemoryUsageSummary $nextCycle).remember | Should -Be 0
        # A journal that cannot be written never changes the call.
        Remove-Item -LiteralPath $path
        [void][IO.Directory]::CreateDirectory($path)
        {Add-ItlMemoryUsage $b recall 'session-4' 'ok' $recall} | Should -Not -Throw
    }
    It 'prints an informational memory line after a check only while memory is enabled' {
        Mock Write-Host {}
        Write-DevBranchMemoryUsageNote
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {[string]$Object -match 'recall: 0, remember: 0'}
        Should -Invoke Write-Host -Times 1 -Exactly
        # A damaged journal never fails or blocks the check.
        $usagePath=Get-ItlMemoryPath usage $b.identity.workspaceId
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $usagePath))
        [IO.File]::WriteAllText($usagePath,'{ broken')
        {Write-DevBranchMemoryUsageNote} | Should -Not -Throw
        Remove-Item -LiteralPath $usagePath
        Mock Write-Vibecoding1cMcpClientConfig {}
        $null=Invoke-ItlMemorySetup disable -Client cursor
        Write-DevBranchMemoryUsageNote
        Should -Invoke Write-Host -Times 1 -Exactly
        # The check prints it only after its own successful report.
        $lifecycle=[IO.File]::ReadAllText((Join-Path $RepoRoot '.agents/skills/1c-workflow/scripts/lib/agent-1c.lifecycle.ps1'),[Text.Encoding]::UTF8)
        $lifecycle | Should -Match 'Write-DevBranchVerificationRunUserReport -State \$verifiedState -PlatformPreparation \$platformPreparation\r?\n\s+Write-DevBranchMemoryUsageNote\r?\n\s+\} catch \{'
    }
}
