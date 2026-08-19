# Candidate worktrees, qualification recovery, and develop/master delivery orchestration.

function New-DeliveryWorktree {
    param([string]$StartPoint, [string]$Purpose)
    $id = [guid]::NewGuid().ToString("N")
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-source-$Purpose-$id")
    $branch = "itl/$Purpose-$id"
    [void](Invoke-DeliveryGit -Arguments @("worktree", "add", "--quiet", "-b", $branch, $path, $StartPoint))
    return [pscustomobject]@{ path = $path; branch = $branch }
}

function Remove-DeliveryWorktree {
    param([object]$Worktree)
    if (-not $Worktree) { return }
    $resolved = [System.IO.Path]::GetFullPath([string]$Worktree.path)
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $resolved) -notlike "itl-source-*") {
        throw "Refusing to remove unexpected delivery worktree path: $resolved"
    }
    [void](Invoke-DeliveryGit -Arguments @("worktree", "remove", "--force", $resolved) -AllowFailure)
    [void](Invoke-DeliveryGit -Arguments @("branch", "-D", [string]$Worktree.branch) -AllowFailure)
}

function Add-QueuedRangesToCandidate {
    param([string]$CandidateRoot, [object[]]$Entries)
    foreach ($entry in @($Entries)) {
        $already = Invoke-WorktreeGit -Root $CandidateRoot -Arguments @("merge-base", "--is-ancestor", [string]$entry.head, "HEAD") -AllowFailure
        if ($already.exitCode -eq 0) { continue }
        $message = "Merge registered develop queue '$([string]$entry.id)' at $([string]$entry.head)"
        $result = Invoke-WorktreeGit -Root $CandidateRoot -Arguments @("merge", "--no-commit", "-m", $message, [string]$entry.head) -AllowFailure
        if ($result.exitCode -ne 0) {
            [void](Invoke-WorktreeGit -Root $CandidateRoot -Arguments @("merge", "--abort") -AllowFailure)
            throw "Queued range '$($entry.id)' conflicts with the develop candidate at $($entry.head). Resolve it in its source task and register again."
        }

        $mergeHead = Invoke-WorktreeGit -Root $CandidateRoot -Arguments @("rev-parse", "--verify", "MERGE_HEAD") -AllowFailure
        if ($mergeHead.exitCode -ne 0) { continue }

        $commitDate = (Invoke-WorktreeGit -Root $CandidateRoot -Arguments @("show", "-s", "--format=%cI", [string]$entry.head)).stdout.Trim()
        $previousAuthorDate = [Environment]::GetEnvironmentVariable("GIT_AUTHOR_DATE", "Process")
        $previousCommitterDate = [Environment]::GetEnvironmentVariable("GIT_COMMITTER_DATE", "Process")
        try {
            $env:GIT_AUTHOR_DATE = $commitDate
            $env:GIT_COMMITTER_DATE = $commitDate
            $commit = Invoke-WorktreeGit -Root $CandidateRoot -Arguments @("commit", "--no-edit") -AllowFailure
        } finally {
            if ($null -eq $previousAuthorDate) { Remove-Item Env:GIT_AUTHOR_DATE -ErrorAction SilentlyContinue } else { $env:GIT_AUTHOR_DATE = $previousAuthorDate }
            if ($null -eq $previousCommitterDate) { Remove-Item Env:GIT_COMMITTER_DATE -ErrorAction SilentlyContinue } else { $env:GIT_COMMITTER_DATE = $previousCommitterDate }
        }
        if ($commit.exitCode -ne 0) {
            [void](Invoke-WorktreeGit -Root $CandidateRoot -Arguments @("merge", "--abort") -AllowFailure)
            throw "Queued range '$($entry.id)' could not be committed into the deterministic develop candidate at $($entry.head)."
        }
    }
}

function Sync-LocalDevelopAfterPublish {
    $branch = Get-GitValue -Arguments @("branch", "--show-current")
    if ($branch -ne "develop") { return }
    Assert-CleanDeliveryWorktree
    [void](Invoke-DeliveryGit -Arguments @("fetch", $script:Remote, "develop"))
    $ff = Invoke-DeliveryGit -Arguments @("merge", "--ff-only", "$script:Remote/develop") -AllowFailure
    if ($ff.exitCode -ne 0) { throw "Remote develop was published, but local develop could not fast-forward. Inspect local-only commits before continuing." }
}

function Publish-AccumulatedDevelop {
    Assert-CleanDeliveryWorktree
    [void](Invoke-DeliveryGit -Arguments @("fetch", $script:Remote, "develop"))
    $remoteBefore = Get-GitValue -Arguments @("rev-parse", "$script:Remote/develop")
    $entries = @(Get-QueueEntries)
    if ($entries.Count -eq 0) { throw "There are no registered develop changes to publish." }

    $worktree = $null
    $deliverySucceeded = $false
    try {
        $worktree = New-DeliveryWorktree -StartPoint "$script:Remote/develop" -Purpose "publish-develop"
        Add-QueuedRangesToCandidate -CandidateRoot $worktree.path -Entries $entries
        $candidateTree = (Invoke-WorktreeGit -Root $worktree.path -Arguments @("rev-parse", "HEAD^{tree}")).stdout.Trim()
        $exactDevelopQualificationRestored = Restore-DeliveryQualification -CandidateRoot $worktree.path -Tree $candidateTree
        if (-not $exactDevelopQualificationRestored) {
            $baselineTree = (Invoke-WorktreeGit -Root $worktree.path -Arguments @("rev-parse", "$remoteBefore^{tree}")).stdout.Trim()
            [void](Restore-DeliveryQualification -CandidateRoot $worktree.path -Tree $baselineTree)
        }
        # Always enter Develop, even when exact proof was restored. Its static
        # and journey checkpoints make this a cheap resume while readiness
        # recomputes the mutable stand/runtime identity before optional Release.
        Invoke-SourceGate -Mode "Develop" -WorkingRoot $worktree.path -TargetBaseRef $remoteBefore
        [void](Save-DeliveryQualification -CandidateRoot $worktree.path -Tree $candidateTree)
        if ($RequireRelease) {
            Invoke-SourceGate -Mode "Release" -WorkingRoot $worktree.path
            [void](Save-DeliveryQualification -CandidateRoot $worktree.path -Tree $candidateTree)
        }

        $candidate = (Invoke-WorktreeGit -Root $worktree.path -Arguments @("rev-parse", "HEAD")).stdout.Trim()
        $componentPublication = Invoke-ComponentPublicationFinalizer -CandidateRoot $worktree.path -CandidateCommit $candidate
        $push = Invoke-WorktreeGit -Root $worktree.path -Arguments @("push", $script:Remote, "HEAD:refs/heads/develop") -AllowFailure
        if ($push.exitCode -ne 0) { throw "origin/develop changed or rejected the fast-forward push. The queue is preserved; rebuild the candidate from the new remote head." }
        $remoteAfter = (Invoke-WorktreeGit -Root $worktree.path -Arguments @("ls-remote", $script:Remote, "refs/heads/develop")).stdout.Split([char]9)[0].Trim()
        if ($remoteAfter -ne $candidate) { throw "Published develop verification failed: expected $candidate, remote reports $remoteAfter." }
        Clear-PublishedQueueEntries -PublishedCommit $candidate
        Sync-LocalDevelopAfterPublish
        $deliverySucceeded = $true
        return [pscustomobject]@{ status = "published"; branch = "develop"; commit = $candidate; tree = $candidateTree; releaseQualified = [bool]$RequireRelease; componentPublication = $componentPublication }
    } finally {
        $customGate = $script:GateScript -ne (Join-Path $script:Root "scripts\check.ps1")
        if ($deliverySucceeded -or $customGate) { Remove-DeliveryWorktree -Worktree $worktree }
        elseif ($worktree) { Write-Warning "Develop candidate was preserved for diagnosis and retry: $($worktree.path) (branch $($worktree.branch)). The queue is unchanged." }
    }
}

function Publish-ReleaseVersion {
    param([string]$Commit)
    if (-not $Version) { return }
    if ($Version -notmatch '^itl-workflow-v\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$') { throw "Version must look like itl-workflow-v1.2.3." }
    [void](Invoke-DeliveryGit -Arguments @("tag", "-a", $Version, $Commit, "-m", "ITL workflow $Version"))
    [void](Invoke-DeliveryGit -Arguments @("push", $script:Remote, "refs/tags/$Version"))
    $gh = Get-Command gh -ErrorAction SilentlyContinue
    if (-not $gh) { throw "Tag $Version was published, but GitHub CLI is unavailable; create the GitHub Release explicitly." }
    & $gh.Source release create $Version --verify-tag --title $Version --generate-notes
    if ($LASTEXITCODE -ne 0) { throw "Tag $Version was published, but GitHub Release creation failed." }
}

function Assert-ReleaseVersionRequest {
    if (-not $Version) { return }
    if ($Version -notmatch '^itl-workflow-v\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$') { throw "Version must look like itl-workflow-v1.2.3." }
    if ((Invoke-DeliveryGit -Arguments @("rev-parse", "--verify", "refs/tags/$Version") -AllowFailure).exitCode -eq 0) { throw "Local tag already exists: $Version" }
    if ((Invoke-DeliveryGit -Arguments @("ls-remote", "--exit-code", "--tags", $script:Remote, "refs/tags/$Version") -AllowFailure).exitCode -eq 0) { throw "Remote tag already exists: $Version" }
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw "GitHub CLI is required before a versioned master release can start." }
}

function Release-DevelopToMaster {
    Assert-ReleaseVersionRequest
    Assert-CleanDeliveryWorktree
    if (@(Get-QueueEntries).Count -gt 0) { throw "ReleaseMaster requires an empty develop queue. Publish accumulated develop changes first." }
    [void](Invoke-DeliveryGit -Arguments @("fetch", $script:Remote, "develop", "master"))
    $localDevelop = Get-GitValue -Arguments @("rev-parse", "develop")
    $remoteDevelop = Get-GitValue -Arguments @("rev-parse", "$script:Remote/develop")
    $remoteMaster = Get-GitValue -Arguments @("rev-parse", "$script:Remote/master")
    if ($localDevelop -ne $remoteDevelop) { throw "Local develop must equal origin/develop before ReleaseMaster." }

    $worktree = $null
    $deliverySucceeded = $false
    try {
        $worktree = New-DeliveryWorktree -StartPoint "$script:Remote/develop" -Purpose "release-master"
        $masterAncestor = Invoke-WorktreeGit -Root $worktree.path -Arguments @("merge-base", "--is-ancestor", "$script:Remote/master", "HEAD") -AllowFailure
        if ($masterAncestor.exitCode -ne 0) {
            $merge = Invoke-WorktreeGit -Root $worktree.path -Arguments @("merge", "--no-ff", "--no-edit", "$script:Remote/master") -AllowFailure
            if ($merge.exitCode -ne 0) {
                [void](Invoke-WorktreeGit -Root $worktree.path -Arguments @("merge", "--abort") -AllowFailure)
                throw "origin/master conflicts with develop. Resolve the release reconciliation on develop and publish it first."
            }
        }
        $candidateTree = (Invoke-WorktreeGit -Root $worktree.path -Arguments @("rev-parse", "HEAD^{tree}")).stdout.Trim()
        [void](Restore-DeliveryQualification -CandidateRoot $worktree.path -Tree $candidateTree)
        Invoke-SourceGate -Mode "Develop" -WorkingRoot $worktree.path -TargetBaseRef $remoteDevelop
        [void](Save-DeliveryQualification -CandidateRoot $worktree.path -Tree $candidateTree)
        Invoke-SourceGate -Mode "Release" -WorkingRoot $worktree.path
        $candidate = (Invoke-WorktreeGit -Root $worktree.path -Arguments @("rev-parse", "HEAD")).stdout.Trim()
        foreach ($oldHead in @($remoteDevelop, $remoteMaster)) {
            if ((Invoke-WorktreeGit -Root $worktree.path -Arguments @("merge-base", "--is-ancestor", $oldHead, $candidate) -AllowFailure).exitCode -ne 0) {
                throw "Release candidate does not contain both fetched remote branch histories. Nothing was published."
            }
        }
        $push = Invoke-WorktreeGit -Root $worktree.path -Arguments @("push", "--atomic", $script:Remote, "HEAD:refs/heads/develop", "HEAD:refs/heads/master") -AllowFailure
        if ($push.exitCode -ne 0) { throw "Release candidate passed, but the atomic develop/master fast-forward push was rejected. Neither branch was published and no force push was attempted." }
        foreach ($branch in @("develop", "master")) {
            $remoteCommit = (Invoke-WorktreeGit -Root $worktree.path -Arguments @("ls-remote", $script:Remote, "refs/heads/$branch")).stdout.Split([char]9)[0].Trim()
            if ($remoteCommit -ne $candidate) { throw "Remote $branch verification failed after release." }
            $remoteTree = (Invoke-WorktreeGit -Root $worktree.path -Arguments @("rev-parse", "$remoteCommit^{tree}")).stdout.Trim()
            if ($remoteTree -ne $candidateTree) { throw "Remote $branch tree verification failed after release." }
        }
        Publish-ReleaseVersion -Commit $candidate
        Sync-LocalDevelopAfterPublish
        $deliverySucceeded = $true
        return [pscustomobject]@{ status = "released"; commit = $candidate; tree = $candidateTree; version = $Version }
    } finally {
        $customGate = $script:GateScript -ne (Join-Path $script:Root "scripts\check.ps1")
        if ($deliverySucceeded -or $customGate) { Remove-DeliveryWorktree -Worktree $worktree }
        elseif ($worktree) { Write-Warning "Release candidate was preserved for diagnosis and retry: $($worktree.path) (branch $($worktree.branch)). No force push was attempted." }
    }
}
