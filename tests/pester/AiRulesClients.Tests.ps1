Describe "1C workflow ai_rules_1c client checks" {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        $RepoRoot = $context.RepoRoot
        $HelperPath = $context.HelperPath
    }

    It "migrates only the legacy dual client and rejects other multi-client inputs" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-ai-rules-targets-" + [guid]::NewGuid().ToString("N"))
        $savedAgentTools = [Environment]::GetEnvironmentVariable("AGENT_TOOLS", "Process")

        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"aiRules":{"tools":["codex","kilocode"]}}'

            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $fromConfig = @(Get-AiRules1cTools)
                $multiError = ""
                [Environment]::SetEnvironmentVariable("AGENT_TOOLS", "cursor,kilo", "Process")
                try { Get-AiRules1cTools | Out-Null } catch { $multiError = $_.Exception.Message }
                [Environment]::SetEnvironmentVariable("AGENT_TOOLS", $null, "Process")
                $AgentTarget = "claude-code"
                $fromExplicit = @(Get-AiRules1cTools)
                [pscustomobject]@{
                    fromConfig = $fromConfig
                    multiError = $multiError
                    fromExplicit = $fromExplicit
                }
            }

            @($result.fromConfig) | Should -Be @("kilocode")
            $result.multiError | Should -Match "Multiple active agent clients are not supported"
            @($result.fromExplicit) | Should -Be @("claude-code")
        } finally {
            [Environment]::SetEnvironmentVariable("AGENT_TOOLS", $savedAgentTools, "Process")
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "resolves ai_rules skills through every active client adapter" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-ai-rules-skill-roots-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"aiRules":{"tools":["codex"]}}'

            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $records = @()
                foreach ($client in @(Get-SupportedAgentTargets)) {
                    $AgentTarget = $client
                    Set-Content -LiteralPath (Join-Path $tempRoot ".ai-rules.json") -Encoding UTF8 -Value (([ordered]@{ tools = @($client); files = [ordered]@{} } | ConvertTo-Json -Depth 4) + [Environment]::NewLine)
                    $adapter = Get-ItlClientAdapter -Client $client
                    $expectedSkillRoot = Join-Path (Join-Path $tempRoot ([string]$adapter.skillsPath)) "1c-metadata-manage"
                    $toolRoot = Join-Path $expectedSkillRoot "tools\1c-cfe-manage\scripts"
                    New-Item -ItemType Directory -Force -Path $toolRoot | Out-Null
                    Set-Content -LiteralPath (Join-Path $toolRoot "cfe-init.ps1") -Encoding ASCII -Value "# fixture"
                    Set-Content -LiteralPath (Join-Path $toolRoot "cfe-validate.ps1") -Encoding ASCII -Value "# fixture"

                    $resolvedSkillRoot = Get-AiRules1cInstalledSkillRoot -SkillName "1c-metadata-manage"
                    $resolvedTools = Get-ExtensionLifecycleToolPaths
                    $records += [pscustomobject]@{
                        client = $client
                        expectedSkillRoot = [System.IO.Path]::GetFullPath($expectedSkillRoot)
                        resolvedSkillRoot = [System.IO.Path]::GetFullPath($resolvedSkillRoot)
                        init = [System.IO.Path]::GetFullPath([string]$resolvedTools.init)
                        validate = [System.IO.Path]::GetFullPath([string]$resolvedTools.validate)
                    }
                }

                $AgentTarget = "kilocode"
                Set-Content -LiteralPath (Join-Path $tempRoot ".ai-rules.json") -Encoding UTF8 -Value '{"tools":["kilocode"],"files":{}}'
                $kiloInit = Join-Path $tempRoot ".kilo\skills\1c-metadata-manage\tools\1c-cfe-manage\scripts\cfe-init.ps1"
                Remove-Item -LiteralPath $kiloInit -Force
                $missingError = ""
                try { Get-ExtensionLifecycleToolPaths | Out-Null } catch { $missingError = $_.Exception.Message }

                [pscustomobject]@{ records = $records; missingError = $missingError }
            }

            @($result.records).Count | Should -Be 10
            foreach ($record in @($result.records)) {
                $record.resolvedSkillRoot | Should -Be $record.expectedSkillRoot
                $record.init | Should -Be (Join-Path $record.expectedSkillRoot "tools\1c-cfe-manage\scripts\cfe-init.ps1")
                $record.validate | Should -Be (Join-Path $record.expectedSkillRoot "tools\1c-cfe-manage\scripts\cfe-validate.ps1")
            }
            $result.missingError | Should -Match "active ai_rules_1c client 'kilocode'"
            $result.missingError | Should -Match "Checked: .*cfe-init\.ps1 and .*cfe-validate\.ps1"
            $result.missingError | Should -Match "Missing: .*\.kilo.*cfe-init\.ps1"
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "keeps hardcoded shared skill paths limited to workflow-owned skills" {
        $allowed = @("1c-workflow", "1c-workflow-fast", "product-docs", "itl-roctup-1c-data", "itl-vanessa-ui-mcp")
        $violations = @()
        $scriptsRoot = Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts"
        foreach ($file in @(Get-ChildItem -LiteralPath $scriptsRoot -Recurse -File -Filter "*.ps1")) {
            $text = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
            foreach ($match in [regex]::Matches($text, '(?i)\.agents[\\/]+skills[\\/]+(?<skill>[a-z0-9][a-z0-9-]*)')) {
                $skill = [string]$match.Groups["skill"].Value
                if ($skill -notin $allowed) {
                    $relative = $file.FullName.Substring($RepoRoot.Length + 1)
                    $violations += "${relative}:$skill"
                }
            }
        }
        @($violations).Count | Should -Be 0 -Because ($violations -join ", ")
    }

    It "replaces a legacy client set instead of adding another client" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-ai-rules-add-" + [guid]::NewGuid().ToString("N"))
        $projectRoot = Join-Path $tempRoot "project"
        $rulesRoot = Join-Path $tempRoot "ai_rules_1c"

        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $projectRoot ".agent-1c"), (Join-Path $rulesRoot "adapters") | Out-Null
            Set-Content -LiteralPath (Join-Path $projectRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"aiRules":{"tools":["codex","kilocode"]}}'
            Set-Content -LiteralPath (Join-Path $projectRoot ".ai-rules.json") -Encoding UTF8 -Value '{"tools":["codex"],"files":{}}'
            Set-Content -LiteralPath (Join-Path $rulesRoot "adapters\codex.yaml") -Encoding ASCII -Value "tool: codex"
            Set-Content -LiteralPath (Join-Path $rulesRoot "adapters\kilocode.yaml") -Encoding ASCII -Value "tool: kilocode"
            Set-Content -LiteralPath (Join-Path $rulesRoot "install.ps1") -Encoding UTF8 -Value @'
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command,
    [string]$Tool,
    [string[]]$Tools,
    [string]$ProjectRoot,
    [string]$Source,
    [ValidateSet("delegated")]
    [string]$McpMode,
    [switch]$AssumeYes,
    [switch]$Force
)

$manifestPath = Join-Path $ProjectRoot ".ai-rules.json"
$currentTools = @()
if (Test-Path -LiteralPath $manifestPath) {
    $currentTools = @((Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json).tools)
}
switch ($Command) {
    "init" { $currentTools = @($Tools) }
    "remove" { $currentTools = @() }
}
$manifest = [ordered]@{
    tools = @($currentTools | Where-Object { $_ } | Select-Object -Unique)
    files = [ordered]@{}
}
Set-Content -LiteralPath $manifestPath -Encoding UTF8 -Value (($manifest | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
Add-Content -LiteralPath (Join-Path $ProjectRoot "installer-calls.txt") -Encoding ASCII -Value "$Command|$Tool|$($Tools -join ',')|$McpMode"
'@

            $result = & {
                . $HelperPath -ProjectRoot $projectRoot -Action help *> $null
                function Sync-AiRules1cCheckout {
                    return [pscustomobject]@{ root = $rulesRoot; repo = "fixture"; ref = "fixture" }
                }
                function Get-GitOutputAt {
                    return "fixture-commit"
                }

                Invoke-AiRules1cInstaller -Command "update"
                $unknownError = ""
                $AgentTarget = "missing-client"
                try {
                    Invoke-AiRules1cInstaller -Command "update"
                } catch {
                    $unknownError = $_.Exception.Message
                }
                [pscustomobject]@{
                    calls = @(Get-Content -LiteralPath (Join-Path $projectRoot "installer-calls.txt"))
                    tools = @(Get-AiRules1cManifestToolNames)
                    unknownError = $unknownError
                }
            }

            @($result.calls) | Should -Be @("remove|||delegated", "init||kilocode|delegated")
            @($result.tools) | Should -Be @("kilocode")
            $result.unknownError | Should -Match "Unsupported agent client"
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "generates only ITL Kilo wrappers after Kilo is installed" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-kilo-surface-" + [guid]::NewGuid().ToString("N"))

        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"masterBranch":"master","aiRules":{"tools":["kilocode"]}}'
            & git -C $tempRoot init *> $null
            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                Sync-KiloItlCommandSurface -SourceRoot $RepoRoot
                (Test-Path -LiteralPath (Join-Path $tempRoot ".kilo\commands") -PathType Container) | Should -BeFalse

                Set-Content -LiteralPath (Join-Path $tempRoot ".ai-rules.json") -Encoding UTF8 -Value '{"tools":["kilocode"],"files":{}}'
                Sync-KiloItlCommandSurface -SourceRoot $RepoRoot
                Set-Content -LiteralPath (Join-Path $tempRoot ".kilo\commands\custom.md") -Encoding UTF8 -Value "custom"
                Sync-KiloItlCommandSurface -SourceRoot $RepoRoot
            }

            (Test-Path -LiteralPath (Join-Path $tempRoot ".kilo\commands\itl.md") -PathType Leaf) | Should -BeTrue
            (Test-Path -LiteralPath (Join-Path $tempRoot ".kilo\commands\itl-status.md") -PathType Leaf) | Should -BeTrue
            (Test-Path -LiteralPath (Join-Path $tempRoot ".kilo\commands\custom.md") -PathType Leaf) | Should -BeTrue
            $masterKiloCommands = @(Get-ChildItem -LiteralPath (Join-Path $tempRoot ".kilo\commands") -File -Filter "itl*.md" | Select-Object -ExpandProperty Name | Sort-Object)
            $masterKiloCommands | Should -Be @("itl.md", "itl-litemode.md", "itl-new-config-branch.md", "itl-new-extension-branch.md", "itl-status.md", "itl-switch-client.md", "itl-update-workflow.md")
            $masterKiloCommands | Should -Not -Contain "itl-check.md"
            $masterKiloCommands | Should -Not -Contain "itl-verify-fix.md"
            $masterKiloCommands | Should -Not -Contain "itl-refresh.md"
            $masterKiloCommands | Should -Not -Contain "itl-result.md"
            $kiloConfig = Get-Content -LiteralPath (Join-Path $tempRoot ".kilo\kilo.json") -Raw -Encoding UTF8 | ConvertFrom-Json
            $kiloConfig.snapshot | Should -BeFalse
            (Test-Path -LiteralPath (Join-Path $tempRoot ".kilo\agents\itl-routine.md") -PathType Leaf) | Should -BeFalse
            (Test-Path -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\kilo-plugin\itl-completion-gate.js") -ErrorAction SilentlyContinue) | Should -BeFalse
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "keeps the fresh upstream compatibility check outside the offline Pester suite" {
        $scriptPath = Join-Path $RepoRoot "scripts\test-ai-rules-compatibility.ps1"
        $text = Get-Content -LiteralPath $scriptPath -Raw -Encoding UTF8

        (Test-Path -LiteralPath $scriptPath -PathType Leaf) | Should -BeTrue
        $text | Should -Match "codex.*kilocode.*claude-code.*cursor.*opencode.*kimi.*qwen.*command-code.*cline.*pi"
        $text | Should -Match "Assert-OpenSpecBundle"
        $text | Should -Match "git clone"
        $text | Should -Match "protocol must be 1.1"
        $text | Should -Match "Compatibility check changed user-scope Codex prompt"
        $text | Should -Match 'docs/custom\.md,USER-RULES\.md'
        $text | Should -Match 'McpMode delegated'
        $text | Should -Match 'Repeated ai_rules update was not byte-idempotent'
        $text | Should -Match 'Exact-one-client manifest failed'
        $text | Should -Match 'templates\\dependency-lock\.json'
        $text | Should -Match 'Assert-WorkflowExtensionTools'
    }

    It "validates shared OpenSpec destinations independently of the winning source owner" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-ai-rules-shared-openspec-" + [guid]::NewGuid().ToString("N"))
        $rulesRoot = Join-Path $tempRoot "rules"
        try {
            New-Item -ItemType Directory -Force -Path `
                (Join-Path $tempRoot ".agent-1c"), `
                (Join-Path $rulesRoot "content\openspec-bundle\codex\.agents\skills\openspec-propose"), `
                (Join-Path $rulesRoot "content\openspec-bundle\kilocode\.agents\skills\openspec-propose"), `
                (Join-Path $rulesRoot "content\openspec-bundle\kilocode\.kilo\commands"), `
                (Join-Path $tempRoot ".agents\skills\openspec-propose"), `
                (Join-Path $tempRoot ".kilo\commands") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"aiRules":{"tools":["codex","kilocode"]}}'
            foreach ($path in @(
                (Join-Path $rulesRoot "content\openspec-bundle\codex\.agents\skills\openspec-propose\SKILL.md"),
                (Join-Path $rulesRoot "content\openspec-bundle\kilocode\.agents\skills\openspec-propose\SKILL.md"),
                (Join-Path $tempRoot ".agents\skills\openspec-propose\SKILL.md")
            )) { Set-Content -LiteralPath $path -Encoding ASCII -Value "fixture" }
            Set-Content -LiteralPath (Join-Path $rulesRoot "content\openspec-bundle\kilocode\.kilo\commands\opsx-propose.md") -Encoding ASCII -Value "fixture"
            Set-Content -LiteralPath (Join-Path $tempRoot ".kilo\commands\opsx-propose.md") -Encoding ASCII -Value "fixture"
            $manifest = [pscustomobject]@{ files = [pscustomobject]@{
                ".agents/skills/openspec-propose/SKILL.md" = [pscustomobject]@{ source = "content/openspec-bundle/kilocode/.agents/skills/openspec-propose/SKILL.md" }
                ".kilo/commands/opsx-propose.md" = [pscustomobject]@{ source = "content/openspec-bundle/kilocode/.kilo/commands/opsx-propose.md" }
            } }
            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                [pscustomobject]@{
                    codex = Get-AiRules1cOpenSpecBundleValidation -RulesDir $rulesRoot -Tool "codex" -Manifest $manifest
                    kilo = Get-AiRules1cOpenSpecBundleValidation -RulesDir $rulesRoot -Tool "kilocode" -Manifest $manifest
                }
            }
            $result.codex.isValid | Should -BeTrue
            $result.kilo.isValid | Should -BeTrue
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "pins a configured aiRules tag in fresh mode" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-ai-rules-pin-" + [guid]::NewGuid().ToString("N"))
        $projectRoot = Join-Path $tempRoot "project"
        $sourceRoot = Join-Path $tempRoot "source"
        $cacheRoot = Join-Path $tempRoot "cache"
        $savedTemp = $env:TEMP
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $projectRoot ".agent-1c"), $sourceRoot, $cacheRoot | Out-Null
            & git -C $sourceRoot init *> $null
            & git -C $sourceRoot config user.email "test@example.invalid"
            & git -C $sourceRoot config user.name "ITL Test"
            Set-Content -LiteralPath (Join-Path $sourceRoot "README.md") -Encoding ASCII -Value "tagged"
            & git -C $sourceRoot add .
            & git -C $sourceRoot commit -m "tagged" *> $null
            & git -C $sourceRoot tag "v1.0.0"
            $tagCommit = (& git -C $sourceRoot rev-parse "v1.0.0^{commit}").Trim()

            $config = [ordered]@{
                dependencyMode = "fresh"
                aiRules = [ordered]@{ repo = $sourceRoot; ref = "v1.0.0"; tools = @("kilocode") }
            }
            Set-Content -LiteralPath (Join-Path $projectRoot ".agent-1c\project.json") -Encoding UTF8 -Value ($config | ConvertTo-Json -Depth 6)
            Set-Content -LiteralPath (Join-Path $projectRoot ".agent-1c\dependency-lock.json") -Encoding UTF8 -Value '{"schemaVersion":1,"mode":"fresh","dependencies":{}}'
            $env:TEMP = $cacheRoot

            $first = & {
                . $HelperPath -ProjectRoot $projectRoot -Action help *> $null
                Sync-AiRules1cCheckout
            }
            $first.ref | Should -Be "v1.0.0"
            $first.commit | Should -Be $tagCommit

            Set-Content -LiteralPath (Join-Path $sourceRoot "README.md") -Encoding ASCII -Value "new main"
            & git -C $sourceRoot add .
            & git -C $sourceRoot commit -m "new main" *> $null
            $second = & {
                . $HelperPath -ProjectRoot $projectRoot -Action help *> $null
                Sync-AiRules1cCheckout
            }
            $second.commit | Should -Be $tagCommit
            $second.commit | Should -Not -Be (& git -C $sourceRoot rev-parse HEAD).Trim()
        } finally {
            $env:TEMP = $savedTemp
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "rejects controlled fork main when aiRules.ref is absent" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-ai-rules-fork-main-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"dependencyMode":"fresh","aiRules":{"repo":"https://github.com/xmentosx/itl_ai_rules_1c.git","tools":["kilocode"]}}'
            $script:pinError = ""
            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                try { Sync-AiRules1cCheckout | Out-Null } catch { $script:pinError = $_.Exception.Message }
            }
            $script:pinError | Should -Match "requires an immutable configured tag"
        } finally {
            Remove-Variable -Name pinError -Scope Script -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
