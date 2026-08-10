Set-StrictMode -Version Latest

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
