BeforeAll {
    $env:ITL_UI_TOOLS_AUTO_INSTALL = 'skip'
    . (Join-Path $PSScriptRoot 'TestSupport.ps1')
    $RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    $McpHostPath = Join-Path $RepoRoot 'vibecoding1c-mcp-host/install-vibecoding1c-mcp-host.ps1'
    . (Join-Path $RepoRoot 'scripts/host-test-runtime.ps1')
    $SourceTestPython = Get-SourceHostTestPython -RepositoryRoot $RepoRoot -Component 'Mantis'
}

Describe 'HostMantis component regressions' {
    It "keeps the Mantis MCP transport stateless" {
        $testPath = Join-Path $RepoRoot "vibecoding1c-mcp-host\mantis-ticket-mcp\test_server.py"
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            $output = & $SourceTestPython -X utf8 -B $testPath 2>&1
            $exitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }
        $exitCode | Should -Be 0 -Because ($output -join [Environment]::NewLine)
        ($output -join [Environment]::NewLine) | Should -Match "Ran 12 tests"
    }

    It "qualifies Mantis delta, recovery and write journal through UTF-8 native transport" {
        . (Join-Path $RepoRoot '.agents/skills/1c-workflow/scripts/lib/agent-1c.core.ps1')
        . (Join-Path $RepoRoot '.agents/skills/1c-workflow/scripts/lib/agent-1c.vanessa.ps1')
        $script:ProjectRoot = $RepoRoot
        $testPath = Join-Path $RepoRoot 'vibecoding1c-mcp-host/mantis-ticket-mcp/test_index.py'
        $result = Invoke-ItlNativeProcessCapture -FilePath $SourceTestPython -Arguments @('-X', 'utf8', $testPath)
        $result.exitCode | Should -Be 0 -Because $result.stderr
        $result.stderr | Should -Match 'OK'
        $result.stdout | Should -Match ([regex]::Escape('Mantis UTF-8: путь с пробелом / original имя.txt'))
    }
}
