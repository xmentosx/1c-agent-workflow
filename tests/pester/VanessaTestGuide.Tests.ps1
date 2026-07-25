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
        $GuideText | Should -Match "selection restores/adds values"
        $GuideText | Should -Match "asserts the exact result"
        $GuideText | Should -Match "runtime-visible, available elements"
        $GuideText | Should -Match "selecting their page or mode"
    }

    It "routes form research from targeted evidence to a final source fallback" {
        $GuideText | Should -Match "For unknown selectors"
        $GuideText | Should -Match "targeted graph/code evidence"
        $GuideText | Should -Match "Vanessa UI MCP for dynamic state"
        $GuideText | Should -Match 'Read only the relevant `Form\.xml` fragment as a final fallback'
        $GuideText | Should -Match 'scripts/get-form-element-context\.ps1'
    }

    It "keeps ordinary acceptance scenarios automated and product-neutral" {
        $GuideText | Should -Match "acceptance scenarios fully automated"
        $GuideText | Should -Match "Interactive profiling is separate tooling"
        $GuideText | Should -Not -Match "PM5"
    }

    It "separates BSL execution contexts and keeps passed scenarios stable" {
        $GuideText | Should -Match "Classify every executable BSL block"
        $GuideText | Should -Match "Never combine both contexts in one block"
        $GuideText | Should -Match "supported Vanessa variable/library step"
        $GuideText | Should -Match "VAExtension cross-step transport"
        $GuideText | Should -Match "never ask the user to click it"
        $GuideText | Should -Match "freeze it during infrastructure diagnosis"
    }
}
