if (-not (Get-Variable -Name OneCSessionLaunchContext -Scope Script -ErrorAction SilentlyContinue)) {
    $script:OneCSessionLaunchContext = $null
}

function Get-OneCMaxConcurrentSessions {
    $rawValue = Get-EnvValue -Name "ONEC_MAX_CONCURRENT_SESSIONS" -Default 3
    $text = ([string]$rawValue).Trim()
    $parsed = 0
    if ($text -notmatch '^\d+$' -or
        -not [int]::TryParse($text, [ref]$parsed) -or
        $parsed -lt 0 -or
        $parsed -gt 1024) {
        throw "ONEC_MAX_CONCURRENT_SESSIONS must be an integer between 0 and 1024. Actual: '$rawValue'. Use 0 only to disable the limit explicitly."
    }
    return $parsed
}

function Ensure-OneCSessionLimitDotEnv {
    $path = Join-Path $script:ProjectRoot ".dev.env"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf -ErrorAction SilentlyContinue)) {
        return $false
    }
    $hasSetting = [bool](Read-Utf8Lines -Path $path | Where-Object {
        $_ -match '^\s*(?:AGENT_1C_)?ONEC_MAX_CONCURRENT_SESSIONS\s*='
    } | Select-Object -First 1)
    if ($hasSetting) {
        return $false
    }
    Set-DotEnvValues -Values @{ ONEC_MAX_CONCURRENT_SESSIONS = 3 }
    Import-DotEnv -Path $path -Overwrite
    Write-Host "Added ONEC_MAX_CONCURRENT_SESSIONS=3 to .dev.env."
    return $true
}

function Get-OneCProcessInfo {
    param([switch]$RequireSuccess)

    try {
        return @(Get-CimInstance Win32_Process -Filter "Name = '1cv8.exe' OR Name = '1cv8c.exe'" -ErrorAction Stop | ForEach-Object {
            $processStartTime = ""
            if ($null -ne $_.CreationDate) {
                try { $processStartTime = ([datetime]$_.CreationDate).ToUniversalTime().ToString("o") } catch {}
            }
            [pscustomobject]@{
                processId = [int]$_.ProcessId
                name = [string]$_.Name
                commandLine = [string]$_.CommandLine
                executablePath = [string]$_.ExecutablePath
                processStartTime = $processStartTime
                workingSetMb = [math]::Round(([double]$_.WorkingSetSize / 1MB), 1)
            }
        })
    } catch {
        if ($RequireSuccess) {
            throw "ITL_ONEC_PROCESS_INSPECTION_UNAVAILABLE: active 1C processes could not be inspected safely. $($_.Exception.Message)"
        }
        Write-Host "[WARN] Could not inspect active 1C processes: $($_.Exception.Message)"
        return @()
    }
}

function Get-OneCCommandLineSwitchPath {
    param(
        [AllowNull()][string]$CommandLine,
        [Parameter(Mandatory = $true)][string[]]$SwitchNames
    )

    if ([string]::IsNullOrWhiteSpace($CommandLine) -or $SwitchNames.Count -eq 0) { return "" }
    $switchPattern = @($SwitchNames | ForEach-Object { [regex]::Escape($_) }) -join '|'
    $matches = [regex]::Matches(
        $CommandLine,
        '(?i)(?:^|\s)/(?:' + $switchPattern + ')(?=\s|")\s*(?:"(?<quoted>[^"]+)"|(?<unquoted>.*?))(?=\s+"?[/-][A-Za-z]|$)'
    )
    if ($matches.Count -ne 1) { return "" }
    $match = $matches[0]
    return ([string]$(if ($match.Groups["quoted"].Success) { $match.Groups["quoted"].Value } else { $match.Groups["unquoted"].Value })).Trim()
}

function Get-SafeOneCProcessInfoBase {
    param([AllowNull()][string]$CommandLine)

    return (Get-OneCCommandLineSwitchPath -CommandLine $CommandLine -SwitchNames @("F", "S"))
}

function Get-OneCInfoBaseIdentity {
    param(
        [Parameter(Mandatory = $true)][ValidateSet("file", "server")][string]$InfoBaseKind,
        [Parameter(Mandatory = $true)][string]$InfoBasePath
    )

    $kind = $InfoBaseKind.Trim().ToLowerInvariant()
    $value = if ($kind -eq "file") {
        Resolve-Agent1cFullPath -Path $InfoBasePath
    } else {
        $InfoBasePath.Trim()
    }
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "Infobase identity is empty."
    }
    return [pscustomobject][ordered]@{
        kind = $kind
        value = $value
        key = ($kind + "|" + $value.ToLowerInvariant())
    }
}

function Test-OneCCommandLineInfoBasePath {
    param(
        [AllowNull()][string]$CommandLine,
        [AllowNull()][string]$InfoBasePath,
        [ValidateSet("", "file", "server")][string]$InfoBaseKind = ""
    )

    if ([string]::IsNullOrWhiteSpace($CommandLine) -or [string]::IsNullOrWhiteSpace($InfoBasePath)) {
        return $false
    }

    $kinds = if ($InfoBaseKind) { @($InfoBaseKind) } else { @("file", "server") }
    foreach ($kind in $kinds) {
        $switchName = if ($kind -eq "file") { "F" } else { "S" }
        $candidate = Get-OneCCommandLineSwitchPath -CommandLine $CommandLine -SwitchNames @($switchName)
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        try {
            $actual = Get-OneCInfoBaseIdentity -InfoBaseKind $kind -InfoBasePath $candidate
            $expected = Get-OneCInfoBaseIdentity -InfoBaseKind $kind -InfoBasePath $InfoBasePath
        } catch {
            continue
        }
        if ([string]::Equals($actual.key, $expected.key, [System.StringComparison]::Ordinal)) {
            return $true
        }
    }
    return $false
}

function Get-OneCSessionProcessRole {
    param([AllowNull()][string]$CommandLine)

    if ($CommandLine -match '(?i)(?:^|\s)/TESTCLIENT(?:\s|$)') { return "test-client" }
    if ($CommandLine -match '(?i)(?:^|\s)/TESTMANAGER(?:\s|$)') { return "test-manager" }
    if ($CommandLine -match '(?i)(?:^|\s)DESIGNER(?:\s|$)') { return "configurator" }
    return "enterprise"
}

function Get-OneCInfoBaseSessionProcesses {
    param(
        [Parameter(Mandatory = $true)][ValidateSet("file", "server")][string]$InfoBaseKind,
        [Parameter(Mandatory = $true)][string]$InfoBasePath
    )

    return @(Get-OneCProcessInfo -RequireSuccess | Where-Object {
        Test-OneCCommandLineInfoBasePath `
            -CommandLine ([string](Get-StateValue -State $_ -Name "commandLine" -Default "")) `
            -InfoBasePath $InfoBasePath `
            -InfoBaseKind $InfoBaseKind
    } | ForEach-Object {
        [pscustomobject][ordered]@{
            pid = [int](Get-StateValue -State $_ -Name "processId" -Default 0)
            role = Get-OneCSessionProcessRole -CommandLine ([string](Get-StateValue -State $_ -Name "commandLine" -Default ""))
            processStartTime = [string](Get-StateValue -State $_ -Name "processStartTime" -Default "")
        }
    })
}

function Get-OneCSessionRegistryPath {
    return (Join-Path (Get-ItlPortRegistryHome) "onec-sessions.json")
}

function Read-OneCSessionRegistry {
    $path = Get-OneCSessionRegistryPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ schemaVersion = 1; reservations = @(); updatedAt = "" }
    }
    try {
        $registry = Read-Utf8Text -Path $path | ConvertFrom-Json
    } catch {
        throw "ITL 1C session registry is not valid JSON: $path. $($_.Exception.Message)"
    }
    if ([int](Get-StateValue -State $registry -Name "schemaVersion" -Default 0) -ne 1) {
        throw "Unsupported ITL 1C session registry schema: $path"
    }
    return $registry
}

function Write-OneCSessionRegistry {
    param([object[]]$Reservations)

    $registry = [ordered]@{
        schemaVersion = 1
        reservations = @($Reservations)
        updatedAt = (Get-Date).ToUniversalTime().ToString("o")
    }
    Write-Utf8TextAtomic -Path (Get-OneCSessionRegistryPath) -Value (($registry | ConvertTo-Json -Depth 10) + [Environment]::NewLine)
}

function Remove-OneCSessionReservation {
    param([AllowNull()][string]$ReservationId)

    if ([string]::IsNullOrWhiteSpace($ReservationId)) { return }
    Invoke-ItlPortRegistryLock {
        $registry = Read-OneCSessionRegistry
        $reservations = @()
        $property = $registry.PSObject.Properties["reservations"]
        if ($null -ne $property -and $null -ne $property.Value) {
            $reservations = @($property.Value)
        }
        $remaining = @($reservations | Where-Object {
            -not [string]::Equals(
                [string](Get-StateValue -State $_ -Name "id" -Default ""),
                $ReservationId,
                [StringComparison]::Ordinal
            )
        })
        if ($remaining.Count -ne $reservations.Count) {
            Write-OneCSessionRegistry -Reservations $remaining
        }
    } | Out-Null
}

function Test-OneCSessionProcessIdentityPresent {
    param(
        [int]$ProcessId,
        [AllowNull()][string]$ProcessStartTime
    )

    if ($ProcessId -le 0) { return $false }
    try { $process = Get-Process -Id $ProcessId -ErrorAction Stop } catch { return $false }
    if ([string]::IsNullOrWhiteSpace($ProcessStartTime)) { return $true }
    $expected = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse($ProcessStartTime, [ref]$expected)) { return $true }
    try { return ($process.StartTime.ToUniversalTime() -eq $expected.UtcDateTime) } catch { return $true }
}

function Get-OneCSessionReservationSnapshot {
    param(
        [Parameter(Mandatory = $true)][object]$Registry,
        [Parameter(Mandatory = $true)][object]$InfoBaseIdentity,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Processes
    )

    $preserved = [System.Collections.Generic.List[object]]::new()
    $matching = [System.Collections.Generic.List[object]]::new()
    $registryReservations = @()
    $reservationsProperty = $Registry.PSObject.Properties["reservations"]
    if ($null -ne $reservationsProperty -and $null -ne $reservationsProperty.Value) {
        $registryReservations = @($reservationsProperty.Value)
    }
    foreach ($reservation in $registryReservations) {
        $machine = [string](Get-StateValue -State $reservation -Name "machine" -Default "")
        if ($machine -and -not [string]::Equals($machine, [Environment]::MachineName, [System.StringComparison]::OrdinalIgnoreCase)) {
            $preserved.Add($reservation) | Out-Null
            continue
        }
        $ownerAlive = Test-OneCSessionProcessIdentityPresent `
            -ProcessId ([int](Get-StateValue -State $reservation -Name "ownerPid" -Default 0)) `
            -ProcessStartTime ([string](Get-StateValue -State $reservation -Name "ownerProcessStartTime" -Default ""))
        $leaderAlive = Test-OneCSessionProcessIdentityPresent `
            -ProcessId ([int](Get-StateValue -State $reservation -Name "leaderPid" -Default 0)) `
            -ProcessStartTime ([string](Get-StateValue -State $reservation -Name "leaderProcessStartTime" -Default ""))
        if (-not $ownerAlive -and -not $leaderAlive) { continue }

        if ([string](Get-StateValue -State $reservation -Name "infoBaseKey" -Default "") -eq [string]$InfoBaseIdentity.key) {
            $matching.Add($reservation) | Out-Null
        } else {
            $preserved.Add($reservation) | Out-Null
        }
    }

    $assigned = [System.Collections.Generic.HashSet[int]]::new()
    $pendingDetails = [System.Collections.Generic.List[object]]::new()
    foreach ($reservation in @($matching | Sort-Object { [string](Get-StateValue -State $_ -Name "createdAt" -Default "") })) {
        $initial = [System.Collections.Generic.HashSet[int]]::new()
        foreach ($pidValue in @((Get-StateValue -State $reservation -Name "initialProcessIds" -Default @()))) {
            [void]$initial.Add([int]$pidValue)
        }
        $required = [int](Get-StateValue -State $reservation -Name "requiredSessions" -Default 1)
        $fulfilled = 0
        $expectedChildRole = [string](Get-StateValue -State $reservation -Name "expectedChildRole" -Default "")
        if ($expectedChildRole) {
            $leaderPid = [int](Get-StateValue -State $reservation -Name "leaderPid" -Default 0)
            $leader = @($Processes | Where-Object {
                [int]$_.pid -eq $leaderPid -and -not $initial.Contains([int]$_.pid) -and -not $assigned.Contains([int]$_.pid)
            } | Select-Object -First 1)
            if ($leader.Count -gt 0) {
                [void]$assigned.Add($leaderPid)
                $fulfilled++
            }
            foreach ($process in @($Processes | Where-Object { [string]$_.role -eq $expectedChildRole } | Sort-Object pid)) {
                $processId = [int]$process.pid
                if ($initial.Contains($processId) -or $assigned.Contains($processId)) { continue }
                [void]$assigned.Add($processId)
                $fulfilled++
                if ($fulfilled -ge $required) { break }
            }
        } else {
            foreach ($process in @($Processes | Sort-Object pid)) {
                $processId = [int]$process.pid
                if ($initial.Contains($processId) -or $assigned.Contains($processId)) { continue }
                [void]$assigned.Add($processId)
                $fulfilled++
                if ($fulfilled -ge $required) { break }
            }
        }
        $pending = [Math]::Max(0, $required - $fulfilled)
        if ($pending -gt 0) {
            $preserved.Add($reservation) | Out-Null
            $pendingDetails.Add([pscustomobject][ordered]@{
                id = [string](Get-StateValue -State $reservation -Name "id" -Default "")
                purpose = [string](Get-StateValue -State $reservation -Name "purpose" -Default "")
                pending = $pending
                leaderPid = [int](Get-StateValue -State $reservation -Name "leaderPid" -Default 0)
            }) | Out-Null
        }
    }

    return [pscustomobject][ordered]@{
        reservations = @($preserved)
        pending = [int](@($pendingDetails | ForEach-Object { $_.pending } | Measure-Object -Sum).Sum)
        pendingDetails = @($pendingDetails)
    }
}

function Invoke-OneCSessionAdmission {
    param(
        [Parameter(Mandatory = $true)][ValidateSet("file", "server")][string]$InfoBaseKind,
        [Parameter(Mandatory = $true)][string]$InfoBasePath,
        [ValidateRange(1, 64)][int]$RequiredSessions = 1,
        [ValidateSet("", "test-client")][string]$ExpectedChildRole = "",
        [string]$Purpose = "1c-process",
        [Parameter(Mandatory = $true)][scriptblock]$StartProcess
    )

    return (Invoke-OneCSessionAdmissionSet `
        -Admissions @([pscustomobject]@{
            infoBaseKind = $InfoBaseKind
            infoBasePath = $InfoBasePath
            requiredSessions = $RequiredSessions
            expectedChildRole = $ExpectedChildRole
            purpose = $Purpose
        }) `
        -StartProcess $StartProcess)
}

function Invoke-OneCSessionAdmissionSet {
    param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][object[]]$Admissions,
        [Parameter(Mandatory = $true)][scriptblock]$StartProcess
    )

    $maximum = Get-OneCMaxConcurrentSessions
    if ($maximum -eq 0) {
        return (& $StartProcess)
    }

    $normalized = @($Admissions | ForEach-Object {
        $kind = [string](Get-StateValue -State $_ -Name "infoBaseKind" -Default "")
        $path = [string](Get-StateValue -State $_ -Name "infoBasePath" -Default "")
        $required = [int](Get-StateValue -State $_ -Name "requiredSessions" -Default 1)
        $role = [string](Get-StateValue -State $_ -Name "expectedChildRole" -Default "")
        $purpose = [string](Get-StateValue -State $_ -Name "purpose" -Default "1c-process")
        if ($kind -notin @("file", "server") -or [string]::IsNullOrWhiteSpace($path) -or
            $required -lt 1 -or $required -gt 64 -or $role -notin @("", "test-client")) {
            throw "ITL_ONEC_SESSION_ADMISSION_INVALID: kind='$kind' path='$path' required=$required role='$role' purpose='$purpose'."
        }
        $identity = Get-OneCInfoBaseIdentity -InfoBaseKind $kind -InfoBasePath $path
        if ($required -gt $maximum) {
            throw "ITL_ONEC_SESSION_LIMIT: max=$maximum active=0 reserved=0 required=$required infobase='$($identity.value)' purpose=$purpose errorCategory=session-capacity requiredAction=finish-or-close-owned-sessions-before-retry retryAction=repeat-original-command-after-session-count-changes limitChange=developer-only"
        }
        [pscustomobject][ordered]@{
            identity = $identity
            requiredSessions = $required
            expectedChildRole = $role
            purpose = $purpose
        }
    })
    $duplicate = @($normalized | Group-Object { [string]$_.identity.key } | Where-Object Count -gt 1)
    if ($duplicate.Count -gt 0) {
        throw "ITL_ONEC_SESSION_ADMISSION_INVALID: duplicate infobase identities are not allowed in one atomic admission set."
    }

    return (Invoke-ItlPortRegistryLock {
        $registry = Read-OneCSessionRegistry
        $preservedReservations = @($registry.reservations)
        $snapshots = [System.Collections.Generic.List[object]]::new()
        foreach ($admission in $normalized) {
            $identity = $admission.identity
            $processes = @(Get-OneCInfoBaseSessionProcesses -InfoBaseKind $identity.kind -InfoBasePath $identity.value)
            $snapshot = Get-OneCSessionReservationSnapshot `
                -Registry ([pscustomobject]@{ reservations = @($preservedReservations) }) `
                -InfoBaseIdentity $identity `
                -Processes $processes
            $active = @($processes).Count
            $reserved = [int]$snapshot.pending
            if (($active + $reserved + [int]$admission.requiredSessions) -gt $maximum) {
                $processDetails = @($processes | Select-Object pid, role) | ConvertTo-Json -Compress -Depth 4
                $reservationDetails = @($snapshot.pendingDetails) | ConvertTo-Json -Compress -Depth 4
                throw "ITL_ONEC_SESSION_LIMIT: max=$maximum active=$active reserved=$reserved required=$($admission.requiredSessions) infobase='$($identity.value)' purpose=$($admission.purpose) processes=$processDetails reservations=$reservationDetails errorCategory=session-capacity requiredAction=finish-or-close-owned-sessions-before-retry retryAction=repeat-original-command-after-session-count-changes limitChange=developer-only"
            }
            $preservedReservations = @($snapshot.reservations)
            $snapshots.Add([pscustomobject]@{ admission = $admission; processes = @($processes) }) | Out-Null
        }

        $startedProcess = & $StartProcess
        $purposeLabel = @($normalized | ForEach-Object { $_.purpose }) -join "+"
        if ($null -eq $startedProcess -or $startedProcess.PSObject.Properties.Match("Id").Count -eq 0 -or [int]$startedProcess.Id -le 0) {
            throw "ITL_ONEC_SESSION_START_UNPROVEN: guarded launcher did not return a process identity for '$purposeLabel'."
        }
        $leaderStartTime = ""
        try { $leaderStartTime = $startedProcess.StartTime.ToUniversalTime().ToString("o") } catch {}
        $ownerStartTime = ""
        try { $ownerStartTime = (Get-Process -Id $PID -ErrorAction Stop).StartTime.ToUniversalTime().ToString("o") } catch {}
        $createdAt = [DateTime]::UtcNow.ToString("o")
        $newReservations = @($snapshots | ForEach-Object {
            $identity = $_.admission.identity
            [pscustomobject][ordered]@{
                id = [guid]::NewGuid().ToString("N")
                machine = [Environment]::MachineName
                infoBaseKind = $identity.kind
                infoBaseValue = $identity.value
                infoBaseKey = $identity.key
                requiredSessions = [int]$_.admission.requiredSessions
                expectedChildRole = [string]$_.admission.expectedChildRole
                initialProcessIds = @($_.processes | ForEach-Object { [int]$_.pid })
                ownerPid = $PID
                ownerProcessStartTime = $ownerStartTime
                leaderPid = [int]$startedProcess.Id
                leaderProcessStartTime = $leaderStartTime
                purpose = [string]$_.admission.purpose
                projectRoot = [string]$script:ProjectRoot
                createdAt = $createdAt
            }
        })
        try {
            Write-OneCSessionRegistry -Reservations (@($preservedReservations) + @($newReservations))
        } catch {
            $registryError = $_.Exception.Message
            $cleanup = Stop-NativeProcessForSafety -Process $startedProcess
            throw "ITL_ONEC_SESSION_RESERVATION_FAILED: started PID $($startedProcess.Id) was stopped=$($cleanup.confirmed) because session admission could not be recorded. registryError='$registryError' cleanupError='$($cleanup.error)'"
        }
        if ($null -ne $script:OneCSessionLaunchContext) {
            $script:OneCSessionLaunchContext.reservationIds = @($newReservations | ForEach-Object { [string]$_.id })
        }
        return $startedProcess
    })
}

function Invoke-OneCSessionProcessStart {
    param([Parameter(Mandatory = $true)][scriptblock]$StartProcess)

    $context = $script:OneCSessionLaunchContext
    if ($null -eq $context) {
        return (& $StartProcess)
    }
    if ([bool]$context.consumed) {
        throw "ITL_ONEC_SESSION_ADMISSION_REUSED: one admission context cannot launch more than one process."
    }
    $context.consumed = $true
    return (Invoke-OneCSessionAdmissionSet -Admissions @($context.admissions) -StartProcess $StartProcess)
}

function Invoke-WithOneCSessionAdmissionContext {
    param(
        [Parameter(Mandatory = $true)][ValidateSet("file", "server")][string]$InfoBaseKind,
        [Parameter(Mandatory = $true)][string]$InfoBasePath,
        [ValidateRange(1, 64)][int]$RequiredSessions = 1,
        [ValidateSet("", "test-client")][string]$ExpectedChildRole = "",
        [string]$Purpose = "1c-process",
        [object[]]$AdditionalAdmissions = @(),
        [switch]$KeepReservation,
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock
    )

    $previous = $script:OneCSessionLaunchContext
    $admissions = @([pscustomobject]@{
        infoBaseKind = $InfoBaseKind
        infoBasePath = $InfoBasePath
        requiredSessions = $RequiredSessions
        expectedChildRole = $ExpectedChildRole
        purpose = $Purpose
    }) + @($AdditionalAdmissions)
    $script:OneCSessionLaunchContext = [pscustomobject]@{
        infoBaseKind = $InfoBaseKind
        infoBasePath = $InfoBasePath
        requiredSessions = $RequiredSessions
        expectedChildRole = $ExpectedChildRole
        purpose = $Purpose
        admissions = @($admissions)
        consumed = $false
        reservationIds = @()
        keepReservation = [bool]$KeepReservation
    }
    try {
        return (& $ScriptBlock)
    } finally {
        $completedContext = $script:OneCSessionLaunchContext
        $script:OneCSessionLaunchContext = $previous
        if ($null -ne $completedContext -and -not [bool]$completedContext.keepReservation) {
            foreach ($reservationId in @($completedContext.reservationIds)) {
                Remove-OneCSessionReservation -ReservationId ([string]$reservationId)
            }
        }
    }
}

function Start-OneCProcessBackground {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Arguments,
        [Parameter(Mandatory = $true)][ValidateSet("file", "server")][string]$InfoBaseKind,
        [Parameter(Mandatory = $true)][string]$InfoBasePath,
        [ValidateRange(1, 64)][int]$RequiredSessions = 1,
        [ValidateSet("", "test-client")][string]$ExpectedChildRole = "",
        [string]$Purpose = "project-1c-process",
        [switch]$Visible
    )

    return (Invoke-WithOneCSessionAdmissionContext `
        -InfoBaseKind $InfoBaseKind `
        -InfoBasePath $InfoBasePath `
        -RequiredSessions $RequiredSessions `
        -ExpectedChildRole $ExpectedChildRole `
        -Purpose $Purpose `
        -KeepReservation `
        -ScriptBlock {
            Start-NativeProcessBackground -FilePath $FilePath -Arguments $Arguments -Visible:$Visible
        })
}
