[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("Checkpoint", "Status", "Resume", "Complete")]
    [string]$Action,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')]
    [string]$TaskId,

    [string]$RepositoryRoot = (Get-Location).Path,
    [string]$PayloadPath = "",
    [string]$ExpectedStateSha256 = "",
    [switch]$AdvanceGitState
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "git-path-list.ps1")

function Get-SourceContextTextSha256 {
    param([Parameter(Mandatory = $true)][string]$Text)

    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        return ([BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant()
    } finally {
        $algorithm.Dispose()
    }
}

function Get-SourceContextFileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function ConvertTo-SourceContextSafeText {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][string]$Field,
        [int]$MaximumLength = 2048,
        [switch]$AllowEmpty
    )

    if ($null -eq $Value) {
        if ($AllowEmpty) { return "" }
        throw "SOURCE_CONTEXT_PAYLOAD_INVALID: '$Field' is required."
    }
    if ($Value -isnot [string]) { throw "SOURCE_CONTEXT_PAYLOAD_INVALID: '$Field' must be a string." }
    $text = ([string]$Value).Trim()
    if (-not $AllowEmpty -and -not $text) { throw "SOURCE_CONTEXT_PAYLOAD_INVALID: '$Field' must not be empty." }
    if ($text.Length -gt $MaximumLength) { throw "SOURCE_CONTEXT_PAYLOAD_INVALID: '$Field' exceeds $MaximumLength characters." }

    $secretAssignment = '(?i)\b(password|passwd|pwd|api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|secret)\s*[:=]\s*(?:"[^"]*"|''[^'']*''|[^\s;,]+)'
    $text = [regex]::Replace($text, $secretAssignment, '$1=[REDACTED]')
    $text = [regex]::Replace($text, '(?i)\bBearer\s+[A-Za-z0-9._~+/-]+=*', 'Bearer [REDACTED]')
    return $text
}

function Get-SourceContextPropertyValue {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [switch]$Required
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        if ($Required) { throw "SOURCE_CONTEXT_PAYLOAD_INVALID: '$Name' is required." }
        return $null
    }
    return ,$property.Value
}

function Assert-SourceContextAllowedProperties {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string[]]$Allowed,
        [Parameter(Mandatory = $true)][string]$Field
    )

    foreach ($property in @($Object.PSObject.Properties)) {
        if ([string]$property.Name -notin $Allowed) {
            $name = [string]$property.Name
            if ($name -match '(?i)prompt|response|raw|output|transcript|password|passwd|secret|credential|token') {
                throw "SOURCE_CONTEXT_PAYLOAD_FIELD_FORBIDDEN: '$Field.$name' may contain raw conversation, output, credentials, or secrets."
            }
            throw "SOURCE_CONTEXT_PAYLOAD_INVALID: unsupported field '$Field.$name'."
        }
    }
}

function ConvertTo-SourceContextStringList {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][string]$Field,
        [int]$MaximumItems = 64,
        [int]$MaximumItemLength = 1024,
        [switch]$Required
    )

    if ($null -eq $Value) {
        if ($Required) { throw "SOURCE_CONTEXT_PAYLOAD_INVALID: '$Field' is required." }
        return @()
    }
    if ($Value -is [string] -or $Value -isnot [System.Collections.IEnumerable]) {
        throw "SOURCE_CONTEXT_PAYLOAD_INVALID: '$Field' must be an array of strings."
    }
    $items = @($Value)
    if ($items.Count -gt $MaximumItems) { throw "SOURCE_CONTEXT_PAYLOAD_INVALID: '$Field' exceeds $MaximumItems items." }
    $result = @($items | ForEach-Object {
        ConvertTo-SourceContextSafeText -Value $_ -Field $Field -MaximumLength $MaximumItemLength
    })
    return ,$result
}

function ConvertTo-SourceContextObjectList {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][string]$Field,
        [Parameter(Mandatory = $true)][string[]]$Allowed,
        [Parameter(Mandatory = $true)][string[]]$Required,
        [int]$MaximumItems = 64
    )

    if ($null -eq $Value) { return @() }
    if ($Value -is [string] -or $Value -isnot [System.Collections.IEnumerable]) {
        throw "SOURCE_CONTEXT_PAYLOAD_INVALID: '$Field' must be an array of objects."
    }
    $items = @($Value)
    if ($items.Count -gt $MaximumItems) { throw "SOURCE_CONTEXT_PAYLOAD_INVALID: '$Field' exceeds $MaximumItems items." }
    $result = @()
    foreach ($item in $items) {
        if ($null -eq $item -or $item -is [string]) { throw "SOURCE_CONTEXT_PAYLOAD_INVALID: '$Field' must contain objects." }
        Assert-SourceContextAllowedProperties -Object $item -Allowed $Allowed -Field $Field
        $record = [ordered]@{}
        foreach ($name in $Allowed) {
            $value = Get-SourceContextPropertyValue -Object $item -Name $name
            if ($name -in $Required) {
                $record[$name] = ConvertTo-SourceContextSafeText -Value $value -Field "$Field.$name"
            } elseif ($null -ne $value) {
                if ($value -is [string]) {
                    $record[$name] = ConvertTo-SourceContextSafeText -Value $value -Field "$Field.$name" -AllowEmpty
                } elseif ($value -is [System.Collections.IEnumerable]) {
                    $record[$name] = ConvertTo-SourceContextStringList -Value $value -Field "$Field.$name" -MaximumItems 16 -MaximumItemLength 1024
                } else {
                    throw "SOURCE_CONTEXT_PAYLOAD_INVALID: '$Field.$name' must be a string or an array of strings."
                }
            }
        }
        $result += ,([pscustomobject]$record)
    }
    return ,@($result)
}

function ConvertTo-SourceContextTelemetry {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return [pscustomobject][ordered]@{} }
    $allowed = @(
        "inputTokens", "cachedInputTokens", "uncachedInputTokens", "outputTokens",
        "contextWindowTokens", "peakContextTokens", "compactions", "toolCalls",
        "toolResultBytes", "repeatedReads", "repeatedSearches", "repeatedGates",
        "resultComplete"
    )
    Assert-SourceContextAllowedProperties -Object $Value -Allowed $allowed -Field "telemetry"
    $result = [ordered]@{}
    foreach ($property in @($Value.PSObject.Properties)) {
        $name = [string]$property.Name
        $item = $property.Value
        if ($item -is [string] -and [string]$item -eq "unknown") {
            $result[$name] = "unknown"
        } elseif ($name -eq "resultComplete" -and $item -is [bool]) {
            $result[$name] = [bool]$item
        } elseif ($item -is [byte] -or $item -is [int16] -or $item -is [int32] -or $item -is [int64] -or
                  $item -is [uint16] -or $item -is [uint32] -or $item -is [uint64] -or $item -is [decimal] -or
                  $item -is [double] -or $item -is [single]) {
            if ([decimal]$item -lt 0) { throw "SOURCE_CONTEXT_PAYLOAD_INVALID: telemetry '$name' must not be negative." }
            $result[$name] = $item
        } else {
            throw "SOURCE_CONTEXT_PAYLOAD_INVALID: telemetry '$name' must be a non-negative number, boolean resultComplete, or 'unknown'."
        }
    }
    return [pscustomobject]$result
}

function ConvertTo-SourceContextPayload {
    param([Parameter(Mandatory = $true)][object]$Payload)

    $allowed = @(
        "objective", "scope", "exclusions", "stage", "approvedPlan", "ownerContracts",
        "changedPaths", "decisions", "evidence", "blockers", "nextAction", "telemetry"
    )
    Assert-SourceContextAllowedProperties -Object $Payload -Allowed $allowed -Field "payload"
    $stage = ConvertTo-SourceContextSafeText -Value (Get-SourceContextPropertyValue -Object $Payload -Name "stage" -Required) -Field "stage" -MaximumLength 32
    if ($stage -notin @("discovery", "plan", "implementation", "verification", "registered", "blocked", "complete")) {
        throw "SOURCE_CONTEXT_PAYLOAD_INVALID: unsupported stage '$stage'."
    }
    $ownerContracts = ConvertTo-SourceContextStringList -Value (Get-SourceContextPropertyValue -Object $Payload -Name "ownerContracts") -Field "ownerContracts" -MaximumItems 32 -MaximumItemLength 128
    foreach ($contract in $ownerContracts) {
        if ($contract -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') { throw "SOURCE_CONTEXT_PAYLOAD_INVALID: invalid owner contract '$contract'." }
    }
    $changedPaths = ConvertTo-SourceContextStringList -Value (Get-SourceContextPropertyValue -Object $Payload -Name "changedPaths") -Field "changedPaths" -MaximumItems 256 -MaximumItemLength 1024
    foreach ($path in $changedPaths) {
        if ([IO.Path]::IsPathRooted($path) -or $path -match '(^|[\\/])\.\.([\\/]|$)') {
            throw "SOURCE_CONTEXT_PAYLOAD_INVALID: changed path '$path' must be repository-relative."
        }
    }
    return [pscustomobject][ordered]@{
        objective = ConvertTo-SourceContextSafeText -Value (Get-SourceContextPropertyValue -Object $Payload -Name "objective" -Required) -Field "objective"
        scope = ConvertTo-SourceContextStringList -Value (Get-SourceContextPropertyValue -Object $Payload -Name "scope" -Required) -Field "scope" -Required
        exclusions = ConvertTo-SourceContextStringList -Value (Get-SourceContextPropertyValue -Object $Payload -Name "exclusions" -Required) -Field "exclusions" -Required
        stage = $stage
        approvedPlan = ConvertTo-SourceContextStringList -Value (Get-SourceContextPropertyValue -Object $Payload -Name "approvedPlan" -Required) -Field "approvedPlan" -Required
        ownerContracts = $ownerContracts
        changedPaths = $changedPaths
        decisions = ConvertTo-SourceContextObjectList -Value (Get-SourceContextPropertyValue -Object $Payload -Name "decisions") -Field "decisions" -Allowed @("decision", "reason", "rejectedAlternatives") -Required @("decision", "reason")
        evidence = ConvertTo-SourceContextObjectList -Value (Get-SourceContextPropertyValue -Object $Payload -Name "evidence") -Field "evidence" -Allowed @("kind", "commandType", "artifact", "inputFingerprint", "status", "recordedAt", "summary") -Required @("kind", "status", "summary")
        blockers = ConvertTo-SourceContextObjectList -Value (Get-SourceContextPropertyValue -Object $Payload -Name "blockers") -Field "blockers" -Allowed @("code", "summary", "requiredAction") -Required @("code", "summary", "requiredAction")
        nextAction = ConvertTo-SourceContextSafeText -Value (Get-SourceContextPropertyValue -Object $Payload -Name "nextAction" -Required) -Field "nextAction"
        telemetry = ConvertTo-SourceContextTelemetry -Value (Get-SourceContextPropertyValue -Object $Payload -Name "telemetry")
    }
}

function Get-SourceContextPath {
    param(
        [Parameter(Mandatory = $true)][string]$CommonGitDirectory,
        [Parameter(Mandatory = $true)][string]$Identifier
    )

    $fileName = $Identifier.ToLowerInvariant() + ".json"
    return Join-Path (Join-Path $CommonGitDirectory "itl\source-maintenance\v1") $fileName
}

function Get-SourceContextIndexFingerprint {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )

    $result = Invoke-RepositoryGit -RepositoryRoot $Root -Arguments @("ls-files", "--stage", "-z", "--", $RelativePath)
    $entry = @($result.stdout.Split([char]0, [StringSplitOptions]::RemoveEmptyEntries) | Where-Object { $_ }) | Select-Object -First 1
    if (-not $entry -or $entry -notmatch '^[0-7]{6} ([0-9a-fA-F]{40,64}) [0-3]\t') {
        return "missing"
    }
    return $matches[1].ToLowerInvariant()
}

function Get-SourceContextWorktreeFingerprint {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )

    $nativePath = $RelativePath.Replace('/', [IO.Path]::DirectorySeparatorChar)
    $path = [IO.Path]::GetFullPath((Join-Path $Root $nativePath))
    $rootWithSeparator = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $path.StartsWith($rootWithSeparator, [StringComparison]::OrdinalIgnoreCase)) {
        throw "SOURCE_CONTEXT_GIT_PATH_INVALID: '$RelativePath' resolved outside the repository."
    }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [pscustomobject][ordered]@{ fingerprint = "deleted"; size = 0 }
    }
    $item = Get-Item -LiteralPath $path
    return [pscustomobject][ordered]@{ fingerprint = Get-SourceContextFileSha256 -Path $path; size = [long]$item.Length }
}

function Get-SourceContextDirtyState {
    param([Parameter(Mandatory = $true)][string]$Root)

    $staged = @(Get-RepositoryGitPathList -RepositoryRoot $Root -Arguments @("diff", "--cached", "--name-only", "-z", "--") | Sort-Object -Unique)
    $unstaged = @(Get-RepositoryGitPathList -RepositoryRoot $Root -Arguments @("diff", "--name-only", "-z", "--") | Sort-Object -Unique)
    $untracked = @(Get-RepositoryGitPathList -RepositoryRoot $Root -Arguments @("ls-files", "--others", "--exclude-standard", "-z", "--") | Sort-Object -Unique)
    $entries = @()
    foreach ($path in $staged) {
        $entries += ,([pscustomobject][ordered]@{
            path = ([string]$path).Replace('\', '/')
            status = "staged"
            fingerprintKind = "git-object"
            fingerprint = Get-SourceContextIndexFingerprint -Root $Root -RelativePath ([string]$path)
            size = "unknown"
        })
    }
    foreach ($kind in @([pscustomobject]@{ name = "unstaged"; paths = $unstaged }, [pscustomobject]@{ name = "untracked"; paths = $untracked })) {
        foreach ($path in @($kind.paths)) {
            $value = Get-SourceContextWorktreeFingerprint -Root $Root -RelativePath ([string]$path)
            $entries += ,([pscustomobject][ordered]@{
                path = ([string]$path).Replace('\', '/')
                status = [string]$kind.name
                fingerprintKind = "sha256"
                fingerprint = [string]$value.fingerprint
                size = $value.size
            })
        }
    }
    $entries = @($entries | Sort-Object status, path)
    $identity = [ordered]@{ entries = $entries }
    return [pscustomobject][ordered]@{
        fingerprint = Get-SourceContextTextSha256 -Text ($identity | ConvertTo-Json -Depth 8 -Compress)
        entries = $entries
    }
}

function Get-SourceContextGitIdentity {
    param([Parameter(Mandatory = $true)][string]$Root)

    $requestedRoot = [IO.Path]::GetFullPath($Root)
    $inside = (Invoke-RepositoryGit -RepositoryRoot $requestedRoot -Arguments @("rev-parse", "--is-inside-work-tree")).stdout.Trim()
    $prefix = (Invoke-RepositoryGit -RepositoryRoot $requestedRoot -Arguments @("rev-parse", "--show-prefix")).stdout.Trim()
    if ($inside -cne "true" -or $prefix) { throw "SOURCE_CONTEXT_REPOSITORY_INVALID: -RepositoryRoot must be the exact worktree root." }
    $repositoryRoot = $requestedRoot
    $gitMarker = Join-Path $repositoryRoot ".git"
    if (Test-Path -LiteralPath $gitMarker -PathType Container) {
        $commonGitDirectory = [IO.Path]::GetFullPath($gitMarker)
    } elseif (Test-Path -LiteralPath $gitMarker -PathType Leaf) {
        $gitLine = ([IO.File]::ReadAllText($gitMarker, [Text.Encoding]::UTF8) -split "`r?`n" | Select-Object -First 1)
        if ($gitLine -notmatch '^gitdir:\s*(.+)$') { throw "SOURCE_CONTEXT_REPOSITORY_INVALID: worktree .git file is invalid." }
        $gitDirectoryValue = $matches[1].Trim()
        $gitDirectory = if ([IO.Path]::IsPathRooted($gitDirectoryValue)) { [IO.Path]::GetFullPath($gitDirectoryValue) } else { [IO.Path]::GetFullPath((Join-Path $repositoryRoot $gitDirectoryValue)) }
        $commonMarker = Join-Path $gitDirectory "commondir"
        if (-not (Test-Path -LiteralPath $commonMarker -PathType Leaf)) { throw "SOURCE_CONTEXT_REPOSITORY_INVALID: linked worktree commondir is missing." }
        $commonValue = [IO.File]::ReadAllText($commonMarker, [Text.Encoding]::UTF8).Trim()
        if (-not $commonValue) { throw "SOURCE_CONTEXT_REPOSITORY_INVALID: linked worktree commondir is empty." }
        $commonGitDirectory = if ([IO.Path]::IsPathRooted($commonValue)) { [IO.Path]::GetFullPath($commonValue) } else { [IO.Path]::GetFullPath((Join-Path $gitDirectory $commonValue)) }
    } else {
        throw "SOURCE_CONTEXT_REPOSITORY_INVALID: .git is missing from the worktree root."
    }
    $branchResult = Invoke-RepositoryGit -RepositoryRoot $repositoryRoot -Arguments @("symbolic-ref", "--quiet", "--short", "HEAD") -AllowFailure
    if ($branchResult.exitCode -ne 0 -or -not $branchResult.stdout.Trim()) { throw "SOURCE_CONTEXT_DETACHED_HEAD: a named branch is required." }
    $headCommit = (Invoke-RepositoryGit -RepositoryRoot $repositoryRoot -Arguments @("rev-parse", "HEAD")).stdout.Trim().ToLowerInvariant()
    $tree = (Invoke-RepositoryGit -RepositoryRoot $repositoryRoot -Arguments @("rev-parse", "HEAD^{tree}")).stdout.Trim().ToLowerInvariant()
    return [pscustomobject][ordered]@{
        repositoryRoot = $repositoryRoot
        commonGitDir = [IO.Path]::GetFullPath($commonGitDirectory)
        worktreePath = $repositoryRoot
        branch = $branchResult.stdout.Trim()
        headCommit = $headCommit
        tree = $tree
        dirtyState = Get-SourceContextDirtyState -Root $repositoryRoot
    }
}

function Read-SourceContextState {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Identifier
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "SOURCE_CONTEXT_NOT_FOUND: no checkpoint exists for task '$Identifier'." }
    try {
        $state = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json
    } catch {
        throw "SOURCE_CONTEXT_STATE_CORRUPT: checkpoint '$Path' is not valid JSON. $($_.Exception.Message)"
    }
    if ([int]$state.schemaVersion -ne 1 -or [string]$state.taskId -cne $Identifier) {
        throw "SOURCE_CONTEXT_STATE_IDENTITY_INVALID: checkpoint schema or task ID does not match '$Identifier'."
    }
    return $state
}

function Get-SourceContextMismatch {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][object]$Identity,
        [switch]$TopologyOnly
    )

    $mismatch = @()
    foreach ($field in @("repositoryRoot", "commonGitDir", "worktreePath")) {
        $left = [IO.Path]::GetFullPath([string]$State.$field)
        $right = [IO.Path]::GetFullPath([string]$Identity.$field)
        if (-not $left.Equals($right, [StringComparison]::OrdinalIgnoreCase)) { $mismatch += $field }
    }
    if ([string]$State.branch -cne [string]$Identity.branch) { $mismatch += "branch" }
    if (-not $TopologyOnly) {
        if ([string]$State.headCommit -cne [string]$Identity.headCommit) { $mismatch += "headCommit" }
        if ([string]$State.tree -cne [string]$Identity.tree) { $mismatch += "tree" }
        if ([string]$State.dirtyState.fingerprint -cne [string]$Identity.dirtyState.fingerprint) { $mismatch += "dirtyState" }
    }
    return @($mismatch)
}

function Write-SourceContextStateAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$State
    )

    $directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $token = [guid]::NewGuid().ToString("N")
    $temporary = Join-Path $directory ("." + [IO.Path]::GetFileName($Path) + "." + $token + ".tmp")
    $backup = Join-Path $directory ("." + [IO.Path]::GetFileName($Path) + "." + $token + ".bak")
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($State | ConvertTo-Json -Depth 16) + [Environment]::NewLine)
    $stream = $null
    try {
        $stream = New-Object IO.FileStream($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
        $stream.Dispose()
        $stream = $null
        if ($env:ITL_SOURCE_CONTEXT_TEST_FAULT -eq "before-replace") { throw "SOURCE_CONTEXT_TEST_ATOMIC_FAILURE" }
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            [IO.File]::Replace($temporary, $Path, $backup, $true)
            Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
        } else {
            [IO.File]::Move($temporary, $Path)
        }
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue }
    }
}

function Assert-SourceContextExpectedState {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [AllowEmptyString()][string]$Expected
    )

    if (-not $Expected) { throw "SOURCE_CONTEXT_EXPECTED_STATE_REQUIRED: updating a checkpoint requires -ExpectedStateSha256 from Status or Resume." }
    $actual = Get-SourceContextFileSha256 -Path $Path
    if ([string]$Expected -cne $actual) { throw "SOURCE_CONTEXT_STATE_CHANGED: expected state SHA '$Expected' does not match '$actual'." }
    return $actual
}

function New-SourceContextState {
    param(
        [Parameter(Mandatory = $true)][object]$Payload,
        [Parameter(Mandatory = $true)][object]$Identity,
        [Parameter(Mandatory = $true)][string]$Identifier,
        [AllowNull()][object]$Existing
    )

    $baseCommit = if ($null -ne $Existing) { [string]$Existing.baseCommit } else { [string]$Identity.headCommit }
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        taskId = $Identifier
        updatedAt = [DateTime]::UtcNow.ToString("o")
        objective = $Payload.objective
        scope = @($Payload.scope)
        exclusions = @($Payload.exclusions)
        repositoryRoot = $Identity.repositoryRoot
        commonGitDir = $Identity.commonGitDir
        worktreePath = $Identity.worktreePath
        branch = $Identity.branch
        baseCommit = $baseCommit
        headCommit = $Identity.headCommit
        tree = $Identity.tree
        dirtyState = $Identity.dirtyState
        stage = $Payload.stage
        approvedPlan = @($Payload.approvedPlan)
        ownerContracts = @($Payload.ownerContracts)
        changedPaths = @($Payload.changedPaths)
        decisions = @($Payload.decisions)
        evidence = @($Payload.evidence)
        blockers = @($Payload.blockers)
        nextAction = $Payload.nextAction
        telemetry = $Payload.telemetry
    }
}

if ($Action -ne "Checkpoint" -and ($PayloadPath -or $AdvanceGitState)) {
    throw "SOURCE_CONTEXT_ARGUMENT_INVALID: -PayloadPath and -AdvanceGitState are valid only with Checkpoint."
}
if ($Action -eq "Checkpoint" -and -not $PayloadPath) { throw "SOURCE_CONTEXT_PAYLOAD_REQUIRED: Checkpoint requires -PayloadPath." }
if ($PayloadPath -and -not (Test-Path -LiteralPath $PayloadPath -PathType Leaf)) { throw "SOURCE_CONTEXT_PAYLOAD_NOT_FOUND: '$PayloadPath'." }

$identity = Get-SourceContextGitIdentity -Root $RepositoryRoot
$statePath = Get-SourceContextPath -CommonGitDirectory $identity.commonGitDir -Identifier $TaskId

switch ($Action) {
    "Checkpoint" {
        $payload = ConvertTo-SourceContextPayload -Payload ([IO.File]::ReadAllText([IO.Path]::GetFullPath($PayloadPath), [Text.Encoding]::UTF8) | ConvertFrom-Json)
        $existing = $null
        if (Test-Path -LiteralPath $statePath -PathType Leaf) {
            $existing = Read-SourceContextState -Path $statePath -Identifier $TaskId
            [void](Assert-SourceContextExpectedState -Path $statePath -Expected $ExpectedStateSha256)
            $topologyMismatch = @(Get-SourceContextMismatch -State $existing -Identity $identity -TopologyOnly)
            if ($topologyMismatch.Count -gt 0) { throw "SOURCE_CONTEXT_TOPOLOGY_MISMATCH: $($topologyMismatch -join ', ')." }
            $gitMismatch = @(Get-SourceContextMismatch -State $existing -Identity $identity | Where-Object { $_ -notin @("repositoryRoot", "commonGitDir", "worktreePath", "branch") })
            if ($gitMismatch.Count -gt 0 -and -not $AdvanceGitState) {
                throw "SOURCE_CONTEXT_GIT_STATE_MISMATCH: $($gitMismatch -join ', '). Use an explicit Checkpoint update with -ExpectedStateSha256 and -AdvanceGitState after reviewing the current Git state."
            }
            if ($AdvanceGitState -and [string]$existing.headCommit -cne [string]$identity.headCommit) {
                $ancestor = Invoke-RepositoryGit -RepositoryRoot $identity.repositoryRoot -Arguments @("merge-base", "--is-ancestor", [string]$existing.headCommit, [string]$identity.headCommit) -AllowFailure
                if ($ancestor.exitCode -ne 0) { throw "SOURCE_CONTEXT_HEAD_DIVERGED: current HEAD is not a descendant of the saved HEAD." }
            }
        } elseif ($ExpectedStateSha256 -or $AdvanceGitState) {
            throw "SOURCE_CONTEXT_ARGUMENT_INVALID: state expectations cannot be used for the first checkpoint."
        }
        $state = New-SourceContextState -Payload $payload -Identity $identity -Identifier $TaskId -Existing $existing
        Write-SourceContextStateAtomic -Path $statePath -State $state
        [pscustomobject][ordered]@{
            status = "saved"
            taskId = $TaskId
            path = $statePath
            stateSha256 = Get-SourceContextFileSha256 -Path $statePath
            stage = $state.stage
            nextAction = $state.nextAction
            gitStateFingerprint = $state.dirtyState.fingerprint
        } | ConvertTo-Json -Depth 6
    }
    "Status" {
        $state = Read-SourceContextState -Path $statePath -Identifier $TaskId
        $mismatch = @(Get-SourceContextMismatch -State $state -Identity $identity)
        [pscustomobject][ordered]@{
            status = $(if ($mismatch.Count -eq 0) { "matched" } else { "mismatch" })
            taskId = $TaskId
            path = $statePath
            stateSha256 = Get-SourceContextFileSha256 -Path $statePath
            stage = $state.stage
            updatedAt = $state.updatedAt
            mismatchFields = $mismatch
        } | ConvertTo-Json -Depth 6
    }
    "Resume" {
        $state = Read-SourceContextState -Path $statePath -Identifier $TaskId
        $mismatch = @(Get-SourceContextMismatch -State $state -Identity $identity)
        if ($mismatch.Count -gt 0) { throw "SOURCE_CONTEXT_RESUME_MISMATCH: $($mismatch -join ', ')." }
        [pscustomobject][ordered]@{
            status = "resumed"
            taskId = $TaskId
            path = $statePath
            stateSha256 = Get-SourceContextFileSha256 -Path $statePath
            checkpoint = $state
        } | ConvertTo-Json -Depth 18
    }
    "Complete" {
        $state = Read-SourceContextState -Path $statePath -Identifier $TaskId
        [void](Assert-SourceContextExpectedState -Path $statePath -Expected $ExpectedStateSha256)
        $mismatch = @(Get-SourceContextMismatch -State $state -Identity $identity)
        if ($mismatch.Count -gt 0) { throw "SOURCE_CONTEXT_COMPLETE_MISMATCH: $($mismatch -join ', ')." }
        $state.stage = "complete"
        $state.nextAction = "none"
        $state.updatedAt = [DateTime]::UtcNow.ToString("o")
        Write-SourceContextStateAtomic -Path $statePath -State $state
        [pscustomobject][ordered]@{
            status = "completed"
            taskId = $TaskId
            path = $statePath
            stateSha256 = Get-SourceContextFileSha256 -Path $statePath
            stage = $state.stage
            nextAction = $state.nextAction
        } | ConvertTo-Json -Depth 6
    }
}
