BeforeAll {
    . (Join-Path $PSScriptRoot "TestSupport.ps1")
    $context = Initialize-WorkflowPesterContext
    $RepoRoot = $context.RepoRoot
}

Describe 'Scheduler-independent Pester proof' {
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
