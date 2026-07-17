function Get-ItlClientAdapterRegistry {
    return [ordered]@{
        codex = [ordered]@{
            id = "codex"
            rulesPath = ".codex/rules"
            agentsPath = ".codex/agents"
            commandsPath = ""
            skillsPath = ".agents/skills"
            mcpPath = ".codex/config.toml"
            reload = "Start a new Codex task so project rules and skills are reread."
        }
        kilocode = [ordered]@{
            id = "kilocode"
            rulesPath = ".kilo/rules-1c"
            agentsPath = ".kilo/agents"
            commandsPath = ".kilo/commands"
            skillsPath = ".kilo/skills"
            mcpPath = ".kilo/kilo.json"
            reload = "Run /reload or restart Kilo Code."
        }
        "claude-code" = [ordered]@{
            id = "claude-code"
            rulesPath = ".claude/rules"
            agentsPath = ".claude/agents"
            commandsPath = ".claude/commands"
            skillsPath = ".claude/skills"
            mcpPath = ".mcp.json"
            reload = "Restart Claude Code."
        }
        cursor = [ordered]@{
            id = "cursor"
            rulesPath = ".cursor/rules"
            agentsPath = ".cursor/agents"
            commandsPath = ".cursor/commands"
            skillsPath = ".cursor/skills"
            mcpPath = ".cursor/mcp.json"
            reload = "Reload the Cursor window."
        }
        opencode = [ordered]@{
            id = "opencode"
            rulesPath = ".opencode/rules"
            agentsPath = ".opencode/agent"
            commandsPath = ".opencode/command"
            skillsPath = ".claude/skills"
            mcpPath = "opencode.json"
            reload = "Restart OpenCode."
        }
    }
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

    if ($Client -eq "kilocode") {
        $json = Join-Path $script:ProjectRoot ".kilo\kilo.json"
        $jsonc = Join-Path $script:ProjectRoot ".kilo\kilo.jsonc"
        if ((Test-Path -LiteralPath $json -PathType Leaf) -and (Test-Path -LiteralPath $jsonc -PathType Leaf)) {
            throw "KILO_CONFIG_COLLISION: both .kilo/kilo.json and .kilo/kilo.jsonc exist. Consolidate them explicitly before ITL writes managed Kilo state."
        }
    }

    $trackedConfig = switch ($Client) {
        "cursor" { ".cursor/mcp.json" }
        "opencode" { "opencode.json" }
        default { "" }
    }
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
    if ($Client -eq "opencode") {
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
        $url = [string]$_.url
        if ($name -and $url) { [pscustomobject]@{ name = (ConvertTo-ItlClientMcpKey -Name $name -Client $Client); url = $url } }
    })

    if ($Client -eq "codex") {
        $lines = [System.Collections.Generic.List[string]]::new()
        foreach ($endpoint in @($normalized | Sort-Object name)) {
            $lines.Add("[mcp_servers.$(ConvertTo-Vibecoding1cMcpTomlString $endpoint.name)]")
            $lines.Add("url = $(ConvertTo-Vibecoding1cMcpTomlString $endpoint.url)")
            $lines.Add("enabled = true")
            $lines.Add("startup_timeout_sec = 20")
            $lines.Add("tool_timeout_sec = 120")
            $lines.Add("")
        }
        Set-Vibecoding1cMcpManagedTextBlock -Path $path -BlockId $Owner -Body ((@($lines) -join [Environment]::NewLine).TrimEnd())
        return $path
    }

    $config = [ordered]@{}
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        try { $config = ConvertTo-Vibecoding1cMcpHashtable -Object (Read-Utf8Text -Path $path | ConvertFrom-Json) } catch { throw "Client MCP config is not valid JSON: $path. $($_.Exception.Message)" }
    }
    $containerName = $(if ($Client -in @("claude-code", "cursor")) { "mcpServers" } else { "mcp" })
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
        $entry = if ($Client -eq "opencode") {
            [ordered]@{ type = "remote"; url = $endpoint.url; enabled = $true }
        } elseif ($Client -eq "kilocode") {
            [ordered]@{ type = "remote"; url = $endpoint.url; enabled = $true; timeout = 120000 }
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
    $frontmatter.Add($(if ($Client -eq "kilocode") { "mode: subagent" } else { "mode: subagent" }))
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
    if ($Client -eq "kilocode") { return ".kilo/agents/itl-routine.md" }
    if ($Client -eq "opencode") { return ".opencode/agent/itl-routine.md" }
    return ""
}

function Convert-ItlCommandForClient {
    param(
        [string]$Text,
        [string]$Client,
        [string]$FileName
    )

    if ($Client -in @("claude-code", "cursor")) {
        return ([regex]::Replace($Text, '(?m)^agent:\s*[^\r\n]+\r?\n', ''))
    }
    if ($Client -eq "opencode" -and $FileName -eq "itl-verify-fix.md") {
        return ([regex]::Replace($Text, '(?m)^agent:\s*[^\r\n]+\r?$', 'agent: build'))
    }
    if (Test-ItlRoutineEnabledForCommand -FileName $FileName) {
        return ([regex]::Replace($Text, '(?m)^agent:\s*[^\r\n]+\r?$', 'agent: itl-routine'))
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
                $relative = ($adapter.commandsPath.TrimEnd('/') + "/" + $name)
                $files[$relative] = Convert-ItlCommandForClient -Text (Read-Utf8Text -Path $source.FullName) -Client $Client -FileName $name
            }
        }
    }
    $routinePath = Get-ItlRoutineAgentRelativePath -Client $Client
    $routineNeeded = @($files.Keys | Where-Object { ([string]$files[$_]) -match '(?m)^agent:\s*itl-routine\s*$' }).Count -gt 0
    if ($routinePath -and $routineNeeded) { $files[$routinePath] = New-ItlRoutineAgentText -Client $Client }
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
                if ($actualHash -ne $expectedHash -and -not ($Client -eq "kilocode" -and (Test-ItlKnownLegacyKiloCommandHash -Hash $actualHash))) {
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
            if ($Client -eq "kilocode" -and (Test-ItlKnownLegacyKiloCommandHash -Hash $hash)) {
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

function Sync-ItlClientSurface {
    param([string]$SourceRoot = $script:ProjectRoot)

    if ($null -eq (Get-AiRules1cProjectManifest)) {
        Write-Host "Skipping ITL client surface generation because ai_rules_1c is not installed."
        return
    }
    $client = Get-ItlActiveClient
    Assert-ItlClientConfigWritable -Client $client
    $adapter = Get-ItlClientAdapter -Client $client
    $expectedFiles = Get-ItlExpectedSurfaceFiles -Client $client -SourceRoot $SourceRoot
    Sync-ItlManagedSurfaceFiles -Client $client -ExpectedFiles $expectedFiles
    if ($client -eq "kilocode") {
        Set-KiloSnapshotsDisabled
    }
    $surface = Get-ItlCommandSurface
    if (-not $adapter.commandsPath) {
        Write-Host "Codex uses project-local .agents/skills and natural requests; no project slash prompts were written."
        return
    }
    if ($client -eq "kilocode") {
        Untrack-GeneratedKiloItlCommands
    }
    Write-Host "Generated $client ITL command surface: $surface ($($adapter.commandsPath)/itl*.md)"
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
    $checks.Add([pscustomobject]@{ status = $(if ($openSpec.isAvailable) { "OK" } else { "FAIL" }); name = "openspec"; detail = $(if ($openSpec.isAvailable) { "active-client bundle installed" } else { $openSpec.reason }) })
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
    Write-Host "Doctor is read-only. Repair with pinned update-ai-rules, /itl-update-workflow, /itl-refresh, or the matching ITL MCP action."
    if (@($checks | Where-Object { $_.status -eq "FAIL" }).Count -gt 0) { throw "ITL doctor found failed checks." }
}

function Sync-KiloItlCommandSurface {
    param([string]$SourceRoot = $script:ProjectRoot)
    Sync-ItlClientSurface -SourceRoot $SourceRoot
}
