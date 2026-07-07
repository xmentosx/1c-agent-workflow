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
    $root = [System.IO.Path]::GetFullPath($script:ProjectRoot).TrimEnd("\")
    if (-not $resolved.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
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
    $path = Get-StateValue -State $State -Name "extensionExportPath" -Default ""
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

    $arguments = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $script:Agent1cScriptPath
    ) + @($script:Agent1cReexecArguments) + @($AdditionalArguments)

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

function Invoke-DevBranchEnterpriseAutoUpdate {
    param([object]$State)

    $epfPath = Ensure-DevBranchAutoUpdateEpfs
    Write-Host "Running development branch Enterprise auto-update: $epfPath"
    Invoke-Enterprise `
        -InfoBasePath $State.devBranchInfoBasePath `
        -InfoBaseKind $State.infoBaseKind `
        -EnterpriseArgs @("/Execute", $epfPath) | Out-Null

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

    $autoUpdateResult = Invoke-DevBranchEnterpriseAutoUpdate -State $State
    $Updates["lastEnterpriseAutoUpdateAt"] = $autoUpdateResult.updatedAt
    $Updates["lastEnterpriseAutoUpdateLogPath"] = $autoUpdateResult.logPath
    $Updates["lastEnterpriseAutoUpdateEpfPath"] = $autoUpdateResult.epfPath
    if ($autoUpdateResult.logPath) {
        $Updates["lastLogPath"] = $autoUpdateResult.logPath
    }
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
        [string]$ExtensionName = ""
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
        }
    }

    $listFilePath = New-ConfigLoadListFile -State $State -Files $changeSet.files
    Write-Host "Partial config load file count: $($changeSet.files.Count)"
    Write-Host "Partial config load list: $listFilePath"

    $designerArgs = @("/LoadConfigFromFiles", $changeSet.absoluteExportPath)
    if ($ExtensionName) {
        $designerArgs += @("-Extension", $ExtensionName)
    }
    $designerArgs += @("-listFile", $listFilePath, "-Format", "Hierarchical", "/UpdateDBCfg")

    Invoke-Designer `
        -InfoBasePath $InfoBasePath `
        -InfoBaseKind $InfoBaseKind `
        -DesignerArgs $designerArgs | Out-Null

    return [pscustomobject]@{
        loaded = $true
        fileCount = $changeSet.files.Count
        listFile = $listFilePath
        currentCommit = $changeSet.currentCommit
        lastLogPath = $script:LastLogPath
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
    $lockedEntry = Get-DependencyLockEntry -Name "aiRules1c"
    $tools = Get-ConfigValue -Path "aiRules.tools" -Default ""
    if (-not $tools) {
        $tools = Get-AgentTargets
    } elseif ($tools -is [string]) {
        $tools = @($tools.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }

    return @($tools)
}

function Sync-AiRules1cCheckout {
    $lockedEntry = Get-DependencyLockEntry -Name "aiRules1c"
    $repo = Get-ConfigValue -Path "aiRules.repo" -Default "https://github.com/comol/ai_rules_1c.git"
    $dependencyMode = Get-DependencyMode
    $lockedRef = ""
    $lockedCommit = ""
    if ($dependencyMode -eq "locked") {
        $lockedRepo = [string](Get-ConfigValueFromObject -Object $lockedEntry -Path "repo" -Default "")
        $lockedRef = [string](Get-ConfigValueFromObject -Object $lockedEntry -Path "ref" -Default "")
        $lockedCommit = [string](Get-ConfigValueFromObject -Object $lockedEntry -Path "commit" -Default "")
        if ($lockedRepo) {
            $repo = $lockedRepo
        }
        if (-not $lockedRef -and -not $lockedCommit) {
            throw "Dependency mode is locked, but aiRules1c.ref and aiRules1c.commit are empty in .agent-1c/dependency-lock.json."
        }
    }

    $rulesDir = Join-Path $env:TEMP "ai_rules_1c"

    if (Test-Path -LiteralPath $rulesDir) {
        try {
            Invoke-GitAt -Root $rulesDir -Arguments @("fetch", "--all", "--tags", "--prune")
        } catch {
            throw "Failed to update ai_rules_1c in $rulesDir"
        }
    } else {
        try {
            Invoke-GitAt -Root $env:TEMP -Arguments @("clone", $repo, $rulesDir)
        } catch {
            throw "Failed to clone ai_rules_1c from $repo"
        }
    }

    $resolvedRef = ""
    if ($dependencyMode -eq "locked") {
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
    }
}

function Invoke-AiRules1cInstaller {
    param(
        [ValidateSet("init", "update")]
        [string]$Command
    )

    $checkout = Sync-AiRules1cCheckout
    $rulesDir = [string]$checkout.root
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
        "-ProjectRoot", $script:ProjectRoot,
        "-Source", $rulesDir,
        "-AssumeYes"
    )
    if ($effectiveCommand -eq "init") {
        $installArgs += @("-Tools") + (Get-AiRules1cTools)
    } elseif ($Force) {
        $installArgs += @("-Force")
    }

    Push-Location $script:ProjectRoot
    try {
        & powershell -NoProfile -ExecutionPolicy Bypass -File $installScript @installArgs
        if ($LASTEXITCODE -ne 0) {
            throw "ai_rules_1c installer failed with exit code $LASTEXITCODE"
        }
    } finally {
        Pop-Location
    }

    Remove-AiRules1cManagedMcpConfig

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
    foreach ($serverId in $ServerIds) {
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
    $serverIds = Get-AiRules1cManagedMcpServerIds
    $removed = @()
    $removed += @(Remove-AiRules1cCodexMcpEntries -ServerIds $serverIds)
    $removed += @(Remove-AiRules1cKiloMcpEntries -ServerIds $serverIds)
    $removed = @($removed | Select-Object -Unique)

    if ($removed.Count -gt 0) {
        Write-Host "Removed ai_rules_1c default MCP client entries; ITL vibecoding1c MCP owns client config: $($removed -join ', ')."
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
    return (Join-Path (Join-Path $env:TEMP "1c-agent-workflow") "workflow-package")
}

function Test-GitRefExistsAt {
    param(
        [string]$Root,
        [string]$Ref
    )

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & git -C $Root show-ref --verify --quiet $Ref
        return ($LASTEXITCODE -eq 0)
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

function Assert-WorkflowPackageSourceRoot {
    param([string]$SourceRoot)

    foreach ($relativePath in @(
        "AGENT-INSTALL.md",
        ".agents\skills\1c-workflow\scripts\agent-1c.ps1",
        ".agents\skills\1c-workflow-fast\SKILL.md",
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
        $root = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($overridePath))
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

    $templateRoot = Join-Path $SourceRoot ".agents\skills\1c-workflow\kilo-command-templates"
    if (-not (Test-Path -LiteralPath $templateRoot -PathType Container -ErrorAction SilentlyContinue)) {
        throw "Workflow package Kilo command templates directory is missing: .agents\skills\1c-workflow\kilo-command-templates"
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

    foreach ($sourceDir in $sourceDirs) {
        if (-not (Test-Path -LiteralPath $sourceDir -PathType Container -ErrorAction SilentlyContinue)) {
            throw "Workflow package Kilo command template set is missing: $sourceDir"
        }
        foreach ($sourceFile in @(Get-ChildItem -LiteralPath $sourceDir -File -Filter "itl*.md" -ErrorAction Stop)) {
            Copy-Item -LiteralPath $sourceFile.FullName -Destination (Join-Path $targetDir $sourceFile.Name) -Force
        }
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
    Write-Host "  Refresh vibecoding1c MCP when needed:"
    Write-Host "    powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action vibecoding1c-mcp-update"
    Write-Host "    powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action vibecoding1c-mcp-setup"
    if ($states.Count -gt 0) {
        Write-Host "  Active development branches must merge the updated master intentionally:"
        foreach ($state in ($states | Sort-Object @{ Expression = { Get-StateValue -State $_ -Name "devBranchName" -Default "" } })) {
            $name = Get-StateValue -State $state -Name "devBranchName" -Default (Get-StateValue -State $state -Name "safeDevBranchName" -Default "<unknown>")
            $worktreePath = Get-StateValue -State $state -Name "worktreePath" -Default (Get-StateValue -State $state -Name "stateProjectRoot" -Default "")
            Write-Host "    $name -> $worktreePath"
        }
        Write-Host "  In each branch worktree, use refresh-dev-branch or merge master, then rerun vibecoding1c MCP setup/status for that scope."
        Write-Host "  If Vanessa MCP is used in a branch, run stop-vanessa-mcp, install-vanessa-mcp, then start-vanessa-mcp in that branch worktree."
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
    Assert-WorkflowPackageUpdateContext

    $source = Resolve-WorkflowPackageSource
    Assert-WorkflowSourceOutsideProject -SourceRoot $source.root

    Copy-WorkflowManagedDirectory -SourceRoot $source.root -RelativePath ".agents\skills\1c-workflow"
    Copy-WorkflowManagedDirectory -SourceRoot $source.root -RelativePath ".agents\skills\1c-workflow-fast"
    Copy-WorkflowManagedDirectory -SourceRoot $source.root -RelativePath "templates"
    foreach ($relativePath in @("README.md", "AGENT-INSTALL.md", "DEVELOPER-GUIDE.ru.md", "DEV-BRANCH-DEVELOPMENT.ru.md", "VANESSA-TESTS-GUIDE.ru.md")) {
        Copy-WorkflowManagedFile -SourceRoot $source.root -RelativePath $relativePath
    }

    Update-WorkflowPackageLockEntry -Source $source
    Ensure-GitIgnore
    Sync-KiloItlCommandSurface
    Update-AgentGuidanceBridge
    Update-UserRules

    if ($SkipAiRules) {
        Write-Host "Skipping ai_rules_1c update because -SkipAiRules was specified."
    } else {
        Update-AiRules1c
    }

    Write-Host "ITL workflow package updated from $($source.source): $($source.root)"
    if ($source.commit) {
        Write-Host "Workflow package commit: $($source.commit)"
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

    $projectName = Split-Path -Leaf $ProjectRootForFolder
    return "/ITL/" + (ConvertTo-LauncherLabel -Value $projectName)
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
    $displayName = ConvertTo-LauncherLabel -Value $DevBranchName
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

    $id = if ($target -and $target.values.ContainsKey("ID") -and $target.values["ID"]) { $target.values["ID"] } else { [guid]::NewGuid().ToString() }
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

function Get-DevBranchUnsafeActionProtectionSetup {
    $value = (Get-Setting -EnvName "DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP" -ConfigName "devBranchUnsafeActionProtectionSetup" -Default "manual-confirm").Trim().ToLowerInvariant()
    if ($value -notin @("manual-confirm", "skip")) {
        throw "Unsupported DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP value: $value. Use manual-confirm or skip."
    }

    return $value
}

function Confirm-DevBranchUnsafeActionProtection {
    param(
        [string]$InfoBaseKind,
        [string]$InfoBasePath,
        [string]$DevBranchName
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

    $mode = Get-DevBranchUnsafeActionProtectionSetup
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

        $answer = (Read-Host (Get-UnsafeActionProtectionMessage 8)).Trim()
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

function Publish-DevBranchToApache {
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
    Require-Value "Apache publication root from autodetect or WEB_PUBLICATION_ROOT override" $publicationRoot | Out-Null

    if (-not (Test-Path -LiteralPath $webInstPath)) {
        throw "webinst.exe was not found: $webInstPath"
    }
    if (-not ($apacheSettings.apacheFound -or $apacheSettings.manualPublicationRoot)) {
        throw "Apache was not detected. Run detect-apache, install/configure Apache, or set APACHE_HTTPD_CONF_PATH for a nonstandard installation."
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

function Initialize-Project {
    Write-Section "Initialize project"
    New-Item -ItemType Directory -Force -Path $script:ProjectRoot | Out-Null
    Write-Host "Project root: $script:ProjectRoot"
    if ($InitMode -eq "wizard" -and [string]::IsNullOrWhiteSpace($RunStatusPath)) {
        Write-Host "WARNING: direct init-project wizard is not monitored. Agent-run initialization must use scripts/run-agent-1c-window.ps1 so the agent waits for completion and reads status.json. Use the direct wizard only for manual debugging."
    }
    if ($InitMode -eq "wizard" -or $InitMode -eq "json") {
        Prepare-InitProjectSettings
    } else {
        Prepare-ConfiguredInitProjectSettings
    }
    Check-Tools -StopOnMissing
    Get-DevBranchInfoBaseRoot | Out-Null
    Ensure-GitRepository
    Ensure-GitIgnore
    Checkout-Master

    $sourceUsesRepository = Get-SourceUsesRepository
    Update-BaseFromRepository
    $dumpResult = Dump-ConfigToFiles
    $dumpMessage = if ($sourceUsesRepository) { "sync: export 1C configuration from repository" } else { "sync: export 1C configuration from source infobase" }
    Commit-IfChanged -Message $dumpMessage -PathSpec @($dumpResult.exportPath) -RequireChanges -ForceAdd | Out-Null
    Assert-BaselineDumpCommitted -ExportPath $dumpResult.exportPath

    Install-AiRules1c
    Update-AgentGuidanceBridge
    Update-UserRules
    Sync-KiloItlCommandSurface
    Commit-IfChanged "chore: install 1C agent workflow"
    if ($script:InitVibecoding1cMcpSetupRequested -or (ConvertTo-YesNoBool -Value (Get-EnvValue -Name "VIBECODING1C_MCP_SETUP_DURING_INIT" -Default $false) -Default $false)) {
        Setup-Vibecoding1cMcp
    } else {
        Write-Host "vibecoding1c MCP setup was deferred. Ask the agent to configure vibecoding1c MCP, or run -Action vibecoding1c-mcp-setup when needed."
    }
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

    if ($kind -eq "file") {
        if (Test-Path -LiteralPath $DevBranchInfoBasePath) {
            throw "Development branch infobase path already exists: $DevBranchInfoBasePath"
        }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $DevBranchInfoBasePath) | Out-Null
        Copy-Item -LiteralPath $source -Destination $DevBranchInfoBasePath -Recurse
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

    $repositoryUnbound = $false
    if ($sourceUsesRepository) {
        Invoke-Designer `
            -InfoBasePath $DevBranchInfoBasePath `
            -InfoBaseKind $kind `
            -DesignerArgs @("/ConfigurationRepositoryUnbindCfg", "-force") | Out-Null
        $repositoryUnbound = $true
    } else {
        Write-Host "Source infobase is configured without repository connection. Skipping repository unbind for development branch copy."
    }

    $unsafeActionProtectionSetup = Confirm-DevBranchUnsafeActionProtection `
        -InfoBaseKind $kind `
        -InfoBasePath $DevBranchInfoBasePath `
        -DevBranchName $DevBranchName

    $launcherRegistration = Register-DevBranchInLauncher `
        -InfoBaseKind $kind `
        -InfoBasePath $DevBranchInfoBasePath `
        -DevBranchName $DevBranchName `
        -ProjectRootForFolder $MainProjectRoot

    $publishDefault = Get-WebPublishByDefault
    $publicationUrl = ""
    $publicationName = ""
    $publicationDir = ""
    if ($PublishToApache -or $publishDefault) {
        $publication = Publish-DevBranchToApache -DevBranchPath $DevBranchInfoBasePath -SafeDevBranchName $SafeDevBranchName
        $publicationUrl = [string]$publication.url
        $publicationName = [string]$publication.publicationName
        $publicationDir = [string]$publication.publicationDir
    }

    $statePath = Save-DevBranchState -SafeDevBranchName $SafeDevBranchName -State @{
        devBranchName = $DevBranchName
        safeDevBranchName = $SafeDevBranchName
        devBranchKind = $DevBranchKind
        devBranch = $GitBranch
        createdWithWorktree = $CreatedWithWorktree
        worktreePath = $WorktreePath
        mainWorktreePath = $MainProjectRoot
        createdFromCommit = Get-CurrentCommit
        lastConfigBaseUpdatedCommit = Get-CurrentCommit
        infoBaseKind = $kind
        devBranchInfoBasePath = $DevBranchInfoBasePath
        sourceUsesRepository = $sourceUsesRepository
        repositoryUnbound = $repositoryUnbound
        launcherRegistered = $launcherRegistration.registered
        launcherInfoBaseName = $launcherRegistration.name
        launcherFolder = $launcherRegistration.folder
        launcherInfoBaseId = $launcherRegistration.id
        launcherListPath = $launcherRegistration.listPath
        publicationUrl = $publicationUrl
        publicationName = $publicationName
        publicationDir = $publicationDir
        unsafeActionProtectionSetupMode = $unsafeActionProtectionSetup.mode
        unsafeActionProtectionConfirmed = $unsafeActionProtectionSetup.confirmed
        unsafeActionProtectionConfirmedAt = $unsafeActionProtectionSetup.confirmedAt
        unsafeActionProtectionUser = $unsafeActionProtectionSetup.user
        createdAt = (Get-Date).ToString("o")
        lastLogPath = $script:LastLogPath
    }

    Write-Host "Development branch: $GitBranch"
    if ($CreatedWithWorktree) {
        Write-Host "Development branch worktree: $WorktreePath"
        Write-Host "Main project worktree: $MainProjectRoot"
    }
    Write-Host "Development branch infobase: $DevBranchInfoBasePath"
    Write-Host "Development branch state: $statePath"
    Write-Host "1C launcher infobase: $($launcherRegistration.name)"
    Write-Host "1C launcher folder: $($launcherRegistration.folder)"
    if ($publicationUrl) {
        Write-Host "Publication URL: $publicationUrl"
    }
    $state = Read-DevBranchStateFile -Path $statePath
    if ($publicationUrl) {
        $dataMcpUpdates = Install-DevBranchDataMcpBestEffort -State $state -PublicationUrl $publicationUrl -PublicationDir $publicationDir
        if ($dataMcpUpdates.Count -gt 0) {
            Update-DevBranchState -State $state -Updates $dataMcpUpdates
            $state = Read-DevBranchStateFile -Path $statePath
        }
    }
    $state = Initialize-DevBranchEventLogBaseline -State $state
    Sync-DevBranchContextToDotEnv -State $state -AllowIncompleteExtension
    Sync-KiloItlCommandSurface
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
    Checkout-Master

    if (Test-GitBranchExists -Branch $DevBranch) {
        throw "Development branch already exists: $DevBranch"
    }

    $mainProjectRoot = Get-MainWorktreePath
    if ($UseCurrentWorktree) {
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
}

function Set-DevBranchExtension {
    $state = Read-DevBranchState -Name $DevBranchName
    Assert-DevelopmentBranchWorktreeContext -State $state -Operation "set-dev-branch-extension"
    Assert-DevBranchKind -State $state -Expected "extension"
    Require-Value "ExtensionName" $ExtensionName | Out-Null

    $existing = Get-StateValue -State $state -Name "extensionName" -Default ""
    if ($existing -and $existing -ne $ExtensionName -and -not $Force) {
        throw "Extension name is already set to '$existing'. Pass -Force to overwrite it."
    }

    $safeExtensionName = ConvertTo-SafeName $ExtensionName
    $extensionExportPath = Get-ExtensionExportPath -SafeExtensionName $safeExtensionName
    $updates = @{
        extensionName = $ExtensionName
        safeExtensionName = $safeExtensionName
        extensionExportPath = $extensionExportPath
    }
    Add-VerificationStaleIfNeeded -State $state -Updates $updates -Reason "Extension settings changed." -Force
    Update-DevBranchState -State $state -Updates $updates
    $updatedState = Read-DevBranchState -Name $DevBranchName
    Sync-DevBranchContextToDotEnv -State $updatedState

    Write-Host "Development branch extension: $ExtensionName"
    Write-Host "Extension files path: $extensionExportPath"
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
        $loadResult = Load-ConfigFromFiles -InfoBasePath $state.devBranchInfoBasePath -InfoBaseKind $state.infoBaseKind -State $state -ExportPath $extensionExportPath -ContentKind "extension" -ExtensionName $extensionName
        $updates = New-LoadStateUpdates -LoadResult $loadResult -ContentKind "extension"
        Invoke-DevBranchEnterpriseAutoUpdateIfLoaded -State $state -LoadResult $loadResult -Updates $updates
        Add-VerificationStaleIfNeeded -State $state -Updates $updates -Reason "Development branch extension base was updated." -CurrentCommit $loadResult.currentCommit
        Update-DevBranchState -State $state -Updates $updates
        $updatedState = Read-DevBranchState -Name $DevBranchName
        Write-BaseUpdateResult -State $updatedState -LoadResult $loadResult -Label "Development branch extension"
    } else {
        $loadResult = Load-ConfigFromFiles -InfoBasePath $state.devBranchInfoBasePath -InfoBaseKind $state.infoBaseKind -State $state -ExportPath (Get-ExportPath) -ContentKind "configuration"
        $updates = New-LoadStateUpdates -LoadResult $loadResult -ContentKind "configuration"
        Invoke-DevBranchEnterpriseAutoUpdateIfLoaded -State $state -LoadResult $loadResult -Updates $updates
        Add-VerificationStaleIfNeeded -State $state -Updates $updates -Reason "Development branch configuration base was updated." -CurrentCommit $loadResult.currentCommit
        Update-DevBranchState -State $state -Updates $updates
        $updatedState = Read-DevBranchState -Name $DevBranchName
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
        $beforeMergeCommit = Get-CurrentCommit
        Invoke-Git @("merge", (Get-MasterBranch))
        Restart-Agent1cIfWorkflowHelperChangedSince -BeforeCommit $beforeMergeCommit -AdditionalArguments @("-LifecyclePhase", "post-merge")
        Restart-Agent1cAfterDevBranchMerge -Operation "refresh-dev-branch"
    }

    Sync-DevBranchContextToDotEnv -State $state -AllowIncompleteExtension
    $loadResult = Load-ConfigFromFiles -InfoBasePath $state.devBranchInfoBasePath -InfoBaseKind $state.infoBaseKind -State $state -ExportPath (Get-ExportPath) -ContentKind "configuration"
    $updates = New-LoadStateUpdates -LoadResult $loadResult -ContentKind "configuration"
    Invoke-DevBranchEnterpriseAutoUpdateIfLoaded -State $state -LoadResult $loadResult -Updates $updates
    $updates["lastRefreshAt"] = (Get-Date).ToString("o")
    Add-VerificationStaleIfNeeded -State $state -Updates $updates -Reason "Development branch was refreshed from master." -CurrentCommit $loadResult.currentCommit
    Update-DevBranchState -State $state -Updates $updates
    $updatedState = Read-DevBranchState -Name $DevBranchName
    Write-Host "Development branch refreshed from master: $($state.devBranch)"
    Write-BaseUpdateResult -State $updatedState -LoadResult $loadResult -Label "Development branch configuration"
    if ((Get-DevBranchKind -State $state) -eq "extension") {
        Write-Host "Extension files were not loaded during refresh. Run update-dev-branch-base when you need to update the extension in the branch infobase."
    }
    Sync-KiloItlCommandSurface
}

function Dump-DevBranchExtension {
    $state = Read-DevBranchState -Name $DevBranchName
    Assert-DevelopmentBranchWorktreeContext -State $state -Operation "dump-dev-branch-extension"
    $dumpResult = Dump-ExtensionToFiles -State $state
    $updates = @{
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

function Show-WorkflowStatus {
    Write-Section "ITL status"

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
                Write-VanessaTestStatusLines -State $state -Indent "    "
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
    $mainWorktreePath = Get-StateValue -State $state -Name "mainWorktreePath" -Default ""
    if ($mainWorktreePath) {
        Write-Host "Main worktree: $mainWorktreePath"
    }
    $safeDevBranchName = Get-StateValue -State $state -Name "safeDevBranchName" -Default "<unknown>"
    Write-Host "Development branch name: $(Get-StateValue -State $state -Name 'devBranchName' -Default $safeDevBranchName)"
    Write-Host "Type: $kind"
    if ($kind -eq "extension") {
        Write-Host "Extension: $(Get-StateValue -State $state -Name 'extensionName' -Default '<not set>')"
        Write-Host "Extension files: $(Get-StateValue -State $state -Name 'extensionExportPath' -Default '<not set>')"
    }
    Write-Host "Infobase: $($state.devBranchInfoBasePath)"
    $publicationUrl = Get-StateValue -State $state -Name "publicationUrl" -Default ""
    if ($publicationUrl) {
        Write-Host "Publication URL: $publicationUrl"
    }
    Write-DataMcpStatusLines -State $state
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
        $loadResult = Load-ConfigFromFiles -InfoBasePath $state.devBranchInfoBasePath -InfoBaseKind $state.infoBaseKind -State $state -ExportPath $extensionExportPath -ContentKind "extension" -ExtensionName $extensionName
    } else {
        $loadResult = Load-ConfigFromFiles -InfoBasePath $state.devBranchInfoBasePath -InfoBaseKind $state.infoBaseKind -State $state -ExportPath (Get-ExportPath) -ContentKind "configuration"
    }
    $devBranchCommit = Get-CurrentCommit
    $masterCommit = Get-GitCommitOrEmpty (Get-MasterBranch)
    $updates = New-LoadStateUpdates -LoadResult $loadResult -ContentKind $kind
    Invoke-DevBranchEnterpriseAutoUpdateIfLoaded -State $state -LoadResult $loadResult -Updates $updates
    Add-VerificationStaleIfNeeded -State $state -Updates $updates -Reason "Development branch base was updated before result export." -CurrentCommit $loadResult.currentCommit
    Update-DevBranchState -State $state -Updates $updates
    $state = Read-DevBranchState -Name $DevBranchName
    $unverifiedOverride = Confirm-UnverifiedProceed -State $state -Operation "export-dev-branch-result" -Allow:$AllowUnverifiedResult

    $resultPath = Export-DevBranchResultFile -State $state -InfoBasePath $state.devBranchInfoBasePath -InfoBaseKind $state.infoBaseKind -ContentKind $kind
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
    Stop-VanessaMcpForState -State $state -Quiet | Out-Null
    $state = Read-DevBranchState -Name $DevBranchName
    Sync-DevBranchContextToDotEnv -State $state

    if ($LifecyclePhase -ne "post-merge") {
        Assert-CleanGit
        Sync-Master
        if ((Get-CurrentBranch) -ne $state.devBranch) {
            Invoke-Git @("checkout", $state.devBranch)
        }
        $beforeMergeCommit = Get-CurrentCommit
        Invoke-Git @("merge", (Get-MasterBranch))
        Restart-Agent1cIfWorkflowHelperChangedSince -BeforeCommit $beforeMergeCommit -AdditionalArguments @("-LifecyclePhase", "post-merge")
        Restart-Agent1cAfterDevBranchMerge -Operation "close-dev-branch"
    }

    Sync-DevBranchContextToDotEnv -State $state

    $kind = Get-DevBranchKind -State $state
    $configLoadResult = Load-ConfigFromFiles -InfoBasePath $state.devBranchInfoBasePath -InfoBaseKind $state.infoBaseKind -State $state -ExportPath (Get-ExportPath) -ContentKind "configuration"
    $updates = New-LoadStateUpdates -LoadResult $configLoadResult -ContentKind "configuration"
    Invoke-DevBranchEnterpriseAutoUpdateIfLoaded -State $state -LoadResult $configLoadResult -Updates $updates
    Add-VerificationStaleIfNeeded -State $state -Updates $updates -Reason "Development branch was refreshed and updated before close." -CurrentCommit $configLoadResult.currentCommit
    if ($kind -eq "extension") {
        $extensionName = Require-DevBranchExtensionName -State $state
        $extensionExportPath = Assert-ExtensionFilesReady -State $state
        $extensionLoadResult = Load-ConfigFromFiles -InfoBasePath $state.devBranchInfoBasePath -InfoBaseKind $state.infoBaseKind -State $state -ExportPath $extensionExportPath -ContentKind "extension" -ExtensionName $extensionName
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

    $resultPath = Export-DevBranchResultFile -State $state -InfoBasePath $state.devBranchInfoBasePath -InfoBaseKind $state.infoBaseKind -ContentKind $kind

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
        }
        Write-DataMcpStatusLines -State $state -Indent "  "
        Write-VanessaTestStatusLines -State $state -Indent "  "
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

function Detect-Apache {
    Write-Section "Detect Apache"
    $settings = Get-EffectiveApacheSettings

    if ($settings.webInstOk) {
        Write-Host "[OK] webinst.exe: $($settings.webInstPath)"
    } elseif ($settings.webInstPath) {
        Write-Host "[MISSING] webinst.exe was configured or derived but does not exist: $($settings.webInstPath)"
    } else {
        Write-Host "[MISSING] webinst.exe was not found next to PLATFORM_PATH and WEBINST_PATH is not set."
    }

    if ($settings.apacheFound) {
        Write-Host "[OK] Apache config: $($settings.httpdConfPath)"
        Write-Host "Source: $($settings.apacheSource)"
        Write-Host "DocumentRoot: $($settings.documentRoot)"
        Write-Host "Listen port: $($settings.listenPort)"
    } elseif ($settings.manualPublicationRoot) {
        Write-Host "[OK] Apache publication root is set manually: $($settings.publicationRoot)"
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
        throw "Apache publication is not ready. Run helper action install-apache after explicit developer confirmation, or install/configure Apache 2.4 manually and make sure webinst.exe exists next to 1cv8.exe, then rerun detect-apache."
    }
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

    if ($surface -eq "master") {
        Write-Host ""
        Write-Host "Lifecycle:"
        Write-Host "  master -> create branch -> open worktree -> work -> check -> result"
        Write-Host ""
        Write-Host "Visible slash commands in this folder:"
        Write-Host "  /itl"
        Write-Host "  /itl-status"
        Write-Host "  /itl-new-config-branch <name>"
        Write-Host "  /itl-new-extension-branch <name>"
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
            }
        }
        Write-Host ""
        Write-Host "Next step: create a configuration or extension branch, then open the printed worktree folder."
    } elseif ($surface -eq "dev") {
        $state = $null
        try {
            $state = Read-DevBranchState -Name ""
        } catch {
            Write-Host "Development branch state: missing"
            Write-Host "Next step: run /itl-status, then open the worktree recorded for this branch if it exists."
        }

        Write-Host ""
        Write-Host "Lifecycle:"
        Write-Host "  work -> /itl-check -> /itl-refresh when needed -> /itl-result"
        Write-Host ""
        Write-Host "Visible slash commands in this folder:"
        Write-Host "  /itl"
        Write-Host "  /itl-status"
        Write-Host "  /itl-check"
        Write-Host "  /itl-refresh"
        Write-Host "  /itl-result"
        Write-Host ""
        Write-Host "OpenSpec:"
        Write-Host "  /opsx-propose  Start the normal OpenSpec flow: proposal, design/tasks/test-plan/spec deltas; no code changes."
        Write-Host "  /opsx-apply    Implement an approved OpenSpec change from tasks.md."
        Write-Host "  /opsx-archive  Archive an accepted OpenSpec change."
        Write-Host "  /opsx-explore  Optional: explore code or task boundaries before proposal when context is unclear."

        if ($state) {
            $verification = Get-VerificationState -State $state
            $kind = Get-DevBranchKind -State $state
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
            if ($verification.reportPath) {
                Write-Host "  Report: $($verification.reportPath)"
            }
            Write-Host "  Last result: $(Get-StateValue -State $state -Name 'lastResultPath' -Default '<none>')"
            Write-Host "  Final result: $(Get-StateValue -State $state -Name 'finalResultPath' -Default '<none>')"
            Write-Host ""
            if (-not $verification.isFreshPassed) {
                Write-Host "Recommended next step: /itl-check"
            } elseif (-not (Get-StateValue -State $state -Name "lastResultPath" -Default "")) {
                Write-Host "Recommended next step: /itl-result"
            } else {
                Write-Host "Recommended next step: continue work and rerun /itl-check, or use /itl-result again when the artifact is ready."
            }
        }
    } else {
        Write-Host ""
        Write-Host "Lifecycle:"
        Write-Host "  Open the master worktree to create branches, or open an itldev/* worktree to check/result work."
        Write-Host ""
        Write-Host "Visible slash commands in this folder:"
        Write-Host "  /itl"
        Write-Host "  /itl-status"
        Write-Host ""
        Write-Host "Next step: run /itl-status to inspect this folder, then open the correct worktree."
    }

    Write-Host ""
    Write-Host "Rare actions:"
    Write-Host "  Ask the agent in natural language for vibecoding1c MCP setup/status, branch-local Vanessa MCP, extension setup/dump, marking a branch closed, workflow updates, or rule updates."
    Write-Host "  The full helper action catalog is documented in .agents/skills/1c-workflow/references/advanced-actions.md."
}
