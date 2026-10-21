# Source-only acceptance of an explicitly declared negative configuration fixture.
# This is not an installed verification override: the public action stays failed.
function Assert-DevelopConfigurationRejection {
    param([object]$ProcessResult, [object]$Expected, [string]$Root, [string]$BranchName,
        [ValidateSet('refresh-dev-branch','check-dev-branch')][string]$ExpectedAction='refresh-dev-branch')
    $summary = Read-CompactSummary -ProcessResult $ProcessResult
    if ([int]$ProcessResult.exitCode -eq 0 -or [string]$summary.status -cne 'failed' -or
        [string]$summary.action -cne $ExpectedAction -or
        [string]$summary.error -notmatch '^GATE6_CHECK_FAILED: step=configuration;') {
        throw "DEVELOP_NEGATIVE_UNEXPECTED_RESULT: expected a configuration Gate6 rejection from $ExpectedAction."
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
    if ([string]::IsNullOrWhiteSpace($diagnostic) -or $diagnostic.Length -lt 20) {
        throw 'DEVELOP_NEGATIVE_DIAGNOSTIC_CHANGED: the exact declared finding was not reported.'
    }
    $console = [IO.Path]::GetFullPath([string]$summary.logPath)
    if (-not $console.StartsWith($rootPath, [StringComparison]::OrdinalIgnoreCase)) { throw 'DEVELOP_NEGATIVE_CONSOLE_TARGET_CHANGED' }
    # The terminal run status forwards the child's result artifact through reexec.
    # Its host output need not be present in the parent's compact console.
    $path = [string]$summary.resultPath
    if ([string]::IsNullOrWhiteSpace($path)) { throw 'DEVELOP_NEGATIVE_ROLLBACK_UNPROVEN: one current checked-load receipt is required.' }
    if (-not ([IO.Path]::GetFullPath($path)).StartsWith($rootPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'DEVELOP_NEGATIVE_RECEIPT_TARGET_CHANGED'
    }
    $receipt = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    $failure = [string]$summary.error
    if ([string]$receipt.failure -cne $failure) {
        # Compact output bounds error text. Bind its full terminal message to
        # this same console and receipt instead of treating truncation as a
        # failed rollback. The public failure and its display budget stay intact.
        $statusPath = Join-Path (Split-Path -Parent $console) 'status.json'
        try { $terminal = Get-Content -LiteralPath $statusPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
        catch { throw 'DEVELOP_NEGATIVE_ROLLBACK_UNPROVEN: the current terminal status is required for a bounded error.' }
        if ([string]$terminal.projectRoot -ine [IO.Path]::GetFullPath($Root) -or
            [string]$terminal.action -cne $ExpectedAction -or [string]$terminal.status -cne 'failed' -or
            [string]$terminal.exitCode -cne [string]$ProcessResult.exitCode -or
            [string]$terminal.logPath -ine $console -or [string]$terminal.resultPath -ine $path -or
            [string]$terminal.error -cne $failure -or
            [string]$terminal.errorMessage -cne [string]$receipt.failure) {
            throw 'DEVELOP_NEGATIVE_ROLLBACK_UNPROVEN: the bounded error must identify this exact terminal failure and receipt.'
        }
        $failure = [string]$terminal.errorMessage
    }
    if ([int]$receipt.schemaVersion -ne 1 -or [string]$receipt.kind -cne 'itl-gate6-rejection' -or
        [string]$receipt.projectRoot -ine [IO.Path]::GetFullPath($Root) -or
        [string]$receipt.failure -cne $failure -or
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
    # The load owner retains three native artifacts and, on newer versions,
    # exact diagnostic/context artifacts. Unknown additions are not admission.
    $requiredCount=3
    foreach($field in @('diagnostics','legacyContextAssessment')) {
        $property=$receipt.PSObject.Properties[$field]
        if($null -eq $property -or $null -eq $property.Value){continue}
        $extra=$property.Value
        $extraPath=if($field -ceq 'diagnostics'){[string]$extra.path}else{[string]$extra.evidencePath}
        $extraSha=if($field -ceq 'diagnostics'){[string]$extra.sha256}else{[string]$extra.evidenceSha256}
        if(@($receipt.artifacts).Count -le $requiredCount -or
            [string]$receipt.artifacts[$requiredCount].path -ine $extraPath -or
            $extraSha -cnotmatch '^[a-f0-9]{64}$' -or
            [string]$receipt.artifacts[$requiredCount].sha256 -cne $extraSha){throw 'DEVELOP_NEGATIVE_NATIVE_PROOF_MISSING'}
        $requiredCount++
    }
    if (@($receipt.artifacts).Count -ne $requiredCount -or
        $failure -notmatch '; result=(.+?); log=(.+?); diagnostics=') { throw 'DEVELOP_NEGATIVE_NATIVE_PROOF_MISSING' }
    if([string]$receipt.artifacts[0].path -ine $Matches[1] -or
        [string]$receipt.artifacts[1].path -ine $Matches[2]){throw 'DEVELOP_NEGATIVE_NATIVE_PROOF_MISSING'}
    if(-not (Read-DesignerBatchStrictUtf8Text -Path ([string]$receipt.artifacts[1].path)).Contains($diagnostic)) {
        throw 'DEVELOP_NEGATIVE_DIAGNOSTIC_CHANGED: the exact declared finding was not reported in the hashed native log.'
    }
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

function Invoke-DevelopConfigurationRejectionScenario {
    param([string]$Root,[string]$BranchName,[object]$Expected)
    $helper=Join-Path $Root '.agents/skills/1c-workflow/scripts/agent-1c.ps1'
    $production= (Test-Path -LiteralPath $helper -PathType Leaf) -and
        (Get-Command -Name $helper -ErrorAction Stop).Parameters.ContainsKey('ResultPurpose')
    if(-not $production) {
        $result=Invoke-DevelopUpgradeRefresh -Name 'upgrade-refresh-branch' -Root $Root -BranchName $BranchName -ExpectedConfigurationRejection $Expected
        return Assert-DevelopConfigurationRejection -ProcessResult $result -Expected $Expected -Root $Root -BranchName $BranchName
    }
    # Check the original pending fixture before development refresh can apply
    # or complete it. Production uses the existing checked-load rollback owner.
    $result=Invoke-InstalledAction -Name 'upgrade-production-check' -Root $Root -Action 'check-dev-branch' `
        -AdditionalArguments @('-ResultPurpose','production','-ConfigLoadMode','Full') -TimeoutSeconds 5400 -AllowFailure
    $proof=Assert-DevelopConfigurationRejection -ProcessResult $result -Expected $Expected -Root $Root -BranchName $BranchName -ExpectedAction 'check-dev-branch'
    $refresh=Invoke-DevelopUpgradeRefresh -Name 'upgrade-refresh-branch' -Root $Root -BranchName $BranchName -AdditionalArguments @('-ConfigLoadMode','Full')
    $summary=Read-CompactSummary -ProcessResult $refresh
    if([int]$refresh.exitCode -ne 0 -or [string]$summary.status -cne 'succeeded' -or [string]$summary.action -cne 'refresh-dev-branch'){
        throw 'DEVELOP_NEGATIVE_DEVELOPMENT_REFRESH_FAILED: the production refusal must retain ordinary development continuation.'
    }
    $proof['productionAction']='check-dev-branch'
    $proof['developmentRefresh']='succeeded'
    return $proof
}
