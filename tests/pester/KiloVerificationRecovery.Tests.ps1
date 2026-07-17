Describe "Kilo verification recovery command" {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        $RepoRoot = $context.RepoRoot
        $HelperPath = $context.HelperPath
        $HelperText = $context.HelperText
    }

    It "removes the ITL completion plugin and machine action" {
        (Test-Path -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\kilo-plugin\itl-completion-gate.js") -ErrorAction SilentlyContinue) | Should -BeFalse
        $HelperText | Should -Not -Match "completion-gate-status"
        $HelperText | Should -Not -Match "Write-CompletionGateStatus"

        $trackedText = @(
            Get-ChildItem -LiteralPath (Join-Path $RepoRoot ".agents"), (Join-Path $RepoRoot "templates") -Recurse -File -ErrorAction SilentlyContinue |
                ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue }
        ) -join [Environment]::NewLine
        $trackedText | Should -Not -Match "itl-completion-gate"
        $trackedText | Should -Not -Match "KILO_PURE"
    }

    It "does not create or rewrite Kilo plugin configuration while syncing commands" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-kilo-no-plugin-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c"), (Join-Path $tempRoot ".kilo") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"aiRules":{"tools":["kilocode"]}}'
            Set-Content -LiteralPath (Join-Path $tempRoot ".ai-rules.json") -Encoding UTF8 -Value '{"tools":["kilocode"],"files":{}}'
            $configPath = Join-Path $tempRoot ".kilo\kilo.json"
            Set-Content -LiteralPath $configPath -Encoding UTF8 -Value '{"instructions":["USER-RULES.md"],"plugin":["custom-plugin"],"custom":"keep"}'
            $before = [System.IO.File]::ReadAllBytes($configPath)
            & git -C $tempRoot init *> $null

            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                Sync-KiloItlCommandSurface -SourceRoot $RepoRoot
            }

            [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($configPath)) | Should -Be ([Convert]::ToBase64String($before))
            $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
            @($config.plugin) | Should -Be @("custom-plugin")
            $config.custom | Should -Be "keep"
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "keeps itl-check mechanical and makes itl-verify-fix the bounded recovery loop" {
        $checkText = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\kilo-command-templates\dev\itl-check.md.template") -Raw -Encoding UTF8
        $recoveryText = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\kilo-command-templates\dev\itl-verify-fix.md.template") -Raw -Encoding UTF8

        $checkText | Should -Match "-Action check-dev-branch"
        $checkText | Should -Not -Match "Search configured"
        $checkText | Should -Not -Match "three failed runs"

        foreach ($marker in @(
            "current agent-made configuration/extension change",
            "reuse it unchanged",
            "do not add or edit a test merely because this command was invoked",
            "VANESSA-TESTS-GUIDE.md",
            "-Action check-dev-branch",
            "event-log baseline check",
            "Fix a defective scenario",
            "fix the implementation",
            "rerun the full",
            "three failed runs",
            "blocker diagnostics",
            "fresh pass"
        )) {
            $recoveryText | Should -Match ([regex]::Escape($marker))
        }
    }
}
