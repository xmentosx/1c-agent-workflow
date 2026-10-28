[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Run')][string]$PlanPath,
    [Parameter(Mandatory = $true, ParameterSetName = 'Run')][string]$JunitPath,
    [Parameter(Mandatory = $true)][string]$ResultPath,
    [Parameter(Mandatory = $true, ParameterSetName = 'Runtime')][switch]$RuntimeIdentityOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $utf8NoBom
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding = $utf8NoBom

. (Join-Path $PSScriptRoot 'invoke-pester-runtime.ps1')
Initialize-PesterShardModulePath
if ($RuntimeIdentityOnly) {
    try {
        Import-Module Pester -MinimumVersion 5.0.0 -Force
        $receipt = Get-PesterShardRuntimeReceipt
    } catch {
        $receipt = [pscustomobject]@{status='unknown';identity=$null;reason=$_.Exception.Message;durationMs=0}
    }
    [IO.File]::WriteAllText($ResultPath, ($receipt | ConvertTo-Json -Depth 6), $utf8NoBom)
    exit 0
}

$plan = Get-Content -LiteralPath $PlanPath -Raw -Encoding UTF8 | ConvertFrom-Json
$fixtureRuntimeRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-pester-worker-{0}-{1}" -f [int]$plan.worker, [guid]::NewGuid().ToString("N"))
$env:ITL_ONDEMAND_MCP_INSTALL_ROOT = Join-Path $fixtureRuntimeRoot "ondemand"
$env:ITL_TEST_EXECUTION_GUARD_FALLBACK_ROOT = Join-Path $fixtureRuntimeRoot "execution-guards-v2"
# Fixtures declare their own client; never the agent hosting this gate.
$env:ITL_TEST_AGENT_HOST_ISOLATED = "1"
$startedAt = [DateTime]::UtcNow
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$result = $null
$failure = $null
$runtimeBefore = $null
$runtimeAfter = $null
try {
    $expectedRuntime = $plan.PSObject.Properties['runtimeIdentity']
    if ($expectedRuntime -and $expectedRuntime.Value) {
        try { Import-Module -Name ([string]$expectedRuntime.Value.pesterManifestPath) -MinimumVersion 5.0.0 -Force }
        catch { Import-Module Pester -MinimumVersion 5.0.0 -Force }
    } else { Import-Module Pester -MinimumVersion 5.0.0 -Force }
    $runtimeBefore = Get-PesterShardRuntimeReceipt
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
    $runtimeAfter = Get-PesterShardRuntimeReceipt
    $runtime = $null
    $runtimeReason = [string]$runtimeAfter.reason
    if ($runtimeBefore -and $runtimeBefore.status -eq 'known' -and $runtimeAfter.status -eq 'known') {
        if ($runtimeBefore.identity.identitySha256 -ceq $runtimeAfter.identity.identitySha256) { $runtime = $runtimeAfter.identity }
        else { $runtimeReason = 'Runtime inputs changed during execution; this passed result cannot qualify reuse.' }
    }
    [Environment]::SetEnvironmentVariable("ITL_ONDEMAND_MCP_INSTALL_ROOT", $null, "Process")
    [Environment]::SetEnvironmentVariable("ITL_TEST_EXECUTION_GUARD_FALLBACK_ROOT", $null, "Process")
    [Environment]::SetEnvironmentVariable("ITL_TEST_AGENT_HOST_ISOLATED", $null, "Process")
    if (Test-Path -LiteralPath $fixtureRuntimeRoot -PathType Container) {
        Remove-Item -LiteralPath $fixtureRuntimeRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    $stopwatch.Stop()
    $payload = [ordered]@{
        schemaVersion = 1
        worker = [int]$plan.worker
        status = $(if ($failure) { "failed" } else { "passed" })
        startedAt = $startedAt.ToString("o")
        finishedAt = [DateTime]::UtcNow.ToString("o")
        durationMs = [int64]$stopwatch.ElapsedMilliseconds
        pesterVersion = $(if (Get-Module Pester) { [string](Get-Module Pester | Select-Object -First 1 -ExpandProperty Version) } else { "" })
        runtimeIdentity = $runtime
        runtimeIdentityReason = $runtimeReason
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
