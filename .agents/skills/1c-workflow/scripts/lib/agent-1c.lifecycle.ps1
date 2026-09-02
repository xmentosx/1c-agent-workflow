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

    $updateMode = Get-SourceRepositoryUpdateMode
    if ($updateMode -eq "external") {
        Write-Host "Source repository update skipped by external mode; master dump uses current source infobase state."
        Write-Host "ITL will not run /ConfigurationRepositoryUpdateCfg or /UpdateDBCfg against the source infobase."
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

function Write-SourceRepositoryUpdateModeStatus {
    $state = Get-SourceRepositoryUpdateModeState
    $suffix = if ($state.valid) { "" } else { " (invalid; source synchronization is blocked)" }
    Write-Host "SOURCE_REPOSITORY_UPDATE_MODE=$($state.effective)$suffix"
    Write-Host "SOURCE_USES_REPOSITORY=$((Get-SourceUsesRepository).ToString().ToLowerInvariant())"
}

function Set-SourceRepositoryUpdateMode {
    param([string]$Mode)

    Assert-MasterWorktreeContext -Operation "itl-repository-mode"
    $normalized = $Mode.Trim().ToLowerInvariant()
    if (-not $normalized -or $normalized -eq "status") {
        Write-SourceRepositoryUpdateModeStatus
        return
    }
    if ($normalized -notin @("workflow", "external")) {
        throw "itl-repository-mode supports: workflow|external|status."
    }

    Set-DotEnvValues -Values @{ SOURCE_REPOSITORY_UPDATE_MODE = $normalized }
    Import-DotEnv -Path (Join-Path $script:ProjectRoot ".dev.env") -Overwrite
    Write-Host "Source repository update mode changed: $normalized"
    Write-SourceRepositoryUpdateModeStatus
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

function Get-GitBlobBytesBatch {
    param([string[]]$ObjectIds)

    $uniqueObjectIds = @($ObjectIds | Where-Object { $_ } | Sort-Object -Unique)
    $result = @{}
    if ($uniqueObjectIds.Count -eq 0) {
        return $result
    }
    foreach ($objectId in $uniqueObjectIds) {
        if ($objectId -notmatch '^[a-f0-9]{40,64}$') {
            throw "GIT_BLOB_OBJECT_ID_INVALID: $objectId"
        }
    }

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = "git"
    $startInfo.Arguments = Join-NativeCommandLineArguments -Arguments @("-C", $script:ProjectRoot, "cat-file", "--batch")
    $startInfo.WorkingDirectory = $script:ProjectRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $started = $false
    try {
        if (-not $process.Start()) {
            throw "Cannot start git cat-file --batch."
        }
        $started = $true
        $request = [System.Text.Encoding]::ASCII.GetBytes(($uniqueObjectIds -join "`n") + "`n")
        $process.StandardInput.BaseStream.Write($request, 0, $request.Length)
        $process.StandardInput.BaseStream.Flush()
        $process.StandardInput.Close()

        $output = $process.StandardOutput.BaseStream
        foreach ($objectId in $uniqueObjectIds) {
            $headerBytes = [System.Collections.Generic.List[byte]]::new()
            while ($true) {
                $value = $output.ReadByte()
                if ($value -lt 0) {
                    throw "Unexpected end of git cat-file output while reading '$objectId'."
                }
                if ($value -eq 10) { break }
                $headerBytes.Add([byte]$value)
            }
            $header = [System.Text.Encoding]::ASCII.GetString($headerBytes.ToArray())
            if ($header -notmatch '^(?<actual>[a-f0-9]{40,64}) blob (?<size>[0-9]+)$' -or $Matches["actual"] -cne $objectId) {
                throw "Unexpected git cat-file header for '$objectId': $header"
            }
            $size = [int64]$Matches["size"]
            if ($size -gt [int]::MaxValue) {
                throw "Git blob is too large to inspect for line endings: object='$objectId' size='$size'."
            }
            $bytes = New-Object byte[] ([int]$size)
            $offset = 0
            while ($offset -lt $bytes.Length) {
                $read = $output.Read($bytes, $offset, $bytes.Length - $offset)
                if ($read -le 0) {
                    throw "Unexpected end of git cat-file blob '$objectId' at byte $offset of $size."
                }
                $offset += $read
            }
            if ($output.ReadByte() -ne 10) {
                throw "Git cat-file blob '$objectId' was not followed by the expected delimiter."
            }
            $result[$objectId] = $bytes
        }

        $process.WaitForExit()
        $stderr = $process.StandardError.ReadToEnd()
        if ($process.ExitCode -ne 0) {
            throw "git cat-file --batch failed with exit code $($process.ExitCode): $stderr"
        }
    } finally {
        if ($started -and -not $process.HasExited) {
            try { $process.Kill() } catch {}
        }
        $process.Dispose()
    }
    return $result
}

function Get-OneCSourceLineEndingStyle {
    param([byte[]]$Bytes)

    if ($null -eq $Bytes -or $Bytes.Length -eq 0) { return "none" }
    $lineFeeds = 0
    $carriageReturnLineFeeds = 0
    $loneCarriageReturns = 0
    for ($index = 0; $index -lt $Bytes.Length; $index++) {
        if ($Bytes[$index] -eq 0) { return "binary" }
        if ($Bytes[$index] -eq 10) {
            $lineFeeds++
            if ($index -gt 0 -and $Bytes[$index - 1] -eq 13) {
                $carriageReturnLineFeeds++
            }
        } elseif ($Bytes[$index] -eq 13 -and ($index + 1 -ge $Bytes.Length -or $Bytes[$index + 1] -ne 10)) {
            $loneCarriageReturns++
        }
    }
    if ($lineFeeds -eq 0) { return $(if ($loneCarriageReturns -eq 0) { "none" } else { "mixed" }) }
    if ($loneCarriageReturns -eq 0 -and $carriageReturnLineFeeds -eq $lineFeeds) { return "crlf" }
    if ($loneCarriageReturns -eq 0 -and $carriageReturnLineFeeds -eq 0) { return "lf" }
    return "mixed"
}

function Convert-OneCSourceLineEndings {
    param(
        [byte[]]$Bytes,
        [ValidateSet("crlf", "lf")][string]$Style
    )

    $carriageReturnLineFeeds = 0
    $bareLineFeeds = 0
    for ($index = 0; $index -lt $Bytes.Length; $index++) {
        if ($Bytes[$index] -ne 10) { continue }
        if ($index -gt 0 -and $Bytes[$index - 1] -eq 13) {
            $carriageReturnLineFeeds++
        } else {
            $bareLineFeeds++
        }
    }

    $targetLength = if ($Style -eq "crlf") {
        $Bytes.Length + $bareLineFeeds
    } else {
        $Bytes.Length - $carriageReturnLineFeeds
    }
    $result = New-Object byte[] $targetLength
    $targetIndex = 0
    for ($index = 0; $index -lt $Bytes.Length; $index++) {
        $value = $Bytes[$index]
        if ($Style -eq "crlf" -and $value -eq 10 -and ($index -eq 0 -or $Bytes[$index - 1] -ne 13)) {
            $result[$targetIndex] = 13
            $targetIndex++
        }
        if ($Style -eq "lf" -and $value -eq 13 -and $index + 1 -lt $Bytes.Length -and $Bytes[$index + 1] -eq 10) {
            continue
        }
        $result[$targetIndex] = $value
        $targetIndex++
    }
    return ,$result
}

function Repair-OneCSourceLineEndings {
    param(
        [string[]]$SourcePaths = @((Get-ExportPath), (Get-ExtensionsPath), "src/configs"),
        [string]$ReferenceCommit = "",
        [string[]]$CandidatePaths = @(),
        [switch]$StageChanges
    )

    try {
        if (-not $ReferenceCommit) {
            $ReferenceCommit = Get-GitCommitOrEmpty (Get-MasterBranch)
        }
        if ($ReferenceCommit -notmatch '^[a-f0-9]{40,64}$' -or -not (Test-GitCommitExists -Commit $ReferenceCommit)) {
            return @()
        }
    } catch {
        return @()
    }

    $normalizedSourcePaths = @(
        $SourcePaths |
            Where-Object { $_ } |
            ForEach-Object { ([string]$_).Replace("\", "/").Trim("/") } |
            Where-Object { $_ } |
            Sort-Object -Unique
    )
    if ($normalizedSourcePaths.Count -eq 0) { return @() }

    $paths = if (@($CandidatePaths).Count -gt 0) {
        @($CandidatePaths)
    } else {
        @(
            @(Get-GitPathList -Arguments (@("diff", "--name-only", "-z", "--diff-filter=ACMRTUXBD", $ReferenceCommit, "--") + $normalizedSourcePaths))
            @(Get-GitPathList -Arguments (@("ls-files", "-z", "--others", "--exclude-standard", "--") + $normalizedSourcePaths))
        )
    }
    $paths = @(
        $paths |
            ForEach-Object { ([string]$_).Replace("\", "/").TrimStart("/") } |
            Where-Object {
                $repoPath = $_
                $extension = [System.IO.Path]::GetExtension($repoPath)
                $leaf = [System.IO.Path]::GetFileName($repoPath)
                $underSource = @($normalizedSourcePaths | Where-Object {
                    $repoPath -ceq $_ -or $repoPath.StartsWith($_ + "/", [System.StringComparison]::Ordinal)
                }).Count -gt 0
                $underSource -and $leaf -ine "ConfigDumpInfo.xml" -and $extension -in @(".bsl", ".xml")
            } |
            Sort-Object -Unique
    )
    if ($paths.Count -eq 0) { return @() }

    $objectIdByPath = @{}
    $pathBatchSize = 64
    for ($offset = 0; $offset -lt $paths.Count; $offset += $pathBatchSize) {
        $lastIndex = [Math]::Min($offset + $pathBatchSize - 1, $paths.Count - 1)
        $pathBatch = @($paths[$offset..$lastIndex])
        foreach ($entry in @(Get-GitPathList -Arguments (@("ls-tree", "-z", $ReferenceCommit, "--") + $pathBatch))) {
            if ($entry -match "^[0-9]{6} blob (?<objectId>[a-f0-9]{40,64})`t(?<path>.*)$") {
                $repoPath = [string]$Matches["path"]
                if ($paths -ccontains $repoPath) {
                    $objectIdByPath[$repoPath] = [string]$Matches["objectId"]
                }
            }
        }
    }
    if ($objectIdByPath.Count -eq 0) { return @() }
    $blobBytesByObjectId = Get-GitBlobBytesBatch -ObjectIds @($objectIdByPath.Values)

    $projectRoot = (Resolve-Agent1cFullPath -Path $script:ProjectRoot).TrimEnd("\", "/")
    $repaired = [System.Collections.Generic.List[string]]::new()
    foreach ($repoPath in $paths) {
        if (-not $objectIdByPath.ContainsKey($repoPath)) { continue }
        $absolutePath = Resolve-Agent1cFullPath -Path (Join-Path $projectRoot ($repoPath.Replace("/", "\")))
        if (-not $absolutePath.StartsWith($projectRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase) -or
            -not (Test-Path -LiteralPath $absolutePath -PathType Leaf -ErrorAction SilentlyContinue)) {
            continue
        }
        $objectId = [string]$objectIdByPath[$repoPath]
        if (-not $blobBytesByObjectId.ContainsKey($objectId)) { continue }
        $referenceBytes = [byte[]]$blobBytesByObjectId[$objectId]
        $referenceStyle = Get-OneCSourceLineEndingStyle -Bytes $referenceBytes
        if ($referenceStyle -notin @("crlf", "lf")) { continue }

        $currentBytes = [System.IO.File]::ReadAllBytes($absolutePath)
        $currentStyle = Get-OneCSourceLineEndingStyle -Bytes $currentBytes
        if ($currentStyle -in @("binary", "none") -or $currentStyle -eq $referenceStyle) { continue }
        $normalizedBytes = Convert-OneCSourceLineEndings -Bytes $currentBytes -Style $referenceStyle
        $temporaryPath = "$absolutePath.itl-eol-$PID-$([guid]::NewGuid().ToString('N')).tmp"
        try {
            [System.IO.File]::WriteAllBytes($temporaryPath, $normalizedBytes)
            Move-Item -LiteralPath $temporaryPath -Destination $absolutePath -Force
        } finally {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
        $repaired.Add($repoPath) | Out-Null
    }

    if ($repaired.Count -gt 0) {
        if ($StageChanges) {
            Invoke-Git (@("add", "--") + @($repaired))
        }
        $shortReference = $ReferenceCommit.Substring(0, [Math]::Min(9, $ReferenceCommit.Length))
        Write-Host "Normalized line endings in $($repaired.Count) changed 1C source file(s) to match reference commit $shortReference."
    }
    return @($repaired)
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
        if ([bool](Get-StateValue -State $configChangeSet -Name "requiresFullLoad" -Default $false) -or @($configChangeSet.files).Count -gt 0) {
            return $true
        }
    } catch {
    }

    if ((Get-DevBranchKind -State $State) -eq "extension") {
        try {
            $extensionExportPath = Get-DevBranchExtensionExportPath -State $State
            $extensionChangeSet = Get-ConfigLoadChangeSet -State $State -ExportPath $extensionExportPath -ContentKind "extension"
            if ([bool](Get-StateValue -State $extensionChangeSet -Name "requiresFullLoad" -Default $false) -or @($extensionChangeSet.files).Count -gt 0) {
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

    $changed = @(Get-GitPathList -Arguments @("diff", "--name-only", "-z", $BeforeCommit, "HEAD", "--", ".agents/skills/1c-workflow/scripts"))
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

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & powershell @arguments 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) {
                [Console]::Error.WriteLine([string]$_)
            } else {
                Write-Output $_
            }
        }
        $pipelineSucceeded = $?
        $exitCode = if ($LASTEXITCODE -is [int]) { $LASTEXITCODE } elseif ($pipelineSucceeded) { 0 } else { 1 }
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($continuesLifecycleOperation) {
        $terminal = Read-Agent1cLifecycleOperationRecord -Path $script:LifecycleOperationStatePath
        if ($null -eq $terminal -or
            [string]$terminal["operationId"] -cne $script:LifecycleOperationId -or
            [string]$terminal["status"] -notin @("succeeded", "failed", "cancelled")) {
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

    $branchHelperPath = Join-Path (Resolve-Agent1cFullPath -Path $script:ProjectRoot) ".agents\skills\1c-workflow\scripts\agent-1c.ps1"
    if (-not (Test-Path -LiteralPath $branchHelperPath -PathType Leaf)) {
        throw "DEV_BRANCH_POST_MERGE_HELPER_MISSING operation='$Operation' path='$branchHelperPath'"
    }
    Write-Host "Development branch merge completed for $Operation. Handing the post-merge phase to the helper from the updated development branch: $branchHelperPath"
    Invoke-Agent1cFreshProcess -ScriptPath $branchHelperPath -AdditionalArguments @("-LifecyclePhase", "post-merge")
}

function Write-ItlAdditionalHelperActions {
    Write-Host ""
    Write-Host "Дополнительные действия:"
    Write-Host "  Данные ROCTUP: используйте MCP-сервер itl-roctup-data; backend ветки запускается и останавливается автоматически."
    Write-Host "  vibecoding1c MCP: попросите выполнить setup, status, select, refresh-registry или update."
    Write-Host "  Vanessa UI: используйте MCP-сервер itl-vanessa-ui только для исследования, записи или отладки фактического UI."
    Write-Host "  Ручное профилирование Vanessa: попросите запустить, проверить или остановить постоянную интерактивную пару текущей ветки."
    Write-Host "  Ветки расширений: одна ветка, worktree и база владеют одним CFE; внутри него допустимо несколько функций."
    Write-Host "  Инициализацией расширения управляет агент при создании ветки или первом входе со статусом pending."
    Write-Host "  Обслуживание и recovery: попросите обновить базу без тестов, обновить workflow/rules, закрыть, показать или переключить ветки."
    Write-Host "  Полный каталог helper-действий: .agents/skills/1c-workflow/references/advanced-actions.md."
}

function Get-ConfigLoadChangeSet {
    param(
        [object]$State,
        [string]$ExportPath = (Get-ExportPath),
        [ValidateSet("configuration", "extension")]
        [string]$ContentKind = "configuration",
        [object]$CurrentSource = $null
    )

    $absoluteExportPath = Assert-ExportPathInsideProject $ExportPath
    $source = if ($null -ne $CurrentSource) { $CurrentSource } else { Get-ConfigSourceFingerprint -ExportPath $ExportPath }
    $treeField = Get-DesignerTreeObjectIdFieldName -ContentKind $ContentKind
    $previousTree = [string](Get-StateValue -State $State -Name $treeField -Default "")
    $currentTree = [string](Get-StateValue -State $source -Name "treeObjectId" -Default "")
    $requiresFullLoad = $false
    $fullLoadReason = ""
    $files = @()

    if ($previousTree -notmatch '^[0-9a-f]{40,64}$') {
        $requiresFullLoad = $true
        $fullLoadReason = "designer-tree-proof-missing"
    } elseif ($currentTree -notmatch '^[0-9a-f]{40,64}$') {
        $requiresFullLoad = $true
        $fullLoadReason = "current-source-tree-missing"
    } else {
        & git -C $script:ProjectRoot cat-file -e "$previousTree^{tree}" *> $null
        if ($LASTEXITCODE -ne 0) {
            $requiresFullLoad = $true
            $fullLoadReason = "designer-tree-object-unavailable"
        } else {
            try {
                $files = @(Get-GitPathList -Arguments @("diff", "--name-only", "-z", "--diff-filter=ACMRTUXBD", $previousTree, $currentTree))
            } catch {
                $requiresFullLoad = $true
                $fullLoadReason = "designer-tree-diff-unavailable"
                $files = @()
            }
        }
    }

    $files = @($files | Where-Object { $_ -and ([System.IO.Path]::GetFileName([string]$_) -ine "ConfigDumpInfo.xml") } | Sort-Object -Unique)
    $missingFiles = @(
        $files |
            Where-Object {
                -not (Test-Path -LiteralPath (Join-Path $absoluteExportPath $_) -PathType Leaf)
            }
    )
    if ($missingFiles.Count -gt 0) {
        $requiresFullLoad = $true
        $fullLoadReason = "designer-tree-deletion-detected"
    }
    return [pscustomobject]@{
        files = $files
        missingFiles = $missingFiles
        baseCommit = $previousTree
        currentCommit = Get-CurrentCommit
        absoluteExportPath = $absoluteExportPath
        previousTreeObjectId = $previousTree
        currentTreeObjectId = $currentTree
        requiresFullLoad = $requiresFullLoad
        fullLoadReason = $fullLoadReason
    }
}

function Get-ConfigSourceFingerprint {
    param([string]$ExportPath)

    $absoluteExportPath = Assert-ExportPathInsideProject $ExportPath
    if (-not (Test-Path -LiteralPath $absoluteExportPath -PathType Container)) {
        throw "Config source path was not found: $absoluteExportPath"
    }
    $projectRoot = (Resolve-Agent1cFullPath -Path $script:ProjectRoot).TrimEnd("\", "/")
    $normalizedExportPath = $absoluteExportPath.Substring($projectRoot.Length).TrimStart("\", "/").Replace("\", "/")
    if (-not $normalizedExportPath) {
        throw "Config source path must be a project subdirectory: $absoluteExportPath"
    }
    $changedPaths = @(Get-VerificationWorkingTreeChangePaths -PathSpec @($normalizedExportPath))
    $ignoredPaths = @(Get-GitPathList -Arguments @(
        "ls-files",
        "-z",
        "--others",
        "--ignored",
        "--exclude-standard",
        "--",
        $normalizedExportPath
    ))

    $pathSet = New-Object "System.Collections.Generic.HashSet[string]" ([System.StringComparer]::Ordinal)
    foreach ($repoPath in @($changedPaths) + @($ignoredPaths)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$repoPath)) {
            [void]$pathSet.Add((([string]$repoPath -replace "\\", "/").TrimStart("/")))
        }
    }
    [string[]]$effectivePaths = @($pathSet)
    [System.Array]::Sort($effectivePaths, [System.StringComparer]::Ordinal)

    $treeish = New-VerificationEffectiveTree -ChangedPaths $effectivePaths
    $treeObjectId = Get-GitObjectIdForTreePath -Treeish $treeish -RepoPath $normalizedExportPath
    $entries = New-Object System.Collections.Generic.List[string]
    if ($treeObjectId -ne "<missing>") {
        foreach ($entry in @(Get-GitPathList -Arguments @("ls-tree", "-r", "-z", "${treeish}:$normalizedExportPath"))) {
            $separator = $entry.IndexOf("`t")
            if ($separator -lt 0) {
                throw "Git returned an invalid source tree entry for '$normalizedExportPath'."
            }
            $relative = $entry.Substring($separator + 1).Replace("\\", "/")
            $leafName = ($relative -split "/")[-1]
            if ($leafName -ieq "ConfigDumpInfo.xml") { continue }
            $entries.Add($entry)
        }
    }

    $payload = [System.Text.Encoding]::UTF8.GetBytes(($entries.ToArray() -join ([string][char]0)))
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $treeHash = ([System.BitConverter]::ToString($sha.ComputeHash($payload))).Replace("-", "").ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
    return [pscustomobject]@{
        fingerprint = "v2|git-tree-sha256|$treeHash"
        fileCount = $entries.Count
        absoluteExportPath = $absoluteExportPath
        treeObjectId = $treeObjectId
    }
}

function Get-OneCConfigurationSourceValidatorPath {
    $override = Get-Variable -Name OneCConfigurationSourceValidatorPathOverride -Scope Script -ErrorAction SilentlyContinue
    $activeClient = ""
    $validatorPath = if ($null -ne $override -and -not [string]::IsNullOrWhiteSpace([string]$override.Value)) {
        [System.IO.Path]::GetFullPath([string]$override.Value)
    } else {
        $activeClient = Get-ItlActiveClient
        $skillRoot = Get-AiRules1cInstalledSkillRoot -SkillName "1c-metadata-manage" -Client $activeClient
        Join-Path $skillRoot "tools\1c-cf-manage\scripts\cf-validate.ps1"
    }
    if (-not (Test-Path -LiteralPath $validatorPath -PathType Leaf)) {
        $source = if ($activeClient) { "active ai_rules_1c client '$activeClient'" } else { "the test or Release tool override" }
        throw "ONEC_SOURCE_VALIDATOR_MISSING source='$source' path='$validatorPath'. Run pinned update-ai-rules from master, then repeat the same ITL command."
    }
    return $validatorPath
}

function Assert-OneCConfigurationSourceIntegrity {
    param([string]$ExportPath = (Get-ExportPath))

    $script:RunSourceIntegrityPaths = @()
    try {
        $validatorPath = Get-OneCConfigurationSourceValidatorPath
    } catch {
        Set-RunFailureContext -Category "runner" -RequiredAction "run-pinned-update-ai-rules-from-master-then-repeat-same-itl-command"
        throw
    }

    $absoluteExportPath = Assert-ExportPathInsideProject -ExportPath $ExportPath
    $projectRoot = (Resolve-Agent1cFullPath -Path $script:ProjectRoot).TrimEnd("\", "/")
    $repoExportPath = $absoluteExportPath.Substring($projectRoot.Length).TrimStart("\", "/").Replace("\", "/")
    $configurationRepoPath = "$repoExportPath/Configuration.xml"
    $reportPath = New-TimestampedFilePath -Directory (Get-Agent1cTempRoot) -Prefix "itl-cf-validate-" -Extension ".txt"
    try {
        & powershell -NoProfile -ExecutionPolicy Bypass -File $validatorPath `
            -ConfigPath $absoluteExportPath `
            -MaxErrors 30 `
            -OutFile $reportPath *> $null
        $exitCode = $LASTEXITCODE
        if ($exitCode -eq 0) {
            return
        }

        $details = if (Test-Path -LiteralPath $reportPath -PathType Leaf) {
            (Read-Utf8Text -Path $reportPath).Trim() -replace "\r?\n", " | "
        } else {
            "cf-validate did not create its UTF-8 report"
        }
        if ($details.Length -gt 2000) {
            $details = $details.Substring(0, 2000) + "..."
        }
        $script:RunSourceIntegrityPaths = @($configurationRepoPath)
        Set-RunStage -Stage "source-integrity.failed" -Detail "Configuration source validation failed before a merge commit or Designer load."
        Set-RunFailureContext `
            -Category "source-integrity" `
            -RequiredAction $(if (Test-GitMergeInProgress) {
                "fix-listed-source-integrity-run-git-add-repeat-same-itl-command-no-manual-commit"
            } else {
                "fix-listed-source-integrity-then-repeat-same-itl-command"
            })
        throw "ONEC_SOURCE_INTEGRITY_FAILED path='$configurationRepoPath' validator='cf-validate' exitCode='$exitCode' details='$details'. Fix the listed source defect and repeat the same ITL command. If a merge is in progress, run git add for the fixed file and do not create the merge commit manually."
    } finally {
        Remove-Item -LiteralPath $reportPath -Force -ErrorAction SilentlyContinue
    }
}

function Test-LegacyConfigSourceFingerprint {
    param([string]$Fingerprint)

    return (-not [string]::IsNullOrWhiteSpace($Fingerprint) -and $Fingerprint -match '^[0-9a-fA-F]{64}$')
}

function Get-LegacyConfigSourceFingerprint {
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
        return ([System.BitConverter]::ToString($sha.ComputeHash($payload))).Replace("-", "").ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Get-DesignerFingerprintFieldName {
    param([ValidateSet("configuration", "extension")][string]$ContentKind)
    if ($ContentKind -eq "extension") { return "lastExtensionDesignerFingerprint" }
    return "lastConfigDesignerFingerprint"
}

function Get-DesignerTreeObjectIdFieldName {
    param([ValidateSet("configuration", "extension")][string]$ContentKind)
    if ($ContentKind -eq "extension") { return "lastExtensionDesignerTreeObjectId" }
    return "lastConfigDesignerTreeObjectId"
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

function New-ConfigDumpInfoLoadSnapshot {
    param([string]$AbsoluteExportPath)

    $dumpInfoPath = Join-Path $AbsoluteExportPath "ConfigDumpInfo.xml"
    $snapshot = [pscustomobject]@{
        path = $dumpInfoPath
        existed = (Test-Path -LiteralPath $dumpInfoPath -PathType Leaf)
        backupPath = ""
        preserveBackup = $false
    }
    if (-not $snapshot.existed) {
        return $snapshot
    }

    $backupPath = New-TimestampedFilePath `
        -Directory ([System.IO.Path]::GetTempPath()) `
        -Prefix "itl-config-dump-info-" `
        -Extension ".xml"
    Copy-Item -LiteralPath $dumpInfoPath -Destination $backupPath -Force -ErrorAction Stop
    $snapshot.backupPath = $backupPath
    return $snapshot
}

function Restore-ConfigDumpInfoLoadSnapshot {
    param([object]$Snapshot)

    if (-not $Snapshot) {
        return
    }

    if ($Snapshot.existed) {
        if (-not $Snapshot.backupPath -or -not (Test-Path -LiteralPath $Snapshot.backupPath -PathType Leaf)) {
            throw "ConfigDumpInfo rollback failed because the snapshot is missing: $($Snapshot.backupPath)"
        }
        try {
            Copy-Item -LiteralPath $Snapshot.backupPath -Destination $Snapshot.path -Force -ErrorAction Stop
        } catch {
            $Snapshot.preserveBackup = $true
            throw "ConfigDumpInfo rollback failed for '$($Snapshot.path)'. Recovery snapshot was preserved at '$($Snapshot.backupPath)': $($_.Exception.Message)"
        }
        return
    }

    if (Test-Path -LiteralPath $Snapshot.path -PathType Leaf) {
        Remove-Item -LiteralPath $Snapshot.path -Force -ErrorAction Stop
    }
}

function Remove-ConfigDumpInfoLoadSnapshot {
    param([object]$Snapshot)

    if (-not $Snapshot -or -not $Snapshot.backupPath -or -not (Test-Path -LiteralPath $Snapshot.backupPath -PathType Leaf)) {
        return
    }
    if ($Snapshot.preserveBackup) {
        Write-Warning "ConfigDumpInfo recovery snapshot was retained after a rollback failure: $($Snapshot.backupPath)"
        return
    }
    try {
        Remove-Item -LiteralPath $Snapshot.backupPath -Force -ErrorAction Stop
    } catch {
        Write-Warning "Could not remove the temporary ConfigDumpInfo snapshot '$($Snapshot.backupPath)': $($_.Exception.Message)"
    }
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
        [string]$User = (Get-EnvValue -Name "IB_USER"),
        [string]$Password = (Get-EnvValue -Name "IB_PASSWORD"),
        [ValidateSet("Auto", "Partial", "Full")]
        [string]$Mode = "Auto",
        [switch]$ResetConfigDumpInfo
    )

    $dumpInfoSnapshot = New-ConfigDumpInfoLoadSnapshot -AbsoluteExportPath $AbsoluteExportPath
    try {
        if ($ResetConfigDumpInfo -and $Mode -ne "Full") {
            throw "ConfigDumpInfo reset is valid only for a full configuration load."
        }
        if ($ResetConfigDumpInfo -and $dumpInfoSnapshot.existed) {
            Remove-Item -LiteralPath $dumpInfoSnapshot.path -Force -ErrorAction Stop
            Write-Host "Removed the stale ConfigDumpInfo cursor before a restore-recovery full load."
        }

        $baseArgs = @("/LoadConfigFromFiles", $AbsoluteExportPath)
        if ($ExtensionName) {
            $baseArgs += @("-Extension", $ExtensionName)
        }

        if ($Mode -eq "Full") {
            Write-Host "Full config load requested explicitly. Changed file count: $FileCount"
            try {
                Invoke-Designer -InfoBasePath $InfoBasePath -InfoBaseKind $InfoBaseKind `
                    -User $User -Password $Password `
                    -DesignerArgs ($baseArgs + @("-updateConfigDumpInfo", "-Format", "Hierarchical", "/UpdateDBCfg")) | Out-Null
            } catch {
                Restore-ConfigDumpInfoLoadSnapshot -Snapshot $dumpInfoSnapshot
                throw
            }
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
        $partialArgs = $baseArgs + @("-listFile", $ListFilePath, "-partial", "-updateConfigDumpInfo", "-Format", "Hierarchical", "/UpdateDBCfg")
        $script:LastNativeProcessStarted = $false
        try {
            Invoke-Designer -InfoBasePath $InfoBasePath -InfoBaseKind $InfoBaseKind -User $User -Password $Password -DesignerArgs $partialArgs | Out-Null
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
            Restore-ConfigDumpInfoLoadSnapshot -Snapshot $dumpInfoSnapshot
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
                    -User $User -Password $Password `
                    -DesignerArgs ($baseArgs + @("-updateConfigDumpInfo", "-Format", "Hierarchical", "/UpdateDBCfg")) | Out-Null
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
                Restore-ConfigDumpInfoLoadSnapshot -Snapshot $dumpInfoSnapshot
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
                throw "ITL_CONFIG_LOAD_FAILED: partial and full fallback config loads both failed. Partial: $($partialException.Exception.Message) (log: $partialLogPath). Full fallback: $($fullException.Exception.Message) (log: $fullLogPath). Inspect and correct the reported configuration source error, then repeat /itl-check. Do not run refresh-dev-branch or sync-master as recovery."
            }
        }
    } finally {
        Remove-ConfigDumpInfoLoadSnapshot -Snapshot $dumpInfoSnapshot
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
    if ($LoadResult.PSObject.Properties.Match("configLoadStatus").Count -gt 0 -and $LoadResult.configLoadStatus) {
        $updates["configLoadStatus"] = $LoadResult.configLoadStatus
    }
    if ($LoadResult.loaded) {
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
    if ($LoadResult.PSObject.Properties.Match("sourceTreeObjectId").Count -gt 0 -and $LoadResult.sourceTreeObjectId) {
        $updates[(Get-DesignerTreeObjectIdFieldName -ContentKind $ContentKind)] = $LoadResult.sourceTreeObjectId
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
        [ValidateSet("branch-copy", "branch-reset", "config-load", "legacy-preflight")]
        [string]$Reason = "legacy-preflight",
        [hashtable]$Updates = $null
    )

    $currentStatus = [string](Get-StateValue -State $State -Name "enterpriseNormalizationStatus" -Default "")
    if ($Reason -eq "legacy-preflight" -and $currentStatus -eq "passed") {
        return $State
    }

    Set-RunStage -Stage "enterprise.normalize" -Detail "Running Enterprise normalization for reason '$Reason'."
    Assert-EnterpriseNormalizationTargetsBranchCopy -State $State
    Stop-DevBranchRuntimeBeforeInfobaseMutation -State $State -Reason "Enterprise normalization ($Reason)"
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
        }
        if ($canPersistImmediately -or $null -eq $Updates) {
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

function Assert-DevBranchApplicationReady {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [string]$Operation = "managed 1C application start"
    )
    $problems = [System.Collections.Generic.List[string]]::new()
    foreach ($content in @(
        [pscustomobject]@{ kind = "configuration"; path = (Get-ExportPath) }
        $(if ((Get-DevBranchKind -State $State) -eq "extension") {
            [pscustomobject]@{ kind = "extension"; path = (Get-DevBranchExtensionExportPath -State $State) }
        })
    )) {
        if ($null -eq $content) { continue }
        $source = Get-ConfigSourceFingerprint -ExportPath $content.path
        $fingerprintField = Get-DesignerFingerprintFieldName -ContentKind $content.kind
        $loadedFingerprint = [string](Get-StateValue -State $State -Name $fingerprintField -Default "")
        if (-not $loadedFingerprint -or $loadedFingerprint -cne [string]$source.fingerprint) {
            $problems.Add("$($content.kind)-fingerprint-mismatch") | Out-Null
        }
    }

    $configLoadStatus = [string](Get-StateValue -State $State -Name "configLoadStatus" -Default "")
    if ($configLoadStatus -notin @("passed", "fallback-succeeded")) {
        $problems.Add("config-load-status-$configLoadStatus") | Out-Null
    }
    if ($problems.Count -gt 0) {
        throw "ITL_INFOBASE_APPLICATION_NOT_READY: operation='$Operation' reasons='$($problems -join ',')' requiredAction=update-dev-branch-base retryAction=repeat-original-operation-once."
    }

    if ([string](Get-StateValue -State $State -Name "enterpriseNormalizationStatus" -Default "") -ne "passed") {
        $State = Ensure-DevBranchEnterpriseNormalized -State $State -Reason "legacy-preflight"
    }
    if ([string](Get-StateValue -State $State -Name "enterpriseNormalizationStatus" -Default "") -ne "passed") {
        throw "ITL_INFOBASE_APPLICATION_NOT_READY: operation='$Operation' reasons='enterprise-normalization-not-passed' requiredAction=update-dev-branch-base retryAction=repeat-original-operation-once."
    }
    return $State
}

function Dump-ConfigToFilesFromInfoBase {
    param(
        [string]$InfoBasePath,
        [ValidateSet("file", "server")]
        [string]$InfoBaseKind,
        [switch]$IncludeRepositoryConnection
    )

    $exportPath = Get-ExportPath
    $absoluteExportPath = Assert-ExportPathInsideProject $exportPath
    $transaction = Initialize-Agent1cProjectTransactionSlot -Kind "c" -Target $absoluteExportPath
    $transactionRoot = $transaction.slot
    $stagedPath = $transaction.stage
    $backupPath = $transaction.backup
    $targetExisted = Test-Path -LiteralPath $absoluteExportPath -PathType Container -ErrorAction SilentlyContinue
    $targetMoved = $false
    $stageInstalled = $false

    if (-not $targetExisted -and (Test-Path -LiteralPath $absoluteExportPath -PathType Leaf -ErrorAction SilentlyContinue)) {
        throw "Configuration dump target is a file: $absoluteExportPath"
    }

    try {
        New-Item -ItemType Directory -Force -Path $stagedPath | Out-Null
        $designerArgs = @()
        if ($IncludeRepositoryConnection) {
            $designerArgs += New-RepositoryConnectionArgs
        }
        $designerArgs += @("/DumpConfigToFiles", $stagedPath, "-Format", "Hierarchical")

        Invoke-Designer `
            -InfoBasePath $InfoBasePath `
            -InfoBaseKind $InfoBaseKind `
            -DesignerArgs $designerArgs | Out-Null

        $dumpState = Get-DesignerDumpArtifactState -Path $stagedPath
        if (-not $dumpState.ready) {
            throw "1C configuration dump did not create complete Configuration.xml and ConfigDumpInfo.xml artifacts. Check the 1C log: $script:LastLogPath"
        }
        $existingSupportState = Join-Path $absoluteExportPath "Ext\ParentConfigurations.bin"
        $stagedSupportState = Join-Path $stagedPath "Ext\ParentConfigurations.bin"
        if ($targetExisted -and (Test-Path -LiteralPath $existingSupportState -PathType Leaf) -and -not (Test-Path -LiteralPath $stagedSupportState -PathType Leaf)) {
            throw "1C configuration dump would lose Ext/ParentConfigurations.bin. The existing vendor-support state was preserved and the staged dump was rejected."
        }

        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $absoluteExportPath) | Out-Null
        if ($targetExisted) {
            Move-Item -LiteralPath $absoluteExportPath -Destination $backupPath
            $targetMoved = $true
            Write-Agent1cProjectTransactionState -Paths $transaction -Kind "c" -Phase "target-backed-up" -Target $absoluteExportPath
        }
        Move-Item -LiteralPath $stagedPath -Destination $absoluteExportPath
        $stageInstalled = $true
        Write-Agent1cProjectTransactionState -Paths $transaction -Kind "c" -Phase "installed" -Target $absoluteExportPath

        Complete-Agent1cProjectTransactionSlot -Paths $transaction

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

function Dump-ConfigToFiles {
    return (Dump-ConfigToFilesFromInfoBase `
        -InfoBasePath (Get-SourceInfoBasePath) `
        -InfoBaseKind (Get-InfoBaseKind) `
        -IncludeRepositoryConnection:(Get-SourceUsesRepository))
}

function Dump-ExtensionToFiles {
    param([object]$State)

    Assert-DevBranchKind -State $State -Expected "extension"
    Assert-SingleManagedExtensionArtifact -State $State
    $extensionName = Require-DevBranchExtensionName -State $State
    $extensionExportPath = Get-DevBranchExtensionExportPath -State $State
    $absoluteExportPath = Assert-ExportPathInsideProject $extensionExportPath
    $transaction = Initialize-Agent1cProjectTransactionSlot -Kind "e" -Target $absoluteExportPath
    $transactionRoot = $transaction.slot
    $stagedPath = $transaction.stage
    $backupPath = $transaction.backup
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
            Write-Agent1cProjectTransactionState -Paths $transaction -Kind "e" -Phase "target-backed-up" -Target $absoluteExportPath
        } elseif (Test-Path -LiteralPath $absoluteExportPath -PathType Leaf -ErrorAction SilentlyContinue) {
            throw "Extension dump target is a file: $absoluteExportPath"
        }
        Move-Item -LiteralPath $stagedPath -Destination $absoluteExportPath
        $stageInstalled = $true
        Write-Agent1cProjectTransactionState -Paths $transaction -Kind "e" -Phase "installed" -Target $absoluteExportPath
        Complete-Agent1cProjectTransactionSlot -Paths $transaction

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

    $infoBaseKind = [string](Get-StateValue -State $State -Name "infoBaseKind" -Default "file")
    Set-RunStage -Stage "config-load.stop-runtime" -Detail "Stopping 1C sessions for the exact development branch infobase before $Reason."
    $ownedCleanupError = ""
    try {
        Invoke-DevBranchVanessaRuntimeRelease -State $State -Reason $Reason | Out-Null
        Stop-ItlOnDemandBackends -Family "roctup" -InfoBasePath $infoBasePath -Strict
        $roctupRuntime = Get-RoctupMcpRuntimeInfo -State $State
        if ($roctupRuntime.processAlive) {
            Stop-RoctupMcpForState -State $State -Quiet -RequireOwnership -SkipClientConfig | Out-Null
        }
    } catch {
        $ownedCleanupError = $_.Exception.Message
        Write-Warning "Workflow-owned cleanup could not prove ownership before exact-infobase cleanup: $ownedCleanupError"
    }

    try {
        $sessionCleanup = Stop-OneCInfoBaseSessionProcesses `
            -InfoBaseKind $infoBaseKind `
            -InfoBasePath $infoBasePath `
            -Reason $Reason

        if ($ownedCleanupError) {
            # Exact-infobase cleanup can recover from an ownership mismatch. In
            # that case re-run the regular owners only to release stale state.
            Invoke-DevBranchVanessaRuntimeRelease -State $State -Reason $Reason | Out-Null
            Stop-ItlOnDemandBackends -InfoBasePath $infoBasePath -Strict
            $roctupRuntime = Get-RoctupMcpRuntimeInfo -State $State
            if ($roctupRuntime.processAlive) {
                Stop-RoctupMcpForState -State $State -Quiet -RequireOwnership -SkipClientConfig | Out-Null
            }
        }

        $remainingSessions = @(Get-OneCInfoBaseSessionProcesses -InfoBaseKind $infoBaseKind -InfoBasePath $infoBasePath)
        $remainingTests = @(Get-OwnVanessaTestProcesses -State $State -RequireInspection)
        $remainingOnDemand = @(Get-ItlOnDemandRuntimeInstances -Strict | Where-Object {
            Test-ItlOnDemandInfoBaseMatch -First ([string]$_.infoBasePath) -Second $infoBasePath
        })
        if ($remainingSessions.Count -gt 0 -or $remainingTests.Count -gt 0 -or $remainingOnDemand.Count -gt 0) {
            throw "processes remain after cleanup (sessions=$($remainingSessions.Count), tests=$($remainingTests.Count), ondemand=$($remainingOnDemand.Count))."
        }
    } catch {
        $ownedDetail = if ($ownedCleanupError) { " initialOwnedCleanup='$ownedCleanupError'" } else { "" }
        throw "ITL_INFOBASE_RUNTIME_DRAIN_FAILED reason='$Reason' infoBasePath='$infoBasePath' detail='$($_.Exception.Message)'$ownedDetail"
    }

    Write-Host "Exact development branch infobase sessions stopped before $Reason. Stopped local sessions: $($sessionCleanup.stopped)."
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

function Remove-CompletedInfobaseSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$SnapshotPath
    )

    $snapshotRoot = Assert-ExportPathInsideProject -ExportPath ".agent-1c/snapshots"
    $snapshotRootPrefix = $snapshotRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    $absoluteSnapshotPath = [System.IO.Path]::GetFullPath($SnapshotPath)
    if (-not $absoluteSnapshotPath.StartsWith($snapshotRootPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
        [System.IO.Path]::GetExtension($absoluteSnapshotPath) -ine ".dt") {
        throw "Refusing to remove an infobase snapshot outside the project snapshot directory: $SnapshotPath"
    }

    if (Test-Path -LiteralPath $absoluteSnapshotPath -PathType Leaf -ErrorAction SilentlyContinue) {
        Remove-Item -LiteralPath $absoluteSnapshotPath -Force -ErrorAction Stop
    }
    if (Test-Path -LiteralPath $absoluteSnapshotPath -ErrorAction SilentlyContinue) {
        throw "Infobase snapshot still exists after cleanup: $absoluteSnapshotPath"
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

    Set-RunStage -Stage "config-load.fingerprint" -Detail "Calculating the $ContentKind source fingerprint."
    $source = Get-ConfigSourceFingerprint -ExportPath $ExportPath
    $sourceTreeObjectId = [string](Get-StateValue -State $source -Name "treeObjectId" -Default "")
    $fingerprintField = Get-DesignerFingerprintFieldName -ContentKind $ContentKind
    $treeObjectIdField = Get-DesignerTreeObjectIdFieldName -ContentKind $ContentKind
    $loadedAtField = Get-DesignerLoadedAtFieldName -ContentKind $ContentKind
    $previousFingerprint = [string](Get-StateValue -State $State -Name $fingerprintField -Default "")
    $normalizationStatus = [string](Get-StateValue -State $State -Name "enterpriseNormalizationStatus" -Default "")
    $configLoadStatus = [string](Get-StateValue -State $State -Name "configLoadStatus" -Default "")
    $currentCommit = Get-CurrentCommit
    $changeSet = $null
    $loadProofInvalidated = (-not $previousFingerprint -and $configLoadStatus -and $configLoadStatus -notin @("passed", "fallback-succeeded"))

    if ($Mode -ne "Full" -and $previousFingerprint -and $previousFingerprint -eq $source.fingerprint) {
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
            sourceTreeObjectId = $sourceTreeObjectId
            loadReason = $reason
            designerInvoked = $false
            enterpriseInvoked = $false
        }
    }

    if ($null -eq $changeSet) {
        $changeSet = Get-ConfigLoadChangeSet -State $State -ExportPath $ExportPath -ContentKind $ContentKind -CurrentSource $source
    }
    $restoreInvalidated = ([string](Get-StateValue -State $State -Name "loadReason" -Default "")) -eq "release-e2e-restore-invalidated"
    if ($restoreInvalidated) {
        Write-Warning "Release E2E restore invalidated the Designer fingerprint. Running a cursor-free full load."
        $Mode = "Full"
        $changeSet.files = @("<release-e2e-restore-invalidated>")
    } elseif ($Mode -eq "Full") {
        $changeSet.files = @("<explicit-full-load>")
    } elseif ([bool](Get-StateValue -State $changeSet -Name "requiresFullLoad" -Default $false)) {
        $fullLoadReason = [string](Get-StateValue -State $changeSet -Name "fullLoadReason" -Default "designer-tree-proof-unavailable")
        Write-Warning "Partial config load proof is unavailable ($fullLoadReason). Running a full load."
        $Mode = "Full"
        $changeSet.files = @("<$fullLoadReason>")
    } elseif ($changeSet.files.Count -eq 0) {
        if ($previousFingerprint -or $loadProofInvalidated) {
            $fullLoadReason = if ($loadProofInvalidated) { "The previous Designer load proof is invalid" } else { "Source fingerprint changed" }
            Write-Warning "$fullLoadReason but Git produced no partial list. Running a full load to preserve correctness."
            $Mode = "Full"
            $changeSet.files = @($(if ($loadProofInvalidated) { "<designer-proof-invalidated>" } else { "<fingerprint-changed>" }))
        }
    }

    $missingPartialFiles = @()
    if ($Mode -ne "Full") {
        $missingFilesProperty = $changeSet.PSObject.Properties["missingFiles"]
        if ($missingFilesProperty) {
            $missingPartialFiles = @($missingFilesProperty.Value | Where-Object { $_ })
        }
    }
    $missingPartialFilesFullLoad = ($missingPartialFiles.Count -gt 0)
    if ($missingPartialFilesFullLoad) {
        $missingFilesText = $missingPartialFiles -join ", "
        $message = "PARTIAL_CONFIG_LOAD_MISSING_FILES: the exact partial-load inventory references source files that are absent under '$($changeSet.absoluteExportPath)': $missingFilesText"
        if ($Mode -eq "Partial") {
            throw $message
        }
        Write-Warning "$message. Skipping partial Designer startup and running a full load."
        Set-RunStage -Stage "config-load.partial-preflight-fallback" -Detail "The partial $ContentKind inventory contains $($missingPartialFiles.Count) absent source file(s); Designer partial load was skipped."
        $Mode = "Full"
    }

    if ($ContentKind -eq "configuration") {
        Assert-OneCConfigurationSourceIntegrity -ExportPath $changeSet.absoluteExportPath
    }

    $listFilePath = ""
    if ($Mode -ne "Full") {
        $listFilePath = New-ConfigLoadListFile -State $State -Files $changeSet.files
    }
    Stop-DevBranchRuntimeBeforeInfobaseMutation -State $State -Reason "$ContentKind source load" -InfoBasePath $InfoBasePath
    Set-RunStage -Stage "config-load.designer" -Detail "Loading $ContentKind source through Designer in $Mode mode."
    $statePath = if ($State) { [string](Get-StateValue -State $State -Name "statePath" -Default "") } else { "" }
    $canPersistLoadProof = $statePath -and (Test-Path -LiteralPath $statePath -PathType Leaf -ErrorAction SilentlyContinue)
    $loadState = $State
    if ($canPersistLoadProof) {
        $loadStateHash = ConvertTo-Agent1cHashtable -Object $State
        $loadStateHash[$fingerprintField] = ""
        $loadStateHash["configLoadStatus"] = "pending"
        $loadState = [pscustomobject]$loadStateHash
        Update-DevBranchState -State $loadState -Updates @{
            $fingerprintField = ""
            configLoadStatus = "pending"
        }
    }
    $orchestration = Invoke-ConfigLoadWithFallback `
        -InfoBasePath $InfoBasePath `
        -InfoBaseKind $InfoBaseKind `
        -State $loadState `
        -AbsoluteExportPath $changeSet.absoluteExportPath `
        -ListFilePath $listFilePath `
        -FileCount $changeSet.files.Count `
        -ExtensionName $ExtensionName `
        -Mode $Mode `
        -ResetConfigDumpInfo:($restoreInvalidated -or $Mode -eq "Full")
    Set-RunStage -Stage "config-load.loaded" -Detail "Designer completed the $ContentKind source load."

    $loadedAt = (Get-Date).ToString("o")
    if ($canPersistLoadProof) {
        Update-DevBranchState -State $loadState -Updates @{
            $fingerprintField = $source.fingerprint
            $treeObjectIdField = $sourceTreeObjectId
            $loadedAtField = $loadedAt
            configLoadStatus = $orchestration.configLoadStatus
            lastConfigLoadMode = $orchestration.loadModeUsed
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
        sourceTreeObjectId = $sourceTreeObjectId
        loadReason = $(
            if ($missingPartialFilesFullLoad) { "partial-inventory-missing-files-full-load" }
            elseif ($Mode -eq "Full" -and $changeSet.files[0] -eq "<fingerprint-changed>") { "fingerprint-changed-full-load" }
            elseif ($Mode -eq "Full" -and $changeSet.files[0] -eq "<designer-proof-invalidated>") { "designer-proof-invalidated-full-load" }
            elseif ($Mode -eq "Full" -and $changeSet.files[0] -eq "<release-e2e-restore-invalidated>") { "release-e2e-restore-full-load" }
            elseif ($Mode -eq "Full" -and $changeSet.files[0] -eq "<explicit-full-load>") { "explicit-full-load" }
            elseif ($Mode -eq "Full" -and $changeSet.files[0] -match '^<designer-tree-') { $changeSet.files[0].Trim('<', '>') + "-full-load" }
            else { "source-fingerprint-changed" }
        )
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

function Get-ConfigRepositoryMetadataCollectionLabel {
    param([string]$Collection)

    switch ($Collection) {
        "AccountingRegisters" { return "РегистрБухгалтерии" }
        "AccumulationRegisters" { return "РегистрНакопления" }
        "BusinessProcesses" { return "БизнесПроцесс" }
        "CalculationRegisters" { return "РегистрРасчета" }
        "Catalogs" { return "Справочник" }
        "ChartsOfAccounts" { return "ПланСчетов" }
        "ChartsOfCalculationTypes" { return "ПланВидовРасчета" }
        "ChartsOfCharacteristicTypes" { return "ПланВидовХарактеристик" }
        "CommandGroups" { return "ГруппаКоманд" }
        "CommonAttributes" { return "ОбщийРеквизит" }
        "CommonCommands" { return "ОбщаяКоманда" }
        "CommonForms" { return "ОбщаяФорма" }
        "CommonModules" { return "ОбщийМодуль" }
        "CommonPictures" { return "ОбщаяКартинка" }
        "CommonTemplates" { return "ОбщийМакет" }
        "Constants" { return "Константа" }
        "DataProcessors" { return "Обработка" }
        "DefinedTypes" { return "ОпределяемыйТип" }
        "DocumentJournals" { return "ЖурналДокументов" }
        "Documents" { return "Документ" }
        "Enums" { return "Перечисление" }
        "EventSubscriptions" { return "ПодпискаНаСобытие" }
        "ExchangePlans" { return "ПланОбмена" }
        "ExternalDataSources" { return "ВнешнийИсточникДанных" }
        "FilterCriteria" { return "КритерийОтбора" }
        "FunctionalOptions" { return "ФункциональнаяОпция" }
        "FunctionalOptionsParameters" { return "ПараметрФункциональнойОпции" }
        "HTTPServices" { return "HTTPСервис" }
        "InformationRegisters" { return "РегистрСведений" }
        "IntegrationServices" { return "СервисИнтеграции" }
        "Languages" { return "Язык" }
        "Reports" { return "Отчет" }
        "Roles" { return "Роль" }
        "ScheduledJobs" { return "РегламентноеЗадание" }
        "Sequences" { return "Последовательность" }
        "SessionParameters" { return "ПараметрСеанса" }
        "SettingsStorages" { return "ХранилищеНастроек" }
        "StyleItems" { return "ЭлементСтиля" }
        "Styles" { return "Стиль" }
        "Subsystems" { return "Подсистема" }
        "Tasks" { return "Задача" }
        "WebServices" { return "WebСервис" }
        "WSReferences" { return "WSСсылка" }
        "XDTOPackages" { return "ПакетXDTO" }
        "Forms" { return "Форма" }
        "Templates" { return "Макет" }
        "Commands" { return "Команда" }
        "Tables" { return "Таблица" }
        "Cubes" { return "Куб" }
        default { return "" }
    }
}

function Get-ConfigRepositoryTransferPartLabel {
    param([string[]]$Segments)

    $parts = @($Segments | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($parts.Count -gt 0 -and $parts[0] -ieq "Ext") {
        $parts = @($parts | Select-Object -Skip 1)
    }
    if ($parts.Count -eq 0) { return "внутреннее содержимое" }

    $leaf = [System.IO.Path]::GetFileNameWithoutExtension([string]$parts[-1])
    switch ($leaf) {
        "CommandModule" { return "модуль команды" }
        "ExternalConnectionModule" { return "модуль внешнего соединения" }
        "Form" { return "форма" }
        "Help" { return "справочная информация" }
        "ManagedApplicationModule" { return "модуль управляемого приложения" }
        "ManagerModule" { return "модуль менеджера" }
        "Module" { return "модуль" }
        "ObjectModule" { return "модуль объекта" }
        "OrdinaryApplicationModule" { return "модуль обычного приложения" }
        "RecordSetModule" { return "модуль набора записей" }
        "SessionModule" { return "модуль сеанса" }
        "Template" { return "макет" }
        "ValueManagerModule" { return "модуль менеджера значения" }
        default { return ($parts -join "/") }
    }
}

function ConvertTo-ConfigRepositoryTransferPath {
    param([string]$RelativePath)

    $normalized = ([string]$RelativePath).Replace("\", "/").Trim("/")
    if (-not $normalized) { return $null }
    $segments = @($normalized -split "/" | Where-Object { $_ })
    if ($segments.Count -eq 0) { return $null }

    if ($segments[0] -ieq "Ext") {
        return [pscustomobject]@{
            objectName = "Конфигурация"
            scope = "partial"
            part = Get-ConfigRepositoryTransferPartLabel -Segments $segments
            path = $normalized
        }
    }

    $collection = [string]$segments[0]
    $collectionLabel = Get-ConfigRepositoryMetadataCollectionLabel -Collection $collection
    if (-not $collectionLabel -or $segments.Count -lt 2) { return $null }

    $nameSegment = [string]$segments[1]
    $isDescriptor = $nameSegment.EndsWith(".xml", [System.StringComparison]::OrdinalIgnoreCase)
    $name = if ($isDescriptor) { [System.IO.Path]::GetFileNameWithoutExtension($nameSegment) } else { $nameSegment }
    $objectName = "$collectionLabel.$name"
    $consumed = 2

    while (-not $isDescriptor -and $consumed -lt $segments.Count) {
        $childCollection = [string]$segments[$consumed]
        if ($childCollection -ieq "Ext" -or ($consumed + 1) -ge $segments.Count) { break }
        $childLabel = Get-ConfigRepositoryMetadataCollectionLabel -Collection $childCollection
        if (-not $childLabel) { break }

        $childNameSegment = [string]$segments[$consumed + 1]
        $childDescriptor = $childNameSegment.EndsWith(".xml", [System.StringComparison]::OrdinalIgnoreCase)
        $childName = if ($childDescriptor) { [System.IO.Path]::GetFileNameWithoutExtension($childNameSegment) } else { $childNameSegment }
        if ($childCollection -ieq "Subsystems") {
            $objectName += ".$childName"
        } else {
            $objectName += ".$childLabel.$childName"
        }
        $consumed += 2
        $isDescriptor = $childDescriptor
    }

    $descriptorIsWholePath = $isDescriptor -and $consumed -eq $segments.Count
    $remaining = if ($consumed -lt $segments.Count) { @($segments[$consumed..($segments.Count - 1)]) } else { @() }
    return [pscustomobject]@{
        objectName = $objectName
        scope = $(if ($descriptorIsWholePath) { "full" } else { "partial" })
        part = $(if ($descriptorIsWholePath) { "" } else { Get-ConfigRepositoryTransferPartLabel -Segments $remaining })
        path = $normalized
    }
}

function Get-DevBranchResultTransferBaseCommit {
    $masterCommit = Get-GitCommitOrEmpty (Get-MasterBranch)
    if (-not $masterCommit) {
        throw "export-dev-branch-result could not resolve the local master commit for configuration repository transfer reporting."
    }
    $baseCommit = (Get-GitOutput @("merge-base", "HEAD", $masterCommit)).Trim()
    if (-not $baseCommit) {
        throw "export-dev-branch-result could not resolve merge-base between HEAD and local master for configuration repository transfer reporting."
    }
    return $baseCommit
}

function Get-ConfigRepositoryTransferPlan {
    param(
        [string]$ExportPath,
        [string]$BaseCommit = ""
    )

    $normalizedExportPath = ([string]$ExportPath).Replace("\", "/").Trim("/")
    if (-not $normalizedExportPath) {
        throw "export-dev-branch-result cannot build a configuration repository transfer plan without an export path."
    }
    if (-not $BaseCommit) {
        $BaseCommit = Get-DevBranchResultTransferBaseCommit
    }

    $tracked = @(Get-GitPathList -Arguments @(
        "diff", "--no-renames", "--name-only", "-z", "--diff-filter=ACMRTUXBD", $BaseCommit, "--", $normalizedExportPath
    ))
    $untracked = @(Get-GitPathList -Arguments @(
        "ls-files", "-z", "--others", "--exclude-standard", "--", $normalizedExportPath
    ))
    $repoPaths = @(
        @($tracked) + @($untracked) |
            ForEach-Object { ([string]$_).Replace("\", "/").Trim("/") } |
            Where-Object { $_ } |
            Sort-Object -Unique
    )

    $itemsByName = @{}
    $unresolved = [System.Collections.Generic.List[string]]::new()
    $prefix = $normalizedExportPath + "/"
    foreach ($repoPath in $repoPaths) {
        if (-not $repoPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        $relativePath = $repoPath.Substring($prefix.Length)
        $leaf = [System.IO.Path]::GetFileName($relativePath)
        if ($leaf -ieq "ConfigDumpInfo.xml" -or $relativePath -ieq "Configuration.xml") { continue }

        $converted = ConvertTo-ConfigRepositoryTransferPath -RelativePath $relativePath
        if ($null -eq $converted) {
            $unresolved.Add($repoPath)
            continue
        }
        if (-not $itemsByName.ContainsKey($converted.objectName)) {
            $itemsByName[$converted.objectName] = [pscustomobject]@{
                name = [string]$converted.objectName
                scope = [string]$converted.scope
                parts = @()
                paths = @()
            }
        }
        $item = $itemsByName[$converted.objectName]
        if ($converted.scope -eq "full") { $item.scope = "full" }
        if ($converted.part) { $item.parts = @($item.parts) + [string]$converted.part }
        $item.paths = @($item.paths) + $repoPath
    }

    $items = @(
        foreach ($name in @($itemsByName.Keys | Sort-Object)) {
            $item = $itemsByName[$name]
            $item.parts = @($item.parts | Sort-Object -Unique)
            $item.paths = @($item.paths | Sort-Object -Unique)
            $item
        }
    )
    return [pscustomobject]@{
        baseCommit = $BaseCommit
        exportPath = $normalizedExportPath
        items = $items
        unresolvedPaths = @($unresolved | Sort-Object -Unique)
    }
}

function Add-ConfigRepositoryTransferPlanRunUserReportLines {
    param(
        [System.Collections.Generic.List[string]]$Lines,
        [object]$Plan
    )

    $items = @($Plan.items)
    $full = @($items | Where-Object { $_.scope -eq "full" })
    $partial = @($items | Where-Object { $_.scope -eq "partial" })
    $unresolved = @($Plan.unresolvedPaths)
    $Lines.Add("")
    $Lines.Add("## Перенос в хранилище конфигурации")
    Add-RunUserReportLine -Lines $Lines -Label "База сравнения (merge-base master)" -Value ([string]$Plan.baseCommit)
    if (($full.Count + $partial.Count + $unresolved.Count) -eq 0) {
        Add-RunUserReportLine -Lines $Lines -Label "Объекты для переноса" -Value "<нет>"
        return
    }

    if ($full.Count -gt 0) {
        $Lines.Add("")
        $Lines.Add("### Полностью")
        foreach ($item in $full) { $Lines.Add("- $([string]$item.name)") }
    }
    if ($partial.Count -gt 0) {
        $Lines.Add("")
        $Lines.Add("### Частично")
        foreach ($item in $partial) {
            $parts = @($item.parts)
            $suffix = if ($parts.Count -gt 0) { ": $($parts -join ', ')" } else { "" }
            $Lines.Add("- $([string]$item.name)$suffix")
        }
    }
    if ($unresolved.Count -gt 0) {
        $Lines.Add("")
        $Lines.Add("### Требуют ручной проверки")
        foreach ($path in $unresolved) { $Lines.Add("- $path") }
    }
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
        [string]$SourceFingerprint = "",
        [string]$VerificationFingerprint = "",
        [object]$VerificationState = $null,
        [bool]$WorktreeClean = $true,
        [bool]$VerificationScopeCommitted = $true,
        [bool]$UnverifiedOverride = $false,
        [ValidateSet("", "fresh-passed", "warn-unverified")]
        [string]$VerificationDecision = ""
    )

    $artifactPath = [System.IO.Path]::GetFullPath($ResultPath)
    if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
        throw "Result artifact was not found for manifest creation: $artifactPath"
    }

    $artifact = Get-Item -LiteralPath $artifactPath
    $artifactHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $artifactPath).Hash.ToLowerInvariant()
    $verification = if ($null -ne $VerificationState) { $VerificationState } else { Get-VerificationState -State $State }
    $manifestPath = "$artifactPath.manifest.json"

    $manifest = [ordered]@{
        schemaVersion = 3
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
            developmentBase = $DevBranchCommit
        }
        source = [ordered]@{
            provenance = $(if ($VerificationScopeCommitted) { "commit" } else { "working-tree" })
            worktreeClean = [bool]$WorktreeClean
            verificationScopeCommitted = [bool]$VerificationScopeCommitted
            configFingerprint = $SourceFingerprint
            verificationFingerprint = $VerificationFingerprint
        }
        verification = [ordered]@{
            policy = Get-VerificationPolicy
            decision = $(if ($VerificationDecision) { $VerificationDecision } elseif ($verification.isFreshPassed) { "fresh-passed" } else { "warn-unverified" })
            status = $verification.effectiveStatus
            storedStatus = $verification.status
            freshPassed = [bool]$verification.isFreshPassed
            verifiedAt = $verification.verifiedAt
            verifiedCommit = $verification.verifiedCommit
            currentCommit = $verification.currentCommit
            verifiedFingerprint = $verification.verifiedFingerprint
            currentFingerprint = $verification.currentFingerprint
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

function Sync-AiRules1cManagedIgnoredFilesFromMain {
    param([object]$State)

    $mainRoot = [string](Get-StateValue -State $State -Name "mainWorktreePath" -Default "")
    if (-not $mainRoot) {
        return 0
    }
    $mainRoot = (Resolve-Agent1cFullPath -Path $mainRoot).TrimEnd('\', '/')
    $branchRoot = (Resolve-Agent1cFullPath -Path $script:ProjectRoot).TrimEnd('\', '/')
    if ([string]::Equals($mainRoot, $branchRoot, [StringComparison]::OrdinalIgnoreCase)) {
        return 0
    }

    $branchManifest = Get-AiRules1cProjectManifest
    $mainManifestPath = Join-Path $mainRoot ".ai-rules.json"
    if ($null -eq $branchManifest -or -not (Test-Path -LiteralPath $mainManifestPath -PathType Leaf)) {
        return 0
    }
    try {
        $mainManifest = Read-Utf8Text -Path $mainManifestPath | ConvertFrom-Json
    } catch {
        throw "AI_RULES_MANAGED_IGNORED_MAIN_MANIFEST_INVALID: $mainManifestPath. $($_.Exception.Message)"
    }
    if ($null -eq $mainManifest.files -or $null -eq $branchManifest.files) {
        return 0
    }
    $mainVersion = [string](Get-ConfigValueFromObject -Object $mainManifest -Path "version" -Default "")
    $branchVersion = [string](Get-ConfigValueFromObject -Object $branchManifest -Path "version" -Default "")
    if ($mainVersion -ne $branchVersion) {
        throw "AI_RULES_MANAGED_IGNORED_VERSION_MISMATCH: main=$mainVersion branch=$branchVersion"
    }

    $mainEntries = @{}
    foreach ($property in @($mainManifest.files.PSObject.Properties)) {
        $mainEntries[([string]$property.Name).Replace('\', '/')] = $property.Value
    }
    $mainPrefix = $mainRoot + [IO.Path]::DirectorySeparatorChar
    $branchPrefix = $branchRoot + [IO.Path]::DirectorySeparatorChar
    $copied = 0
    foreach ($property in @($branchManifest.files.PSObject.Properties)) {
        $target = ([string]$property.Name).Replace('\', '/')
        if ([IO.Path]::IsPathRooted($target) -or [bool](Get-ConfigValueFromObject -Object $property.Value -Path "userModified" -Default $false)) {
            continue
        }
        $branchPath = [IO.Path]::GetFullPath((Join-Path $branchRoot ($target.Replace('/', [IO.Path]::DirectorySeparatorChar))))
        if (-not $branchPath.StartsWith($branchPrefix, [StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $branchPath -PathType Leaf)) {
            continue
        }

        $previousPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            & git -C $branchRoot check-ignore -q -- $target
            $isIgnored = $LASTEXITCODE -eq 0
        } finally {
            $ErrorActionPreference = $previousPreference
        }
        if (-not $isIgnored) {
            continue
        }
        if (-not $mainEntries.ContainsKey($target)) {
            throw "AI_RULES_MANAGED_IGNORED_SOURCE_ENTRY_MISSING: $target"
        }
        $expected = [string](Get-ConfigValueFromObject -Object $property.Value -Path "installedHash" -Default "")
        $mainExpected = [string](Get-ConfigValueFromObject -Object $mainEntries[$target] -Path "installedHash" -Default "")
        if ($expected -notmatch '^[0-9a-fA-F]{64}$' -or $mainExpected -ne $expected) {
            throw "AI_RULES_MANAGED_IGNORED_HASH_CONTRACT_MISMATCH: $target"
        }
        $mainPath = [IO.Path]::GetFullPath((Join-Path $mainRoot ($target.Replace('/', [IO.Path]::DirectorySeparatorChar))))
        if (-not $mainPath.StartsWith($mainPrefix, [StringComparison]::OrdinalIgnoreCase) -or
            -not (Test-AiRulesFileMatchesInstalledHash -Path $mainPath -InstalledHash $expected)) {
            throw "AI_RULES_MANAGED_IGNORED_SOURCE_DRIFT: $target"
        }
        $parent = Split-Path -Parent $branchPath
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
            New-Item -ItemType Directory -Force -Path $parent | Out-Null
        }
        Copy-Item -LiteralPath $mainPath -Destination $branchPath -Force
        if (-not (Test-AiRulesFileMatchesInstalledHash -Path $branchPath -InstalledHash $expected)) {
            throw "AI_RULES_MANAGED_IGNORED_COPY_VERIFY_FAILED: $target"
        }
        $copied++
        Write-Host "Restored ignored ai_rules_1c managed file from main worktree: $target"
    }
    return $copied
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

    $activeClient = @($DesiredTools | Select-Object -First 1)[0]
    foreach ($skillName in @("grill-me", "grill-with-docs")) {
        $skillRoot = Get-AiRules1cInstalledSkillRoot -SkillName $skillName -Client $activeClient
        $skillPath = Join-Path $skillRoot "SKILL.md"
        if (-not (Test-Path -LiteralPath $skillPath -PathType Leaf)) {
            throw "ai_rules_1c installation is missing required skill '$skillName': $skillPath"
        }
        if ($activeClient -eq "codex") {
            $openAiPath = Join-Path $skillRoot "agents\openai.yaml"
            if (-not (Test-Path -LiteralPath $openAiPath -PathType Leaf)) {
                throw "ai_rules_1c Codex skill '$skillName' is missing agents/openai.yaml."
            }
            $openAiText = Read-Utf8Text -Path $openAiPath
            $displayPattern = '(?m)^\s*display_name:\s*[''"]?{0}[''"]?\s*$' -f [regex]::Escape($skillName)
            if ($openAiText -notmatch $displayPattern) {
                throw "ai_rules_1c Codex skill '$skillName' does not expose the exact display_name '$skillName'."
            }
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
        [string]$Client,
        [AllowNull()][object]$Entry
    )

    $target = [string](Get-ConfigValueFromObject -Object $Entry -Path "target" -Default "")
    $target = $target.Replace('\', '/')
    if ($target -match '(?i)/skills/([^/]+)/SKILL\.md$') {
        $skillName = $Matches[1]
        if ($Client -eq "codex") {
            return "`$$skillName"
        }
        return "skill $skillName"
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
    $missingRules = @($integrationRuleEntries | Where-Object {
        $path = Join-Path $script:ProjectRoot $_.target
        return (-not (Test-Path -LiteralPath $path -PathType Leaf))
    })
    if ($missingRules.Count -gt 0) {
        return (New-ItlOpenSpecStatus -Mode unavailable -Reason "managed OpenSpec integration rule is missing." -Cli $cli)
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

    $missing = @()
    $invocations = [ordered]@{}
    foreach ($stage in $requiredStages.Keys) {
        $tokens = @($requiredStages[$stage])
        $matches = @($entries | Where-Object {
            $source = $_.source.Replace('\', '/')
            $matchesStage = @($tokens | Where-Object { $source -match ("/" + [regex]::Escape($_) + "(?:/SKILL)?\.md$") }).Count -gt 0
            if (-not $matchesStage) { return $false }
            return (Test-Path -LiteralPath (Join-Path $script:ProjectRoot $_.target) -PathType Leaf)
        })
        if ($matches.Count -eq 0) {
            $missing += $stage
            continue
        }
        if ($client -eq "codex") {
            $aliasToken = "opsx-$stage"
            $aliasMatches = @($matches | Where-Object {
                $_.source.Replace('\', '/') -match ("/" + [regex]::Escape($aliasToken) + "/SKILL\.md$")
            })
            if ($aliasMatches.Count -gt 0) {
                $matches = $aliasMatches
            }
        }
        $invocations[$stage] = Get-ItlOpenSpecNativeInvocation -Stage $stage -Client $client -Entry $matches[0]
    }

    if ($missing.Count -gt 0) {
        return (New-ItlOpenSpecStatus -Mode unavailable -Reason "required native OpenSpec phase(s) for $client are missing: $($missing -join ', ')." -Cli $cli)
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

function Invoke-AiRules1cFetchWithRetry {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [int]$MaxAttempts = 3
    )

    $failure = $null
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            Invoke-GitAt -Root $Root -Arguments @("fetch", "--all", "--tags", "--prune")
            return
        } catch {
            $failure = $_
            if ($attempt -ge $MaxAttempts) { break }
            $delaySeconds = [int][Math]::Pow(2, $attempt)
            Write-Warning "ai_rules_1c fetch attempt $attempt/$MaxAttempts failed; retrying the same idempotent fetch in $delaySeconds seconds."
            Start-Sleep -Seconds $delaySeconds
        }
    }
    throw $failure
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
            Invoke-AiRules1cFetchWithRetry -Root $rulesDir
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

function Get-AiRules1cMcpReconcileSnapshotPaths {
    return @(
        @(Get-AiRules1cMcpClientConfigPaths) +
        @(Get-ItlManagedMcpStatePath)
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique
}

function Get-AiRules1cMcpExpectedClientKeys {
    param(
        [string[]]$ClientNames,
        [string]$Client = ""
    )

    if (-not $Client) { $Client = Get-ItlActiveClient }
    return @($ClientNames | ForEach-Object { ConvertTo-ItlClientMcpKey -Name ([string]$_) -Client $Client } | Where-Object { $_ } | Select-Object -Unique)
}

function Assert-AiRules1cMcpReconcileIntegrity {
    param([string[]]$ExpectedClientNames)

    $client = Get-ItlActiveClient
    $expectedKeys = @(Get-AiRules1cMcpExpectedClientKeys -ClientNames $ExpectedClientNames -Client $client)
    $actualKeys = @(Get-ItlClientMcpEndpointKeys -Client $client)
    $managedKeys = @(Get-ItlManagedMcpOwnerKeys -Client $client -Owner "vibecoding1c")
    $missingActual = @($expectedKeys | Where-Object { $actualKeys -notcontains $_ })
    $missingManaged = @($expectedKeys | Where-Object { $managedKeys -notcontains $_ })
    $unexpectedManaged = @($managedKeys | Where-Object { $expectedKeys -notcontains $_ })
    if ($missingActual.Count -gt 0 -or $missingManaged.Count -gt 0 -or $unexpectedManaged.Count -gt 0) {
        throw "ITL_MCP_RECONCILE_INTEGRITY_FAILED: client=$client missingClient=[$($missingActual -join ', ')] missingManaged=[$($missingManaged -join ', ')] unexpectedManaged=[$($unexpectedManaged -join ', ')]."
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
    $selectionPath = Get-Vibecoding1cMcpSelectionPath
    if (-not (Test-Path -LiteralPath $selectionPath -PathType Leaf -ErrorAction SilentlyContinue)) {
        Write-AiRules1cMcpPreservedWarning -Operation $Operation -Reasons @("vibecoding1c MCP selection file is missing")
        return [pscustomobject]@{
            reconciled = $false
            preserved = $true
            replacements = @()
            pruned = @()
        }
    }

    try {
        $selectedClientNames = @(Get-Vibecoding1cMcpSelectedClientConfigNames)
        $readyClientNames = @(Get-Vibecoding1cMcpReadyClientConfigNames)
    } catch {
        throw "ITL_MCP_RECONCILE_INTEGRITY_FAILED: failed to calculate selected and ready vibecoding1c MCP endpoints. $($_.Exception.Message)"
    }

    $missingReadyClientNames = @($selectedClientNames | Where-Object { $readyClientNames -notcontains $_ })
    if (-not $selectionCompleteness.isComplete -or $missingReadyClientNames.Count -gt 0) {
        $client = Get-ItlActiveClient
        $expectedKeys = @(Get-AiRules1cMcpExpectedClientKeys -ClientNames $selectedClientNames -Client $client)
        $actualKeys = @(Get-ItlClientMcpEndpointKeys -Client $client)
        $missingActual = @($expectedKeys | Where-Object { $actualKeys -notcontains $_ })
        if ($missingActual.Count -gt 0) {
            throw "ITL_MCP_RECONCILE_INTEGRITY_FAILED: selected MCP replacements are not ready and the current $client config is already incomplete. notReady=[$($missingReadyClientNames -join ', ')] missingClient=[$($missingActual -join ', ')] selection=[$(@($selectionCompleteness.reasons) -join '; ')]."
        }
        $preserveReasons = @($selectionCompleteness.reasons)
        if ($missingReadyClientNames.Count -gt 0) {
            $preserveReasons += "selected vibecoding1c MCP replacements are not ready: $($missingReadyClientNames -join ', ')"
        }
        Write-AiRules1cMcpPreservedWarning -Operation $Operation -Reasons $preserveReasons
        return [pscustomobject]@{
            reconciled = $false
            preserved = $true
            replacements = @()
            pruned = @()
        }
    }

    $replacementServerIds = @($readyClientNames | Where-Object { $managedServerIds -contains $_ } | Select-Object -Unique)

    $snapshot = New-AiRules1cMcpConfigSnapshot -Paths (Get-AiRules1cMcpReconcileSnapshotPaths)
    try {
        $removed = @(Remove-AiRules1cManagedMcpConfig -ServerIds $replacementServerIds)
        Write-Vibecoding1cMcpClientConfig
        $pruned = @(Remove-StaleAiRules1cDataMcpConfig)
        Assert-AiRules1cMcpReconcileIntegrity -ExpectedClientNames $readyClientNames
        Write-Host "Reconciled ai_rules_1c MCP client entries with ITL vibecoding1c MCP config: $($replacementServerIds -join ', ')."
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
        throw "$Operation failed and MCP client config was rolled back. $errorMessage"
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
        # This checkout is workflow-owned; force restores tracked damage in the shared cached copy.
        $remoteRef = "refs/remotes/origin/$ref"
        if (Test-GitRefExistsAt -Root $root -Ref $remoteRef) {
            Invoke-GitAt -Root $root -Arguments @("checkout", "--force", "-B", $ref, "origin/$ref")
        } else {
            Invoke-GitAt -Root $root -Arguments @("checkout", "--force", "--detach", $ref)
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
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & git -C $script:ProjectRoot diff --quiet --ignore-submodules=none -- *> $null
        $worktreeExitCode = $LASTEXITCODE
        & git -C $script:ProjectRoot diff --cached --quiet --ignore-submodules=none -- *> $null
        $indexExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($worktreeExitCode -notin @(0, 1) -or $indexExitCode -notin @(0, 1)) {
        throw "Cannot compare tracked Git content before update-workflow."
    }
    if ($worktreeExitCode -eq 1 -or $indexExitCode -eq 1) {
        throw "Git tracked worktree is not clean. Commit, stash, or discard tracked changes before update-workflow."
    }
}

function Assert-WorkflowUpdateCommitIdentity {
    foreach ($identityKind in @("GIT_AUTHOR_IDENT", "GIT_COMMITTER_IDENT")) {
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            & git -C $script:ProjectRoot var $identityKind *> $null
            $exitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }
        if ($exitCode -ne 0) {
            throw "update-workflow cannot create its required commit because Git identity '$identityKind' is unavailable. Configure user.name and user.email, then retry."
        }
    }
}

function ConvertTo-WorkflowUpdateRepoPath {
    param([string]$Path)

    $normalized = ([string]$Path).Trim().Replace("\", "/")
    while ($normalized.StartsWith("./", [System.StringComparison]::Ordinal)) {
        $normalized = $normalized.Substring(2)
    }
    if (-not $normalized -or [System.IO.Path]::IsPathRooted($normalized) -or $normalized -eq ".." -or $normalized.StartsWith("../", [System.StringComparison]::Ordinal)) {
        throw "Invalid workflow update managed repository path: '$Path'."
    }
    return $normalized
}

function Get-WorkflowUpdateClientSurfacePaths {
    $paths = [System.Collections.Generic.List[string]]::new()
    $state = Read-ItlClientSurfaceState
    $clients = ConvertTo-Vibecoding1cMcpHashtable -Object $state["clients"]
    foreach ($client in @($clients.Keys)) {
        $entry = ConvertTo-Vibecoding1cMcpHashtable -Object $clients[$client]
        if (-not $entry.Contains("files")) { continue }
        $files = ConvertTo-Vibecoding1cMcpHashtable -Object $entry["files"]
        foreach ($path in @($files.Keys)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$path)) {
                $paths.Add((ConvertTo-WorkflowUpdateRepoPath -Path ([string]$path)))
            }
        }
    }
    return @($paths | Select-Object -Unique)
}

function Get-WorkflowUpdateTrackedInstalledClientConfigPaths {
    $paths = [System.Collections.Generic.List[string]]::new()
    foreach ($path in @(".kilo/kilo.json")) {
        foreach ($trackedPath in @(Get-GitPathList -Arguments @("ls-files", "-z", "--", $path))) {
            $normalized = ConvertTo-WorkflowUpdateRepoPath -Path ([string]$trackedPath)
            if (-not $paths.Contains($normalized)) { $paths.Add($normalized) }
        }
    }
    return @($paths)
}

function Get-WorkflowUpdateManagedPathSpecs {
    param(
        [string[]]$AiRulesPathsBefore = @(),
        [string[]]$ClientSurfacePathsBefore = @()
    )

    $paths = [System.Collections.Generic.List[string]]::new()
    foreach ($path in @(
        ".agents/skills/1c-workflow",
        ".agents/skills/1c-workflow-fast",
        ".agents/skills/product-docs",
        ".agents/skills/itl-roctup-1c-data",
        ".agents/skills/itl-vanessa-ui-mcp",
        "docs/itl-workflow",
        "templates",
        "tests/features/Libraries/ITL",
        "install-agent-1c-workflow.ps1",
        "AGENT-INSTALL.md",
        ".agent-1c/project.json",
        ".agent-1c/dependency-lock.json",
        ".gitignore",
        ".ai-rules.json",
        "AGENTS.md",
        "USER-RULES.md",
        "LLM-RULES.md",
        "memory.md"
    ) + @($AiRulesPathsBefore) + @($ClientSurfacePathsBefore) + @(Get-WorkflowUpdateClientSurfacePaths) + @(Get-WorkflowUpdateTrackedInstalledClientConfigPaths)) {
        if ([string]::IsNullOrWhiteSpace([string]$path)) { continue }
        $normalized = ConvertTo-WorkflowUpdateRepoPath -Path ([string]$path)
        if (-not $paths.Contains($normalized)) { $paths.Add($normalized) }
    }
    foreach ($entry in @(Get-AiRules1cManifestFileEntries)) {
        if ([string]::IsNullOrWhiteSpace([string]$entry.target)) { continue }
        $normalized = ConvertTo-WorkflowUpdateRepoPath -Path ([string]$entry.target)
        if (-not $paths.Contains($normalized)) { $paths.Add($normalized) }
    }
    return @($paths)
}

function Get-WorkflowUpdateDeletedLegacyPaths {
    $deleted = [System.Collections.Generic.List[string]]::new()
    foreach ($relativePath in @(Get-LegacyWorkflowManagedFileHashes).Keys) {
        $output = @(& git -C $script:ProjectRoot -c core.quotepath=false diff --name-status -- $relativePath)
        if ($LASTEXITCODE -ne 0) {
            throw "Cannot inspect legacy workflow deletion status: $relativePath"
        }
        if (@($output | Where-Object { ([string]$_).StartsWith("D`t", [System.StringComparison]::Ordinal) }).Count -gt 0) {
            $deleted.Add((ConvertTo-WorkflowUpdateRepoPath -Path $relativePath))
        }
    }
    return @($deleted)
}

function Test-WorkflowUpdatePathAllowed {
    param(
        [string]$Path,
        [string[]]$ManagedPathSpecs
    )

    $normalizedPath = ConvertTo-WorkflowUpdateRepoPath -Path $Path
    foreach ($spec in @($ManagedPathSpecs)) {
        $normalizedSpec = ConvertTo-WorkflowUpdateRepoPath -Path $spec
        if ($normalizedPath.Equals($normalizedSpec, [System.StringComparison]::OrdinalIgnoreCase) -or
            $normalizedPath.StartsWith(($normalizedSpec.TrimEnd("/") + "/"), [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Get-WorkflowUpdateTrackedChangePaths {
    return @(
        @(Get-GitPathList -Arguments @("diff", "--name-only", "-z")) +
        @(Get-GitPathList -Arguments @("diff", "--cached", "--name-only", "-z"))
    ) | Select-Object -Unique
}

function Commit-WorkflowUpdate {
    param(
        [object]$Source,
        [string[]]$AiRulesPathsBefore = @(),
        [string[]]$ClientSurfacePathsBefore = @()
    )

    $managedPathSpecs = @(
        @(Get-WorkflowUpdateManagedPathSpecs -AiRulesPathsBefore $AiRulesPathsBefore -ClientSurfacePathsBefore $ClientSurfacePathsBefore) +
        @(Get-WorkflowUpdateDeletedLegacyPaths)
    ) | Select-Object -Unique
    $trackedChanges = @(Get-WorkflowUpdateTrackedChangePaths)
    $unexpectedTracked = @($trackedChanges | Where-Object { -not (Test-WorkflowUpdatePathAllowed -Path $_ -ManagedPathSpecs $managedPathSpecs) })
    if ($unexpectedTracked.Count -gt 0) {
        throw "update-workflow produced tracked changes outside its managed allowlist and will not commit them: $($unexpectedTracked -join ', ')"
    }

    $managedUntracked = @(Get-GitPathList -Arguments @("ls-files", "-z", "--others", "--exclude-standard") |
        Where-Object { Test-WorkflowUpdatePathAllowed -Path $_ -ManagedPathSpecs $managedPathSpecs })
    $changes = @($trackedChanges + $managedUntracked | Select-Object -Unique)
    if ($changes.Count -eq 0) {
        return [pscustomobject]@{
            created = $false
            commit = Get-CurrentCommit
            message = ""
        }
    }

    $sourceRef = [string]$Source.ref
    $sourceCommit = [string]$Source.commit
    $shortCommit = $(if ($sourceCommit.Length -ge 7) { $sourceCommit.Substring(0, 7) } else { $sourceCommit })
    $message = if ($sourceRef -and $shortCommit) {
        "chore: update ITL workflow to $sourceRef@$shortCommit"
    } elseif ($shortCommit) {
        "chore: update ITL workflow to $shortCommit"
    } else {
        "chore: update ITL workflow from local source"
    }
    $unstagedManagedTracked = @(Get-GitPathList -Arguments @("diff", "--name-only", "-z") |
        Where-Object { Test-WorkflowUpdatePathAllowed -Path $_ -ManagedPathSpecs $managedPathSpecs })
    if ($unstagedManagedTracked.Count -gt 0) {
        Invoke-Git (@("add", "--update", "--") + $unstagedManagedTracked)
    }
    if ($managedUntracked.Count -gt 0) {
        Invoke-Git (@("add", "--") + $managedUntracked)
    }
    $stagedChanges = @(Get-GitPathList -Arguments @("diff", "--cached", "--name-only", "-z"))
    $unexpectedStaged = @($stagedChanges | Where-Object { -not (Test-WorkflowUpdatePathAllowed -Path $_ -ManagedPathSpecs $managedPathSpecs) })
    if ($unexpectedStaged.Count -gt 0) {
        throw "update-workflow found staged changes outside its managed allowlist and will not commit them: $($unexpectedStaged -join ', ')"
    }
    if ($stagedChanges.Count -eq 0) {
        throw "update-workflow found managed changes but could not stage any of them."
    }
    Invoke-Git @("commit", "--quiet", "-m", $message)
    Write-Host "Committed: $message"

    $remainingTracked = @(Get-WorkflowUpdateTrackedChangePaths)
    if ($remainingTracked.Count -gt 0) {
        throw "update-workflow created its commit but the tracked master worktree is still dirty: $($remainingTracked -join ', ')"
    }
    $remainingManagedUntracked = @(Get-GitPathList -Arguments @("ls-files", "-z", "--others", "--exclude-standard") |
        Where-Object { Test-WorkflowUpdatePathAllowed -Path $_ -ManagedPathSpecs $managedPathSpecs })
    if ($remainingManagedUntracked.Count -gt 0) {
        throw "update-workflow created its commit but managed files remain untracked: $($remainingManagedUntracked -join ', ')"
    }

    return [pscustomobject]@{
        created = $true
        commit = Get-CurrentCommit
        message = $message
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

    $devValidInheritedNames = @("itl-update-workflow.md")
    return @(
        Get-ChildItem -LiteralPath $primaryDir -File -Filter "itl*.md" -ErrorAction SilentlyContinue |
            Where-Object { $localNames -notcontains $_.Name -and $devValidInheritedNames -notcontains $_.Name } |
            ForEach-Object { "/$([System.IO.Path]::GetFileNameWithoutExtension($_.Name))" } |
            Sort-Object -Unique
    )
}

function Untrack-GeneratedKiloItlCommands {
    try {
        if (-not (Test-Path -LiteralPath (Join-Path $script:ProjectRoot ".git") -ErrorAction SilentlyContinue)) {
            return
        }
        $tracked = @(Get-GitPathList -Arguments @("ls-files", "-z", "--", ".kilo/commands/itl*.md"))
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
        $resetStatus = [string](Get-StateValue -State $State -Name "resetStatus" -Default "")
        if ($resetStatus -eq "resetting" -and $Operation -ne "reset-dev-branch") {
            $archivePath = [string](Get-StateValue -State $State -Name "resetArchivePath" -Default "")
            throw "DEV_BRANCH_RESET_IN_PROGRESS: repeat /itl-reset-branch to resume the interrupted reset. Archive: $archivePath"
        }
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
    param(
        [object]$Source,
        [object]$CommitResult
    )

    $states = @(Get-WorkflowActiveDevBranchStates)
    $sourceRef = [string]$Source.ref
    $sourceCommit = [string]$Source.commit
    $reportLines = [System.Collections.Generic.List[string]]::new()
    $reportLines.Add("## Workflow обновлён")
    Add-RunUserReportLine -Lines $reportLines -Label "Источник" -Value ([string]$Source.source)
    Add-RunUserReportLine -Lines $reportLines -Label "Версия workflow" -Value $(if ($sourceRef -and $sourceCommit) { "$sourceRef@$sourceCommit" } elseif ($sourceCommit) { $sourceCommit } else { $sourceRef }) -Default "<локальный источник без Git commit>"
    Add-RunUserReportLine -Lines $reportLines -Label "Коммит master" -Value ([string]$CommitResult.commit)
    Add-RunUserReportLine -Lines $reportLines -Label "Новый коммит создан" -Value $(if ($CommitResult.created) { "да" } else { "нет, workflow уже актуален" })
    Add-RunUserReportLine -Lines $reportLines -Label "Tracked-состояние master" -Value "clean"
    $reportLines.Add("")
    $reportLines.Add("## Следующие действия")
    if ($script:RunRequiredAction) {
        $reportLines.Add("- $($script:RunRequiredAction)")
    } else {
        $reportLines.Add("- Перезапустите или перезагрузите активный AI-клиент, чтобы он перечитал правила, навыки и команды.")
    }
    $activeClient = ""
    try { $activeClient = Get-ItlActiveClient } catch { $activeClient = "" }
    if ($activeClient -eq "codex") {
        $reportLines.Add("- Откройте новую задачу Codex, чтобы обновился список skills и стали видны команды `$grill-me` и `$grill-with-docs`.")
    }
    $reportLines.Add("- Push из проекта не выполнялся: созданный коммит остаётся в локальном `master`.")
    $reportLines.Add("- Workflow обновлён только в локальном `master`; каждую активную `itldev/*` обновите отдельно через `/itl-refresh` или `/itl-refresh-lite`.")
    if ($states.Count -gt 0) {
        $reportLines.Add("- Найдены активные ветки разработки:")
        foreach ($state in ($states | Sort-Object @{ Expression = { Get-StateValue -State $_ -Name "devBranchName" -Default "" } })) {
            $name = Get-StateValue -State $state -Name "devBranchName" -Default (Get-StateValue -State $state -Name "safeDevBranchName" -Default "<unknown>")
            $worktreePath = Get-StateValue -State $state -Name "worktreePath" -Default (Get-StateValue -State $state -Name "stateProjectRoot" -Default "")
            $reportLines.Add("  - $name → $worktreePath")
        }
    } else {
        $reportLines.Add("- Активных веток разработки нет.")
    }
    Write-AndSetRunUserReport -Lines $reportLines
}

function Set-ItlOnDemandMcpSemanticReloadRequiredAction {
    param([string]$Operation)

    $changes = @(Get-ItlClientMcpSemanticChanges -Owner "ondemand-facade")
    if ($changes.Count -eq 0) { return $false }

    $client = [string](Get-ItlActiveClient)
    if ($client -eq "kilocode") {
        $script:RunRequiredAction = "До следующего вызова ROCTUP или Vanessa UI обязательно выполните /reload, чтобы Kilo перечитал обновлённую команду MCP."
    } else {
        $adapter = Get-ItlClientAdapter -Client $client
        $fallbackInstruction = [string](Get-StateValue -State $adapter -Name "reloadUserReport" -Default "Перезапустите активный AI-клиент.")
        $instruction = [string](Get-StateValue -State $adapter -Name "mcpReloadUserReport" -Default $fallbackInstruction)
        $script:RunRequiredAction = "$instruction Причина: операция '$Operation' семантически изменила команду запуска ITL on-demand MCP."
    }
    return $true
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

function Assert-WorkflowSourceAiRulesInstallable {
    param([Parameter(Mandatory = $true)][string]$SourceRoot)

    if ($SkipAiRules) { return }
    $lockPath = Join-Path $SourceRoot "templates\dependency-lock.json"
    if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) {
        throw "Workflow source dependency lock is missing before update: $lockPath"
    }
    $lock = Read-Utf8Text -Path $lockPath | ConvertFrom-Json
    $entry = Get-ConfigValueFromObject -Object $lock -Path "dependencies.aiRules1c" -Default $null
    $ref = [string](Get-ConfigValueFromObject -Object $entry -Path "ref" -Default "")
    $commit = [string](Get-ConfigValueFromObject -Object $entry -Path "commit" -Default "")
    $status = [string](Get-ConfigValueFromObject -Object $entry -Path "compatibilityStatus" -Default "")
    if (-not $entry -or -not $ref -or $commit -notmatch '^[a-f0-9]{40}$' -or $status -cne "passed") {
        throw "Workflow source requires ai_rules_1c $(if ($ref) { $ref } else { '<unknown>' }) with compatibilityStatus=$(if ($status) { $status } else { '<missing>' }). Update is blocked before managed files are copied. Complete PublishDevelop for that exact controlled fork, or explicitly use -SkipAiRules."
    }
}

function Update-WorkflowPackage {
    Write-Section "Update ITL workflow package"
    if ($LifecyclePhase -notin @("", "pre-copy", "post-copy")) {
        throw "update-workflow does not support LifecyclePhase '$LifecyclePhase'."
    }

    if ($LifecyclePhase -ne "post-copy") {
        Set-RunStage -Stage "workflow-update.preflight" -Detail "Validating the master worktree and workflow source."
        Assert-WorkflowPackageUpdateContext
        Assert-WorkflowUpdateCommitIdentity

        $source = Resolve-WorkflowPackageSource
        Assert-WorkflowSourceOutsideProject -SourceRoot $source.root
        Set-RunStage -Stage "workflow-update.ai-rules-preflight" -Detail "Validating that the target ai_rules_1c release is installable."
        Assert-WorkflowSourceAiRulesInstallable -SourceRoot $source.root

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
    Ensure-OneCSessionLimitDotEnv | Out-Null
    $aiRulesPathsBefore = @(Get-AiRules1cManifestFileEntries | ForEach-Object { [string]$_.target })
    $clientSurfacePathsBefore = @(Get-WorkflowUpdateClientSurfacePaths)
    Ensure-Agent1cLifecycleLocksIgnored -WorktreePath $script:ProjectRoot
    Ensure-GitIgnore
    Sync-ItlVanessaLibraries
    Update-AgentGuidanceBridge
    Update-UserRules
    Sync-WorkflowManagedDependencyLockEntries | Out-Null
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
        Assert-AiRulesBaselineMigrationResult -Migration $migration
        if (-not $migration.migrated -and -not $migration.suppressRegularUpdate) {
            Update-AiRules1c
        }
    }

    # These actions can materialize tracked client/tool files. Keep them inside
    # the update transaction so the allowlist, commit, and final clean check own
    # every write performed by update-workflow.
    Install-ItlUiTools -BestEffort
    Sync-ItlClientSurface
    Sync-ItlClientUserEnvironment -Client (Get-ItlActiveClient)

    $workflowLock = ConvertTo-Agent1cHashtable -Object (Read-DependencyLockManifest)
    $workflowDependencies = ConvertTo-Agent1cHashtable -Object $workflowLock["dependencies"]
    $workflowEntry = ConvertTo-Agent1cHashtable -Object $workflowDependencies["workflowPackage"]
    Write-Host "ITL workflow package post-copy processing completed from $($workflowEntry['source'])."
    if ($workflowEntry["commit"]) {
        Write-Host "Workflow package commit: $($workflowEntry['commit'])"
    }
    $workflowSource = [pscustomobject]@{
        repo = [string]$workflowEntry["repo"]
        ref = [string]$workflowEntry["ref"]
        commit = [string]$workflowEntry["commit"]
        source = [string]$workflowEntry["source"]
    }
    Set-RunStage -Stage "workflow-update.commit" -Detail "Committing the managed workflow update in master."
    $commitResult = Commit-WorkflowUpdate -Source $workflowSource -AiRulesPathsBefore $aiRulesPathsBefore -ClientSurfacePathsBefore $clientSurfacePathsBefore
    Set-ItlOnDemandMcpSemanticReloadRequiredAction -Operation "update-workflow" | Out-Null
    Write-WorkflowUpdateFollowUp -Source $workflowSource -CommitResult $commitResult
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
    Write-Utf8TextAtomic -Path $path -Value (($State | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
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
    $resetStatus = [string](Get-StateValue -State $State -Name "resetStatus" -Default "")
    if ($resetStatus) {
        Write-Host "${Indent}Branch reset: $resetStatus / $(Get-StateValue -State $State -Name 'resetPhase' -Default '<unknown>')"
        $resetArchivePath = [string](Get-StateValue -State $State -Name "resetArchivePath" -Default "")
        if ($resetArchivePath) { Write-Host "${Indent}Branch reset archive: $resetArchivePath" }
        if ($resetStatus -eq "resetting") { Write-Host "${Indent}Recovery: repeat /itl-reset-branch in this worktree." }
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
        [string]$WorktreePath,
        [string]$SourceContext = "master"
    )

    Write-Host ""
    Write-Host "Ветка разработки создана."
    Write-Host ""
    Write-Host "Текущая папка осталась на ${SourceContext}:"
    Write-Host $MainProjectPath
    Write-Host ""
    Write-Host "Рабочая папка новой ветки:"
    Write-Host $WorktreePath
    Write-Host ""

    $client = Get-ItlActiveClient
    if ($client -eq "codex") {
        $instruction = "Откройте папку '$WorktreePath' в Codex как отдельный project (добавьте её, если project ещё не создан). После добавления project полностью перезапустите приложение Codex, чтобы оно перечитало проектный .codex/config.toml и подключило MCP-серверы. Затем создайте в этом project новую задачу в режиме Local. Режим Worktree не выбирайте: Git worktree и среда 1С уже созданы ITL."
        Write-Host $instruction
    } else {
        Write-Host "Чтобы продолжить работу агентом с этой линией разработки, откройте отдельное окно выбранного агента или IDE в этой папке."
        Write-Host "Могу попробовать открыть новое окно агента для этой папки автоматически."
        Write-Host "Новое окно прочитает контекст этого worktree при открытии; дополнительных действий для перечитывания контекста в нем не требуется."
        $instruction = "Откройте новое окно выбранного клиента или IDE в папке '$WorktreePath'. Новое окно прочитает контекст этого worktree при запуске; дополнительная перезагрузка клиента в нём не требуется."
    }

    $script:RunWorktreePath = $WorktreePath
    $script:RunRequiredAction = $instruction
}

function Write-PostInitClientReloadHandoff {
    $client = Get-ItlActiveClient
    if ($client -eq "codex") {
        $instruction = "После инициализации полностью перезапустите приложение Codex, чтобы оно перечитало проектный .codex/config.toml и подключило MCP-серверы. Затем откройте новую задачу в режиме Local в project master: только новая задача перечитает список skills, включая команды `$grill-me` и `$grill-with-docs`."
    } elseif ($client -eq "kilocode") {
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

function Add-ItlClientMcpEnablementRunUserReportLines {
    param(
        [System.Collections.Generic.List[string]]$McpLines,
        [System.Collections.Generic.List[string]]$AdviceLines
    )

    try {
        $observation = Get-ItlClientMcpEnablementObservation
    } catch {
        return
    }
    if (-not $observation.applicable) { return }

    $managedCoverage = if ($observation.expectedManagedCount -gt 0) {
        "$($observation.configuredManagedCount)/$($observation.expectedManagedCount)"
    } else {
        "<не определено>"
    }
    Add-RunUserReportLine -Lines $McpLines -Label "MCP в конфигурации Cursor" -Value "$($observation.configuredCount); управляемые ITL: $managedCoverage"
    Add-RunUserReportLine -Lines $McpLines -Label "Переключатели MCP в Cursor Agent" -Value "ITL не может проверить"
    if (@($observation.missingManagedServerIds).Count -gt 0) {
        $AdviceLines.Add("- В конфигурации Cursor отсутствуют управляемые MCP: $(@($observation.missingManagedServerIds) -join ', '). Выполните /itl-refresh и повторите /itl-status.")
    }
    if ($observation.instruction) {
        $AdviceLines.Add("- Обязательная проверка Cursor: $($observation.instruction)")
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
        Add-RunUserReportLine -Lines $lines -Label "Обновление исходной базы из хранилища" -Value (Get-RunUserReportObservedValue -Read { Get-SourceRepositoryUpdateMode })
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
    Add-ItlClientMcpEnablementRunUserReportLines -McpLines $lines -AdviceLines $advice
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
        [ValidateSet("created", "forked", "refreshed")]
        [string]$Operation = "created",
        [AllowNull()][object]$LoadResult = $null
    )

    Set-RunDevBranchState -State $State
    $lines = [System.Collections.Generic.List[string]]::new()
    $advice = [System.Collections.Generic.List[string]]::new()
    $isRefresh = $Operation -eq "refreshed"
    $isFork = $Operation -eq "forked"
    $lines.Add($(if ($isRefresh) { "## Обновление ветки разработки" } elseif ($isFork) { "## Копия ветки разработки" } else { "## Ветка разработки" }))
    if ($isRefresh -or $isFork) {
        Add-RunUserReportLine -Lines $lines -Label "Результат" -Value "успешно"
    }
    Add-RunUserReportLine -Lines $lines -Label "Тип" -Value (ConvertTo-RunUserReportStateDisplay -Value (Get-DevBranchKind -State $State) -Kind BranchKind)
    Add-RunUserReportLine -Lines $lines -Label "Ветка" -Value (Get-StateValue -State $State -Name "devBranch" -Default "")
    Add-RunUserReportLine -Lines $lines -Label "Основной worktree" -Value (Get-StateValue -State $State -Name "mainWorktreePath" -Default "")
    Add-RunUserReportLine -Lines $lines -Label "Worktree разработки" -Value (Get-StateValue -State $State -Name "worktreePath" -Default $AdvisoryRoot)
    Add-RunUserReportLine -Lines $lines -Label "Информационная база" -Value (Get-StateValue -State $State -Name "devBranchInfoBasePath" -Default "")
    if ($isFork) {
        Add-RunUserReportLine -Lines $lines -Label "Скопировано из ветки" -Value (Get-StateValue -State $State -Name "forkedFromBranch" -Default "")
        Add-RunUserReportLine -Lines $lines -Label "Исходный коммит" -Value (Get-StateValue -State $State -Name "forkedFromCommit" -Default "")
        Add-RunUserReportLine -Lines $lines -Label "История логов и проверок" -Value (Get-StateValue -State $State -Name "forkHistoryPath" -Default "")
        $verificationInherited = [bool](Get-StateValue -State $State -Name "forkVerificationInherited" -Default $false)
        Add-RunUserReportLine -Lines $lines -Label "Verification evidence" -Value $(if ($verificationInherited) { "fresh passed унаследована" } else { "скопирована как история; текущая проверка stale" })
        Add-RunUserReportLine -Lines $lines -Label "Решение по проверке" -Value (Get-StateValue -State $State -Name "forkVerificationReason" -Default "")
    }
    if ($isRefresh) {
        $refreshMode = [string](Get-StateValue -State $State -Name "lastRefreshMode" -Default "full")
        Add-RunUserReportLine -Lines $lines -Label "Режим" -Value $(if ($refreshMode -eq "lite") { "облегчённый, без исходной базы и seed" } else { "полный, с синхронизацией master" })
        Add-RunUserReportLine -Lines $lines -Label "Использованный коммит master" -Value (Get-StateValue -State $State -Name "lastRefreshMasterCommit" -Default "")
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
    Add-ItlClientMcpEnablementRunUserReportLines -McpLines $lines -AdviceLines $advice
    Add-KiloBrowserRunUserReportLines -McpLines $lines -AdviceLines $advice -ProjectRoot $AdvisoryRoot

    $extensionStatus = Get-DevBranchExtensionInitializationStatus -State $State
    if ($isRefresh) {
        $client = [string](Get-RunUserReportObservedValue -Read { Get-ItlActiveClient } -Default "")
        if (@(Get-ItlClientMcpSemanticChanges -Owner "ondemand-facade").Count -eq 0) {
            if ($client -eq "kilocode") {
                $advice.Add("- Если Kilo продолжает показывать старые команды или маршрутизацию, выполните /reload; при нормальном поведении дополнительный шаг не требуется.")
            } else {
                $reloadInstruction = [string](Get-RunUserReportObservedValue -Read {
                    Get-StateValue -State (Get-ItlClientAdapter -Client $client) -Name "reloadUserReport" -Default "Перезапустите активный клиент."
                } -Default "Перезапустите активный клиент.")
                $advice.Add("- Заставьте текущий клиент перечитать обновлённый проект: $reloadInstruction")
            }
        }
        $advice.Add("- Перед продолжением разработки выполните /itl-check.")
        if ((Get-DevBranchKind -State $State) -eq "extension") {
            $advice.Add("- Файлы расширения при обновлении ветки не загружались; /itl-check обновит расширение в базе перед проверкой.")
        }
    } elseif ($isFork) {
        if ([bool](Get-StateValue -State $State -Name "forkVerificationInherited" -Default $false)) {
            $advice.Add("- Уже проверенное состояние перенесено как fresh passed; повторять ту же проверку до новых изменений не требуется.")
        } else {
            $advice.Add("- Evidence и логи сохранены в истории, но условия безопасного наследования fresh passed не совпали; перед завершением новой работы выполните /itl-check.")
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

    Ensure-OneCSessionLimitDotEnv | Out-Null
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
    Assert-DevelopmentBranchWorktreeContext -State $state -Operation "activate-dev-branch-context"
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
        return (New-FileInfoBaseConnectionString -Path $InfoBasePath)
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

function Enter-LauncherListLock {
    param(
        [string]$ListPath,
        [int]$TimeoutSeconds = 30
    )

    $lockPath = "$ListPath.itl.lock"
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $lockPath) | Out-Null
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        try {
            return [System.IO.File]::Open(
                $lockPath,
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None
            )
        } catch [System.IO.IOException] {
            if ((Get-Date) -ge $deadline) {
                throw "LAUNCHER_LIST_LOCK_TIMEOUT path='$lockPath' timeoutSeconds='$TimeoutSeconds'"
            }
            Start-Sleep -Milliseconds 50
        }
    } while ($true)
}

function Register-DevBranchInLauncher {
    param(
        [string]$InfoBaseKind,
        [string]$InfoBasePath,
        [string]$SafeDevBranchName,
        [string]$ProjectRootForFolder = $script:ProjectRoot,
        [string]$ExistingLauncherId = ""
    )

    $listLock = Enter-LauncherListLock -ListPath (Get-LauncherListPath)
    try {
        return (Register-DevBranchInLauncherUnlocked @PSBoundParameters)
    } finally {
        $listLock.Dispose()
    }
}

function Register-DevBranchInLauncherUnlocked {
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

function Assert-GitAuthoritativeExportPathHasNoCaseCollisions {
    param([string]$ExportPath)

    $trackedPaths = @(Get-GitPathList -Arguments @("ls-files", "-z", "--", $ExportPath))
    $firstPathByCaseInsensitiveKey = [System.Collections.Generic.Dictionary[string,string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    $collidingPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)

    foreach ($trackedPath in $trackedPaths) {
        [string]$firstPath = ""
        if ($firstPathByCaseInsensitiveKey.TryGetValue($trackedPath, [ref]$firstPath)) {
            if ($firstPath -cne $trackedPath) {
                $collidingPaths.Add($firstPath) | Out-Null
                $collidingPaths.Add($trackedPath) | Out-Null
            }
            continue
        }
        $firstPathByCaseInsensitiveKey.Add($trackedPath, $trackedPath)
    }

    if ($collidingPaths.Count -gt 0) {
        $sortedCollisions = @($collidingPaths)
        [System.Array]::Sort($sortedCollisions, [System.StringComparer]::Ordinal)
        throw @"
GIT_CASE_COLLISION_IN_AUTHORITATIVE_DUMP: the rebuilt Git index contains tracked paths that are equal under OrdinalIgnoreCase.
ExportPath: $ExportPath
Colliding tracked paths:
$(@($sortedCollisions | ForEach-Object { "- $_" }) -join [Environment]::NewLine)
"@
    }
}

function Commit-AuthoritativeExportPathIfChanged {
    param(
        [string]$Message,
        [string]$ExportPath
    )

    $absoluteExportPath = Assert-ExportPathInsideProject -ExportPath $ExportPath
    $projectRoot = (Resolve-Agent1cFullPath -Path $script:ProjectRoot).TrimEnd("\", "/")
    if ([string]::Equals($absoluteExportPath, $projectRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-Path -LiteralPath $absoluteExportPath -PathType Container)) {
        throw "Authoritative export path must be an existing project subdirectory: $absoluteExportPath"
    }
    $repoExportPath = $absoluteExportPath.Substring($projectRoot.Length).TrimStart("\", "/").Replace("\", "/")

    $attributesChanged = Ensure-OneCSourceGitAttributes
    Invoke-Git @("add", "--", ".gitattributes")
    $rebuildPaths = @($repoExportPath, (Get-ExtensionsPath))
    if ($attributesChanged) {
        $rebuildPaths += "src/configs"
    }
    $sourcePaths = @(Rebuild-OneCSourceGitIndex -SourcePaths $rebuildPaths)
    Assert-GitAuthoritativeExportPathHasNoCaseCollisions -ExportPath $repoExportPath

    $commitPaths = @(".gitattributes") + $sourcePaths
    if (Test-GitHasStagedChanges -PathSpec $commitPaths) {
        # A commit pathspec re-reads case-insensitive worktree aliases instead of committing this rebuilt index.
        Invoke-Git @("commit", "--quiet", "-m", $Message)
        Write-Host "Committed: $Message"
        return $true
    }

    Write-Host "No Git changes to commit for: $($commitPaths -join ', ')"
    return $false
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
        "init.mcp-selection",
        "init.mcp-selection-complete",
        "init.interactive-complete",
        "init.prepare-runtime",
        "init.runtime-check-tools",
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
    Assert-Agent1cInitialProjectRootPathBudget | Out-Null
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
    Sync-WorkflowManagedDependencyLockEntries | Out-Null
    $dumpWasCompleted = ($InitMode -eq "resume" -and (Test-InitStageAtLeast -Stage $resumeStage -Expected "init.commit-dump") -and (Test-InitDumpArtifactsReady))
    $unsafeActionProtectionWasCompleted = ($InitMode -eq "resume" -and (Test-InitStageAtLeast -Stage $resumeStage -Expected "init.unsafe-action-protection-complete"))
    $interactiveQuestionsWereCompleted = ($InitMode -eq "resume" -and (Test-InitStageAtLeast -Stage $resumeStage -Expected "init.interactive-complete"))
    $allowInteractiveInitPrompts = $InitMode -eq "wizard" -or ($InitMode -eq "resume" -and -not $interactiveQuestionsWereCompleted)
    if (-not $dumpWasCompleted) {
        if (-not $unsafeActionProtectionWasCompleted) {
            Set-RunStage -Stage "init.unsafe-action-protection" -Detail "Confirming source infobase unsafe action protection"
            Initialize-SourceInfoBaseUnsafeActionProtection
            Set-RunStage -Stage "init.unsafe-action-protection-complete" -Detail "Source infobase unsafe action protection resolved"
        } else {
            Write-Host "Resume confirmed that source infobase unsafe action protection setup completed in the interrupted run."
        }
    }

    $vibecodingRequested = $script:InitVibecoding1cMcpSetupRequested -or (ConvertTo-YesNoBool -Value (Get-EnvValue -Name "VIBECODING1C_MCP_SETUP_DURING_INIT" -Default $true) -Default $true)
    $vibecodingAlreadyCompleted = $InitMode -eq "resume" -and (Test-InitStageAtLeast -Stage $resumeStage -Expected "init.final-git-clean")
    if ($vibecodingRequested -and -not $vibecodingAlreadyCompleted) {
        Set-RunStage -Stage "init.mcp-selection" -Detail "Collecting vibecoding1c MCP choices before unattended initialization"
        Prepare-Vibecoding1cMcpSelectionForInit -AllowPrompt:$allowInteractiveInitPrompts
        Set-RunStage -Stage "init.mcp-selection-complete" -Detail "vibecoding1c MCP choices are complete"
    }

    Set-RunStage -Stage "init.interactive-complete" -Detail "All initialization questions are complete"
    Write-Host ""
    Write-Host (Get-Agent1cUtf8Text "0JLRgdC1INCy0L7Qv9GA0L7RgdGLINC40L3QuNGG0LjQsNC70LjQt9Cw0YbQuNC4INC30LDQstC10YDRiNC10L3Riy4g0J3QsNGH0LjQvdCw0LXRgtGB0Y8g0LTQu9C40YLQtdC70YzQvdCw0Y8g0LDQstGC0L7QvNCw0YLQuNGH0LXRgdC60LDRjyDQvdCw0YHRgtGA0L7QudC60LA7INC00LDQu9GM0L3QtdC50YjQuNC5INCy0LLQvtC0INC90LUg0L/QvtGC0YDQtdCx0YPQtdGC0YHRjy4=")
    Write-Host ""
    Set-RunStage -Stage "init.prepare-runtime" -Detail "Preparing initialization runtime dependencies"
    Complete-InitProjectSettingsPreparation

    if (-not $dumpWasCompleted) {
        Set-RunStage -Stage "init.runtime-check-tools" -Detail "Checking required tools"
        Check-Tools -StopOnMissing
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

    $sourceRepositoryUpdated = $false
    if (-not $dumpWasCompleted) {
        Set-RunStage -Stage "init.repository-update" -Detail "Applying the source repository update policy"
        $sourceRepositoryUpdated = Update-BaseFromRepository
        Set-RunStage -Stage "init.dump-config" -Detail "Dumping 1C configuration files"
        $dumpResult = Dump-ConfigToFiles
        Set-RunStage -Stage "init.fingerprint" -Detail "Calculating the authoritative configuration fingerprint"
        $configSource = Get-ConfigSourceFingerprint -ExportPath $dumpResult.exportPath
        Set-RunStage -Stage "init.seed" -Detail "Rebuilding the branch seed"
        Ensure-BranchSeed `
            -Policy "Rebuild" `
            -ConfigurationFingerprint $configSource.fingerprint `
            -ConfigurationFileCount $configSource.fileCount | Out-Null
        $dumpResult = [pscustomobject]@{
            exportPath = Get-ExportPath
            absoluteExportPath = Assert-ExportPathInsideProject (Get-ExportPath)
            incremental = $false
            logPath = $script:LastLogPath
        }
    } else {
        $dumpResult = [pscustomobject]@{
            exportPath = Get-ExportPath
            absoluteExportPath = Assert-ExportPathInsideProject (Get-ExportPath)
            incremental = $true
            logPath = ""
        }
        $existingSeed = Read-BranchSeedManifest -AllowMissing
        if ($null -eq $existingSeed -or -not (Test-BranchSeedArtifactReady -Manifest $existingSeed)) {
            Set-RunStage -Stage "init.fingerprint" -Detail "Calculating the authoritative configuration fingerprint"
            $configSource = Get-ConfigSourceFingerprint -ExportPath $dumpResult.exportPath
            Set-RunStage -Stage "init.seed" -Detail "Rebuilding the branch seed"
            Ensure-BranchSeed `
                -Policy "Rebuild" `
                -ConfigurationFingerprint $configSource.fingerprint `
                -ConfigurationFileCount $configSource.fileCount | Out-Null
        }
    }
    $dumpMessage = if ($sourceRepositoryUpdated) { "sync: export 1C configuration from repository" } else { "sync: export current 1C configuration from source infobase" }
    Set-RunStage -Stage "init.commit-dump" -Detail "Committing baseline 1C configuration dump"
    Commit-AuthoritativeExportPathIfChanged -Message $dumpMessage -ExportPath $dumpResult.exportPath | Out-Null
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
    if ($vibecodingRequested -and -not $vibecodingAlreadyCompleted) {
        Set-RunStage -Stage "init.vibecoding1c-mcp" -Detail "Setting up vibecoding1c MCP"
        Setup-Vibecoding1cMcp -AllowPrompt:$false
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
    param(
        [switch]$NoDelegate,
        [ValidateSet("EnsureCompatible", "Rebuild")]
        [string]$SeedPolicy = "Rebuild"
    )

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
                    Sync-Master -NoDelegate -SeedPolicy $SeedPolicy
                }
                return
            }
        }
    }

    Assert-CleanGit
    Checkout-Master
    Clear-DevBranchContext
    $sourceUsesRepository = Get-SourceUsesRepository
    $sourceRepositoryUpdateMode = Get-SourceRepositoryUpdateMode
    Set-RunStage -Stage "sync-master.repository-update" -Detail "Applying the source repository update policy"
    $sourceRepositoryUpdated = Update-BaseFromRepository
    if ($SeedPolicy -eq "Rebuild" -and (Get-InfoBaseKind) -eq "file") {
        Set-RunStage -Stage "sync-master.seed" -Detail "Rebuilding the branch seed from the source infobase"
        $seed = Ensure-BranchSeed -Policy "Rebuild" -ConfigurationFingerprint "" -ConfigurationFileCount 0
        $dumpResult = [pscustomobject]@{
            exportPath = Get-ExportPath
            absoluteExportPath = Assert-ExportPathInsideProject (Get-ExportPath)
            incremental = $false
            logPath = $script:LastLogPath
        }
    } else {
        Set-RunStage -Stage "sync-master.dump-config" -Detail "Dumping the authoritative 1C configuration"
        $dumpResult = Dump-ConfigToFiles
        Set-RunStage -Stage "sync-master.fingerprint" -Detail "Calculating the authoritative configuration fingerprint"
        $configSource = Get-ConfigSourceFingerprint -ExportPath $dumpResult.exportPath
        Set-RunStage -Stage "sync-master.seed" -Detail "Ensuring a compatible branch seed"
        $seed = Ensure-BranchSeed `
            -Policy $SeedPolicy `
            -ConfigurationFingerprint $configSource.fingerprint `
            -ConfigurationFileCount $configSource.fileCount
    }
    $dumpMessage = if ($sourceRepositoryUpdated) { "sync: refresh 1C configuration from repository" } else { "sync: capture current 1C configuration from source infobase" }
    Set-RunStage -Stage "sync-master.commit" -Detail "Committing the authoritative configuration dump"
    Commit-AuthoritativeExportPathIfChanged -Message $dumpMessage -ExportPath $dumpResult.exportPath | Out-Null
    Sync-KiloItlCommandSurface
    Write-Host "Branch seed: $($seed.artifactPath)"
    Write-Host "Branch seed sync ID: $($seed.syncId)"
    $report = [System.Collections.Generic.List[string]]::new()
    $report.Add("## Синхронизация master и seed")
    Add-RunUserReportLine -Lines $report -Label "Результат" -Value "успешно"
    Add-RunUserReportLine -Lines $report -Label "Режим обновления из хранилища" -Value $sourceRepositoryUpdateMode
    Add-RunUserReportLine -Lines $report -Label "Обновление исходной базы из хранилища" -Value $(if ($sourceRepositoryUpdated) { "выполнено ITL" } elseif ($sourceUsesRepository) { "пропущено; используется текущее состояние исходной базы" } else { "не применяется" })
    Add-RunUserReportLine -Lines $report -Label "Коммит master" -Value (Get-CurrentCommit)
    Add-RunUserReportLine -Lines $report -Label "Seed sync ID" -Value ([string]$seed.syncId)
    Add-RunUserReportLine -Lines $report -Label "Seed" -Value ([string]$seed.artifactPath)
    Add-RunUserReportLine -Lines $report -Label "Тип seed" -Value ([string]$seed.artifactKind)
    Add-RunUserReportLine -Lines $report -Label "Fingerprint конфигурации" -Value ([string]$seed.configurationFingerprint)
    Add-RunUserReportLine -Lines $report -Label "Baseline-сигнатуры" -Value ([int]$seed.baselineCount)
    Add-RunUserReportLine -Lines $report -Label "Состояние seed" -Value ([string]$seed.status)
    Write-AndSetRunUserReport -Lines $report
}

function Get-ConfigDumpInfoRepoPathsAtCommit {
    param([string]$Commit)

    $paths = @()
    foreach ($path in @(Get-GitPathList -Arguments @("ls-tree", "-r", "--name-only", "-z", $Commit))) {
        $normalizedPath = ([string]$path).Replace("\", "/").Trim()
        if ($normalizedPath -and ([System.IO.Path]::GetFileName($normalizedPath) -ieq "ConfigDumpInfo.xml")) {
            $paths += $normalizedPath
        }
    }
    return @($paths | Sort-Object -Unique)
}

function Test-GitMergeInProgress {
    $mergeHeadPath = (Get-GitOutput @("rev-parse", "--git-path", "MERGE_HEAD")).Trim()
    if (-not [System.IO.Path]::IsPathRooted($mergeHeadPath)) {
        $mergeHeadPath = Join-Path $script:ProjectRoot $mergeHeadPath
    }
    return (Test-Path -LiteralPath $mergeHeadPath -PathType Leaf)
}

function Get-GitMergeHeadCommit {
    if (-not (Test-GitMergeInProgress)) {
        return ""
    }
    return (Get-GitOutput @("rev-parse", "MERGE_HEAD")).Trim()
}

function Get-GitCommitParents {
    param([string]$Commit)

    $record = (Get-GitOutput @("rev-list", "--parents", "-n", "1", $Commit)).Trim()
    if (-not $record) {
        return @()
    }
    $parts = @($record -split '\s+' | Where-Object { $_ })
    if ($parts.Count -le 1) {
        return @()
    }
    return @($parts[1..($parts.Count - 1)])
}

function Test-GitCommitIsAncestor {
    param(
        [string]$Ancestor,
        [string]$Descendant
    )

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & git -C $script:ProjectRoot merge-base --is-ancestor $Ancestor $Descendant *> $null
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($exitCode -eq 0) { return $true }
    if ($exitCode -eq 1) { return $false }
    throw "Cannot test Git ancestry for '$Ancestor' and '$Descendant'."
}

function Test-GitCommitHasExactMergeParents {
    param(
        [string]$Commit,
        [string]$FirstParent,
        [string]$SecondParent
    )

    $parents = @(Get-GitCommitParents -Commit $Commit)
    return ($parents.Count -eq 2 -and $parents[0] -ceq $FirstParent -and $parents[1] -ceq $SecondParent)
}

function Assert-DevBranchLifecycleMergeCommitPaths {
    param(
        [string]$BranchCommit,
        [string]$MergeCommit,
        [string[]]$AllowedPaths
    )

    if (@($AllowedPaths).Count -eq 0) {
        return
    }
    $committedPaths = @(
        Get-GitPathList -Arguments @("diff", "--name-only", "-z", $BranchCommit, $MergeCommit, "--") |
            ForEach-Object { ([string]$_).Replace("\", "/").Trim() } |
            Where-Object { $_ } |
            Sort-Object -Unique
    )
    $unexpectedPaths = @($committedPaths | Where-Object { @($AllowedPaths) -cnotcontains $_ })
    if ($unexpectedPaths.Count -gt 0) {
        throw "LIFECYCLE_MERGE_COMMIT_PATHS_MISMATCH branchCommit='$BranchCommit' mergeCommit='$MergeCommit' files='$($unexpectedPaths -join ', ')'."
    }
}

function Get-DevBranchMergeIndexPaths {
    return @(
        @(
            Get-GitPathList -Arguments @("diff", "--cached", "--name-only", "-z", "--diff-filter=ACMRTUXBD", "--")
            Get-GitPathList -Arguments @("diff", "--name-only", "-z", "--diff-filter=U", "--")
        ) |
            ForEach-Object { ([string]$_).Replace("\", "/").Trim() } |
            Where-Object { $_ } |
            Sort-Object -Unique
    )
}

function Get-DevBranchMergeUnmergedPaths {
    return @(
        Get-GitPathList -Arguments @("diff", "--name-only", "-z", "--diff-filter=U", "--") |
            ForEach-Object { ([string]$_).Replace("\", "/").Trim() } |
            Where-Object { $_ } |
            Sort-Object -Unique
    )
}

function Get-DevBranchMergeUnstagedPaths {
    return @(
        Get-GitPathList -Arguments @("diff", "--name-only", "-z", "--diff-filter=ACMRTUXBD", "--") |
            ForEach-Object { ([string]$_).Replace("\", "/").Trim() } |
            Where-Object { $_ } |
            Sort-Object -Unique
    )
}

function Get-DevBranchMergeUntrackedPaths {
    return @(
        Get-GitPathList -Arguments @("ls-files", "-z", "--others", "--exclude-standard", "--") |
            ForEach-Object { ([string]$_).Replace("\", "/").Trim() } |
            Where-Object { $_ } |
            Sort-Object -Unique
    )
}

function Get-PendingDevBranchMergeTransaction {
    param([object]$State)

    $operation = [string](Get-StateValue -State $State -Name "pendingMergeOperation" -Default "")
    $targetCommit = [string](Get-StateValue -State $State -Name "pendingMergeTargetCommit" -Default "")
    $legacy = $false
    if (-not $operation -and -not $targetCommit) {
        $operation = [string](Get-StateValue -State $State -Name "pendingRefreshOperation" -Default "")
        $targetCommit = [string](Get-StateValue -State $State -Name "pendingRefreshMasterCommit" -Default "")
        $legacy = [bool]($operation -or $targetCommit)
    }
    if (-not $operation -and -not $targetCommit) {
        return $null
    }

    return [pscustomobject]@{
        operation = $operation
        branch = [string](Get-StateValue -State $State -Name "pendingMergeBranch" -Default (Get-StateValue -State $State -Name "devBranch" -Default ""))
        branchCommit = [string](Get-StateValue -State $State -Name "pendingMergeBranchCommit" -Default "")
        targetCommit = $targetCommit
        stage = [string](Get-StateValue -State $State -Name "pendingMergeStage" -Default $(if ($legacy) { "legacy" } else { "" }))
        allowedPaths = @(Get-StateValue -State $State -Name "pendingMergePaths" -Default @())
        conflictPaths = @(Get-StateValue -State $State -Name "pendingMergeConflictPaths" -Default @())
        mergeCommit = [string](Get-StateValue -State $State -Name "pendingMergeCommit" -Default "")
        postMergeHead = [string](Get-StateValue -State $State -Name "pendingMergePostMergeHead" -Default "")
        result = [string](Get-StateValue -State $State -Name "pendingMergeResult" -Default "")
        legacy = $legacy
    }
}

function Set-PendingDevBranchMergeTransaction {
    param(
        [object]$State,
        [string]$Operation,
        [string]$Branch,
        [string]$BranchCommit,
        [string]$TargetCommit,
        [string]$Stage,
        [string[]]$AllowedPaths = @(),
        [string[]]$ConflictPaths = @(),
        [string]$MergeCommit = "",
        [string]$PostMergeHead = "",
        [string]$Result = ""
    )

    $isRefresh = $Operation -in @("refresh-dev-branch", "refresh-dev-branch-lite")
    Update-DevBranchState -State $State -Updates @{
        pendingMergeOperation = $Operation
        pendingMergeBranch = $Branch
        pendingMergeBranchCommit = $BranchCommit
        pendingMergeTargetCommit = $TargetCommit
        pendingMergeStage = $Stage
        pendingMergePaths = @($AllowedPaths | Sort-Object -Unique)
        pendingMergeConflictPaths = @($ConflictPaths | Sort-Object -Unique)
        pendingMergeCommit = $MergeCommit
        pendingMergePostMergeHead = $PostMergeHead
        pendingMergeResult = $Result
        pendingRefreshMasterCommit = $(if ($isRefresh) { $TargetCommit } else { "" })
        pendingRefreshOperation = $(if ($isRefresh) { $Operation } else { "" })
    }
}

function Add-PendingDevBranchMergeClearUpdates {
    param([hashtable]$Updates)

    foreach ($name in @(
        "pendingMergeOperation",
        "pendingMergeBranch",
        "pendingMergeBranchCommit",
        "pendingMergeTargetCommit",
        "pendingMergeStage",
        "pendingMergeCommit",
        "pendingMergePostMergeHead",
        "pendingMergeResult",
        "pendingRefreshMasterCommit",
        "pendingRefreshOperation"
    )) {
        $Updates[$name] = ""
    }
    $Updates["pendingMergePaths"] = @()
    $Updates["pendingMergeConflictPaths"] = @()
}

function Stop-DevBranchLifecycleMergeForConflicts {
    param(
        [string]$Operation,
        [string]$Stage,
        [string[]]$ConflictPaths,
        [string]$Reason = "merge conflicts remain"
    )

    $paths = @($ConflictPaths | Where-Object { $_ } | Sort-Object -Unique)
    Set-RunStage -Stage $Stage -Detail "$Reason; resolve the listed files, run git add, and repeat $Operation."
    Set-RunFailureContext `
        -Category "merge-conflict" `
        -RequiredAction "resolve-conflicts-run-git-add-repeat-same-itl-command-no-manual-commit"
    $pathText = if ($paths.Count -gt 0) { $paths -join ", " } else { "<none>" }
    throw "LIFECYCLE_MERGE_CONFLICT operation='$Operation' reason='$Reason' files='$pathText'. Resolve the listed conflicts, run git add for the resolved files, and repeat the same ITL command. Do not create the merge commit manually; the workflow will run git commit --no-edit after validation."
}

function Restore-BranchConfigDumpInfoFromCommit {
    param(
        [string]$Commit,
        [string[]]$RepoPaths
    )

    $branchPaths = @(Get-ConfigDumpInfoRepoPathsAtCommit -Commit $Commit)
    foreach ($repoPath in @($RepoPaths)) {
        if ($branchPaths -ccontains $repoPath) {
            Invoke-Git @("checkout", $Commit, "--", $repoPath)
            Invoke-Git @("add", "--", $repoPath)
        } else {
            Invoke-Git @("rm", "-f", "--ignore-unmatch", "--", $repoPath)
        }
    }
}

function Test-OneCSourceByteContractTransition {
    param(
        [string]$BranchCommit,
        [string]$TargetCommit
    )

    return (-not (Test-OneCSourceGitAttributesAtCommit -Commit $BranchCommit) -and
        (Test-OneCSourceGitAttributesAtCommit -Commit $TargetCommit))
}

function Complete-OneCSourceByteContractMergeTransition {
    param(
        [string]$BranchCommit,
        [string]$TargetCommit,
        [string[]]$CursorPaths = @()
    )

    $mergeBase = (Get-GitOutput @("merge-base", $BranchCommit, $TargetCommit)).Trim()
    $branchChangedSourcePaths = @(Get-GitPathList -Arguments @(
        "diff", "--name-only", "-z", "--diff-filter=ACMRTUXBD", $mergeBase, $BranchCommit,
        "--", (Get-ExportPath), (Get-ExtensionsPath), "src/configs"
    ))
    Update-OneCSourceGitIndexFromWorktreePaths -RepoPaths @($branchChangedSourcePaths + $CursorPaths)
    Invoke-Git @("checkout-index", "--force", "--all")
}

function Test-GitWorktreePathDiffersOnlyByCarriageReturnsAtEol {
    param([string]$RepoPath)

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & git -C $script:ProjectRoot diff --ignore-cr-at-eol --quiet -- $RepoPath 2>$null
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($exitCode -eq 0) { return $true }
    if ($exitCode -eq 1) { return $false }
    throw "Cannot compare the worktree path with the merge index while ignoring carriage returns at EOL: $RepoPath"
}

function Merge-MasterPreservingBranchConfigDumpInfo {
    param(
        [string]$MasterBranch = (Get-MasterBranch),
        [string]$BranchCommit = (Get-CurrentCommit)
    )

    $branchDumpInfoPaths = @(Get-ConfigDumpInfoRepoPathsAtCommit -Commit $BranchCommit)
    $targetDumpInfoPaths = @(Get-ConfigDumpInfoRepoPathsAtCommit -Commit $MasterBranch)
    $allDumpInfoPaths = @($branchDumpInfoPaths + $targetDumpInfoPaths | Sort-Object -Unique)
    $sourceByteContractTransition = Test-OneCSourceByteContractTransition -BranchCommit $BranchCommit -TargetCommit $MasterBranch
    $mergeArgs = @("merge", "--no-ff", "--no-commit")
    if ($sourceByteContractTransition) {
        # Old branch blobs were normalized to LF while their worktree bytes were
        # materialized as CRLF. This option is limited to the one contract transition.
        $mergeArgs += "-Xignore-space-at-eol"
        Write-Host "Migrating the development branch to byte-preserving 1C source attributes during the master merge."
    }
    $mergeArgs += $MasterBranch
    $mergeException = $null
    try {
        Invoke-Git $mergeArgs
    } catch {
        $mergeException = $_
    }

    if (-not (Test-GitMergeInProgress)) {
        if ($mergeException) {
            throw $mergeException
        }
        return
    }

    Restore-BranchConfigDumpInfoFromCommit -Commit $BranchCommit -RepoPaths $allDumpInfoPaths
    $remainingConflicts = @(Get-DevBranchMergeUnmergedPaths)
    if ($remainingConflicts.Count -gt 0) {
        throw "Master merge still has non-ConfigDumpInfo conflicts after preserving the branch synchronization cursor: $($remainingConflicts -join ', ')"
    }
    if ($sourceByteContractTransition) {
        Complete-OneCSourceByteContractMergeTransition `
            -BranchCommit $BranchCommit `
            -TargetCommit $MasterBranch `
            -CursorPaths $allDumpInfoPaths
    }
    Assert-OneCConfigurationSourceIntegrity -ExportPath (Get-ExportPath)
    Invoke-Git @("commit", "--no-edit")
}

function Complete-DevBranchLifecycleMergeTransaction {
    param(
        [object]$State,
        [object]$Transaction
    )

    $head = Get-CurrentCommit
    $result = ""
    if ($head -ceq $Transaction.branchCommit -and (Test-GitCommitIsAncestor -Ancestor $Transaction.targetCommit -Descendant $head)) {
        $result = "already-up-to-date"
    } elseif (Test-GitCommitHasExactMergeParents -Commit $head -FirstParent $Transaction.branchCommit -SecondParent $Transaction.targetCommit) {
        $result = "merge-commit"
        Assert-DevBranchLifecycleMergeCommitPaths `
            -BranchCommit $Transaction.branchCommit `
            -MergeCommit $head `
            -AllowedPaths $Transaction.allowedPaths
    } else {
        throw "LIFECYCLE_MERGE_RESULT_MISMATCH operation='$($Transaction.operation)' branchCommit='$($Transaction.branchCommit)' targetCommit='$($Transaction.targetCommit)' head='$head'."
    }

    Set-PendingDevBranchMergeTransaction `
        -State $State `
        -Operation $Transaction.operation `
        -Branch $Transaction.branch `
        -BranchCommit $Transaction.branchCommit `
        -TargetCommit $Transaction.targetCommit `
        -Stage "merged" `
        -AllowedPaths $Transaction.allowedPaths `
        -ConflictPaths @() `
        -MergeCommit $head `
        -PostMergeHead $head `
        -Result $result
}

function Assert-DevBranchLifecycleMergeRecordedResult {
    param(
        [object]$Transaction,
        [string]$Operation
    )

    $mergeCommit = [string]$Transaction.mergeCommit
    if ($mergeCommit -notmatch '^[a-f0-9]{40}$' -or -not (Test-GitCommitExists -Commit $mergeCommit)) {
        throw "LIFECYCLE_MERGE_COMMIT_INVALID operation='$Operation' commit='$mergeCommit'."
    }
    if ($Transaction.result -ceq "merge-commit") {
        if (-not (Test-GitCommitHasExactMergeParents -Commit $mergeCommit -FirstParent $Transaction.branchCommit -SecondParent $Transaction.targetCommit)) {
            throw "LIFECYCLE_MERGE_RESULT_MISMATCH operation='$Operation' recordedMergeCommit='$mergeCommit'."
        }
        return
    }
    if ($Transaction.result -ceq "already-up-to-date") {
        if ($mergeCommit -cne $Transaction.branchCommit -or -not (Test-GitCommitIsAncestor -Ancestor $Transaction.targetCommit -Descendant $mergeCommit)) {
            throw "LIFECYCLE_MERGE_RESULT_MISMATCH operation='$Operation' recordedNoOpCommit='$mergeCommit'."
        }
        return
    }
    throw "LIFECYCLE_MERGE_RESULT_MISMATCH operation='$Operation' recordedResult='$($Transaction.result)' recordedMergeCommit='$mergeCommit'."
}

function Test-DevBranchLifecycleHelperOwnedPostMergeHead {
    param(
        [object]$Transaction,
        [string]$CandidateHead,
        [switch]$LegacyCursorOnly
    )

    if ($Transaction.operation -notin @("refresh-dev-branch", "refresh-dev-branch-lite")) { return $false }
    if ($CandidateHead -notmatch '^[a-f0-9]{40}$' -or -not (Test-GitCommitExists -Commit $CandidateHead)) { return $false }
    $parents = @(Get-GitCommitParents -Commit $CandidateHead)
    if ($parents.Count -ne 1 -or $parents[0] -cne $Transaction.mergeCommit) { return $false }

    $subject = (Get-GitOutput @("show", "-s", "--format=%s", $CandidateHead)).Trim()
    $paths = @(
        Get-GitPathList -Arguments @("diff-tree", "--no-commit-id", "--name-only", "-r", "-z", $CandidateHead, "--") |
            ForEach-Object { ([string]$_).Replace("\", "/").Trim() } |
            Where-Object { $_ } |
            Sort-Object -Unique
    )
    $normalizedExportPath = ([string](Get-ExportPath)).Replace("\", "/").Trim("/")
    $cursorPath = "$normalizedExportPath/ConfigDumpInfo.xml"
    if ($subject -ceq "chore: persist branch configuration synchronization cursor") {
        return ($paths.Count -eq 1 -and $paths[0] -ceq $cursorPath)
    }
    if ($LegacyCursorOnly -or $subject -cne "chore: persist branch refresh state") { return $false }

    $allowedPaths = @($cursorPath, ".kilo/kilo.json")
    return ($paths.Count -ge 1 -and $paths.Count -le 2 -and
        $paths -ccontains ".kilo/kilo.json" -and
        @($paths | Where-Object { $allowedPaths -cnotcontains $_ }).Count -eq 0)
}

function Resolve-DevBranchLifecyclePostMergeHead {
    param(
        [object]$State,
        [object]$Transaction,
        [string]$Operation,
        [switch]$AllowLegacyCursorMigration
    )

    Assert-DevBranchLifecycleMergeRecordedResult -Transaction $Transaction -Operation $Operation
    $head = Get-CurrentCommit
    $recordedPostMergeHead = [string]$Transaction.postMergeHead
    if ($recordedPostMergeHead) {
        if ($recordedPostMergeHead -cne $Transaction.mergeCommit -and
            -not (Test-DevBranchLifecycleHelperOwnedPostMergeHead -Transaction $Transaction -CandidateHead $recordedPostMergeHead)) {
            throw "LIFECYCLE_MERGE_POST_HEAD_INVALID operation='$Operation' mergeCommit='$($Transaction.mergeCommit)' recordedPostMergeHead='$recordedPostMergeHead'."
        }
        if ($head -cne $recordedPostMergeHead) {
            throw "LIFECYCLE_MERGE_POST_HEAD_MISMATCH operation='$Operation' expected='$recordedPostMergeHead' actual='$head'."
        }
        return $head
    }

    if ($head -ceq $Transaction.mergeCommit) {
        Update-DevBranchState -State $State -Updates @{ pendingMergePostMergeHead = $head }
        return $head
    }
    if ($AllowLegacyCursorMigration -and
        (Test-DevBranchLifecycleHelperOwnedPostMergeHead -Transaction $Transaction -CandidateHead $head -LegacyCursorOnly)) {
        Update-DevBranchState -State $State -Updates @{ pendingMergePostMergeHead = $head }
        return $head
    }
    throw "LIFECYCLE_MERGE_POST_HEAD_MISMATCH operation='$Operation' expected='$($Transaction.mergeCommit)' actual='$head'."
}

function Set-DevBranchLifecyclePostMergeHeadCheckpoint {
    param(
        [object]$State,
        [string]$Operation,
        [string]$PostMergeHead = (Get-CurrentCommit)
    )

    $transaction = Get-PendingDevBranchMergeTransaction -State $State
    if ($null -eq $transaction -or $transaction.operation -cne $Operation -or $transaction.stage -cne "merged") {
        throw "LIFECYCLE_MERGE_TRANSACTION_NOT_COMMITTED operation='$Operation' phase='post-merge-checkpoint'."
    }
    Assert-DevBranchLifecycleMergeRecordedResult -Transaction $transaction -Operation $Operation
    if ($PostMergeHead -cne $transaction.mergeCommit -and
        -not (Test-DevBranchLifecycleHelperOwnedPostMergeHead -Transaction $transaction -CandidateHead $PostMergeHead)) {
        throw "LIFECYCLE_MERGE_POST_HEAD_INVALID operation='$Operation' mergeCommit='$($transaction.mergeCommit)' postMergeHead='$PostMergeHead'."
    }
    Update-DevBranchState -State $State -Updates @{ pendingMergePostMergeHead = $PostMergeHead }
}

function Invoke-NewDevBranchLifecycleMerge {
    param(
        [object]$State,
        [string]$Operation,
        [string]$TargetCommit,
        [string]$ConflictStage
    )

    $branch = [string](Get-StateValue -State $State -Name "devBranch" -Default "")
    $branchCommit = Get-CurrentCommit
    Set-PendingDevBranchMergeTransaction `
        -State $State `
        -Operation $Operation `
        -Branch $branch `
        -BranchCommit $branchCommit `
        -TargetCommit $TargetCommit `
        -Stage "prepared"

    try {
        Merge-MasterPreservingBranchConfigDumpInfo -MasterBranch $TargetCommit -BranchCommit $branchCommit
    } catch {
        $mergeFailure = $_
        if (-not (Test-GitMergeInProgress)) {
            throw $mergeFailure
        }
        $stateAfterConflict = Read-DevBranchState -Name $DevBranchName
        $allowedPaths = @(Get-DevBranchMergeIndexPaths)
        $conflictPaths = @(Get-DevBranchMergeUnmergedPaths)
        $sourceValidationFailure = $mergeFailure.Exception.Message -match '^ONEC_SOURCE_(INTEGRITY_FAILED|VALIDATOR_MISSING)'
        if ($sourceValidationFailure -and $script:RunSourceIntegrityPaths.Count -gt 0) {
            $conflictPaths = @($script:RunSourceIntegrityPaths)
        }
        Set-PendingDevBranchMergeTransaction `
            -State $stateAfterConflict `
            -Operation $Operation `
            -Branch $branch `
            -BranchCommit $branchCommit `
            -TargetCommit $TargetCommit `
            -Stage "conflicts" `
            -AllowedPaths $allowedPaths `
            -ConflictPaths $conflictPaths
        if ($sourceValidationFailure) {
            throw $mergeFailure
        }
        Stop-DevBranchLifecycleMergeForConflicts `
            -Operation $Operation `
            -Stage $ConflictStage `
            -ConflictPaths $conflictPaths
    }

    $stateAfterMerge = Read-DevBranchState -Name $DevBranchName
    $transaction = Get-PendingDevBranchMergeTransaction -State $stateAfterMerge
    Complete-DevBranchLifecycleMergeTransaction -State $stateAfterMerge -Transaction $transaction
    Restart-Agent1cAfterDevBranchMerge -Operation $Operation
}

function Convert-LegacyPendingRefreshMergeTransaction {
    param(
        [object]$State,
        [object]$Transaction
    )

    $currentBranch = Get-CurrentBranch
    $expectedBranch = [string](Get-StateValue -State $State -Name "devBranch" -Default "")
    if ($currentBranch -cne $expectedBranch) {
        throw "LIFECYCLE_MERGE_BRANCH_MISMATCH pending='$expectedBranch' expected='$expectedBranch' current='$currentBranch'."
    }
    if ($Transaction.targetCommit -notmatch '^[a-f0-9]{40}$' -or -not (Test-GitCommitExists -Commit $Transaction.targetCommit)) {
        throw "LIFECYCLE_MERGE_COMMIT_INVALID operation='$($Transaction.operation)' commit='$($Transaction.targetCommit)'."
    }
    $head = Get-CurrentCommit
    $branchCommit = ""
    $stage = ""
    $mergeCommit = ""
    $result = ""
    $allowedPaths = @()
    $conflictPaths = @()

    if (Test-GitMergeInProgress) {
        $mergeHead = Get-GitMergeHeadCommit
        if ($mergeHead -cne $Transaction.targetCommit) {
            throw "LIFECYCLE_MERGE_HEAD_MISMATCH operation='$($Transaction.operation)' expected='$($Transaction.targetCommit)' actual='$mergeHead'."
        }
        $branchCommit = $head
        $stage = "conflicts"
        $allowedPaths = @(Get-DevBranchMergeIndexPaths)
        $conflictPaths = @(Get-DevBranchMergeUnmergedPaths)
    } else {
        $parents = @(Get-GitCommitParents -Commit $head)
        if ($parents.Count -eq 2 -and $parents[1] -ceq $Transaction.targetCommit) {
            $branchCommit = $parents[0]
            $stage = "merged"
            $mergeCommit = $head
            $result = "merge-commit"
        } else {
            throw "LIFECYCLE_LEGACY_MERGE_STATE_UNPROVEN operation='$($Transaction.operation)' targetCommit='$($Transaction.targetCommit)' head='$head'."
        }
    }

    Set-PendingDevBranchMergeTransaction `
        -State $State `
        -Operation $Transaction.operation `
        -Branch $currentBranch `
        -BranchCommit $branchCommit `
        -TargetCommit $Transaction.targetCommit `
        -Stage $stage `
        -AllowedPaths $allowedPaths `
        -ConflictPaths $conflictPaths `
        -MergeCommit $mergeCommit `
        -Result $result
    return (Get-PendingDevBranchMergeTransaction -State (Read-DevBranchState -Name $DevBranchName))
}

function Assert-DevBranchLifecycleMergeIdentity {
    param(
        [object]$State,
        [object]$Transaction,
        [string]$Operation
    )

    $expectedBranch = [string](Get-StateValue -State $State -Name "devBranch" -Default "")
    $currentBranch = Get-CurrentBranch
    if ($Transaction.operation -cne $Operation) {
        throw "LIFECYCLE_MERGE_OPERATION_MISMATCH pending='$($Transaction.operation)' requested='$Operation'. Repeat the same ITL command that started the merge."
    }
    if ($Transaction.branch -cne $expectedBranch -or $currentBranch -cne $expectedBranch) {
        throw "LIFECYCLE_MERGE_BRANCH_MISMATCH pending='$($Transaction.branch)' expected='$expectedBranch' current='$currentBranch'."
    }
    foreach ($entry in @($Transaction.branchCommit, $Transaction.targetCommit)) {
        if ($entry -notmatch '^[a-f0-9]{40}$' -or -not (Test-GitCommitExists -Commit $entry)) {
            throw "LIFECYCLE_MERGE_COMMIT_INVALID operation='$Operation' commit='$entry'."
        }
    }
}

function Resume-DevBranchLifecycleMergeIfPresent {
    param(
        [object]$State,
        [string]$Operation,
        [string]$ConflictStage
    )

    $transaction = Get-PendingDevBranchMergeTransaction -State $State
    if ($null -eq $transaction) {
        return $false
    }
    if ($transaction.operation -cne $Operation) {
        throw "LIFECYCLE_MERGE_OPERATION_MISMATCH pending='$($transaction.operation)' requested='$Operation'. Repeat the same ITL command that started the merge."
    }
    if ($transaction.legacy) {
        $transaction = Convert-LegacyPendingRefreshMergeTransaction -State $State -Transaction $transaction
        $State = Read-DevBranchState -Name $DevBranchName
    }
    Assert-DevBranchLifecycleMergeIdentity -State $State -Transaction $transaction -Operation $Operation

    $head = Get-CurrentCommit
    if (Test-GitMergeInProgress) {
        $mergeHead = Get-GitMergeHeadCommit
        if ($mergeHead -cne $transaction.targetCommit) {
            throw "LIFECYCLE_MERGE_HEAD_MISMATCH operation='$Operation' expected='$($transaction.targetCommit)' actual='$mergeHead'."
        }
        if ($head -cne $transaction.branchCommit) {
            throw "LIFECYCLE_MERGE_BRANCH_HEAD_MISMATCH operation='$Operation' expected='$($transaction.branchCommit)' actual='$head'."
        }

        $cursorPaths = @(
            @(Get-ConfigDumpInfoRepoPathsAtCommit -Commit $transaction.branchCommit) +
            @(Get-ConfigDumpInfoRepoPathsAtCommit -Commit $transaction.targetCommit) |
                Sort-Object -Unique
        )
        Restore-BranchConfigDumpInfoFromCommit -Commit $transaction.branchCommit -RepoPaths $cursorPaths

        $unmergedPaths = @(Get-DevBranchMergeUnmergedPaths)
        if ($unmergedPaths.Count -gt 0) {
            $allowedPaths = @($transaction.allowedPaths)
            if ($allowedPaths.Count -eq 0) {
                $allowedPaths = @(Get-DevBranchMergeIndexPaths)
            }
            Set-PendingDevBranchMergeTransaction `
                -State $State `
                -Operation $Operation `
                -Branch $transaction.branch `
                -BranchCommit $transaction.branchCommit `
                -TargetCommit $transaction.targetCommit `
                -Stage "conflicts" `
                -AllowedPaths $allowedPaths `
                -ConflictPaths $unmergedPaths
            Stop-DevBranchLifecycleMergeForConflicts `
                -Operation $Operation `
                -Stage $ConflictStage `
                -ConflictPaths $unmergedPaths
        }

        $sourceByteContractTransition = Test-OneCSourceByteContractTransition `
            -BranchCommit $transaction.branchCommit `
            -TargetCommit $transaction.targetCommit
        $unstagedPaths = @(Get-DevBranchMergeUnstagedPaths)
        $conflictPathsStillUnstaged = @($unstagedPaths | Where-Object { @($transaction.conflictPaths) -ccontains $_ })
        $unexpectedUnstagedPaths = @(if ($sourceByteContractTransition) {
            @($unstagedPaths | Where-Object {
                $conflictPathsStillUnstaged -ccontains $_ -or
                -not (Test-OneCSourceRepoPath -RepoPath $_) -or
                -not (Test-GitWorktreePathDiffersOnlyByCarriageReturnsAtEol -RepoPath $_)
            })
        } else {
            $unstagedPaths
        })
        if ($unexpectedUnstagedPaths.Count -gt 0) {
            Stop-DevBranchLifecycleMergeForConflicts `
                -Operation $Operation `
                -Stage $ConflictStage `
                -ConflictPaths $unexpectedUnstagedPaths `
                -Reason "resolved files still have unstaged changes"
        }
        $untrackedPaths = @(Get-DevBranchMergeUntrackedPaths)
        if ($untrackedPaths.Count -gt 0) {
            Set-RunFailureContext -Category "runner" -RequiredAction "remove-or-commit-unrelated-untracked-files-then-repeat-same-itl-command"
            throw "LIFECYCLE_MERGE_UNTRACKED_FILES operation='$Operation' files='$($untrackedPaths -join ', ')'. Remove or commit unrelated untracked files outside this merge, then repeat the same ITL command."
        }

        $stagedPaths = @(Get-DevBranchMergeIndexPaths)
        $unexpectedStagedPaths = @($stagedPaths | Where-Object { @($transaction.allowedPaths) -cnotcontains $_ })
        if ($unexpectedStagedPaths.Count -gt 0) {
            Set-RunFailureContext -Category "runner" -RequiredAction "remove-unrelated-staged-changes-then-repeat-same-itl-command"
            throw "LIFECYCLE_MERGE_UNEXPECTED_STAGED_FILES operation='$Operation' files='$($unexpectedStagedPaths -join ', ')'. The workflow will not include unrelated staged changes in its merge commit."
        }

        Repair-OneCSourceLineEndings `
            -ReferenceCommit $transaction.targetCommit `
            -CandidatePaths $stagedPaths `
            -StageChanges | Out-Null
        $stagedPaths = @(Get-DevBranchMergeIndexPaths)

        if ($sourceByteContractTransition) {
            Complete-OneCSourceByteContractMergeTransition `
                -BranchCommit $transaction.branchCommit `
                -TargetCommit $transaction.targetCommit `
                -CursorPaths $cursorPaths
            $stagedPaths = @(Get-DevBranchMergeIndexPaths)
            Set-PendingDevBranchMergeTransaction `
                -State $State `
                -Operation $Operation `
                -Branch $transaction.branch `
                -BranchCommit $transaction.branchCommit `
                -TargetCommit $transaction.targetCommit `
                -Stage "conflicts" `
                -AllowedPaths $stagedPaths `
                -ConflictPaths @()
            $transaction = Get-PendingDevBranchMergeTransaction -State (Read-DevBranchState -Name $DevBranchName)
        }

        Assert-OneCConfigurationSourceIntegrity -ExportPath (Get-ExportPath)
        Invoke-Git @("commit", "--no-edit")
        $State = Read-DevBranchState -Name $DevBranchName
        Complete-DevBranchLifecycleMergeTransaction -State $State -Transaction $transaction
        Restart-Agent1cAfterDevBranchMerge -Operation $Operation
    }

    if ($transaction.stage -ceq "merged") {
        Resolve-DevBranchLifecyclePostMergeHead `
            -State $State `
            -Transaction $transaction `
            -Operation $Operation `
            -AllowLegacyCursorMigration | Out-Null
        Assert-CleanGit
        Restart-Agent1cAfterDevBranchMerge -Operation $Operation
    }

    if (Test-GitCommitHasExactMergeParents -Commit $head -FirstParent $transaction.branchCommit -SecondParent $transaction.targetCommit) {
        Complete-DevBranchLifecycleMergeTransaction -State $State -Transaction $transaction
        Restart-Agent1cAfterDevBranchMerge -Operation $Operation
    }
    if ($head -ceq $transaction.branchCommit -and $transaction.stage -ceq "prepared") {
        if (Test-GitCommitIsAncestor -Ancestor $transaction.targetCommit -Descendant $head) {
            Complete-DevBranchLifecycleMergeTransaction -State $State -Transaction $transaction
            Restart-Agent1cAfterDevBranchMerge -Operation $Operation
        }
        Invoke-NewDevBranchLifecycleMerge `
            -State $State `
            -Operation $Operation `
            -TargetCommit $transaction.targetCommit `
            -ConflictStage $ConflictStage
    }

    throw "LIFECYCLE_MERGE_STATE_MISMATCH operation='$Operation' stage='$($transaction.stage)' branchCommit='$($transaction.branchCommit)' targetCommit='$($transaction.targetCommit)' head='$head'."
}

function Assert-DevBranchLifecycleMergePostMerge {
    param(
        [object]$State,
        [string]$Operation
    )

    $transaction = Get-PendingDevBranchMergeTransaction -State $State
    if ($null -eq $transaction) {
        throw "LIFECYCLE_MERGE_TRANSACTION_MISSING operation='$Operation' phase='post-merge'."
    }
    Assert-DevBranchLifecycleMergeIdentity -State $State -Transaction $transaction -Operation $Operation
    if ($transaction.stage -cne "merged" -or -not $transaction.mergeCommit) {
        throw "LIFECYCLE_MERGE_TRANSACTION_NOT_COMMITTED operation='$Operation' stage='$($transaction.stage)'."
    }
    if (Test-GitMergeInProgress) {
        throw "LIFECYCLE_MERGE_STILL_IN_PROGRESS operation='$Operation' phase='post-merge'."
    }
    Resolve-DevBranchLifecyclePostMergeHead `
        -State $State `
        -Transaction $transaction `
        -Operation $Operation `
        -AllowLegacyCursorMigration | Out-Null
    Assert-CleanGit
    return (Get-PendingDevBranchMergeTransaction -State (Read-DevBranchState -Name $DevBranchName))
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
        [bool]$WorktreeLocked = $false,
        [object]$BranchSeedLease = $null
    )

    $kind = Get-InfoBaseKind
    $sourceUsesRepository = Get-SourceUsesRepository
    $configuredSourceUsesRepository = ConvertTo-BoolSetting `
        -Value (Get-ConfigValue -Path "sourceUsesRepository" -Default $sourceUsesRepository) `
        -Default $sourceUsesRepository
    $branchCopyMayUseRepository = $sourceUsesRepository -or $configuredSourceUsesRepository
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
        @{ name = "lastConfigDesignerTreeObjectId"; value = "" },
        @{ name = "lastConfigDesignerLoadedAt"; value = "" },
        @{ name = "lastExtensionDesignerFingerprint"; value = "" },
        @{ name = "lastExtensionDesignerTreeObjectId"; value = "" },
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
    $seedManifest = $null
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
                $seedManifest = Restore-DevBranchFromSeed `
                    -DevBranchName $DevBranchName `
                    -DevBranchInfoBasePath $DevBranchInfoBasePath `
                    -ExistingLease $BranchSeedLease
                $copyPerformed = $true
            }
        } else {
            if (@("infobase-copied", "repository-unbound", "launcher-registered") -contains $currentStatus) {
                Write-Host "Using existing development branch infobase copy: $DevBranchInfoBasePath"
            } else {
                $seedManifest = Restore-DevBranchFromSeed `
                    -DevBranchName $DevBranchName `
                    -DevBranchInfoBasePath $DevBranchInfoBasePath `
                    -ExistingLease $BranchSeedLease
                $copyPerformed = $true
            }
        }
        if ($copyPerformed) {
            $configExportPath = Get-ExportPath
            $absoluteConfigExportPath = Resolve-ProjectPath $configExportPath
            if (Test-Path -LiteralPath $absoluteConfigExportPath -PathType Container) {
                $configSource = Get-ConfigSourceFingerprint -ExportPath $configExportPath
                $stateHash["lastConfigDesignerFingerprint"] = $configSource.fingerprint
                $stateHash["lastConfigDesignerTreeObjectId"] = $configSource.treeObjectId
                $stateHash["lastConfigDesignerLoadedAt"] = $now
                $stateHash["configLoadStatus"] = "passed"
                $stateHash["sourceFingerprint"] = $configSource.fingerprint
                $stateHash["loadReason"] = "branch-copy-seed"
            } else {
                $stateHash["loadReason"] = "branch-copy-seed-deferred"
            }
            $stateHash["designerInvoked"] = $false
            $stateHash["enterpriseInvoked"] = $false
            $stateHash["branchSeedSourceKey"] = [string]$seedManifest.sourceKey
            $stateHash["branchSeedSyncId"] = [string]$seedManifest.syncId
            $stateHash["branchSeedArtifactKind"] = [string]$seedManifest.artifactKind
            $stateHash["branchSeedConfigurationFingerprint"] = [string]$seedManifest.configurationFingerprint
            $stateHash["branchSeedBaselinePath"] = [string]$seedManifest.baselinePath
            $stateHash["branchSeedBaselineHash"] = [string]$seedManifest.baselineHash
            $stateHash["branchSeedBaselineCount"] = [int]$seedManifest.baselineCount
        }
        $statePath = Save-DevBranchInitializationState -SafeDevBranchName $SafeDevBranchName -State $stateHash -Status "infobase-copied" -ProjectRootOverride $stateProjectRoot
        $currentStatus = "infobase-copied"

        $repositoryUnbound = ConvertTo-BoolSetting -Value $stateHash["repositoryUnbound"] -Default $false
        if ($branchCopyMayUseRepository -and -not $repositoryUnbound) {
            Invoke-Designer `
                -InfoBasePath $DevBranchInfoBasePath `
                -InfoBaseKind $kind `
                -DesignerArgs @("/ConfigurationRepositoryUnbindCfg", "-force") | Out-Null
            $repositoryUnbound = $true
        } elseif (-not $branchCopyMayUseRepository) {
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
        $seedBaselinePath = if ($seedManifest) {
            [string]$seedManifest.baselinePath
        } else {
            [string](Get-StateValue -State $state -Name "branchSeedBaselinePath" -Default "")
        }
        $state = Initialize-DevBranchEventLogBaseline -State $state -SeedBaselinePath $seedBaselinePath
        Ensure-DevBranchEventLogPendingCursor -State $state -Reason "branch-copy" | Out-Null
        $state = Read-DevBranchStateFile -Path $statePath
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

function Initialize-DevBranchRuntimeAction {
    Require-Value "DevBranchName" $DevBranchName | Out-Null
    Require-Value "DevBranch" $DevBranch | Out-Null
    Require-Value "MainWorktreePath" $MainWorktreePath | Out-Null
    $worktreePath = if ($DevBranchWorktreePath) {
        Resolve-Agent1cFullPath -Path $DevBranchWorktreePath
    } else {
        $script:ProjectRoot
    }
    if ((Resolve-Agent1cFullPath -Path $script:ProjectRoot) -ne $worktreePath) {
        throw "BRANCH_RUNTIME_WORKTREE_MISMATCH: projectRoot=$($script:ProjectRoot); worktree=$worktreePath"
    }
    Initialize-DevBranchRuntime `
        -DevBranchKind $DevBranchKind `
        -SafeDevBranchName (ConvertTo-SafeName $DevBranchName) `
        -GitBranch $DevBranch `
        -MainProjectRoot (Resolve-Agent1cFullPath -Path $MainWorktreePath) `
        -WorktreePath $worktreePath `
        -CreatedWithWorktree $true
}

function Get-DevBranchForkStagingRoot {
    return (Resolve-Agent1cFullPath -Path (Join-Path (Get-MainWorktreePath) ".agent-1c\fork-staging"))
}

function Get-DevBranchForkStagingPath {
    param([Parameter(Mandatory = $true)][string]$SafeDevBranchName)

    return (Resolve-Agent1cFullPath -Path (Join-Path (Get-DevBranchForkStagingRoot) $SafeDevBranchName))
}

function Assert-DevBranchForkStagingPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $root = (Get-DevBranchForkStagingRoot).TrimEnd("\", "/")
    $resolved = (Resolve-Agent1cFullPath -Path $Path).TrimEnd("\", "/")
    if (-not $resolved.StartsWith(($root + [IO.Path]::DirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase)) {
        throw "DEV_BRANCH_FORK_STAGING_PATH_OUTSIDE_ROOT: $resolved"
    }
    return $resolved
}

function Get-DevBranchForkEnvironmentFingerprint {
    $platformPath = [string](Get-PlatformPath)
    $platformVersion = ""
    if ($platformPath -and (Test-Path -LiteralPath $platformPath -PathType Leaf -ErrorAction SilentlyContinue)) {
        try { $platformVersion = [string](Get-Item -LiteralPath $platformPath).VersionInfo.FileVersion } catch { $platformVersion = "" }
    }
    $dependencyLockSha256 = ""
    if ($script:DependencyLockPath -and (Test-Path -LiteralPath $script:DependencyLockPath -PathType Leaf -ErrorAction SilentlyContinue)) {
        $dependencyLockSha256 = (Get-FileHash -LiteralPath $script:DependencyLockPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    return (Get-StringSha256 -Value ("platform={0}|version={1}|dependencyLock={2}" -f $platformPath, $platformVersion, $dependencyLockSha256))
}

function Copy-DevBranchForkEvidenceReference {
    param(
        [Parameter(Mandatory = $true)][string]$FieldName,
        [string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$HistoryRoot,
        [Parameter(Mandatory = $true)][hashtable]$EvidencePaths
    )

    if ([string]::IsNullOrWhiteSpace($SourcePath) -or -not (Test-Path -LiteralPath $SourcePath -ErrorAction SilentlyContinue)) {
        return
    }
    $relativePath = "evidence/$FieldName"
    $destination = Join-Path $HistoryRoot ($relativePath.Replace("/", [IO.Path]::DirectorySeparatorChar))
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
    Copy-Item -LiteralPath $SourcePath -Destination $destination -Recurse -Force
    $EvidencePaths[$FieldName] = $relativePath
}

function Remove-DevBranchForkTransientState {
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$State)

    foreach ($key in @($State.Keys)) {
        $name = [string]$key
        if ($name -in @("statePath", "stateProjectRoot", "closedAt", "pendingDeregistration", "pendingDeregistrationAt", "pendingDeregistrationError", "workspaceProvider", "clientWorkspaceId", "runtimeRoot", "lastVanessaStatusPath") -or
            $name -match '^(?:launcher|publication|roctupMcp|vanessaMcp|dataMcp|vibecoding1c)' -or
            $name -match '^(?:reset|pendingMerge|pendingRefresh|lifecycleMerge|lastResult|finalResult|close|eventLogPendingCursor)' -or
            $name -match '(?i)(?:pid|pids|port|ports|leasetoken|lockpath|locked)$') {
            [void]$State.Remove($key)
        }
    }
    return $State
}

function New-DevBranchForkHistorySnapshot {
    param(
        [Parameter(Mandatory = $true)][object]$SourceState,
        [Parameter(Mandatory = $true)][string]$HistoryRoot,
        [Parameter(Mandatory = $true)][object]$EventLogBaseline,
        [Parameter(Mandatory = $true)][string]$SourceCommit
    )

    New-Item -ItemType Directory -Force -Path $HistoryRoot | Out-Null
    $sourceStateHash = ConvertTo-Agent1cHashtable -Object $SourceState
    Remove-DevBranchForkTransientState -State $sourceStateHash | Out-Null

    $baseline = [ordered]@{
        schemaVersion = 2
        createdAt = (Get-Date).ToString("o")
        reason = "fork-boundary"
        reader = [string]$EventLogBaseline.reader
        logDirectory = [string]$EventLogBaseline.logDirectory
        errorCount = [int]$EventLogBaseline.errorCount
        signatureCount = @($EventLogBaseline.signatures).Count
        signatures = @($EventLogBaseline.signatures)
        durationMs = [int64]$EventLogBaseline.durationMs
        cache = [ordered]@{
            status = [string]$EventLogBaseline.cacheStatus
            path = [string]$EventLogBaseline.cachePath
            sourceKey = [string]$EventLogBaseline.sourceKey
            segmentCount = [int]$EventLogBaseline.segmentCount
        }
    }
    Write-Utf8Text -Path (Join-Path $HistoryRoot "event-log-baseline.json") -Value (($baseline | ConvertTo-Json -Depth 8) + [Environment]::NewLine)

    $sourceEventLog = [string](Get-StateValue -State $EventLogBaseline -Name "logDirectory" -Default "")
    if ($sourceEventLog -and (Test-Path -LiteralPath $sourceEventLog -PathType Container -ErrorAction SilentlyContinue)) {
        Copy-Item -LiteralPath $sourceEventLog -Destination (Join-Path $HistoryRoot "event-log") -Recurse -Force
    }

    $evidencePaths = @{}
    $evidenceFieldNames = @(
        "lastVerifiedReportPath", "lastVerificationLogPath",
        "lastDiagnosticVerificationReportPath", "lastDiagnosticVerificationLogPath",
        "lastVanessaReportPath", "lastVanessaLogPath",
        "lastVanessaEventLogNewErrorsPath", "eventLogDebtReportPath"
    )
    foreach ($fieldName in $evidenceFieldNames) {
        Copy-DevBranchForkEvidenceReference `
            -FieldName $fieldName `
            -SourcePath ([string](Get-StateValue -State $SourceState -Name $fieldName -Default "")) `
            -HistoryRoot $HistoryRoot `
            -EvidencePaths $evidencePaths
    }
    foreach ($fieldName in $evidenceFieldNames) {
        $sourceStateHash[$fieldName] = if ($evidencePaths.ContainsKey($fieldName)) { [string]$evidencePaths[$fieldName] } else { "" }
    }
    Write-Utf8Text -Path (Join-Path $HistoryRoot "source-state.json") -Value (($sourceStateHash | ConvertTo-Json -Depth 16) + [Environment]::NewLine)
    $historyManifest = [ordered]@{
        schemaVersion = 1
        createdAt = (Get-Date).ToString("o")
        sourceBranch = [string]$SourceState.devBranch
        sourceBranchName = [string]$SourceState.devBranchName
        sourceCommit = $SourceCommit
        eventLogBaselinePath = "event-log-baseline.json"
        rawEventLogCopied = (Test-Path -LiteralPath (Join-Path $HistoryRoot "event-log") -PathType Container -ErrorAction SilentlyContinue)
        evidencePaths = $evidencePaths
    }
    Write-Utf8Text -Path (Join-Path $HistoryRoot "history-manifest.json") -Value (($historyManifest | ConvertTo-Json -Depth 8) + [Environment]::NewLine)

    $hashes = @()
    $prefix = $HistoryRoot.TrimEnd("\", "/") + [IO.Path]::DirectorySeparatorChar
    foreach ($file in @(Get-ChildItem -LiteralPath $HistoryRoot -Recurse -File -Force -ErrorAction Stop | Sort-Object FullName)) {
        $relative = $file.FullName.Substring($prefix.Length).Replace("\", "/")
        $hashes += [ordered]@{
            path = $relative
            length = [int64]$file.Length
            sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    return [pscustomobject]@{
        evidencePaths = $evidencePaths
        files = @($hashes)
        baselinePath = "event-log-baseline.json"
    }
}

function Read-DevBranchForkSnapshot {
    param([Parameter(Mandatory = $true)][string]$StagingPath)

    $resolved = Assert-DevBranchForkStagingPath -Path $StagingPath
    $manifestPath = Join-Path $resolved "manifest.json"
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf -ErrorAction SilentlyContinue)) {
        throw "DEV_BRANCH_FORK_SNAPSHOT_MISSING: $manifestPath"
    }
    $manifest = Read-Utf8Text -Path $manifestPath | ConvertFrom-Json
    if ([int](Get-StateValue -State $manifest -Name "schemaVersion" -Default 0) -ne 1 -or [string]$manifest.status -ne "ready") {
        throw "DEV_BRANCH_FORK_SNAPSHOT_INVALID: $manifestPath"
    }
    $artifactPath = Resolve-Agent1cFullPath -Path ([string]$manifest.artifactPath)
    if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf -ErrorAction SilentlyContinue)) {
        throw "DEV_BRANCH_FORK_ARTIFACT_MISSING: $artifactPath"
    }
    $actualSha256 = (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualSha256 -cne [string]$manifest.artifactSha256) {
        throw "DEV_BRANCH_FORK_ARTIFACT_SHA_MISMATCH expected='$($manifest.artifactSha256)' actual='$actualSha256' path='$artifactPath'"
    }
    $dependencyLockPath = [string](Get-StateValue -State $manifest -Name "dependencyLockPath" -Default "")
    if ($dependencyLockPath) {
        $dependencyLockPath = Resolve-Agent1cFullPath -Path $dependencyLockPath
        if (-not (Test-Path -LiteralPath $dependencyLockPath -PathType Leaf -ErrorAction SilentlyContinue)) {
            throw "DEV_BRANCH_FORK_DEPENDENCY_LOCK_MISSING: $dependencyLockPath"
        }
        $dependencyLockSha256 = (Get-FileHash -LiteralPath $dependencyLockPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($dependencyLockSha256 -cne [string]$manifest.dependencyLockSha256) {
            throw "DEV_BRANCH_FORK_DEPENDENCY_LOCK_SHA_MISMATCH expected='$($manifest.dependencyLockSha256)' actual='$dependencyLockSha256' path='$dependencyLockPath'"
        }
    }
    $dotEnvPath = [string](Get-StateValue -State $manifest -Name "dotEnvPath" -Default "")
    if ($dotEnvPath) {
        $dotEnvPath = Resolve-Agent1cFullPath -Path $dotEnvPath
        if (-not (Test-Path -LiteralPath $dotEnvPath -PathType Leaf -ErrorAction SilentlyContinue)) {
            throw "DEV_BRANCH_FORK_DOT_ENV_MISSING: $dotEnvPath"
        }
        $dotEnvSha256 = (Get-FileHash -LiteralPath $dotEnvPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($dotEnvSha256 -cne [string]$manifest.dotEnvSha256) {
            throw "DEV_BRANCH_FORK_DOT_ENV_SHA_MISMATCH expected='$($manifest.dotEnvSha256)' actual='$dotEnvSha256' path='$dotEnvPath'"
        }
    }
    $manifest | Add-Member -NotePropertyName manifestPath -NotePropertyValue $manifestPath -Force
    $manifest | Add-Member -NotePropertyName stagingPath -NotePropertyValue $resolved -Force
    return $manifest
}

function New-DevBranchForkSnapshot {
    param(
        [Parameter(Mandatory = $true)][object]$SourceState,
        [Parameter(Mandatory = $true)][string]$TargetBranchName,
        [Parameter(Mandatory = $true)][string]$TargetSafeName,
        [Parameter(Mandatory = $true)][string]$TargetGitBranch,
        [Parameter(Mandatory = $true)][string]$TargetWorktreePath,
        [Parameter(Mandatory = $true)][string]$SourceCommit,
        [Parameter(Mandatory = $true)][object]$SourceVerification,
        [Parameter(Mandatory = $true)][string]$SourceEnvironmentFingerprint
    )

    $stagingPath = Get-DevBranchForkStagingPath -SafeDevBranchName $TargetSafeName
    $manifestPath = Join-Path $stagingPath "manifest.json"
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf -ErrorAction SilentlyContinue) {
        $existing = Read-DevBranchForkSnapshot -StagingPath $stagingPath
        if ([string]$existing.sourceCommit -cne $SourceCommit -or
            [string]$existing.sourceGitBranch -cne [string]$SourceState.devBranch -or
            [string]$existing.targetGitBranch -cne $TargetGitBranch) {
            throw "DEV_BRANCH_FORK_SNAPSHOT_IDENTITY_MISMATCH: $manifestPath"
        }
        return $existing
    }
    if (Test-Path -LiteralPath $stagingPath -ErrorAction SilentlyContinue) {
        throw "DEV_BRANCH_FORK_STAGING_INCOMPLETE: $stagingPath. Repeat after the previous failed operation has been diagnosed."
    }

    New-Item -ItemType Directory -Force -Path $stagingPath | Out-Null
    try {
        Stop-DevBranchRuntimeBeforeInfobaseMutation -State $SourceState -Reason "development branch fork snapshot"
        Set-RunStage -Stage "fork.snapshot.infobase" -Detail "Creating an immutable snapshot of the exact source branch infobase."
        $kind = [string](Get-StateValue -State $SourceState -Name "infoBaseKind" -Default "file")
        if ($kind -eq "file") {
            $artifactDirectory = Join-Path $stagingPath "infobase"
            New-Item -ItemType Directory -Force -Path $artifactDirectory | Out-Null
            $sourceBasePath = Resolve-InfoBasePath ([string]$SourceState.devBranchInfoBasePath)
            $sourceArtifact = Join-Path $sourceBasePath "1Cv8.1CD"
            if (-not (Test-Path -LiteralPath $sourceArtifact -PathType Leaf -ErrorAction SilentlyContinue)) {
                throw "DEV_BRANCH_FORK_SOURCE_ARTIFACT_MISSING: $sourceArtifact"
            }
            $artifactPath = Join-Path $artifactDirectory "1Cv8.1CD"
            Copy-Item -LiteralPath $sourceArtifact -Destination $artifactPath
            Copy-BranchSeedFileDoNotCopyMarker -SourceInfoBasePath $sourceBasePath -DestinationInfoBasePath $artifactDirectory
            $artifactKind = "file-1cd"
        } else {
            $artifactPath = Join-Path $stagingPath "infobase.dt"
            Invoke-Designer `
                -InfoBasePath ([string]$SourceState.devBranchInfoBasePath) `
                -InfoBaseKind "server" `
                -DesignerArgs @("/DumpIB", $artifactPath) | Out-Null
            $artifactKind = "server-dt"
        }
        if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf -ErrorAction SilentlyContinue) -or (Get-Item -LiteralPath $artifactPath).Length -le 0) {
            throw "DEV_BRANCH_FORK_ARTIFACT_EMPTY: $artifactPath"
        }
        $artifactSha256 = (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash.ToLowerInvariant()

        Set-RunStage -Stage "fork.snapshot.event-log" -Detail "Capturing the source event-log boundary after the base snapshot."
        $eventLogBaseline = Read-DevBranchEventLogBaselineData -State $SourceState
        Set-RunStage -Stage "fork.snapshot.history" -Detail "Copying branch-local logs and verification evidence into the fork history bundle."
        $historyRoot = Join-Path $stagingPath "history"
        $history = New-DevBranchForkHistorySnapshot -SourceState $SourceState -HistoryRoot $historyRoot -EventLogBaseline $eventLogBaseline -SourceCommit $SourceCommit
        $dependencyLockPath = ""
        $dependencyLockSha256 = ""
        if ($script:DependencyLockPath -and (Test-Path -LiteralPath $script:DependencyLockPath -PathType Leaf -ErrorAction SilentlyContinue)) {
            $dependencyLockPath = Join-Path $stagingPath "dependency-lock.json"
            Copy-Item -LiteralPath $script:DependencyLockPath -Destination $dependencyLockPath
            $dependencyLockSha256 = (Get-FileHash -LiteralPath $dependencyLockPath -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        $dotEnvPath = ""
        $dotEnvSha256 = ""
        $sourceDotEnvPath = Join-Path $script:ProjectRoot ".dev.env"
        if (Test-Path -LiteralPath $sourceDotEnvPath -PathType Leaf -ErrorAction SilentlyContinue) {
            $dotEnvPath = Join-Path $stagingPath ".dev.env"
            Copy-Item -LiteralPath $sourceDotEnvPath -Destination $dotEnvPath
            $dotEnvSha256 = (Get-FileHash -LiteralPath $dotEnvPath -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        $manifest = [ordered]@{
            schemaVersion = 1
            status = "ready"
            forkId = [guid]::NewGuid().ToString("N")
            createdAt = (Get-Date).ToString("o")
            sourceBranchName = [string]$SourceState.devBranchName
            sourceSafeName = [string]$SourceState.safeDevBranchName
            sourceGitBranch = [string]$SourceState.devBranch
            sourceWorktreePath = [string]$SourceState.worktreePath
            sourceCommit = $SourceCommit
            sourceVerification = [ordered]@{
                status = [string]$SourceVerification.status
                effectiveStatus = [string]$SourceVerification.effectiveStatus
                isFreshPassed = [bool]$SourceVerification.isFreshPassed
                fingerprint = [string]$SourceVerification.currentFingerprint
                verifiedFingerprint = [string]$SourceVerification.verifiedFingerprint
                verifiedCommit = [string]$SourceVerification.verifiedCommit
                verifiedAt = [string]$SourceVerification.verifiedAt
            }
            sourceEnvironmentFingerprint = $SourceEnvironmentFingerprint
            targetBranchName = $TargetBranchName
            targetSafeName = $TargetSafeName
            targetGitBranch = $TargetGitBranch
            targetWorktreePath = $TargetWorktreePath
            infoBaseKind = $kind
            artifactKind = $artifactKind
            artifactPath = $artifactPath
            artifactSha256 = $artifactSha256
            artifactLength = [int64](Get-Item -LiteralPath $artifactPath).Length
            historyPath = $historyRoot
            historyFiles = @($history.files)
            evidencePaths = $history.evidencePaths
            baselinePath = Join-Path $historyRoot ([string]$history.baselinePath)
            dependencyLockPath = $dependencyLockPath
            dependencyLockSha256 = $dependencyLockSha256
            dotEnvPath = $dotEnvPath
            dotEnvSha256 = $dotEnvSha256
        }
        Write-Utf8TextAtomic -Path $manifestPath -Value (($manifest | ConvertTo-Json -Depth 16) + [Environment]::NewLine)
        return (Read-DevBranchForkSnapshot -StagingPath $stagingPath)
    } catch {
        $resolved = Assert-DevBranchForkStagingPath -Path $stagingPath
        if (Test-Path -LiteralPath $resolved -ErrorAction SilentlyContinue) {
            Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
        }
        throw
    }
}

function New-ForkedDevBranchState {
    param(
        [Parameter(Mandatory = $true)][object]$SourceState,
        [Parameter(Mandatory = $true)][object]$Snapshot,
        [Parameter(Mandatory = $true)][string]$TargetInfoBasePath,
        [Parameter(Mandatory = $true)][string]$TargetHistoryRoot,
        [Parameter(Mandatory = $true)][string]$MainProjectRoot
    )

    $state = ConvertTo-Agent1cHashtable -Object $SourceState
    Remove-DevBranchForkTransientState -State $state | Out-Null

    $now = (Get-Date).ToString("o")
    $state["devBranchName"] = [string]$Snapshot.targetBranchName
    $state["safeDevBranchName"] = [string]$Snapshot.targetSafeName
    $state["devBranch"] = [string]$Snapshot.targetGitBranch
    $state["createdWithWorktree"] = $true
    $state["worktreePath"] = [string]$Snapshot.targetWorktreePath
    $state["mainWorktreePath"] = $MainProjectRoot
    $state["createdFromCommit"] = [string]$Snapshot.sourceCommit
    $state["lastConfigBaseUpdatedCommit"] = [string]$Snapshot.sourceCommit
    $state["devBranchInfoBasePath"] = $TargetInfoBasePath
    $state["createdAt"] = $now
    $state["forkedAt"] = $now
    $state["forkId"] = [string]$Snapshot.forkId
    $state["forkedFromBranch"] = [string]$Snapshot.sourceGitBranch
    $state["forkedFromBranchName"] = [string]$Snapshot.sourceBranchName
    $state["forkedFromCommit"] = [string]$Snapshot.sourceCommit
    $state["forkHistoryPath"] = $TargetHistoryRoot
    $state["forkSnapshotArtifactSha256"] = [string]$Snapshot.artifactSha256
    $state["forkSnapshotArtifactKind"] = [string]$Snapshot.artifactKind
    $state["publicationStatus"] = "disabled"
    $state["publicationMode"] = "none"
    $state["publicationUrl"] = ""
    $state["publicationError"] = ""
    $state["launcherRegistered"] = $false
    $state["launcherInfoBaseName"] = ""
    $state["launcherFolder"] = ""
    $state["launcherInfoBaseId"] = ""
    $state["launcherListPath"] = ""
    $state["roctupMcpStatus"] = "stopped"
    $state["roctupMcpPort"] = 0
    $state["roctupMcpUrl"] = ""
    $state["roctupMcpHealthUrl"] = ""
    $state["roctupMcpPid"] = ""
    $state["vanessaMcpStatus"] = "stopped"
    $state["vanessaMcpPort"] = 0
    $state["vanessaMcpUrl"] = ""
    $state["vanessaMcpPid"] = ""
    return $state
}

function Get-DevBranchForkVerificationDecision {
    param(
        [Parameter(Mandatory = $true)][object]$Snapshot,
        [Parameter(Mandatory = $true)][string]$TargetFingerprint,
        [Parameter(Mandatory = $true)][string]$TargetEnvironmentFingerprint,
        [bool]$BaseRestoreProven
    )

    $sourceFresh = [bool](Get-StateValue -State $Snapshot.sourceVerification -Name "isFreshPassed" -Default $false)
    $sourceFingerprint = [string](Get-StateValue -State $Snapshot.sourceVerification -Name "fingerprint" -Default "")
    $fingerprintMatches = $sourceFingerprint -and $sourceFingerprint -ceq $TargetFingerprint
    $environmentMatches = [string]$Snapshot.sourceEnvironmentFingerprint -and [string]$Snapshot.sourceEnvironmentFingerprint -ceq $TargetEnvironmentFingerprint
    $inherited = $sourceFresh -and $fingerprintMatches -and $environmentMatches -and $BaseRestoreProven
    $reason = if ($inherited) {
        "fresh passed inherited from the exact fork snapshot"
    } else {
        "verification retained as history only: sourceFresh=$sourceFresh fingerprintMatches=$fingerprintMatches environmentMatches=$environmentMatches baseRestoreProven=$BaseRestoreProven"
    }
    return [pscustomobject]@{
        inherited = $inherited
        reason = $reason
        sourceFingerprint = $sourceFingerprint
        targetFingerprint = $TargetFingerprint
        environmentMatches = $environmentMatches
    }
}

function Assert-DevBranchForkHistoryPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $root = (Resolve-Agent1cFullPath -Path (Join-Path $script:ProjectRoot ".agent-1c\fork-history")).TrimEnd("\", "/")
    $resolved = (Resolve-Agent1cFullPath -Path $Path).TrimEnd("\", "/")
    if (-not $resolved.StartsWith(($root + [IO.Path]::DirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase)) {
        throw "DEV_BRANCH_FORK_HISTORY_PATH_OUTSIDE_ROOT: $resolved"
    }
    return $resolved
}

function Assert-DevBranchForkHistoryReady {
    param(
        [Parameter(Mandatory = $true)][object]$Snapshot,
        [Parameter(Mandatory = $true)][string]$TargetHistoryRoot
    )

    $resolved = Assert-DevBranchForkHistoryPath -Path $TargetHistoryRoot
    foreach ($entry in @($Snapshot.historyFiles)) {
        $path = Join-Path $resolved (([string]$entry.path).Replace("/", [IO.Path]::DirectorySeparatorChar))
        if (-not (Test-Path -LiteralPath $path -PathType Leaf -ErrorAction SilentlyContinue)) {
            throw "DEV_BRANCH_FORK_HISTORY_FILE_MISSING: $path"
        }
        $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -cne [string]$entry.sha256) {
            throw "DEV_BRANCH_FORK_HISTORY_SHA_MISMATCH expected='$($entry.sha256)' actual='$actual' path='$path'"
        }
    }
    return $resolved
}

function Install-DevBranchForkHistory {
    param(
        [Parameter(Mandatory = $true)][object]$Snapshot,
        [Parameter(Mandatory = $true)][string]$TargetHistoryRoot
    )

    $resolved = Assert-DevBranchForkHistoryPath -Path $TargetHistoryRoot
    if (-not (Test-Path -LiteralPath $resolved -PathType Container -ErrorAction SilentlyContinue)) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $resolved) | Out-Null
        $partialPath = Assert-DevBranchForkHistoryPath -Path ("$resolved.partial-$($Snapshot.forkId)")
        if (Test-Path -LiteralPath $partialPath -ErrorAction SilentlyContinue) {
            Remove-Item -LiteralPath $partialPath -Recurse -Force
        }
        try {
            Copy-Item -LiteralPath ([string]$Snapshot.historyPath) -Destination $partialPath -Recurse -Force
            Assert-DevBranchForkHistoryReady -Snapshot $Snapshot -TargetHistoryRoot $partialPath | Out-Null
            Move-Item -LiteralPath $partialPath -Destination $resolved
        } finally {
            if (Test-Path -LiteralPath $partialPath -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $partialPath -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
    return (Assert-DevBranchForkHistoryReady -Snapshot $Snapshot -TargetHistoryRoot $resolved)
}

function Restore-DevBranchForkInfoBase {
    param(
        [Parameter(Mandatory = $true)][object]$Snapshot,
        [Parameter(Mandatory = $true)][string]$TargetInfoBasePath
    )

    if ([string]$Snapshot.infoBaseKind -eq "file") {
        $targetPath = Resolve-Agent1cFullPath -Path $TargetInfoBasePath
        $targetArtifact = Join-Path $targetPath "1Cv8.1CD"
        if (-not (Test-Path -LiteralPath $targetArtifact -PathType Leaf -ErrorAction SilentlyContinue)) {
            if (Test-Path -LiteralPath $targetPath -ErrorAction SilentlyContinue) {
                throw "DEV_BRANCH_FORK_TARGET_INFOBASE_INVALID: $targetPath"
            }
            $partialPath = Resolve-Agent1cFullPath -Path ("$targetPath.fork-partial-$($Snapshot.forkId)")
            $expectedPartialPath = "$targetPath.fork-partial-$($Snapshot.forkId)"
            if ($partialPath -cne $expectedPartialPath) {
                throw "DEV_BRANCH_FORK_PARTIAL_INFOBASE_PATH_INVALID expected='$expectedPartialPath' actual='$partialPath'"
            }
            if (Test-Path -LiteralPath $partialPath -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $partialPath -Recurse -Force
            }
            try {
                New-Item -ItemType Directory -Force -Path $partialPath | Out-Null
                $partialArtifact = Join-Path $partialPath "1Cv8.1CD"
                Copy-Item -LiteralPath ([string]$Snapshot.artifactPath) -Destination $partialArtifact
                $partialSha256 = (Get-FileHash -LiteralPath $partialArtifact -Algorithm SHA256).Hash.ToLowerInvariant()
                if ($partialSha256 -cne [string]$Snapshot.artifactSha256) {
                    throw "DEV_BRANCH_FORK_TARGET_ARTIFACT_SHA_MISMATCH expected='$($Snapshot.artifactSha256)' actual='$partialSha256' path='$partialArtifact'"
                }
                Copy-BranchSeedFileDoNotCopyMarker `
                    -SourceInfoBasePath (Split-Path -Parent ([string]$Snapshot.artifactPath)) `
                    -DestinationInfoBasePath $partialPath
                Move-Item -LiteralPath $partialPath -Destination $targetPath
            } finally {
                if (Test-Path -LiteralPath $partialPath -ErrorAction SilentlyContinue) {
                    Remove-Item -LiteralPath $partialPath -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }
        $actual = (Get-FileHash -LiteralPath $targetArtifact -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -cne [string]$Snapshot.artifactSha256) {
            throw "DEV_BRANCH_FORK_TARGET_ARTIFACT_SHA_MISMATCH expected='$($Snapshot.artifactSha256)' actual='$actual' path='$targetArtifact'"
        }
        return $true
    }

    $provider = Get-BranchSeedServerProviderCapabilities
    & powershell -NoProfile -ExecutionPolicy Bypass -File $provider.path `
        -Operation "restore-seed" `
        -ProjectRoot $script:ProjectRoot `
        -DevBranchName ([string]$Snapshot.targetBranchName) `
        -SeedArtifactPath ([string]$Snapshot.artifactPath) `
        -DevBranchInfoBasePath $TargetInfoBasePath
    if ($LASTEXITCODE -ne 0) {
        throw "Server fork restore provider failed with exit code $LASTEXITCODE."
    }
    return $true
}

function Install-DevBranchForkDependencyLock {
    param(
        [Parameter(Mandatory = $true)][object]$Snapshot,
        [Parameter(Mandatory = $true)][string]$TargetProjectRoot
    )

    $snapshotDependencyLockPath = [string](Get-StateValue -State $Snapshot -Name "dependencyLockPath" -Default "")
    if (-not $snapshotDependencyLockPath) { return "" }

    $targetDependencyLockPath = Join-Path (Resolve-Agent1cFullPath -Path $TargetProjectRoot) ".agent-1c\dependency-lock.json"
    if (Test-Path -LiteralPath $targetDependencyLockPath -PathType Leaf -ErrorAction SilentlyContinue) {
        $targetDependencyLockSha256 = (Get-FileHash -LiteralPath $targetDependencyLockPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($targetDependencyLockSha256 -cne [string]$Snapshot.dependencyLockSha256) {
            throw "DEV_BRANCH_FORK_TARGET_DEPENDENCY_LOCK_MISMATCH expected='$($Snapshot.dependencyLockSha256)' actual='$targetDependencyLockSha256' path='$targetDependencyLockPath'"
        }
        return $targetDependencyLockPath
    }

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $targetDependencyLockPath) | Out-Null
    $temporaryDependencyLockPath = "$targetDependencyLockPath.fork-$($Snapshot.forkId).tmp"
    try {
        Copy-Item -LiteralPath $snapshotDependencyLockPath -Destination $temporaryDependencyLockPath
        $copiedDependencyLockSha256 = (Get-FileHash -LiteralPath $temporaryDependencyLockPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($copiedDependencyLockSha256 -cne [string]$Snapshot.dependencyLockSha256) {
            throw "DEV_BRANCH_FORK_TARGET_DEPENDENCY_LOCK_SHA_MISMATCH expected='$($Snapshot.dependencyLockSha256)' actual='$copiedDependencyLockSha256' path='$temporaryDependencyLockPath'"
        }
        Move-Item -LiteralPath $temporaryDependencyLockPath -Destination $targetDependencyLockPath
    } finally {
        Remove-Item -LiteralPath $temporaryDependencyLockPath -Force -ErrorAction SilentlyContinue
    }
    return $targetDependencyLockPath
}

function Install-DevBranchForkDotEnv {
    param(
        [Parameter(Mandatory = $true)][object]$Snapshot,
        [Parameter(Mandatory = $true)][string]$TargetProjectRoot
    )

    $snapshotDotEnvPath = [string](Get-StateValue -State $Snapshot -Name "dotEnvPath" -Default "")
    if (-not $snapshotDotEnvPath) { return "" }

    $targetDotEnvPath = Join-Path (Resolve-Agent1cFullPath -Path $TargetProjectRoot) ".dev.env"
    $temporaryDotEnvPath = "$targetDotEnvPath.fork-$($Snapshot.forkId).tmp"
    try {
        Copy-Item -LiteralPath $snapshotDotEnvPath -Destination $temporaryDotEnvPath -Force
        $copiedSha256 = (Get-FileHash -LiteralPath $temporaryDotEnvPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($copiedSha256 -cne [string]$Snapshot.dotEnvSha256) {
            throw "DEV_BRANCH_FORK_TARGET_DOT_ENV_SHA_MISMATCH expected='$($Snapshot.dotEnvSha256)' actual='$copiedSha256' path='$temporaryDotEnvPath'"
        }
        Move-Item -LiteralPath $temporaryDotEnvPath -Destination $targetDotEnvPath -Force
    } finally {
        Remove-Item -LiteralPath $temporaryDotEnvPath -Force -ErrorAction SilentlyContinue
    }
    return $targetDotEnvPath
}

function Assert-DevBranchForkInfoBaseIsolated {
    param(
        [Parameter(Mandatory = $true)][object]$SourceState,
        [Parameter(Mandatory = $true)][object]$Snapshot,
        [Parameter(Mandatory = $true)][string]$TargetInfoBasePath
    )

    $kind = [string]$Snapshot.infoBaseKind
    $targetIdentity = Get-OneCInfoBaseIdentity -InfoBaseKind $kind -InfoBasePath $TargetInfoBasePath
    $sourceIdentity = Get-OneCInfoBaseIdentity -InfoBaseKind $kind -InfoBasePath ([string]$SourceState.devBranchInfoBasePath)
    if ([string]$targetIdentity.key -eq [string]$sourceIdentity.key) {
        throw "DEV_BRANCH_FORK_INFOBASE_NOT_ISOLATED: target infobase resolves to the source branch infobase. Choose a different DevBranchInfoBasePath."
    }

    foreach ($statePath in @(Get-DevBranchStateFiles | Select-Object -Unique)) {
        try { $otherState = Read-DevBranchStateFile -Path $statePath } catch { continue }
        $otherBranch = [string](Get-StateValue -State $otherState -Name "devBranch" -Default "")
        if ($otherBranch -in @([string]$Snapshot.sourceGitBranch, [string]$Snapshot.targetGitBranch)) { continue }
        $otherPath = [string](Get-StateValue -State $otherState -Name "devBranchInfoBasePath" -Default "")
        if (-not $otherPath) { continue }
        $otherKind = [string](Get-StateValue -State $otherState -Name "infoBaseKind" -Default $kind)
        try { $otherIdentity = Get-OneCInfoBaseIdentity -InfoBaseKind $otherKind -InfoBasePath $otherPath } catch { continue }
        if ([string]$targetIdentity.key -eq [string]$otherIdentity.key) {
            throw "DEV_BRANCH_FORK_INFOBASE_ALREADY_OWNED: target='$TargetInfoBasePath' branch='$otherBranch' state='$statePath'"
        }
    }
}

function Initialize-ForkedDevBranchRuntime {
    param(
        [Parameter(Mandatory = $true)][object]$Snapshot,
        [Parameter(Mandatory = $true)][string]$MainProjectRoot
    )

    $safeName = [string]$Snapshot.targetSafeName
    $statePath = Join-Path $script:ProjectRoot ".agent-1c\dev-branches\$safeName.json"
    $sourceState = Read-Utf8Text -Path (Join-Path ([string]$Snapshot.historyPath) "source-state.json") | ConvertFrom-Json
    $targetInfoBasePath = if ($DevBranchInfoBasePath) {
        $DevBranchInfoBasePath
    } else {
        Join-Path (Resolve-ProjectPath (Get-DevBranchInfoBaseRoot)) $safeName
    }
    Assert-DevBranchForkInfoBaseIsolated -SourceState $sourceState -Snapshot $Snapshot -TargetInfoBasePath $targetInfoBasePath
    Install-DevBranchForkDependencyLock -Snapshot $Snapshot -TargetProjectRoot $script:ProjectRoot | Out-Null
    $targetHistoryRoot = Join-Path $script:ProjectRoot ".agent-1c\fork-history\$($Snapshot.forkId)"
    $stateHash = New-ForkedDevBranchState `
        -SourceState $sourceState `
        -Snapshot $Snapshot `
        -TargetInfoBasePath $targetInfoBasePath `
        -TargetHistoryRoot $targetHistoryRoot `
        -MainProjectRoot $MainProjectRoot
    $statePath = Save-DevBranchInitializationState -SafeDevBranchName $safeName -State $stateHash -Status "fork-initializing"

    try {
        Set-RunStage -Stage "fork.restore.infobase" -Detail "Restoring the forked branch infobase from the immutable source snapshot."
        $baseRestoreProven = Restore-DevBranchForkInfoBase -Snapshot $Snapshot -TargetInfoBasePath $targetInfoBasePath
        Install-DevBranchForkHistory -Snapshot $Snapshot -TargetHistoryRoot $targetHistoryRoot

        $baselineSourcePath = Join-Path $targetHistoryRoot "event-log-baseline.json"
        $baseline = Read-Utf8Text -Path $baselineSourcePath | ConvertFrom-Json
        $baseline.logDirectory = if ([string]$Snapshot.infoBaseKind -eq "file") { Join-Path (Resolve-InfoBasePath $targetInfoBasePath) "1Cv8Log" } else { "" }
        $baseline.reason = "fork-boundary"
        $baseline.cache.status = "fork-history"
        $baseline.cache.path = ""
        $baselinePath = Join-Path $script:ProjectRoot ".agent-1c\event-log-baselines\$safeName.json"
        Write-Utf8Text -Path $baselinePath -Value (($baseline | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
        $stateHash["eventLogBaselinePath"] = $baselinePath
        $stateHash["eventLogBaselineCreatedAt"] = [string]$baseline.createdAt
        $stateHash["eventLogBaselineReader"] = [string]$baseline.reader
        $stateHash["eventLogBaselineErrorCount"] = [int]$baseline.errorCount
        $stateHash["eventLogBaselineSignatureCount"] = [int]$baseline.signatureCount
        $stateHash["eventLogBaselineHash"] = Get-StringSha256 -Value ((@($baseline.signatures) -join "`n"))
        $stateHash["eventLogBaselineCacheStatus"] = "fork-history"
        $stateHash["eventLogBaselineCachePath"] = ""
        $stateHash["eventLogBaselineDurationMs"] = [int64]$baseline.durationMs
        $stateHash["eventLogBaselineSegmentCount"] = [int]$baseline.cache.segmentCount
        $stateHash["lastVanessaEventLogBaselinePath"] = $baselinePath

        $evidencePaths = ConvertTo-Agent1cHashtable -Object $Snapshot.evidencePaths
        foreach ($fieldName in @(
            "lastVerifiedReportPath", "lastVerificationLogPath",
            "lastDiagnosticVerificationReportPath", "lastDiagnosticVerificationLogPath",
            "lastVanessaReportPath", "lastVanessaLogPath", "lastVanessaStatusPath",
            "lastVanessaEventLogNewErrorsPath", "eventLogDebtReportPath"
        )) {
            if ($evidencePaths.ContainsKey($fieldName)) {
                $stateHash[$fieldName] = Join-Path $targetHistoryRoot (([string]$evidencePaths[$fieldName]).Replace("/", [IO.Path]::DirectorySeparatorChar))
            } else {
                $stateHash[$fieldName] = ""
            }
        }

        $launcher = Register-DevBranchInLauncher `
            -InfoBaseKind ([string]$Snapshot.infoBaseKind) `
            -InfoBasePath $targetInfoBasePath `
            -SafeDevBranchName $safeName `
            -ProjectRootForFolder $MainProjectRoot
        $stateHash["launcherRegistered"] = $launcher.registered
        $stateHash["launcherInfoBaseName"] = $launcher.name
        $stateHash["launcherFolder"] = $launcher.folder
        $stateHash["launcherInfoBaseId"] = $launcher.id
        $stateHash["launcherListPath"] = $launcher.listPath
        $statePath = Save-DevBranchInitializationState -SafeDevBranchName $safeName -State $stateHash -Status "launcher-registered"

        $state = Read-DevBranchStateFile -Path $statePath
        Sync-AiRules1cManagedIgnoredFilesFromMain -State $state | Out-Null
        Sync-DevBranchContextToDotEnv -State $state -AllowIncompleteExtension
        $state = Invoke-DevBranchDefaultMcpSetup -State $state
        Invoke-DevBranchVibecoding1cMcpInheritance -MainProjectRoot $MainProjectRoot
        Sync-KiloItlCommandSurface

        $targetFingerprint = Get-VerificationFingerprint
        $targetEnvironmentFingerprint = Get-DevBranchForkEnvironmentFingerprint
        $verificationDecision = Get-DevBranchForkVerificationDecision `
            -Snapshot $Snapshot `
            -TargetFingerprint $targetFingerprint `
            -TargetEnvironmentFingerprint $targetEnvironmentFingerprint `
            -BaseRestoreProven:$baseRestoreProven
        $state = Read-DevBranchStateFile -Path $statePath
        $finalHash = ConvertTo-Agent1cHashtable -Object $state
        [void]$finalHash.Remove("statePath")
        [void]$finalHash.Remove("stateProjectRoot")
        $finalHash["forkVerificationInherited"] = [bool]$verificationDecision.inherited
        $finalHash["forkVerificationReason"] = [string]$verificationDecision.reason
        $finalHash["forkSourceVerificationFingerprint"] = [string]$verificationDecision.sourceFingerprint
        $finalHash["forkTargetVerificationFingerprint"] = [string]$verificationDecision.targetFingerprint
        $finalHash["forkSourceEnvironmentFingerprint"] = [string]$Snapshot.sourceEnvironmentFingerprint
        $finalHash["forkTargetEnvironmentFingerprint"] = $targetEnvironmentFingerprint
        if ($verificationDecision.inherited) {
            $finalHash["lastVerificationStatus"] = "passed"
            $finalHash["lastVerifiedFingerprint"] = $targetFingerprint
        } elseif ([string](Get-StateValue -State $sourceState -Name "lastVerificationStatus" -Default "") -eq "passed") {
            $finalHash["lastVerificationStatus"] = "stale"
            $finalHash["lastVerificationStaleAt"] = (Get-Date).ToString("o")
            $finalHash["lastVerificationStaleReason"] = [string]$verificationDecision.reason
        }
        $statePath = Save-DevBranchInitializationState -SafeDevBranchName $safeName -State $finalHash -Status "ready"
        $state = Read-DevBranchStateFile -Path $statePath
        Ensure-DevBranchEventLogPendingCursor -State $state -Reason "fork-dev-branch" | Out-Null
        $state = Read-DevBranchStateFile -Path $statePath

        $stagingPath = Assert-DevBranchForkStagingPath -Path ([string]$Snapshot.stagingPath)
        if (Test-Path -LiteralPath $stagingPath -PathType Container -ErrorAction SilentlyContinue) {
            Remove-Item -LiteralPath $stagingPath -Recurse -Force
        }
        Set-RunDevBranchState -State $state
        return $state
    } catch {
        $errorMessage = $_.Exception.Message
        if (Test-Path -LiteralPath $statePath -PathType Leaf -ErrorAction SilentlyContinue) {
            $failed = Read-DevBranchStateFile -Path $statePath
            $failedHash = ConvertTo-Agent1cHashtable -Object $failed
            [void]$failedHash.Remove("statePath")
            [void]$failedHash.Remove("stateProjectRoot")
            Save-DevBranchInitializationState -SafeDevBranchName $safeName -State $failedHash -Status "fork-failed" -ErrorMessage $errorMessage | Out-Null
        }
        throw
    }
}

function Invoke-ForkDevBranchRuntimeAfterSnapshot {
    param(
        [Parameter(Mandatory = $true)][object]$Snapshot,
        [Parameter(Mandatory = $true)][string]$MainProjectRoot,
        [Parameter(Mandatory = $true)][string]$WorktreePath
    )

    Set-RunStage -Stage "fork.snapshot-complete" -Detail "Fork snapshot completed; releasing source locks before target restoration."
    Complete-Agent1cLifecycleOperation -Status "succeeded" -ExitCode 0
    Exit-Agent1cLifecycleOperation
    Invoke-InProjectContext -Root $WorktreePath -ScriptBlock {
        Enter-Agent1cLifecycleOperation -RequestedAction "fork-dev-branch"
        Initialize-ForkedDevBranchRuntime -Snapshot $Snapshot -MainProjectRoot $MainProjectRoot | Out-Null
    }
}

function Fork-DevBranch {
    Require-Value "DevBranchName" $DevBranchName | Out-Null
    $sourceGitBranch = (Get-GitOutput @("branch", "--show-current")).Trim()
    if ($sourceGitBranch -notlike "itldev/*") {
        throw "fork-dev-branch must be run from the development branch that should be copied."
    }
    $sourceBranchName = $sourceGitBranch.Substring("itldev/".Length)
    $sourceState = Read-DevBranchState -Name $sourceBranchName
    Assert-DevelopmentBranchWorktreeContext -State $sourceState -Operation "fork-dev-branch"
    Assert-DevBranchExtensionInitialized -State $sourceState -Operation "fork-dev-branch"
    if ([string](Get-StateValue -State $sourceState -Name "workspaceProvider" -Default "external") -eq "opencode") {
        throw "DEV_BRANCH_FORK_WORKSPACE_PROVIDER_UNSUPPORTED: OpenCode native workspaces require a provider-owned fork operation."
    }
    $sourceState = Assert-DevBranchApplicationReady -State $sourceState -Operation "fork-dev-branch"

    $targetSafeName = ConvertTo-SafeName $DevBranchName
    $targetGitBranch = if ($DevBranch) { $DevBranch } else { "itldev/$targetSafeName" }
    if ($targetGitBranch -ceq $sourceGitBranch) {
        throw "DEV_BRANCH_FORK_TARGET_EQUALS_SOURCE: $targetGitBranch"
    }
    $mainProjectRoot = Get-MainWorktreePath
    $targetWorktreePath = Resolve-DevBranchWorktreePath -SafeDevBranchName $targetSafeName
    $branchExists = Test-GitBranchExists -Branch $targetGitBranch

    if ($branchExists) {
        $worktree = Find-GitWorktreeByBranch -Branch $targetGitBranch
        if ($null -eq $worktree -or -not $worktree.path) {
            throw "DEV_BRANCH_FORK_TARGET_WORKTREE_MISSING: $targetGitBranch"
        }
        $targetWorktreePath = Resolve-Agent1cFullPath -Path $worktree.path
        $existingState = $null
        try { $existingState = Read-DevBranchState -Name $DevBranchName } catch { $existingState = $null }
        if ($null -ne $existingState -and
            (Get-DevBranchInitializationStatus -State $existingState) -eq "ready" -and
            [string](Get-StateValue -State $existingState -Name "forkedFromBranch" -Default "") -ceq $sourceGitBranch -and
            [string](Get-StateValue -State $existingState -Name "devBranch" -Default "") -ceq $targetGitBranch) {
            $currentSourceCommit = Get-CurrentCommit
            $forkedFromCommit = [string](Get-StateValue -State $existingState -Name "forkedFromCommit" -Default "")
            if ($forkedFromCommit -cne $currentSourceCommit) {
                throw "DEV_BRANCH_FORK_TARGET_ALREADY_READY: target='$targetGitBranch' forkedFromCommit='$forkedFromCommit' currentSourceCommit='$currentSourceCommit'. Choose a new target branch name for the current source state."
            }
            $completedStagingPath = Get-DevBranchForkStagingPath -SafeDevBranchName $targetSafeName
            if (Test-Path -LiteralPath $completedStagingPath -PathType Container -ErrorAction SilentlyContinue) {
                $completedSnapshot = Read-DevBranchForkSnapshot -StagingPath $completedStagingPath
                if ([string]$completedSnapshot.forkId -cne [string](Get-StateValue -State $existingState -Name "forkId" -Default "")) {
                    throw "DEV_BRANCH_FORK_COMPLETED_STAGING_IDENTITY_MISMATCH: $completedStagingPath"
                }
                Remove-Item -LiteralPath (Assert-DevBranchForkStagingPath -Path $completedStagingPath) -Recurse -Force
            }
            Set-RunDevBranchState -State $existingState
            Write-DevBranchWorktreeOpenMessage -MainProjectPath $script:ProjectRoot -WorktreePath $targetWorktreePath -SourceContext $sourceGitBranch
            Open-AgentWorktreeBestEffort -WorktreePath $targetWorktreePath
            Write-DevBranchRunUserReport -State $existingState -AdvisoryRoot $targetWorktreePath -Operation "forked"
            return
        }
        $snapshot = Read-DevBranchForkSnapshot -StagingPath (Get-DevBranchForkStagingPath -SafeDevBranchName $targetSafeName)
        if ([string]$snapshot.sourceGitBranch -cne $sourceGitBranch -or [string]$snapshot.targetGitBranch -cne $targetGitBranch) {
            throw "DEV_BRANCH_FORK_RESUME_IDENTITY_MISMATCH: source='$sourceGitBranch' target='$targetGitBranch'"
        }
    } else {
        if (Test-Path -LiteralPath $targetWorktreePath -ErrorAction SilentlyContinue) {
            throw "Development branch worktree path already exists: $targetWorktreePath"
        }
        Assert-DevBranchWorktreePathBudget -WorktreePath $targetWorktreePath -SafeDevBranchName $targetSafeName
        Save-DevBranchCheckpoint -Operation "fork-dev-branch" -Message "chore: checkpoint before fork to $targetGitBranch" | Out-Null
        $sourceCommit = Get-CurrentCommit
        $sourceState = Read-DevBranchState -Name $sourceBranchName
        $sourceVerification = Get-VerificationState -State $sourceState
        $sourceEnvironmentFingerprint = Get-DevBranchForkEnvironmentFingerprint
        $snapshot = New-DevBranchForkSnapshot `
            -SourceState $sourceState `
            -TargetBranchName $DevBranchName `
            -TargetSafeName $targetSafeName `
            -TargetGitBranch $targetGitBranch `
            -TargetWorktreePath $targetWorktreePath `
            -SourceCommit $sourceCommit `
            -SourceVerification $sourceVerification `
            -SourceEnvironmentFingerprint $sourceEnvironmentFingerprint

        $worktreeParent = Split-Path -Parent $targetWorktreePath
        if ($worktreeParent) { New-Item -ItemType Directory -Force -Path $worktreeParent | Out-Null }
        Set-RunStage -Stage "fork.git-worktree" -Detail "Creating the target branch from the common source checkpoint."
        Invoke-Git @("worktree", "add", "-b", $targetGitBranch, $targetWorktreePath, $sourceCommit)
    }

    Install-DevBranchForkDotEnv -Snapshot $snapshot -TargetProjectRoot $targetWorktreePath | Out-Null
    Copy-KiloProjectConfigToWorktree -MainProjectRoot $mainProjectRoot -WorktreePath $targetWorktreePath
    Invoke-ForkDevBranchRuntimeAfterSnapshot `
        -Snapshot $snapshot `
        -MainProjectRoot $mainProjectRoot `
        -WorktreePath $targetWorktreePath
    $state = Read-DevBranchState -Name $DevBranchName
    Set-RunDevBranchState -State $state
    Write-DevBranchWorktreeOpenMessage -MainProjectPath $script:ProjectRoot -WorktreePath $targetWorktreePath -SourceContext $sourceGitBranch
    Open-AgentWorktreeBestEffort -WorktreePath $targetWorktreePath
    Write-DevBranchRunUserReport -State $state -AdvisoryRoot $targetWorktreePath -Operation "forked"
}

function Invoke-DevBranchRuntimeAfterGitPhase {
    param(
        [ValidateSet("configuration", "extension")]
        [string]$DevBranchKind,
        [string]$GitBranch,
        [string]$MainProjectRoot,
        [string]$WorktreePath,
        [object]$BranchSeedLease
    )

    try {
        Set-RunStage -Stage "branch.git-phase-complete" -Detail "Git worktree phase completed; releasing the main lifecycle lock before branch runtime initialization."
        Complete-Agent1cLifecycleOperation -Status "succeeded" -ExitCode 0
        Exit-Agent1cLifecycleOperation
        Invoke-InProjectContext -Root $WorktreePath -ScriptBlock {
            Enter-Agent1cLifecycleOperation -RequestedAction "initialize-dev-branch-runtime"
            Initialize-DevBranchRuntime `
                -DevBranchKind $DevBranchKind `
                -SafeDevBranchName (ConvertTo-SafeName $DevBranchName) `
                -GitBranch $GitBranch `
                -MainProjectRoot $MainProjectRoot `
                -WorktreePath $WorktreePath `
                -CreatedWithWorktree $true `
                -BranchSeedLease $BranchSeedLease
        }
    } finally {
        $BranchSeedLease.Dispose()
    }
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

    $seedManifest = Read-BranchSeedManifest -AllowMissing
    if ($null -eq $seedManifest) {
        Write-Host "Legacy project has no branch seed. Running a compatible master sync before branch creation."
        Sync-Master -NoDelegate -SeedPolicy "EnsureCompatible"
    } else {
        Assert-BranchSeedReady | Out-Null
    }

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
            $seedLease = Open-BranchSeedLease -Mode read
            Invoke-DevBranchRuntimeAfterGitPhase `
                -DevBranchKind $DevBranchKind `
                -GitBranch $DevBranch `
                -MainProjectRoot $mainProjectRoot `
                -WorktreePath $resumeWorktreePath `
                -BranchSeedLease $seedLease

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
    Assert-DevBranchWorktreePathBudget -WorktreePath $worktreePath -SafeDevBranchName $safe

    $worktreeParent = Split-Path -Parent $worktreePath
    if ($worktreeParent) {
        New-Item -ItemType Directory -Force -Path $worktreeParent | Out-Null
    }
    Invoke-Git @("worktree", "add", "-b", $DevBranch, $worktreePath, (Get-MasterBranch))
    Copy-DotEnvToWorktree -WorktreePath $worktreePath
    Copy-KiloProjectConfigToWorktree -MainProjectRoot $mainProjectRoot -WorktreePath $worktreePath

    $seedLease = Open-BranchSeedLease -Mode read
    Invoke-DevBranchRuntimeAfterGitPhase `
        -DevBranchKind $DevBranchKind `
        -GitBranch $DevBranch `
        -MainProjectRoot $mainProjectRoot `
        -WorktreePath $worktreePath `
        -BranchSeedLease $seedLease

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
    $snapshotCleanupError = ""
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
            lastExtensionDesignerTreeObjectId = $extensionSource.treeObjectId
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

        try {
            Remove-CompletedInfobaseSnapshot -SnapshotPath $snapshotPath
        } catch {
            $snapshotCleanupError = $_.Exception.Message
            Write-Warning "Extension initialized, but rollback snapshot cleanup failed. Snapshot retained: $snapshotPath Detail: $snapshotCleanupError"
        }

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
                    lastConfigDesignerTreeObjectId = ""
                    lastConfigDesignerLoadedAt = ""
                    lastExtensionDesignerFingerprint = ""
                    lastExtensionDesignerTreeObjectId = ""
                    lastExtensionDesignerLoadedAt = ""
                    sourceFingerprint = ""
                    loadReason = "restore-invalidated"
                    designerInvoked = $false
                    enterpriseInvoked = $false
                    enterpriseNormalizationStatus = "pending"
                    enterpriseNormalizationReason = "extension-init-rollback"
                }
                try {
                    Remove-CompletedInfobaseSnapshot -SnapshotPath $snapshotPath
                } catch {
                    $snapshotCleanupError = $_.Exception.Message
                    Write-Warning "Extension initialization rollback succeeded, but snapshot cleanup failed. Snapshot retained: $snapshotPath Detail: $snapshotCleanupError"
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
        } elseif ($snapshotCleanupError) {
            "Extension initialization failed and the infobase snapshot was restored, but snapshot cleanup failed: $originalError Cleanup: $snapshotCleanupError Snapshot retained: $snapshotPath"
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
        lastExtensionDesignerTreeObjectId = ""
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
    Repair-OneCSourceLineEndings | Out-Null
    Sync-DevBranchContextToDotEnv -State $state
    $state = Ensure-DevBranchEventLogBaseline -State $state
    Ensure-DevBranchEventLogPendingCursor -State $state -Reason "update-dev-branch-base" | Out-Null
    $state = Read-DevBranchState -Name $DevBranchName

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

function Get-RefreshManagedKiloMcpNames {
    param([object]$Config)

    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($family in @("roctup", "vanessa-ui")) {
        $definition = Get-ItlOnDemandMcpFamilyDefinition -Family $family
        if ($definition.serverName -and -not $names.Contains([string]$definition.serverName)) {
            $names.Add([string]$definition.serverName) | Out-Null
        }
    }

    $managedState = Read-ItlManagedMcpState
    $owners = ConvertTo-Vibecoding1cMcpHashtable -Object (Get-Vibecoding1cMcpObjectValue -Object $managedState -Name "owners" -Default ([ordered]@{}))
    foreach ($ownerKey in @($owners.Keys | Where-Object { [string]$_ -like "kilocode/*" })) {
        foreach ($name in @($owners[$ownerKey])) {
            if ($name -and -not $names.Contains([string]$name)) {
                $names.Add([string]$name) | Out-Null
            }
        }
    }

    $configHash = ConvertTo-Vibecoding1cMcpHashtable -Object $Config
    if ($configHash.Contains("mcp")) {
        $mcp = ConvertTo-Vibecoding1cMcpHashtable -Object $configHash["mcp"]
        foreach ($name in @($mcp.Keys)) {
            $managedBy = [string](Get-Vibecoding1cMcpObjectValue -Object $mcp[$name] -Name "managedBy" -Default "")
            if ($managedBy -in @("ondemand-facade", "vibecoding1c-mcp", "itl-branch-mcp", "vanessa-mcp", "vanessa-ui-mcp") -and
                -not $names.Contains([string]$name)) {
                $names.Add([string]$name) | Out-Null
            }
        }
    }
    return @($names)
}

function ConvertTo-RefreshUnmanagedKiloConfigJson {
    param(
        [object]$Config,
        [string[]]$ManagedNames
    )

    $configHash = ConvertTo-Vibecoding1cMcpHashtable -Object $Config
    if ($configHash.Contains("mcp")) {
        $mcp = ConvertTo-Vibecoding1cMcpHashtable -Object $configHash["mcp"]
        foreach ($name in @($ManagedNames | Select-Object -Unique)) {
            if ($mcp.Contains([string]$name)) {
                $mcp.Remove([string]$name)
            }
        }
        $configHash["mcp"] = $mcp
    }
    return ($configHash | ConvertTo-Json -Depth 30 -Compress)
}

function New-RefreshTrackedKiloConfigSnapshot {
    $repoPath = ".kilo/kilo.json"
    $tracked = @(Get-GitPathList -Arguments @("ls-files", "-z", "--", $repoPath)).Count -gt 0
    if (-not $tracked) {
        return [pscustomobject]@{ tracked = $false; repoPath = $repoPath; completed = $false }
    }

    $path = Join-Path $script:ProjectRoot ".kilo\kilo.json"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "REFRESH_TRACKED_STATE_UNEXPECTED: tracked Kilo config is missing before refresh: $repoPath"
    }
    $text = Read-Utf8Text -Path $path
    try {
        $config = $text | ConvertFrom-Json
    } catch {
        throw "REFRESH_TRACKED_STATE_UNEXPECTED: tracked Kilo config is not valid JSON before refresh: $repoPath. $($_.Exception.Message)"
    }
    return [pscustomobject]@{
        tracked = $true
        repoPath = $repoPath
        path = $path
        bytes = [System.IO.File]::ReadAllBytes($path)
        text = $text
        config = $config
        completed = $false
    }
}

function Assert-RefreshTrackedKiloConfigChange {
    param([object]$Snapshot)

    if ($null -eq $Snapshot -or -not $Snapshot.tracked) { return $false }
    if (-not (Test-Path -LiteralPath $Snapshot.path -PathType Leaf)) {
        throw "REFRESH_TRACKED_STATE_UNEXPECTED: refresh removed tracked Kilo config: $($Snapshot.repoPath)"
    }
    $currentText = Read-Utf8Text -Path $Snapshot.path
    if ($currentText -ceq $Snapshot.text) { return $false }
    try {
        $currentConfig = $currentText | ConvertFrom-Json
    } catch {
        throw "REFRESH_TRACKED_STATE_UNEXPECTED: refresh produced invalid tracked Kilo config: $($Snapshot.repoPath). $($_.Exception.Message)"
    }

    $managedNames = @(
        @(Get-RefreshManagedKiloMcpNames -Config $Snapshot.config)
        @(Get-RefreshManagedKiloMcpNames -Config $currentConfig)
    ) | Select-Object -Unique
    $beforeUnmanaged = ConvertTo-RefreshUnmanagedKiloConfigJson -Config $Snapshot.config -ManagedNames $managedNames
    $afterUnmanaged = ConvertTo-RefreshUnmanagedKiloConfigJson -Config $currentConfig -ManagedNames $managedNames
    if ($beforeUnmanaged -cne $afterUnmanaged) {
        throw "REFRESH_TRACKED_STATE_UNEXPECTED: refresh changed non-ITL content in tracked Kilo config: $($Snapshot.repoPath)"
    }
    return $true
}

function Restore-RefreshTrackedKiloConfigSnapshot {
    param([object]$Snapshot)

    if ($null -eq $Snapshot -or -not $Snapshot.tracked -or $Snapshot.completed) { return }
    $temporaryPath = "$($Snapshot.path).refresh-rollback-$PID"
    try {
        [System.IO.File]::WriteAllBytes($temporaryPath, [byte[]]$Snapshot.bytes)
        Move-Item -LiteralPath $temporaryPath -Destination $Snapshot.path -Force
    } finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    }
}

function Complete-RefreshConfigDumpInfoPostcondition {
    param(
        [Parameter(Mandatory = $true)][object]$LoadResult,
        [string]$ExportPath = (Get-ExportPath),
        [object]$TrackedKiloSnapshot = $null,
        [object]$State = $null,
        [string]$Operation = ""
    )

    $normalizedExportPath = (($ExportPath -replace "\\", "/").Trim("/"))
    $dumpInfoRepoPath = "$normalizedExportPath/ConfigDumpInfo.xml"
    $trackedKiloChanged = Assert-RefreshTrackedKiloConfigChange -Snapshot $TrackedKiloSnapshot
    $allowedPaths = @($dumpInfoRepoPath)
    if ($trackedKiloChanged) {
        $allowedPaths += [string]$TrackedKiloSnapshot.repoPath
    }
    $trackedPaths = @(
        @(Get-GitPathList -Arguments @("diff", "--name-only", "-z", "--diff-filter=ACMRTUXBD", "--"))
        @(Get-GitPathList -Arguments @("diff", "--cached", "--name-only", "-z", "--diff-filter=ACMRTUXBD", "--"))
    ) | Sort-Object -Unique
    $unexpectedPaths = @($trackedPaths | Where-Object {
        $allowedPaths -cnotcontains ([string]$_ -replace "\\", "/")
    })
    if ($unexpectedPaths.Count -gt 0) {
        throw "REFRESH_TRACKED_STATE_UNEXPECTED: refresh changed tracked files other than the branch synchronization cursor: $($unexpectedPaths -join ', ')"
    }

    $pathsToCommit = @($trackedPaths | Where-Object { $allowedPaths -ccontains ([string]$_ -replace "\\", "/") })
    if ($pathsToCommit.Count -gt 0) {
        $commitMessage = if ($trackedKiloChanged) { "chore: persist branch refresh state" } else { "chore: persist branch configuration synchronization cursor" }
        Commit-IfChanged `
            -Message $commitMessage `
            -PathSpec $pathsToCommit `
            -RequireChanges | Out-Null
    }

    $LoadResult.currentCommit = Get-CurrentCommit
    if ($null -ne $State -and $Operation) {
        Set-DevBranchLifecyclePostMergeHeadCheckpoint `
            -State $State `
            -Operation $Operation `
            -PostMergeHead $LoadResult.currentCommit
    }
    Assert-CleanGit
    if ($null -ne $TrackedKiloSnapshot) {
        $TrackedKiloSnapshot.completed = $true
    }
}

function Write-ConfigRepositoryObjectList {
    param(
        [Parameter(Mandatory = $true)][object]$Plan,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $settings = [System.Xml.XmlWriterSettings]::new()
    $settings.Encoding = [System.Text.UTF8Encoding]::new($false)
    $settings.Indent = $true
    $settings.NewLineChars = [Environment]::NewLine
    $settings.NewLineHandling = [System.Xml.NewLineHandling]::Replace
    $parent = Split-Path -Parent $Path
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    $namespace = "http://v8.1c.ru/8.3/config/objects"
    $writer = [System.Xml.XmlWriter]::Create($Path, $settings)
    try {
        $writer.WriteStartDocument()
        $writer.WriteStartElement("Objects", $namespace)
        $writer.WriteAttributeString("version", "1.0")
        foreach ($item in @($Plan.items | Sort-Object name)) {
            $writer.WriteStartElement("Object", $namespace)
            $writer.WriteAttributeString("fullName", [string]$item.name)
            $writer.WriteAttributeString("includeChildObjects", $(if ([string]$item.scope -eq "full") { "true" } else { "false" }))
            $writer.WriteEndElement()
        }
        $writer.WriteEndElement()
        $writer.WriteEndDocument()
    } finally {
        $writer.Dispose()
    }

    return (Resolve-Agent1cFullPath -Path $Path)
}

function Write-ConfigRepositoryLockRedactedLog {
    param([Parameter(Mandatory = $true)][string]$RunRoot)

    if (-not $script:LastLogPath -or -not (Test-Path -LiteralPath $script:LastLogPath -PathType Leaf -ErrorAction SilentlyContinue)) {
        return ""
    }
    $text = Read-Utf8Text -Path $script:LastLogPath
    $password = [string](Get-EnvValue -Name "REPOSITORY_PASSWORD" -Default "")
    if ($password) { $text = $text.Replace($password, "<redacted>") }
    $text = [regex]::Replace($text, '(?i)(/(?:P|Password)\s+)(?:"[^"]*"|\S+)', '$1<redacted>')
    $path = Join-Path $RunRoot "repository-lock.log"
    Write-Utf8Text -Path $path -Value $text
    return (Resolve-Agent1cFullPath -Path $path)
}

function Get-ConfigRepositoryLockConflictSummary {
    param(
        [string]$LogPath,
        [ValidateRange(1, 50)][int]$MaximumItems = 10
    )

    if (-not $LogPath -or -not (Test-Path -LiteralPath $LogPath -PathType Leaf -ErrorAction SilentlyContinue)) {
        return ""
    }

    try {
        $text = Read-Utf8Text -Path $LogPath
    } catch {
        return ""
    }
    $pattern = '(?im)^\s*Объект захвачен для редактирования другим пользователем:\s*(?<object>.+?)\s+\((?<owner>[^()\r\n]+)\)\s*$'
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $conflicts = [System.Collections.Generic.List[object]]::new()
    foreach ($match in [regex]::Matches($text, $pattern)) {
        $objectName = [string]$match.Groups["object"].Value.Trim()
        $owner = [string]$match.Groups["owner"].Value.Trim()
        if (-not $objectName -or -not $owner) { continue }
        if ($seen.Add("$objectName`0$owner")) {
            $conflicts.Add([pscustomobject]@{ objectName = $objectName; owner = $owner }) | Out-Null
        }
    }
    if ($conflicts.Count -eq 0) {
        return ""
    }

    $visible = @($conflicts | Select-Object -First $MaximumItems)
    if ($conflicts.Count -eq 1) {
        return "LOCK_CONFIG_REPOSITORY_OBJECT_CONFLICT: объект $($visible[0].objectName) уже захвачен пользователем $($visible[0].owner)."
    }

    $details = @($visible | ForEach-Object { "$($_.objectName) — $($_.owner)" })
    $remainder = if ($conflicts.Count -gt $visible.Count) { "; ещё $($conflicts.Count - $visible.Count)" } else { "" }
    return "LOCK_CONFIG_REPOSITORY_OBJECT_CONFLICT: объекты уже захвачены другими пользователями: $($details -join '; ')$remainder."
}

function Invoke-ConfigRepositoryObjectOperation {
    param(
        [Parameter(Mandatory = $true)][ValidateSet("/ConfigurationRepositoryLock", "/ConfigurationRepositoryUnLock")][string]$Operation,
        [Parameter(Mandatory = $true)][string]$ObjectListPath
    )

    $designerArgs = (New-RepositoryConnectionArgs) + @($Operation, "-Objects", $ObjectListPath)
    Invoke-Designer -InfoBasePath (Get-SourceInfoBasePath) -InfoBaseKind (Get-InfoBaseKind) -DesignerArgs $designerArgs | Out-Null
}

function Lock-ConfigRepositoryObjects {
    $state = Read-DevBranchState -Name $DevBranchName
    Assert-DevelopmentBranchWorktreeContext -State $state -Operation "lock-config-repository-objects"
    if ((Get-DevBranchInitializationStatus -State $state) -ne "ready") {
        throw "LOCK_CONFIG_REPOSITORY_BRANCH_NOT_READY: the development branch must be ready."
    }
    if ((Get-DevBranchKind -State $state) -ne "configuration") {
        throw "LOCK_CONFIG_REPOSITORY_EXTENSION_UNSUPPORTED: extension repository ownership is not configured by this command."
    }
    if (-not (Get-SourceUsesRepository)) {
        throw "LOCK_CONFIG_REPOSITORY_NOT_CONFIGURED: SOURCE_USES_REPOSITORY=false."
    }

    Repair-OneCSourceLineEndings | Out-Null
    $plan = Get-ConfigRepositoryTransferPlan -ExportPath (Get-ExportPath)
    $unresolved = @($plan.unresolvedPaths)
    if ($unresolved.Count -gt 0) {
        throw "LOCK_CONFIG_REPOSITORY_UNRESOLVED_PATHS: $($unresolved -join ', ')"
    }
    $items = @($plan.items)
    $report = [System.Collections.Generic.List[string]]::new()
    $report.Add("## Захват объектов в хранилище")
    Add-RunUserReportLine -Lines $report -Label "База сравнения" -Value ([string]$plan.baseCommit)
    if ($items.Count -eq 0) {
        Add-RunUserReportLine -Lines $report -Label "Результат" -Value "изменённых объектов нет; захват не выполнялся"
        Write-AndSetRunUserReport -Lines $report
        return
    }

    $runRoot = if ($RunStatusPath) {
        Split-Path -Parent (Resolve-RunFilePath -Path $RunStatusPath)
    } else {
        Join-Path $script:ProjectRoot (".agent-1c\runs\repository-lock-{0}-{1}" -f (Get-Date -Format "yyyyMMdd-HHmmss-fff"), ([guid]::NewGuid().ToString("N").Substring(0, 8)))
    }
    New-Item -ItemType Directory -Force -Path $runRoot | Out-Null
    $objectListPath = Write-ConfigRepositoryObjectList -Plan $plan -Path (Join-Path $runRoot "repository-objects.xml")
    Set-RunStage -Stage "repository-lock.designer" -Detail "Locking the exact changed configuration objects in the source repository."
    try {
        Invoke-ConfigRepositoryObjectOperation -Operation "/ConfigurationRepositoryLock" -ObjectListPath $objectListPath
        $redactedLogPath = Write-ConfigRepositoryLockRedactedLog -RunRoot $runRoot
    } catch {
        $designerError = $_.Exception.Message
        $redactedLogPath = ""
        try {
            $redactedLogPath = Write-ConfigRepositoryLockRedactedLog -RunRoot $runRoot
        } catch {
            $redactedLogPath = ""
        }
        $diagnosticLogPath = if ($redactedLogPath) { $redactedLogPath } else { [string]$script:LastLogPath }
        $conflictSummary = Get-ConfigRepositoryLockConflictSummary -LogPath $diagnosticLogPath
        if ($conflictSummary) {
            if ($redactedLogPath) { $script:LastLogPath = $redactedLogPath }
            Set-RunStage -Stage "repository-lock.conflict" -Detail $conflictSummary
            Set-RunFailureContext `
                -Category "runner" `
                -RequiredAction "Освободите перечисленные объекты в хранилище или согласуйте это с указанными пользователями, затем повторите /itl-lock-objects."
            $logDetail = if ($redactedLogPath) { " Редактированный лог: $redactedLogPath" } else { "" }
            throw "$conflictSummary$logDetail"
        }
        $redactedLogDetail = if ($redactedLogPath) { " Редактированный лог: $redactedLogPath" } else { "" }
        throw "$designerError$redactedLogDetail"
    }

    Add-RunUserReportLine -Lines $report -Label "Результат" -Value "успешно"
    Add-RunUserReportLine -Lines $report -Label "Исходная база" -Value (Get-SourceInfoBasePath)
    Add-RunUserReportLine -Lines $report -Label "Пользователь хранилища" -Value (Get-EnvValue -Name "REPOSITORY_USER")
    Add-RunUserReportLine -Lines $report -Label "Файл объектов" -Value $objectListPath
    Add-RunUserReportLine -Lines $report -Label "Редактированный лог" -Value $redactedLogPath -Default "<лог 1С не создан>"
    $report.Add("")
    $report.Add("### Захваченные объекты")
    foreach ($item in $items) {
        $report.Add("- $([string]$item.name) ($([string]$item.scope))")
    }
    Write-AndSetRunUserReport -Lines $report
}

function Invoke-ReleaseE2EConfigRepositoryLockRoundtrip {
    $state = Read-DevBranchState -Name $DevBranchName
    Assert-DevelopmentBranchWorktreeContext -State $state -Operation "release-e2e-config-repository-lock-roundtrip"
    if ((Get-DevBranchKind -State $state) -ne "configuration") {
        throw "RELEASE_E2E_CONFIG_REPOSITORY_REQUIRED: the release repository probe requires a configuration branch."
    }
    $runRoot = Join-Path $script:ProjectRoot (".agent-1c\runs\release-e2e-repository-lock-{0}" -f ([guid]::NewGuid().ToString("N")))
    New-Item -ItemType Directory -Force -Path $runRoot | Out-Null
    $repositoryEnvironment = $null
    try {
        if (-not (Get-SourceUsesRepository)) {
            $repositoryEnvironment = @{}
            foreach ($name in @("SOURCE_USES_REPOSITORY", "REPOSITORY_PATH", "REPOSITORY_USER", "REPOSITORY_PASSWORD")) {
                $repositoryEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
            }
            [Environment]::SetEnvironmentVariable("SOURCE_USES_REPOSITORY", "true", "Process")
            [Environment]::SetEnvironmentVariable("REPOSITORY_PATH", (Join-Path $runRoot "repository"), "Process")
            [Environment]::SetEnvironmentVariable("REPOSITORY_USER", "itl-release", "Process")
            [Environment]::SetEnvironmentVariable("REPOSITORY_PASSWORD", "", "Process")
            Set-RunStage -Stage "repository-lock.provision" -Detail "Creating a disposable configuration repository for the Release E2E branch."
            Invoke-Designer `
                -InfoBasePath (Get-SourceInfoBasePath) `
                -InfoBaseKind (Get-InfoBaseKind) `
                -DesignerArgs ((New-RepositoryConnectionArgs) + @("/ConfigurationRepositoryCreate")) | Out-Null
        }

        $plan = Get-ConfigRepositoryTransferPlan -ExportPath (Get-ExportPath)
        if (@($plan.unresolvedPaths).Count -gt 0) {
            throw "RELEASE_E2E_CONFIG_REPOSITORY_UNRESOLVED: $(@($plan.unresolvedPaths) -join ', ')"
        }
        if (@($plan.items).Count -eq 0) {
            throw "RELEASE_E2E_CONFIG_REPOSITORY_DELTA_REQUIRED: the release probe must change at least one mapped configuration object."
        }
        $objectListPath = Write-ConfigRepositoryObjectList -Plan $plan -Path (Join-Path $runRoot "repository-objects.xml")
        $locked = $false
        try {
            Invoke-ConfigRepositoryObjectOperation -Operation "/ConfigurationRepositoryLock" -ObjectListPath $objectListPath
            $locked = $true
        } finally {
            if ($locked) {
                Invoke-ConfigRepositoryObjectOperation -Operation "/ConfigurationRepositoryUnLock" -ObjectListPath $objectListPath
            }
        }

        $report = [System.Collections.Generic.List[string]]::new()
        $report.Add("## Release E2E: точечный захват объектов")
        Add-RunUserReportLine -Lines $report -Label "Результат" -Value "захват и освобождение выполнены"
        Add-RunUserReportLine -Lines $report -Label "Файл объектов" -Value $objectListPath
        foreach ($item in @($plan.items)) { $report.Add("- $([string]$item.name) ($([string]$item.scope))") }
        Write-AndSetRunUserReport -Lines $report
    } finally {
        if ($null -ne $repositoryEnvironment) {
            foreach ($name in $repositoryEnvironment.Keys) {
                [Environment]::SetEnvironmentVariable($name, $repositoryEnvironment[$name], "Process")
            }
        }
    }
}

function Assert-DevBranchCheckpointGitState {
    param([string]$Operation)

    $gitStatePaths = @(
        @{ name = "merge"; path = "MERGE_HEAD"; kind = "file" },
        @{ name = "cherry-pick"; path = "CHERRY_PICK_HEAD"; kind = "file" },
        @{ name = "revert"; path = "REVERT_HEAD"; kind = "file" },
        @{ name = "rebase"; path = "rebase-apply"; kind = "directory" },
        @{ name = "rebase"; path = "rebase-merge"; kind = "directory" }
    )
    foreach ($entry in $gitStatePaths) {
        $resolved = (Get-GitOutput @("rev-parse", "--git-path", [string]$entry.path)).Trim()
        if (-not [System.IO.Path]::IsPathRooted($resolved)) {
            $resolved = Join-Path $script:ProjectRoot $resolved
        }
        $exists = if ($entry.kind -eq "directory") {
            Test-Path -LiteralPath $resolved -PathType Container -ErrorAction SilentlyContinue
        } else {
            Test-Path -LiteralPath $resolved -PathType Leaf -ErrorAction SilentlyContinue
        }
        if ($exists) {
            throw "DEV_BRANCH_CHECKPOINT_GIT_OPERATION_IN_PROGRESS: $Operation cannot checkpoint while a $($entry.name) operation is in progress. Complete or abort it first."
        }
    }

    $unmerged = @(Get-GitPathList -Arguments @("diff", "--name-only", "-z", "--diff-filter=U", "--"))
    if ($unmerged.Count -gt 0) {
        throw "DEV_BRANCH_CHECKPOINT_UNMERGED_PATHS: $Operation cannot checkpoint unresolved paths: $($unmerged -join ', ')"
    }
}

function Save-DevBranchCheckpoint {
    param(
        [string]$Operation,
        [string]$Message = "chore: checkpoint before branch refresh"
    )

    Assert-DevBranchCheckpointGitState -Operation $Operation
    Repair-OneCSourceLineEndings | Out-Null
    if (-not (Test-GitHasChanges)) {
        Write-Host "Development branch checkpoint: no changes."
        return ""
    }

    Set-RunStage -Stage "$Operation.checkpoint" -Detail "Committing accumulated development branch changes before lifecycle mutation."
    Commit-IfChanged -Message $Message -PathSpec @(".") -RequireChanges | Out-Null
    Assert-CleanGit
    $checkpointCommit = Get-CurrentCommit
    Write-Host "Development branch checkpoint commit: $checkpointCommit"
    return $checkpointCommit
}

function Get-DevBranchArchiveRoot {
    $root = Join-Path (Get-MainWorktreePath) ".agent-1c\branch-archives"
    return (Resolve-Agent1cFullPath -Path $root)
}

function Assert-PathUnderDevBranchArchiveRoot {
    param([Parameter(Mandatory = $true)][string]$Path)

    $root = (Get-DevBranchArchiveRoot).TrimEnd("\", "/")
    $resolved = (Resolve-Agent1cFullPath -Path $Path).TrimEnd("\", "/")
    if (-not $resolved.StartsWith(($root + [IO.Path]::DirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase)) {
        throw "DEV_BRANCH_ARCHIVE_PATH_OUTSIDE_ROOT: $resolved"
    }
    return $resolved
}

function Get-DevBranchResetMasterSource {
    $mainRoot = Get-MainWorktreePath
    return Invoke-InProjectContext -Root $mainRoot -ScriptBlock {
        Assert-MasterWorktreeContext -Operation "reset-dev-branch seed preflight"
        Assert-CleanGit
        $masterCommit = Get-CurrentCommit
        $source = Get-ConfigSourceFingerprint -ExportPath (Get-ExportPath)
        [pscustomobject]@{
            commit = $masterCommit
            tree = (Get-GitOutput @("rev-parse", "$masterCommit^{tree}")).Trim()
            fingerprint = [string]$source.fingerprint
            configTreeObjectId = [string]$source.treeObjectId
        }
    }
}

function Assert-DevBranchResetArchiveReady {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$OldHead,
        [Parameter(Mandatory = $true)][string]$MasterCommit
    )

    $finalPath = Assert-PathUnderDevBranchArchiveRoot -Path $ArchivePath
    $manifestPath = Join-Path $finalPath "manifest.json"
    $verifiedManifest = Read-Utf8Text -Path $manifestPath | ConvertFrom-Json
    if ([int]$verifiedManifest.schemaVersion -ne 1 -or [string]$verifiedManifest.status -ne "ready" -or
        [string]$verifiedManifest.oldHead -cne $OldHead -or [string]$verifiedManifest.masterCommit -cne $MasterCommit) {
        throw "DEV_BRANCH_ARCHIVE_MANIFEST_INVALID: $manifestPath"
    }
    $verifiedDtPath = Join-Path $finalPath ([string]$verifiedManifest.dt.path)
    $verifiedDtHash = (Get-FileHash -LiteralPath $verifiedDtPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($verifiedDtHash -cne [string]$verifiedManifest.dt.sha256 -or
        (Get-Item -LiteralPath $verifiedDtPath).Length -ne [long]$verifiedManifest.dt.bytes) {
        throw "DEV_BRANCH_ARCHIVE_DT_VERIFY_FAILED: $verifiedDtPath"
    }
    foreach ($record in @($verifiedManifest.files)) {
        $verifiedFilePath = Resolve-Agent1cFullPath -Path (Join-Path (Join-Path $finalPath "files") ([string]$record.path))
        if (-not (Test-Path -LiteralPath $verifiedFilePath -PathType Leaf) -or
            (Get-Item -LiteralPath $verifiedFilePath).Length -ne [long]$record.bytes -or
            (Get-FileHash -LiteralPath $verifiedFilePath -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$record.sha256) {
            throw "DEV_BRANCH_ARCHIVE_FILE_VERIFY_FAILED: $verifiedFilePath"
        }
    }
    return [pscustomobject]@{ archivePath = $finalPath; dtPath = $verifiedDtPath; manifestPath = $manifestPath }
}

function New-DevBranchResetArchive {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$MasterCommit,
        [Parameter(Mandatory = $true)][string]$OldHead,
        [Parameter(Mandatory = $true)][string]$ArchivePath
    )

    $finalPath = Assert-PathUnderDevBranchArchiveRoot -Path $ArchivePath
    $partialPath = Assert-PathUnderDevBranchArchiveRoot -Path ($finalPath + ".partial")
    if (Test-Path -LiteralPath $partialPath -ErrorAction SilentlyContinue) {
        Remove-Item -LiteralPath $partialPath -Recurse -Force
    }
    if (Test-Path -LiteralPath $finalPath -PathType Container -ErrorAction SilentlyContinue) {
        return (Assert-DevBranchResetArchiveReady -ArchivePath $finalPath -OldHead $OldHead -MasterCommit $MasterCommit)
    }
    New-Item -ItemType Directory -Force -Path (Join-Path $partialPath "files") | Out-Null

    Set-RunStage -Stage "reset.archive-dt" -Detail "Dumping the current development infobase before reset."
    $dtPath = Join-Path $partialPath "infobase.dt"
    Invoke-Designer -InfoBasePath ([string]$State.devBranchInfoBasePath) -InfoBaseKind ([string]$State.infoBaseKind) -DesignerArgs @("/DumpIB", $dtPath) | Out-Null
    if (-not (Test-Path -LiteralPath $dtPath -PathType Leaf) -or (Get-Item -LiteralPath $dtPath).Length -le 0) {
        throw "DEV_BRANCH_ARCHIVE_DT_EMPTY: $dtPath"
    }

    Set-RunStage -Stage "reset.archive-files" -Detail "Archiving the non-configuration delta against local master."
    $changedPaths = @(Get-GitPathList -Arguments @("diff", "--name-only", "-z", "--no-renames", "--diff-filter=ACMRTUXBD", $MasterCommit, "--"))
    $deletedPaths = @(Get-GitPathList -Arguments @("diff", "--name-only", "-z", "--no-renames", "--diff-filter=D", $MasterCommit, "--"))
    $configPaths = @($changedPaths | Where-Object { ([string]$_).Replace("\", "/") -match '^src/(?:cf|cfe)(?:/|$)' })
    $deletedSet = New-Object "System.Collections.Generic.HashSet[string]" ([StringComparer]::Ordinal)
    foreach ($path in $deletedPaths) { [void]$deletedSet.Add(([string]$path).Replace("\", "/")) }
    $fileRecords = @()
    foreach ($repoPath in @($changedPaths | Sort-Object -Unique)) {
        $normalized = ([string]$repoPath).Replace("\", "/")
        if ($normalized -match '^src/(?:cf|cfe)(?:/|$)' -or $deletedSet.Contains($normalized)) { continue }
        $sourcePath = Resolve-Agent1cFullPath -Path (Join-Path $script:ProjectRoot $repoPath)
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) { continue }
        $destination = Resolve-Agent1cFullPath -Path (Join-Path (Join-Path $partialPath "files") $repoPath)
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
        Copy-Item -LiteralPath $sourcePath -Destination $destination -Force
        $fileRecords += [ordered]@{
            path = $normalized
            bytes = (Get-Item -LiteralPath $destination).Length
            sha256 = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }

    $manifest = [ordered]@{
        schemaVersion = 1
        status = "ready"
        createdAt = (Get-Date).ToString("o")
        branch = [string]$State.devBranch
        oldHead = $OldHead
        oldTree = (Get-GitOutput @("rev-parse", "$OldHead^{tree}")).Trim()
        masterCommit = $MasterCommit
        masterTree = (Get-GitOutput @("rev-parse", "$MasterCommit^{tree}")).Trim()
        dt = [ordered]@{
            path = "infobase.dt"
            bytes = (Get-Item -LiteralPath $dtPath).Length
            sha256 = (Get-FileHash -LiteralPath $dtPath -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        files = @($fileRecords)
        deletedPaths = @($deletedPaths | ForEach-Object { ([string]$_).Replace("\", "/") } | Where-Object { $_ -notmatch '^src/(?:cf|cfe)(?:/|$)' } | Sort-Object -Unique)
        excludedConfigurationPaths = @($configPaths | ForEach-Object { ([string]$_).Replace("\", "/") } | Sort-Object -Unique)
    }
    Write-Utf8Text -Path (Join-Path $partialPath "manifest.json") -Value (($manifest | ConvertTo-Json -Depth 10) + [Environment]::NewLine)
    Move-Item -LiteralPath $partialPath -Destination $finalPath
    return (Assert-DevBranchResetArchiveReady -ArchivePath $finalPath -OldHead $OldHead -MasterCommit $MasterCommit)
}

function Set-DevBranchTreeToMasterCommit {
    param([Parameter(Mandatory = $true)][string]$MasterCommit)

    $currentPaths = @(Get-GitPathList -Arguments @("ls-files", "-z"))
    $masterPaths = @(Get-GitPathList -Arguments @("ls-tree", "-r", "--name-only", "-z", $MasterCommit))
    $masterSet = New-Object "System.Collections.Generic.HashSet[string]" ([StringComparer]::Ordinal)
    foreach ($path in $masterPaths) { [void]$masterSet.Add(([string]$path).Replace("\", "/")) }
    $pathsToRemove = @($currentPaths | Where-Object { -not $masterSet.Contains(([string]$_).Replace("\", "/")) })

    Invoke-Git @("read-tree", $MasterCommit)
    Invoke-Git @("checkout-index", "--all", "--force")
    $projectRoot = (Resolve-Agent1cFullPath -Path $script:ProjectRoot).TrimEnd("\", "/")
    foreach ($repoPath in $pathsToRemove) {
        $absolute = Resolve-Agent1cFullPath -Path (Join-Path $script:ProjectRoot $repoPath)
        if (-not $absolute.StartsWith(($projectRoot + [IO.Path]::DirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase)) {
            throw "DEV_BRANCH_RESET_PATH_OUTSIDE_WORKTREE: $absolute"
        }
        if (Test-Path -LiteralPath $absolute -PathType Leaf -ErrorAction SilentlyContinue) {
            Remove-Item -LiteralPath $absolute -Force
        }
    }

    $expectedTree = (Get-GitOutput @("rev-parse", "$MasterCommit^{tree}")).Trim()
    $actualTree = (Get-GitOutput @("write-tree")).Trim()
    if ($actualTree -cne $expectedTree) {
        throw "DEV_BRANCH_RESET_TREE_MISMATCH: expected=$expectedTree actual=$actualTree"
    }
    Invoke-Git @("commit", "--quiet", "-m", "chore: reset branch for next change")
    Assert-CleanGit
    return (Get-CurrentCommit)
}

function Restore-ExistingDevBranchFromSeed {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$ExpectedConfigurationFingerprint
    )

    $seed = Assert-BranchSeedReady -ExpectedConfigurationFingerprint $ExpectedConfigurationFingerprint
    $lease = Open-BranchSeedLease -Mode read
    try {
        if ((Get-InfoBaseKind) -eq "file") {
            $infoBasePath = Resolve-Agent1cFullPath -Path ([string]$State.devBranchInfoBasePath)
            New-Item -ItemType Directory -Force -Path $infoBasePath | Out-Null
            $target = Join-Path $infoBasePath "1Cv8.1CD"
            $temporary = Join-Path $infoBasePath (".itl-reset-{0}.1CD" -f ([guid]::NewGuid().ToString("N")))
            try {
                Copy-Item -LiteralPath ([string]$seed.artifactPath) -Destination $temporary
                $actualHash = (Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash.ToLowerInvariant()
                if ($actualHash -cne [string]$seed.artifactSha256) {
                    throw "DEV_BRANCH_RESET_SEED_HASH_MISMATCH: expected=$($seed.artifactSha256) actual=$actualHash"
                }
                Move-Item -LiteralPath $temporary -Destination $target -Force
            } finally {
                Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
            }
            Remove-BranchSeedFileRuntimeSidecars -ArtifactPath $target
            Copy-BranchSeedFileDoNotCopyMarker -SourceInfoBasePath (Split-Path -Parent ([string]$seed.artifactPath)) -DestinationInfoBasePath $infoBasePath
        } else {
            $provider = Get-BranchSeedServerProviderCapabilities
            & powershell -NoProfile -ExecutionPolicy Bypass -File $provider.path `
                -Operation "restore-seed" `
                -ProjectRoot $script:ProjectRoot `
                -DevBranchName ([string]$State.devBranchName) `
                -SeedArtifactPath ([string]$seed.artifactPath) `
                -DevBranchInfoBasePath ([string]$State.devBranchInfoBasePath)
            if ($LASTEXITCODE -ne 0) { throw "Server seed restore provider failed with exit code $LASTEXITCODE." }
        }
    } finally {
        $lease.Dispose()
    }
    return $seed
}

function Restore-ExistingDevBranchRuntimeFromSeed {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$ExpectedConfigurationFingerprint
    )

    $seed = Restore-ExistingDevBranchFromSeed `
        -State $State `
        -ExpectedConfigurationFingerprint $ExpectedConfigurationFingerprint
    $repositoryUnbound = $false
    if (Get-SourceUsesRepository) {
        Set-RunStage -Stage "reset.repository-unbind" -Detail "Unbinding the restored development copy from the source configuration repository."
        Invoke-Designer `
            -InfoBasePath ([string]$State.devBranchInfoBasePath) `
            -InfoBaseKind ([string]$State.infoBaseKind) `
            -DesignerArgs @("/ConfigurationRepositoryUnbindCfg", "-force") | Out-Null
        $repositoryUnbound = $true
    }
    return [pscustomobject]@{ seed = $seed; repositoryUnbound = $repositoryUnbound }
}

function Add-DevBranchResetTransientStateClearUpdates {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][hashtable]$Updates
    )

    $stateHash = ConvertTo-Agent1cHashtable -Object $State
    foreach ($key in @($stateHash.Keys)) {
        if ([string]$key -notmatch '^(?:last(?:Vanessa|Verification|Verified|Result|Unverified|EventLog)|finalResult|eventLogDebt|eventLogPendingCursor)') {
            continue
        }
        $value = $stateHash[$key]
        $Updates[[string]$key] = if ($value -is [bool]) {
            $false
        } elseif ($value -is [byte] -or $value -is [int16] -or $value -is [int32] -or $value -is [int64] -or
            $value -is [uint16] -or $value -is [uint32] -or $value -is [uint64] -or
            $value -is [single] -or $value -is [double] -or $value -is [decimal]) {
            0
        } elseif ($value -is [System.Collections.IEnumerable] -and $value -isnot [string] -and $value -isnot [System.Collections.IDictionary]) {
            @()
        } else {
            ""
        }
    }
}

function Reset-DevBranch {
    $state = Read-DevBranchState -Name $DevBranchName
    Assert-DevelopmentBranchWorktreeContext -State $state -Operation "reset-dev-branch"
    if ((Get-DevBranchKind -State $state) -ne "configuration") {
        throw "RESET_DEV_BRANCH_EXTENSION_UNSUPPORTED: only configuration branches are supported."
    }

    $resetStatus = [string](Get-StateValue -State $state -Name "resetStatus" -Default "")
    if ($resetStatus -ne "resetting") {
        if ((Get-DevBranchInitializationStatus -State $state) -ne "ready") {
            throw "RESET_DEV_BRANCH_NOT_READY: the branch must be ready before reset."
        }
        if (Resume-DevBranchLifecycleMergeIfPresent -State $state -Operation "reset-dev-branch" -ConflictStage "reset.merge-conflicts") { return }
        Save-DevBranchCheckpoint -Operation "reset-dev-branch" -Message "chore: checkpoint before branch reset" | Out-Null
        $masterSource = Get-DevBranchResetMasterSource
        Assert-BranchSeedReady -ExpectedConfigurationFingerprint ([string]$masterSource.fingerprint) | Out-Null
        $oldHead = Get-CurrentCommit
        $archivePath = Join-Path (Join-Path (Get-DevBranchArchiveRoot) ([string]$state.safeDevBranchName)) ("{0}-{1}" -f ((Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssfffZ")), $oldHead.Substring(0, 8))
        Update-DevBranchState -State $state -Updates @{
            resetStatus = "resetting"; resetPhase = "archive-pending"; resetStartedAt = (Get-Date).ToString("o")
            resetOldHead = $oldHead; resetMasterCommit = [string]$masterSource.commit; resetMasterTree = [string]$masterSource.tree
            resetMasterFingerprint = [string]$masterSource.fingerprint
            resetMasterConfigTreeObjectId = [string]$masterSource.configTreeObjectId
            resetArchivePath = (Assert-PathUnderDevBranchArchiveRoot -Path $archivePath); resetArchiveDtPath = ""; resetNewHead = ""
        }
        $state = Read-DevBranchState -Name $DevBranchName
    }

    $masterCommit = [string](Get-StateValue -State $state -Name "resetMasterCommit" -Default "")
    if (-not (Test-GitCommitExists $masterCommit)) {
        throw "RESET_DEV_BRANCH_MASTER_COMMIT_MISSING: $masterCommit"
    }
    $phase = [string](Get-StateValue -State $state -Name "resetPhase" -Default "archive-pending")
    if ($phase -eq "archive-pending") {
        $archive = New-DevBranchResetArchive -State $state -MasterCommit $masterCommit -OldHead ([string]$state.resetOldHead) -ArchivePath ([string]$state.resetArchivePath)
        Update-DevBranchState -State $state -Updates @{ resetPhase = "archive-complete"; resetArchiveDtPath = [string]$archive.dtPath; resetArchiveManifestPath = [string]$archive.manifestPath }
        $state = Read-DevBranchState -Name $DevBranchName
        $phase = "archive-complete"
    }
    if ($phase -eq "archive-complete") {
        Set-RunStage -Stage "reset.git" -Detail "Replacing the branch tree with the exact local master tree."
        $currentHeadTree = (Get-GitOutput @("rev-parse", "HEAD^{tree}")).Trim()
        if ($currentHeadTree -ceq [string]$state.resetMasterTree) {
            Assert-CleanGit
            $newHead = Get-CurrentCommit
        } else {
            $newHead = Set-DevBranchTreeToMasterCommit -MasterCommit $masterCommit
        }
        Update-DevBranchState -State $state -Updates @{ resetPhase = "git-reset-complete"; resetNewHead = $newHead }
        $state = Read-DevBranchState -Name $DevBranchName
        $phase = "git-reset-complete"
    }
    if ($phase -in @("git-reset-complete", "runtime-initializing")) {
        Stop-DevBranchRuntimeBeforeInfobaseMutation -State $state -Reason "reset-dev-branch"
        Set-RunStage -Stage "reset.infobase" -Detail "Restoring the development infobase from the exact compatible branch seed."
        $runtimeRestore = Restore-ExistingDevBranchRuntimeFromSeed -State $state -ExpectedConfigurationFingerprint ([string]$state.resetMasterFingerprint)
        $seed = $runtimeRestore.seed
        $now = (Get-Date).ToString("o")
        $clear = @{
            initializationStatus = "ready"; initializationError = ""; resetStatus = "resetting"; resetPhase = "runtime-initializing"
            repositoryUnbound = [bool]$runtimeRestore.repositoryUnbound
            lastConfigDesignerFingerprint = [string]$seed.configurationFingerprint; lastConfigDesignerTreeObjectId = [string]$state.resetMasterConfigTreeObjectId
            lastConfigDesignerLoadedAt = $now; configLoadStatus = "passed"; sourceFingerprint = [string]$seed.configurationFingerprint
            loadReason = "branch-reset-seed"; lastConfigBaseUpdatedCommit = $masterCommit; lastRefreshMasterCommit = $masterCommit
            lastVerificationStatus = ""; lastVerificationReason = ""; lastVerificationFingerprint = ""; lastVerifiedFingerprint = ""
            lastVerifiedAt = ""; lastVerifiedCommit = ""; lastVerifiedReportPath = ""; lastVerificationLogPath = ""
            lastResultPath = ""; lastResultKind = ""; lastResultManifestPath = ""; lastResultAt = ""
            lastUnverifiedOverrideAt = ""; lastUnverifiedOverrideOperation = ""; lastUnverifiedResultPath = ""
            pendingMergeOperation = ""; pendingMergeTargetCommit = ""; pendingMergePhase = ""; pendingMergeStartedAt = ""
            branchSeedSourceKey = [string]$seed.sourceKey; branchSeedSyncId = [string]$seed.syncId
            branchSeedArtifactKind = [string]$seed.artifactKind; branchSeedConfigurationFingerprint = [string]$seed.configurationFingerprint
            branchSeedBaselinePath = [string]$seed.baselinePath; branchSeedBaselineHash = [string]$seed.baselineHash; branchSeedBaselineCount = [int]$seed.baselineCount
            enterpriseNormalizationStatus = "pending"; enterpriseNormalizationReason = "branch-reset"; enterpriseNormalizationError = ""
        }
        Add-DevBranchResetTransientStateClearUpdates -State $state -Updates $clear
        Update-DevBranchState -State $state -Updates $clear
        $state = Read-DevBranchState -Name $DevBranchName
        $state = Initialize-DevBranchEventLogBaseline -State $state -SeedBaselinePath ([string]$seed.baselinePath)
        Ensure-DevBranchEventLogPendingCursor -State $state -Reason "branch-reset" | Out-Null
        Ensure-DevBranchEnterpriseNormalized -State (Read-DevBranchState -Name $DevBranchName) -Reason "branch-reset" | Out-Null
        $state = Read-DevBranchState -Name $DevBranchName
        Sync-AiRules1cManagedIgnoredFilesFromMain -State $state | Out-Null
        $state = Invoke-DevBranchDefaultMcpSetup -State $state
        Sync-KiloItlCommandSurface
        Invoke-AiRules1cManagedMcpConfigReconcile -Operation "reset-dev-branch MCP reconcile" | Out-Null
        Sync-DevBranchContextToDotEnv -State $state
        $repairStatePath = Join-Path $script:ProjectRoot ".agent-1c\verification-repair\current.json"
        Remove-Item -LiteralPath $repairStatePath -Force -ErrorAction SilentlyContinue
        Update-DevBranchState -State (Read-DevBranchState -Name $DevBranchName) -Updates @{ resetStatus = "complete"; resetPhase = "complete"; resetCompletedAt = (Get-Date).ToString("o") }
    }

    $completed = Read-DevBranchState -Name $DevBranchName
    $report = [System.Collections.Generic.List[string]]::new()
    $report.Add("## Ветка сброшена для новой доработки")
    Add-RunUserReportLine -Lines $report -Label "Архив" -Value ([string]$completed.resetArchivePath)
    Add-RunUserReportLine -Lines $report -Label "DT" -Value ([string]$completed.resetArchiveDtPath)
    Add-RunUserReportLine -Lines $report -Label "Предыдущий HEAD" -Value ([string]$completed.resetOldHead)
    Add-RunUserReportLine -Lines $report -Label "Новый HEAD" -Value ([string]$completed.resetNewHead)
    Add-RunUserReportLine -Lines $report -Label "Коммит master" -Value ([string]$completed.resetMasterCommit)
    Add-RunUserReportLine -Lines $report -Label "База ветки" -Value ([string]$completed.devBranchInfoBasePath)
    $report.Add("")
    $report.Add("Архив не отслеживается Git. Если он больше не нужен, освободите место вручную по указанному полному пути.")
    Write-AndSetRunUserReport -Lines $report
}

function Invoke-RefreshDevBranchCore {
    param(
        [switch]$SynchronizeMaster,
        [string]$OperationName
    )

    $state = Read-DevBranchState -Name $DevBranchName
    Assert-DevelopmentBranchWorktreeContext -State $state -Operation $OperationName
    Assert-DevBranchExtensionInitialized -State $state -Operation $OperationName
    Sync-DevBranchContextToDotEnv -State $state -AllowIncompleteExtension

    if ($LifecyclePhase -ne "post-merge") {
        if (Resume-DevBranchLifecycleMergeIfPresent -State $state -Operation $OperationName -ConflictStage "refresh.merge-conflicts") {
            return
        }
        Save-DevBranchCheckpoint -Operation $OperationName | Out-Null
        Assert-CleanGit
        if ($SynchronizeMaster) {
            Set-RunStage -Stage "refresh.master" -Detail "Synchronizing master and ensuring a compatible branch seed."
            Sync-Master -SeedPolicy "EnsureCompatible"
        }
        if ((Get-CurrentBranch) -ne $state.devBranch) {
            Invoke-Git @("checkout", $state.devBranch)
        }
        $masterRef = "refs/heads/$(Get-MasterBranch)"
        $targetMasterCommit = (Get-GitOutput @("rev-parse", $masterRef)).Trim()
        if ($targetMasterCommit -notmatch '^[a-f0-9]{40}$') {
            throw "REFRESH_MASTER_COMMIT_INVALID: $targetMasterCommit"
        }
        if ($ExpectedMasterCommit -and $targetMasterCommit -cne $ExpectedMasterCommit) {
            throw "REFRESH_MASTER_COMMIT_CHANGED: expected=$ExpectedMasterCommit actual=$targetMasterCommit"
        }
        Set-RunStage -Stage "refresh.merge" -Detail "Merging master into the development branch."
        Invoke-NewDevBranchLifecycleMerge `
            -State $state `
            -Operation $OperationName `
            -TargetCommit $targetMasterCommit `
            -ConflictStage "refresh.merge-conflicts"
    }

    $state = Read-DevBranchState -Name $DevBranchName
    $mergeTransaction = Assert-DevBranchLifecycleMergePostMerge -State $state -Operation $OperationName
    $targetMasterCommit = [string]$mergeTransaction.targetCommit
    if ($targetMasterCommit -notmatch '^[a-f0-9]{40}$') {
        throw "REFRESH_MASTER_COMMIT_MISSING: the exact master SHA was not preserved across the merge."
    }
    Sync-AiRules1cManagedIgnoredFilesFromMain -State $state | Out-Null
    Update-VerificationSuiteInventory -Reason "$OperationName post-merge" | Out-Null
    Install-VanessaAutomation
    Set-RunStage -Stage "refresh.load" -Detail "Updating the branch infobase after the merge."
    Sync-DevBranchContextToDotEnv -State $state -AllowIncompleteExtension
    $trackedKiloSnapshot = New-RefreshTrackedKiloConfigSnapshot
    try {
        $state = Invoke-DevBranchDefaultMcpSetup -State $state
        $loadResult = Load-ConfigFromFiles -InfoBasePath $state.devBranchInfoBasePath -InfoBaseKind $state.infoBaseKind -State $state -ExportPath (Get-ExportPath) -ContentKind "configuration" -Mode $ConfigLoadMode
        $updates = @{}
        Invoke-DevBranchEnterpriseAutoUpdateIfLoaded -State $state -LoadResult $loadResult -Updates $updates
        $updatedState = Invoke-DevBranchMcpRestartAfterInfobaseLoad -State (Read-DevBranchState -Name $DevBranchName) -LoadResult $loadResult -Reason "refresh-dev-branch"
        Sync-KiloItlCommandSurface
        Invoke-AiRules1cManagedMcpConfigReconcile -Operation "$OperationName MCP reconcile" | Out-Null
        Complete-RefreshConfigDumpInfoPostcondition `
            -LoadResult $loadResult `
            -ExportPath (Get-ExportPath) `
            -TrackedKiloSnapshot $trackedKiloSnapshot `
            -State $state `
            -Operation $OperationName
        Set-ItlOnDemandMcpSemanticReloadRequiredAction -Operation $OperationName | Out-Null

        $loadStateUpdates = New-LoadStateUpdates -LoadResult $loadResult -ContentKind "configuration"
        foreach ($entry in $loadStateUpdates.GetEnumerator()) {
            $updates[$entry.Key] = $entry.Value
        }
        $updates["lastRefreshAt"] = (Get-Date).ToString("o")
        $updates["lastRefreshMasterCommit"] = $targetMasterCommit
        $updates["lastRefreshMode"] = $(if ($SynchronizeMaster) { "full" } else { "lite" })
        Add-PendingDevBranchMergeClearUpdates -Updates $updates
        Add-VerificationStaleIfNeeded -State $state -Updates $updates -Reason "Development branch was refreshed from master." -CurrentCommit $loadResult.currentCommit
        Update-DevBranchState -State $state -Updates $updates
        $updatedState = Read-DevBranchState -Name $DevBranchName
        Write-Host "Development branch refreshed from exact master commit: $targetMasterCommit"
        Write-BaseUpdateResult -State $updatedState -LoadResult $loadResult -Label "Development branch configuration"
        if ((Get-DevBranchKind -State $state) -eq "extension") {
            Write-Host "Extension files were not loaded during refresh. Run update-dev-branch-base when you need to update the extension in the branch infobase."
        }
        Write-DevBranchRunUserReport -State $updatedState -AdvisoryRoot $script:ProjectRoot -Operation refreshed -LoadResult $loadResult
    } catch {
        Restore-RefreshTrackedKiloConfigSnapshot -Snapshot $trackedKiloSnapshot
        throw
    }
}

function Refresh-DevBranch {
    Invoke-RefreshDevBranchCore -SynchronizeMaster -OperationName "refresh-dev-branch"
}

function Refresh-DevBranchLite {
    Invoke-RefreshDevBranchCore -OperationName "refresh-dev-branch-lite"
}

function Get-ActiveReadyDevBranchTargets {
    $targets = @()
    $errors = @()
    $seenBranches = @{}
    foreach ($file in Get-DevBranchStateFiles) {
        try {
            $state = Read-DevBranchStateFile -Path $file.FullName
            if (Get-StateValue -State $state -Name "closedAt" -Default "") { continue }
            $branch = [string](Get-StateValue -State $state -Name "devBranch" -Default "")
            $worktreePath = [string](Get-StateValue -State $state -Name "worktreePath" -Default "")
            $status = Get-DevBranchInitializationStatus -State $state
            if (-not $branch -or $branch -notlike "itldev/*" -or -not $worktreePath -or $status -ne "ready") {
                $errors += "Invalid active branch state '$($file.FullName)': branch='$branch'; worktree='$worktreePath'; status='$status'."
                continue
            }
            $resolvedWorktree = Resolve-Agent1cFullPath -Path $worktreePath
            if (-not (Test-Path -LiteralPath $resolvedWorktree -PathType Container)) {
                $errors += "Active branch worktree is missing: $branch -> $resolvedWorktree"
                continue
            }
            if ($seenBranches.ContainsKey($branch)) {
                if ([string]$seenBranches[$branch] -cne $resolvedWorktree) {
                    $errors += "Active branch has conflicting state files: $branch -> $($seenBranches[$branch]); $resolvedWorktree"
                }
                continue
            }
            $seenBranches[$branch] = $resolvedWorktree
            $targets += [pscustomobject]@{
                name = [string](Get-StateValue -State $state -Name "devBranchName" -Default $branch.Substring("itldev/".Length))
                branch = $branch
                worktreePath = $resolvedWorktree
            }
        } catch {
            $errors += "Unreadable active branch state '$($file.FullName)': $($_.Exception.Message)"
        }
    }
    return [pscustomobject]@{ targets = @($targets | Sort-Object branch); errors = @($errors) }
}

function Start-RefreshAllBranchProcess {
    param(
        [Parameter(Mandatory = $true)][object]$Target,
        [Parameter(Mandatory = $true)][string]$MasterCommit,
        [Parameter(Mandatory = $true)][string]$OutputRoot
    )

    $runner = Join-Path $script:Agent1cScriptRoot "run-itl-command.ps1"
    if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) {
        throw "REFRESH_ALL_RUNNER_MISSING: $runner"
    }
    $safe = ConvertTo-SafeName ([string]$Target.name)
    $stdout = Join-Path $OutputRoot "$safe.stdout.json"
    $stderr = Join-Path $OutputRoot "$safe.stderr.log"
    $arguments = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $runner, "--",
        "-Action", "refresh-dev-branch-lite", "-ExpectedMasterCommit", $MasterCommit
    )
    $process = Start-Process -FilePath "powershell" `
        -ArgumentList (Join-NativeCommandLineArguments -Arguments $arguments) `
        -WorkingDirectory ([string]$Target.worktreePath) `
        -WindowStyle Hidden `
        -RedirectStandardOutput $stdout `
        -RedirectStandardError $stderr `
        -PassThru
    return [pscustomobject]@{ target = $Target; process = $process; stdout = $stdout; stderr = $stderr; startedAt = Get-Date }
}

function Refresh-AllDevBranches {
    Assert-MasterWorktreeContext -Operation "refresh-all-dev-branches"
    Assert-CleanGit
    Set-RunStage -Stage "refresh-all.master" -Detail "Synchronizing master once before refreshing active branches."
    Sync-Master -NoDelegate -SeedPolicy "Rebuild"
    $masterCommit = Get-CurrentCommit
    $inventory = Get-ActiveReadyDevBranchTargets
    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($error in @($inventory.errors)) {
        $results.Add([pscustomobject]@{ branch = "<state>"; status = "failed"; detail = [string]$error; userReport = "" }) | Out-Null
    }

    $runRoot = if ($RunStatusPath) { Split-Path -Parent (Resolve-RunFilePath -Path $RunStatusPath) } else { Join-Path $script:ProjectRoot ".agent-1c\runs" }
    $outputRoot = Join-Path $runRoot "refresh-all"
    New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
    $pending = [System.Collections.Generic.Queue[object]]::new()
    foreach ($target in @($inventory.targets)) { $pending.Enqueue($target) }
    $running = [System.Collections.Generic.List[object]]::new()

    while ($pending.Count -gt 0 -or $running.Count -gt 0) {
        while ($pending.Count -gt 0 -and $running.Count -lt $MaxParallelBranches) {
            $target = $pending.Dequeue()
            try {
                $running.Add((Start-RefreshAllBranchProcess -Target $target -MasterCommit $masterCommit -OutputRoot $outputRoot)) | Out-Null
            } catch {
                $results.Add([pscustomobject]@{ branch = [string]$target.branch; status = "failed"; detail = $_.Exception.Message; userReport = "" }) | Out-Null
            }
        }
        Set-RunStage -Stage "refresh-all.branches" -Detail ("master={0}; running={1}; pending={2}; complete={3}" -f $masterCommit, $running.Count, $pending.Count, $results.Count)
        foreach ($entry in @($running)) {
            $entry.process.Refresh()
            if (-not $entry.process.HasExited) { continue }
            # HasExited can become true before Start-Process finishes flushing
            # redirected streams. The parameterless wait completes that flush and
            # releases the file handles before the compact summary is read.
            $entry.process.WaitForExit()
            $stdoutText = if (Test-Path -LiteralPath $entry.stdout -PathType Leaf) { Read-Utf8Text -Path $entry.stdout } else { "" }
            $stderrText = if (Test-Path -LiteralPath $entry.stderr -PathType Leaf) { Read-Utf8Text -Path $entry.stderr } else { "" }
            $summary = $null
            try { if ($stdoutText) { $summary = $stdoutText | ConvertFrom-Json } } catch {}
            # The compact runner's terminal JSON is authoritative. Under parallel
            # Start-Process collection Windows PowerShell can expose a stale
            # non-zero ExitCode even after the owned runner validated and emitted
            # a terminal success. Missing or malformed JSON still fails closed.
            $succeeded = $null -ne $summary -and [string]$summary.status -eq "succeeded"
            $detail = if ($null -ne $summary -and $summary.error) { [string]$summary.error } elseif ($succeeded) { "" } else { ($stderrText.Trim() + " " + $stdoutText.Trim()).Trim() }
            $results.Add([pscustomobject]@{
                branch = [string]$entry.target.branch
                status = $(if ($succeeded) { "succeeded" } else { "failed" })
                detail = $detail
                userReport = $(if ($null -ne $summary) { [string]$summary.userReport } else { "" })
            }) | Out-Null
            [void]$running.Remove($entry)
        }
        if ($running.Count -gt 0) { Start-Sleep -Milliseconds 500 }
    }

    $report = [System.Collections.Generic.List[string]]::new()
    $report.Add("## Обновление всех веток")
    Add-RunUserReportLine -Lines $report -Label "Коммит master" -Value $masterCommit
    Add-RunUserReportLine -Lines $report -Label "Параллельность" -Value $MaxParallelBranches
    if ($results.Count -eq 0) {
        Add-RunUserReportLine -Lines $report -Label "Ветки" -Value "активных ready-веток нет"
    } else {
        $report.Add("")
        $report.Add("### Результаты")
        foreach ($result in @($results | Sort-Object branch)) {
            $suffix = if ($result.detail) { ": $($result.detail)" } else { "" }
            $report.Add("- $($result.branch): $($result.status)$suffix")
        }
    }
    Write-AndSetRunUserReport -Lines $report
    $failed = @($results | Where-Object status -ne "succeeded")
    if ($failed.Count -gt 0) {
        throw "REFRESH_ALL_BRANCH_FAILURE: $($failed.Count) branch operation(s) failed. See the aggregate user report."
    }
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
        lastExtensionDesignerTreeObjectId = $source.treeObjectId
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
    $snapshotCleanupFailure = $null
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
        $extensionUpdates["lastExtensionDesignerTreeObjectId"] = $extensionSource.treeObjectId
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
        if ($snapshotCreated -and $databaseRestored) {
            try {
                Remove-CompletedInfobaseSnapshot -SnapshotPath $snapshotPath
            } catch {
                $snapshotCleanupFailure = $_.Exception.Message
            }
        }
        if ($hadToolOverride) {
            $script:ExtensionLifecycleToolRootOverride = $previousToolOverride
        } else {
            Remove-Variable -Name ExtensionLifecycleToolRootOverride -Scope Script -ErrorAction SilentlyContinue
        }
    }

    if ($failure) {
        if ($rollbackFailure) {
            if ($databaseRestored) {
                throw "Release extension smoke failed: $failure Cleanup also failed: $rollbackFailure"
            }
            throw "Release extension smoke failed: $failure Rollback also failed: $rollbackFailure Snapshot retained: $snapshotPath"
        }
        if ($snapshotCleanupFailure) {
            throw "Release extension smoke failed and the disposable infobase was restored, but snapshot cleanup failed: $failure Cleanup: $snapshotCleanupFailure Snapshot retained: $snapshotPath"
        }
        throw "Release extension smoke failed and the disposable infobase was restored: $failure"
    }
    if ($rollbackFailure) {
        if ($databaseRestored) {
            throw "Release extension smoke passed but cleanup failed: $rollbackFailure"
        }
        throw "Release extension smoke passed but rollback failed: $rollbackFailure Snapshot retained: $snapshotPath"
    }
    if ($snapshotCleanupFailure) {
        throw "Release extension smoke passed but snapshot cleanup failed: $snapshotCleanupFailure Snapshot retained: $snapshotPath"
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
    Write-SourceRepositoryUpdateModeStatus
    Write-WorkflowPackageStatusLines
    Write-KiloClientSkillProvenanceStatusLines
    Write-AiRules1cStatusLines
    Write-ItlOnDemandMcpStatusLines
    Write-ItlClientMcpEnablementStatusLines
    Show-ItlUiToolsStatus
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
    Assert-ItlVerificationRepairScope -Trigger $trigger
    $state = Read-DevBranchState -Name $DevBranchName
    $checkExportPath = if ((Get-DevBranchKind -State $state) -eq "extension") { Assert-ExtensionFilesReady -State $state } else { Get-ExportPath }
    $dumpInfoSnapshot = New-ConfigDumpInfoLoadSnapshot -AbsoluteExportPath (Resolve-Agent1cFullPath -Path $checkExportPath)
    $repairAttemptConsumed = $false
    $repairVerificationPassed = $false
    try {
    Invoke-DevBranchVanessaRuntimeRelease -State $state -Reason "check-dev-branch preflight" | Out-Null
    Assert-VanessaVerificationPreflight -Trigger $trigger -ExplicitComponents $explicit
    $fullProofEligible = Test-ItlFullVerificationProofEligible -Trigger $trigger -ExplicitComponents $explicit
    if ($trigger -eq "repair") {
        Get-ItlMatchingVerificationRepairSession | Out-Null
        if ($fullProofEligible) {
            Use-ItlVerificationRepairAttempt
            $repairAttemptConsumed = $true
        }
    }
    $state = Ensure-DevBranchEventLogBaseline -State $state
    $eventLogCursor = Ensure-DevBranchEventLogPendingCursor -State $state -Reason "check-dev-branch"
    Update-DevBranchBase
    Restore-ConfigDumpInfoLoadSnapshot -Snapshot $dumpInfoSnapshot
    Invoke-ItlVerificationCycle `
        -Trigger $trigger `
        -ExplicitComponents $explicit `
        -EventLogCursorPath $eventLogCursor.path `
        -EventLogBoundaryAt $eventLogCursor.capturedAt `
        -EventLogCursorScope "lifecycle-pending"
    if ($trigger -eq "repair" -and $fullProofEligible) {
        $verifiedState = Read-DevBranchState -Name $DevBranchName
        $verification = Get-VerificationState -State $verifiedState
        $evidenceKind = [string](Get-StateValue -State $verifiedState -Name "lastVerificationEvidenceKind" -Default "")
        if ($verification.status -eq "passed" -and $evidenceKind -eq "full") {
            Complete-ItlVerificationRepairSession
            $repairVerificationPassed = $true
        }
    }
    } catch {
        if ($repairAttemptConsumed -and -not $repairVerificationPassed) {
            Complete-ItlVerificationRepairFailure
        }
        throw
    } finally {
        try { Restore-ConfigDumpInfoLoadSnapshot -Snapshot $dumpInfoSnapshot } finally { Remove-ConfigDumpInfoLoadSnapshot -Snapshot $dumpInfoSnapshot }
    }
}

function Check-DevBranch {
    $state = Read-DevBranchState -Name $DevBranchName
    Assert-DevelopmentBranchWorktreeContext -State $state -Operation "check-dev-branch"
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
    $restoreUpdates = @{
        lastConfigDesignerFingerprint = ""
        lastConfigDesignerTreeObjectId = ""
        lastConfigDesignerLoadedAt = ""
        lastExtensionDesignerFingerprint = ""
        lastExtensionDesignerTreeObjectId = ""
        lastExtensionDesignerLoadedAt = ""
        sourceFingerprint = ""
        loadReason = "release-e2e-restore-invalidated"
        vanessaMcpSafeModeProof = $null
        designerInvoked = $false
        enterpriseInvoked = $false
        enterpriseNormalizationStatus = "pending"
        enterpriseNormalizationReason = "release-e2e-restore"
        enterpriseNormalizationError = ""
    }
    if ($PreserveReleaseSnapshotApplicationProof) {
        foreach ($field in @(
            "lastConfigDesignerFingerprint",
            "lastConfigDesignerTreeObjectId",
            "lastConfigDesignerLoadedAt",
            "lastExtensionDesignerFingerprint",
            "lastExtensionDesignerTreeObjectId",
            "lastExtensionDesignerLoadedAt",
            "sourceFingerprint",
            "configLoadStatus",
            "loadReason",
            "enterpriseNormalizationStatus",
            "enterpriseNormalizedAt",
            "enterpriseNormalizationReason",
            "enterpriseNormalizationError"
        )) {
            $restoreUpdates[$field] = Get-StateValue -State $state -Name $field -Default ""
        }
    }
    Update-DevBranchState -State $state -Updates $restoreUpdates
    Sync-DevBranchContextToDotEnv -State (Read-DevBranchState -Name $DevBranchName) -AllowIncompleteExtension
    Write-Host "Release E2E snapshot restored: $snapshotPath"
}

function Verify-DevBranch {
    Check-DevBranch
}

function Export-DevBranchResult {
    $state = Read-DevBranchState -Name $DevBranchName
    Assert-DevelopmentBranchWorktreeContext -State $state -Operation "export-dev-branch-result"
    Assert-DevBranchExtensionInitialized -State $state -Operation "export-dev-branch-result"
    Assert-SingleManagedExtensionArtifact -State $state
    Repair-OneCSourceLineEndings | Out-Null
    Sync-DevBranchContextToDotEnv -State $state
    $initialVerification = Get-VerificationState -State $state
    $operationFingerprint = [string]$initialVerification.currentFingerprint
    if ([string]::IsNullOrWhiteSpace($operationFingerprint)) {
        throw "export-dev-branch-result could not calculate the current verification fingerprint."
    }
    Confirm-UnverifiedProceed -State $state -Operation "export-dev-branch-result" -VerificationState $initialVerification -Allow:$AllowUnverifiedResult -ProceedOnWarn | Out-Null

    $kind = Get-DevBranchKind -State $state
    $loadExportPath = if ($kind -eq "extension") { Assert-ExtensionFilesReady -State $state } else { Get-ExportPath }
    $repositoryTransferPlan = Get-ConfigRepositoryTransferPlan -ExportPath $loadExportPath
    $dumpInfoSnapshot = New-ConfigDumpInfoLoadSnapshot -AbsoluteExportPath (Resolve-Agent1cFullPath -Path $loadExportPath)
    try {
    if ($kind -eq "extension") {
        $extensionName = Require-DevBranchExtensionName -State $state
        $loadResult = Load-ConfigFromFiles -InfoBasePath $state.devBranchInfoBasePath -InfoBaseKind $state.infoBaseKind -State $state -ExportPath $loadExportPath -ContentKind "extension" -ExtensionName $extensionName -Mode $ConfigLoadMode
    } else {
        $loadResult = Load-ConfigFromFiles -InfoBasePath $state.devBranchInfoBasePath -InfoBaseKind $state.infoBaseKind -State $state -ExportPath $loadExportPath -ContentKind "configuration" -Mode $ConfigLoadMode
    }
    } finally {
        try { Restore-ConfigDumpInfoLoadSnapshot -Snapshot $dumpInfoSnapshot } finally { Remove-ConfigDumpInfoLoadSnapshot -Snapshot $dumpInfoSnapshot }
    }
    $devBranchCommit = Get-CurrentCommit
    $masterCommit = Get-GitCommitOrEmpty (Get-MasterBranch)
    $updates = New-LoadStateUpdates -LoadResult $loadResult -ContentKind $kind
    Invoke-DevBranchEnterpriseAutoUpdateIfLoaded -State $state -LoadResult $loadResult -Updates $updates
    Add-VerificationStaleIfNeeded -State $state -Updates $updates -Reason "Development branch base was updated before result export." -CurrentCommit $loadResult.currentCommit
    Update-DevBranchState -State $state -Updates $updates
    $state = Invoke-DevBranchMcpRestartAfterInfobaseLoad -State (Read-DevBranchState -Name $DevBranchName) -LoadResult $loadResult -Reason "result export base update"
    $state = Read-DevBranchState -Name $DevBranchName
    $verificationBeforeExport = Get-VerificationState -State $state
    if ([string]$verificationBeforeExport.currentFingerprint -cne $operationFingerprint) {
        throw "export-dev-branch-result stopped because source or Vanessa feature content changed during result preparation. Run /itl-check again."
    }
    $unverifiedOverride = Confirm-UnverifiedProceed -State $state -Operation "export-dev-branch-result" -VerificationState $verificationBeforeExport -Allow:$AllowUnverifiedResult -ProceedOnWarn
    $verificationDecision = if ($verificationBeforeExport.isFreshPassed) { "fresh-passed" } else { "warn-unverified" }

    Assert-DevBranchToolArtifactExportGuard -State $state -ContentKind $kind
    $resultPath = Export-DevBranchResultFile -State $state -InfoBasePath $state.devBranchInfoBasePath -InfoBaseKind $state.infoBaseKind -ContentKind $kind
    $resultPath = Resolve-Agent1cFullPath -Path $resultPath
    Assert-DevBranchToolArtifactExportGuard -State $state -ContentKind $kind -ResultPath $resultPath
    $verificationAfterExport = Get-VerificationState -State $state
    if ([string]$verificationAfterExport.currentFingerprint -cne $operationFingerprint) {
        throw "export-dev-branch-result stopped because source or Vanessa feature content changed during artifact export. Run /itl-check again."
    }
    if ($verificationDecision -eq "fresh-passed" -and -not $verificationAfterExport.isFreshPassed) {
        throw "export-dev-branch-result stopped because fresh passed Vanessa verification was lost during artifact export. Run /itl-check again."
    }

    $resultKind = $(if ($kind -eq "extension") { "cfe" } else { "cf" })
    $sourceFingerprint = $(if ($loadResult.PSObject.Properties.Match("sourceFingerprint").Count -gt 0) { [string]$loadResult.sourceFingerprint } else { "" })
    $worktreeClean = -not (Test-GitHasChanges)
    $verificationScopeCommitted = (@(Get-VerificationWorkingTreeChangePaths -PathSpec (Get-VerificationFingerprintScopePaths)).Count -eq 0)
    $manifestPath = New-ResultManifest `
        -State $state `
        -ResultPath $resultPath `
        -ResultKind $resultKind `
        -Operation "export-dev-branch-result" `
        -MasterCommit $masterCommit `
        -DevBranchCommit $devBranchCommit `
        -SourceFingerprint $sourceFingerprint `
        -VerificationFingerprint $operationFingerprint `
        -VerificationState $verificationAfterExport `
        -WorktreeClean ([bool]$worktreeClean) `
        -VerificationScopeCommitted ([bool]$verificationScopeCommitted) `
        -UnverifiedOverride ([bool]$unverifiedOverride) `
        -VerificationDecision $verificationDecision
    $manifestPath = Resolve-Agent1cFullPath -Path $manifestPath
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
    Set-RunResultArtifacts -ResultPath $resultPath -ResultManifestPath $manifestPath
    $reportLines = [System.Collections.Generic.List[string]]::new()
    $reportLines.Add("## Результат ветки")
    Add-RunUserReportLine -Lines $reportLines -Label "Файл" -Value $resultPath
    Add-RunUserReportLine -Lines $reportLines -Label "Манифест" -Value $manifestPath
    Add-RunUserReportLine -Lines $reportLines -Label "Ветка" -Value $state.devBranch
    Add-RunUserReportLine -Lines $reportLines -Label "Проверка" -Value $(if ($verificationDecision -eq "warn-unverified") { "ВНИМАНИЕ: fresh passed отсутствует; выгружено по политике warn" } else { "fresh passed" })
    Add-ConfigRepositoryTransferPlanRunUserReportLines -Lines $reportLines -Plan $repositoryTransferPlan
    Write-AndSetRunUserReport -Lines $reportLines
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
    Stop-ItlOnDemandBackends -Strict
    Stop-DevBranchRuntimeBeforeInfobaseMutation -State $state -Reason "close-dev-branch"
    $state = Read-DevBranchState -Name $DevBranchName
    Sync-DevBranchContextToDotEnv -State $state

    if ($LifecyclePhase -ne "post-merge") {
        if (Resume-DevBranchLifecycleMergeIfPresent -State $state -Operation "close-dev-branch" -ConflictStage "close.merge-conflicts") {
            return
        }
        Set-RunStage -Stage "close.master" -Detail "Synchronizing master before closing the development branch."
        Assert-CleanGit
        Sync-Master
        if ((Get-CurrentBranch) -ne $state.devBranch) {
            Invoke-Git @("checkout", $state.devBranch)
        }
        $masterRef = "refs/heads/$(Get-MasterBranch)"
        $targetMasterCommit = (Get-GitOutput @("rev-parse", $masterRef)).Trim()
        if ($targetMasterCommit -notmatch '^[a-f0-9]{40}$') {
            throw "CLOSE_MASTER_COMMIT_INVALID: $targetMasterCommit"
        }
        Set-RunStage -Stage "close.merge" -Detail "Merging master into the development branch before close."
        Invoke-NewDevBranchLifecycleMerge `
            -State $state `
            -Operation "close-dev-branch" `
            -TargetCommit $targetMasterCommit `
            -ConflictStage "close.merge-conflicts"
    }

    $state = Read-DevBranchState -Name $DevBranchName
    $mergeTransaction = Assert-DevBranchLifecycleMergePostMerge -State $state -Operation "close-dev-branch"
    $targetMasterCommit = [string]$mergeTransaction.targetCommit
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
    $masterCommit = $targetMasterCommit
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
    $updates["vanessaTestPort"] = 0
    $updates["vanessaTestPorts"] = @()
    $updates["vanessaTestPortLeaseToken"] = ""
    $updates["vanessaTestPortUpdatedAt"] = ""
    $updates["vanessaMcpPort"] = 0
    $updates["vanessaMcpPortLeaseToken"] = ""
    $updates["roctupMcpPort"] = 0
    $updates["roctupMcpPortLeaseToken"] = ""
    $updates["roctupMcpUrl"] = ""
    $updates["roctupMcpHealthUrl"] = ""
    $updates["finalResultPath"] = $resultPath
    $updates["finalResultKind"] = $resultKind
    $updates["finalResultManifestPath"] = $manifestPath
    $updates["lastLogPath"] = $script:LastLogPath
    if ($unverifiedOverride) {
        $updates["lastUnverifiedOverrideAt"] = (Get-Date).ToString("o")
        $updates["lastUnverifiedOverrideOperation"] = "close-dev-branch"
        $updates["lastUnverifiedResultPath"] = $resultPath
    }
    $stateWithPortLeases = $state
    Update-DevBranchState -State $state -Updates $updates
    Release-ItlManagedPortAllocationsForState -State $stateWithPortLeases

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

    $completedState = Read-DevBranchState -Name $DevBranchName
    $completionUpdates = @{}
    Add-PendingDevBranchMergeClearUpdates -Updates $completionUpdates
    Update-DevBranchState -State $completedState -Updates $completionUpdates
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
    Write-Section "Жизненный цикл ITL"
    Write-Host "Корень проекта: $script:ProjectRoot"

    $surface = Get-KiloItlCommandSurface
    $currentBranch = ""
    try {
        $currentBranch = Get-CurrentBranch
    } catch {
        $currentBranch = ""
    }
    Write-Host "Контекст: $surface"
    Write-Host "Ветка Git: $(if ($currentBranch) { $currentBranch } else { '<нет>' })"
    Write-Host "Долгие операции могут запускать Конфигуратор или Предприятие 1С; timeout_ms оболочки агента должен быть не меньше 3900000 и превышать настроенный тайм-аут Designer."

    if ($surface -eq "master") {
        Write-Host ""
        Write-Host "Жизненный цикл:"
        Write-Host "  master → создать ветку → открыть worktree → выполнить задачу → проверить → получить результат"
        Write-Host ""
        Write-Host "Команды ITL в этом контексте:"
        Write-ItlActiveClientCommandText "  /itl"
        Write-ItlActiveClientCommandText "  /itl-status"
        Write-ItlActiveClientCommandText "  /itl-new-config-branch <name>"
        Write-ItlActiveClientCommandText "  /itl-new-extension-branch <name>"
        Write-ItlActiveClientCommandText "  /itl-sync-master"
        Write-ItlActiveClientCommandText "  /itl-refresh-all"
        Write-ItlActiveClientCommandText "  /itl-update-workflow"
        Write-ItlActiveClientCommandText "  /itl-switch-client <client>"
        Write-ItlActiveClientCommandText "  /itl-repository-mode <workflow|external|status>"
        Write-ItlActiveClientCommandText "  /itl-litemode <mode>"
        Write-Host ""
        Write-Host "Активные worktree разработки:"
        $states = @(Get-WorkflowActiveDevBranchStates)
        if ($states.Count -eq 0) {
            Write-Host "  нет"
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
                    Write-Host "    Инициализация расширения: $(Get-DevBranchExtensionInitializationStatus -State $state)"
                }
                Write-Host "    Проверка Vanessa: $(Get-StateValue -State $state -Name 'lastVerificationStatus' -Default '<нет>')"
                Write-Host "    ROCTUP MCP: $(Get-StateValue -State $state -Name 'roctupMcpStatus' -Default 'on-demand')"
                Write-Host "    Vanessa UI MCP: $(Get-StateValue -State $state -Name 'vanessaMcpStatus' -Default 'on-demand')"
            }
        }
        Write-Host ""
        Write-Host "Следующий шаг: создайте ветку конфигурации или расширения и откройте показанную папку worktree."
    } elseif ($surface -eq "dev") {
        $openSpec = Get-AiRules1cOpenSpecStatus
        $state = $null
        try {
            $state = Read-DevBranchState -Name ""
        } catch {
            Write-Host "Состояние ветки разработки: отсутствует"
            Write-Host ""
            Write-ItlActiveClientCommandText "Рекомендуемый шаг: выполните /itl-status и откройте сохранённый worktree этой ветки, если он существует."
        }

        if ($state) {
            $verification = Get-VerificationState -State $state
            $kind = Get-DevBranchKind -State $state
            $extensionInitializationStatus = Get-DevBranchExtensionInitializationStatus -State $state
            $hasCheckableChanges = Test-DevBranchHasCheckableChanges -State $state
            Write-Host ""
            Write-Host "Ветка:"
            Write-Host "  Имя: $(Get-StateValue -State $state -Name 'devBranchName' -Default (Get-StateValue -State $state -Name 'safeDevBranchName' -Default '<неизвестно>'))"
            Write-Host "  Тип: $kind"
            if ($kind -eq "extension") {
                Write-Host "  Инициализация расширения: $extensionInitializationStatus"
            }
            Write-Host "  Информационная база: $($state.devBranchInfoBasePath)"
            $publicationUrl = Get-StateValue -State $state -Name "publicationUrl" -Default ""
            if ($publicationUrl) {
                Write-Host "  URL публикации: $publicationUrl"
            }
            $mainWorktreePath = Get-StateValue -State $state -Name "mainWorktreePath" -Default ""
            if ($mainWorktreePath) {
                Write-Host "  Worktree master: $mainWorktreePath"
            }
            Write-Host ""
            Write-Host "Проверка:"
            Write-Host "  Статус: $($verification.effectiveStatus)"
            Write-Host "  Fresh passed: $($verification.isFreshPassed)"
            Write-Host "  Есть проверяемые изменения: $hasCheckableChanges"
            if ($verification.reportPath) {
                Write-Host "  Отчёт: $($verification.reportPath)"
            }
            Write-Host "  Последний результат: $(Get-StateValue -State $state -Name 'lastResultPath' -Default '<нет>')"
            Write-Host "  Финальный результат: $(Get-StateValue -State $state -Name 'finalResultPath' -Default '<нет>')"
            Write-Host ""
            if ($kind -eq "extension" -and $extensionInitializationStatus -ne "ready") {
                Write-Host "Рекомендуемый шаг: сообщите агенту, нужно создать пустое расширение или загрузить CFE; укажите имя расширения и путь к CFE, если он нужен."
            } elseif ($hasCheckableChanges -or (@("failed", "stale", "unknown") -contains $verification.effectiveStatus)) {
                Write-ItlActiveClientCommandText "Рекомендуемый шаг: /itl-check"
            } elseif (-not $verification.isFreshPassed) {
                if ($openSpec.mode -eq "native") {
                    Write-Host "Рекомендуемый шаг: независимо выберите execution path quick-fix или full-cycle и planning mode direct или OpenSpec. По умолчанию используйте direct; выбирайте $($openSpec.invocations.explore) или $($openSpec.invocations.propose), только если полезно формальное исследование или согласование."
                } elseif ($openSpec.mode -eq "natural") {
                    Write-Host "Рекомендуемый шаг: независимо выберите execution path quick-fix или full-cycle и planning mode direct или OpenSpec. По умолчанию используйте direct; запросите natural OpenSpec explore/propose, только если полезно формальное исследование или согласование."
                } else {
                    Write-Host "Рекомендуемый шаг: выберите execution path quick-fix или full-cycle; planning mode временно ограничен direct. Восстанавливайте workspace и правила OpenSpec только для формального исследования или согласования."
                }
            } elseif (-not (Get-StateValue -State $state -Name "lastResultPath" -Default "")) {
                Write-ItlActiveClientCommandText "Рекомендуемый шаг: /itl-result"
            } else {
                Write-ItlActiveClientCommandText "Рекомендуемый шаг: продолжите работу и повторите /itl-check либо снова выполните /itl-result, когда понадобится артефакт."
            }
        }

        Write-Host ""
        Write-Host "Жизненный цикл:"
        if ($openSpec.mode -eq "native") {
            Write-ItlActiveClientCommandText "  настройка расширения при pending → quick-fix или direct full-cycle → /itl-check → /itl-result; OpenSpec explore/propose/apply/archive используется при необходимости."
        } elseif ($openSpec.mode -eq "natural") {
            Write-ItlActiveClientCommandText "  настройка расширения при pending → quick-fix или direct full-cycle → /itl-check → /itl-result; natural OpenSpec explore/propose/apply/archive используется при необходимости."
        } else {
            Write-ItlActiveClientCommandText "  настройка расширения при pending → quick-fix или direct full-cycle → /itl-check → /itl-result; восстанавливайте OpenSpec только для формального исследования или согласования."
        }
        Write-ItlActiveClientCommandText "  используйте /itl-refresh для полного source → master → branch цикла; для параллельных веток сначала один /itl-sync-master, затем /itl-refresh-lite в каждой ветке."
        Write-Host ""
        Write-Host "Команды ITL в этом контексте:"
        Write-ItlActiveClientCommandText "  /itl"
        Write-ItlActiveClientCommandText "  /itl-status"
        Write-ItlActiveClientCommandText "  /itl-check"
        Write-ItlActiveClientCommandText "  /itl-verify-fix"
        Write-ItlActiveClientCommandText "  /itl-sync-master"
        Write-ItlActiveClientCommandText "  /itl-refresh"
        Write-ItlActiveClientCommandText "  /itl-refresh-lite"
        Write-ItlActiveClientCommandText "  /itl-fork-branch <name>"
        Write-ItlActiveClientCommandText "  /itl-reset-branch"
        Write-ItlActiveClientCommandText "  /itl-lock-objects"
        Write-ItlActiveClientCommandText "  /itl-result"
        Write-ItlActiveClientCommandText "  /itl-update-workflow"
        Write-ItlActiveClientCommandText "  /itl-litemode <mode>"
        $inheritedPrimaryCommands = @()
        try {
            if ((Get-ItlActiveClient) -eq "kilocode") { $inheritedPrimaryCommands = @(Get-KiloInheritedPrimaryItlCommands) }
        } catch {
            $inheritedPrimaryCommands = @()
        }
        if ($inheritedPrimaryCommands.Count -gt 0) {
            Write-Host ""
            Write-Host "Унаследовано Kilo из основного checkout, но недоступно в этом контексте:"
            foreach ($command in $inheritedPrimaryCommands) {
                Write-Host "  $command"
            }
        }
        Write-Host ""
        Write-Host "OpenSpec:"
        $naturalRequests = Get-ItlOpenSpecNaturalRequests
        Write-Host "  Режим: $($openSpec.mode)"
        Write-Host "  Внешний CLI: $(if ($openSpec.cliAvailable) { $openSpec.cliPath } else { 'не найден; установка не выполняется' })"
        if ($openSpec.mode -eq "native") {
            Write-Host "  $($openSpec.invocations.propose)  Создать proposal/design/tasks/test-plan/spec deltas без изменения кода."
            Write-Host "  $($openSpec.invocations.apply)  Реализовать согласованное изменение по tasks.md и test-plan.md."
            Write-Host "  $($openSpec.invocations.archive)  Архивировать принятое изменение."
            Write-Host "  $($openSpec.invocations.explore)  Исследовать задачу без proposal и изменения кода."
            if (-not $openSpec.cliAvailable) {
                Write-Host "  Если native prompt не может вызвать CLI, используйте запросы ниже; не запускайте npm install или openspec update."
                Write-Host "  Исследование: $($naturalRequests.explore)"
                Write-Host "  Предложение: $($naturalRequests.propose)"
                Write-Host "  Реализация: $($naturalRequests.apply)"
                Write-Host "  Архивация: $($naturalRequests.archive)"
            }
        } elseif ($openSpec.mode -eq "natural") {
            Write-Host "  Исследование: $($naturalRequests.explore)"
            Write-Host "  Предложение: $($naturalRequests.propose)"
            Write-Host "  Реализация: $($naturalRequests.apply)"
            Write-Host "  Архивация: $($naturalRequests.archive)"
            Write-Host "  Native bundle не требуется; не запускайте npm install или openspec update."
        } else {
            Write-Host "  OpenSpec недоступен: $($openSpec.reason)"
            Write-ItlActiveClientCommandText "  Восстановление: в master выполните update-ai-rules или update-workflow, перенесите обновление в ветку и запустите /itl-refresh."
        }
        Write-ItlActiveClientCommandText "  используйте /itl-verify-fix только для исправления пропущенного покрытия или неуспешного цикла проверки."
    } else {
        Write-Host ""
        Write-Host "Жизненный цикл:"
        Write-Host "  Откройте worktree master для создания веток либо worktree itldev/* для разработки, проверки и получения результата."
        Write-Host ""
        Write-Host "Команды ITL в этом контексте:"
        Write-ItlActiveClientCommandText "  /itl"
        Write-ItlActiveClientCommandText "  /itl-status"
        Write-Host ""
        Write-ItlActiveClientCommandText "Следующий шаг: выполните /itl-status для проверки папки, затем откройте правильный worktree."
    }

    Write-ItlAdditionalHelperActions
}
