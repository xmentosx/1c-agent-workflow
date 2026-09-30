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
    $run = if ($outsideNamedScope) {
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
    $rawValue = Get-EnvValue -Name "ITL_VERIFICATION_REPAIR_MAX_ATTEMPTS" -Default 5
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

    $maximumAttempts = 0
    if ($null -eq $Record.PSObject.Properties["maximumAttempts"] -or
        -not [int]::TryParse(([string]$Record.maximumAttempts), [ref]$maximumAttempts) -or
        $maximumAttempts -lt 1 -or
        $maximumAttempts -gt 100) {
        Set-RunFailureContext -Category "runner" -RequiredAction "report-blocker"
        throw "Repair session $($Record.sessionId) has invalid maximumAttempts. Return blocker diagnostics; another full run is forbidden."
    }
    return $maximumAttempts
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
        if ([string]$previous.status -eq 'active') {
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
            Write-Host "Repair session resumed: $($previous.sessionId)"
            Write-Host "Repair attempts: $($previous.attempts)/$maximumAttempts"
            Set-RunUserReport -Report "Repair session resumed: $($previous.sessionId). Repair attempts: $($previous.attempts)/$maximumAttempts."
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
        schemaVersion = 1
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
    Write-Utf8TextAtomic -Path $path -Value (($record | ConvertTo-Json -Depth 5) + [Environment]::NewLine)
    Write-Host "Repair session: $($record.sessionId)"
    Write-Host "Repair attempts: 0/$maximumAttempts"
    Set-RunUserReport -Report "Repair session: $($record.sessionId). Repair attempts: 0/$maximumAttempts."
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
        Set-RunFailureContext -Category "runner" -RequiredAction "report-blocker"
        throw "Repair session $($record.sessionId) is terminal (status=$($record.status)). Return its blocker diagnostics; another full run is forbidden."
    }
    return $record
}

function Assert-ItlVerificationRepairScope {
    param([ValidateSet("implicit", "command", "repair", "explicit")][string]$Trigger)

    if ($Trigger -ne "repair" -or -not (Test-ItlDiagnosticVerificationScope)) { return }
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
    if ($VerificationTrigger -ne "repair") { return }
    $record = Get-ItlMatchingVerificationRepairSession
    $path = Get-ItlVerificationRepairStatePath
    $maximumAttempts = Get-ItlVerificationRepairRecordMaximumAttempts -Record $record
    if ([int]$record.attempts -ge $maximumAttempts) {
        $record.status = "exhausted"
        $record.updatedAt = (Get-Date).ToString("o")
        Write-Utf8TextAtomic -Path $path -Value (($record | ConvertTo-Json -Depth 5) + [Environment]::NewLine)
        Set-RunFailureContext -Category "runner" -RequiredAction "report-blocker"
        throw "Repair session $($record.sessionId) exhausted its $maximumAttempts full verification runs. Return blocker diagnostics; another full run is forbidden."
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
    Write-Utf8TextAtomic -Path $path -Value (($record | ConvertTo-Json -Depth 5) + [Environment]::NewLine)
    Write-Host "Repair session: $($record.sessionId)"
    Write-Host "Repair attempt: $($record.attempts)/$maximumAttempts"
}

function Complete-ItlVerificationRepairSession {
    if ($VerificationTrigger -ne "repair") { return }
    $path = Get-ItlVerificationRepairStatePath
    $record = Get-ItlMatchingVerificationRepairSession
    $record.status = "passed"
    $record.updatedAt = (Get-Date).ToString("o")
    Write-Utf8TextAtomic -Path $path -Value (($record | ConvertTo-Json -Depth 5) + [Environment]::NewLine)
}

function Complete-ItlVerificationRepairFailure {
    if ($VerificationTrigger -ne "repair") { return }
    $path = Get-ItlVerificationRepairStatePath
    $record = Get-ItlMatchingVerificationRepairSession
    $maximumAttempts = Get-ItlVerificationRepairRecordMaximumAttempts -Record $record
    if ([int]$record.attempts -lt $maximumAttempts) { return }

    $record.status = "exhausted"
    $record.updatedAt = (Get-Date).ToString("o")
    Write-Utf8TextAtomic -Path $path -Value (($record | ConvertTo-Json -Depth 5) + [Environment]::NewLine)
    Set-RunFailureContext -RequiredAction "report-blocker"
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
    if (-not $script:ActiveAuxiliaryVanessaContext -and -not (Test-ItlDiagnosticVerificationScope)) {
        if ($vanessa.run) {
            $featuresPath = Get-VanessaFeaturesPath
            $applicationFeatureFiles = @(Get-VanessaApplicationFeatureFiles -FeaturePath $featuresPath)
            $oneOffObligations = @(Get-VerificationOneOffObligations)
            if ($applicationFeatureFiles.Count -gt 0 -or $oneOffObligations.Count -gt 0) {
                $vanessaCatalog = if ($applicationFeatureFiles.Count -eq 0) { Read-VerificationSuiteCatalog -ApplicationFeatureFiles @() } else { $null }
                if ($applicationFeatureFiles.Count -eq 0 -and -not $vanessaCatalog.available -and $oneOffObligations.Count -gt 0) {
                    $selectionPlan = [pscustomobject]@{
                        mode = 'reuse'; reason = 'No retained Vanessa acceptance suite exists; one-off proof is assessed separately.'
                        selectedFeatureFiles = @(); selectedSuiteIds = @(); acceptanceSuiteIds = @(); acceptanceSuites = @()
                        catalogFingerprint = ''; currentTree = Get-VerificationSelectionEffectiveTree; catalogAvailable = $false
                    }
                } else {
                    $selectionPlan = New-VerificationSelectionPlan -ApplicationFeatureFiles $applicationFeatureFiles -YAxUnitVerificationPlanned:$yaxunit.run -RequireObservedReceipts
                }
                if ($selectionPlan.mode -eq "classification-required") {
                    Set-RunFailureContext -Category "missing-suite" -RequiredAction "classify-tests-and-repeat-original-itl-command"
                    throw "ITL_TEST_CLASSIFICATION_REQUIRED: $($selectionPlan.reason) Inventory: $(Get-VerificationClassificationInventoryPath)"
                }
            }
        }
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
            lastVerificationEvidenceKind = $(if ([string](Get-StateValue -State $verification -Name 'assessmentKind' -Default '') -eq 'current-obligations') { 'complete/current-obligations' } else { 'full' })
            lastVerificationTrigger = $Trigger
            lastVerificationSkippedComponents = @($skipped | ForEach-Object component)
        }
        Write-Host 'Canonical verification passed: current observed obligations and exact loaded target are complete; skipped runners were not started.'
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
                Write-Host "[WARN] Retained verification completed, but one-off proof is still pending: $($oneOffIssues -join '; '). Result readiness remains partial."
            }
        }
    }
}
