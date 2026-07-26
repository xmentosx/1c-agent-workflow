[CmdletBinding()]
param(
    [string]$ProjectRoot = (Get-Location).Path,
    [string]$SourceRoot = $PSScriptRoot,
    [switch]$NoInit,
    [ValidateSet("wizard", "json", "configured", "resume")]
    [string]$InitMode = "wizard",
    [string]$InitAnswersPath = "",
    [string]$ResumeRunStatusPath = "",
    [ValidateSet("codex", "kilocode", "claude-code", "cursor", "opencode", "kimi", "qwen", "command-code", "cline", "pi")]
    [string]$AgentTarget = "",
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

function Get-BootstrapUtf8Text {
    param([string]$Base64)
    return [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($Base64))
}

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

function Assert-BootstrapProjectRootPathBudget {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)

    $maximumLength = 35
    $resolvedRoot = Resolve-Agent1cFullPath -Path $ProjectRoot
    if ($resolvedRoot.Length -le $maximumLength) {
        return
    }

    $lines = @(
        ((Get-BootstrapUtf8Text "0J3QtdCy0L7Qt9C80L7QttC90L4g0LjQvdC40YbQuNCw0LvQuNC30LjRgNC+0LLQsNGC0Ywg0L/RgNC+0LXQutGCOiDQv9C+0LvQvdGL0Lkg0L/Rg9GC0Ywg0YHQvtC00LXRgNC20LjRgiB7MH0g0YHQuNC80LLQvtC70L7Qsiwg0LHQtdC30L7Qv9Cw0YHQvdGL0Lkg0LzQsNC60YHQuNC80YPQvCDigJQgezF9Lg==") -f $resolvedRoot.Length, $maximumLength),
        ((Get-BootstrapUtf8Text "0J/Rg9GC0Yw6IHswfQ==") -f $resolvedRoot),
        (Get-BootstrapUtf8Text "0J7Qs9GA0LDQvdC40YfQtdC90LjQtSDRgdCy0Y/Qt9Cw0L3QviDRgSBNQVhfUEFUSD0yNjAg0Lgg0LTQu9C40L3QvdGL0LzQuCDQuNC80LXQvdCw0LzQuCDRhNCw0LnQu9C+0LIg0LjRgdGF0L7QtNC90LjQutC+0LIg0LrQvtC90YTQuNCz0YPRgNCw0YbQuNC5INC4INGA0LDRgdGI0LjRgNC10L3QuNC5IDHQoS4=")
    )

    $profileRoot = [Environment]::GetFolderPath("UserProfile")
    if (-not [string]::IsNullOrWhiteSpace($profileRoot)) {
        $profileRoot = Resolve-Agent1cFullPath -Path $profileRoot
        $profilePrefix = $profileRoot.TrimEnd("\", "/") + "\"
        if ($resolvedRoot.StartsWith($profilePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            $recommendedParent = Join-Path $profileRoot "W"
            $maximumProjectNameLength = $maximumLength - $recommendedParent.Length - 1
            if ($maximumProjectNameLength -gt 0) {
                $lines += @(
                    (Get-BootstrapUtf8Text "0JTQu9GPINC/0YDQvtC10LrRgtCwINCyINC/0YDQvtGE0LjQu9C1INC/0L7Qu9GM0LfQvtCy0LDRgtC10LvRjyDRgNC10LrQvtC80LXQvdC00YPQtdGC0YHRjyDRgdC+0LfQtNCw0YLRjCDQutC+0YDQvtGC0LrQuNC5INGA0LDQsdC+0YfQuNC5INC60LDRgtCw0LvQvtCzOg=="),
                    $recommendedParent,
                    ((Get-BootstrapUtf8Text "0JIg0L3RkdC8INC40LzRjyDQv9Cw0L/QutC4INC/0YDQvtC10LrRgtCwINC80L7QttC10YIg0YHQvtC00LXRgNC20LDRgtGMINC90LUg0LHQvtC70LXQtSB7MH0g0YHQuNC80LLQvtC70L7Qsi4=") -f $maximumProjectNameLength)
                )
            }
        }
    }

    throw ($lines -join [Environment]::NewLine)
}

function Invoke-BootstrapGitCapture {
    param(
        [string]$Root,
        [string[]]$Arguments
    )

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = @(& git -C $Root @Arguments 2>$null)
        if ($LASTEXITCODE -ne 0) {
            return @()
        }
        return @($output | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

function Resolve-BootstrapWorkflowPackageProvenance {
    param([string]$Root)

    $result = [ordered]@{
        repo = ""
        ref = ""
        commit = ""
        source = "path"
    }
    $commit = @(Invoke-BootstrapGitCapture -Root $Root -Arguments @("rev-parse", "HEAD") | Select-Object -First 1)
    if ($commit.Count -eq 0) {
        return [pscustomobject]$result
    }
    $commitText = [string]$commit[0]
    if ($commitText -notmatch '^[0-9a-fA-F]{40}$') {
        throw "Workflow package source returned an invalid Git commit: $commitText"
    }

    $origin = @(Invoke-BootstrapGitCapture -Root $Root -Arguments @("remote", "get-url", "origin") | Select-Object -First 1)
    if ($origin.Count -gt 0) {
        $result.repo = [string]$origin[0]
    }
    $branch = @(Invoke-BootstrapGitCapture -Root $Root -Arguments @("symbolic-ref", "--quiet", "--short", "HEAD") | Select-Object -First 1)
    if ($branch.Count -gt 0) {
        $result.ref = [string]$branch[0]
    } else {
        $tags = @(Invoke-BootstrapGitCapture -Root $Root -Arguments @("tag", "--points-at", "HEAD"))
        $result.ref = $(if ($tags.Count -eq 1) { [string]$tags[0] } else { $commitText })
    }
    $result.commit = $commitText.ToLowerInvariant()
    return [pscustomobject]$result
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
        ".agents\skills\itl-vanessa-ui-mcp\SKILL.md",
        "templates\project.json",
        "templates\dependency-lock.json",
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
if (-not $NoInit) {
    Assert-BootstrapProjectRootPathBudget -ProjectRoot $projectRootFull
}
New-Item -ItemType Directory -Force -Path $projectRootFull | Out-Null

Write-Host "Installing ITL workflow package."
Write-Host "Source: $sourceRootFull"
Write-Host "Project: $projectRootFull"

foreach ($relativePath in @(
    ".agents\skills\1c-workflow",
    ".agents\skills\1c-workflow-fast",
    ".agents\skills\product-docs",
    ".agents\skills\itl-roctup-1c-data",
    ".agents\skills\itl-vanessa-ui-mcp",
    "docs\itl-workflow",
    "templates"
)) {
    Copy-ManagedDirectory -SourceRoot $sourceRootFull -TargetRoot $projectRootFull -RelativePath $relativePath
}

foreach ($relativePath in @(
    "install-agent-1c-workflow.ps1",
    "AGENT-INSTALL.md"
)) {
    Copy-ManagedFile -SourceRoot $sourceRootFull -TargetRoot $projectRootFull -RelativePath $relativePath
}

if ($NoInit) {
    Write-Host "Initialization skipped because -NoInit was specified."
    exit 0
}

$workflowProvenance = Resolve-BootstrapWorkflowPackageProvenance -Root $sourceRootFull

$launcherPath = Join-Path $projectRootFull ".agents\skills\1c-workflow\scripts\run-agent-1c-window.ps1"
if (-not (Test-Path -LiteralPath $launcherPath -PathType Leaf -ErrorAction SilentlyContinue)) {
    throw "Installed monitored launcher was not found: $launcherPath"
}

$initArgs = @("-Action", "init-project", "-InitMode", $InitMode)
if ($AgentTarget) {
    $initArgs += @("-AgentTarget", $AgentTarget)
}
foreach ($provenanceArgument in @(
    @{ name = "-BootstrapWorkflowRepo"; value = [string]$workflowProvenance.repo },
    @{ name = "-BootstrapWorkflowRef"; value = [string]$workflowProvenance.ref },
    @{ name = "-BootstrapWorkflowCommit"; value = [string]$workflowProvenance.commit },
    @{ name = "-BootstrapWorkflowSource"; value = [string]$workflowProvenance.source }
)) {
    if (-not [string]::IsNullOrWhiteSpace($provenanceArgument.value)) {
        $initArgs += @($provenanceArgument.name, $provenanceArgument.value)
    }
}
if ($InitAnswersPath) {
    $answersFull = if ([System.IO.Path]::IsPathRooted($InitAnswersPath)) {
        Resolve-Agent1cFullPath -Path $InitAnswersPath
    } else {
        Resolve-Agent1cFullPath -Path (Join-Path $callerRoot $InitAnswersPath)
    }
    $initArgs += @("-InitAnswersPath", $answersFull)
}
if ($ResumeRunStatusPath) {
    $resumeStatusFull = if ([System.IO.Path]::IsPathRooted($ResumeRunStatusPath)) {
        Resolve-Agent1cFullPath -Path $ResumeRunStatusPath
    } else {
        Resolve-Agent1cFullPath -Path (Join-Path $projectRootFull $ResumeRunStatusPath)
    }
    $initArgs += @("-ResumeRunStatusPath", $resumeStatusFull)
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
