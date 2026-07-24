Describe "ITL on-demand MCP facade" {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        $RepoRoot = $context.RepoRoot
        $HelperPath = $context.HelperPath
        $AssetRoot = Join-Path $RepoRoot ".agents\skills\1c-workflow\assets\ondemand-mcp"
        . (Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.ondemand-mcp.ps1")
        $ModuleFixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-ondemand-module-fixture-" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Force -Path (Join-Path $ModuleFixtureRoot ".agent-1c") | Out-Null
        Set-Content -LiteralPath (Join-Path $ModuleFixtureRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"aiRules":{"tools":["codex"]}}'
        . $HelperPath -ProjectRoot $ModuleFixtureRoot -Action help *> $null
    }

    AfterAll {
        Remove-Item -LiteralPath $ModuleFixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "pins hash-verified full catalogs to compatible backend versions" {
        $manifest = Get-Content -LiteralPath (Join-Path $AssetRoot "compatibility.json") -Raw -Encoding UTF8 | ConvertFrom-Json
        $manifest.facadeVersion | Should -Be "0.4.0"
        $manifest.minimumFacadeVersion | Should -Be "0.4.0"
        $mainSource = Get-Content -LiteralPath (Join-Path $RepoRoot "tools\itl-ondemand-mcp\main.go") -Raw -Encoding UTF8
        $gatewaySource = Get-Content -LiteralPath (Join-Path $RepoRoot "tools\itl-ondemand-mcp\gateway.go") -Raw -Encoding UTF8
        $mainSource | Should -Match 'const version = "0\.4\.0"'
        $mainSource | Should -Match '"gateway"'
        $gatewaySource | Should -Match 'gatewayResolveTool\s*=\s*"resolve_tool"'
        $gatewaySource | Should -Match 'gatewayCallTool\s*=\s*"call_tool"'
        $manifest.families.roctup.backendVersions.roctup | Should -Be "v1.7.1"
        $manifest.families.'vanessa-ui'.backendVersions.clientMcp | Should -Be "v0.6.5"
        $manifest.families.'vanessa-ui'.backendVersions.vaExtension | Should -Be "1.2.043.28"
        $manifest.families.'vanessa-ui'.backendVersions.vanessaAutomation | Should -Be "1.2.043.28"
        $manifest.families.'vanessa-ui'.backendRevisions.vanessaAutomation | Should -Be "itl-r1"
        $manifest.families.'vanessa-ui'.vanessaAutomationArtifact.archiveSha256 | Should -Be "fae6ff06a66e5fa3fe315585ec5c5e678724edcd75fff97069f6dd224b86b9b6"
        $manifest.families.'vanessa-ui'.vanessaAutomationArtifact.epfSha256 | Should -Be "260605fd71adf1d2d354b8d1ce3ca7e2ce222db7c79d21f6cb44885aff1b5b80"
        $manifest.families.'vanessa-ui'.backendVersions.vanessaExt | Should -Be "1.3.9.131"
        $manifest.families.'vanessa-ui'.embeddedDependencies.vanessaExt.version | Should -Be "1.3.9.131"
        $manifest.families.'vanessa-ui'.embeddedDependencies.vanessaExt.sha256 | Should -Match '^[0-9a-f]{64}$'
        $lock = Get-Content -LiteralPath (Join-Path $RepoRoot "templates\dependency-lock.json") -Raw -Encoding UTF8 | ConvertFrom-Json
        [string]$lock.dependencies.itlOndemandMcp.sha256 | Should -Be "0083ab7960d1d6507f418aad64a6715df185c947cef37089043022754f1fe131"
        [string]$lock.dependencies.itlOndemandMcp.sha256 | Should -Not -Be "667f0651a9d87f17a7db584ccaf754a2150ab371e88c88af59428eaedf2b2ced"
        foreach ($family in @("roctup", "vanessa-ui")) {
            $definition = $manifest.families.$family
            $catalogPath = Join-Path $AssetRoot ([string]$definition.catalog)
            (Get-ItlOnDemandCatalogCanonicalSha256 -Path $catalogPath) | Should -Be ([string]$definition.catalogSha256)
            $catalog = Get-Content -LiteralPath $catalogPath -Raw -Encoding UTF8 | ConvertFrom-Json
            @($catalog.tools).Count | Should -Be $(if ($family -eq "roctup") { 13 } else { 38 })
            @($catalog.tools.name | Sort-Object -Unique).Count | Should -Be @($catalog.tools).Count
            foreach ($tool in @($catalog.tools)) {
                [string]$tool.name | Should -Not -BeNullOrEmpty
                $null -eq $tool.inputSchema | Should -BeFalse
            }
        }
    }

    It "keeps parallel worker facade installs in GUID temp roots" {
        $moduleText = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.ondemand-mcp.ps1") -Raw -Encoding UTF8
        $workerText = Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\run-pester-shard.ps1") -Raw -Encoding UTF8
        $moduleText | Should -Match 'ITL_ONDEMAND_MCP_INSTALL_ROOT'
        $workerText | Should -Match 'itl-pester-worker-'
        $workerText | Should -Match 'ITL_ONDEMAND_MCP_INSTALL_ROOT'
        $workerText | Should -Match 'Remove-Item -LiteralPath \$fixtureRuntimeRoot -Recurse'
    }

    It "keeps catalog identity stable across Windows and Unix line endings" {
        $sourcePath = Join-Path $AssetRoot "catalogs\roctup-v1.7.1.json"
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-ondemand-line-endings-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            $text = [IO.File]::ReadAllText($sourcePath).Replace("`r`n", "`n").Replace("`r", "`n")
            $lfPath = Join-Path $tempRoot "lf.json"
            $crlfPath = Join-Path $tempRoot "crlf.json"
            [IO.File]::WriteAllText($lfPath, $text, (New-Object Text.UTF8Encoding $false))
            [IO.File]::WriteAllText($crlfPath, $text.Replace("`n", "`r`n"), (New-Object Text.UTF8Encoding $false))
            Get-ItlOnDemandCatalogCanonicalSha256 -Path $lfPath | Should -Be (Get-ItlOnDemandCatalogCanonicalSha256 -Path $crlfPath)
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "publishes the exact hash-locked Windows facade asset from a matching tag" {
        $workflowPath = Join-Path $RepoRoot ".github\workflows\release-ondemand-mcp.yml"
        $workflow = Get-Content -LiteralPath $workflowPath -Raw -Encoding UTF8
        $lock = Get-Content -LiteralPath (Join-Path $RepoRoot "templates\dependency-lock.json") -Raw -Encoding UTF8 | ConvertFrom-Json
        $workflow | Should -Match 'itl-ondemand-mcp-v\*'
        $workflow | Should -Match 'scripts\\Build-ItlOnDemandMcp\.ps1'
        $buildScript = Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\Build-ItlOnDemandMcp.ps1") -Raw
        $buildScript | Should -Match '\$env:CGO_ENABLED\s*=\s*"0"'
        $buildScript | Should -Match '\$env:GOAMD64\s*=\s*"v1"'
        $buildScript | Should -Match '\[guid\]::NewGuid'
        $buildScript | Should -Match 'Move-Item\s+-LiteralPath\s+\$temporaryOutputPath\s+-Destination\s+\$OutputPath\s+-Force'
        $workflow | Should -Match 'result\.sha256'
        $workflow | Should -Match 'dependency-lock\.json'
        $workflow | Should -Match 'softprops/action-gh-release@v2'
        $workflow | Should -Match 'itl-ondemand-mcp-windows-amd64\.exe'

        $buildResult = @(& (Join-Path $RepoRoot "scripts\Build-ItlOnDemandMcp.ps1") -SkipTests)
        $repeatBuildResult = @(& (Join-Path $RepoRoot "scripts\Build-ItlOnDemandMcp.ps1") -SkipTests)
        $buildResult.Count | Should -Be 1
        $repeatBuildResult.Count | Should -Be 1
        $buildResult[0].path | Should -Be (Join-Path $RepoRoot "tools\itl-ondemand-mcp\build\itl-ondemand-mcp-windows-amd64.exe")
        $buildResult[0].sha256 | Should -Be ([string]$lock.dependencies.itlOndemandMcp.sha256)
        $repeatBuildResult[0].sha256 | Should -Be $buildResult[0].sha256
    }

    It "uses the compatibility manifest instead of an unsupported upstream latest in fresh mode" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-ondemand-fresh-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"aiRules":{"tools":["codex"]}}'
            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                function Get-DependencyMode { "fresh" }
                function Get-DependencyLockEntry { param([string]$Name); [pscustomobject]@{ version = "v999"; assetName = "MCP_Toolkit.epf"; url = "https://invalid"; sha256 = "aa" } }
                function Get-GitHubReleaseAssetInfo { throw "must not query latest" }
                try { Get-RoctupMcpReleaseAssetInfo | Out-Null; "accepted" } catch { $_.Exception.Message }
            }
            $result | Should -Match "ITL_ONDEMAND_BACKEND_UNSUPPORTED"
            $result | Should -Not -Match "must not query latest"
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "synchronizes an installed fresh lock to the canonical facade release" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-ondemand-lock-sync-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"dependencyMode":"fresh","aiRules":{"tools":["kilocode"]}}'
            $oldLock = Get-Content -LiteralPath (Join-Path $RepoRoot "templates\dependency-lock.json") -Raw -Encoding UTF8 | ConvertFrom-Json
            $oldLock.dependencies.itlOndemandMcp.version = "0.3.1"
            $oldLock.dependencies.itlOndemandMcp.url = "https://example.invalid/itl-ondemand-mcp-v0.3.1.exe"
            $oldLock.dependencies.itlOndemandMcp.sha256 = ("b" * 64)
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\dependency-lock.json") -Encoding UTF8 -Value ($oldLock | ConvertTo-Json -Depth 10)

            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                Sync-ItlOnDemandMcpDependencyLock *> $null
                Read-DependencyLockManifest
            }
            $canonical = Get-Content -LiteralPath (Join-Path $RepoRoot "templates\dependency-lock.json") -Raw -Encoding UTF8 | ConvertFrom-Json
            $result.dependencies.itlOndemandMcp.version | Should -Be $canonical.dependencies.itlOndemandMcp.version
            $result.dependencies.itlOndemandMcp.url | Should -Be $canonical.dependencies.itlOndemandMcp.url
            $result.dependencies.itlOndemandMcp.sha256 | Should -Be $canonical.dependencies.itlOndemandMcp.sha256
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "installs from the cached release asset when the workflow is an installed copy without Git metadata" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-ondemand-installed-copy-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agents\skills") | Out-Null
            Copy-Item -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow") -Destination (Join-Path $tempRoot ".agents\skills\1c-workflow") -Recurse -Force
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"aiRules":{"tools":["kilocode"]}}'
            $installedHelper = Join-Path $tempRoot ".agents\skills\1c-workflow\scripts\agent-1c.ps1"

            $result = & {
                . $installedHelper -ProjectRoot $tempRoot -Action help *> $null
                $installRoot = Join-Path $tempRoot "localapp\ondemand"
                function Get-ItlOnDemandMcpInstallRoot { return $installRoot }

                $version = "0.4.0"
                $assetName = "itl-ondemand-mcp-windows-amd64.exe"
                $targetDirectory = Join-Path $installRoot $version
                $targetPath = Join-Path $targetDirectory $assetName
                New-Item -ItemType Directory -Force -Path $targetDirectory | Out-Null
                Set-Content -LiteralPath $targetPath -Encoding Byte -Value ([byte[]](1, 2, 3, 4))
                $sha256 = (Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash.ToLowerInvariant()
                function Get-DependencyLockEntry {
                    param([string]$Name)
                    return [pscustomobject]@{
                        version = $version
                        assetName = $assetName
                        url = "https://example.invalid/itl-ondemand-mcp.exe"
                        sha256 = $sha256
                    }
                }

                Install-ItlOnDemandMcp
            }

            $result.path | Should -Be (Join-Path $tempRoot "localapp\ondemand\0.4.0\itl-ondemand-mcp-windows-amd64.exe")
            $result.sha256 | Should -Match '^[a-f0-9]{64}$'
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "does not overwrite an identical source-build facade that another project is using" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-ondemand-shared-binary-" + [guid]::NewGuid().ToString("N"))
        $handle = $null
        try {
            $sourceBuild = Join-Path $RepoRoot "tools\itl-ondemand-mcp\build\itl-ondemand-mcp-windows-amd64.exe"
            if (-not (Test-Path -LiteralPath $sourceBuild -PathType Leaf)) {
                & (Join-Path $RepoRoot "scripts\Build-ItlOnDemandMcp.ps1") -SkipTests | Out-Null
            }
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"aiRules":{"tools":["opencode"]}}'
            Copy-Item -LiteralPath (Join-Path $RepoRoot "templates\dependency-lock.json") -Destination (Join-Path $tempRoot ".agent-1c\dependency-lock.json")
            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $installRoot = Join-Path $tempRoot "shared-ondemand"
                function Get-ItlOnDemandMcpInstallRoot { return $installRoot }
                $entry = Get-DependencyLockEntry -Name "itlOndemandMcp"
                $targetDirectory = Join-Path $installRoot ([string]$entry.version)
                $targetPath = Join-Path $targetDirectory ([string]$entry.assetName)
                New-Item -ItemType Directory -Force -Path $targetDirectory | Out-Null
                Copy-Item -LiteralPath $sourceBuild -Destination $targetPath
                $script:sharedFacadeHandle = [IO.File]::Open($targetPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
                Install-ItlOnDemandMcp
            }
            $handle = $script:sharedFacadeHandle
            $result.sha256 | Should -Be ((Get-FileHash -LiteralPath $sourceBuild -Algorithm SHA256).Hash.ToLowerInvariant())
        } finally {
            if ($null -ne $handle) { $handle.Dispose() }
            $script:sharedFacadeHandle = $null
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "writes native stdio facade entries for all ten clients and preserves unrelated config" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-ondemand-clients-" + [guid]::NewGuid().ToString("N"))
        $fakeExe = Join-Path $tempRoot "itl-ondemand-mcp.exe"
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"aiRules":{"tools":["codex"]}}'
            Set-Content -LiteralPath $fakeExe -Encoding Byte -Value ([byte[]](1, 2, 3))
            [Environment]::SetEnvironmentVariable("ITL_ONDEMAND_MCP_EXE", $fakeExe, "Process")
            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                foreach ($client in @("codex", "kilocode", "claude-code", "cursor", "opencode", "kimi", "qwen", "command-code", "cline", "pi")) {
                    $adapter = Get-ItlClientAdapter -Client $client
                    $path = Join-Path $tempRoot $adapter.mcpPath
                    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
                    if ($client -eq "codex") {
                        Set-Content -LiteralPath $path -Encoding UTF8 -Value "# unrelated-setting`nmodel = `"keep`"`n"
                    } else {
                        $container = [string]$adapter.mcpContainer
                        Set-Content -LiteralPath $path -Encoding UTF8 -Value (([ordered]@{ keep = "value"; $container = [ordered]@{ custom = [ordered]@{ url = "https://example.invalid" }; legacyBranch = [ordered]@{ url = "http://127.0.0.1:9999/mcp"; managedBy = "itl-branch-mcp" } } } | ConvertTo-Json -Depth 8))
                    }
                    Remove-ItlLegacyBranchMcpEntries -Client $client
                    Write-ItlOnDemandMcpClientConfig -Client $client | Out-Null
                }
            }

            $codex = Get-Content -LiteralPath (Join-Path $tempRoot ".codex\config.toml") -Raw -Encoding UTF8
            $codex | Should -Match 'model = "keep"'
            $codex | Should -Match '\[mcp_servers\."itl-roctup-data"\]'
            $codex | Should -Match ([regex]::Escape($fakeExe.Replace('\', '\\')))
            $codex | Should -Match 'tool_timeout_sec = 600'
            $codex | Should -Match '"--surface"'
            $codex | Should -Match '"gateway"'

            foreach ($case in @(
                [pscustomobject]@{ client = "kilocode"; path = ".kilo\kilo.json"; container = "mcp"; local = $true },
                [pscustomobject]@{ client = "opencode"; path = "opencode.json"; container = "mcp"; local = $true },
                [pscustomobject]@{ client = "claude-code"; path = ".mcp.json"; container = "mcpServers"; local = $false },
                [pscustomobject]@{ client = "cursor"; path = ".cursor\mcp.json"; container = "mcpServers"; local = $false },
                [pscustomobject]@{ client = "kimi"; path = ".kimi-code\mcp.json"; container = "mcpServers"; local = $false },
                [pscustomobject]@{ client = "qwen"; path = ".qwen\settings.json"; container = "mcpServers"; local = $false },
                [pscustomobject]@{ client = "command-code"; path = ".mcp.json"; container = "mcpServers"; local = $false },
                [pscustomobject]@{ client = "cline"; path = ".cline\mcp.json"; container = "mcpServers"; local = $false },
                [pscustomobject]@{ client = "pi"; path = ".pi\mcp.json"; container = "mcpServers"; local = $false; pi = $true }
            )) {
                $config = Get-Content -LiteralPath (Join-Path $tempRoot $case.path) -Raw -Encoding UTF8 | ConvertFrom-Json
                $config.keep | Should -Be "value"
                $config.($case.container).custom.url | Should -Be "https://example.invalid"
                @($config.($case.container).PSObject.Properties.Name) | Should -Not -Contain "legacyBranch"
                $entry = $config.($case.container).'itl-vanessa-ui'
                if ($case.local) {
                    $entry.type | Should -Be "local"
                    @($entry.command)[0] | Should -Be $fakeExe
                    $entry.timeout | Should -Be 600000
                    @($entry.command) | Should -Contain "--surface"
                    @($entry.command) | Should -Contain "gateway"
                } elseif ($case.PSObject.Properties.Name -contains "pi" -and $case.pi) {
                    $entry.transport | Should -Be "stdio"
                    $entry.lifecycle | Should -Be "eager"
                    $entry.command | Should -Be $fakeExe
                    @($entry.args) | Should -Contain "vanessa-ui"
                    @($entry.args) | Should -Contain "--surface"
                    @($entry.args) | Should -Contain "gateway"
                } else {
                    $entry.command | Should -Be $fakeExe
                    @($entry.args) | Should -Contain "vanessa-ui"
                    @($entry.args) | Should -Contain "--surface"
                    @($entry.args) | Should -Contain "gateway"
                }
                @($config.($case.container).PSObject.Properties.Name) | Should -Contain "itl-roctup-data"
            }
        } finally {
            [Environment]::SetEnvironmentVariable("ITL_ONDEMAND_MCP_EXE", $null, "Process")
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "keeps backend broker actions private and removes legacy public MCP control" {
        $entrypoint = Get-Content -LiteralPath $HelperPath -Raw -Encoding UTF8
        $entrypoint | Should -Match 'InternalOnDemandOperation'
        $entrypoint | Should -Match 'Invoke-ItlOnDemandBackendBroker'
        foreach ($action in @("install-roctup-mcp", "update-roctup-mcp", "start-roctup-mcp", "stop-roctup-mcp", "roctup-mcp-status", "install-vanessa-mcp", "start-vanessa-mcp", "stop-vanessa-mcp", "vanessa-mcp-status")) {
            $entrypoint | Should -Not -Match ('"' + [regex]::Escape($action) + '"')
        }
    }

    It "keys ports by family, project, worktree, branch, and client instance" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-ondemand-keys-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"aiRules":{"tools":["codex"]}}'
            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $first = [pscustomobject]@{ stateProjectRoot = $tempRoot; worktreePath = (Join-Path $tempRoot 'wt-a'); safeDevBranchName = 'branch-a' }
                $second = [pscustomobject]@{ stateProjectRoot = $tempRoot; worktreePath = (Join-Path $tempRoot 'wt-b'); safeDevBranchName = 'branch-b' }
                [pscustomobject]@{
                    roctupA = Get-ItlOnDemandPortKey -Family roctup -State $first -InstanceId client-a
                    roctupB = Get-ItlOnDemandPortKey -Family roctup -State $first -InstanceId client-b
                    roctupOtherBranch = Get-ItlOnDemandPortKey -Family roctup -State $second -InstanceId client-a
                    vanessaA = Get-ItlOnDemandPortKey -Family 'vanessa-ui' -State $first -InstanceId client-a
                }
            }
            $result.roctupA | Should -Match '^roctup-mcp:'
            $result.vanessaA | Should -Match '^vanessa-mcp:'
            $result.roctupA | Should -Match '\|instance=client-a$'
            @($result.roctupA, $result.roctupB, $result.roctupOtherBranch, $result.vanessaA | Sort-Object -Unique).Count | Should -Be 4
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "creates a private Vanessa profile with a separately leased TestClient port and silent VanessaExt setup" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-ondemand-vanessa-profile-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"aiRules":{"tools":["codex"]}}'
            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $state = [pscustomobject]@{
                    infoBaseKind = "file"
                    devBranchInfoBasePath = (Join-Path $tempRoot "branch-ib")
                    stateProjectRoot = $tempRoot
                    worktreePath = $tempRoot
                    safeDevBranchName = "itldev/test"
                }
                $path = New-ItlOnDemandVanessaParamsFile -State $state -InstanceId ("a" * 32) -TestClientPort 48177 -VanessaVersion "1.2.043.28"
                $params = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
                $clientsKey = ConvertFrom-Utf8Base64 "0JrQu9C40LXQvdGC0KLQtdGB0YLQuNGA0L7QstCw0L3QuNGP"
                $profilesKey = ConvertFrom-Utf8Base64 "0JTQsNC90L3Ri9C10JrQu9C40LXQvdGC0L7QstCi0LXRgdGC0LjRgNC+0LLQsNC90LjRjw=="
                $nameKey = ConvertFrom-Utf8Base64 "0JjQvNGP"
                $portKey = ConvertFrom-Utf8Base64 "0J/QvtGA0YLQl9Cw0L/Rg9GB0LrQsNCi0LXRgdGC0JrQu9C40LXQvdGC0LA="
                $profile = @($params.$clientsKey.$profilesKey)[0]
                [pscustomobject]@{
                    path = $path
                    useaddin = $params.useaddin
                    screenshotAddin = $params.useaddinforscreencapture
                    failClosed = $params.QuitIfSilentInstallationAddinFails
                    disableLegacyProfiles = $params.DisableLoadTestClientsTable
                    useEditor = $params.UseEditor
                    useVanessaEditor = $params.usevanessaeditor
                    name = $profile.$nameKey
                    port = $profile.$portKey
                    range = Get-ItlOnDemandVanessaTestClientPortRange
                    portKey = Get-ItlOnDemandVanessaTestClientPortKey -State $state -InstanceId ("a" * 32)
                }
            }
            $result.useaddin | Should -BeTrue
            $result.screenshotAddin | Should -BeTrue
            $result.failClosed | Should -BeTrue
            $result.disableLegacyProfiles | Should -BeTrue
            $result.useEditor | Should -BeTrue
            $result.useVanessaEditor | Should -BeTrue
            $result.name | Should -Be "itl-ondemand"
            $result.port | Should -Be 48177
            $result.range.start | Should -Be 48151
            $result.range.end | Should -Be 48250
            $result.portKey | Should -Match '^vanessa-mcp-testclient:'

            $broker = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.ondemand-mcp.ps1") -Raw -Encoding UTF8
            $broker | Should -Match 'QuietInstallVanessaExt;DisableFirstRunHelper;UseEditor=true;usevanessaeditor=true'
            $broker | Should -Match 'ITL_VANESSA_UNSAFE_ACTION_PROTECTION_UNCONFIRMED'
            $broker | Should -Match 'function Ensure-ItlOnDemandVanessaTestClient'
            $broker | Should -Match 'Assert-VanessaTestClientCapacity[\s\S]*Start-EnterpriseBackground[\s\S]*-UseTestClient[\s\S]*-TestClientPort'
            $broker | Should -Match 'testClientProcessStartTime'
            $broker | Should -Match 'schemaVersion\s*=\s*3'
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "counts owned and foreign TestClients and fails license preflight without exposing secrets" {
        $oldCapacity = [Environment]::GetEnvironmentVariable("VANESSA_TESTCLIENT_LICENSE_CAPACITY", "Process")
        try {
            [Environment]::SetEnvironmentVariable("VANESSA_TESTCLIENT_LICENSE_CAPACITY", "2", "Process")
            $result = & {
                $state = [pscustomobject]@{
                    devBranchInfoBasePath = "D:\work\owned\base"
                    worktreePath = "D:\work\owned"
                    stateProjectRoot = "D:\work"
                    safeDevBranchName = "branch-owned"
                }
                function Get-OneCProcessInfo {
                    param([switch]$RequireSuccess)
                    @(
                        [pscustomobject]@{ processId = 71001; name = "1cv8c.exe"; commandLine = '1cv8c.exe /TESTCLIENT -TPort 48151 /F "D:\work\owned\base" /P "owned-secret"' },
                        [pscustomobject]@{ processId = 71002; name = "1cv8c.exe"; commandLine = '1cv8c.exe /TESTCLIENT -TPort 48152 /F "D:\foreign\base" /P "foreign-secret"' },
                        [pscustomobject]@{ processId = 71003; name = "1cv8c.exe"; commandLine = '1cv8c.exe /TESTMANAGER -TPort 48153 /F "D:\other\manager"' }
                    )
                }
                $snapshot = Get-VanessaTestClientCapacitySnapshot -State $state
                $message = ""
                try {
                    Assert-VanessaTestClientCapacity -State $state | Out-Null
                } catch {
                    $message = $_.Exception.Message
                }
                [pscustomobject]@{ snapshot = $snapshot; message = $message }
            }
            $result.snapshot.capacity | Should -Be 2
            $result.snapshot.active | Should -Be 2
            @($result.snapshot.processes | Where-Object scope -eq "owned").Count | Should -Be 1
            @($result.snapshot.processes | Where-Object scope -eq "foreign").Count | Should -Be 1
            $result.message | Should -Match '^ITL_VANESSA_LICENSE_LIMIT:'
            $result.message | Should -Match '71001'
            $result.message | Should -Match '71002'
            $result.message | Should -Not -Match 'secret'
        } finally {
            [Environment]::SetEnvironmentVariable("VANESSA_TESTCLIENT_LICENSE_CAPACITY", $oldCapacity, "Process")
        }
    }

    It "reuses a proven owned on-demand TestClient without capacity check or new process" {
        $result = & {
            $script:capacityChecks = 0
            $script:testClientStarts = 0
            $runtime = [pscustomobject]@{
                schemaVersion = 3; status = "running"; family = "vanessa-ui"; instanceId = ("a" * 32)
                pid = 72001; port = 9877; url = "http://127.0.0.1:9877/mcp"
                testClientPid = 72002; testClientPort = 48151; testClientState = "port-ready"
            }
            function Read-ItlOnDemandRuntimeState { return $runtime }
            function Test-ItlOnDemandOwnedProcess { return $true }
            function Test-TcpPortOpen { return $true }
            function Read-CurrentDevBranchStateForRoctupMcp { return [pscustomobject]@{ devBranchInfoBasePath = "D:\owned\base" } }
            function Get-Process { return [pscustomobject]@{ Id = 72002 } }
            function Get-ItlOnDemandOwnedTestClientProcesses { return @([pscustomobject]@{ process = [pscustomobject]@{ Id = 72002 } }) }
            function Assert-VanessaTestClientCapacity { $script:capacityChecks++ }
            function Start-EnterpriseBackground { $script:testClientStarts++ }
            function Write-ItlOnDemandRuntimeState { return "state.json" }
            $reused = Ensure-ItlOnDemandVanessaTestClient -InstanceId ("a" * 32)
            [pscustomobject]@{ state = $reused.testClientState; reused = $reused.testClientReused; capacityChecks = $script:capacityChecks; starts = $script:testClientStarts }
        }
        $result.state | Should -Be "port-ready"
        $result.reused | Should -BeTrue
        $result.capacityChecks | Should -Be 0
        $result.starts | Should -Be 0
    }

    It "does not claim or stop a foreign process stored as TestClient ownership" {
        $result = & {
            $script:stops = 0
            $runtime = [pscustomobject]@{
                schemaVersion = 3; status = "running"; family = "vanessa-ui"; instanceId = ("b" * 32)
                pid = 73001; port = 9877; url = "http://127.0.0.1:9877/mcp"
                testClientPid = 73002; testClientPort = 48151; testClientState = "port-ready"
            }
            function Read-ItlOnDemandRuntimeState { return $runtime }
            function Test-ItlOnDemandOwnedProcess { return $true }
            function Test-TcpPortOpen { return $true }
            function Read-CurrentDevBranchStateForRoctupMcp { return [pscustomobject]@{ devBranchInfoBasePath = "D:\owned\base" } }
            function Get-Process { return [pscustomobject]@{ Id = 73002 } }
            function Get-ItlOnDemandOwnedTestClientProcesses { return @() }
            function Stop-Process { $script:stops++ }
            $message = ""
            try {
                Ensure-ItlOnDemandVanessaTestClient -InstanceId ("b" * 32) | Out-Null
            } catch {
                $message = $_.Exception.Message
            }
            [pscustomobject]@{ message = $message; stops = $script:stops }
        }
        $result.message | Should -Match '^ITL_ONDEMAND_OWNERSHIP_MISMATCH: refusing to reuse or stop unverified TestClient PID 73002'
        $result.stops | Should -Be 0
    }

    It "does not start TestClient when the shared license capacity is exhausted" {
        $result = & {
            $script:starts = 0
            $runtime = [pscustomobject]@{
                schemaVersion = 3; status = "running"; family = "vanessa-ui"; instanceId = ("c" * 32)
                pid = 74001; port = 9877; url = "http://127.0.0.1:9877/mcp"
                testClientPid = 0; testClientPort = 48151; testClientState = "not-started"
            }
            function Read-ItlOnDemandRuntimeState { return $runtime }
            function Test-ItlOnDemandOwnedProcess { return $true }
            function Test-TcpPortOpen { return $true }
            function Read-CurrentDevBranchStateForRoctupMcp { return [pscustomobject]@{ devBranchInfoBasePath = "D:\owned\base" } }
            function Test-VanessaTestPortOwnedByState { return $false }
            function Test-VanessaTestPortUsedByForeignProcess { return $false }
            function Assert-VanessaTestClientCapacity { throw "ITL_VANESSA_LICENSE_LIMIT: capacity=2 active=2" }
            function Start-EnterpriseBackground { $script:starts++ }
            $message = ""
            try {
                Ensure-ItlOnDemandVanessaTestClient -InstanceId ("c" * 32) | Out-Null
            } catch {
                $message = $_.Exception.Message
            }
            [pscustomobject]@{ message = $message; starts = $script:starts }
        }
        $result.message | Should -Match '^ITL_VANESSA_LICENSE_LIMIT:'
        $result.starts | Should -Be 0
    }

    It "refuses to claim a process when the ownership markers do not match" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-ondemand-owner-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"aiRules":{"tools":["codex"]}}'
            $owned = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $native = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$PID"
                $state = [pscustomobject]@{
                    pid = $PID
                    processStartTime = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
                    executablePath = [string]$native.ExecutablePath
                    ownershipMarkers = @('itl-marker-that-is-not-in-the-command-line')
                }
                Test-ItlOnDemandOwnedProcess -RuntimeState $state
            }
            $owned | Should -BeFalse
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "proves a registered runtime stale when its PID is dead after checking the port" {
        $health = & {
            function ConvertTo-IntOrDefault { param($Value, $Default) return [int]$Value }
            function Get-Process { return $null }
            function Test-TcpPortOpen { param([int]$Port) return $false }
            function Test-ItlOnDemandOwnedProcess { return $false }
            Get-ItlOnDemandBackendRuntimeHealth -RuntimeState ([pscustomobject]@{ pid = 41001; port = 48101 })
        }
        $health.stale | Should -BeTrue
        $health.status | Should -Be "pid-dead"
        $health.pidAlive | Should -BeFalse
        $health.portOpen | Should -BeFalse
    }

    It "proves a registered runtime stale when its owned live PID has an unavailable port" {
        $health = & {
            function ConvertTo-IntOrDefault { param($Value, $Default) return [int]$Value }
            function Get-Process { return [pscustomobject]@{ Id = 41002 } }
            function Test-TcpPortOpen { param([int]$Port) return $false }
            function Test-ItlOnDemandOwnedProcess { return $true }
            Get-ItlOnDemandBackendRuntimeHealth -RuntimeState ([pscustomobject]@{ pid = 41002; port = 48102 })
        }
        $health.stale | Should -BeTrue
        $health.status | Should -Be "owned-pid-port-unavailable"
        $health.pidAlive | Should -BeTrue
        $health.portOpen | Should -BeFalse
        $health.owned | Should -BeTrue
    }

    It "does not classify an unverified live PID as stale" {
        $health = & {
            function ConvertTo-IntOrDefault { param($Value, $Default) return [int]$Value }
            function Get-Process { return [pscustomobject]@{ Id = 41003 } }
            function Test-TcpPortOpen { param([int]$Port) return $false }
            function Test-ItlOnDemandOwnedProcess { return $false }
            Get-ItlOnDemandBackendRuntimeHealth -RuntimeState ([pscustomobject]@{ pid = 41003; port = 48103 })
        }
        $health.stale | Should -BeFalse
        $health.status | Should -Be "ownership-unverified"
    }

    It "replaces a proven stale runtime exactly once with a new instance identity" {
        $result = & {
            $script:recoveryStops = 0
            $script:recoveryStarts = 0
            function Read-ItlOnDemandRuntimeState {
                return [pscustomobject]@{ family = "vanessa-ui"; instanceId = ("a" * 32); pid = 41004; port = 48104 }
            }
            function Get-ItlOnDemandBackendRuntimeHealth {
                return [pscustomobject]@{ stale = $true; status = "pid-dead"; pidAlive = $false; portOpen = $false; owned = $false }
            }
            function Stop-ItlOnDemandBackendInstance {
                $script:recoveryStops++
                return [pscustomobject]@{ status = "stopped" }
            }
            function Start-ItlOnDemandBackendInstance {
                param($Family, $InstanceId, $CatalogSha256)
                $script:recoveryStarts++
                return [pscustomobject]@{ status = "running"; family = $Family; instanceId = $InstanceId; pid = 41005; port = 48105 }
            }
            $replacement = Recover-ItlOnDemandBackendInstance `
                -Family "vanessa-ui" `
                -InstanceId ("a" * 32) `
                -ReplacementInstanceId ("b" * 32) `
                -ExpectedPid 41004 `
                -ExpectedPort 48104 `
                -CatalogSha256 ("c" * 64)
            [pscustomobject]@{ stops = $script:recoveryStops; starts = $script:recoveryStarts; replacement = $replacement }
        }
        $result.stops | Should -Be 1
        $result.starts | Should -Be 1
        $result.replacement.instanceId | Should -Be ("b" * 32)
    }

    It "restores an atomically claimed runtime when strict ownership validation fails" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-ondemand-recovery-rollback-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"aiRules":{"tools":["codex"]}}'
            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $runtimeRoot = Join-Path $tempRoot "runtime"
                function Get-ItlOnDemandRuntimeRoot { return $runtimeRoot }
                $native = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$PID"
                $instanceId = "d" * 32
                $path = Write-ItlOnDemandRuntimeState -RuntimeState ([pscustomobject][ordered]@{
                    schemaVersion = 2
                    status = "running"
                    family = "vanessa-ui"
                    instanceId = $instanceId
                    pid = $PID
                    processStartTime = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString("o")
                    executablePath = [string]$native.ExecutablePath
                    ownershipMarkers = @("marker-that-cannot-match")
                    portFamily = "vanessa"
                    portKey = "owned-key"
                    port = 48106
                    testClientPid = 0
                    testClientPort = 0
                    testClientPortFamily = ""
                    testClientPortKey = ""
                    vanessaParamsPath = ""
                })
                $message = ""
                try {
                    Stop-ItlOnDemandBackendInstance -Family "vanessa-ui" -InstanceId $instanceId -StrictOwnership | Out-Null
                } catch {
                    $message = $_.Exception.Message
                }
                [pscustomobject]@{
                    message = $message
                    restored = Test-Path -LiteralPath $path -PathType Leaf
                    claims = @(Get-ChildItem -LiteralPath (Split-Path -Parent $path) -Filter "*.removing-*").Count
                }
            }
            $result.message | Should -Match "^ITL_ONDEMAND_OWNERSHIP_MISMATCH"
            $result.restored | Should -BeTrue
            $result.claims | Should -Be 0
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "drains only on-demand runtime records that target the selected infobase" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-ondemand-target-drain-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"aiRules":{"tools":["codex"]}}'
            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $runtimeRoot = Join-Path $tempRoot "runtime"
                function Get-ItlOnDemandRuntimeRoot { return $runtimeRoot }
                function Release-ItlManagedPortAllocation { }
                $baseA = Join-Path $tempRoot "base-a"
                $baseB = Join-Path $tempRoot "base-b"
                foreach ($item in @(
                    [pscustomobject]@{ family = "roctup"; instanceId = ("a" * 32); infoBasePath = $baseA; portFamily = "roctup"; portKey = "a" },
                    [pscustomobject]@{ family = "vanessa-ui"; instanceId = ("b" * 32); infoBasePath = $baseA; portFamily = "vanessa"; portKey = "b" },
                    [pscustomobject]@{ family = "roctup"; instanceId = ("c" * 32); infoBasePath = $baseB; portFamily = "roctup"; portKey = "c" }
                )) {
                    Write-ItlOnDemandRuntimeState -RuntimeState ([pscustomobject][ordered]@{
                        schemaVersion = 2
                        status = "running"
                        family = $item.family
                        instanceId = $item.instanceId
                        pid = 0
                        processStartTime = ""
                        executablePath = ""
                        ownershipMarkers = @()
                        portFamily = $item.portFamily
                        portKey = $item.portKey
                        port = 0
                        infoBasePath = $item.infoBasePath
                        testClientPid = 0
                        testClientPort = 0
                        testClientPortFamily = ""
                        testClientPortKey = ""
                        vanessaParamsPath = ""
                    }) | Out-Null
                }

                Stop-ItlOnDemandBackends -InfoBasePath $baseA -Strict
                [pscustomobject]@{
                    baseA = @(Get-ItlOnDemandRuntimeInstances -Strict | Where-Object { Test-ItlOnDemandInfoBaseMatch $_.infoBasePath $baseA }).Count
                    baseB = @(Get-ItlOnDemandRuntimeInstances -Strict | Where-Object { Test-ItlOnDemandInfoBaseMatch $_.infoBasePath $baseB }).Count
                }
            }
            $result.baseA | Should -Be 0
            $result.baseB | Should -Be 1
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "atomically removes a stopped Vanessa runtime and releases both managed ports" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-ondemand-release-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"aiRules":{"tools":["codex"]}}'
            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $runtimeRoot = Join-Path $tempRoot "runtime"
                function Get-ItlOnDemandRuntimeRoot { return $runtimeRoot }
                $script:Released = @()
                function Release-ItlManagedPortAllocation {
                    param([string]$Family, [string]$Key)
                    $script:Released += "$Family/$Key"
                }
                $instanceId = "e" * 32
                $paramsPath = Join-Path $tempRoot "vanessa-params.json"
                Set-Content -LiteralPath $paramsPath -Encoding UTF8 -Value "{}"
                $path = Write-ItlOnDemandRuntimeState -RuntimeState ([pscustomobject][ordered]@{
                    schemaVersion = 2
                    status = "running"
                    family = "vanessa-ui"
                    instanceId = $instanceId
                    pid = 0
                    processStartTime = ""
                    executablePath = ""
                    ownershipMarkers = @()
                    portFamily = "vanessa-mcp"
                    portKey = "backend-key"
                    port = 48120
                    infoBasePath = (Join-Path $tempRoot "base")
                    testClientPid = 0
                    testClientPort = 48170
                    testClientPortFamily = "vanessa-mcp-testclient"
                    testClientPortKey = "client-key"
                    vanessaParamsPath = $paramsPath
                })

                Stop-ItlOnDemandBackendInstance -Family "vanessa-ui" -InstanceId $instanceId -StrictOwnership | Out-Null
                [pscustomobject]@{
                    runtimeRemoved = -not (Test-Path -LiteralPath $path)
                    paramsRemoved = -not (Test-Path -LiteralPath $paramsPath)
                    claims = @(Get-ChildItem -LiteralPath (Split-Path -Parent $path) -Filter "*.removing-*").Count
                    released = @($script:Released)
                }
            }
            $result.runtimeRemoved | Should -BeTrue
            $result.paramsRemoved | Should -BeTrue
            $result.claims | Should -Be 0
            $result.released | Should -Contain "vanessa-mcp/backend-key"
            $result.released | Should -Contain "vanessa-mcp-testclient/client-key"
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "stops the strictly owned backend process and closes its listening port" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-ondemand-owned-process-" + [guid]::NewGuid().ToString("N"))
        $child = $null
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"aiRules":{"tools":["codex"]}}'
            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $runtimeRoot = Join-Path $tempRoot "runtime"
                function Get-ItlOnDemandRuntimeRoot { return $runtimeRoot }
                function Release-ItlManagedPortAllocation {}
                $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
                $listener.Start()
                $port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
                $listener.Stop()
                $command = '$listener=[System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback,{0});$listener.Start();Start-Sleep -Seconds 60' -f $port
                $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
                $powershell = (Get-Command powershell.exe).Source
                $script:OwnedChild = Start-Process `
                    -FilePath $powershell `
                    -ArgumentList @("-NoProfile", "-EncodedCommand", $encoded) `
                    -WindowStyle Hidden `
                    -PassThru
                $deadline = (Get-Date).AddSeconds(10)
                while (-not (Test-TcpPortOpen -Port $port) -and (Get-Date) -lt $deadline) {
                    Start-Sleep -Milliseconds 50
                }
                if (-not (Test-TcpPortOpen -Port $port)) {
                    throw "Owned backend fixture did not open port $port."
                }
                $process = Get-Process -Id $script:OwnedChild.Id -ErrorAction Stop
                $native = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$($script:OwnedChild.Id)"
                $instanceId = "f" * 32
                $path = Write-ItlOnDemandRuntimeState -RuntimeState ([pscustomobject][ordered]@{
                    schemaVersion = 2
                    status = "running"
                    family = "vanessa-ui"
                    instanceId = $instanceId
                    pid = $script:OwnedChild.Id
                    processStartTime = $process.StartTime.ToUniversalTime().ToString("o")
                    executablePath = [string]$native.ExecutablePath
                    ownershipMarkers = @($encoded)
                    portFamily = "vanessa-mcp"
                    portKey = "owned-process-key"
                    port = $port
                    infoBasePath = (Join-Path $tempRoot "base")
                    testClientPid = 0
                    testClientPort = 0
                    testClientPortFamily = ""
                    testClientPortKey = ""
                    vanessaParamsPath = ""
                })

                Stop-ItlOnDemandBackendInstance -Family "vanessa-ui" -InstanceId $instanceId -StrictOwnership | Out-Null
                [pscustomobject]@{
                    child = $script:OwnedChild
                    processAlive = $null -ne (Get-Process -Id $script:OwnedChild.Id -ErrorAction SilentlyContinue)
                    portOpen = Test-TcpPortOpen -Port $port
                    runtimeRemoved = -not (Test-Path -LiteralPath $path)
                }
            }
            $child = $result.child
            $result.processAlive | Should -BeFalse
            $result.portOpen | Should -BeFalse
            $result.runtimeRemoved | Should -BeTrue
        } finally {
            if ($null -ne $child -and $null -ne (Get-Process -Id $child.Id -ErrorAction SilentlyContinue)) {
                Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue
            }
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "retains runtime state and leases when a strict stop cannot prove the port was released" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-ondemand-open-port-" + [guid]::NewGuid().ToString("N"))
        $listener = $null
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"aiRules":{"tools":["codex"]}}'
            $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
            $listener.Start()
            $port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $runtimeRoot = Join-Path $tempRoot "runtime"
                function Get-ItlOnDemandRuntimeRoot { return $runtimeRoot }
                $script:ReleaseCalls = 0
                function Release-ItlManagedPortAllocation { $script:ReleaseCalls++ }
                $instanceId = "1" * 32
                $path = Write-ItlOnDemandRuntimeState -RuntimeState ([pscustomobject][ordered]@{
                    schemaVersion = 2
                    status = "running"
                    family = "vanessa-ui"
                    instanceId = $instanceId
                    pid = 0
                    processStartTime = ""
                    executablePath = ""
                    ownershipMarkers = @()
                    portFamily = "vanessa-mcp"
                    portKey = "open-port-key"
                    port = $port
                    infoBasePath = (Join-Path $tempRoot "base")
                    testClientPid = 0
                    testClientPort = 0
                    testClientPortFamily = ""
                    testClientPortKey = ""
                    vanessaParamsPath = ""
                })
                $message = ""
                try {
                    Stop-ItlOnDemandBackendInstance -Family "vanessa-ui" -InstanceId $instanceId -StrictOwnership | Out-Null
                } catch {
                    $message = $_.Exception.Message
                }
                [pscustomobject]@{
                    message = $message
                    runtimeRestored = Test-Path -LiteralPath $path -PathType Leaf
                    releaseCalls = $script:ReleaseCalls
                }
            }
            $result.message | Should -Match "^ITL_ONDEMAND_STOP_FAILED: backend port $port is still open"
            $result.runtimeRestored | Should -BeTrue
            $result.releaseCalls | Should -Be 0
        } finally {
            if ($null -ne $listener) { $listener.Stop() }
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "fails closed when strict runtime drain encounters unreadable ownership state" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-ondemand-invalid-state-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"aiRules":{"tools":["codex"]}}'
            $message = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $runtimeRoot = Join-Path $tempRoot "runtime"
                function Get-ItlOnDemandRuntimeRoot { return $runtimeRoot }
                $invalidPath = Join-Path $runtimeRoot ("roctup\" + ("d" * 32) + ".json")
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $invalidPath) | Out-Null
                Set-Content -LiteralPath $invalidPath -Encoding UTF8 -Value "{not-json"
                try {
                    Stop-ItlOnDemandBackends -InfoBasePath (Join-Path $tempRoot "base") -Strict
                } catch {
                    return $_.Exception.Message
                }
                return ""
            }
            $message | Should -Match "^ITL_ONDEMAND_RUNTIME_STATE_INVALID "
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
