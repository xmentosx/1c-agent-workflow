BeforeAll {
    $script:Repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    $script:Sidecar = Join-Path $script:Repo '.agents/skills/1c-workflow/chatgpt'
}

Describe 'Optional ChatGPT RDC bridge' {
    It 'installs the sidecar as tracked workflow content without agent-1c runtime copies' {
        $target = Join-Path $TestDrive 'Тест КОРП (ветка)-1'
        $installer = Join-Path $script:Repo 'install-agent-1c-workflow.ps1'
        & powershell -NoProfile -ExecutionPolicy Bypass -File $installer `
            -ProjectRoot $target -SourceRoot $script:Repo -NoInit -SkipWorkflowSourceFreshnessCheck *> $null
        $LASTEXITCODE | Should -Be 0

        $installed = Join-Path $target '.agents/skills/1c-workflow/chatgpt'
        Test-Path -LiteralPath (Join-Path $installed 'mcp_bridge.py') -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $installed 'bootstrap-prompt.ru.md') -PathType Leaf | Should -BeTrue
        @(Get-ChildItem -LiteralPath $installed -Recurse -Filter 'SKILL.md' -File -ErrorAction SilentlyContinue).Count | Should -Be 0
        Test-Path -LiteralPath (Join-Path $installed 'plugins') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $target 'docs/itl-workflow/CHATGPT.ru.md') -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $target '.agent-1c/chatgpt') | Should -BeFalse

        $bootstrap = Get-Content -LiteralPath (Join-Path $installed 'bootstrap-prompt.ru.md') -Raw -Encoding UTF8
        $bootstrap | Should -Match ([regex]::Escape('Set-Location -LiteralPath "<PROJECT_ROOT>"'))
        $bootstrap | Should -Match ([regex]::Escape('python -X utf8 .\.agents\skills\1c-workflow\chatgpt\mcp_bridge.py --project-root . project-info'))
        $bootstrap | Should -Match 'файловый API RDC'
        $bootstrap | Should -Not -Match 'python <PROJECT_ROOT>'
        $bootstrap | Should -Not -Match 'WORKFLOW_ROOT'
    }
}
