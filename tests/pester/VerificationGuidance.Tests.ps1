Describe "Verification guidance contracts" {
    BeforeAll {
        $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    }

    It "makes boundary-focused unit coverage an installed agent rule" {
        $rules = Get-Content -LiteralPath (Join-Path $RepoRoot "templates\USER-RULES.append.md") -Raw -Encoding UTF8
        $reference = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\references\yaxunit-tests.md") -Raw -Encoding UTF8
        $rules | Should -Match 'For algorithms, recovery, or optimization'
        $rules | Should -Match 'boundary matrix, optimization invariants, test grouping, and benchmark cadence'
        $rules | Should -Match 'complex changes may need both'
        $reference | Should -Match 'immediately below, at, and immediately above every changed boundary'
        $reference | Should -Match 'corrupt data, select the wrong objects, silently lose rows, or report false success'
        $reference | Should -Match 'Parameterized YAxUnit cases are preferred'
    }

    It "requires correctness-first optimization coverage and bounded test groups" {
        $reference = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\references\yaxunit-tests.md") -Raw -Encoding UTF8
        $guide = Get-Content -LiteralPath (Join-Path $RepoRoot "docs\itl-workflow\FEATURE-DEVELOPMENT.ru.md") -Raw -Encoding UTF8
        $decode = { param([string]$Value) [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Value)) }

        $reference | Should -Match 'lock the current functional contract with characterization cases'
        $reference | Should -Match 'cache or intermediate-state invalidation'
        $reference | Should -Match 'isolation between independent plans, objects, tenants, sessions, or calculation contexts'
        $reference | Should -Match 'no partial or stale state after an error or cancellation'
        $reference | Should -Match 'one small representative performance regression that finishes quickly'
        $reference | Should -Match 'Correctness failures cannot be waived by a speed improvement'
        $reference | Should -Match 'Run all .*default-fast.* groups together in one normal YAxUnit session'
        $reference | Should -Match 'Keep .*explicit-benchmark.* modules outside the default .* registration'
        $reference | Should -Match 'owner-aware selective execution only after measurements'
        $guide | Should -Match ([regex]::Escape((& $decode '0YHQvdCw0YfQsNC70LAg0YTQuNC60YHQuNGA0YPQtdGCINC10LPQviDRgtC10LrRg9GJ0LjQuSDRhNGD0L3QutGG0LjQvtC90LDQu9GM0L3Ri9C5INC60L7QvdGC0YDQsNC60YI=')))
        $guide | Should -Match ([regex]::Escape((& $decode '0LPRgNGD0L/Qv9C40YDRg9GO0YLRgdGPINCyINGC0LXRgdGC0L7QstC+0Lwg0YDQsNGB0YjQuNGA0LXQvdC40Lgg0L/QviDQv9GA0LjQutC70LDQtNC90L7QuSDQv9C+0LTRgdC40YHRgtC10LzQtSwg0L7QsdGK0LXQutGC0YMg0Lgg0LDQu9Cz0L7RgNC40YLQvNGD')))
        $guide | Should -Match ([regex]::Escape((& $decode '0L7RgtC00LXQu9GM0L3Ri9C5INC/0YDQvtGG0LXRgdGBIDHQoSDQvdCwINC60LDQttC00YPRjiDQs9GA0YPQv9C/0YMg0L3QtSDQt9Cw0L/Rg9GB0LrQsNC10YLRgdGP')))
    }

    It "keeps authoring guidance and repair instructions aligned" {
        $reference = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\references\vanessa-authoring.md") -Raw -Encoding UTF8
        $reference | Should -Match 'There is no separate Vanessa authoring gate'
        $reference | Should -Match 'scenario run is optional diagnostic feedback'
        $reference | Should -Match '/itl-check` is the only executable verification gate'
        $reference | Should -Match 'Do not delete, skip, filter, or weaken'
        $reference | Should -Match 'user_actions_recording'
        $reference | Should -Match 'execute_form_actions'
        $reference | Should -Match 'modal dialog, window change, or intermediate state'
        $reference | Should -Match 'frequently_used_steps.*optional fallback'
        $reference | Should -Match 'get_all.*route itself is unknown.*complete command interface'
        $reference | Should -Match 'get_window_list_os.*get_window_screenshot_os'
        $reference | Should -Match 'reloadAndRunFromLine'
        $reference | Should -Match 'question_search.*answers_search.*questions_only.*one_question'
        $reference | Should -Match 'terminal failed `/itl-check`.*named UI/runtime question unresolved'
        $reference | Should -Match 'unchanged tree.*owned cleanup finish.*before editing or spending the next full repair attempt'
        $reference | Should -Match 'Skip this diagnostic when the artifacts already answer the question'
        $reference | Should -Match 'consumes no repair attempt, creates no pass.*configured repair-session limit.*final `/itl-check`'

        $repairTemplate = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\kilo-command-templates\dev\itl-verify-fix.md.template") -Raw -Encoding UTF8
        $repairTemplate | Should -Match 'conditional post-failure runtime diagnostic from `vanessa-authoring.md`'
        $repairTemplate | Should -Match 'not an extra gate or repair attempt'
    }

    It "ships an executable JSON action example in the recipes" {
        $recipes = Get-Content -LiteralPath (Join-Path $RepoRoot '.agents\skills\1c-workflow\references\vanessa-recipes.md') -Raw -Encoding UTF8
        $batchExample = [regex]::Match($recipes, '(?m)^(?<json>\{"name":"execute_form_actions".+\})\r?$')
        $batchExample.Success | Should -BeTrue
        $gatewayArguments = $batchExample.Groups['json'].Value | ConvertFrom-Json
        $innerArguments = $gatewayArguments.argumentsJson | ConvertFrom-Json
        $actions = @($innerArguments.actions_json | ConvertFrom-Json)
        $gatewayArguments.name | Should -Be 'execute_form_actions'
        $actions.Count | Should -Be 1
        $actions[0].action | Should -Be 'set_value'
    }

    It "keeps classification continuation instructions in the same agent task" {
        $fastSkill = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow-fast\SKILL.md") -Raw -Encoding UTF8
        $refreshTemplate = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\kilo-command-templates\dev\itl-refresh.md.template") -Raw -Encoding UTF8
        $advanced = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\references\advanced-actions.md") -Raw -Encoding UTF8
        $selectionReference = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\references\verification-suite-selection.md") -Raw -Encoding UTF8

        foreach ($contract in @($fastSkill, $refreshTemplate)) {
            $contract | Should -Match 'classify-tests-after-refresh:'
            $contract | Should -Match 'same task|same agent task|same task'
            $contract | Should -Match '(?is)do not ask the developer to\s+classify'
        }
        $fastSkill | Should -Match 'split oversized/mixed feature files yourself'
        $refreshTemplate | Should -Match 'split oversized or mixed feature files yourself'
        $advanced | Should -Match 'VERIFICATION_SUITE_ACCEPTANCE_SCOPE_TOO_BROAD'
        $advanced | Should -Match 'Do not merely rename the original file'
        $selectionReference | Should -Match '(?s)at most eight flat\s+scenarios'
        $selectionReference | Should -Match 'post-merge scenario baseline'
    }

    It "ships the bounded Vanessa guide and native feature vocabulary" {
        $vanessaGuideText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".agents\skills\1c-workflow\references\vanessa-tests.md")
        $vanessaGuideText | Should -Match "Agent reference"
        $vanessaGuideText | Should -Match "Context Economy"
        $vanessaGuideText | Should -Match "Do Not"
        $vanessaGuideText | Should -Match "1-2"
        $vanessaGuideText | Should -Match "parameterized YAxUnit"
        $vanessaGuideText | Should -Match "smoke"
        $vanessaGuideText | Should -Match "tests/features"
        $featureMarker = -join ([char[]](0x0424, 0x0443, 0x043D, 0x043A, 0x0446, 0x0438, 0x043E, 0x043D, 0x0430, 0x043B, 0x003A))
        $contextMarker = -join ([char[]](0x041A, 0x043E, 0x043D, 0x0442, 0x0435, 0x043A, 0x0441, 0x0442, 0x003A))
        $scenarioMarker = -join ([char[]](0x0421, 0x0446, 0x0435, 0x043D, 0x0430, 0x0440, 0x0438, 0x0439, 0x003A))
        foreach ($marker in @("#language: ru", $featureMarker, $contextMarker, $scenarioMarker)) {
            $vanessaGuideText | Should -Match ([regex]::Escape($marker))
        }
    }
}
