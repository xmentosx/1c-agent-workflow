$ErrorActionPreference = "Stop"

Describe "Interactive Vanessa profiling lifecycle" {
    BeforeAll {
        $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
        $HelperPath = Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\agent-1c.ps1"
        $CorePath = Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.core.ps1"
        $VanessaPath = Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.vanessa.ps1"
        $FacadePath = Join-Path $RepoRoot "tools\itl-ondemand-mcp\vanessa_profile.go"
    }

    It "exposes a compact start status stop contract without changing verification commands" {
        $helperText = Get-Content -LiteralPath $HelperPath -Raw -Encoding UTF8
        $coreText = Get-Content -LiteralPath $CorePath -Raw -Encoding UTF8
        $vanessaText = Get-Content -LiteralPath $VanessaPath -Raw -Encoding UTF8
        $facadeText = Get-Content -LiteralPath $FacadePath -Raw -Encoding UTF8

        foreach ($action in @("start-vanessa-profile", "status-vanessa-profile", "stop-vanessa-profile")) {
            $helperText | Should -Match ([regex]::Escape('"' + $action + '"'))
        }
        $coreText | Should -Match '"start-vanessa-profile"'
        $coreText | Should -Match '"status-vanessa-profile"'
        $vanessaText | Should -Match 'function Stop-DevBranchVanessaInteractiveProfile[\s\S]*Invoke-DevBranchVanessaRuntimeRelease'
        $facadeText | Should -Match '"connect_test_client"'
        $facadeText | Should -Match '"open_feature_file"'
        $facadeText | Should -Not -Match '"run_scenario"'
        $facadeText | Should -Match 'suppressEvidence:\s*true'
        $helperText | Should -Match '"check-dev-branch" \{ Check-DevBranch \}'
        $helperText | Should -Match '"verify-dev-branch" \{ Verify-DevBranch \}'
    }

    It "starts one owned pair, reuses its markers, and emits only a safe persistent report" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-vanessa-profile-start-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"aiRules":{"tools":["codex"]}}'
            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $state = [pscustomobject]@{
                    devBranchInfoBasePath = (Join-Path $tempRoot "base")
                    worktreePath = $tempRoot
                    stateProjectRoot = $tempRoot
                    safeDevBranchName = "profile"
                    infoBaseKind = "file"
                }
                $script:ProfileMarker = $null
                $script:Runtime = $null
                $script:TransportCalls = 0
                function Read-CurrentDevBranchStateForVanessaMcp { return $state }
                function Assert-DevelopmentBranchWorktreeContext {}
                function Resolve-VanessaInteractiveFeaturePath { return (Join-Path $tempRoot "manual.feature") }
                function Read-VanessaInteractiveProfileState { return $script:ProfileMarker }
                function Get-VanessaInteractiveProfileRuntimeInstances {
                    if ($null -eq $script:Runtime) { return @() }
                    return @($script:Runtime)
                }
                function Get-ItlOnDemandBackendRuntimeHealth {
                    [pscustomobject]@{ owned = $true; status = "healthy" }
                }
                function Get-OwnVanessaTestProcesses { return @() }
                function Invoke-ItlOnDemandVanessaProfileStart {
                    param([string]$InstanceId, [string]$FeaturePath)
                    $script:TransportCalls++
                    $script:Runtime = [pscustomobject]@{
                        family = "vanessa-ui"; instanceId = $InstanceId; infoBasePath = $state.devBranchInfoBasePath
                        pid = 5101; port = 9874; testClientPid = 5102; testClientPort = 48151; testClientState = "port-ready"
                    }
                    [pscustomobject]@{
                        status = "running"; instanceId = $InstanceId; managerPid = 5101; managerPort = 9874
                        testClientPid = 5102; testClientPort = 48151; testClientState = "manager-connected"
                        testClientReused = ($script:TransportCalls -gt 1); scenarioWasStarted = $false
                    }
                }
                function Read-ItlOnDemandRuntimeState { return $script:Runtime }
                function Test-ItlOnDemandOwnedProcess { return $true }
                function Get-ItlOnDemandOwnedTestClientProcesses {
                    return @([pscustomobject]@{ process = [pscustomobject]@{ Id = 5102 } })
                }
                function Write-VanessaInteractiveProfileState {
                    param([object]$ProfileState)
                    $script:ProfileMarker = $ProfileState
                    return "profile.json"
                }

                $first = Start-DevBranchVanessaInteractiveProfile 6>$null
                $firstInstance = [string]$script:ProfileMarker.instanceId
                $second = Start-DevBranchVanessaInteractiveProfile 6>$null
                [pscustomobject]@{
                    first = $first
                    second = $second
                    firstInstance = $firstInstance
                    secondInstance = [string]$script:ProfileMarker.instanceId
                    calls = $script:TransportCalls
                    reportJson = [string]$script:RunUserReport
                }
            }

            $result.first.action | Should -Be "started"
            $result.second.action | Should -Be "reused"
            $result.firstInstance | Should -Be $result.secondInstance
            $result.calls | Should -Be 2
            $report = $result.reportJson | ConvertFrom-Json
            $report.status | Should -Be "running"
            $report.managerPid | Should -Be 5101
            $report.managerPort | Should -Be 9874
            $report.testClientPid | Should -Be 5102
            $report.testClientPort | Should -Be 48151
            $report.connectionState | Should -Be "manager-connected"
            $report.persistentUntilExplicitStop | Should -BeTrue
            $report.scenarioStarted | Should -BeFalse
            $report.verificationVerdictProduced | Should -BeFalse
            $result.reportJson | Should -Not -Match '(?i)(password|secret|token|logPath|junit)'
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "keeps start on the shared facade lease, status read-only, and stop lifecycle-locked" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-vanessa-profile-status-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"aiRules":{"tools":["codex"]}}'
            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $state = [pscustomobject]@{ devBranchInfoBasePath = (Join-Path $tempRoot "base"); worktreePath = $tempRoot; safeDevBranchName = "profile" }
                $profile = [pscustomobject]@{ featurePath = (Join-Path $tempRoot "manual.feature"); testClientState = "manager-connected" }
                $runtime = [pscustomobject]@{
                    family = "vanessa-ui"; instanceId = ("a" * 32); infoBasePath = $state.devBranchInfoBasePath
                    pid = 5301; port = 9874; testClientPid = 5302; testClientPort = 48151
                }
                function Read-CurrentDevBranchStateForVanessaMcp { return $state }
                function Assert-DevelopmentBranchWorktreeContext {}
                function Read-VanessaInteractiveProfileState { return $profile }
                function Get-VanessaInteractiveProfileRuntimeInstances { return @($runtime) }
                function Get-ItlOnDemandBackendRuntimeHealth { [pscustomobject]@{ owned = $true; status = "healthy" } }
                function Get-ItlOnDemandOwnedTestClientProcesses {
                    return @([pscustomobject]@{ process = [pscustomobject]@{ Id = 5302 } })
                }
                $report = Show-DevBranchVanessaInteractiveProfile 6>$null
                [pscustomobject]@{
                    startLocked = Test-Agent1cActionRequiresLifecycleLock -RequestedAction "start-vanessa-profile"
                    statusLocked = Test-Agent1cActionRequiresLifecycleLock -RequestedAction "status-vanessa-profile"
                    stopLocked = Test-Agent1cActionRequiresLifecycleLock -RequestedAction "stop-vanessa-profile"
                    report = $report
                }
            }
            $result.startLocked | Should -BeFalse
            $result.statusLocked | Should -BeFalse
            $result.stopLocked | Should -BeTrue
            $result.report.status | Should -Be "running"
            $result.report.connectionState | Should -Be "manager-connected"
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "propagates the shared capacity failure without writing profile ownership" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-vanessa-profile-capacity-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"aiRules":{"tools":["codex"]}}'
            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $state = [pscustomobject]@{ devBranchInfoBasePath = (Join-Path $tempRoot "base"); worktreePath = $tempRoot; safeDevBranchName = "profile" }
                $script:Writes = 0
                function Read-CurrentDevBranchStateForVanessaMcp { return $state }
                function Assert-DevelopmentBranchWorktreeContext {}
                function Resolve-VanessaInteractiveFeaturePath { return (Join-Path $tempRoot "manual.feature") }
                function Read-VanessaInteractiveProfileState { return $null }
                function Get-VanessaInteractiveProfileRuntimeInstances { return @() }
                function Get-OwnVanessaTestProcesses { return @() }
                function Invoke-ItlOnDemandVanessaProfileStart { throw "ITL_VANESSA_LICENSE_LIMIT: capacity=2 active=2" }
                function Write-VanessaInteractiveProfileState { $script:Writes++ }
                $message = ""
                try { Start-DevBranchVanessaInteractiveProfile 6>$null } catch { $message = $_.Exception.Message }
                [pscustomobject]@{ message = $message; writes = $script:Writes }
            }
            $result.message | Should -Match "ITL_VANESSA_LICENSE_LIMIT"
            $result.writes | Should -Be 0
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "fails closed on an unregistered current-branch process and leaves it untouched" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-vanessa-profile-foreign-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"aiRules":{"tools":["codex"]}}'
            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $state = [pscustomobject]@{ devBranchInfoBasePath = (Join-Path $tempRoot "base"); worktreePath = $tempRoot; safeDevBranchName = "profile" }
                $script:TransportCalls = 0
                $script:ForeignAlive = $true
                function Read-CurrentDevBranchStateForVanessaMcp { return $state }
                function Assert-DevelopmentBranchWorktreeContext {}
                function Resolve-VanessaInteractiveFeaturePath { return (Join-Path $tempRoot "manual.feature") }
                function Read-VanessaInteractiveProfileState { return $null }
                function Get-VanessaInteractiveProfileRuntimeInstances { return @() }
                function Get-OwnVanessaTestProcesses {
                    return @([pscustomobject]@{ processId = 6201; commandLine = "1cv8c.exe /TESTCLIENT" })
                }
                function Invoke-ItlOnDemandVanessaProfileStart { $script:TransportCalls++ }
                $message = ""
                try { Start-DevBranchVanessaInteractiveProfile 6>$null } catch { $message = $_.Exception.Message }
                [pscustomobject]@{ message = $message; transportCalls = $script:TransportCalls; foreignAlive = $script:ForeignAlive }
            }
            $result.message | Should -Match "ITL_VANESSA_PROFILE_OWNERSHIP_UNVERIFIED"
            $result.transportCalls | Should -Be 0
            $result.foreignAlive | Should -BeTrue
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "does not adopt an owned manager that lacks the interactive profile marker" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-vanessa-profile-unmarked-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"aiRules":{"tools":["codex"]}}'
            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $state = [pscustomobject]@{ devBranchInfoBasePath = (Join-Path $tempRoot "base"); worktreePath = $tempRoot; safeDevBranchName = "profile" }
                $runtime = [pscustomobject]@{ family = "vanessa-ui"; instanceId = ("b" * 32); infoBasePath = $state.devBranchInfoBasePath; pid = 6301; port = 9874 }
                $script:TransportCalls = 0
                function Read-CurrentDevBranchStateForVanessaMcp { return $state }
                function Assert-DevelopmentBranchWorktreeContext {}
                function Resolve-VanessaInteractiveFeaturePath { return (Join-Path $tempRoot "manual.feature") }
                function Read-VanessaInteractiveProfileState { return $null }
                function Get-VanessaInteractiveProfileRuntimeInstances { return @($runtime) }
                function Invoke-ItlOnDemandVanessaProfileStart { $script:TransportCalls++ }
                $message = ""
                try { Start-DevBranchVanessaInteractiveProfile 6>$null } catch { $message = $_.Exception.Message }
                [pscustomobject]@{ message = $message; transportCalls = $script:TransportCalls }
            }
            $result.message | Should -Match "ITL_VANESSA_PROFILE_RUNTIME_CONFLICT"
            $result.message | Should -Match "no interactive-profile marker"
            $result.transportCalls | Should -Be 0
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "stops through the shared release primitive and makes repeated stop explicit" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-vanessa-profile-stop-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"aiRules":{"tools":["codex"]}}'
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\vanessa-interactive-profile.json") -Encoding UTF8 -Value '{"schemaVersion":1,"instanceId":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}'
            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $state = [pscustomobject]@{ devBranchInfoBasePath = (Join-Path $tempRoot "base"); worktreePath = $tempRoot; safeDevBranchName = "profile" }
                $script:ReleaseCalls = 0
                $script:ForeignAlive = $true
                function Read-DevBranchState { return $state }
                function Assert-DevelopmentBranchWorktreeContext {}
                function Invoke-DevBranchVanessaRuntimeRelease {
                    $script:ReleaseCalls++
                    if ($script:ReleaseCalls -eq 1) {
                        return [pscustomobject]@{ stoppedTestManager = 1; stoppedTestClient = 1; stoppedVanessaUiBackend = 1 }
                    }
                    return [pscustomobject]@{ stoppedTestManager = 0; stoppedTestClient = 0; stoppedVanessaUiBackend = 0 }
                }
                $first = Stop-DevBranchVanessaInteractiveProfile 6>$null
                $second = Stop-DevBranchVanessaInteractiveProfile 6>$null
                [pscustomobject]@{
                    first = $first
                    second = $second
                    calls = $script:ReleaseCalls
                    foreignAlive = $script:ForeignAlive
                    markerExists = Test-Path -LiteralPath (Get-VanessaInteractiveProfileStatePath)
                }
            }
            $result.first.action | Should -Be "stopped"
            $result.second.action | Should -Be "already-stopped"
            $result.calls | Should -Be 2
            $result.foreignAlive | Should -BeTrue
            $result.markerExists | Should -BeFalse
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
