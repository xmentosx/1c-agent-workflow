Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "develop-e2e-cleanup.ps1")

function Test-SourceDeliveryPathInUse {
    param([Parameter(Mandatory = $true)][string]$Path)

    $escaped = [regex]::Escape(([IO.Path]::GetFullPath($Path)).TrimEnd('\'))
    return @((Get-CimInstance Win32_Process -ErrorAction SilentlyContinue) | Where-Object {
        [string]$_.CommandLine -match $escaped
    }).Count -gt 0
}

function Get-SourceDeliveryTreeBytes {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return [int64]0 }
    return [int64](@(Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction Stop | Measure-Object Length -Sum).Sum)
}

function Test-SourceDeliveryTreeHasReparsePoint {
    param([Parameter(Mandatory = $true)][string]$Path)

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return $true }
    return $null -ne (Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction Stop |
        Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint } |
        Select-Object -First 1)
}

function Test-SourceDeliveryArtifactExpired {
    param([Parameter(Mandatory = $true)][object]$Item, [int]$MinimumAgeHours = 168)

    return $Item.LastWriteTimeUtc -le [DateTime]::UtcNow.AddHours(-1 * [Math]::Max(0, $MinimumAgeHours))
}

function Remove-SourceDeliveryStaleVanessaBuildWork {
    param([string]$WorkRoot = 'C:\itlvabld', [int]$MinimumAgeHours = 168)

    $removed = [Collections.Generic.List[object]]::new(); $freedBytes = [int64]0; $retained = 0
    if (-not (Test-Path -LiteralPath $WorkRoot -PathType Container)) {
        return [pscustomobject]@{ removedDirectories = 0; retained = 0; freedBytes = 0; entries = @() }
    }
    $root = [IO.Path]::GetFullPath($WorkRoot).TrimEnd('\')
    if ((Get-Item -LiteralPath $root -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Vanessa build work root is a reparse point: $root"
    }
    foreach ($directory in @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction Stop)) {
        $path = [IO.Path]::GetFullPath($directory.FullName).TrimEnd('\')
        if (-not [string]::Equals((Split-Path -Parent $path), $root, [StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe Vanessa build work path: $path" }
        if ((Test-Path -LiteralPath (Join-Path $path '.git')) -or
            -not (Test-SourceDeliveryArtifactExpired -Item $directory -MinimumAgeHours $MinimumAgeHours) -or
            (Test-SourceDeliveryPathInUse -Path $path) -or
            (Test-SourceDeliveryTreeHasReparsePoint -Path $path)) { $retained++; continue }
        $bytes = Get-SourceDeliveryTreeBytes -Path $path
        Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
        $freedBytes += $bytes; $removed.Add([pscustomobject]@{ path = $path; bytes = $bytes }) | Out-Null
    }
    return [pscustomobject]@{ removedDirectories = $removed.Count; retained = $retained; freedBytes = $freedBytes; entries = @($removed) }
}

function Remove-SourceDeliveryStaleReleaseRecoveryArtifacts {
    param([string]$TempRoot = ([IO.Path]::GetTempPath()), [int]$MinimumAgeHours = 168)

    $removed = [Collections.Generic.List[object]]::new(); $freedBytes = [int64]0; $retained = 0
    $temp = [IO.Path]::GetFullPath($TempRoot).TrimEnd('\')
    $quarantineRoot = Join-Path $temp 'itl-quarantine'
    if (Test-Path -LiteralPath $quarantineRoot -PathType Container) {
        foreach ($directory in @(Get-ChildItem -LiteralPath $quarantineRoot -Directory -Force -ErrorAction Stop | Where-Object { $_.Name -match '^workflow-release-e2e-snapshots-[0-9]{8}$' })) {
            $files = @(Get-ChildItem -LiteralPath $directory.FullName -Recurse -File -Force -ErrorAction Stop)
            $ownedShape = @($files | Where-Object { $_.Name -notmatch '^release-e2e-' -or $_.Extension -notin @('.dt', '.json', '.env') }).Count -eq 0 -and
                @($files | Where-Object Extension -eq '.dt').Count -gt 0
            if (-not $ownedShape -or -not (Test-SourceDeliveryArtifactExpired -Item $directory -MinimumAgeHours $MinimumAgeHours) -or
                (Test-SourceDeliveryPathInUse -Path $directory.FullName) -or (Test-SourceDeliveryTreeHasReparsePoint -Path $directory.FullName)) { $retained++; continue }
            $bytes = Get-SourceDeliveryTreeBytes -Path $directory.FullName
            Remove-Item -LiteralPath $directory.FullName -Recurse -Force -ErrorAction Stop
            $freedBytes += $bytes; $removed.Add([pscustomobject]@{ path = $directory.FullName; bytes = $bytes }) | Out-Null
        }
    }

    foreach ($preservedRoot in @(Get-ChildItem -LiteralPath $temp -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^itl-release-e2e-preserved-[0-9]{8}-[0-9]{6}$' })) {
        $manifestPath = Join-Path $preservedRoot.FullName 'manifest.json'
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf) -or
            -not (Test-SourceDeliveryArtifactExpired -Item $preservedRoot -MinimumAgeHours $MinimumAgeHours) -or
            (Test-SourceDeliveryPathInUse -Path $preservedRoot.FullName)) { $retained++; continue }
        try { $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $retained++; continue }
        if (-not $manifest.PSObject.Properties['moved']) { $retained++; continue }
        foreach ($child in @(Get-ChildItem -LiteralPath $preservedRoot.FullName -Directory -Force -ErrorAction Stop | Where-Object { $_.Name -in @('.agent-1c', 'build') -or $_.Name -match '^broken-ai-rules-cache-[0-9]{8}-[0-9]{4}$' })) {
            $childPath = [IO.Path]::GetFullPath($child.FullName).TrimEnd('\')
            $protectedByJunction = @($manifest.moved | Where-Object {
                $junctionProperty = $_.PSObject.Properties['junction']
                $destinationProperty = $_.PSObject.Properties['destination']
                $junctionProperty -and [bool]$junctionProperty.Value -and $destinationProperty -and [string]$destinationProperty.Value -and
                ([IO.Path]::GetFullPath([string]$destinationProperty.Value).TrimEnd('\') + '\').StartsWith($childPath + '\', [StringComparison]::OrdinalIgnoreCase)
            }).Count -gt 0
            if ($protectedByJunction -or (Test-SourceDeliveryTreeHasReparsePoint -Path $childPath)) { $retained++; continue }
            $bytes = Get-SourceDeliveryTreeBytes -Path $childPath
            Remove-Item -LiteralPath $childPath -Recurse -Force -ErrorAction Stop
            $freedBytes += $bytes; $removed.Add([pscustomobject]@{ path = $childPath; bytes = $bytes }) | Out-Null
        }
    }
    return [pscustomobject]@{ removedDirectories = $removed.Count; retained = $retained; freedBytes = $freedBytes; entries = @($removed) }
}

function Remove-SourceDeliveryOldAiRulesMigrationSnapshots {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot, [int]$MinimumAgeHours = 168, [int]$Keep = 1)

    $runsRoot = Join-Path ([IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\')) '.agent-1c\runs'
    $removed = [Collections.Generic.List[object]]::new(); $freedBytes = [int64]0
    if (-not (Test-Path -LiteralPath $runsRoot -PathType Container)) { return [pscustomobject]@{ removedDirectories = 0; retained = 0; freedBytes = 0; entries = @() } }
    $passed = [Collections.Generic.List[object]]::new(); $retained = 0
    foreach ($directory in @(Get-ChildItem -LiteralPath $runsRoot -Directory -Force -ErrorAction Stop | Where-Object { $_.Name -match '^ai-rules-migration-[0-9]{8}-[0-9]{6}-[0-9]{3}$' })) {
        $reportPath = Join-Path $directory.FullName 'migration-report.json'
        try { $report = Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $retained++; continue }
        if ([string]$report.status -cne 'passed') { $retained++; continue }
        $passed.Add($directory) | Out-Null
    }
    $ordered = @($passed | Sort-Object Name -Descending)
    $retained += [Math]::Min([Math]::Max(0, $Keep), $ordered.Count)
    foreach ($directory in @($ordered | Select-Object -Skip ([Math]::Max(0, $Keep)))) {
        if (-not (Test-SourceDeliveryArtifactExpired -Item $directory -MinimumAgeHours $MinimumAgeHours) -or
            (Test-SourceDeliveryPathInUse -Path $directory.FullName) -or (Test-SourceDeliveryTreeHasReparsePoint -Path $directory.FullName)) { $retained++; continue }
        $bytes = Get-SourceDeliveryTreeBytes -Path $directory.FullName
        Remove-Item -LiteralPath $directory.FullName -Recurse -Force -ErrorAction Stop
        $freedBytes += $bytes; $removed.Add([pscustomobject]@{ path = $directory.FullName; bytes = $bytes }) | Out-Null
    }
    return [pscustomobject]@{ removedDirectories = $removed.Count; retained = $retained; freedBytes = $freedBytes; entries = @($removed) }
}

function Remove-SourceDeliveryExpiredArtifactHolds {
    param([Parameter(Mandatory = $true)][string]$SearchRoot, [int]$MinimumAgeHours = 168)

    $root = [IO.Path]::GetFullPath($SearchRoot).TrimEnd('\'); $removed = [Collections.Generic.List[object]]::new(); $freedBytes = [int64]0; $retained = 0
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return [pscustomobject]@{ removedDirectories = 0; retained = 0; freedBytes = 0; entries = @() } }
    foreach ($hold in @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction Stop | Where-Object { $_.Name -match '-artifact-hold-[0-9]{8}-[0-9]{4}$' })) {
        $build = Join-Path $hold.FullName 'build'; $testResults = Join-Path $build 'test-results'
        if (-not (Test-Path -LiteralPath $build -PathType Container)) { continue }
        if (-not (Test-Path -LiteralPath $testResults -PathType Container) -or
            -not (Test-SourceDeliveryArtifactExpired -Item (Get-Item -LiteralPath $build) -MinimumAgeHours $MinimumAgeHours) -or
            (Test-SourceDeliveryPathInUse -Path $hold.FullName) -or (Test-SourceDeliveryTreeHasReparsePoint -Path $build)) { $retained++; continue }
        $bytes = Get-SourceDeliveryTreeBytes -Path $build
        Remove-Item -LiteralPath $build -Recurse -Force -ErrorAction Stop
        $freedBytes += $bytes; $removed.Add([pscustomobject]@{ path = $build; bytes = $bytes }) | Out-Null
    }
    return [pscustomobject]@{ removedDirectories = $removed.Count; retained = $retained; freedBytes = $freedBytes; entries = @($removed) }
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
            $leaf -notmatch '^itl-source-(publish-develop|release-master|cleanup-executor)-([0-9a-f]{32})$' -or
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
                $leaf -match '^itl-source-(publish-develop|release-master|cleanup-executor)-([0-9a-f]{32})$' -and
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
    param([string]$FreshProjectsRoot = 'C:\itlj', [string]$E2EProjectRoot = '', [string[]]$PreservePaths = @(), [ValidateSet('manual', 'pre-operation', 'post-operation')][string]$Phase = 'post-operation')

    $report = [ordered]@{ status = 'completed'; warnings = @() }
    $minimumAgeHours = if ($Phase -eq 'manual') { 0 } else { 168 }
    foreach ($step in @(
        [pscustomobject]@{ name = 'sourceCandidates'; action = { Remove-SourceDeliveryStaleCandidateWorktrees -PreservePaths $PreservePaths } },
        [pscustomobject]@{ name = 'sourceTestFixtures'; action = { Remove-SourceDeliveryStaleTestFixtures } },
        [pscustomobject]@{ name = 'vanessaBuildWork'; action = { Remove-SourceDeliveryStaleVanessaBuildWork -MinimumAgeHours $minimumAgeHours } },
        [pscustomobject]@{ name = 'releaseRecoveryArtifacts'; action = { Remove-SourceDeliveryStaleReleaseRecoveryArtifacts -MinimumAgeHours $minimumAgeHours } },
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
            [pscustomobject]@{ name = 'releaseSeedArchives'; action = { Remove-SourceDeliveryStaleReleaseSeedArchives -ProjectRoot $E2EProjectRoot } },
            [pscustomobject]@{ name = 'aiRulesMigrationSnapshots'; action = { Remove-SourceDeliveryOldAiRulesMigrationSnapshots -ProjectRoot $E2EProjectRoot -MinimumAgeHours $minimumAgeHours } },
            [pscustomobject]@{ name = 'artifactHolds'; action = { Remove-SourceDeliveryExpiredArtifactHolds -SearchRoot (Split-Path -Parent ([IO.Path]::GetFullPath($E2EProjectRoot))) -MinimumAgeHours $minimumAgeHours } }
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

# Cleanup mutation is selected from the exact published channel commit while
# the stable master supervisor retains the operation lock and publication
# authority. The child validates a short-lived capability in operation.json;
# it never acquires a second delivery-operation lease.

function Get-DeliveryCleanupTokenSha256 {
    param([Parameter(Mandatory = $true)][string]$Value)

    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value)))).Replace('-', '').ToLowerInvariant()
    } finally { $algorithm.Dispose() }
}

function Resolve-DeliveryCleanupChannelCommit {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Develop', 'Master')][string]$Channel,
        [string]$ExpectedCommit = ''
    )

    $branch = $Channel.ToLowerInvariant()
    [void](Invoke-DeliveryGit -Arguments @('fetch', $script:Remote, $branch))
    $trackingRef = "$script:Remote/$branch"
    $commit = (Invoke-DeliveryGit -Arguments @('rev-parse', $trackingRef)).stdout.Trim()
    $tree = (Invoke-DeliveryGit -Arguments @('rev-parse', "$commit`^{tree}")).stdout.Trim()
    if ($commit -notmatch '^[a-f0-9]{40}$' -or $tree -notmatch '^[a-f0-9]{40}$') {
        throw "DELIVERY_CLEANUP_EXECUTOR_INVALID: unable to resolve $trackingRef."
    }
    if ($ExpectedCommit -and $commit -cne $ExpectedCommit) {
        throw "DELIVERY_CLEANUP_EXECUTOR_MOVED: expected $branch $ExpectedCommit, tracking ref is $commit."
    }
    return [pscustomobject][ordered]@{ channel=$Channel; branch=$branch; ref=$trackingRef; commit=$commit; tree=$tree }
}

function New-DeliveryCleanupExecutorWorktree {
    param([Parameter(Mandatory = $true)][string]$Commit)

    $path = Join-Path ([IO.Path]::GetTempPath()) ('itl-source-cleanup-executor-' + [guid]::NewGuid().ToString('N'))
    [void](Invoke-DeliveryGit -Arguments @('worktree', 'add', '--quiet', '--detach', $path, $Commit))
    return [IO.Path]::GetFullPath($path)
}

function Remove-DeliveryCleanupExecutorWorktree {
    param([string]$Path)

    if (-not $Path) { return }
    $resolved = [IO.Path]::GetFullPath($Path)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $resolved) -notmatch '^itl-source-cleanup-executor-[0-9a-f]{32}$') {
        throw "Refusing to remove unexpected cleanup executor worktree: $resolved"
    }
    $removed = Invoke-DeliveryGit -Arguments @('worktree', 'remove', '--force', '--force', '--', $resolved) -AllowFailure
    if ($removed.exitCode -ne 0) { throw "Cleanup executor worktree could not be removed: $resolved" }
}

function Assert-DeliveryCleanupDelegation {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Develop', 'Master')][string]$Channel,
        [Parameter(Mandatory = $true)][ValidateSet('manual', 'pre-operation', 'post-operation')][string]$Phase,
        [Parameter(Mandatory = $true)][string]$ExecutorCommit,
        [Parameter(Mandatory = $true)][string]$AuthorityCommit,
        [Parameter(Mandatory = $true)][string]$OperationId,
        [Parameter(Mandatory = $true)][string]$DelegationToken
    )

    $operation = Read-DeliveryOperation
    if (-not $operation -or [int]$operation.schemaVersion -ne 1 -or [string]$operation.id -cne $OperationId) {
        throw 'DELIVERY_CLEANUP_DELEGATION_INVALID: active operation identity does not match.'
    }
    if ([string]$operation.action -notin @('Cleanup', 'PublishDevelop', 'PromoteRelease', 'ReleaseMaster') -or
        -not (Test-DeliveryProcessIdentity -ProcessId ([int]$operation.ownerPid) -StartedAt $operation.ownerProcessStartedAt)) {
        throw 'DELIVERY_CLEANUP_DELEGATION_INVALID: authority operation is not live or does not permit cleanup.'
    }
    $delegationProperty = $operation.PSObject.Properties['cleanupDelegation']
    $delegation = if ($delegationProperty) { $delegationProperty.Value } else { $null }
    if (-not $delegation -or [int]$delegation.schemaVersion -ne 1 -or
        [string]$delegation.operationId -cne $OperationId -or
        [string]$delegation.channel -cne $Channel -or
        [string]$delegation.phase -cne $Phase -or
        [string]$delegation.commit -cne $ExecutorCommit -or
        [string]$delegation.authorityCommit -cne $AuthorityCommit -or
        [string]$delegation.tokenSha256 -cne (Get-DeliveryCleanupTokenSha256 -Value $DelegationToken) -or
        (ConvertTo-DeliveryUtcDateTime -Value $delegation.expiresAt) -le [DateTime]::UtcNow) {
        throw 'DELIVERY_CLEANUP_DELEGATION_INVALID: cleanup capability is missing, expired, or does not match the executor.'
    }
    $actualCommit = (Invoke-DeliveryGit -Arguments @('rev-parse', 'HEAD')).stdout.Trim()
    if ($actualCommit -cne $ExecutorCommit) {
        throw "DELIVERY_CLEANUP_EXECUTOR_MISMATCH: expected $ExecutorCommit, actual $actualCommit."
    }
    return $operation
}

function Invoke-DeliveryDelegatedCleanupExecutor {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Develop', 'Master')][string]$Channel,
        [Parameter(Mandatory = $true)][ValidateSet('manual', 'pre-operation', 'post-operation')][string]$Phase,
        [Parameter(Mandatory = $true)][string]$ExecutorCommit,
        [Parameter(Mandatory = $true)][string]$AuthorityCommit,
        [Parameter(Mandatory = $true)][string]$OperationId,
        [Parameter(Mandatory = $true)][string]$DelegationToken,
        [Parameter(Mandatory = $true)][string]$ResultPath,
        [string]$FreshProjectsRoot = 'C:\itlj',
        [string]$E2EProjectRoot = '',
        [switch]$CompactState
    )

    $resolvedResult = [IO.Path]::GetFullPath($ResultPath)
    New-Item -ItemType Directory -Path (Split-Path -Parent $resolvedResult) -Force | Out-Null
    $temporaryResult = "$resolvedResult.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [void](Assert-DeliveryCleanupDelegation -Channel $Channel -Phase $Phase -ExecutorCommit $ExecutorCommit -AuthorityCommit $AuthorityCommit -OperationId $OperationId -DelegationToken $DelegationToken)
        $cleanup = Invoke-DeliveryCleanupSweep -FreshProjectsRoot $FreshProjectsRoot -E2EProjectRoot $E2EProjectRoot -Phase $Phase
        $stateCompaction = if ($CompactState) {
            [pscustomobject][ordered]@{
                runIndex = (Repair-DeliveryRunHotIndex)
                resourceLedger = (Compact-DeliveryResourceLedger)
            }
        } else { $null }
        $result = [pscustomobject][ordered]@{
            schemaVersion = 1
            contract = 'source-delivery-cleanup-v1'
            status = [string]$cleanup.status
            executor = [pscustomobject][ordered]@{
                channel = $Channel.ToLowerInvariant()
                commit = $ExecutorCommit
                tree = (Invoke-DeliveryGit -Arguments @('rev-parse', 'HEAD^{tree}')).stdout.Trim()
                phase = $Phase
                authoritySupervisorCommit = $AuthorityCommit
            }
            cleanup = $cleanup
            stateCompaction = $stateCompaction
        }
        [IO.File]::WriteAllText($temporaryResult, (($result | ConvertTo-Json -Depth 18) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporaryResult -Destination $resolvedResult -Force
    } finally {
        Remove-Item -LiteralPath $temporaryResult -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-DeliveryChannelCleanup {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Develop', 'Master')][string]$Channel,
        [Parameter(Mandatory = $true)][ValidateSet('manual', 'pre-operation', 'post-operation')][string]$Phase,
        [string]$ExpectedCommit = '',
        [switch]$CompactState
    )

    if (-not $script:ActiveOperation) { throw 'Channel cleanup requires an active delivery-operation lease.' }
    $source = Resolve-DeliveryCleanupChannelCommit -Channel $Channel -ExpectedCommit $ExpectedCommit
    $executorRoot = ''
    $process = $null
    $processJob = [IntPtr]::Zero
    $token = [guid]::NewGuid().ToString('N')
    $runId = [guid]::NewGuid().ToString('N')
    $logRoot = Join-Path (Get-DeliveryCommonGitDirectory) "itl\cleanup-runs\v1\$([string]$script:ActiveOperation.id)\$runId"
    New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
    $resultPath = Join-Path $logRoot 'result.json'
    $stdoutPath = Join-Path $logRoot 'stdout.log'
    $stderrPath = Join-Path $logRoot 'stderr.log'
    try {
        $executorRoot = New-DeliveryCleanupExecutorWorktree -Commit ([string]$source.commit)
        $executorPath = Join-Path $executorRoot 'scripts\source-delivery-supervisor.ps1'
        if (-not (Test-Path -LiteralPath $executorPath -PathType Leaf)) {
            throw "DELIVERY_CLEANUP_EXECUTOR_UNAVAILABLE: $($source.ref) at $($source.commit) does not contain the cleanup executor contract."
        }
        $delegation = [pscustomobject][ordered]@{
            schemaVersion = 1
            operationId = [string]$script:ActiveOperation.id
            channel = $Channel
            phase = $Phase
            commit = [string]$source.commit
            tree = [string]$source.tree
            authorityCommit = [string]$script:DeliverySupervisorCommit
            tokenSha256 = Get-DeliveryCleanupTokenSha256 -Value $token
            createdAt = [DateTime]::UtcNow.ToString('o')
            expiresAt = [DateTime]::UtcNow.AddMinutes(30).ToString('o')
            status = 'starting'
        }
        Update-DeliveryOperation -Values @{ cleanupDelegation=$delegation; cleanupExecutorPid=0; cleanupExecutorStatus='starting' }
        $arguments = @(
            '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $executorPath,
            '-Action', 'Cleanup', '-RepositoryRoot', $executorRoot, '-Remote', $script:Remote,
            '-CleanupExecutor', '-CleanupExecutorChannel', $Channel, '-CleanupExecutorPhase', $Phase,
            '-CleanupExecutorCommit', [string]$source.commit, '-CleanupAuthorityCommit', [string]$script:DeliverySupervisorCommit,
            '-CleanupOperationId', [string]$script:ActiveOperation.id, '-CleanupDelegationToken', $token,
            '-CleanupResultPath', $resultPath, '-FreshProjectsRoot', $FreshProjectsRoot
        )
        if ($E2EProjectRoot) { $arguments += @('-E2EProjectRoot', [IO.Path]::GetFullPath($E2EProjectRoot)) }
        if ($CompactState) { $arguments += '-CleanupCompactState' }
        $argumentLine = @($arguments | ForEach-Object { ConvertTo-DeliveryNativeArgument -Value ([string]$_) }) -join ' '
        $started = Start-DeliveryProcess -ArgumentList $argumentLine -WorkingDirectory $executorRoot -StandardOutputPath $stdoutPath -StandardErrorPath $stderrPath
        $process = $started.process
        $processJob = [IntPtr]$started.jobHandle
        $delegation.status = 'running'
        $delegation | Add-Member -NotePropertyName childPid -NotePropertyValue ([int]$process.Id) -Force
        $delegation | Add-Member -NotePropertyName childProcessStartedAt -NotePropertyValue ($process.StartTime.ToUniversalTime().ToString('o')) -Force
        Update-DeliveryOperation -Values @{ cleanupDelegation=$delegation; cleanupExecutorPid=[int]$process.Id; cleanupExecutorStatus='running' }
        if (-not $process.WaitForExit(1800000)) {
            Stop-DeliveryProcessTree -Process $process
            throw "DELIVERY_CLEANUP_TIMEOUT: $Channel $Phase cleanup exceeded 30 minutes."
        }
        $process.WaitForExit(); $process.Refresh()
        if ([int]$process.ExitCode -ne 0) {
            $stderr = if (Test-Path -LiteralPath $stderrPath) { (Get-Content -LiteralPath $stderrPath -Raw -Encoding UTF8).Trim() } else { '' }
            throw "DELIVERY_CLEANUP_EXECUTOR_FAILED: $Channel $Phase cleanup exited with $($process.ExitCode). $stderr"
        }
        if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) { throw 'DELIVERY_CLEANUP_RESULT_MISSING: cleanup executor did not write result.json.' }
        $result = Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([int]$result.schemaVersion -ne 1 -or [string]$result.contract -cne 'source-delivery-cleanup-v1' -or
            [string]$result.executor.channel -cne $Channel.ToLowerInvariant() -or
            [string]$result.executor.commit -cne [string]$source.commit -or
            [string]$result.executor.tree -cne [string]$source.tree -or
            [string]$result.executor.phase -cne $Phase) {
            throw 'DELIVERY_CLEANUP_RESULT_INVALID: cleanup executor identity or contract does not match the delegated source.'
        }
        Update-DeliveryOperation -Values @{ cleanupExecutorPid=0; cleanupExecutorStatus=[string]$result.status }
        return $result
    } finally {
        $closeError = $null
        try { Close-DeliveryProcessJob -JobHandle $processJob -Process $process } catch { $closeError = $_ }
        Stop-DeliveryProcessTree -Process $process
        try { Remove-DeliveryCleanupExecutorWorktree -Path $executorRoot } catch { if (-not $closeError) { $closeError = $_ } }
        if ($script:ActiveOperation) { Update-DeliveryOperation -Values @{ cleanupDelegation=$null; cleanupExecutorPid=0 } }
        if ($closeError) { throw $closeError }
    }
}

function New-DeliveryCleanupFailureResult {
    param(
        [Parameter(Mandatory = $true)][string]$Channel,
        [Parameter(Mandatory = $true)][string]$Phase,
        [Parameter(Mandatory = $true)][string]$Message
    )

    return [pscustomobject][ordered]@{
        schemaVersion = 1
        contract = 'source-delivery-cleanup-v1'
        status = 'completed-with-warnings'
        executor = [pscustomobject][ordered]@{
            channel = $Channel.ToLowerInvariant(); commit=''; tree=''; phase=$Phase
            authoritySupervisorCommit=[string]$script:DeliverySupervisorCommit; status='unavailable'
        }
        cleanup = [pscustomobject][ordered]@{ status='completed-with-warnings'; phase=$Phase; warnings=@($Message); debt=(Get-DeliveryResourceLedgerSummary) }
        stateCompaction = $null
    }
}

function Invoke-DeliveryChannelCleanupSafely {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Develop', 'Master')][string]$Channel,
        [Parameter(Mandatory = $true)][ValidateSet('manual', 'pre-operation', 'post-operation')][string]$Phase,
        [string]$ExpectedCommit = '',
        [switch]$CompactState
    )

    try { return Invoke-DeliveryChannelCleanup -Channel $Channel -Phase $Phase -ExpectedCommit $ExpectedCommit -CompactState:$CompactState }
    catch {
        $message = "$Channel cleanup executor failed closed: $($_.Exception.Message)"
        Write-Warning $message
        return New-DeliveryCleanupFailureResult -Channel $Channel -Phase $Phase -Message $message
    }
}

function Add-DeliveryCleanupResults {
    param([Parameter(Mandatory = $true)][object]$Result, [Parameter(Mandatory = $true)][object[]]$Runs)

    $allRuns = @($Runs | Where-Object { $_ })
    $Result | Add-Member -NotePropertyName cleanupRuns -NotePropertyValue $allRuns -Force
    if ($allRuns.Count -gt 0) { $Result | Add-Member -NotePropertyName cleanup -NotePropertyValue $allRuns[-1] -Force }
    if (@($allRuns | Where-Object { [string]$_.status -eq 'completed-with-warnings' }).Count -gt 0) {
        $Result | Add-Member -NotePropertyName deliveryStatus -NotePropertyValue 'completed-with-cleanup-warnings' -Force
    }
    return $Result
}

function Invoke-PublishDevelopWithCleanup {
    $pre = Invoke-DeliveryChannelCleanupSafely -Channel Develop -Phase pre-operation
    $published = Publish-AccumulatedDevelop
    $post = Invoke-DeliveryChannelCleanupSafely -Channel Develop -Phase post-operation -ExpectedCommit ([string]$published.commit)
    return Add-DeliveryCleanupResults -Result $published -Runs @($pre, $post)
}

function Invoke-ReleaseMasterWithCleanup {
    param(
        [string]$PrequalifiedCommit = '',
        [string]$PrequalifiedTree = '',
        [DateTime]$PrequalifiedNotBefore = [DateTime]::MinValue,
        [switch]$ReusePrequalifiedGates
    )

    $pre = Invoke-DeliveryChannelCleanupSafely -Channel Master -Phase pre-operation
    $released = Release-DevelopToMaster @PSBoundParameters
    $post = Invoke-DeliveryChannelCleanupSafely -Channel Master -Phase post-operation -ExpectedCommit ([string]$released.masterCommit)
    return Add-DeliveryCleanupResults -Result $released -Runs @($pre, $post)
}
