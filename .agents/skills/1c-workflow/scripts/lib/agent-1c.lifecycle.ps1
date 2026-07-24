function New-RepositoryConnectionArgs {
    $repositoryUser = Require-Value "REPOSITORY_USER" (Get-EnvValue -Name "REPOSITORY_USER")
    $repositoryPassword = ConvertFrom-OptionalPasswordAnswer ([string](Get-EnvValue -Name "REPOSITORY_PASSWORD" -Default ""))
    $repositoryPath = Get-RepositoryPath

    return @(
        "/ConfigurationRepositoryF", $repositoryPath,
        "/ConfigurationRepositoryN", $repositoryUser,
        "/ConfigurationRepositoryP", (ConvertTo-NativeEmptyStringArgument $repositoryPassword)
    )
}

function Update-BaseFromRepository {
    if (-not (Get-SourceUsesRepository)) {
        Write-Host "WARNING: no repository update was performed; master dump uses current source infobase state."
        Write-Host "Source infobase is configured without repository connection. Update it manually before sync-master or refresh-dev-branch when fresh external changes are needed."
        return $false
    }

    $repositoryArgs = (New-RepositoryConnectionArgs) + @(
        "/ConfigurationRepositoryUpdateCfg", "-force",
        "/UpdateDBCfg"
    )

    Invoke-Designer `
        -InfoBasePath (Get-SourceInfoBasePath) `
        -InfoBaseKind (Get-InfoBaseKind) `
        -DesignerArgs $repositoryArgs | Out-Null

    return $true
}

function Assert-ExportPathInsideProject {
    param([string]$ExportPath)
    $resolved = Resolve-ProjectPath $ExportPath
    $root = (Resolve-Agent1cFullPath -Path $script:ProjectRoot).TrimEnd("\")
    $rootPrefix = $root + [System.IO.Path]::DirectorySeparatorChar
    if (-not [string]::Equals($resolved, $root, [System.StringComparison]::OrdinalIgnoreCase) -and
        -not $resolved.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Export path must be inside project root: $resolved"
    }
    return $resolved
}

function Get-StateValue {
    param(
        [object]$State,
        [string]$Name,
        [object]$Default = $null
    )

    if ($null -eq $State) {
        return $Default
    }

    $prop = $State.PSObject.Properties[$Name]
    if ($null -eq $prop -or $null -eq $prop.Value -or [string]::IsNullOrWhiteSpace([string]$prop.Value)) {
        return $Default
    }

    return $prop.Value
}

function Get-DevBranchKind {
    param([object]$State)
    return (Get-StateValue -State $State -Name "devBranchKind" -Default "configuration")
}

function Get-DevBranchExtensionInitializationStatus {
    param([object]$State)

    if ((Get-DevBranchKind -State $State) -ne "extension") {
        return "not-required"
    }
    if (Get-StateValue -State $State -Name "extensionName" -Default "") {
        return "ready"
    }
    $status = Get-StateValue -State $State -Name "extensionInitializationStatus" -Default "pending"
    return ([string]$status).Trim().ToLowerInvariant()
}

function Assert-DevBranchExtensionInitialized {
    param(
        [object]$State,
        [string]$Operation = "development work"
    )

    if ((Get-DevBranchKind -State $State) -ne "extension") {
        return
    }
    $status = Get-DevBranchExtensionInitializationStatus -State $State
    if ($status -eq "ready") {
        return
    }
    Set-RunFailureContext -RequiredAction "Ask the developer whether to create an Empty extension or load a CFE, collect the extension name and CFE path when applicable, then let the agent continue initialization in this worktree. Do not ask the developer to run PowerShell."
    throw "EXTENSION_INIT_REQUIRED: $Operation is blocked because extension initialization is '$status'. The agent must collect Empty or CFE, extension name, and optional CFE path in chat and run the internal initialization helper. Do not ask the developer to run PowerShell."
}

function Assert-DevBranchKind {
    param(
        [object]$State,
        [ValidateSet("configuration", "extension")]
        [string]$Expected
    )

    $actual = Get-DevBranchKind -State $State
    if ($actual -ne $Expected) {
        throw "This action requires a '$Expected' development branch, but current branch state is '$actual'."
    }
}

function Get-ExtensionExportPath {
    param([string]$SafeExtensionName)

    $safe = Require-Value "safeExtensionName" $SafeExtensionName
    $basePath = (Get-ExtensionsPath).TrimEnd("\", "/")
    return (($basePath + "/" + $safe) -replace "\\", "/")
}

function Require-DevBranchExtensionName {
    param([object]$State)

    Assert-DevBranchKind -State $State -Expected "extension"
    $name = Get-StateValue -State $State -Name "extensionName" -Default ""
    if (-not $name) {
        Assert-DevBranchExtensionInitialized -State $State -Operation "extension access"
        throw "EXTENSION_INIT_REQUIRED: extension name is not set for this development branch."
    }
    return $name
}

function Get-DevBranchExtensionExportPath {
    param([object]$State)

    $extensionName = Require-DevBranchExtensionName -State $State
    $safeExtensionName = Get-StateValue -State $State -Name "safeExtensionName" -Default (ConvertTo-SafeName $extensionName)
    $path = Get-StateValue -State $State -Name "extensionDumpPath" -Default ""
    if (-not $path) {
        $path = Get-StateValue -State $State -Name "extensionExportPath" -Default ""
    }
    if (-not $path) {
        $path = Get-ExtensionExportPath -SafeExtensionName $safeExtensionName
    }
    return $path
}

function Assert-SingleManagedExtensionArtifact {
    param(
        [object]$State,
        [string]$ExtensionNameOverride = ""
    )

    if ((Get-DevBranchKind -State $State) -ne "extension") { return }
    $extensionName = if ($ExtensionNameOverride) { $ExtensionNameOverride } else { Require-DevBranchExtensionName -State $State }
    Assert-ExtensionInitName -Name $extensionName | Out-Null
    $allowedRoot = (Get-ExtensionInitDumpPath -Name $extensionName).Replace('\', '/').TrimEnd('/')
    $baseCommit = [string](Get-StateValue -State $State -Name "createdFromCommit" -Default "")
    if (-not (Test-GitCommitExists $baseCommit)) {
        $baseCommit = Get-DevBranchLoadBaseCommit -State $State -ContentKind "extension"
    }

    $changed = @(Get-GitPathList -Arguments @(
        "diff", "--name-only", "-z", "--diff-filter=ACMRTUXBD", $baseCommit, "--", "src/cfe"
    ))
    $untracked = @(Get-GitPathList -Arguments @(
        "ls-files", "-z", "--others", "--exclude-standard", "--", "src/cfe"
    ))
    $offenders = @(
        @($changed) + @($untracked) |
            ForEach-Object { ([string]$_).Replace('\', '/').TrimStart('/') } |
            Where-Object {
                $_ -and $_ -ne $allowedRoot -and -not $_.StartsWith($allowedRoot + '/', [System.StringComparison]::OrdinalIgnoreCase)
            } |
            Sort-Object -Unique
    )
    if ($offenders.Count -gt 0) {
        throw "EXTENSION_BRANCH_SINGLE_ARTIFACT: extension branch '$([string](Get-StateValue -State $State -Name 'devBranch' -Default ''))' may change only '$allowedRoot'. Move each other extension to a separate branch/worktree/base. Offending paths: $($offenders -join ', ')"
    }
}

function Assert-ExtensionFilesReady {
    param([object]$State)

    $extensionExportPath = Get-DevBranchExtensionExportPath -State $State
    $absolutePath = Assert-ExportPathInsideProject $extensionExportPath
    $dumpInfoPath = Join-Path $absolutePath "ConfigDumpInfo.xml"
    if (-not (Test-Path -LiteralPath $dumpInfoPath -PathType Leaf)) {
        throw "Extension files are not ready in '$extensionExportPath'. Create the extension in the development branch infobase, then run dump-dev-branch-extension."
    }
    return $extensionExportPath
}

function Get-DevBranchLoadBaseCommit {
    param(
        [object]$State,
        [ValidateSet("configuration", "extension")]
        [string]$ContentKind = "configuration"
    )

    $specificCommitField = if ($ContentKind -eq "extension") { "lastExtensionBaseUpdatedCommit" } else { "lastConfigBaseUpdatedCommit" }

    foreach ($candidate in @(
        (Get-StateValue -State $State -Name $specificCommitField),
        (Get-StateValue -State $State -Name "lastLoadedCommit"),
        (Get-StateValue -State $State -Name "createdFromCommit")
    )) {
        if (Test-GitCommitExists $candidate) {
            return $candidate
        }
    }

    $masterBranch = Get-MasterBranch
    $mergeBase = & git -C $script:ProjectRoot merge-base HEAD $masterBranch 2>$null
    if ($LASTEXITCODE -eq 0 -and $mergeBase) {
        return ([string]$mergeBase).Trim()
    }

    return Get-CurrentCommit
}

function ConvertTo-ConfigLoadRelativePath {
    param(
        [string]$RepoPath,
        [string]$ExportPath
    )

    $normalizedExportPath = ($ExportPath -replace "\\", "/").Trim("/")
    $normalizedRepoPath = $RepoPath -replace "\\", "/"
    if ($normalizedRepoPath -eq $normalizedExportPath) {
        return $null
    }

    $prefix = $normalizedExportPath + "/"
    if (-not $normalizedRepoPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $null
    }

    $relative = $normalizedRepoPath.Substring($prefix.Length)
    if (-not $relative -or $relative -ieq "ConfigDumpInfo.xml") {
        return $null
    }

    return ($relative -replace "/", [System.IO.Path]::DirectorySeparatorChar)
}

function Get-GitPathList {
    param([string[]]$Arguments)

    $stderrPath = New-TimestampedFilePath -Directory ([System.IO.Path]::GetTempPath()) -Prefix "agent-1c-git-stderr-" -Extension ".log"
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = & git -C $script:ProjectRoot -c core.quotepath=false @Arguments 2> $stderrPath
        $exitCode = if ($LASTEXITCODE -is [int]) { $LASTEXITCODE } else { 1 }
        $stderr = ""
        if (Test-Path -LiteralPath $stderrPath -PathType Leaf -ErrorAction SilentlyContinue) {
            $stderr = [System.IO.File]::ReadAllText($stderrPath, (Get-Utf8Encoding))
        }

        if ($exitCode -ne 0) {
            $phase = if ($LifecyclePhase) { $LifecyclePhase } else { "<none>" }
            throw @"
Git path collection failed.
ProjectRoot: $script:ProjectRoot
CurrentDirectory: $((Get-Location).Path)
LifecyclePhase: $phase
ExitCode: $exitCode
Command: git -C "$script:ProjectRoot" -c core.quotepath=false $($Arguments -join ' ')
Stderr:
$stderr
"@
        }
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
        if (Test-Path -LiteralPath $stderrPath -PathType Leaf -ErrorAction SilentlyContinue) {
            Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
        }
    }

    $text = (@($output) -join "")
    if (-not $text) {
        return
    }

    return @($text -split ([string][char]0) | Where-Object { $_ })
}

function Test-GitPathHasChangesSince {
    param(
        [string]$BaseCommit,
        [string[]]$PathSpec
    )

    $paths = @($PathSpec | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($paths.Count -eq 0 -or -not (Test-GitCommitExists $BaseCommit)) {
        return $false
    }

    $tracked = @(Get-GitPathList -Arguments (@("diff", "--name-only", "-z", "--diff-filter=ACMRTUXBD", $BaseCommit, "--") + $paths))
    $untracked = @(Get-GitPathList -Arguments (@("ls-files", "-z", "--others", "--exclude-standard", "--") + $paths))
    return (($tracked.Count + $untracked.Count) -gt 0)
}

function Test-DevBranchHasCheckableChanges {
    param([object]$State)

    try {
        $configChangeSet = Get-ConfigLoadChangeSet -State $State -ExportPath (Get-ExportPath) -ContentKind "configuration"
        if (@($configChangeSet.files).Count -gt 0) {
            return $true
        }
    } catch {
    }

    if ((Get-DevBranchKind -State $State) -eq "extension") {
        try {
            $extensionExportPath = Get-DevBranchExtensionExportPath -State $State
            $extensionChangeSet = Get-ConfigLoadChangeSet -State $State -ExportPath $extensionExportPath -ContentKind "extension"
            if (@($extensionChangeSet.files).Count -gt 0) {
                return $true
            }
        } catch {
        }
    }

    $featuresPath = [string](Get-ConfigValue -Path "vanessaAutomation.featuresPath" -Default (Get-ConfigValue -Path "testsPath" -Default "tests/features"))
    $baseCommit = Get-DevBranchLoadBaseCommit -State $State -ContentKind "configuration"
    return (Test-GitPathHasChangesSince -BaseCommit $baseCommit -PathSpec @($featuresPath))
}

function Test-WorkflowHelperChangedSince {
    param([string]$BeforeCommit)

    if ([string]::IsNullOrWhiteSpace($BeforeCommit)) {
        return $false
    }

    $changed = @(Get-GitOutput @("diff", "--name-only", $BeforeCommit, "HEAD", "--", ".agents/skills/1c-workflow/scripts"))
    return (@($changed | Where-Object { $_ }).Count -gt 0)
}

function Invoke-Agent1cFreshProcess {
    param(
        [string]$ScriptPath = $script:Agent1cScriptPath,
        [string[]]$AdditionalArguments = @()
    )

    $reexecArguments = [System.Collections.Generic.List[string]]::new()
    foreach ($argument in @($script:Agent1cReexecArguments)) {
        $reexecArguments.Add([string]$argument) | Out-Null
    }
    if (@($AdditionalArguments) -contains "-LifecyclePhase") {
        for ($index = $reexecArguments.Count - 1; $index -ge 0; $index--) {
            if ($reexecArguments[$index] -eq "-LifecyclePhase") {
                $reexecArguments.RemoveAt($index)
                if ($index -lt $reexecArguments.Count) {
                    $reexecArguments.RemoveAt($index)
                }
            }
        }
    }

    $continuesLifecycleOperation = $null -ne $script:LifecycleOperationRecord -and
        -not [string]::IsNullOrWhiteSpace($script:LifecycleOperationId)
    if ($continuesLifecycleOperation) {
        Set-RunStage -Stage "reexec" -Detail "Starting a fresh helper process for the same lifecycle operation."
        $continuationOwnerPid = if ($script:LifecycleOperationIsContinuation) { $script:LifecycleOperationOwnerPid } else { $PID }
        $reexecArguments.Add("-OperationId") | Out-Null
        $reexecArguments.Add($script:LifecycleOperationId) | Out-Null
        $reexecArguments.Add("-OperationOwnerPid") | Out-Null
        $reexecArguments.Add([string]$continuationOwnerPid) | Out-Null
        $reexecArguments.Add("-OperationContinuation") | Out-Null
    }

    $arguments = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $ScriptPath
    ) + @($reexecArguments.ToArray()) + @($AdditionalArguments)

    & powershell @arguments
    $exitCode = if ($LASTEXITCODE -is [int]) { $LASTEXITCODE } elseif ($?) { 0 } else { 1 }
    if ($continuesLifecycleOperation) {
        $terminal = Read-Agent1cLifecycleOperationRecord -Path $script:LifecycleOperationStatePath
        if ($null -eq $terminal -or
            [string]$terminal["operationId"] -cne $script:LifecycleOperationId -or
            [string]$terminal["status"] -notin @("succeeded", "failed")) {
            $message = "LIFECYCLE_OPERATION_CONTINUATION_INVALID reason='fresh process did not write terminal operation state' childExitCode='$exitCode' scriptPath='$ScriptPath' operationId='$($script:LifecycleOperationId)' statePath='$($script:LifecycleOperationStatePath)'"
            Complete-Agent1cLifecycleOperation -Status "failed" -ExitCode 1 -ErrorMessage $message
            Set-RunFailureContext -Category "runner"
            try {
                Write-RunStatus -Status "failed" -ExitCode 1 -ErrorMessage $message
            } catch {
                [Console]::Error.WriteLine("Failed to write run status after invalid lifecycle continuation: $($_.Exception.Message)")
            }
            [Console]::Error.WriteLine($message)
            $exitCode = 1
        } else {
            $script:LifecycleOperationTerminalWrittenByContinuation = $true
            if ([string]$terminal["status"] -eq "failed" -and $exitCode -eq 0) {
                $exitCode = 1
            }
        }
    }
    exit $exitCode
}

function Restart-Agent1cFromMainWorktreeIfNeeded {
    param([string]$MainWorktreePath)

    if ([string]::IsNullOrWhiteSpace($MainWorktreePath)) {
        return
    }
    $mainHelperPath = Join-Path (Resolve-Agent1cFullPath -Path $MainWorktreePath) ".agents\skills\1c-workflow\scripts\agent-1c.ps1"
    if (-not (Test-Path -LiteralPath $mainHelperPath -PathType Leaf)) {
        throw "Main worktree ITL helper was not found: $mainHelperPath"
    }
    if ((Get-FullPathNormalized $mainHelperPath) -eq (Get-FullPathNormalized $script:Agent1cScriptPath)) {
        return
    }

    Write-Host "Development worktree helper may be stale. Restarting the current action through the main worktree helper before master synchronization: $mainHelperPath"
    Invoke-Agent1cFreshProcess -ScriptPath $mainHelperPath -AdditionalArguments @("-LifecyclePhase", "main-helper")
}

function Restart-Agent1cAfterWorkflowHelperUpdate {
    Write-Host "ITL workflow helper scripts changed during merge. Restarting helper in a fresh PowerShell process before continuing."
    Invoke-Agent1cFreshProcess
}

function Restart-Agent1cIfWorkflowHelperChangedSince {
    param(
        [string]$BeforeCommit,
        [string[]]$AdditionalArguments = @()
    )

    if (Test-WorkflowHelperChangedSince -BeforeCommit $BeforeCommit) {
        Write-Host "ITL workflow helper scripts changed during merge. Restarting helper in a fresh PowerShell process before continuing."
        Invoke-Agent1cFreshProcess -AdditionalArguments $AdditionalArguments
    }
}

function Restart-Agent1cAfterDevBranchMerge {
    param([string]$Operation)

    Write-Host "Development branch merge completed for $Operation. Restarting helper in a fresh PowerShell process before loading config files."
    Invoke-Agent1cFreshProcess -AdditionalArguments @("-LifecyclePhase", "post-merge")
}

function Write-ItlAdditionalHelperActions {
    Write-Host ""
    Write-Host "Additional helper actions:"
    Write-Host "  ROCTUP data: use the itl-roctup-data MCP server; its branch backend starts and stops automatically."
    Write-Host "  vibecoding1c MCP: ask for setup, status, select, refresh-registry, or update."
    Write-Host "  Vanessa UI: use the itl-vanessa-ui MCP server only for runtime UI research, recording, or debugging."
    Write-Host "  Vanessa manual profiling: ask to start, inspect, or stop one persistent branch-local interactive profile pair."
    Write-Host "  Extension branches: one branch/worktree/base owns one CFE; several features are allowed only inside it."
    Write-Host "  Extension setup is agent-orchestrated during branch creation or on first entry when its saved status is pending."
    Write-Host "  Maintenance/recovery: ask to update base without tests, update workflow/rules, close/list/switch branches."
    Write-Host "  Full helper action catalog: .agents/skills/1c-workflow/references/advanced-actions.md."
}

function Get-ConfigLoadChangeSet {
    param(
        [object]$State,
        [string]$ExportPath = (Get-ExportPath),
        [ValidateSet("configuration", "extension")]
        [string]$ContentKind = "configuration"
    )

    $absoluteExportPath = Assert-ExportPathInsideProject $ExportPath
    $baseCommit = Get-DevBranchLoadBaseCommit -State $State -ContentKind $ContentKind

    $tracked = @(Get-GitPathList -Arguments @("diff", "--name-only", "-z", "--diff-filter=ACMRTUXBD", $baseCommit, "--", $ExportPath))
    $untracked = @(Get-GitPathList -Arguments @("ls-files", "-z", "--others", "--exclude-standard", "--", $ExportPath))

    $files = @()
    foreach ($path in @($tracked) + @($untracked)) {
        $relative = ConvertTo-ConfigLoadRelativePath -RepoPath $path -ExportPath $ExportPath
        if ($relative) {
            $files += $relative
        }
    }

    $files = @($files | Sort-Object -Unique)
    return [pscustomobject]@{
        files = $files
        baseCommit = $baseCommit
        currentCommit = Get-CurrentCommit
        absoluteExportPath = $absoluteExportPath
    }
}

function Get-ConfigSourceFingerprint {
    param([string]$ExportPath)

    $absoluteExportPath = Assert-ExportPathInsideProject $ExportPath
    $root = $absoluteExportPath.TrimEnd("\", "/")
    $entries = New-Object System.Collections.Generic.List[string]
    foreach ($file in @(Get-ChildItem -LiteralPath $absoluteExportPath -Recurse -File -Force -ErrorAction Stop)) {
        if ($file.Name -ieq "ConfigDumpInfo.xml") { continue }
        $relative = $file.FullName.Substring($root.Length).TrimStart("\", "/").Replace("\", "/")
        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash.ToLowerInvariant()
        $entries.Add(($relative + "`0" + $hash))
    }
    $ordered = @($entries.ToArray() | Sort-Object)
    $payload = [System.Text.Encoding]::UTF8.GetBytes(($ordered -join "`n"))
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $fingerprint = ([System.BitConverter]::ToString($sha.ComputeHash($payload))).Replace("-", "").ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
    return [pscustomobject]@{
        fingerprint = $fingerprint
        fileCount = $ordered.Count
        absoluteExportPath = $absoluteExportPath
    }
}

function Get-DesignerFingerprintFieldName {
    param([ValidateSet("configuration", "extension")][string]$ContentKind)
    if ($ContentKind -eq "extension") { return "lastExtensionDesignerFingerprint" }
    return "lastConfigDesignerFingerprint"
}

function Get-DesignerLoadedAtFieldName {
    param([ValidateSet("configuration", "extension")][string]$ContentKind)
    if ($ContentKind -eq "extension") { return "lastExtensionDesignerLoadedAt" }
    return "lastConfigDesignerLoadedAt"
}

function New-ConfigLoadListFile {
    param(
        [object]$State,
        [string[]]$Files
    )

    $logsPath = Resolve-ProjectPath (Get-ConfigValue -Path "logsPath" -Default "logs/1c")
    New-Item -ItemType Directory -Force -Path $logsPath | Out-Null
    $safeDevBranchName = Get-StateValue -State $State -Name "safeDevBranchName" -Default "dev-branch"
    $listFilePath = New-TimestampedFilePath -Directory $logsPath -Prefix ("load-files-" + $safeDevBranchName + "-") -Extension ".txt"
    [System.IO.File]::WriteAllLines($listFilePath, [string[]]$Files, (Get-Utf8Encoding))
    return $listFilePath
}

function Invoke-ConfigLoadWithFallback {
    param(
        [string]$InfoBasePath,
        [string]$InfoBaseKind,
        [object]$State,
        [string]$AbsoluteExportPath,
        [string]$ListFilePath,
        [int]$FileCount,
        [string]$ExtensionName = "",
        [ValidateSet("Auto", "Partial", "Full")]
        [string]$Mode = "Auto"
    )

    $baseArgs = @("/LoadConfigFromFiles", $AbsoluteExportPath)
    if ($ExtensionName) {
        $baseArgs += @("-Extension", $ExtensionName)
    }

    if ($Mode -eq "Full") {
        Write-Host "Full config load requested explicitly. Changed file count: $FileCount"
        Invoke-Designer -InfoBasePath $InfoBasePath -InfoBaseKind $InfoBaseKind `
            -DesignerArgs ($baseArgs + @("-Format", "Hierarchical", "/UpdateDBCfg")) | Out-Null
        return [pscustomobject]@{
            loadModeUsed = "full"
            partialLogPath = ""
            fullFallbackLogPath = $script:LastLogPath
            lastLogPath = $script:LastLogPath
            configLoadStatus = "passed"
            partialError = ""
            fullFallbackError = ""
        }
    }

    Write-Host "Partial config load file count: $FileCount"
    Write-Host "Partial config load list: $ListFilePath"
    $partialArgs = $baseArgs + @("-listFile", $ListFilePath, "-Format", "Hierarchical", "/UpdateDBCfg")
    $script:LastNativeProcessStarted = $false
    try {
        Invoke-Designer -InfoBasePath $InfoBasePath -InfoBaseKind $InfoBaseKind -DesignerArgs $partialArgs | Out-Null
        return [pscustomobject]@{
            loadModeUsed = "partial"
            partialLogPath = $script:LastLogPath
            fullFallbackLogPath = ""
            lastLogPath = $script:LastLogPath
            configLoadStatus = "passed"
            partialError = ""
            fullFallbackError = ""
        }
    } catch {
        $partialException = $_
        $partialLogPath = $script:LastLogPath
        $partialMessage = $partialException.Exception.Message
        $memoryGuardCode = ""
        if ($partialMessage -match '^(DESIGNER_MEMORY_LIMIT_EXCEEDED|DESIGNER_MEMORY_MONITOR_FAILED)\b') {
            $memoryGuardCode = $Matches[1]
        }
        if ($memoryGuardCode) {
            $configLoadStatus = if ($memoryGuardCode -eq "DESIGNER_MEMORY_LIMIT_EXCEEDED") { "memory-limit-exceeded" } else { "memory-monitor-failed" }
            if ($State) {
                Update-DevBranchState -State $State -Updates @{
                    configLoadStatus = $configLoadStatus
                    lastConfigLoadMode = "partial"
                    lastConfigPartialLogPath = $partialLogPath
                    lastConfigFullFallbackLogPath = ""
                    lastConfigPartialError = $partialMessage
                    lastConfigFullFallbackError = ""
                    lastDesignerMemoryLimitExceeded = ($memoryGuardCode -eq "DESIGNER_MEMORY_LIMIT_EXCEEDED")
                    lastDesignerPeakWorkingSetMb = [int]$script:LastProcessPeakWorkingSetMb
                    lastDesignerWorkingSetLimitMb = [int]$script:LastProcessWorkingSetLimitMb
                    lastDesignerMemoryGuardError = $partialMessage
                    lastDesignerMemoryGuardFailedAt = (Get-Date).ToString("o")
                    lastLogPath = $partialLogPath
                }
            }
            $contentLabel = if ($ExtensionName) { "extension" } else { "configuration" }
            Set-RunStage -Stage "config-load.$configLoadStatus" -Detail "$memoryGuardCode stopped the partial $contentLabel load; full fallback is suppressed."
            Write-Warning "$memoryGuardCode stopped Designer. Full-load fallback is suppressed to avoid submitting the same source files to another process."
            Write-Warning "Inspect the input XML/source files. Because no infobase snapshot is available, recreate the branch infobase if its state is uncertain. Log: $partialLogPath"
            throw
        }
        if ($Mode -eq "Partial" -or -not $script:LastNativeProcessStarted) {
            throw
        }

        Write-Warning "Partial config load failed after Designer received -listFile. Running one full-load fallback in the same branch infobase. No infobase snapshot is available."
        Write-Warning "Partial load log: $partialLogPath"
        try {
            Invoke-Designer -InfoBasePath $InfoBasePath -InfoBaseKind $InfoBaseKind `
                -DesignerArgs ($baseArgs + @("-Format", "Hierarchical", "/UpdateDBCfg")) | Out-Null
            return [pscustomobject]@{
                loadModeUsed = "full-fallback"
                partialLogPath = $partialLogPath
                fullFallbackLogPath = $script:LastLogPath
                lastLogPath = $script:LastLogPath
                configLoadStatus = "fallback-succeeded"
                partialError = $partialException.Exception.Message
                fullFallbackError = ""
            }
        } catch {
            $fullException = $_
            $fullLogPath = $script:LastLogPath
            if ($State) {
                Update-DevBranchState -State $State -Updates @{
                    configLoadStatus = "fallback-failed"
                    lastConfigLoadMode = "full-fallback"
                    lastConfigPartialLogPath = $partialLogPath
                    lastConfigFullFallbackLogPath = $fullLogPath
                    lastConfigPartialError = $partialException.Exception.Message
                    lastConfigFullFallbackError = $fullException.Exception.Message
                    lastLogPath = $fullLogPath
                }
            }
            throw "Partial and full fallback config loads both failed. Partial: $($partialException.Exception.Message) (log: $partialLogPath). Full fallback: $($fullException.Exception.Message) (log: $fullLogPath). The branch infobase may be in an intermediate state; the safe recovery is to recreate its copy."
        }
    }
}

function New-LoadStateUpdates {
    param(
        [object]$LoadResult,
        [ValidateSet("configuration", "extension")]
        [string]$ContentKind = "configuration"
    )

    $now = (Get-Date).ToString("o")
    if ($ContentKind -eq "extension") {
        $updates = @{
            lastExtensionBaseUpdatedCommit = $LoadResult.currentCommit
            lastExtensionBaseUpdateAt = $now
            lastExtensionBaseUpdateListFile = $LoadResult.listFile
        }
    } else {
        $updates = @{
            lastConfigBaseUpdatedCommit = $LoadResult.currentCommit
            lastConfigBaseUpdateAt = $now
            lastConfigBaseUpdateListFile = $LoadResult.listFile
        }
    }

    if ($LoadResult.lastLogPath) {
        $updates["lastLogPath"] = $LoadResult.lastLogPath
    }
    if ($LoadResult.loaded) {
        $updates["configLoadStatus"] = $LoadResult.configLoadStatus
        $updates["lastConfigLoadMode"] = $LoadResult.loadModeUsed
        $updates["lastConfigPartialLogPath"] = $LoadResult.partialLogPath
        $updates["lastConfigFullFallbackLogPath"] = $LoadResult.fullFallbackLogPath
        $updates["lastConfigPartialError"] = $LoadResult.partialError
        $updates["lastConfigFullFallbackError"] = $LoadResult.fullFallbackError
    }
    foreach ($field in @("sourceFingerprint", "loadReason", "designerInvoked", "enterpriseInvoked")) {
        if ($LoadResult.PSObject.Properties.Match($field).Count -gt 0) {
            $updates[$field] = $LoadResult.$field
        }
    }
    if ($LoadResult.PSObject.Properties.Match("sourceFingerprint").Count -gt 0 -and $LoadResult.sourceFingerprint) {
        $updates[(Get-DesignerFingerprintFieldName -ContentKind $ContentKind)] = $LoadResult.sourceFingerprint
        if ($LoadResult.PSObject.Properties.Match("designerInvoked").Count -gt 0 -and $LoadResult.designerInvoked) {
            $updates[(Get-DesignerLoadedAtFieldName -ContentKind $ContentKind)] = $now
        }
    }

    return $updates
}

function Get-DevBranchAutoUpdateToolRoot {
    return (Join-Path $script:ProjectRoot ".agents\skills\1c-workflow\tools\auto-update")
}

function Get-DevBranchAutoUpdateInstallRoot {
    return (Resolve-ProjectPath ".agent-1c/tools/auto-update")
}

function Get-DevBranchAutoUpdateMainEpfName {
    $baseName = -join ([char[]](
        0x0414, 0x043B, 0x044F, 0x0410, 0x0432, 0x0442, 0x043E, 0x043C,
        0x0430, 0x0442, 0x0438, 0x0447, 0x0435, 0x0441, 0x043A, 0x043E,
        0x0433, 0x043E, 0x041E, 0x0431, 0x043D, 0x043E, 0x0432, 0x043B,
        0x0435, 0x043D, 0x0438, 0x044F, 0x0418, 0x0411
    ))
    return "$baseName.epf"
}

function Get-DevBranchAutoUpdateDeferredHandlersEpfName {
    $baseName = -join ([char[]](
        0x0414, 0x043B, 0x044F, 0x0410, 0x0432, 0x0442, 0x043E, 0x043C,
        0x0430, 0x0442, 0x0438, 0x0447, 0x0435, 0x0441, 0x043A, 0x043E,
        0x0433, 0x043E, 0x041E, 0x0431, 0x043D, 0x043E, 0x0432, 0x043B,
        0x0435, 0x043D, 0x0438, 0x044F, 0x0418, 0x0411, 0x005F, 0x041E,
        0x0442, 0x043B, 0x043E, 0x0436, 0x0435, 0x043D, 0x043D, 0x044B,
        0x0435, 0x041E, 0x0431, 0x0440, 0x0430, 0x0431, 0x043E, 0x0442,
        0x0447, 0x0438, 0x043A, 0x0438
    ))
    return "$baseName.epf"
}

function Ensure-DevBranchAutoUpdateEpfs {
    $sourceRoot = Get-DevBranchAutoUpdateToolRoot
    if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container -ErrorAction SilentlyContinue)) {
        throw "Development branch auto-update tool source was not found: $sourceRoot"
    }

    $installRoot = Get-DevBranchAutoUpdateInstallRoot
    New-Item -ItemType Directory -Force -Path $installRoot | Out-Null

    $epfNames = @(
        (Get-DevBranchAutoUpdateMainEpfName),
        (Get-DevBranchAutoUpdateDeferredHandlersEpfName)
    )
    foreach ($epfName in $epfNames) {
        $sourcePath = Join-Path $sourceRoot $epfName
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf -ErrorAction SilentlyContinue)) {
            throw "Development branch auto-update EPF was not found: $sourcePath"
        }

        $targetPath = Join-Path $installRoot $epfName
        $needsCopy = -not (Test-Path -LiteralPath $targetPath -PathType Leaf -ErrorAction SilentlyContinue)
        if (-not $needsCopy) {
            $sourceFile = Get-Item -LiteralPath $sourcePath
            $targetFile = Get-Item -LiteralPath $targetPath
            if ($sourceFile.LastWriteTime -gt $targetFile.LastWriteTime -or $sourceFile.Length -ne $targetFile.Length) {
                $needsCopy = $true
            }
        }

        if ($needsCopy) {
            Copy-Item -LiteralPath $sourcePath -Destination $targetPath -Force
        }
    }

    return (Join-Path $installRoot (Get-DevBranchAutoUpdateMainEpfName))
}

function Get-DevBranchAutoUpdateTimeoutSeconds {
    $rawValue = Get-Setting `
        -EnvName "DEV_BRANCH_AUTO_UPDATE_TIMEOUT_SECONDS" `
        -ConfigName "devBranchAutoUpdateTimeoutSeconds" `
        -Default "900"

    $value = 0
    if (-not [int]::TryParse(([string]$rawValue).Trim(), [ref]$value) -or $value -le 0) {
        throw "DEV_BRANCH_AUTO_UPDATE_TIMEOUT_SECONDS must be a positive integer. Current value: $rawValue"
    }

    return $value
}

function Invoke-DevBranchEnterpriseAutoUpdate {
    param([object]$State)

    $epfPath = Ensure-DevBranchAutoUpdateEpfs
    $timeoutSeconds = Get-DevBranchAutoUpdateTimeoutSeconds
    Write-Host "Running development branch Enterprise auto-update: $epfPath"
    Write-Host "Development branch Enterprise auto-update timeout: $timeoutSeconds seconds"
    Invoke-Enterprise `
        -InfoBasePath $State.devBranchInfoBasePath `
        -InfoBaseKind $State.infoBaseKind `
        -EnterpriseArgs @("/Execute", $epfPath) `
        -TimeoutSeconds $timeoutSeconds | Out-Null

    return [pscustomobject]@{
        epfPath = $epfPath
        logPath = $script:LastLogPath
        updatedAt = (Get-Date).ToString("o")
    }
}

function Invoke-DevBranchEnterpriseAutoUpdateIfLoaded {
    param(
        [object]$State,
        [object]$LoadResult,
        [hashtable]$Updates
    )

    $normalizationRequired = $LoadResult.PSObject.Properties.Match("normalizationRequired").Count -gt 0 -and [bool]$LoadResult.normalizationRequired
    if (-not $LoadResult.loaded -and -not $normalizationRequired) {
        return
    }

    Ensure-DevBranchEnterpriseNormalized -State $State -Reason "config-load" -Updates $Updates | Out-Null
    if ($LoadResult.PSObject.Properties.Match("enterpriseInvoked").Count -gt 0) {
        $LoadResult.enterpriseInvoked = $true
        $Updates["enterpriseInvoked"] = $true
    }
}

function Assert-EnterpriseNormalizationTargetsBranchCopy {
    param([object]$State)

    $branchPath = [string](Get-StateValue -State $State -Name "devBranchInfoBasePath" -Default "")
    $sourcePath = [string](Get-SourceInfoBasePath)
    if (-not $branchPath) {
        throw "Development branch infobase path is missing; Enterprise normalization cannot run."
    }

    $same = $false
    if ((Get-StateValue -State $State -Name "infoBaseKind" -Default "file") -eq "file") {
        $same = (Resolve-Agent1cFullPath -Path $branchPath) -ieq (Resolve-Agent1cFullPath -Path $sourcePath)
    } else {
        $same = $branchPath.Trim() -ieq $sourcePath.Trim()
    }
    if ($same) {
        throw "Refusing Enterprise normalization because the target is the source infobase. Only a copied development branch infobase is allowed."
    }
}

function Ensure-DevBranchEnterpriseNormalized {
    param(
        [object]$State,
        [ValidateSet("branch-copy", "config-load", "legacy-preflight")]
        [string]$Reason = "legacy-preflight",
        [hashtable]$Updates = $null
    )

    $currentStatus = [string](Get-StateValue -State $State -Name "enterpriseNormalizationStatus" -Default "")
    if ($Reason -eq "legacy-preflight" -and $currentStatus -eq "passed") {
        return $State
    }

    Set-RunStage -Stage "enterprise.normalize" -Detail "Running Enterprise normalization for reason '$Reason'."
    Assert-EnterpriseNormalizationTargetsBranchCopy -State $State
    $statePath = [string](Get-StateValue -State $State -Name "statePath" -Default "")
    $canPersistImmediately = $statePath -and (Test-Path -LiteralPath $statePath -PathType Leaf -ErrorAction SilentlyContinue)
    $pending = @{
        enterpriseNormalizationStatus = "pending"
        enterpriseNormalizationReason = $Reason
        enterpriseNormalizationError = ""
    }
    if ($canPersistImmediately) {
        Update-DevBranchState -State $State -Updates $pending
    }

    try {
        $autoUpdateResult = Invoke-DevBranchEnterpriseAutoUpdate -State $State
        $passed = @{
            enterpriseNormalizationStatus = "passed"
            enterpriseNormalizationReason = $Reason
            enterpriseNormalizationError = ""
            enterpriseNormalizedAt = $autoUpdateResult.updatedAt
            lastEnterpriseAutoUpdateAt = $autoUpdateResult.updatedAt
            lastEnterpriseAutoUpdateLogPath = $autoUpdateResult.logPath
            lastEnterpriseAutoUpdateEpfPath = $autoUpdateResult.epfPath
        }
        if ($autoUpdateResult.logPath) {
            $passed["lastLogPath"] = $autoUpdateResult.logPath
        }
        if ($null -ne $Updates) {
            foreach ($key in $passed.Keys) { $Updates[$key] = $passed[$key] }
        } else {
            Update-DevBranchState -State $State -Updates $passed
        }
    } catch {
        if ($canPersistImmediately) {
            Update-DevBranchState -State $State -Updates @{
                enterpriseNormalizationStatus = "failed"
                enterpriseNormalizationReason = $Reason
                enterpriseNormalizationError = $_.Exception.Message
            }
        }
        throw
    }

    if ($null -ne $Updates) {
        return $State
    }
    return (Read-DevBranchState -Name (Get-StateValue -State $State -Name "devBranchName" -Default ""))
}

function Dump-ConfigToFiles {
    $exportPath = Get-ExportPath
    $absoluteExportPath = Assert-ExportPathInsideProject $exportPath
    $transactionRoot = Assert-ExportPathInsideProject -ExportPath (".agent-1c/config-dump/" + [guid]::NewGuid().ToString("N"))
    $stagedPath = Join-Path $transactionRoot "staged"
    $backupPath = Join-Path $transactionRoot "backup"
    $targetExisted = Test-Path -LiteralPath $absoluteExportPath -PathType Container -ErrorAction SilentlyContinue
    $targetMoved = $false
    $stageInstalled = $false

    if (-not $targetExisted -and (Test-Path -LiteralPath $absoluteExportPath -PathType Leaf -ErrorAction SilentlyContinue)) {
        throw "Configuration dump target is a file: $absoluteExportPath"
    }

    try {
        New-Item -ItemType Directory -Force -Path $stagedPath | Out-Null
        $designerArgs = @()
        if (Get-SourceUsesRepository) {
            $designerArgs += New-RepositoryConnectionArgs
        }
        $designerArgs += @("/DumpConfigToFiles", $stagedPath, "-Format", "Hierarchical")

        Invoke-Designer `
            -InfoBasePath (Get-SourceInfoBasePath) `
            -InfoBaseKind (Get-InfoBaseKind) `
            -DesignerArgs $designerArgs | Out-Null

        $dumpState = Get-DesignerDumpArtifactState -Path $stagedPath
        if (-not $dumpState.ready) {
            throw "1C configuration dump did not create complete Configuration.xml and ConfigDumpInfo.xml artifacts. Check the 1C log: $script:LastLogPath"
        }

        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $absoluteExportPath) | Out-Null
        if ($targetExisted) {
            Move-Item -LiteralPath $absoluteExportPath -Destination $backupPath
            $targetMoved = $true
        }
        Move-Item -LiteralPath $stagedPath -Destination $absoluteExportPath
        $stageInstalled = $true

        if ($targetMoved -and (Test-Path -LiteralPath $backupPath -PathType Container)) {
            Remove-Item -LiteralPath $backupPath -Recurse -Force
        }
        if (Test-Path -LiteralPath $transactionRoot -PathType Container) {
            Remove-Item -LiteralPath $transactionRoot -Recurse -Force
        }

        return [pscustomobject]@{
            exportPath = $exportPath
            absoluteExportPath = $absoluteExportPath
            incremental = $false
            transactional = $true
            logPath = $script:LastLogPath
        }
    } catch {
        $originalError = $_.Exception.Message
        try {
            if ($stageInstalled -and (Test-Path -LiteralPath $absoluteExportPath -ErrorAction SilentlyContinue)) {
                Remove-Item -LiteralPath $absoluteExportPath -Recurse -Force
            }
            if ($targetMoved -and (Test-Path -LiteralPath $backupPath -PathType Container)) {
                Move-Item -LiteralPath $backupPath -Destination $absoluteExportPath
            }
        } catch {
            throw "1C configuration dump failed and rollback also failed. Original error: $originalError. Rollback error: $($_.Exception.Message). Diagnostic staging: $transactionRoot"
        }

        Write-Warning "1C configuration dump failed. Diagnostic staging was preserved: $transactionRoot"
        throw "1C configuration dump failed. $originalError Diagnostic staging: $transactionRoot"
    }
}

function Dump-ExtensionToFiles {
    param([object]$State)

    Assert-DevBranchKind -State $State -Expected "extension"
    Assert-SingleManagedExtensionArtifact -State $State
    $extensionName = Require-DevBranchExtensionName -State $State
    $extensionExportPath = Get-DevBranchExtensionExportPath -State $State
    $absoluteExportPath = Assert-ExportPathInsideProject $extensionExportPath
    $transactionRoot = Assert-ExportPathInsideProject -ExportPath (".agent-1c/extension-dump/" + [guid]::NewGuid().ToString("N"))
    $stagedPath = Join-Path $transactionRoot "staged"
    $backupPath = Join-Path $transactionRoot "backup"
    $targetExisted = Test-Path -LiteralPath $absoluteExportPath -PathType Container -ErrorAction SilentlyContinue
    $targetMoved = $false
    $stageInstalled = $false
    $tools = Get-ExtensionLifecycleToolPaths

    try {
        New-Item -ItemType Directory -Force -Path $stagedPath | Out-Null
        Invoke-Designer `
            -InfoBasePath $State.devBranchInfoBasePath `
            -InfoBaseKind $State.infoBaseKind `
            -DesignerArgs @("/DumpConfigToFiles", $stagedPath, "-Extension", $extensionName, "-Format", "Hierarchical") | Out-Null

        $dumpInfoPath = Join-Path $stagedPath "ConfigDumpInfo.xml"
        if (-not (Test-Path -LiteralPath $dumpInfoPath -PathType Leaf)) {
            throw "1C extension dump did not create ConfigDumpInfo.xml for '$extensionName'. Check the 1C log: $script:LastLogPath"
        }
        Assert-NormalizedExtensionDump -Path $stagedPath -Name $extensionName
        Invoke-ExtensionLifecycleTool -ScriptPath $tools.validate -Arguments @("-ExtensionPath", $stagedPath)

        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $absoluteExportPath) | Out-Null
        if ($targetExisted) {
            Move-Item -LiteralPath $absoluteExportPath -Destination $backupPath
            $targetMoved = $true
        } elseif (Test-Path -LiteralPath $absoluteExportPath -PathType Leaf -ErrorAction SilentlyContinue) {
            throw "Extension dump target is a file: $absoluteExportPath"
        }
        Move-Item -LiteralPath $stagedPath -Destination $absoluteExportPath
        $stageInstalled = $true

        return [pscustomobject]@{
            extensionName = $extensionName
            exportPath = $extensionExportPath
            absoluteExportPath = $absoluteExportPath
            incremental = $false
            transactional = $true
            logPath = $script:LastLogPath
        }
    } catch {
        $originalError = $_.Exception.Message
        try {
            if ($stageInstalled -and (Test-Path -LiteralPath $absoluteExportPath -ErrorAction SilentlyContinue)) {
                Remove-Item -LiteralPath $absoluteExportPath -Recurse -Force
            }
            if ($targetMoved -and (Test-Path -LiteralPath $backupPath -PathType Container)) {
                Move-Item -LiteralPath $backupPath -Destination $absoluteExportPath
            }
        } catch {
            throw "Extension dump failed: $originalError Transaction rollback also failed: $($_.Exception.Message)"
        }
        throw "Extension dump failed before state or fingerprint update: $originalError"
    } finally {
        if (Test-Path -LiteralPath $transactionRoot -PathType Container -ErrorAction SilentlyContinue) {
            Remove-Item -LiteralPath $transactionRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Stop-DevBranchRuntimeBeforeInfobaseMutation {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [string]$Reason = "managed infobase mutation",
        [string]$InfoBasePath = ""
    )

    $infoBasePath = if ([string]::IsNullOrWhiteSpace($InfoBasePath)) {
        [string](Get-StateValue -State $State -Name "devBranchInfoBasePath" -Default "")
    } else {
        $InfoBasePath
    }
    if ([string]::IsNullOrWhiteSpace($infoBasePath)) {
        throw "ITL_INFOBASE_RUNTIME_DRAIN_FAILED: development branch infobase path is missing."
    }

    Set-RunStage -Stage "config-load.stop-runtime" -Detail "Stopping workflow-owned 1C runtime before $Reason."
    try {
        Invoke-DevBranchVanessaRuntimeRelease -State $State -Reason $Reason | Out-Null
        Stop-ItlOnDemandBackends -Family "roctup" -InfoBasePath $infoBasePath -Strict

        $roctupRuntime = Get-RoctupMcpRuntimeInfo -State $State
        if ($roctupRuntime.processAlive) {
            Stop-RoctupMcpForState -State $State -Quiet -RequireOwnership -SkipClientConfig | Out-Null
        }

        $remainingTests = @(Get-OwnVanessaTestProcesses -State $State)
        $remainingOnDemand = @(Get-ItlOnDemandRuntimeInstances -Strict | Where-Object {
            Test-ItlOnDemandInfoBaseMatch -First ([string]$_.infoBasePath) -Second $infoBasePath
        })
        if ($remainingTests.Count -gt 0 -or $remainingOnDemand.Count -gt 0) {
            throw "workflow-owned processes remain after cleanup (tests=$($remainingTests.Count), ondemand=$($remainingOnDemand.Count))."
        }
    } catch {
        throw "ITL_INFOBASE_RUNTIME_DRAIN_FAILED reason='$Reason' infoBasePath='$infoBasePath' detail='$($_.Exception.Message)'"
    }

    Write-Host "Workflow-owned 1C runtime stopped before $Reason."
}

function Restore-DevBranchInfobaseFromSnapshot {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$SnapshotPath,
        [string]$Reason = "infobase snapshot restore"
    )

    Stop-DevBranchRuntimeBeforeInfobaseMutation -State $State -Reason $Reason
    Invoke-Designer `
        -InfoBasePath $State.devBranchInfoBasePath `
        -InfoBaseKind $State.infoBaseKind `
        -DesignerArgs @("/RestoreIB", $SnapshotPath) | Out-Null
}

function Load-ConfigFromFiles {
    param(
        [string]$InfoBasePath,
        [string]$InfoBaseKind,
        [object]$State,
        [string]$ExportPath = (Get-ExportPath),
        [ValidateSet("configuration", "extension")]
        [string]$ContentKind = "configuration",
        [string]$ExtensionName = "",
        [ValidateSet("Auto", "Partial", "Full")]
        [string]$Mode = "Auto"
    )

    Set-RunStage -Stage "config-load.fingerprint" -Detail "Calculating the $ContentKind source fingerprint."
    $source = Get-ConfigSourceFingerprint -ExportPath $ExportPath
    $fingerprintField = Get-DesignerFingerprintFieldName -ContentKind $ContentKind
    $loadedAtField = Get-DesignerLoadedAtFieldName -ContentKind $ContentKind
    $previousFingerprint = [string](Get-StateValue -State $State -Name $fingerprintField -Default "")
    $normalizationStatus = [string](Get-StateValue -State $State -Name "enterpriseNormalizationStatus" -Default "")
    $currentCommit = Get-CurrentCommit

    if ($previousFingerprint -and $previousFingerprint -eq $source.fingerprint) {
        $normalizationRequired = $normalizationStatus -ne "passed"
        $reason = if ($normalizationRequired) { "source-fingerprint-match-normalization-required" } else { "source-fingerprint-match" }
        Write-Host "Config source fingerprint unchanged for $ContentKind. Designer skipped."
        Set-RunStage -Stage "config-load.skipped" -Detail "The $ContentKind fingerprint is unchanged; Designer was skipped."
        if ($normalizationRequired) { Write-Host "Enterprise normalization remains $normalizationStatus and will be retried without Designer." }
        return [pscustomobject]@{
            loaded = $false
            normalizationRequired = $normalizationRequired
            fileCount = $source.fileCount
            listFile = ""
            currentCommit = $currentCommit
            lastLogPath = $script:LastLogPath
            loadModeUsed = ""
            partialLogPath = ""
            fullFallbackLogPath = ""
            configLoadStatus = "passed"
            partialError = ""
            fullFallbackError = ""
            sourceFingerprint = $source.fingerprint
            loadReason = $reason
            designerInvoked = $false
            enterpriseInvoked = $false
        }
    }

    $changeSet = Get-ConfigLoadChangeSet -State $State -ExportPath $ExportPath -ContentKind $ContentKind
    if ($changeSet.files.Count -eq 0) {
        if ($previousFingerprint) {
            Write-Warning "Source fingerprint changed but Git produced no partial list. Running a full load to preserve correctness."
            $Mode = "Full"
            $changeSet.files = @("<fingerprint-changed>")
        } else {
            Write-Host "No changed config files under $ExportPath since $($changeSet.baseCommit)."
            Write-Host "Legacy state fingerprint initialized without reloading the matching branch infobase."
            Set-RunStage -Stage "config-load.seeded" -Detail "Initialized the legacy $ContentKind fingerprint without Designer."
            return [pscustomobject]@{
                loaded = $false
                normalizationRequired = ($normalizationStatus -ne "passed")
                fileCount = $source.fileCount
                listFile = ""
                currentCommit = $changeSet.currentCommit
                lastLogPath = $script:LastLogPath
                loadModeUsed = ""
                partialLogPath = ""
                fullFallbackLogPath = ""
                configLoadStatus = "passed"
                partialError = ""
                fullFallbackError = ""
                sourceFingerprint = $source.fingerprint
                loadReason = "legacy-fingerprint-seed"
                designerInvoked = $false
                enterpriseInvoked = $false
            }
        }
    }

    $listFilePath = ""
    if ($Mode -ne "Full") {
        $listFilePath = New-ConfigLoadListFile -State $State -Files $changeSet.files
    }
    Stop-DevBranchRuntimeBeforeInfobaseMutation -State $State -Reason "$ContentKind source load" -InfoBasePath $InfoBasePath
    Set-RunStage -Stage "config-load.designer" -Detail "Loading $ContentKind source through Designer in $Mode mode."
    $orchestration = Invoke-ConfigLoadWithFallback `
        -InfoBasePath $InfoBasePath `
        -InfoBaseKind $InfoBaseKind `
        -State $State `
        -AbsoluteExportPath $changeSet.absoluteExportPath `
        -ListFilePath $listFilePath `
        -FileCount $changeSet.files.Count `
        -ExtensionName $ExtensionName `
        -Mode $Mode
    Set-RunStage -Stage "config-load.loaded" -Detail "Designer completed the $ContentKind source load."

    $loadedAt = (Get-Date).ToString("o")
    $statePath = if ($State) { [string](Get-StateValue -State $State -Name "statePath" -Default "") } else { "" }
    if ($statePath -and (Test-Path -LiteralPath $statePath -PathType Leaf -ErrorAction SilentlyContinue)) {
        Update-DevBranchState -State $State -Updates @{
            $fingerprintField = $source.fingerprint
            $loadedAtField = $loadedAt
            enterpriseNormalizationStatus = "pending"
            enterpriseNormalizationReason = "config-load"
            enterpriseNormalizationError = ""
        }
    }

    return [pscustomobject]@{
        loaded = $true
        fileCount = $changeSet.files.Count
        listFile = $listFilePath
        currentCommit = $changeSet.currentCommit
        lastLogPath = $orchestration.lastLogPath
        loadModeUsed = $orchestration.loadModeUsed
        partialLogPath = $orchestration.partialLogPath
        fullFallbackLogPath = $orchestration.fullFallbackLogPath
        configLoadStatus = $orchestration.configLoadStatus
        partialError = $orchestration.partialError
        fullFallbackError = $orchestration.fullFallbackError
        normalizationRequired = $true
        sourceFingerprint = $source.fingerprint
        loadReason = $(if ($Mode -eq "Full" -and $changeSet.files[0] -eq "<fingerprint-changed>") { "fingerprint-changed-full-load" } else { "source-fingerprint-changed" })
        designerInvoked = $true
        enterpriseInvoked = $false
    }
}

function Export-DevBranchResultFile {
    param(
        [object]$State,
        [string]$InfoBasePath,
        [string]$InfoBaseKind,
        [ValidateSet("configuration", "extension")]
        [string]$ContentKind = "configuration"
    )

    $artifactDir = Resolve-ProjectPath (Get-ConfigValue -Path "artifactsPath" -Default "build/result")
    New-Item -ItemType Directory -Force -Path $artifactDir | Out-Null

    $safeDevBranchName = Get-StateValue -State $State -Name "safeDevBranchName" -Default "dev-branch"
    $extensionName = ""
    $extension = ".cf"
    $designerArgs = @()
    if ($ContentKind -eq "extension") {
        $extensionName = Require-DevBranchExtensionName -State $State
        $extension = ".cfe"
    }

    $resultPath = Join-Path $artifactDir ($safeDevBranchName + "-" + (Get-Date -Format "yyyyMMdd-HHmmss") + $extension)
    $designerArgs += @("/DumpCfg", $resultPath)
    if ($extensionName) {
        $designerArgs += @("-Extension", $extensionName)
    }

    Invoke-Designer `
        -InfoBasePath $InfoBasePath `
        -InfoBaseKind $InfoBaseKind `
        -DesignerArgs $designerArgs | Out-Null

    return $resultPath
}

function Get-GitCommitOrEmpty {
    param([string]$Revision)

    if (-not $Revision) {
        return ""
    }

    $output = & git -C $script:ProjectRoot rev-parse --verify $Revision 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $output) {
        return ""
    }

    return ([string]$output).Trim()
}

function New-ResultManifest {
    param(
        [object]$State,
        [string]$ResultPath,
        [ValidateSet("cf", "cfe")]
        [string]$ResultKind,
        [string]$Operation,
        [string]$MasterCommit = "",
        [string]$DevBranchCommit = "",
        [bool]$UnverifiedOverride = $false
    )

    $artifactPath = [System.IO.Path]::GetFullPath($ResultPath)
    if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
        throw "Result artifact was not found for manifest creation: $artifactPath"
    }

    $artifact = Get-Item -LiteralPath $artifactPath
    $artifactHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $artifactPath).Hash.ToLowerInvariant()
    $verification = Get-VerificationState -State $State
    $manifestPath = "$artifactPath.manifest.json"

    $manifest = [ordered]@{
        schemaVersion = 1
        operation = $Operation
        createdAt = (Get-Date).ToString("o")
        artifact = [ordered]@{
            path = $artifactPath
            name = $artifact.Name
            kind = $ResultKind
            sha256 = $artifactHash
        }
        branch = [ordered]@{
            name = (Get-StateValue -State $State -Name "devBranchName" -Default "")
            safeName = (Get-StateValue -State $State -Name "safeDevBranchName" -Default "")
            gitBranch = (Get-StateValue -State $State -Name "devBranch" -Default "")
            kind = (Get-DevBranchKind -State $State)
            publicationUrl = (Get-StateValue -State $State -Name "publicationUrl" -Default "")
        }
        commits = [ordered]@{
            master = $MasterCommit
            development = $DevBranchCommit
        }
        verification = [ordered]@{
            status = $verification.effectiveStatus
            storedStatus = $verification.status
            freshPassed = [bool]$verification.isFreshPassed
            verifiedAt = $verification.verifiedAt
            verifiedCommit = $verification.verifiedCommit
            currentCommit = $verification.currentCommit
            reportPath = $verification.reportPath
            logPath = $verification.logPath
            reason = $verification.reason
        }
        latest1cLogPath = [string]$script:LastLogPath
        unverifiedOverride = [bool]$UnverifiedOverride
        manualImportNote = "Import this CF/CFE into the source infobase manually after backup and normal acceptance checks. The ITL helper does not load development branch changes into the source infobase."
    }

    Write-Utf8Text -Path $manifestPath -Value (($manifest | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
    return $manifestPath
}

function Get-AiRules1cTools {
    return @(Get-AgentTargets)
}

function Get-AiRules1cProjectManifest {
    $manifestPath = Join-Path $script:ProjectRoot ".ai-rules.json"
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        return $null
    }

    try {
        return (Read-Utf8Text -Path $manifestPath | ConvertFrom-Json)
    } catch {
        throw "ai_rules_1c manifest cannot be read: $manifestPath. $($_.Exception.Message)"
    }
}

function Get-AiRules1cManifestToolNames {
    param([AllowNull()][object]$Manifest = (Get-AiRules1cProjectManifest))

    if ($null -eq $Manifest -or $null -eq $Manifest.tools) {
        return @()
    }
    return @($Manifest.tools | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } | Where-Object { $_ } | Select-Object -Unique)
}

function Get-AiRules1cManifestFileEntries {
    param([AllowNull()][object]$Manifest = (Get-AiRules1cProjectManifest))

    if ($null -eq $Manifest -or $null -eq $Manifest.files) {
        return @()
    }

    return @($Manifest.files.PSObject.Properties | ForEach-Object {
        [pscustomobject]@{
            target = [string]$_.Name
            source = [string]$_.Value.source
            installedHash = [string](Get-ConfigValueFromObject -Object $_.Value -Path "installedHash" -Default "")
            userModified = [bool](Get-ConfigValueFromObject -Object $_.Value -Path "userModified" -Default $false)
        }
    })
}

function Test-AiRules1cToolInstalled {
    param([string]$Tool)

    if ([string]::IsNullOrWhiteSpace($Tool)) {
        return $false
    }
    return (@(Get-AiRules1cManifestToolNames) -contains $Tool.Trim().ToLowerInvariant())
}

function Assert-AiRules1cToolAdapters {
    param(
        [string]$RulesDir,
        [string[]]$Tools
    )

    foreach ($tool in @($Tools | Select-Object -Unique)) {
        if ($tool -notmatch '^[a-z0-9][a-z0-9-]*$') {
            throw "Invalid ai_rules_1c tool id: '$tool'."
        }
        $adapterPath = Join-Path $RulesDir ("adapters\$tool.yaml")
        if (-not (Test-Path -LiteralPath $adapterPath -PathType Leaf)) {
            throw "ai_rules_1c adapter is not available for '$tool': adapters/$tool.yaml"
        }
    }
}

function Get-AiRules1cOpenSpecBundleValidation {
    param(
        [string]$RulesDir,
        [string]$Tool,
        [AllowNull()][object]$Manifest = (Get-AiRules1cProjectManifest)
    )

    $bundleDir = Join-Path $RulesDir ("content\openspec-bundle\$Tool")
    if (-not (Test-Path -LiteralPath $bundleDir -PathType Container)) {
        return [pscustomobject]@{
            hasBundle = $false
            isValid = $true
            missing = @()
        }
    }

    $bundleRoot = (Resolve-Path -LiteralPath $bundleDir).Path.TrimEnd('\', '/')
    $bundleFiles = @(Get-ChildItem -LiteralPath $bundleDir -Recurse -File -ErrorAction Stop)
    $entries = @(Get-AiRules1cManifestFileEntries -Manifest $Manifest)
    $missing = @()
    foreach ($bundleFile in $bundleFiles) {
        $relative = $bundleFile.FullName.Substring($bundleRoot.Length + 1).Replace('\', '/')
        $sourceSuffix = "content/openspec-bundle/$Tool/$relative"
        # A shared destination can legitimately be owned by another selected bundle
        # after installer de-duplication. Accept that winner by destination, while
        # retaining source matching for adapter mappings that rewrite destinations.
        $matches = @($entries | Where-Object {
            $_.source.Replace('\', '/') -eq $sourceSuffix -or
            $_.target.Replace('\', '/').TrimStart('/') -eq $relative.TrimStart('/')
        })
        if ($matches.Count -eq 0) {
            $missing += $relative
            continue
        }
        foreach ($match in $matches) {
            if (-not (Test-Path -LiteralPath (Join-Path $script:ProjectRoot $match.target) -PathType Leaf)) {
                $missing += $relative
                break
            }
        }
    }

    return [pscustomobject]@{
        hasBundle = ($bundleFiles.Count -gt 0)
        isValid = ($missing.Count -eq 0)
        missing = @($missing | Select-Object -Unique)
    }
}

function Assert-AiRules1cInstallation {
    param(
        [string]$RulesDir,
        [string[]]$DesiredTools
    )

    $manifest = Get-AiRules1cProjectManifest
    if ($null -eq $manifest) {
        throw "ai_rules_1c installer completed without .ai-rules.json."
    }

    $installedTools = @(Get-AiRules1cManifestToolNames -Manifest $manifest)
    $missingTools = @($DesiredTools | Where-Object { $installedTools -notcontains $_ })
    if ($missingTools.Count -gt 0) {
        throw "ai_rules_1c installer did not activate required tool(s): $($missingTools -join ', ')."
    }
    $unexpectedTools = @($installedTools | Where-Object { $DesiredTools -notcontains $_ })
    if ($unexpectedTools.Count -gt 0 -or $installedTools.Count -ne 1 -or $DesiredTools.Count -ne 1) {
        throw "ai_rules_1c installation must contain exactly the configured client. Configured: $($DesiredTools -join ', '). Installed: $($installedTools -join ', ')."
    }

    foreach ($tool in $DesiredTools) {
        $bundle = Get-AiRules1cOpenSpecBundleValidation -RulesDir $RulesDir -Tool $tool -Manifest $manifest
        if ($bundle.hasBundle -and -not $bundle.isValid) {
            throw "ai_rules_1c OpenSpec bundle for '$tool' is incomplete: $($bundle.missing -join ', ')."
        }
    }

    return $manifest
}

function Get-ItlOpenSpecCliStatus {
    $command = @(Get-Command openspec -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($command.Count -eq 0) {
        return [pscustomobject]@{ available = $false; path = "" }
    }
    $path = [string]$command[0].Path
    if ([string]::IsNullOrWhiteSpace($path)) { $path = [string]$command[0].Source }
    return [pscustomobject]@{ available = $true; path = $path }
}

function Get-ItlOpenSpecNaturalRequests {
    function ConvertFrom-ItlUtf8Base64 {
        param([string]$Value)
        return [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($Value))
    }

    return [pscustomobject]@{
        explore = ConvertFrom-ItlUtf8Base64 "0JjRgdGB0LvQtdC00YPQuSDQt9Cw0LTQsNGH0YMg0LIg0YDQtdC20LjQvNC1IE9wZW5TcGVjLCDQvdC1INGB0L7Qt9C00LDQstCw0Y8gcHJvcG9zYWwg0Lgg0L3QtSDQvNC10L3Rj9GPINC60L7QtA=="
        propose = ConvertFrom-ItlUtf8Base64 "0J/QvtC00LPQvtGC0L7QstGMIE9wZW5TcGVjIHByb3Bvc2FsINC00LvRjyA80LjQt9C80LXQvdC10L3QuNC1Pjsg0YHQvtC30LTQsNC5IHByb3Bvc2FsLCBkZXNpZ24sIHRhc2tzLCB0ZXN0LXBsYW4g0Lggc3BlYyBkZWx0YXM7INC60L7QtCDQvdC1INC80LXQvdGP0Lk="
        apply = ConvertFrom-ItlUtf8Base64 "0KDQtdCw0LvQuNC30YPQuSDRgdC+0LPQu9Cw0YHQvtCy0LDQvdC90YvQuSBPcGVuU3BlYyBjaGFuZ2UgPGNoYW5nZS1pZD4g0L/QviB0YXNrcy5tZCDQuCB0ZXN0LXBsYW4ubWQ="
        archive = ConvertFrom-ItlUtf8Base64 "0JfQsNCw0YDRhdC40LLQuNGA0YPQuSDQv9GA0LjQvdGP0YLRi9C5IE9wZW5TcGVjIGNoYW5nZSA8Y2hhbmdlLWlkPiDQuCDRgdC40L3RhdGA0L7QvdC40LfQuNGA0YPQuSBzcGVjcw=="
    }
}

function Get-ItlOpenSpecNativeInvocation {
    param(
        [string]$Stage,
        [AllowNull()][object]$Entry
    )

    $target = [string](Get-ConfigValueFromObject -Object $Entry -Path "target" -Default "")
    $target = $target.Replace('\', '/')
    if ($target -match '(?i)/skills/([^/]+)/SKILL\.md$') {
        return "skill $($Matches[1])"
    }
    if ($target -match '(?i)/commands/opsx/[^/]+\.md$') {
        return "/opsx:$Stage"
    }
    if ($target -match '(?i)(?:^|/)opsx-[^/]+\.md$') {
        return "/opsx-$Stage"
    }
    return "managed artifact $target"
}

function New-ItlOpenSpecStatus {
    param(
        [ValidateSet("native", "natural", "unavailable")][string]$Mode,
        [string]$Reason = "",
        [AllowNull()][object]$Invocations = $null,
        [AllowNull()][object]$Cli = $null
    )

    if ($null -eq $Cli) { $Cli = Get-ItlOpenSpecCliStatus }
    if ($null -eq $Invocations) { $Invocations = [ordered]@{} }
    return [pscustomobject]@{
        mode = $Mode
        isAvailable = ($Mode -ne "unavailable")
        required = $true
        reason = $Reason
        invocations = [pscustomobject]$Invocations
        cliAvailable = [bool]$Cli.available
        cliPath = [string]$Cli.path
    }
}

function Get-AiRules1cOpenSpecStatus {
    $requiredStages = [ordered]@{
        propose = @("openspec-propose", "opsx-propose")
        explore = @("openspec-explore", "opsx-explore")
        apply = @("openspec-apply-change", "opsx-apply")
        archive = @("openspec-archive-change", "opsx-archive")
    }
    $cli = Get-ItlOpenSpecCliStatus
    try {
        $manifest = Get-AiRules1cProjectManifest
    } catch {
        return (New-ItlOpenSpecStatus -Mode unavailable -Reason $_.Exception.Message -Cli $cli)
    }

    if ($null -eq $manifest) {
        return (New-ItlOpenSpecStatus -Mode unavailable -Reason "ai_rules_1c manifest is missing." -Cli $cli)
    }
    try { $client = Get-ItlActiveClient } catch { return (New-ItlOpenSpecStatus -Mode unavailable -Reason $_.Exception.Message -Cli $cli) }

    $entries = @(Get-AiRules1cManifestFileEntries -Manifest $manifest)
    $requiredWorkspace = @(
        "openspec/README.md",
        "openspec/config.yaml",
        "openspec/project.md",
        "openspec/specs/README.md",
        "openspec/changes/README.md"
    )
    $missingWorkspace = @($requiredWorkspace | Where-Object {
        -not (Test-Path -LiteralPath (Join-Path $script:ProjectRoot $_) -PathType Leaf)
    })
    if ($missingWorkspace.Count -gt 0) {
        return (New-ItlOpenSpecStatus -Mode unavailable -Reason "OpenSpec workspace is incomplete: $($missingWorkspace -join ', ')." -Cli $cli)
    }

    $integrationRuleEntries = @($entries | Where-Object {
        $_.source.Replace('\', '/') -eq "content/rules/sdd-integrations.md"
    })
    if ($integrationRuleEntries.Count -eq 0) {
        return (New-ItlOpenSpecStatus -Mode unavailable -Reason "managed OpenSpec integration rule is absent from the ai_rules_1c manifest." -Cli $cli)
    }
    $badRules = @($integrationRuleEntries | Where-Object {
        $path = Join-Path $script:ProjectRoot $_.target
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $true }
        $expected = [string](Get-ConfigValueFromObject -Object $_ -Path "installedHash" -Default "")
        return (-not [string]::IsNullOrWhiteSpace($expected) -and (Get-ItlFileSha256 -Path $path) -ne $expected.ToLowerInvariant())
    })
    if ($badRules.Count -gt 0) {
        return (New-ItlOpenSpecStatus -Mode unavailable -Reason "managed OpenSpec integration rule is missing or damaged." -Cli $cli)
    }

    $userRulesPath = Join-Path $script:ProjectRoot "USER-RULES.md"
    if (-not (Test-Path -LiteralPath $userRulesPath -PathType Leaf)) {
        return (New-ItlOpenSpecStatus -Mode unavailable -Reason "USER-RULES.md with the ITL OpenSpec preflight is missing." -Cli $cli)
    }
    $userRulesText = Get-Content -LiteralPath $userRulesPath -Raw -Encoding UTF8
    $requiredRuleTokens = @("ITL-WORKFLOW-USER-RULES:START", "Context Sources", "test-plan.md", "fresh")
    $missingRuleTokens = @($requiredRuleTokens | Where-Object { $userRulesText -notmatch [regex]::Escape($_) })
    if ($missingRuleTokens.Count -gt 0) {
        return (New-ItlOpenSpecStatus -Mode unavailable -Reason "USER-RULES.md does not contain the complete ITL OpenSpec preflight." -Cli $cli)
    }

    $clientBundleEntries = @($entries | Where-Object { $_.source.Replace('\', '/') -like "content/openspec-bundle/$client/*" })
    if ($clientBundleEntries.Count -eq 0) {
        $skippedProperty = $manifest.integrations.openspec.PSObject.Properties['bundleSkipped']
        $skipped = if ($null -eq $skippedProperty) { @() } else { @($skippedProperty.Value) }
        if ($skipped -contains $client) {
            return (New-ItlOpenSpecStatus -Mode natural -Reason "the pinned adapter intentionally skipped a native OpenSpec bundle for $client" -Cli $cli)
        }
        return (New-ItlOpenSpecStatus -Mode unavailable -Reason "the manifest neither owns a native OpenSpec bundle nor records an intentional bundleSkipped entry for $client." -Cli $cli)
    }

    $damagedBundleEntries = @($clientBundleEntries | Where-Object {
        $path = Join-Path $script:ProjectRoot $_.target
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $true }
        $expected = [string](Get-ConfigValueFromObject -Object $_ -Path "installedHash" -Default "")
        return ([string]::IsNullOrWhiteSpace($expected) -or (Get-ItlFileSha256 -Path $path) -ne $expected.ToLowerInvariant())
    })
    if ($damagedBundleEntries.Count -gt 0) {
        $targets = @($damagedBundleEntries | ForEach-Object { [string]$_.target } | Select-Object -Unique)
        return (New-ItlOpenSpecStatus -Mode unavailable -Reason "managed native OpenSpec artifact(s) for $client are missing or damaged: $($targets -join ', ')." -Cli $cli)
    }

    $missing = @()
    $invocations = [ordered]@{}
    foreach ($stage in $requiredStages.Keys) {
        $tokens = @($requiredStages[$stage])
        $matches = @($entries | Where-Object {
            $source = $_.source.Replace('\', '/')
            @($tokens | Where-Object { $source -match ("/" + [regex]::Escape($_) + "(?:/SKILL)?\.md$") }).Count -gt 0
        })
        if ($matches.Count -eq 0) {
            $missing += $stage
            continue
        }
        $invocations[$stage] = Get-ItlOpenSpecNativeInvocation -Stage $stage -Entry $matches[0]
    }

    if ($missing.Count -gt 0) {
        return (New-ItlOpenSpecStatus -Mode unavailable -Reason "managed native OpenSpec phase(s) for $client are absent from the manifest: $($missing -join ', ')." -Cli $cli)
    }
    return (New-ItlOpenSpecStatus -Mode native -Invocations $invocations -Cli $cli)
}

function Get-AiRules1cRepositoryIdentity {
    param([string]$Repo)

    if ([string]::IsNullOrWhiteSpace($Repo)) {
        return ""
    }
    $identity = $Repo.Trim().Replace('\', '/').TrimEnd('/').ToLowerInvariant()
    if ($identity.EndsWith('.git')) {
        $identity = $identity.Substring(0, $identity.Length - 4)
    }
    return $identity
}

function Test-AiRules1cForkRepository {
    param([string]$Repo)
    return (Get-AiRules1cRepositoryIdentity -Repo $Repo) -eq "https://github.com/xmentosx/itl_ai_rules_1c"
}

function Sync-AiRules1cCheckout {
    param(
        [string]$RepoOverride = "",
        [string]$RefOverride = "",
        [string]$CommitOverride = ""
    )

    $lockedEntry = Get-DependencyLockEntry -Name "aiRules1c"
    $repo = $(if ($RepoOverride) { $RepoOverride } else { Get-ConfigValue -Path "aiRules.repo" -Default "https://github.com/xmentosx/itl_ai_rules_1c.git" })
    $configuredRef = $(if ($RefOverride) { $RefOverride } else { [string](Get-ConfigValue -Path "aiRules.ref" -Default "") })
    $dependencyMode = Get-DependencyMode
    $lockedRef = ""
    $lockedCommit = ""
    if ($CommitOverride) {
        $lockedCommit = $CommitOverride
    }
    if ($dependencyMode -eq "locked" -and -not $RepoOverride) {
        $lockedRepo = [string](Get-ConfigValueFromObject -Object $lockedEntry -Path "repo" -Default "")
        $lockedRef = [string](Get-ConfigValueFromObject -Object $lockedEntry -Path "ref" -Default "")
        $lockedCommit = [string](Get-ConfigValueFromObject -Object $lockedEntry -Path "commit" -Default "")
        if ($lockedRepo) {
            $repo = $lockedRepo
        }
        if (-not $lockedRef -and -not $lockedCommit) {
            throw "Dependency mode is locked, but aiRules1c.ref and aiRules1c.commit are empty in .agent-1c/dependency-lock.json."
        }
    } elseif ($configuredRef -and -not $CommitOverride) {
        $baselineRepo = [string](Get-ConfigValueFromObject -Object $lockedEntry -Path "repo" -Default "")
        $baselineRef = [string](Get-ConfigValueFromObject -Object $lockedEntry -Path "ref" -Default "")
        if ((Get-AiRules1cRepositoryIdentity -Repo $baselineRepo) -eq (Get-AiRules1cRepositoryIdentity -Repo $repo) -and $baselineRef -eq $configuredRef) {
            $lockedCommit = [string](Get-ConfigValueFromObject -Object $lockedEntry -Path "commit" -Default "")
        }
    }
    if ($RefOverride) {
        $lockedRef = $RefOverride
    }

    if ((Test-AiRules1cForkRepository -Repo $repo) -and -not ($configuredRef -or $lockedRef)) {
        throw "The controlled ai_rules_1c fork requires an immutable configured tag in aiRules.ref; fork main is not allowed."
    }

    $tempRoot = Get-Agent1cTempRoot
    $rulesDir = Resolve-Agent1cFullPath -Path (Join-Path $tempRoot "ai_rules_1c")

    if (Test-Path -LiteralPath $rulesDir) {
        try {
            $currentOrigin = (Get-GitOutputAt -Root $rulesDir -Arguments @("remote", "get-url", "origin")).Trim()
            if ((Get-AiRules1cRepositoryIdentity -Repo $currentOrigin) -ne (Get-AiRules1cRepositoryIdentity -Repo $repo)) {
                Invoke-GitAt -Root $rulesDir -Arguments @("remote", "set-url", "origin", $repo)
            }
            Invoke-GitAt -Root $rulesDir -Arguments @("fetch", "--all", "--tags", "--prune")
        } catch {
            throw "Failed to update ai_rules_1c in $rulesDir"
        }
    } else {
        try {
            Invoke-GitAt -Root $tempRoot -Arguments @("clone", $repo, $rulesDir)
        } catch {
            throw "Failed to clone ai_rules_1c from $repo"
        }
    }

    $resolvedRef = ""
    $effectiveTagRef = $(if ($configuredRef) { $configuredRef } elseif (Test-AiRules1cForkRepository -Repo $repo) { $lockedRef } else { "" })
    if ($effectiveTagRef) {
        if ((Test-AiRules1cForkRepository -Repo $repo) -and $effectiveTagRef -notlike "itl-*") {
            throw "Controlled fork ref must be an immutable ITL tag matching 'itl-*': $effectiveTagRef"
        }
        $tagRef = "refs/tags/$effectiveTagRef"
        if (-not (Test-GitRefExistsAt -Root $rulesDir -Ref $tagRef)) {
            throw "Configured ai_rules_1c ref is not an available tag: $effectiveTagRef"
        }
        $tagCommit = (Get-GitOutputAt -Root $rulesDir -Arguments @("rev-parse", "$tagRef^{commit}")).Trim()
        if ($lockedCommit -and $tagCommit -ne $lockedCommit) {
            throw "ai_rules_1c tag/commit mismatch for '$effectiveTagRef': tag=$tagCommit lock=$lockedCommit"
        }
        try {
            Invoke-GitAt -Root $rulesDir -Arguments @("checkout", "--detach", $tagCommit)
        } catch {
            throw "Failed to checkout pinned ai_rules_1c tag '$effectiveTagRef' in $rulesDir"
        }
        $resolvedRef = $effectiveTagRef
    } elseif ($dependencyMode -eq "locked" -or $lockedCommit) {
        $checkoutTarget = $(if ($lockedCommit) { $lockedCommit } else { $lockedRef })
        try {
            Invoke-GitAt -Root $rulesDir -Arguments @("checkout", "--detach", $checkoutTarget)
        } catch {
            throw "Failed to checkout locked ai_rules_1c revision '$checkoutTarget' in $rulesDir"
        }
        $resolvedRef = $checkoutTarget
    } else {
        try {
            $originHead = (Get-GitOutputAt -Root $rulesDir -Arguments @("symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD")).Trim()
            if (-not $originHead) {
                $originHead = "origin/HEAD"
            }
            Invoke-GitAt -Root $rulesDir -Arguments @("checkout", "--detach", $originHead)
            $resolvedRef = $originHead
        } catch {
            throw "Failed to checkout latest ai_rules_1c origin HEAD in $rulesDir"
        }
    }

    return [pscustomobject]@{
        root = $rulesDir
        repo = $repo
        ref = $resolvedRef
        commit = (Get-GitOutputAt -Root $rulesDir -Arguments @("rev-parse", "HEAD")).Trim()
    }
}

function Invoke-AiRules1cInstaller {
    param(
        [ValidateSet("init", "update")]
        [string]$Command
    )

    $checkout = Sync-AiRules1cCheckout
    $rulesDir = Resolve-Agent1cFullPath -Path ([string]$checkout.root)
    $desiredTools = @(Get-AiRules1cTools)
    Assert-AiRules1cToolAdapters -RulesDir $rulesDir -Tools $desiredTools
    $installScript = Join-Path $rulesDir "install.ps1"
    if (-not (Test-Path -LiteralPath $installScript)) {
        throw "ai_rules_1c install.ps1 was not found: $installScript"
    }

    $manifestPath = Join-Path $script:ProjectRoot ".ai-rules.json"
    $effectiveCommand = $Command
    if ($Command -eq "update" -and -not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        Write-Host "ai_rules_1c manifest was not found; running init instead of update."
        $effectiveCommand = "init"
    }

    if ($effectiveCommand -eq "update") {
        $installedToolsBeforeUpdate = @(Get-AiRules1cManifestToolNames)
        $toolDifference = @(Compare-Object -ReferenceObject @($desiredTools) -DifferenceObject @($installedToolsBeforeUpdate))
        if ($toolDifference.Count -gt 0) {
            if (Test-AiRulesManifestHasUserChanges) {
                throw "Cannot replace the active ai_rules_1c client because managed files are marked userModified. Resolve those files explicitly first."
            }
            Write-Host "Replacing ai_rules_1c client set transactionally: [$($installedToolsBeforeUpdate -join ', ')] -> [$($desiredTools -join ', ')]."
            Push-Location (Resolve-Agent1cFullPath -Path $script:ProjectRoot)
            try {
                & powershell -NoProfile -ExecutionPolicy Bypass -File $installScript remove -ProjectRoot $script:ProjectRoot -Source $rulesDir -McpMode delegated -AssumeYes
                if ($LASTEXITCODE -ne 0) {
                    throw "ai_rules_1c remove failed with exit code $LASTEXITCODE"
                }
            } finally {
                Pop-Location
            }
            $effectiveCommand = "init"
        }
    }

    $installArgs = @(
        $effectiveCommand,
        "-ProjectRoot", (Resolve-Agent1cFullPath -Path $script:ProjectRoot),
        "-Source", $rulesDir,
        "-McpMode", "delegated",
        "-AssumeYes"
    )
    if ($effectiveCommand -eq "init") {
        $installArgs += @("-Tools") + $desiredTools
    } elseif ($Force) {
        $installArgs += @("-Force")
    }

    Push-Location (Resolve-Agent1cFullPath -Path $script:ProjectRoot)
    try {
        & powershell -NoProfile -ExecutionPolicy Bypass -File $installScript @installArgs
        if ($LASTEXITCODE -ne 0) {
            throw "ai_rules_1c installer failed with exit code $LASTEXITCODE"
        }
    } finally {
        Pop-Location
    }

    Assert-AiRules1cInstallation -RulesDir $rulesDir -DesiredTools $desiredTools | Out-Null

    $configuredRaw = @(ConvertTo-AgentToolList -Value (Get-ConfigValue -Path "aiRules.tools" -Default @()))
    if ($configuredRaw.Count -ne 1 -or $configuredRaw[0] -ne $desiredTools[0]) {
        Set-ProjectAiRulesClient -Client $desiredTools[0]
        Read-ProjectConfig
    }

    Invoke-AiRules1cManagedMcpConfigReconcile -Operation "ai_rules_1c $effectiveCommand" | Out-Null

    $commit = (Get-GitOutputAt -Root $rulesDir -Arguments @("rev-parse", "HEAD")).Trim()
    Update-DependencyLockEntry -Name "aiRules1c" -Values @{
        repo = [string]$checkout.repo
        ref = [string]$checkout.ref
        commit = $commit
    }

    Write-Host "ai_rules_1c $effectiveCommand completed at commit $commit."
}

function Get-AiRules1cManagedMcpServerIds {
    return @(
        "1c-code-metadata-mcp",
        "1c-syntax-checker-mcp",
        "1C-docs-mcp",
        "1c-templates-mcp",
        "1c-graph-metadata-mcp",
        "1c-code-check-mcp",
        "1c-ssl-mcp",
        "1c-data-mcp"
    )
}

function Test-AiRules1cMcpEntryCanBeRemoved {
    param([string]$ManagedBy)

    return [string]::IsNullOrWhiteSpace($ManagedBy) -or $ManagedBy -eq "1c-rules" -or $ManagedBy -eq "ai_rules_1c"
}

function Get-AiRules1cTomlMcpManagedBy {
    param([string]$SectionText)

    $match = [regex]::Match($SectionText, "(?im)^\s*managedBy\s*=\s*[""']?(?<value>[^""'#\r\n]+)")
    if ($match.Success) {
        return $match.Groups["value"].Value.Trim()
    }
    return ""
}

function Test-TextIndexInsideVibecoding1cMcpManagedBlock {
    param(
        [string]$Text,
        [int]$Index
    )

    foreach ($match in [regex]::Matches($Text, "(?ms)^# >>> vibecoding1c-mcp\b.*?^# <<< vibecoding1c-mcp\b.*?(?:\r?\n|$)")) {
        if ($Index -ge $match.Index -and $Index -lt ($match.Index + $match.Length)) {
            return $true
        }
    }
    return $false
}

function Remove-AiRules1cCodexMcpEntries {
    param([string[]]$ServerIds)

    $path = Join-Path $script:ProjectRoot ".codex\config.toml"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return @()
    }

    $text = Read-Utf8Text -Path $path
    $removed = @()
    foreach ($serverId in $ServerIds) {
        $escaped = [regex]::Escape($serverId)
        $patterns = @(
            "(?ms)^\[mcp_servers\.`"$escaped`"\]\r?\n.*?(?=^\[|^# >>> vibecoding1c-mcp|\z)",
            "(?ms)^\[mcp_servers\.$escaped\]\r?\n.*?(?=^\[|^# >>> vibecoding1c-mcp|\z)"
        )
        foreach ($pattern in $patterns) {
            $matches = @([regex]::Matches($text, $pattern) | Sort-Object Index -Descending)
            foreach ($match in $matches) {
                if (Test-TextIndexInsideVibecoding1cMcpManagedBlock -Text $text -Index $match.Index) {
                    continue
                }

                $managedBy = Get-AiRules1cTomlMcpManagedBy -SectionText $match.Value
                if (-not (Test-AiRules1cMcpEntryCanBeRemoved -ManagedBy $managedBy)) {
                    continue
                }

                $text = $text.Remove($match.Index, $match.Length)
                if ($removed -notcontains $serverId) {
                    $removed += $serverId
                }
            }
        }
    }

    if ($removed.Count -gt 0) {
        Write-Utf8Text -Path $path -Value ($text.TrimEnd() + [Environment]::NewLine)
    }

    return $removed
}

function Remove-AiRules1cKiloMcpEntries {
    param([string[]]$ServerIds)

    $path = Join-Path $script:ProjectRoot ".kilo\kilo.json"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return @()
    }

    try {
        $config = ConvertTo-Vibecoding1cMcpHashtable -Object ((Read-Utf8Text -Path $path) | ConvertFrom-Json)
    } catch {
        Write-Warning "Could not parse Kilo MCP config for ai_rules_1c cleanup: $path. $($_.Exception.Message)"
        return @()
    }

    if (-not $config.Contains("mcp")) {
        return @()
    }

    $mcp = ConvertTo-Vibecoding1cMcpHashtable -Object $config["mcp"]
    $removed = @()
    $kiloServerIds = @($ServerIds)
    foreach ($serverId in @($ServerIds)) {
        if ($serverId -match '^(?i)1c(?<suffix>.*)$') {
            $kiloServerIds += ("onec" + $Matches["suffix"])
        }
    }
    foreach ($serverId in @($kiloServerIds | Select-Object -Unique)) {
        if (-not $mcp.Contains($serverId)) {
            continue
        }

        $entry = ConvertTo-Vibecoding1cMcpHashtable -Object $mcp[$serverId]
        $managedBy = [string](Get-Vibecoding1cMcpObjectValue -Object $entry -Name "managedBy" -Default "")
        if (-not (Test-AiRules1cMcpEntryCanBeRemoved -ManagedBy $managedBy)) {
            continue
        }

        $mcp.Remove($serverId)
        $removed += $serverId
    }

    if ($removed.Count -gt 0) {
        $config["mcp"] = $mcp
        Write-Utf8Text -Path $path -Value (($config | ConvertTo-Json -Depth 20) + [Environment]::NewLine)
    }

    return $removed
}

function Remove-AiRules1cManagedMcpConfig {
    param([string[]]$ServerIds = @())

    $serverIds = @($ServerIds | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    if ($serverIds.Count -eq 0) {
        $serverIds = Get-AiRules1cManagedMcpServerIds
    }

    $removed = @()
    $removed += @(Remove-AiRules1cCodexMcpEntries -ServerIds $serverIds)
    $removed += @(Remove-AiRules1cKiloMcpEntries -ServerIds $serverIds)
    $removed = @($removed | Select-Object -Unique)

    if ($removed.Count -gt 0) {
        Write-Host "Removed ai_rules_1c default MCP client entries; ITL vibecoding1c MCP owns client config: $($removed -join ', ')."
    }
    return @($removed)
}

function Get-AiRules1cMcpClientConfigPaths {
    try {
        $adapter = Get-ItlClientAdapter -Client ([string](@(Get-AgentTargets) | Select-Object -First 1))
        return @((Join-Path $script:ProjectRoot $adapter.mcpPath))
    } catch {
        return @()
    }
}

function Get-AiRules1cKiloOpenSpecStatus {
    return (Get-AiRules1cOpenSpecStatus)
}

function New-AiRules1cMcpConfigSnapshot {
    param([string[]]$Paths)

    $snapshot = [ordered]@{}
    foreach ($path in @($Paths)) {
        if ([string]::IsNullOrWhiteSpace($path) -or $snapshot.Contains($path)) {
            continue
        }

        $exists = Test-Path -LiteralPath $path -PathType Leaf -ErrorAction SilentlyContinue
        $snapshot[$path] = [pscustomobject]@{
            exists = $exists
            bytes = $(if ($exists) { [System.IO.File]::ReadAllBytes($path) } else { [byte[]]@() })
        }
    }
    return $snapshot
}

function Restore-AiRules1cMcpConfigSnapshot {
    param([object]$Snapshot)

    foreach ($path in @($Snapshot.Keys)) {
        $entry = $Snapshot[$path]
        if ([bool]$entry.exists) {
            $parent = Split-Path -Parent $path
            if ($parent) {
                New-Item -ItemType Directory -Force -Path $parent | Out-Null
            }
            [System.IO.File]::WriteAllBytes($path, [byte[]]$entry.bytes)
        } elseif (Test-Path -LiteralPath $path -PathType Leaf -ErrorAction SilentlyContinue) {
            Remove-Item -LiteralPath $path -Force
        }
    }
}

function Write-AiRules1cMcpPreservedWarning {
    param(
        [string]$Operation,
        [string[]]$Reasons = @()
    )

    Write-Host "WARNING: ai_rules_1c default MCP client entries were preserved during $Operation because ITL vibecoding1c MCP client config is not ready."
    foreach ($reason in @($Reasons | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        Write-Host "  - $reason"
    }
    Write-Host "Complete MCP setup when ready:"
    Write-Host "  powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action vibecoding1c-mcp-setup"
}

function Test-StaleAiRules1cDataMcpShouldBePruned {
    $publishUrl = [string](Get-EnvValue -Name "INFOBASE_PUBLISH_URL" -Default "")
    if (-not [string]::IsNullOrWhiteSpace($publishUrl) -or (Get-WebPublishByDefault)) {
        return $false
    }

    try {
        $state = Read-DevBranchState -Name ""
        $stateUrl = [string](Get-StateValue -State $state -Name "publicationUrl" -Default "")
        $stateStatus = [string](Get-StateValue -State $state -Name "publicationStatus" -Default "")
        if ($stateUrl -or ($stateStatus -and $stateStatus -notin @("disabled", "skipped"))) {
            return $false
        }
    } catch {
    }
    return $true
}

function Remove-StaleAiRules1cDataMcpConfig {
    if (-not (Test-StaleAiRules1cDataMcpShouldBePruned)) {
        return @()
    }

    $removed = @()
    $codexPath = Join-Path $script:ProjectRoot ".codex\config.toml"
    if (Test-Path -LiteralPath $codexPath -PathType Leaf -ErrorAction SilentlyContinue) {
        $text = Read-Utf8Text -Path $codexPath
        $pattern = '(?ms)^\[mcp_servers\.(?:"1c-data-mcp"|1c-data-mcp)\]\r?\n.*?(?=^\[|^# >>> vibecoding1c-mcp|\z)'
        foreach ($match in @([regex]::Matches($text, $pattern) | Sort-Object Index -Descending)) {
            if (Test-TextIndexInsideVibecoding1cMcpManagedBlock -Text $text -Index $match.Index) { continue }
            $managedBy = Get-AiRules1cTomlMcpManagedBy -SectionText $match.Value
            $isManaged = if (-not [string]::IsNullOrWhiteSpace($managedBy)) {
                Test-AiRules1cMcpEntryCanBeRemoved -ManagedBy $managedBy
            } else {
                $match.Value -match '\{INFOBASE_PUBLISH_URL\}/hs/mcp'
            }
            if (-not $isManaged) { continue }
            $text = $text.Remove($match.Index, $match.Length)
            $removed += "codex:1c-data-mcp"
        }
        if ($removed -contains "codex:1c-data-mcp") {
            Write-Utf8Text -Path $codexPath -Value ($text.TrimEnd() + [Environment]::NewLine)
        }
    }

    $kiloPath = Join-Path $script:ProjectRoot ".kilo\kilo.json"
    if (Test-Path -LiteralPath $kiloPath -PathType Leaf -ErrorAction SilentlyContinue) {
        try {
            $config = ConvertTo-Vibecoding1cMcpHashtable -Object ((Read-Utf8Text -Path $kiloPath) | ConvertFrom-Json)
            if ($config.Contains("mcp")) {
                $mcp = ConvertTo-Vibecoding1cMcpHashtable -Object $config["mcp"]
                if ($mcp.Contains("1c-data-mcp")) {
                    $entry = ConvertTo-Vibecoding1cMcpHashtable -Object $mcp["1c-data-mcp"]
                    $managedBy = [string](Get-Vibecoding1cMcpObjectValue -Object $entry -Name "managedBy" -Default "")
                    $url = [string](Get-Vibecoding1cMcpObjectValue -Object $entry -Name "url" -Default "")
                    $isManaged = if (-not [string]::IsNullOrWhiteSpace($managedBy)) {
                        Test-AiRules1cMcpEntryCanBeRemoved -ManagedBy $managedBy
                    } else {
                        $url -match '\{INFOBASE_PUBLISH_URL\}/hs/mcp'
                    }
                    if ($isManaged) {
                        [void]$mcp.Remove("1c-data-mcp")
                        $config["mcp"] = $mcp
                        Write-Utf8Text -Path $kiloPath -Value (($config | ConvertTo-Json -Depth 20) + [Environment]::NewLine)
                        $removed += "kilo:1c-data-mcp"
                    }
                }
            }
        } catch {
            Write-Warning "Could not parse Kilo MCP config while pruning stale ai_rules_1c Data MCP: $kiloPath. $($_.Exception.Message)"
        }
    }

    if ($removed.Count -gt 0) {
        Write-Host "Removed stale ai_rules_1c-managed 1c-data-mcp because publication is disabled and INFOBASE_PUBLISH_URL is empty."
    }
    return @($removed)
}

function Invoke-AiRules1cManagedMcpConfigReconcile {
    param([string]$Operation = "MCP reconcile")

    $managedServerIds = @(Get-AiRules1cManagedMcpServerIds)
    $selection = Read-Vibecoding1cMcpSelection
    $selectionCompleteness = Get-Vibecoding1cMcpSelectionCompleteness -Selection $selection
    if (-not $selectionCompleteness.isComplete) {
        Write-AiRules1cMcpPreservedWarning -Operation $Operation -Reasons $selectionCompleteness.reasons
        return [pscustomobject]@{
            reconciled = $false
            preserved = $true
            replacements = @()
            pruned = @()
        }
    }

    try {
        $readyClientNames = @(Get-Vibecoding1cMcpReadyClientConfigNames)
    } catch {
        Write-AiRules1cMcpPreservedWarning -Operation $Operation -Reasons @("failed to calculate ready vibecoding1c MCP endpoints: $($_.Exception.Message)")
        return [pscustomobject]@{
            reconciled = $false
            preserved = $true
            replacements = @()
            pruned = @()
        }
    }

    $replacementServerIds = @($readyClientNames | Where-Object { $managedServerIds -contains $_ } | Select-Object -Unique)
    if ($replacementServerIds.Count -eq 0) {
        Write-AiRules1cMcpPreservedWarning -Operation $Operation -Reasons @("no ready vibecoding1c MCP endpoints were found in saved state")
        return [pscustomobject]@{
            reconciled = $false
            preserved = $true
            replacements = @()
            pruned = @()
        }
    }

    $snapshot = New-AiRules1cMcpConfigSnapshot -Paths (Get-AiRules1cMcpClientConfigPaths)
    try {
        Write-Vibecoding1cMcpClientConfig
        $removed = @(Remove-AiRules1cManagedMcpConfig -ServerIds $replacementServerIds)
        $pruned = @(Remove-StaleAiRules1cDataMcpConfig)
        $withoutReplacement = @($managedServerIds | Where-Object { $replacementServerIds -notcontains $_ })
        Write-Host "Reconciled ai_rules_1c MCP client entries with ITL vibecoding1c MCP config: $($replacementServerIds -join ', ')."
        if ($withoutReplacement.Count -gt 0) {
            Write-Host "Preserved ai_rules_1c MCP entries without a ready vibecoding1c replacement: $($withoutReplacement -join ', ')."
        }
        return [pscustomobject]@{
            reconciled = $true
            preserved = $false
            replacements = @($replacementServerIds)
            removed = @($removed)
            pruned = @($pruned)
        }
    } catch {
        $errorMessage = $_.Exception.Message
        try {
            Restore-AiRules1cMcpConfigSnapshot -Snapshot $snapshot
        } catch {
            throw "$Operation failed: $errorMessage MCP client config rollback also failed: $($_.Exception.Message)"
        }
        Write-AiRules1cMcpPreservedWarning -Operation $Operation -Reasons @("failed to write replacement client config: $errorMessage")
        return [pscustomobject]@{
            reconciled = $false
            preserved = $true
            replacements = @()
            pruned = @()
        }
    }
}

function Install-AiRules1c {
    if ($SkipAiRules) {
        Write-Host "Skipping ai_rules_1c installation."
        return
    }

    Invoke-AiRules1cInstaller -Command "init"
}

function Update-AiRules1c {
    if ($SkipAiRules) {
        Write-Host "Skipping ai_rules_1c update."
        return
    }

    Invoke-AiRules1cInstaller -Command "update"
    Update-AgentGuidanceBridge
    Update-UserRules
    Sync-KiloItlCommandSurface
}

function Get-WorkflowPackageDefaultRepo {
    return "https://github.com/xmentosx/1c-agent-workflow.git"
}

function Get-WorkflowPackageDefaultRef {
    return "master"
}

function Get-WorkflowPackageRepo {
    $repo = [string](Get-EnvValue -Name "ITL_WORKFLOW_REPO" -Default "")
    if ([string]::IsNullOrWhiteSpace($repo)) {
        return (Get-WorkflowPackageDefaultRepo)
    }
    return $repo
}

function Get-WorkflowPackageRef {
    $ref = [string](Get-EnvValue -Name "ITL_WORKFLOW_REF" -Default "")
    if ([string]::IsNullOrWhiteSpace($ref)) {
        return (Get-WorkflowPackageDefaultRef)
    }
    return $ref
}

function Get-WorkflowPackageTempRoot {
    return (Resolve-Agent1cFullPath -Path (Join-Path (Join-Path (Get-Agent1cTempRoot) "1c-agent-workflow") "workflow-package"))
}

function Test-GitRefExistsAt {
    param(
        [string]$Root,
        [string]$Ref
    )

    $resolvedRoot = Resolve-Agent1cFullPath -Path $Root
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & git -C $resolvedRoot show-ref --verify --quiet $Ref
        return ($LASTEXITCODE -eq 0)
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

function Assert-WorkflowPackageSourceRoot {
    param([string]$SourceRoot)

    foreach ($relativePath in @(
        "install-agent-1c-workflow.ps1",
        "AGENT-INSTALL.md",
        ".agents\skills\1c-workflow\scripts\agent-1c.ps1",
        ".agents\skills\1c-workflow-fast\SKILL.md",
        ".agents\skills\product-docs\SKILL.md",
        ".agents\skills\itl-roctup-1c-data\SKILL.md",
        ".agents\skills\itl-vanessa-ui-mcp\SKILL.md",
        "templates\USER-RULES.append.md"
    )) {
        $path = Join-Path $SourceRoot $relativePath
        if (-not (Test-Path -LiteralPath $path -PathType Leaf -ErrorAction SilentlyContinue)) {
            throw "Workflow package source is missing required file '$relativePath': $SourceRoot"
        }
    }
}

function Resolve-WorkflowPackageSource {
    $overridePath = [string](Get-EnvValue -Name "ITL_WORKFLOW_SOURCE_PATH" -Default "")
    $repo = Get-WorkflowPackageRepo
    $ref = Get-WorkflowPackageRef
    $sourceKind = "git"
    $root = ""

    if (-not [string]::IsNullOrWhiteSpace($overridePath)) {
        $root = Resolve-Agent1cFullPath -Path $overridePath
        if (-not (Test-Path -LiteralPath $root -PathType Container -ErrorAction SilentlyContinue)) {
            throw "ITL_WORKFLOW_SOURCE_PATH was not found: $root"
        }
        $sourceKind = "path"
    } else {
        $root = Get-WorkflowPackageTempRoot
        $parent = Split-Path -Parent $root
        New-Item -ItemType Directory -Force -Path $parent | Out-Null

        if (-not (Test-Path -LiteralPath $root -PathType Container -ErrorAction SilentlyContinue)) {
            Write-Host "Cloning ITL workflow package: $repo"
            Invoke-GitAt -Root $parent -Arguments @("clone", $repo, $root)
        } elseif (-not (Test-Path -LiteralPath (Join-Path $root ".git") -PathType Container -ErrorAction SilentlyContinue)) {
            throw "Managed ITL workflow package checkout exists but is not a Git repository: $root. Remove it or set ITL_WORKFLOW_SOURCE_PATH."
        }

        Write-Host "Updating ITL workflow package checkout: $root"
        Invoke-GitAt -Root $root -Arguments @("fetch", "--all", "--tags", "--prune")
        $remoteRef = "refs/remotes/origin/$ref"
        if (Test-GitRefExistsAt -Root $root -Ref $remoteRef) {
            Invoke-GitAt -Root $root -Arguments @("checkout", "-B", $ref, "origin/$ref")
        } else {
            Invoke-GitAt -Root $root -Arguments @("checkout", "--detach", $ref)
        }
    }

    Assert-WorkflowPackageSourceRoot -SourceRoot $root
    $commit = ""
    # A linked worktree stores .git as a file, while a primary checkout uses a directory.
    if (Test-Path -LiteralPath (Join-Path $root ".git") -ErrorAction SilentlyContinue) {
        $commit = (Get-GitOutputAt -Root $root -Arguments @("rev-parse", "HEAD")).Trim()
    }

    return [pscustomobject]@{
        root = $root
        repo = $repo
        ref = $ref
        commit = $commit
        source = $sourceKind
    }
}

function Assert-WorkflowManagedTargetPath {
    param([string]$Path)

    $root = Get-FullPathNormalized $script:ProjectRoot
    $target = Get-FullPathNormalized $Path
    if ($target -eq $root) {
        return
    }
    if (-not $target.StartsWith(($root + "\"), [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to update a managed workflow path outside project root: $target"
    }
}

function Assert-WorkflowSourceOutsideProject {
    param([string]$SourceRoot)

    $projectRoot = Get-FullPathNormalized $script:ProjectRoot
    $sourceRoot = Get-FullPathNormalized $SourceRoot
    if ($sourceRoot -eq $projectRoot -or $sourceRoot.StartsWith(($projectRoot + "\"), [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "ITL workflow source must be outside the target project root for update-workflow: $SourceRoot"
    }
}

function Assert-WorkflowTrackedGitClean {
    $status = & git -C $script:ProjectRoot status --porcelain
    if ($LASTEXITCODE -ne 0) {
        throw "Cannot read Git status"
    }
    $trackedStatus = @($status | Where-Object {
        $line = [string]$_
        $line -and -not $line.StartsWith("?? ")
    })
    if ($trackedStatus.Count -gt 0) {
        throw "Git tracked worktree is not clean. Commit, stash, or discard tracked changes before update-workflow."
    }
}

function Copy-WorkflowManagedDirectory {
    param(
        [string]$SourceRoot,
        [string]$RelativePath
    )

    $sourcePath = Join-Path $SourceRoot $RelativePath
    $targetPath = Join-Path $script:ProjectRoot $RelativePath
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Container -ErrorAction SilentlyContinue)) {
        throw "Workflow package managed directory is missing: $RelativePath"
    }

    Assert-WorkflowManagedTargetPath -Path $targetPath
    $parent = Split-Path -Parent $targetPath
    if ($parent) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    if (Test-Path -LiteralPath $targetPath -ErrorAction SilentlyContinue) {
        Remove-Item -LiteralPath $targetPath -Recurse -Force
    }
    Copy-Item -LiteralPath $sourcePath -Destination $targetPath -Recurse -Force
    Write-Host "Updated workflow directory: $RelativePath"
}

function Copy-WorkflowManagedFile {
    param(
        [string]$SourceRoot,
        [string]$RelativePath
    )

    $sourcePath = Join-Path $SourceRoot $RelativePath
    $targetPath = Join-Path $script:ProjectRoot $RelativePath
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf -ErrorAction SilentlyContinue)) {
        throw "Workflow package managed file is missing: $RelativePath"
    }

    Assert-WorkflowManagedTargetPath -Path $targetPath
    $parent = Split-Path -Parent $targetPath
    if ($parent) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    Copy-Item -LiteralPath $sourcePath -Destination $targetPath -Force
    Write-Host "Updated workflow file: $RelativePath"
}

function Get-LegacyWorkflowManagedFileHashes {
    return [ordered]@{
        "README.md" = @("3E834E1FD81F0C06E779FCAAB7D467E1615135A72352650C834B9CE205C394D6")
        "DEVELOPER-GUIDE.ru.md" = @("E91CE6E8DF9F23B8AC75FA9EE76524DE0585A0F86B277BE67166D5A56A9C5093")
        "DEV-BRANCH-DEVELOPMENT.ru.md" = @("015C9ECE13462CEA299C795121ADD1AAB4C5C2DACDCFF30AB3D42E3AE5968E03")
        "VANESSA-TESTS-GUIDE.md" = @("052D1950EAB1078CADEC7A00F068E3F61F22ACA5A1FD99982EB3832075F030B1")
        "VANESSA-TESTS-GUIDE.ru.md" = @(
            "099725AFCA5A715D40906325B3CDB12217046FB76D6AA8B1F610357C9E8AE58F",
            "A96050FCDE0A5F97071AF1926752E88D117B5836DBDD537A898718DF43A6D57F"
        )
    }
}

function Remove-LegacyWorkflowManagedFiles {
    $knownFiles = Get-LegacyWorkflowManagedFileHashes
    foreach ($relativePath in @($knownFiles.Keys)) {
        $targetPath = Join-Path $script:ProjectRoot $relativePath
        if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf -ErrorAction SilentlyContinue)) {
            continue
        }

        Assert-WorkflowManagedTargetPath -Path $targetPath
        $actualHash = (Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash.ToUpperInvariant()
        if (@($knownFiles[$relativePath]) -contains $actualHash) {
            Remove-Item -LiteralPath $targetPath -Force
            Write-Host "Removed obsolete workflow-managed file: $relativePath"
            continue
        }

        Write-Warning "Preserved '$relativePath' because it differs from every known workflow-managed version. The workflow no longer manages this file."
    }
}

function Get-KiloItlCommandSurface {
    try {
        $currentBranch = Get-CurrentBranch
    } catch {
        return "unknown"
    }

    if ($currentBranch -eq (Get-MasterBranch)) {
        return "master"
    }
    if ($currentBranch -like "itldev/*") {
        return "dev"
    }
    return "unknown"
}

function Get-KiloInheritedPrimaryItlCommands {
    if ((Get-KiloItlCommandSurface) -ne "dev") {
        return @()
    }

    try {
        $primaryRoot = Resolve-Agent1cFullPath -Path (Get-MainWorktreePath)
        $currentRoot = Resolve-Agent1cFullPath -Path $script:ProjectRoot
    } catch {
        return @()
    }
    if ([string]::Equals($primaryRoot, $currentRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return @()
    }

    $primaryDir = Join-Path $primaryRoot ".kilo\commands"
    if (-not (Test-Path -LiteralPath $primaryDir -PathType Container -ErrorAction SilentlyContinue)) {
        return @()
    }
    $localDir = Join-Path $currentRoot ".kilo\commands"
    $localNames = @()
    if (Test-Path -LiteralPath $localDir -PathType Container -ErrorAction SilentlyContinue) {
        $localNames = @(Get-ChildItem -LiteralPath $localDir -File -Filter "itl*.md" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    }

    return @(
        Get-ChildItem -LiteralPath $primaryDir -File -Filter "itl*.md" -ErrorAction SilentlyContinue |
            Where-Object { $localNames -notcontains $_.Name } |
            ForEach-Object { "/$([System.IO.Path]::GetFileNameWithoutExtension($_.Name))" } |
            Sort-Object -Unique
    )
}

function Untrack-GeneratedKiloItlCommands {
    try {
        if (-not (Test-Path -LiteralPath (Join-Path $script:ProjectRoot ".git") -ErrorAction SilentlyContinue)) {
            return
        }
        $tracked = @(Get-GitOutput @("ls-files", "--", ".kilo/commands/itl*.md") | Where-Object { $_ })
        if ($tracked.Count -gt 0) {
            Invoke-Git (@("rm", "--cached", "--ignore-unmatch", "--") + $tracked)
            Write-Host "Untracked generated Kilo ITL commands from Git index."
        }
    } catch {
        Write-Host "[WARN] Could not untrack generated Kilo ITL commands: $($_.Exception.Message)"
    }
}

function Sync-KiloItlCommandSurface {
    param([string]$SourceRoot = $script:ProjectRoot)

    if (-not (Test-AiRules1cToolInstalled -Tool "kilocode")) {
        Write-Host "Skipping Kilo ITL command generation because ai_rules_1c kilocode is not installed."
        return
    }

    $templateRoot = Join-Path $SourceRoot ".agents\skills\1c-workflow\kilo-command-templates"
    if (-not (Test-Path -LiteralPath $templateRoot -PathType Container -ErrorAction SilentlyContinue)) {
        throw "Workflow package Kilo command templates directory is missing: .agents\skills\1c-workflow\kilo-command-templates"
    }
    $dormantCommandFiles = @(Get-ChildItem -LiteralPath $templateRoot -Recurse -File -Filter "itl*.md" -ErrorAction SilentlyContinue)
    if ($dormantCommandFiles.Count -gt 0) {
        $relative = @($dormantCommandFiles | ForEach-Object {
            $_.FullName.Substring($templateRoot.Length + 1)
        })
        throw "Workflow package Kilo command source templates must use .md.template, not .md: $($relative -join ', ')"
    }

    $surface = Get-KiloItlCommandSurface
    $targetDir = Join-Path $script:ProjectRoot ".kilo\commands"
    Assert-WorkflowManagedTargetPath -Path $targetDir
    New-Item -ItemType Directory -Force -Path $targetDir | Out-Null

    Untrack-GeneratedKiloItlCommands

    foreach ($existing in @(Get-ChildItem -LiteralPath $targetDir -File -Filter "itl*.md" -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $existing.FullName -Force
    }

    $sourceDirs = @((Join-Path $templateRoot "common"))
    if ($surface -in @("master", "dev")) {
        $sourceDirs += (Join-Path $templateRoot $surface)
    }

    $expectedCommandNames = @()
    foreach ($sourceDir in $sourceDirs) {
        if (-not (Test-Path -LiteralPath $sourceDir -PathType Container -ErrorAction SilentlyContinue)) {
            throw "Workflow package Kilo command template set is missing: $sourceDir"
        }
        foreach ($sourceFile in @(Get-ChildItem -LiteralPath $sourceDir -File -Filter "itl*.md.template" -ErrorAction Stop)) {
            $targetName = $sourceFile.Name.Substring(0, $sourceFile.Name.Length - ".template".Length)
            $expectedCommandNames += $targetName
            Copy-Item -LiteralPath $sourceFile.FullName -Destination (Join-Path $targetDir $targetName) -Force
        }
    }

    $expectedCommandNames = @($expectedCommandNames | Sort-Object -Unique)
    $actualCommandNames = @(Get-ChildItem -LiteralPath $targetDir -File -Filter "itl*.md" -ErrorAction Stop | Select-Object -ExpandProperty Name | Sort-Object -Unique)
    $surfaceDifference = @(Compare-Object -ReferenceObject $expectedCommandNames -DifferenceObject $actualCommandNames)
    if ($surfaceDifference.Count -gt 0) {
        $expectedText = if ($expectedCommandNames.Count -gt 0) { $expectedCommandNames -join ", " } else { "<none>" }
        $actualText = if ($actualCommandNames.Count -gt 0) { $actualCommandNames -join ", " } else { "<none>" }
        throw "Kilo ITL command surface verification failed for '$surface'. Expected: $expectedText. Actual: $actualText."
    }

    Write-Host "Generated Kilo ITL command surface: $surface (.kilo\commands\itl*.md)"
}

function Assert-MasterWorktreeContext {
    param([string]$Operation)

    $currentBranch = ""
    try {
        $currentBranch = Get-CurrentBranch
    } catch {
        $currentBranch = ""
    }

    $masterBranch = Get-MasterBranch
    if ($currentBranch -ne $masterBranch) {
        throw "$Operation must be run from the '$masterBranch' worktree. Current branch: $(if ($currentBranch) { $currentBranch } else { '<none>' }). Open the master project folder and run it there."
    }
}

function Assert-DevelopmentBranchWorktreeContext {
    param(
        [object]$State,
        [string]$Operation
    )

    $currentBranch = ""
    try {
        $currentBranch = Get-CurrentBranch
    } catch {
        $currentBranch = ""
    }

    if ($currentBranch -notlike "itldev/*") {
        $worktreePath = ""
        if ($State) {
            $worktreePath = Get-StateValue -State $State -Name "worktreePath" -Default ""
        }
        $hint = $(if ($worktreePath) { " Open the development branch worktree: $worktreePath" } else { " Open the required itldev/* worktree and run it there." })
        throw "$Operation must be run from an active itldev/* development branch worktree. Current branch: $(if ($currentBranch) { $currentBranch } else { '<none>' }).$hint"
    }

    if ($State) {
        $stateBranch = Get-StateValue -State $State -Name "devBranch" -Default ""
        if ($stateBranch -and $currentBranch -ne $stateBranch) {
            throw "$Operation must be run from development branch '$stateBranch'. Current branch: $currentBranch."
        }
        Assert-CurrentProjectRootMatchesDevBranchState -State $State -Operation $Operation
    }
}

function Update-WorkflowPackageLockEntry {
    param([object]$Source)

    Ensure-DependencyLockManifest
    $manifest = ConvertTo-Agent1cHashtable -Object (Read-DependencyLockManifest)
    $dependencies = ConvertTo-Agent1cHashtable -Object $manifest["dependencies"]
    $entry = ConvertTo-Agent1cHashtable -Object $dependencies["workflowPackage"]
    $next = [ordered]@{
        repo = [string]$Source.repo
        ref = [string]$Source.ref
        commit = [string]$Source.commit
        source = [string]$Source.source
    }
    $unchanged = @($next.Keys | Where-Object { [string]$entry[$_] -ne [string]$next[$_] }).Count -eq 0
    if ($unchanged) { return $false }
    foreach ($key in $next.Keys) { $entry[$key] = $next[$key] }
    $entry["updatedAt"] = (Get-Date).ToString("o")
    $dependencies["workflowPackage"] = $entry
    $manifest["dependencies"] = $dependencies
    Write-DependencyLockManifest -Manifest $manifest
    return $true
}

function Apply-BootstrapWorkflowPackageProvenance {
    $values = @($BootstrapWorkflowRepo, $BootstrapWorkflowRef, $BootstrapWorkflowCommit, $BootstrapWorkflowSource)
    if (@($values | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count -eq 0) {
        return $false
    }
    if ($BootstrapWorkflowSource -ne "path") {
        throw "Bootstrap workflow provenance source must be 'path'."
    }
    if ($BootstrapWorkflowCommit -and $BootstrapWorkflowCommit -notmatch '^[0-9a-fA-F]{40}$') {
        throw "Bootstrap workflow provenance commit must be a full 40-character Git SHA: $BootstrapWorkflowCommit"
    }

    $changed = Update-WorkflowPackageLockEntry -Source ([pscustomobject]@{
        repo = [string]$BootstrapWorkflowRepo
        ref = [string]$BootstrapWorkflowRef
        commit = ([string]$BootstrapWorkflowCommit).ToLowerInvariant()
        source = [string]$BootstrapWorkflowSource
    })
    Write-Host "$(if ($changed) { 'Recorded' } else { 'Confirmed' }) bootstrap workflow package provenance: $(if ($BootstrapWorkflowCommit) { $BootstrapWorkflowCommit } else { '<non-Git source>' })"
    return $true
}

function Get-WorkflowActiveDevBranchStates {
    $states = @()
    foreach ($file in Get-DevBranchStateFiles) {
        try {
            $state = Read-DevBranchStateFile -Path $file.FullName
            if (-not (Get-StateValue -State $state -Name "closedAt")) {
                $states += $state
            }
        } catch {
        }
    }
    return @($states)
}

function Write-WorkflowUpdateFollowUp {
    $states = @(Get-WorkflowActiveDevBranchStates)
    Write-Host ""
    Write-Host "Next steps:"
    Write-Host "  Review and commit the updated workflow/rules files in master."
    Write-Host "  Kilo Code: run /reload or open a new session so project instructions, skills, agents, and commands are reread."
    Write-Host "  MCP client config is reconciled automatically when saved vibecoding1c selection/state has ready replacements."
    Write-Host "  If the helper preserved upstream MCP entries, complete setup when ready:"
    Write-Host "    powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action vibecoding1c-mcp-setup"
    Write-Host "  Refresh vibecoding1c MCP registry/distribution when needed:"
    Write-Host "    powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action vibecoding1c-mcp-update"
    if ($states.Count -gt 0) {
        Write-Host "  Active development branches must merge the updated master intentionally:"
        foreach ($state in ($states | Sort-Object @{ Expression = { Get-StateValue -State $_ -Name "devBranchName" -Default "" } })) {
            $name = Get-StateValue -State $state -Name "devBranchName" -Default (Get-StateValue -State $state -Name "safeDevBranchName" -Default "<unknown>")
            $worktreePath = Get-StateValue -State $state -Name "worktreePath" -Default (Get-StateValue -State $state -Name "stateProjectRoot" -Default "")
            Write-Host "    $name -> $worktreePath"
        }
        Write-Host "  In each branch worktree, use refresh-dev-branch or merge master, then rerun vibecoding1c MCP setup/status for that scope."
        Write-Host "  Each refreshed branch receives stable itl-roctup-data and itl-vanessa-ui entries; backend starts need no further reload."
    } else {
        Write-Host "  No active development branches were found."
    }
}

function Write-WorkflowPackageStatusLines {
    $entry = Get-DependencyLockEntry -Name "workflowPackage"
    if ($null -eq $entry) {
        Write-Host "Workflow package: <not recorded>"
        return
    }

    $repo = [string](Get-ConfigValueFromObject -Object $entry -Path "repo" -Default "")
    $ref = [string](Get-ConfigValueFromObject -Object $entry -Path "ref" -Default "")
    $commit = [string](Get-ConfigValueFromObject -Object $entry -Path "commit" -Default "")
    $updatedAt = [string](Get-ConfigValueFromObject -Object $entry -Path "updatedAt" -Default "")
    $source = [string](Get-ConfigValueFromObject -Object $entry -Path "source" -Default "")
    Write-Host "Workflow package: $(if ($commit) { $commit } else { '<not recorded>' })"
    if ($repo) {
        Write-Host "Workflow package repo: $repo"
    }
    if ($ref) {
        Write-Host "Workflow package ref: $ref"
    }
    if ($source) {
        Write-Host "Workflow package source: $source"
    }
    if ($updatedAt) {
        Write-Host "Workflow package updated: $updatedAt"
    }
}

function Assert-WorkflowPackageUpdateContext {
    if (-not (Test-Path -LiteralPath (Join-Path $script:ProjectRoot ".git") -ErrorAction SilentlyContinue)) {
        throw "update-workflow requires an initialized Git repository."
    }

    $currentBranch = Get-CurrentBranch
    if ($currentBranch -like "itldev/*") {
        $mainWorktreePath = ""
        try {
            $state = Read-DevBranchState -Name ""
            $mainWorktreePath = Get-StateValue -State $state -Name "mainWorktreePath" -Default ""
        } catch {
        }
        $hint = $(if ($mainWorktreePath) { " Main worktree: $mainWorktreePath" } else { "" })
        throw "update-workflow must be run from the master worktree, not from development branch '$currentBranch'.$hint"
    }

    $masterBranch = Get-MasterBranch
    if ($currentBranch -ne $masterBranch) {
        throw "update-workflow must be run from '$masterBranch'. Current branch: $(if ($currentBranch) { $currentBranch } else { '<none>' })."
    }

    Assert-WorkflowTrackedGitClean
}

function Update-WorkflowPackage {
    Write-Section "Update ITL workflow package"
    if ($LifecyclePhase -notin @("", "pre-copy", "post-copy")) {
        throw "update-workflow does not support LifecyclePhase '$LifecyclePhase'."
    }

    if ($LifecyclePhase -ne "post-copy") {
        Set-RunStage -Stage "workflow-update.preflight" -Detail "Validating the master worktree and workflow source."
        Assert-WorkflowPackageUpdateContext

        $source = Resolve-WorkflowPackageSource
        Assert-WorkflowSourceOutsideProject -SourceRoot $source.root

        Set-RunStage -Stage "workflow-update.copy" -Detail "Copying the managed workflow package files."
        Copy-WorkflowManagedDirectory -SourceRoot $source.root -RelativePath ".agents\skills\1c-workflow"
        Copy-WorkflowManagedDirectory -SourceRoot $source.root -RelativePath ".agents\skills\1c-workflow-fast"
        Copy-WorkflowManagedDirectory -SourceRoot $source.root -RelativePath ".agents\skills\product-docs"
        Copy-WorkflowManagedDirectory -SourceRoot $source.root -RelativePath ".agents\skills\itl-roctup-1c-data"
        Copy-WorkflowManagedDirectory -SourceRoot $source.root -RelativePath ".agents\skills\itl-vanessa-ui-mcp"
        Copy-WorkflowManagedDirectory -SourceRoot $source.root -RelativePath "docs\itl-workflow"
        Copy-WorkflowManagedDirectory -SourceRoot $source.root -RelativePath "templates"
        foreach ($relativePath in @("install-agent-1c-workflow.ps1", "AGENT-INSTALL.md")) {
            Copy-WorkflowManagedFile -SourceRoot $source.root -RelativePath $relativePath
        }
        Remove-LegacyWorkflowManagedFiles

        Update-WorkflowPackageLockEntry -Source $source | Out-Null
        Write-Host "Workflow package files copied. Restarting the installed helper in a fresh PowerShell process for post-copy processing."
        Invoke-Agent1cFreshProcess -AdditionalArguments @("-LifecyclePhase", "post-copy")
    }

    Set-RunStage -Stage "workflow-update.post-copy" -Detail "Applying installed-project overlays and dependency updates."
    Assert-MasterWorktreeContext -Operation "update-workflow post-copy"
    Ensure-GitIgnore
    Sync-ItlVanessaLibraries
    Update-AgentGuidanceBridge
    Update-UserRules
    Update-RoctupMcp
    Sync-VanessaAutomationDependencyLock | Out-Null
    Install-VanessaAutomation
    Update-VanessaMcpArtifacts
    Sync-ItlOnDemandMcpDependencyLock | Out-Null
    Install-ItlOnDemandMcp | Out-Null

    if ($SkipAiRules) {
        Write-Host "Skipping ai_rules_1c update because -SkipAiRules was specified."
        $migrationPlan = Get-AiRulesMigrationPlan
        if ($migrationPlan.status -eq "eligible") {
            Write-Host "ai_rules_1c migration remains pending because -SkipAiRules was specified: $($migrationPlan.target.ref)"
        }
        Sync-KiloItlCommandSurface
    } else {
        $migration = Invoke-AiRulesBaselineMigration
        if (-not $migration.migrated -and -not $migration.suppressRegularUpdate) {
            Update-AiRules1c
        }
    }

    $workflowLock = ConvertTo-Agent1cHashtable -Object (Read-DependencyLockManifest)
    $workflowDependencies = ConvertTo-Agent1cHashtable -Object $workflowLock["dependencies"]
    $workflowEntry = ConvertTo-Agent1cHashtable -Object $workflowDependencies["workflowPackage"]
    Write-Host "ITL workflow package post-copy processing completed from $($workflowEntry['source'])."
    if ($workflowEntry["commit"]) {
        Write-Host "Workflow package commit: $($workflowEntry['commit'])"
    }
    Write-Host "No commit was created automatically."
    Write-WorkflowUpdateFollowUp
}

function Update-UserRules {
    $path = Join-Path $script:ProjectRoot "USER-RULES.md"
    $templatePath = Join-Path $script:ProjectRoot "templates\USER-RULES.append.md"
    if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) {
        throw "USER-RULES overlay template was not found: $templatePath"
    }
    $startMarker = "<!-- ITL-WORKFLOW-USER-RULES:START -->"
    $endMarker = "<!-- ITL-WORKFLOW-USER-RULES:END -->"
    $marker = "## 1C Project Lifecycle"
    $templateBlock = (Read-Utf8Text -Path $templatePath).Trim()
    if (-not (Test-ProductDocsMcpAllowed)) {
        $productDocsRulePattern = '(?m)^For PM5 product logic,.*$'
        if (-not [regex]::IsMatch($templateBlock, $productDocsRulePattern)) {
            throw "PM5 product-docs rule was not found in USER-RULES overlay; refusing to install PM5 BookStack routing into a PM4 project."
        }
        $pm4Rule = 'For PM4 projects, PM5 product documentation MCP is disabled. Before answering, exploring, planning, proposing, or changing product logic, technical or implementation architecture, internal subsystem design, technical decisions/constraints/rationale, workflows, terminology, permissions, reports, integrations, or acceptance tests, rely on the user request, code, tests, current 1C metadata, and available non-product MCP evidence; report product-intent uncertainty explicitly.'
        $templateBlock = [regex]::Replace($templateBlock, $productDocsRulePattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $pm4Rule }, 1)
    }
    $block = ($startMarker + [Environment]::NewLine + $templateBlock + [Environment]::NewLine + $endMarker)

    if (Test-Path -LiteralPath $path) {
        $current = Read-Utf8Text -Path $path
        $managedPattern = "(?s)" + [regex]::Escape($startMarker) + ".*?" + [regex]::Escape($endMarker)
        if ([regex]::IsMatch($current, $managedPattern)) {
            $updated = [regex]::Replace($current, $managedPattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $block }, 1)
            Write-Utf8Text -Path $path -Value ($updated.TrimEnd() + [Environment]::NewLine)
            return
        }

        $markerIndex = $current.IndexOf($marker, [System.StringComparison]::Ordinal)
        if ($markerIndex -ge 0) {
            $before = $current.Substring(0, $markerIndex).TrimEnd()
            $afterStart = $markerIndex + $marker.Length
            $nextHeadingMatch = [regex]::Match($current.Substring($afterStart), "(?m)^##\s+")
            $after = ""
            if ($nextHeadingMatch.Success) {
                $after = $current.Substring($afterStart + $nextHeadingMatch.Index).TrimStart()
            }
            $parts = @()
            if ($before) {
                $parts += $before
            }
            $parts += $block
            if ($after) {
                $parts += $after
            }
            Write-Utf8Text -Path $path -Value (($parts -join ([Environment]::NewLine + [Environment]::NewLine)) + [Environment]::NewLine)
            return
        }

        Add-Utf8Text -Path $path -Value ([Environment]::NewLine + $block + [Environment]::NewLine)
    } else {
        Write-Utf8Text -Path $path -Value $block.TrimStart()
    }
}

function Update-AgentGuidanceBridge {
    $path = Join-Path $script:ProjectRoot "AGENTS.md"
    $marker = "## 1C Agent Workflow Bridge"
    $templatePath = Join-Path $script:ProjectRoot "templates\AGENTS.append.md"
    $block = if (Test-Path -LiteralPath $templatePath -PathType Leaf) {
        (Read-Utf8Text -Path $templatePath).Trim()
    } else {
        $defaultBlock = @"
$marker

Read `USER-RULES.md` for project-specific workflow notes.

For routine ITL lifecycle operations, prefer `.agents/skills/1c-workflow-fast/SKILL.md` or the short Kilo `/itl-*` wrappers.

Use `.agents/skills/1c-workflow/SKILL.md` for initialization, unusual recovery, or detailed workflow work.

Keep `.dev.env`, `.agent-1c/dev-branches/*.json`, `.agent-1c/event-log-baselines/*.json`, downloaded tools, logs, local infobases, and result artifacts out of Git.
"@
        $defaultBlock.Trim()
    }

    if (Test-Path -LiteralPath $path) {
        $current = Read-Utf8Text -Path $path
        if ($current.Contains($marker)) {
            return
        }
        if ($current.Contains("USER-RULES.md")) {
            Write-Host "AGENTS.md already references USER-RULES.md; keeping ITL overlay in USER-RULES.md only."
            return
        }
        Add-Utf8Text -Path $path -Value ($block + [Environment]::NewLine)
    } else {
        Write-Utf8Text -Path $path -Value $block.TrimStart()
    }
}

function Save-DevBranchState {
    param(
        [string]$SafeDevBranchName,
        [hashtable]$State,
        [string]$ProjectRootOverride = $script:ProjectRoot
    )

    $devBranchesDir = Join-Path $ProjectRootOverride ".agent-1c\dev-branches"
    New-Item -ItemType Directory -Force -Path $devBranchesDir | Out-Null
    $path = Join-Path $devBranchesDir ($SafeDevBranchName + ".json")
    Write-Utf8Text -Path $path -Value (($State | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
    return $path
}

function Get-DevBranchInitializationStatus {
    param([object]$State)

    $status = Get-StateValue -State $State -Name "initializationStatus" -Default ""
    if (-not $status) {
        return "ready"
    }
    return ([string]$status).Trim().ToLowerInvariant()
}

function Test-DevBranchInitializationResumable {
    param([object]$State)

    $status = Get-DevBranchInitializationStatus -State $State
    return (@("initializing", "infobase-copied", "repository-unbound", "unsafe-action-protection-resolved", "launcher-registered", "enterprise-normalization-pending", "failed") -contains $status)
}

function Set-DevBranchInitializationFields {
    param(
        [hashtable]$State,
        [string]$Status,
        [string]$ErrorMessage = ""
    )

    $State["initializationStatus"] = $Status
    $State["initializationError"] = $ErrorMessage
    $State["initializationUpdatedAt"] = (Get-Date).ToString("o")
}

function Save-DevBranchInitializationState {
    param(
        [string]$SafeDevBranchName,
        [hashtable]$State,
        [string]$Status,
        [string]$ErrorMessage = "",
        [string]$ProjectRootOverride = $script:ProjectRoot
    )

    Set-DevBranchInitializationFields -State $State -Status $Status -ErrorMessage $ErrorMessage
    return (Save-DevBranchState -SafeDevBranchName $SafeDevBranchName -State $State -ProjectRootOverride $ProjectRootOverride)
}

function Write-DevBranchInitializationStatusLines {
    param(
        [object]$State,
        [string]$Indent = ""
    )

    $status = Get-DevBranchInitializationStatus -State $State
    if ((Get-DevBranchKind -State $State) -eq "extension") {
        $extensionStatus = Get-DevBranchExtensionInitializationStatus -State $State
        Write-Host "${Indent}Extension initialization: $extensionStatus"
        $extensionError = Get-StateValue -State $State -Name "extensionInitializationError" -Default ""
        if ($extensionError) {
            Write-Host "${Indent}Extension initialization error: $extensionError"
        }
    }
    $normalizationStatus = Get-StateValue -State $State -Name "enterpriseNormalizationStatus" -Default "legacy-pending"
    Write-Host "${Indent}Enterprise normalization: $normalizationStatus"
    $normalizationReason = Get-StateValue -State $State -Name "enterpriseNormalizationReason" -Default ""
    if ($normalizationReason) {
        Write-Host "${Indent}Enterprise normalization reason: $normalizationReason"
    }
    $normalizationError = Get-StateValue -State $State -Name "enterpriseNormalizationError" -Default ""
    if ($normalizationError) {
        Write-Host "${Indent}Enterprise normalization error: $normalizationError"
    }
    $configLoadStatus = Get-StateValue -State $State -Name "configLoadStatus" -Default ""
    if ($configLoadStatus) {
        Write-Host "${Indent}Last config load: $configLoadStatus / $(Get-StateValue -State $State -Name 'lastConfigLoadMode' -Default '<unknown>')"
        $partialLog = Get-StateValue -State $State -Name "lastConfigPartialLogPath" -Default ""
        $fullLog = Get-StateValue -State $State -Name "lastConfigFullFallbackLogPath" -Default ""
        if ($partialLog) { Write-Host "${Indent}Last partial config log: $partialLog" }
        if ($fullLog) { Write-Host "${Indent}Last full fallback config log: $fullLog" }
        if ($configLoadStatus -in @("memory-limit-exceeded", "memory-monitor-failed")) {
            $memoryLimitMb = Get-StateValue -State $State -Name "lastDesignerWorkingSetLimitMb" -Default 0
            $peakWorkingSetMb = Get-StateValue -State $State -Name "lastDesignerPeakWorkingSetMb" -Default 0
            Write-Host "${Indent}Designer memory guard: limitMb=$memoryLimitMb peakWorkingSetMb=$peakWorkingSetMb"
        }
    }
    if ($status -eq "ready") {
        return
    }

    Write-Host "${Indent}Initialization status: $status"
    $errorMessage = Get-StateValue -State $State -Name "initializationError" -Default ""
    if ($errorMessage) {
        Write-Host "${Indent}Initialization error: $errorMessage"
    }
    $worktreePath = Get-StateValue -State $State -Name "worktreePath" -Default (Get-StateValue -State $State -Name "stateProjectRoot" -Default "")
    if ($worktreePath) {
        Write-Host "${Indent}Recovery: rerun new-dev-branch for this branch from the master worktree. Worktree: $worktreePath"
    } else {
        Write-Host "${Indent}Recovery: rerun new-dev-branch for this branch from the master worktree."
    }
}

function Update-DevBranchState {
    param(
        [object]$State,
        [hashtable]$Updates
    )

    $stateHash = @{}
    foreach ($prop in $State.PSObject.Properties) {
        if (@("statePath", "stateProjectRoot") -contains $prop.Name) {
            continue
        }
        $stateHash[$prop.Name] = $prop.Value
    }
    foreach ($key in $Updates.Keys) {
        $stateHash[$key] = $Updates[$key]
    }

    $safeName = $stateHash["safeDevBranchName"]
    if (-not $safeName) {
        $safeName = ConvertTo-SafeName $stateHash["devBranchName"]
        $stateHash["safeDevBranchName"] = $safeName
    }
    $stateProjectRoot = Get-StateValue -State $State -Name "stateProjectRoot" -Default $script:ProjectRoot
    Save-DevBranchState -SafeDevBranchName $safeName -State $stateHash -ProjectRootOverride $stateProjectRoot | Out-Null
}

function Get-DevBranchStateProjectRootFromPath {
    param([string]$Path)

    $devBranchesDir = Split-Path -Parent $Path
    $agentDir = Split-Path -Parent $devBranchesDir
    return [System.IO.Path]::GetFullPath((Split-Path -Parent $agentDir))
}

function Read-DevBranchStateFile {
    param([string]$Path)

    $state = Read-Utf8Text -Path $Path | ConvertFrom-Json
    $stateProjectRoot = Get-DevBranchStateProjectRootFromPath -Path $Path
    $state | Add-Member -NotePropertyName statePath -NotePropertyValue $Path -Force
    $state | Add-Member -NotePropertyName stateProjectRoot -NotePropertyValue $stateProjectRoot -Force
    return $state
}

function Get-DevBranchStateFiles {
    $files = @()
    $roots = @($script:ProjectRoot)
    foreach ($worktree in Get-GitWorktrees) {
        if ($worktree.path) {
            $roots += [System.IO.Path]::GetFullPath($worktree.path)
        }
    }

    foreach ($root in @($roots | Sort-Object -Unique)) {
        $devBranchesDir = Join-Path $root ".agent-1c\dev-branches"
        if (Test-Path -LiteralPath $devBranchesDir -PathType Container -ErrorAction SilentlyContinue) {
            $files += @(Get-ChildItem -LiteralPath $devBranchesDir -Filter "*.json" -File -ErrorAction SilentlyContinue)
        }
    }

    return @($files | Sort-Object FullName -Unique)
}

function Find-DevBranchStateFile {
    param([string]$SafeDevBranchName)

    $fileName = $SafeDevBranchName + ".json"
    foreach ($file in Get-DevBranchStateFiles) {
        if ($file.Name -eq $fileName) {
            return $file.FullName
        }
    }
    return ""
}

function Read-DevBranchState {
    param([string]$Name)

    if (-not $Name) {
        $currentBranch = (Get-GitOutput @("branch", "--show-current")).Trim()
        if ($currentBranch -like "itldev/*") {
            $Name = $currentBranch.Substring("itldev/".Length)
        }
    }

    if (-not $Name) {
        throw "Run this from a development branch or pass -DevBranchName."
    }

    $safe = ConvertTo-SafeName $Name
    $path = Join-Path $script:ProjectRoot ".agent-1c\dev-branches\$safe.json"
    if (-not (Test-Path -LiteralPath $path)) {
        $path = Find-DevBranchStateFile -SafeDevBranchName $safe
    }
    if (-not $path -or -not (Test-Path -LiteralPath $path)) {
        throw "Development branch state not found for '$Name'."
    }
    return Read-DevBranchStateFile -Path $path
}

function Test-DevBranchStateUsesWorktree {
    param([object]$State)

    return (ConvertTo-BoolSetting -Value (Get-StateValue -State $State -Name "createdWithWorktree" -Default $false) -Default $false)
}

function Assert-CurrentProjectRootMatchesDevBranchState {
    param(
        [object]$State,
        [string]$Operation
    )

    if (-not (Test-DevBranchStateUsesWorktree -State $State)) {
        return
    }

    $worktreePath = Get-StateValue -State $State -Name "worktreePath" -Default ""
    if (-not $worktreePath) {
        return
    }

    if ((Get-FullPathNormalized $script:ProjectRoot) -ne (Get-FullPathNormalized $worktreePath)) {
        throw "$Operation must be run from the development branch worktree: $worktreePath. Open a separate agent window in that folder."
    }
}

function Copy-DotEnvToWorktree {
    param([string]$WorktreePath)

    $sourceDotEnv = Join-Path $script:ProjectRoot ".dev.env"
    if (Test-Path -LiteralPath $sourceDotEnv -PathType Leaf -ErrorAction SilentlyContinue) {
        Copy-Item -LiteralPath $sourceDotEnv -Destination (Join-Path $WorktreePath ".dev.env") -Force
    }
}

function Copy-KiloProjectConfigToWorktree {
    param(
        [string]$MainProjectRoot,
        [string]$WorktreePath
    )

    foreach ($fileName in @("kilo.json", "kilo.jsonc")) {
        $sourcePath = Join-Path (Join-Path $MainProjectRoot ".kilo") $fileName
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf -ErrorAction SilentlyContinue)) {
            continue
        }

        $targetDirectory = Join-Path $WorktreePath ".kilo"
        $targetPath = Join-Path $targetDirectory $fileName
        if (Test-Path -LiteralPath $targetPath -PathType Leaf -ErrorAction SilentlyContinue) {
            continue
        }

        New-Item -ItemType Directory -Force -Path $targetDirectory | Out-Null
        Copy-Item -LiteralPath $sourcePath -Destination $targetPath
    }
}

function Open-AgentWorktreeBestEffort {
    param([string]$WorktreePath)

    if (-not $OfferOpenAgent) {
        return
    }

    $codeCommand = Get-Command code -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($codeCommand) {
        & $codeCommand.Source -n $WorktreePath
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Открыто новое окно VS Code/Kilo для рабочей папки: $WorktreePath"
            return
        }
        Write-Host "Не удалось автоматически открыть VS Code/Kilo через команду code."
    } else {
        Write-Host "Команда code не найдена. Откройте рабочую папку вручную."
    }
}

function Write-DevBranchWorktreeOpenMessage {
    param(
        [string]$MainProjectPath,
        [string]$WorktreePath
    )

    Write-Host ""
    Write-Host "Ветка разработки создана."
    Write-Host ""
    Write-Host "Текущая папка осталась на master:"
    Write-Host $MainProjectPath
    Write-Host ""
    Write-Host "Рабочая папка новой ветки:"
    Write-Host $WorktreePath
    Write-Host ""
    Write-Host "Чтобы продолжить работу агентом с этой линией разработки, откройте отдельное окно выбранного агента или IDE в этой папке."
    Write-Host "Могу попробовать открыть новое окно агента для этой папки автоматически."
    Write-Host "Новое окно прочитает контекст этого worktree при открытии; дополнительных действий для перечитывания контекста в нем не требуется."

    $script:RunWorktreePath = $WorktreePath
    $script:RunRequiredAction = "Откройте новое окно выбранного клиента или IDE в папке '$WorktreePath'. Новое окно прочитает контекст этого worktree при запуске; дополнительная перезагрузка клиента в нём не требуется."
}

function Write-PostInitClientReloadHandoff {
    $client = Get-ItlActiveClient
    if ($client -eq "kilocode") {
        $instruction = "В окне Kilo Code, которое было открыто на master до инициализации, сейчас выполните /reload, чтобы клиент перечитал инициализированный проект. Сделайте это до следующего действия в master. Новое окно worktree, открытое позднее, прочитает собственный контекст при запуске."
    } else {
        $adapterInstruction = [string](Get-StateValue -State (Get-ItlClientAdapter -Client $client) -Name "reloadUserReport" -Default "Перезапустите активный клиент.")
        $instruction = "Если окно клиента $client было открыто до инициализации, сейчас заставьте его перечитать инициализированный проект master: $adapterInstruction Новое окно worktree, открытое позднее, прочитает собственный контекст при запуске."
    }

    $script:RunRequiredAction = $instruction
    Write-Host ""
    Write-Host "Initialization client handoff:"
    Write-Host $instruction
}

function ConvertTo-RunUserReportValue {
    param(
        [AllowNull()][object]$Value,
        [string]$Default = "<не задано>"
    )

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $Default
    }
    return (([string]$Value) -replace '[\r\n]+', ' ').Trim()
}

function ConvertTo-RunUserReportStateDisplay {
    param(
        [AllowNull()][object]$Value,
        [ValidateSet("InfoBaseKind", "BranchKind", "PublicationMode", "PublicationStatus", "ExtensionStatus", "McpStatus", "Toggle", "Availability")]
        [string]$Kind
    )

    $text = ([string]$Value).Trim().ToLowerInvariant()
    switch ($Kind) {
        "InfoBaseKind" {
            switch ($text) {
                "file" { return "файловая" }
                "server" { return "серверная" }
                default { return (ConvertTo-RunUserReportValue -Value $Value) }
            }
        }
        "BranchKind" {
            switch ($text) {
                "configuration" { return "конфигурация" }
                "extension" { return "расширение" }
                default { return (ConvertTo-RunUserReportValue -Value $Value) }
            }
        }
        "PublicationMode" {
            switch ($text) {
                "disabled" { return "отключена" }
                "automatic" { return "автоматическая" }
                "manual" { return "ручная" }
                default { return (ConvertTo-RunUserReportValue -Value $Value) }
            }
        }
        "PublicationStatus" {
            switch ($text) {
                "disabled" { return "отключена" }
                "pending" { return "ожидает настройки" }
                "published" { return "опубликована" }
                "skipped" { return "пропущена" }
                "failed" { return "ошибка" }
                default { return (ConvertTo-RunUserReportValue -Value $Value) }
            }
        }
        "ExtensionStatus" {
            switch ($text) {
                "pending" { return "ожидает настройки" }
                "running" { return "выполняется" }
                "ready" { return "готово" }
                "failed" { return "ошибка" }
                "not-required" { return "не требуется" }
                default { return (ConvertTo-RunUserReportValue -Value $Value) }
            }
        }
        "McpStatus" {
            switch ($text) {
                "pending" { return "ожидает запуска" }
                "starting" { return "запускается" }
                "running" { return "работает" }
                "stopped" { return "остановлен" }
                "disabled" { return "отключён" }
                "failed" { return "ошибка" }
                "unknown" { return "состояние не определено" }
                default { return (ConvertTo-RunUserReportValue -Value $Value) }
            }
        }
        "Toggle" {
            switch ($text) {
                "enabled" { return "включено" }
                "disabled" { return "отключено" }
                default { return (ConvertTo-RunUserReportValue -Value $Value) }
            }
        }
        "Availability" {
            switch ($text) {
                "ready" { return "готов" }
                "missing" { return "не найден" }
                "unknown" { return "состояние не определено" }
                default { return (ConvertTo-RunUserReportValue -Value $Value) }
            }
        }
    }
}

function Add-RunUserReportLine {
    param(
        [System.Collections.Generic.List[string]]$Lines,
        [string]$Label,
        [AllowNull()][object]$Value,
        [string]$Default = "<не задано>"
    )

    $Lines.Add("- ${Label}: $(ConvertTo-RunUserReportValue -Value $Value -Default $Default)")
}

function Get-RunUserReportObservedValue {
    param(
        [scriptblock]$Read,
        [AllowNull()][object]$Default = $null
    )

    try {
        return (& $Read)
    } catch {
        return $Default
    }
}

function Format-Vibecoding1cRunUserReportList {
    param([object[]]$Items)

    $value = Format-Vibecoding1cMcpStatusList -Items $Items
    if ($value -in @("none", "<none>")) { return "<нет>" }
    return $value
}

function Add-Vibecoding1cRunUserReportLines {
    param(
        [System.Collections.Generic.List[string]]$Lines,
        [System.Collections.Generic.List[string]]$AdviceLines
    )

    try {
        $summary = Get-Vibecoding1cMcpStatusSummary
        Add-RunUserReportLine -Lines $Lines -Label "Активные vibecoding1c" -Value (Format-Vibecoding1cRunUserReportList -Items $summary.active) -Default "<нет>"
        Add-RunUserReportLine -Lines $Lines -Label "Пропущенные vibecoding1c" -Value (Format-Vibecoding1cRunUserReportList -Items $summary.skipped) -Default "<нет>"
        Add-RunUserReportLine -Lines $Lines -Label "Устаревшие vibecoding1c" -Value (Format-Vibecoding1cRunUserReportList -Items $summary.staleServers) -Default "<нет>"
        Add-RunUserReportLine -Lines $Lines -Label "vibecoding1c без configId" -Value (Format-Vibecoding1cRunUserReportList -Items $summary.missingConfigId) -Default "<нет>"
        if ($null -ne $AdviceLines -and @($summary.missingConfigId).Count -gt 0) {
            $AdviceLines.Add("- Выбор vibecoding1c MCP не завершён. Попросите агента явно выбрать конфигурацию для каждого сервера.")
        }
    } catch {
        Add-RunUserReportLine -Lines $Lines -Label "Состояние vibecoding1c" -Value "не удалось определить"
    }
}

function Add-KiloBrowserRunUserReportLines {
    param(
        [System.Collections.Generic.List[string]]$McpLines,
        [System.Collections.Generic.List[string]]$AdviceLines,
        [string]$ProjectRoot
    )

    $display = Get-KiloBrowserAutomationDisplay -ProjectRoot $ProjectRoot
    if ($null -eq $display) { return }
    $McpLines.Add("- $($display.statusLine.TrimEnd('.'))")
    if ($display.adviceLine) {
        $AdviceLines.Add("- $($display.adviceLine)")
    }
}

function Write-AndSetRunUserReport {
    param([System.Collections.Generic.List[string]]$Lines)

    $report = (@($Lines) -join [Environment]::NewLine).Trim()
    Set-RunUserReport -Report $report
    Write-Host ""
    Write-Host "Agent user report:"
    Write-Host $report
}

function Write-InitRunUserReport {
    param([bool]$VibecodingDeferred)

    $lines = [System.Collections.Generic.List[string]]::new()
    $advice = [System.Collections.Generic.List[string]]::new()
    $lines.Add("## Инициализация проекта")
    Add-RunUserReportLine -Lines $lines -Label "Корень проекта" -Value $script:ProjectRoot
    Add-RunUserReportLine -Lines $lines -Label "Клиент агента" -Value (Get-RunUserReportObservedValue -Read { Get-ItlActiveClient } -Default "состояние не определено")
    Add-RunUserReportLine -Lines $lines -Label "Платформа 1С" -Value (Get-RunUserReportObservedValue -Read { Get-PlatformPath })
    Add-RunUserReportLine -Lines $lines -Label "Базовая конфигурация" -Value (Get-RunUserReportObservedValue -Read { Get-BaseConfigurationVersion })
    $infoBaseKind = Get-RunUserReportObservedValue -Read { Get-InfoBaseKind }
    Add-RunUserReportLine -Lines $lines -Label "Тип исходной информационной базы" -Value (ConvertTo-RunUserReportStateDisplay -Value $infoBaseKind -Kind InfoBaseKind)
    Add-RunUserReportLine -Lines $lines -Label "Исходная информационная база" -Value (Get-RunUserReportObservedValue -Read { Get-SourceInfoBasePath })
    Add-RunUserReportLine -Lines $lines -Label "Пользователь информационной базы" -Value (Get-RunUserReportObservedValue -Read { Get-EnvValue -Name "IB_USER" }) -Default "<пусто>"
    $usesRepository = [bool](Get-RunUserReportObservedValue -Read { Get-SourceUsesRepository } -Default $false)
    Add-RunUserReportLine -Lines $lines -Label "Хранилище конфигурации" -Value $(if ($usesRepository) { "используется" } else { "не используется" })
    if ($usesRepository) {
        Add-RunUserReportLine -Lines $lines -Label "Адрес хранилища" -Value (Get-RunUserReportObservedValue -Read { Get-RepositoryPath })
        Add-RunUserReportLine -Lines $lines -Label "Пользователь хранилища" -Value (Get-RunUserReportObservedValue -Read { Get-EnvValue -Name "REPOSITORY_USER" }) -Default "<пусто>"
    }
    Add-RunUserReportLine -Lines $lines -Label "Режим зависимостей" -Value (Get-RunUserReportObservedValue -Read { Get-DependencyMode })
    $publishDefault = [bool](Get-RunUserReportObservedValue -Read { Get-WebPublishByDefault } -Default $false)
    $publishAuto = [bool](Get-RunUserReportObservedValue -Read { Get-WebPublishAuto } -Default $false)
    $publishMode = if (-not $publishDefault) { "disabled" } elseif ($publishAuto) { "automatic" } else { "manual" }
    Add-RunUserReportLine -Lines $lines -Label "Web-публикация веток" -Value (ConvertTo-RunUserReportStateDisplay -Value $publishMode -Kind PublicationMode)

    $lines.Add("")
    $lines.Add("## MCP")
    $facadeExecutable = [string](Get-RunUserReportObservedValue -Read { Get-ItlOnDemandMcpExecutablePath -AllowMissing } -Default "")
    $facadeStatus = if ($facadeExecutable -and (Test-Path -LiteralPath $facadeExecutable -PathType Leaf)) { "ready" } else { "missing" }
    Add-RunUserReportLine -Lines $lines -Label "Шлюз ITL on-demand MCP" -Value (ConvertTo-RunUserReportStateDisplay -Value $facadeStatus -Kind Availability)
    Add-Vibecoding1cRunUserReportLines -Lines $lines -AdviceLines $advice
    Add-KiloBrowserRunUserReportLines -McpLines $lines -AdviceLines $advice -ProjectRoot $script:ProjectRoot

    if (-not $usesRepository) {
        $advice.Add("- Обновление из хранилища не выполнялось; выгрузка master использует текущее состояние исходной информационной базы.")
    }
    if (-not $facadeExecutable -or -not (Test-Path -LiteralPath $facadeExecutable -PathType Leaf)) {
        $advice.Add("- Шлюз ITL on-demand MCP не найден. Перед использованием branch-local MCP проверьте журнал инициализации.")
    }
    if ($VibecodingDeferred) {
        $advice.Add("- Настройка vibecoding1c MCP отложена. Попросите агента настроить её, когда она понадобится.")
    }
    if ($script:RunRequiredAction) {
        $advice.Add("- $($script:RunRequiredAction)")
    }
    if ($advice.Count -gt 0) {
        $lines.Add("")
        $lines.Add("## Инструкции и рекомендации")
        foreach ($item in $advice) { $lines.Add($item) }
    }
    Write-AndSetRunUserReport -Lines $lines
}

function Set-RunDevBranchState {
    param([object]$State)

    $script:RunDevBranch = Get-StateValue -State $State -Name "devBranch" -Default ""
    $script:RunWorktreePath = Get-StateValue -State $State -Name "worktreePath" -Default (Get-StateValue -State $State -Name "stateProjectRoot" -Default "")
    $script:RunExtensionInitializationStatus = Get-DevBranchExtensionInitializationStatus -State $State
}

function Write-DevBranchRunUserReport {
    param(
        [object]$State,
        [string]$AdvisoryRoot,
        [ValidateSet("created", "refreshed")]
        [string]$Operation = "created",
        [AllowNull()][object]$LoadResult = $null
    )

    Set-RunDevBranchState -State $State
    $lines = [System.Collections.Generic.List[string]]::new()
    $advice = [System.Collections.Generic.List[string]]::new()
    $isRefresh = $Operation -eq "refreshed"
    $lines.Add($(if ($isRefresh) { "## Обновление ветки разработки" } else { "## Ветка разработки" }))
    if ($isRefresh) {
        Add-RunUserReportLine -Lines $lines -Label "Результат" -Value "успешно"
    }
    Add-RunUserReportLine -Lines $lines -Label "Тип" -Value (ConvertTo-RunUserReportStateDisplay -Value (Get-DevBranchKind -State $State) -Kind BranchKind)
    Add-RunUserReportLine -Lines $lines -Label "Ветка" -Value (Get-StateValue -State $State -Name "devBranch" -Default "")
    Add-RunUserReportLine -Lines $lines -Label "Основной worktree" -Value (Get-StateValue -State $State -Name "mainWorktreePath" -Default "")
    Add-RunUserReportLine -Lines $lines -Label "Worktree разработки" -Value (Get-StateValue -State $State -Name "worktreePath" -Default $AdvisoryRoot)
    Add-RunUserReportLine -Lines $lines -Label "Информационная база" -Value (Get-StateValue -State $State -Name "devBranchInfoBasePath" -Default "")
    if ($isRefresh) {
        Add-RunUserReportLine -Lines $lines -Label "Коммит ветки" -Value (Get-StateValue -State $LoadResult -Name "currentCommit" -Default (Get-StateValue -State $State -Name "lastConfigBaseUpdatedCommit" -Default ""))
        $configurationUpdate = if ($null -ne $LoadResult -and [bool](Get-StateValue -State $LoadResult -Name "loaded" -Default $false)) { "выполнено" } else { "не требовалось" }
        Add-RunUserReportLine -Lines $lines -Label "Обновление конфигурации базы" -Value $configurationUpdate
        $loadMode = [string](Get-StateValue -State $LoadResult -Name "loadModeUsed" -Default "")
        $loadModeDisplay = switch ($loadMode) {
            "partial" { "частичная загрузка" }
            "full" { "полная загрузка" }
            "full-fallback" { "полная загрузка после ошибки частичной" }
            default { "не применялся" }
        }
        Add-RunUserReportLine -Lines $lines -Label "Режим загрузки" -Value $loadModeDisplay
        $enterpriseUpdate = if ($null -ne $LoadResult -and [bool](Get-StateValue -State $LoadResult -Name "enterpriseInvoked" -Default $false)) { "выполнено" } else { "не требовалось" }
        Add-RunUserReportLine -Lines $lines -Label "Enterprise-автообновление" -Value $enterpriseUpdate
    } else {
        Add-RunUserReportLine -Lines $lines -Label "База в launcher 1С" -Value (Get-StateValue -State $State -Name "launcherInfoBaseName" -Default "")
        Add-RunUserReportLine -Lines $lines -Label "Папка в launcher 1С" -Value (Get-StateValue -State $State -Name "launcherFolder" -Default "")
        $publicationUrl = Get-StateValue -State $State -Name "publicationUrl" -Default ""
        if ($publicationUrl) {
            Add-RunUserReportLine -Lines $lines -Label "URL публикации" -Value $publicationUrl
        } else {
            $publicationStatus = Get-StateValue -State $State -Name "publicationStatus" -Default ""
            Add-RunUserReportLine -Lines $lines -Label "Публикация" -Value (ConvertTo-RunUserReportStateDisplay -Value $publicationStatus -Kind PublicationStatus)
        }
    }
    $publicationError = [string](Get-StateValue -State $State -Name "publicationError" -Default "")
    if ((Get-DevBranchKind -State $State) -eq "extension") {
        Add-RunUserReportLine -Lines $lines -Label "Инициализация расширения" -Value (ConvertTo-RunUserReportStateDisplay -Value (Get-DevBranchExtensionInitializationStatus -State $State) -Kind ExtensionStatus)
    }

    $lines.Add("")
    $lines.Add("## MCP")
    Add-RunUserReportLine -Lines $lines -Label "ROCTUP MCP" -Value (ConvertTo-RunUserReportStateDisplay -Value (Get-StateValue -State $State -Name "roctupMcpStatus" -Default "unknown") -Kind McpStatus)
    Add-RunUserReportLine -Lines $lines -Label "Vanessa UI MCP" -Value (ConvertTo-RunUserReportStateDisplay -Value (Get-StateValue -State $State -Name "vanessaMcpStatus" -Default "unknown") -Kind McpStatus)
    Add-Vibecoding1cRunUserReportLines -Lines $lines -AdviceLines $advice
    Add-KiloBrowserRunUserReportLines -McpLines $lines -AdviceLines $advice -ProjectRoot $AdvisoryRoot

    $extensionStatus = Get-DevBranchExtensionInitializationStatus -State $State
    if ($isRefresh) {
        $client = [string](Get-RunUserReportObservedValue -Read { Get-ItlActiveClient } -Default "")
        if ($client -eq "kilocode") {
            $advice.Add("- Выполните /reload в текущем окне Kilo Code, чтобы клиент перечитал обновлённые правила, навыки и команды ветки.")
        } else {
            $reloadInstruction = [string](Get-RunUserReportObservedValue -Read {
                Get-StateValue -State (Get-ItlClientAdapter -Client $client) -Name "reloadUserReport" -Default "Перезапустите активный клиент."
            } -Default "Перезапустите активный клиент.")
            $advice.Add("- Заставьте текущий клиент перечитать обновлённый проект: $reloadInstruction")
        }
        $advice.Add("- Перед продолжением разработки выполните /itl-check.")
        if ((Get-DevBranchKind -State $State) -eq "extension") {
            $advice.Add("- Файлы расширения при обновлении ветки не загружались; /itl-check обновит расширение в базе перед проверкой.")
        }
    } elseif ((Get-DevBranchKind -State $State) -eq "extension") {
        if ($extensionStatus -eq "pending") {
            $advice.Add("- В worktree расширения уточните у разработчика, нужно создать пустое расширение или загрузить CFE, затем получите имя расширения и, при необходимости, путь к CFE.")
        } elseif ($extensionStatus -eq "ready") {
            $advice.Add("- Перед завершением задачи разработки выполните /itl-check.")
        }
    }
    if ($publicationError) {
        $advice.Add("- Web-публикация не завершена. При необходимости попросите агента повторить или завершить публикацию ветки.")
    }
    if ($script:RunRequiredAction) {
        $advice.Add("- $($script:RunRequiredAction)")
    }
    if ($advice.Count -gt 0) {
        $lines.Add("")
        $lines.Add("## Инструкции и рекомендации")
        foreach ($item in $advice) { $lines.Add($item) }
    }
    Write-AndSetRunUserReport -Lines $lines
}

function Clear-DevBranchContext {
    Set-DotEnvValues -Values @{
        INFOBASE_PATH = ""
        INFOBASE_PUBLISH_URL = ""
        EXTENSION_NAME = ""
        EXPORT_PATH = ""
        ITL_ACTIVE_DEV_BRANCH = ""
        ITL_ACTIVE_DEV_BRANCH_KIND = ""
        ITL_ACTIVE_CONTEXT_UPDATED_AT = (Get-Date).ToString("o")
        VANESSA_TEST_PORT = ""
        VANESSA_MCP_PORT = ""
        VANESSA_MCP_URL = ""
        ROCTUP_MCP_PORT = ""
        ROCTUP_MCP_URL = ""
        ROCTUP_MCP_HEALTH_URL = ""
    }
    Import-DotEnv -Path (Join-Path $script:ProjectRoot ".dev.env") -Overwrite
    Write-Host "Development branch context cleared in .dev.env."
}

function Sync-DevBranchContextToDotEnv {
    param(
        [object]$State,
        [switch]$AllowIncompleteExtension
    )

    $kind = Get-DevBranchKind -State $State
    $values = @{
        INFOBASE_KIND = (Get-StateValue -State $State -Name "infoBaseKind" -Default (Get-InfoBaseKind))
        INFOBASE_PATH = (Require-Value "devBranchInfoBasePath" (Get-StateValue -State $State -Name "devBranchInfoBasePath"))
        INFOBASE_PUBLISH_URL = (Get-StateValue -State $State -Name "publicationUrl" -Default "")
        EXPORT_PATH = (Get-ExportPath)
        EXTENSION_NAME = ""
        ITL_ACTIVE_DEV_BRANCH = (Get-StateValue -State $State -Name "devBranch" -Default "")
        ITL_ACTIVE_DEV_BRANCH_KIND = $kind
        ITL_ACTIVE_CONTEXT_UPDATED_AT = (Get-Date).ToString("o")
        VANESSA_TEST_PORT = (Get-StateValue -State $State -Name "vanessaTestPort" -Default "")
        VANESSA_MCP_PORT = (Get-StateValue -State $State -Name "vanessaMcpPort" -Default "")
        VANESSA_MCP_URL = (Get-StateValue -State $State -Name "vanessaMcpUrl" -Default "")
        ROCTUP_MCP_PORT = (Get-StateValue -State $State -Name "roctupMcpPort" -Default "")
        ROCTUP_MCP_URL = (Get-StateValue -State $State -Name "roctupMcpUrl" -Default "")
        ROCTUP_MCP_HEALTH_URL = (Get-StateValue -State $State -Name "roctupMcpHealthUrl" -Default "")
    }

    if ($kind -eq "extension") {
        $extensionName = Get-StateValue -State $State -Name "extensionName" -Default ""
        if (-not $extensionName) {
            if ($AllowIncompleteExtension) {
                $values["INFOBASE_PATH"] = ""
                $values["INFOBASE_PUBLISH_URL"] = ""
                $values["EXPORT_PATH"] = ""
                $values["EXTENSION_NAME"] = ""
                Set-DotEnvValues -Values $values
                Import-DotEnv -Path (Join-Path $script:ProjectRoot ".dev.env") -Overwrite
                Write-Host "Development branch context is incomplete: extension initialization is pending. The agent must collect Empty or CFE, extension name, and optional CFE path in chat before development work."
                return
            }
            Require-DevBranchExtensionName -State $State | Out-Null
        }
        $values["EXTENSION_NAME"] = $extensionName
        $values["EXPORT_PATH"] = Get-DevBranchExtensionExportPath -State $State
    }

    Set-DotEnvValues -Values $values
    Import-DotEnv -Path (Join-Path $script:ProjectRoot ".dev.env") -Overwrite
    Write-Host "Development branch context activated in .dev.env."
    Write-Host "Branch: $($values["ITL_ACTIVE_DEV_BRANCH"])"
    Write-Host "Infobase: $($values["INFOBASE_PATH"])"
    Write-Host "Export path: $($values["EXPORT_PATH"])"
    if ($values["EXTENSION_NAME"]) {
        Write-Host "Extension: $($values["EXTENSION_NAME"])"
    }
}

function Activate-DevBranchContext {
    $state = Read-DevBranchState -Name $DevBranchName
    Assert-CurrentProjectRootMatchesDevBranchState -State $state -Operation "activate-dev-branch-context"
    Assert-DevBranchExtensionInitialized -State $state -Operation "activate-dev-branch-context"
    Sync-DevBranchContextToDotEnv -State $state
}

function ConvertTo-LauncherLabel {
    param([AllowNull()][string]$Value)

    $text = [string]$Value
    $text = ($text -replace "[\r\n\[\]]", " ").Trim()
    $text = ($text -replace "\s+", " ")
    if (-not $text) {
        return "project"
    }
    return $text
}

function Get-LauncherListPath {
    $appData = $env:APPDATA
    if (-not $appData) {
        $appData = [Environment]::GetFolderPath("ApplicationData")
    }
    if (-not $appData) {
        throw "APPDATA path is not available; cannot update 1C infobase list."
    }

    return (Join-Path $appData "1C\1CEStart\ibases.v8i")
}

function Get-LauncherProjectFolder {
    param([string]$ProjectRootForFolder = $script:ProjectRoot)

    return "/ITL/" + (Get-LauncherProjectName -ProjectRootForName $ProjectRootForFolder)
}

function Get-LauncherProjectName {
    param([string]$ProjectRootForName = $script:ProjectRoot)

    $projectName = Split-Path -Leaf $ProjectRootForName
    return (ConvertTo-LauncherLabel -Value $projectName)
}

function Get-LauncherInfoBaseName {
    param(
        [string]$SafeDevBranchName,
        [string]$ProjectRootForName = $script:ProjectRoot
    )

    $projectName = Get-LauncherProjectName -ProjectRootForName $ProjectRootForName
    return "$projectName-$SafeDevBranchName"
}

function New-LauncherConnectString {
    param(
        [string]$InfoBaseKind,
        [string]$InfoBasePath
    )

    if ($InfoBaseKind -eq "file") {
        $resolved = Resolve-InfoBasePath $InfoBasePath
        return "File=`"$resolved`";"
    }
    if ($InfoBaseKind -eq "server") {
        return (Require-Value "development branch server infobase connection string" $InfoBasePath)
    }

    throw "Unknown infobase kind: $InfoBaseKind"
}

function Get-LauncherSections {
    param([string[]]$Lines)

    $sections = New-Object System.Collections.ArrayList
    $current = $null
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $line = $Lines[$i]
        if ($line -match '^\[(.*)\]\s*$') {
            if ($null -ne $current) {
                $current["end"] = $i - 1
                [void]$sections.Add([pscustomobject]$current)
            }
            $current = @{
                name = $matches[1]
                start = $i
                end = $i
                values = @{}
            }
            continue
        }

        if ($null -ne $current -and $line -match '^([^=]+)=(.*)$') {
            $current["values"][$matches[1]] = $matches[2]
        }
    }

    if ($null -ne $current) {
        $current["end"] = $Lines.Count - 1
        [void]$sections.Add([pscustomobject]$current)
    }

    return @($sections)
}

function Get-LauncherMaxIntValue {
    param(
        [object[]]$Sections,
        [string]$Key
    )

    $max = 0
    foreach ($section in $Sections) {
        if (-not $section.values.ContainsKey($Key)) {
            continue
        }
        $value = 0
        if ([int]::TryParse([string]$section.values[$Key], [ref]$value) -and $value -gt $max) {
            $max = $value
        }
    }
    return $max
}

function Register-DevBranchInLauncher {
    param(
        [string]$InfoBaseKind,
        [string]$InfoBasePath,
        [string]$SafeDevBranchName,
        [string]$ProjectRootForFolder = $script:ProjectRoot,
        [string]$ExistingLauncherId = ""
    )

    $listPath = Get-LauncherListPath
    $listDir = Split-Path -Parent $listPath
    New-Item -ItemType Directory -Force -Path $listDir | Out-Null

    $lines = @()
    if (Test-Path -LiteralPath $listPath -PathType Leaf) {
        $lines = @(Read-Utf8Lines -Path $listPath)
    }

    $sections = @(Get-LauncherSections -Lines $lines)
    $displayName = Get-LauncherInfoBaseName -SafeDevBranchName $SafeDevBranchName -ProjectRootForName $ProjectRootForFolder
    $folder = Get-LauncherProjectFolder -ProjectRootForFolder $ProjectRootForFolder
    $connect = New-LauncherConnectString -InfoBaseKind $InfoBaseKind -InfoBasePath $InfoBasePath

    $target = $null
    foreach ($section in $sections) {
        if ($ExistingLauncherId -and $section.values.ContainsKey("ID") -and $section.values["ID"] -eq $ExistingLauncherId) {
            $target = $section
            break
        }
    }
    if ($null -eq $target) {
        foreach ($section in $sections) {
            if ($section.values.ContainsKey("Connect") -and $section.values["Connect"] -eq $connect) {
                $target = $section
                break
            }
        }
    }
    if ($null -eq $target) {
        foreach ($section in $sections) {
            if ($section.name -eq $displayName -and $section.values.ContainsKey("Folder") -and $section.values["Folder"] -eq $folder) {
                $target = $section
                break
            }
        }
    }

    $id = if ($target -and $target.values.ContainsKey("ID") -and $target.values["ID"]) { $target.values["ID"] } elseif ($ExistingLauncherId) { $ExistingLauncherId } else { [guid]::NewGuid().ToString() }
    $orderInList = if ($target -and $target.values.ContainsKey("OrderInList")) { $target.values["OrderInList"] } else { [string]((Get-LauncherMaxIntValue -Sections $sections -Key "OrderInList") + 16384) }
    $orderInTree = if ($target -and $target.values.ContainsKey("OrderInTree")) { $target.values["OrderInTree"] } else { [string]((Get-LauncherMaxIntValue -Sections $sections -Key "OrderInTree") + 256) }

    $entry = @(
        "[$displayName]",
        "Connect=$connect",
        "ID=$id",
        "OrderInList=$orderInList",
        "Folder=$folder",
        "OrderInTree=$orderInTree",
        "External=0",
        "ClientConnectionSpeed=Normal",
        "App=Auto",
        "WA=1",
        "Version=8.3"
    )

    $result = New-Object System.Collections.ArrayList
    if ($target) {
        for ($i = 0; $i -lt $target.start; $i++) {
            [void]$result.Add($lines[$i])
        }
        foreach ($line in $entry) {
            [void]$result.Add($line)
        }
        for ($i = $target.end + 1; $i -lt $lines.Count; $i++) {
            [void]$result.Add($lines[$i])
        }
    } else {
        foreach ($line in $lines) {
            [void]$result.Add($line)
        }
        if ($result.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$result[$result.Count - 1])) {
            [void]$result.Add("")
        }
        foreach ($line in $entry) {
            [void]$result.Add($line)
        }
    }

    if (Test-Path -LiteralPath $listPath -PathType Leaf) {
        $backupPath = "$listPath.$(Get-Date -Format 'yyyyMMdd-HHmmss').bak"
        Copy-Item -LiteralPath $listPath -Destination $backupPath -Force
    }

    [System.IO.File]::WriteAllLines($listPath, [string[]]$result.ToArray([string]), (Get-Utf8BomEncoding))
    Write-Host "Registered development branch infobase in 1C launcher list: $displayName"
    Write-Host "Launcher folder: $folder"

    return [pscustomobject]@{
        registered = $true
        name = $displayName
        folder = $folder
        id = $id
        listPath = $listPath
        connect = $connect
    }
}

function Get-SourceInfoBaseUnsafeActionProtectionStatePath {
    param([string]$ProjectRootOverride = $script:ProjectRoot)
    return (Join-Path $ProjectRootOverride ".agent-1c\source-infobase-unsafe-action-protection.json")
}

function Get-SourceInfoBaseUnsafeActionProtectionContext {
    param([string]$ProjectRootOverride = $script:ProjectRoot)
    $kind = ([string](Get-InfoBaseKind)).Trim().ToLowerInvariant()
    $source = [string](Get-SourceInfoBasePath)
    $identity = if ($kind -eq "file") {
        $sourcePath = if ([System.IO.Path]::IsPathRooted($source)) { $source } else { Join-Path $ProjectRootOverride $source }
        (Resolve-Agent1cFullPath -Path $sourcePath).TrimEnd("\", "/").ToLowerInvariant()
    } else {
        $source.Trim().ToLowerInvariant()
    }
    $user = ([string](Get-EnvValue -Name "IB_USER")).Trim()
    $payload = "$kind`n$identity`n$($user.ToLowerInvariant())"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $key = ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
    return [pscustomobject]@{
        key = $key
        infoBaseKind = $kind
        sourceIdentity = $identity
        user = $user
    }
}

function Get-ValidSourceInfoBaseUnsafeActionProtectionConfirmation {
    param([string]$ProjectRootOverride = $script:ProjectRoot)

    $path = Get-SourceInfoBaseUnsafeActionProtectionStatePath -ProjectRootOverride $ProjectRootOverride
    if (-not (Test-Path -LiteralPath $path -PathType Leaf -ErrorAction SilentlyContinue)) {
        return $null
    }
    try {
        $state = Read-Utf8Text -Path $path | ConvertFrom-Json
        $context = Get-SourceInfoBaseUnsafeActionProtectionContext -ProjectRootOverride $ProjectRootOverride
        if (-not (ConvertTo-BoolSetting -Value (Get-StateValue -State $state -Name "confirmed" -Default $false) -Default $false)) {
            return $null
        }
        if ([string](Get-StateValue -State $state -Name "sourceKey" -Default "") -ne $context.key) {
            return $null
        }
        return $state
    } catch {
        Write-Warning "Ignoring unreadable source unsafe-action protection confirmation: $path. $($_.Exception.Message)"
        return $null
    }
}

function Save-SourceInfoBaseUnsafeActionProtectionConfirmation {
    param([ValidateSet("manual-confirm", "confirmed")][string]$ConfirmationMode)

    $context = Get-SourceInfoBaseUnsafeActionProtectionContext
    $state = [ordered]@{
        schemaVersion = 1
        sourceKey = $context.key
        infoBaseKind = $context.infoBaseKind
        sourceIdentity = $context.sourceIdentity
        infoBaseUser = $context.user
        confirmationMode = $ConfirmationMode
        confirmed = $true
        confirmedAt = (Get-Date).ToString("o")
    }
    $path = Get-SourceInfoBaseUnsafeActionProtectionStatePath
    Write-Utf8Text -Path $path -Value (($state | ConvertTo-Json -Depth 5) + [Environment]::NewLine)
    return [pscustomobject]$state
}

function Clear-SourceInfoBaseUnsafeActionProtectionConfirmation {
    $path = Get-SourceInfoBaseUnsafeActionProtectionStatePath
    if (Test-Path -LiteralPath $path -PathType Leaf -ErrorAction SilentlyContinue) {
        Remove-Item -LiteralPath $path -Force
    }
}

function Get-SourceInfoBaseUnsafeActionProtectionMode {
    return ConvertTo-SourceInfoBaseUnsafeActionProtectionMode (Require-Value "SOURCE_INFOBASE_UNSAFE_ACTION_PROTECTION_MODE or project.sourceInfoBaseUnsafeActionProtectionMode" (Get-Setting -EnvName "SOURCE_INFOBASE_UNSAFE_ACTION_PROTECTION_MODE" -ConfigName "sourceInfoBaseUnsafeActionProtectionMode"))
}

function Get-DevBranchUnsafeActionProtectionSetupRaw {
    return (Get-Setting -EnvName "DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP" -ConfigName "devBranchUnsafeActionProtectionSetup" -Default "manual-confirm").Trim().ToLowerInvariant()
}

function Get-DevBranchUnsafeActionProtectionSetup {
    $value = Get-DevBranchUnsafeActionProtectionSetupRaw
    if ($value -notin @("manual-confirm", "skip")) {
        throw "Unsupported DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP value: $value. Use manual-confirm or skip."
    }

    return $value
}

function Get-DevBranchUnsafeActionProtectionInteractiveRequiredMessage {
    return "Подтверждение отключения защиты от опасных действий требует интерактивного ввода. Запустите создание ветки через .\.agents\skills\1c-workflow\scripts\run-agent-1c-window.ps1 -- -Action new-dev-branch -DevBranchName ""<имя-ветки>"" (для расширения используйте -Action new-extension-dev-branch) или явно задайте DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP=skip, если защита уже отключена отдельно."
}

function Assert-DevBranchUnsafeActionProtectionPromptAvailable {
    if ($null -ne (Get-ValidSourceInfoBaseUnsafeActionProtectionConfirmation)) {
        return
    }
    $mode = Get-DevBranchUnsafeActionProtectionSetupRaw
    if ($mode -eq "manual-confirm" -and -not (Test-InteractiveInputAvailable)) {
        throw (Get-DevBranchUnsafeActionProtectionInteractiveRequiredMessage)
    }
}

function Show-DevBranchUnsafeActionProtectionAttention {
    $title = Get-Agent1cUtf8Text "SVRMOiDRgtGA0LXQsdGD0LXRgtGB0Y8g0L/QvtC00YLQstC10YDQttC00LXQvdC40LUg0LfQsNGJ0LjRgtGL"
    try {
        [Console]::Title = $title
    } catch {
    }

    try {
        if (-not ("ItlConsoleWindowAttention" -as [type])) {
            Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class ItlConsoleWindowAttention
{
    [StructLayout(LayoutKind.Sequential)]
    private struct FLASHWINFO
    {
        public uint cbSize;
        public IntPtr hwnd;
        public uint dwFlags;
        public uint uCount;
        public uint dwTimeout;
    }

    [DllImport("kernel32.dll")]
    private static extern IntPtr GetConsoleWindow();

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool FlashWindowEx(ref FLASHWINFO info);

    public static bool FlashTaskbar()
    {
        IntPtr hwnd = GetConsoleWindow();
        if (hwnd == IntPtr.Zero) return false;
        FLASHWINFO info = new FLASHWINFO
        {
            cbSize = (uint)Marshal.SizeOf(typeof(FLASHWINFO)),
            hwnd = hwnd,
            dwFlags = 3,
            uCount = 5,
            dwTimeout = 0
        };
        return FlashWindowEx(ref info);
    }
}
"@
        }
        [ItlConsoleWindowAttention]::FlashTaskbar() | Out-Null
    } catch {
    }

    try {
        [Console]::Beep(880, 250)
    } catch {
    }
}

function Confirm-DevBranchUnsafeActionProtection {
    param(
        [string]$InfoBaseKind,
        [string]$InfoBasePath,
        [string]$DevBranchName,
        [ValidateSet("", "manual-confirm", "skip")]
        [string]$SetupModeOverride = ""
    )

    function Get-UnsafeActionProtectionMessage {
        param([int]$Index)

        $messages = @(
            "0J/QoNCV0JTQo9Cf0KDQldCW0JTQldCd0JjQlTog0L/QvtC00YLQstC10YDQttC00LXQvdC40LUg0L7RgtC60LvRjtGH0LXQvdC40Y8g0LfQsNGJ0LjRgtGLINC+0YIg0L7Qv9Cw0YHQvdGL0YUg0LTQtdC50YHRgtCy0LjQuSDQv9GA0L7Qv9GD0YnQtdC90L4g0L/QviDQvdCw0YHRgtGA0L7QudC60LUgREVWX0JSQU5DSF9VTlNBRkVfQUNUSU9OX1BST1RFQ1RJT05fU0VUVVA9c2tpcC4=",
            "0J/QvtC00YLQstC10YDQttC00LXQvdC40LUg0LfQsNGJ0LjRgtGLINC+0YIg0L7Qv9Cw0YHQvdGL0YUg0LTQtdC50YHRgtCy0LjQuQ==",
            "0JLQtdGC0LrQsCDRgNCw0LfRgNCw0LHQvtGC0LrQuDog",
            "0JHQsNC30LAg0LLQtdGC0LrQuCDRgNCw0LfRgNCw0LHQvtGC0LrQuDog",
            "0J/QvtC70YzQt9C+0LLQsNGC0LXQu9GMINC40L3RhNC+0YDQvNCw0YbQuNC+0L3QvdC+0Lkg0LHQsNC30Ys6IA==",
            "0J/QvtC70YzQt9C+0LLQsNGC0LXQu9GMINC40L3RhNC+0YDQvNCw0YbQuNC+0L3QvdC+0Lkg0LHQsNC30Ysg0LIgLmRldi5lbnYg0L3QtSDQt9Cw0LTQsNC9Lg==",
            "0J7RgtC60LvRjtGH0LjRgtC1INC30LDRidC40YLRgyDRgyDQv9C+0LvRjNC30L7QstCw0YLQtdC70Y8g0JjQkSwg0L/QvtC0INC60L7RgtC+0YDRi9C8INGA0LDQt9GA0LDQsdC+0YLRh9C40Log0YDQsNCx0L7RgtCw0LXRgiDRgSDQsdCw0LfQvtC5INCy0LXRgtC60Lgu",
            "0JXRgdC70Lgg0L7RgtCy0LXRgiDQvdC1INCU0JAsINCx0YPQtNC10YIg0LfQsNC/0YPRidC10L0g0JrQvtC90YTQuNCz0YPRgNCw0YLQvtGALiDQkiDQvdC10Lwg0L3Rg9C20L3QviDQvtGC0LrQu9GO0YfQuNGC0Ywg0LfQsNGJ0LjRgtGDINC+0YIg0L7Qv9Cw0YHQvdGL0YUg0LTQtdC50YHRgtCy0LjQuSwg0YHQvtGF0YDQsNC90LjRgtGMINC/0L7Qu9GM0LfQvtCy0LDRgtC10LvRjyDQuCDQt9Cw0LrRgNGL0YLRjCDQmtC+0L3RhNC40LPRg9GA0LDRgtC+0YAu",
            "0JfQsNGJ0LjRgtCwINC+0YIg0L7Qv9Cw0YHQvdGL0YUg0LTQtdC50YHRgtCy0LjQuSDRg9C20LUg0L7RgtC60LvRjtGH0LXQvdCwPyDQktCy0LXQtNC40YLQtSDQlNCQINC00LvRjyDQv9GA0L7QtNC+0LvQttC10L3QuNGP",
            "0JTQkA==",
            "0KHQtdC50YfQsNGBINCx0YPQtNC10YIg0L7RgtC60YDRi9GCINCa0L7QvdGE0LjQs9GD0YDQsNGC0L7RgCDQsdCw0LfRiyDQstC10YLQutC4INGA0LDQt9GA0LDQsdC+0YLQutC4Lg==",
            "0JjQvdGB0YLRgNGD0LrRhtC40Y86",
            "MS4g0J7RgtC60YDQvtC50YLQtSDRgdC/0LjRgdC+0Log0L/QvtC70YzQt9C+0LLQsNGC0LXQu9C10Lkg0LjQvdGE0L7RgNC80LDRhtC40L7QvdC90L7QuSDQsdCw0LfRiy4=",
            "Mi4g0JLRi9Cx0LXRgNC40YLQtSDQv9C+0LvRjNC30L7QstCw0YLQtdC70Y8gJ3swfScsINC/0L7QtCDQutC+0YLQvtGA0YvQvCB3b3JrZmxvdyDQt9Cw0L/Rg9GB0LrQsNC10YIg0L7QsdGA0LDQsdC+0YLQutC4INC4INGA0LDRgdGI0LjRgNC10L3QuNGPLg==",
            "Mi4g0JLRi9Cx0LXRgNC40YLQtSDQv9C+0LvRjNC30L7QstCw0YLQtdC70Y8g0JjQkSwg0L/QvtC0INC60L7RgtC+0YDRi9C8INGA0LDQt9GA0LDQsdC+0YLRh9C40Log0YDQsNCx0L7RgtCw0LXRgiDRgSDQsdCw0LfQvtC5INCy0LXRgtC60Lgu",
            "My4g0J7RgtC60LvRjtGH0LjRgtC1INC30LDRidC40YLRgyDQvtGCINC+0L/QsNGB0L3Ri9GFINC00LXQudGB0YLQstC40Lku",
            "NC4g0KHQvtGF0YDQsNC90LjRgtC1INC/0L7Qu9GM0LfQvtCy0LDRgtC10LvRjy4=",
            "NS4g0JfQsNC60YDQvtC50YLQtSDQmtC+0L3RhNC40LPRg9GA0LDRgtC+0YAu",
            "Ni4g0J/QvtGB0LvQtSDQt9Cw0LrRgNGL0YLQuNGPINC/0L7QtNGC0LLQtdGA0LTQuNGC0LUg0JTQkCDQsiDRjdGC0L7QvCDQvtC60L3QtSBQb3dlclNoZWxsLg=="
        )

        return [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($messages[$Index]))
    }

    $mode = if ($SetupModeOverride) { $SetupModeOverride } else { Get-DevBranchUnsafeActionProtectionSetup }
    $user = [string](Get-EnvValue -Name "IB_USER")
    if ($mode -eq "skip") {
        Write-Host (Get-UnsafeActionProtectionMessage 0)
        return [pscustomobject]@{
            mode = $mode
            confirmed = $false
            confirmedAt = ""
            user = $user
        }
    }

    Write-Section (Get-UnsafeActionProtectionMessage 1)
    while ($true) {
        Show-DevBranchUnsafeActionProtectionAttention
        Write-Host ((Get-UnsafeActionProtectionMessage 2) + $DevBranchName)
        Write-Host ((Get-UnsafeActionProtectionMessage 3) + $InfoBasePath)
        if ($user) {
            Write-Host ((Get-UnsafeActionProtectionMessage 4) + $user)
        } else {
            Write-Host (Get-UnsafeActionProtectionMessage 5)
            Write-Host (Get-UnsafeActionProtectionMessage 6)
        }
        Write-Host (Get-UnsafeActionProtectionMessage 7)

        $answerValue = Read-Host (Get-UnsafeActionProtectionMessage 8)
        if ($null -eq $answerValue) {
            throw (Get-DevBranchUnsafeActionProtectionInteractiveRequiredMessage)
        }
        $answer = ([string]$answerValue).Trim()
        if ([string]::Equals($answer, (Get-UnsafeActionProtectionMessage 9), [System.StringComparison]::OrdinalIgnoreCase)) {
            return [pscustomobject]@{
                mode = $mode
                confirmed = $true
                confirmedAt = (Get-Date).ToString("o")
                user = $user
            }
        }

        Write-Host (Get-UnsafeActionProtectionMessage 10)
        Write-Host (Get-UnsafeActionProtectionMessage 11)
        Write-Host (Get-UnsafeActionProtectionMessage 12)
        if ($user) {
            Write-Host ((Get-UnsafeActionProtectionMessage 13) -f $user)
        } else {
            Write-Host (Get-UnsafeActionProtectionMessage 14)
        }
        Write-Host (Get-UnsafeActionProtectionMessage 15)
        Write-Host (Get-UnsafeActionProtectionMessage 16)
        Write-Host (Get-UnsafeActionProtectionMessage 17)
        Write-Host (Get-UnsafeActionProtectionMessage 18)

        Invoke-DesignerInteractive `
            -InfoBasePath $InfoBasePath `
            -InfoBaseKind $InfoBaseKind `
            -User $user `
            -Password (Get-EnvValue -Name "IB_PASSWORD") | Out-Null
    }
}

function Confirm-SourceInfoBaseUnsafeActionProtection {
    function Get-SourceUnsafeActionProtectionMessage {
        param([int]$Index)
        $messages = @(
            "0J/QvtC00YLQstC10YDQttC00LXQvdC40LUg0LfQsNGJ0LjRgtGLINC+0YIg0L7Qv9Cw0YHQvdGL0YUg0LTQtdC50YHRgtCy0LjQuQ==",
            "0JrQvtC90YLQtdC60YHRgjog",
            "0JjQvdGE0L7RgNC80LDRhtC40L7QvdC90LDRjyDQsdCw0LfQsDog",
            "0J/QvtC70YzQt9C+0LLQsNGC0LXQu9GMINC40L3RhNC+0YDQvNCw0YbQuNC+0L3QvdC+0Lkg0LHQsNC30Ys6IA==",
            "0J/QvtC70YzQt9C+0LLQsNGC0LXQu9GMINC40L3RhNC+0YDQvNCw0YbQuNC+0L3QvdC+0Lkg0LHQsNC30Ysg0LIgLmRldi5lbnYg0L3QtSDQt9Cw0LTQsNC9Lg==",
            "0J7RgtC60LvRjtGH0LjRgtC1INC30LDRidC40YLRgyDRgyDQv9C+0LvRjNC30L7QstCw0YLQtdC70Y8g0JjQkSwg0L/QvtC0INC60L7RgtC+0YDRi9C8IHdvcmtmbG93INC30LDQv9GD0YHQutCw0LXRgiDQvtCx0YDQsNCx0L7RgtC60Lgg0Lgg0YDQsNGB0YjQuNGA0LXQvdC40Y8u",
            "0JXRgdC70Lgg0L7RgtCy0LXRgiDQvdC1INCU0JAsINCx0YPQtNC10YIg0LfQsNC/0YPRidC10L0g0JrQvtC90YTQuNCz0YPRgNCw0YLQvtGALiDQkiDQvdC10Lwg0L3Rg9C20L3QviDQvtGC0LrQu9GO0YfQuNGC0Ywg0LfQsNGJ0LjRgtGDINC+0YIg0L7Qv9Cw0YHQvdGL0YUg0LTQtdC50YHRgtCy0LjQuSwg0YHQvtGF0YDQsNC90LjRgtGMINC/0L7Qu9GM0LfQvtCy0LDRgtC10LvRjyDQuCDQt9Cw0LrRgNGL0YLRjCDQmtC+0L3RhNC40LPRg9GA0LDRgtC+0YAu",
            "0JfQsNGJ0LjRgtCwINC+0YIg0L7Qv9Cw0YHQvdGL0YUg0LTQtdC50YHRgtCy0LjQuSDRg9C20LUg0L7RgtC60LvRjtGH0LXQvdCwPyDQktCy0LXQtNC40YLQtSDQlNCQINC00LvRjyDQv9GA0L7QtNC+0LvQttC10L3QuNGP",
            "0JTQkA==",
            "0KHQtdC50YfQsNGBINCx0YPQtNC10YIg0L7RgtC60YDRi9GCINCa0L7QvdGE0LjQs9GD0YDQsNGC0L7RgCDRg9C60LDQt9Cw0L3QvdC+0Lkg0LjQvdGE0L7RgNC80LDRhtC40L7QvdC90L7QuSDQsdCw0LfRiy4=",
            "0JjQvdGB0YLRgNGD0LrRhtC40Y86",
            "MS4g0J7RgtC60YDQvtC50YLQtSDRgdC/0LjRgdC+0Log0L/QvtC70YzQt9C+0LLQsNGC0LXQu9C10Lkg0LjQvdGE0L7RgNC80LDRhtC40L7QvdC90L7QuSDQsdCw0LfRiy4=",
            "Mi4g0JLRi9Cx0LXRgNC40YLQtSDQv9C+0LvRjNC30L7QstCw0YLQtdC70Y8gJ3swfScsINC/0L7QtCDQutC+0YLQvtGA0YvQvCB3b3JrZmxvdyDQt9Cw0L/Rg9GB0LrQsNC10YIg0L7QsdGA0LDQsdC+0YLQutC4INC4INGA0LDRgdGI0LjRgNC10L3QuNGPLg==",
            "Mi4g0JLRi9Cx0LXRgNC40YLQtSDQv9C+0LvRjNC30L7QstCw0YLQtdC70Y8g0JjQkSwg0L/QvtC0INC60L7RgtC+0YDRi9C8INGA0LDQt9GA0LDQsdC+0YLRh9C40Log0YDQsNCx0L7RgtCw0LXRgiDRgSDRjdGC0L7QuSDQsdCw0LfQvtC5Lg==",
            "My4g0J7RgtC60LvRjtGH0LjRgtC1INC30LDRidC40YLRgyDQvtGCINC+0L/QsNGB0L3Ri9GFINC00LXQudGB0YLQstC40Lku",
            "NC4g0KHQvtGF0YDQsNC90LjRgtC1INC/0L7Qu9GM0LfQvtCy0LDRgtC10LvRjy4=",
            "NS4g0JfQsNC60YDQvtC50YLQtSDQmtC+0L3RhNC40LPRg9GA0LDRgtC+0YAu",
            "Ni4g0J/QvtGB0LvQtSDQt9Cw0LrRgNGL0YLQuNGPINC/0L7QtNGC0LLQtdGA0LTQuNGC0LUg0JTQkCDQsiDRjdGC0L7QvCDQvtC60L3QtSBQb3dlclNoZWxsLg==",
            "0JjRgdGF0L7QtNC90LDRjyDQsdCw0LfQsCDQv9GA0L7QtdC60YLQsA=="
        )
        return [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($messages[$Index]))
    }

    $kind = Get-InfoBaseKind
    $path = Get-SourceInfoBasePath
    $user = [string](Get-EnvValue -Name "IB_USER")
    Write-Section (Get-SourceUnsafeActionProtectionMessage 0)
    while ($true) {
        Write-Host ((Get-SourceUnsafeActionProtectionMessage 1) + (Get-SourceUnsafeActionProtectionMessage 18))
        Write-Host ((Get-SourceUnsafeActionProtectionMessage 2) + $path)
        if ($user) {
            Write-Host ((Get-SourceUnsafeActionProtectionMessage 3) + $user)
        } else {
            Write-Host (Get-SourceUnsafeActionProtectionMessage 4)
            Write-Host (Get-SourceUnsafeActionProtectionMessage 5)
        }
        Write-Host (Get-SourceUnsafeActionProtectionMessage 6)
        $answerValue = Read-Host (Get-SourceUnsafeActionProtectionMessage 7)
        if ($null -eq $answerValue) {
            throw "Source infobase unsafe action protection confirmation requires interactive input."
        }
        if ([string]::Equals(([string]$answerValue).Trim(), (Get-SourceUnsafeActionProtectionMessage 8), [System.StringComparison]::OrdinalIgnoreCase)) {
            return [pscustomobject]@{ mode = "manual-confirm"; confirmed = $true; confirmedAt = (Get-Date).ToString("o"); user = $user }
        }
        Write-Host (Get-SourceUnsafeActionProtectionMessage 9)
        Write-Host (Get-SourceUnsafeActionProtectionMessage 10)
        Write-Host (Get-SourceUnsafeActionProtectionMessage 11)
        if ($user) {
            Write-Host ((Get-SourceUnsafeActionProtectionMessage 12) -f $user)
        } else {
            Write-Host (Get-SourceUnsafeActionProtectionMessage 13)
        }
        Write-Host (Get-SourceUnsafeActionProtectionMessage 14)
        Write-Host (Get-SourceUnsafeActionProtectionMessage 15)
        Write-Host (Get-SourceUnsafeActionProtectionMessage 16)
        Write-Host (Get-SourceUnsafeActionProtectionMessage 17)
        Invoke-DesignerInteractive -InfoBasePath $path -InfoBaseKind $kind -User $user -Password (Get-EnvValue -Name "IB_PASSWORD") | Out-Null
    }
}

function Initialize-SourceInfoBaseUnsafeActionProtection {
    $mode = Get-SourceInfoBaseUnsafeActionProtectionMode
    if ($mode -eq "defer") {
        Clear-SourceInfoBaseUnsafeActionProtectionConfirmation
        Write-Host (Get-Agent1cUtf8Text "0J/QvtC00YLQstC10YDQttC00LXQvdC40LUg0L7RgtC60LvRjtGH0LXQvdC40Y8g0LfQsNGJ0LjRgtGLINC+0YIg0L7Qv9Cw0YHQvdGL0YUg0LTQtdC50YHRgtCy0LjQuSDQtNC70Y8g0LjRgdGF0L7QtNC90L7QuSDQsdCw0LfRiyDQvtGC0LvQvtC20LXQvdC+INC00L4g0YHQvtC30LTQsNC90LjRjyDQstC10YLQutC4Lg==")
        return
    }
    if ($mode -eq "confirmed") {
        Save-SourceInfoBaseUnsafeActionProtectionConfirmation -ConfirmationMode "confirmed" | Out-Null
        Write-Host (Get-Agent1cUtf8Text "0J/QvtC00YLQstC10YDQttC00LXQvdC40LUg0L7RgtC60LvRjtGH0LXQvdC40Y8g0LfQsNGJ0LjRgtGLINC+0YIg0L7Qv9Cw0YHQvdGL0YUg0LTQtdC50YHRgtCy0LjQuSDQtNC70Y8g0LjRgdGF0L7QtNC90L7QuSDQsdCw0LfRiyDQv9GA0LjQvdGP0YLQviDQuNC3INGP0LLQvdC+0Lkg0L3QsNGB0YLRgNC+0LnQutC4IGNvbmZpcm1lZC4=")
        return
    }
    if (-not (Test-InteractiveInputAvailable)) {
        throw "Source infobase unsafe action protection mode manual-confirm requires interactive input. Use the monitored init launcher or choose defer/confirmed explicitly."
    }
    Confirm-SourceInfoBaseUnsafeActionProtection | Out-Null
    Save-SourceInfoBaseUnsafeActionProtectionConfirmation -ConfirmationMode "manual-confirm" | Out-Null
}

function Configure-DevBranchUnsafeActionProtection {
    $state = Read-DevBranchState -Name $DevBranchName
    Assert-DevelopmentBranchWorktreeContext -State $state -Operation "configure-dev-branch-unsafe-action-protection"

    if ($InfoBaseUser) {
        Set-DotEnvValues -Values @{ IB_USER = $InfoBaseUser }
        Import-DotEnv -Path (Join-Path $script:ProjectRoot ".dev.env") -Overwrite
    }
    Sync-DevBranchContextToDotEnv -State $state

    $result = Confirm-DevBranchUnsafeActionProtection `
        -InfoBaseKind $state.infoBaseKind `
        -InfoBasePath $state.devBranchInfoBasePath `
        -DevBranchName $state.devBranchName `
        -SetupModeOverride "manual-confirm"

    Update-DevBranchState -State $state -Updates @{
        unsafeActionProtectionSetupMode = $result.mode
        unsafeActionProtectionConfirmed = $result.confirmed
        unsafeActionProtectionConfirmedAt = $result.confirmedAt
        unsafeActionProtectionUser = $result.user
    }

    Write-Host "Development branch unsafe action protection setup confirmed."
    Write-Host "Branch: $($state.devBranch)"
    Write-Host "Infobase: $($state.devBranchInfoBasePath)"
    Write-Host "Infobase user: $($result.user)"
}

function Resolve-DevBranchUnsafeActionProtectionState {
    param(
        [hashtable]$State,
        [string]$InfoBaseKind,
        [string]$InfoBasePath,
        [string]$BranchName,
        [string]$MainProjectRoot
    )

    if ([string](Get-StateValue -State $State -Name "unsafeActionProtectionResolution" -Default "")) {
        return $State
    }

    $sourceConfirmation = Get-ValidSourceInfoBaseUnsafeActionProtectionConfirmation -ProjectRootOverride $MainProjectRoot
    if ($null -ne $sourceConfirmation) {
        $State["unsafeActionProtectionResolution"] = "source-confirmed"
        $State["unsafeActionProtectionSetupMode"] = [string](Get-StateValue -State $sourceConfirmation -Name "confirmationMode" -Default "confirmed")
        $State["unsafeActionProtectionConfirmed"] = $true
        $State["unsafeActionProtectionConfirmedAt"] = [string](Get-StateValue -State $sourceConfirmation -Name "confirmedAt" -Default "")
        $State["unsafeActionProtectionUser"] = [string](Get-StateValue -State $sourceConfirmation -Name "infoBaseUser" -Default "")
        $State["unsafeActionProtectionSourceKey"] = [string](Get-StateValue -State $sourceConfirmation -Name "sourceKey" -Default "")
        Write-Host "Development branch unsafe action protection inherited from the confirmed source infobase context."
        return $State
    }

    $result = Confirm-DevBranchUnsafeActionProtection `
        -InfoBaseKind $InfoBaseKind `
        -InfoBasePath $InfoBasePath `
        -DevBranchName $BranchName
    $State["unsafeActionProtectionResolution"] = $(if ($result.confirmed) { "branch-confirmed" } else { "skip" })
    $State["unsafeActionProtectionSetupMode"] = $result.mode
    $State["unsafeActionProtectionConfirmed"] = $result.confirmed
    $State["unsafeActionProtectionConfirmedAt"] = $result.confirmedAt
    $State["unsafeActionProtectionUser"] = $result.user
    $State["unsafeActionProtectionSourceKey"] = ""
    return $State
}

function Publish-DevBranchToWeb {
    param(
        [string]$DevBranchPath,
        [string]$SafeDevBranchName
    )

    $apacheSettings = Get-EffectiveApacheSettings
    $webInstPath = $apacheSettings.webInstPath
    $apacheKind = $apacheSettings.apacheKind
    $publicationRoot = $apacheSettings.publicationRoot
    $urlBase = $apacheSettings.publicationUrlBase
    $confPath = $apacheSettings.httpdConfPath

    Require-Value "WEBINST_PATH, web.webInstPath, or webinst.exe next to PLATFORM_PATH" $webInstPath | Out-Null
    Require-Value "WEB_PUBLICATION_ROOT or publication root from detected web server settings" $publicationRoot | Out-Null

    if (-not (Test-Path -LiteralPath $webInstPath)) {
        throw "webinst.exe was not found: $webInstPath"
    }
    if (-not ($apacheSettings.apacheFound -or $apacheSettings.manualPublicationRoot)) {
        throw "Web server publication settings were not detected. Prepare the web server outside ITL workflow, run configure-web-publication, or set APACHE_HTTPD_CONF_PATH/WEB_PUBLICATION_ROOT."
    }

    $publicationName = $SafeDevBranchName -replace "[^a-zA-Z0-9_]", "_"
    $publicationDir = Join-Path $publicationRoot $publicationName
    New-Item -ItemType Directory -Force -Path $publicationDir | Out-Null

    $kind = Get-InfoBaseKind
    if ($kind -eq "file") {
        $connStr = "File=`"$DevBranchPath`";"
    } else {
        $connStr = $DevBranchPath
    }

    $args = @("-publish", "-$apacheKind", "-wsdir", $publicationName, "-dir", $publicationDir, "-connstr", $connStr)
    if ($confPath -and (Test-Path -LiteralPath $confPath -PathType Leaf -ErrorAction SilentlyContinue)) {
        $args += @("-confpath", $confPath)
    }

    & $webInstPath @args
    if ($LASTEXITCODE -ne 0) {
        throw "webinst failed with exit code $LASTEXITCODE"
    }

    return [pscustomobject]@{
        url = ($urlBase.TrimEnd("/") + "/" + $publicationName)
        publicationName = $publicationName
        publicationDir = $publicationDir
    }
}

function Test-WebPublicationUrl {
    param([string]$Url)

    if ([string]::IsNullOrWhiteSpace($Url)) {
        return $false
    }

    $uri = $null
    if (-not [System.Uri]::TryCreate($Url.Trim(), [System.UriKind]::Absolute, [ref]$uri)) {
        return $false
    }

    return ($uri.Scheme -eq "http" -or $uri.Scheme -eq "https")
}

function Read-WebPublicationUrl {
    while ($true) {
        $url = (Read-Host "HTTP/HTTPS publication URL").Trim()
        if (Test-WebPublicationUrl -Url $url) {
            return $url.TrimEnd("/")
        }
        Write-Host "Enter a valid absolute http or https URL."
    }
}

function Get-PublicationNameFromUrl {
    param([string]$Url)

    if (-not (Test-WebPublicationUrl -Url $Url)) {
        return ""
    }

    $uri = [System.Uri]$Url
    $segments = @($uri.AbsolutePath.Trim("/") -split "/" | Where-Object { $_ })
    if ($segments.Count -eq 0) {
        return ""
    }
    return [System.Uri]::UnescapeDataString($segments[$segments.Count - 1])
}

function Get-PublicationDirCandidateFromUrl {
    param([string]$Url)

    $publicationName = Get-PublicationNameFromUrl -Url $Url
    if (-not $publicationName) {
        return ""
    }

    $settings = Get-EffectiveWebPublicationSettings
    if (-not $settings.publicationRoot) {
        return ""
    }

    return (Join-Path $settings.publicationRoot $publicationName)
}

function Read-ManualPublicationDir {
    param([string]$Url)

    $candidate = Get-PublicationDirCandidateFromUrl -Url $Url
    $default = ""
    if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Container -ErrorAction SilentlyContinue)) {
        $default = $candidate
    }

    return Read-WebPublicationValue -Prompt "Publication directory for Data MCP patching, empty if unknown" -Default $default
}

function Update-DevBranchPublicationState {
    param(
        [object]$State,
        [string]$Status,
        [string]$Mode,
        [string]$ErrorMessage = "",
        [string]$Url = "",
        [string]$Name = "",
        [string]$Dir = ""
    )

    $updates = @{
        publicationStatus = $Status
        publicationMode = $Mode
        publicationError = $ErrorMessage
        publicationUpdatedAt = (Get-Date).ToString("o")
        publicationUrl = $Url
        publicationName = $Name
        publicationDir = $Dir
    }
    Update-DevBranchState -State $State -Updates $updates
    $statePath = Get-StateValue -State $State -Name "statePath" -Default ""
    if ($statePath) {
        return Read-DevBranchStateFile -Path $statePath
    }
    return $State
}

function Invoke-DevBranchDataMcpAfterPublication {
    param([object]$State)

    $publicationUrl = Get-StateValue -State $State -Name "publicationUrl" -Default ""
    if (-not $publicationUrl) {
        return $State
    }

    $publicationDir = Get-StateValue -State $State -Name "publicationDir" -Default ""
    $dataMcpUpdates = Install-DevBranchDataMcpBestEffort -State $State -PublicationUrl $publicationUrl -PublicationDir $publicationDir
    if ($dataMcpUpdates.Count -gt 0) {
        Update-DevBranchState -State $State -Updates $dataMcpUpdates
        $statePath = Get-StateValue -State $State -Name "statePath" -Default ""
        if ($statePath) {
            return Read-DevBranchStateFile -Path $statePath
        }
    }

    return $State
}

function Write-ManualWebPublicationInstructions {
    param([object]$State)

    Write-Section "Manual web publication"
    Write-Host "Publish this development branch infobase outside ITL workflow, then return here with the HTTP URL."
    Write-Host "Development branch: $(Get-StateValue -State $State -Name 'devBranchName' -Default '<unknown>')"
    Write-Host "Infobase kind: $(Get-StateValue -State $State -Name 'infoBaseKind' -Default '<unknown>')"
    Write-Host "Infobase: $(Get-StateValue -State $State -Name 'devBranchInfoBasePath' -Default '<unknown>')"
    Write-Host "If the branch should not be published, choose skip."
}

function Read-ManualWebPublicationChoice {
    while ($true) {
        $choice = (Read-Host "Choose: published, skip, retry-auto [published]").Trim().ToLowerInvariant()
        if (-not $choice) {
            return "published"
        }
        switch ($choice) {
            "published" { return "published" }
            "p" { return "published" }
            "yes" { return "published" }
            "y" { return "published" }
            "skip" { return "skip" }
            "s" { return "skip" }
            "no" { return "skip" }
            "n" { return "skip" }
            "retry-auto" { return "retry-auto" }
            "retry" { return "retry-auto" }
            "r" { return "retry-auto" }
            default { Write-Host "Use published, skip, or retry-auto." }
        }
    }
}

function Invoke-DevBranchPublicationCycle {
    param(
        [object]$State,
        [bool]$PublicationEnabled,
        [bool]$AttemptAuto,
        [switch]$SkipDataMcp
    )

    if (-not $PublicationEnabled) {
        return Update-DevBranchPublicationState -State $State -Status "disabled" -Mode "none"
    }

    $state = $State
    if ($AttemptAuto) {
        try {
            $publication = Publish-DevBranchToWeb `
                -DevBranchPath (Get-StateValue -State $state -Name "devBranchInfoBasePath" -Default "") `
                -SafeDevBranchName (Get-StateValue -State $state -Name "safeDevBranchName" -Default "")
            $state = Update-DevBranchPublicationState `
                -State $state `
                -Status "published" `
                -Mode "auto" `
                -Url ([string]$publication.url) `
                -Name ([string]$publication.publicationName) `
                -Dir ([string]$publication.publicationDir)
            Write-Host "Publication URL: $($publication.url)"
            if ($SkipDataMcp) { return $state }
            return Invoke-DevBranchDataMcpAfterPublication -State $state
        } catch {
            $message = $_.Exception.Message
            Write-Warning "Automatic web publication failed. $message"
            $state = Update-DevBranchPublicationState -State $state -Status "failed" -Mode "auto" -ErrorMessage $message
        }
    } else {
        $state = Update-DevBranchPublicationState -State $state -Status "pending" -Mode "manual"
    }

    if (-not (Test-InteractiveInputAvailable)) {
        Write-Warning "Interactive input is unavailable. Run publish-dev-branch later to finish or skip web publication."
        if ((Get-StateValue -State $state -Name "publicationStatus" -Default "") -ne "failed") {
            $state = Update-DevBranchPublicationState -State $state -Status "pending" -Mode "manual"
        }
        return $state
    }

    while ($true) {
        Write-ManualWebPublicationInstructions -State $state
        $choice = Read-ManualWebPublicationChoice
        if ($choice -eq "skip") {
            return Update-DevBranchPublicationState -State $state -Status "skipped" -Mode "manual"
        }

        if ($choice -eq "retry-auto") {
            try {
                $publication = Publish-DevBranchToWeb `
                    -DevBranchPath (Get-StateValue -State $state -Name "devBranchInfoBasePath" -Default "") `
                    -SafeDevBranchName (Get-StateValue -State $state -Name "safeDevBranchName" -Default "")
                $state = Update-DevBranchPublicationState `
                    -State $state `
                    -Status "published" `
                    -Mode "auto" `
                    -Url ([string]$publication.url) `
                    -Name ([string]$publication.publicationName) `
                    -Dir ([string]$publication.publicationDir)
                Write-Host "Publication URL: $($publication.url)"
                if ($SkipDataMcp) { return $state }
                return Invoke-DevBranchDataMcpAfterPublication -State $state
            } catch {
                $message = $_.Exception.Message
                Write-Warning "Automatic web publication failed. $message"
                $state = Update-DevBranchPublicationState -State $state -Status "failed" -Mode "auto" -ErrorMessage $message
                continue
            }
        }

        $url = Read-WebPublicationUrl
        $publicationName = Get-PublicationNameFromUrl -Url $url
        $publicationDir = Read-ManualPublicationDir -Url $url
        $state = Update-DevBranchPublicationState `
            -State $state `
            -Status "published" `
            -Mode "manual" `
            -Url $url `
            -Name $publicationName `
            -Dir $publicationDir
        if ($SkipDataMcp) { return $state }
        return Invoke-DevBranchDataMcpAfterPublication -State $state
    }
}

function Publish-DevBranch {
    $state = Read-DevBranchState -Name $DevBranchName
    Assert-CurrentProjectRootMatchesDevBranchState -State $state -Operation "publish-dev-branch"
    $state = Ensure-DevBranchEnterpriseNormalized -State $state -Reason "legacy-preflight"
    $state = Invoke-DevBranchPublicationCycle -State $state -PublicationEnabled $true -AttemptAuto (Get-WebPublishAuto)
    Sync-DevBranchContextToDotEnv -State $state -AllowIncompleteExtension
    $publicationUrl = Get-StateValue -State $state -Name "publicationUrl" -Default ""
    if ($publicationUrl) {
        Write-Host "Publication URL: $publicationUrl"
    } else {
        Write-Host "Publication status: $(Get-StateValue -State $state -Name 'publicationStatus' -Default '<unknown>')"
    }
}

function Commit-BaselineDumpIfNeeded {
    param(
        [string]$Message,
        [string]$ExportPath
    )

    $pathSpec = @($ExportPath)
    Invoke-Git (@("add", "--all", "--force", "--") + $pathSpec)
    if (Test-GitHasStagedChanges -PathSpec $pathSpec) {
        Invoke-Git (@("commit", "--quiet", "-m", $Message, "--") + $pathSpec)
        Write-Host "Committed: $Message"
        return $true
    }

    $normalizedExportPath = (($ExportPath -replace "\\", "/").TrimEnd("/"))
    $dumpInfoRepoPath = "$normalizedExportPath/ConfigDumpInfo.xml"
    if (Test-GitHeadContainsPath -RepoPath $dumpInfoRepoPath) {
        Write-Host "No Git changes to commit for: $($pathSpec -join ', '). Baseline configuration dump is already committed to HEAD."
        return $false
    }

    $status = Get-GitStatusForPathSpec -PathSpec $pathSpec
    throw "No Git changes to commit for: $($pathSpec -join ', '). Expected files from the 1C configuration dump. Git status for this path: $status"
}

function Assert-InitGitClean {
    $status = & git -C $script:ProjectRoot status --porcelain
    if ($LASTEXITCODE -ne 0) {
        throw "Cannot read Git status after initialization."
    }

    $effectiveStatus = @(Get-EffectiveGitStatusLines -StatusLines $status)
    if ($effectiveStatus.Count -gt 0) {
        throw "Initialization left Git changes in master. Review why init-project did not commit all managed files before creating a development branch. Remaining Git status: $($effectiveStatus -join '; ')"
    }

    Write-Host "Git worktree is clean after initialization."
}

function Get-InitResumeStatus {
    if ([string]::IsNullOrWhiteSpace($ResumeRunStatusPath)) {
        throw "InitMode resume requires ResumeRunStatusPath from the monitored launcher."
    }

    $path = Resolve-RunFilePath -Path $ResumeRunStatusPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Resume run status was not found: $path"
    }

    try {
        $status = Read-Utf8Text -Path $path | ConvertFrom-Json
    } catch {
        throw "Resume run status cannot be read: $path. $($_.Exception.Message)"
    }
    if ([string]$status.action -ne "init-project") {
        throw "Resume run status is not an init-project run: $path"
    }

    $recordedRoot = Resolve-Agent1cFullPath -Path ([string]$status.projectRoot)
    if ($recordedRoot -ne $script:ProjectRoot) {
        throw "Resume run project root mismatch: status='$recordedRoot' current='$script:ProjectRoot'."
    }
    return $status
}

function Get-InitResumeStage {
    param([object]$Status)

    $resumeStageProperty = $Status.PSObject.Properties["resumeStage"]
    if ($null -ne $resumeStageProperty -and -not [string]::IsNullOrWhiteSpace([string]$resumeStageProperty.Value)) {
        return [string]$resumeStageProperty.Value
    }
    return [string]$Status.stage
}

function Test-InitStageAtLeast {
    param(
        [string]$Stage,
        [string]$Expected
    )

    $stages = @(
        "init.prepare",
        "init.check-tools",
        "init.unsafe-action-protection",
        "init.unsafe-action-protection-complete",
        "init.install-roctup-mcp",
        "init.cache-vanessa-ui-mcp",
        "init.git",
        "init.repository-update",
        "init.dump-config",
        "init.commit-dump",
        "init.install-ai-rules",
        "init.guidance",
        "init.vibecoding1c-mcp",
        "init.final-git-clean",
        "init.complete"
    )
    $actualIndex = [array]::IndexOf($stages, $Stage)
    $expectedIndex = [array]::IndexOf($stages, $Expected)
    return ($actualIndex -ge 0 -and $expectedIndex -ge 0 -and $actualIndex -ge $expectedIndex)
}

function Test-InitDumpArtifactsReady {
    param([string]$ExportPath = (Get-ExportPath))

    try {
        $absoluteExportPath = Assert-ExportPathInsideProject $ExportPath
        $dumpInfoPath = Join-Path $absoluteExportPath "ConfigDumpInfo.xml"
        if (-not (Test-Path -LiteralPath $dumpInfoPath -PathType Leaf)) {
            return $false
        }
        return (@(Get-ChildItem -LiteralPath $absoluteExportPath -Force).Count -gt 0)
    } catch {
        return $false
    }
}

function Test-InitAiRulesReady {
    try {
        $manifest = Get-AiRules1cProjectManifest
        if ($null -eq $manifest) {
            return $false
        }
        $installedTools = @(Get-AiRules1cManifestToolNames -Manifest $manifest)
        foreach ($tool in @(Get-AiRules1cTools)) {
            if ($installedTools -notcontains $tool) {
                return $false
            }
        }
        $configuredRef = [string](Get-ConfigValue -Path "aiRules.ref" -Default "")
        if ($configuredRef -and [string]$manifest.version -ne $configuredRef) {
            return $false
        }
        $lockEntry = Get-DependencyLockEntry -Name "aiRules1c"
        return (-not [string]::IsNullOrWhiteSpace([string](Get-ConfigValueFromObject -Object $lockEntry -Path "commit" -Default "")))
    } catch {
        return $false
    }
}

function Initialize-Project {
    Write-Section "Initialize project"
    New-Item -ItemType Directory -Force -Path $script:ProjectRoot | Out-Null
    Write-Host "Project root: $script:ProjectRoot"
    if ($InitMode -eq "wizard" -and [string]::IsNullOrWhiteSpace($RunStatusPath)) {
        Write-Host "WARNING: direct init-project wizard is not monitored. Agent-run initialization must use scripts/run-agent-1c-window.ps1 so the agent waits for completion and reads status.json. Use the direct wizard only for manual debugging."
    }
    $resumeStatus = $null
    $resumeStage = ""
    if ($InitMode -eq "resume") {
        $resumeStatus = Get-InitResumeStatus
        $resumeStage = Get-InitResumeStage -Status $resumeStatus
        Write-Host "Resuming interrupted initialization from stage: $resumeStage"
    }

    Set-RunStage -Stage "init.prepare" -Detail "Preparing initialization settings"
    if ($InitMode -eq "wizard" -or $InitMode -eq "json") {
        Prepare-InitProjectSettings
    } else {
        Prepare-ConfiguredInitProjectSettings
    }
    Apply-BootstrapWorkflowPackageProvenance | Out-Null
    $dumpWasCompleted = ($InitMode -eq "resume" -and (Test-InitStageAtLeast -Stage $resumeStage -Expected "init.commit-dump") -and (Test-InitDumpArtifactsReady))
    $unsafeActionProtectionWasCompleted = ($InitMode -eq "resume" -and (Test-InitStageAtLeast -Stage $resumeStage -Expected "init.unsafe-action-protection-complete"))
    if (-not $dumpWasCompleted) {
        Set-RunStage -Stage "init.check-tools" -Detail "Checking required tools"
        Check-Tools -StopOnMissing
        if (-not $unsafeActionProtectionWasCompleted) {
            Set-RunStage -Stage "init.unsafe-action-protection" -Detail "Confirming source infobase unsafe action protection"
            Initialize-SourceInfoBaseUnsafeActionProtection
            Set-RunStage -Stage "init.unsafe-action-protection-complete" -Detail "Source infobase unsafe action protection resolved"
        } else {
            Write-Host "Resume confirmed that source infobase unsafe action protection setup completed in the interrupted run."
        }
        Set-RunStage -Stage "init.install-roctup-mcp" -Detail "Installing or updating ROCTUP MCP Toolkit"
        Remove-ItlOnDemandStaleInstances | Out-Null
        Install-RoctupMcp
        Set-RunStage -Stage "init.cache-vanessa-ui-mcp" -Detail "Caching Vanessa UI MCP artifacts"
        Install-VanessaMcpArtifacts | Out-Null
        Set-RunStage -Stage "init.install-ondemand-mcp" -Detail "Installing the ITL on-demand MCP facade"
        Install-ItlOnDemandMcp | Out-Null
        Get-DevBranchInfoBaseRoot | Out-Null
    } else {
        Write-Host "Resume validated the completed configuration dump; tool installation and 1C dump will not be repeated."
    }
    Set-RunStage -Stage "init.git" -Detail "Preparing Git repository and master branch"
    Ensure-GitRepository
    Ensure-GitIgnore
    Checkout-Master

    $sourceUsesRepository = Get-SourceUsesRepository
    if (-not $dumpWasCompleted) {
        Set-RunStage -Stage "init.repository-update" -Detail "Updating source infobase from 1C repository"
        Update-BaseFromRepository
        Set-RunStage -Stage "init.dump-config" -Detail "Dumping 1C configuration files"
        $dumpResult = Dump-ConfigToFiles
    } else {
        $dumpResult = [pscustomobject]@{
            exportPath = Get-ExportPath
            absoluteExportPath = Assert-ExportPathInsideProject (Get-ExportPath)
            incremental = $true
            logPath = ""
        }
    }
    $dumpMessage = if ($sourceUsesRepository) { "sync: export 1C configuration from repository" } else { "sync: export 1C configuration from source infobase" }
    Set-RunStage -Stage "init.commit-dump" -Detail "Committing baseline 1C configuration dump"
    Commit-BaselineDumpIfNeeded -Message $dumpMessage -ExportPath $dumpResult.exportPath | Out-Null
    Assert-BaselineDumpCommitted -ExportPath $dumpResult.exportPath

    Set-RunStage -Stage "init.install-ai-rules" -Detail "Installing or updating ai_rules_1c"
    if ($InitMode -eq "resume" -and (Test-InitAiRulesReady)) {
        Write-Host "Resume validated the installed ai_rules_1c tools and dependency lock; installation will not be repeated."
    } else {
        Install-AiRules1c
    }
    Set-RunStage -Stage "init.guidance" -Detail "Updating agent guidance, USER-RULES, and Kilo commands"
    Sync-ItlVanessaLibraries
    Update-AgentGuidanceBridge
    Update-UserRules
    Sync-KiloItlCommandSurface
    Commit-IfChanged "chore: install 1C agent workflow"
    $vibecodingRequested = $script:InitVibecoding1cMcpSetupRequested -or (ConvertTo-YesNoBool -Value (Get-EnvValue -Name "VIBECODING1C_MCP_SETUP_DURING_INIT" -Default $true) -Default $true)
    $vibecodingAlreadyCompleted = $InitMode -eq "resume" -and (Test-InitStageAtLeast -Stage $resumeStage -Expected "init.final-git-clean")
    if ($vibecodingRequested -and -not $vibecodingAlreadyCompleted) {
        Set-RunStage -Stage "init.vibecoding1c-mcp" -Detail "Setting up vibecoding1c MCP"
        Setup-Vibecoding1cMcp
    } elseif ($vibecodingAlreadyCompleted) {
        Write-Host "Resume confirmed that vibecoding1c MCP setup completed in the interrupted run."
    } else {
        Write-Host "vibecoding1c MCP setup was deferred. Ask the agent to configure vibecoding1c MCP, or run -Action vibecoding1c-mcp-setup when needed."
    }
    Set-RunStage -Stage "init.final-git-clean" -Detail "Checking final Git worktree state"
    Assert-InitGitClean
    Write-PostInitClientReloadHandoff
    Write-KiloBrowserAutomationSummary -ProjectRoot $script:ProjectRoot
    Write-InitRunUserReport -VibecodingDeferred (-not $vibecodingRequested -and -not $vibecodingAlreadyCompleted)
    Set-RunStage -Stage "init.complete" -Detail "Initialization completed"
}

function Sync-Master {
    param([switch]$NoDelegate)

    Set-RunStage -Stage "master-sync" -Detail "Synchronizing the master worktree."
    Write-Section "Sync master"
    if (-not $NoDelegate) {
        $currentBranch = ""
        try {
            $currentBranch = Get-CurrentBranch
        } catch {
            $currentBranch = ""
        }
        if ($currentBranch -like "itldev/*") {
            $state = Read-DevBranchState -Name ""
            $mainWorktreePath = Get-StateValue -State $state -Name "mainWorktreePath" -Default ""
            if ($mainWorktreePath -and ((Get-FullPathNormalized $mainWorktreePath) -ne (Get-FullPathNormalized $script:ProjectRoot))) {
                Restart-Agent1cFromMainWorktreeIfNeeded -MainWorktreePath $mainWorktreePath
                Write-Host "Syncing master in main worktree: $mainWorktreePath"
                Invoke-InProjectContext -Root $mainWorktreePath -ScriptBlock {
                    Sync-Master -NoDelegate
                }
                return
            }
        }
    }

    Assert-CleanGit
    Checkout-Master
    Clear-DevBranchContext
    $sourceUsesRepository = Get-SourceUsesRepository
    Update-BaseFromRepository
    $dumpResult = Dump-ConfigToFiles
    $dumpMessage = if ($sourceUsesRepository) { "sync: refresh 1C configuration from repository" } else { "sync: refresh 1C configuration from source infobase" }
    Commit-IfChanged -Message $dumpMessage -PathSpec @($dumpResult.exportPath) -ForceAdd | Out-Null
    Sync-KiloItlCommandSurface
}

function Initialize-DevBranchRuntime {
    param(
        [ValidateSet("configuration", "extension")]
        [string]$DevBranchKind = "configuration",
        [string]$SafeDevBranchName,
        [string]$GitBranch,
        [string]$MainProjectRoot,
        [string]$WorktreePath,
        [bool]$CreatedWithWorktree = $false,
        [string]$StateProjectRoot = $script:ProjectRoot,
        [string]$WorkspaceProvider = "",
        [string]$ClientWorkspaceId = "",
        [string]$RuntimeRoot = "",
        [bool]$WorktreeLocked = $false
    )

    $kind = Get-InfoBaseKind
    $sourceUsesRepository = Get-SourceUsesRepository
    $source = Get-SourceInfoBasePath
    if (-not $DevBranchInfoBasePath) {
        $rootPath = Resolve-ProjectPath (Get-DevBranchInfoBaseRoot)
        $DevBranchInfoBasePath = Join-Path $rootPath $SafeDevBranchName
    }

    $publishDefault = Get-WebPublishByDefault
    $publicationEnabled = ($PublishToWeb -or $publishDefault)
    $publicationAuto = ($PublishToWeb -or ($publishDefault -and (Get-WebPublishAuto)))
    $publicationStatus = if ($publicationEnabled) { "pending" } else { "disabled" }
    $publicationMode = if ($publicationAuto) { "auto" } elseif ($publicationEnabled) { "manual" } else { "none" }

    $stateProjectRoot = Resolve-Agent1cFullPath -Path $StateProjectRoot
    $statePath = Join-Path $stateProjectRoot ".agent-1c\dev-branches\$SafeDevBranchName.json"
    $existingState = $null
    if (Test-Path -LiteralPath $statePath -PathType Leaf -ErrorAction SilentlyContinue) {
        $existingState = Read-DevBranchStateFile -Path $statePath
        if (-not (Test-DevBranchInitializationResumable -State $existingState)) {
            throw "Development branch initialization is not resumable for '$DevBranchName'. Status: $(Get-DevBranchInitializationStatus -State $existingState)."
        }
    }

    $stateHash = @{}
    if ($null -ne $existingState) {
        $existingHash = ConvertTo-Agent1cHashtable $existingState
        foreach ($key in $existingHash.Keys) {
            if (@("statePath", "stateProjectRoot") -contains $key) {
                continue
            }
            $stateHash[$key] = $existingHash[$key]
        }
    }

    $currentCommit = Get-CurrentCommit
    $now = (Get-Date).ToString("o")
    $stateHash["devBranchName"] = $DevBranchName
    $stateHash["safeDevBranchName"] = $SafeDevBranchName
    $stateHash["devBranchKind"] = $DevBranchKind
    $stateHash["devBranch"] = $GitBranch
    $stateHash["createdWithWorktree"] = $CreatedWithWorktree
    $stateHash["worktreePath"] = $WorktreePath
    $stateHash["mainWorktreePath"] = $MainProjectRoot
    if ($WorkspaceProvider) {
        $stateHash["workspaceProvider"] = $WorkspaceProvider
        $stateHash["clientWorkspaceId"] = $ClientWorkspaceId
        $stateHash["runtimeRoot"] = $RuntimeRoot
        $stateHash["worktreeLocked"] = $WorktreeLocked
    }
    if (-not $stateHash.ContainsKey("createdFromCommit") -or -not $stateHash["createdFromCommit"]) {
        $stateHash["createdFromCommit"] = $currentCommit
    }
    if (-not $stateHash.ContainsKey("lastConfigBaseUpdatedCommit") -or -not $stateHash["lastConfigBaseUpdatedCommit"]) {
        $stateHash["lastConfigBaseUpdatedCommit"] = $currentCommit
    }
    $stateHash["infoBaseKind"] = $kind
    $stateHash["devBranchInfoBasePath"] = $DevBranchInfoBasePath
    $stateHash["sourceUsesRepository"] = $sourceUsesRepository
    if (-not $stateHash.ContainsKey("repositoryUnbound")) {
        $stateHash["repositoryUnbound"] = $false
    }
    if (-not $stateHash.ContainsKey("launcherRegistered")) {
        $stateHash["launcherRegistered"] = $false
    }
    foreach ($default in @(
        @{ name = "launcherInfoBaseName"; value = "" },
        @{ name = "launcherFolder"; value = "" },
        @{ name = "launcherInfoBaseId"; value = "" },
        @{ name = "launcherListPath"; value = "" },
        @{ name = "publicationUrl"; value = "" },
        @{ name = "publicationName"; value = "" },
        @{ name = "publicationDir"; value = "" },
        @{ name = "publicationStatus"; value = $publicationStatus },
        @{ name = "publicationMode"; value = $publicationMode },
        @{ name = "publicationError"; value = "" },
        @{ name = "publicationUpdatedAt"; value = $now },
        @{ name = "roctupMcpPort"; value = 0 },
        @{ name = "roctupMcpUrl"; value = "" },
        @{ name = "roctupMcpHealthUrl"; value = "" },
        @{ name = "roctupMcpPid"; value = "" },
        @{ name = "roctupMcpStatus"; value = "pending" },
        @{ name = "roctupMcpError"; value = "" },
        @{ name = "roctupMcpLogPath"; value = "" },
        @{ name = "roctupMcpEpfPath"; value = "" },
        @{ name = "vanessaMcpPort"; value = 0 },
        @{ name = "vanessaMcpUrl"; value = "" },
        @{ name = "vanessaMcpPid"; value = "" },
        @{ name = "vanessaMcpStatus"; value = "pending" },
        @{ name = "vanessaMcpError"; value = "" },
        @{ name = "vanessaMcpLogPath"; value = "" },
        @{ name = "unsafeActionProtectionSetupMode"; value = "" },
        @{ name = "unsafeActionProtectionResolution"; value = "" },
        @{ name = "unsafeActionProtectionConfirmed"; value = $false },
        @{ name = "unsafeActionProtectionConfirmedAt"; value = "" },
        @{ name = "unsafeActionProtectionUser"; value = "" },
        @{ name = "unsafeActionProtectionSourceKey"; value = "" },
        @{ name = "createdAt"; value = $now },
        @{ name = "lastLogPath"; value = "" },
        @{ name = "enterpriseNormalizationStatus"; value = "pending" },
        @{ name = "enterpriseNormalizationReason"; value = "branch-copy" },
        @{ name = "enterpriseNormalizationError"; value = "" },
        @{ name = "enterpriseNormalizedAt"; value = "" },
        @{ name = "configLoadStatus"; value = "" },
        @{ name = "lastConfigLoadMode"; value = "" },
        @{ name = "lastConfigPartialLogPath"; value = "" },
        @{ name = "lastConfigFullFallbackLogPath"; value = "" },
        @{ name = "lastConfigPartialError"; value = "" },
        @{ name = "lastConfigFullFallbackError"; value = "" },
        @{ name = "lastDesignerMemoryLimitExceeded"; value = $false },
        @{ name = "lastDesignerPeakWorkingSetMb"; value = 0 },
        @{ name = "lastDesignerWorkingSetLimitMb"; value = 0 },
        @{ name = "lastDesignerMemoryGuardError"; value = "" },
        @{ name = "lastDesignerMemoryGuardFailedAt"; value = "" },
        @{ name = "lastConfigDesignerFingerprint"; value = "" },
        @{ name = "lastConfigDesignerLoadedAt"; value = "" },
        @{ name = "lastExtensionDesignerFingerprint"; value = "" },
        @{ name = "lastExtensionDesignerLoadedAt"; value = "" },
        @{ name = "extensionInitializationStatus"; value = $(if ($DevBranchKind -eq "extension") { "pending" } else { "not-required" }) },
        @{ name = "extensionInitializationError"; value = "" },
        @{ name = "extensionInitializationUpdatedAt"; value = $now },
        @{ name = "sourceFingerprint"; value = "" },
        @{ name = "loadReason"; value = "" },
        @{ name = "designerInvoked"; value = $false },
        @{ name = "enterpriseInvoked"; value = $false }
    )) {
        if (-not $stateHash.ContainsKey($default.name)) {
            $stateHash[$default.name] = $default.value
        }
    }

    $currentStatus = if ($existingState) { Get-DevBranchInitializationStatus -State $existingState } else { "initializing" }
    if ($currentStatus -eq "failed") {
        $currentStatus = "initializing"
    }
    if ($currentStatus -eq "initializing") {
        $statePath = Save-DevBranchInitializationState -SafeDevBranchName $SafeDevBranchName -State $stateHash -Status "initializing" -ProjectRootOverride $stateProjectRoot
    }

    $copyPerformed = $false
    try {
        if ($currentStatus -eq "enterprise-normalization-pending") {
            Write-Host "Resuming final Enterprise normalization for existing development branch copy: $DevBranchInfoBasePath"
            $state = Read-DevBranchStateFile -Path $statePath
            $normalizedHash = ConvertTo-Agent1cHashtable $state
            [void]$normalizedHash.Remove("statePath")
            [void]$normalizedHash.Remove("stateProjectRoot")
            $normalizedHash = Resolve-DevBranchUnsafeActionProtectionState `
                -State $normalizedHash `
                -InfoBaseKind $kind `
                -InfoBasePath $DevBranchInfoBasePath `
                -BranchName $DevBranchName `
                -MainProjectRoot $MainProjectRoot
            $statePath = Save-DevBranchInitializationState -SafeDevBranchName $SafeDevBranchName -State $normalizedHash -Status "enterprise-normalization-pending" -ProjectRootOverride $stateProjectRoot
            $state = Read-DevBranchStateFile -Path $statePath
            Ensure-DevBranchEnterpriseNormalized -State $state -Reason "branch-copy" | Out-Null
            $state = Read-DevBranchStateFile -Path $statePath
            if (Get-StateValue -State $state -Name "publicationUrl" -Default "") {
                $state = Invoke-DevBranchDataMcpAfterPublication -State $state
            }
            Sync-DevBranchContextToDotEnv -State $state -AllowIncompleteExtension
            Sync-KiloItlCommandSurface
            $normalizedHash = ConvertTo-Agent1cHashtable $state
            [void]$normalizedHash.Remove("statePath")
            [void]$normalizedHash.Remove("stateProjectRoot")
            $statePath = Save-DevBranchInitializationState -SafeDevBranchName $SafeDevBranchName -State $normalizedHash -Status "ready" -ProjectRootOverride $stateProjectRoot
            return
        }

        if ($kind -eq "file") {
            if (Test-Path -LiteralPath $DevBranchInfoBasePath) {
                if ($null -eq $existingState) {
                    throw "Development branch infobase path already exists: $DevBranchInfoBasePath"
                }
                $mainDbFile = Join-Path $DevBranchInfoBasePath "1Cv8.1CD"
                if (-not (Test-Path -LiteralPath $mainDbFile -PathType Leaf -ErrorAction SilentlyContinue)) {
                    throw "Development branch infobase path already exists but does not look like a complete file infobase: $DevBranchInfoBasePath"
                }
                Write-Host "Using existing development branch infobase copy: $DevBranchInfoBasePath"
            } else {
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $DevBranchInfoBasePath) | Out-Null
                Copy-Item -LiteralPath $source -Destination $DevBranchInfoBasePath -Recurse
                $copyPerformed = $true
            }
        } else {
            if (@("infobase-copied", "repository-unbound", "launcher-registered") -contains $currentStatus) {
                Write-Host "Using existing development branch infobase copy: $DevBranchInfoBasePath"
            } else {
                $copyScript = Get-ConfigValue -Path "serverBaseCopyScript" -Default ""
                if (-not $copyScript) {
                    throw "serverBaseCopyScript is required for server infobase copies."
                }
                $copyScriptPath = Resolve-ProjectPath $copyScript
                & powershell -ExecutionPolicy Bypass -File $copyScriptPath `
                    -ProjectRoot $script:ProjectRoot `
                    -DevBranchName $DevBranchName `
                    -SourceInfoBasePath $source `
                    -DevBranchInfoBasePath $DevBranchInfoBasePath
                if ($LASTEXITCODE -ne 0) {
                    throw "Server infobase copy script failed with exit code $LASTEXITCODE"
                }
                $copyPerformed = $true
            }
        }
        if ($copyPerformed) {
            $configExportPath = Get-ExportPath
            $absoluteConfigExportPath = Resolve-ProjectPath $configExportPath
            if (Test-Path -LiteralPath $absoluteConfigExportPath -PathType Container) {
                $configSource = Get-ConfigSourceFingerprint -ExportPath $configExportPath
                $stateHash["lastConfigDesignerFingerprint"] = $configSource.fingerprint
                $stateHash["lastConfigDesignerLoadedAt"] = $now
                $stateHash["sourceFingerprint"] = $configSource.fingerprint
                $stateHash["loadReason"] = "branch-copy-seed"
            } else {
                $stateHash["loadReason"] = "branch-copy-seed-deferred"
            }
            $stateHash["designerInvoked"] = $false
            $stateHash["enterpriseInvoked"] = $false
        }
        $statePath = Save-DevBranchInitializationState -SafeDevBranchName $SafeDevBranchName -State $stateHash -Status "infobase-copied" -ProjectRootOverride $stateProjectRoot
        $currentStatus = "infobase-copied"

        $repositoryUnbound = ConvertTo-BoolSetting -Value $stateHash["repositoryUnbound"] -Default $false
        if ($sourceUsesRepository -and -not $repositoryUnbound) {
            Invoke-Designer `
                -InfoBasePath $DevBranchInfoBasePath `
                -InfoBaseKind $kind `
                -DesignerArgs @("/ConfigurationRepositoryUnbindCfg", "-force") | Out-Null
            $repositoryUnbound = $true
        } elseif (-not $sourceUsesRepository) {
            Write-Host "Source infobase is configured without repository connection. Skipping repository unbind for development branch copy."
        }
        $stateHash["repositoryUnbound"] = $repositoryUnbound
        $stateHash["lastLogPath"] = $script:LastLogPath
        $statePath = Save-DevBranchInitializationState -SafeDevBranchName $SafeDevBranchName -State $stateHash -Status "repository-unbound" -ProjectRootOverride $stateProjectRoot
        $currentStatus = "repository-unbound"

        $stateHash = Resolve-DevBranchUnsafeActionProtectionState `
            -State $stateHash `
            -InfoBaseKind $kind `
            -InfoBasePath $DevBranchInfoBasePath `
            -BranchName $DevBranchName `
            -MainProjectRoot $MainProjectRoot
        $statePath = Save-DevBranchInitializationState -SafeDevBranchName $SafeDevBranchName -State $stateHash -Status "unsafe-action-protection-resolved" -ProjectRootOverride $stateProjectRoot
        $currentStatus = "unsafe-action-protection-resolved"

        $launcherRegistration = Register-DevBranchInLauncher `
            -InfoBaseKind $kind `
            -InfoBasePath $DevBranchInfoBasePath `
            -SafeDevBranchName $SafeDevBranchName `
            -ProjectRootForFolder $MainProjectRoot `
            -ExistingLauncherId ([string]$stateHash["launcherInfoBaseId"])
        $stateHash["launcherRegistered"] = $launcherRegistration.registered
        $stateHash["launcherInfoBaseName"] = $launcherRegistration.name
        $stateHash["launcherFolder"] = $launcherRegistration.folder
        $stateHash["launcherInfoBaseId"] = $launcherRegistration.id
        $stateHash["launcherListPath"] = $launcherRegistration.listPath
        $statePath = Save-DevBranchInitializationState -SafeDevBranchName $SafeDevBranchName -State $stateHash -Status "launcher-registered" -ProjectRootOverride $stateProjectRoot
        $currentStatus = "launcher-registered"

        Write-Host "Development branch: $GitBranch"
        if ($CreatedWithWorktree) {
            Write-Host "Development branch worktree: $WorktreePath"
            Write-Host "Main project worktree: $MainProjectRoot"
        }
        Write-Host "Development branch infobase: $DevBranchInfoBasePath"
        Write-Host "Development branch state: $statePath"
        Write-Host "1C launcher infobase: $($launcherRegistration.name)"
        Write-Host "1C launcher folder: $($launcherRegistration.folder)"

        $state = Read-DevBranchStateFile -Path $statePath
        Sync-DevBranchContextToDotEnv -State $state -AllowIncompleteExtension
        $state = Invoke-DevBranchDefaultMcpSetup -State $state
        Invoke-DevBranchVibecoding1cMcpInheritance -MainProjectRoot $MainProjectRoot
        $state = Invoke-DevBranchPublicationCycle -State $state -PublicationEnabled $publicationEnabled -AttemptAuto $publicationAuto -SkipDataMcp
        $publicationUrl = Get-StateValue -State $state -Name "publicationUrl" -Default ""
        if ($publicationUrl) {
            Write-Host "Publication URL: $publicationUrl"
        } else {
            $savedPublicationStatus = Get-StateValue -State $state -Name "publicationStatus" -Default ""
            if ($savedPublicationStatus) {
                Write-Host "Publication status: $savedPublicationStatus"
            }
        }
        $state = Initialize-DevBranchEventLogBaseline -State $state
        $pendingHash = ConvertTo-Agent1cHashtable $state
        [void]$pendingHash.Remove("statePath")
        [void]$pendingHash.Remove("stateProjectRoot")
        $pendingHash["enterpriseNormalizationStatus"] = "pending"
        $pendingHash["enterpriseNormalizationReason"] = "branch-copy"
        $pendingHash["enterpriseNormalizationError"] = ""
        $statePath = Save-DevBranchInitializationState -SafeDevBranchName $SafeDevBranchName -State $pendingHash -Status "enterprise-normalization-pending" -ProjectRootOverride $stateProjectRoot
        $currentStatus = "enterprise-normalization-pending"
        $state = Read-DevBranchStateFile -Path $statePath
        Ensure-DevBranchEnterpriseNormalized -State $state -Reason "branch-copy" | Out-Null
        $state = Read-DevBranchStateFile -Path $statePath
        if (Get-StateValue -State $state -Name "publicationUrl" -Default "") {
            $state = Invoke-DevBranchDataMcpAfterPublication -State $state
        }
        Sync-DevBranchContextToDotEnv -State $state -AllowIncompleteExtension
        Sync-KiloItlCommandSurface
        $finalHash = @{}
        $finalStateHash = ConvertTo-Agent1cHashtable $state
        foreach ($key in $finalStateHash.Keys) {
            if (@("statePath", "stateProjectRoot") -contains $key) {
                continue
            }
            $finalHash[$key] = $finalStateHash[$key]
        }
        $statePath = Save-DevBranchInitializationState -SafeDevBranchName $SafeDevBranchName -State $finalHash -Status "ready" -ProjectRootOverride $stateProjectRoot
    } catch {
        $message = $_.Exception.Message
        $statusForError = if ($currentStatus -and @("infobase-copied", "repository-unbound", "unsafe-action-protection-resolved", "launcher-registered", "enterprise-normalization-pending") -contains $currentStatus) { $currentStatus } else { "failed" }
        $failureHash = $stateHash
        if (Test-Path -LiteralPath $statePath -PathType Leaf -ErrorAction SilentlyContinue) {
            try {
                $latestState = Read-DevBranchStateFile -Path $statePath
                $latestHash = ConvertTo-Agent1cHashtable $latestState
                $failureHash = @{}
                foreach ($key in $latestHash.Keys) {
                    if (@("statePath", "stateProjectRoot") -contains $key) {
                        continue
                    }
                    $failureHash[$key] = $latestHash[$key]
                }
            } catch {
                $failureHash = $stateHash
            }
        }
        Save-DevBranchInitializationState -SafeDevBranchName $SafeDevBranchName -State $failureHash -Status $statusForError -ErrorMessage $message -ProjectRootOverride $stateProjectRoot | Out-Null
        throw
    }
}

function Get-DevWorkspacePlan {
    Require-Value "DevBranchName" $DevBranchName | Out-Null
    Assert-MasterWorktreeContext -Operation "get-dev-workspace-plan"
    Assert-CleanGit

    $safe = ConvertTo-SafeName $DevBranchName
    $branch = if ($DevBranch) { $DevBranch } else { "itldev/$safe" }
    if ($branch -ne "itldev/$safe") {
        throw "OpenCode native workspaces require the exact development branch 'itldev/$safe'."
    }
    $mainRoot = Get-MainWorktreePath
    $statePath = Join-Path $mainRoot ".agent-1c\dev-branches\$safe.json"
    $branchExists = Test-GitBranchExists -Branch $branch
    $mode = "create"
    $worktreePath = ""
    $expectedWorkspaceCommit = Get-CurrentCommit
    if ($branchExists) {
        if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
            throw "Development branch already exists without OpenCode ITL state and will not be adopted: $branch"
        }
        $state = Read-DevBranchStateFile -Path $statePath
        if ((Get-StateValue -State $state -Name "workspaceProvider" -Default "external") -ne "opencode") {
            throw "Existing legacy development branch will not be migrated to an OpenCode workspace: $branch"
        }
        if ((Get-StateValue -State $state -Name "devBranch" -Default "") -ne $branch) {
            throw "Existing OpenCode state belongs to another branch: $(Get-StateValue -State $state -Name 'devBranch' -Default '<unknown>')."
        }
        if ((Get-DevBranchKind -State $state) -ne $DevBranchKind) {
            throw "Existing OpenCode state has another development branch kind: $(Get-DevBranchKind -State $state)."
        }
        $worktree = Find-GitWorktreeByBranch -Branch $branch
        if ($null -eq $worktree -or -not $worktree.path) {
            throw "OpenCode development branch state exists but its Git worktree is missing: $branch"
        }
        $mode = "resume"
        $worktreePath = Resolve-Agent1cFullPath -Path $worktree.path
        $expectedWorkspaceCommit = [string]$worktree.head
    } elseif (Test-Path -LiteralPath $statePath -PathType Leaf) {
        throw "Development branch state exists but the Git branch is missing: $statePath"
    }

    $plan = [ordered]@{
        mode = $mode
        kind = $DevBranchKind
        safeName = $safe
        branch = $branch
        baseCommit = $expectedWorkspaceCommit
        mainWorktreePath = $mainRoot
        worktreePath = $worktreePath
        runtimeRoot = Join-Path $mainRoot ".agent-1c\workspaces\$safe"
    }
    Write-Output ($plan | ConvertTo-Json -Compress)
}

function Lock-OpenCodeDevWorktree {
    param([string]$MainRoot, [string]$WorktreePath, [string]$Branch)

    $worktree = Find-GitWorktreeByBranch -Branch $Branch
    if ($null -eq $worktree) { throw "OpenCode worktree is not registered in Git: $Branch" }
    if ($worktree.PSObject.Properties.Name -contains "locked" -and $worktree.locked) { return }
    & git -C $MainRoot worktree lock --reason "ITL managed OpenCode workspace" $WorktreePath
    if ($LASTEXITCODE -ne 0) { throw "Unable to lock OpenCode worktree: $WorktreePath" }
}

function Adopt-DevWorktree {
    Require-Value "DevBranchName" $DevBranchName | Out-Null
    if ($WorkspaceProvider -ne "opencode") { throw "adopt-dev-worktree accepts only WorkspaceProvider=opencode." }
    Require-Value "ClientWorkspaceId" $ClientWorkspaceId | Out-Null
    Require-Value "MainWorktreePath" $MainWorktreePath | Out-Null
    Require-Value "WorkspaceBaseCommit" $WorkspaceBaseCommit | Out-Null
    Require-Value "RuntimeRoot" $RuntimeRoot | Out-Null

    $safe = ConvertTo-SafeName $DevBranchName
    $branch = if ($DevBranch) { $DevBranch } else { "itldev/$safe" }
    $currentRoot = Resolve-Agent1cFullPath -Path $script:ProjectRoot
    $mainRoot = Resolve-Agent1cFullPath -Path $MainWorktreePath
    if ($currentRoot -eq $mainRoot) { throw "The main worktree cannot be adopted as an OpenCode development workspace." }
    if ((Resolve-Agent1cFullPath -Path (Get-MainWorktreePath)) -ne $mainRoot) { throw "The supplied main worktree does not belong to the current Git repository." }
    if ((Get-CurrentBranch) -ne $branch) { throw "OpenCode workspace branch mismatch. Expected: $branch. Actual: $(Get-CurrentBranch)." }
    if ((Get-CurrentCommit) -ne $WorkspaceBaseCommit) { throw "OpenCode workspace base commit mismatch. Expected: $WorkspaceBaseCommit. Actual: $(Get-CurrentCommit)." }
    $gitWorktree = Find-GitWorktreeByBranch -Branch $branch
    if ($null -eq $gitWorktree -or (Resolve-Agent1cFullPath -Path $gitWorktree.path) -ne $currentRoot) {
        throw "The current directory is not the registered additional worktree for $branch."
    }

    $statePath = Join-Path $mainRoot ".agent-1c\dev-branches\$safe.json"
    $otherStatePath = Find-DevBranchStateFile -SafeDevBranchName $safe
    if ($otherStatePath -and (Resolve-Agent1cFullPath -Path $otherStatePath) -ne (Resolve-Agent1cFullPath -Path $statePath)) {
        throw "Existing legacy development branch state will not be migrated: $otherStatePath"
    }
    Assert-DevBranchUnsafeActionProtectionPromptAvailable
    Lock-OpenCodeDevWorktree -MainRoot $mainRoot -WorktreePath $currentRoot -Branch $branch

    $resolvedRuntimeRoot = Resolve-Agent1cFullPath -Path $RuntimeRoot
    $expectedRuntimeRoot = Resolve-Agent1cFullPath -Path (Join-Path $mainRoot ".agent-1c\workspaces\$safe")
    if ($resolvedRuntimeRoot -ne $expectedRuntimeRoot) {
        throw "OpenCode workspace runtime root mismatch. Expected: $expectedRuntimeRoot. Actual: $resolvedRuntimeRoot."
    }
    $script:DevBranchInfoBasePath = Join-Path $resolvedRuntimeRoot "infobase"
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        $existing = Read-DevBranchStateFile -Path $statePath
        if ((Get-StateValue -State $existing -Name "workspaceProvider" -Default "external") -ne "opencode") {
            throw "Existing legacy development branch state will not be migrated: $statePath"
        }
        if ((Get-DevBranchInitializationStatus -State $existing) -eq "ready") {
            Update-DevBranchState -State $existing -Updates @{ clientWorkspaceId = $ClientWorkspaceId; worktreeLocked = $true }
            $existing = Read-DevBranchStateFile -Path $statePath
            Sync-DevBranchContextToDotEnv -State $existing -AllowIncompleteExtension
            Sync-KiloItlCommandSurface
            Write-Host "OpenCode development workspace already ready: $branch"
            return
        }
    }

    Initialize-DevBranchRuntime `
        -DevBranchKind $DevBranchKind `
        -SafeDevBranchName $safe `
        -GitBranch $branch `
        -MainProjectRoot $mainRoot `
        -WorktreePath $currentRoot `
        -CreatedWithWorktree $true `
        -StateProjectRoot $mainRoot `
        -WorkspaceProvider "opencode" `
        -ClientWorkspaceId $ClientWorkspaceId `
        -RuntimeRoot $resolvedRuntimeRoot `
        -WorktreeLocked $true

    if ($DevBranchKind -eq "extension") {
        $hasProvisioningInput = Resolve-NewExtensionProvisioningInput
        if ($hasProvisioningInput) {
            Init-DevBranchExtension
        } else {
            Write-Host "Extension initialization: pending"
        }
    }
}

function Get-DevWorkspaceClosePlan {
    $state = Read-DevBranchState -Name $DevBranchName
    if ((Get-StateValue -State $state -Name "workspaceProvider" -Default "external") -ne "opencode") {
        throw "Existing legacy development branch is not an OpenCode managed workspace and will use the unchanged close lifecycle."
    }
    Assert-DevelopmentBranchWorktreeContext -State $state -Operation "get-dev-workspace-close-plan"

    $plan = [ordered]@{
        branch = [string]$state.devBranch
        safeName = [string](Get-StateValue -State $state -Name "safeDevBranchName" -Default (ConvertTo-SafeName $state.devBranchName))
        clientWorkspaceId = [string](Get-StateValue -State $state -Name "clientWorkspaceId" -Default "")
        mainWorktreePath = [string](Get-StateValue -State $state -Name "mainWorktreePath" -Default "")
        worktreePath = [string](Get-StateValue -State $state -Name "worktreePath" -Default "")
        runtimeRoot = [string](Get-StateValue -State $state -Name "runtimeRoot" -Default "")
        closed = [bool](Get-StateValue -State $state -Name "closedAt" -Default "")
        pendingDeregistration = ConvertTo-BoolSetting -Value (Get-StateValue -State $state -Name "pendingDeregistration" -Default $false) -Default $false
    }
    Write-Output ($plan | ConvertTo-Json -Compress)
}

function Unlock-OpenCodeDevWorktree {
    param([string]$MainRoot, [string]$WorktreePath, [string]$Branch)

    $worktree = Find-GitWorktreeByBranch -Branch $Branch
    if ($null -eq $worktree) { return }
    if ((Resolve-Agent1cFullPath -Path $worktree.path) -ne (Resolve-Agent1cFullPath -Path $WorktreePath)) {
        throw "OpenCode workspace worktree path changed unexpectedly. State: $WorktreePath. Git: $($worktree.path)."
    }
    if ($worktree.PSObject.Properties.Name -notcontains "locked" -or -not $worktree.locked) { return }
    & git -C $MainRoot worktree unlock $WorktreePath
    if ($LASTEXITCODE -ne 0) { throw "Unable to unlock OpenCode worktree before native removal: $WorktreePath" }
}

function Set-DevWorkspaceDeregistration {
    Require-Value "DevBranchName" $DevBranchName | Out-Null
    Require-Value "DeregistrationStatus" $DeregistrationStatus | Out-Null
    Assert-MasterWorktreeContext -Operation "set-dev-workspace-deregistration"
    $state = Read-DevBranchState -Name $DevBranchName
    if ((Get-StateValue -State $state -Name "workspaceProvider" -Default "external") -ne "opencode") {
        throw "Legacy development branch state cannot be changed by OpenCode workspace deregistration."
    }
    if (-not (Get-StateValue -State $state -Name "closedAt" -Default "")) {
        throw "OpenCode workspace deregistration is allowed only after close-dev-branch completed."
    }

    $branch = [string]$state.devBranch
    $mainRoot = Resolve-Agent1cFullPath -Path (Get-StateValue -State $state -Name "mainWorktreePath" -Default "")
    $worktreePath = Resolve-Agent1cFullPath -Path (Get-StateValue -State $state -Name "worktreePath" -Default "")
    if ($mainRoot -ne (Resolve-Agent1cFullPath -Path $script:ProjectRoot)) {
        throw "OpenCode deregistration must run from the state-owned main worktree: $mainRoot"
    }

    switch ($DeregistrationStatus) {
        "pending" {
            Unlock-OpenCodeDevWorktree -MainRoot $mainRoot -WorktreePath $worktreePath -Branch $branch
            Update-DevBranchState -State $state -Updates @{
                clientWorkspaceId = $ClientWorkspaceId
                pendingDeregistration = $true
                pendingDeregistrationAt = (Get-Date).ToString("o")
                pendingDeregistrationError = ""
                worktreeLocked = $false
            }
        }
        "failed" {
            $worktree = Find-GitWorktreeByBranch -Branch $branch
            if ($null -ne $worktree) {
                Lock-OpenCodeDevWorktree -MainRoot $mainRoot -WorktreePath $worktreePath -Branch $branch
            }
            Update-DevBranchState -State $state -Updates @{
                clientWorkspaceId = $ClientWorkspaceId
                pendingDeregistration = $true
                pendingDeregistrationError = $DeregistrationError
                worktreeLocked = [bool]($null -ne $worktree)
            }
        }
        "complete" {
            if ($null -ne (Find-GitWorktreeByBranch -Branch $branch)) {
                throw "OpenCode reported workspace removal complete but Git still registers its worktree: $branch"
            }
            Update-DevBranchState -State $state -Updates @{
                clientWorkspaceId = $ClientWorkspaceId
                pendingDeregistration = $false
                pendingDeregistrationError = ""
                workspaceDeregisteredAt = (Get-Date).ToString("o")
                worktreeLocked = $false
            }
        }
    }
}

function Get-ResumableDevBranchState {
    param(
        [string]$SafeDevBranchName,
        [string]$GitBranch
    )

    $statePath = Find-DevBranchStateFile -SafeDevBranchName $SafeDevBranchName
    if (-not $statePath) {
        return $null
    }

    $state = Read-DevBranchStateFile -Path $statePath
    if (-not (Test-DevBranchInitializationResumable -State $state)) {
        return $null
    }

    $stateBranch = Get-StateValue -State $state -Name "devBranch" -Default ""
    if ($stateBranch -and $stateBranch -ne $GitBranch) {
        throw "Existing development branch state for '$SafeDevBranchName' belongs to '$stateBranch', not '$GitBranch'."
    }

    $worktree = Find-GitWorktreeByBranch -Branch $GitBranch
    if ($null -eq $worktree -or -not $worktree.path) {
        throw "Development branch already exists but no Git worktree was found for resumable initialization: $GitBranch"
    }

    $stateWorktreePath = Get-StateValue -State $state -Name "worktreePath" -Default (Get-StateValue -State $state -Name "stateProjectRoot" -Default "")
    if ($stateWorktreePath -and ((Get-FullPathNormalized $stateWorktreePath) -ne (Get-FullPathNormalized $worktree.path))) {
        throw "Existing development branch state points to a different worktree. State: $stateWorktreePath. Git worktree: $($worktree.path)."
    }

    return $state
}

function New-DevBranchCore {
    param(
        [ValidateSet("configuration", "extension")]
        [string]$DevBranchKind = "configuration",
        [switch]$DeferHandoff
    )

    Require-Value "DevBranchName" $DevBranchName | Out-Null
    $safe = ConvertTo-SafeName $DevBranchName
    if (-not $DevBranch) {
        $DevBranch = "itldev/$safe"
    }

    Assert-MasterWorktreeContext -Operation "new development branch"
    Assert-CleanGit
    Assert-DevBranchUnsafeActionProtectionPromptAvailable
    Checkout-Master

    $mainProjectRoot = Get-MainWorktreePath
    $branchExists = Test-GitBranchExists -Branch $DevBranch
    if ($UseCurrentWorktree) {
        if ($branchExists) {
            throw "Development branch already exists: $DevBranch"
        }
        Invoke-Git @("checkout", "-b", $DevBranch)
        Initialize-DevBranchRuntime `
            -DevBranchKind $DevBranchKind `
            -SafeDevBranchName $safe `
            -GitBranch $DevBranch `
            -MainProjectRoot $script:ProjectRoot `
            -WorktreePath $script:ProjectRoot `
            -CreatedWithWorktree $false
        return
    }

    $worktreePath = Resolve-DevBranchWorktreePath -SafeDevBranchName $safe
    if ($branchExists) {
        $resumeState = Get-ResumableDevBranchState -SafeDevBranchName $safe -GitBranch $DevBranch
        if ($null -ne $resumeState) {
            $resumeWorktreePath = Get-StateValue -State $resumeState -Name "worktreePath" -Default (Get-StateValue -State $resumeState -Name "stateProjectRoot" -Default "")
            Write-Host "Resuming development branch initialization: $DevBranch"
            Write-Host "Development branch worktree: $resumeWorktreePath"
            Copy-KiloProjectConfigToWorktree -MainProjectRoot $mainProjectRoot -WorktreePath $resumeWorktreePath
            Invoke-InProjectContext -Root $resumeWorktreePath -ScriptBlock {
                Initialize-DevBranchRuntime `
                    -DevBranchKind $DevBranchKind `
                    -SafeDevBranchName $safe `
                    -GitBranch $DevBranch `
                    -MainProjectRoot $mainProjectRoot `
                    -WorktreePath $resumeWorktreePath `
                    -CreatedWithWorktree $true
            }

            if (-not $DeferHandoff) {
                Write-DevBranchWorktreeOpenMessage -MainProjectPath $mainProjectRoot -WorktreePath $resumeWorktreePath
                Open-AgentWorktreeBestEffort -WorktreePath $resumeWorktreePath
            }
            return
        }

        throw "Development branch already exists: $DevBranch"
    }
    if (Test-Path -LiteralPath $worktreePath -ErrorAction SilentlyContinue) {
        throw "Development branch worktree path already exists: $worktreePath"
    }

    $worktreeParent = Split-Path -Parent $worktreePath
    if ($worktreeParent) {
        New-Item -ItemType Directory -Force -Path $worktreeParent | Out-Null
    }
    Invoke-Git @("worktree", "add", "-b", $DevBranch, $worktreePath, (Get-MasterBranch))
    Copy-DotEnvToWorktree -WorktreePath $worktreePath
    Copy-KiloProjectConfigToWorktree -MainProjectRoot $mainProjectRoot -WorktreePath $worktreePath

    Invoke-InProjectContext -Root $worktreePath -ScriptBlock {
        Initialize-DevBranchRuntime `
            -DevBranchKind $DevBranchKind `
            -SafeDevBranchName $safe `
            -GitBranch $DevBranch `
            -MainProjectRoot $mainProjectRoot `
            -WorktreePath $worktreePath `
            -CreatedWithWorktree $true
    }

    if (-not $DeferHandoff) {
        Write-DevBranchWorktreeOpenMessage -MainProjectPath $mainProjectRoot -WorktreePath $worktreePath
        Open-AgentWorktreeBestEffort -WorktreePath $worktreePath
    }
}

function New-DevBranch {
    New-DevBranchCore -DevBranchKind "configuration"
    $advisoryRoot = if ($script:RunWorktreePath) { $script:RunWorktreePath } else { $script:ProjectRoot }
    $state = Read-DevBranchState -Name $DevBranchName
    Set-RunDevBranchState -State $state
    Write-KiloBrowserAutomationSummary -ProjectRoot $advisoryRoot
    Write-DevBranchRunUserReport -State $state -AdvisoryRoot $advisoryRoot
}

function Resolve-NewExtensionProvisioningInput {
    $hasAnyInput = [bool]($ExtensionInitMode -or $ExtensionName -or $ExtensionSourcePath)
    if (-not $hasAnyInput) {
        return $false
    }
    if (-not $ExtensionInitMode -or -not $ExtensionName) {
        throw "EXTENSION_INIT_INPUT_INCOMPLETE: provide ExtensionInitMode Empty or Cfe and ExtensionName together. ExtensionSourcePath is also required for Cfe."
    }
    Assert-ExtensionInitName -Name $ExtensionName | Out-Null
    if ($ExtensionInitMode -eq "Cfe") {
        Require-Value "ExtensionSourcePath" $ExtensionSourcePath | Out-Null
        $resolvedSource = Resolve-Agent1cFullPath -Path $ExtensionSourcePath
        if (-not (Test-Path -LiteralPath $resolvedSource -PathType Leaf) -or [System.IO.Path]::GetExtension($resolvedSource) -ine ".cfe") {
            throw "ExtensionSourcePath must be an existing .cfe file: $ExtensionSourcePath"
        }
        if ((Get-Item -LiteralPath $resolvedSource).Length -le 0) {
            throw "ExtensionSourcePath is empty: $resolvedSource"
        }
        $script:ExtensionSourcePath = $resolvedSource
    } elseif ($ExtensionSourcePath) {
        throw "EXTENSION_INIT_INPUT_INCOMPLETE: ExtensionSourcePath is valid only with ExtensionInitMode Cfe."
    }
    return $true
}

function Get-PreparedExtensionDevBranchState {
    Require-Value "DevBranchName" $DevBranchName | Out-Null
    $safe = ConvertTo-SafeName $DevBranchName
    $gitBranch = if ($DevBranch) { $DevBranch } else { "itldev/$safe" }
    if (-not (Test-GitBranchExists -Branch $gitBranch)) {
        return $null
    }
    $statePath = Find-DevBranchStateFile -SafeDevBranchName $safe
    if (-not $statePath) {
        return $null
    }
    $state = Read-DevBranchStateFile -Path $statePath
    if ((Get-StateValue -State $state -Name "devBranch" -Default "") -ne $gitBranch) {
        return $null
    }
    if ((Get-DevBranchInitializationStatus -State $state) -ne "ready") {
        return $null
    }
    Assert-DevBranchKind -State $state -Expected "extension"
    if ((Get-DevBranchExtensionInitializationStatus -State $state) -eq "ready") {
        return $null
    }
    return $state
}

function Set-RunExtensionProvisioningState {
    param([object]$State)

    Set-RunDevBranchState -State $State
}

function Invoke-ExtensionInitializationInWorktree {
    param([string]$WorktreePath)

    $resolvedWorktree = Resolve-Agent1cFullPath -Path $WorktreePath
    if ((Get-FullPathNormalized $resolvedWorktree) -eq (Get-FullPathNormalized $script:ProjectRoot)) {
        Init-DevBranchExtension
        return
    }

    $helperPath = Join-Path $resolvedWorktree ".agents\skills\1c-workflow\scripts\agent-1c.ps1"
    if (-not (Test-Path -LiteralPath $helperPath -PathType Leaf)) {
        throw "Extension initialization helper is missing from the new worktree: $helperPath"
    }
    Set-RunStage -Stage "extension-init.delegate" -Detail "Running the transactional extension initialization under the new worktree lifecycle lock."
    $childArgs = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $helperPath,
        "-ProjectRoot", $resolvedWorktree,
        "-Action", "init-dev-branch-extension",
        "-DevBranchName", $DevBranchName,
        "-ExtensionInitMode", $ExtensionInitMode,
        "-ExtensionName", $ExtensionName
    )
    if ($ExtensionSourcePath) {
        $childArgs += @("-ExtensionSourcePath", $ExtensionSourcePath)
    }
    & powershell @childArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Extension initialization failed in the new worktree. Inspect the preceding helper error and saved branch status."
    }
}

function New-ExtensionDevBranch {
    $hasProvisioningInput = Resolve-NewExtensionProvisioningInput
    $state = Get-PreparedExtensionDevBranchState
    if ($state) {
        Assert-MasterWorktreeContext -Operation "resume extension development branch provisioning"
        Assert-CleanGit
    } else {
        New-DevBranchCore -DevBranchKind "extension" -DeferHandoff
        $state = Read-DevBranchState -Name $DevBranchName
    }

    Set-RunExtensionProvisioningState -State $state
    $worktreePath = Get-StateValue -State $state -Name "worktreePath" -Default (Get-StateValue -State $state -Name "stateProjectRoot" -Default "")
    $mainWorktreePath = Get-StateValue -State $state -Name "mainWorktreePath" -Default $script:ProjectRoot
    try {
        if ($hasProvisioningInput) {
            Invoke-ExtensionInitializationInWorktree -WorktreePath $worktreePath
            $state = Read-DevBranchState -Name $DevBranchName
            Set-RunExtensionProvisioningState -State $state
        } else {
            Set-RunStage -Stage "extension-init.pending" -Detail "The extension branch is ready for agent-guided extension initialization."
            Set-RunFailureContext -RequiredAction "В worktree расширения уточните у разработчика, нужно создать пустое расширение или загрузить CFE, получите имя расширения и, при необходимости, путь к CFE, затем запустите внутренний helper init-dev-branch-extension. Не просите разработчика запускать PowerShell."
            Write-Host "Extension initialization: pending"
            Write-Host "The agent will ask for Empty or CFE, extension name, and optional CFE path in the extension worktree."
        }
    } catch {
        $provisioningError = $_
        Set-RunFailureContext -RequiredAction "Inspect extensionInitializationError in the saved branch state, address the cause, then repeat the same extension-branch request with the setup values. Do not ask the developer to run PowerShell."
        try {
            $state = Read-DevBranchState -Name $DevBranchName
            Set-RunExtensionProvisioningState -State $state
        } catch {
        }
        throw $provisioningError
    } finally {
        if (-not $UseCurrentWorktree -and $worktreePath) {
            Write-DevBranchWorktreeOpenMessage -MainProjectPath $mainWorktreePath -WorktreePath $worktreePath
            Open-AgentWorktreeBestEffort -WorktreePath $worktreePath
        }
    }
    $advisoryRoot = if ($worktreePath) { $worktreePath } else { $script:ProjectRoot }
    Write-KiloBrowserAutomationSummary -ProjectRoot $advisoryRoot
    Write-DevBranchRunUserReport -State $state -AdvisoryRoot $advisoryRoot
}

function Assert-ExtensionInitName {
    param([string]$Name)

    Require-Value "ExtensionName" $Name | Out-Null
    if ($Name -notmatch '^[\p{L}_][\p{L}\p{Nd}_]*$') {
        throw "ExtensionName must be a valid 1C identifier and a single path segment: $Name"
    }
    return $Name
}

function Get-ExtensionInitDumpPath {
    param([string]$Name)

    Assert-ExtensionInitName -Name $Name | Out-Null
    return "src/cfe/$Name"
}

function Get-ExtensionLifecycleToolPaths {
    $override = Get-Variable -Name ExtensionLifecycleToolRootOverride -Scope Script -ErrorAction SilentlyContinue
    $activeClient = ""
    $toolRoot = if ($null -ne $override -and -not [string]::IsNullOrWhiteSpace([string]$override.Value)) {
        [System.IO.Path]::GetFullPath([string]$override.Value)
    } else {
        $activeClient = Get-ItlActiveClient
        $skillRoot = Get-AiRules1cInstalledSkillRoot -SkillName "1c-metadata-manage" -Client $activeClient
        Join-Path $skillRoot "tools\1c-cfe-manage\scripts"
    }
    $initPath = Join-Path $toolRoot "cfe-init.ps1"
    $validatePath = Join-Path $toolRoot "cfe-validate.ps1"
    $missing = @(@($initPath, $validatePath) | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) })
    if ($missing.Count -gt 0) {
        $source = if ($activeClient) { "active ai_rules_1c client '$activeClient'" } else { "the Release tool override" }
        throw "Extension lifecycle tools are missing for $source. Checked: $initPath and $validatePath. Missing: $($missing -join ', '). If these managed files are absent, run pinned update-ai-rules from master, then retry init-dev-branch-extension."
    }
    return [pscustomobject]@{
        init = $initPath
        validate = $validatePath
    }
}

function Invoke-ExtensionLifecycleTool {
    param(
        [string]$ScriptPath,
        [string[]]$Arguments
    )

    & powershell -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Extension lifecycle tool failed with exit code ${LASTEXITCODE}: $ScriptPath"
    }
}

function Test-DevBranchExtensionExists {
    param(
        [object]$State,
        [string]$Name
    )

    try {
        Invoke-Designer `
            -InfoBasePath $State.devBranchInfoBasePath `
            -InfoBaseKind $State.infoBaseKind `
            -DesignerArgs @("/DumpDBCfgList", "-Extension", $Name) | Out-Null
        return $true
    } catch {
        $message = $_.Exception.Message
        $logText = ""
        if ($script:LastLogPath -and (Test-Path -LiteralPath $script:LastLogPath -PathType Leaf -ErrorAction SilentlyContinue)) {
            try { $logText = Read-Utf8Text -Path $script:LastLogPath } catch { $logText = "" }
        }
        $combined = "$message`n$logText"
        if ($combined -match '(?is)(extension|\u0440\u0430\u0441\u0448\u0438\u0440\u0435\u043d)[^\r\n]*(not found|\u043d\u0435\s+\u043d\u0430\u0439\u0434\u0435\u043d|\u043d\u0435\s+\u0441\u0443\u0449\u0435\u0441\u0442\u0432\u0443\u0435\u0442|\u043e\u0442\u0441\u0443\u0442\u0441\u0442\u0432)') {
            return $false
        }
        throw
    }
}

function Assert-NormalizedExtensionDump {
    param(
        [string]$Path,
        [string]$Name
    )

    $configurationFiles = @(Get-ChildItem -LiteralPath $Path -Recurse -File -Filter "Configuration.xml" -ErrorAction Stop)
    $dumpInfoFiles = @(Get-ChildItem -LiteralPath $Path -Recurse -File -Filter "ConfigDumpInfo.xml" -ErrorAction Stop)
    $rootConfiguration = Join-Path $Path "Configuration.xml"
    $rootDumpInfo = Join-Path $Path "ConfigDumpInfo.xml"
    if ($configurationFiles.Count -ne 1 -or -not (Test-Path -LiteralPath $rootConfiguration -PathType Leaf)) {
        throw "Extension dump must contain exactly one root Configuration.xml: $Path"
    }
    if ($dumpInfoFiles.Count -ne 1 -or -not (Test-Path -LiteralPath $rootDumpInfo -PathType Leaf)) {
        throw "Extension dump must contain exactly one root ConfigDumpInfo.xml: $Path"
    }
    foreach ($directory in @(Get-ChildItem -LiteralPath $Path -Recurse -Directory -ErrorAction Stop)) {
        $relative = $directory.FullName.Substring($Path.TrimEnd("\").Length).TrimStart("\", "/")
        if ($relative -match '(?i)(^|[\\/])src[\\/]cfe([\\/]|$)') {
            throw "Nested src/cfe was found inside extension dump: $($directory.FullName)"
        }
        $segments = @($relative -split '[\\/]' | Where-Object { $_ })
        for ($index = 1; $index -lt $segments.Count; $index++) {
            if ($segments[$index] -ieq $segments[$index - 1] -and $segments[$index] -match '(?i)^(DataProcessors|Reports|Catalogs|Documents|Forms|Templates)$') {
                throw "Duplicated metadata directory '$($segments[$index])/$($segments[$index])' was found inside extension dump: $($directory.FullName)"
            }
        }
    }

    try {
        $xml = New-Object System.Xml.XmlDocument
        $xml.PreserveWhitespace = $true
        $xml.Load($rootConfiguration)
        $nameNode = $xml.SelectSingleNode("//*[local-name()='Configuration']/*[local-name()='Properties']/*[local-name()='Name']")
    } catch {
        throw "Extension Configuration.xml is not valid Unicode XML: $($_.Exception.Message)"
    }
    if ($null -eq $nameNode -or $nameNode.InnerText.Trim() -ne $Name) {
        $actual = if ($null -eq $nameNode) { "<missing>" } else { $nameNode.InnerText.Trim() }
        throw "Extension name in Configuration.xml does not match ExtensionName. Expected '$Name', actual '$actual'."
    }
}

function Restore-ExtensionInitMcpRuntime {
    param(
        [object]$State,
        [bool]$RoctupWasRunning,
        [bool]$VanessaWasRunning
    )

    $currentState = Read-DevBranchState -Name (Get-StateValue -State $State -Name "devBranchName" -Default "")
    # Legacy flags are accepted during migration, but no backend is restarted.
    # Stable stdio facades remain configured and create fresh instances lazily.
    Write-ItlBranchMcpClientConfig -State $currentState
}

function Init-DevBranchExtension {
    Write-Section "Initialize development branch extension"
    $state = Read-DevBranchState -Name $DevBranchName
    Assert-DevelopmentBranchWorktreeContext -State $state -Operation "init-dev-branch-extension"
    Assert-DevBranchKind -State $state -Expected "extension"
    if ($ExtensionInitMode -notin @("Empty", "Cfe")) {
        throw "ExtensionInitMode must be Empty or Cfe."
    }
    Assert-ExtensionInitName -Name $ExtensionName | Out-Null

    $existingStateName = Get-StateValue -State $state -Name "extensionName" -Default ""
    $initializedAt = Get-StateValue -State $state -Name "extensionInitializedAt" -Default ""
    if ($existingStateName -or $initializedAt) {
        Write-Host "EXTENSION_BRANCH_ALREADY_INITIALIZED"
        throw "EXTENSION_BRANCH_ALREADY_INITIALIZED: extension branch already owns '$existingStateName'. Multiple features are allowed only inside that same extension; create a separate extension branch/worktree/base for another CFE."
    }
    Assert-SingleManagedExtensionArtifact -State $state -ExtensionNameOverride $ExtensionName

    $dumpPath = Get-ExtensionInitDumpPath -Name $ExtensionName
    $absoluteDumpPath = Assert-ExportPathInsideProject -ExportPath $dumpPath
    $expectedDumpPath = Resolve-Agent1cFullPath -Path (Join-Path $script:ProjectRoot ("src\cfe\" + $ExtensionName))
    if (-not [string]::Equals($absoluteDumpPath, $expectedDumpPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Extension dump path must resolve exactly to src/cfe/$ExtensionName. Actual: $absoluteDumpPath"
    }
    $targetExisted = Test-Path -LiteralPath $absoluteDumpPath -PathType Container -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $absoluteDumpPath -PathType Leaf -ErrorAction SilentlyContinue) {
        throw "Extension dump target is a file: $absoluteDumpPath"
    }
    if ($targetExisted -and @(Get-ChildItem -LiteralPath $absoluteDumpPath -Force -ErrorAction Stop).Count -gt 0) {
        throw "Extension dump target is not empty; refusing to overwrite it: $absoluteDumpPath"
    }
    if (Test-DevBranchExtensionExists -State $state -Name $ExtensionName) {
        throw "Extension '$ExtensionName' already exists in the development branch infobase; refusing to overwrite it."
    }

    $sourceCfe = ""
    if ($ExtensionInitMode -eq "Cfe") {
        Require-Value "ExtensionSourcePath" $ExtensionSourcePath | Out-Null
        $sourceCfe = Resolve-Agent1cFullPath -Path $ExtensionSourcePath
        if (-not (Test-Path -LiteralPath $sourceCfe -PathType Leaf) -or [System.IO.Path]::GetExtension($sourceCfe) -ine ".cfe") {
            throw "ExtensionSourcePath must be an existing .cfe file: $ExtensionSourcePath"
        }
        if ((Get-Item -LiteralPath $sourceCfe).Length -le 0) {
            throw "ExtensionSourcePath is empty: $sourceCfe"
        }
    }

    $tools = $null
    $stagingRoot = ""
    $snapshotDir = ""
    $snapshotPath = ""
    $snapshotCreated = $false
    $roctupWasRunning = $false
    $vanessaWasRunning = $false

    Update-DevBranchState -State $state -Updates @{
        extensionInitializationStatus = "running"
        extensionInitializationError = ""
        extensionInitializationUpdatedAt = (Get-Date).ToString("o")
    }
    $state = Read-DevBranchState -Name (Get-StateValue -State $state -Name "devBranchName" -Default "")

    try {
        $tools = Get-ExtensionLifecycleToolPaths
        $stagingRoot = Assert-ExportPathInsideProject -ExportPath (".agent-1c/extension-init/" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Force -Path $stagingRoot | Out-Null
        $snapshotDir = Assert-ExportPathInsideProject -ExportPath ".agent-1c/snapshots"
        $snapshotPath = Join-Path $snapshotDir ("extension-init-{0}-{1}.dt" -f (ConvertTo-SafeName $ExtensionName), (Get-Date -Format "yyyyMMdd-HHmmss"))
        $roctupWasRunning = [bool](Get-RoctupMcpRuntimeInfo -State $state).processAlive
        $vanessaWasRunning = [bool](Get-VanessaMcpRuntimeInfo -State $state).processAlive
        Stop-DevBranchRuntimeBeforeInfobaseMutation -State $state -Reason "extension initialization"
        $state = Read-DevBranchState -Name (Get-StateValue -State $state -Name "devBranchName" -Default "")

        Set-RunStage -Stage "extension-init.snapshot" -Detail "Creating a rollback snapshot before extension initialization."
        New-Item -ItemType Directory -Force -Path $snapshotDir | Out-Null
        Invoke-Designer -InfoBasePath $state.devBranchInfoBasePath -InfoBaseKind $state.infoBaseKind -DesignerArgs @("/DumpIB", $snapshotPath) | Out-Null
        if (-not (Test-Path -LiteralPath $snapshotPath -PathType Leaf)) {
            throw "1C snapshot was not created: $snapshotPath"
        }
        $snapshotCreated = $true

        if ($ExtensionInitMode -eq "Empty") {
            Set-RunStage -Stage "extension-init.scaffold" -Detail "Creating and validating the Empty extension scaffold."
            $scaffoldPath = Join-Path $stagingRoot "scaffold"
            Invoke-ExtensionLifecycleTool -ScriptPath $tools.init -Arguments @(
                "-Name", $ExtensionName,
                "-OutputDir", $scaffoldPath,
                "-Purpose", "Customization",
                "-NamePrefix", ($ExtensionName + "_"),
                "-ConfigPath", (Assert-ExportPathInsideProject -ExportPath (Get-ExportPath)),
                "-NoRole"
            )
            Invoke-ExtensionLifecycleTool -ScriptPath $tools.validate -Arguments @("-ExtensionPath", $scaffoldPath)
            Set-RunStage -Stage "extension-init.load" -Detail "Loading the extension scaffold into the branch infobase."
            Invoke-Designer -InfoBasePath $state.devBranchInfoBasePath -InfoBaseKind $state.infoBaseKind -DesignerArgs @(
                "/LoadConfigFromFiles", $scaffoldPath, "-Extension", $ExtensionName, "-Format", "Hierarchical", "/UpdateDBCfg"
            ) | Out-Null
        } else {
            Set-RunStage -Stage "extension-init.load" -Detail "Loading the supplied CFE into the branch infobase."
            Invoke-Designer -InfoBasePath $state.devBranchInfoBasePath -InfoBaseKind $state.infoBaseKind -DesignerArgs @(
                "/LoadCfg", $sourceCfe, "-Extension", $ExtensionName, "/UpdateDBCfg"
            ) | Out-Null
        }

        Set-RunStage -Stage "extension-init.dump" -Detail "Dumping and validating the canonical extension source tree."
        New-Item -ItemType Directory -Force -Path $absoluteDumpPath | Out-Null
        Invoke-Designer -InfoBasePath $state.devBranchInfoBasePath -InfoBaseKind $state.infoBaseKind -DesignerArgs @(
            "/DumpConfigToFiles", $absoluteDumpPath, "-Extension", $ExtensionName, "-Format", "Hierarchical"
        ) | Out-Null
        Assert-NormalizedExtensionDump -Path $absoluteDumpPath -Name $ExtensionName
        Invoke-ExtensionLifecycleTool -ScriptPath $tools.validate -Arguments @("-ExtensionPath", $absoluteDumpPath)
        $extensionSource = Get-ConfigSourceFingerprint -ExportPath $dumpPath

        Restore-ExtensionInitMcpRuntime -State $state -RoctupWasRunning $roctupWasRunning -VanessaWasRunning $vanessaWasRunning
        $state = Read-DevBranchState -Name (Get-StateValue -State $state -Name "devBranchName" -Default "")
        $now = (Get-Date).ToString("o")
        $updates = @{
            extensionName = $ExtensionName
            safeExtensionName = ConvertTo-SafeName $ExtensionName
            extensionInitMode = $ExtensionInitMode
            extensionInitializationStatus = "ready"
            extensionInitializationError = ""
            extensionInitializationUpdatedAt = $now
            extensionDumpPath = $dumpPath
            extensionExportPath = $dumpPath
            extensionInitializedAt = $now
            lastExtensionDumpAt = $now
            lastExtensionDumpPath = $dumpPath
            lastExtensionBaseUpdateAt = $now
            lastExtensionBaseUpdatedCommit = Get-CurrentCommit
            lastExtensionDesignerFingerprint = $extensionSource.fingerprint
            lastExtensionDesignerLoadedAt = $now
            sourceFingerprint = $extensionSource.fingerprint
            loadReason = "extension-init-seed"
            designerInvoked = $true
            enterpriseInvoked = $false
            extensionRecoveryStatus = "not-required"
            extensionRecoveryReason = "initialized and dumped transactionally"
            enterpriseNormalizationStatus = "pending"
            enterpriseNormalizationReason = "extension-init"
            enterpriseNormalizationError = ""
            lastLoadedCommit = Get-CurrentCommit
            lastLogPath = $script:LastLogPath
        }
        Set-RunStage -Stage "extension-init.state" -Detail "Saving the initialized extension state and fingerprint."
        Add-VerificationStaleIfNeeded -State $state -Updates $updates -Reason "Extension was initialized in the development branch infobase." -Force
        Update-DevBranchState -State $state -Updates $updates
        $state = Read-DevBranchState -Name (Get-StateValue -State $state -Name "devBranchName" -Default "")
        Sync-DevBranchContextToDotEnv -State $state

        Write-Host "Extension initialized: $ExtensionName ($ExtensionInitMode)"
        Write-Host "Normalized extension dump: $dumpPath"
        Write-Host "Run /itl-check before reporting the development task complete."
    } catch {
        $originalError = $_.Exception.Message
        $rollbackError = ""
        if ($snapshotCreated) {
            try {
                Set-RunStage -Stage "extension-init.rollback" -Detail "Restoring the branch infobase snapshot after extension initialization failure."
                Restore-DevBranchInfobaseFromSnapshot -State $state -SnapshotPath $snapshotPath -Reason "extension initialization rollback"
                Update-DevBranchState -State $state -Updates @{
                    lastConfigDesignerFingerprint = ""
                    lastConfigDesignerLoadedAt = ""
                    lastExtensionDesignerFingerprint = ""
                    lastExtensionDesignerLoadedAt = ""
                    sourceFingerprint = ""
                    loadReason = "restore-invalidated"
                    designerInvoked = $false
                    enterpriseInvoked = $false
                    enterpriseNormalizationStatus = "pending"
                    enterpriseNormalizationReason = "extension-init-rollback"
                }
            } catch {
                $rollbackError = $_.Exception.Message
            }
        }
        try {
            if (Test-Path -LiteralPath $absoluteDumpPath -PathType Container -ErrorAction SilentlyContinue) {
                if ($targetExisted) {
                    foreach ($child in @(Get-ChildItem -LiteralPath $absoluteDumpPath -Force -ErrorAction SilentlyContinue)) {
                        Remove-Item -LiteralPath $child.FullName -Recurse -Force
                    }
                } else {
                    Remove-Item -LiteralPath $absoluteDumpPath -Recurse -Force
                }
            }
        } catch {
            Write-Warning "Could not remove partial extension dump: $($_.Exception.Message)"
        }
        try {
            Restore-ExtensionInitMcpRuntime -State $state -RoctupWasRunning $roctupWasRunning -VanessaWasRunning $vanessaWasRunning
        } catch {
            Write-Warning "Could not restore branch MCP runtime after extension initialization failure: $($_.Exception.Message)"
        }
        $failureMessage = if ($rollbackError) {
            "Extension initialization failed: $originalError Rollback also failed: $rollbackError Snapshot retained: $snapshotPath"
        } elseif ($snapshotCreated) {
            "Extension initialization failed and the infobase snapshot was restored: $originalError"
        } else {
            "Extension initialization failed before a snapshot was created: $originalError"
        }
        try {
            $failedState = Read-DevBranchState -Name (Get-StateValue -State $state -Name "devBranchName" -Default "")
            Update-DevBranchState -State $failedState -Updates @{
                extensionInitializationStatus = "failed"
                extensionInitializationError = $failureMessage
                extensionInitializationUpdatedAt = (Get-Date).ToString("o")
            }
        } catch {
            Write-Warning "Could not persist failed extension initialization status: $($_.Exception.Message)"
        }
        throw $failureMessage
    } finally {
        if ($stagingRoot -and (Test-Path -LiteralPath $stagingRoot -PathType Container -ErrorAction SilentlyContinue)) {
            Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Set-DevBranchExtension {
    $state = Read-DevBranchState -Name $DevBranchName
    Assert-DevelopmentBranchWorktreeContext -State $state -Operation "set-dev-branch-extension"
    Assert-DevBranchKind -State $state -Expected "extension"
    Assert-ExtensionInitName -Name $ExtensionName | Out-Null

    $existing = Get-StateValue -State $state -Name "extensionName" -Default ""
    if ($existing -and $existing -ne $ExtensionName -and -not $Force) {
        throw "Extension name is already set to '$existing'. Pass -Force to overwrite it."
    }

    if (-not (Test-DevBranchExtensionExists -State $state -Name $ExtensionName)) {
        Write-Host "EXTENSION_RECOVERY_SLOT_MISSING"
        throw "EXTENSION_RECOVERY_SLOT_MISSING: extension '$ExtensionName' is absent from the branch infobase. Recovery context was not changed."
    }

    Assert-SingleManagedExtensionArtifact -State $state -ExtensionNameOverride $ExtensionName

    $safeExtensionName = ConvertTo-SafeName $ExtensionName
    $extensionExportPath = Get-ExtensionInitDumpPath -Name $ExtensionName
    $absoluteExtensionExportPath = Assert-ExportPathInsideProject -ExportPath $extensionExportPath
    $recoveryStatus = "pending-dump"
    $recoveryReason = "canonical dump is absent or empty"
    if (Test-Path -LiteralPath $absoluteExtensionExportPath -PathType Leaf -ErrorAction SilentlyContinue) {
        throw "Extension recovery dump target is a file: $absoluteExtensionExportPath"
    }
    if (Test-Path -LiteralPath $absoluteExtensionExportPath -PathType Container -ErrorAction SilentlyContinue) {
        $children = @(Get-ChildItem -LiteralPath $absoluteExtensionExportPath -Force -ErrorAction Stop)
        if ($children.Count -gt 0) {
            $rootConfiguration = Join-Path $absoluteExtensionExportPath "Configuration.xml"
            try {
                $dumpXml = New-Object System.Xml.XmlDocument
                $dumpXml.Load($rootConfiguration)
                $dumpNameNode = $dumpXml.SelectSingleNode("//*[local-name()='Configuration']/*[local-name()='Properties']/*[local-name()='Name']")
                $dumpName = if ($dumpNameNode) { $dumpNameNode.InnerText.Trim() } else { "" }
            } catch {
                throw "Extension recovery dump is invalid and state was not changed: $($_.Exception.Message)"
            }
            if ($dumpName -eq $ExtensionName) {
                Assert-NormalizedExtensionDump -Path $absoluteExtensionExportPath -Name $ExtensionName
                $tools = Get-ExtensionLifecycleToolPaths
                Invoke-ExtensionLifecycleTool -ScriptPath $tools.validate -Arguments @("-ExtensionPath", $absoluteExtensionExportPath)
                $recoveryReason = "validated canonical dump requires a fresh transactional slot dump"
            } elseif ($dumpName) {
                # The infobase slot is authoritative.  A dump for another name is
                # tolerated only as pending recovery input and will be replaced
                # transactionally by dump-dev-branch-extension.
                $recoveryReason = "existing dump belongs to '$dumpName'; slot '$ExtensionName' is authoritative"
            } else {
                throw "Extension recovery dump has no Configuration/Properties/Name and state was not changed: $absoluteExtensionExportPath"
            }
        }
    }
    $updates = @{
        extensionName = $ExtensionName
        safeExtensionName = $safeExtensionName
        extensionDumpPath = $extensionExportPath
        extensionExportPath = $extensionExportPath
        extensionInitializationStatus = "ready"
        extensionInitializationError = ""
        extensionInitializationUpdatedAt = (Get-Date).ToString("o")
        extensionRecoveryStatus = $recoveryStatus
        extensionRecoveryReason = $recoveryReason
        lastExtensionDesignerFingerprint = ""
        lastExtensionDesignerLoadedAt = ""
    }
    Add-VerificationStaleIfNeeded -State $state -Updates $updates -Reason "Extension settings changed." -Force
    Update-DevBranchState -State $state -Updates $updates
    $updatedState = Read-DevBranchState -Name $DevBranchName
    Sync-DevBranchContextToDotEnv -State $updatedState

    Write-Host "Development branch extension: $ExtensionName"
    Write-Host "Extension files path: $extensionExportPath"
    Write-Host "Recovery context recorded. set-dev-branch-extension does not create or load an extension in the infobase."
}

function Write-BaseUpdateResult {
    param(
        [object]$State,
        [object]$LoadResult,
        [string]$Label
    )

    if ($LoadResult.loaded) {
        Write-Host "$Label updated: $($State.devBranchInfoBasePath)"
        Write-Host "Last 1C log: $($LoadResult.lastLogPath)"
        $autoUpdateLogPath = Get-StateValue -State $State -Name "lastEnterpriseAutoUpdateLogPath" -Default ""
        if ($autoUpdateLogPath) {
            Write-Host "Last Enterprise auto-update log: $autoUpdateLogPath"
        }
    } else {
        Write-Host "$Label unchanged: $($State.devBranchInfoBasePath)"
    }
}

function Update-DevBranchBase {
    $state = Read-DevBranchState -Name $DevBranchName
    Assert-DevelopmentBranchWorktreeContext -State $state -Operation "update-dev-branch-base"
    Assert-DevBranchExtensionInitialized -State $state -Operation "update-dev-branch-base"
    Assert-SingleManagedExtensionArtifact -State $state
    Sync-DevBranchContextToDotEnv -State $state

    if ((Get-DevBranchKind -State $state) -eq "extension") {
        $extensionName = Require-DevBranchExtensionName -State $state
        $extensionExportPath = Assert-ExtensionFilesReady -State $state
        $loadResult = Load-ConfigFromFiles -InfoBasePath $state.devBranchInfoBasePath -InfoBaseKind $state.infoBaseKind -State $state -ExportPath $extensionExportPath -ContentKind "extension" -ExtensionName $extensionName -Mode $ConfigLoadMode
        $updates = New-LoadStateUpdates -LoadResult $loadResult -ContentKind "extension"
        Invoke-DevBranchEnterpriseAutoUpdateIfLoaded -State $state -LoadResult $loadResult -Updates $updates
        Add-VerificationStaleIfNeeded -State $state -Updates $updates -Reason "Development branch extension base was updated." -CurrentCommit $loadResult.currentCommit
        Update-DevBranchState -State $state -Updates $updates
        $updatedState = Invoke-DevBranchMcpRestartAfterInfobaseLoad -State (Read-DevBranchState -Name $DevBranchName) -LoadResult $loadResult -Reason "development branch extension base update"
        Write-BaseUpdateResult -State $updatedState -LoadResult $loadResult -Label "Development branch extension"
    } else {
        $loadResult = Load-ConfigFromFiles -InfoBasePath $state.devBranchInfoBasePath -InfoBaseKind $state.infoBaseKind -State $state -ExportPath (Get-ExportPath) -ContentKind "configuration" -Mode $ConfigLoadMode
        $updates = New-LoadStateUpdates -LoadResult $loadResult -ContentKind "configuration"
        Invoke-DevBranchEnterpriseAutoUpdateIfLoaded -State $state -LoadResult $loadResult -Updates $updates
        Add-VerificationStaleIfNeeded -State $state -Updates $updates -Reason "Development branch configuration base was updated." -CurrentCommit $loadResult.currentCommit
        Update-DevBranchState -State $state -Updates $updates
        $updatedState = Invoke-DevBranchMcpRestartAfterInfobaseLoad -State (Read-DevBranchState -Name $DevBranchName) -LoadResult $loadResult -Reason "development branch configuration base update"
        Write-BaseUpdateResult -State $updatedState -LoadResult $loadResult -Label "Development branch infobase"
    }
}

function Refresh-DevBranch {
    $state = Read-DevBranchState -Name $DevBranchName
    Assert-DevelopmentBranchWorktreeContext -State $state -Operation "refresh-dev-branch"
    Assert-DevBranchExtensionInitialized -State $state -Operation "refresh-dev-branch"
    Sync-DevBranchContextToDotEnv -State $state -AllowIncompleteExtension

    if ($LifecyclePhase -ne "post-merge") {
        Set-RunStage -Stage "refresh.master" -Detail "Synchronizing master before refreshing the development branch."
        Assert-CleanGit
        Sync-Master
        if ((Get-CurrentBranch) -ne $state.devBranch) {
            Invoke-Git @("checkout", $state.devBranch)
        }
        Set-RunStage -Stage "refresh.merge" -Detail "Merging master into the development branch."
        Invoke-Git @("merge", (Get-MasterBranch))
        Restart-Agent1cAfterDevBranchMerge -Operation "refresh-dev-branch"
    }

    Set-RunStage -Stage "refresh.load" -Detail "Updating the branch infobase after the merge."
    Sync-DevBranchContextToDotEnv -State $state -AllowIncompleteExtension
    $state = Invoke-DevBranchDefaultMcpSetup -State $state
    $loadResult = Load-ConfigFromFiles -InfoBasePath $state.devBranchInfoBasePath -InfoBaseKind $state.infoBaseKind -State $state -ExportPath (Get-ExportPath) -ContentKind "configuration" -Mode $ConfigLoadMode
    $updates = New-LoadStateUpdates -LoadResult $loadResult -ContentKind "configuration"
    Invoke-DevBranchEnterpriseAutoUpdateIfLoaded -State $state -LoadResult $loadResult -Updates $updates
    $updates["lastRefreshAt"] = (Get-Date).ToString("o")
    Add-VerificationStaleIfNeeded -State $state -Updates $updates -Reason "Development branch was refreshed from master." -CurrentCommit $loadResult.currentCommit
    Update-DevBranchState -State $state -Updates $updates
    $updatedState = Invoke-DevBranchMcpRestartAfterInfobaseLoad -State (Read-DevBranchState -Name $DevBranchName) -LoadResult $loadResult -Reason "refresh-dev-branch"
    Write-Host "Development branch refreshed from master: $($state.devBranch)"
    Write-BaseUpdateResult -State $updatedState -LoadResult $loadResult -Label "Development branch configuration"
    if ((Get-DevBranchKind -State $state) -eq "extension") {
        Write-Host "Extension files were not loaded during refresh. Run update-dev-branch-base when you need to update the extension in the branch infobase."
    }
    Sync-KiloItlCommandSurface
    Invoke-AiRules1cManagedMcpConfigReconcile -Operation "refresh-dev-branch MCP reconcile" | Out-Null
    $updatedState = Read-DevBranchState -Name $DevBranchName
    Write-DevBranchRunUserReport -State $updatedState -AdvisoryRoot $script:ProjectRoot -Operation refreshed -LoadResult $loadResult
}

function Dump-DevBranchExtension {
    $state = Read-DevBranchState -Name $DevBranchName
    Assert-DevelopmentBranchWorktreeContext -State $state -Operation "dump-dev-branch-extension"
    Assert-SingleManagedExtensionArtifact -State $state
    $dumpResult = Dump-ExtensionToFiles -State $state
    $source = Get-ConfigSourceFingerprint -ExportPath $dumpResult.exportPath
    $now = (Get-Date).ToString("o")
    $updates = @{
        extensionDumpPath = $dumpResult.exportPath
        extensionExportPath = $dumpResult.exportPath
        lastExtensionDumpAt = $now
        lastExtensionDumpPath = $dumpResult.exportPath
        lastExtensionDesignerFingerprint = $source.fingerprint
        lastExtensionDesignerLoadedAt = $now
        sourceFingerprint = $source.fingerprint
        loadReason = "extension-dump-seed"
        designerInvoked = $false
        enterpriseInvoked = $false
        extensionRecoveryStatus = "passed"
        extensionRecoveryReason = "transactional dump validated against the infobase slot"
        lastLogPath = $dumpResult.logPath
    }
    Add-VerificationStaleIfNeeded -State $state -Updates $updates -Reason "Extension files were dumped from the branch infobase." -Force
    Update-DevBranchState -State $state -Updates $updates
    $updatedState = Read-DevBranchState -Name $DevBranchName
    Sync-DevBranchContextToDotEnv -State $updatedState
    Write-Host "Extension dumped: $($dumpResult.exportPath)"
    Write-Host "Last 1C log: $($dumpResult.logPath)"
}

function Get-ConfigurationRootComment {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Root Configuration.xml was not found: $Path"
    }
    $document = New-Object System.Xml.XmlDocument
    $document.PreserveWhitespace = $true
    $document.Load($Path)
    $nodes = @($document.SelectNodes("//*[local-name()='Configuration']/*[local-name()='Properties']/*[local-name()='Comment']"))
    if ($nodes.Count -ne 1) {
        throw "Expected exactly one root Configuration/Properties/Comment node in '$Path'; found $($nodes.Count)."
    }
    return [string]$nodes[0].InnerText
}

function Prepare-ReleaseE2EOnDemandDependencies {
    Set-RunStage -Stage "release.ondemand-prepare" -Detail "Installing the workflow-pinned Vanessa Automation and on-demand MCP facade."
    $state = Read-DevBranchState -Name $DevBranchName
    Assert-DevelopmentBranchWorktreeContext -State $state -Operation "release-e2e-prepare-ondemand"
    Assert-DevBranchKind -State $state -Expected "configuration"

    if ((Get-DependencyMode) -ne "fresh") {
        throw "RELEASE_E2E_FRESH_DEPENDENCIES_REQUIRED: the dedicated stand must use fresh dependency mode."
    }
    $packageRoot = [IO.Path]::GetFullPath((Join-Path $script:Agent1cScriptRoot "..\..\..\.."))
    $templatePath = Join-Path $packageRoot "templates\dependency-lock.json"
    if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) {
        throw "RELEASE_E2E_WORKFLOW_PIN_MISSING: $templatePath"
    }
    $template = Read-Utf8Text -Path $templatePath | ConvertFrom-Json
    foreach ($dependencyName in @("vanessaAutomation", "itlOndemandMcp")) {
        $entry = Get-ConfigValueFromObject -Object $template -Path "dependencies.$dependencyName" -Default $null
        if ($null -eq $entry) {
            throw "RELEASE_E2E_WORKFLOW_PIN_MISSING: templates/dependency-lock.json has no $dependencyName entry."
        }
        Update-DependencyLockEntry -Name $dependencyName -Values (ConvertTo-Agent1cHashtable -Object $entry)
    }

    Install-VanessaAutomation
    Install-ItlOnDemandMcp | Out-Null
}

function Invoke-ReleaseE2EConfigRoundtrip {
    Set-RunStage -Stage "release.config-roundtrip" -Detail "Running the Release E2E configuration roundtrip."
    $state = Read-DevBranchState -Name $DevBranchName
    Assert-DevelopmentBranchWorktreeContext -State $state -Operation "release-e2e-config-roundtrip"
    Assert-DevBranchKind -State $state -Expected "configuration"

    $exportPath = Assert-ExportPathInsideProject (Get-ExportPath)
    $sourceConfigurationPath = Join-Path $exportPath "Configuration.xml"
    $sourceParentConfigurationsPath = Join-Path $exportPath "Ext\ParentConfigurations.bin"
    if (-not (Test-Path -LiteralPath $sourceParentConfigurationsPath -PathType Leaf)) {
        throw "Release E2E requires Ext/ParentConfigurations.bin in the configuration dump: $sourceParentConfigurationsPath"
    }
    $expectedComment = Get-ConfigurationRootComment -Path $sourceConfigurationPath

    $roundtripRoot = Resolve-ProjectPath ".agent-1c/release-e2e-roundtrip"
    New-Item -ItemType Directory -Force -Path $roundtripRoot | Out-Null
    $dumpPath = Join-Path $roundtripRoot ((Get-Date -Format "yyyyMMdd-HHmmss-fff") + "-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $dumpPath | Out-Null
    $evidencePath = Resolve-ProjectPath "build/test-results/release-e2e/config-roundtrip.json"
    $passed = $false
    try {
        Invoke-Designer `
            -InfoBasePath $state.devBranchInfoBasePath `
            -InfoBaseKind $state.infoBaseKind `
            -DesignerArgs @("/DumpConfigToFiles", $dumpPath, "-Format", "Hierarchical") | Out-Null

        $dumpedConfigurationPath = Join-Path $dumpPath "Configuration.xml"
        $dumpedParentConfigurationsPath = Join-Path $dumpPath "Ext\ParentConfigurations.bin"
        if (-not (Test-Path -LiteralPath $dumpedParentConfigurationsPath -PathType Leaf)) {
            throw "Roundtrip dump did not produce ParentConfigurations.bin: $dumpedParentConfigurationsPath"
        }
        $actualComment = Get-ConfigurationRootComment -Path $dumpedConfigurationPath
        if ($actualComment -cne $expectedComment) {
            throw "Partial root Configuration.xml roundtrip changed Comment. Expected '$expectedComment', actual '$actualComment'."
        }

        $evidence = [ordered]@{
            schemaVersion = 1
            checkedAt = [DateTime]::UtcNow.ToString("o")
            devBranchName = [string](Get-StateValue -State $state -Name "devBranchName" -Default "")
            expectedComment = $expectedComment
            actualComment = $actualComment
            sourceParentConfigurationsPath = $sourceParentConfigurationsPath
            parentConfigurationsPresentInDump = $true
            dumpedConfigurationSha256 = (Get-FileHash -LiteralPath $dumpedConfigurationPath -Algorithm SHA256).Hash.ToLowerInvariant()
            dumpedParentConfigurationsSha256 = (Get-FileHash -LiteralPath $dumpedParentConfigurationsPath -Algorithm SHA256).Hash.ToLowerInvariant()
            designerLogPath = $script:LastLogPath
        }
        Write-Utf8Text -Path $evidencePath -Value (($evidence | ConvertTo-Json -Depth 6) + [Environment]::NewLine)
        $passed = $true
        Write-Host "Release E2E partial Configuration.xml roundtrip passed: $evidencePath"
    } finally {
        if ($passed -and (Test-Path -LiteralPath $dumpPath -PathType Container)) {
            Remove-Item -LiteralPath $dumpPath -Recurse -Force
        }
    }
}

function Invoke-ReleaseE2EExtensionSmoke {
    Set-RunStage -Stage "release.extension-smoke" -Detail "Running the Release E2E extension lifecycle smoke."
    $state = Read-DevBranchState -Name $DevBranchName
    Assert-DevelopmentBranchWorktreeContext -State $state -Operation "release-e2e-extension-smoke"
    Assert-DevBranchKind -State $state -Expected "configuration"
    Assert-CleanGit
    Assert-ExtensionInitName -Name $ExtensionName | Out-Null
    Require-Value "ReleaseAiRulesSource" $ReleaseAiRulesSource | Out-Null
    $releaseAiRulesRoot = Resolve-Agent1cFullPath -Path $ReleaseAiRulesSource
    $releaseToolRoot = Join-Path $releaseAiRulesRoot "content\skills\1c-metadata-manage\tools\1c-cfe-manage\scripts"
    $releaseMetadataToolRoot = Join-Path $releaseAiRulesRoot "content\skills\1c-metadata-manage\tools"
    $releaseTools = [ordered]@{
        cfeInit = Join-Path $releaseToolRoot "cfe-init.ps1"
        cfeValidate = Join-Path $releaseToolRoot "cfe-validate.ps1"
        metaCompile = Join-Path $releaseMetadataToolRoot "1c-meta-compile\scripts\meta-compile.ps1"
        formAdd = Join-Path $releaseMetadataToolRoot "1c-form-scaffold\scripts\form-add.ps1"
        templateAdd = Join-Path $releaseMetadataToolRoot "1c-template-manage\scripts\add-template.ps1"
    }
    foreach ($requiredTool in $releaseTools.GetEnumerator()) {
        if (-not (Test-Path -LiteralPath $requiredTool.Value -PathType Leaf)) {
            throw "Release ai_rules source does not contain $($requiredTool.Key) at the expected controlled-fork path: $($requiredTool.Value)"
        }
    }
    $previousToolOverrideVariable = Get-Variable -Name ExtensionLifecycleToolRootOverride -Scope Script -ErrorAction SilentlyContinue
    $hadToolOverride = $null -ne $previousToolOverrideVariable
    $previousToolOverride = if ($hadToolOverride) { [string]$previousToolOverrideVariable.Value } else { "" }
    $script:ExtensionLifecycleToolRootOverride = $releaseToolRoot

    $statePath = [string](Get-StateValue -State $state -Name "statePath" -Default "")
    if (-not $statePath -or -not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        throw "Release extension smoke requires a persisted development branch state file."
    }
    $dotEnvPath = Join-Path $script:ProjectRoot ".dev.env"
    $originalStateBytes = [System.IO.File]::ReadAllBytes($statePath)
    $dotEnvExisted = Test-Path -LiteralPath $dotEnvPath -PathType Leaf
    $originalDotEnvBytes = if ($dotEnvExisted) { [System.IO.File]::ReadAllBytes($dotEnvPath) } else { $null }
    $originalStatus = @(& git -C $script:ProjectRoot status --porcelain)
    if ($originalStatus.Count -gt 0) {
        throw "Release extension smoke requires a clean worktree."
    }

    $smokeRoot = Assert-ExportPathInsideProject -ExportPath (".agent-1c/release-e2e-extension/" + [guid]::NewGuid().ToString("N"))
    $snapshotDir = Assert-ExportPathInsideProject -ExportPath ".agent-1c/snapshots"
    $snapshotPath = Join-Path $snapshotDir ("release-e2e-extension-{0}-{1}.dt" -f (ConvertTo-SafeName $ExtensionName), (Get-Date -Format "yyyyMMdd-HHmmss"))
    $cfePath = Join-Path $smokeRoot ($ExtensionName + ".cfe")
    $dumpPath = Assert-ExportPathInsideProject -ExportPath (Get-ExtensionInitDumpPath -Name $ExtensionName)
    $evidencePath = Resolve-ProjectPath "build/test-results/release-e2e/extension-smoke.json"
    $snapshotCreated = $false
    $databaseRestored = $false
    $roctupWasRunning = [bool](Get-RoctupMcpRuntimeInfo -State $state).processAlive
    $vanessaWasRunning = [bool](Get-VanessaMcpRuntimeInfo -State $state).processAlive
    $failure = $null
    $rollbackFailure = $null
    $emptyDumpSha256 = ""
    $cfeSha256 = ""
    $cfeDumpSha256 = ""
    $processorName = "ITLReleaseSmokeProcessor"
    $processorSynonym = "ITL Release Extension Form"
    $processorInitialFormSynonym = "ITL Release Extension Form Draft"
    $processorFormName = "MainForm"
    $processorTemplateName = "SmokeTemplate"
    $processorTemplateSynonym = "ITL Release Smoke Template"
    $reportName = "ITLReleaseSmokeReport"
    $reportSynonym = "ITL Release Smoke Report"
    $reportTemplateName = "MainDataCompositionSchema"
    $reportTemplateSynonym = "ITL Release Main Data Composition Schema"
    $formRegistrationCount = 0
    $templateRegistrationCount = 0
    $formContentPreserved = $false
    $formModulePreserved = $false
    $templateContentPreserved = $false
    $explicitMetadataUpdatesPassed = $false
    $authoredFileHashes = [ordered]@{}
    $extensionUiReportPath = ""
    $extensionUiJunitTests = 0

    function Invoke-ReleaseAiRulesTool {
        param(
            [Parameter(Mandatory = $true)][string]$ToolPath,
            [string[]]$Arguments = @()
        )
        & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $ToolPath @Arguments
        if ($LASTEXITCODE -ne 0) {
            throw "Controlled-fork release tool failed with exit code $LASTEXITCODE`: $ToolPath $($Arguments -join ' ')"
        }
    }

    function Get-ReleaseExtensionFixtureCounts {
        param([Parameter(Mandatory = $true)][string]$ExtensionDumpPath)

        $processorMetadataPath = Join-Path $ExtensionDumpPath ("DataProcessors\" + $processorName + ".xml")
        if (-not (Test-Path -LiteralPath $processorMetadataPath -PathType Leaf)) {
            throw "Release extension smoke processor metadata is missing: $processorMetadataPath"
        }
        $processorDocument = New-Object System.Xml.XmlDocument
        $processorDocument.Load($processorMetadataPath)
        $forms = @($processorDocument.SelectNodes("//*[local-name()='ChildObjects']/*[local-name()='Form' and text()='$processorFormName']"))
        $templates = @($processorDocument.SelectNodes("//*[local-name()='ChildObjects']/*[local-name()='Template' and text()='$processorTemplateName']"))
        return [pscustomobject]@{
            forms = $forms.Count
            templates = $templates.Count
        }
    }

    function Restore-ReleaseE2EExtensionLocalState {
        if (Test-Path -LiteralPath $dumpPath -PathType Container -ErrorAction SilentlyContinue) {
            Remove-Item -LiteralPath $dumpPath -Recurse -Force
        }
        [System.IO.File]::WriteAllBytes($statePath, $originalStateBytes)
        if ($dotEnvExisted) {
            [System.IO.File]::WriteAllBytes($dotEnvPath, $originalDotEnvBytes)
        } elseif (Test-Path -LiteralPath $dotEnvPath -PathType Leaf -ErrorAction SilentlyContinue) {
            Remove-Item -LiteralPath $dotEnvPath -Force
        }
    }

    function Enable-ReleaseE2EExtensionState {
        Restore-ReleaseE2EExtensionLocalState
        $currentState = Read-DevBranchState -Name $DevBranchName
        Update-DevBranchState -State $currentState -Updates @{ devBranchKind = "extension" }
    }

    try {
        New-Item -ItemType Directory -Force -Path $smokeRoot, $snapshotDir | Out-Null
        Stop-DevBranchRuntimeBeforeInfobaseMutation -State $state -Reason "Release E2E extension smoke"
        $state = Read-DevBranchState -Name $DevBranchName

        Invoke-Designer -InfoBasePath $state.devBranchInfoBasePath -InfoBaseKind $state.infoBaseKind -DesignerArgs @("/DumpIB", $snapshotPath) | Out-Null
        if (-not (Test-Path -LiteralPath $snapshotPath -PathType Leaf)) {
            throw "Release extension smoke snapshot was not created: $snapshotPath"
        }
        $snapshotCreated = $true

        Enable-ReleaseE2EExtensionState
        $script:ExtensionInitMode = "Empty"
        $script:ExtensionSourcePath = ""
        Init-DevBranchExtension
        $emptyState = Read-DevBranchState -Name $DevBranchName
        if ([string](Get-StateValue -State $emptyState -Name "extensionInitMode" -Default "") -ne "Empty") {
            throw "Release extension smoke did not record Empty initialization."
        }
        Assert-NormalizedExtensionDump -Path $dumpPath -Name $ExtensionName
        $emptyDumpSha256 = (Get-FileHash -LiteralPath (Join-Path $dumpPath "Configuration.xml") -Algorithm SHA256).Hash.ToLowerInvariant()

        $processorDefinitionPath = Join-Path $smokeRoot "processor.json"
        Write-Utf8Text -Path $processorDefinitionPath -Value (([ordered]@{
            type = "DataProcessor"
            name = $processorName
            synonym = $processorSynonym
        } | ConvertTo-Json -Depth 4) + [Environment]::NewLine)
        Invoke-ReleaseAiRulesTool -ToolPath $releaseTools.metaCompile -Arguments @(
            "-JsonPath", $processorDefinitionPath,
            "-OutputDir", $dumpPath
        )

        $processorMetadataPath = Join-Path $dumpPath ("DataProcessors\" + $processorName + ".xml")
        $processorObjectPath = Join-Path $dumpPath ("DataProcessors\" + $processorName)
        $formMetadataPath = Join-Path $processorObjectPath ("Forms\" + $processorFormName + ".xml")
        $formContentPath = Join-Path $processorObjectPath ("Forms\" + $processorFormName + "\Ext\Form.xml")
        $formModulePath = Join-Path $processorObjectPath ("Forms\" + $processorFormName + "\Ext\Form\Module.bsl")
        $templateMetadataPath = Join-Path $processorObjectPath ("Templates\" + $processorTemplateName + ".xml")
        $templateContentPath = Join-Path $processorObjectPath ("Templates\" + $processorTemplateName + "\Ext\Template.txt")

        Invoke-ReleaseAiRulesTool -ToolPath $releaseTools.formAdd -Arguments @(
            "-ObjectPath", $processorMetadataPath,
            "-FormName", $processorFormName,
            "-Synonym", $processorInitialFormSynonym,
            "-Purpose", "Object",
            "-SetDefault"
        )
        Invoke-ReleaseAiRulesTool -ToolPath $releaseTools.templateAdd -Arguments @(
            "-ObjectName", $processorName,
            "-TemplateName", $processorTemplateName,
            "-TemplateType", "Text",
            "-Synonym", ($processorTemplateSynonym + " Draft"),
            "-SrcDir", (Join-Path $dumpPath "DataProcessors")
        )
        foreach ($requiredFixturePath in @($formMetadataPath, $formContentPath, $formModulePath, $templateMetadataPath, $templateContentPath)) {
            if (-not (Test-Path -LiteralPath $requiredFixturePath -PathType Leaf)) {
                throw "Release extension smoke fixture file is missing: $requiredFixturePath"
            }
        }

        $formContent = [System.IO.File]::ReadAllText($formContentPath)
        Write-Utf8Text -Path $formContentPath -Value ($formContent.TrimEnd() + [Environment]::NewLine + "<!-- ITL authored form content -->" + [Environment]::NewLine)
        Write-Utf8Text -Path $formModulePath -Value ("&AtClient" + [Environment]::NewLine + "Procedure ITLReleaseAuthoredFormCode()" + [Environment]::NewLine + "EndProcedure" + [Environment]::NewLine)
        Write-Utf8Text -Path $templateContentPath -Value ("ITL authored template content" + [Environment]::NewLine)
        $authoredFileHashes.form = (Get-FileHash -LiteralPath $formContentPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $authoredFileHashes.module = (Get-FileHash -LiteralPath $formModulePath -Algorithm SHA256).Hash.ToLowerInvariant()
        $authoredFileHashes.template = (Get-FileHash -LiteralPath $templateContentPath -Algorithm SHA256).Hash.ToLowerInvariant()

        # A second call must update only explicitly requested metadata and must
        # preserve authored Form.xml, Module.bsl, and template bytes.
        Invoke-ReleaseAiRulesTool -ToolPath $releaseTools.formAdd -Arguments @(
            "-ObjectPath", $processorMetadataPath,
            "-FormName", $processorFormName,
            "-Synonym", $processorSynonym,
            "-Purpose", "Object",
            "-SetDefault"
        )
        Invoke-ReleaseAiRulesTool -ToolPath $releaseTools.templateAdd -Arguments @(
            "-ObjectName", $processorName,
            "-TemplateName", $processorTemplateName,
            "-TemplateType", "Text",
            "-Synonym", $processorTemplateSynonym,
            "-SrcDir", (Join-Path $dumpPath "DataProcessors")
        )
        $formContentPreserved = ((Get-FileHash -LiteralPath $formContentPath -Algorithm SHA256).Hash.ToLowerInvariant() -eq $authoredFileHashes.form)
        $formModulePreserved = ((Get-FileHash -LiteralPath $formModulePath -Algorithm SHA256).Hash.ToLowerInvariant() -eq $authoredFileHashes.module)
        $templateContentPreserved = ((Get-FileHash -LiteralPath $templateContentPath -Algorithm SHA256).Hash.ToLowerInvariant() -eq $authoredFileHashes.template)
        if (-not $formContentPreserved -or -not $formModulePreserved -or -not $templateContentPreserved) {
            throw "Release extension smoke specialized tools overwrote authored form or template content."
        }

        $reportDefinitionPath = Join-Path $smokeRoot "report.json"
        Write-Utf8Text -Path $reportDefinitionPath -Value (([ordered]@{
            type = "Report"
            name = $reportName
            synonym = $reportSynonym
        } | ConvertTo-Json -Depth 4) + [Environment]::NewLine)
        Invoke-ReleaseAiRulesTool -ToolPath $releaseTools.metaCompile -Arguments @(
            "-JsonPath", $reportDefinitionPath,
            "-OutputDir", $dumpPath
        )
        $reportMetadataPath = Join-Path $dumpPath ("Reports\" + $reportName + ".xml")
        $reportTemplateMetadataPath = Join-Path $dumpPath ("Reports\" + $reportName + "\Templates\" + $reportTemplateName + ".xml")
        $reportTemplateContentPath = Join-Path $dumpPath ("Reports\" + $reportName + "\Templates\" + $reportTemplateName + "\Ext\Template.xml")
        Invoke-ReleaseAiRulesTool -ToolPath $releaseTools.templateAdd -Arguments @(
            "-ObjectName", $reportName,
            "-TemplateName", $reportTemplateName,
            "-TemplateType", "DataCompositionSchema",
            "-Synonym", ($reportTemplateSynonym + " Draft"),
            "-SrcDir", (Join-Path $dumpPath "Reports"),
            "-SetMainSKD"
        )
        $reportTemplateContent = [System.IO.File]::ReadAllText($reportTemplateContentPath)
        Write-Utf8Text -Path $reportTemplateContentPath -Value ($reportTemplateContent.TrimEnd() + [Environment]::NewLine + "<!-- ITL authored DCS content -->" + [Environment]::NewLine)
        $authoredFileHashes.reportTemplate = (Get-FileHash -LiteralPath $reportTemplateContentPath -Algorithm SHA256).Hash.ToLowerInvariant()
        Invoke-ReleaseAiRulesTool -ToolPath $releaseTools.templateAdd -Arguments @(
            "-ObjectName", $reportName,
            "-TemplateName", $reportTemplateName,
            "-TemplateType", "DataCompositionSchema",
            "-Synonym", $reportTemplateSynonym,
            "-SrcDir", (Join-Path $dumpPath "Reports"),
            "-SetMainSKD"
        )
        $templateContentPreserved = $templateContentPreserved -and ((Get-FileHash -LiteralPath $reportTemplateContentPath -Algorithm SHA256).Hash.ToLowerInvariant() -eq $authoredFileHashes.reportTemplate)

        $processorDocument = New-Object System.Xml.XmlDocument
        $processorDocument.Load($processorMetadataPath)
        $formDocument = New-Object System.Xml.XmlDocument
        $formDocument.Load($formMetadataPath)
        $templateDocument = New-Object System.Xml.XmlDocument
        $templateDocument.Load($templateMetadataPath)
        $reportDocument = New-Object System.Xml.XmlDocument
        $reportDocument.Load($reportMetadataPath)
        $reportTemplateDocument = New-Object System.Xml.XmlDocument
        $reportTemplateDocument.Load($reportTemplateMetadataPath)
        $defaultForm = [string]$processorDocument.SelectSingleNode("//*[local-name()='DataProcessor']/*[local-name()='Properties']/*[local-name()='DefaultForm']").InnerText
        $formSynonym = [string]$formDocument.SelectSingleNode("//*[local-name()='Form']/*[local-name()='Properties']/*[local-name()='Synonym']/*[local-name()='item']/*[local-name()='content']").InnerText
        $templateSynonym = [string]$templateDocument.SelectSingleNode("//*[local-name()='Template']/*[local-name()='Properties']/*[local-name()='Synonym']/*[local-name()='item']/*[local-name()='content']").InnerText
        $mainDcs = [string]$reportDocument.SelectSingleNode("//*[local-name()='Report']/*[local-name()='Properties']/*[local-name()='MainDataCompositionSchema']").InnerText
        $reportTemplateActualSynonym = [string]$reportTemplateDocument.SelectSingleNode("//*[local-name()='Template']/*[local-name()='Properties']/*[local-name()='Synonym']/*[local-name()='item']/*[local-name()='content']").InnerText
        $explicitMetadataUpdatesPassed = $defaultForm -eq "DataProcessor.$processorName.Form.$processorFormName" -and
            $formSynonym -eq $processorSynonym -and $templateSynonym -eq $processorTemplateSynonym -and
            $mainDcs -eq "Report.$reportName.Template.$reportTemplateName" -and $reportTemplateActualSynonym -eq $reportTemplateSynonym
        if (-not $explicitMetadataUpdatesPassed -or -not $templateContentPreserved) {
            throw "Release extension smoke did not preserve authored DCS content or apply explicit Synonym/DefaultForm/MainDataCompositionSchema updates."
        }
        $fixtureCounts = Get-ReleaseExtensionFixtureCounts -ExtensionDumpPath $dumpPath
        $formRegistrationCount = $fixtureCounts.forms
        $templateRegistrationCount = $fixtureCounts.templates
        if ($formRegistrationCount -ne 1 -or $templateRegistrationCount -ne 1) {
            throw "Release extension smoke idempotency failed: forms=$formRegistrationCount, templates=$templateRegistrationCount."
        }
        Invoke-ReleaseAiRulesTool -ToolPath $releaseTools.cfeValidate -Arguments @("-ExtensionPath", $dumpPath)

        $extensionSource = Get-ConfigSourceFingerprint -ExportPath $dumpPath
        $extensionLoadResult = Load-ConfigFromFiles `
            -InfoBasePath $emptyState.devBranchInfoBasePath `
            -InfoBaseKind $emptyState.infoBaseKind `
            -State $emptyState `
            -ExportPath $dumpPath `
            -ContentKind "extension" `
            -ExtensionName $ExtensionName `
            -Mode "Full"
        $extensionUpdates = New-LoadStateUpdates -LoadResult $extensionLoadResult -ContentKind "extension"
        Invoke-DevBranchEnterpriseAutoUpdateIfLoaded -State $emptyState -LoadResult $extensionLoadResult -Updates $extensionUpdates
        $extensionUpdates["lastExtensionDesignerFingerprint"] = $extensionSource.fingerprint
        Update-DevBranchState -State $emptyState -Updates $extensionUpdates

        # This feature is intentionally decoded at runtime so Windows PowerShell 5.1
        # cannot corrupt Russian Gherkin in this UTF-8-without-BOM source file.
        $extensionUiFeaturePath = Join-Path $smokeRoot "extension-form.feature"
        $extensionUiFeatureBase64 = 'I2xhbmd1YWdlOiBydQoKQGl0bF9yZWxlYXNlX2V4dGVuc2lvbl91aQrQpNGD0L3QutGG0LjQvtC90LDQuzog0KTQvtGA0LzQsCDQvtCx0YDQsNCx0L7RgtC60Lgg0YDQsNGB0YjQuNGA0LXQvdC40Y8KCtCa0L7QvdGC0LXQutGB0YI6CgnQlNCw0L3QviDQryDQt9Cw0L/Rg9GB0LrQsNGOINGB0YbQtdC90LDRgNC40Lkg0L7RgtC60YDRi9GC0LjRjyBUZXN0Q2xpZW50INC40LvQuCDQv9C+0LTQutC70Y7Rh9Cw0Y4g0YPQttC1INGB0YPRidC10YHRgtCy0YPRjtGJ0LjQuQoJ0Jgg0Y8g0LfQsNC60YDRi9Cy0LDRjiDQstGB0LUg0L7QutC90LAg0LrQu9C40LXQvdGC0YHQutC+0LPQviDQv9GA0LjQu9C+0LbQtdC90LjRjwoK0KHRhtC10L3QsNGA0LjQuTog0KTQvtGA0LzQsCDRgNCw0YHRiNC40YDQtdC90LjRjyDQvtGC0LrRgNGL0LLQsNC10YLRgdGPINCyIFRlc3RDbGllbnQKCdCYINCvINC+0YLQutGA0YvQstCw0Y4g0L3QsNCy0LjQs9Cw0YbQuNC+0L3QvdGD0Y4g0YHRgdGL0LvQutGDICJlMWNpYi9hcHAv0J7QsdGA0LDQsdC+0YLQutCwLklUTFJlbGVhc2VTbW9rZVByb2Nlc3NvciIKCdCV0YHQu9C4INC/0L7Rj9Cy0LjQu9C+0YHRjCDQv9GA0LXQtNGD0L/RgNC10LbQtNC10L3QuNC1INCi0L7Qs9C00LAKCQnQotC+0LPQtNCwINGPINCy0YvQt9GL0LLQsNGOINC40YHQutC70Y7Rh9C10L3QuNC1ICLQndC1INGD0LTQsNC70L7RgdGMINC+0YLQutGA0YvRgtGMINGE0L7RgNC80YMg0L7QsdGA0LDQsdC+0YLQutC4INGA0LDRgdGI0LjRgNC10L3QuNGPIgoJ0JXRgdC70Lgg0LjQvNGPINGC0LXQutGD0YnQtdC5INGE0L7RgNC80YsgIkVycm9yV2luZG93IiDQotC+0LPQtNCwCgkJ0KLQvtCz0LTQsCDRjyDQstGL0LfRi9Cy0LDRjiDQuNGB0LrQu9GO0YfQtdC90LjQtSAi0J7RgtC60YDRi9C70LDRgdGMINGE0L7RgNC80LAg0L7RiNC40LHQutC4INCy0LzQtdGB0YLQviDRhNC+0YDQvNGLINGA0LDRgdGI0LjRgNC10L3QuNGPIgoJ0KLQvtCz0LTQsCDQvtGC0LrRgNGL0LvQvtGB0Ywg0L7QutC90L4gIipJVEwgUmVsZWFzZSBFeHRlbnNpb24gRm9ybSoi'
        [System.IO.File]::WriteAllBytes($extensionUiFeaturePath, [System.Convert]::FromBase64String($extensionUiFeatureBase64))
        $previousVanessaFeaturePath = [string]$script:VanessaFeaturePath
        $previousVanessaFilterTags = [string]$script:VanessaFilterTags
        try {
            $script:VanessaFeaturePath = $extensionUiFeaturePath
            $script:VanessaFilterTags = "@itl_release_extension_ui"
            Run-DevBranchTests
        } finally {
            $script:VanessaFeaturePath = $previousVanessaFeaturePath
            $script:VanessaFilterTags = $previousVanessaFilterTags
        }
        $extensionUiState = Read-DevBranchState -Name $DevBranchName
        $extensionUiReportPath = [string](Get-StateValue -State $extensionUiState -Name "lastVanessaReportPath" -Default "")
        $extensionUiJunit = Get-VanessaJunitSummary -RunDirectory $extensionUiReportPath
        $extensionUiJunitTests = $extensionUiJunit.tests
        if (-not $extensionUiJunit.found -or $extensionUiJunitTests -ne 1 -or ($extensionUiJunit.failures + $extensionUiJunit.errors) -ne 0) {
            throw "Release extension UI smoke must produce one passing TestClient JUnit test; tests=$extensionUiJunitTests, failures=$($extensionUiJunit.failures), errors=$($extensionUiJunit.errors)."
        }

        Invoke-Designer -InfoBasePath $emptyState.devBranchInfoBasePath -InfoBaseKind $emptyState.infoBaseKind -DesignerArgs @(
            "/DumpCfg", $cfePath, "-Extension", $ExtensionName
        ) | Out-Null
        if (-not (Test-Path -LiteralPath $cfePath -PathType Leaf) -or (Get-Item -LiteralPath $cfePath).Length -le 0) {
            throw "Release extension smoke did not create a non-empty CFE: $cfePath"
        }
        $cfeSha256 = (Get-FileHash -LiteralPath $cfePath -Algorithm SHA256).Hash.ToLowerInvariant()

        Restore-DevBranchInfobaseFromSnapshot -State $emptyState -SnapshotPath $snapshotPath -Reason "Release E2E Empty extension restore"
        $databaseRestored = $true
        Enable-ReleaseE2EExtensionState
        $databaseRestored = $false
        $script:ExtensionInitMode = "Cfe"
        $script:ExtensionSourcePath = $cfePath
        Init-DevBranchExtension
        $cfeState = Read-DevBranchState -Name $DevBranchName
        if ([string](Get-StateValue -State $cfeState -Name "extensionInitMode" -Default "") -ne "Cfe") {
            throw "Release extension smoke did not record Cfe initialization."
        }
        Assert-NormalizedExtensionDump -Path $dumpPath -Name $ExtensionName
        $cfeDumpSha256 = (Get-FileHash -LiteralPath (Join-Path $dumpPath "Configuration.xml") -Algorithm SHA256).Hash.ToLowerInvariant()
        Invoke-ReleaseAiRulesTool -ToolPath $releaseTools.cfeValidate -Arguments @("-ExtensionPath", $dumpPath)
        $roundtripFixtureCounts = Get-ReleaseExtensionFixtureCounts -ExtensionDumpPath $dumpPath
        if ($roundtripFixtureCounts.forms -ne 1 -or $roundtripFixtureCounts.templates -ne 1) {
            throw "Release extension CFE roundtrip changed specialized child registrations: forms=$($roundtripFixtureCounts.forms), templates=$($roundtripFixtureCounts.templates)."
        }

        Restore-DevBranchInfobaseFromSnapshot -State $cfeState -SnapshotPath $snapshotPath -Reason "Release E2E CFE restore"
        $databaseRestored = $true
        Restore-ReleaseE2EExtensionLocalState
        if (Test-Path -LiteralPath $smokeRoot -PathType Container -ErrorAction SilentlyContinue) {
            Remove-Item -LiteralPath $smokeRoot -Recurse -Force
        }

        if (@(& git -C $script:ProjectRoot status --porcelain).Count -ne 0) {
            throw "Release extension smoke left the worktree dirty."
        }
        $evidence = [ordered]@{
            schemaVersion = 2
            checkedAt = [DateTime]::UtcNow.ToString("o")
            devBranchName = $DevBranchName
            extensionName = $ExtensionName
            emptyInitialized = $true
            cfeCreated = $true
            cfeInitialized = $true
            databaseRestored = $true
            repeatedFormOperationsIdempotent = ($formRegistrationCount -eq 1)
            repeatedTemplateOperationsIdempotent = ($templateRegistrationCount -eq 1)
            formContentPreserved = $formContentPreserved
            formModulePreserved = $formModulePreserved
            templateContentPreserved = $templateContentPreserved
            explicitMetadataUpdatesPassed = $explicitMetadataUpdatesPassed
            formRegistrationCount = $formRegistrationCount
            templateRegistrationCount = $templateRegistrationCount
            extensionUiTestClientPassed = ($extensionUiJunitTests -eq 1)
            extensionUiJunitTests = $extensionUiJunitTests
            extensionUiReportPath = $extensionUiReportPath
            emptyDumpConfigurationSha256 = $emptyDumpSha256
            cfeSha256 = $cfeSha256
            cfeDumpConfigurationSha256 = $cfeDumpSha256
            authoredFileSha256 = $authoredFileHashes
        }
        Write-Utf8Text -Path $evidencePath -Value (($evidence | ConvertTo-Json -Depth 6) + [Environment]::NewLine)
        Write-Host "Release E2E extension Empty/CFE smoke passed: $evidencePath"
    } catch {
        $failure = $_.Exception.Message
    } finally {
        if ($snapshotCreated -and -not $databaseRestored) {
            try {
                $rollbackState = Read-DevBranchState -Name $DevBranchName
                Restore-DevBranchInfobaseFromSnapshot -State $rollbackState -SnapshotPath $snapshotPath -Reason "Release E2E extension smoke rollback"
                $databaseRestored = $true
            } catch {
                $rollbackFailure = $_.Exception.Message
            }
        }
        try { Restore-ReleaseE2EExtensionLocalState } catch {
            if (-not $rollbackFailure) { $rollbackFailure = $_.Exception.Message }
        }
        try {
            Restore-ExtensionInitMcpRuntime -State (Read-DevBranchState -Name $DevBranchName) -RoctupWasRunning $roctupWasRunning -VanessaWasRunning $vanessaWasRunning
        } catch {
            if (-not $rollbackFailure) { $rollbackFailure = $_.Exception.Message }
        }
        if (Test-Path -LiteralPath $smokeRoot -PathType Container -ErrorAction SilentlyContinue) {
            Remove-Item -LiteralPath $smokeRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($hadToolOverride) {
            $script:ExtensionLifecycleToolRootOverride = $previousToolOverride
        } else {
            Remove-Variable -Name ExtensionLifecycleToolRootOverride -Scope Script -ErrorAction SilentlyContinue
        }
    }

    if ($failure) {
        if ($rollbackFailure) {
            throw "Release extension smoke failed: $failure Rollback also failed: $rollbackFailure Snapshot retained: $snapshotPath"
        }
        throw "Release extension smoke failed and the disposable infobase was restored: $failure"
    }
    if ($rollbackFailure) {
        throw "Release extension smoke passed but cleanup failed: $rollbackFailure Snapshot retained: $snapshotPath"
    }
}

function Show-WorkflowStatus {
    Write-Section "ITL status"
    Write-Host "Long lifecycle actions may run 1C Designer/Enterprise; agent shell timeout_ms must be >= 3900000 by default and exceed the configured Designer timeout."
    Write-DesignerMemoryLimitStatusLine
    Write-Agent1cLifecycleOperationStatusLines

    if (-not (Test-Path -LiteralPath (Join-Path $script:ProjectRoot ".git"))) {
        Write-Host "Git repository: missing"
        return
    }

    $currentBranch = Get-CurrentBranch
    $currentCommit = ""
    try {
        $currentCommit = Get-CurrentCommit
    } catch {
        $currentCommit = "<none>"
    }
    $dirty = Test-GitHasChanges

    Write-Host "Git branch: $(if ($currentBranch) { $currentBranch } else { '<none>' })"
    Write-Host "Git commit: $currentCommit"
    Write-Host "Git worktree: $(if ($dirty) { 'dirty' } else { 'clean' })"
    Write-WorkflowPackageStatusLines
    Write-AiRules1cStatusLines
    Write-ItlOnDemandMcpStatusLines
    Write-KiloBrowserAutomationSummary -ProjectRoot $script:ProjectRoot

    if ($currentBranch -notlike "itldev/*") {
        Write-Vibecoding1cMcpStatusLines
        Write-Host "Current development branch: none"
        $worktreeStates = @()
        foreach ($file in Get-DevBranchStateFiles) {
            try {
                $state = Read-DevBranchStateFile -Path $file.FullName
                if (-not (Get-StateValue -State $state -Name "closedAt")) {
                    $worktreeStates += $state
                }
            } catch {
            }
        }
        if ($worktreeStates.Count -gt 0) {
            Write-Host "Active development worktrees: $($worktreeStates.Count)"
            foreach ($state in ($worktreeStates | Sort-Object @{ Expression = { Get-StateValue -State $_ -Name "createdAt" -Default "" } }, @{ Expression = { Get-StateValue -State $_ -Name "devBranchName" -Default "" } })) {
                $name = Get-StateValue -State $state -Name "devBranchName" -Default (Get-StateValue -State $state -Name "safeDevBranchName" -Default "<unknown>")
                Write-Host "  $name"
                $worktreePath = Get-StateValue -State $state -Name "worktreePath" -Default ""
                if ($worktreePath) {
                    Write-Host "    Worktree: $worktreePath"
                }
                Write-DevBranchInitializationStatusLines -State $state -Indent "    "
                Write-VanessaTestStatusLines -State $state -Indent "    "
                Write-DataMcpStatusLines -State $state -Indent "    "
            }
        }
        return
    }

    $state = Read-DevBranchState -Name ""
    $verification = Get-VerificationState -State $state
    $kind = Get-DevBranchKind -State $state

    Write-Host "Development branch: $($state.devBranch)"
    $worktreePath = Get-StateValue -State $state -Name "worktreePath" -Default ""
    if ($worktreePath) {
        Write-Host "Worktree: $worktreePath"
    }
    Write-DevBranchInitializationStatusLines -State $state
    $mainWorktreePath = Get-StateValue -State $state -Name "mainWorktreePath" -Default ""
    if ($mainWorktreePath) {
        Write-Host "Main worktree: $mainWorktreePath"
    }
    $safeDevBranchName = Get-StateValue -State $state -Name "safeDevBranchName" -Default "<unknown>"
    Write-Host "Development branch name: $(Get-StateValue -State $state -Name 'devBranchName' -Default $safeDevBranchName)"
    Write-Host "Type: $kind"
    if ($kind -eq "extension") {
        Write-Host "Extension: $(Get-StateValue -State $state -Name 'extensionName' -Default '<not set>')"
        $extensionFiles = Get-StateValue -State $state -Name "extensionDumpPath" -Default (Get-StateValue -State $state -Name "extensionExportPath" -Default "<not set>")
        Write-Host "Extension files: $extensionFiles"
    }
    Write-Host "Infobase: $($state.devBranchInfoBasePath)"
    $publicationUrl = Get-StateValue -State $state -Name "publicationUrl" -Default ""
    if ($publicationUrl) {
        Write-Host "Publication URL: $publicationUrl"
    }
    Write-DataMcpStatusLines -State $state
    Write-VanessaTestStatusLines -State $state
    Write-Vibecoding1cMcpStatusLines
    Write-Host "Last config base update: $(Get-StateValue -State $state -Name 'lastConfigBaseUpdateAt' -Default '<never>')"
    if ($kind -eq "extension") {
        Write-Host "Last extension base update: $(Get-StateValue -State $state -Name 'lastExtensionBaseUpdateAt' -Default '<never>')"
    }
    Write-Host "Last Enterprise auto-update: $(Get-StateValue -State $state -Name 'lastEnterpriseAutoUpdateAt' -Default '<never>')"
    $autoUpdateLog = Get-StateValue -State $state -Name "lastEnterpriseAutoUpdateLogPath" -Default ""
    if ($autoUpdateLog) {
        Write-Host "Last Enterprise auto-update log: $autoUpdateLog"
    }
    Write-Host "Last refresh: $(Get-StateValue -State $state -Name 'lastRefreshAt' -Default '<never>')"
    Write-Host "Verification status: $($verification.effectiveStatus)"
    Write-Host "Verification fresh passed: $($verification.isFreshPassed)"
    if ($verification.verifiedAt) {
        Write-Host "Last verified at: $($verification.verifiedAt)"
    }
    if ($verification.verifiedCommit) {
        Write-Host "Last verified commit: $($verification.verifiedCommit)"
    }
    if ($verification.reportPath) {
        Write-Host "Last verification report: $($verification.reportPath)"
    }
    if ($verification.reason) {
        Write-Host "Last verification reason: $($verification.reason)"
    }
    Write-Host "Last result: $(Get-StateValue -State $state -Name 'lastResultPath' -Default '<none>')"
    Write-Host "Final result: $(Get-StateValue -State $state -Name 'finalResultPath' -Default '<none>')"
    $override = Get-StateValue -State $state -Name "lastUnverifiedOverrideAt" -Default ""
    if ($override) {
        Write-Host "Last unverified override: $override ($(Get-StateValue -State $state -Name 'lastUnverifiedOverrideOperation' -Default 'unknown'))"
    }
}

function Invoke-DevBranchCheck {
    $trigger = $(if ($VerificationTrigger) { $VerificationTrigger } else { "command" })
    $explicit = $(if ($ExplicitVerificationComponent) { @($ExplicitVerificationComponent) } else { @() })
    $state = Read-DevBranchState -Name $DevBranchName
    Invoke-DevBranchVanessaRuntimeRelease -State $state -Reason "check-dev-branch preflight" | Out-Null
    $mcpRuntime = Get-VanessaMcpRuntimeInfo -State $state
    if ($mcpRuntime.processAlive) {
        Stop-VanessaAuthoringMcpForState -State $state -Quiet | Out-Null
    }
    Assert-VanessaAuthoringPreflight -Trigger $trigger -ExplicitComponents $explicit
    Use-ItlVerificationRepairAttempt
    Update-DevBranchBase
    Invoke-ItlVerificationCycle -Trigger $trigger -ExplicitComponents $explicit
    Complete-ItlVerificationRepairSession
}

function Check-DevBranch {
    $state = Read-DevBranchState -Name $DevBranchName
    Assert-DevBranchExtensionInitialized -State $state -Operation "check-dev-branch"
    Assert-SingleManagedExtensionArtifact -State $state
    Invoke-DevBranchCheck
}

function Save-ReleaseE2EInfobaseSnapshot {
    Set-RunStage -Stage "release.snapshot" -Detail "Creating the Release E2E infobase snapshot."
    $state = Read-DevBranchState -Name $DevBranchName
    Assert-DevelopmentBranchWorktreeContext -State $state -Operation "release-e2e-snapshot"
    Assert-DevBranchKind -State $state -Expected "configuration"
    Require-Value "ReleaseSnapshotPath" $ReleaseSnapshotPath | Out-Null
    $snapshotPath = Assert-ExportPathInsideProject -ExportPath $ReleaseSnapshotPath
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $snapshotPath) | Out-Null
    Stop-DevBranchRuntimeBeforeInfobaseMutation -State $state -Reason "Release E2E checkpoint snapshot"
    Invoke-Designer -InfoBasePath $state.devBranchInfoBasePath -InfoBaseKind $state.infoBaseKind -DesignerArgs @("/DumpIB", $snapshotPath) | Out-Null
    if (-not (Test-Path -LiteralPath $snapshotPath -PathType Leaf) -or (Get-Item -LiteralPath $snapshotPath).Length -le 0) {
        throw "Release E2E snapshot was not created: $snapshotPath"
    }
    Write-Host "Release E2E snapshot: $snapshotPath"
    Write-Host "SHA256: $((Get-FileHash -LiteralPath $snapshotPath -Algorithm SHA256).Hash.ToLowerInvariant())"
}

function Restore-ReleaseE2EInfobaseSnapshot {
    Set-RunStage -Stage "release.restore" -Detail "Restoring the Release E2E infobase snapshot."
    $state = Read-DevBranchState -Name $DevBranchName
    Assert-DevelopmentBranchWorktreeContext -State $state -Operation "release-e2e-restore"
    Assert-DevBranchKind -State $state -Expected "configuration"
    Require-Value "ReleaseSnapshotPath" $ReleaseSnapshotPath | Out-Null
    $snapshotPath = Assert-ExportPathInsideProject -ExportPath $ReleaseSnapshotPath
    if (-not (Test-Path -LiteralPath $snapshotPath -PathType Leaf)) { throw "Release E2E snapshot is missing: $snapshotPath" }
    Restore-DevBranchInfobaseFromSnapshot -State $state -SnapshotPath $snapshotPath -Reason "Release E2E checkpoint restore"
    Update-DevBranchState -State $state -Updates @{
        lastConfigDesignerFingerprint = ""
        lastConfigDesignerLoadedAt = ""
        lastExtensionDesignerFingerprint = ""
        lastExtensionDesignerLoadedAt = ""
        sourceFingerprint = ""
        loadReason = "release-e2e-restore-invalidated"
        designerInvoked = $false
        enterpriseInvoked = $false
        enterpriseNormalizationStatus = "pending"
        enterpriseNormalizationReason = "release-e2e-restore"
        enterpriseNormalizationError = ""
    }
    Sync-DevBranchContextToDotEnv -State (Read-DevBranchState -Name $DevBranchName) -AllowIncompleteExtension
    Write-Host "Release E2E snapshot restored: $snapshotPath"
}

function Verify-DevBranch {
    $state = Read-DevBranchState -Name $DevBranchName
    Assert-DevBranchExtensionInitialized -State $state -Operation "verify-dev-branch"
    Assert-SingleManagedExtensionArtifact -State $state
    $savedTrigger = $VerificationTrigger
    try {
        if (-not $VerificationTrigger) { $script:VerificationTrigger = "repair" }
        Invoke-DevBranchCheck
    } finally {
        $script:VerificationTrigger = $savedTrigger
    }
}

function Export-DevBranchResult {
    $state = Read-DevBranchState -Name $DevBranchName
    Assert-DevelopmentBranchWorktreeContext -State $state -Operation "export-dev-branch-result"
    Assert-DevBranchExtensionInitialized -State $state -Operation "export-dev-branch-result"
    Assert-SingleManagedExtensionArtifact -State $state
    Assert-CleanGit
    Sync-DevBranchContextToDotEnv -State $state
    $currentBranch = Get-CurrentBranch
    if ($currentBranch -ne $state.devBranch) {
        Invoke-Git @("checkout", $state.devBranch)
    }
    $kind = Get-DevBranchKind -State $state
    if ($kind -eq "extension") {
        $extensionName = Require-DevBranchExtensionName -State $state
        $extensionExportPath = Assert-ExtensionFilesReady -State $state
        $loadResult = Load-ConfigFromFiles -InfoBasePath $state.devBranchInfoBasePath -InfoBaseKind $state.infoBaseKind -State $state -ExportPath $extensionExportPath -ContentKind "extension" -ExtensionName $extensionName -Mode $ConfigLoadMode
    } else {
        $loadResult = Load-ConfigFromFiles -InfoBasePath $state.devBranchInfoBasePath -InfoBaseKind $state.infoBaseKind -State $state -ExportPath (Get-ExportPath) -ContentKind "configuration" -Mode $ConfigLoadMode
    }
    $devBranchCommit = Get-CurrentCommit
    $masterCommit = Get-GitCommitOrEmpty (Get-MasterBranch)
    $updates = New-LoadStateUpdates -LoadResult $loadResult -ContentKind $kind
    Invoke-DevBranchEnterpriseAutoUpdateIfLoaded -State $state -LoadResult $loadResult -Updates $updates
    Add-VerificationStaleIfNeeded -State $state -Updates $updates -Reason "Development branch base was updated before result export." -CurrentCommit $loadResult.currentCommit
    Update-DevBranchState -State $state -Updates $updates
    $state = Invoke-DevBranchMcpRestartAfterInfobaseLoad -State (Read-DevBranchState -Name $DevBranchName) -LoadResult $loadResult -Reason "result export base update"
    $state = Read-DevBranchState -Name $DevBranchName
    $unverifiedOverride = Confirm-UnverifiedProceed -State $state -Operation "export-dev-branch-result" -Allow:$AllowUnverifiedResult

    Assert-DevBranchToolArtifactExportGuard -State $state -ContentKind $kind
    $resultPath = Export-DevBranchResultFile -State $state -InfoBasePath $state.devBranchInfoBasePath -InfoBaseKind $state.infoBaseKind -ContentKind $kind
    Assert-DevBranchToolArtifactExportGuard -State $state -ContentKind $kind -ResultPath $resultPath
    $resultKind = $(if ($kind -eq "extension") { "cfe" } else { "cf" })
    $manifestPath = New-ResultManifest `
        -State $state `
        -ResultPath $resultPath `
        -ResultKind $resultKind `
        -Operation "export-dev-branch-result" `
        -MasterCommit $masterCommit `
        -DevBranchCommit $devBranchCommit `
        -UnverifiedOverride ([bool]$unverifiedOverride)
    $updates = @{}
    $updates["lastResultPath"] = $resultPath
    $updates["lastResultKind"] = $resultKind
    $updates["lastResultManifestPath"] = $manifestPath
    $updates["lastResultAt"] = (Get-Date).ToString("o")
    $updates["lastLogPath"] = $script:LastLogPath
    if ($unverifiedOverride) {
        $updates["lastUnverifiedOverrideAt"] = (Get-Date).ToString("o")
        $updates["lastUnverifiedOverrideOperation"] = "export-dev-branch-result"
        $updates["lastUnverifiedResultPath"] = $resultPath
    }
    Update-DevBranchState -State $state -Updates $updates
    Write-Host "Branch: $($state.devBranch)"
    Write-Host "Development branch commit: $devBranchCommit"
    Write-Host "Result saved: $resultPath"
    Write-Host "Result manifest: $manifestPath"
    Write-Host "Last 1C log: $script:LastLogPath"
}

function Close-DevBranch {
    $state = Read-DevBranchState -Name $DevBranchName
    Assert-DevelopmentBranchWorktreeContext -State $state -Operation "close-dev-branch"
    Assert-DevBranchExtensionInitialized -State $state -Operation "close-dev-branch"
    Assert-SingleManagedExtensionArtifact -State $state
    Stop-DevBranchRuntimeBeforeInfobaseMutation -State $state -Reason "close-dev-branch"
    $state = Read-DevBranchState -Name $DevBranchName
    Release-ItlManagedPortAllocationsForState -State $state
    Sync-DevBranchContextToDotEnv -State $state

    if ($LifecyclePhase -ne "post-merge") {
        Set-RunStage -Stage "close.master" -Detail "Synchronizing master before closing the development branch."
        Assert-CleanGit
        Sync-Master
        if ((Get-CurrentBranch) -ne $state.devBranch) {
            Invoke-Git @("checkout", $state.devBranch)
        }
        Set-RunStage -Stage "close.merge" -Detail "Merging master into the development branch before close."
        Invoke-Git @("merge", (Get-MasterBranch))
        Restart-Agent1cAfterDevBranchMerge -Operation "close-dev-branch"
    }

    Set-RunStage -Stage "close.load" -Detail "Updating the branch infobase before result export."
    Sync-DevBranchContextToDotEnv -State $state

    $kind = Get-DevBranchKind -State $state
    $configLoadResult = Load-ConfigFromFiles -InfoBasePath $state.devBranchInfoBasePath -InfoBaseKind $state.infoBaseKind -State $state -ExportPath (Get-ExportPath) -ContentKind "configuration" -Mode $ConfigLoadMode
    $updates = New-LoadStateUpdates -LoadResult $configLoadResult -ContentKind "configuration"
    Invoke-DevBranchEnterpriseAutoUpdateIfLoaded -State $state -LoadResult $configLoadResult -Updates $updates
    Add-VerificationStaleIfNeeded -State $state -Updates $updates -Reason "Development branch was refreshed and updated before close." -CurrentCommit $configLoadResult.currentCommit
    if ($kind -eq "extension") {
        $extensionName = Require-DevBranchExtensionName -State $state
        $extensionExportPath = Assert-ExtensionFilesReady -State $state
        $extensionLoadResult = Load-ConfigFromFiles -InfoBasePath $state.devBranchInfoBasePath -InfoBaseKind $state.infoBaseKind -State $state -ExportPath $extensionExportPath -ContentKind "extension" -ExtensionName $extensionName -Mode $ConfigLoadMode
        $extensionUpdates = New-LoadStateUpdates -LoadResult $extensionLoadResult -ContentKind "extension"
        Invoke-DevBranchEnterpriseAutoUpdateIfLoaded -State $state -LoadResult $extensionLoadResult -Updates $extensionUpdates
        foreach ($key in $extensionUpdates.Keys) {
            $updates[$key] = $extensionUpdates[$key]
        }
        Add-VerificationStaleIfNeeded -State $state -Updates $updates -Reason "Development branch extension was updated before close." -CurrentCommit $extensionLoadResult.currentCommit
    }
    Update-DevBranchState -State $state -Updates $updates
    $state = Read-DevBranchState -Name $DevBranchName
    $unverifiedOverride = Confirm-UnverifiedProceed -State $state -Operation "close-dev-branch" -Allow:$AllowUnverifiedClose

    Assert-DevBranchToolArtifactExportGuard -State $state -ContentKind $kind
    $resultPath = Export-DevBranchResultFile -State $state -InfoBasePath $state.devBranchInfoBasePath -InfoBaseKind $state.infoBaseKind -ContentKind $kind
    Assert-DevBranchToolArtifactExportGuard -State $state -ContentKind $kind -ResultPath $resultPath

    $masterBranch = Get-MasterBranch
    $masterCommit = (Get-GitOutput @("rev-parse", $masterBranch)).Trim()
    $devBranchCommit = Get-CurrentCommit
    $resultKind = $(if ($kind -eq "extension") { "cfe" } else { "cf" })
    $manifestPath = New-ResultManifest `
        -State $state `
        -ResultPath $resultPath `
        -ResultKind $resultKind `
        -Operation "close-dev-branch" `
        -MasterCommit $masterCommit `
        -DevBranchCommit $devBranchCommit `
        -UnverifiedOverride ([bool]$unverifiedOverride)

    $updates["closedAt"] = (Get-Date).ToString("o")
    $updates["finalResultPath"] = $resultPath
    $updates["finalResultKind"] = $resultKind
    $updates["finalResultManifestPath"] = $manifestPath
    $updates["lastLogPath"] = $script:LastLogPath
    if ($unverifiedOverride) {
        $updates["lastUnverifiedOverrideAt"] = (Get-Date).ToString("o")
        $updates["lastUnverifiedOverrideOperation"] = "close-dev-branch"
        $updates["lastUnverifiedResultPath"] = $resultPath
    }
    Update-DevBranchState -State $state -Updates $updates

    Write-Host "Branch: $($state.devBranch)"
    Write-Host "Master commit: $masterCommit"
    Write-Host "Development branch commit: $devBranchCommit"
    Write-Host "Result saved: $resultPath"
    Write-Host "Result manifest: $manifestPath"
    Write-Host "Last 1C log: $script:LastLogPath"
    if ($state.publicationUrl) {
        Write-Host "Publication URL: $($state.publicationUrl)"
    }

    if (Test-DevBranchStateUsesWorktree -State $state) {
        Clear-DevBranchContext
        $mainWorktreePath = Get-StateValue -State $state -Name "mainWorktreePath" -Default ""
        Write-Host "Development branch worktree remains on closed branch: $($state.devBranch)"
        if ($mainWorktreePath) {
            Write-Host "Main project worktree stays on master: $mainWorktreePath"
        }
    } else {
        Invoke-Git @("checkout", $masterBranch)
        Clear-DevBranchContext
        $currentCommit = Get-CurrentCommit
        Write-Host "Switched to master branch: $masterBranch"
        Write-Host "Current commit: $currentCommit"
    }
}

function List-DevBranches {
    Write-Section "Development branches"

    $currentBranch = ""
    if (Test-Path -LiteralPath (Join-Path $script:ProjectRoot ".git")) {
        $currentBranch = Get-CurrentBranch
    }

    $currentDevBranch = "none"
    if ($currentBranch -like "itldev/*") {
        $currentDevBranch = $currentBranch.Substring("itldev/".Length)
    }

    Write-Host "Current branch: $(if ($currentBranch) { $currentBranch } else { '<none>' })"
    Write-Host "Current development branch: $currentDevBranch"

    $states = @()
    foreach ($file in Get-DevBranchStateFiles) {
        try {
            $state = Read-DevBranchStateFile -Path $file.FullName
            if (-not (Get-StateValue -State $state -Name "closedAt")) {
                $states += $state
            }
        } catch {
            Write-Host "Skipping unreadable development branch state: $($file.FullName)"
        }
    }

    if ($states.Count -eq 0) {
        Write-Host "No active development branches."
        return
    }

    foreach ($state in ($states | Sort-Object @{ Expression = { Get-StateValue -State $_ -Name "createdAt" -Default "" } }, @{ Expression = { Get-StateValue -State $_ -Name "devBranchName" -Default "" } })) {
        $branch = Get-StateValue -State $state -Name "devBranch" -Default ""
        $marker = if ($branch -and $branch -eq $currentBranch) { "*" } else { " " }
        $name = Get-StateValue -State $state -Name "devBranchName" -Default (Get-StateValue -State $state -Name "safeDevBranchName" -Default "<unknown>")
        $infoBasePath = Get-StateValue -State $state -Name "devBranchInfoBasePath" -Default ""
        $kind = Get-DevBranchKind -State $state
        $extensionName = Get-StateValue -State $state -Name "extensionName" -Default ""
        $createdAt = Get-StateValue -State $state -Name "createdAt" -Default ""
        $lastConfigBaseUpdateAt = Get-StateValue -State $state -Name "lastConfigBaseUpdateAt" -Default ""
        $lastExtensionBaseUpdateAt = Get-StateValue -State $state -Name "lastExtensionBaseUpdateAt" -Default ""
        $lastRefreshAt = Get-StateValue -State $state -Name "lastRefreshAt" -Default ""
        Write-Host "$marker $name"
        Write-Host "  Branch: $branch"
        Write-Host "  Type: $kind"
        $worktreePath = Get-StateValue -State $state -Name "worktreePath" -Default ""
        if (-not $worktreePath) {
            $worktreePath = Get-StateValue -State $state -Name "stateProjectRoot" -Default ""
        }
        if ($worktreePath) {
            Write-Host "  Worktree: $worktreePath"
        }
        Write-DevBranchInitializationStatusLines -State $state -Indent "  "
        $mainWorktreePath = Get-StateValue -State $state -Name "mainWorktreePath" -Default ""
        if ($mainWorktreePath) {
            Write-Host "  Main worktree: $mainWorktreePath"
        }
        if ($extensionName) {
            Write-Host "  Extension: $extensionName"
        }
        Write-Host "  Infobase: $infoBasePath"
        $launcherName = Get-StateValue -State $state -Name "launcherInfoBaseName" -Default ""
        $launcherFolder = Get-StateValue -State $state -Name "launcherFolder" -Default ""
        if ($launcherName) {
            Write-Host "  1C launcher: $launcherName"
        }
        if ($launcherFolder) {
            Write-Host "  1C launcher folder: $launcherFolder"
        }
        $publicationUrl = Get-StateValue -State $state -Name "publicationUrl" -Default ""
        if ($publicationUrl) {
            Write-Host "  Publication URL: $publicationUrl"
        } else {
            $publicationStatus = Get-StateValue -State $state -Name "publicationStatus" -Default ""
            if ($publicationStatus) {
                Write-Host "  Publication status: $publicationStatus"
            }
        }
        Write-DataMcpStatusLines -State $state -Indent "  "
        Write-VanessaTestStatusLines -State $state -Indent "  "
        Write-RoctupMcpStatusLines -State $state -Indent "  "
        Write-VanessaMcpStatusLines -State $state -Indent "  "
        Write-Vibecoding1cMcpStatusLines -Indent "  "
        Write-Host "  Created: $createdAt"
        Write-Host "  Last config base update: $lastConfigBaseUpdateAt"
        if ($kind -eq "extension") {
            Write-Host "  Last extension base update: $lastExtensionBaseUpdateAt"
        }
        Write-Host "  Last Enterprise auto-update: $(Get-StateValue -State $state -Name 'lastEnterpriseAutoUpdateAt' -Default '<never>')"
        Write-Host "  Last refresh: $lastRefreshAt"
    }
}

function Switch-Master {
    Assert-CleanGit
    $currentBranch = ""
    try {
        $currentBranch = Get-CurrentBranch
    } catch {
        $currentBranch = ""
    }
    if ($currentBranch -like "itldev/*") {
        $state = Read-DevBranchState -Name ""
        if (Test-DevBranchStateUsesWorktree -State $state) {
            Clear-DevBranchContext
            $mainWorktreePath = Get-StateValue -State $state -Name "mainWorktreePath" -Default (Get-MainWorktreePath)
            Write-Host "Текущая ветка разработки находится в отдельной рабочей папке."
            Write-Host "Чтобы работать с master, откройте основную папку проекта:"
            Write-Host $mainWorktreePath
            Open-AgentWorktreeBestEffort -WorktreePath $mainWorktreePath
            return
        }
    }

    $masterBranch = Get-MasterBranch
    Ensure-GitRepository
    & git -C $script:ProjectRoot rev-parse --verify $masterBranch *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "Master branch does not exist: $masterBranch"
    }
    Invoke-Git @("checkout", $masterBranch)
    Clear-DevBranchContext
    Sync-KiloItlCommandSurface
    $currentCommit = (Get-GitOutput @("rev-parse", "HEAD")).Trim()
    Write-Host "Switched to master branch: $masterBranch"
    Write-Host "Current commit: $currentCommit"
}

function Switch-DevBranch {
    $state = Read-DevBranchState -Name $DevBranchName
    if (Test-DevBranchStateUsesWorktree -State $state) {
        $worktreePath = Get-StateValue -State $state -Name "worktreePath" -Default ""
        if (-not $worktreePath) {
            $worktree = Find-GitWorktreeByBranch -Branch $state.devBranch
            if ($worktree) {
                $worktreePath = $worktree.path
            }
        }

        if ($worktreePath -and ((Get-FullPathNormalized $worktreePath) -ne (Get-FullPathNormalized $script:ProjectRoot))) {
            Write-Host "Ветка разработки находится в отдельной рабочей папке:"
            Write-Host $worktreePath
            Write-Host "Чтобы продолжить работу агентом с этой линией разработки, откройте отдельное окно выбранного агента или IDE в этой папке."
            Open-AgentWorktreeBestEffort -WorktreePath $worktreePath
            return
        }
    }

    Assert-CleanGit
    Invoke-Git @("checkout", $state.devBranch)
    Sync-DevBranchContextToDotEnv -State $state -AllowIncompleteExtension
    Sync-KiloItlCommandSurface
    $currentCommit = (Get-GitOutput @("rev-parse", "HEAD")).Trim()
    Write-Host "Switched to development branch: $($state.devBranch)"
    Write-Host "Current commit: $currentCommit"
    Write-Host "Development branch infobase: $($state.devBranchInfoBasePath)"
    $launcherName = Get-StateValue -State $state -Name "launcherInfoBaseName" -Default ""
    $launcherFolder = Get-StateValue -State $state -Name "launcherFolder" -Default ""
    if ($launcherName) {
        Write-Host "1C launcher infobase: $launcherName"
    }
    if ($launcherFolder) {
        Write-Host "1C launcher folder: $launcherFolder"
    }
    if ($state.publicationUrl) {
        Write-Host "Publication URL: $($state.publicationUrl)"
    }
    Write-DataMcpStatusLines -State $state
}

function Detect-WebPublication {
    Write-Section "Detect web publication"
    $settings = Get-EffectiveApacheSettings

    if ($settings.webInstOk) {
        Write-Host "[OK] webinst.exe: $($settings.webInstPath)"
    } elseif ($settings.webInstPath) {
        Write-Host "[MISSING] webinst.exe was configured or derived but does not exist: $($settings.webInstPath)"
    } else {
        Write-Host "[MISSING] webinst.exe was not found next to PLATFORM_PATH and WEBINST_PATH is not set."
    }

    if ($settings.apacheFound) {
        Write-Host "[OK] Apache/httpd config: $($settings.httpdConfPath)"
        Write-Host "Source: $($settings.apacheSource)"
        Write-Host "DocumentRoot: $($settings.documentRoot)"
        Write-Host "Listen port: $($settings.listenPort)"
    } elseif ($settings.manualPublicationRoot) {
        Write-Host "[OK] Web publication root is set manually: $($settings.publicationRoot)"
    } else {
        Write-Host "[MISSING] $($settings.message)"
    }

    if ($settings.publicationRoot) {
        Write-Host "Publication root: $($settings.publicationRoot)"
        Write-Host "Publication URL base: $($settings.publicationUrlBase)"
    }

    Write-Host ""
    Write-Host "Values for .dev.env:"
    Write-Host "WEB_PUBLISH_BY_DEFAULT=true"
    Write-Host "WEB_PUBLISH_AUTO=true"
    if ($settings.webInstPath) {
        Write-Host "WEBINST_PATH=$($settings.webInstPath)"
    }
    Write-Host "APACHE_KIND=$($settings.apacheKind)"
    if ($settings.httpdConfPath) {
        Write-Host "APACHE_HTTPD_CONF_PATH=$($settings.httpdConfPath)"
    }
    if ($settings.publicationRoot) {
        Write-Host "WEB_PUBLICATION_ROOT=$($settings.publicationRoot)"
    }
    if ($settings.publicationUrlBase) {
        Write-Host "WEB_PUBLICATION_URL_BASE=$($settings.publicationUrlBase)"
    }

    if (-not $settings.ready) {
        throw "Web publication is not ready. Prepare the web server outside ITL workflow, make sure webinst.exe is available, then rerun configure-web-publication or detect-web-publication."
    }
}

function Detect-Apache {
    Detect-WebPublication
}

function Validate-Project {
    Write-Section "Validate project"
    Require-Value "project root" $script:ProjectRoot | Out-Null
    if (-not (Test-Path -LiteralPath $script:ProjectRoot)) {
        throw "Project root does not exist: $script:ProjectRoot"
    }

    $platformPath = Get-PlatformPath
    if (-not (Test-Path -LiteralPath $platformPath)) {
        throw "1cv8.exe was not found: $platformPath"
    }

    Get-DevBranchInfoBaseRoot | Out-Null

    $kind = Get-InfoBaseKind
    $source = Get-SourceInfoBasePath
    Assert-InfoBaseAvailable -Kind $kind -Path $source -SettingName "source infobase"

    if (Get-SourceUsesRepository) {
        Get-RepositoryPath | Out-Null
        Require-Value "REPOSITORY_USER" (Get-EnvValue -Name "REPOSITORY_USER") | Out-Null
    } else {
        Write-Host "Source repository connection: disabled"
    }
    Write-Host "Validation passed."
}

function Show-Help {
    Write-Section "ITL lifecycle panel"
    Write-Host "Project root: $script:ProjectRoot"

    $surface = Get-KiloItlCommandSurface
    $currentBranch = ""
    try {
        $currentBranch = Get-CurrentBranch
    } catch {
        $currentBranch = ""
    }
    Write-Host "Context: $surface"
    Write-Host "Git branch: $(if ($currentBranch) { $currentBranch } else { '<none>' })"
    Write-Host "Long lifecycle actions may run 1C Designer/Enterprise; agent shell timeout_ms must be >= 3900000 by default and exceed the configured Designer timeout."

    if ($surface -eq "master") {
        Write-Host ""
        Write-Host "Lifecycle:"
        Write-Host "  master -> create branch -> open worktree -> work -> check -> result"
        Write-Host ""
        Write-Host "ITL commands valid in this context:"
        Write-Host "  /itl"
        Write-Host "  /itl-status"
        Write-Host "  /itl-new-config-branch <name>"
        Write-Host "  /itl-new-extension-branch <name>"
        Write-Host "  /itl-update-workflow"
        Write-Host "  /itl-switch-client <client>"
        Write-Host "  /itl-litemode <mode>"
        Write-Host ""
        Write-Host "Active development worktrees:"
        $states = @(Get-WorkflowActiveDevBranchStates)
        if ($states.Count -eq 0) {
            Write-Host "  none"
        } else {
            foreach ($state in ($states | Sort-Object @{ Expression = { Get-StateValue -State $_ -Name "createdAt" -Default "" } }, @{ Expression = { Get-StateValue -State $_ -Name "devBranchName" -Default "" } })) {
                $name = Get-StateValue -State $state -Name "devBranchName" -Default (Get-StateValue -State $state -Name "safeDevBranchName" -Default "<unknown>")
                $branch = Get-StateValue -State $state -Name "devBranch" -Default ""
                $worktreePath = Get-StateValue -State $state -Name "worktreePath" -Default ""
                $branchSuffix = if ($branch) { " ($branch)" } else { "" }
                Write-Host "  $name$branchSuffix"
                if ($worktreePath) {
                    Write-Host "    Worktree: $worktreePath"
                }
                if ((Get-DevBranchKind -State $state) -eq "extension") {
                    Write-Host "    Extension initialization: $(Get-DevBranchExtensionInitializationStatus -State $state)"
                }
                Write-VanessaTestStatusLines -State $state -Indent "    "
                Write-RoctupMcpStatusLines -State $state -Indent "    "
                Write-VanessaMcpStatusLines -State $state -Indent "    "
            }
        }
        Write-Host ""
        Write-Host "Next step: create a configuration or extension branch, then open the printed worktree folder."
    } elseif ($surface -eq "dev") {
        $openSpec = Get-AiRules1cOpenSpecStatus
        $state = $null
        try {
            $state = Read-DevBranchState -Name ""
        } catch {
            Write-Host "Development branch state: missing"
            Write-Host ""
            Write-Host "Recommended next step: run /itl-status, then open the worktree recorded for this branch if it exists."
        }

        if ($state) {
            $verification = Get-VerificationState -State $state
            $kind = Get-DevBranchKind -State $state
            $extensionInitializationStatus = Get-DevBranchExtensionInitializationStatus -State $state
            $hasCheckableChanges = Test-DevBranchHasCheckableChanges -State $state
            $authoringRequired = $false
            try { $authoringRequired = Test-VanessaAuthoringRequired } catch { $authoringRequired = $false }

            Write-Host ""
            Write-Host "Branch:"
            Write-Host "  Name: $(Get-StateValue -State $state -Name 'devBranchName' -Default (Get-StateValue -State $state -Name 'safeDevBranchName' -Default '<unknown>'))"
            Write-Host "  Type: $kind"
            if ($kind -eq "extension") {
                Write-Host "  Extension initialization: $extensionInitializationStatus"
            }
            Write-Host "  Infobase: $($state.devBranchInfoBasePath)"
            $publicationUrl = Get-StateValue -State $state -Name "publicationUrl" -Default ""
            if ($publicationUrl) {
                Write-Host "  Publication URL: $publicationUrl"
            }
            $mainWorktreePath = Get-StateValue -State $state -Name "mainWorktreePath" -Default ""
            if ($mainWorktreePath) {
                Write-Host "  Master worktree: $mainWorktreePath"
            }
            Write-Host ""
            Write-Host "Verification:"
            Write-Host "  Status: $($verification.effectiveStatus)"
            Write-Host "  Fresh passed: $($verification.isFreshPassed)"
            Write-Host "  Checkable changes: $hasCheckableChanges"
            if ($verification.reportPath) {
                Write-Host "  Report: $($verification.reportPath)"
            }
            Write-Host "  Last result: $(Get-StateValue -State $state -Name 'lastResultPath' -Default '<none>')"
            Write-Host "  Final result: $(Get-StateValue -State $state -Name 'finalResultPath' -Default '<none>')"
            Write-Host ""
            if ($kind -eq "extension" -and $extensionInitializationStatus -ne "ready") {
                Write-Host "Recommended next step: tell the agent whether to create an Empty extension or load a CFE, with the extension name and CFE path when applicable."
            } elseif ($authoringRequired) {
                Write-Host "Recommended next step: /itl-vanessa-author"
            } elseif ($hasCheckableChanges -or (@("failed", "stale", "unknown") -contains $verification.effectiveStatus)) {
                Write-Host "Recommended next step: /itl-check"
            } elseif (-not $verification.isFreshPassed) {
                if ($openSpec.mode -eq "native") {
                    Write-Host "Recommended next step: choose development mode: quick-fix, $($openSpec.invocations.explore), or $($openSpec.invocations.propose)"
                } elseif ($openSpec.mode -eq "natural") {
                    Write-Host "Recommended next step: choose quick-fix, or ask the agent to explore a task or prepare an OpenSpec proposal in natural language."
                } else {
                    Write-Host "Recommended next step: choose quick-fix, or restore the OpenSpec workspace/rules from master before starting an OpenSpec change."
                }
            } elseif (-not (Get-StateValue -State $state -Name "lastResultPath" -Default "")) {
                Write-Host "Recommended next step: /itl-result"
            } else {
                Write-Host "Recommended next step: continue work and rerun /itl-check, or use /itl-result again when the artifact is ready."
            }
        }

        Write-Host ""
        Write-Host "Lifecycle:"
        if ($openSpec.mode -eq "native") {
            Write-Host "  extension setup when pending -> optional $($openSpec.invocations.explore) -> quick-fix or $($openSpec.invocations.propose) -> $($openSpec.invocations.apply)/work -> /itl-vanessa-author when features change -> /itl-check -> /itl-result"
        } elseif ($openSpec.mode -eq "natural") {
            Write-Host "  extension setup when pending -> natural explore -> quick-fix or natural propose -> natural apply/work -> /itl-vanessa-author when features change -> /itl-check -> /itl-result -> natural archive"
        } else {
            Write-Host "  extension setup when pending -> quick-fix -> /itl-vanessa-author when features change -> /itl-check -> /itl-result; restore the OpenSpec workspace/rules before an OpenSpec change."
        }
        Write-Host "  use /itl-refresh when master changes must be merged into this branch."
        Write-Host ""
        Write-Host "ITL commands valid in this context:"
        Write-Host "  /itl"
        Write-Host "  /itl-status"
        Write-Host "  /itl-check"
        Write-Host "  /itl-vanessa-author"
        Write-Host "  /itl-verify-fix"
        Write-Host "  /itl-refresh"
        Write-Host "  /itl-result"
        Write-Host "  /itl-litemode <mode>"
        $inheritedPrimaryCommands = @()
        try {
            if ((Get-ItlActiveClient) -eq "kilocode") { $inheritedPrimaryCommands = @(Get-KiloInheritedPrimaryItlCommands) }
        } catch {
            $inheritedPrimaryCommands = @()
        }
        if ($inheritedPrimaryCommands.Count -gt 0) {
            Write-Host ""
            Write-Host "Inherited by Kilo from primary checkout; invalid in this context:"
            foreach ($command in $inheritedPrimaryCommands) {
                Write-Host "  $command"
            }
        }
        Write-Host ""
        Write-Host "OpenSpec:"
        $naturalRequests = Get-ItlOpenSpecNaturalRequests
        Write-Host "  Mode: $($openSpec.mode)"
        Write-Host "  External CLI: $(if ($openSpec.cliAvailable) { $openSpec.cliPath } else { 'not detected; no installation is attempted' })"
        if ($openSpec.mode -eq "native") {
            Write-Host "  $($openSpec.invocations.propose)  Start proposal/design/tasks/test-plan/spec deltas; no code changes."
            Write-Host "  $($openSpec.invocations.apply)  Implement an approved OpenSpec change from tasks.md and test-plan.md."
            Write-Host "  $($openSpec.invocations.archive)  Archive an accepted OpenSpec change."
            Write-Host "  $($openSpec.invocations.explore)  Optional exploration without proposal or code changes."
            if (-not $openSpec.cliAvailable) {
                Write-Host "  If the native prompt cannot invoke the CLI, use the natural requests below; never run npm install or openspec update."
                Write-Host "  Explore: $($naturalRequests.explore)"
                Write-Host "  Propose: $($naturalRequests.propose)"
                Write-Host "  Apply: $($naturalRequests.apply)"
                Write-Host "  Archive: $($naturalRequests.archive)"
            }
        } elseif ($openSpec.mode -eq "natural") {
            Write-Host "  Explore: $($naturalRequests.explore)"
            Write-Host "  Propose: $($naturalRequests.propose)"
            Write-Host "  Apply: $($naturalRequests.apply)"
            Write-Host "  Archive: $($naturalRequests.archive)"
            Write-Host "  No native bundle is required; never run npm install or openspec update."
        } else {
            Write-Host "  OpenSpec is unavailable: $($openSpec.reason)"
            Write-Host "  Recovery: in master run update-ai-rules or update-workflow, merge the update into this branch, then run /itl-refresh."
        }
        Write-Host "  use /itl-verify-fix only to repair omitted coverage or a failing verification cycle."
    } else {
        Write-Host ""
        Write-Host "Lifecycle:"
        Write-Host "  Open the master worktree to create branches, or open an itldev/* worktree to check/result work."
        Write-Host ""
        Write-Host "ITL commands valid in this context:"
        Write-Host "  /itl"
        Write-Host "  /itl-status"
        Write-Host ""
        Write-Host "Next step: run /itl-status to inspect this folder, then open the correct worktree."
    }

    Write-ItlAdditionalHelperActions
}
