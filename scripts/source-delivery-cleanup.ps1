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
    $removed = [Collections.Generic.List[object]]::new()
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    foreach ($worktree in @(Get-DevelopE2ERegisteredWorktrees -ProjectRoot $script:Root)) {
        $path = [IO.Path]::GetFullPath([string]$worktree.path).TrimEnd('\')
        $leaf = Split-Path -Leaf $path
        $branch = [string]$worktree.branch
        if (-not $path.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
            $leaf -notmatch '^itl-source-(publish-develop|release-master)-([0-9a-f]{32})$' -or
            $branch -cne "refs/heads/itl/$($matches[1])-$($matches[2])" -or
            (Test-SourceDeliveryPathInUse -Path $path)) { continue }
        $shortBranch = $branch.Substring('refs/heads/'.Length)
        $remove = Invoke-DeliveryGit -Arguments @('worktree', 'remove', '--force', '--force', '--', $path) -AllowFailure
        if ($remove.exitCode -ne 0) { throw "Unable to remove stale delivery candidate '$path': $($remove.stderr.Trim())" }
        $delete = Invoke-DeliveryGit -Arguments @('branch', '-D', '--', $shortBranch) -AllowFailure
        if ($delete.exitCode -ne 0) { throw "Removed stale delivery candidate '$path', but could not delete '$shortBranch': $($delete.stderr.Trim())" }
        $removed.Add([pscustomobject]@{ path = $path; branch = $shortBranch }) | Out-Null
    }
    return [pscustomobject]@{ removedWorktrees = $removed.Count; entries = @($removed) }
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
        $shortBranch = $branch.Substring('refs/heads/'.Length)
        $remove = Invoke-RepositoryGit -RepositoryRoot $ProjectRoot -Arguments @('worktree', 'remove', '--force', '--force', '--', $path) -AllowFailure
        if ($remove.exitCode -ne 0) { throw "Unable to remove stale release seed '$path': $($remove.stderr.Trim())" }
        $delete = Invoke-RepositoryGit -RepositoryRoot $ProjectRoot -Arguments @('branch', '-D', '--', $shortBranch) -AllowFailure
        if ($delete.exitCode -ne 0) { throw "Removed stale release seed '$path', but could not delete '$shortBranch': $($delete.stderr.Trim())" }
        $removed.Add([pscustomobject]@{ path = $path; branch = $shortBranch }) | Out-Null
    }
    return [pscustomobject]@{ removedWorktrees = $removed.Count; entries = @($removed) }
}

function Invoke-SourceDeliveryPostSuccessCleanup {
    param([string]$FreshProjectsRoot = 'C:\itlj', [string]$E2EProjectRoot = '')

    $report = [ordered]@{ status = 'completed'; warnings = @() }
    foreach ($step in @(
        [pscustomobject]@{ name = 'sourceCandidates'; action = { Remove-SourceDeliveryStaleCandidateWorktrees } },
        [pscustomobject]@{ name = 'freshProjects'; action = { Remove-DevelopE2EStaleFreshProjects -FreshProjectsRoot $FreshProjectsRoot } },
        [pscustomobject]@{ name = 'freshLauncherEntries'; action = { Remove-DevelopE2EStaleLauncherRegistrations -FreshProjectsRoot $FreshProjectsRoot } }
    )) {
        try { $report[$step.name] = & $step.action }
        catch { $report.warnings += "$($step.name): $($_.Exception.Message)"; Write-Warning "Post-success cleanup $($step.name) failed: $($_.Exception.Message)" }
    }
    if ($E2EProjectRoot) {
        foreach ($step in @(
            [pscustomobject]@{ name = 'developStandWorktrees'; action = { Remove-DevelopE2EStaleStandWorktrees -ProjectRoot $E2EProjectRoot } },
            [pscustomobject]@{ name = 'releaseSeedWorktrees'; action = { Remove-SourceDeliveryStaleReleaseSeeds -ProjectRoot $E2EProjectRoot } }
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
