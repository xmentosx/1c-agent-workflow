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

    It "pins compatible catalogs and uses main-worktree endpoint assets" {
        $manifest = Get-Content -LiteralPath (Join-Path $AssetRoot "compatibility.json") -Raw -Encoding UTF8 | ConvertFrom-Json
        $manifest.facadeVersion | Should -Be "0.4.7"
        $manifest.minimumFacadeVersion | Should -Be "0.4.7"
        $mainSource = Get-Content -LiteralPath (Join-Path $RepoRoot "tools\itl-ondemand-mcp\main.go") -Raw -Encoding UTF8
        $gatewaySource = Get-Content -LiteralPath (Join-Path $RepoRoot "tools\itl-ondemand-mcp\gateway.go") -Raw -Encoding UTF8
        $mainSource | Should -Match 'const version = "0\.4\.7"'
        $mainSource | Should -Match '"gateway"'
        $gatewaySource | Should -Match 'gatewayResolveTool\s*=\s*"resolve_tool"'
        $gatewaySource | Should -Match 'gatewayCallTool\s*=\s*"call_tool"'
        $gatewaySource | Should -Match 'ArgumentsJSON\s+\*string\s+`json:"argumentsJson,omitempty"`'
        $gatewaySource | Should -Match '"additionalProperties":\s*true'
        $manifest.families.roctup.backendVersions.roctup | Should -Be "v1.7.1"
        $manifest.families.'vanessa-ui'.backendVersions.clientMcp | Should -Be "v0.6.5"
        $manifest.families.'vanessa-ui'.backendVersions.vaExtension | Should -Be "1.2.043.28"
        $manifest.families.'vanessa-ui'.backendVersions.vanessaAutomation | Should -Be "1.2.043.28"
        $manifest.families.'vanessa-ui'.backendRevisions.vanessaAutomation | Should -Be "itl-r7"
        $manifest.families.'vanessa-ui'.vanessaAutomationArtifact.archiveSha256 | Should -Be "d96ac6e48578ac8b2dc65d645b1748bc5f6183c58bcd22987122dc8e45e19c1e"
        $manifest.families.'vanessa-ui'.vanessaAutomationArtifact.epfSha256 | Should -Be "d17b20bca54861b025256652a84dec18cdcc2d20b4a08932c5141054d7dc7f9f"
        $manifest.families.'vanessa-ui'.vanessaAutomationArtifact.manifestSha256 | Should -Be "f8dc93948bff574ecf51570227757ce0caa0c18f5c3b9c93174a8b381c79ad48"
        $manifest.families.'vanessa-ui'.vanessaAutomationArtifact.patchSha256 | Should -Be "b19fba2bccb0f997525cf92433a817e3d6d25a49ce16961319397bfba79bd25f"
        $manifest.families.'vanessa-ui'.backendVersions.vanessaExt | Should -Be "1.3.9.131"
        $manifest.families.'vanessa-ui'.embeddedDependencies.vanessaExt.version | Should -Be "1.3.9.131"
        $manifest.families.'vanessa-ui'.embeddedDependencies.vanessaExt.sha256 | Should -Match '^[0-9a-f]{64}$'
        $lock = Get-Content -LiteralPath (Join-Path $RepoRoot "templates\dependency-lock.json") -Raw -Encoding UTF8 | ConvertFrom-Json
        [string]$lock.dependencies.itlOndemandMcp.version | Should -Be "0.4.7"
        [string]$lock.dependencies.itlOndemandMcp.url | Should -Be "https://github.com/xmentosx/1c-agent-workflow/releases/download/itl-ondemand-mcp-v0.4.7/itl-ondemand-mcp-windows-amd64.exe"
        [string]$lock.dependencies.itlOndemandMcp.sha256 | Should -Be "bfdfe62986cab26ded5ca573d067a7a283901287649cfabb38b6fc5534911b35"
        [string]$lock.dependencies.itlOndemandMcp.sha256 | Should -Not -Be "45debfd236dcb1b1b00dcfbf5343e236be05884cba0f00e42eb94ae72d1cfb13"
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
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-ondemand-main-helper-" + [guid]::NewGuid().ToString("N"))
        $mainRoot = Join-Path $tempRoot "main"; $branchRoot = Join-Path $tempRoot "branch"
        $oldExecutable = [Environment]::GetEnvironmentVariable("ITL_ONDEMAND_MCP_EXE", "Process")
        try {
            $workflowRoot = Join-Path $mainRoot ".agents\skills\1c-workflow"
            New-Item -ItemType Directory -Force -Path (Join-Path $workflowRoot "scripts"), (Join-Path $workflowRoot "assets"), $mainRoot | Out-Null
            Copy-Item -LiteralPath $AssetRoot -Destination (Join-Path $workflowRoot "assets\ondemand-mcp") -Recurse
            Set-Content -LiteralPath (Join-Path $workflowRoot "scripts\agent-1c.ps1") -Encoding UTF8 -Value "param()"
            Set-Content -LiteralPath (Join-Path $mainRoot "README.md") -Encoding UTF8 -Value "fixture"
            & git -C $mainRoot init *> $null; & git -C $mainRoot config user.email "test@example.com"; & git -C $mainRoot config user.name "Test User"; & git -C $mainRoot add .
            & git -C $mainRoot commit -m "base" *> $null
            & git -C $mainRoot branch -M master
            & git -C $mainRoot worktree add --quiet -b itldev/test $branchRoot master *> $null

            $executable = Join-Path $tempRoot "itl-ondemand-mcp.exe"
            Set-Content -LiteralPath $executable -Encoding ASCII -Value "fixture"
            [Environment]::SetEnvironmentVariable("ITL_ONDEMAND_MCP_EXE", $executable, "Process")
            $endpoints = & {
                . $HelperPath -ProjectRoot $branchRoot -Action help *> $null
                Get-ItlOnDemandMcpEndpointDescriptors
            }

            @($endpoints).Count | Should -Be 2
            $expectedHelper = [System.IO.Path]::GetFullPath((Join-Path $workflowRoot "scripts\agent-1c.ps1")); $expectedCatalogRoot = [System.IO.Path]::GetFullPath((Join-Path $workflowRoot "assets\ondemand-mcp\catalogs"))
            foreach ($endpoint in @($endpoints)) {
                $helperIndex = [Array]::IndexOf([object[]]$endpoint.args, "--helper"); $catalogIndex = [Array]::IndexOf([object[]]$endpoint.args, "--catalog")
                $endpoint.args[$helperIndex + 1] | Should -Be $expectedHelper
                [string]$endpoint.args[$catalogIndex + 1] | Should -Match ("^" + [regex]::Escape($expectedCatalogRoot))
                $endpoint.args[$helperIndex + 1] | Should -Not -Match ([regex]::Escape($branchRoot))
            }
        } finally {
            [Environment]::SetEnvironmentVariable("ITL_ONDEMAND_MCP_EXE", $oldExecutable, "Process")
            $previousPreference = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
            try {
                if (Test-Path -LiteralPath $branchRoot -PathType Container -ErrorAction SilentlyContinue) {
                    & git -C $mainRoot worktree remove --force --force $branchRoot *> $null
                }
            } finally {
                $ErrorActionPreference = $previousPreference
            }
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
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

    It "rejects a facade lock mismatch and never falls back to an older installed version" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-ondemand-contract-" + [guid]::NewGuid().ToString("N"))
        $oldInstallRoot = [Environment]::GetEnvironmentVariable("ITL_ONDEMAND_MCP_INSTALL_ROOT", "Process")
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"aiRules":{"tools":["kilocode"]}}'
            $lock = Get-Content -LiteralPath (Join-Path $RepoRoot "templates\dependency-lock.json") -Raw -Encoding UTF8 | ConvertFrom-Json
            $lock.dependencies.itlOndemandMcp.version = "0.4.2"
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\dependency-lock.json") -Encoding UTF8 -Value ($lock | ConvertTo-Json -Depth 20)
            $installRoot = Join-Path $tempRoot "ondemand"
            New-Item -ItemType Directory -Force -Path (Join-Path $installRoot "0.4.2") | Out-Null
            Set-Content -LiteralPath (Join-Path $installRoot "0.4.2\itl-ondemand-mcp-windows-amd64.exe") -Encoding ASCII -Value "old facade"
            [Environment]::SetEnvironmentVariable("ITL_ONDEMAND_MCP_INSTALL_ROOT", $installRoot, "Process")

            $mismatch = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                try { Get-ItlOnDemandMcpExecutablePath -AllowMissing } catch { $_.Exception.Message }
            }
            $mismatch | Should -Match "ITL_ONDEMAND_FACADE_LOCK_MISMATCH"

            $lock.dependencies.itlOndemandMcp.version = "0.4.7"
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\dependency-lock.json") -Encoding UTF8 -Value ($lock | ConvertTo-Json -Depth 20)
            $resolved = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                Get-ItlOnDemandMcpExecutablePath -AllowMissing
            }
            $resolved | Should -Be (Join-Path $installRoot "0.4.7\itl-ondemand-mcp-windows-amd64.exe")
            $resolved | Should -Not -Match ([regex]::Escape("\0.4.2\"))
        } finally {
            [Environment]::SetEnvironmentVariable("ITL_ONDEMAND_MCP_INSTALL_ROOT", $oldInstallRoot, "Process")
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

                $version = "0.4.7"
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

            $result.path | Should -Be (Join-Path $tempRoot "localapp\ondemand\0.4.7\itl-ondemand-mcp-windows-amd64.exe")
            $result.sha256 | Should -Match '^[a-f0-9]{64}$'
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "does not replace a verified cached facade with a stale source-repository build" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-ondemand-stale-source-" + [guid]::NewGuid().ToString("N"))
        try {
            $skillRoot = Join-Path $tempRoot ".agents\skills\1c-workflow"
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            & git -C $tempRoot init *> $null
            if ($LASTEXITCODE -ne 0) { throw "Failed to initialize the stale source-build fixture repository." }
            Copy-Item -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow") -Destination $skillRoot -Recurse -Force
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"aiRules":{"tools":["kilocode"]}}'

            $sourceBuild = Join-Path $tempRoot "tools\itl-ondemand-mcp\build\itl-ondemand-mcp-windows-amd64.exe"
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $sourceBuild) | Out-Null
            Set-Content -LiteralPath $sourceBuild -Encoding Byte -Value ([byte[]](1, 2, 3))
            $cachedBytes = [byte[]](4, 5, 6, 7)
            $cachedSha256 = ([BitConverter]::ToString(([Security.Cryptography.SHA256]::Create().ComputeHash($cachedBytes)))).Replace("-", "").ToLowerInvariant()
            $installedHelper = Join-Path $skillRoot "scripts\agent-1c.ps1"

            $result = & {
                . $installedHelper -ProjectRoot $tempRoot -Action help *> $null
                $installRoot = Join-Path $tempRoot "localapp\ondemand"
                function Get-ItlOnDemandMcpInstallRoot { return $installRoot }
                function Get-DependencyLockEntry {
                    param([string]$Name)
                    return [pscustomobject]@{
                        version = "0.4.7"
                        assetName = "itl-ondemand-mcp-windows-amd64.exe"
                        url = "https://example.invalid/itl-ondemand-mcp.exe"
                        sha256 = $cachedSha256
                    }
                }
                $targetPath = Join-Path $installRoot "0.4.7\itl-ondemand-mcp-windows-amd64.exe"
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $targetPath) | Out-Null
                [IO.File]::WriteAllBytes($targetPath, $cachedBytes)
                Install-ItlOnDemandMcp
            }

            $result.sha256 | Should -Be $cachedSha256
            [IO.File]::ReadAllBytes([string]$result.path) | Should -Be $cachedBytes
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "installs an exact source-build facade from a publication candidate without Git metadata" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-ondemand-publication-candidate-" + [guid]::NewGuid().ToString("N"))
        try {
            $skillRoot = Join-Path $tempRoot ".agents\skills\1c-workflow"
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            Copy-Item -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow") -Destination $skillRoot -Recurse -Force
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"aiRules":{"tools":["kilocode"]}}'

            $sourceBuild = Join-Path $tempRoot "tools\itl-ondemand-mcp\build\itl-ondemand-mcp-windows-amd64.exe"
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $sourceBuild) | Out-Null
            $sourceBytes = [byte[]](8, 6, 7, 5, 3, 0, 9)
            [IO.File]::WriteAllBytes($sourceBuild, $sourceBytes)
            $sourceSha256 = (Get-FileHash -LiteralPath $sourceBuild -Algorithm SHA256).Hash.ToLowerInvariant()
            $installedHelper = Join-Path $skillRoot "scripts\agent-1c.ps1"

            $result = & {
                . $installedHelper -ProjectRoot $tempRoot -Action help *> $null
                $installRoot = Join-Path $tempRoot "localapp\ondemand"
                function Get-ItlOnDemandMcpInstallRoot { return $installRoot }
                function Get-DependencyLockEntry {
                    param([string]$Name)
                    return [pscustomobject]@{
                        version = "0.4.7"
                        assetName = "itl-ondemand-mcp-windows-amd64.exe"
                        url = "https://example.invalid/itl-ondemand-mcp.exe"
                        sha256 = $sourceSha256
                    }
                }
                Install-ItlOnDemandMcp
            }

            $result.sha256 | Should -Be $sourceSha256
            [IO.File]::ReadAllBytes([string]$result.path) | Should -Be $sourceBytes
            (Test-Path -LiteralPath (Join-Path $tempRoot ".git")) | Should -BeFalse
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
        $vanessa = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.vanessa.ps1") -Raw -Encoding UTF8
        foreach ($functionName in @("Start-VanessaMcp", "Stop-VanessaMcp", "Show-VanessaMcpStatus", "Resolve-VanessaMcpPort")) {
            $vanessa | Should -Not -Match ("function " + [regex]::Escape($functionName) + "\s*\{")
        }
        $vanessa | Should -Match 'function Get-VanessaMcpRuntimeInfo\s*\{'
        $vanessa | Should -Match 'function Stop-VanessaMcpForState\s*\{'
    }

    It "does not reacquire the runtime lock from nested facade broker operations" {
        $tokens = $null
        $parseErrors = $null
        $entrypointAst = [Management.Automation.Language.Parser]::ParseFile($HelperPath, [ref]$tokens, [ref]$parseErrors)
        @($parseErrors) | Should -BeNullOrEmpty
        $operationParameter = @($entrypointAst.ParamBlock.Parameters | Where-Object {
            $_.Name.VariablePath.UserPath -eq "InternalOnDemandOperation"
        })
        $operationParameter.Count | Should -Be 1
        $validateSet = @($operationParameter[0].Attributes | Where-Object {
            $_.TypeName.Name -eq "ValidateSet"
        })
        $validateSet.Count | Should -Be 1
        $brokerOperations = @($validateSet[0].PositionalArguments | ForEach-Object { [string]$_.Value } | Where-Object { $_ })
        $brokerOperations | Should -Contain "mark-running"

        foreach ($operation in @($brokerOperations | Where-Object { $_ -ne "stop-all" })) {
            $action = "internal-ondemand-$operation"
            Test-Agent1cActionRequiresLifecycleLock -RequestedAction $action | Should -BeFalse -Because "$action runs inside the facade-owned runtime lease"
        }
        Test-Agent1cActionRequiresLifecycleLock -RequestedAction "internal-ondemand-stop-all" | Should -BeTrue
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
            $broker | Should -Match '(?s)Start-EnterpriseBackground.*?-InfoBasePath \$serviceInfoBase\.path.*?-UseTestManager'
            $broker | Should -Match 'managerInfoBasePath = \$\(if \(\$Family -eq "vanessa-ui"\) \{ \[string\]\$serviceInfoBase\.path \}'
            $broker | Should -Match 'infoBasePath = \[string\]\$state\.devBranchInfoBasePath'
            $broker | Should -Match 'Start-EnterpriseBackground[\s\S]*-UseTestClient[\s\S]*-TestClientPort'
            $broker | Should -Not -Match 'Assert-VanessaTestClientCapacity'
            $broker | Should -Match 'testClientProcessStartTime'
            $broker | Should -Match 'schemaVersion\s*=\s*4'
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "records the actual executable returned for an on-demand backend manager" {
        $runtime = & {
            $script:runtimeStatuses = @()
            function Read-ItlOnDemandRuntimeState { return $null }
            function Read-CurrentDevBranchStateForRoctupMcp {
                return [pscustomobject]@{ devBranchInfoBasePath = "D:\owned\base"; infoBaseKind = "file" }
            }
            function Ensure-DevBranchEnterpriseNormalized { param([object]$State) return $State }
            function Get-ItlOnDemandPortFamily { return "roctup-mcp" }
            function Get-ItlOnDemandPortKey { return "roctup-key" }
            function Install-RoctupMcpArtifact { return [pscustomobject]@{ path = "D:\tools\roctup.epf"; version = "1.0" } }
            function Get-RoctupMcpPortRange { return [pscustomobject]@{ start = 48000; end = 48010 } }
            function New-ItlManagedPortLeaseToken { return "backend-token" }
            function Resolve-ItlManagedPortLease { return [pscustomobject]@{ port = 48001; leaseToken = "backend-token" } }
            function Get-RoctupMcpUrl { return "http://127.0.0.1:48001/mcp" }
            function Start-EnterpriseBackground {
                return [pscustomobject]@{
                    process = [pscustomobject]@{ Id = 76001 }
                    executablePath = "D:\platform\bin\1cv8c.exe"
                    logPath = "D:\logs\roctup.log"
                }
            }
            function Wait-RoctupMcpPort { return $true }
            function Test-ItlOnDemandPortOwnedByProcess { return $true }
            function Set-ItlOnDemandManagedPortLeaseStatus {}
            function Get-Process { return [pscustomobject]@{ Id = 76001; StartTime = [datetime]"2026-07-31T08:00:00Z" } }
            function Resolve-Agent1cFullPath { param([string]$Path) return $Path }
            function Write-ItlOnDemandRuntimeState {
                param([object]$RuntimeState)
                $script:runtimeStatuses += [string]$RuntimeState.status
                return "runtime.json"
            }

            $started = Start-ItlOnDemandBackendInstance -Family "roctup" -InstanceId ("a" * 32) -CatalogSha256 ("b" * 64)
            [pscustomobject]@{ state = $started; statuses = @($script:runtimeStatuses) }
        }

        $runtime.state.executablePath | Should -Be "D:\platform\bin\1cv8c.exe"
        $runtime.state.pid | Should -Be 76001
        $runtime.state.status | Should -Be "readiness"
        $runtime.statuses | Should -Be @("starting", "process-started", "readiness")
    }

    It "retains startup state and leases when failed readiness cannot prove process exit and closed ports" {
        $result = & {
            $script:statuses = @()
            $script:releaseCalls = 0
            function Read-ItlOnDemandRuntimeState { return $null }
            function Read-CurrentDevBranchStateForRoctupMcp { return [pscustomobject]@{ devBranchInfoBasePath = "D:\owned\base"; infoBaseKind = "file" } }
            function Ensure-DevBranchEnterpriseNormalized { param([object]$State) return $State }
            function Get-ItlOnDemandPortFamily { return "roctup-mcp" }
            function Get-ItlOnDemandPortKey { return "roctup-key" }
            function Install-RoctupMcpArtifact { return [pscustomobject]@{ path = "D:\tools\roctup.epf"; version = "1.0" } }
            function Get-RoctupMcpPortRange { return [pscustomobject]@{ start = 48000; end = 48010 } }
            function New-ItlManagedPortLeaseToken { return "failure-token" }
            function Resolve-ItlManagedPortLease { return [pscustomobject]@{ port = 48002; leaseToken = "failure-token" } }
            function Get-RoctupMcpUrl { return "http://127.0.0.1:48002/mcp" }
            function Start-EnterpriseBackground { return [pscustomobject]@{ process = [pscustomobject]@{ Id = 76002 }; executablePath = "D:\platform\bin\1cv8c.exe"; logPath = "D:\logs\roctup.log" } }
            function Get-Process { return [pscustomobject]@{ Id = 76002; StartTime = [datetime]"2026-07-31T08:00:00Z" } }
            function Resolve-Agent1cFullPath { param([string]$Path) return $Path }
            function Set-ItlOnDemandManagedPortLeaseStatus {}
            function Wait-RoctupMcpPort { return $false }
            function Stop-Process {}
            function Test-TcpPortOpen { return $true }
            function Release-ItlOnDemandManagedPortLease { $script:releaseCalls++ }
            function Write-ItlOnDemandRuntimeState {
                param([object]$RuntimeState)
                $script:statuses += [string]$RuntimeState.status
                return "runtime.json"
            }
            $message = ""
            try { Start-ItlOnDemandBackendInstance -Family "roctup" -InstanceId ("2" * 32) -CatalogSha256 ("b" * 64) | Out-Null } catch { $message = $_.Exception.Message }
            [pscustomobject]@{ message = $message; statuses = @($script:statuses); releaseCalls = $script:releaseCalls }
        }
        $result.message | Should -Match "runtime state and leases were retained"
        $result.statuses | Should -Be @("starting", "process-started")
        $result.releaseCalls | Should -Be 0
    }

    It "marks a backend running only after strict process and port identity confirmation" {
        $result = & {
            $script:written = $null
            $script:allocationStatus = ""
            $script:confirmationEvents = @()
            $runtime = [pscustomobject]@{
                schemaVersion = 4; status = "readiness"; family = "roctup"; instanceId = ("5" * 32)
                pid = 76003; port = 48003; catalogSha256 = ("b" * 64); portFamily = "roctup-mcp"; portKey = "roctup-key"; portLeaseToken = "backend-token"
            }
            function Read-ItlOnDemandRuntimeState { return $runtime }
            function Test-ItlOnDemandOwnedProcess { return $true }
            function Test-ItlOnDemandPortOwnedByProcess { return $true }
            function Write-ItlOnDemandRuntimeState { param([object]$RuntimeState); $script:confirmationEvents += "runtime"; $script:written = $RuntimeState; return "runtime.json" }
            function Set-ItlOnDemandManagedPortLeaseStatus { param($Family, $Key, $LeaseToken, $Status, $ProcessId); $script:confirmationEvents += "lease"; $script:allocationStatus = "$LeaseToken/$Status" }
            $confirmed = Confirm-ItlOnDemandBackendRunning -Family "roctup" -InstanceId ("5" * 32) -ExpectedPid 76003 -ExpectedPort 48003 -CatalogSha256 ("b" * 64)
            [pscustomobject]@{ confirmed = $confirmed; written = $script:written; allocationStatus = $script:allocationStatus; events = @($script:confirmationEvents) }
        }
        $result.confirmed.status | Should -Be "running"
        $result.written.readiness | Should -Be "mcp-handshake-catalog-verified"
        $result.written.portOwnerPidVerified | Should -BeTrue
        $result.allocationStatus | Should -Be "backend-token/running"
        $result.events | Should -Be @("lease", "runtime")
    }

    It "excludes only the proven on-demand manager from TestClient port conflict checks" {
        $result = & {
            $state = [pscustomobject]@{
                devBranchInfoBasePath = "D:\work\owned\base"
                worktreePath = "D:\work\owned"
                stateProjectRoot = "D:\work"
                safeDevBranchName = "branch-owned"
            }
            function Get-OneCProcessInfo {
                @(
                    [pscustomobject]@{ processId = 71501; name = "1cv8.exe"; commandLine = '1cv8.exe ENTERPRISE /TESTMANAGER -TPort 48151 /F "D:\work\owned\base"' },
                    [pscustomobject]@{ processId = 71502; name = "1cv8c.exe"; commandLine = '1cv8c.exe ENTERPRISE /TESTCLIENT -TPort 48151 /F "D:\foreign\base"' }
                )
            }
            [pscustomobject]@{
                ownedWithoutExclusion = Test-VanessaTestPortOwnedByState -State $state -Port 48151
                ownedWithExclusion = Test-VanessaTestPortOwnedByState -State $state -Port 48151 -ExcludeProcessId 71501
                foreignWithManagerExcluded = Test-VanessaTestPortUsedByForeignProcess -State $state -Port 48151 -ExcludeProcessId 71501
                foreignWithForeignExcluded = Test-VanessaTestPortUsedByForeignProcess -State $state -Port 48151 -ExcludeProcessId 71502
            }
        }
        $result.ownedWithoutExclusion | Should -BeTrue
        $result.ownedWithExclusion | Should -BeFalse
        $result.foreignWithManagerExcluded | Should -BeTrue
        $result.foreignWithForeignExcluded | Should -BeFalse
    }

    It "reuses a proven owned on-demand TestClient without a new process" {
        $result = & {
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
            function Start-EnterpriseBackground { $script:testClientStarts++ }
            function Write-ItlOnDemandRuntimeState { return "state.json" }
            $reused = Ensure-ItlOnDemandVanessaTestClient -InstanceId ("a" * 32)
            [pscustomobject]@{ state = $reused.testClientState; reused = $reused.testClientReused; starts = $script:testClientStarts }
        }
        $result.state | Should -Be "port-ready"
        $result.reused | Should -BeTrue
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

    It "records the actual thin TestClient executable returned by the launcher" {
        $result = & {
            $runtime = [pscustomobject]@{
                schemaVersion = 3; status = "running"; family = "vanessa-ui"; instanceId = ("d" * 32)
                pid = 75001; port = 9877; url = "http://127.0.0.1:9877/mcp"
                testClientPid = 0; testClientPort = 48151; testClientState = "not-started"
                testClientPortFamily = "vanessa-test"; testClientPortKey = "fixture"; testClientPortLeaseToken = "client-token"
            }
            $script:WrittenRuntime = $null
            function Read-ItlOnDemandRuntimeState { return $runtime }
            function Test-ItlOnDemandOwnedProcess { return $true }
            function Test-TcpPortOpen { return $true }
            function Read-CurrentDevBranchStateForRoctupMcp {
                return [pscustomobject]@{ devBranchInfoBasePath = "D:\owned\base"; infoBaseKind = "file" }
            }
            function Test-VanessaTestPortOwnedByState { return $false }
            function Test-VanessaTestPortUsedByForeignProcess { return $false }
            function Start-EnterpriseBackground {
                return [pscustomobject]@{
                    process = [pscustomobject]@{ Id = 75002 }
                    executablePath = "D:\platform\bin\1cv8c.exe"
                    logPath = "D:\logs\test-client.log"
                }
            }
            function Get-Process {
                return [pscustomobject]@{ Id = 75002; StartTime = [datetime]"2026-07-31T08:00:00Z" }
            }
            function Write-ItlOnDemandRuntimeState {
                param([object]$RuntimeState)
                $script:WrittenRuntime = $RuntimeState
                return "state.json"
            }
            function Wait-ItlOnDemandTestClientPortReady { return $true }
            function Set-ItlOnDemandManagedPortLeaseStatus {}

            $ensured = Ensure-ItlOnDemandVanessaTestClient -InstanceId ("d" * 32)
            [pscustomobject]@{
                returnedPath = $ensured.testClientExecutablePath
                writtenPath = $script:WrittenRuntime.testClientExecutablePath
                state = $ensured.testClientState
            }
        }

        $result.returnedPath | Should -Be "D:\platform\bin\1cv8c.exe"
        $result.writtenPath | Should -Be "D:\platform\bin\1cv8c.exe"
        $result.state | Should -Be "port-ready"
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

    It "does not classify a missing PID with an open startup port as stale" {
        $health = & {
            function ConvertTo-IntOrDefault { param($Value, $Default) return [int]$Value }
            function Test-TcpPortOpen { return $true }
            Get-ItlOnDemandBackendRuntimeHealth -RuntimeState ([pscustomobject]@{ status = "starting"; pid = 0; port = 48109 })
        }
        $health.stale | Should -BeFalse
        $health.status | Should -Be "startup-port-open-ownership-unverified"
        $health.portOpen | Should -BeTrue
    }

    It "retains a recent starting registration with no PID while launch may still be in progress" {
        $health = & {
            function ConvertTo-IntOrDefault { param($Value, $Default) return [int]$Value }
            function Test-TcpPortOpen { return $false }
            Get-ItlOnDemandBackendRuntimeHealth -RuntimeState ([pscustomobject]@{
                status = "starting"
                startingAt = (Get-Date).ToUniversalTime().ToString("o")
                pid = 0
                port = 48112
            })
        }
        $health.stale | Should -BeFalse
        $health.status | Should -Be "startup-registration-unexpired"
        $health.portOpen | Should -BeFalse
    }

    It "classifies an expired starting registration stale only after PID absence and closed port are proven" {
        $health = & {
            function ConvertTo-IntOrDefault { param($Value, $Default) return [int]$Value }
            function Test-TcpPortOpen { return $false }
            Get-ItlOnDemandBackendRuntimeHealth -RuntimeState ([pscustomobject]@{
                status = "starting"
                startingAt = (Get-Date).ToUniversalTime().AddMinutes(-10).ToString("o")
                pid = 0
                port = 48113
            })
        }
        $health.stale | Should -BeTrue
        $health.status | Should -Be "startup-no-process-port-closed"
        $health.portOpen | Should -BeFalse
    }

    It "does not let stale cleanup remove an open-port startup lease" {
        $result = & {
            $script:stops = 0
            function Get-ItlOnDemandRuntimeInstances { return @([pscustomobject]@{ status = "starting"; family = "roctup"; instanceId = ("3" * 32); pid = 0; port = 48110 }) }
            function Get-ItlOnDemandBackendRuntimeHealth { return [pscustomobject]@{ stale = $false; status = "startup-port-open-ownership-unverified" } }
            function Stop-ItlOnDemandBackendInstance { $script:stops++ }
            [pscustomobject]@{ removed = Remove-ItlOnDemandStaleInstances; stops = $script:stops }
        }
        $result.removed | Should -Be 0
        $result.stops | Should -Be 0
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
                function Release-ItlOnDemandManagedPortLease {
                    param([string]$Family, [string]$Key, [string]$LeaseToken)
                    $script:Released += "$Family/$Key/$LeaseToken"
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
                    portLeaseToken = "backend-token"
                    port = 48120
                    infoBasePath = (Join-Path $tempRoot "base")
                    testClientPid = 0
                    testClientPort = 48170
                    testClientPortFamily = "vanessa-mcp-testclient"
                    testClientPortKey = "client-key"
                    testClientPortLeaseToken = "client-token"
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
            $result.released | Should -Contain "vanessa-mcp/backend-key/backend-token"
            $result.released | Should -Contain "vanessa-mcp-testclient/client-key/client-token"
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "waits for a strictly owned process to finish exiting after force stop" {
        $result = & {
            . $HelperPath -ProjectRoot $TestDrive -Action help *> $null
            $script:ProcessChecks = 0
            function Get-Process {
                param([int]$Id, [object]$ErrorAction)
                $script:ProcessChecks++
                if ($script:ProcessChecks -lt 3) { return [pscustomobject]@{ Id = $Id } }
                return $null
            }
            function Start-Sleep { param([int]$Milliseconds) }
            [pscustomobject]@{
                exited = Wait-ItlOnDemandProcessExit -ProcessId 42001 -TimeoutSeconds 1 -PollMilliseconds 1
                checks = $script:ProcessChecks
            }
        }
        $result.exited | Should -BeTrue
        $result.checks | Should -Be 3
    }

    It "fails closed when a strictly owned process remains alive through the exit deadline" {
        $result = & {
            . $HelperPath -ProjectRoot $TestDrive -Action help *> $null
            function Get-Process { param([int]$Id, [object]$ErrorAction); return [pscustomobject]@{ Id = $Id } }
            Wait-ItlOnDemandProcessExit -ProcessId 42002 -TimeoutSeconds 0 -PollMilliseconds 1
        }
        $result | Should -BeFalse
    }

    It "isolates on-demand lease tokens from branch leases and rejects ABA replacement cleanup" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-ondemand-lease-token-" + [guid]::NewGuid().ToString("N"))
        $oldRegistryHome = [Environment]::GetEnvironmentVariable("ITL_PORT_REGISTRY_HOME", "Process")
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"aiRules":{"tools":["codex"]}}'
            [Environment]::SetEnvironmentVariable("ITL_PORT_REGISTRY_HOME", (Join-Path $tempRoot "registry"), "Process")

            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $state = [pscustomobject]@{
                    devBranchName = "Lease isolation"
                    safeDevBranchName = "lease-isolation"
                    devBranch = "itldev/lease-isolation"
                    stateProjectRoot = $tempRoot
                    worktreePath = $tempRoot
                }
                $branchToken = New-ItlManagedPortLeaseToken
                $backendToken = New-ItlManagedPortLeaseToken
                $clientToken = New-ItlManagedPortLeaseToken
                $branch = Resolve-ItlManagedPortLease -Family "vanessa-mcp" -Key "branch-lease" -Start 45000 -End 55000 -State $state -LeaseToken $branchToken
                $backend = Resolve-ItlManagedPortLease -Family "vanessa-mcp" -Key "ondemand-backend" -Start 45000 -End 55000 -State $state -LeaseToken $backendToken
                $client = Resolve-ItlManagedPortLease -Family "vanessa-mcp-testclient" -Key "ondemand-client" -Start 45000 -End 55000 -State $state -LeaseToken $clientToken
                $allocatedPorts = @(
                    [int](Get-ItlPortObjectValue -Object $branch -Name "port" -Default 0)
                    [int](Get-ItlPortObjectValue -Object $backend -Name "port" -Default 0)
                    [int](Get-ItlPortObjectValue -Object $client -Name "port" -Default 0)
                )

                Set-ItlOnDemandManagedPortLeaseStatus -Family "vanessa-mcp" -Key "ondemand-backend" -LeaseToken $backendToken -Status "running" -ProcessId $PID
                Release-ItlOnDemandManagedPortLease -Family "vanessa-mcp" -Key "ondemand-backend" -LeaseToken $backendToken
                Release-ItlOnDemandManagedPortLease -Family "vanessa-mcp-testclient" -Key "ondemand-client" -LeaseToken $clientToken
                $afterOwnRelease = Read-ItlPortRegistry

                $oldToken = New-ItlManagedPortLeaseToken
                $replacementToken = New-ItlManagedPortLeaseToken
                $oldLease = Resolve-ItlManagedPortLease -Family "roctup-mcp" -Key "replacement-key" -Start 45000 -End 55000 -State $state -LeaseToken $oldToken
                Release-ItlManagedPortAllocation -Family "roctup-mcp" -Key "replacement-key" -LeaseToken $oldToken
                $replacement = Resolve-ItlManagedPortLease -Family "roctup-mcp" -Key "replacement-key" -Start 45000 -End 55000 -State $state -LeaseToken $replacementToken
                $replacementPort = [int](Get-ItlPortObjectValue -Object $replacement -Name "port" -Default 0)
                $mismatch = ""
                try {
                    Release-ItlOnDemandManagedPortLease -Family "roctup-mcp" -Key "replacement-key" -LeaseToken $oldToken
                } catch {
                    $mismatch = $_.Exception.Message
                }
                $afterStaleRelease = Read-ItlPortRegistry

                [pscustomobject]@{
                    distinctTokens = @(@($branchToken, $backendToken, $clientToken) | Sort-Object -Unique).Count
                    distinctPorts = @($allocatedPorts | Sort-Object -Unique).Count
                    branchCount = @($afterOwnRelease.allocations | Where-Object { $_.family -eq "vanessa-mcp" -and $_.key -eq "branch-lease" -and $_.leaseToken -eq $branchToken }).Count
                    backendCount = @($afterOwnRelease.allocations | Where-Object { $_.key -eq "ondemand-backend" }).Count
                    clientCount = @($afterOwnRelease.allocations | Where-Object { $_.key -eq "ondemand-client" }).Count
                    mismatch = $mismatch
                    replacementPort = $replacementPort
                    replacementCount = @($afterStaleRelease.allocations | Where-Object { $_.family -eq "roctup-mcp" -and $_.key -eq "replacement-key" -and $_.leaseToken -eq $replacementToken }).Count
                    oldTokenCount = @($afterStaleRelease.allocations | Where-Object { $_.leaseToken -eq $oldToken }).Count
                }
            }

            $result.distinctTokens | Should -Be 3
            $result.distinctPorts | Should -Be 3
            $result.branchCount | Should -Be 1
            $result.backendCount | Should -Be 0
            $result.clientCount | Should -Be 0
            $result.mismatch | Should -Match "ITL_ONDEMAND_PORT_LEASE_MISMATCH"
            $result.replacementPort | Should -BeGreaterThan 0
            $result.replacementCount | Should -Be 1
            $result.oldTokenCount | Should -Be 0
        } finally {
            [Environment]::SetEnvironmentVariable("ITL_PORT_REGISTRY_HOME", $oldRegistryHome, "Process")
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
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
                $portOwnedBeforeStop = Test-ItlOnDemandPortOwnedByProcess -Port $port -ProcessId $script:OwnedChild.Id
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
                    portOwnedBeforeStop = $portOwnedBeforeStop
                    runtimeRemoved = -not (Test-Path -LiteralPath $path)
                }
            }
            $child = $result.child
            $result.processAlive | Should -BeFalse
            $result.portOpen | Should -BeFalse
            $result.portOwnedBeforeStop | Should -BeTrue
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

    It "uses strict ownership by default and retains an unverified live PID without an explicit switch" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-ondemand-default-strict-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"aiRules":{"tools":["codex"]}}'
            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $runtimeRoot = Join-Path $tempRoot "runtime"
                function Get-ItlOnDemandRuntimeRoot { return $runtimeRoot }
                $script:releaseCalls = 0
                function Release-ItlManagedPortAllocation { $script:releaseCalls++ }
                function Get-Process { return [pscustomobject]@{ Id = 79001 } }
                function Test-ItlOnDemandOwnedProcess { return $false }
                function Test-TcpPortOpen { return $true }
                $instanceId = "4" * 32
                $path = Write-ItlOnDemandRuntimeState -RuntimeState ([pscustomobject][ordered]@{
                    schemaVersion = 4; status = "readiness"; family = "roctup"; instanceId = $instanceId
                    pid = 79001; processStartTime = "2026-08-03T00:00:00Z"; executablePath = "D:\platform\1cv8c.exe"
                    ownershipMarkers = @("owned-marker"); portFamily = "roctup-mcp"; portKey = "strict-key"; port = 48111
                    testClientPid = 0; testClientPort = 0; testClientPortFamily = ""; testClientPortKey = ""; vanessaParamsPath = ""
                })
                $message = ""
                try { Stop-ItlOnDemandBackendInstance -Family "roctup" -InstanceId $instanceId | Out-Null } catch { $message = $_.Exception.Message }
                [pscustomobject]@{ message = $message; restored = Test-Path -LiteralPath $path; releaseCalls = $script:releaseCalls }
            }
            $result.message | Should -Match "^ITL_ONDEMAND_OWNERSHIP_MISMATCH"
            $result.restored | Should -BeTrue
            $result.releaseCalls | Should -Be 0
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
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
