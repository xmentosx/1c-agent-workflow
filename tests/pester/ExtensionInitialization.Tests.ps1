Describe "1C workflow extension initialization" {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        $RepoRoot = $context.RepoRoot
        $HelperPath = $context.HelperPath
        $HelperText = $context.HelperText

        function Invoke-MockedExtensionInitialization {
            param(
                [ValidateSet("Empty", "Cfe")]
                [string]$Mode,
                [switch]$FailDump,
                [switch]$FailValidate,
                [switch]$FailRollback,
                [switch]$ExistingExtension,
                [switch]$PrepopulateTarget
            )

            $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-extension-init-" + [guid]::NewGuid().ToString("N"))
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot "src\cf") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\Configuration.xml") -Encoding UTF8 -Value '<Configuration />'
            $cfePath = Join-Path $tempRoot "input.cfe"
            Set-Content -LiteralPath $cfePath -Encoding Byte -Value ([byte[]](1, 2, 3))
            if ($PrepopulateTarget) {
                New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot "src\cfe\ShipModel") | Out-Null
                Set-Content -LiteralPath (Join-Path $tempRoot "src\cfe\ShipModel\existing.txt") -Encoding ASCII -Value "existing"
            }

            try {
                return & {
                    . $HelperPath -ProjectRoot $tempRoot -Action help -ExtensionInitMode $Mode -ExtensionName "ShipModel" -ExtensionSourcePath $(if ($Mode -eq "Cfe") { $cfePath } else { "" }) *> $null

                    $fakeState = [pscustomobject]@{
                        devBranchName = "branch1"
                        safeDevBranchName = "branch1"
                        devBranch = "itldev/branch1"
                        devBranchKind = "extension"
                        devBranchInfoBasePath = (Join-Path $tempRoot "base")
                        infoBaseKind = "file"
                        stateProjectRoot = $tempRoot
                    }
                    $script:extensionInitUpdatesCaptured = $null
                    $script:extensionInitDesignerCalls = @()
                    $script:extensionInitRollbackCalled = $false

                    function Read-DevBranchState { return $fakeState }
                    function Assert-DevelopmentBranchWorktreeContext {}
                    function Assert-DevBranchKind {}
                    function Get-ExtensionLifecycleToolPaths { return [pscustomobject]@{ init = "cfe-init.ps1"; validate = "cfe-validate.ps1" } }
                    function Test-DevBranchExtensionExists { return [bool]$ExistingExtension }
                    function Get-RoctupMcpRuntimeInfo { return [pscustomobject]@{ processAlive = $false } }
                    function Get-VanessaMcpRuntimeInfo { return [pscustomobject]@{ processAlive = $false } }
                    function Stop-OwnVanessaTestProcessesAndAssert {}
                    function Stop-RoctupMcpForState { return $false }
                    function Stop-VanessaMcpForState { return $false }
                    function Restore-ExtensionInitMcpRuntime {}
                    function Invoke-ExtensionLifecycleTool {
                        param([string]$ScriptPath, [string[]]$Arguments)
                        if ($FailValidate -and $ScriptPath -like "*cfe-validate.ps1") { throw "mock validation failure" }
                    }
                    function Add-VerificationStaleIfNeeded {}
                    function Sync-DevBranchContextToDotEnv {}
                    function Get-CurrentCommit { return "head" }
                    function Update-DevBranchState {
                        param([object]$State, [hashtable]$Updates)
                        $script:extensionInitUpdatesCaptured = $Updates
                    }
                    function Invoke-Designer {
                        param([string]$InfoBasePath, [string]$InfoBaseKind, [string[]]$DesignerArgs)
                        $script:extensionInitDesignerCalls += ,@($DesignerArgs)
                        switch ($DesignerArgs[0]) {
                            "/DumpIB" {
                                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $DesignerArgs[1]) | Out-Null
                                Set-Content -LiteralPath $DesignerArgs[1] -Encoding Byte -Value ([byte[]](4, 5, 6))
                            }
                            "/DumpConfigToFiles" {
                                if ($FailDump) { throw "mock dump failure" }
                                New-Item -ItemType Directory -Force -Path $DesignerArgs[1] | Out-Null
                                Set-Content -LiteralPath (Join-Path $DesignerArgs[1] "Configuration.xml") -Encoding UTF8 -Value @'
<?xml version="1.0" encoding="UTF-8"?>
<MetaDataObject xmlns="http://v8.1c.ru/8.3/MDClasses"><Configuration><Properties><Name>ShipModel</Name></Properties></Configuration></MetaDataObject>
'@
                                Set-Content -LiteralPath (Join-Path $DesignerArgs[1] "ConfigDumpInfo.xml") -Encoding UTF8 -Value '<ConfigDumpInfo />'
                            }
                            "/RestoreIB" {
                                $script:extensionInitRollbackCalled = $true
                                if ($FailRollback) { throw "mock rollback failure" }
                            }
                        }
                        $script:LastLogPath = Join-Path $tempRoot "designer.log"
                    }

                    $errorText = ""
                    try {
                        Init-DevBranchExtension *> $null
                    } catch {
                        $errorText = $_.Exception.Message
                    }
                    [pscustomobject]@{
                        updates = $script:extensionInitUpdatesCaptured
                        calls = @($script:extensionInitDesignerCalls)
                        rollbackCalled = $script:extensionInitRollbackCalled
                        error = $errorText
                        targetExists = Test-Path -LiteralPath (Join-Path $tempRoot "src\cfe\ShipModel")
                    }
                }
            } finally {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "exposes the script-owned action without Designer Agent or CFE unpacking" {
        $HelperText | Should -Match '"init-dev-branch-extension"'
        $HelperText | Should -Match "ExtensionInitMode"
        $HelperText | Should -Match ([regex]::Escape('"/LoadConfigFromFiles", $scaffoldPath, "-Extension", $ExtensionName'))
        $HelperText | Should -Match ([regex]::Escape('"/LoadCfg", $sourceCfe, "-Extension", $ExtensionName'))
        $HelperText | Should -Match ([regex]::Escape('-DesignerArgs @("/DumpDBCfgList", "-Extension", $Name)'))
        $HelperText | Should -Not -Match "AgentMode"
        $HelperText | Should -Not -Match "v8unpack"
        $HelperText | Should -Not -Match '"/Extension"'
    }

    It "initializes Empty sources and records state only after normalized validation" {
        $result = Invoke-MockedExtensionInitialization -Mode Empty
        $result.error | Should -BeNullOrEmpty
        $result.updates.extensionName | Should -Be "ShipModel"
        $result.updates.extensionInitMode | Should -Be "Empty"
        $result.updates.extensionDumpPath | Should -Be "src/cfe/ShipModel"
        $result.updates.extensionExportPath | Should -Be "src/cfe/ShipModel"
        $result.updates.extensionInitializedAt | Should -Not -BeNullOrEmpty
        ($result.calls | ForEach-Object { $_ -join " " }) -join "`n" | Should -Match "/LoadConfigFromFiles.*-Extension ShipModel.*-Format Hierarchical.*\/UpdateDBCfg"
    }

    It "loads CFE directly with -Extension and never unpacks it" {
        $result = Invoke-MockedExtensionInitialization -Mode Cfe
        $result.error | Should -BeNullOrEmpty
        $result.updates.extensionInitMode | Should -Be "Cfe"
        $callsText = ($result.calls | ForEach-Object { $_ -join " " }) -join "`n"
        $callsText | Should -Match "/LoadCfg.*input\.cfe.*-Extension ShipModel.*\/UpdateDBCfg"
        $callsText | Should -Not -Match "LoadConfigFromFiles"
        $callsText | Should -Not -Match "v8unpack"
    }

    It "restores the snapshot removes partial files and leaves extension state absent on failure" {
        $result = Invoke-MockedExtensionInitialization -Mode Empty -FailDump
        $result.error | Should -Match "snapshot was restored"
        $result.rollbackCalled | Should -BeTrue
        $result.updates.Keys | Should -Not -Contain "extensionName"
        $result.updates.lastExtensionDesignerFingerprint | Should -Be ""
        $result.updates.enterpriseNormalizationStatus | Should -Be "pending"
        $result.targetExists | Should -BeFalse
    }

    It "stops safely on existing extension or a nonempty exact dump target" {
        $existing = Invoke-MockedExtensionInitialization -Mode Empty -ExistingExtension
        $existing.error | Should -Match "already exists"
        $existing.updates | Should -BeNullOrEmpty
        $existing.rollbackCalled | Should -BeFalse

        $nonempty = Invoke-MockedExtensionInitialization -Mode Empty -PrepopulateTarget
        $nonempty.error | Should -Match "not empty"
        $nonempty.updates | Should -BeNullOrEmpty
        $nonempty.rollbackCalled | Should -BeFalse
    }

    It "rolls back validation failures and reports a second rollback failure without state" {
        $validation = Invoke-MockedExtensionInitialization -Mode Empty -FailValidate
        $validation.error | Should -Match "snapshot was restored"
        $validation.rollbackCalled | Should -BeTrue
        $validation.updates.Keys | Should -Not -Contain "extensionName"
        $validation.updates.lastExtensionDesignerFingerprint | Should -Be ""
        $validation.updates.enterpriseNormalizationStatus | Should -Be "pending"

        $rollback = Invoke-MockedExtensionInitialization -Mode Cfe -FailDump -FailRollback
        $rollback.error | Should -Match "Rollback also failed"
        $rollback.error | Should -Match "mock dump failure"
        $rollback.error | Should -Match "mock rollback failure"
        $rollback.updates | Should -BeNullOrEmpty
    }

    It "validates Unicode extension names and rejects nested src cfe roots" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-extension-unicode-" + [guid]::NewGuid().ToString("N"))
        try {
            $name = -join ([char[]](0x041C, 0x043E, 0x0434, 0x0435, 0x043B, 0x044C))
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot "Configuration.xml") -Encoding UTF8 -Value "<MetaDataObject><Configuration><Properties><Name>$name</Name></Properties></Configuration></MetaDataObject>"
            Set-Content -LiteralPath (Join-Path $tempRoot "ConfigDumpInfo.xml") -Encoding UTF8 -Value '<ConfigDumpInfo />'

            & {
                . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
                { Assert-NormalizedExtensionDump -Path $tempRoot -Name $name } | Should -Not -Throw
                New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot "src\cfe\nested") | Out-Null
                { Assert-NormalizedExtensionDump -Path $tempRoot -Name $name } | Should -Throw "*Nested src/cfe*"
            }
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
