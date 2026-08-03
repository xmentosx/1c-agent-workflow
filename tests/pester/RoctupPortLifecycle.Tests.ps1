Describe "ROCTUP managed port lifecycle" {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        $RepoRoot = $context.RepoRoot
        $HelperPath = $context.HelperPath

        function Get-FreeRoctupPort {
            for ($port = 46000; $port -lt 55000; $port += 7) {
                $listener = $null
                try {
                    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $port)
                    $listener.Start()
                    return $port
                } catch {
                } finally {
                    if ($null -ne $listener) { $listener.Stop() }
                }
            }
            throw "No free TCP port found for ROCTUP lifecycle test."
        }
    }

    It "does not reserve a ROCTUP port from a closed branch state" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-roctup-closed-port-" + [guid]::NewGuid().ToString("N"))
        try {
            $stateDir = Join-Path $tempRoot ".agent-1c\dev-branches"
            New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
            & git -C $tempRoot init *> $null
            $closedState = [ordered]@{
                devBranchName = "Closed"
                safeDevBranchName = "closed"
                devBranch = "itldev/closed"
                worktreePath = $tempRoot
                roctupMcpPort = 48161
                closedAt = (Get-Date).ToString("o")
            }
            [System.IO.File]::WriteAllText((Join-Path $stateDir "closed.json"), (($closedState | ConvertTo-Json) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))

            $count = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $current = [pscustomobject]@{
                    devBranchName = "Current"
                    safeDevBranchName = "current"
                    devBranch = "itldev/current"
                    stateProjectRoot = $tempRoot
                    worktreePath = $tempRoot
                }
                (Get-RoctupMcpReservedPorts -CurrentState $current).Keys.Count
            }

            $count | Should -Be 0
        } finally {
            Set-Location -LiteralPath $RepoRoot
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "migrates a legacy ROCTUP allocation and reuses its immutable token after restart" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-roctup-port-restart-" + [guid]::NewGuid().ToString("N"))
        $oldRegistryHome = [Environment]::GetEnvironmentVariable("ITL_PORT_REGISTRY_HOME", "Process")
        $oldRange = [Environment]::GetEnvironmentVariable("ROCTUP_MCP_PORT_RANGE", "Process")
        try {
            $stateDir = Join-Path $tempRoot ".agent-1c\dev-branches"
            New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
            & git -C $tempRoot init *> $null
            $port = Get-FreeRoctupPort
            [Environment]::SetEnvironmentVariable("ITL_PORT_REGISTRY_HOME", (Join-Path $tempRoot "registry"), "Process")
            [Environment]::SetEnvironmentVariable("ROCTUP_MCP_PORT_RANGE", "$port..$port", "Process")
            $savedState = [ordered]@{
                devBranchName = "Feature"
                safeDevBranchName = "feature"
                devBranch = "itldev/feature"
                worktreePath = $tempRoot
                closedAt = ""
            }
            [System.IO.File]::WriteAllText((Join-Path $stateDir "feature.json"), (($savedState | ConvertTo-Json) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))

            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $state = [pscustomobject]@{
                    devBranchName = "Feature"
                    safeDevBranchName = "feature"
                    devBranch = "itldev/feature"
                    stateProjectRoot = $tempRoot
                    worktreePath = $tempRoot
                }
                $legacyPort = Resolve-RoctupMcpPort -State $state
                $legacy = ConvertTo-Agent1cHashtable -Object (Read-ItlPortRegistry)
                $legacy["schemaVersion"] = 1
                $legacyAllocation = ConvertTo-Agent1cHashtable -Object @($legacy["allocations"])[0]
                $legacyAllocation.Remove("leaseToken")
                $legacyAllocation.Remove("ownerProcessStartedAt")
                $legacy["allocations"] = @($legacyAllocation)
                Write-Utf8Text -Path (Get-ItlPortRegistryPath) -Value (($legacy | ConvertTo-Json -Depth 12) + [Environment]::NewLine)

                $token = New-ItlManagedPortLeaseToken
                $first = Resolve-RoctupMcpPortLease -State $state -LeaseToken $token
                $second = Resolve-RoctupMcpPortLease -State $state -LeaseToken $token
                Release-ItlManagedPortAllocation -Family "roctup-mcp" -Key (Get-ItlBranchManagedPortKey -Family "roctup-mcp" -State $state)
                $afterLegacyRelease = Read-ItlPortRegistry
                [pscustomobject]@{
                    legacyPort = $legacyPort
                    firstPort = $first.port
                    secondPort = $second.port
                    token = $token
                    storedToken = [string]@($afterLegacyRelease.allocations)[0].leaseToken
                    allocationCount = @($afterLegacyRelease.allocations).Count
                }
            }

            $result.firstPort | Should -Be $result.legacyPort
            $result.secondPort | Should -Be $result.legacyPort
            $result.storedToken | Should -Be $result.token
            $result.allocationCount | Should -Be 1
        } finally {
            Set-Location -LiteralPath $RepoRoot
            [Environment]::SetEnvironmentVariable("ITL_PORT_REGISTRY_HOME", $oldRegistryHome, "Process")
            [Environment]::SetEnvironmentVariable("ROCTUP_MCP_PORT_RANGE", $oldRange, "Process")
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "reclaims a crashed ROCTUP lease only when all conservative proofs pass" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-roctup-port-crash-" + [guid]::NewGuid().ToString("N"))
        $oldRegistryHome = [Environment]::GetEnvironmentVariable("ITL_PORT_REGISTRY_HOME", "Process")
        try {
            $stateDir = Join-Path $tempRoot ".agent-1c\dev-branches"
            New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
            & git -C $tempRoot init *> $null
            $port = Get-FreeRoctupPort
            [Environment]::SetEnvironmentVariable("ITL_PORT_REGISTRY_HOME", (Join-Path $tempRoot "registry"), "Process")

            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $allocation = [ordered]@{
                    family = "roctup-mcp"
                    key = "crashed"
                    port = $port
                    status = "allocated"
                    projectRoot = $tempRoot
                    worktreePath = $tempRoot
                    safeDevBranchName = "missing"
                    machine = [Environment]::MachineName
                    pid = 2147483000
                    ownerProcessStartedAt = "2020-01-01T00:00:00.0000000Z"
                    leaseToken = "crashed-token"
                    updatedAt = (Get-Date).AddMinutes(-10).ToString("o")
                }

                $withinGrace = ConvertTo-Agent1cHashtable -Object $allocation
                $withinGrace["updatedAt"] = (Get-Date).ToString("o")
                $beforeGrace = Test-ItlPortAllocationSafelyStale -Allocation $withinGrace

                $openState = [ordered]@{ safeDevBranchName = "missing"; devBranchName = "Missing"; closedAt = "" }
                [System.IO.File]::WriteAllText((Join-Path $stateDir "missing.json"), (($openState | ConvertTo-Json) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
                $withOpenState = Test-ItlPortAllocationSafelyStale -Allocation $allocation
                Remove-Item -LiteralPath (Join-Path $stateDir "missing.json") -Force

                $owned = ConvertTo-Agent1cHashtable -Object $allocation
                $owned["pid"] = $PID
                $owned["ownerProcessStartedAt"] = Get-ItlProcessStartedAt -ProcessId $PID
                $withOwner = Test-ItlPortAllocationSafelyStale -Allocation $owned

                $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $port)
                $listener.Start()
                try {
                    $withOpenPort = Test-ItlPortAllocationSafelyStale -Allocation $allocation
                } finally {
                    $listener.Stop()
                }

                $allProofs = Test-ItlPortAllocationSafelyStale -Allocation $allocation
                Write-ItlPortRegistry -Registry ([ordered]@{ schemaVersion = 2; allocations = @($allocation); updatedAt = "" })
                $replacementState = [pscustomobject]@{
                    devBranchName = "Replacement"
                    safeDevBranchName = "replacement"
                    devBranch = "itldev/replacement"
                    stateProjectRoot = $tempRoot
                    worktreePath = $tempRoot
                }
                $replacement = Resolve-ItlManagedPortLease -Family "roctup-mcp" -Key "replacement" -Start $port -End $port -ExplicitPort $port -State $replacementState -LeaseToken "replacement-token"
                [pscustomobject]@{
                    beforeGrace = $beforeGrace
                    withOpenState = $withOpenState
                    withOwner = $withOwner
                    withOpenPort = $withOpenPort
                    allProofs = $allProofs
                    replacementPort = $replacement.port
                }
            }

            $result.beforeGrace | Should -BeFalse
            $result.withOpenState | Should -BeFalse
            $result.withOwner | Should -BeFalse
            $result.withOpenPort | Should -BeFalse
            $result.allProofs | Should -BeTrue
            $result.replacementPort | Should -Be $port
        } finally {
            Set-Location -LiteralPath $RepoRoot
            [Environment]::SetEnvironmentVariable("ITL_PORT_REGISTRY_HOME", $oldRegistryHome, "Process")
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "keeps a replacement ROCTUP lease safe from old close state and clears close fields" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-roctup-port-close-" + [guid]::NewGuid().ToString("N"))
        $oldRegistryHome = [Environment]::GetEnvironmentVariable("ITL_PORT_REGISTRY_HOME", "Process")
        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            & git -C $tempRoot init *> $null
            [Environment]::SetEnvironmentVariable("ITL_PORT_REGISTRY_HOME", (Join-Path $tempRoot "registry"), "Process")
            $port = Get-FreeRoctupPort
            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $allocation = [ordered]@{
                    family = "roctup-mcp"
                    key = "same-branch"
                    port = $port
                    status = "allocated"
                    projectRoot = $tempRoot
                    worktreePath = $tempRoot
                    safeDevBranchName = "feature"
                    leaseToken = "replacement-token"
                    updatedAt = (Get-Date).ToString("o")
                }
                Write-ItlPortRegistry -Registry ([ordered]@{ schemaVersion = 2; allocations = @($allocation); updatedAt = "" })
                Release-ItlManagedPortAllocationsForState -State ([pscustomobject]@{
                    stateProjectRoot = $tempRoot
                    worktreePath = $tempRoot
                    safeDevBranchName = "feature"
                    roctupMcpPortLeaseToken = "old-token"
                })
                $afterOldState = Read-ItlPortRegistry
                Release-ItlManagedPortAllocationsForState -State ([pscustomobject]@{
                    stateProjectRoot = $tempRoot
                    worktreePath = $tempRoot
                    safeDevBranchName = "feature"
                    roctupMcpPortLeaseToken = "replacement-token"
                })
                $afterReplacement = Read-ItlPortRegistry
                [pscustomobject]@{
                    afterOldStateCount = @($afterOldState.allocations).Count
                    afterReplacementCount = @($afterReplacement.allocations).Count
                }
            }

            $result.afterOldStateCount | Should -Be 1
            $result.afterReplacementCount | Should -Be 0

            $lifecycleText = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.lifecycle.ps1") -Encoding UTF8 -Raw
            $lifecycleText | Should -Match '\$updates\["roctupMcpPort"\]\s*=\s*0'
            $lifecycleText | Should -Match '\$updates\["roctupMcpPortLeaseToken"\]\s*=\s*""'
            $roctupText = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.roctup-mcp.ps1") -Encoding UTF8 -Raw
            $roctupText | Should -Match '(?s)Update-DevBranchState -State \$State -Updates @\{ roctupMcpPortLeaseToken = \$portLeaseToken \}.*?Resolve-RoctupMcpPortLease -State \$State -LeaseToken \$portLeaseToken'
            $roctupText | Should -Match 'Set-ItlManagedPortAllocationStatus -Family "roctup-mcp".*?-ProcessId \$result\.process\.Id -LeaseToken \$portLeaseToken'
        } finally {
            Set-Location -LiteralPath $RepoRoot
            [Environment]::SetEnvironmentVariable("ITL_PORT_REGISTRY_HOME", $oldRegistryHome, "Process")
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
