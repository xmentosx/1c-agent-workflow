BeforeAll {
    . (Join-Path $PSScriptRoot "TestSupport.ps1")
    $context = Initialize-WorkflowPesterContext
    $RepoRoot = $context.RepoRoot
}

Describe "Local quality gate contract" {

    It 'measures a parallel child at process exit instead of charging delayed collection as execution' {
        $tokens=$null;$errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot scripts/check.ps1),[ref]$tokens,[ref]$errors)
        @($errors)|Should -BeNullOrEmpty
        $definition=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Complete-ParallelGateStage'},$true)
        . ([scriptblock]::Create($definition.Extent.Text))
        function Wait-PowerShellChildProcess {}
        function Add-StageResult {param($Name,$Status,$Execution,$Reason,$Detail,$StartedAt,$DurationMs) $script:observedStageStatus=$Status}
        function Set-StageMetrics {param($Name,$Metrics) $script:observedProcessTiming=$Metrics}
        $start=[DateTime]::UtcNow.AddMinutes(-10)
        $child=[pscustomobject]@{startedAt=$start;process=[pscustomobject]@{StartTime=$start;ExitTime=$start.AddMinutes(1)}}
        Complete-ParallelGateStage -Name compatibility -Reason fixture -Child $child -TimeoutSeconds 600
        $script:observedStageStatus | Should -Be passed
        $script:observedProcessTiming.timingKind | Should -BeExactly process-exit
        $script:observedProcessTiming.processDurationMs | Should -Be 60000
        $script:observedProcessTiming.collectionDelayMs | Should -BeGreaterThan 500000
    }

    It 'admits concurrent stand stages by measured memory and leaves the rest to the sequential path' {
        $tokens=$null;$errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot scripts/check.ps1),[ref]$tokens,[ref]$errors)
        @($errors)|Should -BeNullOrEmpty
        foreach($name in @('Test-GateParallelStageAdmission','Start-DevelopJourneyPreruns','Update-GateMemoryTelemetry')) {
            . ([scriptblock]::Create($ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true).Extent.Text))
        }
        $script:parallelStageAvailableBytes=2GB;$script:parallelStageCommitBytes=4GB
        $host8=[pscustomobject]@{availableBytes=8GB;committedBytes=32GB;commitLimitBytes=63GB}
        Test-GateParallelStageAdmission -Running 0 -Snapshot $host8 | Should -BeTrue
        Test-GateParallelStageAdmission -Running 3 -Snapshot $host8 | Should -BeTrue
        Test-GateParallelStageAdmission -Running 4 -Snapshot $host8 | Should -BeFalse
        Test-GateParallelStageAdmission -Running 1 -Snapshot ([pscustomobject]@{availableBytes=16GB;committedBytes=54GB;commitLimitBytes=63GB}) | Should -BeFalse
        Test-GateParallelStageAdmission -Running 0 -Snapshot $null | Should -BeFalse

        $repoRoot=Join-Path $TestDrive 'Кандидат с пробелом';$tree='a'*40;$outputRoot=Join-Path $TestDrive 'out';$E2EProjectRoot='stand';$AgentTarget='kilocode'
        $FreshProjectsRoot=Join-Path $TestDrive 'fresh п';$qualityCatalog=[pscustomobject]@{};$script:developRulesSource='fork';$script:sourceE2EArtifactBinding=$null;$script:sourceE2EArtifactBindingPath='binding.json';$script:developScript='invoke-develop-e2e.ps1'
        function Get-DevelopE2EJourneyHardBudgetSeconds {param($Catalog,$Journey) if($Journey -eq 'upgrade'){7200}else{5400}}
        function Get-DevelopE2EInputIdentity {param($RepositoryRoot,$Journey,$Catalog,$ProjectRoot,$AiRulesSource,$AgentTarget,$ArtifactBinding,$FreshProjectsRoot) [pscustomobject]@{journey=$Journey}}
        function Get-DevelopScenarioReusePlan {param($RepositoryRoot,$Tree,$Journey,$InputIdentity,$Catalog,[switch]$AllowPendingStatic,$ProjectRoot)
            $script:pendingStaticPlanned+=,$AllowPendingStatic.IsPresent
            if($Journey -eq 'upgrade'){@([pscustomobject]@{id='update';execution='execute'},[pscustomobject]@{id='verification-export';execution='setup'},[pscustomobject]@{id='configuration-rejection';execution='reuse'})}
            else{@([pscustomobject]@{id='install';execution='execute'})}}
        function Start-PowerShellChildProcess {param($ScriptPath,$Arguments,$LogName) $script:startedChildren+=,[pscustomobject]@{log=$LogName;arguments=@($Arguments)}; [pscustomobject]@{logName=$LogName;startedAt=[DateTime]::UtcNow}}

        $script:startedChildren=@();$script:pendingStaticPlanned=@();$script:stagePreruns=[ordered]@{}
        function Get-GateMemorySnapshot {$host8}
        Start-DevelopJourneyPreruns -Journeys @('fresh','upgrade')
        @($script:startedChildren.log) | Should -Be @('develop-e2e-upgrade-prerun','develop-e2e-fresh-prerun')
        $upgrade=$script:startedChildren[0].arguments
        $upgrade[[array]::IndexOf($upgrade,'-Scenario')+1] | Should -BeExactly 'update,verification-export'
        $upgrade[[array]::IndexOf($upgrade,'-FreshProjectsRoot')+1] | Should -BeExactly $FreshProjectsRoot
        $upgrade | Should -Contain '-ArtifactBindingPath'
        @($script:pendingStaticPlanned) | Should -Be @($true,$true)
        @($script:stagePreruns.Values | ForEach-Object { $_.blocking }) | Should -Be @($true,$true)

        # Pressure after the first reservation defers only the shorter journey.
        $script:startedChildren=@();$script:stagePreruns=[ordered]@{}
        function Get-GateMemorySnapshot {[pscustomobject]@{availableBytes=3GB;committedBytes=32GB;commitLimitBytes=63GB}}
        Start-DevelopJourneyPreruns -Journeys @('fresh','upgrade')
        @($script:startedChildren.log) | Should -Be @('develop-e2e-upgrade-prerun')
        @($script:stagePreruns.Keys) | Should -Be @('develop-e2e-upgrade-prerun')
    }

    It 'collects every concurrent stage before failing and keeps a speculative failure non-blocking' {
        $tokens=$null;$errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot scripts/check.ps1),[ref]$tokens,[ref]$errors)
        @($errors)|Should -BeNullOrEmpty
        . ([scriptblock]::Create($ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Complete-StagePreruns'},$true).Extent.Text))
        $script:stages=[Collections.Generic.List[object]]::new();$script:completed=@()
        function Complete-ParallelGateStage {param($Name,$Reason,$Detail,$Child,$TimeoutSeconds,$NoProgressSeconds,$ProgressPaths)
            $script:completed+=,$Name;$script:stages.Add([ordered]@{name=$Name;status=$(if($Child.fails){'failed'}else{'passed'});execution='executed'})
            if($Child.fails){throw "$Name failed"}}
        $now=[DateTime]::UtcNow
        $script:stagePreruns=[ordered]@{
            'develop-e2e-upgrade-prerun'=[pscustomobject]@{child=[pscustomobject]@{startedAt=$now;fails=$true};blocking=$true;timeoutSeconds=60;progressPaths=@();reason='r';detail='d'}
            'release-e2e-prerun'=[pscustomobject]@{child=[pscustomobject]@{startedAt=$now;fails=$true};blocking=$false;timeoutSeconds=60;progressPaths=@();reason='r';detail='d'}
            'develop-e2e-fresh-prerun'=[pscustomobject]@{child=[pscustomobject]@{startedAt=$now;fails=$false};blocking=$true;timeoutSeconds=60;progressPaths=@();reason='r';detail='d'}
        }
        { Complete-StagePreruns } | Should -Throw 'develop-e2e-upgrade-prerun failed'
        @($script:completed) | Should -Be @('develop-e2e-upgrade-prerun','release-e2e-prerun','develop-e2e-fresh-prerun')
        $script:stagePreruns.Count | Should -Be 0
        @($script:stages | Where-Object { $_['name'] -eq 'release-e2e-prerun' })[0]['execution'] | Should -BeExactly 'speculative'

        $script:completed=@();$script:stagePreruns=[ordered]@{
            'release-e2e-prerun'=[pscustomobject]@{child=[pscustomobject]@{startedAt=$now;fails=$true};blocking=$false;timeoutSeconds=60;progressPaths=@();reason='r';detail='d'}
        }
        { Complete-StagePreruns } | Should -Not -Throw
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
        $definitions = foreach ($name in @('ConvertTo-NativeArgument', 'Start-PowerShellChildProcess', 'Stop-GateChildProcessTree', 'Wait-PowerShellChildProcess', 'Get-GateMemorySnapshot', 'Update-GateMemoryTelemetry')) {
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
}
