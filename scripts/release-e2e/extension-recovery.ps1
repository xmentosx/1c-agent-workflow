# Stateless contracts called only by the existing mutating Release owner.
# The checkpoint owner persists returned ownership; this module owns no journal.
function Get-ReleaseExtensionRecoveryValue {
    param([object]$Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [Collections.IDictionary]) { return $Object[$Name] }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function Stop-ReleaseExtensionRecovery {
    param([string]$Reason)
    throw "RELEASE_EXTENSION_RECOVERY_REJECTED: $Reason"
}

function Get-ReleaseExtensionRecoveryPath {
    param([string]$Root, [string]$Path, [switch]$AllowRoot)
    if (-not $Root -or -not $Path) { Stop-ReleaseExtensionRecovery 'missing path binding' }
    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $absolute = [IO.Path]::GetFullPath($(if ([IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $rootPath $Path }))
    if (-not ($AllowRoot -and $absolute.Equals($rootPath, [StringComparison]::OrdinalIgnoreCase)) -and
        -not $absolute.StartsWith($rootPath + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        Stop-ReleaseExtensionRecovery "path escapes owned root: $Path"
    }
    $cursor = $absolute
    while ($cursor -and $cursor.Length -ge $rootPath.Length) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Stop-ReleaseExtensionRecovery "reparse path is not owned: $cursor" }
        }
        if ($cursor.Equals($rootPath, [StringComparison]::OrdinalIgnoreCase)) { break }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
    }
    return $absolute
}

function Get-ReleaseExtensionRecoveryFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Stop-ReleaseExtensionRecovery "missing file: $Path" }
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return [ordered]@{ path = $Path; sha256 = ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant(); bytes = $stream.Length }
    } finally { $sha.Dispose(); $stream.Dispose() }
}

function Read-ReleaseExtensionRecoveryJson {
    param([string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { return ($text | ConvertFrom-Json -DateKind String -ErrorAction Stop) }
    return ($text | ConvertFrom-Json -ErrorAction Stop)
}

function Assert-ReleaseExtensionRecoveryFile {
    param([string]$Path, [string]$Sha256, [object]$Bytes = $null)
    if ($Sha256 -cnotmatch '^[0-9a-f]{64}$') { Stop-ReleaseExtensionRecovery "invalid file SHA: $Path" }
    $actual = Get-ReleaseExtensionRecoveryFile -Path $Path
    if ($actual.sha256 -cne $Sha256 -or ($null -ne $Bytes -and $actual.bytes -ne [long]$Bytes)) { Stop-ReleaseExtensionRecovery "file bytes changed: $Path" }
    return $actual
}

function Get-ReleaseExtensionRecoveryContext {
    param([object]$Context)
    $binding = [ordered]@{}
    foreach ($name in @('projectRoot', 'worktreePath', 'commonGitPath', 'branch', 'expectedHead', 'checkpointPath', 'runId', 'infoBaseKind', 'infoBasePath')) {
        $value = [string](Get-ReleaseExtensionRecoveryValue $Context $name)
        if (-not $value) { Stop-ReleaseExtensionRecovery "missing context field: $name" }
        $binding[$name] = $value
    }
    if ($binding.infoBaseKind -notin @('file', 'server')) { Stop-ReleaseExtensionRecovery 'unknown infobase kind' }
    if ($binding.expectedHead -cnotmatch '^[0-9a-f]{40}$') { Stop-ReleaseExtensionRecovery 'invalid expected HEAD' }
    foreach ($name in @('projectRoot', 'worktreePath', 'commonGitPath', 'checkpointPath')) { $binding[$name] = [IO.Path]::GetFullPath($binding[$name]) }
    if ($binding.infoBaseKind -eq 'file') { $binding.infoBasePath = [IO.Path]::GetFullPath($binding.infoBasePath) }
    return $binding
}

function Get-ReleaseExtensionRecoveryIdentity {
    param([object]$Checkpoint)
    $identity = Get-ReleaseExtensionRecoveryValue $Checkpoint 'identity'
    $copy = [ordered]@{}
    foreach ($name in @('projectRoot', 'worktreePath', 'branch', 'workflowCommit', 'workflowTree', 'runnerSha256', 'aiRulesCommit', 'aiRulesTree', 'helperSha256', 'projectConfigSha256', 'clientSelection')) {
        $value = [string](Get-ReleaseExtensionRecoveryValue $identity $name)
        if (-not $value) { Stop-ReleaseExtensionRecovery "missing original checkpoint identity: $name" }
        $copy[$name] = $value
    }
    return $copy
}

function Assert-ReleaseExtensionRecoveryBinding {
    param([object]$Checkpoint, [object]$Context, [object]$Ownership, [Parameter(Mandatory = $true)][scriptblock]$AssertCompatibility)
    $binding = Get-ReleaseExtensionRecoveryContext $Context
    $identity = Get-ReleaseExtensionRecoveryValue $Checkpoint 'identity'
    if ((Get-ReleaseExtensionRecoveryValue $Checkpoint 'schemaVersion') -ne 3 -or
        [string](Get-ReleaseExtensionRecoveryValue $Checkpoint 'runId') -cne $binding.runId -or
        [string](Get-ReleaseExtensionRecoveryValue $Checkpoint 'expectedHead') -cne $binding.expectedHead) { Stop-ReleaseExtensionRecovery 'checkpoint/run/HEAD binding changed' }
    foreach ($name in @('projectRoot', 'worktreePath', 'branch')) {
        if (-not ([string](Get-ReleaseExtensionRecoveryValue $identity $name)).Equals($binding[$name], [StringComparison]::OrdinalIgnoreCase)) { Stop-ReleaseExtensionRecovery "checkpoint identity changed: $name" }
    }
    if ($null -ne $Ownership) {
        $prior = Get-ReleaseExtensionRecoveryValue $Ownership 'context'
        foreach ($name in $binding.Keys) {
            if (-not ([string](Get-ReleaseExtensionRecoveryValue $prior $name)).Equals($binding[$name], [StringComparison]::OrdinalIgnoreCase)) { Stop-ReleaseExtensionRecovery "ownership binding changed: $name" }
        }
        foreach ($name in @('workflowCommit', 'workflowTree', 'runnerSha256', 'aiRulesCommit', 'aiRulesTree', 'helperSha256', 'projectConfigSha256', 'clientSelection')) {
            if ([string](Get-ReleaseExtensionRecoveryValue (Get-ReleaseExtensionRecoveryValue $Ownership 'identity') $name) -cne [string](Get-ReleaseExtensionRecoveryValue $identity $name)) { Stop-ReleaseExtensionRecovery "original identity changed: $name" }
        }
    }
    if (-not (Get-Command Get-RepositoryGitPathList -ErrorAction SilentlyContinue)) { Stop-ReleaseExtensionRecovery 'shared Git path-list contract is not loaded' }
    foreach ($root in @($binding.projectRoot, $binding.worktreePath)) {
        $common = Get-RepositoryCommonGitDirectory -RepositoryRoot $root
        if (-not $common.Equals($binding.commonGitPath, [StringComparison]::OrdinalIgnoreCase)) { Stop-ReleaseExtensionRecovery 'stand and main do not share the owned Git directory' }
    }
    $head = (Invoke-RepositoryGit -RepositoryRoot $binding.worktreePath -Arguments @('rev-parse', 'HEAD')).stdout.Trim()
    $branch = (Invoke-RepositoryGit -RepositoryRoot $binding.worktreePath -Arguments @('symbolic-ref', '--short', 'HEAD')).stdout.Trim()
    if ($head -cne $binding.expectedHead -or $branch -cne $binding.branch) { Stop-ReleaseExtensionRecovery 'actual branch/HEAD changed' }
    $null = Get-ReleaseExtensionRecoveryPath -Root (Join-Path $binding.worktreePath '.agent-1c') -Path $binding.checkpointPath
    # This existing-owner callback validates supported source/helper/fork continuation,
    # and current state/env against the interrupted or already-restored owner state.
    & $AssertCompatibility $Context $Checkpoint $Ownership | Out-Null
    return $binding
}

function Get-ReleaseExtensionRecoverySupport {
    param([object]$Checkpoint, [object]$Context)
    $binding = Get-ReleaseExtensionRecoveryContext $Context
    # Existing qualified capability-cache imports retain their exact support
    # records under this same worktree's runs; they need not be in this run.
    $supportRoot = Join-Path $binding.worktreePath '.agent-1c/runs'
    $snapshot = Get-ReleaseExtensionRecoveryValue (Get-ReleaseExtensionRecoveryValue $Checkpoint 'snapshots') 'postConfig'
    $state = Get-ReleaseExtensionRecoveryValue (Get-ReleaseExtensionRecoveryValue $Checkpoint 'stateFiles') 'postConfig'
    $support = [ordered]@{}
    foreach ($item in @(
        @{ name = 'snapshot'; path = (Get-ReleaseExtensionRecoveryValue $snapshot 'path'); sha = (Get-ReleaseExtensionRecoveryValue $snapshot 'sha256') },
        @{ name = 'state'; path = (Get-ReleaseExtensionRecoveryValue $state 'stateCopyPath'); sha = (Get-ReleaseExtensionRecoveryValue $state 'stateSha256') },
        @{ name = 'env'; path = (Get-ReleaseExtensionRecoveryValue $state 'envCopyPath'); sha = (Get-ReleaseExtensionRecoveryValue $state 'envSha256') }
    )) {
        $path = Get-ReleaseExtensionRecoveryPath -Root $supportRoot -Path ([string]$item.path)
        $support[$item.name] = Assert-ReleaseExtensionRecoveryFile -Path $path -Sha256 ([string]$item.sha)
    }
    $actualState = Get-ReleaseExtensionRecoveryPath -Root (Join-Path $binding.worktreePath '.agent-1c') -Path ([string](Get-ReleaseExtensionRecoveryValue $state 'actualStatePath'))
    $actualEnv = [IO.Path]::GetFullPath([string](Get-ReleaseExtensionRecoveryValue $state 'actualEnvPath'))
    if (-not $actualEnv.Equals((Join-Path $binding.worktreePath '.dev.env'), [StringComparison]::OrdinalIgnoreCase)) { Stop-ReleaseExtensionRecovery 'state/env destination changed' }
    $null = Get-ReleaseExtensionRecoveryPath -Root $binding.worktreePath -Path $actualEnv
    $saved = Read-ReleaseExtensionRecoveryJson $support.state.path
    if ([string](Get-ReleaseExtensionRecoveryValue $saved 'devBranchKind') -cne 'configuration' -or
        -not ([string](Get-ReleaseExtensionRecoveryValue $saved 'devBranchInfoBasePath')).Equals($binding.infoBasePath, [StringComparison]::OrdinalIgnoreCase)) { Stop-ReleaseExtensionRecovery 'post-config state target changed' }
    $support.actualStatePath = $actualState
    $support.actualEnvPath = $actualEnv
    return $support
}

function Get-ReleaseExtensionRecoveryWriteSet {
    param([object]$Context, [string]$ExtensionName, [AllowEmptyCollection()][string[]]$WriteSet)
    if (-not $ExtensionName -or $ExtensionName -match '[\\/:\x00-\x1f]' -or $ExtensionName -in @('.', '..')) { Stop-ReleaseExtensionRecovery 'invalid extension name' }
    $binding = Get-ReleaseExtensionRecoveryContext $Context
    $residue = 'src/cfe/' + $ExtensionName
    $root = Get-ReleaseExtensionRecoveryPath -Root $binding.worktreePath -Path $residue
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $paths = @()
    foreach ($path in @($WriteSet)) {
        if (-not $path -or [IO.Path]::IsPathRooted($path) -or $path.Contains('\') -or $path.Split('/') -contains '..' -or $path.Split('/') -contains '.') { Stop-ReleaseExtensionRecovery 'write set must contain canonical relative file paths' }
        $absolute = Get-ReleaseExtensionRecoveryPath -Root $root -Path (Join-Path $binding.worktreePath $path)
        if (-not $seen.Add($path)) { Stop-ReleaseExtensionRecovery 'duplicate write-set path' }
        $paths += $path
    }
    return [ordered]@{ residuePath = $residue; root = $root; paths = @($paths | Sort-Object) }
}

function Get-ReleaseExtensionRecoveryRuntimeFiles {
    param([object]$Checkpoint, [object]$Context)
    $support = Get-ReleaseExtensionRecoverySupport $Checkpoint $Context
    $state = Read-ReleaseExtensionRecoveryJson $support.actualStatePath
    if (-not ([string](Get-ReleaseExtensionRecoveryValue $state 'devBranchInfoBasePath')).Equals([string](Get-ReleaseExtensionRecoveryValue $Context 'infoBasePath'), [StringComparison]::OrdinalIgnoreCase)) { Stop-ReleaseExtensionRecovery 'current branch state target changed' }
    return [ordered]@{ state = (Get-ReleaseExtensionRecoveryFile $support.actualStatePath); env = (Get-ReleaseExtensionRecoveryFile $support.actualEnvPath) }
}

function Get-ReleaseExtensionRecoveryResidueFiles {
    param([object]$Context, [object]$Set)
    if (-not (Test-Path -LiteralPath $Set.root)) { return @() }
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($Set.root)
    $files = @()
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        $null = Get-ReleaseExtensionRecoveryPath -Root $Set.root -Path $directory -AllowRoot
        foreach ($item in @(Get-ChildItem -LiteralPath $directory -Force)) {
            $absolute = Get-ReleaseExtensionRecoveryPath -Root $Set.root -Path $item.FullName
            $relative = $absolute.Substring(([string](Get-ReleaseExtensionRecoveryValue $Context 'worktreePath')).TrimEnd('\', '/').Length + 1).Replace('\', '/')
            if ($item.PSIsContainer) {
                if (@($Set.paths | Where-Object { $_.StartsWith($relative + '/', [StringComparison]::Ordinal) }).Count -eq 0) { Stop-ReleaseExtensionRecovery "undeclared generated directory: $relative" }
                $pending.Push($absolute)
            } else {
                if ($Set.paths -cnotcontains $relative) { Stop-ReleaseExtensionRecovery "undeclared generated file: $relative" }
                $files += $item
            }
        }
    }
    return $files
}

function Assert-ReleaseExtensionRecoveryDirtySet {
    param([object]$Context, [string[]]$AllowedPaths)
    $binding = Get-ReleaseExtensionRecoveryContext $Context
    foreach ($entry in @(Get-RepositoryGitPathList -RepositoryRoot $binding.worktreePath -Arguments @('status', '--porcelain=v1', '--untracked-files=all', '-z'))) {
        if ($entry.Length -lt 4 -or $entry.Substring(0, 3) -cne '?? ' -or $AllowedPaths -cnotcontains $entry.Substring(3)) { Stop-ReleaseExtensionRecovery "foreign or tracked dirty path: $entry" }
    }
}

function Assert-ReleaseExtensionRecoveryStop {
    param([object]$Context, [object]$Ownership, [Parameter(Mandatory = $true)][scriptblock]$GetStopEvidence)
    $observation = & $GetStopEvidence $Context $Ownership
    $invocation = Get-ReleaseExtensionRecoveryValue $Ownership 'invocation'
    $childId = Get-ReleaseExtensionRecoveryValue $invocation 'childProcessId'
    $childStart = [datetime]::MinValue
    if (($childId -isnot [int] -and $childId -isnot [long]) -or $childId -le 0) { Stop-ReleaseExtensionRecovery 'child invocation was not bound by the Release owner' }
    $invocationFields = @('childProcessId', 'childStartedAtUtc')
    $legacyNoCreation = Get-ReleaseExtensionRecoveryValue $invocation 'processCreationUnavailable'
    if ($legacyNoCreation -is [bool] -and $legacyNoCreation) {
        $approved = Get-ReleaseExtensionRecoveryValue $Ownership 'approvedLegacyManifest'
        if ($null -eq $approved) { Stop-ReleaseExtensionRecovery 'missing process creation requires explicit approved legacy ownership' }
        $null = Assert-ReleaseExtensionRecoveryFile ([string](Get-ReleaseExtensionRecoveryValue $approved 'path')) ([string](Get-ReleaseExtensionRecoveryValue $approved 'sha256'))
        $operationPath = Get-ReleaseExtensionRecoveryPath -Root (Join-Path ([string](Get-ReleaseExtensionRecoveryValue $Context 'worktreePath')) '.agent-1c') -Path ([string](Get-ReleaseExtensionRecoveryValue $invocation 'legacyOperationRecordPath'))
        $null = Assert-ReleaseExtensionRecoveryFile $operationPath ([string](Get-ReleaseExtensionRecoveryValue $invocation 'legacyOperationRecordSha256'))
        $operation = Read-ReleaseExtensionRecoveryJson $operationPath
        if ([string](Get-ReleaseExtensionRecoveryValue $operation 'status') -cne 'failed' -or [string](Get-ReleaseExtensionRecoveryValue $operation 'action') -cne 'release-e2e-extension-smoke' -or
            -not ([string](Get-ReleaseExtensionRecoveryValue $operation 'projectRoot')).Equals([string](Get-ReleaseExtensionRecoveryValue $Context 'worktreePath'), [StringComparison]::OrdinalIgnoreCase) -or
            [string](Get-ReleaseExtensionRecoveryValue $operation 'branch') -cne [string](Get-ReleaseExtensionRecoveryValue $Context 'branch') -or
            [string](Get-ReleaseExtensionRecoveryValue $operation 'pid') -cne [string]$childId) { Stop-ReleaseExtensionRecovery 'legacy closed lifecycle record scope changed' }
        $started = [DateTimeOffset]::MinValue; $finished = [DateTimeOffset]::MinValue
        if ([string](Get-ReleaseExtensionRecoveryValue $operation 'startedAt') -cne [string](Get-ReleaseExtensionRecoveryValue $invocation 'operationStartedAt') -or
            [string](Get-ReleaseExtensionRecoveryValue $operation 'finishedAt') -cne [string](Get-ReleaseExtensionRecoveryValue $invocation 'operationFinishedAt') -or
            -not [DateTimeOffset]::TryParse([string](Get-ReleaseExtensionRecoveryValue $operation 'startedAt'), [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$started) -or
            -not [DateTimeOffset]::TryParse([string](Get-ReleaseExtensionRecoveryValue $operation 'finishedAt'), [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$finished) -or $finished -lt $started) { Stop-ReleaseExtensionRecovery 'legacy lifecycle record has no exact completed interval' }
        $invocationFields = @('childProcessId', 'processCreationUnavailable', 'legacyOperationRecordPath', 'legacyOperationRecordSha256', 'operationStartedAt', 'operationFinishedAt')
    } elseif (-not [datetime]::TryParse([string](Get-ReleaseExtensionRecoveryValue $invocation 'childStartedAtUtc'), [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$childStart)) {
        Stop-ReleaseExtensionRecovery 'child invocation was not bound by the Release owner'
    }
    $path = Get-ReleaseExtensionRecoveryPath -Root (Join-Path ([string](Get-ReleaseExtensionRecoveryValue $Context 'worktreePath')) '.agent-1c') -Path ([string](Get-ReleaseExtensionRecoveryValue $observation 'evidencePath'))
    $record = Assert-ReleaseExtensionRecoveryFile -Path $path -Sha256 ([string](Get-ReleaseExtensionRecoveryValue $observation 'evidenceSha256'))
    $raw = Read-ReleaseExtensionRecoveryJson $path
    foreach ($source in @($observation, $raw)) {
        foreach ($name in @('runId', 'projectRoot', 'worktreePath', 'branch', 'infoBaseKind', 'infoBasePath')) {
            if (-not ([string](Get-ReleaseExtensionRecoveryValue $source $name)).Equals([string](Get-ReleaseExtensionRecoveryValue $Context $name), [StringComparison]::OrdinalIgnoreCase)) { Stop-ReleaseExtensionRecovery "closed process scope changed: $name" }
        }
        foreach ($name in $invocationFields) {
            if ([string](Get-ReleaseExtensionRecoveryValue $source $name) -cne [string](Get-ReleaseExtensionRecoveryValue $invocation $name)) { Stop-ReleaseExtensionRecovery "closed child invocation changed: $name" }
        }
        if ([string](Get-ReleaseExtensionRecoveryValue $source 'action') -cne 'release-e2e-extension-smoke' -or
            (Get-ReleaseExtensionRecoveryValue $source 'launcherExited') -isnot [bool] -or -not (Get-ReleaseExtensionRecoveryValue $source 'launcherExited') -or
            (Get-ReleaseExtensionRecoveryValue $source 'nativeQuiescent') -isnot [bool] -or -not (Get-ReleaseExtensionRecoveryValue $source 'nativeQuiescent')) { Stop-ReleaseExtensionRecovery 'child/native release is not confirmed' }
    }
    $bound = [ordered]@{}
    foreach ($name in (@('runId', 'projectRoot', 'worktreePath', 'branch', 'infoBaseKind', 'infoBasePath', 'action', 'launcherExited', 'nativeQuiescent') + $invocationFields)) {
        $bound[$name] = Get-ReleaseExtensionRecoveryValue $raw $name
    }
    $bound.evidencePath = $record.path
    $bound.evidenceSha256 = $record.sha256
    $bound.evidenceBytes = $record.bytes
    return $bound
}

function New-ReleaseExtensionRecoveryOwnership {
    param([object]$Checkpoint, [object]$Context, [string]$ExtensionName, [AllowEmptyCollection()][string[]]$WriteSet,
        [ValidateSet('release-extension-smoke')][string]$Actor = 'release-extension-smoke', [Parameter(Mandatory = $true)][scriptblock]$AssertCompatibility)
    $binding = Assert-ReleaseExtensionRecoveryBinding $Checkpoint $Context $null $AssertCompatibility
    $set = Get-ReleaseExtensionRecoveryWriteSet $Context $ExtensionName $WriteSet
    Assert-ReleaseExtensionRecoveryDirtySet $Context @()
    if (Test-Path -LiteralPath $set.root) { Stop-ReleaseExtensionRecovery 'predeclared extension root was already present' }
    return [ordered]@{ schemaVersion = 1; id = [guid]::NewGuid().ToString('N'); actor = $Actor; status = 'declared'; context = $binding;
        identity = (Get-ReleaseExtensionRecoveryIdentity $Checkpoint); extensionName = $ExtensionName; residuePath = $set.residuePath;
        writeSet = $set.paths; support = (Get-ReleaseExtensionRecoverySupport $Checkpoint $Context); invocation = $null; files = @(); stopEvidence = $null; runtimeFiles = $null }
}

function Complete-ReleaseExtensionRecoveryOwnership {
    param([object]$Ownership, [object]$Checkpoint, [object]$Context, [Parameter(Mandatory = $true)][scriptblock]$GetStopEvidence, [Parameter(Mandatory = $true)][scriptblock]$AssertCompatibility)
    $null = Assert-ReleaseExtensionRecoveryBinding $Checkpoint $Context $Ownership $AssertCompatibility
    if ((Get-ReleaseExtensionRecoveryValue $Ownership 'schemaVersion') -ne 1 -or [string](Get-ReleaseExtensionRecoveryValue $Ownership 'actor') -cne 'release-extension-smoke' -or [string](Get-ReleaseExtensionRecoveryValue $Ownership 'status') -cne 'declared') { Stop-ReleaseExtensionRecovery 'no trusted pre-child declaration' }
    $set = Get-ReleaseExtensionRecoveryWriteSet $Context ([string](Get-ReleaseExtensionRecoveryValue $Ownership 'extensionName')) @(Get-ReleaseExtensionRecoveryValue $Ownership 'writeSet')
    $support = Get-ReleaseExtensionRecoverySupport $Checkpoint $Context
    foreach ($name in @('snapshot', 'state', 'env')) {
        if ($support[$name].sha256 -cne [string](Get-ReleaseExtensionRecoveryValue (Get-ReleaseExtensionRecoveryValue (Get-ReleaseExtensionRecoveryValue $Ownership 'support') $name) 'sha256')) { Stop-ReleaseExtensionRecovery 'pre-child support changed' }
    }
    $stop = Assert-ReleaseExtensionRecoveryStop $Context $Ownership $GetStopEvidence
    Assert-ReleaseExtensionRecoveryDirtySet $Context $set.paths
    $files = @()
    foreach ($item in @(Get-ReleaseExtensionRecoveryResidueFiles $Context $set)) {
        $relative = $item.FullName.Substring(([string](Get-ReleaseExtensionRecoveryValue $Context 'worktreePath')).TrimEnd('\', '/').Length + 1).Replace('\', '/')
        $record = Get-ReleaseExtensionRecoveryFile $item.FullName
        $files += [ordered]@{ path = $relative; sha256 = $record.sha256; bytes = $record.bytes }
    }
    return [ordered]@{ schemaVersion = 1; id = (Get-ReleaseExtensionRecoveryValue $Ownership 'id'); actor = 'release-extension-smoke'; status = 'sealed';
        context = (Get-ReleaseExtensionRecoveryValue $Ownership 'context'); identity = (Get-ReleaseExtensionRecoveryValue $Ownership 'identity');
        extensionName = (Get-ReleaseExtensionRecoveryValue $Ownership 'extensionName'); residuePath = $set.residuePath; writeSet = $set.paths;
        support = $support; invocation = (Get-ReleaseExtensionRecoveryValue $Ownership 'invocation'); files = $files; stopEvidence = $stop; runtimeFiles = (Get-ReleaseExtensionRecoveryRuntimeFiles $Checkpoint $Context) }
}

function Resolve-ReleaseExtensionRecoveryOwnership {
    param([object]$Checkpoint, [object]$Context, [object]$Invocation, [string]$ApprovedLegacyManifestPath, [string]$ApprovedLegacyManifestSha256,
        [Parameter(Mandatory = $true)][scriptblock]$AssertCompatibility)
    $owned = Get-ReleaseExtensionRecoveryValue $Checkpoint 'extensionRecovery'
    if ($null -ne $owned -and [string](Get-ReleaseExtensionRecoveryValue $owned 'status') -eq 'sealed') {
        $null = Assert-ReleaseExtensionRecoveryBinding $Checkpoint $Context $owned $AssertCompatibility
        return $owned
    }
    if (-not $ApprovedLegacyManifestPath -or -not $ApprovedLegacyManifestSha256) { Stop-ReleaseExtensionRecovery 'legacy residue has no explicit approved manifest and SHA' }
    $manifestRecord = Assert-ReleaseExtensionRecoveryFile -Path $ApprovedLegacyManifestPath -Sha256 $ApprovedLegacyManifestSha256
    $manifest = Read-ReleaseExtensionRecoveryJson $ApprovedLegacyManifestPath
    $binding = Assert-ReleaseExtensionRecoveryBinding $Checkpoint $Context $null $AssertCompatibility
    foreach ($pair in @(@('stand', 'worktreePath'), @('expectedBranch', 'branch'), @('expectedHead', 'expectedHead'), @('checkpoint', 'checkpointPath'))) {
        if (-not ([string](Get-ReleaseExtensionRecoveryValue $manifest $pair[0])).Equals($binding[$pair[1]], [StringComparison]::OrdinalIgnoreCase)) { Stop-ReleaseExtensionRecovery 'approved legacy scope changed' }
    }
    $residue = [string](Get-ReleaseExtensionRecoveryValue $manifest 'residue')
    if ($residue -cnotmatch '^src/cfe/([^/]+)$') { Stop-ReleaseExtensionRecovery 'invalid approved legacy extension root' }
    $extensionName = $Matches[1]
    $files = @(Get-ReleaseExtensionRecoveryValue $manifest 'files')
    $set = Get-ReleaseExtensionRecoveryWriteSet $Context $extensionName @($files | ForEach-Object { [string](Get-ReleaseExtensionRecoveryValue $_ 'path') })
    $support = Get-ReleaseExtensionRecoverySupport $Checkpoint $Context
    foreach ($pair in @(@('postConfigSnapshotSha256', 'snapshot'), @('postConfigStateSha256', 'state'), @('postConfigEnvSha256', 'env'))) {
        if ([string](Get-ReleaseExtensionRecoveryValue $manifest $pair[0]) -cne $support[$pair[1]].sha256) { Stop-ReleaseExtensionRecovery 'approved legacy support changed' }
    }
    return [ordered]@{ schemaVersion = 1; id = 'legacy-' + $manifestRecord.sha256; actor = 'release-extension-smoke'; status = 'sealed';
        context = $binding; identity = (Get-ReleaseExtensionRecoveryIdentity $Checkpoint); extensionName = $extensionName; residuePath = $set.residuePath;
        writeSet = $set.paths; support = $support; invocation = $Invocation; files = $files; approvedLegacyManifest = $manifestRecord;
        runtimeFiles = (Get-ReleaseExtensionRecoveryRuntimeFiles $Checkpoint $Context) }
}

function Invoke-ReleaseExtensionRecovery {
    param([object]$Checkpoint, [object]$Context, [object]$Ownership, [string]$ArchiveRoot,
        [Parameter(Mandatory = $true)][scriptblock]$GetStopEvidence, [Parameter(Mandatory = $true)][scriptblock]$AssertCompatibility,
        [Parameter(Mandatory = $true)][scriptblock]$RestoreSnapshot)
    $binding = Assert-ReleaseExtensionRecoveryBinding $Checkpoint $Context $Ownership $AssertCompatibility
    $stage = Get-ReleaseExtensionRecoveryValue (Get-ReleaseExtensionRecoveryValue $Checkpoint 'stages') 'extension-smoke'
    if ([string](Get-ReleaseExtensionRecoveryValue $stage 'status') -notin @('running', 'failed') -or
        (Get-ReleaseExtensionRecoveryValue $Ownership 'schemaVersion') -ne 1 -or [string](Get-ReleaseExtensionRecoveryValue $Ownership 'actor') -cne 'release-extension-smoke' -or
        [string](Get-ReleaseExtensionRecoveryValue $Ownership 'status') -cne 'sealed') { Stop-ReleaseExtensionRecovery 'only the bound interrupted extension stage can be recovered' }
    $set = Get-ReleaseExtensionRecoveryWriteSet $Context ([string](Get-ReleaseExtensionRecoveryValue $Ownership 'extensionName')) @(Get-ReleaseExtensionRecoveryValue $Ownership 'writeSet')
    if ($set.residuePath -cne [string](Get-ReleaseExtensionRecoveryValue $Ownership 'residuePath')) { Stop-ReleaseExtensionRecovery 'owned residue root changed' }
    $support = Get-ReleaseExtensionRecoverySupport $Checkpoint $Context
    foreach ($name in @('snapshot', 'state', 'env')) {
        $original = Get-ReleaseExtensionRecoveryValue (Get-ReleaseExtensionRecoveryValue $Ownership 'support') $name
        if ($support[$name].path -cne [string](Get-ReleaseExtensionRecoveryValue $original 'path') -or $support[$name].sha256 -cne [string](Get-ReleaseExtensionRecoveryValue $original 'sha256')) { Stop-ReleaseExtensionRecovery 'sealed support changed' }
    }
    $stop = Assert-ReleaseExtensionRecoveryStop $Context $Ownership $GetStopEvidence
    $runtimeFiles = Get-ReleaseExtensionRecoveryRuntimeFiles $Checkpoint $Context
    foreach ($name in @('state', 'env')) {
        $frozen = Get-ReleaseExtensionRecoveryValue (Get-ReleaseExtensionRecoveryValue $Ownership 'runtimeFiles') $name
        if ($runtimeFiles[$name].path -cne [string](Get-ReleaseExtensionRecoveryValue $frozen 'path') -or $runtimeFiles[$name].sha256 -cne [string](Get-ReleaseExtensionRecoveryValue $frozen 'sha256')) { Stop-ReleaseExtensionRecovery 'current state/env changed after sealing' }
    }
    $archive = Get-ReleaseExtensionRecoveryPath -Root (Join-Path $binding.worktreePath '.agent-1c') -Path $ArchiveRoot
    $runRoot = (Split-Path -Parent $binding.checkpointPath).TrimEnd('\', '/')
    if ($archive.Equals($runRoot, [StringComparison]::OrdinalIgnoreCase) -or $archive.StartsWith($runRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { Stop-ReleaseExtensionRecovery 'archive would be evicted with the Release run' }
    $files = @(Get-ReleaseExtensionRecoveryValue $Ownership 'files')
    $legacy = Get-ReleaseExtensionRecoveryValue $Ownership 'approvedLegacyManifest'
    if ($null -ne $legacy) {
        $null = Assert-ReleaseExtensionRecoveryFile ([string](Get-ReleaseExtensionRecoveryValue $legacy 'path')) ([string](Get-ReleaseExtensionRecoveryValue $legacy 'sha256'))
        $approvedFiles = @(Get-ReleaseExtensionRecoveryValue (Read-ReleaseExtensionRecoveryJson ([string](Get-ReleaseExtensionRecoveryValue $legacy 'path'))) 'files')
        if ($approvedFiles.Count -ne $files.Count) { Stop-ReleaseExtensionRecovery 'approved legacy file set changed' }
        foreach ($approved in $approvedFiles) {
            $matching = @($files | Where-Object { [string](Get-ReleaseExtensionRecoveryValue $_ 'path') -ceq [string](Get-ReleaseExtensionRecoveryValue $approved 'path') })
            if ($matching.Count -ne 1 -or [string](Get-ReleaseExtensionRecoveryValue $matching[0] 'sha256') -cne [string](Get-ReleaseExtensionRecoveryValue $approved 'sha256') -or
                [string](Get-ReleaseExtensionRecoveryValue $matching[0] 'bytes') -cne [string](Get-ReleaseExtensionRecoveryValue $approved 'bytes')) { Stop-ReleaseExtensionRecovery 'sealed legacy bytes are not the approved manifest' }
        }
    }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $moves = @()
    foreach ($file in $files) {
        $relative = [string](Get-ReleaseExtensionRecoveryValue $file 'path')
        if ($set.paths -cnotcontains $relative -or -not $seen.Add($relative)) { Stop-ReleaseExtensionRecovery 'sealed file is not in the original write set' }
        $source = Get-ReleaseExtensionRecoveryPath -Root $set.root -Path (Join-Path $binding.worktreePath $relative)
        $destination = Get-ReleaseExtensionRecoveryPath -Root $archive -Path $relative
        $sha = [string](Get-ReleaseExtensionRecoveryValue $file 'sha256')
        $bytes = Get-ReleaseExtensionRecoveryValue $file 'bytes'
        if ($null -eq $bytes -or [long]$bytes -lt 0) { Stop-ReleaseExtensionRecovery 'invalid sealed file length' }
        $sourceExists = Test-Path -LiteralPath $source -PathType Leaf
        $archived = Test-Path -LiteralPath $destination -PathType Leaf
        if (-not $sourceExists -and -not $archived) { Stop-ReleaseExtensionRecovery 'frozen file is missing from both source and archive' }
        if ($sourceExists) { $null = Assert-ReleaseExtensionRecoveryFile $source $sha $bytes }
        if ($archived) { $null = Assert-ReleaseExtensionRecoveryFile $destination $sha $bytes }
        if ($sourceExists -and $archived) { Stop-ReleaseExtensionRecovery 'duplicate source/archive requires owner inspection' }
        $moves += [ordered]@{ source = $source; destination = $destination; sha256 = $sha; bytes = [long]$bytes; sourceExists = $sourceExists }
    }
    $ignorePaths = @((Join-Path $archive '.release-owner-probe').Substring($binding.worktreePath.TrimEnd('\', '/').Length + 1).Replace('\', '/')) +
        @($moves | ForEach-Object { $_.destination.Substring($binding.worktreePath.TrimEnd('\', '/').Length + 1).Replace('\', '/') })
    foreach ($path in $ignorePaths) {
        # check-ignore -z requires --stdin, whose shared input transport is ASCII.
        # Literal UTF-8 argv and the exit code preserve Unicode without path parsing.
        $ignore = Invoke-RepositoryGit -RepositoryRoot $binding.worktreePath -Arguments @('check-ignore', '-q', '--', $path) -AllowFailure
        if ($ignore.exitCode -ne 0) { Stop-ReleaseExtensionRecovery 'archive file is not covered by the existing runtime ignore contract' }
    }
    Assert-ReleaseExtensionRecoveryDirtySet $Context @($files | ForEach-Object { [string](Get-ReleaseExtensionRecoveryValue $_ 'path') })
    foreach ($item in @(Get-ReleaseExtensionRecoveryResidueFiles $Context $set)) {
        $relative = $item.FullName.Substring($binding.worktreePath.TrimEnd('\', '/').Length + 1).Replace('\', '/')
        if (-not $seen.Contains($relative)) { Stop-ReleaseExtensionRecovery 'foreign file appeared after sealing' }
    }
    # All refusal checks precede the existing owner's DT restoration. A thrown or
    # lost acknowledgement never authorizes cleanup; the same validated DT may replay.
    $readLeases = @()
    try {
        foreach ($move in $moves) {
            if (-not $move.sourceExists) { continue }
            $stream = [IO.File]::Open($move.source, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
            $readLeases += $stream
            $null = Assert-ReleaseExtensionRecoveryFile $move.source $move.sha256 $move.bytes
        }
        & $RestoreSnapshot (Get-ReleaseExtensionRecoveryValue (Get-ReleaseExtensionRecoveryValue $Checkpoint 'snapshots') 'postConfig') (Get-ReleaseExtensionRecoveryValue (Get-ReleaseExtensionRecoveryValue $Checkpoint 'stateFiles') 'postConfig') | Out-Null
    } finally { foreach ($stream in $readLeases) { $stream.Dispose() } }
    $null = Assert-ReleaseExtensionRecoveryStop $Context $Ownership $GetStopEvidence
    foreach ($move in $moves) {
        if (-not $move.sourceExists) { continue }
        $null = Get-ReleaseExtensionRecoveryPath -Root $set.root -Path $move.source
        $null = Get-ReleaseExtensionRecoveryPath -Root $archive -Path $move.destination
        $null = Assert-ReleaseExtensionRecoveryFile $move.source $move.sha256 $move.bytes
        [IO.Directory]::CreateDirectory((Split-Path -Parent $move.destination)) | Out-Null
        [IO.File]::Move($move.source, $move.destination)
        try { $null = Assert-ReleaseExtensionRecoveryFile $move.destination $move.sha256 $move.bytes }
        catch {
            if (-not (Test-Path -LiteralPath $move.source)) { [IO.File]::Move($move.destination, $move.source) }
            throw
        }
    }
    if (Test-Path -LiteralPath $set.root) {
        $directories = @(Get-ChildItem -LiteralPath $set.root -Directory -Recurse -Force | Sort-Object { $_.FullName.Length } -Descending) + @(Get-Item -LiteralPath $set.root)
        foreach ($directory in $directories) {
            $absolute = Get-ReleaseExtensionRecoveryPath -Root $set.root -Path $directory.FullName -AllowRoot
            if (@(Get-ChildItem -LiteralPath $absolute -Force).Count -eq 0) { [IO.Directory]::Delete($absolute, $false) }
        }
    }
    Assert-ReleaseExtensionRecoveryDirtySet $Context @()
    return [ordered]@{ status = 'recovered'; ownershipId = (Get-ReleaseExtensionRecoveryValue $Ownership 'id'); archiveRoot = $archive;
        snapshotSha256 = $support.snapshot.sha256; stopEvidence = $stop; archivedFiles = $files; stageStatus = [string](Get-ReleaseExtensionRecoveryValue $stage 'status') }
}
