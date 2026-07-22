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
                [switch]$FailTools,
                [switch]$FailDump,
                [switch]$FailValidate,
                [switch]$FailRollback,
                [switch]$ExistingExtension,
                [switch]$PrepopulateTarget
            )

            $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-extension-init-" + [guid]::NewGuid().ToString("N"))
            $kiloToolRoot = Join-Path $tempRoot ".kilo\skills\1c-metadata-manage\tools\1c-cfe-manage\scripts"
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot "src\cf"), (Join-Path $tempRoot ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\Configuration.xml") -Encoding UTF8 -Value '<Configuration />'
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"aiRules":{"tools":["kilocode"]}}'
            Set-Content -LiteralPath (Join-Path $tempRoot ".ai-rules.json") -Encoding UTF8 -Value '{"tools":["kilocode"],"files":{}}'
            if (-not $FailTools) {
                New-Item -ItemType Directory -Force -Path $kiloToolRoot | Out-Null
                Set-Content -LiteralPath (Join-Path $kiloToolRoot "cfe-init.ps1") -Encoding ASCII -Value "# fixture"
                Set-Content -LiteralPath (Join-Path $kiloToolRoot "cfe-validate.ps1") -Encoding ASCII -Value "# fixture"
            }
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
                    $script:extensionLifecycleToolCalls = @()
                    $script:extensionInitRollbackCalled = $false

                    function Read-DevBranchState { return $fakeState }
                    function Assert-DevelopmentBranchWorktreeContext {}
                    function Assert-DevBranchKind {}
                    function Assert-SingleManagedExtensionArtifact {}
                    function Test-DevBranchExtensionExists { return [bool]$ExistingExtension }
                    function Get-RoctupMcpRuntimeInfo { return [pscustomobject]@{ processAlive = $false } }
                    function Get-VanessaMcpRuntimeInfo { return [pscustomobject]@{ processAlive = $false } }
                    function Stop-OwnVanessaTestProcessesAndAssert {}
                    function Stop-RoctupMcpForState { return $false }
                    function Stop-VanessaMcpForState { return $false }
                    function Restore-ExtensionInitMcpRuntime {}
                    function Invoke-ExtensionLifecycleTool {
                        param([string]$ScriptPath, [string[]]$Arguments)
                        $script:extensionLifecycleToolCalls += $ScriptPath
                        if ($FailValidate -and $ScriptPath -like "*cfe-validate.ps1") { throw "mock validation failure" }
                    }
                    function Add-VerificationStaleIfNeeded {}
                    function Sync-DevBranchContextToDotEnv {}
                    function Get-CurrentCommit { return "head" }
                    function Update-DevBranchState {
                        param([object]$State, [hashtable]$Updates)
                        if ($null -eq $script:extensionInitUpdatesCaptured) { $script:extensionInitUpdatesCaptured = @{} }
                        foreach ($key in $Updates.Keys) { $script:extensionInitUpdatesCaptured[$key] = $Updates[$key] }
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
                        toolCalls = @($script:extensionLifecycleToolCalls)
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
        $HelperText | Should -Match "extension-init.delegate"
        $HelperText | Should -Match ([regex]::Escape('"-Action", "init-dev-branch-extension"'))
        $HelperText | Should -Match "EXTENSION_INIT_REQUIRED"
    }

    It "initializes Empty sources and records state only after normalized validation" {
        $result = Invoke-MockedExtensionInitialization -Mode Empty
        $result.error | Should -BeNullOrEmpty
        $result.updates.extensionName | Should -Be "ShipModel"
        $result.updates.extensionInitMode | Should -Be "Empty"
        $result.updates.extensionDumpPath | Should -Be "src/cfe/ShipModel"
        $result.updates.extensionExportPath | Should -Be "src/cfe/ShipModel"
        $result.updates.extensionInitializedAt | Should -Not -BeNullOrEmpty
        $result.updates.extensionInitializationStatus | Should -Be "ready"
        ($result.toolCalls -join "`n") | Should -Match ([regex]::Escape(".kilo\skills\1c-metadata-manage\tools\1c-cfe-manage\scripts"))
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
        $result.updates.extensionInitializationStatus | Should -Be "failed"
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
        $rollback.updates.extensionInitializationStatus | Should -Be "failed"
        $rollback.updates.extensionInitializationError | Should -Match "Rollback also failed"
    }

    It "persists failed state when setup fails before the snapshot" {
        $result = Invoke-MockedExtensionInitialization -Mode Empty -FailTools
        $result.error | Should -Match "before a snapshot was created"
        $result.error | Should -Match "active ai_rules_1c client 'kilocode'"
        $result.error | Should -Match "\.kilo.*cfe-init\.ps1"
        $result.updates.extensionInitializationStatus | Should -Be "failed"
        $result.updates.extensionInitializationError | Should -Match "active ai_rules_1c client 'kilocode'"
        $result.rollbackCalled | Should -BeFalse
    }

    It "treats pending extension setup as a persisted lifecycle gate" {
        & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $pending = [pscustomobject]@{
                devBranchKind = "extension"
                extensionInitializationStatus = "pending"
            }
            $failed = [pscustomobject]@{
                devBranchKind = "extension"
                extensionInitializationStatus = "failed"
            }
            $ready = [pscustomobject]@{
                devBranchKind = "extension"
                extensionName = "ShipModel"
            }
            $configuration = [pscustomobject]@{ devBranchKind = "configuration" }

            (Get-DevBranchExtensionInitializationStatus -State $pending) | Should -Be "pending"
            (Get-DevBranchExtensionInitializationStatus -State $failed) | Should -Be "failed"
            (Get-DevBranchExtensionInitializationStatus -State $ready) | Should -Be "ready"
            (Get-DevBranchExtensionInitializationStatus -State $configuration) | Should -Be "not-required"
            { Assert-DevBranchExtensionInitialized -State $pending -Operation "check-dev-branch" } | Should -Throw "*EXTENSION_INIT_REQUIRED*"
            $script:RunRequiredAction | Should -Match "Ask the developer"
            $script:RunRequiredAction | Should -Match "Do not ask the developer to run PowerShell"
        }
    }

    It "orchestrates branch creation and extension initialization as one user scenario" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help -DevBranchName "ship" -ExtensionInitMode Empty -ExtensionName "ShipModel" *> $null
            $script:testProvisioningState = [pscustomobject]@{
                devBranchName = "ship"
                devBranch = "itldev/ship"
                devBranchKind = "extension"
                initializationStatus = "ready"
                extensionInitializationStatus = "pending"
                worktreePath = "C:\fixture\ship"
                mainWorktreePath = "C:\fixture\master"
                stateProjectRoot = "C:\fixture\ship"
            }
            $script:coreCalled = $false
            $script:initCalled = $false
            $script:contextRoot = ""
            function Get-PreparedExtensionDevBranchState { return $null }
            function New-DevBranchCore { param([string]$DevBranchKind, [switch]$DeferHandoff); $script:coreCalled = ($DevBranchKind -eq "extension" -and $DeferHandoff) }
            function Read-DevBranchState { return $script:testProvisioningState }
            function Invoke-ExtensionInitializationInWorktree {
                param([string]$WorktreePath)
                $script:contextRoot = $WorktreePath
                $script:initCalled = $true
                $script:testProvisioningState | Add-Member -NotePropertyName extensionName -NotePropertyValue "ShipModel" -Force
                $script:testProvisioningState.extensionInitializationStatus = "ready"
            }
            function Write-DevBranchWorktreeOpenMessage {}
            function Open-AgentWorktreeBestEffort {}

            New-ExtensionDevBranch *> $null
            [pscustomobject]@{
                coreCalled = $script:coreCalled
                initCalled = $script:initCalled
                contextRoot = $script:contextRoot
                runStatus = $script:RunExtensionInitializationStatus
                worktreePath = $script:RunWorktreePath
            }
        }

        $result.coreCalled | Should -BeTrue
        $result.initCalled | Should -BeTrue
        $result.contextRoot | Should -Be "C:\fixture\ship"
        $result.runStatus | Should -Be "ready"
        $result.worktreePath | Should -Be "C:\fixture\ship"
    }

    It "rejects partial setup input before branch creation" {
        & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help -DevBranchName "ship" -ExtensionName "ShipModel" *> $null
            $script:coreCalled = $false
            function New-DevBranchCore { $script:coreCalled = $true }
            { New-ExtensionDevBranch } | Should -Throw "*EXTENSION_INIT_INPUT_INCOMPLETE*"
            $script:coreCalled | Should -BeFalse
        }
    }

    It "persists an agent-guided pending step when setup parameters are unknown" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help -DevBranchName "ship" *> $null
            $script:testProvisioningState = [pscustomobject]@{
                devBranchName = "ship"
                devBranch = "itldev/ship"
                devBranchKind = "extension"
                initializationStatus = "ready"
                extensionInitializationStatus = "pending"
                worktreePath = "C:\fixture\ship"
                mainWorktreePath = "C:\fixture\master"
                stateProjectRoot = "C:\fixture\ship"
            }
            $script:initCalled = $false
            function Get-PreparedExtensionDevBranchState { return $null }
            function New-DevBranchCore {}
            function Read-DevBranchState { return $script:testProvisioningState }
            function Invoke-ExtensionInitializationInWorktree { param([string]$WorktreePath); $script:initCalled = $true }
            function Write-DevBranchWorktreeOpenMessage {}
            function Open-AgentWorktreeBestEffort {}

            New-ExtensionDevBranch *> $null
            [pscustomobject]@{
                initCalled = $script:initCalled
                runStatus = $script:RunExtensionInitializationStatus
                requiredAction = $script:RunRequiredAction
            }
        }

        $result.initCalled | Should -BeFalse
        $result.runStatus | Should -Be "pending"
        $result.requiredAction | Should -Match "В worktree расширения"
        $result.requiredAction | Should -Match "Не просите разработчика запускать PowerShell"
    }

    It "resumes a prepared pending branch without copying its infobase again" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help -DevBranchName "ship" -ExtensionInitMode Empty -ExtensionName "ShipModel" *> $null
            $script:testProvisioningState = [pscustomobject]@{
                devBranchName = "ship"
                devBranch = "itldev/ship"
                devBranchKind = "extension"
                initializationStatus = "ready"
                extensionInitializationStatus = "failed"
                worktreePath = "C:\fixture\ship"
                mainWorktreePath = "C:\fixture\master"
                stateProjectRoot = "C:\fixture\ship"
            }
            $script:coreCalled = $false
            $script:initCalled = $false
            function Get-PreparedExtensionDevBranchState { return $script:testProvisioningState }
            function Assert-MasterWorktreeContext {}
            function Assert-CleanGit {}
            function New-DevBranchCore { $script:coreCalled = $true }
            function Invoke-ExtensionInitializationInWorktree {
                param([string]$WorktreePath)
                $script:initCalled = $true
                $script:testProvisioningState | Add-Member -NotePropertyName extensionName -NotePropertyValue "ShipModel" -Force
                $script:testProvisioningState.extensionInitializationStatus = "ready"
            }
            function Read-DevBranchState { return $script:testProvisioningState }
            function Write-DevBranchWorktreeOpenMessage {}
            function Open-AgentWorktreeBestEffort {}

            New-ExtensionDevBranch *> $null
            [pscustomobject]@{ coreCalled = $script:coreCalled; initCalled = $script:initCalled; runStatus = $script:RunExtensionInitializationStatus }
        }

        $result.coreCalled | Should -BeFalse
        $result.initCalled | Should -BeTrue
        $result.runStatus | Should -Be "ready"
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

    It "allows unchanged baseline CFE roots but rejects every changed second extension artifact" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-extension-single-artifact-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot "src\cfe\Baseline"), (Join-Path $tempRoot "src\cfe\ShipModel") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cfe\Baseline\Configuration.xml") -Encoding UTF8 -Value "baseline"
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cfe\ShipModel\Configuration.xml") -Encoding UTF8 -Value "selected"
            & git -C $tempRoot init *> $null
            & git -C $tempRoot config user.email "test@example.invalid"
            & git -C $tempRoot config user.name "ITL Test"
            & git -C $tempRoot add .
            & git -C $tempRoot commit -m baseline *> $null
            $baseCommit = (& git -C $tempRoot rev-parse HEAD).Trim()

            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $state = [pscustomobject]@{
                    devBranchKind = "extension"
                    devBranch = "itldev/ship"
                    extensionName = "ShipModel"
                    createdFromCommit = $baseCommit
                }
                { Assert-SingleManagedExtensionArtifact -State $state } | Should -Not -Throw
                Add-Content -LiteralPath (Join-Path $tempRoot "src\cfe\ShipModel\Configuration.xml") -Value "feature"
                { Assert-SingleManagedExtensionArtifact -State $state } | Should -Not -Throw
                Add-Content -LiteralPath (Join-Path $tempRoot "src\cfe\Baseline\Configuration.xml") -Value "wrong branch"
                { Assert-SingleManagedExtensionArtifact -State $state } | Should -Throw "*EXTENSION_BRANCH_SINGLE_ARTIFACT*"
                & git -C $tempRoot checkout -- src/cfe/Baseline/Configuration.xml
                New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot "src\cfe\Other") | Out-Null
                Set-Content -LiteralPath (Join-Path $tempRoot "src\cfe\Other\Configuration.xml") -Encoding UTF8 -Value "other"
                { Assert-SingleManagedExtensionArtifact -State $state } | Should -Throw "*EXTENSION_BRANCH_SINGLE_ARTIFACT*"
            }
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "validates the infobase slot before mutating recovery state" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-extension-recovery-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot "src\cfe") | Out-Null
            & git -C $tempRoot init *> $null
            & git -C $tempRoot config user.email "test@example.invalid"
            & git -C $tempRoot config user.name "ITL Test"
            Set-Content -LiteralPath (Join-Path $tempRoot ".gitignore") -Encoding ASCII -Value ".agent-1c/"
            & git -C $tempRoot add .gitignore
            & git -C $tempRoot commit -m baseline *> $null
            $baseCommit = (& git -C $tempRoot rev-parse HEAD).Trim()

            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help -ExtensionName "ShipModel" *> $null
                $state = [pscustomobject]@{
                    devBranchName = "ship"
                    devBranchKind = "extension"
                    devBranch = "itldev/ship"
                    createdFromCommit = $baseCommit
                    devBranchInfoBasePath = (Join-Path $tempRoot "ib")
                    infoBaseKind = "file"
                    stateProjectRoot = $tempRoot
                }
                $script:slotExists = $false
                $script:capturedUpdates = $null
                $script:syncCalled = $false
                function Read-DevBranchState { return $state }
                function Assert-DevelopmentBranchWorktreeContext {}
                function Test-DevBranchExtensionExists { return $script:slotExists }
                function Add-VerificationStaleIfNeeded {}
                function Update-DevBranchState { param([object]$State, [hashtable]$Updates); $script:capturedUpdates = $Updates }
                function Sync-DevBranchContextToDotEnv { $script:syncCalled = $true }

                $missingError = ""
                try { Set-DevBranchExtension *> $null } catch { $missingError = $_.Exception.Message }
                $missingUpdates = $script:capturedUpdates
                $missingSync = $script:syncCalled

                $script:slotExists = $true
                $script:syncCalled = $false
                Set-DevBranchExtension *> $null
                [pscustomobject]@{
                    missingError = $missingError
                    missingUpdates = $missingUpdates
                    missingSync = $missingSync
                    successfulUpdates = $script:capturedUpdates
                    successfulSync = $script:syncCalled
                }
            }
            $result.missingError | Should -Match "EXTENSION_RECOVERY_SLOT_MISSING"
            $result.missingUpdates | Should -BeNullOrEmpty
            $result.missingSync | Should -BeFalse
            $result.successfulUpdates.extensionName | Should -Be "ShipModel"
            $result.successfulUpdates.extensionRecoveryStatus | Should -Be "pending-dump"
            $result.successfulUpdates.lastExtensionDesignerFingerprint | Should -Be ""
            $result.successfulSync | Should -BeTrue
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "replaces a recovery dump transactionally only after normalization and CFE validation" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-extension-dump-transaction-" + [guid]::NewGuid().ToString("N"))
        try {
            $target = Join-Path $tempRoot "src\cfe\ShipModel"
            New-Item -ItemType Directory -Force -Path $target | Out-Null
            Set-Content -LiteralPath (Join-Path $target "sentinel.txt") -Encoding ASCII -Value "original"
            & git -C $tempRoot init *> $null
            & git -C $tempRoot config user.email "test@example.invalid"
            & git -C $tempRoot config user.name "ITL Test"
            & git -C $tempRoot add .
            & git -C $tempRoot commit -m baseline *> $null
            $baseCommit = (& git -C $tempRoot rev-parse HEAD).Trim()

            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $state = [pscustomobject]@{
                    devBranchKind = "extension"
                    devBranch = "itldev/ship"
                    extensionName = "ShipModel"
                    extensionDumpPath = "src/cfe/ShipModel"
                    createdFromCommit = $baseCommit
                    devBranchInfoBasePath = (Join-Path $tempRoot "ib")
                    infoBaseKind = "file"
                }
                $script:validationFails = $true
                function Get-ExtensionLifecycleToolPaths { return [pscustomobject]@{ validate = "validate.ps1"; init = "init.ps1" } }
                function Invoke-ExtensionLifecycleTool {
                    if ($script:validationFails) { throw "mock CFE validation failure" }
                }
                function Invoke-Designer {
                    param([string]$InfoBasePath, [string]$InfoBaseKind, [string[]]$DesignerArgs)
                    $dump = $DesignerArgs[1]
                    New-Item -ItemType Directory -Force -Path $dump | Out-Null
                    Set-Content -LiteralPath (Join-Path $dump "Configuration.xml") -Encoding UTF8 -Value '<MetaDataObject><Configuration><Properties><Name>ShipModel</Name></Properties></Configuration></MetaDataObject>'
                    Set-Content -LiteralPath (Join-Path $dump "ConfigDumpInfo.xml") -Encoding UTF8 -Value '<ConfigDumpInfo />'
                    Set-Content -LiteralPath (Join-Path $dump "fresh.txt") -Encoding ASCII -Value "fresh"
                    $script:LastLogPath = Join-Path $tempRoot "designer.log"
                }

                $failure = ""
                try { Dump-ExtensionToFiles -State $state *> $null } catch { $failure = $_.Exception.Message }
                $sentinelAfterFailure = Test-Path -LiteralPath (Join-Path $target "sentinel.txt")
                $script:validationFails = $false
                $success = Dump-ExtensionToFiles -State $state
                [pscustomobject]@{
                    failure = $failure
                    sentinelAfterFailure = $sentinelAfterFailure
                    freshAfterSuccess = Test-Path -LiteralPath (Join-Path $target "fresh.txt")
                    sentinelAfterSuccess = Test-Path -LiteralPath (Join-Path $target "sentinel.txt")
                    transactional = $success.transactional
                }
            }
            $result.failure | Should -Match "before state or fingerprint update"
            $result.sentinelAfterFailure | Should -BeTrue
            $result.freshAfterSuccess | Should -BeTrue
            $result.sentinelAfterSuccess | Should -BeFalse
            $result.transactional | Should -BeTrue
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
