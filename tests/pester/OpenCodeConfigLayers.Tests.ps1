Describe 'OpenCode physical config ownership' {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
        $helperPath = Join-Path $repoRoot '.agents/skills/1c-workflow/scripts/agent-1c.ps1'
        function New-OpenCodeConfigFixture {
            param([string]$Name)
            $root = Join-Path $TestDrive $Name
            New-Item -ItemType Directory -Force -Path (Join-Path $root '.agent-1c/mcp'), (Join-Path $root '.opencode') | Out-Null
            [IO.File]::WriteAllText((Join-Path $root '.agent-1c/project.json'), '{"aiRules":{"tools":["opencode"]}}', [Text.UTF8Encoding]::new($false))
            return $root
        }
        function Write-OpenCodeFixtureText {
            param([string]$Root, [string]$RelativePath, [string]$Text)
            [IO.File]::WriteAllText((Join-Path $Root $RelativePath), $Text, [Text.UTF8Encoding]::new($false))
        }
    }

    It 'uses the only nested JSONC and keeps policy comments BOM CRLF and string literals' {
        $root = New-OpenCodeConfigFixture 'OpenCode вложенный файл'
        $before = [string][char]0xfeff + "{`r`n // project comment`r`n `"description`": `"literal ,} ,] https://user/*ok*/`",`r`n `"mcp`": {`r`n  // external server`r`n  `"external`": {`"url`":`"https://user.invalid`",`"enabled`":false},`r`n },`r`n}`r`n"
        Write-OpenCodeFixtureText $root '.opencode/opencode.jsonc' $before
        & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            Write-ItlClientMcpEndpoints -Client opencode -Owner fixture -Endpoints @([pscustomobject]@{name='owned';url='https://itl.invalid'}) | Out-Null
            $path = Join-Path $root '.opencode/opencode.jsonc'
            $after = [Text.UTF8Encoding]::new($false,$true).GetString([IO.File]::ReadAllBytes($path))
            $after[0] | Should -Be ([char]0xfeff)
            $after | Should -Match '// project comment'
            $after | Should -Match '// external server'
            $after | Should -Match ([regex]::Escape('"description": "literal ,} ,] https://user/*ok*/"'))
            $after | Should -Match ([regex]::Escape('"external": {"url":"https://user.invalid","enabled":false}'))
            $after -replace "`r`n", '' | Should -Not -Match "`n"
            $entries = Read-ItlClientMcpEntries -Client opencode
            $entries.owned.url | Should -Be 'https://itl.invalid'
            $entries.external.enabled | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $root 'opencode.json') | Should -BeFalse
            $state = Read-ItlManagedMcpState
            $rootOwners = ConvertTo-Vibecoding1cMcpHashtable -Object $state.owners
            $pathOwners = ConvertTo-Vibecoding1cMcpHashtable -Object $state.pathOwners
            $physicalOwners = ConvertTo-Vibecoding1cMcpHashtable -Object $pathOwners['opencode/fixture']
            @($rootOwners['opencode/fixture']).Count | Should -Be 0
            @($physicalOwners['.opencode/opencode.jsonc']) | Should -Contain 'owned'
            @(Get-ItlOpenCodeMcpBindings -State $state -OwnerKey 'opencode/fixture' | Where-Object { $_.name -ceq 'owned' -and $_.relativePath -ceq '.opencode/opencode.jsonc' }).Count | Should -Be 1
            $hash = (Get-FileHash -LiteralPath $path).Hash
            Write-ItlClientMcpEndpoints -Client opencode -Owner fixture -Endpoints @([pscustomobject]@{name='owned';url='https://itl.invalid'}) | Out-Null
            (Get-FileHash -LiteralPath $path).Hash | Should -Be $hash
        }
    }

    It 'reads all four native layers without flattening their physical files' {
        $root = New-OpenCodeConfigFixture 'OpenCode четыре слоя'
        Write-OpenCodeFixtureText $root 'opencode.json' '{"mcp":{"same":{"url":"https://root.invalid","headers":{"a":"root","b":"root"}},"rootOnly":{"url":"https://root-only.invalid"}}}'
        Write-OpenCodeFixtureText $root 'opencode.jsonc' '{/* root jsonc */"mcp":{"same":{"headers":{"a":"jsonc"},"enabled":false}}}'
        Write-OpenCodeFixtureText $root '.opencode/opencode.json' '{"mcp":{"same":{"url":"https://nested.invalid","command":["old"]},"nestedOnly":{"url":"https://nested-only.invalid"}}}'
        Write-OpenCodeFixtureText $root '.opencode/opencode.jsonc' '{/* nested wins */"mcp":{"same":{"url":"https://final.invalid","command":["new","arg"],"headers":{"c":"nested"}},}}'
        & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            $before = @(Get-ItlClientMcpConfigPaths -Client opencode | ForEach-Object { (Get-FileHash -LiteralPath $_).Hash }) -join '|'
            $view = Get-ItlOpenCodeMcpView
            $view.entries.same.url | Should -Be 'https://final.invalid'
            $view.entries.same.headers.a | Should -Be 'jsonc'
            $view.entries.same.headers.b | Should -Be 'root'
            $view.entries.same.headers.c | Should -Be 'nested'
            $view.entries.same.enabled | Should -BeFalse
            @($view.entries.same.command) -join '|' | Should -Be 'new|arg'
            @($view.entries.Keys).Count | Should -Be 3
            @($view.provenance.same).Count | Should -Be 4
            @(Get-ItlClientMcpConfigPaths -Client opencode | ForEach-Object { (Get-FileHash -LiteralPath $_).Hash }) -join '|' | Should -Be $before
            Test-Path -LiteralPath (Get-ItlManagedMcpStatePath) | Should -BeFalse
        }
    }

    It 'does not adopt a later foreign same-name key and completes reconciliation after explicit resolution' {
        $root = New-OpenCodeConfigFixture 'OpenCode совпавший чужой ключ'
        Write-OpenCodeFixtureText $root 'opencode.json' '{"mcp":{"owned":{"url":"https://old.invalid","enabled":false,"headers":{"Authorization":"user"}}}}'
        Write-OpenCodeFixtureText $root '.opencode/opencode.jsonc' '{/* foreign override */"mcp":{"owned":{"url":"https://foreign.invalid"}}}'
        Write-OpenCodeFixtureText $root '.agent-1c/mcp/client-managed.json' '{"schemaVersion":1,"owners":{"opencode/fixture":["owned"]}}'
        & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            $paths = @(Get-ItlClientMcpConfigPaths -Client opencode) + @(Get-ItlManagedMcpStatePath)
            $before = @($paths | ForEach-Object { Get-ItlMcpFileState -Path $_ }) -join '|'
            { Write-ItlClientMcpEndpointSet -Requests @([pscustomobject]@{client='opencode';owner='fixture';endpoints=@([pscustomobject]@{name='owned';url='https://new.invalid'})}) } | Should -Throw '*CLIENT_MCP_USER_COLLISION*repeat the original*'
            @($paths | ForEach-Object { Get-ItlMcpFileState -Path $_ }) -join '|' | Should -Be $before
            $nested = Join-Path $root '.opencode/opencode.jsonc'
            # Explicit user resolution preserves the foreign server under a new key.
            $text = [IO.File]::ReadAllText($nested)
            $text = Set-ItlJsoncObjectProperty -Text $text -PropertyPath @('mcp','foreign') -Value (Read-ItlClientMcpEntries -Client opencode).owned
            $text = Remove-ItlJsoncObjectProperty -Text $text -PropertyPath @('mcp','owned')
            Write-Utf8TextAtomic -Path $nested -Value $text
            Write-ItlClientMcpEndpointSet -Requests @([pscustomobject]@{client='opencode';owner='fixture';endpoints=@([pscustomobject]@{name='owned';url='https://new.invalid'})}) | Out-Null
            $entries = Read-ItlClientMcpEntries -Client opencode
            $entries.owned.url | Should -Be 'https://new.invalid'
            $entries.owned.enabled | Should -BeFalse
            $entries.owned.headers.Authorization | Should -Be 'user'
            $entries.foreign.url | Should -Be 'https://foreign.invalid'
            [IO.File]::ReadAllText($nested) | Should -Match '/\* foreign override \*/'
        }
    }

    It 'detaches only proved physical contributions while retaining foreign same-name and shared owners' {
        $root = New-OpenCodeConfigFixture 'OpenCode отключение владельца'
        Write-OpenCodeFixtureText $root 'opencode.json' '{"mcp":{"owned":{"url":"https://itl.invalid"},"shared":{"url":"https://shared.invalid"}}}'
        $foreign = '{/* user file */"mcp":{"owned":{"url":"https://foreign.invalid"}},"theme":"user"}'
        Write-OpenCodeFixtureText $root '.opencode/opencode.jsonc' $foreign
        Write-OpenCodeFixtureText $root '.agent-1c/mcp/client-managed.json' '{"schemaVersion":1,"owners":{"opencode/first":["owned","shared"],"opencode/second":["shared"]}}'
        & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            Write-ItlClientMcpEndpoints -Client opencode -Owner first -Endpoints @() | Out-Null
            [IO.File]::ReadAllText((Join-Path $root '.opencode/opencode.jsonc')) | Should -BeExactly $foreign
            $view = Get-ItlOpenCodeMcpView
            $view.entries.owned.url | Should -Be 'https://foreign.invalid'
            $view.entries.shared.url | Should -Be 'https://shared.invalid'
            $view.layers[0].entries.Contains('owned') | Should -BeFalse
            @(Get-ItlManagedMcpOwnerKeys -Client opencode -Owner first).Count | Should -Be 0
            @(Get-ItlManagedMcpOwnerKeys -Client opencode -Owner second) | Should -Contain 'shared'
        }
    }

    It 'preserves every input when an absent layer appears after preflight and completes on a new plan' {
        $root = New-OpenCodeConfigFixture 'OpenCode поздний новый файл'
        Write-OpenCodeFixtureText $root '.opencode/opencode.jsonc' '{/* existing */"theme":"user"}'
        & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            $original = ${function:Get-ItlMcpFileState}
            $script:lateRootReads = 0
            function Get-ItlMcpFileState {
                param([string]$Path)
                if ($Path -eq (Join-Path $script:ProjectRoot 'opencode.json')) {
                    $script:lateRootReads++
                    if ($script:lateRootReads -eq 2) { [IO.File]::WriteAllText($Path, '{"description":"late user"}', [Text.UTF8Encoding]::new($false)) }
                }
                & $original -Path $Path
            }
            $nested = Join-Path $root '.opencode/opencode.jsonc'
            $before = (Get-FileHash -LiteralPath $nested).Hash
            $request = @([pscustomobject]@{client='opencode';owner='fixture';endpoints=@([pscustomobject]@{name='owned';url='https://itl.invalid'})})
            { Write-ItlClientMcpEndpointSet -Requests $request } | Should -Throw '*CLIENT_MCP_FINAL_SET_CHANGED*'
            (Get-FileHash -LiteralPath $nested).Hash | Should -Be $before
            Test-Path -LiteralPath (Get-ItlManagedMcpStatePath) | Should -BeFalse
            [IO.File]::ReadAllText((Join-Path $root 'opencode.json')) | Should -BeExactly '{"description":"late user"}'
            Set-Item -LiteralPath function:Get-ItlMcpFileState -Value $original
            Write-ItlClientMcpEndpointSet -Requests $request | Out-Null
            (Read-ItlClientMcpEntries -Client opencode).owned.url | Should -Be 'https://itl.invalid'
        }
    }

    It 'updates only managed transport fields while preserving inline policy comments and headers' {
        $root = New-OpenCodeConfigFixture 'OpenCode локальная запись с политикой'
        $before = '{"mcp":{"owned":{"type":"local", "command":["old"], /* keep auth comment */ "headers":{"A":"a,}"}, "enabled":false, "timeout":120000}},"outside":"untouched"}'
        Write-OpenCodeFixtureText $root '.opencode/opencode.jsonc' $before
        Write-OpenCodeFixtureText $root '.agent-1c/mcp/client-managed.json' '{"schemaVersion":1,"owners":{"opencode/fixture":[]},"pathOwners":{"opencode/fixture":{".opencode/opencode.jsonc":["owned"]}}}'
        & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            Write-ItlClientMcpEndpoints -Client opencode -Owner fixture -Endpoints @([pscustomobject]@{name='owned';url='https://new.invalid'}) | Out-Null
            $text = [IO.File]::ReadAllText((Join-Path $root '.opencode/opencode.jsonc'))
            $text | Should -Match ([regex]::Escape('/* keep auth comment */ "headers":{"A":"a,}"}, "enabled":false'))
            $text | Should -Match ([regex]::Escape('"outside":"untouched"'))
            $entries = Read-ItlClientMcpEntries -Client opencode
            $entries.owned.url | Should -Be 'https://new.invalid'
            $entries.owned.Contains('command') | Should -BeFalse
            $entries.owned.enabled | Should -BeFalse
        }
    }

    It 'binds the actual changed path for tracked refusal and completes after explicit supported untracking' {
        $root = New-OpenCodeConfigFixture 'OpenCode tracked и readonly слои'
        Write-OpenCodeFixtureText $root 'opencode.json' '{"description":"tracked read-only input"}'
        Write-OpenCodeFixtureText $root '.opencode/opencode.jsonc' '{/* tracked writer */"theme":"user"}'
        & git -C $root init *> $null
        & git -C $root config user.email 'test@example.com'
        & git -C $root config user.name 'Test User'
        & git -C $root add -- opencode.json .opencode/opencode.jsonc
        & git -C $root commit -m base *> $null
        & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            $rootBefore = (Get-FileHash -LiteralPath (Join-Path $root 'opencode.json')).Hash
            { Assert-ItlClientConfigWritable -Client opencode } | Should -Throw '*TRACKED_CLIENT_CONFIG*.opencode/opencode.jsonc*'
            { Write-ItlClientMcpEndpoints -Client opencode -Owner fixture -Endpoints @([pscustomobject]@{name='owned';url='https://itl.invalid'}) } | Should -Throw '*TRACKED_CLIENT_CONFIG*.opencode/opencode.jsonc*'
            & git -C $root rm --cached -- .opencode/opencode.jsonc *> $null
            { Assert-ItlClientConfigWritable -Client opencode } | Should -Not -Throw
            Write-ItlClientMcpEndpoints -Client opencode -Owner fixture -Endpoints @([pscustomobject]@{name='owned';url='https://itl.invalid'}) | Out-Null
            (Get-FileHash -LiteralPath (Join-Path $root 'opencode.json')).Hash | Should -Be $rootBefore
            (Read-ItlClientMcpEntries -Client opencode).owned.url | Should -Be 'https://itl.invalid'
        }
    }

    It 'transfers nested ownership in <Order> order without moving the path or losing user policy' -ForEach @(@{Order='release-first'},@{Order='receive-first'}) {
        $root = New-OpenCodeConfigFixture ('OpenCode передача '+$Order)
        $owned = '{"mcp":{"owned":{"type":"remote","url":"https://old.invalid", /* keep auth */ "headers":{"Authorization":"user"}, "enabled":false, "timeout":120000}}}'
        $late = '{/* later tracked user layer */"theme":"user"}'
        Write-OpenCodeFixtureText $root '.opencode/opencode.json' $owned
        Write-OpenCodeFixtureText $root '.opencode/opencode.jsonc' $late
        Write-OpenCodeFixtureText $root '.agent-1c/mcp/client-managed.json' '{"schemaVersion":1,"owners":{"opencode/first":[]},"pathOwners":{"opencode/first":{".opencode/opencode.json":["owned"]}}}'
        & git -C $root init *> $null
        & git -C $root config user.email 'test@example.com'
        & git -C $root config user.name 'Test User'
        & git -C $root add -- .opencode/opencode.jsonc
        & git -C $root commit -m base *> $null
        & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            $release = [pscustomobject]@{client='opencode';owner='first';endpoints=@()}
            $receive = [pscustomobject]@{client='opencode';owner='second';endpoints=@([pscustomobject]@{name='owned';url='https://new.invalid'})}
            $requests = if ($Order -eq 'release-first') { @($release,$receive) } else { @($receive,$release) }
            Write-ItlClientMcpEndpointSet -Requests $requests | Out-Null
            [IO.File]::ReadAllText((Join-Path $root '.opencode/opencode.jsonc')) | Should -BeExactly $late
            [IO.File]::ReadAllText((Join-Path $root '.opencode/opencode.json')) | Should -Match ([regex]::Escape('/* keep auth */ "headers":{"Authorization":"user"}, "enabled":false'))
            $entries = Read-ItlClientMcpEntries -Client opencode
            $entries.owned.url | Should -Be 'https://new.invalid'
            $entries.owned.enabled | Should -BeFalse
            $entries.owned.headers.Authorization | Should -Be 'user'
            @(Get-ItlManagedMcpOwnerKeys -Client opencode -Owner first).Count | Should -Be 0
            $bindings = @(Get-ItlOpenCodeMcpBindings -State (Read-ItlManagedMcpState) -OwnerKey 'opencode/second')
            $bindings.Count | Should -Be 1
            $bindings[0].relativePath | Should -Be '.opencode/opencode.json'
            Test-Path -LiteralPath (Join-Path $root 'opencode.json') | Should -BeFalse
        }
    }

    It 'retains releasing ownership after an interrupted handoff and completes the same final set' {
        $root = New-OpenCodeConfigFixture 'OpenCode прерванная передача'
        $before = '{/* retained original */"mcp":{"owned":{"url":"https://old.invalid","enabled":false,"headers":{"A":"user"}}}}'
        Write-OpenCodeFixtureText $root '.opencode/opencode.json' $before
        Write-OpenCodeFixtureText $root '.opencode/opencode.jsonc' '{"theme":"user"}'
        Write-OpenCodeFixtureText $root '.agent-1c/mcp/client-managed.json' '{"schemaVersion":1,"owners":{"opencode/first":[]},"pathOwners":{"opencode/first":{".opencode/opencode.json":["owned"]}}}'
        & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            $originalWriter = ${function:Write-Utf8TextAtomic}
            function Write-Utf8TextAtomic {
                param([string]$Path,[string]$Value)
                if ($Path -eq (Join-Path $script:ProjectRoot '.opencode/opencode.json')) { throw 'fixture receiving write interrupted' }
                & $originalWriter -Path $Path -Value $Value
            }
            $requests = @([pscustomobject]@{client='opencode';owner='first';endpoints=@()},[pscustomobject]@{client='opencode';owner='second';endpoints=@([pscustomobject]@{name='owned';url='https://new.invalid'})})
            { Write-ItlClientMcpEndpointSet -Requests $requests } | Should -Throw '*receiving write interrupted*'
            [IO.File]::ReadAllText((Join-Path $root '.opencode/opencode.json')) | Should -BeExactly $before
            @(Get-ItlManagedMcpOwnerKeys -Client opencode -Owner first) | Should -Contain 'owned'
            Set-Item -LiteralPath function:Write-Utf8TextAtomic -Value $originalWriter
            Write-ItlClientMcpEndpointSet -Requests $requests | Out-Null
            (Read-ItlClientMcpEntries -Client opencode).owned.url | Should -Be 'https://new.invalid'
            (Read-ItlClientMcpEntries -Client opencode).owned.enabled | Should -BeFalse
            (Read-ItlClientMcpEntries -Client opencode).owned.headers.A | Should -Be 'user'
            @(Get-ItlManagedMcpOwnerKeys -Client opencode -Owner first).Count | Should -Be 0
            @(Get-ItlManagedMcpOwnerKeys -Client opencode -Owner second) | Should -Contain 'owned'
        }
    }

    It 'preserves an ownership edit between capture and parse then completes on a fresh plan' {
        $root = New-OpenCodeConfigFixture 'OpenCode поздний чужой владелец'
        Write-OpenCodeFixtureText $root '.opencode/opencode.jsonc' '{/* original */"theme":"user"}'
        Write-OpenCodeFixtureText $root '.agent-1c/mcp/client-managed.json' '{"schemaVersion":1,"owners":{}}'
        & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            $originalReader = ${function:Read-ItlManagedMcpState}
            $script:injectOwner = $true
            function Read-ItlManagedMcpState {
                $state = & $originalReader
                if ($script:injectOwner) {
                    $script:injectOwner = $false
                    [IO.File]::WriteAllText((Get-ItlManagedMcpStatePath), '{"schemaVersion":1,"owners":{"opencode/foreign":["foreign"]}}', [Text.UTF8Encoding]::new($false))
                }
                return $state
            }
            $before = (Get-FileHash -LiteralPath (Join-Path $root '.opencode/opencode.jsonc')).Hash
            { Write-ItlClientMcpEndpoints -Client opencode -Owner fixture -Endpoints @([pscustomobject]@{name='owned';url='https://itl.invalid'}) } | Should -Throw '*CLIENT_MCP_FINAL_SET_CHANGED*ownership changed*repeat the original*'
            (Get-FileHash -LiteralPath (Join-Path $root '.opencode/opencode.jsonc')).Hash | Should -Be $before
            @(Get-ItlManagedMcpOwnerKeys -Client opencode -Owner foreign) | Should -Contain 'foreign'
            Set-Item -LiteralPath function:Read-ItlManagedMcpState -Value $originalReader
            Write-ItlClientMcpEndpoints -Client opencode -Owner fixture -Endpoints @([pscustomobject]@{name='owned';url='https://itl.invalid'}) | Out-Null
            @(Get-ItlManagedMcpOwnerKeys -Client opencode -Owner foreign) | Should -Contain 'foreign'
            (Read-ItlClientMcpEntries -Client opencode).owned.url | Should -Be 'https://itl.invalid'
        }
    }

    It 'keeps a confirmed first physical write owned when a later write fails and resumes the same command' {
        $root = New-OpenCodeConfigFixture 'OpenCode прерванные две записи'
        Write-OpenCodeFixtureText $root 'opencode.json' '{"mcp":{"rootOwned":{"url":"https://old-root.invalid"}}}'
        $nested = '{/* keep nested */"mcp":{"nestedOwned":{"url":"https://old-nested.invalid"}},"theme":"user"}'
        Write-OpenCodeFixtureText $root '.opencode/opencode.jsonc' $nested
        Write-OpenCodeFixtureText $root '.agent-1c/mcp/client-managed.json' '{"schemaVersion":1,"owners":{"opencode/fixture":["rootOwned"]},"pathOwners":{"opencode/fixture":{".opencode/opencode.jsonc":["nestedOwned"]}}}'
        & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            $originalWriter = ${function:Write-Utf8TextAtomic}
            function Write-Utf8TextAtomic {
                param([string]$Path,[string]$Value)
                if ($Path -eq (Join-Path $script:ProjectRoot '.opencode/opencode.jsonc')) { throw 'fixture second physical write interrupted' }
                & $originalWriter -Path $Path -Value $Value
            }
            $endpoints = @([pscustomobject]@{name='rootOwned';url='https://new-root.invalid'},[pscustomobject]@{name='nestedOwned';url='https://new-nested.invalid'})
            { Write-ItlClientMcpEndpoints -Client opencode -Owner fixture -Endpoints $endpoints } | Should -Throw '*second physical write interrupted*'
            (Read-ItlClientMcpEntries -Client opencode).rootOwned.url | Should -Be 'https://new-root.invalid'
            [IO.File]::ReadAllText((Join-Path $root '.opencode/opencode.jsonc')) | Should -BeExactly $nested
            @(Get-ItlManagedMcpOwnerKeys -Client opencode -Owner fixture) | Should -Contain 'rootOwned'
            @(Get-ItlManagedMcpOwnerKeys -Client opencode -Owner fixture) | Should -Contain 'nestedOwned'
            Set-Item -LiteralPath function:Write-Utf8TextAtomic -Value $originalWriter
            Write-ItlClientMcpEndpoints -Client opencode -Owner fixture -Endpoints $endpoints | Out-Null
            (Read-ItlClientMcpEntries -Client opencode).nestedOwned.url | Should -Be 'https://new-nested.invalid'
            [IO.File]::ReadAllText((Join-Path $root '.opencode/opencode.jsonc')) | Should -Match '/\* keep nested \*/'
        }
    }

    It 'preserves nested future bindings during a recorded root-only operation' {
        $root = New-OpenCodeConfigFixture 'OpenCode старый target'
        $nested = '{"mcp":{"future":{"url":"https://future.invalid"}}}'
        Write-OpenCodeFixtureText $root '.opencode/opencode.jsonc' $nested
        Write-OpenCodeFixtureText $root '.agent-1c/mcp/client-managed.json' '{"schemaVersion":1,"owners":{"opencode/fixture":[]},"pathOwners":{"opencode/fixture":{".opencode/opencode.jsonc":["future"]}}}'
        & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            $script:ItlOpenCodeOperationConfigPathsMode = 'legacy-root'
            @(Get-ItlClientMcpConfigPaths -Client opencode).Count | Should -Be 4
            @(Get-ItlOpenCodeOperationConfigPaths).Count | Should -Be 1
            Write-ItlClientMcpEndpoints -Client opencode -Owner fixture -Endpoints @([pscustomobject]@{name='owned';url='https://itl.invalid'}) | Out-Null
            [IO.File]::ReadAllText((Join-Path $root '.opencode/opencode.jsonc')) | Should -BeExactly $nested
            (Read-ItlClientMcpEntries -Client opencode).Contains('future') | Should -BeFalse
            @(Get-ItlManagedMcpOwnerKeys -Client opencode -Owner fixture) | Should -Contain 'future'
            Remove-Variable -Name ItlOpenCodeOperationConfigPathsMode -Scope Script
            (Read-ItlClientMcpEntries -Client opencode).future.url | Should -Be 'https://future.invalid'
        }
    }
}
