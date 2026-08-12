Describe "Non-interactive 1C startup dialogs" {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        $RepoRoot = $context.RepoRoot
        $CorePath = Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.core.ps1"
        $VanessaPath = Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.vanessa.ps1"
        $VanessaBuildPath = Join-Path $RepoRoot "scripts\build-vanessa-automation-patched.ps1"
        $McpHostDumpPath = Join-Path $RepoRoot "vibecoding1c-mcp-host\export-1c-config-dump.ps1"
    }

    It "suppresses startup dialogs except in interactive and TestClient launchers" {
        $tokens = $null
        $errors = $null
        $coreAst = [System.Management.Automation.Language.Parser]::ParseFile($CorePath, [ref]$tokens, [ref]$errors)
        @($errors) | Should -HaveCount 0
        $functions = @($coreAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))

        foreach ($name in @("Invoke-Designer", "Invoke-Enterprise")) {
            $functionText = [string](($functions | Where-Object Name -eq $name).Extent.Text)
            $functionText | Should -Match ([regex]::Escape('"/DisableStartupMessages", "/DisableStartupDialogs"'))
        }

        $backgroundEnterprise = [string](($functions | Where-Object Name -eq "Start-EnterpriseBackground").Extent.Text)
        $backgroundEnterprise | Should -Match '(?s)if \(-not \$UseTestClient\)\s*\{\s*\$args \+= "/DisableStartupDialogs"\s*\}'

        $interactiveDesigner = [string](($functions | Where-Object Name -eq "Invoke-DesignerInteractive").Extent.Text)
        $interactiveDesigner | Should -Not -Match ([regex]::Escape('"/DisableStartupDialogs"'))
    }

    It "does not prohibit license warning dialogs in Vanessa-created TestClients" {
        $tokens = $null
        $errors = $null
        $vanessaAst = [System.Management.Automation.Language.Parser]::ParseFile($VanessaPath, [ref]$tokens, [ref]$errors)
        @($errors) | Should -HaveCount 0
        $functions = @($vanessaAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
        $additionalParams = [string](($functions | Where-Object Name -eq "New-VanessaTestClientAdditionalParams").Extent.Text)

        $additionalParams | Should -Match ([regex]::Escape('"/DisableStartupMessages"'))
        $additionalParams | Should -Not -Match ([regex]::Escape('"/DisableStartupDialogs"'))
    }

    It "suppresses dialogs in direct qualification and standalone dump launches" {
        $buildText = Get-Content -LiteralPath $VanessaBuildPath -Raw -Encoding UTF8
        $dumpText = Get-Content -LiteralPath $McpHostDumpPath -Raw -Encoding UTF8

        $buildText | Should -Match '(?s)\$createBaseArguments\s*=\s*@\(.*?"/DisableStartupDialogs".*?"/Out"'
        $dumpText | Should -Match ([regex]::Escape('"/DisableStartupMessages", "/DisableStartupDialogs", "/Out"'))
    }
}
