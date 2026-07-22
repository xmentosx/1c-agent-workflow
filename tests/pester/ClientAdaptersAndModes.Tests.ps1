Describe "ITL client adapters and verification modes" {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        $RepoRoot = $context.RepoRoot
        $HelperPath = $context.HelperPath

        function New-OpenSpecModeFixture {
            param(
                [string]$Root,
                [string]$Client,
                [ValidateSet("native", "natural")][string]$Mode
            )

            New-Item -ItemType Directory -Force -Path (Join-Path $Root ".agent-1c"), (Join-Path $Root "openspec/specs"), (Join-Path $Root "openspec/changes"), (Join-Path $Root ".fixture-rules") | Out-Null
            Set-Content -LiteralPath (Join-Path $Root ".agent-1c/project.json") -Encoding UTF8 -Value (([ordered]@{ aiRules = [ordered]@{ tools = @($Client) } } | ConvertTo-Json -Depth 5) + "`n")
            foreach ($relative in @("openspec/README.md", "openspec/config.yaml", "openspec/project.md", "openspec/specs/README.md", "openspec/changes/README.md")) {
                Set-Content -LiteralPath (Join-Path $Root $relative) -Encoding UTF8 -Value "fixture"
            }
            Set-Content -LiteralPath (Join-Path $Root "USER-RULES.md") -Encoding UTF8 -Value "<!-- ITL-WORKFLOW-USER-RULES:START -->`nContext Sources; test-plan.md; fresh /itl-check`n<!-- ITL-WORKFLOW-USER-RULES:END -->"
            $rulePath = Join-Path $Root ".fixture-rules/sdd-integrations.md"
            Set-Content -LiteralPath $rulePath -Encoding UTF8 -Value "OpenSpec integration fixture"
            $files = [ordered]@{
                ".fixture-rules/sdd-integrations.md" = [ordered]@{
                    source = "content/rules/sdd-integrations.md"
                    installedHash = (Get-FileHash -LiteralPath $rulePath -Algorithm SHA256).Hash.ToLowerInvariant()
                }
            }
            $integrations = [ordered]@{ openspec = [ordered]@{} }
            if ($Mode -eq "natural") {
                $integrations.openspec.bundleSkipped = @($Client)
            } else {
                $stages = [ordered]@{
                    propose = "openspec-propose"
                    explore = "openspec-explore"
                    apply = "openspec-apply-change"
                    archive = "openspec-archive-change"
                }
                foreach ($stage in $stages.Keys) {
                    $token = $stages[$stage]
                    $target = ".agents/skills/$token/SKILL.md"
                    $path = Join-Path $Root $target
                    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
                    Set-Content -LiteralPath $path -Encoding UTF8 -Value "# $stage"
                    $files[$target] = [ordered]@{
                        source = "content/openspec-bundle/$Client/.codex/skills/$token/SKILL.md"
                        installedHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
                    }
                }
            }
            $manifest = [ordered]@{ protocol = "1.1"; tools = @($Client); integrations = $integrations; files = $files }
            Set-Content -LiteralPath (Join-Path $Root ".ai-rules.json") -Encoding UTF8 -Value (($manifest | ConvertTo-Json -Depth 10) + "`n")
        }
    }

    It "registers all ten capability-driven client layouts" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-adapter-registry-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"aiRules":{"tools":["codex"]}}'
            $registry = & { . $HelperPath -ProjectRoot $tempRoot -Action help *> $null; Get-ItlClientAdapterRegistry }
            @($registry.Keys) | Should -Be @("codex", "kilocode", "claude-code", "cursor", "opencode", "kimi", "qwen", "command-code", "cline", "pi")
            $registry.codex.skillsPath | Should -Be ".agents/skills"
            $registry.kilocode.commandsPath | Should -Be ".kilo/commands"
            $registry.opencode.agentsPath | Should -Be ".opencode/agent"
            $registry.opencode.commandsPath | Should -Be ".opencode/command"
            $registry.opencode.mcpPath | Should -Be "opencode.json"
            $registry.opencode.devWorkspaceMode | Should -Be "client-native-adopt"
            $registry.opencode.workspaceProvider | Should -Be "opencode"
            $registry.opencode.handoffMode | Should -Be "native-workspace"
            $registry.opencode.workspacePluginPath | Should -Be ".opencode/plugins/itl-workspace.js"
            $registry.opencode.workspacePluginPackageLockKey | Should -Be "opencodePlugin"
            $registry.opencode.workspacePluginPackageName | Should -Be "@opencode-ai/plugin"
            $registry.opencode.workspacePluginRuntimePath | Should -Be ".opencode"
            $registry.opencode.requiredUserEnvironment.OPENCODE_EXPERIMENTAL_WORKSPACES | Should -Be "true"
            $registry.kimi.commandsPath | Should -Be ".kimi-code/skills"
            $registry.kimi.commandFormat | Should -Be "skill"
            $registry.kimi.nativeAgents | Should -BeFalse
            $registry.qwen.mcpPath | Should -Be ".qwen/settings.json"
            $registry.qwen.mcpRemoteFormat | Should -Be "qwen-http"
            $registry.'command-code'.executable | Should -Be "command-code"
            $registry.cline.nativeAgents | Should -BeFalse
            $registry.cline.mcpPath | Should -Be ".cline/mcp.json"
            $registry.pi.commandsPath | Should -Be ".pi/prompts"
            $registry.pi.requiredPackage | Should -Be "npm:pi-mcp-extension@1.5.0"
            foreach ($client in @($registry.Keys)) {
                [string]$registry[$client].reload | Should -Not -BeNullOrEmpty
                if ($client -ne "opencode") {
                    $registry[$client].devWorkspaceMode | Should -Be "external-create"
                    $registry[$client].workspaceProvider | Should -Be "git"
                    $registry[$client].workspacePluginPath | Should -Be ""
                    $registry[$client].workspacePluginPackageLockKey | Should -Be ""
                    $registry[$client].PSObject.Properties.Name | Should -Not -Contain "requiredUserEnvironment"
                }
            }
            $vanessaSource = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.vanessa.ps1") -Raw -Encoding UTF8
            $vanessaSource | Should -Match 'Vanessa authoring state: ready'
            $vanessaSource | Should -Not -Match 'reloadInstruction'
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "configures the OpenCode native workspace user flag idempotently" {
        $name = "OPENCODE_EXPERIMENTAL_WORKSPACES"
        $originalUser = [Environment]::GetEnvironmentVariable($name, "User")
        $originalProcess = [Environment]::GetEnvironmentVariable($name, "Process")
        try {
            [Environment]::SetEnvironmentVariable($name, "false", "User")
            [Environment]::SetEnvironmentVariable($name, $null, "Process")
            $first = & {
                . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
                Sync-ItlClientUserEnvironment -Client opencode
                [pscustomobject]@{
                    user = [Environment]::GetEnvironmentVariable("OPENCODE_EXPERIMENTAL_WORKSPACES", "User")
                    process = [Environment]::GetEnvironmentVariable("OPENCODE_EXPERIMENTAL_WORKSPACES", "Process")
                }
            }
            $first.user | Should -Be "true"
            $first.process | Should -Be "true"

            [Environment]::SetEnvironmentVariable($name, "1", "User")
            [Environment]::SetEnvironmentVariable($name, $null, "Process")
            & {
                . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
                Sync-ItlClientUserEnvironment -Client opencode
            } | Should -BeNullOrEmpty
            [Environment]::GetEnvironmentVariable($name, "User") | Should -Be "1"
            [Environment]::GetEnvironmentVariable($name, "Process") | Should -Be "1"
        } finally {
            [Environment]::SetEnvironmentVariable($name, $originalUser, "User")
            [Environment]::SetEnvironmentVariable($name, $originalProcess, "Process")
        }
    }

    It "reports native mode only for an intact managed bundle" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-openspec-native-" + [guid]::NewGuid().ToString("N"))
        try {
            New-OpenSpecModeFixture -Root $tempRoot -Client codex -Mode native
            $status = & { . $HelperPath -ProjectRoot $tempRoot -Action help *> $null; Get-AiRules1cOpenSpecStatus }
            $status.mode | Should -Be "native"
            $status.isAvailable | Should -BeTrue
            $status.invocations.propose | Should -Be "skill openspec-propose"

            Remove-Item -LiteralPath (Join-Path $tempRoot ".agents/skills/openspec-apply-change/SKILL.md") -Force
            $broken = & { . $HelperPath -ProjectRoot $tempRoot -Action help *> $null; Get-AiRules1cOpenSpecStatus }
            $broken.mode | Should -Be "unavailable"
            $broken.reason | Should -Match "missing or damaged"
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "reports natural mode for every new client even when the external CLI is absent" {
        foreach ($client in @("kimi", "qwen", "command-code", "cline", "pi")) {
            $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-openspec-natural-$($client.Replace('-', '_'))-" + [guid]::NewGuid().ToString("N"))
            try {
                New-OpenSpecModeFixture -Root $tempRoot -Client $client -Mode natural
                $status = & {
                    . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                    function Get-ItlOpenSpecCliStatus { [pscustomobject]@{ available = $false; path = "" } }
                    Get-AiRules1cOpenSpecStatus
                }
                $status.mode | Should -Be "natural" -Because $client
                $status.isAvailable | Should -BeTrue -Because $client
                $status.cliAvailable | Should -BeFalse -Because $client
                $status.reason | Should -Match "intentionally skipped" -Because $client
            } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    It "does not mask missing workspace or ITL rules with natural fallback" {
        $workspaceRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-openspec-missing-workspace-" + [guid]::NewGuid().ToString("N"))
        $rulesRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-openspec-missing-rules-" + [guid]::NewGuid().ToString("N"))
        try {
            New-OpenSpecModeFixture -Root $workspaceRoot -Client qwen -Mode natural
            Remove-Item -LiteralPath (Join-Path $workspaceRoot "openspec/project.md") -Force
            $workspaceStatus = & { . $HelperPath -ProjectRoot $workspaceRoot -Action help *> $null; Get-AiRules1cOpenSpecStatus }
            $workspaceStatus.mode | Should -Be "unavailable"
            $workspaceStatus.reason | Should -Match "workspace is incomplete"

            New-OpenSpecModeFixture -Root $rulesRoot -Client qwen -Mode natural
            Set-Content -LiteralPath (Join-Path $rulesRoot "USER-RULES.md") -Encoding UTF8 -Value "user only"
            $rulesStatus = & { . $HelperPath -ProjectRoot $rulesRoot -Action help *> $null; Get-AiRules1cOpenSpecStatus }
            $rulesStatus.mode | Should -Be "unavailable"
            $rulesStatus.reason | Should -Match "complete ITL OpenSpec preflight"
        } finally {
            Remove-Item -LiteralPath $workspaceRoot, $rulesRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "preserves the output format contracts across native command adapters" {
        $templateRoot = Join-Path $RepoRoot ".agents\skills\1c-workflow\kilo-command-templates\common"
        $templates = [ordered]@{
            "itl.md" = Get-Content -LiteralPath (Join-Path $templateRoot "itl.md.template") -Raw -Encoding UTF8
            "itl-status.md" = Get-Content -LiteralPath (Join-Path $templateRoot "itl-status.md.template") -Raw -Encoding UTF8
            "itl-litemode.md" = Get-Content -LiteralPath (Join-Path $templateRoot "itl-litemode.md.template") -Raw -Encoding UTF8
        }
        $previousMode = [Environment]::GetEnvironmentVariable("ITL_ROUTINE_MODE", "Process")
        try {
            [Environment]::SetEnvironmentVariable("ITL_ROUTINE_MODE", "off", "Process")
            $adapted = & {
                . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
                $result = [ordered]@{}
                foreach ($client in @("kilocode", "claude-code", "cursor", "opencode", "kimi", "qwen", "command-code", "cline", "pi")) {
                    $result[$client] = [ordered]@{}
                    foreach ($fileName in $templates.Keys) {
                        $result[$client][$fileName] = Convert-ItlCommandForClient -Text $templates[$fileName] -Client $client -FileName $fileName
                    }
                }
                $result
            }

            foreach ($client in $adapted.Keys) {
                $adapted[$client]["itl.md"] | Should -Match "entire final response"
                $adapted[$client]["itl.md"] | Should -Match 'fenced `text` code block'
                $adapted[$client]["itl-status.md"] | Should -Match "structured Russian Markdown report"
                $adapted[$client]["itl-status.md"] | Should -Match 'one `- Подпись: значение` field per line'
                $adapted[$client]["itl-status.md"] | Should -Match "Kilo Browser Automation"
                $adapted[$client]["itl-status.md"] | Should -Match "never omit, reword, or move"
                $adapted[$client]["itl-status.md"] | Should -Match "Контекст разработки"
                $adapted[$client]["itl-litemode.md"] | Should -Match "complete helper stdout unchanged"
                $adapted[$client]["itl-litemode.md"] | Should -Match 'exactly one fenced `text` code block'
            }
        } finally {
            [Environment]::SetEnvironmentVariable("ITL_ROUTINE_MODE", $previousMode, "Process")
        }
    }

    It "provides a Russian initialization reload instruction for every client" {
        $instructions = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $registry = Get-ItlClientAdapterRegistry
            $result = [ordered]@{}
            foreach ($client in $registry.Keys) { $result[$client] = [string]$registry[$client].reloadUserReport }
            $result
        }

        $instructions.Keys.Count | Should -Be 10
        foreach ($client in $instructions.Keys) {
            $instructions[$client] | Should -Not -BeNullOrEmpty -Because $client
            $instructions[$client] | Should -Not -Match '^(Start|Run|Restart|Reload|Trust)\b' -Because $client
        }
        $instructions.kilocode | Should -Match '/reload'
    }

    It "generates the documented routine surfaces for every new client" {
        $expected = [ordered]@{
            kimi = ".kimi-code/skills/itl/SKILL.md"
            qwen = ".qwen/commands/itl.md"
            "command-code" = ".commandcode/commands/itl.md"
            cline = ".cline/skills/itl/SKILL.md"
            pi = ".pi/prompts/itl.md"
        }
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $value = [ordered]@{}
            foreach ($client in $expected.Keys) { $value[$client] = Get-ItlExpectedSurfaceFiles -Client $client -SourceRoot $RepoRoot }
            $value
        }
        foreach ($client in $expected.Keys) {
            $path = [string]$expected[$client]
            @($result[$client].Keys) | Should -Contain $path
            [string]$result[$client][$path] | Should -Not -Match '(?m)^agent:'
        }
        [string]$result.kimi[$expected.kimi] | Should -Match '(?m)^name:\s*itl$'
        [string]$result.cline[$expected.cline] | Should -Match '(?m)^name:\s*itl$'
    }

    It "renders all new project MCP schemas without replacing user config" {
        $cases = @(
            [pscustomobject]@{ client = "kimi"; remoteKey = "url"; remoteType = "type"; remoteValue = "http" },
            [pscustomobject]@{ client = "qwen"; remoteKey = "httpUrl"; remoteType = ""; remoteValue = "" },
            [pscustomobject]@{ client = "command-code"; remoteKey = "url"; remoteType = "type"; remoteValue = "http" },
            [pscustomobject]@{ client = "cline"; remoteKey = "url"; remoteType = "type"; remoteValue = "streamableHttp" },
            [pscustomobject]@{ client = "pi"; remoteKey = "url"; remoteType = "transport"; remoteValue = "streamable-http" }
        )
        foreach ($case in $cases) {
            $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-new-mcp-$($case.client)-" + [guid]::NewGuid().ToString("N"))
            try {
                New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
                Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value (([ordered]@{ aiRules = [ordered]@{ tools = @($case.client) } } | ConvertTo-Json -Depth 5))
                & {
                    . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                    $adapter = Get-ItlClientAdapter -Client $case.client
                    $path = Join-Path $tempRoot $adapter.mcpPath
                    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
                    Write-Vibecoding1cMcpJsonFile -Path $path -Value ([ordered]@{ keep = "user"; $($adapter.mcpContainer) = [ordered]@{ custom = [ordered]@{ url = "https://custom.invalid" } } })
                    Write-ItlClientMcpEndpoints -Client $case.client -Owner test -Endpoints @([pscustomobject]@{ name = "remote-test"; url = "https://itl.invalid/mcp"; transport = "remote" }) | Out-Null
                }
                $adapter = & { . $HelperPath -ProjectRoot $tempRoot -Action help *> $null; Get-ItlClientAdapter -Client $case.client }
                $config = Get-Content -LiteralPath (Join-Path $tempRoot $adapter.mcpPath) -Raw -Encoding UTF8 | ConvertFrom-Json
                $config.keep | Should -Be "user"
                $config.($adapter.mcpContainer).custom.url | Should -Be "https://custom.invalid"
                $entry = $config.($adapter.mcpContainer).'remote-test'
                $entry.($case.remoteKey) | Should -Be "https://itl.invalid/mcp"
                if ($case.remoteType) { $entry.($case.remoteType) | Should -Be $case.remoteValue }
                if ($case.client -eq "pi") { $entry.lifecycle | Should -Be "eager" }
            } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    It "pins and removes only the managed Pi extension package" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-pi-package-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c"), (Join-Path $tempRoot ".pi") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"aiRules":{"tools":["pi"]}}'
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\dependency-lock.json") -Encoding UTF8 -Value (Get-Content -LiteralPath (Join-Path $RepoRoot "templates\dependency-lock.json") -Raw -Encoding UTF8)
            Set-Content -LiteralPath (Join-Path $tempRoot ".pi\settings.json") -Encoding UTF8 -Value '{"theme":"keep","packages":["npm:user-package@2.0.0","npm:pi-mcp-extension@1.4.0"]}'
            & { . $HelperPath -ProjectRoot $tempRoot -Action help *> $null; Assert-ItlClientRequirements -Client pi; Sync-ItlClientRequiredPackage -Client pi }
            $installed = Get-Content -LiteralPath (Join-Path $tempRoot ".pi\settings.json") -Raw -Encoding UTF8 | ConvertFrom-Json
            $installed.theme | Should -Be "keep"
            @($installed.packages) | Should -Be @("npm:user-package@2.0.0", "npm:pi-mcp-extension@1.5.0")
            & { . $HelperPath -ProjectRoot $tempRoot -Action help *> $null; Sync-ItlClientRequiredPackage -Client pi -Remove }
            $removed = Get-Content -LiteralPath (Join-Path $tempRoot ".pi\settings.json") -Raw -Encoding UTF8 | ConvertFrom-Json
            $removed.theme | Should -Be "keep"
            @($removed.packages) | Should -Be @("npm:user-package@2.0.0")
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "cleans managed routine surfaces for every ordered client switch pair" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-client-pairs-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            & git -C $tempRoot init *> $null
            & git -C $tempRoot branch -M master
            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $clients = @(Get-SupportedAgentTargets)
                foreach ($from in $clients) {
                    foreach ($to in $clients) {
                        $fromFiles = Get-ItlExpectedSurfaceFiles -Client $from -SourceRoot $RepoRoot
                        Sync-ItlManagedSurfaceFiles -Client $from -ExpectedFiles $fromFiles
                        $toFiles = Get-ItlExpectedSurfaceFiles -Client $to -SourceRoot $RepoRoot
                        Sync-ItlManagedSurfaceFiles -Client $to -ExpectedFiles $toFiles
                        foreach ($relative in @($fromFiles.Keys | Where-Object { -not $toFiles.Contains($_) })) {
                            (Test-Path -LiteralPath (Join-Path $tempRoot $relative) -PathType Leaf) | Should -BeFalse -Because "$from -> $to must remove only the old managed surface"
                        }
                        $state = Read-ItlClientSurfaceState
                        $stateClients = ConvertTo-Vibecoding1cMcpHashtable -Object $state.clients
                        @($stateClients.Keys) | Should -Be @($to)
                    }
                }
            }
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
                $primaryAgent = $(if ($client -eq "opencode") { 'agent: build' } else { 'agent: code' })
                $shortText | Should -Match $(if ($case.shortRoutine) { 'agent: itl-routine' } else { $primaryAgent })
                if ($client -eq "opencode") {
                    $longText | Should -Match 'agent: build'
                    $longText | Should -Match 'itl_create_dev_workspace'
                    $longText | Should -Not -Match 'run-itl-command\.ps1'
                    $longText | Should -Match 'ITL_OPENCODE_WORKSPACE_TOOL_UNAVAILABLE'
                    $longText | Should -Match 'Do not load a skill'
                    $longText | Should -Match 'Do not search for its implementation'
                } else {
                    $longText | Should -Match $(if ($case.longRoutine) { 'agent: itl-routine' } else { $primaryAgent })
                }
                if ($client -eq "opencode") {
                    $shortText | Should -Not -Match '(?m)^agent:\s*code\s*$'
                    $longText | Should -Not -Match '(?m)^agent:\s*code\s*$'
                }
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
        $authorTemplate = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\kilo-command-templates\dev\itl-vanessa-author.md.template") -Raw
        $authorRouting = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            [pscustomobject]@{
                listed = (Get-ItlRoutineCommandNames) -contains "itl-vanessa-author.md"
                kilocode = Convert-ItlCommandForClient -Text $authorTemplate -Client "kilocode" -FileName "itl-vanessa-author.md"
                opencode = Convert-ItlCommandForClient -Text $authorTemplate -Client "opencode" -FileName "itl-vanessa-author.md"
                opencodeVerifyFix = Convert-ItlCommandForClient -Text $verifyFix -Client "opencode" -FileName "itl-verify-fix.md"
            }
        }
        $authorRouting.listed | Should -BeFalse
        $authorRouting.kilocode | Should -Match '(?m)^agent:\s*code\s*$'
        $authorRouting.opencode | Should -Match '(?m)^agent:\s*build\s*$'
        $authorRouting.opencodeVerifyFix | Should -Match '(?m)^agent:\s*build\s*$'
    }

    It "maps every development OpenCode ITL wrapper to a valid agent" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-opencode-dev-routing-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"masterBranch":"master","aiRules":{"tools":["opencode"]}}'
            Set-Content -LiteralPath (Join-Path $tempRoot ".ai-rules.json") -Encoding UTF8 -Value '{"tools":["opencode"],"files":{}}'
            Set-Content -LiteralPath (Join-Path $tempRoot ".dev.env") -Encoding UTF8 -Value "ITL_ROUTINE_MODE=off`n"
            [Environment]::SetEnvironmentVariable("ITL_ROUTINE_MODE", "off", "Process")
            [Environment]::SetEnvironmentVariable("SUBAGENT_MODEL_LIGHT", $null, "Process")
            & git -C $tempRoot init *> $null
            & git -C $tempRoot branch -M "itldev/opencode-routing"
            & { . $HelperPath -ProjectRoot $tempRoot -Action help *> $null; Sync-ItlClientSurface -SourceRoot $RepoRoot *> $null }

            $commands = @(Get-ChildItem -LiteralPath (Join-Path $tempRoot ".opencode\command") -File -Filter "itl*.md")
            $commands.Count | Should -BeGreaterThan 0
            foreach ($command in $commands) {
                $text = Get-Content -LiteralPath $command.FullName -Raw
                $text | Should -Match '(?m)^agent:\s*build\s*$'
                $text | Should -Not -Match '(?m)^agent:\s*code\s*$'
            }
        } finally {
            [Environment]::SetEnvironmentVariable("ITL_ROUTINE_MODE", $null, "Process")
            [Environment]::SetEnvironmentVariable("SUBAGENT_MODEL_LIGHT", $null, "Process")
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "generates the managed OpenCode native workspace plugin only for OpenCode" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            [pscustomobject]@{
                opencode = Get-ItlExpectedSurfaceFiles -Client opencode -SourceRoot $RepoRoot
                kilocode = Get-ItlExpectedSurfaceFiles -Client kilocode -SourceRoot $RepoRoot
            }
        }
        $pluginPath = ".opencode/plugins/itl-workspace.js"
        @($result.opencode.Keys) | Should -Contain $pluginPath
        @($result.kilocode.Keys) | Should -Not -Contain $pluginPath
        $plugin = [string]$result.opencode[$pluginPath]
        $plugin | Should -Match 'itl_create_dev_workspace'
        $plugin | Should -Match 'client\.experimental\.workspace\.create'
        $plugin | Should -Match 'client\.experimental\.workspace\.warp'
        $plugin | Should -Match 'workspace\.syncList'
        $plugin | Should -Match 'OPENCODE_EXPERIMENTAL_WORKSPACES=true'
        $plugin.IndexOf('waitUntilReady(plan, workspace)') | Should -BeLessThan $plugin.IndexOf('"-Action", "adopt-dev-worktree"')
        $plugin.IndexOf('"-Action", "adopt-dev-worktree"') | Should -BeLessThan $plugin.IndexOf('workspace.warp')
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
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c"), (Join-Path $tempRoot ".agents\skills"), (Join-Path $tempRoot "openspec/specs"), (Join-Path $tempRoot "openspec/changes"), (Join-Path $tempRoot ".kilo/rules-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"masterBranch":"master","aiRules":{"repo":"https://github.com/xmentosx/itl_ai_rules_1c.git","ref":"itl-main-b4d9875b-r11","tools":["kilocode"]}}'
            Set-Content -LiteralPath (Join-Path $tempRoot ".dev.env") -Encoding UTF8 -Value "ITL_VANESSA_TESTING=auto`nITL_CHECK_EVENT_LOG=manual`n"
            foreach ($relative in @("openspec/README.md", "openspec/config.yaml", "openspec/project.md", "openspec/specs/README.md", "openspec/changes/README.md")) {
                Set-Content -LiteralPath (Join-Path $tempRoot $relative) -Encoding UTF8 -Value "fixture"
            }
            Set-Content -LiteralPath (Join-Path $tempRoot "USER-RULES.md") -Encoding UTF8 -Value "<!-- ITL-WORKFLOW-USER-RULES:START -->`nContext Sources; test-plan.md; fresh /itl-check`n<!-- ITL-WORKFLOW-USER-RULES:END -->"
            $rulePath = Join-Path $tempRoot ".kilo/rules-1c/sdd-integrations.md"
            Set-Content -LiteralPath $rulePath -Encoding UTF8 -Value "OpenSpec integration fixture"
            $files = [ordered]@{
                ".kilo/rules-1c/sdd-integrations.md" = [ordered]@{ source = "content/rules/sdd-integrations.md"; installedHash = (Get-FileHash -LiteralPath $rulePath -Algorithm SHA256).Hash.ToLowerInvariant() }
            }
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

    It "reports a healthy natural OpenSpec mode as OK in doctor" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-doctor-openspec-natural-" + [guid]::NewGuid().ToString("N"))
        try {
            New-OpenSpecModeFixture -Root $tempRoot -Client qwen -Mode natural
            $projectConfig = [ordered]@{ masterBranch = "master"; aiRules = [ordered]@{ repo = "https://github.com/xmentosx/itl_ai_rules_1c.git"; ref = "itl-main-72665287-r13"; tools = @("qwen") } }
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c/project.json") -Encoding UTF8 -Value (($projectConfig | ConvertTo-Json -Depth 6) + "`n")
            $lock = [ordered]@{ dependencies = [ordered]@{ aiRules1c = [ordered]@{ repo = "https://github.com/xmentosx/itl_ai_rules_1c.git"; ref = "itl-main-72665287-r13"; commit = "b66569bebf46e0369efa53983fca69368e16d57a"; upstreamCommit = "72665287e77361aea3aaf866fef163d98f0fabcd"; downstreamRevision = 13; compatibilityStatus = "passed" } } }
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c/dependency-lock.json") -Encoding UTF8 -Value (($lock | ConvertTo-Json -Depth 8) + "`n")
            Set-Content -LiteralPath (Join-Path $tempRoot ".dev.env") -Encoding UTF8 -Value "ITL_VANESSA_TESTING=auto`nITL_CHECK_EVENT_LOG=manual`n"
            foreach ($skill in @("1c-workflow", "1c-workflow-fast", "product-docs", "itl-roctup-1c-data", "itl-vanessa-ui-mcp")) {
                $path = Join-Path $tempRoot ".agents/skills/$skill/SKILL.md"
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
                Set-Content -LiteralPath $path -Encoding UTF8 -Value "# $skill"
            }
            & git -C $tempRoot init *> $null
            & git -C $tempRoot branch -M master
            $output = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                function Get-ItlRtkStatus { [pscustomobject]@{ status = "SKIP"; detail = "fixture" } }
                Show-ItlDoctor
            } 6>&1 | Out-String
            $output | Should -Match '\[OK\] openspec: mode=natural'
            ($output -replace '\s+', '') | Should -Match 'intentionallyskipped'
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
