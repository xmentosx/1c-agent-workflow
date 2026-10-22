# Queue registration and atomic shared-ref transactions for source delivery.

function ConvertTo-QueueRefName {
    param([string]$Value)
    $name = $Value.Trim().Replace('\', '/').ToLowerInvariant()
    $name = [regex]::Replace($name, '[^a-z0-9._/-]+', '-')
    $name = [regex]::Replace($name, '/+', '/')
    $name = $name.Trim('/', '.', '-')
    if (-not $name) { throw "Queue id cannot be converted to a safe Git ref name." }
    return $name
}

function Get-DefaultQueueId {
    $branch = Get-GitValue -Arguments @("branch", "--show-current")
    if ($branch) { return $branch }
    return "detached-" + (Get-GitValue -Arguments @("rev-parse", "--short=12", "HEAD"))
}

function Invoke-QueueRefTransaction {
    param([string[]]$Commands, [switch]$AllowFailure)
    $payload = (($Commands -join "`n") + "`n")
    $result = Invoke-DeliveryGit -Arguments @("update-ref", "--stdin") -StandardInput $payload -AllowFailure:$AllowFailure
    if ($AllowFailure) { return $result }
}

function Get-SourceRegistrationSnapshot {
    $candidateRef = "refs/itl/develop-candidate/head"
    $stateRef = "refs/itl/develop-candidate/state"
    $refs = @{}
    $records = @{}
    $output = Invoke-DeliveryGit -Arguments @("for-each-ref", "--format=%(refname) %(objectname)", "$script:QueueRoot/", "refs/itl/develop-candidate/")
    foreach ($line in @($output.stdout -split "`r?`n" | Where-Object { $_ })) {
        $parts = $line.Split(' ', 2)
        $refs[[string]$parts[0]] = [string]$parts[1]
        if ($parts[0] -notmatch ('^' + [regex]::Escape($script:QueueRoot) + '/(.+)/(base|head)$')) { continue }
        $id = $Matches[1]; $kind = $Matches[2]
        if (-not $records.ContainsKey($id)) { $records[$id] = [ordered]@{ id=$id; base=""; head="" } }
        $records[$id][$kind] = [string]$parts[1]
    }
    foreach ($entry in @($records.Values)) {
        if (-not $entry.base -or -not $entry.head) {
            throw "Queue $($entry.id) has incomplete base/head refs. The queue was preserved; inspect source-delivery Status and continue through its owning registration."
        }
    }
    $entries = @($records.Values | ForEach-Object { [pscustomobject]$_ } | Sort-Object id)
    $candidate = if ($refs.ContainsKey($candidateRef)) { [string]$refs[$candidateRef] } else { "" }
    $stateObject = if ($refs.ContainsKey($stateRef)) { [string]$refs[$stateRef] } else { "" }
    $state = $null
    if ($candidate -and $stateObject) {
        try {
            $state = (Invoke-DeliveryGit -Arguments @("cat-file", "blob", $stateObject)).stdout | ConvertFrom-Json
            if ([int]$state.schemaVersion -ne 1 -or [string]$state.kind -ne "itl-source-candidate" -or
                'queue' -notin $state.PSObject.Properties.Name -or 'remoteBefore' -notin $state.PSObject.Properties.Name -or
                [string]$state.candidate -cne $candidate -or [string]$state.tree -cne (Get-GitValue -Arguments @("rev-parse", "$candidate^{tree}"))) { $state = $null }
        } catch { $state = $null }
    }
    foreach ($entry in $entries) {
        $known = @(if ($state) { $state.queue | Where-Object { [string]$_.id -ceq [string]$entry.id -and [string]$_.base -ceq [string]$entry.base -and [string]$_.head -ceq [string]$entry.head } })
        if ($known.Count -eq 1) { continue }
        if ((Invoke-DeliveryGit -Arguments @("merge-base", "--is-ancestor", [string]$entry.base, [string]$entry.head) -AllowFailure).exitCode -ne 0) {
            throw "Queue $($entry.id) is corrupt: its base $($entry.base) is not an ancestor of its head $($entry.head). Accepted refs were preserved; inspect Status and continue from the queue's registered task."
        }
    }
    $remoteRef = "refs/remotes/$script:Remote/develop"
    return [pscustomobject]@{
        refs=$refs; entries=$entries; candidateRef=$candidateRef; stateRef=$stateRef
        candidate=$candidate; stateObject=$stateObject; state=$state
        remoteRef=$remoteRef; remoteBefore=(Get-GitValue -Arguments @("rev-parse", $remoteRef))
    }
}

function Get-SourceRegistrationStartPoint {
    param([object]$Snapshot)
    if (-not $Snapshot.state) { return [string]$Snapshot.remoteBefore }
    if ([string]$Snapshot.state.remoteBefore -cne [string]$Snapshot.remoteBefore -and
        (Invoke-DeliveryGit -Arguments @("merge-base", "--is-ancestor", [string]$Snapshot.candidate, [string]$Snapshot.remoteBefore) -AllowFailure).exitCode -eq 0) {
        # Published develop has already qualified this candidate and any
        # installability promotion. Do not count that released delta again.
        return [string]$Snapshot.remoteBefore
    }
    # A legacy published owner may have appended or cleared queue refs without
    # updating our candidate. Keep its records and qualify the additional delta.
    # A removed accepted range is reusable only after develop contains it.
    foreach ($prior in @($Snapshot.state.queue)) {
        $current = @($Snapshot.entries | Where-Object id -eq ([string]$prior.id))
        $descendant = if ($current.Count -eq 1) { [string]$current[0].head } else { [string]$Snapshot.remoteBefore }
        if ((Invoke-DeliveryGit -Arguments @("merge-base", "--is-ancestor", [string]$prior.head, $descendant) -AllowFailure).exitCode -ne 0) {
            # Rebuild from authoritative current queue; never trust a stale tree
            # as proof of a rewritten or removed range.
            return [string]$Snapshot.remoteBefore
        }
    }
    return [string]$Snapshot.candidate
}

function Get-SourceCandidateStatus {
    try { $snapshot = Get-SourceRegistrationSnapshot }
    catch { return [pscustomobject]@{ status="requires-integration"; error=$_.Exception.Message } }
    $status = if ($snapshot.state) { "ready" } elseif ($snapshot.candidate -or $snapshot.stateObject) { "requires-integration" } else { "legacy" }
    if ($snapshot.state) {
        $accepted = @($snapshot.state.queue | Sort-Object id | ForEach-Object { "$($_.id) $($_.base) $($_.head)" }) -join "`n"
        $current = @($snapshot.entries | ForEach-Object { "$($_.id) $($_.base) $($_.head)" }) -join "`n"
        if ($accepted -cne $current -or [string]$snapshot.state.remoteBefore -cne [string]$snapshot.remoteBefore) { $status = "requires-integration" }
    }
    return [pscustomobject]@{ status=$status; head=[string]$snapshot.candidate; tree=$(if ($snapshot.state) { [string]$snapshot.state.tree } else { "" }); queueCount=@($snapshot.entries).Count }
}

function Save-SourceRegistrationEvidence {
    param([string]$CandidateRoot, [string]$Candidate, [string]$RunRecordPath)
    if (-not $RunRecordPath -or -not (Test-Path -LiteralPath $RunRecordPath -PathType Leaf)) {
        throw "Registration has no durable passed gate record. The candidate and queue were preserved."
    }
    $relative = "itl/registrations/v1/" + [IO.Path]::GetFileNameWithoutExtension($RunRecordPath)
    $root = Join-Path (Get-DeliveryCommonGitDirectory) $relative
    New-Item -ItemType Directory -Path $root -ErrorAction Stop | Out-Null
    foreach ($path in @("build\test-results\local", "build\test-results\delivery", "build\source-registration")) {
        $source = Join-Path $CandidateRoot $path
        if (Test-Path -LiteralPath $source -PathType Container) {
            Copy-Item -LiteralPath $source -Destination (Join-Path $root (Split-Path -Leaf $path)) -Recurse -ErrorAction Stop
        }
    }
    $files = @(Get-ChildItem -LiteralPath $root -File -Recurse | Sort-Object FullName | ForEach-Object {
        [ordered]@{ path=$_.FullName.Substring($root.Length + 1).Replace('\','/'); sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
    })
    $manifest = Join-Path $root "manifest.json"
    [IO.File]::WriteAllText($manifest, ([ordered]@{ candidate=$Candidate; runRecord=[IO.Path]::GetFileName($RunRecordPath); files=$files } | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
    # This preserves audit artifacts; the existing input-bound shard cache is
    # still the only admission path for reusing test results.
    return [pscustomobject]@{ path=$relative; manifestSha256=(Get-FileHash -LiteralPath $manifest -Algorithm SHA256).Hash.ToLowerInvariant() }
}

function Try-AcceptSourceRegistration {
    param([object]$Snapshot, [string]$Id, [string]$Base, [string]$Head, [string]$Candidate, [string]$Tree, [object[]]$Entries, [object]$Evidence)
    $zero = '0' * 40
    $state = [ordered]@{
        schemaVersion=1; kind="itl-source-candidate"; candidate=$Candidate; tree=$Tree
        remoteBefore=[string]$Snapshot.remoteBefore; supervisor=[string]$script:DeliverySupervisorCommit; evidence=$Evidence
        queue=@($Entries | ForEach-Object { [ordered]@{ id=[string]$_.id; base=[string]$_.base; head=[string]$_.head } })
    }
    $stateObject = (Invoke-DeliveryGit -Arguments @("hash-object", "-w", "--stdin") -StandardInput ($state | ConvertTo-Json -Depth 8 -Compress)).stdout.Trim()
    $commands = New-Object System.Collections.Generic.List[string]
    $commands.Add("start") | Out-Null
    $commands.Add("verify $($Snapshot.remoteRef) $($Snapshot.remoteBefore)") | Out-Null
    foreach ($entry in @($Snapshot.entries | Where-Object id -ne $Id)) {
        $commands.Add("verify $script:QueueRoot/$($entry.id)/base $($entry.base)") | Out-Null
        $commands.Add("verify $script:QueueRoot/$($entry.id)/head $($entry.head)") | Out-Null
    }
    foreach ($update in @(
        @("$script:QueueRoot/$Id/base", $Base), @("$script:QueueRoot/$Id/head", $Head),
        @([string]$Snapshot.candidateRef, $Candidate), @([string]$Snapshot.stateRef, $stateObject)
    )) {
        $expected = if ($Snapshot.refs.ContainsKey([string]$update[0])) { [string]$Snapshot.refs[[string]$update[0]] } else { $zero }
        $commands.Add("update $($update[0]) $($update[1]) $expected") | Out-Null
    }
    $commands.Add("prepare") | Out-Null
    $commands.Add("commit") | Out-Null
    $result = Invoke-QueueRefTransaction -Commands @($commands) -AllowFailure
    if ($result.exitCode -eq 0) { return $true }
    $current = Get-SourceRegistrationSnapshot
    $before = @($Snapshot.refs.Keys | Sort-Object | ForEach-Object { "$_ $($Snapshot.refs[$_])" }) -join "`n"
    $after = @($current.refs.Keys | Sort-Object | ForEach-Object { "$_ $($current.refs[$_])" }) -join "`n"
    if ($before -ne $after -or $Snapshot.remoteBefore -ne $current.remoteBefore) { return $false }
    throw "Candidate transaction failed without concurrent ref movement. All accepted refs were preserved. $($result.stderr)"
}

function Get-QueueEntries {
    $result = Invoke-DeliveryGit -Arguments @("for-each-ref", "--format=%(refname) %(objectname)", "$script:QueueRoot/")
    $records = @{}
    foreach ($line in @($result.stdout -split "`r?`n" | Where-Object { $_ })) {
        $parts = $line.Split(' ', 2)
        $ref = [string]$parts[0]
        $sha = [string]$parts[1]
        if ($ref -notmatch ('^' + [regex]::Escape($script:QueueRoot) + '/(.+)/(base|head)$')) { continue }
        $id = $Matches[1]
        $kind = $Matches[2]
        if (-not $records.ContainsKey($id)) { $records[$id] = [ordered]@{ id = $id; base = ""; head = "" } }
        $records[$id][$kind] = $sha
    }
    $entries = @($records.Values | Where-Object { $_.base -and $_.head } | ForEach-Object { [pscustomobject]$_ })
    return @($entries | Sort-Object -Property id)
}

function Clear-PublishedQueueEntries {
    param([string]$PublishedCommit, [AllowEmptyCollection()][object[]]$Entries)
    $frozen = if ($PSBoundParameters.ContainsKey('Entries')) { @($Entries) } else { @(Get-QueueEntries) }
    for ($retry = 0; $retry -lt 3; $retry++) {
        $current = @(Get-QueueEntries)
        $commands = New-Object System.Collections.Generic.List[string]
        $selected = @()
        foreach ($entry in $frozen) {
            $same = @($current | Where-Object { [string]$_.id -ceq [string]$entry.id -and [string]$_.base -ceq [string]$entry.base -and [string]$_.head -ceq [string]$entry.head })
            if ($same.Count -ne 1) { continue }
            $reachable = Invoke-DeliveryGit -Arguments @("merge-base", "--is-ancestor", [string]$entry.head, $PublishedCommit) -AllowFailure
            if ($reachable.exitCode -eq 0) {
                $selected += $entry
                $commands.Add("delete $script:QueueRoot/$($entry.id)/base $($entry.base)") | Out-Null
                $commands.Add("delete $script:QueueRoot/$($entry.id)/head $($entry.head)") | Out-Null
            }
        }
        if ($commands.Count -eq 0) { return }
        try { Invoke-QueueRefTransaction -Commands @($commands); return }
        catch {
            $transactionFailure = $_
            $after = @(Get-QueueEntries)
            $moved = @($selected | Where-Object {
                $old = $_
                @($after | Where-Object { [string]$_.id -ceq [string]$old.id -and [string]$_.base -ceq [string]$old.base -and [string]$_.head -ceq [string]$old.head }).Count -ne 1
            })
            if ($moved.Count -eq 0) { throw $transactionFailure }
        }
    }
    throw "Published candidate queue cleanup observed repeated concurrent movement. Accepted refs and publication checkpoint were preserved; repeat the same publication command to finish cleanup without requalifying the published candidate."
}

function Assert-SourceRegistrationTransitionReady {
    $attemptPath = Get-DevelopPublicationAttemptPath
    if (-not (Test-Path -LiteralPath $attemptPath -PathType Leaf)) { return }
    $attempt = Get-Content -LiteralPath $attemptPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $activePlanId = if ($attempt.PSObject.Properties['planId']) { [string]$attempt.planId } else { '' }
    if ($attempt.PSObject.Properties['sourceRegistrationProtocol'] -and [int]$attempt.sourceRegistrationProtocol -eq 1) { return }
    if ($attempt.PSObject.Properties['planId'] -and [string]$attempt.planId) {
        $planPath = Join-Path (Get-DeliveryPlanRoot) "$([string]$attempt.planId).json"
        if (Test-Path -LiteralPath $planPath -PathType Leaf) {
            $plan = Get-Content -LiteralPath $planPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($plan.PSObject.Properties['queue']) { return }
        }
    }
    throw "DELIVERY_LEGACY_PUBLICATION_ACTIVE: the historical publication checkpoint '$attemptPath' must finish before the first candidate-CAS registration. Continue its original PublishDevelop options under plan '$activePlanId', then repeat this RegisterChange with the same QueueId. No registration, task work or proof was changed."
}

function Get-SourceRegistrationUtcNow {
    # One clock boundary lets the deadline regression advance time without
    # coupling repeated CAS losses to machine speed or real sleeps.
    return [DateTime]::UtcNow
}

function Register-SourceChange {
    Assert-CleanDeliveryWorktree
    $head = Get-GitValue -Arguments @("rev-parse", "HEAD")
    $base = if ($BaseRef) { Get-GitValue -Arguments @("rev-parse", $BaseRef) } else { Get-GitValue -Arguments @("rev-parse", "$script:Remote/develop") }
    $id = ConvertTo-QueueRefName -Value $(if ($QueueId) { $QueueId } else { Get-DefaultQueueId })
    $allowMissingCatalog = $script:GateScript -ne (Join-Path $script:Root "scripts\check.ps1")
    $budgetSeconds = Get-SourceGateHardBudgetSeconds -Mode "Targeted" -WorkingRoot $script:Root -AllowMissingCatalog:$allowMissingCatalog
    $deadline = (Get-SourceRegistrationUtcNow).AddSeconds($budgetSeconds)
    $worktree = $null
    $accepted = $false
    $attempt = 0
    try {
        while ($true) {
            if ((Get-SourceRegistrationUtcNow) -ge $deadline) {
                throw "Registration exhausted its original $budgetSeconds second budget. Candidate, task and proof are preserved; repeat RegisterChange with the same QueueId '$id' from the unchanged source checkout."
            }
            $attempt++
            Assert-SourceRegistrationTransitionReady
            $snapshot = Get-SourceRegistrationSnapshot
            $old = @($snapshot.entries | Where-Object id -eq $id)
            $oldBase = if ($old.Count) { [string]$old[0].base } else { "" }
            $oldHead = if ($old.Count) { [string]$old[0].head } else { "" }
            if ($oldHead) {
                if ((Invoke-DeliveryGit -Arguments @("merge-base", "--is-ancestor", $oldBase, $oldHead) -AllowFailure).exitCode -ne 0) {
                    throw "Queue $id is corrupt: its base $oldBase is not an ancestor of its head $oldHead. The accepted queue was preserved."
                }
                if ((Invoke-DeliveryGit -Arguments @("merge-base", "--is-ancestor", $oldHead, $head) -AllowFailure).exitCode -ne 0) {
                    throw "Existing queue head $oldHead is not an ancestor of HEAD $head. Continue the same QueueId from its registered head or use a different QueueId."
                }
            } elseif ((Invoke-DeliveryGit -Arguments @("merge-base", "--is-ancestor", $base, $head) -AllowFailure).exitCode -ne 0) {
                throw "Queue base $base is not an ancestor of HEAD $head. Rebase the task on current develop."
            }
            $targetBase = if ($oldHead) { $oldHead } else { $base }
            if ($targetBase -eq $head) { throw "There are no commits to register after $targetBase." }
            $changed = @(Get-RepositoryGitPathList -RepositoryRoot $script:Root -Arguments @("diff", "--name-only", "-z", "$targetBase...$head", "--"))
            $testChanged = @($changed | Where-Object { ([string]$_).Replace('\', '/') -like "tests/pester/*.Tests.ps1" }).Count -gt 0
            if (-not $testChanged -and @($CoverageContract | Where-Object { $_ }).Count -eq 0) {
                throw "Executable changes without a test change must declare an existing -CoverageContract. Registration was not created."
            }
            $startPoint = Get-SourceRegistrationStartPoint -Snapshot $snapshot
            if (-not $worktree) { $worktree = New-DeliveryWorktree -StartPoint $startPoint -Purpose "register" }
            else { [void](Invoke-WorktreeGit -Root $worktree.path -Arguments @("reset", "--hard", $startPoint)) }
            # Admit the already validated source head first: it may contain an
            # explicit merge resolution between its queued head and develop.
            # Otherwise the old accepted candidate can conflict with develop
            # before the resolving source lineage is ever considered.
            Add-QueuedRangesToCandidate -CandidateRoot $worktree.path -Entries @([pscustomobject]@{ id=$id; head=$head })
            Add-QueuedRangesToCandidate -CandidateRoot $worktree.path -Entries $snapshot.entries -PublishedDevelop $snapshot.remoteBefore
            $candidate = (Invoke-WorktreeGit -Root $worktree.path -Arguments @("rev-parse", "HEAD")).stdout.Trim()
            $tree = (Invoke-WorktreeGit -Root $worktree.path -Arguments @("rev-parse", "HEAD^{tree}")).stdout.Trim()
            $queueBase = if ($oldBase) { $oldBase } else { $base }
            $entries = @(@($snapshot.entries | Where-Object id -ne $id) + @([pscustomobject]@{ id=$id; base=$queueBase; head=$head }) | Sort-Object id)
            $checkpointRoot = Join-Path $worktree.path "build\source-registration"
            New-Item -ItemType Directory -Force -Path $checkpointRoot | Out-Null
            $checkpoint = [ordered]@{ id=$id; sourceRoot=$script:Root; taskHead=$head; candidate=$candidate; previous=$startPoint; deadline=$deadline.ToString("o"); attempt=$attempt; queue=$entries }
            [IO.File]::WriteAllText((Join-Path $checkpointRoot "checkpoint.json"), ($checkpoint | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
            # No shared operation lease is held during composition or checking.
            # The existing shard cache admits unchanged input proofs on a retry.
            $runRecordPath = Invoke-SourceGate -Mode "Targeted" -WorkingRoot $worktree.path -TargetBaseRef $startPoint -DeadlineUtc $deadline -PassThru
            if ((Invoke-WorktreeGit -Root $worktree.path -Arguments @("status", "--porcelain", "--untracked-files=all")).stdout -or
                (Invoke-WorktreeGit -Root $worktree.path -Arguments @("rev-parse", "HEAD")).stdout.Trim() -cne $candidate) {
                throw "Targeted changed its candidate. Registration was not accepted; inspect the preserved worktree."
            }
            Assert-CleanDeliveryWorktree
            if ((Get-GitValue -Arguments @("rev-parse", "HEAD")) -cne $head) { throw "Source HEAD changed during registration. Repeat RegisterChange from the intended committed source task." }
            $evidence = Save-SourceRegistrationEvidence -CandidateRoot $worktree.path -Candidate $candidate -RunRecordPath $runRecordPath
            if ((Get-SourceRegistrationUtcNow) -ge $deadline) { continue }
            if (Try-AcceptSourceRegistration -Snapshot $snapshot -Id $id -Base $queueBase -Head $head -Candidate $candidate -Tree $tree -Entries $entries -Evidence $evidence) {
                $accepted = $true
                return [pscustomobject]@{ status="registered"; id=$id; base=$queueBase; head=$head; paths=$changed; candidate=$candidate; tree=$tree; attempts=$attempt }
            }
        }
    } finally {
        if ($accepted) { Remove-DeliveryWorktree -Worktree $worktree }
        elseif ($worktree) { Write-Warning "Registration candidate and proof were preserved at $($worktree.path) (branch $($worktree.branch)). Continue RegisterChange from the source task with QueueId '$id'; accepted refs were not replaced by a failed candidate." }
    }
}
