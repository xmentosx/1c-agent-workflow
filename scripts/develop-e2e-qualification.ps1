Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "git-path-list.ps1")
. (Join-Path $PSScriptRoot "quality-contracts.ps1")

function Get-DevelopE2EChangedPaths {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [string]$BaseRef = "",
        [string[]]$ChangedPath = @()
    )

    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($path in @($ChangedPath)) {
        if ($path) { $paths.Add(([string]$path).Replace('\', '/')) | Out-Null }
    }
    if ($BaseRef) {
        foreach ($path in @(Get-RepositoryGitPathList -RepositoryRoot $RepositoryRoot -Arguments @("diff", "--name-only", "--diff-filter=ACDMRT", "-z", "$BaseRef...HEAD", "--"))) {
            $paths.Add(([string]$path).Replace('\', '/')) | Out-Null
        }
    }
    return @($paths | Sort-Object -Unique)
}

function Resolve-DevelopE2EJourneyPlan {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [string]$BaseRef = "",
        [string[]]$ChangedPath = @(),
        [object]$Catalog = $null
    )

    $root = [IO.Path]::GetFullPath($RepositoryRoot)
    if ($null -eq $Catalog) { $Catalog = Get-QualityContractCatalog -RepositoryRoot $root }
    [void](Test-QualityContractCatalog -RepositoryRoot $root -Catalog $Catalog)
    $paths = @(Get-DevelopE2EChangedPaths -RepositoryRoot $root -BaseRef $BaseRef -ChangedPath $ChangedPath)
    if ($paths.Count -eq 0) {
        return [pscustomobject][ordered]@{
            schemaVersion = 1
            kind = "itl-develop-e2e-journey-plan"
            reason = "empty-range-fail-closed"
            paths = @()
            contracts = @()
            journeys = @($Catalog.developJourneys.names | ForEach-Object { [string]$_ })
            unknownPaths = @()
            matchedFullPaths = @()
        }
    }

    $selection = Resolve-QualityContractsForPaths -Catalog $Catalog -Paths $paths
    $contractIds = @($selection.contracts | ForEach-Object { [string]$_.id } | Sort-Object -Unique)
    $unknownPaths = @($selection.unknownPaths | ForEach-Object { [string]$_ } | Sort-Object -Unique)
    $fullPathSet = @($Catalog.developJourneys.fullPaths | ForEach-Object { ([string]$_).Replace('\', '/') })
    $matchedFullPaths = @($paths | Where-Object { $_ -in $fullPathSet } | Sort-Object -Unique)
    $journeys = New-Object System.Collections.Generic.List[string]
    $reason = ""

    if ($unknownPaths.Count -gt 0) {
        throw "QUALITY_OWNER_MISSING: $($unknownPaths -join ', ')"
    } elseif ($matchedFullPaths.Count -gt 0) {
        foreach ($name in @($Catalog.developJourneys.names)) { $journeys.Add([string]$name) | Out-Null }
        $reason = "develop-orchestration-full-path"
    } elseif ($contractIds.Count -eq 0 -and @($paths | Where-Object { $_ -like "tests/pester/*.Tests.ps1" }).Count -eq $paths.Count) {
        $reason = "direct-tests-only"
    } else {
        foreach ($name in @($Catalog.developJourneys.names)) {
            $routeContracts = @($Catalog.developJourneys.routes.$name.contracts | ForEach-Object { [string]$_ })
            if (@($contractIds | Where-Object { $_ -in $routeContracts }).Count -gt 0) { $journeys.Add([string]$name) | Out-Null }
        }
        $reason = if ($journeys.Count -gt 0) { "quality-contract-route" } else { "no-develop-journey-route" }
    }

    return [pscustomobject][ordered]@{
        schemaVersion = 1
        kind = "itl-develop-e2e-journey-plan"
        reason = $reason
        paths = $paths
        contracts = $contractIds
        journeys = @($journeys)
        unknownPaths = $unknownPaths
        matchedFullPaths = $matchedFullPaths
    }
}

function Get-DevelopE2ECanonicalJsonSha256 {
    param([Parameter(Mandatory = $true)][object]$Value)

    $json = $Value | ConvertTo-Json -Depth 16 -Compress
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($json)))).Replace('-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
}

function Get-DevelopE2EStandRepositories {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)

    $root = [IO.Path]::GetFullPath($ProjectRoot)
    $configPath = Join-Path $root ".agent-1c\release-e2e.json"
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { throw "Develop E2E stand config is missing: $configPath" }
    $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $developRoot = [IO.Path]::GetFullPath([string]$config.developWorktreePath)
    return @(
        [pscustomobject]@{ path = $root; role = "master" },
        [pscustomobject]@{ path = $developRoot; role = "develop" }
    )
}

function Get-DevelopE2EStandContentState {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [string]$MasterCommit = "HEAD",
        [string]$DevelopCommit = "HEAD",
        [switch]$RequireClean
    )

    $state = [ordered]@{ schemaVersion = 2; repositories = @() }
    foreach ($entry in @(Get-DevelopE2EStandRepositories -ProjectRoot $ProjectRoot)) {
        $path = [string]$entry.path
        $commit = if ([string]$entry.role -eq "master") { $MasterCommit } else { $DevelopCommit }
        $resolvedCommit = (& git -C $path rev-parse $commit 2>$null).Trim()
        if ($LASTEXITCODE -ne 0 -or $resolvedCommit -notmatch '^[a-f0-9]{40}$') { throw "Develop E2E cannot resolve $($entry.role) stand commit '$commit': $path" }
        $tracked = @(& git -C $path status --porcelain --untracked-files=no 2>$null)
        if ($LASTEXITCODE -ne 0) { throw "Develop E2E cannot inspect $($entry.role) stand state: $path" }
        $trackedClean = $tracked.Count -eq 0
        if ($RequireClean -and -not $trackedClean) { throw "Develop E2E $($entry.role) stand has tracked changes: $path" }
        $content = [ordered]@{}
        foreach ($repoPath in @("src/cf", "src/cfe", "tests/features")) {
            $treeEntry = (@(& git -C $path ls-tree -d $resolvedCommit -- $repoPath 2>$null) -join [Environment]::NewLine).Trim()
            if ($LASTEXITCODE -ne 0) { throw "Develop E2E cannot inspect $($entry.role) stand content '$repoPath' at '$resolvedCommit': $path" }
            $objectId = ""
            if ($treeEntry) {
                if ($treeEntry -notmatch '^040000\s+tree\s+([a-f0-9]{40})\t') {
                    throw "Develop E2E received an invalid $($entry.role) stand tree entry for '$repoPath' at '$resolvedCommit': $path"
                }
                $objectId = [string]$Matches[1]
            }
            $content[$repoPath] = $objectId
        }
        $state.repositories += [ordered]@{
            role = [string]$entry.role
            path = $path.ToLowerInvariant()
            trackedClean = $trackedClean
            content = $content
        }
    }
    return $state
}

function Get-DevelopE2EStandStateSha256 {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)

    return Get-DevelopE2ECanonicalJsonSha256 -Value (Get-DevelopE2EStandContentState -ProjectRoot $ProjectRoot)
}

function Test-DevelopE2ELegacyStandContinuation {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RecordedSha256
    )

    if ($RecordedSha256 -notmatch '^[a-f0-9]{64}$') { return $false }
    try {
        $repositories = @(Get-DevelopE2EStandRepositories -ProjectRoot $ProjectRoot)
        $currentState = Get-DevelopE2EStandContentState -ProjectRoot $ProjectRoot -RequireClean
        $currentSha256 = Get-DevelopE2ECanonicalJsonSha256 -Value $currentState
        $masterHeads = @(& git -C ([string]$repositories[0].path) reflog --format=%H -n 64 2>$null | Where-Object { $_ -match '^[a-f0-9]{40}$' } | Select-Object -Unique)
        $developHeads = @(& git -C ([string]$repositories[1].path) reflog --format=%H -n 128 2>$null | Where-Object { $_ -match '^[a-f0-9]{40}$' } | Select-Object -Unique)
        foreach ($masterHead in $masterHeads) {
            foreach ($developHead in $developHeads) {
                $legacyState = [ordered]@{ schemaVersion = 1; repositories = @(
                    [ordered]@{ role = "master"; path = ([string]$repositories[0].path).ToLowerInvariant(); head = [string]$masterHead; trackedClean = $true },
                    [ordered]@{ role = "develop"; path = ([string]$repositories[1].path).ToLowerInvariant(); head = [string]$developHead; trackedClean = $true }
                ) }
                if ((Get-DevelopE2ECanonicalJsonSha256 -Value $legacyState) -ne $RecordedSha256) { continue }
                $recordedState = Get-DevelopE2EStandContentState -ProjectRoot $ProjectRoot -MasterCommit ([string]$masterHead) -DevelopCommit ([string]$developHead)
                return (Get-DevelopE2ECanonicalJsonSha256 -Value $recordedState) -eq $currentSha256
            }
        }
    } catch {
        return $false
    }
    return $false
}

function New-DevelopE2ERouteReport {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][object]$Plan,
        [Parameter(Mandatory = $true)][ValidateSet("upgrade", "fresh")][string]$Journey,
        [Parameter(Mandatory = $true)][string]$IdentitySha256,
        [Parameter(Mandatory = $true)][string]$StandStateSha256,
        [Parameter(Mandatory = $true)][object]$JourneyResult
    )

    $commit = (& git -C $RepositoryRoot rev-parse HEAD 2>$null).Trim()
    $tree = (& git -C $RepositoryRoot rev-parse 'HEAD^{tree}' 2>$null).Trim()
    if ($LASTEXITCODE -ne 0 -or $commit -notmatch '^[a-f0-9]{40}$' -or $tree -notmatch '^[a-f0-9]{40}$') {
        throw "Cannot resolve candidate identity for Develop E2E route report."
    }
    if ($IdentitySha256 -notmatch '^[a-f0-9]{64}$') { throw "Invalid Develop E2E identity SHA256: $IdentitySha256" }
    if ($StandStateSha256 -notmatch '^[a-f0-9]{64}$') { throw "Invalid Develop E2E stand-state SHA256: $StandStateSha256" }
    if ($Journey -notin @($Plan.journeys | ForEach-Object { [string]$_ }) -or [string]$JourneyResult.name -ne $Journey -or [string]$JourneyResult.status -ne "passed") {
        throw "Develop E2E route report requires one passed result for requested journey '$Journey'."
    }
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        kind = "itl-develop-e2e-route-report"
        status = "passed"
        repository = [ordered]@{ commit = $commit; tree = $tree }
        identitySha256 = $IdentitySha256
        standStateSha256 = $StandStateSha256
        journey = $Journey
        plan = $Plan
        planSha256 = Get-DevelopE2ECanonicalJsonSha256 -Value $Plan
        result = $JourneyResult
        finishedAt = [DateTime]::UtcNow.ToString("o")
    }
}

function Test-DevelopE2ERouteReport {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Tree,
        [Parameter(Mandatory = $true)][ValidateSet("upgrade", "fresh")][string]$Journey,
        [Parameter(Mandatory = $true)][string]$IdentitySha256,
        [Parameter(Mandatory = $true)][string]$StandStateSha256,
        [string]$ProjectRoot = ""
    )

    if ($Tree -notmatch '^[a-f0-9]{40}$' -or $IdentitySha256 -notmatch '^[a-f0-9]{64}$' -or $StandStateSha256 -notmatch '^[a-f0-9]{64}$' -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try {
        if (-not $ProjectRoot) {
            $projectRootVariable = Get-Variable -Name E2EProjectRoot -Scope Script -ErrorAction SilentlyContinue
            if ($projectRootVariable -and [string]$projectRootVariable.Value) { $ProjectRoot = [string]$projectRootVariable.Value }
        }
        $report = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        $standMatches = [string]$report.standStateSha256 -eq $StandStateSha256 -or
            ($ProjectRoot -and (Test-DevelopE2ELegacyStandContinuation -ProjectRoot $ProjectRoot -RecordedSha256 ([string]$report.standStateSha256)))
        if ([int]$report.schemaVersion -ne 1 -or [string]$report.kind -ne "itl-develop-e2e-route-report" -or
            [string]$report.status -ne "passed" -or [string]$report.repository.tree -ne $Tree -or
            [string]$report.identitySha256 -ne $IdentitySha256 -or -not $standMatches -or [string]$report.journey -ne $Journey -or
            [string]$report.plan.kind -ne "itl-develop-e2e-journey-plan" -or
            [string]$report.planSha256 -ne (Get-DevelopE2ECanonicalJsonSha256 -Value $report.plan)) { return $false }
        return $Journey -in @($report.plan.journeys | ForEach-Object { [string]$_ }) -and
            [string]$report.result.name -eq $Journey -and [string]$report.result.status -eq "passed"
    } catch { return $false }
}

function Get-DevelopE2EQualificationCachePath {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$Tree,
        [Parameter(Mandatory = $true)][ValidateSet("upgrade", "fresh")][string]$Journey,
        [Parameter(Mandatory = $true)][string]$IdentitySha256
    )

    if ($Tree -notmatch '^[a-f0-9]{40}$') { throw "Invalid Develop E2E qualification tree: $Tree" }
    if ($IdentitySha256 -notmatch '^[a-f0-9]{64}$') { throw "Invalid Develop E2E identity SHA256: $IdentitySha256" }
    $commonDirectory = Get-RepositoryCommonGitDirectory -RepositoryRoot $RepositoryRoot
    return Join-Path $commonDirectory ("itl\develop-e2e-qualifications\$Tree\$IdentitySha256\$Journey")
}

function Save-DevelopE2EQualification {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$ReportPath,
        [Parameter(Mandatory = $true)][string]$Tree,
        [Parameter(Mandatory = $true)][ValidateSet("upgrade", "fresh")][string]$Journey,
        [Parameter(Mandatory = $true)][string]$IdentitySha256,
        [Parameter(Mandatory = $true)][string]$StandStateSha256
    )

    if (-not (Test-DevelopE2ERouteReport -Path $ReportPath -Tree $Tree -Journey $Journey -IdentitySha256 $IdentitySha256 -StandStateSha256 $StandStateSha256)) {
        throw "Develop E2E route report is incomplete, corrupt, or does not match tree/identity/journey."
    }
    $report = Get-Content -LiteralPath $ReportPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $target = Get-DevelopE2EQualificationCachePath -RepositoryRoot $RepositoryRoot -Tree $Tree -Journey $Journey -IdentitySha256 $IdentitySha256
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    $token = [guid]::NewGuid().ToString("N")
    $temporaryReport = Join-Path $target ("route-report.json.$token.tmp")
    $temporaryManifest = Join-Path $target ("manifest.json.$token.tmp")
    try {
        Copy-Item -LiteralPath $ReportPath -Destination $temporaryReport -Force
        $reportSha256 = (Get-FileHash -LiteralPath $temporaryReport -Algorithm SHA256).Hash.ToLowerInvariant()
        $manifest = [ordered]@{
            schemaVersion = 1
            kind = "itl-develop-e2e-qualification-cache"
            identity = [ordered]@{
                tree = $Tree
                identitySha256 = $IdentitySha256
                standStateSha256 = $StandStateSha256
                journey = $Journey
                reportKind = [string]$report.kind
                reportSha256 = $reportSha256
                planSha256 = [string]$report.planSha256
            }
            savedAt = [DateTime]::UtcNow.ToString("o")
        }
        [IO.File]::WriteAllText($temporaryManifest, (($manifest | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporaryReport -Destination (Join-Path $target "route-report.json") -Force
        Move-Item -LiteralPath $temporaryManifest -Destination (Join-Path $target "manifest.json") -Force
    } finally {
        Remove-Item -LiteralPath $temporaryReport, $temporaryManifest -Force -ErrorAction SilentlyContinue
    }
    return $target
}

function Restore-DevelopE2EQualification {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [Parameter(Mandatory = $true)][string]$Tree,
        [Parameter(Mandatory = $true)][ValidateSet("upgrade", "fresh")][string]$Journey,
        [Parameter(Mandatory = $true)][string]$IdentitySha256,
        [Parameter(Mandatory = $true)][string]$StandStateSha256
    )

    $source = Get-DevelopE2EQualificationCachePath -RepositoryRoot $RepositoryRoot -Tree $Tree -Journey $Journey -IdentitySha256 $IdentitySha256
    $manifestPath = Join-Path $source "manifest.json"
    $reportPath = Join-Path $source "route-report.json"
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf) -or -not (Test-Path -LiteralPath $reportPath -PathType Leaf)) { return $false }
    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([int]$manifest.schemaVersion -ne 1 -or [string]$manifest.kind -ne "itl-develop-e2e-qualification-cache" -or
            [string]$manifest.identity.tree -ne $Tree -or [string]$manifest.identity.reportKind -ne "itl-develop-e2e-route-report" -or
            [string]$manifest.identity.identitySha256 -ne $IdentitySha256 -or [string]$manifest.identity.journey -ne $Journey -or
            [string]$manifest.identity.standStateSha256 -ne $StandStateSha256 -or
            (Get-FileHash -LiteralPath $reportPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne ([string]$manifest.identity.reportSha256).ToLowerInvariant() -or
            -not (Test-DevelopE2ERouteReport -Path $reportPath -Tree $Tree -Journey $Journey -IdentitySha256 $IdentitySha256 -StandStateSha256 $StandStateSha256)) { return $false }
        $report = Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([string]$manifest.identity.planSha256 -ne [string]$report.planSha256) { return $false }

        $parent = Split-Path -Parent $OutputPath
        if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
        $temporary = $OutputPath + "." + [guid]::NewGuid().ToString("N") + ".tmp"
        try {
            Copy-Item -LiteralPath $reportPath -Destination $temporary -Force
            Move-Item -LiteralPath $temporary -Destination $OutputPath -Force
        } finally { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
        return $true
    } catch { return $false }
}
