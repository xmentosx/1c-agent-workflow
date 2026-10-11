BeforeAll {
    $RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    . (Join-Path $RepoRoot 'scripts/quality-contracts.ps1')
    $catalog = Get-QualityContractCatalog -RepositoryRoot $RepoRoot
}

Describe 'Independent host component source verification' {
    It 'selects independent verification for <Component>' -ForEach @(
        @{ Component='Mantis'; Path='vibecoding1c-mcp-host/mantis-ticket-mcp/mantis_index.py'; Test='HostMantis' }
        @{ Component='BookStack'; Path='vibecoding1c-mcp-host/bookstack-product-docs-mcp/server.py'; Test='HostBookStack' }
        @{ Component='CodeChecker'; Path='vibecoding1c-mcp-host/codechecker-overlay/retry_policy.py'; Test='HostCodeChecker' }
        @{ Component='CodeChecker beta'; Path='vibecoding1c-mcp-host/codechecker-beta-overlay/patch_mcp_server.py'; Test='HostCodeChecker' }
        @{ Component='SPPR'; Path='vibecoding1c-mcp-host/sppr-mcp/sppr_service.py'; Test='HostSppr' }
        @{ Component='Node proxy'; Path='vibecoding1c-mcp-host/tools-list-proxy/tools-list-proxy.js'; Test='HostToolsProxy' }
        @{ Component='Linux host'; Path='vibecoding1c-mcp-host/linux-native-host/watchdog.py'; Test='HostLinux' }
        @{ Component='ChatGPT guide'; Path='docs/itl-workflow/CHATGPT.ru.md'; Expected=@('tests/pester/ChatGptSourcePolicy.Tests.ps1','tests/pester/ParserDocsBudgets.Tests.ps1') }
        @{ Component='ChatGPT bootstrap'; Path='.agents/skills/1c-workflow/chatgpt/bootstrap-prompt.ru.md'; Expected=@('tests/pester/ChatGptSourcePolicy.Tests.ps1','tests/pester/ChatGptInstall.Tests.ps1') }
        @{ Component='ChatGPT bridge'; Path='.agents/skills/1c-workflow/chatgpt/mcp_bridge.py'; Expected=@('tests/pester/ChatGptBridge.Tests.ps1','tests/pester/ChatGptSourcePolicy.Tests.ps1','tests/pester/ChatGptInstall.Tests.ps1') }
    ) {
        param($Component, $Path, $Test, $Expected)
        $selection = Resolve-QualityContractsForPaths -Catalog $catalog -Paths @($Path)
        @($selection.unknownPaths) | Should -BeNullOrEmpty
        $expectedTests = if ($Expected) { @($Expected) | Sort-Object } else { @(
            "tests/pester/$Test.Tests.ps1",
            'tests/pester/HostTooling.Tests.ps1'
        ) | Sort-Object }
        @($selection.tests | Sort-Object) | Should -Be @($expectedTests)
    }

    It 'keeps the real shared installer consumers selected' {
        $selection = Resolve-QualityContractsForPaths -Catalog $catalog -Paths @('vibecoding1c-mcp-host/install-vibecoding1c-mcp-host.ps1')
        @($selection.unknownPaths) | Should -BeNullOrEmpty
        @($selection.tests | Sort-Object) | Should -Be @(
            'tests/pester/ChatGptBridge.Tests.ps1',
            'tests/pester/HostBookStack.Tests.ps1',
            'tests/pester/HostCodeChecker.Tests.ps1',
            'tests/pester/HostLinux.Tests.ps1',
            'tests/pester/HostMantis.Tests.ps1',
            'tests/pester/HostNativeTransport.Tests.ps1',
            'tests/pester/HostSourceRuntime.Tests.ps1',
            'tests/pester/HostSppr.Tests.ps1',
            'tests/pester/HostTestSelection.Tests.ps1',
            'tests/pester/HostTooling.Tests.ps1'
        )
    }

    It 'keeps documentation-only selection independent of host runtimes' {
        $selection = Resolve-QualityContractsForPaths -Catalog $catalog -Paths @('docs/source-planning.md')
        @($selection.tests) | Should -Be @('tests/pester/ParserDocsBudgets.Tests.ps1')
        @($selection.unknownPaths) | Should -BeNullOrEmpty
    }

    It 'does not qualify reusable host suite proof with unknown external runtime identity' {
        $tokens=$null; $errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'scripts/invoke-pester-shards.ps1'),[ref]$tokens,[ref]$errors)
        @($errors) | Should -BeNullOrEmpty
        foreach($name in @('Get-ShardRelativeTestPath','Get-ShardInputDigest')) {
            $definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true)
            $definition | Should -Not -BeNullOrEmpty
            . ([scriptblock]::Create($definition.Extent.Text))
        }
        $RepositoryRoot=$RepoRoot
        foreach($name in @('HostNativeTransport','HostLinux','HostCodeChecker','HostToolsProxy','HostBookStack','HostMantis','HostSppr','HostSourceRuntime','ChatGptBridge','ChatGptInstall','ChatGptSourcePolicy')) {
            $path=Join-Path $RepoRoot "tests/pester/$name.Tests.ps1"
            Get-ShardInputDigest -Paths @($path) | Should -BeNullOrEmpty
        }
    }
}
