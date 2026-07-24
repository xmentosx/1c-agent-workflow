[CmdletBinding()]
param(
    [string]$OutputDirectory = "",
    [string]$PlatformBin = "C:\Program Files\1cv8\8.3.27.2130\bin",
    [string]$WorkRoot = "C:\itlvabld",
    [switch]$KeepWork,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-Equal {
    param(
        [Parameter(Mandatory = $true)][string]$Actual,
        [Parameter(Mandatory = $true)][string]$Expected,
        [Parameter(Mandatory = $true)][string]$Subject
    )
    if ($Actual -ne $Expected) {
        throw "$Subject mismatch. Expected '$Expected', actual '$Actual'."
    }
}

function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Description
    )
    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Description failed with exit code $LASTEXITCODE."
    }
}

function Test-PathInside {
    param(
        [Parameter(Mandatory = $true)][string]$Candidate,
        [Parameter(Mandatory = $true)][string]$Parent
    )
    $candidateFull = [System.IO.Path]::GetFullPath($Candidate).TrimEnd("\")
    $parentFull = [System.IO.Path]::GetFullPath($Parent).TrimEnd("\")
    return $candidateFull.StartsWith($parentFull + "\", [System.StringComparison]::OrdinalIgnoreCase)
}

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$assetRoot = Join-Path $repoRoot "third-party\vanessa-automation\1.2.043.28-itl-r1"
$manifestPath = Join-Path $assetRoot "manifest.json"
$patchPath = Join-Path $assetRoot "file-operations.patch"
$noticePath = Join-Path $assetRoot "ITL-NOTICE.txt"
$licenseNoticePath = Join-Path $assetRoot "LICENSE.upstream"

if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $repoRoot "build\third-party\vanessa-automation\1.2.043.28-itl-r1"
}
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
$WorkRoot = [System.IO.Path]::GetFullPath($WorkRoot)

foreach ($requiredPath in @($manifestPath, $patchPath, $noticePath, $licenseNoticePath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required controlled asset is missing: $requiredPath"
    }
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$artifactPath = Join-Path $OutputDirectory ([string]$manifest.artifact.fileName)
$provenancePath = Join-Path $OutputDirectory "candidate.provenance.json"
if ((Test-Path -LiteralPath $artifactPath) -and -not $Force) {
    throw "Candidate already exists: $artifactPath. Use -Force to replace it."
}

Assert-Equal (Get-Sha256 -Path $patchPath) ([string]$manifest.patch.sha256) "Patch SHA-256"

$gitVersion = (& git --version) -replace "^git version\s+", ""
if ($LASTEXITCODE -ne 0) { throw "git --version failed." }
Assert-Equal $gitVersion ([string]$manifest.build.gitVersion) "Git version"

$oscriptCommand = Get-Command oscript.exe -ErrorAction Stop
$opmCommand = Get-Command opm.bat -ErrorAction Stop
$oscriptVersion = (& $oscriptCommand.Source -version).Trim()
if ($LASTEXITCODE -ne 0) { throw "oscript -version failed." }
$opmVersion = (& $opmCommand.Source --version).Trim()
if ($LASTEXITCODE -ne 0) { throw "opm --version failed." }
Assert-Equal $oscriptVersion ([string]$manifest.build.oneScript.version) "OneScript version"
Assert-Equal $opmVersion ([string]$manifest.build.oneScript.opmVersion) "OPM version"

$opmPackages = (& $opmCommand.Source list) -join "`n"
if ($LASTEXITCODE -ne 0) { throw "opm list failed." }
foreach ($property in $manifest.build.oneScript.packages.PSObject.Properties) {
    $packagePattern = "(?m)^\s*" + [regex]::Escape($property.Name) + "\s*\|\s*" + [regex]::Escape([string]$property.Value) + "\s*\|"
    if ($opmPackages -notmatch $packagePattern) {
        throw "Required OneScript package is absent or has the wrong version: $($property.Name) $($property.Value)."
    }
}

$platformExe = Join-Path $PlatformBin "1cv8.exe"
if (-not (Test-Path -LiteralPath $platformExe -PathType Leaf)) {
    throw "1C:Enterprise executable was not found: $platformExe"
}
$platformVersion = (Get-Item -LiteralPath $platformExe).VersionInfo.FileVersion
Assert-Equal $platformVersion ([string]$manifest.build.platform.version) "1C:Enterprise platform version"

$installedPlatformExecutables = @()
foreach ($platformRoot in @("C:\Program Files\1cv8", "C:\Program Files (x86)\1cv8")) {
    if (Test-Path -LiteralPath $platformRoot -PathType Container) {
        $installedPlatformExecutables += Get-ChildItem -LiteralPath $platformRoot -Directory |
            ForEach-Object { Join-Path $_.FullName "bin\1cv8.exe" } |
            Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
    }
}
$latestPlatformVersion = @($installedPlatformExecutables |
    ForEach-Object { [version](Get-Item -LiteralPath $_).VersionInfo.FileVersion } |
    Sort-Object -Descending |
    Select-Object -First 1)
if ($latestPlatformVersion.Count -ne 1 -or $latestPlatformVersion[0].ToString() -ne $platformVersion) {
    throw "Upstream Compile.os selects the latest installed 8.3 platform. The selected version would not be the pinned $platformVersion."
}

$workId = [Guid]::NewGuid().ToString("N").Substring(0, 8)
$workDirectory = Join-Path $WorkRoot $workId
if (-not (Test-PathInside -Candidate $workDirectory -Parent $WorkRoot)) {
    throw "Unsafe work directory: $workDirectory"
}
if ($workDirectory.Length -gt 40) {
    throw "Work directory is too long for upstream MakeVASingle.os: $workDirectory"
}

$sourceDirectory = Join-Path $workDirectory "src"
$singleBuildDirectory = Join-Path $workDirectory "out"
$qualificationBase = Join-Path $workDirectory "base"
$stageDirectory = Join-Path $workDirectory "stage"
$sourceArchivePath = Join-Path $workDirectory "source.tar"
$createBaseLog = Join-Path $workDirectory "create-base.log"

New-Item -ItemType Directory -Path $workDirectory -Force | Out-Null
try {
    Invoke-Native -FilePath "git" -Arguments @(
        "clone", "--filter=blob:none", "--no-checkout",
        [string]$manifest.upstream.repository, $sourceDirectory
    ) -Description "Clone upstream Vanessa Automation"

    $tagCommit = (& git -C $sourceDirectory rev-parse "$($manifest.upstream.ref)^{commit}").Trim()
    if ($LASTEXITCODE -ne 0) { throw "Could not resolve the pinned upstream tag." }
    Assert-Equal $tagCommit ([string]$manifest.upstream.commit) "Upstream tag commit"

    Invoke-Native -FilePath "git" -Arguments @(
        "-C", $sourceDirectory, "checkout", "--detach", [string]$manifest.upstream.commit
    ) -Description "Checkout pinned upstream commit"

    $headCommit = (& git -C $sourceDirectory rev-parse HEAD).Trim()
    $headTree = (& git -C $sourceDirectory rev-parse "HEAD^{tree}").Trim()
    Assert-Equal $headCommit ([string]$manifest.upstream.commit) "Upstream HEAD"
    Assert-Equal $headTree ([string]$manifest.upstream.tree) "Upstream tree"

    Invoke-Native -FilePath "git" -Arguments @(
        "-C", $sourceDirectory, "archive", "--format=tar",
        "--output=$sourceArchivePath", [string]$manifest.upstream.commit
    ) -Description "Create canonical upstream source archive"
    Assert-Equal (Get-Sha256 -Path $sourceArchivePath) ([string]$manifest.upstream.sourceArchive.sha256) "Upstream source archive SHA-256"

    foreach ($flowFile in $manifest.build.upstreamFlow) {
        $flowPath = Join-Path $sourceDirectory ([string]$flowFile.path).Replace("/", "\")
        Assert-Equal (Get-Sha256 -Path $flowPath) ([string]$flowFile.sha256) "Upstream build file $($flowFile.path)"
    }

    Invoke-Native -FilePath "git" -Arguments @(
        "-C", $sourceDirectory, "apply", "--check", "--whitespace=error-all", $patchPath
    ) -Description "Check downstream patch"
    Invoke-Native -FilePath "git" -Arguments @(
        "-C", $sourceDirectory, "apply", "--whitespace=error-all", $patchPath
    ) -Description "Apply downstream patch"
    Invoke-Native -FilePath "git" -Arguments @(
        "-C", $sourceDirectory, "diff", "--check"
    ) -Description "Check patched source whitespace"

    $changedPaths = @(& git -C $sourceDirectory diff --name-only)
    if ($LASTEXITCODE -ne 0) { throw "Could not enumerate patched paths." }
    $expectedChangedPaths = @($manifest.patch.expectedChangedPaths)
    if (($changedPaths -join "`n") -ne ($expectedChangedPaths -join "`n")) {
        throw "Patch changed an unexpected path set. Expected '$($expectedChangedPaths -join ", ")'; actual '$($changedPaths -join ", ")'."
    }

    Push-Location $sourceDirectory
    try {
        Invoke-Native -FilePath $oscriptCommand.Source -Arguments @(
            (Join-Path $sourceDirectory "lib\packages.os"), "download"
        ) -Description "Download upstream pinned packages"

        foreach ($dependency in $manifest.build.upstreamBundledDependencies) {
            $dependencyPath = Join-Path $sourceDirectory ([string]$dependency.path).Replace("/", "\")
            Assert-Equal (Get-Sha256 -Path $dependencyPath) ([string]$dependency.sha256) "Bundled dependency $($dependency.name)"
        }

        Invoke-Native -FilePath $oscriptCommand.Source -Arguments @(
            (Join-Path $sourceDirectory "tools\onescript\ZipTemplates.os")
        ) -Description "Build upstream templates"
        Invoke-Native -FilePath $oscriptCommand.Source -Arguments @(
            (Join-Path $sourceDirectory "tools\onescript\Compile.os"), ($sourceDirectory + "\")
        ) -Description "Run upstream Compile.os"
    } finally {
        Pop-Location
    }

    New-Item -ItemType Directory -Path $qualificationBase -Force | Out-Null
    $createBaseArguments = @(
        "CREATEINFOBASE",
        "File=`"$qualificationBase`"",
        "/Out",
        "`"$createBaseLog`""
    )
    $createBaseProcess = Start-Process -FilePath $platformExe -ArgumentList $createBaseArguments -Wait -PassThru -WindowStyle Hidden
    if ($createBaseProcess.ExitCode -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $qualificationBase "1Cv8.1CD") -PathType Leaf)) {
        $createBaseDetails = if (Test-Path -LiteralPath $createBaseLog) { Get-Content -LiteralPath $createBaseLog -Raw -Encoding UTF8 } else { "" }
        throw "Creating the qualification infobase failed with exit code $($createBaseProcess.ExitCode). $createBaseDetails"
    }

    Push-Location $sourceDirectory
    try {
        Invoke-Native -FilePath $oscriptCommand.Source -Arguments @(
            (Join-Path $sourceDirectory "tools\onescript\MakeVASingle.os"),
            $sourceDirectory,
            $singleBuildDirectory,
            (Join-Path $sourceDirectory "features\Libraries"),
            $PlatformBin,
            $qualificationBase
        ) -Description "Run upstream MakeVASingle.os"
    } finally {
        Pop-Location
    }

    $distributionDirectory = Join-Path $singleBuildDirectory "Temp\DistribVanessaAutomationsingle"
    $epfPath = Join-Path $distributionDirectory ([string]$manifest.artifact.entryPoint)
    $upstreamLicensePath = Join-Path $distributionDirectory "LICENSE"
    if (-not (Test-Path -LiteralPath $epfPath -PathType Leaf)) {
        throw "Upstream single EPF was not produced: $epfPath"
    }
    Assert-Equal (Get-Sha256 -Path $upstreamLicensePath) ([string]$manifest.license.upstreamSha256) "Artifact upstream license"

    Copy-Item -LiteralPath $distributionDirectory -Destination $stageDirectory -Recurse
    Copy-Item -LiteralPath $noticePath -Destination (Join-Path $stageDirectory "ITL-NOTICE.txt")
    Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $stageDirectory "ITL-PROVENANCE.json")

    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    if (Test-Path -LiteralPath $artifactPath) {
        if (-not $Force) { throw "Refusing to replace existing candidate: $artifactPath" }
        Remove-Item -LiteralPath $artifactPath -Force
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::CreateFromDirectory(
        $stageDirectory,
        $artifactPath,
        [System.IO.Compression.CompressionLevel]::Optimal,
        $false
    )

    $candidateProvenance = [ordered]@{
        schemaVersion = 1
        artifactPath = $artifactPath
        artifactSha256 = (Get-Sha256 -Path $artifactPath)
        artifactSize = (Get-Item -LiteralPath $artifactPath).Length
        epfSha256 = (Get-Sha256 -Path (Join-Path $stageDirectory ([string]$manifest.artifact.entryPoint)))
        epfSize = (Get-Item -LiteralPath (Join-Path $stageDirectory ([string]$manifest.artifact.entryPoint))).Length
        manifestSha256 = (Get-Sha256 -Path $manifestPath)
        patchSha256 = (Get-Sha256 -Path $patchPath)
        upstreamCommit = [string]$manifest.upstream.commit
        compatibilityVersion = [string]$manifest.compatibilityVersion
        downstreamRevision = [string]$manifest.downstreamRevision
        platformVersion = $platformVersion
        oneScriptVersion = $oscriptVersion
        opmVersion = $opmVersion
        builtAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    }
    $candidateProvenanceJson = $candidateProvenance | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($provenancePath, $candidateProvenanceJson + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))

    Write-Host "Candidate: $artifactPath"
    Write-Host "SHA256: $($candidateProvenance.artifactSha256)"
    Write-Host "Provenance: $provenancePath"
} finally {
    if ($KeepWork) {
        Write-Host "Build work directory retained: $workDirectory"
    } elseif (Test-Path -LiteralPath $workDirectory) {
        if (-not (Test-PathInside -Candidate $workDirectory -Parent $WorkRoot)) {
            throw "Refusing to remove unsafe work directory: $workDirectory"
        }
        Remove-Item -LiteralPath $workDirectory -Recurse -Force
    }
}
