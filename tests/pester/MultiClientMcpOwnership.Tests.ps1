Describe 'Shared client MCP ownership' {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $helperPath = Join-Path $repoRoot '.agents\skills\1c-workflow\scripts\agent-1c.ps1'
    }

    It 'rejects a foreign Codex TOML section before writing an earlier client' {
        $root = Join-Path $TestDrive 'Чужая секция Codex MCP'
        New-Item -ItemType Directory -Force -Path (Join-Path $root '.agent-1c'), (Join-Path $root '.codex') | Out-Null
        [IO.File]::WriteAllText((Join-Path $root '.agent-1c/project.json'), '{"aiRules":{"tools":["kilocode","codex"]}}', [Text.UTF8Encoding]::new($false))
        $path = Join-Path $root '.codex/config.toml'
        [IO.File]::WriteAllText($path, "[mcp_servers.'reserved']`nurl = 'https://user.invalid'`nenabled = false`n", [Text.UTF8Encoding]::new($false))
        & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            $before = (Get-FileHash -LiteralPath $path).Hash
            $requests = @('kilocode','codex' | ForEach-Object { [pscustomobject]@{client=$_;owner='test';endpoints=@([pscustomobject]@{name='reserved';url='https://itl.invalid'})} })
            { Write-ItlClientMcpEndpointSet -Requests $requests } | Should -Throw '*CLIENT_MCP_USER_COLLISION*'
            (Get-FileHash -LiteralPath $path).Hash | Should -Be $before
            Test-Path -LiteralPath (Join-Path $root '.kilo/kilo.json') | Should -BeFalse
            Test-Path -LiteralPath (Get-ItlManagedMcpStatePath) | Should -BeFalse
        }
    }

    It 'adopts qualified legacy defaults in one write while preserving disabled and auth policy' {
        $root = Join-Path $TestDrive 'Старые MCP записи обоих клиентов'
        New-Item -ItemType Directory -Force -Path (Join-Path $root '.agent-1c'), (Join-Path $root '.codex'), (Join-Path $root '.kilo') | Out-Null
        [IO.File]::WriteAllText((Join-Path $root '.agent-1c/project.json'), '{"aiRules":{"tools":["kilocode","codex"]}}', [Text.UTF8Encoding]::new($false))
        $tomlPath = Join-Path $root '.codex/config.toml'
        [IO.File]::WriteAllText($tomlPath, "# user comment`n[mcp_servers.'1C-docs-mcp']`nurl = 'https://old.invalid'`nenabled = false`nmanagedBy = '1c-rules'`nhttp_headers = { Authorization = 'user-auth' }`n[mcp_servers.foreign]`nurl = 'https://user.invalid'`n", [Text.UTF8Encoding]::new($false))
        $kiloPath = Join-Path $root '.kilo/kilo.json'
        [IO.File]::WriteAllText($kiloPath, '{"mcp":{"1C-docs-mcp":{"url":"https://old.invalid","enabled":false,"managedBy":"1c-rules","headers":{"Authorization":"user-auth"}},"foreign":{"url":"https://user.invalid"}}}', [Text.UTF8Encoding]::new($false))
        & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            $requests = @('kilocode','codex' | ForEach-Object { [pscustomobject]@{client=$_;owner='vibecoding1c';replaceAiRulesServerIds=@('1C-docs-mcp');endpoints=@([pscustomobject]@{name='1C-docs-mcp';url='https://new.invalid'})} })
            Write-ItlClientMcpEndpointSet -Requests $requests | Out-Null
            $text = Read-Utf8Text -Path $tomlPath
            @([regex]::Matches($text, '(?m)^\[mcp_servers\.(?:"1C-docs-mcp"|''1C-docs-mcp'')\]')).Count | Should -Be 1
            $text | Should -Match '# user comment'
            $text | Should -Match 'user-auth'
            $codex = Read-ItlClientMcpEntries -Client codex
            $codex['1C-docs-mcp']['url'] | Should -Be 'https://new.invalid'
            $codex['1C-docs-mcp']['enabled'] | Should -BeFalse
            $codex['foreign']['url'] | Should -Be 'https://user.invalid'
            $kilo = Read-Utf8Text -Path $kiloPath | ConvertFrom-Json
            $kilo.mcp.'1C-docs-mcp'.url | Should -Be 'https://new.invalid'
            $kilo.mcp.'1C-docs-mcp'.enabled | Should -BeFalse
            $kilo.mcp.'1C-docs-mcp'.headers.Authorization | Should -Be 'user-auth'
            $kilo.mcp.foreign.url | Should -Be 'https://user.invalid'
            $before = (Get-FileHash -LiteralPath $tomlPath).Hash
            Write-ItlClientMcpEndpointSet -Requests $requests | Out-Null
            (Get-FileHash -LiteralPath $tomlPath).Hash | Should -Be $before
        }
    }

    It 'preflights actual bulk reconciliation before legacy removal or config writes' {
        $root = Join-Path $TestDrive 'Полный reconcile с поздним конфликтом'
        New-Item -ItemType Directory -Force -Path (Join-Path $root '.agent-1c/mcp'), (Join-Path $root '.kilo') | Out-Null
        [IO.File]::WriteAllText((Join-Path $root '.agent-1c/project.json'), '{"aiRules":{"tools":["kilocode","claude-code"]}}', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $root '.agent-1c/mcp/vibecoding1c-selection.json'), '{"schemaVersion":1,"servers":[]}', [Text.UTF8Encoding]::new($false))
        $kiloPath = Join-Path $root '.kilo/kilo.json'
        [IO.File]::WriteAllText($kiloPath, '{"mcp":{"onec-docs-mcp":{"url":"https://old.invalid","managedBy":"1c-rules"}}}', [Text.UTF8Encoding]::new($false))
        $shared = Join-Path $root '.mcp.json'
        [IO.File]::WriteAllText($shared, '{"mcpServers":{"1C-docs-mcp":{"url":"https://user.invalid"}}}', [Text.UTF8Encoding]::new($false))
        & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            function Get-Vibecoding1cMcpSelectionCompleteness { [pscustomobject]@{isComplete=$true;reasons=@()} }
            function Get-Vibecoding1cMcpReadyClientConfigNames { @('1C-docs-mcp') }
            function Get-Vibecoding1cMcpSelectedClientConfigNames { @('1C-docs-mcp') }
            function Get-Vibecoding1cMcpClientConfigEndpointSet { [pscustomobject]@{allEndpoints=@([pscustomobject]@{name='1C-docs-mcp';url='https://itl.invalid'})} }
            $script:legacyRemovalCalled = $false
            function Remove-AiRules1cManagedMcpConfig { $script:legacyRemovalCalled=$true; throw 'legacy cleanup ran before preflight' }
            $beforeKilo = (Get-FileHash -LiteralPath $kiloPath).Hash
            $beforeShared = (Get-FileHash -LiteralPath $shared).Hash
            { Invoke-AiRules1cManagedMcpConfigReconcile -Operation fixture *> $null } | Should -Throw '*CLIENT_MCP_USER_COLLISION*'
            $script:legacyRemovalCalled | Should -BeFalse
            (Get-FileHash -LiteralPath $kiloPath).Hash | Should -Be $beforeKilo
            (Get-FileHash -LiteralPath $shared).Hash | Should -Be $beforeShared
            Test-Path -LiteralPath (Get-ItlManagedMcpStatePath) | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $root '.gitignore') | Should -BeFalse
        }
    }

    It 'preserves a late user edit when reconciliation detects changed final-set input' {
        $root = Join-Path $TestDrive 'Поздняя правка MCP при reconcile'
        New-Item -ItemType Directory -Force -Path (Join-Path $root '.agent-1c/mcp') | Out-Null
        [IO.File]::WriteAllText((Join-Path $root '.agent-1c/project.json'), '{"aiRules":{"tools":["claude-code"]}}', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $root '.agent-1c/mcp/vibecoding1c-selection.json'), '{"schemaVersion":1,"servers":[]}', [Text.UTF8Encoding]::new($false))
        $path = Join-Path $root '.mcp.json'
        [IO.File]::WriteAllText($path, '{"mcpServers":{"foreign":{"url":"https://before.invalid"}}}', [Text.UTF8Encoding]::new($false))
        & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            function Get-Vibecoding1cMcpSelectionCompleteness { [pscustomobject]@{isComplete=$true;reasons=@()} }
            function Get-Vibecoding1cMcpReadyClientConfigNames { @('1C-docs-mcp') }
            function Get-Vibecoding1cMcpSelectedClientConfigNames { @('1C-docs-mcp') }
            function Get-Vibecoding1cMcpClientConfigEndpointSet { [pscustomobject]@{allEndpoints=@([pscustomobject]@{name='1C-docs-mcp';url='https://itl.invalid'})} }
            $originalStateReader = ${function:Get-ItlMcpFileState}
            $script:sharedReads = 0
            function Get-ItlMcpFileState {
                param([string]$Path)
                if ($Path -eq (Join-Path $script:ProjectRoot '.mcp.json')) {
                    $script:sharedReads++
                    if ($script:sharedReads -eq 2) {
                        [IO.File]::WriteAllText($Path, '{"mcpServers":{"foreign":{"url":"https://late-user.invalid"}}}', [Text.UTF8Encoding]::new($false))
                    }
                }
                & $originalStateReader -Path $Path
            }
            { Invoke-AiRules1cManagedMcpConfigReconcile -Operation fixture *> $null } | Should -Throw '*CLIENT_MCP_FINAL_SET_CHANGED*repeat the original reconciliation*'
            (Read-Utf8Text -Path $path | ConvertFrom-Json).mcpServers.foreign.url | Should -Be 'https://late-user.invalid'
            Test-Path -LiteralPath (Get-ItlManagedMcpStatePath) | Should -BeFalse
            # Once the edit has been reviewed, the original operation can resume.
            ${function:Get-ItlMcpFileState} = $originalStateReader
            function Test-StaleAiRules1cDataMcpShouldBePruned { $false }
            Invoke-AiRules1cManagedMcpConfigReconcile -Operation fixture *> $null
            $result = Read-Utf8Text -Path $path | ConvertFrom-Json
            $result.mcpServers.foreign.url | Should -Be 'https://late-user.invalid'
            $result.mcpServers.'1C-docs-mcp'.url | Should -Be 'https://itl.invalid'
        }
    }

    It 'preflights every desired client before writing the first config on a later user collision' {
        $root = Join-Path $TestDrive 'Полный набор MCP с пробелом'
        New-Item -ItemType Directory -Force -Path (Join-Path $root '.agent-1c') | Out-Null
        [IO.File]::WriteAllText((Join-Path $root '.agent-1c/project.json'), '{"aiRules":{"tools":["kilocode","claude-code"]}}', [Text.UTF8Encoding]::new($false))
        $shared = Join-Path $root '.mcp.json'
        [IO.File]::WriteAllText($shared, '{"mcpServers":{"reserved":{"url":"https://user.invalid"}}}', [Text.UTF8Encoding]::new($false))
        & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            $kiloPath = Join-Path $root (Get-ItlClientAdapter -Client kilocode).mcpPath
            $before = (Get-FileHash -LiteralPath $shared).Hash
            $requests = @(
                [pscustomobject]@{client='kilocode';owner='test';endpoints=@([pscustomobject]@{name='safe';url='https://itl.invalid'})},
                [pscustomobject]@{client='claude-code';owner='test';endpoints=@([pscustomobject]@{name='reserved';url='https://itl.invalid'})}
            )
            { Write-ItlClientMcpEndpointSet -Requests $requests } | Should -Throw '*CLIENT_MCP_USER_COLLISION*'
            Test-Path -LiteralPath $kiloPath | Should -BeFalse
            Test-Path -LiteralPath (Get-ItlManagedMcpStatePath) | Should -BeFalse
            (Get-FileHash -LiteralPath $shared).Hash | Should -Be $before
        }
    }

    It 'stops the rules installer before fork placement on a later client MCP collision' {
        $root = Join-Path $TestDrive 'MCP до копирования fork'
        $rulesRoot = Join-Path $TestDrive 'fork source'
        New-Item -ItemType Directory -Force -Path (Join-Path $root '.agent-1c/mcp'), $rulesRoot | Out-Null
        [IO.File]::WriteAllText((Join-Path $root '.agent-1c/project.json'), '{"aiRules":{"tools":["kilocode","claude-code"]}}', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $root '.agent-1c/mcp/vibecoding1c-selection.json'), '{"schemaVersion":1,"servers":[]}', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $rulesRoot 'install.ps1'), 'throw "fork installer reached before MCP preflight"', [Text.UTF8Encoding]::new($true))
        $path = Join-Path $root '.mcp.json'
        [IO.File]::WriteAllText($path, '{"mcpServers":{"1C-docs-mcp":{"url":"https://user.invalid"}}}', [Text.UTF8Encoding]::new($false))
        & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            function Sync-AiRules1cCheckout { [pscustomobject]@{root=$rulesRoot} }
            function Assert-AiRules1cToolAdapters {}
            function Get-AiRules1cTools { @('kilocode','claude-code') }
            $script:modelTiersInitialized = $false
            function Initialize-ItlClientModelTiers { $script:modelTiersInitialized=$true }
            function Get-Vibecoding1cMcpSelectionCompleteness { [pscustomobject]@{isComplete=$true;reasons=@()} }
            function Get-Vibecoding1cMcpReadyClientConfigNames { @('1C-docs-mcp') }
            function Get-Vibecoding1cMcpSelectedClientConfigNames { @('1C-docs-mcp') }
            function Get-Vibecoding1cMcpClientConfigEndpointSet { [pscustomobject]@{allEndpoints=@([pscustomobject]@{name='1C-docs-mcp';url='https://itl.invalid'})} }
            $before = (Get-FileHash -LiteralPath $path).Hash
            { Invoke-AiRules1cInstaller -Command update *> $null } | Should -Throw '*CLIENT_MCP_USER_COLLISION*'
            $script:modelTiersInitialized | Should -BeFalse
            (Get-FileHash -LiteralPath $path).Hash | Should -Be $before
            Test-Path -LiteralPath (Join-Path $root '.kilo/kilo.json') | Should -BeFalse
            Test-Path -LiteralPath (Get-ItlManagedMcpStatePath) | Should -BeFalse
        }
    }

    It 'returns a complete reconciliation preflight without client, ownership or ignore writes' {
        $root = Join-Path $TestDrive 'Чистый MCP plan only'
        New-Item -ItemType Directory -Force -Path (Join-Path $root '.agent-1c/mcp') | Out-Null
        [IO.File]::WriteAllText((Join-Path $root '.agent-1c/project.json'), '{"aiRules":{"tools":["kilocode","claude-code"]}}', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $root '.agent-1c/mcp/vibecoding1c-selection.json'), '{"schemaVersion":1,"servers":[]}', [Text.UTF8Encoding]::new($false))
        & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            function Get-Vibecoding1cMcpSelectionCompleteness { [pscustomobject]@{isComplete=$true;reasons=@()} }
            function Get-Vibecoding1cMcpReadyClientConfigNames { @('1C-docs-mcp') }
            function Get-Vibecoding1cMcpSelectedClientConfigNames { @('1C-docs-mcp') }
            function Get-Vibecoding1cMcpClientConfigEndpointSet { [pscustomobject]@{allEndpoints=@([pscustomobject]@{name='1C-docs-mcp';url='https://itl.invalid'})} }
            $result = Invoke-AiRules1cManagedMcpConfigReconcile -PlanOnly
            $result.planned | Should -BeTrue
            $result.reconciled | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $root '.kilo/kilo.json') | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $root '.mcp.json') | Should -BeFalse
            Test-Path -LiteralPath (Get-ItlManagedMcpStatePath) | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $root '.gitignore') | Should -BeFalse
        }
    }

    It 'rejects different incoming shared claims with no config or ownership writes' {
        $root = Join-Path $TestDrive 'Разные общие MCP вклады'
        New-Item -ItemType Directory -Force -Path (Join-Path $root '.agent-1c') | Out-Null
        [IO.File]::WriteAllText((Join-Path $root '.agent-1c/project.json'), '{"aiRules":{"tools":["claude-code","command-code"]}}', [Text.UTF8Encoding]::new($false))
        & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            $requests = @(
                [pscustomobject]@{client='claude-code';owner='test';endpoints=@([pscustomobject]@{name='shared';url='https://first.invalid'})},
                [pscustomobject]@{client='command-code';owner='test';endpoints=@([pscustomobject]@{name='shared';url='https://second.invalid'})}
            )
            { Write-ItlClientMcpEndpointSet -Requests $requests } | Should -Throw '*CLIENT_MCP_OWNER_CONFLICT*'
            Test-Path -LiteralPath (Join-Path $root '.mcp.json') | Should -BeFalse
            Test-Path -LiteralPath (Get-ItlManagedMcpStatePath) | Should -BeFalse
        }
    }

    It 'checks facade and provider families together before an explicit client sync writes either' {
        $root = Join-Path $TestDrive 'Конфликт разных семейств MCP'
        New-Item -ItemType Directory -Force -Path (Join-Path $root '.agent-1c') | Out-Null
        [IO.File]::WriteAllText((Join-Path $root '.agent-1c/project.json'), '{"aiRules":{"tools":["codex","claude-code"]}}', [Text.UTF8Encoding]::new($false))
        $path = Join-Path $root '.mcp.json'
        [IO.File]::WriteAllText($path, '{"mcpServers":{"reserved":{"url":"https://user.invalid"}}}', [Text.UTF8Encoding]::new($false))
        & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            function Get-Vibecoding1cMcpClientConfigEndpointSet { [pscustomobject]@{allEndpoints=@([pscustomobject]@{name='1C-docs-mcp';url='https://itl.invalid'})} }
            function Write-ItlOnDemandMcpClientConfig {
                param([string]$Client,[switch]$PlanOnly)
                $PlanOnly | Should -BeTrue
                [pscustomobject]@{client=$Client;owner='ondemand-facade';endpoints=@([pscustomobject]@{name='reserved';url='https://facade.invalid'})}
            }
            function Sync-ItlUiToolsMcp { return $null }
            $before = (Get-FileHash -LiteralPath $path).Hash
            { Sync-ItlClientMcpConfig -Client claude-code *> $null } | Should -Throw '*CLIENT_MCP_USER_COLLISION*'
            (Get-FileHash -LiteralPath $path).Hash | Should -Be $before
            Test-Path -LiteralPath (Get-ItlManagedMcpStatePath) | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $root '.gitignore') | Should -BeFalse
        }
    }

    It 'preserves disabled and auth policy when an owned OpenCode key is renamed' {
        $root = Join-Path $TestDrive 'Старый ключ OpenCode MCP'
        New-Item -ItemType Directory -Force -Path (Join-Path $root '.agent-1c/mcp') | Out-Null
        [IO.File]::WriteAllText((Join-Path $root '.agent-1c/project.json'), '{"aiRules":{"tools":["opencode"]}}', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $root '.agent-1c/mcp/client-managed.json'), '{"schemaVersion":1,"owners":{"opencode/vibecoding1c":["1C-docs-mcp"]}}', [Text.UTF8Encoding]::new($false))
        $path = Join-Path $root 'opencode.json'
        [IO.File]::WriteAllText($path, '{"mcp":{"1C-docs-mcp":{"type":"remote","url":"https://old.invalid","managedBy":"vibecoding1c-mcp","family":"vibecoding1c","enabled":false,"headers":{"Authorization":"user-auth"}},"foreign":{"url":"https://user.invalid"}}}', [Text.UTF8Encoding]::new($false))
        & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            Write-ItlClientMcpEndpointSet -Requests @([pscustomobject]@{client='opencode';owner='vibecoding1c';endpoints=@([pscustomobject]@{name='1C-docs-mcp';url='https://new.invalid'})}) | Out-Null
            $config = Read-Utf8Text -Path $path | ConvertFrom-Json
            $config.mcp.'onec-docs-mcp'.url | Should -Be 'https://new.invalid'
            $config.mcp.'onec-docs-mcp'.enabled | Should -BeFalse
            $config.mcp.'onec-docs-mcp'.headers.Authorization | Should -Be 'user-auth'
            $config.mcp.PSObject.Properties.Name | Should -Not -Contain '1C-docs-mcp'
            $config.mcp.foreign.url | Should -Be 'https://user.invalid'
            @(Get-ItlManagedMcpOwnerKeys -Client opencode -Owner vibecoding1c) | Should -Be @('onec-docs-mcp')
        }
    }

    It 'updates an entire shared cohort to one desired transport while keeping foreign content and both owners' {
        $root = Join-Path $TestDrive 'Обновление общего MCP обоих клиентов'
        New-Item -ItemType Directory -Force -Path (Join-Path $root '.agent-1c') | Out-Null
        [IO.File]::WriteAllText((Join-Path $root '.agent-1c/project.json'), '{"aiRules":{"tools":["claude-code","command-code"]}}', [Text.UTF8Encoding]::new($false))
        & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            $old = @([pscustomobject]@{name='shared';url='https://old.invalid'})
            Write-ItlClientMcpEndpoints -Client claude-code -Owner test -Endpoints $old | Out-Null
            Write-ItlClientMcpEndpoints -Client command-code -Owner test -Endpoints $old | Out-Null
            $path = Join-Path $root '.mcp.json'
            $config = ConvertTo-Vibecoding1cMcpHashtable -Object (Read-Utf8Text -Path $path | ConvertFrom-Json)
            $servers = Get-ItlClientMcpContainer -Config $config -Path 'mcpServers'
            $servers['foreign'] = @{url='https://user.invalid'}
            $sharedEntry = ConvertTo-Vibecoding1cMcpHashtable -Object $servers['shared']
            $sharedEntry['enabled'] = $false
            $servers['shared'] = $sharedEntry
            Set-ItlClientMcpContainer -Config $config -Path 'mcpServers' -Container $servers
            Write-Vibecoding1cMcpJsonFile -Path $path -Value $config
            $new = @([pscustomobject]@{name='shared';url='https://new.invalid'})
            $requests = @('claude-code','command-code' | ForEach-Object { [pscustomobject]@{client=$_;owner='test';endpoints=$new} })
            Write-ItlClientMcpEndpointSet -Requests $requests | Out-Null
            $result = Read-Utf8Text -Path $path | ConvertFrom-Json
            $result.mcpServers.shared.url | Should -Be 'https://new.invalid'
            $result.mcpServers.shared.enabled | Should -BeFalse
            $result.mcpServers.foreign.url | Should -Be 'https://user.invalid'
            $owners = ConvertTo-Vibecoding1cMcpHashtable -Object (Read-ItlManagedMcpState).owners
            @($owners['claude-code/test']) | Should -Be @('shared')
            @($owners['command-code/test']) | Should -Be @('shared')
            $before = (Get-FileHash -LiteralPath $path).Hash
            Write-ItlClientMcpEndpointSet -Requests $requests | Out-Null
            (Get-FileHash -LiteralPath $path).Hash | Should -Be $before
        }
    }

    It 'preserves a shared Claude and Command Code server until its last owner leaves' {
        $root = Join-Path $TestDrive ('Общий MCP ' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path (Join-Path $root '.agent-1c') | Out-Null
        [IO.File]::WriteAllText((Join-Path $root '.agent-1c/project.json'), '{"aiRules":{"tools":["claude-code","command-code"]}}', [Text.UTF8Encoding]::new($false))
        & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            $endpoint = @([pscustomobject]@{ name='itl-shared'; url='https://itl.invalid/mcp'; transport='remote' })
            Write-ItlClientMcpEndpoints -Client claude-code -Owner test -Endpoints $endpoint | Out-Null
            Write-ItlClientMcpEndpoints -Client command-code -Owner test -Endpoints $endpoint | Out-Null
            Write-ItlClientMcpEndpoints -Client claude-code -Owner test -Endpoints @() | Out-Null
        }
        $config = Get-Content -LiteralPath (Join-Path $root '.mcp.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $config.mcpServers.'itl-shared'.url | Should -Be 'https://itl.invalid/mcp'
        & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            Write-ItlClientMcpEndpoints -Client command-code -Owner test -Endpoints @() | Out-Null
        }
        $config = Get-Content -LiteralPath (Join-Path $root '.mcp.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        @($config.mcpServers.PSObject.Properties | ForEach-Object { $_.Name }) | Should -Not -Contain 'itl-shared'
    }

    It 'rejects a different second-owner transport and a user-owned key before replacement' {
        $root = Join-Path $TestDrive ('MCP collision ' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path (Join-Path $root '.agent-1c') | Out-Null
        [IO.File]::WriteAllText((Join-Path $root '.agent-1c/project.json'), '{"aiRules":{"tools":["claude-code","command-code"]}}', [Text.UTF8Encoding]::new($false))
        $configPath = Join-Path $root '.mcp.json'
        [IO.File]::WriteAllText($configPath, '{"mcpServers":{"user-owned":{"type":"http","url":"https://user.invalid"}}}', [Text.UTF8Encoding]::new($false))
        $result = & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            $userHashBefore = (Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash
            $userCollision = ''
            try { Write-ItlClientMcpEndpoints -Client claude-code -Owner test -Endpoints @([pscustomobject]@{ name='user-owned'; url='https://itl.invalid'; transport='remote' }) | Out-Null }
            catch { $userCollision = $_.Exception.Message }
            $userBytesUnchanged = ((Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash -ceq $userHashBefore)
            Write-ItlClientMcpEndpoints -Client claude-code -Owner test -Endpoints @([pscustomobject]@{ name='itl-shared'; url='https://first.invalid'; transport='remote' }) | Out-Null
            $before = Read-Utf8Text -Path $configPath
            $ownerConflict = ''
            try { Write-ItlClientMcpEndpoints -Client command-code -Owner test -Endpoints @([pscustomobject]@{ name='itl-shared'; url='https://second.invalid'; transport='remote' }) | Out-Null }
            catch { $ownerConflict = $_.Exception.Message }
            [pscustomobject]@{ userCollision = $userCollision; userBytesUnchanged = $userBytesUnchanged; ownerConflict = $ownerConflict; ownerBytesUnchanged = ((Read-Utf8Text -Path $configPath) -ceq $before) }
        }
        $result.userCollision | Should -Match 'CLIENT_MCP_USER_COLLISION'
        $result.userBytesUnchanged | Should -BeTrue
        $result.ownerConflict | Should -Match 'CLIENT_MCP_OWNER_CONFLICT'
        $result.ownerBytesUnchanged | Should -BeTrue
    }
}

Describe 'Copied client MCP ownership proof' {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $helperPath = Join-Path $repoRoot '.agents/skills/1c-workflow/scripts/agent-1c.ps1'
        function New-CopiedMcpFixture {
            param([string]$Root)
            $source=Join-Path $Root 'Исходный owner'; $target=Join-Path $Root 'Ветка назначения'
            New-Item -ItemType Directory -Force -Path (Join-Path $source '.agent-1c'),(Join-Path $target '.kilo'),(Join-Path $target '.agent-1c/mcp') | Out-Null
            $config='{"mcp":{"itl-roctup-data":{"type":"local","command":["C:\\Tools\\Команда x.exe","--root","D:\\Рабочая папка"],"enabled":false,"headers":{"Authorization":"fixture-policy"}},"user-owned":{"url":"https://user.invalid"}},"permission":{"bash":"ask"}}'
            $sourceConfig=Join-Path $source 'config.json'; $sourceOwner=Join-Path $source 'owners.json'
            $targetConfig=Join-Path $target '.kilo/kilo.json'; $targetOwner=Join-Path $target '.agent-1c/mcp/client-managed.json'
            [IO.File]::WriteAllText($sourceConfig,$config,[Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText($targetConfig,$config,[Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText($sourceOwner,'{"schemaVersion":1,"owners":{"kilocode/ondemand-facade":["itl-roctup-data","missing-source-key"],"codex/ondemand-facade":["user-owned"]}}',[Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText($targetOwner,'{"schemaVersion":1,"customNote":"preserve","owners":{"kilocode/branch-runtime":[],"codex/user":["separate-config"]}}',[Text.UTF8Encoding]::new($false))
            foreach($rootPath in @($source,$target)) { [IO.File]::WriteAllText((Join-Path $rootPath '.agent-1c/project.json'),'{"aiRules":{"tools":["kilocode"]}}',[Text.UTF8Encoding]::new($false)) }
            return [pscustomobject]@{root=$target;source=$source;sourceConfig=$sourceConfig;sourceOwner=$sourceOwner;targetConfig=$targetConfig;targetOwner=$targetOwner}
        }
    }

    It 'transfers exact copied ownership and preserves policy (explicit target: <ExplicitTarget>)' -ForEach @(@{ExplicitTarget=$false},@{ExplicitTarget=$true}) {
        $fixture=New-CopiedMcpFixture -Root (Join-Path $TestDrive ('Точный перенос MCP '+$ExplicitTarget))
        & {
            $initialRoot=if($ExplicitTarget){$fixture.source}else{$fixture.root}
            . $helperPath -ProjectRoot $initialRoot -Action help *> $null
            $copyArguments=@{Client='kilocode';SourceConfigPath=$fixture.sourceConfig;SourceOwnershipPath=$fixture.sourceOwner;ExpectedConfigState=(Get-ItlMcpFileState $fixture.sourceConfig);ExpectedOwnershipState=(Get-ItlMcpFileState $fixture.sourceOwner)}
            if($ExplicitTarget){$copyArguments.TargetProjectRoot=$fixture.root}
            $configBefore=Get-ItlMcpFileState $fixture.targetConfig
            (Copy-ItlClientMcpOwnershipFromProof @copyArguments).changed | Should -BeTrue
            $script:ProjectRoot | Should -Be $initialRoot
            (Get-ItlMcpFileState $fixture.targetConfig) | Should -BeExactly $configBefore
            $state=Read-Utf8Text -Path $fixture.targetOwner | ConvertFrom-Json
            $state.customNote | Should -Be 'preserve'
            @($state.owners.'codex/user') | Should -Contain 'separate-config'
            @($state.owners.'kilocode/ondemand-facade') | Should -Be @('itl-roctup-data')
            @($state.owners.PSObject.Properties.Name) | Should -Not -Contain 'codex/ondemand-facade'
            $ownerBefore=Get-ItlMcpFileState $fixture.targetOwner
            (Copy-ItlClientMcpOwnershipFromProof @copyArguments).changed | Should -BeFalse
            (Get-ItlMcpFileState $fixture.targetOwner) | Should -BeExactly $ownerBefore
            Invoke-InProjectContext -Root $fixture.root -ScriptBlock {
                Write-ItlClientMcpEndpoints -Client kilocode -Owner ondemand-facade -Endpoints @([pscustomobject]@{name='itl-roctup-data';url='https://new.invalid'}) | Out-Null
                $actual=Read-Utf8Text -Path $fixture.targetConfig | ConvertFrom-Json
                $actual.mcp.'itl-roctup-data'.url | Should -Be 'https://new.invalid'
                $actual.mcp.'itl-roctup-data'.enabled | Should -BeFalse
                $actual.mcp.'itl-roctup-data'.headers.Authorization | Should -Be 'fixture-policy'
                $actual.permission.bash | Should -Be 'ask'
                $actual.mcp.'user-owned'.url | Should -Be 'https://user.invalid'
                { Write-ItlClientMcpEndpoints -Client kilocode -Owner ondemand-facade -Endpoints @([pscustomobject]@{name='user-owned';url='https://new.invalid'}) } | Should -Throw '*CLIENT_MCP_USER_COLLISION*'
            }
        }
    }

    It 'refuses <Mutation> proof drift without changing target bytes' -ForEach @(@{Mutation='target-config'},@{Mutation='source-config'},@{Mutation='source-ownership'},@{Mutation='config-hash'},@{Mutation='ownership-hash'}) {
        $fixture=New-CopiedMcpFixture -Root (Join-Path $TestDrive ('Изменённое доказательство '+$Mutation))
        & {
            . $helperPath -ProjectRoot $fixture.root -Action help *> $null
            $copyArguments=@{Client='kilocode';SourceConfigPath=$fixture.sourceConfig;SourceOwnershipPath=$fixture.sourceOwner;ExpectedConfigState=(Get-ItlMcpFileState $fixture.sourceConfig);ExpectedOwnershipState=(Get-ItlMcpFileState $fixture.sourceOwner)}
            switch($Mutation) {
                'target-config' { [IO.File]::AppendAllText($fixture.targetConfig,"`n",[Text.UTF8Encoding]::new($false)) }
                'source-config' { [IO.File]::AppendAllText($fixture.sourceConfig,"`n",[Text.UTF8Encoding]::new($false)) }
                'source-ownership' { [IO.File]::WriteAllText($fixture.sourceOwner,'{"owners":{"kilocode/ondemand-facade":["user-owned"]}}',[Text.UTF8Encoding]::new($false)) }
                'config-hash' {$copyArguments.ExpectedConfigState='file:'+('0'*64)}
                'ownership-hash' {$copyArguments.ExpectedOwnershipState='file:'+('0'*64)}
            }
            $configBefore=Get-ItlMcpFileState $fixture.targetConfig; $ownerBefore=Get-ItlMcpFileState $fixture.targetOwner
            { Copy-ItlClientMcpOwnershipFromProof @copyArguments } | Should -Throw '*CLIENT_MCP_COPY_PROOF_CHANGED*'
            (Get-ItlMcpFileState $fixture.targetConfig) | Should -BeExactly $configBefore
            (Get-ItlMcpFileState $fixture.targetOwner) | Should -BeExactly $ownerBefore
        }
    }

    It 'keeps an <Proof> config unowned and the ordinary collision strict' -ForEach @(@{Proof='absent'},@{Proof='empty'}) {
        $fixture=New-CopiedMcpFixture -Root (Join-Path $TestDrive ('Без владельца '+$Proof))
        if($Proof -eq 'absent'){Remove-Item -LiteralPath $fixture.sourceOwner}else{[IO.File]::WriteAllText($fixture.sourceOwner,'{"owners":{}}',[Text.UTF8Encoding]::new($false))}
        & {
            . $helperPath -ProjectRoot $fixture.root -Action help *> $null
            $configBefore=Get-ItlMcpFileState $fixture.targetConfig; $ownerBefore=Get-ItlMcpFileState $fixture.targetOwner
            (Copy-ItlClientMcpOwnershipFromProof -Client kilocode -SourceConfigPath $fixture.sourceConfig -SourceOwnershipPath $fixture.sourceOwner -ExpectedConfigState (Get-ItlMcpFileState $fixture.sourceConfig) -ExpectedOwnershipState (Get-ItlMcpFileState $fixture.sourceOwner)).changed | Should -BeFalse
            { Write-ItlClientMcpEndpoints -Client kilocode -Owner ondemand-facade -Endpoints @([pscustomobject]@{name='itl-roctup-data';url='https://new.invalid'}) } | Should -Throw '*CLIENT_MCP_USER_COLLISION*'
            (Get-ItlMcpFileState $fixture.targetConfig) | Should -BeExactly $configBefore
            (Get-ItlMcpFileState $fixture.targetOwner) | Should -BeExactly $ownerBefore
        }
    }

    It 'preserves a late ownership edit detected before its atomic write' {
        $fixture=New-CopiedMcpFixture -Root (Join-Path $TestDrive 'Поздняя правка владельца')
        & {
            . $helperPath -ProjectRoot $fixture.root -Action help *> $null
            $copyArguments=@{Client='kilocode';SourceConfigPath=$fixture.sourceConfig;SourceOwnershipPath=$fixture.sourceOwner;ExpectedConfigState=(Get-ItlMcpFileState $fixture.sourceConfig);ExpectedOwnershipState=(Get-ItlMcpFileState $fixture.sourceOwner)}
            $originalReader=${function:Get-ItlMcpFileState}
            $script:copiedConfigReads=0
            $lateText='{"schemaVersion":1,"owners":{"kilocode/late-user":["user-owned"]}}'
            function Get-ItlMcpFileState {
                param([string]$Path)
                if($Path -ceq $fixture.targetConfig){
                    $script:copiedConfigReads++
                    if($script:copiedConfigReads -eq 2){[IO.File]::WriteAllText($fixture.targetOwner,$lateText,[Text.UTF8Encoding]::new($false))}
                }
                & $originalReader -Path $Path
            }
            try {
                { Copy-ItlClientMcpOwnershipFromProof @copyArguments } | Should -Throw '*CLIENT_MCP_FINAL_SET_CHANGED*'
                (Read-Utf8Text -Path $fixture.targetOwner) | Should -BeExactly $lateText
                (Get-ItlMcpFileState $fixture.targetConfig) | Should -BeExactly $copyArguments.ExpectedConfigState
            } finally { Set-Item -Path Function:Get-ItlMcpFileState -Value $originalReader }
        }
    }

    It 'preserves <Conflict> without adopting ownership' -ForEach @(@{Conflict='foreign-owner'},@{Conflict='jsonc'}) {
        $fixture=New-CopiedMcpFixture -Root (Join-Path $TestDrive ('Конфликт '+$Conflict))
        if($Conflict -eq 'jsonc'){[IO.File]::WriteAllText((Join-Path $fixture.root '.kilo/kilo.jsonc'),'{ /* user comments */ }',[Text.UTF8Encoding]::new($false))}
        else{[IO.File]::WriteAllText($fixture.targetOwner,'{"schemaVersion":1,"owners":{"kilocode/foreign":["itl-roctup-data"]}}',[Text.UTF8Encoding]::new($false))}
        & {
            . $helperPath -ProjectRoot $fixture.root -Action help *> $null
            $configBefore=Get-ItlMcpFileState $fixture.targetConfig; $ownerBefore=Get-ItlMcpFileState $fixture.targetOwner
            $failure=if($Conflict -eq 'jsonc'){'*KILO_CONFIG_COLLISION*'}else{'*CLIENT_MCP_OWNER_CONFLICT*'}
            { Copy-ItlClientMcpOwnershipFromProof -Client kilocode -SourceConfigPath $fixture.sourceConfig -SourceOwnershipPath $fixture.sourceOwner -ExpectedConfigState (Get-ItlMcpFileState $fixture.sourceConfig) -ExpectedOwnershipState (Get-ItlMcpFileState $fixture.sourceOwner) } | Should -Throw $failure
            (Get-ItlMcpFileState $fixture.targetConfig) | Should -BeExactly $configBefore
            (Get-ItlMcpFileState $fixture.targetOwner) | Should -BeExactly $ownerBefore
        }
    }
}
