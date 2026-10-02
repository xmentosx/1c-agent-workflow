Describe 'Effective client MCP observations' {
    BeforeAll {
        $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $HelperPath = Join-Path $RepoRoot '.agents\skills\1c-workflow\scripts\agent-1c.ps1'

        function New-ObservationFixture {
            param([string]$Name, [string[]]$Clients = @('opencode'), [string[]]$Installed = $Clients)
            $root = Join-Path $TestDrive ('Наблюдение клиентов с пробелом ' + $Name)
            New-Item -ItemType Directory -Force -Path (Join-Path $root '.agent-1c'), (Join-Path $root '.opencode'), (Join-Path $root '.codex'), (Join-Path $root '.cursor') | Out-Null
            [IO.File]::WriteAllText((Join-Path $root '.agent-1c/project.json'), (@{ masterBranch = 'master'; aiRules = @{ tools = $Clients } } | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($true))
            [IO.File]::WriteAllText((Join-Path $root '.ai-rules.json'), (@{ tools = $Installed; files = @{} } | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($true))
            [IO.File]::WriteAllText((Join-Path $root '.agent-1c/client-managed.json'), '{"schemaVersion":1,"owners":{}}', [Text.UTF8Encoding]::new($true))
            return $root
        }

        function Write-ObservationText {
            param([string]$Root, [string]$RelativePath, [string]$Text)
            [IO.File]::WriteAllText((Join-Path $Root $RelativePath), $Text, [Text.UTF8Encoding]::new($true))
        }

        function Get-ObservationFileState {
            param([string]$Root)
            return @((Get-ChildItem -LiteralPath $Root -File -Recurse | Sort-Object FullName) | ForEach-Object {
                $_.FullName.Substring($Root.Length) + ':' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
            })
        }

        function Read-Observation {
            param([string]$Root, [string]$Client)
            & {
                . $HelperPath -ProjectRoot $Root -Action help -AgentTarget $Client *> $null
                function Test-ProductDocsMcpAllowed { return $true }
                function Read-Vibecoding1cMcpSelection { return @{ servers = @(@{ id = 'bookstack'; enabled = $true }) } }
                function Test-Vibecoding1cMcpSelectionHasServerId { param($Selection, $ServerId) return $true }
                function Get-Vibecoding1cMcpCurrentEndpoints { param([switch]$IncludeGlobal) return @() }
                [pscustomobject]@{
                    keys = @(Get-ItlConfiguredMcpKeys)
                    entries = Read-ItlClientMcpEntries -Client $Client
                    product = Get-Vibecoding1cMcpProductDocsStatus
                    configuredClients = @(Get-AgentTargets)
                    managed = @(Get-ItlManagedMcpOwnerKeys -Owner 'ui-tools' -Client $Client)
                }
            }
        }
    }

    It 'observes nested JSONC Product Docs and effective UI keys across all four OpenCode layers without writes' {
        $root = New-ObservationFixture 'Четыре слоя'
        Write-ObservationText $root 'opencode.json' '{"mcp":{"foreign":{"type":"remote","url":"http://fixture/foreign"}}}'
        Write-ObservationText $root 'opencode.jsonc' @'
{
  // A lower project layer defines two endpoints.
  "mcp": {
    "agent-browser": {"type": "local", "command": ["C:\\Инструменты с пробелом\\browser.exe"]},
    "BookStack-product-docs-mcp": {"type": "remote", "url": "http://fixture/lower", "headers": {"fixture": "нижний слой"}},
  },
}
'@
        Write-ObservationText $root '.opencode/opencode.json' '{"mcp":{"windows-mcp":{"type":"local","command":["fixture-windows"]},"BookStack-product-docs-mcp":{"timeout":321}}}'
        Write-ObservationText $root '.opencode/opencode.jsonc' @'
{
  /* The final file overrides only its declared field. */
  "mcp": {"BookStack-product-docs-mcp": {"url": "http://fixture/последний слой",},},
}
'@
        $before = @(Get-ObservationFileState $root)
        $result = Read-Observation $root 'opencode'
        @($result.keys | Sort-Object) | Should -Be @('agent-browser', 'BookStack-product-docs-mcp', 'foreign', 'windows-mcp' | Sort-Object)
        $result.entries['BookStack-product-docs-mcp'].url | Should -BeExactly 'http://fixture/последний слой'
        $result.entries['BookStack-product-docs-mcp'].timeout | Should -Be 321
        $result.entries['BookStack-product-docs-mcp'].headers.fixture | Should -BeExactly 'нижний слой'
        $result.product.activeClient | Should -BeExactly 'opencode'
        $result.product.clientConfigured | Should -BeTrue
        $result.product.allowed | Should -BeTrue
        $result.product.selected | Should -BeTrue
        $result.product.reachable | Should -BeFalse
        @($result.managed).Count | Should -Be 0
        $result.configuredClients | Should -Be @('opencode')
        @(Get-ObservationFileState $root) | Should -Be $before
    }

    It 'observes a nested-only JSONC file without creating the legacy root JSON' {
        $root = New-ObservationFixture 'Только вложенный JSONC'
        Write-ObservationText $root '.opencode/opencode.jsonc' '{/* owned fixture, foreign endpoint */"mcp":{"BookStack-product-docs-mcp":{"type":"remote","url":"http://fixture/docs"},"agent-browser":{"type":"local","command":["fixture-browser"]},},}'
        $before = @(Get-ObservationFileState $root)
        $result = Read-Observation $root 'opencode'
        $result.product.clientConfigured | Should -BeTrue
        $result.keys | Should -Contain 'agent-browser'
        @($result.managed).Count | Should -Be 0
        Test-Path -LiteralPath (Join-Path $root 'opencode.json') | Should -BeFalse
        @(Get-ObservationFileState $root) | Should -Be $before
    }

    It 'preserves configured-key observation for the legacy single OpenCode JSON file' {
        $root = New-ObservationFixture 'Старый корневой JSON'
        Write-ObservationText $root 'opencode.json' '{"mcp":{"BookStack-product-docs-mcp":{"type":"remote","url":"http://fixture/docs","enabled":false},"windows-mcp":{"type":"local","command":["fixture"]}}}'
        $before = @(Get-ObservationFileState $root)
        $result = Read-Observation $root 'opencode'
        $result.product.clientConfigured | Should -BeTrue
        $result.entries['BookStack-product-docs-mcp'].enabled | Should -BeFalse
        $result.keys | Should -Contain 'windows-mcp'
        @(Get-ObservationFileState $root) | Should -Be $before
    }

    It 'preserves the existing <Client> configured Product Docs and UI key observations' -TestCases @(
        @{ Client = 'codex'; Path = '.codex/config.toml'; Text = "[mcp_servers.`"BookStack-product-docs-mcp`"]`nurl = `"http://fixture/docs`"`n[mcp_servers.agent-browser]`ncommand = `"fixture`"`n[mcp_servers.agent-browser.env]`nFIXTURE = `"значение с пробелом`"`n" },
        @{ Client = 'cursor'; Path = '.cursor/mcp.json'; Text = '{"mcpServers":{"BookStack-product-docs-mcp":{"url":"http://fixture/docs"},"agent-browser":{"command":"fixture"}}}' }
    ) {
        param($Client, $Path, $Text)
        $root = New-ObservationFixture $Client @($Client)
        Write-ObservationText $root $Path $Text
        $before = @(Get-ObservationFileState $root)
        $result = Read-Observation $root $Client
        $result.product.activeClient | Should -BeExactly $Client
        $result.product.clientConfigured | Should -BeTrue
        @($result.keys | Sort-Object) | Should -Be @('agent-browser', 'BookStack-product-docs-mcp' | Sort-Object)
        @(Get-ObservationFileState $root) | Should -Be $before
    }

    It 'does not turn a foreign layered endpoint into an attached executing client (<Case>)' -TestCases @(
        @{ Case = 'unattached'; Configured = @('cursor'); Installed = @('cursor'); Error = 'ITL_CLIENT_NOT_ATTACHED' },
        @{ Case = 'membership mismatch'; Configured = @('opencode'); Installed = @('cursor'); Error = 'Configured and installed ai_rules_1c clients disagree' }
    ) {
        param($Case, $Configured, $Installed, $Error)
        $root = New-ObservationFixture $Case $Configured $Installed
        Write-ObservationText $root '.opencode/opencode.jsonc' '{"mcp":{"BookStack-product-docs-mcp":{"url":"http://fixture/foreign"},"agent-browser":{"command":["foreign"]}}}'
        $before = @(Get-ObservationFileState $root)
        & {
            . $HelperPath -ProjectRoot $root -Action help -AgentTarget opencode *> $null
            function Test-ProductDocsMcpAllowed { return $true }
            function Read-Vibecoding1cMcpSelection { return @{ servers = @() } }
            function Test-Vibecoding1cMcpSelectionHasServerId { param($Selection, $ServerId) return $false }
            function Get-Vibecoding1cMcpCurrentEndpoints { param([switch]$IncludeGlobal) return @() }
            $status = Get-Vibecoding1cMcpProductDocsStatus
            $status.clientConfigured | Should -BeFalse
            { Get-ItlConfiguredMcpKeys } | Should -Throw "*$Error*"
            { Get-ItlActiveClient } | Should -Throw "*$Error*"
            @(Get-ItlManagedMcpOwnerKeys -Owner 'ui-tools' -Client opencode).Count | Should -Be 0
            @(Get-AgentTargets) | Should -Be $Configured
        }
        @(Get-ObservationFileState $root) | Should -Be $before
    }
}
