Describe 'ZCode and MiMo Code project adapters' {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $helperPath = Join-Path $repoRoot '.agents\skills\1c-workflow\scripts\agent-1c.ps1'
    }

    It 'reports twelve concrete clients without claiming a configured file proves runtime callability' {
        $root = Join-Path $TestDrive ('Capability project ' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path (Join-Path $root '.agent-1c') | Out-Null
        [IO.File]::WriteAllText((Join-Path $root '.agent-1c/project.json'), '{"aiRules":{"tools":["zcode","mimocode","cline"]}}', [Text.UTF8Encoding]::new($false))
        $reports = & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            [pscustomobject]@{
                count = @(Get-SupportedAgentTargets).Count
                zcode = Get-ItlClientCapabilityReport -Client zcode
                mimo = Get-ItlClientCapabilityReport -Client mimocode
                cline = Get-ItlClientCapabilityReport -Client cline
            }
        }
        $reports.count | Should -Be 12
        $reports.zcode.mcp | Should -Match 'mcp.servers'
        $reports.mimo.mcp | Should -Match '\.mimocode/mimocode.json'
        $reports.cline.runtimeVariant | Should -Match 'CLI.*editor'
        $reports.zcode.evidence | Should -Match 'static'
        $reports.mimo.model | Should -Match 'unverified'
    }

    It 'keeps user JSON while rendering the native nested ZCode MCP schema' {
        $root = Join-Path $TestDrive ('ZCode проект ' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path (Join-Path $root '.agent-1c') | Out-Null
        [IO.File]::WriteAllText((Join-Path $root '.agent-1c/project.json'), '{"aiRules":{"tools":["zcode"]}}', [Text.UTF8Encoding]::new($false))
        $configPath = Join-Path $root '.zcode/config.json'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $configPath) | Out-Null
        [IO.File]::WriteAllText($configPath, '{"keep":"user","mcp":{"keep":"nested","servers":{"custom":{"type":"http","url":"https://custom.invalid"}}}}', [Text.UTF8Encoding]::new($false))
        $result = & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            $endpoints = @(
                [pscustomobject]@{ name='itl-local'; command='C:\Путь с пробелами\mcp.exe'; args=@('--safe'); transport='stdio' },
                [pscustomobject]@{ name='itl-remote'; url='https://itl.invalid/mcp'; transport='remote' }
            )
            Write-ItlClientMcpEndpoints -Client zcode -Owner test -Endpoints $endpoints | Out-Null
            $firstText = Read-Utf8Text -Path $configPath
            Write-ItlClientMcpEndpoints -Client zcode -Owner test -Endpoints $endpoints | Out-Null
            [pscustomobject]@{ entries = Read-ItlClientMcpEntries -Client zcode; firstText = $firstText; secondText = (Read-Utf8Text -Path $configPath) }
        }
        $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $config.keep | Should -Be 'user'
        $config.mcp.keep | Should -Be 'nested'
        $config.mcp.servers.custom.url | Should -Be 'https://custom.invalid'
        $config.mcp.servers.'itl-local'.type | Should -Be 'stdio'
        $config.mcp.servers.'itl-local'.command | Should -Be 'C:\Путь с пробелами\mcp.exe'
        $config.mcp.servers.'itl-remote'.type | Should -Be 'http'
        @($result.entries.Keys) | Should -Contain 'custom'
        $result.secondText | Should -BeExactly $result.firstText
    }

    It 'uses MiMo project configuration and preserves user settings and MCP servers' {
        $root = Join-Path $TestDrive ('MiMo проект ' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path (Join-Path $root '.agent-1c') | Out-Null
        [IO.File]::WriteAllText((Join-Path $root '.agent-1c/project.json'), '{"aiRules":{"tools":["mimocode"]}}', [Text.UTF8Encoding]::new($false))
        $configPath = Join-Path $root '.mimocode/mimocode.json'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $configPath) | Out-Null
        [IO.File]::WriteAllText($configPath, '{"model":"user-model","mcp":{"custom":{"type":"remote","url":"https://custom.invalid"}}}', [Text.UTF8Encoding]::new($false))
        & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            Write-ItlClientMcpEndpoints -Client mimocode -Owner test -Endpoints @([pscustomobject]@{ name='itl-remote'; url='https://itl.invalid/mcp'; transport='remote' }) | Out-Null
        }
        $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $config.model | Should -Be 'user-model'
        $config.mcp.custom.url | Should -Be 'https://custom.invalid'
        $config.mcp.'itl-remote'.type | Should -Be 'remote'
        $config.mcp.'itl-remote'.enabled | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $root 'mimocode.json') | Should -BeFalse
    }

    It 'preserves an existing MiMo JSONC config instead of writing a competing JSON file' {
        $root = Join-Path $TestDrive ('MiMo JSONC ' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path (Join-Path $root '.agent-1c'),(Join-Path $root '.mimocode') | Out-Null
        [IO.File]::WriteAllText((Join-Path $root '.agent-1c/project.json'), '{"aiRules":{"tools":["mimocode"]}}', [Text.UTF8Encoding]::new($false))
        $jsoncPath = Join-Path $root '.mimocode/mimocode.jsonc'
        [IO.File]::WriteAllText($jsoncPath, "{ // user comment`n  `"model`": `"custom`"`n}", [Text.UTF8Encoding]::new($false))
        $before = (Get-FileHash -LiteralPath $jsoncPath -Algorithm SHA256).Hash
        $message = & {
            . $helperPath -ProjectRoot $root -Action help *> $null
            try { Write-ItlClientMcpEndpoints -Client mimocode -Owner test -Endpoints @([pscustomobject]@{ name='itl'; url='https://itl.invalid'; transport='remote' }) | Out-Null }
            catch { $_.Exception.Message }
        }
        $message | Should -Match 'MIMOCODE_CONFIG_COLLISION'
        (Get-FileHash -LiteralPath $jsoncPath -Algorithm SHA256).Hash | Should -Be $before
        Test-Path -LiteralPath (Join-Path $root '.mimocode/mimocode.json') | Should -BeFalse
    }
}
