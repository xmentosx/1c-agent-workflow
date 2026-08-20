# Immutable component verification and publication finalization.

function ConvertTo-DeliveryNativeArgument {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value -or $Value.Length -eq 0) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $escaped = $Value -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

function Get-DeliveryGitHubRepository {
    param([string]$CandidateRoot)
    $remoteUrl = (Invoke-WorktreeGit -Root $CandidateRoot -Arguments @("remote", "get-url", $script:Remote)).stdout.Trim()
    $match = [regex]::Match($remoteUrl, '^(?:https://github\.com/|git@github\.com:|ssh://git@github\.com/)(?<owner>[^/]+)/(?<repo>[^/]+?)(?:\.git)?$')
    if (-not $match.Success) { throw "Component publication requires $($script:Remote) to be an exact github.com repository URL; actual='$remoteUrl'." }
    return [pscustomobject]@{ owner = $match.Groups["owner"].Value; repo = $match.Groups["repo"].Value; slug = ($match.Groups["owner"].Value + "/" + $match.Groups["repo"].Value) }
}

function Get-DeliveryRemoteAssetState {
    param(
        [string]$Url,
        [string]$ExpectedSha256,
        [ValidateRange(1, 3)][int]$NetworkAttempts = 3,
        [ValidateRange(1, 12)][int]$AvailabilityAttempts = 1
    )
    for ($availabilityAttempt = 1; $availabilityAttempt -le $AvailabilityAttempts; $availabilityAttempt++) {
        $downloadPath = Join-Path ([IO.Path]::GetTempPath()) ("itl-component-download-" + [guid]::NewGuid().ToString("N") + ".bin")
        try {
            try {
                $download = Invoke-ItlImmutableFileDownload -Uri $Url -DestinationPath $downloadPath -ExpectedSha256 $ExpectedSha256 `
                    -Label "Published Vanessa asset" -MaxAttempts $NetworkAttempts -TimeoutSeconds 300
                return [pscustomobject]@{ status = "matched"; sha256 = [string]$download.sha256 }
            } catch {
                if ($_.Exception -is [System.IO.InvalidDataException]) { throw }
                if ((Get-ItlHttpFailureStatusCode -ErrorRecord $_) -ne 404) {
                    throw "Unable to verify the immutable Vanessa asset without mutation: $($_.Exception.Message)"
                }
                if ($availabilityAttempt -ge $AvailabilityAttempts) {
                    return [pscustomobject]@{ status = "missing"; sha256 = "" }
                }
                Start-Sleep -Seconds ([Math]::Min(2 * $availabilityAttempt, 10))
            }
        } finally {
            Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue
        }
    }
    throw "Unable to determine the immutable Vanessa asset state: $Url"
}

function Get-DeliveryExactVanessaCandidate {
    param([string]$CandidateRoot, [object]$Lock)
    $expected = ([string]$Lock.sha256).ToLowerInvariant()
    $override = [Environment]::GetEnvironmentVariable("ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE", "Process")
    if (-not [string]::IsNullOrWhiteSpace($override)) {
        $path = [IO.Path]::GetFullPath($override)
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE does not exist: $path" }
        $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -cne $expected) { throw "Vanessa source-build override SHA256 mismatch. expected='$expected'; actual='$actual'." }
        return $path
    }

    $folder = ([string]$Lock.compatibilityVersion) + "-" + ([string]$Lock.downstreamRevision)
    $relative = Join-Path ("build\third-party\vanessa-automation\" + $folder) ([string]$Lock.assetName)
    foreach ($root in @($CandidateRoot, $script:Root) | Select-Object -Unique) {
        $path = Join-Path $root $relative
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -cne $expected) { throw "Canonical Vanessa candidate SHA256 mismatch. expected='$expected'; actual='$actual'; path='$path'." }
        return $path
    }
    throw "The immutable Vanessa URL is absent and no exact local candidate is available. Set ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE or place the locked asset at the canonical candidate path."
}

function Get-DeliveryRemoteAnnotatedTagCommit {
    param([string]$CandidateRoot, [string]$Tag)
    $result = Invoke-WorktreeGit -Root $CandidateRoot -Arguments @("ls-remote", "--tags", $script:Remote, "refs/tags/$Tag", "refs/tags/$Tag^{}") -AllowFailure
    if ($result.exitCode -ne 0) { throw "Unable to inspect remote component tag '$Tag'." }
    $direct = ""; $peeled = ""
    foreach ($line in @($result.stdout -split "`r?`n" | Where-Object { $_ })) {
        $parts = $line -split "\s+", 2
        if ($parts.Count -ne 2) { continue }
        if ($parts[1] -eq "refs/tags/$Tag") { $direct = $parts[0] }
        if ($parts[1] -eq "refs/tags/$Tag^{}") { $peeled = $parts[0] }
    }
    if (-not $direct) { return "" }
    if (-not $peeled) { throw "Remote component tag '$Tag' is lightweight; an immutable annotated tag is required." }
    return $peeled
}

function Invoke-DeliveryGitHubCli {
    param([string[]]$Arguments, [switch]$AllowFailure)
    $gh = Get-Command gh -ErrorAction SilentlyContinue
    if (-not $gh) { throw "GitHub CLI is required to finalize an unpublished Vanessa component." }
    $output = @(& $gh.Source @Arguments 2>&1 | ForEach-Object { [string]$_ })
    $exitCode = $LASTEXITCODE
    if (-not $AllowFailure -and $exitCode -ne 0) { throw "gh $($Arguments -join ' ') failed: $($output -join '; ')" }
    return [pscustomobject]@{ exitCode = [int]$exitCode; output = $output; text = ($output -join "`n") }
}

function Save-DeliveryComponentPublicationEvidence {
    param([string]$CandidateCommit, [object]$Evidence)
    $root = Join-Path (Get-DeliveryCommonGitDirectory) "itl\component-publications\$CandidateCommit"
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    [IO.File]::WriteAllText((Join-Path $root "vanessa-automation.json"), (($Evidence | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
}

function Invoke-VanessaComponentPublicationFinalize {
    param([string]$CandidateRoot, [string]$CandidateCommit)
    $lockPath = Join-Path $CandidateRoot "templates\dependency-lock.json"
    if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) { throw "Component finalization requires templates/dependency-lock.json in the exact candidate." }
    $lock = (Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8 | ConvertFrom-Json).dependencies.vanessaAutomation
    foreach ($field in @("releaseTag", "url", "assetName", "sha256", "compatibilityVersion", "downstreamRevision")) {
        $property = if ($null -eq $lock) { $null } else { $lock.PSObject.Properties[$field] }
        if ($null -eq $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) { throw "Vanessa component lock is missing '$field'." }
    }
    $expectedSha = ([string]$lock.sha256).ToLowerInvariant()
    if ($expectedSha -notmatch '^[a-f0-9]{64}$') { throw "Vanessa component lock has an invalid SHA256: $expectedSha" }
    $repository = Get-DeliveryGitHubRepository -CandidateRoot $CandidateRoot
    $uri = [Uri]([string]$lock.url)
    $urlMatch = [regex]::Match($uri.AbsolutePath, '^/(?<owner>[^/]+)/(?<repo>[^/]+)/releases/download/(?<tag>[^/]+)/(?<asset>[^/]+)$')
    if ($uri.Scheme -ne "https" -or $uri.Host -ne "github.com" -or -not $urlMatch.Success) { throw "Vanessa immutable URL is not an exact GitHub release asset URL: $($lock.url)" }
    $urlOwner = [Uri]::UnescapeDataString($urlMatch.Groups["owner"].Value)
    $urlRepo = [Uri]::UnescapeDataString($urlMatch.Groups["repo"].Value)
    $urlTag = [Uri]::UnescapeDataString($urlMatch.Groups["tag"].Value)
    $urlAsset = [Uri]::UnescapeDataString($urlMatch.Groups["asset"].Value)
    if ($urlOwner -cne $repository.owner -or $urlRepo -cne $repository.repo -or $urlTag -cne [string]$lock.releaseTag -or $urlAsset -cne [string]$lock.assetName) {
        throw "Vanessa immutable URL owner/repo/tag/asset does not match origin, releaseTag, and assetName."
    }

    $remote = Get-DeliveryRemoteAssetState -Url ([string]$lock.url) -ExpectedSha256 $expectedSha
    $mutated = $false
    if ($remote.status -eq "missing") {
        if (-not $RequireRelease) { throw "The locked Vanessa asset is not published. Component upload requires PublishDevelop -RequireRelease so the exact candidate passes Release first." }
        $candidatePath = Get-DeliveryExactVanessaCandidate -CandidateRoot $CandidateRoot -Lock $lock
        $remoteTagCommit = Get-DeliveryRemoteAnnotatedTagCommit -CandidateRoot $CandidateRoot -Tag ([string]$lock.releaseTag)
        if ($remoteTagCommit) {
            if ($remoteTagCommit -cne $CandidateCommit) { throw "Remote component tag '$($lock.releaseTag)' points to '$remoteTagCommit', not exact candidate '$CandidateCommit'. Refusing to repoint it." }
        } else {
            $localTag = "refs/tags/$($lock.releaseTag)"
            $localTagType = (Invoke-WorktreeGit -Root $CandidateRoot -Arguments @("cat-file", "-t", $localTag) -AllowFailure).stdout.Trim()
            if ($localTagType) {
                $localTagCommit = (Invoke-WorktreeGit -Root $CandidateRoot -Arguments @("rev-parse", "$localTag^{}") -AllowFailure).stdout.Trim()
                if ($localTagType -cne "tag" -or $localTagCommit -cne $CandidateCommit) { throw "Local component tag '$($lock.releaseTag)' is not an annotated tag for exact candidate '$CandidateCommit'." }
            } else {
                [void](Invoke-WorktreeGit -Root $CandidateRoot -Arguments @("tag", "-a", [string]$lock.releaseTag, $CandidateCommit, "-m", "Vanessa Automation $($lock.downstreamRevision)"))
            }
            $tagPush = Invoke-WorktreeGit -Root $CandidateRoot -Arguments @("push", $script:Remote, $localTag) -AllowFailure
            if ($tagPush.exitCode -ne 0) {
                $racedTagCommit = Get-DeliveryRemoteAnnotatedTagCommit -CandidateRoot $CandidateRoot -Tag ([string]$lock.releaseTag)
                if ($racedTagCommit -cne $CandidateCommit) { throw "Unable to publish the immutable component tag '$($lock.releaseTag)' safely." }
            }
            $mutated = $true
        }

        $releaseView = Invoke-DeliveryGitHubCli -Arguments @("release", "view", [string]$lock.releaseTag, "--repo", $repository.slug, "--json", "assets") -AllowFailure
        if ($releaseView.exitCode -ne 0) {
            if ($releaseView.text -notmatch '(?i)(release not found|HTTP 404|not found)') { throw "Unable to inspect GitHub Release '$($lock.releaseTag)': $($releaseView.text)" }
            [void](Invoke-DeliveryGitHubCli -Arguments @("release", "create", [string]$lock.releaseTag, "--repo", $repository.slug, "--verify-tag", "--title", [string]$lock.releaseTag, "--notes", "Immutable Vanessa Automation component $($lock.downstreamRevision)."))
            $mutated = $true
            $releaseView = Invoke-DeliveryGitHubCli -Arguments @("release", "view", [string]$lock.releaseTag, "--repo", $repository.slug, "--json", "assets")
        }
        $release = $releaseView.text | ConvertFrom-Json
        $assetExists = @($release.assets | Where-Object { [string]$_.name -ceq [string]$lock.assetName }).Count -gt 0
        if (-not $assetExists) {
            $uploadRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-component-upload-" + [guid]::NewGuid().ToString("N"))
            New-Item -ItemType Directory -Force -Path $uploadRoot | Out-Null
            try {
                $uploadPath = Join-Path $uploadRoot ([string]$lock.assetName)
                Copy-Item -LiteralPath $candidatePath -Destination $uploadPath
                [void](Invoke-DeliveryGitHubCli -Arguments @("release", "upload", [string]$lock.releaseTag, $uploadPath, "--repo", $repository.slug))
                $mutated = $true
            } finally { Remove-Item -LiteralPath $uploadRoot -Recurse -Force -ErrorAction SilentlyContinue }
        }
        $remote = Get-DeliveryRemoteAssetState -Url ([string]$lock.url) -ExpectedSha256 $expectedSha -AvailabilityAttempts 12
        if ($remote.status -ne "matched") { throw "The Vanessa component was finalized, but its immutable URL is still unavailable. The queue is preserved for a safe retry." }
    }

    $evidence = [ordered]@{
        schemaVersion = 1; status = "passed"; component = "vanessaAutomation"; candidateCommit = $CandidateCommit
        releaseTag = [string]$lock.releaseTag; url = [string]$lock.url; assetName = [string]$lock.assetName; sha256 = $expectedSha
        githubRepository = $repository.slug; githubMutated = $mutated; verifiedAt = [DateTime]::UtcNow.ToString("o")
    }
    Save-DeliveryComponentPublicationEvidence -CandidateCommit $CandidateCommit -Evidence $evidence
    return [pscustomobject]$evidence
}

function Invoke-ComponentPublicationFinalizer {
    param([string]$CandidateRoot, [string]$CandidateCommit)
    if (-not $script:ComponentFinalizerScript) { return Invoke-VanessaComponentPublicationFinalize -CandidateRoot $CandidateRoot -CandidateCommit $CandidateCommit }
    if (-not (Test-Path -LiteralPath $script:ComponentFinalizerScript -PathType Leaf)) { throw "Component finalizer seam was not found: $($script:ComponentFinalizerScript)" }
    $arguments = @(
        "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $script:ComponentFinalizerScript,
        "-RepositoryRoot", $CandidateRoot, "-SourceRepositoryRoot", $script:Root, "-CandidateCommit", $CandidateCommit, "-Remote", $script:Remote
    )
    if ($RequireRelease) { $arguments += "-ReleaseQualified" }
    $quoted = @($arguments | ForEach-Object { ConvertTo-DeliveryNativeArgument -Value ([string]$_) })
    $logRoot = Join-Path $CandidateRoot "build\test-results\delivery"
    New-Item -ItemType Directory -Force -Path $logRoot | Out-Null
    $stdout = Join-Path $logRoot "component-finalizer.stdout.log"; $stderr = Join-Path $logRoot "component-finalizer.stderr.log"
    $process = $null; $processJob = [IntPtr]::Zero; $finalizerError = ""
    try {
        $started = Start-DeliveryProcess -ArgumentList ($quoted -join " ") -WorkingDirectory $CandidateRoot -StandardOutputPath $stdout -StandardErrorPath $stderr
        $process = $started.process
        $processJob = [IntPtr]$started.jobHandle
        while (-not $process.WaitForExit(1000)) {}
        $process.WaitForExit(); $process.Refresh()
        if ([int]$process.ExitCode -ne 0) {
            $detail = if (Test-Path -LiteralPath $stderr -PathType Leaf) { (Get-Content -LiteralPath $stderr -Raw -Encoding UTF8).Trim() } else { "" }
            throw "Component publication finalizer failed with exit code $($process.ExitCode). $detail"
        }
    } catch {
        $finalizerError = $_.Exception.Message
        throw
    } finally {
        $jobCloseError = $null
        try { Close-DeliveryProcessJob -JobHandle $processJob -Process $process -PriorErrorMessage $finalizerError } catch { $jobCloseError = $_ }
        Stop-DeliveryProcessTree -Process $process
        if ($jobCloseError) { throw $jobCloseError }
    }
    return [pscustomobject]@{ status = "passed"; component = "test-seam"; candidateCommit = $CandidateCommit }
}
