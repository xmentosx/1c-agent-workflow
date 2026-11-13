function Get-ItlVerificationMode {
    param([ValidateSet("yaxunit", "vanessa", "event-log")][string]$Component)

    $key = switch ($Component) {
        "yaxunit" { "ITL_YAXUNIT_TESTING" }
        "vanessa" { "ITL_VANESSA_TESTING" }
        default { "ITL_CHECK_EVENT_LOG" }
    }
    $raw = [string](Get-EnvValue -Name $key -Default "")
    $normalized = $raw.Trim().ToLowerInvariant()
    $valid = [string]::IsNullOrWhiteSpace($normalized) -or $normalized -in @("auto", "manual", "off")
    $effective = $(if ($valid -and $normalized) { $normalized } else { "auto" })
    return [pscustomobject]@{
        component = $Component
        key = $key
        raw = $raw
        valid = [bool]$valid
        effective = $effective
    }
}

function Get-ItlVerificationExecutionDecision {
    param(
        [ValidateSet("yaxunit", "vanessa", "event-log")][string]$Component,
        [ValidateSet("implicit", "command", "repair", "explicit")][string]$Trigger,
        [string[]]$ExplicitComponents = @()
    )

    $mode = Get-ItlVerificationMode -Component $Component
    $namedComponent = $ExplicitComponents -contains $Component -or $ExplicitComponents -contains "all"
    $isScenarioRepair = $Trigger -eq 'repair' -and $namedComponent -and $RepairSessionId -and
        [string](Get-StateValue (Get-ItlMatchingVerificationRepairSession) 'kind' 'canonical-repair') -eq 'scenario-loop'
    $isExplicit = $namedComponent -and ($Trigger -eq 'explicit' -or $isScenarioRepair)
    # Saved Vanessa is a TOOL_BROWSER provider; UI_TESTING only selects the
    # separate interactive UI workflow. A named request is invocation-local.
    $providerKey = if ($Component -eq 'vanessa') { 'TOOL_BROWSER' } else { '' }
    $providerRaw = if ($providerKey) { [string](Get-EnvValue -Name $providerKey -Default '') } else { '' }
    $providerPolicy = $providerRaw.Trim().ToLowerInvariant()
    $providerValid = -not $providerPolicy -or $providerPolicy -in @('auto', 'off', 'required')
    if (-not $providerPolicy) { $providerPolicy = 'auto' }
    $providerOverride = $providerKey -and $providerPolicy -eq 'off' -and $isExplicit
    $outsideNamedScope = $Trigger -eq 'explicit' -and -not $namedComponent
    # A runner filter is diagnostic-only and proves nothing for the other runner;
    # its unnamed full suite would only cost time. Naming it runs it as before.
    $diagnosticFilter = if ($Component -eq 'yaxunit' -and (Test-ItlVanessaDiagnosticScope) -and -not (Test-ItlYAxUnitDiagnosticScope)) { 'Vanessa feature/tag' }
        elseif ($Component -eq 'vanessa' -and (Test-ItlYAxUnitDiagnosticScope) -and -not (Test-ItlVanessaDiagnosticScope)) { 'YAxUnit module' } else { '' }
    $outsideDiagnosticScope = $diagnosticFilter -and -not $namedComponent
    $run = if ($outsideNamedScope -or $outsideDiagnosticScope) {
        $false
    } elseif (-not $mode.valid) {
        $false
    } elseif (-not $providerValid -or ($providerPolicy -eq 'off' -and -not $providerOverride)) {
        $false
    } elseif ($isExplicit) {
        $true
    } elseif ($mode.effective -eq "auto") {
        $true
    } elseif ($mode.effective -eq "manual") {
        $Trigger -in @("command", "repair")
    } else {
        $false
    }
    $reason = if ($outsideNamedScope) {
        "$Component is outside the named invocation scope"
    } elseif ($outsideDiagnosticScope) {
        "diagnostic $diagnosticFilter filter run; name -ExplicitVerificationComponent $Component or all to include $Component"
    } elseif (-not $mode.valid) {
        "invalid $($mode.key)='$($mode.raw)'; set auto, manual, or off before running $Component"
    } elseif (-not $providerValid) {
        "invalid $providerKey='$providerRaw'; set auto, off, or required before running $Component"
    } elseif ($providerPolicy -eq 'off' -and -not $providerOverride) {
        "$providerKey=off skips $Component; only a named invocation may override this provider"
    } elseif ($run) {
        $(if ($providerOverride) { "explicit user request for $Component overrides $providerKey=off for this invocation" }
          elseif ($isExplicit) { "explicit user request for $Component" }
          else { "$($mode.effective) mode permits $Trigger verification" })
    } else {
        "$($mode.key)=$($mode.effective) skips $Component for trigger=$Trigger"
    }
    return [pscustomobject]@{
        component = $Component
        mode = $mode.effective
        rawMode = $mode.raw
        valid = $mode.valid
        trigger = $Trigger
        providerKey = $providerKey
        rawProviderPolicy = $providerRaw
        providerPolicy = $providerPolicy
        providerValid = [bool]$providerValid
        providerOverride = [bool]$providerOverride
        run = [bool]$run
        reason = $reason
    }
}

function Write-ItlVerificationModeStatus {
    foreach ($component in @("yaxunit", "vanessa", "event-log")) {
        $mode = Get-ItlVerificationMode -Component $component
        $suffix = $(if ($mode.valid) { "" } else { " (invalid '$($mode.raw)'; execution skipped until set to auto, manual, or off)" })
        Write-Host "$($mode.key)=$($mode.effective)$suffix"
    }
}

function Set-ItlLiteMode {
    param([string]$Mode)

    $normalized = $Mode.Trim().ToLowerInvariant()
    if ($normalized -eq "status" -or -not $normalized) {
        Write-ItlVerificationModeStatus
        return
    }
    $values = switch ($normalized) {
        { $_ -in @("lite", "on") } { @{ ITL_YAXUNIT_TESTING = "off"; ITL_VANESSA_TESTING = "off"; ITL_CHECK_EVENT_LOG = "off" }; break }
        "standard" { @{ ITL_YAXUNIT_TESTING = "auto"; ITL_VANESSA_TESTING = "auto"; ITL_CHECK_EVENT_LOG = "manual" }; break }
        { $_ -in @("full", "off") } { @{ ITL_YAXUNIT_TESTING = "auto"; ITL_VANESSA_TESTING = "auto"; ITL_CHECK_EVENT_LOG = "auto" }; break }
        default { throw "itl-litemode supports: lite|on|standard|full|off|status." }
    }
    Set-DotEnvValues -Values $values
    Import-DotEnv -Path (Join-Path $script:ProjectRoot ".dev.env") -Overwrite
    Write-Host "ITL verification mode changed atomically: $normalized"
    Write-ItlVerificationModeStatus
}

function Set-ItlPartialVerificationEvidence {
    param(
        [object]$State,
        [object[]]$Decisions,
        [string]$Trigger
    )

    $skipped = @($Decisions | Where-Object { -not $_.run })
    if ($skipped.Count -eq 0) { return }
    # An explicit, complete run can satisfy the same current input even when
    # persistent auto-run switches remain off. A later ordinary check must not
    # destroy that proof merely because it had no permission to rerun a tool.
    if ([string](Get-StateValue -State $State -Name 'lastVerificationStatus' -Default '') -eq 'passed') {
        $existing = Get-VerificationState -State $State
        if ($existing.isFreshPassed) {
            Write-Host 'Executable verification reused: fresh passed proof already covers this input; skipped components were not rerun.'
            return
        }
    }
    $reason = "Executable verification skipped: " + (($skipped | ForEach-Object { $_.reason }) -join "; ")
    Update-DevBranchState -State $State -Updates @{
        lastVerificationStatus = "partial"
        lastVerificationEvidenceKind = "partial/skipped"
        lastVerificationTrigger = $Trigger
        lastVerificationSkippedComponents = @($skipped | ForEach-Object { $_.component })
        lastVerificationReason = $reason
        lastVerifiedAt = (Get-Date).ToString("o")
        lastVerifiedCommit = ""
        lastVerifiedFingerprint = ""
        lastVerifiedLoadedBaseIdentity = ""
    }
    Write-Host "[WARN] $reason"
    Write-Host "Result wording: implemented; executable verification skipped. Do not report verified/done."
}

function Test-ItlEventLogCurrent {
    param(
        [object]$State,
        [string]$CursorPath = "",
        [Nullable[datetime]]$BoundaryAt = $null,
        [string]$CursorScope = "lifecycle-pending",
        [ValidateSet("implicit", "command", "repair", "explicit")][string]$Trigger = "command"
    )

    $stateWithBaseline = Ensure-DevBranchEventLogBaseline -State $State
    if (-not $CursorPath) {
        $pending = Ensure-DevBranchEventLogPendingCursor -State $stateWithBaseline -Reason "event-log-only"
        $CursorPath = $pending.path
        $BoundaryAt = $pending.capturedAt
    }
    $now = Get-Date
    $stateProjectRoot = [string](Get-StateValue -State $stateWithBaseline -Name "stateProjectRoot" -Default $script:ProjectRoot)
    $runDirectory = Join-Path $stateProjectRoot (".agent-1c\event-log-checks\run-" + $now.ToString("yyyyMMdd-HHmmss-fff"))
    New-Item -ItemType Directory -Force -Path $runDirectory | Out-Null
    $verification = Test-DevBranchEventLogAfterVanessa `
        -State $stateWithBaseline `
        -RunStartedAt $now `
        -RunFinishedAt $now `
        -RunDirectory $runDirectory `
        -CursorPath $CursorPath `
        -BoundaryStartedAt $BoundaryAt `
        -CursorScope $CursorScope
    $fingerprint = Get-VerificationFingerprint
    $debt = Resolve-DevBranchEventLogDebt -State $stateWithBaseline -Verification $verification -Fingerprint $fingerprint -Trigger $Trigger
    $verification = $debt.verification
    $updates = @{
        lastEventLogOnlyStatus = $verification.status
        lastEventLogOnlyCheckedAt = (Get-Date).ToString("o")
        lastEventLogOnlyReader = $verification.reader
        lastEventLogOnlyReason = $verification.reason
        lastEventLogOnlyNewErrorCount = $verification.newErrorCount
        lastEventLogOnlyReportPath = $verification.reportPath
        lastEventLogOnlyCursorScope = $CursorScope
        lastEventLogOnlyCursorSourceKey = [string](Get-StateValue -State $verification -Name "cursorSourceKey" -Default "")
    }
    foreach ($key in $debt.updates.Keys) { $updates[$key] = $debt.updates[$key] }
    if ($CursorScope -eq "lifecycle-pending" -and $verification.scanMode -notin @("failed", "skipped")) {
        $boundaryUpdates = Complete-DevBranchEventLogObservation -State $stateWithBaseline -Status $verification.status -Fingerprint $fingerprint -ReportPath $verification.reportPath
        foreach ($key in $boundaryUpdates.Keys) { $updates[$key] = $boundaryUpdates[$key] }
    }
    Add-VerificationComponentEvidenceUpdates -Updates $updates -State $stateWithBaseline -Component 'event-log' -Status $verification.status -EventLogObservation $verification -RunDirectory $runDirectory
    Update-DevBranchState -State $stateWithBaseline -Updates $updates
    Write-Host "Event-log verification: $($verification.status). $($verification.reason)"
    if ($verification.status -ne "passed") {
        Set-RunFailureContext -Category "event-log" -RequiredAction "/itl-verify-fix"
        throw $verification.reason
    }
}

function Get-ItlVerificationRepairStatePath {
    return (Join-Path $script:ProjectRoot ".agent-1c\verification-repair\current.json")
}

function Get-ItlVerificationRepairMaximumAttempts {
    $rawValue = Get-EnvValue -Name "ITL_VERIFICATION_REPAIR_MAX_ATTEMPTS"
    if ($null -eq $rawValue) { return $null }
    $text = ([string]$rawValue).Trim()
    $parsed = 0
    if ($text -notmatch '^\d+$' -or
        -not [int]::TryParse($text, [ref]$parsed) -or
        $parsed -lt 1 -or
        $parsed -gt 100) {
        throw "ITL_VERIFICATION_REPAIR_MAX_ATTEMPTS must be an integer between 1 and 100. Actual: '$rawValue'."
    }
    return $parsed
}

function Get-ItlVerificationRepairRecordMaximumAttempts {
    param([Parameter(Mandatory = $true)][object]$Record)

    $limit = $Record.PSObject.Properties['maximumAttempts']
    if ($null -ne $limit -and $null -eq $limit.Value -and
        (Get-StateValue $Record 'schemaVersion' 1) -eq 2 -and
        (Get-StateValue $Record 'kind' '') -ceq 'canonical-repair') { return $null }

    $maximumAttempts = 0
    if ($null -eq $limit -or
        -not [int]::TryParse(([string]$Record.maximumAttempts), [ref]$maximumAttempts) -or
        $maximumAttempts -lt 1 -or
        $maximumAttempts -gt 100) {
        Set-RunFailureContext -Category "runner" -RequiredAction "report-blocker"
        throw "Repair session $($Record.sessionId) has invalid maximumAttempts. Return blocker diagnostics; another full run is forbidden."
    }
    return $maximumAttempts
}

function Write-ItlVerificationRepairRecord {
    param([object]$Record)

    Write-Utf8TextAtomic -Path (Get-ItlVerificationRepairStatePath) -Value (($Record | ConvertTo-Json -Depth 20) + [Environment]::NewLine)
}

function Format-ItlVerificationRepairAttempts {
    param([object]$Record, [AllowNull()][object]$Maximum)

    if ($null -eq $Maximum) { return "$($Record.attempts) (no overall limit)" }
    return "$($Record.attempts)/$Maximum"
}

function Write-ItlVerificationRepairStatus {
    param([object]$Record, [AllowNull()][object]$Maximum, [string]$Label, [string]$Admission = '')

    $report = "${Label}: $($Record.sessionId). Repair attempts: $(Format-ItlVerificationRepairAttempts -Record $Record -Maximum $Maximum)."
    if ((Get-StateValue $Record 'kind' 'canonical-repair') -eq 'canonical-repair') {
        if ($Admission) { $report += " Admission: $Admission." }
        if ($Record.status -eq 'exhausted') {
            $report += ' Preserve this ID and use extend-verification-repair with an explicit user grant for a greater limit.'
        }
        if ($null -eq $Maximum -and $Record.status -eq 'active' -and [int]$Record.attempts -ge 5) {
            $report += ' Assessment required before the next full run. See references/verification-result.md.'
        }
        $report += " Repair report: $(Get-ItlVerificationRepairStatePath)"
    }
    $existing = if ($Admission) { [string](Get-Variable -Name RunUserReport -Scope Script -ValueOnly -ErrorAction SilentlyContinue) } else { '' }
    Write-Host $report
    Set-RunUserReport -Report ((@($report, $existing) | Where-Object { $_ }) -join "`n`n")
}

function New-ItlVerificationRepairRun {
    param([object]$Record, [string]$Outcome)

    $statusPath = [string](Get-Variable -Name RunStatusPath -ValueOnly -ErrorAction SilentlyContinue)
    return [pscustomobject][ordered]@{
        id = [guid]::NewGuid().ToString('N')
        attempt = [int]$Record.attempts
        outcome = $Outcome
        startedAt = (Get-Date).ToString('o')
        inputFingerprint = ''
        finishedAt = $null
        durationMs = $null
        basis = $null
        statusPath = $(if ($statusPath) { Resolve-RunFilePath -Path $statusPath } else { '' })
        result = $null
    }
}

function Get-ItlVerificationRepairRuns {
    param([object]$Record)

    $property = $Record.PSObject.Properties['runs']
    if ($null -ne $property) { $property.Value }
}

function Add-ItlVerificationRepairRun {
    param([object]$Record, [object]$Run)

    $runs = @(Get-ItlVerificationRepairRuns -Record $Record)
    if ($runs.Count -gt 0 -and $runs[-1].outcome -eq 'admitted') {
        # A different invocation reached this point under the same lifecycle lock.
        # A lost process keeps its charged admission and any existing run evidence.
        $interrupted = $runs[-1]
        $interrupted.outcome = 'interrupted'
        if ($interrupted.statusPath) {
            try {
                $status = Read-Utf8Text -Path $interrupted.statusPath | ConvertFrom-Json -ErrorAction Stop
                $lastSeen = [datetimeoffset]$status.updatedAt
                if ($lastSeen -ge [datetimeoffset]$interrupted.startedAt) {
                    $interrupted.durationMs = [int64]($lastSeen - [datetimeoffset]$interrupted.startedAt).TotalMilliseconds
                }
            } catch {
                # The wrapper can be interrupted before persisting any status.
            }
        }
    }
    Set-ItlVerificationRepairRecordValue -Record $Record -Name 'runs' -Value ($runs + @($Run))
}

function Set-ItlVerificationRepairRunOutcome {
    param([object]$Record, [AllowNull()][object]$Ticket, [string]$Outcome, [AllowNull()][object]$Result, [switch]$PassThru)

    $runId = [string](Get-StateValue $Ticket 'runId' '')
    $runs = @(Get-ItlVerificationRepairRuns -Record $Record)
    $changed = $runId -and $runs.Count -gt 0 -and $runs[-1].id -ceq $runId -and $runs[-1].outcome -eq 'admitted'
    if ($changed) {
        $run = $runs[-1]
        $now = Get-Date
        $run.outcome = $Outcome
        $run.result = $Result
        $run.finishedAt = $now.ToString('o')
        $run.durationMs = [int64]([datetimeoffset]$now - [datetimeoffset]$run.startedAt).TotalMilliseconds
    }
    if ($PassThru) { return [bool]$changed }
}

function Get-ItlVerificationRepairBasis {
    param([object[]]$Runs, [string]$Path)

    $result = [ordered]@{ present = [bool]$Path; linked = $false; evidenceCurrent = $false; status = 'missing'; details = $null }
    if (-not $Path) { return [pscustomobject]$result }
    $result.status = 'incomplete'
    try {
        $full = Resolve-ProjectPath $Path
        [void](Get-VerificationRepoRelativePath -Path $full)
        $file = Get-Item -LiteralPath $full -ErrorAction Stop
        if ($file.PSIsContainer -or $file.Length -gt 8192) { return [pscustomobject]$result }
        $basis = Read-Utf8Text -Path $full | ConvertFrom-Json -ErrorAction Stop
        $result.details = [pscustomobject][ordered]@{}
        foreach ($name in @('previousRunId', 'evidencePath', 'progress', 'change', 'expected')) {
            $value = Get-StateValue $basis $name $null
            if ($value -is [string] -and $value.Length -le 1024) {
                $result.details | Add-Member -NotePropertyName $name -NotePropertyValue $value.Trim()
            }
        }
        $previous = $Runs | Where-Object outcome -in @('completed', 'failed') | Select-Object -Last 1
        $previousId = [string](Get-StateValue $result.details 'previousRunId' '')
        $evidencePath = [string](Get-StateValue $result.details 'evidencePath' '')
        if ($previousId -and $null -ne $previous) { $result.linked = $previousId -ceq $previous.id }
        if ($previousId -and -not $result.linked) {
            $result.status = if (@($Runs | Where-Object id -CEQ $previousId).Count) { 'stale' } else { 'unrelated-result' }
        } elseif ($result.linked -and $evidencePath) {
            $evidencePath = Resolve-ProjectPath $evidencePath
            $expected = @(if ($null -ne $previous.result -and $previous.result.PSObject.Properties['evidence']) {
                $previous.result.evidence | Where-Object path -EQ $evidencePath
            })
            if ($expected.Count -eq 1) {
                $item = Get-Item -LiteralPath $evidencePath -ErrorAction SilentlyContinue
                $result.evidenceCurrent = $null -ne $item -and -not $item.PSIsContainer -and
                    $item.Length -eq $expected[0].length -and $item.LastWriteTimeUtc.Ticks -eq $expected[0].modifiedTicks
                if (-not $result.evidenceCurrent) { $result.status = 'stale-evidence' }
            } elseif ($evidencePath -and $evidencePath -ieq $previous.statusPath) {
                # The compact runner updates its status after the helper releases.
                $status = Read-Utf8Text -Path $evidencePath | ConvertFrom-Json -ErrorAction Stop
                $result.evidenceCurrent = $status.status -in @('succeeded', 'failed') -and
                    $status.action -in @('check-dev-branch', 'verify-dev-branch', 'deploy-and-test') -and
                    $status.projectRoot -ieq $script:ProjectRoot -and
                    [datetimeoffset]$status.startedAt -le [datetimeoffset]$previous.startedAt -and
                    [datetimeoffset]$status.finishedAt -ge [datetimeoffset]$previous.startedAt
                if (-not $result.evidenceCurrent) { $result.status = 'stale-status' }
            } else { $result.status = 'unrelated-evidence' }
        }
        if ($result.evidenceCurrent -and
            (Get-StateValue $result.details 'progress' '') -and
            (Get-StateValue $result.details 'change' '') -and
            (Get-StateValue $result.details 'expected' '')) {
            $result.status = 'linked'
        }
    } catch {
        $result.status = 'unreadable'
    }
    return [pscustomobject]$result
}

function Start-ItlVerificationRepairSession {
    $state = Read-DevBranchState -Name $DevBranchName
    Assert-DevelopmentBranchWorktreeContext -State $state -Operation "begin-verification-repair"
    $kind = if ($VerificationRepairKind) { $VerificationRepairKind } else { 'canonical-repair' }
    $scenarioFeature = if ($VanessaFeaturePath) { Resolve-ProjectPath $VanessaFeaturePath } else { '' }
    $scenarioTags = ([string]$VanessaFilterTags).Trim()
    if ($scenarioFeature) {
        [void](Get-VerificationRepoRelativePath -Path $scenarioFeature)
        if (-not $scenarioFeature.EndsWith('.feature', [StringComparison]::OrdinalIgnoreCase) -or
            -not (Test-Path -LiteralPath $scenarioFeature -PathType Leaf)) {
            throw "ITL_VERIFICATION_SCENARIO_FEATURE_INVALID: '$scenarioFeature' must be an existing project .feature file."
        }
    }
    if ($kind -eq 'scenario-loop' -and -not $scenarioFeature -and -not $scenarioTags) {
        throw 'ITL_VERIFICATION_SCENARIO_SCOPE_REQUIRED: scenario-loop needs VanessaFeaturePath or VanessaFilterTags before starting its bounded session.'
    }
    if ($kind -eq 'canonical-repair' -and ($scenarioFeature -or $scenarioTags)) {
        throw 'ITL_VERIFICATION_REPAIR_SCOPE_INVALID: canonical-repair is unfiltered; use scenario-loop for a named diagnostic scope.'
    }
    if ($VerificationRepairMaxAttempts -lt 0 -or $VerificationRepairMaxAttempts -gt 100) {
        throw 'ITL_VERIFICATION_REPAIR_LIMIT_INVALID: explicit attempt limit must be between 1 and 100.'
    }
    $path = Get-ItlVerificationRepairStatePath
    $recoveryId = [string](Get-StateValue $state "toolingRecoveryId" "")
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $previous = Read-Utf8Text -Path $path | ConvertFrom-Json
        if ([string]$previous.status -in @('active', 'workflow-blocked')) {
            if ([string]$previous.branch -cne (Get-CurrentBranch) -or
                -not [string]::Equals((Get-FullPathNormalized ([string]$previous.projectRoot)),
                    (Get-FullPathNormalized $script:ProjectRoot), [StringComparison]::OrdinalIgnoreCase)) {
                throw "ITL_VERIFICATION_REPAIR_ACTIVE_ELSEWHERE: session $($previous.sessionId) belongs to another branch or worktree. Preserve its record and resume it in that scope."
            }
            $maximumAttempts = Get-ItlVerificationRepairRecordMaximumAttempts -Record $previous
            $previousKind = [string](Get-StateValue $previous 'kind' 'canonical-repair')
            if ($previousKind -cne $kind -or
                [string](Get-StateValue $previous 'scenarioFeature' '') -cne $scenarioFeature -or
                [string](Get-StateValue $previous 'scenarioTags' '') -cne $scenarioTags) {
                throw "ITL_VERIFICATION_REPAIR_SCOPE_CHANGED: active session $($previous.sessionId) owns kind=$previousKind and its original scenario scope. Resume that exact session or report its blocker; do not reset the budget."
            }
            if ([string]$previous.status -eq 'workflow-blocked') {
                # Workflow refusals never consumed the product budget, so the
                # same session resumes with its attempts. The last blocked code
                # is retained: an unchanged refusal stops again after one run.
                $previous.status = 'active'
                $previous.updatedAt = (Get-Date).ToString('o')
                Write-ItlVerificationRepairRecord -Record $previous
            }
            $assessment = ''
            $basisPath = [string](Get-Variable -Name VerificationRepairBasisPath -ValueOnly -ErrorAction SilentlyContinue)
            if ($null -eq $maximumAttempts -and [int]$previous.attempts -ge 5 -and $basisPath) {
                $basis = Get-ItlVerificationRepairBasis -Runs @(Get-ItlVerificationRepairRuns -Record $previous) -Path $basisPath
                $assessment = if ($basis.status -eq 'linked') { 'basis linked; assess the reason before running' }
                    else { "WARN $($basis.status), diagnose before repeating" }
            }
            Write-ItlVerificationRepairStatus -Record $previous -Maximum $maximumAttempts -Label 'Repair session resumed' -Admission $assessment
            return
        }
        if ([string]$previous.status -eq "exhausted") {
            # ConvertFrom-Json returns UTC DateTime for a trailing Z, whereas
            # casting the state string to DateTime yields local time. Compare
            # absolute instants so a stale recovery cannot reset the budget.
            $exhaustedAt = [datetimeoffset]$previous.updatedAt
            $mutationAt = [datetimeoffset](Get-StateValue $state "toolingRecoveredMutationAt" "0001-01-01T00:00:00Z")
            $recoveredAt = [datetimeoffset](Get-StateValue $state "toolingRecoveredAt" "0001-01-01T00:00:00Z")
            if (-not $recoveryId -or $recoveryId -ceq [string](Get-StateValue $previous "toolingRecoveryId" "") -or
                $mutationAt -le $exhaustedAt -or $recoveredAt -le $exhaustedAt) {
                Set-RunFailureContext -Category "runner" -RequiredAction "report-blocker"
                throw "ITL_VERIFICATION_REPAIR_EXHAUSTED: repair the diagnosed tooling prerequisite through repair-dev-branch-tooling before starting a new bounded session."
            }
        }
        if ([string]$previous.status -eq 'exhausted' -or
            ([string]$previous.status -eq 'passed' -and $previous.PSObject.Properties['runs'])) {
            $archive = Join-Path (Split-Path -Parent $path) ("history/" + [string]$previous.sessionId + ".json")
            New-Item -ItemType Directory -Path (Split-Path -Parent $archive) -Force | Out-Null
            Copy-Item -LiteralPath $path -Destination $archive -ErrorAction Stop
        }
    }
    $maximumAttempts = if ($VerificationRepairMaxAttempts -gt 0) {
        $VerificationRepairMaxAttempts
    } elseif ($kind -eq 'scenario-loop') {
        3
    } else {
        Get-ItlVerificationRepairMaximumAttempts
    }
    $record = [pscustomobject][ordered]@{
        schemaVersion = $(if ($null -eq $maximumAttempts) { 2 } else { 1 })
        sessionId = [guid]::NewGuid().ToString("N")
        kind = $kind
        scenarioFeature = $scenarioFeature
        scenarioTags = $scenarioTags
        projectRoot = $script:ProjectRoot
        branch = Get-CurrentBranch
        attempts = 0
        toolingRecoveryId = $recoveryId
        maximumAttempts = $maximumAttempts
        status = "active"
        startedAt = (Get-Date).ToString("o")
        updatedAt = (Get-Date).ToString("o")
    }
    $path = Get-ItlVerificationRepairStatePath
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
    Write-ItlVerificationRepairRecord -Record $record
    Write-ItlVerificationRepairStatus -Record $record -Maximum $maximumAttempts -Label 'Repair session'
}

function Extend-ItlVerificationRepairSession {
    $source = ([string]$VerificationRepairGrantSource).Trim()
    if (-not $source -or $source.Length -gt 1024) {
        throw 'ITL_VERIFICATION_REPAIR_EXTENSION_GRANT_REQUIRED: provide the source reference of an explicit user grant for this session; preserve the session and resume this operation after obtaining that grant.'
    }
    if (-not $RepairSessionId -or $VerificationRepairMaxAttempts -lt 1 -or $VerificationRepairMaxAttempts -gt 100) {
        throw 'ITL_VERIFICATION_REPAIR_EXTENSION_ARGUMENTS_INVALID: pass the existing RepairSessionId and an authorized maximum between 1 and 100; do not replace the session to bypass its limit.'
    }
    $state = Read-DevBranchState -Name $DevBranchName
    Assert-DevelopmentBranchWorktreeContext -State $state -Operation 'extend-verification-repair'
    $path = Get-ItlVerificationRepairStatePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw 'ITL_VERIFICATION_REPAIR_EXTENSION_STATE_MISSING: restore the original session through its owner; extension does not create a new session.'
    }
    $record = Read-Utf8Text -Path $path | ConvertFrom-Json
    $recordRoot = [string](Get-StateValue $record 'projectRoot' '')
    if ([string](Get-StateValue $record 'sessionId' '') -cne $RepairSessionId -or
        [string](Get-StateValue $record 'branch' '') -cne (Get-CurrentBranch) -or
        -not $recordRoot -or
        -not [string]::Equals((Get-FullPathNormalized $recordRoot), (Get-FullPathNormalized $script:ProjectRoot), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'ITL_VERIFICATION_REPAIR_EXTENSION_SCOPE_MISMATCH: run the explicit extension in the original session branch/worktree with its exact RepairSessionId; the record was retained.'
    }
    $kind = [string](Get-StateValue $record 'kind' 'canonical-repair')
    if (($VerificationRepairKind -and $VerificationRepairKind -cne $kind) -or
        ($VanessaFeaturePath -and (Resolve-ProjectPath $VanessaFeaturePath) -cne [string](Get-StateValue $record 'scenarioFeature' '')) -or
        ($VanessaFilterTags -and $VanessaFilterTags.Trim() -cne [string](Get-StateValue $record 'scenarioTags' ''))) {
        throw 'ITL_VERIFICATION_REPAIR_EXTENSION_SCOPE_CHANGED: preserve the original kind/feature/tags; extension changes only the existing session limit.'
    }
    $status = [string](Get-StateValue $record 'status' '')
    if ($status -notin @('active', 'exhausted')) {
        throw "ITL_VERIFICATION_REPAIR_EXTENSION_TERMINAL: session '$RepairSessionId' has status '$status'; resume the original task, do not revive a completed session."
    }
    $maximum = Get-ItlVerificationRepairRecordMaximumAttempts -Record $record
    if ($null -eq $maximum) {
        throw 'ITL_VERIFICATION_REPAIR_EXTENSION_NOT_NEEDED: this session has no overall limit; continue the original command with its existing ID.'
    }
    [int]$attempts = 0
    if (-not [int]::TryParse([string](Get-StateValue $record 'attempts' ''), [ref]$attempts) -or
        $attempts -lt 0 -or $attempts -gt $maximum -or ($status -eq 'exhausted' -and $attempts -lt $maximum)) {
        throw 'ITL_VERIFICATION_REPAIR_EXTENSION_STATE_INVALID: attempts/status contradict the existing limit; retain the record and diagnose it through the repair-session owner.'
    }
    if ($VerificationRepairMaxAttempts -lt $maximum) {
        throw "ITL_VERIFICATION_REPAIR_EXTENSION_NOT_MONOTONIC: current maximum is $maximum; pass the authorized greater maximum without resetting attempts."
    }
    if ($VerificationRepairMaxAttempts -eq $maximum) {
        Set-RunUserReport -Report "Repair limit unchanged: $RepairSessionId; attempts=$attempts/$maximum; status=$status. An exhausted session still requires an authorized greater maximum."
        return
    }
    $historyProperty = $record.PSObject.Properties['limitExtensions']
    $history = @()
    if ($null -ne $historyProperty -and $null -ne $historyProperty.Value) {
        if ($historyProperty.Value -isnot [Array]) {
            throw 'ITL_VERIFICATION_REPAIR_EXTENSION_HISTORY_INVALID: retain the existing extension history and diagnose its format; do not discard or replace it.'
        }
        $history = @($historyProperty.Value)
    }
    $now = (Get-Date).ToString('o')
    $event = [pscustomobject]@{
        id = [guid]::NewGuid().ToString('N'); at = $now; source = $source
        previousMaximum = $maximum; maximum = $VerificationRepairMaxAttempts
        attempts = $attempts; previousStatus = $status
    }
    $record.maximumAttempts = $VerificationRepairMaxAttempts
    $record.status = 'active'
    $record.updatedAt = $now
    $record | Add-Member -NotePropertyName limitExtensions -NotePropertyValue (@($history) + @($event)) -Force
    Write-ItlVerificationRepairRecord -Record $record
    Set-RunUserReport -Report "Repair session extended: $RepairSessionId; attempts=$attempts/$VerificationRepairMaxAttempts; previous maximum=$maximum. Continue the original repair command with this RepairSessionId; prior failures and evidence were retained."
}

function Get-ItlMatchingVerificationRepairSession {
    if ([string]::IsNullOrWhiteSpace([string]$RepairSessionId)) {
        throw "VerificationTrigger=repair requires RepairSessionId from begin-verification-repair."
    }
    $path = Get-ItlVerificationRepairStatePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf -ErrorAction SilentlyContinue)) {
        throw "Verification repair session is missing. Run begin-verification-repair first and pass its RepairSessionId."
    }
    $record = Read-Utf8Text -Path $path | ConvertFrom-Json
    if ([string]$record.sessionId -ne $RepairSessionId) {
        throw "Repair session mismatch. Active: $($record.sessionId); requested: $RepairSessionId."
    }
    if ([string]$record.branch -ne (Get-CurrentBranch) -or (Get-FullPathNormalized ([string]$record.projectRoot)) -ne (Get-FullPathNormalized $script:ProjectRoot)) {
        throw "Repair session belongs to another branch or worktree. Begin a new /itl-verify-fix invocation."
    }
    if ([string]$record.status -ne "active") {
        if ([string]$record.status -eq "passed") {
            Set-RunFailureContext -Category "runner" -RequiredAction "stop-repair-and-resume-original-task"
            throw "Repair session $($record.sessionId) already passed. Do not start another repair run; resume the original task and use an ordinary check for later verification."
        }
        if ([string]$record.status -eq "workflow-blocked") {
            Set-RunFailureContext -Category "runner" -RequiredAction "report-workflow-incident"
            throw "ITL_VERIFICATION_REPAIR_WORKFLOW_BLOCKED: repair session $($record.sessionId) stopped after workflow refusal $(Get-StateValue $record 'lastWorkflowBlockedCode' '') repeated consecutively; product attempts $(Format-ItlVerificationRepairAttempts -Record $record -Maximum $record.maximumAttempts) were preserved. Follow references/workflow-incidents.md, then resume this session with begin-verification-repair."
        }
        Set-RunFailureContext -Category "runner" -RequiredAction "report-blocker"
        throw "Repair session $($record.sessionId) is terminal (status=$($record.status)). Return its blocker diagnostics; another full run is forbidden."
    }
    return $record
}

function Assert-ItlVerificationRepairScope {
    param([ValidateSet("implicit", "command", "repair", "explicit")][string]$Trigger)

    if ($Trigger -ne "repair" -or -not (Test-ItlDiagnosticVerificationScope)) { return }
    if (Test-ItlYAxUnitDiagnosticScope) {
        Set-RunFailureContext -Category "runner" -RequiredAction "repeat-original-diagnostic-without-repair-session"
        throw "VerificationTrigger=repair cannot be combined with YAxUnitModule. A filtered YAxUnit run is diagnostic only; repeat it without a repair session."
    }
    if (-not $RepairSessionId -and -not $VerificationRepairKind) {
        Set-RunFailureContext -Category "runner" -RequiredAction "repeat-original-diagnostic-without-repair-session"
        throw "VerificationTrigger=repair cannot be combined with VanessaFeaturePath or VanessaFilterTags for canonical-repair. A filtered run is diagnostic only; use an explicitly scoped scenario-loop session."
    }
    $record = Get-ItlMatchingVerificationRepairSession
    if ([string](Get-StateValue $record 'kind' 'canonical-repair') -eq 'scenario-loop') {
        $feature = if ($VanessaFeaturePath) { Resolve-ProjectPath $VanessaFeaturePath } else { '' }
        $tags = ([string]$VanessaFilterTags).Trim()
        if ($feature -ceq [string](Get-StateValue $record 'scenarioFeature' '') -and
            $tags -ceq [string](Get-StateValue $record 'scenarioTags' '')) { return }
        Set-RunFailureContext -Category 'runner' -RequiredAction 'repeat-original-scenario-scope'
        throw "ITL_VERIFICATION_REPAIR_SCOPE_CHANGED: scenario-loop $($record.sessionId) permits only its recorded feature and tag filter."
    }
    Set-RunFailureContext -Category "runner" -RequiredAction "repeat-original-diagnostic-without-repair-session"
    throw "VerificationTrigger=repair cannot be combined with VanessaFeaturePath or VanessaFilterTags for canonical-repair. A filtered run is diagnostic only; use an explicitly scoped scenario-loop session."
}

function Test-ItlFullVerificationProofEligible {
    param(
        [ValidateSet("implicit", "command", "repair", "explicit")][string]$Trigger,
        [string[]]$ExplicitComponents = @()
    )

    if (Test-ItlDiagnosticVerificationScope) { return $false }
    $decisions = @(
        Get-ItlVerificationExecutionDecision -Component "yaxunit" -Trigger $Trigger -ExplicitComponents $ExplicitComponents
        Get-ItlVerificationExecutionDecision -Component "vanessa" -Trigger $Trigger -ExplicitComponents $ExplicitComponents
        Get-ItlVerificationExecutionDecision -Component "event-log" -Trigger $Trigger -ExplicitComponents $ExplicitComponents
    )
    return @($decisions | Where-Object { -not $_.run }).Count -eq 0
}

function Use-ItlVerificationRepairAttempt {
    param([string]$InputFingerprint = '')

    if ($VerificationTrigger -ne "repair") { return }
    $record = Get-ItlMatchingVerificationRepairSession
    $maximumAttempts = Get-ItlVerificationRepairRecordMaximumAttempts -Record $record
    if ($null -ne $maximumAttempts -and [int]$record.attempts -ge $maximumAttempts) {
        $record.status = "exhausted"
        $record.updatedAt = (Get-Date).ToString("o")
        Write-ItlVerificationRepairRecord -Record $record
        Set-RunFailureContext -Category "runner" -RequiredAction "report-blocker"
        throw "Repair session $($record.sessionId) exhausted its $maximumAttempts full verification runs. Return blocker diagnostics; another full run is forbidden."
    }
    # A workflow-blocked outcome refunds this attempt; the ticket lets the
    # failure owner restore the pre-attempt scenario-loop input identity.
    $identityProperty = $record.PSObject.Properties['lastAttemptInputIdentity']
    $ticket = [pscustomobject]@{
        sessionId = [string]$record.sessionId
        hadInputIdentity = $null -ne $identityProperty
        inputIdentity = $(if ($null -ne $identityProperty) { [string]$identityProperty.Value } else { '' })
    }
    if ([string](Get-StateValue $record 'kind' 'canonical-repair') -eq 'scenario-loop') {
        $state = Read-DevBranchState -Name $DevBranchName
        $featurePath = [string](Get-StateValue $record 'scenarioFeature' '')
        $featureIdentity = ''
        if ($featurePath) {
            [void](Get-VerificationRepoRelativePath -Path $featurePath)
            if (-not (Test-Path -LiteralPath $featurePath -PathType Leaf)) {
                throw "ITL_VERIFICATION_SCENARIO_FEATURE_MISSING: '$featurePath' was removed from the active scenario-loop scope. Restore the named feature before consuming another attempt."
            }
            $featureIdentity = (Get-FileHash -LiteralPath $featurePath -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        $modeIdentity = @(@('yaxunit', 'vanessa', 'event-log') | ForEach-Object {
            $decision = Get-ItlVerificationExecutionDecision -Component $_ -Trigger command
            "$($_)=$($decision.mode):$($decision.valid);$($decision.providerKey)=$($decision.providerPolicy):$($decision.providerValid)"
        }) -join ','
        $inputIdentity = (Get-VerificationFingerprint) + '|toolingRecoveryId=' +
            [string](Get-StateValue $state 'toolingRecoveryId' '') + '|modes=' + $modeIdentity +
            '|named=' + ([string]$ExplicitVerificationComponent).Trim().ToLowerInvariant() + '|feature=' + $featureIdentity
        if ([int]$record.attempts -gt 0 -and
            [string](Get-StateValue $record 'lastAttemptInputIdentity' '') -ceq $inputIdentity) {
            Set-RunFailureContext -Category 'runner' -RequiredAction 'diagnose-and-change-before-retry'
            throw "ITL_VERIFICATION_REPAIR_NO_CHANGE: scenario-loop $($record.sessionId) already checked this source and tooling state. Diagnose the failure and change the relevant input before another round."
        }
        if ($record.PSObject.Properties['lastAttemptInputIdentity']) {
            $record.lastAttemptInputIdentity = $inputIdentity
        } else {
            $record | Add-Member -NotePropertyName lastAttemptInputIdentity -NotePropertyValue $inputIdentity
        }
    }
    $record.attempts = [int]$record.attempts + 1
    $record.updatedAt = (Get-Date).ToString("o")
    if ((Get-StateValue $record 'kind' 'canonical-repair') -eq 'canonical-repair') {
        $run = New-ItlVerificationRepairRun -Record $record -Outcome 'admitted'
        $run.inputFingerprint = $InputFingerprint
        $ticket | Add-Member -NotePropertyName runId -NotePropertyValue $run.id
        if ($null -eq $maximumAttempts -and [int]$record.attempts -gt 5) {
            $basisPath = [string](Get-Variable -Name VerificationRepairBasisPath -ValueOnly -ErrorAction SilentlyContinue)
            $run.basis = Get-ItlVerificationRepairBasis -Runs @(Get-ItlVerificationRepairRuns -Record $record) -Path $basisPath
            if ($run.basis.status -ne 'linked') {
                Write-Warning "ITL_VERIFICATION_REPAIR_BASIS: $($run.basis.status). Diagnose the last result and record a current reason before repeating. See references/verification-result.md." -WarningAction Continue
            }
        }
        Add-ItlVerificationRepairRun -Record $record -Run $run
    }
    Write-ItlVerificationRepairRecord -Record $record
    Write-Host "Repair session: $($record.sessionId)"
    Write-Host "Repair attempt: $(Format-ItlVerificationRepairAttempts -Record $record -Maximum $maximumAttempts)"
    return $ticket
}

function Get-ItlVerificationRepairWorkflowBlockCode {
    param(
        [AllowEmptyString()][string]$Message,
        [AllowEmptyString()][string]$Category = ''
    )

    # Only a workflow/runner refusal before a product verdict is refunded. A
    # product, fixture, suite, update or event-log owner always counts.
    if ($Category -and $Category -notin @('runner', 'session-capacity', 'execution-conflict')) { return '' }
    if ([string]$Message -cmatch '(?<![A-Z0-9_])((?:ITL_TESTCLIENT|EXECUTION_GUARD|ITL_ONDEMAND)_[A-Z0-9_]+|ITL_ONEC_SESSION_LIMIT|ITL_VANESSA_LICENSE_LIMIT)(?![A-Z0-9_])') {
        return [string]$Matches[1]
    }
    return ''
}

function Set-ItlVerificationRepairRecordValue {
    param([object]$Record, [string]$Name, [AllowNull()][object]$Value)

    if ($Record.PSObject.Properties[$Name]) { $Record.$Name = $Value }
    else { $Record | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
}

function Complete-ItlVerificationRepairSession {
    param([AllowNull()][object]$AttemptTicket, [AllowNull()][object]$Result)

    if ($VerificationTrigger -ne "repair") { return }
    $record = Get-ItlMatchingVerificationRepairSession
    $record.status = "passed"
    $record.updatedAt = (Get-Date).ToString("o")
    Set-ItlVerificationRepairRunOutcome -Record $record -Ticket $AttemptTicket -Outcome 'completed' -Result $Result
    Write-ItlVerificationRepairRecord -Record $record
}

function Complete-ItlVerificationRepairFailure {
    param(
        [AllowNull()][object]$Failure = $null,
        [AllowNull()][object]$AttemptTicket = $null,
        [AllowNull()][object]$Result = $null
    )

    if ($VerificationTrigger -ne "repair") { return }
    $record = Get-ItlMatchingVerificationRepairSession
    $maximumAttempts = Get-ItlVerificationRepairRecordMaximumAttempts -Record $record
    $message = if ($Failure -is [System.Management.Automation.ErrorRecord]) { [string]$Failure.Exception.Message }
        elseif ($Failure -is [Exception]) { [string]$Failure.Message } elseif ($null -ne $Failure) { [string]$Failure } else { '' }
    $category = [string](Get-Variable -Name RunErrorCategory -Scope Script -ValueOnly -ErrorAction SilentlyContinue)
    $blockCode = if ($message) { Get-ItlVerificationRepairWorkflowBlockCode -Message $message -Category $category } else { '' }
    $previousBlockCode = [string](Get-StateValue $record 'lastWorkflowBlockedCode' '')
    $AttemptTicket = @(@($AttemptTicket) | Where-Object { $null -ne $_ -and $null -ne $_.PSObject.Properties['sessionId'] }) | Select-Object -Last 1
    $outcome = if ($blockCode) { 'workflow-refunded' } else { 'failed' }
    $changed = Set-ItlVerificationRepairRunOutcome -Record $record -Ticket $AttemptTicket -Outcome $outcome -Result $Result -PassThru

    if ($blockCode) {
        # The refusal happened before a product verdict: refund the attempt
        # instead of spending the user's product repair budget on workflow.
        $record.attempts = [Math]::Max(0, [int]$record.attempts - 1)
        if ($null -ne $AttemptTicket -and [string]$AttemptTicket.sessionId -ceq [string]$record.sessionId) {
            if ([bool]$AttemptTicket.hadInputIdentity) {
                Set-ItlVerificationRepairRecordValue -Record $record -Name 'lastAttemptInputIdentity' -Value ([string]$AttemptTicket.inputIdentity)
            } elseif ($record.PSObject.Properties['lastAttemptInputIdentity']) {
                $record.PSObject.Properties.Remove('lastAttemptInputIdentity')
            }
        }
        $now = (Get-Date).ToString('o')
        $history = @(@(Get-StateValue $record 'workflowBlocked' @()) + @([pscustomobject][ordered]@{ code = $blockCode; at = $now; category = $category }))
        if ($history.Count -gt 20) { $history = @($history | Select-Object -Last 20) }
        Set-ItlVerificationRepairRecordValue -Record $record -Name 'workflowBlocked' -Value $history
        Set-ItlVerificationRepairRecordValue -Record $record -Name 'workflowBlockedCount' -Value ([int](Get-StateValue $record 'workflowBlockedCount' 0) + 1)
        Set-ItlVerificationRepairRecordValue -Record $record -Name 'lastWorkflowBlockedCode' -Value $blockCode
        $repeated = $previousBlockCode -ceq $blockCode
        if ($repeated) { $record.status = 'workflow-blocked' }
        $record.updatedAt = $now
        Write-ItlVerificationRepairRecord -Record $record
        $attemptText = Format-ItlVerificationRepairAttempts -Record $record -Maximum $maximumAttempts
        if ($repeated) {
            Set-RunFailureContext -Category 'runner' -RequiredAction 'report-workflow-incident'
            Write-Host "Repair session $($record.sessionId) stopped: workflowBlocked code $blockCode repeated consecutively. Product attempts: $attemptText. Follow references/workflow-incidents.md."
        } else {
            Write-Host "Repair attempt not counted: workflowBlocked code=$blockCode. Product attempts: $attemptText. A consecutive repeat of the same code stops the session."
        }
        return
    }

    if ($previousBlockCode) {
        # A counted product attempt ends the consecutive workflow-block run.
        $record.lastWorkflowBlockedCode = ''
        $changed = $true
    }
    $exhausted = $null -ne $maximumAttempts -and [int]$record.attempts -ge $maximumAttempts
    if ($exhausted) {
        $record.status = "exhausted"
        $changed = $true
    }
    if ($changed) {
        $record.updatedAt = (Get-Date).ToString("o")
        Write-ItlVerificationRepairRecord -Record $record
    }
    if ($exhausted) { Set-RunFailureContext -RequiredAction "report-blocker" }
}

function Get-ItlVerificationRepairRunResult {
    param([string]$Phase, [object]$State, [AllowNull()][object]$Verification, [AllowNull()][object]$Failure, [datetime]$StartedAt)

    $yaxunit = $null
    $eventLog = $null
    $observedAt = [datetimeoffset]::MinValue
    $timestamp = [string](Get-StateValue $State 'lastYAxUnitTestAt' '')
    if ([datetimeoffset]::TryParse($timestamp, [ref]$observedAt) -and $observedAt -ge $StartedAt) {
        $yaxunit = [pscustomobject]@{
            status = Get-StateValue $State 'lastYAxUnitStatus' 'unknown'
            coverage = Get-StateValue $State 'lastYAxUnitCoverage' $null
            junitPath = Get-StateValue $State 'lastYAxUnitReportPath' ''
            logPath = Get-StateValue $State 'lastYAxUnitLogPath' ''
        }
    }
    $timestamp = [string](Get-StateValue $State 'lastEventLogOnlyCheckedAt' '')
    if ([datetimeoffset]::TryParse($timestamp, [ref]$observedAt) -and $observedAt -ge $StartedAt) {
        $eventLog = [pscustomobject]@{
            status = Get-StateValue $State 'lastEventLogOnlyStatus' 'unknown'
            reportPath = Get-StateValue $State 'lastEventLogOnlyReportPath' ''
        }
    } else {
        $timestamp = [string](Get-StateValue $State 'lastVanessaEventLogCheckedUntil' '')
        $path = [string](Get-StateValue $State 'lastVanessaEventLogNewErrorsPath' '')
        if ($path -and [datetimeoffset]::TryParse($timestamp, [ref]$observedAt) -and $observedAt -ge $StartedAt) {
            $status = if ((Get-StateValue $State 'lastVanessaEventLogScanMode' '') -in @('', 'failed', 'skipped')) { 'unknown' }
                elseif ((Get-StateValue $State 'lastVanessaEventLogNewErrorCount' 0) -gt 0) { 'failed' } else { 'observed' }
            $eventLog = [pscustomobject]@{ status = $status; reportPath = $path }
        }
    }
    $vanessa = $null
    $timestamp = [string](Get-StateValue $State 'lastVanessaStartedAt' '')
    if ([datetimeoffset]::TryParse($timestamp, [ref]$observedAt) -and $observedAt -ge $StartedAt) {
        $vanessa = [pscustomobject]@{
            reportPath = Get-StateValue $State 'lastVanessaReportPath' ''
            logPath = Get-StateValue $State 'lastVanessaLogPath' ''
            statusPath = Get-StateValue $State 'lastVanessaStatusPath' ''
        }
    }
    $stage = [string](Get-Variable RunStage -Scope Script -ValueOnly -ErrorAction SilentlyContinue)
    $nativeLog = [string](Get-Variable LastLogPath -Scope Script -ValueOnly -ErrorAction SilentlyContinue)
    return [pscustomobject]@{
        phase = $Phase
        stage = $stage
        category = [string](Get-Variable RunErrorCategory -Scope Script -ValueOnly -ErrorAction SilentlyContinue)
        reason = $(if ($null -ne $Failure) { ([string]$Failure.Exception.Message -split '
?
', 2)[0] | ForEach-Object { $_.Substring(0, [Math]::Min($_.Length, 512)) } } else { '' })
        verification = Get-StateValue $Verification 'effectiveStatus' 'unknown'
        freshPassed = [bool](Get-StateValue $Verification 'isFreshPassed' $false)
        taskAccepted = [bool](Get-StateValue $Verification 'isFreshPassed' $false) -and [bool](Get-StateValue $Verification 'taskAccepted' $true)
        acceptanceRemaining = @(if ($null -ne $Verification -and $Verification.PSObject.Properties['acceptanceRemaining']) { $Verification.acceptanceRemaining })
        yaxunit = $yaxunit
        eventLog = $eventLog
        vanessa = $vanessa
        evidence = @(@((Get-StateValue $yaxunit 'junitPath' ''), (Get-StateValue $yaxunit 'logPath' ''),
            (Get-StateValue $eventLog 'reportPath' ''), (Get-StateValue $vanessa 'statusPath' ''), (Get-StateValue $vanessa 'logPath' ''), $nativeLog) |
            Where-Object { $_ } | Select-Object -Unique | ForEach-Object {
                $item = Get-Item -LiteralPath $_ -ErrorAction SilentlyContinue
                if ($null -ne $item -and -not $item.PSIsContainer) {
                    [pscustomobject]@{ path = $item.FullName; length = $item.Length; modifiedTicks = $item.LastWriteTimeUtc.Ticks }
                }
            })
    }
}

function Publish-ItlVerificationRepairRun {
    param(
        [AllowNull()][object]$Ticket, [AllowNull()][object]$Result,
        [AllowNull()][object]$Failure, [bool]$SessionPassed, [datetime]$StartedAt
    )

    $record = if ($null -eq $Failure -or $null -ne $Ticket) { Get-ItlMatchingVerificationRepairSession } else {
        $path = Get-ItlVerificationRepairStatePath
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
        $saved = Read-Utf8Text -Path $path | ConvertFrom-Json
        if ($saved.sessionId -cne $RepairSessionId -or $saved.branch -cne (Get-CurrentBranch) -or
            (Get-FullPathNormalized ([string]$saved.projectRoot)) -ine (Get-FullPathNormalized $script:ProjectRoot) -or (Get-StateValue $saved 'kind' 'canonical-repair') -ne 'canonical-repair') { return }
        $saved
    }
    if ((Get-StateValue $record 'kind' 'canonical-repair') -ne 'canonical-repair') { return }
    $maximum = Get-ItlVerificationRepairRecordMaximumAttempts -Record $record
    if ($null -ne $Failure -and $null -ne $Ticket) {
        Complete-ItlVerificationRepairFailure -Failure $Failure -AttemptTicket $Ticket -Result $Result
        $record = Read-Utf8Text -Path (Get-ItlVerificationRepairStatePath) | ConvertFrom-Json
    } elseif ($SessionPassed) {
        Complete-ItlVerificationRepairSession -AttemptTicket $Ticket -Result $Result
        $record.status = 'passed'
    } elseif ($null -ne $Ticket) {
        Set-ItlVerificationRepairRunOutcome -Record $record -Ticket $Ticket -Outcome 'completed' -Result $Result
        Write-ItlVerificationRepairRecord -Record $record
    } else {
        $run = New-ItlVerificationRepairRun -Record $record -Outcome 'admitted'
        $run.attempt = $null
        $run.startedAt = $StartedAt.ToString('o')
        Add-ItlVerificationRepairRun -Record $record -Run $run
        $outcome = if ($null -eq $Failure) { 'partial-unaccounted' }
            elseif ($record.status -eq 'exhausted') { 'limit-refused' }
            elseif ($record.status -eq 'active') { 'preflight-refused' } else { 'session-refused' }
        Set-ItlVerificationRepairRunOutcome -Record $record -Ticket ([pscustomobject]@{runId=$run.id}) -Outcome $outcome -Result $Result
        Write-ItlVerificationRepairRecord -Record $record
    }
    $runs = @(Get-ItlVerificationRepairRuns -Record $record)
    $admission = if ($null -eq $Ticket) { "$($runs[-1].outcome), no attempt charged" }
        elseif ($runs.Count -gt 0 -and $runs[-1].outcome -eq 'workflow-refunded') { 'workflow refusal, attempt returned' }
        elseif ($runs.Count -gt 0 -and $null -ne $runs[-1].basis -and $runs[-1].basis.status -ne 'linked') { "WARN $($runs[-1].basis.status), diagnose before repeating" }
        else { 'admitted' }
    Write-ItlVerificationRepairStatus -Record $record -Maximum $maximum -Label 'Repair session' -Admission $admission
}

function Get-ItlVanessaVerificationSelectionPlan {
    param([switch]$YAxUnitVerificationPlanned)

    if ($script:ActiveAuxiliaryVanessaContext -or (Test-ItlDiagnosticVerificationScope)) { return $null }
    $featuresPath = Get-VanessaFeaturesPath
    $applicationFeatureFiles = @(Get-VanessaApplicationFeatureFiles -FeaturePath $featuresPath)
    $oneOffObligations = @(Get-VerificationOneOffObligations)
    $currentChange = if ((Get-VerificationModel) -eq 'change') { Read-VerificationChange } else { $null }
    if ($applicationFeatureFiles.Count -eq 0 -and $oneOffObligations.Count -eq 0 -and ($null -eq $currentChange -or @($currentChange.checks).Count -eq 0)) { return $null }
    $plan = New-VerificationSelectionPlan -ApplicationFeatureFiles $applicationFeatureFiles -YAxUnitVerificationPlanned:$YAxUnitVerificationPlanned -RequireObservedReceipts
    if ($plan.mode -eq 'classification-required') {
        Set-RunFailureContext -Category 'missing-suite' -RequiredAction 'classify-tests-and-repeat-original-itl-command'
        throw "ITL_TEST_CLASSIFICATION_REQUIRED: $($plan.reason) Inventory: $(Get-VerificationClassificationInventoryPath)"
    }
    return $plan
}

function Invoke-ItlVerificationCycle {
    param(
        [ValidateSet("implicit", "command", "repair", "explicit")][string]$Trigger = "command",
        [string[]]$ExplicitComponents = @(),
        [switch]$ScenarioDiagnosticOnly,
        [string]$EventLogCursorPath = "",
        [Nullable[datetime]]$EventLogBoundaryAt = $null,
        [string]$EventLogCursorScope = "vanessa-only"
    )

    $state = Read-DevBranchState -Name $DevBranchName
    $yaxunit = Get-ItlVerificationExecutionDecision -Component "yaxunit" -Trigger $Trigger -ExplicitComponents $ExplicitComponents
    $vanessa = Get-ItlVerificationExecutionDecision -Component "vanessa" -Trigger $Trigger -ExplicitComponents $ExplicitComponents
    $eventLog = Get-ItlVerificationExecutionDecision -Component "event-log" -Trigger $Trigger -ExplicitComponents $ExplicitComponents
    if ($ScenarioDiagnosticOnly) {
        if (-not (Test-ItlDiagnosticVerificationScope) -or -not $vanessa.run) {
            throw 'ITL_VERIFICATION_SCENARIO_DIAGNOSTIC_INVALID: a named Vanessa scenario and permitted runner are required before the unfiltered phase.'
        }
        foreach ($deferred in @($yaxunit, $eventLog)) {
            $deferred.run = $false
            $deferred.reason = 'deferred to the unfiltered phase of the same scenario-loop attempt'
        }
    }
    $decisions = @($yaxunit, $vanessa, $eventLog)
    foreach ($decision in $decisions) { Write-Host "Verification component $($decision.component): $(if ($decision.run) { 'RUN' } else { 'SKIP' }) ($($decision.reason))" }

    $recordFullProof = Test-ItlFullVerificationProofEligible -Trigger $Trigger -ExplicitComponents $ExplicitComponents
    $selectionPlan = $null
    if (-not $script:ActiveAuxiliaryVanessaContext -and ($vanessa.run -or $yaxunit.run)) {
        Assert-VerificationClassificationReady -Reason "check-dev-branch preflight" -RequireVanessa:$vanessa.run -RequireYAxUnit:$yaxunit.run | Out-Null
        $state = Read-DevBranchState -Name $DevBranchName
    }
    if ($vanessa.run) {
        $selectionPlan = Get-ItlVanessaVerificationSelectionPlan -YAxUnitVerificationPlanned:$yaxunit.run
    }

    if ($yaxunit.run) {
        Invoke-YAxUnitVerification -State $state | Out-Null
        $state = Read-DevBranchState -Name $DevBranchName
    }

    if ($vanessa.run) {
        $script:ItlSkipEventLogForVerification = -not $eventLog.run
        if ($null -ne $selectionPlan -and $selectionPlan.mode -eq "reuse") {
            Assert-DevelopmentBranchWorktreeContext -State $state -Operation "check-dev-branch"
            Assert-DevBranchExtensionInitialized -State $state -Operation "check-dev-branch"
            $state = Assert-DevBranchApplicationReady -State $state -Operation "verification proof reuse"
            try {
                if ($eventLog.run) {
                    Test-ItlEventLogCurrent -State $state -CursorPath $EventLogCursorPath -BoundaryAt $EventLogBoundaryAt -CursorScope $EventLogCursorScope -Trigger $Trigger
                }
                $state = Read-DevBranchState -Name $DevBranchName
                $updates = @{
                    lastVerificationSelectionMode = "reuse"
                    lastVerificationSelectedSuites = @()
                    lastVerificationSelectionReason = [string]$selectionPlan.reason
                }
                Add-VanessaVerificationEvidenceUpdates `
                    -Updates $updates `
                    -State $state `
                    -Status "passed" `
                    -Reason "$($selectionPlan.reason) Event-log verification passed." `
                    -Commit (Get-CurrentCommit) `
                    -Fingerprint (Get-VerificationFingerprint) `
                    -ReportPath ([string](Get-StateValue -State $state -Name "lastVerifiedReportPath" -Default "")) `
                    -LogPath ([string](Get-StateValue -State $state -Name "lastVerificationLogPath" -Default "")) `
                    -RecordFullVerificationEvidence:$recordFullProof
                Complete-VerificationSelectionProof -Plan $selectionPlan
                Update-DevBranchState -State $state -Updates $updates
                Write-Host "Vanessa verification selection: $($selectionPlan.reason) Vanessa was not started."
            } finally {
                $script:ItlSkipEventLogForVerification = $false
            }
        } else {
            $script:ActiveVerificationSelectionPlan = $selectionPlan
            try {
                Run-DevBranchTests `
                    -RecordFullVerificationEvidence:$recordFullProof `
                    -EventLogCursorPath $EventLogCursorPath `
                    -EventLogBoundaryAt $EventLogBoundaryAt `
                    -EventLogCursorScope $EventLogCursorScope
            } finally {
                $script:ItlSkipEventLogForVerification = $false
                $script:ActiveVerificationSelectionPlan = $null
            }
        }
    } elseif ($eventLog.run) {
        Test-ItlEventLogCurrent -State $state -CursorPath $EventLogCursorPath -BoundaryAt $EventLogBoundaryAt -CursorScope $EventLogCursorScope -Trigger $Trigger
    }
    $state = Read-DevBranchState -Name $DevBranchName
    if (Test-ItlDiagnosticVerificationScope) {
        return
    }
    $skipped = @($decisions | Where-Object { -not $_.run })
    $verification = Get-VerificationState -State $state
    if ($verification.isFreshPassed) {
        Update-DevBranchState -State $state -Updates @{
            lastVerificationEvidenceKind = $(if ([string](Get-StateValue -State $verification -Name 'assessmentKind' -Default '') -eq 'current-obligations') { 'complete/current-obligations' } elseif ((Get-VerificationModel) -eq 'change') { 'complete/current-change' } else { 'full' })
            lastVerificationTrigger = $Trigger
            lastVerificationSkippedComponents = @($skipped | ForEach-Object component)
        }
        Write-Host 'Canonical verification passed: current observed obligations and exact loaded target are complete; skipped runners were not started.'
    } elseif ((Get-VerificationModel) -eq 'change' -and [bool](Get-StateValue -State $verification -Name 'changeFreshPassed' -Default $false)) {
        Update-DevBranchState -State $state -Updates @{
            lastVerificationEvidenceKind = 'change/task-pending'
            lastVerificationTrigger = $Trigger
            lastVerificationSkippedComponents = @($skipped | ForEach-Object component)
        }
        Write-Host "Current change checks passed; whole-task acceptance remains pending: $(@(Get-StateValue -State $verification -Name 'acceptanceRemaining' -Default @()) -join ', '). Complete the change record without repeating successful observations; keep the remaining criteria open."
    } elseif ($skipped.Count -gt 0) {
        Set-ItlPartialVerificationEvidence -State $state -Decisions $decisions -Trigger $Trigger
    } else {
        $assessmentIssues = @(Get-StateValue -State $verification -Name 'assessmentIssues' -Default @())
        if ($assessmentIssues.Count -gt 0) {
            Write-Host "[WARN] Current observed verification remains partial: $($assessmentIssues -join '; '). Preserve the reports and satisfy only the missing obligation through its existing owner."
        } elseif ($verification.status -eq "passed") {
            Update-DevBranchState -State $state -Updates @{
                lastVerificationEvidenceKind = "full"
                lastVerificationTrigger = $Trigger
                lastVerificationSkippedComponents = @()
            }
            $oneOffIssues = @(Get-StateValue -State $verification -Name 'oneOffIssues' -Default @())
            if ($oneOffIssues.Count -gt 0) {
                Write-Host "[WARN] Retained verification completed, but one-off proof is still pending: $($oneOffIssues -join '; '). Result readiness remains partial until the agent performs each named one-off check on this loaded infobase; it is the next step, not a final result."
            }
        }
    }
}
