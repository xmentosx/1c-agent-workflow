BeforeAll {
    . (Join-Path $PSScriptRoot "TestSupport.ps1")
    $context = Initialize-WorkflowPesterContext
    $RepoRoot = $context.RepoRoot
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

    It 'reuses custom-gate publication proof across native planner changes and invalidates an orchestration change' {
        . (Join-Path $RepoRoot 'scripts/git-path-list.ps1')
        . (Join-Path $RepoRoot 'scripts/quality-contracts.ps1')
        $root=New-ShardIdentityFixture 'Native scope'
        $test='tests/pester/SourceDeliveryFrozenPublication.Tests.ps1'
        $catalog=Get-QualityContractCatalog $RepoRoot
        $owners=@($catalog.contracts|Where-Object {$test -in @($_.tests)})
        $patterns=@($owners|ForEach-Object {@($_.paths);Get-QualityContractReuseInputPaths $_})
        $tracked=@(Get-RepositoryGitPathList $RepoRoot @('ls-files','-z','--'))
        foreach($relative in @(Select-QualityPaths $tracked $patterns)) {
            $target=Join-Path $root $relative
            [void][IO.Directory]::CreateDirectory((Split-Path $target))
            Copy-Item -LiteralPath (Join-Path $RepoRoot $relative) -Destination $target -Force
        }
        Copy-Item -LiteralPath (Join-Path $RepoRoot 'tests/quality-contracts.json') -Destination (Join-Path $root 'tests/quality-contracts.json') -Force
        # The actual frozen fixture suites separately execute the real custom
        # gate. This fixture checks production shard selection/cache admission.
        [IO.File]::WriteAllText((Join-Path $root $test),"Describe 'Publication fixture' { It 'passed' { `$true|Should -BeTrue } }")
        [IO.File]::WriteAllText((Join-Path $root 'selection.json'),(@{tests=@($test)}|ConvertTo-Json))
        & git -C $root add --all; & git -C $root commit -qm 'custom gate scope'
        $first=Invoke-ShardIdentityFixture $root 'out-scope-first'
        $first.executedWorkerCount | Should -Be 1
        $first.workers[0].inputDigest | Should -Not -BeNullOrEmpty
        foreach($path in @('scripts/delivery-native-plan.ps1','scripts/develop-e2e-qualification.ps1','scripts/develop-journey-inputs.ps1','scripts/develop-e2e-scenarios.ps1')) {
            $native=Join-Path $root $path
            [IO.File]::WriteAllText($native,"throw 'native planner must not load for a custom gate'")
        }
        & git -C $root add --all; & git -C $root commit -qm 'native planner only'
        $warm=Invoke-ShardIdentityFixture $root 'out-scope-warm'
        $warm.reusedWorkerCount | Should -Be 1
        $warm.workers[0].inputDigest | Should -Be $first.workers[0].inputDigest
        $selected=Resolve-QualityContractsForPaths $catalog @('scripts/delivery-native-plan.ps1')
        @($selected.tests) | Should -Not -Contain $test
        @($selected.tests | Sort-Object) | Should -Be @('tests/pester/SourceDeliveryIncremental.Tests.ps1','tests/pester/SourceDeliveryPlan.Tests.ps1')
        [IO.File]::AppendAllText((Join-Path $root 'scripts/source-delivery-candidate.ps1'),"`n# orchestration change")
        & git -C $root add --all; & git -C $root commit -qm 'orchestration change'
        $changed=Invoke-ShardIdentityFixture $root 'out-scope-changed'
        $changed.executedWorkerCount | Should -Be 1
        $changed.workers[0].inputDigest | Should -Not -Be $first.workers[0].inputDigest
    }

    It 'reuses an unchanged workflow operation group after a sibling edit but invalidates the shared fixture' {
        . (Join-Path $RepoRoot 'scripts/git-path-list.ps1')
        . (Join-Path $RepoRoot 'scripts/quality-contracts.ps1')
        $root=New-ShardIdentityFixture 'Workflow operation scope'
        $tests=@('tests/pester/WorkflowUpdateRollback.Tests.ps1','tests/pester/WorkflowUpdateReceiptRecovery.Tests.ps1')
        $catalog=Get-QualityContractCatalog $RepoRoot
        $owners=@($catalog.contracts|Where-Object {@($_.tests|Where-Object {$_ -in $tests}).Count})
        $patterns=@($owners|ForEach-Object {@($_.paths);Get-QualityContractReuseInputPaths $_})
        $tracked=@(Get-RepositoryGitPathList $RepoRoot @('ls-files','-z','--'))
        foreach($relative in @(Select-QualityPaths $tracked $patterns)) {
            $target=Join-Path $root $relative;[void][IO.Directory]::CreateDirectory((Split-Path $target))
            Copy-Item -LiteralPath (Join-Path $RepoRoot $relative) -Destination $target -Force
        }
        Copy-Item -LiteralPath (Join-Path $RepoRoot 'tests/quality-contracts.json') -Destination (Join-Path $root 'tests/quality-contracts.json') -Force
        foreach($test in $tests) {
            [IO.File]::WriteAllText((Join-Path $root $test),"Describe 'Workflow fixture' { It 'passed' { `$true|Should -BeTrue } }")
        }
        [IO.File]::WriteAllText((Join-Path $root 'selection.json'),(@{tests=$tests}|ConvertTo-Json))
        & git -C $root add --all;& git -C $root commit -qm 'workflow group scope'
        $first=Invoke-ShardIdentityFixture $root 'out-workflow-first'
        $first.executedWorkerCount | Should -Be 2
        [IO.File]::AppendAllText((Join-Path $root $tests[1]),"`n# changed receipt regression")
        & git -C $root add --all;& git -C $root commit -qm 'one operation regression'
        $warm=Invoke-ShardIdentityFixture $root 'out-workflow-sibling'
        $warm.executedWorkerCount | Should -Be 1
        $warm.reusedWorkerCount | Should -Be 1
        @($warm.workers|Where-Object execution -eq reused|ForEach-Object {$_.paths[0]})[0] | Should -BeLike ('*'+(Split-Path $tests[0] -Leaf))
        @((Resolve-QualityContractsForPaths $catalog @($tests[1])).tests) | Should -Be @($tests[1])
        [IO.File]::AppendAllText((Join-Path $root 'tests/pester/WorkflowUpdateRollback.TestSupport.ps1'),"`n# changed shared fixture")
        & git -C $root add --all;& git -C $root commit -qm 'shared workflow fixture'
        $changed=Invoke-ShardIdentityFixture $root 'out-workflow-shared'
        $changed.executedWorkerCount | Should -Be 2
        $changed.reusedWorkerCount | Should -Be 0
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
