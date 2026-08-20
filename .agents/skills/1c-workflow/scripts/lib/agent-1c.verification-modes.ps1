function Get-ItlVerificationMode {
    param([ValidateSet("vanessa", "event-log")][string]$Component)

    $key = $(if ($Component -eq "vanessa") { "ITL_VANESSA_TESTING" } else { "ITL_CHECK_EVENT_LOG" })
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
        [ValidateSet("vanessa", "event-log")][string]$Component,
        [ValidateSet("implicit", "command", "repair", "explicit")][string]$Trigger,
        [string[]]$ExplicitComponents = @()
    )

    $mode = Get-ItlVerificationMode -Component $Component
    $isExplicit = $Trigger -eq "explicit" -and ($ExplicitComponents -contains $Component -or $ExplicitComponents -contains "all")
    $run = if ($isExplicit) {
        $true
    } elseif ($mode.effective -eq "auto") {
        $true
    } elseif ($mode.effective -eq "manual") {
        $Trigger -in @("command", "repair")
    } else {
        $false
    }
    $reason = if ($run) {
        $(if ($isExplicit) { "explicit user request for $Component" } else { "$($mode.effective) mode permits $Trigger verification" })
    } else {
        "$($mode.key)=$($mode.effective) skips $Component for trigger=$Trigger"
    }
    return [pscustomobject]@{
        component = $Component
        mode = $mode.effective
        rawMode = $mode.raw
        valid = $mode.valid
        trigger = $Trigger
        run = [bool]$run
        reason = $reason
    }
}

function Write-ItlVerificationModeStatus {
    foreach ($component in @("vanessa", "event-log")) {
        $mode = Get-ItlVerificationMode -Component $component
        $suffix = $(if ($mode.valid) { "" } else { " (invalid '$($mode.raw)'; effective safe default auto)" })
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
        { $_ -in @("lite", "on") } { @{ ITL_VANESSA_TESTING = "off"; ITL_CHECK_EVENT_LOG = "off" }; break }
        "standard" { @{ ITL_VANESSA_TESTING = "auto"; ITL_CHECK_EVENT_LOG = "manual" }; break }
        { $_ -in @("full", "off") } { @{ ITL_VANESSA_TESTING = "auto"; ITL_CHECK_EVENT_LOG = "auto" }; break }
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

function Start-ItlVerificationRepairSession {
    $state = Read-DevBranchState -Name $DevBranchName
    Assert-CurrentProjectRootMatchesDevBranchState -State $state -Operation "begin-verification-repair"
    $record = [pscustomobject][ordered]@{
        schemaVersion = 1
        sessionId = [guid]::NewGuid().ToString("N")
        projectRoot = $script:ProjectRoot
        branch = Get-CurrentBranch
        attempts = 0
        maximumAttempts = 3
        status = "active"
        startedAt = (Get-Date).ToString("o")
        updatedAt = (Get-Date).ToString("o")
    }
    $path = Get-ItlVerificationRepairStatePath
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
    Write-Utf8Text -Path $path -Value (($record | ConvertTo-Json -Depth 5) + [Environment]::NewLine)
    Write-Host "Repair session: $($record.sessionId)"
    Write-Host "Repair attempts: 0/3"
    Set-RunUserReport -Report "Repair session: $($record.sessionId). Repair attempts: 0/3."
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
        throw "Repair session $($record.sessionId) is not active (status=$($record.status)). Begin a new /itl-verify-fix invocation."
    }
    return $record
}

function Test-ItlFullVerificationProofEligible {
    param(
        [ValidateSet("implicit", "command", "repair", "explicit")][string]$Trigger,
        [string[]]$ExplicitComponents = @()
    )

    if ($VanessaFeaturePath -or $VanessaFilterTags) { return $false }
    $decisions = @(
        Get-ItlVerificationExecutionDecision -Component "vanessa" -Trigger $Trigger -ExplicitComponents $ExplicitComponents
        Get-ItlVerificationExecutionDecision -Component "event-log" -Trigger $Trigger -ExplicitComponents $ExplicitComponents
    )
    return @($decisions | Where-Object { -not $_.run }).Count -eq 0
}

function Use-ItlVerificationRepairAttempt {
    if ($VerificationTrigger -ne "repair") { return }
    $record = Get-ItlMatchingVerificationRepairSession
    $path = Get-ItlVerificationRepairStatePath
    if ([int]$record.attempts -ge 3) {
        Set-RunFailureContext -Category "runner" -RequiredAction "report-blocker"
        throw "Repair session $($record.sessionId) exhausted its three full verification runs. Return blocker diagnostics; a fourth run is forbidden."
    }
    $record.attempts = [int]$record.attempts + 1
    $record.updatedAt = (Get-Date).ToString("o")
    Write-Utf8Text -Path $path -Value (($record | ConvertTo-Json -Depth 5) + [Environment]::NewLine)
    Write-Host "Repair session: $($record.sessionId)"
    Write-Host "Repair attempt: $($record.attempts)/3"
}

function Complete-ItlVerificationRepairSession {
    if ($VerificationTrigger -ne "repair") { return }
    $path = Get-ItlVerificationRepairStatePath
    $record = Get-ItlMatchingVerificationRepairSession
    $record.status = "passed"
    $record.updatedAt = (Get-Date).ToString("o")
    Write-Utf8Text -Path $path -Value (($record | ConvertTo-Json -Depth 5) + [Environment]::NewLine)
}

function Invoke-ItlVerificationCycle {
    param(
        [ValidateSet("implicit", "command", "repair", "explicit")][string]$Trigger = "command",
        [string[]]$ExplicitComponents = @(),
        [string]$EventLogCursorPath = "",
        [Nullable[datetime]]$EventLogBoundaryAt = $null,
        [string]$EventLogCursorScope = "vanessa-only"
    )

    $state = Read-DevBranchState -Name $DevBranchName
    $vanessa = Get-ItlVerificationExecutionDecision -Component "vanessa" -Trigger $Trigger -ExplicitComponents $ExplicitComponents
    $eventLog = Get-ItlVerificationExecutionDecision -Component "event-log" -Trigger $Trigger -ExplicitComponents $ExplicitComponents
    $decisions = @($vanessa, $eventLog)
    foreach ($decision in $decisions) { Write-Host "Verification component $($decision.component): $(if ($decision.run) { 'RUN' } else { 'SKIP' }) ($($decision.reason))" }

    if ($vanessa.run) {
        $script:ItlSkipEventLogForVerification = -not $eventLog.run
        $recordFullProof = Test-ItlFullVerificationProofEligible -Trigger $Trigger -ExplicitComponents $ExplicitComponents
        try {
            Run-DevBranchTests `
                -RecordFullVerificationEvidence:$recordFullProof `
                -EventLogCursorPath $EventLogCursorPath `
                -EventLogBoundaryAt $EventLogBoundaryAt `
                -EventLogCursorScope $EventLogCursorScope
        } finally { $script:ItlSkipEventLogForVerification = $false }
    } elseif ($eventLog.run) {
        Test-ItlEventLogCurrent -State $state -CursorPath $EventLogCursorPath -BoundaryAt $EventLogBoundaryAt -CursorScope $EventLogCursorScope -Trigger $Trigger
    }
    $state = Read-DevBranchState -Name $DevBranchName
    $skipped = @($decisions | Where-Object { -not $_.run })
    if ($skipped.Count -gt 0) {
        Set-ItlPartialVerificationEvidence -State $state -Decisions $decisions -Trigger $Trigger
    } else {
        $verification = Get-VerificationState -State $state
        if ($verification.status -eq "passed") {
            Update-DevBranchState -State $state -Updates @{
                lastVerificationEvidenceKind = "full"
                lastVerificationTrigger = $Trigger
                lastVerificationSkippedComponents = @()
            }
        }
    }
}
