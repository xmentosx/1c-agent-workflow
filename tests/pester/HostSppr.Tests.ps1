BeforeAll {
    $env:ITL_UI_TOOLS_AUTO_INSTALL = 'skip'
    . (Join-Path $PSScriptRoot 'TestSupport.ps1')
    $RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    $McpHostPath = Join-Path $RepoRoot 'vibecoding1c-mcp-host/install-vibecoding1c-mcp-host.ps1'
    . (Join-Path $RepoRoot 'scripts/host-test-runtime.ps1')
    $SourceTestPython = Get-SourceHostTestPython -RepositoryRoot $RepoRoot -Component 'Sppr'
}

Describe 'HostSppr component regressions' {
    It "qualifies SPPR corpus and HTTP tools with the selected isolated Python runtime" -Tag Sppr {
        $python = $SourceTestPython
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
