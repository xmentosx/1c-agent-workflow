BeforeAll {
    . (Join-Path $PSScriptRoot "TestSupport.ps1")
    $context = Initialize-WorkflowPesterContext
    $RepoRoot = $context.RepoRoot
}

Describe "Local quality gate contract" {
    It 'retains complete owner fallback when a reviewed baseline gains the stale-pin diagnostic' {
        . (Join-Path $RepoRoot 'scripts/quality-contracts.ps1')
        $catalog = Get-QualityContractCatalog -RepositoryRoot $RepoRoot
        $path = '.agents/skills/1c-workflow/scripts/lib/agent-1c.lifecycle.ps1'
        # Freeze only this regression's reviewed call set, so a future valid
        # production pin update cannot turn the safe-fallback test into a barrier.
        $text = "function Invoke-DevBranchCheck { Write-Output 'baseline' }"
        $model = Get-Agent1cSemanticModel -Text $text -Library
        $catalog.semanticTargeting.libraries.PSObject.Properties[$path].Value.functions.'Invoke-DevBranchCheck'.callsSha256 = Get-QualityFunctionInvocationInventory -Model $model -Name 'Invoke-DevBranchCheck'
        $signature = 'function Invoke-DevBranchCheck {'
        $baseline = $text.Replace($signature,$signature+"`n    Write-Verbose 'owner-local diagnostic'")
        $baseline | Should -Not -Be $text
        $current = $baseline.Replace($signature,$signature+"`n    # next local edit")
        (Test-QualityContractCatalog -RepositoryRoot $RepoRoot -Catalog $catalog) | Should -BeTrue
        $impact = Resolve-Agent1cSemanticImpact -Catalog $catalog -LibraryPath $path -BaselineText $baseline -CurrentText $current
        $impact.fallback | Should -BeTrue
        $impact.reason | Should -Be 'function-dependencies-changed-Invoke-DevBranchCheck'
        @($impact.tests) | Should -Be @((Resolve-QualityContractsForPaths -Catalog $catalog -Paths @($path)).tests)
    }

    It 'classifies both ends of a library rename into <destination>' -TestCases @(
        @{ destination='scripts/release-e2e/перенесённый модуль.ps1'; known=$true; edit=$false },
        @{ destination='unknown/перенесённый модуль.ps1'; known=$false; edit=$false },
        @{ destination='.agents/skills/1c-workflow/scripts/lib/agent-1c.изменённый модуль.ps1'; known=$false; edit=$true }
    ) {
        param($destination,$known,$edit)
        . (Join-Path $RepoRoot 'scripts/quality-contracts.ps1')
        $root = Join-Path $TestDrive ('rename владелец с пробелом '+[guid]::NewGuid().ToString('N'))
        & git -c core.longpaths=true clone --quiet --shared --no-hardlinks -- $RepoRoot $root
        $LASTEXITCODE | Should -Be 0
        Copy-Item -LiteralPath (Join-Path $RepoRoot 'tests/quality-contracts.json') -Destination (Join-Path $root 'tests/quality-contracts.json') -Force
        & git -C $root add -- tests/quality-contracts.json
        & git -C $root -c user.name=Test -c user.email=test@example.invalid commit --allow-empty -qm baseline
        $base = (& git -C $root rev-parse HEAD).Trim()
        $path = '.agents/skills/1c-workflow/scripts/lib/agent-1c.lifecycle.ps1'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent (Join-Path $root $destination)) | Out-Null
        & git -C $root mv -- $path $destination
        if ($edit) { [IO.File]::AppendAllText((Join-Path $root $destination),"`nWrite-Verbose 'changed during rename'`n",[Text.UTF8Encoding]::new($false)) }
        & git -C $root add -- $destination
        & git -C $root -c user.name=Test -c user.email=test@example.invalid commit -qm rename
        $LASTEXITCODE | Should -Be 0
        $run = Invoke-TestPowerShellFile -FilePath (Join-Path $RepoRoot 'scripts/resolve-targeted-tests.ps1') -Arguments @('-RepositoryRoot',$root,'-BaseRef',$base)
        if (-not $known) {
            $run.exitCode | Should -Not -Be 0
            $run.combinedText | Should -Match 'without a quality owner'
            $catalog = Get-QualityContractCatalog -RepositoryRoot $RepoRoot
            @((Resolve-QualityContractsForPaths -Catalog $catalog -Paths @($destination)).unknownPaths) | Should -Be @($destination)
            return
        }
        $run.exitCode | Should -Be 0 -Because $run.combinedText
        $selection = ($run.stdout -join "`n") | ConvertFrom-Json
        $catalog = Get-QualityContractCatalog -RepositoryRoot $RepoRoot
        $expected = Resolve-QualityContractsForPaths -Catalog $catalog -Paths @($path,$destination)
        @($selection.tests) | Should -Be @($expected.tests)
        @($selection.tests) | Should -Contain 'tests/pester/DevelopConfigurationRejection.Tests.ps1'
        @($selection.tests) | Should -Contain 'tests/pester/WorkflowUpdateRollback.Tests.ps1'
        @($selection.additionalInputs) | Should -Contain $destination
    }

    It 'narrows only declared check functions while retaining the complete fallback for <module>' -TestCases @(
        @{ module='lifecycle'; functionName='Invoke-DevBranchCheck' },
        @{ module='vanessa'; functionName='Assert-VanessaVerificationPreflight' },
        @{ module='verification-modes'; functionName='Get-ItlVanessaVerificationSelectionPlan' }
    ) {
        param($module, $functionName)
        . (Join-Path $RepoRoot 'scripts/quality-contracts.ps1')
        $catalog = Get-QualityContractCatalog -RepositoryRoot $RepoRoot
        $path = '.agents/skills/1c-workflow/scripts/lib/agent-1c.'+$module+'.ps1'
        $text = [IO.File]::ReadAllText((Join-Path $RepoRoot $path))
        $signature = 'function '+$functionName+' {'
        $changed = $text.Replace($signature, $signature+"`n    # local control-flow edit")
        $changed | Should -Not -Be $text
        $model = Get-Agent1cSemanticModel -Text $text -Library
        $calls = Get-QualityFunctionInvocationInventory -Model $model -Name $functionName
        $live = Resolve-Agent1cSemanticImpact -Catalog $catalog -LibraryPath $path -BaselineText $text -CurrentText $changed
        $pin = $catalog.semanticTargeting.libraries.PSObject.Properties[$path].Value.functions.PSObject.Properties[$functionName].Value.callsSha256
        if ($calls -cne $pin) {
            $live.fallback | Should -BeTrue
            @($live.tests) | Should -Be @((Resolve-QualityContractsForPaths -Catalog $catalog -Paths @($path)).tests)
        } else { $live.fallback | Should -BeFalse }
        # Positive narrowing uses an explicitly reviewed fixture pin. Drift in
        # the live catalog must select the broad owner, not fail this self-test.
        $catalog = $catalog | ConvertTo-Json -Depth 30 | ConvertFrom-Json
        $catalog.semanticTargeting.libraries.PSObject.Properties[$path].Value.functions.PSObject.Properties[$functionName].Value.callsSha256 = $calls
        $impact = Resolve-Agent1cSemanticImpact -Catalog $catalog -LibraryPath $path -BaselineText $text -CurrentText $changed
        $impact.fallback | Should -BeFalse
        @($impact.impacts.name) | Should -Be @($functionName)
        $expected = @($catalog.semanticTargeting.libraries.PSObject.Properties[$path].Value.functions.PSObject.Properties[$functionName].Value.tests | Sort-Object)
        @($impact.tests) | Should -Be $expected
        $full = @( (Resolve-QualityContractsForPaths -Catalog $catalog -Paths @($path)).tests )
        $impact.tests.Count | Should -BeLessThan $full.Count
        @($impact.tests) | Should -Not -Contain 'tests/pester/WorkflowUpdateRollback.Tests.ps1'
        foreach ($mutation in @(
            $text.Replace($signature,$signature+"`n    New-UnknownDependency"),
            $text.Replace($signature,$signature+"`n    & `$script:DynamicDependency"),
            $text.Replace($signature,$signature+"`n    [NewOwner]::Run()"),
            $text.Replace($signature,$signature+"`n    function global:New-Owner {}"),
            ($changed+"`n'new startup behavior'"),
            ("param([string]`$Shared = 'new')`n"+$changed),
            $text.Replace($signature,'function Renamed-Owner {'),
            ($text+"`nfunction New-Owner {}"),
            ($text+"`n{"),
            ("begin {`n"+$text+"`n}"),
            ("process {`n"+$text+"`n}"),
            '',
            $null
        )) {
            $fallback = Resolve-Agent1cSemanticImpact -Catalog $catalog -LibraryPath $path -BaselineText $text -CurrentText $mutation
            $fallback.fallback | Should -BeTrue
            @($fallback.tests) | Should -Be $full
        }
        $fallback = Resolve-Agent1cSemanticImpact -Catalog $catalog -LibraryPath $path -BaselineText $null -CurrentText $changed
        $fallback.reason | Should -Be 'missing-baseline'
        @($fallback.tests) | Should -Be $full
        $emptyBaseline = Resolve-Agent1cSemanticImpact -Catalog $catalog -LibraryPath $path -BaselineText '' -CurrentText $changed
        $emptyBaseline.fallback | Should -BeTrue
        @($emptyBaseline.tests) | Should -Be $full
        # A dependency first admitted by the broad gate must not silently gain
        # narrow ownership on the next edit without a reviewed catalog update.
        $expandedBaseline = $text.Replace($signature,$signature+"`n    New-UnknownDependency")
        $expandedCurrent = $expandedBaseline.Replace($signature,$signature+"`n    # next local edit")
        $unreviewed = Resolve-Agent1cSemanticImpact -Catalog $catalog -LibraryPath $path -BaselineText $expandedBaseline -CurrentText $expandedCurrent
        $unreviewed.fallback | Should -BeTrue
        @($unreviewed.tests) | Should -Be $full
        $unknownName = @( (Get-Agent1cSemanticModel -Text $text -Library).functions.Keys | Where-Object { $_ -ne $functionName } | Sort-Object )[0]
        $mixed = $changed.Replace(('function '+$unknownName+' {'),('function '+$unknownName+" {`n    # unknown owner"))
        $mixed | Should -Not -Be $changed
        @((Resolve-Agent1cSemanticImpact -Catalog $catalog -LibraryPath $path -BaselineText $text -CurrentText $mixed).tests) | Should -Be $full
    }

    It 'carries library ownership and fallback through the real BaseRef selector and kills a skipped preflight' {
        $root = Join-Path $TestDrive 'check owner путь с пробелом'
        & git clone --quiet --shared --no-hardlinks -- $RepoRoot $root
        $LASTEXITCODE | Should -Be 0
        foreach ($path in @('scripts/quality-contracts.ps1','scripts/resolve-targeted-tests.ps1','tests/quality-contracts.json','tests/pester/DevBranchCheck.Tests.ps1')) {
            Copy-Item -LiteralPath (Join-Path $RepoRoot $path) -Destination (Join-Path $root $path) -Force
        }
        . (Join-Path $RepoRoot 'scripts/quality-contracts.ps1')
        # This fixture proves the skipped-preflight mutant at a known baseline;
        # live pins are independently checked by the safe-fallback case above.
        $fixtureCatalogPath = Join-Path $root 'tests/quality-contracts.json'
        $fixtureCatalog = Get-QualityContractCatalog -RepositoryRoot $root
        $fixturePath = '.agents/skills/1c-workflow/scripts/lib/agent-1c.lifecycle.ps1'
        $fixtureModel = Get-Agent1cSemanticModel -Text ([IO.File]::ReadAllText((Join-Path $root $fixturePath))) -Library
        $fixtureCatalog.semanticTargeting.libraries.PSObject.Properties[$fixturePath].Value.functions.'Invoke-DevBranchCheck'.callsSha256 = Get-QualityFunctionInvocationInventory -Model $fixtureModel -Name 'Invoke-DevBranchCheck'
        [IO.File]::WriteAllText($fixtureCatalogPath,($fixtureCatalog | ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false))
        & git -C $root -c user.name=Test -c user.email=test@example.invalid add --all
        # A committed candidate already contains these exact files. Keep one
        # baseline commit in both the dirty-source and committed-source fixture.
        & git -C $root -c user.name=Test -c user.email=test@example.invalid commit --allow-empty -qm ownership
        $LASTEXITCODE | Should -Be 0
        $base = (& git -C $root rev-parse HEAD).Trim()
        $resolver = Join-Path $RepoRoot 'scripts/resolve-targeted-tests.ps1'
        $path = '.agents/skills/1c-workflow/scripts/lib/agent-1c.lifecycle.ps1'
        $file = Join-Path $root $path
        $text = [IO.File]::ReadAllText($file)
        $changed = $text.Replace('function Invoke-DevBranchCheck {',"function Invoke-DevBranchCheck {`n    # owned edit")
        [IO.File]::WriteAllText($file,$changed,[Text.UTF8Encoding]::new($true))
        $run = Invoke-TestPowerShellFile -FilePath $resolver -Arguments @('-RepositoryRoot',$root,'-BaseRef',$base,'-ChangedPath',$path)
        $run.exitCode | Should -Be 0 -Because $run.combinedText
        $selection = ($run.stdout -join "`n") | ConvertFrom-Json
        $entrypoint = '.agents/skills/1c-workflow/scripts/agent-1c.ps1'
        @($selection.additionalInputs) | Should -Be @($entrypoint,$path | Sort-Object)
        @($selection.semanticImpacts.name) | Should -Be @('Invoke-DevBranchCheck')
        @($selection.tests) | Should -Not -Contain 'tests/pester/WorkflowUpdateRollback.Tests.ps1'
        @($selection.tests) | Should -Contain 'tests/pester/DevBranchCheck.Tests.ps1'

        $ordinaryPlan = Join-Path $root 'build/ordinary-selection.json'
        $ordinary = Invoke-TestPowerShellFile -FilePath $resolver -Arguments @('-RepositoryRoot',$root,'-BaseRef',$base,'-ChangedPath','tests/pester/DevBranchCheck.Tests.ps1','-OutputPath',$ordinaryPlan)
        $ordinary.exitCode | Should -Be 0 -Because $ordinary.combinedText
        $ordinarySelection = Get-Content $ordinaryPlan -Raw -Encoding UTF8 | ConvertFrom-Json
        @($ordinarySelection.semanticImpacts).Count | Should -Be 0
        $accepted = Invoke-TestPowerShellFile -FilePath (Join-Path $RepoRoot 'scripts/invoke-pester-shards.ps1') -Arguments @('-RepositoryRoot',$root,'-OutputRoot',(Join-Path $root 'build/ordinary'),'-JunitPath',(Join-Path $root 'build/ordinary.xml'),'-SelectionPath',$ordinaryPlan,'-InputIdentityOnly')
        $accepted.exitCode | Should -Be 0 -Because $accepted.combinedText
        $catalogPath = Join-Path $root 'tests/quality-contracts.json'
        $catalogText = [IO.File]::ReadAllText($catalogPath)
        try {
            $emptyCatalog = $catalogText | ConvertFrom-Json
            $emptyCatalog.semanticTargeting.libraries = [pscustomobject]@{}
            $emptyCatalog | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $catalogPath -Encoding UTF8
            $ordinary = Invoke-TestPowerShellFile -FilePath $resolver -Arguments @('-RepositoryRoot',$root,'-BaseRef',$base,'-ChangedPath','tests/pester/DevBranchCheck.Tests.ps1','-OutputPath',$ordinaryPlan)
            $ordinary.exitCode | Should -Be 0 -Because $ordinary.combinedText
            $accepted = Invoke-TestPowerShellFile -FilePath (Join-Path $RepoRoot 'scripts/invoke-pester-shards.ps1') -Arguments @('-RepositoryRoot',$root,'-OutputRoot',(Join-Path $root 'build/empty-libraries'),'-JunitPath',(Join-Path $root 'build/empty-libraries.xml'),'-SelectionPath',$ordinaryPlan,'-InputIdentityOnly')
            $accepted.exitCode | Should -Be 0 -Because $accepted.combinedText
        } finally { [IO.File]::WriteAllText($catalogPath,$catalogText,[Text.UTF8Encoding]::new($false)) }

        $invalidPlan = Join-Path $root 'build/missing-library-input.json'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $invalidPlan) | Out-Null
        $selection.additionalInputs = @($entrypoint)
        $selection | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $invalidPlan -Encoding UTF8
        $rejected = Invoke-TestPowerShellFile -FilePath (Join-Path $RepoRoot 'scripts/invoke-pester-shards.ps1') -Arguments @('-RepositoryRoot',$root,'-OutputRoot',(Join-Path $root 'build/rejected'),'-JunitPath',(Join-Path $root 'build/rejected.xml'),'-SelectionPath',$invalidPlan,'-InputIdentityOnly')
        $rejected.exitCode | Should -Not -Be 0
        $rejected.combinedText | Should -Match 'complete library in additionalInputs'

        # Keep the callee inventory unchanged: this mutation must be detected by
        # behavior tests, rather than escaping to the broad fallback.
        $ast = [Management.Automation.Language.Parser]::ParseInput($text,[ref]$null,[ref]$null)
        $definition = $ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-DevBranchCheck'},$true)
        $body = $definition.Extent.Text
        $mutant = $body.Replace('Assert-VanessaVerificationPreflight -Trigger','if ($false) { Assert-VanessaVerificationPreflight -Trigger')
        $line = @($mutant -split "`n" | Where-Object { $_ -match 'if \(\$false\) \{ Assert-VanessaVerificationPreflight' })
        $line.Count | Should -Be 1
        $mutant = $mutant.Replace($line[0],$line[0]+' }')
        [IO.File]::WriteAllText($file,$text.Replace($body,$mutant),[Text.UTF8Encoding]::new($true))
        $plan = Join-Path $root 'build/check-selection.json'
        $run = Invoke-TestPowerShellFile -FilePath $resolver -Arguments @('-RepositoryRoot',$root,'-BaseRef',$base,'-ChangedPath',$path,'-OutputPath',$plan)
        $run.exitCode | Should -Be 0 -Because $run.combinedText
        $selection = Get-Content $plan -Raw -Encoding UTF8 | ConvertFrom-Json
        @($selection.semanticImpacts.name) | Should -Be @('Invoke-DevBranchCheck')
        $output = Join-Path $root 'build/mutant-proof'
        $proof = Invoke-TestPowerShellFile -FilePath (Join-Path $RepoRoot 'scripts/invoke-pester-shards.ps1') -Arguments @('-RepositoryRoot',$root,'-OutputRoot',$output,'-JunitPath',(Join-Path $output 'pester.xml'),'-WorkerCount','3','-SelectionPath',$plan)
        $proof.exitCode | Should -Not -Be 0
        Test-Path -LiteralPath (Join-Path $output 'pester.xml') | Should -BeTrue -Because $proof.combinedText
        [xml]$junit = Get-Content (Join-Path $output 'pester.xml') -Raw -Encoding UTF8
        @($junit.SelectNodes('//testcase[failure]') | Where-Object { $_.name -match 'rejects a selected missing profile through the public check' }).Count | Should -Be 1

        [IO.File]::WriteAllText($file,$text,[Text.UTF8Encoding]::new($true))
        $renamed = $path.Replace('.lifecycle.','.перенесённый модуль.')
        & git -C $root mv -- $path $renamed
        & git -C $root -c user.name=Test -c user.email=test@example.invalid commit -qm rename
        $run = Invoke-TestPowerShellFile -FilePath $resolver -Arguments @('-RepositoryRoot',$root,'-BaseRef',$base)
        $run.exitCode | Should -Be 0 -Because $run.combinedText
        $selection = ($run.stdout -join "`n") | ConvertFrom-Json
        @($selection.additionalInputs) | Should -Be @($entrypoint,$renamed | Sort-Object)
        @($selection.tests) | Should -Contain 'tests/pester/WorkflowUpdateRollback.Tests.ps1'
        @($selection.semanticImpacts.kind) | Should -Be @('fallback')
        & git -C $root rm -- $entrypoint
        & git -C $root -c user.name=Test -c user.email=test@example.invalid commit -qm missing-entrypoint
        $run = Invoke-TestPowerShellFile -FilePath $resolver -Arguments @('-RepositoryRoot',$root,'-BaseRef',$base)
        $run.exitCode | Should -Be 0 -Because $run.combinedText
        $selection = ($run.stdout -join "`n") | ConvertFrom-Json
        @($selection.semanticImpacts.name) | Should -Contain 'missing-current-entrypoint'
        @($selection.tests) | Should -Contain 'tests/pester/WorkflowUpdateRollback.Tests.ps1'
    }

    It "invalidates every extracted lifecycle shard when their shared fixture changes" {
        . (Join-Path $RepoRoot "scripts/quality-contracts.ps1")
        $catalog = Get-QualityContractCatalog -RepositoryRoot $RepoRoot
        $expected = @('DevBranchLifecycle','DevBranchCheck','DevBranchWorktrees','DevBranchForkContinuation','DevBranchMergeRecovery' | ForEach-Object { 'tests/pester/'+$_+'.Tests.ps1' } | Sort-Object)
        $selection = Resolve-QualityContractsForPaths -Catalog $catalog -Paths @('tests/pester/DevBranchLifecycleSupport.ps1')
        @($selection.unknownPaths).Count | Should -Be 0
        @($selection.tests) | Should -Be $expected
        foreach ($path in @('.agents/skills/1c-workflow/scripts/lib/agent-1c.lifecycle.ps1','.agents/skills/1c-workflow/scripts/lib/agent-1c.core.ps1')) {
            $production = Resolve-QualityContractsForPaths -Catalog $catalog -Paths @($path)
            foreach ($test in $expected) { @($production.tests) | Should -Contain $test }
        }
    }

        It "preserves implicit worker provenance through the focused test wrapper" {
        $outputRoot = Join-Path $TestDrive "implicit focused wrapper"
        $resultPath = Join-Path $outputRoot "parser-docs.xml"
        $run = Invoke-TestPowerShellFile -FilePath (Join-Path $RepoRoot "scripts\test.ps1") -Arguments @("-Path", "tests/pester/ParserDocsBudgets.Tests.ps1", "-OutputFile", $resultPath)
        $run.exitCode | Should -Be 0 -Because $run.combinedText
        $summary = Get-Content -LiteralPath (Join-Path $outputRoot "pester-shards\summary.json") -Raw -Encoding UTF8 | ConvertFrom-Json
        $summary.pesterWorkers.requested | Should -Be 3
        $summary.pesterWorkers.explicit | Should -BeFalse
        $summary.pesterWorkers.effective | Should -Be 3
    }

    It "routes only exact named entrypoint AST changes and falls back for shared or unknown impact" {
        . (Join-Path $RepoRoot "scripts\quality-contracts.ps1")
        $catalog = Get-QualityContractCatalog -RepositoryRoot $RepoRoot
        $entrypoint = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\agent-1c.ps1") -Raw -Encoding UTF8

        $oneAction = $entrypoint.Replace('"update-auxiliary-contour" { Update-AuxiliaryContour }', '"update-auxiliary-contour" { Update-AuxiliaryContour | Out-Null }')
        $oneAction | Should -Not -Be $entrypoint
        $oneActionImpact = Resolve-Agent1cSemanticImpact -Catalog $catalog -CurrentText $oneAction -BaselineText $entrypoint
        $oneActionImpact.fallback | Should -BeFalse
        @($oneActionImpact.tests) | Should -Be @("tests/pester/Agent1cEntrypoint.Tests.ps1", "tests/pester/AuxiliaryContours.Tests.ps1")

        # Registry dispatch may grow additional branches; mutate the same status
        # leaf instead of assuming an obsolete spelling of the whole action.
        $statusAst = [Management.Automation.Language.Parser]::ParseInput($oneAction, [ref]$null, [ref]$null)
        $statusCommands = @($statusAst.FindAll({ param($node)
            $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Show-Vibecoding1cMcpStatus'
        }, $true))
        $statusCommands.Count | Should -Be 1
        $statusSpan = $statusCommands[0].Extent
        $twoActions = $oneAction.Remove($statusSpan.StartOffset, $statusSpan.EndOffset - $statusSpan.StartOffset).
            Insert($statusSpan.StartOffset, ($statusSpan.Text + ' | Out-Null'))
        $twoActions | Should -Not -Be $oneAction
        $actionImpact = Resolve-Agent1cSemanticImpact -Catalog $catalog -CurrentText $twoActions -BaselineText $entrypoint
        $actionImpact.fallback | Should -BeFalse
        @($actionImpact.impacts.name) | Should -Be @("update-auxiliary-contour", "vibecoding1c-mcp-status")
        @($actionImpact.tests) | Should -Be @("tests/pester/Agent1cEntrypoint.Tests.ps1", "tests/pester/AuxiliaryContours.Tests.ps1", "tests/pester/McpConfig.Tests.ps1", "tests/pester/OnDemandMcp.Tests.ps1")
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
        $unknownPath = 'неизвестно/Путь с пробелом.ps1'
        $rejected = Invoke-TestPowerShellFile -FilePath $resolver -Arguments @('-RepositoryRoot',$RepoRoot,'-ChangedPath',$unknownPath)
        $rejected.exitCode | Should -Not -Be 0
        $rejected.combinedText.Contains($unknownPath) | Should -BeTrue -Because 'the UTF-8 child boundary must retain the exact whitespace-and-Cyrillic path in its diagnostic'
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
                pesterWorkers=[ordered]@{targetedImplicitDefault=4}
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
                "tests\pester\DevBranchCheck.Tests.ps1",
                "scripts\develop-configuration-rejection.ps1",
                "tests\quality-contracts.json",
                "tests\pester\DevelopConfigurationRejection.Tests.ps1",
                "tests\pester\TestSupport.ps1",
                "tests\pester\Agent1cEntrypoint.Tests.ps1",
                "tests\pester\AuxiliaryContours.Tests.ps1",
                "tests\pester\ExecutionGuardCutover.Tests.ps1",
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
            @($selection.tests) | Should -Be @('tests/pester/Agent1cEntrypoint.Tests.ps1', 'tests/pester/AuxiliaryContours.Tests.ps1')
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
}
