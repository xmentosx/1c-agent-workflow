BeforeAll {
    $env:ITL_UI_TOOLS_AUTO_INSTALL = 'skip'
    . (Join-Path $PSScriptRoot 'TestSupport.ps1')
    $RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    $McpHostPath = Join-Path $RepoRoot 'vibecoding1c-mcp-host/install-vibecoding1c-mcp-host.ps1'
}

Describe 'HostCodeChecker component regressions' {
    It "restores the stable CodeChecker logic tool in the beta image" -Tag BetaCutover {
        $testPath = Join-Path $RepoRoot "vibecoding1c-mcp-host\codechecker-beta-overlay\test_patch_mcp_server.py"
        $output = & python $testPath 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join [Environment]::NewLine)
        ($output -join [Environment]::NewLine) | Should -Match "Ran 3 tests"
    }

    It "applies the shared codechecker transport retry contract" {
        $testPath = Join-Path $RepoRoot "vibecoding1c-mcp-host\codechecker-overlay\test_retry_policy.py"
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            $output = & python $testPath 2>&1
            $exitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }
        $exitCode | Should -Be 0 -Because ($output -join [Environment]::NewLine)
        ($output -join [Environment]::NewLine) | Should -Match "OK"
    }
}
