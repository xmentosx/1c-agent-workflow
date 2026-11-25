BeforeAll {
    $env:ITL_UI_TOOLS_AUTO_INSTALL = 'skip'
    . (Join-Path $PSScriptRoot 'TestSupport.ps1')
    $RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    $McpHostPath = Join-Path $RepoRoot 'vibecoding1c-mcp-host/install-vibecoding1c-mcp-host.ps1'
}

Describe 'HostToolsProxy component regressions' {
    It "preserves MCP tool contracts while compacting only descriptions" {
        $testPath = Join-Path $RepoRoot "tests\node\tools-list-proxy.test.js"
        $windowsNodeAbortExitCode = -1073740791
        $output = @()
        $exitCode = 1
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            $output = & node $testPath 2>&1
            $exitCode = $LASTEXITCODE
            if ($exitCode -eq 0 -or $exitCode -ne $windowsNodeAbortExitCode) {
                break
            }
            Start-Sleep -Milliseconds 1500
        }
        $exitCode | Should -Be 0 -Because ($output -join [Environment]::NewLine)
        ($output -join [Environment]::NewLine) | Should -Match "unit contract passed"
        $contract = Get-Content -LiteralPath (Join-Path $RepoRoot "vibecoding1c-mcp-host\tools-list-proxy\tools-contract.json") -Raw -Encoding UTF8 | ConvertFrom-Json
        $maximumLength = [int]$contract.descriptionPolicy.maximumApprovedDescriptionCharacters
        $remember = [string]$contract.servers.templates.toolDescriptions.remember.compact
        $recall = [string]$contract.servers.templates.toolDescriptions.recall.compact

        $remember | Should -Match 'shared cross-project memory'
        $remember | Should -Match 'Never use it for project-specific facts'
        $recall | Should -Match 'shared cross-project memory'
        $recall | Should -Match 'verify results against the current project'
        $remember.Length | Should -BeLessOrEqual $maximumLength
        $recall.Length | Should -BeLessOrEqual $maximumLength

        $codechecker = $contract.servers.codechecker
        $codechecker.toolCount | Should -Be 12
        $codechecker.structuralSha256 | Should -Be "ddad947b18a4f4b535faeeb80301daa0fd11c1d0f04a0d162b3029ed49e1f5fa"
        $codechecker.toolDescriptions.check_1c_logic.sourceSha256 | Should -Be "0bcab7643d1d868bfe15c52eb232110c2740b9bc01ff252408d01e318a958ffd"
        $codechecker.toolDescriptions.check_1c_logic.compact | Should -Match 'without checking syntax or style'
    }
}
