if (-not (Get-Variable -Name ItlPortRegistryUserScopeWarningPrinted -Scope Script -ErrorAction SilentlyContinue)) {
    $script:ItlPortRegistryUserScopeWarningPrinted = $false
}

function New-ItlPortOwnershipDeadline {
    param([int]$BudgetMilliseconds = 3000)
    # One retry budget per caller operation, shared by all of its ports.
    return [DateTime]::UtcNow.AddMilliseconds([Math]::Max(0, $BudgetMilliseconds))
}

function ConvertTo-ItlTcpRowSummary {
    param([object]$Row)
    $rawState = if ($Row -is [Microsoft.Management.Infrastructure.CimInstance]) {
        $Row.CimInstanceProperties['State'].Value
    } else { Get-ItlPortObjectValue -Object $Row -Name State -Default '' }
    return [pscustomobject]@{
        state = [string]$rawState
        pid = [int](Get-ItlPortObjectValue -Object $Row -Name OwningProcess -Default 0)
        remotePort = [int](Get-ItlPortObjectValue -Object $Row -Name RemotePort -Default 0)
    }
}

function Get-ItlTcpConnectionProbe {
    param(
        [string]$Address = '127.0.0.1',
        [int]$Port,
        [int]$TimeoutMilliseconds = 500,
        [switch]$ResolveServerOwner
    )
    # Own connect probe. A refused Windows loopback connect may take about two
    # seconds, so a timeout alone never proves absence.
    $result = [ordered]@{ outcome = 'error'; localPort = 0; owners = @(); rows = @(); error = '' }
    $client = $null
    try {
        $ip = $null
        if (-not [Net.IPAddress]::TryParse($Address, [ref]$ip)) { $ip = @([Net.Dns]::GetHostAddresses($Address))[0] }
        $client = New-Object System.Net.Sockets.TcpClient ($ip.AddressFamily)
        $async = $client.BeginConnect($ip, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMilliseconds, $false)) {
            $result.outcome = 'timeout'
            return [pscustomobject]$result
        }
        try { $client.EndConnect($async) } catch {
            $socketError = $_.Exception
            while ($null -ne $socketError -and $socketError -isnot [Net.Sockets.SocketException]) { $socketError = $socketError.InnerException }
            if ($null -ne $socketError -and $socketError.SocketErrorCode -eq [Net.Sockets.SocketError]::ConnectionRefused) { $result.outcome = 'refused' }
            else { $result.error = $_.Exception.Message }
            return [pscustomobject]$result
        }
        $result.outcome = 'connected'
        $result.localPort = ([Net.IPEndPoint]$client.Client.LocalEndPoint).Port
        if ($ResolveServerOwner) {
            # The accepted (or backlog) server side of this exact connection is
            # owned by the listener process even when the listener row is hidden.
            $rows = @()
            try {
                $rows = @(Get-NetTCPConnection -LocalPort $Port -RemotePort $result.localPort -ErrorAction Stop |
                    Where-Object { [int](Get-ItlPortObjectValue -Object $_ -Name RemotePort -Default 0) -eq $result.localPort })
            } catch {
                $result.error = $(if ($_.CategoryInfo.Category -eq 'ObjectNotFound') { 'server-side-row-missing' } else { $_.Exception.Message })
            }
            $result.rows = @($rows | ForEach-Object { ConvertTo-ItlTcpRowSummary -Row $_ })
            $result.owners = @($result.rows | ForEach-Object { $_.pid } | Where-Object { $_ -gt 0 } | Sort-Object -Unique)
            if (-not $result.owners.Count -and -not $result.error) { $result.error = 'server-side-owner-missing' }
        }
        return [pscustomobject]$result
    } catch {
        $result.error = $_.Exception.Message
        return [pscustomobject]$result
    } finally {
        if ($null -ne $client) { $client.Close() }
    }
}

function Get-ItlTcpListenerOwnershipAttempt {
    param([int]$Port, [string]$Address, [int]$ConnectTimeoutMilliseconds, [string]$FallbackSource)
    $rows = @()
    $tableError = ''
    try { $rows = @(Get-NetTCPConnection -LocalPort $Port -ErrorAction Stop) } catch {
        if ($_.CategoryInfo.Category -ne 'ObjectNotFound') { $tableError = $_.Exception.Message }
    }
    $summaries = @($rows | ForEach-Object { ConvertTo-ItlTcpRowSummary -Row $_ })
    $attempt = [ordered]@{ status = 'unknown'; owners = @(); source = 'none'; rows = $summaries; connection = ''; error = $tableError }
    $listeners = @($summaries | Where-Object { $_.state -cin @('Listen','2') })
    # A row without a real owner PID (seen on some builds) proves nothing.
    if (-not $tableError -and $listeners.Count -and -not @($listeners | Where-Object { $_.pid -le 0 }).Count) {
        $attempt.status = 'proven'; $attempt.source = 'listen'
        $attempt.owners = @($listeners | ForEach-Object { $_.pid } | Sort-Object -Unique)
        return [pscustomobject]$attempt
    }
    # Some Windows builds report live listeners only with raw State=0.
    $candidates = @($summaries | Where-Object { $_.state -ceq '0' -and $_.remotePort -eq 0 })
    $probe = Get-ItlTcpConnectionProbe -Address $Address -Port $Port -TimeoutMilliseconds $ConnectTimeoutMilliseconds -ResolveServerOwner:($FallbackSource -eq 'connection' -and -not $tableError)
    $attempt.connection = [string]$probe.outcome
    if ($probe.localPort) { $attempt.connection += ":local=$($probe.localPort)" }
    if (@($probe.owners).Count) { $attempt.connection += ":pid=$(@($probe.owners) -join '+')" }
    if ($probe.error) { $attempt.error = (@($attempt.error, $probe.error) | Where-Object { $_ }) -join '; ' }
    if ($probe.outcome -eq 'refused' -or ($probe.outcome -eq 'timeout' -and -not $tableError -and -not $candidates.Count -and -not $listeners.Count)) {
        $attempt.status = 'absent'; $attempt.source = 'connection'
        return [pscustomobject]$attempt
    }
    if ($probe.outcome -ne 'connected' -or $tableError) { return [pscustomobject]$attempt }
    if ($FallbackSource -eq 'connection') {
        if (@($probe.owners).Count) { $attempt.status = 'proven'; $attempt.source = 'connection'; $attempt.owners = @($probe.owners) }
    } elseif ($candidates.Count -and -not @($candidates | Where-Object { $_.pid -le 0 }).Count) {
        # TestClient ports keep the previous State=0 source with a live probe.
        $attempt.status = 'proven'; $attempt.source = 'legacy-state0'
        $attempt.owners = @($candidates | ForEach-Object { $_.pid } | Sort-Object -Unique)
    }
    return [pscustomobject]$attempt
}

function Get-ItlTcpListenerOwnership {
    param(
        [int]$Port,
        [string]$Address = '127.0.0.1',
        [AllowNull()][Nullable[datetime]]$RetryUntil = $null,
        [int]$ConnectTimeoutMilliseconds = 500,
        [ValidateSet('connection','legacy-state0')][string]$FallbackSource = 'connection'
    )
    # Sole answer to "who listens on this port": proven | absent | unknown.
    # A table failure, or a connect timeout while listener evidence exists, is
    # unknown; callers never treat unknown as owned or as not owned.
    if ($Port -le 0) { return [pscustomobject]@{ status = 'absent'; owners = @(); source = 'none'; attempts = 0; elapsedMs = 0; diagnostic = 'status=absent port=0' } }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $attempts = 0
    $pauseMilliseconds = 250
    do {
        $attempts++
        $attempt = Get-ItlTcpListenerOwnershipAttempt -Port $Port -Address $Address -ConnectTimeoutMilliseconds $ConnectTimeoutMilliseconds -FallbackSource $FallbackSource
        if ($attempt.status -ne 'unknown' -or $null -eq $RetryUntil -or
            [DateTime]::UtcNow.AddMilliseconds($pauseMilliseconds) -ge ([datetime]$RetryUntil).ToUniversalTime()) { break }
        Start-Sleep -Milliseconds $pauseMilliseconds
    } while ($true)
    $watch.Stop()
    $rowText = (@($attempt.rows | Select-Object -First 6 | ForEach-Object { "$($_.state)/$($_.pid)/$($_.remotePort)" }) -join ',')
    if (@($attempt.rows).Count -gt 6) { $rowText += ",+$(@($attempt.rows).Count - 6)" }
    $diagnostic = "status=$($attempt.status) source=$($attempt.source) address=${Address}:$Port owners=$(@($attempt.owners) -join '+') rows(state/pid/remote)=[$rowText] connection=$($attempt.connection) attempts=$attempts elapsedMs=$($watch.ElapsedMilliseconds)"
    if ($attempt.error) { $diagnostic += " error=$($attempt.error)" }
    if ($diagnostic.Length -gt 600) { $diagnostic = $diagnostic.Substring(0, 597) + '...' }
    return [pscustomobject]@{
        status = [string]$attempt.status; owners = @($attempt.owners); source = [string]$attempt.source
        attempts = $attempts; elapsedMs = [int]$watch.ElapsedMilliseconds; diagnostic = $diagnostic
    }
}

function Get-ItlPortObjectValue {
    param(
        [AllowNull()][object]$Object,
        [string]$Name,
        [object]$Default = $null
    )

    if ($null -eq $Object -or [string]::IsNullOrWhiteSpace($Name)) {
        return $Default
    }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) {
            return $Object[$Name]
        }
        return $Default
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) {
        return $property.Value
    }
    return $Default
}

function ConvertTo-ItlPortInt {
    param(
        [AllowNull()][object]$Value,
        [int]$Default = 0
    )

    if ($null -eq $Value) {
        return $Default
    }

    $parsed = 0
    if ([int]::TryParse(([string]$Value).Trim(), [ref]$parsed)) {
        return $parsed
    }
    return $Default
}

function Get-ItlPortRegistryScope {
    $scope = [string](Get-EnvValue -Name "ITL_PORT_REGISTRY_SCOPE" -Default "machine")
    $scope = $scope.Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($scope)) {
        $scope = "machine"
    }
    if ($scope -ne "machine" -and $scope -ne "user") {
        throw "Invalid ITL_PORT_REGISTRY_SCOPE '$scope'. Use machine or user."
    }
    return $scope
}

function Get-ItlPortRegistryHome {
    $override = [string](Get-EnvValue -Name "ITL_PORT_REGISTRY_HOME" -Default "")
    if (-not [string]::IsNullOrWhiteSpace($override)) {
        return [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($override))
    }

    $scope = Get-ItlPortRegistryScope
    if ($scope -eq "machine") {
        $root = [Environment]::GetFolderPath("CommonApplicationData")
        if ([string]::IsNullOrWhiteSpace($root)) {
            $root = [Environment]::GetEnvironmentVariable("ProgramData", "Process")
        }
        if ([string]::IsNullOrWhiteSpace($root)) {
            throw "ITL machine port registry root could not be resolved. Set ITL_PORT_REGISTRY_HOME to a writable directory shared by all terminal server users."
        }
        return (Join-Path (Join-Path (Join-Path $root "ITL") "1c-agent-workflow") "port-registry")
    }

    $root = [Environment]::GetFolderPath("LocalApplicationData")
    if ([string]::IsNullOrWhiteSpace($root)) {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) "ITL"
    } else {
        $root = Join-Path $root "ITL"
    }
    return (Join-Path (Join-Path $root "1c-agent-workflow") "port-registry")
}

function Get-ItlPortRegistryPath {
    return (Join-Path (Get-ItlPortRegistryHome) "ports.json")
}

function Read-ItlPortRegistry {
    $path = Get-ItlPortRegistryPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{
            schemaVersion = 2
            allocations = @()
            updatedAt = ""
        }
    }

    try {
        return (Read-Utf8Text -Path $path | ConvertFrom-Json)
    } catch {
        throw "ITL port registry is not valid JSON: $path. $($_.Exception.Message)"
    }
}

function Write-ItlPortRegistry {
    param([object]$Registry)

    $hash = ConvertTo-Agent1cHashtable -Object $Registry
    $hash["schemaVersion"] = 2
    $hash["updatedAt"] = (Get-Date).ToString("o")
    Write-Utf8TextAtomic -Path (Get-ItlPortRegistryPath) -Value (($hash | ConvertTo-Json -Depth 12) + [Environment]::NewLine)
}

function Invoke-ItlPortRegistryLock {
    param([scriptblock]$ScriptBlock)

    $scope = Get-ItlPortRegistryScope
    $registryHome = Get-ItlPortRegistryHome
    try {
        New-Item -ItemType Directory -Force -Path $registryHome | Out-Null
    } catch {
        if ($scope -eq "machine") {
            throw "Cannot create ITL machine port registry directory: $registryHome. Set ITL_PORT_REGISTRY_HOME to a writable directory shared by all terminal server users, or set ITL_PORT_REGISTRY_SCOPE=user to accept user-local best-effort port isolation. $($_.Exception.Message)"
        }
        throw
    }

    if ($scope -eq "user" -and -not $script:ItlPortRegistryUserScopeWarningPrinted) {
        Write-Host "[WARN] ITL_PORT_REGISTRY_SCOPE=user gives only user-local port isolation; different Windows users can still race for the same port."
        $script:ItlPortRegistryUserScopeWarningPrinted = $true
    }

    $lockPath = Join-Path $registryHome "ports.lock"
    $stream = $null
    for ($attempt = 1; $attempt -le 50; $attempt++) {
        try {
            $stream = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            break
        } catch {
            Start-Sleep -Milliseconds 100
        }
    }

    if ($null -eq $stream) {
        if ($scope -eq "machine") {
            throw "Cannot acquire ITL machine port registry lock: $lockPath. Set ITL_PORT_REGISTRY_HOME to a writable directory shared by all terminal server users, or set ITL_PORT_REGISTRY_SCOPE=user to accept user-local best-effort port isolation."
        }
        throw "Cannot acquire ITL user port registry lock: $lockPath"
    }

    try {
        return (& $ScriptBlock)
    } finally {
        $stream.Close()
    }
}

function ConvertTo-ItlPortAllocationArray {
    param([AllowNull()][object]$Allocations)

    if ($null -eq $Allocations) {
        return @()
    }
    if ($Allocations -is [System.Array]) {
        return @($Allocations)
    }
    return @($Allocations)
}

function Get-ItlPortStaleGraceSeconds {
    return 300
}

function Get-ItlProcessStartedAt {
    param([int]$ProcessId)

    if ($ProcessId -le 0) {
        return ""
    }
    try {
        return (Get-Process -Id $ProcessId -ErrorAction Stop).StartTime.ToUniversalTime().ToString("o")
    } catch {
        return ""
    }
}

function Test-ItlPortAllocationOwnerIdentityPresent {
    param([object]$Allocation)

    $machine = [string](Get-ItlPortObjectValue -Object $Allocation -Name "machine" -Default "")
    if ($machine -and $machine -ne [Environment]::MachineName) {
        return $true
    }

    $processId = ConvertTo-ItlPortInt -Value (Get-ItlPortObjectValue -Object $Allocation -Name "pid" -Default 0)
    if ($processId -le 0) {
        return $false
    }

    $process = $null
    try {
        $process = Get-Process -Id $processId -ErrorAction Stop
    } catch {
        return $false
    }

    $expectedStartedAt = [string](Get-ItlPortObjectValue -Object $Allocation -Name "ownerProcessStartedAt" -Default "")
    if ([string]::IsNullOrWhiteSpace($expectedStartedAt)) {
        return $true
    }

    $expected = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse($expectedStartedAt, [ref]$expected)) {
        return $true
    }
    try {
        return ($process.StartTime.ToUniversalTime() -eq $expected.UtcDateTime)
    } catch {
        return $true
    }
}

function Test-ItlBranchPortAllocationStateAbsentOrClosed {
    param([object]$Allocation)

    $family = [string](Get-ItlPortObjectValue -Object $Allocation -Name "family" -Default "")
    if (@("vanessa-testclient", "vanessa-mcp", "roctup-mcp") -notcontains $family) {
        return $false
    }

    $projectRoot = [string](Get-ItlPortObjectValue -Object $Allocation -Name "projectRoot" -Default "")
    $safeName = [string](Get-ItlPortObjectValue -Object $Allocation -Name "safeDevBranchName" -Default "")
    if ([string]::IsNullOrWhiteSpace($projectRoot) -or [string]::IsNullOrWhiteSpace($safeName)) {
        return $false
    }

    $statePath = Join-Path (Join-Path $projectRoot ".agent-1c\dev-branches") ($safeName + ".json")
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf -ErrorAction SilentlyContinue)) {
        return $true
    }

    try {
        $state = Read-Utf8Text -Path $statePath | ConvertFrom-Json
        return -not [string]::IsNullOrWhiteSpace([string](Get-ItlPortObjectValue -Object $state -Name "closedAt" -Default ""))
    } catch {
        return $false
    }
}

function Test-ItlPortAllocationGraceExpired {
    param([object]$Allocation)

    $updatedAtText = [string](Get-ItlPortObjectValue -Object $Allocation -Name "updatedAt" -Default "")
    $updatedAt = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse($updatedAtText, [ref]$updatedAt)) {
        return $false
    }
    return ([DateTimeOffset]::UtcNow -ge $updatedAt.ToUniversalTime().AddSeconds((Get-ItlPortStaleGraceSeconds)))
}

function Test-ItlPortAllocationSafelyStale {
    param([object]$Allocation)

    if (-not (Test-ItlBranchPortAllocationStateAbsentOrClosed -Allocation $Allocation)) {
        return $false
    }
    if (Test-ItlPortAllocationOwnerIdentityPresent -Allocation $Allocation) {
        return $false
    }
    $port = ConvertTo-ItlPortInt -Value (Get-ItlPortObjectValue -Object $Allocation -Name "port" -Default 0)
    if ($port -le 0 -or -not (Test-ItlTcpPortAvailable -Port $port)) {
        return $false
    }
    return (Test-ItlPortAllocationGraceExpired -Allocation $Allocation)
}

function New-ItlManagedPortLeaseToken {
    return [guid]::NewGuid().ToString("N")
}

function Test-ItlPortAllocationMatchesStateIdentity {
    param(
        [object]$Allocation,
        [object]$State
    )

    if ($null -eq $State) {
        return $false
    }
    $stateProjectRoot = [string](Get-ItlPortObjectValue -Object $State -Name "stateProjectRoot" -Default $script:ProjectRoot)
    $worktreePath = [string](Get-ItlPortObjectValue -Object $State -Name "worktreePath" -Default $stateProjectRoot)
    $safeName = [string](Get-ItlPortObjectValue -Object $State -Name "safeDevBranchName" -Default "")
    $allocationRoot = [string](Get-ItlPortObjectValue -Object $Allocation -Name "projectRoot" -Default "")
    $allocationWorktree = [string](Get-ItlPortObjectValue -Object $Allocation -Name "worktreePath" -Default "")
    $allocationSafeName = [string](Get-ItlPortObjectValue -Object $Allocation -Name "safeDevBranchName" -Default "")
    if (-not $stateProjectRoot -or -not $worktreePath -or -not $safeName -or -not $allocationRoot -or -not $allocationWorktree) {
        return $false
    }
    return (
        (Get-FullPathNormalized $allocationRoot) -eq (Get-FullPathNormalized $stateProjectRoot) -and
        (Get-FullPathNormalized $allocationWorktree) -eq (Get-FullPathNormalized $worktreePath) -and
        $allocationSafeName -eq $safeName
    )
}

function Test-ItlTcpPortAvailable {
    param([int]$Port)

    if ($Port -lt 1 -or $Port -gt 65535) {
        return $false
    }

    foreach ($address in @([System.Net.IPAddress]::Any, [System.Net.IPAddress]::Loopback)) {
        $listener = $null
        try {
            $listener = New-Object System.Net.Sockets.TcpListener $address, $Port
            $listener.Start()
        } catch {
            return $false
        } finally {
            if ($null -ne $listener) {
                $listener.Stop()
            }
        }
    }
    return $true
}

function Test-ItlPortDockerContainerExists {
    param([string]$ContainerName)

    if ([string]::IsNullOrWhiteSpace($ContainerName)) {
        return $false
    }
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        return $false
    }

    $output = & docker ps -a --filter "name=^/$ContainerName$" --format "{{.Names}}" 2>$null
    if ($LASTEXITCODE -ne 0) {
        return $false
    }
    return @($output) -contains $ContainerName
}

function Get-ItlPortHashSegment {
    param([string]$Value)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Value)
        $hash = $sha.ComputeHash($bytes)
        return ([System.BitConverter]::ToString($hash).Replace("-", "").ToLowerInvariant().Substring(0, 12))
    } finally {
        $sha.Dispose()
    }
}

function Get-ItlBranchManagedPortKey {
    param(
        [string]$Family,
        [object]$State,
        [string]$Suffix = ""
    )

    $stateProjectRoot = [string](Get-ItlPortObjectValue -Object $State -Name "stateProjectRoot" -Default $script:ProjectRoot)
    $worktreePath = [string](Get-ItlPortObjectValue -Object $State -Name "worktreePath" -Default $stateProjectRoot)
    $safeName = [string](Get-ItlPortObjectValue -Object $State -Name "safeDevBranchName" -Default "")
    if (-not $safeName) {
        $branchName = [string](Get-ItlPortObjectValue -Object $State -Name "devBranchName" -Default "")
        if (-not $branchName) {
            $branchName = [string](Get-ItlPortObjectValue -Object $State -Name "devBranch" -Default "dev-branch")
        }
        $safeName = ConvertTo-SafeName $branchName
    }

    $projectSegment = ConvertTo-SafeName (Split-Path -Leaf $stateProjectRoot)
    $hash = Get-ItlPortHashSegment "$stateProjectRoot|$worktreePath|$safeName|$Suffix"
    return "${Family}:${projectSegment}:${safeName}:$hash"
}

function New-ItlPortAllocationRecord {
    param(
        [string]$Family,
        [string]$Key,
        [int]$Port,
        [object]$State = $null,
        [string]$Scope = "",
        [string]$ServerId = "",
        [string]$ContainerName = "",
        [string]$Status = "allocated",
        [string]$LeaseToken = ""
    )

    $stateProjectRoot = [string](Get-ItlPortObjectValue -Object $State -Name "stateProjectRoot" -Default $script:ProjectRoot)
    $worktreePath = [string](Get-ItlPortObjectValue -Object $State -Name "worktreePath" -Default $stateProjectRoot)
    $devBranchName = [string](Get-ItlPortObjectValue -Object $State -Name "devBranchName" -Default "")
    $safeName = [string](Get-ItlPortObjectValue -Object $State -Name "safeDevBranchName" -Default "")
    $devBranch = [string](Get-ItlPortObjectValue -Object $State -Name "devBranch" -Default "")
    $user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    if ([string]::IsNullOrWhiteSpace($user)) {
        $user = [Environment]::UserName
    }

    return [ordered]@{
        family = $Family
        key = $Key
        port = $Port
        scope = $Scope
        serverId = $ServerId
        containerName = $ContainerName
        status = $Status
        projectRoot = $stateProjectRoot
        worktreePath = $worktreePath
        devBranchName = $devBranchName
        safeDevBranchName = $safeName
        devBranch = $devBranch
        user = $user
        machine = [Environment]::MachineName
        pid = $PID
        ownerProcessStartedAt = (Get-ItlProcessStartedAt -ProcessId $PID)
        leaseToken = $LeaseToken
        updatedAt = (Get-Date).ToString("o")
    }
}

function Test-ItlPortReserved {
    param(
        [hashtable]$ReservedPorts,
        [int]$Port
    )

    if ($null -eq $ReservedPorts -or $Port -le 0) {
        return $false
    }
    return ($ReservedPorts.ContainsKey($Port) -or $ReservedPorts.ContainsKey([string]$Port))
}

function Resolve-ItlManagedPortLease {
    param(
        [string]$Family,
        [string]$Key,
        [int]$Start,
        [int]$End,
        [int]$PreferredPort = 0,
        [int]$ExplicitPort = 0,
        [hashtable]$ReservedPorts = @{},
        [object]$State = $null,
        [string]$Scope = "",
        [string]$ServerId = "",
        [string]$ContainerName = "",
        [string]$Subject = "managed port",
        [string]$LeaseToken = ""
    )

    if ([string]::IsNullOrWhiteSpace($Family) -or [string]::IsNullOrWhiteSpace($Key)) {
        throw "ITL port allocation requires non-empty family and key."
    }
    if ($Start -lt 1 -or $End -gt 65535 -or $Start -gt $End) {
        throw "Invalid $Subject range: $Start..$End"
    }
    if ($ExplicitPort -lt 0 -or $ExplicitPort -gt 65535) {
        throw "Invalid requested $Subject ${ExplicitPort}."
    }

    $result = Invoke-ItlPortRegistryLock -ScriptBlock {
        $registry = Read-ItlPortRegistry
        $allocations = @(ConvertTo-ItlPortAllocationArray (Get-ItlPortObjectValue -Object $registry -Name "allocations" -Default @()))
        $kept = @()
        $used = @{}
        $same = $null

        foreach ($allocation in $allocations) {
            $status = [string](Get-ItlPortObjectValue -Object $allocation -Name "status" -Default "")
            if ($status -eq "released" -or (Test-ItlPortAllocationSafelyStale -Allocation $allocation)) {
                continue
            }

            $port = ConvertTo-ItlPortInt -Value (Get-ItlPortObjectValue -Object $allocation -Name "port" -Default 0)
            $allocationFamily = [string](Get-ItlPortObjectValue -Object $allocation -Name "family" -Default "")
            $allocationKey = [string](Get-ItlPortObjectValue -Object $allocation -Name "key" -Default "")
            $allocationLeaseToken = [string](Get-ItlPortObjectValue -Object $allocation -Name "leaseToken" -Default "")
            $adoptLegacyLease = $LeaseToken -and -not $allocationLeaseToken -and (Test-ItlPortAllocationMatchesStateIdentity -Allocation $allocation -State $State)
            $sameToken = $(if ($LeaseToken) { $allocationLeaseToken -eq $LeaseToken -or $adoptLegacyLease } else { -not $allocationLeaseToken })
            $isSame = ($allocationFamily -eq $Family -and $allocationKey -eq $Key -and $sameToken)
            if ($isSame -and $null -eq $same) {
                $same = $allocation
                $kept += $allocation
                continue
            }

            $kept += $allocation
            if ($port -gt 0) {
                $used[$port] = $allocation
            }
        }

        foreach ($reservedPort in @($ReservedPorts.Keys)) {
            $reserved = ConvertTo-ItlPortInt -Value $reservedPort
            if ($reserved -gt 0 -and -not $used.ContainsKey($reserved)) {
                $used[$reserved] = [pscustomobject]@{ family = "branch-state"; key = "reserved"; port = $reserved }
            }
        }

        function New-AllocationResult {
            param([int]$Port)

            $record = New-ItlPortAllocationRecord `
                -Family $Family `
                -Key $Key `
                -Port $Port `
                -State $State `
                -Scope $Scope `
                -ServerId $ServerId `
                -ContainerName $ContainerName `
                -Status "allocated" `
                -LeaseToken $LeaseToken

            $updated = @()
            $replaced = $false
            foreach ($allocation in $kept) {
                $allocationFamily = [string](Get-ItlPortObjectValue -Object $allocation -Name "family" -Default "")
                $allocationKey = [string](Get-ItlPortObjectValue -Object $allocation -Name "key" -Default "")
                $allocationLeaseToken = [string](Get-ItlPortObjectValue -Object $allocation -Name "leaseToken" -Default "")
                $adoptLegacyLease = $LeaseToken -and -not $allocationLeaseToken -and (Test-ItlPortAllocationMatchesStateIdentity -Allocation $allocation -State $State)
                $sameToken = $(if ($LeaseToken) { $allocationLeaseToken -eq $LeaseToken -or $adoptLegacyLease } else { -not $allocationLeaseToken })
                if ($allocationFamily -eq $Family -and $allocationKey -eq $Key -and $sameToken) {
                    if (-not $replaced) {
                        $updated += $record
                        $replaced = $true
                    }
                } else {
                    $updated += $allocation
                }
            }
            if (-not $replaced) {
                $updated += $record
            }

            $hash = ConvertTo-Agent1cHashtable -Object $registry
            $hash["allocations"] = $updated
            Write-ItlPortRegistry -Registry $hash
            return [pscustomobject]@{ port = $Port; leaseToken = $LeaseToken }
        }

        function Test-CandidatePort {
            param(
                [int]$Port,
                [switch]$Explicit
            )

            if ($Port -lt 1 -or $Port -gt 65535) {
                return $false
            }
            if ($used.ContainsKey($Port)) {
                if ($Explicit) {
                    $owner = $used[$Port]
                    $ownerFamily = [string](Get-ItlPortObjectValue -Object $owner -Name "family" -Default "unknown")
                    $ownerKey = [string](Get-ItlPortObjectValue -Object $owner -Name "key" -Default "unknown")
                    throw "Requested $Subject $Port is already reserved by $ownerFamily allocation '$ownerKey'."
                }
                return $false
            }
            if (-not (Test-ItlTcpPortAvailable -Port $Port)) {
                if ($Explicit) {
                    throw "Requested $Subject $Port is already occupied by another process."
                }
                return $false
            }
            return $true
        }

        if ($ExplicitPort -gt 0) {
            if (Test-CandidatePort -Port $ExplicitPort -Explicit) {
                return (New-AllocationResult -Port $ExplicitPort)
            }
        }

        if ($null -ne $same) {
            $samePort = ConvertTo-ItlPortInt -Value (Get-ItlPortObjectValue -Object $same -Name "port" -Default 0)
            $sameContainer = [string](Get-ItlPortObjectValue -Object $same -Name "containerName" -Default $ContainerName)
            if ($samePort -gt 0 -and -not $used.ContainsKey($samePort)) {
                if ((Test-ItlTcpPortAvailable -Port $samePort) -or (Test-ItlPortDockerContainerExists -ContainerName $sameContainer)) {
                    return (New-AllocationResult -Port $samePort)
                }
            }
        }

        if ($PreferredPort -gt 0 -and (Test-CandidatePort -Port $PreferredPort)) {
            return (New-AllocationResult -Port $PreferredPort)
        }

        for ($port = $Start; $port -le $End; $port++) {
            if (Test-CandidatePort -Port $port) {
                return (New-AllocationResult -Port $port)
            }
        }

        throw "No free $Subject found in range $Start..$End. Stop another ITL-managed process or override the corresponding port range."
    }

    return $result
}

function Resolve-ItlManagedPort {
    param(
        [string]$Family,
        [string]$Key,
        [int]$Start,
        [int]$End,
        [int]$PreferredPort = 0,
        [int]$ExplicitPort = 0,
        [hashtable]$ReservedPorts = @{},
        [object]$State = $null,
        [string]$Scope = "",
        [string]$ServerId = "",
        [string]$ContainerName = "",
        [string]$Subject = "managed port"
    )

    $lease = Resolve-ItlManagedPortLease @PSBoundParameters
    return [int]$lease.port
}

function Set-ItlManagedPortAllocationStatus {
    param(
        [string]$Family,
        [string]$Key,
        [string]$Status,
        [int]$ProcessId = 0,
        [string]$LeaseToken = ""
    )

    if ([string]::IsNullOrWhiteSpace($Family) -or [string]::IsNullOrWhiteSpace($Key)) {
        return
    }

    Invoke-ItlPortRegistryLock -ScriptBlock {
        $registry = Read-ItlPortRegistry
        $allocations = @(ConvertTo-ItlPortAllocationArray (Get-ItlPortObjectValue -Object $registry -Name "allocations" -Default @()))
        $updated = @()
        foreach ($allocation in $allocations) {
            $allocationFamily = [string](Get-ItlPortObjectValue -Object $allocation -Name "family" -Default "")
            $allocationKey = [string](Get-ItlPortObjectValue -Object $allocation -Name "key" -Default "")
            $allocationLeaseToken = [string](Get-ItlPortObjectValue -Object $allocation -Name "leaseToken" -Default "")
            $tokenMatches = $(if ($allocationLeaseToken) { $LeaseToken -and $allocationLeaseToken -eq $LeaseToken } else { -not $LeaseToken })
            if ($allocationFamily -eq $Family -and $allocationKey -eq $Key -and $tokenMatches) {
                $hash = ConvertTo-Agent1cHashtable -Object $allocation
                $hash["status"] = $Status
                $hash["updatedAt"] = (Get-Date).ToString("o")
                if ($ProcessId -gt 0) {
                    $hash["pid"] = $ProcessId
                    $hash["ownerProcessStartedAt"] = Get-ItlProcessStartedAt -ProcessId $ProcessId
                }
                $updated += $hash
            } else {
                $updated += $allocation
            }
        }

        $registryHash = ConvertTo-Agent1cHashtable -Object $registry
        $registryHash["allocations"] = $updated
        Write-ItlPortRegistry -Registry $registryHash
    } | Out-Null
}

function Release-ItlManagedPortAllocation {
    param(
        [string]$Family,
        [string]$Key,
        [string]$LeaseToken = ""
    )

    if ([string]::IsNullOrWhiteSpace($Family) -or [string]::IsNullOrWhiteSpace($Key)) {
        return
    }

    Invoke-ItlPortRegistryLock -ScriptBlock {
        $registry = Read-ItlPortRegistry
        $allocations = @(ConvertTo-ItlPortAllocationArray (Get-ItlPortObjectValue -Object $registry -Name "allocations" -Default @()))
        $updated = @()
        foreach ($allocation in $allocations) {
            $allocationFamily = [string](Get-ItlPortObjectValue -Object $allocation -Name "family" -Default "")
            $allocationKey = [string](Get-ItlPortObjectValue -Object $allocation -Name "key" -Default "")
            $allocationLeaseToken = [string](Get-ItlPortObjectValue -Object $allocation -Name "leaseToken" -Default "")
            $tokenMatches = $(if ($allocationLeaseToken) { $LeaseToken -and $allocationLeaseToken -eq $LeaseToken } else { -not $LeaseToken })
            if ($allocationFamily -eq $Family -and $allocationKey -eq $Key -and $tokenMatches) {
                continue
            }
            $updated += $allocation
        }

        $registryHash = ConvertTo-Agent1cHashtable -Object $registry
        $registryHash["allocations"] = $updated
        Write-ItlPortRegistry -Registry $registryHash
    } | Out-Null
}

function Release-ItlManagedPortAllocationsForState {
    param([object]$State)

    $stateProjectRoot = [string](Get-ItlPortObjectValue -Object $State -Name "stateProjectRoot" -Default $script:ProjectRoot)
    $worktreePath = [string](Get-ItlPortObjectValue -Object $State -Name "worktreePath" -Default $stateProjectRoot)
    $safeName = [string](Get-ItlPortObjectValue -Object $State -Name "safeDevBranchName" -Default "")

    Invoke-ItlPortRegistryLock -ScriptBlock {
        $registry = Read-ItlPortRegistry
        $allocations = @(ConvertTo-ItlPortAllocationArray (Get-ItlPortObjectValue -Object $registry -Name "allocations" -Default @()))
        $updated = @()
        foreach ($allocation in $allocations) {
            $allocationRoot = [string](Get-ItlPortObjectValue -Object $allocation -Name "projectRoot" -Default "")
            $allocationWorktree = [string](Get-ItlPortObjectValue -Object $allocation -Name "worktreePath" -Default "")
            $allocationSafeName = [string](Get-ItlPortObjectValue -Object $allocation -Name "safeDevBranchName" -Default "")
            $sameRoot = $allocationRoot -and ((Get-FullPathNormalized $allocationRoot) -eq (Get-FullPathNormalized $stateProjectRoot))
            $sameWorktree = $allocationWorktree -and ((Get-FullPathNormalized $allocationWorktree) -eq (Get-FullPathNormalized $worktreePath))
            $sameBranch = $safeName -and $allocationSafeName -eq $safeName
            if ($sameRoot -and $sameWorktree -and $sameBranch) {
                $allocationLeaseToken = [string](Get-ItlPortObjectValue -Object $allocation -Name "leaseToken" -Default "")
                if (-not $allocationLeaseToken) {
                    continue
                }
                $family = [string](Get-ItlPortObjectValue -Object $allocation -Name "family" -Default "")
                $stateTokenName = switch ($family) {
                    "vanessa-testclient" { "vanessaTestPortLeaseToken" }
                    "vanessa-mcp" { "vanessaMcpPortLeaseToken" }
                    "roctup-mcp" { "roctupMcpPortLeaseToken" }
                    default { "" }
                }
                $stateLeaseToken = $(if ($stateTokenName) { [string](Get-ItlPortObjectValue -Object $State -Name $stateTokenName -Default "") } else { "" })
                if ($stateLeaseToken -and $stateLeaseToken -eq $allocationLeaseToken) {
                    continue
                }
            }
            $updated += $allocation
        }

        $registryHash = ConvertTo-Agent1cHashtable -Object $registry
        $registryHash["allocations"] = $updated
        Write-ItlPortRegistry -Registry $registryHash
    } | Out-Null
}
