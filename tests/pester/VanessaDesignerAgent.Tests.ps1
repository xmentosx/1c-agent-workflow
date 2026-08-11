Describe "Vanessa Designer Agent safe-mode reconciliation" {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        $RepoRoot = $context.RepoRoot
        $HelperPath = $context.HelperPath
        $VanessaPath = Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.vanessa.ps1"
        $VanessaText = Get-Content -Encoding UTF8 -Raw $VanessaPath
        $OnDemandText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.ondemand-mcp.ps1")
        $LifecycleText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.lifecycle.ps1")
    }

    It "keeps LoadCfg unchanged and reconciles each Vanessa extension in its own infobase" {
        $VanessaText | Should -Match ([regex]::Escape('-DesignerArgs @("/LoadCfg", $CfePath, "-Extension", $ExtensionName, "/UpdateDBCfg")'))
        $VanessaText | Should -Match 'function Set-VanessaMcpExtensionUnsafeMode'
        $VanessaText | Should -Match 'config extensions properties set --extension \$ExtensionName --safe-mode no'
        $VanessaText | Should -Match '(?s)-ExtensionName "client_mcp".*?-InfoBasePath \$serviceInfoBase\.path'
        $VanessaText | Should -Match '(?s)-ExtensionName "VAExtension".*?-InfoBasePath \(\[string\]\$state\.devBranchInfoBasePath\)'
        $VanessaText | Should -Not -Match 'config extensions properties set --all-extensions'
        $VanessaText | Should -Not -Match 'config extensions properties set[^\r\n]*unsafe-action-protection'
    }

    It "writes Designer Agent input as UTF-8 bytes on Windows PowerShell 5.1" {
        $VanessaText | Should -Not -Match 'StandardInputEncoding'
        $VanessaText | Should -Match ([regex]::Escape('$stdinBytes = (Get-Utf8Encoding).GetBytes($json)'))
        $VanessaText | Should -Match ([regex]::Escape('$process.StandardInput.BaseStream.Write($stdinBytes, 0, $stdinBytes.Length)'))
    }

    It "starts Designer Agent with a platform log and verifies listener ownership" {
        $VanessaText | Should -Match '(?s)function Set-VanessaMcpExtensionUnsafeMode.*?"/DisableStartupMessages".*?"/DisableStartupDialogs".*?"/Out", \$logPath.*?Wait-VanessaDesignerAgentReady'
        $VanessaText | Should -Match 'ITL_DESIGNER_AGENT_EXITED'
        $VanessaText | Should -Match 'ITL_DESIGNER_AGENT_PORT_OWNER_MISMATCH'
        $VanessaText | Should -Match ([regex]::Escape("infoBaseKey='`$(`$infoBaseIdentity.key)'"))
        $VanessaText | Should -Match ([regex]::Escape("platformVersion='`$platformVersion'"))
        $VanessaText | Should -Match ([regex]::Escape("log='`$logPath'"))
    }

    It "accepts readiness only when the expected live PID owns the listener" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $script:fixtureStartTime = [DateTime]::UtcNow.AddSeconds(-5)
            function Get-Process { return [pscustomobject]@{ Id = 7311; StartTime = $script:fixtureStartTime } }
            function Test-TcpPortOpen { return $true }
            function Get-NetTCPConnection {
                [CmdletBinding()]
                param([string]$State, [int]$LocalPort)
                return [pscustomobject]@{ OwningProcess = 7311 }
            }
            $fixtureProcess = [pscustomobject]@{ Id = 7311; StartTime = $script:fixtureStartTime; HasExited = $false }
            Wait-VanessaDesignerAgentReady -Process $fixtureProcess -ExpectedStartTime $script:fixtureStartTime -Port 48251 -TimeoutSeconds 0
        }

        $result.ready | Should -BeTrue
        $result.status | Should -Be "ready"
        $result.ownerPids | Should -Be @(7311)
    }

    It "reports a foreign listener instead of accepting a raw open port" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $script:fixtureStartTime = [DateTime]::UtcNow.AddSeconds(-5)
            function Get-Process { return [pscustomobject]@{ Id = 7312; StartTime = $script:fixtureStartTime } }
            function Test-TcpPortOpen { return $true }
            function Get-NetTCPConnection {
                [CmdletBinding()]
                param([string]$State, [int]$LocalPort)
                return [pscustomobject]@{ OwningProcess = 9901 }
            }
            $fixtureProcess = [pscustomobject]@{ Id = 7312; StartTime = $script:fixtureStartTime; HasExited = $false }
            Wait-VanessaDesignerAgentReady -Process $fixtureProcess -ExpectedStartTime $script:fixtureStartTime -Port 48251 -TimeoutSeconds 0
        }

        $result.ready | Should -BeFalse
        $result.status | Should -Be "owner-mismatch"
        $result.ownerPids | Should -Be @(9901)
    }

    It "preserves the exit code when Designer Agent dies before readiness" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            function Get-Process { return $null }
            $fixtureProcess = [pscustomobject]@{ Id = 7313; StartTime = [DateTime]::UtcNow; HasExited = $true; ExitCode = 27 }
            Wait-VanessaDesignerAgentReady -Process $fixtureProcess -ExpectedStartTime $fixtureProcess.StartTime -Port 48251 -TimeoutSeconds 0
        }

        $result.ready | Should -BeFalse
        $result.status | Should -Be "exited"
        $result.processAlive | Should -BeFalse
        $result.exitCode | Should -Be 27
    }

    It "distinguishes an alive process that never opens the listener" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $script:fixtureStartTime = [DateTime]::UtcNow.AddSeconds(-5)
            function Get-Process { return [pscustomobject]@{ Id = 7314; StartTime = $script:fixtureStartTime } }
            function Test-TcpPortOpen { return $false }
            $fixtureProcess = [pscustomobject]@{ Id = 7314; StartTime = $script:fixtureStartTime; HasExited = $false }
            Wait-VanessaDesignerAgentReady -Process $fixtureProcess -ExpectedStartTime $script:fixtureStartTime -Port 48251 -TimeoutSeconds 0
        }

        $result.ready | Should -BeFalse
        $result.status | Should -Be "timeout"
        $result.processAlive | Should -BeTrue
    }

    It "redacts secrets from the Designer Agent log tail" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-designer-log-" + [guid]::NewGuid().ToString("N"))
        try {
            $result = & {
                . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
                New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
                $logPath = Join-Path $tempRoot "designer-agent.log"
                Set-Content -LiteralPath $logPath -Encoding UTF8 -Value 'startup failed password=do-not-leak /P "also-secret"'
                Read-VanessaDesignerAgentSafeLogTail -Path $logPath
            }
            $result | Should -Match 'startup failed'
            $result | Should -Match '<redacted>'
            $result | Should -Not -Match 'do-not-leak|also-secret'
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "keeps the project-owned Designer Agent host key outside Git status" {
        (Get-Content -LiteralPath (Join-Path $RepoRoot "templates\gitignore.append") -Raw -Encoding UTF8) | Should -Match ([regex]::Escape('.agent-1c/runtime/'))
        $LifecycleText | Should -Match ([regex]::Escape('Ensure-Agent1cLifecycleLocksIgnored -WorktreePath $script:ProjectRoot'))
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            Test-IgnorableLocalGitStatusLine -Line '?? .agent-1c/runtime/'
        }
        $result | Should -BeTrue
    }

    It "builds canonical file infobase connection strings for native 1C arguments" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $cyrillicBase = -join ([char[]](0x0411, 0x0430, 0x0437, 0x0430))
            $cyrillicFolder = -join ([char[]](0x041A, 0x0430, 0x0442, 0x0430, 0x043B, 0x043E, 0x0433))
            @(
                New-FileInfoBaseConnectionString -Path "C:\base"
                New-FileInfoBaseConnectionString -Path "C:\base with spaces"
                New-FileInfoBaseConnectionString -Path "C:\$cyrillicBase"
                New-FileInfoBaseConnectionString -Path "C:\$cyrillicFolder with spaces\$cyrillicBase"
            )
        }

        $cyrillicBase = -join ([char[]](0x0411, 0x0430, 0x0437, 0x0430))
        $cyrillicFolder = -join ([char[]](0x041A, 0x0430, 0x0442, 0x0430, 0x043B, 0x043E, 0x0433))
        $result | Should -Be @(
            'File="C:\base";'
            'File="C:\base with spaces";'
            "File=`"C:\$cyrillicBase`";"
            "File=`"C:\$cyrillicFolder with spaces\$cyrillicBase`";"
        )
    }

    It "preserves the connection-string quotes through the native process launcher" {
        $cyrillicSuffix = -join ([char[]](0x041A, 0x0438, 0x0440, 0x0438, 0x043B, 0x043B, 0x0438, 0x0446, 0x0430))
        $cyrillicBase = -join ([char[]](0x0431, 0x0430, 0x0437, 0x0430))
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl native argv $cyrillicSuffix " + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            $probePath = Join-Path $tempRoot "capture-argument.ps1"
            $capturedPath = Join-Path $tempRoot "captured.txt"
            $probeText = @'
param([string]$OutputPath, [string]$Value)
[IO.File]::WriteAllText($OutputPath, $Value, (New-Object Text.UTF8Encoding $false))
'@
            [IO.File]::WriteAllText($probePath, $probeText, (New-Object Text.UTF8Encoding $false))

            $result = & {
                . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
                $connectionString = New-FileInfoBaseConnectionString -Path (Join-Path $tempRoot "service $cyrillicBase")
                $processResult = Invoke-NativeProcessAndWaitResult `
                    -FilePath (Get-Command powershell.exe -ErrorAction Stop).Source `
                    -Arguments @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $probePath, $capturedPath, $connectionString) `
                    -TimeoutSeconds 30
                [pscustomobject]@{
                    connectionString = $connectionString
                    captured = [IO.File]::ReadAllText($capturedPath, [Text.Encoding]::UTF8)
                    exitCode = $processResult.exitCode
                    timedOut = $processResult.timedOut
                }
            }

            $result.exitCode | Should -Be 0
            $result.timedOut | Should -BeFalse
            $result.captured | Should -Be $result.connectionString
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "keeps CREATEINFOBASE connection quotes literal for the 1C raw command-line parser" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $cyrillicBase = -join ([char[]](0x0431, 0x0430, 0x0437, 0x0430))
            $connectionString = New-FileInfoBaseConnectionString -Path "C:\service path\$cyrillicBase"
            $arguments = @("CREATEINFOBASE", $connectionString, "/DisableStartupDialogs", "/Out", "C:\log path\create.log")
            [pscustomobject]@{
                standard = Join-NativeCommandLineArguments -Arguments $arguments
                oneC = Join-OneCCreateInfoBaseCommandLineArguments -Arguments $arguments
                expected = 'CREATEINFOBASE File="C:\service path\' + $cyrillicBase + '"; /DisableStartupDialogs /Out "C:\log path\create.log"'
            }
        }

        $result.standard | Should -Match ([regex]::Escape('\"'))
        $result.oneC | Should -Be $result.expected
        $result.oneC | Should -Not -Match ([regex]::Escape('\"'))
    }

    It "creates and restores one qualified branch-local service infobase through guarded 1C calls" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl Vanessa service " + [guid]::NewGuid().ToString("N"))
        try {
            $result = & {
                . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
                $script:ProjectRoot = $tempRoot
                $template = Get-VanessaServiceInfoBaseTemplate
                $generation = "a" * 32
                $servicePath = Join-Path $tempRoot ".agent-1c\infobases\vanessa-service-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                $state = [pscustomobject]@{
                    devBranchName = "demo"
                    vanessaServiceInfoBasePath = $servicePath
                    vanessaServiceInfoBaseGeneration = $generation
                    vanessaServiceInfoBaseSchemaVersion = 3
                    vanessaServiceInfoBaseTemplateSha256 = $template.sha256
                    vanessaServiceInfoBaseUser = $template.user
                }
                $script:capturedArguments = @()
                $script:capturedDesignerArgs = @()
                $script:capturedDesignerUser = $null
                $script:capturedPurpose = ""
                $script:capturedCreateSyntax = $false
                $script:updates = $null
                function Get-PlatformPath { return "C:\fake\1cv8.exe" }
                function Invoke-WithOneCSessionAdmissionContext {
                    param([string]$InfoBaseKind, [string]$InfoBasePath, [int]$RequiredSessions, [string]$Purpose, [scriptblock]$ScriptBlock)
                    $script:capturedPurpose = $Purpose
                    return (& $ScriptBlock)
                }
                function Invoke-NativeProcessAndWaitResult {
                    param([string]$FilePath, [string[]]$Arguments, [switch]$OneCCreateInfoBaseSyntax, [int]$TimeoutSeconds)
                    $script:capturedArguments = @($Arguments)
                    $script:capturedCreateSyntax = $OneCCreateInfoBaseSyntax.IsPresent
                    if ([string]$Arguments[1] -notmatch '^File="(?<path>[^"]+)";$') {
                        throw "Unexpected CREATEINFOBASE connection string: $($Arguments[1])"
                    }
                    $createdPath = [string]$Matches['path']
                    New-Item -ItemType Directory -Force -Path $createdPath | Out-Null
                    [IO.File]::WriteAllText((Join-Path $createdPath "1Cv8.1CD"), "fixture")
                    return [pscustomobject]@{ exitCode = 0; timedOut = $false }
                }
                function Invoke-Designer {
                    param([string]$InfoBasePath, [string]$InfoBaseKind, [string[]]$DesignerArgs, [string]$User, [string]$Password)
                    $script:capturedDesignerArgs = @($DesignerArgs)
                    $script:capturedDesignerUser = $User
                }
                function Update-DevBranchState { param([object]$State, [hashtable]$Updates) $script:updates = $Updates }
                $service = Ensure-VanessaServiceInfoBase -State $state
                [pscustomobject]@{
                    service = $service
                    arguments = @($script:capturedArguments)
                    designerArgs = @($script:capturedDesignerArgs)
                    designerUser = $script:capturedDesignerUser
                    lastLogPath = $script:LastLogPath
                    purpose = $script:capturedPurpose
                    createSyntax = $script:capturedCreateSyntax
                    updates = $script:updates
                }
            }

            $result.service.created | Should -BeTrue
            $result.service.restored | Should -BeTrue
            $result.service.kind | Should -Be "file"
            $result.service.user | Should -Be "itl_vanessa_service"
            (Split-Path -Leaf $result.service.path) | Should -Match '^vanessa-service-[a-f0-9]{32}$'
            $result.arguments[0] | Should -Be "CREATEINFOBASE"
            $result.arguments | Should -Contain ('File="' + $result.service.path + '";')
            $result.arguments | Should -Not -Contain "/AddInList"
            $result.arguments[[Array]::IndexOf($result.arguments, "/Out") + 1] | Should -Be $result.lastLogPath
            $result.purpose | Should -Be "vanessa-service-infobase-create"
            $result.createSyntax | Should -BeTrue
            $result.designerArgs[0] | Should -Be "/RestoreIB"
            (Split-Path -Leaf $result.designerArgs[1]) | Should -Be "service-infobase.dt"
            $result.designerUser | Should -Be ""
            $result.updates.vanessaServiceInfoBasePath | Should -Be $result.service.path
            $result.updates.vanessaServiceInfoBaseGeneration | Should -Match '^[a-f0-9]{32}$'
            $result.updates.vanessaServiceInfoBaseSchemaVersion | Should -Be 3
            $result.updates.vanessaServiceInfoBaseTemplateSha256 | Should -Be $result.service.templateSha256
            $result.updates.vanessaServiceInfoBaseUser | Should -Be "itl_vanessa_service"
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "reuses a qualified service infobase without another native or Designer call" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl Vanessa reuse " + [guid]::NewGuid().ToString("N"))
        try {
            $result = & {
                . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
                $script:ProjectRoot = $tempRoot
                $template = Get-VanessaServiceInfoBaseTemplate
                $generation = "b" * 32
                $servicePath = Join-Path $tempRoot ".agent-1c\infobases\vanessa-service-$generation"
                New-Item -ItemType Directory -Force -Path $servicePath | Out-Null
                [IO.File]::WriteAllText((Join-Path $servicePath "1Cv8.1CD"), "fixture")
                $marker = [ordered]@{
                    schemaVersion = 1
                    generation = $generation
                    templateSha256 = $template.sha256
                    serviceUser = $template.user
                }
                Write-Utf8TextAtomic -Path (Join-Path $servicePath ".itl-service-template.json") -Value (($marker | ConvertTo-Json) + [Environment]::NewLine)
                $state = [pscustomobject]@{
                    devBranchName = "demo"
                    vanessaServiceInfoBaseKind = "file"
                    vanessaServiceInfoBasePath = $servicePath
                    vanessaServiceInfoBaseGeneration = $generation
                    vanessaServiceInfoBaseSchemaVersion = 3
                    vanessaServiceInfoBaseTemplateSha256 = $template.sha256
                    vanessaServiceInfoBaseUser = $template.user
                }
                function Invoke-NativeProcessAndWaitResult { throw "Native CREATEINFOBASE must not run for a qualified service infobase." }
                function Invoke-Designer { throw "Designer restore must not run for a qualified service infobase." }
                Ensure-VanessaServiceInfoBase -State $state
            }

            $result.created | Should -BeFalse
            $result.restored | Should -BeFalse
            $result.path | Should -Be (Join-Path $tempRoot ".agent-1c\infobases\vanessa-service-$('b' * 32)")
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "rejects a non-empty invalid owned service directory before starting 1C" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl Vanessa invalid " + [guid]::NewGuid().ToString("N"))
        try {
            $message = & {
                . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
                $script:ProjectRoot = $tempRoot
                $template = Get-VanessaServiceInfoBaseTemplate
                $generation = "c" * 32
                $servicePath = Join-Path $tempRoot ".agent-1c\infobases\vanessa-service-$generation"
                New-Item -ItemType Directory -Force -Path $servicePath | Out-Null
                $marker = [ordered]@{
                    schemaVersion = 1
                    generation = $generation
                    templateSha256 = $template.sha256
                    serviceUser = $template.user
                }
                Write-Utf8TextAtomic -Path (Join-Path $servicePath ".itl-service-template.json") -Value (($marker | ConvertTo-Json) + [Environment]::NewLine)
                [IO.File]::WriteAllText((Join-Path $servicePath "unexpected.txt"), "do not delete")
                $state = [pscustomobject]@{
                    devBranchName = "demo"
                    vanessaServiceInfoBaseKind = "file"
                    vanessaServiceInfoBasePath = $servicePath
                    vanessaServiceInfoBaseGeneration = $generation
                    vanessaServiceInfoBaseSchemaVersion = 3
                    vanessaServiceInfoBaseTemplateSha256 = $template.sha256
                    vanessaServiceInfoBaseUser = $template.user
                }
                function Get-PlatformPath { throw "1C must not start for a non-empty invalid service directory." }
                try {
                    Ensure-VanessaServiceInfoBase -State $state | Out-Null
                    "NO_ERROR"
                } catch {
                    $_.Exception.Message
                }
            }

            $message | Should -Match '^ITL_VANESSA_SERVICE_INFOBASE_INVALID:'
            Test-Path -LiteralPath (Join-Path $tempRoot ".agent-1c\infobases\vanessa-service-$('c' * 32)\unexpected.txt") | Should -BeTrue
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "packages the qualified template and uses its service user without editing user-level configuration" {
        $manifestPath = Join-Path $RepoRoot ".agents\skills\1c-workflow\assets\vanessa-service\manifest.json"
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $artifactPath = Join-Path (Split-Path -Parent $manifestPath) ([string]$manifest.artifact)
        (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be ([string]$manifest.sha256)
        $manifest.serviceUser | Should -Be "itl_vanessa_service"
        $manifest.passwordRequired | Should -BeFalse
        $manifest.unsafeActionProtectionDisabled | Should -BeTrue
        (Get-Content -LiteralPath (Join-Path $RepoRoot "templates\gitignore.append") -Raw -Encoding UTF8) |
            Should -Match '!\.agents/skills/1c-workflow/assets/vanessa-service/service-infobase\.dt'

        foreach ($functionName in @("Run-DevBranchTests", "Install-VanessaMcp", "Start-VanessaMcp")) {
            $functionText = [regex]::Match(
                $VanessaText,
                ("function " + [regex]::Escape($functionName) + "\s*\{[\s\S]*?^}"),
                [Text.RegularExpressions.RegexOptions]::Multiline
            ).Value
            $functionText | Should -Match '\$serviceInfoBase\.user'
        }
        $onDemandStart = [regex]::Match(
            $OnDemandText,
            'function Start-ItlOnDemandBackendInstance[\s\S]*?^}',
            [Text.RegularExpressions.RegexOptions]::Multiline
        ).Value
        $onDemandStart | Should -Match '\$serviceInfoBase\.user'
        ($VanessaText + $OnDemandText) | Should -Not -Match 'conf\.cfg|DisableUnsafeActionProtection|UnsafeActionProtectionBypass'
    }

    It "records installation state only after both CFE loads and successful safe-mode proof" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $script:sequence = New-Object System.Collections.Generic.List[string]
            $script:updates = $null
            $script:fixtureState = [pscustomobject]@{ devBranchName = "demo"; devBranchInfoBasePath = "target-base"; infoBaseKind = "file"; vanessaServiceInfoBasePath = "service-base"; vanessaServiceInfoBaseKind = "file" }
            function Read-CurrentDevBranchStateForVanessaMcp { return $script:fixtureState }
            function Read-DevBranchState { return $script:fixtureState }
            function Ensure-VanessaServiceInfoBase { return [pscustomobject]@{ kind = "file"; path = "service-base"; user = "itl_vanessa_service"; password = ""; created = $false } }
            function Stop-DevBranchRuntimeBeforeInfobaseMutation {}
            function Get-VanessaMcpRuntimeInfo { return [pscustomobject]@{ processAlive = $false } }
            function Get-VanessaAutomationState { return [pscustomobject]@{ ready = $true } }
            function Install-VanessaMcpArtifacts {
                return @(
                    [pscustomobject]@{ key = "clientMcp"; path = "client.cfe"; version = "1"; sha256 = "client-sha" },
                    [pscustomobject]@{ key = "vaExtension"; path = "va.cfe"; version = "2"; sha256 = "va-sha" }
                )
            }
            function Install-VanessaMcpExtensionCfe {
                param([object]$State, [string]$CfePath, [string]$ExtensionName, [string]$InfoBaseKind, [string]$InfoBasePath, [string]$User, [string]$Password)
                $script:sequence.Add("load:$ExtensionName") | Out-Null
                return "$ExtensionName.log"
            }
            function Set-VanessaMcpExtensionUnsafeMode {
                param([object]$State, [string]$InfoBaseKind, [string]$InfoBasePath, [string]$ExtensionName, [object]$Artifact, [string]$User, [string]$Password, [string]$Scope)
                $script:sequence.Add("safe:${ExtensionName}:$InfoBasePath") | Out-Null
                return [pscustomobject]@{ extensionName = $ExtensionName; infoBasePath = $InfoBasePath; safeMode = $false; artifactSha256 = $Artifact.sha256 }
            }
            function Update-DevBranchState {
                param([object]$State, [hashtable]$Updates)
                $script:sequence.Add("state") | Out-Null
                $script:updates = $Updates
            }
            Install-VanessaMcp *> $null
            [pscustomobject]@{ sequence = @($script:sequence); updates = $script:updates }
        }

        $result.sequence | Should -Be @("load:client_mcp", "load:VAExtension", "safe:client_mcp:service-base", "safe:VAExtension:target-base", "state")
        $result.updates.vanessaMcpSafeModeProof.clientMcpSafeMode | Should -BeFalse
        $result.updates.vanessaMcpSafeModeProof.vaExtensionSafeMode | Should -BeFalse
        $result.updates.vanessaMcpSafeModeProof.clientMcp.infoBasePath | Should -Be "service-base"
        $result.updates.vanessaMcpSafeModeProof.vaExtension.infoBasePath | Should -Be "target-base"
    }

    It "does not persist installed state when Designer Agent reconciliation fails" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $script:updateCalled = $false
            $script:fixtureState = [pscustomobject]@{ devBranchName = "demo"; devBranchInfoBasePath = "target-base"; infoBaseKind = "file"; vanessaServiceInfoBasePath = "service-base"; vanessaServiceInfoBaseKind = "file" }
            function Read-CurrentDevBranchStateForVanessaMcp { return $script:fixtureState }
            function Read-DevBranchState { return $script:fixtureState }
            function Ensure-VanessaServiceInfoBase { return [pscustomobject]@{ kind = "file"; path = "service-base"; user = "itl_vanessa_service"; password = ""; created = $false } }
            function Stop-DevBranchRuntimeBeforeInfobaseMutation {}
            function Get-VanessaMcpRuntimeInfo { return [pscustomobject]@{ processAlive = $false } }
            function Get-VanessaAutomationState { return [pscustomobject]@{ ready = $true } }
            function Install-VanessaMcpArtifacts {
                return @(
                    [pscustomobject]@{ key = "clientMcp"; path = "client.cfe"; version = "1"; sha256 = "client-sha" },
                    [pscustomobject]@{ key = "vaExtension"; path = "va.cfe"; version = "2"; sha256 = "va-sha" }
                )
            }
            function Install-VanessaMcpExtensionCfe { return "load.log" }
            function Set-VanessaMcpExtensionUnsafeMode { throw "safe-mode proof failed" }
            function Update-DevBranchState { $script:updateCalled = $true }
            $message = ""
            try { Install-VanessaMcp *> $null } catch { $message = $_.Exception.Message }
            [pscustomobject]@{ message = $message; updateCalled = $script:updateCalled }
        }

        $result.message | Should -Match "safe-mode proof failed"
        $result.updateCalled | Should -BeFalse
    }

    It "accepts only an explicit false or no safe-mode result for each exact extension" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $proof = [pscustomobject]@{
                success = $true
                commands = @(
                    [pscustomobject]@{ command = "config extensions properties get --extension client_mcp"; messages = @([pscustomobject]@{ type = "success"; body = [pscustomobject]@{ safeMode = $false } }) },
                    [pscustomobject]@{ command = "config extensions properties get --extension VAExtension"; messages = @([pscustomobject]@{ type = "success"; body = [pscustomobject]@{ 'safe-mode' = "no" } }) }
                )
            }
            [pscustomobject]@{
                client = Test-VanessaDesignerAgentSafeModeResult -Result $proof -ExtensionName "client_mcp"
                extension = Test-VanessaDesignerAgentSafeModeResult -Result $proof -ExtensionName "VAExtension"
                absent = Test-VanessaDesignerAgentSafeModeResult -Result $proof -ExtensionName "Other"
            }
        }
        $result.client | Should -BeTrue
        $result.extension | Should -BeTrue
        $result.absent | Should -BeFalse
    }

    It "accepts safe-mode proof only when each artifact belongs to its own exact infobase" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-vanessa-proof-" + [guid]::NewGuid().ToString("N"))
        try {
            $result = & {
                . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
                $service = Join-Path $tempRoot "service"
                $target = Join-Path $tempRoot "target"
                $serviceIdentity = Get-OneCInfoBaseIdentity -InfoBaseKind file -InfoBasePath $service
                $targetIdentity = Get-OneCInfoBaseIdentity -InfoBaseKind file -InfoBasePath $target
                $proof = [pscustomobject]@{
                    serviceInfoBaseGeneration = "generation-one"
                    clientMcp = [pscustomobject]@{ extensionName = "client_mcp"; infoBaseKey = $serviceIdentity.key; artifactSha256 = "client-sha"; safeMode = $false }
                    vaExtension = [pscustomobject]@{ extensionName = "VAExtension"; infoBaseKey = $targetIdentity.key; artifactSha256 = "va-sha"; safeMode = $false }
                }
                $state = [pscustomobject]@{
                    infoBaseKind = "file"; devBranchInfoBasePath = $target
                    vanessaServiceInfoBaseKind = "file"; vanessaServiceInfoBasePath = $service
                    vanessaServiceInfoBaseGeneration = "generation-one"
                    vanessaMcpClientMcpSha256 = "client-sha"; vanessaMcpVaExtensionSha256 = "va-sha"
                    vanessaMcpSafeModeProof = $proof
                }
                $valid = Test-VanessaMcpSafeModeProofMatchesState -State $state
                $proof.clientMcp.infoBaseKey = $targetIdentity.key
                $swapped = Test-VanessaMcpSafeModeProofMatchesState -State $state
                [pscustomobject]@{ valid = $valid; swapped = $swapped }
            }
            $result.valid | Should -BeTrue
            $result.swapped | Should -BeFalse
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "forms both file and client-server AgentMode infobase arguments without credentials" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            [pscustomobject]@{
                file = @(New-InfobaseArgs -Kind file -Path "C:\base with spaces" -User "" -Password "")
                server = @(New-InfobaseArgs -Kind server -Path "server\base" -User "" -Password "")
            }
        }
        $result.file | Should -Be @("/F", "C:\base with spaces")
        $result.server | Should -Be @("/S", "server\base")
        ($result.file + $result.server) | Should -Not -Contain "/N"
        ($result.file + $result.server) | Should -Not -Contain "/P"
    }

    It "passes credentials only through stdin JSON and refuses cleanup after PID identity changes" {
        $VanessaText | Should -Match '\.Arguments = "designer-agent-safe-mode"'
        $VanessaText | Should -Match '\$process\.StandardInput\.BaseStream\.Write\(\$stdinBytes, 0, \$stdinBytes\.Length\)'
        $VanessaText | Should -Not -Match '\.Arguments\s*=\s*[^\r\n]*(?:password|IB_PASSWORD)'

        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $script:stopCalled = $false
            function Get-Process { return [pscustomobject]@{ Id = 123; StartTime = [DateTime]::UtcNow.AddMinutes(5) } }
            function Stop-NativeProcessForSafety { $script:stopCalled = $true }
            $cleanup = Stop-VanessaDesignerAgentOwnedProcess -Process ([pscustomobject]@{ Id = 123 }) -ExpectedStartTime ([DateTime]::UtcNow)
            [pscustomobject]@{ cleanup = $cleanup; stopCalled = $script:stopCalled }
        }
        $result.cleanup.confirmed | Should -BeFalse
        $result.cleanup.error | Should -Match "refusing to stop a foreign process"
        $result.stopCalled | Should -BeFalse
    }
}
