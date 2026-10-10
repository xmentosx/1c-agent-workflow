BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $helperPath = Join-Path $repoRoot '.agents\skills\1c-workflow\scripts\agent-1c.ps1'
}

Describe 'ITL client membership planning' {
    It 'restores membership and new client roots after failure while preserving a late MCP edit through retry' {
        $root = Join-Path $TestDrive 'Откат смены клиента с поздней правкой'
        New-Item -ItemType Directory -Force -Path (Join-Path $root '.agent-1c/mcp'), (Join-Path $root '.zcode'), (Join-Path $root '.kilo/worktrees') | Out-Null
        [IO.File]::WriteAllText((Join-Path $root '.agent-1c/project.json'), '{"aiRules":{"tools":["zcode"]}}', [Text.UTF8Encoding]::new($false))
        $beforeFiles = @{
            '.agent-1c/client-surface.json'='{"clients":{"zcode":{"files":{}}}}'
            '.agent-1c/mcp/client-managed.json'='{"schemaVersion":1,"owners":{}}'
            '.zcode/config.json'='{"mcp":{"servers":{"foreign":{"url":"https://before.invalid"}}}}'
            '.zcode/rules-1c/owned.md'='old-rule'
            '.kilo/worktrees/business.txt'='business-runtime'
            '.gitignore'='user-ignore'
            '.gitattributes'='user-attributes'
            'CLAUDE.md'='user-entry'
            '.clinerules/managed.md'='old-cline-rule'
            '.kimi/settings.json'='{"user":true}'
        }
        foreach ($path in $beforeFiles.Keys) {
            $physical = Join-Path $root $path
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $physical) | Out-Null
            [IO.File]::WriteAllText($physical, $beforeFiles[$path], [Text.UTF8Encoding]::new($false))
        }
        & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            function Assert-MasterWorktreeContext {}
            function Assert-WorkflowTrackedGitClean {}
            function Assert-ItlClientConfigWritable {}
            function Test-AiRulesManifestHasUserChanges { $false }
            function Sync-ItlClientUserEnvironment {}
            function Sync-ItlClientSurfaces {}
            $script:injectLateEdit = $true
            function Update-AiRules1c {
                New-Item -ItemType Directory -Force -Path (Join-Path $script:ProjectRoot '.mimocode/rules-1c') | Out-Null
                Write-Utf8Text -Path (Join-Path $script:ProjectRoot '.mimocode/rules-1c/new.md') -Value 'new-rule'
                Write-Utf8Text -Path (Join-Path $script:ProjectRoot '.zcode/rules-1c/owned.md') -Value 'changed-rule'
                Write-Utf8Text -Path (Join-Path $script:ProjectRoot '.agent-1c/client-surface.json') -Value '{"clients":{"mimocode":{"files":{}}}}'
                Write-Utf8Text -Path (Join-Path $script:ProjectRoot '.gitignore') -Value 'changed-ignore'
                Write-Utf8Text -Path (Join-Path $script:ProjectRoot 'CLAUDE.md') -Value 'changed-entry'
                if ($script:injectLateEdit) {
                    Write-Utf8Text -Path (Join-Path $script:ProjectRoot '.zcode/config.json') -Value '{"mcp":{"servers":{"foreign":{"url":"https://late.invalid"}}}}'
                    Write-Utf8Text -Path (Get-ItlManagedMcpStatePath) -Value '{"schemaVersion":1,"owners":{"mimocode/test":{"completed":true}}}'
                    throw 'CLIENT_MCP_FINAL_SET_CHANGED: late config edit'
                }
            }
            { Switch-ItlClient -Mode attach -Client mimocode *> $null } | Should -Throw '*Current MCP files and ownership receipts were preserved*repeat the original attach/detach*'
            @(Get-AgentTargets) | Should -Be @('zcode')
            Read-Utf8Text -Path (Join-Path $root '.agent-1c/client-surface.json') | Should -Be $beforeFiles['.agent-1c/client-surface.json']
            Read-Utf8Text -Path (Join-Path $root '.zcode/rules-1c/owned.md') | Should -Be 'old-rule'
            Test-Path -LiteralPath (Join-Path $root '.mimocode') | Should -BeFalse
            (Read-Utf8Text -Path (Join-Path $root '.zcode/config.json') | ConvertFrom-Json).mcp.servers.foreign.url | Should -Be 'https://late.invalid'
            (Read-Utf8Text -Path (Get-ItlManagedMcpStatePath) | ConvertFrom-Json).owners.'mimocode/test'.completed | Should -BeTrue
            Read-Utf8Text -Path (Join-Path $root '.kilo/worktrees/business.txt') | Should -Be 'business-runtime'
            foreach ($path in @('.gitignore','.gitattributes','CLAUDE.md','.clinerules/managed.md','.kimi/settings.json')) {
                Read-Utf8Text -Path (Join-Path $root $path) | Should -Be $beforeFiles[$path]
            }
            $script:injectLateEdit = $false
            Switch-ItlClient -Mode attach -Client mimocode *> $null
            @(Get-AgentTargets) | Should -Be @('zcode','mimocode')
            Read-Utf8Text -Path (Join-Path $root '.mimocode/rules-1c/new.md') | Should -Be 'new-rule'
            (Read-Utf8Text -Path (Join-Path $root '.zcode/config.json') | ConvertFrom-Json).mcp.servers.foreign.url | Should -Be 'https://late.invalid'
            # A normal failure restores the same complete inventory, including
            # the ownership and client-surface receipts and both new client roots.
            $snapshot = New-AiRulesMigrationSnapshot
            Write-Utf8Text -Path (Join-Path $root '.agent-1c/client-surface.json') -Value 'broken-surface'
            Write-Utf8Text -Path (Get-ItlManagedMcpStatePath) -Value 'broken-owner'
            Write-Utf8Text -Path (Join-Path $root '.zcode/config.json') -Value 'broken-config'
            Write-Utf8Text -Path (Join-Path $root '.mimocode/rules-1c/new.md') -Value 'broken-rule'
            Restore-AiRulesMigrationSnapshot -Snapshot $snapshot
            (Read-Utf8Text -Path (Get-ItlManagedMcpStatePath) | ConvertFrom-Json).owners.'mimocode/test'.completed | Should -BeTrue
            (Read-Utf8Text -Path (Join-Path $root '.agent-1c/client-surface.json') | ConvertFrom-Json).clients.PSObject.Properties.Name | Should -Be @('mimocode')
            Read-Utf8Text -Path (Join-Path $root '.mimocode/rules-1c/new.md') | Should -Be 'new-rule'
            (Read-Utf8Text -Path (Join-Path $root '.zcode/config.json') | ConvertFrom-Json).mcp.servers.foreign.url | Should -Be 'https://late.invalid'
        }
    }

    It 'preflights a later MCP collision before replacing any client surface' {
        $root = Join-Path $TestDrive 'Поздний MCP конфликт при surfaces'
        New-Item -ItemType Directory -Force -Path (Join-Path $root '.agent-1c') | Out-Null
        [IO.File]::WriteAllText((Join-Path $root '.agent-1c/project.json'), '{"aiRules":{"tools":["kilocode","claude-code"]}}', [Text.UTF8Encoding]::new($false))
        $mcpPath = Join-Path $root '.mcp.json'
        [IO.File]::WriteAllText($mcpPath, '{"mcpServers":{"reserved":{"url":"https://user.invalid"}}}', [Text.UTF8Encoding]::new($false))
        $facadePath = Join-Path $root 'fixture.exe'
        [IO.File]::WriteAllText($facadePath, 'fixture', [Text.UTF8Encoding]::new($false))
        & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            function Get-ItlExpectedSurfaceFiles { param([string]$Client) return ([ordered]@{".agents/skills/itl-$Client/SKILL.md"='managed'}) }
            function Get-AiRules1cProjectManifest { [pscustomobject]@{tools=@('kilocode','claude-code')} }
            function Get-ItlOnDemandMcpExecutablePath { return $facadePath }
            function Get-ItlOnDemandMcpEndpointDescriptors { @([pscustomobject]@{name='reserved';url='https://itl.invalid'}) }
            function Sync-ItlUiToolsMcp { return $null }
            $before = (Get-FileHash -LiteralPath $mcpPath).Hash
            { Sync-ItlClientSurfaces -SourceRoot $repoRoot } | Should -Throw '*CLIENT_MCP_USER_COLLISION*'
            Test-Path -LiteralPath (Join-Path $root '.agents/skills/itl-kilocode/SKILL.md') | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $root '.agent-1c/client-surface.json') | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $root '.kilo/kilo.json') | Should -BeFalse
            (Get-FileHash -LiteralPath $mcpPath).Hash | Should -Be $before
        }
    }

    It 'reports MCP reload per changed client without requiring the invoking client to be attached' {
        $root = Join-Path $TestDrive ('Reload clients ' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path (Join-Path $root '.agent-1c') | Out-Null
        [IO.File]::WriteAllText((Join-Path $root '.agent-1c/project.json'), '{"aiRules":{"tools":["kilocode"]}}', [Text.UTF8Encoding]::new($false))
        $result = & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            Register-ItlClientMcpSemanticChange -Client kilocode -Owner facade -Path '.kilo/mcp.json'
            Set-ItlOnDemandMcpSemanticReloadRequiredAction -Operation 'update-workflow' | Out-Null
            [string]$script:RunRequiredAction
        }
        $result | Should -Match 'kilocode:'
        $result | Should -Match '/reload'
        $result | Should -Match 'facade'
    }

    It 'accepts a hash-recorded obsolete Kilo command for owned removal, but rejects an edited one' {
        $root = Join-Path $TestDrive ('Legacy command Кириллица ' + [guid]::NewGuid().ToString('N'))
        $legacyPath = Join-Path $root '.kilo/commands/itl-old.md'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $legacyPath) | Out-Null
        [IO.File]::WriteAllText($legacyPath, 'old managed command', [Text.UTF8Encoding]::new($false))
        $result = & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            function Assert-ItlClientConfigWritable { param([string]$Client) }
            function Assert-ItlClientRequirements { param([string]$Client) }
            $hash = Get-ItlFileSha256 -Path $legacyPath
            $expected = [ordered]@{ kilocode = [ordered]@{ '.kilo/commands/itl.md' = 'new command' } }
            $existing = [ordered]@{ kilocode = [ordered]@{ files = [ordered]@{ '.kilo/commands/itl-old.md' = $hash } } }
            $accepted = $true
            try { Assert-ItlClientSurfaceFinalSet -ExpectedByClient $expected -ExistingClients $existing | Out-Null }
            catch { $accepted = $false }
            [IO.File]::WriteAllText($legacyPath, 'user edit', [Text.UTF8Encoding]::new($false))
            $edited = ''
            try { Assert-ItlClientSurfaceFinalSet -ExpectedByClient $expected -ExistingClients $existing | Out-Null }
            catch { $edited = $_.Exception.Message }
            [pscustomobject]@{ accepted=$accepted; edited=$edited }
        }
        $result.accepted | Should -BeTrue
        $result.edited | Should -Match 'ITL_SURFACE_USER_MODIFIED'
    }

    It 'preflights a later client collision before writing the first client surface' {
        $root = Join-Path $TestDrive ('Final set collision ' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path (Join-Path $root '.agent-1c') | Out-Null
        [IO.File]::WriteAllText((Join-Path $root '.agent-1c/project.json'), '{"aiRules":{"tools":["codex","kilocode"]}}', [Text.UTF8Encoding]::new($false))
        $collisionPath = Join-Path $root '.kilo/commands/itl-collision.md'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $collisionPath) | Out-Null
        [IO.File]::WriteAllText($collisionPath, 'user-owned', [Text.UTF8Encoding]::new($false))
        $result = & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            function Assert-ItlClientConfigWritable {}
            function Assert-ItlClientRequirements {}
            function Get-ItlExpectedSurfaceFiles {
                param([string]$Client, [string]$SourceRoot)
                if ($Client -eq 'codex') { return [ordered]@{ '.agents/skills/itl-first/SKILL.md' = 'first' } }
                return [ordered]@{ '.kilo/commands/itl-collision.md' = 'managed' }
            }
            $errorText = ''
            try { Sync-ItlClientSurfaces -SourceRoot $repoRoot } catch { $errorText = $_.Exception.Message }
            [pscustomobject]@{
                errorText = $errorText
                firstWritten = Test-Path -LiteralPath (Join-Path $root '.agents/skills/itl-first/SKILL.md')
                collisionText = Read-Utf8Text -Path (Join-Path $root '.kilo/commands/itl-collision.md')
                stateWritten = Test-Path -LiteralPath (Join-Path $root '.agent-1c/client-surface.json')
            }
        }
        $result.errorText | Should -Match 'ITL_SURFACE_COLLISION'
        $result.firstWritten | Should -BeFalse
        $result.collisionText | Should -Be 'user-owned'
        $result.stateWritten | Should -BeFalse
    }

    It 'keeps switch and status read-only for an attached multi-client project' {
        $root = Join-Path $TestDrive ('Сессия двух клиентов ' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path (Join-Path $root '.agent-1c') | Out-Null
        $configPath = Join-Path $root '.agent-1c/project.json'
        [IO.File]::WriteAllText($configPath, '{"aiRules":{"tools":["codex","kilocode"]}}', [Text.UTF8Encoding]::new($false))
        $before = (Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash
        $output = & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            Switch-ItlClient -Mode status
            Switch-ItlClient -Mode switch -Client kilocode
        } 6>&1 | Out-String
        $output | Should -Match 'codex, kilocode'
        $output | Should -Match 'Project client membership was not changed'
        (Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash | Should -Be $before
    }

    It 'does not silently select the sole installed client when another executor is identified' {
        $root = Join-Path $TestDrive ('Другой исполняющий клиент ' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path (Join-Path $root '.agent-1c') | Out-Null
        [IO.File]::WriteAllText((Join-Path $root '.agent-1c/project.json'), '{"aiRules":{"tools":["kilocode"]}}', [Text.UTF8Encoding]::new($false))
        $result = & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            function Get-InitAgentExecutionEnvironment { return @{ CODEX_THREAD_ID = 'verified-test-executor' } }
            $script:contextProcessCalls = 0
            function Get-InitAgentExecutionProcessChain { $script:contextProcessCalls++; return @() }
            $identified = ''
            try { Get-ItlActiveClient | Out-Null } catch { $identified = $_.Exception.Message }
            function Get-InitAgentExecutionEnvironment { return @{ CODEX_THREAD_ID = 'verified-test-executor'; CLAUDECODE = 'containing-other-client' } }
            $conflictingMarkers = ''
            try { Get-ItlActiveClient | Out-Null } catch { $conflictingMarkers = $_.Exception.Message }
            $markerProcessCalls = $script:contextProcessCalls
            function Get-InitAgentExecutionEnvironment { return @{} }
            $sole = Get-ItlActiveClient
            $fallbackProcessCalls = $script:contextProcessCalls
            function Get-InitAgentExecutionProcessChain { $script:contextProcessCalls++; return @([pscustomobject]@{ name='codex.exe'; executablePath=''; commandLine='' }) }
            $processIdentified = ''
            try { Get-ItlActiveClient | Out-Null } catch { $processIdentified = $_.Exception.Message }
            [pscustomobject]@{ identified = $identified; sole = $sole; conflictingMarkers = $conflictingMarkers; processIdentified = $processIdentified; markerProcessCalls = $markerProcessCalls; fallbackProcessCalls = $fallbackProcessCalls; detectedProcessCalls = $script:contextProcessCalls }
        }
        $result.identified | Should -Match "ITL_CLIENT_NOT_ATTACHED: 'codex'"
        $result.sole | Should -Be 'kilocode'
        $result.conflictingMarkers | Should -Match "ITL_CLIENT_NOT_ATTACHED: 'codex'"
        $result.processIdentified | Should -Match "ITL_CLIENT_NOT_ATTACHED: 'codex'"
        $result.markerProcessCalls | Should -Be 0
        $result.fallbackProcessCalls | Should -Be 1
        $result.detectedProcessCalls | Should -Be 2
    }

    It 'binds legacy model tiers to the original client before attach' {
        $root = Join-Path $TestDrive ('Исходная модель ' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path (Join-Path $root '.agent-1c') | Out-Null
        [IO.File]::WriteAllText((Join-Path $root '.agent-1c\project.json'), '{"aiRules":{"tools":["codex"]}}', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $root '.dev.env'), "SUBAGENT_MODEL_CODING=provider/original`nSUBAGENT_MODEL_LIGHT=provider/light`n", [Text.UTF8Encoding]::new($false))
        $result = & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            $migrated = Initialize-ItlClientModelTiers
            Set-ProjectAiRulesClients -Clients @('codex', 'kilocode')
            Read-ProjectConfig
            [pscustomobject]@{
                migrated = $migrated
                original = Get-ConfigValue -Path 'aiRules.modelTiersByClient.codex.coding'
                analysis = Get-ConfigValue -Path 'aiRules.modelTiersByClient.codex.analysis'
                analysisExplicit = Get-ConfigValue -Path 'aiRules.modelTiersByClient.codex.analysisExplicit'
                other = Get-ConfigValue -Path 'aiRules.modelTiersByClient.kilocode.light' -Default ''
                repeated = Initialize-ItlClientModelTiers
            }
        }
        $result.migrated | Should -BeTrue
        $result.original | Should -Be 'provider/original'
        $result.analysis | Should -Be 'provider/original'
        $result.analysisExplicit | Should -BeFalse
        $result.other | Should -Be ''
        $result.repeated | Should -BeFalse
    }

    It 'uses the installed manifest to recover the original model owner after client membership expands' {
        $root = Join-Path $TestDrive ('Модель после расширения ' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path (Join-Path $root '.agent-1c') | Out-Null
        [IO.File]::WriteAllText((Join-Path $root '.agent-1c/project.json'),
            '{"aiRules":{"tools":["codex","kilocode"]}}', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $root '.ai-rules.json'),
            '{"tools":["codex"],"files":{}}', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $root '.dev.env'),
            "SUBAGENT_MODEL_CODING=provider/original`n", [Text.UTF8Encoding]::new($false))
        $result = & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            $migrated = Initialize-ItlClientModelTiers
            [pscustomobject]@{
                migrated = $migrated
                original = Get-ConfigValue -Path 'aiRules.modelTiersByClient.codex.coding'
                other = Get-ConfigValue -Path 'aiRules.modelTiersByClient.kilocode.coding' -Default ''
            }
        }
        $result.migrated | Should -BeTrue
        $result.original | Should -Be 'provider/original'
        $result.other | Should -Be ''
    }


    It 'uses client-specific light models for generated routine agents' {
        $root = Join-Path $TestDrive ('Разные модели ' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path (Join-Path $root '.agent-1c') | Out-Null
        [IO.File]::WriteAllText((Join-Path $root '.agent-1c\project.json'),
            '{"aiRules":{"tools":["codex","kilocode"],"modelTiersByClient":{"codex":{"light":"provider/first"},"kilocode":{"light":"provider/second"}}}}',
            [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $root '.dev.env'), "SUBAGENT_MODEL_LIGHT=provider/legacy`n", [Text.UTF8Encoding]::new($false))
        $models = & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            @((Get-ItlRoutineModel -Client 'codex'), (Get-ItlRoutineModel -Client 'kilocode'))
        }
        $models | Should -Be @('provider/first', 'provider/second')
    }
    It 'renders distinct routine model ids for Kilo and OpenCode in one project' {
        $root = Join-Path $TestDrive ('Два routine ' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path (Join-Path $root '.agent-1c') | Out-Null
        [IO.File]::WriteAllText((Join-Path $root '.agent-1c\project.json'),
            '{"masterBranch":"master","aiRules":{"tools":["kilocode","opencode"],"modelTiersByClient":{"kilocode":{"light":"provider/kilo"},"opencode":{"light":"provider/open"}}}}',
            [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $root '.dev.env'), "ITL_ROUTINE_MODE=on`nSUBAGENT_MODEL_LIGHT=provider/legacy`n", [Text.UTF8Encoding]::new($false))
        & git -C $root init *> $null
        & git -C $root branch -M master
        $rendered = & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            [pscustomobject]@{
                kilo = Get-ItlExpectedSurfaceFiles -Client 'kilocode' -SourceRoot $repoRoot
                open = Get-ItlExpectedSurfaceFiles -Client 'opencode' -SourceRoot $repoRoot
            }
        }
        $rendered.kilo['.kilo/agents/itl-routine.md'] | Should -Match 'model: provider/kilo'
        $rendered.open['.opencode/agent/itl-routine.md'] | Should -Match 'model: provider/open'
        $rendered.kilo['.kilo/agents/itl-routine.md'] | Should -Not -Match 'provider/open|provider/legacy'
        $rendered.open['.opencode/agent/itl-routine.md'] | Should -Not -Match 'provider/kilo|provider/legacy'
    }
    It 'rerenders only the selected client model after an economy-mode model change' {
        $root = Join-Path $TestDrive ('Перерендер моделей ' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path (Join-Path $root '.agent-1c') | Out-Null
        $configPath = Join-Path $root '.agent-1c/project.json'
        [IO.File]::WriteAllText($configPath,
            '{"masterBranch":"master","aiRules":{"tools":["kilocode","opencode"],"modelTiersByClient":{"kilocode":{"light":"provider/kilo-old"},"opencode":{"light":"provider/open"}}}}',
            [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $root '.ai-rules.json'),
            '{"tools":["kilocode","opencode"],"files":{}}', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $root '.dev.env'), "ITL_ROUTINE_MODE=on`nORCHESTRATION=economy`n", [Text.UTF8Encoding]::new($false))
        & git -C $root init *> $null
        & git -C $root branch -M master
        $result = & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            Sync-ItlClientSurfaces -SourceRoot $repoRoot
            $kiloPath = Join-Path $root '.kilo/agents/itl-routine.md'
            $openPath = Join-Path $root '.opencode/agent/itl-routine.md'
            $beforeKilo = [IO.File]::ReadAllText($kiloPath)
            $beforeOpen = [IO.File]::ReadAllText($openPath)
            $config = [IO.File]::ReadAllText($configPath).Replace('provider/kilo-old', 'provider/kilo-new')
            [IO.File]::WriteAllText($configPath, $config, [Text.UTF8Encoding]::new($false))
            Read-ProjectConfig
            Sync-ItlClientSurfaces -SourceRoot $repoRoot
            [pscustomobject]@{
                beforeKilo = $beforeKilo
                afterKilo = [IO.File]::ReadAllText($kiloPath)
                beforeOpen = $beforeOpen
                afterOpen = [IO.File]::ReadAllText($openPath)
            }
        }
        $result.beforeKilo | Should -Match 'model: provider/kilo-old'
        $result.afterKilo | Should -Match 'model: provider/kilo-new'
        $result.afterOpen | Should -BeExactly $result.beforeOpen
    }
    It 'reconciles an empty client set without deleting user-owned project content' {
        $root = Join-Path $TestDrive ('Пустой набор ' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path (Join-Path $root '.agent-1c') | Out-Null
        [IO.File]::WriteAllText((Join-Path $root '.agent-1c\project.json'), '{"masterBranch":"master","aiRules":{"tools":["codex"]}}', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $root '.ai-rules.json'), '{"tools":["codex"],"files":{}}', [Text.UTF8Encoding]::new($false))
        & git -C $root init *> $null
        & git -C $root branch -M master
        $result = & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            Sync-ItlClientSurfaces -SourceRoot $repoRoot
            $owned = Join-Path $root '.agents/skills/itl-status/SKILL.md'
            $ownedInitially = Test-Path -LiteralPath $owned -PathType Leaf
            $custom = Join-Path $root 'USER-RULES.md'
            [IO.File]::WriteAllText($custom, 'user-owned', [Text.UTF8Encoding]::new($false))
            Set-ProjectAiRulesClients -Clients @()
            Read-ProjectConfig
            Sync-ItlClientSurfaces -SourceRoot $repoRoot
            [pscustomobject]@{
                ownedInitially = $ownedInitially
                ownedRemoved = -not (Test-Path -LiteralPath $owned)
                custom = Read-Utf8Text -Path $custom
                attached = @(Get-AgentTargets)
            }
        }
        $result.ownedInitially | Should -BeTrue
        $result.ownedRemoved | Should -BeTrue
        $result.custom | Should -Be 'user-owned'
        $result.attached | Should -BeNullOrEmpty
    }
    It 'attaches and detaches through an empty client set without resetting another client model' {
        $root = Join-Path $TestDrive ('Несколько клиентов ' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path (Join-Path $root '.agent-1c') | Out-Null
        [IO.File]::WriteAllText((Join-Path $root '.agent-1c\project.json'), '{"aiRules":{"tools":["codex"]}}', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $root '.dev.env'), "SUBAGENT_MODEL_LIGHT=provider/original`n", [Text.UTF8Encoding]::new($false))
        $result = & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            function Assert-MasterWorktreeContext {}
            function Assert-WorkflowTrackedGitClean {}
            function Assert-ItlClientConfigWritable {}
            function Test-AiRulesManifestHasUserChanges { return $false }
            function New-AiRulesMigrationSnapshot { return [pscustomobject]@{ root = 'fixture' } }
            function Read-ItlManagedMcpState { return [ordered]@{ owners = [ordered]@{} } }
            function Sync-ItlClientRequiredPackage {}
            function Update-AiRules1c {}
            function Sync-ItlClientSurfaces {}
            function Sync-ItlClientUserEnvironment {}

            Switch-ItlClient -Client kilocode -Mode attach
            $attached = @(Get-AgentTargets)
            Switch-ItlClient -Client codex -Mode detach
            $remaining = @(Get-AgentTargets)
            Switch-ItlClient -Client kilocode -Mode detach
            $empty = @(Get-AgentTargets)
            Switch-ItlClient -Client codex -Mode attach
            [pscustomobject]@{
                attached = $attached
                remaining = $remaining
                empty = $empty
                reattached = @(Get-AgentTargets)
                envText = Read-Utf8Text -Path (Join-Path $root '.dev.env')
            }
        }
        $result.attached | Should -Be @('codex','kilocode')
        $result.remaining | Should -Be @('kilocode')
        $result.empty | Should -BeNullOrEmpty
        $result.reattached | Should -Be @('codex')
        $result.envText | Should -Be "SUBAGENT_MODEL_LIGHT=provider/original`n"
    }
}

Describe 'ITL help client resolution' {
    It 'resolves one help executor while preserving output for every command prefix and project context' {
        $root = Join-Path $TestDrive ('Справка нескольких клиентов ' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path (Join-Path $root '.agent-1c') | Out-Null
        $configPath = Join-Path $root '.agent-1c/project.json'
        $manifestPath = Join-Path $root '.ai-rules.json'
        [IO.File]::WriteAllText($configPath, '{"masterBranch":"master","aiRules":{"tools":["codex","kilocode","kimi"]}}', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($manifestPath, '{"tools":["codex","kilocode","kimi"],"files":{}}', [Text.UTF8Encoding]::new($false))
        $beforeConfig = (Get-FileHash -LiteralPath $configPath).Hash
        $beforeManifest = (Get-FileHash -LiteralPath $manifestPath).Hash
        & git -C $root init *> $null
        & git -C $root branch -M master
        $results = & {
            . $helperPath -ProjectRoot $root -Action help -AgentTarget codex *> $null
            function Get-InitAgentExecutionEnvironment { return @{} }
            function Get-InitAgentExecutionProcessChain {
                $script:helpProcessCalls++
                return @([pscustomobject]@{ name=$script:helpExecutor; executablePath=''; commandLine='' })
            }
            foreach ($branch in @('master','itldev/help-proof','other-help-proof')) {
                & git -C $root symbolic-ref HEAD ('refs/heads/' + $branch)
                foreach ($client in @('codex','kilocode','kimi')) {
                    $AgentTarget = $client
                    $expected = Show-Help 6>&1 | Out-String -Width 10000
                    $AgentTarget = ''
                    $script:helpExecutor = $client
                    $script:helpProcessCalls = 0
                    $actual = Show-Help 6>&1 | Out-String -Width 10000
                    [pscustomobject]@{ client=$client; branch=$branch; expected=$expected; actual=$actual; processCalls=$script:helpProcessCalls }
                }
            }
        }
        $results.Count | Should -Be 9
        foreach ($result in $results) {
            $result.actual | Should -BeExactly $result.expected
            $result.actual | Should -Match ([regex]::Escape($root))
            $result.actual | Should -Match ('Ветка Git: ' + [regex]::Escape($result.branch))
            $result.processCalls | Should -Be 1
            $prefix = switch ($result.client) { 'codex' { '$itl-status' } 'kimi' { '/skill:itl-status' } default { '/itl-status' } }
            $result.actual | Should -Match ([regex]::Escape($prefix))
        }
        (Get-FileHash -LiteralPath $configPath).Hash | Should -Be $beforeConfig
        (Get-FileHash -LiteralPath $manifestPath).Hash | Should -Be $beforeManifest
    }

    It 'retains membership and manifest guards and plain help fallback for an unattached or ambiguous executor' {
        $root = Join-Path $TestDrive ('Справка без разрешённого клиента ' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path (Join-Path $root '.agent-1c') | Out-Null
        $configPath = Join-Path $root '.agent-1c/project.json'
        $manifestPath = Join-Path $root '.ai-rules.json'
        [IO.File]::WriteAllText($configPath, '{"masterBranch":"master","aiRules":{"tools":["codex","kilocode"]}}', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($manifestPath, '{"tools":["codex","kilocode"],"files":{}}', [Text.UTF8Encoding]::new($false))
        & git -C $root init *> $null
        & git -C $root branch -M master
        & {
            . $helperPath -ProjectRoot $root -Action help -AgentTarget codex *> $null
            $AgentTarget = ''
            $script:helpProcessCalls = 0
            function Get-InitAgentExecutionProcessChain { $script:helpProcessCalls++; return @() }
            function Get-InitAgentExecutionEnvironment { return @{ CLAUDECODE='verified-other-executor' } }
            { Get-ItlActiveClient } | Should -Throw "*ITL_CLIENT_NOT_ATTACHED: 'claude-code'*"
            $script:helpProcessCalls = 0
            $unattached = Show-Help 6>&1 | Out-String -Width 10000
            $script:helpProcessCalls | Should -Be 0
            $unattached | Should -Match '/itl-status'
            $unattached | Should -Not -Match '\$itl-status'
            function Get-InitAgentExecutionEnvironment { return @{} }
            $script:helpProcessCalls = 0
            $ambiguous = Show-Help 6>&1 | Out-String -Width 10000
            $script:helpProcessCalls | Should -Be 1
            $ambiguous | Should -BeExactly $unattached
            { Get-ItlActiveClient } | Should -Throw '*ITL_CLIENT_AMBIGUOUS*'
            $script:helpProcessCalls = 0
            ConvertTo-ItlActiveClientCommandText -Text '/itl-status' -Client codex | Should -BeExactly '$itl-status'
            ConvertTo-ItlActiveClientCommandText -Text '/itl-status' -Client claude-code | Should -BeExactly '/itl-status'
            { Get-ItlActiveClient -Client claude-code } | Should -Throw '*ITL_CLIENT_NOT_ATTACHED*'
            [IO.File]::WriteAllText($manifestPath, '{"tools":["codex"],"files":{}}', [Text.UTF8Encoding]::new($false))
            { Get-ItlActiveClient -Client codex } | Should -Throw '*Configured and installed ai_rules_1c clients disagree*'
            ConvertTo-ItlActiveClientCommandText -Text '/itl-status' -Client codex | Should -BeExactly '/itl-status'
            $script:helpProcessCalls | Should -Be 0
            @(Get-AgentTargets) | Should -Be @('codex','kilocode')
        }
    }
}
