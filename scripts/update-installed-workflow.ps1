[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ProjectRoot,
    [string]$SourceRoot = (Split-Path -Parent $PSScriptRoot),
    [ValidateSet('update', 'status', 'restore', 'reconcile', 'legacy-status', 'legacy-copy')][string]$Recovery = 'update',
    [string]$AgentTarget = '',
    [string]$LegacySourceRoot = '',
    [string]$SnapshotId = '',
    [string]$ReconciliationFile = '',
    [string]$WorkflowUpdateBranchRootsFile = '',
    [string]$DependencySelectionFile = '',
    [switch]$DependencyHotfixOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8

# The first upgrade from an installed old helper must enter the current helper
# before any managed path is copied. This launcher delegates the entire update
# to that owner; it never copies or repairs project files itself.
$source = [IO.Path]::GetFullPath($SourceRoot).TrimEnd('\', '/')
$project = [IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\', '/')
if ([string]::Equals($source, $project, [StringComparison]::OrdinalIgnoreCase) -or
    $source.StartsWith(($project + [IO.Path]::DirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase) -or
    $project.StartsWith(($source + [IO.Path]::DirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase)) {
    throw "ITL workflow source and installed project must be separate directories: source=$source project=$project"
}
if (-not (Test-Path -LiteralPath $project -PathType Container)) {
    throw "Installed project root was not found: $project"
}
$executor = $source
$sourceTemplate = Join-Path $source 'templates/dependency-lock.json'
if (Test-Path -LiteralPath $sourceTemplate -PathType Leaf) {
    $template = Get-Content -LiteralPath $sourceTemplate -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([int]$template.schemaVersion -eq 1 -and [string]$template.mode -in @('fresh','latest','locked','pinned')) {
        # SourceRoot still selects the exact payload. The current source-side
        # launcher owns its transition, including old-package branch rollout.
        $executor = Split-Path -Parent $PSScriptRoot
    }
}
$helper = Join-Path $executor '.agents\skills\1c-workflow\scripts\agent-1c.ps1'
if (-not (Test-Path -LiteralPath $helper -PathType Leaf)) {
    throw "Current ITL workflow helper was not found: $helper"
}
if (-not (Test-Path -LiteralPath (Join-Path $source '.git'))) {
    throw "First installed workflow upgrade requires an exact Git source checkout: $source"
}
$sourceGitRoot = (& git -C $source rev-parse --show-toplevel 2>$null)
if ($LASTEXITCODE -ne 0 -or
    -not [string]::Equals(([IO.Path]::GetFullPath(([string]$sourceGitRoot).Trim())).TrimEnd('\', '/'), $source, [StringComparison]::OrdinalIgnoreCase)) {
    throw "ITL workflow source is not the Git checkout root: $source"
}

$priorSource = $env:ITL_WORKFLOW_SOURCE_PATH
$priorCleanSource = $env:ITL_WORKFLOW_REQUIRE_CLEAN_SOURCE
try {
    $env:ITL_WORKFLOW_SOURCE_PATH = $source
    $env:ITL_WORKFLOW_REQUIRE_CLEAN_SOURCE = 'true'
    $global:LASTEXITCODE = 0
    $arguments = @{ ProjectRoot=$project; Action='update-workflow' }
    if ($AgentTarget) { $arguments.AgentTarget = $AgentTarget }
    if ($Recovery -ne 'update') { $arguments.WorkflowUpdateRecovery = $Recovery }
    if ($SnapshotId) { $arguments.WorkflowUpdateSnapshotId = $SnapshotId }
    if ($ReconciliationFile) { $arguments.WorkflowUpdateReconciliationFile = $ReconciliationFile }
    if ($WorkflowUpdateBranchRootsFile) { $arguments.WorkflowUpdateBranchRootsFile = [IO.Path]::GetFullPath($WorkflowUpdateBranchRootsFile) }
    if ($LegacySourceRoot) { $arguments.WorkflowUpdateLegacySourceRoot = $LegacySourceRoot }
    if ($DependencySelectionFile) { $arguments.DependencySelectionFile = [IO.Path]::GetFullPath($DependencySelectionFile) }
    if ($DependencyHotfixOnly) { $arguments.DependencyHotfixOnly = $true }
    & $helper @arguments
    if ($LASTEXITCODE -is [int] -and $LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
} finally {
    $env:ITL_WORKFLOW_SOURCE_PATH = $priorSource
    $env:ITL_WORKFLOW_REQUIRE_CLEAN_SOURCE = $priorCleanSource
}
