BeforeAll {
    $env:ITL_UI_TOOLS_AUTO_INSTALL = 'skip'
    . (Join-Path $PSScriptRoot 'TestSupport.ps1')
    $RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    $McpHostPath = Join-Path $RepoRoot 'vibecoding1c-mcp-host/install-vibecoding1c-mcp-host.ps1'
}

Describe 'HostNativeTransport component regressions' {
    It "round trips Python Unicode evidence through the host child-process helper" -Tag BookStackQwen {
        $root = Join-Path $TestDrive "документы с пробелом"
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $configPath = Join-Path $root "host.config.json"
        @{ schemaVersion = 1; stateRoot = $root } | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding UTF8
        $scriptPath = Join-Path $root "проверка.py"
        [IO.File]::WriteAllText($scriptPath, "import sys; print(sys.argv[1])", [Text.UTF8Encoding]::new($false))
        & {
            . $McpHostPath -Action status -ConfigPath $configPath *> $null
            $oldEncoding = $env:PYTHONIOENCODING
            try {
                $env:PYTHONIOENCODING = "utf-8"
                $result = Invoke-ProcessCapture -FilePath python -Arguments @($scriptPath, $root)
                $result.exitCode | Should -Be 0
                $result.lines[0] | Should -BeExactly $root
            } finally { $env:PYTHONIOENCODING = $oldEncoding }
        }
    }

    It "round-trips a real retained SQLite/vector snapshot and rejects invalid archives before modifying data" -Tag StableCutover {
        $tempRoot = Join-Path $TestDrive 'snapshot данные с пробелом'
        New-Item -ItemType Directory -Path $tempRoot | Out-Null
        $configPath = Join-Path $tempRoot 'host.config.json'
        @{ schemaVersion = 1; stateRoot = $tempRoot } | ConvertTo-Json | Set-Content $configPath -Encoding UTF8
        & {
            . $McpHostPath -Action status -ConfigPath $configPath *> $null
            $python = Resolve-PythonExecutable -Config @{}
            $result = Invoke-ProcessWithTimeout -FilePath $python -Arguments @('-X', 'utf8', '-B', (Join-Path $RepoRoot 'tests/python/test_host_index_snapshot.py'), (Join-Path $RepoRoot 'vibecoding1c-mcp-host/index-snapshot.py'), $tempRoot) -TimeoutSec 30 -Description 'SQLite snapshot round trip'
            $result.exitCode | Should -Be 0 -Because ($result.lines -join [Environment]::NewLine)
            ($result.lines -join [Environment]::NewLine) | Should -Match ([regex]::Escape('Снимок: ' + $tempRoot))
        }
    }

    Context 'Original endpoint recovery scope' -Tag DirectEndpointRecovery {
    It 'executes the shared real HTTP identity and Linux ownership regressions' {
        foreach ($test in @('mcp-host/test_endpoint_identity.py', 'mcp-host/linux/test_watchdog.py')) {
            $output = & python -B -X utf8 (Join-Path $RepoRoot $test) 2>&1
            $LASTEXITCODE | Should -Be 0 -Because ($output -join [Environment]::NewLine)
        }
    }
    }
}
