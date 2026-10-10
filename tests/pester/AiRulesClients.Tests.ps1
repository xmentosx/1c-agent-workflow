Describe "1C workflow ai_rules_1c client checks" {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        $RepoRoot = $context.RepoRoot
        $HelperPath = $context.HelperPath
    }

    It "offers the executing client first as recommended and selects it when the wizard answer is skipped" {
        $results = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            foreach ($defaultClient in @(Get-SupportedAgentTargets)) {
                $capture = [pscustomobject]@{
                    lines = [System.Collections.Generic.List[string]]::new()
                    prompt = ""
                }
                function Write-Host {
                    param([Parameter(Position = 0)]$Object)
                    [void]$capture.lines.Add([string]$Object)
                }
                function Read-Host {
                    param([Parameter(Position = 0)]$Prompt)
                    $capture.prompt = [string]$Prompt
                    return ""
                }

                [pscustomobject]@{
                    defaultClient = $defaultClient
                    selected = Read-InitAgentTarget -DefaultClient $defaultClient
                    choices = @(Get-InitAgentTargetChoices -DefaultClient $defaultClient)
                    supportedCount = @(Get-SupportedAgentTargets).Count
                    lines = @($capture.lines)
                    prompt = $capture.prompt
                }
            }
        }

        @($results).Count | Should -Be 12
        foreach ($result in @($results)) {
            $result.selected | Should -Be $result.defaultClient
            @($result.choices)[0] | Should -Be $result.defaultClient
            @($result.choices | Select-Object -Unique).Count | Should -Be $result.supportedCount
            @($result.lines) | Should -Contain "1. $($result.defaultClient) (recommended)"
            $result.prompt | Should -Match ("\[" + [regex]::Escape($result.defaultClient) + "\]$")
        }
    }

    It "detects supported agent runtimes from inherited markers and the process chain" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $environmentCases = [ordered]@{
                codex = @{ CODEX_THREAD_ID = "thread-test" }
                "claude-code" = @{ CLAUDECODE = "1" }
                kilocode = @{ KILOCODE_FEATURE = "vscode-extension" }
                cursor = @{ CURSOR_TRACE_ID = "trace-test" }
            }
            $processCases = [ordered]@{
                codex = "codex.exe"
                "claude-code" = "claude.exe"
                kilocode = "kilo.exe"
                cursor = "Cursor.exe"
                opencode = "opencode.exe"
                kimi = "kimi.exe"
                qwen = "qwen.exe"
                "command-code" = "command-code.exe"
                cline = "cline.exe"
                zcode = "zcode.exe"
                mimocode = "mimocode.exe"
                pi = "pi.exe"
            }
            [pscustomobject]@{
                environment = @($environmentCases.Keys | ForEach-Object {
                    [pscustomobject]@{
                        expected = $_
                        actual = Resolve-InitAgentTargetFromExecutionContext -Environment $environmentCases[$_] -ProcessChain @()
                    }
                })
                process = @($processCases.Keys | ForEach-Object {
                    [pscustomobject]@{
                        expected = $_
                        actual = Resolve-InitAgentTargetFromExecutionContext -Environment @{} -ProcessChain @([pscustomobject]@{ name = $processCases[$_]; executablePath = ""; commandLine = "" })
                    }
                })
                nested = Resolve-InitAgentTargetFromExecutionContext `
                    -Environment @{ CLAUDECODE = "1" } `
                    -ProcessChain @([pscustomobject]@{ name = "Cursor.exe"; executablePath = ""; commandLine = "" })
                nestedProcess = Resolve-InitAgentTargetFromExecutionContext `
                    -Environment @{} `
                    -ProcessChain @(
                        [pscustomobject]@{ name = "opencode.exe"; executablePath = ""; commandLine = "" },
                        [pscustomobject]@{ name = "Cursor.exe"; executablePath = ""; commandLine = "" }
                    )
                unknown = Resolve-InitAgentTargetFromExecutionContext -Environment @{} -ProcessChain @()
            }
        }

        foreach ($case in @($result.environment) + @($result.process)) {
            $case.actual | Should -Be $case.expected
        }
        $result.nested | Should -Be "claude-code"
        $result.nestedProcess | Should -Be "opencode"
        $result.unknown | Should -Be ""
    }

    It "preserves the configured client set while selecting a session client" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-ai-rules-targets-" + [guid]::NewGuid().ToString("N"))
        $savedAgentTools = [Environment]::GetEnvironmentVariable("AGENT_TOOLS", "Process")

        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"aiRules":{"tools":["codex","kilocode"]}}'

            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $fromConfig = @(Get-AiRules1cTools)
                [Environment]::SetEnvironmentVariable("AGENT_TOOLS", "cursor,kilo", "Process")
                $fromEnvironment = @(Get-AiRules1cTools)
                [Environment]::SetEnvironmentVariable("AGENT_TOOLS", $null, "Process")
                $AgentTarget = "claude-code"
                $fromExplicit = @(Get-AiRules1cTools)
                $missingSession = ""
                try { Get-ItlActiveClient -Client 'claude-code' | Out-Null } catch { $missingSession = $_.Exception.Message }
                [pscustomobject]@{
                    fromConfig = $fromConfig
                    fromEnvironment = $fromEnvironment
                    fromExplicit = $fromExplicit
                    missingSession = $missingSession
                }
            }

            @($result.fromConfig) | Should -Be @("codex", "kilocode")
            @($result.fromEnvironment) | Should -Be @("codex", "kilocode")
            @($result.fromExplicit) | Should -Be @("codex", "kilocode")
            $result.missingSession | Should -Match "ITL_CLIENT_NOT_ATTACHED"
        } finally {
            [Environment]::SetEnvironmentVariable("AGENT_TOOLS", $savedAgentTools, "Process")
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "selects an explicitly attached session client and rejects an absent one" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-ai-rules-session-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot '.agent-1c') | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot '.agent-1c\project.json') -Encoding UTF8 -Value '{"aiRules":{"tools":["codex","cursor"]}}'
            Set-Content -LiteralPath (Join-Path $tempRoot '.ai-rules.json') -Encoding UTF8 -Value '{"tools":["cursor","codex"],"files":{}}'
            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $selected = Get-ItlActiveClient -Client 'cursor'
                $missing = ''
                try { Get-ItlActiveClient -Client 'kilocode' | Out-Null } catch { $missing = $_.Exception.Message }
                [pscustomobject]@{ selected = $selected; missing = $missing }
            }
            $result.selected | Should -Be 'cursor'
            $result.missing | Should -Match 'ITL_CLIENT_NOT_ATTACHED'
        } finally {
            if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
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
                    Set-ProjectAiRulesClient -Client $client
                    Read-ProjectConfig | Out-Null
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
                Set-ProjectAiRulesClient -Client "kilocode"
                Read-ProjectConfig | Out-Null
                Set-Content -LiteralPath (Join-Path $tempRoot ".ai-rules.json") -Encoding UTF8 -Value '{"tools":["kilocode"],"files":{}}'
                $kiloInit = Join-Path $tempRoot ".kilo\skills\1c-metadata-manage\tools\1c-cfe-manage\scripts\cfe-init.ps1"
                Remove-Item -LiteralPath $kiloInit -Force
                $missingError = ""
                try { Get-ExtensionLifecycleToolPaths | Out-Null } catch { $missingError = $_.Exception.Message }

                [pscustomobject]@{ records = $records; missingError = $missingError }
            }

            @($result.records).Count | Should -Be 12
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
        $allowed = @(
            "1c-workflow",
            "1c-workflow-fast",
            "product-docs",
            "itl-roctup-1c-data",
            "itl-vanessa-ui-mcp",
            "itl-remote-runner",
            "itl-remote-agent",
            "itl-performance",
            "itl",
            "itl-litemode",
            "itl-status",
            "itl-new-config-branch",
            "itl-new-extension-branch",
            "itl-switch-client",
            "itl-update-workflow",
            "itl-check",
            "itl-sync-master",
            "itl-refresh",
            "itl-refresh-lite",
            "itl-refresh-all",
            "itl-reset-branch",
            "itl-lock-objects",
            "itl-result",
            "itl-verify-fix"
        )
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

    It "adds a configured client without removing the installed client" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-ai-rules-add-" + [guid]::NewGuid().ToString("N"))
        $projectRoot = Join-Path $tempRoot "project"
        $rulesRoot = Join-Path $tempRoot "ai_rules_1c"

        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $projectRoot ".agent-1c"), (Join-Path $rulesRoot "adapters") | Out-Null
            Set-Content -LiteralPath (Join-Path $projectRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"aiRules":{"tools":["codex","kilocode"]}}'
            Set-Content -LiteralPath (Join-Path $projectRoot ".ai-rules.json") -Encoding UTF8 -Value '{"tools":["codex"],"files":{}}'
            Set-Content -LiteralPath (Join-Path $rulesRoot "adapters\codex.yaml") -Encoding ASCII -Value "tool: codex"
            Set-Content -LiteralPath (Join-Path $rulesRoot "adapters\kilocode.yaml") -Encoding ASCII -Value "tool: kilocode"
            foreach ($skillName in @("grill-me", "grill-with-docs")) {
                foreach ($clientSkillRoot in @(".kilo\skills", ".agents\skills")) {
                    $skillRoot = Join-Path $projectRoot "$clientSkillRoot\$skillName"
                    New-Item -ItemType Directory -Force -Path $skillRoot | Out-Null
                    Set-Content -LiteralPath (Join-Path $skillRoot "SKILL.md") -Encoding UTF8 -Value "# $skillName"
                    if ($clientSkillRoot -eq '.agents\skills') {
                        New-Item -ItemType Directory -Force -Path (Join-Path $skillRoot 'agents') | Out-Null
                        Set-Content -LiteralPath (Join-Path $skillRoot 'agents\openai.yaml') -Encoding UTF8 -Value "interface:`n  display_name: `"$skillName`""
                    }
                }
            }
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
    "add" { $currentTools = @($currentTools) + $Tool }
    "remove" { $currentTools = @($currentTools | Where-Object { $_ -ne $Tool }) }
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
                [pscustomobject]@{
                    calls = @(Get-Content -LiteralPath (Join-Path $projectRoot "installer-calls.txt"))
                    tools = @(Get-AiRules1cManifestToolNames)
                }
            }

            @($result.calls) | Should -Be @("add|kilocode||delegated", "update|||delegated")
            @($result.tools) | Should -Be @("codex", "kilocode")
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
            $masterKiloCommands | Should -Be @(@("itl.md", "itl-clean.md", "itl-delete-branch.md", "itl-litemode.md", "itl-new-config-branch.md", "itl-new-extension-branch.md", "itl-refresh-all.md", "itl-repository-mode.md", "itl-status.md", "itl-switch-client.md", "itl-sync-master.md", "itl-update-workflow.md") | Sort-Object)
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
        $text | Should -Match "codex.*kilocode.*claude-code.*cursor.*opencode.*kimi.*qwen.*command-code.*cline.*pi.*zcode.*mimocode"
        $text | Should -Match 'compatibility requires exact checkout HEAD'
        $text | Should -Match "Assert-OpenSpecBundle"
        $text | Should -Match "git clone"
        $text | Should -Match "protocol must be 1.1"
        $text | Should -Match "Compatibility check changed user-scope Codex prompt"
        $text | Should -Match 'docs/custom\.md.*Kilo shared config preservation failed'
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
        $savedSource = $env:ITL_AI_RULES_SOURCE_PATH
        try {
            Remove-Item Env:\ITL_AI_RULES_SOURCE_PATH -ErrorAction SilentlyContinue
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
            $env:ITL_AI_RULES_SOURCE_PATH = $savedSource
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "uses an explicit clean local controlled-fork checkout before its pending tag is remote" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-ai-rules-local-source-" + [guid]::NewGuid().ToString("N"))
        $projectRoot = Join-Path $tempRoot "project"
        $sourceRoot = Join-Path $tempRoot "source"
        $cacheRoot = Join-Path $tempRoot "cache"
        $savedTemp = $env:TEMP
        $savedSource = $env:ITL_AI_RULES_SOURCE_PATH
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $projectRoot ".agent-1c"), $sourceRoot, $cacheRoot | Out-Null
            & git -C $sourceRoot init *> $null
            & git -C $sourceRoot config user.email "test@example.invalid"
            & git -C $sourceRoot config user.name "ITL Test"
            Set-Content -LiteralPath (Join-Path $sourceRoot "README.md") -Encoding ASCII -Value "pending controlled fork"
            & git -C $sourceRoot add .
            & git -C $sourceRoot commit -m "candidate" *> $null
            & git -C $sourceRoot tag -a "itl-main-test-r1" -m "candidate"
            & git -C $sourceRoot remote add origin "https://github.com/xmentosx/itl_ai_rules_1c.git"
            $tagCommit = (& git -C $sourceRoot rev-parse "itl-main-test-r1^{commit}").Trim()

            $config = [ordered]@{
                dependencyMode = "fresh"
                aiRules = [ordered]@{ repo = "https://github.com/xmentosx/itl_ai_rules_1c.git"; ref = "itl-main-test-r1"; tools = @("kilocode") }
            }
            Set-Content -LiteralPath (Join-Path $projectRoot ".agent-1c\project.json") -Encoding UTF8 -Value ($config | ConvertTo-Json -Depth 6)
            Set-Content -LiteralPath (Join-Path $projectRoot ".agent-1c\dependency-lock.json") -Encoding UTF8 -Value '{"schemaVersion":1,"mode":"fresh","dependencies":{}}'
            $env:TEMP = $cacheRoot
            $env:ITL_AI_RULES_SOURCE_PATH = $sourceRoot

            $result = & {
                . $HelperPath -ProjectRoot $projectRoot -Action help *> $null
                Sync-AiRules1cCheckout
            }

            $result.ref | Should -Be "itl-main-test-r1"
            $result.commit | Should -Be $tagCommit
            (& git -C $result.root remote get-url origin).Trim() | Should -Be "https://github.com/xmentosx/itl_ai_rules_1c.git"
        } finally {
            $env:TEMP = $savedTemp
            $env:ITL_AI_RULES_SOURCE_PATH = $savedSource
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "isolates real project rule checkouts while another project holds its Git index lock and preserves same-root pins" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl правила cache " + [guid]::NewGuid().ToString("N"))
        $projectA = Join-Path $tempRoot "проект один"
        $projectB = Join-Path $tempRoot "проект два"
        $sourceRoot = Join-Path $tempRoot "source правила"
        $cacheRoot = Join-Path $tempRoot "cache правила"
        $savedTemp = $env:TEMP
        $savedSource = $env:ITL_AI_RULES_SOURCE_PATH
        $indexLock = $null
        $indexLockPath = ""
        try {
            Remove-Item Env:\ITL_AI_RULES_SOURCE_PATH -ErrorAction SilentlyContinue
            New-Item -ItemType Directory -Force -Path $sourceRoot, $cacheRoot | Out-Null
            & git -C $sourceRoot init *> $null
            & git -C $sourceRoot config user.email "test@example.invalid"
            & git -C $sourceRoot config user.name "ITL Test"
            Set-Content -LiteralPath (Join-Path $sourceRoot "README.md") -Encoding ASCII -Value "first pinned tag"
            & git -C $sourceRoot add .
            & git -C $sourceRoot commit -m "first tag" *> $null
            & git -C $sourceRoot tag "v1.0.0"
            $commitA = (& git -C $sourceRoot rev-parse HEAD).Trim()
            Set-Content -LiteralPath (Join-Path $sourceRoot "README.md") -Encoding ASCII -Value "second pinned tag"
            & git -C $sourceRoot add .
            & git -C $sourceRoot commit -m "second tag" *> $null
            & git -C $sourceRoot tag "v2.0.0"
            $commitB = (& git -C $sourceRoot rev-parse HEAD).Trim()
            foreach ($pair in @(@($projectA, "v1.0.0"), @($projectB, "v2.0.0"))) {
                New-Item -ItemType Directory -Force -Path (Join-Path $pair[0] ".agent-1c") | Out-Null
                & git -C $pair[0] init *> $null
                & git -C $pair[0] config user.email "test@example.invalid"
                & git -C $pair[0] config user.name "ITL Test"
                $config = [ordered]@{ dependencyMode="fresh"; aiRules=[ordered]@{ repo=$sourceRoot; ref=$pair[1]; tools=@("kilocode") } }
                Set-Content -LiteralPath (Join-Path $pair[0] ".agent-1c/project.json") -Encoding UTF8 -Value ($config | ConvertTo-Json -Depth 6)
                Set-Content -LiteralPath (Join-Path $pair[0] ".agent-1c/dependency-lock.json") -Encoding UTF8 -Value '{"schemaVersion":1,"mode":"fresh","dependencies":{}}'
                & git -C $pair[0] add .
                & git -C $pair[0] commit -m "owned project baseline" *> $null
            }
            $env:TEMP = $cacheRoot
            $first = & { . $HelperPath -ProjectRoot $projectA -Action help *> $null; Sync-AiRules1cCheckout }
            $first.commit | Should -Be $commitA
            $configHashA = (Get-FileHash -LiteralPath (Join-Path $first.root ".git/config") -Algorithm SHA256).Hash
            $reuseMarker = Join-Path $first.root ".git/owned-reuse-marker"
            [IO.File]::WriteAllText($reuseMarker, "exact existing checkout owner", [Text.UTF8Encoding]::new($false))
            $sharedRoot = Join-Path $cacheRoot "ai_rules_1c"
            New-Item -ItemType Directory -Force -Path $sharedRoot | Out-Null
            $sharedSentinel = Join-Path $sharedRoot "old-shared-owner"
            [IO.File]::WriteAllText($sharedSentinel, "old shared cache stays untouched", [Text.UTF8Encoding]::new($false))
            $sharedSentinelHash = (Get-FileHash -LiteralPath $sharedSentinel -Algorithm SHA256).Hash
            $indexLockPath = Join-Path $first.root ".git/index.lock"
            $indexLock = [IO.File]::Open($indexLockPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            $lockBytes = [Text.Encoding]::UTF8.GetBytes("active first-project Git owner")
            $indexLock.Write($lockBytes, 0, $lockBytes.Length)
            $indexLock.Flush()
            $second = & { . $HelperPath -ProjectRoot $projectB -Action help *> $null; Sync-AiRules1cCheckout }
            $second.root | Should -Not -Be $first.root
            $second.commit | Should -Be $commitB
            (& git -C $first.root rev-parse HEAD).Trim() | Should -Be $commitA
            (Get-FileHash -LiteralPath (Join-Path $first.root ".git/config") -Algorithm SHA256).Hash | Should -Be $configHashA
            $indexLock.Length | Should -Be $lockBytes.Length
            (Get-FileHash -LiteralPath $sharedSentinel -Algorithm SHA256).Hash | Should -Be $sharedSentinelHash
            (& git -C $first.root config --local --get core.longpaths).Trim() | Should -Be "true"
            (& git -C $second.root config --local --get core.longpaths).Trim() | Should -Be "true"
            $indexLock.Dispose(); $indexLock = $null
            Remove-Item -LiteralPath $indexLockPath -Force
            $sameRoot = & { . $HelperPath -ProjectRoot ($projectA.ToUpperInvariant() + "\") -Action help *> $null; Sync-AiRules1cCheckout }
            $sameRoot.root | Should -Be $first.root
            $sameRoot.commit | Should -Be $commitA
            [IO.File]::ReadAllText($reuseMarker) | Should -Be "exact existing checkout owner"
            $badLock = [ordered]@{ schemaVersion=1; mode="fresh"; dependencies=[ordered]@{ aiRules1c=[ordered]@{ repo=$sourceRoot; ref="v1.0.0"; commit=$commitB } } }
            Set-Content -LiteralPath (Join-Path $projectA ".agent-1c/dependency-lock.json") -Encoding UTF8 -Value ($badLock | ConvertTo-Json -Depth 6)
            { & { . $HelperPath -ProjectRoot $projectA -Action help *> $null; Sync-AiRules1cCheckout } } | Should -Throw "*tag/commit mismatch*"
            (& git -C $first.root rev-parse HEAD).Trim() | Should -Be $commitA
        } finally {
            if ($null -ne $indexLock) { $indexLock.Dispose() }
            $env:TEMP = $savedTemp
            $env:ITL_AI_RULES_SOURCE_PATH = $savedSource
            $resolvedFixture = [IO.Path]::GetFullPath($tempRoot)
            $fixtureParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
            if (-not $resolvedFixture.StartsWith($fixtureParent, [StringComparison]::OrdinalIgnoreCase)) { throw "Fixture cleanup escaped its owned temporary root" }
            Remove-Item -LiteralPath $resolvedFixture -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "rejects controlled fork main when aiRules.ref is absent" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-ai-rules-fork-main-" + [guid]::NewGuid().ToString("N"))
        $savedSource = $env:ITL_AI_RULES_SOURCE_PATH
        try {
            Remove-Item Env:\ITL_AI_RULES_SOURCE_PATH -ErrorAction SilentlyContinue
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"dependencyMode":"fresh","aiRules":{"repo":"https://github.com/xmentosx/itl_ai_rules_1c.git","tools":["kilocode"]}}'
            $script:pinError = ""
            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                try { Sync-AiRules1cCheckout | Out-Null } catch { $script:pinError = $_.Exception.Message }
            }
            $script:pinError | Should -Match "requires an immutable configured tag"
        } finally {
            $env:ITL_AI_RULES_SOURCE_PATH = $savedSource
            Remove-Variable -Name pinError -Scope Script -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
