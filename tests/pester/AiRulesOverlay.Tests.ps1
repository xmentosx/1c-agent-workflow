Describe "controlled ai_rules_1c release overlay" {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        $RepoRoot = $context.RepoRoot
        $BuilderPath = Join-Path $RepoRoot "scripts\build-ai-rules-release.ps1"
        $Utf8NoBom = New-Object Text.UTF8Encoding $false
    }

    It "rebuilds idempotently and blocks added sections or touched downstream paths" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-ai-overlay-" + [guid]::NewGuid().ToString("N"))
        $forkRoot = Join-Path $tempRoot "fork"
        $overlayRoot = Join-Path $tempRoot "overlay"
        try {
            New-Item -ItemType Directory -Force -Path $forkRoot, $overlayRoot, (Join-Path $forkRoot "content") | Out-Null
            & git -C $forkRoot init *> $null
            & git -C $forkRoot config user.email "tests@example.invalid"
            & git -C $forkRoot config user.name "ITL Tests"
            [IO.File]::WriteAllText((Join-Path $forkRoot "AGENTS.md"), "# Root`n`n# Process`nold`n", $Utf8NoBom)
            [IO.File]::WriteAllText((Join-Path $forkRoot "base.txt"), "upstream`n", $Utf8NoBom)
            [IO.File]::WriteAllText((Join-Path $forkRoot "content\owner.md"), "owner`n", $Utf8NoBom)
            & git -C $forkRoot add .
            & git -C $forkRoot commit -m upstream *> $null
            $upstream = (& git -C $forkRoot rev-parse HEAD).Trim()

            & git -C $forkRoot switch -q -c baseline-release *> $null
            [IO.File]::WriteAllText((Join-Path $forkRoot "base.txt"), "downstream`n", $Utf8NoBom)
            [IO.File]::WriteAllText((Join-Path $forkRoot "content\new-owner.md"), "new owner`n", $Utf8NoBom)
            & git -C $forkRoot add .
            & git -C $forkRoot commit -m downstream *> $null
            $release = (& git -C $forkRoot rev-parse HEAD).Trim()
            & git -C $forkRoot switch -q -c release/test $upstream *> $null

            $sourceText = (& git -C $forkRoot show "$upstream`:AGENTS.md") -join "`n"
            $sourceText += "`n"
            $matches = [regex]::Matches($sourceText, '(?m)^# ([^#\r\n].*)$')
            $sections = @()
            for ($index = 0; $index -lt $matches.Count; $index++) {
                $start = $matches[$index].Index
                $end = if (($index + 1) -lt $matches.Count) { $matches[$index + 1].Index } else { $sourceText.Length }
                $sectionText = $sourceText.Substring($start, $end - $start)
                $sha = [Security.Cryptography.SHA256]::Create()
                try { $hash = ([BitConverter]::ToString($sha.ComputeHash($Utf8NoBom.GetBytes($sectionText)))).Replace('-', '').ToLowerInvariant() } finally { $sha.Dispose() }
                $sections += [ordered]@{ heading = $matches[$index].Groups[1].Value; sha256 = $hash; disposition = "rewrite"; owner = $(if ($index -eq 0) { "content/owner.md" } else { "content/new-owner.md" }) }
            }
            $manifest = [ordered]@{
                schemaVersion = 1
                baselineUpstreamCommit = $upstream
                baselineReleaseCommit = $release
                targetPath = "AGENTS.md"
                maximumTargetCharacters = 20000
                downstreamPatch = [ordered]@{ disposition = "rewrite"; excludePaths = @("AGENTS.md") }
                sections = $sections
                requiredUpstreamAnchors = @()
                requiredTargetAnchors = @("completion gate")
            }
            [IO.File]::WriteAllText((Join-Path $overlayRoot "sections.json"), (($manifest | ConvertTo-Json -Depth 8) + "`n"), $Utf8NoBom)
            [IO.File]::WriteAllText((Join-Path $overlayRoot "AGENTS.md"), "# Root`n`ncompact completion gate`n`n# Process`n`nrouted`n", $Utf8NoBom)
            $reportPath = Join-Path $tempRoot "report.json"

            & $BuilderPath -AiRulesRoot $forkRoot -UpstreamCommit $upstream -OverlayRoot $overlayRoot -ReportPath $reportPath
            (Get-Content -LiteralPath (Join-Path $forkRoot "base.txt") -Raw -Encoding UTF8).Trim() | Should -Be "downstream"
            (Test-Path -LiteralPath (Join-Path $forkRoot "content\new-owner.md") -PathType Leaf) | Should -BeTrue
            (Get-Content -LiteralPath (Join-Path $forkRoot "AGENTS.md") -Raw -Encoding UTF8) | Should -Match 'compact completion gate'
            $firstHashes = @(Get-FileHash -LiteralPath (Join-Path $forkRoot "AGENTS.md"), (Join-Path $forkRoot "base.txt"), (Join-Path $forkRoot "content\new-owner.md") | Select-Object -ExpandProperty Hash)
            & $BuilderPath -AiRulesRoot $forkRoot -UpstreamCommit $upstream -OverlayRoot $overlayRoot -ReportPath $reportPath
            $secondHashes = @(Get-FileHash -LiteralPath (Join-Path $forkRoot "AGENTS.md"), (Join-Path $forkRoot "base.txt"), (Join-Path $forkRoot "content\new-owner.md") | Select-Object -ExpandProperty Hash)
            $secondHashes | Should -Be $firstHashes

            & git -C $forkRoot reset --hard $upstream *> $null
            & git -C $forkRoot switch -q -C upstream-added $upstream *> $null
            [IO.File]::AppendAllText((Join-Path $forkRoot "AGENTS.md"), "`n# New upstream section`nnew`n", $Utf8NoBom)
            & git -C $forkRoot add AGENTS.md
            & git -C $forkRoot commit -m added *> $null
            $addedUpstream = (& git -C $forkRoot rev-parse HEAD).Trim()
            & git -C $forkRoot switch -q -c release/added *> $null
            { & $BuilderPath -AiRulesRoot $forkRoot -UpstreamCommit $addedUpstream -OverlayRoot $overlayRoot -ReportPath $reportPath } | Should -Throw '*added unclassified section*'
            @((Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8 | ConvertFrom-Json).sections | Where-Object state -eq "added").Count | Should -Be 1

            & git -C $forkRoot switch -q -C upstream-drift $upstream *> $null
            [IO.File]::WriteAllText((Join-Path $forkRoot "base.txt"), "upstream changed`n", $Utf8NoBom)
            & git -C $forkRoot add base.txt
            & git -C $forkRoot commit -m drift *> $null
            $driftUpstream = (& git -C $forkRoot rev-parse HEAD).Trim()
            & git -C $forkRoot switch -q -c release/drift *> $null
            { & $BuilderPath -AiRulesRoot $forkRoot -UpstreamCommit $driftUpstream -OverlayRoot $overlayRoot -ReportPath $reportPath } | Should -Throw '*downstream-owned path*'
            ((Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8 | ConvertFrom-Json).downstreamPaths | Where-Object state -eq "changed").path | Should -Contain "base.txt"
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
