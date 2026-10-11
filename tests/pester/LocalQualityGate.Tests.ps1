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

    It "preserves exact Unicode stdout and stderr from a redirected Windows PowerShell Pester shard" {
        $fixtureRoot = Join-Path $TestDrive "Путь с пробелом"
        New-Item -ItemType Directory -Force -Path $fixtureRoot | Out-Null
        $testPath = Join-Path $fixtureRoot "UnicodeOutput.Tests.ps1"
        $planPath = Join-Path $fixtureRoot "worker.plan.json"
        $junitPath = Join-Path $fixtureRoot "worker.xml"
        $resultPath = Join-Path $fixtureRoot "worker.result.json"
        $stdoutMarker = "Стандартный вывод: Путь с пробелом"
        $stderrMarker = "Стандартная ошибка: Путь с пробелом"
        $fixture = @"
BeforeAll {
    [Console]::Out.WriteLine('$stdoutMarker')
    [Console]::Error.WriteLine('$stderrMarker')
}
Describe 'Unicode redirected output' {
    It 'passes' { `$true | Should -BeTrue }
}
"@
        [IO.File]::WriteAllText($testPath, $fixture, [Text.UTF8Encoding]::new($true))
        $plan = [ordered]@{ schemaVersion = 1; worker = 1; paths = @($testPath) }
        [IO.File]::WriteAllText($planPath, (($plan | ConvertTo-Json -Depth 4) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))

        $run = Invoke-TestPowerShellFile -FilePath (Join-Path $RepoRoot "scripts\run-pester-shard.ps1") -Arguments @(
            "-PlanPath", $planPath,
            "-JunitPath", $junitPath,
            "-ResultPath", $resultPath
        )

        $run.exitCode | Should -Be 0 -Because $run.combinedText
        ($run.stdout -join [Environment]::NewLine) | Should -Match ([regex]::Escape($stdoutMarker))
        ($run.stderr -join [Environment]::NewLine) | Should -Match ([regex]::Escape($stderrMarker))
        (Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json).status | Should -Be "passed"
    }

    It "preserves exact UTF-8 when the shared gate child reports a real failed Pester shard" {
        $fixtureRoot = Join-Path $TestDrive 'Путь с пробелом ОшибкаШарда'
        $testRoot = Join-Path $fixtureRoot 'tests/pester'
        $outputRoot = Join-Path $fixtureRoot 'out'
        New-Item -ItemType Directory -Force -Path $testRoot, $outputRoot | Out-Null
        $marker = 'Намеренная ошибка: Путь с пробелом'
        $testPath = Join-Path $testRoot 'UnicodeFailure.Tests.ps1'
        $fixture = @"
BeforeAll {
    [Console]::Out.WriteLine('$marker')
    [Console]::Error.WriteLine('$marker')
}
Describe 'real failing shard' {
    It 'retains the deliberate failure' { throw '$marker' }
}
"@
        [IO.File]::WriteAllText($testPath, $fixture, [Text.UTF8Encoding]::new($true))
        $catalog = [ordered]@{
            schemaVersion = 1; pesterNonReusableTests = @('tests/pester/UnicodeFailure.Tests.ps1')
            contracts = @([ordered]@{ id = 'unicode-failure'; owner = 'fixture'; primaryTest = 'tests/pester/UnicodeFailure.Tests.ps1'; gate = 'targeted'; budgetSeconds = 30; paths = @('fixture/*'); tests = @('tests/pester/UnicodeFailure.Tests.ps1') })
        }
        [IO.File]::WriteAllText((Join-Path $fixtureRoot 'tests/quality-contracts.json'), ($catalog | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $fixtureRoot 'selection.json'), '{"tests":["tests/pester/UnicodeFailure.Tests.ps1"]}', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $fixtureRoot '.gitignore'), "out/`nprobe.ps1`n", [Text.UTF8Encoding]::new($false))
        & git -C $fixtureRoot init *> $null
        & git -C $fixtureRoot config user.name 'ITL Test'
        & git -C $fixtureRoot config user.email 'itl-test@example.invalid'
        & git -C $fixtureRoot add --all
        & git -C $fixtureRoot commit -m fixture *> $null
        $LASTEXITCODE | Should -Be 0

        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'scripts/check.ps1'), [ref]$tokens, [ref]$errors)
        @($errors) | Should -BeNullOrEmpty
        $definitions = foreach ($name in @('ConvertTo-NativeArgument', 'Start-PowerShellChildProcess', 'Stop-GateChildProcessTree', 'Wait-PowerShellChildProcess')) {
            $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name }, $false)
            $definition | Should -Not -BeNullOrEmpty
            $definition.Extent.Text
        }
        $probePath = Join-Path $fixtureRoot 'probe.ps1'
        $probe = @'
param([string]$SourceRoot, [string]$FixtureRoot)
$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $utf8; [Console]::OutputEncoding = $utf8; $OutputEncoding = $utf8
'@ + [Environment]::NewLine + ($definitions -join [Environment]::NewLine) + [Environment]::NewLine + @'
$repoRoot = $FixtureRoot
$outputRoot = Join-Path $FixtureRoot 'out'
$modeHardBudgetSeconds = 90
$overallStopwatch = [Diagnostics.Stopwatch]::StartNew()
$child = Start-PowerShellChildProcess -ScriptPath (Join-Path $SourceRoot 'scripts/invoke-pester-shards.ps1') -Arguments @('-RepositoryRoot', $FixtureRoot, '-OutputRoot', $outputRoot, '-JunitPath', (Join-Path $outputRoot 'pester.xml'), '-WorkerCount', '1', '-SelectionPath', (Join-Path $FixtureRoot 'selection.json')) -LogName 'pester-selection-shards'
$failure = ''
try { Wait-PowerShellChildProcess -Child $child -TimeoutSeconds 90 -NoProgressSeconds 60 }
catch { $failure = $_.Exception.Message }
$receipt = [ordered]@{ exitCode = [int]$child.process.ExitCode; failure = $failure }
[IO.File]::WriteAllText((Join-Path $outputRoot 'child-receipt.json'), ($receipt | ConvertTo-Json), $utf8)
exit $child.process.ExitCode
'@
        [IO.File]::WriteAllText($probePath, $probe, [Text.UTF8Encoding]::new($true))
        $run = Invoke-TestPowerShellFile -FilePath $probePath -Arguments @('-SourceRoot', $RepoRoot, '-FixtureRoot', $fixtureRoot)
        $run.exitCode | Should -Be 1 -Because $run.combinedText
        $childReceipt = Get-Content -LiteralPath (Join-Path $outputRoot 'child-receipt.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $childReceipt.exitCode | Should -Be 1
        $childReceipt.failure | Should -Match 'pester-selection-shards failed with exit code 1'
        $summary = Get-Content -LiteralPath (Join-Path $outputRoot 'pester-shards/summary.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $summary.status | Should -Be 'failed'
        $summary.executedWorkerCount | Should -Be 1
        $summary.reusedWorkerCount | Should -Be 0
        $worker = Get-Content -LiteralPath (Join-Path $outputRoot 'pester-shards/worker-1.result.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $worker.status | Should -Be 'failed'
        $worker.failed | Should -Be 1
        @($worker.paths) | Should -Be @($testPath)
        $strictUtf8 = [Text.UTF8Encoding]::new($false, $true)
        foreach ($stream in @('stdout', 'stderr')) {
            $workerText = $strictUtf8.GetString([IO.File]::ReadAllBytes((Join-Path $outputRoot "pester-shards/worker-1.$stream.log")))
            $workerText | Should -Match ([regex]::Escape($marker))
            $gateText = $strictUtf8.GetString([IO.File]::ReadAllBytes((Join-Path $outputRoot "pester-selection-shards.$stream.log")))
            if ($stream -eq 'stderr') {
                $gateText | Should -Match 'Pester shards failed:'
                $gateText | Should -Match 'worker 1 reported failed:'
                $gateText | Should -Match 'ОшибкаШарда'
                $gateText | Should -Match 'worker-1\.stderr\.log'
            }
        }
    }

    It "preserves exact UTF-8 for the successful over-target gate warning through the delivery child" {
        $fixtureRoot = Join-Path $TestDrive 'Путь с пробелом ПредупреждениеПроверки'
        $outputRoot = Join-Path $fixtureRoot 'out'
        New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
        $summaryPath = Join-Path $outputRoot 'check-summary.json'
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'scripts/check.ps1'), [ref]$tokens, [ref]$errors)
        @($errors) | Should -BeNullOrEmpty
        $firstFunction = $ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] } | Select-Object -First 1
        $warning = @($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.IfStatementAst] -and $_.Extent.Text.StartsWith('if ($budgetStatus -eq "over-target")') })
        $warning.Count | Should -Be 1
        $passedMessage = @($ast.EndBlock.Statements | Where-Object { $_.Extent.Text.StartsWith('Write-Host "ITL $Mode gate passed.') })
        $passedMessage.Count | Should -Be 1
        $gatePath = Join-Path $fixtureRoot 'actual-check-warning.ps1'
        # Execute the original startup and successful over-target emitter; no slow gate or elapsed-time substitute.
        $gate = $ast.Extent.Text.Substring(0, $firstFunction.Extent.StartOffset) + @'
$modeTargetBudgetSeconds = 300
$budgetStatus = 'over-target'
$summaryPath = $OutputDirectory
'@ + [Environment]::NewLine + $warning[0].Extent.Text + [Environment]::NewLine + $passedMessage[0].Extent.Text
        [IO.File]::WriteAllText($gatePath, $gate, [Text.UTF8Encoding]::new($true))
        $quoteDefinition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'ConvertTo-NativeArgument' }, $false)
        $deliveryAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'scripts/source-delivery-process.ps1'), [ref]$tokens, [ref]$errors)
        @($errors) | Should -BeNullOrEmpty
        $definitions = foreach ($name in @('Test-DeliveryProcessCreationIdentity', 'Get-DeliveryDescendantProcessIdentities', 'Stop-DeliveryProcessTree', 'Start-DeliveryProcess', 'Close-DeliveryProcessJob')) {
            $definition = $deliveryAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name }, $false)
            $definition | Should -Not -BeNullOrEmpty
            $definition.Extent.Text
        }
        $probePath = Join-Path $fixtureRoot 'probe.ps1'
        $probe = @'
param([string]$GatePath, [string]$FixtureRoot, [string]$SummaryPath)
$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $utf8; [Console]::OutputEncoding = $utf8; $OutputEncoding = $utf8
'@ + [Environment]::NewLine + $quoteDefinition.Extent.Text + [Environment]::NewLine + ($definitions -join [Environment]::NewLine) + [Environment]::NewLine + @'
$outputRoot = Join-Path $FixtureRoot 'out'
$arguments = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (ConvertTo-NativeArgument $GatePath), '-Mode', 'Targeted', '-OutputDirectory', (ConvertTo-NativeArgument $SummaryPath))
$child = Start-DeliveryProcess -ArgumentList ($arguments -join ' ') -WorkingDirectory $FixtureRoot -StandardOutputPath (Join-Path $outputRoot 'gate-targeted.stdout.log') -StandardErrorPath (Join-Path $outputRoot 'gate-targeted.stderr.log')
try {
    if (-not $child.process.WaitForExit(30000)) { throw 'Warning fixture child exceeded 30 seconds' }
    $child.process.WaitForExit(); $child.process.Refresh()
    $exitCode = [int]$child.process.ExitCode
} finally { Close-DeliveryProcessJob -JobHandle $child.jobHandle -Process $child.process }
[IO.File]::WriteAllText((Join-Path $outputRoot 'child-receipt.json'), (@{ exitCode = $exitCode; summaryPath = $SummaryPath } | ConvertTo-Json), $utf8)
exit $exitCode
'@
        [IO.File]::WriteAllText($probePath, $probe, [Text.UTF8Encoding]::new($true))
        $run = Invoke-TestPowerShellFile -FilePath $probePath -Arguments @('-GatePath', $gatePath, '-FixtureRoot', $fixtureRoot, '-SummaryPath', $summaryPath)
        $run.exitCode | Should -Be 0 -Because $run.combinedText
        $childReceipt = Get-Content -LiteralPath (Join-Path $outputRoot 'child-receipt.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $childReceipt.exitCode | Should -Be 0
        $childReceipt.summaryPath | Should -BeExactly $summaryPath
        $warningUtf8 = [Text.UTF8Encoding]::new($false, $true)
        $gateText = $warningUtf8.GetString([IO.File]::ReadAllBytes((Join-Path $outputRoot 'gate-targeted.stdout.log')))
        $warningUtf8.GetString([IO.File]::ReadAllBytes((Join-Path $outputRoot 'gate-targeted.stderr.log'))) | Should -BeNullOrEmpty
        $gateText | Should -Match '(?m)^\p{L}+: ITL Targeted passed but exceeded its target budget of 300 seconds\.'
        if ($PSUICulture -like 'ru*') { $gateText | Should -Match '(?m)^ПРЕДУПРЕЖДЕНИЕ: ITL Targeted passed' }
        $unwrappedText = $gateText.Replace("`r", '').Replace("`n", '')
        $unwrappedText | Should -Match ([regex]::Escape("Inspect slowestStages in $summaryPath."))
        $unwrappedText | Should -Match ([regex]::Escape("ITL Targeted gate passed. Summary: $summaryPath"))
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
        $oneActionImpact = Resolve-Agent1cSemanticImpact -Catalog $catalog -CurrentText $oneAction -BaselineText $entrypoint
        $oneActionImpact.fallback | Should -BeFalse
        @($oneActionImpact.tests) | Should -Be @("tests/pester/Agent1cEntrypoint.Tests.ps1", "tests/pester/AuxiliaryContours.Tests.ps1")

        $twoActions = $oneAction.
            Replace('"vibecoding1c-mcp-status" { Show-Vibecoding1cMcpStatus }', '"vibecoding1c-mcp-status" { Show-Vibecoding1cMcpStatus | Out-Null }')
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
        $hashOwnerPath = Join-Path $RepoRoot "scripts\invoke-pester-runtime.ps1"
        $runner = Get-Content -LiteralPath $runnerPath -Raw -Encoding UTF8
        $runner | Should -Not -Match '\bGet-FileHash\b'

        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($hashOwnerPath, [ref]$tokens, [ref]$errors)
        @($errors) | Should -BeNullOrEmpty
        $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Get-PesterShardFileSha256" }, $true)
        $definition | Should -Not -BeNullOrEmpty
        $ownerOffset = $runner.IndexOf('. (Join-Path $PSScriptRoot "invoke-pester-runtime.ps1")', [StringComparison]::Ordinal)
        $ownerOffset | Should -BeGreaterThan -1
        $ownerOffset | Should -BeLessThan $runner.IndexOf('function Initialize-VanessaSourceBuildArchiveForPester', [StringComparison]::Ordinal)
        $ownerOffset | Should -BeLessThan $runner.IndexOf('function Get-ShardInputDigest', [StringComparison]::Ordinal)

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
        $check | Should -Match 'qualificationMatch -and \$qualificationMatch\.canReusePester'
        $check | Should -Match 'Update-DevelopQualificationFullBinding -Commit \$commit -Tree \$tree -PreviousFullProof \$releaseFullProof'
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

    It "runs complete Pester as individually checkpointed files with bounded workers" {
        $runner = Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\invoke-pester-shards.ps1") -Raw -Encoding UTF8; $worker = Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\run-pester-shard.ps1") -Raw -Encoding UTF8
        $localRunner = Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\test.ps1") -Raw -Encoding UTF8
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
        $runner | Should -Match 'pesterExternalIdentityCache'; $runner | Should -Match 'pesterLegacyExternalIdentityCache'; $runner | Should -Match '\$configuredArchive'; $runner | Should -Match 'legacy scheduler or external identity normalized to exact owner inputs'
        $runner | Should -Match 'legacyInputDigests'; $runner | Should -Match 'legacyArchiveCandidates'
        $runner | Should -Match 'rev-list --max-count=8 HEAD'; $runner | Should -Match 'recentRootByHead'
        $runner | Should -Match 'hash-object --path \$RelativePath -- \$AbsolutePath'
        $runner | Should -Match 'ls-files", "-t", "-s", "-m", "-z"'
        $runner | Should -Match 'pesterTrackedIdentityCache'
        $runner | Should -Not -Match '& git -C \$RepositoryRoot diff --quiet'
        $runner | Should -Match 'fingerprintPlanMs'; $runner | Should -Match 'cacheLookupMs'; $runner | Should -Match 'workerSpanMs'
        $runner.IndexOf('$workerSpanStopwatch.Stop()') | Should -BeGreaterThan $runner.IndexOf('while (-not $stopScheduling -and $pendingSerial.Count -gt 0)')
        $runner | Should -Match '\$resetModulePathForWindowsPowerShell = \[string\]\$PSVersionTable\.PSEdition -eq "Core"'
        $runtimeOwner = Get-Content -LiteralPath (Join-Path $RepoRoot 'scripts/invoke-pester-runtime.ps1') -Raw -Encoding UTF8
        $runtimeOwner | Should -Match 'SpecialFolder\]::MyDocuments'
        $worker | Should -Match "\. \(Join-Path \`$PSScriptRoot 'invoke-pester-runtime\.ps1'\)"
        $worker.IndexOf('Initialize-PesterShardModulePath') | Should -BeGreaterThan -1
        $worker.IndexOf('Initialize-PesterShardModulePath') | Should -BeLessThan $worker.IndexOf('Import-Module Pester')
        $worker | Should -Match 'Invoke-Pester -Configuration'
        $worker | Should -Match '\$env:ITL_TEST_EXECUTION_GUARD_FALLBACK_ROOT\s*=\s*Join-Path \$fixtureRuntimeRoot "execution-guards-v2"'
        $localRunner | Should -Match '& powershell\.exe @runnerArguments'
        $localRunner | Should -Match 'itl-pester-local-'
        $localRunner | Should -Match 'SetEnvironmentVariable\("ITL_TEST_EXECUTION_GUARD_FALLBACK_ROOT", \$originalExecutionGuardFallbackRoot, "Process"\)'
    }
    It "preserves an explicit execution guard root while isolating the Pester worker fallback" {
        $root = Join-Path ([IO.Path]::GetTempPath()) ("itl gate isolation Тест " + [guid]::NewGuid().ToString("N"))
        $testRoot = Join-Path $root "tests\pester"
        $poisonRoot = Join-Path $root "Внешний execution guard"
        $planPath = Join-Path $root "plan.json"
        $junitPath = Join-Path $root "pester.xml"
        $resultPath = Join-Path $root "result.json"
        $testPath = Join-Path $testRoot "Isolation.Tests.ps1"
        $originalGuardRoot = [Environment]::GetEnvironmentVariable("ITL_EXECUTION_GUARD_ROOT", "Process")
        $originalPoisonRoot = [Environment]::GetEnvironmentVariable("ITL_TEST_POISON_GUARD_ROOT", "Process")
        try {
            New-Item -ItemType Directory -Force -Path $testRoot, $poisonRoot | Out-Null
            [IO.File]::WriteAllText((Join-Path $poisonRoot "sentinel.json"), '{"schemaVersion":2}', [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText($testPath, @'
Describe "Pester worker execution guard isolation" {
    It "uses a worker-private fallback without overriding an explicit root" {
        $env:ITL_EXECUTION_GUARD_ROOT | Should -Be $env:ITL_TEST_POISON_GUARD_ROOT
        $env:ITL_TEST_EXECUTION_GUARD_FALLBACK_ROOT | Should -Not -Be $env:ITL_TEST_POISON_GUARD_ROOT
        $env:ITL_TEST_EXECUTION_GUARD_FALLBACK_ROOT | Should -Match 'itl-pester-worker-\d+-[a-f0-9]+[\\/]execution-guards-v2$'
    }
}
'@, [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText($planPath, (([ordered]@{ worker=7; paths=@($testPath) } | ConvertTo-Json -Depth 4) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
            $poisonHash = (Get-FileHash -LiteralPath (Join-Path $poisonRoot "sentinel.json") -Algorithm SHA256).Hash
            [Environment]::SetEnvironmentVariable("ITL_EXECUTION_GUARD_ROOT", $poisonRoot, "Process")
            [Environment]::SetEnvironmentVariable("ITL_TEST_POISON_GUARD_ROOT", $poisonRoot, "Process")

            $result = Invoke-TestPowerShellFile -FilePath (Join-Path $RepoRoot "scripts\run-pester-shard.ps1") -Arguments @("-PlanPath", $planPath, "-JunitPath", $junitPath, "-ResultPath", $resultPath)

            $result.exitCode | Should -Be 0 -Because $result.combinedText
            (Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json).status | Should -Be "passed"
            (Get-FileHash -LiteralPath (Join-Path $poisonRoot "sentinel.json") -Algorithm SHA256).Hash | Should -Be $poisonHash
        } finally {
            [Environment]::SetEnvironmentVariable("ITL_EXECUTION_GUARD_ROOT", $originalGuardRoot, "Process")
            [Environment]::SetEnvironmentVariable("ITL_TEST_POISON_GUARD_ROOT", $originalPoisonRoot, "Process")
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
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
            $second.pesterWorkers.requested | Should -Be 1
            $second.pesterWorkers.explicit | Should -BeTrue
            $second.pesterWorkers.effective | Should -Be 1
            $out3 = Join-Path $root "out3"; $implicitRun = Invoke-TestPowerShellFile -FilePath $invoke -Arguments @("-RepositoryRoot", $root, "-OutputRoot", $out3, "-JunitPath", (Join-Path $out3 "pester.xml"), "-SelectionPath", $selectionPath); $implicitRun.exitCode | Should -Be 0 -Because ((@($implicitRun.stdout) + @($implicitRun.stderr)) -join [Environment]::NewLine); $implicit = ($implicitRun.stdout -join [Environment]::NewLine) | ConvertFrom-Json
            $implicit.pesterWorkers.requested | Should -Be 3
            $implicit.pesterWorkers.explicit | Should -BeFalse
            $implicit.pesterWorkers.effective | Should -Be 3
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


    It "keeps repository-only guidance alongside the managed skills without Git hooks" {
        Test-Path -LiteralPath (Join-Path $RepoRoot ".githooks") | Should -BeFalse
        $installedSkillIds = @("1c-workflow", "1c-workflow-fast", "itl-roctup-1c-data", "itl-vanessa-ui-mcp", "itl-performance", "itl-remote-runner", "itl-remote-agent", "product-docs")
        $sourcePlanningSkillIds = @(
            'grill-me', 'grill-with-docs', 'grilling', 'domain-modeling',
            'openspec-explore', 'openspec-propose', 'openspec-apply-change',
            'openspec-update-change', 'openspec-sync-specs', 'openspec-archive-change'
        )
        # BootstrapUpdate covers actual installed output and update copy boundaries.
        $expected = @($installedSkillIds + $sourcePlanningSkillIds | Sort-Object)
        $actual = @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot ".agents\skills") -Directory | Select-Object -ExpandProperty Name | Sort-Object)
        $actual | Should -Be $expected
        $docs = Get-Content -LiteralPath (Join-Path $RepoRoot "docs\local-quality-gate.md") -Raw -Encoding UTF8
        $docs | Should -Match "Git hooks"
        $docs | Should -Match "GitHub Actions"
        $docs | Should -Match "continuation\s+scope"
        $docs | Should -Match 'точный прошедший `Targeted`'
    }
}
