# Authoritative lookup of the locked patched Vanessa Automation source-build
# archive. Release readiness, the component finalizer and the Pester shard
# setup all resolve the archive here, in one order:
#   1. ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE (explicit; fails closed);
#   2. the canonical build path in the repository root, the caller's extra
#      search roots and every worktree of the common Git directory;
#   3. the shared SHA-addressed cache
#      <common-git-dir>/itl/dependencies/vanessa-automation/<ver>-<rev>/<sha>-<asset>;
#   4. the immutable locked URL (only when the caller allows a download).
# A source is accepted only when its SHA-256 equals the lock. A same-named
# file with other bytes is never admitted; an unpublished locked revision is
# therefore satisfied by any exact local build without a manual override.

if (-not (Get-Command Get-RepositoryGitPathList -CommandType Function -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'git-path-list.ps1')
}
if (-not (Get-Command Invoke-ItlImmutableFileAcquire -CommandType Function -ErrorAction SilentlyContinue)) {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) '.agents\skills\1c-workflow\scripts\lib\agent-1c.immutable-download.ps1')
}

function Get-VanessaSourceBuildArchiveLayout {
    param([Parameter(Mandatory = $true)][object]$Lock)
    $values = @{}
    foreach ($field in @('compatibilityVersion', 'downstreamRevision', 'assetName', 'sha256')) {
        $property = $Lock.PSObject.Properties[$field]
        $values[$field] = $(if ($property) { [string]$property.Value } else { '' })
    }
    $expected = $values.sha256.ToLowerInvariant()
    $assetName = $values.assetName
    if ($expected -cnotmatch '^[a-f0-9]{64}$' -or -not $assetName -or [IO.Path]::GetFileName($assetName) -cne $assetName -or
        -not $values.compatibilityVersion -or -not $values.downstreamRevision) {
        throw 'VANESSA_ARCHIVE_LOCK_INVALID: the vanessaAutomation lock entry needs compatibilityVersion, downstreamRevision, a plain assetName and a SHA-256.'
    }
    $folder = $values.compatibilityVersion + '-' + $values.downstreamRevision
    return [pscustomobject]@{
        sha256 = $expected
        assetName = $assetName
        folder = $folder
        relativePath = 'build\third-party\vanessa-automation\' + $folder + '\' + $assetName
        url = $(if ($Lock.PSObject.Properties['url']) { [string]$Lock.url } else { '' })
    }
}

function Get-VanessaSourceBuildWorktreeRoots {
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot)
    try {
        $records = @(Get-RepositoryGitPathList -RepositoryRoot $RepositoryRoot -Arguments @('worktree', 'list', '--porcelain', '-z'))
    } catch { return @() }
    return @(foreach ($record in $records) {
        if ([string]$record -notmatch '^worktree (.+)$') { continue }
        try { [IO.Path]::GetFullPath($Matches[1]) } catch { continue }
    })
}

function Resolve-VanessaSourceBuildArchive {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][object]$Lock,
        # Roots searched right after RepositoryRoot, before other worktrees.
        [string[]]$SearchRoot = @(),
        # Copy an exact local build into the SHA-addressed cache when absent.
        [switch]$PublishSharedCache,
        # Download the locked URL into the shared cache when nothing local matches.
        [switch]$AllowDownload,
        # Without an override, return the durable shared copy whenever it exists.
        [switch]$PreferDurable
    )
    $layout = Get-VanessaSourceBuildArchiveLayout -Lock $Lock
    $expected = $layout.sha256
    $RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
    $valid = New-Object System.Collections.Generic.List[object]
    $invalid = New-Object System.Collections.Generic.List[string]
    $seen = New-Object System.Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)

    $configured = [Environment]::GetEnvironmentVariable('ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE', 'Process')
    $configuredPath = ''
    if (-not [string]::IsNullOrWhiteSpace($configured)) {
        try { $configuredPath = [IO.Path]::GetFullPath($configured) }
        catch { throw "VANESSA_ARCHIVE_OVERRIDE_INVALID: ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE is not a valid path: $configured" }
        if (-not (Test-Path -LiteralPath $configuredPath -PathType Leaf)) {
            throw "VANESSA_ARCHIVE_OVERRIDE_INVALID: ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE does not exist: $configuredPath"
        }
        $actual = Get-ItlImmutableFileSha256 -Path $configuredPath
        if ($actual -cne $expected) {
            throw "VANESSA_ARCHIVE_OVERRIDE_INVALID: ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE SHA256 differs from the lock. expected=$expected actual=$actual path=$configuredPath"
        }
        [void]$seen.Add($configuredPath)
        $valid.Add([pscustomobject]@{ path = $configuredPath; source = 'environment' }) | Out-Null
    }

    $roots = @(@($RepositoryRoot) + @($SearchRoot | Where-Object { $_ } | ForEach-Object { [IO.Path]::GetFullPath([string]$_) }) +
        @(Get-VanessaSourceBuildWorktreeRoots -RepositoryRoot $RepositoryRoot))
    foreach ($root in $roots) {
        $candidate = [IO.Path]::GetFullPath((Join-Path $root $layout.relativePath))
        if (-not $seen.Add($candidate) -or -not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        $actual = Get-ItlImmutableFileSha256 -Path $candidate
        if ($actual -ceq $expected) { $valid.Add([pscustomobject]@{ path = $candidate; source = 'worktree' }) | Out-Null }
        else { $invalid.Add("$candidate (actual=$actual)") | Out-Null }
    }

    $sharedPath = ''
    try { $commonGitDir = Get-RepositoryCommonGitDirectory -RepositoryRoot $RepositoryRoot } catch { $commonGitDir = '' }
    if ($commonGitDir) {
        $sharedPath = [IO.Path]::GetFullPath((Join-Path $commonGitDir ('itl\dependencies\vanessa-automation\' + $layout.folder + '\' + $expected + '-' + $layout.assetName)))
        if (Test-Path -LiteralPath $sharedPath -PathType Leaf) {
            $actual = Get-ItlImmutableFileSha256 -Path $sharedPath
            # The name carries the SHA, so foreign bytes there are corruption, not drift.
            if ($actual -cne $expected) { throw "VANESSA_ARCHIVE_SHARED_CACHE_CORRUPT: shared Vanessa source-build cache entry has an impossible SHA-address mismatch: expected=$expected actual=$actual path=$sharedPath" }
            if ($seen.Add($sharedPath)) { $valid.Add([pscustomobject]@{ path = $sharedPath; source = 'shared-cache' }) | Out-Null }
        } elseif ($PublishSharedCache -and $valid.Count -gt 0) {
            # Seed the durable copy so later candidates resolve it independently
            # of worktree lifetime. The acquire helper stages, re-verifies the
            # SHA and publishes atomically; a mismatch fails closed.
            $published = Invoke-ItlImmutableFileAcquire -Source ([string]$valid[0].path) -DestinationPath $sharedPath -ExpectedSha256 $expected -Label 'Vanessa source-build shared cache' -MaxAttempts 1
            if ([string]$published.sha256 -cne $expected -or (Get-ItlImmutableFileSha256 -Path $sharedPath) -cne $expected) {
                throw "VANESSA_ARCHIVE_SHARED_CACHE_CORRUPT: shared cache publication did not preserve the locked SHA256: $sharedPath"
            }
            if ($seen.Add($sharedPath)) { $valid.Add([pscustomobject]@{ path = $sharedPath; source = 'shared-cache' }) | Out-Null }
        }
    }

    $selected = $null
    if ($valid.Count -gt 0) {
        $selected = $valid[0]
        if ($selected.source -ne 'environment' -and $PreferDurable) {
            $durable = @($valid | Where-Object { $_.source -eq 'shared-cache' } | Select-Object -First 1)
            if ($durable.Count -eq 1) { $selected = $durable[0] }
        }
    } elseif ($AllowDownload) {
        if (-not $layout.url) { throw 'VANESSA_ARCHIVE_UNAVAILABLE: the locked Vanessa URL is empty and no exact local source-build archive was found.' }
        $destination = $(if ($sharedPath) { $sharedPath } else { [IO.Path]::GetFullPath((Join-Path $RepositoryRoot $layout.relativePath)) })
        [void](Invoke-ItlImmutableFileDownload -Uri $layout.url -DestinationPath $destination -ExpectedSha256 $expected -Label 'Vanessa Automation source-build archive')
        $selected = [pscustomobject]@{ path = $destination; source = 'locked-url' }
        $valid.Add($selected) | Out-Null
    }

    return [pscustomobject]@{
        status = $(if ($selected) { 'resolved' } else { 'missing' })
        path = $(if ($selected) { [string]$selected.path } else { '' })
        sha256 = $(if ($selected) { $expected } else { '' })
        source = $(if ($selected) { [string]$selected.source } else { '' })
        candidates = @($valid | ForEach-Object { [string]$_.path })
        invalidCandidates = @($invalid)
        canonicalPath = [IO.Path]::GetFullPath((Join-Path $RepositoryRoot $layout.relativePath))
        sharedPath = $sharedPath
    }
}
