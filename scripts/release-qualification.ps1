function Get-WorkflowQualificationReuseKind {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][int]$SchemaVersion,
        [Parameter(Mandatory = $true)][string]$QualifiedCommit,
        [Parameter(Mandatory = $true)][string]$EvidenceCommit,
        [Parameter(Mandatory = $true)][string]$QualifiedTree,
        [Parameter(Mandatory = $true)][string]$CurrentCommit,
        [Parameter(Mandatory = $true)][string]$CurrentTree
    )
    if ($QualifiedTree -ne $CurrentTree) { return "" }
    if ($QualifiedCommit -eq $CurrentCommit) { return "exact-commit" }
    if ($SchemaVersion -lt 2) { return "" }
    & git -C $RepositoryRoot merge-base --is-ancestor $EvidenceCommit $CurrentCommit 2>$null
    if ($LASTEXITCODE -ne 0) { return "" }
    return "ancestor-same-tree"
}

function Get-CachedWorkflowQualificationReuseKind {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][int]$SchemaVersion,
        [Parameter(Mandatory = $true)][string]$QualifiedCommit,
        [Parameter(Mandatory = $true)][string]$EvidenceCommit,
        [Parameter(Mandatory = $true)][string]$QualifiedTree,
        [Parameter(Mandatory = $true)][string]$CurrentCommit,
        [Parameter(Mandatory = $true)][string]$CurrentTree
    )

    $strict = Get-WorkflowQualificationReuseKind @PSBoundParameters
    if ($strict) { return $strict }
    if ($QualifiedTree -eq $CurrentTree) { return "independent-exact-tree" }
    return ""
}

function Test-WorkflowContinuationPattern {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Pattern)

    $wildcard = [System.Management.Automation.WildcardPattern]::new(
        $Pattern.Replace('\', '/'),
        [System.Management.Automation.WildcardOptions]::IgnoreCase
    )
    return $wildcard.IsMatch($Path.Replace('\', '/'))
}

function Get-ExactTargetedRunProof {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$Commit,
        [Parameter(Mandatory = $true)][string]$Tree
    )

    if (-not (Get-Command Get-RepositoryCommonGitDirectory -ErrorAction SilentlyContinue)) {
        . (Join-Path $PSScriptRoot "git-path-list.ps1")
    }
    try { $commonGitPath = Get-RepositoryCommonGitDirectory -RepositoryRoot $RepositoryRoot } catch { return $null }
    $runRoot = Join-Path $commonGitPath "itl\runs"
    if (-not (Test-Path -LiteralPath $runRoot -PathType Container)) { return $null }

    foreach ($file in @(Get-ChildItem -LiteralPath $runRoot -File -Filter "*-targeted-*.json" | Sort-Object Name -Descending)) {
        try { $run = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
        if ([int]$run.schemaVersion -ne 1 -or [string]$run.mode -ne "Targeted" -or [string]$run.status -ne "passed" -or
            [int]$run.exitCode -ne 0 -or [string]$run.commit -ne $Commit -or [string]$run.tree -ne $Tree) { continue }
        $stageNames = @($run.stages | Where-Object { [string]$_.status -eq "passed" } | ForEach-Object { [string]$_.name })
        if ($stageNames -notcontains "pester" -or $stageNames -notcontains "tracked-state" -or $stageNames -notcontains "git-diff-check") { continue }
        return [pscustomobject]@{
            path = $file.FullName
            sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            run = $run
        }
    }
    return $null
}

function Get-SourceDeliveryCandidateIdentity {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$Commit
    )

    $parentResult = Invoke-RepositoryGit -RepositoryRoot $RepositoryRoot -Arguments @("rev-list", "--parents", "-n", "1", $Commit) -AllowFailure
    if ([int]$parentResult.exitCode -ne 0) { return $null }
    $parts = @($parentResult.stdout.Trim() -split '\s+' | Where-Object { $_ })
    if ($parts.Count -ne 3 -or $parts[0] -cne $Commit) { return $null }

    $subjectResult = Invoke-RepositoryGit -RepositoryRoot $RepositoryRoot -Arguments @("show", "-s", "--format=%s", $Commit) -AllowFailure
    if ([int]$subjectResult.exitCode -ne 0) { return $null }
    $subject = $subjectResult.stdout.Trim()
    if ($subject -notmatch "^Merge registered develop queue '(?<id>[^']+)' at (?<head>[a-f0-9]{40})$") { return $null }
    if ([string]$Matches.head -cne [string]$parts[2]) { return $null }
    $actualTree = Invoke-RepositoryGit -RepositoryRoot $RepositoryRoot -Arguments @("rev-parse", "$Commit^{tree}") -AllowFailure
    $mergeTree = Invoke-RepositoryGit -RepositoryRoot $RepositoryRoot -Arguments @("merge-tree", "--write-tree", [string]$parts[1], [string]$parts[2]) -AllowFailure
    if ([int]$actualTree.exitCode -ne 0 -or [int]$mergeTree.exitCode -ne 0 -or
        $actualTree.stdout.Trim() -cne $mergeTree.stdout.Trim()) { return $null }

    return [pscustomobject]@{
        commit = $parts[0]
        tree = $actualTree.stdout.Trim()
        base = $parts[1]
        queueHead = $parts[2]
        queueId = [string]$Matches.id
    }
}

function Get-WorkflowContinuationEndpoint {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$QualifiedCommit,
        [Parameter(Mandatory = $true)][string]$CurrentCommit,
        [Parameter(Mandatory = $true)][string]$CurrentTree
    )

    $actualTree = Invoke-RepositoryGit -RepositoryRoot $RepositoryRoot -Arguments @("rev-parse", "$CurrentCommit^{tree}") -AllowFailure
    if ([int]$actualTree.exitCode -ne 0 -or $actualTree.stdout.Trim() -cne $CurrentTree) { return $null }

    $ancestor = Invoke-RepositoryGit -RepositoryRoot $RepositoryRoot -Arguments @("merge-base", "--is-ancestor", $QualifiedCommit, $CurrentCommit) -AllowFailure
    if ([int]$ancestor.exitCode -eq 0) {
        return [pscustomobject]@{
            kind = "ancestor"
            targetedCommit = $CurrentCommit
            targetedTree = $CurrentTree
            sourceDeliveryBase = ""
            qualifiedQueueHead = ""
            currentQueueHead = ""
        }
    }

    $qualifiedCandidate = Get-SourceDeliveryCandidateIdentity -RepositoryRoot $RepositoryRoot -Commit $QualifiedCommit
    $currentCandidate = Get-SourceDeliveryCandidateIdentity -RepositoryRoot $RepositoryRoot -Commit $CurrentCommit
    if (-not $qualifiedCandidate -or -not $currentCandidate -or
        [string]$qualifiedCandidate.base -cne [string]$currentCandidate.base -or
        [string]$qualifiedCandidate.queueId -cne [string]$currentCandidate.queueId) { return $null }
    $queueAdvance = Invoke-RepositoryGit -RepositoryRoot $RepositoryRoot -Arguments @(
        "merge-base", "--is-ancestor", [string]$qualifiedCandidate.queueHead, [string]$currentCandidate.queueHead
    ) -AllowFailure
    if ([int]$queueAdvance.exitCode -ne 0) { return $null }
    $queueTree = Invoke-RepositoryGit -RepositoryRoot $RepositoryRoot -Arguments @("rev-parse", "$([string]$currentCandidate.queueHead)^{tree}") -AllowFailure
    if ([int]$queueTree.exitCode -ne 0) { return $null }

    return [pscustomobject]@{
        kind = "source-delivery-candidate"
        targetedCommit = [string]$currentCandidate.queueHead
        targetedTree = $queueTree.stdout.Trim()
        sourceDeliveryBase = [string]$currentCandidate.base
        qualifiedQueueHead = [string]$qualifiedCandidate.queueHead
        currentQueueHead = [string]$currentCandidate.queueHead
    }
}

function Get-WorkflowContinuationProof {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$QualifiedCommit,
        [Parameter(Mandatory = $true)][string]$CurrentCommit,
        [Parameter(Mandatory = $true)][string]$CurrentTree,
        [string]$CatalogPath = ""
    )

    if ($QualifiedCommit -notmatch '^[a-fA-F0-9]{40}$' -or $CurrentCommit -notmatch '^[a-fA-F0-9]{40}$' -or $CurrentTree -notmatch '^[a-fA-F0-9]{40}$') { return $null }
    if (-not (Get-Command Invoke-RepositoryGit -ErrorAction SilentlyContinue)) {
        . (Join-Path $PSScriptRoot "git-path-list.ps1")
    }
    $endpoint = Get-WorkflowContinuationEndpoint -RepositoryRoot $RepositoryRoot -QualifiedCommit $QualifiedCommit -CurrentCommit $CurrentCommit -CurrentTree $CurrentTree
    if (-not $endpoint) { return $null }
    if (-not $CatalogPath) { $CatalogPath = Join-Path $RepositoryRoot "tests\quality-contracts.json" }
    if (-not (Test-Path -LiteralPath $CatalogPath -PathType Leaf)) { return $null }
    try { $catalog = Get-Content -LiteralPath $CatalogPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
    if (-not $catalog.PSObject.Properties["continuationScopes"]) { return $null }

    $changedPaths = @(Get-RepositoryGitPathList -RepositoryRoot $RepositoryRoot -Arguments @("diff", "--name-only", "-z", $QualifiedCommit, $CurrentCommit, "--") | ForEach-Object { ([string]$_).Replace('\', '/') })
    if ($changedPaths.Count -eq 0) { return $null }
    $scopeNames = @($catalog.continuationScopes.PSObject.Properties | ForEach-Object { [string]$_.Name })
    $matchedScopes = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in $changedPaths) {
        $pathMatched = $false
        foreach ($scopeName in $scopeNames) {
            foreach ($pattern in @($catalog.continuationScopes.$scopeName)) {
                if (Test-WorkflowContinuationPattern -Path $path -Pattern ([string]$pattern)) {
                    [void]$matchedScopes.Add($scopeName)
                    $pathMatched = $true
                }
            }
        }
        if (-not $pathMatched) { return $null }
    }

    $targeted = Get-ExactTargetedRunProof -RepositoryRoot $RepositoryRoot -Commit ([string]$endpoint.targetedCommit) -Tree ([string]$endpoint.targetedTree)
    if (-not $targeted) { return $null }
    return [pscustomobject]@{
        qualifiedCommit = $QualifiedCommit
        currentCommit = $CurrentCommit
        currentTree = $CurrentTree
        proofKind = [string]$endpoint.kind
        targetedCommit = [string]$endpoint.targetedCommit
        targetedTree = [string]$endpoint.targetedTree
        sourceDeliveryBase = [string]$endpoint.sourceDeliveryBase
        qualifiedQueueHead = [string]$endpoint.qualifiedQueueHead
        currentQueueHead = [string]$endpoint.currentQueueHead
        paths = $changedPaths
        scopes = @($matchedScopes | Sort-Object)
        targetedRunPath = [string]$targeted.path
        targetedRunSha256 = [string]$targeted.sha256
        targetedFinishedAt = [string]$targeted.run.finishedAt
    }
}

function Test-RecordedWorkflowContinuation {
    param(
        [Parameter(Mandatory = $true)][object]$Record,
        [Parameter(Mandatory = $true)][string]$Commit,
        [Parameter(Mandatory = $true)][string]$Tree
    )

    try {
        $path = [string]$Record.targetedRunPath
        if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -ne ([string]$Record.targetedRunSha256).ToLowerInvariant()) { return $false }
        $run = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($Record.PSObject.Properties["currentCommit"] -and [string]$Record.currentCommit -cne $Commit) { return $false }
        if ($Record.PSObject.Properties["currentTree"] -and [string]$Record.currentTree -cne $Tree) { return $false }
        $targetedCommit = if ($Record.PSObject.Properties["targetedCommit"] -and [string]$Record.targetedCommit) { [string]$Record.targetedCommit } else { $Commit }
        $targetedTree = if ($Record.PSObject.Properties["targetedTree"] -and [string]$Record.targetedTree) { [string]$Record.targetedTree } else { $Tree }
        return [int]$run.schemaVersion -eq 1 -and [string]$run.mode -eq "Targeted" -and [string]$run.status -eq "passed" -and
            [int]$run.exitCode -eq 0 -and [string]$run.commit -eq $targetedCommit -and [string]$run.tree -eq $targetedTree
    } catch { return $false }
}
