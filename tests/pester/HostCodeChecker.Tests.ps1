BeforeAll {
    $env:ITL_UI_TOOLS_AUTO_INSTALL = 'skip'
    . (Join-Path $PSScriptRoot 'TestSupport.ps1')
    $RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    $McpHostPath = Join-Path $RepoRoot 'vibecoding1c-mcp-host/install-vibecoding1c-mcp-host.ps1'
    . (Join-Path $RepoRoot 'scripts/host-test-runtime.ps1')
    $SourceTestPython = Get-SourceHostTestPython -RepositoryRoot $RepoRoot -Component 'CodeChecker'
}

Describe 'HostCodeChecker component regressions' {
    It "keeps ambiguous review complete and separates proven ITS evidence without filtering findings" {
        $testPath = Join-Path $RepoRoot 'vibecoding1c-mcp-host/codechecker-beta-overlay/test_review_evidence.py'
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $output = & $SourceTestPython -X utf8 -B $testPath 2>&1
            $exitCode = $LASTEXITCODE
        } finally { $ErrorActionPreference = $previousErrorActionPreference }
        $exitCode | Should -Be 0 -Because ($output -join [Environment]::NewLine)
        ($output -join [Environment]::NewLine) | Should -Match 'OK'
    }
    It "repairs only the pinned FastMCP session cancellation owner" {
        $testPath = Join-Path $RepoRoot 'vibecoding1c-mcp-host/codechecker-beta-overlay/test_fastmcp_lifecycle.py'
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $output = & $SourceTestPython -X utf8 -B $testPath 2>&1
            $exitCode = $LASTEXITCODE
        } finally { $ErrorActionPreference = $previousErrorActionPreference }
        $exitCode | Should -Be 0 -Because ($output -join [Environment]::NewLine)
        ($output -join [Environment]::NewLine) | Should -Match 'OK'
    }
    It "completes only verified ITS results and shares the direct fallback deadline" {
        $testPath = Join-Path $RepoRoot 'vibecoding1c-mcp-host/codechecker-beta-overlay/test_fetch_completion.py'
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $output = & $SourceTestPython -X utf8 -B $testPath 2>&1
            $exitCode = $LASTEXITCODE
        } finally { $ErrorActionPreference = $previousErrorActionPreference }
        $exitCode | Should -Be 0 -Because ($output -join [Environment]::NewLine)
        ($output -join [Environment]::NewLine) | Should -Match 'OK'
    }
    It "preserves the complete logic prompt and returns one bounded provider analysis without semantic filtering" -Tag BetaCutover {
        $testPath = Join-Path $RepoRoot "vibecoding1c-mcp-host\codechecker-beta-overlay\test_patch_mcp_server.py"
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $output = & $SourceTestPython -X utf8 -B $testPath 2>&1
            $exitCode = $LASTEXITCODE
        } finally { $ErrorActionPreference = $previousErrorActionPreference }
        $exitCode | Should -Be 0 -Because ($output -join [Environment]::NewLine)
        ($output -join [Environment]::NewLine) | Should -Match "Ran 28 tests"
    }

    It "applies the shared codechecker transport retry contract" {
        $testPath = Join-Path $RepoRoot "vibecoding1c-mcp-host\codechecker-overlay\test_retry_policy.py"
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            $output = & $SourceTestPython -X utf8 -B $testPath 2>&1
            $exitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }
        $exitCode | Should -Be 0 -Because ($output -join [Environment]::NewLine)
        ($output -join [Environment]::NewLine) | Should -Match "OK"
    }

    It "correlates modern attempts and terminal outcomes without content or retry authority" {
        $testPath = Join-Path $RepoRoot "vibecoding1c-mcp-host/codechecker-beta-overlay/test_telemetry.py"
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $output = & $SourceTestPython -X utf8 -B $testPath 2>&1
            $exitCode = $LASTEXITCODE
        } finally { $ErrorActionPreference = $previousErrorActionPreference }
        $exitCode | Should -Be 0 -Because ($output -join [Environment]::NewLine)
        ($output -join [Environment]::NewLine) | Should -Match "Ran 14 tests"
    }

    It "packages the shared telemetry owner through a restricted modern build context" {
        $configPath = Join-Path $TestDrive 'telemetry host конфигурация.json'
        @{ schemaVersion = 1; stateRoot = $TestDrive } | ConvertTo-Json | Set-Content $configPath -Encoding UTF8
        & {
            . $McpHostPath -Action status -ConfigPath $configPath *> $null
            $baseImage = 'comol/1c-code-checker@sha256:' + ('a' * 64)
            function Ensure-DockerImageAvailable { param($Image); $Image | Should -Be $baseImage }
            function Invoke-DockerCommandChecked {
                param($Arguments, $TimeoutSec, $Description)
                $Arguments[0] | Should -Be 'build'
                $Arguments[2] | Should -Be "BASE_IMAGE=$baseImage"
                $Arguments[3] | Should -Be '-f'
                $Arguments[4] | Should -Be (Join-Path $RepoRoot 'vibecoding1c-mcp-host/codechecker-beta-overlay/Dockerfile')
                $Arguments[-1] | Should -Be (Join-Path $RepoRoot 'vibecoding1c-mcp-host')
                $Arguments[6] | Should -Be 'offline-modern-test'
            }
            Ensure-ServerDockerImageAvailable -Server @{ id = 'codechecker'; channel = 'stable'; manifestPath = 'manifest.json'; upstreamImage = $baseImage } -Image 'offline-modern-test'
        }
        $hostRoot = Join-Path $RepoRoot 'vibecoding1c-mcp-host'
        $ignore = Get-Content (Join-Path $hostRoot '.dockerignore')
        ($ignore -join "`n") | Should -Be (@('**', '!codechecker-beta-overlay/', 'codechecker-beta-overlay/*', '!codechecker-beta-overlay/Dockerfile', '!codechecker-beta-overlay/patch_mcp_server.py', '!codechecker-beta-overlay/fetch_completion.py', '!codechecker-beta-overlay/test_fetch_completion.py', '!codechecker-beta-overlay/review_evidence.py', '!codechecker-beta-overlay/test_review_evidence.py', '!codechecker-beta-overlay/patch_fastmcp_lifecycle.py', '!codechecker-beta-overlay/test_fastmcp_lifecycle.py', '!codechecker-overlay/', 'codechecker-overlay/*', '!codechecker-overlay/observability.py') -join "`n")
        Get-Content (Join-Path $hostRoot 'codechecker-beta-overlay/Dockerfile') -Raw | Should -Match 'COPY codechecker-overlay/observability.py /app/MCP_1copilot/observability.py'
        Get-Content (Join-Path $hostRoot 'codechecker-beta-overlay/Dockerfile') -Raw | Should -Match 'test_review_evidence.py --native'
    }
}
