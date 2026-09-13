BeforeAll {
    . (Join-Path $PSScriptRoot "TestSupport.ps1")
    $context = Initialize-WorkflowPesterContext
    $RepoRoot = $context.RepoRoot
}
Describe "Local quality gate contract" {
    It "lets Windows PowerShell gate children rebuild their native module path when launched from PowerShell Core" {
        $path = Join-Path $RepoRoot "scripts\check.ps1"
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
        @($errors) | Should -BeNullOrEmpty
        $definition = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Start-PowerShellChildProcess"
        }, $true)
        $definition | Should -Not -BeNullOrEmpty
        $text = $definition.Extent.Text

        $filterOffset = $text.IndexOf('$coreModuleRoot = [IO.Path]::GetFullPath((Join-Path $PSHOME "Modules"))', [StringComparison]::Ordinal)
        $launchOffset = $text.IndexOf('Start-Process -FilePath "powershell.exe"', [StringComparison]::Ordinal)
        $restoreOffset = $text.LastIndexOf('$env:PSModulePath = $originalPowerShellModulePath', [StringComparison]::Ordinal)
        $text | Should -Match '\$resetModulePathForWindowsPowerShell = \[string\]\$PSVersionTable\.PSEdition -eq "Core"'
        $filterOffset | Should -BeGreaterThan -1
        $filterOffset | Should -BeLessThan $launchOffset
        $restoreOffset | Should -BeGreaterThan $launchOffset
        $text | Should -Match '\$env:PSModulePath = \$compatibleModuleRoots -join'
        $text | Should -Match 'try\s*\{[\s\S]+Start-Process[\s\S]+\}\s*finally\s*\{'
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
        $text | Should -Match '\$journeyHardSeconds = if \(\$Journey -eq "upgrade"\) \{ 1200 \} else \{ 2100 \}'
        $text | Should -Match 'TimeoutSeconds \$journeyHardSeconds'; $text | Should -Match 'TimeoutSeconds 7200'; $text | Should -Not -Match 'TimeoutSeconds 14400'
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
        $sourceRules = Resolve-QualityContractsForPaths -Catalog $catalog -Paths @("AGENTS.md")
        @($sourceRules.tests) | Should -Contain "tests/pester/ParserDocsBudgets.Tests.ps1"
        @($sourceRules.tests) | Should -Not -Contain "tests/pester/SourceDeliveryPublish.Tests.ps1"
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
        @($onDemandOnly.contracts.id) | Should -Be @("mcp-hosts")
        @($onDemandOnly.tests) | Should -Contain "tests/pester/OnDemandMcp.Tests.ps1"
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
        @($processOnly.contracts.id) | Should -Be @("source-delivery-process")
        @($processOnly.tests) | Should -Contain "tests/pester/SourceDeliveryProcessLifetime.Tests.ps1"
        @($processOnly.tests) | Should -Contain "tests/pester/SourceDeliveryQueue.Tests.ps1"
        @($processOnly.tests) | Should -Contain "tests/pester/SourceDeliveryComponentPublication.Tests.ps1"
        $queueOnly = Resolve-QualityContractsForPaths -Catalog $catalog -Paths @("scripts/source-delivery-queue.ps1")
        @($queueOnly.contracts.id) | Should -Be @("source-delivery-queue")
        @($queueOnly.tests) | Should -Be @("tests/pester/SourceDeliveryQueue.Tests.ps1")
        $componentOnly = Resolve-QualityContractsForPaths -Catalog $catalog -Paths @("scripts/source-delivery-component.ps1")
        @($componentOnly.contracts.id) | Should -Be @("source-delivery-component")
        @($componentOnly.tests) | Should -Be @("tests/pester/ImmutableDownloadRetry.Tests.ps1", "tests/pester/SourceDeliveryComponentPublication.Tests.ps1", "tests/pester/SourceDeliveryProcessLifetime.Tests.ps1")
        $postGatePaths = @(
            "scripts/source-delivery.ps1",
            "scripts/source-delivery-supervisor.ps1",
            "scripts/source-delivery-plan.ps1",
            "scripts/source-delivery-resources.ps1",
            "scripts/source-delivery-ref-cleanup.ps1",
            "scripts/source-delivery-process.ps1",
            "scripts/source-delivery-queue.ps1",
            "scripts/source-delivery-candidate.ps1",
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
        $shardRunner | Should -Match '\$serialTestNames = @\("CompactItlRunner\.Tests\.ps1", "DependencyLocks\.Tests\.ps1", "ReleaseGate\.Tests\.ps1"\)'
        $check = Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\check.ps1") -Raw -Encoding UTF8
        $check | Should -Match 'SelectionPath", \$selectionPath\) -TimeoutSeconds \$modeHardBudgetSeconds' -Because "the selected shard runner must use the Targeted contract budget instead of a second hard-coded limit"
        $check | Should -Match '-TimeoutSeconds \$pesterHardBudgetSeconds -ProgressPaths \(Join-Path \$outputRoot "pester-shards"\) -LogName "pester-shards"' -Because "the complete Pester inventory must use the catalog Full hard budget and treat shard artifacts as live progress"
        [int]$catalog.budgets.targetedHardSeconds | Should -BeGreaterOrEqual 1200
        [int]$catalog.budgets.fullHardSeconds | Should -BeGreaterOrEqual 1800
        [int]($catalog.contracts | Where-Object id -eq "source-delivery-candidate").budgetSeconds | Should -BeGreaterOrEqual 1200
    }
    It "routes only exact named entrypoint AST changes and falls back for shared or unknown impact" {
        . (Join-Path $RepoRoot "scripts\quality-contracts.ps1")
        $catalog = Get-QualityContractCatalog -RepositoryRoot $RepoRoot
        $entrypoint = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\agent-1c.ps1") -Raw -Encoding UTF8

        $oneAction = $entrypoint.Replace('"update-auxiliary-contour" { Update-AuxiliaryContour }', '"update-auxiliary-contour" { Update-AuxiliaryContour | Out-Null }')
        $oneActionImpact = Resolve-Agent1cSemanticImpact -Catalog $catalog -CurrentText $oneAction -BaselineText $entrypoint
        $oneActionImpact.fallback | Should -BeFalse
        @($oneActionImpact.tests) | Should -Be @("tests/pester/Agent1cEntrypoint.Tests.ps1", "tests/pester/AuxiliaryContours.Tests.ps1", "tests/pester/AuxiliaryDatabaseAdmission.Tests.ps1")

        $twoActions = $oneAction.
            Replace('"vibecoding1c-mcp-status" { Show-Vibecoding1cMcpStatus }', '"vibecoding1c-mcp-status" { Show-Vibecoding1cMcpStatus | Out-Null }')
        $actionImpact = Resolve-Agent1cSemanticImpact -Catalog $catalog -CurrentText $twoActions -BaselineText $entrypoint
        $actionImpact.fallback | Should -BeFalse
        @($actionImpact.impacts.name) | Should -Be @("update-auxiliary-contour", "vibecoding1c-mcp-status")
        @($actionImpact.tests) | Should -Be @("tests/pester/Agent1cEntrypoint.Tests.ps1", "tests/pester/AuxiliaryContours.Tests.ps1", "tests/pester/AuxiliaryDatabaseAdmission.Tests.ps1", "tests/pester/McpConfig.Tests.ps1", "tests/pester/OnDemandMcp.Tests.ps1")
        @($actionImpact.tests).Count | Should -BeLessThan @($catalog.contracts | Where-Object id -eq "lifecycle").tests.Count

        $parameterText = $entrypoint.Replace('[string]$AuxiliaryDisplayName = ""', '[string]$AuxiliaryDisplayName = "semantic probe"')
        $parameterImpact = Resolve-Agent1cSemanticImpact -Catalog $catalog -CurrentText $parameterText -BaselineText $entrypoint
        $parameterImpact.fallback | Should -BeTrue
        $parameterImpact.reason | Should -Be 'unproven-parameter-AuxiliaryDisplayName'

        $functionText = $entrypoint.Replace("function Normalize-Agent1cFullPathText {", "function Normalize-Agent1cFullPathText {`n    # semantic probe")
        $functionImpact = Resolve-Agent1cSemanticImpact -Catalog $catalog -CurrentText $functionText -BaselineText $entrypoint
        $functionImpact.fallback | Should -BeTrue
        $functionImpact.reason | Should -Be 'unproven-function-Normalize-Agent1cFullPathText'

        $unprovenAction = $entrypoint.Replace('"release-e2e-snapshot" { Save-ReleaseE2EInfobaseSnapshot }', '"release-e2e-snapshot" { Show-Help }')
        (Resolve-Agent1cSemanticImpact -Catalog $catalog -CurrentText $unprovenAction -BaselineText $entrypoint).reason | Should -Be 'unproven-action-release-e2e-snapshot'
        $unprovenParameter = $entrypoint.Replace('[string]$ConfigLoadMode = "Auto"', '[string]$ConfigLoadMode = "Broken"')
        $unprovenParameter | Should -Not -Be $entrypoint
        (Resolve-Agent1cSemanticImpact -Catalog $catalog -CurrentText $unprovenParameter -BaselineText $entrypoint).reason | Should -Be 'unproven-parameter-ConfigLoadMode'

        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseInput($entrypoint, 'reorder-probe.ps1', [ref]$tokens, [ref]$errors)
        $definitions = @($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] } | Select-Object -First 2)
        $first = $definitions[0]; $second = $definitions[1]
        $between = $entrypoint.Substring($first.Extent.EndOffset, $second.Extent.StartOffset - $first.Extent.EndOffset)
        $reordered = $entrypoint.Substring(0, $first.Extent.StartOffset) + $second.Extent.Text + $between + $first.Extent.Text + $entrypoint.Substring($second.Extent.EndOffset)
        (Resolve-Agent1cSemanticImpact -Catalog $catalog -CurrentText $reordered -BaselineText $entrypoint).reason | Should -Be "shared-or-top-level-change"

        $unknownParameter = $entrypoint.Replace('[string]$ProjectRoot = (Get-Location).Path', '[string]$ProjectRoot = (Resolve-Path ".").Path')
        (Resolve-Agent1cSemanticImpact -Catalog $catalog -CurrentText $unknownParameter -BaselineText $entrypoint).reason | Should -Be "unknown-parameter-ProjectRoot"
        $topLevel = $entrypoint.Replace('Set-StrictMode -Version Latest', 'Set-StrictMode -Version 3')
        (Resolve-Agent1cSemanticImpact -Catalog $catalog -CurrentText $topLevel -BaselineText $entrypoint).reason | Should -Be "shared-or-top-level-change"
        $renamed = $entrypoint.Replace('"help" { Show-Help }', '"help-renamed" { Show-Help }')
        (Resolve-Agent1cSemanticImpact -Catalog $catalog -CurrentText $renamed -BaselineText $entrypoint).reason | Should -Be "actions-inventory-changed"
        $dynamic = $entrypoint.Replace('"help" { Show-Help }', '$script:DynamicAction { Show-Help }')
        (Resolve-Agent1cSemanticImpact -Catalog $catalog -CurrentText $dynamic -BaselineText $entrypoint).reason | Should -Be "current-dynamic-dispatch-label"
        (Resolve-Agent1cSemanticImpact -Catalog $catalog -CurrentText "'valid PowerShell without params'" -BaselineText $entrypoint).reason | Should -Be "current-missing-param-block"
        (Resolve-Agent1cSemanticImpact -Catalog $catalog -CurrentText $entrypoint -BaselineText $null).reason | Should -Be "missing-baseline"
        (Resolve-Agent1cSemanticImpact -Catalog $catalog -CurrentText $null -BaselineText $entrypoint).reason | Should -Be "missing-current-entrypoint"
    }
    It "writes Targeted selection schema v2 and carries the complete entrypoint as an additional input" {
        $resolver = Join-Path $RepoRoot "scripts\resolve-targeted-tests.ps1"
        $entrypoint = ".agents/skills/1c-workflow/scripts/agent-1c.ps1"
        $run = Invoke-TestPowerShellFile -FilePath $resolver -Arguments @("-RepositoryRoot", $RepoRoot, "-ChangedPath", $entrypoint)
        $run.exitCode | Should -Be 0 -Because ((@($run.stdout) + @($run.stderr)) -join [Environment]::NewLine)
        $selection = ($run.stdout -join [Environment]::NewLine) | ConvertFrom-Json
        [int]$selection.schemaVersion | Should -Be 2
        @($selection.additionalInputs) | Should -Be @($entrypoint)
        @($selection.semanticImpacts | ForEach-Object { "$($_.kind):$($_.name)" }) | Should -Be @("fallback:missing-baseline")
        @($selection.tests) | Should -Contain "tests/pester/DevBranchLifecycle.Tests.ps1"
        @($selection.tests) | Should -Contain "tests/pester/CompactItlRunner.Tests.ps1"

        $canonicalRun = Invoke-TestPowerShellFile -FilePath $resolver -Arguments @("-RepositoryRoot", $RepoRoot, "-BaseRef", "HEAD", "-ChangedPath", $entrypoint)
        $canonicalRun.exitCode | Should -Be 0 -Because ((@($canonicalRun.stdout) + @($canonicalRun.stderr)) -join [Environment]::NewLine)
        $canonicalSelection = ($canonicalRun.stdout -join [Environment]::NewLine) | ConvertFrom-Json
        @($canonicalSelection.semanticImpacts.name) | Should -Be @("no-semantic-impact") -Because "CRLF checkout bytes and LF git-show bytes must compare through the canonical Git filter"
    }
    It "falls back for a deleted or exactly renamed semantic entrypoint without reading a missing file" {
        $root = Join-Path ([IO.Path]::GetTempPath()) ("itl semantic rename путь " + [guid]::NewGuid().ToString("N"))
        $entrypoint = ".agents/skills/1c-workflow/scripts/agent-1c.ps1"
        $renamedEntrypoint = ".agents/skills/1c-workflow/scripts/agent-1c-renamed.ps1"
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $root ".agents\skills\1c-workflow\scripts"), (Join-Path $root "tests\pester") | Out-Null
            & git -C $root init *> $null
            & git -C $root config user.name "ITL Test"
            & git -C $root config user.email "itl-test@example.invalid"
            Set-Content -LiteralPath (Join-Path $root $entrypoint.Replace('/', '\')) -Encoding UTF8 -Value "param()"
            Set-Content -LiteralPath (Join-Path $root "tests\pester\Fallback.Tests.ps1") -Encoding UTF8 -Value "Describe 'fallback' { It 'passes' { `$true | Should -BeTrue } }"
            Set-Content -LiteralPath (Join-Path $root "full.txt") -Encoding UTF8 -Value "full"
            $catalog = [ordered]@{
                schemaVersion=1
                continuationScopes=[ordered]@{deliveryPostGate=@('delivery/*');develop=@('develop/*');gate=@('gate/*');release=@('release/*');static=@('tests/*')}
                developJourneys=[ordered]@{names=@('upgrade','fresh');fullPaths=@('full.txt');routes=[ordered]@{upgrade=[ordered]@{contracts=@('lifecycle')};fresh=[ordered]@{contracts=@('lifecycle')}}}
                retiredTests=[ordered]@{}
                contracts=@([ordered]@{id='lifecycle';owner='fixture';primaryTest='tests/pester/Fallback.Tests.ps1';gate='targeted';budgetSeconds=30;paths=@($entrypoint);tests=@('tests/pester/Fallback.Tests.ps1')})
                semanticTargeting=[ordered]@{path=$entrypoint;fallbackContract='lifecycle'}
            }
            New-Item -ItemType Directory -Force -Path (Join-Path $root "tests") | Out-Null
            [IO.File]::WriteAllText((Join-Path $root "tests\quality-contracts.json"), ($catalog | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
            & git -C $root add --all
            & git -C $root commit -m baseline *> $null
            $base = (& git -C $root rev-parse HEAD).Trim()
            $resolver = Join-Path $RepoRoot "scripts\resolve-targeted-tests.ps1"

            Remove-Item -LiteralPath (Join-Path $root $entrypoint.Replace('/', '\'))
            & git -C $root add --all
            & git -C $root commit -m deleted *> $null
            $deletedRun = Invoke-TestPowerShellFile -FilePath $resolver -Arguments @('-RepositoryRoot', $root, '-BaseRef', $base)
            $deletedRun.exitCode | Should -Be 0 -Because ((@($deletedRun.stdout) + @($deletedRun.stderr)) -join [Environment]::NewLine)
            $deleted = ($deletedRun.stdout -join [Environment]::NewLine) | ConvertFrom-Json
            @($deleted.semanticImpacts.name) | Should -Be @('missing-current-entrypoint')
            @($deleted.additionalInputs) | Should -BeNullOrEmpty
            @($deleted.tests) | Should -Be @('tests/pester/Fallback.Tests.ps1')

            & git -C $root switch --quiet -c rename-probe $base
            & git -C $root mv -- $entrypoint $renamedEntrypoint
            & git -C $root commit -m renamed *> $null
            $selectionPath = Join-Path $root 'rename-selection.json'
            $renamedRun = Invoke-TestPowerShellFile -FilePath $resolver -Arguments @('-RepositoryRoot', $root, '-BaseRef', $base, '-OutputPath', $selectionPath)
            $renamedRun.exitCode | Should -Be 0 -Because ((@($renamedRun.stdout) + @($renamedRun.stderr)) -join [Environment]::NewLine)
            $renamed = ($renamedRun.stdout -join [Environment]::NewLine) | ConvertFrom-Json
            @($renamed.semanticImpacts.name) | Should -Be @('missing-current-entrypoint')
            @($renamed.additionalInputs) | Should -Be @($renamedEntrypoint)
            @($renamed.tests) | Should -Be @('tests/pester/Fallback.Tests.ps1')

            $runner = Join-Path $RepoRoot 'scripts/invoke-pester-shards.ps1'
            $out1 = Join-Path $root 'rename-out-1'
            $firstRun = Invoke-TestPowerShellFile -FilePath $runner -Arguments @('-RepositoryRoot', $root, '-OutputRoot', $out1, '-JunitPath', (Join-Path $out1 'pester.xml'), '-WorkerCount', '1', '-SelectionPath', $selectionPath)
            $firstRun.exitCode | Should -Be 0 -Because ((@($firstRun.stdout) + @($firstRun.stderr)) -join [Environment]::NewLine)
            $first = ($firstRun.stdout -join [Environment]::NewLine) | ConvertFrom-Json
            Set-Content -LiteralPath (Join-Path $root $renamedEntrypoint.Replace('/', '\')) -Encoding UTF8 -Value "param()`n# renamed leaf changed"
            $out2 = Join-Path $root 'rename-out-2'
            $secondRun = Invoke-TestPowerShellFile -FilePath $runner -Arguments @('-RepositoryRoot', $root, '-OutputRoot', $out2, '-JunitPath', (Join-Path $out2 'pester.xml'), '-WorkerCount', '1', '-SelectionPath', $selectionPath)
            $secondRun.exitCode | Should -Be 0 -Because ((@($secondRun.stdout) + @($secondRun.stderr)) -join [Environment]::NewLine)
            $second = ($secondRun.stdout -join [Environment]::NewLine) | ConvertFrom-Json
            $first.executedWorkerCount | Should -Be 1
            $second.executedWorkerCount | Should -Be 1
            [string]$second.workers[0].inputDigest | Should -Not -Be ([string]$first.workers[0].inputDigest)
        } finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    It "selects common plus domain tests through the real BaseRef entrypoint route" {
        $root = Join-Path ([IO.Path]::GetTempPath()) ("itl semantic leaf путь " + [guid]::NewGuid().ToString("N"))
        try {
            & git clone --quiet --shared --no-hardlinks -- $RepoRoot $root
            $LASTEXITCODE | Should -Be 0
            & git -C $root config user.name "ITL Test"
            & git -C $root config user.email "itl-test@example.invalid"
            foreach ($relativePath in @(
                "scripts\quality-contracts.ps1",
                "tests\quality-contracts.json",
                "tests\pester\TestSupport.ps1",
                "tests\pester\Agent1cEntrypoint.Tests.ps1",
                "tests\pester\AuxiliaryContours.Tests.ps1",
                "tests\pester\McpConfig.Tests.ps1",
                "tests\pester\SourceDeliveryRunIndex.Tests.ps1",
                "tests\pester\SourceDeliveryRefCleanup.Tests.ps1"
            )) {
                Copy-Item -LiteralPath (Join-Path $RepoRoot $relativePath) -Destination (Join-Path $root $relativePath) -Force
            }
            & git -C $root add --all
            & git -C $root commit -m semantic-catalog *> $null
            $base = (& git -C $root rev-parse HEAD).Trim()
            $entrypoint = ".agents/skills/1c-workflow/scripts/agent-1c.ps1"
            $entrypointPath = Join-Path $root $entrypoint.Replace('/', '\')
            $text = [IO.File]::ReadAllText($entrypointPath, [Text.Encoding]::UTF8)
            $changed = $text.Replace('"update-auxiliary-contour" { Update-AuxiliaryContour }', '"update-auxiliary-contour" { Update-AuxiliaryContour | Out-Null }')
            $changed | Should -Not -Be $text
            [IO.File]::WriteAllText($entrypointPath, $changed, [Text.UTF8Encoding]::new($false))
            & git -C $root add -- $entrypoint
            & git -C $root commit -m leaf *> $null

            $resolver = Join-Path $RepoRoot "scripts\resolve-targeted-tests.ps1"
            $run = Invoke-TestPowerShellFile -FilePath $resolver -Arguments @('-RepositoryRoot', $root, '-BaseRef', $base)
            $run.exitCode | Should -Be 0 -Because ((@($run.stdout) + @($run.stderr)) -join [Environment]::NewLine)
            $selection = ($run.stdout -join [Environment]::NewLine) | ConvertFrom-Json
            @($selection.semanticImpacts | ForEach-Object { "$($_.kind):$($_.name):$($_.owner)" }) | Should -Be @('action:update-auxiliary-contour:auxiliary')
            @($selection.tests) | Should -Be @('tests/pester/Agent1cEntrypoint.Tests.ps1', 'tests/pester/AuxiliaryContours.Tests.ps1', 'tests/pester/AuxiliaryDatabaseAdmission.Tests.ps1')
            @($selection.additionalInputs) | Should -Be @($entrypoint)

            $broken = $text.Replace('"update-auxiliary-contour" { Update-AuxiliaryContour }', '"update-auxiliary-contour" { Show-Help }')
            $broken | Should -Not -Be $text
            [IO.File]::WriteAllText($entrypointPath, $broken, [Text.UTF8Encoding]::new($false))
            & git -C $root add -- $entrypoint
            & git -C $root commit -m mutation-kill *> $null
            $selectionPath = Join-Path $root 'mutation-selection.json'
            $mutationRun = Invoke-TestPowerShellFile -FilePath $resolver -Arguments @('-RepositoryRoot', $root, '-BaseRef', $base, '-OutputPath', $selectionPath)
            $mutationRun.exitCode | Should -Be 0 -Because ((@($mutationRun.stdout) + @($mutationRun.stderr)) -join [Environment]::NewLine)
            $mutationSelection = ($mutationRun.stdout -join [Environment]::NewLine) | ConvertFrom-Json
            @($mutationSelection.tests) | Should -Contain 'tests/pester/AuxiliaryContours.Tests.ps1'

            $runner = Join-Path $RepoRoot 'scripts/invoke-pester-shards.ps1'
            $outputRoot = Join-Path $root 'mutation-output'
            $mutantProof = Invoke-TestPowerShellFile -FilePath $runner -Arguments @('-RepositoryRoot', $root, '-OutputRoot', $outputRoot, '-JunitPath', (Join-Path $outputRoot 'pester.xml'), '-WorkerCount', '3', '-SelectionPath', $selectionPath)
            $mutantProof.exitCode | Should -Not -Be 0 -Because 'the selected public-entrypoint probe must kill a dispatch mutation'
            $workerOutput = @(Get-ChildItem -LiteralPath (Join-Path $outputRoot 'pester-shards') -File -Filter 'worker-*.stdout.log' | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 }) -join [Environment]::NewLine
            $workerOutput | Should -Match 'blocks configuration mutation for an attached read-only base before starting 1C'
        } finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    It "invalidates every selected shard when a schema v2 additional input changes" {
        $root = Join-Path ([IO.Path]::GetTempPath()) ("itl-additional-input путь " + [guid]::NewGuid().ToString("N"))
        $testRoot = Join-Path $root "tests\pester"
        try {
            New-Item -ItemType Directory -Force -Path $testRoot | Out-Null
            & git -C $root init *> $null
            & git -C $root config user.name "ITL Test"
            & git -C $root config user.email "itl-test@example.invalid"
            Set-Content -LiteralPath (Join-Path $testRoot "CacheA.Tests.ps1") -Encoding UTF8 -Value "Describe 'cache A' { It 'passes' { `$true | Should -BeTrue } }"
            Set-Content -LiteralPath (Join-Path $testRoot "CacheB.Tests.ps1") -Encoding UTF8 -Value "Describe 'cache B' { It 'passes' { `$true | Should -BeTrue } }"
            Set-Content -LiteralPath (Join-Path $root "entrypoint.ps1") -Encoding UTF8 -Value "entrypoint-v1"
            $catalog = [ordered]@{ schemaVersion=1; contracts=@(
                [ordered]@{id='cache-a';owner='fixture';primaryTest='tests/pester/CacheA.Tests.ps1';gate='targeted';budgetSeconds=30;paths=@('fixture/a/*');tests=@('tests/pester/CacheA.Tests.ps1')},
                [ordered]@{id='cache-b';owner='fixture';primaryTest='tests/pester/CacheB.Tests.ps1';gate='targeted';budgetSeconds=30;paths=@('fixture/b/*');tests=@('tests/pester/CacheB.Tests.ps1')}
            ) }
            [IO.File]::WriteAllText((Join-Path $root "tests\quality-contracts.json"), ($catalog | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
            $selectionPath = Join-Path $root "selection.json"
            $selection = [ordered]@{ schemaVersion=2; paths=@('entrypoint.ps1'); contracts=@([ordered]@{id='cache-a';owner='fixture'}, [ordered]@{id='cache-b';owner='fixture'}); tests=@('tests/pester/CacheA.Tests.ps1', 'tests/pester/CacheB.Tests.ps1'); semanticImpacts=@([ordered]@{kind='action';name='probe';owner='fixture'}); additionalInputs=@('entrypoint.ps1') }
            [IO.File]::WriteAllText($selectionPath, ($selection | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
            & git -C $root add --all
            & git -C $root commit -m fixture *> $null

            $runner = Join-Path $RepoRoot "scripts\invoke-pester-shards.ps1"
            $out1 = Join-Path $root "out1"
            $firstRun = Invoke-TestPowerShellFile -FilePath $runner -Arguments @("-RepositoryRoot", $root, "-OutputRoot", $out1, "-JunitPath", (Join-Path $out1 "pester.xml"), "-WorkerCount", "1", "-SelectionPath", $selectionPath)
            $firstRun.exitCode | Should -Be 0 -Because ((@($firstRun.stdout) + @($firstRun.stderr)) -join [Environment]::NewLine)
            $first = ($firstRun.stdout -join [Environment]::NewLine) | ConvertFrom-Json

            Set-Content -LiteralPath (Join-Path $root "entrypoint.ps1") -Encoding UTF8 -Value "entrypoint-v2"
            $out2 = Join-Path $root "out2"
            $secondRun = Invoke-TestPowerShellFile -FilePath $runner -Arguments @("-RepositoryRoot", $root, "-OutputRoot", $out2, "-JunitPath", (Join-Path $out2 "pester.xml"), "-WorkerCount", "1", "-SelectionPath", $selectionPath)
            $secondRun.exitCode | Should -Be 0 -Because ((@($secondRun.stdout) + @($secondRun.stderr)) -join [Environment]::NewLine)
            $second = ($secondRun.stdout -join [Environment]::NewLine) | ConvertFrom-Json
            $first.executedWorkerCount | Should -Be 2
            $second.executedWorkerCount | Should -Be 2
            foreach ($index in 0..1) {
                [string]$second.workers[$index].inputDigest | Should -Not -Be ([string]$first.workers[$index].inputDigest)
            }
        } finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    It "does not cache a shard whose external runtime identity is not modeled" {
        $runnerPath = Join-Path $RepoRoot 'scripts/invoke-pester-shards.ps1'
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($runnerPath, [ref]$tokens, [ref]$errors)
        $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-ShardInputDigest' }, $true)
        $actualCatalog = Get-Content -LiteralPath (Join-Path $RepoRoot 'tests/quality-contracts.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        @($actualCatalog.pesterNonReusableTests) | Should -Contain 'tests/pester/VanessaNestedSelection.Tests.ps1'
        $result = & {
            $RepositoryRoot = $RepoRoot
            # Contracts and hashing dependencies deliberately absent: the
            # runtime exclusion must apply before any cache key is produced.
            $catalog = [pscustomobject]@{ pesterNonReusableTests = @('tests/pester/VanessaNestedSelection.Tests.ps1') }
            . ([scriptblock]::Create($definition.Extent.Text))
            $path = Join-Path $RepoRoot 'tests/pester/VanessaNestedSelection.Tests.ps1'
            @((Get-ShardInputDigest -Paths @($path)), (Get-ShardInputDigest -Paths @($path) -IncludeLegacyGlobalExternalInputs))
        }
        @($result | Where-Object { $_ }) | Should -BeNullOrEmpty
    }
    It "completes and reruns an explicitly non-reusable passed file through the real shard runner" {
        $root = Join-Path $TestDrive 'Некэшируемая проверка с пробелом'
        $testRoot = Join-Path $root 'tests/pester'
        New-Item -ItemType Directory -Force -Path $testRoot | Out-Null
        & git -C $root init *> $null
        & git -C $root config user.name 'ITL Test'
        & git -C $root config user.email 'itl-test@example.invalid'
        Set-Content -LiteralPath (Join-Path $root '.gitignore') -Encoding UTF8 -Value "out/`ncounter.txt"
        $testText = "Describe 'external runtime' { It 'actually executes' { Add-Content -LiteralPath (Join-Path `$PSScriptRoot '../../counter.txt') -Value 'executed'; `$true | Should -BeTrue } }"
        Set-Content -LiteralPath (Join-Path $testRoot 'External.Tests.ps1') -Encoding UTF8 -Value $testText
        $catalog = [ordered]@{
            schemaVersion=1; pesterNonReusableTests=@('tests/pester/External.Tests.ps1')
            contracts=@([ordered]@{id='external';owner='fixture';primaryTest='tests/pester/External.Tests.ps1';gate='targeted';budgetSeconds=30;paths=@('fixture/*');tests=@('tests/pester/External.Tests.ps1')})
        }
        [IO.File]::WriteAllText((Join-Path $root 'tests/quality-contracts.json'), ($catalog | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        $selectionPath = Join-Path $root 'selection.json'
        [IO.File]::WriteAllText($selectionPath, '{"tests":["tests/pester/External.Tests.ps1"]}', [Text.UTF8Encoding]::new($false))
        & git -C $root add --all
        & git -C $root commit -m fixture *> $null
        $invoke = Join-Path $RepoRoot 'scripts/invoke-pester-shards.ps1'
        $output = Join-Path $root 'out'
        foreach ($attempt in 1..2) {
            $run = Invoke-TestPowerShellFile -FilePath $invoke -Arguments @('-RepositoryRoot', $root, '-OutputRoot', $output, '-JunitPath', (Join-Path $output 'pester.xml'), '-WorkerCount', '1', '-SelectionPath', $selectionPath)
            $run.exitCode | Should -Be 0 -Because ($run.stderr -join [Environment]::NewLine)
            $summary = ($run.stdout -join [Environment]::NewLine) | ConvertFrom-Json
            $summary.status | Should -Be 'passed'
            $summary.executedWorkerCount | Should -Be 1
            $summary.reusedWorkerCount | Should -Be 0
            $summary.workers[0].inputDigest | Should -BeNullOrEmpty
        }
        @(Get-Content -LiteralPath (Join-Path $root 'counter.txt')).Count | Should -Be 2
    }
    It "owns shard archive and cache hashing without Get-FileHash" {
        $runnerPath = Join-Path $RepoRoot "scripts\invoke-pester-shards.ps1"
        $runner = Get-Content -LiteralPath $runnerPath -Raw -Encoding UTF8
        $runner | Should -Not -Match '\bGet-FileHash\b'

        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($runnerPath, [ref]$tokens, [ref]$errors)
        @($errors) | Should -BeNullOrEmpty
        $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Get-PesterShardFileSha256" }, $true)
        $definition | Should -Not -BeNullOrEmpty
        $definition.Extent.StartOffset | Should -BeLessThan $runner.IndexOf('function Initialize-VanessaSourceBuildArchiveForPester', [StringComparison]::Ordinal)
        $definition.Extent.StartOffset | Should -BeLessThan $runner.IndexOf('function Get-ShardInputDigest', [StringComparison]::Ordinal)

        $payloadPath = Join-Path $TestDrive "hash probe data.bin"
        $payload = [byte[]](0, 1, 2, 3, 10, 13, 127, 128, 255)
        [IO.File]::WriteAllBytes($payloadPath, $payload)
        $sha256 = [Security.Cryptography.SHA256]::Create()
        try { $expected = ([BitConverter]::ToString($sha256.ComputeHash($payload))).Replace("-", "").ToLowerInvariant() } finally { $sha256.Dispose() }

        $probePath = Join-Path $TestDrive "local-shard-hash.ps1"
        [IO.File]::WriteAllText($probePath, @"
param([string]`$Path)
function Get-FileHash { throw "Get-FileHash must not be used" }
$($definition.Extent.Text)
Get-PesterShardFileSha256 -Path `$Path
"@, [Text.UTF8Encoding]::new($false))
        $probe = Invoke-TestPowerShellFile -FilePath $probePath -Arguments @("-Path", $payloadPath)
        $probe.exitCode | Should -Be 0
        $probe.stdout[-1] | Should -Be $expected
    }
    It "qualifies static and live candidate evidence without repeating Develop during Release" {
        $check = Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\check.ps1") -Raw -Encoding UTF8; $qualification = Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\release-qualification.ps1") -Raw -Encoding UTF8
        $promoter = Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\promote-ai-rules-compatibility.ps1") -Raw -Encoding UTF8
        $delivery = @("source-delivery.ps1", "source-delivery-supervisor.ps1", "source-delivery-process.ps1", "source-delivery-queue.ps1", "source-delivery-component.ps1", "source-delivery-candidate.ps1", "source-delivery-resources.ps1", "source-delivery-ref-cleanup.ps1", "source-delivery-cleanup.ps1" | ForEach-Object { Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\$_") -Raw -Encoding UTF8 }) -join [Environment]::NewLine
        $developJourney = Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\invoke-develop-e2e.ps1") -Raw -Encoding UTF8
        $check | Should -Match 'itl-workflow-full-qualification'
        $check | Should -Match 'source-delivery-ref-cleanup\.ps1' -Because 'ref cleanup code must invalidate reusable gate evidence'
        $check | Should -Match 'itl-workflow-develop-qualification'
        $check | Should -Match 'Test-DevelopQualification'
        $check | Should -Match 'Test-WorkflowQualification -Path \$qualificationFullPath.*-ForkIdentity \$aiRulesRelease'
        $check | Should -Match 'FullProof\.qualification\.repository\.commit'
        $check | Should -Match 'Write-DevelopQualification'
        $developProofIndex = $check.IndexOf('$releaseDevelopProof = Test-DevelopQualification', [StringComparison]::Ordinal)
        $fullRewriteIndex = $check.IndexOf('$existingQualification = Write-WorkflowQualification', [StringComparison]::Ordinal)
        $developProofIndex | Should -BeGreaterThan -1; $fullRewriteIndex | Should -BeGreaterThan $developProofIndex
        $check | Should -Match 'Add-ReusedStage -Name "develop-e2e"'
        $check | Should -Match 'Test-HasExactInventory'
        $check | Should -Match 'sha256 = Get-CanonicalTextSha256 -Path \$Path'
        $check | Should -Match '\$canonicalHash = Get-CanonicalTextSha256 -Path \$path'
        $check | Should -Match '\$byteHash = \(Get-FileHash -LiteralPath \$path -Algorithm SHA256\)'
        $check | Should -Match '\$canonicalHash -ne \$expectedHash -and \$byteHash -ne \$expectedHash'
        $check | Should -Match 'static-tracked-state'; $check | Should -Match ([regex]::Escape("-split ','"))
        foreach ($gateLeaf in @('source-delivery-process.ps1','source-delivery-queue.ps1','source-delivery-component.ps1','source-delivery-candidate.ps1')) { $check | Should -Match ([regex]::Escape($gateLeaf)) }
        $delivery | Should -Match 'StatusDetail'; $delivery | Should -Match 'Invoke-SourceDeliveryPostSuccessCleanup'
        $check | Should -Match 'infrastructure-retried-once'; $check | Should -Match 'retrySafeLeaf'
        $check | Should -Match '\$plannedJourneys\.Count -gt 0 -and \$plannedJourneys\.Count -lt \$allJourneys\.Count'
        $qualification | Should -Match 'merge-base --is-ancestor'
        $promoter | Should -Match 'qualificationSha256'
        $promoter | Should -Match 'compatibilityStatus'
        $delivery | Should -Match 'Restore-DeliveryQualification'
        $delivery | Should -Match 'Enter-DeliveryOperation'; $delivery | Should -Match 'gateProcessStartedAt'; $delivery | Should -Match 'Archive-StaleDeliveryOperation'
        $delivery | Should -Match 'itl\\qualifications'; $check | Should -Match ([regex]::Escape('Stop-GateChildProcessTree -Process $process'))
        foreach ($marker in @('update-workflow', 'SOURCE_INFOBASE_UNSAFE_ACTION_PROTECTION_MODE=confirmed', 'fresh-bootstrap-init-project', 'Assert-InitializedProject', 'lifecycle-operation.json', 'fresh-status', 'Git worktree: clean', '-Windowed', '$process.Handle', 'ITL develop E2E step', 'Stop-DevelopProcessTree', 'taskkill.exe /PID $processId /T /F', 'Assert-DevelopAiRulesSourceAvailable', 'source must contain the annotated tag', 'tag/lock mismatch', 'DEVELOP_E2E_SPECIAL_PATH_REQUIRED', 'fresh-missing-suite', 'fresh-stale-export', 'warn-unverified', 'stale-export-warn', 'Assert-FreshVerificationResult', '.agent-1c\dev-branches\{0}.json', 'Assert-ExportResult', 'Read-CompactSummary -ProcessResult $result', 'develop-e2e-cleanup.ps1', 'Remove-DevelopE2EFreshProject -FreshProjectsRoot $FreshProjectsRoot')) {
            $developJourney | Should -Match ([regex]::Escape($marker))
        }
        $developJourney | Should -Match ([regex]::Escape("fresh passed.*warn"))
        $developJourney | Should -Not -Match ([regex]::Escape("fresh passed.*policy warn"))
        $developJourney | Should -Match '\[Console\]::OutputEncoding = \$utf8'
        $developJourney | Should -Match '\$OutputEncoding = \$utf8'
        $developJourney | Should -Match 'tests\\features\\ITLDevelopJourney\.feature.*stale verification boundary'
    }
    It "removes an exact disposable E2E repository, worktree, and launcher registration" {
        $root = Join-Path ([IO.Path]::GetTempPath()) ("itl-e2e-cleanup-" + [guid]::NewGuid().ToString("N")); $main = Join-Path $root "d-1234abcd"; $branch = Join-Path $root "d-1234abcd-develop-golden"; $launcher = Join-Path $root "appdata\1C\1CEStart\ibases.v8i"
        try { New-Item -ItemType Directory -Force -Path $main | Out-Null; & git -C $main init *> $null; & git -C $main config user.name "ITL Test"; & git -C $main config user.email "itl-test@example.invalid"
            Set-Content -LiteralPath (Join-Path $main "value.txt") -Value "one" -Encoding ASCII; & git -C $main add value.txt; & git -C $main commit -m init *> $null; & git -C $main worktree add --quiet -b itldev/develop-golden $branch *> $null; . (Join-Path $RepoRoot "scripts\develop-e2e-cleanup.ps1")
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $launcher) | Out-Null; $infoBase = Join-Path $branch ".agent-1c\infobases\dev-branches\develop-golden"; New-Item -ItemType Directory -Force -Path $infoBase | Out-Null
            @('[keep]','Connect=File="C:\keep";','Folder=/','', '[d-1234abcd-develop-golden]','Connect=File="C:\keep-duplicate";','Folder=/Other','', '[d-1234abcd-develop-golden]',"Connect=File=`"$infoBase`";",'Folder=/ITL/d-1234abcd','', '[d-1234abcd]','OrderInList=-1','Folder=/ITL') | Set-Content -LiteralPath $launcher -Encoding UTF8
            Remove-DevelopE2EFreshProject -FreshProjectsRoot $root -Path $main -BranchPath $branch -LauncherListPath $launcher; Test-Path -LiteralPath $main | Should -BeFalse; Test-Path -LiteralPath $branch | Should -BeFalse
            $launcherText = Get-Content -LiteralPath $launcher -Raw -Encoding UTF8; $launcherText | Should -Match '\[keep\]'; $launcherText | Should -Match 'C:\\keep-duplicate'; $launcherText | Should -Not -Match 'Folder=/ITL/d-1234abcd'; $launcherText | Should -Not -Match '(?m)^\[d-1234abcd\]$'; @(Get-ChildItem -LiteralPath (Split-Path -Parent $launcher) -Filter 'ibases.v8i.*.bak').Count | Should -Be 1
            $bytes = [IO.File]::ReadAllBytes($launcher); @($bytes[0], $bytes[1], $bytes[2]) | Should -Be @(0xEF, 0xBB, 0xBF)
        } finally { if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force } }
    }
    It "bulk-removes only missing Develop E2E launcher registrations" {
        $root = Join-Path ([IO.Path]::GetTempPath()) ("itl-e2e-launcher-cleanup-" + [guid]::NewGuid().ToString("N")); $launcher = Join-Path $root "appdata\1C\1CEStart\ibases.v8i"; $existing = Join-Path $root "d-22222222-develop-golden\.agent-1c\infobases\dev-branches\develop-golden"
        try { New-Item -ItemType Directory -Force -Path (Split-Path -Parent $launcher), $existing | Out-Null; . (Join-Path $RepoRoot "scripts\develop-e2e-cleanup.ps1")
            $missing = Join-Path $root "d-11111111-develop-golden\.agent-1c\infobases\dev-branches\develop-golden"; @('[d-11111111-develop-golden]',"Connect=File=`"$missing`";",'Folder=/ITL/d-11111111','', '[d-11111111]','OrderInList=-1','Folder=/ITL','', '[d-22222222-develop-golden]',"Connect=File=`"$existing`";",'Folder=/ITL/d-22222222','', '[d-22222222]','OrderInList=-1','Folder=/ITL','', '[user-base]','Connect=File="C:\user";','Folder=/') | Set-Content -LiteralPath $launcher -Encoding UTF8
            Remove-DevelopE2EStaleLauncherRegistrations -FreshProjectsRoot $root -LauncherListPath $launcher | Should -Be 1; $launcherText = Get-Content -LiteralPath $launcher -Raw -Encoding UTF8
            $launcherText | Should -Not -Match 'd-11111111'; $launcherText | Should -Match 'd-22222222-develop-golden'; $launcherText | Should -Match '\[user-base\]'
        } finally { if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force } }
    }
    It "finds nested special-path fresh entries and retains only three launcher backups" {
        $root = Join-Path ([IO.Path]::GetTempPath()) ("itl nested launcher Проект " + [guid]::NewGuid().ToString("N")); $launcher = Join-Path $root "appdata\1C\1CEStart\ibases.v8i"
        try {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $launcher) | Out-Null; . (Join-Path $RepoRoot "scripts\develop-e2e-cleanup.ps1")
            $missing = Join-Path $root "p Проект\d-11111111-develop-golden\.agent-1c\infobases\dev-branches\develop-golden"
            @('[d-11111111-develop-golden]',"Connect=File=`"$missing`";",'Folder=/ITL/d-11111111','', '[d-11111111]','OrderInList=-1','Folder=/ITL') | Set-Content -LiteralPath $launcher -Encoding UTF8
            1..5 | ForEach-Object { Copy-Item -LiteralPath $launcher -Destination "$launcher.2026082$_-120000-000.bak" }
            Remove-DevelopE2EStaleLauncherRegistrations -FreshProjectsRoot $root -LauncherListPath $launcher | Should -Be 1
            @(Get-ChildItem -LiteralPath (Split-Path -Parent $launcher) -Filter 'ibases.v8i.*.bak').Count | Should -Be 3
            Get-Content -LiteralPath $launcher -Raw -Encoding UTF8 | Should -Not -Match 'd-11111111'
        } finally { if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force } }
    }
    It "removes only exact missing release-seed launcher entries" {
        $root = Join-Path ([IO.Path]::GetTempPath()) ("itl release launcher " + [guid]::NewGuid().ToString("N")); $launcher = Join-Path $root "appdata\1C\1CEStart\ibases.v8i"
        try {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $launcher) | Out-Null; . (Join-Path $RepoRoot "scripts\develop-e2e-cleanup.ps1")
            $missing = Join-Path $root 'itlsa-1234abcd\.agent-1c\infobases\dev-branches\release-seed-a-1234abcd'
            @('[itl-workflow-e2e-pm5-release-seed-a-1234abcd]',"Connect=File=`"$missing`";",'Folder=/ITL/itl-workflow-e2e-pm5','', '[user-base]',"Connect=File=`"$missing`";",'Folder=/') | Set-Content -LiteralPath $launcher -Encoding UTF8
            Remove-ReleaseE2EStaleLauncherRegistrations -LauncherListPath $launcher -SeedRoot $root | Should -Be 1
            $text = Get-Content -LiteralPath $launcher -Raw -Encoding UTF8; $text | Should -Not -Match 'itl-workflow-e2e-pm5-release-seed'; $text | Should -Match '\[user-base\]'
        } finally { if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force } }
    }
    It "removes verified Develop E2E CF exports while preserving unrelated result files" {
        $root = Join-Path ([IO.Path]::GetTempPath()) ("itl e2e exports Проект " + [guid]::NewGuid().ToString("N"))
        try {
            $resultRoot = Join-Path $root "build\result"; New-Item -ItemType Directory -Force -Path $resultRoot | Out-Null
            $artifact = Join-Path $resultRoot "current.cf"; Set-Content -LiteralPath $artifact -Encoding ASCII -Value "verified"
            $manifestPath = "$artifact.manifest.json"; $sha = (Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash.ToLowerInvariant()
            [IO.File]::WriteAllText($manifestPath, (([ordered]@{ artifact = [ordered]@{ path = $artifact; sha256 = $sha } } | ConvertTo-Json -Depth 4) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
            Set-Content -LiteralPath (Join-Path $resultRoot "old.cf") -Encoding ASCII -Value "old"
            Set-Content -LiteralPath (Join-Path $resultRoot "old.cf.manifest.json") -Encoding ASCII -Value "old manifest"
            Set-Content -LiteralPath (Join-Path $resultRoot "keep.txt") -Encoding ASCII -Value "keep"
            . (Join-Path $RepoRoot "scripts\develop-e2e-cleanup.ps1")
            $cleanup = Remove-DevelopE2EExportArtifacts -Root $root -Summary ([pscustomobject]@{ resultManifestPath = $manifestPath })
            $cleanup.removedFiles | Should -Be 4; $cleanup.removedBytes | Should -BeGreaterThan 0
            @(Get-ChildItem -LiteralPath $resultRoot -Filter "*.cf*" -File).Count | Should -Be 0
            Test-Path -LiteralPath (Join-Path $resultRoot "keep.txt") -PathType Leaf | Should -BeTrue
        } finally { if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force } }
    }
    It "removes only unconfigured workflow Release E2E worktrees after a passed journey" {
        $root = Join-Path ([IO.Path]::GetTempPath()) ("itl e2e worktrees Проект " + [guid]::NewGuid().ToString("N")); $main = Join-Path $root "main"; $release = Join-Path $root "release"; $develop = Join-Path $root "develop"; $stale = Join-Path $root "stale"
        try {
            New-Item -ItemType Directory -Force -Path $main | Out-Null; & git -C $main init --quiet; & git -C $main config user.name "ITL Test"; & git -C $main config user.email "itl-test@example.invalid"
            Set-Content -LiteralPath (Join-Path $main ".gitignore") -Encoding ASCII -Value ".agent-1c/`nbuild/"; Set-Content -LiteralPath (Join-Path $main "README.md") -Encoding ASCII -Value "fixture"
            & git -C $main add .gitignore README.md; & git -C $main commit --quiet -m init
            & git -C $main worktree add --quiet -b itldev/workflow-release-e2e $release; & git -C $main worktree add --quiet -b itldev/workflow-release-e2e-preflight $develop; & git -C $main worktree add --quiet -b itldev/workflow-release-e2e-rules $stale
            New-Item -ItemType Directory -Force -Path (Join-Path $main ".agent-1c"), (Join-Path $stale "build\result") | Out-Null
            [IO.File]::WriteAllText((Join-Path $main ".agent-1c\release-e2e.json"), (([ordered]@{ schemaVersion=1; devBranchName="workflow-release-e2e"; worktreePath=$release; developDevBranchName="workflow-release-e2e-preflight"; developWorktreePath=$develop } | ConvertTo-Json -Depth 4) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
            Set-Content -LiteralPath (Join-Path $stale "build\result\obsolete.cf") -Encoding ASCII -Value "obsolete"
            . (Join-Path $RepoRoot "scripts\develop-e2e-cleanup.ps1")
            $cleanup = Remove-DevelopE2EStaleStandWorktrees -ProjectRoot $main
            $cleanup.removedWorktrees | Should -Be 1; Test-Path -LiteralPath $stale | Should -BeFalse; Test-Path -LiteralPath $release | Should -BeTrue; Test-Path -LiteralPath $develop | Should -BeTrue
            & git -C $main show-ref --verify --quiet refs/heads/itldev/workflow-release-e2e-rules; $LASTEXITCODE | Should -Be 1
            $dirty = Join-Path $root "dirty"; & git -C $main worktree add --quiet -b itldev/workflow-release-e2e-dirty $dirty
            Set-Content -LiteralPath (Join-Path $dirty "README.md") -Encoding ASCII -Value "tracked drift"
            { Remove-DevelopE2EStaleStandWorktrees -ProjectRoot $main } | Should -Throw "*tracked changes*"
            Test-Path -LiteralPath $dirty -PathType Container | Should -BeTrue
        } finally { if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force } }
    }
    It "runs complete Pester as individually checkpointed files with bounded workers" {
        $runner = Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\invoke-pester-shards.ps1") -Raw -Encoding UTF8; $worker = Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\run-pester-shard.ps1") -Raw -Encoding UTF8
        $runner | Should -Match '\*\.Tests\.ps1'; $runner | Should -Match 'Get-ShardInputDigest -Paths @\(\[string\]\$item\.path\)'; $runner | Should -Match 'stopScheduling'
        $runner | Should -Match 'pendingParallel'; $runner | Should -Match 'pendingSerial'; $runner | Should -Match 'exact owner input fingerprint'; $runner | Should -Match 'CreateElement\("testsuites"\)'
        $runner | Should -Match 'Pester shard heartbeat:'; $runner | Should -Match 'Save-ShardCache -Digest \$digest -ResultPath \$resultPath -JunitPath \$workerJunit'
        $runner | Should -Match 'Expression = "weight"; Descending = \$true' -Because "long shards must start first so serial tail work fits the outer gate budget"
        $runner | Should -Match '\[string\]\$priorPlan\.inputDigest -eq \$digest'
        $runner | Should -Match 'Incomplete Pester shard cache is not empty'
        $runner | Should -Match 'Get-ShardInputDigest'; $runner | Should -Match 'itl\\pester-shards\\v1'
        $runner | Should -Match 'reusedWorkerCount'; $runner | Should -Match 'Save-ShardCache'; $runner | Should -Match 'SelectionPath'
        $runner | Should -Match 'Restore-ShardCache -Digest \$digest -ResultPath \$resultPath -JunitPath \$workerJunit -Worker \$index -TestPath'
        $runner | Should -Match 'Add-Member -NotePropertyName worker -NotePropertyValue \$Worker -Force'
        $runner | Should -Match 'Add-Member -NotePropertyName worker -NotePropertyValue \$index -Force'
        $runner | Should -Match '\$result\.paths = @\(\$TestPath\)'
        $runner | Should -Match '\$priorResult\.paths = @\(\[string\]\$item\.path\)'
        $runner | Should -Match 'Initialize-VanessaSourceBuildArchiveForPester'; $runner | Should -Match 'worktree list --porcelain'
        $runner | Should -Match 'itl\\dependencies\\vanessa-automation'; $runner | Should -Match 'Invoke-ItlImmutableFileDownload -Uri \$url -DestinationPath \$sharedArchive -ExpectedSha256 \$expected'
        $runner | Should -Match 'pesterExternalIdentityCache'; $runner | Should -Match 'pesterLegacyExternalIdentityCache'; $runner | Should -Match '\$configuredArchive'; $runner | Should -Match 'legacy external path normalized to exact content identity'
        $runner | Should -Match 'legacyInputDigests'; $runner | Should -Match 'legacyArchiveCandidates'
        $runner | Should -Match 'rev-list --max-count=8 HEAD'; $runner | Should -Match 'recentRootByHead'
        $runner | Should -Match 'hash-object --path \$RelativePath -- \$AbsolutePath'
        $runner | Should -Match 'ls-files", "-t", "-s", "-m", "-z"'
        $runner | Should -Match 'pesterTrackedIdentityCache'
        $runner | Should -Not -Match '& git -C \$RepositoryRoot diff --quiet'
        $runner | Should -Match 'fingerprintPlanMs'; $runner | Should -Match 'cacheLookupMs'; $runner | Should -Match 'workerSpanMs'
        $runner.IndexOf('$workerSpanStopwatch.Stop()') | Should -BeGreaterThan $runner.IndexOf('while (-not $stopScheduling -and $pendingSerial.Count -gt 0)')
        $runner | Should -Match '\$resetModulePathForWindowsPowerShell = \[string\]\$PSVersionTable\.PSEdition -eq "Core"'
        $worker | Should -Match 'SpecialFolder\]::MyDocuments'
        $worker | Should -Match 'Invoke-Pester -Configuration'
        (Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\test.ps1") -Raw -Encoding UTF8) | Should -Match '& powershell\.exe @runnerArguments'
    }
    It "reuses a focused dirty proof after the identical files are committed" {
        $root = Join-Path ([IO.Path]::GetTempPath()) ("itl focused путь " + [guid]::NewGuid().ToString("N")); $testRoot = Join-Path $root "tests\pester"; $fixtureRoot = Join-Path $root "fixture"
        try {
            New-Item -ItemType Directory -Force -Path $testRoot, $fixtureRoot | Out-Null; & git -C $root init *> $null; & git -C $root config user.name "ITL Test"; & git -C $root config user.email "itl-test@example.invalid"
            Set-Content -LiteralPath (Join-Path $fixtureRoot "owner.ps1") -Encoding UTF8 -Value "owner-v1"
            $testPath = Join-Path $testRoot "Cache.Tests.ps1"; Set-Content -LiteralPath $testPath -Encoding UTF8 -Value "Describe 'cache' { It 'passes' { `$true | Should -BeTrue } }"
            $catalog = [ordered]@{ schemaVersion=1; contracts=@([ordered]@{id='cache';owner='fixture';primaryTest='tests/pester/Cache.Tests.ps1';gate='targeted';budgetSeconds=30;paths=@('fixture/*');tests=@('tests/pester/Cache.Tests.ps1')}) }; [IO.File]::WriteAllText((Join-Path $root "tests\quality-contracts.json"), ($catalog | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false)); $selectionPath=Join-Path $root 'selection.json'; [IO.File]::WriteAllText($selectionPath, '{"tests":["tests/pester/Cache.Tests.ps1"]}', [Text.UTF8Encoding]::new($false)); & git -C $root add --all; & git -C $root commit -m baseline *> $null
            Set-Content -LiteralPath (Join-Path $fixtureRoot "owner.ps1") -Encoding UTF8 -Value "owner-v2"
            Add-Content -LiteralPath $testPath -Encoding UTF8 -Value "# focused proof"
            $invoke = Join-Path $RepoRoot "scripts\invoke-pester-shards.ps1"; $out1 = Join-Path $root "out1"; $firstRun = Invoke-TestPowerShellFile -FilePath $invoke -Arguments @("-RepositoryRoot", $root, "-OutputRoot", $out1, "-JunitPath", (Join-Path $out1 "pester.xml"), "-WorkerCount", "1", "-SelectionPath", $selectionPath); $firstRun.exitCode | Should -Be 0 -Because ((@($firstRun.stdout) + @($firstRun.stderr)) -join [Environment]::NewLine); $first = ($firstRun.stdout -join [Environment]::NewLine) | ConvertFrom-Json
            & git -C $root add --all; & git -C $root commit -m proven *> $null
            $out2 = Join-Path $root "out2"; $secondRun = Invoke-TestPowerShellFile -FilePath $invoke -Arguments @("-RepositoryRoot", $root, "-OutputRoot", $out2, "-JunitPath", (Join-Path $out2 "pester.xml"), "-WorkerCount", "1", "-SelectionPath", $selectionPath); $secondRun.exitCode | Should -Be 0 -Because ((@($secondRun.stdout) + @($secondRun.stderr)) -join [Environment]::NewLine); $second = ($secondRun.stdout -join [Environment]::NewLine) | ConvertFrom-Json
            $first.executedWorkerCount | Should -Be 1; $second.reusedWorkerCount | Should -Be 1; [string]$second.workers[0].inputDigest | Should -Be ([string]$first.workers[0].inputDigest)
            $second.legacyDigestCount | Should -Be 0
            $second.fingerprintPlanMs | Should -BeGreaterOrEqual 0
            $second.cacheLookupMs | Should -BeGreaterOrEqual 0
            $second.workerSpanMs | Should -BeGreaterOrEqual 0
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It "runs owner-selected upgrade before complete Pester and records shard timing metrics" {
        $check = Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\check.ps1") -Raw -Encoding UTF8
        $early = $check.IndexOf('owner-selected fail-fast $journey journey before complete Pester')
        $pester = $check.IndexOf('Invoke-GateStage -Name "pester"')
        $early | Should -BeGreaterOrEqual 0
        $early | Should -BeLessThan $pester
        $check | Should -Match 'Set-StageMetrics -Name "pester"'
        $check | Should -Match 'executedWorkerCount = \[int\]\$pesterShardSummary\.executedWorkerCount'
        . (Join-Path $RepoRoot "scripts\quality-contracts.ps1")
        $catalog = Get-QualityContractCatalog -RepositoryRoot $RepoRoot
        @($catalog.developJourneys.failFastOrder) | Should -Be @("upgrade")
        @($catalog.developJourneys.routes.upgrade.contracts) | Should -Contain "lifecycle"
    }
    It "reuses only a passed shard with the same owner inputs" {
        $root = Join-Path ([IO.Path]::GetTempPath()) ("itl-shard-cache-" + [guid]::NewGuid().ToString("N")); $testRoot = Join-Path $root "tests\pester"
        $previousArchive = [Environment]::GetEnvironmentVariable('ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE', 'Process')
        try { New-Item -ItemType Directory -Force -Path $testRoot | Out-Null; & git -C $root init *> $null; & git -C $root config user.name "ITL Test"; & git -C $root config user.email "itl-test@example.invalid"; & git -C $root config core.autocrlf true
            $testPath = Join-Path $testRoot "Cache.Tests.ps1"; Set-Content -LiteralPath $testPath -Encoding UTF8 -Value "Describe 'cache' { It 'passes' { `$true | Should -BeTrue } }"
            $archiveOne = Join-Path $root "archive путь one.zip"; $archiveTwo = Join-Path $root "archive путь two.zip"; [IO.File]::WriteAllBytes($archiveOne, [byte[]](1,2,3,4)); [IO.File]::WriteAllBytes($archiveTwo, [byte[]](1,2,3,4))
            $catalog = [ordered]@{ schemaVersion=1; pesterExternalInputs=[ordered]@{'tests/pester/Cache.Tests.ps1'=@('ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE')}; contracts=@([ordered]@{id='cache';owner='fixture';primaryTest='tests/pester/Cache.Tests.ps1';gate='full';budgetSeconds=30;paths=@('fixture/*');tests=@('tests/pester/Cache.Tests.ps1')}) }; [IO.File]::WriteAllText((Join-Path $root "tests\quality-contracts.json"), ($catalog | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false)); $selectionPath=Join-Path $root 'selection.json'; [IO.File]::WriteAllText($selectionPath, '{"tests":["tests/pester/Cache.Tests.ps1"]}', [Text.UTF8Encoding]::new($false)); & git -C $root add --all; & git -C $root commit -m fixture *> $null
            $env:ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE = $archiveOne
            $invoke = Join-Path $RepoRoot "scripts\invoke-pester-shards.ps1"; $out1 = Join-Path $root "out1"; $firstRun = Invoke-TestPowerShellFile -FilePath $invoke -Arguments @("-RepositoryRoot", $root, "-OutputRoot", $out1, "-JunitPath", (Join-Path $out1 "pester.xml"), "-WorkerCount", "1", "-SelectionPath", $selectionPath); $firstRun.exitCode | Should -Be 0 -Because ((@($firstRun.stdout) + @($firstRun.stderr)) -join [Environment]::NewLine); $first = ($firstRun.stdout -join [Environment]::NewLine) | ConvertFrom-Json
            $digest = [string]$first.workers[0].inputDigest; $entryRoot = Join-Path $root ".git\itl\pester-shards\v1\$digest"; $nested = Join-Path $entryRoot ".$digest.fixture.tmp"; New-Item -ItemType Directory -Path $nested | Out-Null; Get-ChildItem -LiteralPath $entryRoot -File | Move-Item -Destination $nested
            $env:ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE = $archiveTwo
            $out2 = Join-Path $root "out2"; $secondRun = Invoke-TestPowerShellFile -FilePath $invoke -Arguments @("-RepositoryRoot", $root, "-OutputRoot", $out2, "-JunitPath", (Join-Path $out2 "pester.xml"), "-WorkerCount", "1", "-SelectionPath", $selectionPath); $secondRun.exitCode | Should -Be 0; $second = ($secondRun.stdout -join [Environment]::NewLine) | ConvertFrom-Json; $first.executedWorkerCount | Should -Be 1; $second.reusedWorkerCount | Should -Be 1
            $originalBytes = [IO.File]::ReadAllBytes($testPath); $originalHasBom = $originalBytes.Length -ge 3 -and $originalBytes[0] -eq 0xEF -and $originalBytes[1] -eq 0xBB -and $originalBytes[2] -eq 0xBF
            $lfText = (Get-Content -LiteralPath $testPath -Raw -Encoding UTF8).Replace("`r`n", "`n"); [IO.File]::WriteAllText($testPath, $lfText, [Text.UTF8Encoding]::new($originalHasBom)); (& git -C $root diff --quiet -- "tests/pester/Cache.Tests.ps1"); $LASTEXITCODE | Should -Be 0
            $out3 = Join-Path $root "out3"; $lineEndingRun = Invoke-TestPowerShellFile -FilePath $invoke -Arguments @("-RepositoryRoot", $root, "-OutputRoot", $out3, "-JunitPath", (Join-Path $out3 "pester.xml"), "-WorkerCount", "1", "-SelectionPath", $selectionPath); $lineEndingRun.exitCode | Should -Be 0 -Because ((@($lineEndingRun.stdout) + @($lineEndingRun.stderr)) -join [Environment]::NewLine); $lineEnding = ($lineEndingRun.stdout -join [Environment]::NewLine) | ConvertFrom-Json; $lineEnding.executedWorkerCount | Should -Be 0; $lineEnding.reusedWorkerCount | Should -Be 1; [string]$lineEnding.workers[0].inputDigest | Should -Be $digest
            [IO.File]::WriteAllBytes($archiveTwo, [byte[]](9,8,7,6)); $out4 = Join-Path $root "out4"; $externalRun = Invoke-TestPowerShellFile -FilePath $invoke -Arguments @("-RepositoryRoot", $root, "-OutputRoot", $out4, "-JunitPath", (Join-Path $out4 "pester.xml"), "-WorkerCount", "1", "-SelectionPath", $selectionPath); $externalRun.exitCode | Should -Be 0; $external = ($externalRun.stdout -join [Environment]::NewLine) | ConvertFrom-Json; $external.executedWorkerCount | Should -Be 1; [string]$external.workers[0].inputDigest | Should -Not -Be $digest
            Add-Content -LiteralPath $testPath -Encoding UTF8 -Value "# changed owner input"; $out5 = Join-Path $root "out5"; $fifthRun = Invoke-TestPowerShellFile -FilePath $invoke -Arguments @("-RepositoryRoot", $root, "-OutputRoot", $out5, "-JunitPath", (Join-Path $out5 "pester.xml"), "-WorkerCount", "1", "-SelectionPath", $selectionPath); $fifthRun.exitCode | Should -Be 0; $fifth = ($fifthRun.stdout -join [Environment]::NewLine) | ConvertFrom-Json; $fifth.executedWorkerCount | Should -Be 1
        } finally { [Environment]::SetEnvironmentVariable('ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE', $previousArchive, 'Process'); Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It "keeps undeclared external identities out of a shard digest" {
        $root = Join-Path ([IO.Path]::GetTempPath()) ("itl-shard-external-scope-" + [guid]::NewGuid().ToString("N")); $testRoot = Join-Path $root "tests\pester"
        $previousArchive = [Environment]::GetEnvironmentVariable('ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE', 'Process'); $previousRules = [Environment]::GetEnvironmentVariable('ITL_AI_RULES_SOURCE_PATH', 'Process')
        try {
            New-Item -ItemType Directory -Force -Path $testRoot | Out-Null; & git -C $root init *> $null; & git -C $root config user.name "ITL Test"; & git -C $root config user.email "itl-test@example.invalid"
            Set-Content -LiteralPath (Join-Path $testRoot "Cache.Tests.ps1") -Encoding UTF8 -Value "Describe 'cache' { It 'passes' { `$true | Should -BeTrue } }"
            $archiveOne = Join-Path $root "archive один.zip"; $archiveTwo = Join-Path $root "archive два.zip"; [IO.File]::WriteAllBytes($archiveOne, [byte[]](1)); [IO.File]::WriteAllBytes($archiveTwo, [byte[]](2))
            $rulesOne = Join-Path $root "rules один"; $rulesTwo = Join-Path $root "rules два"; New-Item -ItemType Directory -Path $rulesOne, $rulesTwo | Out-Null
            $catalog = [ordered]@{ schemaVersion=1; pesterExternalInputs=[ordered]@{}; contracts=@([ordered]@{id='cache';owner='fixture';primaryTest='tests/pester/Cache.Tests.ps1';gate='full';budgetSeconds=30;paths=@('fixture/*');tests=@('tests/pester/Cache.Tests.ps1')}) }; [IO.File]::WriteAllText((Join-Path $root "tests\quality-contracts.json"), ($catalog | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false)); $selectionPath=Join-Path $root 'selection.json'; [IO.File]::WriteAllText($selectionPath, '{"tests":["tests/pester/Cache.Tests.ps1"]}', [Text.UTF8Encoding]::new($false)); & git -C $root add --all; & git -C $root commit -m fixture *> $null
            $env:ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE = $archiveOne; $env:ITL_AI_RULES_SOURCE_PATH = $rulesOne; $invoke = Join-Path $RepoRoot "scripts\invoke-pester-shards.ps1"; $out1 = Join-Path $root "out1"; $firstRun = Invoke-TestPowerShellFile -FilePath $invoke -Arguments @("-RepositoryRoot", $root, "-OutputRoot", $out1, "-JunitPath", (Join-Path $out1 "pester.xml"), "-WorkerCount", "1", "-SelectionPath", $selectionPath); $firstRun.exitCode | Should -Be 0; $first = ($firstRun.stdout -join [Environment]::NewLine) | ConvertFrom-Json
            $env:ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE = $archiveTwo; $env:ITL_AI_RULES_SOURCE_PATH = $rulesTwo; $out2 = Join-Path $root "out2"; $secondRun = Invoke-TestPowerShellFile -FilePath $invoke -Arguments @("-RepositoryRoot", $root, "-OutputRoot", $out2, "-JunitPath", (Join-Path $out2 "pester.xml"), "-WorkerCount", "1", "-SelectionPath", $selectionPath); $secondRun.exitCode | Should -Be 0; $second = ($secondRun.stdout -join [Environment]::NewLine) | ConvertFrom-Json
            $first.executedWorkerCount | Should -Be 1; $second.executedWorkerCount | Should -Be 0; $second.reusedWorkerCount | Should -Be 1; [string]$second.workers[0].inputDigest | Should -Be ([string]$first.workers[0].inputDigest)
        } finally { [Environment]::SetEnvironmentVariable('ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE', $previousArchive, 'Process'); [Environment]::SetEnvironmentVariable('ITL_AI_RULES_SOURCE_PATH', $previousRules, 'Process'); Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It "reuses an unchanged passed test file across runner and neighboring test repairs" {
        $root = Join-Path ([IO.Path]::GetTempPath()) ("itl runner путь " + [guid]::NewGuid().ToString("N")); $testRoot = Join-Path $root "tests\pester"; $scriptRoot = Join-Path $root "scripts"
        try {
            New-Item -ItemType Directory -Force -Path $testRoot, $scriptRoot | Out-Null; & git -C $root init *> $null; & git -C $root config user.name "ITL Test"; & git -C $root config user.email "itl-test@example.invalid"
            $testPath = Join-Path $testRoot "Cache.Tests.ps1"; Set-Content -LiteralPath $testPath -Encoding UTF8 -Value "Describe 'cache' { It 'passes' { `$true | Should -BeTrue } }"
            Set-Content -LiteralPath (Join-Path $scriptRoot "invoke-pester-shards.ps1") -Encoding ASCII -Value "runner-v1"
            Set-Content -LiteralPath (Join-Path $root ".gitignore") -Encoding ASCII -Value "out*/"
            $catalog = [ordered]@{ schemaVersion=1; contracts=@([ordered]@{id='cache';owner='fixture';primaryTest='tests/pester/Cache.Tests.ps1';gate='full';budgetSeconds=30;paths=@('fixture/*');tests=@('tests/pester/Cache.Tests.ps1')}) }; [IO.File]::WriteAllText((Join-Path $root "tests\quality-contracts.json"), ($catalog | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false)); $selectionPath=Join-Path $root 'selection.json'; [IO.File]::WriteAllText($selectionPath, '{"tests":["tests/pester/Cache.Tests.ps1"]}', [Text.UTF8Encoding]::new($false)); & git -C $root add --all; & git -C $root commit -m v1 *> $null
            $invoke = Join-Path $RepoRoot "scripts\invoke-pester-shards.ps1"; $out1 = Join-Path $root "out1"; (Invoke-TestPowerShellFile -FilePath $invoke -Arguments @("-RepositoryRoot", $root, "-OutputRoot", $out1, "-JunitPath", (Join-Path $out1 "pester.xml"), "-WorkerCount", "1", "-SelectionPath", $selectionPath)).exitCode | Should -Be 0
            Set-Content -LiteralPath (Join-Path $scriptRoot "invoke-pester-shards.ps1") -Encoding ASCII -Value "runner-v2"; Set-Content -LiteralPath (Join-Path $testRoot "Other.Tests.ps1") -Encoding UTF8 -Value "Describe 'other' { It 'changed' { `$true | Should -BeTrue } }"; & git -C $root add --all; & git -C $root commit -m v2 *> $null
            $out2 = Join-Path $root "out2"; $secondRun = Invoke-TestPowerShellFile -FilePath $invoke -Arguments @("-RepositoryRoot", $root, "-OutputRoot", $out2, "-JunitPath", (Join-Path $out2 "pester.xml"), "-WorkerCount", "1", "-SelectionPath", $selectionPath)
            $secondRun.exitCode | Should -Be 0; $second = ($secondRun.stdout -join [Environment]::NewLine) | ConvertFrom-Json
            $second.executedWorkerCount | Should -Be 0; $second.reusedWorkerCount | Should -Be 1; $second.workers[0].reuseReason | Should -Be "exact owner input fingerprint"
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It "restarts a failed Pester stage at the corrected test file and then runs only its downstream files" {
        $root = Join-Path ([IO.Path]::GetTempPath()) ("itl-file-checkpoint-" + [guid]::NewGuid().ToString("N")); $testRoot = Join-Path $root "tests\pester"
        try {
            New-Item -ItemType Directory -Force -Path $testRoot | Out-Null; & git -C $root init *> $null; & git -C $root config user.name "ITL Test"; & git -C $root config user.email "itl-test@example.invalid"
            Set-Content -LiteralPath (Join-Path $testRoot "A.Tests.ps1") -Encoding UTF8 -Value "Describe 'A' { It 'passes' { `$true | Should -BeTrue } }"
            Set-Content -LiteralPath (Join-Path $testRoot "B.Tests.ps1") -Encoding UTF8 -Value "Describe 'B' { It 'fails' { `$false | Should -BeTrue } }"
            Set-Content -LiteralPath (Join-Path $testRoot "C.Tests.ps1") -Encoding UTF8 -Value "Describe 'C' { It 'passes' { `$true | Should -BeTrue } }"
            $contracts = @('A','B','C') | ForEach-Object { [ordered]@{id=$_;owner='fixture';primaryTest="tests/pester/$_.Tests.ps1";gate='full';budgetSeconds=30;paths=@("fixture/$_/*");tests=@("tests/pester/$_.Tests.ps1")} }
            [IO.File]::WriteAllText((Join-Path $root "tests\quality-contracts.json"), ([ordered]@{schemaVersion=1;contracts=$contracts} | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
            $selectionPath=Join-Path $root 'selection.json'; [IO.File]::WriteAllText($selectionPath, '{"tests":["tests/pester/A.Tests.ps1","tests/pester/B.Tests.ps1","tests/pester/C.Tests.ps1"]}', [Text.UTF8Encoding]::new($false)); & git -C $root add --all; & git -C $root commit -m fixture *> $null
            $invoke = Join-Path $RepoRoot "scripts\invoke-pester-shards.ps1"; $out1 = Join-Path $root "out1"; $first = Invoke-TestPowerShellFile -FilePath $invoke -Arguments @("-RepositoryRoot", $root, "-OutputRoot", $out1, "-JunitPath", (Join-Path $out1 "pester.xml"), "-WorkerCount", "1", "-SelectionPath", $selectionPath)
            $first.exitCode | Should -Not -Be 0
            $failedSummary = Get-Content -LiteralPath (Join-Path $out1 "pester-shards\summary.json") -Raw -Encoding UTF8 | ConvertFrom-Json
            @($failedSummary.workers.paths | ForEach-Object { Split-Path $_ -Leaf }) | Should -Be @("A.Tests.ps1", "B.Tests.ps1")

            Set-Content -LiteralPath (Join-Path $testRoot "B.Tests.ps1") -Encoding UTF8 -Value "Describe 'B' { It 'is fixed' { `$true | Should -BeTrue } }"
            $out2 = Join-Path $root "out2"; $secondRun = Invoke-TestPowerShellFile -FilePath $invoke -Arguments @("-RepositoryRoot", $root, "-OutputRoot", $out2, "-JunitPath", (Join-Path $out2 "pester.xml"), "-WorkerCount", "1", "-SelectionPath", $selectionPath)
            $secondRun.exitCode | Should -Be 0; $second = ($secondRun.stdout -join [Environment]::NewLine) | ConvertFrom-Json
            $second.reusedWorkerCount | Should -Be 1; $second.executedWorkerCount | Should -Be 2
            @($second.workers | Where-Object execution -eq 'reused' | ForEach-Object { Split-Path $_.paths[0] -Leaf }) | Should -Be @("A.Tests.ps1")
            @($second.workers | Where-Object execution -eq 'executed' | ForEach-Object { Split-Path $_.paths[0] -Leaf }) | Should -Be @("B.Tests.ps1", "C.Tests.ps1")
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It "accepts only exact or ancestor same-tree qualification commits" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-qualification-reuse-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            & git -C $tempRoot init *> $null
            & git -C $tempRoot config user.name "ITL Test"
            & git -C $tempRoot config user.email "itl-test@example.invalid"
            Set-Content -LiteralPath (Join-Path $tempRoot "value.txt") -Encoding ASCII -Value "one"
            & git -C $tempRoot add value.txt; & git -C $tempRoot commit -m base *> $null
            $base = (& git -C $tempRoot rev-parse HEAD).Trim(); $baseTree = (& git -C $tempRoot rev-parse 'HEAD^{tree}').Trim()
            & git -C $tempRoot commit --allow-empty -m merge-like *> $null
            $descendant = (& git -C $tempRoot rev-parse HEAD).Trim(); $descendantTree = (& git -C $tempRoot rev-parse 'HEAD^{tree}').Trim()
            & git -C $tempRoot switch --quiet -c sibling $base *> $null; & git -C $tempRoot commit --allow-empty -m sibling *> $null
            $sibling = (& git -C $tempRoot rev-parse HEAD).Trim(); $siblingTree = (& git -C $tempRoot rev-parse 'HEAD^{tree}').Trim()
            Set-Content -LiteralPath (Join-Path $tempRoot "value.txt") -Encoding ASCII -Value "two"; & git -C $tempRoot add value.txt; & git -C $tempRoot commit -m changed *> $null
            $changed = (& git -C $tempRoot rev-parse HEAD).Trim(); $changedTree = (& git -C $tempRoot rev-parse 'HEAD^{tree}').Trim()
            . (Join-Path $RepoRoot "scripts\release-qualification.ps1")
            Get-WorkflowQualificationReuseKind -RepositoryRoot $tempRoot -SchemaVersion 2 -QualifiedCommit $base -EvidenceCommit $base -QualifiedTree $baseTree -CurrentCommit $base -CurrentTree $baseTree | Should -Be "exact-commit"
            Get-WorkflowQualificationReuseKind -RepositoryRoot $tempRoot -SchemaVersion 2 -QualifiedCommit $base -EvidenceCommit $base -QualifiedTree $baseTree -CurrentCommit $descendant -CurrentTree $descendantTree | Should -Be "ancestor-same-tree"
            Get-WorkflowQualificationReuseKind -RepositoryRoot $tempRoot -SchemaVersion 1 -QualifiedCommit $base -EvidenceCommit $base -QualifiedTree $baseTree -CurrentCommit $descendant -CurrentTree $descendantTree | Should -Be ""
            Get-WorkflowQualificationReuseKind -RepositoryRoot $tempRoot -SchemaVersion 2 -QualifiedCommit $sibling -EvidenceCommit $sibling -QualifiedTree $siblingTree -CurrentCommit $descendant -CurrentTree $descendantTree | Should -Be ""
            Get-WorkflowQualificationReuseKind -RepositoryRoot $tempRoot -SchemaVersion 2 -QualifiedCommit $base -EvidenceCommit $base -QualifiedTree $baseTree -CurrentCommit $changed -CurrentTree $changedTree | Should -Be ""
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It "allows cross-tree continuation only for declared scopes with an exact passed Targeted run" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-continuation-proof-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot "tests\pester") | Out-Null
            & git -C $tempRoot init *> $null
            & git -C $tempRoot config user.name "ITL Test"
            & git -C $tempRoot config user.email "itl-test@example.invalid"
            Set-Content -LiteralPath (Join-Path $tempRoot "workflow.txt") -Encoding ASCII -Value "production"
            Set-Content -LiteralPath (Join-Path $tempRoot "tests\pester\Fixture.Tests.ps1") -Encoding ASCII -Value "Describe fixture {}"
            [IO.File]::WriteAllText((Join-Path $tempRoot "tests\quality-contracts.json"), '{"continuationScopes":{"static":["tests/pester/*"]}}', [Text.UTF8Encoding]::new($false))
            & git -C $tempRoot add --all; & git -C $tempRoot commit -m base *> $null
            $base = (& git -C $tempRoot rev-parse HEAD).Trim()

            Add-Content -LiteralPath (Join-Path $tempRoot "tests\pester\Fixture.Tests.ps1") -Encoding ASCII -Value "# fixed test"
            & git -C $tempRoot add --all; & git -C $tempRoot commit -m "fix test" *> $null
            $current = (& git -C $tempRoot rev-parse HEAD).Trim(); $tree = (& git -C $tempRoot rev-parse 'HEAD^{tree}').Trim()
            $runRoot = Join-Path $tempRoot ".git\itl\runs"; New-Item -ItemType Directory -Force -Path $runRoot | Out-Null
            $run = [ordered]@{ schemaVersion=1; mode="Targeted"; status="passed"; exitCode=0; commit=$current; tree=$tree; finishedAt=[DateTime]::UtcNow.ToString("o"); stages=@(
                [ordered]@{name="pester";status="passed"}, [ordered]@{name="tracked-state";status="passed"}, [ordered]@{name="git-diff-check";status="passed"}
            ) }
            [IO.File]::WriteAllText((Join-Path $runRoot "20260809-000000-000-targeted-proof.json"), (($run | ConvertTo-Json -Depth 6) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))

            . (Join-Path $RepoRoot "scripts\git-path-list.ps1")
            . (Join-Path $RepoRoot "scripts\release-qualification.ps1")
            $proof = Get-WorkflowContinuationProof -RepositoryRoot $tempRoot -QualifiedCommit $base -CurrentCommit $current -CurrentTree $tree
            @($proof.scopes) | Should -Be @("static")
            @($proof.paths) | Should -Be @("tests/pester/Fixture.Tests.ps1")
            Test-RecordedWorkflowContinuation -Record $proof -Commit $current -Tree $tree | Should -BeTrue

            # PublishDevelop rebuilds a deterministic merge candidate from the
            # same remote base after every failed publication. Those sibling
            # merge commits are a continuation when their registered queue head
            # advances and owns an exact Targeted proof.
            $firstCandidate = (& git -C $tempRoot commit-tree $tree -p $base -p $current -m "Merge registered develop queue 'develop' at $current").Trim()
            Add-Content -LiteralPath (Join-Path $tempRoot "tests\pester\Fixture.Tests.ps1") -Encoding ASCII -Value "# second fix"
            & git -C $tempRoot add --all; & git -C $tempRoot commit -m "fix test again" *> $null
            $queueHead = (& git -C $tempRoot rev-parse HEAD).Trim(); $queueTree = (& git -C $tempRoot rev-parse 'HEAD^{tree}').Trim()
            $queueRun = [ordered]@{ schemaVersion=1; mode="Targeted"; status="passed"; exitCode=0; commit=$queueHead; tree=$queueTree; finishedAt=[DateTime]::UtcNow.ToString("o"); stages=@(
                [ordered]@{name="pester";status="passed"}, [ordered]@{name="tracked-state";status="passed"}, [ordered]@{name="git-diff-check";status="passed"}
            ) }
            [IO.File]::WriteAllText((Join-Path $runRoot "20260809-000001-000-targeted-proof.json"), (($queueRun | ConvertTo-Json -Depth 6) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
            $secondCandidate = (& git -C $tempRoot commit-tree $queueTree -p $base -p $queueHead -m "Merge registered develop queue 'develop' at $queueHead").Trim()
            $candidateProof = Get-WorkflowContinuationProof -RepositoryRoot $tempRoot -QualifiedCommit $firstCandidate -CurrentCommit $secondCandidate -CurrentTree $queueTree
            $candidateProof.proofKind | Should -Be "source-delivery-candidate"
            $candidateProof.targetedCommit | Should -Be $queueHead
            @($candidateProof.paths) | Should -Be @("tests/pester/Fixture.Tests.ps1")
            Test-RecordedWorkflowContinuation -Record $candidateProof -Commit $secondCandidate -Tree $queueTree | Should -BeTrue

            $badCandidate = (& git -C $tempRoot commit-tree $queueTree -p $base -p $queueHead -m "unmanaged merge candidate").Trim()
            Get-WorkflowContinuationProof -RepositoryRoot $tempRoot -QualifiedCommit $firstCandidate -CurrentCommit $badCandidate -CurrentTree $queueTree | Should -BeNullOrEmpty
            $forgedCandidate = (& git -C $tempRoot commit-tree $tree -p $base -p $queueHead -m "Merge registered develop queue 'develop' at $queueHead").Trim()
            Get-WorkflowContinuationProof -RepositoryRoot $tempRoot -QualifiedCommit $firstCandidate -CurrentCommit $forgedCandidate -CurrentTree $tree | Should -BeNullOrEmpty

            Add-Content -LiteralPath (Join-Path $tempRoot "workflow.txt") -Encoding ASCII -Value "changed"
            & git -C $tempRoot add --all; & git -C $tempRoot commit -m "change production" *> $null
            $productionCommit = (& git -C $tempRoot rev-parse HEAD).Trim(); $productionTree = (& git -C $tempRoot rev-parse 'HEAD^{tree}').Trim()
            Get-WorkflowContinuationProof -RepositoryRoot $tempRoot -QualifiedCommit $base -CurrentCommit $productionCommit -CurrentTree $productionTree | Should -BeNullOrEmpty
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It "classifies Release readiness repairs as resumable Release harness changes" {
        $catalog = Get-Content -LiteralPath (Join-Path $RepoRoot "tests\quality-contracts.json") -Raw -Encoding UTF8 | ConvertFrom-Json
        @($catalog.continuationScopes.release) | Should -Contain "scripts/test-release-readiness.ps1"
    }

    It "keeps repository-only guidance out of installed packages and preserves the managed skills" {
        Test-Path -LiteralPath (Join-Path $RepoRoot ".githooks") | Should -BeFalse
        $expected = @("1c-workflow", "1c-workflow-fast", "itl-roctup-1c-data", "itl-vanessa-ui-mcp", "itl-performance", "itl-remote-runner", "itl-remote-agent", "product-docs") | Sort-Object
        $actual = @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot ".agents\skills") -Directory | Select-Object -ExpandProperty Name | Sort-Object)
        $actual | Should -Be $expected
        $docs = Get-Content -LiteralPath (Join-Path $RepoRoot "docs\local-quality-gate.md") -Raw -Encoding UTF8
        $docs | Should -Match "Git hooks"
        $docs | Should -Match "GitHub Actions"
        $docs | Should -Match "continuation\s+scope"
        $docs | Should -Match 'точный прошедший `Targeted`'
    }
}
