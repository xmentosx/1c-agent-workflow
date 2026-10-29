# Source-only verification planning and negative configuration acceptance.
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
    # Only a rejected refresh leaves its merged transaction pending; a
    # production check merges nothing, so a fresh branch has no such fields.
    $pendingOperation = if ($state.PSObject.Properties['pendingMergeOperation']) { [string]$state.pendingMergeOperation } else { '' }
    $pendingStage = if ($state.PSObject.Properties['pendingMergeStage']) { [string]$state.pendingMergeStage } else { '' }
    if ([string]$state.devBranchInfoBasePath -ine [string]$receipt.infoBasePath -or
        [string]$state.infoBaseKind -cne [string]$receipt.infoBaseKind -or
        ($ExpectedAction -ceq 'refresh-dev-branch' -and ($pendingOperation -cne 'refresh-dev-branch' -or $pendingStage -cne 'merged'))) {
        throw 'DEVELOP_NEGATIVE_TARGET_OR_CONTINUATION_CHANGED'
    }
    Assert-TrackedClean -Root $Root -Label 'Rejected configuration fixture'
    return [ordered]@{ status='passed'; expectedOutcome='configuration-rejected'; sourcePath=$relative;
        sourceSha256=[string]$Expected.sourceSha256; diagnostic=$diagnostic; evidencePath=$path;
        evidenceSha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant(); proof=$receipt }
}

function Get-DevelopVerificationChangeInspection {
    param([string]$Root,[string]$Name,[object]$HelperCommand=$null)
    if($null -eq $HelperCommand){$HelperCommand=Get-Command (Join-Path $Root '.agents/skills/1c-workflow/scripts/agent-1c.ps1') -ErrorAction Stop}
    $action=$HelperCommand.Parameters['Action']
    if($null -eq $action -or 'begin-verification-change' -cnotin @($action.Attributes|Where-Object{$_ -is [Management.Automation.ValidateSetAttribute]}|ForEach-Object ValidValues)){return}
    $inspection=Invoke-InstalledAction -Name $Name -Root $Root -Action 'begin-verification-change' -TimeoutSeconds 180 -AllowFailure
    $summary=Read-CompactSummary -ProcessResult $inspection
    if([int]$inspection.exitCode -ne 0 -or $summary.status -cne 'succeeded'){
        # An explicit cumulative project retains its existing model. No other
        # inspection failure authorizes a fallback or replacement task.
        if($summary.status -ceq 'failed' -and [string]$summary.error -ceq 'VERIFICATION_CHANGE_MODEL: select ITL_VERIFICATION_MODEL=change before preparing a change plan.'){return}
        throw "DEVELOP_VERIFICATION_CHANGE_INSPECTION_FAILED: $([string]$summary.error)"
    }
    $prefix=[IO.Path]::GetFullPath($Root).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    $console=[IO.Path]::GetFullPath([string]$summary.logPath)
    if(-not $console.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'DEVELOP_VERIFICATION_CHANGE_TARGET_CHANGED'}
    $view=[IO.File]::ReadAllText($console,[Text.UTF8Encoding]::new($false,$true))|ConvertFrom-Json -ErrorAction Stop
    if($view.model -cne 'change' -or $view.status -cne 'planning' -or $view.baseTree -cnotmatch '^[a-f0-9]{40}$' -or $view.tree -cnotmatch '^[a-f0-9]{40}$'){
        throw 'DEVELOP_VERIFICATION_CHANGE_SCOPE_UNSUPPORTED: inspect the current task through its owner.'
    }
    return $view
}

function Assert-DevelopVerificationChangePaths {
    param([string[]]$Paths)
    $runtime=@('.agent-1c/dependency-lock.json','tests/verification-suites.shared.json','tests/verification-suites.branch.json')
    $runtime+=@('vanessa','yaxunit','verification-selection','verification-change','verification-modes'|ForEach-Object{".agents/skills/1c-workflow/scripts/lib/agent-1c.$_.ps1"})
    foreach($path in $Paths){
        if($path -cnotlike 'src/cf/*' -and $path -cnotlike 'tests/features/*' -and $path -cnotin $runtime){
            throw "DEVELOP_VERIFICATION_CHANGE_SCOPE_UNSUPPORTED: review '$path' before planning its verification."
        }
    }
}

function Initialize-DevelopConfigurationRejectionPlan {
    param([string]$Root,[object]$Expected,[object]$HelperCommand)
    $view=Get-DevelopVerificationChangeInspection -Root $Root -Name 'upgrade-production-change-inspect' -HelperCommand $HelperCommand
    if($null -eq $view){return}
    # This adapter plans only the immutable, previously unplanned negative copy.
    # It cannot replace another task or waive any inherited criterion.
    if($view.taskId -or @($view.criteria).Count -or @($view.requirementPaths).Count){
        throw 'DEVELOP_NEGATIVE_CHANGE_SCOPE_UNSUPPORTED: preserve the existing task and its acceptance.'
    }
    $prefix=[IO.Path]::GetFullPath($Root).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    $source=[IO.Path]::GetFullPath((Join-Path $Root ([string]$Expected.sourcePath)))
    if([string]$Expected.sourcePath -cnotlike 'src/cf/*' -or
        -not $source.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or
        (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$Expected.sourceSha256){
        throw 'DEVELOP_NEGATIVE_SOURCE_CHANGED'
    }
    $paths=@($view.changedPaths)
    Assert-DevelopVerificationChangePaths -Paths $paths
    $check='configuration-refusal'
    $expectedResult='Production configuration load rejects the original diagnostic without applying the database configuration and restores its snapshot and cursor: '+[string]$Expected.diagnostic
    $plan=[ordered]@{
        taskId='develop-configuration-rejection';taskDescription=$expectedResult
        sourceReference='PublishDevelop immutable negative configuration fixture'
        requirementPaths=@();retainedDispositions=@()
        checks=@(@{id=$check;expectedResult=$expectedResult;inputPaths=@(@($paths)+@([string]$Expected.sourcePath)|Select-Object -Unique);admissibleProof=@('runtime-observation')})
        paths=@($paths|ForEach-Object{@{path=$_;checkIds=@($check);reason='The exact candidate verifier, fixture source and test inputs must retain the original production configuration refusal before any test runner or database apply.'}})
        criteria=@(@{id='AC-configuration-refusal';expectedResult=$expectedResult;decision='check';checkIds=@($check)})
    }
    $directory=Join-Path $Root ('.agent-1c/runs/develop-configuration-rejection-'+[guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($directory)
    $planPath=Join-Path $directory 'plan.json'
    [IO.File]::WriteAllText($planPath,($plan|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
    # Only the existing installed owner may create current-change state. This
    # preparation does not complete acceptance or substitute for the Gate6 proof.
    [void](Invoke-InstalledAction -Name 'upgrade-production-change-plan' -Root $Root -Action 'begin-verification-change' -AdditionalArguments @('-VerificationEvidencePath',$planPath) -TimeoutSeconds 180)
}

function Invoke-DevelopPlannedCheck {
    param([string]$Name,[string]$Root,[int]$TimeoutSeconds=5400)
    $view=Get-DevelopVerificationChangeInspection -Root $Root -Name ($Name+'-change-inspect')
    if($null -ne $view){
        $expected='The normal unfiltered ITL check passes on the current Develop fixture source and target.'
        $criteria=@($view.criteria)
        if(($view.taskId -and $view.taskId -cne 'develop-journey') -or @($view.requirementPaths).Count -or
            ($criteria.Count -and ($criteria.Count -ne 1 -or $criteria[0].id -cne 'AC-journey-check' -or $criteria[0].expectedResult -cne $expected))){
            throw 'DEVELOP_VERIFICATION_CHANGE_SCOPE_UNSUPPORTED: preserve the existing task criteria.'
        }
        $paths=@($view.changedPaths)
        Assert-DevelopVerificationChangePaths -Paths $paths
        $checkId='vanessa/itl-develop-journey'
        $criterion=@{id='AC-journey-check';expectedResult=$expected;decision='check';checkIds=@($checkId)}
        $plan=[ordered]@{
            taskId='develop-journey';taskDescription='Qualify the current workflow through missing-suite recovery, real unfiltered verification and export.'
            sourceReference='PublishDevelop owned golden Develop journey';requirementPaths=@();retainedDispositions=@()
            checks=@(@{suiteId='itl-develop-journey'});criteria=@($criterion)
            paths=@($paths|ForEach-Object{@{path=$_;checkIds=@($checkId);reason='The owned golden source, suite and candidate verifier inputs require the current unfiltered workflow check.'}})
        }
        $directory=Join-Path $Root ('.agent-1c/runs/develop-journey-'+[guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($directory)
        $path=Join-Path $directory 'plan.json'
        [IO.File]::WriteAllText($path,($plan|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
        [void](Invoke-InstalledAction -Name ($Name+'-change-plan') -Root $Root -Action 'begin-verification-change' -AdditionalArguments @('-VerificationEvidencePath',$path) -TimeoutSeconds 180)
    }
    $result=Invoke-InstalledAction -Name $Name -Root $Root -Action 'check-dev-branch' -TimeoutSeconds $TimeoutSeconds
    [void](Assert-FreshVerificationResult -ProcessResult $result)
    if($null -ne $view){[void](Invoke-InstalledAction -Name ($Name+'-change-complete') -Root $Root -Action 'complete-verification-change' -TimeoutSeconds 180)}
    return $result
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
    Initialize-DevelopConfigurationRejectionPlan -Root $Root -Expected $Expected -HelperCommand (Get-Command -Name $helper -ErrorAction Stop)
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
