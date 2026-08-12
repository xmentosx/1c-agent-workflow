function Get-ItlHttpFailureStatusCode {
    param([Parameter(Mandatory = $true)][object]$ErrorRecord)

    $exception = $ErrorRecord.Exception
    while ($null -ne $exception) {
        try {
            if ($exception.Data.Contains("StatusCode")) { return [int]$exception.Data["StatusCode"] }
        } catch {}
        try {
            if ($null -ne $exception.Response) { return [int]$exception.Response.StatusCode }
        } catch {}
        try {
            $statusCodeProperty = $exception.PSObject.Properties["StatusCode"]
            if ($null -ne $statusCodeProperty -and $null -ne $statusCodeProperty.Value) { return [int]$statusCodeProperty.Value }
        } catch {}
        $exception = $exception.InnerException
    }
    return 0
}

function Test-ItlTransientImmutableDownloadFailure {
    param([Parameter(Mandatory = $true)][object]$ErrorRecord)

    $statusCode = Get-ItlHttpFailureStatusCode -ErrorRecord $ErrorRecord
    if ($statusCode -gt 0) { return $statusCode -in @(500, 502, 503, 504) }

    $exception = $ErrorRecord.Exception
    while ($null -ne $exception) {
        if ($exception -is [System.TimeoutException]) { return $true }
        if ($exception -is [System.Net.Sockets.SocketException]) {
            return $exception.SocketErrorCode -in @(
                [System.Net.Sockets.SocketError]::ConnectionAborted,
                [System.Net.Sockets.SocketError]::ConnectionRefused,
                [System.Net.Sockets.SocketError]::ConnectionReset,
                [System.Net.Sockets.SocketError]::HostDown,
                [System.Net.Sockets.SocketError]::HostNotFound,
                [System.Net.Sockets.SocketError]::HostUnreachable,
                [System.Net.Sockets.SocketError]::NetworkDown,
                [System.Net.Sockets.SocketError]::NetworkReset,
                [System.Net.Sockets.SocketError]::NetworkUnreachable,
                [System.Net.Sockets.SocketError]::TimedOut,
                [System.Net.Sockets.SocketError]::TryAgain
            )
        }
        if ($exception -is [System.Net.WebException]) {
            return $exception.Status -in @(
                [System.Net.WebExceptionStatus]::ConnectFailure,
                [System.Net.WebExceptionStatus]::ConnectionClosed,
                [System.Net.WebExceptionStatus]::KeepAliveFailure,
                [System.Net.WebExceptionStatus]::NameResolutionFailure,
                [System.Net.WebExceptionStatus]::PipelineFailure,
                [System.Net.WebExceptionStatus]::ProxyNameResolutionFailure,
                [System.Net.WebExceptionStatus]::ReceiveFailure,
                [System.Net.WebExceptionStatus]::SendFailure,
                [System.Net.WebExceptionStatus]::Timeout
            )
        }
        $exception = $exception.InnerException
    }
    return $false
}

function Get-ItlImmutableFileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return "" }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Publish-ItlImmutableStagedFile {
    param(
        [Parameter(Mandatory = $true)][string]$StagedPath,
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256,
        [string]$Label = "Immutable asset"
    )

    $expected = $ExpectedSha256.ToLowerInvariant()
    $stagedSha = Get-ItlImmutableFileSha256 -Path $StagedPath
    if ($stagedSha -cne $expected) {
        throw [System.IO.InvalidDataException]::new("$Label SHA256 mismatch. expected='$expected'; actual='$stagedSha'.")
    }
    $existingSha = Get-ItlImmutableFileSha256 -Path $DestinationPath
    if ($existingSha -ceq $expected) { return [pscustomobject]@{ path = $DestinationPath; sha256 = $expected; published = $false } }

    if ($existingSha) {
        try { [IO.File]::Replace($StagedPath, $DestinationPath, $null, $true) } catch {
            if ((Get-ItlImmutableFileSha256 -Path $DestinationPath) -ceq $expected) {
                Remove-Item -LiteralPath $StagedPath -Force -ErrorAction SilentlyContinue
                return [pscustomobject]@{ path = $DestinationPath; sha256 = $expected; published = $false }
            }
            throw
        }
    } else {
        try { [IO.File]::Move($StagedPath, $DestinationPath) } catch {
            if ((Get-ItlImmutableFileSha256 -Path $DestinationPath) -ceq $expected) {
                Remove-Item -LiteralPath $StagedPath -Force -ErrorAction SilentlyContinue
                return [pscustomobject]@{ path = $DestinationPath; sha256 = $expected; published = $false }
            }
            throw
        }
    }
    if ((Get-ItlImmutableFileSha256 -Path $DestinationPath) -cne $expected) { throw "$Label publish did not preserve exact SHA256." }
    return [pscustomobject]@{ path = $DestinationPath; sha256 = $expected; published = $true }
}

function Invoke-ItlImmutableFileAcquire {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256,
        [string]$Label = "Immutable asset",
        [ValidateRange(1, 3)][int]$MaxAttempts = 3,
        [ValidateRange(1, 300)][int]$TimeoutSeconds = 300
    )

    $expected = $ExpectedSha256.ToLowerInvariant()
    if ($expected -notmatch '^[a-f0-9]{64}$') { throw "$Label has an invalid expected SHA256: '$ExpectedSha256'." }
    $parent = Split-Path -Parent $DestinationPath
    if (-not $parent) {
        $parent = (Get-Location).ProviderPath
        $DestinationPath = Join-Path $parent (Split-Path -Leaf $DestinationPath)
    }
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $temporaryPath = Join-Path $parent ("." + (Split-Path -Leaf $DestinationPath) + "." + [guid]::NewGuid().ToString("N") + ".partial")
    try {
        $sourcePath = $Source
        if ([Uri]::IsWellFormedUriString($Source, [UriKind]::Absolute) -and ([Uri]$Source).Scheme -eq "file") { $sourcePath = ([Uri]$Source).LocalPath }
        if (Test-Path -LiteralPath $sourcePath -PathType Leaf -ErrorAction SilentlyContinue) {
            Copy-Item -LiteralPath $sourcePath -Destination $temporaryPath -Force
            $attempt = 0
        } else {
            $parsedUri = $null
            if (-not [Uri]::TryCreate($Source, [UriKind]::Absolute, [ref]$parsedUri) -or $parsedUri.Scheme -cne "https") {
                throw "$Label source is neither an existing file nor an exact HTTPS URL: '$Source'."
            }
            for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
                Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
                try { Invoke-WebRequest -UseBasicParsing -Uri $Source -OutFile $temporaryPath -TimeoutSec $TimeoutSeconds } catch {
                    if (-not (Test-ItlTransientImmutableDownloadFailure -ErrorRecord $_) -or $attempt -ge $MaxAttempts) { throw }
                    Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
                    $delaySeconds = [int][Math]::Pow(2, $attempt - 1)
                    Write-Warning "$Label download hit a transient network failure (attempt $attempt of $MaxAttempts); retrying in $delaySeconds second(s): $($_.Exception.Message)"
                    Start-Sleep -Seconds $delaySeconds
                    continue
                }
                if (-not (Test-Path -LiteralPath $temporaryPath -PathType Leaf)) { throw "$Label download completed without creating an output file." }
                break
            }
        }
        $publication = Publish-ItlImmutableStagedFile -StagedPath $temporaryPath -DestinationPath $DestinationPath -ExpectedSha256 $expected -Label $Label
        return [pscustomobject]@{ path = $DestinationPath; sha256 = $expected; attempts = $attempt; source = $Source; published = [bool]$publication.published }
    } finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-ItlImmutableFileDownload {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256,
        [string]$Label = "Immutable asset",
        [ValidateRange(1, 3)][int]$MaxAttempts = 3,
        [ValidateRange(1, 300)][int]$TimeoutSeconds = 300
    )
    return Invoke-ItlImmutableFileAcquire -Source $Uri -DestinationPath $DestinationPath -ExpectedSha256 $ExpectedSha256 `
        -Label $Label -MaxAttempts $MaxAttempts -TimeoutSeconds $TimeoutSeconds
}
