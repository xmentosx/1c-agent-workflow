[CmdletBinding()]
param(
    [ValidateSet("help", "validate", "check-tools", "list-platforms", "detect-web-publication", "detect-apache", "configure-web-publication", "publish-dev-branch", "install-vanessa-automation", "install-vanessa-mcp", "start-vanessa-mcp", "stop-vanessa-mcp", "vanessa-mcp-status", "install-roctup-mcp", "update-roctup-mcp", "start-roctup-mcp", "stop-roctup-mcp", "roctup-mcp-status", "vibecoding1c-mcp-setup", "vibecoding1c-mcp-update", "vibecoding1c-mcp-status", "vibecoding1c-mcp-start", "vibecoding1c-mcp-stop", "vibecoding1c-mcp-select", "vibecoding1c-mcp-refresh-registry", "vibecoding1c-mcp-rotate-keys", "vibecoding1c-mcp-ensure-model", "vibecoding1c-mcp-write-client-config", "update-workflow", "update-ai-rules", "run-dev-branch-tests", "init-project", "sync-master", "new-dev-branch", "new-extension-dev-branch", "set-dev-branch-extension", "dump-dev-branch-extension", "activate-dev-branch-context", "update-dev-branch-base", "check-dev-branch", "verify-dev-branch", "status", "refresh-dev-branch", "export-dev-branch-result", "close-dev-branch", "switch-master", "switch-dev-branch", "list-dev-branches")]
    [string]$Action = "help",

    [string]$ProjectRoot = (Get-Location).Path,
    [string]$ConfigPath,
    [string]$DevBranchName,
    [string]$DevBranch,
    [string]$DevBranchInfoBasePath,
    [string]$DevBranchWorktreePath,
    [string]$ExtensionName,
    [string]$VanessaFeaturePath,
    [string]$VanessaFilterTags,
    [int]$VanessaTestPort = 0,
    [int]$VanessaMcpPort = 0,
    [int]$RoctupMcpPort = 0,
    [string]$McpDistributionPath = "",
    [ValidateSet("", "global", "project", "branch", "current", "all")]
    [string]$McpScope = "",
    [string]$McpServerId = "",
    [ValidateSet("", "remote", "local")]
    [string]$McpProvider = "",
    [string]$McpConfigId = "",
    [string]$McpHostId = "",
    [ValidateSet("", "project", "branch")]
    [string]$McpLocalScope = "",
    [ValidateSet("configured", "wizard", "json")]
    [string]$InitMode = "configured",
    [string]$InitAnswersPath,
    [ValidateSet("", "fresh", "locked")]
    [string]$DependencyMode = "",
    [ValidateSet("", "codex", "kilocode", "both")]
    [string]$AgentTarget = "",
    [switch]$PublishToWeb,
    [switch]$Force,
    [switch]$SkipAiRules,
    [switch]$InstallVanessaIfMissing,
    [switch]$AllowUnverifiedResult,
    [switch]$AllowUnverifiedClose,
    [switch]$UseCurrentWorktree,
    [switch]$OfferOpenAgent,
    [string]$RunStatusPath,
    [string]$RunLogPath,
    [switch]$PauseOnFailure,
    [ValidateSet("", "post-merge")]
    [string]$LifecyclePhase = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$script:ConsoleOutputEncoding = New-Object System.Text.UTF8Encoding $false
[Console]::OutputEncoding = $script:ConsoleOutputEncoding
$OutputEncoding = $script:ConsoleOutputEncoding

if (-not $ConfigPath) {
    $ConfigPath = Join-Path $ProjectRoot ".agent-1c\project.json"
}

function Add-Agent1cReexecArgument {
    param(
        [System.Collections.Generic.List[string]]$Arguments,
        [string]$Name,
        [AllowNull()][object]$Value
    )

    if ($null -eq $Value) {
        return
    }
    if ($Value -is [System.Management.Automation.SwitchParameter]) {
        if ($Value.IsPresent) {
            $Arguments.Add("-$Name") | Out-Null
        }
        return
    }

    $text = [string]$Value
    if ($text -eq "") {
        return
    }

    $Arguments.Add("-$Name") | Out-Null
    $Arguments.Add($text) | Out-Null
}

function Get-Agent1cReexecArguments {
    $arguments = [System.Collections.Generic.List[string]]::new()
    Add-Agent1cReexecArgument -Arguments $arguments -Name "Action" -Value $Action
    Add-Agent1cReexecArgument -Arguments $arguments -Name "ProjectRoot" -Value ([System.IO.Path]::GetFullPath($ProjectRoot))
    Add-Agent1cReexecArgument -Arguments $arguments -Name "ConfigPath" -Value ([System.IO.Path]::GetFullPath($ConfigPath))
    Add-Agent1cReexecArgument -Arguments $arguments -Name "DevBranchName" -Value $DevBranchName
    Add-Agent1cReexecArgument -Arguments $arguments -Name "DevBranch" -Value $DevBranch
    Add-Agent1cReexecArgument -Arguments $arguments -Name "DevBranchInfoBasePath" -Value $DevBranchInfoBasePath
    Add-Agent1cReexecArgument -Arguments $arguments -Name "DevBranchWorktreePath" -Value $DevBranchWorktreePath
    Add-Agent1cReexecArgument -Arguments $arguments -Name "ExtensionName" -Value $ExtensionName
    Add-Agent1cReexecArgument -Arguments $arguments -Name "VanessaFeaturePath" -Value $VanessaFeaturePath
    Add-Agent1cReexecArgument -Arguments $arguments -Name "VanessaFilterTags" -Value $VanessaFilterTags
    Add-Agent1cReexecArgument -Arguments $arguments -Name "VanessaTestPort" -Value $(if ($VanessaTestPort -ne 0) { $VanessaTestPort } else { $null })
    Add-Agent1cReexecArgument -Arguments $arguments -Name "VanessaMcpPort" -Value $(if ($VanessaMcpPort -ne 0) { $VanessaMcpPort } else { $null })
    Add-Agent1cReexecArgument -Arguments $arguments -Name "RoctupMcpPort" -Value $(if ($RoctupMcpPort -ne 0) { $RoctupMcpPort } else { $null })
    Add-Agent1cReexecArgument -Arguments $arguments -Name "McpDistributionPath" -Value $McpDistributionPath
    Add-Agent1cReexecArgument -Arguments $arguments -Name "McpScope" -Value $McpScope
    Add-Agent1cReexecArgument -Arguments $arguments -Name "McpServerId" -Value $McpServerId
    Add-Agent1cReexecArgument -Arguments $arguments -Name "McpProvider" -Value $McpProvider
    Add-Agent1cReexecArgument -Arguments $arguments -Name "McpConfigId" -Value $McpConfigId
    Add-Agent1cReexecArgument -Arguments $arguments -Name "McpHostId" -Value $McpHostId
    Add-Agent1cReexecArgument -Arguments $arguments -Name "McpLocalScope" -Value $McpLocalScope
    Add-Agent1cReexecArgument -Arguments $arguments -Name "InitMode" -Value $InitMode
    Add-Agent1cReexecArgument -Arguments $arguments -Name "InitAnswersPath" -Value $InitAnswersPath
    Add-Agent1cReexecArgument -Arguments $arguments -Name "DependencyMode" -Value $DependencyMode
    Add-Agent1cReexecArgument -Arguments $arguments -Name "AgentTarget" -Value $AgentTarget
    Add-Agent1cReexecArgument -Arguments $arguments -Name "PublishToWeb" -Value $PublishToWeb
    Add-Agent1cReexecArgument -Arguments $arguments -Name "Force" -Value $Force
    Add-Agent1cReexecArgument -Arguments $arguments -Name "SkipAiRules" -Value $SkipAiRules
    Add-Agent1cReexecArgument -Arguments $arguments -Name "InstallVanessaIfMissing" -Value $InstallVanessaIfMissing
    Add-Agent1cReexecArgument -Arguments $arguments -Name "AllowUnverifiedResult" -Value $AllowUnverifiedResult
    Add-Agent1cReexecArgument -Arguments $arguments -Name "AllowUnverifiedClose" -Value $AllowUnverifiedClose
    Add-Agent1cReexecArgument -Arguments $arguments -Name "UseCurrentWorktree" -Value $UseCurrentWorktree
    Add-Agent1cReexecArgument -Arguments $arguments -Name "OfferOpenAgent" -Value $OfferOpenAgent
    Add-Agent1cReexecArgument -Arguments $arguments -Name "RunStatusPath" -Value $RunStatusPath
    Add-Agent1cReexecArgument -Arguments $arguments -Name "RunLogPath" -Value $RunLogPath
    Add-Agent1cReexecArgument -Arguments $arguments -Name "PauseOnFailure" -Value $PauseOnFailure
    Add-Agent1cReexecArgument -Arguments $arguments -Name "LifecyclePhase" -Value $LifecyclePhase
    return [string[]]$arguments.ToArray()
}

$script:LastLogPath = $null
$script:LastProcessId = 0
$script:LastProcessTimedOut = $false
$script:RunStartedAt = Get-Date
$script:ResolvedRunStatusPath = ""
$script:ResolvedRunLogPath = ""
$script:ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)
$script:ConfigPath = [System.IO.Path]::GetFullPath($ConfigPath)
$script:Config = $null
$script:ToolsManifest = $null
$script:ToolsManifestLoaded = $false
$script:InitVibecoding1cMcpSetupRequested = $false
$script:DependencyLockPath = Join-Path $script:ProjectRoot ".agent-1c\dependency-lock.json"
$script:Agent1cScriptPath = [System.IO.Path]::GetFullPath($PSCommandPath)
$script:Agent1cReexecArguments = Get-Agent1cReexecArguments

$script:Agent1cScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:Agent1cLibRoot = Join-Path $script:Agent1cScriptRoot "lib"
$script:Agent1cModuleFiles = @(
    "agent-1c.core.ps1",
    "agent-1c.vanessa.ps1",
    "agent-1c.vibecoding1c-mcp.ps1",
    "agent-1c.data-mcp.ps1",
    "agent-1c.roctup-mcp.ps1",
    "agent-1c.lifecycle.ps1"
)
foreach ($moduleFile in $script:Agent1cModuleFiles) {
    $modulePath = Join-Path $script:Agent1cLibRoot $moduleFile
    if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
        throw "ITL helper module was not found: $modulePath"
    }
    . $modulePath
}

try {
    Write-RunStatus -Status "running"
    Import-DotEnv -Path (Join-Path $script:ProjectRoot ".dev.env")
    Read-ProjectConfig

    switch ($Action) {
        "help" { Show-Help }
        "validate" { Validate-Project }
        "check-tools" { Check-Tools -StopOnMissing }
        "list-platforms" { List-Platforms }
        "detect-web-publication" { Detect-WebPublication }
        "detect-apache" { Detect-WebPublication }
        "configure-web-publication" { Configure-WebPublication }
        "publish-dev-branch" { Publish-DevBranch }
        "install-vanessa-automation" { Install-VanessaAutomation }
        "install-vanessa-mcp" { Install-VanessaMcp }
        "start-vanessa-mcp" { Start-VanessaMcp }
        "stop-vanessa-mcp" { Stop-VanessaMcp }
        "vanessa-mcp-status" { Show-VanessaMcpStatus }
        "install-roctup-mcp" { Install-RoctupMcp }
        "update-roctup-mcp" { Update-RoctupMcp }
        "start-roctup-mcp" { Start-RoctupMcp }
        "stop-roctup-mcp" { Stop-RoctupMcp }
        "roctup-mcp-status" { Show-RoctupMcpStatus }
        "vibecoding1c-mcp-setup" { Setup-Vibecoding1cMcp }
        "vibecoding1c-mcp-update" { Update-Vibecoding1cMcp }
        "vibecoding1c-mcp-status" { Show-Vibecoding1cMcpStatus }
        "vibecoding1c-mcp-start" { Start-Vibecoding1cMcp }
        "vibecoding1c-mcp-stop" { Stop-Vibecoding1cMcp }
        "vibecoding1c-mcp-select" { Set-Vibecoding1cMcpSelection }
        "vibecoding1c-mcp-refresh-registry" { Refresh-Vibecoding1cMcpRegistry }
        "vibecoding1c-mcp-rotate-keys" { Rotate-Vibecoding1cMcpKeys }
        "vibecoding1c-mcp-ensure-model" { Ensure-Vibecoding1cMcpModel | Out-Null }
        "vibecoding1c-mcp-write-client-config" { Write-Vibecoding1cMcpClientConfig }
        "update-workflow" { Update-WorkflowPackage }
        "update-ai-rules" { Update-AiRules1c }
        "status" { Show-WorkflowStatus }
        "run-dev-branch-tests" { Run-DevBranchTests }
        "check-dev-branch" { Check-DevBranch }
        "verify-dev-branch" { Verify-DevBranch }
        "init-project" { Initialize-Project }
        "sync-master" { Sync-Master }
        "new-dev-branch" { New-DevBranch }
        "new-extension-dev-branch" { New-ExtensionDevBranch }
        "set-dev-branch-extension" { Set-DevBranchExtension }
        "dump-dev-branch-extension" { Dump-DevBranchExtension }
        "activate-dev-branch-context" { Activate-DevBranchContext }
        "update-dev-branch-base" { Update-DevBranchBase }
        "refresh-dev-branch" { Refresh-DevBranch }
        "export-dev-branch-result" { Export-DevBranchResult }
        "close-dev-branch" { Close-DevBranch }
        "switch-master" { Switch-Master }
        "switch-dev-branch" { Switch-DevBranch }
        "list-dev-branches" { List-DevBranches }
    }
    Write-RunStatus -Status "succeeded" -ExitCode 0
} catch {
    $errorMessage = $_.Exception.Message
    try {
        Write-RunStatus -Status "failed" -ExitCode 1 -ErrorMessage $errorMessage
    } catch {
        [Console]::Error.WriteLine("Failed to write run status: $($_.Exception.Message)")
    }
    [Console]::Error.WriteLine($errorMessage)
    if ($PauseOnFailure) {
        Write-Host ""
        try {
            [void](Read-Host "ITL helper failed. Press Enter to close this window")
        } catch {
            Write-Host "ITL helper failed; unable to pause for input."
        }
    }
    exit 1
}
