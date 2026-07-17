Describe "1C workflow MCP config checks" {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        $RepoRoot = $context.RepoRoot
        $HelperPath = $context.HelperPath
        $HelperModulePaths = $context.HelperModulePaths
        $LauncherPath = $context.LauncherPath
        $InstallerPath = $context.InstallerPath
        $McpHostPath = $context.McpHostPath
        $McpHostDumpPath = $context.McpHostDumpPath
        $HelperText = $context.HelperText
        $LauncherText = $context.LauncherText
        $McpHostText = $context.McpHostText
    }

    It "treats remote endpoints without branch fingerprints as shared rather than stale" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            [pscustomobject]@{
                remote = Get-Vibecoding1cMcpEndpointFreshness -Endpoint ([pscustomobject]@{ provider = "remote"; sourceFingerprint = "" })
                local = Get-Vibecoding1cMcpEndpointFreshness -Endpoint ([pscustomobject]@{ provider = "local"; sourceFingerprint = "" })
            }
        }

        $result.remote | Should -Be "remote-shared"
        $result.local | Should -Be "unknown"
    }

    It "offers one bulk provider choice and auto-selects a sole remote configuration" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $script:Answers = @("", "each")
            function Read-Host { return $script:Answers[0] }
            $defaultMode = Read-Vibecoding1cMcpProviderSelectionMode
            $script:Answers = @("each")
            $eachMode = Read-Vibecoding1cMcpProviderSelectionMode
            function Ensure-Vibecoding1cMcpRegistry {}
            function Read-Vibecoding1cMcpRegistry { return [pscustomobject]@{} }
            function Get-Vibecoding1cMcpRegistryConfigurations {
                return @([pscustomobject]@{ configId = "only-config"; title = "Only" })
            }
            [pscustomobject]@{
                defaultMode = $defaultMode
                eachMode = $eachMode
                configId = Read-Vibecoding1cMcpRemoteConfigChoice -Selection ([pscustomobject]@{})
            }
        }

        $result.defaultMode | Should -Be "remote"
        $result.eachMode | Should -Be "each"
        $result.configId | Should -Be "only-config"
    }
    It "wires ROCTUP MCP defaults, actions, lock, client config, and agent token guardrails" {
        foreach ($action in @("install-roctup-mcp", "update-roctup-mcp", "start-roctup-mcp", "stop-roctup-mcp", "roctup-mcp-status")) {
            $HelperText | Should -Match ([regex]::Escape("`"$action`""))
        }

        $HelperText | Should -Match "ROCTUP/1c-mcp-toolkit"
        $HelperText | Should -Match "MCP_Toolkit.epf"
        $HelperText | Should -Match "MCP_Toolkit_x86.epf"
        $HelperText | Should -Match "MCP_Toolkit_linux.epf"
        $HelperText | Should -Match "ROCTUP_MCP_PORT_RANGE"
        $HelperText | Should -Match "6003"
        $HelperText | Should -Match "6102"
        $HelperText | Should -Match "startup;mode=embedded;port="
        $HelperText | Should -Match "Invoke-DevBranchDefaultMcpSetup"
        $HelperText | Should -Match "Invoke-DevBranchMcpRestartAfterInfobaseLoad"
        $HelperText | Should -Match "Write-ItlBranchMcpClientConfig"
        $HelperText | Should -Match 'itl-\$project-\$safeName-roctup'
        $HelperText | Should -Match "ROCTUP_MCP_REQUIRED"
        $HelperText | Should -Match "roctupMcpToolkit"
        $HelperText | Should -Match "assetName"
        $HelperText | Should -Match "Assert-DevBranchToolArtifactExportGuard"
        $HelperText | Should -Match "client_mcp"
        $HelperText | Should -Match "VAExtension"

        $devEnvTemplate = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\dev.env.example")
        foreach ($name in @("ROCTUP_MCP_ENABLED=true", "ROCTUP_MCP_AUTO_START=false", "ROCTUP_MCP_REQUIRED=false", "ROCTUP_MCP_INSTALL_ROOT=.agent-1c/tools/roctup-mcp-toolkit", "ROCTUP_MCP_PORT_RANGE=6003..6102", "VANESSA_MCP_AUTO_START=false")) {
            $devEnvTemplate | Should -Match ([regex]::Escape($name))
        }

        $dependencyLock = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\dependency-lock.json") | ConvertFrom-Json
        $dependencyLock.dependencies.roctupMcpToolkit.version | Should -Be "v1.7.0"
        $dependencyLock.dependencies.roctupMcpToolkit.assetName | Should -Be "MCP_Toolkit.epf"
        $dependencyLock.dependencies.roctupMcpToolkit.url | Should -Match "/releases/download/v1.7.0/MCP_Toolkit.epf$"
        $dependencyLock.dependencies.roctupMcpToolkit.sha256 | Should -Be "e9a0856224aea4f54763fe1fb6a21aa8e71efb9d14158adc4382e1b2276d829d"
        $dependencyLock.dependencies.vanessaMcp.clientMcp.assetName | Should -Be "client_mcp.cfe"
        $dependencyLock.dependencies.vanessaMcp.clientMcp.sha256 | Should -Be "74d3cb7f97e3800860f5a1754eecf47178164d888f2299125d1b3118a4614ec1"
        $dependencyLock.dependencies.vanessaMcp.vaExtension.assetName | Should -Be "VAExtension.1.29.cfe"
        $dependencyLock.dependencies.vanessaMcp.vaExtension.sha256 | Should -Be "fc557bb23371a37dbe22a7a7a83e28f6db75b57f87e8802028cf1f90c4e00605"

        $skillText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".agents\skills\itl-roctup-1c-data\SKILL.md")
        $skillText | Should -Match "get_metadata"
        $skillText | Should -Match "execute_query"
        $skillText | Should -Match "50"
        $skillText | Should -Match "100"
        $skillText | Should -Match "execute_code"
        $skillText | Should -Match "restart_1c_session"
        $skillText | Should -Match "close_1c_session"
        $skillText | Should -Match "on-demand"
    }

    It "wires vibecoding1c MCP actions, scopes, ports, registry, selection, and client config" {
        $actions = @("vibecoding1c-mcp-setup", "vibecoding1c-mcp-update", "vibecoding1c-mcp-status", "vibecoding1c-mcp-start", "vibecoding1c-mcp-stop", "vibecoding1c-mcp-select", "vibecoding1c-mcp-refresh-registry", "vibecoding1c-mcp-rotate-keys", "vibecoding1c-mcp-ensure-model", "vibecoding1c-mcp-write-client-config")
        foreach ($action in $actions) {
            $HelperText | Should -Match ([regex]::Escape("`"$action`""))
        }
        foreach ($oldAction in @("mcp-setup", "mcp-update", "mcp-status", "mcp-start", "mcp-stop", "mcp-select", "mcp-refresh-registry", "mcp-rotate-keys", "mcp-ensure-model", "mcp-write-client-config")) {
            $HelperText | Should -Not -Match "(?<!vibecoding1c-)(?<!vanessa-)(?<!roctup-)$([regex]::Escape($oldAction))(?![A-Za-z0-9-])"
        }
        foreach ($parameter in @('$McpProvider', '$McpConfigId', '$McpHostId', '$McpLocalScope')) {
            $HelperText | Should -Match ([regex]::Escape($parameter))
        }

        $HelperText | Should -Match "itl-1c-docs"
        $HelperText | Should -Match "itl-1c-templates"
        $HelperText | Should -Match "itl-1c-syntax"
        $HelperText | Should -Match "itl-1c-codechecker"
        $HelperText | Should -Match "itl-{projectSlug}-code"
        $HelperText | Should -Match "itl-{projectSlug}-graph"
        $HelperText | Should -Match "bookstack-product-docs"
        $HelperText | Should -Match "BookStack-product-docs-mcp"
        $HelperText | Should -Match "itl-mantis-ticket-mcp"
        $HelperText | Should -Match "Get-Vibecoding1cMcpMantisTicketServerDefinition"
        $HelperText | Should -Match "Test-Vibecoding1cMcpMantisTicketVirtualServerEnabled"
        $HelperText | Should -Match "Add-Vibecoding1cMcpVirtualServersToManifest"
        $HelperText | Should -Match "Test-ProductDocsMcpAllowed"
        $HelperText | Should -Match "Product docs allowed for project"
        $HelperText | Should -Match "Product docs selected in MCP manifest"
        $HelperText | Should -Match "Product docs effective client config:.*activeClient"
        $HelperText | Should -Match "Product docs endpoint reachable \(bounded probe\)"
        $HelperText | Should -Match "Test-Vibecoding1cMcpLogicalServerAllowedForProject"
        $HelperText | Should -Not -Match "itl-{projectSlug}-{branchSlug}-vanessa"
        $HelperText | Should -Not -Match "localVanessa"
        foreach ($portMarker in @("18000", "18100", "18500", "19000")) {
            $HelperText | Should -Match $portMarker
        }
        foreach ($internalPort in @("8000", "8002", "8003", "8004", "8006", "8007", "8008")) {
            $HelperText | Should -Match $internalPort
        }
        $HelperText | Should -Match "host.docker.internal"
        $HelperText | Should -Match "Qwen3-Embedding-4B-GGUF"
        $HelperText | Should -Match "intfloat/multilingual-e5-small"
        $HelperText | Should -Match "lms server start --port"
        $HelperText | Should -Match "mcp_servers"
        $HelperText | Should -Match "managedBy"
        $HelperText | Should -Match "family = `"vibecoding1c`""
        $HelperText | Should -Match "managedBy = `"vibecoding1c-mcp`""
        $HelperText | Should -Match ([regex]::Escape("http://gitlabserv01.itland.local/root/MCP-vibecoding1c.git"))
        $HelperText | Should -Match ([regex]::Escape("http://gitlabserv01.itland.local/root/MCP-vibecoding1c-registry.git"))
        $HelperText | Should -Match "VIBECODING1C_MCP_DISTRIBUTION_REPO"
        $HelperText | Should -Match "VIBECODING1C_MCP_REGISTRY_REPO"
        $HelperText | Should -Match "vibecoding1c-selection.json"
        $HelperText | Should -Match "Get-Vibecoding1cMcpSelectionCompleteness"
        $HelperText | Should -Match "vibecoding1c MCP selection is missing or incomplete"
        $HelperText | Should -Match "Force was specified; running vibecoding1c MCP selection"
        $HelperText | Should -Match "remote-shared"
        $HelperText | Should -Match "Get-Vibecoding1cMcpStatusSummary"
        $HelperText | Should -Match "vibecoding1c MCP skipped servers"
        $HelperText | Should -Match "vibecoding1c MCP stale servers"
        $HelperText | Should -Match "vibecoding1c MCP missing-configId servers"
        $HelperText | Should -Not -Match ([regex]::Escape("D:\Git\MCP vibecoding1c"))
        $HelperText | Should -Not -Match "-p 8000:8000"
        $HelperText | Should -Not -Match "-p 8006:8006"
        $HelperText | Should -Not -Match "ITL_MCP"
        $HelperText | Should -Not -Match "/itl-mcp"
        $HelperText | Should -Not -Match "itl-mcp"
        $HelperText | Should -Not -Match "(?<![A-Za-z0-9])mcpSetupDuringInit"

        (Test-Path -LiteralPath (Join-Path $RepoRoot ".kilo\commands\itl-vibecoding1c-mcp.md") -PathType Leaf) | Should -Be $false
        (Test-Path -LiteralPath (Join-Path $RepoRoot ".kilo\commands\itl-mcp.md") -PathType Leaf) | Should -Be $false
        $kiloTemplateText = (Get-ChildItem -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\kilo-command-templates") -Recurse -File -Filter "itl*.md.template" | ForEach-Object { Get-Content -Encoding UTF8 -Raw $_.FullName }) -join [Environment]::NewLine
        $kiloTemplateText | Should -Not -Match "/itl-vibecoding1c-mcp"
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "docs\itl-workflow\DEV-ENV-REFERENCE.ru.md")) | Should -Match "VIBECODING1C_MCP_DISTRIBUTION_REPO"
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "AGENT-INSTALL.md")) | Should -Match "vibecoding1c-mcp-setup"
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "AGENT-INSTALL.md")) | Should -Not -Match "/itl-vibecoding1c-mcp"
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\dev.env.example")) | Should -Match "VIBECODING1C_MCP_DISTRIBUTION_PATH"
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\dev.env.example")) | Should -Match "VIBECODING1C_MCP_DISTRIBUTION_REPO"
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\dev.env.example")) | Should -Match "VIBECODING1C_MCP_REGISTRY_PATH"
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\dev.env.example")) | Should -Match "VIBECODING1C_MCP_REGISTRY_REPO"
        $projectTemplate = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\project.json")
        $projectTemplate | Should -Match "vibecoding1cMcp"
        $projectTemplate | Should -Match "providerDefault"
        $projectTemplate | Should -Match '"baseConfigurationVersion"\s*:\s*"PM5"'
        $projectTemplate | Should -Not -Match '"mcp"\s*:'
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\dev.env.example")) | Should -Match "PATH_METADATA"
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\dev.env.example")) | Should -Match "BASE_CONFIGURATION_VERSION=PM5"
    }

    It "clones and fast-forwards the managed vibecoding1c MCP distribution checkout" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vibecoding1c-mcp-distribution-test-" + [guid]::NewGuid().ToString("N"))
        $projectRoot = Join-Path $tempRoot "project"
        $workRepo = Join-Path $tempRoot "source"
        $remoteRepo = Join-Path $tempRoot "remote.git"
        $localHome = Join-Path $tempRoot "local-home"
        $oldRepo = [Environment]::GetEnvironmentVariable("VIBECODING1C_MCP_DISTRIBUTION_REPO", "Process")
        $oldPath = [Environment]::GetEnvironmentVariable("VIBECODING1C_MCP_DISTRIBUTION_PATH", "Process")
        $oldHome = [Environment]::GetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", "Process")

        try {
            New-Item -ItemType Directory -Force -Path $projectRoot, $workRepo | Out-Null
            & git -C $workRepo init *> $null
            & git -C $workRepo config user.email "test@example.com"
            & git -C $workRepo config user.name "Test User"
            & git -C $workRepo branch -M main
            Set-Content -LiteralPath (Join-Path $workRepo "config.env") -Value "LICENSE_KEY_HELP=fixture-key`n" -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $workRepo "vibecoding1c-mcp.manifest.json") -Value '{"servers":[]}' -Encoding ASCII
            & git -C $workRepo add config.env vibecoding1c-mcp.manifest.json
            & git -C $workRepo commit -m "initial distribution" *> $null
            & git init --bare $remoteRepo *> $null
            & git -C $workRepo remote add origin $remoteRepo
            & git -C $workRepo push --quiet -u origin main *> $null
            & git -C $remoteRepo symbolic-ref HEAD refs/heads/main

            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_DISTRIBUTION_REPO", $remoteRepo, "Process")
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_DISTRIBUTION_PATH", $null, "Process")
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", $localHome, "Process")

            & {
                . $HelperPath -ProjectRoot $projectRoot -Action help *> $null
                Ensure-Vibecoding1cMcpDistribution | Out-Null
            }

            $managedPath = Join-Path $localHome "distribution"
            (Test-Path -LiteralPath (Join-Path $managedPath ".git") -PathType Container) | Should -Be $true
            (Test-Path -LiteralPath (Join-Path $managedPath "config.env") -PathType Leaf) | Should -Be $true

            Set-Content -LiteralPath (Join-Path $workRepo "version.txt") -Value "2" -Encoding ASCII
            & git -C $workRepo add version.txt
            & git -C $workRepo commit -m "update distribution" *> $null
            & git -C $workRepo push --quiet origin main *> $null

            & {
                . $HelperPath -ProjectRoot $projectRoot -Action help *> $null
                Ensure-Vibecoding1cMcpDistribution | Out-Null
            }

            (Get-Content -Encoding ASCII -Raw (Join-Path $managedPath "version.txt")).Trim() | Should -Be "2"
        } finally {
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_DISTRIBUTION_REPO", $oldRepo, "Process")
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_DISTRIBUTION_PATH", $oldPath, "Process")
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", $oldHome, "Process")
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "does not clone when an explicit vibecoding1c MCP distribution path is configured" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vibecoding1c-mcp-distribution-override-" + [guid]::NewGuid().ToString("N"))
        $projectRoot = Join-Path $tempRoot "project"
        $manualDistribution = Join-Path $tempRoot "manual-distribution"
        $localHome = Join-Path $tempRoot "local-home"
        $oldRepo = [Environment]::GetEnvironmentVariable("VIBECODING1C_MCP_DISTRIBUTION_REPO", "Process")
        $oldPath = [Environment]::GetEnvironmentVariable("VIBECODING1C_MCP_DISTRIBUTION_PATH", "Process")
        $oldHome = [Environment]::GetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", "Process")

        try {
            New-Item -ItemType Directory -Force -Path $projectRoot, $manualDistribution | Out-Null
            Set-Content -LiteralPath (Join-Path $manualDistribution "config.env") -Value "LICENSE_KEY_HELP=manual-key`n" -Encoding ASCII
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_DISTRIBUTION_REPO", "bad://should-not-be-used", "Process")
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_DISTRIBUTION_PATH", $manualDistribution, "Process")
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", $localHome, "Process")

            & {
                . $HelperPath -ProjectRoot $projectRoot -Action help *> $null
                $resolved = Ensure-Vibecoding1cMcpDistribution
                $resolved | Should -Be ([System.IO.Path]::GetFullPath($manualDistribution))
            }

            (Test-Path -LiteralPath (Join-Path $localHome "distribution") -ErrorAction SilentlyContinue) | Should -Be $false
        } finally {
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_DISTRIBUTION_REPO", $oldRepo, "Process")
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_DISTRIBUTION_PATH", $oldPath, "Process")
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", $oldHome, "Process")
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "fails clearly when the managed vibecoding1c MCP distribution path is not a Git checkout" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vibecoding1c-mcp-distribution-invalid-" + [guid]::NewGuid().ToString("N"))
        $projectRoot = Join-Path $tempRoot "project"
        $localHome = Join-Path $tempRoot "local-home"
        $managedPath = Join-Path $localHome "distribution"
        $oldRepo = [Environment]::GetEnvironmentVariable("VIBECODING1C_MCP_DISTRIBUTION_REPO", "Process")
        $oldPath = [Environment]::GetEnvironmentVariable("VIBECODING1C_MCP_DISTRIBUTION_PATH", "Process")
        $oldHome = [Environment]::GetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", "Process")

        try {
            New-Item -ItemType Directory -Force -Path $projectRoot, $managedPath | Out-Null
            Set-Content -LiteralPath (Join-Path $managedPath "config.env") -Value "LICENSE_KEY_HELP=stale`n" -Encoding ASCII
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_DISTRIBUTION_REPO", "bad://should-not-be-used", "Process")
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_DISTRIBUTION_PATH", $null, "Process")
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", $localHome, "Process")

            {
                & {
                    . $HelperPath -ProjectRoot $projectRoot -Action help *> $null
                    Ensure-Vibecoding1cMcpDistribution | Out-Null
                }
            } | Should -Throw "*not a Git checkout*"
        } finally {
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_DISTRIBUTION_REPO", $oldRepo, "Process")
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_DISTRIBUTION_PATH", $oldPath, "Process")
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", $oldHome, "Process")
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "requires explicit remote config selection and resolves registry endpoints" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vibecoding1c-mcp-registry-select-" + [guid]::NewGuid().ToString("N"))
        $projectRoot = Join-Path $tempRoot "project"
        $registryRoot = Join-Path $tempRoot "registry"
        $localHome = Join-Path $tempRoot "local-home"
        $oldRegistryPath = [Environment]::GetEnvironmentVariable("VIBECODING1C_MCP_REGISTRY_PATH", "Process")
        $oldHome = [Environment]::GetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", "Process")

        try {
            New-Item -ItemType Directory -Force -Path $projectRoot, $registryRoot | Out-Null
            $registry = [ordered]@{
                schemaVersion = 1
                publishedAt = "2026-07-04T00:00:00Z"
                host = [ordered]@{ hostId = "host-a"; baseUrl = "http://vibecoding1c-mcp-host" }
                configurations = @(
                    [ordered]@{
                        configId = "trade"
                        title = "Trade"
                        sourceFingerprint = "remote-fingerprint"
                        reportHash = "abc"
                        indexedAt = "2026-07-04T00:00:00Z"
                    }
                )
                servers = @(
                    [ordered]@{
                        id = "code"
                        scope = "project"
                        family = "vibecoding1c"
                        provider = "remote"
                        configId = "trade"
                        name = "itl-trade-code"
                        url = "http://vibecoding1c-mcp-host:18100/mcp"
                        health = "running"
                        sourceFingerprint = "remote-fingerprint"
                        reportHash = "abc"
                        indexedAt = "2026-07-04T00:00:00Z"
                    }
                )
            }
            Set-Content -LiteralPath (Join-Path $registryRoot "registry.json") -Value (($registry | ConvertTo-Json -Depth 10) + [Environment]::NewLine) -Encoding UTF8
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_REGISTRY_PATH", $registryRoot, "Process")
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", $localHome, "Process")

            {
                & {
                    . $HelperPath -ProjectRoot $projectRoot -Action help *> $null
                    $server = (Read-Vibecoding1cMcpManifest).servers | Where-Object { $_.id -eq "code" } | Select-Object -First 1
                    New-Vibecoding1cMcpRemoteRuntime -Server $server -Selection (Read-Vibecoding1cMcpSelection) | Out-Null
                }
            } | Should -Throw "*requires explicit configuration selection*"

            & {
                . $HelperPath -ProjectRoot $projectRoot -Action help -McpServerId code -McpProvider remote -McpConfigId trade *> $null
                Set-Vibecoding1cMcpSelection *> $null
                $selection = Read-Vibecoding1cMcpSelection
                $server = (Read-Vibecoding1cMcpManifest).servers | Where-Object { $_.id -eq "code" } | Select-Object -First 1
                $runtime = New-Vibecoding1cMcpRemoteRuntime -Server $server -Selection $selection
                $runtime.url | Should -Be "http://vibecoding1c-mcp-host:18100/mcp"
                $runtime.configId | Should -Be "trade"
                (Get-Vibecoding1cMcpEndpointFreshness -Endpoint $runtime) | Should -Be "remote-shared"
            }
        } finally {
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_REGISTRY_PATH", $oldRegistryPath, "Process")
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", $oldHome, "Process")
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "keeps config-specific remote choices per server during selection" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vibecoding1c-mcp-per-server-config-select-" + [guid]::NewGuid().ToString("N"))
        $projectRoot = Join-Path $tempRoot "project"
        $registryRoot = Join-Path $tempRoot "registry"
        $localHome = Join-Path $tempRoot "local-home"
        $oldRegistryPath = [Environment]::GetEnvironmentVariable("VIBECODING1C_MCP_REGISTRY_PATH", "Process")
        $oldHome = [Environment]::GetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", "Process")
        $oldConfigId = [Environment]::GetEnvironmentVariable("VIBECODING1C_MCP_CONFIG_ID", "Process")
        $oldHostId = [Environment]::GetEnvironmentVariable("VIBECODING1C_MCP_HOST_ID", "Process")

        try {
            New-Item -ItemType Directory -Force -Path $projectRoot, $registryRoot | Out-Null
            $registry = [ordered]@{
                schemaVersion = 1
                publishedAt = "2026-07-05T00:00:00Z"
                host = [ordered]@{ hostId = "host-a"; baseUrl = "http://vibecoding1c-mcp-host" }
                configurations = @(
                    [ordered]@{ configId = "trade"; title = "Trade"; indexedAt = "2026-07-05T00:00:00Z" },
                    [ordered]@{ configId = "erp"; title = "ERP"; indexedAt = "2026-07-05T00:00:00Z" }
                )
                servers = @(
                    [ordered]@{ id = "code"; scope = "project"; family = "vibecoding1c"; provider = "remote"; configId = "trade"; name = "itl-trade-code"; url = "http://vibecoding1c-mcp-host:18100/mcp"; health = "running"; indexedAt = "2026-07-05T00:00:00Z" },
                    [ordered]@{ id = "code"; scope = "project"; family = "vibecoding1c"; provider = "remote"; configId = "erp"; name = "itl-erp-code"; url = "http://vibecoding1c-mcp-host:18101/mcp"; health = "running"; indexedAt = "2026-07-05T00:00:00Z" },
                    [ordered]@{ id = "graph"; scope = "project"; family = "vibecoding1c"; provider = "remote"; configId = "trade"; name = "itl-trade-graph"; url = "http://vibecoding1c-mcp-host:18106/mcp"; health = "running"; indexedAt = "2026-07-05T00:00:00Z" },
                    [ordered]@{ id = "graph"; scope = "project"; family = "vibecoding1c"; provider = "remote"; configId = "erp"; name = "itl-erp-graph"; url = "http://vibecoding1c-mcp-host:18107/mcp"; health = "running"; indexedAt = "2026-07-05T00:00:00Z" },
                    [ordered]@{ id = "docs"; scope = "global"; family = "vibecoding1c"; provider = "remote"; name = "itl-1c-docs"; url = "http://vibecoding1c-mcp-host:18000/mcp"; health = "running" },
                    [ordered]@{ id = "templates"; scope = "global"; family = "vibecoding1c"; provider = "remote"; name = "itl-1c-templates"; url = "http://vibecoding1c-mcp-host:18001/mcp"; health = "running" },
                    [ordered]@{ id = "syntax"; scope = "global"; family = "vibecoding1c"; provider = "remote"; name = "itl-1c-syntax"; url = "http://vibecoding1c-mcp-host:18002/mcp"; health = "running" },
                    [ordered]@{ id = "codechecker"; scope = "global"; family = "vibecoding1c"; provider = "remote"; name = "itl-1c-codechecker"; url = "http://vibecoding1c-mcp-host:18003/mcp"; health = "running" },
                    [ordered]@{ id = "ssl"; scope = "global"; family = "vibecoding1c"; provider = "remote"; name = "itl-1c-ssl"; url = "http://vibecoding1c-mcp-host:18004/mcp"; health = "running" }
                )
            }
            Set-Content -LiteralPath (Join-Path $registryRoot "registry.json") -Encoding UTF8 -Value (($registry | ConvertTo-Json -Depth 20) + [Environment]::NewLine)
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_REGISTRY_PATH", $registryRoot, "Process")
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", $localHome, "Process")
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_CONFIG_ID", $null, "Process")
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_HOST_ID", $null, "Process")

            & {
                . $HelperPath -ProjectRoot $projectRoot -Action help *> $null
                $script:vibecoding1cConfigChoices = @("trade", "erp")
                $script:vibecoding1cConfigChoiceIndex = 0

                function Test-InteractiveInputAvailable {
                    return $false
                }

                function Read-Vibecoding1cMcpRemoteConfigChoice {
                    param([object]$Selection)

                    $choice = $script:vibecoding1cConfigChoices[$script:vibecoding1cConfigChoiceIndex]
                    $script:vibecoding1cConfigChoiceIndex += 1
                    return $choice
                }

                Set-Vibecoding1cMcpSelection *> $null
                $selection = Read-Vibecoding1cMcpSelection
                $script:vibecoding1cConfigChoiceIndex | Should -Be 2
                $selection.remoteConfigId | Should -Be ""

                $codeSelection = $selection.servers | Where-Object { $_.id -eq "code" } | Select-Object -First 1
                $graphSelection = $selection.servers | Where-Object { $_.id -eq "graph" } | Select-Object -First 1
                $codeSelection.configId | Should -Be "trade"
                $graphSelection.configId | Should -Be "erp"

                $complete = Get-Vibecoding1cMcpSelectionCompleteness -Selection $selection -RefreshRegistry
                $complete.isComplete | Should -Be $true
            }
        } finally {
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_REGISTRY_PATH", $oldRegistryPath, "Process")
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", $oldHome, "Process")
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_CONFIG_ID", $oldConfigId, "Process")
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_HOST_ID", $oldHostId, "Process")
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "requires McpHostId for duplicate remote registry endpoints and resolves v2 host metadata" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vibecoding1c-mcp-registry-v2-host-select-" + [guid]::NewGuid().ToString("N"))
        $projectRoot = Join-Path $tempRoot "project"
        $registryRoot = Join-Path $tempRoot "registry"
        $localHome = Join-Path $tempRoot "local-home"
        $oldRegistryPath = [Environment]::GetEnvironmentVariable("VIBECODING1C_MCP_REGISTRY_PATH", "Process")
        $oldHome = [Environment]::GetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", "Process")

        try {
            New-Item -ItemType Directory -Force -Path $projectRoot, $registryRoot | Out-Null
            $registry = [ordered]@{
                schemaVersion = 2
                publishedAt = "2026-07-05T00:00:00Z"
                hosts = @(
                    [ordered]@{
                        hostId = "host-a"
                        baseUrl = "http://host-a"
                        publishedAt = "2026-07-05T00:00:00Z"
                        configurations = @([ordered]@{ configId = "trade"; title = "Trade"; configurationName = "Trade A"; configurationVersion = "1.0" })
                        servers = @(
                            [ordered]@{
                                id = "code"
                                scope = "project"
                                family = "vibecoding1c"
                                provider = "remote"
                                configId = "trade"
                                name = "itl-trade-code"
                                url = "http://host-a:18100/mcp"
                                health = "running"
                                configurationName = "Trade A"
                                configurationVersion = "1.0"
                                embeddingMode = "cpu"
                                embeddingModel = "intfloat/multilingual-e5-base"
                                indexedAt = "2026-07-05T00:00:00Z"
                            },
                            [ordered]@{
                                id = "docs"
                                scope = "global"
                                family = "vibecoding1c"
                                provider = "remote"
                                name = "itl-1c-docs"
                                url = "http://host-a:18000/mcp"
                                health = "running"
                            }
                        )
                    },
                    [ordered]@{
                        hostId = "host-b"
                        baseUrl = "http://host-b"
                        publishedAt = "2026-07-05T00:05:00Z"
                        configurations = @([ordered]@{ configId = "trade"; title = "Trade"; configurationName = "Trade B"; configurationVersion = "2.0" })
                        servers = @(
                            [ordered]@{
                                id = "code"
                                scope = "project"
                                family = "vibecoding1c"
                                provider = "remote"
                                configId = "trade"
                                name = "itl-trade-code"
                                url = "http://host-b:18100/mcp"
                                health = "running"
                                configurationName = "Trade B"
                                configurationVersion = "2.0"
                                embeddingMode = "cpu"
                                embeddingModel = "intfloat/multilingual-e5-base"
                                indexedAt = "2026-07-05T00:05:00Z"
                            },
                            [ordered]@{
                                id = "docs"
                                scope = "global"
                                family = "vibecoding1c"
                                provider = "remote"
                                name = "itl-1c-docs"
                                url = "http://host-b:18000/mcp"
                                health = "running"
                            }
                        )
                    }
                )
                configurations = @()
                servers = @()
            }
            Set-Content -LiteralPath (Join-Path $registryRoot "registry.json") -Value (($registry | ConvertTo-Json -Depth 20) + [Environment]::NewLine) -Encoding UTF8
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_REGISTRY_PATH", $registryRoot, "Process")
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", $localHome, "Process")

            {
                & {
                    . $HelperPath -ProjectRoot $projectRoot -Action help -McpServerId code -McpProvider remote -McpConfigId trade *> $null
                    Set-Vibecoding1cMcpSelection *> $null
                    $selection = Read-Vibecoding1cMcpSelection
                    $server = (Read-Vibecoding1cMcpManifest).servers | Where-Object { $_.id -eq "code" } | Select-Object -First 1
                    New-Vibecoding1cMcpRemoteRuntime -Server $server -Selection $selection | Out-Null
                }
            } | Should -Throw "*multiple matching hosts*"

            & {
                . $HelperPath -ProjectRoot $projectRoot -Action help -McpServerId code -McpProvider remote -McpConfigId trade -McpHostId host-b *> $null
                Set-Vibecoding1cMcpSelection *> $null
                $selection = Read-Vibecoding1cMcpSelection
                $selection.remoteConfigId | Should -Be ""
                $selection.remoteHostId | Should -Be ""
                $selectionEntry = $selection.servers | Where-Object { $_.id -eq "code" } | Select-Object -First 1
                $selectionEntry.configId | Should -Be "trade"
                $selectionEntry.hostId | Should -Be "host-b"
                $server = (Read-Vibecoding1cMcpManifest).servers | Where-Object { $_.id -eq "code" } | Select-Object -First 1
                $runtime = New-Vibecoding1cMcpRemoteRuntime -Server $server -Selection $selection
                $runtime.url | Should -Be "http://host-b:18100/mcp"
                $runtime.hostId | Should -Be "host-b"
                $runtime.configurationName | Should -Be "Trade B"
                $runtime.configurationVersion | Should -Be "2.0"
                $runtime.embeddingModel | Should -Be "intfloat/multilingual-e5-base"
            }

            {
                & {
                    . $HelperPath -ProjectRoot $projectRoot -Action help -McpServerId docs -McpProvider remote *> $null
                    Set-Vibecoding1cMcpSelection *> $null
                    $selection = Read-Vibecoding1cMcpSelection
                    $server = (Read-Vibecoding1cMcpManifest).servers | Where-Object { $_.id -eq "docs" } | Select-Object -First 1
                    New-Vibecoding1cMcpRemoteRuntime -Server $server -Selection $selection | Out-Null
                }
            } | Should -Throw "*multiple matching hosts*"

            & {
                . $HelperPath -ProjectRoot $projectRoot -Action help -McpServerId docs -McpProvider remote -McpHostId host-b *> $null
                Set-Vibecoding1cMcpSelection *> $null
                $selection = Read-Vibecoding1cMcpSelection
                $selectionEntry = $selection.servers | Where-Object { $_.id -eq "docs" } | Select-Object -First 1
                $selectionEntry.configId | Should -Be ""
                $selectionEntry.hostId | Should -Be "host-b"
                $server = (Read-Vibecoding1cMcpManifest).servers | Where-Object { $_.id -eq "docs" } | Select-Object -First 1
                $runtime = New-Vibecoding1cMcpRemoteRuntime -Server $server -Selection $selection
                $runtime.url | Should -Be "http://host-b:18000/mcp"
                $runtime.hostId | Should -Be "host-b"
                $runtime.configId | Should -Be ""
            }
        } finally {
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_REGISTRY_PATH", $oldRegistryPath, "Process")
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", $oldHome, "Process")
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "marks missing and incomplete vibecoding1c MCP selections before setup" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vibecoding1c-mcp-selection-complete-" + [guid]::NewGuid().ToString("N"))
        $projectRoot = Join-Path $tempRoot "project"
        $oldHome = [Environment]::GetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", "Process")

        try {
            New-Item -ItemType Directory -Force -Path $projectRoot | Out-Null
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", (Join-Path $tempRoot "local-home"), "Process")

            & {
                . $HelperPath -ProjectRoot $projectRoot -Action help *> $null
                $missing = Get-Vibecoding1cMcpSelectionCompleteness -Selection (Read-Vibecoding1cMcpSelection)
                $missing.isComplete | Should -Be $false
                $missing.reasons | Should -Contain "selection file is missing"

                $serverIds = @("docs", "templates", "syntax", "codechecker", "ssl", "code", "graph")
                $selectionPath = Get-Vibecoding1cMcpSelectionPath
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $selectionPath) | Out-Null
                $incompleteSelection = [ordered]@{
                    schemaVersion = 1
                    family = "vibecoding1c"
                    defaultProvider = "remote"
                    remoteConfigId = ""
                    remoteHostId = ""
                    localScopeDefault = "project"
                    servers = @($serverIds | ForEach-Object {
                        [ordered]@{ id = $_; family = "vibecoding1c"; provider = "remote"; configId = ""; hostId = ""; localScope = "project" }
                    })
                }
                Set-Content -LiteralPath $selectionPath -Encoding UTF8 -Value (($incompleteSelection | ConvertTo-Json -Depth 10) + [Environment]::NewLine)

                $incomplete = Get-Vibecoding1cMcpSelectionCompleteness -Selection (Read-Vibecoding1cMcpSelection)
                $incomplete.isComplete | Should -Be $false
                ($incomplete.reasons -join [Environment]::NewLine) | Should -Match "code/project remote provider has no configId"

                $completeSelection = [ordered]@{
                    schemaVersion = 1
                    family = "vibecoding1c"
                    defaultProvider = "remote"
                    remoteConfigId = "trade"
                    remoteHostId = "host-a"
                    localScopeDefault = "project"
                    servers = @($serverIds | ForEach-Object {
                        [ordered]@{
                            id = $_
                            family = "vibecoding1c"
                            provider = "remote"
                            configId = $(if ($_ -eq "code" -or $_ -eq "graph") { "trade" } else { "" })
                            hostId = "host-a"
                            localScope = "project"
                        }
                    })
                }
                Set-Content -LiteralPath $selectionPath -Encoding UTF8 -Value (($completeSelection | ConvertTo-Json -Depth 10) + [Environment]::NewLine)

                $complete = Get-Vibecoding1cMcpSelectionCompleteness -Selection (Read-Vibecoding1cMcpSelection)
                $complete.isComplete | Should -Be $true
            }
        } finally {
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", $oldHome, "Process")
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "ignores legacy Vanessa entries from external vibecoding1c manifests and endpoints" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vibecoding1c-mcp-legacy-vanessa-" + [guid]::NewGuid().ToString("N"))
        $projectRoot = Join-Path $tempRoot "project"
        $distributionRoot = Join-Path $tempRoot "distribution"
        $oldHome = [Environment]::GetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", "Process")

        try {
            New-Item -ItemType Directory -Force -Path $projectRoot, $distributionRoot | Out-Null
            $servers = @(
                [ordered]@{ id = "docs"; scope = "global" },
                [ordered]@{ id = "templates"; scope = "global" },
                [ordered]@{ id = "syntax"; scope = "global" },
                [ordered]@{ id = "codechecker"; scope = "global" },
                [ordered]@{ id = "ssl"; scope = "global" },
                [ordered]@{ id = "code"; scope = "project" },
                [ordered]@{ id = "graph"; scope = "project" },
                [ordered]@{ id = "vanessa"; scope = "branch"; title = "Branch Vanessa Automation MCP" }
            )
            $manifest = [ordered]@{ schemaVersion = 1; package = "vibecoding1c"; servers = $servers }
            Set-Content -LiteralPath (Join-Path $distributionRoot "vibecoding1c-mcp.manifest.json") -Encoding UTF8 -Value (($manifest | ConvertTo-Json -Depth 10) + [Environment]::NewLine)
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", (Join-Path $tempRoot "local-home"), "Process")

            & {
                . $HelperPath -ProjectRoot $projectRoot -Action help -McpDistributionPath $distributionRoot -McpScope all *> $null

                $selectedIds = @(Select-Vibecoding1cMcpManifestServers | ForEach-Object { [string]$_.id })
                $selectedIds | Should -Not -Contain "vanessa"
                $selectedIds.Count | Should -Be 7

                $selectionPath = Get-Vibecoding1cMcpSelectionPath
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $selectionPath) | Out-Null
                $selection = [ordered]@{
                    schemaVersion = 1
                    family = "vibecoding1c"
                    defaultProvider = "local"
                    remoteConfigId = ""
                    remoteHostId = ""
                    localScopeDefault = "project"
                    servers = @($selectedIds | ForEach-Object {
                        [ordered]@{ id = $_; family = "vibecoding1c"; provider = "local"; configId = ""; hostId = ""; localScope = "project" }
                    })
                }
                Set-Content -LiteralPath $selectionPath -Encoding UTF8 -Value (($selection | ConvertTo-Json -Depth 10) + [Environment]::NewLine)

                $complete = Get-Vibecoding1cMcpSelectionCompleteness -Selection (Read-Vibecoding1cMcpSelection)
                $complete.isComplete | Should -Be $true
                ($complete.reasons -join [Environment]::NewLine) | Should -Not -Match "vanessa/branch"

                $legacyEndpoint = [pscustomobject]@{ id = "vanessa"; scope = "branch"; family = "vibecoding1c"; provider = "remote"; name = "legacy-vanessa"; url = "http://localhost:9874/mcp"; health = "running" }
                (Test-Vibecoding1cMcpEndpointAllowedForProject -Endpoint $legacyEndpoint) | Should -Be $false
                @(Select-Vibecoding1cMcpClientConfigEndpoints -Endpoints @($legacyEndpoint)).Count | Should -Be 0
            }
        } finally {
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", $oldHome, "Process")
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "gates BookStack product MCP by base configuration version" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vibecoding1c-mcp-pm-gate-" + [guid]::NewGuid().ToString("N"))
        $pm4Root = Join-Path $tempRoot "pm4"
        $pm5Root = Join-Path $tempRoot "pm5"
        $missingRoot = Join-Path $tempRoot "missing"
        $oldBookStackEnabled = [Environment]::GetEnvironmentVariable("VIBECODING1C_MCP_BOOKSTACK_ENABLED", "Process")
        $oldBaseVersion = [Environment]::GetEnvironmentVariable("BASE_CONFIGURATION_VERSION", "Process")

        try {
            New-Item -ItemType Directory -Force -Path `
                (Join-Path $pm4Root ".agent-1c"),
                (Join-Path $pm5Root ".agent-1c"),
                $missingRoot | Out-Null
            Set-Content -LiteralPath (Join-Path $pm4Root ".agent-1c\project.json") -Encoding UTF8 -Value (@{ schemaVersion = 1; baseConfigurationVersion = "PM4" } | ConvertTo-Json)
            Set-Content -LiteralPath (Join-Path $pm5Root ".agent-1c\project.json") -Encoding UTF8 -Value (@{ schemaVersion = 1; baseConfigurationVersion = "PM5" } | ConvertTo-Json)
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_BOOKSTACK_ENABLED", "true", "Process")
            [Environment]::SetEnvironmentVariable("BASE_CONFIGURATION_VERSION", $null, "Process")

            $pm4Ids = & {
                . $HelperPath -ProjectRoot $pm4Root -Action help *> $null
                @(Select-Vibecoding1cMcpManifestServers | ForEach-Object { [string]$_.id })
            }
            $pm5Ids = & {
                . $HelperPath -ProjectRoot $pm5Root -Action help *> $null
                @(Select-Vibecoding1cMcpManifestServers | ForEach-Object { [string]$_.id })
            }
            $missingIds = & {
                . $HelperPath -ProjectRoot $missingRoot -Action help *> $null
                @(Select-Vibecoding1cMcpManifestServers | ForEach-Object { [string]$_.id })
            }

            $pm4Ids | Should -Not -Contain "bookstack"
            $pm5Ids | Should -Contain "bookstack"
            $missingIds | Should -Contain "bookstack"
        } finally {
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_BOOKSTACK_ENABLED", $oldBookStackEnabled, "Process")
            [Environment]::SetEnvironmentVariable("BASE_CONFIGURATION_VERSION", $oldBaseVersion, "Process")
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "skips incomplete inherited vibecoding1c MCP selection without failing branch setup" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vibecoding1c-mcp-incomplete-inherit-" + [guid]::NewGuid().ToString("N"))
        $mainRoot = Join-Path $tempRoot "main"
        $branchRoot = Join-Path $tempRoot "branch"
        $oldHome = [Environment]::GetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", "Process")

        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $mainRoot ".agent-1c\mcp"), $branchRoot | Out-Null
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", (Join-Path $tempRoot "local-home"), "Process")

            $selection = [ordered]@{
                schemaVersion = 1
                family = "vibecoding1c"
                defaultProvider = "remote"
                remoteConfigId = ""
                remoteHostId = ""
                localScopeDefault = "project"
                servers = @(
                    [ordered]@{ id = "code"; family = "vibecoding1c"; provider = "remote"; configId = ""; hostId = ""; localScope = "project" },
                    [ordered]@{ id = "graph"; family = "vibecoding1c"; provider = "remote"; configId = ""; hostId = ""; localScope = "project" }
                )
            }
            Set-Content -LiteralPath (Join-Path $mainRoot ".agent-1c\mcp\vibecoding1c-selection.json") -Encoding UTF8 -Value (($selection | ConvertTo-Json -Depth 10) + [Environment]::NewLine)

            $result = & {
                . $HelperPath -ProjectRoot $branchRoot -Action help -McpScope project *> $null
                Invoke-DevBranchVibecoding1cMcpInheritance -MainProjectRoot $mainRoot *> $null
                [pscustomobject]@{
                    selectionExists = Test-Path -LiteralPath (Join-Path $branchRoot ".agent-1c\mcp\vibecoding1c-selection.json") -PathType Leaf
                    codexExists = Test-Path -LiteralPath (Join-Path $branchRoot ".codex\config.toml") -PathType Leaf
                    stateExists = Test-Path -LiteralPath (Join-Path $branchRoot ".agent-1c\mcp\state.json") -PathType Leaf
                }
            }

            $result.selectionExists | Should -BeTrue
            $result.codexExists | Should -BeFalse
            $result.stateExists | Should -BeFalse
        } finally {
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", $oldHome, "Process")
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "requires a host selection for duplicate remote endpoints and formats host details for selection" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vibecoding1c-mcp-selection-host-details-" + [guid]::NewGuid().ToString("N"))
        $projectRoot = Join-Path $tempRoot "project"
        $registryRoot = Join-Path $tempRoot "registry"
        $oldRegistryPath = [Environment]::GetEnvironmentVariable("VIBECODING1C_MCP_REGISTRY_PATH", "Process")
        $oldHome = [Environment]::GetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", "Process")

        try {
            New-Item -ItemType Directory -Force -Path $projectRoot, $registryRoot | Out-Null
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_REGISTRY_PATH", $registryRoot, "Process")
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", (Join-Path $tempRoot "local-home"), "Process")

            $registry = [ordered]@{
                schemaVersion = 2
                publishedAt = "2026-07-05T00:10:00Z"
                hosts = @(
                    [ordered]@{
                        hostId = "host-a"
                        baseUrl = "http://host-a"
                        publishedAt = "2026-07-05T00:00:00Z"
                        configurations = @([ordered]@{ configId = "trade"; title = "Trade"; configurationName = "Trade A"; configurationVersion = "1.0" })
                        servers = @(
                            [ordered]@{ id = "code"; scope = "project"; family = "vibecoding1c"; provider = "remote"; configId = "trade"; name = "itl-trade-code"; url = "http://host-a:18100/mcp"; health = "running"; configurationName = "Trade A"; configurationVersion = "1.0"; embeddingModel = "intfloat/multilingual-e5-base"; indexedAt = "2026-07-05T00:00:00Z" },
                            [ordered]@{ id = "docs"; scope = "global"; family = "vibecoding1c"; provider = "remote"; name = "itl-1c-docs"; url = "http://host-a:18000/mcp"; health = "running" }
                        )
                    },
                    [ordered]@{
                        hostId = "host-b"
                        baseUrl = "http://host-b"
                        publishedAt = "2026-07-05T00:05:00Z"
                        configurations = @([ordered]@{ configId = "trade"; title = "Trade"; configurationName = "Trade B"; configurationVersion = "2.0" })
                        servers = @(
                            [ordered]@{ id = "code"; scope = "project"; family = "vibecoding1c"; provider = "remote"; configId = "trade"; name = "itl-trade-code"; url = "http://host-b:18100/mcp"; health = "running"; configurationName = "Trade B"; configurationVersion = "2.0"; embeddingModel = "intfloat/multilingual-e5-base"; indexedAt = "2026-07-05T00:05:00Z" },
                            [ordered]@{ id = "docs"; scope = "global"; family = "vibecoding1c"; provider = "remote"; name = "itl-1c-docs"; url = "http://host-b:18000/mcp"; health = "running" }
                        )
                    }
                )
                configurations = @()
                servers = @()
            }
            Set-Content -LiteralPath (Join-Path $registryRoot "registry.json") -Encoding UTF8 -Value (($registry | ConvertTo-Json -Depth 20) + [Environment]::NewLine)

            & {
                . $HelperPath -ProjectRoot $projectRoot -Action help *> $null
                $serverIds = @("docs", "templates", "syntax", "codechecker", "ssl", "code", "graph")
                $selectionPath = Get-Vibecoding1cMcpSelectionPath
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $selectionPath) | Out-Null
                $selection = [ordered]@{
                    schemaVersion = 1
                    family = "vibecoding1c"
                    defaultProvider = "remote"
                    remoteConfigId = "trade"
                    remoteHostId = ""
                    localScopeDefault = "project"
                    servers = @($serverIds | ForEach-Object {
                        $isRemoteTestServer = ($_ -eq "code" -or $_ -eq "docs")
                        [ordered]@{
                            id = $_
                            family = "vibecoding1c"
                            provider = $(if ($isRemoteTestServer) { "remote" } else { "local" })
                            configId = $(if ($_ -eq "code") { "trade" } else { "" })
                            hostId = ""
                            localScope = "project"
                        }
                    })
                }
                Set-Content -LiteralPath $selectionPath -Encoding UTF8 -Value (($selection | ConvertTo-Json -Depth 10) + [Environment]::NewLine)

                $duplicate = Get-Vibecoding1cMcpSelectionCompleteness -Selection (Read-Vibecoding1cMcpSelection) -RefreshRegistry
                $duplicate.isComplete | Should -Be $false
                ($duplicate.reasons -join [Environment]::NewLine) | Should -Match "code/project remote provider has multiple matching hosts and no hostId"
                ($duplicate.reasons -join [Environment]::NewLine) | Should -Match "docs/global remote provider has multiple matching hosts and no hostId"

                $endpoint = (Get-Vibecoding1cMcpRegistryServers -Registry (Read-Vibecoding1cMcpRegistry) | Where-Object { [string](Get-Vibecoding1cMcpObjectValue -Object $_ -Name "hostId" -Default "") -eq "host-b" } | Select-Object -First 1)
                $details = Format-Vibecoding1cMcpRemoteEndpointInfo -Endpoint $endpoint
                $details | Should -Match "hostId=host-b"
                $details | Should -Match ([regex]::Escape("url=http://host-b:18100/mcp"))
                $details | Should -Match "health=running"
                $details | Should -Match "configId=trade"
                $details | Should -Match "configuration=Trade B 2.0"
                $details | Should -Match "model=intfloat/multilingual-e5-base"
                $details | Should -Match "indexedAt=2026-07-05T00:05:00Z"

                foreach ($serverSelection in $selection["servers"]) {
                    if ($serverSelection["id"] -eq "code" -or $serverSelection["id"] -eq "docs") {
                        $serverSelection["hostId"] = "host-b"
                    }
                }
                Set-Content -LiteralPath $selectionPath -Encoding UTF8 -Value (($selection | ConvertTo-Json -Depth 10) + [Environment]::NewLine)
                $complete = Get-Vibecoding1cMcpSelectionCompleteness -Selection (Read-Vibecoding1cMcpSelection) -RefreshRegistry
                $complete.isComplete | Should -Be $true
            }
        } finally {
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_REGISTRY_PATH", $oldRegistryPath, "Process")
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", $oldHome, "Process")
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "marks a single unusable global remote endpoint as incomplete and skips runtime connection" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vibecoding1c-mcp-global-unusable-" + [guid]::NewGuid().ToString("N"))
        $projectRoot = Join-Path $tempRoot "project"
        $registryRoot = Join-Path $tempRoot "registry"
        $oldRegistryPath = [Environment]::GetEnvironmentVariable("VIBECODING1C_MCP_REGISTRY_PATH", "Process")
        $oldHome = [Environment]::GetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", "Process")

        try {
            New-Item -ItemType Directory -Force -Path $projectRoot, $registryRoot | Out-Null
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_REGISTRY_PATH", $registryRoot, "Process")
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", (Join-Path $tempRoot "local-home"), "Process")

            $registry = [ordered]@{
                schemaVersion = 2
                publishedAt = "2026-07-05T00:10:00Z"
                hosts = @([ordered]@{
                    hostId = "dead-host"
                    baseUrl = "http://dead-host"
                    publishedAt = "2026-07-05T00:00:00Z"
                    configurations = @()
                    servers = @([ordered]@{ id = "docs"; scope = "global"; family = "vibecoding1c"; provider = "remote"; name = "itl-1c-docs"; url = "http://dead-host:18000/mcp"; status = "missing"; health = "missing" })
                })
                configurations = @()
                servers = @()
            }
            Set-Content -LiteralPath (Join-Path $registryRoot "registry.json") -Encoding UTF8 -Value (($registry | ConvertTo-Json -Depth 20) + [Environment]::NewLine)

            & {
                . $HelperPath -ProjectRoot $projectRoot -Action help -McpServerId docs -McpProvider remote *> $null
                Set-Vibecoding1cMcpSelection *> $null
                $selection = Read-Vibecoding1cMcpSelection
                $selectionEntry = $selection.servers | Where-Object { $_.id -eq "docs" } | Select-Object -First 1
                $selectionEntry.hostId | Should -Be ""

                $complete = Get-Vibecoding1cMcpSelectionCompleteness -Selection $selection -RefreshRegistry
                $complete.isComplete | Should -Be $false
                ($complete.reasons -join [Environment]::NewLine) | Should -Match "docs/global remote provider has no usable endpoint"

                $server = (Read-Vibecoding1cMcpManifest).servers | Where-Object { $_.id -eq "docs" } | Select-Object -First 1
                $runtime = New-Vibecoding1cMcpRemoteRuntime -Server $server -Selection $selection
                $runtime | Should -BeNullOrEmpty
            }
        } finally {
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_REGISTRY_PATH", $oldRegistryPath, "Process")
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", $oldHome, "Process")
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "shows vibecoding1c MCP active, skipped, stale, and missing-configId status groups" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vibecoding1c-mcp-status-groups-" + [guid]::NewGuid().ToString("N"))
        $projectRoot = Join-Path $tempRoot "project"
        $localHome = Join-Path $tempRoot "local-home"
        $oldHome = [Environment]::GetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", "Process")

        try {
            New-Item -ItemType Directory -Force -Path `
                $projectRoot,
                (Join-Path $projectRoot ".agent-1c\mcp"),
                $localHome | Out-Null

            $selection = [ordered]@{
                schemaVersion = 1
                family = "vibecoding1c"
                defaultProvider = "remote"
                remoteConfigId = ""
                localScopeDefault = "project"
                servers = @(
                    [ordered]@{ id = "docs"; provider = "local"; localScope = "project"; configId = "" },
                    [ordered]@{ id = "templates"; provider = "remote"; localScope = "project"; configId = "" }
                )
                updatedAt = "2026-07-04T00:00:00Z"
            }
            Set-Content -LiteralPath (Join-Path $projectRoot ".agent-1c\mcp\vibecoding1c-selection.json") -Encoding UTF8 -Value (($selection | ConvertTo-Json -Depth 10) + [Environment]::NewLine)

            $state = [ordered]@{
                schemaVersion = 1
                model = [ordered]@{ modelId = "fixture-model"; ready = $true }
                staleIndexes = @("docs")
                servers = @(
                    [ordered]@{
                        id = "docs"
                        scope = "global"
                        name = "itl-1c-docs"
                        url = "http://127.0.0.1:18003/mcp"
                        status = "running"
                        family = "vibecoding1c"
                        provider = "local"
                        configId = ""
                        sourceFingerprint = "old-fingerprint"
                    },
                    [ordered]@{
                        id = "templates"
                        scope = "global"
                        name = "itl-1c-templates"
                        url = ""
                        status = "missing-settings"
                        family = "vibecoding1c"
                        provider = "remote"
                        configId = ""
                    }
                )
                updatedAt = "2026-07-04T00:00:00Z"
            }
            Set-Content -LiteralPath (Join-Path $localHome "state.json") -Encoding UTF8 -Value (($state | ConvertTo-Json -Depth 10) + [Environment]::NewLine)
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", $localHome, "Process")

            $output = & powershell -NoProfile -ExecutionPolicy Bypass -File $HelperPath -ProjectRoot $projectRoot -Action vibecoding1c-mcp-status 2>&1
            $LASTEXITCODE | Should -Be 0
            $statusText = ($output -join [Environment]::NewLine)

            $statusText | Should -Match "vibecoding1c MCP active servers: .*itl-1c-docs/local/stale"
            $statusText | Should -Match "vibecoding1c MCP skipped servers: .*templates/global/remote/missing-settings"
            $statusText | Should -Match "vibecoding1c MCP stale servers: .*itl-1c-docs/stale"
            $statusText | Should -Match "vibecoding1c MCP missing-configId servers: .*code/project"
            $statusText | Should -Match "vibecoding1c MCP stale indexes: docs"
        } finally {
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", $oldHome, "Process")
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "removes PM5-only managed BookStack client config for PM4 projects" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vibecoding1c-mcp-pm4-client-config-" + [guid]::NewGuid().ToString("N"))
        $projectRoot = Join-Path $tempRoot "project"
        $localHome = Join-Path $tempRoot "local-home"
        $codexHomeConfig = Join-Path $tempRoot "codex-home\config.toml"
        $oldHome = [Environment]::GetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", "Process")
        $oldBaseVersion = [Environment]::GetEnvironmentVariable("BASE_CONFIGURATION_VERSION", "Process")

        try {
            New-Item -ItemType Directory -Force -Path `
                (Join-Path $projectRoot ".agent-1c\mcp"),
                (Join-Path $projectRoot ".codex"),
                (Join-Path $projectRoot ".kilo"),
                (Split-Path -Parent $codexHomeConfig),
                $localHome | Out-Null
            Set-Content -LiteralPath (Join-Path $projectRoot ".agent-1c\project.json") -Encoding UTF8 -Value (@{ schemaVersion = 1; baseConfigurationVersion = "PM4"; aiRules = @{ tools = @("kilocode") } } | ConvertTo-Json -Depth 5)
            Set-Content -LiteralPath (Join-Path $projectRoot ".ai-rules.json") -Encoding UTF8 -Value '{"schemaVersion":1,"tools":["kilocode"],"files":{}}'

            $state = [ordered]@{
                schemaVersion = 1
                servers = @(
                    [ordered]@{
                        id = "docs"
                        scope = "global"
                        name = "itl-1c-docs"
                        url = "http://127.0.0.1:18003/mcp"
                        status = "running"
                        family = "vibecoding1c"
                        provider = "remote"
                        configId = ""
                    },
                    [ordered]@{
                        id = "bookstack"
                        scope = "global"
                        name = "bookstack-product-docs"
                        url = "http://127.0.0.1:18009/mcp"
                        status = "running"
                        family = "vibecoding1c"
                        provider = "remote"
                        configId = ""
                    }
                )
            }
            Set-Content -LiteralPath (Join-Path $localHome "state.json") -Encoding UTF8 -Value (($state | ConvertTo-Json -Depth 10) + [Environment]::NewLine)

            $codexText = @'
[mcp_servers."BookStack-product-docs-mcp"]
url = "http://127.0.0.1:18009/mcp"
managedBy = "vibecoding1c-mcp"
family = "vibecoding1c"

[mcp_servers."external-product-docs"]
url = "http://127.0.0.1:19999/mcp"
enabled = true
'@
            Set-Content -LiteralPath $codexHomeConfig -Encoding UTF8 -Value ($codexText + [Environment]::NewLine)

            $kiloConfig = [ordered]@{
                mcp = [ordered]@{
                    "BookStack-product-docs-mcp" = [ordered]@{
                        type = "remote"
                        url = "http://127.0.0.1:18009/mcp"
                        enabled = $true
                        managedBy = "vibecoding1c-mcp"
                        family = "vibecoding1c"
                        logicalId = "bookstack"
                    }
                    "external-product-docs" = [ordered]@{
                        type = "remote"
                        url = "http://127.0.0.1:19999/mcp"
                        enabled = $true
                    }
                }
            }
            Set-Content -LiteralPath (Join-Path $projectRoot ".kilo\kilo.json") -Encoding UTF8 -Value (($kiloConfig | ConvertTo-Json -Depth 10) + [Environment]::NewLine)
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", $localHome, "Process")
            [Environment]::SetEnvironmentVariable("BASE_CONFIGURATION_VERSION", $null, "Process")

            & {
                . $HelperPath -ProjectRoot $projectRoot -Action help *> $null
                $script:TestCodexHomeConfigPath = $codexHomeConfig
                function Get-Vibecoding1cMcpCodexHomeConfigPath {
                    return $script:TestCodexHomeConfigPath
                }
                Write-Vibecoding1cMcpClientConfig *> $null
            }

            $updatedCodex = Get-Content -Encoding UTF8 -Raw $codexHomeConfig
            $updatedKilo = Get-Content -Encoding UTF8 -Raw (Join-Path $projectRoot ".kilo\kilo.json") | ConvertFrom-Json

            $updatedCodex | Should -Match "BookStack-product-docs-mcp"
            $updatedCodex | Should -Not -Match "1C-docs-mcp"
            $updatedCodex | Should -Match "external-product-docs"
            $updatedKilo.mcp.PSObject.Properties.Name | Should -Not -Contain "BookStack-product-docs-mcp"
            $updatedKilo.mcp.PSObject.Properties.Name | Should -Contain "1C-docs-mcp"
            $updatedKilo.mcp.PSObject.Properties.Name | Should -Contain "external-product-docs"
        } finally {
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", $oldHome, "Process")
            [Environment]::SetEnvironmentVariable("BASE_CONFIGURATION_VERSION", $oldBaseVersion, "Process")
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "does not store concrete MCP license key values in tracked text files" {
        $tracked = @(& git -C $RepoRoot ls-files)
        $textExtensions = @(".ps1", ".md", ".json", ".jsonc", ".yml", ".yaml", ".example", ".gitignore", ".toml")
        foreach ($relativePath in $tracked) {
            if ($relativePath -match '[<>:"|?*\x00-\x1F]') {
                continue
            }
            $extension = [System.IO.Path]::GetExtension($relativePath)
            if ($textExtensions -notcontains $extension -and $relativePath -notlike "templates/*" -and $relativePath -notlike ".gitignore") {
                continue
            }
            $path = Join-Path $RepoRoot $relativePath
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                continue
            }
            $text = Get-Content -Encoding UTF8 -Raw $path
            $text | Should -Not -Match '(?m)^\s*LICENSE_KEY_[A-Z0-9_]+\s*=\s*[^#\s]+'
            $text | Should -Not -Match '(?m)^\s*ONEC_AI_TOKEN\s*=\s*(?!<)[^#\s]+'
            $text | Should -Not -Match '"ONEC_AI_TOKEN"\s*:\s*"(?!<)[^"]+"'
            $text | Should -Not -Match '(?m)^\s*BOOKSTACK_TOKEN_(ID|SECRET)\s*=\s*(?!<)[^#\s]+'
            $text | Should -Not -Match '"BOOKSTACK_TOKEN_(ID|SECRET)"\s*:\s*"(?!<)[^"]+"'
        }
    }

    It "caches Vanessa UI MCP CFE artifacts, shares them with a worktree, and verifies locked hashes" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vanessa-ui-mcp-cache-test-" + [guid]::NewGuid().ToString("N"))
        $masterRoot = Join-Path $tempRoot "master"
        $branchRoot = Join-Path $tempRoot "branch"

        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $masterRoot ".agent-1c"), (Join-Path $branchRoot ".agent-1c"), (Join-Path $tempRoot "fixtures") | Out-Null
            Copy-Item -LiteralPath (Join-Path $RepoRoot "templates\project.json") -Destination (Join-Path $masterRoot ".agent-1c\project.json")
            Copy-Item -LiteralPath (Join-Path $RepoRoot "templates\project.json") -Destination (Join-Path $branchRoot ".agent-1c\project.json")
            $clientSource = Join-Path $tempRoot "fixtures\client_mcp.cfe"
            $extensionSource = Join-Path $tempRoot "fixtures\VAExtension.fixture.cfe"
            Set-Content -LiteralPath $clientSource -Encoding UTF8 -Value "client fixture"
            Set-Content -LiteralPath $extensionSource -Encoding UTF8 -Value "extension fixture"
            $clientUri = ([System.Uri]$clientSource).AbsoluteUri
            $extensionUri = ([System.Uri]$extensionSource).AbsoluteUri
            Set-Content -LiteralPath (Join-Path $masterRoot ".dev.env") -Encoding UTF8 -Value @"
DEPENDENCY_MODE=fresh
VANESSA_MCP_CLIENT_CFE_URL=$clientUri
VANESSA_MCP_VA_EXTENSION_CFE_URL=$extensionUri
"@

            $masterArtifacts = & {
                . $HelperPath -ProjectRoot $masterRoot -Action help *> $null
                @(Install-VanessaMcpArtifacts)
            }
            $masterArtifacts.Count | Should -Be 2
            $masterClient = @($masterArtifacts | Where-Object { $_.key -eq "clientMcp" })[0]
            $masterExtension = @($masterArtifacts | Where-Object { $_.key -eq "vaExtension" })[0]
            $masterClient.path | Should -Not -BeNullOrEmpty
            $masterExtension.path | Should -Not -BeNullOrEmpty
            (Test-Path -LiteralPath $masterClient.path -PathType Leaf) | Should -Be $true
            (Test-Path -LiteralPath $masterExtension.path -PathType Leaf) | Should -Be $true

            $masterLock = Get-Content -Encoding UTF8 -Raw (Join-Path $masterRoot ".agent-1c\dependency-lock.json") | ConvertFrom-Json
            $masterLock.dependencies.vanessaMcp.clientMcp.sha256 | Should -Be $masterClient.sha256
            $masterLock.dependencies.vanessaMcp.vaExtension.sha256 | Should -Be $masterExtension.sha256
            $masterLock.dependencies.vanessaMcp.clientMcp.assetName | Should -Be "client_mcp.cfe"

            & {
                . $HelperPath -ProjectRoot $masterRoot -Action help *> $null
                Copy-DotEnvToWorktree -WorktreePath $branchRoot
            }
            Copy-Item -LiteralPath (Join-Path $masterRoot ".agent-1c\dependency-lock.json") -Destination (Join-Path $branchRoot ".agent-1c\dependency-lock.json")
            $branchArtifacts = & {
                . $HelperPath -ProjectRoot $branchRoot -Action help *> $null
                @(Install-VanessaMcpArtifacts)
            }
            (@($branchArtifacts | Where-Object { $_.key -eq "clientMcp" })[0].path) | Should -Be $masterClient.path
            (@($branchArtifacts | Where-Object { $_.key -eq "vaExtension" })[0].path) | Should -Be $masterExtension.path

            $lockedManifest = Get-Content -Encoding UTF8 -Raw (Join-Path $branchRoot ".agent-1c\dependency-lock.json") | ConvertFrom-Json
            $lockedManifest.dependencies.vanessaMcp.clientMcp.version = "fixture"
            $lockedManifest.dependencies.vanessaMcp.vaExtension.version = "fixture"
            Set-Content -LiteralPath (Join-Path $branchRoot ".agent-1c\dependency-lock.json") -Encoding UTF8 -Value (($lockedManifest | ConvertTo-Json -Depth 10) + [Environment]::NewLine)
            Add-Content -LiteralPath (Join-Path $branchRoot ".dev.env") -Encoding UTF8 -Value "DEPENDENCY_MODE=locked"
            Set-Content -LiteralPath $masterClient.path -Encoding UTF8 -Value "corrupted fixture"

            {
                & {
                    . $HelperPath -ProjectRoot $branchRoot -Action help *> $null
                    Install-VanessaMcpArtifacts | Out-Null
                }
            } | Should -Throw "*SHA256 mismatch*"
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "wires branch-local Vanessa UI MCP actions, cache, and local artifacts" {
        $actions = @("install-vanessa-mcp", "start-vanessa-mcp", "stop-vanessa-mcp", "vanessa-mcp-status")
        foreach ($action in $actions) {
            $HelperText | Should -Match ([regex]::Escape("`"$action`""))
        }

        $HelperText | Should -Match "Resolve-VanessaMcpPort"
        $HelperText | Should -Match "VANESSA_MCP_PORT_RANGE"
        $HelperText | Should -Match "client_mcp.cfe"
        $HelperText | Should -Match "VAExtension"
        $HelperText | Should -Match "Install-VanessaMcpArtifacts"
        $HelperText | Should -Match "Update-VanessaMcpArtifacts"
        $HelperText | Should -Match "Get-VanessaMcpArtifactLockEntry"
        $HelperText | Should -Match 'lockKey = "clientMcp"'
        $HelperText | Should -Match 'lockKey = "vaExtension"'
        $HelperText | Should -Match "VANESSA_MCP_CLIENT_CFE_PATH"
        $HelperText | Should -Match "VANESSA_MCP_VA_EXTENSION_CFE_PATH"
        $HelperText | Should -Match "runMcp;mcpPort="
        $HelperText | Should -Match "Write-VanessaMcpKiloConfig"
        $HelperText | Should -Match "function Stop-VanessaMcpForState[\s\S]+Write-VanessaMcpClientConfig"
        $HelperText | Should -Match 'managedBy = "vanessa-ui-mcp"'
        $HelperText | Should -Match 'family = "vanessa-ui"'
        $HelperText | Should -Match "Vanessa UI MCP"
        $HelperText | Should -Match "Vanessa Automation verification"
        $HelperText | Should -Match "reload or restart Kilo Code"
        $HelperText | Should -Match "StartFeaturePlayer"

        $mcpToolPath = ".agent-1c/tools/vanessa-mcp/"
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".gitignore")) | Should -Match ([regex]::Escape($mcpToolPath))
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\gitignore.append")) | Should -Match ([regex]::Escape($mcpToolPath))
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\dev.env.example")) | Should -Match "VANESSA_MCP_URL"
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\dev.env.example")) | Should -Match "VANESSA_MCP_CLIENT_CFE_PATH"
        (Test-Path -LiteralPath (Join-Path $RepoRoot ".agents\skills\itl-vanessa-ui-mcp\SKILL.md") -PathType Leaf) | Should -Be $true
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".agents\skills\itl-vanessa-ui-mcp\SKILL.md")) | Should -Match "Do \*\*not\*\* start Vanessa UI MCP merely because a request mentions a form"
        (Test-Path -LiteralPath (Join-Path $RepoRoot ".kilo\commands\itl-vanessa-mcp.md") -PathType Leaf) | Should -Be $false
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".agents\skills\1c-workflow\references\advanced-actions.md")) | Should -Match "reload or restart Kilo Code"
        $kiloTemplateText = (Get-ChildItem -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\kilo-command-templates") -Recurse -File -Filter "itl*.md.template" | ForEach-Object { Get-Content -Encoding UTF8 -Raw $_.FullName }) -join [Environment]::NewLine
        $kiloTemplateText | Should -Not -Match "/itl-vanessa-mcp"
    }

    It "removes default upstream ai_rules_1c MCP entries without deleting ITL or External MCP config" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-rules-mcp-cleanup-test-" + [guid]::NewGuid().ToString("N"))

        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".codex"), (Join-Path $tempRoot ".kilo") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".codex\config.toml") -Value @"
[mcp_servers."1c-code-metadata-mcp"]
url = "http://localhost:8000/mcp"
enabled = true

[mcp_servers."1c-ssl-mcp"]
url = "http://localhost:8007/mcp"
enabled = true
managedBy = "external-mcp"

# >>> vibecoding1c-mcp project
[mcp_servers."1c-code-metadata-mcp"]
url = "http://127.0.0.1:18100/mcp"
enabled = true
managedBy = "vibecoding1c-mcp"
family = "vibecoding1c"

[mcp_servers."1c-data-mcp"]
url = "http://127.0.0.1/published/hs/mcp"
enabled = true
managedBy = "vibecoding1c-mcp"
family = "vibecoding1c"
# <<< vibecoding1c-mcp project

[mcp_servers."custom-tool"]
url = "http://localhost:9999/mcp"
enabled = true
"@ -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $tempRoot ".kilo\kilo.json") -Value @"
{
  "instructions": ["USER-RULES.md", "docs/custom.md"],
  "permission": { "bash": "ask" },
  "mcp": {
    "1c-code-metadata-mcp": {
      "type": "remote",
      "url": "http://localhost:8000/mcp",
      "enabled": true
    },
    "1C-docs-mcp": {
      "type": "remote",
      "url": "http://localhost:8003/mcp",
      "enabled": true,
      "managedBy": "ai_rules_1c"
    },
    "onec-syntax-checker-mcp": {
      "type": "remote",
      "url": "http://localhost:8001/mcp",
      "enabled": true,
      "managedBy": "ai_rules_1c"
    },
    "1c-ssl-mcp": {
      "type": "remote",
      "url": "http://localhost:8007/mcp",
      "enabled": true,
      "managedBy": "external-mcp",
      "family": "external"
    },
    "itl-demo-code": {
      "type": "remote",
      "url": "http://127.0.0.1:18100/mcp",
      "enabled": true,
      "managedBy": "vibecoding1c-mcp",
      "family": "vibecoding1c"
    },
    "1c-graph-metadata-mcp": {
      "type": "remote",
      "url": "http://127.0.0.1:18101/mcp",
      "enabled": true,
      "managedBy": "vibecoding1c-mcp",
      "family": "vibecoding1c"
    },
    "1c-data-mcp": {
      "type": "remote",
      "url": "http://127.0.0.1/published/hs/mcp",
      "enabled": true,
      "managedBy": "vibecoding1c-mcp",
      "family": "vibecoding1c"
    },
    "custom-tool": {
      "type": "remote",
      "url": "http://localhost:9999/mcp",
      "enabled": true,
      "managedBy": "external-mcp",
      "family": "external"
    }
  }
}
"@ -Encoding UTF8

            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                Remove-AiRules1cManagedMcpConfig
            }

            $codexText = Get-Content -Encoding UTF8 -Raw (Join-Path $tempRoot ".codex\config.toml")
            $codexText | Should -Not -Match "http://localhost:8000/mcp"
            $codexText | Should -Match ([regex]::Escape('[mcp_servers."1c-code-metadata-mcp"]'))
            $codexText | Should -Match ([regex]::Escape('[mcp_servers."1c-data-mcp"]'))
            $codexText | Should -Match "1c-ssl-mcp"
            $codexText | Should -Match "external-mcp"
            $codexText | Should -Match ([regex]::Escape("# >>> vibecoding1c-mcp project"))
            $codexText | Should -Match ([regex]::Escape("# <<< vibecoding1c-mcp project"))
            $codexText | Should -Match ([regex]::Escape('[mcp_servers."custom-tool"]'))

            $kilo = Get-Content -Encoding UTF8 -Raw (Join-Path $tempRoot ".kilo\kilo.json") | ConvertFrom-Json
            $kilo.mcp.PSObject.Properties["1c-code-metadata-mcp"] | Should -BeNullOrEmpty
            $kilo.mcp.PSObject.Properties["1C-docs-mcp"] | Should -BeNullOrEmpty
            $kilo.mcp.PSObject.Properties["onec-syntax-checker-mcp"] | Should -BeNullOrEmpty
            $kilo.mcp.'1c-ssl-mcp'.managedBy | Should -Be "external-mcp"
            $kilo.mcp.'itl-demo-code'.managedBy | Should -Be "vibecoding1c-mcp"
            $kilo.mcp.'1c-graph-metadata-mcp'.managedBy | Should -Be "vibecoding1c-mcp"
            $kilo.mcp.'1c-data-mcp'.managedBy | Should -Be "vibecoding1c-mcp"
            $kilo.mcp.'custom-tool'.managedBy | Should -Be "external-mcp"
            @($kilo.instructions) | Should -Be @("USER-RULES.md", "docs/custom.md")
            $kilo.permission.bash | Should -Be "ask"
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "reconciles ai_rules_1c MCP entries only after ready vibecoding1c replacements are available" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-rules-mcp-reconcile-ready-" + [guid]::NewGuid().ToString("N"))

        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".codex"), (Join-Path $tempRoot ".kilo") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".codex\config.toml") -Value @"
[mcp_servers."1C-docs-mcp"]
url = "http://localhost:8003/mcp"
enabled = true

[mcp_servers."1c-code-metadata-mcp"]
url = "http://localhost:8000/mcp"
enabled = true

[mcp_servers."custom-tool"]
url = "http://localhost:9999/mcp"
enabled = true
managedBy = "external-mcp"
"@ -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $tempRoot ".kilo\kilo.json") -Value @"
{
  "instructions": ["USER-RULES.md", "docs/custom.md"],
  "permission": { "bash": "ask" },
  "mcp": {
    "1C-docs-mcp": {
      "type": "remote",
      "url": "http://localhost:8003/mcp",
      "enabled": true
    },
    "1c-code-metadata-mcp": {
      "type": "remote",
      "url": "http://localhost:8000/mcp",
      "enabled": true,
      "managedBy": "ai_rules_1c"
    },
    "custom-tool": {
      "type": "remote",
      "url": "http://localhost:9999/mcp",
      "enabled": true,
      "managedBy": "external-mcp",
      "family": "external"
    }
  }
}
"@ -Encoding UTF8

            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help -McpServerId code -McpProvider remote -McpConfigId trade *> $null

                function Get-Vibecoding1cMcpSelectionCompleteness {
                    return [pscustomobject]@{ isComplete = $true; reasons = @() }
                }
                function Get-Vibecoding1cMcpReadyClientConfigNames {
                    return @("1C-docs-mcp", "1c-code-metadata-mcp")
                }
                function Write-Vibecoding1cMcpClientConfig {
                    $endpoints = @(
                        [pscustomobject]@{ id = "docs"; name = "itl-1c-docs"; url = "http://ready/docs"; scope = "global"; provider = "remote"; clientNames = [pscustomobject]@{ aiRules1c = "1C-docs-mcp" } },
                        [pscustomobject]@{ id = "code"; name = "itl-trade-code"; url = "http://ready/code"; scope = "project"; provider = "remote"; configId = "trade"; clientNames = [pscustomobject]@{ aiRules1c = "1c-code-metadata-mcp" } }
                    )
                    Write-Vibecoding1cMcpCodexConfig -Path (Join-Path $script:ProjectRoot ".codex\config.toml") -BlockId "project" -Endpoints $endpoints
                    Write-Vibecoding1cMcpKiloConfig -Endpoints $endpoints
                }

                Invoke-AiRules1cManagedMcpConfigReconcile -Operation "test-ready" *> $null
            }

            $codexText = Get-Content -Encoding UTF8 -Raw (Join-Path $tempRoot ".codex\config.toml")
            $codexText | Should -Not -Match "http://localhost:8003/mcp"
            $codexText | Should -Not -Match "http://localhost:8000/mcp"
            $codexText | Should -Match "http://ready/docs"
            $codexText | Should -Match "http://ready/code"
            $codexText | Should -Match "custom-tool"

            $kilo = Get-Content -Encoding UTF8 -Raw (Join-Path $tempRoot ".kilo\kilo.json") | ConvertFrom-Json
            $kilo.mcp.'1C-docs-mcp'.url | Should -Be "http://ready/docs"
            $kilo.mcp.'1C-docs-mcp'.managedBy | Should -Be "vibecoding1c-mcp"
            $kilo.mcp.'1c-code-metadata-mcp'.url | Should -Be "http://ready/code"
            $kilo.mcp.'1c-code-metadata-mcp'.managedBy | Should -Be "vibecoding1c-mcp"
            $kilo.mcp.'custom-tool'.managedBy | Should -Be "external-mcp"
            @($kilo.instructions) | Should -Be @("USER-RULES.md", "docs/custom.md")
            $kilo.permission.bash | Should -Be "ask"
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "preserves all MCP entries when transactional replacement state is not ready" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-rules-mcp-reconcile-missing-" + [guid]::NewGuid().ToString("N"))
        $oldHome = [Environment]::GetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", "Process")

        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".kilo") | Out-Null
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", (Join-Path $tempRoot "local-home"), "Process")
            Set-Content -LiteralPath (Join-Path $tempRoot ".kilo\kilo.json") -Value @"
{
  "instructions": ["USER-RULES.md", "docs/custom.md"],
  "mcp": {
    "1C-docs-mcp": {
      "type": "remote",
      "url": "http://localhost:8003/mcp",
      "enabled": true
    },
    "1c-data-mcp": {
      "type": "remote",
      "url": "http://localhost:8008/mcp",
      "enabled": true,
      "managedBy": "ai_rules_1c"
    },
    "custom-tool": {
      "type": "remote",
      "url": "http://localhost:9999/mcp",
      "enabled": true,
      "managedBy": "external-mcp",
      "family": "external"
    }
  }
}
"@ -Encoding UTF8

            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                Invoke-AiRules1cManagedMcpConfigReconcile -Operation "test-missing" *> $null
            }

            $kilo = Get-Content -Encoding UTF8 -Raw (Join-Path $tempRoot ".kilo\kilo.json") | ConvertFrom-Json
            $kilo.mcp.'1C-docs-mcp'.url | Should -Be "http://localhost:8003/mcp"
            $kilo.mcp.PSObject.Properties.Name | Should -Contain "1c-data-mcp"
            $kilo.mcp.'custom-tool'.managedBy | Should -Be "external-mcp"
            @($kilo.instructions) | Should -Be @("USER-RULES.md", "docs/custom.md")
        } finally {
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", $oldHome, "Process")
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "preserves explicitly external Data MCP even when it uses the legacy placeholder" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-rules-external-data-mcp-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".kilo") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".kilo\kilo.json") -Encoding UTF8 -Value @'
{
  "mcp": {
    "1c-data-mcp": {
      "type": "remote",
      "url": "{INFOBASE_PUBLISH_URL}/hs/mcp",
      "enabled": true,
      "managedBy": "external-mcp",
      "family": "external"
    }
  }
}
'@
            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                Remove-StaleAiRules1cDataMcpConfig *> $null
            }
            $kilo = Get-Content -Encoding UTF8 -Raw (Join-Path $tempRoot ".kilo\kilo.json") | ConvertFrom-Json
            $kilo.mcp.'1c-data-mcp'.managedBy | Should -Be "external-mcp"
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "restores MCP client config snapshot when replacement write fails" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-rules-mcp-reconcile-rollback-" + [guid]::NewGuid().ToString("N"))

        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c"), (Join-Path $tempRoot ".codex"), (Join-Path $tempRoot ".kilo") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"aiRules":{"tools":["kilocode"]}}'
            Set-Content -LiteralPath (Join-Path $tempRoot ".ai-rules.json") -Encoding UTF8 -Value '{"schemaVersion":1,"tools":["kilocode"],"files":{}}'
            Set-Content -LiteralPath (Join-Path $tempRoot ".codex\config.toml") -Value @"
[mcp_servers."1C-docs-mcp"]
url = "http://localhost:8003/mcp"
enabled = true
"@ -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $tempRoot ".kilo\kilo.json") -Value @"
{
  "mcp": {
    "1C-docs-mcp": {
      "type": "remote",
      "url": "http://localhost:8003/mcp",
      "enabled": true
    }

  }
}
"@ -Encoding UTF8

            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null

                function Get-Vibecoding1cMcpSelectionCompleteness {
                    return [pscustomobject]@{ isComplete = $true; reasons = @() }
                }
                function Get-Vibecoding1cMcpReadyClientConfigNames {
                    return @("1C-docs-mcp")
                }
                function Write-Vibecoding1cMcpClientConfig {
                    Set-Content -LiteralPath (Join-Path $script:ProjectRoot ".kilo\kilo.json") -Encoding UTF8 -Value '{"mcp":{}}'
                    throw "simulated write failure"
                }

                Invoke-AiRules1cManagedMcpConfigReconcile -Operation "test-rollback" *> $null
            }

            $kilo = Get-Content -Encoding UTF8 -Raw (Join-Path $tempRoot ".kilo\kilo.json") | ConvertFrom-Json
            $kilo.mcp.'1C-docs-mcp'.url | Should -Be "http://localhost:8003/mcp"
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "restores every client config byte when stale pruning fails inside the transaction" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-rules-mcp-prune-rollback-" + [guid]::NewGuid().ToString("N"))
        $oldHome = [Environment]::GetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", "Process")
        try {
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", (Join-Path $tempRoot "local-home"), "Process")
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c"), (Join-Path $tempRoot ".codex"), (Join-Path $tempRoot ".kilo") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"aiRules":{"tools":["kilocode"]}}'
            Set-Content -LiteralPath (Join-Path $tempRoot ".ai-rules.json") -Encoding UTF8 -Value '{"schemaVersion":1,"tools":["kilocode"],"files":{}}'
            $codexPath = Join-Path $tempRoot ".codex\config.toml"
            $kiloPath = Join-Path $tempRoot ".kilo\kilo.json"
            [System.IO.File]::WriteAllBytes($codexPath, [byte[]](0xEF, 0xBB, 0xBF, 0x23, 0x20, 0x78, 0x0D, 0x0A))
            [System.IO.File]::WriteAllBytes($kiloPath, [System.Text.Encoding]::UTF8.GetBytes('{"mcp":{"custom":{"url":"http://custom"}}}'))
            $codexBefore = (Get-FileHash -Algorithm SHA256 -LiteralPath $codexPath).Hash
            $kiloBefore = (Get-FileHash -Algorithm SHA256 -LiteralPath $kiloPath).Hash

            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                function Get-Vibecoding1cMcpSelectionCompleteness { [pscustomobject]@{ isComplete = $true; reasons = @() } }
                function Get-Vibecoding1cMcpReadyClientConfigNames { @("1C-docs-mcp") }
                function Write-Vibecoding1cMcpClientConfig { Set-Content -LiteralPath $kiloPath -Encoding UTF8 -Value '{"mcp":{}}' }
                function Remove-AiRules1cManagedMcpConfig { @() }
                function Remove-StaleAiRules1cDataMcpConfig {
                    Set-Content -LiteralPath $kiloPath -Encoding UTF8 -Value "changed"
                    throw "simulated stale prune failure"
                }
                Invoke-AiRules1cManagedMcpConfigReconcile -Operation "test-prune-rollback" *> $null
            }

            (Get-FileHash -Algorithm SHA256 -LiteralPath $kiloPath).Hash | Should -Be $kiloBefore
        } finally {
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", $oldHome, "Process")
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "allocates Vanessa MCP ports per development branch state" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vibecoding1c-mcp-port-test-" + [guid]::NewGuid().ToString("N"))
        $oldRange = [Environment]::GetEnvironmentVariable("VANESSA_MCP_PORT_RANGE", "Process")
        $oldRegistryHome = [Environment]::GetEnvironmentVariable("ITL_PORT_REGISTRY_HOME", "Process")
        $oldRegistryScope = [Environment]::GetEnvironmentVariable("ITL_PORT_REGISTRY_SCOPE", "Process")
        $listener = $null

        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c\dev-branches") | Out-Null
            & git -C $tempRoot init *> $null
            [Environment]::SetEnvironmentVariable("ITL_PORT_REGISTRY_HOME", (Join-Path $tempRoot "port-registry"), "Process")
            [Environment]::SetEnvironmentVariable("ITL_PORT_REGISTRY_SCOPE", $null, "Process")

            $basePort = 0
            for ($candidate = 41000; $candidate -lt 55000; $candidate += 10) {
                $probe1 = $null
                $probe2 = $null
                try {
                    $address = [System.Net.IPAddress]::Parse("127.0.0.1")
                    $probe1 = New-Object System.Net.Sockets.TcpListener($address, $candidate)
                    $probe2 = New-Object System.Net.Sockets.TcpListener($address, ($candidate + 1))
                    $probe1.Start()
                    $probe2.Start()
                    $basePort = $candidate
                    break
                } catch {
                } finally {
                    if ($null -ne $probe1) { $probe1.Stop() }
                    if ($null -ne $probe2) { $probe2.Stop() }
                }
            }
            $basePort | Should -BeGreaterThan 0

            [Environment]::SetEnvironmentVariable("VANESSA_MCP_PORT_RANGE", "$basePort..$($basePort + 1)", "Process")

            $otherState = @{
                devBranchName = "Other Branch"
                safeDevBranchName = "other-branch"
                devBranch = "itldev/other-branch"
                vanessaMcpPort = $basePort
            } | ConvertTo-Json
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\dev-branches\other-branch.json") -Value $otherState -Encoding UTF8

            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $state = [pscustomobject]@{
                    devBranchName = "Current Branch"
                    safeDevBranchName = "current-branch"
                    devBranch = "itldev/current-branch"
                }
                Resolve-VanessaMcpPort -State $state
            } | Should -Be ($basePort + 1)

            Remove-Item -LiteralPath (Join-Path $tempRoot ".agent-1c\dev-branches\other-branch.json") -Force
            $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Parse("127.0.0.1"), $basePort)
            $listener.Start()

            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $state = [pscustomobject]@{
                    devBranchName = "Current Branch"
                    safeDevBranchName = "current-branch"
                    devBranch = "itldev/current-branch"
                }
                Resolve-VanessaMcpPort -State $state
            } | Should -Be ($basePort + 1)

            $listener.Stop()
            $listener = $null

            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $state = [pscustomobject]@{
                    devBranchName = "Saved Branch"
                    safeDevBranchName = "saved-branch"
                    devBranch = "itldev/saved-branch"
                    vanessaMcpPort = $basePort
                }
                Resolve-VanessaMcpPort -State $state
            } | Should -Be $basePort
        } finally {
            if ($null -ne $listener) {
                $listener.Stop()
            }
            [Environment]::SetEnvironmentVariable("VANESSA_MCP_PORT_RANGE", $oldRange, "Process")
            [Environment]::SetEnvironmentVariable("ITL_PORT_REGISTRY_HOME", $oldRegistryHome, "Process")
            [Environment]::SetEnvironmentVariable("ITL_PORT_REGISTRY_SCOPE", $oldRegistryScope, "Process")
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "allocates helper-managed ports through one shared registry across projects" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-shared-port-registry-test-" + [guid]::NewGuid().ToString("N"))
        $oldRegistryHome = [Environment]::GetEnvironmentVariable("ITL_PORT_REGISTRY_HOME", "Process")
        $oldRegistryScope = [Environment]::GetEnvironmentVariable("ITL_PORT_REGISTRY_SCOPE", "Process")
        $oldVanessaTestRange = [Environment]::GetEnvironmentVariable("VANESSA_TEST_PORT_RANGE", "Process")
        $oldVanessaMcpRange = [Environment]::GetEnvironmentVariable("VANESSA_MCP_PORT_RANGE", "Process")
        $oldRoctupRange = [Environment]::GetEnvironmentVariable("ROCTUP_MCP_PORT_RANGE", "Process")

        try {
            $projectA = Join-Path $tempRoot "project-a"
            $projectB = Join-Path $tempRoot "project-b"
            New-Item -ItemType Directory -Force -Path $projectA, $projectB | Out-Null
            & git -C $projectA init *> $null
            & git -C $projectB init *> $null

            $basePort = 0
            for ($candidate = 43000; $candidate -lt 55000; $candidate += 20) {
                $probes = @()
                try {
                    $ok = $true
                    $address = [System.Net.IPAddress]::Parse("127.0.0.1")
                    for ($offset = 0; $offset -lt 8; $offset++) {
                        $probe = New-Object System.Net.Sockets.TcpListener($address, ($candidate + $offset))
                        $probe.Start()
                        $probes += $probe
                    }
                    if ($ok) {
                        $basePort = $candidate
                        break
                    }
                } catch {
                } finally {
                    foreach ($probe in $probes) {
                        $probe.Stop()
                    }
                }
            }
            $basePort | Should -BeGreaterThan 0

            [Environment]::SetEnvironmentVariable("ITL_PORT_REGISTRY_HOME", (Join-Path $tempRoot "port-registry"), "Process")
            [Environment]::SetEnvironmentVariable("ITL_PORT_REGISTRY_SCOPE", $null, "Process")
            [Environment]::SetEnvironmentVariable("VANESSA_TEST_PORT_RANGE", "$basePort..$($basePort + 1)", "Process")
            [Environment]::SetEnvironmentVariable("VANESSA_MCP_PORT_RANGE", "$($basePort + 2)..$($basePort + 3)", "Process")
            [Environment]::SetEnvironmentVariable("ROCTUP_MCP_PORT_RANGE", "$($basePort + 4)..$($basePort + 5)", "Process")

            $vanessaTestA = & {
                . $HelperPath -ProjectRoot $projectA -Action help *> $null
                $state = [pscustomobject]@{ devBranchName = "Feature"; safeDevBranchName = "feature"; devBranch = "itldev/feature"; stateProjectRoot = $projectA; worktreePath = $projectA }
                Resolve-VanessaTestPort -State $state
            }
            $vanessaTestB = & {
                . $HelperPath -ProjectRoot $projectB -Action help *> $null
                $state = [pscustomobject]@{ devBranchName = "Feature"; safeDevBranchName = "feature"; devBranch = "itldev/feature"; stateProjectRoot = $projectB; worktreePath = $projectB }
                Resolve-VanessaTestPort -State $state
            }
            $vanessaTestA | Should -Not -Be $vanessaTestB

            $vanessaMcpA = & {
                . $HelperPath -ProjectRoot $projectA -Action help *> $null
                $state = [pscustomobject]@{ devBranchName = "Feature"; safeDevBranchName = "feature"; devBranch = "itldev/feature"; stateProjectRoot = $projectA; worktreePath = $projectA }
                Resolve-VanessaMcpPort -State $state
            }
            $vanessaMcpB = & {
                . $HelperPath -ProjectRoot $projectB -Action help *> $null
                $state = [pscustomobject]@{ devBranchName = "Feature"; safeDevBranchName = "feature"; devBranch = "itldev/feature"; stateProjectRoot = $projectB; worktreePath = $projectB }
                Resolve-VanessaMcpPort -State $state
            }
            $vanessaMcpA | Should -Not -Be $vanessaMcpB

            $roctupA = & {
                . $HelperPath -ProjectRoot $projectA -Action help *> $null
                $state = [pscustomobject]@{ devBranchName = "Feature"; safeDevBranchName = "feature"; devBranch = "itldev/feature"; stateProjectRoot = $projectA; worktreePath = $projectA }
                Resolve-RoctupMcpPort -State $state
            }
            $roctupB = & {
                . $HelperPath -ProjectRoot $projectB -Action help *> $null
                $state = [pscustomobject]@{ devBranchName = "Feature"; safeDevBranchName = "feature"; devBranch = "itldev/feature"; stateProjectRoot = $projectB; worktreePath = $projectB }
                Resolve-RoctupMcpPort -State $state
            }
            $roctupA | Should -Not -Be $roctupB

            $vibecodingA = & {
                . $HelperPath -ProjectRoot $projectA -Action help *> $null
                function Get-Vibecoding1cMcpPortRange {
                    param([string]$Scope)
                    return [pscustomobject]@{ start = ($basePort + 6); end = ($basePort + 7) }
                }
                Resolve-Vibecoding1cMcpPort -Scope "project" -Key "project:itl-project-a-code" -ServerId "code" -ContainerName "itl-project-a-code"
            }
            $vibecodingB = & {
                . $HelperPath -ProjectRoot $projectB -Action help *> $null
                function Get-Vibecoding1cMcpPortRange {
                    param([string]$Scope)
                    return [pscustomobject]@{ start = ($basePort + 6); end = ($basePort + 7) }
                }
                Resolve-Vibecoding1cMcpPort -Scope "project" -Key "project:itl-project-b-code" -ServerId "code" -ContainerName "itl-project-b-code"
            }
            $vibecodingA | Should -Not -Be $vibecodingB
        } finally {
            [Environment]::SetEnvironmentVariable("ITL_PORT_REGISTRY_HOME", $oldRegistryHome, "Process")
            [Environment]::SetEnvironmentVariable("ITL_PORT_REGISTRY_SCOPE", $oldRegistryScope, "Process")
            [Environment]::SetEnvironmentVariable("VANESSA_TEST_PORT_RANGE", $oldVanessaTestRange, "Process")
            [Environment]::SetEnvironmentVariable("VANESSA_MCP_PORT_RANGE", $oldVanessaMcpRange, "Process")
            [Environment]::SetEnvironmentVariable("ROCTUP_MCP_PORT_RANGE", $oldRoctupRange, "Process")
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "rejects explicit managed port conflicts and reuses released allocations" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-managed-port-explicit-test-" + [guid]::NewGuid().ToString("N"))
        $oldRegistryHome = [Environment]::GetEnvironmentVariable("ITL_PORT_REGISTRY_HOME", "Process")
        $oldRegistryScope = [Environment]::GetEnvironmentVariable("ITL_PORT_REGISTRY_SCOPE", "Process")
        $listener = $null

        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            [Environment]::SetEnvironmentVariable("ITL_PORT_REGISTRY_HOME", (Join-Path $tempRoot "port-registry"), "Process")
            [Environment]::SetEnvironmentVariable("ITL_PORT_REGISTRY_SCOPE", $null, "Process")

            $basePort = 0
            for ($candidate = 44000; $candidate -lt 55000; $candidate += 10) {
                $probe1 = $null
                $probe2 = $null
                try {
                    $address = [System.Net.IPAddress]::Parse("127.0.0.1")
                    $probe1 = New-Object System.Net.Sockets.TcpListener($address, $candidate)
                    $probe2 = New-Object System.Net.Sockets.TcpListener($address, ($candidate + 1))
                    $probe1.Start()
                    $probe2.Start()
                    $basePort = $candidate
                    break
                } catch {
                } finally {
                    if ($null -ne $probe1) { $probe1.Stop() }
                    if ($null -ne $probe2) { $probe2.Stop() }
                }
            }
            $basePort | Should -BeGreaterThan 0

            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                Resolve-ItlManagedPort -Family "test-family" -Key "one" -Start $basePort -End ($basePort + 1) -ExplicitPort $basePort -Subject "test port"
            } | Should -Be $basePort

            {
                & {
                    . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                    Resolve-ItlManagedPort -Family "test-family" -Key "two" -Start $basePort -End ($basePort + 1) -ExplicitPort $basePort -Subject "test port"
                }
            } | Should -Throw "*already reserved*"

            $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Parse("127.0.0.1"), ($basePort + 1))
            $listener.Start()
            {
                & {
                    . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                    Resolve-ItlManagedPort -Family "test-family" -Key "two" -Start $basePort -End ($basePort + 1) -ExplicitPort ($basePort + 1) -Subject "test port"
                }
            } | Should -Throw "*occupied*"
            $listener.Stop()
            $listener = $null

            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                Release-ItlManagedPortAllocation -Family "test-family" -Key "one"
                Resolve-ItlManagedPort -Family "test-family" -Key "two" -Start $basePort -End ($basePort + 1) -ExplicitPort $basePort -Subject "test port"
            } | Should -Be $basePort
        } finally {
            if ($null -ne $listener) {
                $listener.Stop()
            }
            [Environment]::SetEnvironmentVariable("ITL_PORT_REGISTRY_HOME", $oldRegistryHome, "Process")
            [Environment]::SetEnvironmentVariable("ITL_PORT_REGISTRY_SCOPE", $oldRegistryScope, "Process")
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "selects vibecoding1c MCP embedding models from mocked hardware" {
        $results = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            [pscustomobject]@{
                Gpu6 = (Select-Vibecoding1cMcpEmbeddingModel -GpuMemoryMb 6144 -RamGb 32).modelId
                Gpu4 = (Select-Vibecoding1cMcpEmbeddingModel -GpuMemoryMb 4096 -RamGb 32).modelId
                Gpu3 = (Select-Vibecoding1cMcpEmbeddingModel -GpuMemoryMb 3072 -RamGb 32).modelId
                CpuLarge = (Select-Vibecoding1cMcpEmbeddingModel -GpuMemoryMb 0 -RamGb 32).modelId
                CpuSmall = (Select-Vibecoding1cMcpEmbeddingModel -GpuMemoryMb 0 -RamGb 8).modelId
            }
        }

        $results.Gpu6 | Should -Be "Qwen3-Embedding-4B-GGUF:Q8_0"
        $results.Gpu4 | Should -Be "Qwen3-Embedding-4B-GGUF:Q6_K"
        $results.Gpu3 | Should -Be "Qwen3-Embedding-4B-GGUF:Q4_K_M"
        $results.CpuLarge | Should -Be "intfloat/multilingual-e5-base"
        $results.CpuSmall | Should -Be "intfloat/multilingual-e5-small"
    }

    It "patches Data MCP tools XML from vcvalidatequery to validatequery" {
        $patched = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $catalogName = Get-DataMcpToolsCatalogLocalName
            $xml = @"
<DataExchange>
  <$catalogName>
    <Description>vcvalidatequery</Description>
  </$catalogName>
</DataExchange>
"@
            Convert-DataMcpToolsXmlText -Text $xml
        }

        $patched | Should -Match "<Description>validatequery</Description>"
        $patched | Should -Not -Match "vcvalidatequery"
    }

    It "patches a publication default.vrd with the Data MCP HTTP service" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("data-mcp-vrd-test-" + [guid]::NewGuid().ToString("N"))

        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot "default.vrd") -Encoding UTF8 -Value @"
<?xml version="1.0" encoding="UTF-8"?>
<point xmlns="http://v8.1c.ru/8.2/virtual-resource-system"
       base="/published"
       ib="File='C:\base';Usr='Admin';Pwd=''"
       enable="false">
  <httpServices publishByDefault="false"/>
</point>
"@

            & {
                . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
                Enable-DataMcpHttpService -PublicationDir $tempRoot *> $null
            }

            $vrdText = Get-Content -Encoding UTF8 -Raw (Join-Path $tempRoot "default.vrd")
            $vrdText | Should -Match 'name="APA_MCP"'
            $vrdText | Should -Match 'rootUrl="mcp"'
            $vrdText | Should -Match 'enable="true"'
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "merges managed Codex TOML and Kilo MCP JSON without deleting unrelated entries" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vibecoding1c-mcp-config-test-" + [guid]::NewGuid().ToString("N"))

        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".codex"), (Join-Path $tempRoot ".kilo") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".codex\config.toml") -Value @"
[mcp_servers.unrelated]
url = "http://localhost:9999/mcp"
"@ -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $tempRoot ".kilo\kilo.json") -Value @"
{
  "mcp": {
    "unrelated": {
      "type": "remote",
      "url": "http://localhost:9999/mcp"
    },
    "external-tool": {
      "type": "remote",
      "url": "http://localhost:9998/mcp",
      "managedBy": "external-mcp",
      "family": "external"
    },
    "itl-old": {
      "type": "remote",
      "url": "http://localhost:1/mcp",
      "managedBy": "vibecoding1c-mcp",
      "family": "vibecoding1c"
    },
    "VanessaAutomation-demo": {
      "type": "remote",
      "url": "http://localhost:9874/mcp",
      "managedBy": "vanessa-mcp",
      "family": "vanessa",
      "scope": "branch"
    }
  }
}
"@ -Encoding UTF8

            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help -McpServerId code -McpProvider remote -McpConfigId trade *> $null
                $endpoints = @(
                    [pscustomobject]@{ id = "docs"; name = "itl-1c-docs"; url = "http://127.0.0.1:18000/mcp"; scope = "global"; provider = "remote" },
                    [pscustomobject]@{ id = "code"; name = "itl-dead-code"; url = "http://127.0.0.1:18102/mcp"; scope = "project"; provider = "remote"; configId = "trade"; status = "stopped"; clientNames = [pscustomobject]@{ aiRules1c = "1c-code-metadata-mcp" } },
                    [pscustomobject]@{ id = "code"; name = "itl-trade-code"; url = "http://127.0.0.1:18100/mcp"; scope = "project"; provider = "remote"; configId = "trade"; clientNames = [pscustomobject]@{ aiRules1c = "1c-code-metadata-mcp" } },
                    [pscustomobject]@{ id = "code"; name = "itl-erp-code"; url = "http://127.0.0.1:18101/mcp"; scope = "project"; provider = "remote"; configId = "erp"; clientNames = [pscustomobject]@{ aiRules1c = "1c-code-metadata-mcp" } },
                    [pscustomobject]@{ id = "data"; name = "itl-current-data"; url = "http://localhost/current/hs/mcp"; scope = "branch"; provider = "local"; clientNames = [pscustomobject]@{ aiRules1c = "1c-data-mcp" } }
                )
                Write-Vibecoding1cMcpCodexConfig -Path (Join-Path $tempRoot ".codex\config.toml") -BlockId "project" -Endpoints $endpoints
                Write-Vibecoding1cMcpCodexConfig -Path (Join-Path $tempRoot ".codex\config.toml") -BlockId "project" -Endpoints $endpoints
                Write-Vibecoding1cMcpKiloConfig -Endpoints $endpoints
            }

            $codexText = Get-Content -Encoding UTF8 -Raw (Join-Path $tempRoot ".codex\config.toml")
            $codexText | Should -Match "mcp_servers.unrelated"
            $codexText | Should -Match ([regex]::Escape('[mcp_servers."1C-docs-mcp"]'))
            $codexText | Should -Match ([regex]::Escape('[mcp_servers."1c-code-metadata-mcp"]'))
            $codexText | Should -Match ([regex]::Escape('[mcp_servers."1c-data-mcp"]'))
            $codexText | Should -Match "http://127.0.0.1:18100/mcp"
            $codexText | Should -Match "http://localhost/current/hs/mcp"
            $codexText | Should -Not -Match "http://127.0.0.1:18101/mcp"
            $codexText | Should -Not -Match "http://127.0.0.1:18102/mcp"
            @([regex]::Matches($codexText, [regex]::Escape("# >>> vibecoding1c-mcp project"))).Count | Should -Be 1

            $kilo = Get-Content -Encoding UTF8 -Raw (Join-Path $tempRoot ".kilo\kilo.json") | ConvertFrom-Json
            $kilo.mcp.unrelated.url | Should -Be "http://localhost:9999/mcp"
            $kilo.mcp.'external-tool'.url | Should -Be "http://localhost:9998/mcp"
            $kilo.mcp.'external-tool'.family | Should -Be "external"
            $kilo.mcp.'VanessaAutomation-demo'.url | Should -Be "http://localhost:9874/mcp"
            $kilo.mcp.'VanessaAutomation-demo'.managedBy | Should -Be "vanessa-mcp"
            $kilo.mcp.'VanessaAutomation-demo'.family | Should -Be "vanessa"
            $kilo.mcp.PSObject.Properties["itl-old"] | Should -BeNullOrEmpty
            $kilo.mcp.'1c-code-metadata-mcp'.url | Should -Be "http://127.0.0.1:18100/mcp"
            $kilo.mcp.'1c-code-metadata-mcp'.managedBy | Should -Be "vibecoding1c-mcp"
            $kilo.mcp.'1c-code-metadata-mcp'.family | Should -Be "vibecoding1c"
            $kilo.mcp.'1c-code-metadata-mcp'.logicalId | Should -Be "code"
            $kilo.mcp.'1c-code-metadata-mcp'.registryName | Should -Be "itl-trade-code"
            $kilo.mcp.'1c-data-mcp'.url | Should -Be "http://localhost/current/hs/mcp"
            $kilo.mcp.'1c-data-mcp'.managedBy | Should -Be "vibecoding1c-mcp"
            $kilo.mcp.'1c-data-mcp'.logicalId | Should -Be "data"
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "writes branch-local Vanessa UI MCP into Kilo config without deleting custom entries" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vanessa-mcp-kilo-config-test-" + [guid]::NewGuid().ToString("N"))

        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".kilo") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".kilo\kilo.json") -Value @"
{
  "mcp": {
    "custom-tool": {
      "type": "remote",
      "url": "http://localhost:9999/mcp",
      "managedBy": "external-mcp",
      "family": "external"
    },
    "VanessaAutomation-demo": {
      "type": "remote",
      "url": "http://localhost:9874/mcp",
      "managedBy": "vanessa-mcp",
      "family": "vanessa",
      "scope": "branch",
      "devBranchName": "demo",
      "safeDevBranchName": "demo"
    }
  }
}
"@ -Encoding UTF8

            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $state = [pscustomobject]@{
                    devBranchName = "feature/demo"
                    safeDevBranchName = "feature-demo"
                    vanessaMcpPort = 9888
                    vanessaMcpUrl = "http://localhost:9888/mcp"
                }
                Write-VanessaMcpKiloConfig -State $state *> $null
            }

            $kilo = Get-Content -Encoding UTF8 -Raw (Join-Path $tempRoot ".kilo\kilo.json") | ConvertFrom-Json
            $kilo.mcp.'custom-tool'.url | Should -Be "http://localhost:9999/mcp"
            $kilo.mcp.'custom-tool'.managedBy | Should -Be "external-mcp"
            $kilo.mcp.PSObject.Properties['VanessaAutomation-demo'] | Should -BeNullOrEmpty
            $kilo.mcp.'VanessaUi-feature-demo'.type | Should -Be "remote"
            $kilo.mcp.'VanessaUi-feature-demo'.url | Should -Be "http://localhost:9888/mcp"
            $kilo.mcp.'VanessaUi-feature-demo'.enabled | Should -Be $true
            $kilo.mcp.'VanessaUi-feature-demo'.timeout | Should -Be 120000
            $kilo.mcp.'VanessaUi-feature-demo'.managedBy | Should -Be "vanessa-ui-mcp"
            $kilo.mcp.'VanessaUi-feature-demo'.family | Should -Be "vanessa-ui"
            $kilo.mcp.'VanessaUi-feature-demo'.scope | Should -Be "branch"
            $kilo.mcp.'VanessaUi-feature-demo'.devBranchName | Should -Be "feature/demo"
            $kilo.mcp.'VanessaUi-feature-demo'.safeDevBranchName | Should -Be "feature-demo"
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "connects Data MCP for a published branch with stubbed 1C calls" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("data-mcp-success-test-" + [guid]::NewGuid().ToString("N"))
        $publicationDir = Join-Path $tempRoot "publication"

        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c"), $publicationDir | Out-Null
            Copy-Item -LiteralPath (Join-Path $RepoRoot "templates\project.json") -Destination (Join-Path $tempRoot ".agent-1c\project.json")
            Set-Content -LiteralPath (Join-Path $publicationDir "default.vrd") -Encoding UTF8 -Value @"
<?xml version="1.0" encoding="UTF-8"?>
<point xmlns="http://v8.1c.ru/8.2/virtual-resource-system" base="/published" ib="File='C:\base';Usr='Admin';Pwd=''" enable="false"/>
"@

            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null

                function Ensure-DataMcpPackage {
                    return [pscustomobject]@{
                        cfePath = "C:\fake\OneMCP.cfe"
                        toolsXmlPath = "C:\fake\tools.xml"
                    }
                }
                function Ensure-DevBranchEnterpriseNormalized {
                    param([object]$State, [string]$Reason)
                    return $State
                }
                function Install-DataMcpExtension {
                    param([object]$State, [string]$CfePath)
                    $script:DataMcpCfePath = $CfePath
                    return "designer.log"
                }
                function Invoke-DataMcpToolsLoader {
                    param([object]$State, [string]$ToolsXmlPath)
                    $script:DataMcpToolsXmlPath = $ToolsXmlPath
                    return "tools-loader.json"
                }
                function Test-DataMcpEndpointReachable {
                    param([string]$Url)
                    return $true
                }
                function Write-Vibecoding1cMcpClientConfig {
                    $localEndpoints = @(Get-Vibecoding1cMcpCurrentEndpoints | Where-Object { [string](Get-Vibecoding1cMcpObjectValue -Object $_ -Name "scope" -Default "") -ne "global" })
                    Write-Vibecoding1cMcpCodexConfig -Path (Join-Path $script:ProjectRoot ".codex\config.toml") -BlockId "project" -Endpoints $localEndpoints
                    Write-Vibecoding1cMcpKiloConfig -Endpoints $localEndpoints
                }

                $state = [pscustomobject]@{
                    devBranchInfoBasePath = "C:\base"
                    infoBaseKind = "file"
                    publicationUrl = "http://localhost/published"
                }
                $updates = Install-DevBranchDataMcpBestEffort -State $state -PublicationUrl "http://localhost/published" -PublicationDir $publicationDir
                $updates.dataMcpStatus | Should -Be "running"
                $updates.dataMcpEndpointUrl | Should -Be "http://localhost/published/hs/mcp"
                $script:DataMcpCfePath | Should -Be "C:\fake\OneMCP.cfe"
                $script:DataMcpToolsXmlPath | Should -Be "C:\fake\tools.xml"
            }

            $codexText = Get-Content -Encoding UTF8 -Raw (Join-Path $tempRoot ".codex\config.toml")
            $codexText | Should -Match ([regex]::Escape('[mcp_servers."1c-data-mcp"]'))
            $codexText | Should -Match "http://localhost/published/hs/mcp"
            $vrdText = Get-Content -Encoding UTF8 -Raw (Join-Path $publicationDir "default.vrd")
            $vrdText | Should -Match 'name="APA_MCP"'
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "keeps published branch creation non-blocking when Data MCP package is missing" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("data-mcp-failure-test-" + [guid]::NewGuid().ToString("N"))
        $publicationDir = Join-Path $tempRoot "publication"

        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c"), $publicationDir | Out-Null
            Copy-Item -LiteralPath (Join-Path $RepoRoot "templates\project.json") -Destination (Join-Path $tempRoot ".agent-1c\project.json")
            Set-Content -LiteralPath (Join-Path $publicationDir "default.vrd") -Encoding UTF8 -Value @"
<?xml version="1.0" encoding="UTF-8"?>
<point xmlns="http://v8.1c.ru/8.2/virtual-resource-system" base="/published" ib="File='C:\base';Usr='Admin';Pwd=''" enable="false"/>
"@

            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null

                function Ensure-DataMcpPackage {
                    throw "MCP_1C_Distr.zip was not found"
                }
                function Ensure-DevBranchEnterpriseNormalized {
                    param([object]$State, [string]$Reason)
                    return $State
                }
                function Write-Vibecoding1cMcpClientConfig {
                    $localEndpoints = @(Get-Vibecoding1cMcpCurrentEndpoints | Where-Object { [string](Get-Vibecoding1cMcpObjectValue -Object $_ -Name "scope" -Default "") -ne "global" })
                    Write-Vibecoding1cMcpCodexConfig -Path (Join-Path $script:ProjectRoot ".codex\config.toml") -BlockId "project" -Endpoints $localEndpoints
                    Write-Vibecoding1cMcpKiloConfig -Endpoints $localEndpoints
                }

                $state = [pscustomobject]@{
                    devBranchInfoBasePath = "C:\base"
                    infoBaseKind = "file"
                    publicationUrl = "http://localhost/published"
                }
                $updates = Install-DevBranchDataMcpBestEffort -State $state -PublicationUrl "http://localhost/published" -PublicationDir $publicationDir 3>$null
                $updates.dataMcpStatus | Should -Be "failed"
                $updates.dataMcpError | Should -Match "MCP_1C_Distr.zip"
            }

            $codexPath = Join-Path $tempRoot ".codex\config.toml"
            if (Test-Path -LiteralPath $codexPath -PathType Leaf -ErrorAction SilentlyContinue) {
                (Get-Content -Encoding UTF8 -Raw $codexPath) | Should -Not -Match "1c-data-mcp"
            }
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
