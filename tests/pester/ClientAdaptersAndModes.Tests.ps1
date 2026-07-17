Describe "ITL client adapters and verification modes" {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        $RepoRoot = $context.RepoRoot
        $HelperPath = $context.HelperPath
    }

    It "registers the five native client layouts" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-adapter-registry-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"aiRules":{"tools":["codex"]}}'
            $registry = & { . $HelperPath -ProjectRoot $tempRoot -Action help *> $null; Get-ItlClientAdapterRegistry }
            @($registry.Keys) | Should -Be @("codex", "kilocode", "claude-code", "cursor", "opencode")
            $registry.codex.skillsPath | Should -Be ".agents/skills"
            $registry.kilocode.commandsPath | Should -Be ".kilo/commands"
            $registry.opencode.agentsPath | Should -Be ".opencode/agent"
            $registry.opencode.commandsPath | Should -Be ".opencode/command"
            $registry.opencode.mcpPath | Should -Be "opencode.json"
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "implements auto manual off trigger semantics including explicit off override" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-mode-matrix-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"aiRules":{"tools":["codex"]}}'
            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                foreach ($mode in @("auto", "manual", "off")) {
                    [Environment]::SetEnvironmentVariable("ITL_VANESSA_TESTING", $mode, "Process")
                    foreach ($trigger in @("implicit", "command", "repair")) {
                        $decision = Get-ItlVerificationExecutionDecision -Component vanessa -Trigger $trigger
                        $expected = $mode -eq "auto" -or ($mode -eq "manual" -and $trigger -in @("command", "repair"))
                        $decision.run | Should -Be $expected
                    }
                    $explicit = Get-ItlVerificationExecutionDecision -Component vanessa -Trigger explicit -ExplicitComponents vanessa
                    $explicit.run | Should -BeTrue
                }
                [Environment]::SetEnvironmentVariable("ITL_VANESSA_TESTING", "broken", "Process")
                $invalid = Get-ItlVerificationMode -Component vanessa
                $invalid.valid | Should -BeFalse
                $invalid.effective | Should -Be "auto"
            }
        } finally {
            [Environment]::SetEnvironmentVariable("ITL_VANESSA_TESTING", $null, "Process")
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "changes only the two ITL keys through itl-litemode" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-lite-mode-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"aiRules":{"tools":["codex"]}}'
            Set-Content -LiteralPath (Join-Path $tempRoot ".dev.env") -Encoding UTF8 -Value "CUSTOM_KEEP=yes`nITL_VANESSA_TESTING=auto`nITL_CHECK_EVENT_LOG=auto`n"
            & { . $HelperPath -ProjectRoot $tempRoot -Action help *> $null; Set-ItlLiteMode -Mode standard *> $null }
            $text = Get-Content -LiteralPath (Join-Path $tempRoot ".dev.env") -Raw -Encoding UTF8
            $text | Should -Match '(?m)^CUSTOM_KEEP=yes\r?$'
            $text | Should -Match '(?m)^ITL_VANESSA_TESTING=auto\r?$'
            $text | Should -Match '(?m)^ITL_CHECK_EVENT_LOG=manual\r?$'
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "routes Kilo and OpenCode commands through the explicit ITL routine mode matrix" {
        $cases = @(
            [pscustomobject]@{ mode = "off"; model = "provider/light"; routine = $false; shortRoutine = $false; longRoutine = $false },
            [pscustomobject]@{ mode = "auto"; model = ""; routine = $false; shortRoutine = $false; longRoutine = $false },
            [pscustomobject]@{ mode = "auto"; model = "provider/light"; routine = $true; shortRoutine = $false; longRoutine = $true },
            [pscustomobject]@{ mode = "on"; model = "provider/light"; routine = $true; shortRoutine = $true; longRoutine = $true },
            [pscustomobject]@{ mode = "unknown"; model = "provider/light"; routine = $false; shortRoutine = $false; longRoutine = $false }
        )
        foreach ($client in @("kilocode", "opencode")) {
          foreach ($case in $cases) {
            $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-routine-$client-$($case.mode)-" + [guid]::NewGuid().ToString("N"))
            try {
                New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
                Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value (([ordered]@{ masterBranch = "master"; aiRules = [ordered]@{ tools = @($client) } } | ConvertTo-Json -Depth 5))
                Set-Content -LiteralPath (Join-Path $tempRoot ".ai-rules.json") -Encoding UTF8 -Value (([ordered]@{ tools = @($client); files = [ordered]@{} } | ConvertTo-Json -Depth 5))
                Set-Content -LiteralPath (Join-Path $tempRoot ".dev.env") -Encoding UTF8 -Value "ITL_ROUTINE_MODE=$($case.mode)`nSUBAGENT_MODEL_LIGHT=$($case.model)`nCAVEMAN=on`n"
                [Environment]::SetEnvironmentVariable("ITL_ROUTINE_MODE", $case.mode, "Process")
                [Environment]::SetEnvironmentVariable("SUBAGENT_MODEL_LIGHT", $case.model, "Process")
                & git -C $tempRoot init *> $null
                & git -C $tempRoot branch -M master
                & { . $HelperPath -ProjectRoot $tempRoot -Action help *> $null; Sync-ItlClientSurface -SourceRoot $RepoRoot *> $null }
                $adapter = if ($client -eq "kilocode") { ".kilo" } else { ".opencode" }
                $agentPath = if ($client -eq "kilocode") { Join-Path $tempRoot "$adapter\agents\itl-routine.md" } else { Join-Path $tempRoot "$adapter\agent\itl-routine.md" }
                (Test-Path -LiteralPath $agentPath -PathType Leaf) | Should -Be $case.routine
                if ($case.routine) {
                    $agentText = Get-Content -LiteralPath $agentPath -Raw
                    $agentText | Should -Match 'model: provider/light'
                    $agentText | Should -Match 'steps: 2'
                    $agentText | Should -Match '"\*": deny'
                    $agentText | Should -Match 'run-itl-command\.ps1\*": allow'
                    $agentText | Should -Match 'CAVEMAN terse prose'
                }
                $commandRoot = if ($client -eq "kilocode") { Join-Path $tempRoot ".kilo\commands" } else { Join-Path $tempRoot ".opencode\command" }
                $shortText = Get-Content -LiteralPath (Join-Path $commandRoot "itl.md") -Raw
                $longText = Get-Content -LiteralPath (Join-Path $commandRoot "itl-new-config-branch.md") -Raw
                $shortText | Should -Match $(if ($case.shortRoutine) { 'agent: itl-routine' } else { 'agent: code' })
                $longText | Should -Match $(if ($case.longRoutine) { 'agent: itl-routine' } else { 'agent: code' })
                if ($client -eq "kilocode") {
                    (Get-Content -LiteralPath (Join-Path $tempRoot ".kilo\kilo.json") -Raw | ConvertFrom-Json).snapshot | Should -BeFalse
                }
            } finally {
                [Environment]::SetEnvironmentVariable("ITL_ROUTINE_MODE", $null, "Process")
                [Environment]::SetEnvironmentVariable("SUBAGENT_MODEL_LIGHT", $null, "Process")
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
          }
        }

        $missingModelRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-routine-missing-model-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $missingModelRoot ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $missingModelRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"masterBranch":"master","aiRules":{"tools":["kilocode"]}}'
            Set-Content -LiteralPath (Join-Path $missingModelRoot ".ai-rules.json") -Encoding UTF8 -Value '{"tools":["kilocode"],"files":{}}'
            Set-Content -LiteralPath (Join-Path $missingModelRoot ".dev.env") -Encoding UTF8 -Value "ITL_ROUTINE_MODE=on`nSUBAGENT_MODEL_LIGHT=`n"
            [Environment]::SetEnvironmentVariable("ITL_ROUTINE_MODE", "on", "Process")
            [Environment]::SetEnvironmentVariable("SUBAGENT_MODEL_LIGHT", $null, "Process")
            & git -C $missingModelRoot init *> $null
            & git -C $missingModelRoot branch -M master
            $errorText = & { . $HelperPath -ProjectRoot $missingModelRoot -Action help *> $null; try { Sync-ItlClientSurface -SourceRoot $RepoRoot *> $null } catch { $_.Exception.Message } }
            $errorText | Should -Match 'requires an explicit SUBAGENT_MODEL_LIGHT'
        } finally {
            [Environment]::SetEnvironmentVariable("ITL_ROUTINE_MODE", $null, "Process")
            [Environment]::SetEnvironmentVariable("SUBAGENT_MODEL_LIGHT", $null, "Process")
            Remove-Item -LiteralPath $missingModelRoot -Recurse -Force -ErrorAction SilentlyContinue
        }

        $verifyFix = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\kilo-command-templates\dev\itl-verify-fix.md.template") -Raw
        $verifyFix | Should -Match 'agent: code'
        $verifyFix | Should -Match 'VerificationTrigger repair'
    }

    It "removes only an unchanged inactive routine agent" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-routine-cleanup-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"masterBranch":"master","aiRules":{"tools":["kilocode"]}}'
            Set-Content -LiteralPath (Join-Path $tempRoot ".ai-rules.json") -Encoding UTF8 -Value '{"tools":["kilocode"],"files":{}}'
            Set-Content -LiteralPath (Join-Path $tempRoot ".dev.env") -Encoding UTF8 -Value "ITL_ROUTINE_MODE=on`nSUBAGENT_MODEL_LIGHT=provider/light`n"
            [Environment]::SetEnvironmentVariable("ITL_ROUTINE_MODE", "on", "Process")
            [Environment]::SetEnvironmentVariable("SUBAGENT_MODEL_LIGHT", "provider/light", "Process")
            & git -C $tempRoot init *> $null
            & git -C $tempRoot branch -M master
            & { . $HelperPath -ProjectRoot $tempRoot -Action help *> $null; Sync-ItlClientSurface -SourceRoot $RepoRoot *> $null }
            $agentPath = Join-Path $tempRoot ".kilo\agents\itl-routine.md"
            Set-Content -LiteralPath (Join-Path $tempRoot ".dev.env") -Encoding UTF8 -Value "ITL_ROUTINE_MODE=off`nSUBAGENT_MODEL_LIGHT=provider/light`n"
            [Environment]::SetEnvironmentVariable("ITL_ROUTINE_MODE", "off", "Process")
            & { . $HelperPath -ProjectRoot $tempRoot -Action help *> $null; Sync-ItlClientSurface -SourceRoot $RepoRoot *> $null }
            (Test-Path -LiteralPath $agentPath -PathType Leaf) | Should -BeFalse

            Set-Content -LiteralPath (Join-Path $tempRoot ".dev.env") -Encoding UTF8 -Value "ITL_ROUTINE_MODE=on`nSUBAGENT_MODEL_LIGHT=provider/light`n"
            [Environment]::SetEnvironmentVariable("ITL_ROUTINE_MODE", "on", "Process")
            & { . $HelperPath -ProjectRoot $tempRoot -Action help *> $null; Sync-ItlClientSurface -SourceRoot $RepoRoot *> $null }
            Add-Content -LiteralPath $agentPath -Encoding UTF8 -Value "user edit"
            Set-Content -LiteralPath (Join-Path $tempRoot ".dev.env") -Encoding UTF8 -Value "ITL_ROUTINE_MODE=off`nSUBAGENT_MODEL_LIGHT=provider/light`n"
            [Environment]::SetEnvironmentVariable("ITL_ROUTINE_MODE", "off", "Process")
            & { . $HelperPath -ProjectRoot $tempRoot -Action help *> $null; Sync-ItlClientSurface -SourceRoot $RepoRoot *> $null }
            (Get-Content -LiteralPath $agentPath -Raw) | Should -Match 'user edit'
        } finally {
            [Environment]::SetEnvironmentVariable("ITL_ROUTINE_MODE", $null, "Process")
            [Environment]::SetEnvironmentVariable("SUBAGENT_MODEL_LIGHT", $null, "Process")
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "tracks ITL surface hashes, blocks drift, and preserves unowned inactive commands" {
        & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            Test-ItlKnownLegacyKiloCommandHash -Hash "5533dfbd12f58acfe7d81bf12d7b61f77f82341e7a87415c0e4ee0e6c996bdcf"
        } | Should -BeTrue
        foreach ($legacyHash in @(
            "1010d5c6c5c56c0f4fc8ac98af8776da42deba6426e0edbd7175d28fa2cf3424",
            "960430f846cc2f9bcb412336e28f284e04ade925ca0bbd98262a6feca42c9115",
            "f654eaaef1535f99781a45fa8fdff926623164b7e1eb5e7c35fa7eaa3ce5d93b",
            "4329c97b3798efe87e75f5cdd8f7a86a60039ea946206507a072700d198f0ccc",
            "df5150b2383d145028670f7a770d3c396e211910fd353cd4e5209a047442d6d9"
        )) {
            & {
                . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
                Test-ItlKnownLegacyKiloCommandHash -Hash $legacyHash
            } | Should -BeTrue
        }
        & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            Test-ItlKnownLegacyKiloCommandHash -Hash ("0" * 64)
        } | Should -BeFalse

        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-surface-state-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"masterBranch":"master","aiRules":{"repo":"https://github.com/xmentosx/itl_ai_rules_1c.git","ref":"itl-main-b4d9875b-r11","tools":["kilocode"]}}'
            Set-Content -LiteralPath (Join-Path $tempRoot ".ai-rules.json") -Encoding UTF8 -Value '{"protocol":"1.1","tools":["kilocode"],"files":{}}'
            & git -C $tempRoot init *> $null
            & git -C $tempRoot branch -M master
            & { . $HelperPath -ProjectRoot $tempRoot -Action help *> $null; Sync-ItlClientSurface -SourceRoot $RepoRoot *> $null }
            $managedPath = Join-Path $tempRoot ".kilo\commands\itl.md"
            Add-Content -LiteralPath $managedPath -Encoding UTF8 -Value "user edit"
            $drift = & { . $HelperPath -ProjectRoot $tempRoot -Action help *> $null; try { Sync-ItlClientSurface -SourceRoot $RepoRoot *> $null } catch { $_.Exception.Message } }
            $drift | Should -Match 'ITL_SURFACE_USER_MODIFIED'

            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $expectedItl = (Get-ItlExpectedSurfaceFiles -Client kilocode -SourceRoot $RepoRoot)['.kilo/commands/itl.md']
                Write-Utf8Text -Path $managedPath -Value $expectedItl
                Sync-ItlClientSurface -SourceRoot $RepoRoot *> $null
            }
            $customPath = Join-Path $tempRoot ".kilo\commands\itl-custom.md"
            Set-Content -LiteralPath $customPath -Encoding UTF8 -Value "user owned"
            & { . $HelperPath -ProjectRoot $tempRoot -Action help *> $null; Sync-ItlManagedSurfaceFiles -Client opencode -ExpectedFiles ([ordered]@{}) }
            (Get-Content -LiteralPath $customPath -Raw -Encoding UTF8).Trim() | Should -Be "user owned"
            (Test-Path -LiteralPath (Join-Path $tempRoot ".kilo\commands\itl-status.md") -PathType Leaf) | Should -BeFalse
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "keeps doctor read-only while checking provenance integrity OpenSpec modes and branch scope" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-doctor-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c"), (Join-Path $tempRoot ".agents\skills") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"masterBranch":"master","aiRules":{"repo":"https://github.com/xmentosx/itl_ai_rules_1c.git","ref":"itl-main-b4d9875b-r11","tools":["kilocode"]}}'
            Set-Content -LiteralPath (Join-Path $tempRoot ".dev.env") -Encoding UTF8 -Value "ITL_VANESSA_TESTING=auto`nITL_CHECK_EVENT_LOG=manual`n"
            $files = [ordered]@{}
            foreach ($skill in @("1c-workflow", "1c-workflow-fast", "product-docs", "itl-roctup-1c-data", "itl-vanessa-ui-mcp")) {
                $path = Join-Path $tempRoot ".agents\skills\$skill\SKILL.md"
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
                Set-Content -LiteralPath $path -Encoding UTF8 -Value "# $skill"
            }
            foreach ($stage in @("propose", "explore", "apply", "archive")) {
                $target = ".kilo/commands/opsx-$stage.md"
                $path = Join-Path $tempRoot $target
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
                Set-Content -LiteralPath $path -Encoding UTF8 -Value "# $stage"
                $files[$target] = [ordered]@{ source = "content/openspec-bundle/kilocode/.kilocode/workflows/opsx-$stage.md"; installedHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() }
            }
            $files[".dev.env"] = [ordered]@{ source = "content/root-templates/.dev.env"; installedHash = "upstream"; userModified = $true }
            Set-Content -LiteralPath (Join-Path $tempRoot ".ai-rules.json") -Encoding UTF8 -Value (([ordered]@{ protocol = "1.1"; tools = @("kilocode"); files = $files } | ConvertTo-Json -Depth 8) + "`n")
            $lock = [ordered]@{ dependencies = [ordered]@{ aiRules1c = [ordered]@{ repo = "https://github.com/xmentosx/itl_ai_rules_1c.git"; ref = "itl-main-b4d9875b-r11"; commit = "af82570afca06c40a9588c8a678bf3665bba4870"; upstreamCommit = "b4d9875b15c6d93f493035aee51f077126e72a21"; downstreamRevision = 11; compatibilityStatus = "passed" } } }
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\dependency-lock.json") -Encoding UTF8 -Value (($lock | ConvertTo-Json -Depth 8) + "`n")
            & git -C $tempRoot init *> $null
            & git -C $tempRoot branch -M master
            $before = (Get-ChildItem -LiteralPath $tempRoot -Recurse -File | ForEach-Object { "$($_.FullName.Substring($tempRoot.Length))=$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)" }) -join "`n"
            $output = & { . $HelperPath -ProjectRoot $tempRoot -Action help *> $null; function Get-ItlRtkStatus { [pscustomobject]@{ status = "SKIP"; detail = "fixture" } }; Show-ItlDoctor } 6>&1 | Out-String
            $after = (Get-ChildItem -LiteralPath $tempRoot -Recurse -File | ForEach-Object { "$($_.FullName.Substring($tempRoot.Length))=$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)" }) -join "`n"
            $output | Should -Match '\[OK\] active-client'
            $output | Should -Match '\[OK\] managed-integrity'
            $output | Should -Match 'workflowOwned=1'
            $output | Should -Match '\[OK\] openspec'
            $output | Should -Match '\[SKIP\] branch-infobase'
            $after | Should -Be $before
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "blocks Kilo JSON JSONC collision and tracked OpenCode config" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-client-guards-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c"), (Join-Path $tempRoot ".kilo") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"aiRules":{"tools":["kilocode"]}}'
            Set-Content -LiteralPath (Join-Path $tempRoot ".kilo\kilo.json") -Encoding UTF8 -Value '{}'
            Set-Content -LiteralPath (Join-Path $tempRoot ".kilo\kilo.jsonc") -Encoding UTF8 -Value '{}'
            $collision = & { . $HelperPath -ProjectRoot $tempRoot -Action help *> $null; try { Assert-ItlClientConfigWritable -Client kilocode } catch { $_.Exception.Message } }
            $collision | Should -Match 'KILO_CONFIG_COLLISION'

            Remove-Item -LiteralPath (Join-Path $tempRoot ".kilo\kilo.jsonc") -Force
            Set-Content -LiteralPath (Join-Path $tempRoot "opencode.json") -Encoding UTF8 -Value '{}'
            & git -C $tempRoot init *> $null
            & git -C $tempRoot add opencode.json
            $tracked = & { . $HelperPath -ProjectRoot $tempRoot -Action help *> $null; try { Assert-ItlClientConfigWritable -Client opencode } catch { $_.Exception.Message } }
            $tracked | Should -Match 'TRACKED_CLIENT_CONFIG'
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
