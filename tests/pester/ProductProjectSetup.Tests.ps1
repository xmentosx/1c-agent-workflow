Describe 'Explicit catalog setup and bootstrap keep one selected context' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $RepoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
        $HelperPath=Join-Path $RepoRoot '.agents/skills/1c-workflow/scripts/agent-1c.ps1'
        function New-SetupCatalogFixture {
            return @{catalogRevision=('a'*40);inputGitObjectIds=@{};registry=@{schemaVersion=2;hosts=@()};relations=@{schemaVersion=1;relations=@();knowledgeAreas=@{}};catalog=@{schemaVersion=1;products=@(@{productId='pm4';name='PM4';baseConfigurationVersion='PM4'},@{productId='pm5';name='PM5';baseConfigurationVersion='PM5'});projects=@(@{projectId='four';name='Four';productId='pm4'},@{projectId='five';name='Five';productId='pm5'});sources=@();instances=@();profiles=@()}}
        }
    }
    BeforeEach {
        $root=Join-Path $TestDrive ('Local project данные '+[guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory((Join-Path $root '.agent-1c'))
        [IO.File]::WriteAllText((Join-Path $root '.agent-1c/project.json'),'{"aiRules":{"tools":["codex"]}}',[Text.UTF8Encoding]::new($false))
        . $HelperPath -ProjectRoot $root -Action help *> $null
        . Import-ItlProductProjectSetup
        $snapshot=New-SetupCatalogFixture
        $script:ItlMcpRegistryOperation=@{attempted=$true;snapshot=$snapshot.registry;error=$null;catalogAttempted=$true;catalogSnapshot=$snapshot;catalogError=$null}
        Mock Read-InitRequired {throw 'Unexpected additional local question'}
        Mock Read-InitBaseConfigurationVersion {throw 'Unexpected PM4/PM5 question'}
    }
    AfterEach {Remove-Variable ItlMcpRegistryOperation -Scope Script -ErrorAction SilentlyContinue}
    It 'exposes applied project and registry source differences without network or state writes' {
        $snapshot.registry.hosts=@(@{hostId='source';configurations=@(@{id='typical';configurationName='PM5 CORP';configurationVersion='5.0.3.59';indexedAt='2026-10-21T00:00:00Z';nightlyIndexStatus='succeeded'});servers=@(@{id='code';scope='project';configId='typical';family='vibecoding1c';url='http://source.invalid:22100/mcp'})})
        $snapshot.catalog.sources=@(@{sourceId='typical-code';role='code';endpoint=@{hostId='source';serverId='code';configId='typical'};origin=@{productId='pm5'}})
        $snapshot.catalog.products[1].roles=@{code=@{mode='own';sourceId='typical-code'}}
        $snapshot.catalog.projects[1].customized=$true
        $snapshot.catalog.projects[1].customizations=@{summary='Расчёт заказчика';references=@('https://docs.invalid/customer')}
        $snapshot.catalog.projects[1].roles=@{code=@{mode='inherit';usage='base-product';limitations=@{summary='Типовой MCP не содержит доработок'}}}
        $candidate=Select-ItlProductProjectCandidate five
        $null=Invoke-ItlProductProjectAssociation $candidate
        $protected=@($script:ConfigPath,(Get-ItlProductProjectPath applied),(Get-ItlProductProjectPath operation),(Get-ItlManagedMcpStatePath),(Get-Vibecoding1cMcpSelectionPath))+@(Get-ItlClientMcpConfigPaths codex)
        $before=@{};foreach($path in $protected){$before[$path]=Get-ItlMcpFileState $path}
        Mock Read-ItlProductProjectSnapshot {throw 'Context must not refresh registry'}
        $report=Invoke-ItlProductProjectCommand context
        $report.projectId|Should -Be five
        $report.productId|Should -Be pm5
        $report.projectDifferences.customizations.summary|Should -Be 'Расчёт заказчика'
        $report.sources[0].usage|Should -Be base-product
        $report.sources[0].registry.configurationVersion|Should -Be '5.0.3.59'
        $report.sources[0].registry.provenance|Should -Be registry
        $report.sources[0].origin.productId|Should -Be pm5
        $report.sources[0].nativeReadiness|Should -Be unverified
        $path=Join-Path $root 'наблюдение MCP с пробелом.json'
        $ctx=$candidate.context
        $read=@{request=@{id=2;method='tools/call';params=@{name='get_module_structure';arguments=@{module_path='CommonModules/Модуль/Ext/Module.bsl'}}};response=@{id=2;result=@{structuredContent=@{status='success';data=@{name='Модуль'}}}}}
        @{schemaVersion=1;catalogRevision=$ctx.catalogRevision;settingsHash=$ctx.settingsHash;roles=@{code=@{endpoint=$ctx.endpointIntents.code.url;checkedAt='2026-10-21T00:00:00Z';transport='external-probe';read=$read}}}|ConvertTo-Json -Depth 20|Set-Content -LiteralPath $path -Encoding UTF8
        $proof=Invoke-ItlProductProjectCommand context -RecordPath $path
        $proof.sourceObservations.roles.code.binding|Should -Be matched
        $proof.sourceObservations.roles.code.clientActivation|Should -Be unverified
        foreach($file in $protected){(Get-ItlMcpFileState $file)|Should -BeExactly $before[$file]}
        Should -Invoke Read-ItlProductProjectSnapshot -Times 0
    }
    It 'prints nested <Scenario> context as UTF-8 JSON through the actual <EntryAction> child CLI' -ForEach @(
        @{Scenario='custom';EntryAction='vibecoding1c-mcp-status'},
        @{Scenario='prof';EntryAction='vibecoding1c-mcp-status'},
        @{Scenario='custom';EntryAction='vibecoding1c-mcp-select'},
        @{Scenario='prof';EntryAction='vibecoding1c-mcp-select'}
    ) {
        $snapshot.catalog.products[1].name='PM5 КОРП'
        $snapshot.registry.hosts=@(@{hostId='typical';configurations=@(@{id='corp';configurationName='УправлениеПроектамиКОРП';configurationVersion='5.0.3.59';indexedAt='2026-10-21T00:00:00Z';nightlyIndexStatus='succeeded'});servers=@(
            @{id='code';scope='project';configId='corp';family='vibecoding1c';url='http://source.invalid:22100/mcp'},
            @{id='graph';scope='project';configId='corp';family='vibecoding1c';url='http://source.invalid:22101/mcp/'}
        )})
        $snapshot.catalog.sources=@('code','graph'|ForEach-Object {@{sourceId=('typical-'+$_);role=$_;endpoint=@{hostId='typical';serverId=$_;configId='corp'};origin=@{productId='pm5'}}})
        $usage=if($Scenario -eq 'custom'){'base-product'}else{'reference-product'}
        $limitations=if($Scenario -eq 'custom'){'Типовой MCP не содержит доработок'}else{'Проверять исключённые функции по карте ПРОФ'}
        $snapshot.catalog.projects[1].roles=@{code=@{mode='own';sourceId='typical-code';usage=$usage;limitations=@{summary=$limitations}};graph=@{mode='own';sourceId='typical-graph';usage=$usage;limitations=@{summary=$limitations}}}
        $snapshot.catalog.projects[1].name='Проект с пробелом '+$Scenario
        $snapshot.catalog.projects[1].customized=($Scenario -eq 'custom')
        if($Scenario -eq 'custom'){$snapshot.catalog.projects[1].customizations=@{summary='Расчёт заказчика';references=@('https://docs.invalid/customer')}}
        else {$snapshot.catalog.products+=@{productId='prof';name='PM5 ПРОФ';baseConfigurationVersion='PM5'};$snapshot.catalog.projects[1].productId='prof'}
        $snapshot.catalog.projects[0].name='UNSELECTED_PROJECT_MUST_NOT_LEAK'
        $candidate=Select-ItlProductProjectCandidate five
        $null=Invoke-ItlProductProjectAssociation $candidate
        $ctx=$candidate.context
        $read=@{request=@{id=2;method='tools/call';params=@{name='get_module_structure';arguments=@{module_path='CommonModules/Модуль/Ext/Module.bsl'}}};response=@{id=2;result=@{structuredContent=@{status='success';data=@{name='Модуль'}}}}}
        $recordPath=Join-Path $root 'наблюдение MCP с пробелом.json'
        Write-Utf8TextAtomic $recordPath (@{schemaVersion=1;catalogRevision=$ctx.catalogRevision;settingsHash=$ctx.settingsHash;roles=@{code=@{endpoint=$ctx.endpointIntents.code.url;checkedAt='2026-10-21T00:00:00Z';transport='external-probe';read=$read}}}|ConvertTo-Json -Depth 20)
        $protected=@($script:ConfigPath,(Get-ItlProductProjectPath applied),(Get-ItlProductProjectPath operation),(Get-ItlManagedMcpStatePath),(Get-Vibecoding1cMcpSelectionPath))
        $before=@{};foreach($path in $protected){$before[$path]=@{sha=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash;mtime=(Get-Item -LiteralPath $path).LastWriteTimeUtc.Ticks}}
        $probe=Invoke-TestPowerShellFile -FilePath $HelperPath -Arguments @('-ProjectRoot',$root,'-Action',$EntryAction,'-CatalogAction','context','-CatalogRecordPath',$recordPath)
        $probe.exitCode|Should -Be 0 -Because $probe.combinedText
        $text=$probe.stdout -join [Environment]::NewLine
        $text|Should -Not -Match 'System.Collections|UNSELECTED_PROJECT_MUST_NOT_LEAK'
        $report=$text|ConvertFrom-Json -ErrorAction Stop
        $report.project|Should -BeExactly ('Проект с пробелом '+$Scenario)
        $report.productId|Should -BeExactly $candidate.binding.productId
        $report.projectDifferences.customized|Should -Be ($Scenario -eq 'custom')
        if($Scenario -eq 'custom'){$report.projectDifferences.customizations.summary|Should -BeExactly 'Расчёт заказчика';$report.projectDifferences.customizations.references|Should -Be @('https://docs.invalid/customer')}
        @($report.sources).Count|Should -Be 2
        foreach($source in $report.sources){
            $source.origin.productId|Should -BeExactly pm5
            $source.origin.productName|Should -BeExactly 'PM5 КОРП'
            $source.usage|Should -BeExactly $usage
            $source.limitations.summary|Should -BeExactly $limitations
            $source.registry.configurationName|Should -BeExactly 'УправлениеПроектамиКОРП'
            $source.registry.configurationVersion|Should -BeExactly '5.0.3.59'
            $source.registry.indexedAt|Should -BeExactly '2026-10-21T00:00:00Z'
            $source.registry.provenance|Should -BeExactly registry
            $source.nativeReadiness|Should -BeExactly unverified
        }
        $report.sourceObservations.roles.code.binding|Should -BeExactly matched
        $report.sourceObservations.roles.code.clientActivation|Should -BeExactly unverified
        $report.activeClientContext|Should -BeExactly unverified
        foreach($path in $protected){(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash|Should -BeExactly $before[$path].sha;(Get-Item -LiteralPath $path).LastWriteTimeUtc.Ticks|Should -Be $before[$path].mtime}
    }
    It 'prints unbound context as JSON without creating an association' {
        $probe=Invoke-TestPowerShellFile -FilePath $HelperPath -Arguments @('-ProjectRoot',$root,'-Action','vibecoding1c-mcp-status','-CatalogAction','context')
        $probe.exitCode|Should -Be 0 -Because $probe.combinedText
        $report=($probe.stdout -join [Environment]::NewLine)|ConvertFrom-Json -ErrorAction Stop
        $report.status|Should -BeExactly unbound
        $report.continuation|Should -BeExactly 'Use catalog select/preview explicitly.'
        Read-ItlProductProjectRecord applied|Should -BeNullOrEmpty
        (Read-Utf8Text $script:ConfigPath)|Should -Not -Match 'productProject'
    }
    It 'previews the imported alias masks as additions to an otherwise unchanged legacy Kilo receipt' {
        $snapshot.registry.hosts=@(@{hostId='source';configurations=@(@{id='typical'});servers=@(@{id='code';scope='project';configId='typical';family='vibecoding1c';url='http://source.invalid:22100/mcp'})})
        $snapshot.catalog.sources=@(@{sourceId='typical-code';role='code';endpoint=@{hostId='source';serverId='code';configId='typical'}})
        $snapshot.catalog.products[1].roles=@{code=@{mode='own';sourceId='typical-code'}}
        $script:Config.aiRules.tools=@('kilocode')
        Write-Utf8TextAtomic $script:ConfigPath ($script:Config|ConvertTo-Json -Depth 10)
        $candidate=Select-ItlProductProjectCandidate five
        $null=Invoke-ItlProductProjectAssociation $candidate
        $endpoints=@((New-ItlProductProjectPreview $candidate.context @('kilocode')).requests[0].endpoints)
        # Model the old writer/receipt, without changing the selected context.
        Write-ItlClientMcpEndpoints -Client kilocode -Owner vibecoding1c -Endpoints $endpoints *> $null
        $statePath=Get-ItlManagedMcpStatePath
        $legacyState=Read-Utf8Text $statePath|ConvertFrom-Json
        $legacyState.lastWritten.'kilocode/vibecoding1c'.PSObject.Properties.Remove('onec-code-metadata-mcp')
        Write-Utf8TextAtomic $statePath ($legacyState|ConvertTo-Json -Depth 20)
        $applied=Read-ItlProductProjectRecord applied
        $applied.proof=Get-ItlProductProjectClientProof @(@{client='kilocode';owner='vibecoding1c';endpoints=$endpoints})
        Write-ItlProductProjectRecord applied $applied
        $preview=New-ItlProductProjectPreview $candidate.context @('kilocode')
        $additions=@($preview.changes|Where-Object name -eq 'onec-code-metadata-mcp')
        $additions.Count|Should -Be 1 -Because ($preview.changes|ConvertTo-Json -Depth 4 -Compress)
        $additions[0].status|Should -BeExactly addition
        Test-ItlProductProjectPreviewClientChanges $preview|Should -BeTrue
    }
    It 'keeps select restore later and pending catalog records out of legacy MCP enrollment' -Tag CatalogLegacyEnrollment {
        $path=Get-Vibecoding1cMcpSelectionPath
        Mock Get-Vibecoding1cMcpSelectionCompleteness {throw 'Catalog preferences triggered legacy readiness'}
        $candidate=Select-ItlProductProjectCandidate five
        $null=Invoke-ItlProductProjectAssociation $candidate
        @((Read-Utf8Text $path|ConvertFrom-Json).PSObject.Properties.Name)|Should -Be @('productProject')
        (Invoke-AiRules1cManagedMcpConfigReconcile -Operation 'catalog association').preserved|Should -BeTrue
        $null=Invoke-ItlProductProjectRecovery restore
        Test-Path -LiteralPath $path|Should -BeFalse
        (Invoke-AiRules1cManagedMcpConfigReconcile -Operation 'restored association').preserved|Should -BeTrue
        Mock Test-InteractiveInputAvailable {return $true}
        Mock Read-InitOptional {return 'later'}
        Invoke-ItlProductProjectPostUpdateOffer
        (Invoke-AiRules1cManagedMcpConfigReconcile -Operation 'explicit later').preserved|Should -BeTrue
        $before=Read-ItlProductProjectSetting selection
        $desired=ConvertTo-ItlCatalogCanonicalValue $before
        $desired['pendingCatalogRecords']=@(@{collection='projects';record=@{projectId='pending';productId='pm5';name='Pending'};status='unsubmitted'})
        Set-ItlProductProjectSetting selection $desired $before
        (Invoke-AiRules1cManagedMcpConfigReconcile -Operation 'retained draft').preserved|Should -BeTrue
        (Read-ItlProductProjectSetting selection).associationOffer|Should -Be later
        Should -Invoke Get-Vibecoding1cMcpSelectionCompleteness -Times 0
    }
    It 'preserves the native legacy body and its integrity failure across catalog apply and restore' -Tag CatalogLegacyEnrollment {
        $path=Get-Vibecoding1cMcpSelectionPath
        $legacy=@{schemaVersion=1;servers=@(@{id='code';enabled=$true;provider='remote';configId='original'});updatedAt='unchanged-native-time';custom=@{keep='exact'}}
        Write-Vibecoding1cMcpJsonFile $path $legacy
        Set-ItlProductProjectSetting selection @{associationOffer='later'} $null
        $raw=ConvertTo-ItlCatalogCanonicalValue (Read-Utf8Text $path|ConvertFrom-Json)
        $raw.Remove('productProject')
        (Get-ItlCatalogHash $raw)|Should -Be (Get-ItlCatalogHash $legacy)
        Set-ItlProductProjectSetting selection $null @{associationOffer='later'}
        (Get-ItlCatalogHash (Read-Utf8Text $path|ConvertFrom-Json))|Should -Be (Get-ItlCatalogHash $legacy)
        Mock Get-Vibecoding1cMcpSelectionCompleteness {return [pscustomobject]@{isComplete=$false;reasons=@('configured endpoint unavailable')}}
        Mock Get-Vibecoding1cMcpSelectedClientConfigNames {return @('1c-code-metadata-mcp')}
        Mock Get-Vibecoding1cMcpReadyClientConfigNames {return @()}
        {Invoke-AiRules1cManagedMcpConfigReconcile}|Should -Throw '*ITL_MCP_RECONCILE_INTEGRITY_FAILED*'
        Should -Invoke Get-Vibecoding1cMcpSelectionCompleteness -Times 1
    }
    It 'retains legacy presence for an existing empty native selection file' -Tag CatalogLegacyEnrollment {
        $path=Get-Vibecoding1cMcpSelectionPath
        Write-Vibecoding1cMcpJsonFile $path @{}
        Set-ItlProductProjectSetting selection @{associationOffer='later'} $null
        Test-Vibecoding1cMcpLegacySelectionPresent|Should -BeTrue
        Set-ItlProductProjectSetting selection $null @{associationOffer='later'}
        Test-Path -LiteralPath $path|Should -BeTrue
        Test-Vibecoding1cMcpLegacySelectionPresent|Should -BeTrue
    }
    It 'does not suppress corrupt native selection as catalog-only' -Tag CatalogLegacyEnrollment {
        $path=Get-Vibecoding1cMcpSelectionPath
        Write-Utf8TextAtomic $path '{broken'
        {Invoke-AiRules1cManagedMcpConfigReconcile}|Should -Throw
    }
    It 'inherits only catalog preferences without probing or starting legacy MCP in an unbound branch' -Tag CatalogLegacyEnrollment {
        Set-ItlProductProjectSetting selection @{associationOffer='later'} $null
        $sourceBytes=Read-Utf8Text (Get-Vibecoding1cMcpSelectionPath)
        $branch=Join-Path $TestDrive ('Catalog-only branch '+[guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory((Join-Path $branch '.agent-1c'))
        [IO.File]::WriteAllText((Join-Path $branch '.agent-1c/project.json'),'{"aiRules":{"tools":["codex"]}}',[Text.UTF8Encoding]::new($false))
        $script:ProjectRoot=$branch;$script:ConfigPath=Join-Path $branch '.agent-1c/project.json'
        Read-ProjectConfig
        Mock Get-Vibecoding1cMcpSelectionCompleteness {throw 'Unexpected legacy inheritance probe'}
        Mock Start-Vibecoding1cMcp {throw 'Unexpected legacy MCP start'}
        Invoke-DevBranchVibecoding1cMcpInheritance -MainProjectRoot $root
        (Read-Utf8Text (Get-Vibecoding1cMcpSelectionPath))|Should -BeExactly $sourceBytes
        (Read-Utf8Text (Join-Path $root '.agent-1c/mcp/vibecoding1c-selection.json'))|Should -BeExactly $sourceBytes
        Test-Vibecoding1cMcpLegacySelectionPresent|Should -BeFalse
        Get-ItlProductProjectBinding|Should -BeNullOrEmpty
        Should -Invoke Get-Vibecoding1cMcpSelectionCompleteness -Times 0
        Should -Invoke Start-Vibecoding1cMcp -Times 0
    }
    It 'selects <Project> and derives <Family> without repeating MCP or family questions' -ForEach @(@{Project='four';Family='PM4'},@{Project='five';Family='PM5'}) {
        $candidate=Select-ItlProductProjectCandidate -ProjectId $Project -AllowPrompt:$true
        $candidate.context.baseConfigurationVersion|Should -Be $Family
        $candidate.binding.requiredCapability|Should -Be product-project-registry-v1
        @($candidate.binding.Keys).Count|Should -Be 4
        Should -Invoke Read-InitRequired -Times 0
        Should -Invoke Read-InitBaseConfigurationVersion -Times 0
    }
    It 'requires explicit association and does not treat unattended or no answer as consent' {
        {Select-ItlProductProjectCandidate -AllowPrompt:$false}|Should -Throw '*CATALOG_PROJECT_REQUIRED*'
        Get-ItlProductProjectBinding|Should -BeNullOrEmpty
        Test-Path (Get-ItlProductProjectPath applied)|Should -BeFalse
    }
    It 'limits visible choices and retains stable IDs rather than exposing the full catalog' {
        $choices=@(Get-ItlProductProjectChoices $snapshot projects 1)
        $choices.Count|Should -Be 1
        $choices[0].id|Should -Be five
        $choices[0].PSObject.Properties.Name|Should -Not -Contain roles
    }
    It 'keeps explicit legacy JSON answers and rejects contradictory catalog mode' {
        $AgentTarget='codex';$AgentModel=''
        $legacy=Normalize-InitAnswers ([pscustomobject]@{baseConfigurationVersion='PM4';sourceUsesRepository=$false})
        $legacy.catalogMode|Should -Be legacy
        $legacy.baseConfigurationVersion|Should -Be PM4
        {Resolve-ItlProductProjectInitAnswers ([pscustomobject]@{projectId='five';catalogMode='legacy'})}|Should -Throw '*CATALOG_INIT_MODE_CONFLICT*'
        {Resolve-ItlProductProjectInitAnswers ([pscustomobject]@{catalogMode='catalog'})}|Should -Throw '*CATALOG_PROJECT_REQUIRED*'
    }
    It 'does not infer a missing product family during read-only preview' {
        $snapshot.catalog.products[1].Remove('baseConfigurationVersion')
        {Select-ItlProductProjectCandidate five -ReadOnly -AllowPrompt:$true}|Should -Throw '*CATALOG_PRODUCT_FAMILY_REQUIRED*'
        Should -Invoke Read-InitBaseConfigurationVersion -Times 0
        {Select-ItlProductProjectCandidate new -ReadOnly -AllowPrompt:$true}|Should -Throw '*CATALOG_PREVIEW_READ_ONLY*'
    }
    It 'retains a denied project publication with the same ID and resolves its local draft' {
        Mock Save-ItlCatalogRecord {return @{status='unsubmitted';outcome='permission-denied'}}
        $record=@{projectId='new-project';name='New project';productId='pm5'}
        $saved=Save-ItlProductProjectDraft $snapshot projects $record
        $saved.status|Should -Be unsubmitted
        $again=New-ItlProductProjectDraft $snapshot
        $again.recordId|Should -Be new-project
        $candidate=Select-ItlProductProjectCandidate new-project
        $candidate.context.catalogPublication.state|Should -Be local-pending
        $candidate.binding.projectId|Should -Be new-project
        Should -Invoke Save-ItlCatalogRecord -Times 2 -Exactly -ParameterFilter {$BaseCommit -ceq ('a'*40)}
    }
    It 'uses exact publication read-back without refreshing or changing a retained project ID' {
        $record=@{projectId='new-project';name='New project';productId='pm5'}
        $verified=ConvertTo-ItlCatalogCanonicalValue $snapshot
        $verified.catalog=Set-ItlCatalogRecord $snapshot.catalog projects $record
        $verified.catalogRevision='b'*40
        Mock Save-ItlCatalogRecord {return @{status='saved';outcome='published';catalogRevision=('b'*40);verifiedSnapshot=$verified}}
        Mock Update-Vibecoding1cMcpRegistryCheckout {throw 'Unexpected second network check'}
        $null=Save-ItlProductProjectDraft $snapshot projects $record
        $candidate=Select-ItlProductProjectCandidate new-project
        $candidate.context.catalogRevision|Should -Be ('b'*40)
        $candidate.context.catalogPublication.state|Should -Be published
        $candidate.binding.projectId|Should -Be new-project
        Should -Invoke Update-Vibecoding1cMcpRegistryCheckout -Times 0
    }
    It 'rejects an independently changed public record instead of silently applying a pending draft' {
        $preferences=@{pendingCatalogRecords=@(@{collection='projects';record=@{projectId='five';name='Local';productId='pm5'};baseRecordHash=(Get-ItlCatalogHash $snapshot.catalog.projects[1]);status='unsubmitted'})}
        $snapshot.catalog.projects[1].name='Foreign change'
        {Get-ItlProductProjectEffectiveSnapshot $snapshot $preferences}|Should -Throw '*CATALOG_PENDING_RECORD_CONFLICT*'
    }
    It 'saves catalog bootstrap binding before unattended work and leaves memory disabled' {
        $script:PreparedCatalogCandidate=Select-ItlProductProjectCandidate five
        Save-ItlProductProjectInitBinding ([pscustomobject]@{catalogMode='catalog'})
        (Get-ItlProductProjectBinding).projectId|Should -Be five
        (Read-ItlProductProjectRecord applied).configurationState|Should -Be binding-only
        (Read-ItlProductProjectSetting selection).memoryOptIn|Should -BeFalse
        Mock Get-Vibecoding1cMcpSelectionCompleteness {throw 'Legacy MCP questionnaire must not run'}
        Mock Set-Vibecoding1cMcpSelection {throw 'Unexpected per-MCP question'}
        Prepare-Vibecoding1cMcpSelectionForInit -AllowPrompt:$false
        Should -Invoke Set-Vibecoding1cMcpSelection -Times 0
    }
    It 'materializes the pinned bootstrap through the same writer without catalog-role legacy lookup' {
        $script:PreparedCatalogCandidate=Select-ItlProductProjectCandidate five
        Save-ItlProductProjectInitBinding ([pscustomobject]@{catalogMode='catalog'})
        Mock Select-Vibecoding1cMcpManifestServers {return @(@{id='code';scope='project'},@{id='graph';scope='project'},@{id='bookstack';scope='global'})}
        Mock New-Vibecoding1cMcpRemoteRuntime {throw 'Legacy configuration-ID question must not run'}
        Mock Ensure-Vibecoding1cMcpDistribution {throw 'Unexpected distribution clone'}
        Mock Get-Vibecoding1cMcpConfigContext {return @{}}
        Mock Get-Vibecoding1cMcpCurrentEndpoints {return @()}
        Mock Write-ItlOnDemandMcpClientConfig {return $null}
        Mock Sync-ItlUiToolsMcp {return $null}
        Start-Vibecoding1cMcp -AllowPrompt:$false
        (Read-ItlProductProjectRecord applied).configurationState|Should -Be configured
        (Get-ItlProductProjectOperationContext).catalogRevision|Should -Be ('a'*40)
        Should -Invoke New-Vibecoding1cMcpRemoteRuntime -Times 0
        Should -Invoke Ensure-Vibecoding1cMcpDistribution -Times 0
    }
    It 'retains explicit local and catalog overrides while recognizing inherited roles' {
        Test-ItlProductProjectCatalogRole code @{servers=@()}|Should -BeTrue
        Test-ItlProductProjectCatalogRole syntax @{servers=@()}|Should -BeFalse
        Test-ItlProductProjectCatalogRole code @{servers=@(@{id='code';provider='local'})}|Should -BeFalse
        Test-ItlProductProjectCatalogRole graph @{servers=@(@{id='graph';provider='remote';catalogOverride=$true})}|Should -BeFalse
    }
    It 'stops incompatible package replacement and permits the descriptor of the current source' {
        $script:PreparedCatalogCandidate=Select-ItlProductProjectCandidate five
        Save-ItlProductProjectInitBinding ([pscustomobject]@{catalogMode='catalog'})
        {Assert-ItlProductProjectPackageCompatibility (Join-Path $TestDrive 'Old source')}|Should -Throw '*CATALOG_PACKAGE_INCOMPATIBLE*restore-compatible*'
        {Assert-ItlProductProjectPackageCompatibility $RepoRoot}|Should -Not -Throw
        (Get-ItlProductProjectBinding).projectId|Should -Be five
    }
    It 'restores the original owned MCP and binding baseline after multiple catalog applies' {
        $old=@(@{client='codex';owner='vibecoding1c';endpoints=@(@{name='old';url='https://old.invalid'})})
        Write-ItlClientMcpEndpointSet $old *> $null
        $before=Get-ItlMcpOwnedSemanticSignature (Read-ItlClientMcpEntries codex) @('old')
        $script:PreparedCatalogCandidate=Select-ItlProductProjectCandidate five
        Save-ItlProductProjectInitBinding ([pscustomobject]@{catalogMode='catalog'})
        $context=ConvertTo-ItlCatalogCanonicalValue $script:PreparedCatalogCandidate.context
        $context.Remove('configurationStage')
        $null=Invoke-ItlProductProjectClientApply $context @(@{client='codex';owner='vibecoding1c';endpoints=@(@{name='new';url='https://new.invalid'})})
        (Invoke-ItlProductProjectRecovery restore-compatible).status|Should -Be compatible-restored
        Get-ItlProductProjectBinding|Should -BeNullOrEmpty
        Read-ItlProductProjectSetting selection|Should -BeNullOrEmpty
        Read-ItlProductProjectRecord applied|Should -BeNullOrEmpty
        (Read-ItlClientMcpEntries codex).Contains('new')|Should -BeFalse
        (Get-ItlMcpOwnedSemanticSignature (Read-ItlClientMcpEntries codex) @('old'))|Should -BeExactly $before
        {Assert-ItlProductProjectPackageCompatibility (Join-Path $TestDrive 'Old source')}|Should -Not -Throw
    }
    It 'does not replace a manually changed owned key during compatibility restore' {
        $script:PreparedCatalogCandidate=Select-ItlProductProjectCandidate five
        Save-ItlProductProjectInitBinding ([pscustomobject]@{catalogMode='catalog'})
        $null=Invoke-ItlProductProjectClientApply $script:PreparedCatalogCandidate.context @(@{client='codex';owner='vibecoding1c';endpoints=@(@{name='code';url='https://new.invalid'})})
        $path=Join-Path $root '.codex/config.toml'
        Write-Utf8TextAtomic $path ((Read-Utf8Text $path).Replace('https://new.invalid','https://manual.invalid'))
        {Invoke-ItlProductProjectRecovery restore-compatible}|Should -Throw '*CATALOG_CLIENT_CONFLICT*'
        (Get-ItlProductProjectBinding).projectId|Should -Be five
        (Read-Utf8Text $path)|Should -Match 'manual.invalid'
    }
    It 'records only explicit later and does not repeat the successful-update offer' {
        Mock Test-InteractiveInputAvailable {return $true}
        Mock Read-InitOptional {return 'later'}
        Invoke-ItlProductProjectPostUpdateOffer
        Invoke-ItlProductProjectPostUpdateOffer
        (Read-ItlProductProjectSetting selection).associationOffer|Should -Be later
        Should -Invoke Read-InitOptional -Times 1 -Exactly
        Get-ItlProductProjectBinding|Should -BeNullOrEmpty
    }
    It 'records no consent or defer for an empty answer or unattended update' {
        Mock Test-InteractiveInputAvailable {return $false}
        Mock Read-InitOptional {throw 'Unexpected unattended question'}
        Invoke-ItlProductProjectPostUpdateOffer
        Should -Invoke Read-InitOptional -Times 0
        Mock Test-InteractiveInputAvailable {return $true}
        Mock Read-InitOptional {return ''}
        Invoke-ItlProductProjectPostUpdateOffer
        Read-ItlProductProjectSetting selection|Should -BeNullOrEmpty
        Get-ItlProductProjectBinding|Should -BeNullOrEmpty
    }
    It 'never reads from an unvalidated continuation even if its hidden console reports input available' {
        Mock Test-InteractiveInputAvailable {return $true}
        Mock Read-InitOptional {throw 'Hidden continuation cannot receive foreground input'}
        $script:LifecycleOperationIsContinuation=$true
        try {Invoke-ItlProductProjectPostUpdateOffer -WarningAction SilentlyContinue} finally {$script:LifecycleOperationIsContinuation=$false}
        Should -Invoke Read-InitOptional -Times 0
        Read-ItlProductProjectSetting selection|Should -BeNullOrEmpty
    }
    It 'verifies the exact child terminal and retained snapshot without a second parent offer' {
        $script:CatalogPendingRead=0
        Mock Get-WorkflowUpdatePendingSnapshot {
            $script:CatalogPendingRead++
            if($script:CatalogPendingRead -eq 1){return @{snapshot=@{root='itl-workflow-update-rollback-catalog'};receipt=@{phase='master-committed'}}}
            return $null
        }
        Mock Invoke-Agent1cFreshProcess {return @{exitCode=0}}
        Mock Get-WorkflowUpdateCompletedSnapshot {return @{receipt=@{sourceCommit='exact-source';sourceRoot='exact-root'}}}
        Mock Assert-WorkflowDevelopmentBranchRolloutComplete {return $true}
        Mock Invoke-ItlProductProjectPostUpdateOffer {throw 'The child owns the first-upgrade offer'}
        Complete-WorkflowUpdatePostCopyFromSnapshot -Snapshot @{root='itl-workflow-update-rollback-catalog'} -Source @{commit='exact-source';root='exact-root'}
        Should -Invoke Assert-WorkflowDevelopmentBranchRolloutComplete -Times 1 -Exactly
        Should -Invoke Invoke-ItlProductProjectPostUpdateOffer -Times 0 -Exactly
    }
    It 'does not repeat the intermediate parent hook after an empty child answer' {
        Mock Test-InteractiveInputAvailable {return $true}
        Mock Read-InitOptional {throw 'Duplicate parent offer'}
        $script:LifecycleOperationTerminalWrittenByContinuation=$true
        try {Invoke-ItlProductProjectPostUpdateOffer} finally {$script:LifecycleOperationTerminalWrittenByContinuation=$false}
        Should -Invoke Read-InitOptional -Times 0
        Read-ItlProductProjectSetting selection|Should -BeNullOrEmpty
    }
    It 'keeps package success separate from a failed association' {
        Mock Test-InteractiveInputAvailable {return $true}
        Mock Read-InitOptional {return 'choose'}
        Mock Invoke-ItlProductProjectCommand {throw 'Fixture association failure'}
        {Invoke-ItlProductProjectPostUpdateOffer -WarningAction SilentlyContinue}|Should -Not -Throw
        Should -Invoke Invoke-ItlProductProjectCommand -Times 1 -Exactly
        Get-ItlProductProjectBinding|Should -BeNullOrEmpty
    }
    It 'keeps both catalog receipts byte-identical on the first unchanged single-client sync' -Tag StartupReceiptNoOp {
        Write-Utf8TextAtomic $script:ConfigPath '{"aiRules":{"tools":["codex","claude-code"]}}'
        Read-ProjectConfig
        Mock Get-Vibecoding1cMcpCurrentEndpoints {return @()}
        Mock Select-Vibecoding1cMcpManifestServers {return @()}
        $null=Invoke-ItlProductProjectAssociation (Select-ItlProductProjectCandidate five)
        $marker=Get-ItlProductProjectPath applied;$operation=Get-ItlProductProjectPath operation
        $beforeMarker=Read-Utf8Text $marker;$beforeOperation=Read-Utf8Text $operation
        $beforeApplied=Read-ItlProductProjectRecord applied
        # The first requested subset differs from the configured project client
        # set, while every requested physical entry is already proven current.
        Write-Vibecoding1cMcpClientConfig -Client codex
        (Read-Utf8Text $marker)|Should -BeExactly $beforeMarker
        (Read-Utf8Text $operation)|Should -BeExactly $beforeOperation
        (Read-ItlProductProjectRecord applied).proof.Contains('claude-code/vibecoding1c')|Should -BeTrue
        (Read-ItlProductProjectRecord applied).context.settingsIntentHash|Should -BeExactly $beforeApplied.context.settingsIntentHash
    }
    It 'still adopts a newly requested client and detects a later manual change after single-client sync' -Tag StartupReceiptNoOp {
        Mock Get-Vibecoding1cMcpCurrentEndpoints {return @()}
        Mock Select-Vibecoding1cMcpManifestServers {return @()}
        $null=Invoke-ItlProductProjectAssociation (Select-ItlProductProjectCandidate five)
        $before=(Read-ItlProductProjectRecord applied).operationId
        Write-Vibecoding1cMcpClientConfig -Client claude-code
        $after=Read-ItlProductProjectRecord applied
        $after.operationId|Should -Not -Be $before
        $after.proof.Contains('claude-code/vibecoding1c')|Should -BeTrue
        Mock New-ItlProductProjectPreview {throw 'Manual client change reached full preview'}
        Write-Utf8TextAtomic (Join-Path $root '.mcp.json') '{"mcpServers":{},"manual":"сохранить"}'
        {Initialize-ItlProductProjectContext}|Should -Throw '*Manual client change reached full preview*'
    }
    It 'invalidates early reuse when the catalog schema changes without changing catalog HEAD' -Tag StartupReceiptNoOp {
        Mock Get-Vibecoding1cMcpCurrentEndpoints {return @()}
        Mock Select-Vibecoding1cMcpManifestServers {return @()}
        $null=Invoke-ItlProductProjectAssociation (Select-ItlProductProjectCandidate five)
        Remove-Variable ItlMcpRegistryOperation -Scope Script
        Mock Update-Vibecoding1cMcpRegistryCheckout {return 'unused-root'}
        Mock Get-GitOutputAt {return ('a'*40)}
        Mock Read-ItlProductCatalogSnapshot {return $snapshot}
        Invoke-Vibecoding1cMcpRegistryOperation {Initialize-ItlProductProjectContext}
        Should -Invoke Read-ItlProductCatalogSnapshot -Times 0
        Mock Get-ItlMcpFileState {return 'fixture-schema-changed'} -ParameterFilter {$Path -like '*/templates/product-project-registry/schemas/catalog.schema.json' -or $Path -like '*\templates\product-project-registry\schemas\catalog.schema.json'}
        Invoke-Vibecoding1cMcpRegistryOperation {Initialize-ItlProductProjectContext}
        Should -Invoke Read-ItlProductCatalogSnapshot -Times 1 -Exactly
    }
    It 'uses the same apply owner for ordinary sync and retains proofs of unaffected clients' {
        $script:PreparedCatalogCandidate=Select-ItlProductProjectCandidate five
        Save-ItlProductProjectInitBinding ([pscustomobject]@{catalogMode='catalog'})
        $context=$script:PreparedCatalogCandidate.context
        $null=Invoke-ItlProductProjectClientApply $context @(@{client='claude-code';owner='vibecoding1c';endpoints=@(@{name='retained';url='https://retained.invalid'})})
        Mock Get-Vibecoding1cMcpCurrentEndpoints {return @()}
        Mock Select-Vibecoding1cMcpManifestServers {return @()}
        Mock Write-ItlOnDemandMcpClientConfig {return $null}
        Mock Sync-ItlUiToolsMcp {return $null}
        Mock Refresh-Vibecoding1cMcpRegistry {throw 'Unexpected repeated registry refresh'}
        Sync-ItlClientMcpConfig -Client codex
        $applied=Read-ItlProductProjectRecord applied
        $applied.proof.Contains('claude-code/vibecoding1c')|Should -BeTrue
        (Read-ItlClientMcpEntries claude-code).retained.url|Should -Be 'https://retained.invalid'
        Should -Invoke Refresh-Vibecoding1cMcpRegistry -Times 0
    }
    It 'rematerializes a new branch root from the same revision without writing the main root' {
        $script:PreparedCatalogCandidate=Select-ItlProductProjectCandidate five
        Save-ItlProductProjectInitBinding ([pscustomobject]@{catalogMode='catalog'})
        $mainConfig=Read-Utf8Text $script:ConfigPath
        $mainSelection=Read-Utf8Text (Get-Vibecoding1cMcpSelectionPath)
        $branch=Join-Path $TestDrive ('Branch '+[guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory((Join-Path $branch '.agent-1c'))
        [IO.File]::WriteAllText((Join-Path $branch '.agent-1c/project.json'),$mainConfig,[Text.UTF8Encoding]::new($false))
        $script:ProjectRoot=$branch;$script:ConfigPath=Join-Path $branch '.agent-1c/project.json'
        Read-ProjectConfig
        Copy-Vibecoding1cMcpSelectionFromMainWorktree $root|Should -BeTrue
        $context=Get-ItlProductProjectOperationContext
        $context.catalogRevision|Should -Be ('a'*40)
        Mock Get-Vibecoding1cMcpCurrentEndpoints {return @()}
        Mock Select-Vibecoding1cMcpManifestServers {return @()}
        Initialize-ItlProductProjectContext
        (Read-ItlProductProjectRecord applied).projectRoot|Should -Be $branch
        (Read-Utf8Text (Join-Path $root '.agent-1c/project.json'))|Should -BeExactly $mainConfig
        (Read-Utf8Text (Join-Path $root '.agent-1c/mcp/vibecoding1c-selection.json'))|Should -BeExactly $mainSelection
    }
    It 'skips full preview only while resolved context and physical inputs remain unchanged' {
        $candidate=Select-ItlProductProjectCandidate five
        Mock Get-Vibecoding1cMcpCurrentEndpoints {return @()}
        Mock Select-Vibecoding1cMcpManifestServers {return @()}
        $null=Invoke-ItlProductProjectAssociation $candidate
        $marker=Get-ItlMcpFileState (Get-ItlProductProjectPath applied)
        Mock New-ItlProductProjectPreview {throw 'Fixture full preview reached'}
        {Initialize-ItlProductProjectContext}|Should -Not -Throw
        Should -Invoke New-ItlProductProjectPreview -Times 0
        (Get-ItlMcpFileState (Get-ItlProductProjectPath applied))|Should -BeExactly $marker
        # Even an unrelated edit invalidates this optimization, so manual MCP
        # edits cannot be hidden by a matching catalog SHA.
        $path=Join-Path $root '.codex/config.toml'
        Write-Utf8TextAtomic $path ((Read-Utf8Text $path)+"`n# User edit`n")
        {Initialize-ItlProductProjectContext}|Should -Throw '*Fixture full preview reached*'
        Should -Invoke New-ItlProductProjectPreview -Times 1 -Exactly
    }
}

Describe 'Catalog lazy import uses only visible functions' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $RepoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
        . (Join-Path $RepoRoot '.agents/skills/1c-workflow/scripts/lib/agent-1c.vibecoding1c-mcp.ps1')
    }
    It 'loads missing catalog functions without command or module discovery and keeps them on repeated import' -Tag G3CatalogImport {
        $names=@('Resolve-ItlProductContext','Save-ItlCatalogRecord','Invoke-ItlProductProjectClientApply','Read-ItlProductProjectSnapshot','Invoke-ItlProductProjectCommand')
        foreach($name in $names){Remove-Item -LiteralPath ('Function:\'+$name) -ErrorAction SilentlyContinue}
        # A missing function queried through Get-Command scans PATH and modules.
        # This assertion tests the lookup contract, not a machine-specific time.
        Mock Get-Command {throw 'Unexpected command discovery in catalog lazy import'}
        . Import-ItlProductProject
        foreach($name in $names[0..3]){Test-Path -LiteralPath ('Function:\'+$name)|Should -BeTrue}
        Test-Path -LiteralPath 'Function:\Invoke-ItlProductProjectCommand'|Should -BeFalse
        . Import-ItlProductProjectSetup
        Test-Path -LiteralPath 'Function:\Invoke-ItlProductProjectCommand'|Should -BeTrue
        $before=@{};foreach($name in $names){$before[$name]=(Get-Item -LiteralPath ('Function:\'+$name)).ScriptBlock}
        . Import-ItlProductProjectSetup
        foreach($name in $names){[object]::ReferenceEquals($before[$name],(Get-Item -LiteralPath ('Function:\'+$name)).ScriptBlock)|Should -BeTrue}
        Should -Invoke Get-Command -Times 0 -Exactly
    }
}
