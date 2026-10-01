function Get-ItlClientAdapterRegistry {
    $registry = [ordered]@{
        codex = [ordered]@{
            id = "codex"
            rulesPath = ".codex/rules"
            agentsPath = ".codex/agents"
            commandsPath = ".agents/skills"
            skillsPath = ".agents/skills"
            mcpPath = ".codex/config.toml"
            commandFormat = "skill"
            commandRouting = "none"
            nativeAgents = $true
            mcpFormat = "toml"
            mcpContainer = "mcp_servers"
            mcpStdioFormat = "standard"
            mcpRemoteFormat = "url"
            trackedMcpConfig = $false
            reload = "Start a new Codex task so project rules and skills are reread."
            reloadUserReport = "Откройте новую задачу Codex, чтобы заново прочитать правила и skills проекта."
            mcpReload = "Restart the Codex app, then start a new task so project MCP configuration is loaded."
            mcpReloadUserReport = "Перечитайте MCP-подключения Codex из .codex/config.toml штатным механизмом клиента в текущей задаче; при отсутствии такой возможности сообщите ограничение клиента и продолжайте независимую работу. См. .agents/skills/1c-workflow/references/mcp.md."
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
            reloadUserReport = "Выполните /reload или перезапустите Kilo Code."
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
            reloadUserReport = "Перезапустите Claude Code."
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
            mcpEnablementObservation = "private-client-state"
            mcpEnablementUserInstruction = "Откройте в текущем проекте Cursor меню + → MCP Servers и убедитесь, что включены все серверы ITL. ITL проверяет .cursor/mcp.json, но Cursor не предоставляет workflow доступ к состоянию этих переключателей. После включения откройте новый Agent-чат."
            reload = "Reload the Cursor window."
            reloadUserReport = "Перезагрузите окно Cursor."
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
            workspacePluginSdkPackageName = "@opencode-ai/sdk"
            workspacePluginRuntimePath = ".opencode"
            requiredUserEnvironment = [ordered]@{
                OPENCODE_EXPERIMENTAL_WORKSPACES = "true"
            }
            reload = "Restart OpenCode."
            reloadUserReport = "Перезапустите OpenCode."
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
            reloadUserReport = "Перезапустите Kimi Code; вызывайте ITL-команды как /skill:itl-*."
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
            reloadUserReport = "Перезапустите Qwen Code."
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
            reloadUserReport = "Перезапустите Command Code."
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
            reloadUserReport = "Перезапустите Cline; вызывайте ITL-команды как skills /itl-*."
        }
        zcode = [ordered]@{
            id = "zcode"
            rulesPath = ".zcode/rules-1c"
            agentsPath = ".zcode/agents"
            commandsPath = ".zcode/commands"
            skillsPath = ".zcode/skills"
            mcpPath = ".zcode/config.json"
            commandFormat = "markdown"
            commandRouting = "none"
            nativeAgents = $true
            mcpFormat = "json"
            mcpContainer = "mcp.servers"
            mcpStdioFormat = "zcode"
            mcpRemoteFormat = "http"
            trackedMcpConfig = $false
            reload = "Restart ZCode or open a new agent session to load project commands and MCP."
            reloadUserReport = "Перезапустите ZCode или откройте новую агентскую сессию для загрузки команд и MCP проекта."
        }
        mimocode = [ordered]@{
            id = "mimocode"
            rulesPath = ".mimocode/rules-1c"
            agentsPath = ".mimocode/agents"
            commandsPath = ".mimocode/commands"
            skillsPath = ".mimocode/skills"
            mcpPath = ".mimocode/mimocode.json"
            commandFormat = "markdown"
            commandRouting = "none"
            nativeAgents = $true
            mcpFormat = "json"
            mcpContainer = "mcp"
            mcpStdioFormat = "local-array"
            mcpRemoteFormat = "remote"
            trackedMcpConfig = $false
            configCollisionCheck = "mimocode-jsonc"
            reload = "Restart MiMo Code to load project configuration and skills."
            reloadUserReport = "Перезапустите MiMo Code для загрузки настроек и skills проекта."
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
            reloadUserReport = "Подтвердите доверие к проекту и перезапустите Pi, чтобы загрузить настройки .pi, prompts, skills и MCP-расширение."
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
        if (-not $entry.Contains("workspacePluginSdkPackageName")) { $entry["workspacePluginSdkPackageName"] = "" }
        if (-not $entry.Contains("workspacePluginRuntimePath")) { $entry["workspacePluginRuntimePath"] = "" }
    }
    return $registry
}

function Get-ItlClientAdapter {
    param([string]$Client = "")

    if ([string]::IsNullOrWhiteSpace($Client)) {
        $Client = Get-ItlActiveClient
    }
    $Client = $Client.Trim().ToLowerInvariant()
    $registry = Get-ItlClientAdapterRegistry
    if (-not $registry.Contains($Client)) {
        throw "Unsupported ITL client '$Client'. Supported clients: $((Get-SupportedAgentTargets) -join ', ')."
    }
    return [pscustomobject]$registry[$Client]
}

function Get-ItlClientCapabilityReport {
    param([Parameter(Mandatory = $true)][string]$Client)

    $adapter = Get-ItlClientAdapter -Client $Client
    $variant = 'runtime variant and minimum build unverified'
    $discovery = "project rules=$($adapter.rulesPath); skills=$($adapter.skillsPath); commands=$($adapter.commandsPath)"
    $mcp = "project $($adapter.mcpPath) -> $($adapter.mcpContainer); actual discovery and tools unverified"
    switch ($Client) {
        'cline' {
            $variant = 'CLI with project MCP and editor/older global-only variants must be qualified separately'
            $mcp = 'CLI project .cline/mcp.json; editor/older runtime project discovery unverified; no user-global fallback'
        }
        'zcode' {
            $variant = 'ZCode workspace runtime; exact build and loaded surfaces unverified'
            $mcp = 'project .zcode/config.json -> mcp.servers; connection and tool callability unverified'
        }
        'mimocode' {
            $variant = 'MiMo Code project runtime; exact build and JSON/JSONC precedence unverified'
            $mcp = 'project .mimocode/mimocode.json -> mcp; JSONC collision blocks writes; connection unverified'
        }
        'kilocode' { $variant = 'Kilo CLI and editor variants require separate loaded-surface qualification' }
        'opencode' { $variant = 'OpenCode workspace plugin requires separate runtime qualification' }
        'pi' { $variant = 'Pi requires pinned MCP extension, Node 22+, project trust and runtime qualification' }
    }
    return [pscustomobject]@{
        client = $Client
        runtimeVariant = $variant
        discovery = $discovery
        mcp = $mcp
        roles = $(if ($adapter.nativeAgents) { "project $($adapter.agentsPath); native restrictions not executed" } else { "reference-only at $($adapter.agentsPath) unless this runtime proves native agents" })
        model = 'per-client settings rendered; actual provider/model selection unverified'
        openSpec = $(if ($Client -in @('codex','kilocode','claude-code','cursor','opencode')) { 'native bundle rendered; invocation unverified' } else { 'intentional natural route; CLI/store execution unverified' })
        nativeCommand = "format=$($adapter.commandFormat); client discovery and invocation unverified"
        evidence = 'static adapter and project-config inspection only'
    }
}

function Get-ItlActiveClient {
    param([string]$Client = "")

    $configured = @(Get-AgentTargets)
    if ($configured.Count -eq 0) {
        throw 'ITL_CLIENT_NOT_ATTACHED: this project has no attached AI client. Use itl-switch-client -Mode attach -Client <client> from master.'
    }
    $manifest = Get-AiRules1cProjectManifest
    if ($null -ne $manifest) {
        $installed = @(Get-AiRules1cManifestToolNames -Manifest $manifest)
        $difference = @(Compare-Object -ReferenceObject @($configured | Sort-Object) -DifferenceObject @($installed | Sort-Object))
        if ($difference.Count -gt 0) {
            throw "Configured and installed ai_rules_1c clients disagree. Configured: $($configured -join ', '). Installed: $($installed -join ', '). Run pinned update-ai-rules from master."
        }
    }
    if ([string]::IsNullOrWhiteSpace($Client)) { $Client = [string]$AgentTarget }
    if ([string]::IsNullOrWhiteSpace($Client)) {
        $executionEnvironment = Get-InitAgentExecutionEnvironment
        $detected = Resolve-InitAgentTargetFromExecutionContext -Environment $executionEnvironment -ProcessChain @()
        if (-not $detected) {
            $detected = Resolve-InitAgentTargetFromExecutionContext `
                -Environment $executionEnvironment `
                -ProcessChain @(Get-InitAgentExecutionProcessChain)
        }
        # A verified executor outside the desired set must receive an attach
        # continuation even when there is only one installed client. Falling
        # back to that sole client would target the wrong client surface.
        if ($detected) { $Client = $detected }
    }
    if ([string]::IsNullOrWhiteSpace($Client) -and $configured.Count -eq 1) {
        $Client = [string]$configured[0]
    }
    if ([string]::IsNullOrWhiteSpace($Client)) {
        throw "ITL_CLIENT_AMBIGUOUS: identify the executing client with -AgentTarget. Configured: $($configured -join ', ')."
    }
    $Client = $Client.Trim().ToLowerInvariant()
    if ($Client -notin $configured) {
        throw "ITL_CLIENT_NOT_ATTACHED: '$Client' is not in aiRules.tools. Configured: $($configured -join ', '). Attach it from the project master first."
    }
    return $Client
}

function Get-ItlClientMcpContainer {
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $node = $Config
    foreach ($part in $Path.Split('.')) {
        if (-not $node.Contains($part)) { return [ordered]@{} }
        if ($node[$part] -isnot [System.Collections.IDictionary] -and $node[$part] -isnot [pscustomobject]) {
            throw "CLIENT_MCP_CONTAINER_INVALID: '$Path' contains a non-object '$part'; preserve the config and reconcile it before retrying."
        }
        $node = ConvertTo-Vibecoding1cMcpHashtable -Object $node[$part]
    }
    return $node
}

function Set-ItlClientMcpContainer {
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Container
    )
    $parts = $Path.Split('.')
    $node = $Config
    for ($index = 0; $index -lt $parts.Length - 1; $index++) {
        $part = $parts[$index]
        if ($node.Contains($part)) {
            if ($node[$part] -isnot [System.Collections.IDictionary] -and $node[$part] -isnot [pscustomobject]) {
                throw "CLIENT_MCP_CONTAINER_INVALID: '$Path' contains a non-object '$part'; preserve the config and reconcile it before retrying."
            }
            $child = ConvertTo-Vibecoding1cMcpHashtable -Object $node[$part]
        } else {
            $child = [ordered]@{}
        }
        $node[$part] = $child
        $node = $child
    }
    $node[$parts[-1]] = $Container
}

function Get-KiloFastSkillProvenance {
    $relativePath = ".agents\skills\1c-workflow-fast\SKILL.md"
    $path = Join-Path $script:ProjectRoot $relativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "ITL_KILO_SKILL_MISSING: expected installed skill was not found: $relativePath"
    }
    $text = Read-Utf8Text -Path $path
    $match = [regex]::Match($text, '(?m)^<!-- ITL_KILO_SKILL_CONTRACT:\s*(?<contract>[A-Za-z0-9._-]+)\s*-->\r?$')
    if (-not $match.Success) {
        throw "ITL_KILO_SKILL_CONTRACT_MISSING: $relativePath has no ITL_KILO_SKILL_CONTRACT marker."
    }
    return [pscustomobject][ordered]@{
        path = $relativePath.Replace("\", "/")
        contract = [string]$match.Groups["contract"].Value
        sha256 = (Get-ItlFileSha256 -Path $path).ToLowerInvariant()
    }
}

function Write-KiloClientSkillProvenanceStatusLines {
    try {
        if ((Get-ItlActiveClient) -ne "kilocode") { return }
        $provenance = Get-KiloFastSkillProvenance
        Write-Host "Kilo expected skill: $($provenance.path); contract=$($provenance.contract); sha256=$($provenance.sha256)"
        Write-Host "Kilo loaded skill: not observable through an ITL API. If Kilo behavior disagrees with this provenance, run /reload before treating it as a workflow source defect."
    } catch {
        Write-Host "Kilo skill provenance: diagnostic unavailable: $($_.Exception.Message)"
    }
}

function ConvertTo-ItlActiveClientCommandText {
    param([string]$Text, [string]$Client = "")

    # An explicitly unresolved display context keeps the ordinary text fallback.
    if ($PSBoundParameters.ContainsKey('Client') -and [string]::IsNullOrWhiteSpace($Client)) {
        return $Text
    }

    try {
        $client = Get-ItlActiveClient -Client $Client
        $adapter = Get-ItlClientAdapter -Client $client
    } catch {
        return $Text
    }

    $prefix = switch ([string]$adapter.commandFormat) {
        "skill" {
            if ($client -eq "codex") { '$' } elseif ($client -eq "kimi") { "/skill:" } else { "/" }
        }
        default { "/" }
    }
    return $Text.Replace("/itl", ($prefix + "itl"))
}

function Write-ItlActiveClientCommandText {
    param([string]$Text, [string]$Client = "")
    if ($PSBoundParameters.ContainsKey('Client')) {
        Write-Host (ConvertTo-ItlActiveClientCommandText -Text $Text -Client $Client)
    } else {
        Write-Host (ConvertTo-ItlActiveClientCommandText -Text $Text)
    }
}

function Get-AiRules1cInstalledSkillRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SkillName,
        [string]$Client = ""
    )

    if ($SkillName -notmatch '^[a-z0-9][a-z0-9-]*$') {
        throw "Invalid ai_rules_1c skill name: '$SkillName'."
    }
    if ([string]::IsNullOrWhiteSpace($Client)) {
        $Client = Get-ItlActiveClient
    }
    $adapter = Get-ItlClientAdapter -Client $Client
    $skillsPath = [string]$adapter.skillsPath
    if ([string]::IsNullOrWhiteSpace($skillsPath)) {
        throw "ITL client '$Client' does not define an ai_rules_1c skills path."
    }

    return (Join-Path (Join-Path $script:ProjectRoot $skillsPath) $SkillName)
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
        "3a96fa2243ff6bc8f32b9689b3aed0189e633786755864829f477100c6794419",
        "782efb40f1db49711747401644f19f523606c384a7c9b739dc13a25ffed9b6c7",
        "4e48bfb2991a1661cea3283536e69185252b51ab1273b62b8d2371c7742b5746",
        "5ef04f1afe7e2203e46879fc28b0741d6a4624eae4e53dbc022a479064d31adf"
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
    Write-Utf8TextAtomic -Path (Get-ItlManagedMcpStatePath) -Value (($State | ConvertTo-Json -Depth 12) + [Environment]::NewLine)
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

function ConvertFrom-ItlMcpTomlValue {
    param([string]$Text)
    # Read the scalar/array syntax emitted by ITL. Unknown TOML stays opaque;
    # observation must never reject or rewrite an otherwise valid client file.
    $value = [regex]::Replace($Text, '(?m)("(?:\\.|[^"\\])*"|''[^'']*'')|\s*#.*$', '$1').Trim()
    if ($value -match "^'([^']*)'$") { return $matches[1] }
    if ($value.StartsWith('[') -and $value.EndsWith(']')) {
        $items = @([regex]::Matches($value.Substring(1, $value.Length - 2), '"(?:\\.|[^"\\])*"|''[^'']*''|[^,\s]+') | ForEach-Object {
            ConvertFrom-ItlMcpTomlValue -Text $_.Value
        })
        return ,$items
    }
    try { return ,($value | ConvertFrom-Json -ErrorAction Stop) } catch { return $value }
}

function Read-ItlClientMcpEntries {
    param([string]$Client = "")
    if (-not $Client) { $Client = Get-ItlActiveClient }
    $adapter = Get-ItlClientAdapter -Client $Client
    $path = Join-Path $script:ProjectRoot $adapter.mcpPath
    $entries = [ordered]@{}
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $entries }
    $text = Read-Utf8Text -Path $path
    if ($adapter.mcpFormat -ne "toml") {
        $config = ConvertTo-Vibecoding1cMcpHashtable -Object ($text | ConvertFrom-Json)
        $container = Get-ItlClientMcpContainer -Config $config -Path ([string]$adapter.mcpContainer)
        foreach ($name in @($container.Keys)) { $entries[$name] = ConvertTo-Vibecoding1cMcpHashtable -Object $container[$name] }
        return $entries
    }
    $section = $null
    # A server name is exactly one TOML key; env and tool subtables are not servers.
    $keyPattern = '(?:"(?:\\.|[^"\\])*"|''[^'']*''|[A-Za-z0-9_-]+)'
    $pendingKey = ''; $pendingValue = ''
    foreach ($line in ($text -split '\r?\n')) {
        if ($pendingKey) {
            $pendingValue += "`n$line"
            if ($line -match '\]\s*(?:#.*)?$') {
                $section[$pendingKey] = ConvertFrom-ItlMcpTomlValue -Text $pendingValue
                $pendingKey = ''; $pendingValue = ''
            }
            continue
        }
        if ($line -match ('^\s*\[mcp_servers\.(?<name>' + $keyPattern + ')(?<sub>(?:\.' + $keyPattern + ')*)\]\s*(?:#.*)?$')) {
            $name = [string](ConvertFrom-ItlMcpTomlValue -Text $matches.name)
            $sub = [string]$matches.sub
            if (-not $entries.Contains($name)) { $entries[$name] = [ordered]@{} }
            $section = $entries[$name]
            foreach ($part in [regex]::Matches($sub, $keyPattern)) {
                $key = [string](ConvertFrom-ItlMcpTomlValue -Text $part.Value)
                if (-not $section.Contains($key)) { $section[$key] = [ordered]@{} }
                $section = $section[$key]
            }
        } elseif ($line -match '^\s*\[') {
            $section = $null
        } elseif ($null -ne $section -and $line -match ('^\s*(?<key>' + $keyPattern + ')\s*=\s*(?<value>.*)$')) {
            $key = [string](ConvertFrom-ItlMcpTomlValue -Text $matches.key)
            $value = [string]$matches.value
            if ($value -match '^\s*\[' -and $value -notmatch '\]\s*(?:#.*)?$') {
                $pendingKey = $key; $pendingValue = $value
            } else { $section[$key] = ConvertFrom-ItlMcpTomlValue -Text $value }
        }
    }
    return $entries
}

function Get-ItlClientMcpEndpointKeys {
    param([string]$Client = "")
    return @((Read-ItlClientMcpEntries -Client $Client).Keys | ForEach-Object { [string]$_ })
}

function Get-ItlClientMcpEnablementObservation {
    param([string]$Client = "")

    if (-not $Client) { $Client = Get-ItlActiveClient }
    $adapter = Get-ItlClientAdapter -Client $Client
    $entries = Read-ItlClientMcpEntries -Client $Client
    $configuredServerIds = @($entries.Keys | Sort-Object -Unique)
    $disabledServerIds = @($configuredServerIds | Where-Object {
        $entry = $entries[$_]
        ($entry.Contains('enabled') -and $entry.enabled -is [bool] -and -not $entry.enabled) -or
        ($entry.Contains('disabled') -and $entry.disabled -is [bool] -and $entry.disabled)
    })
    $managedServerIds = @()
    $managedState = Read-ItlManagedMcpState
    if ($managedState.Contains("owners")) {
        $owners = ConvertTo-Vibecoding1cMcpHashtable -Object $managedState["owners"]
        foreach ($ownerKey in @($owners.Keys | Where-Object { $_ -like "$Client/*" })) {
            $managedServerIds += @($owners[$ownerKey] | ForEach-Object { [string]$_ } | Where-Object { $_ })
        }
    }
    $managedServerIds = @($managedServerIds | Sort-Object -Unique)
    $configuredManagedServerIds = @($managedServerIds | Where-Object { $_ -in $configuredServerIds })
    $missingManagedServerIds = @($managedServerIds | Where-Object { $_ -notin $configuredServerIds })
    $observationMode = [string](Get-StateValue -State $adapter -Name "mcpEnablementObservation" -Default "client-config")

    return [pscustomobject]@{
        applicable = ($observationMode -eq "private-client-state")
        client = $Client
        configPath = [string]$adapter.mcpPath
        configuredServerIds = @($configuredServerIds)
        disabledServerIds = @($disabledServerIds)
        connectionState = "not-observed"
        taskToolsState = "not-observable"
        configuredCount = @($configuredServerIds).Count
        managedServerIds = @($managedServerIds)
        expectedManagedCount = @($managedServerIds).Count
        configuredManagedServerIds = @($configuredManagedServerIds)
        configuredManagedCount = @($configuredManagedServerIds).Count
        missingManagedServerIds = @($missingManagedServerIds)
        enablementState = $(if ($observationMode -eq "private-client-state") { "not-observable" } else { "client-config" })
        instruction = [string](Get-StateValue -State $adapter -Name "mcpEnablementUserInstruction" -Default "")
    }
}

function Write-ItlClientMcpEnablementStatusLines {
    try {
        $observation = Get-ItlClientMcpEnablementObservation
    } catch {
        Write-Host "Client MCP enablement observation: unavailable ($($_.Exception.Message))"
        return
    }
    Write-Host "MCP connection and current task tools: not checked (configuration only)"
    if (@($observation.disabledServerIds).Count -gt 0) {
        Write-Host "MCP disabled in client config: $(@($observation.disabledServerIds) -join ', ')"
    }
    if (-not $observation.applicable) { return }

    $managedCoverage = if ($observation.expectedManagedCount -gt 0) {
        "$($observation.configuredManagedCount)/$($observation.expectedManagedCount)"
    } else {
        "<unknown>"
    }
    Write-Host "Cursor MCP client config: $($observation.configuredCount) servers; managed ITL coverage=$managedCoverage; path=$($observation.configPath)"
    if (@($observation.missingManagedServerIds).Count -gt 0) {
        Write-Host "Cursor MCP missing managed servers: $(@($observation.missingManagedServerIds) -join ', ')"
    }
    Write-Host "Cursor MCP Agent switches: not observable by ITL"
    if ($observation.instruction) {
        Write-Host "Cursor MCP required action: $($observation.instruction)"
    }
}

function Get-ItlManagedMcpOwnerKeys {
    param(
        [string]$Owner,
        [string]$Client = ""
    )

    if (-not $Client) { $Client = Get-ItlActiveClient }
    $state = Read-ItlManagedMcpState
    if (-not $state.Contains("owners")) {
        return @()
    }
    $owners = ConvertTo-Vibecoding1cMcpHashtable -Object $state["owners"]
    $stateKey = "$Client/$Owner"
    if (-not $owners.Contains($stateKey)) {
        return @()
    }
    return @($owners[$stateKey] | ForEach-Object { [string]$_ } | Where-Object { $_ } | Select-Object -Unique)
}

function ConvertTo-ItlMcpSemanticCanonicalValue {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary] -or $Value -is [pscustomobject]) {
        $table = ConvertTo-Vibecoding1cMcpHashtable -Object $Value
        [string[]]$keys = @($table.Keys | ForEach-Object { [string]$_ })
        [System.Array]::Sort($keys, [System.StringComparer]::Ordinal)
        $canonical = [ordered]@{}
        foreach ($key in $keys) {
            $canonical[$key] = ConvertTo-ItlMcpSemanticCanonicalValue -Value $table[$key]
        }
        return $canonical
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        return [object[]]@($Value | ForEach-Object { ConvertTo-ItlMcpSemanticCanonicalValue -Value $_ })
    }
    return $Value
}

function Get-ItlMcpOwnedSemanticSignature {
    param(
        [System.Collections.IDictionary]$Container,
        [string[]]$Names
    )

    [string[]]$ownedNames = @($Names | ForEach-Object { [string]$_ } | Where-Object { $_ } | Select-Object -Unique)
    [System.Array]::Sort($ownedNames, [System.StringComparer]::Ordinal)
    $owned = [ordered]@{}
    foreach ($name in $ownedNames) {
        $owned[$name] = if ($Container.Contains($name)) {
            ConvertTo-ItlMcpSemanticCanonicalValue -Value $Container[$name]
        } else {
            $null
        }
    }
    return ($owned | ConvertTo-Json -Depth 30 -Compress)
}

function Register-ItlClientMcpSemanticChange {
    param(
        [string]$Client,
        [string]$Owner,
        [string]$Path
    )

    if (-not (Get-Variable -Name ItlClientMcpSemanticChanges -Scope Script -ErrorAction SilentlyContinue)) {
        $script:ItlClientMcpSemanticChanges = [ordered]@{}
    }
    $script:ItlClientMcpSemanticChanges["$Client/$Owner"] = [pscustomobject]@{
        client = $Client
        owner = $Owner
        path = $Path
    }
}

function Get-ItlClientMcpSemanticChanges {
    param([string]$Owner = "")

    if (-not (Get-Variable -Name ItlClientMcpSemanticChanges -Scope Script -ErrorAction SilentlyContinue)) {
        return @()
    }
    return @($script:ItlClientMcpSemanticChanges.Values | Where-Object { -not $Owner -or $_.owner -eq $Owner })
}

function Get-ItlMcpTextState {
    param([string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ('file:' + ([BitConverter]::ToString($sha.ComputeHash((Get-Utf8Encoding).GetBytes($Text)))).Replace('-', '').ToLowerInvariant()) }
    finally { $sha.Dispose() }
}

function Get-ItlMcpFileState {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 'absent' }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "CLIENT_MCP_PATH_NOT_FILE: preserve '$Path' and restore the client's expected config file before retrying." }
    return ('file:' + (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant())
}

function Copy-ItlClientMcpOwnershipFromProof {
    param(
        [Parameter(Mandatory = $true)][string]$Client,
        [Parameter(Mandatory = $true)][string]$SourceConfigPath,
        [Parameter(Mandatory = $true)][string]$SourceOwnershipPath,
        [Parameter(Mandatory = $true)][string]$ExpectedConfigState,
        [Parameter(Mandatory = $true)][string]$ExpectedOwnershipState,
        [string]$TargetProjectRoot = $script:ProjectRoot
    )

    if (-not [string]::Equals((Resolve-Agent1cFullPath -Path $TargetProjectRoot), (Resolve-Agent1cFullPath -Path $script:ProjectRoot), [StringComparison]::OrdinalIgnoreCase)) {
        return (Invoke-InProjectContext -Root $TargetProjectRoot -ScriptBlock {
            Copy-ItlClientMcpOwnershipFromProof -Client $Client -SourceConfigPath $SourceConfigPath -SourceOwnershipPath $SourceOwnershipPath `
                -ExpectedConfigState $ExpectedConfigState -ExpectedOwnershipState $ExpectedOwnershipState
        })
    }
    # The lifecycle caller proves the new copy or the retained same-fork capsule
    # and repository scope. This owner only transfers the proved config's keys;
    # names, prefixes or similar endpoint settings are never ownership proof.
    $adapter = Get-ItlClientAdapter -Client $Client
    Assert-ItlClientConfigWritable -Client $Client
    if ([string]$adapter.mcpFormat -ne 'json') { throw 'CLIENT_MCP_COPY_PROOF_INVALID: copied ownership requires the existing JSON client format.' }
    $targetConfig = Join-Path $script:ProjectRoot ([string]$adapter.mcpPath)
    $targetOwnership = Get-ItlManagedMcpStatePath
    $targetOwnershipBefore = Get-ItlMcpFileState -Path $targetOwnership
    if ($ExpectedConfigState -cnotmatch '^file:[a-f0-9]{64}$' -or
        $ExpectedOwnershipState -cnotmatch '^(absent|file:[a-f0-9]{64})$' -or
        (Get-ItlMcpFileState -Path $SourceConfigPath) -cne $ExpectedConfigState -or
        (Get-ItlMcpFileState -Path $targetConfig) -cne $ExpectedConfigState -or
        (Get-ItlMcpFileState -Path $SourceOwnershipPath) -cne $ExpectedOwnershipState) {
        throw 'CLIENT_MCP_COPY_PROOF_CHANGED: copied config or source ownership differs from its exact proof; preserve the files and repeat the original owner recovery.'
    }
    $imported = [ordered]@{}
    $changed = $false
    if ($ExpectedOwnershipState -cne 'absent') {
        $config = ConvertTo-Vibecoding1cMcpHashtable -Object (Read-Utf8Text -Path $SourceConfigPath | ConvertFrom-Json -ErrorAction Stop)
        $container = Get-ItlClientMcpContainer -Config $config -Path ([string]$adapter.mcpContainer)
        $sourceState = ConvertTo-Vibecoding1cMcpHashtable -Object (Read-Utf8Text -Path $SourceOwnershipPath | ConvertFrom-Json -ErrorAction Stop)
        $sourceOwners = ConvertTo-Vibecoding1cMcpHashtable -Object $sourceState['owners']
        foreach ($key in @($sourceOwners.Keys)) {
            if (-not ([string]$key).StartsWith("$Client/", [StringComparison]::Ordinal)) { continue }
            if ([string]$key -ceq "$Client/") { throw 'CLIENT_MCP_OWNER_STATE_INVALID: copied ownership has an empty owner name.' }
            $names = @($sourceOwners[$key] | ForEach-Object { [string]$_ } | Where-Object { $_ -and $container.Contains($_) } | Select-Object -Unique)
            if ($names.Count -gt 0) { $imported[[string]$key] = $names }
        }
        $state = Read-ItlManagedMcpState
        $owners = ConvertTo-Vibecoding1cMcpHashtable -Object $state['owners']
        foreach ($key in @($imported.Keys)) {
            foreach ($otherKey in @($owners.Keys | Where-Object { $_ -cne $key })) {
                $separator = ([string]$otherKey).IndexOf('/')
                if ($separator -le 0) { throw 'CLIENT_MCP_OWNER_STATE_INVALID: current ownership has no client prefix.' }
                $otherAdapter = Get-ItlClientAdapter -Client ([string]$otherKey).Substring(0, $separator)
                if ([string]$otherAdapter.mcpPath -ine [string]$adapter.mcpPath -or [string]$otherAdapter.mcpContainer -ine [string]$adapter.mcpContainer) { continue }
                foreach ($name in @($imported[$key])) {
                    if ($name -in @($owners[$otherKey]) -and
                        (-not $imported.Contains([string]$otherKey) -or $name -notin @($imported[$otherKey]))) {
                        throw "CLIENT_MCP_OWNER_CONFLICT: '$name' already belongs to '$otherKey'; copied proof cannot replace that ownership."
                    }
                }
            }
            $currentNames = @($owners[$key])
            $additions = @($imported[$key] | Where-Object { $_ -notin $currentNames })
            if ($additions.Count -gt 0) {
                $owners[$key] = @($currentNames | Where-Object { $_ }) + $additions
                $changed = $true
            }
        }
        if ($changed) { $state['owners'] = $owners }
    }
    if ((Get-ItlMcpFileState -Path $SourceConfigPath) -cne $ExpectedConfigState -or
        (Get-ItlMcpFileState -Path $SourceOwnershipPath) -cne $ExpectedOwnershipState -or
        (Get-ItlMcpFileState -Path $targetConfig) -cne $ExpectedConfigState -or
        (Get-ItlMcpFileState -Path $targetOwnership) -cne $targetOwnershipBefore) {
        throw 'CLIENT_MCP_FINAL_SET_CHANGED: config or ownership changed while verifying the copied proof; no ownership was written.'
    }
    if ($changed) { Write-ItlManagedMcpState -State $state }
    return [pscustomobject]@{
        changed = $changed; importedOwners = $imported; importedKeys = @($imported.Values | ForEach-Object { $_ } | Select-Object -Unique)
        configState = $ExpectedConfigState; ownerState = (Get-ItlMcpFileState -Path $targetOwnership)
    }
}

function Write-ItlClientMcpEndpoints {
    param(
        [object[]]$Endpoints,
        [string]$Owner,
        [string]$Client = "",
        [string[]]$PreserveOwnedKeys = @(),
        [switch]$PlanOnly,
        [string[]]$FinalSetOwnerKeys = @(),
        [string[]]$ReplaceAiRulesServerIds = @(),
        [switch]$ReturnReceipt
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

    $beforeFileState = Get-ItlMcpFileState -Path $path
    $beforeOwnerState = Get-ItlMcpFileState -Path (Get-ItlManagedMcpStatePath)
    if ($adapter.mcpFormat -eq "toml") {
        $beforeEntries = Read-ItlClientMcpEntries -Client $Client
        $state = Read-ItlManagedMcpState
        $owners = ConvertTo-Vibecoding1cMcpHashtable -Object (Get-Vibecoding1cMcpObjectValue -Object $state -Name "owners" -Default ([ordered]@{}))
        $names = @(@($owners["$Client/$Owner"]) + @($normalized | ForEach-Object { $_.name }) + @($PreserveOwnedKeys) | Where-Object { $_ } | Select-Object -Unique)
        $before = Get-ItlMcpOwnedSemanticSignature -Container $beforeEntries -Names $names
        $existingText = if (Test-Path -LiteralPath $path -PathType Leaf) { Read-Utf8Text -Path $path } else { "" }
        $writeText = $existingText
        $ownBlockPattern = '(?ms)^# >>> vibecoding1c-mcp ' + [regex]::Escape($Owner) + '\r?\n.*?^# <<< vibecoding1c-mcp ' + [regex]::Escape($Owner) + '(?:\r?\n|$)'
        $ownBlocks = @([regex]::Matches($existingText, $ownBlockPattern))
        $removeSections = @()
        foreach ($name in @(@($normalized | ForEach-Object { [string]$_.name }) + @($PreserveOwnedKeys) | Where-Object { $_ } | Select-Object -Unique)) {
            $token = '(?:' + [regex]::Escape((ConvertTo-Vibecoding1cMcpTomlString $name)) + '|' + [regex]::Escape($name) + '|''' + [regex]::Escape($name) + ''')'
            $sections = @([regex]::Matches($existingText, '(?ms)^\s*\[mcp_servers\.' + $token + '(?<sub>\.[^\]]+)?\][^\r\n]*\r?\n.*?(?=^\s*\[|^# >>>|^# <<<|\z)'))
            $outsideRoots = @($sections | Where-Object {
                $section = $_
                -not $section.Groups['sub'].Success -and -not @($ownBlocks | Where-Object { $section.Index -ge $_.Index -and $section.Index -lt ($_.Index + $_.Length) }).Count
            })
            foreach ($section in $outsideRoots) {
                $inManagedBlock = Test-TextIndexInsideVibecoding1cMcpManagedBlock -Text $existingText -Index $section.Index
                $legacy = $Owner -eq 'vibecoding1c' -and -not $inManagedBlock -and (
                    (Test-Vibecoding1cMcpTomlSectionIsManaged -SectionText $section.Value) -or
                    ($Client -eq 'codex' -and $name -in $ReplaceAiRulesServerIds -and
                        (Test-AiRules1cMcpEntryCanBeRemoved -ManagedBy (Get-AiRules1cTomlMcpManagedBy -SectionText $section.Value))))
                if (-not $legacy) {
                    throw "CLIENT_MCP_USER_COLLISION: '$name' already has a TOML section outside owner '$Owner' in '$($adapter.mcpPath)'. Preserve it and choose another managed key or resolve its ownership before retrying. No client MCP file was replaced."
                }
                $removeSections += @($sections | Where-Object {
                    $candidate = $_
                    -not (Test-TextIndexInsideVibecoding1cMcpManagedBlock -Text $existingText -Index $candidate.Index)
                })
            }
            if ($outsideRoots.Count -eq 0 -and @($sections | Where-Object {
                $section = $_
                -not @($ownBlocks | Where-Object { $section.Index -ge $_.Index -and $section.Index -lt ($_.Index + $_.Length) }).Count
            }).Count -gt 0) {
                throw "CLIENT_MCP_USER_COLLISION: '$name' has a foreign TOML subtable in '$($adapter.mcpPath)'. Preserve it and resolve ownership before retrying."
            }
        }
        foreach ($section in @($removeSections | Sort-Object Index -Unique -Descending)) {
            $writeText = $writeText.Remove($section.Index, $section.Length)
        }
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
            $enabled = Get-Vibecoding1cMcpObjectValue -Object $beforeEntries[$endpoint.name] -Name "enabled" -Default $true
            $lines.Add("enabled = $(([string]$enabled).ToLowerInvariant())")
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
            $nameToken = '(?:' + [regex]::Escape((ConvertTo-Vibecoding1cMcpTomlString $endpoint.name)) + '|' + [regex]::Escape($endpoint.name) + '|''' + [regex]::Escape($endpoint.name) + ''')'
            $rootMatch = [regex]::Match($existingText, '(?ms)^\s*\[mcp_servers\.' + $nameToken + '\][^\r\n]*\r?\n(?<body>.*?)(?=^\s*\[|^# >>>|^# <<<|\z)')
            $policyLines = [Collections.Generic.List[string]]::new()
            $keep = $false
            foreach ($line in ($rootMatch.Groups['body'].Value -split '\r?\n')) {
                if ($line -match '^\s*(?<key>"(?:\\.|[^"\\])*"|''[^'']*''|[A-Za-z0-9_-]+)\s*=') {
                    $keep = (ConvertFrom-ItlMcpTomlValue -Text $matches.key) -notin @('url','command','args','enabled','startup_timeout_sec','tool_timeout_sec','managedBy','family')
                }
                if ($keep) { $policyLines.Add($line) }
            }
            # Insert root policy before the generated env subtable.
            $rootInsert = $lines.Count
            for ($i = $lines.Count - 1; $i -ge 0; $i--) {
                if ($lines[$i] -eq "[mcp_servers.$(ConvertTo-Vibecoding1cMcpTomlString $endpoint.name).env]") { $rootInsert = $i; break }
                if ($lines[$i] -eq "[mcp_servers.$(ConvertTo-Vibecoding1cMcpTomlString $endpoint.name)]") { break }
            }
            $lines.InsertRange($rootInsert, [string[]]@($policyLines))
            foreach ($subtable in [regex]::Matches($existingText, '(?ms)^\s*\[mcp_servers\.' + $nameToken + '\.(?<sub>[^\]]+)\][^\r\n]*\r?\n.*?(?=^\s*\[|^# >>>|^# <<<|\z)')) {
                if ((ConvertFrom-ItlMcpTomlValue -Text $subtable.Groups['sub'].Value) -ne 'env') { $lines.Add($subtable.Value.TrimEnd()) }
            }
            $lines.Add("")
        }
        foreach ($name in @($PreserveOwnedKeys | Where-Object { $_ -notin @($normalized | ForEach-Object { $_.name }) })) {
            $token = '(?:' + [regex]::Escape((ConvertTo-Vibecoding1cMcpTomlString $name)) + '|' + [regex]::Escape($name) + '|''' + [regex]::Escape($name) + ''')'
            foreach ($section in [regex]::Matches($existingText, '(?ms)^\s*\[mcp_servers\.' + $token + '(?:\.[^\]]+)?\][^\r\n]*\r?\n.*?(?=^\s*\[|^# >>>|^# <<<|\z)')) {
                $lines.Add($section.Value.TrimEnd())
            }
        }
        $content = Set-Vibecoding1cMcpManagedTextBlock -Path $path -BlockId $Owner -Body ((@($lines) -join [Environment]::NewLine).TrimEnd()) -ExistingText $writeText -PlanOnly
        if ($PlanOnly) {
            $claims = [ordered]@{}
            foreach ($endpoint in $normalized) { $claims[$endpoint.name] = $endpoint }
            return [pscustomobject]@{ path=$path; ownerKey="$Client/$Owner"; entries=$claims; beforeFileState=$beforeFileState; beforeOwnerState=$beforeOwnerState }
        }
        $expectedFileState = if ((Test-Path -LiteralPath $path -PathType Leaf) -and (Read-Utf8Text -Path $path) -ceq $content) { $beforeFileState } else { Get-ItlMcpTextState -Text $content }
        if ($expectedFileState -cne $beforeFileState) { Write-Utf8TextAtomic -Path $path -Value $content }
        $state = Read-ItlManagedMcpState
        if (-not $state.Contains("owners")) { $state["owners"] = [ordered]@{} }
        $owners = ConvertTo-Vibecoding1cMcpHashtable -Object $state["owners"]
        $owners["$Client/$Owner"] = @(@($normalized | ForEach-Object { [string]$_.name }) + @($PreserveOwnedKeys) | Select-Object -Unique)
        $state["owners"] = $owners
        Write-ItlManagedMcpState -State $state
        $after = Get-ItlMcpOwnedSemanticSignature -Container (Read-ItlClientMcpEntries -Client $Client) -Names $names
        if ($before -cne $after) { Register-ItlClientMcpSemanticChange -Client $Client -Owner $Owner -Path $path }
        if ($ReturnReceipt) { return [pscustomobject]@{ path=$path; fileState=$expectedFileState; ownerState=(Get-ItlMcpTextState -Text (($state | ConvertTo-Json -Depth 12) + [Environment]::NewLine)) } }
        return $path
    }

    $config = [ordered]@{}
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        try { $config = ConvertTo-Vibecoding1cMcpHashtable -Object (Read-Utf8Text -Path $path | ConvertFrom-Json) } catch { throw "Client MCP config is not valid JSON: $path. $($_.Exception.Message)" }
    }
    $containerName = [string]$adapter.mcpContainer
    $container = Get-ItlClientMcpContainer -Config $config -Path $containerName
    $beforeContainer = ConvertTo-Vibecoding1cMcpHashtable -Object $container
    $legacyNames = @($container.Keys | Where-Object { $Owner -eq "vibecoding1c" -and (Get-Vibecoding1cMcpObjectValue -Object $container[$_] -Name "managedBy" -Default "") -eq "vibecoding1c-mcp" -and (Get-Vibecoding1cMcpObjectValue -Object $container[$_] -Name "family" -Default "") -eq "vibecoding1c" })
    if ($Owner -eq 'vibecoding1c' -and $Client -eq 'kilocode') {
        $replacementKeys = @($ReplaceAiRulesServerIds | ForEach-Object { ConvertTo-ItlClientMcpKey -Name $_ -Client $Client })
        $legacyNames += @($container.Keys | Where-Object {
            (ConvertTo-ItlClientMcpKey -Name ([string]$_) -Client $Client) -in $replacementKeys -and
                (Test-AiRules1cMcpEntryCanBeRemoved -ManagedBy ([string](Get-Vibecoding1cMcpObjectValue -Object $container[$_] -Name 'managedBy' -Default '')))
        })
    }
    $state = Read-ItlManagedMcpState
    if (-not $state.Contains("owners")) { $state["owners"] = [ordered]@{} }
    $owners = ConvertTo-Vibecoding1cMcpHashtable -Object $state["owners"]
    $stateKey = "$Client/$Owner"
    $sharedOwners = [ordered]@{}
    $plannedOwnedNames = @()
    foreach ($otherStateKey in @($owners.Keys | Where-Object { $_ -cne $stateKey })) {
        $separator = ([string]$otherStateKey).IndexOf('/')
        if ($separator -le 0) { throw "CLIENT_MCP_OWNER_STATE_INVALID: '$otherStateKey' has no client prefix; preserve the MCP config and reconcile ownership before retrying." }
        $otherClient = ([string]$otherStateKey).Substring(0, $separator)
        $otherAdapter = Get-ItlClientAdapter -Client $otherClient
        if (-not [string]::Equals([string]$otherAdapter.mcpPath, [string]$adapter.mcpPath, [StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals([string]$otherAdapter.mcpContainer, $containerName, [StringComparison]::OrdinalIgnoreCase)) { continue }
        if ($otherStateKey -in $FinalSetOwnerKeys) {
            $plannedOwnedNames += @($owners[$otherStateKey])
            continue
        }
        foreach ($key in @($owners[$otherStateKey])) {
            if (-not $key) { continue }
            if (-not $sharedOwners.Contains([string]$key)) { $sharedOwners[[string]$key] = @() }
            $sharedOwners[[string]$key] = @($sharedOwners[[string]$key]) + @([string]$otherStateKey)
        }
    }
    if ($adapter.PSObject.Properties.Name -contains "configCollisionCheck" -and $adapter.configCollisionCheck -eq "mimocode-jsonc") {
        $jsonc = Join-Path $script:ProjectRoot ".mimocode\mimocode.jsonc"
        if (Test-Path -LiteralPath $jsonc -PathType Leaf) {
            throw "MIMOCODE_CONFIG_COLLISION: '$jsonc' is present. ITL cannot safely merge JSONC comments or prove which project config MiMo Code loads. Preserve it and explicitly consolidate into .mimocode/mimocode.json before attaching or updating MiMo Code."
        }
    }
    $semanticNames = @(
        @($owners[$stateKey])
        @($normalized | ForEach-Object { [string]$_.name })
        @($PreserveOwnedKeys)
        @($legacyNames)
    ) | ForEach-Object { [string]$_ } | Where-Object { $_ } | Select-Object -Unique
    $beforeSemanticSignature = Get-ItlMcpOwnedSemanticSignature -Container $container -Names $semanticNames
    foreach ($oldKey in @($owners[$stateKey]) + @($legacyNames)) {
        if ($PreserveOwnedKeys -contains [string]$oldKey) { continue }
        if ($sharedOwners.Contains([string]$oldKey)) { continue }
        if ($container.Contains([string]$oldKey)) { $container.Remove([string]$oldKey) }
    }
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
        } elseif ($endpoint.transport -eq "stdio" -and $adapter.mcpStdioFormat -eq "zcode") {
            $local = [ordered]@{ type = "stdio"; command = $endpoint.command; args = @($endpoint.args) }
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
        if ($Owner -eq "vibecoding1c") {
            $entry["managedBy"] = "vibecoding1c-mcp"
            $entry["family"] = "vibecoding1c"
        }
        $previousKey = [string]$endpoint.name
        $ownedAlias = $false
        if (-not $beforeContainer.Contains($previousKey)) {
            $aliases = @($beforeContainer.Keys | Where-Object {
                (ConvertTo-ItlClientMcpKey -Name ([string]$_) -Client $Client) -ceq $endpoint.name -and
                ($_ -in @($owners[$stateKey]) -or $_ -in $legacyNames)
            })
            if ($aliases.Count -gt 1) { throw "CLIENT_MCP_OWNER_CONFLICT: several previously owned keys map to '$($endpoint.name)'; preserve them and reconcile their policy before retrying." }
            if ($aliases.Count -eq 1) { $previousKey = [string]$aliases[0]; $ownedAlias = $true }
        }
        if ($beforeContainer.Contains($previousKey)) {
            # Transport is helper-owned; preserve the user's policy/auth fields.
            $previous = ConvertTo-Vibecoding1cMcpHashtable -Object $beforeContainer[$previousKey]
            foreach ($key in @($previous.Keys)) {
                if (-not $entry.Contains($key) -and $key -notin @('url','httpUrl','command','args','env','environment','transport','type','timeout','lifecycle','managedBy','family')) { $entry[$key] = $previous[$key] }
            }
            foreach ($key in @('enabled','disabled')) {
                if ($previous.Contains($key)) { $entry[$key] = $previous[$key] }
            }
            if ($sharedOwners.Contains([string]$endpoint.name)) {
                $candidate = [ordered]@{}; $candidate[$endpoint.name] = $entry
                $existing = [ordered]@{}; $existing[$endpoint.name] = $previous
                if ((Get-ItlMcpOwnedSemanticSignature -Container $candidate -Names @($endpoint.name)) -cne
                    (Get-ItlMcpOwnedSemanticSignature -Container $existing -Names @($endpoint.name))) {
                    throw "CLIENT_MCP_OWNER_CONFLICT: '$($endpoint.name)' in '$($adapter.mcpPath)' is owned by $($sharedOwners[[string]$endpoint.name] -join ', ') with different settings. No client MCP file was replaced."
                }
                $entry = $previous
            } elseif (-not $ownedAlias -and $endpoint.name -notin @($owners[$stateKey]) -and $endpoint.name -notin $legacyNames -and $endpoint.name -notin $plannedOwnedNames) {
                throw "CLIENT_MCP_USER_COLLISION: '$($endpoint.name)' already exists in '$($adapter.mcpPath)' without ITL ownership. Preserve the user entry and choose another managed key before retrying."
            }
        }
        $container[$endpoint.name] = $entry
        $written += $endpoint.name
    }
    [string[]]$containerKeys = @($container.Keys | ForEach-Object { [string]$_ })
    [System.Array]::Sort($containerKeys, [System.StringComparer]::Ordinal)
    $orderedContainer = [ordered]@{}
    foreach ($key in $containerKeys) {
        $orderedContainer[$key] = $container[$key]
    }
    Set-ItlClientMcpContainer -Config $config -Path $containerName -Container $orderedContainer
    if ($PlanOnly) {
        $claims = [ordered]@{}
        foreach ($name in @($written + $PreserveOwnedKeys | Select-Object -Unique)) {
            if ($orderedContainer.Contains($name)) { $claims[$name] = $orderedContainer[$name] }
        }
        return [pscustomobject]@{ path=$path; ownerKey=$stateKey; entries=$claims; beforeFileState=$beforeFileState; beforeOwnerState=$beforeOwnerState }
    }
    $content = ($config | ConvertTo-Json -Depth 20) + [Environment]::NewLine
    $expectedFileState = if ((Test-Path -LiteralPath $path -PathType Leaf) -and (Read-Utf8Text -Path $path) -ceq $content) { $beforeFileState } else { Get-ItlMcpTextState -Text $content }
    Write-Vibecoding1cMcpJsonFile -Path $path -Value $config
    $afterSemanticSignature = Get-ItlMcpOwnedSemanticSignature -Container $orderedContainer -Names $semanticNames
    if ($beforeSemanticSignature -cne $afterSemanticSignature) {
        Register-ItlClientMcpSemanticChange -Client $Client -Owner $Owner -Path $path
    }
    $owners[$stateKey] = @($written + @($PreserveOwnedKeys) | Select-Object -Unique)
    $state["owners"] = $owners
    Write-ItlManagedMcpState -State $state
    if ($ReturnReceipt) { return [pscustomobject]@{ path=$path; fileState=$expectedFileState; ownerState=(Get-ItlMcpTextState -Text (($state | ConvertTo-Json -Depth 12) + [Environment]::NewLine)) } }
    return $path
}

function Write-ItlClientMcpEndpointSet {
    param([Parameter(Mandatory = $true)][object[]]$Requests, [string[]]$AdditionalInputPaths = @(), [switch]$PlanOnly)

    if ($Requests.Count -eq 0) { return }
    $ownerKeys = @()
    foreach ($request in $Requests) {
        $key = "$( [string]$request.client )/$( [string]$request.owner )"
        if ($key -in $ownerKeys) { throw "CLIENT_MCP_FINAL_SET_INVALID: duplicate request for '$key'; combine that owner's endpoints before preflight." }
        $ownerKeys += $key
    }
    $plans = @()
    $claims = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    $fileStates = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
    $ownerPath = Get-ItlManagedMcpStatePath
    $ownerState = Get-ItlMcpFileState -Path $ownerPath
    foreach ($path in @($AdditionalInputPaths | Where-Object { $_ } | Select-Object -Unique)) {
        $fileStates[$path] = Get-ItlMcpFileState -Path $path
    }
    foreach ($request in $Requests) {
        $arguments = @{ Client=[string]$request.client; Owner=[string]$request.owner; Endpoints=@($request.endpoints)
            PreserveOwnedKeys=@(Get-Vibecoding1cMcpObjectValue -Object $request -Name 'preserveOwnedKeys' -Default @()); FinalSetOwnerKeys=$ownerKeys
            ReplaceAiRulesServerIds=@(Get-Vibecoding1cMcpObjectValue -Object $request -Name 'replaceAiRulesServerIds' -Default @()) }
        $plan = Write-ItlClientMcpEndpoints @arguments -PlanOnly
        if ($plan.beforeOwnerState -cne $ownerState -or ($fileStates.ContainsKey($plan.path) -and $fileStates[$plan.path] -cne $plan.beforeFileState)) {
            throw 'CLIENT_MCP_FINAL_SET_CHANGED: config/ownership changed during preflight; preserve those edits and rebuild the final set before writing.'
        }
        $fileStates[$plan.path] = $plan.beforeFileState
        $adapter = Get-ItlClientAdapter -Client ([string]$request.client)
        foreach ($name in @($plan.entries.Keys)) {
            $containerName = [string](Get-StateValue -State $adapter -Name 'mcpContainer' -Default 'mcp_servers')
            $key = ([string]$plan.path).ToLowerInvariant() + '|' + $containerName + '|' + [string]$name
            $signature = Get-ItlMcpOwnedSemanticSignature -Container $plan.entries -Names @([string]$name)
            if ($claims.ContainsKey($key) -and ($adapter.mcpFormat -eq 'toml' -or $claims[$key] -cne $signature)) {
                throw "CLIENT_MCP_OWNER_CONFLICT: desired owners provide different settings for '$name' in '$($adapter.mcpPath)'. No client MCP config or ownership was written."
            }
            $claims[$key] = $signature
        }
        $plans += [pscustomobject]@{ arguments=$arguments; path=[string]$plan.path }
    }
    # Check every input before the first write, including a later client's file.
    foreach ($path in @($fileStates.Keys)) {
        if ((Get-ItlMcpFileState -Path $path) -cne $fileStates[$path]) { throw "CLIENT_MCP_FINAL_SET_CHANGED: '$path' changed after preflight; no MCP config was written. Preserve it and rebuild the final set." }
    }
    if ((Get-ItlMcpFileState -Path $ownerPath) -cne $ownerState) { throw 'CLIENT_MCP_FINAL_SET_CHANGED: ownership changed after preflight; no MCP config was written. Preserve it and rebuild the final set.' }
    if ($PlanOnly) { return @($plans.path | Select-Object -Unique) }
    foreach ($plan in $plans) {
        if ((Get-ItlMcpFileState -Path $plan.path) -cne $fileStates[$plan.path] -or
            (Get-ItlMcpFileState -Path $ownerPath) -cne $ownerState) {
            throw "CLIENT_MCP_FINAL_SET_CHANGED: '$($plan.path)' or ownership changed before its write; completed writes remain owned. Preserve the edits and repeat the original owner reconciliation."
        }
        $arguments = $plan.arguments
        $receipt = Write-ItlClientMcpEndpoints @arguments -ReturnReceipt
        if ((Get-ItlMcpFileState -Path $receipt.path) -cne $receipt.fileState -or
            (Get-ItlMcpFileState -Path $ownerPath) -cne $receipt.ownerState) {
            throw 'CLIENT_MCP_FINAL_SET_WRITE_UNCONFIRMED: actual bytes differ from the intended writer result; preserve current and before state through the original owner recovery.'
        }
        $fileStates[$receipt.path] = [string]$receipt.fileState
        $ownerState = [string]$receipt.ownerState
    }
    return @($plans.path | Select-Object -Unique)
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
    $container = Get-ItlClientMcpContainer -Config $config -Path $containerName
    if ($container.Count -eq 0) { return }
    $changed = $false
    foreach ($key in @($container.Keys)) {
        $managedBy = [string](Get-Vibecoding1cMcpObjectValue -Object $container[$key] -Name "managedBy" -Default "")
        if ($managedBy -in @("itl-branch-mcp", "vanessa-mcp", "vanessa-ui-mcp")) {
            $container.Remove($key)
            $changed = $true
        }
    }
    if ($changed) {
        Set-ItlClientMcpContainer -Config $config -Path $containerName -Container $container
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
        "itl.md", "itl-status.md", "itl-sync-master.md", "itl-new-config-branch.md",
        "itl-new-extension-branch.md", "itl-check.md", "itl-refresh.md",
        "itl-refresh-lite.md", "itl-refresh-all.md", "itl-fork-branch.md", "itl-sync-branches.md", "itl-reset-branch.md", "itl-lock-objects.md",
        "itl-result.md", "itl-update-workflow.md", "itl-litemode.md", "itl-repository-mode.md", "itl-switch-client.md"
    )
}

function Get-ItlExplicitRoutineContractText {
    param([string]$NewLine = [Environment]::NewLine)

    return @(
        '<!-- ITL_EXPLICIT_ROUTINE_CONTRACT: self-contained-v2 -->',
        '',
        'This explicit ITL routine is self-contained. Do not preload `1c-workflow` or `1c-workflow-fast`. A path under `.agents\skills\1c-workflow\scripts\` names the helper implementation, not a router-skill dependency. Follow `requiredAction`/`nextAction`; when either names another explicit ITL wrapper, use that wrapper alone. Load detailed recovery guidance only when the helper requires recovery without an explicit wrapper.',
        '',
        'Before the helper call, use at most one short sentence and make the exact helper command the first and only tool action: do not read skills or `.dev.env`, inspect Git, or duplicate helper-owned preflight. The helper emits `ITL response-style` on stderr and `responseStyle` in its bounded JSON; apply an explicit session Caveman override first, otherwise use that runtime profile. Keep every required progress heartbeat to one line containing only the current stage and material liveness state; do not narrate unchanged diagnostics. Preserve a successful `userReport` verbatim regardless of style. When `userReportOmitted=true`, read only the full absolute `userReportPath`: use the file contents directly for `userReportSource=file`, or only its `userReport` JSON property for `userReportSource=status-json`. Return the recovered report verbatim and never treat transport omission as an operation failure.'
    ) -join $NewLine
}

function Add-ItlExplicitRoutineContract {
    param([string]$Text, [string]$FileName)

    if ($FileName -notin (Get-ItlRoutineCommandNames)) { return $Text }
    if ($Text -match '(?m)^<!-- ITL_EXPLICIT_ROUTINE_CONTRACT:') { return $Text }

    $frontmatter = [regex]::Match($Text, '\A---\r?\n.*?\r?\n---\r?\n', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $frontmatter.Success) {
        throw "ITL explicit routine template has no frontmatter: $FileName"
    }
    $newLine = if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $insert = $newLine + (Get-ItlExplicitRoutineContractText -NewLine $newLine) + $newLine
    return $Text.Insert($frontmatter.Length, $insert)
}

function Get-ItlRoutineLongCommandNames {
    return @(
        "itl-new-config-branch.md", "itl-new-extension-branch.md",
        "itl-check.md", "itl-sync-master.md", "itl-refresh.md", "itl-refresh-lite.md",
        "itl-refresh-all.md", "itl-fork-branch.md", "itl-sync-branches.md", "itl-reset-branch.md", "itl-lock-objects.md", "itl-result.md",
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
    param([string]$Client)
    $modelMap = Get-ConfigValue -Path 'aiRules.modelTiersByClient' -Default $null
    if ($null -ne $modelMap) {
        $model = ([string](Get-ConfigValue -Path "aiRules.modelTiersByClient.$Client.light" -Default '')).Trim()
    } else {
        $attached = @(Get-AgentTargets)
        $model = if ($attached.Count -eq 1 -and $attached[0] -eq $Client) {
            ([string](Get-EnvValue -Name 'SUBAGENT_MODEL_LIGHT' -Default '')).Trim()
        } else { '' }
    }
    if ($model -and $model -notmatch '^[^/\s]+/[^/\s]+$') {
        throw "SUBAGENT_MODEL_LIGHT must use provider/model format when ITL routine mode is enabled."
    }
    return $model
}

function Test-ItlRoutineEnabledForCommand {
    param([string]$FileName, [string]$Client)

    if ($FileName -notin (Get-ItlRoutineCommandNames)) { return $false }
    # The current-dialog agent owns task-level response composition after export.
    # Keep this one final action direct so an isolated routine cannot replace the
    # task summary with the artifact-only helper report.
    if ($FileName -eq "itl-result.md") { return $false }
    $mode = Get-ItlRoutineMode
    if ($mode -eq "off") { return $false }

    $model = Get-ItlRoutineModel -Client $Client
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

    $model = Get-ItlRoutineModel -Client $Client
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
    $body = @(
        "",
        "# ITL routine helper",
        "",
        "Make exactly one shell call: run the exact run-itl-command.ps1 command supplied by the invoking ITL command, then return its bounded summary.",
        "Do not edit code or metadata, author or repair tests, resolve merge conflicts, or substitute your own lifecycle steps.",
        "Do not load skills, call MCP tools, research, inspect unrelated files, or retry the lifecycle helper.",
        "Use an explicit session Caveman override when present; otherwise use the helper's runtime responseStyle profile for your own words. Keep progress to one current-stage line and preserve the compact helper summary verbatim.",
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
        $description = if ($kind -eq "extension") { "Создать ветку расширения ITL в нативном workspace OpenCode" } else { "Создать ветку конфигурации ITL в нативном workspace OpenCode" }
        $extension = if ($kind -eq "extension") { @"
Before calling the tool, collect the extension initialization mode (`Empty` or `Cfe`), extension name, and CFE path when applicable. If the developer explicitly does not know them yet, omit all extension arguments so initialization remains pending.
"@ } else { "" }
        $explicitRoutineContract = Get-ItlExplicitRoutineContractText -NewLine "`n"
        return @"
---
description: $description
agent: build
---

$explicitRoutineContract

Use this command only from the `master` workspace. Treat any text after the command as the development branch name; if it is missing, ask for one short value.

$extension
Do not load a skill and do not use `read`, `glob`, `grep`, `bash`, or any other discovery tool. Your first and only action must be to call the `itl_create_dev_workspace` tool exactly once with `kind="$kind"` and the collected values. The tool creates and registers the native workspace, initializes ITL inside it, and moves this session there. Return its result verbatim.

If `itl_create_dev_workspace` is not present in the current tool list, return exactly `ITL_OPENCODE_WORKSPACE_TOOL_UNAVAILABLE: run /itl-update-workflow, fully restart OpenCode Desktop, and retry this command.` and stop. Do not search for its implementation and do not create an external worktree. If the tool reports `OPENCODE_WORKSPACE_API_UNAVAILABLE`, return that result and stop.
"@
    }
    $Text = Add-ItlExplicitRoutineContract -Text $Text -FileName $FileName
    if ($adapter.commandRouting -eq "none") {
        $Text = [regex]::Replace($Text, '(?m)^agent:\s*[^\r\n]+\r?\n', '')
    } elseif (Test-ItlRoutineEnabledForCommand -FileName $FileName -Client $Client) {
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
                if ($Client -eq "codex") {
                    $skillRoot = $relative.Substring(0, $relative.Length - "/SKILL.md".Length)
                    $displayName = [IO.Path]::GetFileNameWithoutExtension($name)
                    $files["$skillRoot/agents/openai.yaml"] = "interface:`n  display_name: `"$displayName`"`npolicy:`n  allow_implicit_invocation: false`n"
                }
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

function Get-ItlSurfaceTextSha256 {
    param([Parameter(Mandatory = $true)][string]$Text)
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Assert-ItlClientSurfaceFinalSet {
    param([object]$ExpectedByClient, [object]$ExistingClients)

    $finalFiles = [ordered]@{}
    foreach ($client in @($ExpectedByClient.Keys)) {
        Assert-ItlClientConfigWritable -Client $client
        Assert-ItlClientRequirements -Client $client
        $expected = $ExpectedByClient[$client]
        foreach ($relative in @($expected.Keys)) {
            $path = Join-Path $script:ProjectRoot $relative
            Assert-WorkflowManagedTargetPath -Path $path
            $hash = Get-ItlSurfaceTextSha256 -Text ([string]$expected[$relative])
            if ($finalFiles.Contains($relative)) {
                if ([string]$finalFiles[$relative].hash -cne $hash) {
                    throw "ITL_SURFACE_OWNER_CONFLICT: '$relative' renders differently for the desired clients. No surface was changed."
                }
                $finalFiles[$relative].owners += $client
            } else {
                $finalFiles[$relative] = [pscustomobject]@{ hash = $hash; owners = @($client) }
            }
        }
    }

    $oldHashes = [ordered]@{}
    foreach ($client in @($ExistingClients.Keys)) {
        $entry = ConvertTo-Vibecoding1cMcpHashtable -Object $ExistingClients[$client]
        $files = if ($entry.Contains('files')) { ConvertTo-Vibecoding1cMcpHashtable -Object $entry['files'] } else { [ordered]@{} }
        foreach ($relative in @($files.Keys)) {
            $path = Join-Path $script:ProjectRoot $relative
            Assert-WorkflowManagedTargetPath -Path $path
            if ($oldHashes.Contains($relative) -and [string]$oldHashes[$relative] -cne [string]$files[$relative]) {
                throw "ITL_SURFACE_OWNER_STATE_INVALID: '$relative' has different recorded hashes for attached clients."
            }
            $oldHashes[$relative] = [string]$files[$relative]
        }
    }
    foreach ($relative in @($oldHashes.Keys)) {
        $path = Join-Path $script:ProjectRoot $relative
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $actual = Get-ItlFileSha256 -Path $path
        if ($actual -cne [string]$oldHashes[$relative] -and
            -not ($relative -match '(?i)(^|/)itl-routine\.md$' -and -not $finalFiles.Contains($relative))) {
            throw "ITL_SURFACE_USER_MODIFIED: managed file '$relative' differs from its recorded hash. Preserve or reconcile it explicitly before update/client switch."
        }
    }
    foreach ($relative in @($finalFiles.Keys)) {
        if ($oldHashes.Contains($relative)) { continue }
        $path = Join-Path $script:ProjectRoot $relative
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $actual = Get-ItlFileSha256 -Path $path
        $legacyKilo = @($finalFiles[$relative].owners | Where-Object {
            $adapter = Get-ItlClientAdapter -Client $_
            $adapter.PSObject.Properties.Name -contains 'legacyKiloCommands' -and $adapter.legacyKiloCommands
        }).Count -gt 0
        if ($actual -cne [string]$finalFiles[$relative].hash -and -not ($legacyKilo -and (Test-ItlKnownLegacyKiloCommandHash -Hash $actual))) {
            throw "ITL_SURFACE_COLLISION: '$relative' exists but is not a hash-matching managed or legacy ITL asset."
        }
    }
    foreach ($client in @($ExpectedByClient.Keys)) {
        $adapter = Get-ItlClientAdapter -Client $client
        if (-not $adapter.commandsPath) { continue }
        $commandDir = Join-Path $script:ProjectRoot $adapter.commandsPath
        foreach ($file in @(Get-ChildItem -LiteralPath $commandDir -File -Filter 'itl*.md' -ErrorAction SilentlyContinue)) {
            $relative = $adapter.commandsPath.TrimEnd('/') + '/' + $file.Name
            if ($ExpectedByClient[$client].Contains($relative)) { continue }
            $hash = Get-ItlFileSha256 -Path $file.FullName
            if ($oldHashes.Contains($relative) -and [string]$oldHashes[$relative] -ceq $hash) { continue }
            $legacyKilo = $adapter.PSObject.Properties.Name -contains 'legacyKiloCommands' -and $adapter.legacyKiloCommands
            if (-not ($legacyKilo -and (Test-ItlKnownLegacyKiloCommandHash -Hash $hash))) {
                throw "ITL_SURFACE_COLLISION: unexpected '$relative' is not a hash-matching managed or legacy ITL asset."
            }
        }
    }
    return $finalFiles
}

function Sync-ItlManagedSurfaceFiles {
    param([string]$Client, [object]$ExpectedFiles)

    $state = Read-ItlClientSurfaceState
    $clients = ConvertTo-Vibecoding1cMcpHashtable -Object $state["clients"]
    $adapter = Get-ItlClientAdapter -Client $Client
    $activeEntry = if ($clients.Contains($Client)) { ConvertTo-Vibecoding1cMcpHashtable -Object $clients[$Client] } else { [ordered]@{} }
    $previous = if ($activeEntry.Contains("files")) { ConvertTo-Vibecoding1cMcpHashtable -Object $activeEntry["files"] } else { [ordered]@{} }
    # A shared surface path is legal only when every attached client's rendered
    # bytes are identical. Check before any file replacement.
    foreach ($relative in @($ExpectedFiles.Keys)) {
        $expectedBytes = [System.Text.UTF8Encoding]::new($false).GetBytes([string]$ExpectedFiles[$relative])
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { $expectedHash = ([BitConverter]::ToString($sha.ComputeHash($expectedBytes))).Replace("-", "").ToLowerInvariant() }
        finally { $sha.Dispose() }
        foreach ($otherClient in @($clients.Keys | Where-Object { $_ -ne $Client })) {
            $otherEntry = ConvertTo-Vibecoding1cMcpHashtable -Object $clients[$otherClient]
            $otherFiles = if ($otherEntry.Contains('files')) { ConvertTo-Vibecoding1cMcpHashtable -Object $otherEntry['files'] } else { [ordered]@{} }
            if ($otherFiles.Contains($relative) -and [string]$otherFiles[$relative] -cne $expectedHash) {
                throw "ITL_SURFACE_OWNER_CONFLICT: '$relative' has different renders for '$Client' and '$otherClient'. No shared file was replaced."
            }
        }
    }
    foreach ($relative in @($previous.Keys)) {
        $path = Join-Path $script:ProjectRoot $relative
        if (-not $ExpectedFiles.Contains($relative) -and $relative -match '(?i)(^|/)itl-routine\.md$' -and (Test-Path -LiteralPath $path -PathType Leaf) -and (Get-ItlFileSha256 -Path $path) -ne [string]$previous[$relative]) {
            Write-Warning "Preserving user-modified inactive routine agent: $relative"
            continue
        }
        Assert-ItlManagedSurfaceFileUnmodified -RelativePath $relative -ExpectedHash ([string]$previous[$relative])
        if (-not $ExpectedFiles.Contains($relative)) {
            $otherOwners = @($clients.Keys | Where-Object {
                if ($_ -eq $Client) { return $false }
                $otherEntry = ConvertTo-Vibecoding1cMcpHashtable -Object $clients[$_]
                $otherFiles = if ($otherEntry.Contains('files')) { ConvertTo-Vibecoding1cMcpHashtable -Object $otherEntry['files'] } else { [ordered]@{} }
                return $otherFiles.Contains($relative)
            })
            if ($otherOwners.Count -eq 0 -and (Test-Path -LiteralPath $path -PathType Leaf)) { Remove-Item -LiteralPath $path -Force }
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

function Remove-ItlClientSurface {
    param([Parameter(Mandatory = $true)][string]$Client)

    $state = Read-ItlClientSurfaceState
    $clients = ConvertTo-Vibecoding1cMcpHashtable -Object $state['clients']
    if (-not $clients.Contains($Client)) { return }
    $entry = ConvertTo-Vibecoding1cMcpHashtable -Object $clients[$Client]
    $files = if ($entry.Contains('files')) { ConvertTo-Vibecoding1cMcpHashtable -Object $entry['files'] } else { [ordered]@{} }
    foreach ($relative in @($files.Keys)) {
        $path = Join-Path $script:ProjectRoot $relative
        $otherOwners = @($clients.Keys | Where-Object {
            if ($_ -eq $Client) { return $false }
            $otherEntry = ConvertTo-Vibecoding1cMcpHashtable -Object $clients[$_]
            $otherFiles = if ($otherEntry.Contains('files')) { ConvertTo-Vibecoding1cMcpHashtable -Object $otherEntry['files'] } else { [ordered]@{} }
            return $otherFiles.Contains($relative)
        })
        if ($relative -match '(?i)(^|/)itl-routine\.md$' -and (Test-Path -LiteralPath $path -PathType Leaf) -and (Get-ItlFileSha256 -Path $path) -ne [string]$files[$relative]) {
            Write-Warning "Preserving user-modified inactive routine agent: $relative"
            continue
        }
        Assert-ItlManagedSurfaceFileUnmodified -RelativePath $relative -ExpectedHash ([string]$files[$relative])
        if ($otherOwners.Count -eq 0 -and (Test-Path -LiteralPath $path -PathType Leaf)) { Remove-Item -LiteralPath $path -Force }
    }
    $clients.Remove($Client)
    $state['clients'] = $clients
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
    $sdkPackageName = [string]$adapter.workspacePluginSdkPackageName
    $sdkVersion = [string](Get-ConfigValueFromObject -Object $locked -Path "sdk.version" -Default "")
    $sdkSource = [string](Get-ConfigValueFromObject -Object $locked -Path "sdk.source" -Default "")
    $sdkIntegrity = [string](Get-ConfigValueFromObject -Object $locked -Path "sdk.integrity" -Default "")
    $expectedSource = "npm:$([string]$adapter.workspacePluginPackageName)@$version"
    $expectedSdkSource = "npm:$sdkPackageName@$sdkVersion"
    if (-not $version -or $source -ne $expectedSource -or -not $integrity -or
        -not $sdkPackageName -or -not $sdkVersion -or $sdkSource -ne $expectedSdkSource -or -not $sdkIntegrity) {
        throw "OPENCODE_PLUGIN_RUNTIME_LOCK_MISMATCH: workflow registry and dependency-lock.json disagree about the OpenCode plugin runtime."
    }
    return [pscustomobject]@{
        client = $Client
        runtimeRoot = Join-Path $script:ProjectRoot ([string]$adapter.workspacePluginRuntimePath)
        packageName = [string]$adapter.workspacePluginPackageName
        version = $version
        source = $source
        integrity = $integrity
        sdkPackageName = $sdkPackageName
        sdkVersion = $sdkVersion
        sdkSource = $sdkSource
        sdkIntegrity = $sdkIntegrity
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
    $installedSdkManifestPath = Join-Path $contract.runtimeRoot "node_modules\@opencode-ai\sdk\package.json"
    $packageLockPath = Join-Path $contract.runtimeRoot "package-lock.json"
    if (-not (Test-Path -LiteralPath $packageManifestPath -PathType Leaf)) {
        return [pscustomobject]@{ required = $true; ready = $false; detail = "package manifest missing: $packageManifestPath" }
    }
    if (-not (Test-Path -LiteralPath $installedManifestPath -PathType Leaf)) {
        return [pscustomobject]@{ required = $true; ready = $false; detail = "installed package missing: $installedManifestPath" }
    }
    if (-not (Test-Path -LiteralPath $installedSdkManifestPath -PathType Leaf)) {
        return [pscustomobject]@{ required = $true; ready = $false; detail = "installed SDK package missing: $installedSdkManifestPath" }
    }
    if (-not (Test-Path -LiteralPath $packageLockPath -PathType Leaf)) {
        return [pscustomobject]@{ required = $true; ready = $false; detail = "package lock missing: $packageLockPath" }
    }
    try {
        $packageManifest = Read-Utf8Text -Path $packageManifestPath | ConvertFrom-Json
        $installedManifest = Read-Utf8Text -Path $installedManifestPath | ConvertFrom-Json
        $installedSdkManifest = Read-Utf8Text -Path $installedSdkManifestPath | ConvertFrom-Json
        # Windows PowerShell 5 ConvertFrom-Json rejects npm lockfile v3's required packages[""] root entry.
        $packageLockText = (Read-Utf8Text -Path $packageLockPath).Replace('"":', '"_itl_root":')
        $packageLock = $packageLockText | ConvertFrom-Json
    } catch {
        return [pscustomobject]@{ required = $true; ready = $false; detail = "runtime package metadata is invalid JSON: $($_.Exception.Message)" }
    }
    $declared = [string](Get-ConfigValueFromObject -Object $packageManifest -Path "dependencies.$($contract.packageName)" -Default "")
    $declaredSdk = [string](Get-ConfigValueFromObject -Object $packageManifest -Path "dependencies.$($contract.sdkPackageName)" -Default "")
    $installed = [string](Get-ConfigValueFromObject -Object $installedManifest -Path "version" -Default "")
    $installedSdk = [string](Get-ConfigValueFromObject -Object $installedSdkManifest -Path "version" -Default "")
    $lockedPackage = Get-ConfigValueFromObject -Object $packageLock -Path "packages.node_modules/@opencode-ai/plugin" -Default $null
    $lockedSdkPackage = Get-ConfigValueFromObject -Object $packageLock -Path "packages.node_modules/@opencode-ai/sdk" -Default $null
    $lockVersion = [string](Get-ConfigValueFromObject -Object $lockedPackage -Path "version" -Default "")
    $lockIntegrity = [string](Get-ConfigValueFromObject -Object $lockedPackage -Path "integrity" -Default "")
    $sdkLockVersion = [string](Get-ConfigValueFromObject -Object $lockedSdkPackage -Path "version" -Default "")
    $sdkLockIntegrity = [string](Get-ConfigValueFromObject -Object $lockedSdkPackage -Path "integrity" -Default "")
    $ready = $declared -eq $contract.version -and $installed -eq $contract.version -and
        $lockVersion -eq $contract.version -and $lockIntegrity -eq $contract.integrity -and
        $declaredSdk -eq $contract.sdkVersion -and $installedSdk -eq $contract.sdkVersion -and
        $sdkLockVersion -eq $contract.sdkVersion -and $sdkLockIntegrity -eq $contract.sdkIntegrity
    return [pscustomobject]@{
        required = $true
        ready = $ready
        detail = "plugin expected=$($contract.version); declared=$(if ($declared) { $declared } else { '<missing>' }); installed=$(if ($installed) { $installed } else { '<missing>' }); lock=$(if ($lockVersion) { $lockVersion } else { '<missing>' }); integrity=$(if ($lockIntegrity -eq $contract.integrity) { 'matched' } else { 'mismatch' }); sdk expected=$($contract.sdkVersion); declared=$(if ($declaredSdk) { $declaredSdk } else { '<missing>' }); installed=$(if ($installedSdk) { $installedSdk } else { '<missing>' }); lock=$(if ($sdkLockVersion) { $sdkLockVersion } else { '<missing>' }); integrity=$(if ($sdkLockIntegrity -eq $contract.sdkIntegrity) { 'matched' } else { 'mismatch' })"
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
    $manifest["dependencies"][$Contract.sdkPackageName] = $Contract.sdkVersion
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
    param([string]$SourceRoot = $script:ProjectRoot, [string]$Client = "", [AllowNull()][object]$ExpectedFiles = $null, [switch]$SkipMcpSync)

    if ($null -eq (Get-AiRules1cProjectManifest)) {
        Write-Host "Skipping ITL client surface generation because ai_rules_1c is not installed."
        return
    }
    $client = Get-ItlActiveClient -Client $Client
    Assert-ItlClientConfigWritable -Client $client
    Assert-ItlClientRequirements -Client $client
    $adapter = Get-ItlClientAdapter -Client $client
    $expectedFiles = if ($null -ne $ExpectedFiles) { $ExpectedFiles } else { Get-ItlExpectedSurfaceFiles -Client $client -SourceRoot $SourceRoot }
    Sync-ItlManagedSurfaceFiles -Client $client -ExpectedFiles $expectedFiles
    if ((Get-FullPathNormalized $SourceRoot) -eq (Get-FullPathNormalized $script:ProjectRoot)) {
        Sync-ItlOpenCodePluginRuntime -Client $client
    }
    if ($adapter.PSObject.Properties.Name -contains "disableSnapshots" -and $adapter.disableSnapshots) {
        Set-KiloSnapshotsDisabled
    }
    Sync-ItlClientRequiredPackage -Client $client
    if (-not $SkipMcpSync) {
        Write-ItlOnDemandMcpClientConfig -Client $client | Out-Null
        Sync-ItlUiToolsMcp -Client $client
    }
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

function Sync-ItlClientSurfaces {
    param([string]$SourceRoot = $script:ProjectRoot)

    $desired = @(Get-AgentTargets)
    $expectedByClient = [ordered]@{}
    foreach ($client in $desired) {
        $expectedByClient[$client] = Get-ItlExpectedSurfaceFiles -Client $client -SourceRoot $SourceRoot
    }
    $state = Read-ItlClientSurfaceState
    $existing = ConvertTo-Vibecoding1cMcpHashtable -Object $state['clients']
    [void](Assert-ItlClientSurfaceFinalSet -ExpectedByClient $expectedByClient -ExistingClients $existing)
    $mcpRequests = @()
    if ($null -ne (Get-AiRules1cProjectManifest)) {
        foreach ($client in $desired) {
            $facade = Write-ItlOnDemandMcpClientConfig -Client $client -PlanOnly
            if ($null -ne $facade) { $mcpRequests += $facade }
            $ui = Sync-ItlUiToolsMcp -Client $client -PlanOnly
            if ($null -ne $ui) { $mcpRequests += $ui }
        }
        if ($mcpRequests.Count -gt 0) { Write-ItlClientMcpEndpointSet -Requests $mcpRequests | Out-Null }
    }
    foreach ($stale in @($existing.Keys | Where-Object { $_ -notin $desired })) {
        Remove-ItlClientSurface -Client ([string]$stale)
    }
    foreach ($client in $desired) {
        Sync-ItlClientSurface -SourceRoot $SourceRoot -Client $client -ExpectedFiles $expectedByClient[$client] -SkipMcpSync
    }
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

function Sync-ItlClientMcpConfig {
    param([string]$Client)

    $normalized = @(ConvertTo-AgentToolList -Value $Client)
    if ($normalized.Count -ne 1 -or $normalized[0] -notin (Get-SupportedAgentTargets)) {
        throw "sync-client-mcp requires exactly one explicit -Client: $((Get-SupportedAgentTargets) -join ', ')."
    }
    $target = [string]$normalized[0]
    Assert-ItlClientConfigWritable -Client $target
    $active = Get-ItlActiveClient
    $adapter = Get-ItlClientAdapter -Client $target

    Write-Section "Sync ITL MCP config for $target"
    Write-Vibecoding1cMcpClientConfig -Client $target -IncludeClientSurfaces

    $path = Join-Path $script:ProjectRoot $adapter.mcpPath
    Write-Host "Synced managed ITL MCP families (vibecoding1c, on-demand facades, UI tools) for $target : $path"
    Write-Host "Active client is unchanged: $active. ai_rules_1c, skills, and generated command surfaces were not modified."
    $reload = [string](Get-StateValue -State $adapter -Name "mcpReloadUserReport" -Default "")
    if (-not $reload) {
        $reload = [string](Get-StateValue -State $adapter -Name "reloadUserReport" -Default "")
    }
    if ($reload) {
        Write-Host $reload
    }
    $enablement = [string](Get-StateValue -State $adapter -Name "mcpEnablementUserInstruction" -Default "")
    if ($enablement) {
        Write-Host $enablement
    }
    Write-Host "Writing the client MCP config does not attach servers to an already open chat. Reload the client, enable ITL servers if it has MCP Server switches, then open a new chat."
}

function Test-ItlMcpFailurePreservesCurrentState {
    param([string]$Message)
    return $Message -match 'CLIENT_MCP_(?:USER_COLLISION|OWNER_CONFLICT|FINAL_SET_|PATH_NOT_FILE|OWNER_STATE_INVALID)|MIMOCODE_CONFIG_COLLISION'
}

function Get-ItlMcpMigrationPreservePaths {
    # A detach may already have removed its client from project.json. Protect
    # all adapter config paths, including that client's late edit and receipts.
    return @(
        @((Get-ItlClientAdapterRegistry).Values | ForEach-Object { Join-Path $script:ProjectRoot $_.mcpPath }) +
        @(Get-ItlManagedMcpStatePath)
    ) | Select-Object -Unique
}

function Switch-ItlClient {
    param([string]$Client, [ValidateSet('status','switch','attach','detach','reconcile')][string]$Mode = 'switch')

    if ($Mode -eq 'status') {
        $configured = @(Get-AgentTargets)
        Write-Host "Attached ITL clients: $(if ($configured.Count) { $configured -join ', ' } else { '<none>' })."
        Write-Host 'Use -Mode attach/detach to change the project set; pass -AgentTarget for a client-specific invocation.'
        return
    }
    if ($Mode -eq 'switch') {
        $sessionClient = Get-ItlActiveClient -Client $Client
        Write-Host "Selected ITL client for this invocation: $sessionClient. Project client membership was not changed. Pass -AgentTarget $sessionClient on later client-specific helper calls when the executor cannot be identified automatically."
        return
    }

    Assert-MasterWorktreeContext -Operation "itl-switch-client"
    Assert-WorkflowTrackedGitClean
    if ($Mode -eq 'reconcile') {
        $desiredClients = @(Get-AgentTargets)
        Update-AiRules1c
        Sync-ItlClientSurfaces
        Write-Host "Reconciled installed ITL client surfaces to aiRules.tools: [$($desiredClients -join ', ')]."
        return
    }
    $normalized = @(ConvertTo-AgentToolList -Value $Client)
    if ($normalized.Count -ne 1 -or $normalized[0] -notin (Get-SupportedAgentTargets)) {
        throw "itl-switch-client requires exactly one client: $((Get-SupportedAgentTargets) -join ', ')."
    }
    $selectedClient = [string]$normalized[0]
    Assert-ItlClientConfigWritable -Client $selectedClient
    if (Test-AiRulesManifestHasUserChanges) {
        throw "itl-switch-client is blocked because ai_rules_1c manifest contains userModified files."
    }
    $current = @(Get-AgentTargets)
    $desired = @(switch ($Mode) {
        'attach' { @($current + $selectedClient | Select-Object -Unique) }
        'detach' { @($current | Where-Object { $_ -ne $selectedClient }) }
    })
    if ($Mode -eq 'detach' -and $selectedClient -notin $current) {
        throw "ITL_CLIENT_NOT_ATTACHED: '$selectedClient' is not in aiRules.tools."
    }
    if (@(Compare-Object -ReferenceObject @($current | Sort-Object) -DifferenceObject @($desired | Sort-Object)).Count -eq 0) {
        Sync-ItlClientSurfaces
        Write-Host "ITL client set already matches: [$($desired -join ', ')]."
        return
    }
    $toDetach = @($current | Where-Object { $_ -notin $desired })

    $snapshot = New-AiRulesMigrationSnapshot
    try {
        Initialize-ItlClientModelTiers | Out-Null
        foreach ($oldClient in $toDetach) {
            $mcpState = Read-ItlManagedMcpState
            $owners = ConvertTo-Vibecoding1cMcpHashtable -Object $mcpState['owners']
            foreach ($ownerKey in @($owners.Keys | Where-Object { $_.StartsWith("$oldClient/", [StringComparison]::OrdinalIgnoreCase) })) {
                $owner = $ownerKey.Substring($oldClient.Length + 1)
                Write-ItlClientMcpEndpoints -Endpoints @() -Owner $owner -Client $oldClient | Out-Null
            }
            Sync-ItlClientRequiredPackage -Client $oldClient -Remove
        }
        Set-ProjectAiRulesClients -Clients $desired
        Read-ProjectConfig
        Update-AiRules1c
        Sync-ItlClientSurfaces
        foreach ($newClient in @($desired | Where-Object { $_ -notin $current })) {
            Sync-ItlClientUserEnvironment -Client $newClient
        }
        Write-Host "ITL client set reconciled: [$($current -join ', ')] -> [$($desired -join ', ')]."
        Write-Host "Other worktrees were not changed; run /itl-update-workflow from master to reconcile them when the project package supports worktree rollout."
        Write-Host "RTK integration was preserved and must be reconciled explicitly if the client changed."
        Write-Host ((Get-ItlClientAdapter -Client $selectedClient).reload)
    } catch {
        $failure = $_.Exception.Message
        $preserveMcp = Test-ItlMcpFailurePreservesCurrentState -Message $failure
        if ($preserveMcp) {
            Restore-AiRulesMigrationSnapshot -Snapshot $snapshot -PreservePaths (Get-ItlMcpMigrationPreservePaths)
        } else {
            Restore-AiRulesMigrationSnapshot -Snapshot $snapshot
        }
        $preservation = if ($preserveMcp) { ' Current MCP files and ownership receipts were preserved; review the reported edit/conflict and repeat the original attach/detach command.' } else { '' }
        throw "itl-switch-client failed and the project snapshot was restored from $($snapshot.root): $failure$preservation"
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
    try {
        $ruleConflicts = @(Get-ItlManagedRuleOverrideConflicts)
        if ($ruleConflicts.Count -eq 0) {
            $checks.Add([pscustomobject]@{ status = 'OK'; name = 'user-rule-overrides'; detail = 'no known legacy directive conflict detected; semantic review still applies' })
        } else {
            foreach ($conflict in $ruleConflicts) {
                $checks.Add([pscustomobject]@{
                    status = 'WARN'
                    name = 'user-rule-overrides'
                    detail = "$($conflict.path):$($conflict.line): $($conflict.policy); dependent=$($conflict.dependentOperation); preserve user text and reconcile before that operation; text=$($conflict.text)"
                })
            }
        }
    } catch {
        $checks.Add([pscustomobject]@{ status = 'WARN'; name = 'user-rule-overrides'; detail = "could not inspect overrides: $($_.Exception.Message)" })
    }
    $configuredClients = @(Get-AgentTargets)
    $checks.Add([pscustomobject]@{
        status = $(if ($configuredClients.Count -gt 0) { 'OK' } else { 'WARN' })
        name = 'configured-clients'
        detail = $(if ($configuredClients.Count -gt 0) { "aiRules.tools=[$($configuredClients -join ', ')]; session client is selected independently" } else { 'aiRules.tools is empty; attach a supported client before client-specific operations' })
    })
    foreach ($configuredClient in $configuredClients) {
        try {
            $configuredAdapter = Get-ItlClientAdapter -Client $configuredClient
            $capabilities = Get-ItlClientCapabilityReport -Client $configuredClient
            Assert-ItlClientConfigWritable -Client $configuredClient
            $observation = Get-ItlClientMcpEnablementObservation -Client $configuredClient
            $clientOpenSpec = Get-AiRules1cOpenSpecStatus -Client $configuredClient
            $missing = @($observation.missingManagedServerIds)
            $checks.Add([pscustomobject]@{
                status = 'WARN'
                name = "client-capability:$configuredClient"
                detail = "variant=$($capabilities.runtimeVariant); $($capabilities.mcp); configuredServers=$($observation.configuredCount); managedCoverage=$($observation.configuredManagedCount)/$($observation.expectedManagedCount); missing=[$($missing -join ', ')]; roles=$($capabilities.roles); model=$($capabilities.model); OpenSpec=$($clientOpenSpec.mode); cliPin=$($clientOpenSpec.cliVersion); store=$($clientOpenSpec.storeSource):$($clientOpenSpec.storeRoot); native=$($capabilities.nativeCommand); providerCallability=unverified; $($capabilities.evidence)"
            })
        } catch {
            $checks.Add([pscustomobject]@{ status = 'WARN'; name = "client-capability:$configuredClient"; detail = "inspection unavailable: $($_.Exception.Message); runtime callability remains unverified" })
        }
    }
    $client = ""
    $adapter = $null
    try {
        $client = Get-ItlActiveClient
        $adapter = Get-ItlClientAdapter -Client $client
        Assert-ItlClientConfigWritable -Client $client
        Assert-ItlClientRequirements -Client $client
        Assert-ItlClientRequiredPackageConfigured -Client $client
        $checks.Add([pscustomobject]@{ status = "OK"; name = "active-client"; detail = "$client; rules=$($adapter.rulesPath); agents=$($adapter.agentsPath); commands=$(if ($adapter.commandsPath) { $adapter.commandsPath } else { '<skills/natural requests>' }); skills=$($adapter.skillsPath); mcp=$($adapter.mcpPath)" })
    } catch {
        $sessionError = $_.Exception.Message
        if ($sessionError -match '^ITL_CLIENT_(NOT_ATTACHED|AMBIGUOUS):') {
            $checks.Add([pscustomobject]@{ status = "WARN"; name = "active-client"; detail = "$sessionError General diagnosis continues without attaching a client." })
            if ($configuredClients.Count -eq 1) {
                $client = [string]$configuredClients[0]
                $adapter = Get-ItlClientAdapter -Client $client
                $checks.Add([pscustomobject]@{ status = "OK"; name = "diagnostic-client"; detail = "inspecting configured '$client' read-only; session client remains unchanged" })
            }
        } else {
            $checks.Add([pscustomobject]@{ status = "FAIL"; name = "active-client"; detail = $sessionError })
        }
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
        $checks.Add([pscustomobject]@{ status = 'SKIP'; name = 'plugin-project-version'; detail = "projectRulesCommit=$commit; pluginHostVersion=unobserved; optional plugin installation and project rules are independent; inspect the client host if plugin version matters" })
    } catch {
        $checks.Add([pscustomobject]@{ status = "FAIL"; name = "ai-rules-provenance"; detail = $_.Exception.Message })
    }
    $itlSkills = @("1c-workflow", "1c-workflow-fast", "product-docs", "itl-roctup-1c-data", "itl-vanessa-ui-mcp", "itl-remote-runner", "itl-remote-agent", "itl-performance")
    $missingSkills = @($itlSkills | Where-Object { -not (Test-Path -LiteralPath (Join-Path $script:ProjectRoot ".agents\skills\$_\SKILL.md") -PathType Leaf) })
    $checks.Add([pscustomobject]@{ status = $(if ($missingSkills.Count -eq 0) { "OK" } else { "FAIL" }); name = "itl-skills"; detail = $(if ($missingSkills.Count -eq 0) { "all managed skills installed" } else { "missing: $($missingSkills -join ', ')" }) })
    if ($client -eq "kilocode") {
        try {
            $provenance = Get-KiloFastSkillProvenance
            $checks.Add([pscustomobject]@{
                status = "OK"
                name = "kilo-skill-provenance"
                detail = "expected=$($provenance.path); contract=$($provenance.contract); sha256=$($provenance.sha256); loaded-cache-hash=not-observable; reload-only-on-observed-mismatch"
            })
        } catch {
            $checks.Add([pscustomobject]@{ status = "FAIL"; name = "kilo-skill-provenance"; detail = $_.Exception.Message })
        }
    }
    $openSpec = Get-AiRules1cOpenSpecStatus -Client $client
    $openSpecDetail = if ($openSpec.isAvailable) {
        "mode=$($openSpec.mode); cliVersion=$($openSpec.cliVersion); cli=$(if ($openSpec.cliAvailable) { $openSpec.cliPath } else { '<not-detected>' }); store=$($openSpec.storeSource):$($openSpec.storeRoot); invocation=unverified$(if ($openSpec.reason) { "; $($openSpec.reason)" } else { '' })"
    } else {
        "mode=unavailable; $($openSpec.reason)"
    }
    $checks.Add([pscustomobject]@{ status = $(if ($openSpec.isAvailable) { "OK" } else { "WARN" }); name = "openspec"; detail = $openSpecDetail })
    $devEnvPath = Join-Path $script:ProjectRoot ".dev.env"
    $checks.Add([pscustomobject]@{ status = $(if (Test-Path -LiteralPath $devEnvPath -PathType Leaf) { "OK" } else { "FAIL" }); name = "dev-env"; detail = $(if (Test-Path -LiteralPath $devEnvPath -PathType Leaf) { "present; values inspected without mutation" } else { "missing" }) })
    foreach ($component in @("yaxunit", "vanessa", "event-log")) {
        $mode = Get-ItlVerificationMode -Component $component
        $checks.Add([pscustomobject]@{ status = $(if ($mode.valid) { "OK" } else { "WARN" }); name = $mode.key; detail = "raw=$(if ($mode.raw) { $mode.raw } else { '<missing>' }); effective=$($mode.effective)$(if (-not $mode.valid) { '; execution skipped until set to auto, manual, or off' } else { '' })" })
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
        if (-not $facadeVersion) {
            $checks.Add([pscustomobject]@{ status = "SKIP"; name = "ondemand-mcp"; detail = "version=<legacy project>; facade=<not managed>" })
        } else {
            $facadePath = Get-ItlOnDemandMcpExecutablePath -AllowMissing
            $instances = @(Get-ItlOnDemandRuntimeInstances)
            $stale = @($instances | Where-Object { -not (Test-ItlOnDemandOwnedProcess -RuntimeState $_) }).Count
            $facadeReady = Test-Path -LiteralPath $facadePath -PathType Leaf
            $checks.Add([pscustomobject]@{
                status = $(if ($facadeReady -and $stale -eq 0) { "OK" } elseif ($facadeReady) { "WARN" } else { "FAIL" })
                name = "ondemand-mcp"
                detail = "version=$facadeVersion; facade=$facadePath; instances=$($instances.Count); stale=$stale"
            })
        }
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
    if ($client) {
        foreach ($uiTool in @("agent-browser", "windows-mcp")) {
            try {
                $ui = Get-ItlUiToolStatus -Tool $uiTool -Client $client
                $uiCheck = if ($ui.state -eq "configured") { "OK" } elseif ($ui.state -eq "external") { "SKIP" } else { "WARN" }
                $checks.Add([pscustomobject]@{ status = $uiCheck; name = $uiTool; detail = "installed=$(if ($ui.installedVersion) { $ui.installedVersion } else { '<none>' }); expected=$($ui.expectedVersion); state=$($ui.state); configured does not prove active; install=$($ui.installCommand)" })
            } catch {
                $checks.Add([pscustomobject]@{ status = "WARN"; name = $uiTool; detail = $_.Exception.Message })
            }
        }
    }
    foreach ($check in $checks) { Write-Host ("[{0}] {1}: {2}" -f $check.status, $check.name, $check.detail) }
    Write-Host "Doctor is read-only. Follow the named recovery action; ITL workflow state uses /itl-update-workflow or /itl-refresh."
    if (@($checks | Where-Object { $_.status -eq "FAIL" }).Count -gt 0) { throw "ITL doctor found failed checks." }
}

function Sync-KiloItlCommandSurface {
    param([string]$SourceRoot = $script:ProjectRoot)
    Sync-ItlClientSurfaces -SourceRoot $SourceRoot
}
