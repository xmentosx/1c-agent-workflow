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
    }
}
