function Write-Section {
    param([string]$Text)
    Write-Host ""
    Write-Host "== $Text =="
}

function Get-Utf8Encoding {
    return New-Object System.Text.UTF8Encoding $false
}

function Get-Utf8BomEncoding {
    return New-Object System.Text.UTF8Encoding $true
}

function Read-Utf8Text {
    param([string]$Path)
    return [System.IO.File]::ReadAllText($Path, (Get-Utf8Encoding))
}

function Read-Utf8Lines {
    param([string]$Path)
    return [System.IO.File]::ReadAllLines($Path, (Get-Utf8Encoding))
}

function Write-Utf8Text {
    param(
        [string]$Path,
        [string]$Value
    )
    $directory = Split-Path -Parent $Path
    if ($directory) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $Value, (Get-Utf8Encoding))
}

function Add-Utf8Text {
    param(
        [string]$Path,
        [string]$Value
    )
    $directory = Split-Path -Parent $Path
    if ($directory) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }
    [System.IO.File]::AppendAllText($Path, $Value, (Get-Utf8Encoding))
}

function New-TimestampedFilePath {
    param(
        [string]$Directory,
        [string]$Prefix,
        [string]$Extension
    )

    $suffix = [guid]::NewGuid().ToString("N").Substring(0, 8)
    $name = "{0}{1}-{2}-{3}{4}" -f $Prefix, (Get-Date -Format "yyyyMMdd-HHmmss-fff"), $PID, $suffix, $Extension
    return Join-Path $Directory $name
}

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

function Test-Agent1cWritableDirectory {
    param([AllowNull()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    $resolved = Resolve-Agent1cFullPath -Path $Path
    if (-not (Test-Path -LiteralPath $resolved -PathType Container -ErrorAction SilentlyContinue)) {
        return $false
    }

    $probePath = Join-Path $resolved (".itl-temp-probe-" + [guid]::NewGuid().ToString("N") + ".tmp")
    try {
        $stream = [System.IO.File]::Open($probePath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $stream.Dispose()
        return $true
    } catch {
        return $false
    } finally {
        Remove-Item -LiteralPath $probePath -Force -ErrorAction SilentlyContinue
    }
}

function Get-Agent1cTempRoot {
    $userTemp = ""
    $userTmp = ""
    try {
        $userTemp = [Environment]::GetEnvironmentVariable("TEMP", [EnvironmentVariableTarget]::User)
        $userTmp = [Environment]::GetEnvironmentVariable("TMP", [EnvironmentVariableTarget]::User)
    } catch {
    }

    $localAppData = [string]$env:LOCALAPPDATA
    if ([string]::IsNullOrWhiteSpace($localAppData)) {
        try {
            $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
        } catch {
        }
    }

    $candidates = @(
        [string]$env:TEMP,
        [string]$env:TMP,
        [string]$userTemp,
        [string]$userTmp,
        $(if ([string]::IsNullOrWhiteSpace($localAppData)) { "" } else { Join-Path $localAppData "Temp" }),
        $(if ([string]::IsNullOrWhiteSpace([string]$env:USERPROFILE)) { "" } else { Join-Path ([string]$env:USERPROFILE) "AppData\Local\Temp" })
    )

    foreach ($candidate in $candidates) {
        if (Test-Agent1cWritableDirectory -Path $candidate) {
            return (Resolve-Agent1cFullPath -Path $candidate)
        }
    }

    $fallback = Resolve-Agent1cFullPath -Path (Join-Path $script:ProjectRoot ".agent-1c\tmp")
    try {
        New-Item -ItemType Directory -Force -Path $fallback -ErrorAction Stop | Out-Null
    } catch {
        throw "Could not create the project-local temporary directory: $fallback"
    }
    if (-not (Test-Agent1cWritableDirectory -Path $fallback)) {
        throw "No writable temporary directory is available. Checked TEMP, TMP, user profile, and project-local fallback '$fallback'."
    }
    return $fallback
}

function Resolve-RunFilePath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return (Resolve-Agent1cFullPath -Path $Path)
    }
    return (Resolve-Agent1cFullPath -Path (Join-Path $script:ProjectRoot $Path))
}

function Write-RunStatus {
    param(
        [ValidateSet("running", "succeeded", "failed")]
        [string]$Status,
        [object]$ExitCode = $null,
        [string]$ErrorMessage = ""
    )

    if ([string]::IsNullOrWhiteSpace($RunStatusPath)) {
        return
    }
    if ($Status -eq "succeeded" -and $Action -eq "init-project") {
        if ($script:RunStage -ne "init.complete" -or $null -eq $ExitCode -or [int]$ExitCode -ne 0) {
            throw "init-project success status requires stage init.complete and exitCode 0."
        }
    }

    $script:ResolvedRunStatusPath = Resolve-RunFilePath -Path $RunStatusPath
    if ($RunLogPath) {
        $script:ResolvedRunLogPath = Resolve-RunFilePath -Path $RunLogPath
    }

    $now = Get-Date
    $finishedAt = $null
    if ($Status -ne "running") {
        $finishedAt = $now.ToString("o")
    }

    $payload = [ordered]@{
        schemaVersion = 1
        status = $Status
        action = $Action
        projectRoot = $script:ProjectRoot
        pid = $PID
        launcherPid = $script:LauncherPid
        startedAt = $script:RunStartedAt.ToString("o")
        updatedAt = $now.ToString("o")
        finishedAt = $finishedAt
        exitCode = $ExitCode
        lastLogPath = $(if ($script:LastLogPath) { [string]$script:LastLogPath } else { "" })
        runLogPath = $script:ResolvedRunLogPath
        errorMessage = $ErrorMessage
        stage = $(if ($script:RunStage) { [string]$script:RunStage } else { "" })
        stageDetail = $(if ($script:RunStageDetail) { [string]$script:RunStageDetail } else { "" })
        lastProcessId = $script:LastProcessId
        lastProcessTimedOut = $script:LastProcessTimedOut
        gitIndexLockPreExisted = [bool]$script:GitIndexLockPreExisted
        resumedFrom = $script:ResumedFrom
        recoveryReason = $script:RecoveryReason
    }

    Write-Utf8Text -Path $script:ResolvedRunStatusPath -Value (($payload | ConvertTo-Json -Depth 5) + [Environment]::NewLine)
}

function Set-RunStage {
    param(
        [string]$Stage,
        [string]$Detail = ""
    )

    $script:RunStage = $Stage
    $script:RunStageDetail = $Detail
    if (-not [string]::IsNullOrWhiteSpace($RunStatusPath)) {
        Write-RunStatus -Status "running"
    }
    Update-Agent1cLifecycleOperationStage -Stage $Stage -Detail $Detail
}

function Test-Agent1cActionRequiresLifecycleLock {
    param([string]$RequestedAction)

    $readOnlyActions = @(
        "help",
        "status",
        "list-dev-branches",
        "validate",
        "check-tools",
        "list-platforms",
        "detect-web-publication",
        "detect-apache",
        "vanessa-mcp-status",
        "roctup-mcp-status",
        "vibecoding1c-mcp-status"
    )
    return -not ($readOnlyActions -contains $RequestedAction)
}

function Get-Agent1cLifecycleLockPath {
    param([string]$WorktreePath)
    return (Join-Path (Resolve-Agent1cFullPath -Path $WorktreePath) ".agent-1c\locks\lifecycle.lock")
}

function Get-Agent1cLifecycleOperationStatePath {
    param([string]$WorktreePath)
    return (Join-Path (Resolve-Agent1cFullPath -Path $WorktreePath) ".agent-1c\locks\lifecycle-operation.json")
}

function Ensure-Agent1cLifecycleLocksIgnored {
    param([string]$WorktreePath)

    $resolvedWorktree = Resolve-Agent1cFullPath -Path $WorktreePath
    if (-not (Test-Path -LiteralPath (Join-Path $resolvedWorktree ".git") -ErrorAction SilentlyContinue)) {
        return
    }

    $commonGitDirectoryText = ""
    try {
        $commonGitDirectoryText = ([string](Get-GitOutputAt -Root $resolvedWorktree -Arguments @("rev-parse", "--git-common-dir"))).Trim()
    } catch {
        return
    }
    if ([string]::IsNullOrWhiteSpace($commonGitDirectoryText)) {
        return
    }

    $commonGitDirectory = if ([System.IO.Path]::IsPathRooted($commonGitDirectoryText)) {
        Resolve-Agent1cFullPath -Path $commonGitDirectoryText
    } else {
        Resolve-Agent1cFullPath -Path (Join-Path $resolvedWorktree $commonGitDirectoryText)
    }
    $excludePath = Join-Path $commonGitDirectory "info\exclude"
    $ignoreLine = ".agent-1c/locks/"
    if (Test-Path -LiteralPath $excludePath -PathType Leaf -ErrorAction SilentlyContinue) {
        $hasRule = [bool](Read-Utf8Lines -Path $excludePath | Where-Object { ([string]$_).Trim() -eq $ignoreLine } | Select-Object -First 1)
        if ($hasRule) {
            return
        }
    }
    Add-Utf8Text -Path $excludePath -Value ($ignoreLine + [Environment]::NewLine)
}

function Read-Agent1cLifecycleOperationRecord {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    try {
        return (ConvertTo-Agent1cHashtable -Object ((Read-Utf8Text -Path $Path) | ConvertFrom-Json))
    } catch {
        return $null
    }
}

function Write-Agent1cLifecycleOperationRecord {
    param(
        [string]$Path,
        [System.Collections.IDictionary]$Record
    )

    Write-Utf8Text -Path $Path -Value (($Record | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
}

function Get-Agent1cLifecycleOperationLockScopes {
    param([string]$RequestedAction)

    $candidatePaths = @($script:ProjectRoot)
    if ($RequestedAction -in @("refresh-dev-branch", "close-dev-branch", "sync-master")) {
        $candidatePaths += Get-MainWorktreePath
    }

    $seen = @{}
    $scopes = @()
    foreach ($candidatePath in $candidatePaths) {
        $resolved = Resolve-Agent1cFullPath -Path $candidatePath
        $key = $resolved.ToLowerInvariant()
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $scopes += $resolved
        }
    }
    return @($scopes | Sort-Object { $_.ToLowerInvariant() })
}

function Test-Agent1cProcessAlive {
    param([int]$ProcessId)

    if ($ProcessId -le 0) {
        return $false
    }
    return $null -ne (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)
}

function Test-Agent1cLifecycleLockHeld {
    param([string]$WorktreePath)

    $lockPath = Get-Agent1cLifecycleLockPath -WorktreePath $WorktreePath
    $directory = Split-Path -Parent $lockPath
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $probe = $null
    try {
        $probe = [System.IO.File]::Open(
            $lockPath,
            [System.IO.FileMode]::OpenOrCreate,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::Read
        )
        return $false
    } catch [System.IO.IOException] {
        return $true
    } finally {
        if ($null -ne $probe) {
            $probe.Dispose()
        }
    }
}

function Get-Agent1cLifecycleConflictRecord {
    param([string]$WorktreePath)

    $statePath = Get-Agent1cLifecycleOperationStatePath -WorktreePath $WorktreePath
    $record = Read-Agent1cLifecycleOperationRecord -Path $statePath
    if ($null -ne $record -and $record.Contains("ownerStatePath") -and -not [string]::IsNullOrWhiteSpace([string]$record["ownerStatePath"])) {
        $ownerStatePath = Resolve-Agent1cFullPath -Path ([string]$record["ownerStatePath"])
        $ownerRecord = Read-Agent1cLifecycleOperationRecord -Path $ownerStatePath
        if ($null -ne $ownerRecord -and [string]$ownerRecord["operationId"] -ceq [string]$record["operationId"]) {
            return [pscustomobject]@{ record = $ownerRecord; statePath = $ownerStatePath }
        }
    }
    return [pscustomobject]@{ record = $record; statePath = $statePath }
}

function New-Agent1cLifecycleConflictMessage {
    param(
        [string]$RequestedAction,
        [string]$WorktreePath
    )

    $conflict = Get-Agent1cLifecycleConflictRecord -WorktreePath $WorktreePath
    $record = $conflict.record
    $activeAction = if ($null -ne $record -and $record.Contains("action")) { [string]$record["action"] } else { "<unknown>" }
    $branch = if ($null -ne $record -and $record.Contains("branch")) { [string]$record["branch"] } else { "<unknown>" }
    $ownerPid = if ($null -ne $record -and $record.Contains("pid")) { [string]$record["pid"] } elseif ($null -ne $record -and $record.Contains("ownerPid")) { [string]$record["ownerPid"] } else { "<unknown>" }
    $phase = if ($null -ne $record -and $record.Contains("phase")) { [string]$record["phase"] } else { "<unknown>" }
    $startedAt = if ($null -ne $record -and $record.Contains("startedAt")) { [string]$record["startedAt"] } else { "<unknown>" }
    return "LIFECYCLE_OPERATION_CONFLICT requestedAction='$RequestedAction' activeAction='$activeAction' worktree='$WorktreePath' branch='$branch' pid='$ownerPid' phase='$phase' startedAt='$startedAt' statePath='$($conflict.statePath)'"
}

function Assert-Agent1cLifecycleContinuationOwner {
    if (-not $script:LifecycleOperationIsContinuation -or $null -eq $script:LifecycleOperationRecord) {
        return
    }
    if (-not (Test-Agent1cProcessAlive -ProcessId $script:LifecycleOperationOwnerPid)) {
        throw "LIFECYCLE_OPERATION_CONTINUATION_INVALID reason='owner process is not running' operationId='$($script:LifecycleOperationId)' ownerPid='$($script:LifecycleOperationOwnerPid)'"
    }
    foreach ($scope in @($script:LifecycleOperationRecord["lockScopes"])) {
        if (-not (Test-Agent1cLifecycleLockHeld -WorktreePath ([string]$scope))) {
            throw "LIFECYCLE_OPERATION_CONTINUATION_INVALID reason='owner lock is not held' operationId='$($script:LifecycleOperationId)' ownerPid='$($script:LifecycleOperationOwnerPid)' worktree='$scope'"
        }
    }
}

function Enter-Agent1cLifecycleOperation {
    param(
        [string]$RequestedAction,
        [string]$RequestedOperationId = "",
        [int]$RequestedOwnerPid = 0,
        [switch]$Continuation
    )

    if (-not (Test-Agent1cActionRequiresLifecycleLock -RequestedAction $RequestedAction)) {
        if ($Continuation) {
            throw "LIFECYCLE_OPERATION_CONTINUATION_INVALID reason='read-only action cannot continue a mutating operation' action='$RequestedAction'"
        }
        return
    }

    $primaryStatePath = Get-Agent1cLifecycleOperationStatePath -WorktreePath $script:ProjectRoot
    if ($Continuation) {
        $record = Read-Agent1cLifecycleOperationRecord -Path $primaryStatePath
        if ($null -eq $record -or
            [string]::IsNullOrWhiteSpace($RequestedOperationId) -or
            [string]$record["operationId"] -cne $RequestedOperationId -or
            [string]$record["action"] -cne $RequestedAction -or
            [string]$record["status"] -cne "running" -or
            [int]$record["pid"] -ne $RequestedOwnerPid -or
            (Resolve-Agent1cFullPath -Path ([string]$record["projectRoot"])) -cne $script:ProjectRoot) {
            throw "LIFECYCLE_OPERATION_CONTINUATION_INVALID reason='operation record does not match' action='$RequestedAction' operationId='$RequestedOperationId' ownerPid='$RequestedOwnerPid' statePath='$primaryStatePath'"
        }

        $script:LifecycleOperationRecord = $record
        $script:LifecycleOperationStatePath = $primaryStatePath
        $script:LifecycleOperationId = $RequestedOperationId
        $script:LifecycleOperationOwnerPid = $RequestedOwnerPid
        $script:LifecycleOperationIsContinuation = $true
        Assert-Agent1cLifecycleContinuationOwner
        $record["continuationPid"] = $PID
        $record["updatedAt"] = (Get-Date).ToString("o")
        $record["phase"] = "continuation"
        $record["detail"] = "Fresh helper process continued the active operation."
        Write-Agent1cLifecycleOperationRecord -Path $primaryStatePath -Record $record
        return
    }

    if (-not [string]::IsNullOrWhiteSpace($RequestedOperationId) -or $RequestedOwnerPid -gt 0) {
        throw "LIFECYCLE_OPERATION_CONTINUATION_INVALID reason='continuation arguments require OperationContinuation' action='$RequestedAction' operationId='$RequestedOperationId' ownerPid='$RequestedOwnerPid'"
    }

    $scopes = @(Get-Agent1cLifecycleOperationLockScopes -RequestedAction $RequestedAction)
    $handles = @()
    try {
        foreach ($scope in $scopes) {
            Ensure-Agent1cLifecycleLocksIgnored -WorktreePath $scope
            $lockPath = Get-Agent1cLifecycleLockPath -WorktreePath $scope
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $lockPath) | Out-Null
            try {
                $stream = [System.IO.File]::Open(
                    $lockPath,
                    [System.IO.FileMode]::OpenOrCreate,
                    [System.IO.FileAccess]::ReadWrite,
                    [System.IO.FileShare]::Read
                )
            } catch [System.IO.IOException] {
                throw (New-Agent1cLifecycleConflictMessage -RequestedAction $RequestedAction -WorktreePath $scope)
            }
            $handles += [pscustomobject]@{ worktreePath = $scope; lockPath = $lockPath; stream = $stream }
        }
    } catch {
        for ($index = $handles.Count - 1; $index -ge 0; $index--) {
            $handles[$index].stream.Dispose()
        }
        throw
    }

    $now = (Get-Date).ToString("o")
    $branch = ""
    if (Test-Path -LiteralPath (Join-Path $script:ProjectRoot ".git") -ErrorAction SilentlyContinue) {
        try { $branch = Get-CurrentBranch } catch { $branch = "" }
    }
    $operationIdValue = [guid]::NewGuid().ToString("N")
    $record = [ordered]@{
        schemaVersion = 1
        status = "running"
        operationId = $operationIdValue
        action = $RequestedAction
        projectRoot = $script:ProjectRoot
        worktreePath = $script:ProjectRoot
        branch = $branch
        lockScopes = @($scopes)
        pid = $PID
        launcherPid = $script:LauncherPid
        continuationPid = 0
        startedAt = $now
        updatedAt = $now
        finishedAt = $null
        phase = "acquired"
        detail = "Lifecycle operation locks acquired."
        lastProcessId = 0
        lastLogPath = ""
        exitCode = $null
        errorCode = ""
        errorMessage = ""
    }

    $script:LifecycleOperationHandles = @($handles)
    $script:LifecycleOperationRecord = $record
    $script:LifecycleOperationStatePath = $primaryStatePath
    $script:LifecycleOperationId = $operationIdValue
    $script:LifecycleOperationOwnerPid = $PID
    Write-Agent1cLifecycleOperationRecord -Path $primaryStatePath -Record $record
    foreach ($scope in $scopes) {
        if ($scope -ceq $script:ProjectRoot) {
            continue
        }
        $holder = [ordered]@{
            schemaVersion = 1
            status = "running"
            role = "holder"
            operationId = $operationIdValue
            action = $RequestedAction
            projectRoot = $script:ProjectRoot
            worktreePath = $scope
            branch = $branch
            lockScopes = @($scopes)
            ownerPid = $PID
            ownerStatePath = $primaryStatePath
            startedAt = $now
            updatedAt = $now
            finishedAt = $null
            phase = "acquired"
            detail = "Secondary lifecycle operation lock held."
        }
        Write-Agent1cLifecycleOperationRecord -Path (Get-Agent1cLifecycleOperationStatePath -WorktreePath $scope) -Record $holder
    }
}

function Update-Agent1cLifecycleOperationStage {
    param(
        [string]$Stage,
        [string]$Detail = ""
    )

    if ($null -eq $script:LifecycleOperationRecord -or [string]::IsNullOrWhiteSpace($script:LifecycleOperationStatePath)) {
        return
    }
    Assert-Agent1cLifecycleContinuationOwner
    $record = Read-Agent1cLifecycleOperationRecord -Path $script:LifecycleOperationStatePath
    if ($null -eq $record -or [string]$record["operationId"] -cne $script:LifecycleOperationId) {
        throw "LIFECYCLE_OPERATION_CONTINUATION_INVALID reason='operation record disappeared or changed' operationId='$($script:LifecycleOperationId)' statePath='$($script:LifecycleOperationStatePath)'"
    }
    $record["phase"] = $Stage
    $record["detail"] = $Detail
    $record["updatedAt"] = (Get-Date).ToString("o")
    $record["lastProcessId"] = $script:LastProcessId
    $record["lastLogPath"] = $(if ($script:LastLogPath) { [string]$script:LastLogPath } else { "" })
    if ($script:LifecycleOperationIsContinuation) {
        $record["continuationPid"] = $PID
    }
    $script:LifecycleOperationRecord = $record
    Write-Agent1cLifecycleOperationRecord -Path $script:LifecycleOperationStatePath -Record $record
}

function Complete-Agent1cLifecycleOperation {
    param(
        [ValidateSet("succeeded", "failed")]
        [string]$Status,
        [int]$ExitCode,
        [string]$ErrorMessage = ""
    )

    if ($script:LifecycleOperationTerminalWrittenByContinuation -or
        $null -eq $script:LifecycleOperationRecord -or
        [string]::IsNullOrWhiteSpace($script:LifecycleOperationStatePath)) {
        return
    }
    $record = Read-Agent1cLifecycleOperationRecord -Path $script:LifecycleOperationStatePath
    if ($null -eq $record -or [string]$record["operationId"] -cne $script:LifecycleOperationId) {
        return
    }
    $now = (Get-Date).ToString("o")
    $record["status"] = $Status
    $record["updatedAt"] = $now
    $record["finishedAt"] = $now
    $record["phase"] = $(if ($Status -eq "succeeded") { "complete" } else { "failed" })
    $record["detail"] = $(if ($Status -eq "succeeded") { "Lifecycle operation completed." } else { $ErrorMessage })
    $record["lastProcessId"] = $script:LastProcessId
    $record["lastLogPath"] = $(if ($script:LastLogPath) { [string]$script:LastLogPath } else { "" })
    $record["exitCode"] = $ExitCode
    $record["errorCode"] = $(if ($Status -eq "failed") { "LIFECYCLE_OPERATION_FAILED" } else { "" })
    $record["errorMessage"] = $ErrorMessage
    if ($script:LifecycleOperationIsContinuation) {
        $record["continuationPid"] = $PID
    }
    $script:LifecycleOperationRecord = $record
    Write-Agent1cLifecycleOperationRecord -Path $script:LifecycleOperationStatePath -Record $record

    foreach ($scope in @($record["lockScopes"])) {
        $scopePath = Resolve-Agent1cFullPath -Path ([string]$scope)
        if ($scopePath -ceq $script:ProjectRoot) {
            continue
        }
        $holderPath = Get-Agent1cLifecycleOperationStatePath -WorktreePath $scopePath
        $holder = Read-Agent1cLifecycleOperationRecord -Path $holderPath
        if ($null -ne $holder -and [string]$holder["operationId"] -ceq $script:LifecycleOperationId) {
            $holder["status"] = $Status
            $holder["updatedAt"] = $now
            $holder["finishedAt"] = $now
            $holder["phase"] = $record["phase"]
            $holder["detail"] = $record["detail"]
            Write-Agent1cLifecycleOperationRecord -Path $holderPath -Record $holder
        }
    }
}

function Exit-Agent1cLifecycleOperation {
    for ($index = $script:LifecycleOperationHandles.Count - 1; $index -ge 0; $index--) {
        try { $script:LifecycleOperationHandles[$index].stream.Dispose() } catch {}
    }
    $script:LifecycleOperationHandles = @()
}

function Write-Agent1cLifecycleOperationStatusLines {
    $statePath = Get-Agent1cLifecycleOperationStatePath -WorktreePath $script:ProjectRoot
    $record = Read-Agent1cLifecycleOperationRecord -Path $statePath
    if ($null -eq $record) {
        Write-Host "Lifecycle operation: none"
        return
    }
    if ($record.Contains("ownerStatePath") -and -not [string]::IsNullOrWhiteSpace([string]$record["ownerStatePath"])) {
        $ownerStatePath = Resolve-Agent1cFullPath -Path ([string]$record["ownerStatePath"])
        $ownerRecord = Read-Agent1cLifecycleOperationRecord -Path $ownerStatePath
        if ($null -ne $ownerRecord -and [string]$ownerRecord["operationId"] -ceq [string]$record["operationId"]) {
            $record = $ownerRecord
            $statePath = $ownerStatePath
        }
    }
    $status = [string]$record["status"]
    if ($status -eq "running") {
        $activeScope = if ($record.Contains("worktreePath")) { [string]$record["worktreePath"] } else { $script:ProjectRoot }
        if (-not (Test-Agent1cLifecycleLockHeld -WorktreePath $activeScope)) {
            $status = "orphaned"
        }
    }
    $activeAction = if ($record.Contains("action")) { [string]$record["action"] } else { "<unknown>" }
    $ownerPid = if ($record.Contains("pid")) { [string]$record["pid"] } elseif ($record.Contains("ownerPid")) { [string]$record["ownerPid"] } else { "<unknown>" }
    $phase = if ($record.Contains("phase")) { [string]$record["phase"] } else { "<unknown>" }
    Write-Host "Lifecycle operation: $status (action=$activeAction, pid=$ownerPid, phase=$phase)"
    Write-Host "Lifecycle operation state: $statePath"
}

function Import-DotEnv {
    param(
        [string]$Path,
        [switch]$Overwrite
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    foreach ($line in Read-Utf8Lines -Path $Path) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith("#")) {
            continue
        }
        $idx = $trimmed.IndexOf("=")
        if ($idx -lt 1) {
            continue
        }

        $name = $trimmed.Substring(0, $idx).Trim()
        $value = $trimmed.Substring($idx + 1).Trim()
        if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
            $value = $value.Substring(1, $value.Length - 2)
        }

        if ($Overwrite -or -not [Environment]::GetEnvironmentVariable($name, "Process")) {
            [Environment]::SetEnvironmentVariable($name, $value, "Process")
        }
    }
}

function Read-ProjectConfig {
    if (Test-Path -LiteralPath $script:ConfigPath) {
        $script:Config = Read-Utf8Text -Path $script:ConfigPath | ConvertFrom-Json
    } else {
        $script:Config = [pscustomobject]@{}
    }
}

function Get-ConfigValue {
    param(
        [string]$Path,
        [object]$Default = $null
    )

    $node = $script:Config
    foreach ($part in $Path.Split(".")) {
        if ($null -eq $node) {
            return $Default
        }

        $prop = $node.PSObject.Properties[$part]
        if ($null -eq $prop) {
            return $Default
        }

        $node = $prop.Value
    }

    if ($null -eq $node) {
        return $Default
    }
    if ($node -is [string] -and $node -eq "") {
        return $Default
    }

    return $node
}

function Get-EnvValue {
    param(
        [string]$Name,
        [object]$Default = $null
    )

    $value = [Environment]::GetEnvironmentVariable($Name, "Process")
    if ($value) {
        return $value
    }

    $prefixedName = "AGENT_1C_$Name"
    $value = [Environment]::GetEnvironmentVariable($prefixedName, "Process")
    if ($value) {
        return $value
    }

    return $Default
}

function Get-Setting {
    param(
        [string]$EnvName,
        [string]$ConfigName,
        [object]$Default = $null
    )

    $value = Get-EnvValue -Name $EnvName
    if ($value) {
        return $value
    }

    return Get-ConfigValue -Path $ConfigName -Default $Default
}

function ConvertTo-BoolSetting {
    param(
        [AllowNull()][object]$Value,
        [bool]$Default = $false
    )

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $Default
    }

    if ($Value -is [bool]) {
        return [bool]$Value
    }

    $text = ([string]$Value).Trim().ToLowerInvariant()
    $yesMarker = -join ([char[]](0x0434, 0x0430))
    $noMarker = -join ([char[]](0x043D, 0x0435, 0x0442))
    if (@("1", "true", "yes", "y", "on", $yesMarker) -contains $text) {
        return $true
    }
    if (@("0", "false", "no", "n", "off", $noMarker) -contains $text) {
        return $false
    }

    throw "Invalid boolean setting value: $Value"
}

function ConvertTo-DependencyMode {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return "fresh"
    }

    $text = ([string]$Value).Trim().ToLowerInvariant()
    if ($text -eq "fresh" -or $text -eq "latest") {
        return "fresh"
    }
    if ($text -eq "locked" -or $text -eq "pinned") {
        return "locked"
    }

    throw "Invalid dependency mode: $Value. Use fresh or locked."
}

function ConvertTo-BaseConfigurationVersion {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return "PM5"
    }

    $text = ([string]$Value).Trim().ToUpperInvariant()
    if ($text -eq "PM4" -or $text -eq "PM5") {
        return $text
    }

    throw "Invalid base configuration version: $Value. Use PM4 or PM5."
}

function ConvertTo-Agent1cHashtable {
    param([AllowNull()][object]$Object)

    $hash = [ordered]@{}
    if ($null -eq $Object) {
        return $hash
    }
    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($key in $Object.Keys) {
            $hash[$key] = $Object[$key]
        }
        return $hash
    }
    foreach ($property in $Object.PSObject.Properties) {
        $hash[$property.Name] = $property.Value
    }
    return $hash
}

function Require-Value {
    param(
        [string]$Name,
        [object]$Value
    )

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        throw "Required value is missing: $Name"
    }

    return $Value
}

function Resolve-ProjectPath {
    param([string]$Path)
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return (Resolve-Agent1cFullPath -Path $Path)
    }
    return (Resolve-Agent1cFullPath -Path (Join-Path $script:ProjectRoot $Path))
}

function Set-ProjectContext {
    param([string]$Root)

    $resolvedRoot = Resolve-Agent1cFullPath -Path $Root
    $script:ProjectRoot = $resolvedRoot
    $script:ConfigPath = Resolve-Agent1cFullPath -Path (Join-Path $resolvedRoot ".agent-1c\project.json")
    $script:DependencyLockPath = Join-Path $resolvedRoot ".agent-1c\dependency-lock.json"
    Import-DotEnv -Path (Join-Path $resolvedRoot ".dev.env") -Overwrite
    Read-ProjectConfig
}

function Invoke-InProjectContext {
    param(
        [string]$Root,
        [scriptblock]$ScriptBlock
    )

    $previousRoot = $script:ProjectRoot
    $previousConfigPath = $script:ConfigPath
    $previousDependencyLockPath = $script:DependencyLockPath
    $previousConfig = $script:Config
    try {
        Set-ProjectContext -Root $Root
        & $ScriptBlock
    } finally {
        $script:ProjectRoot = $previousRoot
        $script:ConfigPath = $previousConfigPath
        $script:DependencyLockPath = $previousDependencyLockPath
        $script:Config = $previousConfig
        Import-DotEnv -Path (Join-Path $script:ProjectRoot ".dev.env") -Overwrite
    }
}

function Test-DirectoryExists {
    param([string]$Path)
    if (-not $Path) {
        return $false
    }

    try {
        return [System.IO.Directory]::Exists($Path)
    } catch {
        return $false
    }
}

function Get-ChildDirectoriesSafe {
    param([string]$Path)
    if (-not (Test-DirectoryExists -Path $Path)) {
        return @()
    }

    try {
        return @(Get-ChildItem -LiteralPath $Path -Directory -ErrorAction Stop)
    } catch {
        return @()
    }
}

function Resolve-InfoBasePath {
    param([string]$Path)
    if (-not $Path) {
        return $Path
    }
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return (Resolve-Agent1cFullPath -Path $Path)
    }
    return Resolve-ProjectPath $Path
}

function ConvertTo-SafeName {
    param([string]$Name)
    $safe = ($Name.Trim() -replace "[^a-zA-Z0-9_.-]+", "-").Trim("-").ToLowerInvariant()
    if (-not $safe) {
        $safe = "dev-branch-" + (Get-Date -Format "yyyyMMdd-HHmmss")
    }
    return $safe
}

function Get-GitIndexLockPath {
    param([string]$Root = $script:ProjectRoot)

    $gitPath = Join-Path $Root ".git"
    if (Test-Path -LiteralPath $gitPath -PathType Leaf -ErrorAction SilentlyContinue) {
        try {
            $firstLine = [System.IO.File]::ReadLines($gitPath) | Select-Object -First 1
            if ($firstLine -match '^gitdir:\s*(.+)$') {
                $gitDir = $matches[1].Trim()
                if (-not [System.IO.Path]::IsPathRooted($gitDir)) {
                    $gitDir = Resolve-Agent1cFullPath -Path (Join-Path $Root $gitDir)
                }
                return (Join-Path $gitDir "index.lock")
            }
        } catch {
        }
    }

    return (Join-Path $gitPath "index.lock")
}

function Initialize-GitIndexLockTracking {
    $script:GitIndexLockPath = Get-GitIndexLockPath
    $script:GitIndexLockPreExisted = Test-Path -LiteralPath $script:GitIndexLockPath -PathType Leaf -ErrorAction SilentlyContinue
}

function Test-GitProcessRunning {
    return [bool](Get-Process -Name "git" -ErrorAction SilentlyContinue | Select-Object -First 1)
}

function Invoke-GitIndexLockCleanupOnFailure {
    $lockPath = if ($script:GitIndexLockPath) { $script:GitIndexLockPath } else { Get-GitIndexLockPath }
    if (-not $lockPath -or -not (Test-Path -LiteralPath $lockPath -PathType Leaf -ErrorAction SilentlyContinue)) {
        return ""
    }

    if ($script:GitIndexLockPreExisted) {
        return "Git index lock was present before this helper run and was left in place: $lockPath. Close active Git processes and remove it manually only if it is stale."
    }

    if (Test-GitProcessRunning) {
        return "Git index lock remains because git.exe is still running: $lockPath. Wait for Git to finish, then remove it manually only if it is stale."
    }

    try {
        Remove-Item -LiteralPath $lockPath -Force -ErrorAction Stop
        return "Removed Git index lock created during this failed helper run: $lockPath"
    } catch {
        return "Git index lock cleanup failed for '$lockPath': $($_.Exception.Message). Close active Git processes and remove it manually only if it is stale."
    }
}

function Test-GitIndexLockErrorOutput {
    param([string[]]$Output = @())

    foreach ($line in @($Output)) {
        if ([string]$line -match '(?i)(index\.lock|Unable to create.*lock file)') {
            return $true
        }
    }

    return $false
}

function Get-GitIndexLockRecoveryHint {
    param([string]$Root = $script:ProjectRoot)

    $lockPath = Get-GitIndexLockPath -Root $Root
    return "Git index lock blocks this command: $lockPath. Close active Git processes and remove it manually only if it is stale."
}

function Invoke-GitCommand {
    param(
        [string]$Root,
        [string[]]$Arguments,
        [switch]$PassThru
    )

    $resolvedRoot = Resolve-Agent1cFullPath -Path $Root
    $gitArgs = @("-C", $resolvedRoot) + @($Arguments)
    $exitCode = 1
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $rawOutput = & git @gitArgs 2>&1
        if ($LASTEXITCODE -is [int]) {
            $exitCode = $LASTEXITCODE
        }
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    $standardOutput = @()
    $errorOutput = @()
    $displayOutput = @()
    foreach ($item in @($rawOutput)) {
        if ($null -eq $item) {
            continue
        }

        $text = [string]$item
        $displayOutput += $text
        if (-not ($item -is [System.Management.Automation.ErrorRecord])) {
            $standardOutput += $text
        } else {
            $errorOutput += $text
        }
    }

    $outputToLog = if ($exitCode -ne 0 -or (-not $PassThru)) { $displayOutput } else { $errorOutput }
    if ($exitCode -eq 0) {
        $outputToLog = @($outputToLog | Where-Object { -not (Test-GitBenignSuccessfulOutputLine -Line ([string]$_)) })
    }
    foreach ($line in $outputToLog) {
        if ($line) {
            Write-Host $line
        }
    }

    if ($exitCode -ne 0) {
        $message = "Git failed: git -C `"$resolvedRoot`" $($Arguments -join ' ')"
        if (Test-GitIndexLockErrorOutput -Output $displayOutput) {
            $message = "$message. $(Get-GitIndexLockRecoveryHint -Root $resolvedRoot)"
        }
        throw $message
    }

    if ($PassThru) {
        return $standardOutput
    }
}

function Test-GitBenignSuccessfulOutputLine {
    param([string]$Line)

    if (-not $Line) {
        return $false
    }

    return ($Line -match "LF will be replaced by CRLF" -or $Line -match "CRLF will be replaced by LF")
}

function Invoke-Git {
    param([string[]]$Arguments)
    Invoke-GitCommand -Root $script:ProjectRoot -Arguments $Arguments
}

function Invoke-GitAt {
    param(
        [string]$Root,
        [string[]]$Arguments
    )

    Invoke-GitCommand -Root $Root -Arguments $Arguments
}

function Get-GitOutput {
    param([string[]]$Arguments)
    return (Invoke-GitCommand -Root $script:ProjectRoot -Arguments $Arguments -PassThru)
}

function Get-GitOutputAt {
    param(
        [string]$Root,
        [string[]]$Arguments
    )

    return (Invoke-GitCommand -Root $Root -Arguments $Arguments -PassThru)
}

function Get-CurrentBranch {
    return (Get-GitOutput @("branch", "--show-current")).Trim()
}

function Get-CurrentCommit {
    return (Get-GitOutput @("rev-parse", "HEAD")).Trim()
}

function Test-GitCommitExists {
    param([string]$Commit)
    if (-not $Commit) {
        return $false
    }

    & git -C $script:ProjectRoot cat-file -e "$Commit^{commit}" *> $null
    return ($LASTEXITCODE -eq 0)
}

function Test-GitHasAnyCommit {
    & git -C $script:ProjectRoot rev-parse --verify --quiet HEAD *> $null
    return ($LASTEXITCODE -eq 0)
}

function Test-GitBranchExists {
    param([string]$Branch)

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & git -C $script:ProjectRoot show-ref --verify --quiet "refs/heads/$Branch"
        return ($LASTEXITCODE -eq 0)
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

function Get-GitHeadBranch {
    $branch = & git -C $script:ProjectRoot symbolic-ref --quiet --short HEAD 2>$null
    if ($LASTEXITCODE -eq 0 -and $branch) {
        return ([string]$branch).Trim()
    }
    return ""
}

function Set-GitHeadBranch {
    param([string]$Branch)
    & git -C $script:ProjectRoot symbolic-ref HEAD "refs/heads/$Branch"
    if ($LASTEXITCODE -ne 0) {
        throw "Git failed: git -C `"$script:ProjectRoot`" symbolic-ref HEAD refs/heads/$Branch"
    }
}

function Test-GitHasRemote {
    $remote = & git -C $script:ProjectRoot remote
    if ($LASTEXITCODE -ne 0) {
        return $false
    }
    return [bool]($remote | Select-Object -First 1)
}

function Test-GitHasUpstream {
    & git -C $script:ProjectRoot rev-parse --abbrev-ref --symbolic-full-name "@{u}" *> $null
    return ($LASTEXITCODE -eq 0)
}

function Test-IgnorableLocalGitStatusLine {
    param([string]$Line)

    if (-not $Line -or -not $Line.StartsWith("?? ")) {
        return $false
    }

    $path = $Line.Substring(3).Trim()
    $normalizedPath = $path -replace "\\", "/"
    if ($normalizedPath -eq ".kilo/kilo.json" -or $normalizedPath -eq ".kilo/kilo.jsonc" -or $normalizedPath -eq ".codex/config.toml") {
        return $true
    }

    if ($normalizedPath -eq ".agent-1c/mcp/" -or $normalizedPath -eq ".agent-1c/locks/") {
        return $true
    }

    if ($normalizedPath -eq ".kilo/" -or $normalizedPath -eq ".codex/") {
        $localDirName = $(if ($normalizedPath -eq ".kilo/") { ".kilo" } else { ".codex" })
        $allowedFiles = $(if ($normalizedPath -eq ".kilo/") { @(".kilo/kilo.json", ".kilo/kilo.jsonc") } else { @(".codex/config.toml") })
        $localDir = Join-Path $script:ProjectRoot $localDirName
        if (-not (Test-Path -LiteralPath $localDir -PathType Container -ErrorAction SilentlyContinue)) {
            return $false
        }

        $files = @(Get-ChildItem -LiteralPath $localDir -Recurse -File -Force -ErrorAction SilentlyContinue)
        if ($files.Count -lt 1) {
            return $false
        }

        $rootPath = [System.IO.Path]::GetFullPath($script:ProjectRoot).TrimEnd("\", "/") + "\"
        foreach ($file in $files) {
            $filePath = [System.IO.Path]::GetFullPath($file.FullName)
            if (-not $filePath.StartsWith($rootPath, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $false
            }

            $relativePath = $filePath.Substring($rootPath.Length) -replace "\\", "/"
            if ($allowedFiles -notcontains $relativePath) {
                return $false
            }
        }

        return $true
    }

    return $false
}

function Test-GitHasChanges {
    $status = & git -C $script:ProjectRoot status --porcelain
    if ($LASTEXITCODE -ne 0) {
        throw "Cannot read Git status"
    }
    return [bool]((Get-EffectiveGitStatusLines -StatusLines $status) | Select-Object -First 1)
}

function Get-EffectiveGitStatusLines {
    param([string[]]$StatusLines = @())

    return @($StatusLines | Where-Object {
        $line = [string]$_
        $line -and -not (Test-IgnorableLocalGitStatusLine -Line $line)
    })
}

function Assert-CleanGit {
    $status = & git -C $script:ProjectRoot status --porcelain
    if ($LASTEXITCODE -ne 0) {
        throw "Cannot read Git status"
    }
    $effectiveStatus = @(Get-EffectiveGitStatusLines -StatusLines $status)
    if ($effectiveStatus.Count -gt 0) {
        throw "Git worktree is not clean. Commit, stash, or discard changes before this action. Remaining Git status: $($effectiveStatus -join '; ')"
    }
}

function Get-FullPathNormalized {
    param([string]$Path)

    return (Resolve-Agent1cFullPath -Path $Path)
}

function Get-GitWorktrees {
    $output = & git -C $script:ProjectRoot worktree list --porcelain
    if ($LASTEXITCODE -ne 0) {
        return @()
    }

    $items = @()
    $current = $null
    foreach ($line in @($output)) {
        if (-not $line) {
            if ($null -ne $current) {
                $items += [pscustomobject]$current
                $current = $null
            }
            continue
        }

        if ($line -like "worktree *") {
            if ($null -ne $current) {
                $items += [pscustomobject]$current
            }
            $current = [ordered]@{
                path = $line.Substring("worktree ".Length)
                head = ""
                branch = ""
                bare = $false
                detached = $false
            }
            continue
        }

        if ($null -eq $current) {
            continue
        }

        if ($line -like "HEAD *") {
            $current.head = $line.Substring("HEAD ".Length)
        } elseif ($line -like "branch *") {
            $branch = $line.Substring("branch ".Length)
            $current.branch = ($branch -replace "^refs/heads/", "")
        } elseif ($line -eq "bare") {
            $current.bare = $true
        } elseif ($line -eq "detached") {
            $current.detached = $true
        }
    }

    if ($null -ne $current) {
        $items += [pscustomobject]$current
    }
    return @($items)
}

function Find-GitWorktreeByBranch {
    param([string]$Branch)

    foreach ($worktree in Get-GitWorktrees) {
        if ($worktree.branch -eq $Branch) {
            return $worktree
        }
    }
    return $null
}

function Get-MainWorktreePath {
    $worktrees = @(Get-GitWorktrees)
    if ($worktrees.Count -gt 0) {
        return [System.IO.Path]::GetFullPath($worktrees[0].path)
    }
    return $script:ProjectRoot
}

function Ensure-GitRepository {
    if (-not (Test-Path -LiteralPath (Join-Path $script:ProjectRoot ".git"))) {
        Invoke-Git @("init")
    }
}

function Get-MasterBranch {
    return "master"
}

function Get-ExportPath {
    return "src/cf"
}

function Get-ExtensionsPath {
    return (Get-ConfigValue -Path "extensionsPath" -Default "src/cfe")
}

function Checkout-Master {
    $masterBranch = Get-MasterBranch
    Ensure-GitRepository

    if (-not (Test-GitHasAnyCommit)) {
        $currentBranch = Get-GitHeadBranch
        if ($currentBranch -ne $masterBranch) {
            Set-GitHeadBranch -Branch $masterBranch
        }
        Write-Host "Using empty Git repository on branch: $masterBranch"
        return
    }

    & git -C $script:ProjectRoot rev-parse --verify --quiet $masterBranch *> $null
    if ($LASTEXITCODE -eq 0) {
        Invoke-Git @("checkout", $masterBranch)
    } else {
        Invoke-Git @("checkout", "-b", $masterBranch)
    }

    if ((Test-GitHasRemote) -and (Test-GitHasUpstream)) {
        Invoke-Git @("pull", "--ff-only")
    }
}

function Test-GitHasStagedChanges {
    param([string[]]$PathSpec = @("."))

    $arguments = @("diff", "--cached", "--quiet", "--") + @($PathSpec)
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & git -C $script:ProjectRoot @arguments
        if ($LASTEXITCODE -eq 0) {
            return $false
        }
        if ($LASTEXITCODE -eq 1) {
            return $true
        }
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    throw "Cannot read staged Git changes for: $($PathSpec -join ', ')"
}

function Test-GitHeadContainsPath {
    param([string]$RepoPath)

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & git -C $script:ProjectRoot cat-file -e "HEAD:$RepoPath" *> $null
        return ($LASTEXITCODE -eq 0)
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

function Get-GitStatusForPathSpec {
    param([string[]]$PathSpec = @("."))

    $arguments = @("status", "--short", "--") + @($PathSpec)
    $output = & git -C $script:ProjectRoot @arguments 2>$null
    if ($LASTEXITCODE -ne 0) {
        return "<cannot read git status>"
    }
    if (-not $output) {
        return "<empty>"
    }
    return ($output -join [Environment]::NewLine)
}

function Commit-IfChanged {
    param(
        [string]$Message,
        [string[]]$PathSpec = @("."),
        [switch]$RequireChanges,
        [switch]$ForceAdd
    )

    $addArgs = @("add", "--all")
    if ($ForceAdd) {
        $addArgs += "--force"
    }
    $addArgs += "--"
    $addArgs += @($PathSpec)
    Invoke-Git $addArgs
    if (Test-GitHasStagedChanges -PathSpec $PathSpec) {
        $commitArgs = @("commit", "--quiet", "-m", $Message, "--") + @($PathSpec)
        Invoke-Git $commitArgs
        Write-Host "Committed: $Message"
        return $true
    } elseif ($RequireChanges) {
        $status = Get-GitStatusForPathSpec -PathSpec $PathSpec
        throw "No Git changes to commit for: $($PathSpec -join ', '). Expected files from the 1C configuration dump. Git status for this path: $status"
    } else {
        Write-Host "No Git changes to commit for: $($PathSpec -join ', ')"
        return $false
    }
}

function Assert-BaselineDumpCommitted {
    param([string]$ExportPath)

    $normalizedExportPath = (($ExportPath -replace "\\", "/").TrimEnd("/"))
    $dumpInfoRepoPath = "$normalizedExportPath/ConfigDumpInfo.xml"
    if (Test-GitHeadContainsPath -RepoPath $dumpInfoRepoPath) {
        return
    }

    $status = Get-GitStatusForPathSpec -PathSpec @($ExportPath)
    throw "Baseline configuration dump was not committed to HEAD: $dumpInfoRepoPath. Git status for $($ExportPath): $status. Check .gitignore and make sure '$normalizedExportPath' is tracked."
}

function Ensure-GitIgnore {
    $gitignorePath = Join-Path $script:ProjectRoot ".gitignore"
    $fallbackRequired = @(
        ".dev.env",
        "build/result/",
        "build/event-log/",
        "testResults.xml",
        "*.cf",
        "*.cfe",
        "*.dt",
        "*.log",
        "logs/",
        ".agent-1c/dev-branches/",
        ".agent-1c/event-log-baselines/",
        ".agent-1c/runs/",
        ".agent-1c/locks/",
        ".agent-1c/infobases/",
        ".agent-1c/tools/event-log-exporter/",
        ".agent-1c/tools/auto-update/",
        ".agent-1c/tools/data-mcp/",
        ".agent-1c/tools/vanessa-automation/",
        ".agent-1c/tools/vanessa-mcp/",
        ".agent-1c/tools/roctup-mcp-toolkit/",
        ".agent-1c/mcp/",
        "build/data-mcp-tools-loader/",
        "build/test-results/",
        ".codex/config.toml",
        ".kilo/commands/itl*.md",
        ".kilo/kilo.json",
        ".kilo/kilo.jsonc"
    )

    $templatePath = Join-Path $script:ProjectRoot "templates\gitignore.append"
    if (Test-Path -LiteralPath $templatePath -PathType Leaf -ErrorAction SilentlyContinue) {
        $required = @(Read-Utf8Lines -Path $templatePath | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    } else {
        $required = $fallbackRequired
    }

    if (Test-Path -LiteralPath $gitignorePath) {
        $current = Read-Utf8Lines -Path $gitignorePath
    } else {
        $current = @()
    }

    $linesToAdd = @()
    foreach ($line in $required) {
        if ($current -notcontains $line) {
            $linesToAdd += $line
        }
    }

    if ($linesToAdd.Count -gt 0) {
        Add-Utf8Text -Path $gitignorePath -Value (($linesToAdd -join [Environment]::NewLine) + [Environment]::NewLine)
    }
}

function Resolve-PlatformExecutablePath {
    param([string]$Path)

    if (-not $Path) {
        return $Path
    }

    $resolvedPath = [Environment]::ExpandEnvironmentVariables($Path.Trim())
    if (Test-DirectoryExists -Path $resolvedPath) {
        return (Join-Path $resolvedPath "1cv8.exe")
    }

    return $resolvedPath
}

function Get-PlatformPath {
    $value = Require-Value "PLATFORM_PATH or project.platformPath" (Get-Setting -EnvName "PLATFORM_PATH" -ConfigName "platformPath")
    return Resolve-PlatformExecutablePath -Path $value
}

function Get-SourceUsesRepository {
    $value = Get-Setting -EnvName "SOURCE_USES_REPOSITORY" -ConfigName "sourceUsesRepository" -Default $true
    return ConvertTo-BoolSetting -Value $value -Default $true
}

function Get-WebPublishByDefault {
    $envValue = Get-EnvValue -Name "WEB_PUBLISH_BY_DEFAULT"
    if ($null -ne $envValue -and -not [string]::IsNullOrWhiteSpace([string]$envValue)) {
        return ConvertTo-BoolSetting -Value $envValue -Default $false
    }

    return ConvertTo-BoolSetting -Value (Get-ConfigValue -Path "web.publishByDefault" -Default $false) -Default $false
}

function Get-WebPublishAuto {
    $envValue = Get-EnvValue -Name "WEB_PUBLISH_AUTO"
    if ($null -ne $envValue -and -not [string]::IsNullOrWhiteSpace([string]$envValue)) {
        return ConvertTo-BoolSetting -Value $envValue -Default $false
    }

    return ConvertTo-BoolSetting -Value (Get-ConfigValue -Path "web.publishAuto" -Default $false) -Default $false
}

function Get-DefaultWebInstPath {
    $rawPlatformPath = Get-Setting -EnvName "PLATFORM_PATH" -ConfigName "platformPath"
    if (-not $rawPlatformPath) {
        return ""
    }

    $platformPath = Resolve-PlatformExecutablePath -Path $rawPlatformPath
    if (-not $platformPath) {
        return ""
    }

    $platformDirectory = Split-Path -Parent $platformPath
    if (-not $platformDirectory) {
        return ""
    }

    $candidate = Join-Path $platformDirectory "webinst.exe"
    if (Test-Path -LiteralPath $candidate -PathType Leaf -ErrorAction SilentlyContinue) {
        return $candidate
    }

    return ""
}

function Get-WebInstPath {
    $configured = Get-Setting -EnvName "WEBINST_PATH" -ConfigName "web.webInstPath"
    if ($configured) {
        return [Environment]::ExpandEnvironmentVariables(([string]$configured).Trim())
    }

    return Get-DefaultWebInstPath
}

function Remove-ApacheInlineComment {
    param([string]$Line)

    $inQuote = $false
    for ($i = 0; $i -lt $Line.Length; $i++) {
        $ch = $Line[$i]
        if ($ch -eq '"') {
            $inQuote = -not $inQuote
        } elseif ($ch -eq '#' -and -not $inQuote) {
            return $Line.Substring(0, $i)
        }
    }

    return $Line
}

function ConvertFrom-ApacheConfigToken {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) {
        return ""
    }

    $text = $Value.Trim()
    if (($text.StartsWith('"') -and $text.EndsWith('"')) -or ($text.StartsWith("'") -and $text.EndsWith("'"))) {
        $text = $text.Substring(1, $text.Length - 2)
    }
    return $text
}

function Resolve-ApacheConfigPathValue {
    param(
        [AllowNull()][string]$Value,
        [hashtable]$Variables,
        [string]$BasePath
    )

    $text = ConvertFrom-ApacheConfigToken -Value $Value
    if (-not $text) {
        return ""
    }

    foreach ($key in @($Variables.Keys)) {
        $text = $text.Replace(('${' + $key + '}'), [string]$Variables[$key])
    }
    $text = [Environment]::ExpandEnvironmentVariables($text)

    if (-not [System.IO.Path]::IsPathRooted($text) -and $BasePath) {
        $text = Join-Path $BasePath $text
    }

    try {
        return [System.IO.Path]::GetFullPath($text)
    } catch {
        return $text
    }
}

function Get-ApacheListenPort {
    param([string]$Value)

    $token = ConvertFrom-ApacheConfigToken -Value (($Value.Trim() -split "\s+")[0])
    if ($token -match '^\d+$') {
        return [int]$token
    }
    if ($token -match ':(\d+)$') {
        return [int]$matches[1]
    }
    if ($token -match '\]:(\d+)$') {
        return [int]$matches[1]
    }
    return 80
}

function Read-ApacheHttpdConfig {
    param([string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Path))
    $confDirectory = Split-Path -Parent $fullPath
    $defaultServerRoot = Split-Path -Parent $confDirectory
    $variables = @{}
    $serverRoot = $defaultServerRoot
    $documentRoot = ""
    $listenPort = 80

    foreach ($rawLine in Read-Utf8Lines -Path $fullPath) {
        $line = (Remove-ApacheInlineComment -Line $rawLine).Trim()
        if (-not $line) {
            continue
        }

        if ($line -match '^\s*Define\s+([^\s]+)\s+(.+)$') {
            $name = $matches[1]
            $value = Resolve-ApacheConfigPathValue -Value $matches[2] -Variables $variables -BasePath $serverRoot
            $variables[$name] = $value
            continue
        }

        if ($line -match '^\s*ServerRoot\s+(.+)$') {
            $serverRoot = Resolve-ApacheConfigPathValue -Value $matches[1] -Variables $variables -BasePath $serverRoot
            continue
        }

        if (-not $documentRoot -and $line -match '^\s*DocumentRoot\s+(.+)$') {
            $documentRoot = Resolve-ApacheConfigPathValue -Value $matches[1] -Variables $variables -BasePath $serverRoot
            continue
        }

        if ($line -match '^\s*Listen\s+(.+)$') {
            $listenPort = Get-ApacheListenPort -Value $matches[1]
            continue
        }
    }

    if (-not $documentRoot) {
        throw "DocumentRoot was not found in Apache config: $fullPath"
    }

    $urlBase = if ($listenPort -eq 80) { "http://localhost" } else { "http://localhost:$listenPort" }
    return [pscustomobject]@{
        found = $true
        httpdConfPath = $fullPath
        documentRoot = $documentRoot
        listenPort = $listenPort
        publicationRoot = (Join-Path $documentRoot "1c")
        publicationUrlBase = $urlBase
    }
}

function Get-ExecutablePathFromCommandLine {
    param([AllowNull()][string]$CommandLine)

    if ([string]::IsNullOrWhiteSpace($CommandLine)) {
        return ""
    }

    $text = $CommandLine.Trim()
    if ($text.StartsWith('"')) {
        $endQuote = $text.IndexOf('"', 1)
        if ($endQuote -gt 1) {
            return $text.Substring(1, $endQuote - 1)
        }
    }

    if ($text -match '^(.*?\.exe)(\s|$)') {
        return $matches[1]
    }

    return ""
}

function Get-CommandLineSwitchValue {
    param(
        [AllowNull()][string]$CommandLine,
        [string]$Switch
    )

    if ([string]::IsNullOrWhiteSpace($CommandLine)) {
        return ""
    }

    $pattern = '(?i)(?:^|\s)' + [regex]::Escape($Switch) + '\s+(?:"([^"]+)"|(\S+))'
    if ($CommandLine -match $pattern) {
        if ($matches[1]) {
            return $matches[1]
        }
        return $matches[2]
    }

    return ""
}

function New-ApacheConfigCandidate {
    param(
        [string]$Path,
        [string]$Source
    )

    if (-not $Path) {
        return $null
    }

    $resolved = [Environment]::ExpandEnvironmentVariables($Path)
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf -ErrorAction SilentlyContinue)) {
        return $null
    }

    return [pscustomobject]@{
        path = [System.IO.Path]::GetFullPath($resolved)
        source = $Source
    }
}

function Get-ApacheConfigCandidates {
    $candidates = New-Object System.Collections.ArrayList
    $seen = @{}

    $addCandidate = {
        param([string]$Path, [string]$Source)
        $candidate = New-ApacheConfigCandidate -Path $Path -Source $Source
        if ($candidate -and -not $seen.ContainsKey($candidate.path.ToLowerInvariant())) {
            $seen[$candidate.path.ToLowerInvariant()] = $true
            [void]$candidates.Add($candidate)
        }
    }

    $configuredConf = Get-Setting -EnvName "APACHE_HTTPD_CONF_PATH" -ConfigName "web.apacheHttpdConfPath"
    if ($configuredConf) {
        & $addCandidate $configuredConf "APACHE_HTTPD_CONF_PATH"
    }

    & $addCandidate (Join-Path (Get-ApacheInstallRoot) "conf\httpd.conf") "APACHE_INSTALL_ROOT"

    try {
        $services = @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object {
            ($_.PathName -match 'httpd\.exe') -or ($_.Name -match 'apache|httpd') -or ($_.DisplayName -match 'apache|httpd')
        })
        foreach ($service in $services) {
            $serviceRoot = Get-CommandLineSwitchValue -CommandLine $service.PathName -Switch "-d"
            $serviceConf = Get-CommandLineSwitchValue -CommandLine $service.PathName -Switch "-f"
            if ($serviceConf) {
                if (-not [System.IO.Path]::IsPathRooted($serviceConf) -and $serviceRoot) {
                    $serviceConf = Join-Path $serviceRoot $serviceConf
                }
                & $addCandidate $serviceConf "Windows service $($service.Name)"
            }

            $serviceExe = Get-ExecutablePathFromCommandLine -CommandLine $service.PathName
            if ($serviceExe) {
                $exeRoot = Split-Path -Parent (Split-Path -Parent $serviceExe)
                & $addCandidate (Join-Path $exeRoot "conf\httpd.conf") "Windows service $($service.Name)"
            }
        }
    } catch {
        # Service discovery is best-effort; continue with PATH and standard folders.
    }

    $httpdCommand = Get-Command httpd.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($httpdCommand -and $httpdCommand.Source) {
        $httpdRoot = Split-Path -Parent (Split-Path -Parent $httpdCommand.Source)
        & $addCandidate (Join-Path $httpdRoot "conf\httpd.conf") "PATH httpd.exe"
    }

    $standardRoots = @(
        "C:\Apache24",
        "C:\Apache2.4",
        "C:\Apache",
        (Join-Path ([Environment]::GetFolderPath("ProgramFiles")) "Apache24"),
        (Join-Path ([Environment]::GetFolderPath("ProgramFiles")) "Apache Software Foundation\Apache2.4")
    )
    $programFilesX86 = [Environment]::GetEnvironmentVariable("ProgramFiles(x86)", "Process")
    if ($programFilesX86) {
        $standardRoots += (Join-Path $programFilesX86 "Apache Software Foundation\Apache2.4")
    }

    foreach ($root in @($standardRoots | Where-Object { $_ } | Select-Object -Unique)) {
        & $addCandidate (Join-Path $root "conf\httpd.conf") "standard path"
    }

    return @($candidates)
}

function Find-ApacheConfig {
    $errors = @()
    foreach ($candidate in Get-ApacheConfigCandidates) {
        try {
            $parsed = Read-ApacheHttpdConfig -Path $candidate.path
            $parsed | Add-Member -NotePropertyName source -NotePropertyValue $candidate.source -Force
            return $parsed
        } catch {
            $errors += "$($candidate.path): $($_.Exception.Message)"
        }
    }

    $message = "Apache/httpd config was not found. Prepare the web server outside ITL workflow, or set APACHE_HTTPD_CONF_PATH/WEB_PUBLICATION_ROOT/WEB_PUBLICATION_URL_BASE, then rerun detect-web-publication or check-tools."
    if ($errors.Count -gt 0) {
        $message += " Checked candidates: $($errors -join '; ')"
    }

    return [pscustomobject]@{
        found = $false
        httpdConfPath = ""
        documentRoot = ""
        listenPort = $null
        publicationRoot = ""
        publicationUrlBase = ""
        source = ""
        message = $message
    }
}

function Get-ConfigUrlBaseOverride {
    $envValue = Get-EnvValue -Name "WEB_PUBLICATION_URL_BASE"
    if ($envValue) {
        return $envValue
    }

    $configValue = Get-ConfigValue -Path "web.publicationUrlBase"
    if ($configValue -and $configValue -ne "http://localhost") {
        return $configValue
    }

    return ""
}

function Get-EffectiveApacheSettings {
    $detected = Find-ApacheConfig
    $webInstPath = Get-WebInstPath
    $publicationRootOverride = Get-Setting -EnvName "WEB_PUBLICATION_ROOT" -ConfigName "web.publicationRoot"
    $publicationUrlOverride = Get-ConfigUrlBaseOverride
    $apacheKind = Get-Setting -EnvName "APACHE_KIND" -ConfigName "web.apacheKind" -Default "apache24"

    $publicationRoot = $publicationRootOverride
    if (-not $publicationRoot -and $detected.found) {
        $publicationRoot = $detected.publicationRoot
    }

    $publicationUrlBase = $publicationUrlOverride
    if (-not $publicationUrlBase -and $detected.found) {
        $publicationUrlBase = $detected.publicationUrlBase
    }
    if (-not $publicationUrlBase) {
        $publicationUrlBase = "http://localhost"
    }

    $httpdConfPath = ""
    if ($detected.found) {
        $httpdConfPath = $detected.httpdConfPath
    }

    $hasManualPublicationRoot = -not [string]::IsNullOrWhiteSpace([string]$publicationRootOverride)
    $webInstOk = ($webInstPath -and (Test-Path -LiteralPath $webInstPath -PathType Leaf -ErrorAction SilentlyContinue))
    $ready = ([bool]$webInstOk -and -not [string]::IsNullOrWhiteSpace([string]$publicationRoot) -and ($detected.found -or $hasManualPublicationRoot))

    return [pscustomobject]@{
        ready = $ready
        webInstPath = $webInstPath
        webInstOk = [bool]$webInstOk
        apacheKind = $apacheKind
        apacheFound = [bool]$detected.found
        apacheSource = $detected.source
        message = $(if ($detected.found) { "Apache detected from $($detected.source)" } else { $detected.message })
        httpdConfPath = $httpdConfPath
        documentRoot = $detected.documentRoot
        listenPort = $detected.listenPort
        publicationRoot = $publicationRoot
        publicationUrlBase = $publicationUrlBase
        manualPublicationRoot = $hasManualPublicationRoot
    }
}

function Set-DotEnvValues {
    param([hashtable]$Values)

    $path = Join-Path $script:ProjectRoot ".dev.env"
    $lines = @()
    if (Test-Path -LiteralPath $path) {
        $lines = @(Read-Utf8Lines -Path $path)
    }

    $seen = @{}
    $updated = New-Object System.Collections.ArrayList
    foreach ($line in $lines) {
        $replacement = $line
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)=') {
            $name = $matches[1]
            if ($Values.ContainsKey($name)) {
                $replacement = "$name=$($Values[$name])"
                $seen[$name] = $true
            }
        }
        [void]$updated.Add($replacement)
    }

    foreach ($name in @($Values.Keys | Sort-Object)) {
        if (-not $seen.ContainsKey($name)) {
            [void]$updated.Add("$name=$($Values[$name])")
        }
    }

    Write-Utf8Text -Path $path -Value ((@($updated) -join [Environment]::NewLine) + [Environment]::NewLine)
}

function New-DefaultProjectConfig {
    return [ordered]@{
        schemaVersion = 1
        masterBranch = "master"
        baseConfigurationVersion = "PM5"
        exportPath = "src/cf"
        extensionsPath = "src/cfe"
        artifactsPath = "build/result"
        testsPath = "tests/features"
        testResultsPath = "build/test-results/vanessa"
        logsPath = "logs/1c"
        platformPath = ""
        infoBaseKind = "file"
        sourceUsesRepository = $true
        sourceInfoBasePath = ""
        sourceServerName = ""
        sourceInfoBaseName = ""
        repositoryPath = ""
        dependencyMode = "fresh"
        verificationPolicy = "warn"
        devBranchInfoBaseRoot = ".agent-1c/infobases/dev-branches"
        devBranchWorktreeRoot = ""
        serverBaseCopyScript = ""
        aiRules = [ordered]@{
            repo = "https://github.com/xmentosx/itl_ai_rules_1c.git"
            ref = "itl-main-a421cf44-r6"
            tools = @("codex", "kilocode")
        }
        vibecoding1cMcp = [ordered]@{
            registryRepo = "http://gitlabserv01.itland.local/root/MCP-vibecoding1c-registry.git"
            providerDefault = "remote"
            remoteConfigId = ""
            localScopeDefault = "project"
        }
        web = [ordered]@{
            publishByDefault = $false
            publishAuto = $false
            webInstPath = ""
            apacheKind = "apache24"
            apacheHttpdConfPath = ""
            publicationRoot = ""
            publicationUrlBase = "http://localhost"
        }
        vanessaAutomation = [ordered]@{
            installRoot = ".agent-1c/tools/vanessa-automation"
            epfPath = ""
            version = ""
            featuresPath = "tests/features"
            reportsPath = "build/test-results/vanessa"
        }
        roctupMcpToolkit = [ordered]@{
            installRoot = ".agent-1c/tools/roctup-mcp-toolkit"
            epfPath = ""
            version = ""
        }
    }
}

function Get-EffectiveWebPublicationSettings {
    return Get-EffectiveApacheSettings
}

function New-DefaultDependencyLockManifest {
    return [ordered]@{
        schemaVersion = 1
        mode = "fresh"
        dependencies = [ordered]@{
            workflowPackage = [ordered]@{
                repo = "https://github.com/xmentosx/1c-agent-workflow.git"
                ref = "master"
                commit = ""
                source = "template default"
                updatedAt = ""
            }
            aiRules1c = [ordered]@{
                repo = "https://github.com/xmentosx/itl_ai_rules_1c.git"
                ref = "itl-main-a421cf44-r6"
                commit = "603987af4b4ca2d7c6be9e894edf3b6239f5ed35"
                upstreamRepo = "https://github.com/comol/ai_rules_1c.git"
                upstreamRef = "refs/heads/main"
                upstreamCommit = "a421cf44eb1f5859cf2a2b74884f8fbcaefc4826"
                downstreamRevision = 6
                compatibilityStatus = "passed"
                compatibilityCheckedAt = "2026-07-14T08:17:00Z"
            }
            vanessaAutomation = [ordered]@{
                version = "1.2.043.28"
                url = "https://github.com/Pr-Mex/vanessa-automation/releases/download/1.2.043.28/vanessa-automation-single.1.2.043.28.zip"
                sha256 = "cd0a017a8af69328f471f628ac1367a0e5148f790df9c28c318348b30f08f32a"
                source = "template baseline"
            }
            vanessaMcp = [ordered]@{
                clientMcp = [ordered]@{
                    version = "v0.6.4"
                    assetName = "client_mcp.cfe"
                    url = "https://github.com/1c-neurofish/onec-client-mcp-devkit/releases/download/v0.6.4/client_mcp.cfe"
                    sha256 = "74d3cb7f97e3800860f5a1754eecf47178164d888f2299125d1b3118a4614ec1"
                    source = "template baseline"
                    updatedAt = "2026-07-10T00:00:00Z"
                }
                vaExtension = [ordered]@{
                    version = "1.2.043.28"
                    assetName = "VAExtension.1.29.cfe"
                    url = "https://github.com/Pr-Mex/vanessa-automation/releases/download/1.2.043.28/VAExtension.1.29.cfe"
                    sha256 = "fc557bb23371a37dbe22a7a7a83e28f6db75b57f87e8802028cf1f90c4e00605"
                    source = "template baseline"
                    updatedAt = "2026-07-10T00:00:00Z"
                }
            }
            roctupMcpToolkit = [ordered]@{
                version = "v1.7.0"
                assetName = "MCP_Toolkit.epf"
                url = "https://github.com/ROCTUP/1c-mcp-toolkit/releases/download/v1.7.0/MCP_Toolkit.epf"
                sha256 = "e9a0856224aea4f54763fe1fb6a21aa8e71efb9d14158adc4382e1b2276d829d"
                source = "template baseline"
                updatedAt = "2026-07-10T00:00:00Z"
            }
        }
    }
}

function Get-DependencyLockPath {
    if (-not $script:DependencyLockPath) {
        $script:DependencyLockPath = Join-Path $script:ProjectRoot ".agent-1c\dependency-lock.json"
    }
    return $script:DependencyLockPath
}

function Read-DependencyLockManifest {
    $path = Get-DependencyLockPath
    if (Test-Path -LiteralPath $path -PathType Leaf -ErrorAction SilentlyContinue) {
        return Read-Utf8Text -Path $path | ConvertFrom-Json
    }
    return [pscustomobject](New-DefaultDependencyLockManifest)
}

function Write-DependencyLockManifest {
    param([object]$Manifest)

    Write-Utf8Text -Path (Get-DependencyLockPath) -Value (($Manifest | ConvertTo-Json -Depth 10) + [Environment]::NewLine)
}

function Ensure-DependencyLockManifest {
    $path = Get-DependencyLockPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf -ErrorAction SilentlyContinue)) {
        Write-DependencyLockManifest -Manifest (New-DefaultDependencyLockManifest)
    }
}

function Get-DependencyMode {
    if ($DependencyMode) {
        return ConvertTo-DependencyMode -Value $DependencyMode
    }

    $value = Get-EnvValue -Name "DEPENDENCY_MODE"
    if (-not $value) {
        $value = Get-ConfigValue -Path "dependencyMode" -Default ""
    }
    if (-not $value) {
        $lock = Read-DependencyLockManifest
        $value = [string](Get-ConfigValueFromObject -Object $lock -Path "mode" -Default "fresh")
    }

    return ConvertTo-DependencyMode -Value $value
}

function Get-BaseConfigurationVersion {
    $value = Get-Setting -EnvName "BASE_CONFIGURATION_VERSION" -ConfigName "baseConfigurationVersion" -Default "PM5"
    return ConvertTo-BaseConfigurationVersion -Value $value
}

function Test-ProductDocsMcpAllowed {
    return ((Get-BaseConfigurationVersion) -eq "PM5")
}

function Set-ProjectBaseConfigurationVersion {
    param([string]$Version)

    $normalizedVersion = ConvertTo-BaseConfigurationVersion -Value $Version
    $config = if (Test-Path -LiteralPath $script:ConfigPath -PathType Leaf -ErrorAction SilentlyContinue) {
        ConvertTo-Agent1cHashtable -Object (Read-Utf8Text -Path $script:ConfigPath | ConvertFrom-Json)
    } else {
        New-DefaultProjectConfig
    }
    $config["baseConfigurationVersion"] = $normalizedVersion
    Write-Utf8Text -Path $script:ConfigPath -Value (($config | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
    Read-ProjectConfig
}

function Get-ConfigValueFromObject {
    param(
        [AllowNull()][object]$Object,
        [string]$Path,
        [object]$Default = $null
    )

    $node = $Object
    foreach ($part in $Path.Split(".")) {
        if ($null -eq $node) {
            return $Default
        }
        if ($node -is [System.Collections.IDictionary]) {
            if (-not $node.Contains($part)) {
                return $Default
            }
            $node = $node[$part]
            continue
        }
        $prop = $node.PSObject.Properties[$part]
        if ($null -eq $prop) {
            return $Default
        }
        $node = $prop.Value
    }
    if ($null -eq $node) {
        return $Default
    }
    if ($node -is [string] -and $node -eq "") {
        return $Default
    }
    return $node
}

function Set-DependencyLockMode {
    param([string]$Mode)

    $normalizedMode = ConvertTo-DependencyMode -Value $Mode
    Ensure-DependencyLockManifest
    $manifest = ConvertTo-Agent1cHashtable -Object (Read-DependencyLockManifest)
    $manifest["mode"] = $normalizedMode
    Write-DependencyLockManifest -Manifest $manifest

    $config = if (Test-Path -LiteralPath $script:ConfigPath -PathType Leaf -ErrorAction SilentlyContinue) {
        ConvertTo-Agent1cHashtable -Object (Read-Utf8Text -Path $script:ConfigPath | ConvertFrom-Json)
    } else {
        New-DefaultProjectConfig
    }
    $config["dependencyMode"] = $normalizedMode
    Write-Utf8Text -Path $script:ConfigPath -Value (($config | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
    Read-ProjectConfig
}

function Get-DependencyLockEntry {
    param([string]$Name)

    $manifest = Read-DependencyLockManifest
    return Get-ConfigValueFromObject -Object $manifest -Path "dependencies.$Name" -Default $null
}

function Get-GitHubApiHeaders {
    $headers = @{
        "User-Agent" = "1c-agent-workflow"
        "Accept" = "application/vnd.github+json"
    }

    $token = [string](Get-EnvValue -Name "GITHUB_TOKEN" -Default "")
    if (-not $token) {
        $token = [string](Get-EnvValue -Name "GH_TOKEN" -Default "")
    }
    if ($token) {
        $headers["Authorization"] = "Bearer $token"
    }

    return $headers
}

function Invoke-GitHubApiRestMethod {
    param([string]$Uri)

    return Invoke-RestMethod -Uri $Uri -Headers (Get-GitHubApiHeaders)
}

function Get-GitHubApiResponseHeader {
    param(
        [AllowNull()][object]$Headers,
        [string]$Name
    )

    if ($null -eq $Headers) {
        return ""
    }
    try {
        $value = $Headers[$Name]
        if ($value) {
            return ([string]$value).Trim()
        }
    } catch {
    }
    return ""
}

function Get-GitHubApiFailureInfo {
    param([AllowNull()][object]$ErrorRecord)

    $exception = if ($null -ne $ErrorRecord) { $ErrorRecord.Exception } else { $null }
    $response = if ($null -ne $exception -and $null -ne $exception.PSObject.Properties["Response"]) { $exception.Response } else { $null }
    $statusCode = 0
    $headers = $null
    try {
        if ($null -ne $response) {
            $statusCode = [int]$response.StatusCode
            $headers = $response.Headers
        }
    } catch {
    }
    if ($statusCode -eq 0 -and $null -ne $exception) {
        try {
            $statusCode = [int]$exception.Data["StatusCode"]
        } catch {
        }
    }

    $message = if ($null -ne $exception) { [string]$exception.Message } else { "" }
    $remaining = Get-GitHubApiResponseHeader -Headers $headers -Name "X-RateLimit-Remaining"
    $reset = Get-GitHubApiResponseHeader -Headers $headers -Name "X-RateLimit-Reset"
    $rateLimited = ($statusCode -eq 429 -or ($statusCode -eq 403 -and ($remaining -eq "0" -or $message -match '(?i)rate limit')))

    return [pscustomobject]@{
        statusCode = $statusCode
        remaining = $remaining
        reset = $reset
        rateLimited = $rateLimited
        message = $message
    }
}

function Get-DependencyLockRateLimitFallbackInfo {
    param(
        [string]$LockPath,
        [string]$AssetNameLike = "",
        [string]$DefaultFileName = ""
    )

    $manifest = Read-DependencyLockManifest
    $entry = Get-ConfigValueFromObject -Object $manifest -Path "dependencies.$LockPath" -Default $null
    $version = [string](Get-ConfigValueFromObject -Object $entry -Path "version" -Default "")
    $url = [string](Get-ConfigValueFromObject -Object $entry -Path "url" -Default "")
    $sha256 = [string](Get-ConfigValueFromObject -Object $entry -Path "sha256" -Default "")
    $name = [string](Get-ConfigValueFromObject -Object $entry -Path "assetName" -Default "")
    if (-not $name -and $url) {
        $name = Split-Path -Leaf $url
    }
    if (-not $name) {
        $name = $DefaultFileName
    }
    if (-not $version -or -not $url -or -not $sha256 -or ($AssetNameLike -and (-not $name -or $name -notlike $AssetNameLike))) {
        return $null
    }

    return [pscustomobject]@{
        url = $url
        name = $name
        version = $version
        expectedSha256 = $sha256
        source = "dependency-lock rate-limit fallback"
    }
}

function Get-GitHubReleaseRateLimitFallbackInfo {
    param(
        [string]$Repository,
        [string]$AssetNameLike,
        [string]$DefaultFileName
    )

    $lockPath = switch ("$Repository|$AssetNameLike") {
        "ROCTUP/1c-mcp-toolkit|MCP_Toolkit.epf" { "roctupMcpToolkit"; break }
        "1c-neurofish/onec-client-mcp-devkit|client_mcp.cfe" { "vanessaMcp.clientMcp"; break }
        "Pr-Mex/vanessa-automation|VAExtension*.cfe" { "vanessaMcp.vaExtension"; break }
        default { "" }
    }
    if (-not $lockPath) {
        return $null
    }
    return Get-DependencyLockRateLimitFallbackInfo -LockPath $lockPath -AssetNameLike $AssetNameLike -DefaultFileName $DefaultFileName
}

function Test-DependencyLockRateLimitFallbackSource {
    param([string]$Source)
    return $Source -eq "dependency-lock rate-limit fallback"
}

function Get-GitHubRateLimitRecoveryMessage {
    param(
        [string]$Operation,
        [object]$FailureInfo
    )

    $resetSuffix = ""
    $reset = [string](Get-ConfigValueFromObject -Object $FailureInfo -Path "reset" -Default "")
    if ($reset) {
        try {
            $resetAt = [DateTimeOffset]::FromUnixTimeSeconds([int64]$reset).ToLocalTime().ToString("u")
            $resetSuffix = " GitHub reports the limit resets at $resetAt."
        } catch {
        }
    }
    return "GitHub API rate limit reached while $Operation. Set GITHUB_TOKEN (or GH_TOKEN) in the process environment or .dev.env, or provide a complete compatible dependency lock.$resetSuffix"
}

function Update-DependencyLockEntry {
    param(
        [string]$Name,
        [hashtable]$Values
    )

    if ((Get-DependencyMode) -ne "fresh") {
        return
    }

    Ensure-DependencyLockManifest
    $manifest = ConvertTo-Agent1cHashtable -Object (Read-DependencyLockManifest)
    $dependencies = ConvertTo-Agent1cHashtable -Object $manifest["dependencies"]
    $entry = ConvertTo-Agent1cHashtable -Object $dependencies[$Name]
    foreach ($key in @($Values.Keys)) {
        $entry[$key] = $Values[$key]
    }
    $entry["updatedAt"] = (Get-Date).ToString("o")
    $dependencies[$Name] = $entry
    $manifest["dependencies"] = $dependencies
    $manifest["mode"] = "fresh"
    Write-DependencyLockManifest -Manifest $manifest
}

function Get-VerificationPolicy {
    $value = Get-EnvValue -Name "VERIFICATION_POLICY"
    if (-not $value) {
        $value = Get-ConfigValue -Path "verificationPolicy" -Default "warn"
    }
    $policy = ([string]$value).Trim().ToLowerInvariant()
    if (-not $policy) {
        return "warn"
    }
    if ($policy -ne "warn" -and $policy -ne "block") {
        throw "Invalid verificationPolicy: $value. Use warn or block."
    }
    return $policy
}

function New-DefaultToolsManifest {
    return [ordered]@{
        schemaVersion = 1
        tools = @(
            [ordered]@{
                id = "git"
                name = "Git"
                required = $true
                install = [ordered]@{
                    policy = "offer"
                    commands = @("winget install --id Git.Git -e")
                }
            },
            [ordered]@{
                id = "1c-platform"
                name = "1C platform"
                required = $true
                install = [ordered]@{
                    policy = "manual"
                    commands = @("Choose an installed 1C version from C:\Program Files\1cv8\*\bin\1cv8.exe or C:\Program Files (x86)\1cv8\*\bin\1cv8.exe, then set PLATFORM_PATH in .dev.env. If no version is found, install 1C:Enterprise platform manually.")
                }
            },
            [ordered]@{
                id = "apache-webinst"
                name = "Web publication"
                requiredWhenWebPublication = $true
                install = [ordered]@{
                    policy = "manual"
                    commands = @(
                        "Prepare the web server and 1C web publication tooling outside ITL workflow.",
                        "Then run: powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action configure-web-publication"
                    )
                }
            },
            [ordered]@{
                id = "vanessa-automation"
                name = "Vanessa Automation"
                required = $true
                install = [ordered]@{
                    policy = "auto"
                    commands = @(
                        "The ITL helper installs Vanessa Automation automatically during init. Manual recovery: powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action install-vanessa-automation"
                    )
                }
            }
        )
    }
}

function Ensure-WorkflowProjectFiles {
    $agentDir = Join-Path $script:ProjectRoot ".agent-1c"
    New-Item -ItemType Directory -Force -Path $agentDir | Out-Null

    if (-not (Test-Path -LiteralPath $script:ConfigPath -PathType Leaf)) {
        Write-Utf8Text -Path $script:ConfigPath -Value (((New-DefaultProjectConfig) | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
    }

    Ensure-DependencyLockManifest

    $toolsPath = Join-Path $agentDir "tools.json"
    if (-not (Test-Path -LiteralPath $toolsPath -PathType Leaf)) {
        Write-Utf8Text -Path $toolsPath -Value (((New-DefaultToolsManifest) | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
        $script:ToolsManifestLoaded = $false
        $script:ToolsManifest = $null
    }

    Ensure-GitIgnore
}

function Get-ApacheInstallRoot {
    $value = Get-Setting -EnvName "APACHE_INSTALL_ROOT" -ConfigName "web.apacheInstallRoot" -Default "C:\Apache24"
    return [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables(([string]$value).Trim()))
}

function Test-TcpPortAvailable {
    param([int]$Port)

    $listener = $null
    try {
        $listener = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Any), $Port
        $listener.Start()
        return $true
    } catch {
        return $false
    } finally {
        if ($listener) {
            $listener.Stop()
        }
    }
}

function ConvertFrom-FileUri {
    param([string]$Value)

    if ($Value -match '^file:') {
        return ([System.Uri]$Value).LocalPath
    }

    return $Value
}

function Save-WebPublicationDetectedSettingsToDotEnv {
    param(
        [bool]$PublishByDefault = $true,
        [bool]$Auto = $true
    )

    $settings = Get-EffectiveApacheSettings
    $values = @{
        WEB_PUBLISH_BY_DEFAULT = $(if ($PublishByDefault) { "true" } else { "false" })
        WEB_PUBLISH_AUTO = $(if ($Auto) { "true" } else { "false" })
        APACHE_KIND = $settings.apacheKind
    }

    if ($settings.webInstPath) {
        $values["WEBINST_PATH"] = $settings.webInstPath
    }
    if ($settings.httpdConfPath) {
        $values["APACHE_HTTPD_CONF_PATH"] = $settings.httpdConfPath
    }
    if ($settings.publicationRoot) {
        $values["WEB_PUBLICATION_ROOT"] = $settings.publicationRoot
    }
    if ($settings.publicationUrlBase) {
        $values["WEB_PUBLICATION_URL_BASE"] = $settings.publicationUrlBase
    }

    Set-DotEnvValues -Values $values
    Write-Host "Web publication settings saved to .dev.env"
    return $settings
}

function Set-WebPublicationPolicy {
    param(
        [bool]$PublishByDefault,
        [bool]$Auto
    )

    Set-DotEnvValues -Values @{
        WEB_PUBLISH_BY_DEFAULT = $(if ($PublishByDefault) { "true" } else { "false" })
        WEB_PUBLISH_AUTO = $(if ($Auto) { "true" } else { "false" })
    }
    Import-DotEnv -Path (Join-Path $script:ProjectRoot ".dev.env") -Overwrite
}

function Get-Agent1cUtf8Text {
    param([Parameter(Mandatory = $true)][string]$Value)

    return [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($Value))
}

function Read-WebPublicationValue {
    param(
        [string]$Prompt,
        [string]$Default = "",
        [switch]$Required
    )

    while ($true) {
        $suffix = if ($Default) { " [$Default]" } else { "" }
        $value = Read-Host ($Prompt + $suffix)
        if ([string]::IsNullOrWhiteSpace($value)) {
            $value = $Default
        }
        $value = [string]$value
        if (-not $Required -or -not [string]::IsNullOrWhiteSpace($value)) {
            return $value.Trim()
        }
        Write-Host (Get-Agent1cUtf8Text "0JfQvdCw0YfQtdC90LjQtSDQvtCx0Y/Qt9Cw0YLQtdC70YzQvdC+Lg==")
    }
}

function Read-WebPublicationSettingsInteractively {
    param(
        [bool]$PublishByDefault = $true,
        [bool]$Auto = $true
    )

    $settings = Get-EffectiveWebPublicationSettings
    Write-Host (Get-Agent1cUtf8Text "0JDQstGC0L7QvNCw0YLQuNGH0LXRgdC60LDRjyDQstC10LEt0L/Rg9Cx0LvQuNC60LDRhtC40Y8g0LjRgdC/0L7Qu9GM0LfRg9C10YIg0YHRg9GJ0LXRgdGC0LLRg9GO0YnQuNC5IHdlYmluc3Qt0YHQvtCy0LzQtdGB0YLQuNC80YvQuSDQstC10LEt0YHQtdGA0LLQtdGAIDFDLiBJVEwgd29ya2Zsb3cg0L3QtSDRg9GB0YLQsNC90LDQstC70LjQstCw0LXRgiDQuCDQvdC1INC90LDRgdGC0YDQsNC40LLQsNC10YIg0LLQtdCxLdGB0LXRgNCy0LXRgC4=")

    $webInstPath = Read-WebPublicationValue -Prompt (Get-Agent1cUtf8Text "0J/QvtC70L3Ri9C5INC/0YPRgtGMINC6IHdlYmluc3QuZXhl") -Default $settings.webInstPath -Required
    $publicationRoot = Read-WebPublicationValue -Prompt (Get-Agent1cUtf8Text "0JrQsNGC0LDQu9C+0LMg0L/Rg9Cx0LvQuNC60LDRhtC40Lk=") -Default $settings.publicationRoot -Required
    $publicationUrlBase = Read-WebPublicationValue -Prompt (Get-Agent1cUtf8Text "0JHQsNC30L7QstGL0LkgVVJMINC/0YPQsdC70LjQutCw0YbQuNC5") -Default $settings.publicationUrlBase -Required
    $apacheKind = Read-WebPublicationValue -Prompt (Get-Agent1cUtf8Text "0KLQuNC/IHdlYmluc3Q=") -Default $settings.apacheKind -Required
    $httpdConfPath = Read-WebPublicationValue -Prompt (Get-Agent1cUtf8Text "0J3QtdC+0LHRj9C30LDRgtC10LvRjNC90YvQuSDQv9GD0YLRjCDQuiDQutC+0L3RhNC40LPRg9GA0LDRhtC40LggQXBhY2hlL2h0dHBkLCDQv9GD0YHRgtC+INC10YHQu9C4INC90LUg0L3Rg9C20LXQvQ==") -Default $settings.httpdConfPath

    $values = @{
        WEB_PUBLISH_BY_DEFAULT = $(if ($PublishByDefault) { "true" } else { "false" })
        WEB_PUBLISH_AUTO = $(if ($Auto) { "true" } else { "false" })
        WEBINST_PATH = $webInstPath
        WEB_PUBLICATION_ROOT = $publicationRoot
        WEB_PUBLICATION_URL_BASE = $publicationUrlBase
        APACHE_KIND = $apacheKind
        APACHE_HTTPD_CONF_PATH = $httpdConfPath
    }
    Set-DotEnvValues -Values $values
    Import-DotEnv -Path (Join-Path $script:ProjectRoot ".dev.env") -Overwrite
    return Get-EffectiveWebPublicationSettings
}

function Ensure-WebPublicationForInit {
    param([object]$Answers)

    if (-not $Answers.webPublishByDefault) {
        Set-WebPublicationPolicy -PublishByDefault $false -Auto $false
        return
    }

    if (-not $Answers.webPublishAuto) {
        Set-WebPublicationPolicy -PublishByDefault $true -Auto $false
        return
    }

    $settings = Get-EffectiveWebPublicationSettings
    if ($settings.ready) {
        Save-WebPublicationDetectedSettingsToDotEnv -PublishByDefault $true -Auto $true | Out-Null
        Import-DotEnv -Path (Join-Path $script:ProjectRoot ".dev.env") -Overwrite
        return
    }

    Write-Host "Automatic web publication was requested, but the existing web publication tooling is not ready: $($settings.message)"
    if (Test-InteractiveInputAvailable) {
        try {
            $settings = Read-WebPublicationSettingsInteractively -PublishByDefault $true -Auto $true
            if ($settings.ready) {
                Write-Host "Automatic web publication is configured."
                return
            }
            Write-Warning "Web publication settings are incomplete. Automatic publication will be disabled; manual branch publication remains available."
        } catch {
            Write-Warning "Could not collect web publication settings. Automatic publication will be disabled; manual branch publication remains available. $($_.Exception.Message)"
        }
    } else {
        Write-Warning "Interactive input is unavailable. Automatic publication will be disabled; manual branch publication remains available."
    }

    Set-WebPublicationPolicy -PublishByDefault $true -Auto $false
}

function Configure-WebPublication {
    if (-not (Test-InteractiveInputAvailable)) {
        throw "configure-web-publication needs terminal input. Run it from an interactive terminal."
    }

    Write-Section "Configure web publication"
    $publishByDefault = Read-InitYesNo -Prompt (Get-Agent1cUtf8Text "0J/Rg9Cx0LvQuNC60L7QstCw0YLRjCDQuNC90YTQvtGA0LzQsNGG0LjQvtC90L3Ri9C1INCx0LDQt9GLINCy0LXRgtC+0Log0YDQsNC30YDQsNCx0L7RgtC60Lgg0L3QsCDQstC10LEt0YHQtdGA0LLQtdGA0LUg0L/QviDRg9C80L7Qu9GH0LDQvdC40Y4/") -Default (Get-WebPublishByDefault)
    if (-not $publishByDefault) {
        Set-WebPublicationPolicy -PublishByDefault $false -Auto $false
        Write-Host "Web publication disabled for new development branches."
        return
    }

    $auto = Read-InitYesNo -Prompt (Get-Agent1cUtf8Text "0J/Ri9GC0LDRgtGM0YHRjyDQsNCy0YLQvtC80LDRgtC40YfQtdGB0LrQuCDQv9GD0LHQu9C40LrQvtCy0LDRgtGMINCx0LDQt9GDINC/0YDQuCDRgdC+0LfQtNCw0L3QuNC4INCy0LXRgtC60Lgg0YDQsNC30YDQsNCx0L7RgtC60Lg/") -Default (Get-WebPublishAuto)
    if (-not $auto) {
        Set-WebPublicationPolicy -PublishByDefault $true -Auto $false
        Write-Host "Web publication enabled; branch publication will be manual."
        return
    }

    $settings = Get-EffectiveWebPublicationSettings
    if ($settings.ready) {
        Write-Host "Detected usable web publication settings."
        if (Read-InitYesNo -Prompt (Get-Agent1cUtf8Text "0JjRgdC/0L7Qu9GM0LfQvtCy0LDRgtGMINC90LDQudC00LXQvdC90YvQtSDQvdCw0YHRgtGA0L7QudC60Lgg0LTQu9GPINCw0LLRgtC+0LzQsNGC0LjRh9C10YHQutC+0Lkg0L/Rg9Cx0LvQuNC60LDRhtC40Lg/") -Default $true) {
            Save-WebPublicationDetectedSettingsToDotEnv -PublishByDefault $true -Auto $true | Out-Null
            Import-DotEnv -Path (Join-Path $script:ProjectRoot ".dev.env") -Overwrite
            return
        }
    }

    $settings = Read-WebPublicationSettingsInteractively -PublishByDefault $true -Auto $true
    if ($settings.ready) {
        Write-Host "Automatic web publication is configured."
        return
    }

    Set-WebPublicationPolicy -PublishByDefault $true -Auto $false
    Write-Warning "Web publication settings are incomplete. Publication remains enabled, but automatic publication is disabled."
}

function Find-Installed1CPlatforms {
    $roots = @()

    $programFiles = [Environment]::GetFolderPath("ProgramFiles")
    if ($programFiles) {
        $roots += (Join-Path $programFiles "1cv8")
    }

    $programFilesX86 = [Environment]::GetEnvironmentVariable("ProgramFiles(x86)", "Process")
    if (-not $programFilesX86) {
        $programFilesX86 = [Environment]::GetEnvironmentVariable("ProgramFiles(x86)", "Machine")
    }
    if ($programFilesX86) {
        $roots += (Join-Path $programFilesX86 "1cv8")
    }

    $roots += @("C:\Program Files\1cv8", "C:\Program Files (x86)\1cv8")
    $roots = @($roots | Where-Object { $_ } | Select-Object -Unique)

    $items = @()
    $seen = @{}
    foreach ($root in $roots) {
        foreach ($dir in Get-ChildDirectoriesSafe -Path $root) {
            $exePath = Join-Path $dir.FullName "bin\1cv8.exe"
            if (-not (Test-Path -LiteralPath $exePath -PathType Leaf -ErrorAction SilentlyContinue)) {
                continue
            }

            $key = $exePath.ToLowerInvariant()
            if ($seen.ContainsKey($key)) {
                continue
            }
            $seen[$key] = $true

            $parsedVersion = $null
            $versionOk = [System.Version]::TryParse($dir.Name, [ref]$parsedVersion)
            $items += [pscustomobject]@{
                version = $dir.Name
                parsedVersion = $(if ($versionOk) { $parsedVersion } else { [System.Version]"0.0" })
                binPath = (Split-Path -Parent $exePath)
                exePath = $exePath
                root = $root
            }
        }
    }

    return @($items | Sort-Object @{ Expression = { $_.parsedVersion }; Descending = $true }, @{ Expression = { $_.exePath }; Descending = $false })
}

function Format-Installed1CPlatformOptions {
    param([object[]]$Platforms)

    $items = @($Platforms)
    if ($items.Count -eq 0) {
        return "No installed 1C platform versions were found under C:\Program Files\1cv8 or C:\Program Files (x86)\1cv8."
    }

    $lines = @("Installed 1C platform versions detected:")
    $index = 1
    foreach ($item in $items) {
        $lines += "$index. $($item.version) - $($item.exePath)"
        $index++
    }
    $lines += "Choose one of these 1cv8.exe paths for PLATFORM_PATH, or enter a custom full path."
    return ($lines -join "`n")
}

function Test-InteractiveInputAvailable {
    try {
        return (-not [Console]::IsInputRedirected)
    } catch {
        return $false
    }
}

function ConvertTo-YesNoBool {
    param(
        [AllowNull()][object]$Value,
        [bool]$Default = $false
    )

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $Default
    }

    if ($Value -is [bool]) {
        return [bool]$Value
    }

    $text = ([string]$Value).Trim().ToLowerInvariant()
    $yesMarker = -join ([char[]](0x0434, 0x0430))
    $noMarker = -join ([char[]](0x043D, 0x0435, 0x0442))
    if (@("1", "true", "yes", "y", "on", $yesMarker) -contains $text) {
        return $true
    }
    if (@("0", "false", "no", "n", "off", $noMarker, "-") -contains $text) {
        return $false
    }

    throw "Expected yes/no value, got: $Value"
}

function Read-InitRequired {
    param([string]$Prompt)

    while ($true) {
        $value = Read-Host $Prompt
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value
        }
        Write-Host (Get-Agent1cUtf8Text "0JfQvdCw0YfQtdC90LjQtSDQvtCx0Y/Qt9Cw0YLQtdC70YzQvdC+Lg==")
    }
}

function Read-InitOptional {
    param([string]$Prompt)
    return (Read-Host $Prompt)
}

function Read-InitYesNo {
    param(
        [string]$Prompt,
        [bool]$Default = $false
    )

    $suffix = if ($Default) { Get-Agent1cUtf8Text "IFvQlC/QvV0=" } else { Get-Agent1cUtf8Text "IFvQtC/QnV0=" }
    while ($true) {
        $answer = Read-Host ($Prompt + $suffix)
        try {
            return ConvertTo-YesNoBool -Value $answer -Default $Default
        } catch {
            Write-Host (Get-Agent1cUtf8Text "0J7RgtCy0LXRgtGM0YLQtSDQtNCwINC40LvQuCDQvdC10YIu")
        }
    }
}

function Read-InitInfoBaseKind {
    while ($true) {
        $answer = (Read-Host (Get-Agent1cUtf8Text "0KLQuNC/INC40YHRhdC+0LTQvdC+0Lkg0LjQvdGE0L7RgNC80LDRhtC40L7QvdC90L7QuSDQsdCw0LfRizogZmlsZSDQuNC70Lggc2VydmVyIFtmaWxlXQ==")).Trim().ToLowerInvariant()
        if (-not $answer) {
            return "file"
        }
        if ($answer -eq "file" -or $answer -eq "server") {
            return $answer
        }
        Write-Host (Get-Agent1cUtf8Text "0JLQstC10LTQuNGC0LUgJ2ZpbGUnINC40LvQuCAnc2VydmVyJy4=")
    }
}

function Read-InitBaseConfigurationVersion {
    while ($true) {
        $answer = (Read-Host "Base configuration version: PM4 or PM5 [PM5]").Trim()
        try {
            return ConvertTo-BaseConfigurationVersion -Value $answer
        } catch {
            Write-Host "Enter PM4 or PM5."
        }
    }
}

function Read-InitDependencyMode {
    $useLatest = Read-InitYesNo -Prompt (Get-Agent1cUtf8Text "0JjRgdC/0L7Qu9GM0LfQvtCy0LDRgtGMINGB0LLQtdC20LjQtSDQstC10YDRgdC40Lgg0LfQsNCy0LjRgdC40LzQvtGB0YLQtdC5INC/0YDQuCDQuNC90LjRhtC40LDQu9C40LfQsNGG0LjQuD8g0J7RgtCy0LXRgtGM0YLQtSDQvdC10YIsINGH0YLQvtCx0Ysg0LjRgdC/0L7Qu9GM0LfQvtCy0LDRgtGMIHBpbnMg0LjQtyAuYWdlbnQtMWMvZGVwZW5kZW5jeS1sb2NrLmpzb24u") -Default $true
    if ($useLatest) {
        return "fresh"
    }
    return "locked"
}

function Read-InitPlatformPath {
    $platforms = @(Find-Installed1CPlatforms)
    if ($platforms.Count -gt 0) {
        Write-Host (Get-Agent1cUtf8Text "0J3QsNC50LTQtdC90L3Ri9C1INCy0LXRgNGB0LjQuCDQv9C70LDRgtGE0L7RgNC80YsgMUM6")
        for ($i = 0; $i -lt $platforms.Count; $i++) {
            Write-Host ("{0}. {1} - {2}" -f ($i + 1), $platforms[$i].version, $platforms[$i].exePath)
        }

        while ($true) {
            $answer = Read-Host (Get-Agent1cUtf8Text "0JLRi9Cx0LXRgNC40YLQtSDQvdC+0LzQtdGAINC/0LvQsNGC0YTQvtGA0LzRiyDQuNC70Lgg0LLQstC10LTQuNGC0LUg0L/QvtC70L3Ri9C5INC/0YPRgtGMINC6IDFjdjguZXhl")
            $index = 0
            if ([int]::TryParse($answer, [ref]$index) -and $index -ge 1 -and $index -le $platforms.Count) {
                return $platforms[$index - 1].exePath
            }
            if (-not [string]::IsNullOrWhiteSpace($answer)) {
                return $answer
            }
        }
    }

    return Read-InitRequired (Get-Agent1cUtf8Text "0J/QvtC70L3Ri9C5INC/0YPRgtGMINC6IDFjdjguZXhl")
}

function Get-AnswerValue {
    param(
        [object]$Answers,
        [string[]]$Names,
        [object]$Default = $null
    )

    foreach ($name in $Names) {
        $prop = $Answers.PSObject.Properties[$name]
        if ($null -ne $prop) {
            return $prop.Value
        }
    }
    return $Default
}

function Read-InitAnswersFromJson {
    $path = Require-Value "InitAnswersPath" $InitAnswersPath
    $resolvedPath = Resolve-ProjectPath $path
    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
        throw "Init answers JSON was not found: $resolvedPath"
    }
    return Read-Utf8Text -Path $resolvedPath | ConvertFrom-Json
}

function Confirm-InitWizardProjectRoot {
    Write-Section (Get-Agent1cUtf8Text "0JzQsNGB0YLQtdGAINC40L3QuNGG0LjQsNC70LjQt9Cw0YbQuNC4")
    Write-Host ((Get-Agent1cUtf8Text "0JrQvtGA0LXQvdGMINC/0YDQvtC10LrRgtCwOiA=") + $script:ProjectRoot)
    if (-not (Read-InitYesNo -Prompt (Get-Agent1cUtf8Text "0JjQvdC40YbQuNCw0LvQuNC30LjRgNC+0LLQsNGC0YwgMUMg0L/RgNC+0LXQutGCINCyINGN0YLQvtC5INC/0LDQv9C60LU/") -Default $true)) {
        throw "Init canceled by developer."
    }
}

function Read-InitWizardAnswersOnce {
    $platformPath = Read-InitPlatformPath
    $baseConfigurationVersion = Read-InitBaseConfigurationVersion
    $infoBaseKind = Read-InitInfoBaseKind
    $sourceUsesRepository = Read-InitYesNo -Prompt (Get-Agent1cUtf8Text "0JjRgdGF0L7QtNC90LDRjyDQuNC90YTQvtGA0LzQsNGG0LjQvtC90L3QsNGPINCx0LDQt9CwINC/0L7QtNC60LvRjtGH0LXQvdCwINC6INGF0YDQsNC90LjQu9C40YnRgyDQutC+0L3RhNC40LPRg9GA0LDRhtC40LggMUM/") -Default $true

    $answers = [ordered]@{
        platformPath = $platformPath
        baseConfigurationVersion = $baseConfigurationVersion
        infoBaseKind = $infoBaseKind
        sourceUsesRepository = $sourceUsesRepository
        ibUser = ""
        ibPassword = ""
        repositoryPath = ""
        repositoryUser = ""
        repositoryPassword = ""
        webPublishByDefault = $false
        webPublishAuto = $false
    }

    if ($infoBaseKind -eq "server") {
        $answers.sourceServerName = Read-InitRequired (Get-Agent1cUtf8Text "0JjQvNGPINGB0LXRgNCy0LXRgNCwIDFD")
        $answers.sourceInfoBaseName = Read-InitRequired (Get-Agent1cUtf8Text "0JjQvNGPINC40YHRhdC+0LTQvdC+0Lkg0LjQvdGE0L7RgNC80LDRhtC40L7QvdC90L7QuSDQsdCw0LfRiw==")
    } else {
        $answers.sourceInfoBasePath = Read-InitRequired (Get-Agent1cUtf8Text "0JrQsNGC0LDQu9C+0LMg0LjRgdGF0L7QtNC90L7QuSDRhNCw0LnQu9C+0LLQvtC5INC40L3RhNC+0YDQvNCw0YbQuNC+0L3QvdC+0Lkg0LHQsNC30Ys=")
    }

    $answers.ibUser = Read-InitOptional (Get-Agent1cUtf8Text "0J/QvtC70YzQt9C+0LLQsNGC0LXQu9GMINC40L3RhNC+0YDQvNCw0YbQuNC+0L3QvdC+0Lkg0LHQsNC30YsgKNC/0YPRgdGC0L4sINC10YHQu9C4INC90LUg0LjRgdC/0L7Qu9GM0LfRg9C10YLRgdGPKQ==")
    $answers.ibPassword = ConvertFrom-OptionalPasswordAnswer (Read-InitOptional (Get-Agent1cUtf8Text "0J/QsNGA0L7Qu9GMINC40L3RhNC+0YDQvNCw0YbQuNC+0L3QvdC+0Lkg0LHQsNC30YsgKNC/0YPRgdGC0L4g0LjQu9C4ICctJyDQtdGB0LvQuCDQvdC1INC40YHQv9C+0LvRjNC30YPQtdGC0YHRjyk="))

    if ($sourceUsesRepository) {
        $answers.repositoryPath = Read-InitRequired (Get-Agent1cUtf8Text "0J/Rg9GC0Ywg0Log0YXRgNCw0L3QuNC70LjRidGDINC60L7QvdGE0LjQs9GD0YDQsNGG0LjQuA==")
        $answers.repositoryUser = Read-InitRequired (Get-Agent1cUtf8Text "0J/QvtC70YzQt9C+0LLQsNGC0LXQu9GMINGF0YDQsNC90LjQu9C40YnQsCDQutC+0L3RhNC40LPRg9GA0LDRhtC40Lg=")
        $answers.repositoryPassword = ConvertFrom-OptionalPasswordAnswer (Read-InitOptional (Get-Agent1cUtf8Text "0J/QsNGA0L7Qu9GMINGF0YDQsNC90LjQu9C40YnQsCDQutC+0L3RhNC40LPRg9GA0LDRhtC40LggKNC/0YPRgdGC0L4g0LjQu9C4ICctJyDQtdGB0LvQuCDQvdC1INC40YHQv9C+0LvRjNC30YPQtdGC0YHRjyk="))
    }

    $answers.webPublishByDefault = Read-InitYesNo -Prompt (Get-Agent1cUtf8Text "0J/Rg9Cx0LvQuNC60L7QstCw0YLRjCDQuNC90YTQvtGA0LzQsNGG0LjQvtC90L3Ri9C1INCx0LDQt9GLINCy0LXRgtC+0Log0YDQsNC30YDQsNCx0L7RgtC60Lgg0L3QsCDQstC10LEt0YHQtdGA0LLQtdGA0LUg0LTQu9GPINGC0LXRgdGC0LjRgNC+0LLQsNC90LjRjyDQstC10LEt0LrQu9C40LXQvdGC0LA/") -Default $false
    if ($answers.webPublishByDefault) {
        $answers.webPublishAuto = Read-InitYesNo -Prompt (Get-Agent1cUtf8Text "0J/Ri9GC0LDRgtGM0YHRjyDQsNCy0YLQvtC80LDRgtC40YfQtdGB0LrQuCDQv9GD0LHQu9C40LrQvtCy0LDRgtGMINCx0LDQt9GDINC/0YDQuCDRgdC+0LfQtNCw0L3QuNC4INCy0LXRgtC60Lgg0YDQsNC30YDQsNCx0L7RgtC60Lg/") -Default $false
    }
    $answers.dependencyMode = Read-InitDependencyMode
    $answers.vibecoding1cMcpSetupDuringInit = Read-InitYesNo -Prompt (Get-Agent1cUtf8Text "0J3QsNGB0YLRgNC+0LjRgtGMIHZpYmVjb2RpbmcxYyBNQ1Ag0YHQtdC50YfQsNGBPyDQntGC0LLQtdGC0YzRgtC1INC90LXRgiwg0YfRgtC+0LHRiyDRgdC00LXQu9Cw0YLRjCDRjdGC0L4g0L/QvtC30LbQtSDQvtCx0YvRh9C90YvQvCDQt9Cw0L/RgNC+0YHQvtC8INCw0LPQtdC90YLRgyDQuNC70LggaGVscGVyIGFjdGlvbi4=") -Default $true

    return [pscustomobject]$answers
}

function Write-InitWizardAnswersSummary {
    param([object]$Answers)

    $answers = [pscustomobject]$Answers
    Write-Section (Get-Agent1cUtf8Text "0KHQstC+0LTQutCwINC40L3QuNGG0LjQsNC70LjQt9Cw0YbQuNC4")
    Write-Host ((Get-Agent1cUtf8Text "0JrQvtGA0LXQvdGMINC/0YDQvtC10LrRgtCwOiA=") + $script:ProjectRoot)
    Write-Host ((Get-Agent1cUtf8Text "0J/Qu9Cw0YLRhNC+0YDQvNCwOiA=") + $answers.platformPath)
    Write-Host ("Base configuration version: " + $answers.baseConfigurationVersion)
    Write-Host ((Get-Agent1cUtf8Text "0KLQuNC/INC40YHRhdC+0LTQvdC+0Lkg0LHQsNC30Ys6IA==") + $answers.infoBaseKind)
    if ($answers.infoBaseKind -eq "server") {
        Write-Host ((Get-Agent1cUtf8Text "0JjRgdGF0L7QtNC90YvQuSDRgdC10YDQstC10YA6IA==") + $answers.sourceServerName)
        Write-Host ((Get-Agent1cUtf8Text "0JjRgdGF0L7QtNC90LDRjyDQsdCw0LfQsDog") + $answers.sourceInfoBaseName)
    } else {
        Write-Host ((Get-Agent1cUtf8Text "0JjRgdGF0L7QtNC90LDRjyDQsdCw0LfQsDog") + $answers.sourceInfoBasePath)
    }
    Write-Host ((Get-Agent1cUtf8Text "0J/QvtC70YzQt9C+0LLQsNGC0LXQu9GMINCx0LDQt9GLOiA=") + $answers.ibUser)
    Write-Host ((Get-Agent1cUtf8Text "0JjRgdGF0L7QtNC90LDRjyDQsdCw0LfQsCDQuNGB0L/QvtC70YzQt9GD0LXRgiDRhdGA0LDQvdC40LvQuNGJ0LU6IA==") + $answers.sourceUsesRepository)
    if ($answers.sourceUsesRepository) {
        Write-Host ((Get-Agent1cUtf8Text "0J/Rg9GC0Ywg0Log0YXRgNCw0L3QuNC70LjRidGDOiA=") + $answers.repositoryPath)
        Write-Host ((Get-Agent1cUtf8Text "0J/QvtC70YzQt9C+0LLQsNGC0LXQu9GMINGF0YDQsNC90LjQu9C40YnQsDog") + $answers.repositoryUser)
    }
    Write-Host ((Get-Agent1cUtf8Text "0JLQtdCxLdC/0YPQsdC70LjQutCw0YbQuNGPINC/0L4g0YPQvNC+0LvRh9Cw0L3QuNGOOiA=") + $answers.webPublishByDefault)
    Write-Host ((Get-Agent1cUtf8Text "0JDQstGC0L7QvNCw0YLQuNGH0LXRgdC60LDRjyDQstC10LEt0L/Rg9Cx0LvQuNC60LDRhtC40Y86IA==") + $answers.webPublishAuto)
    Write-Host ((Get-Agent1cUtf8Text "0KDQtdC20LjQvCDQt9Cw0LLQuNGB0LjQvNC+0YHRgtC10Lk6IA==") + $answers.dependencyMode)
    Write-Host ((Get-Agent1cUtf8Text "0J3QsNGB0YLRgNC+0LjRgtGMIHZpYmVjb2RpbmcxYyBNQ1Ag0YHQtdC50YfQsNGBOiA=") + $answers.vibecoding1cMcpSetupDuringInit)
    Write-Host (Get-Agent1cUtf8Text "0J/QsNGA0L7Qu9C4OiDRgdC60YDRi9GC0Ys=")
}

function Confirm-InitWizardAnswers {
    return (Read-InitYesNo -Prompt (Get-Agent1cUtf8Text "0J/RgNC+0LTQvtC70LbQuNGC0Ywg0YEg0Y3RgtC40LzQuCDQt9C90LDRh9C10L3QuNGP0LzQuD8g0J7RgtCy0LXRgtGM0YLQtSDQvdC10YIsINGH0YLQvtCx0Ysg0LfQsNC/0L7Qu9C90LjRgtGMINC/0LDRgNCw0LzQtdGC0YDRiyDQt9Cw0L3QvtCy0L4u") -Default $true)
}

function Read-InitAnswersFromWizard {
    if (-not (Test-InteractiveInputAvailable)) {
        throw "Interactive init wizard needs terminal input. Run this command from an interactive terminal or pass -InitMode json -InitAnswersPath <file>."
    }

    Confirm-InitWizardProjectRoot

    while ($true) {
        $answers = Read-InitWizardAnswersOnce
        Write-InitWizardAnswersSummary -Answers $answers
        if (Confirm-InitWizardAnswers) {
            return [pscustomobject]$answers
        }

        Write-Host (Get-Agent1cUtf8Text "0JfQsNC/0L7Qu9C90LjRgtC1INC/0LDRgNCw0LzQtdGC0YDRiyDQt9Cw0L3QvtCy0L4u")
    }
}

function Normalize-InitAnswers {
    param([object]$Answers)

    $baseConfigurationVersion = ConvertTo-BaseConfigurationVersion -Value (Get-AnswerValue -Answers $Answers -Names @("baseConfigurationVersion", "BASE_CONFIGURATION_VERSION") -Default "PM5")
    $sourceUsesRepository = ConvertTo-YesNoBool -Value (Get-AnswerValue -Answers $Answers -Names @("sourceUsesRepository", "SOURCE_USES_REPOSITORY") -Default $true) -Default $true
    $webPublishByDefault = ConvertTo-YesNoBool -Value (Get-AnswerValue -Answers $Answers -Names @("webPublishByDefault", "WEB_PUBLISH_BY_DEFAULT") -Default $false) -Default $false
    $webPublishAuto = ConvertTo-YesNoBool -Value (Get-AnswerValue -Answers $Answers -Names @("webPublishAuto", "WEB_PUBLISH_AUTO") -Default $false) -Default $false
    if (-not $webPublishByDefault) {
        $webPublishAuto = $false
    }
    $vibecoding1cMcpSetupDuringInit = ConvertTo-YesNoBool -Value (Get-AnswerValue -Answers $Answers -Names @("vibecoding1cMcpSetupDuringInit", "VIBECODING1C_MCP_SETUP_DURING_INIT") -Default $true) -Default $true
    $dependencyModeValue = Get-AnswerValue -Answers $Answers -Names @("dependencyMode", "DEPENDENCY_MODE") -Default ""
    if (-not $dependencyModeValue) {
        $useLatestDependencies = ConvertTo-YesNoBool -Value (Get-AnswerValue -Answers $Answers -Names @("useLatestDependencies", "USE_LATEST_DEPENDENCIES") -Default $true) -Default $true
        $dependencyModeValue = $(if ($useLatestDependencies) { "fresh" } else { "locked" })
    }

    return [pscustomobject]@{
        platformPath = [string](Get-AnswerValue -Answers $Answers -Names @("platformPath", "PLATFORM_PATH"))
        baseConfigurationVersion = $baseConfigurationVersion
        infoBaseKind = ([string](Get-AnswerValue -Answers $Answers -Names @("infoBaseKind", "INFOBASE_KIND") -Default "file")).Trim().ToLowerInvariant()
        sourceUsesRepository = $sourceUsesRepository
        sourceInfoBasePath = [string](Get-AnswerValue -Answers $Answers -Names @("sourceInfoBasePath", "SOURCE_INFOBASE_PATH") -Default "")
        sourceServerName = [string](Get-AnswerValue -Answers $Answers -Names @("sourceServerName", "SOURCE_SERVER_NAME") -Default "")
        sourceInfoBaseName = [string](Get-AnswerValue -Answers $Answers -Names @("sourceInfoBaseName", "SOURCE_INFOBASE_NAME") -Default "")
        ibUser = [string](Get-AnswerValue -Answers $Answers -Names @("ibUser", "IB_USER") -Default "")
        ibPassword = ConvertFrom-OptionalPasswordAnswer ([string](Get-AnswerValue -Answers $Answers -Names @("ibPassword", "IB_PASSWORD") -Default ""))
        repositoryPath = [string](Get-AnswerValue -Answers $Answers -Names @("repositoryPath", "REPOSITORY_PATH") -Default "")
        repositoryUser = [string](Get-AnswerValue -Answers $Answers -Names @("repositoryUser", "REPOSITORY_USER") -Default "")
        repositoryPassword = ConvertFrom-OptionalPasswordAnswer ([string](Get-AnswerValue -Answers $Answers -Names @("repositoryPassword", "REPOSITORY_PASSWORD") -Default ""))
        webPublishByDefault = $webPublishByDefault
        webPublishAuto = $webPublishAuto
        dependencyMode = ConvertTo-DependencyMode -Value $dependencyModeValue
        vibecoding1cMcpSetupDuringInit = $vibecoding1cMcpSetupDuringInit
        installVanessaIfMissing = (ConvertTo-YesNoBool -Value (Get-AnswerValue -Answers $Answers -Names @("installVanessaIfMissing", "INSTALL_VANESSA_IF_MISSING") -Default $false) -Default $false)
    }
}

function Assert-InitAnswers {
    param([object]$Answers)

    $missing = @()
    if (-not $Answers.platformPath) { $missing += "platformPath" }
    if ($Answers.infoBaseKind -ne "file" -and $Answers.infoBaseKind -ne "server") { $missing += "infoBaseKind(file|server)" }
    if ($Answers.infoBaseKind -eq "server") {
        if (-not $Answers.sourceServerName) { $missing += "sourceServerName" }
        if (-not $Answers.sourceInfoBaseName) { $missing += "sourceInfoBaseName" }
    } else {
        if (-not $Answers.sourceInfoBasePath) { $missing += "sourceInfoBasePath" }
    }
    if ($Answers.sourceUsesRepository) {
        if (-not $Answers.repositoryPath) { $missing += "repositoryPath" }
        if (-not $Answers.repositoryUser) { $missing += "repositoryUser" }
    }

    if ($missing.Count -gt 0) {
        throw "Init answers are incomplete. Missing: $($missing -join ', ')"
    }
}

function Save-InitAnswers {
    param([object]$Answers)

    $values = @{
        PLATFORM_PATH = $Answers.platformPath
        INFOBASE_KIND = $Answers.infoBaseKind
        SOURCE_USES_REPOSITORY = $(if ($Answers.sourceUsesRepository) { "true" } else { "false" })
        SOURCE_INFOBASE_PATH = $(if ($Answers.infoBaseKind -eq "file") { $Answers.sourceInfoBasePath } else { "" })
        SOURCE_SERVER_NAME = $(if ($Answers.infoBaseKind -eq "server") { $Answers.sourceServerName } else { "" })
        SOURCE_INFOBASE_NAME = $(if ($Answers.infoBaseKind -eq "server") { $Answers.sourceInfoBaseName } else { "" })
        IB_USER = $Answers.ibUser
        IB_PASSWORD = $Answers.ibPassword
        REPOSITORY_PATH = $(if ($Answers.sourceUsesRepository) { $Answers.repositoryPath } else { "" })
        REPOSITORY_USER = $(if ($Answers.sourceUsesRepository) { $Answers.repositoryUser } else { "" })
        REPOSITORY_PASSWORD = $(if ($Answers.sourceUsesRepository) { $Answers.repositoryPassword } else { "" })
        WEB_PUBLISH_BY_DEFAULT = $(if ($Answers.webPublishByDefault) { "true" } else { "false" })
        WEB_PUBLISH_AUTO = $(if ($Answers.webPublishAuto) { "true" } else { "false" })
        DEPENDENCY_MODE = $Answers.dependencyMode
        VIBECODING1C_MCP_SETUP_DURING_INIT = $(if ($Answers.vibecoding1cMcpSetupDuringInit) { "true" } else { "false" })
    }

    Set-DotEnvValues -Values $values
    Set-ProjectBaseConfigurationVersion -Version $Answers.baseConfigurationVersion
    Set-DependencyLockMode -Mode $Answers.dependencyMode
    Import-DotEnv -Path (Join-Path $script:ProjectRoot ".dev.env") -Overwrite
    $script:InitVibecoding1cMcpSetupRequested = [bool]$Answers.vibecoding1cMcpSetupDuringInit
}

function New-ConfiguredInitAnswers {
    return [pscustomobject]@{
        webPublishByDefault = (Get-WebPublishByDefault)
        webPublishAuto = (Get-WebPublishAuto)
        installVanessaIfMissing = [bool]$InstallVanessaIfMissing
    }
}

function Prepare-InitProjectSettings {
    Ensure-WorkflowProjectFiles
    Read-ProjectConfig

    $rawAnswers = if ($InitMode -eq "json") {
        Read-InitAnswersFromJson
    } elseif ($InitMode -eq "wizard") {
        Read-InitAnswersFromWizard
    } else {
        return
    }

    $answers = Normalize-InitAnswers -Answers $rawAnswers
    Assert-InitAnswers -Answers $answers
    Save-InitAnswers -Answers $answers
    Ensure-WebPublicationForInit -Answers $answers
    Ensure-VanessaAutomationForInit -Answers $answers
    Read-ProjectConfig
}

function Prepare-ConfiguredInitProjectSettings {
    Ensure-WorkflowProjectFiles
    Read-ProjectConfig

    $answers = New-ConfiguredInitAnswers
    Ensure-WebPublicationForInit -Answers $answers
    Ensure-VanessaAutomationForInit -Answers $answers
    Read-ProjectConfig
}

function Get-InfoBaseKind {
    return (Get-Setting -EnvName "INFOBASE_KIND" -ConfigName "infoBaseKind" -Default "file")
}

function Get-SourceInfoBasePath {
    $kind = Get-InfoBaseKind
    if ($kind -eq "server") {
        $legacyValue = Get-Setting -EnvName "SOURCE_INFOBASE_PATH" -ConfigName "sourceInfoBasePath"
        if ($legacyValue) {
            return $legacyValue
        }

        $serverName = Require-Value "SOURCE_SERVER_NAME or project.sourceServerName" (Get-Setting -EnvName "SOURCE_SERVER_NAME" -ConfigName "sourceServerName")
        $infoBaseName = Require-Value "SOURCE_INFOBASE_NAME or project.sourceInfoBaseName" (Get-Setting -EnvName "SOURCE_INFOBASE_NAME" -ConfigName "sourceInfoBaseName")
        return "Srvr=`"$serverName`";Ref=`"$infoBaseName`";"
    }

    $value = Get-Setting -EnvName "SOURCE_INFOBASE_PATH" -ConfigName "sourceInfoBasePath"
    if (-not $value) {
        $value = Get-EnvValue -Name "INFOBASE_PATH"
    }
    return Require-Value "SOURCE_INFOBASE_PATH or project.sourceInfoBasePath" $value
}

function Get-RepositoryPath {
    return Require-Value "REPOSITORY_PATH or project.repositoryPath" (Get-Setting -EnvName "REPOSITORY_PATH" -ConfigName "repositoryPath")
}

function Get-DevBranchInfoBaseRoot {
    return Get-Setting -EnvName "DEV_BRANCH_INFOBASE_ROOT" -ConfigName "devBranchInfoBaseRoot" -Default ".agent-1c/infobases/dev-branches"
}

function Get-DefaultDevBranchWorktreeRoot {
    $mainWorktreePath = Get-MainWorktreePath
    $parent = Split-Path -Parent $mainWorktreePath
    $leaf = Split-Path -Leaf $mainWorktreePath
    return [System.IO.Path]::GetFullPath((Join-Path $parent ($leaf + "-worktrees")))
}

function Get-DevBranchWorktreeRoot {
    $value = Get-Setting -EnvName "DEV_BRANCH_WORKTREE_ROOT" -ConfigName "devBranchWorktreeRoot" -Default ""
    if ($value) {
        if ([System.IO.Path]::IsPathRooted([string]$value)) {
            return [System.IO.Path]::GetFullPath([string]$value)
        }
        return [System.IO.Path]::GetFullPath((Join-Path $script:ProjectRoot ([string]$value)))
    }
    return Get-DefaultDevBranchWorktreeRoot
}

function Resolve-DevBranchWorktreePath {
    param([string]$SafeDevBranchName)

    if ($DevBranchWorktreePath) {
        if ([System.IO.Path]::IsPathRooted($DevBranchWorktreePath)) {
            return [System.IO.Path]::GetFullPath($DevBranchWorktreePath)
        }
        return [System.IO.Path]::GetFullPath((Join-Path $script:ProjectRoot $DevBranchWorktreePath))
    }

    return [System.IO.Path]::GetFullPath((Join-Path (Get-DevBranchWorktreeRoot) $SafeDevBranchName))
}

function ConvertTo-AgentToolList {
    param([AllowNull()][object]$Value)

    $values = @()
    if ($null -ne $Value) {
        if (($Value -is [System.Collections.IEnumerable]) -and -not ($Value -is [string])) {
            $values = @($Value)
        } else {
            $values = @($Value)
        }
    }

    $items = @()
    foreach ($value in $values) {
        foreach ($part in ([string]$value).Split(",")) {
            $normalized = $part.Trim().ToLowerInvariant()
            if (-not $normalized) {
                continue
            }
            switch ($normalized) {
                "both" { $items += @("codex", "kilocode") }
                "kilo" { $items += "kilocode" }
                default { $items += $normalized }
            }
        }
    }

    return @($items | Select-Object -Unique)
}

function Get-AgentTargets {
    $target = $AgentTarget
    if ($null -eq $target -or ($target -is [string] -and [string]::IsNullOrWhiteSpace($target))) {
        $target = Get-Setting -EnvName "AGENT_TOOLS" -ConfigName "aiRules.tools" -Default @("codex", "kilocode")
    }

    $items = @(ConvertTo-AgentToolList -Value $target)
    if ($items.Count -eq 0) {
        $items = @("codex", "kilocode")
    }

    return $items
}

function Read-ToolsManifest {
    if ($script:ToolsManifestLoaded) {
        return $script:ToolsManifest
    }

    $script:ToolsManifestLoaded = $true
    $path = Join-Path $script:ProjectRoot ".agent-1c\tools.json"
    if (Test-Path -LiteralPath $path) {
        $script:ToolsManifest = Read-Utf8Text -Path $path | ConvertFrom-Json
    }
    return $script:ToolsManifest
}

function Get-ToolOffer {
    param(
        [string]$Id,
        [string]$Fallback
    )

    $manifest = Read-ToolsManifest
    if ($manifest -and $manifest.PSObject.Properties["tools"]) {
        foreach ($tool in @($manifest.tools)) {
            if ($tool.id -eq $Id -and $tool.PSObject.Properties["install"] -and $tool.install.PSObject.Properties["commands"]) {
                return (@($tool.install.commands) -join "`n")
            }
        }
    }
    return $Fallback
}

function Invoke-ToolVersionCheck {
    param(
        [string]$Command,
        [string[]]$Arguments
    )

    try {
        $output = & $Command @Arguments 2>&1
        $exitCode = $LASTEXITCODE
        return [pscustomobject]@{
            ok = ($exitCode -eq 0)
            detail = (($output | Out-String).Trim())
        }
    } catch {
        $detail = $_.Exception.Message
        $atIndex = $detail.IndexOf("At ")
        if ($atIndex -gt 0) {
            $detail = $detail.Substring(0, $atIndex).Trim()
        }
        return [pscustomobject]@{
            ok = $false
            detail = $detail
        }
    }
}

function New-ToolResult {
    param(
        [string]$Id,
        [string]$Name,
        [bool]$Required,
        [bool]$Ok,
        [string]$Detail,
        [string]$Offer
    )

    return [pscustomobject]@{
        id = $Id
        name = $Name
        required = $Required
        ok = $Ok
        detail = $Detail
        offer = $Offer
    }
}

function Check-Tools {
    param([switch]$StopOnMissing)

    Write-Section "Check tools"
    $results = @()

    $gitCommand = Get-Command git -ErrorAction SilentlyContinue
    $gitCheck = if ($gitCommand) { Invoke-ToolVersionCheck -Command "git" -Arguments @("--version") } else { $null }
    $results += New-ToolResult `
        -Id "git" `
        -Name "Git" `
        -Required $true `
        -Ok ([bool]$gitCommand -and [bool]$gitCheck.ok) `
        -Detail $(if ($gitCommand) { $gitCheck.detail } else { "git command not found" }) `
        -Offer (Get-ToolOffer -Id "git" -Fallback "winget install --id Git.Git -e")

    $rawPlatformPath = Get-Setting -EnvName "PLATFORM_PATH" -ConfigName "platformPath"
    $platformPath = Resolve-PlatformExecutablePath -Path $rawPlatformPath
    $platformOk = ($platformPath -and (Test-Path -LiteralPath $platformPath))
    $platformOffer = Get-ToolOffer -Id "1c-platform" -Fallback "Install 1C:Enterprise platform manually, then set PLATFORM_PATH in .dev.env."
    if (-not $platformOk) {
        $foundPlatforms = @(Find-Installed1CPlatforms)
        if ($foundPlatforms.Count -gt 0) {
            $platformOffer = Format-Installed1CPlatformOptions -Platforms $foundPlatforms
        }
    }
    $results += New-ToolResult `
        -Id "1c-platform" `
        -Name "1C platform" `
        -Required $true `
        -Ok ([bool]$platformOk) `
        -Detail $(if ($platformOk) { $platformPath } elseif ($rawPlatformPath) { "Configured path does not exist: $platformPath" } else { "PLATFORM_PATH/project.platformPath is missing" }) `
        -Offer $platformOffer

    $vanessa = Get-VanessaAutomationState
    $vanessaDetail = if ($vanessa.ready) {
        if ($vanessa.version) { "{0} ({1})" -f $vanessa.epfPath, $vanessa.version } else { $vanessa.epfPath }
    } else {
        $vanessa.message
    }
    $results += New-ToolResult `
        -Id "vanessa-automation" `
        -Name "Vanessa Automation" `
        -Required $true `
        -Ok ([bool]$vanessa.ready) `
        -Detail $vanessaDetail `
        -Offer (Get-ToolOffer -Id "vanessa-automation" -Fallback "ITL installs Vanessa Automation automatically during init. Manual recovery: run helper action install-vanessa-automation.")

    $publishDefault = Get-WebPublishByDefault
    $publishAuto = Get-WebPublishAuto
    if ($PublishToWeb -or ($publishDefault -and $publishAuto)) {
        $apacheSettings = Get-EffectiveApacheSettings
        $webInstDetail = if ($apacheSettings.webInstPath) { $apacheSettings.webInstPath } else { "webinst.exe was not found next to PLATFORM_PATH and WEBINST_PATH is not set" }
        $results += New-ToolResult `
            -Id "apache-webinst" `
            -Name "Web publication webinst" `
            -Required $true `
            -Ok ([bool]$apacheSettings.webInstOk) `
            -Detail $webInstDetail `
            -Offer (Get-ToolOffer -Id "apache-webinst" -Fallback "Use the 1C webinst.exe located next to the selected 1cv8.exe, or set WEBINST_PATH only for a nonstandard 1C platform layout.")

        $apacheDetail = if ($apacheSettings.apacheFound) {
            "Config: $($apacheSettings.httpdConfPath); DocumentRoot: $($apacheSettings.documentRoot); URL base: $($apacheSettings.publicationUrlBase)"
        } elseif ($apacheSettings.manualPublicationRoot) {
            "Manual publication root: $($apacheSettings.publicationRoot); URL base: $($apacheSettings.publicationUrlBase)"
        } else {
            $apacheSettings.message
        }
        $results += New-ToolResult `
            -Id "apache-httpd" `
            -Name "Web server config" `
            -Required $true `
            -Ok ([bool]($apacheSettings.apacheFound -or $apacheSettings.manualPublicationRoot)) `
            -Detail $apacheDetail `
            -Offer (Get-ToolOffer -Id "apache-webinst" -Fallback "Prepare the web server outside ITL workflow, then run configure-web-publication or detect-web-publication.")

        $publicationDetail = if ($apacheSettings.publicationRoot) {
            "$($apacheSettings.publicationRoot) -> $($apacheSettings.publicationUrlBase)"
        } else {
            "Publication root could not be derived from the current web server settings."
        }
        $results += New-ToolResult `
            -Id "web-publication" `
            -Name "Web publication target" `
            -Required $true `
            -Ok (-not [string]::IsNullOrWhiteSpace([string]$apacheSettings.publicationRoot)) `
            -Detail $publicationDetail `
            -Offer "Set WEB_PUBLICATION_ROOT and WEB_PUBLICATION_URL_BASE, or run configure-web-publication."
    }

    $missingRequired = @()
    foreach ($result in $results) {
        if ($result.ok) {
            Write-Host "[OK] $($result.name): $($result.detail)"
        } else {
            $level = if ($result.required) { "MISSING" } else { "OPTIONAL" }
            Write-Host "[$level] $($result.name): $($result.detail)"
            if ($result.offer) {
                Write-Host "Suggested install/setup:"
                Write-Host $result.offer
            }
            if ($result.required) {
                $missingRequired += $result
            }
        }
    }

    if ($StopOnMissing -and $missingRequired.Count -gt 0) {
        throw "Required tools are missing. Install or configure them, then rerun this action."
    }
}

function List-Platforms {
    Write-Section "Installed 1C platforms"
    $platforms = @(Find-Installed1CPlatforms)
    if ($platforms.Count -eq 0) {
        Write-Host "No installed 1C platform versions were found under C:\Program Files\1cv8 or C:\Program Files (x86)\1cv8."
        Write-Host "Install 1C:Enterprise platform manually or enter the full path to bin\1cv8.exe."
        return
    }

    $index = 1
    foreach ($platform in $platforms) {
        Write-Host "$index. Version: $($platform.version)"
        Write-Host "   bin: $($platform.binPath)"
        Write-Host "   1cv8.exe: $($platform.exePath)"
        $index++
    }
}

function Assert-InfoBaseAvailable {
    param(
        [string]$Kind,
        [string]$Path,
        [string]$SettingName = "infobase path"
    )

    if ($Kind -eq "file") {
        $resolvedPath = Resolve-InfoBasePath $Path
        if (-not $resolvedPath) {
            throw "File infobase path is empty: $SettingName"
        }
        if (-not (Test-Path -LiteralPath $resolvedPath -PathType Container)) {
            throw "File infobase directory was not found: $resolvedPath. Check $SettingName before running 1C Designer."
        }

        $dbFile = Join-Path $resolvedPath "1Cv8.1CD"
        if (-not (Test-Path -LiteralPath $dbFile -PathType Leaf)) {
            throw "File infobase database file was not found: $dbFile. Check $SettingName; the helper will not let 1C create a new empty infobase during this workflow."
        }
    } elseif ($Kind -eq "server") {
        Require-Value $SettingName $Path | Out-Null
    } else {
        throw "Unknown infobase kind: $Kind"
    }
}

function New-InfobaseArgs {
    param(
        [string]$Kind,
        [string]$Path,
        [string]$User,
        [string]$Password
    )

    $args = @()
    if ($Kind -eq "file") {
        $args += @("/F", (Resolve-InfoBasePath $Path))
    } elseif ($Kind -eq "server") {
        $args += @("/S", $Path)
    } else {
        throw "Unknown infobase kind: $Kind"
    }

    $Password = ConvertFrom-OptionalPasswordAnswer $Password
    if ($User) {
        $args += @("/N", $User)
    }
    if (-not [string]::IsNullOrEmpty($Password)) {
        $args += @("/P", $Password)
    }

    return $args
}

function ConvertFrom-OptionalPasswordAnswer {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) {
        return ""
    }

    $trimmed = $Value.Trim()
    $noMarker = -join ([char[]](0x043D, 0x0435, 0x0442))
    if ($trimmed -eq "-" -or [string]::Equals($trimmed, $noMarker, [System.StringComparison]::OrdinalIgnoreCase)) {
        return ""
    }

    return $Value
}

function ConvertTo-NativeEmptyStringArgument {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) {
        return ""
    }

    return $Value
}

function ConvertTo-NativeCommandLineArgument {
    param([AllowNull()][string]$Argument)

    if ($null -eq $Argument -or $Argument.Length -eq 0) {
        return '""'
    }

    if ($Argument -notmatch '[\s"]') {
        return $Argument
    }

    $escaped = $Argument -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

function Join-NativeCommandLineArguments {
    param([string[]]$Arguments)

    $quoted = @()
    foreach ($arg in $Arguments) {
        $quoted += ConvertTo-NativeCommandLineArgument $arg
    }

    return ($quoted -join " ")
}

function Format-SafeCommandLine {
    param(
        [string]$Command,
        [string[]]$Arguments
    )

    $secretKeys = @("/P", "/ConfigurationRepositoryP")
    $parts = @((ConvertTo-NativeCommandLineArgument $Command))
    $maskNext = $false
    foreach ($arg in $Arguments) {
        if ($maskNext) {
            $parts += "<hidden>"
            $maskNext = $false
            continue
        }

        $parts += ConvertTo-NativeCommandLineArgument $arg
        if ($secretKeys -contains $arg) {
            $maskNext = $true
        }
    }

    return ($parts -join " ")
}

function Invoke-NativeProcessAndWaitResult {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [int]$TimeoutSeconds = 0,
        [scriptblock]$OnTimeout = $null,
        [scriptblock]$CompletionProbe = $null,
        [ValidateRange(0, 300)][int]$CompletionGraceSeconds = 10
    )

    $script:LastNativeProcessStarted = $false
    $argumentLine = Join-NativeCommandLineArguments -Arguments $Arguments
    $process = Start-Process `
        -FilePath $FilePath `
        -ArgumentList $argumentLine `
        -WorkingDirectory $script:ProjectRoot `
        -WindowStyle Hidden `
        -PassThru

    if ($null -eq $process) {
        throw "Failed to start process: $FilePath"
    }

    $script:LastNativeProcessStarted = $true
    $script:LastProcessId = $process.Id
    $script:LastProcessTimedOut = $false
    $completedByProbe = $false
    if ($TimeoutSeconds -gt 0) {
        if ($null -ne $CompletionProbe) {
            $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
            $probeObservedAt = $null
            $finished = $process.HasExited
            while (-not $finished -and [DateTime]::UtcNow -lt $deadline) {
                $probeComplete = $false
                try {
                    $probeComplete = [bool](& $CompletionProbe)
                } catch {
                    $probeComplete = $false
                }
                if ($probeComplete) {
                    if ($null -eq $probeObservedAt) {
                        $probeObservedAt = [DateTime]::UtcNow
                    }
                    if (([DateTime]::UtcNow - $probeObservedAt).TotalSeconds -ge $CompletionGraceSeconds) {
                        $completedByProbe = $true
                        Write-Host "Process result artifacts are complete; stopping lingering process PID $($process.Id)."
                        try {
                            if (-not $process.HasExited) {
                                Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
                            }
                        } catch {
                        }
                        try {
                            $process.WaitForExit(10000) | Out-Null
                        } catch {
                        }
                        $finished = $true
                        break
                    }
                } else {
                    $probeObservedAt = $null
                }
                $finished = $process.WaitForExit(250)
            }
        } else {
            $finished = $process.WaitForExit($TimeoutSeconds * 1000)
        }
        if (-not $finished) {
            $script:LastProcessTimedOut = $true
            if ($null -ne $OnTimeout) {
                & $OnTimeout
            }
            try {
                if (-not $process.HasExited) {
                    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
                }
            } catch {
            }
            try {
                $process.WaitForExit(10000) | Out-Null
            } catch {
            }
        }
    } else {
        $process.WaitForExit()
    }

    $process.Refresh()
    return [pscustomobject]@{
        processId = $process.Id
        exitCode = $(if ($script:LastProcessTimedOut) { -1 } elseif ($completedByProbe) { 0 } else { $process.ExitCode })
        timedOut = $script:LastProcessTimedOut
        completedByProbe = $completedByProbe
    }
}

function Invoke-NativeProcessAndWait {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )

    $result = Invoke-NativeProcessAndWaitResult -FilePath $FilePath -Arguments $Arguments
    return $result.exitCode
}

function Invoke-VisibleNativeProcessAndWait {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )

    $argumentLine = Join-NativeCommandLineArguments -Arguments $Arguments
    $process = Start-Process `
        -FilePath $FilePath `
        -ArgumentList $argumentLine `
        -WorkingDirectory $script:ProjectRoot `
        -PassThru

    if ($null -eq $process) {
        throw "Failed to start process: $FilePath"
    }

    $script:LastProcessId = $process.Id
    $process.WaitForExit()
    $process.Refresh()
    return $process.ExitCode
}

function Start-NativeProcessBackground {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )

    $argumentLine = Join-NativeCommandLineArguments -Arguments $Arguments
    $process = Start-Process `
        -FilePath $FilePath `
        -ArgumentList $argumentLine `
        -WorkingDirectory $script:ProjectRoot `
        -WindowStyle Hidden `
        -PassThru

    if ($null -eq $process) {
        throw "Failed to start process: $FilePath"
    }

    return $process
}

function Invoke-Designer {
    param(
        [string]$InfoBasePath,
        [string]$InfoBaseKind,
        [string[]]$DesignerArgs,
        [string]$User = (Get-EnvValue -Name "IB_USER"),
        [string]$Password = (Get-EnvValue -Name "IB_PASSWORD")
    )

    $platformPath = Get-PlatformPath
    if (-not (Test-Path -LiteralPath $platformPath)) {
        throw "1cv8.exe was not found: $platformPath"
    }

    Assert-InfoBaseAvailable -Kind $InfoBaseKind -Path $InfoBasePath -SettingName "infobase path"

    $logsPath = Resolve-ProjectPath (Get-ConfigValue -Path "logsPath" -Default "logs/1c")
    New-Item -ItemType Directory -Force -Path $logsPath | Out-Null
    $logPath = New-TimestampedFilePath -Directory $logsPath -Prefix "1c-" -Extension ".log"
    $script:LastLogPath = $logPath

    $ibArgs = New-InfobaseArgs -Kind $InfoBaseKind -Path $InfoBasePath -User $User -Password $Password
    $args = @("DESIGNER") + $ibArgs + @("/DisableStartupMessages", "/Out", $logPath) + $DesignerArgs

    Write-Host "1C command: $(Format-SafeCommandLine -Command $platformPath -Arguments $args)"
    Write-Host "1C log: $logPath"

    $exitCode = Invoke-NativeProcessAndWait -FilePath $platformPath -Arguments $args
    if ($exitCode -ne 0) {
        throw "1C Designer failed with exit code $exitCode. Log: $logPath"
    }

    return $logPath
}

function Invoke-DesignerInteractive {
    param(
        [string]$InfoBasePath,
        [string]$InfoBaseKind,
        [string]$User = (Get-EnvValue -Name "IB_USER"),
        [string]$Password = (Get-EnvValue -Name "IB_PASSWORD")
    )

    $platformPath = Get-PlatformPath
    if (-not (Test-Path -LiteralPath $platformPath)) {
        throw "1cv8.exe was not found: $platformPath"
    }

    Assert-InfoBaseAvailable -Kind $InfoBaseKind -Path $InfoBasePath -SettingName "infobase path"

    $logsPath = Resolve-ProjectPath (Get-ConfigValue -Path "logsPath" -Default "logs/1c")
    New-Item -ItemType Directory -Force -Path $logsPath | Out-Null
    $logPath = New-TimestampedFilePath -Directory $logsPath -Prefix "1c-designer-interactive-" -Extension ".log"
    $script:LastLogPath = $logPath

    $ibArgs = New-InfobaseArgs -Kind $InfoBaseKind -Path $InfoBasePath -User $User -Password $Password
    $args = @("DESIGNER") + $ibArgs + @("/DisableStartupMessages", "/Out", $logPath)

    Write-Host "1C command: $(Format-SafeCommandLine -Command $platformPath -Arguments $args)"
    Write-Host "1C log: $logPath"

    $exitCode = Invoke-VisibleNativeProcessAndWait -FilePath $platformPath -Arguments $args
    if ($exitCode -ne 0) {
        throw "1C Designer failed with exit code $exitCode. Log: $logPath"
    }

    return $logPath
}

function Start-EnterpriseBackground {
    param(
        [string]$InfoBasePath,
        [string]$InfoBaseKind,
        [string[]]$EnterpriseArgs,
        [switch]$UseTestManager,
        [string]$User = (Get-EnvValue -Name "IB_USER"),
        [string]$Password = (Get-EnvValue -Name "IB_PASSWORD")
    )

    $platformPath = Get-PlatformPath
    if (-not (Test-Path -LiteralPath $platformPath)) {
        throw "1cv8.exe was not found: $platformPath"
    }

    Assert-InfoBaseAvailable -Kind $InfoBaseKind -Path $InfoBasePath -SettingName "infobase path"

    $logsPath = Resolve-ProjectPath (Get-ConfigValue -Path "logsPath" -Default "logs/1c")
    New-Item -ItemType Directory -Force -Path $logsPath | Out-Null
    $logPath = New-TimestampedFilePath -Directory $logsPath -Prefix "1c-enterprise-mcp-" -Extension ".log"
    $script:LastLogPath = $logPath

    $ibArgs = New-InfobaseArgs -Kind $InfoBaseKind -Path $InfoBasePath -User $User -Password $Password
    $args = @("ENTERPRISE")
    if ($UseTestManager) {
        $args += "/TESTMANAGER"
    }
    $args += $ibArgs + @("/DisableStartupMessages", "/Out", $logPath) + $EnterpriseArgs

    Write-Host "1C command: $(Format-SafeCommandLine -Command $platformPath -Arguments $args)"
    Write-Host "1C log: $logPath"

    $process = Start-NativeProcessBackground -FilePath $platformPath -Arguments $args
    return [pscustomobject]@{
        process = $process
        logPath = $logPath
    }
}

function Invoke-Enterprise {
    param(
        [string]$InfoBasePath,
        [string]$InfoBaseKind,
        [string[]]$EnterpriseArgs,
        [int]$TestClientPort = 0,
        [int]$VanessaTestPort = 0,
        [int]$TimeoutSeconds = 0,
        [scriptblock]$OnTimeout = $null,
        [scriptblock]$CompletionProbe = $null,
        [ValidateRange(0, 300)][int]$CompletionGraceSeconds = 10,
        [string]$User = (Get-EnvValue -Name "IB_USER"),
        [string]$Password = (Get-EnvValue -Name "IB_PASSWORD")
    )

    $platformPath = Get-PlatformPath
    if (-not (Test-Path -LiteralPath $platformPath)) {
        throw "1cv8.exe was not found: $platformPath"
    }

    Assert-InfoBaseAvailable -Kind $InfoBaseKind -Path $InfoBasePath -SettingName "infobase path"

    $logsPath = Resolve-ProjectPath (Get-ConfigValue -Path "logsPath" -Default "logs/1c")
    New-Item -ItemType Directory -Force -Path $logsPath | Out-Null
    $logPath = New-TimestampedFilePath -Directory $logsPath -Prefix "1c-enterprise-" -Extension ".log"
    $script:LastLogPath = $logPath

    $ibArgs = New-InfobaseArgs -Kind $InfoBaseKind -Path $InfoBasePath -User $User -Password $Password
    $args = @("ENTERPRISE") + $ibArgs + @("/DisableStartupMessages")
    $effectiveTestClientPort = 0
    if ($TestClientPort -gt 0) {
        $effectiveTestClientPort = $TestClientPort
    } elseif ($VanessaTestPort -gt 0) {
        $effectiveTestClientPort = $VanessaTestPort
    }
    if ($effectiveTestClientPort -gt 0) {
        $args += "/TESTMANAGER"
    }
    $args += @("/Out", $logPath) + $EnterpriseArgs

    Write-Host "1C command: $(Format-SafeCommandLine -Command $platformPath -Arguments $args)"
    Write-Host "1C log: $logPath"

    $result = Invoke-NativeProcessAndWaitResult `
        -FilePath $platformPath `
        -Arguments $args `
        -TimeoutSeconds $TimeoutSeconds `
        -OnTimeout $OnTimeout `
        -CompletionProbe $CompletionProbe `
        -CompletionGraceSeconds $CompletionGraceSeconds
    if ($result.timedOut) {
        throw "1C Enterprise timed out after $TimeoutSeconds seconds. PID: $($result.processId). Log: $logPath"
    }
    if ($result.exitCode -ne 0) {
        throw "1C Enterprise failed with exit code $($result.exitCode). PID: $($result.processId). Log: $logPath"
    }

    return $logPath
}
