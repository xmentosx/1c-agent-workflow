Describe "Branch managed port registry lifecycle" {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        $HelperPath = $context.HelperPath

        function Get-FreePortRange {
            param([int]$Count = 1)

            for ($candidate = 45000; $candidate -le (55000 - $Count); $candidate += ($Count + 3)) {
                $listeners = @()
                try {
                    for ($offset = 0; $offset -lt $Count; $offset++) {
                        $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, ($candidate + $offset))
                        $listener.Start()
                        $listeners += $listener
                    }
                    return [pscustomobject]@{ start = $candidate; end = ($candidate + $Count - 1) }
                } catch {
                } finally {
                    foreach ($listener in $listeners) {
                        $listener.Stop()
                    }
                }
            }
            throw "No free consecutive TCP port range found for test."
        }
    }

    It "does not reserve Vanessa TestClient or MCP ports from closed branch states" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-closed-port-state-" + [guid]::NewGuid().ToString("N"))
        try {
            $stateDir = Join-Path $tempRoot ".agent-1c\dev-branches"
            New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
            & git -C $tempRoot init *> $null
            $closedState = [ordered]@{
                devBranchName = "Closed"
                safeDevBranchName = "closed"
                devBranch = "itldev/closed"
                worktreePath = $tempRoot
                vanessaTestPort = 48151
                vanessaMcpPort = 9875
                closedAt = (Get-Date).ToString("o")
            }
            [System.IO.File]::WriteAllText((Join-Path $stateDir "closed.json"), (($closedState | ConvertTo-Json) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))

            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $current = [pscustomobject]@{
                    devBranchName = "Current"
                    safeDevBranchName = "current"
                    devBranch = "itldev/current"
                    stateProjectRoot = $tempRoot
                    worktreePath = $tempRoot
                }
                [pscustomobject]@{
                    testPortCount = (Get-VanessaTestReservedPorts -CurrentState $current).Keys.Count
                    mcpPortCount = (Get-VanessaMcpReservedPorts -CurrentState $current).Keys.Count
                }
            }

            $result.testPortCount | Should -Be 0
            $result.mcpPortCount | Should -Be 0
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "reserves every array and legacy TestClient port without merging a foreign canonical tuple" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-reserved-port-state-" + [guid]::NewGuid().ToString("N"))
        try {
            $stateDir = Join-Path $tempRoot ".agent-1c\dev-branches"
            New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
            & git -C $tempRoot init *> $null
            $sharedInfoBase = Join-Path $tempRoot "shared\infobase"
            $foreignState = [ordered]@{
                devBranchName = "Same display"
                safeDevBranchName = "same-display"
                stateProjectRoot = Join-Path $tempRoot "foreign-root"
                worktreePath = Join-Path $tempRoot "foreign-worktree"
                devBranchInfoBasePath = $sharedInfoBase
                vanessaTestPort = 48151
                vanessaTestPorts = @(48151, 48152)
                closedAt = ""
            }
            $legacyState = [ordered]@{
                devBranchName = "Legacy"
                safeDevBranchName = "legacy"
                stateProjectRoot = Join-Path $tempRoot "legacy-root"
                worktreePath = Join-Path $tempRoot "legacy-worktree"
                devBranchInfoBasePath = Join-Path $tempRoot "legacy\infobase"
                vanessaTestPort = 48153
                closedAt = ""
            }
            [System.IO.File]::WriteAllText((Join-Path $stateDir "foreign.json"), (($foreignState | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
            [System.IO.File]::WriteAllText((Join-Path $stateDir "legacy.json"), (($legacyState | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))

            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $current = [pscustomobject]@{
                    devBranchName = "Same display"
                    safeDevBranchName = "same-display"
                    stateProjectRoot = Join-Path $tempRoot "current-root"
                    worktreePath = Join-Path $tempRoot "current-worktree"
                    devBranchInfoBasePath = $sharedInfoBase
                }
                $exactTuple = [pscustomobject]@{
                    safeDevBranchName = "different-display"
                    stateProjectRoot = $current.stateProjectRoot.ToUpperInvariant().Replace('\', '/')
                    worktreePath = $current.worktreePath.ToUpperInvariant().Replace('\', '/')
                    devBranchInfoBasePath = $current.devBranchInfoBasePath.ToUpperInvariant().Replace('\', '/')
                }
                $reserved = Get-VanessaTestReservedPorts -CurrentState $current
                [pscustomobject]@{
                    foreignMatch = Test-VanessaStateIdentityMatch -First $current -Second $foreignState
                    exactTupleMatch = Test-VanessaStateIdentityMatch -First $current -Second $exactTuple
                    incompleteMatch = Test-VanessaStateIdentityMatch -First $current -Second ([pscustomobject]@{ devBranchInfoBasePath = $sharedInfoBase })
                    ports = @($reserved.Keys | Sort-Object)
                }
            }

            $result.foreignMatch | Should -BeFalse
            $result.exactTupleMatch | Should -BeTrue
            $result.incompleteMatch | Should -BeFalse
            $result.ports | Should -Be @(48151, 48152, 48153)
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "migrates a schema-1 allocation on restart and rejects stale or missing lease tokens" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-port-lease-migration-" + [guid]::NewGuid().ToString("N"))
        $oldRegistryHome = [Environment]::GetEnvironmentVariable("ITL_PORT_REGISTRY_HOME", "Process")
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c\dev-branches") | Out-Null
            [Environment]::SetEnvironmentVariable("ITL_PORT_REGISTRY_HOME", (Join-Path $tempRoot "registry"), "Process")
            $range = Get-FreePortRange
            $state = [ordered]@{
                devBranchName = "Feature"
                safeDevBranchName = "feature"
                devBranch = "itldev/feature"
                worktreePath = $tempRoot
            }
            [System.IO.File]::WriteAllText((Join-Path $tempRoot ".agent-1c\dev-branches\feature.json"), (($state | ConvertTo-Json) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))

            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $runtimeState = [pscustomobject]@{
                    devBranchName = "Feature"
                    safeDevBranchName = "feature"
                    devBranch = "itldev/feature"
                    stateProjectRoot = $tempRoot
                    worktreePath = $tempRoot
                }
                $key = Get-ItlBranchManagedPortKey -Family "vanessa-mcp" -State $runtimeState
                $legacyPort = Resolve-ItlManagedPort -Family "vanessa-mcp" -Key $key -Start $range.start -End $range.end -State $runtimeState
                $legacy = ConvertTo-Agent1cHashtable -Object (Read-ItlPortRegistry)
                $legacy["schemaVersion"] = 1
                $legacyAllocation = ConvertTo-Agent1cHashtable -Object @($legacy["allocations"])[0]
                $legacyAllocation.Remove("leaseToken")
                $legacyAllocation.Remove("ownerProcessStartedAt")
                $legacy["allocations"] = @($legacyAllocation)
                Write-Utf8Text -Path (Get-ItlPortRegistryPath) -Value (($legacy | ConvertTo-Json -Depth 12) + [Environment]::NewLine)

                $token = New-ItlManagedPortLeaseToken
                $first = Resolve-ItlManagedPortLease -Family "vanessa-mcp" -Key $key -Start $range.start -End $range.end -State $runtimeState -LeaseToken $token
                $second = Resolve-ItlManagedPortLease -Family "vanessa-mcp" -Key $key -Start $range.start -End $range.end -State $runtimeState -LeaseToken $token
                Release-ItlManagedPortAllocation -Family "vanessa-mcp" -Key $key
                Release-ItlManagedPortAllocation -Family "vanessa-mcp" -Key $key -LeaseToken (New-ItlManagedPortLeaseToken)
                $afterOldRelease = Read-ItlPortRegistry
                Release-ItlManagedPortAllocation -Family "vanessa-mcp" -Key $key -LeaseToken $token
                $afterOwnerRelease = Read-ItlPortRegistry

                [pscustomobject]@{
                    legacyPort = $legacyPort
                    firstPort = $first.port
                    secondPort = $second.port
                    firstToken = $first.leaseToken
                    schemaVersion = $afterOldRelease.schemaVersion
                    afterOldReleaseCount = @($afterOldRelease.allocations).Count
                    migratedToken = [string]@($afterOldRelease.allocations)[0].leaseToken
                    afterOwnerReleaseCount = @($afterOwnerRelease.allocations).Count
                    expectedToken = $token
                }
            }

            $result.firstPort | Should -Be $result.legacyPort
            $result.secondPort | Should -Be $result.legacyPort
            $result.firstToken | Should -Be $result.expectedToken
            $result.schemaVersion | Should -Be 2
            $result.afterOldReleaseCount | Should -Be 1
            $result.migratedToken | Should -Be $result.expectedToken
            $result.afterOwnerReleaseCount | Should -Be 0
        } finally {
            [Environment]::SetEnvironmentVariable("ITL_PORT_REGISTRY_HOME", $oldRegistryHome, "Process")
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "reclaims a crashed allocation only after state owner port and grace checks all pass" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-port-stale-reclaim-" + [guid]::NewGuid().ToString("N"))
        $oldRegistryHome = [Environment]::GetEnvironmentVariable("ITL_PORT_REGISTRY_HOME", "Process")
        $listener = $null
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c\dev-branches") | Out-Null
            [Environment]::SetEnvironmentVariable("ITL_PORT_REGISTRY_HOME", (Join-Path $tempRoot "registry"), "Process")
            $range = Get-FreePortRange

            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $allocation = [ordered]@{
                    family = "vanessa-testclient"
                    key = "crashed"
                    port = $range.start
                    status = "allocated"
                    projectRoot = $tempRoot
                    worktreePath = $tempRoot
                    safeDevBranchName = "missing"
                    machine = [Environment]::MachineName
                    pid = 2147483000
                    ownerProcessStartedAt = "2020-01-01T00:00:00.0000000Z"
                    leaseToken = "crashed-token"
                    updatedAt = (Get-Date).ToString("o")
                }

                $beforeGrace = Test-ItlPortAllocationSafelyStale -Allocation $allocation
                $allocation["updatedAt"] = (Get-Date).AddMinutes(-10).ToString("o")

                $openState = [ordered]@{ safeDevBranchName = "missing"; devBranchName = "Missing"; closedAt = "" }
                [System.IO.File]::WriteAllText((Join-Path $tempRoot ".agent-1c\dev-branches\missing.json"), (($openState | ConvertTo-Json) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
                $withOpenState = Test-ItlPortAllocationSafelyStale -Allocation $allocation
                Remove-Item -LiteralPath (Join-Path $tempRoot ".agent-1c\dev-branches\missing.json") -Force

                $owned = ConvertTo-Agent1cHashtable -Object $allocation
                $owned["pid"] = $PID
                $owned["ownerProcessStartedAt"] = Get-ItlProcessStartedAt -ProcessId $PID
                $withOwner = Test-ItlPortAllocationSafelyStale -Allocation $owned

                $script:staleListener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $range.start)
                $script:staleListener.Start()
                $withOpenPort = Test-ItlPortAllocationSafelyStale -Allocation $allocation
                $script:staleListener.Stop()
                $script:staleListener = $null

                $allChecksPass = Test-ItlPortAllocationSafelyStale -Allocation $allocation
                Write-ItlPortRegistry -Registry ([ordered]@{ schemaVersion = 2; allocations = @($allocation); updatedAt = "" })
                $replacementState = [pscustomobject]@{
                    devBranchName = "Replacement"
                    safeDevBranchName = "replacement"
                    devBranch = "itldev/replacement"
                    stateProjectRoot = $tempRoot
                    worktreePath = $tempRoot
                }
                $replacement = Resolve-ItlManagedPortLease -Family "vanessa-testclient" -Key "replacement" -Start $range.start -End $range.end -ExplicitPort $range.start -State $replacementState -LeaseToken "replacement-token"
                $registry = Read-ItlPortRegistry
                [pscustomobject]@{
                    beforeGrace = $beforeGrace
                    withOpenState = $withOpenState
                    withOwner = $withOwner
                    withOpenPort = $withOpenPort
                    allChecksPass = $allChecksPass
                    replacementPort = $replacement.port
                    allocationCount = @($registry.allocations).Count
                    remainingToken = [string]@($registry.allocations)[0].leaseToken
                }
            }

            $result.beforeGrace | Should -BeFalse
            $result.withOpenState | Should -BeFalse
            $result.withOwner | Should -BeFalse
            $result.withOpenPort | Should -BeFalse
            $result.allChecksPass | Should -BeTrue
            $result.replacementPort | Should -Be $range.start
            $result.allocationCount | Should -Be 1
            $result.remainingToken | Should -Be "replacement-token"
        } finally {
            if ($null -ne $listener) { $listener.Stop() }
            [Environment]::SetEnvironmentVariable("ITL_PORT_REGISTRY_HOME", $oldRegistryHome, "Process")
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "does not let an old branch state release a replacement lease" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-port-state-release-" + [guid]::NewGuid().ToString("N"))
        $oldRegistryHome = [Environment]::GetEnvironmentVariable("ITL_PORT_REGISTRY_HOME", "Process")
        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            [Environment]::SetEnvironmentVariable("ITL_PORT_REGISTRY_HOME", (Join-Path $tempRoot "registry"), "Process")
            $range = Get-FreePortRange

            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $allocation = [ordered]@{
                    family = "vanessa-mcp"
                    key = "same-branch"
                    port = $range.start
                    status = "allocated"
                    projectRoot = $tempRoot
                    worktreePath = $tempRoot
                    safeDevBranchName = "feature"
                    leaseToken = "replacement-token"
                    updatedAt = (Get-Date).ToString("o")
                }
                Write-ItlPortRegistry -Registry ([ordered]@{ schemaVersion = 2; allocations = @($allocation); updatedAt = "" })
                $oldState = [pscustomobject]@{
                    stateProjectRoot = $tempRoot
                    worktreePath = $tempRoot
                    safeDevBranchName = "feature"
                    vanessaMcpPortLeaseToken = "old-token"
                }
                Release-ItlManagedPortAllocationsForState -State $oldState
                $afterOldState = Read-ItlPortRegistry
                $replacementState = [pscustomobject]@{
                    stateProjectRoot = $tempRoot
                    worktreePath = $tempRoot
                    safeDevBranchName = "feature"
                    vanessaMcpPortLeaseToken = "replacement-token"
                }
                Release-ItlManagedPortAllocationsForState -State $replacementState
                $afterReplacement = Read-ItlPortRegistry
                [pscustomobject]@{
                    afterOldStateCount = @($afterOldState.allocations).Count
                    afterReplacementCount = @($afterReplacement.allocations).Count
                }
            }

            $result.afterOldStateCount | Should -Be 1
            $result.afterReplacementCount | Should -Be 0
        } finally {
            [Environment]::SetEnvironmentVariable("ITL_PORT_REGISTRY_HOME", $oldRegistryHome, "Process")
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "closes a branch by clearing Vanessa lease fields before releasing the captured leases" {
        $lifecyclePath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) ".agents\skills\1c-workflow\scripts\lib\agent-1c.lifecycle.ps1"
        $text = Get-Content -LiteralPath $lifecyclePath -Encoding UTF8 -Raw
        $closeStart = $text.IndexOf("function Close-DevBranch {")
        $closeEnd = $text.IndexOf("function Switch-Master {", $closeStart)
        $closeText = $text.Substring($closeStart, ($closeEnd - $closeStart))

        $closeText | Should -Match '\$updates\["closedAt"\]'
        $closeText | Should -Match '\$updates\["vanessaTestPort"\]\s*=\s*0'
        $closeText | Should -Match '\$updates\["vanessaTestPorts"\]\s*=\s*@\(\)'
        $closeText | Should -Match '\$updates\["vanessaTestPortLeaseToken"\]\s*=\s*""'
        $closeText | Should -Match '\$updates\["vanessaMcpPort"\]\s*=\s*0'
        $closeText | Should -Match '\$updates\["vanessaMcpPortLeaseToken"\]\s*=\s*""'
        $closeText | Should -Match '(?s)\$stateWithPortLeases\s*=\s*\$state\s+Update-DevBranchState.*?Release-ItlManagedPortAllocationsForState -State \$stateWithPortLeases'
    }

    It "serializes concurrent allocations through the shared registry lock" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-port-concurrency-" + [guid]::NewGuid().ToString("N"))
        $oldRegistryHome = [Environment]::GetEnvironmentVariable("ITL_PORT_REGISTRY_HOME", "Process")
        $jobs = @()
        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            $registryHome = Join-Path $tempRoot "registry"
            [Environment]::SetEnvironmentVariable("ITL_PORT_REGISTRY_HOME", $registryHome, "Process")
            $range = Get-FreePortRange -Count 4

            for ($index = 0; $index -lt 4; $index++) {
                $jobs += Start-Job -ScriptBlock {
                    param($ChildHelperPath, $ChildRoot, $RegistryHome, $Start, $End, $Index)
                    [Environment]::SetEnvironmentVariable("ITL_PORT_REGISTRY_HOME", $RegistryHome, "Process")
                    . $ChildHelperPath -ProjectRoot $ChildRoot -Action help *> $null
                    $state = [pscustomobject]@{
                        devBranchName = "Concurrent $Index"
                        safeDevBranchName = "concurrent-$Index"
                        devBranch = "itldev/concurrent-$Index"
                        stateProjectRoot = $ChildRoot
                        worktreePath = $ChildRoot
                    }
                    (Resolve-ItlManagedPortLease -Family "vanessa-mcp" -Key "concurrent-$Index" -Start $Start -End $End -State $state -LeaseToken "token-$Index").port
                } -ArgumentList $HelperPath, $tempRoot, $registryHome, $range.start, $range.end, $index
            }

            $jobs | Wait-Job -Timeout 60 | Out-Null
            @($jobs | Where-Object State -ne "Completed").Count | Should -Be 0
            $ports = @($jobs | Receive-Job)
            $ports.Count | Should -Be 4
            @($ports | Sort-Object -Unique).Count | Should -Be 4

            $registry = Get-Content -LiteralPath (Join-Path $registryHome "ports.json") -Encoding UTF8 -Raw | ConvertFrom-Json
            $registry.schemaVersion | Should -Be 2
            @($registry.allocations).Count | Should -Be 4
        } finally {
            if ($jobs.Count -gt 0) {
                $jobs | Remove-Job -Force -ErrorAction SilentlyContinue
            }
            [Environment]::SetEnvironmentVariable("ITL_PORT_REGISTRY_HOME", $oldRegistryHome, "Process")
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
