BeforeAll {
    . (Join-Path $PSScriptRoot "TestSupport.ps1")
    $context = Initialize-WorkflowPesterContext
    $RepoRoot = $context.RepoRoot
}

Describe 'Scheduler-independent Pester proof' {
    It 'retains complete legacy fallback bindings and refuses an unclassified semantic schema' {
        . (Join-Path $RepoRoot 'scripts/quality-contracts.ps1')
        $catalog=[pscustomobject]@{contracts=@([pscustomobject]@{id='fallback';tests=@('A.Tests.ps1')});semanticTargeting=[pscustomobject]@{path='entry.ps1';fallbackContract='fallback'}}
        $binding=Get-QualityPesterSemanticInputBindings $catalog
        $binding.complete|Should -BeTrue
        @($binding.byTest['A.Tests.ps1'])|Should -Be @('entry.ps1')
        $binding.byTest['B.Tests.ps1']|Should -BeNullOrEmpty
        $catalog.semanticTargeting|Add-Member futureInput 'unknown'
        (Get-QualityPesterSemanticInputBindings $catalog).complete|Should -BeFalse
    }
    It 'reuses mixed semantic Targeted inputs in Full and preview without dropping the affected owner binding' {
        $root=Join-Path $TestDrive 'Semantic cache путь с пробелом'
        New-Item -ItemType Directory -Force (Join-Path $root 'tests/pester'),(Join-Path $root 'fixture')|Out-Null
        & git -C $root init --quiet
        & git -C $root config user.name 'ITL Test'
        & git -C $root config user.email 'itl-test@example.invalid'
        [IO.File]::WriteAllText((Join-Path $root '.gitignore'),"out*/`nselection.json`ncounter*.txt`n")
        $contracts=@(foreach($name in @('A','B')) {
            [IO.File]::WriteAllText((Join-Path $root ('fixture/'+$name+'.ps1')),'v1')
            [IO.File]::WriteAllText((Join-Path $root ('tests/pester/'+$name+'.Tests.ps1')),("Describe '$name' { It 'runs' { Add-Content (Join-Path `$PSScriptRoot '../../counter$name.txt') executed; `$true|Should -BeTrue } }"))
            @{id=$name;owner='fixture';primaryTest=('tests/pester/'+$name+'.Tests.ps1');gate='targeted';budgetSeconds=30;paths=@('fixture/'+$name+'.ps1');tests=@('tests/pester/'+$name+'.Tests.ps1')}
        })
        $entry='fixture/entry.ps1';[IO.File]::WriteAllText((Join-Path $root $entry),'entry-v1')
        $contracts[0].paths+=@($entry)
        $catalog=@{schemaVersion=1;contracts=$contracts;semanticTargeting=@{path=$entry;fallbackContract='A';commonTests=@();owners=@{};libraries=@{}}}
        [IO.File]::WriteAllText((Join-Path $root 'tests/quality-contracts.json'),($catalog|ConvertTo-Json -Depth 12))
        $selection=Join-Path $root 'selection.json'
        [IO.File]::WriteAllText($selection,(@{schemaVersion=2;paths=@($entry);contracts=@('A','B');semanticImpacts=@(@{kind='fallback';owner='A';name='parameters-inventory-changed'});tests=@('tests/pester/A.Tests.ps1','tests/pester/B.Tests.ps1');additionalInputs=@($entry)}|ConvertTo-Json -Depth 4))
        & git -C $root add --all;& git -C $root commit --quiet -m baseline
        $runner=Join-Path $RepoRoot 'scripts/invoke-pester-shards.ps1'
        $results=@()
        foreach($step in 1..6) {
            if($step -eq 3){[IO.File]::WriteAllText((Join-Path $root $entry),'entry-v2')}
            if($step -eq 4){[IO.File]::WriteAllText((Join-Path $root 'fixture/B.ps1'),'owner-v2')}
            if($step -eq 5){$catalog.semanticTargeting.futureUnknownInput='unclassified';[IO.File]::WriteAllText((Join-Path $root 'tests/quality-contracts.json'),($catalog|ConvertTo-Json -Depth 12))}
            if($step -eq 6){$catalog.semanticTargeting.Remove('futureUnknownInput');[IO.File]::WriteAllText((Join-Path $root 'tests/quality-contracts.json'),($catalog|ConvertTo-Json -Depth 12))}
            $output=Join-Path $root ('out'+$step)
            $args=@('-RepositoryRoot',$root,'-OutputRoot',$output,'-JunitPath',(Join-Path $output 'pester.xml'),'-WorkerCount','2')
            if($step -eq 1){$args+=@('-SelectionPath',$selection)}
            if($step -eq 2){
                $preview=Invoke-TestPowerShellFile -FilePath $runner -Arguments ($args+@('-PlanOnly'))
                $preview.exitCode|Should -Be 0 -Because $preview.combinedText
                $plan=($preview.stdout -join [Environment]::NewLine)|ConvertFrom-Json
                $plan.reusedCount|Should -Be 2
                $plan.executedCount|Should -Be 0
            }
            $run=Invoke-TestPowerShellFile -FilePath $runner -Arguments $args
            $run.exitCode|Should -Be 0 -Because $run.combinedText
            $results+=($run.stdout -join [Environment]::NewLine)|ConvertFrom-Json
        }
        @($results|ForEach-Object executedWorkerCount)|Should -Be @(2,0,1,1,2,0)
        @($results|ForEach-Object reusedWorkerCount)|Should -Be @(0,2,1,1,0,2)
        foreach($name in @('A','B')) {@(Get-Content (Join-Path $root ('counter'+$name+'.txt')))|Should -Be @('executed','executed','executed')}
    }
    It 'reuses Targeted proof in Full with another worker limit, retaining input and SHA guards: <Producer>' -ForEach @(
        @{ Producer = 'current' }
        @{ Producer = 'legacy-workers-4' }
        @{ Producer = 'pre-isolation' }
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
        if ($Producer -ne 'current') {
            # Produce the previous runtime key through the real runner. Keep all
            # owner inputs, child execution and cache manifest checks unchanged.
            $legacy = [IO.File]::ReadAllText($runner)
            $legacy = $legacy.Replace('$lines.Add($runtimeIdentity)', '$lines.Add("powershell=$($PSVersionTable.PSVersion)|pester=$($runtime.pesterVersion)|workers=$WorkerCount")')
            if ($Producer -eq 'pre-isolation') {
                $withoutScope = $legacy.Replace("`$lines.Add('external-input-scope=declared-v1')", '')
                $withoutScope | Should -Not -Be $legacy
                $legacy = $withoutScope
            }
            $legacy = $legacy.Replace('$PSScriptRoot', ("'" + (Split-Path -Parent $runner).Replace("'", "''") + "'"))
            $producerPath = Join-Path $TestDrive 'legacy-shard-runner.ps1'
            [IO.File]::WriteAllText($producerPath, $legacy, [Text.UTF8Encoding]::new($true))
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
        $expectedExecuted = if ($Producer -eq 'pre-isolation') { @(2,2,1) } else { @(2,0,1) }
        $expectedReused = if ($Producer -eq 'pre-isolation') { @(0,0,1) } else { @(0,2,1) }
        @($summaries | ForEach-Object { $_.executedWorkerCount }) | Should -Be $expectedExecuted
        @($summaries | ForEach-Object { $_.reusedWorkerCount }) | Should -Be $expectedReused
        @($summaries | ForEach-Object { $_.pesterWorkers.effective }) | Should -Be @(4,3,3)
        foreach ($name in @('A','B')) {
            $expectedCount = if ($Producer -eq 'pre-isolation') { 3 } else { 2 }
            @(Get-Content -LiteralPath (Join-Path $root "counter$name.txt")).Count | Should -Be $expectedCount
        }
    }

}
