# Private pipe adapter. The caller resolves its complete database set before
# taking project/runtime locks and keeps this owner through operation cleanup.
function Read-ItlDatabaseAccessHostEvent {
    param([Parameter(Mandatory = $true)][object]$Owner, [double]$TimeoutSeconds = 30, [string]$CancelPath = '')

    $timer = [Diagnostics.Stopwatch]::StartNew()
    $cancelSent = $false
    $read = $Owner.process.StandardOutput.ReadLineAsync()
    while (-not $read.IsCompleted) {
        if ($CancelPath -and -not $cancelSent -and (Test-Path -LiteralPath $CancelPath -PathType Leaf)) {
            $Owner.process.StandardInput.WriteLine('{"event":"cancel"}')
            $Owner.process.StandardInput.Flush()
            $cancelSent = $true
        }
        if ($timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
            throw 'INFOBASE_ACCESS_HOST_RESPONSE_TIMEOUT'
        }
        Start-Sleep -Milliseconds 20
    }
    $line = $read.GetAwaiter().GetResult()
    if ($null -eq $line) { throw 'INFOBASE_ACCESS_HOST_DISCONNECTED' }
    try { $event = $line | ConvertFrom-Json -ErrorAction Stop } catch { throw 'INFOBASE_ACCESS_HOST_RESPONSE_INVALID' }
    if ($null -eq $event -or -not $event.PSObject.Properties['event']) { throw 'INFOBASE_ACCESS_HOST_RESPONSE_INVALID' }
    if ($event.event -eq 'error') { throw ([string]$event.error) }
    return $event
}

function Close-ItlDatabaseAccessHost {
    param([AllowNull()][object]$Owner)

    if ($null -eq $Owner -or $Owner.closed) { return }
    try {
        # EOF without release deliberately retains recovery debt after admission.
        try { $Owner.process.StandardInput.Close() } catch [IO.IOException] { }
        if (-not $Owner.process.WaitForExit(5000)) {
            # This is the exact pipe host we launched, never a 1C process/PID scan.
            $Owner.process.Kill()
            if (-not $Owner.process.WaitForExit(5000)) { throw 'INFOBASE_ACCESS_HOST_EXIT_UNCONFIRMED' }
        }
    } finally {
        $Owner.closed = $true
        $Owner.process.Dispose()
    }
}

function Start-ItlDatabaseAccessHost {
    param(
        [Parameter(Mandatory = $true)][object]$Request,
        [string]$Python = '',
        [string]$CancelPath = '',
        [scriptblock]$OnProgress
    )

    if (-not (Get-Command Join-NativeCommandLineArguments -CommandType Function -ErrorAction SilentlyContinue)) {
        throw 'INFOBASE_ACCESS_SHARED_QUOTING_REQUIRED'
    }
    if ($CancelPath -and (Test-Path -LiteralPath $CancelPath -PathType Leaf)) {
        throw 'INFOBASE_ACCESS_PARENT_CANCELLED'
    }
    . (Join-Path $PSScriptRoot 'PythonRuntime.ps1')
    $Python = Resolve-ItlPythonExecutable -Python $Python
    if ($CancelPath -and (Test-Path -LiteralPath $CancelPath -PathType Leaf)) { throw 'INFOBASE_ACCESS_PARENT_CANCELLED' }
    $budget = 3600.0
    if (($Request -is [Collections.IDictionary] -and $Request.Contains('timeout')) -or
        $null -ne $Request.PSObject.Properties['timeout']) { $budget = [double]$Request.timeout }
    if ([double]::IsNaN($budget) -or [double]::IsInfinity($budget) -or $budget -lt 0 -or $budget -gt 86400) {
        throw 'INFOBASE_ACCESS_TIMEOUT_INVALID'
    }
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $Python
    $start.Arguments = Join-NativeCommandLineArguments -Arguments @('-B', '-X', 'utf8', '-u', '-m', 'itl_remote.access_host')
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
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    $owner = [pscustomobject]@{ process = $process; proof = $null; public = $null; closed = $false; stderr = $null }
    $started = $false
    try {
        if (-not $process.Start()) { throw 'INFOBASE_ACCESS_HOST_START_FAILED' }
        $started = $true
        $owner.stderr = $process.StandardError.ReadToEndAsync()
        # ensure_ascii JSON avoids the PS5.1 stdin encoding default. The proof
        # stays on private pipes; never emit the request or admitted event.
        $payload = $Request | ConvertTo-Json -Depth 40 -Compress
        $ascii = [Text.RegularExpressions.Regex]::Replace($payload, '[^\x00-\x7f]', {
            param($match)
            return ('\u{0:x4}' -f [int][char]$match.Value)
        })
        $process.StandardInput.WriteLine($ascii)
        $process.StandardInput.Flush()
        $timer = [Diagnostics.Stopwatch]::StartNew()
        while ($true) {
            $remaining = ($budget + 30) - $timer.Elapsed.TotalSeconds
            if ($remaining -le 0) { throw 'INFOBASE_ACCESS_HOST_RESPONSE_TIMEOUT' }
            $event = Read-ItlDatabaseAccessHostEvent -Owner $owner -TimeoutSeconds $remaining -CancelPath $CancelPath
            if ($event.event -eq 'admitted') {
                if ($null -eq $event.proof -or $event.proof.ticket -notmatch '^[a-f0-9]{32}$' -or -not $event.proof.token) {
                    throw 'INFOBASE_ACCESS_HOST_PROOF_INVALID'
                }
                $owner.proof = $event.proof
                $owner.public = $event.owner
                if ($CancelPath -and (Test-Path -LiteralPath $CancelPath -PathType Leaf)) {
                    # The API has not returned control: no native operation has
                    # started under this grant, so it can explicitly release it.
                    Complete-ItlDatabaseAccessHost -Owner $owner | Out-Null
                    throw 'INFOBASE_ACCESS_PARENT_CANCELLED'
                }
                return $owner
            }
            if ($event.event -ne 'waiting') { throw 'INFOBASE_ACCESS_HOST_RESPONSE_INVALID' }
            if ($OnProgress) { & $OnProgress $event | Out-Null } else {
                Write-Host ('INFOBASE_ACCESS_WAIT ' + ($event | ConvertTo-Json -Depth 20 -Compress))
            }
        }
    } catch {
        if ($started) { Close-ItlDatabaseAccessHost -Owner $owner } else { $process.Dispose() }
        throw
    }
}

function Assert-ItlDatabaseAccessHost {
    param([Parameter(Mandatory = $true)][object]$Owner)

    if ($Owner.closed) { throw 'INFOBASE_ACCESS_HOST_ALREADY_CLOSED' }
    $Owner.process.StandardInput.WriteLine('{"event":"validate"}')
    $Owner.process.StandardInput.Flush()
    $event = Read-ItlDatabaseAccessHostEvent -Owner $Owner -TimeoutSeconds 30
    if ($event.event -ne 'validated') { throw 'INFOBASE_ACCESS_HOST_VALIDATION_UNCONFIRMED' }
}

function Complete-ItlDatabaseAccessHost {
    param([Parameter(Mandatory = $true)][object]$Owner, [string[]]$CleanupErrors = @())

    if ($Owner.closed) { throw 'INFOBASE_ACCESS_HOST_ALREADY_CLOSED' }
    try {
        $message = [pscustomobject]@{ event = 'release'; cleanupErrors = @($CleanupErrors) } | ConvertTo-Json -Compress
        # Error messages can contain Unicode; reuse an ASCII wire boundary.
        $ascii = [Text.RegularExpressions.Regex]::Replace($message, '[^\x00-\x7f]', {
            param($match)
            return ('\u{0:x4}' -f [int][char]$match.Value)
        })
        $Owner.process.StandardInput.WriteLine($ascii)
        $Owner.process.StandardInput.Flush()
        $event = Read-ItlDatabaseAccessHostEvent -Owner $Owner -TimeoutSeconds 30
        if ($event.event -ne 'released' -or $event.status -notin @('released', 'needs-attention')) {
            throw 'INFOBASE_ACCESS_HOST_RELEASE_UNCONFIRMED'
        }
        if (-not $Owner.process.WaitForExit(5000) -or $Owner.process.ExitCode -ne 0) {
            throw 'INFOBASE_ACCESS_HOST_RELEASE_UNCONFIRMED'
        }
        return $event
    } finally {
        Close-ItlDatabaseAccessHost -Owner $Owner
    }
}
