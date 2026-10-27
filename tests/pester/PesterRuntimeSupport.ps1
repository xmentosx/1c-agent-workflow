function New-RuntimeProofFixture([string]$Name) {
        $root = Join-Path $TestDrive ("Runtime Проект " + $Name)
        $testRoot = Join-Path $root 'tests/pester'
        New-Item -ItemType Directory -Force -Path $testRoot, (Join-Path $root 'scripts') | Out-Null
        [IO.File]::WriteAllText((Join-Path $testRoot 'Runtime.Tests.ps1'), "Describe 'real runtime fixture' { It 'executes original task' { `$lock=[Threading.Mutex]::new(`$false,'Local\itl-runtime-proof-counter'); [void]`$lock.WaitOne(); try { Add-Content -LiteralPath (Join-Path `$PSScriptRoot '../../counter.txt') -Value 'executed' -ErrorAction Stop } finally { `$lock.ReleaseMutex(); `$lock.Dispose() }; `$true | Should -BeTrue } }", [Text.UTF8Encoding]::new($true))
        foreach ($file in @('run-pester-shard.ps1', 'invoke-pester-runtime.ps1')) {
            Copy-Item -LiteralPath (Join-Path $RepoRoot "scripts/$file") -Destination (Join-Path $root "scripts/$file")
        }
        $catalog = @{schemaVersion=1;contracts=@(@{id='runtime-fixture';owner='fixture';gate='targeted';budgetSeconds=30;primaryTest='tests/pester/Runtime.Tests.ps1';paths=@('scripts/*');tests=@('tests/pester/Runtime.Tests.ps1')})}
        [IO.File]::WriteAllText((Join-Path $root 'tests/quality-contracts.json'), ($catalog | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $root '.gitignore'), "out*/`ncounter.txt`n", [Text.UTF8Encoding]::new($false))
        & git -C $root init -q
        & git -C $root config user.name 'ITL Test'
        & git -C $root config user.email 'itl-test@example.invalid'
        & git -C $root add --all
        & git -C $root commit -qm fixture
        $LASTEXITCODE | Should -Be 0
        return $root
    }

function Invoke-RuntimeProofFixture([string]$Root, [string]$OutputName, [string]$Runner = '', [string]$Core = '', [switch]$InputIdentityOnly) {
        if (-not $Runner) { $Runner = Join-Path $RepoRoot 'scripts/invoke-pester-shards.ps1' }
        if ($Core) {
            $wrapper = Join-Path $TestDrive 'invoke-core-parent.ps1'
            $body = "[Console]::OutputEncoding=[Text.UTF8Encoding]::new(`$false); `$OutputEncoding=[Console]::OutputEncoding; & '" + $Core.Replace("'", "''") + "' -NoProfile -File '" + $Runner.Replace("'", "''") + "' @args; exit `$LASTEXITCODE"
            [IO.File]::WriteAllText($wrapper, $body, [Text.UTF8Encoding]::new($true))
            $Runner = $wrapper
        }
        $output = Join-Path $Root $OutputName
        $arguments = @('-RepositoryRoot', $Root, '-OutputRoot', $output, '-JunitPath', (Join-Path $output 'pester.xml'), '-WorkerCount', '1')
        if ($InputIdentityOnly) { $arguments += '-InputIdentityOnly' }
        $run = Invoke-TestPowerShellFile -FilePath $Runner -Arguments $arguments
        $run.exitCode | Should -Be 0 -Because $run.combinedText
        return (($run.stdout -join [Environment]::NewLine) | ConvertFrom-Json)
    }

function New-UnknownRuntimeRunner {
        $workerRoot = Join-Path $TestDrive 'Unknown Проект worker'
        New-Item -ItemType Directory -Force -Path $workerRoot | Out-Null
        Copy-Item -LiteralPath (Join-Path $RepoRoot 'scripts/invoke-pester-runtime.ps1') -Destination $workerRoot
        $worker = [IO.File]::ReadAllText((Join-Path $RepoRoot 'scripts/run-pester-shard.ps1'))
        # Model an unreadable runtime observation only; the normal worker and
        # original test body are byte-for-byte unchanged by this injection.
        $worker = $worker.Replace('if ($RuntimeIdentityOnly) {', "if (`$RuntimeIdentityOnly) { [IO.File]::WriteAllText(`$ResultPath, '{`"status`":`"unknown`",`"identity`":null,`"reason`":`"fixture observation unavailable`",`"durationMs`":0}', [Text.UTF8Encoding]::new(`$false)); exit 0 }
if (`$RuntimeIdentityOnly) {")
        [IO.File]::WriteAllText((Join-Path $workerRoot 'run-pester-shard.ps1'), $worker, [Text.UTF8Encoding]::new($true))
        $runner = [IO.File]::ReadAllText((Join-Path $RepoRoot 'scripts/invoke-pester-shards.ps1'))
        $runner = $runner.Replace('$workerScript = Join-Path $PSScriptRoot "run-pester-shard.ps1"', ("`$workerScript = '" + (Join-Path $workerRoot 'run-pester-shard.ps1').Replace("'", "''") + "'"))
        $runner = $runner.Replace('$PSScriptRoot', ("'" + (Join-Path $RepoRoot 'scripts').Replace("'", "''") + "'"))
        $path = Join-Path $TestDrive 'unknown-runtime-runner.ps1'
        [IO.File]::WriteAllText($path, $runner, [Text.UTF8Encoding]::new($true))
        return $path
    }