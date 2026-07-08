[CmdletBinding()]
param(
    [string]$ProjectRoot = (Get-Location).Path,
    [string]$SourceRoot = $PSScriptRoot,
    [switch]$NoInit,
    [ValidateSet("wizard", "json", "configured")]
    [string]$InitMode = "wizard",
    [string]$InitAnswersPath = "",
    [switch]$KeepWindowOnFailure
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$utf8 = New-Object System.Text.UTF8Encoding $false
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8

function Get-FullPathNormalized {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }
    return [System.IO.Path]::GetFullPath($Path).TrimEnd("\", "/")
}

function Assert-SourcePackage {
    param([string]$Root)

    foreach ($relativePath in @(
        "install-agent-1c-workflow.ps1",
        "AGENT-INSTALL.md",
        ".agents\skills\1c-workflow\scripts\run-agent-1c-window.ps1",
        ".agents\skills\1c-workflow-fast\SKILL.md",
        "templates\project.json",
        "templates\USER-RULES.append.md"
    )) {
        $path = Join-Path $Root $relativePath
        if (-not (Test-Path -LiteralPath $path -ErrorAction SilentlyContinue)) {
            throw "ITL workflow package source is missing required file '$relativePath': $Root"
        }
    }
}

function Assert-ManagedTargetPath {
    param(
        [string]$Root,
        [string]$Path
    )

    $rootFull = Get-FullPathNormalized $Root
    $targetFull = Get-FullPathNormalized $Path
    if ($targetFull -eq $rootFull) {
        throw "Refusing to replace project root as a managed workflow path: $targetFull"
    }
    if (-not $targetFull.StartsWith(($rootFull + "\"), [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to copy a managed workflow path outside project root: $targetFull"
    }
}

function Copy-ManagedDirectory {
    param(
        [string]$SourceRoot,
        [string]$TargetRoot,
        [string]$RelativePath
    )

    $sourcePath = Join-Path $SourceRoot $RelativePath
    $targetPath = Join-Path $TargetRoot $RelativePath
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Container -ErrorAction SilentlyContinue)) {
        throw "Managed workflow directory is missing: $RelativePath"
    }

    Assert-ManagedTargetPath -Root $TargetRoot -Path $targetPath
    if ((Get-FullPathNormalized $sourcePath) -eq (Get-FullPathNormalized $targetPath)) {
        Write-Host "Managed directory already present: $RelativePath"
        return
    }

    $parent = Split-Path -Parent $targetPath
    if ($parent) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    if (Test-Path -LiteralPath $targetPath -ErrorAction SilentlyContinue) {
        Remove-Item -LiteralPath $targetPath -Recurse -Force
    }
    Copy-Item -LiteralPath $sourcePath -Destination $targetPath -Recurse -Force
    Write-Host "Installed workflow directory: $RelativePath"
}

function Copy-ManagedFile {
    param(
        [string]$SourceRoot,
        [string]$TargetRoot,
        [string]$RelativePath
    )

    $sourcePath = Join-Path $SourceRoot $RelativePath
    $targetPath = Join-Path $TargetRoot $RelativePath
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf -ErrorAction SilentlyContinue)) {
        throw "Managed workflow file is missing: $RelativePath"
    }

    Assert-ManagedTargetPath -Root $TargetRoot -Path $targetPath
    if ((Get-FullPathNormalized $sourcePath) -eq (Get-FullPathNormalized $targetPath)) {
        Write-Host "Managed file already present: $RelativePath"
        return
    }

    $parent = Split-Path -Parent $targetPath
    if ($parent) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    Copy-Item -LiteralPath $sourcePath -Destination $targetPath -Force
    Write-Host "Installed workflow file: $RelativePath"
}

$scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if ([string]::IsNullOrWhiteSpace($SourceRoot)) {
    $SourceRoot = $scriptRoot
}

$projectRootFull = [System.IO.Path]::GetFullPath($ProjectRoot)
$sourceRootFull = [System.IO.Path]::GetFullPath($SourceRoot)
$callerRoot = (Get-Location).Path

if (-not (Test-Path -LiteralPath $sourceRootFull -PathType Container -ErrorAction SilentlyContinue)) {
    throw "ITL workflow package source was not found: $sourceRootFull"
}

Assert-SourcePackage -Root $sourceRootFull
New-Item -ItemType Directory -Force -Path $projectRootFull | Out-Null

Write-Host "Installing ITL workflow package."
Write-Host "Source: $sourceRootFull"
Write-Host "Project: $projectRootFull"

foreach ($relativePath in @(
    ".agents\skills\1c-workflow",
    ".agents\skills\1c-workflow-fast",
    "templates"
)) {
    Copy-ManagedDirectory -SourceRoot $sourceRootFull -TargetRoot $projectRootFull -RelativePath $relativePath
}

foreach ($relativePath in @(
    "install-agent-1c-workflow.ps1",
    "README.md",
    "AGENT-INSTALL.md",
    "DEVELOPER-GUIDE.ru.md",
    "DEV-BRANCH-DEVELOPMENT.ru.md",
    "VANESSA-TESTS-GUIDE.md",
    "VANESSA-TESTS-GUIDE.ru.md"
)) {
    Copy-ManagedFile -SourceRoot $sourceRootFull -TargetRoot $projectRootFull -RelativePath $relativePath
}

if ($NoInit) {
    Write-Host "Initialization skipped because -NoInit was specified."
    exit 0
}

$launcherPath = Join-Path $projectRootFull ".agents\skills\1c-workflow\scripts\run-agent-1c-window.ps1"
if (-not (Test-Path -LiteralPath $launcherPath -PathType Leaf -ErrorAction SilentlyContinue)) {
    throw "Installed monitored launcher was not found: $launcherPath"
}

$initArgs = @("-Action", "init-project", "-InitMode", $InitMode)
if ($InitAnswersPath) {
    $answersFull = if ([System.IO.Path]::IsPathRooted($InitAnswersPath)) {
        [System.IO.Path]::GetFullPath($InitAnswersPath)
    } else {
        [System.IO.Path]::GetFullPath((Join-Path $callerRoot $InitAnswersPath))
    }
    $initArgs += @("-InitAnswersPath", $answersFull)
}

$launcherArgs = @()
if ($KeepWindowOnFailure) {
    $launcherArgs += "-KeepWindowOnFailure"
}
$launcherArgs += @("--") + $initArgs

Write-Host "Starting monitored ITL initialization."
Push-Location $projectRootFull
try {
    & powershell -ExecutionPolicy Bypass -File $launcherPath @launcherArgs
    if ($LASTEXITCODE -is [int] -and $LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
} finally {
    Pop-Location
}
