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

function Get-DevelopPublicationAttemptPath {
    return Join-Path (Get-DeliveryCommonGitDirectory) "itl\publication-attempts\develop.json"
}

function Get-DeliveryTextSha256 {
    param([Parameter(Mandatory = $true)][string]$Text)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace("-", "").ToLowerInvariant()
    } finally { $algorithm.Dispose() }
}

function Get-DeliveryFileIdentity {
    param([AllowEmptyString()][string]$Path)
    if (-not $Path) { return "none" }
    $resolved = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { return "$resolved|missing" }
    return "$resolved|$((Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash.ToLowerInvariant())"
}

function Get-DevelopPublicationEnvironmentIdentity {
    if (-not $E2EProjectRoot) { return "none" }
    $projectRoot = [IO.Path]::GetFullPath($E2EProjectRoot)
    if (-not (Test-Path -LiteralPath $projectRoot -PathType Container)) { return "$projectRoot|missing" }
    $standConfigPath = Join-Path $projectRoot ".agent-1c\release-e2e.json"
    $developRoot = ""
    if (Test-Path -LiteralPath $standConfigPath -PathType Leaf) {
        try {
            $standConfig = Get-Content -LiteralPath $standConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([string]$standConfig.developWorktreePath) { $developRoot = [IO.Path]::GetFullPath([string]$standConfig.developWorktreePath) }
        } catch { $developRoot = "invalid" }
    }
    $repositories = @()
    foreach ($entry in @(
        [pscustomobject]@{ role = "master"; root = $projectRoot },
        [pscustomobject]@{ role = "develop"; root = $developRoot }
    )) {
        $head = "unavailable"; $trackedStatus = "unavailable"
        if ([string]$entry.root -and [string]$entry.root -ne "invalid" -and (Test-Path -LiteralPath ([string]$entry.root) -PathType Container)) {
            $headResult = Invoke-RepositoryGit -RepositoryRoot ([string]$entry.root) -Arguments @("rev-parse", "HEAD") -AllowFailure
            $statusResult = Invoke-RepositoryGit -RepositoryRoot ([string]$entry.root) -Arguments @("status", "--porcelain", "--untracked-files=no") -AllowFailure
            if ($headResult.exitCode -eq 0) { $head = $headResult.stdout.Trim() }
            if ($statusResult.exitCode -eq 0) {
                $trackedStatusText = [string]$statusResult.stdout
                $trackedStatus = if ($trackedStatusText.Length -eq 0) { "clean" } else { Get-DeliveryTextSha256 -Text $trackedStatusText }
            }
        }
        $repositories += [ordered]@{ role = [string]$entry.role; root = ([string]$entry.root).ToLowerInvariant(); head = $head; trackedStatusSha256 = $trackedStatus }
    }
    $identity = [ordered]@{
        schemaVersion = 1
        projectRoot = $projectRoot.ToLowerInvariant()
        projectConfig = Get-DeliveryFileIdentity -Path (Join-Path $projectRoot ".agent-1c\project.json")
        standConfig = Get-DeliveryFileIdentity -Path $standConfigPath
        devEnv = Get-DeliveryFileIdentity -Path (Join-Path $projectRoot ".dev.env")
        repositories = $repositories
    }
    return Get-DeliveryTextSha256 -Text ($identity | ConvertTo-Json -Depth 8 -Compress)
}

function Get-DeliveryComponentFinalizerIdentity {
    $path = if ($script:ComponentFinalizerScript) { $script:ComponentFinalizerScript } else { Join-Path $script:Root "scripts\source-delivery-component.ps1" }
    return Get-DeliveryFileIdentity -Path $path
}

function Get-DeliveryCompatibilityPromoterIdentity {
    return Get-DeliveryFileIdentity -Path $script:CompatibilityPromoterScript
}

function Get-DependencyLockInstallability {
    param([AllowNull()][object]$Lock)

    if (-not $Lock) { return [pscustomobject]@{ installable = $true; aiRulesStatus = "not-applicable"; aiRulesRef = ""; blockers = @() } }
    $lock = $Lock
    $dependencies = $lock.dependencies
    if (-not $dependencies) { throw "Candidate dependency lock does not contain dependencies." }
    $blockers = @()
    foreach ($property in @($dependencies.PSObject.Properties)) {
        $statusProperty = $property.Value.PSObject.Properties["compatibilityStatus"]
        if (-not $statusProperty) { continue }
        $status = [string]$statusProperty.Value
        if ($status -cne "passed") {
            $blockers += [pscustomobject]@{ name = [string]$property.Name; status = $status }
        }
    }
    $aiRulesProperty = $dependencies.PSObject.Properties["aiRules1c"]
    $aiRules = if ($aiRulesProperty) { $aiRulesProperty.Value } else { $null }
    if ($aiRules -and -not $aiRules.PSObject.Properties["compatibilityStatus"]) {
        $blockers += [pscustomobject]@{ name = "aiRules1c"; status = "missing" }
    }
    $aiRulesStatus = if (-not $aiRules) { "not-applicable" } elseif ($aiRules.PSObject.Properties["compatibilityStatus"]) { [string]$aiRules.compatibilityStatus } else { "missing" }
    $aiRulesRef = if ($aiRules -and $aiRules.PSObject.Properties["ref"]) { [string]$aiRules.ref } else { "" }
    return [pscustomobject]@{
        installable = ($blockers.Count -eq 0)
        aiRulesStatus = $aiRulesStatus
        aiRulesRef = $aiRulesRef
        blockers = $blockers
    }
}

function Get-DevelopCandidateInstallability {
    param([Parameter(Mandatory = $true)][string]$CandidateRoot)

    $lockPath = Join-Path $CandidateRoot "templates\dependency-lock.json"
    if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) { return Get-DependencyLockInstallability -Lock $null }
    return Get-DependencyLockInstallability -Lock (Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Get-DevelopCommitInstallability {
    param([Parameter(Mandatory = $true)][string]$Commit)

    $result = Invoke-DeliveryGit -Arguments @("show", "${Commit}:templates/dependency-lock.json") -AllowFailure
    if ($result.exitCode -ne 0) { return Get-DependencyLockInstallability -Lock $null }
    return Get-DependencyLockInstallability -Lock ($result.stdout | ConvertFrom-Json)
}

function Assert-DevelopCandidateInstallable {
    param([Parameter(Mandatory = $true)][string]$CandidateRoot)

    $state = Get-DevelopCandidateInstallability -CandidateRoot $CandidateRoot
    if (-not [bool]$state.installable) {
        $detail = @($state.blockers | ForEach-Object { "$([string]$_.name)=$([string]$_.status)" }) -join ", "
        throw "Develop candidate is not installable because required dependency compatibility is not passed: $detail. Nothing may be pushed."
    }
    return $state
}

function Get-DevelopPromotionRef {
    param([Parameter(Mandatory = $true)][string]$Identity)
    return "refs/itl/develop-promotions/$Identity"
}

function Remove-DevelopPromotionRef {
    param([AllowEmptyString()][string]$Ref)
    if ($Ref) { [void](Invoke-DeliveryGit -Arguments @("update-ref", "-d", $Ref) -AllowFailure) }
}

function Get-DevelopCompatibilityQualificationPath {
    param([Parameter(Mandatory = $true)][string]$Tree)
    if ($Tree -notmatch '^[a-f0-9]{40}$') { throw "Invalid candidate tree for compatibility qualification: $Tree" }
    return Join-Path (Get-DeliveryCommonGitDirectory) ("itl\compatibility-qualifications\$Tree\full.json")
}

function Save-DevelopCompatibilityQualification {
    param([Parameter(Mandatory = $true)][string]$CandidateRoot, [Parameter(Mandatory = $true)][string]$Tree)
    $source = Join-Path $CandidateRoot "build\test-results\qualification\full.json"
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Full gate did not create reusable qualification file 'full.json'." }
    $target = Get-DevelopCompatibilityQualificationPath -Tree $Tree
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
    $staging = "$target.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        Copy-Item -LiteralPath $source -Destination $staging -Force
        Move-Item -LiteralPath $staging -Destination $target -Force
    } finally {
        Remove-Item -LiteralPath $staging -Force -ErrorAction SilentlyContinue
    }
    return $target
}

function Restore-DevelopCompatibilityQualification {
    param([Parameter(Mandatory = $true)][string]$CandidateRoot, [Parameter(Mandatory = $true)][string]$Tree)
    $source = Get-DevelopCompatibilityQualificationPath -Tree $Tree
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { return $false }
    try {
        $qualification = Get-Content -LiteralPath $source -Raw -Encoding UTF8 | ConvertFrom-Json
        $head = (Invoke-WorktreeGit -Root $CandidateRoot -Arguments @("rev-parse", "HEAD")).stdout.Trim()
        if ([string]$qualification.kind -cne "itl-workflow-full-qualification" -or [string]$qualification.status -cne "passed" -or
            -not [bool]$qualification.reusable -or [string]$qualification.repository.commit -cne $head -or
            [string]$qualification.repository.tree -cne $Tree -or -not [bool]$qualification.repository.worktreeClean -or
            [int]$qualification.result.failed -ne 0 -or [int]$qualification.result.skipped -ne 0) { return $false }
    } catch { return $false }
    $targetRoot = Join-Path $CandidateRoot "build\test-results\qualification"
    New-Item -ItemType Directory -Force -Path $targetRoot | Out-Null
    Copy-Item -LiteralPath $source -Destination (Join-Path $targetRoot "full.json") -Force
    return $true
}

function Restore-DevelopCompatibilityPromotion {
    param(
        [Parameter(Mandatory = $true)][string]$CandidateRoot,
        [Parameter(Mandatory = $true)][object]$Attempt,
        [Parameter(Mandatory = $true)][string]$QueuedCandidate
    )
    if (-not ($Attempt.PSObject.Properties.Name -contains "promotionCommit") -or -not [string]$Attempt.promotionCommit) { return $false }
    $promotionCommit = [string]$Attempt.promotionCommit
    $promotionRef = [string]$Attempt.promotionRef
    if ($promotionCommit -notmatch '^[a-f0-9]{40}$' -or -not $promotionRef) { throw "Recorded ai_rules compatibility promotion is invalid." }
    $refCommit = (Invoke-DeliveryGit -Arguments @("rev-parse", "--verify", $promotionRef) -AllowFailure)
    if ($refCommit.exitCode -ne 0 -or $refCommit.stdout.Trim() -cne $promotionCommit) { throw "Recorded ai_rules compatibility promotion ref is missing or changed: $promotionRef" }
    if ((Invoke-WorktreeGit -Root $CandidateRoot -Arguments @("merge-base", "--is-ancestor", $QueuedCandidate, $promotionCommit) -AllowFailure).exitCode -ne 0) {
        throw "Recorded ai_rules compatibility promotion is not a descendant of the exact queued candidate."
    }
    $merge = Invoke-WorktreeGit -Root $CandidateRoot -Arguments @("merge", "--ff-only", $promotionCommit) -AllowFailure
    if ($merge.exitCode -ne 0) { throw "Unable to restore the recorded ai_rules compatibility promotion." }
    return $true
}

function Invoke-DevelopCompatibilityPromotion {
    param(
        [Parameter(Mandatory = $true)][string]$CandidateRoot,
        [Parameter(Mandatory = $true)][object]$Attempt,
        [Parameter(Mandatory = $true)][string]$QueuedCandidate,
        [Parameter(Mandatory = $true)][string]$QueuedTree,
        [Parameter(Mandatory = $true)][string]$RemoteBefore,
        [Parameter(Mandatory = $true)][DateTime]$OperationStartedAt
    )
    $state = Get-DevelopCandidateInstallability -CandidateRoot $CandidateRoot
    if ([bool]$state.installable) { return $false }
    $unsupported = @($state.blockers | Where-Object { [string]$_.name -cne "aiRules1c" -or [string]$_.status -cne "pending" })
    if ($unsupported.Count -gt 0 -or [string]$state.aiRulesStatus -cne "pending") {
        [void](Assert-DevelopCandidateInstallable -CandidateRoot $CandidateRoot)
    }
    if (-not (Test-Path -LiteralPath $script:CompatibilityPromoterScript -PathType Leaf)) {
        throw "ai_rules compatibility promoter is missing: $script:CompatibilityPromoterScript"
    }

    $compatibilityQualificationRestored = $false
    $recordedCompatibilityTree = if ($Attempt.PSObject.Properties.Name -contains "compatibilityQualifiedTree") { [string]$Attempt.compatibilityQualifiedTree } else { "" }
    $recordedCompatibilityEnvironment = if ($Attempt.PSObject.Properties.Name -contains "compatibilityEnvironmentIdentity") { [string]$Attempt.compatibilityEnvironmentIdentity } else { "" }
    if ($recordedCompatibilityTree -ceq $QueuedTree -and $recordedCompatibilityEnvironment -ceq (Get-DevelopPublicationEnvironmentIdentity)) {
        $compatibilityQualificationRestored = Restore-DevelopCompatibilityQualification -CandidateRoot $CandidateRoot -Tree $QueuedTree
    }
    if (-not $compatibilityQualificationRestored) {
        Assert-DevelopPublicationStageMayRun -Attempt $Attempt -Stage "compatibility-qualification"
        Assert-DevelopPublicationOperationBudget -StartedAt $OperationStartedAt -NextStage "ai_rules compatibility qualification"
        try {
            Invoke-SourceGate -Mode "Full" -WorkingRoot $CandidateRoot -TargetBaseRef $RemoteBefore
            [void](Save-DevelopCompatibilityQualification -CandidateRoot $CandidateRoot -Tree $QueuedTree)
            $Attempt | Add-Member -NotePropertyName compatibilityQualifiedTree -NotePropertyValue $QueuedTree -Force
            $Attempt | Add-Member -NotePropertyName compatibilityEnvironmentIdentity -NotePropertyValue (Get-DevelopPublicationEnvironmentIdentity) -Force
            Clear-DevelopPublicationStageFailure -Attempt $Attempt -Stage "compatibility-qualification"
            Write-DevelopPublicationAttempt -Attempt $Attempt
        } catch {
            Register-DevelopPublicationStageFailure -Attempt $Attempt -Stage "compatibility-qualification" -Message $_.Exception.Message
            throw
        }
    }

    Assert-DevelopPublicationStageMayRun -Attempt $Attempt -Stage "compatibility-promotion"
    try {
        $promotionOutput = @(& $script:CompatibilityPromoterScript -RepositoryRoot $CandidateRoot -QualificationPath (Join-Path $CandidateRoot "build\test-results\qualification\full.json") 6>&1)
        $status = Invoke-WorktreeGit -Root $CandidateRoot -Arguments @("status", "--porcelain", "--untracked-files=no")
        $unexpected = @($status.stdout -split "`r?`n" | Where-Object { $_ -and $_ -notmatch '^ M templates/dependency-lock\.json$' })
        if ($unexpected.Count -gt 0) { throw "ai_rules compatibility promotion changed unexpected tracked paths: $($unexpected -join ', ')" }
        [void](Invoke-WorktreeGit -Root $CandidateRoot -Arguments @("add", "--", "templates/dependency-lock.json"))
        $revision = [int]((Get-Content -LiteralPath (Join-Path $CandidateRoot "templates\dependency-lock.json") -Raw -Encoding UTF8 | ConvertFrom-Json).dependencies.aiRules1c.downstreamRevision)
        $commit = Invoke-WorktreeGit -Root $CandidateRoot -Arguments @("commit", "-m", "chore: promote ai rules r$revision compatibility") -AllowFailure
        if ($commit.exitCode -ne 0) { throw "Unable to commit the ai_rules compatibility promotion." }
        $promotionCommit = (Invoke-WorktreeGit -Root $CandidateRoot -Arguments @("rev-parse", "HEAD")).stdout.Trim()
        $promotionTree = (Invoke-WorktreeGit -Root $CandidateRoot -Arguments @("rev-parse", "HEAD^{tree}")).stdout.Trim()
        $promotionRef = Get-DevelopPromotionRef -Identity ([string]$Attempt.identity)
        [void](Invoke-DeliveryGit -Arguments @("update-ref", $promotionRef, $promotionCommit))
        $Attempt | Add-Member -NotePropertyName promotionSourceCandidate -NotePropertyValue $QueuedCandidate -Force
        $Attempt | Add-Member -NotePropertyName promotionCommit -NotePropertyValue $promotionCommit -Force
        $Attempt | Add-Member -NotePropertyName promotionRef -NotePropertyValue $promotionRef -Force
        $Attempt | Add-Member -NotePropertyName compatibilityPromoterIdentity -NotePropertyValue (Get-DeliveryCompatibilityPromoterIdentity) -Force
        $Attempt.candidate = $promotionCommit
        $Attempt.tree = $promotionTree
        $Attempt.phase = "candidate-built"
        Clear-DevelopPublicationStageFailure -Attempt $Attempt -Stage "compatibility-promotion"
        Write-DevelopPublicationAttempt -Attempt $Attempt
        [void](Assert-DevelopCandidateInstallable -CandidateRoot $CandidateRoot)
        return $true
    } catch {
        Register-DevelopPublicationStageFailure -Attempt $Attempt -Stage "compatibility-promotion" -Message $_.Exception.Message
        throw
    }
}

function Get-DevelopPublicationIdentity {
    param(
        [Parameter(Mandatory = $true)][string]$RemoteBefore,
        [Parameter(Mandatory = $true)][object[]]$Entries,
        [Parameter(Mandatory = $true)][string]$Candidate,
        [Parameter(Mandatory = $true)][string]$Tree
    )
    $queue = @($Entries | ForEach-Object { "$([string]$_.id)|$([string]$_.base)|$([string]$_.head)" }) -join "`n"
    $gateIdentity = Get-DeliveryFileIdentity -Path $script:GateScript
    $promoterIdentity = Get-DeliveryCompatibilityPromoterIdentity
    return Get-DeliveryTextSha256 -Text (@(
        "remote=$($script:Remote)", "remoteBefore=$RemoteBefore", "candidate=$Candidate", "tree=$Tree",
        "requireRelease=$([bool]$RequireRelease)", "gate=$gateIdentity", "promoter=$promoterIdentity", "queue=$queue"
    ) -join "`n")
}

function Read-DevelopPublicationAttempt {
    $path = Get-DevelopPublicationAttemptPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try {
        $attempt = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([int]$attempt.schemaVersion -ne 1) { return $null }
        return $attempt
    } catch { return $null }
}

function Write-DevelopPublicationAttempt {
    param([Parameter(Mandatory = $true)][object]$Attempt)
    $target = Get-DevelopPublicationAttemptPath
    $parent = Split-Path -Parent $target
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $Attempt.updatedAt = [DateTime]::UtcNow.ToString("o")
    $temp = Join-Path $parent ("develop." + [guid]::NewGuid().ToString("N") + ".tmp")
    [IO.File]::WriteAllText($temp, (($Attempt | ConvertTo-Json -Depth 12) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temp -Destination $target -Force
}

function Remove-DevelopPublicationAttempt {
    Remove-Item -LiteralPath (Get-DevelopPublicationAttemptPath) -Force -ErrorAction SilentlyContinue
}

function Get-DevelopPublicationPhaseRank {
    param([AllowEmptyString()][string]$Phase)
    switch ($Phase) {
        "candidate-built" { return 0 }
        "develop-qualified" { return 1 }
        "release-qualified" { return 2 }
        "component-finalized" { return 3 }
        "remote-pushed" { return 4 }
        default { return -1 }
    }
}

function Set-DevelopPublicationPhase {
    param([Parameter(Mandatory = $true)][object]$Attempt, [Parameter(Mandatory = $true)][string]$Phase)
    $Attempt.phase = $Phase
    Write-DevelopPublicationAttempt -Attempt $Attempt
}

function Clear-DevelopPublicationStageFailure {
    param([Parameter(Mandatory = $true)][object]$Attempt, [Parameter(Mandatory = $true)][string]$Stage)
    $Attempt.failures = @($Attempt.failures | Where-Object { [string]$_.stage -ne $Stage })
    Write-DevelopPublicationAttempt -Attempt $Attempt
}

function Register-DevelopPublicationStageFailure {
    param(
        [Parameter(Mandatory = $true)][object]$Attempt,
        [Parameter(Mandatory = $true)][string]$Stage,
        [Parameter(Mandatory = $true)][string]$Message
    )
    # Candidate worktree names are intentionally random on every retry. Remove
    # that run-local token so the same owning failure opens the circuit breaker.
    $normalizedMessage = $Message.Trim() -replace '(?i)itl-source-publish-develop-[a-f0-9]{32}', 'itl-source-publish-develop-<attempt>'
    $signature = Get-DeliveryTextSha256 -Text $normalizedMessage
    $failures = @($Attempt.failures)
    $existing = $failures | Where-Object { [string]$_.stage -eq $Stage -and [string]$_.signature -eq $signature } | Select-Object -First 1
    if ($existing) {
        $existing.count = [int]$existing.count + 1
        $existing.lastFailedAt = [DateTime]::UtcNow.ToString("o")
    } else {
        $failures += [pscustomobject]@{ stage = $Stage; signature = $signature; count = 1; lastFailedAt = [DateTime]::UtcNow.ToString("o"); message = $Message }
    }
    $Attempt.failures = $failures
    Write-DevelopPublicationAttempt -Attempt $Attempt
}

function Assert-DevelopPublicationStageMayRun {
    param([Parameter(Mandatory = $true)][object]$Attempt, [Parameter(Mandatory = $true)][string]$Stage)
    $blocked = @($Attempt.failures | Where-Object { [string]$_.stage -eq $Stage -and [int]$_.count -ge 2 } | Sort-Object lastFailedAt -Descending | Select-Object -First 1)
    if ($blocked.Count -eq 0) { return }
    if ($RetryBlockedStage) {
        Clear-DevelopPublicationStageFailure -Attempt $Attempt -Stage $Stage
        return
    }
    throw "Publication stage '$Stage' produced the same failure twice for this exact candidate. Automatic retry is blocked. Fix or inspect the owner first; pass -RetryBlockedStage only for an explicit supervised retry. Last error: $([string]$blocked[0].message)"
}

function Assert-DevelopPublicationOperationBudget {
    param([Parameter(Mandatory = $true)][datetime]$StartedAt, [Parameter(Mandatory = $true)][string]$NextStage)
    $elapsed = ([DateTime]::UtcNow - $StartedAt).TotalMinutes
    if ($elapsed -ge 60) {
        throw "Publication operation reached the 60 minute wall-clock budget before '$NextStage'. The durable checkpoint is preserved; continue PublishDevelop to resume from that stage without repeating passed broad gates."
    }
}

function New-DevelopPublicationAttempt {
    param(
        [Parameter(Mandatory = $true)][string]$Identity,
        [Parameter(Mandatory = $true)][string]$RemoteBefore,
        [Parameter(Mandatory = $true)][object[]]$Entries,
        [Parameter(Mandatory = $true)][string]$Candidate,
        [Parameter(Mandatory = $true)][string]$Tree,
        [AllowNull()][object]$ComponentPlan
    )
    $now = [DateTime]::UtcNow.ToString("o")
    $attempt = [pscustomobject]@{
        schemaVersion = 1; identity = $Identity; remote = $script:Remote; remoteBefore = $RemoteBefore
        candidate = $Candidate; tree = $Tree; requireRelease = [bool]$RequireRelease; phase = "candidate-built"
        gateIdentity = (Get-DeliveryFileIdentity -Path $script:GateScript)
        componentFinalizerIdentity = (Get-DeliveryComponentFinalizerIdentity)
        compatibilityPromoterIdentity = (Get-DeliveryCompatibilityPromoterIdentity)
        queue = @($Entries | ForEach-Object { [pscustomobject]@{ id = [string]$_.id; base = [string]$_.base; head = [string]$_.head } })
        componentPlan = $ComponentPlan; componentPublication = $null; failures = @(); startedAt = $now; updatedAt = $now
    }
    Write-DevelopPublicationAttempt -Attempt $attempt
    return $attempt
}

function Restore-PriorDevelopPublicationQualification {
    param(
        [Parameter(Mandatory = $true)][string]$CandidateRoot,
        [AllowNull()][object]$PriorAttempt,
        [Parameter(Mandatory = $true)][string]$Candidate,
        [Parameter(Mandatory = $true)][string]$Tree
    )
    if (-not $PriorAttempt -or (Get-DevelopPublicationPhaseRank -Phase ([string]$PriorAttempt.phase)) -lt 1) { return $false }
    $qualifiedCommit = [string]$PriorAttempt.candidate
    $qualifiedTree = [string]$PriorAttempt.tree
    if ($qualifiedCommit -notmatch '^[a-f0-9]{40}$' -or $qualifiedTree -notmatch '^[a-f0-9]{40}$') { return $false }
    try {
        $continuation = Get-WorkflowContinuationProof -RepositoryRoot $CandidateRoot -QualifiedCommit $qualifiedCommit -CurrentCommit $Candidate -CurrentTree $Tree
        if (-not $continuation -or @($continuation.scopes) -contains "develop") { return $false }
        return Restore-DeliveryQualification -CandidateRoot $CandidateRoot -Tree $qualifiedTree
    } catch { return $false }
}

function Test-ExactPassedDeliveryRun {
    param(
        [Parameter(Mandatory = $true)][ValidateSet("Develop", "Release")][string]$Mode,
        [Parameter(Mandatory = $true)][string]$Candidate,
        [Parameter(Mandatory = $true)][string]$Tree,
        [Parameter(Mandatory = $true)][DateTime]$NotBefore
    )
    $runRoot = Join-Path (Get-DeliveryCommonGitDirectory) "itl\runs"
    if (-not (Test-Path -LiteralPath $runRoot -PathType Container)) { return $false }
    foreach ($file in @(Get-ChildItem -LiteralPath $runRoot -File -Filter "*.json" | Sort-Object Name -Descending)) {
        try {
            $run = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([string]$run.mode -cne $Mode -or [string]$run.status -cne "passed" -or [int]$run.exitCode -ne 0) { continue }
            if ([string]$run.commit -cne $Candidate -or [string]$run.tree -cne $Tree) { continue }
            if ((ConvertTo-DeliveryUtcDateTime -Value $run.startedAt) -lt $NotBefore.ToUniversalTime()) { continue }
            return $true
        } catch { continue }
    }
    return $false
}

function Complete-InterruptedDevelopPublication {
    param([Parameter(Mandatory = $true)][string]$RemoteBefore, [Parameter(Mandatory = $true)][object[]]$Entries)
    $attempt = Read-DevelopPublicationAttempt
    if (-not $attempt -or (Get-DevelopPublicationPhaseRank -Phase ([string]$attempt.phase)) -lt 3 -or
        [string]$attempt.candidate -ne $RemoteBefore) { return $null }
    foreach ($entry in @($Entries)) {
        if ((Invoke-DeliveryGit -Arguments @("merge-base", "--is-ancestor", [string]$entry.head, $RemoteBefore) -AllowFailure).exitCode -ne 0) { return $null }
    }
    $remoteTree = Get-GitValue -Arguments @("rev-parse", "$RemoteBefore^{tree}")
    if ($remoteTree -ne [string]$attempt.tree) { return $null }
    $installability = Get-DevelopCommitInstallability -Commit $RemoteBefore
    if (-not [bool]$installability.installable) { throw "Published develop is not installable; recovery will not report success." }
    Clear-PublishedQueueEntries -PublishedCommit $RemoteBefore
    Sync-LocalDevelopAfterPublish
    if ($attempt.PSObject.Properties.Name -contains "promotionRef") { Remove-DevelopPromotionRef -Ref ([string]$attempt.promotionRef) }
    Remove-DevelopPublicationAttempt
    return [pscustomobject]@{
        status = "published"; branch = "develop"; commit = $RemoteBefore; tree = $remoteTree
        developPublished = $true; dependenciesInstallable = $true; masterReleased = $false
        aiRulesCompatibility = [string]$installability.aiRulesStatus
        releaseQualified = [bool]$attempt.requireRelease; componentPublication = $attempt.componentPublication; recovered = $true
    }
}

function Publish-AccumulatedDevelop {
    $operationStartedAt = [DateTime]::UtcNow
    Assert-CleanDeliveryWorktree
    [void](Invoke-DeliveryGit -Arguments @("fetch", $script:Remote, "develop"))
    $remoteBefore = Get-GitValue -Arguments @("rev-parse", "$script:Remote/develop")
    $entries = @(Get-QueueEntries)
    if ($entries.Count -eq 0) { throw "There are no registered develop changes to publish." }
    $interrupted = Complete-InterruptedDevelopPublication -RemoteBefore $remoteBefore -Entries $entries
    if ($interrupted) { return $interrupted }

    $worktree = $null
    $deliverySucceeded = $false
    try {
        $worktree = New-DeliveryWorktree -StartPoint "$script:Remote/develop" -Purpose "publish-develop"
        Add-QueuedRangesToCandidate -CandidateRoot $worktree.path -Entries $entries
        $queuedTree = (Invoke-WorktreeGit -Root $worktree.path -Arguments @("rev-parse", "HEAD^{tree}")).stdout.Trim()
        $queuedCandidate = (Invoke-WorktreeGit -Root $worktree.path -Arguments @("rev-parse", "HEAD")).stdout.Trim()
        $attemptIdentity = Get-DevelopPublicationIdentity -RemoteBefore $remoteBefore -Entries $entries -Candidate $queuedCandidate -Tree $queuedTree
        $attempt = Read-DevelopPublicationAttempt
        $priorAttempt = $attempt
        if ($attempt -and [string]$attempt.identity -ne $attemptIdentity -and $attempt.PSObject.Properties.Name -contains "promotionRef") {
            Remove-DevelopPromotionRef -Ref ([string]$attempt.promotionRef)
        }
        $promotionRestored = $false
        if ($attempt -and [string]$attempt.identity -eq $attemptIdentity) {
            $promotionRestored = Restore-DevelopCompatibilityPromotion -CandidateRoot $worktree.path -Attempt $attempt -QueuedCandidate $queuedCandidate
        }
        $candidateTree = (Invoke-WorktreeGit -Root $worktree.path -Arguments @("rev-parse", "HEAD^{tree}")).stdout.Trim()
        $candidate = (Invoke-WorktreeGit -Root $worktree.path -Arguments @("rev-parse", "HEAD")).stdout.Trim()
        $componentPlan = Get-OwnedComponentPublicationPlan -CandidateRoot $worktree.path -CandidateCommit $candidate
        if ([bool]$componentPlan.requiresRelease -and -not [bool]$RequireRelease) {
            Write-Host "Owned component publication requires exact-candidate Release qualification; PublishDevelop promoted itself to Develop + Release."
        }
        $RequireRelease = [bool]($RequireRelease -or [bool]$componentPlan.requiresRelease)
        if (-not $attempt -or [string]$attempt.identity -ne $attemptIdentity) {
            $attempt = New-DevelopPublicationAttempt -Identity $attemptIdentity -RemoteBefore $remoteBefore -Entries $entries -Candidate $candidate -Tree $candidateTree -ComponentPlan $componentPlan
        } elseif ($attempt.PSObject.Properties.Name -contains "componentPlan") {
            $attempt.componentPlan = $componentPlan
        } else {
            $attempt | Add-Member -NotePropertyName componentPlan -NotePropertyValue $componentPlan
        }
        $attempt.candidate = $candidate
        $attempt.tree = $candidateTree
        Write-DevelopPublicationAttempt -Attempt $attempt

        $prePromotionInstallability = Get-DevelopCandidateInstallability -CandidateRoot $worktree.path
        if (-not $promotionRestored -and [string]$prePromotionInstallability.aiRulesStatus -eq "pending") {
            [void](Invoke-DevelopCompatibilityPromotion -CandidateRoot $worktree.path -Attempt $attempt -QueuedCandidate $queuedCandidate -QueuedTree $queuedTree -RemoteBefore $remoteBefore -OperationStartedAt $operationStartedAt)
            $candidateTree = (Invoke-WorktreeGit -Root $worktree.path -Arguments @("rev-parse", "HEAD^{tree}")).stdout.Trim()
            $candidate = (Invoke-WorktreeGit -Root $worktree.path -Arguments @("rev-parse", "HEAD")).stdout.Trim()
            $componentPlan = Get-OwnedComponentPublicationPlan -CandidateRoot $worktree.path -CandidateCommit $candidate
            $attempt.componentPlan = $componentPlan
            $attempt.candidate = $candidate
            $attempt.tree = $candidateTree
            Write-DevelopPublicationAttempt -Attempt $attempt
        }
        [void](Assert-DevelopCandidateInstallable -CandidateRoot $worktree.path)
        $developEnvironmentIdentity = Get-DevelopPublicationEnvironmentIdentity
        $exactDevelopQualificationRestored = Restore-DeliveryQualification -CandidateRoot $worktree.path -Tree $candidateTree
        if (-not $exactDevelopQualificationRestored) {
            $priorQualificationRestored = Restore-PriorDevelopPublicationQualification -CandidateRoot $worktree.path -PriorAttempt $priorAttempt -Candidate $candidate -Tree $candidateTree
            if (-not $priorQualificationRestored) {
                $baselineTree = (Invoke-WorktreeGit -Root $worktree.path -Arguments @("rev-parse", "$remoteBefore^{tree}")).stdout.Trim()
                [void](Restore-DeliveryQualification -CandidateRoot $worktree.path -Tree $baselineTree)
            }
        }
        if ((Get-DevelopPublicationPhaseRank -Phase ([string]$attempt.phase)) -ge 1 -and -not $exactDevelopQualificationRestored) {
            Set-DevelopPublicationPhase -Attempt $attempt -Phase "candidate-built"
        }
        if ($RequireRelease -and (Get-DevelopPublicationPhaseRank -Phase ([string]$attempt.phase)) -lt 2 -and
            $exactDevelopQualificationRestored -and
            (Test-ExactPassedDeliveryRun -Mode "Release" -Candidate $candidate -Tree $candidateTree -NotBefore (ConvertTo-DeliveryUtcDateTime -Value $attempt.startedAt))) {
            Clear-DevelopPublicationStageFailure -Attempt $attempt -Stage "Release"
            Set-DevelopPublicationPhase -Attempt $attempt -Phase "release-qualified"
        }
        $recordedDevelopEnvironmentIdentity = if ($attempt.PSObject.Properties.Name -contains "developEnvironmentIdentity") { [string]$attempt.developEnvironmentIdentity } else { "" }
        if ((Get-DevelopPublicationPhaseRank -Phase ([string]$attempt.phase)) -eq 1 -and $recordedDevelopEnvironmentIdentity -ne $developEnvironmentIdentity) {
            Clear-DevelopPublicationStageFailure -Attempt $attempt -Stage "Release"
            Set-DevelopPublicationPhase -Attempt $attempt -Phase "candidate-built"
        }
        if ((Get-DevelopPublicationPhaseRank -Phase ([string]$attempt.phase)) -lt 1) {
            Assert-DevelopPublicationStageMayRun -Attempt $attempt -Stage "Develop"
            Assert-DevelopPublicationOperationBudget -StartedAt $operationStartedAt -NextStage "Develop"
            try {
                Invoke-SourceGate -Mode "Develop" -WorkingRoot $worktree.path -TargetBaseRef $remoteBefore
                [void](Save-DeliveryQualification -CandidateRoot $worktree.path -Tree $candidateTree)
                $attempt | Add-Member -NotePropertyName developEnvironmentIdentity -NotePropertyValue (Get-DevelopPublicationEnvironmentIdentity) -Force
                Write-DevelopPublicationAttempt -Attempt $attempt
                Clear-DevelopPublicationStageFailure -Attempt $attempt -Stage "Develop"
                Set-DevelopPublicationPhase -Attempt $attempt -Phase "develop-qualified"
            } catch {
                Register-DevelopPublicationStageFailure -Attempt $attempt -Stage "Develop" -Message $_.Exception.Message
                throw
            }
        }
        if ($RequireRelease -and (Get-DevelopPublicationPhaseRank -Phase ([string]$attempt.phase)) -lt 2) {
            Assert-DevelopPublicationStageMayRun -Attempt $attempt -Stage "Release"
            Assert-DevelopPublicationOperationBudget -StartedAt $operationStartedAt -NextStage "Release"
            try {
                Invoke-SourceGate -Mode "Release" -WorkingRoot $worktree.path
                [void](Save-DeliveryQualification -CandidateRoot $worktree.path -Tree $candidateTree)
                Clear-DevelopPublicationStageFailure -Attempt $attempt -Stage "Release"
                Set-DevelopPublicationPhase -Attempt $attempt -Phase "release-qualified"
            } catch {
                Register-DevelopPublicationStageFailure -Attempt $attempt -Stage "Release" -Message $_.Exception.Message
                throw
            }
        }

        $currentFinalizerIdentity = Get-DeliveryComponentFinalizerIdentity
        if ((Get-DevelopPublicationPhaseRank -Phase ([string]$attempt.phase)) -ge 3 -and [string]$attempt.componentFinalizerIdentity -ne $currentFinalizerIdentity) {
            $attempt.componentFinalizerIdentity = $currentFinalizerIdentity
            $attempt.componentPublication = $null
            Set-DevelopPublicationPhase -Attempt $attempt -Phase $(if ($RequireRelease) { "release-qualified" } else { "develop-qualified" })
        }
        $componentPublication = $attempt.componentPublication
        if ((Get-DevelopPublicationPhaseRank -Phase ([string]$attempt.phase)) -lt 3) {
            Assert-DevelopPublicationStageMayRun -Attempt $attempt -Stage "component-finalizer"
            try {
                $componentPublication = Invoke-ComponentPublicationFinalizer -CandidateRoot $worktree.path -CandidateCommit $candidate
                $attempt.componentPublication = $componentPublication
                Clear-DevelopPublicationStageFailure -Attempt $attempt -Stage "component-finalizer"
                Set-DevelopPublicationPhase -Attempt $attempt -Phase "component-finalized"
            } catch {
                Register-DevelopPublicationStageFailure -Attempt $attempt -Stage "component-finalizer" -Message $_.Exception.Message
                throw
            }
        }
        $installability = Assert-DevelopCandidateInstallable -CandidateRoot $worktree.path
        Assert-DevelopPublicationStageMayRun -Attempt $attempt -Stage "push"
        try {
            $push = Invoke-WorktreeGit -Root $worktree.path -Arguments @("push", $script:Remote, "HEAD:refs/heads/develop") -AllowFailure
            if ($push.exitCode -ne 0) { throw "origin/develop changed or rejected the fast-forward push. The queue is preserved; rebuild the candidate from the new remote head." }
            Clear-DevelopPublicationStageFailure -Attempt $attempt -Stage "push"
            Set-DevelopPublicationPhase -Attempt $attempt -Phase "remote-pushed"
        } catch {
            Register-DevelopPublicationStageFailure -Attempt $attempt -Stage "push" -Message $_.Exception.Message
            throw
        }
        $remoteAfter = (Invoke-WorktreeGit -Root $worktree.path -Arguments @("ls-remote", $script:Remote, "refs/heads/develop")).stdout.Split([char]9)[0].Trim()
        if ($remoteAfter -ne $candidate) { throw "Published develop verification failed: expected $candidate, remote reports $remoteAfter." }
        Clear-PublishedQueueEntries -PublishedCommit $candidate
        Sync-LocalDevelopAfterPublish
        if ($attempt.PSObject.Properties.Name -contains "promotionRef") { Remove-DevelopPromotionRef -Ref ([string]$attempt.promotionRef) }
        Remove-DevelopPublicationAttempt
        $deliverySucceeded = $true
        return [pscustomobject]@{
            status = "published"; branch = "develop"; commit = $candidate; tree = $candidateTree
            developPublished = $true; dependenciesInstallable = [bool]$installability.installable; masterReleased = $false
            aiRulesCompatibility = [string]$installability.aiRulesStatus
            releaseQualified = [bool]$RequireRelease; componentPublication = $componentPublication
        }
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

function Get-ReleaseRemoteCommit {
    param([string]$CandidateRoot, [string]$Branch)
    $remote = Invoke-WorktreeGit -Root $CandidateRoot -Arguments @("ls-remote", $script:Remote, "refs/heads/$Branch")
    $line = @($remote.stdout -split "`r?`n" | Where-Object { $_ })
    if ($line.Count -ne 1) { throw "Remote branch '$Branch' could not be resolved uniquely during release publication." }
    return ($line[0] -split "`t")[0].Trim()
}

function Get-ReleaseGitHubRepository {
    param([string]$CandidateRoot)
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { return "" }
    $remoteUrl = Invoke-WorktreeGit -Root $CandidateRoot -Arguments @("remote", "get-url", $script:Remote) -AllowFailure
    if ($remoteUrl.exitCode -ne 0 -or -not $remoteUrl.stdout.Trim()) { return "" }
    $repository = Invoke-DeliveryGitHubCli -Arguments @("repo", "view", $remoteUrl.stdout.Trim(), "--json", "nameWithOwner", "--jq", ".nameWithOwner") -AllowFailure
    if ($repository.exitCode -ne 0) { return "" }
    return $repository.text.Trim()
}

function Complete-ReleaseDevelopReconciliation {
    param(
        [string]$CandidateRoot,
        [string]$CandidateTree,
        [string]$ExpectedDevelop,
        [string]$MasterCommit
    )
    $currentDevelop = Get-ReleaseRemoteCommit -CandidateRoot $CandidateRoot -Branch "develop"
    if ($currentDevelop -ne $ExpectedDevelop) {
        throw "origin/develop moved during protected master publication. Master may already be released; rerun ReleaseMaster after inspecting the remote refs."
    }
    $masterAncestor = Invoke-WorktreeGit -Root $CandidateRoot -Arguments @("merge-base", "--is-ancestor", $MasterCommit, "HEAD") -AllowFailure
    if ($masterAncestor.exitCode -ne 0) {
        $merge = Invoke-WorktreeGit -Root $CandidateRoot -Arguments @("merge", "--no-ff", "--no-edit", $MasterCommit) -AllowFailure
        if ($merge.exitCode -ne 0) {
            [void](Invoke-WorktreeGit -Root $CandidateRoot -Arguments @("merge", "--abort") -AllowFailure)
            throw "Master was released at $MasterCommit, but develop could not reconcile that protected-branch commit. Rerun ReleaseMaster after diagnosis."
        }
    }
    $developCommit = (Invoke-WorktreeGit -Root $CandidateRoot -Arguments @("rev-parse", "HEAD")).stdout.Trim()
    $developTree = (Invoke-WorktreeGit -Root $CandidateRoot -Arguments @("rev-parse", "HEAD^{tree}")).stdout.Trim()
    if ($developTree -ne $CandidateTree) {
        throw "Protected master publication changed the qualified tree while reconciling develop. Nothing further was published."
    }
    $push = Invoke-WorktreeGit -Root $CandidateRoot -Arguments @("push", $script:Remote, "HEAD:refs/heads/develop") -AllowFailure
    if ($push.exitCode -ne 0) {
        throw "Master was released at $MasterCommit, but the develop reconciliation push was rejected. Rerun ReleaseMaster; no force push is permitted."
    }
    if ((Get-ReleaseRemoteCommit -CandidateRoot $CandidateRoot -Branch "develop") -ne $developCommit) {
        throw "Remote develop verification failed after protected master publication."
    }
    return $developCommit
}

function Publish-ReleaseThroughGitHubPullRequest {
    param(
        [string]$CandidateRoot,
        [string]$Repository,
        [string]$Candidate,
        [string]$CandidateTree,
        [string]$ExpectedDevelop,
        [string]$ExpectedMaster
    )
    [void](Invoke-WorktreeGit -Root $CandidateRoot -Arguments @("fetch", $script:Remote, "develop", "master"))
    if ((Get-ReleaseRemoteCommit -CandidateRoot $CandidateRoot -Branch "develop") -ne $ExpectedDevelop -or
        (Get-ReleaseRemoteCommit -CandidateRoot $CandidateRoot -Branch "master") -ne $ExpectedMaster) {
        throw "Remote develop or master moved before protected master publication. Nothing was published."
    }

    $masterCommit = $ExpectedMaster
    $masterTree = (Invoke-WorktreeGit -Root $CandidateRoot -Arguments @("rev-parse", "$masterCommit^{tree}")).stdout.Trim()
    $pullRequest = $null
    if ($masterTree -ne $CandidateTree) {
        $releaseBranch = "itl/release-master-" + $Candidate.Substring(0, 12)
        $remoteRelease = Invoke-WorktreeGit -Root $CandidateRoot -Arguments @("ls-remote", $script:Remote, "refs/heads/$releaseBranch") -AllowFailure
        $remoteReleaseCommit = if ($remoteRelease.stdout.Trim()) { (($remoteRelease.stdout.Trim() -split "`t")[0]).Trim() } else { "" }
        if ($remoteReleaseCommit -and $remoteReleaseCommit -ne $Candidate) {
            throw "Remote release branch '$releaseBranch' points to an unexpected commit. Nothing was published."
        }
        if (-not $remoteReleaseCommit) {
            [void](Invoke-WorktreeGit -Root $CandidateRoot -Arguments @("push", $script:Remote, "$Candidate`:refs/heads/$releaseBranch"))
        }

        $existing = Invoke-DeliveryGitHubCli -Arguments @("pr", "list", "--repo", $Repository, "--state", "open", "--base", "master", "--head", $releaseBranch, "--json", "number", "--jq", ".[0].number")
        $pullRequest = $existing.text.Trim()
        if (-not $pullRequest) {
            [void](Invoke-DeliveryGitHubCli -Arguments @("pr", "create", "--repo", $Repository, "--base", "master", "--head", $releaseBranch, "--title", "Release develop to master", "--body", "Automated ReleaseMaster promotion of qualified develop tree $CandidateTree."))
            $pullRequest = (Invoke-DeliveryGitHubCli -Arguments @("pr", "view", $releaseBranch, "--repo", $Repository, "--json", "number", "--jq", ".number")).text.Trim()
        }
        if (-not $pullRequest) { throw "GitHub did not return a pull request number for the protected master release." }
        $merged = Invoke-DeliveryGitHubCli -Arguments @("pr", "merge", $pullRequest, "--repo", $Repository, "--rebase", "--delete-branch") -AllowFailure
        if ($merged.exitCode -ne 0) {
            throw "Qualified release PR #$pullRequest could not be merged: $($merged.text)"
        }
        [void](Invoke-WorktreeGit -Root $CandidateRoot -Arguments @("fetch", $script:Remote, "develop", "master"))
        $masterCommit = Get-ReleaseRemoteCommit -CandidateRoot $CandidateRoot -Branch "master"
        if ((Invoke-WorktreeGit -Root $CandidateRoot -Arguments @("merge-base", "--is-ancestor", $ExpectedMaster, $masterCommit) -AllowFailure).exitCode -ne 0) {
            throw "Protected master publication did not fast-forward from the fetched master."
        }
        $masterTree = (Invoke-WorktreeGit -Root $CandidateRoot -Arguments @("rev-parse", "$masterCommit^{tree}")).stdout.Trim()
        if ($masterTree -ne $CandidateTree) {
            throw "Protected master publication produced a tree that differs from the qualified release candidate."
        }
    }

    $developCommit = Complete-ReleaseDevelopReconciliation -CandidateRoot $CandidateRoot -CandidateTree $CandidateTree -ExpectedDevelop $ExpectedDevelop -MasterCommit $masterCommit
    return [pscustomobject]@{
        mode = $(if ($pullRequest) { "github-pull-request" } else { "github-pull-request-recovery" })
        pullRequest = $pullRequest
        masterCommit = $masterCommit
        developCommit = $developCommit
    }
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
        $installability = Assert-DevelopCandidateInstallable -CandidateRoot $worktree.path
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
        $githubRepository = Get-ReleaseGitHubRepository -CandidateRoot $worktree.path
        if ($githubRepository) {
            $publication = Publish-ReleaseThroughGitHubPullRequest -CandidateRoot $worktree.path -Repository $githubRepository -Candidate $candidate -CandidateTree $candidateTree -ExpectedDevelop $remoteDevelop -ExpectedMaster $remoteMaster
        } else {
            $push = Invoke-WorktreeGit -Root $worktree.path -Arguments @("push", "--atomic", $script:Remote, "HEAD:refs/heads/develop", "HEAD:refs/heads/master") -AllowFailure
            if ($push.exitCode -ne 0) { throw "Release candidate passed, but the atomic develop/master fast-forward push was rejected. Neither branch was published and no force push was attempted." }
            $publication = [pscustomobject]@{ mode = "atomic-git"; pullRequest = $null; masterCommit = $candidate; developCommit = $candidate }
        }
        foreach ($branch in @("develop", "master")) {
            $remoteCommit = Get-ReleaseRemoteCommit -CandidateRoot $worktree.path -Branch $branch
            $expectedCommit = if ($branch -eq "develop") { $publication.developCommit } else { $publication.masterCommit }
            if ($remoteCommit -ne $expectedCommit) { throw "Remote $branch commit verification failed after release." }
            $remoteTree = (Invoke-WorktreeGit -Root $worktree.path -Arguments @("rev-parse", "$remoteCommit^{tree}")).stdout.Trim()
            if ($remoteTree -ne $candidateTree) { throw "Remote $branch tree verification failed after release." }
        }
        Publish-ReleaseVersion -Commit $publication.masterCommit
        Sync-LocalDevelopAfterPublish
        $deliverySucceeded = $true
        return [pscustomobject]@{
            status = "released"; commit = $publication.masterCommit; candidateCommit = $candidate; tree = $candidateTree; version = $Version
            publicationMode = $publication.mode; pullRequest = $publication.pullRequest
            developCommit = $publication.developCommit; masterCommit = $publication.masterCommit
            developPublished = $true; dependenciesInstallable = [bool]$installability.installable; masterReleased = $true
            aiRulesCompatibility = [string]$installability.aiRulesStatus
        }
    } finally {
        $customGate = $script:GateScript -ne (Join-Path $script:Root "scripts\check.ps1")
        if ($deliverySucceeded -or $customGate) { Remove-DeliveryWorktree -Worktree $worktree }
        elseif ($worktree) { Write-Warning "Release candidate was preserved for diagnosis and retry: $($worktree.path) (branch $($worktree.branch)). No force push was attempted." }
    }
}
