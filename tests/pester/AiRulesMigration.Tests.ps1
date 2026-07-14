BeforeAll {
    . (Join-Path $PSScriptRoot "TestSupport.ps1")
    $context = Initialize-WorkflowPesterContext
    $RepoRoot = $context.RepoRoot
    $HelperPath = $context.HelperPath

    function New-AiRulesMigrationFixture {
        param(
            [string]$Root,
            [string]$CurrentRepo = "https://github.com/comol/ai_rules_1c.git",
            [string]$CurrentRef = "",
            [string]$CurrentCommit = "a421cf44eb1f5859cf2a2b74884f8fbcaefc4826",
            [string]$CurrentUpstreamCommit = "",
            [int]$CurrentDownstreamRevision = 0,
            [bool]$UserModified = $false,
            [bool]$ConfigureTarget = $true
        )

        New-Item -ItemType Directory -Force -Path (Join-Path $Root ".agent-1c"), (Join-Path $Root "templates") | Out-Null
        $config = [ordered]@{
            dependencyMode = "fresh"
            aiRules = [ordered]@{ repo = $CurrentRepo; ref = $CurrentRef; tools = @("codex", "kilocode") }
        }
        $targetConfig = [ordered]@{
            aiRules = [ordered]@{
                repo = "https://github.com/xmentosx/itl_ai_rules_1c.git"
                ref = $(if ($ConfigureTarget) { "itl-main-a421cf44-r5" } else { "" })
                tools = @("codex", "kilocode")
            }
        }
        $targetEntry = [ordered]@{
            repo = "https://github.com/xmentosx/itl_ai_rules_1c.git"
            ref = "itl-main-a421cf44-r5"
            commit = "8ebfc644f1f6c36c49052562ff68f186c0d6bc1e"
            upstreamRepo = "https://github.com/comol/ai_rules_1c.git"
            upstreamRef = "refs/heads/main"
            upstreamCommit = "a421cf44eb1f5859cf2a2b74884f8fbcaefc4826"
            downstreamRevision = 5
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
            tools = @("codex", "kilocode")
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

    It "plans a controlled fork r4 to r5 migration by downstream revision and upstream provenance" {
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
            $plan.target.downstreamRevision | Should -Be 5
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "treats the controlled target as current only when ref commit and revision all match" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-ai-migration-current-" + [guid]::NewGuid().ToString("N"))
        try {
            New-AiRulesMigrationFixture -Root $tempRoot `
                -CurrentRepo "https://github.com/xmentosx/itl_ai_rules_1c.git" `
                -CurrentRef "itl-main-a421cf44-r5" `
                -CurrentCommit "8ebfc644f1f6c36c49052562ff68f186c0d6bc1e" `
                -CurrentUpstreamCommit "a421cf44eb1f5859cf2a2b74884f8fbcaefc4826" `
                -CurrentDownstreamRevision 5
            $plan = & { . $HelperPath -ProjectRoot $tempRoot -Action help *> $null; Get-AiRulesMigrationPlan }
            $plan.status | Should -Be "current"
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
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
}

Describe "ai_rules_1c transactional migration" {
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
            $report.target.ref | Should -Be "itl-main-a421cf44-r5"
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "writes fork config and provenance after an eligible migration" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-ai-migration-pass-" + [guid]::NewGuid().ToString("N"))
        try {
            New-AiRulesMigrationFixture -Root $tempRoot
            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                function Invoke-AiRulesMigrationCandidatePreflight { param([object]$Plan); Write-Output "preflight progress"; return [pscustomobject]@{ root = "fixture" } }
                function Update-AiRules1c { Set-Content -LiteralPath (Join-Path $script:ProjectRoot "migration-applied.txt") -Encoding ASCII -Value "applied" }
                Invoke-AiRulesBaselineMigration
            }
            $result.migrated | Should -BeTrue
            $config = Get-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Raw -Encoding UTF8 | ConvertFrom-Json
            $lock = Get-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\dependency-lock.json") -Raw -Encoding UTF8 | ConvertFrom-Json
            $config.aiRules.repo | Should -Be "https://github.com/xmentosx/itl_ai_rules_1c.git"
            $config.aiRules.ref | Should -Be "itl-main-a421cf44-r5"
            $lock.dependencies.aiRules1c.commit | Should -Be "8ebfc644f1f6c36c49052562ff68f186c0d6bc1e"
            $lock.dependencies.aiRules1c.upstreamRef | Should -Be "refs/heads/main"
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
                    foreach ($dir in @(".agents", ".codex", ".kilo", ".kilocode")) {
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
