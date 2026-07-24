$ErrorActionPreference = "Stop"

Describe "Branch-safe Vanessa runtime cleanup" {
    BeforeAll {
        $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
        $HelperPath = Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\agent-1c.ps1"
        $VanessaPath = Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.vanessa.ps1"
        $LifecyclePath = Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.lifecycle.ps1"
    }

    It "releases only current-branch TestManager, TestClient, and Vanessa backend and is idempotent" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-vanessa-runtime-release-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"aiRules":{"tools":["codex"]}}'
            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $currentBase = Join-Path $tempRoot "current-base"
                $foreignBase = "D:\foreign-worktree\base"
                $state = [pscustomobject]@{
                    devBranchInfoBasePath = $currentBase
                    worktreePath = $tempRoot
                    safeDevBranchName = "current"
                }
                $script:StoppedIds = @()
                $script:Processes = @(
                    [pscustomobject]@{ processId = 1001; name = "1cv8c.exe"; commandLine = "1cv8c.exe /TESTMANAGER /F `"$currentBase`""; workingSetMb = 10 },
                    [pscustomobject]@{ processId = 1002; name = "1cv8c.exe"; commandLine = "1cv8c.exe /TESTCLIENT -TPort 48151 /F `"$currentBase`""; workingSetMb = 10 },
                    [pscustomobject]@{ processId = 2001; name = "1cv8c.exe"; commandLine = "1cv8c.exe /TESTCLIENT -TPort 48152 /F `"$foreignBase`""; workingSetMb = 10 }
                )
                $script:Runtimes = @(
                    [pscustomobject]@{ family = "vanessa-ui"; instanceId = ("a" * 32); infoBasePath = $currentBase; pid = 3001 },
                    [pscustomobject]@{ family = "vanessa-ui"; instanceId = ("b" * 32); infoBasePath = $foreignBase; pid = 3002 }
                )
                function Get-OneCProcessInfo {
                    @($script:Processes | Where-Object { $script:StoppedIds -notcontains [int]$_.processId })
                }
                function Stop-Process {
                    param([int]$Id, [switch]$Force, [object]$ErrorAction)
                    $script:StoppedIds += $Id
                }
                function Start-Sleep {}
                function Get-ItlOnDemandRuntimeInstances {
                    param([switch]$Strict)
                    @($script:Runtimes)
                }
                function Stop-ItlOnDemandBackendInstance {
                    param([string]$Family, [string]$InstanceId, [switch]$StrictOwnership)
                    $script:Runtimes = @($script:Runtimes | Where-Object { [string]$_.instanceId -ne $InstanceId })
                    [pscustomobject]@{ status = "stopped" }
                }
                function Get-VanessaMcpRuntimeInfo {
                    [pscustomobject]@{ processAlive = $false; pid = 0 }
                }

                $first = Invoke-DevBranchVanessaRuntimeRelease -State $state -Reason "test" 6>$null
                $second = Invoke-DevBranchVanessaRuntimeRelease -State $state -Reason "repeat" 6>$null
                [pscustomobject]@{
                    first = $first
                    second = $second
                    stoppedIds = @($script:StoppedIds)
                    remainingRuntimeIds = @($script:Runtimes | ForEach-Object { [string]$_.instanceId })
                }
            }

            $result.first.status | Should -Be "released"
            $result.first.stoppedTestManager | Should -Be 1
            $result.first.stoppedTestClient | Should -Be 1
            $result.first.stoppedVanessaUiBackend | Should -Be 1
            $result.second.status | Should -Be "released"
            $result.second.stoppedTestManager | Should -Be 0
            $result.second.stoppedTestClient | Should -Be 0
            $result.second.stoppedVanessaUiBackend | Should -Be 0
            $result.stoppedIds | Should -Contain 1001
            $result.stoppedIds | Should -Contain 1002
            $result.stoppedIds | Should -Not -Contain 2001
            $result.remainingRuntimeIds | Should -Be @(("b" * 32))
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "fails closed and reports remaining runtime when backend ownership cannot be verified" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-vanessa-runtime-foreign-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"aiRules":{"tools":["codex"]}}'
            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $base = Join-Path $tempRoot "base"
                $state = [pscustomobject]@{ devBranchInfoBasePath = $base; worktreePath = $tempRoot; safeDevBranchName = "current" }
                $script:ForeignBackendAlive = $true
                $runtime = [pscustomobject]@{ family = "vanessa-ui"; instanceId = ("c" * 32); infoBasePath = $base; pid = 4001 }
                function Get-OneCProcessInfo { @() }
                function Get-ItlOnDemandRuntimeInstances { param([switch]$Strict); @($runtime) }
                function Stop-ItlOnDemandBackendInstance {
                    throw "ITL_ONDEMAND_OWNERSHIP_MISMATCH: refusing foreign PID"
                }
                function Get-VanessaMcpRuntimeInfo { [pscustomobject]@{ processAlive = $false; pid = 0 } }
                $script:ReleaseMessage = ""
                $output = @(& {
                    try {
                        Invoke-DevBranchVanessaRuntimeRelease -State $state -Reason "partial" *>&1
                    } catch {
                        $script:ReleaseMessage = $_.Exception.Message
                    }
                })
                [pscustomobject]@{
                    message = $script:ReleaseMessage
                    output = ($output -join [Environment]::NewLine)
                    foreignBackendAlive = $script:ForeignBackendAlive
                }
            }

            $result.message | Should -Match "^ITL_VANESSA_RUNTIME_RELEASE_FAILED "
            $result.message | Should -Match "remaining=1"
            $result.message | Should -Match "ITL_ONDEMAND_OWNERSHIP_MISMATCH"
            $result.output | Should -Match "Vanessa runtime cleanup remaining owned runtime: 1"
            $result.foreignBackendAlive | Should -BeTrue
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "wires the single release primitive into the explicit stop and infobase lifecycle path" {
        $vanessaText = Get-Content -LiteralPath $VanessaPath -Raw -Encoding UTF8
        $lifecycleText = Get-Content -LiteralPath $LifecyclePath -Raw -Encoding UTF8

        $vanessaText | Should -Match 'function Invoke-DevBranchVanessaRuntimeRelease'
        $vanessaText | Should -Match 'function Stop-DevBranchTestClients[\s\S]*Invoke-DevBranchVanessaRuntimeRelease'
        $lifecycleText | Should -Match 'function Stop-DevBranchRuntimeBeforeInfobaseMutation[\s\S]*Invoke-DevBranchVanessaRuntimeRelease'
        $lifecycleText | Should -Match 'function Save-ReleaseE2EInfobaseSnapshot[\s\S]*Stop-DevBranchRuntimeBeforeInfobaseMutation'
        $lifecycleText | Should -Match 'function Close-DevBranch[\s\S]*Stop-DevBranchRuntimeBeforeInfobaseMutation'
    }

    It "delegates infobase release to the Vanessa primitive and drains ROCTUP separately" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-vanessa-runtime-lifecycle-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"aiRules":{"tools":["codex"]}}'
            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $base = Join-Path $tempRoot "base"
                $state = [pscustomobject]@{ devBranchInfoBasePath = $base }
                $script:VanessaCalls = 0
                $script:VanessaReason = ""
                $script:DrainedFamily = ""
                $script:DrainedBase = ""
                function Set-RunStage {}
                function Invoke-DevBranchVanessaRuntimeRelease {
                    param([object]$State, [string]$Reason)
                    $script:VanessaCalls++
                    $script:VanessaReason = $Reason
                    [pscustomobject]@{ status = "released" }
                }
                function Stop-ItlOnDemandBackends {
                    param([string]$Family, [string]$InfoBasePath, [switch]$Strict)
                    $script:DrainedFamily = $Family
                    $script:DrainedBase = $InfoBasePath
                }
                function Get-RoctupMcpRuntimeInfo { [pscustomobject]@{ processAlive = $false } }
                function Get-OwnVanessaTestProcesses { @() }
                function Get-ItlOnDemandRuntimeInstances { param([switch]$Strict); @() }

                Stop-DevBranchRuntimeBeforeInfobaseMutation -State $state -Reason "fixture mutation" 6>$null
                [pscustomobject]@{
                    vanessaCalls = $script:VanessaCalls
                    reason = $script:VanessaReason
                    family = $script:DrainedFamily
                    infoBasePath = $script:DrainedBase
                }
            }

            $result.vanessaCalls | Should -Be 1
            $result.reason | Should -Be "fixture mutation"
            $result.family | Should -Be "roctup"
            $result.infoBasePath | Should -Be (Join-Path $tempRoot "base")
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
