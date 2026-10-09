BeforeAll {
    . (Join-Path $PSScriptRoot "TestSupport.ps1")
    $context = Initialize-WorkflowPesterContext
    $RepoRoot = $context.RepoRoot
}
Describe 'Scheduler-independent Pester proof' {
    It 'reuses Targeted proof in Full with another worker limit, retaining input and SHA guards: <Producer>' -ForEach @(
        @{ Producer = 'current' }
        @{ Producer = 'legacy-workers-4' }
    ) {
        $root = Join-Path $TestDrive "Кэш с пробелом $Producer"
        $testRoot = Join-Path $root 'tests/pester'
        New-Item -ItemType Directory -Force -Path $testRoot, (Join-Path $root 'fixture') | Out-Null
        & git -C $root init *> $null
        & git -C $root config user.name 'ITL Test'
        & git -C $root config user.email 'itl-test@example.invalid'
        Set-Content -LiteralPath (Join-Path $root '.gitignore') -Encoding UTF8 -Value "out*/`nselection.json`ncounter*.txt"
        $contracts = foreach ($name in @('A','B')) {
            Set-Content -LiteralPath (Join-Path $root "fixture/$name.ps1") -Encoding UTF8 -Value 'owner-v1'
            Set-Content -LiteralPath (Join-Path $testRoot "$name.Tests.ps1") -Encoding UTF8 -Value "Describe '$name' { It 'executes' { Add-Content -LiteralPath (Join-Path `$PSScriptRoot '../../counter$name.txt') -Value 'executed'; `$true | Should -BeTrue } }"
            [ordered]@{ id=$name; owner='fixture'; primaryTest="tests/pester/$name.Tests.ps1"; gate='targeted'; budgetSeconds=30; paths=@("fixture/$name.ps1"); tests=@("tests/pester/$name.Tests.ps1") }
        }
        [IO.File]::WriteAllText((Join-Path $root 'tests/quality-contracts.json'), (@{schemaVersion=1;contracts=@($contracts)} | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        $selectionPath = Join-Path $root 'selection.json'
        [IO.File]::WriteAllText($selectionPath, '{"tests":["tests/pester/A.Tests.ps1","tests/pester/B.Tests.ps1"]}', [Text.UTF8Encoding]::new($false))
        & git -C $root add --all
        & git -C $root commit -m fixture *> $null
        $runner = Join-Path $RepoRoot 'scripts/invoke-pester-shards.ps1'
        $producerPath = $runner
        if ($Producer -eq 'legacy-workers-4') {
            # Produce the previous runtime key through the real runner. Keep all
            # owner inputs, child execution and cache manifest checks unchanged.
            $legacy = [IO.File]::ReadAllText($runner)
            $legacy = $legacy.Replace('$lines.Add($runtimeIdentity)', '$lines.Add("powershell=$($PSVersionTable.PSVersion)|pester=$($pester.Version)|workers=$WorkerCount")')
            $legacy = $legacy.Replace('$PSScriptRoot', ("'" + (Split-Path -Parent $runner).Replace("'", "''") + "'"))
            $producerPath = Join-Path $TestDrive 'legacy-shard-runner.ps1'
            [IO.File]::WriteAllText($producerPath, $legacy, [Text.UTF8Encoding]::new($false))
        }
        $summaries = @()
        foreach ($attempt in 1..4) {
            if ($attempt -eq 3) { Set-Content -LiteralPath (Join-Path $root 'fixture/A.ps1') -Encoding UTF8 -Value 'owner-v2' }
            if ($attempt -eq 4) {
                foreach ($cachedResult in @(Get-ChildItem -LiteralPath (Join-Path $root '.git/itl/pester-shards/v1') -Recurse -File -Filter result.json)) {
                    $proof = Get-Content -LiteralPath $cachedResult.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                    if ([IO.Path]::GetFileName($proof.paths[0]) -eq 'B.Tests.ps1') {
                        Add-Content -LiteralPath $cachedResult.FullName -Encoding UTF8 -Value 'corrupt'
                    }
                }
            }
            $output = Join-Path $root "out$attempt"
            $arguments = @('-RepositoryRoot', $root, '-OutputRoot', $output, '-JunitPath', (Join-Path $output 'pester.xml'), '-WorkerCount', $(if ($attempt -eq 1) { '4' } else { '3' }))
            if ($attempt -eq 1) { $arguments += @('-SelectionPath', $selectionPath) }
            $path = if ($attempt -eq 1) { $producerPath } else { $runner }
            $run = Invoke-TestPowerShellFile -FilePath $path -Arguments $arguments
            if ($attempt -eq 4) {
                $run.exitCode | Should -Not -Be 0 -Because 'corrupted proof must never produce a successful reused qualification'
                ($run.stderr -join [Environment]::NewLine) | Should -Match 'Incomplete Pester shard cache is not empty'
                continue
            }
            $run.exitCode | Should -Be 0 -Because ((@($run.stdout) + @($run.stderr)) -join [Environment]::NewLine)
            $summaries += ($run.stdout -join [Environment]::NewLine) | ConvertFrom-Json
        }
        @($summaries | ForEach-Object { $_.executedWorkerCount }) | Should -Be @(2,0,1)
        @($summaries | ForEach-Object { $_.reusedWorkerCount }) | Should -Be @(0,2,1)
        @($summaries | ForEach-Object { $_.pesterWorkers.effective }) | Should -Be @(4,3,3)
        foreach ($name in @('A','B')) {
            @(Get-Content -LiteralPath (Join-Path $root "counter$name.txt")).Count | Should -Be 2
        }
    }
    It 'allows the observed passing cold cohorts and retains bounded aggregate budgets' {
        . (Join-Path $RepoRoot 'scripts/quality-contracts.ps1')
        $catalog = Get-QualityContractCatalog -RepositoryRoot $RepoRoot
        # 2026-10-09: Targeted exhausted 2100s before an ~8-minute serial tail;
        # Full exhausted 2700s before a 642-second successful continuation.
        $catalog.budgets.targetedHardSeconds | Should -BeGreaterThan (2100 + 480 + 300)
        $catalog.budgets.fullHardSeconds | Should -BeGreaterThan (2700 + 642 + 300)
        $catalog.budgets.targetedHardSeconds | Should -BeLessThan $catalog.budgets.fullHardSeconds
        $catalog.budgets.developHardSeconds | Should -Be ($catalog.budgets.fullHardSeconds + 1200 + 3600)
        Get-ReleaseE2EBudgetProjection -QualityCatalog $catalog -StageCatalog (Get-QualityReleaseStageCatalog -RepositoryRoot $RepoRoot) | Should -Not -BeNullOrEmpty
    }
}
Describe 'Release native progress observation' {
    It 'observes owned native progress while retaining idle and hard limits: <Scenario>' -TestCases @(
        @{ Scenario = 'release-worktree'; ExpectedFailure = ''; NativeRoot = 'release' }
        @{ Scenario = 'configured-relative-worktree'; ExpectedFailure = ''; NativeRoot = 'release'; LogLayout = 'relative' }
        @{ Scenario = 'configured-absolute-main'; ExpectedFailure = ''; NativeRoot = 'main'; LogLayout = 'absolute' }
        @{ Scenario = 'foreign-worktree'; ExpectedFailure = 'no progress for 10 seconds'; NativeRoot = 'foreign' }
        @{ Scenario = 'hard-timeout'; ExpectedFailure = 'remaining mode budget 12 seconds'; NativeRoot = 'release' }
    ) {
        param($Scenario, $ExpectedFailure, $NativeRoot, [string]$LogLayout = 'default')
        $fixtureRoot = Join-Path $TestDrive "Стенд с пробелом $Scenario"
        $projectRoot = Join-Path $fixtureRoot 'Основная ветка'
        $releaseRoot = Join-Path $fixtureRoot 'Рабочая ветка'
        $foreignRoot = Join-Path $fixtureRoot 'Посторонняя ветка'
        $outputRoot = Join-Path $fixtureRoot 'out'
        New-Item -ItemType Directory -Force -Path (Join-Path $projectRoot '.agent-1c'), $releaseRoot, $foreignRoot, $outputRoot | Out-Null
        [IO.File]::WriteAllText((Join-Path $projectRoot '.agent-1c/release-e2e.json'), (@{
            worktreePath = $releaseRoot; devBranchName = 'release-fixture'
        } | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'scripts/check.ps1'), [ref]$tokens, [ref]$errors)
        @($errors) | Should -BeNullOrEmpty
        $definitions = foreach ($name in @('ConvertTo-NativeArgument', 'Start-PowerShellChildProcess', 'Stop-GateChildProcessTree', 'Wait-PowerShellChildProcess')) {
            $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name }, $false)
            $definition | Should -Not -BeNullOrEmpty
            $definition.Extent.Text
        }
        $progressAssignment = @($ast.FindAll({ param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -ceq '$releaseProgressPaths'
        }, $true))
        $progressAssignment.Count | Should -Be 1
        $nativeRootPath = if ($NativeRoot -eq 'release') { $releaseRoot } elseif ($NativeRoot -eq 'main') { $projectRoot } else { $foreignRoot }
        $nativeLogDirectory = Join-Path $nativeRootPath 'logs/1c'
        if ($LogLayout -ne 'default') {
            $nativeLogDirectory = Join-Path $nativeRootPath 'Настроенные журналы 1С'
            $configuredPath = if ($LogLayout -eq 'relative') { 'Настроенные журналы 1С' } else { $nativeLogDirectory }
            New-Item -ItemType Directory -Force -Path (Join-Path $nativeRootPath '.agent-1c') | Out-Null
            [IO.File]::WriteAllText((Join-Path $nativeRootPath '.agent-1c/project.json'), (@{
                logsPath = $configuredPath
            } | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        }
        $nativeLogPath = Join-Path $nativeLogDirectory 'Проверка модулей.log'
        $writerPath = Join-Path $fixtureRoot 'native-progress.ps1'
        [IO.File]::WriteAllText($writerPath, @'
param([string]$LogPath)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $LogPath) | Out-Null
for ($i = 0; $i -lt 10; $i++) {
    [IO.File]::AppendAllText($LogPath, "Проверка модулей: $i`n", [Text.UTF8Encoding]::new($false))
    Start-Sleep -Milliseconds 2500
}
exit 0
'@, [Text.UTF8Encoding]::new($true))
        $probePath = Join-Path $fixtureRoot 'observe-progress.ps1'
        $probe = @'
param([string]$SourceRoot, [string]$FixtureRoot, [string]$NativeLogPath, [string]$Scenario)
$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $utf8; [Console]::OutputEncoding = $utf8; $OutputEncoding = $utf8
. (Join-Path $SourceRoot 'scripts/stand-env-identity.ps1')
'@ + [Environment]::NewLine + ($definitions -join [Environment]::NewLine) + [Environment]::NewLine + @'
$repoRoot = $FixtureRoot
$outputRoot = Join-Path $FixtureRoot 'out'
$E2EProjectRoot = Join-Path $FixtureRoot 'Основная ветка'
$modeHardBudgetSeconds = 60
$childTimeoutSeconds = if ($Scenario -eq 'hard-timeout') { 12 } else { 60 }
$overallStopwatch = [Diagnostics.Stopwatch]::StartNew()
'@ + [Environment]::NewLine + $progressAssignment[0].Extent.Text + [Environment]::NewLine + @'
$child = Start-PowerShellChildProcess -ScriptPath (Join-Path $FixtureRoot 'native-progress.ps1') -Arguments @('-LogPath', $NativeLogPath) -LogName 'release-e2e'
$failure = ''
try { Wait-PowerShellChildProcess -Child $child -TimeoutSeconds $childTimeoutSeconds -NoProgressSeconds 10 -ProgressPaths $releaseProgressPaths }
catch { $failure = $_.Exception.Message }
finally { Stop-GateChildProcessTree -Process $child.process }
$child.process.Refresh()
[IO.File]::WriteAllText((Join-Path $outputRoot 'observation.json'), (@{
    failure = $failure; exitCode = [int]$child.process.ExitCode; elapsedSeconds = $overallStopwatch.Elapsed.TotalSeconds
} | ConvertTo-Json), $utf8)
'@
        [IO.File]::WriteAllText($probePath, $probe, [Text.UTF8Encoding]::new($true))
        $run = Invoke-TestPowerShellFile -FilePath $probePath -Arguments @(
            '-SourceRoot', $RepoRoot, '-FixtureRoot', $fixtureRoot, '-NativeLogPath', $nativeLogPath, '-Scenario', $Scenario
        )
        $run.exitCode | Should -Be 0 -Because $run.combinedText
        $observation = Get-Content -LiteralPath (Join-Path $outputRoot 'observation.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($ExpectedFailure) {
            $observation.failure | Should -Match ([regex]::Escape($ExpectedFailure))
            $observation.elapsedSeconds | Should -BeLessThan 25
        } else {
            $observation.failure | Should -BeNullOrEmpty
            $observation.exitCode | Should -Be 0
            $observation.elapsedSeconds | Should -BeGreaterThan 24
        }
        $nativeText = [Text.UTF8Encoding]::new($false, $true).GetString([IO.File]::ReadAllBytes($nativeLogPath))
        $nativeText | Should -Match 'Проверка модулей: 0'
    }
}

Describe 'Pester shard selected-test identity' {
    BeforeAll {
        function New-ShardIdentityFixture([string]$Name) {
            $root = Join-Path $TestDrive "Кэш с пробелом $Name"
            $testRoot = Join-Path $root 'tests/pester'
            New-Item -ItemType Directory -Force -Path $testRoot | Out-Null
            [IO.File]::WriteAllText((Join-Path $testRoot 'Alpha.Tests.ps1'), "Describe 'AlphaFixture' { It 'alpha' { `$true | Should -BeTrue } }", [Text.UTF8Encoding]::new($true))
            [IO.File]::WriteAllText((Join-Path $testRoot 'Beta.Tests.ps1'), "Describe 'BetaFixture' { It 'beta one' { `$true | Should -BeTrue }; It 'beta two' { `$true | Should -BeTrue } }", [Text.UTF8Encoding]::new($true))
            $tests = @('tests/pester/Alpha.Tests.ps1', 'tests/pester/Beta.Tests.ps1')
            $catalog = [ordered]@{ schemaVersion = 1; contracts = @([ordered]@{
                id = 'shared'; owner = 'fixture'; primaryTest = $tests[0]; gate = 'full'; budgetSeconds = 30
                paths = $tests; tests = $tests
            }) }
            [IO.File]::WriteAllText((Join-Path $root 'tests/quality-contracts.json'), ($catalog | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $root 'selection.json'), (@{ tests = $tests } | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $root '.gitignore'), "out*/`n", [Text.UTF8Encoding]::new($false))
            & git -C $root init -q
            & git -C $root config user.name 'ITL Test'
            & git -C $root config user.email 'itl-test@example.invalid'
            & git -C $root add --all
            & git -C $root commit -qm fixture
            $LASTEXITCODE | Should -Be 0
            return $root
        }
        function Invoke-ShardIdentityFixture([string]$Root, [string]$OutputName) {
            $output = Join-Path $Root $OutputName
            $run = Invoke-TestPowerShellFile -FilePath (Join-Path $RepoRoot 'scripts/invoke-pester-shards.ps1') -Arguments @(
                '-RepositoryRoot', $Root, '-OutputRoot', $output, '-JunitPath', (Join-Path $output 'pester.xml'),
                '-WorkerCount', '1', '-SelectionPath', (Join-Path $Root 'selection.json'))
            $run.exitCode | Should -Be 0 -Because ((@($run.stdout) + @($run.stderr)) -join [Environment]::NewLine)
            return (($run.stdout -join [Environment]::NewLine) | ConvertFrom-Json)
        }
        function Assert-ShardIdentityResults($Summary, [string]$OutputRoot) {
            $alpha = @($Summary.workers | Where-Object { (Split-Path ([string]$_.paths[0]) -Leaf) -eq 'Alpha.Tests.ps1' })
            $beta = @($Summary.workers | Where-Object { (Split-Path ([string]$_.paths[0]) -Leaf) -eq 'Beta.Tests.ps1' })
            $alpha.Count | Should -Be 1; $beta.Count | Should -Be 1
            $alpha[0].passed | Should -Be 1; $beta[0].passed | Should -Be 2
            [xml]$xml = Get-Content -LiteralPath (Join-Path $OutputRoot 'pester.xml') -Raw
            @($xml.SelectNodes('//testcase')).Count | Should -Be 3
            @($xml.SelectNodes('//testcase') | Where-Object { $_.name -like '*alpha*' }).Count | Should -Be 1
            @($xml.SelectNodes('//testcase') | Where-Object { $_.name -like '*beta*' }).Count | Should -Be 2
        }
    }

    It 'separates tests with identical owner inputs and reuses each exact result in another worktree' {
        $root = New-ShardIdentityFixture 'Разные тесты'
        $first = Invoke-ShardIdentityFixture $root 'out-first'
        $first.executedWorkerCount | Should -Be 2
        @($first.workers.inputDigest | Sort-Object -Unique).Count | Should -Be 2
        Assert-ShardIdentityResults $first (Join-Path $root 'out-first')
        $other = Join-Path $TestDrive 'Вторая рабочая копия'
        & git -C $root worktree add -q -b other $other
        $LASTEXITCODE | Should -Be 0
        $second = Invoke-ShardIdentityFixture $other 'out-second'
        $second.executedWorkerCount | Should -Be 0; $second.reusedWorkerCount | Should -Be 2
        Assert-ShardIdentityResults $second (Join-Path $other 'out-second')
        @($second.workers.inputDigest | Sort-Object) | Should -Be @($first.workers.inputDigest | Sort-Object)
    }

    It 'preserves a valid-hash foreign <Kind> cache entry and executes then reuses the requested test' -ForEach @(
        @{ Kind = 'different file' }, @{ Kind = 'same basename under another relative directory' }
    ) {
        $root = New-ShardIdentityFixture $Kind
        $first = Invoke-ShardIdentityFixture $root 'out-first'
        $alpha = $first.workers | Where-Object { (Split-Path ([string]$_.paths[0]) -Leaf) -eq 'Alpha.Tests.ps1' }
        $beta = $first.workers | Where-Object { (Split-Path ([string]$_.paths[0]) -Leaf) -eq 'Beta.Tests.ps1' }
        $slot = Join-Path $root ('.git/itl/pester-shards/v1/' + $alpha.inputDigest)
        $foreign = Get-Content -LiteralPath (Join-Path $root "out-first/pester-shards/worker-$($beta.worker).result.json") -Raw | ConvertFrom-Json
        $foreign.inputDigest = $alpha.inputDigest
        if ($Kind -like 'same basename*') { $foreign.paths = @((Join-Path $root 'tests/pester/Другой каталог/Alpha.Tests.ps1')) }
        [IO.File]::WriteAllText((Join-Path $slot 'result.json'), ($foreign | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        Copy-Item -LiteralPath (Join-Path $root "out-first/pester-shards/worker-$($beta.worker).xml") -Destination (Join-Path $slot 'pester.xml') -Force
        $manifest = Get-Content -LiteralPath (Join-Path $slot 'manifest.json') -Raw | ConvertFrom-Json
        $manifest.resultSha256 = (Get-FileHash -LiteralPath (Join-Path $slot 'result.json')).Hash.ToLowerInvariant()
        $manifest.junitSha256 = (Get-FileHash -LiteralPath (Join-Path $slot 'pester.xml')).Hash.ToLowerInvariant()
        [IO.File]::WriteAllText((Join-Path $slot 'manifest.json'), ($manifest | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        $before = @('manifest.json', 'result.json', 'pester.xml') | ForEach-Object { (Get-FileHash -LiteralPath (Join-Path $slot $_)).Hash }
        $second = Invoke-ShardIdentityFixture $root 'out-second'
        $second.executedWorkerCount | Should -Be 1; $second.reusedWorkerCount | Should -Be 1
        Assert-ShardIdentityResults $second (Join-Path $root 'out-second')
        @(@('manifest.json', 'result.json', 'pester.xml') | ForEach-Object { (Get-FileHash -LiteralPath (Join-Path $slot $_)).Hash }) | Should -Be $before
        $third = Invoke-ShardIdentityFixture $root 'out-third'
        $third.executedWorkerCount | Should -Be 0; $third.reusedWorkerCount | Should -Be 2
        Assert-ShardIdentityResults $third (Join-Path $root 'out-third')
    }

    It 'does not seed the shared cache from a prior local result belonging to another test' {
        $root = New-ShardIdentityFixture 'Локальный чужой результат'
        $first = Invoke-ShardIdentityFixture $root 'out-first'
        $alpha = $first.workers | Where-Object { (Split-Path ([string]$_.paths[0]) -Leaf) -eq 'Alpha.Tests.ps1' }
        $beta = $first.workers | Where-Object { (Split-Path ([string]$_.paths[0]) -Leaf) -eq 'Beta.Tests.ps1' }
        $slot = [IO.Path]::GetFullPath((Join-Path $root ('.git/itl/pester-shards/v1/' + $alpha.inputDigest)))
        $preserved = [IO.Path]::GetFullPath((Join-Path $root 'out-preserved-cache'))
        foreach ($path in @($slot, $preserved)) { $path.StartsWith([IO.Path]::GetFullPath($root) + '\', [StringComparison]::OrdinalIgnoreCase) | Should -BeTrue }
        Move-Item -LiteralPath $slot -Destination $preserved
        $workers = Join-Path $root 'out-first/pester-shards'
        Copy-Item -LiteralPath (Join-Path $workers "worker-$($beta.worker).result.json") -Destination (Join-Path $workers "worker-$($alpha.worker).result.json") -Force
        Copy-Item -LiteralPath (Join-Path $workers "worker-$($beta.worker).xml") -Destination (Join-Path $workers "worker-$($alpha.worker).xml") -Force
        $second = Invoke-ShardIdentityFixture $root 'out-first'
        $second.executedWorkerCount | Should -Be 1; $second.reusedWorkerCount | Should -Be 1
        Assert-ShardIdentityResults $second (Join-Path $root 'out-first')
    }
    It 'invalidates native-build shard reuse when its actual loaded helper or guard changes' {
        $root = New-ShardIdentityFixture 'Нативные зависимости'
        $nativeTest='tests/pester/VanessaBuildRuntime.Tests.ps1'
        Move-Item -LiteralPath (Join-Path $root 'tests/pester/Alpha.Tests.ps1') -Destination (Join-Path $root $nativeTest)
        Copy-Item -LiteralPath (Join-Path $RepoRoot 'tests/quality-contracts.json') -Destination (Join-Path $root 'tests/quality-contracts.json')
        . (Join-Path $RepoRoot 'scripts/client-mcp-build.ps1')
        $nativeInputs=@(Get-ClientMcpBuildInputPaths -RepositoryRoot $RepoRoot)
        foreach($inputPath in $nativeInputs){
            $path=Join-Path $root $inputPath
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
            [IO.File]::WriteAllText($path, "# native fixture input`n", [Text.UTF8Encoding]::new($false))
        }
        [IO.File]::WriteAllText((Join-Path $root 'selection.json'), (@{tests=@($nativeTest)}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
        & git -C $root add --all
        & git -C $root commit -qm native-inputs
        $LASTEXITCODE | Should -Be 0
        $first=Invoke-ShardIdentityFixture $root 'out-native-first'
        $first.executedWorkerCount | Should -Be 1
        $same=Invoke-ShardIdentityFixture $root 'out-native-same'
        $same.reusedWorkerCount | Should -Be 1
        $priorDigest=[string]$same.workers[0].inputDigest
        $changes=@('.agents/skills/1c-workflow/scripts/lib/agent-1c.core.ps1',
            '.agents/skills/1c-workflow/scripts/lib/agent-1c.sessions.ps1',
            '.agents/skills/itl-remote-runner/scripts/ExecutionGuard.ps1',
            '.agents/skills/itl-remote-runner/scripts/itl_remote/execution_guard.py')
        for($index=0;$index -lt $changes.Count;$index++){
            $changed=$changes[$index]
            [IO.File]::AppendAllText((Join-Path $root $changed), "# changed owner input`n",[Text.UTF8Encoding]::new($false))
            & git -C $root add -- $changed
            & git -C $root commit -qm changed-native-input
            $LASTEXITCODE | Should -Be 0
            $fresh=Invoke-ShardIdentityFixture $root "out-native-fresh-$index"
            $fresh.executedWorkerCount | Should -Be 1 -Because "$changed must invalidate the native-build evidence"
            $fresh.reusedWorkerCount | Should -Be 0
            $fresh.workers[0].inputDigest | Should -Not -Be $priorDigest
            $same=Invoke-ShardIdentityFixture $root "out-native-reuse-$index"
            $same.reusedWorkerCount | Should -Be 1
            $priorDigest=[string]$same.workers[0].inputDigest
        }
        # An absent declared dependency must never qualify a cached result.
        & git -C $root rm -q -- $changes[2]
        & git -C $root commit -qm missing-native-input
        $LASTEXITCODE | Should -Be 0
        $missing=Invoke-ShardIdentityFixture $root 'out-native-missing-first'
        $missing.executedWorkerCount | Should -Be 1
        $missing.workers[0].inputDigest | Should -BeNullOrEmpty
        $again=Invoke-ShardIdentityFixture $root 'out-native-missing-second'
        $again.executedWorkerCount | Should -Be 1
        $again.reusedWorkerCount | Should -Be 0
        $catalog=Get-Content -LiteralPath (Join-Path $RepoRoot 'tests/quality-contracts.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $patterns=@($catalog.contracts | Where-Object {$nativeTest -in @($_.tests)} | ForEach-Object { @($_.paths); $extra=$_.PSObject.Properties['reuseInputPaths']; if($extra){@($extra.Value)} })
        @($nativeInputs | Where-Object {$path=$_;@($patterns | Where-Object {$path -like $_}).Count -eq 0}) | Should -BeNullOrEmpty
    }

    It 'rejects malformed reuse input paths: <kind>' -TestCases @(
        @{kind='empty';paths=@()}, @{kind='blank';paths=@('')},
        @{kind='outside';paths=@('../secret.ps1')},
        @{kind='absolute';paths=@('C:\outside.ps1')},
        @{kind='duplicate';paths=@('lib/core.ps1','lib/core.ps1')}
    ) {
        param($kind,$paths)
        . (Join-Path $RepoRoot 'scripts/quality-contracts.ps1')
        $contract=[pscustomobject]@{id='native-fixture';reuseInputPaths=$paths}
        {Get-QualityContractReuseInputPaths -Contract $contract} | Should -Throw '*reuseInputPaths*'
    }
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
        $shardRunner | Should -Match '\$serialTestNames = @\("CompactItlRunner\.Tests\.ps1", "DependencyLocks\.Tests\.ps1", "ReleaseGate\.Tests\.ps1"\)'
        $check = Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\check.ps1") -Raw -Encoding UTF8
        $check | Should -Match 'Invoke-PowerShellChild -ScriptPath \$shardRunner -Arguments \$shardArguments -TimeoutSeconds \$modeHardBudgetSeconds' -Because "the selected shard runner must use the Targeted contract budget instead of a second hard-coded limit"
        $check | Should -Match '-TimeoutSeconds \$pesterHardBudgetSeconds -ProgressPaths \(Join-Path \$outputRoot "pester-shards"\) -LogName "pester-shards"' -Because "the complete Pester inventory must use the catalog Full hard budget and treat shard artifacts as live progress"
        [int]$catalog.budgets.targetedHardSeconds | Should -BeGreaterOrEqual 1200
        [int]$catalog.budgets.fullHardSeconds | Should -BeGreaterOrEqual 1800
        [int]($catalog.contracts | Where-Object id -eq "source-delivery-candidate").budgetSeconds | Should -BeGreaterOrEqual 1200
    }
    It "uses the catalog Targeted worker default only when PesterWorkers is implicit" {
        . (Join-Path $RepoRoot "scripts\quality-contracts.ps1")
        $catalog = Get-QualityContractCatalog -RepositoryRoot $RepoRoot
        [int]$catalog.pesterWorkers.targetedImplicitDefault | Should -Be 4
        Resolve-PesterWorkerCount -Mode Targeted -RequestedWorkerCount 3 -Explicit $false -Catalog $catalog -ProcessorCount 8 | Should -Be 4
        Resolve-PesterWorkerCount -Mode Targeted -RequestedWorkerCount 3 -Explicit $false -Catalog $catalog -ProcessorCount 2 | Should -Be 2
        Resolve-PesterWorkerCount -Mode Targeted -RequestedWorkerCount 3 -Explicit $false -Catalog $catalog -ProcessorCount 0 | Should -Be 1
        Resolve-PesterWorkerCount -Mode Targeted -RequestedWorkerCount 3 -Explicit $true -Catalog $catalog -ProcessorCount 8 | Should -Be 3
        foreach ($mode in @("Smoke", "Full", "Develop", "Release")) {
            Resolve-PesterWorkerCount -Mode $mode -RequestedWorkerCount 3 -Explicit $false -Catalog $catalog -ProcessorCount 8 | Should -Be 3
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
            "tests/pester/DevelopStaticQualificationCache.Tests.ps1", "tests/pester/LocalQualityGate.Tests.ps1",
            "tests/pester/ParserDocsBudgets.Tests.ps1", "tests/pester/ReleaseGate.Tests.ps1", "tests/pester/ReleaseReadiness.Tests.ps1",
            "tests/pester/SourceDeliveryComponentPublication.Tests.ps1", "tests/pester/SourceDeliveryPlan.Tests.ps1",
            "tests/pester/SourceDeliveryProcessLifetime.Tests.ps1",
            "tests/pester/SourceDeliveryPublish.Tests.ps1", "tests/pester/SourceDeliveryPublishContinuation.Tests.ps1",
            "tests/pester/SourceDeliveryPublishQualification.Tests.ps1", "tests/pester/SourceDeliveryPublishRecovery.Tests.ps1",
            "tests/pester/SourceDeliveryPublishReleaseTrain.Tests.ps1", "tests/pester/SourceDeliveryQueue.Tests.ps1",
            "tests/pester/SourceDeliveryRefCleanup.Tests.ps1", "tests/pester/SourceDeliveryResourceLedger.Tests.ps1"
        )
        $selection = Resolve-QualityContractsForPaths -Catalog $catalog -Paths $ePaths
        @($selection.contracts.id | Sort-Object) | Should -Be @("documentation", "source-delivery-entrypoint", "source-delivery-fixtures", "source-delivery-ref-cleanup", "source-quality-gate")
        @($selection.tests) | Should -Be $expectedTests
        @($selection.tests).Count | Should -Be 18

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
            "AiRulesCompatibilityPromotion.Tests.ps1"=3; "DevelopE2EQualification.Tests.ps1"=33
            "DevelopStaticQualificationCache.Tests.ps1"=17; "LocalQualityGate.Tests.ps1"=233
            "ParserDocsBudgets.Tests.ps1"=13; "ReleaseReadiness.Tests.ps1"=105
            "SourceDeliveryComponentPublication.Tests.ps1"=201; "SourceDeliveryPlan.Tests.ps1"=30
            "SourceDeliveryProcessLifetime.Tests.ps1"=7
            "SourceDeliveryResourceLedger.Tests.ps1"=192; "SourceDeliveryPublishContinuation.Tests.ps1"=253
            "SourceDeliveryPublishQualification.Tests.ps1"=460; "SourceDeliveryPublishRecovery.Tests.ps1"=333
            "SourceDeliveryPublishReleaseTrain.Tests.ps1"=346; "SourceDeliveryQueue.Tests.ps1"=352
        }
        foreach ($entry in $updatedOrderingWeights.GetEnumerator()) { [double]$trackedTimings.files.($entry.Key) | Should -Be ([double]$entry.Value) }
        # The complete native 2026-10-08 run measured 549.137 seconds (37/0/0).
        # This current ordering weight does not replace the historical E measurements below.
        [double]$trackedTimings.files."ReleaseGate.Tests.ps1" | Should -Be 550
        [double]$trackedTimings.files."SourceDeliveryPublish.Tests.ps1" | Should -Be 260
        [double]$trackedTimings.files."SourceDeliveryRefCleanup.Tests.ps1" | Should -Be 200
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
        ([double]$catalog.budgets.targetedHardSeconds - $four) | Should -BeGreaterThan 200
    }
    It "fits the observed lifecycle cohort and mandatory serial tail without changing runtime watchdogs" {
        . (Join-Path $RepoRoot "scripts\quality-contracts.ps1")
        $catalog = Get-QualityContractCatalog -RepositoryRoot $RepoRoot
        $historicalPaths = @(
            ".agents/skills/1c-workflow/scripts/lib/agent-1c.lifecycle.ps1",
            ".agents/skills/1c-workflow/scripts/lib/agent-1c.vanessa.ps1",
            "openspec/changes/upgrade-ai-rules-upstream-20a083e5/evidence/c1-final-local-qualification.md",
            "openspec/changes/upgrade-ai-rules-upstream-20a083e5/test-plan.md",
            "templates/dependency-lock.json",
            "tests/pester/CompactItlRunner.Tests.ps1",
            "tests/pester/LifecycleOperationLock.Tests.ps1")
        $selection = Resolve-QualityContractsForPaths -Catalog $catalog -Paths $historicalPaths
        $gate6Tests = @(
            "tests/pester/PlatformGate6Trigger.Tests.ps1",
            "tests/pester/PlatformLegacyContext.Tests.ps1",
            "tests/pester/PlatformLegacyDiagnostics.Tests.ps1",
            "tests/pester/PlatformLegacyImpact.Tests.ps1",
            "tests/pester/PlatformLoadContinuation.Tests.ps1",
            "tests/pester/PlatformSourceCoverage.Tests.ps1")
        # Retain the original observed 57-file cohort; the six newly owned
        # Gate 6 files extend current inventory rather than replacing it.
        @($selection.tests | Where-Object { $_ -notin $gate6Tests }).Count | Should -Be 57
        @($selection.tests).Count | Should -Be 63
        foreach ($test in $gate6Tests) { @($selection.tests) | Should -Contain $test }
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
        $estimatedCriticalPath = $preludeSeconds + $parallelSpanSeconds + $oldCompactSeconds + $newCompactPassedSeconds + $dependencySeconds
        $estimatedCriticalPath | Should -BeGreaterThan 1200
        ([double]$catalog.budgets.targetedHardSeconds - $estimatedCriticalPath) | Should -BeGreaterThan 120
        # Updating this catalog also selects its six directly owned quality files.
        # Keep that self-selected workload, including the mandatory serial ReleaseGate.
        $currentSelection = Resolve-QualityContractsForPaths -Catalog $catalog -Paths @($historicalPaths + @(
            "docs/local-quality-gate.md",
            "openspec/changes/upgrade-ai-rules-upstream-20a083e5/tasks.md",
            "tests/pester/LocalQualityGate.Tests.ps1",
            "tests/pester/WorkflowUpdateRollback.Tests.ps1",
            "tests/quality-contracts.json"))
        @($currentSelection.tests).Count | Should -Be 69
        @($currentSelection.tests | Where-Object { $_ -notin $selection.tests }) | Should -Be @(
            "tests/pester/AiRulesCompatibilityPromotion.Tests.ps1",
            "tests/pester/DevelopE2EQualification.Tests.ps1",
            "tests/pester/DevelopStaticQualificationCache.Tests.ps1",
            "tests/pester/LocalQualityGate.Tests.ps1",
            "tests/pester/ReleaseGate.Tests.ps1",
            "tests/pester/ReleaseReadiness.Tests.ps1")
        # Current scheduler weights/four lanes with the retained per-file observations:
        # parallel 936.459, old complete ReleaseGate 198.938. No cache reuse is assumed.
        $currentParallelSpanSeconds = 936.459
        $serialReleaseSeconds = 198.938
        $currentEstimatedCriticalPath = $preludeSeconds + $currentParallelSpanSeconds + $serialReleaseSeconds + $oldCompactSeconds + $newCompactPassedSeconds + $dependencySeconds
        $currentEstimatedCriticalPath | Should -BeGreaterThan $estimatedCriticalPath
        ([double]$catalog.budgets.targetedHardSeconds - $currentEstimatedCriticalPath) | Should -BeGreaterOrEqual 120
        [double]$catalog.budgets.targetedHardSeconds | Should -BeLessThan ([double]$catalog.budgets.fullHardSeconds)
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
                "tests\quality-contracts.json",
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
    It "does not cache a shard whose external runtime identity is not modeled" {
        $runnerPath = Join-Path $RepoRoot 'scripts/invoke-pester-shards.ps1'
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($runnerPath, [ref]$tokens, [ref]$errors)
        $pathDefinition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-ShardRelativeTestPath' }, $true)
        $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-ShardInputDigest' }, $true)
        $actualCatalog = Get-Content -LiteralPath (Join-Path $RepoRoot 'tests/quality-contracts.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        @($actualCatalog.pesterNonReusableTests) | Should -Contain 'tests/pester/VanessaNestedSelection.Tests.ps1'
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
    It "removes the owned Cyrillic-path branch left after Git unregisters it but fails to delete its directory" {
        $root = Join-Path ([IO.Path]::GetTempPath()) ("itl-e2e-cleanup-p Проект-" + [guid]::NewGuid().ToString('N'))
        $main = Join-Path $root 'd-1234abcd'; $branch = "$main-develop-golden"; $launcher = Join-Path $root 'appdata\1C\1CEStart\ibases.v8i'; $sibling = "$root-keep"
        try {
            New-Item -ItemType Directory -Force -Path $main, $sibling | Out-Null
            & git -C $main init *> $null; & git -C $main config user.name 'ITL Test'; & git -C $main config user.email 'itl-test@example.invalid'
            Set-Content -LiteralPath (Join-Path $main 'value.txt') -Value 'one' -Encoding ASCII
            & git -C $main add value.txt; & git -C $main commit -m init *> $null
            & git -C $main worktree add --quiet -b itldev/develop-golden $branch *> $null
            $gitPointer = Get-Content -LiteralPath (Join-Path $branch '.git') -Raw -Encoding UTF8
            & git -C $main worktree remove --force -- $branch *> $null
            $LASTEXITCODE | Should -Be 0
            New-Item -ItemType Directory -Force -Path (Join-Path $branch 'ignored') | Out-Null
            [IO.File]::WriteAllText((Join-Path $branch '.git'), $gitPointer, [Text.UTF8Encoding]::new($false))
            Set-Content -LiteralPath (Join-Path $branch 'ignored\residue.txt') -Value 'left by Git' -Encoding UTF8
            . (Join-Path $RepoRoot 'scripts\develop-e2e-cleanup.ps1')
            Remove-DevelopE2EFreshProject -FreshProjectsRoot $root -Path $main -BranchPath $branch -LauncherListPath $launcher
            Test-Path -LiteralPath $main | Should -BeFalse
            Test-Path -LiteralPath $branch | Should -BeFalse
            Test-Path -LiteralPath $sibling | Should -BeTrue
        } finally {
            if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
            if (Test-Path -LiteralPath $sibling) { Remove-Item -LiteralPath $sibling -Recurse -Force }
        }
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
        $worker | Should -Match 'SpecialFolder\]::MyDocuments'
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
    It "classifies Release readiness repairs as resumable Release harness changes" {
        $catalog = Get-Content -LiteralPath (Join-Path $RepoRoot "tests\quality-contracts.json") -Raw -Encoding UTF8 | ConvertFrom-Json
        @($catalog.continuationScopes.release) | Should -Contain "scripts/test-release-readiness.ps1"
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

Describe 'Controlled fork qualification script inventory' {
    BeforeAll {
        $tokens = $null
        $errors = $null
        $checkAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'scripts/check.ps1'), [ref]$tokens, [ref]$errors)
        if (@($errors).Count) { throw 'Cannot parse the actual workflow gate consumer.' }
        foreach ($name in @('Get-RelativeRepositoryPath', 'Get-CanonicalTextSha256', 'Test-HasExactInventory', 'Test-ForkQualification')) {
            $definition = $checkAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name }, $true)
            if ($null -eq $definition) { throw "Actual gate function is missing: $name" }
            Invoke-Expression $definition.Extent.Text
        }
        function New-ForkScriptInventoryFixture {
            param([string]$Root, [switch]$Legacy)
            $utf8 = [Text.UTF8Encoding]::new($false)
            foreach ($directory in @('tests', 'scripts', 'build')) { [void][IO.Directory]::CreateDirectory((Join-Path $Root $directory)) }
            $scripts = @('scripts/check.ps1', 'scripts/publish-fork-release.ps1')
            if (-not $Legacy) { $scripts += 'scripts/full-check-contract.ps1' }
            foreach ($relative in @('tests/Проверка.Tests.ps1', 'build/pester.xml') + $scripts) {
                [IO.File]::WriteAllText((Join-Path $Root $relative), "# Точный исходник: $relative`r`n", $utf8)
            }
            $identity = [ordered]@{ commit = ('a' * 40); tree = ('b' * 40); upstreamRef = 'refs/heads/main'; upstreamCommit = ('c' * 40) }
            $qualification = [ordered]@{
                schemaVersion = 2; kind = 'itl-ai-rules-full-qualification'; status = 'passed'; reusable = $true
                repository = [ordered]@{ commit = $identity.commit; tree = $identity.tree; worktreeClean = $true }
                provenance = [ordered]@{ upstreamRef = $identity.upstreamRef; upstreamCommit = $identity.upstreamCommit }
                inventory = [ordered]@{
                    tests = @([ordered]@{ path = 'tests/Проверка.Tests.ps1'; sha256 = (Get-FileHash -LiteralPath (Join-Path $Root 'tests/Проверка.Tests.ps1')).Hash.ToLowerInvariant() })
                    scripts = @(foreach ($relative in $scripts) { [ordered]@{ path = $relative; sha256 = (Get-FileHash -LiteralPath (Join-Path $Root $relative)).Hash.ToLowerInvariant() } })
                }
                junit = [ordered]@{ path = 'build/pester.xml'; sha256 = (Get-FileHash -LiteralPath (Join-Path $Root 'build/pester.xml')).Hash.ToLowerInvariant() }
            }
            $path = Join-Path $Root 'build/full.json'
            [IO.File]::WriteAllText($path, ($qualification | ConvertTo-Json -Depth 8), $utf8)
            return [pscustomobject]@{ Root = $Root; Path = $path; Identity = $identity; Qualification = $qualification }
        }
        function Save-ForkScriptInventoryFixture {
            param([object]$Fixture)
            [IO.File]::WriteAllText($Fixture.Path, ($Fixture.Qualification | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        }
    }
    BeforeEach {
        $fixture = New-ForkScriptInventoryFixture -Root (Join-Path $TestDrive ('Форк с пробелом ' + [guid]::NewGuid().ToString('N')))
    }
    It 'accepts the exact three-script receipt when the Full contract helper exists' {
        Test-ForkQualification -SourceRoot $fixture.Root -Path $fixture.Path -Identity $fixture.Identity | Should -BeTrue
    }
    It 'accepts an exact legacy two-script receipt only when the Full contract helper is absent' {
        $legacy = New-ForkScriptInventoryFixture -Root (Join-Path $TestDrive 'Старый форк с пробелом') -Legacy
        Test-ForkQualification -SourceRoot $legacy.Root -Path $legacy.Path -Identity $legacy.Identity | Should -BeTrue
    }
    It 'refuses a receipt that omits the existing Full contract helper' {
        $fixture.Qualification.inventory.scripts = @($fixture.Qualification.inventory.scripts | Where-Object { $_.path -cne 'scripts/full-check-contract.ps1' })
        Save-ForkScriptInventoryFixture $fixture
        Test-ForkQualification -SourceRoot $fixture.Root -Path $fixture.Path -Identity $fixture.Identity | Should -BeFalse
    }
    It 'refuses an extra script entry rather than trusting an inventory subset' {
        $extra = Join-Path $fixture.Root 'scripts/extra.ps1'
        [IO.File]::WriteAllText($extra, '# foreign entry', [Text.UTF8Encoding]::new($false))
        $fixture.Qualification.inventory.scripts += [ordered]@{ path = 'scripts/extra.ps1'; sha256 = (Get-FileHash -LiteralPath $extra).Hash.ToLowerInvariant() }
        Save-ForkScriptInventoryFixture $fixture
        Test-ForkQualification -SourceRoot $fixture.Root -Path $fixture.Path -Identity $fixture.Identity | Should -BeFalse
    }
    It 'refuses a Full contract helper whose actual source bytes changed after qualification' {
        [IO.File]::AppendAllText((Join-Path $fixture.Root 'scripts/full-check-contract.ps1'), '# изменённый контракт', [Text.UTF8Encoding]::new($false))
        Test-ForkQualification -SourceRoot $fixture.Root -Path $fixture.Path -Identity $fixture.Identity | Should -BeFalse
    }
    It 'refuses an incorrect recorded hash for the Full contract helper' {
        ($fixture.Qualification.inventory.scripts | Where-Object { $_.path -ceq 'scripts/full-check-contract.ps1' }).sha256 = 'd' * 64
        Save-ForkScriptInventoryFixture $fixture
        Test-ForkQualification -SourceRoot $fixture.Root -Path $fixture.Path -Identity $fixture.Identity | Should -BeFalse
    }
    It 'refuses explicit provenance when the canonical release requires refs heads main' {
        $fixture.Qualification.provenance.upstreamRef = 'explicit'
        Save-ForkScriptInventoryFixture $fixture
        Test-ForkQualification -SourceRoot $fixture.Root -Path $fixture.Path -Identity $fixture.Identity | Should -BeFalse
    }
    It 'refuses a helper inventory entry when the helper file no longer exists' {
        Remove-Item -LiteralPath (Join-Path $fixture.Root 'scripts/full-check-contract.ps1')
        Test-ForkQualification -SourceRoot $fixture.Root -Path $fixture.Path -Identity $fixture.Identity | Should -BeFalse
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
        Get-DevelopE2EJourneyHardBudgetSeconds -Catalog $catalog -Journey upgrade | Should -Be 1200
        Get-DevelopE2EJourneyHardBudgetSeconds -Catalog $catalog -Journey fresh | Should -Be 3600
        [int]$catalog.budgets.developHardSeconds | Should -Be 9000
        ([int]$catalog.budgets.fullHardSeconds +
            (Get-DevelopE2EJourneyHardBudgetSeconds -Catalog $catalog -Journey upgrade) +
            (Get-DevelopE2EJourneyHardBudgetSeconds -Catalog $catalog -Journey fresh)) | Should -Be 9000
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
