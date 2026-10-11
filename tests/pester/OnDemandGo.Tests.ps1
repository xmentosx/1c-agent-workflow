BeforeAll {
    $script:Repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    . (Join-Path $script:Repo 'scripts/host-test-runtime.ps1')
}

Describe 'On-demand Go component source verification' {
    It 'runs the original Go suites through their real protocol, process and guard boundaries' {
        $python = Get-SourceHostTestPython -RepositoryRoot $script:Repo -Component OnDemandGo
        $go = if ($env:ITL_SOURCE_TEST_GO) { $env:ITL_SOURCE_TEST_GO } else {
            $command = Get-Command go -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($command) { $command.Source } else { '' }
        }
        if (-not [IO.Path]::IsPathRooted($go) -or -not (Test-Path -LiteralPath $go -PathType Leaf)) {
            throw 'Configure ITL_SOURCE_TEST_GO with an absolute Go executable supporting the component go.mod/toolchain, then repeat this component test.'
        }
        $oldPath = $env:PATH
        $oldUtf8 = $env:PYTHONUTF8
        $oldBytecode = $env:PYTHONDONTWRITEBYTECODE
        try {
            # Go's real execution-guard fixtures resolve python in their children.
            $env:PATH = (Split-Path -Parent $python) + [IO.Path]::PathSeparator + $oldPath
            $env:PYTHONUTF8 = '1'
            $env:PYTHONDONTWRITEBYTECODE = '1'
            $config = Join-Path $TestDrive 'go-host.config.json'
            [IO.File]::WriteAllText($config, ('{"schemaVersion":1,"stateRoot":' + (ConvertTo-Json $TestDrive -Compress) + '}'), [Text.UTF8Encoding]::new($false))
            $result = & {
                . (Join-Path $script:Repo 'vibecoding1c-mcp-host/install-vibecoding1c-mcp-host.ps1') -Action status -ConfigPath $config *> $null
                Invoke-ProcessWithTimeout -FilePath $go -Arguments @('-C', (Join-Path $script:Repo 'tools/itl-ondemand-mcp'), 'test', './...', '-count=1', '-timeout', '120s', '-json') -TimeoutSec 180 -Description 'Original on-demand Go component tests'
            }
            $proofRoot = Join-Path $script:Repo 'build/test-results/local'
            New-Item -ItemType Directory -Force -Path $proofRoot | Out-Null
            $proof = Join-Path $proofRoot ('ondemand-go-' + [guid]::NewGuid().ToString('N') + '.jsonl')
            [IO.File]::WriteAllLines($proof, [string[]]$result.lines, [Text.UTF8Encoding]::new($false))
            $result.exitCode | Should -Be 0 -Because "the complete Go output is retained at $proof; repair the failing owner and repeat the same component test"
            $events = @($result.lines | Where-Object { $_.StartsWith('{') } | ForEach-Object { $_ | ConvertFrom-Json })
            @($events | Where-Object { $_.Action -eq 'fail' -or $_.Action -eq 'skip' }).Count | Should -Be 0
            @($events | Where-Object { $_.Action -eq 'pass' -and $_.PSObject.Properties['Test'] }).Count | Should -BeGreaterThan 0
        } finally {
            $env:PATH = $oldPath
            $env:PYTHONUTF8 = $oldUtf8
            $env:PYTHONDONTWRITEBYTECODE = $oldBytecode
        }
    }
}
