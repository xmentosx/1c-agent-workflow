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

function Stop-ItlUiToolProcessTree {
    param([Parameter(Mandatory = $true)][object]$Process)

    $started = $Process.StartTime
    $inventory = @(Get-CimInstance Win32_Process | Select-Object ProcessId, ParentProcessId, CreationDate)
    $root = @($inventory | Where-Object { $_.ProcessId -eq $Process.Id })
    if ($root.Count -gt 0 -and [Math]::Abs(($root[0].CreationDate - $started).TotalSeconds) -gt 1) {
        return [pscustomobject]@{ confirmed = $false; error = 'UI probe PID identity changed; no process was stopped.' }
    }
    $owned = @($root)
    $level = @($Process.Id)
    while ($level.Count -gt 0) {
        $children = @($inventory | Where-Object { $_.ParentProcessId -in $level -and $_.CreationDate -ge $started.AddSeconds(-1) })
        $owned += $children
        $level = @($children | ForEach-Object ProcessId)
    }
    $errors = @()
    foreach ($item in @($owned | Sort-Object CreationDate -Descending)) {
        $actual = Get-CimInstance Win32_Process -Filter "ProcessId=$($item.ProcessId)"
        if ($null -eq $actual) { continue }
        if ($actual.CreationDate -ne $item.CreationDate) { $errors += "PID $($item.ProcessId) identity changed"; continue }
        $termination = Stop-NativeProcessForSafety -Process (Get-Process -Id $item.ProcessId -ErrorAction Stop)
        if (-not $termination.confirmed) { $errors += "PID $($item.ProcessId): $($termination.error)" }
    }
    return [pscustomobject]@{ confirmed = ($errors.Count -eq 0); error = ($errors -join '; ') }
}

function Invoke-ItlUiToolCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$FailureCode,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 300
    )
    $nativeExecutable = $Executable
    $nativeArguments = @($Arguments)
    if ([IO.Path]::GetExtension($Executable) -eq '.cmd') {
        # Resolve owned shims without cmd.exe. The browser's JS wrapper uses
        # Node spawn, which cannot start its packaged exe at a 260-character path.
        switch ([IO.Path]::GetFileName($Executable)) {
            'npm.cmd' {
                $node = Get-Command node.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
                $entry = Join-Path (Split-Path -Parent $Executable) 'node_modules\npm\bin\npm-cli.js'
                if (-not $node -or -not (Test-Path -LiteralPath $entry -PathType Leaf)) {
                    throw "$FailureCode`: the Node entrypoint for '$Executable' is unavailable."
                }
                $nativeExecutable = [string]$node.Source
                $nativeArguments = @([string]$entry) + $nativeArguments
            }
            'agent-browser.cmd' {
                $nativeExecutable = Join-Path (Split-Path -Parent (Split-Path -Parent $Executable)) 'agent-browser\bin\agent-browser-win32-x64.exe'
                if (-not (Test-Path -LiteralPath $nativeExecutable -PathType Leaf)) {
                    throw "$FailureCode`: the packaged Windows binary for '$Executable' is unavailable."
                }
                $nativeExecutable = [IO.Path]::GetFullPath($nativeExecutable)
            }
            default { throw "$FailureCode`: unsupported UI tool shim '$Executable'." }
        }
    }
    try {
        $result = Invoke-ItlNativeProcessCapture -FilePath $nativeExecutable -Arguments $nativeArguments -WorkingDirectory (Get-Location).Path -TimeoutSeconds $TimeoutSeconds -OnTimeout { param($process) Stop-ItlUiToolProcessTree -Process $process }
    } catch {
        throw "$FailureCode`: $($_.Exception.Message)"
    }
    $output = @([regex]::Split(([string]$result.stdout + "`n" + [string]$result.stderr), '\r?\n') | Where-Object { $_ })
    if ($result.exitCode -ne 0) {
        $tail = (@($output | Select-Object -Last 12) -join " ").Trim()
        throw "$FailureCode`: command failed with exit code $($result.exitCode). $tail"
    }
    return @($output)
}

function Test-ItlAgentBrowserReady {
    param([object]$Pin = $null, [switch]$StaticOnly)
    if ($null -eq $Pin) { $Pin = (Get-ItlUiToolsLock).agentBrowser }
    $executable = Get-ItlAgentBrowserExecutablePath -Pin $Pin
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { return $false }
    try {
        if ($StaticOnly) {
            $root = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $executable))
            $package = Read-Utf8Text -Path (Join-Path $root 'node_modules/agent-browser/package.json') | ConvertFrom-Json
            $lockText = (Read-Utf8Text -Path (Join-Path $root 'package-lock.json')).Replace('"":', '"_itl_root":')
            $packageLock = $lockText | ConvertFrom-Json
            $entry = $packageLock.packages.'node_modules/agent-browser'
            return ([string]$package.version -eq [string]$Pin.version -and
                [string]$entry.version -eq [string]$Pin.version -and [string]$entry.integrity -eq [string]$Pin.integrity -and
                (Test-Path -LiteralPath (Join-Path $root 'node_modules/agent-browser/bin/agent-browser-win32-x64.exe') -PathType Leaf))
        }
        $version = ((Invoke-ItlUiToolCommand -Executable $executable -Arguments @("--version") -FailureCode "AGENT_BROWSER_VERSION_FAILED" -TimeoutSeconds 30) -join " ").Trim()
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
    $policy = Get-ItlUiToolPolicy -Tool agent-browser
    if (-not $policy.valid) { throw "ITL_UI_TOOL_POLICY_INVALID: $($policy.key)='$($policy.raw)'; set auto, off, or required before installing agent-browser." }
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
    # Keep the same tool root and full GUID uniqueness without making the
    # temporary native executable path longer than the versioned destination.
    $staging = Join-Path $parent ('.' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $staging | Out-Null
    try {
        Invoke-ItlUiToolCommand -Executable $npm.Source -Arguments @("install", "--prefix", $staging, "--ignore-scripts", "--no-audit", "--no-fund", "--package-lock=true", "agent-browser@$($pin.version)") -FailureCode "AGENT_BROWSER_INSTALL_FAILED" | Out-Null
        $packageLockPath = Join-Path $staging "package-lock.json"
        # npm lockfile v3 includes packages[""]. Windows PowerShell 5 cannot
        # represent that empty property name; rename it only in the parsed view.
        $packageLockText = (Read-Utf8Text -Path $packageLockPath).Replace('"":', '"_itl_root":')
        $packageLock = $packageLockText | ConvertFrom-Json
        $resolved = $packageLock.packages.'node_modules/agent-browser'
        if ([string]$resolved.version -ne [string]$pin.version -or [string]$resolved.integrity -ne [string]$pin.integrity) {
            throw "AGENT_BROWSER_INTEGRITY_FAILED: npm resolved version/integrity does not match dependency-lock."
        }
        $stagedExecutable = Join-Path $staging "node_modules\.bin\agent-browser.cmd"
        Invoke-ItlUiToolCommand -Executable $stagedExecutable -Arguments @("--version") -FailureCode "AGENT_BROWSER_VERSION_FAILED" -TimeoutSeconds 30 | Out-Null
        Invoke-ItlUiToolCommand -Executable $stagedExecutable -Arguments @("install") -FailureCode "AGENT_BROWSER_BROWSER_INSTALL_FAILED" -TimeoutSeconds 600 | Out-Null
        Invoke-ItlUiToolCommand -Executable $stagedExecutable -Arguments @("doctor") -FailureCode "AGENT_BROWSER_DOCTOR_FAILED" -TimeoutSeconds 90 | Out-Null
        Invoke-ItlUiToolCommand -Executable $stagedExecutable -Arguments @("skills", "get", "core", "--full") -FailureCode "AGENT_BROWSER_CORE_PROFILE_FAILED" -TimeoutSeconds 30 | Out-Null
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
    $policy = Get-ItlUiToolPolicy -Tool windows-mcp
    if (-not $policy.valid) { throw "ITL_UI_TOOL_POLICY_INVALID: $($policy.key)='$($policy.raw)'; set auto, off, or required before installing windows-mcp." }
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

function Get-ItlUiToolPolicy {
    param([ValidateSet('agent-browser','windows-mcp')][string]$Tool)
    $key = if ($Tool -eq 'agent-browser') { 'TOOL_AGENT_BROWSER' } else { 'TOOL_WINDOWS_MCP' }
    $raw = [string](Get-EnvValue -Name $key -Default '')
    $value = $raw.Trim().ToLowerInvariant()
    $valid = -not $value -or $value -in @('auto','off','required')
    return [pscustomobject]@{ key=$key; raw=$raw; valid=[bool]$valid; effective=$(if ($value) { $value } else { 'auto' }) }
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
            if ($BestEffort) {
                $policy = Get-ItlUiToolPolicy -Tool $tool
                if (-not $policy.valid) { throw "ITL_UI_TOOL_POLICY_INVALID: $($policy.key)='$($policy.raw)'; set auto, off, or required before automatic preparation." }
                if ($policy.effective -eq 'off') { Write-Host "$tool preparation skipped: $($policy.key)=off. A named install action may override this for one invocation."; continue }
            }
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
    try {
        return @((Read-ItlClientMcpEntries -Client $Client).Keys | ForEach-Object { [string]$_ })
    } catch {
        # Preserve the existing best-effort JSON observation and TOML read errors.
        if ((Get-ItlClientAdapter -Client $Client).mcpFormat -eq "toml") { throw }
        return @()
    }
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
    $installed = if ($Tool -eq "agent-browser") { Test-ItlAgentBrowserReady -Pin $pin -StaticOnly } else { Test-ItlWindowsMcpReady -Pin $pin }
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
        evidence = 'stored package/configuration identity only; runtime callability unverified'
    }
}

function Sync-ItlUiToolsMcp {
    param([string]$Client = "", [switch]$PlanOnly)
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
    $agentPolicy = Get-ItlUiToolPolicy -Tool agent-browser
    if (-not $agentPolicy.valid -or $agentPolicy.effective -eq 'off') {
        if ($owned -contains $agentKey) { $preserve += $agentKey }
    } elseif (Test-ItlAgentBrowserReady -Pin $lock.agentBrowser -StaticOnly) {
        if (-not ($configured -contains $agentKey) -or $owned -contains $agentKey) {
            $endpoints += [pscustomobject]@{ name = "agent-browser"; transport = "stdio"; command = (Get-ItlAgentBrowserExecutablePath -Pin $lock.agentBrowser); args = @("mcp"); env = [ordered]@{ AGENT_BROWSER_SESSION = Get-ItlWorktreeBrowserSession }; startupTimeoutSeconds = 30; toolTimeoutSeconds = 120 }
        }
    } elseif ($owned -contains $agentKey) { $preserve += $agentKey }

    $windowsKey = ConvertTo-ItlClientMcpKey -Name "windows-mcp" -Client $Client
    $windowsPolicy = Get-ItlUiToolPolicy -Tool windows-mcp
    if (-not $windowsPolicy.valid -or $windowsPolicy.effective -eq 'off') {
        if ($owned -contains $windowsKey) { $preserve += $windowsKey }
    } elseif (Test-ItlWindowsMcpReady -Pin $lock.windowsMcp) {
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
    if ($PlanOnly) { return [pscustomobject]@{client=$Client;owner='ui-tools';endpoints=$endpoints;preserveOwnedKeys=$preserve} }
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
