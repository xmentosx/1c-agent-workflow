Describe "ITL UI tools" {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        $RepoRoot = $context.RepoRoot
        $HelperPath = $context.HelperPath
    }

    It "pins exact direct-stdio UI tool dependencies without ports or desktop locks" {
        $lock = Get-Content -LiteralPath (Join-Path $RepoRoot "templates\dependency-lock.json") -Raw -Encoding UTF8 | ConvertFrom-Json
        $lock.dependencies.agentBrowser.version | Should -Be "0.33.1"
        $lock.dependencies.agentBrowser.integrity | Should -Be "sha512-lS0KbU9QdkD0I2n+uzrmNXKNGRjsd6GcB7bR6Wm1eyLcaxTCSf2zuxbWzf76fHCrDA4YoY3TikoOMSA8qA+wFA=="
        $lock.dependencies.agentBrowser.profile | Should -Be "core"
        $lock.dependencies.windowsMcp.version | Should -Be "0.8.2"
        $module = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.ui-tools.ps1") -Raw -Encoding UTF8
        $module | Should -Match 'transport = "stdio"'
        $module | Should -Match 'AGENT_BROWSER_SESSION'
        $module | Should -Match 'skills", "get", "core", "--full"'
        $module | Should -Match 'windows-mcp==\$\(\$lock\.windowsMcp\.version\)'
        $module | Should -Match 'autostart was not enabled'
        $module | Should -Not -Match 'ITL_PORT_REGISTRY|PORT_RANGE|desktop[- ]lock|telemetry|ScheduledTask|--port'
    }

    It "generates isolated direct stdio entries for all twelve clients" {
        $clients = @("codex", "kilocode", "claude-code", "cursor", "opencode", "kimi", "qwen", "command-code", "cline", "pi", "zcode", "mimocode")
        foreach ($client in $clients) {
            $uiFixtureClient = $client
            $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-ui-tools-$client-" + [guid]::NewGuid().ToString("N"))
            try {
                New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
                Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value (([ordered]@{ aiRules = [ordered]@{ tools = @($client) } } | ConvertTo-Json -Depth 4) + "`n")
                Copy-Item -LiteralPath (Join-Path $RepoRoot "templates\dependency-lock.json") -Destination (Join-Path $tempRoot ".agent-1c\dependency-lock.json")
                $result = & {
                    . $HelperPath -ProjectRoot $tempRoot -Action help -AgentTarget $uiFixtureClient *> $null
                    function Test-ItlAgentBrowserReady { return $true }
                    function Test-ItlWindowsMcpReady { return $true }
                    function Get-ItlAgentBrowserExecutablePath { return "C:\ITL\agent-browser.cmd" }
                    function Get-ItlWindowsMcpUvxPath { return "C:\ITL\uvx.exe" }
                    Sync-ItlUiToolsMcp -Client $uiFixtureClient
                    $adapter = Get-ItlClientAdapter -Client $uiFixtureClient
                    $path = Join-Path $tempRoot $adapter.mcpPath
                    [pscustomobject]@{
                        text = Get-Content -LiteralPath $path -Raw -Encoding UTF8
                        session = Get-ItlWorktreeBrowserSession
                        owners = @(Get-ItlManagedMcpOwnerKeys -Owner "ui-tools" -Client $uiFixtureClient)
                    }
                }
                $result.text | Should -Match "agent-browser"
                $result.text | Should -Match "windows-mcp"
                $result.text | Should -Match ([regex]::Escape($result.session))
                $result.text | Should -Match "stdio|command"
                $result.text | Should -Not -Match 'localhost|127\.0\.0\.1|--port|telemetry'
                @($result.owners).Count | Should -Be 2
            } finally {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "preserves a foreign UI key and reports it as external" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-ui-tools-foreign-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c"), (Join-Path $tempRoot ".cursor") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"aiRules":{"tools":["cursor"]}}'
            Copy-Item -LiteralPath (Join-Path $RepoRoot "templates\dependency-lock.json") -Destination (Join-Path $tempRoot ".agent-1c\dependency-lock.json")
            Set-Content -LiteralPath (Join-Path $tempRoot ".cursor\mcp.json") -Encoding UTF8 -Value '{"mcpServers":{"agent-browser":{"command":"foreign-browser"},"foreign":{"command":"keep"}}}'
            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                function Test-ItlAgentBrowserReady { return $true }
                function Test-ItlWindowsMcpReady { return $true }
                function Get-ItlAgentBrowserExecutablePath { return "C:\ITL\agent-browser.cmd" }
                function Get-ItlWindowsMcpUvxPath { return "C:\ITL\uvx.exe" }
                Sync-ItlUiToolsMcp -Client cursor
                [pscustomobject]@{
                    config = Get-Content -LiteralPath (Join-Path $tempRoot ".cursor\mcp.json") -Raw -Encoding UTF8 | ConvertFrom-Json
                    browser = Get-ItlUiToolStatus -Tool "agent-browser" -Client cursor
                    windows = Get-ItlUiToolStatus -Tool "windows-mcp" -Client cursor
                }
            }
            $result.config.mcpServers.'agent-browser'.command | Should -Be "foreign-browser"
            $result.config.mcpServers.foreign.command | Should -Be "keep"
            $result.config.mcpServers.'windows-mcp'.command | Should -Be "C:\ITL\uvx.exe"
            $result.browser.state | Should -Be "external"
            $result.windows.state | Should -Be "configured"
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "keeps best-effort failures non-blocking and explicit actions strict" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $env:ITL_UI_TOOLS_AUTO_INSTALL = ""
            function Install-ItlAgentBrowser { throw "npm unavailable" }
            function Install-ItlWindowsMcp { throw "network unavailable" }
            [pscustomobject]@{
                bestEffort = (Install-ItlUiTools -BestEffort 3>&1 6>&1) -join "`n"
                strict = try { Install-ItlUiTools; "unexpected" } catch { $_.Exception.Message }
            }
        }
        $result.bestEffort | Should -Match "non-blocking"
        $result.strict | Should -Match "npm unavailable"
        $env:ITL_UI_TOOLS_AUTO_INSTALL = "skip"
    }

    It "bounds a stalled UI command and stops only its own child before the original command is retried" {
        $root = Join-Path $TestDrive 'Зависший UI с пробелом'
        New-Item -ItemType Directory -Path $root | Out-Null
        $entry = Join-Path $root 'pipe.js'
        $pidPath = Join-Path $root 'child.json'
        [IO.File]::WriteAllText($entry, 'const fs=require("fs"), cp=require("child_process"); const child=cp.spawn(process.execPath,["-e","setTimeout(()=>{},180000)"],{stdio:"inherit",windowsHide:true}); fs.writeFileSync(process.argv[2],JSON.stringify({pid:child.pid})); setTimeout(()=>{},180000);', [Text.UTF8Encoding]::new($false))
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $node = (Get-Command node.exe -CommandType Application | Select-Object -First 1).Source
            $timer = [Diagnostics.Stopwatch]::StartNew()
            $failure = try { Invoke-ItlUiToolCommand -Executable $node -Arguments @($entry,$pidPath) -FailureCode 'UI_PIPE_FAILED' -TimeoutSeconds 1; 'unexpected' } catch { $_.Exception.Message }
            $child = Read-Utf8Text -Path $pidPath | ConvertFrom-Json
            $alive = $null -ne (Get-Process -Id $child.pid -ErrorAction SilentlyContinue)
            # Same owner and invocation path with the causal child behavior fixed.
            [IO.File]::WriteAllText($entry, 'process.stdout.write(process.argv[2]);', [Text.UTF8Encoding]::new($false))
            $continued = @(Invoke-ItlUiToolCommand -Executable $node -Arguments @($entry,$pidPath) -FailureCode 'UI_PIPE_FAILED' -TimeoutSeconds 5)
            [pscustomobject]@{ failure=$failure; seconds=$timer.Elapsed.TotalSeconds; childAlive=$alive; continued=$continued }
        }
        $result.failure | Should -Match 'UI_PIPE_FAILED: NATIVE_PROCESS_TIMEOUT'
        $result.failure | Should -Match 'owned cleanup confirmed=True'
        $result.seconds | Should -BeLessThan 15
        $result.childAlive | Should -BeFalse
        $result.continued | Should -Contain $pidPath
    }

    It "skips automatic disabled or invalid providers without changing a named invocation policy" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $env:ITL_UI_TOOLS_AUTO_INSTALL = ''
            $script:uiPolicy = @{ TOOL_AGENT_BROWSER='off'; TOOL_WINDOWS_MCP='invalid' }
            $script:uiPolicyCalls = @()
            function Get-EnvValue { param($Name,$Default) if ($script:uiPolicy.ContainsKey($Name)) { return $script:uiPolicy[$Name] }; return $Default }
            function Install-ItlAgentBrowser { $script:uiPolicyCalls += 'agent-browser' }
            function Install-ItlWindowsMcp { $script:uiPolicyCalls += 'windows-mcp' }
            $automatic = (Install-ItlUiTools -BestEffort 3>&1 6>&1) -join "`n"
            $callsBefore = @($script:uiPolicyCalls)
            Install-ItlAgentBrowser
            [pscustomobject]@{automatic=$automatic; callsBefore=$callsBefore; callsAfter=$script:uiPolicyCalls; policy=$script:uiPolicy.TOOL_AGENT_BROWSER}
        }
        @($result.callsBefore).Count | Should -Be 0
        $result.automatic | Should -Match 'TOOL_AGENT_BROWSER=off'
        $result.automatic | Should -Match 'ITL_UI_TOOL_POLICY_INVALID.*TOOL_WINDOWS_MCP'
        @($result.callsAfter).Count | Should -Be 1
        $result.policy | Should -Be 'off'
        $env:ITL_UI_TOOLS_AUTO_INSTALL = 'skip'
    }

    It "reports the stored browser package identity without starting a native readiness probe" {
        $root = Join-Path $TestDrive 'Статус UI с пробелом'
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $script:uiStatusProbeRoot = $root
            function Get-ItlUiToolsUserRoot { return $script:uiStatusProbeRoot }
            function Invoke-ItlUiToolCommand { throw 'A status read must not start a native process' }
            function Get-ItlManagedMcpOwnerKeys { return @() }
            function Get-ItlConfiguredMcpKeys { return @() }
            $pin = (Get-ItlUiToolsLock).agentBrowser
            $target = Join-Path $root "agent-browser/$($pin.version)"
            Write-Utf8Text -Path (Join-Path $target 'node_modules/.bin/agent-browser.cmd') -Value '@echo off'
            Write-Utf8Text -Path (Join-Path $target 'node_modules/agent-browser/bin/agent-browser-win32-x64.exe') -Value 'identity fixture, not an executable'
            Write-Utf8Text -Path (Join-Path $target 'node_modules/agent-browser/package.json') -Value ('{"version":"'+$pin.version+'"}')
            Write-Utf8Text -Path (Join-Path $target 'package-lock.json') -Value ('{"packages":{"":{},"node_modules/agent-browser":{"version":"'+$pin.version+'","integrity":"'+$pin.integrity+'"}}}')
            Get-ItlUiToolStatus -Tool agent-browser -Client codex
        }
        $result.installedVersion | Should -Be '0.33.1'
        $result.evidence | Should -Match 'stored.*unverified'
    }

    It "preserves Unicode output and arguments and uses process exit rather than a stderr notice" {
        $root = Join-Path $TestDrive 'Транспорт инструмента с пробелом'
        New-Item -ItemType Directory -Path $root | Out-Null
        $entry = Join-Path $root 'echo.js'
        [IO.File]::WriteAllText($entry, 'process.stdout.write(process.argv[2]); process.stderr.write("notice " + process.argv[2]); process.exit(Number(process.argv[3]));', [Text.UTF8Encoding]::new($false))
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $node = (Get-Command node.exe -CommandType Application | Select-Object -First 1).Source
            $okay = @(Invoke-ItlUiToolCommand -Executable $node -Arguments @($entry, $root, '0') -FailureCode 'UI_PROBE_FAILED')
            $failure = try { Invoke-ItlUiToolCommand -Executable $node -Arguments @($entry, $root, '7') -FailureCode 'UI_PROBE_FAILED'; 'unexpected' } catch { $_.Exception.Message }
            [pscustomobject]@{ okay=$okay; failure=$failure }
        }
        $result.okay | Should -Contain $root
        $result.okay | Should -Contain "notice $root"
        $result.failure | Should -Match 'UI_PROBE_FAILED: command failed with exit code 7'
        $result.failure | Should -Match ([regex]::Escape("notice $root"))
    }

    It "keeps the original Unicode tool root while avoiding a staging-only native path overflow" {
        $legacySuffix = 'agent-browser/.0.33.1.staging-' + ('a' * 32) + '/node_modules/agent-browser/bin/agent-browser-win32-x64.exe'
        $baseRoot = Join-Path $TestDrive 'Проба инструмента с пробелом '
        $padding = 260 - (Join-Path $baseRoot $legacySuffix).Length
        $root = $baseRoot + ('д' * $padding)
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $script:uiInstallProbeRoot = $root
            $script:uiInstallProbePin = (Get-ItlUiToolsLock).agentBrowser
            $script:uiOriginalCommand = ${function:Invoke-ItlUiToolCommand}
            $script:uiInstalledBinaryLength = 0
            $script:uiInstallCalls = @()
            function Get-ItlUiToolsUserRoot { return $script:uiInstallProbeRoot }
            function Test-ItlAgentBrowserReady { return $false }
            function Invoke-ItlUiToolCommand {
                param($Executable, $Arguments, $FailureCode)
                $script:uiInstallCalls += $FailureCode
                if ($FailureCode -eq 'AGENT_BROWSER_INSTALL_FAILED') {
                    $staging = $Arguments[2]
                    $metadata = '{"packages":{"":{"name":"root"},"node_modules/agent-browser":{"version":"' + $script:uiInstallProbePin.version + '","integrity":"' + $script:uiInstallProbePin.integrity + '"}}}'
                    Write-Utf8Text -Path (Join-Path $staging 'package-lock.json') -Value $metadata
                    $binary = Join-Path $staging 'node_modules/agent-browser/bin/agent-browser-win32-x64.exe'
                    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $binary) | Out-Null
                    Copy-Item -LiteralPath (Get-Command node.exe -CommandType Application | Select-Object -First 1).Source -Destination $binary
                    $script:uiInstalledBinaryLength = $binary.Length
                    return
                }
                # A real Windows executable proves this exact staging path can
                # launch; native browser behavior is qualified separately.
                & $script:uiOriginalCommand -Executable $Executable -Arguments @('--version') -FailureCode $FailureCode
            }
            Install-ItlAgentBrowser *> $null
            [pscustomobject]@{ binaryLength=$script:uiInstalledBinaryLength; root=Get-ItlUiToolsUserRoot; calls=$script:uiInstallCalls }
        }
        (Join-Path $root $legacySuffix).Length | Should -Be 260
        $result.binaryLength | Should -BeLessThan 260
        $result.root | Should -BeExactly $root
        $result.calls | Should -Contain 'AGENT_BROWSER_BROWSER_INSTALL_FAILED'
        $result.calls | Should -Contain 'AGENT_BROWSER_DOCTOR_FAILED'
        $result.calls | Should -Contain 'AGENT_BROWSER_CORE_PROFILE_FAILED'
    }

    It "reads the npm root package entry and rejects a mismatched browser integrity before promotion" {
        $toolRoot = Join-Path $TestDrive 'Инструменты UI с пробелом'
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $script:uiInstallProbeRoot = $toolRoot
            $script:uiInstallProbePin = (Get-ItlUiToolsLock).agentBrowser
            $script:uiInstallProbeIntegrity = [string]$script:uiInstallProbePin.integrity
            $script:uiInstallProbeCalls = @()
            function Get-ItlUiToolsUserRoot { return $script:uiInstallProbeRoot }
            function Test-ItlAgentBrowserReady { return $false }
            function Invoke-ItlUiToolCommand {
                param($Executable, $Arguments, $FailureCode)
                $script:uiInstallProbeCalls += $FailureCode
                if ($FailureCode -eq 'AGENT_BROWSER_INSTALL_FAILED') {
                    $staging = $Arguments[2]
                    $metadata = '{"lockfileVersion":3,"packages":{"":{"name":"root"},"node_modules/agent-browser":{"version":"' + $script:uiInstallProbePin.version + '","integrity":"' + $script:uiInstallProbeIntegrity + '"}}}'
                    Write-Utf8Text -Path (Join-Path $staging 'package-lock.json') -Value $metadata
                    return
                }
                return 'passed'
            }
            Install-ItlAgentBrowser *> $null
            $target = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Get-ItlAgentBrowserExecutablePath -Pin $script:uiInstallProbePin)))
            $acceptedLock = Read-Utf8Text -Path (Join-Path $target 'package-lock.json')
            $acceptedCalls = @($script:uiInstallProbeCalls)
            $script:uiInstallProbeCalls = @()
            $script:uiInstallProbeIntegrity = 'wrong-integrity'
            $rejection = try { Install-ItlAgentBrowser; 'unexpected' } catch { $_.Exception.Message }
            [pscustomobject]@{
                acceptedLock = $acceptedLock
                acceptedCalls = $acceptedCalls
                rejectedCalls = @($script:uiInstallProbeCalls)
                rejection = $rejection
                afterLock = Read-Utf8Text -Path (Join-Path $target 'package-lock.json')
            }
        }
        $result.acceptedLock | Should -Match '"":\{'
        $result.acceptedLock | Should -Not -Match '_itl_root'
        $result.acceptedCalls | Should -Contain 'AGENT_BROWSER_CORE_PROFILE_FAILED'
        $result.rejection | Should -Match 'AGENT_BROWSER_INTEGRITY_FAILED'
        @($result.rejectedCalls).Count | Should -Be 1
        $result.afterLock | Should -BeExactly $result.acceptedLock
    }

    It "derives different worktree sessions without allocating fixed ports" {
        $firstRoot = Join-Path ([IO.Path]::GetTempPath()) "itl-session-a"
        $secondRoot = Join-Path ([IO.Path]::GetTempPath()) "itl-session-b"
        $sessions = & {
            . $HelperPath -ProjectRoot $firstRoot -Action help *> $null
            $first = Get-ItlWorktreeBrowserSession
            $script:ProjectRoot = $secondRoot
            $second = Get-ItlWorktreeBrowserSession
            @($first, $second)
        }
        $sessions[0] | Should -Not -Be $sessions[1]
        $sessions[0] | Should -Match '^itl-.*-[a-f0-9]{12}$'
        $sessions[1] | Should -Match '^itl-.*-[a-f0-9]{12}$'
    }
}
