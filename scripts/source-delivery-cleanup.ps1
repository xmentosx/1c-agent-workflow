Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "develop-e2e-cleanup.ps1")

function Test-SourceDeliveryPathInUse {
    param([Parameter(Mandatory = $true)][string]$Path)

    $escaped = [regex]::Escape(([IO.Path]::GetFullPath($Path)).TrimEnd('\'))
    return @((Get-CimInstance Win32_Process -ErrorAction SilentlyContinue) | Where-Object {
        [string]$_.CommandLine -match $escaped
    }).Count -gt 0
}

function Remove-SourceDeliveryStaleCandidateWorktrees {
    param([string[]]$PreservePaths = @())

    $removed = [Collections.Generic.List[object]]::new()
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    $preserved = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($preservePath in $PreservePaths) { if ($preservePath) { [void]$preserved.Add(([IO.Path]::GetFullPath($preservePath)).TrimEnd('\')) } }
    foreach ($worktree in @(Get-DevelopE2ERegisteredWorktrees -ProjectRoot $script:Root)) {
        $path = [IO.Path]::GetFullPath([string]$worktree.path).TrimEnd('\')
        $leaf = Split-Path -Leaf $path
        $branch = [string]$worktree.branch
        if (-not $path.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
            $leaf -notmatch '^itl-source-(publish-develop|release-master)-([0-9a-f]{32})$' -or
            $branch -cne "refs/heads/itl/$($matches[1])-$($matches[2])" -or $preserved.Contains($path) -or
            (Test-SourceDeliveryPathInUse -Path $path)) { continue }
        $trackedStatus = Invoke-RepositoryGit -RepositoryRoot $path -Arguments @('status', '--porcelain', '--untracked-files=no') -AllowFailure
        if ($trackedStatus.exitCode -ne 0 -or [string]$trackedStatus.stdout) { continue }
        $shortBranch = $branch.Substring('refs/heads/'.Length)
        $remove = Invoke-DeliveryGit -Arguments @('worktree', 'remove', '--force', '--force', '--', $path) -AllowFailure
        if ($remove.exitCode -ne 0) { throw "Unable to remove stale delivery candidate '$path': $($remove.stderr.Trim())" }
        $delete = Invoke-DeliveryGit -Arguments @('branch', '-D', '--', $shortBranch) -AllowFailure
        if ($delete.exitCode -ne 0) { throw "Removed stale delivery candidate '$path', but could not delete '$shortBranch': $($delete.stderr.Trim())" }
        $removed.Add([pscustomobject]@{ path = $path; branch = $shortBranch }) | Out-Null
    }
    return [pscustomobject]@{ removedWorktrees = $removed.Count; entries = @($removed) }
}

function Remove-SourceDeliveryStaleTestFixtures {
    param([string]$TempRoot = ([IO.Path]::GetTempPath()))

    $root = [IO.Path]::GetFullPath($TempRoot).TrimEnd('\')
    $fixturePrefix = 'itl delivery ' + [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('0L/Rg9GC0Yw=')) + ' '
    $removed = [Collections.Generic.List[object]]::new()
    $removedWorktrees = 0
    $freedBytes = [int64]0
    foreach ($directory in @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -match ('^' + [regex]::Escape($fixturePrefix) + '[0-9a-f]{32}$')
    })) {
        $fixtureRoot = [IO.Path]::GetFullPath($directory.FullName).TrimEnd('\')
        $readmePath = Join-Path $fixtureRoot 'README.md'
        if ((Test-SourceDeliveryPathInUse -Path $fixtureRoot) -or
            -not (Test-Path -LiteralPath (Join-Path $fixtureRoot '.git') -PathType Container) -or
            -not (Test-Path -LiteralPath (Join-Path $fixtureRoot 'fake-gate.ps1') -PathType Leaf) -or
            -not (Test-Path -LiteralPath $readmePath -PathType Leaf) -or
            (Get-Content -LiteralPath $readmePath -Raw).Trim() -cne 'base') { continue }
        $remoteResult = Invoke-RepositoryGit -RepositoryRoot $fixtureRoot -Arguments @('remote', 'get-url', 'origin') -AllowFailure
        if ($remoteResult.exitCode -ne 0) { continue }
        try { $remotePath = [IO.Path]::GetFullPath($remoteResult.stdout.Trim()).TrimEnd('\') } catch { continue }
        if (-not [string]::Equals((Split-Path -Parent $remotePath), $root, [StringComparison]::OrdinalIgnoreCase) -or
            (Split-Path -Leaf $remotePath) -notmatch '^itl-delivery-remote-[0-9a-f]{32}\.git$') { continue }
        $worktrees = @(Get-DevelopE2ERegisteredWorktrees -ProjectRoot $fixtureRoot)
        $unexpected = @($worktrees | Where-Object {
            $path = [IO.Path]::GetFullPath([string]$_.path).TrimEnd('\')
            if ([string]::Equals($path, $fixtureRoot, [StringComparison]::OrdinalIgnoreCase)) { return $false }
            $leaf = Split-Path -Leaf $path; $branch = [string]$_.branch
            $generatedCandidate = [string]::Equals((Split-Path -Parent $path), $root, [StringComparison]::OrdinalIgnoreCase) -and
                $leaf -match '^itl-source-(publish-develop|release-master)-([0-9a-f]{32})$' -and
                $branch -ceq "refs/heads/itl/$($matches[1])-$($matches[2])"
            $parallelFixture = [string]::Equals((Split-Path -Parent $path), $root, [StringComparison]::OrdinalIgnoreCase) -and
                $leaf -match '^itl parallel worktree [0-9a-f]{32}$' -and $branch -ceq 'refs/heads/topic-two'
            return -not ($generatedCandidate -or $parallelFixture)
        })
        if ($unexpected.Count -gt 0) { continue }
        $bytes = [int64](@(Get-ChildItem -LiteralPath $fixtureRoot -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum)
        foreach ($worktree in @($worktrees | Where-Object { -not [string]::Equals(([IO.Path]::GetFullPath([string]$_.path).TrimEnd('\')), $fixtureRoot, [StringComparison]::OrdinalIgnoreCase) })) {
            $path = [IO.Path]::GetFullPath([string]$worktree.path).TrimEnd('\')
            if (Test-SourceDeliveryPathInUse -Path $path) { $unexpected = @($worktree); break }
            $bytes += [int64](@(Get-ChildItem -LiteralPath $path -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum)
        }
        if ($unexpected.Count -gt 0) { continue }
        foreach ($worktree in @($worktrees | Where-Object { -not [string]::Equals(([IO.Path]::GetFullPath([string]$_.path).TrimEnd('\')), $fixtureRoot, [StringComparison]::OrdinalIgnoreCase) })) {
            $path = [IO.Path]::GetFullPath([string]$worktree.path).TrimEnd('\')
            $remove = Invoke-RepositoryGit -RepositoryRoot $fixtureRoot -Arguments @('worktree', 'remove', '--force', '--force', '--', $path) -AllowFailure
            if ($remove.exitCode -ne 0) { throw "Unable to remove stale delivery test candidate '$path': $($remove.stderr.Trim())" }
            $removedWorktrees++
        }
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
        if (Test-Path -LiteralPath $remotePath -PathType Container) { Remove-Item -LiteralPath $remotePath -Recurse -Force }
        $freedBytes += $bytes
        $removed.Add([pscustomobject]@{ path = $fixtureRoot; remote = $remotePath }) | Out-Null
    }
    return [pscustomobject]@{ removedFixtures = $removed.Count; removedWorktrees = $removedWorktrees; freedBytes = $freedBytes; entries = @($removed) }
}

function Remove-SourceDeliveryStaleReleaseSeeds {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot, [string]$SeedRoot = 'D:\Git')

    $removed = [Collections.Generic.List[object]]::new()
    foreach ($worktree in @(Get-DevelopE2ERegisteredWorktrees -ProjectRoot $ProjectRoot)) {
        $path = [IO.Path]::GetFullPath([string]$worktree.path).TrimEnd('\')
        $leaf = Split-Path -Leaf $path
        $branch = [string]$worktree.branch
        if ($leaf -notmatch '^itls([ab])-([0-9a-f]{8})$') { continue }
        $family = $matches[1]; $id = $matches[2]
        if ($branch -cne "refs/heads/itldev/release-seed-$family-$id" -or
            -not [string]::Equals((Split-Path -Parent $path), ([IO.Path]::GetFullPath($SeedRoot).TrimEnd('\')), [StringComparison]::OrdinalIgnoreCase) -or
            (Test-SourceDeliveryPathInUse -Path $path)) { continue }
        $trackedStatus = Invoke-RepositoryGit -RepositoryRoot $path -Arguments @('status', '--porcelain', '--untracked-files=no') -AllowFailure
        if ($trackedStatus.exitCode -ne 0 -or [string]$trackedStatus.stdout) { continue }
        $shortBranch = $branch.Substring('refs/heads/'.Length)
        $remove = Invoke-RepositoryGit -RepositoryRoot $ProjectRoot -Arguments @('worktree', 'remove', '--force', '--force', '--', $path) -AllowFailure
        if ($remove.exitCode -ne 0) { throw "Unable to remove stale release seed '$path': $($remove.stderr.Trim())" }
        $delete = Invoke-RepositoryGit -RepositoryRoot $ProjectRoot -Arguments @('branch', '-D', '--', $shortBranch) -AllowFailure
        if ($delete.exitCode -ne 0) { throw "Removed stale release seed '$path', but could not delete '$shortBranch': $($delete.stderr.Trim())" }
        $removed.Add([pscustomobject]@{ path = $path; branch = $shortBranch }) | Out-Null
    }
    return [pscustomobject]@{ removedWorktrees = $removed.Count; entries = @($removed) }
}

function Remove-SourceDeliveryStaleReleaseSeedArchives {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)

    $project = [IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\')
    $archiveRoot = Join-Path $project '.agent-1c\branch-archives'
    if (-not (Test-Path -LiteralPath $archiveRoot -PathType Container)) { return [pscustomobject]@{ removedArchives = 0; freedBytes = 0; entries = @() } }
    $removed = [Collections.Generic.List[object]]::new(); $freedBytes = [int64]0
    foreach ($archive in @(Get-ChildItem -LiteralPath $archiveRoot -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^release-seed-([ab])-([0-9a-f]{8})$' })) {
        $name = $archive.Name; $branch = "refs/heads/itldev/$name"
        if ((Test-Path -LiteralPath (Join-Path $project ".agent-1c\dev-branches\$name")) -or (Test-SourceDeliveryPathInUse -Path $archive.FullName)) { continue }
        $branchResult = Invoke-RepositoryGit -RepositoryRoot $project -Arguments @('show-ref', '--verify', '--quiet', $branch) -AllowFailure
        if ($branchResult.exitCode -eq 0) { continue }
        if ($branchResult.exitCode -ne 1) { throw "Unable to inspect release seed branch '$branch'." }
        $bytes = [int64](@(Get-ChildItem -LiteralPath $archive.FullName -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum)
        Remove-Item -LiteralPath $archive.FullName -Recurse -Force
        $freedBytes += $bytes
        $removed.Add([pscustomobject]@{ path = $archive.FullName; branch = $branch }) | Out-Null
    }
    return [pscustomobject]@{ removedArchives = $removed.Count; freedBytes = $freedBytes; entries = @($removed) }
}

function Invoke-SourceDeliveryPostSuccessCleanup {
    param([string]$FreshProjectsRoot = 'C:\itlj', [string]$E2EProjectRoot = '', [string[]]$PreservePaths = @())

    $report = [ordered]@{ status = 'completed'; warnings = @() }
    foreach ($step in @(
        [pscustomobject]@{ name = 'sourceCandidates'; action = { Remove-SourceDeliveryStaleCandidateWorktrees -PreservePaths $PreservePaths } },
        [pscustomobject]@{ name = 'sourceTestFixtures'; action = { Remove-SourceDeliveryStaleTestFixtures } },
        [pscustomobject]@{ name = 'freshProjects'; action = { Remove-DevelopE2EStaleFreshProjects -FreshProjectsRoot $FreshProjectsRoot -PreservePaths $PreservePaths } },
        [pscustomobject]@{ name = 'freshLauncherEntries'; action = { Remove-DevelopE2EStaleLauncherRegistrations -FreshProjectsRoot $FreshProjectsRoot } }
    )) {
        try { $report[$step.name] = & $step.action }
        catch { $report.warnings += "$($step.name): $($_.Exception.Message)"; Write-Warning "Post-success cleanup $($step.name) failed: $($_.Exception.Message)" }
    }
    if ($E2EProjectRoot) {
        foreach ($step in @(
            [pscustomobject]@{ name = 'developStandWorktrees'; action = { Remove-DevelopE2EStaleStandWorktrees -ProjectRoot $E2EProjectRoot } },
            [pscustomobject]@{ name = 'releaseSeedWorktrees'; action = { Remove-SourceDeliveryStaleReleaseSeeds -ProjectRoot $E2EProjectRoot } },
            [pscustomobject]@{ name = 'releaseSeedArchives'; action = { Remove-SourceDeliveryStaleReleaseSeedArchives -ProjectRoot $E2EProjectRoot } }
        )) {
            try { $report[$step.name] = & $step.action }
            catch { $report.warnings += "$($step.name): $($_.Exception.Message)"; Write-Warning "Post-success cleanup $($step.name) failed: $($_.Exception.Message)" }
        }
    }
    try { $report.releaseLauncherEntries = Remove-ReleaseE2EStaleLauncherRegistrations }
    catch { $report.warnings += "releaseLauncherEntries: $($_.Exception.Message)"; Write-Warning "Post-success cleanup releaseLauncherEntries failed: $($_.Exception.Message)" }
    try { $report.launcherBackups = Remove-DevelopE2ELauncherListBackups -ListPath (Get-DevelopE2ELauncherListPath) }
    catch { $report.warnings += "launcherBackups: $($_.Exception.Message)"; Write-Warning "Post-success cleanup launcherBackups failed: $($_.Exception.Message)" }
    if ($report.warnings.Count -gt 0) { $report.status = 'completed-with-warnings' }
    return [pscustomobject]$report
}
