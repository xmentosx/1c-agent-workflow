Describe "1C workflow dependency lock checks" {
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
    It "install contract stays consistent across installer update-workflow and docs" {
        $installerText = Get-Content -Encoding UTF8 -Raw $InstallerPath
        $lifecycleText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.lifecycle.ps1")
        $installDocText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "AGENT-INSTALL.md")
        $initSetupText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".agents\skills\1c-workflow\references\init-setup.md")
        foreach ($skillPath in @(
            ".agents\skills\1c-workflow",
            ".agents\skills\1c-workflow-fast",
            ".agents\skills\product-docs",
            ".agents\skills\itl-roctup-1c-data",
            ".agents\skills\itl-vanessa-ui-mcp"
        )) {
            $installerText | Should -Match ([regex]::Escape($skillPath))
            $lifecycleText | Should -Match ([regex]::Escape($skillPath))
            (Test-Path -LiteralPath (Join-Path $RepoRoot ($skillPath + "\SKILL.md")) -PathType Leaf) | Should -Be $true

            $docsSkillPath = $skillPath -replace '\\', '/'
            $installDocText | Should -Match ([regex]::Escape($docsSkillPath))
            $initSetupText | Should -Match ([regex]::Escape($docsSkillPath))
        }
    }

    It "keeps required package files visible for Git packaging" {
        $requiredFiles = @(
            ".agents/skills/1c-workflow/scripts/lib/agent-1c.core.ps1",
            ".agents/skills/1c-workflow/scripts/lib/agent-1c.ports.ps1",
            ".agents/skills/1c-workflow/scripts/lib/agent-1c.data-mcp.ps1",
            ".agents/skills/1c-workflow/scripts/lib/agent-1c.vanessa.ps1",
            ".agents/skills/1c-workflow/scripts/lib/agent-1c.vibecoding1c-mcp.ps1",
            ".agents/skills/1c-workflow/scripts/lib/agent-1c.lifecycle.ps1",
            ".agents/skills/1c-workflow/scripts/lib/agent-1c.ai-rules-migration.ps1",
            ".agents/skills/1c-workflow/kilo-command-templates/common/itl.md.template",
            ".agents/skills/1c-workflow/kilo-command-templates/master/itl-new-config-branch.md.template",
            ".agents/skills/1c-workflow/kilo-command-templates/master/itl-update-workflow.md.template",
            ".agents/skills/1c-workflow/kilo-command-templates/dev/itl-result.md.template",
            "install-agent-1c-workflow.ps1",
            "scripts/test.ps1",
            "scripts/check.ps1",
            "scripts/invoke-release-e2e.ps1",
            "templates/AGENTS.append.md",
            "templates/USER-RULES.append.md",
            "templates/dependency-lock.json",
            ".agents/skills/1c-workflow/tools/data-mcp-tools-loader/DataMcpToolsLoader.xml",
            ".agents/skills/1c-workflow/tools/event-log-exporter/EventLogExporter.xml"
        )

        foreach ($relativePath in $requiredFiles) {
            (Test-Path -LiteralPath (Join-Path $RepoRoot $relativePath) -PathType Leaf) | Should -Be $true
            @(& git -C $RepoRoot ls-files --cached --others --exclude-standard -- $relativePath).Count | Should -BeGreaterThan 0
        }

        $modulePath = @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\tools\event-log-exporter") -Recurse -File -Filter "Module.bsl" | Select-Object -First 1).FullName
        $modulePath | Should -Not -BeNullOrEmpty
        $moduleRelativePath = $modulePath.Substring($RepoRoot.Length + 1).Replace("\", "/")
        @(& git -C $RepoRoot ls-files --cached --others --exclude-standard -- $moduleRelativePath).Count | Should -BeGreaterThan 0
        (Get-Content -LiteralPath (Join-Path $RepoRoot "templates\gitignore.append") -Raw -Encoding UTF8) |
            Should -Match ([regex]::Escape('.agent-1c/client-surface.json'))
    }

    It "keeps direct process TEMP access inside the shared temp resolver" {
        $tempReaders = @($HelperModulePaths | ForEach-Object {
            Select-String -LiteralPath $_ -SimpleMatch '$env:TEMP'
        })
        $tmpReaders = @($HelperModulePaths | ForEach-Object {
            Select-String -LiteralPath $_ -SimpleMatch '$env:TMP'
        })

        $tempReaders.Count | Should -Be 1
        $tmpReaders.Count | Should -Be 1
        (Split-Path -Leaf $tempReaders[0].Path) | Should -Be "agent-1c.core.ps1"
        (Split-Path -Leaf $tmpReaders[0].Path) | Should -Be "agent-1c.core.ps1"
    }

    It "falls back from invalid process temp aliases and preserves a valid TEMP" {
        $fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-temp-root-test-" + [guid]::NewGuid().ToString("N"))
        $validTemp = Join-Path $fixtureRoot "valid-temp"
        $localAppData = Join-Path $fixtureRoot "local-app-data"
        $localTemp = Join-Path $localAppData "Temp"
        $brokenTemp = Join-Path $fixtureRoot "BROKEN~1.USR\AppData\Local\Temp\108"
        $savedTemp = $env:TEMP
        $savedTmp = $env:TMP
        $savedLocalAppData = $env:LOCALAPPDATA

        try {
            New-Item -ItemType Directory -Force -Path $validTemp, $localTemp | Out-Null

            $env:TEMP = $validTemp
            $env:TMP = $brokenTemp
            $env:LOCALAPPDATA = $localAppData
            $resolvedValid = & {
                . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
                Get-Agent1cTempRoot
            }
            $resolvedValid | Should -Be (Resolve-Path -LiteralPath $validTemp).Path

            $env:TEMP = $brokenTemp
            $env:TMP = $brokenTemp
            $resolvedFallback = & {
                . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
                $tempRoot = Get-Agent1cTempRoot
                [pscustomobject]@{
                    tempRoot = $tempRoot
                    writable = Test-Agent1cWritableDirectory -Path $tempRoot
                    vanessaCache = Get-VanessaCacheDirectory
                }
            }

            $resolvedFallback.tempRoot | Should -Not -Be $brokenTemp
            (Test-Path -LiteralPath $resolvedFallback.tempRoot -PathType Container) | Should -Be $true
            $resolvedFallback.writable | Should -Be $true
            $resolvedFallback.vanessaCache | Should -Be (Join-Path $resolvedFallback.tempRoot "1c-agent-workflow\vanessa-automation")
        } finally {
            $env:TEMP = $savedTemp
            $env:TMP = $savedTmp
            $env:LOCALAPPDATA = $savedLocalAppData
            Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "wires dependency lock mode and verification policy" {
        $projectTemplate = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\project.json")
        $devEnvTemplate = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\dev.env.example")
        $lockTemplatePath = Join-Path $RepoRoot "templates\dependency-lock.json"
        $lockTemplate = Get-Content -Encoding UTF8 -Raw $lockTemplatePath | ConvertFrom-Json

        $projectTemplate | Should -Match '"dependencyMode"\s*:\s*"fresh"'
        $projectTemplate | Should -Match '"verificationPolicy"\s*:\s*"warn"'
        $devEnvTemplate | Should -Match "DEPENDENCY_MODE=fresh"
        $devEnvTemplate | Should -Match "VERIFICATION_POLICY=warn"
        $lockTemplate.mode | Should -Be "fresh"
        $project = $projectTemplate | ConvertFrom-Json
        $project.aiRules.repo | Should -Be "https://github.com/xmentosx/itl_ai_rules_1c.git"
        $project.aiRules.ref | Should -Be "itl-main-410951e7-r22"
        @($project.aiRules.tools).Count | Should -Be 0
        $lockTemplate.dependencies.aiRules1c.repo | Should -Be "https://github.com/xmentosx/itl_ai_rules_1c.git"
        $lockTemplate.dependencies.aiRules1c.ref | Should -Be "itl-main-410951e7-r22"
        $lockTemplate.dependencies.workflowPackage.commit | Should -Be ""
        $lockTemplate.dependencies.workflowPackage.source | Should -Be "template default"
        $lockTemplate.dependencies.workflowPackage.updatedAt | Should -Be ""
        $lockTemplate.dependencies.aiRules1c.commit | Should -Be "bcd94d1723f26a0b0568869845484c8572c402a6"
        $lockTemplate.dependencies.aiRules1c.upstreamRef | Should -Be "refs/heads/main"
        $lockTemplate.dependencies.aiRules1c.upstreamCommit | Should -Be "410951e74fd3e6b7a763cf49757935b9a34d3f31"
        $lockTemplate.dependencies.aiRules1c.downstreamRevision | Should -Be 22
        $lockTemplate.dependencies.aiRules1c.compatibilityStatus | Should -Be "pending"
        $lockTemplate.dependencies.aiRules1c.compatibilityCheckedAt | Should -Be ""
        $lockTemplate.dependencies.agentBrowser.version | Should -Be "0.33.1"
        $lockTemplate.dependencies.agentBrowser.profile | Should -Be "core"
        $lockTemplate.dependencies.windowsMcp.version | Should -Be "0.8.2"
        $lockTemplate.dependencies.piMcpExtension.version | Should -Be "1.5.0"
        $lockTemplate.dependencies.piMcpExtension.source | Should -Be "npm:pi-mcp-extension@1.5.0"
        $lockTemplate.dependencies.piMcpExtension.tarball | Should -Be "https://registry.npmjs.org/pi-mcp-extension/-/pi-mcp-extension-1.5.0.tgz"
        $lockTemplate.dependencies.piMcpExtension.integrity | Should -Be "sha512-tfsgi8qSr3UUKMp4vS9/FwKv+Pn2U4T/rTlAwrZkEIvz616mFrU/Ryp3b69ZDfFdkQVVXriaQmZUj4vlZDV2Uw=="
        $lockTemplate.dependencies.piMcpExtension.scope | Should -Be "project"
        $lockTemplate.dependencies.opencodePlugin.version | Should -Be "1.18.4"
        $lockTemplate.dependencies.opencodePlugin.source | Should -Be "npm:@opencode-ai/plugin@1.18.4"
        $lockTemplate.dependencies.opencodePlugin.tarball | Should -Be "https://registry.npmjs.org/@opencode-ai/plugin/-/plugin-1.18.4.tgz"
        $lockTemplate.dependencies.opencodePlugin.integrity | Should -Be "sha512-Mkq128aLJo4E8Sb2bX8zrRlQ+I2WPaJ/n1kzaor8nTi/K/zNP4t8LGKwyMbuRoD/lhw4veSbzDOASSSypv3mcQ=="
        $lockTemplate.dependencies.opencodePlugin.scope | Should -Be "project-runtime"
        $lockTemplate.dependencies.opencodePlugin.minimumNodeMajor | Should -Be 22
        $lockTemplate.dependencies.opencodePlugin.qualifiedOpenCodeDesktop | Should -Be "1.18.4"
        $lockTemplate.dependencies.opencodePlugin.compatibilityStatus | Should -Be "passed"
        $lockTemplate.dependencies.opencodePlugin.compatibilityCheckedAt | Should -Not -BeNullOrEmpty
        $lockTemplate.dependencies.roctupMcpToolkit.assetName | Should -Be "MCP_Toolkit.epf"
        $lockTemplate.dependencies.roctupMcpToolkit.sha256 | Should -Be "74bd1d228aa36fda688b34277ede6030ea3b54350c112a680cdce63adb8ac675"
        $lockTemplate.dependencies.vanessaMcp.clientMcp.sha256 | Should -Be "d1093475a15e50a33ad48a64b61d09d1108b5a39328c73e6be17a5c914825e7f"
        $lockTemplate.dependencies.vanessaMcp.vaExtension.assetName | Should -Be "VAExtension.1.29.cfe"
        $lockTemplate.dependencies.vanessaAutomation.compatibilityVersion | Should -Be "1.2.043.28"
        $lockTemplate.dependencies.vanessaAutomation.downstreamRevision | Should -Be "itl-r4"
        $lockTemplate.dependencies.vanessaAutomation.sha256 | Should -Be "55f487363b297251042e962146a73b08c9cffd115072c40d8143bbd2d1cb2f04"
        $lockTemplate.dependencies.vanessaAutomation.epfSha256 | Should -Be "7e52c7ed277bd69526fa07cc41b1d240d2d252a5ccc515712c6285610e1e1858"
        $lockTemplate.dependencies.vanessaAutomation.publicationStatus | Should -Be "published"
        $lockTemplate.dependencies.vanessaAutomation.PSObject.Properties.Name | Should -Contain "sha256"
        $lockTemplate.dependencies.vanessaMcp.clientMcp.PSObject.Properties.Name | Should -Contain "sha256"
        $lockTemplate.dependencies.vanessaMcp.vaExtension.PSObject.Properties.Name | Should -Contain "sha256"
        $lockTemplate.dependencies.PSObject.Properties.Name | Should -Not -Contain "apache"

        $HelperText | Should -Match "function Get-DependencyMode"
        $HelperText | Should -Match "function Get-GitHubApiHeaders"
        $HelperText | Should -Match "function Get-DependencyLockRateLimitFallbackInfo"
        $HelperText | Should -Match "function Update-DependencyLockEntry"
        $HelperText | Should -Match "function Get-VerificationPolicy"
        $HelperText | Should -Match "verificationPolicy=block"
        $HelperText | Should -Match "Dependency mode is locked"
    }

    It "keeps dependency lock bytes stable when an entry payload is unchanged" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-lock-idempotence-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"dependencyMode":"fresh"}'
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\dependency-lock.json") -Encoding UTF8 -Value '{"schemaVersion":1,"mode":"fresh","dependencies":{"fixture":{"version":"1","nested":{"value":2},"updatedAt":"original"}}}'
            $lockPath = Join-Path $tempRoot ".agent-1c\dependency-lock.json"

            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                Update-DependencyLockEntry -Name "fixture" -Values ([ordered]@{ version = "2"; nested = [ordered]@{ value = 3; updatedAt = "first" } })
            }
            $beforeRepeat = Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8
            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                Update-DependencyLockEntry -Name "fixture" -Values ([ordered]@{ version = "2"; nested = [ordered]@{ value = 3; updatedAt = "second" } })
            }
            (Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8) | Should -Be $beforeRepeat
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "reconciles every workflow-managed entry in a sparse fresh lock and preserves special and foreign entries" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-lock-sparse-fresh-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"dependencyMode":"fresh"}'
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\dependency-lock.json") -Encoding UTF8 -Value '{"schemaVersion":1,"mode":"fresh","dependencies":{"workflowPackage":{"commit":"keep-workflow"},"aiRules1c":{"commit":"keep-rules"},"apache":{"value":"keep-foreign"}}}'
            $lockPath = Join-Path $tempRoot ".agent-1c\dependency-lock.json"

            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $sync = Sync-WorkflowManagedDependencyLockEntries
                $manifest = Read-DependencyLockManifest
                $template = New-DefaultDependencyLockManifest
                $names = @(Get-WorkflowManagedDependencyLockEntryNames -TemplateManifest $template)
                [pscustomobject]@{ sync = $sync; manifest = $manifest; template = $template; names = $names }
            }

            $result.sync.changed | Should -BeTrue
            @($result.sync.entries | Sort-Object) | Should -Be @($result.names | Sort-Object)
            foreach ($name in $result.names) {
                $actualComparable = & {
                    . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                    ConvertTo-DependencyLockComparableValue -Value $result.manifest.dependencies.$name
                }
                $templateComparable = & {
                    . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                    ConvertTo-DependencyLockComparableValue -Value $result.template.dependencies.$name
                }
                ($actualComparable | ConvertTo-Json -Depth 100 -Compress) | Should -Be ($templateComparable | ConvertTo-Json -Depth 100 -Compress)
            }
            $result.manifest.dependencies.workflowPackage.commit | Should -Be "keep-workflow"
            $result.manifest.dependencies.aiRules1c.commit | Should -Be "keep-rules"
            $result.manifest.dependencies.apache.value | Should -Be "keep-foreign"

            $beforeRepeat = Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8
            $repeat = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                Sync-WorkflowManagedDependencyLockEntries
            }
            $repeat.changed | Should -BeFalse
            (Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8) | Should -Be $beforeRepeat
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "updates canonical pins without replacing compatibility runtime metadata" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-lock-runtime-metadata-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"dependencyMode":"fresh"}'
            $manifest = Get-Content -LiteralPath (Join-Path $RepoRoot "templates\dependency-lock.json") -Raw -Encoding UTF8 | ConvertFrom-Json
            $manifest.dependencies.roctupMcpToolkit.version = "v0"
            $manifest.dependencies.roctupMcpToolkit.source = "compatibility-manifest"
            $manifest.dependencies.roctupMcpToolkit.updatedAt = "runtime-roctup"
            $manifest.dependencies.vanessaMcp.clientMcp.version = "v0"
            $manifest.dependencies.vanessaMcp.clientMcp.source = "compatibility-manifest"
            $manifest.dependencies.vanessaMcp.clientMcp.updatedAt = "runtime-vanessa"
            $lockPath = Join-Path $tempRoot ".agent-1c\dependency-lock.json"
            Set-Content -LiteralPath $lockPath -Encoding UTF8 -Value (($manifest | ConvertTo-Json -Depth 20) + [Environment]::NewLine)

            $first = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                Sync-WorkflowManagedDependencyLockEntries | Out-Null
                Read-DependencyLockManifest
            }
            $canonical = Get-Content -LiteralPath (Join-Path $RepoRoot "templates\dependency-lock.json") -Raw -Encoding UTF8 | ConvertFrom-Json
            $first.dependencies.roctupMcpToolkit.version | Should -Be $canonical.dependencies.roctupMcpToolkit.version
            $first.dependencies.roctupMcpToolkit.source | Should -Be "compatibility-manifest"
            $first.dependencies.vanessaMcp.clientMcp.version | Should -Be $canonical.dependencies.vanessaMcp.clientMcp.version
            $first.dependencies.vanessaMcp.clientMcp.source | Should -Be "compatibility-manifest"

            $beforeRepeat = Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8
            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                Sync-WorkflowManagedDependencyLockEntries | Out-Null
            }
            (Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8) | Should -Be $beforeRepeat
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "reports every missing locked dependency path without mutating the lock" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-lock-sparse-locked-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"dependencyMode":"locked"}'
            $lockPath = Join-Path $tempRoot ".agent-1c\dependency-lock.json"
            Set-Content -LiteralPath $lockPath -Encoding UTF8 -Value '{"schemaVersion":1,"mode":"locked","dependencies":{"workflowPackage":{"commit":"keep"},"aiRules1c":{"commit":"keep"},"apache":{"value":"keep"}}}'
            $before = Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8

            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $template = New-DefaultDependencyLockManifest
                $names = @(Get-WorkflowManagedDependencyLockEntryNames -TemplateManifest $template)
                $errorText = ""
                try { Sync-WorkflowManagedDependencyLockEntries | Out-Null } catch { $errorText = $_.Exception.Message }
                [pscustomobject]@{ names = $names; error = $errorText }
            }

            $result.error | Should -Match "DEPENDENCY_LOCK_UPGRADE_REQUIRED"
            foreach ($name in $result.names) {
                $result.error | Should -Match ([regex]::Escape("dependencies.$name"))
            }
            (Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8) | Should -Be $before
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
