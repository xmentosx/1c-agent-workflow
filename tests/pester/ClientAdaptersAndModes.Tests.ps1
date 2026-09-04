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
                [ValidateSet("native", "natural")][string]$Mode,
                [bool]$IncludeOpsxAliases = $true
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
                if ($Client -eq "codex" -and $IncludeOpsxAliases) {
                    foreach ($stage in @("propose", "explore", "apply", "archive")) {
                        $token = "opsx-$stage"
                        $target = ".agents/skills/$token/SKILL.md"
                        $path = Join-Path $Root $target
                        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
                        Set-Content -LiteralPath $path -Encoding UTF8 -Value "# explicit $stage"
                        $files[$target] = [ordered]@{
                            source = "content/openspec-bundle/$Client/.codex/skills/$token/SKILL.md"
                            installedHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
                        }
                    }
                }
            }
            $manifest = [ordered]@{ protocol = "1.1"; tools = @($Client); integrations = $integrations; files = $files }
            Set-Content -LiteralPath (Join-Path $Root ".ai-rules.json") -Encoding UTF8 -Value (($manifest | ConvertTo-Json -Depth 10) + "`n")
        }
    }

    It "writes deterministic MCP entries and registers every client layout" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-client-mcp-order-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c\mcp"), (Join-Path $tempRoot ".kilo") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"aiRules":{"tools":["kilocode"]}}'; Set-Content -LiteralPath (Join-Path $tempRoot ".ai-rules.json") -Encoding UTF8 -Value '{"schemaVersion":1,"tools":["kilocode"],"files":{}}'
            Set-Content -LiteralPath (Join-Path $tempRoot ".kilo\kilo.json") -Encoding UTF8 -Value '{"mcp":{"custom":{"type":"remote","url":"http://custom"}},"permission":{"bash":"ask"}}'
            $hashes = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                function Get-ItlActiveClient { return "kilocode" }
                $alpha = [pscustomobject]@{ name = "alpha"; transport = "stdio"; command = "tool.exe"; args = @("alpha"); toolTimeoutSeconds = 120 }
                $zulu = [pscustomobject]@{ name = "zulu"; transport = "stdio"; command = "tool.exe"; args = @("zulu"); toolTimeoutSeconds = 120 }
                Write-ItlClientMcpEndpoints -Endpoints @($zulu, $alpha) -Owner "ondemand-facade" -Client "kilocode" | Out-Null
                $first = (Get-FileHash -LiteralPath (Join-Path $tempRoot ".kilo\kilo.json") -Algorithm SHA256).Hash
                Write-ItlClientMcpEndpoints -Endpoints @($alpha, $zulu) -Owner "ondemand-facade" -Client "kilocode" | Out-Null
                [pscustomobject]@{
                    first = $first
                    second = (Get-FileHash -LiteralPath (Join-Path $tempRoot ".kilo\kilo.json") -Algorithm SHA256).Hash
                    config = Get-Content -LiteralPath (Join-Path $tempRoot ".kilo\kilo.json") -Raw -Encoding UTF8 | ConvertFrom-Json
                }
            }

            $hashes.second | Should -Be $hashes.first; @($hashes.config.mcp.PSObject.Properties.Name) | Should -Be @("alpha", "custom", "zulu")
            $hashes.config.mcp.custom.url | Should -Be "http://custom"; $hashes.config.permission.bash | Should -Be "ask"
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-adapter-registry-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"aiRules":{"tools":["codex"]}}'
            $registry = & { . $HelperPath -ProjectRoot $tempRoot -Action help *> $null; Get-ItlClientAdapterRegistry }
            @($registry.Keys) | Should -Be @("codex", "kilocode", "claude-code", "cursor", "opencode", "kimi", "qwen", "command-code", "cline", "pi")
            $registry.codex.skillsPath | Should -Be ".agents/skills"
            $registry.codex.commandsPath | Should -Be ".agents/skills"
            $registry.codex.commandFormat | Should -Be "skill"
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
            $registry.opencode.workspacePluginSdkPackageName | Should -Be "@opencode-ai/sdk"
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
            $registry.cursor.mcpEnablementObservation | Should -Be "private-client-state"
            $registry.cursor.mcpEnablementUserInstruction | Should -Match ([regex]::Escape("+ → MCP Servers"))
            $registry.cursor.mcpEnablementUserInstruction | Should -Match "не предоставляет workflow доступ"
            foreach ($client in @($registry.Keys)) {
                [string]$registry[$client].reload | Should -Not -BeNullOrEmpty
                if ($client -ne "opencode") {
                    $registry[$client].devWorkspaceMode | Should -Be "external-create"
                    $registry[$client].workspaceProvider | Should -Be "git"
                    $registry[$client].workspacePluginPath | Should -Be ""
                    $registry[$client].workspacePluginPackageLockKey | Should -Be ""
                    $registry[$client].workspacePluginSdkPackageName | Should -Be ""
                    $registry[$client].PSObject.Properties.Name | Should -Not -Contain "requiredUserEnvironment"
                }
            }
            $vanessaSource = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.vanessa.ps1") -Raw -Encoding UTF8
            $vanessaSource | Should -Not -Match 'Vanessa authoring state'
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

    It "reports native mode from present entrypoints without using Markdown identity" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-openspec-native-" + [guid]::NewGuid().ToString("N"))
        try {
            New-OpenSpecModeFixture -Root $tempRoot -Client codex -Mode native
            $status = & { . $HelperPath -ProjectRoot $tempRoot -Action help *> $null; Get-AiRules1cOpenSpecStatus }
            $status.mode | Should -Be "native"
            $status.isAvailable | Should -BeTrue
            $status.invocations.propose | Should -Be '$opsx-propose'
            $status.invocations.explore | Should -Be '$opsx-explore'
            $status.invocations.apply | Should -Be '$opsx-apply'
            $status.invocations.archive | Should -Be '$opsx-archive'

            $manifestPath = Join-Path $tempRoot ".ai-rules.json"
            $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($property in @($manifest.files.PSObject.Properties)) {
                $property.Value.installedHash = ("0" * 64)
            }
            Set-Content -LiteralPath $manifestPath -Encoding UTF8 -Value (($manifest | ConvertTo-Json -Depth 10) + "`n")
            Set-Content -LiteralPath (Join-Path $tempRoot ".fixture-rules/sdd-integrations.md") -Encoding UTF8 -Value "OpenSpec integration fixture`r`nUser clarification`r`n"
            Set-Content -LiteralPath (Join-Path $tempRoot ".agents/skills/opsx-propose/SKILL.md") -Encoding UTF8 -Value "# explicit propose`r`nUser clarification`r`n"
            $modified = & { . $HelperPath -ProjectRoot $tempRoot -Action help *> $null; Get-AiRules1cOpenSpecStatus }
            $modified.mode | Should -Be "native"
            $modified.invocations.propose | Should -Be '$opsx-propose'

            Remove-Item -LiteralPath (Join-Path $tempRoot ".agents/skills/openspec-apply-change/SKILL.md") -Force
            Remove-Item -LiteralPath (Join-Path $tempRoot ".agents/skills/opsx-apply/SKILL.md") -Force
            $broken = & { . $HelperPath -ProjectRoot $tempRoot -Action help *> $null; Get-AiRules1cOpenSpecStatus }
            $broken.mode | Should -Be "unavailable"
            $broken.reason | Should -Match "required native OpenSpec phase"
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "keeps older Codex bundles available through canonical skill names" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-openspec-native-legacy-" + [guid]::NewGuid().ToString("N"))
        try {
            New-OpenSpecModeFixture -Root $tempRoot -Client codex -Mode native -IncludeOpsxAliases $false
            $status = & { . $HelperPath -ProjectRoot $tempRoot -Action help *> $null; Get-AiRules1cOpenSpecStatus }
            $status.mode | Should -Be "native"
            $status.invocations.propose | Should -Be '$openspec-propose'
            $status.invocations.apply | Should -Be '$openspec-apply-change'
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
        $masterTemplateRoot = Join-Path $RepoRoot ".agents\skills\1c-workflow\kilo-command-templates\master"
        $templates = [ordered]@{
            "itl.md" = Get-Content -LiteralPath (Join-Path $templateRoot "itl.md.template") -Raw -Encoding UTF8
            "itl-status.md" = Get-Content -LiteralPath (Join-Path $templateRoot "itl-status.md.template") -Raw -Encoding UTF8
            "itl-litemode.md" = Get-Content -LiteralPath (Join-Path $templateRoot "itl-litemode.md.template") -Raw -Encoding UTF8
            "itl-new-config-branch.md" = Get-Content -LiteralPath (Join-Path $masterTemplateRoot "itl-new-config-branch.md.template") -Raw -Encoding UTF8
            "itl-new-extension-branch.md" = Get-Content -LiteralPath (Join-Path $masterTemplateRoot "itl-new-extension-branch.md.template") -Raw -Encoding UTF8
        }
        $previousMode = [Environment]::GetEnvironmentVariable("ITL_ROUTINE_MODE", "Process")
        try {
            [Environment]::SetEnvironmentVariable("ITL_ROUTINE_MODE", "off", "Process")
            $adapted = & {
                . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
                $result = [ordered]@{}
                foreach ($client in @("codex", "kilocode", "claude-code", "cursor", "opencode", "kimi", "qwen", "command-code", "cline", "pi")) {
                    $result[$client] = [ordered]@{}
                    foreach ($fileName in $templates.Keys) {
                        $result[$client][$fileName] = Convert-ItlCommandForClient -Text $templates[$fileName] -Client $client -FileName $fileName
                    }
                }
                $result
            }

            foreach ($client in $adapted.Keys) {
                $adapted[$client]["itl.md"] | Should -Match "entire final response"
                $adapted[$client]["itl.md"] | Should -Match 'fenced `text` block'
                $adapted[$client]["itl-status.md"] | Should -Match "structured Russian Markdown report"
                $adapted[$client]["itl-status.md"] | Should -Match 'one `- Подпись: значение` field per line'
                $adapted[$client]["itl-status.md"] | Should -Match "Kilo Browser Automation"
                $adapted[$client]["itl-status.md"] | Should -Match "never omit, reword, or move"
                $adapted[$client]["itl-status.md"] | Should -Match "Cursor MCP Agent switches"
                $adapted[$client]["itl-status.md"] | Should -Match "separate permission boundary"
                $adapted[$client]["itl-status.md"] | Should -Match "Контекст разработки"
                $adapted[$client]["itl-litemode.md"] | Should -Match "complete helper stdout unchanged"
                $adapted[$client]["itl-litemode.md"] | Should -Match 'exactly one fenced `text` code block'
                foreach ($fileName in $templates.Keys) {
                    $adapted[$client][$fileName] | Should -Match '(?m)^description:\s*[^\r\n]*[А-Яа-яЁё]'
                    ([regex]::Matches([string]$adapted[$client][$fileName], 'ITL_EXPLICIT_ROUTINE_CONTRACT: self-contained-v2')).Count | Should -Be 1 -Because "$client $fileName"
                    $adapted[$client][$fileName] | Should -Match 'Do not preload `1c-workflow` or `1c-workflow-fast`'
                    $adapted[$client][$fileName] | Should -Match 'helper implementation, not a router-skill dependency'
                    $adapted[$client][$fileName] | Should -Match 'requiredAction`/`nextAction`.*explicit ITL wrapper.*wrapper alone'
                    $adapted[$client][$fileName] | Should -Match 'recovery without an explicit wrapper'
                    $adapted[$client][$fileName] | Should -Match 'at most one short sentence'
                    $adapted[$client][$fileName] | Should -Match 'first and only tool action'
                    $adapted[$client][$fileName] | Should -Match 'responseStyle'
                    $adapted[$client][$fileName] | Should -Match 'userReport` verbatim'
                    $adapted[$client][$fileName] | Should -Match 'userReportOmitted=true'
                    $adapted[$client][$fileName] | Should -Match 'full absolute `userReportPath`'
                    $adapted[$client][$fileName] | Should -Match 'userReportSource=status-json'
                }
            }
            $adapted.codex["itl.md"] | Should -Match '(?m)^name:\s*itl$'
            $adapted["opencode"]["itl-new-config-branch.md"] | Should -Match '(?m)^description:\s*Создать ветку конфигурации ITL'
            $adapted["opencode"]["itl-new-extension-branch.md"] | Should -Match '(?m)^description:\s*Создать ветку расширения ITL'
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

    It "separates Cursor MCP client config coverage from private Agent switches" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-cursor-mcp-enablement-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c\mcp"), (Join-Path $tempRoot ".cursor") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"aiRules":{"tools":["cursor"]}}'
            Set-Content -LiteralPath (Join-Path $tempRoot ".cursor\mcp.json") -Encoding UTF8 -Value '{"mcpServers":{"itl-roctup-data":{"command":"fixture"},"1C-docs-mcp":{"type":"http","url":"http://fixture.invalid/mcp"}}}'
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\mcp\client-managed.json") -Encoding UTF8 -Value '{"schemaVersion":1,"owners":{"cursor/ondemand-facade":["itl-roctup-data"],"cursor/vibecoding1c":["1C-docs-mcp","1c-code-metadata-mcp"]}}'

            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $observation = Get-ItlClientMcpEnablementObservation
                $status = (Write-ItlClientMcpEnablementStatusLines 6>&1) -join [Environment]::NewLine
                $mcpLines = [System.Collections.Generic.List[string]]::new()
                $adviceLines = [System.Collections.Generic.List[string]]::new()
                Add-ItlClientMcpEnablementRunUserReportLines -McpLines $mcpLines -AdviceLines $adviceLines
                [pscustomobject]@{
                    observation = $observation
                    status = $status
                    reportLines = @($mcpLines)
                    adviceLines = @($adviceLines)
                }
            }

            $result.observation.applicable | Should -BeTrue
            $result.observation.enablementState | Should -Be "not-observable"
            $result.observation.configuredCount | Should -Be 2
            $result.observation.configuredManagedCount | Should -Be 2
            $result.observation.expectedManagedCount | Should -Be 3
            @($result.observation.missingManagedServerIds) | Should -Be @("1c-code-metadata-mcp")
            $result.status | Should -Match "managed ITL coverage=2/3"
            $result.status | Should -Match "Cursor MCP missing managed servers: 1c-code-metadata-mcp"
            $result.status | Should -Match "Cursor MCP Agent switches: not observable by ITL"
            $result.status | Should -Match ([regex]::Escape("+ → MCP Servers"))
            ($result.reportLines -join "`n") | Should -Match "MCP в конфигурации Cursor: 2; управляемые ITL: 2/3"
            ($result.reportLines -join "`n") | Should -Match "Переключатели MCP в Cursor Agent: ITL не может проверить"
            ($result.adviceLines -join "`n") | Should -Match "В конфигурации Cursor отсутствуют управляемые MCP: 1c-code-metadata-mcp"
            ($result.adviceLines -join "`n") | Should -Match "Обязательная проверка Cursor:"
            ($result.adviceLines -join "`n") | Should -Match ([regex]::Escape("+ → MCP Servers"))
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "wires Cursor MCP enablement guidance into init branch refresh and status reports" {
        $lifecycleText = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.lifecycle.ps1") -Raw -Encoding UTF8
        foreach ($functionName in @("Write-InitRunUserReport", "Write-DevBranchRunUserReport")) {
            $block = [regex]::Match($lifecycleText, "(?s)function $functionName \{.*?(?=\r?\nfunction )").Value
            $block | Should -Not -BeNullOrEmpty
            ([regex]::Matches($block, "Add-ItlClientMcpEnablementRunUserReportLines")).Count | Should -Be 1 -Because $functionName
        }
        $statusBlock = [regex]::Match($lifecycleText, "(?s)function Show-WorkflowStatus \{.*?(?=\r?\nfunction )").Value
        $statusBlock | Should -Not -BeNullOrEmpty
        ([regex]::Matches($statusBlock, "Write-ItlClientMcpEnablementStatusLines")).Count | Should -Be 1
    }

    It "generates the documented routine surfaces for every new client" {
        $expected = [ordered]@{
            codex = ".agents/skills/itl/SKILL.md"
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
        [string]$result.codex[$expected.codex] | Should -Match '(?m)^name:\s*itl$'
        @($result.codex.Keys) | Should -Contain ".agents/skills/itl/agents/openai.yaml"
        [string]$result.codex[".agents/skills/itl/agents/openai.yaml"] | Should -Match '(?m)^  display_name: "itl"$'
        [string]$result.codex[".agents/skills/itl/agents/openai.yaml"] | Should -Match 'allow_implicit_invocation:\s*false'
        [string]$result.kimi[$expected.kimi] | Should -Match '(?m)^name:\s*itl$'
        [string]$result.cline[$expected.cline] | Should -Match '(?m)^name:\s*itl$'
    }

    It "generates only context-valid explicit Codex routine skills" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-codex-surface-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"masterBranch":"master","aiRules":{"tools":["codex"]}}'
            & git -C $tempRoot init *> $null
            & git -C $tempRoot branch -M master

            $masterFiles = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                Get-ItlExpectedSurfaceFiles -Client codex -SourceRoot $RepoRoot
            }
            @($masterFiles.Keys).Count | Should -Be 20
            foreach ($name in @("itl", "itl-status", "itl-litemode", "itl-sync-master", "itl-new-config-branch", "itl-new-extension-branch", "itl-refresh-all", "itl-update-workflow", "itl-repository-mode", "itl-switch-client")) {
                @($masterFiles.Keys) | Should -Contain ".agents/skills/$name/SKILL.md"
                @($masterFiles.Keys) | Should -Contain ".agents/skills/$name/agents/openai.yaml"
                [string]$masterFiles[".agents/skills/$name/agents/openai.yaml"] | Should -Match ("(?m)^  display_name: `"" + [regex]::Escape($name) + "`"$")
                [string]$masterFiles[".agents/skills/$name/SKILL.md"] | Should -Match 'ITL_EXPLICIT_ROUTINE_CONTRACT: self-contained-v2'
            }
            @($masterFiles.Keys) | Should -Not -Contain ".agents/skills/itl-check/SKILL.md"
            @($masterFiles.Keys) | Should -Not -Contain ".agents/skills/itl-fork-branch/SKILL.md"

            & git -C $tempRoot branch -M itldev/codex-surface
            $devFiles = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                Get-ItlExpectedSurfaceFiles -Client codex -SourceRoot $RepoRoot
            }
            @($devFiles.Keys).Count | Should -Be 28
            foreach ($name in @("itl", "itl-status", "itl-litemode", "itl-sync-master", "itl-check", "itl-verify-fix", "itl-refresh", "itl-refresh-lite", "itl-fork-branch", "itl-sync-branches", "itl-reset-branch", "itl-lock-objects", "itl-result", "itl-update-workflow")) {
                @($devFiles.Keys) | Should -Contain ".agents/skills/$name/SKILL.md"
                [string]$devFiles[".agents/skills/$name/agents/openai.yaml"] | Should -Match ("(?m)^  display_name: `"" + [regex]::Escape($name) + "`"$")
                [string]$devFiles[".agents/skills/$name/agents/openai.yaml"] | Should -Match 'allow_implicit_invocation:\s*false'
                $skillText = [string]$devFiles[".agents/skills/$name/SKILL.md"]
                if ($name -eq "itl-verify-fix") {
                    $skillText | Should -Not -Match 'ITL_EXPLICIT_ROUTINE_CONTRACT:'
                    $skillText | Should -Match ([regex]::Escape('.agents/skills/1c-workflow/references/vanessa-tests.md'))
                } else {
                    $skillText | Should -Match 'ITL_EXPLICIT_ROUTINE_CONTRACT: self-contained-v2'
                }
            }
            @($devFiles.Keys) | Should -Not -Contain ".agents/skills/itl-new-config-branch/SKILL.md"
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "keeps every generated Codex skill ignored when the dev surface is materialized" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-codex-ignore-surface-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            Copy-Item -LiteralPath (Join-Path $RepoRoot "templates\gitignore.append") -Destination (Join-Path $tempRoot ".gitignore")
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"masterBranch":"master","aiRules":{"tools":["codex"]}}'
            & git -C $tempRoot init *> $null
            & git -C $tempRoot config user.email "test@example.com"
            & git -C $tempRoot config user.name "Test User"
            & git -C $tempRoot add .gitignore .agent-1c/project.json
            & git -C $tempRoot commit -m "base" *> $null
            & git -C $tempRoot branch -M itldev/codex-surface

            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $expectedFiles = Get-ItlExpectedSurfaceFiles -Client codex -SourceRoot $RepoRoot
                Sync-ItlManagedSurfaceFiles -Client codex -ExpectedFiles $expectedFiles
                [pscustomobject]@{
                    hasForkSkill = Test-Path -LiteralPath (Join-Path $tempRoot ".agents\skills\itl-fork-branch\SKILL.md") -PathType Leaf
                    hasSyncSkill = Test-Path -LiteralPath (Join-Path $tempRoot ".agents\skills\itl-sync-branches\SKILL.md") -PathType Leaf
                    status = @(& git -C $tempRoot status --porcelain)
                }
            }

            $result.hasForkSkill | Should -BeTrue
            $result.hasSyncSkill | Should -BeTrue
            $result.status | Should -BeNullOrEmpty
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "renders ITL command examples in the active client syntax" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-active-command-syntax-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $values = [ordered]@{}
                foreach ($client in @("codex", "kilocode", "kimi")) {
                    Write-Utf8Text -Path (Join-Path $tempRoot ".agent-1c\project.json") -Value "{`"aiRules`":{`"tools`":[`"$client`"]}}"
                    [void](Read-ProjectConfig)
                    $values[$client] = ConvertTo-ItlActiveClientCommandText -Text "Рекомендуемый шаг: /itl-check"
                }
                $values
            }
            $result.codex | Should -Be 'Рекомендуемый шаг: $itl-check'
            $result.kilocode | Should -Be "Рекомендуемый шаг: /itl-check"
            $result.kimi | Should -Be "Рекомендуемый шаг: /skill:itl-check"
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
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

    It "does not rewrite an unchanged Kilo MCP config" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-kilo-mcp-idempotent-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"aiRules":{"tools":["kilocode"]}}'
            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $endpoints = @([pscustomobject]@{ name = "remote-test"; url = "https://itl.invalid/mcp"; transport = "remote" })
                $script:ItlClientMcpSemanticChanges = [ordered]@{}
                Write-ItlClientMcpEndpoints -Client kilocode -Owner test -Endpoints $endpoints | Out-Null
                $firstChangeCount = @(Get-ItlClientMcpSemanticChanges -Owner test).Count
                $path = Join-Path $tempRoot ".kilo\kilo.json"
                $sentinel = [DateTime]::UtcNow.AddHours(-2)
                [System.IO.File]::SetLastWriteTimeUtc($path, $sentinel)
                $script:ItlClientMcpSemanticChanges = [ordered]@{}
                Write-ItlClientMcpEndpoints -Client kilocode -Owner test -Endpoints $endpoints | Out-Null
                [pscustomobject]@{
                    expected = $sentinel
                    actual = [System.IO.File]::GetLastWriteTimeUtc($path)
                    firstChangeCount = $firstChangeCount
                    secondChangeCount = @(Get-ItlClientMcpSemanticChanges -Owner test).Count
                    orderedSignature = Get-ItlMcpOwnedSemanticSignature -Container ([ordered]@{ entry = [ordered]@{ type = "remote"; url = "https://itl.invalid/mcp" } }) -Names entry
                    reorderedSignature = Get-ItlMcpOwnedSemanticSignature -Container ([ordered]@{ entry = [ordered]@{ url = "https://itl.invalid/mcp"; type = "remote" } }) -Names entry
                }
            }
            $result.actual | Should -Be $result.expected
            $result.firstChangeCount | Should -Be 1
            $result.secondChangeCount | Should -Be 0
            $result.orderedSignature | Should -Be $result.reorderedSignature
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
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
                foreach ($componentCase in @(
                    @{ component = "yaxunit"; key = "ITL_YAXUNIT_TESTING" },
                    @{ component = "vanessa"; key = "ITL_VANESSA_TESTING" }
                )) {
                    foreach ($mode in @("auto", "manual", "off")) {
                        [Environment]::SetEnvironmentVariable($componentCase.key, $mode, "Process")
                        foreach ($trigger in @("implicit", "command", "repair")) {
                            $decision = Get-ItlVerificationExecutionDecision -Component $componentCase.component -Trigger $trigger
                            $expected = $mode -eq "auto" -or ($mode -eq "manual" -and $trigger -in @("command", "repair"))
                            $decision.run | Should -Be $expected
                        }
                        $explicit = Get-ItlVerificationExecutionDecision -Component $componentCase.component -Trigger explicit -ExplicitComponents $componentCase.component
                        $explicit.run | Should -BeTrue
                    }
                }
                [Environment]::SetEnvironmentVariable("ITL_VANESSA_TESTING", "broken", "Process")
                $invalid = Get-ItlVerificationMode -Component vanessa
                $invalid.valid | Should -BeFalse
                $invalid.effective | Should -Be "auto"
            }
        } finally {
            [Environment]::SetEnvironmentVariable("ITL_VANESSA_TESTING", $null, "Process")
            [Environment]::SetEnvironmentVariable("ITL_YAXUNIT_TESTING", $null, "Process")
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "changes only the three ITL verification keys through itl-litemode" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-lite-mode-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"aiRules":{"tools":["codex"]}}'
            Set-Content -LiteralPath (Join-Path $tempRoot ".dev.env") -Encoding UTF8 -Value "CUSTOM_KEEP=yes`nITL_YAXUNIT_TESTING=off`nITL_VANESSA_TESTING=auto`nITL_CHECK_EVENT_LOG=auto`n"
            & { . $HelperPath -ProjectRoot $tempRoot -Action help *> $null; Set-ItlLiteMode -Mode standard *> $null }
            $text = Get-Content -LiteralPath (Join-Path $tempRoot ".dev.env") -Raw -Encoding UTF8
            $text | Should -Match '(?m)^CUSTOM_KEEP=yes\r?$'
            $text | Should -Match '(?m)^ITL_YAXUNIT_TESTING=auto\r?$'
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
                    $agentText | Should -Match "helper's runtime responseStyle profile"
                    $agentText | Should -Match 'progress to one current-stage line'
                    $agentText | Should -Match 'compact helper summary verbatim'
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
        $routing = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            [pscustomobject]@{
                listed = (Get-ItlRoutineCommandNames) -contains "itl-vanessa-author.md"
                verifyFixListed = (Get-ItlRoutineCommandNames) -contains "itl-verify-fix.md"
                opencodeVerifyFix = Convert-ItlCommandForClient -Text $verifyFix -Client "opencode" -FileName "itl-verify-fix.md"
            }
        }
        $routing.listed | Should -BeFalse
        $routing.verifyFixListed | Should -BeFalse
        $routing.opencodeVerifyFix | Should -Match '(?m)^agent:\s*build\s*$'
        $routing.opencodeVerifyFix | Should -Not -Match 'ITL_EXPLICIT_ROUTINE_CONTRACT:'
        $routing.opencodeVerifyFix | Should -Match ([regex]::Escape('.agents/skills/1c-workflow/references/vanessa-tests.md'))
        Test-Path -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\kilo-command-templates\dev\itl-vanessa-author.md.template") | Should -BeFalse
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
            "df5150b2383d145028670f7a770d3c396e211910fd353cd4e5209a047442d6d9",
            "782efb40f1db49711747401644f19f523606c384a7c9b739dc13a25ffed9b6c7",
            "4e48bfb2991a1661cea3283536e69185252b51ab1273b62b8d2371c7742b5746",
            "5ef04f1afe7e2203e46879fc28b0741d6a4624eae4e53dbc022a479064d31adf"
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

    It "keeps doctor read-only without duplicating managed-file integrity" {
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
                $skillText = if ($skill -eq "1c-workflow-fast") { "# $skill`n<!-- ITL_KILO_SKILL_CONTRACT: fixture -->" } else { "# $skill" }
                Set-Content -LiteralPath $path -Encoding UTF8 -Value $skillText
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
            Add-Content -LiteralPath $rulePath -Encoding UTF8 -Value "User clarification"
            $lock = [ordered]@{ dependencies = [ordered]@{ aiRules1c = [ordered]@{ repo = "https://github.com/xmentosx/itl_ai_rules_1c.git"; ref = "itl-main-b4d9875b-r11"; commit = "af82570afca06c40a9588c8a678bf3665bba4870"; upstreamCommit = "b4d9875b15c6d93f493035aee51f077126e72a21"; downstreamRevision = 11; compatibilityStatus = "passed" } } }
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\dependency-lock.json") -Encoding UTF8 -Value (($lock | ConvertTo-Json -Depth 8) + "`n")
            & git -C $tempRoot init *> $null
            & git -C $tempRoot branch -M master
            $before = (Get-ChildItem -LiteralPath $tempRoot -Recurse -File | ForEach-Object { "$($_.FullName.Substring($tempRoot.Length))=$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)" }) -join "`n"
            $output = & { . $HelperPath -ProjectRoot $tempRoot -Action help *> $null; function Get-ItlRtkStatus { [pscustomobject]@{ status = "SKIP"; detail = "fixture" } }; Show-ItlDoctor } 6>&1 | Out-String
            $after = (Get-ChildItem -LiteralPath $tempRoot -Recurse -File | ForEach-Object { "$($_.FullName.Substring($tempRoot.Length))=$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)" }) -join "`n"
            $output | Should -Match '\[OK\] active-client'
            $output | Should -Not -Match 'managed-integrity'
            $output | Should -Match '\[OK\] openspec'
            $output | Should -Match '\[SKIP\] branch-infobase'
            $after | Should -Be $before
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "reports a healthy natural OpenSpec mode as OK in doctor" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-doctor-openspec-natural-" + [guid]::NewGuid().ToString("N"))
        try {
            New-OpenSpecModeFixture -Root $tempRoot -Client qwen -Mode natural
            $projectConfig = [ordered]@{ masterBranch = "master"; aiRules = [ordered]@{ repo = "https://github.com/xmentosx/itl_ai_rules_1c.git"; ref = "itl-main-410951e7-r24"; tools = @("qwen") } }
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c/project.json") -Encoding UTF8 -Value (($projectConfig | ConvertTo-Json -Depth 6) + "`n")
            $lock = [ordered]@{ dependencies = [ordered]@{ aiRules1c = [ordered]@{ repo = "https://github.com/xmentosx/itl_ai_rules_1c.git"; ref = "itl-main-410951e7-r24"; commit = "83e179469363c16497d9cc389a9a814537cc076b"; upstreamCommit = "410951e74fd3e6b7a763cf49757935b9a34d3f31"; downstreamRevision = 24; compatibilityStatus = "passed" } } }
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

            Remove-Item -LiteralPath (Join-Path $tempRoot "openspec/project.md") -Force
            $degraded = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                function Get-ItlRtkStatus { [pscustomobject]@{ status = "SKIP"; detail = "fixture" } }
                Show-ItlDoctor
                "doctor-completed"
            } 6>&1 | Out-String
            $degraded | Should -Match '\[WARN\] openspec: mode=unavailable'
            $degraded | Should -Match 'doctor-completed'
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
