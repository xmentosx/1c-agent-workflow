[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$E2EProjectRoot,
    [Parameter(Mandatory = $true)][string]$FixtureWorktree,
    [Parameter(Mandatory = $true)][ValidatePattern('^[a-z0-9][a-z0-9-]{1,40}$')][string]$NewDevBranchName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'git-path-list.ps1')

function Get-StandGitValue {
    param([string]$Root, [string[]]$Arguments)
    return (Invoke-RepositoryGit -RepositoryRoot $Root -Arguments $Arguments).stdout.Trim()
}

function Assert-StandWorktreeOwned {
    param([string]$ProjectRoot, [string]$WorktreeRoot, [string]$ExpectedBranch)
    if (-not (Test-Path -LiteralPath $WorktreeRoot -PathType Container)) { throw "Release worktree is missing: $WorktreeRoot" }
    $projectGit = Get-RepositoryCommonGitDirectory -RepositoryRoot $ProjectRoot
    $worktreeGit = Get-RepositoryCommonGitDirectory -RepositoryRoot $WorktreeRoot
    if (-not [string]::Equals($projectGit, $worktreeGit, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Release worktree is not registered in the configured E2E project: $WorktreeRoot"
    }
    $branch = Get-StandGitValue -Root $WorktreeRoot -Arguments @('branch', '--show-current')
    if ($branch -cne $ExpectedBranch) { throw "Release worktree branch is '$branch'; expected '$ExpectedBranch'." }
}

function Get-StandWorktreeForBranch {
    param([string]$ProjectRoot, [string]$Branch)
    $records = @(Get-RepositoryGitPathList -RepositoryRoot $ProjectRoot -Arguments @('worktree', 'list', '--porcelain', '-z'))
    $path = ''; $matches = New-Object System.Collections.Generic.List[string]
    foreach ($field in $records) {
        if ($field.StartsWith('worktree ', [StringComparison]::Ordinal)) { $path = $field.Substring(9) }
        elseif ($field -ceq "branch refs/heads/$Branch" -and $path) { $matches.Add([IO.Path]::GetFullPath($path)) | Out-Null }
    }
    if ($matches.Count -ne 1) { throw "Fork did not register exactly one worktree for '$Branch'; found $($matches.Count). The stand config is unchanged." }
    return $matches[0]
}

$projectRoot = [IO.Path]::GetFullPath($E2EProjectRoot)
$fixtureRoot = [IO.Path]::GetFullPath($FixtureWorktree)
$configPath = Join-Path $projectRoot '.agent-1c\release-e2e.json'
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { throw "Release stand config is missing: $configPath" }
$configBytes = [IO.File]::ReadAllBytes($configPath)
try { $config = [Text.Encoding]::UTF8.GetString($configBytes) | ConvertFrom-Json } catch { throw "Release stand config is invalid: $configPath" }
$oldName = [string]$config.devBranchName
$oldRoot = [IO.Path]::GetFullPath([string]$config.worktreePath)
Assert-StandWorktreeOwned -ProjectRoot $projectRoot -WorktreeRoot $oldRoot -ExpectedBranch "itldev/$oldName"
$fixtureBranch = Get-StandGitValue -Root $fixtureRoot -Arguments @('branch', '--show-current')
if ($fixtureBranch -cnotmatch '^itldev/(?<name>.+)$') { throw 'Fixture source must be a development-branch worktree.' }
$fixtureName = [string]$Matches.name
Assert-StandWorktreeOwned -ProjectRoot $projectRoot -WorktreeRoot $fixtureRoot -ExpectedBranch $fixtureBranch
if ([string]::Equals($fixtureRoot, $oldRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The configured Release worktree cannot serve as its own recovery fixture.'
}
if ($NewDevBranchName -in @($oldName, $fixtureName)) { throw 'The new Release branch name must differ from the configured and fixture branches.' }
$fixtureStatus = (Invoke-RepositoryGit -RepositoryRoot $fixtureRoot -Arguments @('status', '--porcelain', '--untracked-files=all')).stdout
if ($fixtureStatus) { throw "Fixture worktree has changes: $fixtureRoot" }
$markerRelative = 'tests/features/workflow-release-e2e.feature'
$marker = Join-Path $fixtureRoot 'tests\features\workflow-release-e2e.feature'
if (-not (Test-Path -LiteralPath $marker -PathType Leaf) -or
    (Invoke-RepositoryGit -RepositoryRoot $fixtureRoot -Arguments @('ls-files', '--error-unmatch', '--', $markerRelative) -AllowFailure).exitCode -ne 0) {
    throw "Fixture source lacks the committed Release marker: $marker"
}
$safeRunName = ($fixtureName -replace '[^A-Za-z0-9_.-]', '_')
foreach ($checkpointPath in @(
    (Join-Path $fixtureRoot ".agent-1c\runs\release-e2e\$safeRunName\checkpoint.json"),
    (Join-Path $fixtureRoot ".agent-1c\release-e2e-runs\$safeRunName\checkpoint.json")
)) {
    if (Test-Path -LiteralPath $checkpointPath -PathType Leaf) {
        throw "Fixture source has a Release checkpoint and may contain mutated test data: $checkpointPath"
    }
}
$helper = Join-Path $fixtureRoot '.agents\skills\1c-workflow\scripts\run-itl-command.ps1'
if (-not (Test-Path -LiteralPath $helper -PathType Leaf)) { throw "Installed fork helper is missing: $helper" }

Push-Location $fixtureRoot
try {
    & $helper -- -Action fork-dev-branch -DevBranchName $NewDevBranchName
    if ($LASTEXITCODE -ne 0) { throw "fork-dev-branch failed for '$NewDevBranchName'. The Release stand config is unchanged; repeat the same command after diagnosis." }
} finally { Pop-Location }

$newBranch = "itldev/$NewDevBranchName"
$newRoot = Get-StandWorktreeForBranch -ProjectRoot $projectRoot -Branch $newBranch
Assert-StandWorktreeOwned -ProjectRoot $projectRoot -WorktreeRoot $newRoot -ExpectedBranch $newBranch
if ((Invoke-RepositoryGit -RepositoryRoot $newRoot -Arguments @('status', '--porcelain', '--untracked-files=all')).stdout) {
    throw "Forked Release worktree is dirty: $newRoot. The stand config is unchanged."
}
if (-not (Test-Path -LiteralPath (Join-Path $newRoot 'tests\features\workflow-release-e2e.feature') -PathType Leaf)) {
    throw "Forked Release worktree lacks the fixture marker: $newRoot. The stand config is unchanged."
}
$statePath = Join-Path $newRoot ".agent-1c\dev-branches\$NewDevBranchName.json"
if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { throw "Forked branch state is missing: $statePath" }
$state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $state.PSObject.Properties['unsafeActionProtectionConfirmed'] -or -not [bool]$state.unsafeActionProtectionConfirmed) {
    throw "Forked branch has no unsafe-action protection confirmation: $newRoot. The stand config is unchanged."
}
if (-not [Collections.StructuralComparisons]::StructuralEqualityComparer.Equals($configBytes, [IO.File]::ReadAllBytes($configPath))) {
    throw 'Release stand config changed during fork; refusing to overwrite it.'
}
$config.devBranchName = $NewDevBranchName
$config.worktreePath = $newRoot
$temporaryPath = Join-Path (Split-Path -Parent $configPath) ("release-e2e." + [guid]::NewGuid().ToString('N') + '.tmp')
$backupPath = Join-Path (Split-Path -Parent $configPath) ("release-e2e." + [guid]::NewGuid().ToString('N') + '.backup.json')
try {
    [IO.File]::WriteAllText($temporaryPath, (($config | ConvertTo-Json -Depth 16) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    [IO.File]::Replace($temporaryPath, $configPath, $backupPath)
} finally { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue }
[pscustomobject]@{
    status = 'recovered'; previousWorktree = $oldRoot; previousBranch = "itldev/$oldName"
    newWorktree = $newRoot; newBranch = $newBranch; configBackup = $backupPath
}
