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
        throw "Extension name is not set for this development branch. Run set-dev-branch-extension first."
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

    $arguments = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $script:Agent1cScriptPath
    ) + @($reexecArguments.ToArray()) + @($AdditionalArguments)

    & powershell @arguments
    $exitCode = if ($LASTEXITCODE -is [int]) { $LASTEXITCODE } elseif ($?) { 0 } else { 1 }
    exit $exitCode
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
    Write-Host "  ROCTUP MCP: ask for branch-local install, update, start, status, or stop for data exploration."
    Write-Host "  vibecoding1c MCP: ask for setup, status, select, refresh-registry, or update."
    Write-Host "  Vanessa UI MCP: ask for branch-local install, start, status, or stop only for runtime UI research, recording, or debugging."
    Write-Host "  Extension branches: after branch creation run init-dev-branch-extension; set/dump remain recovery actions."
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

    if (-not $LoadResult.loaded) {
        return
    }

    Ensure-DevBranchEnterpriseNormalized -State $State -Reason "config-load" -Updates $Updates | Out-Null
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
    New-Item -ItemType Directory -Force -Path $absoluteExportPath | Out-Null

    $dumpInfoPath = Join-Path $absoluteExportPath "ConfigDumpInfo.xml"
    $children = @(Get-ChildItem -LiteralPath $absoluteExportPath -Force)
    $isIncremental = Test-Path -LiteralPath $dumpInfoPath -PathType Leaf
    $designerArgs = @()
    if (Get-SourceUsesRepository) {
        $designerArgs += New-RepositoryConnectionArgs
    }
    $designerArgs += @("/DumpConfigToFiles", $absoluteExportPath, "-Format", "Hierarchical")
    if ($isIncremental) {
        $designerArgs += @("-update", "-force")
    } elseif ($children.Count -gt 0) {
        throw "Export path '$absoluteExportPath' is not empty and ConfigDumpInfo.xml is missing. Clean the folder manually or restore ConfigDumpInfo.xml before dumping config files."
    }

    Invoke-Designer `
        -InfoBasePath (Get-SourceInfoBasePath) `
        -InfoBaseKind (Get-InfoBaseKind) `
        -DesignerArgs $designerArgs | Out-Null

    if (-not (Test-Path -LiteralPath $dumpInfoPath -PathType Leaf)) {
        throw "1C configuration dump did not create ConfigDumpInfo.xml in '$absoluteExportPath'. Check the 1C log: $script:LastLogPath"
    }

    $dumpedFiles = @(Get-ChildItem -LiteralPath $absoluteExportPath -Force)
    if ($dumpedFiles.Count -eq 0) {
        throw "1C configuration dump produced no files in '$absoluteExportPath'. Check the 1C log: $script:LastLogPath"
    }

    return [pscustomobject]@{
        exportPath = $exportPath
        absoluteExportPath = $absoluteExportPath
        incremental = $isIncremental
        logPath = $script:LastLogPath
    }
}

function Dump-ExtensionToFiles {
    param([object]$State)

    Assert-DevBranchKind -State $State -Expected "extension"
    $extensionName = Require-DevBranchExtensionName -State $State
    $extensionExportPath = Get-DevBranchExtensionExportPath -State $State
    $absoluteExportPath = Assert-ExportPathInsideProject $extensionExportPath
    New-Item -ItemType Directory -Force -Path $absoluteExportPath | Out-Null

    $dumpInfoPath = Join-Path $absoluteExportPath "ConfigDumpInfo.xml"
    $children = @(Get-ChildItem -LiteralPath $absoluteExportPath -Force)
    $isIncremental = Test-Path -LiteralPath $dumpInfoPath -PathType Leaf
    $designerArgs = @("/DumpConfigToFiles", $absoluteExportPath, "-Extension", $extensionName, "-Format", "Hierarchical")
    if ($isIncremental) {
        $designerArgs += @("-update", "-force")
    } elseif ($children.Count -gt 0) {
        throw "Extension export path '$absoluteExportPath' is not empty and ConfigDumpInfo.xml is missing. Clean the folder manually or restore ConfigDumpInfo.xml before dumping extension files."
    }

    Invoke-Designer `
        -InfoBasePath $state.devBranchInfoBasePath `
        -InfoBaseKind $state.infoBaseKind `
        -DesignerArgs $designerArgs | Out-Null

    if (-not (Test-Path -LiteralPath $dumpInfoPath -PathType Leaf)) {
        throw "1C extension dump did not create ConfigDumpInfo.xml in '$absoluteExportPath'. Make sure extension '$extensionName' exists in the development branch infobase. Check the 1C log: $script:LastLogPath"
    }

    return [pscustomobject]@{
        extensionName = $extensionName
        exportPath = $extensionExportPath
        absoluteExportPath = $absoluteExportPath
        incremental = $isIncremental
        logPath = $script:LastLogPath
    }
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

    $changeSet = Get-ConfigLoadChangeSet -State $State -ExportPath $ExportPath -ContentKind $ContentKind
    if ($changeSet.files.Count -eq 0) {
        Write-Host "No changed config files under $ExportPath since $($changeSet.baseCommit)."
        Write-Host "Development branch infobase already matches current branch config files."
        return [pscustomobject]@{
            loaded = $false
            fileCount = 0
            listFile = ""
            currentCommit = $changeSet.currentCommit
            lastLogPath = $script:LastLogPath
            loadModeUsed = ""
            partialLogPath = ""
            fullFallbackLogPath = ""
            configLoadStatus = "passed"
            partialError = ""
            fullFallbackError = ""
        }
    }

    $listFilePath = ""
    if ($Mode -ne "Full") {
        $listFilePath = New-ConfigLoadListFile -State $State -Files $changeSet.files
    }
    $orchestration = Invoke-ConfigLoadWithFallback `
        -InfoBasePath $InfoBasePath `
        -InfoBaseKind $InfoBaseKind `
        -State $State `
        -AbsoluteExportPath $changeSet.absoluteExportPath `
        -ListFilePath $listFilePath `
        -FileCount $changeSet.files.Count `
        -ExtensionName $ExtensionName `
        -Mode $Mode

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
        # Protocol 1.1 can merge identical Codex/Kilo bundle destinations into
        # one manifest entry whose source belongs to either owner. Destination
        # inventory, not source-string identity, proves the bundle is present.
        $matches = @($entries | Where-Object { $_.target -eq $relative })
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

    foreach ($tool in $DesiredTools) {
        $bundle = Get-AiRules1cOpenSpecBundleValidation -RulesDir $RulesDir -Tool $tool -Manifest $manifest
        if ($bundle.hasBundle -and -not $bundle.isValid) {
            throw "ai_rules_1c OpenSpec bundle for '$tool' is incomplete: $($bundle.missing -join ', ')."
        }
    }

    return $manifest
}

function Get-AiRules1cKiloOpenSpecStatus {
    $requiredCommands = @("opsx-propose", "opsx-explore", "opsx-apply", "opsx-archive")
    try {
        $manifest = Get-AiRules1cProjectManifest
    } catch {
        return [pscustomobject]@{ isAvailable = $false; reason = $_.Exception.Message }
    }

    if ($null -eq $manifest) {
        return [pscustomobject]@{ isAvailable = $false; reason = "ai_rules_1c manifest is missing." }
    }
    if (-not (Test-AiRules1cToolInstalled -Tool "kilocode")) {
        return [pscustomobject]@{ isAvailable = $false; reason = "ai_rules_1c does not list kilocode as an installed tool." }
    }

    $entries = @(Get-AiRules1cManifestFileEntries -Manifest $manifest)
    $missing = @()
    foreach ($command in $requiredCommands) {
        $matches = @($entries | Where-Object {
            $_.source.Replace('\', '/') -match ("/" + [regex]::Escape($command) + "\.md$")
        })
        if ($matches.Count -eq 0) {
            $missing += $command
            continue
        }
        if (@($matches | Where-Object { -not (Test-Path -LiteralPath (Join-Path $script:ProjectRoot $_.target) -PathType Leaf) }).Count -gt 0) {
            $missing += $command
        }
    }

    if ($missing.Count -gt 0) {
        return [pscustomobject]@{
            isAvailable = $false
            reason = "managed OpenSpec command artifact(s) are missing: $($missing -join ', ')."
        }
    }
    return [pscustomobject]@{ isAvailable = $true; reason = "" }
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

    $tempRoot = Resolve-Agent1cFullPath -Path $env:TEMP
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

    $installedTools = @(Get-AiRules1cManifestToolNames)
    foreach ($tool in @($desiredTools | Where-Object { $installedTools -notcontains $_ })) {
        $addArgs = @(
            "add",
            "-Tool", $tool,
            "-ProjectRoot", (Resolve-Agent1cFullPath -Path $script:ProjectRoot),
            "-Source", $rulesDir,
            "-McpMode", "delegated",
            "-AssumeYes"
        )
        Push-Location (Resolve-Agent1cFullPath -Path $script:ProjectRoot)
        try {
            & powershell -NoProfile -ExecutionPolicy Bypass -File $installScript @addArgs
            if ($LASTEXITCODE -ne 0) {
                throw "ai_rules_1c add $tool failed with exit code $LASTEXITCODE"
            }
        } finally {
            Pop-Location
        }
    }

    Assert-AiRules1cInstallation -RulesDir $rulesDir -DesiredTools $desiredTools | Out-Null

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
    $paths = @(
        (Get-Vibecoding1cMcpCodexHomeConfigPath),
        (Get-Vibecoding1cMcpCodexProjectConfigPath),
        (Get-Vibecoding1cMcpKiloConfigPath)
    )
    return @($paths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
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
    return (Resolve-Agent1cFullPath -Path (Join-Path (Join-Path (Resolve-Agent1cFullPath -Path $env:TEMP) "1c-agent-workflow") "workflow-package"))
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
    if (Test-Path -LiteralPath (Join-Path $root ".git") -PathType Container -ErrorAction SilentlyContinue) {
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
    $entry["repo"] = [string]$Source.repo
    $entry["ref"] = [string]$Source.ref
    $entry["commit"] = [string]$Source.commit
    $entry["source"] = [string]$Source.source
    $entry["updatedAt"] = (Get-Date).ToString("o")
    $dependencies["workflowPackage"] = $entry
    $manifest["dependencies"] = $dependencies
    Write-DependencyLockManifest -Manifest $manifest
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

    Update-WorkflowPackageLockEntry -Source ([pscustomobject]@{
        repo = [string]$BootstrapWorkflowRepo
        ref = [string]$BootstrapWorkflowRef
        commit = ([string]$BootstrapWorkflowCommit).ToLowerInvariant()
        source = [string]$BootstrapWorkflowSource
    })
    Write-Host "Recorded bootstrap workflow package provenance: $(if ($BootstrapWorkflowCommit) { $BootstrapWorkflowCommit } else { '<non-Git source>' })"
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
        Write-Host "  If Vanessa UI MCP is used in a branch, run stop-vanessa-mcp, install-vanessa-mcp, then start-vanessa-mcp in that branch worktree."
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
        Assert-WorkflowPackageUpdateContext

        $source = Resolve-WorkflowPackageSource
        Assert-WorkflowSourceOutsideProject -SourceRoot $source.root

        Copy-WorkflowManagedDirectory -SourceRoot $source.root -RelativePath ".agents\skills\1c-workflow"
        Copy-WorkflowManagedDirectory -SourceRoot $source.root -RelativePath ".agents\skills\1c-workflow-fast"
        Copy-WorkflowManagedDirectory -SourceRoot $source.root -RelativePath ".agents\skills\product-docs"
        Copy-WorkflowManagedDirectory -SourceRoot $source.root -RelativePath ".agents\skills\itl-roctup-1c-data"
        Copy-WorkflowManagedDirectory -SourceRoot $source.root -RelativePath ".agents\skills\itl-vanessa-ui-mcp"
        Copy-WorkflowManagedDirectory -SourceRoot $source.root -RelativePath "templates"
        foreach ($relativePath in @("install-agent-1c-workflow.ps1", "README.md", "AGENT-INSTALL.md", "DEVELOPER-GUIDE.ru.md", "DEV-BRANCH-DEVELOPMENT.ru.md", "VANESSA-TESTS-GUIDE.md", "VANESSA-TESTS-GUIDE.ru.md")) {
            Copy-WorkflowManagedFile -SourceRoot $source.root -RelativePath $relativePath
        }

        Update-WorkflowPackageLockEntry -Source $source
        Write-Host "Workflow package files copied. Restarting the installed helper in a fresh PowerShell process for post-copy processing."
        Invoke-Agent1cFreshProcess -AdditionalArguments @("-LifecyclePhase", "post-copy")
    }

    Assert-MasterWorktreeContext -Operation "update-workflow post-copy"
    Ensure-GitIgnore
    Update-AgentGuidanceBridge
    Update-UserRules
    Update-RoctupMcp
    Update-VanessaMcpArtifacts

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
    return (@("initializing", "infobase-copied", "repository-unbound", "launcher-registered", "enterprise-normalization-pending", "failed") -contains $status)
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
    Write-Host "Чтобы продолжить работу агентом с этой линией разработки, откройте отдельное окно Codex/Kilo/IDE в этой папке."
    Write-Host "Могу попробовать открыть новое окно агента для этой папки автоматически."
    Write-Host "Если Kilo показывает устаревший список slash-команд в новом worktree, выполните /reload."
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
                Write-Host "Development branch context is incomplete: extension name is not set. Run set-dev-branch-extension before using /update1cbase."
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
        [string]$DevBranchName,
        [string]$ProjectRootForName = $script:ProjectRoot
    )

    $projectName = Get-LauncherProjectName -ProjectRootForName $ProjectRootForName
    $branchName = ConvertTo-LauncherLabel -Value $DevBranchName
    return "$projectName - $branchName"
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
        [string]$DevBranchName,
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
    $displayName = Get-LauncherInfoBaseName -DevBranchName $DevBranchName -ProjectRootForName $ProjectRootForFolder
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
    $mode = Get-DevBranchUnsafeActionProtectionSetupRaw
    if ($mode -eq "manual-confirm" -and -not (Test-InteractiveInputAvailable)) {
        throw (Get-DevBranchUnsafeActionProtectionInteractiveRequiredMessage)
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
    if (-not $dumpWasCompleted) {
        Set-RunStage -Stage "init.check-tools" -Detail "Checking required tools"
        Check-Tools -StopOnMissing
        Set-RunStage -Stage "init.install-roctup-mcp" -Detail "Installing or updating ROCTUP MCP Toolkit"
        Install-RoctupMcp
        Set-RunStage -Stage "init.cache-vanessa-ui-mcp" -Detail "Caching Vanessa UI MCP artifacts"
        Install-VanessaMcpArtifacts | Out-Null
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
    Set-RunStage -Stage "init.complete" -Detail "Initialization completed"
}

function Sync-Master {
    param([switch]$NoDelegate)

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
        [bool]$CreatedWithWorktree = $false
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

    $statePath = Join-Path $script:ProjectRoot ".agent-1c\dev-branches\$SafeDevBranchName.json"
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
        @{ name = "unsafeActionProtectionConfirmed"; value = $false },
        @{ name = "unsafeActionProtectionConfirmedAt"; value = "" },
        @{ name = "unsafeActionProtectionUser"; value = "" },
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
        @{ name = "lastConfigFullFallbackError"; value = "" }
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
        $statePath = Save-DevBranchInitializationState -SafeDevBranchName $SafeDevBranchName -State $stateHash -Status "initializing"
    }

    try {
        if ($currentStatus -eq "enterprise-normalization-pending") {
            Write-Host "Resuming final Enterprise normalization for existing development branch copy: $DevBranchInfoBasePath"
            $state = Read-DevBranchStateFile -Path $statePath
            Ensure-DevBranchEnterpriseNormalized -State $state -Reason "branch-copy" | Out-Null
            $normalizedState = Read-DevBranchStateFile -Path $statePath
            $normalizedHash = ConvertTo-Agent1cHashtable $normalizedState
            [void]$normalizedHash.Remove("statePath")
            [void]$normalizedHash.Remove("stateProjectRoot")
            $statePath = Save-DevBranchInitializationState -SafeDevBranchName $SafeDevBranchName -State $normalizedHash -Status "ready"
            $state = Read-DevBranchStateFile -Path $statePath
            if (Get-StateValue -State $state -Name "publicationUrl" -Default "") {
                $state = Invoke-DevBranchDataMcpAfterPublication -State $state
            }
            Sync-DevBranchContextToDotEnv -State $state -AllowIncompleteExtension
            Sync-KiloItlCommandSurface
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
            }
        }
        $statePath = Save-DevBranchInitializationState -SafeDevBranchName $SafeDevBranchName -State $stateHash -Status "infobase-copied"
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
        $statePath = Save-DevBranchInitializationState -SafeDevBranchName $SafeDevBranchName -State $stateHash -Status "repository-unbound"
        $currentStatus = "repository-unbound"

        $launcherRegistration = Register-DevBranchInLauncher `
            -InfoBaseKind $kind `
            -InfoBasePath $DevBranchInfoBasePath `
            -DevBranchName $DevBranchName `
            -ProjectRootForFolder $MainProjectRoot `
            -ExistingLauncherId ([string]$stateHash["launcherInfoBaseId"])
        $stateHash["launcherRegistered"] = $launcherRegistration.registered
        $stateHash["launcherInfoBaseName"] = $launcherRegistration.name
        $stateHash["launcherFolder"] = $launcherRegistration.folder
        $stateHash["launcherInfoBaseId"] = $launcherRegistration.id
        $stateHash["launcherListPath"] = $launcherRegistration.listPath
        $statePath = Save-DevBranchInitializationState -SafeDevBranchName $SafeDevBranchName -State $stateHash -Status "launcher-registered"
        $currentStatus = "launcher-registered"

        $unsafeActionProtectionSetup = Confirm-DevBranchUnsafeActionProtection `
            -InfoBaseKind $kind `
            -InfoBasePath $DevBranchInfoBasePath `
            -DevBranchName $DevBranchName
        $stateHash["unsafeActionProtectionSetupMode"] = $unsafeActionProtectionSetup.mode
        $stateHash["unsafeActionProtectionConfirmed"] = $unsafeActionProtectionSetup.confirmed
        $stateHash["unsafeActionProtectionConfirmedAt"] = $unsafeActionProtectionSetup.confirmedAt
        $stateHash["unsafeActionProtectionUser"] = $unsafeActionProtectionSetup.user
        $statePath = Save-DevBranchInitializationState -SafeDevBranchName $SafeDevBranchName -State $stateHash -Status "launcher-registered"

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
        $statePath = Save-DevBranchInitializationState -SafeDevBranchName $SafeDevBranchName -State $pendingHash -Status "enterprise-normalization-pending"
        $currentStatus = "enterprise-normalization-pending"
        $state = Read-DevBranchStateFile -Path $statePath
        Ensure-DevBranchEnterpriseNormalized -State $state -Reason "branch-copy" | Out-Null
        $state = Read-DevBranchStateFile -Path $statePath
        $finalHash = @{}
        $finalStateHash = ConvertTo-Agent1cHashtable $state
        foreach ($key in $finalStateHash.Keys) {
            if (@("statePath", "stateProjectRoot") -contains $key) {
                continue
            }
            $finalHash[$key] = $finalStateHash[$key]
        }
        $statePath = Save-DevBranchInitializationState -SafeDevBranchName $SafeDevBranchName -State $finalHash -Status "ready"
        $state = Read-DevBranchStateFile -Path $statePath
        if (Get-StateValue -State $state -Name "publicationUrl" -Default "") {
            $state = Invoke-DevBranchDataMcpAfterPublication -State $state
        }
        Sync-DevBranchContextToDotEnv -State $state -AllowIncompleteExtension
        Sync-KiloItlCommandSurface
    } catch {
        $message = $_.Exception.Message
        $statusForError = if ($currentStatus -and @("infobase-copied", "repository-unbound", "launcher-registered", "enterprise-normalization-pending") -contains $currentStatus) { $currentStatus } else { "failed" }
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
        Save-DevBranchInitializationState -SafeDevBranchName $SafeDevBranchName -State $failureHash -Status $statusForError -ErrorMessage $message | Out-Null
        throw
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
        [string]$DevBranchKind = "configuration"
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
            Invoke-InProjectContext -Root $resumeWorktreePath -ScriptBlock {
                Initialize-DevBranchRuntime `
                    -DevBranchKind $DevBranchKind `
                    -SafeDevBranchName $safe `
                    -GitBranch $DevBranch `
                    -MainProjectRoot $mainProjectRoot `
                    -WorktreePath $resumeWorktreePath `
                    -CreatedWithWorktree $true
            }

            Write-DevBranchWorktreeOpenMessage -MainProjectPath $mainProjectRoot -WorktreePath $resumeWorktreePath
            Open-AgentWorktreeBestEffort -WorktreePath $resumeWorktreePath
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

    Invoke-InProjectContext -Root $worktreePath -ScriptBlock {
        Initialize-DevBranchRuntime `
            -DevBranchKind $DevBranchKind `
            -SafeDevBranchName $safe `
            -GitBranch $DevBranch `
            -MainProjectRoot $mainProjectRoot `
            -WorktreePath $worktreePath `
            -CreatedWithWorktree $true
    }

    Write-DevBranchWorktreeOpenMessage -MainProjectPath $mainProjectRoot -WorktreePath $worktreePath
    Open-AgentWorktreeBestEffort -WorktreePath $worktreePath
}

function New-DevBranch {
    New-DevBranchCore -DevBranchKind "configuration"
}

function New-ExtensionDevBranch {
    New-DevBranchCore -DevBranchKind "extension"
    Write-Host "Mandatory next step (run in the new extension worktree):"
    Write-Host '  powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action init-dev-branch-extension -ExtensionInitMode Empty -ExtensionName "<ExtensionName>"'
    Write-Host '  For an existing CFE, use -ExtensionInitMode Cfe -ExtensionName "<ExtensionName>" -ExtensionSourcePath "<file.cfe>".'
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
    $toolRoot = if ($null -ne $override -and -not [string]::IsNullOrWhiteSpace([string]$override.Value)) {
        [System.IO.Path]::GetFullPath([string]$override.Value)
    } else {
        Join-Path $script:ProjectRoot ".agents\skills\1c-metadata-manage\tools\1c-cfe-manage\scripts"
    }
    $initPath = Join-Path $toolRoot "cfe-init.ps1"
    $validatePath = Join-Path $toolRoot "cfe-validate.ps1"
    if (-not (Test-Path -LiteralPath $initPath -PathType Leaf) -or -not (Test-Path -LiteralPath $validatePath -PathType Leaf)) {
        throw "Extension lifecycle tools are missing. Run update-ai-rules, then retry init-dev-branch-extension. Expected: $initPath and $validatePath"
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
    if ($RoctupWasRunning) {
        $currentState = Start-RoctupMcpForState -State $currentState -Quiet
    }
    if ($VanessaWasRunning) {
        Start-VanessaMcp
        $currentState = Read-DevBranchState -Name (Get-StateValue -State $State -Name "devBranchName" -Default "")
    }
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
        throw "Extension state already exists for this branch ('$existingStateName'). init-dev-branch-extension never overwrites it; use set-dev-branch-extension only for recovery of a manually created extension."
    }

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

    $tools = Get-ExtensionLifecycleToolPaths
    $stagingRoot = Assert-ExportPathInsideProject -ExportPath (".agent-1c/extension-init/" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $stagingRoot | Out-Null
    $snapshotDir = Assert-ExportPathInsideProject -ExportPath ".agent-1c/snapshots"
    $snapshotPath = Join-Path $snapshotDir ("extension-init-{0}-{1}.dt" -f (ConvertTo-SafeName $ExtensionName), (Get-Date -Format "yyyyMMdd-HHmmss"))
    $snapshotCreated = $false
    $roctupWasRunning = $false
    $vanessaWasRunning = $false

    try {
        if (Test-DevBranchExtensionExists -State $state -Name $ExtensionName) {
            throw "Extension '$ExtensionName' already exists in the development branch infobase; refusing to overwrite it."
        }

        $roctupWasRunning = [bool](Get-RoctupMcpRuntimeInfo -State $state).processAlive
        $vanessaWasRunning = [bool](Get-VanessaMcpRuntimeInfo -State $state).processAlive
        Stop-OwnVanessaTestProcessesAndAssert -State $state
        Stop-RoctupMcpForState -State $state -Quiet | Out-Null
        $state = Read-DevBranchState -Name (Get-StateValue -State $state -Name "devBranchName" -Default "")
        Stop-VanessaMcpForState -State $state -Quiet | Out-Null
        $state = Read-DevBranchState -Name (Get-StateValue -State $state -Name "devBranchName" -Default "")

        New-Item -ItemType Directory -Force -Path $snapshotDir | Out-Null
        Invoke-Designer -InfoBasePath $state.devBranchInfoBasePath -InfoBaseKind $state.infoBaseKind -DesignerArgs @("/DumpIB", $snapshotPath) | Out-Null
        if (-not (Test-Path -LiteralPath $snapshotPath -PathType Leaf)) {
            throw "1C snapshot was not created: $snapshotPath"
        }
        $snapshotCreated = $true

        if ($ExtensionInitMode -eq "Empty") {
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
            Invoke-Designer -InfoBasePath $state.devBranchInfoBasePath -InfoBaseKind $state.infoBaseKind -DesignerArgs @(
                "/LoadConfigFromFiles", $scaffoldPath, "-Extension", $ExtensionName, "-Format", "Hierarchical", "/UpdateDBCfg"
            ) | Out-Null
        } else {
            Invoke-Designer -InfoBasePath $state.devBranchInfoBasePath -InfoBaseKind $state.infoBaseKind -DesignerArgs @(
                "/LoadCfg", $sourceCfe, "-Extension", $ExtensionName, "/UpdateDBCfg"
            ) | Out-Null
        }

        New-Item -ItemType Directory -Force -Path $absoluteDumpPath | Out-Null
        Invoke-Designer -InfoBasePath $state.devBranchInfoBasePath -InfoBaseKind $state.infoBaseKind -DesignerArgs @(
            "/DumpConfigToFiles", $absoluteDumpPath, "-Extension", $ExtensionName, "-Format", "Hierarchical"
        ) | Out-Null
        Assert-NormalizedExtensionDump -Path $absoluteDumpPath -Name $ExtensionName
        Invoke-ExtensionLifecycleTool -ScriptPath $tools.validate -Arguments @("-ExtensionPath", $absoluteDumpPath)

        Restore-ExtensionInitMcpRuntime -State $state -RoctupWasRunning $roctupWasRunning -VanessaWasRunning $vanessaWasRunning
        $state = Read-DevBranchState -Name (Get-StateValue -State $state -Name "devBranchName" -Default "")
        $now = (Get-Date).ToString("o")
        $updates = @{
            extensionName = $ExtensionName
            safeExtensionName = ConvertTo-SafeName $ExtensionName
            extensionInitMode = $ExtensionInitMode
            extensionDumpPath = $dumpPath
            extensionExportPath = $dumpPath
            extensionInitializedAt = $now
            lastExtensionDumpAt = $now
            lastExtensionDumpPath = $dumpPath
            lastExtensionBaseUpdateAt = $now
            lastExtensionBaseUpdatedCommit = Get-CurrentCommit
            lastLoadedCommit = Get-CurrentCommit
            lastLogPath = $script:LastLogPath
        }
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
                Invoke-Designer -InfoBasePath $state.devBranchInfoBasePath -InfoBaseKind $state.infoBaseKind -DesignerArgs @("/RestoreIB", $snapshotPath) | Out-Null
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
        if ($rollbackError) {
            throw "Extension initialization failed: $originalError Rollback also failed: $rollbackError Snapshot retained: $snapshotPath"
        }
        if ($snapshotCreated) {
            throw "Extension initialization failed and the infobase snapshot was restored: $originalError"
        }
        throw "Extension initialization failed before a snapshot was created: $originalError"
    } finally {
        if (Test-Path -LiteralPath $stagingRoot -PathType Container -ErrorAction SilentlyContinue) {
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

    $safeExtensionName = ConvertTo-SafeName $ExtensionName
    $extensionExportPath = Get-ExtensionInitDumpPath -Name $ExtensionName
    $updates = @{
        extensionName = $ExtensionName
        safeExtensionName = $safeExtensionName
        extensionDumpPath = $extensionExportPath
        extensionExportPath = $extensionExportPath
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
    Sync-DevBranchContextToDotEnv -State $state -AllowIncompleteExtension

    if ($LifecyclePhase -ne "post-merge") {
        Assert-CleanGit
        Sync-Master
        if ((Get-CurrentBranch) -ne $state.devBranch) {
            Invoke-Git @("checkout", $state.devBranch)
        }
        Invoke-Git @("merge", (Get-MasterBranch))
        Restart-Agent1cAfterDevBranchMerge -Operation "refresh-dev-branch"
    }

    Sync-DevBranchContextToDotEnv -State $state -AllowIncompleteExtension
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
}

function Dump-DevBranchExtension {
    $state = Read-DevBranchState -Name $DevBranchName
    Assert-DevelopmentBranchWorktreeContext -State $state -Operation "dump-dev-branch-extension"
    $dumpResult = Dump-ExtensionToFiles -State $state
    $updates = @{
        extensionDumpPath = $dumpResult.exportPath
        extensionExportPath = $dumpResult.exportPath
        lastExtensionDumpAt = (Get-Date).ToString("o")
        lastExtensionDumpPath = $dumpResult.exportPath
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

function Invoke-ReleaseE2EConfigRoundtrip {
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
    $state = Read-DevBranchState -Name $DevBranchName
    Assert-DevelopmentBranchWorktreeContext -State $state -Operation "release-e2e-extension-smoke"
    Assert-DevBranchKind -State $state -Expected "configuration"
    Assert-CleanGit
    Assert-ExtensionInitName -Name $ExtensionName | Out-Null
    Require-Value "ReleaseAiRulesSource" $ReleaseAiRulesSource | Out-Null
    $releaseAiRulesRoot = Resolve-Agent1cFullPath -Path $ReleaseAiRulesSource
    $releaseToolRoot = Join-Path $releaseAiRulesRoot "content\skills\1c-metadata-manage\tools\1c-cfe-manage\scripts"
    foreach ($requiredTool in @("cfe-init.ps1", "cfe-validate.ps1")) {
        if (-not (Test-Path -LiteralPath (Join-Path $releaseToolRoot $requiredTool) -PathType Leaf)) {
            throw "Release ai_rules source does not contain $requiredTool at the expected r4 path: $releaseToolRoot"
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
        Stop-OwnVanessaTestProcessesAndAssert -State $state
        Stop-RoctupMcpForState -State $state -Quiet | Out-Null
        $state = Read-DevBranchState -Name $DevBranchName
        Stop-VanessaMcpForState -State $state -Quiet | Out-Null
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

        Invoke-Designer -InfoBasePath $emptyState.devBranchInfoBasePath -InfoBaseKind $emptyState.infoBaseKind -DesignerArgs @(
            "/DumpCfg", $cfePath, "-Extension", $ExtensionName
        ) | Out-Null
        if (-not (Test-Path -LiteralPath $cfePath -PathType Leaf) -or (Get-Item -LiteralPath $cfePath).Length -le 0) {
            throw "Release extension smoke did not create a non-empty CFE: $cfePath"
        }
        $cfeSha256 = (Get-FileHash -LiteralPath $cfePath -Algorithm SHA256).Hash.ToLowerInvariant()

        Invoke-Designer -InfoBasePath $emptyState.devBranchInfoBasePath -InfoBaseKind $emptyState.infoBaseKind -DesignerArgs @("/RestoreIB", $snapshotPath) | Out-Null
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

        Invoke-Designer -InfoBasePath $cfeState.devBranchInfoBasePath -InfoBaseKind $cfeState.infoBaseKind -DesignerArgs @("/RestoreIB", $snapshotPath) | Out-Null
        $databaseRestored = $true
        Restore-ReleaseE2EExtensionLocalState

        if (@(& git -C $script:ProjectRoot status --porcelain).Count -ne 0) {
            throw "Release extension smoke left the worktree dirty."
        }
        $evidence = [ordered]@{
            schemaVersion = 1
            checkedAt = [DateTime]::UtcNow.ToString("o")
            devBranchName = $DevBranchName
            extensionName = $ExtensionName
            emptyInitialized = $true
            cfeCreated = $true
            cfeInitialized = $true
            databaseRestored = $true
            emptyDumpConfigurationSha256 = $emptyDumpSha256
            cfeSha256 = $cfeSha256
            cfeDumpConfigurationSha256 = $cfeDumpSha256
        }
        Write-Utf8Text -Path $evidencePath -Value (($evidence | ConvertTo-Json -Depth 6) + [Environment]::NewLine)
        Write-Host "Release E2E extension Empty/CFE smoke passed: $evidencePath"
    } catch {
        $failure = $_.Exception.Message
    } finally {
        if ($snapshotCreated -and -not $databaseRestored) {
            try {
                $rollbackState = Read-DevBranchState -Name $DevBranchName
                Invoke-Designer -InfoBasePath $rollbackState.devBranchInfoBasePath -InfoBaseKind $rollbackState.infoBaseKind -DesignerArgs @("/RestoreIB", $snapshotPath) | Out-Null
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
    Write-Host "Long lifecycle actions may run 1C Designer/Enterprise; agent shell timeout_ms must be >= 1800000."

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
                Write-RoctupMcpStatusLines -State $state -Indent "    "
                Write-VanessaMcpStatusLines -State $state -Indent "    "
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
    Write-RoctupMcpStatusLines -State $state
    Write-VanessaTestStatusLines -State $state
    Write-VanessaMcpStatusLines -State $state
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
    Update-DevBranchBase
    Run-DevBranchTests
}

function Check-DevBranch {
    Invoke-DevBranchCheck
}

function Verify-DevBranch {
    Invoke-DevBranchCheck
}

function Export-DevBranchResult {
    $state = Read-DevBranchState -Name $DevBranchName
    Assert-DevelopmentBranchWorktreeContext -State $state -Operation "export-dev-branch-result"
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
    Stop-RoctupMcpForState -State $state -Quiet | Out-Null
    $state = Read-DevBranchState -Name $DevBranchName
    Stop-VanessaMcpForState -State $state -Quiet | Out-Null
    $state = Read-DevBranchState -Name $DevBranchName
    Release-ItlManagedPortAllocationsForState -State $state
    Sync-DevBranchContextToDotEnv -State $state

    if ($LifecyclePhase -ne "post-merge") {
        Assert-CleanGit
        Sync-Master
        if ((Get-CurrentBranch) -ne $state.devBranch) {
            Invoke-Git @("checkout", $state.devBranch)
        }
        Invoke-Git @("merge", (Get-MasterBranch))
        Restart-Agent1cAfterDevBranchMerge -Operation "close-dev-branch"
    }

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
            Write-Host "Чтобы продолжить работу агентом с этой линией разработки, откройте отдельное окно Codex/Kilo/IDE в этой папке."
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
    Write-Host "Long lifecycle actions may run 1C Designer/Enterprise; agent shell timeout_ms must be >= 1800000."

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
                Write-VanessaTestStatusLines -State $state -Indent "    "
                Write-RoctupMcpStatusLines -State $state -Indent "    "
                Write-VanessaMcpStatusLines -State $state -Indent "    "
            }
        }
        Write-Host ""
        Write-Host "Next step: create a configuration or extension branch, then open the printed worktree folder."
    } elseif ($surface -eq "dev") {
        $openSpec = Get-AiRules1cKiloOpenSpecStatus
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
            $hasCheckableChanges = Test-DevBranchHasCheckableChanges -State $state

            Write-Host ""
            Write-Host "Branch:"
            Write-Host "  Name: $(Get-StateValue -State $state -Name 'devBranchName' -Default (Get-StateValue -State $state -Name 'safeDevBranchName' -Default '<unknown>'))"
            Write-Host "  Type: $kind"
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
            if ($hasCheckableChanges -or (@("failed", "stale", "unknown") -contains $verification.effectiveStatus)) {
                Write-Host "Recommended next step: /itl-check"
            } elseif (-not $verification.isFreshPassed) {
                if ($openSpec.isAvailable) {
                    Write-Host "Recommended next step: choose development mode: quick-fix, /opsx-explore, or /opsx-propose"
                } else {
                    Write-Host "Recommended next step: choose quick-fix, or restore Kilo OpenSpec commands from master before starting an OpenSpec change."
                }
            } elseif (-not (Get-StateValue -State $state -Name "lastResultPath" -Default "")) {
                Write-Host "Recommended next step: /itl-result"
            } else {
                Write-Host "Recommended next step: continue work and rerun /itl-check, or use /itl-result again when the artifact is ready."
            }
        }

        Write-Host ""
        Write-Host "Lifecycle:"
        if ($openSpec.isAvailable) {
            Write-Host "  optional /opsx-explore -> quick-fix or /opsx-propose -> /opsx-apply/work -> /itl-check -> /itl-result"
        } else {
            Write-Host "  quick-fix -> /itl-check -> /itl-result; restore Kilo OpenSpec commands before an OpenSpec change."
        }
        Write-Host "  use /itl-refresh when master changes must be merged into this branch."
        Write-Host ""
        Write-Host "ITL commands valid in this context:"
        Write-Host "  /itl"
        Write-Host "  /itl-status"
        Write-Host "  /itl-check"
        Write-Host "  /itl-refresh"
        Write-Host "  /itl-result"
        $inheritedPrimaryCommands = @(Get-KiloInheritedPrimaryItlCommands)
        if ($inheritedPrimaryCommands.Count -gt 0) {
            Write-Host ""
            Write-Host "Inherited by Kilo from primary checkout; invalid in this context:"
            foreach ($command in $inheritedPrimaryCommands) {
                Write-Host "  $command"
            }
        }
        Write-Host ""
        Write-Host "OpenSpec:"
        if ($openSpec.isAvailable) {
            Write-Host "  /opsx-propose  Start the normal OpenSpec flow: proposal, design/tasks/test-plan/spec deltas; no code changes."
            Write-Host "  /opsx-apply    Implement an approved OpenSpec change from tasks.md."
            Write-Host "  /opsx-archive  Archive an accepted OpenSpec change."
            Write-Host "  /opsx-explore  Optional: explore code or task boundaries before proposal when context is unclear."
        } else {
            Write-Host "  Kilo OpenSpec commands are unavailable: $($openSpec.reason)"
            Write-Host "  Recovery: in master run update-ai-rules or update-workflow, merge the update into this branch, then run /itl-refresh."
        }
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
