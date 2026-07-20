[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PlanPath,
    [Parameter(Mandatory = $true)][string]$JunitPath,
    [Parameter(Mandatory = $true)][string]$ResultPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$plan = Get-Content -LiteralPath $PlanPath -Raw -Encoding UTF8 | ConvertFrom-Json
$startedAt = [DateTime]::UtcNow
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$result = $null
$failure = $null
try {
    Import-Module Pester -MinimumVersion 5.0.0 -Force
    $configuration = New-PesterConfiguration
    $configuration.Run.Path = @($plan.paths)
    $configuration.Run.PassThru = $true
    $configuration.Output.Verbosity = "Detailed"
    $configuration.TestResult.Enabled = $true
    $configuration.TestResult.OutputFormat = "JUnitXml"
    $configuration.TestResult.OutputPath = $JunitPath
    # Test files own their error policy. In particular, native tools such as Git
    # legitimately write progress to stderr, which PowerShell must not promote
    # to a terminating RemoteException merely because the shard host is strict.
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $result = Invoke-Pester -Configuration $configuration
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ([string]$result.Result -ne "Passed") {
        throw "Pester shard $($plan.worker) did not pass: result=$($result.Result), failed=$($result.FailedCount)."
    }
} catch {
    $failure = $_.Exception.Message
} finally {
    $stopwatch.Stop()
    $payload = [ordered]@{
        schemaVersion = 1
        worker = [int]$plan.worker
        status = $(if ($failure) { "failed" } else { "passed" })
        startedAt = $startedAt.ToString("o")
        finishedAt = [DateTime]::UtcNow.ToString("o")
        durationMs = [int64]$stopwatch.ElapsedMilliseconds
        pesterVersion = $(if (Get-Module Pester) { [string](Get-Module Pester | Select-Object -First 1 -ExpandProperty Version) } else { "" })
        paths = @($plan.paths)
        junitPath = $JunitPath
        passed = $(if ($result) { [int]$result.PassedCount } else { 0 })
        failed = $(if ($result) { [int]$result.FailedCount } else { 1 })
        skipped = $(if ($result) { [int]$result.SkippedCount } else { 0 })
        error = $failure
    }
    [System.IO.File]::WriteAllText($ResultPath, (($payload | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
}

if ($failure) { [Console]::Error.WriteLine($failure); exit 1 }
