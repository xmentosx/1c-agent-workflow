[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$BaseRef = "",
    [string[]]$ChangedPath = @(),
    [string[]]$CoverageContract = @(),
    [string]$OutputPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$CoverageContract = @($CoverageContract | ForEach-Object { @(([string]$_) -split ',') } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
. (Join-Path $PSScriptRoot "git-path-list.ps1")
. (Join-Path $PSScriptRoot "quality-contracts.ps1")

$root = [System.IO.Path]::GetFullPath($RepositoryRoot)
$catalog = Get-QualityContractCatalog -RepositoryRoot $root
[void](Test-QualityContractCatalog -RepositoryRoot $root -Catalog $catalog)
$paths = New-Object System.Collections.Generic.List[string]
foreach ($path in @($ChangedPath)) { if ($path) { $paths.Add(([string]$path).Replace('\', '/')) | Out-Null } }
if ($BaseRef) {
    foreach ($path in @(Get-RepositoryGitPathList -RepositoryRoot $root -Arguments @("diff", "--name-only", "-z", "$BaseRef...HEAD", "--"))) {
        $paths.Add(([string]$path).Replace('\', '/')) | Out-Null
    }
}
if (-not $BaseRef -and @($ChangedPath).Count -eq 0) {
    foreach ($args in @(
        @("diff", "--name-only", "-z", "--"),
        @("diff", "--cached", "--name-only", "-z", "--"),
        @("ls-files", "-z", "--others", "--exclude-standard", "--")
    )) {
        foreach ($path in @(Get-RepositoryGitPathList -RepositoryRoot $root -Arguments $args)) {
            $paths.Add(([string]$path).Replace('\', '/')) | Out-Null
        }
    }
}
$uniquePaths = @($paths | Sort-Object -Unique)
if ($uniquePaths.Count -eq 0) { throw "Targeted mode found no changed paths. Pass -BaseRef or -ChangedPath." }
$selection = Resolve-QualityContractsForPaths -Catalog $catalog -Paths $uniquePaths
if (@($selection.unknownPaths).Count -gt 0) {
    throw "Targeted mode found paths without a quality owner: $($selection.unknownPaths -join ', '). Update tests/quality-contracts.json."
}
if (@($selection.tests).Count -eq 0) { throw "Targeted mode selected no tests." }

$declared = @($CoverageContract | Where-Object { $_ } | Sort-Object -Unique)
if ($declared.Count -gt 0) {
    $selectedIds = @($selection.contracts | ForEach-Object { [string]$_.id })
    $invalid = @($declared | Where-Object { $_ -notin $selectedIds })
    if ($invalid.Count -gt 0) { throw "Declared coverage contracts were not selected by the changed paths: $($invalid -join ', ')." }
}

$result = [ordered]@{
    schemaVersion = 1
    paths = $uniquePaths
    contracts = @($selection.contracts | ForEach-Object { [ordered]@{ id = [string]$_.id; owner = [string]$_.owner } })
    tests = @($selection.tests)
}
$json = ($result | ConvertTo-Json -Depth 8)
if ($OutputPath) {
    $fullOutputPath = if ([System.IO.Path]::IsPathRooted($OutputPath)) { $OutputPath } else { Join-Path $root $OutputPath }
    $parent = Split-Path -Parent $fullOutputPath
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    [System.IO.File]::WriteAllText($fullOutputPath, ($json + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
}
$json
