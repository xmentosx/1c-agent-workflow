[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ProjectRoot,
    [string]$PackageRoot = '',
    [switch]$PrepareManagedWorktrees
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Text.UTF8Encoding]::new($false)

function Get-CutoverFullPath([string]$Path) {
    if (-not [IO.Path]::IsPathRooted($Path)) { $Path = Join-Path (Get-Location).Path $Path }
    return [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
}

function Assert-CutoverChildPath([string]$Root, [string]$Path) {
    $rootFull = Get-CutoverFullPath $Root
    $pathFull = Get-CutoverFullPath $Path
    if (-not $pathFull.StartsWith(($rootFull + [IO.Path]::DirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase)) {
        throw "EXECUTION_GUARD_CUTOVER_SCOPE_INVALID: '$pathFull' is outside '$rootFull'."
    }
    return $pathFull
}

function Test-CutoverOwnedProcess([object]$State, [string]$PidField, [string]$StartField, [string]$ExecutableField, [string[]]$Markers) {
    $processId = 0
    if (-not [int]::TryParse([string]$State.$PidField, [ref]$processId) -or $processId -le 0) { return $null }
    $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
    if ($null -eq $process) { return $null }
    $expectedStart = [datetime]::MinValue
    if (-not [datetime]::TryParse([string]$State.$StartField, [ref]$expectedStart) -or
        [math]::Abs(($process.StartTime.ToUniversalTime() - $expectedStart.ToUniversalTime()).TotalSeconds) -gt 2) { return $false }
    $expectedExecutable = [string]$State.$ExecutableField
    try { $actualExecutable = [IO.Path]::GetFullPath($process.Path) } catch { return $false }
    if (-not $expectedExecutable -or -not [string]::Equals([IO.Path]::GetFullPath($expectedExecutable), $actualExecutable, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    try { $commandLine = [string](Get-CimInstance Win32_Process -Filter "ProcessId=$processId" -ErrorAction Stop).CommandLine } catch { return $false }
    $required = @($Markers | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($required.Count -eq 0 -or @($required | Where-Object { $commandLine.IndexOf($_, [StringComparison]::OrdinalIgnoreCase) -lt 0 }).Count -gt 0) { return $false }
    return $process
}

function Stop-CutoverOwnedRuntime([string]$StatePath) {
    try { $state = Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop }
    catch { Write-Warning "Preserved unparseable runtime state '$StatePath'; it is not ownership evidence."; return }
    foreach ($entry in @(
        @{pid='testClientPid';start='testClientProcessStartTime';exe='testClientExecutablePath';markers=@($state.testClientOwnershipMarkers)},
        @{pid='pid';start='processStartTime';exe='executablePath';markers=@($state.ownershipMarkers)}
    )) {
        $owned = Test-CutoverOwnedProcess -State $state -PidField $entry.pid -StartField $entry.start -ExecutableField $entry.exe -Markers $entry.markers
        if ($owned -eq $false) {
            Write-Warning "Preserved process recorded by '$StatePath': exact ownership could not be proven."
            continue
        }
        if ($null -ne $owned) {
            Stop-Process -Id $owned.Id -ErrorAction Stop
            if (-not $owned.WaitForExit(5000)) { Stop-Process -Id $owned.Id -Force -ErrorAction Stop }
        }
    }
}

function Remove-ExecutionGuardLegacyState([string]$Root) {
    $rootFull = Get-CutoverFullPath $Root
    $runtimeRoot = Join-Path $rootFull '.agent-1c\mcp\ondemand'
    if (Test-Path -LiteralPath $runtimeRoot -PathType Container) {
        foreach ($statePath in @(Get-ChildItem -LiteralPath $runtimeRoot -Filter '*.json' -File -Recurse -ErrorAction Stop | Select-Object -ExpandProperty FullName)) {
            Stop-CutoverOwnedRuntime -StatePath $statePath
        }
    }
    foreach ($relative in @(
        '.agent-1c\infobase-access',
        '.agent-1c\database-access',
        '.agent-1c\native-recovery',
        '.agent-1c\recovery',
        '.agent-1c\mcp\ondemand'
    )) {
        $target = Assert-CutoverChildPath -Root $rootFull -Path (Join-Path $rootFull $relative)
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop }
    }
    foreach ($relative in @(
        '.agent-1c\locks\runtime-mcp.lock',
        '.agent-1c\locks\ondemand-start.lock'
    )) {
        $target = Assert-CutoverChildPath -Root $rootFull -Path (Join-Path $rootFull $relative)
        if (Test-Path -LiteralPath $target -PathType Leaf) { Remove-Item -LiteralPath $target -Force -ErrorAction Stop }
    }
}

function Enable-ExecutionGuardGeneration([string]$Root) {
    $rootFull = Get-CutoverFullPath $Root
    $marker = Join-Path $rootFull '.agent-1c\execution-guard-generation.json'
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $marker))
    $temporary = $marker + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    [IO.File]::WriteAllText($temporary, (([ordered]@{schemaVersion=1;generation='execution-guards-v2';updatedAtUtc=[datetime]::UtcNow.ToString('o')} | ConvertTo-Json -Compress) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    if (Test-Path -LiteralPath $marker -PathType Leaf) { [IO.File]::Replace($temporary, $marker, $null) }
    else { [IO.File]::Move($temporary, $marker) }
}

function Invoke-CutoverGit([string]$Root, [string[]]$Arguments, [switch]$Capture) {
    $output = @(& git -C $Root @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "EXECUTION_GUARD_CUTOVER_GIT_FAILED: git $($Arguments -join ' ') in '$Root': $($output -join [Environment]::NewLine)"
    }
    if ($Capture) { return (($output -join [Environment]::NewLine).Trim()) }
}

function Get-CutoverManagedDirectoryPaths {
    return @(
        '.agents\skills\1c-workflow',
        '.agents\skills\1c-workflow-fast',
        '.agents\skills\product-docs',
        '.agents\skills\itl-roctup-1c-data',
        '.agents\skills\itl-vanessa-ui-mcp',
        '.agents\skills\itl-remote-runner',
        '.agents\skills\itl-remote-agent',
        '.agents\skills\itl-performance',
        'docs\itl-workflow',
        'templates'
    )
}

function Get-CutoverManagedFilePaths {
    return @('install-agent-1c-workflow.ps1', 'AGENT-INSTALL.md')
}

function Assert-CutoverPackageReady([string]$PackageRoot) {
    foreach ($relative in @(Get-CutoverManagedDirectoryPaths)) {
        $source = Assert-CutoverChildPath -Root $PackageRoot -Path (Join-Path $PackageRoot $relative)
        if (-not (Test-Path -LiteralPath $source -PathType Container)) {
            throw "EXECUTION_GUARD_CUTOVER_PACKAGE_MISSING: $source"
        }
    }
    foreach ($relative in @(Get-CutoverManagedFilePaths)) {
        $source = Assert-CutoverChildPath -Root $PackageRoot -Path (Join-Path $PackageRoot $relative)
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            throw "EXECUTION_GUARD_CUTOVER_PACKAGE_MISSING: $source"
        }
    }
}

function Assert-CutoverWorktreeReady([string]$WorktreeRoot) {
    [void](Invoke-CutoverGit -Root $WorktreeRoot -Arguments @('symbolic-ref', '--quiet', 'HEAD') -Capture)
    foreach ($markerName in @('MERGE_HEAD', 'CHERRY_PICK_HEAD', 'REVERT_HEAD', 'BISECT_LOG', 'rebase-apply', 'rebase-merge', 'sequencer')) {
        $markerPath = Invoke-CutoverGit -Root $WorktreeRoot -Arguments @('rev-parse', '--git-path', $markerName) -Capture
        if (-not [IO.Path]::IsPathRooted($markerPath)) { $markerPath = Join-Path $WorktreeRoot $markerPath }
        if (Test-Path -LiteralPath $markerPath) {
            throw "EXECUTION_GUARD_CUTOVER_GIT_OPERATION_ACTIVE: '$WorktreeRoot' has '$markerName'."
        }
    }
}

function Copy-CutoverManagedPath([string]$PackageRoot, [string]$WorktreeRoot, [string]$RelativePath, [bool]$Directory) {
    $source = Assert-CutoverChildPath -Root $PackageRoot -Path (Join-Path $PackageRoot $RelativePath)
    if (-not (Test-Path -LiteralPath $source -PathType $(if ($Directory) { 'Container' } else { 'Leaf' }))) {
        throw "EXECUTION_GUARD_CUTOVER_PACKAGE_MISSING: $source"
    }
    $destination = Assert-CutoverChildPath -Root $WorktreeRoot -Path (Join-Path $WorktreeRoot $RelativePath)
    if (Test-Path -LiteralPath $destination) {
        Remove-Item -LiteralPath $destination -Recurse:$Directory -Force -ErrorAction Stop
    }
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $destination))
    Copy-Item -LiteralPath $source -Destination $destination -Recurse:$Directory -Force -ErrorAction Stop
}

function Update-CutoverManagedWorktree([string]$PackageRoot, [string]$WorktreeRoot) {
    $directoryPaths = @(Get-CutoverManagedDirectoryPaths)
    $filePaths = @(Get-CutoverManagedFilePaths)
    foreach ($relative in $directoryPaths) { Copy-CutoverManagedPath -PackageRoot $PackageRoot -WorktreeRoot $WorktreeRoot -RelativePath $relative -Directory $true }
    foreach ($relative in $filePaths) { Copy-CutoverManagedPath -PackageRoot $PackageRoot -WorktreeRoot $WorktreeRoot -RelativePath $relative -Directory $false }

    $branchRef = Invoke-CutoverGit -Root $WorktreeRoot -Arguments @('symbolic-ref', '--quiet', 'HEAD') -Capture
    if (-not $branchRef.StartsWith('refs/heads/', [StringComparison]::Ordinal)) {
        throw "EXECUTION_GUARD_CUTOVER_BRANCH_REQUIRED: managed worktree '$WorktreeRoot' is detached."
    }
    $oldHead = Invoke-CutoverGit -Root $WorktreeRoot -Arguments @('rev-parse', 'HEAD') -Capture
    $temporaryIndex = Join-Path ([IO.Path]::GetTempPath()) ('itl-execution-guard-cutover-' + [guid]::NewGuid().ToString('N') + '.index')
    $previousIndex = [Environment]::GetEnvironmentVariable('GIT_INDEX_FILE', 'Process')
    $managedPaths = @($directoryPaths + $filePaths | ForEach-Object { $_.Replace('\', '/') })
    try {
        [Environment]::SetEnvironmentVariable('GIT_INDEX_FILE', $temporaryIndex, 'Process')
        Invoke-CutoverGit -Root $WorktreeRoot -Arguments @('read-tree', $oldHead)
        Invoke-CutoverGit -Root $WorktreeRoot -Arguments (@('add', '-A', '-f', '--') + $managedPaths)
        $tree = Invoke-CutoverGit -Root $WorktreeRoot -Arguments @('write-tree') -Capture
        $oldTree = Invoke-CutoverGit -Root $WorktreeRoot -Arguments @('rev-parse', "$oldHead^{tree}") -Capture
        if ($tree -cne $oldTree) {
            $newHead = Invoke-CutoverGit -Root $WorktreeRoot -Arguments @('commit-tree', $tree, '-p', $oldHead, '-m', 'chore: activate execution guards v2') -Capture
            Invoke-CutoverGit -Root $WorktreeRoot -Arguments @('update-ref', $branchRef, $newHead, $oldHead)
        }
    } finally {
        [Environment]::SetEnvironmentVariable('GIT_INDEX_FILE', $previousIndex, 'Process')
        if (Test-Path -LiteralPath $temporaryIndex -PathType Leaf) { Remove-Item -LiteralPath $temporaryIndex -Force -ErrorAction SilentlyContinue }
    }
    Invoke-CutoverGit -Root $WorktreeRoot -Arguments (@('reset', '--quiet', 'HEAD', '--') + $managedPaths)
}

function Get-CutoverGitWorktrees([string]$Root) {
    $raw = & git -C $Root -c core.quotepath=false worktree list --porcelain -z
    if ($LASTEXITCODE -ne 0) { throw 'EXECUTION_GUARD_CUTOVER_WORKTREE_LIST_FAILED' }
    $paths = [Collections.Generic.List[string]]::new()
    $rootFull = Get-CutoverFullPath $Root
    $currentPath = ''
    $currentBranch = ''
    $flush = {
        if ($currentPath -and ([string]::Equals($currentPath, $rootFull, [StringComparison]::OrdinalIgnoreCase) -or
            $currentBranch.StartsWith('refs/heads/itldev/', [StringComparison]::OrdinalIgnoreCase))) {
            $paths.Add($currentPath) | Out-Null
        }
    }
    foreach ($entry in (($raw -join '') -split "`0")) {
        if ($entry.StartsWith('worktree ')) {
            & $flush
            $currentPath = Get-CutoverFullPath $entry.Substring(9)
            $currentBranch = ''
        } elseif ($entry.StartsWith('branch ')) {
            $currentBranch = $entry.Substring(7)
        }
    }
    & $flush
    if (@($paths | Where-Object { [string]::Equals($_, $rootFull, [StringComparison]::OrdinalIgnoreCase) }).Count -ne 1) {
        throw 'EXECUTION_GUARD_CUTOVER_MASTER_WORKTREE_MISSING'
    }
    return @($paths | Sort-Object -Unique)
}

$projectFull = Get-CutoverFullPath $ProjectRoot
$roots = @($projectFull)
if ($PrepareManagedWorktrees) { $roots = @(Get-CutoverGitWorktrees -Root $projectFull) }

if ($PrepareManagedWorktrees) {
    $packageFull = Get-CutoverFullPath $(if ($PackageRoot) { $PackageRoot } else { $projectFull })
    Assert-CutoverPackageReady -PackageRoot $packageFull
    foreach ($root in $roots) { Assert-CutoverWorktreeReady -WorktreeRoot $root }
}

foreach ($root in $roots) { Remove-ExecutionGuardLegacyState -Root $root }

if ($PrepareManagedWorktrees) {
    foreach ($root in @($roots | Where-Object { -not [string]::Equals($_, $projectFull, [StringComparison]::OrdinalIgnoreCase) })) {
        Update-CutoverManagedWorktree -PackageRoot $packageFull -WorktreeRoot $root
    }
}

foreach ($root in $roots) { Enable-ExecutionGuardGeneration -Root $root }

[pscustomobject]@{status='completed';generation='execution-guards-v2';project=$projectFull;worktrees=@($roots)}
