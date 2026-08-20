Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "git-path-list.ps1")

function Get-DevelopE2ELauncherListPath {
    $appData = $env:APPDATA
    if (-not $appData) { $appData = [Environment]::GetFolderPath("ApplicationData") }
    if (-not $appData) { throw "APPDATA path is not available; cannot clean the 1C infobase list." }
    return (Join-Path $appData "1C\1CEStart\ibases.v8i")
}

function Get-DevelopE2ELauncherSections {
    param([AllowEmptyString()][string[]]$Lines)

    $sections = New-Object System.Collections.ArrayList
    $current = $null
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $line = $Lines[$i]
        if ($line -match '^\[(.*)\]\s*$') {
            if ($null -ne $current) {
                $current["end"] = $i - 1
                [void]$sections.Add([pscustomobject]$current)
            }
            $current = @{ name = $matches[1]; start = $i; end = $i; values = @{} }
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

function Enter-DevelopE2ELauncherListLock {
    param([Parameter(Mandatory = $true)][string]$ListPath, [int]$TimeoutSeconds = 30)

    $lockPath = "$ListPath.itl.lock"
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $lockPath) | Out-Null
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        try {
            return [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        } catch [System.IO.IOException] {
            if ((Get-Date) -ge $deadline) { throw "LAUNCHER_LIST_LOCK_TIMEOUT path='$lockPath' timeoutSeconds='$TimeoutSeconds'" }
            Start-Sleep -Milliseconds 50
        }
    } while ($true)
}

function Write-DevelopE2ELauncherSectionsRemoved {
    param(
        [Parameter(Mandatory = $true)][string]$ListPath,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string[]]$Lines,
        [Parameter(Mandatory = $true)][object[]]$Sections,
        [Parameter(Mandatory = $true)][int[]]$SectionStarts
    )

    $removeLines = [Collections.Generic.HashSet[int]]::new()
    foreach ($section in $Sections) {
        if ($SectionStarts -notcontains [int]$section.start) { continue }
        for ($i = [int]$section.start; $i -le [int]$section.end; $i++) { [void]$removeLines.Add($i) }
    }
    if ($removeLines.Count -eq 0) { return $false }

    $result = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if (-not $removeLines.Contains($i)) { [void]$result.Add($Lines[$i]) }
    }
    $backupPath = "$ListPath.$(Get-Date -Format 'yyyyMMdd-HHmmss-fff').bak"
    Copy-Item -LiteralPath $ListPath -Destination $backupPath
    [IO.File]::WriteAllLines($ListPath, [string[]]$result.ToArray([string]), [Text.UTF8Encoding]::new($true))
    $removedNames = @($Sections | Where-Object { $SectionStarts -contains [int]$_.start } | ForEach-Object { [string]$_.name })
    Write-Host "Removed stale Develop E2E entries from 1C launcher list: $($removedNames -join ', ')"
    Write-Host "Launcher list backup: $backupPath"
    return $true
}

function Remove-DevelopE2ELauncherRegistration {
    param(
        [Parameter(Mandatory = $true)][string]$FreshProjectsRoot,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$BranchPath,
        [string]$LauncherListPath = ""
    )

    $resolvedRoot = [IO.Path]::GetFullPath($FreshProjectsRoot).TrimEnd('\') + '\'
    $resolved = [IO.Path]::GetFullPath($Path)
    $branchResolved = [IO.Path]::GetFullPath($BranchPath)
    $projectName = Split-Path -Leaf $resolved
    $branchName = Split-Path -Leaf $branchResolved
    if (-not $resolved.StartsWith($resolvedRoot, [StringComparison]::OrdinalIgnoreCase) -or $projectName -notmatch '^d-[0-9a-f]{8}$') {
        throw "Refusing to clean unexpected fresh journey launcher project: $resolved"
    }
    if (-not $branchResolved.StartsWith($resolvedRoot, [StringComparison]::OrdinalIgnoreCase) -or $branchName -cne "$projectName-develop-golden") {
        throw "Refusing to clean unexpected fresh journey launcher branch: $branchResolved"
    }

    if (-not $LauncherListPath) { $LauncherListPath = Get-DevelopE2ELauncherListPath }
    if (-not (Test-Path -LiteralPath $LauncherListPath -PathType Leaf)) { return $false }
    $lock = Enter-DevelopE2ELauncherListLock -ListPath $LauncherListPath
    try {
        $lines = @([IO.File]::ReadAllLines($LauncherListPath))
        $sections = @(Get-DevelopE2ELauncherSections -Lines $lines)
        $expectedFolder = "/ITL/$projectName"
        $expectedInfoBasePath = [IO.Path]::GetFullPath((Join-Path $branchResolved ".agent-1c\infobases\dev-branches\develop-golden"))
        $expectedConnect = "File=`"$expectedInfoBasePath`";"
        $base = @($sections | Where-Object {
            $_.name -ceq $branchName -and
            $_.values.ContainsKey("Folder") -and $_.values["Folder"] -ceq $expectedFolder -and
            $_.values.ContainsKey("Connect") -and [string]::Equals([string]$_.values["Connect"], $expectedConnect, [StringComparison]::OrdinalIgnoreCase)
        })
        if ($base.Count -eq 0) { return $false }
        if ($base.Count -ne 1) { throw "Expected exactly one Develop E2E launcher entry for '$branchName', found $($base.Count)." }

        $starts = [Collections.Generic.List[int]]::new()
        $starts.Add([int]$base[0].start)
        $remainingInFolder = @($sections | Where-Object {
            [int]$_.start -ne [int]$base[0].start -and $_.values.ContainsKey("Folder") -and $_.values["Folder"] -ceq $expectedFolder
        })
        $folder = @($sections | Where-Object {
            $_.name -ceq $projectName -and -not $_.values.ContainsKey("Connect") -and
            $_.values.ContainsKey("Folder") -and $_.values["Folder"] -ceq "/ITL"
        })
        if ($remainingInFolder.Count -eq 0 -and $folder.Count -eq 1) { $starts.Add([int]$folder[0].start) }
        return (Write-DevelopE2ELauncherSectionsRemoved -ListPath $LauncherListPath -Lines $lines -Sections $sections -SectionStarts $starts.ToArray())
    } finally {
        $lock.Dispose()
    }
}

function Remove-DevelopE2EStaleLauncherRegistrations {
    param([Parameter(Mandatory = $true)][string]$FreshProjectsRoot, [string]$LauncherListPath = "")

    if (-not $LauncherListPath) { $LauncherListPath = Get-DevelopE2ELauncherListPath }
    if (-not (Test-Path -LiteralPath $LauncherListPath -PathType Leaf)) { return 0 }
    $resolvedRoot = [IO.Path]::GetFullPath($FreshProjectsRoot).TrimEnd('\') + '\'
    $lock = Enter-DevelopE2ELauncherListLock -ListPath $LauncherListPath
    try {
        $lines = @([IO.File]::ReadAllLines($LauncherListPath))
        $sections = @(Get-DevelopE2ELauncherSections -Lines $lines)
        $starts = [Collections.Generic.List[int]]::new()
        $projects = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($section in $sections) {
            if ([string]$section.name -notmatch '^(d-[0-9a-f]{8})-develop-golden$') { continue }
            $projectName = $matches[1]
            $expectedFolder = "/ITL/$projectName"
            if (-not $section.values.ContainsKey("Folder") -or $section.values["Folder"] -cne $expectedFolder -or -not $section.values.ContainsKey("Connect")) { continue }
            $connect = [string]$section.values["Connect"]
            if ($connect -notmatch '^File="([^"]+)";$') { continue }
            $infoBasePath = [IO.Path]::GetFullPath($matches[1])
            $expectedPrefix = [IO.Path]::GetFullPath((Join-Path $resolvedRoot "$projectName-develop-golden")).TrimEnd('\') + '\'
            if (-not $infoBasePath.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $infoBasePath)) { continue }
            $starts.Add([int]$section.start)
            [void]$projects.Add($projectName)
        }
        foreach ($projectName in $projects) {
            $expectedFolder = "/ITL/$projectName"
            $retainedInFolder = @($sections | Where-Object {
                $starts -notcontains [int]$_.start -and $_.values.ContainsKey("Folder") -and $_.values["Folder"] -ceq $expectedFolder
            })
            $folder = @($sections | Where-Object {
                $_.name -ceq $projectName -and -not $_.values.ContainsKey("Connect") -and
                $_.values.ContainsKey("Folder") -and $_.values["Folder"] -ceq "/ITL"
            })
            if ($retainedInFolder.Count -eq 0 -and $folder.Count -eq 1) { $starts.Add([int]$folder[0].start) }
        }
        if ($starts.Count -eq 0) { return 0 }
        [void](Write-DevelopE2ELauncherSectionsRemoved -ListPath $LauncherListPath -Lines $lines -Sections $sections -SectionStarts $starts.ToArray())
        return $projects.Count
    } finally {
        $lock.Dispose()
    }
}

function Remove-DevelopE2EFreshProject {
    param([Parameter(Mandatory = $true)][string]$FreshProjectsRoot, [string]$Path, [string]$BranchPath = "", [string]$LauncherListPath = "")
    if (-not $Path) { return }
    $resolved = [IO.Path]::GetFullPath($Path)
    $allowed = [IO.Path]::GetFullPath($FreshProjectsRoot).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $resolved) -notlike "d-*") { throw "Refusing to remove unexpected fresh journey path: $resolved" }
    if ($BranchPath) {
        $branchResolved = [IO.Path]::GetFullPath($BranchPath)
        $expectedBranchLeaf = (Split-Path -Leaf $resolved) + "-*"
        if (-not $branchResolved.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $branchResolved) -notlike $expectedBranchLeaf) { throw "Refusing to remove unexpected fresh journey branch path: $branchResolved" }
        [void](Remove-DevelopE2ELauncherRegistration -FreshProjectsRoot $FreshProjectsRoot -Path $resolved -BranchPath $branchResolved -LauncherListPath $LauncherListPath)
        if ((Test-Path -LiteralPath $resolved -PathType Container) -and (Test-Path -LiteralPath $branchResolved -PathType Container)) {
            & git -C $resolved worktree remove --force $branchResolved
            if ($LASTEXITCODE -ne 0) { throw "Unable to remove fresh journey branch worktree: $branchResolved" }
        }
    }
    if (Test-Path -LiteralPath $resolved -PathType Container) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}

function Remove-DevelopE2EExportArtifacts {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][object]$Summary
    )

    $resolvedRoot = [IO.Path]::GetFullPath($Root)
    $resultRoot = [IO.Path]::GetFullPath((Join-Path $resolvedRoot "build\result"))
    $resultPrefix = $resultRoot.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $manifestPath = [IO.Path]::GetFullPath([string]$Summary.resultManifestPath)
    if (-not $manifestPath.StartsWith($resultPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $manifestPath) -notlike "*.cf.manifest.json" -or
        -not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Refusing to clean an unexpected Develop E2E result manifest: $manifestPath"
    }

    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $artifactPath = [IO.Path]::GetFullPath([string]$manifest.artifact.path)
    if (-not $artifactPath.StartsWith($resultPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetExtension($artifactPath) -cne ".cf" -or
        -not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
        throw "Refusing to clean an unexpected Develop E2E result artifact: $artifactPath"
    }
    $expectedSha256 = ([string]$manifest.artifact.sha256).ToLowerInvariant()
    $actualSha256 = (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($expectedSha256 -notmatch '^[a-f0-9]{64}$' -or $actualSha256 -cne $expectedSha256) {
        throw "Develop E2E result artifact SHA256 does not match its manifest: $artifactPath"
    }

    $artifacts = @(Get-ChildItem -LiteralPath $resultRoot -File -Force -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -like "*.cf" -or $_.Name -like "*.cf.manifest.json"
    })
    $removedBytes = [int64](($artifacts | Measure-Object -Property Length -Sum).Sum)
    foreach ($artifact in $artifacts) {
        Remove-Item -LiteralPath $artifact.FullName -Force
    }
    return [pscustomobject]@{
        resultRoot = $resultRoot
        removedFiles = $artifacts.Count
        removedBytes = $removedBytes
    }
}

function Get-DevelopE2ERegisteredWorktrees {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)

    $tokens = @(Get-RepositoryGitPathList -RepositoryRoot $ProjectRoot -Arguments @("worktree", "list", "--porcelain", "-z"))
    $records = New-Object System.Collections.Generic.List[object]
    $current = $null
    foreach ($token in $tokens) {
        if ($token -like "worktree *") {
            if ($null -ne $current) { $records.Add([pscustomobject]$current) | Out-Null }
            $current = [ordered]@{ path = [IO.Path]::GetFullPath($token.Substring(9)); branch = "" }
            continue
        }
        if ($null -ne $current -and $token -like "branch *") {
            $current.branch = $token.Substring(7)
        }
    }
    if ($null -ne $current) { $records.Add([pscustomobject]$current) | Out-Null }
    return @($records | ForEach-Object { $_ })
}

function Remove-DevelopE2EStaleStandWorktrees {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)

    $resolvedProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)
    $configPath = Join-Path $resolvedProjectRoot ".agent-1c\release-e2e.json"
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        throw "Develop E2E stand config is missing: $configPath"
    }
    $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $preservedPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    [void]$preservedPaths.Add($resolvedProjectRoot.TrimEnd('\', '/'))
    foreach ($propertyName in @("worktreePath", "developWorktreePath")) {
        if ($config.PSObject.Properties[$propertyName] -and [string]$config.$propertyName) {
            [void]$preservedPaths.Add(([IO.Path]::GetFullPath([string]$config.$propertyName)).TrimEnd('\', '/'))
        }
    }

    $removed = New-Object System.Collections.Generic.List[object]
    foreach ($worktree in @(Get-DevelopE2ERegisteredWorktrees -ProjectRoot $resolvedProjectRoot)) {
        $path = ([IO.Path]::GetFullPath([string]$worktree.path)).TrimEnd('\', '/')
        $branch = [string]$worktree.branch
        if ($preservedPaths.Contains($path) -or $branch -notmatch '^refs/heads/itldev/workflow-release-e2e(?:-[A-Za-z0-9._-]+)?$') { continue }
        if (Test-Path -LiteralPath $path -PathType Container) {
            $status = Invoke-RepositoryGit -RepositoryRoot $path -Arguments @("status", "--porcelain", "--untracked-files=no")
            if ($status.stdout) { throw "Refusing to remove a stale Develop E2E worktree with tracked changes: $path" }
        }
        $remove = Invoke-RepositoryGit -RepositoryRoot $resolvedProjectRoot -Arguments @("worktree", "remove", "--force", "--force", "--", $path) -AllowFailure
        if ($remove.exitCode -ne 0) { throw "Unable to remove stale Develop E2E worktree '$path': $($remove.stderr.Trim())" }
        $shortBranch = $branch.Substring("refs/heads/".Length)
        $delete = Invoke-RepositoryGit -RepositoryRoot $resolvedProjectRoot -Arguments @("branch", "-D", "--", $shortBranch) -AllowFailure
        if ($delete.exitCode -ne 0) { throw "Removed stale Develop E2E worktree '$path', but could not delete branch '$shortBranch': $($delete.stderr.Trim())" }
        $removed.Add([pscustomobject]@{ path = $path; branch = $shortBranch }) | Out-Null
    }
    return [pscustomobject]@{ removedWorktrees = $removed.Count; entries = @($removed | ForEach-Object { $_ }) }
}
