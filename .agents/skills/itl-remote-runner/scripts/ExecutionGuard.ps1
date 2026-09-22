# Private pipe adapter for the execution-guards-v2 supervisor. The Python host
# owns the OS handles; JSON records are diagnostic only.
function Get-ItlExecutionGuardRequestValue {
    param([Parameter(Mandatory = $true)][object]$Request, [Parameter(Mandatory = $true)][string]$Name, [AllowNull()][object]$Default = $null)
    if ($Request -is [Collections.IDictionary]) {
        if ($Request.Contains($Name)) { return $Request[$Name] }
        return $Default
    }
    $property = $Request.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $Default
}

function Read-ItlExecutionGuardHostEvent {
    param([Parameter(Mandatory = $true)][object]$Owner, [double]$TimeoutSeconds = 30)

    $timer = [Diagnostics.Stopwatch]::StartNew()
    $read = $Owner.process.StandardOutput.ReadLineAsync()
    while (-not $read.IsCompleted) {
        if ($timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) { throw 'EXECUTION_GUARD_HOST_RESPONSE_TIMEOUT' }
        Start-Sleep -Milliseconds 20
    }
    $line = $read.GetAwaiter().GetResult()
    if ($null -eq $line) {
        $detail = ''
        try {
            if (-not $Owner.process.HasExited) { [void]$Owner.process.WaitForExit(1000) }
            if ($null -ne $Owner.stderr -and $Owner.stderr.IsCompleted) { $detail = [string]$Owner.stderr.GetAwaiter().GetResult() }
        } catch { }
        throw ('EXECUTION_GUARD_HOST_DISCONNECTED' + $(if ($detail) { ': ' + $detail.Trim() } else { '' }))
    }
    try { $event = $line | ConvertFrom-Json -ErrorAction Stop } catch { throw 'EXECUTION_GUARD_HOST_RESPONSE_INVALID' }
    if ($null -eq $event -or -not $event.PSObject.Properties['event']) { throw 'EXECUTION_GUARD_HOST_RESPONSE_INVALID' }
    if ($event.event -eq 'error') { throw ([string]$event.error) }
    return $event
}

function Close-ItlExecutionGuardHost {
    param([AllowNull()][object]$Owner)

    if ($null -eq $Owner -or $Owner.closed) { return }
    try {
        try { $Owner.process.StandardInput.Close() } catch [IO.IOException] { }
        if (-not $Owner.process.WaitForExit(5000)) {
            $Owner.process.Kill()
            if (-not $Owner.process.WaitForExit(5000)) { throw 'EXECUTION_GUARD_HOST_EXIT_UNCONFIRMED' }
        }
    } finally {
        $Owner.closed = $true
        $Owner.process.Dispose()
    }
}

function Start-ItlExecutionGuardHost {
    param(
        [Parameter(Mandatory = $true)][object]$Request,
        [string]$Python = '',
        [scriptblock]$OnProgress
    )

    if (-not (Get-Command Join-NativeCommandLineArguments -CommandType Function -ErrorAction SilentlyContinue)) {
        throw 'EXECUTION_GUARD_SHARED_QUOTING_REQUIRED'
    }
    $timeout = [double](Get-ItlExecutionGuardRequestValue -Request $Request -Name 'timeout' -Default 3600)
    if ([double]::IsNaN($timeout) -or [double]::IsInfinity($timeout) -or $timeout -le 0 -or $timeout -gt 86400) {
        throw 'EXECUTION_GUARD_WAIT_TIMEOUT_INVALID'
    }
    $cancelPath = [string](Get-ItlExecutionGuardRequestValue -Request $Request -Name 'cancelPath' -Default '')
    if ($cancelPath -and (Test-Path -LiteralPath $cancelPath -PathType Leaf)) { throw 'EXECUTION_GUARD_CANCELLED' }
    . (Join-Path $PSScriptRoot 'PythonRuntime.ps1')
    $Python = Resolve-ItlPythonExecutable -Python $Python

    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Python
    $start.Arguments = Join-NativeCommandLineArguments -Arguments @('-B','-X','utf8','-u','-m','itl_remote.execution_guard_host')
    $start.WorkingDirectory = $PSScriptRoot
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $start.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    $start.EnvironmentVariables['PYTHONPATH'] = $PSScriptRoot
    $start.EnvironmentVariables['PYTHONUTF8'] = '1'
    $start.EnvironmentVariables['PYTHONIOENCODING'] = 'utf-8'
    $start.EnvironmentVariables['PYTHONDONTWRITEBYTECODE'] = '1'
    $start.EnvironmentVariables['PYTHONNOUSERSITE'] = '1'
    $start.EnvironmentVariables.Remove('PYTHONHOME')
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    $owner = [pscustomobject]@{process=$process;closed=$false;stderr=$null;executionId='';resources=@();proof=$null}
    $started = $false
    try {
        if (-not $process.Start()) { throw 'EXECUTION_GUARD_HOST_START_FAILED' }
        $started = $true
        $owner.stderr = $process.StandardError.ReadToEndAsync()
        $payload = $Request | ConvertTo-Json -Depth 40 -Compress
        $ascii = [Text.RegularExpressions.Regex]::Replace($payload, '[^\x00-\x7f]', {
            param($match)
            return ('\u{0:x4}' -f [int][char]$match.Value)
        })
        $process.StandardInput.WriteLine($ascii)
        $process.StandardInput.Flush()
        $timer = [Diagnostics.Stopwatch]::StartNew()
        while ($true) {
            $remaining = ($timeout + 30) - $timer.Elapsed.TotalSeconds
            if ($remaining -le 0) { throw 'EXECUTION_GUARD_HOST_RESPONSE_TIMEOUT' }
            $event = Read-ItlExecutionGuardHostEvent -Owner $owner -TimeoutSeconds $remaining
            if ($event.event -eq 'admitted') {
                if ($event.executionId -notmatch '^[a-f0-9]{32}$' -or -not $event.executionContext -or -not $event.executionContextKey -or @($event.resources).Count -eq 0) {
                    throw 'EXECUTION_GUARD_HOST_PROOF_INVALID'
                }
                $owner.executionId = [string]$event.executionId
                $owner.resources = @($event.resources)
                $owner.proof = [pscustomobject]@{encoded=[string]$event.executionContext;key=[string]$event.executionContextKey;executionId=[string]$event.executionId;resources=@($event.resources)}
                if ($cancelPath -and (Test-Path -LiteralPath $cancelPath -PathType Leaf)) {
                    Complete-ItlExecutionGuardHost -Owner $owner -Result cancelled | Out-Null
                    throw 'EXECUTION_GUARD_CANCELLED'
                }
                return $owner
            }
            if ($event.event -ne 'waiting' -or $event.status -ne 'waiting-for-base') { throw 'EXECUTION_GUARD_HOST_RESPONSE_INVALID' }
            if ($OnProgress) { & $OnProgress $event | Out-Null } else { Write-Host ('EXECUTION_GUARD_WAIT ' + ($event | ConvertTo-Json -Depth 10 -Compress)) }
        }
    } catch {
        if ($started) { Close-ItlExecutionGuardHost -Owner $owner } else { $process.Dispose() }
        throw
    }
}

function Assert-ItlExecutionGuardHost {
    param([Parameter(Mandatory = $true)][object]$Owner)
    if ($Owner.closed) { throw 'EXECUTION_GUARD_HOST_ALREADY_CLOSED' }
    $Owner.process.StandardInput.WriteLine('{"action":"validate"}')
    $Owner.process.StandardInput.Flush()
    $event = Read-ItlExecutionGuardHostEvent -Owner $Owner -TimeoutSeconds 30
    if ($event.event -ne 'validated' -or $event.executionId -cne $Owner.executionId) { throw 'EXECUTION_GUARD_HOST_VALIDATION_UNCONFIRMED' }
    return $event
}

function Complete-ItlExecutionGuardHost {
    param(
        [Parameter(Mandatory = $true)][object]$Owner,
        [ValidateSet('succeeded','failed','interrupted','cancelled')][string]$Result,
        [string]$ErrorMessage = '',
        [string[]]$Artifacts = @()
    )
    if ($Owner.closed) { throw 'EXECUTION_GUARD_HOST_ALREADY_CLOSED' }
    try {
        $message = [pscustomobject]@{action='release';result=$Result;error=$ErrorMessage;artifacts=@($Artifacts)} | ConvertTo-Json -Depth 5 -Compress
        $ascii = [Text.RegularExpressions.Regex]::Replace($message, '[^\x00-\x7f]', { param($match) ('\u{0:x4}' -f [int][char]$match.Value) })
        $Owner.process.StandardInput.WriteLine($ascii)
        $Owner.process.StandardInput.Flush()
        $event = Read-ItlExecutionGuardHostEvent -Owner $Owner -TimeoutSeconds 30
        if ($event.event -ne 'released' -or $event.status -cne $Result -or $event.executionId -cne $Owner.executionId) {
            throw 'EXECUTION_GUARD_HOST_RELEASE_UNCONFIRMED'
        }
        if (-not $Owner.process.WaitForExit(5000) -or $Owner.process.ExitCode -ne 0) { throw 'EXECUTION_GUARD_HOST_RELEASE_UNCONFIRMED' }
        return $event
    } finally { Close-ItlExecutionGuardHost -Owner $Owner }
}
