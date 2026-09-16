BeforeAll {
    $script:Repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    $script:Sidecar = Join-Path $script:Repo '.agents/skills/1c-workflow/chatgpt'
}

Describe 'Optional ChatGPT RDC bridge' {
    It 'passes its isolated Python regressions' {
        $python = (Get-Command python -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
        $testRoot = Join-Path $script:Repo 'tests/python/chatgpt'
        $output = & $python -m unittest discover -s $testRoot -p 'test_*.py' 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
    }

    It 'keeps the ChatGPT integration inside the installed workflow package' {
        $readme = Get-Content -LiteralPath (Join-Path $script:Sidecar 'README.ru.md') -Raw -Encoding UTF8
        $readme | Should -Match 'только `PROJECT_ROOT`'
        $readme | Should -Match '\.codex/config\.toml'
        Test-Path -LiteralPath (Join-Path $script:Repo '.agents/plugins/marketplace.json') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:Sidecar '.agents/plugins/marketplace.json') | Should -BeTrue
    }

    It 'installs the sidecar as tracked workflow content without agent-1c runtime copies' {
        $target = Join-Path $TestDrive 'Рабочая ветка с пробелом'
        $installer = Join-Path $script:Repo 'install-agent-1c-workflow.ps1'
        & powershell -NoProfile -ExecutionPolicy Bypass -File $installer `
            -ProjectRoot $target -SourceRoot $script:Repo -NoInit -SkipWorkflowSourceFreshnessCheck *> $null
        $LASTEXITCODE | Should -Be 0

        $installed = Join-Path $target '.agents/skills/1c-workflow/chatgpt'
        Test-Path -LiteralPath (Join-Path $installed 'mcp_bridge.py') -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $installed 'bootstrap-prompt.ru.md') -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $target '.agent-1c/chatgpt') | Should -BeFalse

        $bootstrap = Get-Content -LiteralPath (Join-Path $installed 'bootstrap-prompt.ru.md') -Raw -Encoding UTF8
        $bootstrap | Should -Match '<PROJECT_ROOT>\\\.agents\\skills\\1c-workflow\\chatgpt\\mcp_bridge\.py'
        $bootstrap | Should -Not -Match 'WORKFLOW_ROOT'
    }
}