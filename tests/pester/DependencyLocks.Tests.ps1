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
            ".agents\skills\itl-vanessa-ui-mcp",
            ".agents\skills\itl-remote-runner",
            ".agents\skills\itl-remote-agent",
            ".agents\skills\itl-performance"
        )) {
            $installerText | Should -Match ([regex]::Escape($skillPath))
            $lifecycleText | Should -Match ([regex]::Escape($skillPath))
            (Test-Path -LiteralPath (Join-Path $RepoRoot ($skillPath + "\SKILL.md")) -PathType Leaf) | Should -Be $true

            $docsSkillPath = $skillPath -replace '\\', '/'
            $installDocText | Should -Match ([regex]::Escape($docsSkillPath))
            $initSetupText | Should -Match ([regex]::Escape($docsSkillPath))
        }
        $installerText | Should -Match ([regex]::Escape('"templates\dependency-lock.json"'))
        $lifecycleText | Should -Match ([regex]::Escape('Join-Path $packageRoot "templates\dependency-lock.json"'))
    }

    It "keeps required package files visible for Git packaging" {
        $requiredFiles = @(
            ".agents/skills/1c-workflow/scripts/lib/agent-1c.immutable-download.ps1",
            ".agents/skills/1c-workflow/scripts/lib/agent-1c.core.ps1",
            ".agents/skills/1c-workflow/scripts/lib/agent-1c.ports.ps1",
            ".agents/skills/1c-workflow/scripts/lib/agent-1c.data-mcp.ps1",
            ".agents/skills/1c-workflow/scripts/lib/agent-1c.vanessa.ps1",
            ".agents/skills/1c-workflow/scripts/lib/agent-1c.vibecoding1c-mcp.ps1",
            ".agents/skills/1c-workflow/scripts/lib/agent-1c.lifecycle.ps1",
            ".agents/skills/1c-workflow/scripts/lib/agent-1c.ai-rules-migration.ps1",
            ".agents/skills/1c-workflow/kilo-command-templates/common/itl.md.template",
            ".agents/skills/1c-workflow/kilo-command-templates/master/itl-new-config-branch.md.template",
            ".agents/skills/1c-workflow/kilo-command-templates/common/itl-update-workflow.md.template",
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
        $lockTemplateText = Get-Content -Encoding UTF8 -Raw $lockTemplatePath
        $lockTemplate = $lockTemplateText | ConvertFrom-Json

        $projectTemplate | Should -Match '"dependencyMode"\s*:\s*"workflow"'
        $projectTemplate | Should -Match '"verificationPolicy"\s*:\s*"warn"'
        $devEnvTemplate | Should -Match "DEPENDENCY_MODE=workflow"
        $devEnvTemplate | Should -Match "VERIFICATION_POLICY=warn"
        $lockTemplate.mode | Should -Be "workflow"
        $project = $projectTemplate | ConvertFrom-Json
        $project.aiRules.repo | Should -Be "https://github.com/xmentosx/itl_ai_rules_1c.git"
        $project.aiRules.ref | Should -Be "itl-main-5700f54-r42"
        @($project.aiRules.tools).Count | Should -Be 0
        $lockTemplate.dependencies.aiRules1c.repo | Should -Be "https://github.com/xmentosx/itl_ai_rules_1c.git"
        $lockTemplate.dependencies.aiRules1c.ref | Should -Be "itl-main-5700f54-r42"
        $lockTemplate.dependencies.workflowPackage.commit | Should -Be ""
        $lockTemplate.dependencies.workflowPackage.source | Should -Be "template default"
        $lockTemplate.dependencies.workflowPackage.updatedAt | Should -Be ""
        $lockTemplate.dependencies.aiRules1c.commit | Should -Be "827e5ccaa7e319dc5871555f7e997093478359c4"
        $lockTemplate.dependencies.aiRules1c.upstreamRef | Should -Be "refs/heads/main"
        $lockTemplate.dependencies.aiRules1c.upstreamCommit | Should -Be "5700f54a899abb1e8b6483badd6986e5a0e6c1af"
        $lockTemplate.dependencies.aiRules1c.downstreamRevision | Should -Be 42
        $lockTemplate.dependencies.aiRules1c.compatibilityStatus | Should -BeIn @("pending", "passed")
        if ($lockTemplate.dependencies.aiRules1c.compatibilityStatus -eq "pending") {
            $lockTemplate.dependencies.aiRules1c.compatibilityCheckedAt | Should -Be ""
        } else {
            $lockTemplateText | Should -Match '"compatibilityCheckedAt"\s*:\s*"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z"'
        }
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
        $lockTemplate.dependencies.opencodePlugin.sdk.version | Should -Be "1.18.4"
        $lockTemplate.dependencies.opencodePlugin.sdk.source | Should -Be "npm:@opencode-ai/sdk@1.18.4"
        $lockTemplate.dependencies.opencodePlugin.sdk.tarball | Should -Be "https://registry.npmjs.org/@opencode-ai/sdk/-/sdk-1.18.4.tgz"
        $lockTemplate.dependencies.opencodePlugin.sdk.integrity | Should -Be "sha512-p/3P0KtWknoLvpsk8QrUzCKd4Q1A5Z3RmACEvwuQBGxnUy4AGo379lUYMgt7fczFn53079oroLuo6BosQri+HA=="
        $lockTemplate.dependencies.opencodePlugin.scope | Should -Be "project-runtime"
        $lockTemplate.dependencies.opencodePlugin.minimumNodeMajor | Should -Be 22
        $lockTemplate.dependencies.opencodePlugin.qualifiedOpenCodeDesktop | Should -Be "1.18.4"
        $lockTemplate.dependencies.opencodePlugin.compatibilityStatus | Should -Be "passed"
        $lockTemplate.dependencies.opencodePlugin.compatibilityCheckedAt | Should -Not -BeNullOrEmpty
        $lockTemplate.dependencies.roctupMcpToolkit.assetName | Should -Be "MCP_Toolkit.epf"
        $lockTemplate.dependencies.roctupMcpToolkit.sha256 | Should -Be "74bd1d228aa36fda688b34277ede6030ea3b54350c112a680cdce63adb8ac675"
        $lockTemplate.dependencies.itlOndemandMcp.releaseTag | Should -Be "itl-ondemand-mcp-v0.4.22"
        $lockTemplate.dependencies.vanessaMcp.clientMcp.sha256 | Should -Be "29f741db8a379384cd8270398761ec96e7e8e548071a0c180d4ffc6ddd8443b6"
        $lockTemplate.dependencies.vanessaMcp.vaExtension.assetName | Should -Be "VAExtension.1.32-itl-r4.cfe"
        $lockTemplate.dependencies.vanessaMcp.vaExtension.protocol | Should -Be "itl-file-code-v1"
        $lockTemplate.dependencies.vanessaMcp.vaExtension.sha256 | Should -Be "24190cb07ad82ac49aacdd86c1fb6412cd2f6713758cde123b1bb4103b7b4c0c"
        $lockTemplate.dependencies.vanessaAutomation.compatibilityVersion | Should -Be "1.2.043.42"
        $lockTemplate.dependencies.vanessaAutomation.downstreamRevision | Should -Be "itl-r4"
        $lockTemplate.dependencies.vanessaAutomation.sha256 | Should -Be "84aabfbf77511abd432c235625afb543aa3c182654e08a24bda3c4312c7d5f4c"
        $lockTemplate.dependencies.vanessaAutomation.epfSha256 | Should -Be "b1e5d7111115b6cea4fdf64774f31de2f485579f024e6af81c2b361ecabd4e1b"
        $lockTemplate.dependencies.vanessaAutomation.PSObject.Properties.Name | Should -Not -Contain "publicationStatus"
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
        $HelperText | Should -Match "function Get-WorkflowDependencyEntry"
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
            $rulesPin = (Get-Content -LiteralPath (Join-Path $RepoRoot 'templates/dependency-lock.json') -Raw -Encoding UTF8 | ConvertFrom-Json).dependencies.aiRules1c
            $sparse = @{schemaVersion=1;mode='fresh';dependencies=@{workflowPackage=@{commit='keep-workflow'};aiRules1c=$rulesPin;apache=@{value='keep-foreign'}}}
            Set-Content -LiteralPath (Join-Path $tempRoot '.agent-1c/dependency-lock.json') -Encoding UTF8 -Value ($sparse | ConvertTo-Json -Depth 30)
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
            $result.manifest.dependencies.aiRules1c.commit | Should -Be $rulesPin.commit
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

    It "updates canonical pins without replacing compatibility runtime metadata for <clientPolicy>" -TestCases @(
        @{ clientPolicy = 'published legacy baseline'; expectedClientSource = 'compatibility-manifest' }
        @{ clientPolicy = 'current owned pin'; expectedClientSource = 'workflow-pinned' }
    ) {
        param($clientPolicy, $expectedClientSource)
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-lock-runtime-metadata-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"dependencyMode":"fresh"}'
            $canonical = Get-Content -LiteralPath (Join-Path $RepoRoot "templates\dependency-lock.json") -Raw -Encoding UTF8 | ConvertFrom-Json
            $templatePath = Join-Path $RepoRoot "templates\dependency-lock.json"
            if ($clientPolicy -eq 'published legacy baseline') {
                # Exact client entry published at f5466e6ff98e95bae989a80d65809d1bff2bc31e.
                # Get-WorkflowTemplatePath resolves this fixture-local canonical input.
                $canonical.dependencies.vanessaMcp.clientMcp = [pscustomobject]@{
                    version = 'v0.6.5'
                    assetName = 'client_mcp.cfe'
                    url = 'https://github.com/1c-neurofish/onec-client-mcp-devkit/releases/download/v0.6.5/client_mcp.cfe'
                    sha256 = 'd1093475a15e50a33ad48a64b61d09d1108b5a39328c73e6be17a5c914825e7f'
                    source = 'template baseline'
                    updatedAt = '2026-05-26T19:34:34Z'
                }
                New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot 'templates') | Out-Null
                $templatePath = Join-Path $tempRoot 'templates\dependency-lock.json'
                [IO.File]::WriteAllText($templatePath, ($canonical | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
            } else {
                $canonical.dependencies.vanessaMcp.clientMcp.source | Should -BeExactly 'workflow-pinned'
                $canonical.dependencies.vanessaMcp.clientMcp.PSObject.Properties.Name | Should -Not -Contain 'updatedAt'
            }
            $canonicalBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($templatePath))
            $manifest = $canonical | ConvertTo-Json -Depth 20 | ConvertFrom-Json
            $manifest.dependencies.roctupMcpToolkit.version = "v0"
            $manifest.dependencies.roctupMcpToolkit.source = "compatibility-manifest"
            $manifest.dependencies.roctupMcpToolkit.updatedAt = "runtime-roctup"
            $manifest.dependencies.vanessaMcp.clientMcp.version = "v0"
            $manifest.dependencies.vanessaMcp.clientMcp.source = "compatibility-manifest"
            $manifest.dependencies.vanessaMcp.clientMcp | Add-Member -NotePropertyName updatedAt -NotePropertyValue "runtime-vanessa" -Force
            $lockPath = Join-Path $tempRoot ".agent-1c\dependency-lock.json"
            Set-Content -LiteralPath $lockPath -Encoding UTF8 -Value (($manifest | ConvertTo-Json -Depth 20) + [Environment]::NewLine)

            $selectionPath = Join-Path $tempRoot 'решение с пробелом.json'
            $selection = @{schemaVersion=1;worktrees=@(@{worktreePath=$tempRoot;decisions=@{roctupMcpToolkit='workflow';vanessaMcp='workflow'}})}
            [IO.File]::WriteAllText($selectionPath, ($selection | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
            $first = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help -DependencySelectionFile $selectionPath *> $null
                Sync-WorkflowManagedDependencyLockEntries | Out-Null
                Read-DependencyLockManifest
            }
            $first.dependencies.roctupMcpToolkit.version | Should -Be $canonical.dependencies.roctupMcpToolkit.version
            $first.dependencies.roctupMcpToolkit.source | Should -Be "compatibility-manifest"
            $first.dependencies.vanessaMcp.clientMcp.version | Should -Be $canonical.dependencies.vanessaMcp.clientMcp.version
            $first.dependencies.vanessaMcp.clientMcp.source | Should -Be $expectedClientSource
            $first.dependencies.vanessaMcp.clientMcp.updatedAt | Should -Not -BeNullOrEmpty
            foreach ($property in @($canonical.dependencies.vanessaMcp.clientMcp.PSObject.Properties | Where-Object { $_.Name -notin @('source', 'updatedAt') })) {
                ($first.dependencies.vanessaMcp.clientMcp.($property.Name) | ConvertTo-Json -Depth 20 -Compress) |
                    Should -BeExactly ($property.Value | ConvertTo-Json -Depth 20 -Compress)
            }

            $beforeRepeat = Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8
            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                Sync-WorkflowManagedDependencyLockEntries | Out-Null
            }
            (Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8) | Should -Be $beforeRepeat
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($templatePath)) | Should -BeExactly $canonicalBytes
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "reports a legacy custom rules identity with a continuation before mutating the lock" {
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

            $result.error | Should -Match "DEPENDENCY_SELECTION_REQUIRED"
            $result.error | Should -Match 'DependencySelectionFile'
            $report = Get-Content -LiteralPath (Join-Path $tempRoot '.agent-1c/snapshots/dependency-selection.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            @($report.blocked.component) | Should -Contain 'aiRules1c'
            $report.proposed.dependencies.apache.value | Should -Be 'keep'
            (Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8) | Should -Be $before
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "migrates a locked project after an explicit custom-pin decision and adds the pinned OpenSpec CLI" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-lock-openspec-upgrade-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot '.agent-1c') | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot '.agent-1c\project.json') -Encoding UTF8 -Value '{"dependencyMode":"locked"}'
            $lockPath = Join-Path $tempRoot '.agent-1c\dependency-lock.json'
            $template = Get-Content -LiteralPath (Join-Path $RepoRoot 'templates\dependency-lock.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            $expectedOpenSpec = $template.dependencies.openSpecCli
            $template.mode = 'locked'
            $template.dependencies.PSObject.Properties.Remove('openSpecCli')
            $template.dependencies.yaxunit.version = 'project-specific-pin'
            Set-Content -LiteralPath $lockPath -Encoding UTF8 -Value ($template | ConvertTo-Json -Depth 30)
            $beforeDecision = [Convert]::ToBase64String([IO.File]::ReadAllBytes($lockPath))
            { & { . $HelperPath -ProjectRoot $tempRoot -Action help *> $null; Sync-WorkflowManagedDependencyLockEntries } } | Should -Throw '*DEPENDENCY_SELECTION_REQUIRED*'
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($lockPath)) | Should -BeExactly $beforeDecision
            $selectionPath = Join-Path $tempRoot 'решение с пробелом.json'
            $selection = @{schemaVersion=1;worktrees=@(@{worktreePath=$tempRoot;decisions=@{yaxunit='workflow'}})}
            [IO.File]::WriteAllText($selectionPath, ($selection | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
            $first = & { . $HelperPath -ProjectRoot $tempRoot -Action help -DependencySelectionFile $selectionPath *> $null; Sync-WorkflowManagedDependencyLockEntries }
            $first.changed | Should -BeTrue
            @($first.entries) | Should -Contain 'openSpecCli'
            $after = Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $after.mode | Should -Be 'workflow'
            $after.dependencies.yaxunit.version | Should -Be ((Get-Content -LiteralPath (Join-Path $RepoRoot 'templates/dependency-lock.json') -Raw -Encoding UTF8 | ConvertFrom-Json).dependencies.yaxunit.version)
            $after.dependencies.openSpecCli.packageLockSha256 | Should -Be $expectedOpenSpec.packageLockSha256
            $beforeRepeat = Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8
            $repeat = & { . $HelperPath -ProjectRoot $tempRoot -Action help *> $null; Sync-WorkflowManagedDependencyLockEntries }
            $repeat.changed | Should -BeFalse
            (Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8) | Should -Be $beforeRepeat
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Workflow dependency selection' -Tag WorkflowDependencySelection {
    BeforeAll {
        $selectionRepo = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
        . (Join-Path $selectionRepo '.agents/skills/1c-workflow/scripts/lib/agent-1c.core.ps1')
        . (Join-Path $selectionRepo '.agents/skills/1c-workflow/scripts/lib/agent-1c.dependencies.ps1')
        function New-SelectionTestPin {
            param([string]$Version='1.0.0', [string]$Hash=('a' * 64), [string]$Revision='')
            $pin = [ordered]@{version=$Version;assetName='tool.bin';url="https://github.com/owner/tool/releases/download/$Version/tool.bin";sha256=$Hash}
            if ($Revision) { $pin['downstreamRevision']=$Revision }
            return $pin
        }
        function New-SelectionTestTemplate {
            param([object]$Pin=(New-SelectionTestPin))
            return [ordered]@{schemaVersion=2;mode='workflow';dependencies=[ordered]@{workflowPackage=@{commit='keep-provenance'};tool=$Pin}}
        }
        function New-SelectionTestHotfix {
            param([object]$Pin=(New-SelectionTestPin -Version '1.1.0' -Hash ('b'*64)))
            return [ordered]@{reason='incident fix';dependencies=[ordered]@{tool=$Pin}}
        }
    }

    It 'treats legacy <mode> as a migration alias rather than an independent version policy' -ForEach @(
        @{mode='fresh'},@{mode='locked'},@{mode='latest'},@{mode='pinned'},@{mode='workflow'}
    ) {
        ConvertTo-DependencyMode $mode | Should -Be workflow
    }

    It 'upgrades ordinary old pins from the installed baseline and preserves foreign records without mutating the input' {
        $old = New-SelectionTestTemplate
        $current = ConvertTo-Agent1cHashtable $old
        $current.mode='locked'
        $current.dependencies['foreign']=@{value='preserve'}
        $before = $current | ConvertTo-Json -Depth 20
        $target = New-SelectionTestTemplate (New-SelectionTestPin '2.0.0' ('c'*64))
        $plan = New-WorkflowDependencyPlan -Template $target -InstalledTemplate $old -Manifest $current
        @($plan.blocked).Count | Should -Be 0
        $plan.manifest.dependencies.tool.version | Should -Be '2.0.0'
        $plan.manifest.dependencies.foreign.value | Should -Be preserve
        $plan.manifest.dependencies.workflowPackage.commit | Should -Be keep-provenance
        ($current | ConvertTo-Json -Depth 20) | Should -Be $before
    }

    It 'keeps a blocked component getter observational and lets its update owner emit the report' {
        $root=Join-Path $TestDrive 'Диагностика выбора с пробелом'
        $result=& {
            . (Join-Path $selectionRepo '.agents/skills/1c-workflow/scripts/agent-1c.ps1') -ProjectRoot $root -Action help *> $null
            $manifest=New-DefaultDependencyLockManifest
            $manifest.dependencies.yaxunit.version='99.0.0'
            $lockPath=Join-Path $root '.agent-1c/dependency-lock.json'
            Write-Utf8Text -Path $lockPath -Value ($manifest|ConvertTo-Json -Depth 100)
            $before=(Get-FileHash -LiteralPath $lockPath).Hash
            $unrelated=Get-WorkflowDependencyEntry -Name roctupMcpToolkit
            {Get-WorkflowDependencyEntry -Name yaxunit}|Should -Throw '*DEPENDENCY_SELECTION_REQUIRED*Diagnostics have not changed*'
            $report=Join-Path $root '.agent-1c/snapshots/dependency-selection.json'
            Test-Path -LiteralPath $report|Should -BeFalse
            (Get-FileHash -LiteralPath $lockPath).Hash|Should -BeExactly $before
            {Sync-WorkflowManagedDependencyLockEntries}|Should -Throw '*DEPENDENCY_SELECTION_REQUIRED*'
            [pscustomobject]@{unrelated=$unrelated;report=(Test-Path -LiteralPath $report);before=$before;after=(Get-FileHash -LiteralPath $lockPath).Hash}
        }
        $result.unrelated.version|Should -Be v1.7.1
        $result.report|Should -BeTrue
        $result.after|Should -BeExactly $result.before
    }

    It 'requires an explicit decision for a custom legacy pin and accepts the workflow continuation' {
        $template = New-SelectionTestTemplate
        $custom = New-SelectionTestTemplate (New-SelectionTestPin '1.5.0' ('d'*64))
        $before = $custom | ConvertTo-Json -Depth 20
        $blocked = New-WorkflowDependencyPlan -Template $template -Manifest $custom
        @($blocked.blocked).Count | Should -Be 1
        $blocked.blocked[0].component | Should -Be tool
        $continued = New-WorkflowDependencyPlan -Template $template -Manifest $custom -Selection @{decisions=@{tool='workflow'}}
        @($continued.blocked).Count | Should -Be 0
        $continued.manifest.dependencies.tool.sha256 | Should -Be ('a'*64)
        ($custom | ConvertTo-Json -Depth 20) | Should -Be $before
    }

    It 'retains the newer hotfix while the workflow has not caught up' {
        $template = New-SelectionTestTemplate
        $plan = New-WorkflowDependencyPlan -Template $template -Manifest $template -Selection @{hotfixes=@{incident=(New-SelectionTestHotfix)}}
        @($plan.blocked).Count | Should -Be 0
        $plan.manifest.dependencies.tool.version | Should -Be '1.1.0'
        $plan.manifest.hotfixes.incident.reason | Should -Be 'incident fix'
    }

    It 'retires an incorporated hotfix on an <relation> workflow build' -ForEach @(
        @{relation='equal';version='1.1.0';hash=('b'*64)},@{relation='newer';version='1.2.0';hash=('c'*64)}
    ) {
        $old = New-SelectionTestTemplate
        $applied = New-WorkflowDependencyPlan -Template $old -Manifest $old -Selection @{hotfixes=@{incident=(New-SelectionTestHotfix)}}
        $target = New-SelectionTestTemplate (New-SelectionTestPin $version $hash)
        $updated = New-WorkflowDependencyPlan -Template $target -InstalledTemplate $old -Manifest $applied.manifest
        @($updated.blocked).Count | Should -Be 0
        $updated.manifest.hotfixes.Count | Should -Be 0
        $updated.manifest.dependencies.tool.sha256 | Should -Be $hash
    }

    It 'removes an exception explicitly and does not misclassify it as a legacy custom pin' {
        $template = New-SelectionTestTemplate
        $applied = New-WorkflowDependencyPlan -Template $template -Manifest $template -Selection @{hotfixes=@{incident=(New-SelectionTestHotfix)}}
        $removed = New-WorkflowDependencyPlan -Template $template -Manifest $applied.manifest -Selection @{hotfixes=@{}}
        @($removed.blocked).Count | Should -Be 0
        $removed.manifest.dependencies.tool.version | Should -Be '1.0.0'
        $removed.manifest.hotfixes.Count | Should -Be 0
    }

    It 'does not retire same-version different bytes without a decision' {
        $template = New-SelectionTestTemplate
        $selection = @{hotfixes=@{incident=(New-SelectionTestHotfix (New-SelectionTestPin '1.0.0' ('b'*64)))}}
        $plan = New-WorkflowDependencyPlan -Template $template -Manifest $template -Selection $selection
        @($plan.blocked).Count | Should -Be 1
        $selection['decisions']=@{incident='hotfix'}
        $continued = New-WorkflowDependencyPlan -Template $template -Manifest $template -Selection $selection
        @($continued.blocked).Count | Should -Be 0
        $continued.manifest.dependencies.tool.sha256 | Should -Be ('b'*64)
    }

    It 'recognizes the same immutable bytes after moving from a local transport to the published URL' {
        $published = New-SelectionTestPin '1.1.0' ('b'*64)
        $local = ConvertTo-Agent1cHashtable $published
        $local.url='file:///C:/Hotfix%20%D0%A2%D0%B5%D1%81%D1%82/tool.bin'
        Compare-WorkflowDependencyBuild $published $local | Should -Be equal
    }

    It 'orders downstream revisions but never orders unrelated repository lineages' {
        Compare-WorkflowDependencyBuild (New-SelectionTestPin '1.2.043.42' ('c'*64) 'itl-r4') (New-SelectionTestPin '1.2.043.42' ('b'*64) 'itl-r3') | Should -Be newer
        $other = New-SelectionTestPin '9.0.0' ('c'*64)
        $other.url='https://github.com/another/tool/releases/download/9.0.0/tool.bin'
        Compare-WorkflowDependencyBuild $other (New-SelectionTestPin) | Should -Be incomparable
    }

    It 'rejects overlapping exceptions and incomplete metadata before any lock write' {
        $template = New-SelectionTestTemplate
        $overlap = New-WorkflowDependencyPlan -Template $template -Manifest $template -Selection @{hotfixes=@{a=(New-SelectionTestHotfix);b=(New-SelectionTestHotfix)}}
        ($overlap.blocked.reason -join ' ') | Should -Match DEPENDENCY_HOTFIX_OVERLAP
        $incomplete = New-WorkflowDependencyPlan -Template $template -Manifest $template -Selection @{hotfixes=@{bad=@{dependencies=@{tool=(New-SelectionTestPin)}}}}
        ($incomplete.blocked.reason -join ' ') | Should -Match DEPENDENCY_HOTFIX_INCOMPLETE
    }

    It 'excludes observation metadata from build identity while retaining SDK identity' {
        $a = New-SelectionTestPin
        $b = ConvertTo-Agent1cHashtable $a
        $b['updatedAt']='later'
        $b['runtimeBindings']=@{path='C:\Ветка с пробелом\tool.bin'}
        Compare-WorkflowDependencyBuild $a $b | Should -Be equal
        $b['sdk']=@{version='1.0.0';integrity='different'}
        Compare-WorkflowDependencyBuild $a $b | Should -Be incomparable
    }

    It 'requires a decision for equal MCP bytes with a different catalog and accepts its qualified continuation' {
        $template = Get-Content (Join-Path $selectionRepo 'templates/dependency-lock.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $compatibility = Get-Content (Join-Path $selectionRepo '.agents/skills/1c-workflow/assets/ondemand-mcp/compatibility.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $definition = ConvertTo-Agent1cHashtable $compatibility.families.roctup
        $catalog = Get-Content (Join-Path $selectionRepo '.agents/skills/1c-workflow/assets/ondemand-mcp/catalogs/roctup-v1.7.1.json') -Raw -Encoding UTF8
        $catalog += "`n"
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $definition.catalogSha256=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($catalog.Replace("`r`n","`n"))))).Replace('-','').ToLowerInvariant() }
        finally { $sha.Dispose() }
        $fix=@{reason='catalog qualification';dependencies=@{roctupMcpToolkit=$template.dependencies.roctupMcpToolkit};compatibility=@{families=@{roctup=$definition}};catalogs=@{roctup=$catalog}}
        $selection=@{hotfixes=@{'incident.fix'=$fix}}
        $plan=New-WorkflowDependencyPlan -Template $template -Manifest $template -Selection $selection -Compatibility $compatibility
        @($plan.blocked).Count | Should -Be 1
        $plan.manifest.hotfixes.Contains('incident.fix') | Should -BeTrue
        $selection.decisions=@{'incident.fix'='hotfix'}
        $continued=New-WorkflowDependencyPlan -Template $template -Manifest $template -Selection $selection -Compatibility $compatibility
        @($continued.blocked).Count | Should -Be 0
        $selection.decisions['incident.fix']='workflow'
        $adopted=New-WorkflowDependencyPlan -Template $template -Manifest $template -Selection $selection -Compatibility $compatibility
        $adopted.manifest.hotfixes.Count | Should -Be 0
    }

    It 'rejects an incomplete Vanessa pair while keeping an unrelated component selectable' {
        $template=Get-Content (Join-Path $selectionRepo 'templates/dependency-lock.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $fix=@{reason='incomplete';dependencies=@{vanessaAutomation=$template.dependencies.vanessaAutomation}}
        $plan=New-WorkflowDependencyPlan -Template $template -Manifest $template -Selection @{hotfixes=@{incident=$fix}}
        ($plan.blocked.reason -join ' ') | Should -Match DEPENDENCY_HOTFIX_PAIR_REQUIRED
        $plan.manifest.dependencies.yaxunit.sha256 | Should -Be $template.dependencies.yaxunit.sha256
    }

    It 'admits exact OpenSpec resource bytes and rejects drift or conflicting package identity' {
        $template=Get-Content (Join-Path $selectionRepo 'templates/dependency-lock.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $resourceRoot=Join-Path $selectionRepo '.agents/skills/1c-workflow/resources/openspec-cli'
        $resource=@{packageJson=[IO.File]::ReadAllText((Join-Path $resourceRoot 'package.json'));packageLockJson=[IO.File]::ReadAllText((Join-Path $resourceRoot 'package-lock.json'))}
        {Assert-WorkflowOpenSpecResource -Entry $template.dependencies.openSpecCli -Resource $resource} | Should -Not -Throw
        $resource.packageJson='{"dependencies":{"@fission-ai/openspec":"99.0.0"}}'
        {Assert-WorkflowOpenSpecResource -Entry $template.dependencies.openSpecCli -Resource $resource} | Should -Throw '*RESOURCE_CONFLICT*'
        $resource.packageLockJson += ' '
        {Assert-WorkflowOpenSpecResource -Entry $template.dependencies.openSpecCli -Resource $resource} | Should -Throw '*RESOURCE_REQUIRED*'
    }
}

Describe 'Workflow dependency input boundaries' -Tag WorkflowDependencySelection {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context=Initialize-WorkflowPesterContext
        $inputHelper=$context.HelperPath
        $inputRepo=$context.RepoRoot
    }

    It 'round-trips Cyrillic and whitespace selection paths and reasons through the shared native process helper' {
        $root=Join-Path $TestDrive 'Проект с пробелом'
        New-Item -ItemType Directory -Force -Path (Join-Path $root '.agent-1c') | Out-Null
        $selectionPath=Join-Path $root 'Решение с пробелом.json'
        $pin=(Get-Content (Join-Path $inputRepo 'templates/dependency-lock.json') -Raw -Encoding UTF8 | ConvertFrom-Json).dependencies.yaxunit
        $pin.version='26.1'; $pin.releaseTag='26.1'; $pin.sha256=('b'*64)
        $selection=@{schemaVersion=1;worktrees=@(@{worktreePath=$root;hotfixes=@{'incident.fix'=@{reason='Исправление проверки';dependencies=@{yaxunit=$pin}}}})}
        [IO.File]::WriteAllText($selectionPath,($selection|ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false))
        & {
            . $inputHelper -ProjectRoot $root -Action help *> $null
            $stdout=Join-Path $root 'Вывод команды.txt'; $stderr=Join-Path $root 'Ошибка команды.txt'
            $result=Invoke-NativeProcessAndWaitResult -FilePath (Join-Path $PSHOME 'powershell.exe') -Arguments @('-NoProfile','-ExecutionPolicy','Bypass','-File',$inputHelper,'-ProjectRoot',$root,'-Action','status','-Mode','dependencies','-DependencySelectionFile',$selectionPath) -StdoutPath $stdout -StderrPath $stderr -TimeoutSeconds 60
            $result.exitCode | Should -Be 0
            $rows=Read-Utf8Text -Path $stdout | ConvertFrom-Json
            $row=@($rows | Where-Object component -EQ yaxunit)[0]
            $row.selected.version | Should -Be '26.1'
            $row.reason | Should -BeExactly 'Исправление проверки'
            $row.hotfix | Should -BeTrue
        }
    }

    It 'rejects unknown and duplicate scope before writes and resolves only the requested root' {
        $root=Join-Path $TestDrive 'Scope project'
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        & {
            . $inputHelper -ProjectRoot $root -Action help *> $null
            $DependencySelectionFile=Join-Path $root 'selection.json'
            $doc=@{schemaVersion=1;worktrees=@(@{worktreePath=$root;decisions=@{yaxunit='workflow'}})}
            Write-Utf8Text -Path $DependencySelectionFile -Value ($doc|ConvertTo-Json -Depth 10)
            {Assert-WorkflowDependencySelectionScopes -Roots @($root)} | Should -Not -Throw
            (Get-WorkflowDependencySelectionInput -Root ($root+' other')) | Should -BeNullOrEmpty
            $doc.worktrees += $doc.worktrees[0]
            Write-Utf8Text -Path $DependencySelectionFile -Value ($doc|ConvertTo-Json -Depth 10)
            {Assert-WorkflowDependencySelectionScopes -Roots @($root)} | Should -Throw '*SCOPE_AMBIGUOUS*'
            $doc.worktrees=@(@{worktreePath=($root+' other')})
            Write-Utf8Text -Path $DependencySelectionFile -Value ($doc|ConvertTo-Json -Depth 10)
            {Assert-WorkflowDependencySelectionScopes -Roots @($root)} | Should -Throw '*SCOPE_UNKNOWN*'
            Test-Path -LiteralPath (Join-Path $root '.agent-1c/dependency-lock.json') | Should -BeFalse
        }
    }

    It 'blocks only the incomplete MCP family and continues it after the selection is repaired' {
        $root=Join-Path $TestDrive 'MCP selection project'
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        & {
            . $inputHelper -ProjectRoot $root -Action help *> $null
            $DependencySelectionFile=Join-Path $root 'selection.json'
            $baseline=New-DefaultDependencyLockManifest
            $scope=@{worktreePath=$root;hotfixes=@{yaxunit=@{reason='incomplete pair';dependencies=@{vanessaAutomation=$baseline.dependencies.vanessaAutomation}}}}
            Write-Utf8Text -Path $DependencySelectionFile -Value (@{schemaVersion=1;worktrees=@($scope)}|ConvertTo-Json -Depth 30)
            {Get-WorkflowDependencyEntry -Name yaxunit} | Should -Not -Throw
            {Get-WorkflowDependencyEntry -Name vanessaAutomation} | Should -Throw '*DEPENDENCY_SELECTION_REQUIRED*'
            $scope.hotfixes=@{}
            Write-Utf8Text -Path $DependencySelectionFile -Value (@{schemaVersion=1;worktrees=@($scope)}|ConvertTo-Json -Depth 30)
            (Get-WorkflowDependencyEntry -Name vanessaAutomation).sha256 | Should -Be $baseline.dependencies.vanessaAutomation.sha256
            $scope.hotfixes=@{incident=@{reason='wrong resource owner';dependencies=@{yaxunit=$baseline.dependencies.yaxunit};resources=@{openSpecCli=@{packageJson='wrong';packageLockJson='wrong'}}}}
            Write-Utf8Text -Path $DependencySelectionFile -Value (@{schemaVersion=1;worktrees=@($scope)}|ConvertTo-Json -Depth 30)
            {Get-ItlOpenSpecCliPin} | Should -Not -Throw
            {Get-WorkflowDependencyEntry -Name yaxunit} | Should -Throw '*DEPENDENCY_SELECTION_REQUIRED*'
            $scope.hotfixes=@{}
            Write-Utf8Text -Path $DependencySelectionFile -Value (@{schemaVersion=1;worktrees=@($scope)}|ConvertTo-Json -Depth 30)
            (Get-WorkflowDependencyEntry -Name yaxunit).version | Should -Be $baseline.dependencies.yaxunit.version
            Test-Path -LiteralPath (Join-Path $root '.agent-1c/dependency-lock.json') | Should -BeFalse
        }
    }
}
