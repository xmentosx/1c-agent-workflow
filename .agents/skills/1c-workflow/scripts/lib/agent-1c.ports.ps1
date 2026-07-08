if (-not (Get-Variable -Name ItlPortRegistryUserScopeWarningPrinted -Scope Script -ErrorAction SilentlyContinue)) {
    $script:ItlPortRegistryUserScopeWarningPrinted = $false
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
            schemaVersion = 1
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
    $hash["schemaVersion"] = 1
    $hash["updatedAt"] = (Get-Date).ToString("o")
    Write-Utf8Text -Path (Get-ItlPortRegistryPath) -Value (($hash | ConvertTo-Json -Depth 12) + [Environment]::NewLine)
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
        [string]$Status = "allocated"
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
            if ($status -eq "released") {
                continue
            }

            $port = ConvertTo-ItlPortInt -Value (Get-ItlPortObjectValue -Object $allocation -Name "port" -Default 0)
            $allocationFamily = [string](Get-ItlPortObjectValue -Object $allocation -Name "family" -Default "")
            $allocationKey = [string](Get-ItlPortObjectValue -Object $allocation -Name "key" -Default "")
            $isSame = ($allocationFamily -eq $Family -and $allocationKey -eq $Key)
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
                -Status "allocated"

            $updated = @()
            $replaced = $false
            foreach ($allocation in $kept) {
                $allocationFamily = [string](Get-ItlPortObjectValue -Object $allocation -Name "family" -Default "")
                $allocationKey = [string](Get-ItlPortObjectValue -Object $allocation -Name "key" -Default "")
                if ($allocationFamily -eq $Family -and $allocationKey -eq $Key) {
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
            return [pscustomobject]@{ port = $Port }
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

    return [int]$result.port
}

function Set-ItlManagedPortAllocationStatus {
    param(
        [string]$Family,
        [string]$Key,
        [string]$Status,
        [int]$ProcessId = 0
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
            if ($allocationFamily -eq $Family -and $allocationKey -eq $Key) {
                $hash = ConvertTo-Agent1cHashtable -Object $allocation
                $hash["status"] = $Status
                $hash["updatedAt"] = (Get-Date).ToString("o")
                if ($ProcessId -gt 0) {
                    $hash["pid"] = $ProcessId
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
        [string]$Key
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
            if ($allocationFamily -eq $Family -and $allocationKey -eq $Key) {
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
                continue
            }
            $updated += $allocation
        }

        $registryHash = ConvertTo-Agent1cHashtable -Object $registry
        $registryHash["allocations"] = $updated
        Write-ItlPortRegistry -Registry $registryHash
    } | Out-Null
}
