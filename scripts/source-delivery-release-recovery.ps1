# Mutating publication composition; lifecycle and fixture owners retain their locks and receipts.
function Get-DeliveryStandPreparation {
    param([string]$CandidateRoot, [string]$BaseCommit, [switch]$RequireRelease)
    if ($script:DeliveryCustomGateBoundary) { return $null }
    # Candidate policy is evaluated in a local function scope, as in the plan
    # calculator. No stand fingerprints or expensive fixture SHA walks yet.
    $journeys = @(& {
        . (Join-Path $CandidateRoot 'scripts/develop-e2e-qualification.ps1')
        $catalog = Get-QualityContractCatalog -RepositoryRoot $CandidateRoot
        [void](Test-QualityContractCatalog -RepositoryRoot $CandidateRoot -Catalog $catalog)
        $selection = Resolve-DevelopE2EJourneyPlanCore -RepositoryRoot $CandidateRoot -BaseRef $BaseCommit -Catalog $catalog
        if (@($selection.unknownPaths).Count) { throw 'QUALITY_OWNER_MISSING: cannot prepare an unowned selection.' }
        $selection.journeys
    })
    # check.ps1 admits both shared-master capsules before either phase binds
    # stand identity. Keep that existing closure; other registered branches and
    # read-only context/receipt references are outside the update write set.
    $phases = @(if ($journeys.Count -or $RequireRelease) { 'Release'; 'Develop' })
    if (-not $phases.Count) { return $null }
    if (-not $E2EProjectRoot) { throw 'DELIVERY_STAND_PREPARATION_ROOT_REQUIRED: configure the registered E2E stand before publication.' }
    $root = [IO.Path]::GetFullPath($E2EProjectRoot).TrimEnd('\','/')
    $config = Get-Content -LiteralPath (Join-Path $root '.agent-1c/release-e2e.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $capsules = @(foreach ($phase in $phases) {
        if (-not $config.PSObject.Properties['qualificationFixtures'] -or -not $config.qualificationFixtures.PSObject.Properties[$phase]) {
            throw "FIXTURE_EXISTING_CAPSULE_REQUIRED: prepare the published $phase baseline through source-e2e-fixture Capture before publication; automatic preparation never creates or replaces a baseline."
        }
        $descriptor = $config.qualificationFixtures.$phase
        if ((Get-FileHash -LiteralPath ([string]$descriptor.path) -Algorithm SHA256).Hash -ine [string]$descriptor.sha256) { throw 'FIXTURE_CAPSULE_SHA_MISMATCH' }
        $manifest = Get-Content -LiteralPath ([string]$descriptor.path) -Raw -Encoding UTF8 | ConvertFrom-Json
        $branch = [IO.Path]::GetFullPath([string]$manifest.sourceBranchRoot).TrimEnd('\','/')
        $configuredBranch = if ($phase -eq 'Develop') { [string]$config.developWorktreePath } else { [string]$config.worktreePath }
        if ($branch -ine [IO.Path]::GetFullPath($configuredBranch).TrimEnd('\','/') -or
            (Get-RepositoryCommonGitDirectory -RepositoryRoot $root) -ine (Get-RepositoryCommonGitDirectory -RepositoryRoot $branch)) {
            throw 'FIXTURE_SEED_NOT_REGISTERED: selected capsule and configured branch must share the registered stand.'
        }
        $masterHead = (Invoke-RepositoryGit -RepositoryRoot $root -Arguments @('rev-parse','HEAD')).stdout.Trim()
        $branchHead = (Invoke-RepositoryGit -RepositoryRoot $branch -Arguments @('rev-parse','HEAD')).stdout.Trim()
        $admission = $descriptor.PSObject.Properties['workflowUpdateAdmission']
        $admittedMaster = if ($admission) { [string]$admission.Value.master.head } else { [string]$manifest.masterCommit }
        $admittedBranch = if ($admission) { [string]$admission.Value.branch.head } else { [string]$manifest.branchCommit }
        [pscustomobject]@{phase=$phase;path=[string]$descriptor.path;sha256=[string]$descriptor.sha256;root=$branch;needsAdmission=($masterHead -cne $admittedMaster -or $branchHead -cne $admittedBranch)}
    })
    $candidate = (Invoke-WorktreeGit -Root $CandidateRoot -Arguments @('rev-parse','HEAD')).stdout.Trim()
    $roots = @($capsules.root | Sort-Object -Unique)
    $updates = @(foreach ($target in @($root) + $roots) {
        $lock = Get-Content -LiteralPath (Join-Path $target '.agent-1c/dependency-lock.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([string]$lock.dependencies.workflowPackage.commit -cne $candidate -or
            @(Get-ChildItem -LiteralPath (Join-Path $target '.agent-1c/snapshots/workflow-update') -Directory -Filter 'itl-workflow-update-rollback-*' -ErrorAction SilentlyContinue).Count) { $target }
    })
    return [pscustomobject]@{schemaVersion=1;projectRoot=$root;sourceCommit=$candidate;roots=$roots;capsules=$capsules;updateRoots=$updates;
        steps=@('recover-interrupted-release','update-selected-workflow-roots','validate-and-admit-existing-capsules','release-readiness','freeze-execution-plan');
        estimatedSeconds=$null;basis='preparation-not-yet-measured';requiresWorkflowUpdate=[bool]$updates.Count;
        requiresStateChange=([bool]$updates.Count -or @($capsules | Where-Object needsAdmission).Count -gt 0)}
}

function Invoke-DeliveryStandOwner {
    param([string]$CandidateRoot, [string]$Name, [string[]]$Arguments, [int]$BudgetSeconds)
    $logs = Join-Path $CandidateRoot 'build/test-results/delivery'
    [void][IO.Directory]::CreateDirectory($logs)
    $stdout = Join-Path $logs ($Name + '.stdout.log'); $stderr = Join-Path $logs ($Name + '.stderr.log')
    $quoted = @(@('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass') + $Arguments | ForEach-Object { ConvertTo-DeliveryNativeArgument -Value ([string]$_) })
    $process = $null; $job = [IntPtr]::Zero; $priorError = ''
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $started = Start-DeliveryProcess -ArgumentList ($quoted -join ' ') -WorkingDirectory $CandidateRoot -StandardOutputPath $stdout -StandardErrorPath $stderr
        $process = $started.process; $job = [IntPtr]$started.jobHandle
        while (-not $process.WaitForExit(5000)) {
            if ($watch.Elapsed.TotalSeconds -ge $BudgetSeconds) { throw "DELIVERY_STAND_PREPARATION_TIMEOUT: $Name; resume the same PublishDevelop after inspecting owner logs $stdout and $stderr; receipts and capsules were preserved." }
        }
        $process.WaitForExit(); $process.Refresh()
        if ([int]$process.ExitCode -ne 0) { throw "DELIVERY_STAND_PREPARATION_FAILED: $Name exited $($process.ExitCode); follow its owner continuation in $stdout and $stderr, then repeat the same PublishDevelop." }
        return [pscustomobject]@{name=$Name;durationMs=[int64]$watch.ElapsedMilliseconds;stdout=$stdout;stderr=$stderr}
    } catch { $priorError=$_.Exception.Message; throw } finally {
        try { Close-DeliveryProcessJob -JobHandle $job -Process $process -PriorErrorMessage $priorError }
        finally { Stop-DeliveryProcessTree -Process $process }
    }
}

function Invoke-DeliveryStandPreparation {
    param([string]$CandidateRoot, [object]$Preparation, [object]$Attempt, [switch]$RequireRelease)
    if ($null -eq $Preparation) { return }
    $prior = if ($Attempt.PSObject.Properties['standPreparation']) { $Attempt.standPreparation } else { $null }
    # The original capsule identities and scope survive partial preparation.
    $identity = [ordered]@{projectRoot=$Preparation.projectRoot;sourceCommit=$Preparation.sourceCommit;roots=@($Preparation.roots);capsules=@($Preparation.capsules | Select-Object phase,path,sha256,root)}
    if ($prior -and (Get-DeliveryCanonicalJsonSha256 -Value $prior.identity) -cne (Get-DeliveryCanonicalJsonSha256 -Value $identity)) {
        throw 'DELIVERY_STAND_PREPARATION_CHANGED: restore the original selected roots and capsule SHA before resuming the unplanned checkpoint.'
    }
    $record = [pscustomobject]@{identity=$identity;status='running';steps=@();startedAt=[DateTime]::UtcNow.ToString('o')}
    $Attempt | Add-Member -NotePropertyName standPreparation -NotePropertyValue $record -Force
    Write-DevelopPublicationAttempt -Attempt $Attempt
    if ($RequireRelease) { Invoke-DeliveryReleaseStandRecovery -CandidateRoot $CandidateRoot }
    if ($Preparation.requiresWorkflowUpdate) {
        $scopePath = Join-Path $CandidateRoot 'build/test-results/delivery/stand-update-roots.json'
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $scopePath))
        [IO.File]::WriteAllText($scopePath, ([ordered]@{schemaVersion=1;projectRoot=$Preparation.projectRoot;sourceCommit=$Preparation.sourceCommit;roots=@($Preparation.roots)} | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        $record.steps += Invoke-DeliveryStandOwner -CandidateRoot $CandidateRoot -Name 'stand-workflow-update' -BudgetSeconds 3600 -Arguments @('-File',(Join-Path $CandidateRoot 'scripts/update-installed-workflow.ps1'),'-ProjectRoot',$Preparation.projectRoot,'-SourceRoot',$CandidateRoot,'-WorkflowUpdateBranchRootsFile',$scopePath)
        Write-DevelopPublicationAttempt -Attempt $Attempt
    }
    foreach ($capsule in $Preparation.capsules) {
        # Capture owns full chain/backup, environment, business bytes and original
        # DB SHA validation. Admission cannot bless an arbitrary stand change.
        $arguments = @('-File',(Join-Path $CandidateRoot 'scripts/source-e2e-fixture.ps1'),'-Action','Capture','-ProjectRoot',$Preparation.projectRoot,'-Phase',$capsule.phase)
        if ($Preparation.requiresWorkflowUpdate -or $capsule.needsAdmission) { $arguments += '-AcknowledgeWorkflowUpdate' }
        $client = Get-Variable AgentTarget -ValueOnly -ErrorAction SilentlyContinue
        if ($client) { $arguments += @('-AgentTarget',[string]$client) }
        $record.steps += Invoke-DeliveryStandOwner -CandidateRoot $CandidateRoot -Name ('stand-capture-'+$capsule.phase) -BudgetSeconds 900 -Arguments $arguments
        if ((Get-FileHash -LiteralPath $capsule.path -Algorithm SHA256).Hash -ine $capsule.sha256) { throw 'FIXTURE_CAPSULE_SHA_MISMATCH: preparation must preserve the original baseline.' }
        Write-DevelopPublicationAttempt -Attempt $Attempt
    }
    $record.status='passed'
    $record | Add-Member -NotePropertyName durationMs -NotePropertyValue ([int64]([DateTime]::UtcNow - [DateTime]::Parse($record.startedAt).ToUniversalTime()).TotalMilliseconds)
    Write-DevelopPublicationAttempt -Attempt $Attempt
}

function Invoke-DeliveryReleaseStandRecovery {
    param([Parameter(Mandatory = $true)][string]$CandidateRoot)

    if ($script:DeliveryCustomGateBoundary) { return }
    $runner = Join-Path $CandidateRoot 'scripts\invoke-release-e2e.ps1'
    if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) { return }
    $tokens = $null; $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($runner, [ref]$tokens, [ref]$parseErrors)
    if (@($parseErrors).Count -gt 0) { throw "Release recovery runner has parse errors: $runner" }
    # A published master supervisor can qualify an older candidate. Preserve its
    # ordinary readiness path when that candidate predates this internal mode.
    if (-not $ast.ParamBlock -or @($ast.ParamBlock.Parameters | Where-Object {
        $_.Name.VariablePath.UserPath -ceq 'RecoverInterruptedExtensionOnly'
    }).Count -eq 0) { return }
    if (-not $E2EProjectRoot -or -not $AiRulesSource) {
        throw 'Release recovery requires the configured E2E project and exact controlled-fork checkout.'
    }

    $logRoot = Join-Path $CandidateRoot 'build\test-results\delivery'
    [void][IO.Directory]::CreateDirectory($logRoot)
    $stdout = Join-Path $logRoot 'release-stand-recovery.stdout.log'
    $stderr = Join-Path $logRoot 'release-stand-recovery.stderr.log'
    $arguments = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $runner,
        '-ProjectRoot', ([IO.Path]::GetFullPath($E2EProjectRoot)),
        '-AiRulesSource', ([IO.Path]::GetFullPath($AiRulesSource)),
        '-ResumeMode', $ReleaseResumeMode, '-RecoverInterruptedExtensionOnly')
    $clientParameter = Get-Variable -Name AgentTarget -ErrorAction SilentlyContinue
    if ($clientParameter -and -not [string]::IsNullOrWhiteSpace([string]$clientParameter.Value)) {
        $arguments += @('-AgentTarget', [string]$clientParameter.Value)
    }
    $quoted = @($arguments | ForEach-Object { ConvertTo-DeliveryNativeArgument -Value ([string]$_) })
    $process = $null; $job = [IntPtr]::Zero; $priorError = ''
    try {
        $started = Start-DeliveryProcess -ArgumentList ($quoted -join ' ') -WorkingDirectory $CandidateRoot -StandardOutputPath $stdout -StandardErrorPath $stderr
        $process = $started.process; $job = [IntPtr]$started.jobHandle
        # The existing guarded restore owns 7200 seconds; allow its cleanup and
        # process finalization without inheriting an expired capability deadline.
        $watch = [Diagnostics.Stopwatch]::StartNew()
        while (-not $process.WaitForExit(5000)) {
            if ($watch.Elapsed.TotalSeconds -ge 7800) {
                if ($job -ne [IntPtr]::Zero -and $env:OS -eq 'Windows_NT') {
                    [void](Stop-DeliveryProcessJobAndWait -JobHandle $job -Process $process)
                } else { Stop-DeliveryProcessTree -Process $process }
                throw "Release stand recovery exceeded its bounded restore allowance. See $stdout and $stderr"
            }
        }
        $process.WaitForExit(); $process.Refresh()
        if ([int]$process.ExitCode -ne 0) {
            throw "Release stand recovery failed with exit code $($process.ExitCode). See $stdout and $stderr"
        }
        # Exit zero completes only this recovery subphase, never a passed gate.
    } catch { $priorError = $_.Exception.Message; throw } finally {
        $closeError = $null
        try { Close-DeliveryProcessJob -JobHandle $job -Process $process -PriorErrorMessage $priorError } catch { $closeError = $_ }
        Stop-DeliveryProcessTree -Process $process
        if ($closeError) { throw $closeError }
    }
}
