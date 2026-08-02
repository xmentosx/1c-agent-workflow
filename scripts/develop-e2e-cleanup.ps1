Set-StrictMode -Version Latest

function Remove-DevelopE2EFreshProject {
    param([Parameter(Mandatory = $true)][string]$FreshProjectsRoot, [string]$Path, [string]$BranchPath = "")
    if (-not $Path) { return }
    $resolved = [IO.Path]::GetFullPath($Path)
    $allowed = [IO.Path]::GetFullPath($FreshProjectsRoot).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $resolved) -notlike "d-*") { throw "Refusing to remove unexpected fresh journey path: $resolved" }
    if ($BranchPath) {
        $branchResolved = [IO.Path]::GetFullPath($BranchPath)
        $expectedBranchLeaf = (Split-Path -Leaf $resolved) + "-*"
        if (-not $branchResolved.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $branchResolved) -notlike $expectedBranchLeaf) { throw "Refusing to remove unexpected fresh journey branch path: $branchResolved" }
        if ((Test-Path -LiteralPath $resolved -PathType Container) -and (Test-Path -LiteralPath $branchResolved -PathType Container)) {
            & git -C $resolved worktree remove --force $branchResolved
            if ($LASTEXITCODE -ne 0) { throw "Unable to remove fresh journey branch worktree: $branchResolved" }
        }
    }
    if (Test-Path -LiteralPath $resolved -PathType Container) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
