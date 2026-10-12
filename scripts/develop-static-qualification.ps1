Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'release-qualification.ps1')

if (-not (Get-Command Get-RepositoryCommonGitDirectory -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "git-path-list.ps1")
}

function Get-DevelopStaticQualificationCachePath {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$Tree
    )

    if ($Tree -notmatch '^[a-f0-9]{40}$') { throw "Invalid Develop static qualification tree: $Tree" }
    $commonDirectory = Get-RepositoryCommonGitDirectory -RepositoryRoot $RepositoryRoot
    return Join-Path $commonDirectory ("itl\develop-static-qualifications\" + $Tree)
}

function Test-DevelopStaticQualificationSource {
    param(
        [Parameter(Mandatory = $true)][string]$FullPath,
        [Parameter(Mandatory = $true)][string]$PesterPath,
        [Parameter(Mandatory = $true)][string]$Tree
    )

    if (-not (Test-Path -LiteralPath $FullPath -PathType Leaf) -or -not (Test-Path -LiteralPath $PesterPath -PathType Leaf)) { return $false }
    try {
        $qualification = Get-Content -LiteralPath $FullPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([int]$qualification.schemaVersion -notin @(1,2,3,4) -or -not (Test-WorkflowFullQualificationRecord $qualification) -or
            -not [bool]$qualification.repository.worktreeClean -or
            [string]$qualification.repository.tree -ne $Tree) { return $false }
        $pesterHash = (Get-FileHash -LiteralPath $PesterPath -Algorithm SHA256).Hash.ToLowerInvariant()
        return $pesterHash -eq ([string]$qualification.junit.sha256).ToLowerInvariant()
    } catch { return $false }
}

function Save-DevelopStaticQualification {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$QualificationRoot,
        [Parameter(Mandatory = $true)][string]$Tree
    )

    $fullPath = Join-Path $QualificationRoot "full.json"
    $pesterPath = Join-Path $QualificationRoot "pester.xml"
    if (-not (Test-DevelopStaticQualificationSource -FullPath $fullPath -PesterPath $pesterPath -Tree $Tree)) {
        throw "Develop static qualification is incomplete, corrupt, or does not match candidate tree $Tree."
    }

    $target = Get-DevelopStaticQualificationCachePath -RepositoryRoot $RepositoryRoot -Tree $Tree
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    $id = [guid]::NewGuid().ToString("N")
    $cachedFull = Join-Path $target "full.json"
    $cachedPester = Join-Path $target "pester.xml"
    $temporaryFull = Join-Path $target ("full.json.$id.tmp")
    $temporaryPester = Join-Path $target ("pester.xml.$id.tmp")
    $temporaryManifest = Join-Path $target ("manifest.json.$id.tmp")
    try {
        Copy-Item -LiteralPath $fullPath -Destination $temporaryFull -Force
        Copy-Item -LiteralPath $pesterPath -Destination $temporaryPester -Force
        $manifest = [ordered]@{
            schemaVersion = 1
            kind = "itl-develop-static-qualification-cache"
            tree = $Tree
            fullSha256 = (Get-FileHash -LiteralPath $temporaryFull -Algorithm SHA256).Hash.ToLowerInvariant()
            pesterSha256 = (Get-FileHash -LiteralPath $temporaryPester -Algorithm SHA256).Hash.ToLowerInvariant()
            savedAt = [DateTime]::UtcNow.ToString("o")
        }
        [IO.File]::WriteAllText($temporaryManifest, (($manifest | ConvertTo-Json -Depth 4) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporaryFull -Destination $cachedFull -Force
        Move-Item -LiteralPath $temporaryPester -Destination $cachedPester -Force
        Move-Item -LiteralPath $temporaryManifest -Destination (Join-Path $target "manifest.json") -Force
    } finally {
        foreach ($path in @($temporaryFull, $temporaryPester, $temporaryManifest)) {
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
        }
    }
    return $target
}

function Restore-DevelopStaticQualification {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$QualificationRoot,
        [Parameter(Mandatory = $true)][string]$Tree
    )

    $source = Get-DevelopStaticQualificationCachePath -RepositoryRoot $RepositoryRoot -Tree $Tree
    $manifestPath = Join-Path $source "manifest.json"
    $fullPath = Join-Path $source "full.json"
    $pesterPath = Join-Path $source "pester.xml"
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { return $false }
    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([int]$manifest.schemaVersion -ne 1 -or [string]$manifest.kind -ne "itl-develop-static-qualification-cache" -or [string]$manifest.tree -ne $Tree) { return $false }
        if (-not (Test-DevelopStaticQualificationSource -FullPath $fullPath -PesterPath $pesterPath -Tree $Tree)) { return $false }
        if ((Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne ([string]$manifest.fullSha256).ToLowerInvariant() -or
            (Get-FileHash -LiteralPath $pesterPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne ([string]$manifest.pesterSha256).ToLowerInvariant()) { return $false }

        New-Item -ItemType Directory -Force -Path $QualificationRoot | Out-Null
        $id = [guid]::NewGuid().ToString("N")
        $temporaryFull = Join-Path $QualificationRoot ("full.json.$id.tmp")
        $temporaryPester = Join-Path $QualificationRoot ("pester.xml.$id.tmp")
        try {
            Copy-Item -LiteralPath $fullPath -Destination $temporaryFull -Force
            Copy-Item -LiteralPath $pesterPath -Destination $temporaryPester -Force
            Move-Item -LiteralPath $temporaryFull -Destination (Join-Path $QualificationRoot "full.json") -Force
            Move-Item -LiteralPath $temporaryPester -Destination (Join-Path $QualificationRoot "pester.xml") -Force
        } finally {
            foreach ($path in @($temporaryFull, $temporaryPester)) {
                if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
            }
        }
        return $true
    } catch { return $false }
}

function Get-DevelopStaticQualificationCacheMatch {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$QualificationRoot,
        [Parameter(Mandatory = $true)][string]$Tree,
        [Parameter(Mandatory = $true)][scriptblock]$Validate
    )

    if ((Test-Path -LiteralPath (Join-Path $QualificationRoot "full.json") -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $QualificationRoot "pester.xml") -PathType Leaf)) {
        $current = & $Validate $false
        if ($current) { return $current }
    }
    if (-not (Restore-DevelopStaticQualification -RepositoryRoot $RepositoryRoot -QualificationRoot $QualificationRoot -Tree $Tree)) { return $null }
    return & $Validate $true
}

function Write-WorkflowQualification {
    param(
        [string]$Commit,
        [string]$Tree,
        [object]$Result,
        [string]$EvidenceCommit,
        [string]$ReuseKind,
        [object]$SourceQualification = $null,
        [object]$ContinuationProof = $null
    )
    $qualificationRoot = Split-Path -Parent $qualificationFullPath
    $qualificationJunitPath = Join-Path $qualificationRoot "pester.xml"
    New-Item -ItemType Directory -Force -Path $qualificationRoot | Out-Null
    if (-not $SourceQualification -and (Test-Path -LiteralPath $junitPath -PathType Leaf)) {
        if (-not [string]::Equals([IO.Path]::GetFullPath($junitPath), [IO.Path]::GetFullPath($qualificationJunitPath), [StringComparison]::OrdinalIgnoreCase)) {
            Copy-Item -LiteralPath $junitPath -Destination $qualificationJunitPath -Force
        }
    }
    if (-not (Test-Path -LiteralPath $qualificationJunitPath -PathType Leaf)) { throw "Reusable workflow qualification has no canonical JUnit evidence." }
    $testInventory = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot "tests\pester") -Recurse -File -Filter "*.ps1" | Sort-Object FullName | ForEach-Object { New-InventoryEntry -Path $_.FullName -Root $repoRoot })
    $scriptInventory = @(Get-WorkflowGateScriptPaths | ForEach-Object { New-InventoryEntry -Path $_ -Root $repoRoot })
    $forkRecord = if ($SourceQualification) { $SourceQualification.fork } else {
        [ordered]@{
            repo = [string]$aiRulesRelease.repo; tag = [string]$aiRulesRelease.tag; commit = [string]$aiRulesRelease.commit; tree = [string]$aiRulesRelease.tree
            upstreamRef = [string]$aiRulesRelease.upstreamRef; upstreamCommit = [string]$aiRulesRelease.upstreamCommit
            qualificationPath = $forkQualificationPath; qualificationSha256 = $forkQualificationSha256
        }
    }
    $pesterInputs = if ($SourceQualification) { $SourceQualification.pesterInputs } else { $pesterShardSummary.inputIdentity }
    if (-not (Test-PesterInputIdentityRecord $pesterInputs)) { throw 'Passed Full qualification requires the actual scheduler input manifest.' }
    $qualification = [ordered]@{
        schemaVersion = 4
        kind = "itl-workflow-full-qualification"
        status = "passed"
        reusable = [bool]$pesterInputs.reusable
        pesterInputs = $pesterInputs
        repository = [ordered]@{ name = "1c-agent-workflow"; commit = $Commit; tree = $Tree; worktreeClean = $true; evidenceCommit = $EvidenceCommit; reuseKind = $ReuseKind }
        fork = $forkRecord
        environment = [ordered]@{
            powershellVersion = [string]$PSVersionTable.PSVersion; powershellEdition = [string]$PSVersionTable.PSEdition
            pesterVersion = $(if ($SourceQualification) { [string]$SourceQualification.environment.pesterVersion } else { $pesterVersion })
            platform = $(if ($PSVersionTable.ContainsKey("Platform")) { [string]$PSVersionTable["Platform"] } else { "Win32NT" })
            os = $(if ($PSVersionTable.ContainsKey("OS")) { [string]$PSVersionTable["OS"] } else { [string][System.Environment]::OSVersion.VersionString })
        }
        inventory = [ordered]@{ tests = $testInventory; scripts = $scriptInventory }
        junit = [ordered]@{ path = Get-RelativeRepositoryPath -Path $qualificationJunitPath -Root $repoRoot; sha256 = (Get-FileHash -LiteralPath $qualificationJunitPath -Algorithm SHA256).Hash.ToLowerInvariant() }
        result = $Result
        stages = @($stages | ForEach-Object { $_ })
        startedAt = $startedAt.ToString("o")
        finishedAt = [DateTime]::UtcNow.ToString("o")
        durationMs = [int64]$overallStopwatch.ElapsedMilliseconds
        error = $null
    }
    if ($ContinuationProof) {
        $qualification["continuation"] = [ordered]@{
            qualifiedCommit = [string]$ContinuationProof.qualifiedCommit
            paths = @($ContinuationProof.paths)
            scopes = @($ContinuationProof.scopes)
            targetedRunPath = [string]$ContinuationProof.targetedRunPath
            targetedRunSha256 = [string]$ContinuationProof.targetedRunSha256
            targetedFinishedAt = [string]$ContinuationProof.targetedFinishedAt
        }
    }
    [System.IO.File]::WriteAllText($qualificationFullPath, (($qualification | ConvertTo-Json -Depth 16) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
    return $qualification
}
