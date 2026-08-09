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
    $ancestor = Invoke-RepositoryGit -RepositoryRoot $RepositoryRoot -Arguments @("merge-base", "--is-ancestor", $QualifiedCommit, $CurrentCommit) -AllowFailure
    if ([int]$ancestor.exitCode -ne 0) { return $null }
    if (-not $CatalogPath) { $CatalogPath = Join-Path $RepositoryRoot "tests\quality-contracts.json" }
    if (-not (Test-Path -LiteralPath $CatalogPath -PathType Leaf)) { return $null }
    try { $catalog = Get-Content -LiteralPath $CatalogPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
    if (-not $catalog.PSObject.Properties["continuationScopes"]) { return $null }

    $changedPaths = @(Get-RepositoryGitPathList -RepositoryRoot $RepositoryRoot -Arguments @("diff", "--name-only", "-z", "$QualifiedCommit...$CurrentCommit", "--") | ForEach-Object { ([string]$_).Replace('\', '/') })
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

    $targeted = Get-ExactTargetedRunProof -RepositoryRoot $RepositoryRoot -Commit $CurrentCommit -Tree $CurrentTree
    if (-not $targeted) { return $null }
    return [pscustomobject]@{
        qualifiedCommit = $QualifiedCommit
        currentCommit = $CurrentCommit
        currentTree = $CurrentTree
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
        return [int]$run.schemaVersion -eq 1 -and [string]$run.mode -eq "Targeted" -and [string]$run.status -eq "passed" -and
            [int]$run.exitCode -eq 0 -and [string]$run.commit -eq $Commit -and [string]$run.tree -eq $Tree
    } catch { return $false }
}
