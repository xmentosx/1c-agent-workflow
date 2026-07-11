BeforeAll {
    . (Join-Path $PSScriptRoot "TestSupport.ps1")
    $context = Initialize-WorkflowPesterContext
    $RepoRoot = $context.RepoRoot
}

Describe "Local quality gate contract" {
    It "parses scripts/check.ps1" {
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $RepoRoot "scripts\check.ps1"),
            [ref]$tokens,
            [ref]$errors
        )
        @($errors) | Should -BeNullOrEmpty
    }

    It "makes Full the default and exposes Fast Full Release modes" {
        $text = Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\check.ps1") -Raw -Encoding UTF8
        $text | Should -Match '\[ValidateSet\("Fast", "Full", "Release"\)\]'
        $text | Should -Match '\[string\]\$Mode = "Full"'
        $text | Should -Match 'ITL_AI_RULES_SOURCE_PATH'
        $text | Should -Match 'Get-LocalForkRelease'
        $text | Should -Match 'invoke-release-e2e\.ps1'
    }

    It "does not install repository-managed git hooks" {
        Test-Path -LiteralPath (Join-Path $RepoRoot ".githooks") | Should -BeFalse
        $text = Get-Content -LiteralPath (Join-Path $RepoRoot "docs\local-quality-gate.md") -Raw -Encoding UTF8
        $text | Should -Match "Git hooks"
        $text | Should -Match "GitHub Actions"
    }

    It "keeps the five local skill directories present" {
        $expected = @(
            "1c-workflow",
            "1c-workflow-fast",
            "itl-roctup-1c-data",
            "itl-vanessa-ui-mcp",
            "product-docs"
        ) | Sort-Object
        $actual = @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot ".agents\skills") -Directory | Select-Object -ExpandProperty Name | Sort-Object)
        $actual | Should -Be $expected
    }
}
