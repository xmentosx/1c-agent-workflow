Describe "1C workflow ai_rules_1c client checks" {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        $RepoRoot = $context.RepoRoot
        $HelperPath = $context.HelperPath
    }

    It "normalizes configured clients, environment overrides, and explicit targets" {
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
                $AgentTarget = "claude-code,kilo"
                $fromExplicit = @(Get-AiRules1cTools)
                [pscustomobject]@{
                    fromConfig = $fromConfig
                    fromEnvironment = $fromEnvironment
                    fromExplicit = $fromExplicit
                }
            }

            @($result.fromConfig) | Should -Be @("codex", "kilocode")
            @($result.fromEnvironment) | Should -Be @("cursor", "kilocode")
            @($result.fromExplicit) | Should -Be @("claude-code", "kilocode")
        } finally {
            [Environment]::SetEnvironmentVariable("AGENT_TOOLS", $savedAgentTools, "Process")
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "adds missing configured clients without removing existing clients" {
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
}
$manifest = [ordered]@{
    tools = @($currentTools | Where-Object { $_ } | Select-Object -Unique)
    files = [ordered]@{}
}
Set-Content -LiteralPath $manifestPath -Encoding UTF8 -Value (($manifest | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
Add-Content -LiteralPath (Join-Path $ProjectRoot "installer-calls.txt") -Encoding ASCII -Value "$Command|$Tool|$($Tools -join ',')"
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

            @($result.calls) | Should -Be @("update||", "add|kilocode|")
            @($result.tools) | Should -Be @("codex", "kilocode")
            $result.unknownError | Should -Match "adapter is not available"
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
            $masterKiloCommands | Should -Be @("itl.md", "itl-new-config-branch.md", "itl-new-extension-branch.md", "itl-status.md", "itl-update-workflow.md")
            $masterKiloCommands | Should -Not -Contain "itl-check.md"
            $masterKiloCommands | Should -Not -Contain "itl-refresh.md"
            $masterKiloCommands | Should -Not -Contain "itl-result.md"
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
        $text | Should -Match "codex,kilocode"
        $text | Should -Match "Assert-OpenSpecBundle"
        $text | Should -Match "git clone"
        $text | Should -Match "protocol must be 1.1"
        $text | Should -Match "Compatibility check changed user-scope Codex prompt"
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
