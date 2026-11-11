# Window helper for hidden agent TestClients: local build, group lifecycle, the file
# request channel, lease summaries and the window-helper actions. The helper source is
# assets/window-helper/ItlWindowHelper.cs; protocol.json is the shared contract.

$script:ItlWindowHelperAssetRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\assets\window-helper'))
$script:ItlWindowHelperProtocol = 1
$script:ItlWindowHelperOperations = @('lease', 'lease-end', 'capture-show', 'capture-end', 'adopt', 'status', 'show', 'hide')
$script:ItlWindowChannelCapability = 'itl-window-channel-1'
# Longest path the Vanessa patch writes below the group root:
# \requests\<uuid>.json.<uuid32>.tmp is written by the helper only; 1C writes
# \requests\<uuid>.json.tmp and reads \responses\<uuid>.json.
$script:ItlWindowChannelSuffixLength = 1 + 9 + 1 + 36 + 9

function Get-ItlWindowHelperCacheRoot {
    $override = [Environment]::GetEnvironmentVariable('ITL_WINDOW_HELPER_CACHE_ROOT')
    if (-not [string]::IsNullOrWhiteSpace($override)) { return [IO.Path]::GetFullPath($override.Trim()) }
    $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if ([string]::IsNullOrWhiteSpace($localAppData)) { throw 'ITL_WINDOW_HELPER_UNAVAILABLE: LOCALAPPDATA is not available for the helper build.' }
    return (Join-Path $localAppData 'itl\window-helper')
}

function Get-ItlWindowHelperCompilerPath {
    $framework = if ([Environment]::Is64BitOperatingSystem) { 'Framework64' } else { 'Framework' }
    return (Join-Path $env:WINDIR "Microsoft.NET\$framework\v4.0.30319\csc.exe")
}

function Get-ItlFileSha256 {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

# The build lands in a sibling temporary directory and is renamed into place; a
# concurrent build that loses the rename uses the winner's directory. csc output is
# not deterministic, so the executable hash is recorded after the build and checked
# before each start.
function Build-ItlWindowHelper {
    param([Parameter(Mandatory = $true)][string]$Source, [Parameter(Mandatory = $true)][string]$Target)
    $compiler = Get-ItlWindowHelperCompilerPath
    if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) { throw "ITL_WINDOW_HELPER_UNAVAILABLE: .NET Framework compiler was not found: $compiler" }
    $parent = Split-Path -Parent $Target
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $temp = Join-Path $parent ('build-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $temp | Out-Null
    try {
        $exe = Join-Path $temp 'itl-window-helper.exe'
        $capture = Invoke-ItlNativeProcessCapture -FilePath $compiler -WorkingDirectory $temp -TimeoutSeconds 120 -Arguments @(
            '/nologo', '/utf8output', '/codepage:65001', '/target:winexe', '/optimize+', '/warn:4', '/warnaserror+', '/langversion:5',
            '/r:System.Windows.Forms.dll', '/r:System.Drawing.dll', '/r:System.Web.Extensions.dll', "/out:$exe", $Source)
        if ([int]$capture.exitCode -ne 0 -or -not (Test-Path -LiteralPath $exe -PathType Leaf)) {
            $detail = (([string]$capture.stdout + ' ' + [string]$capture.stderr).Trim() -replace '\s+', ' ')
            if ($detail.Length -gt 400) { $detail = $detail.Substring(0, 400) }
            throw "ITL_WINDOW_HELPER_UNAVAILABLE: helper build failed (exit $($capture.exitCode)): $detail"
        }
        Write-Utf8Text -Path "$exe.sha256" -Value (Get-ItlFileSha256 -Path $exe)
        try {
            [IO.Directory]::Move($temp, $Target)
        } catch {
            if (-not (Test-Path -LiteralPath (Join-Path $Target 'itl-window-helper.exe') -PathType Leaf)) { throw }
        }
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Get-ItlWindowHelperExecutable {
    $source = Join-Path $script:ItlWindowHelperAssetRoot 'ItlWindowHelper.cs'
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "ITL_WINDOW_HELPER_UNAVAILABLE: helper source is missing: $source" }
    $target = Join-Path (Get-ItlWindowHelperCacheRoot) (Get-ItlFileSha256 -Path $source)
    $exe = Join-Path $target 'itl-window-helper.exe'
    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        if ((Test-Path -LiteralPath $exe -PathType Leaf) -and (Test-Path -LiteralPath "$exe.sha256" -PathType Leaf)) {
            $recorded = ([string](Read-Utf8Text -Path "$exe.sha256")).Trim()
            if ($recorded -ceq (Get-ItlFileSha256 -Path $exe)) { return $exe }
        }
        if ($attempt -gt 0) { break }
        # A replaced or partial executable is rebuilt once.
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue }
        Build-ItlWindowHelper -Source $source -Target $target
    }
    throw "ITL_WINDOW_HELPER_UNAVAILABLE: helper executable hash does not match its build record after one rebuild: $exe"
}

function Test-ItlAgentChannelRootFits {
    # The 1C file API is limited to MAX_PATH; one check serves every channel root.
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][int]$SuffixLength)
    try { $full = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/') } catch { return $false }
    return (($full.Length + $SuffixLength) -le 259)
}

function Invoke-ItlWindowHelperVerb {
    param([Parameter(Mandatory = $true)][string]$Executable, [Parameter(Mandatory = $true)][string[]]$Arguments)
    $capture = Invoke-ItlNativeProcessCapture -FilePath $Executable -Arguments $Arguments -WorkingDirectory (Split-Path -Parent $Executable) -TimeoutSeconds 20
    return [int]$capture.exitCode
}

function Get-ItlWindowHelperGroupConfig {
    param([string]$Directory)
    $path = Join-Path $Directory 'group.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try { return ((Read-Utf8Text -Path $path).TrimStart([char]0xFEFF) | ConvertFrom-Json) } catch { return $null }
}

function Test-ItlWindowHelperLockHeld {
    param([string]$Directory)
    $path = Join-Path $Directory 'helper.lock'
    try {
        $stream = [IO.File]::Open($path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $stream.Dispose()
        return $false
    } catch [IO.IOException] {
        return $true
    } catch [UnauthorizedAccessException] {
        return $true
    }
}

# One request through the group file channel. A missing reply within three seconds
# restarts the helper once (a hung one is replaced) and repeats the request; the
# fresh helper has until the request deadline to take it, since a start under load is slow.
function Send-ItlWindowHelperRequest {
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][ValidateSet('lease', 'lease-end', 'capture-show', 'capture-end', 'adopt', 'status', 'show', 'hide')][string]$Operation,
        [System.Collections.IDictionary]$Fields = @{},
        [DateTime]$DeadlineUtc = [DateTime]::UtcNow.AddSeconds(30),
        [int]$AckTimeoutMilliseconds = 3000,
        [string]$Executable = ''
    )
    $requests = Join-Path $Directory 'requests'
    $responses = Join-Path $Directory 'responses'
    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        New-Item -ItemType Directory -Force -Path $requests, $responses | Out-Null
        $id = [guid]::NewGuid().ToString()
        $body = [ordered]@{ protocol = $script:ItlWindowHelperProtocol; op = $Operation; id = $id; scope = ''; deadlineUtc = $DeadlineUtc.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ') }
        foreach ($key in $Fields.Keys) { $body[[string]$key] = $Fields[$key] }
        $requestPath = Join-Path $requests "$id.json"
        Write-Utf8Text -Path "$requestPath.tmp" -Value ($body | ConvertTo-Json -Depth 5 -Compress)
        Move-Item -LiteralPath "$requestPath.tmp" -Destination $requestPath -Force
        $responsePath = Join-Path $responses "$id.json"
        $ackPath = Join-Path $responses "$id.ack"
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $ackLimit = $AckTimeoutMilliseconds
        if ($attempt -gt 0) { $ackLimit = [Math]::Max($AckTimeoutMilliseconds, ($DeadlineUtc.ToUniversalTime() - [DateTime]::UtcNow).TotalMilliseconds) }
        $finalLimit = [Math]::Max($AckTimeoutMilliseconds, ($DeadlineUtc.ToUniversalTime() - [DateTime]::UtcNow).TotalMilliseconds + 5000)
        $lastLiveness = 0
        while ($true) {
            if (Test-Path -LiteralPath $responsePath -PathType Leaf) {
                $response = $null
                try { $response = (Read-Utf8Text -Path $responsePath).TrimStart([char]0xFEFF) | ConvertFrom-Json } catch { Start-Sleep -Milliseconds 20; continue }
                Remove-Item -LiteralPath $responsePath, $ackPath -Force -ErrorAction SilentlyContinue
                if ([string]$response.status -ceq 'protocol-mismatch') { return $null }
                return $response
            }
            $acked = Test-Path -LiteralPath $ackPath -PathType Leaf
            if (-not $acked -and $watch.ElapsedMilliseconds -ge $ackLimit) { break }
            if ($acked -and $watch.ElapsedMilliseconds -ge $finalLimit) { break }
            if ($acked -and $watch.ElapsedMilliseconds - $lastLiveness -ge 1000) {
                $lastLiveness = $watch.ElapsedMilliseconds
                if (-not (Test-ItlWindowHelperLockHeld -Directory $Directory)) { break }
            }
            Start-Sleep -Milliseconds 25
        }
        Remove-Item -LiteralPath $requestPath, $ackPath -Force -ErrorAction SilentlyContinue
        if ($attempt -gt 0) { break }
        try {
            $exe = if ($Executable) { $Executable } else { Get-ItlWindowHelperExecutable }
            $verb = @('ensure', $Directory)
            if (Test-ItlWindowHelperLockHeld -Directory $Directory) { $verb += '--hung' }
            if ((Invoke-ItlWindowHelperVerb -Executable $exe -Arguments $verb) -ne 0) { return $null }
        } catch {
            return $null
        }
    }
    return $null
}

function Test-ItlVanessaWindowChannelCapability {
    # A Vanessa revision without the window channel keeps its TestClients visible.
    param([AllowNull()][object]$VanessaEntry)
    if ($null -eq $VanessaEntry) {
        try { $VanessaEntry = Get-WorkflowDependencyEntry -Name 'vanessaAutomation' } catch { $VanessaEntry = $null }
    }
    $capabilities = @(Get-ConfigValueFromObject -Object $VanessaEntry -Path 'capabilities' -Default @())
    return ($capabilities -contains $script:ItlWindowChannelCapability)
}

function Write-ItlWindowHelperUnavailable {
    param([string]$Reason)
    Write-Host "[WARN] ITL_WINDOW_HELPER_UNAVAILABLE: $Reason. The TestClient starts visible and the run continues; ONEC_WINDOW_MODE=visible keeps this behavior without the warning."
}

# Prepares a helper group before a TestClient starts. A visible result never blocks the
# run: the client starts visible as in ONEC_WINDOW_MODE=visible and the caller reports
# the warning in its output and summary.
function Start-ItlWindowHelperGroup {
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [ValidateSet('runner', 'vanessa-ui')][string]$Owner = 'runner',
        [int[]]$Roots = @(),
        [AllowNull()][object]$VanessaEntry = $null
    )
    $mode = Get-OneCWindowMode
    $fullDirectory = $Directory
    try { $fullDirectory = [IO.Path]::GetFullPath($Directory) } catch { }
    $result = [pscustomobject]@{ ready = $false; directory = $fullDirectory; mode = $mode; reason = ''; warning = '' }
    if ($mode -ne 'hidden') { $result.reason = 'mode-visible'; return $result }
    $unavailable = {
        param($reason)
        $result.reason = $reason
        $result.warning = "ITL_WINDOW_HELPER_UNAVAILABLE: $reason"
        Write-ItlWindowHelperUnavailable -Reason $reason
        return $result
    }
    if (-not (Test-ItlVanessaWindowChannelCapability -VanessaEntry $VanessaEntry)) { return (& $unavailable 'vanessa-revision-without-window-channel') }
    if (-not (Test-ItlAgentChannelRootFits -Root $result.directory -SuffixLength $script:ItlWindowChannelSuffixLength)) { return (& $unavailable "max-path: group directory '$($result.directory)' is too long for the 1C file API") }
    try {
        $exe = Get-ItlWindowHelperExecutable
        New-Item -ItemType Directory -Force -Path $result.directory | Out-Null
        $config = [ordered]@{
            protocol = $script:ItlWindowHelperProtocol
            mode = $mode
            owner = $Owner
            countdownSeconds = Get-OneCUiLeaseCountdownSeconds
            pauseLimitSeconds = Get-OneCUiLeasePauseLimitSeconds
            roots = @($Roots | Where-Object { $_ -gt 0 })
            # The Vanessa patch restarts a missing or hung helper with this executable.
            executable = $exe
            createdUtc = [DateTime]::UtcNow.ToString('o')
        }
        Write-Utf8TextAtomic -Path (Join-Path $result.directory 'group.json') -Value ($config | ConvertTo-Json -Depth 4)
        $exitCode = Invoke-ItlWindowHelperVerb -Executable $exe -Arguments @('ensure', $result.directory)
        if ($exitCode -ne 0) { return (& $unavailable "helper did not start (ensure exit $exitCode)") }
        $status = Send-ItlWindowHelperRequest -Directory $result.directory -Operation status -Executable $exe -DeadlineUtc ([DateTime]::UtcNow.AddSeconds(3))
        if ($null -eq $status -or [string]$status.status -cne 'ok') { return (& $unavailable 'helper did not answer status within 3 seconds') }
        $result | Add-Member -NotePropertyName executable -NotePropertyValue $exe
        $result.ready = $true
        return $result
    } catch {
        $message = [string]$_.Exception.Message
        return (& $unavailable ($message -replace '^ITL_WINDOW_HELPER_UNAVAILABLE:\s*', ''))
    }
}

function Add-ItlWindowHelperRoot {
    param([AllowNull()][object]$Group, [int]$ProcessId)
    if ($null -eq $Group -or -not $Group.ready -or $ProcessId -le 0) { return $false }
    $response = Send-ItlWindowHelperRequest -Directory $Group.directory -Operation adopt -Fields @{ pid = $ProcessId } -DeadlineUtc ([DateTime]::UtcNow.AddSeconds(5))
    return ($null -ne $response -and [string]$response.status -ceq 'ok')
}

function Read-ItlWindowHelperJournal {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    $entries = @()
    foreach ($line in [IO.File]::ReadAllLines($Path, [Text.UTF8Encoding]::new($false))) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $entries += ($line | ConvertFrom-Json) } catch { }
    }
    return $entries
}

function Get-ItlWindowHelperLeaseSummary {
    param([AllowNull()][object]$Group)
    $summary = [ordered]@{ mode = 'visible'; modeSource = (Get-OneCWindowModeSource); leases = 0; leaseMs = [int64]0; consentWaitMs = [int64]0; queueWaitMs = [int64]0; declined = 0; warning = '' }
    if ($null -eq $Group) { return [pscustomobject]$summary }
    $summary.mode = if ($Group.ready) { 'hidden' } else { [string]$Group.mode }
    $summary.warning = [string]$Group.warning
    if (-not $Group.ready) { return [pscustomobject]$summary }
    foreach ($entry in (Read-ItlWindowHelperJournal -Path (Join-Path $Group.directory 'journal\leases.jsonl'))) {
        $outcome = [string]$entry.outcome
        $summary.consentWaitMs += [int64]$entry.consentWaitMs
        $summary.queueWaitMs += [int64]$entry.queueWaitMs
        if ($outcome.StartsWith('declined:')) { $summary.declined++; continue }
        if ($outcome -ceq 'activation-failed') { continue }
        $summary.leases++
        $summary.leaseMs += [int64]$entry.durationMs
    }
    return [pscustomobject]$summary
}

function Format-ItlWindowHelperLeaseSummary {
    param([object]$Summary)
    $line = 'Agent UI control: mode={0} modeSource={6} leases={1} leaseSeconds={2:0.0} consentWaitSeconds={3:0.0} queueWaitSeconds={4:0.0} declined={5}' -f
        $Summary.mode, $Summary.leases, ($Summary.leaseMs / 1000.0), ($Summary.consentWaitMs / 1000.0), ($Summary.queueWaitMs / 1000.0), $Summary.declined, $(if ($Summary.PSObject.Properties['modeSource']) { $Summary.modeSource } else { 'project' })
    if ($Summary.warning) { $line += " warning=$($Summary.warning)" }
    return ($line -replace ',', '.')
}

function Get-ItlWindowHelperHiddenTail {
    param([AllowNull()][object]$Group, [int]$Count = 5)
    if ($null -eq $Group -or -not $Group.ready) { return @() }
    $hidden = @(Read-ItlWindowHelperJournal -Path (Join-Path $Group.directory 'journal\hidden.jsonl') | Where-Object { [string]$_.event -ceq 'hidden' -and [string]$_.title -ne '' })
    return @($hidden | Select-Object -Last $Count)
}

function Write-ItlWindowHelperFailureDiagnostics {
    param([AllowNull()][object]$Group)
    foreach ($entry in (Get-ItlWindowHelperHiddenTail -Group $Group -Count 5)) {
        Write-Host "Hidden TestClient window: t=$($entry.t) title='$($entry.title)' class=$($entry.class) image='$($entry.image)'"
    }
}

# ------------------------------------------------------------------ actions
function Get-ItlWindowHelperProcesses {
    $sessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
    $items = @()
    foreach ($process in @(Get-CimInstance -ClassName Win32_Process -Filter "Name='itl-window-helper.exe'" -ErrorAction SilentlyContinue)) {
        if ([int]$process.SessionId -ne $sessionId) { continue }
        $match = [regex]::Match([string]$process.CommandLine, '(?i)\srun\s+"(?<dir>[^"]+)"')
        if (-not $match.Success) { continue }
        $items += [pscustomobject]@{ processId = [int]$process.ProcessId; directory = $match.Groups['dir'].Value; executable = [string]$process.ExecutablePath }
    }
    return $items
}

function Select-ItlWindowHelperGroups {
    param([switch]$All)
    $root = [IO.Path]::GetFullPath($script:ProjectRoot).TrimEnd('\') + '\'
    return @(Get-ItlWindowHelperProcesses | Where-Object { $All -or $_.directory.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) })
}

function Show-ItlWindowHelperStatus {
    param([switch]$All)
    $mode = Get-OneCWindowMode
    Write-Host "ONEC_WINDOW_MODE=$mode source=$(Get-OneCWindowModeSource) (applies to the next TestClient launch)."
    $groups = @(Select-ItlWindowHelperGroups -All:$All)
    if ($groups.Count -eq 0) { Write-Host 'No running window helper for this project.'; return }
    foreach ($group in $groups) {
        $config = Get-ItlWindowHelperGroupConfig -Directory $group.directory
        $status = Send-ItlWindowHelperRequest -Directory $group.directory -Operation status -Executable $group.executable -DeadlineUtc ([DateTime]::UtcNow.AddSeconds(3))
        $groupMode = if ($null -ne $config) { [string]$config.mode } else { 'unknown' }
        if ($null -eq $status) { Write-Host "Window helper PID $($group.processId): not answering; group='$($group.directory)' mode=$groupMode"; continue }
        $summary = Get-ItlWindowHelperLeaseSummary -Group ([pscustomobject]@{ ready = $true; directory = $group.directory; mode = $groupMode; warning = '' })
        Write-Host "Window helper PID $($status.helperPid): group='$($group.directory)' mode=$groupMode state=$($status.state) clients=$(@($status.clients).Count) members=$($status.members)"
        $revealed = @(if ($status.PSObject.Properties['revealed']) { $status.revealed })
        if ($revealed.Count -gt 0) { Write-Host "  Shown on request (window-hide returns hiding): $($revealed -join ', ')" }
        Write-Host "  $(Format-ItlWindowHelperLeaseSummary -Summary $summary)"
    }
}

# Shows or hides a TestClient of one of this project's helper groups on the agent's
# request. Showing neither activates the client nor grants OS input: input still
# needs a consented lease. A process outside the groups is refused untouched.
function Set-ItlWindowHelperClientVisibility {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('show', 'hide')][string]$Operation,
        [int]$ProcessId = 0,
        [int]$Port = 0
    )
    if ($ProcessId -le 0 -and $Port -le 0) {
        throw "ITL_WINDOW_TARGET_REQUIRED: window-$Operation needs -ProcessId or -Port of a TestClient. window-helper-status lists the clients."
    }
    $target = $null
    foreach ($group in @(Select-ItlWindowHelperGroups)) {
        $fields = @{}
        if ($Port -gt 0) { $fields.port = $Port }
        $status = Send-ItlWindowHelperRequest -Directory $group.directory -Operation status -Fields $fields -Executable $group.executable -DeadlineUtc ([DateTime]::UtcNow.AddSeconds(3))
        if ($null -eq $status) { continue }
        foreach ($client in @($status.clients)) {
            if (($ProcessId -le 0 -or [int]$client.pid -eq $ProcessId) -and ($Port -le 0 -or [int]$client.port -eq $Port)) {
                $target = [pscustomobject]@{ group = $group; pid = [int]$client.pid; port = [int]$client.port }
                break
            }
        }
        if ($null -ne $target) { break }
    }
    $what = if ($ProcessId -gt 0) { "PID $ProcessId" } else { "port $Port" }
    if ($null -eq $target) {
        if ((Get-OneCWindowMode) -eq 'visible') {
            if ($Operation -eq 'show') { Write-Host "TestClient windows are already visible: ONEC_WINDOW_MODE=visible, no window helper hides them."; return }
            throw "ITL_WINDOW_HIDE_UNAVAILABLE: ONEC_WINDOW_MODE=visible, so no window helper serves $what. Start the run or session with -WindowMode hidden to hide its TestClient."
        }
        throw "ITL_WINDOW_NOT_MEMBER: $what is not a TestClient of a window helper group of this project; its windows were not changed. window-helper-status lists the groups."
    }
    $response = Send-ItlWindowHelperRequest -Directory $target.group.directory -Operation $Operation -Fields @{ pid = $target.pid } -Executable $target.group.executable -DeadlineUtc ([DateTime]::UtcNow.AddSeconds(5))
    if ($null -eq $response) { throw "ITL_WINDOW_HELPER_UNAVAILABLE: the window helper of group '$($target.group.directory)' did not answer window-$Operation." }
    if ([string]$response.status -ne 'ok') { throw "ITL_WINDOW_NOT_MEMBER: the window helper refused window-$Operation for PID $($target.pid): $($response.code)." }
    if ($Operation -eq 'show') {
        Write-Host "TestClient PID $($target.pid) port $($target.port) shown below the active window without focus ($($response.shown) window(s)); window-hide -ProcessId $($target.pid) hides it again."
    } else {
        Write-Host "TestClient PID $($target.pid) port $($target.port) hidden; its new windows are hidden again."
    }
}

function Stop-ItlWindowHelper {
    param([switch]$All, [switch]$Restart)
    $showHidden = (Get-OneCWindowMode) -eq 'visible'
    $groups = @(Select-ItlWindowHelperGroups -All:$All)
    if ($groups.Count -eq 0) { Write-Host 'No running window helper to stop.'; return }
    foreach ($group in $groups) {
        $arguments = @('stop', $group.directory)
        if ($showHidden -and -not $Restart) { $arguments += '--show-hidden' }
        $code = Invoke-ItlWindowHelperVerb -Executable $group.executable -Arguments $arguments
        Write-Host "Window helper PID $($group.processId) stopped: exit=$code group='$($group.directory)'$(if ($showHidden -and -not $Restart) { ' (hidden main windows shown: ONEC_WINDOW_MODE=visible)' })"
        if ($Restart) {
            $code = Invoke-ItlWindowHelperVerb -Executable (Get-ItlWindowHelperExecutable) -Arguments @('ensure', $group.directory)
            Write-Host "Window helper restarted: exit=$code group='$($group.directory)'"
        }
    }
}
