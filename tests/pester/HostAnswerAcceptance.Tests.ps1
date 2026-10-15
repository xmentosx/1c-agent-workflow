BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSupport.ps1')
    $RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    . (Join-Path $RepoRoot 'scripts/host-test-runtime.ps1')
    $SourceTestPython = Get-SourceHostTestPython -RepositoryRoot $RepoRoot -Component 'CodeChecker'
}

Describe 'Offline CodeChecker whole-answer acceptance' {
    It 'preserves raw evidence and rejects incomplete or unsupported whole-answer acceptance' {
        $testPath = Join-Path $RepoRoot 'vibecoding1c-mcp-host/answer-acceptance/test_assess.py'
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $output = & $SourceTestPython -X utf8 -B $testPath 2>&1
            $exitCode = $LASTEXITCODE
        } finally { $ErrorActionPreference = $previousErrorActionPreference }
        $exitCode | Should -Be 0 -Because ($output -join [Environment]::NewLine)
        ($output -join [Environment]::NewLine) | Should -Match 'Ran 19 tests'
    }
}
