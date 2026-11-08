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

    It 'serializes the shared registry fetch and merge across independent processes' {
        $root = Join-Path $TestDrive 'Общий реестр MCP'
        $source = Join-Path $root 'source'
        $registry = Join-Path $root 'registry'
        $module = Join-Path (Split-Path -Parent $HelperPath) 'lib/agent-1c.vibecoding1c-mcp.ps1'
        New-Item -ItemType Directory -Path $source -Force | Out-Null

        function Invoke-FixtureGit {
            param([string[]]$Arguments)
            $output = & git @Arguments
            if ($LASTEXITCODE -ne 0) { throw "Fixture Git failed: $Arguments" }
            return $output
        }

        Invoke-FixtureGit @('-C', $source, 'init', '-b', 'main') | Out-Null
        Set-Content -LiteralPath (Join-Path $source 'registry.json') -Value '{"publishedAt":"first"}'
        Invoke-FixtureGit @('-C', $source, 'add', 'registry.json')
        Invoke-FixtureGit @('-C', $source, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.test', 'commit', '-m', 'first') | Out-Null
        Invoke-FixtureGit @('clone', '-q', $source, $registry)
        Set-Content -LiteralPath (Join-Path $source 'registry.json') -Value '{"publishedAt":"second"}'
        Invoke-FixtureGit @('-C', $source, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.test', 'commit', '-am', 'second') | Out-Null

        $worker = {
            param($Module, $CoordinationRoot, $Source, $Registry, $Role)
            $ErrorActionPreference = 'Stop'
            [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
            . (Join-Path (Split-Path -Parent $Module) 'agent-1c.core.ps1')
            . $Module
            function Get-Vibecoding1cMcpRegistryRoot { $Registry }
            function Get-Vibecoding1cMcpRegistryRepo { $Source }
            function Test-Vibecoding1cMcpRegistryPathOverride { $false }
            function Invoke-GitAt {
                param([string]$Root, [string[]]$Arguments)
                if ($Arguments[0] -eq 'merge') {
                    [IO.File]::WriteAllText((Join-Path $CoordinationRoot 'before-merge'), '')
                    $until = [DateTime]::UtcNow.AddSeconds(20)
                    while (-not [IO.File]::Exists((Join-Path $CoordinationRoot 'allow-merge'))) {
                        if ([DateTime]::UtcNow -ge $until) { throw 'Timed out waiting for the fixture to allow merge.' }
                        Start-Sleep -Milliseconds 25
                    }
                }
                Get-GitOutputAt $Root $Arguments | Out-Null
                if ($Arguments[0] -eq 'merge') {
                    [IO.File]::WriteAllText((Join-Path $CoordinationRoot 'merge-complete'), '')
                }
            }
            function Invoke-ItlCatalogGit {
                param([string]$Root, [string[]]$Arguments, [DateTime]$DeadlineUtc, [switch]$AllowFailure)
                if (-not [IO.File]::Exists((Join-Path $CoordinationRoot 'merge-complete'))) {
                    throw 'The second worker entered Git before the first finished merging.'
                }
                return @{exitCode=0;stdout=(Get-GitOutputAt $Root $Arguments) -join "`n"}
            }
            if ($Role -eq 'first') {
                Update-Vibecoding1cMcpRegistryCheckout | Out-Null
            } else {
                [IO.File]::WriteAllText((Join-Path $CoordinationRoot 'second-ready'), '')
                Update-Vibecoding1cMcpRegistryCheckout -DeadlineUtc ([DateTime]::UtcNow.AddSeconds(15)) | Out-Null
            }
            'completed'
        }
        function Wait-FixtureMarker {
            param([string]$Name, [System.Management.Automation.Job]$Job)
            $until = [DateTime]::UtcNow.AddSeconds(12)
            while (-not [IO.File]::Exists((Join-Path $root $Name))) {
                if ($Job.State -in @('Failed', 'Completed', 'Stopped')) {
                    Receive-Job -Job $Job -Keep -ErrorAction Stop | Out-Null
                    throw "Worker ended without marker: $Name ($($Job.State))"
                }
                if ([DateTime]::UtcNow -ge $until) { throw "Missing worker marker: $Name ($($Job.State))" }
                Start-Sleep -Milliseconds 25
            }
        }

        $jobs = @()
        try {
            $jobs += Start-Job -ScriptBlock $worker -ArgumentList $module, $root, $source, $registry, 'first'
            Wait-FixtureMarker 'before-merge' $jobs[0]
            $jobs += Start-Job -ScriptBlock $worker -ArgumentList $module, $root, $source, $registry, 'second'
            Wait-FixtureMarker 'second-ready' $jobs[1]
            # The second process has entered the operation while the first still owns Git.
            $jobs[1] | Wait-Job -Timeout 1 | Out-Null
            [IO.File]::WriteAllText((Join-Path $root 'allow-merge'), '')
            foreach ($job in $jobs) {
                Wait-Job -Job $job -Timeout 15 | Out-Null
                Receive-Job -Job $job -ErrorAction Stop | Should -Be 'completed'
                $job.State | Should -Be 'Completed'
            }
            (Invoke-FixtureGit @('-C', $registry, 'rev-parse', 'HEAD')) |
                Should -Be (Invoke-FixtureGit @('-C', $source, 'rev-parse', 'HEAD'))
            (Get-Content -Raw -LiteralPath (Join-Path $registry 'registry.json') | ConvertFrom-Json).publishedAt |
                Should -Be 'second'
        } finally {
            $jobs | Remove-Job -Force -ErrorAction SilentlyContinue
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
