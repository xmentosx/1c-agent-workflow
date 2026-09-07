BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSupport.ps1')
    $context = Initialize-WorkflowPesterContext
    . $context.HelperPath -ProjectRoot $context.RepoRoot -Action help *> $null
    function New-ReadyToolingRuntime {
        param([string]$Name, [string]$Hash = "runtime-hash")
        [pscustomobject]@{ name=$Name; present=$true; active=$true; safeMode=$false; unsafeActionProtection=$false; contentHash=$Hash; serverCodeObject=$true }
    }
}

Describe "Tooling generation and recovery" {
    BeforeEach {
        $script:toolingState = [pscustomobject]@{
            devBranchName="branch"; infoBaseKind="file"; devBranchInfoBasePath="C:\Тест базы\branch"
            toolingInfoBaseGeneration="old"; vanessaMcpSafeModeProof=@{ success=$true }; yaxunitInstallationProof=@{ success=$true }
        }
        Mock Update-DevBranchState {
            param($State,$Updates)
            foreach ($key in $Updates.Keys) { $script:toolingState | Add-Member -NotePropertyName $key -NotePropertyValue $Updates[$key] -Force }
        }
        Mock Read-DevBranchState { $script:toolingState }
    }

    It "invalidates both proofs and the caller snapshot for a replacement at the same path" {
        Reset-DevBranchToolingProof -State $script:toolingState -Reason reset
        $script:toolingState.devBranchInfoBasePath | Should -Be "C:\Тест базы\branch"
        $script:toolingState.toolingInfoBaseGeneration | Should -Not -Be "old"
        $script:toolingState.vanessaMcpSafeModeProof | Should -BeNullOrEmpty
        $script:toolingState.yaxunitInstallationProof | Should -BeNullOrEmpty
    }

    It "invalidates snapshot receipts before RestoreIB even if Designer fails" {
        Mock Stop-DevBranchRuntimeBeforeInfobaseMutation {}
        Mock Invoke-Designer {
            $script:toolingState.vanessaMcpSafeModeProof | Should -BeNullOrEmpty
            $script:toolingState.yaxunitInstallationProof | Should -BeNullOrEmpty
            throw "restore interrupted"
        }
        { Restore-DevBranchInfobaseFromSnapshot -State $script:toolingState -SnapshotPath "C:\Архив базы\copy.dt" } | Should -Throw '*restore interrupted*'
        $script:toolingState.toolingInfoBaseGeneration | Should -Not -Be "old"
    }

    It "migrates legacy state once and preserves an unchanged generation" {
        $script:toolingState.toolingInfoBaseGeneration=""
        $first=Ensure-DevBranchToolingGeneration $script:toolingState
        $generation=$first.toolingInfoBaseGeneration
        $second=Ensure-DevBranchToolingGeneration $first
        $second.toolingInfoBaseGeneration | Should -Be $generation
        Should -Invoke Update-DevBranchState -Times 1 -Exactly
    }

    It "clears proofs before replacing the seed file at an unchanged mixed Unicode and space path" {
        $basePath=Join-Path $TestDrive 'Копия базы'
        New-Item -ItemType Directory -Path $basePath | Out-Null
        $script:toolingState.devBranchInfoBasePath=$basePath
        $seedPath=Join-Path $TestDrive 'seed.1CD'
        [IO.File]::WriteAllText($seedPath,'new database')
        [IO.File]::WriteAllText((Join-Path $basePath '1Cv8.1CD'),'old database')
        $script:seed=[pscustomobject]@{configurationFingerprint='config';artifactPath=$seedPath;artifactSha256=(Get-FileHash $seedPath -Algorithm SHA256).Hash.ToLowerInvariant()}
        Mock Open-BranchSeedLease { [IO.MemoryStream]::new() }
        Mock Assert-BranchSeedReady { $script:seed }
        Mock Get-InfoBaseKind { 'file' }
        Mock Remove-BranchSeedFileRuntimeSidecars {}
        Mock Copy-BranchSeedFileDoNotCopyMarker {}
        Mock Move-Item {
            param($LiteralPath,$Destination)
            $script:toolingState.vanessaMcpSafeModeProof | Should -BeNullOrEmpty
            $script:toolingState.yaxunitInstallationProof | Should -BeNullOrEmpty
            [IO.File]::Replace([string]@($LiteralPath)[0], [string]$Destination, ([string]$Destination + '.before'))
        }
        Restore-ExistingDevBranchFromSeed -State $script:toolingState -ExpectedConfigurationFingerprint config | Out-Null
        [IO.File]::ReadAllText((Join-Path $basePath '1Cv8.1CD')) | Should -Be 'new database'
        $script:toolingState.toolingInfoBaseGeneration | Should -Not -Be old
    }

    It "does not accept a file or legacy safe-mode receipt without database generation" {
        $script:toolingState.vanessaMcpSafeModeProof=[pscustomobject]@{ schemaVersion=2 }
        Test-VanessaMcpSafeModeProofMatchesState $script:toolingState | Should -BeFalse
    }

    It "requires the extension active in a fresh session, exact content and required object" {
        $runtime=New-ReadyToolingRuntime VAExtension
        Test-ToolingRuntimeExtensionReady $runtime VAExtension -ExpectedHash runtime-hash -RequireUnsafeMode | Should -BeTrue
        foreach ($field in @('present','active','serverCodeObject')) {
            $runtime.$field=$false
            Test-ToolingRuntimeExtensionReady $runtime VAExtension | Should -BeFalse
            $runtime.$field=$true
        }
        Test-ToolingRuntimeExtensionReady $runtime client_mcp | Should -BeFalse
        Test-ToolingRuntimeExtensionReady $runtime VAExtension -ExpectedHash changed | Should -BeFalse
        $runtime.safeMode=$true
        Test-ToolingRuntimeExtensionReady $runtime VAExtension -RequireUnsafeMode | Should -BeFalse
    }

    It "routes recovery through a lifecycle-locked public action" {
        Test-Agent1cActionRequiresLifecycleLock repair-dev-branch-tooling | Should -BeTrue
        $entry=Get-Content $context.HelperPath -Raw -Encoding UTF8
        $entry | Should -Match '"repair-dev-branch-tooling" \{ Repair-DevBranchTooling \}'
        $compact=Get-Content (Join-Path $context.RepoRoot '.agents/skills/1c-workflow/scripts/run-itl-command.ps1') -Raw -Encoding UTF8
        $compact | Should -Match '"repair-dev-branch-tooling"'
    }
}

Describe "YAxUnit selective installation" {
    BeforeEach {
        $script:engine=New-ReadyToolingRuntime YAXUNIT engine-hash
        $script:testsRuntime=New-ReadyToolingRuntime ПМ5Тесты tests-hash
        $script:toolingState=[pscustomobject]@{
            devBranchName="branch"; infoBaseKind="file"; devBranchInfoBasePath="C:\Тест базы\branch"; toolingInfoBaseGeneration="generation"
            yaxunitInstallationProof=[pscustomobject]@{
                schemaVersion=1; generation="generation"; infoBaseKey="base-key"; engineSha256="pinned-sha"
                engineName="YAXUNIT"; testsName="ПМ5Тесты"
                engineRuntimeHash="engine-hash"; testsRuntimeHash="tests-hash"; testsFingerprint="source"
            }
        }
        Mock Ensure-DevBranchToolingGeneration { param($State) $State }
        Mock Get-YAxUnitExtensionName { "YAXUNIT" }
        Mock Get-YAxUnitTestsExtensionName { "ПМ5Тесты" }
        Mock Get-YAxUnitTestsPath { "tests/yaxunit" }
        Mock Resolve-ProjectPath { "C:\Тест проекта\tests" }
        Mock Read-Utf8Text { '<MetaDataObject><Configuration><Properties><Name>ПМ5Тесты</Name></Properties></Configuration></MetaDataObject>' }
        Mock Get-ConfigSourceFingerprint { [pscustomobject]@{fingerprint="source"} }
        Mock Get-YAxUnitPinnedEntry { [pscustomobject]@{sha256="pinned-sha"} }
        Mock Install-YAxUnit { "C:\Кеш тестов\YAxUnit.cfe" }
        Mock Get-OneCInfoBaseIdentity { [pscustomobject]@{key="base-key"} }
        Mock Get-ToolingRuntimeExtensions { @($script:engine,$script:testsRuntime) }
        Mock Stop-DevBranchRuntimeBeforeInfobaseMutation {}
        Mock Invoke-Designer {}
        Mock Install-ItlOnDemandMcp {}
        Mock Set-VanessaMcpExtensionUnsafeMode {}
        Mock Update-DevBranchState {
            param($State,$Updates)
            foreach ($key in $Updates.Keys) { $script:toolingState | Add-Member -NotePropertyName $key -NotePropertyValue $Updates[$key] -Force }
        }
        Mock Read-DevBranchState { $script:toolingState }
    }

    It "does not stop runtime or invoke Designer when both extensions are unchanged and active" {
        Ensure-YAxUnitExtensions $script:toolingState | Out-Null
        Should -Invoke Invoke-Designer -Times 0 -Exactly
        Should -Invoke Stop-DevBranchRuntimeBeforeInfobaseMutation -Times 0 -Exactly
        Should -Invoke Set-VanessaMcpExtensionUnsafeMode -Times 0 -Exactly
    }

    It "loads only the test extension when its sources changed" {
        Mock Get-ConfigSourceFingerprint { [pscustomobject]@{fingerprint="edited"} }
        Ensure-YAxUnitExtensions $script:toolingState | Out-Null
        Should -Invoke Invoke-Designer -Times 1 -Exactly -ParameterFilter { $DesignerArgs[0] -eq '/LoadConfigFromFiles' }
        Should -Invoke Set-VanessaMcpExtensionUnsafeMode -Times 0 -Exactly
        $script:toolingState.yaxunitInstallationProof.testsFingerprint | Should -Be edited
    }

    It "loads only the engine when the pinned CFE changes" {
        Mock Get-YAxUnitPinnedEntry { [pscustomobject]@{sha256="new-pin"} }
        Ensure-YAxUnitExtensions $script:toolingState | Out-Null
        Should -Invoke Invoke-Designer -Times 1 -Exactly -ParameterFilter { $DesignerArgs[0] -eq '/LoadCfg' }
        Should -Invoke Set-VanessaMcpExtensionUnsafeMode -Times 1 -Exactly
    }

    It "reloads both after database replacement at the same path" {
        $script:toolingState.toolingInfoBaseGeneration="replacement"
        Ensure-YAxUnitExtensions $script:toolingState | Out-Null
        Should -Invoke Invoke-Designer -Times 2 -Exactly
    }

    It "does not preserve successful proof after interrupted loading" {
        $script:toolingState.toolingInfoBaseGeneration="replacement"
        Mock Invoke-Designer { throw "load interrupted" }
        { Ensure-YAxUnitExtensions $script:toolingState } | Should -Throw '*load interrupted*'
        $script:toolingState.yaxunitInstallationProof | Should -BeNullOrEmpty
    }

    It "fails before mutation if configured test extension name differs from metadata" {
        Mock Get-YAxUnitTestsExtensionName { "tests" }
        { Ensure-YAxUnitExtensions $script:toolingState } | Should -Throw '*ITL_YAXUNIT_TEST_EXTENSION_NAME_MISMATCH*'
        Should -Invoke Invoke-Designer -Times 0 -Exactly
    }

    It "does not retry indefinitely or record proof when an extension remains inactive" {
        $script:testsRuntime.active=$false
        { Ensure-YAxUnitExtensions $script:toolingState } | Should -Throw '*ITL_TOOLING_EXTENSION_NOT_READY*'
        Should -Invoke Invoke-Designer -Times 1 -Exactly
        $script:toolingState.yaxunitInstallationProof | Should -BeNullOrEmpty
    }
}

Describe "Primary verification failure classification" {
    It "preserves a YAxUnit runner failure even if recording its state also fails" {
        $script:RunErrorCategory=""
        $script:RunRequiredAction=""
        Mock Test-YAxUnitSuitePresent { $true }
        Mock Get-YAxUnitReportsPath { $TestDrive }
        Mock Get-YAxUnitTestsPath { 'tests/yaxunit' }
        Mock Get-YAxUnitExtensionName { 'YAXUNIT' }
        Mock Get-YAxUnitTestsExtensionName { 'tests' }
        Mock Get-YAxUnitPinnedEntry { [pscustomobject]@{sha256='pin'} }
        Mock Ensure-YAxUnitExtensions { throw 'ITL_YAXUNIT_REPORT_MISSING: primary cause' }
        Mock Update-DevBranchState { throw 'secondary write failure' }
        { Invoke-YAxUnitVerification -State ([pscustomobject]@{devBranchName='branch'}) } | Should -Throw '*ITL_YAXUNIT_REPORT_MISSING: primary cause*'
        $script:RunErrorCategory | Should -Be runner
        $script:RunRequiredAction | Should -Be '/itl-verify-fix'
    }

    It "keeps the original failure category for <Message>" -TestCases @(
        @{Message='ITL_YAXUNIT_ZERO_TESTS: zero'; Category='missing-suite'},
        @{Message='ITL_YAXUNIT_TESTS_FAILED: assertion'; Category='product-assertion'},
        @{Message='ITL_YAXUNIT_REPORT_MISSING: missing'; Category='runner'},
        @{Message='ITL_TOOLING_EXTENSION_NOT_READY: VAExtension'; Category='runner'}
    ) {
        param($Message,$Category)
        $script:RunErrorCategory=""
        $script:RunRequiredAction=""
        Set-RunFailureContextFromMessage -Message $Message -RequestedAction check-dev-branch
        $script:RunErrorCategory | Should -Be $Category
    }
}

Describe "Vanessa readiness reconciliation" {
    BeforeEach {
        $script:probeClient=New-ReadyToolingRuntime client_mcp client-hash
        $script:probeTarget=New-ReadyToolingRuntime VAExtension va-hash
        $script:state=[pscustomobject]@{
            devBranchName='branch'; vanessaMcpClientMcpCfePath='client.cfe'; vanessaMcpVaExtensionCfePath='va.cfe'
            vanessaMcpClientMcpSha256='client-pin'; vanessaMcpVaExtensionSha256='va-pin'
            vanessaMcpSafeModeProof=[pscustomobject]@{clientRuntimeHash='client-hash'; vaRuntimeHash='va-hash'}
        }
        Mock Ensure-DevBranchToolingGeneration { $script:state }
        Mock Ensure-VanessaServiceInfoBase { [pscustomobject]@{kind='file';path='service';user='service-user';password=''} }
        Mock Read-DevBranchState { $script:state }
        Mock Install-VanessaMcpArtifacts { @([pscustomobject]@{key='clientMcp';sha256='client-pin'},[pscustomobject]@{key='vaExtension';sha256='va-pin'}) }
        Mock Test-Path { $true }
        Mock Test-VanessaMcpSafeModeProofMatchesState { $true }
        Mock Get-ToolingRuntimeExtensions {
            param($State,$Names,$User,$Password)
            if ($Names[0] -ceq 'client_mcp') {
                $State.devBranchInfoBasePath | Should -Be service
                $User | Should -Be service-user
                return $script:probeClient
            }
            return $script:probeTarget
        }
        Mock Install-VanessaMcp {}
    }

    It "does not reinstall healthy runtime" {
        Ensure-VanessaMcpInstalled $script:state | Out-Null
        Should -Invoke Install-VanessaMcp -Times 0 -Exactly
        Should -Invoke Get-ToolingRuntimeExtensions -Times 2 -Exactly
    }

    It "restores a missing target despite matching saved proof and CFE files" {
        $script:probeTarget.present=$false
        Ensure-VanessaMcpInstalled $script:state | Out-Null
        Should -Invoke Install-VanessaMcp -Times 1 -Exactly
    }

    It "does not reuse proof after the dependency pin changes" {
        $script:state.vanessaMcpVaExtensionSha256='old-pin'
        Ensure-VanessaMcpInstalled $script:state | Out-Null
        Should -Invoke Install-VanessaMcp -Times 1 -Exactly
    }

    It "does not reinstall blindly after an inconclusive probe" {
        Mock Get-ToolingRuntimeExtensions { throw 'ITL_TOOLING_PROBE_FAILED: timeout' }
        { Ensure-VanessaMcpInstalled $script:state } | Should -Throw '*ITL_TOOLING_PROBE_FAILED*'
        Should -Invoke Install-VanessaMcp -Times 0 -Exactly
    }
}

Describe "Tooling recovery receipt" {
    BeforeEach {
        $script:receiptState=[pscustomobject]@{devBranchName='branch';toolingMutationId='new-mutation';toolingMutationAt='2026-09-07T21:30:00Z'}
        Mock Read-CurrentDevBranchStateForVanessaMcp { $script:receiptState }
        Mock Read-DevBranchState { $script:receiptState }
        Mock Assert-DevelopmentBranchWorktreeContext {}
        Mock Stop-DevBranchRuntimeBeforeInfobaseMutation {}
        Mock Ensure-VanessaMcpInstalled { $script:receiptState }
        Mock Test-YAxUnitSuitePresent { $true }
        Mock Ensure-YAxUnitExtensions { $script:receiptState }
        Mock Set-RunUserReport {}
        Mock Update-DevBranchState {
            param($State,$Updates)
            foreach ($key in $Updates.Keys) { $script:receiptState | Add-Member -NotePropertyName $key -NotePropertyValue $Updates[$key] -Force }
        }
    }

    It "preserves the actual mutation time and grants only one receipt for it" {
        Repair-DevBranchTooling
        $firstId=$script:receiptState.toolingRecoveryId
        $script:receiptState.toolingRecoveredMutationAt | Should -Be '2026-09-07T21:30:00Z'
        Repair-DevBranchTooling
        $script:receiptState.toolingRecoveryId | Should -Be $firstId
        Should -Invoke Update-DevBranchState -Times 1 -Exactly
    }

    It "cannot issue a successful receipt after a partial recovery failure" {
        Mock Ensure-YAxUnitExtensions { throw 'test extension did not activate' }
        { Repair-DevBranchTooling } | Should -Throw '*did not activate*'
        Should -Invoke Update-DevBranchState -Times 0 -Exactly
    }
}

Describe "Exhausted repair session after tooling recovery" {
    BeforeEach {
        $script:DevBranchName='branch'
        $script:sessionPath=Join-Path $TestDrive 'current.json'
        $script:previous=[pscustomobject]@{sessionId='old-session';status='exhausted';attempts=5;maximumAttempts=5;updatedAt='2026-09-07T21:00:00Z';toolingRecoveryId='old-recovery'}
        [IO.File]::WriteAllText($script:sessionPath,($script:previous | ConvertTo-Json))
        $script:recoveryState=[pscustomobject]@{toolingRecoveryId='new-recovery';toolingRecoveredAt='2026-09-07T22:00:00Z';toolingRecoveredMutationAt='2026-09-07T21:30:00Z'}
        Mock Read-DevBranchState { $script:recoveryState }
        Mock Assert-DevelopmentBranchWorktreeContext {}
        Mock Get-ItlVerificationRepairStatePath { $script:sessionPath }
        Mock Get-CurrentBranch { 'itldev/branch' }
        Mock Set-RunUserReport {}
    }

    It "archives the exhausted record and starts a bounded session after proved recovery" {
        Start-ItlVerificationRepairSession
        $old=Get-Content (Join-Path $TestDrive 'history/old-session.json') -Raw | ConvertFrom-Json
        $old.attempts | Should -Be 5
        $old.status | Should -Be exhausted
        $new=Get-Content $script:sessionPath -Raw | ConvertFrom-Json
        $new.sessionId | Should -Not -Be old-session
        $new.toolingRecoveryId | Should -Be new-recovery
        $new.attempts | Should -Be 0
        $new.maximumAttempts | Should -Be 5
    }

    It "cannot refresh the budget with the same receipt" {
        $script:recoveryState.toolingRecoveryId='old-recovery'
        { Start-ItlVerificationRepairSession } | Should -Throw '*ITL_VERIFICATION_REPAIR_EXHAUSTED*'
        (Get-Content $script:sessionPath -Raw | ConvertFrom-Json).attempts | Should -Be 5
    }

    It "cannot refresh the budget using a recovery predating exhaustion" {
        $script:recoveryState.toolingRecoveredAt='2026-09-07T20:00:00Z'
        { Start-ItlVerificationRepairSession } | Should -Throw '*ITL_VERIFICATION_REPAIR_EXHAUSTED*'
    }

    It "cannot turn an older installation into a new budget by issuing its receipt later" {
        $script:recoveryState.toolingRecoveredMutationAt='2026-09-07T20:00:00Z'
        { Start-ItlVerificationRepairSession } | Should -Throw '*ITL_VERIFICATION_REPAIR_EXHAUSTED*'
        (Get-Content $script:sessionPath -Raw | ConvertFrom-Json).attempts | Should -Be 5
    }
}
