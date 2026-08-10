Describe "Per-infobase 1C session admission" {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        $RepoRoot = $context.RepoRoot
        $HelperPath = $context.HelperPath
        $CorePath = Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.core.ps1"
        $LifecyclePath = Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.lifecycle.ps1"
        $SessionPath = Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.sessions.ps1"
    }

    It "defaults to three, accepts zero as unlimited, and rejects invalid values" {
        $result = & {
            $saved = $env:ONEC_MAX_CONCURRENT_SESSIONS
            $savedPrefixed = $env:AGENT_1C_ONEC_MAX_CONCURRENT_SESSIONS
            try {
                $env:ONEC_MAX_CONCURRENT_SESSIONS = $null
                $env:AGENT_1C_ONEC_MAX_CONCURRENT_SESSIONS = $null
                . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
                $defaultValue = Get-OneCMaxConcurrentSessions
                $env:ONEC_MAX_CONCURRENT_SESSIONS = "0"
                $unlimitedValue = Get-OneCMaxConcurrentSessions
                $messages = @()
                foreach ($value in @("-1", "1.5", "many", "1025")) {
                    $env:ONEC_MAX_CONCURRENT_SESSIONS = $value
                    try { Get-OneCMaxConcurrentSessions | Out-Null } catch { $messages += $_.Exception.Message }
                }
                [pscustomobject]@{ defaultValue = $defaultValue; unlimitedValue = $unlimitedValue; messages = @($messages) }
            } finally {
                $env:ONEC_MAX_CONCURRENT_SESSIONS = $saved
                $env:AGENT_1C_ONEC_MAX_CONCURRENT_SESSIONS = $savedPrefixed
            }
        }

        $result.defaultValue | Should -Be 3
        $result.unlimitedValue | Should -Be 0
        @($result.messages).Count | Should -Be 4
        @($result.messages | Where-Object { $_ -match "ONEC_MAX_CONCURRENT_SESSIONS" }).Count | Should -Be 4
    }

    It "matches file and server infobases exactly instead of by path substring" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $base = Join-Path ([IO.Path]::GetTempPath()) "itl session base"
            $other = $base + "-other"
            [pscustomobject]@{
                fileExact = Test-OneCCommandLineInfoBasePath -CommandLine "1cv8.exe DESIGNER /F `"$base`" /N user" -InfoBasePath $base -InfoBaseKind file
                fileOther = Test-OneCCommandLineInfoBasePath -CommandLine "1cv8.exe ENTERPRISE /F `"$other`"" -InfoBasePath $base -InfoBaseKind file
                serverExact = Test-OneCCommandLineInfoBasePath -CommandLine '1cv8c.exe ENTERPRISE /S "srv\base"' -InfoBasePath 'SRV\BASE' -InfoBaseKind server
                serverOther = Test-OneCCommandLineInfoBasePath -CommandLine '1cv8c.exe ENTERPRISE /S "srv\base2"' -InfoBasePath 'srv\base' -InfoBaseKind server
            }
        }

        $result.fileExact | Should -BeTrue
        $result.fileOther | Should -BeFalse
        $result.serverExact | Should -BeTrue
        $result.serverOther | Should -BeFalse
    }

    It "adds the explicit default to an existing project env without overriding a configured value" {
        $result = & {
            $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-session-env-" + [guid]::NewGuid().ToString("N"))
            $savedRoot = $script:ProjectRoot
            $savedLimit = $env:ONEC_MAX_CONCURRENT_SESSIONS
            $savedPlatformPath = $env:PLATFORM_PATH
            try {
                New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
                Set-Content -LiteralPath (Join-Path $tempRoot ".dev.env") -Encoding UTF8 -Value "PLATFORM_PATH=C:\fake\1cv8.exe"
                . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
                $script:ProjectRoot = $tempRoot
                $added = Ensure-OneCSessionLimitDotEnv
                $first = Get-Content -LiteralPath (Join-Path $tempRoot ".dev.env") -Raw -Encoding UTF8
                Set-DotEnvValues -Values @{ ONEC_MAX_CONCURRENT_SESSIONS = 5 }
                $addedAgain = Ensure-OneCSessionLimitDotEnv
                $second = Get-Content -LiteralPath (Join-Path $tempRoot ".dev.env") -Raw -Encoding UTF8
                [pscustomobject]@{ added = $added; addedAgain = $addedAgain; first = $first; second = $second }
            } finally {
                $script:ProjectRoot = $savedRoot
                $env:ONEC_MAX_CONCURRENT_SESSIONS = $savedLimit
                $env:PLATFORM_PATH = $savedPlatformPath
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        $result.added | Should -BeTrue
        $result.addedAgain | Should -BeFalse
        $result.first | Should -Match "(?m)^ONEC_MAX_CONCURRENT_SESSIONS=3\r?$"
        $result.second | Should -Match "(?m)^ONEC_MAX_CONCURRENT_SESSIONS=5\r?$"
        @([regex]::Matches($result.second, "(?m)^ONEC_MAX_CONCURRENT_SESSIONS=")).Count | Should -Be 1
    }

    It "blocks a fourth process when Configurator, TestManager, and TestClient already use the base" {
        $message = & {
            $saved = $env:ONEC_MAX_CONCURRENT_SESSIONS
            try {
                $env:ONEC_MAX_CONCURRENT_SESSIONS = "3"
                . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
                $base = Join-Path ([IO.Path]::GetTempPath()) "itl-session-limit-full"
                $script:FixtureProcesses = @(
                    [pscustomobject]@{ processId = 101; commandLine = "1cv8.exe DESIGNER /F `"$base`"" },
                    [pscustomobject]@{ processId = 102; commandLine = "1cv8c.exe ENTERPRISE /TESTMANAGER /F `"$base`"" },
                    [pscustomobject]@{ processId = 103; commandLine = "1cv8c.exe ENTERPRISE /TESTCLIENT /F `"$base`"" }
                )
                function Get-OneCProcessInfo { return @($script:FixtureProcesses) }
                function Invoke-ItlPortRegistryLock { param([scriptblock]$ScriptBlock) & $ScriptBlock }
                function Read-OneCSessionRegistry { return [pscustomobject]@{ schemaVersion = 1; reservations = @() } }
                function Write-OneCSessionRegistry { param([object[]]$Reservations) }
                try {
                    Invoke-OneCSessionAdmission -InfoBaseKind file -InfoBasePath $base -Purpose roctup -StartProcess { [pscustomobject]@{ Id = 104 } } | Out-Null
                    ""
                } catch { $_.Exception.Message }
            } finally { $env:ONEC_MAX_CONCURRENT_SESSIONS = $saved }
        }

        $message | Should -Match "^ITL_ONEC_SESSION_LIMIT: max=3 active=3 reserved=0 required=1"
        $message | Should -Match "configurator"
        $message | Should -Match "test-manager"
        $message | Should -Match "test-client"
        $message | Should -Match "errorCategory=session-capacity"
        $message | Should -Match "requiredAction=finish-or-close-owned-sessions-before-retry"
        $message | Should -Match "limitChange=developer-only"
    }

    It "does not count sessions connected to another exact infobase" {
        $result = & {
            $saved = $env:ONEC_MAX_CONCURRENT_SESSIONS
            try {
                $env:ONEC_MAX_CONCURRENT_SESSIONS = "3"
                . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
                $base = Join-Path ([IO.Path]::GetTempPath()) "itl-session-current"
                $other = Join-Path ([IO.Path]::GetTempPath()) "itl-session-other"
                $script:FixtureProcesses = @(
                    [pscustomobject]@{ processId = 111; commandLine = "1cv8.exe DESIGNER /F `"$other`"" },
                    [pscustomobject]@{ processId = 112; commandLine = "1cv8c.exe ENTERPRISE /TESTMANAGER /F `"$other`"" },
                    [pscustomobject]@{ processId = 113; commandLine = "1cv8c.exe ENTERPRISE /TESTCLIENT /F `"$other`"" }
                )
                function Get-OneCProcessInfo { return @($script:FixtureProcesses) }
                function Invoke-ItlPortRegistryLock { param([scriptblock]$ScriptBlock) & $ScriptBlock }
                function Read-OneCSessionRegistry { return [pscustomobject]@{ schemaVersion = 1; reservations = @() } }
                function Write-OneCSessionRegistry { param([object[]]$Reservations) }
                Invoke-OneCSessionAdmission -InfoBaseKind file -InfoBasePath $base -Purpose roctup -StartProcess { [pscustomobject]@{ Id = 114 } }
            } finally { $env:ONEC_MAX_CONCURRENT_SESSIONS = $saved }
        }

        $result.Id | Should -Be 114
    }

    It "admits one manager and one TestClient next to one existing session on the same base" {
        $result = & {
            $saved = $env:ONEC_MAX_CONCURRENT_SESSIONS
            try {
                $env:ONEC_MAX_CONCURRENT_SESSIONS = "3"
                . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
                $base = Join-Path ([IO.Path]::GetTempPath()) "itl-session-roctup-plus-vanessa"
                $script:FixtureProcesses = @(
                    [pscustomobject]@{ processId = 121; commandLine = "1cv8c.exe ENTERPRISE /F `"$base`"" }
                )
                function Get-OneCProcessInfo { return @($script:FixtureProcesses) }
                function Invoke-ItlPortRegistryLock { param([scriptblock]$ScriptBlock) & $ScriptBlock }
                function Read-OneCSessionRegistry { return [pscustomobject]@{ schemaVersion = 1; reservations = @() } }
                function Write-OneCSessionRegistry { param([object[]]$Reservations) $script:WrittenReservations = @($Reservations) }
                $script:WrittenReservations = @()
                $started = Invoke-OneCSessionAdmission `
                    -InfoBaseKind file `
                    -InfoBasePath $base `
                    -RequiredSessions 2 `
                    -ExpectedChildRole test-client `
                    -Purpose test-manager-run `
                    -StartProcess { [pscustomobject]@{ Id = 122 } }
                [pscustomobject]@{ process = $started; reservations = @($script:WrittenReservations) }
            } finally { $env:ONEC_MAX_CONCURRENT_SESSIONS = $saved }
        }

        $result.process.Id | Should -Be 122
        $result.reservations[-1].requiredSessions | Should -Be 2
        $result.reservations[-1].infoBaseKey | Should -Match '^file\|'
    }

    It "blocks one manager plus two TestClients next to an existing session on the same base" {
        $message = & {
            $saved = $env:ONEC_MAX_CONCURRENT_SESSIONS
            try {
                $env:ONEC_MAX_CONCURRENT_SESSIONS = "3"
                . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
                $base = Join-Path ([IO.Path]::GetTempPath()) "itl-session-roctup-plus-two-clients"
                $script:FixtureProcesses = @(
                    [pscustomobject]@{ processId = 131; commandLine = "1cv8c.exe ENTERPRISE /F `"$base`"" }
                )
                function Get-OneCProcessInfo { return @($script:FixtureProcesses) }
                function Invoke-ItlPortRegistryLock { param([scriptblock]$ScriptBlock) & $ScriptBlock }
                function Read-OneCSessionRegistry { return [pscustomobject]@{ schemaVersion = 1; reservations = @() } }
                function Write-OneCSessionRegistry { param([object[]]$Reservations) }
                try {
                    Invoke-OneCSessionAdmission `
                        -InfoBaseKind file `
                        -InfoBasePath $base `
                        -RequiredSessions 3 `
                        -ExpectedChildRole test-client `
                        -Purpose test-manager-run `
                        -StartProcess { [pscustomobject]@{ Id = 132 } } | Out-Null
                    ""
                } catch { $_.Exception.Message }
            } finally { $env:ONEC_MAX_CONCURRENT_SESSIONS = $saved }
        }

        $message | Should -Match '^ITL_ONEC_SESSION_LIMIT: max=3 active=1 reserved=0 required=3'
    }

    It "keeps a future TestClient slot reserved while its TestManager is starting" {
        $message = & {
            $saved = $env:ONEC_MAX_CONCURRENT_SESSIONS
            try {
                $env:ONEC_MAX_CONCURRENT_SESSIONS = "3"
                . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
                $base = Join-Path ([IO.Path]::GetTempPath()) "itl-session-limit-pending"
                $identity = Get-OneCInfoBaseIdentity -InfoBaseKind file -InfoBasePath $base
                $script:FixtureProcesses = @(
                    [pscustomobject]@{ processId = 201; commandLine = "1cv8.exe DESIGNER /F `"$base`"" },
                    [pscustomobject]@{ processId = 202; commandLine = "1cv8c.exe ENTERPRISE /TESTMANAGER /F `"$base`"" }
                )
                $reservation = [pscustomobject]@{
                    id = "manager"; machine = [Environment]::MachineName; infoBaseKey = $identity.key
                    requiredSessions = 2; initialProcessIds = @(201); ownerPid = 1; leaderPid = 202
                    expectedChildRole = "test-client"
                    purpose = "test-manager"; createdAt = "2026-08-04T00:00:00Z"
                }
                function Get-OneCProcessInfo { return @($script:FixtureProcesses) }
                function Test-OneCSessionProcessIdentityPresent { return $true }
                function Invoke-ItlPortRegistryLock { param([scriptblock]$ScriptBlock) & $ScriptBlock }
                function Read-OneCSessionRegistry { return [pscustomobject]@{ schemaVersion = 1; reservations = @($reservation) } }
                function Write-OneCSessionRegistry { param([object[]]$Reservations) }
                try {
                    Invoke-OneCSessionAdmission -InfoBaseKind file -InfoBasePath $base -Purpose roctup -StartProcess { [pscustomobject]@{ Id = 203 } } | Out-Null
                    ""
                } catch { $_.Exception.Message }
            } finally { $env:ONEC_MAX_CONCURRENT_SESSIONS = $saved }
        }

        $message | Should -Match "^ITL_ONEC_SESSION_LIMIT: max=3 active=2 reserved=1 required=1"
    }

    It "does not let a Configurator consume the TestClient slot reserved by a manager" {
        $message = & {
            $saved = $env:ONEC_MAX_CONCURRENT_SESSIONS
            try {
                $env:ONEC_MAX_CONCURRENT_SESSIONS = "3"
                . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
                $base = Join-Path ([IO.Path]::GetTempPath()) "itl-session-limit-role-reservation"
                $identity = Get-OneCInfoBaseIdentity -InfoBaseKind file -InfoBasePath $base
                $script:FixtureProcesses = @(
                    [pscustomobject]@{ processId = 251; commandLine = "1cv8c.exe ENTERPRISE /TESTMANAGER /F `"$base`"" },
                    [pscustomobject]@{ processId = 252; commandLine = "1cv8.exe DESIGNER /F `"$base`"" }
                )
                $reservation = [pscustomobject]@{
                    id = "manager"; machine = [Environment]::MachineName; infoBaseKey = $identity.key
                    requiredSessions = 2; initialProcessIds = @(); ownerPid = 1; leaderPid = 251
                    expectedChildRole = "test-client"
                    purpose = "test-manager"; createdAt = "2026-08-04T00:00:00Z"
                }
                function Get-OneCProcessInfo { return @($script:FixtureProcesses) }
                function Test-OneCSessionProcessIdentityPresent { return $true }
                function Invoke-ItlPortRegistryLock { param([scriptblock]$ScriptBlock) & $ScriptBlock }
                function Read-OneCSessionRegistry { return [pscustomobject]@{ schemaVersion = 1; reservations = @($reservation) } }
                function Write-OneCSessionRegistry { param([object[]]$Reservations) }
                try {
                    Invoke-OneCSessionAdmission -InfoBaseKind file -InfoBasePath $base -Purpose roctup -StartProcess { [pscustomobject]@{ Id = 253 } } | Out-Null
                    ""
                } catch { $_.Exception.Message }
            } finally { $env:ONEC_MAX_CONCURRENT_SESSIONS = $saved }
        }

        $message | Should -Match "^ITL_ONEC_SESSION_LIMIT: max=3 active=2 reserved=1 required=1"
    }

    It "releases a fulfilled TestManager reservation and admits the third actual session" {
        $result = & {
            $saved = $env:ONEC_MAX_CONCURRENT_SESSIONS
            try {
                $env:ONEC_MAX_CONCURRENT_SESSIONS = "3"
                . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
                $base = Join-Path ([IO.Path]::GetTempPath()) "itl-session-limit-fulfilled"
                $identity = Get-OneCInfoBaseIdentity -InfoBaseKind file -InfoBasePath $base
                $script:FixtureProcesses = @(
                    [pscustomobject]@{ processId = 301; commandLine = "1cv8c.exe ENTERPRISE /TESTMANAGER /F `"$base`"" },
                    [pscustomobject]@{ processId = 302; commandLine = "1cv8c.exe ENTERPRISE /TESTCLIENT /F `"$base`"" }
                )
                $reservation = [pscustomobject]@{
                    id = "manager"; machine = [Environment]::MachineName; infoBaseKey = $identity.key
                    requiredSessions = 2; initialProcessIds = @(); ownerPid = 1; leaderPid = 301
                    expectedChildRole = "test-client"
                    purpose = "test-manager"; createdAt = "2026-08-04T00:00:00Z"
                }
                function Get-OneCProcessInfo { return @($script:FixtureProcesses) }
                function Test-OneCSessionProcessIdentityPresent { return $true }
                function Invoke-ItlPortRegistryLock { param([scriptblock]$ScriptBlock) & $ScriptBlock }
                function Read-OneCSessionRegistry { return [pscustomobject]@{ schemaVersion = 1; reservations = @($reservation) } }
                function Write-OneCSessionRegistry { param([object[]]$Reservations) $script:Written = @($Reservations) }
                $script:Written = @()
                $started = Invoke-OneCSessionAdmission -InfoBaseKind file -InfoBasePath $base -Purpose configurator -StartProcess { [pscustomobject]@{ Id = 303 } }
                [pscustomobject]@{ pid = $started.Id; reservations = @($script:Written) }
            } finally { $env:ONEC_MAX_CONCURRENT_SESSIONS = $saved }
        }

        $result.pid | Should -Be 303
        @($result.reservations).Count | Should -Be 1
        $result.reservations[0].purpose | Should -Be "configurator"
    }

    It "does not inspect or serialize processes when the limit is explicitly disabled" {
        $result = & {
            $saved = $env:ONEC_MAX_CONCURRENT_SESSIONS
            try {
                $env:ONEC_MAX_CONCURRENT_SESSIONS = "0"
                . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
                function Get-OneCProcessInfo { throw "inspection must not run" }
                function Invoke-ItlPortRegistryLock { throw "lock must not run" }
                Invoke-OneCSessionAdmission -InfoBaseKind server -InfoBasePath "srv\base" -StartProcess { [pscustomobject]@{ Id = 401 } }
            } finally { $env:ONEC_MAX_CONCURRENT_SESSIONS = $saved }
        }

        $result.Id | Should -Be 401
    }

    It "classifies the capacity block as scheduling with an explicit recovery action" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $script:RunErrorCategory = ""
            $script:RunRequiredAction = ""
            Set-RunFailureContextFromMessage -Message "ITL_ONEC_SESSION_LIMIT: max=3 active=3 required=1" -RequestedAction "status"
            [pscustomobject]@{ category = $script:RunErrorCategory; requiredAction = $script:RunRequiredAction }
        }

        $result.category | Should -Be "session-capacity"
        $result.requiredAction | Should -Be "finish-or-close-owned-sessions-before-retry"
    }

    It "releases synchronous reservations but keeps background reservations" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $script:Released = @()
            function Invoke-OneCSessionAdmission {
                param(
                    [string]$InfoBaseKind, [string]$InfoBasePath, [int]$RequiredSessions,
                    [string]$ExpectedChildRole, [string]$Purpose, [scriptblock]$StartProcess
                )
                $script:OneCSessionLaunchContext.reservationId = $Purpose
                return (& $StartProcess)
            }
            function Remove-OneCSessionReservation { param([string]$ReservationId) $script:Released += $ReservationId }

            $sync = Invoke-WithOneCSessionAdmissionContext -InfoBaseKind server -InfoBasePath "srv\base" -Purpose "sync" -ScriptBlock {
                Invoke-OneCSessionProcessStart -StartProcess { [pscustomobject]@{ Id = 501 } }
            }
            $background = Invoke-WithOneCSessionAdmissionContext -InfoBaseKind server -InfoBasePath "srv\base" -Purpose "background" -KeepReservation -ScriptBlock {
                Invoke-OneCSessionProcessStart -StartProcess { [pscustomobject]@{ Id = 502 } }
            }
            [pscustomobject]@{ sync = $sync.Id; background = $background.Id; released = @($script:Released) }
        }

        $result.sync | Should -Be 501
        $result.background | Should -Be 502
        @($result.released) | Should -Be @("sync")
    }

    It "routes Designer, Enterprise, background MCP, and project launches through one admission hook" {
        $core = Get-Content -LiteralPath $CorePath -Raw -Encoding UTF8
        $lifecycle = Get-Content -LiteralPath $LifecyclePath -Raw -Encoding UTF8
        $sessions = Get-Content -LiteralPath $SessionPath -Raw -Encoding UTF8
        $module = Get-Content -LiteralPath $HelperPath -Raw -Encoding UTF8
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($core, [ref]$null, [ref]$null)
        $functions = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
        $lifecycleAst = [System.Management.Automation.Language.Parser]::ParseInput($lifecycle, [ref]$null, [ref]$null)
        $lifecycleFunctions = $lifecycleAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)

        ($functions | Where-Object Name -eq "Invoke-Designer").Extent.Text | Should -Match "Invoke-WithOneCSessionAdmissionContext"
        ($functions | Where-Object Name -eq "Invoke-DesignerInteractive").Extent.Text | Should -Match "Invoke-WithOneCSessionAdmissionContext"
        ($functions | Where-Object Name -eq "Invoke-Enterprise").Extent.Text | Should -Match "ExpectedSessionCount"
        $backgroundFunction = ($functions | Where-Object Name -eq "Start-EnterpriseBackground").Extent.Text
        $backgroundFunction | Should -Match "Start-OneCProcessBackground"
        $backgroundFunction | Should -Match '(?s)-RequiredSessions\s+1.*-Purpose'
        $backgroundFunction | Should -Not -Match "ExpectedChildRole"
        ($lifecycleFunctions | Where-Object Name -eq "Sync-DevBranchContextToDotEnv").Extent.Text | Should -Match "Ensure-OneCSessionLimitDotEnv"
        $sessions | Should -Match "function Start-OneCProcessBackground"
        $module | Should -Match '"agent-1c\.ports\.ps1",\s*\r?\n\s*"agent-1c\.sessions\.ps1",\s*\r?\n\s*"agent-1c\.vanessa\.ps1"'
    }
}
