BeforeAll {
    $script:Repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    $script:Sidecar = Join-Path $script:Repo '.agents/skills/1c-workflow/chatgpt'
    . (Join-Path $script:Repo 'scripts/git-path-list.ps1')
    $script:ChatGptTrackedPaths = @(Get-RepositoryGitPathList -RepositoryRoot $script:Repo -Arguments @('ls-files','-z','--cached'))
}

Describe 'Optional ChatGPT RDC bridge' {
    It 'keeps the ChatGPT integration inside the installed workflow package' {
        $readme = Get-Content -LiteralPath (Join-Path $script:Sidecar 'README.ru.md') -Raw -Encoding UTF8
        $readme | Should -Match 'PROJECT_ROOT'
        $readme | Should -Match '\.codex/config\.toml'
        Test-Path -LiteralPath (Join-Path $script:Repo '.agents/plugins/marketplace.json') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:Sidecar '.agents/plugins/marketplace.json') | Should -BeFalse
        @(Get-ChildItem -LiteralPath $script:Sidecar -Recurse -Filter 'SKILL.md' -ErrorAction SilentlyContinue).Count | Should -Be 0
        Test-Path -LiteralPath (Join-Path $script:Sidecar 'plugins') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:Sidecar 'generate_skills.py') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:Sidecar 'mcp_bridge.py') -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:Sidecar 'bootstrap-prompt.ru.md') -PathType Leaf | Should -BeTrue
        foreach ($leaf in @('mcp_bridge.py','bootstrap-prompt.ru.md')) {
            ($script:ChatGptTrackedPaths -ccontains ('.agents/skills/1c-workflow/chatgpt/' + $leaf)) | Should -BeTrue -Because 'canonical package path casing must also work on a case-sensitive filesystem'
        }
    }

    It 'ships ChatGPT Project instructions for master, dev, and workflow-source worktrees' {
        $guide = Get-Content -LiteralPath (Join-Path $script:Repo 'docs/itl-workflow/CHATGPT.ru.md') -Raw -Encoding UTF8
        $guide | Should -Match 'RDC_DEVICE_ID'
        $guide | Should -Not -Match 'PROJECT_KIND='
        $guide | Should -Match 'source-delivery\.ps1'
        $guide | Should -Match 'itl-refresh-all'
        $guide | Should -Match 'itl-remote-runner'
        ([regex]::Matches($guide, [regex]::Escape('Set-Location -LiteralPath "<PROJECT_ROOT>"; python -X utf8 .\.agents\skills\1c-workflow\chatgpt\mcp_bridge.py --project-root . project-info'))).Count | Should -Be 2
        $guide | Should -Match 'файловый API RDC'
        $guide | Should -Not -Match ([regex]::Escape('python "<PROJECT_ROOT>\.agents\skills\1c-workflow\chatgpt\mcp_bridge.py"'))
        $completionRule = 'Не завершай конечную задачу после промежуточного успешного шага'
        ([regex]::Matches($guide, [regex]::Escape($completionRule))).Count | Should -Be 3
        $guide | Should -Match 'без запроса подтверждения пользователя'
        $guide | Should -Match 'status.*validate.*form-validate.*validate-test-classification'
        $guide | Should -Match 'fresh passed'
        $guide | Should -Match 'реальном blocker'
        $guide | Should -Match 'объём контекста.*количество tool-вызовов'
        $guide | Should -Not -Match 'WORKFLOW_ROOT'
        foreach ($required in @('session --server', 'one-shot `tools-call`', 'При любой команде itl-*', 'локальный SKILL.md')) {
            $guide.Contains($required) | Should -BeTrue
        }
        $guide.Contains('ChatGPT/RDC thin wrapper') | Should -BeFalse
    }
}
