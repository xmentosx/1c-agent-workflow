function Get-ItlArtifactRetentionPolicy {
    $enabledText = ([string](Get-EnvValue -Name 'ITL_ARTIFACT_CLEANUP_ENABLED' -Default 'true')).Trim().ToLowerInvariant()
    if ($enabledText -notin @('true', 'false')) { throw "ITL_ARTIFACT_CLEANUP_ENABLED must be true or false: '$enabledText'." }
    $defaults = [ordered]@{
        ITL_RESULT_ARTIFACT_KEEP_COUNT = 3
        ITL_RECOVERY_ARCHIVE_KEEP_COUNT = 2
        ITL_RUN_ARTIFACT_KEEP_COUNT = 3
        ITL_RUNTIME_ARTIFACT_RETENTION_DAYS = 7
    }
    $values = @{}
    foreach ($name in $defaults.Keys) {
        $raw = ([string](Get-EnvValue -Name $name -Default $defaults[$name])).Trim()
        $parsed = 0
        if ($raw -notmatch '^\d+$' -or -not [int]::TryParse($raw, [ref]$parsed) -or $parsed -lt 1 -or $parsed -gt 3650) {
            throw "$name must be an integer from 1 to 3650: '$raw'."
        }
        $values[$name] = $parsed
    }
    return [pscustomobject]@{
        enabled = ($enabledText -eq 'true')
        resultKeepCount = $values.ITL_RESULT_ARTIFACT_KEEP_COUNT
        archiveKeepCount = $values.ITL_RECOVERY_ARCHIVE_KEEP_COUNT
        runKeepCount = $values.ITL_RUN_ARTIFACT_KEEP_COUNT
        runtimeDays = $values.ITL_RUNTIME_ARTIFACT_RETENTION_DAYS
    }
}

function Test-ItlArtifactPathInside {
    param([string]$Root, [string]$Path, [switch]$AllowRoot)
    if (-not $Root -or -not $Path) { return $false }
    $base = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $target = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    if ($AllowRoot -and [string]::Equals($base, $target, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $target.StartsWith(($base + [IO.Path]::DirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase)
}

function Test-ItlArtifactPathWithoutReparse {
    param([string]$Root, [string]$Path, [switch]$Recursive)
    if (-not (Test-ItlArtifactPathInside -Root $Root -Path $Path -AllowRoot)) { return $false }
    $base = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $target = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $parts = @($base)
    if ($target.Length -gt $base.Length) {
        $cursor = $base
        foreach ($part in $target.Substring($base.Length + 1).Split([IO.Path]::DirectorySeparatorChar)) {
            $cursor = Join-Path $cursor $part
            $parts += $cursor
        }
    }
    foreach ($part in $parts) {
        $item = Get-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
        if ($null -eq $item -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $false }
    }
    if (-not $Recursive) { return $true }
    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($target)
    while ($pending.Count -gt 0) {
        $folder = $pending.Pop()
        foreach ($item in @(Get-ChildItem -LiteralPath $folder -Force -ErrorAction Stop)) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return $false }
            if ($item.PSIsContainer) { $pending.Push($item.FullName) }
        }
    }
    return $true
}

function Get-ItlArtifactProtectedPaths {
    param([string]$ProjectRoot = $script:ProjectRoot)
    $paths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($candidate in @($script:ResolvedRunStatusPath, $script:ResolvedRunLogPath, $script:RunResultPath, $script:RunResultManifestPath)) {
        if ($candidate -and [IO.Path]::IsPathRooted([string]$candidate)) { [void]$paths.Add([IO.Path]::GetFullPath([string]$candidate)) }
    }
    $stateFiles = @(Get-DevBranchStateFiles)
    foreach ($file in $stateFiles) {
            try {
                $state = Read-Utf8Text -Path $file.FullName | ConvertFrom-Json
                foreach ($name in @('lastResultPath', 'lastResultManifestPath', 'finalResultPath', 'finalResultManifestPath', 'lastUnverifiedResultPath', 'lastVanessaStatusPath', 'lastVanessaReportPath', 'lastVanessaLogPath', 'lastYAxUnitReportPath', 'lastYAxUnitLogPath')) {
                    $value = [string](Get-StateValue -State $state -Name $name -Default '')
                    if ($value -and [IO.Path]::IsPathRooted($value)) { [void]$paths.Add([IO.Path]::GetFullPath($value)) }
                }
                if ([string](Get-StateValue -State $state -Name 'resetStatus' -Default '') -eq 'resetting') {
                    $value = [string](Get-StateValue -State $state -Name 'resetArchivePath' -Default '')
                    if ($value -and [IO.Path]::IsPathRooted($value)) { [void]$paths.Add([IO.Path]::GetFullPath($value)) }
                }
            } catch { throw "ITL_ARTIFACT_STATE_UNREADABLE: $($file.FullName): $($_.Exception.Message)" }
    }
    $auxRoot = Join-Path $ProjectRoot '.agent-1c\auxiliary-contours'
    if (Test-Path -LiteralPath $auxRoot -PathType Container) {
        foreach ($file in @(Get-ChildItem -LiteralPath $auxRoot -File -Filter '*.json' -Recurse -ErrorAction Stop)) {
            try {
                $state = Read-Utf8Text -Path $file.FullName | ConvertFrom-Json
                foreach ($name in @('lastResultPath', 'lastResultManifestPath')) {
                    $value = [string](Get-StateValue -State $state -Name $name -Default '')
                    if ($value -and [IO.Path]::IsPathRooted($value)) { [void]$paths.Add([IO.Path]::GetFullPath($value)) }
                }
            } catch { throw "ITL_ARTIFACT_STATE_UNREADABLE: $($file.FullName): $($_.Exception.Message)" }
        }
    }
    return $paths
}

function Test-ItlArtifactProtected {
    param([string]$Path, [object]$ProtectedPaths)
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    foreach ($protected in $ProtectedPaths) {
        $saved = ([string]$protected).TrimEnd('\', '/')
        if ([string]::Equals($full, $saved, [StringComparison]::OrdinalIgnoreCase) -or
            (Test-ItlArtifactPathInside -Root $full -Path $saved) -or
            (Test-ItlArtifactPathInside -Root $saved -Path $full)) { return $true }
    }
    return $false
}

function New-ItlArtifactRetentionCandidate {
    param([string]$Category, [string]$Root, [string]$Path, [string]$Group, [datetime]$ModifiedAt,
        [string]$Companion = '', [string]$ExpectedSha256 = '')
    return [pscustomobject]@{
        category = $Category; root = $Root; path = $Path; group = $Group
        modifiedAt = $ModifiedAt; companion = $Companion; expectedSha256 = $ExpectedSha256
    }
}

function Get-ItlResultArtifactCandidates {
    param([string]$ProjectRoot)
    $resultRoot = Resolve-ProjectPath (Get-ConfigValue -Path 'artifactsPath' -Default 'build/result')
    if (-not (Test-ItlArtifactPathInside -Root $ProjectRoot -Path $resultRoot) -or
        -not (Test-Path -LiteralPath $resultRoot -PathType Container)) { return @() }
    $folders = @($resultRoot)
    $auxiliaryRoot = Join-Path $resultRoot 'auxiliary'
    if (Test-Path -LiteralPath $auxiliaryRoot -PathType Container) {
        $folders += @(Get-ChildItem -LiteralPath $auxiliaryRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object FullName)
    }
    $items = @()
    foreach ($folder in $folders) {
        if (-not (Test-ItlArtifactPathWithoutReparse -Root $ProjectRoot -Path $folder)) { continue }
        foreach ($manifestFile in @(Get-ChildItem -LiteralPath $folder -File -Filter '*.manifest.json' -ErrorAction SilentlyContinue)) {
            $artifactPath = $manifestFile.FullName.Substring(0, $manifestFile.FullName.Length - '.manifest.json'.Length)
            if ($artifactPath -notmatch '(?i)\.(cf|cfe)$' -or -not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) { continue }
            if (-not (Test-ItlArtifactPathWithoutReparse -Root $resultRoot -Path $artifactPath) -or
                -not (Test-ItlArtifactPathWithoutReparse -Root $resultRoot -Path $manifestFile.FullName)) { continue }
            try {
                $manifest = Read-Utf8Text -Path $manifestFile.FullName | ConvertFrom-Json
                $recordedPath = if ($manifest.PSObject.Properties.Name -contains 'artifact') { [string]$manifest.artifact.path } else { [string]$manifest.resultPath }
                $hash = if ($manifest.PSObject.Properties.Name -contains 'artifact') { [string]$manifest.artifact.sha256 } else { [string]$manifest.sha256 }
                if (-not [string]::Equals([IO.Path]::GetFullPath($recordedPath), $artifactPath, [StringComparison]::OrdinalIgnoreCase) -or
                    $hash -notmatch '^[a-fA-F0-9]{64}$') { continue }
                $group = if ($folder -ne $resultRoot) { 'auxiliary/' + (Split-Path -Leaf $folder) } else { [string]$manifest.branch.safeName }
                if (-not $group) { continue }
                $items += New-ItlArtifactRetentionCandidate -Category 'result' -Root $resultRoot -Path $artifactPath -Group $group -ModifiedAt $manifestFile.LastWriteTimeUtc -Companion $manifestFile.FullName -ExpectedSha256 $hash
            } catch { Write-Warning "ITL artifact retention: invalid manifest retained: $($manifestFile.FullName)." }
        }
    }
    return @($items)
}

function Get-ItlRunArtifactCandidates {
    param([string]$ProjectRoot)
    $specs = @(
        @{ category = 'itl-run'; root = (Join-Path $ProjectRoot '.agent-1c\runs'); marker = 'status.json'; pattern = '*' },
        @{ category = 'vanessa'; root = (Resolve-ProjectPath (Get-VanessaReportsPath)); marker = 'status.json'; pattern = 'run-*' },
        @{ category = 'yaxunit'; root = (Resolve-ProjectPath (Get-YAxUnitReportsPath)); marker = 'junit.xml'; pattern = 'run-*' }
    )
    $items = @()
    foreach ($spec in $specs) {
        $root = [string]$spec.root
        if (-not (Test-ItlArtifactPathInside -Root $ProjectRoot -Path $root) -or
            -not (Test-Path -LiteralPath $root -PathType Container) -or
            -not (Test-ItlArtifactPathWithoutReparse -Root $ProjectRoot -Path $root)) { continue }
        foreach ($folder in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
            if ($folder.Name -notlike $spec.pattern -or -not (Test-Path -LiteralPath (Join-Path $folder.FullName $spec.marker) -PathType Leaf)) { continue }
            if ($spec.category -eq 'itl-run') {
                try {
                    $status = Read-Utf8Text -Path (Join-Path $folder.FullName 'status.json') | ConvertFrom-Json
                    if ([string]$status.status -notin @('succeeded', 'failed', 'cancelled')) { continue }
                } catch { continue }
            } elseif ($folder.Name -notmatch '^run-\d{8}-\d{6}-\d{3}$') { continue }
            if (-not (Test-ItlArtifactPathWithoutReparse -Root $root -Path $folder.FullName -Recursive)) { continue }
            $items += New-ItlArtifactRetentionCandidate -Category ([string]$spec.category) -Root $root -Path $folder.FullName -Group ([string]$spec.category) -ModifiedAt $folder.LastWriteTimeUtc
        }
    }
    return @($items)
}

function Get-ItlArchiveArtifactCandidates {
    param([string]$MainRoot)
    $root = Join-Path $MainRoot '.agent-1c\branch-archives'
    if (-not (Test-Path -LiteralPath $root -PathType Container) -or
        -not (Test-ItlArtifactPathWithoutReparse -Root $MainRoot -Path $root)) { return @() }
    $items = @()
    foreach ($branchFolder in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
        if (-not (Test-ItlArtifactPathWithoutReparse -Root $root -Path $branchFolder.FullName)) { continue }
        foreach ($archive in @(Get-ChildItem -LiteralPath $branchFolder.FullName -Directory -ErrorAction SilentlyContinue)) {
            if ($archive.Name -notmatch '^\d{8}T\d{9}Z-[a-fA-F0-9]{8}$') { continue }
            if (-not (Test-ItlArtifactPathWithoutReparse -Root $root -Path $archive.FullName -Recursive)) { continue }
            $manifestPath = Join-Path $archive.FullName 'manifest.json'
            if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { continue }
            try {
                $manifest = Read-Utf8Text -Path $manifestPath | ConvertFrom-Json
                if ([int]$manifest.schemaVersion -ne 1 -or [string]$manifest.status -cne 'ready' -or
                    [string]$manifest.branch -cne ('itldev/' + $branchFolder.Name) -or
                    [string]$manifest.dt.path -cne 'infobase.dt') { continue }
                $items += New-ItlArtifactRetentionCandidate -Category 'archive' -Root $root -Path $archive.FullName -Group $branchFolder.Name -ModifiedAt $archive.LastWriteTimeUtc
            } catch { continue }
        }
    }
    return @($items)
}

function Get-ItlAuxiliaryArchiveArtifactCandidates {
    param([string]$ProjectRoot)
    $root = Join-Path $ProjectRoot '.agent-1c\auxiliary-archives'
    if (-not (Test-Path -LiteralPath $root -PathType Container) -or
        -not (Test-ItlArtifactPathWithoutReparse -Root $ProjectRoot -Path $root)) { return @() }
    $items = @()
    foreach ($branchFolder in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
        if (-not (Test-ItlArtifactPathWithoutReparse -Root $root -Path $branchFolder.FullName)) { continue }
        foreach ($archive in @(Get-ChildItem -LiteralPath $branchFolder.FullName -Directory -ErrorAction SilentlyContinue)) {
            if (-not (Test-ItlArtifactPathWithoutReparse -Root $root -Path $archive.FullName -Recursive)) { continue }
            $manifestPath = Join-Path $archive.FullName 'itl-archive.json'
            if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { continue }
            try {
                $manifest = Read-Utf8Text -Path $manifestPath | ConvertFrom-Json
                if ([int]$manifest.schemaVersion -ne 1 -or [string]$manifest.kind -cne 'auxiliary-reset' -or
                    [string]$manifest.status -cne 'ready' -or [string]$manifest.branchKey -cne $branchFolder.Name -or
                    [string]$manifest.contour -notmatch '^[a-z0-9][a-z0-9-]{0,47}$' -or
                    $archive.Name -cnotmatch ('^' + [regex]::Escape([string]$manifest.contour) + '-\d{8}-\d{6}-\d{3}$')) { continue }
                $items += New-ItlArtifactRetentionCandidate -Category 'auxiliary-archive' -Root $root -Path $archive.FullName -Group "$($branchFolder.Name)/$($manifest.contour)" -ModifiedAt $archive.LastWriteTimeUtc
            } catch { continue }
        }
    }
    return @($items)
}

function Get-ItlArtifactCandidateSize {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path -PathType Leaf) { return [int64](Get-Item -LiteralPath $Path).Length }
    $total = [int64]0
    foreach ($file in @(Get-ChildItem -LiteralPath $Path -File -Recurse -Force -ErrorAction Stop)) { $total += [int64]$file.Length }
    return $total
}

function Get-ItlArtifactCleanupPlan {
    param([string]$ProjectRoot = $script:ProjectRoot, [string]$MainRoot = (Get-MainWorktreePath))
    $policy = Get-ItlArtifactRetentionPolicy
    $protected = Get-ItlArtifactProtectedPaths -ProjectRoot $ProjectRoot
    $candidates = @()
    $candidates += @(Get-ItlResultArtifactCandidates -ProjectRoot $ProjectRoot)
    $candidates += @(Get-ItlRunArtifactCandidates -ProjectRoot $ProjectRoot)
    $candidates += @(Get-ItlAuxiliaryArchiveArtifactCandidates -ProjectRoot $ProjectRoot)
    if ([string]::Equals([IO.Path]::GetFullPath($ProjectRoot), [IO.Path]::GetFullPath($MainRoot), [StringComparison]::OrdinalIgnoreCase)) {
        $candidates += @(Get-ItlArchiveArtifactCandidates -MainRoot $MainRoot)
    }
    $now = (Get-Date).ToUniversalTime()
    $entries = @()
    foreach ($group in @($candidates | Group-Object { "$($_.category)|$($_.group)" })) {
        $ordered = @($group.Group | Sort-Object modifiedAt, path -Descending)
        $keep = if ($ordered[0].category -eq 'result') { $policy.resultKeepCount } elseif ($ordered[0].category -in @('archive', 'auxiliary-archive')) { $policy.archiveKeepCount } else { $policy.runKeepCount }
        for ($index = 0; $index -lt $ordered.Count; $index++) {
            $item = $ordered[$index]
            $expired = ($item.category -in @('itl-run', 'vanessa', 'yaxunit') -and $item.modifiedAt -lt $now.AddDays(-$policy.runtimeDays))
            $protectedPath = Test-ItlArtifactProtected -Path $item.path -ProtectedPaths $protected
            $delete = ($index -ge $keep -and (-not ($item.category -in @('itl-run', 'vanessa', 'yaxunit')) -or $expired) -and -not $protectedPath)
            $entries += [pscustomobject]@{ category = $item.category; group = $item.group; path = $item.path; root = $item.root; companion = $item.companion; expectedSha256 = $item.expectedSha256; modifiedAt = $item.modifiedAt; sizeBytes = (Get-ItlArtifactCandidateSize -Path $item.path); delete = $delete; reason = $(if ($protectedPath) { 'referenced' } elseif ($index -lt $keep) { 'newest' } elseif (-not $expired -and $item.category -in @('itl-run', 'vanessa', 'yaxunit')) { 'within-age' } else { 'expired' }) }
        }
    }
    return [pscustomobject]@{ policy = $policy; entries = @($entries) }
}

function Show-ItlArtifactFootprint {
    try {
        $plan = Get-ItlArtifactCleanupPlan
        $total = [int64]0
        $eligible = [int64]0
        foreach ($entry in $plan.entries) {
            $total += [int64]$entry.sizeBytes
            if ($entry.delete) { $eligible += [int64]$entry.sizeBytes }
        }
        Write-Host "ITL owned artifacts: $($plan.entries.Count) verified candidate(s), $total bytes; eligible for cleanup: $eligible bytes. Auto cleanup: $($plan.policy.enabled)."
    } catch { Write-Warning "ITL artifact footprint unavailable: $($_.Exception.Message)" }
}

function Invoke-ItlArtifactCleanup {
    param([switch]$DryRun, [switch]$Automatic)
    $plan = Get-ItlArtifactCleanupPlan
    if ($Automatic -and -not $plan.policy.enabled) { return }
    $removed = [int64]0
    $removedPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $failed = @()
    foreach ($entry in @($plan.entries | Where-Object delete)) {
        if ($DryRun) { continue }
        try {
            if (-not (Test-ItlArtifactPathWithoutReparse -Root $entry.root -Path $entry.path -Recursive)) { throw 'path contains a reparse point or is outside the managed root' }
            if ($entry.companion -and -not (Test-ItlArtifactPathWithoutReparse -Root $entry.root -Path $entry.companion)) { throw 'manifest path is unsafe' }
            if ($entry.expectedSha256 -and (Get-FileHash -LiteralPath $entry.path -Algorithm SHA256).Hash -cne $entry.expectedSha256) { throw 'artifact hash differs from its manifest' }
            Remove-Item -LiteralPath $entry.path -Recurse -Force -ErrorAction Stop
            if ($entry.companion) { Remove-Item -LiteralPath $entry.companion -Force -ErrorAction Stop }
            $removed += $entry.sizeBytes
            [void]$removedPaths.Add([string]$entry.path)
        } catch { $failed += "$($entry.path): $($_.Exception.Message)" }
    }
    $eligible = @($plan.entries | Where-Object delete)
    $bytes = [int64]0
    foreach ($entry in $eligible) { $bytes += $entry.sizeBytes }
    if (-not $Automatic) {
        Write-Host "ITL artifact cleanup: candidates=$($plan.entries.Count), eligible=$($eligible.Count), bytes=$bytes, removedBytes=$removed, dryRun=$([bool]$DryRun)."
        foreach ($entry in $eligible) { Write-Host "  $(if ($DryRun) { 'would remove' } elseif ($removedPaths.Contains([string]$entry.path)) { 'removed' } else { 'left' }): $($entry.path)" }
    }
    foreach ($issue in $failed) { Write-Warning "ITL artifact cleanup left: $issue" }
    if ($failed.Count -gt 0 -and -not $Automatic) { throw "ITL_ARTIFACT_CLEANUP_INCOMPLETE: $($failed.Count) artifact(s) left; see warnings above." }
    return [pscustomobject]@{ candidates = $plan.entries.Count; eligible = $eligible.Count; removedBytes = $removed; failed = @($failed) }
}
