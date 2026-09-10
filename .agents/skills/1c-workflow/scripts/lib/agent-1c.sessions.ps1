if (-not (Get-Variable -Name OneCSessionLaunchContext -Scope Script -ErrorAction SilentlyContinue)) {
    $script:OneCSessionLaunchContext = $null
}

if (-not (Get-Variable -Name OneCNativeOperationJournal -Scope Script -ErrorAction SilentlyContinue)) {
    $script:OneCNativeOperationJournal = $null
}

function New-OneCNativeOperationJournal {
    param([object[]]$Resources = @(), [AllowNull()][object]$Owner = $null)
    # The aggregate database admission owns this journal. Session-capacity
    # reservation removal is not proof that database work has stopped.
    return [pscustomobject]@{ entries = [Collections.Generic.List[object]]::new(); restorations = [Collections.Generic.List[object]]::new(); resources = @($Resources); owner = $Owner; persistence = $null }
}

function Initialize-OneCNativeRecoveryContext {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot, [AllowNull()][object]$Configuration = $null,
        [string]$DatabaseAccessBridgePath = '')
    # Called in a fresh recovery verifier after loading the retained modules.
    # Do not run today's helper entrypoint or import a changed project config.
    $script:ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)
    $script:Config = if ($null -ne $Configuration) { $Configuration } else { [pscustomobject]@{} }
    $script:NativeRecoveryDatabaseAccessBridgePath = $DatabaseAccessBridgePath
    $script:LifecycleOperationRecord = $null
    $script:LifecycleOperationStatePath = ''
    $script:LastLogPath = ''
    $script:LastProcessId = 0
    $script:LastProcessTimedOut = $false
    $script:LastProcessMemoryLimitExceeded = $false
    $script:LastProcessPeakWorkingSetMb = 0
    $script:LastProcessWorkingSetLimitMb = 0
    $script:RunStatusPath = ''
    $script:RunProbePhase = ''
    $script:OneCSessionLaunchContext = $null
    $script:OneCNativeOperationJournal = $null
    Set-RunStage -Stage 'native-recovery' -Detail 'Reconcile an interrupted native operation.'
}

function Get-OneCDatabaseAccessBridgePath {
    $override = Get-Variable -Name NativeRecoveryDatabaseAccessBridgePath -Scope Script -ErrorAction SilentlyContinue
    if ($null -ne $override -and $override.Value) { return [string]$override.Value }
    return (Join-Path $PSScriptRoot '../../../itl-remote-runner/scripts/DatabaseAccess.ps1')
}

function Save-OneCNativeRecoveryHelpers {
    param([Parameter(Mandatory = $true)][string]$CoordinatorRoot, [string]$LibraryRoot = $PSScriptRoot)
    # Retain code, not project config, credentials, command lines or native
    # artifacts. The retained modules include the child process-enumeration worker's
    # dependencies. Content identity allows callers from different worktrees to
    # share the same immutable generation. Ports owns the session registry lock
    # needed when a fresh recovery process launches native rollback.
    $names = @('agent-1c.core.ps1', 'agent-1c.runtime-values.ps1', 'agent-1c.sessions.ps1', 'agent-1c.vanessa.ps1', 'agent-1c.ports.ps1')
    $files = [Collections.Generic.List[object]]::new()
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        foreach ($name in $names) {
            $bytes = [IO.File]::ReadAllBytes((Join-Path $LibraryRoot $name))
            $hash = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant()
            $files.Add([pscustomobject]@{name=$name;sha256=$hash;bytes=$bytes})
        }
        $identity = ($files | ForEach-Object { $_.name + ':' + $_.sha256 }) -join "`n"
        $generation = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($identity))).Replace('-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
    $archiveRoot = Join-Path ([IO.Path]::GetFullPath($CoordinatorRoot)) 'native-helper-generations'
    [void][IO.Directory]::CreateDirectory($archiveRoot)
    if ((Get-Item -LiteralPath $archiveRoot -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw 'ONEC_NATIVE_RECOVERY_HELPER_ARCHIVE_REDIRECTED'
    }
    $destination = Join-Path $archiveRoot $generation
    $staging = $null
    try {
        if (-not (Test-Path -LiteralPath $destination)) {
            $staging = Join-Path $archiveRoot ('.pending-' + [guid]::NewGuid().ToString('N'))
            [void][IO.Directory]::CreateDirectory($staging)
            foreach ($file in $files) { [IO.File]::WriteAllBytes((Join-Path $staging $file.name), $file.bytes) }
            for ($attempt = 1; $attempt -le 40; $attempt++) {
                try { [IO.Directory]::Move($staging, $destination); break }
                catch {
                    # A concurrent winner still needs full validation below.
                    if (Test-Path -LiteralPath $destination -PathType Container) { break }
                    $cause = $_.Exception.GetBaseException()
                    if ($attempt -ge 40 -or ($cause -isnot [IO.IOException] -and $cause -isnot [UnauthorizedAccessException])) { throw }
                    # Windows can briefly deny rename immediately after the
                    # newly written scripts are closed. Never change ACLs or
                    # replace an existing generation to work around that.
                    Start-Sleep -Milliseconds 50
                }
            }
        }
        if ((Get-Item -LiteralPath $destination -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw 'ONEC_NATIVE_RECOVERY_HELPER_ARCHIVE_REDIRECTED'
        }
        # Use the same .NET hash boundary as the producer above. A fresh
        # Windows PowerShell helper can inherit another host's module path;
        # archive validation must not depend on an auto-loaded Get-FileHash
        # function from that host's PowerShell module generation.
        $archiveSha = [Security.Cryptography.SHA256]::Create()
        try {
            foreach ($file in $files) {
                $path = Join-Path $destination $file.name
                $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
                if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
                    [BitConverter]::ToString($archiveSha.ComputeHash([IO.File]::ReadAllBytes($path))).Replace('-', '').ToLowerInvariant() -cne $file.sha256) {
                    throw 'ONEC_NATIVE_RECOVERY_HELPER_ARCHIVE_CHANGED'
                }
            }
        } finally { $archiveSha.Dispose() }
        return @($files | ForEach-Object { [pscustomobject]@{path=(Join-Path $destination $_.name);sha256=$_.sha256} })
    } finally {
        if ($staging -and (Test-Path -LiteralPath $staging -PathType Container)) {
            # Only fixed files in this call's fresh staging directory are owned.
            # Never recursively remove an archive generation or unknown files.
            foreach ($name in $names) { [IO.File]::Delete((Join-Path $staging $name)) }
            [IO.Directory]::Delete($staging)
        }
    }
}

function New-OneCNativeJournalPersistence {
    param([object[]]$Resources, [object]$Owner)
    $persistence = $null
    if ($null -ne $Owner) {
        if ($null -eq $Owner.proof -or $Owner.proof.ticket -notmatch '^[a-f0-9]{32}$' -or
            -not $Owner.proof.coordinator -or $Owner.public.ticket -cne $Owner.proof.ticket) {
            throw 'ONEC_NATIVE_JOURNAL_OWNER_INVALID'
        }
        $journalId = [guid]::NewGuid().ToString('N')
        # The public owner can be an inherited caller with no descriptive
        # metadata. Missing labels do not invalidate its admitted authority.
        $operation = ''; $project = ''
        if ($Owner.public.owner.PSObject.Properties['operation']) { $operation = [string]$Owner.public.owner.operation }
        if ($Owner.public.owner.PSObject.Properties['project']) { $project = [string]$Owner.public.owner.project }
        $persistence = [pscustomobject]@{
            owner = $Owner
            journalId = $journalId; ticket = $Owner.proof.ticket
            createdAt = [DateTime]::UtcNow.ToString('o'); hostName = [Environment]::MachineName; ownerPid = $PID
            operation = $operation; project = $project
            resources = @($Resources | ForEach-Object { [pscustomobject]@{kind=$_.kind;path=$_.path} })
            resourceIds = @($Owner.public.resources)
            helperInputs = @(Save-OneCNativeRecoveryHelpers -CoordinatorRoot $Owner.proof.coordinator)
        }
    }
    return $persistence
}

function Save-OneCNativeOperationRecord {
    param([AllowNull()][object]$Record)
    if ($null -eq $Record -or $null -eq $Record.persistence) { return }
    $binding = $Record.persistence
    # Explicit fields only: never serialize process objects, passwords, native
    # command lines, or the private inheritance proof. Every journal gets its
    # own directory even when several participants share one admission ticket.
    $payload = [ordered]@{
        schemaVersion = 1; journalId = $binding.journalId; ticket = $binding.ticket; id = $Record.id
        createdAt = $binding.createdAt; updatedAt = [DateTime]::UtcNow.ToString('o')
        hostName = $binding.hostName; ownerPid = $binding.ownerPid
        operation = $binding.operation; project = $binding.project; purpose = $Record.purpose
        resources = @($binding.resources); resourceIds = @($binding.resourceIds); helperInputs = @($binding.helperInputs)
        admissions = @($Record.admissions | ForEach-Object {
            [pscustomobject]@{kind=$_.infoBaseKind;path=$_.infoBasePath;requiredSessions=$_.requiredSessions;expectedChildRole=$_.expectedChildRole}
        })
        startAttempted = [bool]$Record.startAttempted; processId = [int]$Record.processId
        launcherExited = [bool]$Record.launcherExited; quiescenceConfirmed = [bool]$Record.quiescenceConfirmed
        releaseEvidence = $Record.releaseEvidence
        ownedProcessScopes = @($Record.ownedProcessScopes | ForEach-Object {
            if ($_.role -eq 'native-invocation') {
                [pscustomobject]@{schemaVersion=$_.schemaVersion;role=$_.role;kind=$_.kind;path=$_.path;mode=$_.mode;logPath=$_.logPath;notBeforeUtc=$_.notBeforeUtc}
            } else {
                [pscustomobject]@{schemaVersion=$_.schemaVersion;role=$_.role;kind=$_.kind;path=$_.path;runParamsPath=$_.runParamsPath;runParamsSha256=$_.runParamsSha256;testPorts=@($_.testPorts)}
            }
        })
        # A future recovery must inspect live work and the original operation's
        # restoration duties; these saved observations never authorize release.
        recoveryRequiresLiveVerification = $true
    }
    . (Get-OneCDatabaseAccessBridgePath)
    $ack = Publish-ItlDatabaseNativeOperation -Owner $binding.owner -Record $payload
    $Record.persistedPath = $ack.path
}

function Add-OneCNativeOperationRecord {
    param([object]$Journal, [object[]]$Admissions, [string]$Purpose)
    if ($null -eq $Journal) { return $null }
    if ($null -ne $Journal.owner) {
        # Build callers attach the acquired owner after allocating the journal.
        # Defer disk binding until the first operation, inside their cleanup scope.
        if ($null -eq $Journal.persistence) { $Journal.persistence = New-OneCNativeJournalPersistence -Resources $Journal.resources -Owner $Journal.owner }
        foreach ($admission in $Admissions) {
            $matches = @($Journal.resources | Where-Object {
                $_.kind -ceq $admission.infoBaseKind -and
                (Test-ItlOnDemandInfoBaseMatch -First $_.path -Second $admission.infoBasePath)
            })
            if ($matches.Count -eq 0) { throw 'INFOBASE_ACCESS_NATIVE_TARGET_NOT_RESERVED' }
        }
    }
    $record = [pscustomobject]@{
        id = [guid]::NewGuid().ToString('N')
        purpose = $Purpose
        admissions = @($Admissions)
        startAttempted = $false
        process = $null
        processId = 0
        launcherExited = $false
        quiescenceConfirmed = $false
        releaseEvidence = ''
        ownedProcessScopes = @()
        persistence = $Journal.persistence
        persistedPath = ''
    }
    $Journal.entries.Add($record)
    Save-OneCNativeOperationRecord -Record $record
    return $record
}

function Test-OneCNativeOperationJournalReleased {
    param([Parameter(Mandatory = $true)][object]$Journal)
    foreach ($record in $Journal.entries) {
        if ($record.startAttempted -and -not $record.quiescenceConfirmed) { return $false }
    }
    if ($Journal.PSObject.Properties['restorations']) {
        foreach ($duty in $Journal.restorations) { if ($duty.payload.status -eq 'pending') { return $false } }
    }
    return $true
}

function Register-OneCFileRestorationDuty {
    param([Parameter(Mandatory = $true)][object]$Snapshot)
    $journalVariable = Get-Variable -Name OneCNativeOperationJournal -Scope Script -ErrorAction SilentlyContinue
    if ($null -eq $journalVariable -or $null -eq $journalVariable.Value -or $null -eq $journalVariable.Value.owner) { return }
    $journal = $journalVariable.Value
    if ($null -eq $journal.persistence) { $journal.persistence = New-OneCNativeJournalPersistence -Resources $journal.resources -Owner $journal.owner }
    $binding = $journal.persistence
    $id = [guid]::NewGuid().ToString('N')
    $oldBackup = $Snapshot.backupPath
    if ($Snapshot.existed) {
        # Keep the snapshot with the authority, not in OS temporary storage that
        # can be removed before an interrupted operation is reconciled.
        $directory = [IO.Path]::GetFullPath($binding.owner.proof.coordinator)
        foreach ($component in @('restoration-snapshots', $binding.ticket, $binding.journalId)) {
            $directory = Join-Path $directory $component
            [void][IO.Directory]::CreateDirectory($directory)
            if ((Get-Item -LiteralPath $directory -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'ONEC_RESTORATION_SNAPSHOT_REDIRECTED' }
        }
        $retained = Join-Path $directory ($id + '.xml')
        [IO.File]::Copy($oldBackup, $retained, $false)
        if ((Get-FileHash -LiteralPath $retained -Algorithm SHA256).Hash.ToLowerInvariant() -cne $Snapshot.backupSha256) { throw 'ONEC_RESTORATION_SNAPSHOT_CHANGED' }
        $Snapshot.backupPath = $retained
    }
    $payload = [ordered]@{
        schemaVersion=1;journalId=$binding.journalId;ticket=$binding.ticket;id=$id
        createdAt=[DateTime]::UtcNow.ToString('o');updatedAt=[DateTime]::UtcNow.ToString('o')
        hostName=$binding.hostName;ownerPid=$binding.ownerPid;operation=$binding.operation;project=$binding.project
        resources=@($binding.resources);resourceIds=@($binding.resourceIds);helperInputs=@($binding.helperInputs)
        kind='config-dump-info';destination=[IO.Path]::GetFullPath($Snapshot.path);existed=[bool]$Snapshot.existed
        snapshotPath=$Snapshot.backupPath;snapshotSha256=$Snapshot.backupSha256;policy=$Snapshot.restorationPolicy;status='pending'
    }
    $duty = [pscustomobject]@{owner=$binding.owner;payload=$payload}
    $journal.restorations.Add($duty)
    $Snapshot.restorationDuty = $duty
    try {
        . (Get-OneCDatabaseAccessBridgePath)
        Publish-ItlDatabaseRestorationDuty -Owner $duty.owner -Record $payload | Out-Null
    } catch { $Snapshot.preserveBackup = $true; throw }
    if ($oldBackup -and $oldBackup -cne $Snapshot.backupPath) { [IO.File]::Delete($oldBackup) }
}

function Complete-OneCFileRestorationDuty {
    param([Parameter(Mandatory = $true)][object]$Snapshot, [ValidateSet('restored','committed')][string]$Resolution = 'restored')
    if (-not $Snapshot.PSObject.Properties['restorationDuty'] -or $null -eq $Snapshot.restorationDuty) { return }
    $duty = $Snapshot.restorationDuty
    . (Get-OneCDatabaseAccessBridgePath)
    $duty.payload.status = $Resolution
    $duty.payload.updatedAt = [DateTime]::UtcNow.ToString('o')
    try { Publish-ItlDatabaseRestorationDuty -Owner $duty.owner -Record $duty.payload | Out-Null }
    catch { $duty.payload.status = 'pending'; $Snapshot.preserveBackup = $true; throw }
}

function Register-OneCDatabaseRestorationDuty {
    param([Parameter(Mandatory = $true)][object]$State, [Parameter(Mandatory = $true)][string]$SnapshotPath,
        [ValidateSet('always','on-failure')][string]$Policy = 'always', [AllowNull()][object]$RecoveryContext = $null)
    $journalVariable = Get-Variable -Name OneCNativeOperationJournal -Scope Script -ErrorAction SilentlyContinue
    if ($null -eq $journalVariable -or $null -eq $journalVariable.Value -or $null -eq $journalVariable.Value.owner) { return $null }
    $journal = $journalVariable.Value
    if ($null -eq $journal.persistence) { $journal.persistence = New-OneCNativeJournalPersistence -Resources $journal.resources -Owner $journal.owner }
    $binding = $journal.persistence
    $path = [IO.Path]::GetFullPath($SnapshotPath)
    $payload = [ordered]@{
        schemaVersion=1;journalId=$binding.journalId;ticket=$binding.ticket;id=[guid]::NewGuid().ToString('N')
        createdAt=[DateTime]::UtcNow.ToString('o');updatedAt=[DateTime]::UtcNow.ToString('o')
        hostName=$binding.hostName;ownerPid=$binding.ownerPid;operation=$binding.operation;project=[IO.Path]::GetFullPath($script:ProjectRoot)
        resources=@($binding.resources);resourceIds=@($binding.resourceIds);helperInputs=@($binding.helperInputs)
        kind='infobase-snapshot';infoBase=[pscustomobject]@{kind=[string]$State.infoBaseKind;path=[string]$State.devBranchInfoBasePath}
        snapshotPath=$path;snapshotSha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        policy=$Policy;status='pending';restoreOperation='';recoveryContext=$RecoveryContext
    }
    $duty = [pscustomobject]@{owner=$binding.owner;payload=$payload}
    $journal.restorations.Add($duty)
    . (Get-OneCDatabaseAccessBridgePath)
    Publish-ItlDatabaseRestorationDuty -Owner $duty.owner -Record $payload | Out-Null
    return $duty
}

function Get-OneCDatabaseRestorationDuty {
    param([Parameter(Mandatory = $true)][string]$SnapshotPath)
    $journalVariable = Get-Variable -Name OneCNativeOperationJournal -Scope Script -ErrorAction SilentlyContinue
    if ($null -eq $journalVariable -or $null -eq $journalVariable.Value -or -not $journalVariable.Value.PSObject.Properties['restorations']) { return $null }
    $path = [IO.Path]::GetFullPath($SnapshotPath)
    $matches = @($journalVariable.Value.restorations | Where-Object {
        $_.payload.kind -eq 'infobase-snapshot' -and $_.payload.status -eq 'pending' -and
        [string]::Equals($_.payload.snapshotPath,$path,[StringComparison]::OrdinalIgnoreCase)
    })
    if ($matches.Count -gt 1) { throw 'ONEC_RESTORATION_SNAPSHOT_OWNER_AMBIGUOUS' }
    if ($matches.Count -eq 1) { return $matches[0] }
    return $null
}

function Assert-OneCDatabaseRestoreRequest {
    param([Parameter(Mandatory = $true)][object]$Duty, [string]$InfoBaseKind, [string]$InfoBasePath, [string[]]$DesignerArgs)
    $payload = $Duty.payload
    if ($payload.kind -cne 'infobase-snapshot' -or $payload.status -cne 'pending' -or
        $InfoBaseKind -cne $payload.infoBase.kind -or
        -not (Test-ItlOnDemandInfoBaseMatch -First $InfoBasePath -Second $payload.infoBase.path) -or
        $DesignerArgs.Count -ne 2 -or $DesignerArgs[0] -ine '/RestoreIB' -or
        -not [string]::Equals([IO.Path]::GetFullPath($DesignerArgs[1]),$payload.snapshotPath,[StringComparison]::OrdinalIgnoreCase)) {
        throw 'ONEC_RESTORATION_NATIVE_INPUT_CHANGED'
    }
    $payload.restoreOperation = ''
    $payload.updatedAt = [DateTime]::UtcNow.ToString('o')
    . (Get-OneCDatabaseAccessBridgePath)
    # Revalidates the pinned DT bytes before the native restore starts.
    Publish-ItlDatabaseRestorationDuty -Owner $Duty.owner -Record $payload | Out-Null
}

function Set-OneCDatabaseRestoreEvidence {
    param([Parameter(Mandatory = $true)][object]$Duty, [AllowNull()][object]$NativeRecord)
    if ($null -eq $NativeRecord -or $null -eq $NativeRecord.persistence -or -not $NativeRecord.quiescenceConfirmed -or
        $NativeRecord.purpose -cne ('designer-restore-snapshot-' + $Duty.payload.id)) {
        throw 'ONEC_RESTORATION_NATIVE_RESTORE_UNPROVEN'
    }
    $Duty.payload.restoreOperation = $NativeRecord.persistence.journalId + '/' + $NativeRecord.id
    $Duty.payload.updatedAt = [DateTime]::UtcNow.ToString('o')
    . (Get-OneCDatabaseAccessBridgePath)
    Publish-ItlDatabaseRestorationDuty -Owner $Duty.owner -Record $Duty.payload | Out-Null
}

function Complete-OneCDatabaseRestorationDuty {
    param([AllowNull()][object]$Duty, [ValidateSet('restored','committed')][string]$Resolution = 'restored')
    if ($null -eq $Duty) { return }
    $Duty.payload.status = $Resolution
    $Duty.payload.updatedAt = [DateTime]::UtcNow.ToString('o')
    try {
        . (Get-OneCDatabaseAccessBridgePath)
        Publish-ItlDatabaseRestorationDuty -Owner $Duty.owner -Record $Duty.payload | Out-Null
    } catch { $Duty.payload.status = 'pending'; throw }
}

function Assert-OneCNativeOperationJournalOwner {
    param([AllowNull()][object]$Journal)
    if ($null -eq $Journal -or $null -eq $Journal.owner) { return }
    . (Get-OneCDatabaseAccessBridgePath)
    Assert-ItlDatabaseAccessHost -Owner $Journal.owner
}

function Confirm-OneCNativeOperationRelease {
    param([AllowNull()][object]$Record, [bool]$LauncherExited, [bool]$OwnedProcessesReleased, [string]$Evidence)
    if ($null -eq $Record) { return }
    $Record.launcherExited = $LauncherExited
    # Never infer descendant release from launcher exit or an absent PID.
    # The caller must supply its operation-specific owned-process proof.
    $Record.quiescenceConfirmed = [bool]($Record.startAttempted -and $LauncherExited -and $OwnedProcessesReleased -and $Evidence)
    $Record.releaseEvidence = if ($Record.quiescenceConfirmed) { $Evidence } else { '' }
    Save-OneCNativeOperationRecord -Record $Record
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
    if ([string]::IsNullOrWhiteSpace((Get-SafeOneCProcessInfoBase -CommandLine $CommandLine))) {
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
        # A single-process reservation only bridges discovery of that process.
        # Its exited leader cannot occupy a slot merely because the launcher is
        # still alive. Promised child slots retain their existing owner lifetime.
        if (-not $leaderAlive -and [int](Get-StateValue -State $reservation -Name 'leaderPid' -Default 0) -gt 0 -and
            [int](Get-StateValue -State $reservation -Name 'requiredSessions' -Default 1) -eq 1 -and
            -not [string](Get-StateValue -State $reservation -Name 'expectedChildRole' -Default '')) { continue }

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

function Stop-OneCInfoBaseSessionProcesses {
    param(
        [Parameter(Mandatory = $true)][ValidateSet("file", "server")][string]$InfoBaseKind,
        [Parameter(Mandatory = $true)][string]$InfoBasePath,
        [string]$Reason = "managed infobase exclusive operation"
    )

    $candidates = @(Get-OneCProcessInfo -RequireSuccess | Where-Object {
        Test-OneCCommandLineInfoBasePath `
            -CommandLine ([string](Get-StateValue -State $_ -Name "commandLine" -Default "")) `
            -InfoBasePath $InfoBasePath `
            -InfoBaseKind $InfoBaseKind
    })
    $stopped = [System.Collections.Generic.List[int]]::new()
    foreach ($candidate in $candidates) {
        $processId = [int](Get-StateValue -State $candidate -Name "processId" -Default 0)
        $expectedStart = [string](Get-StateValue -State $candidate -Name "processStartTime" -Default "")
        $expectedExecutable = [string](Get-StateValue -State $candidate -Name "executablePath" -Default "")
        $current = @(Get-OneCProcessInfo -RequireSuccess | Where-Object { [int]$_.processId -eq $processId } | Select-Object -First 1)
        if ($current.Count -eq 0) { continue }

        $currentStart = [string](Get-StateValue -State $current[0] -Name "processStartTime" -Default "")
        $currentExecutable = [string](Get-StateValue -State $current[0] -Name "executablePath" -Default "")
        $currentCommandLine = [string](Get-StateValue -State $current[0] -Name "commandLine" -Default "")
        if (-not $expectedStart -or -not $currentStart -or $expectedStart -cne $currentStart) {
            throw "ITL_ONEC_SESSION_IDENTITY_MISMATCH: failedPredicate=processStartTime pid=$processId reason='$Reason'."
        }
        if (-not $expectedExecutable -or -not $currentExecutable -or -not [string]::Equals($expectedExecutable, $currentExecutable, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "ITL_ONEC_SESSION_IDENTITY_MISMATCH: failedPredicate=executablePath pid=$processId reason='$Reason'."
        }
        if (-not (Test-OneCCommandLineInfoBasePath -CommandLine $currentCommandLine -InfoBasePath $InfoBasePath -InfoBaseKind $InfoBaseKind)) {
            throw "ITL_ONEC_SESSION_IDENTITY_MISMATCH: failedPredicate=infoBasePath pid=$processId reason='$Reason'."
        }

        $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
        if ($null -eq $process) { continue }
        $expectedStartTime = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParse($expectedStart, [ref]$expectedStartTime)) {
            throw "ITL_ONEC_SESSION_IDENTITY_MISMATCH: failedPredicate=processStartTimeFormat pid=$processId reason='$Reason'."
        }
        try {
            $actualProcessStart = $process.StartTime.ToUniversalTime()
        } catch {
            throw "ITL_ONEC_SESSION_IDENTITY_MISMATCH: failedPredicate=processStartTimeInspection pid=$processId reason='$Reason'."
        }
        if ([Math]::Abs(($actualProcessStart - $expectedStartTime.UtcDateTime).TotalSeconds) -ge 2) {
            throw "ITL_ONEC_SESSION_IDENTITY_MISMATCH: failedPredicate=processStartTime pid=$processId reason='$Reason'."
        }
        $cleanup = Stop-NativeProcessForSafety -Process $process
        if (-not [bool]$cleanup.confirmed) {
            throw "ITL_ONEC_SESSION_STOP_FAILED: pid=$processId reason='$Reason' detail='$([string]$cleanup.error)'."
        }
        $stopped.Add($processId) | Out-Null
    }

    $remaining = @(Get-OneCInfoBaseSessionProcesses -InfoBaseKind $InfoBaseKind -InfoBasePath $InfoBasePath)
    if ($remaining.Count -gt 0) {
        throw "ITL_ONEC_SESSION_STOP_FAILED: exact dev infobase still has local sessions after '$Reason': $(@($remaining.pid) -join ',')."
    }
    return [pscustomobject][ordered]@{
        stopped = $stopped.Count
        processIds = @($stopped)
    }
}

function New-OneCSessionCapacityError {
    param([string]$Message, [switch]$Waitable)
    $error = [InvalidOperationException]::new($Message)
    $error.Data['ItlSessionCapacityBeforeLaunch'] = $true
    $error.Data['ItlSessionCapacityWaitable'] = [bool]$Waitable
    return $error
}

function Get-OneCSessionWaitParameters {
    param([ValidateRange(0, 86400)][double]$DefaultTimeoutSeconds = 300,
          [string]$ContextPath = $env:ITL_PERFORMANCE_CONTEXT)
    $options = @{ SessionWaitTimeoutSeconds=$DefaultTimeoutSeconds; SessionCancelPath=''; SessionDeadlineMonotonicNs=[long]0 }
    if ($ContextPath) {
        $context = Read-Utf8Text -Path $ContextPath | ConvertFrom-Json
        $options.SessionCancelPath = [string](Get-StateValue -State $context -Name 'cancelPath' -Default '')
        $phase = Get-StateValue -State $context -Name 'phase' -Default $null
        if ($null -ne $phase) {
            $timeout = [double](Get-StateValue -State $phase -Name 'timeoutSeconds' -Default $DefaultTimeoutSeconds)
            if ([double]::IsNaN($timeout) -or [double]::IsInfinity($timeout) -or $timeout -le 0 -or $timeout -gt 86400) {
                throw 'INVALID_PHASE_DEADLINE'
            }
            $options.SessionWaitTimeoutSeconds = if ($PSBoundParameters.ContainsKey('DefaultTimeoutSeconds')) { [math]::Min($DefaultTimeoutSeconds, $timeout) } else { $timeout }
            $deadline = [long](Get-StateValue -State $phase -Name 'deadlineMonotonicNs' -Default 0)
            if ($deadline -gt 0) {
                if (-not [string]::Equals([string](Get-StateValue -State $phase -Name 'executionHost' -Default ''), [Environment]::MachineName, [StringComparison]::OrdinalIgnoreCase)) {
                    throw 'FOREIGN_PHASE_DEADLINE_HOST'
                }
                # Python's Windows monotonic clock and Stopwatch both use QPC.
                $options.SessionDeadlineMonotonicNs = $deadline
            }
        }
    }
    return $options
}

function Test-OneCSessionWaitExpired {
    param([object]$Context, [Diagnostics.Stopwatch]$Watch)
    if ($Context.sessionDeadlineMonotonicNs -gt 0) {
        $now = [decimal][Diagnostics.Stopwatch]::GetTimestamp() * 1000000000 / [Diagnostics.Stopwatch]::Frequency
        if ($now -ge $Context.sessionDeadlineMonotonicNs) { return $true }
    }
    return ($Context.sessionWaitTimeoutSeconds -gt 0 -and $Watch.Elapsed.TotalSeconds -ge $Context.sessionWaitTimeoutSeconds)
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
            throw (New-OneCSessionCapacityError -Message "ITL_ONEC_SESSION_LIMIT: max=$maximum active=0 reserved=0 required=$required infobase='$($identity.value)' purpose=$purpose errorCategory=session-capacity requiredAction=finish-or-close-owned-sessions-before-retry retryAction=repeat-original-command-after-session-count-changes limitChange=developer-only")
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
                throw (New-OneCSessionCapacityError -Waitable -Message "ITL_ONEC_SESSION_LIMIT: max=$maximum active=$active reserved=$reserved required=$($admission.requiredSessions) infobase='$($identity.value)' purpose=$($admission.purpose) processes=$processDetails reservations=$reservationDetails errorCategory=session-capacity requiredAction=finish-or-close-owned-sessions-before-retry retryAction=repeat-original-command-after-session-count-changes limitChange=developer-only")
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
    $waitWatch = [Diagnostics.Stopwatch]::StartNew()
    $waitSeconds = [double]$context.sessionWaitTimeoutSeconds
    $nextNotice = 0.0
    $requestedStartProcess = $StartProcess
    while ($true) {
        if ($context.sessionCancelPath -and (Test-Path -LiteralPath $context.sessionCancelPath)) { throw 'CANCELLED' }
        try {
            return (Invoke-OneCSessionAdmissionSet -Admissions @($context.admissions) -StartProcess {
                if ($context.sessionCancelPath -and (Test-Path -LiteralPath $context.sessionCancelPath)) { throw 'CANCELLED' }
                if (Test-OneCSessionWaitExpired -Context $context -Watch $waitWatch) { throw 'ITL_ONEC_SESSION_WAIT_TIMEOUT: admission expired before launch' }
                Assert-OneCNativeOperationJournalOwner -Journal $context.nativeOperationJournal
                if ($null -ne $context.nativeOperationRecord) {
                    foreach ($scope in $context.nativeOperationRecord.ownedProcessScopes) {
                        if ($scope.role -eq 'native-invocation') { continue }
                        $currentHash = (Get-FileHash -LiteralPath $scope.runParamsPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
                        if ($currentHash -cne $scope.runParamsSha256) { throw 'ONEC_NATIVE_RUN_PARAMETERS_CHANGED_BEFORE_LAUNCH' }
                    }
                }
                if ($null -ne $context.nativeOperationRecord) {
                    $context.nativeOperationRecord.startAttempted = $true
                    try { Save-OneCNativeOperationRecord -Record $context.nativeOperationRecord }
                    catch { $context.nativeOperationRecord.startAttempted = $false; throw }
                }
                $context.nativeStartAttempted = $true
                $startedProcess = & $requestedStartProcess
                if ($null -ne $context.nativeOperationRecord -and $null -ne $startedProcess) {
                    $context.nativeOperationRecord.process = $startedProcess
                    $context.nativeOperationRecord.processId = [int]$startedProcess.Id
                    Save-OneCNativeOperationRecord -Record $context.nativeOperationRecord
                }
                return $startedProcess
            })
        } catch {
            # Retry admission only when no process start was attempted. A
            # native launcher failure never authorizes replay, even if it has
            # the same message or exception data as a capacity rejection.
            $beforeLaunch = -not $context.nativeStartAttempted -and [bool]$_.Exception.Data['ItlSessionCapacityBeforeLaunch']
            if ($beforeLaunch -and $waitSeconds -gt 0 -and [bool]$_.Exception.Data['ItlSessionCapacityWaitable']) {
                if (Test-OneCSessionWaitExpired -Context $context -Watch $waitWatch) { throw }
                if ($waitWatch.Elapsed.TotalSeconds -ge $nextNotice) {
                    Write-Host "ITL_ONEC_SESSION_WAIT: elapsed=$([math]::Round($waitWatch.Elapsed.TotalSeconds, 1))s; $($_.Exception.Message)"
                    $nextNotice = $waitWatch.Elapsed.TotalSeconds + 5
                }
                Start-Sleep -Milliseconds 100
                continue
            }
            if (-not $beforeLaunch -or $waitSeconds -gt 0 -or $null -eq $context.sessionLimitRecovery -or [bool]$context.recoveryAttempted) { throw }
            $context.recoveryAttempted = $true
            & $context.sessionLimitRecovery
        }
    }
}

function Invoke-WithOneCSessionAdmissionContext {
    param(
        [Parameter(Mandatory = $true)][ValidateSet("file", "server")][string]$InfoBaseKind,
        [Parameter(Mandatory = $true)][string]$InfoBasePath,
        [ValidateRange(1, 64)][int]$RequiredSessions = 1,
        [ValidateSet("", "test-client")][string]$ExpectedChildRole = "",
        [string]$Purpose = "1c-process",
        [object[]]$AdditionalAdmissions = @(),
        [scriptblock]$SessionLimitRecovery = $null,
        [ValidateRange(0, 86400)][double]$SessionWaitTimeoutSeconds = 0,
        [string]$SessionCancelPath = '',
        [long]$SessionDeadlineMonotonicNs = 0,
        [switch]$KeepReservation,
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock
    )

    $previous = $script:OneCSessionLaunchContext
    if ($SessionWaitTimeoutSeconds -gt 0 -and $null -ne $SessionLimitRecovery) {
        throw 'ITL_ONEC_SESSION_ADMISSION_INVALID: waiting cannot invoke destructive capacity recovery'
    }
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
        sessionLimitRecovery = $SessionLimitRecovery
        recoveryAttempted = $false
        nativeStartAttempted = $false
        nativeOperationRecord = (Add-OneCNativeOperationRecord -Journal $script:OneCNativeOperationJournal -Admissions $admissions -Purpose $Purpose)
        nativeOperationJournal = $script:OneCNativeOperationJournal
        sessionWaitTimeoutSeconds = $SessionWaitTimeoutSeconds
        sessionCancelPath = $SessionCancelPath
        sessionDeadlineMonotonicNs = $SessionDeadlineMonotonicNs
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
        [scriptblock]$SessionLimitRecovery = $null,
        [ValidateRange(0, 86400)][double]$SessionWaitTimeoutSeconds = 0,
        [string]$SessionCancelPath = '',
        [long]$SessionDeadlineMonotonicNs = 0,
        [switch]$Visible
    )

    return (Invoke-WithOneCSessionAdmissionContext `
        -InfoBaseKind $InfoBaseKind `
        -InfoBasePath $InfoBasePath `
        -RequiredSessions $RequiredSessions `
        -ExpectedChildRole $ExpectedChildRole `
        -Purpose $Purpose `
        -SessionLimitRecovery $SessionLimitRecovery `
        -SessionWaitTimeoutSeconds $SessionWaitTimeoutSeconds `
        -SessionCancelPath $SessionCancelPath `
        -SessionDeadlineMonotonicNs $SessionDeadlineMonotonicNs `
        -KeepReservation `
        -ScriptBlock {
            Start-NativeProcessBackground -FilePath $FilePath -Arguments $Arguments -Visible:$Visible
        })
}

function Test-OneCCommandLineOutputBelongsToRun {
    param(
        [AllowNull()][string]$CommandLine,
        [AllowNull()][string]$RunParamsPath
    )

    if ([string]::IsNullOrWhiteSpace($CommandLine) -or [string]::IsNullOrWhiteSpace($RunParamsPath)) { return $false }
    $outputPath = Get-OneCCommandLineSwitchPath -CommandLine $CommandLine -SwitchNames @("Out")
    if ([string]::IsNullOrWhiteSpace($outputPath)) { return $false }
    try {
        $runDirectory = (Split-Path -Parent (Resolve-Agent1cFullPath -Path $RunParamsPath)).TrimEnd('\', '/')
        $resolvedOutputPath = Resolve-Agent1cFullPath -Path $outputPath
    } catch {
        return $false
    }
    $runPrefix = $runDirectory + [System.IO.Path]::DirectorySeparatorChar
    return $resolvedOutputPath.StartsWith($runPrefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-OneCCommandLineTestPort {
    param([AllowNull()][string]$CommandLine)

    if ([string]::IsNullOrWhiteSpace($CommandLine)) {
        return 0
    }

    $matches = [regex]::Matches(
        [string]$CommandLine,
        '(?i)(?:^|\s)-TPort(?=\s)\s+(?:"(?<quoted>\d+)"|(?<plain>\d+))(?=\s|$)'
    )
    if ($matches.Count -ne 1) {
        return 0
    }
    $match = $matches[0]
    $value = $(if ($match.Groups["quoted"].Success) { $match.Groups["quoted"].Value } else { $match.Groups["plain"].Value })
    $parsed = 0
    if ([int]::TryParse($value, [ref]$parsed)) { return $parsed }
    return 0
}

function Test-CommandLineContainsVaParamsPath {
    param(
        [AllowNull()][string]$CommandLine,
        [AllowNull()][string]$ParamsPath
    )

    if ([string]::IsNullOrWhiteSpace($CommandLine) -or [string]::IsNullOrWhiteSpace($ParamsPath)) {
        return $false
    }

    try {
        $expected = (Resolve-Agent1cFullPath -Path $ParamsPath).Replace('/', '\').ToLowerInvariant()
    } catch {
        return $false
    }
    $normalized = ([string]$CommandLine).Replace('/', '\').ToLowerInvariant()
    $marker = 'vaparams='
    $offset = 0
    while ($offset -lt $normalized.Length) {
        $index = $normalized.IndexOf($marker, $offset, [System.StringComparison]::Ordinal)
        if ($index -lt 0) { break }
        $valueStart = $index + $marker.Length
        if (($normalized.Length - $valueStart) -ge $expected.Length -and
            $normalized.Substring($valueStart, $expected.Length) -ceq $expected) {
            $valueEnd = $valueStart + $expected.Length
            if ($valueEnd -eq $normalized.Length -or @(';', '"', ' ', "`t") -contains [string]$normalized[$valueEnd]) {
                return $true
            }
        }
        $offset = $valueStart
    }
    return $false
}

function Get-OneCNativeRunProcessScopes {
    param(
        [Parameter(Mandatory = $true)][string]$RunParamsPath,
        [Parameter(Mandatory = $true)][object[]]$Resources
    )
    $paramsPath = Resolve-Agent1cFullPath -Path $RunParamsPath
    if ($Resources.Count -eq 0) { throw 'ONEC_NATIVE_RUN_RESOURCES_REQUIRED' }
    $paramsBytes = [IO.File]::ReadAllBytes($paramsPath)
    $paramsText = [Text.Encoding]::UTF8.GetString($paramsBytes).TrimStart([char]0xfeff)
    $settings = $paramsText | ConvertFrom-Json -ErrorAction Stop
    $clientSettings = $settings.PSObject.Properties['КлиентТестирования']
    $clientsProperty = if ($null -ne $clientSettings -and $null -ne $clientSettings.Value) { $clientSettings.Value.PSObject.Properties['ДанныеКлиентовТестирования'] } else { $null }
    $clients = @(if ($null -ne $clientsProperty) { $clientsProperty.Value })
    if ($clients.Count -eq 0) { throw 'ONEC_NATIVE_RUN_CLIENTS_REQUIRED' }
    $scopes = [Collections.Generic.List[object]]::new()
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { $hash = ([BitConverter]::ToString($hasher.ComputeHash($paramsBytes))).Replace('-', '').ToLowerInvariant() }
    finally { $hasher.Dispose() }
    $scopes.Add([pscustomobject]@{schemaVersion=1;role='test-manager';kind=$Resources[0].kind;path=$Resources[0].path;runParamsPath=$paramsPath;runParamsSha256=$hash;testPorts=@()})
    foreach ($client in $clients) {
        $connection = [string](Get-StateValue -State $client -Name 'ПутьКИнфобазе' -Default '')
        $port = 0
        if (-not [int]::TryParse([string](Get-StateValue -State $client -Name 'ПортЗапускаТестКлиента' -Default 0), [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
            throw 'ONEC_NATIVE_RUN_CLIENT_PORT_REQUIRED'
        }
        $uniqueTargets = @{}
        foreach ($resource in $Resources) {
            if (Test-OneCCommandLineInfoBasePath -CommandLine $connection -InfoBaseKind $resource.kind -InfoBasePath $resource.path) {
                $identity = Get-OneCInfoBaseIdentity -InfoBaseKind $resource.kind -InfoBasePath $resource.path
                $uniqueTargets[$identity.key] = $resource
            }
        }
        $targets = @($uniqueTargets.Values)
        if ($targets.Count -ne 1) { throw 'ONEC_NATIVE_RUN_CLIENT_TARGET_NOT_RESERVED' }
        $scopes.Add([pscustomobject]@{schemaVersion=1;role='test-client';kind=$targets[0].kind;path=$targets[0].path;runParamsPath=$paramsPath;runParamsSha256=$hash;testPorts=@($port)})
    }
    # Vanessa may relocate a profile to another port in this run's assigned set.
    # The original orphan used A's port with B's database and B's run-owned Out.
    $runPorts = @($scopes | Where-Object role -eq 'test-client' | ForEach-Object { $_.testPorts } | Sort-Object -Unique)
    foreach ($scope in $scopes) { if ($scope.role -eq 'test-client') { $scope.testPorts = $runPorts } }
    return @($scopes.ToArray())
}

function Add-OneCNativeInvocationScope {
    param([string]$FilePath, [string[]]$Arguments)
    $context = $script:OneCSessionLaunchContext
    if ($null -eq $context -or $null -eq $context.nativeOperationRecord -or
        [IO.Path]::GetFileName($FilePath) -notin @('1cv8.exe','1cv8c.exe') -or
        $Arguments.Count -eq 0 -or $Arguments[0] -notin @('DESIGNER','ENTERPRISE','CREATEINFOBASE')) { return }
    $indices = @(for ($i=0; $i -lt $Arguments.Count; $i++) { if ($Arguments[$i] -ieq '/Out') { $i } })
    if ($indices.Count -eq 0) { return }
    if ($indices.Count -ne 1 -or $indices[0]+1 -ge $Arguments.Count -or
        -not [IO.Path]::IsPathRooted($Arguments[$indices[0]+1])) { throw 'ONEC_NATIVE_INVOCATION_OUTPUT_AMBIGUOUS' }
    if (@($context.nativeOperationRecord.ownedProcessScopes | Where-Object role -eq 'native-invocation').Count) {
        throw 'ONEC_NATIVE_INVOCATION_SCOPE_ALREADY_CAPTURED'
    }
    $scope = [pscustomobject]@{schemaVersion=1;role='native-invocation';kind=$context.infoBaseKind;path=$context.infoBasePath
        mode=$Arguments[0].ToUpperInvariant();logPath=[IO.Path]::GetFullPath($Arguments[$indices[0]+1]);notBeforeUtc=[DateTime]::UtcNow.ToString('o')}
    $context.nativeOperationRecord.ownedProcessScopes = @($context.nativeOperationRecord.ownedProcessScopes) + @($scope)
}

function Test-OneCNativeInvocationProcess {
    param([object]$ProcessInfo, [object]$Scope)
    $commandLine = [string](Get-StateValue -State $ProcessInfo -Name 'CommandLine' -Default '')
    $mode = [regex]::Match($commandLine, '^\s*(?:"[^"]+"|\S+)\s+(DESIGNER|ENTERPRISE|CREATEINFOBASE)(?=\s|$)', 'IgnoreCase')
    if (-not $mode.Success -or $mode.Groups[1].Value -ine $Scope.mode -or
        -not (Test-OneCCommandLineInfoBasePath -CommandLine $commandLine -InfoBaseKind $Scope.kind -InfoBasePath $Scope.path)) { return $false }
    $output = Get-OneCCommandLineSwitchPath -CommandLine $commandLine -SwitchNames @('Out')
    if (-not $output -or -not [IO.Path]::IsPathRooted($output) -or
        -not [string]::Equals([IO.Path]::GetFullPath($output),$Scope.logPath,[StringComparison]::OrdinalIgnoreCase)) { return $false }
    $creation = Get-StateValue -State $ProcessInfo -Name 'CreationDate' -Default $null
    $observedStart = if ($null -ne $creation) { ([datetime]$creation).ToUniversalTime().ToString('o') } else {
        [string](Get-StateValue -State $ProcessInfo -Name 'processStartTime' -Default '')
    }
    $start = [DateTimeOffset]::MinValue; $minimum = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse($observedStart,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$start) -or
        -not [DateTimeOffset]::TryParse($Scope.notBeforeUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$minimum)) {
        throw 'ONEC_NATIVE_INVOCATION_START_TIME_UNAVAILABLE'
    }
    return $start -ge $minimum
}

function Test-OneCNativeProcessInRunScopes {
    param([object]$ProcessInfo, [object[]]$Scopes = @())
    $name = [string](Get-StateValue -State $ProcessInfo -Name 'Name' -Default '')
    if ($name -notin @('1cv8.exe','1cv8c.exe')) { return $false }
    $commandLine = [string](Get-StateValue -State $ProcessInfo -Name 'CommandLine' -Default '')
    foreach ($scope in $Scopes) {
        if ($scope.schemaVersion -eq 1 -and $scope.role -eq 'native-invocation') {
            if (Test-OneCNativeInvocationProcess -ProcessInfo $ProcessInfo -Scope $scope) { return $true }
            continue
        }
        if ($scope.schemaVersion -ne 1 -or $scope.role -notin @('test-client','test-manager')) { throw 'ONEC_NATIVE_RUN_SCOPE_INVALID' }
        if ((Get-OneCSessionProcessRole -CommandLine $commandLine) -ne $scope.role) { continue }
        if (-not (Test-OneCCommandLineInfoBasePath -CommandLine $commandLine -InfoBaseKind $scope.kind -InfoBasePath $scope.path)) { continue }
        if ($scope.role -eq 'test-client') {
            if (-not (Test-OneCCommandLineOutputBelongsToRun -CommandLine $commandLine -RunParamsPath $scope.runParamsPath)) { continue }
            $port = Get-OneCCommandLineTestPort -CommandLine $commandLine
            if ($port -gt 0 -and @($scope.testPorts) -contains $port) { return $true }
        } elseif (Test-CommandLineContainsVaParamsPath -CommandLine $commandLine -ParamsPath $scope.runParamsPath) { return $true }
    }
    return $false
}
