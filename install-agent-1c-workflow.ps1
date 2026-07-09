[CmdletBinding()]
param(
    [string]$ProjectRoot = (Get-Location).Path,
    [string]$SourceRoot = $PSScriptRoot,
    [switch]$NoInit,
    [ValidateSet("wizard", "json", "configured")]
    [string]$InitMode = "wizard",
    [string]$InitAnswersPath = "",
    [int]$InitMaxWaitSeconds = 3600,
    [switch]$KeepWindowOnFailure
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$utf8 = New-Object System.Text.UTF8Encoding $false
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8

if ($InitMaxWaitSeconds -lt 0) {
    throw "InitMaxWaitSeconds must be 0 or greater."
}

function Normalize-Agent1cFullPathText {
    param([string]$Path)

    if ([string]::IsNullOrEmpty($Path)) {
        return $Path
    }

    $root = [System.IO.Path]::GetPathRoot($Path)
    $trimmed = $Path.TrimEnd("\", "/")
    if ([string]::IsNullOrEmpty($trimmed)) {
        return $Path
    }

    if ($root -and $trimmed -eq $root.TrimEnd("\", "/")) {
        return $root
    }
    return $trimmed
}

function Resolve-Agent1cFullPath {
    param([AllowNull()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }

    $full = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Path))
    if (Test-Path -LiteralPath $full -ErrorAction SilentlyContinue) {
        try {
            return (Normalize-Agent1cFullPathText -Path (Get-Item -LiteralPath $full -ErrorAction Stop).FullName)
        } catch {
        }
    }

    $segments = [System.Collections.Generic.List[string]]::new()
    $current = $full
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        if (Test-Path -LiteralPath $current -ErrorAction SilentlyContinue) {
            try {
                $resolved = (Get-Item -LiteralPath $current -ErrorAction Stop).FullName
                for ($i = $segments.Count - 1; $i -ge 0; $i--) {
                    $resolved = Join-Path $resolved $segments[$i]
                }
                return (Normalize-Agent1cFullPathText -Path $resolved)
            } catch {
            }
        }

        $parent = Split-Path -Parent $current
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $current) {
            break
        }

        $leaf = Split-Path -Leaf $current
        if (-not [string]::IsNullOrEmpty($leaf)) {
            $segments.Add($leaf) | Out-Null
        }
        $current = $parent
    }

    return (Normalize-Agent1cFullPathText -Path $full)
}

function Get-FullPathNormalized {
    param([string]$Path)

    return (Resolve-Agent1cFullPath -Path $Path)
}

function Assert-SourcePackage {
    param([string]$Root)

    foreach ($relativePath in @(
        "install-agent-1c-workflow.ps1",
        "AGENT-INSTALL.md",
        ".agents\skills\1c-workflow\scripts\run-agent-1c-window.ps1",
        ".agents\skills\1c-workflow-fast\SKILL.md",
        ".agents\skills\product-docs\SKILL.md",
        ".agents\skills\itl-roctup-1c-data\SKILL.md",
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

$projectRootFull = Resolve-Agent1cFullPath -Path $ProjectRoot
$sourceRootFull = Resolve-Agent1cFullPath -Path $SourceRoot
$callerRoot = Resolve-Agent1cFullPath -Path (Get-Location).Path

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
    ".agents\skills\product-docs",
    ".agents\skills\itl-roctup-1c-data",
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
        Resolve-Agent1cFullPath -Path $InitAnswersPath
    } else {
        Resolve-Agent1cFullPath -Path (Join-Path $callerRoot $InitAnswersPath)
    }
    $initArgs += @("-InitAnswersPath", $answersFull)
}

$launcherArgs = @()
if ($KeepWindowOnFailure) {
    $launcherArgs += "-KeepWindowOnFailure"
}
$launcherArgs += @("-MaxWaitSeconds", [string]$InitMaxWaitSeconds)
$launcherArgs += @("--") + $initArgs

Write-Host "Starting monitored ITL initialization."
Push-Location (Resolve-Agent1cFullPath -Path $projectRootFull)
try {
    & powershell -ExecutionPolicy Bypass -File $launcherPath @launcherArgs
    if ($LASTEXITCODE -is [int] -and $LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
} finally {
    Pop-Location
}
