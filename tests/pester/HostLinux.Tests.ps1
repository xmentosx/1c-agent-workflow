BeforeAll {
    $env:ITL_UI_TOOLS_AUTO_INSTALL = 'skip'
    . (Join-Path $PSScriptRoot 'TestSupport.ps1')
    $RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    $McpHostPath = Join-Path $RepoRoot 'vibecoding1c-mcp-host/install-vibecoding1c-mcp-host.ps1'
    . (Join-Path $RepoRoot 'scripts/host-test-runtime.ps1')
    $SourceTestPython = Get-SourceHostTestPython -RepositoryRoot $RepoRoot -Component 'Linux'
}

Describe 'HostLinux component regressions' {
    It "checks dedicated Linux watchdog and refresh ownership boundaries" -Tag LinuxHost {
        $configPath = Join-Path $TestDrive 'linux-host.json'
        @{ schemaVersion = 1; stateRoot = $TestDrive } | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding UTF8
        & {
            . $McpHostPath -Action status -ConfigPath $configPath *> $null
            $python = $SourceTestPython
            $testPath = Join-Path $RepoRoot 'vibecoding1c-mcp-host/linux-native-host'
            $result = Invoke-ProcessWithTimeout -FilePath $python -Arguments @('-X','utf8','-B','-m','unittest','discover','-s',$testPath,'-p','test_*.py') -TimeoutSec 30 -Description 'Linux host ownership and refresh regressions'
            $result.exitCode | Should -Be 0 -Because ($result.lines -join [Environment]::NewLine)
        }
    }
}
