BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSupport.ps1')
    $context = Initialize-WorkflowPesterContext
    $HelperPath = $context.HelperPath
}

Describe 'Managed rule override diagnostics' {
    It 'reports only conflicting user directives with their dependent operation and preserves the files' {
        $root = Join-Path $TestDrive 'Проект с локальными правилами'
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        $userRules = Join-Path $root 'USER-RULES.md'
        $llmRules = Join-Path $root 'LLM-RULES.md'
        $userText = @'
# User Rules
<!-- ITL-WORKFLOW-USER-RULES:START -->
A separate test-plan.md is not mandatory.
<!-- ITL-WORKFLOW-USER-RULES:END -->
Always create test-plan.md before any OpenSpec proposal.
Unrelated project note stays.
'@
        $llmText = "# LLM Rules`nCAVEMAN_LEVEL=ultra`n"
        [IO.File]::WriteAllText($userRules, $userText, [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($llmRules, $llmText, [Text.UTF8Encoding]::new($false))
        $beforeUserHash = (Get-FileHash -LiteralPath $userRules -Algorithm SHA256).Hash
        $beforeLlmHash = (Get-FileHash -LiteralPath $llmRules -Algorithm SHA256).Hash

        $conflicts = & { . $HelperPath -ProjectRoot $root -Action help *> $null; @(Get-ItlManagedRuleOverrideConflicts) }

        $conflicts | Should -HaveCount 2
        $conflicts[0].path | Should -Be 'USER-RULES.md'
        $conflicts[0].line | Should -Be 5
        $conflicts[0].policy | Should -Be 'test-plan-is-optional'
        $conflicts[0].dependentOperation | Should -Be 'OpenSpec propose/apply'
        $conflicts[1].path | Should -Be 'LLM-RULES.md'
        $conflicts[1].policy | Should -Be 'caveman-level-is-session-only'
        (Get-FileHash -LiteralPath $userRules -Algorithm SHA256).Hash | Should -Be $beforeUserHash
        (Get-FileHash -LiteralPath $llmRules -Algorithm SHA256).Hash | Should -Be $beforeLlmHash
    }
}
