Describe "ITL on-demand MCP facade" {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        $RepoRoot = $context.RepoRoot
        $HelperPath = $context.HelperPath
        $AssetRoot = Join-Path $RepoRoot ".agents\skills\1c-workflow\assets\ondemand-mcp"
        . (Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.ondemand-mcp.ps1")
    }

    It "pins hash-verified full catalogs to compatible backend versions" {
        $manifest = Get-Content -LiteralPath (Join-Path $AssetRoot "compatibility.json") -Raw -Encoding UTF8 | ConvertFrom-Json
        $manifest.facadeVersion | Should -Be "0.3.2"
        $manifest.minimumFacadeVersion | Should -Be "0.3.2"
        $mainSource = Get-Content -LiteralPath (Join-Path $RepoRoot "tools\itl-ondemand-mcp\main.go") -Raw -Encoding UTF8
        $gatewaySource = Get-Content -LiteralPath (Join-Path $RepoRoot "tools\itl-ondemand-mcp\gateway.go") -Raw -Encoding UTF8
        $mainSource | Should -Match 'const version = "0\.3\.2"'
        $mainSource | Should -Match '"gateway"'
        $gatewaySource | Should -Match 'gatewayResolveTool\s*=\s*"resolve_tool"'
        $gatewaySource | Should -Match 'gatewayCallTool\s*=\s*"call_tool"'
        $manifest.families.roctup.backendVersions.roctup | Should -Be "v1.7.1"
        $manifest.families.'vanessa-ui'.backendVersions.clientMcp | Should -Be "v0.6.5"
        $manifest.families.'vanessa-ui'.backendVersions.vaExtension | Should -Be "1.2.043.28"
        $manifest.families.'vanessa-ui'.backendVersions.vanessaAutomation | Should -Be "1.2.043.28"
        $manifest.families.'vanessa-ui'.backendVersions.vanessaExt | Should -Be "1.3.9.131"
        $manifest.families.'vanessa-ui'.embeddedDependencies.vanessaExt.version | Should -Be "1.3.9.131"
        $manifest.families.'vanessa-ui'.embeddedDependencies.vanessaExt.sha256 | Should -Match '^[0-9a-f]{64}$'
        $lock = Get-Content -LiteralPath (Join-Path $RepoRoot "templates\dependency-lock.json") -Raw -Encoding UTF8 | ConvertFrom-Json
        [string]$lock.dependencies.itlOndemandMcp.sha256 | Should -Match '^[0-9a-f]{64}$'
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

                $version = "0.3.2"
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

            $result.path | Should -Be (Join-Path $tempRoot "localapp\ondemand\0.3.2\itl-ondemand-mcp-windows-amd64.exe")
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
            $result.name | Should -Be "itl-ondemand"
            $result.port | Should -Be 48177
            $result.range.start | Should -Be 48151
            $result.range.end | Should -Be 48250
            $result.portKey | Should -Match '^vanessa-mcp-testclient:'

            $broker = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.ondemand-mcp.ps1") -Raw -Encoding UTF8
            $broker | Should -Match 'QuietInstallVanessaExt;DisableFirstRunHelper'
            $broker | Should -Match 'ITL_VANESSA_UNSAFE_ACTION_PROTECTION_UNCONFIRMED'
            $broker | Should -Match 'Start-EnterpriseBackground[\s\S]*-UseTestClient[\s\S]*-TestClientPort'
            $broker | Should -Match 'testClientProcessStartTime'
            $broker | Should -Match 'schemaVersion\s*=\s*2'
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
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
}
