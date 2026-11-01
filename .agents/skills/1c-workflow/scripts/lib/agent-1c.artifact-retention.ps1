. (Join-Path $PSScriptRoot 'agent-1c.diagnostic-retention.ps1')

function Get-ItlArtifactRetentionPolicy {
    $enabledText = ([string](Get-EnvValue -Name 'ITL_ARTIFACT_CLEANUP_ENABLED' -Default 'true')).Trim().ToLowerInvariant()
    if ($enabledText -notin @('true', 'false')) { throw "ITL_ARTIFACT_CLEANUP_ENABLED must be true or false: '$enabledText'." }
    $defaults = [ordered]@{
        ITL_RESULT_ARTIFACT_KEEP_COUNT = 3
        ITL_RECOVERY_ARCHIVE_KEEP_COUNT = 2
        ITL_RUN_ARTIFACT_KEEP_COUNT = 3
        ITL_RUNTIME_ARTIFACT_RETENTION_DAYS = 7
        ITL_DIAGNOSTIC_ARTIFACT_RETENTION_DAYS = 7
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
        diagnosticDays = $values.ITL_DIAGNOSTIC_ARTIFACT_RETENTION_DAYS
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
    foreach ($name in @('ResolvedRunStatusPath', 'ResolvedRunLogPath', 'RunResultPath', 'RunResultManifestPath')) {
        $variable = Get-Variable -Name $name -Scope Script -ErrorAction SilentlyContinue
        $candidate = if ($null -ne $variable) { $variable.Value } else { $null }
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
                $components = Get-StateValue -State $state -Name 'lastVerificationComponentEvidence' -Default $null
                if ($null -ne $components) {
                    foreach ($property in $components.PSObject.Properties) {
                        foreach ($artifact in @($property.Value.artifacts)) {
                            $full = [IO.Path]::GetFullPath((Join-Path $ProjectRoot ([string]$artifact.path)))
                            if (-not (Test-ItlArtifactPathInside -Root $ProjectRoot -Path $full)) { throw 'component evidence path escaped the project' }
                            [void]$paths.Add($full)
                        }
                    }
                }
                # A reset journaled by an older workflow may still name its archive.
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
    $oneOffRoot = Join-Path $ProjectRoot '.agent-1c\verification-selection\one-off'
    if (Test-Path -LiteralPath $oneOffRoot -PathType Container) {
        foreach ($file in @(Get-ChildItem -LiteralPath $oneOffRoot -File -Filter '*.json' -ErrorAction Stop)) {
            try {
                $receipt = Read-Utf8Text -Path $file.FullName | ConvertFrom-Json -ErrorAction Stop
                if ([string]$receipt.status -ne 'passed') { continue }
                foreach ($relative in @([string]$receipt.evidencePath) + @($receipt.artifacts | ForEach-Object { [string]$_.path })) {
                    if (-not $relative -or [IO.Path]::IsPathRooted($relative) -or $relative -match '(^|[\\/])\.\.([\\/]|$)') {
                        throw "unsafe one-off evidence path '$relative'"
                    }
                    $full = [IO.Path]::GetFullPath((Join-Path $ProjectRoot $relative))
                    if (-not (Test-ItlArtifactPathInside -Root $ProjectRoot -Path $full)) {
                        throw "one-off evidence path escaped the project: '$relative'"
                    }
                    [void]$paths.Add($full)
                }
            } catch { throw "ITL_ARTIFACT_ONE_OFF_RECEIPT_UNREADABLE: $($file.FullName): $($_.Exception.Message)" }
        }
    }
    $selectionPath = Join-Path $ProjectRoot '.agent-1c/verification-selection/proof.json'
    if (Test-Path -LiteralPath $selectionPath -PathType Leaf) {
        try {
            $proof = Read-Utf8Text -Path $selectionPath | ConvertFrom-Json -ErrorAction Stop
            $receipts = if ($null -ne $proof.PSObject.Properties['suiteEvidence']) { @($proof.suiteEvidence) } else { @() }
            foreach ($receipt in $receipts) {
                foreach ($artifact in @($receipt.artifacts)) {
                    $full = [IO.Path]::GetFullPath((Join-Path $ProjectRoot ([string]$artifact.path)))
                    if (-not (Test-ItlArtifactPathInside -Root $ProjectRoot -Path $full)) { throw 'retained evidence path escaped the project' }
                    [void]$paths.Add($full)
                }
            }
        } catch { throw "ITL_ARTIFACT_RETAINED_RECEIPT_UNREADABLE: $selectionPath`: $($_.Exception.Message)" }
    }
    [void]$paths.Add((Join-Path $ProjectRoot '.agent-1c/verification-selection/changes'))
    $changePath=Join-Path $ProjectRoot '.agent-1c/verification-selection/current-change.json'
    if (Test-Path -LiteralPath $changePath -PathType Leaf) {
        try {
            $change=Read-Utf8Text -Path $changePath | ConvertFrom-Json -ErrorAction Stop
            [void]$paths.Add($changePath)
            foreach ($reference in @($change.planArtifact)+@($change.requirements)) {
                $full=[IO.Path]::GetFullPath((Join-Path $ProjectRoot ([string]$reference.path)))
                if (-not (Test-ItlArtifactPathInside -Root $ProjectRoot -Path $full)) { throw 'change evidence escaped the project' }
                [void]$paths.Add($full)
            }
        } catch { throw "ITL_ARTIFACT_CHANGE_RECEIPT_UNREADABLE: $changePath`: $($_.Exception.Message)" }
    }
    return $paths
}

function New-ItlArtifactProtectionIndex {
    # Protected paths plus all their ancestors: one lookup per path level
    # replaces a scan of every protected path for every candidate.
    param([object]$ProtectedPaths)
    $exact = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $ancestors = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($protected in @($ProtectedPaths)) {
        if ([string]::IsNullOrWhiteSpace([string]$protected)) { continue }
        $saved = [IO.Path]::GetFullPath([string]$protected).TrimEnd('\', '/')
        if (-not $exact.Add($saved)) { continue }
        $parent = [IO.Path]::GetDirectoryName($saved)
        while ($parent -and $ancestors.Add($parent.TrimEnd('\', '/'))) { $parent = [IO.Path]::GetDirectoryName($parent) }
    }
    return [pscustomobject]@{ itlProtectionIndex = $true; exact = $exact; ancestors = $ancestors }
}

function Test-ItlArtifactProtected {
    # A path is protected when it is, lies inside, or contains protected
    # evidence. Loops pass an index built once by New-ItlArtifactProtectionIndex.
    param([string]$Path, [object]$ProtectedPaths)
    $index = if ($null -ne $ProtectedPaths -and $null -ne $ProtectedPaths.PSObject.Properties['itlProtectionIndex']) { $ProtectedPaths } else { New-ItlArtifactProtectionIndex -ProtectedPaths $ProtectedPaths }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    if ($index.exact.Contains($full) -or $index.ancestors.Contains($full)) { return $true }
    $parent = [IO.Path]::GetDirectoryName($full)
    while ($parent) {
        if ($index.exact.Contains($parent.TrimEnd('\', '/'))) { return $true }
        $parent = [IO.Path]::GetDirectoryName($parent)
    }
    return $false
}

function New-ItlArtifactRetentionCandidate {
    param([string]$Category, [string]$Root, [string]$Path, [string]$Group, [datetime]$ModifiedAt,
        [string]$Companion = '', [string]$ExpectedSha256 = '', [long]$SizeBytes = -1)
    return [pscustomobject]@{
        category = $Category; root = $Root; path = $Path; group = $Group
        modifiedAt = $ModifiedAt; companion = $Companion; expectedSha256 = $ExpectedSha256; sizeBytes = $SizeBytes
    }
}

function Measure-ItlArtifactTree {
    # One walk that never enters a link: newest write anywhere below, total size,
    # and whether a reparse point was seen (such trees are never removed).
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    $linked = [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
    if (-not $item.PSIsContainer -or $linked) {
        return [pscustomobject]@{ newestUtc = $item.LastWriteTimeUtc; bytes = $(if ($item.PSIsContainer) { [int64]0 } else { [int64]$item.Length }); linked = $linked }
    }
    $newest = $item.LastWriteTimeUtc
    $bytes = [int64]0
    $pending = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
    $pending.Push($item)
    while ($pending.Count -gt 0) {
        foreach ($entry in $pending.Pop().GetFileSystemInfos()) {
            if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { $linked = $true; continue }
            if ($entry.LastWriteTimeUtc -gt $newest) { $newest = $entry.LastWriteTimeUtc }
            if ($entry -is [IO.DirectoryInfo]) { $pending.Push($entry) } else { $bytes += $entry.Length }
        }
    }
    return [pscustomobject]@{ newestUtc = $newest; bytes = $bytes; linked = $linked }
}

function Get-ItlOwnedBuildFolderNames {
    # Helper-owned children of build/ and build/test-results; everything else
    # there is an agent task folder.
    # diagnostic-runtime belongs to the remote measurement engine and its receipts.
    $build = @('result', 'test-results', 'agent-artifacts', 'event-log', 'data-mcp-tools-loader', 'tooling-probe', 'diagnostic-runtime')
    $resultLeaf = Split-Path -Leaf ([string](Get-ConfigValue -Path 'artifactsPath' -Default 'build/result')).TrimEnd('\', '/')
    if ($resultLeaf) { $build += $resultLeaf }
    return [pscustomobject]@{ build = @($build | Select-Object -Unique); testResults = @('vanessa', 'yaxunit', 'tooling-probe', 'release-e2e') }
}

function Test-ItlArtifactPathTracked {
    # build/ itself is not ignored; a folder with tracked files belongs to the project.
    param([string]$ProjectRoot, [string]$Path)
    $relative = [IO.Path]::GetFullPath($Path).Substring([IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\', '/').Length + 1)
    try { return (@(Get-GitPathListAt -Root $ProjectRoot -Arguments @('ls-files', '-z', '--', $relative)).Count -gt 0) }
    catch { return $true }
}

function Test-ItlRunStatusAbandoned {
    # A running record whose deadline passed and whose process is gone can
    # never complete; a reused live PID keeps it, which only delays cleanup.
    param([object]$Status)
    if ([string]$Status.status -ne 'running') { return $false }
    $deadline = $Status.operationDeadlineUtc
    if ($deadline -isnot [datetime]) {
        $parsed = [datetime]::MinValue
        if (-not [datetime]::TryParse([string]$deadline, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) { return $false }
        $deadline = $parsed
    }
    if ($deadline.ToUniversalTime() -gt [datetime]::UtcNow) { return $false }
    $processId = 0
    if (-not [int]::TryParse([string]$Status.pid, [ref]$processId) -or $processId -le 0) { return $false }
    return ($null -eq (Get-Process -Id $processId -ErrorAction SilentlyContinue))
}

function Get-ItlAgentTaskArtifactCandidates {
    param([string]$ProjectRoot)
    $owned = Get-ItlOwnedBuildFolderNames
    $build = Join-Path $ProjectRoot 'build'
    $specs = @(
        @{ group = 'build'; root = $build; exclude = $owned.build },
        @{ group = 'test-results'; root = (Join-Path $build 'test-results'); exclude = $owned.testResults },
        @{ group = 'agent-artifacts'; root = (Join-Path $build 'agent-artifacts'); exclude = @() },
        @{ group = 'runs'; root = (Join-Path $ProjectRoot '.agent-1c\runs'); exclude = @() },
        @{ group = 'tmp'; root = (Join-Path $ProjectRoot '.agent-1c\tmp'); exclude = @('tooling-probe') }
    )
    $items = @()
    foreach ($spec in $specs) {
        $root = [string]$spec.root
        if (-not (Test-Path -LiteralPath $root -PathType Container) -or
            -not (Test-ItlArtifactPathWithoutReparse -Root $ProjectRoot -Path $root)) { continue }
        foreach ($folder in @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue)) {
            if ($spec.exclude -contains $folder.Name) { continue }
            # Helper runs carry status.json and keep their own policy.
            if ($spec.group -eq 'runs' -and ((Test-Path -LiteralPath (Join-Path $folder.FullName 'status.json') -PathType Leaf) -or
                $folder.Name -match '^(auto-update|ai-rules-migration-)')) { continue }
            if ($spec.group -eq 'build' -and (Test-ItlArtifactPathTracked -ProjectRoot $ProjectRoot -Path $folder.FullName)) { continue }
            try { $measure = Measure-ItlArtifactTree -Path $folder.FullName } catch { continue }
            if ($measure.linked) { continue }
            $items += New-ItlArtifactRetentionCandidate -Category 'agent-task' -Root $root -Path $folder.FullName -Group ([string]$spec.group) -ModifiedAt $measure.newestUtc -SizeBytes $measure.bytes
        }
    }
    return @($items)
}

function Get-ItlBranchDumpArtifactCandidates {
    param([string]$ProjectRoot)
    $root = Join-Path $ProjectRoot '.agent-1c\branch-dumps'
    if (-not (Test-Path -LiteralPath $root -PathType Container) -or
        -not (Test-ItlArtifactPathWithoutReparse -Root $ProjectRoot -Path $root)) { return @() }
    $items = @()
    foreach ($folder in @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue)) {
        if ($folder.Name -notmatch '^\d{8}-\d{6}-\d{3}-[0-9a-f]{32}$') { continue }
        try { $measure = Measure-ItlArtifactTree -Path $folder.FullName } catch { continue }
        if ($measure.linked) { continue }
        $items += New-ItlArtifactRetentionCandidate -Category 'branch-dump' -Root $root -Path $folder.FullName -Group 'branch-dump' -ModifiedAt $measure.newestUtc -SizeBytes $measure.bytes
    }
    return @($items)
}

function Invoke-ItlBranchResetLeftoverCleanup {
    # Reset recreates the branch: the previous task's ignored runtime goes. Only
    # items untouched since the reset started are removed, so reset's own files,
    # the current run and live runs stay; referenced workflow evidence stays too.
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$MainRoot,
        [Parameter(Mandatory)][string]$SafeBranchName, [Parameter(Mandatory)][datetime]$StartedAt)
    $before = $StartedAt.ToUniversalTime()
    $protected = New-ItlArtifactProtectionIndex -ProtectedPaths (Get-ItlArtifactProtectedPaths -ProjectRoot $ProjectRoot)
    $owned = Get-ItlOwnedBuildFolderNames
    $build = Join-Path $ProjectRoot 'build'
    $agentRoot = Join-Path $ProjectRoot '.agent-1c'
    $targets = New-Object System.Collections.Generic.List[object]
    $children = {
        param([string]$Root, [string[]]$Exclude, [switch]$SnapshotFiles)
        if (Test-Path -LiteralPath $Root -PathType Container) {
            foreach ($child in @(Get-ChildItem -LiteralPath $Root -Force -ErrorAction SilentlyContinue)) {
                # Snapshot subtrees (workflow update, incidents) keep their owners.
                if ($SnapshotFiles -and ($child.PSIsContainer -or $child.Name -notmatch '\.dt($|\.)')) { continue }
                if ($Exclude -notcontains $child.Name -and $child.Name -notmatch '^ai-rules-migration-') { $targets.Add([pscustomobject]@{ root = $Root; path = $child.FullName }) }
            }
        }
    }
    & $children $build ($owned.build)
    & $children (Join-Path $build 'test-results') @('tooling-probe', 'release-e2e')
    foreach ($name in @('agent-artifacts', 'event-log')) { & $children (Join-Path $build $name) @() }
    & $children (Join-Path $agentRoot 'runs') @('auto-update')
    & $children (Join-Path $agentRoot 'tmp') @('tooling-probe')
    foreach ($name in @('branch-dumps', 'fork-history')) { & $children (Join-Path $agentRoot $name) @() }
    & $children (Join-Path $agentRoot 'snapshots') @() -SnapshotFiles
    & $children (Join-Path $ProjectRoot 'logs') @()
    $archive = Join-Path (Join-Path $MainRoot '.agent-1c\branch-archives') $SafeBranchName
    if (Test-Path -LiteralPath $archive -PathType Container) { $targets.Add([pscustomobject]@{ root = (Split-Path -Parent $archive); path = $archive }) }
    $removedCount = 0
    $removedBytes = [int64]0
    $leftovers = New-Object System.Collections.Generic.List[string]
    foreach ($target in $targets) {
        $path = [string]$target.path
        try {
            $statusPath = Join-Path $path 'status.json'
            if ((Test-Path -LiteralPath $statusPath -PathType Leaf) -and
                [string]::Equals((Split-Path -Parent $path), (Join-Path $agentRoot 'runs'), [StringComparison]::OrdinalIgnoreCase)) {
                $status = Read-Utf8Text -Path $statusPath | ConvertFrom-Json
                if ([string]$status.status -eq 'running' -and -not (Test-ItlRunStatusAbandoned -Status $status)) { continue }
            }
            $measure = Measure-ItlArtifactTree -Path $path
            if ($measure.newestUtc -ge $before) { continue }
            if ([string]::Equals([string]$target.root, $build, [StringComparison]::OrdinalIgnoreCase) -and
                (Test-ItlArtifactPathTracked -ProjectRoot $ProjectRoot -Path $path)) { continue }
            if (Test-ItlArtifactProtected -Path $path -ProtectedPaths $protected) { $leftovers.Add("$path (referenced by workflow evidence)"); continue }
            if ($measure.linked -or -not (Test-ItlArtifactPathWithoutReparse -Root ([string]$target.root) -Path $path)) { $leftovers.Add("$path (contains a link)"); continue }
            Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
            $removedCount++
            $removedBytes += $measure.bytes
        } catch { $leftovers.Add("$path ($($_.Exception.Message))") }
    }
    # Bounded report: the full list stays recoverable by repeating /itl-clean.
    return [ordered]@{ removedCount = $removedCount; removedBytes = $removedBytes; leftoverCount = $leftovers.Count; leftovers = @($leftovers | Select-Object -First 20) }
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
        @{ category = 'yaxunit'; root = (Resolve-ProjectPath (Get-YAxUnitReportsPath)); marker = 'junit.xml'; pattern = 'run-*' },
        @{ category = 'event-log'; root = (Resolve-ProjectPath 'build/event-log'); marker = 'EventLogExportParams.json'; pattern = 'export-*' }
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
                    if ([string]$status.status -notin @('succeeded', 'failed', 'cancelled') -and -not (Test-ItlRunStatusAbandoned -Status $status)) { continue }
                } catch { continue }
            } elseif ($spec.category -eq 'event-log') {
                if ($folder.Name -notmatch '^export-\d{8}-\d{6}-\d{3}$') { continue }
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

function Get-ItlWorkflowIncidentArchiveCandidates {
    param([string]$ProjectRoot)
    $root = Join-Path $ProjectRoot '.agent-1c/snapshots/workflow-incidents'
    if (-not (Test-Path -LiteralPath $root -PathType Container) -or
        -not (Test-ItlArtifactPathWithoutReparse -Root $ProjectRoot -Path $root)) { return @() }
    # Unreadable active state preserves every local incident until reconciled.
    $active = $null
    $activePath = Join-Path $root 'active.json'
    if (Test-Path -LiteralPath $activePath) {
        try {
            $active = Read-Utf8Text $activePath | ConvertFrom-Json
            if ($active.schemaVersion -ne 1 -or $active.id -notmatch '^[a-f0-9]{32}$' -or $active.phase -notin @('captured','active','retiring','retired')) { return @() }
        } catch { return @() }
    }
    foreach ($folder in @(Get-ChildItem -LiteralPath $root -Directory)) {
        if ($folder.Name -notmatch '^[a-f0-9]{32}$' -or
            -not (Test-ItlArtifactPathWithoutReparse -Root $root -Path $folder.FullName -Recursive)) { continue }
        if ($null -ne $active -and $active.id -eq $folder.Name) { continue }
        try {
            $receipt = Read-Utf8Text (Join-Path $folder.FullName 'patch.json') | ConvertFrom-Json
            if ($receipt.schemaVersion -ne 1 -or $receipt.id -cne $folder.Name -or $receipt.phase -ne 'retired') { continue }
            New-ItlArtifactRetentionCandidate -Category 'archive' -Root $root -Path $folder.FullName -Group 'workflow-incidents' -ModifiedAt $folder.LastWriteTimeUtc
        } catch { continue }
    }
}

function Get-ItlArtifactCleanupPlan {
    param([string]$ProjectRoot = $script:ProjectRoot, [string]$MainRoot = (Get-MainWorktreePath))
    $policy = Get-ItlArtifactRetentionPolicy
    $protected = Get-ItlArtifactProtectedPaths -ProjectRoot $ProjectRoot
    $candidates = @()
    $candidates += @(Get-ItlResultArtifactCandidates -ProjectRoot $ProjectRoot)
    $candidates += @(Get-ItlRunArtifactCandidates -ProjectRoot $ProjectRoot)
    $candidates += @(Get-ItlAuxiliaryArchiveArtifactCandidates -ProjectRoot $ProjectRoot)
    $candidates += @(Get-ItlWorkflowIncidentArchiveCandidates -ProjectRoot $ProjectRoot)
    $candidates += @(Get-ItlAgentTaskArtifactCandidates -ProjectRoot $ProjectRoot)
    $candidates += @(Get-ItlBranchDumpArtifactCandidates -ProjectRoot $ProjectRoot)
    if ([string]::Equals([IO.Path]::GetFullPath($ProjectRoot), [IO.Path]::GetFullPath($MainRoot), [StringComparison]::OrdinalIgnoreCase)) {
        $candidates += @(Get-ItlArchiveArtifactCandidates -MainRoot $MainRoot)
    }
    # Agent task folders also honor retained dependencies of completion receipts;
    # an unreadable receipt store keeps every such folder.
    $retainedDependencies = $null
    try { $retainedDependencies = New-ItlArtifactProtectionIndex -ProtectedPaths @(Get-ItlDiagnosticRetainedPaths -ProjectRoot $ProjectRoot) } catch { $retainedDependencies = $null }
    $protectedIndex = New-ItlArtifactProtectionIndex -ProtectedPaths $protected
    $now = (Get-Date).ToUniversalTime()
    $ageLimited = @('itl-run', 'vanessa', 'yaxunit', 'event-log', 'agent-task', 'branch-dump')
    $entries = @()
    foreach ($group in @($candidates | Group-Object { "$($_.category)|$($_.group)" })) {
        $ordered = @($group.Group | Sort-Object modifiedAt, path -Descending)
        $category = $ordered[0].category
        $keep = if ($category -eq 'result') { $policy.resultKeepCount } elseif ($category -in @('archive', 'auxiliary-archive')) { $policy.archiveKeepCount } elseif ($category -eq 'branch-dump') { 0 } else { $policy.runKeepCount }
        # A dump transaction finishes within one operation; an hour without writes means it was interrupted.
        $cutoff = if ($category -eq 'branch-dump') { $now.AddHours(-1) } else { $now.AddDays(-$policy.runtimeDays) }
        for ($index = 0; $index -lt $ordered.Count; $index++) {
            $item = $ordered[$index]
            $expired = ($category -in $ageLimited -and $item.modifiedAt -lt $cutoff)
            $protectedPath = (Test-ItlArtifactProtected -Path $item.path -ProtectedPaths $protectedIndex) -or
                ($category -eq 'agent-task' -and ($null -eq $retainedDependencies -or (Test-ItlArtifactProtected -Path $item.path -ProtectedPaths $retainedDependencies)))
            $delete = ($index -ge $keep -and (-not ($category -in $ageLimited) -or $expired) -and -not $protectedPath)
            $size = if ($item.sizeBytes -ge 0) { [int64]$item.sizeBytes } else { Get-ItlArtifactCandidateSize -Path $item.path }
            $entries += [pscustomobject]@{ category = $category; group = $item.group; path = $item.path; root = $item.root; companion = $item.companion; expectedSha256 = $item.expectedSha256; modifiedAt = $item.modifiedAt; sizeBytes = $size; delete = $delete; reason = $(if ($protectedPath) { 'referenced' } elseif ($index -lt $keep) { 'newest' } elseif (-not $expired -and $category -in $ageLimited) { 'within-age' } else { 'expired' }) }
        }
    }
    $entries += @(Get-ItlDiagnosticArtifactPlan -ProjectRoot $ProjectRoot -MinimumAgeDays $policy.diagnosticDays -ProtectedPaths $protected)
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
    # Automatic cleanup is optional after the action: it stops removing at its
    # deadline and leaves the rest to /itl-clean instead of delaying the result.
    # The heartbeat keeps the finished action from looking stalled to the runner.
    param([switch]$DryRun, [switch]$Automatic, [object]$DeadlineUtc = $null)
    if ($Automatic -and -not (Get-ItlArtifactRetentionPolicy).enabled) { return }
    if ($Automatic -and $null -eq $DeadlineUtc) { $DeadlineUtc = [datetime]::UtcNow.AddSeconds(30) }
    $plan = if ($Automatic) { Invoke-WithRunStatusHeartbeat { Get-ItlArtifactCleanupPlan } } else { Get-ItlArtifactCleanupPlan }
    $removed = [int64]0
    $removedPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $failed = @()
    $deferred = 0
    $diagnosticCache = @{}
    foreach ($entry in @($plan.entries | Where-Object delete)) {
        if ($DryRun) { continue }
        if ($null -ne $DeadlineUtc -and [datetime]::UtcNow -ge $DeadlineUtc.ToUniversalTime()) { $deferred++; continue }
        try {
            if ($entry.category -eq 'diagnostic') {
                Remove-ItlDiagnosticArtifact -Entry $entry -Cache $diagnosticCache
                $removed += $entry.sizeBytes
                [void]$removedPaths.Add([string]$entry.path)
                continue
            }
            if (-not (Test-ItlArtifactPathWithoutReparse -Root $entry.root -Path $entry.path -Recursive)) { throw 'path contains a reparse point or is outside the managed root' }
            if ($entry.companion -and -not (Test-ItlArtifactPathWithoutReparse -Root $entry.root -Path $entry.companion)) { throw 'manifest path is unsafe' }
            if ($entry.expectedSha256 -and (Get-FileHash -LiteralPath $entry.path -Algorithm SHA256).Hash -ine $entry.expectedSha256) { throw 'artifact hash differs from its manifest' }
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
    if ($deferred -gt 0) { Write-Warning "ITL artifact cleanup deferred $deferred eligible artifact(s) at its time budget; /itl-clean removes them." }
    if ($failed.Count -gt 0 -and -not $Automatic) { throw "ITL_ARTIFACT_CLEANUP_INCOMPLETE: $($failed.Count) artifact(s) left; see warnings above." }
    return [pscustomobject]@{ candidates = $plan.entries.Count; eligible = $eligible.Count; removedBytes = $removed; failed = @($failed); deferred = $deferred }
}
