Describe "Vanessa test guide contract" {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        $guidePath = Join-Path $context.RepoRoot ".agents\skills\1c-workflow\references\vanessa-tests.md"
        $GuideText = Get-Content -LiteralPath $guidePath -Raw -Encoding UTF8
    }

    It "documents deterministic Gherkin selection and setup" {
        $GuideText | Should -Match "single-quoted Gherkin parameters and table cells"
        $escapedApostropheRule = "escape an apostrophe as " + [char]96 + [char]92 + [char]39 + [char]96
        $GuideText | Should -Match ([regex]::Escape($escapedApostropheRule))
        $GuideText | Should -Match "stable business key"
        $GuideText | Should -Match "saved form state, the current row, or an active page or mode"
    }

    It "makes clearing and page handling conditional on known runtime behavior" {
        $GuideText | Should -Match "only when it is known to add or restore values"
        $GuideText | Should -Match "scenario expects an exact set"
        $GuideText | Should -Match "runtime-visible and available elements"
        $GuideText | Should -Match "explicitly select the relevant state"
    }

    It "routes form research from targeted evidence to a final source fallback" {
        $GuideText | Should -Match "If a selector is already known, do no extra discovery"
        $GuideText | Should -Match "targeted graph/code metadata or source"
        $GuideText | Should -Match "targeted Vanessa UI MCP evidence"
        $GuideText | Should -Match 'Read only the relevant `Form\.xml` fragment as a final fallback'
        $GuideText | Should -Match "never require a full-form scan"
    }

    It "keeps ordinary acceptance scenarios automated and product-neutral" {
        $GuideText | Should -Match "acceptance scenarios fully automated"
        $GuideText | Should -Match "Interactive profiling is separate tooling"
        $GuideText | Should -Not -Match "PM5"
    }
}
