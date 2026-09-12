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

function ConvertTo-TargetedCanonicalPowerShellText {
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return $null }
    return $Text.Replace("`r`n", "`n").Replace("`r", "`n")
}

$root = [System.IO.Path]::GetFullPath($RepositoryRoot)
$catalog = Get-QualityContractCatalog -RepositoryRoot $root
$semanticPath = ([string]$catalog.semanticTargeting.path).Replace('\', '/')
$semanticRenamedPaths = @()
$paths = New-Object System.Collections.Generic.List[string]
foreach ($path in @($ChangedPath)) { if ($path) { $paths.Add(([string]$path).Replace('\', '/')) | Out-Null } }
if ($BaseRef) {
    foreach ($path in @(Get-RepositoryGitPathList -RepositoryRoot $root -Arguments @("diff", "--name-only", "-z", "$BaseRef...HEAD", "--"))) {
        $paths.Add(([string]$path).Replace('\', '/')) | Out-Null
    }
    $statusFields = @(Get-RepositoryGitPathList -RepositoryRoot $root -Arguments @("diff", "--name-status", "-z", "$BaseRef...HEAD", "--"))
    for ($index = 0; $index -lt $statusFields.Count;) {
        $status = [string]$statusFields[$index++]
        if ($status -match '^[RC][0-9]+$') {
            if ($index + 1 -ge $statusFields.Count) { break }
            $oldPath = ([string]$statusFields[$index++]).Replace('\', '/')
            $newPath = ([string]$statusFields[$index++]).Replace('\', '/')
            if ($status -like 'R*' -and $oldPath -eq $semanticPath) { $semanticRenamedPaths += $newPath }
        } elseif ($index -lt $statusFields.Count) {
            $index++
        }
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
$semanticPathChanged = $semanticPath -in $uniquePaths -or $semanticRenamedPaths.Count -gt 0
$semanticCurrentPath = Join-Path $root $semanticPath.Replace('/', '\')
$semanticCurrentExists = Test-Path -LiteralPath $semanticCurrentPath -PathType Leaf
[void](Test-QualityContractCatalog -RepositoryRoot $root -Catalog $catalog -SkipSemanticEntrypointValidation:(-not $semanticCurrentExists -and $semanticPathChanged))
$ordinaryPaths = @($uniquePaths | Where-Object { $_ -ne $semanticPath -and $_ -notin $semanticRenamedPaths })
$selection = if ($ordinaryPaths.Count -gt 0) {
    Resolve-QualityContractsForPaths -Catalog $catalog -Paths $ordinaryPaths
} else {
    [pscustomobject]@{ contracts = @(); tests = @(); unknownPaths = @() }
}
if (@($selection.unknownPaths).Count -gt 0) {
    throw "Targeted mode found paths without a quality owner: $($selection.unknownPaths -join ', '). Update tests/quality-contracts.json."
}

$selectedContracts = New-Object System.Collections.Generic.List[object]
foreach ($contract in @($selection.contracts)) { $selectedContracts.Add($contract) | Out-Null }
$selectedTests = New-Object System.Collections.Generic.List[string]
foreach ($test in @($selection.tests)) { $selectedTests.Add(([string]$test).Replace('\', '/')) | Out-Null }
$semanticImpacts = @()
$additionalInputs = @()
if ($semanticPathChanged) {
    $currentText = $null
    if ($semanticCurrentExists) {
        # The entrypoint is a UTF-8 PowerShell text file. Normalize decoded EOL
        # on both sides so a CRLF checkout compares to the LF Git blob without
        # writing an uncommitted blob into the object database.
        $currentText = ConvertTo-TargetedCanonicalPowerShellText -Text ([IO.File]::ReadAllText($semanticCurrentPath, [Text.Encoding]::UTF8))
    }
    $baselineText = $null
    if ($BaseRef) {
        $baselineResult = Invoke-RepositoryGit -RepositoryRoot $root -Arguments @("show", "$BaseRef`:$semanticPath") -AllowFailure
        if ($baselineResult.exitCode -eq 0) { $baselineText = ConvertTo-TargetedCanonicalPowerShellText -Text ([string]$baselineResult.stdout) }
    }
    $semanticSelection = Resolve-Agent1cSemanticImpact -Catalog $catalog -CurrentText $currentText -BaselineText $baselineText
    foreach ($test in @($semanticSelection.tests)) { $selectedTests.Add(([string]$test).Replace('\', '/')) | Out-Null }
    $semanticImpacts = @($semanticSelection.impacts | ForEach-Object {
        [ordered]@{ kind = [string]$_.kind; name = [string]$_.name; owner = [string]$_.owner }
    })
    $additionalInputs = if ($semanticCurrentExists) { @($semanticPath) } else { @($semanticRenamedPaths | Sort-Object -Unique) }

    # The changed path remains owned by the lifecycle contract. semanticImpacts
    # explains why only a tested subset of that contract is selected.
    $semanticContracts = @($catalog.contracts | Where-Object { [string]$_.id -eq [string]$catalog.semanticTargeting.fallbackContract })
    foreach ($contract in $semanticContracts) {
        if (@($selectedContracts | Where-Object { [string]$_.id -eq [string]$contract.id }).Count -eq 0) { $selectedContracts.Add($contract) | Out-Null }
    }
}
$resolvedTests = @($selectedTests | Sort-Object -Unique)
if ($resolvedTests.Count -eq 0) { throw "Targeted mode selected no tests." }

$declared = @($CoverageContract | Where-Object { $_ } | Sort-Object -Unique)
if ($declared.Count -gt 0) {
    $selectedIds = @($selectedContracts | ForEach-Object { [string]$_.id })
    $invalid = @($declared | Where-Object { $_ -notin $selectedIds })
    if ($invalid.Count -gt 0) { throw "Declared coverage contracts were not selected by the changed paths: $($invalid -join ', ')." }
}

$result = [ordered]@{
    schemaVersion = 2
    paths = $uniquePaths
    contracts = @($selectedContracts | Sort-Object { [string]$_.id } -Unique | ForEach-Object { [ordered]@{ id = [string]$_.id; owner = [string]$_.owner } })
    tests = $resolvedTests
    semanticImpacts = $semanticImpacts
    additionalInputs = $additionalInputs
}
$json = ($result | ConvertTo-Json -Depth 8)
if ($OutputPath) {
    $fullOutputPath = if ([System.IO.Path]::IsPathRooted($OutputPath)) { $OutputPath } else { Join-Path $root $OutputPath }
    $parent = Split-Path -Parent $fullOutputPath
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    [System.IO.File]::WriteAllText($fullOutputPath, ($json + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
}
$json
