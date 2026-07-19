[CmdletBinding()]
param(
    [ValidateSet("help", "doctor", "validate", "check-tools", "list-platforms", "detect-web-publication", "detect-apache", "configure-web-publication", "publish-dev-branch", "install-vanessa-automation", "prepare-vanessa-authoring", "complete-vanessa-authoring", "begin-verification-repair", "vibecoding1c-mcp-setup", "vibecoding1c-mcp-update", "vibecoding1c-mcp-status", "vibecoding1c-mcp-start", "vibecoding1c-mcp-stop", "vibecoding1c-mcp-select", "vibecoding1c-mcp-refresh-registry", "vibecoding1c-mcp-rotate-keys", "vibecoding1c-mcp-ensure-model", "vibecoding1c-mcp-write-client-config", "update-workflow", "update-ai-rules", "itl-litemode", "itl-switch-client", "update1cbase", "loadfrom1cbase", "getconfigfiles", "deploy-and-test", "run-dev-branch-tests", "stop-dev-branch-test-clients", "init-project", "sync-master", "new-dev-branch", "new-extension-dev-branch", "configure-dev-branch-unsafe-action-protection", "init-dev-branch-extension", "set-dev-branch-extension", "dump-dev-branch-extension", "activate-dev-branch-context", "update-dev-branch-base", "check-dev-branch", "verify-dev-branch", "status", "refresh-dev-branch", "export-dev-branch-result", "close-dev-branch", "switch-master", "switch-dev-branch", "list-dev-branches", "release-e2e-snapshot", "release-e2e-restore", "release-e2e-config-roundtrip", "release-e2e-extension-smoke")]
    [string]$Action = "help",

    [string]$ProjectRoot = (Get-Location).Path,
    [string]$ConfigPath,
    [string]$DevBranchName,
    [string]$DevBranch,
    [string]$DevBranchInfoBasePath,
    [string]$DevBranchWorktreePath,
    [string]$InfoBaseUser = "",
    [string]$ExtensionName,
    [ValidateSet("", "Empty", "Cfe")]
    [string]$ExtensionInitMode = "",
    [string]$ExtensionSourcePath = "",
    [string]$ReleaseAiRulesSource = "",
    [string]$ReleaseSnapshotPath = "",
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
    [ValidateSet("configured", "wizard", "json", "resume")]
    [string]$InitMode = "configured",
    [string]$InitAnswersPath,
    [string]$ResumeRunStatusPath = "",
    [string]$RecoveryReason = "",
    [int]$LauncherPid = 0,
    [ValidateSet("", "fresh", "locked")]
    [string]$DependencyMode = "",
    [string]$BootstrapWorkflowRepo = "",
    [string]$BootstrapWorkflowRef = "",
    [string]$BootstrapWorkflowCommit = "",
    [ValidateSet("", "path")]
    [string]$BootstrapWorkflowSource = "",
    [string]$AgentTarget = "",
    [string]$Client = "",
    [string]$Mode = "status",
    [ValidateSet("", "implicit", "command", "repair", "explicit")]
    [string]$VerificationTrigger = "",
    [ValidateSet("", "vanessa", "event-log", "all")]
    [string]$ExplicitVerificationComponent = "",
    [ValidateSet("", "passed", "failed")]
    [string]$AuthoringResult = "",
    [ValidateSet("", "missing-suite", "unsupported-step", "scenario-context", "product-assertion", "runner", "event-log")]
    [string]$AuthoringErrorCategory = "",
    [string]$AuthoringResultsPath = "",
    [string]$RepairSessionId = "",
    [string[]]$ConfigObjectPaths = @(),
    [switch]$PublishToWeb,
    [switch]$Force,
    [switch]$SkipAiRules,
    [switch]$InstallVanessaIfMissing,
    [switch]$AllowUnverifiedResult,
    [switch]$AllowUnverifiedClose,
    [switch]$UseCurrentWorktree,
    [switch]$OfferOpenAgent,
    [ValidateSet("Auto", "Partial", "Full")]
    [string]$ConfigLoadMode = "Auto",
    [string]$RunStatusPath,
    [string]$RunLogPath,
    [switch]$PauseOnFailure,
    [ValidateSet("", "pre-copy", "post-copy", "post-merge")]
    [string]$LifecyclePhase = "",
    [string]$OperationId = "",
    [int]$OperationOwnerPid = 0,
    [switch]$OperationContinuation,
    [ValidateSet("", "ensure", "stop", "stop-all")][string]$InternalOnDemandOperation = "",
    [ValidateSet("", "roctup", "vanessa-ui")][string]$InternalOnDemandFamily = "",
    [string]$InternalOnDemandInstanceId = "",
    [string]$InternalOnDemandCatalogSha256 = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$script:ConsoleOutputEncoding = New-Object System.Text.UTF8Encoding $false
[Console]::InputEncoding = $script:ConsoleOutputEncoding
[Console]::OutputEncoding = $script:ConsoleOutputEncoding
$OutputEncoding = $script:ConsoleOutputEncoding

function Normalize-Agent1cFullPathText {
    param([string]$Path)

    if ([string]::IsNullOrEmpty($Path)) {
        return $Path
    }

    $root = [System.IO.Path]::GetPathRoot($Path)
    $trimmed = $Path.TrimEnd("\", "/")
    if ([string]::IsNullOrEmpty($trimmed)) {
        return $Path
    }

    if ($root -and $trimmed -eq $root.TrimEnd("\", "/")) {
        return $root
    }
    return $trimmed
}

function Resolve-Agent1cFullPath {
    param([AllowNull()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }

    $full = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Path))
    if (Test-Path -LiteralPath $full -ErrorAction SilentlyContinue) {
        try {
            return (Normalize-Agent1cFullPathText -Path (Get-Item -LiteralPath $full -ErrorAction Stop).FullName)
        } catch {
        }
    }

    $segments = [System.Collections.Generic.List[string]]::new()
    $current = $full
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        if (Test-Path -LiteralPath $current -ErrorAction SilentlyContinue) {
            try {
                $resolved = (Get-Item -LiteralPath $current -ErrorAction Stop).FullName
                for ($i = $segments.Count - 1; $i -ge 0; $i--) {
                    $resolved = Join-Path $resolved $segments[$i]
                }
                return (Normalize-Agent1cFullPathText -Path $resolved)
            } catch {
            }
        }

        $parent = Split-Path -Parent $current
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $current) {
            break
        }

        $leaf = Split-Path -Leaf $current
        if (-not [string]::IsNullOrEmpty($leaf)) {
            $segments.Add($leaf) | Out-Null
        }
        $current = $parent
    }

    return (Normalize-Agent1cFullPathText -Path $full)
}

if (-not $ConfigPath) {
    $ConfigPath = Join-Path (Resolve-Agent1cFullPath -Path $ProjectRoot) ".agent-1c\project.json"
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
    Add-Agent1cReexecArgument -Arguments $arguments -Name "ProjectRoot" -Value (Resolve-Agent1cFullPath -Path $ProjectRoot)
    Add-Agent1cReexecArgument -Arguments $arguments -Name "ConfigPath" -Value (Resolve-Agent1cFullPath -Path $ConfigPath)
    Add-Agent1cReexecArgument -Arguments $arguments -Name "DevBranchName" -Value $DevBranchName
    Add-Agent1cReexecArgument -Arguments $arguments -Name "DevBranch" -Value $DevBranch
    Add-Agent1cReexecArgument -Arguments $arguments -Name "DevBranchInfoBasePath" -Value $DevBranchInfoBasePath
    Add-Agent1cReexecArgument -Arguments $arguments -Name "DevBranchWorktreePath" -Value $DevBranchWorktreePath
    Add-Agent1cReexecArgument -Arguments $arguments -Name "InfoBaseUser" -Value $InfoBaseUser
    Add-Agent1cReexecArgument -Arguments $arguments -Name "ExtensionName" -Value $ExtensionName
    Add-Agent1cReexecArgument -Arguments $arguments -Name "ExtensionInitMode" -Value $ExtensionInitMode
    Add-Agent1cReexecArgument -Arguments $arguments -Name "ExtensionSourcePath" -Value $ExtensionSourcePath
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
    Add-Agent1cReexecArgument -Arguments $arguments -Name "ResumeRunStatusPath" -Value $ResumeRunStatusPath
    Add-Agent1cReexecArgument -Arguments $arguments -Name "RecoveryReason" -Value $RecoveryReason
    Add-Agent1cReexecArgument -Arguments $arguments -Name "LauncherPid" -Value $(if ($LauncherPid -gt 0) { $LauncherPid } else { $null })
    Add-Agent1cReexecArgument -Arguments $arguments -Name "DependencyMode" -Value $DependencyMode
    Add-Agent1cReexecArgument -Arguments $arguments -Name "AgentTarget" -Value $AgentTarget
    Add-Agent1cReexecArgument -Arguments $arguments -Name "Client" -Value $Client
    Add-Agent1cReexecArgument -Arguments $arguments -Name "Mode" -Value $Mode
    Add-Agent1cReexecArgument -Arguments $arguments -Name "VerificationTrigger" -Value $VerificationTrigger
    Add-Agent1cReexecArgument -Arguments $arguments -Name "ExplicitVerificationComponent" -Value $ExplicitVerificationComponent
    Add-Agent1cReexecArgument -Arguments $arguments -Name "AuthoringResult" -Value $AuthoringResult
    Add-Agent1cReexecArgument -Arguments $arguments -Name "AuthoringErrorCategory" -Value $AuthoringErrorCategory
    Add-Agent1cReexecArgument -Arguments $arguments -Name "AuthoringResultsPath" -Value $AuthoringResultsPath
    Add-Agent1cReexecArgument -Arguments $arguments -Name "RepairSessionId" -Value $RepairSessionId
    if ($ConfigObjectPaths.Count -gt 0) { Add-Agent1cReexecArgument -Arguments $arguments -Name "ConfigObjectPaths" -Value ($ConfigObjectPaths -join ",") }
    Add-Agent1cReexecArgument -Arguments $arguments -Name "PublishToWeb" -Value $PublishToWeb
    Add-Agent1cReexecArgument -Arguments $arguments -Name "Force" -Value $Force
    Add-Agent1cReexecArgument -Arguments $arguments -Name "SkipAiRules" -Value $SkipAiRules
    Add-Agent1cReexecArgument -Arguments $arguments -Name "InstallVanessaIfMissing" -Value $InstallVanessaIfMissing
    Add-Agent1cReexecArgument -Arguments $arguments -Name "AllowUnverifiedResult" -Value $AllowUnverifiedResult
    Add-Agent1cReexecArgument -Arguments $arguments -Name "AllowUnverifiedClose" -Value $AllowUnverifiedClose
    Add-Agent1cReexecArgument -Arguments $arguments -Name "UseCurrentWorktree" -Value $UseCurrentWorktree
    Add-Agent1cReexecArgument -Arguments $arguments -Name "OfferOpenAgent" -Value $OfferOpenAgent
    Add-Agent1cReexecArgument -Arguments $arguments -Name "ConfigLoadMode" -Value $(if ($ConfigLoadMode -ne "Auto") { $ConfigLoadMode } else { $null })
    Add-Agent1cReexecArgument -Arguments $arguments -Name "RunStatusPath" -Value $RunStatusPath
    Add-Agent1cReexecArgument -Arguments $arguments -Name "RunLogPath" -Value $RunLogPath
    Add-Agent1cReexecArgument -Arguments $arguments -Name "PauseOnFailure" -Value $PauseOnFailure
    Add-Agent1cReexecArgument -Arguments $arguments -Name "LifecyclePhase" -Value $LifecyclePhase
    Add-Agent1cReexecArgument -Arguments $arguments -Name "BootstrapWorkflowRepo" -Value $BootstrapWorkflowRepo
    Add-Agent1cReexecArgument -Arguments $arguments -Name "BootstrapWorkflowRef" -Value $BootstrapWorkflowRef
    Add-Agent1cReexecArgument -Arguments $arguments -Name "BootstrapWorkflowCommit" -Value $BootstrapWorkflowCommit
    Add-Agent1cReexecArgument -Arguments $arguments -Name "BootstrapWorkflowSource" -Value $BootstrapWorkflowSource
    return [string[]]$arguments.ToArray()
}

$script:LastLogPath = $null
$script:LastProcessId = 0
$script:LastProcessTimedOut = $false
$script:LastProcessMemoryLimitExceeded = $false
$script:LastProcessPeakWorkingSetMb = 0
$script:LastProcessWorkingSetLimitMb = 0
$script:RunStage = ""
$script:RunStageDetail = ""
$script:RunStartedAt = Get-Date
$script:ResolvedRunStatusPath = ""
$script:ResolvedRunLogPath = ""
$script:GitIndexLockPath = ""
$script:GitIndexLockPreExisted = $false
$script:LauncherPid = $LauncherPid
$script:ResumedFrom = $(if ($ResumeRunStatusPath) { Resolve-Agent1cFullPath -Path $ResumeRunStatusPath } else { "" })
$script:RecoveryReason = $RecoveryReason
$script:RunErrorCategory = ""
$script:RunRequiredAction = ""
$script:RunDevBranch = ""
$script:RunWorktreePath = ""
$script:RunExtensionInitializationStatus = ""
$script:RunAuthoringStatus = ""
$script:RunAuthoringStatePath = ""
$script:ProjectRoot = Resolve-Agent1cFullPath -Path $ProjectRoot
$script:ConfigPath = Resolve-Agent1cFullPath -Path $ConfigPath
$script:Config = $null
$script:ToolsManifest = $null
$script:ToolsManifestLoaded = $false
$script:InitVibecoding1cMcpSetupRequested = $false
$script:ItlSkipEventLogForVerification = $false
$script:DependencyLockPath = Join-Path $script:ProjectRoot ".agent-1c\dependency-lock.json"
$script:Agent1cScriptPath = Resolve-Agent1cFullPath -Path $PSCommandPath
$script:Agent1cReexecArguments = Get-Agent1cReexecArguments
$script:LifecycleOperationHandles = @()
$script:LifecycleOperationRecord = $null
$script:LifecycleOperationStatePath = ""
$script:LifecycleOperationId = ""
$script:LifecycleOperationIsContinuation = [bool]$OperationContinuation
$script:LifecycleOperationOwnerPid = $OperationOwnerPid
$script:LifecycleOperationTerminalWrittenByContinuation = $false

$script:Agent1cScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:Agent1cLibRoot = Join-Path $script:Agent1cScriptRoot "lib"
$script:Agent1cModuleFiles = @(
    "agent-1c.core.ps1",
    "agent-1c.ports.ps1",
    "agent-1c.vanessa.ps1",
    "agent-1c.vibecoding1c-mcp.ps1",
    "agent-1c.data-mcp.ps1",
    "agent-1c.roctup-mcp.ps1",
    "agent-1c.lifecycle.ps1",
    "agent-1c.client-adapters.ps1",
    "agent-1c.ondemand-mcp.ps1",
    "agent-1c.verification-modes.ps1",
    "agent-1c.legacy-bridges.ps1",
    "agent-1c.ai-rules-migration.ps1"
)
foreach ($moduleFile in $script:Agent1cModuleFiles) {
    $modulePath = Join-Path $script:Agent1cLibRoot $moduleFile
    if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
        throw "ITL helper module was not found: $modulePath"
    }
    . $modulePath
}

Initialize-GitIndexLockTracking

try {
    Import-DotEnv -Path (Join-Path $script:ProjectRoot ".dev.env")
    Read-ProjectConfig
    $requestedLifecycleAction = $(if ($InternalOnDemandOperation) { "internal-ondemand-$InternalOnDemandOperation" } else { $Action })
    Enter-Agent1cLifecycleOperation `
        -RequestedAction $requestedLifecycleAction `
        -RequestedOperationId $OperationId `
        -RequestedOwnerPid $OperationOwnerPid `
        -Continuation:$OperationContinuation
    Set-RunStage -Stage "start" -Detail "Starting helper action '$requestedLifecycleAction'"

    if ($InternalOnDemandOperation) {
        Invoke-ItlOnDemandBackendBroker `
            -Operation $InternalOnDemandOperation `
            -Family $InternalOnDemandFamily `
            -InstanceId $InternalOnDemandInstanceId `
            -CatalogSha256 $InternalOnDemandCatalogSha256
    } else { switch ($Action) {
        "help" { Show-Help }
        "doctor" { Show-ItlDoctor }
        "validate" { Validate-Project }
        "check-tools" { Check-Tools -StopOnMissing }
        "list-platforms" { List-Platforms }
        "detect-web-publication" { Detect-WebPublication }
        "detect-apache" { Detect-WebPublication }
        "configure-web-publication" { Configure-WebPublication }
        "publish-dev-branch" { Publish-DevBranch }
        "install-vanessa-automation" { Install-VanessaAutomation }
        "prepare-vanessa-authoring" { Prepare-VanessaAuthoring }
        "complete-vanessa-authoring" { Complete-VanessaAuthoring -Result $AuthoringResult -ErrorCategory $AuthoringErrorCategory -ResultsPath $AuthoringResultsPath }
        "begin-verification-repair" { Start-ItlVerificationRepairSession }
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
        "itl-litemode" { Set-ItlLiteMode -Mode $Mode }
        "itl-switch-client" { Switch-ItlClient -Client $Client }
        "update1cbase" { Invoke-ItlUpdate1cBaseBridge }
        "loadfrom1cbase" { Invoke-ItlLoadFrom1cBaseBridge }
        "getconfigfiles" { Invoke-ItlGetConfigFilesBridge }
        "deploy-and-test" { Invoke-ItlDeployAndTestBridge }
        "status" { Show-WorkflowStatus }
        "run-dev-branch-tests" { Run-DevBranchTests }
        "stop-dev-branch-test-clients" { Stop-DevBranchTestClients }
        "check-dev-branch" { Check-DevBranch }
        "verify-dev-branch" { Verify-DevBranch }
        "init-project" { Initialize-Project }
        "sync-master" { Sync-Master }
        "new-dev-branch" { New-DevBranch }
        "new-extension-dev-branch" { New-ExtensionDevBranch }
        "configure-dev-branch-unsafe-action-protection" { Configure-DevBranchUnsafeActionProtection }
        "init-dev-branch-extension" { Init-DevBranchExtension }
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
        "release-e2e-snapshot" { Save-ReleaseE2EInfobaseSnapshot }
        "release-e2e-restore" { Restore-ReleaseE2EInfobaseSnapshot }
        "release-e2e-config-roundtrip" { Invoke-ReleaseE2EConfigRoundtrip }
        "release-e2e-extension-smoke" { Invoke-ReleaseE2EExtensionSmoke }
    } }
    Complete-Agent1cLifecycleOperation -Status "succeeded" -ExitCode 0
    Write-RunStatus -Status "succeeded" -ExitCode 0
} catch {
    $errorMessage = $_.Exception.Message
    Set-RunFailureContextFromMessage -Message $errorMessage
    try {
        $cleanupMessage = Invoke-GitIndexLockCleanupOnFailure
        if ($cleanupMessage) {
            Write-Host $cleanupMessage
            $errorMessage = "$errorMessage $cleanupMessage"
        }
    } catch {
        $cleanupError = "Git index lock cleanup check failed: $($_.Exception.Message)"
        [Console]::Error.WriteLine($cleanupError)
        $errorMessage = "$errorMessage $cleanupError"
    }
    try {
        Complete-Agent1cLifecycleOperation -Status "failed" -ExitCode 1 -ErrorMessage $errorMessage
    } catch {
        [Console]::Error.WriteLine("Failed to write lifecycle operation status: $($_.Exception.Message)")
    }
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
} finally {
    Exit-Agent1cLifecycleOperation
}
