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

    It "disables Kilo snapshots while preserving unrelated configuration" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-kilo-no-plugin-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c"), (Join-Path $tempRoot ".kilo") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"aiRules":{"tools":["kilocode"]}}'
            Set-Content -LiteralPath (Join-Path $tempRoot ".ai-rules.json") -Encoding UTF8 -Value '{"tools":["kilocode"],"files":{}}'
            $configPath = Join-Path $tempRoot ".kilo\kilo.json"
            Set-Content -LiteralPath $configPath -Encoding UTF8 -Value '{"instructions":["USER-RULES.md"],"plugin":["custom-plugin"],"custom":"keep"}'
            & git -C $tempRoot init *> $null

            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                Sync-KiloItlCommandSurface -SourceRoot $RepoRoot
            }

            $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $config.snapshot | Should -BeFalse
            @($config.plugin) | Should -Be @("custom-plugin")
            $config.custom | Should -Be "keep"
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "keeps one structured completion and bounded recovery contract across agent surfaces" {
        $rulesText = Get-Content -LiteralPath (Join-Path $RepoRoot "templates\USER-RULES.append.md") -Raw -Encoding UTF8
        foreach ($marker in @("Quick-fix is no exception", "verify_xml", "targeted/static", "executable milestones only to decide continuation", "fresh unfiltered", "after the last relevant edit", "pending verification")) {
            $rulesText | Should -Match ([regex]::Escape($marker))
        }
        $checkText = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\kilo-command-templates\dev\itl-check.md.template") -Raw -Encoding UTF8
        $recoveryText = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\kilo-command-templates\dev\itl-verify-fix.md.template") -Raw -Encoding UTF8

        $checkText | Should -Match "-Action check-dev-branch"
        $checkText | Should -Not -Match "Search configured"
        $checkText | Should -Not -Match "three failed runs"
        foreach ($marker in @(
            "targeted/static checks",
            "milestone whose runtime result decides whether implementation can continue",
            "last verification-relevant edit",
            "final pass is unfiltered",
            "VanessaFeaturePath",
            "VanessaFilterTags"
        )) {
            $checkText | Should -Match ([regex]::Escape($marker))
        }

        foreach ($marker in @(
            "current agent-made configuration/extension change",
            "reuse it unchanged",
            "do not add or edit a test merely because this command was invoked",
            ".agents/skills/1c-workflow/references/vanessa-tests.md",
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
        $fastSkill = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow-fast\SKILL.md") -Raw -Encoding UTF8
        $compactRunner = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\run-itl-command.ps1") -Raw -Encoding UTF8

        $fastSkill | Should -Match 'run-itl-command\.ps1 -- -Action <action>'
        $fastSkill | Should -Not -Match 'scripts\\agent-1c\.ps1 -Action <action>'
        $fastSkill | Should -Match 'executable milestone or completion check'
        $fastSkill | Should -Match 'Do not add `VanessaFeaturePath` or `VanessaFilterTags` to a final run'
        foreach ($marker in @(
            'status=failed',
            'Never relabel it as skipped',
            'requiredAction=/itl-verify-fix',
            'Do not return completion to the user',
            'stalled-suspected',
            'hard timeout',
            'memory'
        )) {
            $fastSkill | Should -Match ([regex]::Escape($marker))
        }
        foreach ($action in @('init-dev-branch-extension', 'update-dev-branch-base', 'check-dev-branch', 'verify-dev-branch')) {
            $compactRunner | Should -Match ([regex]::Escape('"' + $action + '"'))
        }
    }
}
