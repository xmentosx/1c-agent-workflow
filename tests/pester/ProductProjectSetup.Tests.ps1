Describe 'Explicit catalog setup and bootstrap keep one selected context' {
    BeforeAll {
        $RepoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
        $HelperPath=Join-Path $RepoRoot '.agents/skills/1c-workflow/scripts/agent-1c.ps1'
        function New-SetupCatalogFixture {
            return @{catalogRevision=('a'*40);inputGitObjectIds=@{};registry=@{schemaVersion=2;hosts=@()};relations=@{schemaVersion=1;relations=@();knowledgeAreas=@{}};catalog=@{schemaVersion=1;products=@(@{productId='pm4';name='PM4';baseConfigurationVersion='PM4'},@{productId='pm5';name='PM5';baseConfigurationVersion='PM5'});projects=@(@{projectId='four';name='Four';productId='pm4'},@{projectId='five';name='Five';productId='pm5'});sources=@();instances=@();profiles=@()}}
        }
    }
    BeforeEach {
        $root=Join-Path $TestDrive ('Local project '+[guid]::NewGuid().ToString('N'))
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
