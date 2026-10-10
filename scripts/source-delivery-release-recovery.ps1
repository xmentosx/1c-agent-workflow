# Mutating publication composition; the Release runner owns all recovery bindings.
function Invoke-DeliveryReleaseStandRecovery {
    param([Parameter(Mandatory = $true)][string]$CandidateRoot)

    if ($script:DeliveryCustomGateBoundary) { return }
    $runner = Join-Path $CandidateRoot 'scripts\invoke-release-e2e.ps1'
    if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) { return }
    $tokens = $null; $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($runner, [ref]$tokens, [ref]$parseErrors)
    if (@($parseErrors).Count -gt 0) { throw "Release recovery runner has parse errors: $runner" }
    # A published master supervisor can qualify an older candidate. Preserve its
    # ordinary readiness path when that candidate predates this internal mode.
    if (-not $ast.ParamBlock -or @($ast.ParamBlock.Parameters | Where-Object {
        $_.Name.VariablePath.UserPath -ceq 'RecoverInterruptedExtensionOnly'
    }).Count -eq 0) { return }
    if (-not $E2EProjectRoot -or -not $AiRulesSource) {
        throw 'Release recovery requires the configured E2E project and exact controlled-fork checkout.'
    }

    $logRoot = Join-Path $CandidateRoot 'build\test-results\delivery'
    [void][IO.Directory]::CreateDirectory($logRoot)
    $stdout = Join-Path $logRoot 'release-stand-recovery.stdout.log'
    $stderr = Join-Path $logRoot 'release-stand-recovery.stderr.log'
    $arguments = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $runner,
        '-ProjectRoot', ([IO.Path]::GetFullPath($E2EProjectRoot)),
        '-AiRulesSource', ([IO.Path]::GetFullPath($AiRulesSource)),
        '-ResumeMode', $ReleaseResumeMode, '-RecoverInterruptedExtensionOnly')
    $clientParameter = Get-Variable -Name AgentTarget -ErrorAction SilentlyContinue
    if ($clientParameter -and -not [string]::IsNullOrWhiteSpace([string]$clientParameter.Value)) {
        $arguments += @('-AgentTarget', [string]$clientParameter.Value)
    }
    $quoted = @($arguments | ForEach-Object { ConvertTo-DeliveryNativeArgument -Value ([string]$_) })
    $process = $null; $job = [IntPtr]::Zero; $priorError = ''
    try {
        $started = Start-DeliveryProcess -ArgumentList ($quoted -join ' ') -WorkingDirectory $CandidateRoot -StandardOutputPath $stdout -StandardErrorPath $stderr
        $process = $started.process; $job = [IntPtr]$started.jobHandle
        # The existing guarded restore owns 7200 seconds; allow its cleanup and
        # process finalization without inheriting an expired capability deadline.
        $watch = [Diagnostics.Stopwatch]::StartNew()
        while (-not $process.WaitForExit(5000)) {
            if ($watch.Elapsed.TotalSeconds -ge 7800) {
                if ($job -ne [IntPtr]::Zero -and $env:OS -eq 'Windows_NT') {
                    [void](Stop-DeliveryProcessJobAndWait -JobHandle $job -Process $process)
                } else { Stop-DeliveryProcessTree -Process $process }
                throw "Release stand recovery exceeded its bounded restore allowance. See $stdout and $stderr"
            }
        }
        $process.WaitForExit(); $process.Refresh()
        if ([int]$process.ExitCode -ne 0) {
            throw "Release stand recovery failed with exit code $($process.ExitCode). See $stdout and $stderr"
        }
        # Exit zero completes only this recovery subphase, never a passed gate.
    } catch { $priorError = $_.Exception.Message; throw } finally {
        $closeError = $null
        try { Close-DeliveryProcessJob -JobHandle $job -Process $process -PriorErrorMessage $priorError } catch { $closeError = $_ }
        Stop-DeliveryProcessTree -Process $process
        if ($closeError) { throw $closeError }
    }
}
