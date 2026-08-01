Describe "ai_rules compatibility promotion" {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        $RepoRoot = $context.RepoRoot
        $PromoterPath = Join-Path $RepoRoot 'scripts\promote-ai-rules-compatibility.ps1'
        $Utf8NoBom = New-Object Text.UTF8Encoding $false
    }

    It "parses and requires a clean exact Full qualification" {
        $tokens = $null
        $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile($PromoterPath, [ref]$tokens, [ref]$errors)
        @($errors) | Should -BeNullOrEmpty
        $text = Get-Content -LiteralPath $PromoterPath -Raw -Encoding UTF8
        $text | Should -Match 'status --porcelain --untracked-files=no'
        $text | Should -Match 'repository\.commit -ne \$head'
        $text | Should -Match 'forkQualificationHash'
        $text | Should -Match 'compatibilityCheckedAt cannot precede'
    }

    It "promotes only the two aiRules1c lock fields without reformatting the file" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-ai-promotion-" + [guid]::NewGuid().ToString('N'))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot 'templates'), (Join-Path $tempRoot 'build\test-results\qualification') | Out-Null
            & git -C $tempRoot init *> $null
            & git -C $tempRoot config user.email 'tests@example.invalid'
            & git -C $tempRoot config user.name 'ITL Tests'
            $lockPath = Join-Path $tempRoot 'templates\dependency-lock.json'
            $lockText = @'
{
  "schemaVersion": 1,
  "dependencies": {
    "aiRules1c": {
      "repo": "https://github.com/xmentosx/itl_ai_rules_1c.git",
      "ref": "itl-main-fixture-r21",
      "commit": "1111111111111111111111111111111111111111",
      "upstreamRef": "refs/heads/main",
      "upstreamCommit": "2222222222222222222222222222222222222222",
      "compatibilityStatus": "pending",
      "compatibilityCheckedAt": ""
    }
  }
}
'@
            [IO.File]::WriteAllText($lockPath, $lockText, $Utf8NoBom)
            [IO.File]::WriteAllText((Join-Path $tempRoot '.gitignore'), "build/`n", $Utf8NoBom)
            & git -C $tempRoot add .
            & git -C $tempRoot commit -m pending *> $null
            $head = (& git -C $tempRoot rev-parse HEAD).Trim()
            $tree = (& git -C $tempRoot rev-parse 'HEAD^{tree}').Trim()

            $forkQualificationPath = Join-Path $tempRoot 'build\test-results\qualification\fork.json'
            [IO.File]::WriteAllText($forkQualificationPath, "{`"status`":`"passed`"}`n", $Utf8NoBom)
            $forkHash = (Get-FileHash -LiteralPath $forkQualificationPath -Algorithm SHA256).Hash.ToLowerInvariant()
            $qualification = [ordered]@{
                kind = 'itl-workflow-full-qualification'; status = 'passed'; reusable = $true
                repository = [ordered]@{ commit = $head; tree = $tree; worktreeClean = $true }
                fork = [ordered]@{
                    repo = 'https://github.com/xmentosx/itl_ai_rules_1c.git'; tag = 'itl-main-fixture-r21'
                    commit = '1111111111111111111111111111111111111111'; upstreamRef = 'refs/heads/main'
                    upstreamCommit = '2222222222222222222222222222222222222222'
                    qualificationPath = $forkQualificationPath; qualificationSha256 = $forkHash
                }
                result = [ordered]@{ passed = 1; failed = 0; skipped = 0 }
                finishedAt = '2026-08-01T10:00:00Z'
            }
            $qualificationPath = Join-Path $tempRoot 'build\test-results\qualification\full.json'
            [IO.File]::WriteAllText($qualificationPath, (($qualification | ConvertTo-Json -Depth 8) + "`n"), $Utf8NoBom)

            $output = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $PromoterPath `
                -RepositoryRoot $tempRoot -QualificationPath $qualificationPath `
                -LockPath $lockPath -CheckedAt '2026-08-01T10:01:00Z' 2>&1 | Out-String
            $LASTEXITCODE | Should -Be 0 -Because $output
            $updated = [IO.File]::ReadAllText($lockPath, [Text.Encoding]::UTF8)
            $updated | Should -Be ($lockText.Replace('"compatibilityStatus": "pending"', '"compatibilityStatus": "passed"').Replace('"compatibilityCheckedAt": ""', '"compatibilityCheckedAt": "2026-08-01T10:01:00Z"'))
        }
        finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
