Describe "Vanessa Designer Agent safe-mode reconciliation" {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        $RepoRoot = $context.RepoRoot
        $HelperPath = $context.HelperPath
        $VanessaPath = Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.vanessa.ps1"
        $VanessaText = Get-Content -Encoding UTF8 -Raw $VanessaPath
    }

    It "keeps LoadCfg unchanged and reconciles only the two Vanessa extensions afterward" {
        $VanessaText | Should -Match ([regex]::Escape('-DesignerArgs @("/LoadCfg", $CfePath, "-Extension", $ExtensionName, "/UpdateDBCfg")'))
        $VanessaText | Should -Match ([regex]::Escape('$safeModeProof = Set-VanessaMcpExtensionsUnsafeMode -State $state -ClientArtifact $clientArtifact -VaExtensionArtifact $vaExtensionArtifact'))
        $setCommands = @([regex]::Matches($VanessaText, 'config extensions properties set --extension ([A-Za-z0-9_]+) --safe-mode no'))
        @($setCommands | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique) | Should -Be @("client_mcp", "VAExtension")
        $VanessaText | Should -Not -Match 'config extensions properties set --all-extensions'
        $VanessaText | Should -Not -Match 'config extensions properties set[^\r\n]*unsafe-action-protection'
    }

    It "writes Designer Agent input as UTF-8 bytes on Windows PowerShell 5.1" {
        $VanessaText | Should -Not -Match 'StandardInputEncoding'
        $VanessaText | Should -Match ([regex]::Escape('$stdinBytes = (Get-Utf8Encoding).GetBytes($json)'))
        $VanessaText | Should -Match ([regex]::Escape('$process.StandardInput.BaseStream.Write($stdinBytes, 0, $stdinBytes.Length)'))
    }

    It "records installation state only after both CFE loads and successful safe-mode proof" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $script:sequence = New-Object System.Collections.Generic.List[string]
            $script:updates = $null
            function Read-CurrentDevBranchStateForVanessaMcp { return [pscustomobject]@{ devBranchInfoBasePath = "base"; infoBaseKind = "file" } }
            function Get-VanessaMcpRuntimeInfo { return [pscustomobject]@{ processAlive = $false } }
            function Get-VanessaAutomationState { return [pscustomobject]@{ ready = $true } }
            function Install-VanessaMcpArtifacts {
                return @(
                    [pscustomobject]@{ key = "clientMcp"; path = "client.cfe"; version = "1"; sha256 = "client-sha" },
                    [pscustomobject]@{ key = "vaExtension"; path = "va.cfe"; version = "2"; sha256 = "va-sha" }
                )
            }
            function Install-VanessaMcpExtensionCfe {
                param([object]$State, [string]$CfePath, [string]$ExtensionName)
                $script:sequence.Add("load:$ExtensionName") | Out-Null
                return "$ExtensionName.log"
            }
            function Set-VanessaMcpExtensionsUnsafeMode {
                $script:sequence.Add("safe-mode") | Out-Null
                return [pscustomobject]@{ clientMcpSafeMode = $false; vaExtensionSafeMode = $false }
            }
            function Update-DevBranchState {
                param([object]$State, [hashtable]$Updates)
                $script:sequence.Add("state") | Out-Null
                $script:updates = $Updates
            }
            Install-VanessaMcp *> $null
            [pscustomobject]@{ sequence = @($script:sequence); updates = $script:updates }
        }

        $result.sequence | Should -Be @("load:client_mcp", "load:VAExtension", "safe-mode", "state")
        $result.updates.vanessaMcpSafeModeProof.clientMcpSafeMode | Should -BeFalse
        $result.updates.vanessaMcpSafeModeProof.vaExtensionSafeMode | Should -BeFalse
    }

    It "does not persist installed state when Designer Agent reconciliation fails" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $script:updateCalled = $false
            function Read-CurrentDevBranchStateForVanessaMcp { return [pscustomobject]@{ devBranchInfoBasePath = "base"; infoBaseKind = "file" } }
            function Get-VanessaMcpRuntimeInfo { return [pscustomobject]@{ processAlive = $false } }
            function Get-VanessaAutomationState { return [pscustomobject]@{ ready = $true } }
            function Install-VanessaMcpArtifacts {
                return @(
                    [pscustomobject]@{ key = "clientMcp"; path = "client.cfe"; version = "1"; sha256 = "client-sha" },
                    [pscustomobject]@{ key = "vaExtension"; path = "va.cfe"; version = "2"; sha256 = "va-sha" }
                )
            }
            function Install-VanessaMcpExtensionCfe { return "load.log" }
            function Set-VanessaMcpExtensionsUnsafeMode { throw "safe-mode proof failed" }
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
