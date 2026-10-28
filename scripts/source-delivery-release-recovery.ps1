# Mutating publication composition; lifecycle and fixture owners retain their locks and receipts.
function Get-DeliveryWorkflowPackageBase {
    # A compatibility promotion is one commit over the queued candidate that only
    # records ai_rules compatibility in templates/dependency-lock.json. It installs
    # the same workflow package, so a stand on either commit is current for both;
    # Plan (unpromoted) and every retry's new promotion then agree with it.
    param([string]$CandidateRoot, [string]$Commit)
    if ($Commit -notmatch '^[0-9a-f]{40}$') { return $Commit }
    $parents = @(((Invoke-WorktreeGit -Root $CandidateRoot -Arguments @('rev-list', '--parents', '-n', '1', $Commit) -AllowFailure).stdout.Trim()) -split ' ')
    if ($parents.Count -ne 2) { return $Commit }
    $parent = [string]$parents[1]
    $other = Invoke-WorktreeGit -Root $CandidateRoot -Arguments @('diff', '--quiet', $parent, $Commit, '--', '.', ':(exclude)templates/dependency-lock.json') -AllowFailure
    if ($other.exitCode -ne 0) { return $Commit }
    try {
        $locks = foreach ($revision in @($parent, $Commit)) {
            $lock = (Invoke-WorktreeGit -Root $CandidateRoot -Arguments @('show', "${revision}:templates/dependency-lock.json")).stdout | ConvertFrom-Json
            foreach ($field in @('compatibilityStatus', 'compatibilityCheckedAt')) { $lock.dependencies.aiRules1c.PSObject.Properties.Remove($field) }
            $lock | ConvertTo-Json -Depth 32 -Compress
        }
        if ($locks[0] -cne $locks[1]) { return $Commit }
    } catch { return $Commit }
    return $parent
}

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
    $candidatePackage = Get-DeliveryWorkflowPackageBase -CandidateRoot $CandidateRoot -Commit $candidate
    $roots = @($capsules.root | Sort-Object -Unique)
    $updates = @(foreach ($target in @($root) + $roots) {
        $lock = Get-Content -LiteralPath (Join-Path $target '.agent-1c/dependency-lock.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        if ((Get-DeliveryWorkflowPackageBase -CandidateRoot $CandidateRoot -Commit ([string]$lock.dependencies.workflowPackage.commit)) -cne $candidatePackage -or
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

function Start-DeliveryStandPrewarm {
    # Pester needs no stand. While the stand owners run, the gate's own shard
    # runner warms the shared shard cache with the same candidate and fork.
    # Develop reuses only exact passed shards through its normal digest checks;
    # this warmup never decides a gate. Worker count does not enter the digest.
    param([string]$CandidateRoot)
    $runner = Join-Path $CandidateRoot 'scripts/invoke-pester-shards.ps1'
    if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) { return $null }
    try {
        $output = Join-Path $CandidateRoot 'build/test-results/delivery/stand-prewarm'
        [void][IO.Directory]::CreateDirectory($output)
        $workers = 3
        $catalogPath = Join-Path $CandidateRoot 'tests/quality-contracts.json'
        if (Test-Path -LiteralPath $catalogPath -PathType Leaf) {
            $catalog = Get-Content -LiteralPath $catalogPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($catalog.PSObject.Properties['pesterWorkers'] -and $catalog.pesterWorkers.PSObject.Properties['qualificationImplicitDefault']) { $workers = [int]$catalog.pesterWorkers.qualificationImplicitDefault }
        }
        $arguments = @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$runner,'-RepositoryRoot',$CandidateRoot,'-OutputRoot',$output,'-JunitPath',(Join-Path $output 'pester.xml'),'-WorkerCount',[string]$workers,'-RequestedWorkerCount','3','-WorkerCountDefaulted')
        $rules = Get-Variable AiRulesSource -ValueOnly -ErrorAction SilentlyContinue
        if ($rules) { $arguments += @('-AiRulesSource',[IO.Path]::GetFullPath([string]$rules)) }
        $stdout = Join-Path $output 'stand-prewarm.stdout.log'; $stderr = Join-Path $output 'stand-prewarm.stderr.log'
        $started = Start-DeliveryProcess -ArgumentList (@($arguments | ForEach-Object { ConvertTo-DeliveryNativeArgument -Value ([string]$_) }) -join ' ') -WorkingDirectory $CandidateRoot -StandardOutputPath $stdout -StandardErrorPath $stderr
        return [pscustomobject]@{process=$started.process;jobHandle=[IntPtr]$started.jobHandle;watch=[Diagnostics.Stopwatch]::StartNew();stdout=$stdout;stderr=$stderr}
    } catch {
        Write-Warning "Stand preparation continues without Pester prewarm: $($_.Exception.Message)"
        return $null
    }
}

function Stop-DeliveryStandPrewarm {
    # Preparation ends the warmup so Develop scenarios start on time; shards it
    # finished are already in the cache, unfinished ones run in the gate.
    param([object]$Prewarm)
    if ($null -eq $Prewarm) { return $null }
    $process = $Prewarm.process
    $completed = $process.HasExited
    $stopError = ''
    try {
        try {
            if (-not $completed) {
                if ($Prewarm.jobHandle -ne [IntPtr]::Zero -and $env:OS -eq 'Windows_NT') { [void](Stop-DeliveryProcessJobAndWait -JobHandle $Prewarm.jobHandle -Process $process -TimeoutMilliseconds 30000) }
                else { Stop-DeliveryProcessTree -Process $process }
            }
        } finally {
            try { Close-DeliveryProcessJob -JobHandle $Prewarm.jobHandle -Process $process }
            finally { Stop-DeliveryProcessTree -Process $process }
        }
    } catch {
        # A warmup never decides preparation; its tree was stopped best-effort.
        $stopError = $_.Exception.Message
        Write-Warning "Stand prewarm stop: $stopError"
    }
    return [pscustomobject]@{name='stand-prewarm';durationMs=[int64]$Prewarm.watch.ElapsedMilliseconds;completed=[bool]$completed;stopError=$stopError;stdout=$Prewarm.stdout;stderr=$Prewarm.stderr}
}

function Invoke-DeliveryStandPreparation {
    param([string]$CandidateRoot, [object]$Preparation, [object]$Attempt, [switch]$RequireRelease)
    if ($null -eq $Preparation) { return }
    $prewarm = Start-DeliveryStandPrewarm -CandidateRoot $CandidateRoot
    try { Invoke-DeliveryStandPreparationOwners -CandidateRoot $CandidateRoot -Preparation $Preparation -Attempt $Attempt -RequireRelease:$RequireRelease }
    finally {
        $warm = Stop-DeliveryStandPrewarm -Prewarm $prewarm
        if ($warm -and $Attempt.PSObject.Properties['standPreparation']) {
            $Attempt.standPreparation | Add-Member -NotePropertyName prewarm -NotePropertyValue $warm -Force
            Write-DevelopPublicationAttempt -Attempt $Attempt
        }
    }
}

function Invoke-DeliveryStandPreparationOwners {
    param([string]$CandidateRoot, [object]$Preparation, [object]$Attempt, [switch]$RequireRelease)
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
        $captureReport = Join-Path $CandidateRoot ('build/test-results/delivery/stand-capture-'+$capsule.phase+'.json')
        $arguments = @('-File',(Join-Path $CandidateRoot 'scripts/source-e2e-fixture.ps1'),'-Action','Capture','-ProjectRoot',$Preparation.projectRoot,'-Phase',$capsule.phase,'-OutputPath',$captureReport)
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
