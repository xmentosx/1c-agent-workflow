function Get-ItlClientAdapterRegistry {
    $registry = [ordered]@{
        codex = [ordered]@{
            id = "codex"
            rulesPath = ".codex/rules"
            agentsPath = ".codex/agents"
            commandsPath = ""
            skillsPath = ".agents/skills"
            mcpPath = ".codex/config.toml"
            commandFormat = "none"
            commandRouting = "none"
            nativeAgents = $true
            mcpFormat = "toml"
            mcpContainer = "mcp_servers"
            mcpStdioFormat = "standard"
            mcpRemoteFormat = "url"
            trackedMcpConfig = $false
            reload = "Start a new Codex task so project rules and skills are reread."
        }
        kilocode = [ordered]@{
            id = "kilocode"
            rulesPath = ".kilo/rules-1c"
            agentsPath = ".kilo/agents"
            commandsPath = ".kilo/commands"
            skillsPath = ".kilo/skills"
            mcpPath = ".kilo/kilo.json"
            commandFormat = "markdown"
            commandRouting = "kilocode"
            routineAgentPath = ".kilo/agents/itl-routine.md"
            nativeAgents = $true
            mcpFormat = "json"
            mcpContainer = "mcp"
            mcpStdioFormat = "local-array"
            mcpRemoteFormat = "remote-timeout"
            trackedMcpConfig = $false
            configCollisionCheck = "kilo-jsonc"
            disableSnapshots = $true
            legacyKiloCommands = $true
            untrackGeneratedCommands = $true
            reload = "Run /reload or restart Kilo Code."
        }
        "claude-code" = [ordered]@{
            id = "claude-code"
            rulesPath = ".claude/rules"
            agentsPath = ".claude/agents"
            commandsPath = ".claude/commands"
            skillsPath = ".claude/skills"
            mcpPath = ".mcp.json"
            commandFormat = "markdown"
            commandRouting = "none"
            nativeAgents = $true
            mcpFormat = "json"
            mcpContainer = "mcpServers"
            mcpStdioFormat = "standard"
            mcpRemoteFormat = "http"
            trackedMcpConfig = $false
            reload = "Restart Claude Code."
        }
        cursor = [ordered]@{
            id = "cursor"
            rulesPath = ".cursor/rules"
            agentsPath = ".cursor/agents"
            commandsPath = ".cursor/commands"
            skillsPath = ".cursor/skills"
            mcpPath = ".cursor/mcp.json"
            commandFormat = "markdown"
            commandRouting = "none"
            nativeAgents = $true
            mcpFormat = "json"
            mcpContainer = "mcpServers"
            mcpStdioFormat = "standard"
            mcpRemoteFormat = "http"
            trackedMcpConfig = $true
            reload = "Reload the Cursor window."
        }
        opencode = [ordered]@{
            id = "opencode"
            rulesPath = ".opencode/rules"
            agentsPath = ".opencode/agent"
            commandsPath = ".opencode/command"
            skillsPath = ".claude/skills"
            mcpPath = "opencode.json"
            commandFormat = "markdown"
            commandRouting = "opencode"
            routineAgentPath = ".opencode/agent/itl-routine.md"
            nativeAgents = $true
            mcpFormat = "json"
            mcpContainer = "mcp"
            mcpStdioFormat = "local-array"
            mcpRemoteFormat = "remote"
            trackedMcpConfig = $true
            mcpKeyMode = "letter-prefix"
            devWorkspaceMode = "client-native-adopt"
            workspaceProvider = "opencode"
            handoffMode = "native-workspace"
            workspacePluginPath = ".opencode/plugins/itl-workspace.js"
            workspacePluginPackageLockKey = "opencodePlugin"
            workspacePluginPackageName = "@opencode-ai/plugin"
            workspacePluginRuntimePath = ".opencode"
            requiredUserEnvironment = [ordered]@{
                OPENCODE_EXPERIMENTAL_WORKSPACES = "true"
            }
            reload = "Restart OpenCode."
        }
        kimi = [ordered]@{
            id = "kimi"
            rulesPath = ".kimi-code/rules-1c"
            agentsPath = ".kimi-code/rules-1c/agents"
            commandsPath = ".kimi-code/skills"
            skillsPath = ".kimi-code/skills"
            mcpPath = ".kimi-code/mcp.json"
            commandFormat = "skill"
            commandRouting = "none"
            nativeAgents = $false
            mcpFormat = "json"
            mcpContainer = "mcpServers"
            mcpStdioFormat = "standard"
            mcpRemoteFormat = "http"
            trackedMcpConfig = $false
            reload = "Restart Kimi Code; invoke ITL routines as /skill:itl-* commands."
        }
        qwen = [ordered]@{
            id = "qwen"
            rulesPath = ".qwen/rules-1c"
            agentsPath = ".qwen/agents"
            commandsPath = ".qwen/commands"
            skillsPath = ".qwen/skills"
            mcpPath = ".qwen/settings.json"
            commandFormat = "markdown"
            commandRouting = "none"
            nativeAgents = $true
            mcpFormat = "json"
            mcpContainer = "mcpServers"
            mcpStdioFormat = "standard"
            mcpRemoteFormat = "qwen-http"
            trackedMcpConfig = $false
            reload = "Restart Qwen Code."
        }
        "command-code" = [ordered]@{
            id = "command-code"
            executable = "command-code"
            rulesPath = ".commandcode/rules-1c"
            agentsPath = ".commandcode/agents"
            commandsPath = ".commandcode/commands"
            skillsPath = ".commandcode/skills"
            mcpPath = ".mcp.json"
            commandFormat = "markdown"
            commandRouting = "none"
            nativeAgents = $true
            mcpFormat = "json"
            mcpContainer = "mcpServers"
            mcpStdioFormat = "standard"
            mcpRemoteFormat = "http"
            trackedMcpConfig = $false
            reload = "Restart Command Code."
        }
        cline = [ordered]@{
            id = "cline"
            rulesPath = ".cline/rules-1c"
            agentsPath = ".cline/rules-1c/agents"
            commandsPath = ".cline/skills"
            skillsPath = ".cline/skills"
            mcpPath = ".cline/mcp.json"
            commandFormat = "skill"
            commandRouting = "none"
            nativeAgents = $false
            mcpFormat = "json"
            mcpContainer = "mcpServers"
            mcpStdioFormat = "standard"
            mcpRemoteFormat = "cline-http"
            trackedMcpConfig = $false
            reload = "Restart Cline; invoke ITL routines as /itl-* skills."
        }
        pi = [ordered]@{
            id = "pi"
            rulesPath = ".pi/rules-1c"
            agentsPath = ".pi/rules-1c/agents"
            commandsPath = ".pi/prompts"
            skillsPath = ".pi/skills"
            mcpPath = ".pi/mcp.json"
            commandFormat = "prompt"
            commandRouting = "none"
            nativeAgents = $false
            mcpFormat = "json"
            mcpContainer = "mcpServers"
            mcpStdioFormat = "pi"
            mcpRemoteFormat = "pi-http"
            trackedMcpConfig = $false
            requiredPackagePath = ".pi/settings.json"
            requiredPackageKey = "packages"
            requiredPackage = "npm:pi-mcp-extension@1.5.0"
            requiredPackageIntegrity = "sha512-tfsgi8qSr3UUKMp4vS9/FwKv+Pn2U4T/rTlAwrZkEIvz616mFrU/Ryp3b69ZDfFdkQVVXriaQmZUj4vlZDV2Uw=="
            minimumNodeMajor = 22
            reload = "Trust the project and restart Pi so .pi settings, prompts, skills, and MCP extension are loaded."
        }
    }

    foreach ($client in @($registry.Keys)) {
        $entry = $registry[$client]
        if (-not $entry.Contains("devWorkspaceMode")) { $entry["devWorkspaceMode"] = "external-create" }
        if (-not $entry.Contains("workspaceProvider")) { $entry["workspaceProvider"] = "git" }
        if (-not $entry.Contains("handoffMode")) { $entry["handoffMode"] = "editor-open" }
        if (-not $entry.Contains("workspacePluginPath")) { $entry["workspacePluginPath"] = "" }
        if (-not $entry.Contains("workspacePluginPackageLockKey")) { $entry["workspacePluginPackageLockKey"] = "" }
        if (-not $entry.Contains("workspacePluginPackageName")) { $entry["workspacePluginPackageName"] = "" }
        if (-not $entry.Contains("workspacePluginRuntimePath")) { $entry["workspacePluginRuntimePath"] = "" }
    }
    return $registry
}

function Get-ItlClientAdapter {
    param([string]$Client = "")

    if ([string]::IsNullOrWhiteSpace($Client)) {
        $Client = [string](@(Get-AgentTargets) | Select-Object -First 1)
    }
    $Client = $Client.Trim().ToLowerInvariant()
    $registry = Get-ItlClientAdapterRegistry
    if (-not $registry.Contains($Client)) {
        throw "Unsupported ITL client '$Client'. Supported clients: $((Get-SupportedAgentTargets) -join ', ')."
    }
    return [pscustomobject]$registry[$Client]
}

function Get-ItlActiveClient {
    $configured = @(Get-AgentTargets)
    if ($configured.Count -ne 1) {
        throw "Exactly one configured ITL client is required."
    }
    $manifest = Get-AiRules1cProjectManifest
    if ($null -ne $manifest) {
        $installed = @(Get-AiRules1cManifestToolNames -Manifest $manifest)
        if ($installed.Count -ne 1 -or $installed[0] -ne $configured[0]) {
            throw "Configured and installed ai_rules_1c clients disagree. Configured: $($configured -join ', '). Installed: $($installed -join ', '). Run pinned update-ai-rules from master."
        }
    }
    return [string]$configured[0]
}

function Test-ItlGitPathTracked {
    param([string]$RelativePath)

    if (-not (Test-Path -LiteralPath (Join-Path $script:ProjectRoot ".git") -ErrorAction SilentlyContinue)) {
        return $false
    }
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & git -C $script:ProjectRoot ls-files --error-unmatch -- $RelativePath *> $null
        return ($LASTEXITCODE -eq 0)
    } finally {
        $ErrorActionPreference = $previous
    }
}

function Assert-ItlClientConfigWritable {
    param(
        [string]$Client,
        [switch]$ExplicitMigration
    )

    $adapter = Get-ItlClientAdapter -Client $Client
    if ($adapter.PSObject.Properties.Name -contains "configCollisionCheck" -and $adapter.configCollisionCheck -eq "kilo-jsonc") {
        $json = Join-Path $script:ProjectRoot ".kilo\kilo.json"
        $jsonc = Join-Path $script:ProjectRoot ".kilo\kilo.jsonc"
        if ((Test-Path -LiteralPath $json -PathType Leaf) -and (Test-Path -LiteralPath $jsonc -PathType Leaf)) {
            throw "KILO_CONFIG_COLLISION: both .kilo/kilo.json and .kilo/kilo.jsonc exist. Consolidate them explicitly before ITL writes managed Kilo state."
        }
    }

    $trackedConfig = $(if ($adapter.trackedMcpConfig) { [string]$adapter.mcpPath } else { "" })
    if ($trackedConfig -and (Test-ItlGitPathTracked -RelativePath $trackedConfig) -and -not $ExplicitMigration) {
        throw "TRACKED_CLIENT_CONFIG: '$trackedConfig' is tracked. ITL will not modify it without an explicit client-config migration."
    }
}

function Set-KiloSnapshotsDisabled {
    $configPath = Join-Path $script:ProjectRoot ".kilo\kilo.json"
    $jsoncPath = Join-Path $script:ProjectRoot ".kilo\kilo.jsonc"
    if ((Test-Path -LiteralPath $jsoncPath -PathType Leaf) -and -not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        throw "KILO_CONFIG_COLLISION: ITL cannot safely preserve comments while setting snapshot=false in .kilo/kilo.jsonc. Rename it to .kilo/kilo.json first."
    }

    $config = if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        ConvertTo-Agent1cHashtable -Object (Read-Utf8Text -Path $configPath | ConvertFrom-Json)
    } else {
        [ordered]@{}
    }
    if ($config.Contains("snapshot") -and $config["snapshot"] -eq $false) {
        return
    }

    $config["snapshot"] = $false
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $configPath) | Out-Null
    Write-Utf8Text -Path $configPath -Value (($config | ConvertTo-Json -Depth 30) + [Environment]::NewLine)
}

function Get-ItlManagedMcpStatePath {
    return (Join-Path $script:ProjectRoot ".agent-1c\mcp\client-managed.json")
}

function Get-ItlClientSurfaceStatePath {
    return (Join-Path $script:ProjectRoot ".agent-1c\client-surface.json")
}

function Read-ItlClientSurfaceState {
    $path = Get-ItlClientSurfaceStatePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [ordered]@{ schemaVersion = 1; clients = [ordered]@{} }
    }
    try {
        $state = ConvertTo-Vibecoding1cMcpHashtable -Object (Read-Utf8Text -Path $path | ConvertFrom-Json)
        if (-not $state.Contains("clients")) { $state["clients"] = [ordered]@{} }
        return $state
    } catch {
        throw "ITL client surface state is invalid: $path. $($_.Exception.Message)"
    }
}

function Write-ItlClientSurfaceState {
    param([object]$State)
    Write-Utf8Text -Path (Get-ItlClientSurfaceStatePath) -Value (($State | ConvertTo-Json -Depth 12) + [Environment]::NewLine)
}

function Get-ItlFileSha256 {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Test-ItlKnownLegacyKiloCommandHash {
    param([string]$Hash)
    return $Hash -in @(
        "5533dfbd12f58acfe7d81bf12d7b61f77f82341e7a87415c0e4ee0e6c996bdcf",
        "1010d5c6c5c56c0f4fc8ac98af8776da42deba6426e0edbd7175d28fa2cf3424",
        "960430f846cc2f9bcb412336e28f284e04ade925ca0bbd98262a6feca42c9115",
        "f654eaaef1535f99781a45fa8fdff926623164b7e1eb5e7c35fa7eaa3ce5d93b",
        "4329c97b3798efe87e75f5cdd8f7a86a60039ea946206507a072700d198f0ccc",
        "df5150b2383d145028670f7a770d3c396e211910fd353cd4e5209a047442d6d9",
        "a48e6e0b25caab6fea786664893801e18426056fbe9bb2485511cc2b57eebf87",
        "4c46e7d1cef2abb027c11b9a0dc27ec90663450f0adb082f13404b5d73936cad",
        "0fe573f21aebc00aad034caf36c3d02a5ff9be35ed4cb16c94f758f57d3c64a5",
        "5434fe9229889578bf79258fa9858b2addfb34c69491bb60cae08f0f8e3b67cd",
        "d8482aeed8ca0ef3761f7522aefaa15f1eb2c7b5b774dab3d679f2daaf6233f9",
        "187cdc3c55a42ce495c7bf2b2a8cf069128092b8b4c380d818ba32a2610d1dab",
        "6ebbfb4b929bdbb922413dcf583ef38e2bab5687da73801ff2e0254b9696a2ce",
        "b2256ee8a93a826208d5ab1bcc1d11d51ab48258ba73604177d63dbdbb160c1a",
        "3a96fa2243ff6bc8f32b9689b3aed0189e633786755864829f477100c6794419"
    )
}

function Assert-ItlManagedSurfaceFileUnmodified {
    param([string]$RelativePath, [string]$ExpectedHash)
    $path = Join-Path $script:ProjectRoot $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
    $actual = Get-ItlFileSha256 -Path $path
    if ($actual -ne $ExpectedHash) {
        throw "ITL_SURFACE_USER_MODIFIED: managed file '$RelativePath' differs from its recorded hash. Preserve or reconcile it explicitly before update/client switch."
    }
}

function Read-ItlManagedMcpState {
    $path = Get-ItlManagedMcpStatePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return [ordered]@{ schemaVersion = 1; owners = [ordered]@{} } }
    try { return (ConvertTo-Vibecoding1cMcpHashtable -Object (Read-Utf8Text -Path $path | ConvertFrom-Json)) } catch { throw "Managed MCP state is invalid: $path. $($_.Exception.Message)" }
}

function Write-ItlManagedMcpState {
    param([object]$State)
    Write-Utf8Text -Path (Get-ItlManagedMcpStatePath) -Value (($State | ConvertTo-Json -Depth 12) + [Environment]::NewLine)
}

function ConvertTo-ItlClientMcpKey {
    param([string]$Name, [string]$Client)
    $adapter = Get-ItlClientAdapter -Client $Client
    if ($adapter.PSObject.Properties.Name -contains "mcpKeyMode" -and $adapter.mcpKeyMode -eq "letter-prefix") {
        if ($Name -match '^(?i)1c(?<tail>.*)$') { return "onec$($Matches['tail'])" }
        if ($Name -notmatch '^[A-Za-z]') { return "mcp-$Name" }
    }
    return $Name
}

function Write-ItlClientMcpEndpoints {
    param(
        [object[]]$Endpoints,
        [string]$Owner,
        [string]$Client = ""
    )

    if (-not $Client) { $Client = Get-ItlActiveClient }
    Assert-ItlClientConfigWritable -Client $Client
    $adapter = Get-ItlClientAdapter -Client $Client
    $path = Join-Path $script:ProjectRoot $adapter.mcpPath
    $normalized = @($Endpoints | ForEach-Object {
        $name = [string]$_.name
        $url = [string](Get-Vibecoding1cMcpObjectValue -Object $_ -Name "url" -Default "")
        $transport = [string](Get-Vibecoding1cMcpObjectValue -Object $_ -Name "transport" -Default $(if ($url) { "remote" } else { "" }))
        $command = [string](Get-Vibecoding1cMcpObjectValue -Object $_ -Name "command" -Default "")
        $arguments = @(Get-Vibecoding1cMcpObjectValue -Object $_ -Name "args" -Default @())
        $environment = Get-Vibecoding1cMcpObjectValue -Object $_ -Name "env" -Default ([ordered]@{})
        $startupTimeout = ConvertTo-IntOrDefault -Value (Get-Vibecoding1cMcpObjectValue -Object $_ -Name "startupTimeoutSeconds" -Default 20) -Default 20
        $toolTimeout = ConvertTo-IntOrDefault -Value (Get-Vibecoding1cMcpObjectValue -Object $_ -Name "toolTimeoutSeconds" -Default 120) -Default 120
        if ($name -and (($transport -eq "remote" -and $url) -or ($transport -eq "stdio" -and $command))) {
            [pscustomobject]@{
                name = (ConvertTo-ItlClientMcpKey -Name $name -Client $Client)
                transport = $transport
                url = $url
                command = $command
                args = @($arguments | ForEach-Object { [string]$_ })
                env = $environment
                startupTimeoutSeconds = $startupTimeout
                toolTimeoutSeconds = $toolTimeout
            }
        }
    })

    if ($adapter.mcpFormat -eq "toml") {
        $lines = [System.Collections.Generic.List[string]]::new()
        foreach ($endpoint in @($normalized | Sort-Object name)) {
            $lines.Add("[mcp_servers.$(ConvertTo-Vibecoding1cMcpTomlString $endpoint.name)]")
            if ($endpoint.transport -eq "stdio") {
                $lines.Add("command = $(ConvertTo-Vibecoding1cMcpTomlString $endpoint.command)")
                $tomlArguments = @($endpoint.args | ForEach-Object { ConvertTo-Vibecoding1cMcpTomlString ([string]$_) }) -join ", "
                $lines.Add("args = [$tomlArguments]")
            } else {
                $lines.Add("url = $(ConvertTo-Vibecoding1cMcpTomlString $endpoint.url)")
            }
            $lines.Add("enabled = true")
            $lines.Add("startup_timeout_sec = $($endpoint.startupTimeoutSeconds)")
            $lines.Add("tool_timeout_sec = $($endpoint.toolTimeoutSeconds)")
            $environment = ConvertTo-Vibecoding1cMcpHashtable -Object $endpoint.env
            if ($endpoint.transport -eq "stdio" -and $environment.Count -gt 0) {
                $lines.Add("")
                $lines.Add("[mcp_servers.$(ConvertTo-Vibecoding1cMcpTomlString $endpoint.name).env]")
                foreach ($key in @($environment.Keys | Sort-Object)) {
                    $lines.Add("$(ConvertTo-Vibecoding1cMcpTomlString ([string]$key)) = $(ConvertTo-Vibecoding1cMcpTomlString ([string]$environment[$key]))")
                }
            }
            $lines.Add("")
        }
        Set-Vibecoding1cMcpManagedTextBlock -Path $path -BlockId $Owner -Body ((@($lines) -join [Environment]::NewLine).TrimEnd())
        return $path
    }

    $config = [ordered]@{}
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        try { $config = ConvertTo-Vibecoding1cMcpHashtable -Object (Read-Utf8Text -Path $path | ConvertFrom-Json) } catch { throw "Client MCP config is not valid JSON: $path. $($_.Exception.Message)" }
    }
    $containerName = [string]$adapter.mcpContainer
    $container = [ordered]@{}
    if ($config.Contains($containerName)) { $container = ConvertTo-Vibecoding1cMcpHashtable -Object $config[$containerName] }
    if ($Owner -eq "vibecoding1c") {
        foreach ($key in @($container.Keys)) {
            $entry = $container[$key]
            $managedBy = [string](Get-Vibecoding1cMcpObjectValue -Object $entry -Name "managedBy" -Default "")
            $family = [string](Get-Vibecoding1cMcpObjectValue -Object $entry -Name "family" -Default "")
            if ($managedBy -eq "vibecoding1c-mcp" -and $family -eq "vibecoding1c") {
                $container.Remove($key)
            }
        }
    }
    $state = Read-ItlManagedMcpState
    if (-not $state.Contains("owners")) { $state["owners"] = [ordered]@{} }
    $owners = ConvertTo-Vibecoding1cMcpHashtable -Object $state["owners"]
    $stateKey = "$Client/$Owner"
    foreach ($oldKey in @($owners[$stateKey])) { if ($container.Contains([string]$oldKey)) { $container.Remove([string]$oldKey) } }
    $written = @()
    foreach ($endpoint in $normalized) {
        $entry = if ($endpoint.transport -eq "stdio" -and $adapter.mcpStdioFormat -eq "local-array") {
            $local = [ordered]@{
                type = "local"
                command = @($endpoint.command) + @($endpoint.args)
                enabled = $true
                timeout = ([int]$endpoint.toolTimeoutSeconds * 1000)
            }
            $environment = ConvertTo-Vibecoding1cMcpHashtable -Object $endpoint.env
            if ($environment.Count -gt 0) { $local["environment"] = $environment }
            $local
        } elseif ($endpoint.transport -eq "stdio" -and $adapter.mcpStdioFormat -eq "pi") {
            $local = [ordered]@{ lifecycle = "eager"; transport = "stdio"; command = $endpoint.command; args = @($endpoint.args) }
            $environment = ConvertTo-Vibecoding1cMcpHashtable -Object $endpoint.env
            if ($environment.Count -gt 0) { $local["env"] = $environment }
            $local
        } elseif ($endpoint.transport -eq "stdio") {
            $local = [ordered]@{ command = $endpoint.command; args = @($endpoint.args) }
            $environment = ConvertTo-Vibecoding1cMcpHashtable -Object $endpoint.env
            if ($environment.Count -gt 0) { $local["env"] = $environment }
            $local
        } elseif ($adapter.mcpRemoteFormat -eq "remote-timeout") {
            [ordered]@{ type = "remote"; url = $endpoint.url; enabled = $true; timeout = ([int]$endpoint.toolTimeoutSeconds * 1000) }
        } elseif ($adapter.mcpRemoteFormat -eq "remote") {
            [ordered]@{ type = "remote"; url = $endpoint.url; enabled = $true }
        } elseif ($adapter.mcpRemoteFormat -eq "qwen-http") {
            [ordered]@{ httpUrl = $endpoint.url }
        } elseif ($adapter.mcpRemoteFormat -eq "cline-http") {
            [ordered]@{ type = "streamableHttp"; url = $endpoint.url }
        } elseif ($adapter.mcpRemoteFormat -eq "pi-http") {
            [ordered]@{ lifecycle = "eager"; transport = "streamable-http"; url = $endpoint.url }
        } else {
            [ordered]@{ type = "http"; url = $endpoint.url }
        }
        $container[$endpoint.name] = $entry
        $written += $endpoint.name
    }
    $config[$containerName] = $container
    Write-Vibecoding1cMcpJsonFile -Path $path -Value $config
    $owners[$stateKey] = @($written)
    $state["owners"] = $owners
    Write-ItlManagedMcpState -State $state
    return $path
}

function Remove-ItlLegacyBranchMcpEntries {
    param([string]$Client = "")
    if (-not $Client) { $Client = Get-ItlActiveClient }
    # Generic owner cleanup handles Codex managed text blocks and any JSON keys
    # recorded by newer legacy versions.
    Write-ItlClientMcpEndpoints -Endpoints @() -Owner "branch-runtime" -Client $Client | Out-Null
    $adapter = Get-ItlClientAdapter -Client $Client
    if ($adapter.mcpFormat -eq "toml") { return }
    $path = Join-Path $script:ProjectRoot $adapter.mcpPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
    $config = ConvertTo-Vibecoding1cMcpHashtable -Object (Read-Utf8Text -Path $path | ConvertFrom-Json)
    $containerName = [string]$adapter.mcpContainer
    if (-not $config.Contains($containerName)) { return }
    $container = ConvertTo-Vibecoding1cMcpHashtable -Object $config[$containerName]
    $changed = $false
    foreach ($key in @($container.Keys)) {
        $managedBy = [string](Get-Vibecoding1cMcpObjectValue -Object $container[$key] -Name "managedBy" -Default "")
        if ($managedBy -in @("itl-branch-mcp", "vanessa-mcp", "vanessa-ui-mcp")) {
            $container.Remove($key)
            $changed = $true
        }
    }
    if ($changed) {
        $config[$containerName] = $container
        Write-Vibecoding1cMcpJsonFile -Path $path -Value $config
    }
}

function Get-ItlCommandSurface {
    try { $branch = Get-CurrentBranch } catch { return "unknown" }
    if ($branch -eq (Get-MasterBranch)) { return "master" }
    if ($branch -like "itldev/*") { return "dev" }
    return "unknown"
}

function Get-ItlRoutineCommandNames {
    return @(
        "itl.md", "itl-status.md", "itl-new-config-branch.md",
        "itl-new-extension-branch.md", "itl-check.md", "itl-refresh.md",
        "itl-result.md", "itl-update-workflow.md", "itl-litemode.md",
        "itl-switch-client.md"
    )
}

function Get-ItlRoutineLongCommandNames {
    return @(
        "itl-new-config-branch.md", "itl-new-extension-branch.md",
        "itl-check.md", "itl-refresh.md", "itl-result.md",
        "itl-update-workflow.md", "itl-switch-client.md"
    )
}

function Get-ItlRoutineMode {
    $value = ([string](Get-EnvValue -Name "ITL_ROUTINE_MODE" -Default "off")).Trim().ToLowerInvariant()
    if (-not $value) { return "off" }
    if ($value -in @("off", "auto", "on")) { return $value }

    if (-not (Test-Path Variable:script:ItlRoutineModeWarningWritten) -or -not $script:ItlRoutineModeWarningWritten) {
        Write-Warning "Unknown ITL_ROUTINE_MODE '$value'; using safe default 'off'. Valid values: off, auto, on."
        $script:ItlRoutineModeWarningWritten = $true
    }
    return "off"
}

function Get-ItlRoutineModel {
    $model = ([string](Get-EnvValue -Name "SUBAGENT_MODEL_LIGHT" -Default "")).Trim()
    if ($model -and $model -notmatch '^[^/\s]+/[^/\s]+$') {
        throw "SUBAGENT_MODEL_LIGHT must use provider/model format when ITL routine mode is enabled."
    }
    return $model
}

function Test-ItlRoutineEnabledForCommand {
    param([string]$FileName)

    if ($FileName -notin (Get-ItlRoutineCommandNames)) { return $false }
    $mode = Get-ItlRoutineMode
    if ($mode -eq "off") { return $false }

    $model = Get-ItlRoutineModel
    if ($mode -eq "on") {
        if (-not $model) {
            throw "ITL_ROUTINE_MODE=on requires an explicit SUBAGENT_MODEL_LIGHT in provider/model format; parent-model inheritance is forbidden."
        }
        return $true
    }
    return ($model -and $FileName -in (Get-ItlRoutineLongCommandNames))
}

function New-ItlRoutineAgentText {
    param([ValidateSet("kilocode", "opencode")][string]$Client)

    $model = Get-ItlRoutineModel
    if (-not $model) {
        throw "itl-routine for $Client requires an explicit SUBAGENT_MODEL_LIGHT; parent-model inheritance is forbidden."
    }
    $frontmatter = [System.Collections.Generic.List[string]]::new()
    $frontmatter.Add("---")
    $frontmatter.Add("name: itl-routine")
    $frontmatter.Add("description: Runs deterministic ITL lifecycle helpers and reports their output without editing project code.")
    $frontmatter.Add("mode: subagent")
    $frontmatter.Add("model: $model")
    $frontmatter.Add("steps: 2")
    $frontmatter.Add("permission:")
    $frontmatter.Add('  "*": deny')
    $frontmatter.Add("  bash:")
    $frontmatter.Add('    "powershell -ExecutionPolicy Bypass -File .\\.agents\\skills\\1c-workflow\\scripts\\run-itl-command.ps1*": allow')
    $frontmatter.Add('    "powershell -ExecutionPolicy Bypass -File .\\.agents\\skills\\1c-workflow\\scripts\\agent-1c.ps1*": allow')
    $frontmatter.Add("---")
    $caveman = ([string](Get-EnvValue -Name "CAVEMAN" -Default "on")).Trim().ToLowerInvariant()
    $responseStyle = if ($caveman -eq "off") { "normal concise prose" } else { "CAVEMAN terse prose" }
    $body = @(
        "",
        "# ITL routine helper",
        "",
        "Make exactly one shell call: run the exact run-itl-command.ps1 command supplied by the invoking ITL command, then return its bounded summary.",
        "Do not edit code or metadata, author or repair tests, resolve merge conflicts, or substitute your own lifecycle steps.",
        "Do not load skills, call MCP tools, research, inspect unrelated files, or retry the lifecycle helper.",
        "Use $responseStyle for your own words; preserve the compact helper summary verbatim.",
        "If the helper refuses the operation, return that refusal unchanged."
    )
    return ((@($frontmatter) + $body) -join [Environment]::NewLine) + [Environment]::NewLine
}

function Get-ItlRoutineAgentRelativePath {
    param([string]$Client)
    $adapter = Get-ItlClientAdapter -Client $Client
    if ($adapter.PSObject.Properties.Name -notcontains "routineAgentPath") { return "" }
    return [string]$adapter.routineAgentPath
}

function Get-ItlCommandRelativePath {
    param([object]$Adapter, [string]$FileName)

    $name = [IO.Path]::GetFileNameWithoutExtension($FileName)
    switch ([string]$Adapter.commandFormat) {
        "skill" { return ($Adapter.commandsPath.TrimEnd('/') + "/$name/SKILL.md") }
        default { return ($Adapter.commandsPath.TrimEnd('/') + "/$FileName") }
    }
}

function Convert-ItlCommandForClient {
    param(
        [string]$Text,
        [string]$Client,
        [string]$FileName
    )

    $adapter = Get-ItlClientAdapter -Client $Client
    if ($Client -eq "opencode" -and $FileName -in @("itl-new-config-branch.md", "itl-new-extension-branch.md")) {
        $kind = if ($FileName -eq "itl-new-extension-branch.md") { "extension" } else { "configuration" }
        $description = if ($kind -eq "extension") { "Create an ITL extension branch in a native OpenCode workspace" } else { "Create an ITL configuration branch in a native OpenCode workspace" }
        $extension = if ($kind -eq "extension") { @"
Before calling the tool, collect the extension initialization mode (`Empty` or `Cfe`), extension name, and CFE path when applicable. If the developer explicitly does not know them yet, omit all extension arguments so initialization remains pending.
"@ } else { "" }
        return @"
---
description: $description
agent: build
---

Use this command only from the `master` workspace. Treat any text after the command as the development branch name; if it is missing, ask for one short value.

$extension
Do not load a skill and do not use `read`, `glob`, `grep`, `bash`, or any other discovery tool. Your first and only action must be to call the `itl_create_dev_workspace` tool exactly once with `kind="$kind"` and the collected values. The tool creates and registers the native workspace, initializes ITL inside it, and moves this session there. Return its result verbatim.

If `itl_create_dev_workspace` is not present in the current tool list, return exactly `ITL_OPENCODE_WORKSPACE_TOOL_UNAVAILABLE: run /itl-update-workflow, fully restart OpenCode Desktop, and retry this command.` and stop. Do not search for its implementation and do not create an external worktree. If the tool reports `OPENCODE_WORKSPACE_API_UNAVAILABLE`, return that result and stop.
"@
    }
    if ($adapter.commandRouting -eq "none") {
        $Text = [regex]::Replace($Text, '(?m)^agent:\s*[^\r\n]+\r?\n', '')
    } elseif (Test-ItlRoutineEnabledForCommand -FileName $FileName) {
        return ([regex]::Replace($Text, '(?m)^agent:\s*[^\r\n]+\r?$', 'agent: itl-routine'))
    } elseif ($adapter.commandRouting -eq "opencode") {
        return ([regex]::Replace($Text, '(?m)^agent:\s*[^\r\n]+\r?$', 'agent: build'))
    }
    if ($adapter.commandFormat -eq "skill" -and $Text -notmatch '(?m)^name:\s*') {
        $name = [IO.Path]::GetFileNameWithoutExtension($FileName)
        $Text = [regex]::Replace($Text, '^---\r?\n', "---`nname: $name`n", 1)
    }
    return $Text
}

function Get-ItlExpectedSurfaceFiles {
    param([string]$Client, [string]$SourceRoot)

    $files = [ordered]@{}
    $adapter = Get-ItlClientAdapter -Client $Client
    if ($adapter.commandsPath) {
        $templateRoot = Join-Path $SourceRoot ".agents\skills\1c-workflow\kilo-command-templates"
        if (-not (Test-Path -LiteralPath $templateRoot -PathType Container)) {
            throw "ITL command templates are missing: $templateRoot"
        }
        $surface = Get-ItlCommandSurface
        $sourceDirs = @((Join-Path $templateRoot "common"))
        if ($surface -in @("master", "dev")) { $sourceDirs += (Join-Path $templateRoot $surface) }
        foreach ($sourceDir in $sourceDirs) {
            foreach ($source in @(Get-ChildItem -LiteralPath $sourceDir -File -Filter "itl*.md.template" -ErrorAction Stop)) {
                $name = $source.Name.Substring(0, $source.Name.Length - ".template".Length)
                $relative = Get-ItlCommandRelativePath -Adapter $adapter -FileName $name
                $files[$relative] = Convert-ItlCommandForClient -Text (Read-Utf8Text -Path $source.FullName) -Client $Client -FileName $name
            }
        }
    }
    $routinePath = Get-ItlRoutineAgentRelativePath -Client $Client
    $routineNeeded = @($files.Keys | Where-Object { ([string]$files[$_]) -match '(?m)^agent:\s*itl-routine\s*$' }).Count -gt 0
    if ($routinePath -and $routineNeeded) { $files[$routinePath] = New-ItlRoutineAgentText -Client $Client }
    if ($adapter.workspacePluginPath) {
        $pluginTemplate = Join-Path $SourceRoot ".agents\skills\1c-workflow\opencode-plugin-templates\itl-workspace.js.template"
        if (-not (Test-Path -LiteralPath $pluginTemplate -PathType Leaf)) {
            throw "OpenCode workspace plugin template is missing: $pluginTemplate"
        }
        $files[[string]$adapter.workspacePluginPath] = Read-Utf8Text -Path $pluginTemplate
    }
    return $files
}

function Sync-ItlManagedSurfaceFiles {
    param([string]$Client, [object]$ExpectedFiles)

    $state = Read-ItlClientSurfaceState
    $clients = ConvertTo-Vibecoding1cMcpHashtable -Object $state["clients"]
    foreach ($oldClient in @($clients.Keys)) {
        if ($oldClient -eq $Client) { continue }
        $entry = ConvertTo-Vibecoding1cMcpHashtable -Object $clients[$oldClient]
        $managed = if ($entry.Contains("files")) { ConvertTo-Vibecoding1cMcpHashtable -Object $entry["files"] } else { [ordered]@{} }
        foreach ($relative in @($managed.Keys)) {
            $path = Join-Path $script:ProjectRoot $relative
            if ($relative -match '(?i)(^|/)itl-routine\.md$' -and (Test-Path -LiteralPath $path -PathType Leaf) -and (Get-ItlFileSha256 -Path $path) -ne [string]$managed[$relative]) {
                Write-Warning "Preserving user-modified inactive routine agent: $relative"
                continue
            }
            Assert-ItlManagedSurfaceFileUnmodified -RelativePath $relative -ExpectedHash ([string]$managed[$relative])
            if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force }
        }
        $clients.Remove($oldClient)
    }

    $activeEntry = if ($clients.Contains($Client)) { ConvertTo-Vibecoding1cMcpHashtable -Object $clients[$Client] } else { [ordered]@{} }
    $previous = if ($activeEntry.Contains("files")) { ConvertTo-Vibecoding1cMcpHashtable -Object $activeEntry["files"] } else { [ordered]@{} }
    foreach ($relative in @($previous.Keys)) {
        $path = Join-Path $script:ProjectRoot $relative
        if (-not $ExpectedFiles.Contains($relative) -and $relative -match '(?i)(^|/)itl-routine\.md$' -and (Test-Path -LiteralPath $path -PathType Leaf) -and (Get-ItlFileSha256 -Path $path) -ne [string]$previous[$relative]) {
            Write-Warning "Preserving user-modified inactive routine agent: $relative"
            continue
        }
        Assert-ItlManagedSurfaceFileUnmodified -RelativePath $relative -ExpectedHash ([string]$previous[$relative])
        if (-not $ExpectedFiles.Contains($relative)) {
            if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force }
        }
    }

    $newHashes = [ordered]@{}
    foreach ($relative in @($ExpectedFiles.Keys)) {
        $path = Join-Path $script:ProjectRoot $relative
        $expectedText = [string]$ExpectedFiles[$relative]
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $actualHash = Get-ItlFileSha256 -Path $path
            if (-not $previous.Contains($relative)) {
                $expectedBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($expectedText)
                $sha = [System.Security.Cryptography.SHA256]::Create()
                try { $expectedHash = ([BitConverter]::ToString($sha.ComputeHash($expectedBytes))).Replace("-", "").ToLowerInvariant() } finally { $sha.Dispose() }
                $acceptLegacy = $adapter.PSObject.Properties.Name -contains "legacyKiloCommands" -and $adapter.legacyKiloCommands -and (Test-ItlKnownLegacyKiloCommandHash -Hash $actualHash)
                if ($actualHash -ne $expectedHash -and -not $acceptLegacy) {
                    throw "ITL_SURFACE_COLLISION: '$relative' exists but is not a hash-matching managed or legacy ITL asset."
                }
            }
        }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
        Write-Utf8Text -Path $path -Value $expectedText
        $newHashes[$relative] = Get-ItlFileSha256 -Path $path
    }

    $adapter = Get-ItlClientAdapter -Client $Client
    if ($adapter.commandsPath) {
        $commandDir = Join-Path $script:ProjectRoot $adapter.commandsPath
        foreach ($file in @(Get-ChildItem -LiteralPath $commandDir -File -Filter "itl*.md" -ErrorAction SilentlyContinue)) {
            $relative = ($adapter.commandsPath.TrimEnd('/') + "/" + $file.Name)
            if ($ExpectedFiles.Contains($relative)) { continue }
            $hash = Get-ItlFileSha256 -Path $file.FullName
            $acceptLegacy = $adapter.PSObject.Properties.Name -contains "legacyKiloCommands" -and $adapter.legacyKiloCommands -and (Test-ItlKnownLegacyKiloCommandHash -Hash $hash)
            if ($acceptLegacy) {
                Remove-Item -LiteralPath $file.FullName -Force
                continue
            }
            throw "ITL_SURFACE_COLLISION: unexpected '$relative' is not a hash-matching managed or legacy ITL asset."
        }
    }
    # Keep this state byte-idempotent: it is part of migration/reconciliation evidence,
    # so an unchanged update must not differ only because it ran at another time.
    $clients[$Client] = [ordered]@{ files = $newHashes }
    $state["clients"] = $clients
    Write-ItlClientSurfaceState -State $state
}

function Get-ItlPackageIdentity {
    param([string]$Source)
    return ($Source -replace '@[^@/]+$', '')
}

function Assert-ItlClientRequirements {
    param([string]$Client)

    $adapter = Get-ItlClientAdapter -Client $Client
    if ($adapter.PSObject.Properties.Name -notcontains "requiredPackage" -or -not $adapter.requiredPackage) { return }
    $locked = Get-DependencyLockEntry -Name "piMcpExtension"
    if ([string]$locked.source -ne [string]$adapter.requiredPackage -or [string]$locked.integrity -ne [string]$adapter.requiredPackageIntegrity) {
        throw "PI_MCP_EXTENSION_LOCK_MISMATCH: workflow registry and dependency-lock.json disagree about the required Pi MCP extension."
    }
    $node = Get-Command node -ErrorAction SilentlyContinue
    if (-not $node) {
        throw "PI_NODE_REQUIRED: Pi MCP requires Node.js $($adapter.minimumNodeMajor)+ and project trust; no node executable was found."
    }
    $versionText = ((& $node.Source --version 2>&1 | Select-Object -First 1) -join "").Trim()
    $major = 0
    if ($versionText -notmatch '^v?(?<major>\d+)\.' -or -not [int]::TryParse($Matches['major'], [ref]$major) -or $major -lt [int]$adapter.minimumNodeMajor) {
        throw "PI_NODE_INCOMPATIBLE: Pi MCP requires Node.js $($adapter.minimumNodeMajor)+; detected '$versionText'."
    }
}

function Sync-ItlClientRequiredPackage {
    param([string]$Client, [switch]$Remove)

    $adapter = Get-ItlClientAdapter -Client $Client
    if ($adapter.PSObject.Properties.Name -notcontains "requiredPackage" -or -not $adapter.requiredPackage) { return }
    $path = Join-Path $script:ProjectRoot ([string]$adapter.requiredPackagePath)
    $key = [string]$adapter.requiredPackageKey
    $config = [ordered]@{}
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        try { $config = ConvertTo-Vibecoding1cMcpHashtable -Object (Read-Utf8Text -Path $path | ConvertFrom-Json) }
        catch { throw "Client package config is not valid JSON: $path. $($_.Exception.Message)" }
    }
    $identity = Get-ItlPackageIdentity -Source ([string]$adapter.requiredPackage)
    $items = $(if ($config.Contains($key)) { @($config[$key]) } else { @() })
    $kept = @($items | Where-Object {
        $candidate = if ($_ -is [string]) { [string]$_ } else { [string](Get-Vibecoding1cMcpObjectValue -Object $_ -Name "source" -Default "") }
        (Get-ItlPackageIdentity -Source $candidate) -ne $identity
    })
    if (-not $Remove) { $kept += [string]$adapter.requiredPackage }
    if ($kept.Count -gt 0) { $config[$key] = @($kept) } elseif ($config.Contains($key)) { $config.Remove($key) }
    if ($config.Count -eq 0) {
        if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force }
        return
    }
    Write-Vibecoding1cMcpJsonFile -Path $path -Value $config
}

function Assert-ItlClientRequiredPackageConfigured {
    param([string]$Client)

    $adapter = Get-ItlClientAdapter -Client $Client
    if ($adapter.PSObject.Properties.Name -notcontains "requiredPackage" -or -not $adapter.requiredPackage) { return }
    $path = Join-Path $script:ProjectRoot ([string]$adapter.requiredPackagePath)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "PI_MCP_EXTENSION_MISSING: '$($adapter.requiredPackage)' is not configured in $($adapter.requiredPackagePath). Run /itl-refresh, trust the project, and restart Pi."
    }
    try { $config = ConvertTo-Vibecoding1cMcpHashtable -Object (Read-Utf8Text -Path $path | ConvertFrom-Json) }
    catch { throw "PI_MCP_EXTENSION_CONFIG_INVALID: $path is not valid JSON. $($_.Exception.Message)" }
    $items = $(if ($config.Contains([string]$adapter.requiredPackageKey)) { @($config[[string]$adapter.requiredPackageKey]) } else { @() })
    if ([string]$adapter.requiredPackage -notin @($items | ForEach-Object { if ($_ -is [string]) { [string]$_ } else { [string](Get-Vibecoding1cMcpObjectValue -Object $_ -Name "source" -Default "") } })) {
        throw "PI_MCP_EXTENSION_INCOMPATIBLE: expected exact project package '$($adapter.requiredPackage)' in $($adapter.requiredPackagePath). Pi without the pinned MCP extension is unsupported."
    }
}

function Get-ItlOpenCodePluginRuntimeContract {
    param([string]$Client)

    $adapter = Get-ItlClientAdapter -Client $Client
    if (-not $adapter.workspacePluginPackageLockKey) { return $null }
    $locked = Get-DependencyLockEntry -Name ([string]$adapter.workspacePluginPackageLockKey)
    $version = [string](Get-ConfigValueFromObject -Object $locked -Path "version" -Default "")
    $source = [string](Get-ConfigValueFromObject -Object $locked -Path "source" -Default "")
    $integrity = [string](Get-ConfigValueFromObject -Object $locked -Path "integrity" -Default "")
    $expectedSource = "npm:$([string]$adapter.workspacePluginPackageName)@$version"
    if (-not $version -or $source -ne $expectedSource -or -not $integrity) {
        throw "OPENCODE_PLUGIN_RUNTIME_LOCK_MISMATCH: workflow registry and dependency-lock.json disagree about the OpenCode plugin runtime."
    }
    return [pscustomobject]@{
        client = $Client
        runtimeRoot = Join-Path $script:ProjectRoot ([string]$adapter.workspacePluginRuntimePath)
        packageName = [string]$adapter.workspacePluginPackageName
        version = $version
        source = $source
        integrity = $integrity
        minimumNodeMajor = [int](Get-ConfigValueFromObject -Object $locked -Path "minimumNodeMajor" -Default 22)
    }
}

function Sync-ItlOpenCodePluginRuntimeLockEntry {
    param([string]$Client)

    $adapter = Get-ItlClientAdapter -Client $Client
    if (-not $adapter.workspacePluginPackageLockKey) { return }
    $template = New-DefaultDependencyLockManifest
    $templateEntry = Get-ConfigValueFromObject -Object $template -Path "dependencies.$([string]$adapter.workspacePluginPackageLockKey)" -Default $null
    if ($null -eq $templateEntry) {
        throw "OPENCODE_PLUGIN_RUNTIME_TEMPLATE_LOCK_MISSING: templates/dependency-lock.json has no '$([string]$adapter.workspacePluginPackageLockKey)' entry."
    }
    $values = ConvertTo-Agent1cHashtable -Object $templateEntry
    Update-DependencyLockEntry -Name ([string]$adapter.workspacePluginPackageLockKey) -Values $values
}

function Get-ItlOpenCodePluginRuntimeStatus {
    param([string]$Client)

    $contract = Get-ItlOpenCodePluginRuntimeContract -Client $Client
    if ($null -eq $contract) {
        return [pscustomobject]@{ required = $false; ready = $true; detail = "not required for $Client" }
    }
    $packageManifestPath = Join-Path $contract.runtimeRoot "package.json"
    $installedManifestPath = Join-Path $contract.runtimeRoot "node_modules\@opencode-ai\plugin\package.json"
    $packageLockPath = Join-Path $contract.runtimeRoot "package-lock.json"
    if (-not (Test-Path -LiteralPath $packageManifestPath -PathType Leaf)) {
        return [pscustomobject]@{ required = $true; ready = $false; detail = "package manifest missing: $packageManifestPath" }
    }
    if (-not (Test-Path -LiteralPath $installedManifestPath -PathType Leaf)) {
        return [pscustomobject]@{ required = $true; ready = $false; detail = "installed package missing: $installedManifestPath" }
    }
    if (-not (Test-Path -LiteralPath $packageLockPath -PathType Leaf)) {
        return [pscustomobject]@{ required = $true; ready = $false; detail = "package lock missing: $packageLockPath" }
    }
    try {
        $packageManifest = Read-Utf8Text -Path $packageManifestPath | ConvertFrom-Json
        $installedManifest = Read-Utf8Text -Path $installedManifestPath | ConvertFrom-Json
        # Windows PowerShell 5 ConvertFrom-Json rejects npm lockfile v3's required packages[""] root entry.
        $packageLockText = (Read-Utf8Text -Path $packageLockPath).Replace('"":', '"_itl_root":')
        $packageLock = $packageLockText | ConvertFrom-Json
    } catch {
        return [pscustomobject]@{ required = $true; ready = $false; detail = "runtime package metadata is invalid JSON: $($_.Exception.Message)" }
    }
    $declared = [string](Get-ConfigValueFromObject -Object $packageManifest -Path "dependencies.$($contract.packageName)" -Default "")
    $installed = [string](Get-ConfigValueFromObject -Object $installedManifest -Path "version" -Default "")
    $lockedPackage = Get-ConfigValueFromObject -Object $packageLock -Path "packages.node_modules/@opencode-ai/plugin" -Default $null
    $lockVersion = [string](Get-ConfigValueFromObject -Object $lockedPackage -Path "version" -Default "")
    $lockIntegrity = [string](Get-ConfigValueFromObject -Object $lockedPackage -Path "integrity" -Default "")
    $ready = $declared -eq $contract.version -and $installed -eq $contract.version -and
        $lockVersion -eq $contract.version -and $lockIntegrity -eq $contract.integrity
    return [pscustomobject]@{
        required = $true
        ready = $ready
        detail = "expected=$($contract.version); declared=$(if ($declared) { $declared } else { '<missing>' }); installed=$(if ($installed) { $installed } else { '<missing>' }); lock=$(if ($lockVersion) { $lockVersion } else { '<missing>' }); integrity=$(if ($lockIntegrity -eq $contract.integrity) { 'matched' } else { 'mismatch' })"
    }
}

function Set-ItlOpenCodePluginPackageManifest {
    param([object]$Contract)

    New-Item -ItemType Directory -Force -Path $Contract.runtimeRoot | Out-Null
    $gitIgnorePath = Join-Path $Contract.runtimeRoot ".gitignore"
    $ignoreLines = @(if (Test-Path -LiteralPath $gitIgnorePath -PathType Leaf) { Read-Utf8Lines -Path $gitIgnorePath })
    foreach ($entry in @("node_modules", "package.json", "package-lock.json", "bun.lock", ".gitignore")) {
        if ($entry -notin $ignoreLines) { $ignoreLines += $entry }
    }
    $ignoreText = [string]::Join([Environment]::NewLine, [string[]]$ignoreLines) + [Environment]::NewLine
    Write-Utf8Text -Path $gitIgnorePath -Value $ignoreText

    $packageManifestPath = Join-Path $Contract.runtimeRoot "package.json"
    $manifest = [ordered]@{ private = $true; dependencies = [ordered]@{} }
    if (Test-Path -LiteralPath $packageManifestPath -PathType Leaf) {
        try { $manifest = ConvertTo-Vibecoding1cMcpHashtable -Object (Read-Utf8Text -Path $packageManifestPath | ConvertFrom-Json) }
        catch { throw "OPENCODE_PLUGIN_RUNTIME_MANIFEST_INVALID: $packageManifestPath is not valid JSON. $($_.Exception.Message)" }
        if (-not $manifest.Contains("dependencies") -or $null -eq $manifest["dependencies"]) { $manifest["dependencies"] = [ordered]@{} }
        else { $manifest["dependencies"] = ConvertTo-Vibecoding1cMcpHashtable -Object $manifest["dependencies"] }
        $manifest["private"] = $true
    }
    $manifest["dependencies"][$Contract.packageName] = $Contract.version
    Write-Vibecoding1cMcpJsonFile -Path $packageManifestPath -Value $manifest
}

function Sync-ItlOpenCodePluginRuntime {
    param([string]$Client, [string]$NpmCommand = "")

    Sync-ItlOpenCodePluginRuntimeLockEntry -Client $Client
    $contract = Get-ItlOpenCodePluginRuntimeContract -Client $Client
    if ($null -eq $contract) { return }
    $status = Get-ItlOpenCodePluginRuntimeStatus -Client $Client
    if ($status.ready) { return }

    Set-ItlOpenCodePluginPackageManifest -Contract $contract
    $node = Get-Command node -ErrorAction SilentlyContinue
    $npm = if ($NpmCommand) { Get-Command $NpmCommand -ErrorAction SilentlyContinue } else { Get-Command npm.cmd -ErrorAction SilentlyContinue }
    if (-not $npm -and -not $NpmCommand) { $npm = Get-Command npm -ErrorAction SilentlyContinue }
    if (-not $node -or -not $npm) {
        throw "OPENCODE_PLUGIN_RUNTIME_NPM_REQUIRED: OpenCode Desktop needs Node.js $($contract.minimumNodeMajor)+ with npm so ITL can prepare its project-local plugin runtime."
    }
    $versionText = ((& $node.Source --version 2>&1 | Select-Object -First 1) -join "").Trim()
    $major = 0
    if ($versionText -notmatch '^v?(?<major>\d+)\.' -or -not [int]::TryParse($Matches['major'], [ref]$major) -or $major -lt $contract.minimumNodeMajor) {
        throw "OPENCODE_PLUGIN_RUNTIME_NODE_INCOMPATIBLE: OpenCode Desktop needs Node.js $($contract.minimumNodeMajor)+ with npm; detected '$versionText'."
    }
    $output = @(& $npm.Source "install" "--prefix" $contract.runtimeRoot "--ignore-scripts" "--no-audit" "--no-fund" "--package-lock=true" 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "OPENCODE_PLUGIN_RUNTIME_INSTALL_FAILED: npm could not install $($contract.source). $((@($output | Select-Object -Last 8) -join ' ').Trim())"
    }
    $status = Get-ItlOpenCodePluginRuntimeStatus -Client $Client
    if (-not $status.ready) {
        throw "OPENCODE_PLUGIN_RUNTIME_VERIFY_FAILED: $($status.detail)"
    }
    Write-Host "Prepared OpenCode plugin runtime: $($contract.source)."
    Write-Host "Restart OpenCode so it registers the ITL native workspace tools."
}

function Sync-ItlClientSurface {
    param([string]$SourceRoot = $script:ProjectRoot)

    if ($null -eq (Get-AiRules1cProjectManifest)) {
        Write-Host "Skipping ITL client surface generation because ai_rules_1c is not installed."
        return
    }
    $client = Get-ItlActiveClient
    Assert-ItlClientConfigWritable -Client $client
    Assert-ItlClientRequirements -Client $client
    $adapter = Get-ItlClientAdapter -Client $client
    $expectedFiles = Get-ItlExpectedSurfaceFiles -Client $client -SourceRoot $SourceRoot
    Sync-ItlManagedSurfaceFiles -Client $client -ExpectedFiles $expectedFiles
    if ((Get-FullPathNormalized $SourceRoot) -eq (Get-FullPathNormalized $script:ProjectRoot)) {
        Sync-ItlOpenCodePluginRuntime -Client $client
    }
    if ($adapter.PSObject.Properties.Name -contains "disableSnapshots" -and $adapter.disableSnapshots) {
        Set-KiloSnapshotsDisabled
    }
    Sync-ItlClientRequiredPackage -Client $client
    Write-ItlOnDemandMcpClientConfig -Client $client | Out-Null
    $surface = Get-ItlCommandSurface
    if ($adapter.commandFormat -eq "none") {
        Write-Host "$client uses project-local skills and natural requests; no project slash prompts were written."
        return
    }
    if ($adapter.PSObject.Properties.Name -contains "untrackGeneratedCommands" -and $adapter.untrackGeneratedCommands) {
        Untrack-GeneratedKiloItlCommands
    }
    Write-Host "Generated $client ITL command surface: $surface ($($adapter.commandsPath); format=$($adapter.commandFormat))"
}

function Sync-ItlClientUserEnvironment {
    param([string]$Client)

    $adapter = Get-ItlClientAdapter -Client $Client
    if ($adapter.PSObject.Properties.Name -notcontains "requiredUserEnvironment" -or $null -eq $adapter.requiredUserEnvironment) {
        return
    }

    $changed = @()
    foreach ($entry in $adapter.requiredUserEnvironment.GetEnumerator()) {
        $name = [string]$entry.Key
        $expected = [string]$entry.Value
        $current = [Environment]::GetEnvironmentVariable($name, "User")
        $matches = [string]::Equals([string]$current, $expected, [StringComparison]::OrdinalIgnoreCase)
        if ($expected -eq "true" -and $current -eq "1") { $matches = $true }
        if (-not $matches) {
            try {
                [Environment]::SetEnvironmentVariable($name, $expected, "User")
            } catch {
                throw "ITL_CLIENT_ENVIRONMENT_CONFIG_FAILED: unable to set user environment variable '$name' for '$Client'. $($_.Exception.Message)"
            }
            $changed += $name
            $current = $expected
        }
        [Environment]::SetEnvironmentVariable($name, $current, "Process")
    }

    if ($changed.Count -gt 0) {
        Write-Host "Configured required $Client user environment: $($changed -join ', ')."
        Write-Host $adapter.reload
    }
}

function Switch-ItlClient {
    param([string]$Client)

    Assert-MasterWorktreeContext -Operation "itl-switch-client"
    Assert-WorkflowTrackedGitClean
    $normalized = @(ConvertTo-AgentToolList -Value $Client)
    if ($normalized.Count -ne 1 -or $normalized[0] -notin (Get-SupportedAgentTargets)) {
        throw "itl-switch-client requires exactly one client: $((Get-SupportedAgentTargets) -join ', ')."
    }
    $newClient = [string]$normalized[0]
    Assert-ItlClientConfigWritable -Client $newClient
    if (Test-AiRulesManifestHasUserChanges) {
        throw "itl-switch-client is blocked because ai_rules_1c manifest contains userModified files."
    }
    $oldClient = Get-ItlActiveClient
    if ($oldClient -eq $newClient) {
        Sync-ItlClientSurface
        Write-Host "ITL client is already '$newClient'."
        return
    }

    $snapshot = New-AiRulesMigrationSnapshot
    try {
        Write-ItlClientMcpEndpoints -Endpoints @() -Owner "ondemand-facade" -Client $oldClient | Out-Null
        Sync-ItlClientRequiredPackage -Client $oldClient -Remove
        Set-ProjectAiRulesClient -Client $newClient
        Set-DotEnvValues -Values @{
            SUBAGENT_MODEL_CODING = ""
            SUBAGENT_MODEL_ANALYSIS = ""
            SUBAGENT_MODEL_LIGHT = ""
        }
        Import-DotEnv -Path (Join-Path $script:ProjectRoot ".dev.env") -Overwrite
        Read-ProjectConfig
        Update-AiRules1c
        Sync-ItlClientSurface
        Write-Host "ITL client switched: $oldClient -> $newClient."
        Write-Host "Other worktrees were not changed; run /itl-refresh in each development worktree."
        Write-Host "RTK integration was preserved and must be reconciled explicitly if the client changed."
        Write-Host ((Get-ItlClientAdapter -Client $newClient).reload)
    } catch {
        $failure = $_.Exception.Message
        Restore-AiRulesMigrationSnapshot -Snapshot $snapshot
        throw "itl-switch-client failed and the project snapshot was restored from $($snapshot.root): $failure"
    }
}

function Get-ItlRtkStatus {
    $command = Get-Command rtk -ErrorAction SilentlyContinue
    if (-not $command) { return [pscustomobject]@{ status = "SKIP"; detail = "not installed; /economymode rtk can configure it after explicit confirmation" } }
    try {
        $version = ((& rtk --version 2>&1 | Select-Object -First 1) -join "").Trim()
        $integration = ((& rtk init --show 2>&1 | Select-Object -First 3) -join " ").Trim()
        $gain = ((& rtk gain 2>&1 | Select-Object -First 2) -join " ").Trim()
        return [pscustomobject]@{ status = "OK"; detail = "$version; integration=$integration; gain=$gain; shell only, built-in reads/MCP bypass RTK" }
    } catch {
        return [pscustomobject]@{ status = "WARN"; detail = "installed but status could not be read: $($_.Exception.Message)" }
    }
}

function Show-ItlDoctor {
    $checks = [System.Collections.Generic.List[object]]::new()
    $client = ""
    $adapter = $null
    $manifest = $null
    try {
        $client = Get-ItlActiveClient
        $adapter = Get-ItlClientAdapter -Client $client
        Assert-ItlClientConfigWritable -Client $client
        Assert-ItlClientRequirements -Client $client
        Assert-ItlClientRequiredPackageConfigured -Client $client
        $checks.Add([pscustomobject]@{ status = "OK"; name = "active-client"; detail = "$client; rules=$($adapter.rulesPath); agents=$($adapter.agentsPath); commands=$(if ($adapter.commandsPath) { $adapter.commandsPath } else { '<skills/natural requests>' }); skills=$($adapter.skillsPath); mcp=$($adapter.mcpPath)" })
    } catch {
        $checks.Add([pscustomobject]@{ status = "FAIL"; name = "active-client"; detail = $_.Exception.Message })
    }
    try {
        $entry = Get-DependencyLockEntry -Name "aiRules1c"
        $manifest = Get-AiRules1cProjectManifest
        $protocol = [string](Get-ConfigValueFromObject -Object $manifest -Path "protocol" -Default "")
        $compatibility = [string](Get-ConfigValueFromObject -Object $entry -Path "compatibilityStatus" -Default "")
        $revision = [int](Get-ConfigValueFromObject -Object $entry -Path "downstreamRevision" -Default 0)
        $repo = [string](Get-ConfigValueFromObject -Object $entry -Path "repo" -Default "")
        $ref = [string](Get-ConfigValueFromObject -Object $entry -Path "ref" -Default "")
        $commit = [string](Get-ConfigValueFromObject -Object $entry -Path "commit" -Default "")
        $upstreamCommit = [string](Get-ConfigValueFromObject -Object $entry -Path "upstreamCommit" -Default "")
        $configuredRepo = [string](Get-ConfigValue -Path "aiRules.repo" -Default "")
        $configuredRef = [string](Get-ConfigValue -Path "aiRules.ref" -Default "")
        $provenanceOk = $manifest -and $protocol -eq "1.1" -and $compatibility -eq "passed" -and $revision -gt 0 -and
            $repo -eq $configuredRepo -and $ref -eq $configuredRef -and
            $commit -match '^[0-9a-fA-F]{40}$' -and $upstreamCommit -match '^[0-9a-fA-F]{40}$'
        $detail = "$repo#$ref@$commit; upstream=$upstreamCommit; revision=$revision; protocol=$protocol; compatibility=$compatibility"
        $checks.Add([pscustomobject]@{ status = $(if ($provenanceOk) { "OK" } else { "FAIL" }); name = "ai-rules-provenance"; detail = $detail })
    } catch {
        $checks.Add([pscustomobject]@{ status = "FAIL"; name = "ai-rules-provenance"; detail = $_.Exception.Message })
    }
    if ($manifest -and $manifest.files) {
        $missing = @(); $drift = @(); $modified = @(); $workflowOwned = @()
        foreach ($property in @($manifest.files.PSObject.Properties)) {
            $relative = [string]$property.Name
            $entry = $property.Value
            if (Test-AiRulesManifestPathOwnedByWorkflow -Path $relative) { $workflowOwned += $relative; continue }
            $path = Join-Path $script:ProjectRoot $relative
            if ([bool](Get-ConfigValueFromObject -Object $entry -Path "userModified" -Default $false)) { $modified += $relative; continue }
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $missing += $relative; continue }
            $expected = [string](Get-ConfigValueFromObject -Object $entry -Path "installedHash" -Default "")
            if ($expected -and (Get-ItlFileSha256 -Path $path) -ne $expected.ToLowerInvariant()) { $drift += $relative }
        }
        $integrityStatus = if ($missing.Count -gt 0 -or $drift.Count -gt 0) { "FAIL" } elseif ($modified.Count -gt 0) { "WARN" } else { "OK" }
        $checks.Add([pscustomobject]@{ status = $integrityStatus; name = "managed-integrity"; detail = "files=$(@($manifest.files.PSObject.Properties).Count); missing=$($missing.Count); drift=$($drift.Count); userModified=$($modified.Count); workflowOwned=$($workflowOwned.Count)" })
    } else {
        $checks.Add([pscustomobject]@{ status = "FAIL"; name = "managed-integrity"; detail = "manifest file inventory is missing" })
    }
    $itlSkills = @("1c-workflow", "1c-workflow-fast", "product-docs", "itl-roctup-1c-data", "itl-vanessa-ui-mcp")
    $missingSkills = @($itlSkills | Where-Object { -not (Test-Path -LiteralPath (Join-Path $script:ProjectRoot ".agents\skills\$_\SKILL.md") -PathType Leaf) })
    $checks.Add([pscustomobject]@{ status = $(if ($missingSkills.Count -eq 0) { "OK" } else { "FAIL" }); name = "itl-skills"; detail = $(if ($missingSkills.Count -eq 0) { "all five installed" } else { "missing: $($missingSkills -join ', ')" }) })
    $openSpec = Get-AiRules1cOpenSpecStatus
    $openSpecDetail = if ($openSpec.isAvailable) {
        "mode=$($openSpec.mode); cli=$(if ($openSpec.cliAvailable) { $openSpec.cliPath } else { '<not-detected>' })$(if ($openSpec.reason) { "; $($openSpec.reason)" } else { '' })"
    } else {
        "mode=unavailable; $($openSpec.reason)"
    }
    $checks.Add([pscustomobject]@{ status = $(if ($openSpec.isAvailable) { "OK" } else { "FAIL" }); name = "openspec"; detail = $openSpecDetail })
    $devEnvPath = Join-Path $script:ProjectRoot ".dev.env"
    $checks.Add([pscustomobject]@{ status = $(if (Test-Path -LiteralPath $devEnvPath -PathType Leaf) { "OK" } else { "FAIL" }); name = "dev-env"; detail = $(if (Test-Path -LiteralPath $devEnvPath -PathType Leaf) { "present; values inspected without mutation" } else { "missing" }) })
    foreach ($component in @("vanessa", "event-log")) {
        $mode = Get-ItlVerificationMode -Component $component
        $checks.Add([pscustomobject]@{ status = $(if ($mode.valid) { "OK" } else { "WARN" }); name = $mode.key; detail = "raw=$(if ($mode.raw) { $mode.raw } else { '<missing>' }); effective=$($mode.effective)$(if (-not $mode.valid) { '; safe default auto' } else { '' })" })
    }
    if ($client -and $adapter) {
        $mcpPath = Join-Path $script:ProjectRoot $adapter.mcpPath
        $managedMcp = Read-ItlManagedMcpState
        $owners = ConvertTo-Vibecoding1cMcpHashtable -Object $managedMcp["owners"]
        $ownedCount = 0
        foreach ($ownerKey in @($owners.Keys | Where-Object { $_ -like "$client/*" })) { $ownedCount += @($owners[$ownerKey]).Count }
        if ($ownedCount -gt 0 -and -not (Test-Path -LiteralPath $mcpPath -PathType Leaf)) {
            $checks.Add([pscustomobject]@{ status = "FAIL"; name = "mcp"; detail = "managed endpoints exist but active config is missing: $($adapter.mcpPath)" })
        } else {
            $checks.Add([pscustomobject]@{ status = $(if ($ownedCount -gt 0) { "OK" } else { "SKIP" }); name = "mcp"; detail = "active=$client; managedEndpoints=$ownedCount; config=$($adapter.mcpPath)" })
        }
        try {
            $pluginRuntime = Get-ItlOpenCodePluginRuntimeStatus -Client $client
            $checks.Add([pscustomobject]@{
                status = $(if (-not $pluginRuntime.required) { "SKIP" } elseif ($pluginRuntime.ready) { "OK" } else { "FAIL" })
                name = "opencode-plugin-runtime"
                detail = $pluginRuntime.detail
            })
        } catch {
            $checks.Add([pscustomobject]@{ status = "FAIL"; name = "opencode-plugin-runtime"; detail = $_.Exception.Message })
        }
    }
    try {
        $facadeLock = Get-DependencyLockEntry -Name "itlOndemandMcp"
        $facadeVersion = [string](Get-ConfigValueFromObject -Object $facadeLock -Path "version" -Default "")
        $facadePath = Get-ItlOnDemandMcpExecutablePath -AllowMissing
        $instances = @(Get-ItlOnDemandRuntimeInstances)
        $stale = @($instances | Where-Object { -not (Test-ItlOnDemandOwnedProcess -RuntimeState $_) }).Count
        $facadeReady = Test-Path -LiteralPath $facadePath -PathType Leaf
        $checks.Add([pscustomobject]@{
            status = $(if (-not $facadeVersion) { "SKIP" } elseif ($facadeReady -and $stale -eq 0) { "OK" } elseif ($facadeReady) { "WARN" } else { "FAIL" })
            name = "ondemand-mcp"
            detail = "version=$(if ($facadeVersion) { $facadeVersion } else { '<legacy project>' }); facade=$facadePath; instances=$($instances.Count); stale=$stale"
        })
    } catch {
        $checks.Add([pscustomobject]@{ status = "FAIL"; name = "ondemand-mcp"; detail = $_.Exception.Message })
    }
    $surface = Get-ItlCommandSurface
    if ($surface -eq "dev") {
        try {
            $state = Read-DevBranchState -Name ""
            Assert-DevelopmentBranchWorktreeContext -State $state -Operation "doctor"
            $branchBase = [string](Get-StateValue -State $state -Name "devBranchInfoBasePath" -Default "")
            if (-not $branchBase) { throw "branch infobase path is missing" }
            $checks.Add([pscustomobject]@{ status = "OK"; name = "branch-infobase"; detail = $branchBase })
        } catch {
            $checks.Add([pscustomobject]@{ status = "FAIL"; name = "branch-infobase"; detail = $_.Exception.Message })
        }
    } else {
        $checks.Add([pscustomobject]@{ status = "SKIP"; name = "branch-infobase"; detail = "branch-only check on $surface" })
    }
    $rtk = Get-ItlRtkStatus
    $checks.Add([pscustomobject]@{ status = $rtk.status; name = "rtk"; detail = $rtk.detail })
    foreach ($check in $checks) { Write-Host ("[{0}] {1}: {2}" -f $check.status, $check.name, $check.detail) }
    Write-Host "Doctor is read-only. Repair with pinned update-ai-rules, /itl-update-workflow, or /itl-refresh; on-demand backend control is private."
    if (@($checks | Where-Object { $_.status -eq "FAIL" }).Count -gt 0) { throw "ITL doctor found failed checks." }
}

function Sync-KiloItlCommandSurface {
    param([string]$SourceRoot = $script:ProjectRoot)
    Sync-ItlClientSurface -SourceRoot $SourceRoot
}
