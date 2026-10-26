function Test-SourceE2ELegacyUpdateEvidence {
    param([object]$ProcessResult, [string]$Root, [string]$CandidateRoot, [datetime]$StartedAt)
    # A compact parent may only report POST_COPY_INCOMPLETE. Admit the exact
    # fresh child's terminal guard, never recovery prose or an older run.
    try {
        $summary = Read-SourceE2ECompactSummary -ProcessResult $ProcessResult
        if ([int]$ProcessResult.exitCode -eq 0 -or $summary.action -cne 'update-workflow' -or
            $summary.status -cne 'failed' -or $summary.blockerRequiresUserDecision -ne $false) { return $false }
        $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd('\','/')
        $candidatePath = [IO.Path]::GetFullPath($CandidateRoot).TrimEnd('\','/')
        $statusPath = [IO.Path]::GetFullPath([string]$summary.statusPath)
        $runsPath = (Join-Path $rootPath '.agent-1c/runs') + [IO.Path]::DirectorySeparatorChar
        if (-not $statusPath.StartsWith($runsPath, [StringComparison]::OrdinalIgnoreCase) -or
            [IO.Path]::GetFileName($statusPath) -cne 'status.json') { return $false }
        $matches = @(Get-ChildItem -LiteralPath (Split-Path -Parent $statusPath) -Filter 'status.json.fresh-*.json' -File | ForEach-Object {
            $status = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($status.action -ceq 'update-workflow' -and $status.status -ceq 'failed' -and
                $status.stage -ceq 'workflow-update.post-copy' -and [int]$status.exitCode -ne 0 -and
                $status.blockerRequiresUserDecision -eq $false -and
                ([datetimeoffset]$status.startedAt).UtcDateTime -ge $StartedAt.ToUniversalTime() -and
                [string]::Equals([IO.Path]::GetFullPath([string]$status.projectRoot).TrimEnd('\','/'), $rootPath, [StringComparison]::OrdinalIgnoreCase) -and
                [string]$status.errorMessage -cmatch '^(UI_TESTING_POLICY_LEGACY_SNAPSHOT|VERIFICATION_MODEL_POLICY_LEGACY_SNAPSHOT):' -and
                ([string]$status.errorMessage).Contains("Original candidate: '$candidatePath'.")) { $status }
        })
        return $matches.Count -eq 1
    } catch { return $false }
}

function Invoke-SourceE2EWorkflowUpdate {
    param([string]$Root, [string]$CandidateRoot, [string]$AgentTarget, [int]$TimeoutSeconds,
        [scriptblock]$InstalledOperation, [scriptblock]$SourceOperation)
    $started = [datetime]::UtcNow
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $initial = & $InstalledOperation $TimeoutSeconds
        $continuation = $null
        if ([int]$initial.exitCode -ne 0) {
            if (-not (Test-SourceE2ELegacyUpdateEvidence -ProcessResult $initial -Root $Root -CandidateRoot $CandidateRoot -StartedAt $started)) {
                throw "SOURCE_E2E_UPDATE_FAILED: legacy continuation refused; original logs=$($initial.stdout), $($initial.stderr)"
            }
            $remaining = [int][math]::Floor($TimeoutSeconds - $watch.Elapsed.TotalSeconds)
            if ($remaining -lt 1) { throw "SOURCE_E2E_UPDATE_TIMEOUT: original operation budget exhausted; logs=$($initial.stdout)" }
            # The existing source updater alone owns snapshot admission, resume,
            # rollback and branch rollout. There is no E2E receipt/state repair.
            $arguments = @('-ProjectRoot',$Root,'-SourceRoot',$CandidateRoot,'-Recovery','update','-AgentTarget',$AgentTarget)
            $continuation = & $SourceOperation (Join-Path $CandidateRoot 'scripts/update-installed-workflow.ps1') $arguments $remaining
            if ([int]$continuation.exitCode -ne 0) {
                throw "SOURCE_E2E_UPDATE_CONTINUATION_FAILED: original logs=$($initial.stdout); continuation logs=$($continuation.stdout), $($continuation.stderr)"
            }
        } else {
            $summary = Read-SourceE2ECompactSummary -ProcessResult $initial
            if ($summary.action -cne 'update-workflow' -or $summary.status -cne 'succeeded') { throw "SOURCE_E2E_UPDATE_FAILED: invalid successful summary; logs=$($initial.stdout)" }
        }
        return [pscustomobject]@{ initial=$initial; continuation=$continuation; durationMs=[int64]$watch.ElapsedMilliseconds }
    } finally { $watch.Stop() }
}
