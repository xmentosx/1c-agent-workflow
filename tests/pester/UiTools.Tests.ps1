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

    It "generates isolated direct stdio entries for all ten clients" {
        $clients = @("codex", "kilocode", "claude-code", "cursor", "opencode", "kimi", "qwen", "command-code", "cline", "pi")
        foreach ($client in $clients) {
            $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-ui-tools-$client-" + [guid]::NewGuid().ToString("N"))
            try {
                New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
                Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value (([ordered]@{ aiRules = [ordered]@{ tools = @($client) } } | ConvertTo-Json -Depth 4) + "`n")
                Copy-Item -LiteralPath (Join-Path $RepoRoot "templates\dependency-lock.json") -Destination (Join-Path $tempRoot ".agent-1c\dependency-lock.json")
                $result = & {
                    . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                    function Test-ItlAgentBrowserReady { return $true }
                    function Test-ItlWindowsMcpReady { return $true }
                    function Get-ItlAgentBrowserExecutablePath { return "C:\ITL\agent-browser.cmd" }
                    function Get-ItlWindowsMcpUvxPath { return "C:\ITL\uvx.exe" }
                    Sync-ItlUiToolsMcp -Client $client
                    $adapter = Get-ItlClientAdapter -Client $client
                    $path = Join-Path $tempRoot $adapter.mcpPath
                    [pscustomobject]@{
                        text = Get-Content -LiteralPath $path -Raw -Encoding UTF8
                        session = Get-ItlWorktreeBrowserSession
                        owners = @(Get-ItlManagedMcpOwnerKeys -Owner "ui-tools" -Client $client)
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
