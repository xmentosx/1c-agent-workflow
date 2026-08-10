Describe "Vanessa Designer Agent safe-mode reconciliation" {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        $RepoRoot = $context.RepoRoot
        $HelperPath = $context.HelperPath
        $VanessaPath = Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.vanessa.ps1"
        $VanessaText = Get-Content -Encoding UTF8 -Raw $VanessaPath
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

    It "keeps the project-owned Designer Agent host key outside Git status" {
        (Get-Content -LiteralPath (Join-Path $RepoRoot "templates\gitignore.append") -Raw -Encoding UTF8) | Should -Match ([regex]::Escape('.agent-1c/runtime/'))
        $LifecycleText | Should -Match ([regex]::Escape('Ensure-Agent1cLifecycleLocksIgnored -WorktreePath $script:ProjectRoot'))
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            Test-IgnorableLocalGitStatusLine -Line '?? .agent-1c/runtime/'
        }
        $result | Should -BeTrue
    }

    It "creates one branch-local empty service infobase through guarded CREATEINFOBASE" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-vanessa-service-base-" + [guid]::NewGuid().ToString("N"))
        try {
            $result = & {
                . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
                $servicePath = Join-Path $tempRoot ".agent-1c\infobases\vanessa-service"
                $state = [pscustomobject]@{ devBranchName = "demo"; vanessaServiceInfoBasePath = $servicePath }
                $script:capturedArguments = @()
                $script:capturedPurpose = ""
                $script:updates = $null
                function Get-PlatformPath { return "C:\fake\1cv8.exe" }
                function Invoke-WithOneCSessionAdmissionContext {
                    param([string]$InfoBaseKind, [string]$InfoBasePath, [int]$RequiredSessions, [string]$Purpose, [scriptblock]$ScriptBlock)
                    $script:capturedPurpose = $Purpose
                    return (& $ScriptBlock)
                }
                function Invoke-NativeProcessAndWaitResult {
                    param([string]$FilePath, [string[]]$Arguments, [int]$TimeoutSeconds)
                    $script:capturedArguments = @($Arguments)
                    New-Item -ItemType Directory -Force -Path $servicePath | Out-Null
                    [IO.File]::WriteAllText((Join-Path $servicePath "1Cv8.1CD"), "fixture")
                    return [pscustomobject]@{ exitCode = 0; timedOut = $false }
                }
                function Update-DevBranchState { param([object]$State, [hashtable]$Updates) $script:updates = $Updates }
                $service = Ensure-VanessaServiceInfoBase -State $state
                [pscustomobject]@{ service = $service; arguments = @($script:capturedArguments); purpose = $script:capturedPurpose; updates = $script:updates }
            }

            $result.service.created | Should -BeTrue
            $result.service.kind | Should -Be "file"
            $result.arguments[0] | Should -Be "CREATEINFOBASE"
            $result.arguments | Should -Contain ('File="' + $result.service.path + '"')
            $result.arguments | Should -Not -Contain "/AddInList"
            $result.purpose | Should -Be "vanessa-service-infobase-create"
            $result.updates.vanessaServiceInfoBasePath | Should -Be $result.service.path
            $result.updates.vanessaServiceInfoBaseGeneration | Should -Match '^[a-f0-9]{32}$'
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "records installation state only after both CFE loads and successful safe-mode proof" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $script:sequence = New-Object System.Collections.Generic.List[string]
            $script:updates = $null
            $script:fixtureState = [pscustomobject]@{ devBranchName = "demo"; devBranchInfoBasePath = "target-base"; infoBaseKind = "file"; vanessaServiceInfoBasePath = "service-base"; vanessaServiceInfoBaseKind = "file" }
            function Read-CurrentDevBranchStateForVanessaMcp { return $script:fixtureState }
            function Read-DevBranchState { return $script:fixtureState }
            function Ensure-VanessaServiceInfoBase { return [pscustomobject]@{ kind = "file"; path = "service-base"; created = $false } }
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
            function Ensure-VanessaServiceInfoBase { return [pscustomobject]@{ kind = "file"; path = "service-base"; created = $false } }
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
