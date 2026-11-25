[CmdletBinding()]
param(
    [switch]$CI,
    [string]$OutputFile = "",
    [string[]]$Path = @(),
    [ValidateRange(1, 8)][int]$PesterWorkers = 3,
    # Run exactly the Pester files RegisterChange's Targeted gate would select
    # for the committed and uncommitted change against BaseRef.
    [switch]$Targeted,
    [string]$BaseRef = "origin/develop",
    [string[]]$CoverageContract = @(),
    # With -Targeted: print and write the selection without running it.
    [switch]$ListOnly
)

$pesterWorkersExplicit = $PSBoundParameters.ContainsKey("PesterWorkers")
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$repoRoot = Split-Path -Parent $PSScriptRoot
$originalExecutionGuardFallbackRoot = [Environment]::GetEnvironmentVariable("ITL_TEST_EXECUTION_GUARD_FALLBACK_ROOT", "Process")
$fixtureRuntimeRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-pester-local-" + [guid]::NewGuid().ToString("N"))
[Environment]::SetEnvironmentVariable("ITL_TEST_EXECUTION_GUARD_FALLBACK_ROOT", (Join-Path $fixtureRuntimeRoot "execution-guards-v2"), "Process")
Push-Location $repoRoot
try {
    # Same host environment as check.ps1: a configured PowerShell 7 is on PATH,
    # so Core-host cases run instead of skipping and their proofs are reusable.
    . (Join-Path $PSScriptRoot "release-qualification.ps1")
    [void](Resolve-WorkflowGatePwsh -RepositoryRoot $repoRoot)
    if ($Targeted -and $Path.Count -gt 0) { throw "Use either -Targeted or -Path, not both." }
    if ($ListOnly -and -not $Targeted) { throw "-ListOnly applies only to -Targeted." }
    if ($Targeted -or $Path.Count -gt 0) {
        if (-not $OutputFile) { $OutputFile = "build\test-results\focused\testResults.xml" }
        $resolvedOutputFile = if ([System.IO.Path]::IsPathRooted($OutputFile)) {
            [System.IO.Path]::GetFullPath($OutputFile)
        } else {
            [System.IO.Path]::GetFullPath((Join-Path $repoRoot $OutputFile))
        }
        $outputRoot = Split-Path -Parent $resolvedOutputFile
        New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
        $selectionPath = Join-Path $outputRoot "selection.json"
        if ($Targeted) {
            # The gate's own selector, given the committed range from the
            # merge base plus uncommitted paths, writes the gate's selection
            # (tests and additional inputs), so proofs match registration.
            . (Join-Path $PSScriptRoot "git-path-list.ps1")
            $mergeBase = ([string](Invoke-RepositoryGit -RepositoryRoot $repoRoot -Arguments @("merge-base", $BaseRef, "HEAD")).stdout).Trim()
            if (-not $mergeBase) { throw "Targeted preview found no merge base between '$BaseRef' and HEAD; pass -BaseRef." }
            $uncommitted = @(@(
                Get-RepositoryGitPathList -RepositoryRoot $repoRoot -Arguments @("diff", "--name-only", "-z", "--")
                Get-RepositoryGitPathList -RepositoryRoot $repoRoot -Arguments @("diff", "--cached", "--name-only", "-z", "--")
                Get-RepositoryGitPathList -RepositoryRoot $repoRoot -Arguments @("ls-files", "-z", "--others", "--exclude-standard", "--")
            ) | Where-Object { $_ } | Sort-Object -Unique)
            $selectorArguments = @{ RepositoryRoot = $repoRoot; BaseRef = $mergeBase; OutputPath = $selectionPath }
            if ($uncommitted.Count -gt 0) { $selectorArguments.ChangedPath = $uncommitted }
            if ($CoverageContract.Count -gt 0) { $selectorArguments.CoverageContract = $CoverageContract }
            & (Join-Path $PSScriptRoot "resolve-targeted-tests.ps1") @selectorArguments | Out-Null
            $selection = Get-Content -LiteralPath $selectionPath -Raw -Encoding UTF8 | ConvertFrom-Json
            Write-Host "Targeted preview against $BaseRef ($($mergeBase.Substring(0, 12))): $(@($selection.paths).Count) changed paths select $(@($selection.tests).Count) Pester files:"
            foreach ($test in @($selection.tests)) { Write-Host "  $test" }
            if ($ListOnly) { return }
        } else {
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
        [System.IO.File]::WriteAllText(
            $selectionPath,
            (([ordered]@{ tests = $selected } | ConvertTo-Json -Depth 4) + [Environment]::NewLine),
            [System.Text.UTF8Encoding]::new($false))
        }
        $runnerArguments = @(
            "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass",
            "-File", (Join-Path $PSScriptRoot "invoke-pester-shards.ps1"),
            "-RepositoryRoot", $repoRoot,
            "-OutputRoot", $outputRoot,
            "-JunitPath", $resolvedOutputFile,
            "-WorkerCount", [string]$PesterWorkers,
            "-RequestedWorkerCount", [string]$PesterWorkers,
            "-SelectionPath", $selectionPath
        )
        if (-not $pesterWorkersExplicit) { $runnerArguments += "-WorkerCountDefaulted" }
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
    # Same policy as the gate's shard runner: no test uses TestRegistry.
    if ($configuration.PSObject.Properties['TestRegistry']) { $configuration.TestRegistry.Enabled = $false }
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
    [Environment]::SetEnvironmentVariable("ITL_TEST_EXECUTION_GUARD_FALLBACK_ROOT", $originalExecutionGuardFallbackRoot, "Process")
    if (Test-Path -LiteralPath $fixtureRuntimeRoot -PathType Container) {
        Remove-Item -LiteralPath $fixtureRuntimeRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
