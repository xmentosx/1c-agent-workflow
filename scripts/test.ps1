[CmdletBinding()]
param(
    [switch]$CI,
    [string]$OutputFile = "",
    [string[]]$Path = @(),
    [ValidateRange(1, 4)][int]$PesterWorkers = 3
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$repoRoot = Split-Path -Parent $PSScriptRoot
Push-Location $repoRoot
try {
    if ($Path.Count -gt 0) {
        if (-not $OutputFile) { $OutputFile = "build\test-results\focused\testResults.xml" }
        $resolvedOutputFile = if ([System.IO.Path]::IsPathRooted($OutputFile)) {
            [System.IO.Path]::GetFullPath($OutputFile)
        } else {
            [System.IO.Path]::GetFullPath((Join-Path $repoRoot $OutputFile))
        }
        $testRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "tests\pester")).TrimEnd('\') + '\'
        $selected = @($Path | ForEach-Object {
            $candidate = if ([System.IO.Path]::IsPathRooted($_)) { $_ } else { Join-Path $repoRoot $_ }
            $resolved = [System.IO.Path]::GetFullPath($candidate)
            if (-not $resolved.StartsWith($testRoot, [StringComparison]::OrdinalIgnoreCase) -or
                $resolved -notlike "*.Tests.ps1" -or -not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
                throw "Focused Pester path is missing or outside tests/pester: $_"
            }
            $resolved.Substring($repoRoot.TrimEnd('\').Length).TrimStart('\').Replace('\','/')
        } | Sort-Object -Unique)
        $outputRoot = Split-Path -Parent $resolvedOutputFile
        New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
        $selectionPath = Join-Path $outputRoot "selection.json"
        [System.IO.File]::WriteAllText(
            $selectionPath,
            (([ordered]@{ tests = $selected } | ConvertTo-Json -Depth 4) + [Environment]::NewLine),
            [System.Text.UTF8Encoding]::new($false))
        $runnerArguments = @(
            "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass",
            "-File", (Join-Path $PSScriptRoot "invoke-pester-shards.ps1"),
            "-RepositoryRoot", $repoRoot,
            "-OutputRoot", $outputRoot,
            "-JunitPath", $resolvedOutputFile,
            "-WorkerCount", [string]$PesterWorkers,
            "-SelectionPath", $selectionPath
        )
        # Use the same Windows PowerShell host as the authoritative quality gate
        # so the host/Pester fingerprint is reusable by RegisterChange.
        & powershell.exe @runnerArguments
        if ($LASTEXITCODE -ne 0) { throw "Focused Pester shards failed with exit code $LASTEXITCODE." }
        return
    }

    Import-Module Pester -MinimumVersion 5.0.0 -Force

    $configuration = New-PesterConfiguration
    $configuration.Run.Path = @(".\tests\pester")
    $configuration.Run.PassThru = $true
    $configuration.Output.Verbosity = $(if ($CI) { "Detailed" } else { "Normal" })

    if ($CI -and -not $OutputFile) {
        $OutputFile = "build\test-results\pester\testResults.xml"
    }

    if ($CI -or $OutputFile) {
        $resolvedOutputFile = if ([System.IO.Path]::IsPathRooted($OutputFile)) {
            [System.IO.Path]::GetFullPath($OutputFile)
        } else {
            [System.IO.Path]::GetFullPath((Join-Path $repoRoot $OutputFile))
        }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $resolvedOutputFile) | Out-Null
        $configuration.TestResult.Enabled = $true
        $configuration.TestResult.OutputFormat = "JUnitXml"
        $configuration.TestResult.OutputPath = $resolvedOutputFile
    }

    $result = Invoke-Pester -Configuration $configuration
    if ($result.FailedCount -gt 0) {
        exit 1
    }
} finally {
    Pop-Location
}
