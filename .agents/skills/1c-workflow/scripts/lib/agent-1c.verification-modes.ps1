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
    param([object]$State)

    $stateWithBaseline = Ensure-DevBranchEventLogBaseline -State $State
    $baselinePath = Get-StateValue -State $stateWithBaseline -Name "eventLogBaselinePath" -Default (Get-DevBranchEventLogBaselinePath -State $stateWithBaseline)
    $baseline = Read-Utf8Text -Path $baselinePath | ConvertFrom-Json
    $known = @{}
    foreach ($signature in @($baseline.signatures)) { if ($signature) { $known[[string]$signature] = $true } }
    $read = Read-DevBranchEventLogErrors -State $stateWithBaseline
    $newErrors = @($read.events | Where-Object { -not $known.ContainsKey([string]$_.signature) })
    $status = $(if ($newErrors.Count -eq 0) { "passed" } else { "failed" })
    $reason = $(if ($newErrors.Count -eq 0) { "1C event log contains no signatures outside the branch baseline." } else { "1C event log contains $($newErrors.Count) signature(s) outside the branch baseline." })
    Update-DevBranchState -State $stateWithBaseline -Updates @{
        lastEventLogOnlyStatus = $status
        lastEventLogOnlyCheckedAt = (Get-Date).ToString("o")
        lastEventLogOnlyReader = $read.reader
        lastEventLogOnlyReason = $reason
        lastEventLogOnlyNewErrorCount = $newErrors.Count
    }
    Write-Host "Event-log verification: $status. $reason"
    if ($status -ne "passed") { throw $reason }
}

function Invoke-ItlVerificationCycle {
    param(
        [ValidateSet("implicit", "command", "repair", "explicit")][string]$Trigger = "command",
        [string[]]$ExplicitComponents = @()
    )

    $state = Read-DevBranchState -Name $DevBranchName
    $vanessa = Get-ItlVerificationExecutionDecision -Component "vanessa" -Trigger $Trigger -ExplicitComponents $ExplicitComponents
    $eventLog = Get-ItlVerificationExecutionDecision -Component "event-log" -Trigger $Trigger -ExplicitComponents $ExplicitComponents
    $decisions = @($vanessa, $eventLog)
    foreach ($decision in $decisions) { Write-Host "Verification component $($decision.component): $(if ($decision.run) { 'RUN' } else { 'SKIP' }) ($($decision.reason))" }

    if ($vanessa.run) {
        $script:ItlSkipEventLogForVerification = -not $eventLog.run
        try { Run-DevBranchTests } finally { $script:ItlSkipEventLogForVerification = $false }
    } elseif ($eventLog.run) {
        Test-ItlEventLogCurrent -State $state
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
