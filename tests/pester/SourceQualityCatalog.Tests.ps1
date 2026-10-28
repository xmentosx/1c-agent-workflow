BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSupport.ps1')
    $context = Initialize-WorkflowPesterContext
    $RepoRoot = $context.RepoRoot
}

Describe 'Source quality catalog contracts' {
    It 'preserves fingerprint variants and file invalidation when one item prepares its input paths once' {
        . (Join-Path $RepoRoot 'scripts/quality-contracts.ps1')
        $tokens=$null;$errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'scripts/invoke-pester-shards.ps1'),[ref]$tokens,[ref]$errors)
        @($errors) | Should -BeNullOrEmpty
        $savedReceipt=Get-Variable -Name pesterRuntimeReceipt -Scope Script -ErrorAction SilentlyContinue
        try {
            & {
                $RepositoryRoot=Join-Path $TestDrive 'fingerprint путь с пробелом'
                New-Item -ItemType Directory -Force -Path $RepositoryRoot | Out-Null
                $trackedPaths=@('a.Tests.ps1','b.Tests.ps1','unknown.Tests.ps1','excluded.Tests.ps1','a.txt','b.txt','extra.txt')
                foreach($path in $trackedPaths){[IO.File]::WriteAllText((Join-Path $RepositoryRoot $path),$path,[Text.UTF8Encoding]::new($false))}
                $catalog=[pscustomobject]@{pesterNonReusableTests=@('excluded.Tests.ps1');contracts=@(
                    [pscustomobject]@{tests=@('a.Tests.ps1');paths=@('a.txt')}
                    [pscustomobject]@{tests=@('b.Tests.ps1');paths=@('b.txt')}
                )}
                $sharedInputs=@();$pesterExternalInputsByTest=@{'a.Tests.ps1'=@('ITL_AI_RULES_SOURCE_PATH')}
                $script:pesterRuntimeReceipt=[pscustomobject]@{status='known';identity=[pscustomobject]@{powerShellVersion=[string]$PSVersionTable.PSVersion;pesterVersion='fixture';identitySha256=('a'*64)}}
                foreach($name in @('Get-ShardRelativeTestPath','Get-TextSha256','Get-ShardInputDigest')) {
                    $definition=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true)
                    . ([scriptblock]::Create($definition.Extent.Text))
                }
                function Get-ShardTrackedFileIdentity {param($RelativePath,$AbsolutePath) (Get-FileHash -LiteralPath $AbsolutePath).Hash}
                function Get-ExternalInputIdentity {param($Name) "env:$Name=fixture"}
                $a=Join-Path $RepositoryRoot 'a.Tests.ps1';$prepared=$null
                $before=Get-ShardInputDigest -Paths @($a) -PreparedInputs ([ref]$prepared)
                $before | Should -Not -BeNullOrEmpty
                $variants=@(@{})+@(1..4|ForEach-Object {@{LegacyWorkerCount=$_}})+@(
                    @{LegacyWorkerCount=4;IncludeLegacyGlobalExternalInputs=$true}
                    @{LegacyWorkerCount=4;IncludeLegacyGlobalExternalInputs=$true;ExternalIdentityOverrides=@{ITL_AI_RULES_SOURCE_PATH='env:ITL_AI_RULES_SOURCE_PATH=<unset>'}}
                )
                foreach($variant in $variants) {
                    Get-ShardInputDigest -Paths @($a) -PreparedInputs ([ref]$prepared) @variant | Should -BeExactly (Get-ShardInputDigest -Paths @($a) @variant)
                }
                [IO.File]::AppendAllText((Join-Path $RepositoryRoot 'a.txt'),' changed input',[Text.UTF8Encoding]::new($false))
                $changed=Get-ShardInputDigest -Paths @($a) -PreparedInputs ([ref]$prepared)
                $changed | Should -Not -Be $before
                $changed | Should -BeExactly (Get-ShardInputDigest -Paths @($a))
                $withExtra=Get-ShardInputDigest -Paths @($a) -AdditionalInputs @('extra.txt') -PreparedInputs ([ref]$prepared)
                $withExtra | Should -Not -Be $changed
                $withExtra | Should -BeExactly (Get-ShardInputDigest -Paths @($a) -AdditionalInputs @('extra.txt'))
                $b=Join-Path $RepositoryRoot 'b.Tests.ps1'
                Get-ShardInputDigest -Paths @($b) -PreparedInputs ([ref]$prepared) | Should -BeExactly (Get-ShardInputDigest -Paths @($b))
                foreach($name in @('unknown.Tests.ps1','excluded.Tests.ps1')) {
                    Get-ShardInputDigest -Paths @((Join-Path $RepositoryRoot $name)) -PreparedInputs ([ref]$prepared) | Should -BeNullOrEmpty
                }
                # Bind the real classifier owner, so removing an actual cross-file
                # dependency cannot silently reuse a consumer's previous proof.
                $actualCatalog = Get-QualityContractCatalog -RepositoryRoot $RepoRoot
                $classifierOwner = @($actualCatalog.contracts | Where-Object id -eq 'verification-failure-classification')[0]
                $catalog = [pscustomobject]@{contracts=@($classifierOwner)}
                $trackedPaths = @($classifierOwner.paths) + @(Get-QualityContractReuseInputPaths -Contract $classifierOwner) + @($classifierOwner.tests)
                foreach ($path in $trackedPaths) {
                    $full = Join-Path $RepositoryRoot $path
                    [IO.Directory]::CreateDirectory((Split-Path -Parent $full)) | Out-Null
                    [IO.File]::WriteAllText($full, '# classifier fixture input', [Text.UTF8Encoding]::new($false))
                }
                $pesterExternalInputsByTest = @{}
                $consumer = Join-Path $RepositoryRoot 'tests/pester/VanessaRunnerTopology.Tests.ps1'
                $prepared = $null
                $prior = Get-ShardInputDigest -Paths @($consumer) -PreparedInputs ([ref]$prepared)
                $prior | Should -Not -BeNullOrEmpty
                foreach ($inputPath in @('.agents/skills/1c-workflow/scripts/lib/agent-1c.core.ps1', '.agents/skills/1c-workflow/scripts/lib/agent-1c.vanessa.ps1', '.agents/skills/1c-workflow/scripts/lib/agent-1c.runtime-values.ps1')) {
                    Get-ShardInputDigest -Paths @($consumer) -PreparedInputs ([ref]$prepared) | Should -BeExactly $prior
                    [IO.File]::AppendAllText((Join-Path $RepositoryRoot $inputPath), ' changed classifier input', [Text.UTF8Encoding]::new($false))
                    $fresh = Get-ShardInputDigest -Paths @($consumer) -PreparedInputs ([ref]$prepared)
                    $fresh | Should -Not -Be $prior -Because "$inputPath must invalidate the shared classifier consumer"
                    $fresh | Should -BeExactly (Get-ShardInputDigest -Paths @($consumer))
                    $prior = $fresh
                }
            }
        } finally {
            if($savedReceipt){$script:pesterRuntimeReceipt=$savedReceipt.Value}else{Remove-Variable -Name pesterRuntimeReceipt -Scope Script -ErrorAction SilentlyContinue}
        }
    }

    It 'invalidates whole-gate script inventory when the worker runtime helper changes' {
        $tokens=$null; $errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'scripts/check.ps1'),[ref]$tokens,[ref]$errors)
        @($errors) | Should -BeNullOrEmpty
        $definitions=foreach($name in @('Get-RelativeRepositoryPath','Get-CanonicalTextSha256','New-InventoryEntry','Test-HasExactInventory','Get-WorkflowGateScriptPaths')) {
            $function=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
            $function | Should -Not -BeNullOrEmpty
            $function.Extent.Text
        }
        & {
            param($FixtureRoot, $Definitions)
            foreach($definition in $Definitions) { . ([scriptblock]::Create($definition)) }
            $repoRoot=$FixtureRoot
            $paths=@(Get-WorkflowGateScriptPaths)
            foreach($path in $paths) {
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
                [IO.File]::WriteAllText($path,'# unchanged qualification input',[Text.UTF8Encoding]::new($true))
            }
            $relative=@($paths | ForEach-Object { Get-RelativeRepositoryPath -Path $_ -Root $repoRoot })
            $relative | Should -Contain 'scripts/invoke-pester-runtime.ps1'
            $inventory=@($paths | ForEach-Object { New-InventoryEntry -Path $_ -Root $repoRoot })
            Test-HasExactInventory -Entries $inventory -ActualPaths $relative -Root $repoRoot | Should -BeTrue
            Add-Content -LiteralPath (Join-Path $repoRoot 'scripts/invoke-pester-runtime.ps1') -Encoding UTF8 -Value '# changed runtime contract'
            Test-HasExactInventory -Entries $inventory -ActualPaths $relative -Root $repoRoot | Should -BeFalse
        } (Join-Path $TestDrive 'Whole gate Проект') $definitions
    }

    It 'allows the observed passing cold cohorts and retains bounded aggregate budgets' {
        . (Join-Path $RepoRoot 'scripts/quality-contracts.ps1')
        $catalog = Get-QualityContractCatalog -RepositoryRoot $RepoRoot
        # 2026-10-09: Targeted exhausted 2100s before an ~8-minute serial tail;
        # Full exhausted 2700s before a 642-second successful continuation.
        $catalog.budgets.targetedHardSeconds | Should -BeGreaterThan (2100 + 480 + 300)
        $catalog.budgets.fullHardSeconds | Should -BeGreaterThan (2700 + 642 + 300)
        $catalog.budgets.targetedHardSeconds | Should -BeLessThan $catalog.budgets.fullHardSeconds
        $catalog.budgets.developHardSeconds | Should -Be ($catalog.budgets.fullHardSeconds + $catalog.developJourneys.routes.upgrade.hardSeconds + $catalog.developJourneys.routes.fresh.hardSeconds)
        Get-ReleaseE2EBudgetProjection -QualityCatalog $catalog -StageCatalog (Get-QualityReleaseStageCatalog -RepositoryRoot $RepoRoot) | Should -Not -BeNullOrEmpty
    }

    It "keeps the short modes cheap and reserves broad proof for Develop and Release" {
        $path = Join-Path $RepoRoot "scripts\check.ps1"
        $tokens = $null
        $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
        @($errors) | Should -BeNullOrEmpty
        $text = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        $text | Should -Match '\[ValidateSet\("Targeted", "Smoke", "Fast", "Full", "Develop", "Release"\)\]'; $text | Should -Match '\[string\]\$Mode = "Smoke"'
        $text | Should -Match 'Fast is deprecated and now aliases Smoke'; $text | Should -Match 'resolve-targeted-tests\.ps1'; $text | Should -Match 'smokeTests'
        $text | Should -Match '\$journeyHardSeconds = Get-DevelopE2EJourneyHardBudgetSeconds -Catalog \$qualityCatalog -Journey \$Journey'
        $text | Should -Match 'TimeoutSeconds \$journeyHardSeconds'; $text | Should -Match 'TimeoutSeconds \$releaseE2EHardBudgetSeconds'; $text | Should -Not -Match 'TimeoutSeconds 14400'
        $text | Should -Match 'targetBudgetSeconds'; $text | Should -Match 'slowestStages'; $text | Should -Match 'ProgressPaths \(Join-Path \$outputRoot "pester-shards"\)'
        $text | Should -Match 'LastWriteTimeUtc\.Ticks'; $text | Should -Match '-ProgressPaths \$releaseProgressPaths -LogName "release-e2e"'
        . (Join-Path $RepoRoot "scripts\quality-contracts.ps1"); $catalog = Get-QualityContractCatalog -RepositoryRoot $RepoRoot
        Test-QualityContractCatalog -RepositoryRoot $RepoRoot -Catalog $catalog | Should -BeTrue
        $ownedTests = @($catalog.contracts | ForEach-Object { @($_.tests) } | ForEach-Object { ([string]$_).Replace('\\','/') } | Sort-Object -Unique); @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot "tests\pester") -File -Filter "*.Tests.ps1" | ForEach-Object { "tests/pester/$($_.Name)" } | Where-Object { $_ -notin $ownedTests }) | Should -BeNullOrEmpty
        @(Get-PublicLifecycleActions -RepositoryRoot $RepoRoot).Count | Should -BeGreaterThan 50
        $known = Resolve-QualityContractsForPaths -Catalog $catalog -Paths @("docs/путь с пробелами/пример.md", "scripts/source-delivery.ps1"); @($known.unknownPaths) | Should -BeNullOrEmpty
        @($known.tests) | Should -Contain "tests/pester/SourceDeliveryQueue.Tests.ps1"
        @($known.tests) | Should -Contain "tests/pester/ParserDocsBudgets.Tests.ps1"
        @($known.tests) | Should -Not -Contain "tests/pester/SourceDeliveryPublish.Tests.ps1"
        $unknown = Resolve-QualityContractsForPaths -Catalog $catalog -Paths @("unowned/новый файл.ps1")
        @($unknown.unknownPaths) | Should -Be @("unowned/новый файл.ps1")
        $retired = Resolve-QualityContractsForPaths -Catalog $catalog -Paths @("tests/pester/TriageContract.Tests.ps1")
        @($retired.tests) | Should -Be @("tests/pester/ParserDocsBudgets.Tests.ps1")
        $retiredDelivery = Resolve-QualityContractsForPaths -Catalog $catalog -Paths @("tests/pester/SourceDelivery.Tests.ps1")
        @($retiredDelivery.tests) | Should -Be @("tests/pester/SourceDeliveryPublish.Tests.ps1")
        foreach ($retiredExecutionTest in @(
            "AuxiliaryDatabaseAdmission", "DatabaseAccessModes", "DevBranchMutationAdmission",
            "DevBranchVerificationAdmission", "InitializationDatabaseAdmission", "LifecycleDatabaseContinuation",
            "MasterDatabaseAdmission", "OneCDatabaseRestorationJournal", "OneCFileRestorationJournal",
            "OneCNativeJournalPersistence", "OneCNativeOperationJournal", "OneCNativeRecoveryGeneration",
            "OneCNativeRunOwnership", "VanessaCleanupAdmission"
        )) {
            $retiredExecution = Resolve-QualityContractsForPaths -Catalog $catalog -Paths @("tests/pester/$retiredExecutionTest.Tests.ps1")
            @($retiredExecution.unknownPaths) | Should -BeNullOrEmpty
            @($retiredExecution.tests).Count | Should -Be 1
        }
        $sourceRules = Resolve-QualityContractsForPaths -Catalog $catalog -Paths @("AGENTS.md")
        @($sourceRules.tests) | Should -Contain "tests/pester/ParserDocsBudgets.Tests.ps1"
        @($sourceRules.tests) | Should -Not -Contain "tests/pester/SourceDeliveryPublish.Tests.ps1"
        $cutover = Resolve-QualityContractsForPaths -Catalog $catalog -Paths @(".agents/skills/1c-workflow/scripts/execution-guard-cutover.ps1")
        @($cutover.contracts.id) | Should -Contain "lifecycle"
        @($cutover.tests) | Should -Contain "tests/pester/ExecutionGuardCutover.Tests.ps1"
        $retiredProducer = Resolve-QualityContractsForPaths -Catalog $catalog -Paths @("tests/database-access-producers.json")
        @($retiredProducer.contracts.id) | Should -Contain "remote-performance"
        @($retiredProducer.tests) | Should -Contain "tests/pester/RemotePerformance.Tests.ps1"
        $roctupOnly = Resolve-QualityContractsForPaths -Catalog $catalog -Paths @(".agents/skills/1c-workflow/scripts/lib/agent-1c.roctup-mcp.ps1")
        @($roctupOnly.contracts.id) | Should -Be @("roctup-port-lifecycle")
        @($roctupOnly.tests) | Should -Be @("tests/pester/ArtifactCacheIsolation.Tests.ps1", "tests/pester/RoctupPortLifecycle.Tests.ps1")
        foreach ($sharedPath in @(".agents/skills/1c-workflow/scripts/lib/agent-1c.ports.ps1", ".agents/skills/1c-workflow/scripts/lib/agent-1c.lifecycle.ps1")) {
            $sharedSelection = Resolve-QualityContractsForPaths -Catalog $catalog -Paths @($sharedPath)
            @($sharedSelection.tests) | Should -Contain "tests/pester/RoctupPortLifecycle.Tests.ps1"
            @($sharedSelection.tests) | Should -Contain "tests/pester/PortRegistryLifecycle.Tests.ps1"
        }
        $unrelatedLifecycle = Resolve-QualityContractsForPaths -Catalog $catalog -Paths @(".agents/skills/1c-workflow/scripts/lib/agent-1c.core.ps1")
        @($unrelatedLifecycle.tests) | Should -Not -Contain "tests/pester/RoctupPortLifecycle.Tests.ps1"
        $onDemandOnly = Resolve-QualityContractsForPaths -Catalog $catalog -Paths @(".agents/skills/1c-workflow/scripts/lib/agent-1c.ondemand-mcp.ps1")
        @($onDemandOnly.contracts.id) | Should -Be @("develop-broker-input-scope", "mcp-hosts")
        @($onDemandOnly.tests) | Should -Contain "tests/pester/OnDemandMcp.Tests.ps1"
        @($onDemandOnly.tests) | Should -Contain "tests/pester/DevelopBrokerInputScope.Tests.ps1"
        $dependencyLockOnly = Resolve-QualityContractsForPaths -Catalog $catalog -Paths @("templates/dependency-lock.json")
        @($dependencyLockOnly.contracts.id) | Should -Be @("dependency-lock")
        @($dependencyLockOnly.tests) | Should -Contain "tests/pester/DependencyLocks.Tests.ps1"
        @($dependencyLockOnly.tests) | Should -Contain "tests/pester/GitHubDependencyFallback.Tests.ps1"
        @($dependencyLockOnly.tests) | Should -Contain "tests/pester/VanessaArtifactIntegration.Tests.ps1"
        @($dependencyLockOnly.tests) | Should -Not -Contain "tests/pester/BootstrapUpdate.Tests.ps1"
        @($catalog.smokeTests) | Should -Contain "tests/pester/SourceDeliveryProcessLifetime.Tests.ps1"
        @($catalog.smokeTests) | Should -Not -Contain "tests/pester/SourceDeliveryPublish.Tests.ps1"
        @($catalog.smokeTests) | Should -Not -Contain "tests/pester/SourceDeliveryQueue.Tests.ps1"
        @($catalog.smokeTests) | Should -Not -Contain "tests/pester/SourceDeliveryComponentPublication.Tests.ps1"
        $processOnly = Resolve-QualityContractsForPaths -Catalog $catalog -Paths @("scripts/source-delivery-process.ps1")
        @($processOnly.contracts.id) | Should -Be @("source-quality-catalog",'release-orchestration-tests', 'e2e-client-selection-tests', "source-delivery-process", "source-candidate-registration", 'source-e2e-disk-monitor', 'qualification-fixture-process-tests')
        @($processOnly.tests) | Should -Contain 'tests/pester/SourceE2EDiskMonitor.Tests.ps1'
        @($processOnly.tests) | Should -Contain 'tests/pester/SourceQualificationFixture.Tests.ps1'
        @($processOnly.tests) | Should -Contain 'tests/pester/SourceQualityCatalog.Tests.ps1'
        @($processOnly.tests) | Should -Contain "tests/pester/SourceDeliveryProcessLifetime.Tests.ps1"
        @($processOnly.tests) | Should -Contain "tests/pester/SourceDeliveryQueue.Tests.ps1"
        @($processOnly.tests) | Should -Contain "tests/pester/SourceDeliveryComponentPublication.Tests.ps1"
        $queueOnly = Resolve-QualityContractsForPaths -Catalog $catalog -Paths @("scripts/source-delivery-queue.ps1")
        $integrityOnly = Resolve-QualityContractsForPaths -Catalog $catalog -Paths @('scripts/source-delivery-integrity.ps1')
        @($integrityOnly.contracts.id) | Should -Be @('source-delivery-integrity')
        @($integrityOnly.tests) | Should -Be @('tests/pester/SourceDeliveryAdmission.Tests.ps1','tests/pester/SourceDeliveryCandidateIntegrity.Tests.ps1','tests/pester/SourceDeliveryFinalizerIntegrity.Tests.ps1')
        @($queueOnly.contracts.id) | Should -Be @("source-candidate-registration", "source-delivery-queue")
        @($queueOnly.tests) | Should -Be @("tests/pester/SourceDeliveryAdmission.Tests.ps1", "tests/pester/SourceDeliveryAuthority.Tests.ps1", "tests/pester/SourceDeliveryCandidateRegistration.Tests.ps1", "tests/pester/SourceDeliveryControllerRollback.Tests.ps1", "tests/pester/SourceDeliveryFrozenPlan.Tests.ps1", "tests/pester/SourceDeliveryFrozenPublication.Tests.ps1", "tests/pester/SourceDeliveryHistoricalTransition.Tests.ps1", "tests/pester/SourceDeliveryLegacyPlan.Tests.ps1", "tests/pester/SourceDeliveryOperationRecovery.Tests.ps1", "tests/pester/SourceDeliveryPublicationCleanup.Tests.ps1", "tests/pester/SourceDeliveryQueue.Tests.ps1")
        $componentOnly = Resolve-QualityContractsForPaths -Catalog $catalog -Paths @("scripts/source-delivery-component.ps1")
        @($componentOnly.contracts.id) | Should -Be @("source-delivery-component")
        @($componentOnly.tests) | Should -Be @("tests/pester/ImmutableDownloadRetry.Tests.ps1", "tests/pester/SourceDeliveryComponentPublication.Tests.ps1", "tests/pester/SourceDeliveryProcessLifetime.Tests.ps1")
        $postGatePaths = @(
            "scripts/source-delivery.ps1",
            "scripts/source-delivery-supervisor.ps1",
            "scripts/source-delivery-plan.ps1",
            "scripts/source-e2e-artifact-discovery.ps1",
            "scripts/source-delivery-resources.ps1",
            "scripts/release-artifact-paths.ps1",
            "scripts/source-delivery-ref-cleanup.ps1",
            "scripts/source-delivery-evidence.ps1",
            "scripts/source-delivery-process.ps1",
            "scripts/source-delivery-queue.ps1",
            "scripts/source-delivery-candidate.ps1",
            "scripts/source-delivery-integrity.ps1",
            "scripts/source-delivery-release-recovery.ps1",
            "scripts/source-delivery-component.ps1",
            "scripts/source-delivery-cleanup.ps1"
        )
        @($catalog.continuationScopes.deliveryPostGate) | Should -Be $postGatePaths
        foreach ($postGatePath in $postGatePaths) {
            @($catalog.continuationScopes.gate) | Should -Not -Contain $postGatePath
        }
        @($catalog.contracts.paths | ForEach-Object { @($_) } | Where-Object { [string]$_ -in @("*", "**", "*/*") }) | Should -BeNullOrEmpty
        $catalog.PSObject.Properties["baseline"] | Should -BeNullOrEmpty
        $shardRunner = Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\invoke-pester-shards.ps1") -Raw -Encoding UTF8
        $runnerAst=[Management.Automation.Language.Parser]::ParseInput($shardRunner,[ref]$null,[ref]$null)
        $serialAssignment=$runnerAst.Find({param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -ceq '$serialTestNames'},$true)
        $serialAssignment | Should -Not -BeNullOrEmpty
        . ([scriptblock]::Create($serialAssignment.Extent.Text))
        @($serialTestNames) | Should -Be @('CompactItlRunner.Tests.ps1','DependencyLocks.Tests.ps1','ReleaseGate.Tests.ps1',
            'ReleaseOrchestration.Tests.ps1','E2EClientSelection.Tests.ps1',
            'ReleaseSnapshotContinuation.Tests.ps1','ReleaseAdmission.Tests.ps1')
        $check = Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\check.ps1") -Raw -Encoding UTF8
        $check | Should -Match 'Invoke-PowerShellChild -ScriptPath \$shardRunner -Arguments \$shardArguments -TimeoutSeconds \$modeHardBudgetSeconds' -Because "the selected shard runner must use the Targeted contract budget instead of a second hard-coded limit"
        $check | Should -Match '-TimeoutSeconds \$pesterHardBudgetSeconds -ProgressPaths \(Join-Path \$outputRoot "pester-shards"\) -LogName "pester-shards"' -Because "the complete Pester inventory must use the catalog Full hard budget and treat shard artifacts as live progress"
        [int]$catalog.budgets.targetedHardSeconds | Should -BeGreaterOrEqual 1200
        [int]$catalog.budgets.fullHardSeconds | Should -BeGreaterOrEqual 1800
        [int]($catalog.contracts | Where-Object id -eq "source-delivery-candidate").budgetSeconds | Should -BeGreaterOrEqual 1200
    }

    It "uses bounded catalog workers for implicit Targeted and qualification while preserving explicit and legacy choices" {
        . (Join-Path $RepoRoot "scripts\quality-contracts.ps1")
        $catalog = Get-QualityContractCatalog -RepositoryRoot $RepoRoot
        [int]$catalog.pesterWorkers.targetedImplicitDefault | Should -Be 8
        Resolve-PesterWorkerCount -Mode Targeted -RequestedWorkerCount 3 -Explicit $false -Catalog $catalog -ProcessorCount 24 | Should -Be 8
        Resolve-PesterWorkerCount -Mode Targeted -RequestedWorkerCount 3 -Explicit $false -Catalog $catalog -ProcessorCount 2 | Should -Be 2
        Resolve-PesterWorkerCount -Mode Targeted -RequestedWorkerCount 3 -Explicit $false -Catalog $catalog -ProcessorCount 0 | Should -Be 1
        Resolve-PesterWorkerCount -Mode Targeted -RequestedWorkerCount 3 -Explicit $true -Catalog $catalog -ProcessorCount 8 | Should -Be 3
        Resolve-PesterWorkerCount -Mode Smoke -RequestedWorkerCount 3 -Explicit $false -Catalog $catalog -ProcessorCount 8 | Should -Be 3
        foreach ($mode in @("Full", "Develop", "Release")) {
            Resolve-PesterWorkerCount -Mode $mode -RequestedWorkerCount 3 -Explicit $false -Catalog $catalog -ProcessorCount 24 | Should -Be 8
            Resolve-PesterWorkerCount -Mode $mode -RequestedWorkerCount 3 -Explicit $false -Catalog $catalog -ProcessorCount 2 | Should -Be 2
            Resolve-PesterWorkerCount -Mode $mode -RequestedWorkerCount 8 -Explicit $true -Catalog $catalog -ProcessorCount 24 | Should -Be 8
            Resolve-PesterWorkerCount -Mode $mode -RequestedWorkerCount 3 -Explicit $true -Catalog $catalog -ProcessorCount 8 | Should -Be 3
            Resolve-PesterWorkerCount -Mode $mode -RequestedWorkerCount 3 -Explicit $false -Catalog ([pscustomobject]@{pesterWorkers=[ordered]@{targetedImplicitDefault=4}}) -ProcessorCount 8 | Should -Be 3
        }

        $check = Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\check.ps1") -Raw -Encoding UTF8
        $check | Should -Match '\[int\]\$PesterWorkers = 3'
        $check | Should -Match '\$pesterWorkersExplicit = \$PSBoundParameters\.ContainsKey\("PesterWorkers"\)'
        $check | Should -Match '"-WorkerCount", \[string\]\$effectivePesterWorkers, "-RequestedWorkerCount", \[string\]\$PesterWorkers'
        $check | Should -Match 'pesterWorkers = \[ordered\]@\{\s*requested = \[int\]\$PesterWorkers\s*explicit = \[bool\]\$pesterWorkersExplicit\s*effective = \[int\]\$effectivePesterWorkers'
        $focusedWrapper = Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\test.ps1") -Raw -Encoding UTF8
        $focusedWrapper | Should -Match '\$pesterWorkersExplicit = \$PSBoundParameters\.ContainsKey\("PesterWorkers"\)'
        $focusedWrapper | Should -Match '"-RequestedWorkerCount", \[string\]\$PesterWorkers'
        $focusedWrapper | Should -Match 'if \(-not \$pesterWorkersExplicit\) \{ \$runnerArguments \+= "-WorkerCountDefaulted" \}'
    }

    It "keeps the exact stabilization E owner selection and models four workers with hard-budget reserve" {
        . (Join-Path $RepoRoot "scripts\quality-contracts.ps1")
        $catalog = Get-QualityContractCatalog -RepositoryRoot $RepoRoot
        $ePaths = @(
            "docs/local-quality-gate.md", "docs/workflow-stabilization-history.md", "docs/workflow-stabilization-plan.md",
            "scripts/check.ps1", "scripts/pester-timings.json", "scripts/source-delivery-ref-cleanup.ps1", "scripts/source-delivery-supervisor.ps1",
            "tests/pester/LocalQualityGate.Tests.ps1", "tests/pester/SourceDelivery.TestSupport.ps1",
            "tests/pester/SourceDeliveryRefCleanup.Tests.ps1", "tests/pester/SourceDeliveryResourceLedger.Tests.ps1", "tests/quality-contracts.json"
        )
        $expectedTests = @(
            "tests/pester/AiRulesCompatibilityPromotion.Tests.ps1", "tests/pester/DevelopE2EQualification.Tests.ps1",
            "tests/pester/DevelopStaticQualificationCache.Tests.ps1", "tests/pester/ForkQualificationInventory.Tests.ps1", "tests/pester/FullInputProof.Tests.ps1", "tests/pester/HostTestSelection.Tests.ps1", "tests/pester/LocalGateTransport.Tests.ps1", "tests/pester/LocalQualityGate.Tests.ps1", "tests/pester/LocalShardCache.Tests.ps1", "tests/pester/LocalTargetedSelection.Tests.ps1",
            "tests/pester/ParserDocsBudgets.Tests.ps1", "tests/pester/ReleaseGate.Tests.ps1", "tests/pester/ReleaseRouting.Tests.ps1", "tests/pester/ReleaseProgressObservation.Tests.ps1", "tests/pester/RepositoryGitTransport.Tests.ps1",
            "tests/pester/SourceDeliveryAdmission.Tests.ps1", "tests/pester/SourceDeliveryAuthority.Tests.ps1", "tests/pester/SourceDeliveryCandidateIntegrity.Tests.ps1", "tests/pester/SourceDeliveryCandidateRegistration.Tests.ps1", "tests/pester/SourceDeliveryComponentPublication.Tests.ps1", "tests/pester/SourceDeliveryControllerRollback.Tests.ps1", "tests/pester/SourceDeliveryEvidenceRepair.Tests.ps1", "tests/pester/SourceDeliveryEvidenceRetention.Tests.ps1", "tests/pester/SourceDeliveryFinalizerIntegrity.Tests.ps1", "tests/pester/SourceDeliveryFrozenPlan.Tests.ps1", "tests/pester/SourceDeliveryFrozenPublication.Tests.ps1", "tests/pester/SourceDeliveryHistoricalTransition.Tests.ps1", "tests/pester/SourceDeliveryIncremental.Tests.ps1", "tests/pester/SourceDeliveryLegacyPlan.Tests.ps1", "tests/pester/SourceDeliveryOperationRecovery.Tests.ps1", "tests/pester/SourceDeliveryPlan.Tests.ps1",
            "tests/pester/SourceDeliveryProcessLifetime.Tests.ps1",
            "tests/pester/SourceDeliveryPublicationCleanup.Tests.ps1", "tests/pester/SourceDeliveryPublish.Tests.ps1", "tests/pester/SourceDeliveryPublishContinuation.Tests.ps1",
            "tests/pester/SourceDeliveryPublishQualification.Tests.ps1", "tests/pester/SourceDeliveryPublishRecovery.Tests.ps1",
            "tests/pester/SourceDeliveryPublishReleaseTrain.Tests.ps1", "tests/pester/SourceDeliveryQueue.Tests.ps1",
            "tests/pester/SourceDeliveryRefCleanup.Tests.ps1", "tests/pester/SourceDeliveryReleaseEvidenceRepair.Tests.ps1", "tests/pester/SourceDeliveryRemoteMovement.Tests.ps1", "tests/pester/SourceDeliveryReplan.Tests.ps1", "tests/pester/SourceDeliveryResourceLedger.Tests.ps1",
            "tests/pester/SourceQualityCatalog.Tests.ps1"
        )
        $expectedTests = @($expectedTests + @('tests/pester/DeliveryCandidatePlanBridge.Tests.ps1','tests/pester/DeliveryCatalogInputScope.Tests.ps1','tests/pester/DeliveryGoInputScope.Tests.ps1','tests/pester/DeliveryScenarioAuthentication.Tests.ps1','tests/pester/DeliveryScenarioComposition.Tests.ps1','tests/pester/DeliveryScenarioSelection.Tests.ps1','tests/pester/DeliverySetupInputScope.Tests.ps1','tests/pester/DevelopForkConsumerInventory.Tests.ps1') | Sort-Object)
        $selection = Resolve-QualityContractsForPaths -Catalog $catalog -Paths $ePaths
        @($selection.contracts.id | Sort-Object) | Should -Be @("develop-e2e-qualification-tests", "develop-fork-consumer-inventory", "develop-static-qualification-cache-tests", "documentation", "fork-qualification-inventory", "pester-full-input-proof", "release-progress-observation", "source-candidate-registration", "source-delivery-entrypoint", "source-delivery-evidence-retention", "source-delivery-fixtures", "source-delivery-incremental-inputs", "source-delivery-plan-checker", "source-delivery-ref-cleanup", "source-quality-catalog", "source-quality-gate")
        @($selection.tests) | Should -Be $expectedTests

        $observedSeconds = [ordered]@{
            "AiRulesCompatibilityPromotion.Tests.ps1" = 2.387; "DevelopE2EQualification.Tests.ps1" = 32.264
            "DevelopStaticQualificationCache.Tests.ps1" = 16.008; "LocalQualityGate.Tests.ps1" = 232.946
            "ParserDocsBudgets.Tests.ps1" = 12.688; "ReleaseGate.Tests.ps1" = 176.030; "ReleaseReadiness.Tests.ps1" = 104.107
            # The client-selection delta makes immutable Plan proof part of the entrypoint owner.
            # Native PS5 qualification on 2026-10-02 measured its complete 20-case suite at 29.530 seconds.
            "SourceDeliveryComponentPublication.Tests.ps1" = 200.522; "SourceDeliveryPlan.Tests.ps1" = 29.530
            "SourceDeliveryProcessLifetime.Tests.ps1" = 6.719
            "SourceDeliveryPublish.Tests.ps1" = 243.396; "SourceDeliveryPublishContinuation.Tests.ps1" = 252.135
            "SourceDeliveryPublishQualification.Tests.ps1" = 459.824; "SourceDeliveryPublishRecovery.Tests.ps1" = 332.610
            "SourceDeliveryPublishReleaseTrain.Tests.ps1" = 345.565; "SourceDeliveryQueue.Tests.ps1" = 351.430
            "SourceDeliveryRefCleanup.Tests.ps1" = 191.680; "SourceDeliveryResourceLedger.Tests.ps1" = 191.731
        }
        $trackedTimings = Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\pester-timings.json") -Raw -Encoding UTF8 | ConvertFrom-Json
        $updatedOrderingWeights = [ordered]@{
            "AiRulesCompatibilityPromotion.Tests.ps1"=3; "DevelopE2EQualification.Tests.ps1"=285
            "DevelopStaticQualificationCache.Tests.ps1"=17; "LocalQualityGate.Tests.ps1"=48
            "ParserDocsBudgets.Tests.ps1"=13; "ReleaseReadiness.Tests.ps1"=105
            "SourceDeliveryComponentPublication.Tests.ps1"=201; "SourceDeliveryPlan.Tests.ps1"=91
            "SourceDeliveryProcessLifetime.Tests.ps1"=7
            "SourceDeliveryResourceLedger.Tests.ps1"=192; "SourceDeliveryPublishContinuation.Tests.ps1"=253
            # 2026-10-25 original native files, four concurrent workers:
            # 168.641/128.145s, rounded up; assertions and cases unchanged.
            "SourceDeliveryPublishQualification.Tests.ps1"=169; "SourceDeliveryPublishRecovery.Tests.ps1"=129
            "SourceDeliveryPublishReleaseTrain.Tests.ps1"=346; "SourceDeliveryQueue.Tests.ps1"=192
        }
        [double]$trackedTimings.files.'LocalGateTransport.Tests.ps1' | Should -Be 20
        # 2026-10-24 ownership-bound/optional-shapes: 328.54/354.32s.
        # Round ordering weights up to 30s; historical observations below and
        # all verification deadlines remain unchanged.
        [double]$trackedTimings.files.'LocalTargetedSelection.Tests.ps1' | Should -Be 360
        [double]$trackedTimings.files.'LocalShardCache.Tests.ps1' | Should -Be 162
        [double]$trackedTimings.files.'CompactRunnerFreshContinuation.Tests.ps1' | Should -Be 183
        [double]$trackedTimings.files.'CompactRunnerLongContinuation.Tests.ps1' | Should -Be 145
        # ownership-bound worker: 214.386s with the new catalog validation.
        [double]$trackedTimings.files.'SourceQualityCatalog.Tests.ps1' | Should -Be 240
        # Preserved 36-case planner family: measured isolated worker costs, no watchdog changes.
        [double]$trackedTimings.files.'SourceDeliveryIncremental.Tests.ps1' | Should -Be 120
        [double]$trackedTimings.files.'DeliveryCandidatePlanBridge.Tests.ps1' | Should -Be 95
        [double]$trackedTimings.files.'DeliveryScenarioAuthentication.Tests.ps1' | Should -Be 88
        [double]$trackedTimings.files.'DeliveryCatalogInputScope.Tests.ps1' | Should -Be 84
        [double]$trackedTimings.files.'DeliveryGoInputScope.Tests.ps1' | Should -Be 159
        [double]$trackedTimings.files.'DeliveryScenarioSelection.Tests.ps1' | Should -Be 66
        [double]$trackedTimings.files.'DeliverySetupInputScope.Tests.ps1' | Should -Be 36
        [double]$trackedTimings.files.'DeliveryScenarioComposition.Tests.ps1' | Should -Be 100
        # Retained 955db4d1 worker results: 341s fixture and 338s replan.
        # Keep these costly files out of the default one-second tail.
        [double]$trackedTimings.files.'SourceQualificationFixture.Tests.ps1' | Should -Be 290
        [double]$trackedTimings.files.'SourceDeliveryReplan.Tests.ps1' | Should -Be 339
        foreach ($entry in $updatedOrderingWeights.GetEnumerator()) { [double]$trackedTimings.files.($entry.Key) | Should -Be ([double]$entry.Value) }
        # 012a1225 named worker JUnit: same original 56 expanded cases.
        # Individual case sums plus 5 seconds per file for setup, rounded up.
        [double]$trackedTimings.files.'PesterCacheCompatibility.Tests.ps1' | Should -Be 67
        [double]$trackedTimings.files.'PesterShardIdentity.Tests.ps1' | Should -Be 215
        [double]$trackedTimings.files.'ReleaseProgressObservation.Tests.ps1' | Should -Be 122
        [double]$trackedTimings.files.'E2EArtifactCleanup.Tests.ps1' | Should -Be 17
        [double]$trackedTimings.files.'ForkQualificationInventory.Tests.ps1' | Should -Be 6
        # The historical complete native file remains represented below. Its
        # transferred groups now have individual measured-cost ordering weights.
        [double]$trackedTimings.files."ReleaseGate.Tests.ps1" | Should -Be 10
        [double]$trackedTimings.files."ReleaseOrchestration.Tests.ps1" | Should -Be 285
        [double]$trackedTimings.files."DevelopManifestContinuation.Tests.ps1" | Should -Be 184
        [double]$trackedTimings.files."SourceDeliveryPublish.Tests.ps1" | Should -Be 260
        [double]$trackedTimings.files."SourceDeliveryRefCleanup.Tests.ps1" | Should -Be 305
        $estimate = {
            param([double[]]$ParallelSeconds, [double[]]$SerialSeconds, [int]$WorkerCount, [double]$OverheadSeconds)
            $lanes = New-Object double[] $WorkerCount
            foreach ($seconds in @($ParallelSeconds | Sort-Object -Descending)) {
                $lane = 0
                for ($index = 1; $index -lt $lanes.Count; $index++) { if ($lanes[$index] -lt $lanes[$lane]) { $lane = $index } }
                $lanes[$lane] += $seconds
            }
            $parallelCriticalPath = 0.0; foreach ($seconds in $lanes) { $parallelCriticalPath = [Math]::Max($parallelCriticalPath, $seconds) }
            $serialCriticalPath = 0.0; foreach ($seconds in $SerialSeconds) { $serialCriticalPath += $seconds }
            return $parallelCriticalPath + $serialCriticalPath + $OverheadSeconds
        }
        $serial = @([double]$observedSeconds["ReleaseGate.Tests.ps1"])
        $parallel = @($observedSeconds.GetEnumerator() | Where-Object Key -ne "ReleaseGate.Tests.ps1" | ForEach-Object { [double]$_.Value })
        # The first E run left about ten seconds outside shard execution; round that observed orchestration remainder up to 15 seconds.
        $overhead = 15.0
        $three = & $estimate $parallel $serial 3 $overhead
        $four = & $estimate $parallel $serial 4 $overhead
        # This E measurement motivated four workers under the then-current 20-minute budget.
        # A later capacity correction must not rewrite that historical comparison.
        $historicalHardSeconds = 1200.0
        $three | Should -BeGreaterThan $historicalHardSeconds
        ($historicalHardSeconds - $four) | Should -BeGreaterThan 200
        # Keep the historical measured comparison intact. Current selection
        # additionally owns aggregate-input and candidate-registration regressions.
        $currentParallel = @($observedSeconds.GetEnumerator() | Where-Object Key -notin @('ReleaseGate.Tests.ps1','SourceDeliveryQueue.Tests.ps1','SourceDeliveryPlan.Tests.ps1') | ForEach-Object { [double]$_.Value })
        $currentParallel += @('SourceDeliveryQueue.Tests.ps1','SourceDeliveryAuthority.Tests.ps1','SourceDeliveryOperationRecovery.Tests.ps1','SourceDeliveryPlan.Tests.ps1','SourceDeliveryIncremental.Tests.ps1','FullInputProof.Tests.ps1','SourceDeliveryCandidateRegistration.Tests.ps1','SourceDeliveryFrozenPublication.Tests.ps1','SourceDeliveryFrozenPlan.Tests.ps1','SourceDeliveryLegacyPlan.Tests.ps1','SourceDeliveryPublicationCleanup.Tests.ps1','SourceDeliveryCandidateIntegrity.Tests.ps1','SourceDeliveryFinalizerIntegrity.Tests.ps1','SourceDeliveryControllerRollback.Tests.ps1','SourceDeliveryEvidenceRepair.Tests.ps1','SourceDeliveryHistoricalTransition.Tests.ps1','SourceDeliveryReleaseEvidenceRepair.Tests.ps1','SourceDeliveryRemoteMovement.Tests.ps1','SourceDeliveryReplan.Tests.ps1','RepositoryGitTransport.Tests.ps1') | ForEach-Object { [double]$trackedTimings.files.$_ }
        $currentParallel += @(($catalog.contracts|Where-Object id -eq 'source-delivery-incremental-inputs').tests|Where-Object {$_ -ne 'tests/pester/SourceDeliveryIncremental.Tests.ps1'}|ForEach-Object {[double]$trackedTimings.files.(Split-Path $_ -Leaf)})
        $currentFour = & $estimate $currentParallel $serial 4 ($overhead + [double]$trackedTimings.files.'SourceDeliveryAdmission.Tests.ps1')
        ([double]$catalog.budgets.targetedHardSeconds - $currentFour) | Should -BeGreaterThan 200
    }

    It "fits the observed lifecycle cohort and mandatory serial tail without changing runtime watchdogs" {
        . (Join-Path $RepoRoot "scripts\quality-contracts.ps1")
        $catalog = Get-QualityContractCatalog -RepositoryRoot $RepoRoot
        $trackedTimings = Get-Content -LiteralPath (Join-Path $RepoRoot 'scripts/pester-timings.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $historicalPaths = @(
            ".agents/skills/1c-workflow/scripts/lib/agent-1c.lifecycle.ps1",
            ".agents/skills/1c-workflow/scripts/lib/agent-1c.vanessa.ps1",
            "openspec/changes/upgrade-ai-rules-upstream-20a083e5/evidence/c1-final-local-qualification.md",
            "openspec/changes/upgrade-ai-rules-upstream-20a083e5/test-plan.md",
            "templates/dependency-lock.json",
            "tests/pester/CompactItlRunner.Tests.ps1",
            "tests/pester/LifecycleOperationLock.Tests.ps1")
        $selection = Resolve-QualityContractsForPaths -Catalog $catalog -Paths $historicalPaths
        # Preserve the historical cohort counts; all ten moved groups are
        # additional current workers, with their own measured timing weights.
        $splitWorkflowConsumers=@(($catalog.contracts|Where-Object id -eq 'workflow-update-producers').tests|Where-Object {$_ -ne 'tests/pester/WorkflowUpdateRollback.Tests.ps1'})
        @($splitWorkflowConsumers|Where-Object {$_ -notin @($selection.tests)}).Count | Should -Be 0
        $productionPreparationConsumer = 'tests/pester/PlatformProductionPreparation.Tests.ps1'
        $gate6Tests = @(
            "tests/pester/PlatformGate6Trigger.Tests.ps1",
            "tests/pester/PlatformLegacyContext.Tests.ps1",
            "tests/pester/PlatformLegacyDiagnostics.Tests.ps1",
            "tests/pester/PlatformLegacyImpact.Tests.ps1",
            "tests/pester/PlatformLoadContinuation.Tests.ps1",
            "tests/pester/PlatformSourceCoverage.Tests.ps1",
            $productionPreparationConsumer)
        # Retain the original observed 57-file cohort. Gate 6, Mantis and
        # three extracted Release groups extend its explicit dependency set.
        $splitHostConsumers = @('tests/pester/HostMantis.Tests.ps1')
        $routingConsumer = 'tests/pester/ReleaseRouting.Tests.ps1'
        $standPreparationConsumer = 'tests/pester/SourceDeliveryStandPreparation.Tests.ps1'
        $splitReleaseConsumers = @('DevelopManifestContinuation','ReleaseAdmission','ReleaseOrchestration' | ForEach-Object { 'tests/pester/'+$_+'.Tests.ps1' })
        $readinessConsumers = @('tests/pester/ReleaseReadiness.Tests.ps1','tests/pester/DevelopE2EQualification.Tests.ps1')
        $compactConsumers = @('CompactRunnerFreshContinuation','CompactRunnerLongContinuation','CompactRunnerReports','CompactRunnerRouting','CompactRunnerWatchdog' | ForEach-Object { 'tests/pester/'+$_+'.Tests.ps1' })
        $snapshotConsumer = 'tests/pester/ContinuationStatusSnapshot.Tests.ps1'
        $changeModelConsumer = 'tests/pester/VerificationChangeModel.Tests.ps1'
        $qualificationConsumer = 'tests/pester/SourceQualificationFixture.Tests.ps1'
        $lifecycleConsumers = @('DevBranchWorktrees','DevBranchForkContinuation','DevBranchMergeRecovery','DevBranchCheck' | ForEach-Object { 'tests/pester/'+$_+'.Tests.ps1' })
        $checkConsumer = 'tests/pester/DevBranchCheck.Tests.ps1'
        $gitTransportConsumer = 'tests/pester/RepositoryGitTransport.Tests.ps1'
        $classificationConsumer = 'tests/pester/ToolingReadiness.Tests.ps1'
        $registrySetupConsumers = @('tests/pester/ProductProjectContext.Tests.ps1','tests/pester/ProductProjectSetup.Tests.ps1')
        $callerInputConsumer = 'tests/pester/ProductProjectCallerInput.Tests.ps1'
        $registryConsumers = @($registrySetupConsumers + @($callerInputConsumer))
        $autonomyConsumer = 'tests/pester/LifecycleGitContinuation.Tests.ps1'
        # Keep the historical 57/80 cohort. The third registry consumer proves
        # native input independently of setup; account for its own owner/budget
        # rather than changing the historical counts or dropping its selection.
        # The concurrent snapshot regression is another explicit addition.
        @($selection.tests | Where-Object { $_ -notin $splitWorkflowConsumers -and $_ -notin $gate6Tests -and $_ -notin $splitHostConsumers -and $_ -notin $splitReleaseConsumers -and $_ -notin $readinessConsumers -and $_ -notin $compactConsumers -and $_ -notin $lifecycleConsumers -and $_ -ne $qualificationConsumer -and $_ -ne $gitTransportConsumer -and $_ -ne $classificationConsumer -and $_ -notin $registryConsumers -and $_ -ne $autonomyConsumer -and $_ -ne $snapshotConsumer -and $_ -ne $changeModelConsumer -and $_ -ne $standPreparationConsumer }).Count | Should -Be 57
        @($selection.tests|Where-Object {$_ -notin $splitWorkflowConsumers -and $_ -notin $registryConsumers -and $_ -ne $productionPreparationConsumer -and $_ -ne $autonomyConsumer -and $_ -ne $snapshotConsumer -and $_ -ne $changeModelConsumer -and $_ -ne $checkConsumer -and $_ -ne $standPreparationConsumer}).Count | Should -Be 80
        @($selection.tests).Count | Should -Be (80 + $registryConsumers.Count + 6 + $splitWorkflowConsumers.Count)
        @($selection.tests) | Should -Contain $changeModelConsumer
        @($selection.tests) | Should -Contain $standPreparationConsumer
        foreach ($owner in @($catalog.contracts | Where-Object { $_.tests -contains 'tests/pester/ReleaseGate.Tests.ps1' })) {
            @($owner.tests) | Should -Contain $routingConsumer
        }
        $changeModelOwner=@($catalog.contracts|Where-Object id -eq 'vanessa-verification')[0]
        @($changeModelOwner.tests) | Should -Contain $changeModelConsumer
        @($changeModelOwner.paths) | Should -Contain '.agents/skills/1c-workflow/scripts/lib/agent-1c.verification-change.ps1'
        @($selection.tests) | Should -Contain $snapshotConsumer
        $snapshotOwner = @($catalog.contracts | Where-Object id -eq 'compact-helper-continuation-inputs')[0]
        @($snapshotOwner.tests) | Should -Contain $snapshotConsumer
        @($snapshotOwner.paths) | Should -Contain 'tests/pester/ContinuationStatusSnapshot.TestSupport.ps1'
        @(Get-QualityContractReuseInputPaths -Contract $snapshotOwner) | Should -Contain 'tests/pester/ContinuationStatusSnapshot.TestSupport.ps1'
        $snapshotSelection = Resolve-QualityContractsForPaths -Catalog $catalog -Paths @('tests/pester/ContinuationStatusSnapshot.TestSupport.ps1')
        @($snapshotSelection.tests) | Should -Be @(
            'tests/pester/CompactRunnerFreshContinuation.Tests.ps1',
            'tests/pester/CompactRunnerLongContinuation.Tests.ps1',
            'tests/pester/CompactRunnerRouting.Tests.ps1',
            $snapshotConsumer)
        @($selection.tests) | Should -Contain $autonomyConsumer
        foreach($test in $registryConsumers){@($selection.tests)|Should -Contain $test}
        $registryOwner=@($catalog.contracts|Where-Object id -eq 'product-project-setup')[0]
        @($registryOwner.tests|Sort-Object)|Should -Be $registrySetupConsumers
        $callerInputOwner=@($catalog.contracts|Where-Object id -eq 'product-project-caller-input')[0]
        @($callerInputOwner.tests)|Should -Be @($callerInputConsumer)
        foreach($path in @('agent-1c.lifecycle.ps1','agent-1c.core.ps1','agent-1c.vanessa.ps1','agent-1c.product-project-console.ps1')){
            @($callerInputOwner.paths)|Should -Contain ('.agents/skills/1c-workflow/scripts/lib/'+$path)
        }
        @($callerInputOwner.paths)|Should -Contain 'tests/fixtures/product-project-caller-input.ps1'
        @($registryOwner.paths)|Should -Contain '.agents/skills/1c-workflow/scripts/lib/agent-1c.lifecycle.ps1'
        @(Get-QualityContractReuseInputPaths -Contract $registryOwner)|Should -Contain '.agents/skills/1c-workflow/scripts/lib/agent-1c.product-project-runtime.ps1'
        @($selection.tests) | Should -Contain $classificationConsumer
        $classificationOwner = @($catalog.contracts | Where-Object id -eq 'verification-failure-classification')[0]
        @($classificationOwner.paths) | Should -Contain '.agents/skills/1c-workflow/scripts/lib/agent-1c.core.ps1'
        @($classificationOwner.paths) | Should -Contain '.agents/skills/1c-workflow/scripts/lib/agent-1c.vanessa.ps1'
        @($classificationOwner.tests) | Should -Contain 'tests/pester/VanessaRunnerTopology.Tests.ps1'
        $repairOwner = @($catalog.contracts | Where-Object id -eq 'verification-repair-session')[0]
        @($repairOwner.paths) | Should -Contain '.agents/skills/1c-workflow/scripts/lib/agent-1c.verification-modes.ps1'
        @($repairOwner.tests) | Should -Contain 'tests/pester/ToolingReadiness.Tests.ps1'
        @($repairOwner.tests) | Should -Contain 'tests/pester/LifecycleOperationLock.Tests.ps1'
        @(Get-QualityContractReuseInputPaths -Contract $repairOwner) | Should -Contain '.agents/skills/1c-workflow/scripts/lib/agent-1c.core.ps1'
        @(Get-QualityContractReuseInputPaths -Contract $repairOwner) | Should -Contain 'scripts/source-delivery-process.ps1'
        $transferOwner = @($catalog.contracts | Where-Object id -eq 'branch-refresh-result')[0]
        @(Get-QualityContractReuseInputPaths -Contract $transferOwner) | Should -Contain '.agents/skills/1c-workflow/scripts/lib/agent-1c.lifecycle.ps1'
        @($transferOwner.tests) | Should -Contain 'tests/pester/BranchSeedRefreshLite.Tests.ps1'
        @($selection.tests) | Should -Contain $gitTransportConsumer
        $gitTransportOwner = @($catalog.contracts | Where-Object id -eq 'repository-git-transport')[0]
        @($gitTransportOwner.paths) | Should -Contain '.agents/skills/1c-workflow/scripts/lib/agent-1c.lifecycle.ps1'
        @(Get-QualityContractReuseInputPaths -Contract $gitTransportOwner) | Should -Contain '.agents/skills/1c-workflow/scripts/lib/agent-1c.core.ps1'
        foreach ($test in $lifecycleConsumers) { @($selection.tests) | Should -Contain $test }
        @($selection.tests) | Should -Contain $qualificationConsumer
        foreach ($test in $gate6Tests) { @($selection.tests) | Should -Contain $test }
        foreach ($test in $splitHostConsumers) { @($selection.tests) | Should -Contain $test }
        foreach ($test in $splitReleaseConsumers) { @($selection.tests) | Should -Contain $test }
        foreach ($test in $readinessConsumers) { @($selection.tests) | Should -Contain $test }
        foreach ($test in $compactConsumers) { @($selection.tests) | Should -Contain $test }
        foreach ($test in @("DevBranchLifecycle", "CompactItlRunner", "DependencyLocks")) {
            @($selection.tests) | Should -Contain "tests/pester/$test.Tests.ps1"
        }
        # Source 0bc3ff21: prelude and the actual 55-file parallel cohort before the hard stop.
        $preludeSeconds = 84.859
        $parallelSpanSeconds = 917.257
        # Historical complete 38-case Compact plus the nine new passed durations from after-2,
        # and two corrected cases from after-nested-streaming. This is a capacity model,
        # not a claim that the complete 49-case file has passed or a new tracked timing weight.
        $oldCompactSeconds = 239.771
        $newCompactPassedSeconds = 240.7690454 + 13.436425 + 11.5876579
        $dependencySeconds = 14.161
        # Conservatively account for the new blob-pressure consumer without rewriting the historical measurements.
        $registryBudgetReserve=[double]$registryOwner.budgetSeconds + [double]$callerInputOwner.budgetSeconds
        # Named production-purpose/proof-final-result.json: 16 cases, 11.239s;
        # reserve 17s including rounded setup cost, without changing watchdogs.
        $productionPreparationSeconds = 17.0
        # continuation-status-snapshot/focused.json: four cases, 23.52s;
        # reserve 30s without rewriting the historical cohort measurements.
        $snapshotSeconds = 30.0
        # change-verification-model/owned-final: 15 cases, 135.982s in WinPS 5.1.
        # integration-cases adds the current-plan profile case at 6.18s.
        # Reserve 180s for this additional consumer; keep every historical cohort,
        # its observed timings and all runtime/hard watchdogs unchanged.
        $changeModelSeconds = 180.0
        [double]$changeModelOwner.budgetSeconds | Should -BeGreaterOrEqual $changeModelSeconds
        $estimatedCriticalPath = $preludeSeconds + $parallelSpanSeconds + $oldCompactSeconds + $newCompactPassedSeconds + $dependencySeconds + [double]$trackedTimings.files.'RepositoryGitTransport.Tests.ps1' + [double]$trackedTimings.files.'ToolingReadiness.Tests.ps1' + $registryBudgetReserve + $productionPreparationSeconds + $snapshotSeconds + $changeModelSeconds
        $estimatedCriticalPath | Should -BeGreaterThan 1200
        ([double]$catalog.budgets.targetedHardSeconds - $estimatedCriticalPath) | Should -BeGreaterThan 120
        # Catalog-only changes now select static catalog proof. An explicitly
        # changed process-suite test still selects itself; retain that closure.
        $splitIncrementalConsumers=@(($catalog.contracts|Where-Object id -eq 'source-delivery-incremental-inputs').tests|Where-Object {$_ -ne 'tests/pester/SourceDeliveryIncremental.Tests.ps1'})
        $currentSelection = Resolve-QualityContractsForPaths -Catalog $catalog -Paths @($historicalPaths + @(
            "docs/local-quality-gate.md",
            "openspec/changes/upgrade-ai-rules-upstream-20a083e5/tasks.md",
            "tests/pester/LocalQualityGate.Tests.ps1",
            "tests/pester/WorkflowUpdateRollback.Tests.ps1",
            "tests/quality-contracts.json"))
        # One additional real catalog consumer; historical observed timings above
        # remain unchanged, and the exact added selection is checked below. The
        # fork binding asserts over catalog entries, so it is a catalog consumer.
        $catalogInvariantConsumer = 'tests/pester/DevelopForkConsumerInventory.Tests.ps1'
        @($currentSelection.tests|Where-Object {$_ -notin $splitWorkflowConsumers -and $_ -notin $splitIncrementalConsumers -and $_ -notin $registryConsumers -and $_ -ne $productionPreparationConsumer -and $_ -ne $autonomyConsumer -and $_ -ne $snapshotConsumer -and $_ -ne $changeModelConsumer -and $_ -ne $checkConsumer -and $_ -ne $routingConsumer -and $_ -ne $standPreparationConsumer -and $_ -ne $catalogInvariantConsumer}).Count | Should -Be 84
        @($currentSelection.tests).Count | Should -Be (84 + $registryConsumers.Count + 6 + $splitWorkflowConsumers.Count + $splitIncrementalConsumers.Count + 1)
        @($currentSelection.tests | Where-Object { $_ -notin $selection.tests -and $_ -notin $splitIncrementalConsumers }) | Should -Be @(
            $catalogInvariantConsumer,
            "tests/pester/HostTestSelection.Tests.ps1",
            "tests/pester/LocalQualityGate.Tests.ps1",
            "tests/pester/SourceDeliveryIncremental.Tests.ps1",
            "tests/pester/SourceQualityCatalog.Tests.ps1")
        @($splitIncrementalConsumers|Where-Object {$_ -notin @($currentSelection.tests)}).Count | Should -Be 0
        # Historical catalog-wide scheduler weights/four lanes, retained for comparison:
        # parallel 936.459, old complete ReleaseGate 198.938. No cache reuse is assumed.
        $currentParallelSpanSeconds = 936.459
        $serialReleaseSeconds = 198.938
        # Retain the lifecycle owner's measured 33.218 seconds in the combined
        # capacity model; no removed cohort, timeout change or cache assumption.
        $autonomyObservedSeconds = 33.218
        [double]$trackedTimings.files.'LifecycleGitContinuation.Tests.ps1' | Should -Be ([Math]::Ceiling($autonomyObservedSeconds))
        $currentEstimatedCriticalPath = $preludeSeconds + $currentParallelSpanSeconds + $serialReleaseSeconds + $oldCompactSeconds + $newCompactPassedSeconds + $dependencySeconds + $registryBudgetReserve + $autonomyObservedSeconds + $snapshotSeconds + $changeModelSeconds
        $currentEstimatedCriticalPath | Should -BeGreaterThan $estimatedCriticalPath
        ([double]$catalog.budgets.targetedHardSeconds - $currentEstimatedCriticalPath) | Should -BeGreaterOrEqual 120
        [double]$catalog.budgets.targetedHardSeconds | Should -BeLessThan ([double]$catalog.budgets.fullHardSeconds)
    }

    It 'keeps <Family> scenario selection independent while binding every shared producer and fixture' -TestCases @(
        @{Family='workflow';Owner='workflow-update-producers';Count=11;Support='WorkflowUpdateRollback.TestSupport.ps1';Runtime='.agents/skills/1c-workflow/scripts/lib/agent-1c.lifecycle.ps1'},
        @{Family='planner';Owner='source-delivery-incremental-inputs';Count=8;Support='SourceDeliveryIncremental.TestSupport.ps1';Runtime='scripts/source-delivery-plan.ps1'}
    ) {
        param($Family,$Owner,$Count,$Support,$Runtime)
        . (Join-Path $RepoRoot 'scripts/quality-contracts.ps1')
        $catalog=Get-QualityContractCatalog $RepoRoot
        $producer=@($catalog.contracts|Where-Object id -eq $Owner)[0]
        $groups=@($producer.tests)
        $groups.Count | Should -Be $Count
        foreach($file in $groups) {
            @((Resolve-QualityContractsForPaths $catalog @($file)).tests) | Should -Be @($file)
        }
        @((Resolve-QualityContractsForPaths $catalog @('tests/pester/'+$Support)).tests) | Should -Be @($groups|Sort-Object)
        $runtimeSelection=Resolve-QualityContractsForPaths $catalog @($Runtime)
        @($groups|Where-Object {$_ -notin @($runtimeSelection.tests)}) | Should -BeNullOrEmpty
        $sibling=Resolve-QualityContractsForPaths $catalog @('tests/pester/UiTestingPolicyTransition.Tests.ps1')
        @($sibling.tests|Where-Object {$_ -in $groups}) | Should -BeNullOrEmpty
        $invalid=$catalog|ConvertTo-Json -Depth 32|ConvertFrom-Json
        $rule=@($invalid.developJourneys.scenarioInputs|Where-Object {$_.PSObject.Properties['outsideWhenNoProductContext'] -and $_.outsideWhenNoProductContext})[0]
        $rule.PSObject.Properties.Remove('requiresNoProductContext')
        {Test-QualityContractCatalog $RepoRoot $invalid} | Should -Throw '*DEVELOP_SCENARIO_INPUT_INVALID*'
    }

    It "binds every PowerShell Core boundary test to the Core runtime profile" {
        $actualCatalog = Get-Content -LiteralPath (Join-Path $RepoRoot 'tests/quality-contracts.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $actualCatalog.pesterExternalRuntimeProfiles.'powershell-core'.kind | Should -BeExactly 'powershell-core'
        $coreUsers = @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'tests/pester') -Filter '*.Tests.ps1' | Where-Object {
            $tokens = $null; $errors = $null
            $ast = [Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors)
            $null -ne $ast.Find({ param($node)
                ($node -is [Management.Automation.Language.CommandAst] -and [string]$node.GetCommandName() -match '^pwsh(\.exe)?$') -or
                ($node -is [Management.Automation.Language.StringConstantExpressionAst] -and $node.Value -match '^pwsh(\.exe)?$') }, $true)
        } | ForEach-Object { 'tests/pester/' + $_.Name } | Sort-Object)
        $coreUsers | Should -Contain 'tests/pester/CompactRunnerRouting.Tests.ps1'
        $declared = @($actualCatalog.pesterExternalRuntimeTests.PSObject.Properties | Where-Object { 'powershell-core' -in @($_.Value) } | ForEach-Object { $_.Name } | Sort-Object)
        ($declared -join "`n") | Should -BeExactly ($coreUsers -join "`n")
    }

    It "does not cache a shard whose external runtime identity is not modeled" {
        $runnerPath = Join-Path $RepoRoot 'scripts/invoke-pester-shards.ps1'
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($runnerPath, [ref]$tokens, [ref]$errors)
        $pathDefinition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-ShardRelativeTestPath' }, $true)
        $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-ShardInputDigest' }, $true)
        $actualCatalog = Get-Content -LiteralPath (Join-Path $RepoRoot 'tests/quality-contracts.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        @($actualCatalog.pesterNonReusableTests) | Should -Not -Contain 'tests/pester/VanessaNestedSelection.Tests.ps1'
        @($actualCatalog.pesterExternalRuntimeTests.'tests/pester/VanessaNestedSelection.Tests.ps1') | Should -Contain 'onescript'
        $result = & {
            $RepositoryRoot = $RepoRoot
            # Contracts and hashing dependencies deliberately absent: the
            # runtime exclusion must apply before any cache key is produced.
            $catalog = [pscustomobject]@{ pesterNonReusableTests = @('tests/pester/VanessaNestedSelection.Tests.ps1') }
            . ([scriptblock]::Create($pathDefinition.Extent.Text))
            . ([scriptblock]::Create($definition.Extent.Text))
            $path = Join-Path $RepoRoot 'tests/pester/VanessaNestedSelection.Tests.ps1'
            @((Get-ShardInputDigest -Paths @($path)), (Get-ShardInputDigest -Paths @($path) -IncludeLegacyGlobalExternalInputs))
        }
        @($result | Where-Object { $_ }) | Should -BeNullOrEmpty
    }

    It "classifies Release readiness repairs as resumable Release harness changes" {
        $catalog = Get-Content -LiteralPath (Join-Path $RepoRoot "tests\quality-contracts.json") -Raw -Encoding UTF8 | ConvertFrom-Json
        @($catalog.continuationScopes.release) | Should -Contain "scripts/test-release-readiness.ps1"
    }
}

Describe 'Develop journey catalog hard budgets' {
    BeforeAll {
        . (Join-Path $RepoRoot 'scripts\quality-contracts.ps1')
    }

    It 'retains the original deadlines when an older catalog omits route budgets' {
        $catalog = Get-QualityContractCatalog -RepositoryRoot $RepoRoot
        $catalog.developJourneys.routes.upgrade.PSObject.Properties.Remove('hardSeconds')
        $catalog.developJourneys.routes.fresh.PSObject.Properties.Remove('hardSeconds')
        Get-DevelopE2EJourneyHardBudgetSeconds -Catalog $catalog -Journey upgrade | Should -Be 1200
        Get-DevelopE2EJourneyHardBudgetSeconds -Catalog $catalog -Journey fresh | Should -Be 2100
        Test-QualityContractCatalog -RepositoryRoot $RepoRoot -Catalog $catalog | Should -BeTrue
    }

    It 'uses explicit positive integer route budgets and the complete Develop aggregate' {
        $catalog = Get-QualityContractCatalog -RepositoryRoot $RepoRoot
        Get-DevelopE2EJourneyHardBudgetSeconds -Catalog $catalog -Journey upgrade | Should -Be 5400
        Get-DevelopE2EJourneyHardBudgetSeconds -Catalog $catalog -Journey fresh | Should -Be 3600
        [int]$catalog.budgets.developHardSeconds | Should -Be 13200
        ([int]$catalog.budgets.fullHardSeconds +
            (Get-DevelopE2EJourneyHardBudgetSeconds -Catalog $catalog -Journey upgrade) +
            (Get-DevelopE2EJourneyHardBudgetSeconds -Catalog $catalog -Journey fresh)) | Should -Be 13200
        Test-QualityContractCatalog -RepositoryRoot $RepoRoot -Catalog $catalog | Should -BeTrue
        $map = @{ developJourneys=@{ routes=@{ fresh=@{ hardSeconds=[long]3600 } } } }
        Get-DevelopE2EJourneyHardBudgetSeconds -Catalog $map -Journey fresh | Should -Be 3600
    }

    It 'refuses a present invalid route budget instead of using a legacy default: <label>' -ForEach @(
        @{ label='null'; budget=$null }
        @{ label='zero'; budget=0 }
        @{ label='negative'; budget=-1 }
        @{ label='fraction'; budget=3600.5 }
        @{ label='numeric string'; budget='3600' }
        @{ label='boolean'; budget=$true }
        @{ label='array'; budget=@(3600,3600) }
        @{ label='overflow'; budget=[long]2147483648 }
    ) {
        $catalog = Get-QualityContractCatalog -RepositoryRoot $RepoRoot
        $catalog.developJourneys.routes.fresh.hardSeconds = $budget
        { Get-DevelopE2EJourneyHardBudgetSeconds -Catalog $catalog -Journey fresh } |
            Should -Throw '*QUALITY_DEVELOP_JOURNEY_BUDGET_INVALID*'
        { Test-QualityContractCatalog -RepositoryRoot $RepoRoot -Catalog $catalog } |
            Should -Throw '*QUALITY_DEVELOP_JOURNEY_BUDGET_INVALID*'
    }
}

Describe 'Shared Release budget projection' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        $budgetRepoRoot = $context.RepoRoot
        . (Join-Path $budgetRepoRoot 'scripts/quality-contracts.ps1')
        . (Join-Path $budgetRepoRoot 'scripts/source-delivery-process.ps1')
        function Get-BudgetOwnerAst {
            param([string]$RelativePath)
            $tokens = $null; $errors = $null
            $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $budgetRepoRoot $RelativePath), [ref]$tokens, [ref]$errors)
            if (@($errors).Count) { throw "Budget owner did not parse: $RelativePath" }
            return $ast
        }
    }

    It 'projects full and selected dependency budgets without broadening capability scope' {
        $stages = Get-QualityReleaseStageCatalog -RepositoryRoot $budgetRepoRoot
        $quality = Get-QualityContractCatalog -RepositoryRoot $budgetRepoRoot
        $full = Get-ReleaseE2EBudgetProjection -StageCatalog $stages -QualityCatalog $quality -RequireRelease
        $full.capabilities | Should -Be @($stages.stages.id)
        $full.fullStageSeconds | Should -Be 11700
        $full.enclosingOverheadSeconds | Should -Be 1140
        $full.e2eHardSeconds | Should -Be 12840
        $full.gateHardSeconds | Should -Be ($quality.budgets.fullHardSeconds + $full.e2eHardSeconds)
        $full.gateHardSeconds | Should -Be $quality.budgets.releaseHardSeconds
        $partial = Get-ReleaseE2EBudgetProjection -StageCatalog $stages -QualityCatalog $quality -ReleaseCapability @('extension-smoke','ondemand-mcp','verification-refresh','result-cleanup','extension-smoke')
        $partial.capabilities | Should -Be @('config-cadence','extension-smoke','ondemand-mcp','verification-refresh','result-cleanup')
        $partial.summedStageSeconds | Should -Be 8400
        $partial.e2eHardSeconds | Should -Be 9540
        $onlyMcp = Get-ReleaseE2EBudgetProjection -StageCatalog $stages -QualityCatalog $quality -ReleaseCapability 'ondemand-mcp'
        $onlyMcp.capabilities | Should -Be @('ondemand-mcp')
        $onlyMcp.e2eHardSeconds | Should -Be 2640
        $onlyMcp.gateHardSeconds | Should -Be $full.gateHardSeconds
        $none = Get-ReleaseE2EBudgetProjection -StageCatalog $stages -QualityCatalog $quality
        @($none.capabilities).Count | Should -Be 0
        $none.e2eHardSeconds | Should -Be 0
    }

    It 'keeps the old pinned supervisor allowance equal to the validated full projection' {
        $stages = Get-QualityReleaseStageCatalog -RepositoryRoot $budgetRepoRoot
        $quality = Get-QualityContractCatalog -RepositoryRoot $budgetRepoRoot
        $projection = Get-ReleaseE2EBudgetProjection -StageCatalog $stages -QualityCatalog $quality -RequireRelease
        # Exact legacy wire consumer: it only reads the serialized quality field.
        $oldCatalog = Get-Content -LiteralPath (Join-Path $budgetRepoRoot 'tests/quality-contracts.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $oldPinnedAllowance = [int]$oldCatalog.budgets.releaseHardSeconds + 300
        $oldPinnedAllowance | Should -Be ($projection.gateHardSeconds + 300)
        Get-SourceGateHardBudgetSeconds -Mode Release -WorkingRoot $budgetRepoRoot | Should -Be $oldPinnedAllowance
        Get-SourceGateSupervisionBudgetSeconds -Mode Release -WorkingRoot $budgetRepoRoot -PlanBudgetSeconds 8940 | Should -Be $oldPinnedAllowance
        $largerPlanBudget = $oldPinnedAllowance + 1000
        Get-SourceGateSupervisionBudgetSeconds -Mode Release -WorkingRoot $budgetRepoRoot -PlanBudgetSeconds $largerPlanBudget | Should -Be $largerPlanBudget
        $quality.budgets.releaseHardSeconds--
        { Get-ReleaseE2EBudgetProjection -StageCatalog $stages -QualityCatalog $quality -RequireRelease } | Should -Throw '*PROJECTION_MISMATCH*'
    }

    It 'retains old candidate budgets but rejects a malformed present contract and cycles' {
        $stages = Get-QualityReleaseStageCatalog -RepositoryRoot $budgetRepoRoot
        $quality = Get-QualityContractCatalog -RepositoryRoot $budgetRepoRoot
        $stages.PSObject.Properties.Remove('enclosingOverheadSeconds')
        ($stages.stages | Where-Object id -eq 'config-cadence').budgetSeconds = 1200
        $quality.budgets.releaseHardSeconds = 7200
        $old = Get-ReleaseE2EBudgetProjection -StageCatalog $stages -QualityCatalog $quality -ReleaseCapability 'extension-smoke'
        $old.usesLegacyModeBudget | Should -BeTrue
        $old.stageBudgets['config-cadence'] | Should -Be 1200
        $old.e2eHardSeconds | Should -Be 7200
        $old.gateHardSeconds | Should -Be 7200
        $stages | Add-Member -NotePropertyName enclosingOverheadSeconds -NotePropertyValue $null
        foreach ($bad in @($null, 0, -1, '1140', 1.5, [long]2147483648)) {
            $stages.enclosingOverheadSeconds = $bad
            { Get-ReleaseE2EBudgetProjection -StageCatalog $stages -QualityCatalog $quality -RequireRelease } | Should -Throw '*BUDGET_INVALID*'
        }
        $stages.enclosingOverheadSeconds = 1140
        ($stages.stages | Where-Object id -eq 'config-cadence').dependsOn = @('extension-smoke')
        { Resolve-QualityReleaseCapabilities -Catalog $stages -ReleaseCapability 'extension-smoke' } | Should -Throw '*DEPENDENCY_CYCLE*'
    }

    It 'passes the selected projection to the real child call and retains enclosing timeout clipping' {
        $ast = Get-BudgetOwnerAst -RelativePath 'scripts/check.ps1'
        $qualityCatalog = Get-QualityContractCatalog -RepositoryRoot $budgetRepoRoot
        $repoRoot = $budgetRepoRoot
        $effectiveMode = 'Release'
        $selectedReleaseCapabilities = @('extension-smoke','ondemand-mcp','verification-refresh','result-cleanup')
        $initialization = @($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.IfStatementAst] -and $_.Extent.Text.Contains('$releaseBudget = Get-ReleaseE2EBudgetProjection') })
        $initialization.Count | Should -Be 1
        . ([scriptblock]::Create($initialization[0].Extent.Text))
        $modeHardBudgetSeconds | Should -Be 17040
        $releaseE2EHardBudgetSeconds | Should -Be 9540
        $call = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Invoke-PowerShellChild' -and $node.Extent.Text.Contains('-LogName "release-e2e"') }, $true))
        $call.Count | Should -Be 1
        function Invoke-PowerShellChild {
            param($ScriptPath, $Arguments, $TimeoutSeconds, $NoProgressSeconds, $ProgressPaths, $LogName)
            [pscustomobject]@{ timeout=$TimeoutSeconds; noProgress=$NoProgressSeconds; name=$LogName }
        }
        $e2eScript = 'fixture'; $releaseE2EArguments = @(); $releaseProgressPaths = @()
        $observed = & ([scriptblock]::Create($call[0].Extent.Text))
        $observed.timeout | Should -Be 9540
        $observed.noProgress | Should -Be 900
        $wait = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Wait-PowerShellChildProcess' }, $true)
        $clip = @($wait.Body.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -in @('$remainingOverallSeconds', '$effectiveTimeoutSeconds') })
        $clip.Count | Should -Be 2
        $TimeoutSeconds = $observed.timeout
        $overallStopwatch = [pscustomobject]@{ Elapsed=[timespan]::FromSeconds(8600) }
        foreach ($statement in $clip) { . ([scriptblock]::Create($statement.Extent.Text)) }
        $effectiveTimeoutSeconds | Should -Be 8440
        $overallStopwatch = [pscustomobject]@{ Elapsed=[timespan]::FromSeconds(10) }
        foreach ($statement in $clip) { . ([scriptblock]::Create($statement.Extent.Text)) }
        $effectiveTimeoutSeconds | Should -Be 9540
    }

    It 'forwards the remaining original cadence deadline to the unchanged helper timeout owner' {
        $ast = Get-BudgetOwnerAst -RelativePath 'scripts/invoke-release-e2e.ps1'
        $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Complete-E2EHelperProcess' }, $true)
        . ([scriptblock]::Create($definition.Extent.Text))
        $process = [pscustomobject]@{ Handle=1; ExitCode=0; ExitTime=[DateTime]::UtcNow; timedWaits=[Collections.Generic.List[int]]::new() }
        $process | Add-Member ScriptMethod WaitForExit { param($milliseconds) if ($null -ne $milliseconds) { $this.timedWaits.Add([int]$milliseconds); return $true } }
        $process | Add-Member ScriptMethod Refresh {}
        $invocation = [pscustomobject]@{ process=$process; action='check-dev-branch'; stdoutPath='fixture.out'; stderrPath='fixture.err'; exitedAtUtc=$null }
        $script:activeStageName = 'config-cadence'
        $catalog = Get-QualityReleaseStageCatalog -RepositoryRoot $budgetRepoRoot
        $cadenceSeconds = [int]($catalog.stages | Where-Object id -eq 'config-cadence').budgetSeconds
        # A slow first metadata check consumes the observed fresh-check envelope.
        $remainingModelSeconds = $cadenceSeconds - 1773
        $script:activeStageDeadlineUtc = [DateTime]::UtcNow.AddSeconds($remainingModelSeconds)
        try {
            $result = Complete-E2EHelperProcess -Invocation $invocation -TimeoutSeconds 7200
            $result.exitCode | Should -Be 0
            $process.timedWaits.Count | Should -Be 1
            $process.timedWaits[0] | Should -BeGreaterThan 1773000
            $process.timedWaits[0] | Should -BeLessOrEqual ($remainingModelSeconds * 1000)
        } finally { $script:activeStageDeadlineUtc = $null; $script:activeStageName = '' }
    }
}

Describe 'Catalog selection and qualified consumer inputs' {
    It 'keeps static qualification cache independent of unused scheduler and catalog inputs' {
        . (Join-Path $RepoRoot 'scripts/quality-contracts.ps1')
        $catalog=Get-QualityContractCatalog -RepositoryRoot $RepoRoot
        $test='tests/pester/DevelopStaticQualificationCache.Tests.ps1'
        foreach($path in @('scripts/pester-timings.json','scripts/invoke-pester-shards.ps1','scripts/run-pester-shard.ps1','scripts/quality-contracts.ps1','scripts/resolve-targeted-tests.ps1','scripts/develop-e2e-qualification.ps1','scripts/stand-env-identity.ps1','tests/quality-contracts.json')) {
            $selected=Resolve-QualityContractsForPaths -Catalog $catalog -Paths @($path)
            @($selected.unknownPaths) | Should -BeNullOrEmpty
            @($selected.tests) | Should -Not -Contain $test -Because "$path is not consumed by the static qualification cache fixtures"
        }
        foreach($path in @('scripts/check.ps1','scripts/develop-static-qualification.ps1','scripts/release-qualification.ps1','scripts/invoke-pester-runtime.ps1','scripts/git-path-list.ps1')) {
            @(Resolve-QualityContractsForPaths -Catalog $catalog -Paths @($path) | Select-Object -ExpandProperty tests) | Should -Contain $test
        }
        @(Resolve-QualityContractsForPaths -Catalog $catalog -Paths @($test) | Select-Object -ExpandProperty tests) | Should -Be @($test)
    }

    It 'preserves every Local Smoke case while splitting transport selection and cache fixtures into ordinary workers' {
        . (Join-Path $RepoRoot 'scripts/quality-contracts.ps1')
        $catalog=Get-QualityContractCatalog -RepositoryRoot $RepoRoot
        $names=@('LocalGateTransport','LocalTargetedSelection','LocalShardCache')
        $tokens=$null;$errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'scripts/invoke-pester-shards.ps1'),[ref]$tokens,[ref]$errors)
        @($errors) | Should -BeNullOrEmpty
        $assignment=$ast.Find({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$serialTestNames'},$true)
        $serialTestNames=@(& ([scriptblock]::Create($assignment.Right.Extent.Text)))
        foreach($name in $names) {
            $test='tests/pester/'+$name+'.Tests.ps1'
            $serialTestNames | Should -Not -Contain ($name+'.Tests.ps1')
            @($catalog.smokeTests) | Should -Contain $test
            @(Resolve-QualityContractsForPaths -Catalog $catalog -Paths @($test) | Select-Object -ExpandProperty tests) | Should -Be @($test)
            foreach($path in @('scripts/check.ps1','scripts/pester-timings.json','scripts/invoke-pester-shards.ps1')) {
                @(Resolve-QualityContractsForPaths -Catalog $catalog -Paths @($path) | Select-Object -ExpandProperty tests) | Should -Contain $test
            }
        }
    }

    It 'selects Develop continuation qualification for actual fixture inputs without scheduler-only dependencies' {
        . (Join-Path $RepoRoot 'scripts/quality-contracts.ps1')
        $catalog=Get-QualityContractCatalog -RepositoryRoot $RepoRoot
        $test='tests/pester/DevelopE2EQualification.Tests.ps1'
        foreach($path in @('scripts/pester-timings.json','scripts/resolve-targeted-tests.ps1','scripts/invoke-pester-shards.ps1','scripts/run-pester-shard.ps1','scripts/develop-static-qualification.ps1','scripts/source-delivery-plan.ps1')) {
            $selected=Resolve-QualityContractsForPaths -Catalog $catalog -Paths @($path)
            @($selected.unknownPaths) | Should -BeNullOrEmpty
            @($selected.tests) | Should -Not -Contain $test -Because "$path is not read or executed by the Develop qualification fixture"
        }
        foreach($path in @('scripts/check.ps1','scripts/quality-contracts.ps1','scripts/develop-e2e-qualification.ps1','scripts/release-qualification.ps1','scripts/invoke-pester-runtime.ps1','scripts/git-path-list.ps1','scripts/stand-env-identity.ps1','scripts/invoke-release-e2e.ps1','scripts/invoke-develop-e2e.ps1','templates/project.json','.agents/skills/1c-workflow/scripts/agent-1c.ps1','.agents/skills/1c-workflow/scripts/lib/agent-1c.lifecycle.ps1')) {
            @(Resolve-QualityContractsForPaths -Catalog $catalog -Paths @($path) | Select-Object -ExpandProperty tests) | Should -Contain $test -Because "$path is a retained execution or source-extraction boundary"
        }
        @(Resolve-QualityContractsForPaths -Catalog $catalog -Paths @($test) | Select-Object -ExpandProperty tests) | Should -Be @($test)
    }

    It 'keeps real console interruption serial while extracted compact fixtures use ordinary isolated workers' {
        . (Join-Path $RepoRoot 'scripts/quality-contracts.ps1')
        $catalog=Get-QualityContractCatalog -RepositoryRoot $RepoRoot
        $names=@('CompactRunnerFreshContinuation','CompactRunnerLongContinuation','CompactRunnerReports','CompactRunnerRouting','CompactRunnerWatchdog')
        $tokens=$null;$errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'scripts/invoke-pester-shards.ps1'),[ref]$tokens,[ref]$errors)
        @($errors) | Should -BeNullOrEmpty
        $assignment=$ast.Find({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$serialTestNames'},$true)
        $assignment | Should -Not -BeNullOrEmpty
        $serialTestNames=@(& ([scriptblock]::Create($assignment.Right.Extent.Text)))
        $serialTestNames | Should -Contain 'CompactItlRunner.Tests.ps1'
        foreach($name in $names) {
            $file=$name+'.Tests.ps1';$test='tests/pester/'+$file
            $serialTestNames | Should -Not -Contain $file
            @(Resolve-QualityContractsForPaths -Catalog $catalog -Paths @($test) | Select-Object -ExpandProperty tests) | Should -Be @($test)
            @($catalog.smokeTests) | Should -Not -Contain $test -Because 'the original Compact suite was outside Smoke'
            @(Resolve-QualityContractsForPaths -Catalog $catalog -Paths @('.agents/skills/1c-workflow/scripts/run-itl-command.ps1') | Select-Object -ExpandProperty tests) | Should -Contain $test
        }
    }

    It 'selects readiness only for its executable and admission dependencies' {
        . (Join-Path $RepoRoot 'scripts/quality-contracts.ps1')
        $catalog=Get-QualityContractCatalog -RepositoryRoot $RepoRoot
        $test='tests/pester/ReleaseReadiness.Tests.ps1'
        foreach($path in @('scripts/check.ps1','scripts/pester-timings.json','scripts/resolve-targeted-tests.ps1','scripts/invoke-pester-shards.ps1','scripts/run-pester-shard.ps1','scripts/invoke-develop-e2e.ps1','scripts/develop-static-qualification.ps1','scripts/develop-e2e-qualification.ps1')) {
            $selected=Resolve-QualityContractsForPaths -Catalog $catalog -Paths @($path)
            @($selected.unknownPaths) | Should -BeNullOrEmpty
            @($selected.tests) | Should -Not -Contain $test -Because "$path is neither executed nor read by the readiness fixture"
        }
        foreach($path in @('scripts/test-release-readiness.ps1','scripts/test-powershell-encoding.ps1','scripts/release-qualification.ps1','scripts/invoke-pester-runtime.ps1','scripts/stand-env-identity.ps1','scripts/git-path-list.ps1','scripts/invoke-release-e2e.ps1','scripts/release-e2e/admission.ps1','scripts/release-e2e/workflow-transition.ps1','.agents/skills/1c-workflow/scripts/agent-1c.ps1','.agents/skills/1c-workflow/scripts/lib/agent-1c.package-content.ps1','.agents/skills/1c-workflow/scripts/lib/agent-1c.immutable-download.ps1','.agents/skills/1c-workflow/scripts/lib/agent-1c.lifecycle.ps1')) {
            @(Resolve-QualityContractsForPaths -Catalog $catalog -Paths @($path) | Select-Object -ExpandProperty tests) | Should -Contain $test -Because "$path is a real readiness boundary"
        }
        @(Resolve-QualityContractsForPaths -Catalog $catalog -Paths @($test) | Select-Object -ExpandProperty tests) | Should -Be @($test)
    }

    It 'routes extracted cache, progress, cleanup and fork behavior independently with every direct suite retained' {
        . (Join-Path $RepoRoot 'scripts/quality-contracts.ps1')
        $catalog=Get-QualityContractCatalog -RepositoryRoot $RepoRoot
        $names=@('E2EArtifactCleanup','ForkQualificationInventory','PesterCacheCompatibility','PesterShardIdentity','ReleaseProgressObservation')
        $groups=@($names|ForEach-Object {'tests/pester/'+$_+'.Tests.ps1'})
        foreach($test in $groups) {
            $selection=Resolve-QualityContractsForPaths -Catalog $catalog -Paths @($test)
            @($selection.unknownPaths) | Should -BeNullOrEmpty
            @($selection.tests) | Should -Be @($test)
            @($catalog.smokeTests) | Should -Contain $test -Because 'the original Smoke file included every transferred case'
        }
        $routes=@(
            @{path='scripts/check.ps1';expected=@('ForkQualificationInventory','ReleaseProgressObservation')}
            @{path='scripts/invoke-pester-shards.ps1';expected=@('PesterCacheCompatibility','PesterShardIdentity')}
            @{path='scripts/client-mcp-build.ps1';expected=@('PesterShardIdentity')}
            @{path='scripts/develop-e2e-cleanup.ps1';expected=@('E2EArtifactCleanup')}
            @{path='scripts/git-path-list.ps1';expected=@('E2EArtifactCleanup','PesterCacheCompatibility','PesterShardIdentity')}
            @{path='scripts/stand-env-identity.ps1';expected=@('ReleaseProgressObservation')}
            @{path='scripts/build-client-mcp-patched.ps1';expected=@()}
            @{path='.agents/skills/1c-workflow/scripts/lib/agent-1c.roctup-mcp.ps1';expected=@()}
            @{path='scripts/pester-timings.json';expected=@()}
            @{path='tests/quality-contracts.json';expected=@()}
        )
        foreach($route in $routes) {
            $selection=Resolve-QualityContractsForPaths -Catalog $catalog -Paths @($route.path)
            @($selection.unknownPaths) | Should -BeNullOrEmpty
            @($selection.tests|Where-Object {$_ -in $groups}) | Should -Be @($route.expected|ForEach-Object {'tests/pester/'+$_+'.Tests.ps1'}) -Because $route.path
        }
    }

    It 'selects extracted Release groups only for their behavior and preserves every direct suite route' {
        . (Join-Path $RepoRoot 'scripts/quality-contracts.ps1')
        $catalog=Get-QualityContractCatalog -RepositoryRoot $RepoRoot
        $groups=@('DevelopManifestContinuation','E2EClientSelection','ReleaseAdmission','ReleaseOrchestration','ReleaseSnapshotContinuation' | ForEach-Object { 'tests/pester/'+$_+'.Tests.ps1' })
        foreach($path in @('scripts/check.ps1','scripts/resolve-targeted-tests.ps1','scripts/pester-timings.json','tests/quality-contracts.json')) {
            $selection=Resolve-QualityContractsForPaths -Catalog $catalog -Paths @($path)
            @($selection.unknownPaths) | Should -BeNullOrEmpty
            @($selection.tests | Where-Object { $_ -in $groups }) | Should -BeNullOrEmpty -Because "$path does not execute the extracted Release behavior"
        }
        foreach($test in $groups) {
            $selection=Resolve-QualityContractsForPaths -Catalog $catalog -Paths @($test)
            @($selection.unknownPaths) | Should -BeNullOrEmpty
            @($selection.tests) | Should -Be @($test)
        }
        $release=Resolve-QualityContractsForPaths -Catalog $catalog -Paths @('scripts/invoke-release-e2e.ps1')
        @($release.tests | Where-Object { $_ -in $groups }) | Should -Be @($groups | Where-Object { $_ -notlike '*DevelopManifestContinuation*' })
        $develop=Resolve-QualityContractsForPaths -Catalog $catalog -Paths @('scripts/invoke-develop-e2e.ps1')
        @($develop.tests | Where-Object { $_ -in $groups }) | Should -Be @('tests/pester/DevelopManifestContinuation.Tests.ps1','tests/pester/E2EClientSelection.Tests.ps1')
        $lifecycle=@('DevBranchLifecycle','DevBranchWorktrees','DevBranchForkContinuation','DevBranchMergeRecovery'|ForEach-Object {'tests/pester/'+$_+'.Tests.ps1'})
        @($develop.tests|Where-Object {$_ -in $lifecycle})|Should -BeNullOrEmpty -Because 'Develop orchestration does not own the installed lifecycle test workload'
        foreach($test in $lifecycle){
            @($release.tests)|Should -Contain $test
            @(Resolve-QualityContractsForPaths -Catalog $catalog -Paths @('.agents/skills/1c-workflow/scripts/lib/agent-1c.lifecycle.ps1')|Select-Object -ExpandProperty tests)|Should -Contain $test
        }
        foreach($test in @('DevelopConfigurationRejection','ReleaseGate','LocalQualityGate')){
            @($develop.tests)|Should -Contain ('tests/pester/'+$test+'.Tests.ps1')
        }
        foreach($helper in @('scripts/source-delivery-process.ps1','scripts/source-proof-json.ps1','scripts/git-path-list.ps1','scripts/quality-contracts.ps1')) {
            @(Resolve-QualityContractsForPaths -Catalog $catalog -Paths @($helper) | Select-Object -ExpandProperty tests) | Should -Contain 'tests/pester/ReleaseOrchestration.Tests.ps1'
        }
    }

    It 'selects static catalog proof without launching publication process suites' {
        . (Join-Path $RepoRoot 'scripts/quality-contracts.ps1')
        $catalog=Get-QualityContractCatalog -RepositoryRoot $RepoRoot
        $selected=Resolve-QualityContractsForPaths -Catalog $catalog -Paths @('tests/quality-contracts.json')
        @($selected.unknownPaths) | Should -BeNullOrEmpty
        @($selected.tests) | Should -Be @('tests/pester/DeliveryCandidatePlanBridge.Tests.ps1','tests/pester/DeliveryCatalogInputScope.Tests.ps1','tests/pester/DeliveryGoInputScope.Tests.ps1','tests/pester/DeliveryScenarioAuthentication.Tests.ps1','tests/pester/DeliveryScenarioComposition.Tests.ps1','tests/pester/DeliveryScenarioSelection.Tests.ps1','tests/pester/DeliverySetupInputScope.Tests.ps1','tests/pester/DevelopForkConsumerInventory.Tests.ps1','tests/pester/HostTestSelection.Tests.ps1','tests/pester/SourceDeliveryIncremental.Tests.ps1','tests/pester/SourceQualityCatalog.Tests.ps1')
    }

    It 'invalidates every existing qualification consumer when the catalog bytes change' {
        . (Join-Path $RepoRoot 'scripts/quality-contracts.ps1')
        $actualCatalog=Get-QualityContractCatalog -RepositoryRoot $RepoRoot
        $tokens=$null;$errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'scripts/invoke-pester-shards.ps1'),[ref]$tokens,[ref]$errors)
        @($errors) | Should -BeNullOrEmpty
        & {
            foreach($name in @('Get-ShardRelativeTestPath','Get-ShardExternalProfiles','Get-ShardInputDigest','Get-TextSha256')) {
                $definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true)
                $definition | Should -Not -BeNullOrEmpty
                . ([scriptblock]::Create($definition.Extent.Text))
            }
            function Get-ShardTrackedFileIdentity {
                param($RelativePath,$AbsolutePath)
                (Get-FileHash -LiteralPath $AbsolutePath -Algorithm SHA256).Hash
            }
            $RepositoryRoot=Join-Path $TestDrive 'Каталог proof с пробелом'
            New-Item -ItemType Directory -Path (Join-Path $RepositoryRoot 'tests/pester') -Force | Out-Null
            $catalogPath=Join-Path $RepositoryRoot 'tests/quality-contracts.json'
            Copy-Item -LiteralPath (Join-Path $RepoRoot 'tests/quality-contracts.json') -Destination $catalogPath
            # External runtime keys have their own regression; isolate the
            # catalog-byte consumption of these consumers from host runtimes.
            $catalog=$actualCatalog.PSObject.Copy()
            $catalog.PSObject.Properties.Remove('pesterExternalRuntimeTests')
            $script:pesterRuntimeReceipt=[pscustomobject]@{status='known';identity=[pscustomobject]@{powerShellVersion=[string]$PSVersionTable.PSVersion;pesterVersion='fixture';identitySha256=('a'*64)}}
            $sharedInputs=@()
            $pesterExternalInputsByTest=@{}
            $consumers=@('LocalQualityGate','LocalGateTransport','LocalTargetedSelection','LocalShardCache','DevelopStaticQualificationCache','DevelopE2EQualification','ReleaseReadiness','ReleaseGate','AiRulesCompatibilityPromotion','HostTestSelection',
                'ReleaseOrchestration','DevelopManifestContinuation','E2EClientSelection','ReleaseSnapshotContinuation','ReleaseAdmission',
                'PesterShardIdentity','PesterCacheCompatibility','ReleaseProgressObservation','E2EArtifactCleanup','ForkQualificationInventory',
                'CompactRunnerFreshContinuation','CompactRunnerLongContinuation','CompactRunnerReports','CompactRunnerRouting','CompactRunnerWatchdog','SourceDeliveryPlan','SourceDeliveryIncremental','SourceDeliveryFrozenPlan','SourceDeliveryHistoricalTransition')
            $catalogIndependent=@('DevelopStaticQualificationCache','PesterCacheCompatibility','ReleaseProgressObservation','E2EArtifactCleanup','ForkQualificationInventory',
                'CompactRunnerFreshContinuation','CompactRunnerLongContinuation','CompactRunnerReports','CompactRunnerRouting','CompactRunnerWatchdog','SourceDeliveryPlan','SourceDeliveryFrozenPlan','SourceDeliveryHistoricalTransition')
            $trackedPaths=@('tests/quality-contracts.json')+@($consumers | ForEach-Object { 'tests/pester/'+$_+'.Tests.ps1' })
            . (Join-Path $RepoRoot 'scripts/git-path-list.ps1')
            $actualPaths=@(Get-RepositoryGitPathList -RepositoryRoot $RepoRoot -Arguments @('ls-files','-z','--cached'))
            $consumerTests=@($consumers | ForEach-Object { 'tests/pester/'+$_+'.Tests.ps1' })
            $patterns=@($catalog.contracts | Where-Object { @($_.tests | Where-Object { $_ -in $consumerTests }).Count -gt 0 } | ForEach-Object { $_.paths; Get-QualityContractReuseInputPaths -Contract $_ } | Sort-Object -Unique)
            $dependencies=@($actualPaths | Where-Object { $path=$_; @($patterns | Where-Object { $path -like $_ }).Count -gt 0 })
            foreach($relative in $dependencies) {
                if($relative -eq 'tests/quality-contracts.json'){continue}
                $absolute=Join-Path $RepositoryRoot $relative
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $absolute) | Out-Null
                [IO.File]::WriteAllText($absolute,'unchanged dependency fixture',[Text.UTF8Encoding]::new($false))
            }
            $trackedPaths=@($trackedPaths+$dependencies | Sort-Object -Unique)
            $before=@{}
            foreach($name in $consumers) {
                $path=Join-Path $RepositoryRoot ('tests/pester/'+$name+'.Tests.ps1')
                [IO.File]::WriteAllText($path,'# unchanged test source',[Text.UTF8Encoding]::new($true))
                $digest=Get-ShardInputDigest -Paths @($path)
                $digest | Should -Not -BeNullOrEmpty
                Get-ShardInputDigest -Paths @($path) | Should -BeExactly $digest
                $before[$name]=$digest
            }
            [IO.File]::AppendAllText($catalogPath,"`n",[Text.UTF8Encoding]::new($false))
            foreach($name in $consumers) {
                $path=Join-Path $RepositoryRoot ('tests/pester/'+$name+'.Tests.ps1')
                $changed=Get-ShardInputDigest -Paths @($path)
                if($name -in $catalogIndependent) {
                    $changed | Should -BeExactly $before[$name] -Because "$name does not read the real catalog as fixture input"
                } else {
                    $changed | Should -Not -Be $before[$name] -Because "$name still consumes the catalog during full qualification"
                }
            }
            # Discovery is loaded by the real planner, not by the custom-gate
            # frozen/historical process fixtures. Exercise actual per-file keys.
            $beforeDiscovery=@{}
            foreach($name in $consumers) {
                $beforeDiscovery[$name]=Get-ShardInputDigest -Paths @((Join-Path $RepositoryRoot ('tests/pester/'+$name+'.Tests.ps1')))
            }
            [IO.File]::AppendAllText((Join-Path $RepositoryRoot 'scripts/source-e2e-artifact-discovery.ps1'),"`n# changed artifact lookup",[Text.UTF8Encoding]::new($false))
            foreach($name in $consumers) {
                $after=Get-ShardInputDigest -Paths @((Join-Path $RepositoryRoot ('tests/pester/'+$name+'.Tests.ps1')))
                if($name -in @('SourceDeliveryPlan','SourceDeliveryIncremental')) {
                    $after | Should -Not -Be $beforeDiscovery[$name]
                } else {
                    $after | Should -BeExactly $beforeDiscovery[$name] -Because "$name does not execute artifact discovery"
                }
            }
            # Definitions loaded by the workflow-transition module remain Full
            # inputs even when their standalone component does not select Release.
            $afterCatalog=@{}
            foreach($name in $consumers) {
                $path=Join-Path $RepositoryRoot ('tests/pester/'+$name+'.Tests.ps1')
                $afterCatalog[$name]=Get-ShardInputDigest -Paths @($path)
            }
            $loadedHelper=Join-Path $RepositoryRoot '.agents/skills/1c-workflow/scripts/lib/agent-1c.roctup-mcp.ps1'
            Test-Path -LiteralPath $loadedHelper | Should -BeTrue
            [IO.File]::AppendAllText($loadedHelper,"`n# changed loaded definition",[Text.UTF8Encoding]::new($false))
            foreach($name in $consumers) {
                $path=Join-Path $RepositoryRoot ('tests/pester/'+$name+'.Tests.ps1')
                $changed=Get-ShardInputDigest -Paths @($path)
                if($name -in @('PesterShardIdentity','ReleaseOrchestration','ReleaseAdmission','ReleaseReadiness','DevelopE2EQualification','CompactRunnerFreshContinuation','CompactRunnerLongContinuation','CompactRunnerRouting')) {
                    $changed | Should -Not -Be $afterCatalog[$name] -Because "$name declares this helper as a reuse dependency"
                } else {
                    $changed | Should -BeExactly $afterCatalog[$name] -Because "$name does not consume this helper"
                }
            }
            $readinessPath=Join-Path $RepositoryRoot 'tests/pester/ReleaseReadiness.Tests.ps1'
            $readinessDigest=Get-ShardInputDigest -Paths @($readinessPath)
            $plannerPath=Join-Path $RepositoryRoot 'tests/pester/SourceDeliveryPlan.Tests.ps1'
            $plannerDigest=Get-ShardInputDigest -Paths @($plannerPath)
            foreach($relative in @('scripts/check.ps1','scripts/pester-timings.json','scripts/invoke-pester-shards.ps1')) {
                [IO.File]::AppendAllText((Join-Path $RepositoryRoot $relative),"`nchanged unrelated checker input",[Text.UTF8Encoding]::new($false))
                Get-ShardInputDigest -Paths @($readinessPath) | Should -BeExactly $readinessDigest -Because "$relative is outside readiness execution and input closure"
                $plannerChanged=Get-ShardInputDigest -Paths @($plannerPath)
                if($relative -eq 'scripts/check.ps1') {
                    $plannerChanged | Should -Not -Be $plannerDigest -Because 'planner acceptance extracts the actual checker route'
                } else {
                    $plannerChanged | Should -BeExactly $plannerDigest -Because 'planner acceptance does not consume scheduler inputs'
                }
                $plannerDigest=$plannerChanged
            }
            @(Resolve-QualityContractsForPaths -Catalog $catalog -Paths @('scripts/check.ps1') | Select-Object -ExpandProperty tests) | Should -Contain 'tests/pester/SourceDeliveryPlan.Tests.ps1'
            $incrementalPath=Join-Path $RepositoryRoot 'tests/pester/SourceDeliveryIncremental.Tests.ps1'
            $incrementalDigest=Get-ShardInputDigest -Paths @($incrementalPath)
            $plannerDigest=Get-ShardInputDigest -Paths @($plannerPath)
            [IO.File]::AppendAllText((Join-Path $RepositoryRoot '.agents/skills/1c-workflow/scripts/lib/agent-1c.lifecycle.ps1'),"`n# changed actual journey source",[Text.UTF8Encoding]::new($false))
            Get-ShardInputDigest -Paths @($incrementalPath) | Should -Not -Be $incrementalDigest -Because 'the incremental suite consumes the actual lifecycle source'
            Get-ShardInputDigest -Paths @($plannerPath) | Should -BeExactly $plannerDigest -Because 'the remaining planner suite does not consume lifecycle source'
            [IO.File]::AppendAllText((Join-Path $RepositoryRoot 'scripts/test-release-readiness.ps1'),"`n# changed readiness owner",[Text.UTF8Encoding]::new($false))
            Get-ShardInputDigest -Paths @($readinessPath) | Should -Not -Be $readinessDigest
            $developPath=Join-Path $RepositoryRoot 'tests/pester/DevelopE2EQualification.Tests.ps1'
            $developDigest=Get-ShardInputDigest -Paths @($developPath)
            foreach($relative in @('scripts/pester-timings.json','scripts/invoke-pester-shards.ps1','scripts/run-pester-shard.ps1','scripts/develop-static-qualification.ps1')) {
                [IO.File]::AppendAllText((Join-Path $RepositoryRoot $relative),"`n# unrelated Develop fixture input",[Text.UTF8Encoding]::new($false))
                Get-ShardInputDigest -Paths @($developPath) | Should -BeExactly $developDigest -Because "$relative is not consumed by the Develop continuation fixture"
            }
            [IO.File]::AppendAllText((Join-Path $RepositoryRoot 'scripts/check.ps1'),"`n# changed actual check AST",[Text.UTF8Encoding]::new($false))
            Get-ShardInputDigest -Paths @($developPath) | Should -Not -Be $developDigest
            $compactNames=@('CompactRunnerFreshContinuation','CompactRunnerLongContinuation','CompactRunnerReports','CompactRunnerRouting','CompactRunnerWatchdog')
            $compactBefore=@{}
            foreach($name in $compactNames){$compactBefore[$name]=Get-ShardInputDigest -Paths @((Join-Path $RepositoryRoot ('tests/pester/'+$name+'.Tests.ps1')))}
            [IO.File]::AppendAllText((Join-Path $RepositoryRoot 'tests/pester/CompactRunnerReports.Tests.ps1'),"`n# changed report scenario",[Text.UTF8Encoding]::new($false))
            foreach($name in $compactNames) {
                $digest=Get-ShardInputDigest -Paths @((Join-Path $RepositoryRoot ('tests/pester/'+$name+'.Tests.ps1')))
                if($name -eq 'CompactRunnerReports'){$digest | Should -Not -Be $compactBefore[$name]}
                else {$digest | Should -BeExactly $compactBefore[$name] -Because 'a neighboring test edit does not change this fixture'}
            }
        }
    }
}

Describe 'Source catalog Develop journey selection' {
    BeforeAll {
        . (Join-Path $RepoRoot 'scripts/develop-e2e-qualification.ps1')
    }
    It 'keeps the <Component> test owner outside installed 1C journeys' -ForEach @(
        @{Component='Mantis';Path='vibecoding1c-mcp-host/mantis-ticket-mcp/mantis_index.py';Owner='host-mantis-tests'}
        @{Component='BookStack';Path='vibecoding1c-mcp-host/bookstack-product-docs-mcp/server.py';Owner='host-bookstack-tests'}
        @{Component='CodeChecker';Path='vibecoding1c-mcp-host/codechecker-overlay/retry_policy.py';Owner='host-codechecker-tests'}
        @{Component='CodeChecker beta';Path='vibecoding1c-mcp-host/codechecker-beta-overlay/patch_mcp_server.py';Owner='host-codechecker-tests'}
        @{Component='SPPR';Path='vibecoding1c-mcp-host/sppr-mcp/sppr_service.py';Owner='host-sppr-tests'}
        @{Component='Node proxy';Path='vibecoding1c-mcp-host/tools-list-proxy/tools-list-proxy.js';Owner='host-tools-proxy-tests'}
        @{Component='Linux host';Path='vibecoding1c-mcp-host/linux-native-host/watchdog.py';Owner='host-linux-tests'}
        @{Component='Native transport';Path='vibecoding1c-mcp-host/index-snapshot.py';Owner='host-native-transport'}
    ) {
        $plan=Resolve-DevelopE2EJourneyPlan -RepositoryRoot $RepoRoot -ChangedPath @($Path)
        $plan.reason | Should -Be 'no-develop-journey-route'
        @($plan.contracts) | Should -Be @($Owner,'standalone-mcp-host')
        @($plan.journeys) | Should -BeNullOrEmpty
        @($plan.unknownPaths) | Should -BeNullOrEmpty
        @($plan.matchedFullPaths) | Should -BeNullOrEmpty
    }

    It "validates exact journey names, exact full paths, and known route contracts" {
        $catalog = Get-QualityContractCatalog -RepositoryRoot $RepoRoot
        Test-QualityContractCatalog -RepositoryRoot $RepoRoot -Catalog $catalog | Should -BeTrue
        @($catalog.developJourneys.names) | Should -Be @('upgrade','fresh')
        @($catalog.developJourneys.fullPaths) | Should -Not -Contain 'scripts/check.ps1'
        @($catalog.developJourneys.fullPaths) | Should -Contain 'scripts/git-path-list.ps1'
        @($catalog.developJourneys.fullPaths) | Should -Not -Contain 'scripts/develop-e2e-qualification.ps1'
        @($catalog.developJourneys.fullPaths) | Should -Not -Contain 'tests/quality-contracts.json'
        foreach ($leaf in @('scripts/source-delivery.ps1','scripts/source-delivery-process.ps1','scripts/source-delivery-queue.ps1','scripts/source-delivery-component.ps1','scripts/source-delivery-candidate.ps1')) {
            @($catalog.developJourneys.fullPaths) | Should -Not -Contain $leaf
        }

        $invalid = $catalog | ConvertTo-Json -Depth 16 | ConvertFrom-Json
        $invalid.developJourneys.routes.upgrade.contracts = @('missing-owner')
        { Test-QualityContractCatalog -RepositoryRoot $RepoRoot -Catalog $invalid } | Should -Throw '*unknown quality contracts*'
        $invalid = $catalog | ConvertTo-Json -Depth 16 | ConvertFrom-Json
        $invalid.developJourneys.fullPaths = @('scripts/*.ps1')
        { Test-QualityContractCatalog -RepositoryRoot $RepoRoot -Catalog $invalid } | Should -Throw '*unique exact repository-relative paths*'
    }

    It "routes each installed owner to the journey that exercises its behavior" {
        $installed = Resolve-DevelopE2EJourneyPlan -RepositoryRoot $RepoRoot -ChangedPath @('.agents/skills/1c-workflow/scripts/lib/agent-1c.ondemand-mcp.ps1')
        $installed.reason | Should -Be 'quality-contract-route'
        @($installed.contracts) | Should -Be @('develop-broker-input-scope','mcp-hosts')
        @($installed.journeys) | Should -Be @('fresh')
        @(Resolve-DevelopE2EJourneyPlan -RepositoryRoot $RepoRoot -ChangedPath @('templates/dependency-lock.json') | Select-Object -ExpandProperty journeys) | Should -Be @('fresh')
        @(Resolve-DevelopE2EJourneyPlan -RepositoryRoot $RepoRoot -ChangedPath @('scripts/build-ai-rules-release.ps1') | Select-Object -ExpandProperty journeys) | Should -Be @('upgrade')
        @(Resolve-DevelopE2EJourneyPlan -RepositoryRoot $RepoRoot -ChangedPath @('.agents/skills/1c-workflow/scripts/lib/agent-1c.verification-modes.ps1') | Select-Object -ExpandProperty journeys) | Should -Be @('upgrade','fresh')

        $standalone = Resolve-DevelopE2EJourneyPlan -RepositoryRoot $RepoRoot -ChangedPath @('vibecoding1c-mcp-host/codechecker-overlay/retry_policy.py')
        $standalone.reason | Should -Be 'no-develop-journey-route'
        @($standalone.contracts) | Should -Be @('host-codechecker-tests','standalone-mcp-host')
        @($standalone.journeys) | Should -BeNullOrEmpty

        foreach ($leaf in @('process','queue','component')) {
            $path = "scripts/source-delivery-$leaf.ps1"
            $plan = Resolve-DevelopE2EJourneyPlan -RepositoryRoot $RepoRoot -ChangedPath @($path)
            $plan.reason | Should -Be 'no-develop-journey-route'
            $expectedContracts=@("source-delivery-$leaf")
            if($leaf -eq 'process') { $expectedContracts = @('e2e-client-selection-tests','qualification-fixture-process-tests','release-orchestration-tests','source-candidate-registration') + $expectedContracts + @('source-e2e-disk-monitor','source-quality-catalog') }
            if($leaf -eq 'queue') { $expectedContracts = @('source-candidate-registration') + $expectedContracts }
            @($plan.contracts) | Should -Be $expectedContracts
            @($plan.journeys) | Should -BeNullOrEmpty
        }
        foreach ($path in @('scripts/source-e2e-fixture.ps1','scripts/lifecycle-qualification-fixture.ps1','scripts/source-e2e-storage.ps1')) {
            $fixture = Resolve-DevelopE2EJourneyPlan -RepositoryRoot $RepoRoot -ChangedPath @($path)
            @($fixture.journeys) | Should -Be @('upgrade','fresh')
        }
        $entrypoint = Resolve-DevelopE2EJourneyPlan -RepositoryRoot $RepoRoot -ChangedPath @('scripts/source-delivery.ps1')
        @($entrypoint.contracts) | Should -Be @('source-candidate-registration','source-delivery-entrypoint','source-delivery-incremental-inputs'); @($entrypoint.journeys) | Should -BeNullOrEmpty
        $candidate = Resolve-DevelopE2EJourneyPlan -RepositoryRoot $RepoRoot -ChangedPath @('scripts/source-delivery-candidate.ps1')
        @($candidate.contracts) | Should -Be @('pester-full-input-proof','source-candidate-registration','source-delivery-candidate','source-delivery-stand-preparation'); @($candidate.journeys) | Should -BeNullOrEmpty
        $cleanup = Resolve-DevelopE2EJourneyPlan -RepositoryRoot $RepoRoot -ChangedPath @('scripts/develop-e2e-cleanup.ps1')
        @($cleanup.contracts) | Should -Be @('e2e-artifact-cleanup-tests','source-delivery-cleanup'); @($cleanup.journeys) | Should -BeNullOrEmpty
    }
}
