BeforeAll {
    $env:ITL_UI_TOOLS_AUTO_INSTALL = 'skip'
    . (Join-Path $PSScriptRoot 'TestSupport.ps1')
    $RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    $McpHostPath = Join-Path $RepoRoot 'vibecoding1c-mcp-host/install-vibecoding1c-mcp-host.ps1'
    . (Join-Path $RepoRoot 'scripts/host-test-runtime.ps1')
    $SourceTestPython = Get-SourceHostTestPython -RepositoryRoot $RepoRoot -Component 'BookStack'
}

Describe 'HostBookStack component regressions' {
    It "bounds BookStack MCP responses and keeps explicit continuation" {
        $testPath = Join-Path $RepoRoot "vibecoding1c-mcp-host\bookstack-product-docs-mcp\test_server.py"
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            $output = & $SourceTestPython -X utf8 -B $testPath 2>&1
            $exitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }
        $exitCode | Should -Be 0 -Because ($output -join [Environment]::NewLine)
        ($output -join [Environment]::NewLine) | Should -Match "Ran 50 tests"
    }
    It 'enforces BookStack ID selectors and request-bound views on every read path' {
        $previousPreference=$ErrorActionPreference
        try {
            $ErrorActionPreference='Continue'
            $output = & $SourceTestPython -X utf8 -B (Join-Path $RepoRoot 'vibecoding1c-mcp-host/bookstack-product-docs-mcp/test_views.py') 2>&1
            $testExit=$LASTEXITCODE
        } finally { $ErrorActionPreference=$previousPreference }
        $testExit | Should -Be 0 -Because ($output -join [Environment]::NewLine)
        ($output -join [Environment]::NewLine) | Should -Match 'Ran 6 tests'
    }
}
