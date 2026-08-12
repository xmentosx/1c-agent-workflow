Set-StrictMode -Version Latest

function Get-DevelopStaticQualificationCachePath {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$Tree
    )

    if ($Tree -notmatch '^[a-f0-9]{40}$') { throw "Invalid Develop static qualification tree: $Tree" }
    $commonDirectory = [string](& git -C $RepositoryRoot rev-parse --git-common-dir 2>$null)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($commonDirectory)) { throw "Cannot resolve the common Git directory for Develop static qualification." }
    if (-not [IO.Path]::IsPathRooted($commonDirectory)) { $commonDirectory = Join-Path $RepositoryRoot $commonDirectory }
    $commonDirectory = [IO.Path]::GetFullPath($commonDirectory)
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
        if ([int]$qualification.schemaVersion -notin @(1, 2, 3) -or
            [string]$qualification.kind -ne "itl-workflow-full-qualification" -or
            [string]$qualification.status -ne "passed" -or
            -not [bool]$qualification.reusable -or
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
