Describe 'Catalog runtime context is pinned by the existing registry operation' {
    BeforeAll {
        $RepoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
        . (Join-Path $RepoRoot 'scripts/git-path-list.ps1')
        foreach($leaf in @('core','vanessa','vibecoding1c-mcp','product-catalog','product-project-context','product-source-evidence')){. (Join-Path $RepoRoot ".agents/skills/1c-workflow/scripts/lib/agent-1c.$leaf.ps1")}
        function New-ContextFixture {
            $code=@{id='code';family='vibecoding1c';scope='project';configId='corp';url='http://source-a.invalid:22100/mcp'}
            $graph=@{id='graph';family='vibecoding1c';scope='project';configId='other';url='http://source-b.invalid:22101/mcp/'}
            $docs=@{id='bookstack';family='vibecoding1c';scope='global';url='http://source-a.invalid:18005/mcp';viewBindings=@(@{viewId='corp';url='http://source-a.invalid:18005/mcp?view=corp';capability='product-docs-view-v1'})}
            return @{
                registry=@{schemaVersion=2;hosts=@(@{hostId='a';configurations=@(@{id='corp'});servers=@($code,$docs)},@{hostId='b';configurations=@(@{id='other'});servers=@($graph)})}
                catalog=@{schemaVersion=1;products=@(@{productId='corp';name='PM5 CORP';baseConfigurationVersion='PM5';roles=@{code=@{mode='own';sourceId='code'};graph=@{mode='own';sourceId='graph'};productDocs=@{mode='own';sourceId='docs'}}});projects=@(@{projectId='development';name='Development';productId='corp'});profiles=@();sources=@(
                    @{sourceId='code';role='code';endpoint=@{hostId='a';serverId='code';configId='corp'};namespace='same-native-id'},
                    @{sourceId='graph';role='graph';endpoint=@{hostId='b';serverId='graph';configId='other'};namespace='default'},
                    @{sourceId='docs';role='productDocs';endpoint=@{hostId='a';serverId='bookstack'};binding=@{mode='view';viewId='corp'}});instances=@()}
                relations=@{schemaVersion=1;relations=@();knowledgeAreas=@{}}
                catalogRevision=('a'*40);inputGitObjectIds=@{}
            }
        }
    }
    BeforeEach {
        $script:McpProvider='';$script:McpServerId=''
        $snapshot=New-ContextFixture
        $binding=@{schemaVersion=1;requiredCapability='product-project-registry-v1';projectId='development';productId='corp'}
        $script:Config=[pscustomobject]@{productProject=[pscustomobject]$binding}
        $previousRegistry=[Environment]::GetEnvironmentVariable('VIBECODING1C_MCP_REGISTRY_PATH','Process')
    }
    It 'uses registry versions and a successful legacy Code read without requiring index stamps' {
        $snapshot.registry.hosts[0].configurations[0].configurationName='PM5 CORP'
        $snapshot.registry.hosts[0].configurations[0].configurationVersion='5.0.3.59'
        $snapshot.registry.hosts[0].configurations[0].nightlyIndexStatus='succeeded'
        $snapshot.registry.hosts[0].configurations[0].indexedAt='2026-10-21T00:00:00Z'
        $context=Resolve-ItlProductProjectRuntimeContext $snapshot $binding
        $context.endpointIntents.code.registry.configurationVersion|Should -Be '5.0.3.59'
        $context.endpointIntents.code.registry.provenance|Should -Be registry
        $context.projectContext.customized|Should -BeNullOrEmpty
        function New-Exchange($id,$name,$payload){@{request=@{id=$id;method='tools/call';params=@{name=$name;arguments=@{module_path='CommonModules/Модуль с пробелом/Ext/Module.bsl'}}};response=@{id=$id;result=@{isError=$false;structuredContent=$payload}}}}
        $observation=@{checkedAt='2026-10-21T00:00:00Z';endpoint=$context.endpointIntents.code.url;transport='external-probe';metadata=(New-Exchange 1 stats @{status='success';data=@{project_id='same-native-id';configurationVersion='other-current-file'}});read=(New-Exchange 2 get_module_structure @{status='success';data=@{name='Модуль с пробелом'}})}
        $before=Get-ItlCatalogHash $context
        $proof=Compare-ItlProductSourceObservation $context code $observation
        $proof.binding|Should -Be matched
        $proof.clientActivation|Should -Be unverified
        $proof.Contains('registry')|Should -BeFalse # Already present once in the selected source context.
        $proof.Contains('indexedVersion')|Should -BeFalse
        $observation.transport='native-client'
        $observation.client=@{serverName='1c-code-metadata-mcp';sessionId='private-thread';loadedEndpoint=$observation.endpoint;requestIds=@(1,2)}
        (Compare-ItlProductSourceObservation $context code $observation).clientActivation|Should -Be unverified
        foreach($call in @($observation.metadata,$observation.read)){
            $call.request.method='mcpServer/tool/call'
            $call.request.params=@{threadId='private-thread';server='1c-code-metadata-mcp';tool=$call.request.params.name;arguments=$call.request.params.arguments}
        }
        (Compare-ItlProductSourceObservation $context code $observation).clientActivation|Should -Be matched
        $observation.Remove('metadata')
        (Compare-ItlProductSourceObservation $context code $observation).binding|Should -Be matched
        (Compare-ItlProductSourceObservation $context code $observation).clientActivation|Should -Be matched
        $context.endpointIntents.code.versionPin=@{configurationVersion='5.0.3.60'}
        $pinned=Compare-ItlProductSourceObservation $context code $observation
        $pinned.binding|Should -Be matched
        $pinned.versionConstraint|Should -Be mismatch
        $context.endpointIntents.code.versionPin=@{}
        (Get-ItlCatalogHash $context)|Should -BeExactly $before
        $path=Join-Path $TestDrive 'наблюдение с пробелом.json'
        @{schemaVersion=1;catalogRevision=$context.catalogRevision;settingsHash=$context.settingsHash;roles=@{code=$observation}}|ConvertTo-Json -Depth 30|Set-Content -LiteralPath $path -Encoding UTF8
        (Read-ItlProductSourceObservations $context $path).roles.code.binding|Should -Be matched
        $context.catalogRevision='d'*40
        (Read-ItlProductSourceObservations $context $path).status|Should -Be unverified
        $observation.endpoint='http://wrong.invalid/mcp'
        (Compare-ItlProductSourceObservation $context code $observation).binding|Should -Be mismatch
        $observation.endpoint=$context.endpointIntents.code.url
        $observation.read.response.result.isError=$true
        (Compare-ItlProductSourceObservation $context code $observation).binding|Should -Be unverified
    }
    It 'accepts supported Graph scope with inherited data and rejects an actual wrong selector' {
        $snapshot.catalog.sources[1].binding=@{mode='dedicated';nativeProjectId='pm5corp';sourceKey='retained-optional-legacy-key'}
        $context=Resolve-ItlProductProjectRuntimeContext $snapshot $binding
        $observation=@{checkedAt='2026-10-21T00:00:00Z';endpoint=$context.endpointIntents.graph.url;transport='external-probe'}
        $meta=@{contract_version='2.0';context=@{project_id=$null;mcp_namespace=$null};data=@{project_id='pm5corp';mcp_namespace='default';is_accessible=$true;active_generation=$null;ingestion_state='inherited'}}
        $read=@{contract_version='2.0';context=@{project_id='pm5corp';mcp_namespace='default'};returned=1;text='bounded fulltext fixture'}
        $observation.metadata=@{request=@{id=1;method='tools/call';params=@{name='get_graph_project_status';arguments=@{project_id='pm5corp'}}};response=@{id=1;result=@{structuredContent=$meta}}}
        $observation.read=@{request=@{id=2;method='tools/call';params=@{name='search_code';arguments=@{project_id='pm5corp';search_type='fulltext'}}};response=@{id=2;result=@{structuredContent=$read}}}
        (Compare-ItlProductSourceObservation $context graph $observation).binding|Should -Be matched
        $read.context.mcp_namespace='wrong'
        (Compare-ItlProductSourceObservation $context graph $observation).binding|Should -Be mismatch
        $read.context.mcp_namespace='default'
        $observation.read.request.params.arguments.project_id='foreign'
        (Compare-ItlProductSourceObservation $context graph $observation).binding|Should -Be mismatch
        $observation.read.request.params.arguments.project_id='pm5corp'
        $observation.Remove('metadata')
        (Compare-ItlProductSourceObservation $context graph $observation).binding|Should -Be matched
        $read.returned=0
        (Compare-ItlProductSourceObservation $context graph $observation).binding|Should -Be unverified
    }
    It 'keeps explicit registry version pins optional and rejects empty or oversized constraints' {
        $snapshot.catalog.sources[0].binding=@{mode='dedicated';versionPin=@{configurationVersion='5.0.1'}}
        $null=Assert-ItlProductCatalog $snapshot.catalog $snapshot.relations $snapshot.registry
        (Resolve-ItlProductProjectRuntimeContext $snapshot $binding).endpointIntents.code.versionPin.configurationVersion|Should -Be '5.0.1'
        $snapshot.catalog.sources[0].binding.versionPin=@{}
        {Assert-ItlProductCatalog $snapshot.catalog $snapshot.relations $snapshot.registry}|Should -Throw '*at least 1 properties*'
        $snapshot.catalog.sources[0].binding.versionPin=@{configurationVersion=('x'*129)}
        {Assert-ItlProductCatalog $snapshot.catalog $snapshot.relations $snapshot.registry}|Should -Throw '*maxLength*'
    }
    It 'shows custom project differences and the explicitly selected typical source without mutating business IDs' {
        $snapshot.catalog.sources[0].origin=@{productId='corp'}
        $snapshot.catalog.projects[0].customized=$true
        $snapshot.catalog.projects[0].customizations=@{summary='Клиентский расчёт с доработками';references=@('https://docs.invalid/customer')}
        $snapshot.catalog.projects[0].roles=@{code=@{mode='inherit';usage='base-product';limitations=@{summary='Типовой источник не описывает доработки'}}}
        $context=Resolve-ItlProductProjectRuntimeContext $snapshot $binding
        $context.projectId|Should -Be development
        $context.roles.code.source.origin.productId|Should -Be corp
        $context.roles.code.usage|Should -Be base-product
        $context.projectContext.customizations.summary|Should -Be 'Клиентский расчёт с доработками'
        $summary=@(Get-ItlProductProjectSourceSummary $context)|Where-Object role -eq code
        $summary.origin.productName|Should -Be 'PM5 CORP'
        $summary.descriptionStatus|Should -Be declared
        $summary.limitations.summary|Should -Be 'Типовой источник не описывает доработки'
        $preview=Show-ItlProductProjectPreview @{context=$context;changes=@()}
        $preview.projectDifferences.customized|Should -BeTrue
        $preview.sources[0].usage|Should -Be base-product
        $initialSettings=$context.settingsHash;$initialKnowledge=$context.knowledgeHash
        $snapshot.catalog.projects[0].customizations.summary='Уточнённый расчёт'
        $changed=Resolve-ItlProductProjectRuntimeContext $snapshot $binding
        $changed.settingsHash|Should -Be $initialSettings
        $changed.knowledgeHash|Should -Not -Be $initialKnowledge
        (Get-ItlProductProjectResolvedHash $changed)|Should -Not -Be (Get-ItlProductProjectResolvedHash $context)
    }
    It 'allows PROF to use CORP while the existing applicability owner excludes CORP-only functionality' {
        $snapshot.catalog.products+=@(@{productId='prof';name='PM5 PROF';baseConfigurationVersion='PM5'})
        $snapshot.catalog.projects[0].productId='prof'
        $snapshot.catalog.projects[0].roles=@{code=@{mode='own';sourceId='code';usage='reference-product';limitations=@{summary='Проверять доступность по карте ПРОФ'}}}
        $snapshot.catalog.sources[0].origin=@{productId='corp'}
        $snapshot.relations.knowledgeAreas=@{common=@{title='Common';availableIn=@('corp','prof');memoryHomeProductId='corp'};removed=@{title='CORP only';availableIn=@('corp')}}
        $binding.productId='prof'
        $context=Resolve-ItlProductProjectRuntimeContext $snapshot $binding
        $context.productId|Should -Be prof
        $context.roles.code.source.origin.productId|Should -Be corp
        (@(Get-ItlProductProjectSourceSummary $context)|Where-Object role -eq code).descriptionStatus|Should -Be declared
        $note=@{origin=@{source='registry-source';revision=$snapshot.catalogRevision};evidence=@(@{source='registry-source';revision=$snapshot.catalogRevision;result='read'});applicability=@{knowledgeAreas=@('removed');verificationState='verified'}}
        (Resolve-ItlProductKnowledge $snapshot prof $note).status|Should -Be not-applicable
        $note.applicability.knowledgeAreas=@('common')
        (Resolve-ItlProductKnowledge $snapshot prof $note).status|Should -Be applicable
    }
    It 'does not infer absent source origin or usage and keeps disabled overrides' {
        $context=Resolve-ItlProductProjectRuntimeContext $snapshot $binding
        (@(Get-ItlProductProjectSourceSummary $context)|Where-Object role -eq code).descriptionStatus|Should -Be incomplete
        $context.roles.code.source.origin|Should -BeNullOrEmpty
        $context=Resolve-ItlProductProjectRuntimeContext $snapshot $binding -Overrides @{roles=@{code=@{mode='disabled'}}}
        @($context.endpointIntents.Keys)|Should -Not -Contain code
        @((Get-ItlProductProjectSourceSummary $context)|Where-Object role -eq code).Count|Should -Be 0
    }
    It 'validates explicit origin references and bounded notes in catalog and private overrides' {
        $snapshot.catalog.sources[0].origin=@{productId='missing'}
        {Resolve-ItlProductProjectRuntimeContext $snapshot $binding}|Should -Throw '*origin.productId*'
        $snapshot.catalog.sources[0].origin=@{productId='corp';projectId='missing'}
        {Resolve-ItlProductProjectRuntimeContext $snapshot $binding}|Should -Throw '*origin.projectId*'
        $snapshot.catalog.sources[0].origin=@{productId='corp';projectId='development'}
        $snapshot.catalog.projects[0].customizations=@{summary=('x'*513)}
        {Resolve-ItlProductProjectRuntimeContext $snapshot $binding}|Should -Throw '*maxLength*'
        $snapshot.catalog.projects[0].customizations=@{summary='Declared';references=@(1..9|ForEach-Object {'ref-'+$_})}
        {Resolve-ItlProductProjectRuntimeContext $snapshot $binding}|Should -Throw '*maxItems*'
        $snapshot.catalog.projects[0].Remove('customizations')
        {Resolve-ItlProductProjectRuntimeContext $snapshot $binding -Overrides @{roles=@{code=@{mode='inherit';usage='guessed'}}}}|Should -Throw '*unsupported value*'
        {Resolve-ItlProductProjectRuntimeContext $snapshot $binding -Overrides @{roles=@{code=@{mode='inherit';limitations=@{summary=('x'*513)}}}}}|Should -Throw '*maxLength*'
        $context=Resolve-ItlProductProjectRuntimeContext $snapshot $binding -Overrides @{roles=@{code=@{mode='inherit';usage='project'}}}
        (@(Get-ItlProductProjectSourceSummary $context)|Where-Object role -eq code).descriptionStatus|Should -Be declared
    }
    AfterEach {
        [Environment]::SetEnvironmentVariable('VIBECODING1C_MCP_REGISTRY_PATH',$previousRegistry,'Process')
        Remove-Variable ItlMcpRegistryOperation -Scope Script -ErrorAction SilentlyContinue
    }
    It 'keeps independent role hosts/configurations and the exact published view URL as unverified intent' {
        $context=Resolve-ItlProductProjectRuntimeContext $snapshot $binding
        $context.endpointIntents.code.hostId | Should -Be a
        $context.endpointIntents.graph.hostId | Should -Be b
        $context.endpointIntents.graph.configId | Should -Be other
        $context.endpointIntents.productDocs.url | Should -Be 'http://source-a.invalid:18005/mcp?view=corp'
        $context.endpointIntents.code.readiness | Should -Be unverified
        $context.baseConfigurationVersion | Should -Be PM5
        $context.projectName | Should -Be Development
    }
    It 'does not replace an absent/foreign view with the global docs URL' {
        $snapshot.registry.hosts[0].servers[1].viewBindings=@()
        {Resolve-ItlProductProjectRuntimeContext $snapshot $binding} | Should -Throw '*CATALOG_SOURCE_VIEW_UNAVAILABLE*'
        $snapshot=New-ContextFixture
        $snapshot.registry.hosts[0].servers[1].viewBindings[0].url='http://foreign.invalid/mcp?view=corp'
        {Resolve-ItlProductProjectRuntimeContext $snapshot $binding} | Should -Throw '*changes this source public origin*'
    }
    It 'selects one of multiple server-bound views without widening to another product' {
        $snapshot.registry.hosts[0].servers[1].viewBindings=@(@{viewId='foreign';url='http://source-a.invalid:18005/mcp?view=foreign';capability='product-docs-view-v1'},$snapshot.registry.hosts[0].servers[1].viewBindings[0])
        (Resolve-ItlProductProjectRuntimeContext $snapshot $binding).endpointIntents.productDocs.url|Should -Be 'http://source-a.invalid:18005/mcp?view=corp'
    }
    It 'never changes the tracked base product implicitly' {
        $binding.productId='another'
        {Resolve-ItlProductProjectRuntimeContext $snapshot $binding} | Should -Throw '*CATALOG_PRODUCT_CHANGED*'
    }
    It 'checks binding capability before accepting IDs and leaves legacy unbound' {
        (Get-ItlProductProjectBinding).projectId | Should -Be development
        $script:Config=[pscustomobject]@{}
        Get-ItlProductProjectBinding | Should -BeNullOrEmpty
        $binding.requiredCapability='future-v9';$script:Config=[pscustomobject]@{productProject=$binding}
        {Get-ItlProductProjectBinding}|Should -Throw '*CATALOG_BINDING_CAPABILITY*'
    }
    It 'routes bug and feature creation independently without changing the writer operation ID' {
        $context=Resolve-ItlProductProjectRuntimeContext $snapshot $binding
        $context.links.mantis=@{value=@{instanceId='tracker';projectIds=@(12,23);searchProjectIds=@(12,23);createRoutes=@{bug=12;feature=23}};provenance='project:development'}
        $search=Get-ItlProductProjectIntegrationIntent $context mantis-search
        $search.filters.project_ids|Should -Be @(12,23)
        $search.scopeIsAccessControl|Should -BeFalse
        $context.links.mantis.value.searchProjectIds=@()
        (Get-ItlProductProjectIntegrationIntent $context mantis-search).filters.Contains('project_ids')|Should -BeTrue
        @((Get-ItlProductProjectIntegrationIntent $context mantis-search).filters.project_ids).Count|Should -Be 0
        $steps=@(@{action='create_issue';fields=@{summary='Fixture';description='Harmless fixture'}})
        $bug=New-ItlProductProjectMantisWriteArguments $context bug 'same-operation' $steps
        $feature=New-ItlProductProjectMantisWriteArguments $context feature 'other-operation' $steps
        $bug.operation_id|Should -Be same-operation
        $bug.steps[0].project_id|Should -Be 12
        $feature.steps[0].project_id|Should -Be 23
        (New-ItlProductProjectMantisWriteArguments $context bug 'same-operation' $steps|ConvertTo-Json -Depth 12 -Compress)|Should -BeExactly ($bug|ConvertTo-Json -Depth 12 -Compress)
        $steps[0].Contains('project_id')|Should -BeFalse
        {New-ItlProductProjectMantisWriteArguments $context missing 'same-operation' $steps}|Should -Throw '*CATALOG_MANTIS_ROUTE_REQUIRED*'
        (New-ItlProductProjectMantisWriteArguments $context missing 'same-operation' $steps -ExplicitProjectId 42).steps[0].project_id|Should -Be 42
    }
    It 'keeps explicit issue reads global and exact SPPR links separate from similarity search' {
        $context=Resolve-ItlProductProjectRuntimeContext $snapshot $binding
        (Get-ItlProductProjectIntegrationIntent $context mantis-search -IssueId 777).filters.Count|Should -Be 0
        (Get-ItlProductProjectIntegrationIntent $context sppr-exact).status|Should -Be unlinked
        $context.links.sppr=@{value=@{instanceId='s';projectId='11111111-1111-1111-1111-111111111111'};provenance='project:development'}
        $intent=Get-ItlProductProjectIntegrationIntent $context sppr-exact
        $intent.exactLink.projectId|Should -Be '11111111-1111-1111-1111-111111111111'
        $intent.similarity|Should -Be independent-search-evidence
        $intent.nativeReadiness|Should -Be unverified
    }
    It 'classifies every current dispatcher action and all broker operations without expanding their guards' {
        $tokens=$null;$errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot '.agents/skills/1c-workflow/scripts/agent-1c.ps1'),[ref]$tokens,[ref]$errors)
        $actions=@(($ast.ParamBlock.Parameters|Where-Object {$_.Name.VariablePath.UserPath -eq 'Action'}).Attributes|Where-Object {$_.TypeName.Name -eq 'ValidateSet'}|ForEach-Object {$_.PositionalArguments.Value})
        $brokers=@(($ast.ParamBlock.Parameters|Where-Object {$_.Name.VariablePath.UserPath -eq 'InternalOnDemandOperation'}).Attributes|Where-Object {$_.TypeName.Name -eq 'ValidateSet'}|ForEach-Object {$_.PositionalArguments.Value}|Where-Object {$_})
        # The ninth ValidateSet value is the empty "not a broker" option.
        $actions.Count|Should -Be 96;$brokers.Count|Should -Be 8
        foreach($action in $actions){
            $actual=Get-ItlProductProjectStartupDisposition $action
            $actual|Should -BeIn @('diagnostic','bootstrap','inherited-runtime','project-operation')
            if($actual -eq 'project-operation'){(Test-Agent1cActionRequiresLifecycleLock $action)|Should -BeTrue}
        }
        foreach($broker in $brokers){(Get-ItlProductProjectStartupDisposition 'status' '' $broker)|Should -Be inherited-broker}
        foreach($action in @('help','doctor','status','vibecoding1c-mcp-status','openspec-context')){(Get-ItlProductProjectStartupDisposition $action)|Should -Be diagnostic}
        (Get-ItlProductProjectStartupDisposition 'vibecoding1c-mcp-select' 'restore')|Should -Be explicit-recovery
        (Get-ItlProductProjectStartupDisposition 'update-workflow' '' '' 'restore')|Should -Be explicit-recovery
    }
    It 'reads all catalog inputs from one SHA and shares it through nested consumers after the tip moves' {
        $root=Join-Path $TestDrive 'Pinned registry'
        [void][IO.Directory]::CreateDirectory((Join-Path $root 'catalog'))
        $null=Invoke-RepositoryGit $root @('init','-b','main')
        $null=Invoke-RepositoryGit $root @('config','user.email','fixture@example.test')
        $null=Invoke-RepositoryGit $root @('config','user.name','Fixture')
        foreach($pair in @(@('registry.json',$snapshot.registry),@('catalog/catalog.json',$snapshot.catalog),@('catalog/product-relations.json',$snapshot.relations))){[IO.File]::WriteAllText((Join-Path $root $pair[0]),($pair[1]|ConvertTo-Json -Depth 40),[Text.UTF8Encoding]::new($false))}
        $null=Invoke-RepositoryGit $root @('add','.')
        $null=Invoke-RepositoryGit $root @('commit','-m','first')
        [Environment]::SetEnvironmentVariable('VIBECODING1C_MCP_REGISTRY_PATH',$root,'Process')
        Mock Update-Vibecoding1cMcpRegistryCheckout {return $root}
        Invoke-Vibecoding1cMcpRegistryOperation {
            $one=Read-ItlProductProjectSnapshot
            $null=Invoke-RepositoryGit $root @('commit','--allow-empty','-m','second')
            Invoke-Vibecoding1cMcpRegistryOperation {
                $two=Read-ItlProductProjectSnapshot
                $two.catalogRevision|Should -Be $one.catalogRevision
                (Read-Vibecoding1cMcpRegistry).hosts[0].hostId|Should -Be a
            }
        }
        Should -Invoke Update-Vibecoding1cMcpRegistryCheckout -Times 1 -Exactly
    }
    It 'reuses checked inputs before decoding blobs and lazily reads the same SHA after the tip moves' {
        $root=Join-Path $TestDrive 'Pinned early reuse'
        [void][IO.Directory]::CreateDirectory((Join-Path $root 'catalog'))
        $null=Invoke-RepositoryGit $root @('init','-b','main')
        $null=Invoke-RepositoryGit $root @('config','user.email','fixture@example.test')
        $null=Invoke-RepositoryGit $root @('config','user.name','Fixture')
        foreach($pair in @(@('registry.json',$snapshot.registry),@('catalog/catalog.json',$snapshot.catalog),@('catalog/product-relations.json',$snapshot.relations))){[IO.File]::WriteAllText((Join-Path $root $pair[0]),($pair[1]|ConvertTo-Json -Depth 40),[Text.UTF8Encoding]::new($false))}
        $null=Invoke-RepositoryGit $root @('add','.')
        $null=Invoke-RepositoryGit $root @('commit','-m','first')
        $first=Read-ItlProductCatalogSnapshot $root HEAD
        $hint=@{configurationState='configured';catalogRevision=$first.catalogRevision;context=@{registryMetadata=$first.registry};proof=@{};noOpInputs=@{files=@{};includeClientSurfaces=$false}}
        [Environment]::SetEnvironmentVariable('VIBECODING1C_MCP_REGISTRY_PATH',$root,'Process')
        $script:UnmockedSnapshotReader=${function:Read-ItlProductCatalogSnapshot}
        Mock Update-Vibecoding1cMcpRegistryCheckout {return $root}
        Mock Get-ItlProductProjectNoOpInputs {return $hint.noOpInputs}
        Mock Read-ItlProductCatalogSnapshot {& $script:UnmockedSnapshotReader -RepositoryRoot $RepositoryRoot -Commit $Commit}
        Invoke-Vibecoding1cMcpRegistryOperation {
            (Read-ItlProductProjectSnapshot -NoOpApplied $hint).reusedAppliedContext|Should -Not -BeNullOrEmpty
            Should -Invoke Read-ItlProductCatalogSnapshot -Times 0
            $null=Invoke-RepositoryGit $root @('commit','--allow-empty','-m','second')
            Invoke-Vibecoding1cMcpRegistryOperation {
                (Read-ItlProductProjectSnapshot -NoOpApplied $hint).catalogRevision|Should -Be $first.catalogRevision
                (Read-ItlProductProjectSnapshot).catalogRevision|Should -Be $first.catalogRevision
                (Read-Vibecoding1cMcpRegistry).hosts[0].hostId|Should -Be a
            }
        }
        Should -Invoke Read-ItlProductCatalogSnapshot -Times 1 -Exactly -ParameterFilter {$Commit -ceq $first.catalogRevision}
        Should -Invoke Update-Vibecoding1cMcpRegistryCheckout -Times 1 -Exactly
        Invoke-Vibecoding1cMcpRegistryOperation {
            $next=Read-ItlProductProjectSnapshot -NoOpApplied $hint
            $next.catalogRevision|Should -Not -Be $first.catalogRevision
            $next.catalog.products.Count|Should -Be 1
        }
        Should -Invoke Read-ItlProductCatalogSnapshot -Times 2 -Exactly
        Should -Invoke Update-Vibecoding1cMcpRegistryCheckout -Times 2 -Exactly
    }
    It 'remembers failed refresh for the operation without nested retries or writable fallback' {
        [Environment]::SetEnvironmentVariable('VIBECODING1C_MCP_REGISTRY_PATH',(Join-Path $TestDrive 'No valid cache'),'Process')
        Mock Update-Vibecoding1cMcpRegistryCheckout {throw 'fixture unavailable'}
        Invoke-Vibecoding1cMcpRegistryOperation {
            {Read-ItlProductProjectSnapshot}|Should -Throw '*CATALOG_REFRESH_UNAVAILABLE*'
            {Read-ItlProductProjectSnapshot}|Should -Throw '*CATALOG_REFRESH_UNAVAILABLE*'
        }
        Should -Invoke Update-Vibecoding1cMcpRegistryCheckout -Times 1 -Exactly
    }
    It 'uses the validated cached reference when refresh fails without retrying the network' {
        Mock Update-Vibecoding1cMcpRegistryCheckout {throw 'Fixture offline'}
        Mock Read-ItlProductProjectSetting {return @{catalogRevision=('a'*40)}}
        Mock Read-ItlProductCatalogSnapshot {return $snapshot}
        Invoke-Vibecoding1cMcpRegistryOperation {
            $cached=Read-ItlProductProjectSnapshot
            $cached.stale|Should -BeTrue
            $cached.catalogRevision|Should -Be ('a'*40)
            (Read-ItlProductProjectSnapshot).catalogRevision|Should -Be $cached.catalogRevision
        }
        Should -Invoke Update-Vibecoding1cMcpRegistryCheckout -Times 1 -Exactly
        Should -Invoke Read-ItlProductCatalogSnapshot -Times 1 -Exactly -ParameterFilter {$Commit -ceq ('a'*40)}
    }
    It 'reuses the ordinary endpoint/request producers with canonical role names and shared MCPs' {
        $context=Resolve-ItlProductProjectRuntimeContext $snapshot $binding
        $script:ProjectRoot=Join-Path $TestDrive 'Project'
        Mock Read-Vibecoding1cMcpRegistry {return $snapshot.registry}
        Mock Read-Vibecoding1cMcpSelection {return @{servers=@()}}
        Mock Select-Vibecoding1cMcpManifestServers {return @()}
        Mock Get-Vibecoding1cMcpCurrentEndpoints {return @(@{id='syntax';url='http://shared.invalid/mcp';scope='global'},@{id='code';url='http://legacy.invalid/mcp';scope='project'})}
        $set=Get-Vibecoding1cMcpClientConfigEndpointSet -ProductContext $context
        @($set.allEndpoints).Count|Should -Be 4
        $names=@($set.allEndpoints|ForEach-Object {Get-Vibecoding1cMcpEndpointClientName $_})
        $names|Should -Contain '1c-code-metadata-mcp'
        $names|Should -Contain '1c-graph-metadata-mcp'
        $names|Should -Contain 'BookStack-product-docs-mcp'
        ($set.allEndpoints|Where-Object id -eq code).url|Should -Be 'http://source-a.invalid:22100/mcp'
        ($set.allEndpoints|Where-Object id -eq bookstack).status|Should -Be unknown
        $requests=@(Write-Vibecoding1cMcpClientConfig -Clients @('codex','opencode') -EndpointSet $set -ReturnRequests)
        $requests.Count|Should -Be 2
        $requests[1].endpoints.name|Should -Contain 'BookStack-product-docs-mcp'
        $requests[1].endpoints.url|Should -Not -Contain 'http://legacy.invalid/mcp'
        Test-Path -LiteralPath $script:ProjectRoot|Should -BeFalse
    }
    It 'retains the PM4 product-docs guard even when a catalog record declares that role' {
        $snapshot.catalog.products[0].baseConfigurationVersion='PM4'
        $script:Config=[pscustomobject]@{baseConfigurationVersion='PM4';productProject=$binding}
        $context=Resolve-ItlProductProjectRuntimeContext $snapshot $binding
        $script:ProjectRoot=Join-Path $TestDrive 'PM4 catalog project'
        Mock Read-Vibecoding1cMcpRegistry {return $snapshot.registry}
        Mock Read-Vibecoding1cMcpSelection {return @{servers=@()}}
        Mock Select-Vibecoding1cMcpManifestServers {return @()}
        Mock Get-Vibecoding1cMcpCurrentEndpoints {return @()}
        $set=Get-Vibecoding1cMcpClientConfigEndpointSet -ProductContext $context
        @($set.allEndpoints|Where-Object {$_.id -eq 'bookstack'}).Count|Should -Be 0
        $set.roleOverrides.productDocs.mode|Should -Be disabled-by-policy
    }
    It 'preserves an explicit local disabled selection and scopes the resolved context by root' {
        $context=Resolve-ItlProductProjectRuntimeContext $snapshot $binding
        $script:ProjectRoot=Join-Path $TestDrive 'First'
        Mock Read-Vibecoding1cMcpRegistry {return $snapshot.registry}
        Mock Read-Vibecoding1cMcpSelection {return @{servers=@(@{id='code';enabled=$false})}}
        Mock Select-Vibecoding1cMcpManifestServers {return @()}
        Mock Get-Vibecoding1cMcpCurrentEndpoints {return @()}
        Invoke-Vibecoding1cMcpRegistryOperation {
            Set-ItlProductProjectOperationContext $context
            $set=Get-Vibecoding1cMcpClientConfigEndpointSet
            @($set.allEndpoints|Where-Object id -eq code).Count|Should -Be 0
            $script:ProjectRoot=Join-Path $TestDrive 'Second'
            Get-ItlProductProjectOperationContext|Should -BeNullOrEmpty
        }
    }
}
