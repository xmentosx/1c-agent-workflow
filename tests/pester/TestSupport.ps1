function Initialize-WorkflowPesterContext {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
    $helperPath = Join-Path $repoRoot ".agents\skills\1c-workflow\scripts\agent-1c.ps1"
    $helperModulePaths = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot ".agents\skills\1c-workflow\scripts\lib") -File -Filter "agent-1c.*.ps1" | Sort-Object Name | ForEach-Object { $_.FullName })
    $launcherPath = Join-Path $repoRoot ".agents\skills\1c-workflow\scripts\run-agent-1c-window.ps1"
    $installerPath = Join-Path $repoRoot "install-agent-1c-workflow.ps1"
    $mcpHostPath = Join-Path $repoRoot "vibecoding1c-mcp-host\install-vibecoding1c-mcp-host.ps1"
    $mcpHostDumpPath = Join-Path $repoRoot "vibecoding1c-mcp-host\export-1c-config-dump.ps1"

    $helperParts = @()
    $helperParts += Get-Content -Encoding UTF8 -Raw $helperPath
    foreach ($modulePath in $helperModulePaths) {
        $helperParts += Get-Content -Encoding UTF8 -Raw $modulePath
    }

    return [pscustomobject]@{
        RepoRoot = $repoRoot
        HelperPath = $helperPath
        HelperModulePaths = $helperModulePaths
        LauncherPath = $launcherPath
        InstallerPath = $installerPath
        McpHostPath = $mcpHostPath
        McpHostDumpPath = $mcpHostDumpPath
        HelperText = ($helperParts -join [Environment]::NewLine)
        LauncherText = Get-Content -Encoding UTF8 -Raw $launcherPath
        McpHostText = @(
            (Get-Content -Encoding UTF8 -Raw $mcpHostPath),
            (Get-Content -Encoding UTF8 -Raw $mcpHostDumpPath)
        ) -join [Environment]::NewLine
    }
}

function Invoke-TestPowerShellFile {
    param(
        [string]$FilePath,
        [string[]]$Arguments = @()
    )

    $stdoutPath = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-test-powershell-stdout-" + [guid]::NewGuid().ToString("N") + ".log")
    $stderrPath = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-test-powershell-stderr-" + [guid]::NewGuid().ToString("N") + ".log")

    try {
        $quoteArgument = {
            param([string]$Value)
            if ($Value -match '[\s"]') {
                return '"' + ($Value -replace '"', '\"') + '"'
            }
            return $Value
        }
        $argumentList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (& $quoteArgument $FilePath)) + @($Arguments | ForEach-Object { & $quoteArgument $_ })
        $process = Start-Process -FilePath "powershell" `
            -ArgumentList $argumentList `
            -RedirectStandardOutput $stdoutPath `
            -RedirectStandardError $stderrPath `
            -Wait `
            -PassThru `
            -WindowStyle Hidden
        $exitCode = $process.ExitCode
        $stdout = @(if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) { Get-Content -Encoding UTF8 -LiteralPath $stdoutPath })
        $stderr = @(if (Test-Path -LiteralPath $stderrPath -PathType Leaf) { Get-Content -Encoding UTF8 -LiteralPath $stderrPath })
        $combined = @($stdout) + @($stderr)

        return [pscustomobject]@{
            exitCode = $exitCode
            stdout = @($stdout)
            stderr = @($stderr)
            combinedText = ($combined -join [Environment]::NewLine)
        }
    } finally {
        foreach ($path in @($stdoutPath, $stderrPath)) {
            if (Test-Path -LiteralPath $path -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Get-TestShortPath {
    param([string]$Path)

    $isWindowsVariable = Get-Variable -Name IsWindows -ErrorAction SilentlyContinue
    $isWindowsHost = if ($null -ne $isWindowsVariable) { [bool]$isWindowsVariable.Value } else { $env:OS -eq "Windows_NT" }
    if (-not $isWindowsHost) {
        return ""
    }
    if (-not (Test-Path -LiteralPath $Path -ErrorAction SilentlyContinue)) {
        return ""
    }

    $resolved = (Get-Item -LiteralPath $Path).FullName
    $cmdPath = $resolved -replace '"', '""'
    $output = @(cmd.exe /d /c "for %I in (`"$cmdPath`") do @echo %~sI" 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $output) {
        return ""
    }

    $shortPath = ([string]($output | Select-Object -First 1)).Trim()
    if (-not $shortPath -or $shortPath -eq $resolved) {
        return ""
    }
    if (-not (Test-Path -LiteralPath $shortPath -ErrorAction SilentlyContinue)) {
        return ""
    }
    return $shortPath
}

function Decode-TestUtf8([string]$Value) {
    return [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($Value))
}
