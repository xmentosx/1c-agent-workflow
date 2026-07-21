Describe "Kilo context diagnostics" {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        $RepoRoot = $context.RepoRoot
        $HelperPath = $context.HelperPath
        $ContextModulePath = Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.context-diagnostics.ps1"
        $LifecyclePath = Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.lifecycle.ps1"

        function New-KiloSessionFixture {
            param(
                [long]$InputTokens = 100,
                [long]$CacheRead = 0,
                [long]$CacheWrite = 0,
                [long]$Output = 2,
                [long]$Reasoning = 0,
                [string]$Model = "gpt-test",
                [string]$Provider = "provider-test",
                [string]$Variant = "",
                [switch]$ToolCall,
                [switch]$ExtraMessage
            )
            $assistantParts = @(
                [ordered]@{ type = "step-start" },
                [ordered]@{ type = "text"; text = "OK" }
            )
            if ($ToolCall) { $assistantParts += [ordered]@{ type = "tool"; tool = "read"; state = [ordered]@{} } }
            $assistantParts += [ordered]@{ type = "step-finish" }
            $messages = @(
                [ordered]@{
                    info = [ordered]@{ role = "user"; agent = "code" }
                    parts = @([ordered]@{ type = "text"; text = "ITL_CONTEXT_BENCHMARK_V1: Reply with only OK. Do not call tools." })
                },
                [ordered]@{
                    info = [ordered]@{
                        role = "assistant"; agent = "code"; modelID = $Model; providerID = $Provider; variant = $Variant; cost = 0
                        tokens = [ordered]@{ input = $InputTokens; cache = [ordered]@{ read = $CacheRead; write = $CacheWrite }; output = $Output; reasoning = $Reasoning }
                    }
                    parts = $assistantParts
                }
            )
            if ($ExtraMessage) { $messages += [ordered]@{ info = [ordered]@{ role = "user" }; parts = @([ordered]@{ type = "text"; text = "again" }) } }
            return (($([ordered]@{ info = [ordered]@{}; messages = $messages }) | ConvertTo-Json -Depth 10) | ConvertFrom-Json)
        }
    }

    It "parses JSONC comments trailing commas and comment-like strings" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            ConvertFrom-ItlJsoncText -Text @'
{
  // line comment
  "url": "https://example.test/a/*keep*/",
  "kilo-code.new.browserAutomation.enabled": true,
}
'@
        }
        $result.url | Should -Be "https://example.test/a/*keep*/"
        $result.'kilo-code.new.browserAutomation.enabled' | Should -BeTrue
    }

    It "uses workspace over user and does not modify either settings file" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-kilo-browser-workspace-" + [guid]::NewGuid().ToString("N"))
        try {
            $workspacePath = Join-Path $tempRoot ".vscode\settings.json"
            $userPath = Join-Path $tempRoot "user-settings.json"
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $workspacePath) | Out-Null
            Set-Content -LiteralPath $workspacePath -Encoding UTF8 -Value '{"kilo-code.new.browserAutomation.enabled":true}'
            Set-Content -LiteralPath $userPath -Encoding UTF8 -Value '{"kilo-code.new.browserAutomation.enabled":false}'
            $beforeWorkspace = (Get-FileHash -LiteralPath $workspacePath -Algorithm SHA256).Hash
            $beforeUser = (Get-FileHash -LiteralPath $userPath -Algorithm SHA256).Hash

            $status = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                function Get-ItlActiveClient { return "kilocode" }
                function Get-KiloUserSettingsCandidates { return @($userPath) }
                function Get-KiloExtensionBrowserDefault { return [pscustomobject]@{ state = "disabled"; source = "extension-default"; version = "test" } }
                $output = Write-KiloBrowserAutomationAdvisory -ProjectRoot $tempRoot 6>&1
                [pscustomobject]@{ status = Get-KiloBrowserAutomationStatus -ProjectRoot $tempRoot; output = ($output -join "`n") }
            }

            $status.status.state | Should -Be "enabled"
            $status.status.source | Should -Be "workspace"
            $status.output | Should -Match "thousands of context tokens"
            (Get-FileHash -LiteralPath $workspacePath -Algorithm SHA256).Hash | Should -Be $beforeWorkspace
            (Get-FileHash -LiteralPath $userPath -Algorithm SHA256).Hash | Should -Be $beforeUser
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "reports ambiguous user profiles as unknown and falls back to the extension default only when unambiguous" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-kilo-browser-profiles-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            $first = Join-Path $tempRoot "first.json"
            $second = Join-Path $tempRoot "second.json"
            Set-Content -LiteralPath $first -Encoding UTF8 -Value '{"kilo-code.new.browserAutomation.enabled":true}'
            Set-Content -LiteralPath $second -Encoding UTF8 -Value '{"kilo-code.new.browserAutomation.enabled":false}'
            $ambiguous = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                function Get-ItlActiveClient { return "kilocode" }
                function Get-KiloUserSettingsCandidates { return @($first, $second) }
                Get-KiloBrowserAutomationStatus -ProjectRoot $tempRoot
            }
            $ambiguous.state | Should -Be "unknown"
            $ambiguous.source | Should -Be "user-profile-ambiguous"

            $fallback = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                function Get-ItlActiveClient { return "kilocode" }
                function Get-KiloUserSettingsCandidates { return @() }
                function Get-KiloExtensionBrowserDefault { return [pscustomobject]@{ state = "disabled"; source = "extension-default"; version = "7.4.11" } }
                Get-KiloBrowserAutomationStatus -ProjectRoot $tempRoot
            }
            $fallback.state | Should -Be "disabled"
            $fallback.source | Should -Be "extension-default"
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "stays silent for non-Kilo clients and never lets advisory errors escape" {
        $nonKilo = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            function Get-ItlActiveClient { return "codex" }
            @(Write-KiloBrowserAutomationAdvisory 6>&1)
        }
        @($nonKilo).Count | Should -Be 0

        $failure = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            function Get-KiloBrowserAutomationStatus { throw "fixture" }
            (Write-KiloBrowserAutomationAdvisory 6>&1) -join "`n"
        }
        $failure | Should -Match "unknown"
        $failure | Should -Match "does not change this setting"
    }

    It "wires one advisory into init configuration branch extension branch and status" {
        $text = Get-Content -LiteralPath $LifecyclePath -Raw -Encoding UTF8
        foreach ($functionName in @("Initialize-Project", "New-DevBranch", "New-ExtensionDevBranch", "Show-WorkflowStatus")) {
            $block = [regex]::Match($text, "(?s)function $functionName \{.*?(?=\r?\nfunction )").Value
            $block | Should -Not -BeNullOrEmpty
            ([regex]::Matches($block, 'Write-KiloBrowserAutomationAdvisory')).Count | Should -Be 1 -Because $functionName
        }
    }

    It "calculates prompt-side context tokens for GPT and DeepSeek fixtures" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $gpt = ConvertFrom-KiloBenchmarkSessionExport -Export (New-KiloSessionFixture -InputTokens 24146 -Output 5) -SessionId "ses_gpt" -Surface ide
            $deepSeek = ConvertFrom-KiloBenchmarkSessionExport -Export (New-KiloSessionFixture -InputTokens 31824 -CacheRead 2176 -Output 2 -Reasoning 26 -Model "deepseek-v4-flash") -SessionId "ses_deepseek" -Surface ide
            [pscustomobject]@{ gpt = $gpt; deepSeek = $deepSeek }
        }
        $result.gpt.tokens.context | Should -Be 24146
        $result.gpt.tokens.output | Should -Be 5
        $result.deepSeek.tokens.context | Should -Be 34000
        $result.deepSeek.tokens.reasoning | Should -Be 26
    }

    It "rejects tool calls multi-step transcripts and incompatible comparisons" {
        & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            { ConvertFrom-KiloBenchmarkSessionExport -Export (New-KiloSessionFixture -ToolCall) -SessionId "ses_tool" -Surface ide } | Should -Throw "*KILO_CONTEXT_BENCHMARK_TOOL_CALL*"
            { ConvertFrom-KiloBenchmarkSessionExport -Export (New-KiloSessionFixture -ExtraMessage) -SessionId "ses_multi" -Surface ide } | Should -Throw "*KILO_CONTEXT_BENCHMARK_MULTI_STEP*"
            $wrongPrompt = New-KiloSessionFixture
            $wrongPrompt.messages[0].parts[0].text = "Reply with only OK"
            { ConvertFrom-KiloBenchmarkSessionExport -Export $wrongPrompt -SessionId "ses_prompt" -Surface ide } | Should -Throw "*KILO_CONTEXT_BENCHMARK_PROMPT_INVALID*"
            $baseline = ConvertFrom-KiloBenchmarkSessionExport -Export (New-KiloSessionFixture -Model "one") -SessionId "ses_one" -Surface ide
            $candidate = ConvertFrom-KiloBenchmarkSessionExport -Export (New-KiloSessionFixture -Model "two") -SessionId "ses_two" -Surface ide
            { Compare-KiloContextBenchmarkSummaries -Baseline $baseline -Candidate $candidate } | Should -Throw "*KILO_CONTEXT_BENCHMARK_INCOMPATIBLE*"
        }
    }

    It "saves an anonymized summary without transcript tool arguments URLs or secrets" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-kilo-context-summary-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            $saved = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                function Ensure-KiloContextBenchmarkIgnored { }
                $summary = ConvertFrom-KiloBenchmarkSessionExport -Export (New-KiloSessionFixture) -SessionId "ses_privacy" -Surface ide -Label "browser-off"
                Save-KiloContextBenchmarkSummary -Summary $summary -Prefix "privacy"
            }
            $json = Get-Content -LiteralPath $saved -Raw -Encoding UTF8
            $json | Should -Not -Match "Reply with only OK"
            $json | Should -Not -Match 'https?://'
            $json | Should -Not -Match 'arguments|secret'
            ($json | ConvertFrom-Json).tokens.context | Should -Be 100
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "discovers the newest extension CLI and requires explicit run confirmation" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-kilo-context-cli-" + [guid]::NewGuid().ToString("N"))
        try {
            $bin = Join-Path $tempRoot "bin"
            New-Item -ItemType Directory -Force -Path $bin | Out-Null
            $exe = Join-Path $bin "kilo.exe"
            Set-Content -LiteralPath $exe -Encoding ASCII -Value "fixture"
            $result = & {
                . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
                function Get-Command { return $null }
                function Get-KiloExtensionPackageCandidates { return @([pscustomobject]@{ directory = $tempRoot; version = [version]"99.0" }) }
                $script:BenchmarkModel = "provider/model"
                $script:ConfirmTokenSpend = $false
                $resolved = Resolve-KiloExecutable
                $confirmation = ""
                try { Invoke-KiloContextBenchmarkRun -Executable $resolved } catch { $confirmation = $_.Exception.Message }
                [pscustomobject]@{ executable = $resolved; confirmation = $confirmation }
            }
            $result.executable | Should -Be $exe
            $result.confirmation | Should -Match "KILO_CONTEXT_BENCHMARK_CONFIRM_REQUIRED"
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "completes a confirmed CLI run after the owned process exits zero" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-kilo-context-run-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $BenchmarkModel = "provider/model"
                $BenchmarkVariant = ""
                $BenchmarkLabel = "fixture"
                $ConfirmTokenSpend = $true
                $script:KiloContextBenchmarkTimeoutSeconds = 1
                $fakeProcess = [pscustomobject]@{ Id = 12345; ExitCode = 0 }
                $fakeProcess | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($Timeout); if ($null -ne $Timeout) { return $true } }
                $fakeProcess | Add-Member -MemberType ScriptMethod -Name Refresh -Value { }
                function Start-Process {
                    param($FilePath, $ArgumentList, $WorkingDirectory, $RedirectStandardOutput, $RedirectStandardError, [switch]$PassThru, [string]$WindowStyle)
                    return $fakeProcess
                }
                function Get-Agent1cTempRoot { return $tempRoot }
                function Invoke-KiloJsonCapture {
                    param($Executable, [string[]]$Arguments, $WorkingDirectory)
                    $searchIndex = [array]::IndexOf($Arguments, "--search")
                    return @([pscustomobject]@{ id = "ses_fixture"; title = [string]$Arguments[$searchIndex + 1] })
                }
                function Get-KiloSessionExport { param($Executable, $SessionId); return (New-KiloSessionFixture) }
                function Add-KiloContextBenchmarkEnvironment { param($Summary, $Executable); return $Summary }
                $originalPrompt = $script:KiloContextBenchmarkPrompt
                $summary = Invoke-KiloContextBenchmarkRun -Executable "fixture-kilo.exe"
                [pscustomobject]@{ surface = $summary.surface; context = $summary.tokens.context; prompt = $originalPrompt }
            }
            $result.surface | Should -Be "cli"
            $result.context | Should -Be 100
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "keeps the benchmark action read-only and does not add a slash command" {
        $helperText = Get-Content -LiteralPath $HelperPath -Raw -Encoding UTF8
        $coreText = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.core.ps1") -Raw -Encoding UTF8
        $helperText | Should -Match '"context-benchmark" \{ Invoke-KiloContextBenchmark \}'
        $coreText | Should -Match '"context-benchmark"'
        @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\kilo-command-templates") -Recurse -File | Where-Object { $_.Name -match 'context.*benchmark' }).Count | Should -Be 0
    }
}
