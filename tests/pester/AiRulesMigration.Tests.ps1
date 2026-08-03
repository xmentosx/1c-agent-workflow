BeforeAll {
    . (Join-Path $PSScriptRoot "TestSupport.ps1")
    $context = Initialize-WorkflowPesterContext
    $RepoRoot = $context.RepoRoot
    $HelperPath = $context.HelperPath
    $script:TargetAiRulesRef = "itl-main-410951e7-r22"
    $script:TargetAiRulesCommit = "bcd94d1723f26a0b0568869845484c8572c402a6"
    $script:TargetAiRulesRevision = 22

    function New-AiRulesMigrationFixture {
        param(
            [string]$Root,
            [string]$CurrentRepo = "https://github.com/comol/ai_rules_1c.git",
            [string]$CurrentRef = "",
            [string]$CurrentCommit = "a421cf44eb1f5859cf2a2b74884f8fbcaefc4826",
            [string]$CurrentUpstreamCommit = "",
            [int]$CurrentDownstreamRevision = 0,
            [string]$CurrentTool = "codex",
            [bool]$UserModified = $false,
            [bool]$ConfigureTarget = $true
        )

        New-Item -ItemType Directory -Force -Path (Join-Path $Root ".agent-1c"), (Join-Path $Root "templates") | Out-Null
        $config = [ordered]@{
            dependencyMode = "fresh"
            aiRules = [ordered]@{ repo = $CurrentRepo; ref = $CurrentRef; tools = @($CurrentTool) }
        }
        $targetConfig = [ordered]@{
            aiRules = [ordered]@{
                repo = "https://github.com/xmentosx/itl_ai_rules_1c.git"
                ref = $(if ($ConfigureTarget) { $script:TargetAiRulesRef } else { "" })
                tools = @($CurrentTool)
            }
        }
        $targetEntry = [ordered]@{
            repo = "https://github.com/xmentosx/itl_ai_rules_1c.git"
            ref = $script:TargetAiRulesRef
            commit = $script:TargetAiRulesCommit
            upstreamRepo = "https://github.com/comol/ai_rules_1c.git"
            upstreamRef = "refs/heads/main"
            upstreamCommit = "410951e74fd3e6b7a763cf49757935b9a34d3f31"
            downstreamRevision = $script:TargetAiRulesRevision
            compatibilityStatus = $(if ($ConfigureTarget) { "passed" } else { "legacy-baseline" })
            compatibilityCheckedAt = "2026-07-11T00:00:00Z"
        }
        $targetLock = [ordered]@{ schemaVersion = 1; mode = "fresh"; dependencies = [ordered]@{ aiRules1c = $targetEntry } }
        $currentLock = [ordered]@{
            schemaVersion = 1
            mode = "fresh"
            dependencies = [ordered]@{
                aiRules1c = [ordered]@{
                    repo = $CurrentRepo
                    ref = $(if ($CurrentRef) { $CurrentRef } else { "main" })
                    commit = $CurrentCommit
                    upstreamCommit = $CurrentUpstreamCommit
                    downstreamRevision = $CurrentDownstreamRevision
                }
            }
        }
        $manifest = [ordered]@{
            tools = @($CurrentTool)
            files = [ordered]@{
                ".codex/rules/example.md" = [ordered]@{ source = "content/rules/example.md"; installedHash = "fixture"; userModified = $UserModified }
            }
        }
        Set-Content -LiteralPath (Join-Path $Root ".agent-1c\project.json") -Encoding UTF8 -Value ($config | ConvertTo-Json -Depth 10)
        Set-Content -LiteralPath (Join-Path $Root ".agent-1c\dependency-lock.json") -Encoding UTF8 -Value ($currentLock | ConvertTo-Json -Depth 10)
        Set-Content -LiteralPath (Join-Path $Root "templates\project.json") -Encoding UTF8 -Value ($targetConfig | ConvertTo-Json -Depth 10)
        Set-Content -LiteralPath (Join-Path $Root "templates\dependency-lock.json") -Encoding UTF8 -Value ($targetLock | ConvertTo-Json -Depth 10)
        Set-Content -LiteralPath (Join-Path $Root ".ai-rules.json") -Encoding UTF8 -Value ($manifest | ConvertTo-Json -Depth 10)
    }
}

Describe "ai_rules_1c migration planning" {
    It "stays dormant until a verified fork baseline is configured" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-ai-migration-dormant-" + [guid]::NewGuid().ToString("N"))
        try {
            New-AiRulesMigrationFixture -Root $tempRoot -ConfigureTarget $false
            $plan = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                Get-AiRulesMigrationPlan
            }
            $plan.status | Should -Be "dormant"
            $plan.eligible | Should -BeFalse
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "preserves a custom repository and blocks user-modified legacy migration" {
        $customRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-ai-migration-custom-" + [guid]::NewGuid().ToString("N"))
        $modifiedRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-ai-migration-modified-" + [guid]::NewGuid().ToString("N"))
        $controlledModifiedRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-ai-migration-controlled-modified-" + [guid]::NewGuid().ToString("N"))
        try {
            New-AiRulesMigrationFixture -Root $customRoot -CurrentRepo "https://example.invalid/custom-rules.git"
            New-AiRulesMigrationFixture -Root $modifiedRoot -UserModified $true
            New-AiRulesMigrationFixture -Root $controlledModifiedRoot `
                -CurrentRepo "https://github.com/xmentosx/itl_ai_rules_1c.git" -CurrentRef "itl-main-a421cf44-r1" `
                -CurrentCommit "dc9a767f0cb77418bcae3c52521594b183c1b879" `
                -CurrentUpstreamCommit "a421cf44eb1f5859cf2a2b74884f8fbcaefc4826" -CurrentDownstreamRevision 1 -UserModified $true
            $customPlan = & { . $HelperPath -ProjectRoot $customRoot -Action help *> $null; Get-AiRulesMigrationPlan }
            $modifiedPlan = & { . $HelperPath -ProjectRoot $modifiedRoot -Action help *> $null; Get-AiRulesMigrationPlan }
            $controlledModifiedPlan = & { . $HelperPath -ProjectRoot $controlledModifiedRoot -Action help *> $null; Get-AiRulesMigrationPlan }
            $customPlan.status | Should -Be "custom"
            $customPlan.suppressRegularUpdate | Should -BeTrue
            $modifiedPlan.status | Should -Be "user-modified"
            $modifiedPlan.suppressRegularUpdate | Should -BeTrue
            $controlledModifiedPlan.status | Should -Be "user-modified"
        } finally {
            Remove-Item -LiteralPath $customRoot, $modifiedRoot, $controlledModifiedRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "does not treat the workflow-owned dev env as controlled-fork user drift" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-ai-migration-dev-env-" + [guid]::NewGuid().ToString("N"))
        try {
            New-AiRulesMigrationFixture -Root $tempRoot `
                -CurrentRepo "https://github.com/xmentosx/itl_ai_rules_1c.git" -CurrentRef "itl-main-a421cf44-r7" `
                -CurrentCommit "dc9a767f0cb77418bcae3c52521594b183c1b879" `
                -CurrentUpstreamCommit "a421cf44eb1f5859cf2a2b74884f8fbcaefc4826" -CurrentDownstreamRevision 7
            $manifestPath = Join-Path $tempRoot ".ai-rules.json"
            $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
            $manifest.files | Add-Member -NotePropertyName ".dev.env" -NotePropertyValue ([pscustomobject]@{ source = "content/root-templates/.dev.env"; installedHash = "upstream"; userModified = $true })
            Set-Content -LiteralPath $manifestPath -Encoding UTF8 -Value ($manifest | ConvertTo-Json -Depth 10)

            $plan = & { . $HelperPath -ProjectRoot $tempRoot -Action help *> $null; Get-AiRulesMigrationPlan }
            $plan.status | Should -Be "eligible"
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "clears a USER-RULES marker when the ITL overlay is the only change from installedHash" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-ai-migration-user-rules-overlay-" + [guid]::NewGuid().ToString("N"))
        try {
            New-AiRulesMigrationFixture -Root $tempRoot `
                -CurrentRepo "https://github.com/xmentosx/itl_ai_rules_1c.git" -CurrentRef "itl-main-72665287-r13" `
                -CurrentCommit "b66569bebf46e0369efa53983fca69368e16d57a" `
                -CurrentUpstreamCommit "72665287e77361aea3aaf866fef163d98f0fabcd" -CurrentDownstreamRevision 13
            $userRulesPath = Join-Path $tempRoot "USER-RULES.md"
            $baseline = "# User Rules`r`n`r`n## Migrated content from a previous setup`r`n`r`n<!-- start of migrated content -->`r`n<!-- end of migrated content -->`r`n"
            [System.IO.File]::WriteAllText($userRulesPath, $baseline, (New-Object System.Text.UTF8Encoding $false))
            $installedHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $userRulesPath).Hash.ToLowerInvariant()
            $installedHash | Should -Be "26d9fa88b4972690f0e62d7faa51af3f312a938813139000065aab03fdf7f04d"
            $overlay = "<!-- ITL-WORKFLOW-USER-RULES:START -->`r`n## 1C Project Lifecycle`r`nManaged by ITL.`r`n<!-- ITL-WORKFLOW-USER-RULES:END -->"
            [System.IO.File]::AppendAllText($userRulesPath, "`r`n$overlay`r`n", (New-Object System.Text.UTF8Encoding $false))

            $manifestPath = Join-Path $tempRoot ".ai-rules.json"
            $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $manifest.files | Add-Member -NotePropertyName "USER-RULES.md" -NotePropertyValue ([pscustomobject]@{
                source = "USER-RULES.md"
                template = $true
                installedHash = $installedHash
                userModified = $true
            })
            Set-Content -LiteralPath $manifestPath -Encoding UTF8 -Value ($manifest | ConvertTo-Json -Depth 10)

            $plan = & { . $HelperPath -ProjectRoot $tempRoot -Action help *> $null; Get-AiRulesMigrationPlan }
            $plan.status | Should -Be "eligible"
            $updatedManifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $updatedManifest.files.'USER-RULES.md'.userModified | Should -BeFalse
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "keeps USER-RULES blocking when content outside the ITL overlay changed" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-ai-migration-user-rules-custom-" + [guid]::NewGuid().ToString("N"))
        try {
            New-AiRulesMigrationFixture -Root $tempRoot `
                -CurrentRepo "https://github.com/xmentosx/itl_ai_rules_1c.git" -CurrentRef "itl-main-72665287-r13" `
                -CurrentCommit "b66569bebf46e0369efa53983fca69368e16d57a" `
                -CurrentUpstreamCommit "72665287e77361aea3aaf866fef163d98f0fabcd" -CurrentDownstreamRevision 13
            $userRulesPath = Join-Path $tempRoot "USER-RULES.md"
            $baseline = "# User Rules`r`n"
            [System.IO.File]::WriteAllText($userRulesPath, $baseline, (New-Object System.Text.UTF8Encoding $false))
            $installedHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $userRulesPath).Hash.ToLowerInvariant()
            $overlay = "<!-- ITL-WORKFLOW-USER-RULES:START -->`r`n## 1C Project Lifecycle`r`nManaged by ITL.`r`n<!-- ITL-WORKFLOW-USER-RULES:END -->"
            [System.IO.File]::WriteAllText($userRulesPath, ($baseline + "Keep my custom rule.`r`n`r`n" + $overlay + "`r`n"), (New-Object System.Text.UTF8Encoding $false))

            $manifestPath = Join-Path $tempRoot ".ai-rules.json"
            $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $manifest.files | Add-Member -NotePropertyName "USER-RULES.md" -NotePropertyValue ([pscustomobject]@{
                source = "USER-RULES.md"
                template = $true
                installedHash = $installedHash
                userModified = $true
            })
            Set-Content -LiteralPath $manifestPath -Encoding UTF8 -Value ($manifest | ConvertTo-Json -Depth 10)

            $plan = & { . $HelperPath -ProjectRoot $tempRoot -Action help *> $null; Get-AiRulesMigrationPlan }
            $plan.status | Should -Be "user-modified"
            $updatedManifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $updatedManifest.files.'USER-RULES.md'.userModified | Should -BeTrue
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "clears a USER-RULES marker when the ITL overlay replaced an exact legacy controlled-fork section" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-ai-migration-user-rules-controlled-" + [guid]::NewGuid().ToString("N"))
        $sourceRoot = "$tempRoot-source"
        try {
            New-Item -ItemType Directory -Force -Path $sourceRoot | Out-Null
            $prefix = "# User Rules`r`n`r`n## Migrated content from a previous setup`r`n`r`n<!-- start of migrated content -->`r`n<!-- end of migrated content -->`r`n`r`n"
            $legacySource = $prefix + "## ITL hard gates`r`n`r`n- Legacy managed rule.`r`n"
            [IO.File]::WriteAllText((Join-Path $sourceRoot "USER-RULES.md"), $legacySource, (New-Object Text.UTF8Encoding $false))
            & git -C $sourceRoot init *> $null
            & git -C $sourceRoot config user.email "test@example.com"
            & git -C $sourceRoot config user.name "Test User"
            & git -C $sourceRoot add USER-RULES.md
            & git -C $sourceRoot commit -m fixture *> $null
            & git -C $sourceRoot remote add origin "https://github.com/xmentosx/itl_ai_rules_1c.git"
            $currentCommit = (& git -C $sourceRoot rev-parse HEAD).Trim()
            $currentRef = "itl-main-fixture-r18"

            New-AiRulesMigrationFixture -Root $tempRoot `
                -CurrentRepo "https://github.com/xmentosx/itl_ai_rules_1c.git" -CurrentRef $currentRef `
                -CurrentCommit $currentCommit -CurrentUpstreamCommit "5ae333ed49dc66989e305b286acc93691bb96926" -CurrentDownstreamRevision 18
            $overlay = "<!-- ITL-WORKFLOW-USER-RULES:START -->`r`n## 1C Project Lifecycle`r`nManaged by ITL.`r`n<!-- ITL-WORKFLOW-USER-RULES:END -->"
            [IO.File]::WriteAllText((Join-Path $tempRoot "USER-RULES.md"), ($prefix + $overlay + "`r`n"), (New-Object Text.UTF8Encoding $false))
            $manifestPath = Join-Path $tempRoot ".ai-rules.json"
            $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $manifest | Add-Member -NotePropertyName source -NotePropertyValue $sourceRoot -Force
            $manifest | Add-Member -NotePropertyName version -NotePropertyValue $currentRef -Force
            $manifest.files | Add-Member -NotePropertyName "USER-RULES.md" -NotePropertyValue ([pscustomobject]@{
                source = "USER-RULES.md"
                template = $true
                installedHash = ("0" * 64)
                userModified = $true
            })
            Set-Content -LiteralPath $manifestPath -Encoding UTF8 -Value ($manifest | ConvertTo-Json -Depth 10)

            $plan = & { . $HelperPath -ProjectRoot $tempRoot -Action help *> $null; Get-AiRulesMigrationPlan }
            $plan.status | Should -Be "eligible"
            $updatedManifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $updatedManifest.files.'USER-RULES.md'.userModified | Should -BeFalse
        } finally {
            Remove-Item -LiteralPath $tempRoot, $sourceRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "clears a USER-RULES marker when the file contains only the ITL overlay" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-ai-migration-user-rules-only-overlay-" + [guid]::NewGuid().ToString("N"))
        try {
            New-AiRulesMigrationFixture -Root $tempRoot
            $userRulesPath = Join-Path $tempRoot "USER-RULES.md"
            $overlay = "<!-- ITL-WORKFLOW-USER-RULES:START -->`r`n## 1C Project Lifecycle`r`nManaged by ITL.`r`n<!-- ITL-WORKFLOW-USER-RULES:END -->"
            [System.IO.File]::WriteAllText($userRulesPath, ($overlay + "`r`n"), (New-Object System.Text.UTF8Encoding $false))

            $manifestPath = Join-Path $tempRoot ".ai-rules.json"
            $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $manifest.files | Add-Member -NotePropertyName "USER-RULES.md" -NotePropertyValue ([pscustomobject]@{
                source = "USER-RULES.md"
                template = $true
                installedHash = "351fddfb4e2fc3cc95642f56ea4e94f9995e9741cd04c85e2ad9595888bcb70e"
                userModified = $true
            })
            Set-Content -LiteralPath $manifestPath -Encoding UTF8 -Value ($manifest | ConvertTo-Json -Depth 10)

            $plan = & { . $HelperPath -ProjectRoot $tempRoot -Action help *> $null; Get-AiRulesMigrationPlan }
            $plan.status | Should -Be "eligible"
            $updatedManifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $updatedManifest.files.'USER-RULES.md'.userModified | Should -BeFalse
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "plans a controlled fork r4 to r19 migration by downstream revision and upstream provenance" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-ai-migration-controlled-" + [guid]::NewGuid().ToString("N"))
        try {
            New-AiRulesMigrationFixture -Root $tempRoot `
                -CurrentRepo "https://github.com/xmentosx/itl_ai_rules_1c.git" `
                -CurrentRef "itl-main-a421cf44-r4" `
                -CurrentCommit "6396b1538339ce1ff025cd6f2a24ccb8ff742e1e" `
                -CurrentUpstreamCommit "a421cf44eb1f5859cf2a2b74884f8fbcaefc4826" `
                -CurrentDownstreamRevision 4
            $plan = & { . $HelperPath -ProjectRoot $tempRoot -Action help *> $null; Get-AiRulesMigrationPlan }
            $plan.status | Should -Be "eligible"
            $plan.sourceKind | Should -Be "controlled-fork"
            $plan.fromCommit | Should -Be "6396b1538339ce1ff025cd6f2a24ccb8ff742e1e"
            $plan.comparisonCommit | Should -Be "a421cf44eb1f5859cf2a2b74884f8fbcaefc4826"
            $plan.fromDownstreamRevision | Should -Be 4
            $plan.target.downstreamRevision | Should -Be $script:TargetAiRulesRevision
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "plans the supported r11 to r19 migration" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-ai-migration-r11-r19-" + [guid]::NewGuid().ToString("N"))
        try {
            New-AiRulesMigrationFixture -Root $tempRoot `
                -CurrentRepo "https://github.com/xmentosx/itl_ai_rules_1c.git" `
                -CurrentRef "itl-main-b4d9875b-r11" `
                -CurrentCommit "af82570afca06c40a9588c8a678bf3665bba4870" `
                -CurrentUpstreamCommit "b4d9875b15c6d93f493035aee51f077126e72a21" `
                -CurrentDownstreamRevision 11
            $plan = & { . $HelperPath -ProjectRoot $tempRoot -Action help *> $null; Get-AiRulesMigrationPlan }
            $plan.status | Should -Be "eligible"
            $plan.fromDownstreamRevision | Should -Be 11
            $plan.target.downstreamRevision | Should -Be $script:TargetAiRulesRevision
            $plan.target.ref | Should -Be $script:TargetAiRulesRef
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "plans r12 to r19 for every supported single-client installation" {
        $clients = @("codex", "kilocode", "claude-code", "cursor", "opencode", "kimi", "qwen", "command-code", "cline", "pi")
        foreach ($client in $clients) {
            $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-ai-migration-r12-r19-$($client.Replace('-', '_'))-" + [guid]::NewGuid().ToString("N"))
            try {
                New-AiRulesMigrationFixture -Root $tempRoot `
                    -CurrentRepo "https://github.com/xmentosx/itl_ai_rules_1c.git" `
                    -CurrentRef "itl-main-72665287-r12" `
                    -CurrentCommit "16e9e44318a79d9e82c12b19e6759cdf6492d9a4" `
                    -CurrentUpstreamCommit "72665287e77361aea3aaf866fef163d98f0fabcd" `
                    -CurrentDownstreamRevision 12 `
                    -CurrentTool $client
                $plan = & { . $HelperPath -ProjectRoot $tempRoot -Action help *> $null; Get-AiRulesMigrationPlan }
                $plan.status | Should -Be "eligible" -Because $client
                $plan.fromDownstreamRevision | Should -Be 12 -Because $client
                $plan.target.downstreamRevision | Should -Be $script:TargetAiRulesRevision -Because $client
                $plan.target.ref | Should -Be $script:TargetAiRulesRef -Because $client
                $plan.target.commit | Should -Be $script:TargetAiRulesCommit -Because $client
            } finally {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "plans r13 to r19 for every supported single-client installation" {
        $clients = @("codex", "kilocode", "claude-code", "cursor", "opencode", "kimi", "qwen", "command-code", "cline", "pi")
        foreach ($client in $clients) {
            $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-ai-migration-r13-r19-$($client.Replace('-', '_'))-" + [guid]::NewGuid().ToString("N"))
            try {
                New-AiRulesMigrationFixture -Root $tempRoot `
                    -CurrentRepo "https://github.com/xmentosx/itl_ai_rules_1c.git" `
                    -CurrentRef "itl-main-72665287-r13" `
                    -CurrentCommit "b66569bebf46e0369efa53983fca69368e16d57a" `
                    -CurrentUpstreamCommit "72665287e77361aea3aaf866fef163d98f0fabcd" `
                    -CurrentDownstreamRevision 13 `
                    -CurrentTool $client
                $plan = & { . $HelperPath -ProjectRoot $tempRoot -Action help *> $null; Get-AiRulesMigrationPlan }
                $plan.status | Should -Be "eligible" -Because $client
                $plan.fromDownstreamRevision | Should -Be 13 -Because $client
                $plan.target.downstreamRevision | Should -Be $script:TargetAiRulesRevision -Because $client
                $plan.target.ref | Should -Be $script:TargetAiRulesRef -Because $client
                $plan.target.commit | Should -Be $script:TargetAiRulesCommit -Because $client
            } finally {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "plans r14 to r19 for every supported single-client installation" {
        $clients = @("codex", "kilocode", "claude-code", "cursor", "opencode", "kimi", "qwen", "command-code", "cline", "pi")
        foreach ($client in $clients) {
            $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-ai-migration-r14-r19-$($client.Replace('-', '_'))-" + [guid]::NewGuid().ToString("N"))
            try {
                New-AiRulesMigrationFixture -Root $tempRoot `
                    -CurrentRepo "https://github.com/xmentosx/itl_ai_rules_1c.git" `
                    -CurrentRef "itl-main-72665287-r14" `
                    -CurrentCommit "0888fcdaf223abf97cfba7450bf38454926ad384" `
                    -CurrentUpstreamCommit "72665287e77361aea3aaf866fef163d98f0fabcd" `
                    -CurrentDownstreamRevision 14 `
                    -CurrentTool $client
                $plan = & { . $HelperPath -ProjectRoot $tempRoot -Action help *> $null; Get-AiRulesMigrationPlan }
                $plan.status | Should -Be "eligible" -Because $client
                $plan.fromDownstreamRevision | Should -Be 14 -Because $client
                $plan.target.downstreamRevision | Should -Be $script:TargetAiRulesRevision -Because $client
                $plan.target.ref | Should -Be $script:TargetAiRulesRef -Because $client
                $plan.target.commit | Should -Be $script:TargetAiRulesCommit -Because $client
            } finally {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "plans r15 to r19 for every supported single-client installation" {
        $clients = @("codex", "kilocode", "claude-code", "cursor", "opencode", "kimi", "qwen", "command-code", "cline", "pi")
        foreach ($client in $clients) {
            $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-ai-migration-r15-r19-$($client.Replace('-', '_'))-" + [guid]::NewGuid().ToString("N"))
            try {
                New-AiRulesMigrationFixture -Root $tempRoot `
                    -CurrentRepo "https://github.com/xmentosx/itl_ai_rules_1c.git" `
                    -CurrentRef "itl-main-72665287-r15" `
                    -CurrentCommit "cf31a89deaee5d39bab5cce490330d204e6e1233" `
                    -CurrentUpstreamCommit "72665287e77361aea3aaf866fef163d98f0fabcd" `
                    -CurrentDownstreamRevision 15 `
                    -CurrentTool $client
                $plan = & { . $HelperPath -ProjectRoot $tempRoot -Action help *> $null; Get-AiRulesMigrationPlan }
                $plan.status | Should -Be "eligible" -Because $client
                $plan.fromDownstreamRevision | Should -Be 15 -Because $client
                $plan.target.downstreamRevision | Should -Be $script:TargetAiRulesRevision -Because $client
                $plan.target.ref | Should -Be $script:TargetAiRulesRef -Because $client
                $plan.target.commit | Should -Be $script:TargetAiRulesCommit -Because $client
            } finally {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "plans r16 to r19 for every supported single-client installation" {
        $clients = @("codex", "kilocode", "claude-code", "cursor", "opencode", "kimi", "qwen", "command-code", "cline", "pi")
        foreach ($client in $clients) {
            $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-ai-migration-r16-r19-$($client.Replace('-', '_'))-" + [guid]::NewGuid().ToString("N"))
            try {
                New-AiRulesMigrationFixture -Root $tempRoot `
                    -CurrentRepo "https://github.com/xmentosx/itl_ai_rules_1c.git" `
                    -CurrentRef "itl-main-72665287-r16" `
                    -CurrentCommit "0118493165fd9507169317be28d53c52803d52ed" `
                    -CurrentUpstreamCommit "72665287e77361aea3aaf866fef163d98f0fabcd" `
                    -CurrentDownstreamRevision 16 `
                    -CurrentTool $client
                $plan = & { . $HelperPath -ProjectRoot $tempRoot -Action help *> $null; Get-AiRulesMigrationPlan }
                $plan.status | Should -Be "eligible" -Because $client
                $plan.fromDownstreamRevision | Should -Be 16 -Because $client
                $plan.target.downstreamRevision | Should -Be $script:TargetAiRulesRevision -Because $client
                $plan.target.ref | Should -Be $script:TargetAiRulesRef -Because $client
                $plan.target.commit | Should -Be $script:TargetAiRulesCommit -Because $client
            } finally {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "plans r17 to r19 for every supported single-client installation" {
        $clients = @("codex", "kilocode", "claude-code", "cursor", "opencode", "kimi", "qwen", "command-code", "cline", "pi")
        foreach ($client in $clients) {
            $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-ai-migration-r17-r19-$($client.Replace('-', '_'))-" + [guid]::NewGuid().ToString("N"))
            try {
                New-AiRulesMigrationFixture -Root $tempRoot `
                    -CurrentRepo "https://github.com/xmentosx/itl_ai_rules_1c.git" `
                    -CurrentRef "itl-main-72665287-r17" `
                    -CurrentCommit "27a898c426a1016fffc4a1b008e8ac0cb1490da2" `
                    -CurrentUpstreamCommit "72665287e77361aea3aaf866fef163d98f0fabcd" `
                    -CurrentDownstreamRevision 17 `
                    -CurrentTool $client
                $plan = & { . $HelperPath -ProjectRoot $tempRoot -Action help *> $null; Get-AiRulesMigrationPlan }
                $plan.status | Should -Be "eligible" -Because $client
                $plan.fromDownstreamRevision | Should -Be 17 -Because $client
                $plan.target.downstreamRevision | Should -Be $script:TargetAiRulesRevision -Because $client
                $plan.target.ref | Should -Be $script:TargetAiRulesRef -Because $client
                $plan.target.commit | Should -Be $script:TargetAiRulesCommit -Because $client
            } finally {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "plans r18 to r19 for every supported single-client installation" {
        $clients = @("codex", "kilocode", "claude-code", "cursor", "opencode", "kimi", "qwen", "command-code", "cline", "pi")
        foreach ($client in $clients) {
            $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-ai-migration-r18-r19-$($client.Replace('-', '_'))-" + [guid]::NewGuid().ToString("N"))
            try {
                New-AiRulesMigrationFixture -Root $tempRoot `
                    -CurrentRepo "https://github.com/xmentosx/itl_ai_rules_1c.git" `
                    -CurrentRef "itl-main-5ae333ed-r18" `
                    -CurrentCommit "841b30af5d87eb212f497754f1328b38146cb279" `
                    -CurrentUpstreamCommit "5ae333ed49dc66989e305b286acc93691bb96926" `
                    -CurrentDownstreamRevision 18 `
                    -CurrentTool $client
                $plan = & { . $HelperPath -ProjectRoot $tempRoot -Action help *> $null; Get-AiRulesMigrationPlan }
                $plan.status | Should -Be "eligible" -Because $client
                $plan.fromDownstreamRevision | Should -Be 18 -Because $client
                $plan.target.downstreamRevision | Should -Be $script:TargetAiRulesRevision -Because $client
                $plan.target.ref | Should -Be $script:TargetAiRulesRef -Because $client
                $plan.target.commit | Should -Be $script:TargetAiRulesCommit -Because $client
            }
            finally {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "treats the controlled target as current only when ref commit and revision all match" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-ai-migration-current-" + [guid]::NewGuid().ToString("N"))
        try {
            New-AiRulesMigrationFixture -Root $tempRoot `
                -CurrentRepo "https://github.com/xmentosx/itl_ai_rules_1c.git" `
                -CurrentRef $script:TargetAiRulesRef `
                -CurrentCommit $script:TargetAiRulesCommit `
                -CurrentUpstreamCommit "410951e74fd3e6b7a763cf49757935b9a34d3f31" `
                -CurrentDownstreamRevision $script:TargetAiRulesRevision
            $plan = & { . $HelperPath -ProjectRoot $tempRoot -Action help *> $null; Get-AiRulesMigrationPlan }
            $plan.status | Should -Be "current"
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "plans monotonic r11 through r21 to r22 migration for all ten clients" {
        $releases = @(
            [pscustomobject]@{ revision = 11; ref = "itl-main-b4d9875b-r11"; commit = "af82570afca06c40a9588c8a678bf3665bba4870"; upstream = "b4d9875b15c6d93f493035aee51f077126e72a21" },
            [pscustomobject]@{ revision = 12; ref = "itl-main-72665287-r12"; commit = "16e9e44318a79d9e82c12b19e6759cdf6492d9a4"; upstream = "72665287e77361aea3aaf866fef163d98f0fabcd" },
            [pscustomobject]@{ revision = 13; ref = "itl-main-72665287-r13"; commit = "b66569bebf46e0369efa53983fca69368e16d57a"; upstream = "72665287e77361aea3aaf866fef163d98f0fabcd" },
            [pscustomobject]@{ revision = 14; ref = "itl-main-72665287-r14"; commit = "0888fcdaf223abf97cfba7450bf38454926ad384"; upstream = "72665287e77361aea3aaf866fef163d98f0fabcd" },
            [pscustomobject]@{ revision = 15; ref = "itl-main-72665287-r15"; commit = "cf31a89deaee5d39bab5cce490330d204e6e1233"; upstream = "72665287e77361aea3aaf866fef163d98f0fabcd" },
            [pscustomobject]@{ revision = 16; ref = "itl-main-72665287-r16"; commit = "0118493165fd9507169317be28d53c52803d52ed"; upstream = "72665287e77361aea3aaf866fef163d98f0fabcd" },
            [pscustomobject]@{ revision = 17; ref = "itl-main-72665287-r17"; commit = "27a898c426a1016fffc4a1b008e8ac0cb1490da2"; upstream = "72665287e77361aea3aaf866fef163d98f0fabcd" },
            [pscustomobject]@{ revision = 18; ref = "itl-main-5ae333ed-r18"; commit = "841b30af5d87eb212f497754f1328b38146cb279"; upstream = "5ae333ed49dc66989e305b286acc93691bb96926" },
            [pscustomobject]@{ revision = 19; ref = "itl-main-5ae333ed-r19"; commit = "7952e7d9bb050d67e145c0136e87b6855c353f58"; upstream = "5ae333ed49dc66989e305b286acc93691bb96926" },
            [pscustomobject]@{ revision = 20; ref = "itl-main-5f3d3f0-r20"; commit = "151aa980b5e99b3d129e974925e734d9ef0afa3e"; upstream = "5f3d3f03b778d7de38cf2cfb18a20cf3e7ed79d8" },
            [pscustomobject]@{ revision = 21; ref = "itl-main-410951e7-r21"; commit = "37362c6fa0e29b8aee0f70e01d85bf77e41cc683"; upstream = "410951e74fd3e6b7a763cf49757935b9a34d3f31" }
        )
        $clients = @("codex", "kilocode", "claude-code", "cursor", "opencode", "kimi", "qwen", "command-code", "cline", "pi")
        foreach ($release in $releases) {
            foreach ($client in $clients) {
                $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-ai-r22-$($release.revision)-$($client.Replace('-', '_'))-" + [guid]::NewGuid().ToString("N"))
                try {
                    New-AiRulesMigrationFixture -Root $tempRoot -CurrentRepo "https://github.com/xmentosx/itl_ai_rules_1c.git" -CurrentRef $release.ref -CurrentCommit $release.commit -CurrentUpstreamCommit $release.upstream -CurrentDownstreamRevision $release.revision -CurrentTool $client
                    $plan = & { . $HelperPath -ProjectRoot $tempRoot -Action help *> $null; Get-AiRulesMigrationPlan }
                    $plan.status | Should -Be "eligible" -Because "r$($release.revision) $client"
                    $plan.target.downstreamRevision | Should -Be $script:TargetAiRulesRevision -Because "r$($release.revision) $client"
                    $plan.target.ref | Should -Be $script:TargetAiRulesRef -Because "r$($release.revision) $client"
                } finally {
                    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }

    It "clears only stale workflow-owned MCP userModified markers" {
        $matchingRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-ai-migration-mcp-match-" + [guid]::NewGuid().ToString("N"))
        $changedRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-ai-migration-mcp-changed-" + [guid]::NewGuid().ToString("N"))
        try {
            foreach ($root in @($matchingRoot, $changedRoot)) {
                New-AiRulesMigrationFixture -Root $root
                $manifestPath = Join-Path $root ".ai-rules.json"
                $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $manifest.files | Add-Member -NotePropertyName ".codex/config.toml" -NotePropertyValue ([pscustomobject]@{ source = "mcp"; installedHash = "old"; userModified = $true })
                Set-Content -LiteralPath $manifestPath -Encoding UTF8 -Value ($manifest | ConvertTo-Json -Depth 10)
            }

            $matchingPlan = & {
                . $HelperPath -ProjectRoot $matchingRoot -Action help *> $null
                function Get-Vibecoding1cMcpSelectionCompleteness { [pscustomobject]@{ isComplete = $true; reasons = @() } }
                function Get-Vibecoding1cMcpReadyClientConfigNames { @("1C-docs-mcp") }
                function New-AiRules1cMcpConfigSnapshot { [ordered]@{} }
                function Write-Vibecoding1cMcpClientConfig {}
                function Remove-AiRules1cManagedMcpConfig {}
                function Remove-StaleAiRules1cDataMcpConfig {}
                function Test-AiRulesMcpSnapshotMatchesCurrent { return $true }
                function Test-AiRulesMcpSnapshotHasUnknownEntries { return $false }
                function Restore-AiRules1cMcpConfigSnapshot {}
                Get-AiRulesMigrationPlan
            }
            $matchingPlan.status | Should -Be "eligible"
            $matchingManifest = Get-Content -LiteralPath (Join-Path $matchingRoot ".ai-rules.json") -Raw -Encoding UTF8 | ConvertFrom-Json
            $matchingManifest.files.'.codex/config.toml'.userModified | Should -BeFalse

            $changedPlan = & {
                . $HelperPath -ProjectRoot $changedRoot -Action help *> $null
                function Get-Vibecoding1cMcpSelectionCompleteness { [pscustomobject]@{ isComplete = $true; reasons = @() } }
                function Get-Vibecoding1cMcpReadyClientConfigNames { @("1C-docs-mcp") }
                function New-AiRules1cMcpConfigSnapshot { [ordered]@{} }
                function Write-Vibecoding1cMcpClientConfig {}
                function Remove-AiRules1cManagedMcpConfig {}
                function Remove-StaleAiRules1cDataMcpConfig {}
                function Test-AiRulesMcpSnapshotMatchesCurrent { return $false }
                function Test-AiRulesMcpSnapshotHasUnknownEntries { return $false }
                function Restore-AiRules1cMcpConfigSnapshot {}
                Get-AiRulesMigrationPlan
            }
            $changedPlan.status | Should -Be "user-modified"
            $changedManifest = Get-Content -LiteralPath (Join-Path $changedRoot ".ai-rules.json") -Raw -Encoding UTF8 | ConvertFrom-Json
            $changedManifest.files.'.codex/config.toml'.userModified | Should -BeTrue

            $unknownPlan = & {
                . $HelperPath -ProjectRoot $matchingRoot -Action help *> $null
                $manifestPath = Join-Path $script:ProjectRoot ".ai-rules.json"
                $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $manifest.files.'.codex/config.toml'.userModified = $true
                Set-Content -LiteralPath $manifestPath -Encoding UTF8 -Value ($manifest | ConvertTo-Json -Depth 10)
                function Get-Vibecoding1cMcpSelectionCompleteness { [pscustomobject]@{ isComplete = $true; reasons = @() } }
                function Get-Vibecoding1cMcpReadyClientConfigNames { @("1C-docs-mcp") }
                function New-AiRules1cMcpConfigSnapshot { [ordered]@{} }
                function Test-AiRulesMcpSnapshotHasUnknownEntries { return $true }
                Get-AiRulesMigrationPlan
            }
            $unknownPlan.status | Should -Be "user-modified"
            $unknownManifest = Get-Content -LiteralPath (Join-Path $matchingRoot ".ai-rules.json") -Raw -Encoding UTF8 | ConvertFrom-Json
            $unknownManifest.files.'.codex/config.toml'.userModified | Should -BeTrue
        } finally {
            Remove-Item -LiteralPath $matchingRoot, $changedRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "clears a Kilo marker when byte regeneration differs but every MCP entry is workflow-owned" {
        $managedRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-ai-migration-mcp-owned-" + [guid]::NewGuid().ToString("N"))
        $customRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-ai-migration-mcp-owned-name-custom-" + [guid]::NewGuid().ToString("N"))
        try {
            foreach ($root in @($managedRoot, $customRoot)) {
                New-AiRulesMigrationFixture -Root $root -CurrentTool "kilocode"
                New-Item -ItemType Directory -Force -Path (Join-Path $root ".kilo") | Out-Null
                $manifestPath = Join-Path $root ".ai-rules.json"
                $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $manifest.files | Add-Member -NotePropertyName ".kilo/kilo.json" -NotePropertyValue ([pscustomobject]@{ source = "content/mcp-servers.json"; installedHash = "old"; userModified = $true })
                Set-Content -LiteralPath $manifestPath -Encoding UTF8 -Value ($manifest | ConvertTo-Json -Depth 10)
            }
            $managedKiloJson = (@{
                snapshot = $false
                mcp = @{
                    "1c-code-metadata-mcp" = @{ type = "remote"; url = "http://127.0.0.1:17001/mcp"; managedBy = "vibecoding1c-mcp"; family = "vibecoding1c" }
                    "1c-graph-metadata-mcp" = @{ type = "remote"; url = "http://127.0.0.1:17002/mcp"; managedBy = "vibecoding1c-mcp"; family = "vibecoding1c" }
                }
            } | ConvertTo-Json -Depth 10)
            [System.IO.File]::WriteAllText((Join-Path $managedRoot ".kilo\kilo.json"), $managedKiloJson, (New-Object System.Text.UTF8Encoding $false))
            $customKiloJson = (@{
                mcp = @{
                    "1c-code-metadata-mcp" = @{ type = "remote"; url = "https://custom.invalid/mcp" }
                }
            } | ConvertTo-Json -Depth 10)
            [System.IO.File]::WriteAllText((Join-Path $customRoot ".kilo\kilo.json"), $customKiloJson, (New-Object System.Text.UTF8Encoding $false))

            $managedPlan = & {
                . $HelperPath -ProjectRoot $managedRoot -Action help *> $null
                function Get-AiRules1cMcpClientConfigPaths { @((Join-Path $script:ProjectRoot ".kilo\kilo.json")) }
                function Get-Vibecoding1cMcpSelectionCompleteness { [pscustomobject]@{ isComplete = $true; reasons = @() } }
                function Get-Vibecoding1cMcpReadyClientConfigNames { @("1c-code-metadata-mcp", "1c-graph-metadata-mcp") }
                function Write-Vibecoding1cMcpClientConfig {}
                function Remove-AiRules1cManagedMcpConfig {}
                function Remove-StaleAiRules1cDataMcpConfig {}
                function Test-AiRulesMcpSnapshotMatchesCurrent { return $false }
                $candidatePath = Join-Path $script:ProjectRoot ".kilo\kilo.json"
                $snapshot = New-AiRules1cMcpConfigSnapshot -Paths @($candidatePath)
                (Test-AiRulesMcpSnapshotHasUnknownEntries -Snapshot $snapshot -Paths @($candidatePath) -KnownServerIds @("1c-code-metadata-mcp", "1c-graph-metadata-mcp")) | Should -BeFalse
                (Test-AiRulesMcpSnapshotContainsOnlyVibecoding1cManagedEntries -Snapshot $snapshot -Paths @($candidatePath)) | Should -BeTrue
                Get-AiRulesMigrationPlan
            }
            $managedPlan.status | Should -Be "eligible"

            $customPlan = & {
                . $HelperPath -ProjectRoot $customRoot -Action help *> $null
                function Get-AiRules1cMcpClientConfigPaths { @((Join-Path $script:ProjectRoot ".kilo\kilo.json")) }
                function Get-Vibecoding1cMcpSelectionCompleteness { [pscustomobject]@{ isComplete = $true; reasons = @() } }
                function Get-Vibecoding1cMcpReadyClientConfigNames { @("1c-code-metadata-mcp") }
                function Write-Vibecoding1cMcpClientConfig {}
                function Remove-AiRules1cManagedMcpConfig {}
                function Remove-StaleAiRules1cDataMcpConfig {}
                function Test-AiRulesMcpSnapshotMatchesCurrent { return $false }
                Get-AiRulesMigrationPlan
            }
            $customPlan.status | Should -Be "user-modified"
        } finally {
            Remove-Item -LiteralPath $managedRoot, $customRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe "ai_rules_1c transactional migration" {
    It "excludes Kilo runtime worktrees from snapshots and preserves them during restore" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-ai-migration-kilo-runtime-" + [guid]::NewGuid().ToString("N"))
        try {
            New-AiRulesMigrationFixture -Root $tempRoot
            $kiloRoot = Join-Path $tempRoot ".kilo"
            $kiloConfig = Join-Path $kiloRoot "kilo.json"
            $runtimeSentinel = Join-Path $kiloRoot "worktrees\concrete-macadamia\sentinel.txt"
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $runtimeSentinel) | Out-Null
            [System.IO.File]::WriteAllText($kiloConfig, "original", (New-Object System.Text.UTF8Encoding $false))
            [System.IO.File]::WriteAllText($runtimeSentinel, "runtime", (New-Object System.Text.UTF8Encoding $false))

            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $snapshot = New-AiRulesMigrationSnapshot
                $payloadWorktrees = Join-Path $snapshot.payloadRoot ".kilo\worktrees"
                [System.IO.File]::WriteAllText((Join-Path $script:ProjectRoot ".kilo\kilo.json"), "changed", (New-Object System.Text.UTF8Encoding $false))
                [System.IO.File]::WriteAllText((Join-Path $script:ProjectRoot ".kilo\new-managed.txt"), "new", (New-Object System.Text.UTF8Encoding $false))
                Restore-AiRulesMigrationSnapshot -Snapshot $snapshot
                [pscustomobject]@{ payloadWorktrees = $payloadWorktrees }
            }

            Test-Path -LiteralPath $result.payloadWorktrees | Should -BeFalse
            (Get-Content -LiteralPath $kiloConfig -Raw -Encoding UTF8) | Should -Be "original"
            (Get-Content -LiteralPath $runtimeSentinel -Raw -Encoding UTF8) | Should -Be "runtime"
            Test-Path -LiteralPath (Join-Path $kiloRoot "new-managed.txt") | Should -BeFalse
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "leaves custom repositories untouched and writes a recovery report" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-ai-migration-recovery-" + [guid]::NewGuid().ToString("N"))
        try {
            New-AiRulesMigrationFixture -Root $tempRoot -CurrentRepo "https://example.invalid/custom-rules.git" -CurrentRef "custom-v1"
            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                Invoke-AiRulesBaselineMigration
            }
            $result.migrated | Should -BeFalse
            $result.suppressRegularUpdate | Should -BeTrue
            $result.status | Should -Be "custom"
            Test-Path -LiteralPath $result.recoveryReportPath -PathType Leaf | Should -BeTrue
            $report = Get-Content -LiteralPath $result.recoveryReportPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $report.status | Should -Be "blocked"
            $report.migrationStatus | Should -Be "custom"
            $report.current.repo | Should -Be "https://example.invalid/custom-rules.git"
            $report.target.ref | Should -Be $script:TargetAiRulesRef
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "reports blocking files and makes a blocked managed migration fail closed" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-ai-migration-blocked-" + [guid]::NewGuid().ToString("N"))
        try {
            New-AiRulesMigrationFixture -Root $tempRoot -UserModified $true
            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                Invoke-AiRulesBaselineMigration
            }
            $result.status | Should -Be "user-modified"
            $report = Get-Content -LiteralPath $result.recoveryReportPath -Raw -Encoding UTF8 | ConvertFrom-Json
            @($report.userModifiedFiles) | Should -Contain ".codex/rules/example.md"

            $assertion = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $script:RunErrorCategory = ""
                $script:RunRequiredAction = ""
                try {
                    Assert-AiRulesBaselineMigrationResult -Migration $result
                    [pscustomobject]@{ error = ""; category = $script:RunErrorCategory; requiredAction = $script:RunRequiredAction }
                } catch {
                    [pscustomobject]@{ error = $_.Exception.Message; category = $script:RunErrorCategory; requiredAction = $script:RunRequiredAction }
                }
            }
            $assertion.error | Should -Match "migration is blocked \(user-modified\)"
            $assertion.error | Should -Match ([regex]::Escape($result.recoveryReportPath))
            $assertion.category | Should -Be "ai-rules-migration-blocked"
            $assertion.requiredAction | Should -Match "/itl-update-workflow"
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "writes fork config and provenance after an eligible migration" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-ai-migration-pass-" + [guid]::NewGuid().ToString("N"))
        try {
            New-AiRulesMigrationFixture -Root $tempRoot `
                -CurrentRepo "https://github.com/xmentosx/itl_ai_rules_1c.git" `
                -CurrentRef "itl-main-a421cf44-r7" `
                -CurrentCommit "7f6d4cc68adfb6ada6d8e67ec4327cabbf3d0428" `
                -CurrentUpstreamCommit "a421cf44eb1f5859cf2a2b74884f8fbcaefc4826" `
                -CurrentDownstreamRevision 7
            $kiloPath = Join-Path $tempRoot ".kilo\kilo.json"
            $localStatePath = Join-Path $tempRoot ".agent-1c\local-state.json"
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $kiloPath) | Out-Null
            Set-Content -LiteralPath $kiloPath -Encoding UTF8 -Value '{"instructions":["USER-RULES.md","docs/custom.md"],"permission":{"bash":"ask"},"mcp":{"custom":{"url":"http://custom"}}}'
            Set-Content -LiteralPath $localStatePath -Encoding UTF8 -Value '{"keep":"local"}'
            $kiloBefore = (Get-FileHash -Algorithm SHA256 -LiteralPath $kiloPath).Hash
            $localStateBefore = (Get-FileHash -Algorithm SHA256 -LiteralPath $localStatePath).Hash
            $migrationOutput = @(& {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                function Invoke-AiRulesMigrationCandidatePreflight { param([object]$Plan); Write-Output "preflight progress"; return [pscustomobject]@{ root = "fixture" } }
                function Update-AiRules1c { Set-Content -LiteralPath (Join-Path $script:ProjectRoot "migration-applied.txt") -Encoding ASCII -Value "applied" }
                Invoke-AiRulesBaselineMigration
            })
            $migrationOutput.Count | Should -Be 1
            $result = $migrationOutput[0]
            $result.migrated | Should -BeTrue
            $config = Get-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Raw -Encoding UTF8 | ConvertFrom-Json
            $lock = Get-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\dependency-lock.json") -Raw -Encoding UTF8 | ConvertFrom-Json
            $config.aiRules.repo | Should -Be "https://github.com/xmentosx/itl_ai_rules_1c.git"
            $config.aiRules.ref | Should -Be $script:TargetAiRulesRef
            $lock.dependencies.aiRules1c.commit | Should -Be $script:TargetAiRulesCommit
            $lock.dependencies.aiRules1c.upstreamRef | Should -Be "refs/heads/main"
            (Get-FileHash -Algorithm SHA256 -LiteralPath $kiloPath).Hash | Should -Be $kiloBefore
            (Get-FileHash -Algorithm SHA256 -LiteralPath $localStatePath).Hash | Should -Be $localStateBefore
            Test-Path -LiteralPath (Join-Path $result.snapshotRoot "migration-report.json") | Should -BeTrue
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "restores config manifest and client directories after migration failure" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-ai-migration-rollback-" + [guid]::NewGuid().ToString("N"))
        try {
            New-AiRulesMigrationFixture -Root $tempRoot
            $sentinels = [ordered]@{
                ".agents\skills\itl\sentinel.txt" = "agents-original"
                ".codex\config.toml" = "codex-original"
                ".kilo\kilo.json" = "kilo-original"
                ".kilocode\workflows\legacy.md" = "kilocode-original"
            }
            foreach ($relative in $sentinels.Keys) {
                $path = Join-Path $tempRoot $relative
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
                Set-Content -LiteralPath $path -Encoding ASCII -Value $sentinels[$relative]
            }
            $configBefore = Get-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Raw -Encoding UTF8
            $lockBefore = Get-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\dependency-lock.json") -Raw -Encoding UTF8
            $manifestBefore = Get-Content -LiteralPath (Join-Path $tempRoot ".ai-rules.json") -Raw -Encoding UTF8
            $failure = ""
            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                function Invoke-AiRulesMigrationCandidatePreflight { param([object]$Plan); Write-Output "preflight progress"; return [pscustomobject]@{ root = "fixture" } }
                function Update-AiRules1c {
                    Set-Content -LiteralPath (Join-Path $script:ProjectRoot ".agent-1c\project.json") -Encoding ASCII -Value "damaged"
                    Set-Content -LiteralPath (Join-Path $script:ProjectRoot ".agent-1c\dependency-lock.json") -Encoding ASCII -Value "damaged"
                    Set-Content -LiteralPath (Join-Path $script:ProjectRoot ".ai-rules.json") -Encoding ASCII -Value "damaged"
                    foreach ($dir in @(".agents", ".codex", ".kilo", ".kilocode", ".kimi-code", ".qwen", ".commandcode", ".cline", ".pi")) {
                        Remove-Item -LiteralPath (Join-Path $script:ProjectRoot $dir) -Recurse -Force
                    }
                    throw "fixture migration failure"
                }
                try { Invoke-AiRulesBaselineMigration | Out-Null } catch { $script:migrationFailure = $_.Exception.Message }
            }
            $failure = $script:migrationFailure
            $failure | Should -Match "project files were restored"
            (Get-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Raw -Encoding UTF8) | Should -Be $configBefore
            (Get-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\dependency-lock.json") -Raw -Encoding UTF8) | Should -Be $lockBefore
            (Get-Content -LiteralPath (Join-Path $tempRoot ".ai-rules.json") -Raw -Encoding UTF8) | Should -Be $manifestBefore
            foreach ($relative in $sentinels.Keys) {
                (Get-Content -LiteralPath (Join-Path $tempRoot $relative) -Raw -Encoding ASCII).Trim() | Should -Be $sentinels[$relative]
            }
        } finally {
            Remove-Variable -Name migrationFailure -Scope Script -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
