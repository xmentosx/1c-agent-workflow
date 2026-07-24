Describe "Vanessa authoring lint" {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        $RepoRoot = $context.RepoRoot
        $HelperPath = Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\agent-1c.ps1"
        $script:LintRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-vanessa-lint-" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Force -Path (Join-Path $script:LintRoot ".agent-1c"), (Join-Path $script:LintRoot "tests\features") | Out-Null
        Set-Content -LiteralPath (Join-Path $script:LintRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"schemaVersion":1,"baseConfigurationVersion":"PM5","masterBranch":"master","testsPath":"tests/features"}'
        $script:CurrentRowPhrase = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("0Y8g0LLRi9Cx0LjRgNCw0Y4g0YLQtdC60YPRidGD0Y4g0YHRgtGA0L7QutGD"))
        $script:PositionPhrase = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("0Y8g0L/QtdGA0LXRhdC+0LbRgyDQuiDRgdGC0YDQvtC60LU="))
        $script:PauseKeyword = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("0J/QsNGD0LfQsA=="))
    }

    AfterAll {
        Remove-Item -LiteralPath $script:LintRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "warns for doubled apostrophes in Gherkin values but not empty values or docstring BSL" {
        $featurePath = Join-Path $script:LintRoot "tests\features\apostrophe.feature"
        @'
Feature: Apostrophe
Scenario: Heading 'Company ''not a parameter'''
    Given text 'Company ''Example'''
    And empty ''
    And code:
        """
        Value = 'Company ''Example''';
        """
    And table:
        | value |
        | 'Another ''example''' |
'@ | Set-Content -LiteralPath $featurePath -Encoding UTF8

        $warnings = & {
            . $HelperPath -ProjectRoot $script:LintRoot -Action help *> $null
            Get-VanessaAuthoringLintWarnings -FeatureRecords @([pscustomobject]@{ path = 'tests/features/apostrophe.feature' })
        }

        @($warnings).Count | Should -Be 2
        @($warnings | Select-Object -ExpandProperty code -Unique) | Should -Be @('ITL_VANESSA_LINT_APOSTROPHE')
        @($warnings | Select-Object -ExpandProperty line) | Should -Be @(3, 11)
    }

    It "requires an immediately preceding concrete positioning table before current-row selection" {
        $featurePath = Join-Path $script:LintRoot "tests\features\row.feature"
        @"
Feature: Rows
Scenario: Unsafe
    When $script:CurrentRowPhrase
Scenario: Safe
    When $($script:PositionPhrase):
        | Key |
        | 42 |
    And $script:CurrentRowPhrase
Scenario: Stale
    When $($script:PositionPhrase):
        | Key |
        | 42 |
    And another action
    And $script:CurrentRowPhrase
Scenario: Incomplete key
    When $($script:PositionPhrase):
        | Key |
    And $script:CurrentRowPhrase
"@ | Set-Content -LiteralPath $featurePath -Encoding UTF8

        $warnings = & {
            . $HelperPath -ProjectRoot $script:LintRoot -Action help *> $null
            Get-VanessaAuthoringLintWarnings -FeatureRecords @([pscustomobject]@{ path = 'tests/features/row.feature' })
        }

        @($warnings).Count | Should -Be 3
        @($warnings | Select-Object -ExpandProperty code -Unique) | Should -Be @('ITL_VANESSA_LINT_CURRENT_ROW')
        @($warnings | Select-Object -ExpandProperty line) | Should -Be @(3, 14, 18)
    }

    It "warns only for a blind pause without an immediate explanatory comment" {
        $featurePath = Join-Path $script:LintRoot "tests\features\pause.feature"
        @"
Feature: Pauses
Scenario: Blind
    When $script:PauseKeyword 5
Scenario: Explained
    # Waiting for the external asynchronous response
    When $script:PauseKeyword 5
"@ | Set-Content -LiteralPath $featurePath -Encoding UTF8

        $warnings = & {
            . $HelperPath -ProjectRoot $script:LintRoot -Action help *> $null
            Get-VanessaAuthoringLintWarnings -FeatureRecords @([pscustomobject]@{ path = 'tests/features/pause.feature' })
        }

        @($warnings).Count | Should -Be 1
        $warnings[0].code | Should -Be 'ITL_VANESSA_LINT_BLIND_PAUSE'
        $warnings[0].line | Should -Be 3
    }

    It "bounds warning output and does not echo feature contents" {
        $featurePath = Join-Path $script:LintRoot "tests\features\bounded.feature"
        $secret = 'secret-marker-that-must-not-be-printed'
        $lines = @("Feature: Bound", "Scenario: Many")
        1..25 | ForEach-Object { $lines += "    Given text '$secret ''value$_'''" }
        $lines | Set-Content -LiteralPath $featurePath -Encoding UTF8

        $warningText = & {
            . $HelperPath -ProjectRoot $script:LintRoot -Action help *> $null
            Write-VanessaAuthoringLintWarnings -FeatureRecords @([pscustomobject]@{ path = 'tests/features/bounded.feature' })
        } 3>&1 | Out-String

        ([regex]::Matches($warningText, 'ITL_VANESSA_LINT_APOSTROPHE')).Count | Should -Be 20
        $warningText | Should -Match '20-warning output limit'
        $warningText | Should -Not -Match $secret
    }

    It "fails open with a fixed safe warning when lint inspection is unavailable" {
        $warningText = & {
            . $HelperPath -ProjectRoot $script:LintRoot -Action help *> $null
            function Get-VanessaAuthoringLintWarnings { throw 'secret inspection detail' }
            Write-VanessaAuthoringLintWarnings -FeatureRecords @([pscustomobject]@{ path = 'tests/features/missing.feature' })
        } 3>&1 | Out-String

        $warningText | Should -Match 'ITL_VANESSA_LINT_UNAVAILABLE'
        $warningText | Should -Not -Match 'secret inspection detail'
    }

    It "keeps lint warnings outside authoring state and evidence gates" {
        $source = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.vanessa.ps1") -Raw -Encoding UTF8
        $prepare = [regex]::Match($source, '(?s)function Prepare-VanessaAuthoring \{(?<body>.*?)\n\}')
        $prepare.Success | Should -BeTrue
        $prepare.Groups['body'].Value | Should -Match 'Write-VanessaAuthoringLintWarnings -FeatureRecords \$features'
        $prepare.Groups['body'].Value.IndexOf('Write-VanessaAuthoringLintWarnings') | Should -BeLessThan $prepare.Groups['body'].Value.IndexOf('Update-DevBranchBase')
        $state = [regex]::Match($source, '(?s)function New-VanessaAuthoringState \{(?<body>.*?)\n\}')
        $state.Groups['body'].Value | Should -Not -Match 'lint|warning'
        $preflight = [regex]::Match($source, '(?s)function Assert-VanessaAuthoringPreflight \{(?<body>.*?)\n\}')
        $preflight.Groups['body'].Value | Should -Not -Match 'Lint'
    }
}
