Describe "controlled ai_rules_1c release overlay" {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        $RepoRoot = $context.RepoRoot
        $BuilderPath = Join-Path $RepoRoot "scripts\build-ai-rules-release.ps1"
        $Utf8NoBom = New-Object Text.UTF8Encoding $false

        function Get-NormalizedTextSha256 {
            param([string]$Text)
            $sha = [Security.Cryptography.SHA256]::Create()
            try {
                $bytes = $Utf8NoBom.GetBytes($Text.Replace("`r`n", "`n"))
                return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
            }
            finally {
                $sha.Dispose()
            }
        }
    }

    It "prepares unaffected downstream paths and verifies every upstream path decision" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-ai-overlay-" + [guid]::NewGuid().ToString("N"))
        $forkRoot = Join-Path $tempRoot "fork"
        $overlayRoot = Join-Path $tempRoot "overlay"
        try {
            New-Item -ItemType Directory -Force -Path $forkRoot, $overlayRoot, (Join-Path $forkRoot "content") | Out-Null
            & git -C $forkRoot init *> $null
            & git -C $forkRoot config user.email "tests@example.invalid"
            & git -C $forkRoot config user.name "ITL Tests"
            [IO.File]::WriteAllText((Join-Path $forkRoot "AGENTS.md"), "# Root`nupstream`n", $Utf8NoBom)
            [IO.File]::WriteAllText((Join-Path $forkRoot "USER-RULES.md"), "# User rules`nupstream`n", $Utf8NoBom)
            [IO.File]::WriteAllText((Join-Path $forkRoot "base.txt"), "old upstream`n", $Utf8NoBom)
            [IO.File]::WriteAllText((Join-Path $forkRoot "content\owner.md"), "owner`n", $Utf8NoBom)
            & git -C $forkRoot add .
            & git -C $forkRoot commit -m upstream *> $null
            $oldUpstream = (& git -C $forkRoot rev-parse HEAD).Trim()

            & git -C $forkRoot switch -q -c baseline-release *> $null
            [IO.File]::WriteAllText((Join-Path $forkRoot "USER-RULES.md"), "# User rules`nold downstream routing`n", $Utf8NoBom)
            [IO.File]::WriteAllText((Join-Path $forkRoot "base.txt"), "old downstream`n", $Utf8NoBom)
            [IO.File]::WriteAllText((Join-Path $forkRoot "content\new-owner.md"), "new owner`n", $Utf8NoBom)
            & git -C $forkRoot add .
            & git -C $forkRoot commit -m downstream *> $null
            $baselineRelease = (& git -C $forkRoot rev-parse HEAD).Trim()

            & git -C $forkRoot switch -q -c new-upstream $oldUpstream *> $null
            [IO.File]::WriteAllText((Join-Path $forkRoot "base.txt"), "new upstream`n", $Utf8NoBom)
            & git -C $forkRoot add base.txt
            & git -C $forkRoot commit -m upstream-change *> $null
            $newUpstream = (& git -C $forkRoot rev-parse HEAD).Trim()
            & git -C $forkRoot switch -q -c release/test $newUpstream *> $null

            $manifest = [ordered]@{
                schemaVersion = 2
                baselineUpstreamCommit = $oldUpstream
                baselineReleaseCommit = $baselineRelease
                intakeUpstreamCommit = $newUpstream
                targetPath = "AGENTS.md"
                maximumTargetCharacters = 20000
                additionalTargets = @(
                    [ordered]@{
                        path = "USER-RULES.md"
                        template = "USER-RULES.md"
                        maximumCharacters = 1000
                        requiredAnchors = @("direct full-cycle")
                    }
                )
                requiredUpstreamAnchors = @("upstream")
                requiredTargetAnchors = @("completion gate")
                additionalDownstreamPaths = @()
                pathDecisions = @(
                    [ordered]@{
                        path = "base.txt"
                        disposition = "resolved"
                        reason = "Merge the upstream change with the downstream behavior."
                        upstreamSha256 = Get-NormalizedTextSha256 "new upstream`n"
                        resultSha256 = Get-NormalizedTextSha256 "resolved`n"
                    }
                )
            }
            [IO.File]::WriteAllText((Join-Path $overlayRoot "sections.json"), (($manifest | ConvertTo-Json -Depth 8) + "`n"), $Utf8NoBom)
            [IO.File]::WriteAllText((Join-Path $overlayRoot "AGENTS.md"), "# Root`ncompact completion gate`n", $Utf8NoBom)
            [IO.File]::WriteAllText((Join-Path $overlayRoot "USER-RULES.md"), "# User rules`ndirect full-cycle`n", $Utf8NoBom)
            $reportPath = Join-Path $tempRoot "report.json"

            & $BuilderPath -AiRulesRoot $forkRoot -UpstreamCommit $newUpstream -OverlayRoot $overlayRoot -ReportPath $reportPath -Mode Prepare
            (Test-Path -LiteralPath (Join-Path $forkRoot "content\new-owner.md") -PathType Leaf) | Should -BeTrue
            (Get-Content -LiteralPath (Join-Path $forkRoot "base.txt") -Raw -Encoding UTF8) | Should -Be "new upstream`n"
            (Get-Content -LiteralPath (Join-Path $forkRoot "AGENTS.md") -Raw -Encoding UTF8) | Should -Match "completion gate"
            (Get-Content -LiteralPath (Join-Path $forkRoot "USER-RULES.md") -Raw -Encoding UTF8) | Should -Match "direct full-cycle"
            (Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8 | ConvertFrom-Json).pendingResolvedPaths | Should -Contain "base.txt"

            [IO.File]::WriteAllText((Join-Path $forkRoot "base.txt"), "resolved`n", $Utf8NoBom)
            & git -C $forkRoot add .
            & git -C $forkRoot commit -m resolved *> $null
            & $BuilderPath -AiRulesRoot $forkRoot -UpstreamCommit $newUpstream -OverlayRoot $overlayRoot -ReportPath $reportPath -CheckOnly
            (Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8 | ConvertFrom-Json).status | Should -Be "verified"
            $headBefore = (& git -C $forkRoot rev-parse HEAD).Trim()
            & $BuilderPath -AiRulesRoot $forkRoot -UpstreamCommit $newUpstream -OverlayRoot $overlayRoot -ReportPath $reportPath -Mode Verify
            (& git -C $forkRoot rev-parse HEAD).Trim() | Should -Be $headBefore
            (& git -C $forkRoot status --porcelain) | Should -BeNullOrEmpty

            $manifest.pathDecisions = @()
            [IO.File]::WriteAllText((Join-Path $overlayRoot "sections.json"), (($manifest | ConvertTo-Json -Depth 8) + "`n"), $Utf8NoBom)
            { & $BuilderPath -AiRulesRoot $forkRoot -UpstreamCommit $newUpstream -OverlayRoot $overlayRoot -ReportPath $reportPath -Mode Verify } |
                Should -Throw "*Unclassified upstream path: base.txt*"

            $manifest.pathDecisions = @(
                [ordered]@{
                    path = "base.txt"
                    disposition = "resolved"
                    reason = "Merge the upstream change with the downstream behavior."
                    upstreamSha256 = Get-NormalizedTextSha256 "new upstream`n"
                    resultSha256 = Get-NormalizedTextSha256 "wrong result`n"
                }
            )
            [IO.File]::WriteAllText((Join-Path $overlayRoot "sections.json"), (($manifest | ConvertTo-Json -Depth 8) + "`n"), $Utf8NoBom)
            { & $BuilderPath -AiRulesRoot $forkRoot -UpstreamCommit $newUpstream -OverlayRoot $overlayRoot -ReportPath $reportPath -Mode Verify } |
                Should -Throw "*Result SHA-256 mismatch for 'base.txt'*"
        }
        finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "routes structural Form.xml edits through the specialized tool" {
        $agentsText = Get-Content -LiteralPath (Join-Path $RepoRoot "templates\ai-rules-overlay\AGENTS.md") -Raw -Encoding UTF8
        foreach ($marker in @(
            'existing `Form.xml` must use `1c-form-edit`',
            'never a manual one-line fix',
            'state why the form tool does not apply before editing'
        )) {
            $agentsText | Should -Match ([regex]::Escape($marker))
        }
    }

    It "keeps eligible local BSL fixes on quick-fix without weakening completion" {
        $agentsText = Get-Content -LiteralPath (Join-Path $RepoRoot "templates\ai-rules-overlay\AGENTS.md") -Raw -Encoding UTF8
        foreach ($marker in @(
            'An internal BSL fix that preserves public contracts may remain a quick-fix',
            'do not promote it solely because it corrects existing behavior',
            'relevant Vanessa coverage exists or was updated',
            'a fresh successful `/itl-check` completed after the last change'
        )) {
            $agentsText | Should -Match ([regex]::Escape($marker))
        }
        $agentsText | Should -Not -Match 'public APIs.*changes to existing behavior always promote'
    }

    It "keeps full-cycle execution separate from OpenSpec planning" {
        $agentsText = Get-Content -LiteralPath (Join-Path $RepoRoot "templates\ai-rules-overlay\AGENTS.md") -Raw -Encoding UTF8
        $forkUserRulesText = Get-Content -LiteralPath (Join-Path $RepoRoot "templates\ai-rules-overlay\USER-RULES.md") -Raw -Encoding UTF8
        $projectUserRulesText = Get-Content -LiteralPath (Join-Path $RepoRoot "templates\USER-RULES.append.md") -Raw -Encoding UTF8
        $agentsText | Should -Match 'Full-cycle is not OpenSpec'
        foreach ($text in @($forkUserRulesText, $projectUserRulesText)) {
            $text | Should -Match ([regex]::Escape('executionPath=quick-fix|full-cycle'))
            $text | Should -Match ([regex]::Escape('planningMode=direct|OpenSpec'))
            $text | Should -Match 'Promotion triggers.*never force OpenSpec'
        }
        $projectUserRulesText | Should -Not -Match 'classify each code/metadata edit as quick-fix or OpenSpec'
    }
}
