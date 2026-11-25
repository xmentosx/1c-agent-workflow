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

    $stream = $null
    $sha256 = $null
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        $hashBytes = $sha256.ComputeHash($stream)
        return ([System.BitConverter]::ToString($hashBytes)).Replace("-", "").ToLowerInvariant()
    } finally {
        if ($null -ne $sha256) { $sha256.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
    }
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
        $backupPath = Join-Path (Split-Path -Parent $DestinationPath) ("." + (Split-Path -Leaf $DestinationPath) + "." + [guid]::NewGuid().ToString("N") + ".backup")
        try {
            [IO.File]::Replace($StagedPath, $DestinationPath, $backupPath)
        } catch {
            if ((Get-ItlImmutableFileSha256 -Path $DestinationPath) -ceq $expected) {
                Remove-Item -LiteralPath $StagedPath -Force -ErrorAction SilentlyContinue
                return [pscustomobject]@{ path = $DestinationPath; sha256 = $expected; published = $false }
            }
            throw
        } finally {
            Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
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

function Get-ItlGitHubReleaseAssetReference {
    param([string]$Source)

    $parsed = $null
    if (-not [Uri]::TryCreate($Source, [UriKind]::Absolute, [ref]$parsed) -or $parsed.Scheme -cne "https" -or
        -not [string]::Equals($parsed.Host, "github.com", [StringComparison]::OrdinalIgnoreCase) -or -not $parsed.IsDefaultPort -or
        $parsed.Query -or $parsed.Fragment -or $parsed.UserInfo) { return $null }
    $match = [regex]::Match($parsed.AbsolutePath, '^/(?<owner>[A-Za-z0-9][A-Za-z0-9-]*)/(?<repo>[A-Za-z0-9._-]+)/releases/download/(?<tag>[^/]+)/(?<asset>[^/]+)$')
    if (-not $match.Success) { return $null }
    return [pscustomobject]@{
        owner = $match.Groups["owner"].Value
        repo = $match.Groups["repo"].Value
        tag = [Uri]::UnescapeDataString($match.Groups["tag"].Value)
        asset = [Uri]::UnescapeDataString($match.Groups["asset"].Value)
    }
}

function Get-ItlGitHubApiToken {
    # Same precedence as Get-GitHubApiHeaders; this library cannot load core.
    foreach ($name in @("GITHUB_TOKEN", "GH_TOKEN")) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value.Trim() }
    }
    return ""
}

function Protect-ItlGitHubApiText {
    param([AllowNull()][string]$Text)

    $token = Get-ItlGitHubApiToken
    if ([string]::IsNullOrEmpty($Text) -or -not $token) { return [string]$Text }
    return $Text.Replace($token, "***")
}

function Get-ItlGitHubAssetRedirectLocation {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][hashtable]$Headers,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )

    # Credentials stay on api.github.com: the redirect is read, never followed.
    $request = [System.Net.HttpWebRequest][System.Net.WebRequest]::Create($Uri)
    $request.Method = "GET"
    $request.AllowAutoRedirect = $false
    $request.Timeout = $TimeoutSeconds * 1000
    $request.ReadWriteTimeout = $TimeoutSeconds * 1000
    $request.UserAgent = [string]$Headers["User-Agent"]
    $request.Accept = [string]$Headers["Accept"]
    foreach ($name in @("Authorization", "X-GitHub-Api-Version")) {
        if ($Headers.ContainsKey($name)) { $request.Headers[$name] = [string]$Headers[$name] }
    }
    $response = $null
    try {
        $response = [System.Net.HttpWebResponse]$request.GetResponse()
        $statusCode = [int]$response.StatusCode
        $location = [string]$response.Headers["Location"]
        $target = $null
        if ($statusCode -in @(301, 302, 303, 307, 308) -and [Uri]::TryCreate($location, [UriKind]::Absolute, [ref]$target) -and $target.Scheme -ceq "https") {
            return $target.AbsoluteUri
        }
        $failure = [System.Net.WebException]::new("GitHub asset endpoint returned HTTP $statusCode without an HTTPS redirect.")
        $failure.Data["StatusCode"] = $statusCode
        throw $failure
    } finally {
        if ($null -ne $response) { $response.Dispose() }
    }
}

function Invoke-ItlGitHubReleaseAssetApiDownload {
    param(
        [Parameter(Mandatory = $true)][object]$Reference,
        [Parameter(Mandatory = $true)][string]$OutFile,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds,
        [string]$Label = "Immutable asset"
    )

    $metadataTimeout = [Math]::Min($TimeoutSeconds, 60)
    $headers = @{ "User-Agent" = "1c-agent-workflow"; "Accept" = "application/vnd.github+json"; "X-GitHub-Api-Version" = "2022-11-28" }
    $token = Get-ItlGitHubApiToken
    if ($token) { $headers["Authorization"] = "Bearer $token" }
    $repositoryUri = "https://api.github.com/repos/" + [Uri]::EscapeDataString([string]$Reference.owner) + "/" + [Uri]::EscapeDataString([string]$Reference.repo)
    $release = Invoke-RestMethod -Uri ($repositoryUri + "/releases/tags/" + [Uri]::EscapeDataString([string]$Reference.tag)) -Headers $headers -TimeoutSec $metadataTimeout
    $assets = @(@($release.assets) | Where-Object { $null -ne $_ -and [string]$_.name -ceq [string]$Reference.asset })
    if ($assets.Count -ne 1) { throw "GitHub release '$($Reference.tag)' does not contain exactly one asset named '$($Reference.asset)'." }
    $digestProperty = $assets[0].PSObject.Properties["digest"]
    if ($null -ne $digestProperty -and [string]$digestProperty.Value -cmatch '^sha256:[a-f0-9]{64}$') {
        $digest = ([string]$digestProperty.Value).Substring(7)
        if ($digest -cne $ExpectedSha256) {
            throw [System.IO.InvalidDataException]::new("$Label SHA256 mismatch. expected='$ExpectedSha256'; github-digest='$digest'.")
        }
    }
    $assetUri = [string]$assets[0].url
    $assetPrefix = $repositoryUri + "/releases/assets/"
    if (-not $assetUri.StartsWith($assetPrefix, [StringComparison]::OrdinalIgnoreCase) -or $assetUri.Substring($assetPrefix.Length) -notmatch '^[0-9]+$') {
        throw "GitHub release asset '$($Reference.asset)' has an unexpected API URL."
    }
    $headers["Accept"] = "application/octet-stream"
    $location = Get-ItlGitHubAssetRedirectLocation -Uri $assetUri -Headers $headers -TimeoutSeconds $metadataTimeout
    Invoke-WebRequest -UseBasicParsing -Uri $location -OutFile $OutFile -TimeoutSec $TimeoutSeconds
    if (-not (Test-Path -LiteralPath $OutFile -PathType Leaf)) { throw "GitHub API download completed without creating an output file." }
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
        $route = "file"
        if (Test-Path -LiteralPath $sourcePath -PathType Leaf -ErrorAction SilentlyContinue) {
            Copy-Item -LiteralPath $sourcePath -Destination $temporaryPath -Force
            $attempt = 0
        } else {
            $parsedUri = $null
            if (-not [Uri]::TryCreate($Source, [UriKind]::Absolute, [ref]$parsedUri) -or $parsedUri.Scheme -cne "https") {
                throw "$Label source is neither an existing file nor an exact HTTPS URL: '$Source'."
            }
            # GitHub's web release endpoint can stall and cache 504s while the
            # REST asset route still serves the same bytes; the lock SHA decides.
            $route = "web"
            $apiFailure = ""
            $githubAsset = Get-ItlGitHubReleaseAssetReference -Source $Source
            if ($null -ne $githubAsset) {
                try {
                    Invoke-ItlGitHubReleaseAssetApiDownload -Reference $githubAsset -OutFile $temporaryPath -ExpectedSha256 $expected -TimeoutSeconds $TimeoutSeconds -Label $Label
                    $route = "api"
                    $attempt = 1
                } catch {
                    if ($_.Exception -is [System.IO.InvalidDataException]) { throw }
                    Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
                    $apiStatus = Get-ItlHttpFailureStatusCode -ErrorRecord $_
                    $apiFailure = "GitHub API route" + $(if ($apiStatus -gt 0) { " HTTP $apiStatus" } else { "" }) + ": " + (Protect-ItlGitHubApiText -Text $_.Exception.Message)
                    Write-Warning "$Label download is falling back to the locked release URL. $apiFailure"
                }
            }
            if ($route -ceq "web") {
                for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
                    Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
                    try { Invoke-WebRequest -UseBasicParsing -Uri $Source -OutFile $temporaryPath -TimeoutSec $TimeoutSeconds } catch {
                        if (-not (Test-ItlTransientImmutableDownloadFailure -ErrorRecord $_) -or $attempt -ge $MaxAttempts) {
                            if (-not $apiFailure) { throw }
                            # Name both routes; the inner web failure keeps its status classification.
                            $webStatus = Get-ItlHttpFailureStatusCode -ErrorRecord $_
                            $combined = [System.Exception]::new("$Label download failed through both routes. $apiFailure; locked release URL" +
                                $(if ($webStatus -gt 0) { " HTTP $webStatus" } else { "" }) + ": " + $_.Exception.Message, $_.Exception)
                            if ($webStatus -gt 0) { $combined.Data["StatusCode"] = $webStatus }
                            throw $combined
                        }
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
        }
        $publication = Publish-ItlImmutableStagedFile -StagedPath $temporaryPath -DestinationPath $DestinationPath -ExpectedSha256 $expected -Label $Label
        return [pscustomobject]@{ path = $DestinationPath; sha256 = $expected; attempts = $attempt; source = $Source; route = $route; published = [bool]$publication.published }
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
