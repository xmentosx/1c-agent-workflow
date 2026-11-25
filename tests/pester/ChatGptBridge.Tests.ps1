BeforeAll {
    $script:Repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    $script:Sidecar = Join-Path $script:Repo '.agents/skills/1c-workflow/chatgpt'
}

Describe 'Optional ChatGPT RDC bridge' {
    It 'passes its isolated Python regressions' {
        . (Join-Path $script:Repo 'scripts/host-test-runtime.ps1')
        $python = Get-SourceHostTestPython -RepositoryRoot $script:Repo -Component ChatGpt
        $testRoot = Join-Path $script:Repo 'tests/python/chatgpt'
        $previousPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $output = & $python -X utf8 -B -m unittest discover -s $testRoot -p 'test_*.py' 2>&1
            $nativeExitCode = $LASTEXITCODE
        } finally { $ErrorActionPreference = $previousPreference }
        $nativeExitCode | Should -Be 0 -Because ($output -join "`n")
    }
}
