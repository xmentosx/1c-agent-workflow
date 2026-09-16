BeforeAll {
    $script:Repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
}

Describe 'Optional ChatGPT RDC bridge' {
    It 'passes its isolated Python regressions' {
        $python = (Get-Command python -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
        $testRoot = Join-Path $script:Repo 'tests/python/chatgpt'
        $output = & $python -m unittest discover -s $testRoot -p 'test_*.py' 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
    }

    It 'keeps the ChatGPT integration isolated from normal Codex surfaces' {
        $readme = Get-Content -LiteralPath (Join-Path $script:Repo 'chatgpt/README.ru.md') -Raw -Encoding UTF8
        $readme | Should -Match '\.codex/config\.toml'
        $readme | Should -Match 'обычной работе Codex'
        Test-Path -LiteralPath (Join-Path $script:Repo '.agents/plugins/marketplace.json') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:Repo 'chatgpt/.agents/plugins/marketplace.json') | Should -BeTrue
    }
}
