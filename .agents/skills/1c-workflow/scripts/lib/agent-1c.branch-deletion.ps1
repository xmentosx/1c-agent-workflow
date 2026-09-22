function Get-ItlBranchDeletionJournalPath {
    param([string]$SafeName)
    return (Join-Path (Get-MainWorktreePath) ".agent-1c\branch-deletions\$SafeName.json")
}

function New-ItlBranchDeletionJournal {
    param([string]$Name)
    Assert-MasterWorktreeContext -Operation 'delete-dev-branch'
    if (-not $Name -or $Name -ne (ConvertTo-SafeName $Name)) { throw "DELETE_BRANCH_NAME_INVALID: pass the exact safe branch name." }
    $branch = "itldev/$Name"
    $state = Read-DevBranchState -Name $Name
    if ([string]$state.devBranch -cne $branch -or [string]$state.safeDevBranchName -cne $Name) { throw "DELETE_BRANCH_IDENTITY_MISMATCH: $branch" }
    $mainRoot = [IO.Path]::GetFullPath((Get-MainWorktreePath))
    if (-not [string]::Equals($mainRoot, [IO.Path]::GetFullPath($script:ProjectRoot), [StringComparison]::OrdinalIgnoreCase)) { throw 'DELETE_BRANCH_MAIN_ROOT_MISMATCH' }
    if ($state.mainWorktreePath -and -not [string]::Equals($mainRoot, [IO.Path]::GetFullPath([string]$state.mainWorktreePath), [StringComparison]::OrdinalIgnoreCase)) { throw 'DELETE_BRANCH_STATE_MAIN_MISMATCH' }
    $worktree = Find-GitWorktreeByBranch -Branch $branch
    $worktreePath = [string](Get-StateValue -State $state -Name 'worktreePath' -Default '')
    if (Test-DevBranchStateUsesWorktree -State $state) {
        if (-not $worktree -or -not $worktreePath -or -not [string]::Equals([IO.Path]::GetFullPath($worktree.path), [IO.Path]::GetFullPath($worktreePath), [StringComparison]::OrdinalIgnoreCase)) { throw 'DELETE_BRANCH_WORKTREE_IDENTITY_MISMATCH' }
        if ([string]::Equals($mainRoot, [IO.Path]::GetFullPath($worktreePath), [StringComparison]::OrdinalIgnoreCase) -or
            (Test-ItlArtifactPathInside -Root $worktreePath -Path $mainRoot)) { throw 'DELETE_BRANCH_MAIN_WORKTREE_REFUSED' }
        if (Test-Agent1cLifecycleLockHeld -WorktreePath $worktreePath) { throw 'DELETE_BRANCH_ACTIVE_WORKTREE_OPERATION' }
        if (-not (Test-ItlArtifactPathWithoutReparse -Root (Split-Path -Parent $worktreePath) -Path $worktreePath -Recursive)) { throw 'DELETE_BRANCH_WORKTREE_UNSAFE_PATH' }
    } elseif ($worktree) { throw 'DELETE_BRANCH_UNEXPECTED_WORKTREE' }
    $baseKind = [string](Get-StateValue -State $state -Name 'infoBaseKind' -Default '')
    $basePath = [string](Get-StateValue -State $state -Name 'devBranchInfoBasePath' -Default '')
    if ($baseKind -eq 'file' -and $basePath) {
        $basePath = [IO.Path]::GetFullPath($basePath)
        $sourcePath = [string](Get-SourceInfoBasePath)
        if (-not [IO.Path]::IsPathRooted($sourcePath)) { $sourcePath = Join-Path $mainRoot $sourcePath }
        $sourcePath = [IO.Path]::GetFullPath($sourcePath)
        if ([string]::Equals($basePath, $sourcePath, [StringComparison]::OrdinalIgnoreCase) -or
            (Test-ItlArtifactPathInside -Root $basePath -Path $sourcePath) -or
            (Test-ItlArtifactPathInside -Root $sourcePath -Path $basePath)) { throw 'DELETE_BRANCH_SOURCE_INFOBASE_REFUSED' }
    }
    $publicationDir = [string](Get-StateValue -State $state -Name 'publicationDir' -Default '')
    $publicationMode = [string](Get-StateValue -State $state -Name 'publicationMode' -Default '')
    $publicationRoot = ''
    if ($publicationMode -eq 'auto' -and $publicationDir) {
        $publicationRoot = [string](Get-EffectiveApacheSettings).publicationRoot
        $expectedName = $Name -replace '[^a-zA-Z0-9_]', '_'
        if (-not $publicationRoot -or -not [string]::Equals([IO.Path]::GetFullPath($publicationDir), [IO.Path]::GetFullPath((Join-Path $publicationRoot $expectedName)), [StringComparison]::OrdinalIgnoreCase)) { throw 'DELETE_BRANCH_PUBLICATION_IDENTITY_MISMATCH' }
    }
    $journal = [ordered]@{
        schemaVersion = 1; branch = $branch; safeName = $Name; mainRoot = $mainRoot
        statePath = [string]$state.statePath; stateRoot = [string]$state.stateProjectRoot; worktreePath = $worktreePath
        infoBaseKind = $baseKind; infoBasePath = $basePath
        launcherRegistered = [bool](Get-StateValue -State $state -Name 'launcherRegistered' -Default $false)
        launcherId = [string](Get-StateValue -State $state -Name 'launcherInfoBaseId' -Default '')
        launcherName = [string](Get-StateValue -State $state -Name 'launcherInfoBaseName' -Default '')
        launcherFolder = [string](Get-StateValue -State $state -Name 'launcherFolder' -Default '')
        launcherConnect = $(if ($baseKind -in @('file', 'server') -and $basePath) { New-LauncherConnectString -InfoBaseKind $baseKind -InfoBasePath $basePath } else { '' })
        publicationMode = $publicationMode; publicationDir = $publicationDir; publicationRoot = $publicationRoot
        archivePath = (Join-Path $mainRoot ".agent-1c\branch-archives\$Name")
        auxiliaryArchivePath = (Join-Path $mainRoot ('.agent-1c\auxiliary-archives\' + (ConvertTo-SafeName $branch)))
        forkStagingPath = (Join-Path $mainRoot ".agent-1c\fork-staging\$Name")
        startedAt = (Get-Date).ToString('o')
    }
    return [pscustomobject]$journal
}

function Remove-ItlBranchOwnedDirectory {
    param([string]$Root, [string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return }
    if (-not (Test-ItlArtifactPathInside -Root $Root -Path $Path) -or
        -not (Test-ItlArtifactPathWithoutReparse -Root $Root -Path $Path -Recursive)) { throw "DELETE_BRANCH_UNSAFE_PATH: $Path" }
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
}

function Unregister-ItlBranchLauncherEntry {
    param([object]$Journal)
    if (-not $Journal.launcherRegistered) { return }
    if (-not $Journal.launcherId -and (-not $Journal.launcherName -or -not $Journal.launcherFolder)) { throw 'DELETE_BRANCH_LAUNCHER_IDENTITY_MISSING' }
    $path = Get-LauncherListPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
    $lock = Enter-LauncherListLock -ListPath $path
    try {
        $lines = @(Read-Utf8Lines -Path $path)
        $matches = @(Get-LauncherSections -Lines $lines | Where-Object {
            if ($Journal.launcherId) { return ($_.values.ContainsKey('ID') -and $_.values.ID -ceq $Journal.launcherId) }
            return ($_.name -ceq $Journal.launcherName -and $_.values.ContainsKey('Folder') -and $_.values.Folder -ceq $Journal.launcherFolder -and
                $_.values.ContainsKey('Connect') -and $_.values.Connect -ceq $Journal.launcherConnect)
        })
        if ($matches.Count -eq 0) { return }
        if ($matches.Count -ne 1 -or -not $matches[0].values.ContainsKey('Connect') -or $matches[0].values.Connect -cne $Journal.launcherConnect) { throw 'DELETE_BRANCH_LAUNCHER_IDENTITY_MISMATCH' }
        $section = $matches[0]
        $remaining = [System.Collections.Generic.List[string]]::new()
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($i -lt $section.start -or $i -gt $section.end) { $remaining.Add([string]$lines[$i]) }
        }
        $temp = "$path.itl-delete-$PID-$([guid]::NewGuid().ToString('N')).tmp"
        try {
            [IO.File]::WriteAllLines($temp, $remaining.ToArray(), (Get-Utf8BomEncoding))
            Move-Item -LiteralPath $temp -Destination $path -Force
        } finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
    } finally { $lock.Dispose() }
}

function Remove-ItlBranchResultArtifacts {
    param([object]$Journal)
    $root = [string]$Journal.mainRoot
    foreach ($candidate in @(Get-ItlResultArtifactCandidates -ProjectRoot $root | Where-Object { $_.group -ceq $Journal.safeName })) {
        if (-not (Test-ItlArtifactPathWithoutReparse -Root $candidate.root -Path $candidate.path) -or
            -not (Test-ItlArtifactPathWithoutReparse -Root $candidate.root -Path $candidate.companion)) { throw "DELETE_BRANCH_RESULT_UNSAFE_PATH: $($candidate.path)" }
        if (Test-Path -LiteralPath $candidate.path) { Remove-Item -LiteralPath $candidate.path -Force -ErrorAction Stop }
        if (Test-Path -LiteralPath $candidate.companion) { Remove-Item -LiteralPath $candidate.companion -Force -ErrorAction Stop }
    }
}

function Remove-ItlDevBranch {
    param([string]$Name, [switch]$Confirmed)
    Assert-MasterWorktreeContext -Operation 'delete-dev-branch'
    if (-not $Name -or $Name -ne (ConvertTo-SafeName $Name)) { throw 'DELETE_BRANCH_NAME_INVALID' }
    $journalPath = Get-ItlBranchDeletionJournalPath -SafeName $Name
    $journal = if (Test-Path -LiteralPath $journalPath -PathType Leaf) { Read-Utf8Text -Path $journalPath | ConvertFrom-Json } else { New-ItlBranchDeletionJournal -Name $Name }
    if ([int]$journal.schemaVersion -ne 1 -or [string]$journal.branch -cne "itldev/$Name" -or [string]$journal.safeName -cne $Name -or
        -not [string]::Equals([IO.Path]::GetFullPath([string]$journal.mainRoot), [IO.Path]::GetFullPath($script:ProjectRoot), [StringComparison]::OrdinalIgnoreCase)) { throw 'DELETE_BRANCH_JOURNAL_IDENTITY_MISMATCH' }
    $expectedStateRoot = [string]$journal.stateRoot
    if (-not ([string]::Equals([IO.Path]::GetFullPath($expectedStateRoot), [IO.Path]::GetFullPath([string]$journal.mainRoot), [StringComparison]::OrdinalIgnoreCase) -or
        ($journal.worktreePath -and [string]::Equals([IO.Path]::GetFullPath($expectedStateRoot), [IO.Path]::GetFullPath([string]$journal.worktreePath), [StringComparison]::OrdinalIgnoreCase)))) { throw 'DELETE_BRANCH_JOURNAL_STATE_ROOT_MISMATCH' }
    $expectedStatePath = Join-Path $expectedStateRoot ".agent-1c\dev-branches\$Name.json"
    if (-not [string]::Equals([IO.Path]::GetFullPath([string]$journal.statePath), [IO.Path]::GetFullPath($expectedStatePath), [StringComparison]::OrdinalIgnoreCase)) { throw 'DELETE_BRANCH_JOURNAL_STATE_PATH_MISMATCH' }
    foreach ($spec in @(
        @{ value = [string]$journal.archivePath; expected = (Join-Path $script:ProjectRoot ".agent-1c\branch-archives\$Name") },
        @{ value = [string]$journal.auxiliaryArchivePath; expected = (Join-Path $script:ProjectRoot ('.agent-1c\auxiliary-archives\' + (ConvertTo-SafeName "itldev/$Name"))) },
        @{ value = [string]$journal.forkStagingPath; expected = (Join-Path $script:ProjectRoot ".agent-1c\fork-staging\$Name") }
    )) {
        if (-not [string]::Equals([IO.Path]::GetFullPath($spec.value), [IO.Path]::GetFullPath($spec.expected), [StringComparison]::OrdinalIgnoreCase)) { throw 'DELETE_BRANCH_JOURNAL_OWNED_PATH_MISMATCH' }
    }
    if ($journal.worktreePath) {
        $worktreePath = [IO.Path]::GetFullPath([string]$journal.worktreePath)
        if ([string]::Equals($worktreePath, [IO.Path]::GetFullPath($script:ProjectRoot), [StringComparison]::OrdinalIgnoreCase) -or
            (Test-ItlArtifactPathInside -Root $worktreePath -Path $script:ProjectRoot)) { throw 'DELETE_BRANCH_MAIN_WORKTREE_REFUSED' }
        $registered = Find-GitWorktreeByBranch -Branch ([string]$journal.branch)
        if ($registered -and -not [string]::Equals([IO.Path]::GetFullPath([string]$registered.path), $worktreePath, [StringComparison]::OrdinalIgnoreCase)) { throw 'DELETE_BRANCH_WORKTREE_IDENTITY_MISMATCH' }
        if ((Test-Path -LiteralPath $worktreePath) -and -not $registered) { throw 'DELETE_BRANCH_UNREGISTERED_WORKTREE_REFUSED' }
    }
    if ($journal.infoBaseKind -eq 'file' -and $journal.infoBasePath) {
        $sourcePath = [string](Get-SourceInfoBasePath)
        if (-not [IO.Path]::IsPathRooted($sourcePath)) { $sourcePath = Join-Path $script:ProjectRoot $sourcePath }
        $sourcePath = [IO.Path]::GetFullPath($sourcePath)
        $basePath = [IO.Path]::GetFullPath([string]$journal.infoBasePath)
        if ([string]::Equals($basePath, $sourcePath, [StringComparison]::OrdinalIgnoreCase) -or
            (Test-ItlArtifactPathInside -Root $basePath -Path $sourcePath) -or
            (Test-ItlArtifactPathInside -Root $sourcePath -Path $basePath)) { throw 'DELETE_BRANCH_SOURCE_INFOBASE_REFUSED' }
    }
    if (-not $Confirmed) {
        $answer = Read-Host "Delete $($journal.branch), its complete worktree and owned local data? [y/N]"
        if ($answer -notin @('y', 'Y', 'yes', 'YES', 'да', 'Да')) { Write-Host 'Branch deletion cancelled.'; return }
    }
    if (-not (Test-Path -LiteralPath $journalPath)) { Write-Utf8TextAtomic -Path $journalPath -Value (($journal | ConvertTo-Json -Depth 8) + [Environment]::NewLine) }
    $issues = [System.Collections.Generic.List[string]]::new()
    $externalLeftovers = [System.Collections.Generic.List[string]]::new()
    $mainRoot = [string]$journal.mainRoot
    $safe = [string]$journal.safeName
    if (Test-Path -LiteralPath ([string]$journal.statePath) -PathType Leaf) {
        try {
            $state = Read-DevBranchStateFile -Path ([string]$journal.statePath)
            Stop-DevBranchRuntimeBeforeInfobaseMutation -State $state -Reason 'delete-dev-branch'
            $portState = ConvertTo-Agent1cHashtable -Object $state
            foreach ($token in @('vanessaTestPortLeaseToken', 'vanessaMcpPortLeaseToken', 'roctupMcpPortLeaseToken')) { $portState[$token] = '' }
            Release-ItlManagedPortAllocationsForState -State $portState
        } catch { $issues.Add("runtime and port allocations: $($_.Exception.Message)") }
    }
    try { Unregister-ItlBranchLauncherEntry -Journal $journal } catch { $issues.Add("launcher: $($_.Exception.Message)") }
    if ($journal.publicationMode -eq 'auto' -and $journal.publicationDir) {
        try { Remove-ItlBranchOwnedDirectory -Root ([string]$journal.publicationRoot) -Path ([string]$journal.publicationDir) } catch { $issues.Add("publication: $($_.Exception.Message)") }
    } elseif ($journal.publicationMode -eq 'manual' -and $journal.publicationDir) { $externalLeftovers.Add("manual web publication requires owner cleanup: $($journal.publicationDir)") }
    foreach ($spec in @(
        @{ label = 'recovery archives'; root = (Join-Path $mainRoot '.agent-1c\branch-archives'); path = [string]$journal.archivePath },
        @{ label = 'auxiliary archives'; root = (Join-Path $mainRoot '.agent-1c\auxiliary-archives'); path = [string]$journal.auxiliaryArchivePath },
        @{ label = 'fork staging'; root = (Join-Path $mainRoot '.agent-1c\fork-staging'); path = [string]$journal.forkStagingPath }
    )) {
        try { Remove-ItlBranchOwnedDirectory -Root $spec.root -Path $spec.path } catch { $issues.Add("$($spec.label): $($_.Exception.Message)") }
    }
    try { Remove-ItlBranchResultArtifacts -Journal $journal } catch { $issues.Add("result artifacts: $($_.Exception.Message)") }
    if ($journal.infoBaseKind -eq 'file' -and $journal.infoBasePath) {
        try {
            $basePath = [string]$journal.infoBasePath
            if (-not ($journal.worktreePath -and (Test-ItlArtifactPathInside -Root ([string]$journal.worktreePath) -Path $basePath))) {
                $baseRoot = Resolve-ProjectPath (Get-DevBranchInfoBaseRoot)
                if (-not [string]::Equals([IO.Path]::GetFullPath($basePath), [IO.Path]::GetFullPath((Join-Path $baseRoot $safe)), [StringComparison]::OrdinalIgnoreCase)) { throw 'base is outside the exact configured managed path' }
                Remove-ItlBranchOwnedDirectory -Root $baseRoot -Path $basePath
            }
        } catch { $issues.Add("infobase: $($_.Exception.Message)") }
    } elseif ($journal.infoBaseKind -eq 'server') { $externalLeftovers.Add("server infobase requires administrator cleanup: $($journal.infoBasePath)") }
    elseif ($journal.infoBasePath) { $externalLeftovers.Add("unknown infobase kind '$($journal.infoBaseKind)': $($journal.infoBasePath)") }
    if ($journal.worktreePath) {
        try {
            $worktreePath = [string]$journal.worktreePath
            if (Test-Path -LiteralPath $worktreePath -PathType Container) {
                $registered = Find-GitWorktreeByBranch -Branch ([string]$journal.branch)
                if (-not $registered -or -not [string]::Equals([IO.Path]::GetFullPath([string]$registered.path), [IO.Path]::GetFullPath($worktreePath), [StringComparison]::OrdinalIgnoreCase)) { throw 'worktree ownership changed' }
                if (-not (Test-ItlArtifactPathWithoutReparse -Root (Split-Path -Parent $worktreePath) -Path $worktreePath -Recursive)) { throw 'worktree contains a reparse point' }
                & git -C $mainRoot worktree remove --force --force $worktreePath 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "git worktree remove exited $LASTEXITCODE" }
                if (Test-Path -LiteralPath $worktreePath) { Remove-ItlBranchOwnedDirectory -Root (Split-Path -Parent $worktreePath) -Path $worktreePath }
            }
        } catch { $issues.Add("worktree: $($_.Exception.Message)") }
    }
    try {
        $remainingWorktree = Find-GitWorktreeByBranch -Branch ([string]$journal.branch)
        if ($remainingWorktree) { throw "branch still has a worktree: $($remainingWorktree.path)" }
        & git -C $mainRoot show-ref --verify --quiet "refs/heads/$($journal.branch)"
        if ($LASTEXITCODE -eq 0) {
            & git -C $mainRoot branch -D ([string]$journal.branch) 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "git branch -D exited $LASTEXITCODE" }
        }
    } catch { $issues.Add("git branch: $($_.Exception.Message)") }
    try {
        $statePath = [string]$journal.statePath
        if ($statePath -and (Test-Path -LiteralPath $statePath)) {
            $expected = Join-Path $expectedStateRoot ".agent-1c\dev-branches\$safe.json"
            if (-not [string]::Equals([IO.Path]::GetFullPath($statePath), [IO.Path]::GetFullPath($expected), [StringComparison]::OrdinalIgnoreCase)) { throw 'state path is not exact' }
            Remove-Item -LiteralPath $statePath -Force -ErrorAction Stop
        }
    } catch { $issues.Add("state: $($_.Exception.Message)") }
    if ($issues.Count -gt 0) {
        foreach ($issue in $issues) { Write-Warning "Delete branch leftover: $issue" }
        throw "DELETE_BRANCH_INCOMPLETE: $($issues.Count) leftover(s); repeat the same command to retry. Journal: $journalPath"
    }
    Remove-Item -LiteralPath $journalPath -Force
    foreach ($leftover in $externalLeftovers) { Write-Warning "Delete branch external leftover: $leftover" }
    Write-Host "Deleted local development branch $($journal.branch), its worktree and owned local data. Remote refs and shared cache were not touched."
}
