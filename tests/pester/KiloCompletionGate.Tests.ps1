Describe "Kilo mechanical completion gate" {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        $RepoRoot = $context.RepoRoot
        $HelperPath = $context.HelperPath
        $PluginSpecifier = "../.agents/skills/1c-workflow/kilo-plugin/itl-completion-gate.js"
    }

    It "preserves Kilo config and idempotently registers one local completion plugin" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-kilo-gate-config-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c"), (Join-Path $tempRoot ".kilo") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"aiRules":{"tools":["kilocode"]}}'
            Set-Content -LiteralPath (Join-Path $tempRoot ".kilo\kilo.json") -Encoding UTF8 -Value @"
{
  "`$schema": "https://app.kilo.ai/config.json",
  "instructions": ["USER-RULES.md", "docs/custom.md"],
  "plugin": ["custom-plugin", ["tuple-plugin", {"mode":"keep"}], "$PluginSpecifier", "$PluginSpecifier"],
  "mcp": {"custom":{"type":"remote","url":"https://example.invalid"}},
  "permission": {"bash":"ask"}
}
"@
            & git -C $tempRoot init *> $null

            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                Ensure-KiloCompletionGatePluginConfig *> $null
            }
            $afterFirst = [System.IO.File]::ReadAllBytes((Join-Path $tempRoot ".kilo\kilo.json"))
            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                Ensure-KiloCompletionGatePluginConfig *> $null
            }
            [Convert]::ToBase64String([System.IO.File]::ReadAllBytes((Join-Path $tempRoot ".kilo\kilo.json"))) | Should -Be ([Convert]::ToBase64String($afterFirst))

            $config = Get-Content -LiteralPath (Join-Path $tempRoot ".kilo\kilo.json") -Raw -Encoding UTF8 | ConvertFrom-Json
            @($config.instructions) | Should -Be @("USER-RULES.md", "docs/custom.md")
            $config.'$schema' | Should -Be "https://app.kilo.ai/config.json"
            $config.mcp.custom.url | Should -Be "https://example.invalid"
            $config.permission.bash | Should -Be "ask"
            @($config.plugin)[0] | Should -Be "custom-plugin"
            @($config.plugin)[1][0] | Should -Be "tuple-plugin"
            @($config.plugin | Where-Object { $_ -is [string] -and $_ -eq $PluginSpecifier }).Count | Should -Be 1
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "rejects malformed Kilo plugin config without rewriting the file" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-kilo-gate-invalid-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c"), (Join-Path $tempRoot ".kilo") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{}'
            & git -C $tempRoot init *> $null
            $kiloPath = Join-Path $tempRoot ".kilo\kilo.json"

            foreach ($invalid in @('{"plugin":"not-an-array","custom":"keep"}', '{"plugin":[')) {
                Set-Content -LiteralPath $kiloPath -Encoding UTF8 -Value $invalid
                $before = [System.IO.File]::ReadAllBytes($kiloPath)
                $message = & {
                    . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                    try {
                        Ensure-KiloCompletionGatePluginConfig *> $null
                        ""
                    } catch {
                        $_.Exception.Message
                    }
                }
                $message | Should -Match "KILO_PLUGIN_INVALID"
                [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($kiloPath)) | Should -Be ([Convert]::ToBase64String($before))
            }
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "returns branch-aware JSON and invalidates verification after a second edit of an already dirty file" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-gate-status-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path `
                (Join-Path $tempRoot ".agent-1c\dev-branches"), `
                (Join-Path $tempRoot "src\cf"), `
                (Join-Path $tempRoot "src\cfe"), `
                (Join-Path $tempRoot "tests\features") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"schemaVersion":1,"masterBranch":"master","exportPath":"src/cf","extensionsPath":"src/cfe","testsPath":"tests/features"}'
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\Form.xml") -Encoding UTF8 -Value '<form>baseline</form>'
            Set-Content -LiteralPath (Join-Path $tempRoot "tests\features\regression.feature") -Encoding UTF8 -Value 'Feature: regression'
            & git -C $tempRoot init *> $null
            & git -C $tempRoot config user.email "test@example.com"
            & git -C $tempRoot config user.name "Test User"
            & git -C $tempRoot add .
            & git -C $tempRoot commit -m init *> $null
            & git -C $tempRoot branch -M master
            & git -C $tempRoot checkout -q -b itldev/demo

            $first = & powershell -NoProfile -ExecutionPolicy Bypass -File $HelperPath -ProjectRoot $tempRoot -Action completion-gate-status | ConvertFrom-Json
            $state = [ordered]@{
                devBranchName = "demo"
                safeDevBranchName = "demo"
                devBranch = "itldev/demo"
                lastVerificationStatus = "passed"
                lastVerifiedCommit = ((& git -C $tempRoot rev-parse HEAD).Trim())
                lastVerifiedFingerprint = $first.currentFingerprint
                lastVerifiedAt = (Get-Date).ToString("o")
                lastVerifiedReportPath = "build/test-results/vanessa/run-fixture"
            }
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\dev-branches\demo.json") -Encoding UTF8 -Value (($state | ConvertTo-Json -Depth 6) + [Environment]::NewLine)

            $fresh = & powershell -NoProfile -ExecutionPolicy Bypass -File $HelperPath -ProjectRoot $tempRoot -Action completion-gate-status | ConvertFrom-Json
            $fresh.schemaVersion | Should -Be 1
            $fresh.branch | Should -Be "itldev/demo"
            $fresh.isDevelopmentBranch | Should -BeTrue
            $fresh.freshPassed | Should -BeTrue
            $fresh.paths.exportPath | Should -Be "src/cf"

            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\Form.xml") -Encoding UTF8 -Value '<form>first edit</form>'
            $dirtyOnce = & powershell -NoProfile -ExecutionPolicy Bypass -File $HelperPath -ProjectRoot $tempRoot -Action completion-gate-status | ConvertFrom-Json
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\Form.xml") -Encoding UTF8 -Value '<form>second edit</form>'
            $dirtyTwice = & powershell -NoProfile -ExecutionPolicy Bypass -File $HelperPath -ProjectRoot $tempRoot -Action completion-gate-status | ConvertFrom-Json
            Set-Content -LiteralPath (Join-Path $tempRoot "tests\features\new-regression.feature") -Encoding UTF8 -Value 'Feature: new regression'
            $withUntracked = & powershell -NoProfile -ExecutionPolicy Bypass -File $HelperPath -ProjectRoot $tempRoot -Action completion-gate-status | ConvertFrom-Json

            $dirtyOnce.freshPassed | Should -BeFalse
            $dirtyOnce.status | Should -Be "stale"
            $dirtyOnce.currentFingerprint | Should -Not -Be $fresh.currentFingerprint
            $dirtyTwice.currentFingerprint | Should -Not -Be $dirtyOnce.currentFingerprint
            $withUntracked | Should -Not -BeNullOrEmpty
            $withUntracked.diagnostic | Should -BeNullOrEmpty
            $withUntracked.status | Should -Be "stale"
            $withUntracked.currentFingerprint | Should -Not -Be $dirtyTwice.currentFingerprint
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "runs the event-driven plugin harness without fingerprinting read-only turns" {
        $node = Get-Command node -ErrorAction SilentlyContinue
        $node | Should -Not -BeNullOrEmpty
        $testPath = Join-Path $RepoRoot "tests\js\kilo-completion-gate.test.mjs"
        $output = & $node.Source $testPath 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join [Environment]::NewLine)
        ($output -join [Environment]::NewLine) | Should -Match "kilo completion gate harness passed"
    }

    It "keeps managed and runtime completion context within the combined token budget" {
        $rulesPath = Join-Path $RepoRoot "templates\USER-RULES.append.md"
        $pluginPath = Join-Path $RepoRoot ".agents\skills\1c-workflow\kilo-plugin\itl-completion-gate.js"
        $rulesText = Get-Content -LiteralPath $rulesPath -Raw -Encoding UTF8
        $pluginText = Get-Content -LiteralPath $pluginPath -Raw -Encoding UTF8
        $contextMatch = [regex]::Match($pluginText, 'return `(?<text>ITL gate:[^`]+)`')
        $contextMatch.Success | Should -BeTrue
        $rulesTokens = [math]::Ceiling([Text.Encoding]::UTF8.GetByteCount($rulesText) / 4)
        $contextTokens = [math]::Ceiling([Text.Encoding]::UTF8.GetByteCount($contextMatch.Groups["text"].Value) / 4)
        $rulesTokens | Should -BeLessOrEqual 1120
        $contextTokens | Should -BeLessOrEqual 80
        ($rulesTokens + $contextTokens) | Should -BeLessOrEqual 1200
    }
}
