function Get-ItlUiToolsLock {
    $lock = Read-DependencyLockManifest
    $dependencies = Get-StateValue -State $lock -Name "dependencies" -Default $null
    if ($null -eq $dependencies) { throw "UI_TOOLS_LOCK_MISSING: dependency-lock has no dependencies object." }
    $agentBrowser = Get-StateValue -State $dependencies -Name "agentBrowser" -Default $null
    $windowsMcp = Get-StateValue -State $dependencies -Name "windowsMcp" -Default $null
    if ($null -eq $agentBrowser -or $null -eq $windowsMcp) {
        throw "UI_TOOLS_LOCK_MISSING: dependency-lock must pin agentBrowser and windowsMcp."
    }
    return [pscustomobject]@{ agentBrowser = $agentBrowser; windowsMcp = $windowsMcp }
}

function Get-ItlUiToolsUserRoot {
    $local = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if ([string]::IsNullOrWhiteSpace($local)) { $local = $env:LOCALAPPDATA }
    if ([string]::IsNullOrWhiteSpace($local)) { throw "UI_TOOLS_LOCALAPPDATA_MISSING: no per-user LocalAppData path is available." }
    return Join-Path $local "ITL\ui-tools"
}

function Get-ItlAgentBrowserExecutablePath {
    param([object]$Pin = $null)
    if ($null -eq $Pin) { $Pin = (Get-ItlUiToolsLock).agentBrowser }
    return Join-Path (Get-ItlUiToolsUserRoot) ("agent-browser\{0}\node_modules\.bin\agent-browser.cmd" -f [string]$Pin.version)
}

function Get-ItlWindowsMcpReadyPath {
    param([object]$Pin = $null)
    if ($null -eq $Pin) { $Pin = (Get-ItlUiToolsLock).windowsMcp }
    return Join-Path (Get-ItlUiToolsUserRoot) ("windows-mcp\{0}\ready.json" -f [string]$Pin.version)
}

function Get-ItlWindowsMcpUvxPath {
    $uvx = Get-Command uvx -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($uvx) { return [string]$uvx.Source }
    return ""
}

function Get-ItlWorktreeBrowserSession {
    $normalized = (Get-FullPathNormalized $script:ProjectRoot).ToLowerInvariant()
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($normalized)))).Replace("-", "").ToLowerInvariant().Substring(0, 12)
    } finally {
        $sha.Dispose()
    }
    $leaf = (Split-Path -Leaf $script:ProjectRoot) -replace '[^A-Za-z0-9_-]', '-'
    if ([string]::IsNullOrWhiteSpace($leaf)) { $leaf = "worktree" }
    return "itl-$leaf-$hash"
}

function Invoke-ItlUiToolCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$FailureCode
    )
    $output = @(& $Executable @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        $tail = (@($output | Select-Object -Last 12) -join " ").Trim()
        throw "$FailureCode`: command failed with exit code $LASTEXITCODE. $tail"
    }
    return @($output)
}

function Test-ItlAgentBrowserReady {
    param([object]$Pin = $null)
    if ($null -eq $Pin) { $Pin = (Get-ItlUiToolsLock).agentBrowser }
    $executable = Get-ItlAgentBrowserExecutablePath -Pin $Pin
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { return $false }
    try {
        $version = ((Invoke-ItlUiToolCommand -Executable $executable -Arguments @("--version") -FailureCode "AGENT_BROWSER_VERSION_FAILED") -join " ").Trim()
        return $version -match [regex]::Escape([string]$Pin.version)
    } catch { return $false }
}

function Test-ItlWindowsMcpReady {
    param([object]$Pin = $null)
    if ($null -eq $Pin) { $Pin = (Get-ItlUiToolsLock).windowsMcp }
    $readyPath = Get-ItlWindowsMcpReadyPath -Pin $Pin
    $uvx = Get-ItlWindowsMcpUvxPath
    return [bool]($uvx -and (Test-Path -LiteralPath $readyPath -PathType Leaf))
}

function Install-ItlAgentBrowser {
    $pin = (Get-ItlUiToolsLock).agentBrowser
    if (Test-ItlAgentBrowserReady -Pin $pin) {
        Write-Host "agent-browser $($pin.version) is already installed."
        return
    }
    $node = Get-Command node -ErrorAction SilentlyContinue | Select-Object -First 1
    $npm = Get-Command npm.cmd -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $npm) { $npm = Get-Command npm -ErrorAction SilentlyContinue | Select-Object -First 1 }
    if (-not $node -or -not $npm) { throw "AGENT_BROWSER_NPM_REQUIRED: Node.js and npm are required." }

    $target = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Get-ItlAgentBrowserExecutablePath -Pin $pin)))
    $parent = Split-Path -Parent $target
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $staging = Join-Path $parent (".{0}.staging-{1}" -f [string]$pin.version, [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $staging | Out-Null
    try {
        Invoke-ItlUiToolCommand -Executable $npm.Source -Arguments @("install", "--prefix", $staging, "--ignore-scripts", "--no-audit", "--no-fund", "--package-lock=true", "agent-browser@$($pin.version)") -FailureCode "AGENT_BROWSER_INSTALL_FAILED" | Out-Null
        $packageLockPath = Join-Path $staging "package-lock.json"
        $packageLock = Read-Utf8Text -Path $packageLockPath | ConvertFrom-Json
        $resolved = $packageLock.packages.'node_modules/agent-browser'
        if ([string]$resolved.version -ne [string]$pin.version -or [string]$resolved.integrity -ne [string]$pin.integrity) {
            throw "AGENT_BROWSER_INTEGRITY_FAILED: npm resolved version/integrity does not match dependency-lock."
        }
        $stagedExecutable = Join-Path $staging "node_modules\.bin\agent-browser.cmd"
        Invoke-ItlUiToolCommand -Executable $stagedExecutable -Arguments @("--version") -FailureCode "AGENT_BROWSER_VERSION_FAILED" | Out-Null
        Invoke-ItlUiToolCommand -Executable $stagedExecutable -Arguments @("install") -FailureCode "AGENT_BROWSER_BROWSER_INSTALL_FAILED" | Out-Null
        Invoke-ItlUiToolCommand -Executable $stagedExecutable -Arguments @("doctor") -FailureCode "AGENT_BROWSER_DOCTOR_FAILED" | Out-Null
        Invoke-ItlUiToolCommand -Executable $stagedExecutable -Arguments @("skills", "get", "core", "--full") -FailureCode "AGENT_BROWSER_CORE_PROFILE_FAILED" | Out-Null
        if (Test-Path -LiteralPath $target) {
            $backup = "$target.invalid-$([DateTime]::UtcNow.ToString('yyyyMMddHHmmss'))"
            Move-Item -LiteralPath $target -Destination $backup
        }
        Move-Item -LiteralPath $staging -Destination $target
        $staging = ""
        Write-Host "Installed agent-browser $($pin.version); core skill profile verified."
    } finally {
        if ($staging -and (Test-Path -LiteralPath $staging)) {
            Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Install-ItlWindowsMcp {
    $pin = (Get-ItlUiToolsLock).windowsMcp
    if (Test-ItlWindowsMcpReady -Pin $pin) {
        Write-Host "Windows-MCP $($pin.version) is already prepared."
        return
    }
    $uvx = Get-ItlWindowsMcpUvxPath
    if (-not $uvx) { throw "WINDOWS_MCP_UVX_REQUIRED: uv/uvx is required." }
    Invoke-ItlUiToolCommand -Executable $uvx -Arguments @("--from", "windows-mcp==$($pin.version)", "windows-mcp", "--help") -FailureCode "WINDOWS_MCP_PRELOAD_FAILED" | Out-Null
    $readyPath = Get-ItlWindowsMcpReadyPath -Pin $pin
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $readyPath) | Out-Null
    Write-Utf8Text -Path $readyPath -Value (([ordered]@{ version = [string]$pin.version; preparedAt = [DateTime]::UtcNow.ToString("o"); transport = "stdio" } | ConvertTo-Json) + [Environment]::NewLine)
    Write-Host "Prepared Windows-MCP $($pin.version) in the uvx cache; autostart was not enabled."
}

function Install-ItlUiTools {
    param([switch]$BestEffort)
    if ($BestEffort -and $env:ITL_UI_TOOLS_AUTO_INSTALL -eq "skip") {
        Write-Host "UI tools auto-install skipped by the test/runtime override."
        return
    }
    $failures = @()
    foreach ($tool in @("agent-browser", "windows-mcp")) {
        try {
            if ($tool -eq "agent-browser") { Install-ItlAgentBrowser } else { Install-ItlWindowsMcp }
        } catch {
            if (-not $BestEffort) { throw }
            $failures += "$tool`: $($_.Exception.Message)"
            Write-Warning "UI tool preparation is non-blocking: $tool failed. $($_.Exception.Message)"
        }
    }
    if ($failures.Count -gt 0) { Write-Host "UI tools remain degraded; run -Action ui-tools-status for recovery commands." }
}

function Get-ItlConfiguredMcpKeys {
    param([string]$Client = "")
    if (-not $Client) { $Client = Get-ItlActiveClient }
    $adapter = Get-ItlClientAdapter -Client $Client
    $path = Join-Path $script:ProjectRoot $adapter.mcpPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @() }
    if ($adapter.mcpFormat -eq "toml") {
        $text = Read-Utf8Text -Path $path
        return @([regex]::Matches($text, '(?im)^\s*\[mcp_servers\.(?:"(?<quoted>[^"]+)"|(?<plain>[^\]\s]+))\]') | ForEach-Object {
            if ($_.Groups['quoted'].Success) { $_.Groups['quoted'].Value } else { $_.Groups['plain'].Value }
        } | Select-Object -Unique)
    }
    try { $config = ConvertTo-Vibecoding1cMcpHashtable -Object (Read-Utf8Text -Path $path | ConvertFrom-Json) } catch { return @() }
    $containerName = [string]$adapter.mcpContainer
    if (-not $config.Contains($containerName)) { return @() }
    return @((ConvertTo-Vibecoding1cMcpHashtable -Object $config[$containerName]).Keys | ForEach-Object { [string]$_ })
}

function Get-ItlUiToolStatus {
    param(
        [ValidateSet("agent-browser", "windows-mcp")][string]$Tool,
        [string]$Client = ""
    )
    if (-not $Client) { $Client = Get-ItlActiveClient }
    $lock = Get-ItlUiToolsLock
    $pin = if ($Tool -eq "agent-browser") { $lock.agentBrowser } else { $lock.windowsMcp }
    $key = ConvertTo-ItlClientMcpKey -Name $Tool -Client $Client
    $owned = @(Get-ItlManagedMcpOwnerKeys -Owner "ui-tools" -Client $Client)
    $configured = @(Get-ItlConfiguredMcpKeys -Client $Client)
    $installed = if ($Tool -eq "agent-browser") { Test-ItlAgentBrowserReady -Pin $pin } else { Test-ItlWindowsMcpReady -Pin $pin }
    $isOwned = $owned -contains $key
    $isConfigured = $configured -contains $key
    $state = if ($isConfigured -and -not $isOwned) { "external" } elseif ($installed -and $isOwned) { "configured" } elseif (-not $installed -and $isOwned) { "degraded" } elseif ($installed) { "degraded" } else { "missing" }
    $command = "powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action install-$Tool"
    return [pscustomobject]@{
        tool = $Tool
        expectedVersion = [string]$pin.version
        installedVersion = $(if ($installed) { [string]$pin.version } else { "" })
        state = $state
        configured = [bool]$isConfigured
        owned = [bool]$isOwned
        installCommand = $command
        profile = $(if ($Tool -eq "agent-browser") { [string]$pin.profile } else { "full-default-tools" })
    }
}

function Sync-ItlUiToolsMcp {
    param([string]$Client = "")
    if (-not $Client) { $Client = Get-ItlActiveClient }
    try { $lock = Get-ItlUiToolsLock } catch {
        Write-Warning "UI MCP reconciliation skipped for a legacy dependency lock: $($_.Exception.Message)"
        return
    }
    $owned = @(Get-ItlManagedMcpOwnerKeys -Owner "ui-tools" -Client $Client)
    $configured = @(Get-ItlConfiguredMcpKeys -Client $Client)
    $endpoints = @()
    $preserve = @()

    $agentKey = ConvertTo-ItlClientMcpKey -Name "agent-browser" -Client $Client
    if (Test-ItlAgentBrowserReady -Pin $lock.agentBrowser) {
        if (-not ($configured -contains $agentKey) -or $owned -contains $agentKey) {
            $endpoints += [pscustomobject]@{ name = "agent-browser"; transport = "stdio"; command = (Get-ItlAgentBrowserExecutablePath -Pin $lock.agentBrowser); args = @("mcp"); env = [ordered]@{ AGENT_BROWSER_SESSION = Get-ItlWorktreeBrowserSession }; startupTimeoutSeconds = 30; toolTimeoutSeconds = 120 }
        }
    } elseif ($owned -contains $agentKey) { $preserve += $agentKey }

    $windowsKey = ConvertTo-ItlClientMcpKey -Name "windows-mcp" -Client $Client
    if (Test-ItlWindowsMcpReady -Pin $lock.windowsMcp) {
        if (-not ($configured -contains $windowsKey) -or $owned -contains $windowsKey) {
            $uvx = Get-ItlWindowsMcpUvxPath
            if ($uvx) {
                $endpoints += [pscustomobject]@{ name = "windows-mcp"; transport = "stdio"; command = $uvx; args = @("--from", "windows-mcp==$($lock.windowsMcp.version)", "windows-mcp", "serve"); env = [ordered]@{}; startupTimeoutSeconds = 45; toolTimeoutSeconds = 120 }
            }
        }
    } elseif ($owned -contains $windowsKey) { $preserve += $windowsKey }

    $adapter = Get-ItlClientAdapter -Client $Client
    if ($adapter.mcpFormat -eq "toml" -and $preserve.Count -gt 0) {
        Write-Warning "UI MCP reconciliation kept the previous Codex managed block because a pinned replacement is not ready."
        return
    }
    Write-ItlClientMcpEndpoints -Endpoints $endpoints -Owner "ui-tools" -Client $Client -PreserveOwnedKeys $preserve | Out-Null
}

function Show-ItlUiToolsStatus {
    try {
        $client = Get-ItlActiveClient
    } catch {
        Write-Host "UI tools: client=unknown; state=missing; dependency/config status is unavailable in this legacy or incomplete project."
        Write-Host "Install/recover after initialization: powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action install-ui-tools"
        return
    }
    foreach ($tool in @("agent-browser", "windows-mcp")) {
        try {
            $status = Get-ItlUiToolStatus -Tool $tool -Client $client
            $installed = if ($status.installedVersion) { $status.installedVersion } else { "none" }
            Write-Host "$($status.tool): installed=$installed; expected=$($status.expectedVersion); state=$($status.state); profile=$($status.profile); configured does not prove the server is active."
            if ($status.state -in @("missing", "degraded")) { Write-Host "Install/recover: $($status.installCommand)" }
        } catch {
            Write-Host "$tool`: installed=unknown; expected=unknown; state=missing; configured does not prove the server is active."
            Write-Host "Install/recover: powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action install-$tool"
        }
    }
}
