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

    It "captures native stdout and stderr independently without treating informational stderr as failure" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-vanessa-profile-capture-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"aiRules":{"tools":["codex"]}}'
            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $child = "[Console]::Out.WriteLine('ITL_MARKER=ok'); [Console]::Error.WriteLine('informational diagnostic'); exit 0"
                $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($child))
                Invoke-ItlNativeProcessCapture -FilePath "powershell.exe" -Arguments @("-NoProfile", "-EncodedCommand", $encoded)
            }
            $result.exitCode | Should -Be 0
            $result.stdout | Should -Match "ITL_MARKER=ok"
            $result.stderr | Should -Match "informational diagnostic"
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "parses the profile marker only from stdout when stderr is informational" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-vanessa-profile-stdout-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"aiRules":{"tools":["codex"]}}'
            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                function Get-ItlOnDemandMcpExecutablePath { return "fixture.exe" }
                function Get-ItlOnDemandMcpFamilyDefinition { return [pscustomobject]@{ catalogPath = "catalog.json" } }
                function Invoke-ItlNativeProcessCapture {
                    return [pscustomobject]@{
                        exitCode = 0
                        stdout = "ITL_VANESSA_PROFILE_RESULT={`"status`":`"running`",`"testClientState`":`"manager-connected`"}`r`n"
                        stderr = '{"level":"INFO","stage":"broker-start"}'
                    }
                }
                Invoke-ItlOnDemandVanessaProfileStart -InstanceId ("e" * 32) -FeaturePath (Join-Path $tempRoot "manual.feature")
            }
            $result.status | Should -Be "running"
            $result.testClientState | Should -Be "manager-connected"
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "returns a bounded redacted broker cause, log path, and required action on profile start failure" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-vanessa-profile-diagnostic-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"aiRules":{"tools":["codex"]}}'
            $logPath = Join-Path $tempRoot "broker startup.log"
            Set-Content -LiteralPath $logPath -Encoding UTF8 -Value "license is not available password=log-secret configuration=private-data"
            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $script:RunErrorCategory = ""
                $script:RunRequiredAction = ""
                function Get-ItlOnDemandMcpExecutablePath { return "fixture.exe" }
                function Get-ItlOnDemandMcpFamilyDefinition { return [pscustomobject]@{ catalogPath = "catalog.json" } }
                function Invoke-ItlNativeProcessCapture {
                    return [pscustomobject]@{
                        exitCode = 17
                        stdout = ""
                        stderr = "backend broker ensure failed token=stderr-secret; log=$logPath"
                    }
                }
                $message = ""
                try {
                    Invoke-ItlOnDemandVanessaProfileStart -InstanceId ("f" * 32) -FeaturePath (Join-Path $tempRoot "manual.feature") | Out-Null
                } catch {
                    $message = $_.Exception.Message
                }
                [pscustomobject]@{
                    message = $message
                    category = $script:RunErrorCategory
                    requiredAction = $script:RunRequiredAction
                }
            }
            $result.message | Should -Match "^ITL_VANESSA_PROFILE_START_FAILED: exitCode=17"
            $result.message | Should -Match ([regex]::Escape("brokerLog=$logPath"))
            $result.message | Should -Match "license is not available"
            $result.message | Should -Match "retryAction=start-vanessa-profile"
            $result.message | Should -Not -Match "stderr-secret|log-secret|private-data"
            $result.message.Length | Should -BeLessThan 3800
            $result.category | Should -Be "runner"
            $result.requiredAction | Should -Be "release-1c-license-and-retry-start-vanessa-profile"
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
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
                        testClientReused = ($script:TransportCalls -eq 2); scenarioWasStarted = $false
                        ownerId = $(if ($script:TransportCalls -le 2) { 'chat-a' } else { 'chat-b' })
                        ownerGeneration = $(if ($script:TransportCalls -le 2) { 'b'*32 } else { 'c'*32 })
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
                $script:ProfileMarker.startedAt = '2000-01-01T00:00:00Z'
                $third = Start-DevBranchVanessaInteractiveProfile 6>$null
                [pscustomobject]@{
                    first = $first
                    second = $second
                    third = $third
                    thirdStartedAt = $script:ProfileMarker.startedAt
                    firstInstance = $firstInstance
                    secondInstance = [string]$script:ProfileMarker.instanceId
                    calls = $script:TransportCalls
                    reportJson = [string]$script:RunUserReport
                }
            }

            $result.first.action | Should -Be "started"
            $result.second.action | Should -Be "reused"
            $result.firstInstance | Should -Be $result.secondInstance
            $result.calls | Should -Be 3
            $result.third.action | Should -Be 'started'
            $result.third.ownerId | Should -Be 'chat-b'
            $result.thirdStartedAt | Should -Not -Be '2000-01-01T00:00:00Z'
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

    It "propagates an actual platform license startup failure without writing profile ownership" {
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
                function Invoke-ItlOnDemandVanessaProfileStart { throw "ITL_VANESSA_PLATFORM_LICENSE_UNAVAILABLE: TestClient startup log reports no platform license" }
                function Write-VanessaInteractiveProfileState { $script:Writes++ }
                $message = ""
                try { Start-DevBranchVanessaInteractiveProfile 6>$null } catch { $message = $_.Exception.Message }
                [pscustomobject]@{ message = $message; writes = $script:Writes }
            }
            $result.message | Should -Match "ITL_VANESSA_PLATFORM_LICENSE_UNAVAILABLE"
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

Describe 'Explicit interactive profile caller propagation' {
    BeforeAll {
        $repo = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
        $lib = Join-Path $repo '.agents/skills/1c-workflow/scripts/lib'
        foreach ($name in @('core','runtime-values','vanessa','ondemand-mcp')) { . (Join-Path $lib ("agent-1c.$name.ps1")) }
    }
    BeforeEach {
        $script:ProjectRoot = $TestDrive
        $script:Agent1cScriptPath = Join-Path $repo '.agents/skills/1c-workflow/scripts/agent-1c.ps1'
        $script:VanessaProfileOwnerId = $null
        Mock Get-ItlOnDemandMcpExecutablePath { 'fixture.exe' }
        Mock Get-ItlOnDemandMcpFamilyDefinition { [pscustomobject]@{catalogPath='catalog.json'} }
        Mock Invoke-ItlNativeProcessCapture {
            param($FilePath,$Arguments)
            $script:capturedProfileArguments = @($Arguments)
            $marker = $(if ($Arguments[0] -eq 'vanessa-profile-start') { 'ITL_VANESSA_PROFILE_RESULT=' } else { 'ITL_VANESSA_PROFILE_OWNER_RESULT=' })
            [pscustomobject]@{exitCode=0;stderr='';stdout=($marker + '{"schemaVersion":1,"generation":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","status":"stopped","cleanupConfirmed":true}')}
        }
    }
    AfterEach { $script:VanessaProfileOwnerId = $null }

    It 'forwards an explicit session ID through both start and stop' {
        $script:VanessaProfileOwnerId = 'manual-session'
        Invoke-ItlOnDemandVanessaProfileStart -InstanceId ('a'*32) -FeaturePath 'feature.feature' | Out-Null
        $script:capturedProfileArguments | Should -Contain '--caller-id'
        $script:capturedProfileArguments | Should -Contain 'manual-session'
        Invoke-VanessaInteractiveProfileOwnerControl -Operation stop -Owner ([pscustomobject]@{instanceId=('a'*32);generation=('b'*32);callerId='manual-session'}) | Out-Null
        $script:capturedProfileArguments | Should -Contain 'manual-session'
    }

    It 'does not adopt a foreign caller ID from the branch descriptor' {
        Invoke-VanessaInteractiveProfileOwnerControl -Operation stop -Owner ([pscustomobject]@{instanceId=('a'*32);generation=('b'*32);callerId='foreign-chat'}) | Out-Null
        $script:capturedProfileArguments | Should -Not -Contain '--caller-id'
        $script:capturedProfileArguments | Should -Not -Contain 'foreign-chat'
    }
}

Describe 'Persistent interactive profile owner routing' {
    BeforeAll {
        $repo = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
        $lib = Join-Path $repo '.agents/skills/1c-workflow/scripts/lib'
        foreach ($name in @('core', 'runtime-values', 'lifecycle', 'roctup-mcp', 'vanessa', 'ondemand-mcp')) {
            . (Join-Path $lib ("agent-1c.$name.ps1"))
        }
    }
    BeforeEach {
        $script:ProjectRoot = Join-Path $TestDrive ('Ручной профиль с пробелом ' + [guid]::NewGuid().ToString('N'))
        $script:DevBranchName = 'profile'
        $owner = [pscustomobject]@{schemaVersion=1;projectRoot=$script:ProjectRoot;instanceId=('a'*32);generation=('b'*32);status='running'}
        $profile = [pscustomobject]@{schemaVersion=1;instanceId=$owner.instanceId;ownerGeneration=$owner.generation}
        $ownerPath = Join-Path $script:ProjectRoot '.agent-1c/mcp/vanessa-profile-owner/owner.json'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ownerPath) | Out-Null
        $owner | ConvertTo-Json | Set-Content -LiteralPath $ownerPath -Encoding UTF8
        $profilePath = Get-VanessaInteractiveProfileStatePath
        $profile | ConvertTo-Json | Set-Content -LiteralPath $profilePath -Encoding UTF8
        $baseState = [pscustomobject]@{devBranchInfoBasePath=(Join-Path $script:ProjectRoot 'база профиля');worktreePath=$script:ProjectRoot;safeDevBranchName='profile'}
        Mock Read-DevBranchState { $baseState }
        Mock Read-CurrentDevBranchStateForVanessaMcp { $baseState }
        Mock Assert-DevelopmentBranchWorktreeContext { }
        Mock Read-ItlOnDemandRuntimeState { $null }
        Mock Test-ItlOnDemandOwnedProcess { $false }
        Mock Get-ItlOnDemandOwnedTestClientProcesses { @() }
        Mock Get-VanessaInteractiveProfileRuntimeInstances { @() }
        Mock Invoke-DevBranchVanessaRuntimeRelease { throw 'The owner must stop only its exact profile.' }
        Mock Invoke-VanessaInteractiveProfileOwnerControl { [pscustomobject]@{schemaVersion=1;generation=$owner.generation;status='stopped';cleanupConfirmed=$true} }
        Mock New-VanessaInteractiveProfileUserReport { param($Action,$Status) [pscustomobject]@{action=$Action;status=$Status} }
        Mock Publish-VanessaInteractiveProfileUserReport { param($Report) $Report }
    }

    It 'delegates stop without taking the lock needed by the persistent owner and keeps legacy locking' {
        Test-Agent1cActionRequiresLifecycleLock -RequestedAction stop-vanessa-profile | Should -BeFalse
        (Stop-DevBranchVanessaInteractiveProfile).status | Should -Be 'stopped'
        Test-Path -LiteralPath $profilePath | Should -BeFalse
        Should -Invoke Invoke-VanessaInteractiveProfileOwnerControl -Times 1 -ParameterFilter { $Operation -eq 'stop' -and $Owner.instanceId -eq ('a'*32) }
        Should -Invoke Invoke-DevBranchVanessaRuntimeRelease -Times 0
        Remove-Item -LiteralPath $ownerPath
        Test-Agent1cActionRequiresLifecycleLock -RequestedAction stop-vanessa-profile | Should -BeTrue
    }

    It 'retains the marker on failed cleanup and does not fall back to a branch-wide stop' {
        Mock Invoke-VanessaInteractiveProfileOwnerControl { [pscustomobject]@{schemaVersion=1;generation=$owner.generation;status='needs-attention';cleanupConfirmed=$false} }
        { Stop-DevBranchVanessaInteractiveProfile } | Should -Throw '*STOP_UNCONFIRMED*'
        (Read-VanessaInteractiveProfileState -Strict).ownerGeneration | Should -Be $owner.generation
        Should -Invoke Invoke-DevBranchVanessaRuntimeRelease -Times 0
    }

    It 'rejects stale generation before sending any stop command' {
        $profile.ownerGeneration = 'c'*32
        $profile | ConvertTo-Json | Set-Content -LiteralPath $profilePath -Encoding UTF8
        { Stop-DevBranchVanessaInteractiveProfile } | Should -Throw '*GENERATION_CHANGED*'
        (Read-VanessaInteractiveProfileState -Strict).ownerGeneration | Should -Be ('c'*32)
        Should -Invoke Invoke-VanessaInteractiveProfileOwnerControl -Times 0
        Should -Invoke Invoke-DevBranchVanessaRuntimeRelease -Times 0
    }

    It 'rejects a successful control response when native registration still remains' {
        Mock Read-ItlOnDemandRuntimeState { [pscustomobject]@{instanceId=$owner.instanceId;pid=4242} }
        { Stop-DevBranchVanessaInteractiveProfile } | Should -Throw '*STOP_UNCONFIRMED*'
        Test-Path -LiteralPath $profilePath | Should -BeTrue
    }

    It 'reports unconfirmed owner cleanup even when the native runtime file disappeared' {
        Mock Invoke-VanessaInteractiveProfileOwnerControl { [pscustomobject]@{schemaVersion=1;generation=$owner.generation;status='owner-exited-unconfirmed';cleanupConfirmed=$false} }
        (Show-DevBranchVanessaInteractiveProfile).status | Should -Be 'owner-exited-unconfirmed'
        Should -Invoke Invoke-VanessaInteractiveProfileOwnerControl -Times 1 -ParameterFilter { $Operation -eq 'status' }
    }

    It 'keeps a later legacy profile on its normal lifecycle despite a retained stopped owner descriptor' {
        $owner.status='stopped'
        $owner | ConvertTo-Json | Set-Content -LiteralPath $ownerPath -Encoding UTF8
        [pscustomobject]@{schemaVersion=1;instanceId=('d'*32)} | ConvertTo-Json | Set-Content -LiteralPath $profilePath -Encoding UTF8
        Test-VanessaInteractiveProfileHasOwner | Should -BeFalse
        Test-Agent1cActionRequiresLifecycleLock -RequestedAction stop-vanessa-profile | Should -BeTrue
    }
}
