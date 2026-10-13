Describe 'MCP operation continuity acceptance' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        $HelperPath = $context.HelperPath
    }

    It 'captures one registry publication across nested operations and discards it on exit' {
        $root = Join-Path $TestDrive 'Снимок реестра с пробелом'
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        & {
            . $HelperPath -ProjectRoot $root -Action help *> $null
            function Get-Vibecoding1cMcpRegistryRoot { $root }
            $script:refreshes = 0
            function Update-Vibecoding1cMcpRegistryCheckout { $script:refreshes++ }
            @{publishedAt='first';servers=@()} | ConvertTo-Json | Set-Content (Join-Path $root 'registry.json') -Encoding UTF8
            Invoke-Vibecoding1cMcpRegistryOperation {
                (Read-Vibecoding1cMcpRegistry).publishedAt | Should -Be first
                @{publishedAt='second';servers=@()} | ConvertTo-Json | Set-Content (Join-Path $root 'registry.json') -Encoding UTF8
                Invoke-Vibecoding1cMcpRegistryOperation {
                    Refresh-Vibecoding1cMcpRegistry *> $null
                    (Read-Vibecoding1cMcpRegistry).publishedAt | Should -Be first
                }
                $script:refreshes | Should -Be 1
            }
            Invoke-Vibecoding1cMcpRegistryOperation { (Read-Vibecoding1cMcpRegistry).publishedAt | Should -Be second }
            $script:refreshes | Should -Be 2
            Get-Variable ItlMcpRegistryOperation -Scope Script -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
            { Invoke-Vibecoding1cMcpRegistryOperation { throw 'cancelled' } } | Should -Throw '*cancelled*'
            Get-Variable ItlMcpRegistryOperation -Scope Script -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        }
    }

    It 'never reroutes a saved unavailable host to the only healthy alternative during selection' {
        $root = Join-Path $TestDrive 'Сохранённый host с пробелом'
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        & {
            . $HelperPath -ProjectRoot $root -Action help -McpServerId docs -McpProvider remote *> $null
            function Ensure-GitIgnore {}
            function Ensure-Vibecoding1cMcpRegistry {}
            function Read-Vibecoding1cMcpManifest { @{servers=@(@{id='docs';scope='global'})} }
            function Get-Vibecoding1cMcpTargetScopes { @('global') }
            function Read-Vibecoding1cMcpRegistry {
                @{schemaVersion=1;configurations=@();servers=@(
                    @{id='docs';scope='global';family='vibecoding1c';hostId='chosen';url='http://chosen.invalid/mcp';health='missing'},
                    @{id='docs';scope='global';family='vibecoding1c';hostId='other';url='http://other.invalid/mcp';health='running'}
                )}
            }
            Write-Vibecoding1cMcpSelection -Selection @{defaultProvider='remote';servers=@(@{id='docs';provider='remote';hostId='chosen';enabled=$true})}
            Set-Vibecoding1cMcpSelection -AllowPrompt:$false *> $null
            (Read-Vibecoding1cMcpSelection).servers[0].hostId | Should -Be chosen
        }
    }

    It 'uses one snapshot for earlier post-copy client reconciliation and final managed MCP update' {
        $root = Join-Path $TestDrive 'Обновление workflow с пробелом'
        New-Item -ItemType Directory -Force -Path (Join-Path $root '.agent-1c') | Out-Null
        @{aiRules=@{tools=@('codex')}} | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $root '.agent-1c/project.json') -Encoding UTF8
        & {
            . $HelperPath -ProjectRoot $root -Action help -AgentTarget codex *> $null
            $SkipAiRules = $true
            $script:refreshes = 0
            function Get-Vibecoding1cMcpRegistryRoot { $root }
            function Update-Vibecoding1cMcpRegistryCheckout { $script:refreshes++ }
            function Read-Vibecoding1cMcpManifest { @{servers=@(@{id='docs';scope='global';name='1C-docs-mcp'})} }
            function Get-Vibecoding1cMcpTargetScopes { @('global') }
            function Get-Vibecoding1cMcpCurrentEndpoints { @() }
            function Write-ItlOnDemandMcpClientConfig { $null }
            function Sync-ItlUiToolsMcp { $null }
            $publication = @{schemaVersion=1;host=@{hostId='chosen'};configurations=@();servers=@(@{id='docs';scope='global';family='vibecoding1c';provider='remote';name='1C-docs-mcp';url='http://first.invalid/mcp';status='running'})}
            $publication | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $root 'registry.json') -Encoding UTF8
            Write-Vibecoding1cMcpSelection -Selection @{defaultProvider='remote';servers=@(@{id='docs';provider='remote';enabled=$true;hostId='chosen'})}
            foreach ($name in @(
                'Assert-WorkflowUpdateMcpConfigSnapshot','Assert-UiTestingPolicyUpdateSnapshot',
                'Restore-UnfinishedForkCopiedMcpOwnership','Ensure-OneCSessionLimitDotEnv',
                'Ensure-Agent1cLifecycleLocksIgnored','Ensure-GitIgnore','Ensure-ItlPinnedOpenSpecGitAttributes',
                'Sync-ItlVanessaLibraries','Update-UserRules','Sync-WorkflowManagedDependencyLockEntries',
                'Install-YAxUnit','Update-RoctupMcp','Sync-VanessaAutomationDependencyLock','Install-VanessaAutomation',
                'Update-VanessaMcpArtifacts','Sync-ItlOnDemandMcpDependencyLock','Install-ItlOnDemandMcp',
                'Sync-KiloItlCommandSurface','Update-AgentGuidanceBridge','Install-ItlUiTools',
                'Sync-ItlClientUserEnvironment','Invoke-CavemanPolicyTransition'
            )) { Set-Item -Path ('Function:' + $name) -Value {} }
            function Get-WorkflowUpdatePendingSnapshot { @{receipt=@{sourceRoot=$root};snapshot=@{}} }
            function Test-WorkflowSourceLayeredOpenCodeConfig { $true }
            function Test-WorkflowSourceUiTestingPolicy { $false }
            function Get-AiRules1cManifestFileEntries { @() }
            function Get-WorkflowUpdateClientSurfacePaths { @() }
            function Get-AiRulesMigrationPlan { @{status='current'} }
            function Get-CavemanPolicyPreviousWorkflowCommit { '' }
            function Sync-ItlClientSurfaces {
                (Read-Vibecoding1cMcpRegistry).servers[0].url | Should -Be 'http://first.invalid/mcp'
                $publication.servers[0].url = 'http://second.invalid/mcp'
                $publication | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $root 'registry.json') -Encoding UTF8
            }
            $result = Invoke-WorkflowPackageFilePostCopy *> $null
            $script:refreshes | Should -Be 1
            (Read-ItlClientMcpEntries -Client codex).'1C-docs-mcp'.url | Should -Be 'http://first.invalid/mcp'
            (Read-Vibecoding1cMcpRegistry).servers[0].url | Should -Be 'http://second.invalid/mcp'
            Get-Variable ItlMcpRegistryOperation -Scope Script -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        }
    }

    It 'completes init with sole unavailable codechecker, failed registry=<RegistryFails>, optional degraded=<OptionalDegraded>, preserving recoverable choice' -ForEach @(@{RegistryFails=$false;OptionalDegraded=$false},@{RegistryFails=$true;OptionalDegraded=$false},@{RegistryFails=$false;OptionalDegraded=$true}) {
        $caseRegistryFails = $RegistryFails
        $caseOptionalDegraded = $OptionalDegraded
        $root = Join-Path $TestDrive 'Уфа ERPPM5 init с пробелом'
        New-Item -ItemType Directory -Force -Path (Join-Path $root '.agent-1c') | Out-Null
        @{aiRules=@{tools=@('codex')};baseConfigurationVersion='PM5'} | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $root '.agent-1c/project.json') -Encoding UTF8
        & {
            . $HelperPath -ProjectRoot $root -Action help -AgentTarget codex *> $null
            $InitMode = 'configured'
            $script:InitVibecoding1cMcpSetupRequested = $true
            function Get-Vibecoding1cMcpRegistryRoot { $root }
            $script:refreshes = 0
            function Update-Vibecoding1cMcpRegistryCheckout { $script:refreshes++; if ($caseRegistryFails) { throw 'registry offline' } }
            function Read-Vibecoding1cMcpManifest { @{servers=@(@{id='codechecker';scope='global';name='1c-code-check-mcp'})} }
            function Get-Vibecoding1cMcpTargetScopes { @('global') }
            function Set-Vibecoding1cMcpSelection { throw 'Unexpected reselection' }
            @{schemaVersion=1;host=@{hostId='dev-ermakov'};configurations=@();servers=@(@{id='codechecker';scope='global';family='vibecoding1c';provider='remote';name='1c-code-check-mcp';url='http://127.0.0.1:1/mcp';health=$(if($caseOptionalDegraded){'running'}else{'missing'});status=$(if($caseOptionalDegraded){'running'}else{'missing'});functionalStatus=$(if($caseOptionalDegraded){'degraded'}else{''})})} | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $root 'registry.json') -Encoding UTF8
            Write-Vibecoding1cMcpSelection -Selection @{defaultProvider='remote';servers=@(@{id='codechecker';enabled=$true;provider='remote';hostId='dev-ermakov'})}
            if ($caseRegistryFails) {
                Write-ItlClientMcpEndpointSet -Requests @([pscustomobject]@{client='codex';owner='vibecoding1c';endpoints=@([pscustomobject]@{name='1c-code-check-mcp';url='http://previous.invalid/mcp';toolTimeoutSeconds=300})}) *> $null
            }
            # Only native 1C, dependency installation and unrelated Git/report
            # boundaries are fixtures. Selection/setup/start/config stay real.
            foreach ($name in @(
                'Assert-Agent1cInitialProjectRootPathBudget','Prepare-ConfiguredInitProjectSettings',
                'Apply-BootstrapWorkflowPackageProvenance','Sync-WorkflowManagedDependencyLockEntries',
                'Enter-ItlInitializationNativePhase','Initialize-SourceInfoBaseUnsafeActionProtection',
                'Complete-InitProjectSettingsPreparation','Check-Tools','Remove-ItlOnDemandStaleInstances',
                'Install-RoctupMcp','Install-VanessaMcpArtifacts','Install-ItlOnDemandMcp',
                'Ensure-GitRepository','Ensure-GitIgnore','Checkout-Master','Ensure-ItlPinnedOpenSpecGitAttributes',
                'Update-BaseFromRepository','Ensure-BranchSeed','Commit-AuthoritativeExportPathIfChanged',
                'Assert-BaselineDumpCommitted','Install-AiRules1c','Sync-ItlVanessaLibraries',
                'Update-AgentGuidanceBridge','Update-UserRules','Sync-KiloItlCommandSurface',
                'Invoke-CavemanPolicyTransition','Invoke-UiTestingPolicyTransition','Commit-IfChanged',
                'Assert-InitGitClean','Write-PostInitClientReloadHandoff','Write-KiloBrowserAutomationSummary',
                'Write-InitRunUserReport','Invoke-Vibecoding1cMcpSetupSelectionInheritance','Show-Vibecoding1cMcpStatus'
            )) { Set-Item -Path ('Function:' + $name) -Value {} }
            function Invoke-WithRunStatusHeartbeat { param([scriptblock]$Operation) & $Operation }
            function Get-InfoBaseKind { 'file' }
            function Get-SourceConfigurationGenerationId { 'fixture' }
            function Get-DevBranchInfoBaseRoot { $root }
            function Get-ExistingAuthoritativeExportResult { @{exportPath='src/cf'} }
            function Test-AiRulesUiTestingPolicySupport { $true }
            $script:browserSummaryCalls = 0
            function Write-KiloBrowserAutomationSummary { $script:browserSummaryCalls++ }
            $script:stages = @()
            function Set-RunStage { param($Stage,$Detail) $script:stages += $Stage }
            $initReport = @(Initialize-Project 3>&1 6>&1) -join [Environment]::NewLine
            if ($caseOptionalDegraded) { $initReport | Should -Match 'optional functional capability is degraded.*dependent verification is not passed' }
            $script:browserSummaryCalls | Should -Be 1
            $script:stages[-1] | Should -Be 'init.complete'
            $script:stages | Should -Contain 'init.commit-dump'
            $script:refreshes | Should -Be 1
            (Read-ItlClientMcpEntries -Client codex).'1c-code-check-mcp'.url | Should -Be $(if($caseRegistryFails){'http://previous.invalid/mcp'}else{'http://127.0.0.1:1/mcp'})
            if ($caseOptionalDegraded) {
                @(Get-Vibecoding1cMcpReadyClientConfigNames) | Should -Contain '1c-code-check-mcp'
            } else {
                @(Get-Vibecoding1cMcpReadyClientConfigNames) | Should -Not -Contain '1c-code-check-mcp'
            }
            (Read-Vibecoding1cMcpSelection).servers[0].hostId | Should -Be 'dev-ermakov'
        }
    }
}
