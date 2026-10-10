BeforeAll {
    $env:ITL_UI_TOOLS_AUTO_INSTALL = 'skip'
    . (Join-Path $PSScriptRoot 'TestSupport.ps1')
    $RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    $McpHostPath = Join-Path $RepoRoot 'vibecoding1c-mcp-host/install-vibecoding1c-mcp-host.ps1'
}

Describe 'HostSppr component regressions' {
    It "qualifies SPPR corpus and HTTP tools with the selected isolated Python runtime" -Tag Sppr {
        $python = if ($env:SPPR_TEST_PYTHON) { $env:SPPR_TEST_PYTHON } else { Join-Path $RepoRoot 'build\sppr-venv\Scripts\python.exe' }
        if (-not (Test-Path -LiteralPath $python -PathType Leaf)) {
            throw 'Prepare build/sppr-venv with sppr-mcp/requirements.txt or set SPPR_TEST_PYTHON to that isolated runtime, then repeat the SPPR owner tests.'
        }
        $hostPath = Join-Path $TestDrive 'sppr-transport-host.json'
        @{ schemaVersion = 1; stateRoot = $TestDrive } | ConvertTo-Json | Set-Content -LiteralPath $hostPath -Encoding UTF8
        & {
            . $McpHostPath -Action status -ConfigPath $hostPath *> $null
            foreach ($name in @('test_sppr.py','test_transport.py')) {
                $path = Join-Path $RepoRoot ('vibecoding1c-mcp-host\sppr-mcp\' + $name)
                $result = Invoke-ProcessWithTimeout -FilePath $python -Arguments @('-X','utf8','-B',$path) -TimeoutSec 120
                $result.exitCode | Should -Be 0 -Because ($result.lines -join [Environment]::NewLine)
                ($result.lines -join "`n") | Should -Match 'OK'
            }
            $unicode = 'C:\СППР проверка\путь с пробелом\описание.json'
            $probe = Invoke-ProcessWithTimeout -FilePath $python -Arguments @('-X','utf8','-c','import sys; print(sys.argv[1])',$unicode) -TimeoutSec 30
            $probe.exitCode | Should -Be 0
            $probe.lines[0] | Should -BeExactly $unicode
        }
    }
}
