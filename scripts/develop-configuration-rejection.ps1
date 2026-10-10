# Source-only acceptance of an explicitly declared negative configuration fixture.
# This is not an installed verification override: the public action stays failed.
function Assert-DevelopConfigurationRejection {
    param([object]$ProcessResult, [object]$Expected, [string]$Root, [string]$BranchName)
    $summary = Read-CompactSummary -ProcessResult $ProcessResult
    if ([int]$ProcessResult.exitCode -eq 0 -or [string]$summary.status -cne 'failed' -or
        [string]$summary.action -cne 'refresh-dev-branch' -or
        [string]$summary.error -notmatch '^GATE6_CHECK_FAILED: step=configuration;') {
        throw 'DEVELOP_NEGATIVE_UNEXPECTED_RESULT: expected a configuration Gate6 rejection from refresh-dev-branch.'
    }
    $relative = [string]$Expected.sourcePath
    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    $source = [IO.Path]::GetFullPath((Join-Path $Root $relative))
    if (-not $relative.StartsWith('src/cf/', [StringComparison]::Ordinal) -or
        -not $source.StartsWith($rootPath, [StringComparison]::OrdinalIgnoreCase) -or
        [string]$Expected.sourceSha256 -notmatch '^[a-f0-9]{64}$' -or
        (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$Expected.sourceSha256) {
        throw 'DEVELOP_NEGATIVE_SOURCE_CHANGED: preserve the original reproducer and review the fixture contract.'
    }
    $diagnostic = [string]$Expected.diagnostic
    if ([string]::IsNullOrWhiteSpace($diagnostic) -or $diagnostic.Length -lt 20 -or
        -not ([string]$summary.error).Contains('diagnostics=' + $diagnostic + '. Do not apply')) {
        throw 'DEVELOP_NEGATIVE_DIAGNOSTIC_CHANGED: the exact declared finding was not reported.'
    }
    $console = [IO.Path]::GetFullPath([string]$summary.logPath)
    if (-not $console.StartsWith($rootPath, [StringComparison]::OrdinalIgnoreCase)) { throw 'DEVELOP_NEGATIVE_CONSOLE_TARGET_CHANGED' }
    $text = Get-Content -LiteralPath $console -Raw -Encoding UTF8
    $markers = [regex]::Matches($text, '(?m)^GATE6_REJECTION_EVIDENCE: (.+)\r?$')
    if ($markers.Count -ne 1) { throw 'DEVELOP_NEGATIVE_ROLLBACK_UNPROVEN: one current checked-load receipt is required.' }
    $path = $markers[0].Groups[1].Value.Trim()
    if (-not ([IO.Path]::GetFullPath($path)).StartsWith($rootPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'DEVELOP_NEGATIVE_RECEIPT_TARGET_CHANGED'
    }
    $receipt = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([int]$receipt.schemaVersion -ne 1 -or [string]$receipt.kind -cne 'itl-gate6-rejection' -or
        [string]$receipt.projectRoot -ine [IO.Path]::GetFullPath($Root) -or
        [string]$receipt.failure -cne [string]$summary.error -or
        $receipt.applyStarted -ne $false -or $receipt.snapshotRestored -ne $true -or $receipt.cursorRestored -ne $true -or
        $receipt.nativeOperationsReleased -ne $true -or
        [string]$receipt.snapshotSha256 -notmatch '^[a-f0-9]{64}$' -or
        [string]$receipt.sourceFingerprint -notmatch '^v2\|git-tree-sha256\|[a-f0-9]{64}$') {
        throw 'DEVELOP_NEGATIVE_ROLLBACK_UNPROVEN: the finding alone is insufficient.'
    }
    foreach ($artifact in @($receipt.artifacts)) {
        $artifactPath = [IO.Path]::GetFullPath([string]$artifact.path)
        if (-not $artifactPath.StartsWith($rootPath, [StringComparison]::OrdinalIgnoreCase) -or
            (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$artifact.sha256) {
            throw 'DEVELOP_NEGATIVE_ARTIFACT_CHANGED'
        }
    }
    if (@($receipt.artifacts).Count -ne 3) { throw 'DEVELOP_NEGATIVE_NATIVE_PROOF_MISSING' }
    $state = Get-Content -LiteralPath (Join-Path $Root ('.agent-1c/dev-branches/' + $BranchName + '.json')) -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$state.devBranchInfoBasePath -ine [string]$receipt.infoBasePath -or
        [string]$state.infoBaseKind -cne [string]$receipt.infoBaseKind -or
        [string]$state.pendingMergeOperation -cne 'refresh-dev-branch' -or [string]$state.pendingMergeStage -cne 'merged') {
        throw 'DEVELOP_NEGATIVE_TARGET_OR_CONTINUATION_CHANGED'
    }
    Assert-TrackedClean -Root $Root -Label 'Rejected configuration fixture'
    return [ordered]@{ status='passed'; expectedOutcome='configuration-rejected'; sourcePath=$relative;
        sourceSha256=[string]$Expected.sourceSha256; diagnostic=$diagnostic; evidencePath=$path;
        evidenceSha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant(); proof=$receipt }
}
