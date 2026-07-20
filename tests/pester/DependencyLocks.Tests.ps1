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
        $project.aiRules.ref | Should -Be "itl-main-72665287-r13"
        @($project.aiRules.tools).Count | Should -Be 0
        $lockTemplate.dependencies.aiRules1c.repo | Should -Be "https://github.com/xmentosx/itl_ai_rules_1c.git"
        $lockTemplate.dependencies.aiRules1c.ref | Should -Be "itl-main-72665287-r13"
        $lockTemplate.dependencies.workflowPackage.commit | Should -Be ""
        $lockTemplate.dependencies.workflowPackage.source | Should -Be "template default"
        $lockTemplate.dependencies.workflowPackage.updatedAt | Should -Be ""
        $lockTemplate.dependencies.aiRules1c.commit | Should -Be "b66569bebf46e0369efa53983fca69368e16d57a"
        $lockTemplate.dependencies.aiRules1c.upstreamRef | Should -Be "refs/heads/main"
        $lockTemplate.dependencies.aiRules1c.upstreamCommit | Should -Be "72665287e77361aea3aaf866fef163d98f0fabcd"
        $lockTemplate.dependencies.aiRules1c.downstreamRevision | Should -Be 13
        $lockTemplate.dependencies.aiRules1c.compatibilityStatus | Should -Be "passed"
        $lockTemplate.dependencies.piMcpExtension.version | Should -Be "1.5.0"
        $lockTemplate.dependencies.piMcpExtension.source | Should -Be "npm:pi-mcp-extension@1.5.0"
        $lockTemplate.dependencies.piMcpExtension.tarball | Should -Be "https://registry.npmjs.org/pi-mcp-extension/-/pi-mcp-extension-1.5.0.tgz"
        $lockTemplate.dependencies.piMcpExtension.integrity | Should -Be "sha512-tfsgi8qSr3UUKMp4vS9/FwKv+Pn2U4T/rTlAwrZkEIvz616mFrU/Ryp3b69ZDfFdkQVVXriaQmZUj4vlZDV2Uw=="
        $lockTemplate.dependencies.piMcpExtension.scope | Should -Be "project"
        $lockTemplate.dependencies.roctupMcpToolkit.assetName | Should -Be "MCP_Toolkit.epf"
        $lockTemplate.dependencies.roctupMcpToolkit.sha256 | Should -Be "74bd1d228aa36fda688b34277ede6030ea3b54350c112a680cdce63adb8ac675"
        $lockTemplate.dependencies.vanessaMcp.clientMcp.sha256 | Should -Be "d1093475a15e50a33ad48a64b61d09d1108b5a39328c73e6be17a5c914825e7f"
        $lockTemplate.dependencies.vanessaMcp.vaExtension.assetName | Should -Be "VAExtension.1.29.cfe"
        $lockTemplate.dependencies.vanessaAutomation.sha256 | Should -Be "cd0a017a8af69328f471f628ac1367a0e5148f790df9c28c318348b30f08f32a"
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
}
