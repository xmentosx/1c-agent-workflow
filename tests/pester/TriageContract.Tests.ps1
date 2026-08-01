BeforeAll {
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
    $Contract = Get-Content -LiteralPath (Join-Path $RepoRoot "tests\fixtures\triage-contract.json") -Raw -Encoding UTF8 | ConvertFrom-Json
}

Describe "Quick-fix full-cycle OpenSpec triage contract" -Tag "Fast" {
    It "defines two independent axes and all four combinations" {
        $Contract.schemaVersion | Should -Be 1
        @($Contract.executionPaths) | Should -Be @("quick-fix", "full-cycle")
        @($Contract.planningModes) | Should -Be @("direct", "OpenSpec")
        $Contract.defaultPlanningMode | Should -Be "direct"
        $Contract.planningModeChangesVerificationDepth | Should -BeFalse
        $Contract.promotionTriggerSetsExecutionPath | Should -Be "full-cycle"
        $Contract.promotionTriggerSetsPlanningMode | Should -BeNullOrEmpty
        $Contract.requiresPersistedRuntimeState | Should -BeFalse

        $actual = @($Contract.validCombinations | ForEach-Object { "$($_.executionPath)+$($_.planningMode)" })
        $actual | Should -Be @(
            "quick-fix+direct",
            "quick-fix+OpenSpec",
            "full-cycle+direct",
            "full-cycle+OpenSpec"
        )
    }

    It "keeps rules docs helper and bootstrap aligned with the fixture" {
        $falseRussianChoice = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("cXVpY2stZml4INC40LvQuCDQtNC+0YHRgtGD0L/QvQ=="))
        $falseHierarchicalChoice = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("0LTQu9GPIGBmdWxsLWN5Y2xlYCDQstGL0LHQuNGA0LA="))
        $fourCombinationsRussian = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("0JTQvtC/0YPRgdGC0LjQvNGLINCy0YHQtSDRh9C10YLRi9GA0LUg0YHQvtGH0LXRgtCw0L3QuNGP"))
        $defaultRussian = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("0J/QviDRg9C80L7Qu9GH0LDQvdC40Y4="))
        $englishContracts = @(
            "templates\ai-rules-overlay\AGENTS.md",
            "templates\ai-rules-overlay\USER-RULES.md",
            "templates\USER-RULES.append.md",
            "AGENT-INSTALL.md"
        ) | ForEach-Object { Get-Content -LiteralPath (Join-Path $RepoRoot $_) -Raw -Encoding UTF8 }
        $russianContracts = @(
            "docs\itl-workflow\FEATURE-DEVELOPMENT.ru.md",
            "docs\itl-workflow\PROJECT-WORKFLOW.ru.md",
            ".agents\skills\1c-workflow\references\dev-branch-development.md",
            ".agents\skills\1c-workflow\scripts\lib\agent-1c.lifecycle.ps1"
        ) | ForEach-Object { Get-Content -LiteralPath (Join-Path $RepoRoot $_) -Raw -Encoding UTF8 }

        foreach ($text in $englishContracts) {
            $text | Should -Match "quick-fix"
            $text | Should -Match "full-cycle"
            $text | Should -Match "direct"
            $text | Should -Match "OpenSpec"
        }
        foreach ($text in (@($englishContracts) + @($russianContracts))) {
            $text | Should -Not -Match 'quick-fix or the available OpenSpec invocation mode'
            $text | Should -Not -Match ([regex]::Escape($falseRussianChoice) + '[^\r\n]*OpenSpec')
            $text | Should -Not -Match ([regex]::Escape($falseHierarchicalChoice) + '[^\r\n]*OpenSpec')
        }

        ($englishContracts -join "`n") | Should -Match 'All four combinations are valid|all four combinations are valid'
        ($russianContracts -join "`n") | Should -Match ([regex]::Escape($fourCombinationsRussian))
        ($russianContracts -join "`n") | Should -Match ([regex]::Escape($defaultRussian) + '[^\r\n]*direct')
    }

    It "keeps the workflow and controlled-fork fixtures byte-identical when a source checkout is provided" {
        $forkRoot = [Environment]::GetEnvironmentVariable("ITL_AI_RULES_SOURCE")
        if ([string]::IsNullOrWhiteSpace($forkRoot)) {
            Set-ItResult -Skipped -Because "ITL_AI_RULES_SOURCE is not set for this targeted source-boundary check."
            return
        }

        $forkFixture = Join-Path $forkRoot "tests\fixtures\triage-contract.json"
        Test-Path -LiteralPath $forkFixture -PathType Leaf | Should -BeTrue
        $workflowFixture = Join-Path $RepoRoot "tests\fixtures\triage-contract.json"
        (Get-FileHash -LiteralPath $forkFixture -Algorithm SHA256).Hash |
            Should -Be (Get-FileHash -LiteralPath $workflowFixture -Algorithm SHA256).Hash
    }
}
