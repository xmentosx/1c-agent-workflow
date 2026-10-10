# Package transport excludes disposable Python output, as in the source .gitignore.
# Snapshot/rollback callers copy raw bytes and must not use this filter.
function Test-WorkflowPackageContentPath {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    $parts = $RelativePath.Replace('\', '/').Split('/')
    foreach ($part in $parts) {
        if ([string]::Equals($part, '__pycache__', [StringComparison]::OrdinalIgnoreCase)) { return $false }
    }
    return -not $RelativePath.EndsWith('.pyc', [StringComparison]::OrdinalIgnoreCase)
}

function Copy-WorkflowPackageDirectoryContent {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$DestinationPath
    )

    New-Item -ItemType Directory -Path $DestinationPath -Force -ErrorAction Stop | Out-Null
    foreach ($item in @(Get-ChildItem -LiteralPath $SourcePath -Force -ErrorAction Stop)) {
        if (-not (Test-WorkflowPackageContentPath -RelativePath $item.Name)) { continue }
        $destination = Join-Path $DestinationPath $item.Name
        if ($item.PSIsContainer) {
            Copy-WorkflowPackageDirectoryContent -SourcePath $item.FullName -DestinationPath $destination
        } else {
            Copy-Item -LiteralPath $item.FullName -Destination $destination -Force -ErrorAction Stop
        }
    }
}
