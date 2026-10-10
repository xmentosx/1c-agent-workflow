[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ProjectRoot,
    [string]$SourceRoot = (Split-Path -Parent $PSScriptRoot),
    [ValidateSet('update', 'status', 'restore', 'reconcile')][string]$Recovery = 'update',
    [string]$SnapshotId = '',
    [string]$ReconciliationFile = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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
$helper = Join-Path $source '.agents\skills\1c-workflow\scripts\agent-1c.ps1'
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
    if ($Recovery -ne 'update') { $arguments.WorkflowUpdateRecovery = $Recovery }
    if ($SnapshotId) { $arguments.WorkflowUpdateSnapshotId = $SnapshotId }
    if ($ReconciliationFile) { $arguments.WorkflowUpdateReconciliationFile = $ReconciliationFile }
    & $helper @arguments
    if ($LASTEXITCODE -is [int] -and $LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
} finally {
    $env:ITL_WORKFLOW_SOURCE_PATH = $priorSource
    $env:ITL_WORKFLOW_REQUIRE_CLEAN_SOURCE = $priorCleanSource
}
