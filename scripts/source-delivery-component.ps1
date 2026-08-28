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
                    -Label "Published owned component asset" -MaxAttempts $NetworkAttempts -TimeoutSeconds 300
                return [pscustomobject]@{ status = "matched"; sha256 = [string]$download.sha256 }
            } catch {
                if ($_.Exception -is [System.IO.InvalidDataException]) { throw }
                if ((Get-ItlHttpFailureStatusCode -ErrorRecord $_) -ne 404) {
                    throw "Unable to verify the immutable owned component asset without mutation: $($_.Exception.Message)"
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

function ConvertTo-DeliveryRepositoryIdentity {
    param([string]$Url)
    $value = $Url.Replace('\', '/').TrimEnd('/')
    if ($value.EndsWith('.git', [StringComparison]::OrdinalIgnoreCase)) { $value = $value.Substring(0, $value.Length - 4) }
    $value = $value -replace '^git@github\.com:', 'https://github.com/'
    $value = $value -replace '^ssh://git@github\.com/', 'https://github.com/'
    return $value.ToLowerInvariant()
}

function Get-DeliveryAiRulesRemoteState {
    param([string]$SourceRoot, [object]$Lock)
    $tag = [string]$Lock.ref
    $releaseBranch = "release/$tag"
    $result = Invoke-WorktreeGit -Root $SourceRoot -Arguments @("ls-remote", "origin", "refs/heads/$releaseBranch", "refs/tags/$tag", "refs/tags/$tag^{}", "refs/heads/main") -AllowFailure
    if ($result.exitCode -ne 0) { throw "Unable to inspect remote ai_rules_1c release '$tag'." }
    $refs = @{}
    foreach ($line in @($result.stdout -split "`r?`n" | Where-Object { $_ })) {
        $parts = $line -split "\s+", 2
        if ($parts.Count -eq 2) { $refs[$parts[1]] = $parts[0].ToLowerInvariant() }
    }
    $branchCommit = [string]$refs["refs/heads/$releaseBranch"]
    $tagObject = [string]$refs["refs/tags/$tag"]
    $tagCommit = [string]$refs["refs/tags/$tag^{}"]
    $mainCommit = [string]$refs["refs/heads/main"]
    $expected = ([string]$Lock.commit).ToLowerInvariant()
    $presentCount = @($branchCommit, $tagObject, $tagCommit | Where-Object { $_ }).Count
    $status = if ($presentCount -eq 0) {
        "missing"
    } elseif ($presentCount -eq 3 -and $branchCommit -ceq $expected -and $tagCommit -ceq $expected) {
        "matched"
    } elseif ($presentCount -lt 3) {
        "partial"
    } else {
        "mismatch"
    }
    return [pscustomobject]@{
        status = $status; releaseBranch = $releaseBranch; tag = $tag; branchCommit = $branchCommit
        tagObject = $tagObject; tagCommit = $tagCommit; mainCommit = $mainCommit
    }
}

function Get-DeliveryLocalAiRulesSource {
    param([object]$Lock)
    if ([string]::IsNullOrWhiteSpace($AiRulesSource) -or -not (Test-Path -LiteralPath $AiRulesSource -PathType Container)) {
        throw "Owned ai_rules_1c publication requires explicit -AiRulesSource pointing to the clean locked release checkout."
    }
    $sourceRoot = [IO.Path]::GetFullPath($AiRulesSource)
    $origin = (Invoke-WorktreeGit -Root $sourceRoot -Arguments @("remote", "get-url", "origin")).stdout.Trim()
    if ((ConvertTo-DeliveryRepositoryIdentity -Url $origin) -cne (ConvertTo-DeliveryRepositoryIdentity -Url ([string]$Lock.repo))) {
        throw "ai_rules_1c source origin does not match the canonical lock repository."
    }
    $status = (Invoke-WorktreeGit -Root $sourceRoot -Arguments @("status", "--porcelain", "--untracked-files=all")).stdout
    if ($status) { throw "ai_rules_1c publication source must be clean: $sourceRoot" }
    $head = (Invoke-WorktreeGit -Root $sourceRoot -Arguments @("rev-parse", "HEAD")).stdout.Trim().ToLowerInvariant()
    $expected = ([string]$Lock.commit).ToLowerInvariant()
    if ($head -cne $expected) { throw "ai_rules_1c publication source is not the locked commit. expected='$expected'; actual='$head'." }
    $tag = [string]$Lock.ref
    $tagType = (Invoke-WorktreeGit -Root $sourceRoot -Arguments @("cat-file", "-t", "refs/tags/$tag") -AllowFailure).stdout.Trim()
    $tagCommit = (Invoke-WorktreeGit -Root $sourceRoot -Arguments @("rev-parse", "refs/tags/$tag^{}") -AllowFailure).stdout.Trim().ToLowerInvariant()
    if ($tagType -cne "tag" -or $tagCommit -cne $expected) { throw "Local ai_rules_1c tag '$tag' is not an annotated tag for '$expected'." }
    $releaseBranch = "release/$tag"
    $branchCommit = (Invoke-WorktreeGit -Root $sourceRoot -Arguments @("rev-parse", "refs/heads/$releaseBranch") -AllowFailure).stdout.Trim().ToLowerInvariant()
    if ($branchCommit -cne $expected) { throw "Local ai_rules_1c release branch '$releaseBranch' does not match '$expected'." }
    $tree = (Invoke-WorktreeGit -Root $sourceRoot -Arguments @("rev-parse", "HEAD^{tree}")).stdout.Trim().ToLowerInvariant()
    $qualificationPath = Join-Path $sourceRoot "build\test-results\qualification\full.json"
    if (-not (Test-Path -LiteralPath $qualificationPath -PathType Leaf)) { throw "Exact ai_rules_1c Full qualification is missing: $qualificationPath" }
    $qualification = Get-Content -LiteralPath $qualificationPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$qualification.kind -cne "itl-ai-rules-full-qualification" -or [string]$qualification.status -cne "passed" -or
        -not [bool]$qualification.reusable -or [string]$qualification.repository.commit -cne $expected -or
        [string]$qualification.repository.tree -cne $tree -or -not [bool]$qualification.repository.worktreeClean) {
        throw "ai_rules_1c Full qualification does not match the exact locked commit and tree."
    }
    return [pscustomobject]@{ root = $sourceRoot; commit = $expected; tree = $tree; tag = $tag; releaseBranch = $releaseBranch; qualificationPath = $qualificationPath }
}

function Invoke-AiRulesComponentPublicationFinalize {
    param([string]$CandidateRoot, [string]$CandidateCommit)
    $lock = (Get-Content -LiteralPath (Join-Path $CandidateRoot "templates\dependency-lock.json") -Raw -Encoding UTF8 | ConvertFrom-Json).dependencies.aiRules1c
    foreach ($field in @("repo", "ref", "commit", "upstreamCommit", "downstreamRevision")) {
        if ($null -eq $lock.PSObject.Properties[$field] -or [string]::IsNullOrWhiteSpace([string]$lock.$field)) { throw "ai_rules_1c lock is missing '$field'." }
    }
    if ([string]$lock.compatibilityStatus -cne "passed") {
        throw "ai_rules_1c '$($lock.ref)' is published remotely but is not installable: compatibilityStatus=$($lock.compatibilityStatus)."
    }
    $local = Get-DeliveryLocalAiRulesSource -Lock $lock
    $remote = Get-DeliveryAiRulesRemoteState -SourceRoot $local.root -Lock $lock
    if ($remote.status -in @("partial", "mismatch")) {
        throw "Remote ai_rules_1c release '$($lock.ref)' is $($remote.status); immutable refs will not be repaired or repointed."
    }
    $mutated = $false
    if ($remote.status -eq "missing") {
        if ($remote.mainCommit) {
            $ancestor = Invoke-WorktreeGit -Root $local.root -Arguments @("merge-base", "--is-ancestor", $remote.mainCommit, [string]$lock.upstreamCommit) -AllowFailure
            if ($ancestor.exitCode -ne 0) { throw "Remote ai_rules_1c main cannot fast-forward to locked upstream '$($lock.upstreamCommit)'." }
        }
        $pushRefs = @(
            ([string]$lock.upstreamCommit + ":refs/heads/main"),
            ("refs/heads/$($local.releaseBranch):refs/heads/$($local.releaseBranch)"),
            ("refs/tags/$($local.tag):refs/tags/$($local.tag)")
        )
        $push = Invoke-WorktreeGit -Root $local.root -Arguments (@("push", "--atomic", "origin") + $pushRefs) -AllowFailure
        if ($push.exitCode -ne 0) {
            $raced = Get-DeliveryAiRulesRemoteState -SourceRoot $local.root -Lock $lock
            if ($raced.status -cne "matched") { throw "Unable to publish the immutable ai_rules_1c release '$($lock.ref)' atomically." }
        }
        $mutated = $true
        $remote = Get-DeliveryAiRulesRemoteState -SourceRoot $local.root -Lock $lock
    }
    if ($remote.status -cne "matched") { throw "Published ai_rules_1c refs do not match '$($lock.ref)@$($lock.commit)'." }
    $evidence = [ordered]@{
        schemaVersion = 1; status = "passed"; component = "aiRules1c"; candidateCommit = $CandidateCommit
        releaseTag = [string]$lock.ref; releaseBranch = [string]$remote.releaseBranch; commit = ([string]$lock.commit).ToLowerInvariant()
        upstreamCommit = ([string]$lock.upstreamCommit).ToLowerInvariant(); remoteMutated = $mutated
        compatibilityStatus = [string]$lock.compatibilityStatus; installable = $true
        qualificationPath = [string]$local.qualificationPath; verifiedAt = [DateTime]::UtcNow.ToString("o")
    }
    Save-DeliveryComponentPublicationEvidence -CandidateCommit $CandidateCommit -FileName "ai-rules-1c.json" -Evidence $evidence
    return [pscustomobject]$evidence
}

function Invoke-DeliveryGitHubCli {
    param([string[]]$Arguments, [switch]$AllowFailure)
    $gh = Get-Command gh -ErrorAction SilentlyContinue
    if (-not $gh) { throw "GitHub CLI is required for GitHub-backed delivery publication." }
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        # Windows PowerShell converts native stderr redirected through the success
        # stream into ErrorRecord objects. Keep the native exit code authoritative
        # so expected probes such as `gh release view` for a missing release can be
        # classified by the caller when -AllowFailure is used.
        $ErrorActionPreference = "Continue"
        $output = @(& $gh.Source @Arguments 2>&1 | ForEach-Object { [string]$_ })
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if (-not $AllowFailure -and $exitCode -ne 0) { throw "gh $($Arguments -join ' ') failed: $($output -join '; ')" }
    return [pscustomobject]@{ exitCode = [int]$exitCode; output = $output; text = ($output -join "`n") }
}

function Save-DeliveryComponentPublicationEvidence {
    param([string]$CandidateCommit, [string]$FileName, [object]$Evidence)
    $root = Join-Path (Get-DeliveryCommonGitDirectory) "itl\component-publications\$CandidateCommit"
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    [IO.File]::WriteAllText((Join-Path $root $FileName), (($Evidence | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
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
    Save-DeliveryComponentPublicationEvidence -CandidateCommit $CandidateCommit -FileName "vanessa-automation.json" -Evidence $evidence
    return [pscustomobject]$evidence
}

function Get-DeliveryExactOnDemandMcpCandidate {
    param([string]$CandidateRoot, [object]$Lock)
    $expected = ([string]$Lock.sha256).ToLowerInvariant()
    $override = [Environment]::GetEnvironmentVariable("ITL_ONDEMAND_MCP_SOURCE_BUILD_EXE", "Process")
    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($override)) { $candidates += [IO.Path]::GetFullPath($override) }
    $candidates += Join-Path $CandidateRoot ("tools\itl-ondemand-mcp\build\" + [string]$Lock.assetName)
    foreach ($path in @($candidates | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -cne $expected) { throw "On-demand MCP source-build SHA256 mismatch. expected='$expected'; actual='$actual'; path='$path'." }
        return $path
    }
    throw "The immutable on-demand MCP URL is absent and no exact Release-qualified source build is available."
}

function Invoke-OnDemandMcpComponentPublicationFinalize {
    param([string]$CandidateRoot, [string]$CandidateCommit)
    $lock = (Get-Content -LiteralPath (Join-Path $CandidateRoot "templates\dependency-lock.json") -Raw -Encoding UTF8 | ConvertFrom-Json).dependencies.itlOndemandMcp
    foreach ($field in @("releaseTag", "url", "assetName", "sha256", "version")) {
        if ($null -eq $lock.PSObject.Properties[$field] -or [string]::IsNullOrWhiteSpace([string]$lock.$field)) { throw "On-demand MCP component lock is missing '$field'." }
    }
    $expectedSha = ([string]$lock.sha256).ToLowerInvariant()
    if ($expectedSha -notmatch '^[a-f0-9]{64}$') { throw "On-demand MCP component lock has an invalid SHA256: $expectedSha" }
    $repository = Get-DeliveryGitHubRepository -CandidateRoot $CandidateRoot
    $uri = [Uri]([string]$lock.url)
    $urlMatch = [regex]::Match($uri.AbsolutePath, '^/(?<owner>[^/]+)/(?<repo>[^/]+)/releases/download/(?<tag>[^/]+)/(?<asset>[^/]+)$')
    if ($uri.Scheme -ne "https" -or $uri.Host -ne "github.com" -or -not $urlMatch.Success) { throw "On-demand MCP immutable URL is not an exact GitHub release asset URL: $($lock.url)" }
    $urlOwner = [Uri]::UnescapeDataString($urlMatch.Groups["owner"].Value)
    $urlRepo = [Uri]::UnescapeDataString($urlMatch.Groups["repo"].Value)
    $urlTag = [Uri]::UnescapeDataString($urlMatch.Groups["tag"].Value)
    $urlAsset = [Uri]::UnescapeDataString($urlMatch.Groups["asset"].Value)
    if ($urlOwner -cne $repository.owner -or $urlRepo -cne $repository.repo -or $urlTag -cne [string]$lock.releaseTag -or $urlAsset -cne [string]$lock.assetName) {
        throw "On-demand MCP immutable URL owner/repo/tag/asset does not match origin, releaseTag, and assetName."
    }

    $remote = Get-DeliveryRemoteAssetState -Url ([string]$lock.url) -ExpectedSha256 $expectedSha
    $mutated = $false
    if ($remote.status -eq "missing") {
        if (-not $RequireRelease) { throw "The locked on-demand MCP asset is not published. Exact candidate Release qualification is mandatory." }
        $candidatePath = Get-DeliveryExactOnDemandMcpCandidate -CandidateRoot $CandidateRoot -Lock $lock
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
                [void](Invoke-WorktreeGit -Root $CandidateRoot -Arguments @("tag", "-a", [string]$lock.releaseTag, $CandidateCommit, "-m", "ITL on-demand MCP $($lock.version)"))
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
            [void](Invoke-DeliveryGitHubCli -Arguments @("release", "create", [string]$lock.releaseTag, "--repo", $repository.slug, "--verify-tag", "--title", [string]$lock.releaseTag, "--notes", "Immutable ITL on-demand MCP $($lock.version)."))
            $mutated = $true
            $releaseView = Invoke-DeliveryGitHubCli -Arguments @("release", "view", [string]$lock.releaseTag, "--repo", $repository.slug, "--json", "assets")
        }
        $release = $releaseView.text | ConvertFrom-Json
        if (@($release.assets | Where-Object { [string]$_.name -ceq [string]$lock.assetName }).Count -eq 0) {
            [void](Invoke-DeliveryGitHubCli -Arguments @("release", "upload", [string]$lock.releaseTag, $candidatePath, "--repo", $repository.slug))
            $mutated = $true
        }
        $remote = Get-DeliveryRemoteAssetState -Url ([string]$lock.url) -ExpectedSha256 $expectedSha -AvailabilityAttempts 12
        if ($remote.status -ne "matched") { throw "The on-demand MCP component was finalized, but its immutable URL is still unavailable." }
    }

    $evidence = [ordered]@{
        schemaVersion = 1; status = "passed"; component = "itlOndemandMcp"; candidateCommit = $CandidateCommit
        releaseTag = [string]$lock.releaseTag; url = [string]$lock.url; assetName = [string]$lock.assetName; sha256 = $expectedSha
        githubRepository = $repository.slug; githubMutated = $mutated; verifiedAt = [DateTime]::UtcNow.ToString("o")
    }
    Save-DeliveryComponentPublicationEvidence -CandidateCommit $CandidateCommit -FileName "itl-ondemand-mcp.json" -Evidence $evidence
    return [pscustomobject]$evidence
}

function Get-OwnedComponentPublicationPlan {
    param([string]$CandidateRoot, [string]$CandidateCommit)
    if ($script:ComponentFinalizerScript) {
        return [pscustomobject]@{ status = "planned"; requiresRelease = [bool]$RequireRelease; components = @("test-seam") }
    }
    $lock = (Get-Content -LiteralPath (Join-Path $CandidateRoot "templates\dependency-lock.json") -Raw -Encoding UTF8 | ConvertFrom-Json).dependencies
    $vanessa = Get-DeliveryRemoteAssetState -Url ([string]$lock.vanessaAutomation.url) -ExpectedSha256 ([string]$lock.vanessaAutomation.sha256)
    $onDemand = Get-DeliveryRemoteAssetState -Url ([string]$lock.itlOndemandMcp.url) -ExpectedSha256 ([string]$lock.itlOndemandMcp.sha256)
    $rulesSource = Get-DeliveryLocalAiRulesSource -Lock $lock.aiRules1c
    $rules = Get-DeliveryAiRulesRemoteState -SourceRoot $rulesSource.root -Lock $lock.aiRules1c
    if ($rules.status -in @("partial", "mismatch")) { throw "Remote ai_rules_1c release '$($lock.aiRules1c.ref)' is $($rules.status)." }
    return [pscustomobject]@{
        status = "planned"; candidateCommit = $CandidateCommit
        requiresRelease = [bool]($vanessa.status -eq "missing" -or $onDemand.status -eq "missing")
        components = @(
            [pscustomobject]@{
                name = "aiRules1c"; status = $rules.status; releaseRequired = $false
                compatibilityStatus = [string]$lock.aiRules1c.compatibilityStatus
                compatibilityPromotionRequired = ([string]$lock.aiRules1c.compatibilityStatus -cne "passed")
            },
            [pscustomobject]@{ name = "vanessaAutomation"; status = $vanessa.status; releaseRequired = [bool]($vanessa.status -eq "missing") },
            [pscustomobject]@{ name = "itlOndemandMcp"; status = $onDemand.status; releaseRequired = [bool]($onDemand.status -eq "missing") }
        )
    }
}

function Assert-ComponentPublicationFinalizerPreflight {
    param(
        [Parameter(Mandatory = $true)][string]$CandidateRoot,
        [Parameter(Mandatory = $true)][string]$CandidateCommit,
        [Parameter(Mandatory = $true)][object]$Plan
    )

    if ([string]$Plan.status -cne "planned" -or [string]$CandidateCommit -notmatch '^[a-f0-9]{40}$') {
        throw "Component publication preflight received an invalid candidate plan."
    }
    if ($script:ComponentFinalizerScript) {
        if (-not (Test-Path -LiteralPath $script:ComponentFinalizerScript -PathType Leaf)) {
            throw "Component finalizer seam was not found: $($script:ComponentFinalizerScript)"
        }
        $tokens = $null
        $parseErrors = $null
        [void][Management.Automation.Language.Parser]::ParseFile($script:ComponentFinalizerScript, [ref]$tokens, [ref]$parseErrors)
        if (@($parseErrors).Count -gt 0) {
            throw "Component finalizer seam has PowerShell parse errors: $($parseErrors[0].Message)"
        }
        return [pscustomobject]@{ status = "passed"; component = "test-seam"; candidateCommit = $CandidateCommit }
    }

    $components = @($Plan.components)
    $expectedNames = @("aiRules1c", "itlOndemandMcp", "vanessaAutomation")
    $actualNames = @($components | ForEach-Object { [string]$_.name } | Sort-Object -Unique)
    if (($actualNames -join "`n") -cne (($expectedNames | Sort-Object) -join "`n")) {
        throw "Component publication plan must contain exactly: $($expectedNames -join ', ')."
    }
    foreach ($component in $components) {
        if (-not [string]$component.status) { throw "Component publication plan '$([string]$component.name)' has no status." }
        if ([bool]$component.releaseRequired -and -not [bool]$RequireRelease) {
            throw "Component '$([string]$component.name)' requires Release qualification before finalization."
        }
    }

    $repository = Get-DeliveryGitHubRepository -CandidateRoot $CandidateRoot
    foreach ($property in @("owner", "repo", "slug")) {
        if (-not $repository.PSObject.Properties[$property] -or -not [string]$repository.$property) {
            throw "Component publication repository identity lacks '$property'."
        }
    }
    return [pscustomobject]@{ status = "passed"; candidateCommit = $CandidateCommit; githubRepository = [string]$repository.slug }
}

function Invoke-ComponentPublicationFinalizer {
    param([string]$CandidateRoot, [string]$CandidateCommit)
    if (-not $script:ComponentFinalizerScript) {
        $components = @(
            Invoke-AiRulesComponentPublicationFinalize -CandidateRoot $CandidateRoot -CandidateCommit $CandidateCommit
            Invoke-VanessaComponentPublicationFinalize -CandidateRoot $CandidateRoot -CandidateCommit $CandidateCommit
            Invoke-OnDemandMcpComponentPublicationFinalize -CandidateRoot $CandidateRoot -CandidateCommit $CandidateCommit
        )
        return [pscustomobject]@{ status = "passed"; candidateCommit = $CandidateCommit; components = $components }
    }
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
