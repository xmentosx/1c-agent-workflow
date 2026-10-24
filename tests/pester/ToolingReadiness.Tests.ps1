BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSupport.ps1')
    $context = Initialize-WorkflowPesterContext
    . $context.HelperPath -ProjectRoot $context.RepoRoot -Action help *> $null
    . (Join-Path $context.RepoRoot 'scripts/git-path-list.ps1')
    function New-ReadyToolingRuntime {
        param([string]$Name, [string]$Hash = "runtime-hash")
        [pscustomobject]@{ name=$Name; present=$true; active=$true; safeMode=$false; unsafeActionProtection=$false; contentHash=$Hash; serverCodeObject=$true }
    }
}

Describe 'Shared verification failure ownership' {
    BeforeEach {
        $script:RunErrorCategory = ''
        $script:RunRequiredAction = ''
        Mock Test-ItlDiagnosticVerificationScope { $false }
    }

    It 'keeps the same known owner in core and Vanessa for <Name>' -ForEach @(
        @{Name='Designer command allowlist'; Message='ITL_DESIGNER_AGENT_COMMANDS_INVALID: expected pinned commands'; Category='runner'; RequiredAction='repair-dev-branch-tooling'},
        @{Name='wrapped Designer client'; Message="ITL_DESIGNER_AGENT_CLIENT_FAILED: exitCode=1 error='ITL_DESIGNER_AGENT_COMMANDS_INVALID: expected sequence'"; Category='runner'; RequiredAction='repair-dev-branch-tooling'},
        @{Name='tooling readiness'; Message='ITL_TOOLING_EXTENSION_NOT_READY: expected tests'; Category='runner'; RequiredAction='repair-dev-branch-tooling'},
        @{Name='project tests capability'; Message='ITL_PROJECT_TESTS_CONTENT_PROOF_INVALID: expected tests'; Category='runner'; RequiredAction='repair-dev-branch-tooling'},
        @{Name='actual product assertion'; Message='Expected 120, actual 100'; Category='product-assertion'; RequiredAction='/itl-verify-fix'},
        @{Name='product assertion quoting a diagnostic'; Message='Expected "{ВнешняяОбработка.VanessaAutomationsingle.Форма.Тест_ВстроенныйЯзык.Форма(613)}: Ошибка компиляции при вычислении выражения или выполнении фрагмента кода: {<Неизвестный модуль>(1,1)}"'; Category='product-assertion'; RequiredAction='/itl-verify-fix'},
        @{Name='diagnostic body compilation'; Message='{ВнешняяОбработка.VanessaAutomationsingle.Форма.Тест_ВстроенныйЯзык.Форма(613)}: Ошибка компиляции при вычислении выражения или выполнении фрагмента кода: {<Неизвестный модуль>(1,1)}: Перем ИсходноеЗначение;'; Category='test-fixture'; RequiredAction='/itl-verify-fix'},
        @{Name='unsupported step'; Message='undefined step'; Category='unsupported-step'; RequiredAction='/itl-verify-fix'}
        @{Name='specific YAxUnit failure before generic missing suite'; Message='ITL_YAXUNIT_TESTS_FAILED: expected missing-suite'; Category='product-assertion'; RequiredAction='/itl-verify-fix'},
        @{Name='explicit fixture before generic assertion'; Message='ITL_VANESSA_TEST_FIXTURE_UNRESOLVED_PROFILE: expected test context'; Category='test-fixture'; RequiredAction='/itl-verify-fix'}
    ) {
        param($Message,$Category,$RequiredAction)
        Set-RunFailureContextFromMessage -Message $Message -RequestedAction check-dev-branch
        $script:RunErrorCategory | Should -Be $Category
        $script:RunRequiredAction | Should -Be $RequiredAction
        $route = Get-VanessaVerificationFailureRoute -Verification ([pscustomobject]@{status='failed';reason=$Message}) -EventLogVerification ([pscustomobject]@{status='passed'})
        $route.category | Should -Be $Category
        $route.requiredAction | Should -Be $RequiredAction
    }

    It 'does not attribute a product module or unknown compilation to the diagnostic body' -ForEach @(
        @{Message='{ОбщийМодуль.Продукт.Модуль(10)}: Ошибка компиляции при вычислении выражения или выполнении фрагмента кода: {<Неизвестный модуль>(1,1)}'},
        @{Message='{ВнешняяОбработка.VanessaAutomationsingle.Форма.Тест_ВстроенныйЯзык.Форма(613)}: {ОбщийМодуль.Продукт.Модуль(10)}: Ошибка компиляции при вычислении выражения или выполнении фрагмента кода'},
        @{Message='Ошибка компиляции: source unknown'}
    ) {
        param($Message)
        $route = Get-VanessaVerificationFailureRoute -Verification ([pscustomobject]@{status='failed';reason=$Message}) -EventLogVerification ([pscustomobject]@{status='passed'})
        $route.category | Should -Be product-assertion
        Set-RunFailureContextFromMessage -Message ('ITL_CONFIG_LOAD_FAILED: ' + $Message) -RequestedAction check-dev-branch
        $script:RunErrorCategory | Should -Be config-load-failed
    }

    It 'preserves a structured fixture category and independent event log failure' {
        $verification = [pscustomobject]@{status='failed';reason='Expected diagnostics';failureCategory='test-fixture'}
        (Get-VanessaVerificationFailureRoute -Verification $verification -EventLogVerification ([pscustomobject]@{status='passed'})).category | Should -Be test-fixture
        (Get-VanessaVerificationFailureRoute -Verification $verification -EventLogVerification ([pscustomobject]@{status='failed'})).category | Should -Be event-log
    }

    It 'carries the primary owner and continuation through JUnit for <Name>' -ForEach @(
        @{Name='tooling before connection heuristic'; Message='ITL_DESIGNER_AGENT_CLIENT_FAILED: failed to connect TestClient; connection timeout'; Category='runner'; RequiredAction='repair-dev-branch-tooling'},
        @{Name='diagnostic compilation'; Message='{ВнешняяОбработка.VanessaAutomationsingle.Форма.Тест_ВстроенныйЯзык.Форма(613)}: Ошибка компиляции при вычислении выражения или выполнении фрагмента кода: {<Неизвестный модуль>(1,1)}: Перем ИсходноеЗначение;'; Category='test-fixture'; RequiredAction='/itl-verify-fix'},
        @{Name='existing tag filter route'; Message='ITL_VANESSA_TAG_FILTER_EMPTY: diagnostic'; Category='runner'; RequiredAction=''}
    ) {
        param($Message,$Category,$RequiredAction)
        $root = Join-Path $TestDrive 'Результат с пробелом'
        [IO.Directory]::CreateDirectory($root) | Out-Null
        $escaped = [Security.SecurityElement]::Escape($Message)
        [IO.File]::WriteAllText((Join-Path $root 'junit.xml'), ('<testsuite tests="1" failures="1" errors="0"><testcase name="original"><failure>' + $escaped + '</failure></testcase></testsuite>'), [Text.UTF8Encoding]::new($false))
        $verification = Get-VanessaVerificationStatus -RunDirectory $root -StatusPath (Join-Path $root 'missing.json')
        $verification.status | Should -Be failed
        $verification.failureCategory | Should -Be $Category
        $route = Get-VanessaVerificationFailureRoute -Verification $verification -EventLogVerification ([pscustomobject]@{status='passed'})
        $route.category | Should -Be $Category
        $route.requiredAction | Should -Be $RequiredAction
        $verification.reason | Should -Match ([regex]::Escape($Message))
    }
}

Describe "Tooling runtime Git isolation" {
    It "keeps actual probe artifacts ignored after rollback to the pre-probe Git baseline" {
        $savedRoot=$script:ProjectRoot
        $root=Join-Path $TestDrive ("Откат probe " + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        try {
            & git -C $root init --quiet
            $sourceRelative='.agents/skills/1c-workflow/tools/tooling-probe'
            $sourceParent=Split-Path -Parent (Join-Path $root $sourceRelative)
            New-Item -ItemType Directory -Path $sourceParent -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $context.RepoRoot $sourceRelative) -Destination $sourceParent -Recurse
            [IO.File]::WriteAllText((Join-Path $root '.gitignore'), ".agent-1c/tmp/`nbuild/test-results/`n")
            & git -C $root add -- .
            & git -C $root -c user.name=Test -c user.email=test@example.invalid commit --quiet -m baseline
            $baseline=(& git -C $root rev-parse HEAD).Trim()
            $script:ProjectRoot=$root
            Mock Invoke-Designer {
                param($DesignerArgs)
                [IO.File]::WriteAllText($DesignerArgs[-1], 'probe fixture')
            }
            Mock Invoke-Enterprise {
                param($EnterpriseArgs)
                $requestPath=$EnterpriseArgs[-1].Substring('/CToolingProbe;Params='.Length)
                $request=Get-Content -LiteralPath $requestPath -Raw -Encoding UTF8 | ConvertFrom-Json
                Write-Utf8Text -Path $request.outputPath -Value (@{
                    status='passed'; nonce=$request.nonce; extensions=@(New-ReadyToolingRuntime VAExtension)
                } | ConvertTo-Json -Depth 5)
            }
            $state=[pscustomobject]@{ infoBaseKind='file'; devBranchInfoBasePath=(Join-Path $root 'База теста') }
            $runtime=@(Get-ToolingRuntimeExtensions -State $state -Names @('VAExtension') -User '' -Password '')
            $runtime.Count | Should -Be 1
            $runtime[0].active | Should -BeTrue
            Ensure-GitIgnore
            & git -C $root add -- .gitignore
            & git -C $root -c user.name=Test -c user.email=test@example.invalid commit --quiet -m current
            & git -C $root reset --hard $baseline | Out-Null
            $LASTEXITCODE | Should -Be 0
            @(Get-RepositoryGitPathList -RepositoryRoot $root -Arguments @('ls-files','--others','--exclude-standard','-z')).Count | Should -Be 0
            (Invoke-RepositoryGit -RepositoryRoot $root -Arguments @('diff','--exit-code') -AllowFailure).exitCode | Should -Be 0
            $ignored=@(Get-RepositoryGitPathList -RepositoryRoot $root -Arguments @('ls-files','--others','--ignored','--exclude-standard','-z'))
            $ignored.Count | Should -Be 3
            @($ignored | Where-Object { $_ -like '.agent-1c/tmp/tooling-probe/*/ToolingProbe.epf' }).Count | Should -Be 1
            @($ignored | Where-Object { $_ -like 'build/test-results/tooling-probe/*/*.json' }).Count | Should -Be 2
            (Invoke-RepositoryGit -RepositoryRoot $root -Arguments @('check-ignore','--quiet','--','build/user-evidence.txt') -AllowFailure).exitCode | Should -Be 1
        } finally { $script:ProjectRoot=$savedRoot }
    }

    It "ignores probe artifacts before a checkpoint with legacyTemplate=<LegacyTemplate>" -TestCases @(
        @{ LegacyTemplate=$true }, @{ LegacyTemplate=$false }
    ) {
        param($LegacyTemplate)
        $savedRoot=$script:ProjectRoot
        $root=Join-Path $TestDrive ("Стенд probe " + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        try {
            & git -C $root init --quiet
            $script:ProjectRoot=$root
            if ($LegacyTemplate) {
                New-Item -ItemType Directory -Path (Join-Path $root 'templates') -Force | Out-Null
                [IO.File]::WriteAllText((Join-Path $root 'templates/gitignore.append'), "*.log" + [Environment]::NewLine)
            }
            $runtimePaths=@('.agent-1c/tools/tooling-probe/hash/ToolingProbe.epf','build/tooling-probe/run/request.json','build/tooling-probe/run/result.json')
            foreach ($relative in $runtimePaths + @('build/user-evidence.txt')) {
                $path=Join-Path $root $relative
                New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
                [IO.File]::WriteAllText($path,'fixture')
            }
            Ensure-GitIgnore
            Ensure-GitIgnore
            $ignored=@(Get-RepositoryGitPathList -RepositoryRoot $root -Arguments (@('ls-files','--others','--ignored','--exclude-standard','-z','--') + $runtimePaths))
            $ignored | Should -Be $runtimePaths
            (Invoke-RepositoryGit -RepositoryRoot $root -Arguments @('check-ignore','--quiet','--','build/user-evidence.txt') -AllowFailure).exitCode | Should -Be 1
            $lines=Get-Content -LiteralPath (Join-Path $root '.gitignore')
            @($lines | Where-Object { $_ -eq '.agent-1c/tools/tooling-probe/' }).Count | Should -Be 1
            @($lines | Where-Object { $_ -eq 'build/tooling-probe/' }).Count | Should -Be 1
            $template=Get-Content -LiteralPath (Join-Path $context.RepoRoot 'templates/gitignore.append') -Raw
            $template | Should -Match ([regex]::Escape('.agent-1c/tools/tooling-probe/'))
            $template | Should -Match ([regex]::Escape('build/tooling-probe/'))
        } finally { $script:ProjectRoot=$savedRoot }
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
        Mock Get-YAxUnitProjectTestsSafeModeOptIn { $false }
        Mock Invoke-WithOneCExecutionGuard {
            param($Admissions,$Purpose,$ScriptBlock)
            $Purpose | Should -Be 'project-tests-safe-mode'
            $Admissions.Count | Should -Be 1
            $Admissions[0].infoBasePath | Should -Be $script:toolingState.devBranchInfoBasePath
            $previous=[Environment]::GetEnvironmentVariable('ITL_EXECUTION_CONTEXT','Process')
            try {
                [Environment]::SetEnvironmentVariable('ITL_EXECUTION_CONTEXT','live-parent-context','Process')
                & $ScriptBlock
            } finally { [Environment]::SetEnvironmentVariable('ITL_EXECUTION_CONTEXT',$previous,'Process') }
        }
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
        Mock Invoke-GuardedCfeExtensionApply {}
        Mock Invoke-ConfigLoadDesignerAttempt {}
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
        Should -Invoke Invoke-GuardedCfeExtensionApply -Times 0 -Exactly
        Should -Invoke Invoke-ConfigLoadDesignerAttempt -Times 0 -Exactly
        Should -Invoke Stop-DevBranchRuntimeBeforeInfobaseMutation -Times 0 -Exactly
        Should -Invoke Set-VanessaMcpExtensionUnsafeMode -Times 0 -Exactly
    }

    It "loads only the test extension when its sources changed" {
        Mock Get-ConfigSourceFingerprint { [pscustomobject]@{fingerprint="edited"} }
        Ensure-YAxUnitExtensions $script:toolingState | Out-Null
        Should -Invoke Invoke-ConfigLoadDesignerAttempt -Times 1 -Exactly -ParameterFilter { $DesignerArgs[0] -eq '/LoadConfigFromFiles' }
        Should -Invoke Invoke-GuardedCfeExtensionApply -Times 0 -Exactly
        Should -Invoke Set-VanessaMcpExtensionUnsafeMode -Times 0 -Exactly
        $script:toolingState.yaxunitInstallationProof.testsFingerprint | Should -Be edited
    }

    It "loads only the engine when the pinned CFE changes" {
        Mock Get-YAxUnitPinnedEntry { [pscustomobject]@{sha256="new-pin"} }
        Ensure-YAxUnitExtensions $script:toolingState | Out-Null
        Should -Invoke Invoke-GuardedCfeExtensionApply -Times 1 -Exactly -ParameterFilter { $ExtensionName -eq 'YAXUNIT' }
        Should -Invoke Invoke-ConfigLoadDesignerAttempt -Times 0 -Exactly
        Should -Invoke Set-VanessaMcpExtensionUnsafeMode -Times 1 -Exactly
    }

    It "reloads both after database replacement at the same path" {
        $script:toolingState.toolingInfoBaseGeneration="replacement"
        Ensure-YAxUnitExtensions $script:toolingState | Out-Null
        Should -Invoke Invoke-GuardedCfeExtensionApply -Times 1 -Exactly
        Should -Invoke Invoke-ConfigLoadDesignerAttempt -Times 1 -Exactly
    }

    It "does not preserve successful proof after interrupted loading" {
        $script:toolingState.toolingInfoBaseGeneration="replacement"
        Mock Invoke-GuardedCfeExtensionApply { throw "load interrupted" }
        { Ensure-YAxUnitExtensions $script:toolingState } | Should -Throw '*load interrupted*'
        $script:toolingState.yaxunitInstallationProof | Should -BeNullOrEmpty
    }

    It "fails before mutation if configured test extension name differs from metadata" {
        Mock Get-YAxUnitTestsExtensionName { "tests" }
        { Ensure-YAxUnitExtensions $script:toolingState } | Should -Throw '*ITL_YAXUNIT_TEST_EXTENSION_NAME_MISMATCH*'
        Should -Invoke Invoke-Designer -Times 0 -Exactly
        Should -Invoke Invoke-GuardedCfeExtensionApply -Times 0 -Exactly
        Should -Invoke Invoke-ConfigLoadDesignerAttempt -Times 0 -Exactly
    }

    It "does not retry indefinitely or record proof when an extension remains inactive" {
        $script:testsRuntime.active=$false
        { Ensure-YAxUnitExtensions $script:toolingState } | Should -Throw '*ITL_TOOLING_EXTENSION_NOT_READY*'
        Should -Invoke Invoke-ConfigLoadDesignerAttempt -Times 1 -Exactly
        $script:toolingState.yaxunitInstallationProof | Should -BeNullOrEmpty
    }

    It 'refreshes a legacy content proof under the exact-base guard without reload or setter when SafeMode is already off' {
        Mock Get-YAxUnitProjectTestsSafeModeOptIn { $true }
        $script:testsRuntime.unsafeActionProtection=$true
        Ensure-YAxUnitExtensions $script:toolingState | Out-Null
        Should -Invoke Invoke-WithOneCExecutionGuard -Times 1 -Exactly
        Should -Invoke Stop-DevBranchRuntimeBeforeInfobaseMutation -Times 1 -Exactly
        Should -Invoke Invoke-ConfigLoadDesignerAttempt -Times 0 -Exactly
        Should -Invoke Invoke-GuardedCfeExtensionApply -Times 0 -Exactly
        Should -Invoke Set-VanessaMcpExtensionUnsafeMode -Times 0 -Exactly
        $proof=$script:toolingState.yaxunitInstallationProof
        $proof.schemaVersion | Should -Be 1
        $proof.testsSafeModeRequired | Should -BeTrue
        $proof.testsUnsafeActionProtection | Should -BeTrue
        $proof.projectTestsSettingsPending | Should -BeFalse
        $proof.projectTestsHelperSha256 | Should -Be (Get-FileHash (Join-Path $context.RepoRoot '.agents/skills/1c-workflow/scripts/lib/agent-1c.yaxunit.ps1') -Algorithm SHA256).Hash.ToLowerInvariant()
        Ensure-YAxUnitExtensions $script:toolingState | Out-Null
        Should -Invoke Invoke-WithOneCExecutionGuard -Times 1 -Exactly
    }

    It 'changes only project SafeMode, preserves protection/content and records both component and helper identity' {
        Mock Get-YAxUnitProjectTestsSafeModeOptIn { $true }
        $script:testsRuntime.safeMode=$true
        $script:testsRuntime.unsafeActionProtection=$true
        Mock Set-VanessaMcpExtensionUnsafeMode {
            param($ExtensionName,$Scope,$ProjectTestsContentProof,$ReconcileYAxUnitProtections)
            $ExtensionName | Should -Be 'ПМ5Тесты'
            $Scope | Should -Be 'project-tests'
            $ReconcileYAxUnitProtections | Should -BeFalse
            $script:toolingState.yaxunitInstallationProof.projectTestsSettingsPending | Should -BeTrue
            $ProjectTestsContentProof.runtimeContentHash | Should -Be tests-hash
            $ProjectTestsContentProof.unsafeActionProtection | Should -BeTrue
            $ProjectTestsContentProof.executionContextSha256 | Should -Be (Get-StringSha256 'live-parent-context')
            $script:testsRuntime.safeMode=$false
            [pscustomobject]@{facadeSha256=('a'*64);safeMode=$false}
        }
        Ensure-YAxUnitExtensions $script:toolingState | Out-Null
        Should -Invoke Set-VanessaMcpExtensionUnsafeMode -Times 1 -Exactly
        Should -Invoke Invoke-ConfigLoadDesignerAttempt -Times 0 -Exactly
        Should -Invoke Invoke-GuardedCfeExtensionApply -Times 0 -Exactly
        $script:toolingState.yaxunitInstallationProof.testsUnsafeActionProtection | Should -BeTrue
        $script:toolingState.yaxunitInstallationProof.testsRuntimeHash | Should -Be tests-hash
        $script:toolingState.yaxunitInstallationProof.projectTestsCapabilityEvidence.facadeSha256 | Should -Be ('a'*64)
        $script:toolingState.toolingMutationId | Should -Not -BeNullOrEmpty
    }

    It 'refuses incomplete runtime security evidence rather than interpreting it as SafeMode off' {
        Mock Get-YAxUnitProjectTestsSafeModeOptIn { $true }
        $script:testsRuntime.safeMode=$null
        { Ensure-YAxUnitExtensions $script:toolingState } | Should -Throw '*ITL_PROJECT_TESTS_SECURITY_PROOF_INVALID*'
        Should -Invoke Set-VanessaMcpExtensionUnsafeMode -Times 0 -Exactly
    }

    It 'retains pending evidence if the setter changes <ChangedField> instead of repairing the reproducer' -ForEach @(
        @{ChangedField='contentHash'}, @{ChangedField='unsafeActionProtection'}
    ) {
        param($ChangedField)
        Mock Get-YAxUnitProjectTestsSafeModeOptIn { $true }
        $script:testsRuntime.safeMode=$true
        $script:testsRuntime.unsafeActionProtection=$true
        $script:changedField=$ChangedField
        Mock Set-VanessaMcpExtensionUnsafeMode {
            $script:testsRuntime.safeMode=$false
            if ($script:changedField -eq 'contentHash') { $script:testsRuntime.contentHash='different' }
            else { $script:testsRuntime.unsafeActionProtection=$false }
        }
        { Ensure-YAxUnitExtensions $script:toolingState } | Should -Throw '*ITL_PROJECT_TESTS_CONTENT_OR_PROTECTION_CHANGED*'
        $script:toolingState.yaxunitInstallationProof.projectTestsSettingsPending | Should -BeTrue
        Should -Invoke Set-VanessaMcpExtensionUnsafeMode -Times 1 -Exactly
        Should -Invoke Invoke-ConfigLoadDesignerAttempt -Times 0 -Exactly
    }

    It 'resolves an unknown setter from fresh state only after guarded drain, without replay or reload' {
        Mock Get-YAxUnitProjectTestsSafeModeOptIn { $true }
        $script:testsRuntime.safeMode=$true
        $script:testsRuntime.unsafeActionProtection=$true
        Mock Set-VanessaMcpExtensionUnsafeMode { throw 'connection lost: outcome unknown' }
        { Ensure-YAxUnitExtensions $script:toolingState } | Should -Throw '*outcome unknown*'
        $script:toolingState.yaxunitInstallationProof.projectTestsSettingsPending | Should -BeTrue
        $script:testsRuntime.safeMode=$false
        Ensure-YAxUnitExtensions $script:toolingState | Out-Null
        Should -Invoke Invoke-WithOneCExecutionGuard -Times 2 -Exactly
        Should -Invoke Stop-DevBranchRuntimeBeforeInfobaseMutation -Times 2 -Exactly
        Should -Invoke Set-VanessaMcpExtensionUnsafeMode -Times 1 -Exactly
        Should -Invoke Invoke-ConfigLoadDesignerAttempt -Times 0 -Exactly
        $script:toolingState.yaxunitInstallationProof.projectTestsSettingsPending | Should -BeFalse
    }

    It 'preserves an unresolved operation when its protection baseline changes or its target becomes foreign' -ForEach @(
        @{Foreign=$false}, @{Foreign=$true}
    ) {
        param($Foreign)
        Mock Get-YAxUnitProjectTestsSafeModeOptIn { $true }
        $proof=$script:toolingState.yaxunitInstallationProof
        $proof | Add-Member projectTestsSettingsPending $true
        $proof | Add-Member testsUnsafeActionProtectionBefore $true
        if ($Foreign) { $proof.infoBaseKey='foreign' }
        { Ensure-YAxUnitExtensions $script:toolingState } | Should -Throw $(if ($Foreign) {'*ITL_PROJECT_TESTS_CONTENT_PROOF_INVALID*'} else {'*ITL_PROJECT_TESTS_PROTECTION_CHANGED*'})
        Should -Invoke Set-VanessaMcpExtensionUnsafeMode -Times 0 -Exactly
        $script:toolingState.yaxunitInstallationProof.projectTestsSettingsPending | Should -BeTrue
    }

    It 'cannot bypass quiescence by opting out while a prior project operation remains pending' {
        $proof=$script:toolingState.yaxunitInstallationProof
        $proof | Add-Member projectTestsSettingsPending $true
        $proof | Add-Member testsUnsafeActionProtectionBefore $false
        Ensure-YAxUnitExtensions $script:toolingState | Out-Null
        Should -Invoke Invoke-WithOneCExecutionGuard -Times 1 -Exactly
        Should -Invoke Set-VanessaMcpExtensionUnsafeMode -Times 0 -Exactly
        $script:toolingState.yaxunitInstallationProof.projectTestsSettingsPending | Should -BeFalse
        $script:toolingState.yaxunitInstallationProof.testsSafeModeRequired | Should -BeFalse
    }
}

Describe 'Project test SafeMode project and task permission' {
    BeforeEach { $script:savedProjectConfig=$script:Config; $script:ProjectTestsSafeModeRequested=$false }
    AfterEach { $script:Config=$script:savedProjectConfig; $script:ProjectTestsSafeModeRequested=$false }
    It 'defaults to off and accepts only an explicit JSON true or false' {
        foreach ($json in @('{}','{"yaxunit":{}}','{"yaxunit":{"testsDisableSafeMode":false}}')) {
            $script:Config=$json | ConvertFrom-Json
            Get-YAxUnitProjectTestsSafeModeOptIn | Should -BeFalse
        }
        $script:Config='{"yaxunit":{"testsDisableSafeMode":true}}' | ConvertFrom-Json
        Get-YAxUnitProjectTestsSafeModeOptIn | Should -BeTrue
        foreach ($value in @('"true"','1','null')) {
            $script:Config=('{"yaxunit":{"testsDisableSafeMode":'+$value+'}}') | ConvertFrom-Json
            { Get-YAxUnitProjectTestsSafeModeOptIn } | Should -Throw '*ITL_PROJECT_TESTS_OPTION_INVALID*'
        }
    }
    It 'accepts a task request without changing project JSON and clears it on the next invocation' {
        $root=Join-Path $TestDrive ('Разрешённая задача '+[guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        & {
            . $context.HelperPath -ProjectRoot $root -Action help -DisableProjectTestsSafeMode *> $null
            Get-YAxUnitProjectTestsSafeModeOptIn | Should -BeTrue
            @(Get-Agent1cReexecArguments) | Should -Contain "-DisableProjectTestsSafeMode"
            Test-Path -LiteralPath (Join-Path $root '.agent-1c/project.json') | Should -BeFalse
            . $context.HelperPath -ProjectRoot $root -Action help *> $null
            Get-YAxUnitProjectTestsSafeModeOptIn | Should -BeFalse
        }
        . $context.HelperPath -ProjectRoot $context.RepoRoot -Action help *> $null
    }
    It 'accepts the exact Unicode identifier and rejects reserved roles, whitespace and command syntax' {
        foreach ($name in @('tests','ТестыPM5Канбан')) { { Assert-YAxUnitProjectTestsName $name } | Should -Not -Throw }
        foreach ($name in @('YAXUNIT','client_mcp','VAExtension','Тесты*','Тесты --safe-mode no','Два слова')) {
            { Assert-YAxUnitProjectTestsName $name } | Should -Throw '*ITL_PROJECT_TESTS_EXTENSION_NAME_INVALID*'
        }
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

    It "resumes the active session without resetting its outer attempt budget" {
        $script:previous.status = 'active'
        $script:previous.attempts = 2
        $script:previous.maximumAttempts = 3
        $script:previous | Add-Member -NotePropertyName projectRoot -NotePropertyValue $script:ProjectRoot
        $script:previous | Add-Member -NotePropertyName branch -NotePropertyValue 'itldev/branch'
        [IO.File]::WriteAllText($script:sessionPath, ($script:previous | ConvertTo-Json))
        $before = [IO.File]::ReadAllBytes($script:sessionPath)
        Start-ItlVerificationRepairSession
        Start-ItlVerificationRepairSession
        $after = [IO.File]::ReadAllBytes($script:sessionPath)
        $after | Should -Be $before
        $record = Get-Content $script:sessionPath -Raw | ConvertFrom-Json
        $record.sessionId | Should -Be 'old-session'
        $record.attempts | Should -Be 2
        $record.maximumAttempts | Should -Be 3
    }

    It "bounds a named scenario loop and requires a final unfiltered repair run" {
        $originalProjectRoot = $script:ProjectRoot
        $script:ProjectRoot = $TestDrive
        $script:attemptInput = 'source-1'
        Mock Get-VerificationFingerprint { $script:attemptInput }
        $features = Join-Path $TestDrive 'tests/features'
        New-Item -ItemType Directory -Force -Path $features | Out-Null
        foreach ($name in @('Named.feature', 'Other.feature')) {
            [IO.File]::WriteAllText((Join-Path $features $name), 'Функционал: Example', [Text.UTF8Encoding]::new($false))
        }
        $VerificationRepairKind = 'scenario-loop'
        $VanessaFeaturePath = 'tests/features/Named.feature'
        $VanessaFilterTags = ''
        $VerificationTrigger = 'repair'
        try {
            Start-ItlVerificationRepairSession
            $record = Get-Content $script:sessionPath -Raw | ConvertFrom-Json
            $RepairSessionId = [string]$record.sessionId
            $record.kind | Should -Be 'scenario-loop'
            $record.maximumAttempts | Should -Be 3
            $record.scenarioFeature | Should -Be (Resolve-ProjectPath $VanessaFeaturePath)
            Assert-ItlVerificationRepairScope -Trigger repair

            Mock Get-ItlVerificationMode { [pscustomobject]@{ key='ITL_VANESSA_TESTING'; raw='off'; effective='off'; valid=$true } }
            (Get-ItlVerificationExecutionDecision -Component vanessa -Trigger repair -ExplicitComponents @('vanessa')).run | Should -BeTrue
            Use-ItlVerificationRepairAttempt
            (Get-Content $script:sessionPath -Raw | ConvertFrom-Json).attempts | Should -Be 1
            { Use-ItlVerificationRepairAttempt } | Should -Throw '*ITL_VERIFICATION_REPAIR_NO_CHANGE*'
            (Get-Content $script:sessionPath -Raw | ConvertFrom-Json).attempts | Should -Be 1

            $namedFeature = Join-Path $features 'Named.feature'
            [IO.File]::WriteAllText($namedFeature, 'Функционал: Corrected precondition', [Text.UTF8Encoding]::new($false))
            Use-ItlVerificationRepairAttempt
            (Get-Content $script:sessionPath -Raw | ConvertFrom-Json).attempts | Should -Be 2
            Remove-Item -LiteralPath $namedFeature
            { Use-ItlVerificationRepairAttempt } | Should -Throw '*ITL_VERIFICATION_SCENARIO_FEATURE_MISSING*'
            (Get-Content $script:sessionPath -Raw | ConvertFrom-Json).attempts | Should -Be 2
            [IO.File]::WriteAllText($namedFeature, 'Функционал: Corrected precondition', [Text.UTF8Encoding]::new($false))

            $VerificationRepairMaxAttempts = 2
            Start-ItlVerificationRepairSession
            (Get-Content $script:sessionPath -Raw | ConvertFrom-Json).maximumAttempts | Should -Be 3
            $VerificationRepairMaxAttempts = 0

            $VanessaFeaturePath = 'tests/features/Other.feature'
            { Assert-ItlVerificationRepairScope -Trigger repair } | Should -Throw '*ITL_VERIFICATION_REPAIR_SCOPE_CHANGED*'
            { Start-ItlVerificationRepairSession } | Should -Throw '*ITL_VERIFICATION_REPAIR_SCOPE_CHANGED*'
            (Get-Content $script:sessionPath -Raw | ConvertFrom-Json).attempts | Should -Be 2

            $VanessaFeaturePath = ''
            Assert-ItlVerificationRepairScope -Trigger repair
            $script:attemptInput = 'source-2'
            Use-ItlVerificationRepairAttempt
            Complete-ItlVerificationRepairSession
            $finished = Get-Content $script:sessionPath -Raw | ConvertFrom-Json
            $finished.attempts | Should -Be 3
            $finished.status | Should -Be 'passed'
        } finally {
            $script:ProjectRoot = $originalProjectRoot
            $VerificationRepairKind = ''
            $VerificationRepairMaxAttempts = 0
            $VanessaFeaturePath = ''
            $VanessaFilterTags = ''
            $VerificationTrigger = ''
            $RepairSessionId = ''
        }
    }

    It 'continues the same bounded scenario after correcting a provider policy' {
        $savedRoot = $script:ProjectRoot
        $script:ProjectRoot = $TestDrive
        $script:browserPolicy = 'broken'
        Mock Get-VerificationFingerprint { 'same-source-and-loaded-base' }
        Mock Get-EnvValue {
            param($Name, $Default)
            if ($Name -eq 'TOOL_BROWSER') { return $script:browserPolicy }
            return $Default
        }
        $feature = Join-Path $TestDrive '.agent-1c/verification/scenario-loop/Проверка политики.feature'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $feature) | Out-Null
        [IO.File]::WriteAllText($feature, 'Функционал: Existing expected result', [Text.UTF8Encoding]::new($false))
        $VerificationRepairKind = 'scenario-loop'
        $VanessaFeaturePath = $feature
        $VanessaFilterTags = ''
        $VerificationTrigger = 'repair'
        try {
            Start-ItlVerificationRepairSession
            $session = Get-Content $script:sessionPath -Raw | ConvertFrom-Json
            $RepairSessionId = [string]$session.sessionId
            Use-ItlVerificationRepairAttempt
            { Use-ItlVerificationRepairAttempt } | Should -Throw '*ITL_VERIFICATION_REPAIR_NO_CHANGE*'
            $script:browserPolicy = 'auto'
            Use-ItlVerificationRepairAttempt
            $continued = Get-Content $script:sessionPath -Raw | ConvertFrom-Json
            $continued.sessionId | Should -Be $session.sessionId
            $continued.maximumAttempts | Should -Be 3
            $continued.attempts | Should -Be 2
            $script:browserPolicy = '  AUTO  '
            { Use-ItlVerificationRepairAttempt } | Should -Throw '*ITL_VERIFICATION_REPAIR_NO_CHANGE*'
            (Get-Content $script:sessionPath -Raw | ConvertFrom-Json).attempts | Should -Be 2
        } finally {
            $script:ProjectRoot = $savedRoot
            $VerificationRepairKind = ''
            $VerificationTrigger = ''
            $VanessaFeaturePath = ''
            $RepairSessionId = ''
        }
    }

    It "accepts an ignored transient feature without turning it into a retained suite" {
        $originalProjectRoot = $script:ProjectRoot
        $script:ProjectRoot = $TestDrive
        Mock Get-VerificationFingerprint { 'transient-scenario-source' }
        $transient = Join-Path $TestDrive '.agent-1c/verification/scenario-loop/Новый сценарий.feature'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $transient) | Out-Null
        [IO.File]::WriteAllText($transient, "#language: ru`nФункционал: Однократная проверка`n", [Text.UTF8Encoding]::new($false))
        $VerificationRepairKind = 'scenario-loop'
        $VanessaFeaturePath = $transient
        $VanessaFilterTags = ''
        $VerificationTrigger = 'repair'
        try {
            @(Get-VanessaFeatureFiles -FeaturePath $transient) | Should -Be @($transient)
            Start-ItlVerificationRepairSession
            $record = Get-Content $script:sessionPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $record.scenarioFeature | Should -Be $transient
            $RepairSessionId = [string]$record.sessionId
            Assert-ItlVerificationRepairScope -Trigger repair
            Use-ItlVerificationRepairAttempt
            (Get-Content $script:sessionPath -Raw -Encoding UTF8 | ConvertFrom-Json).attempts | Should -Be 1
        } finally {
            $script:ProjectRoot = $originalProjectRoot
            $VerificationRepairKind = ''
            $VanessaFeaturePath = ''
            $VanessaFilterTags = ''
            $VerificationTrigger = ''
            $RepairSessionId = ''
        }
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



Describe 'repair session explicit extension' {
    BeforeEach {
        $script:ProjectRoot = Join-Path $TestDrive 'продолжение с пробелом'
        New-Item -ItemType Directory -Path $script:ProjectRoot -Force | Out-Null
        $script:extensionPath = Join-Path $script:ProjectRoot 'current.json'
        $RepairSessionId = 'same-session'
        $VerificationRepairMaxAttempts = 10
        $VerificationRepairGrantSource = 'fixture: explicit user numeric grant to 10 for same-session'
        $VerificationRepairKind = ''
        $VanessaFeaturePath = ''
        $VanessaFilterTags = ''
        $VerificationTrigger = 'repair'
        $script:extensionRecord = [pscustomobject]@{
            schemaVersion = 1; sessionId = 'same-session'; projectRoot = $script:ProjectRoot; branch = 'itldev/branch'
            kind = 'canonical-repair'; status = 'active'; attempts = 3; maximumAttempts = 5
            startedAt = '2026-10-01T10:00:00Z'; updatedAt = '2026-10-02T10:00:00Z'
            failures = @(@{ message = 'Исходная ошибка'; run = 'old-run'; hash = 'exact raw' })
            limitExtensions = @(@{ previousMaximum = 3; maximum = 5; source = 'prior grant' })
        }
        Write-Utf8Text -Path $script:extensionPath -Value ($script:extensionRecord | ConvertTo-Json -Depth 10)
        Mock Get-ItlVerificationRepairStatePath { $script:extensionPath }
        Mock Read-DevBranchState { [pscustomobject]@{ devBranch = 'itldev/branch'; worktreePath = $script:ProjectRoot } }
        Mock Get-CurrentBranch { 'itldev/branch' }
        Mock Assert-DevelopmentBranchWorktreeContext {}
        Mock Set-RunUserReport {}
    }

    It 'extends the same <Status> session and retains all existing evidence' -TestCases @(@{Status='active'}, @{Status='exhausted'}) {
        param($Status)
        $script:extensionRecord.status = $Status
        if ($Status -eq 'exhausted') { $script:extensionRecord.attempts = 5 }
        Write-Utf8Text -Path $script:extensionPath -Value ($script:extensionRecord | ConvertTo-Json -Depth 10)
        Extend-ItlVerificationRepairSession
        $actual = Read-Utf8Text -Path $script:extensionPath | ConvertFrom-Json
        $actual.sessionId | Should -Be 'same-session'
        $actual.projectRoot | Should -Be $script:ProjectRoot
        $actual.branch | Should -Be 'itldev/branch'
        $actual.kind | Should -Be 'canonical-repair'
        $actual.startedAt | Should -Be '2026-10-01T10:00:00Z'
        $actual.attempts | Should -Be $script:extensionRecord.attempts
        $actual.maximumAttempts | Should -Be 10
        $actual.status | Should -Be 'active'
        $actual.failures[0].hash | Should -Be 'exact raw'
        $actual.failures[0].message | Should -Be 'Исходная ошибка'
        $actual.limitExtensions.Count | Should -Be 2
        $actual.limitExtensions[0].source | Should -Be 'prior grant'
        $actual.limitExtensions[1].source | Should -Be $VerificationRepairGrantSource
        $actual.limitExtensions[1].previousMaximum | Should -Be 5
        $actual.limitExtensions[1].maximum | Should -Be 10
        Use-ItlVerificationRepairAttempt
        $afterAttempt = Read-Utf8Text -Path $script:extensionPath | ConvertFrom-Json
        $afterAttempt.attempts | Should -Be ($script:extensionRecord.attempts + 1)
        $afterAttempt.failures[0].hash | Should -Be 'exact raw'
    }

    It 'does not create a second audit event or rewrite bytes for the same maximum' {
        Extend-ItlVerificationRepairSession
        $before = [IO.File]::ReadAllBytes($script:extensionPath)
        Extend-ItlVerificationRepairSession
        [IO.File]::ReadAllBytes($script:extensionPath) | Should -Be $before
    }

    It 'rejects <Case> and leaves the previous record byte-exact' -TestCases @(
        @{Case='missing grant'; Code='GRANT_REQUIRED'}, @{Case='lower maximum'; Code='NOT_MONOTONIC'},
        @{Case='invalid maximum'; Code='ARGUMENTS_INVALID'}, @{Case='foreign session'; Code='SCOPE_MISMATCH'},
        @{Case='foreign branch'; Code='SCOPE_MISMATCH'}, @{Case='foreign project'; Code='SCOPE_MISMATCH'},
        @{Case='passed'; Code='TERMINAL'}, @{Case='cancelled'; Code='TERMINAL'}, @{Case='corrupt attempts'; Code='STATE_INVALID'},
        @{Case='contradictory exhausted'; Code='STATE_INVALID'}, @{Case='changed kind'; Code='SCOPE_CHANGED'},
        @{Case='changed tags'; Code='SCOPE_CHANGED'}, @{Case='malformed history'; Code='HISTORY_INVALID'}
    ) {
        param($Case, $Code)
        switch ($Case) {
            'missing grant' { $VerificationRepairGrantSource = '' }
            'lower maximum' { $VerificationRepairMaxAttempts = 4 }
            'invalid maximum' { $VerificationRepairMaxAttempts = 101 }
            'foreign session' { $RepairSessionId = 'another-session' }
            'foreign branch' { $script:extensionRecord.branch = 'itldev/other' }
            'foreign project' { $script:extensionRecord.projectRoot = Join-Path $TestDrive 'other target' }
            'passed' { $script:extensionRecord.status = 'passed' }
            'cancelled' { $script:extensionRecord.status = 'cancelled' }
            'corrupt attempts' { $script:extensionRecord.attempts = 6 }
            'contradictory exhausted' { $script:extensionRecord.status = 'exhausted' }
            'changed kind' { $VerificationRepairKind = 'scenario-loop' }
            'changed tags' { $VanessaFilterTags = '@other-scope' }
            'malformed history' { $script:extensionRecord.limitExtensions = 'retained malformed evidence' }
        }
        Write-Utf8Text -Path $script:extensionPath -Value ($script:extensionRecord | ConvertTo-Json -Depth 10)
        $before = [IO.File]::ReadAllBytes($script:extensionPath)
        { Extend-ItlVerificationRepairSession } | Should -Throw ("*ITL_VERIFICATION_REPAIR_EXTENSION_${Code}*")
        [IO.File]::ReadAllBytes($script:extensionPath) | Should -Be $before
    }

    It 'keeps the prior state if atomic persistence fails' {
        $before = [IO.File]::ReadAllBytes($script:extensionPath)
        Mock Write-Utf8TextAtomic { throw 'Primary write failure' }
        { Extend-ItlVerificationRepairSession } | Should -Throw '*Primary write failure*'
        [IO.File]::ReadAllBytes($script:extensionPath) | Should -Be $before
    }

    It 'uses the existing lifecycle lock for the explicit mutation action' {
        Test-Agent1cActionRequiresLifecycleLock -RequestedAction 'extend-verification-repair' | Should -BeTrue
    }

    It 'preserves the same explicit grant and session in fresh-helper arguments' {
        $Action = 'extend-verification-repair'
        $VerificationRepairGrantSource = 'fixture: разрешено 10 попыток для той же сессии'
        $arguments = @(Get-Agent1cReexecArguments)
        $sourceIndex = [Array]::IndexOf($arguments, '-VerificationRepairGrantSource')
        $sourceIndex | Should -BeGreaterOrEqual 0
        $arguments[$sourceIndex + 1] | Should -BeExactly $VerificationRepairGrantSource
        $arguments[[Array]::IndexOf($arguments, '-RepairSessionId') + 1] | Should -BeExactly 'same-session'
        $arguments[[Array]::IndexOf($arguments, '-VerificationRepairMaxAttempts') + 1] | Should -Be 10
    }

    It 'extends a legacy session without history and keeps the technical maximum at 100' {
        $script:extensionRecord.PSObject.Properties.Remove('limitExtensions')
        $VerificationRepairMaxAttempts = 100
        Write-Utf8Text -Path $script:extensionPath -Value ($script:extensionRecord | ConvertTo-Json -Depth 10)
        Extend-ItlVerificationRepairSession
        $actual = Read-Utf8Text -Path $script:extensionPath | ConvertFrom-Json
        $actual.maximumAttempts | Should -Be 100
        $actual.limitExtensions.Count | Should -Be 1
        $actual.attempts | Should -Be 3
        $actual.failures[0].hash | Should -Be 'exact raw'
    }

    It 'does not reactivate exhausted state for an unchanged maximum' {
        $script:extensionRecord.status = 'exhausted'
        $script:extensionRecord.attempts = 5
        $VerificationRepairMaxAttempts = 5
        Write-Utf8Text -Path $script:extensionPath -Value ($script:extensionRecord | ConvertTo-Json -Depth 10)
        $before = [IO.File]::ReadAllBytes($script:extensionPath)
        Extend-ItlVerificationRepairSession
        [IO.File]::ReadAllBytes($script:extensionPath) | Should -Be $before
        { Get-ItlMatchingVerificationRepairSession } | Should -Throw '*terminal*'
    }
}

Describe 'repair extension normal wrapper integration' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'SourceDelivery.TestSupport.ps1')
        foreach ($definition in Get-DeliveryFunctionDefinitions @('Start-DeliveryProcess','Stop-DeliveryProcessJobAndWait','Close-DeliveryProcessJob','Stop-DeliveryProcessTree','Test-DeliveryProcessCreationIdentity','ConvertTo-DeliveryNativeArgument')) {
            Invoke-Expression $definition.Extent.Text
        }
    }

    It 'serializes two explicit extensions through the actual wrapper and preserves the same session into its next attempt' {
        $root = Join-Path $TestDrive 'native продолжение с пробелом'
        $repairPath = Join-Path $root '.agent-1c/verification-repair/current.json'
        New-Item -ItemType Directory -Path (Split-Path -Parent $repairPath), (Join-Path $root '.agent-1c/dev-branches') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $root '.gitignore'), ".agent-1c/`n", [Text.Encoding]::ASCII)
        & git -C $root init *> $null
        & git -C $root config user.email fixture@example.com
        & git -C $root config user.name Fixture
        & git -C $root add .gitignore
        & git -C $root commit -m fixture *> $null
        & git -C $root branch -M itldev/branch
        [IO.File]::WriteAllText((Join-Path $root '.agent-1c/project.json'), '{"aiRules":{"tools":["codex"]}}', [Text.UTF8Encoding]::new($false))
        $state = @{ devBranchName='branch'; safeDevBranchName='branch'; devBranch='itldev/branch'; worktreePath=$root; stateProjectRoot=$root; createdWithWorktree=$true; status='ready' }
        [IO.File]::WriteAllText((Join-Path $root '.agent-1c/dev-branches/branch.json'), ($state | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        $record = @{ schemaVersion=1; sessionId='native-session'; projectRoot=$root; branch='itldev/branch'; kind='canonical-repair'; status='exhausted'; attempts=5; maximumAttempts=5; startedAt='2026-10-01T10:00:00Z'; updatedAt='2026-10-02T10:00:00Z'; failures=@(@{ message='Исходный отказ'; hash='original raw' }) }
        [IO.File]::WriteAllText($repairPath, ($record | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
        $runner = Join-Path $context.RepoRoot '.agents/skills/1c-workflow/scripts/run-itl-command.ps1'
        $grant = 'fixture: пользователь разрешил 10 попыток для native-session'
        $argv = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$runner,'--','-Action','extend-verification-repair','-RepairSessionId','native-session','-VerificationRepairMaxAttempts','10','-VerificationRepairGrantSource',$grant)
        $arguments = ($argv | ForEach-Object { ConvertTo-DeliveryNativeArgument ([string]$_) }) -join ' '
        $started = @()
        try {
            foreach ($index in 1..2) {
                $out = Join-Path $TestDrive "extension-$index.out"
                $err = Join-Path $TestDrive "extension-$index.err"
                $child = Start-DeliveryProcess -ArgumentList $arguments -WorkingDirectory $root -StandardOutputPath $out -StandardErrorPath $err
                $started += [pscustomobject]@{ child=$child; out=$out; err=$err }
            }
            foreach ($item in $started) {
                $item.child.process.WaitForExit(60000) | Should -BeTrue
                $item.child.process.ExitCode | Should -Be 0 -Because ([IO.File]::ReadAllText($item.err, [Text.Encoding]::UTF8) + [IO.File]::ReadAllText($item.out, [Text.Encoding]::UTF8))
            }
            $actual = [IO.File]::ReadAllText($repairPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
            $actual.sessionId | Should -Be 'native-session'
            $actual.maximumAttempts | Should -Be 10
            $actual.attempts | Should -Be 5
            $actual.limitExtensions.Count | Should -Be 1
            $actual.limitExtensions[0].source | Should -Be $grant
            $actual.failures[0].hash | Should -Be 'original raw'
            & {
                . $context.HelperPath -ProjectRoot $root -Action help *> $null
                $VerificationTrigger = 'repair'; $RepairSessionId = 'native-session'
                Use-ItlVerificationRepairAttempt
            }
            $continued = [IO.File]::ReadAllText($repairPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
            $continued.attempts | Should -Be 6
            $continued.sessionId | Should -Be 'native-session'
            $continued.failures[0].message | Should -Be 'Исходный отказ'
        } finally {
            foreach ($item in $started) {
                try { [void](Stop-DeliveryProcessJobAndWait -JobHandle $item.child.jobHandle -Process $item.child.process -TimeoutMilliseconds 5000) }
                finally { Close-DeliveryProcessJob -JobHandle $item.child.jobHandle -Process $item.child.process; $item.child.process.Dispose() }
            }
        }
    }
}
