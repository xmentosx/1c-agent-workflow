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
