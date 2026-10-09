Describe "YAxUnit verification" {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        $RepoRoot = $context.RepoRoot
        $modulePath = Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.yaxunit.ps1"
        . (Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.vanessa.ps1")
        . (Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.verification-selection.ps1")
        . $modulePath

        function ConvertTo-IntOrDefault {
            param([object]$Value, [int]$Default = 0)
            $parsed = 0
            if ([int]::TryParse([string]$Value, [ref]$parsed)) { return $parsed }
            return $Default
        }
        function Get-StateValue {
            param([object]$State, [string]$Name, [object]$Default = $null)
            if ($null -eq $State -or $null -eq $State.PSObject.Properties[$Name]) { return $Default }
            return $State.$Name
        }
    }

    It "pins the official YAxUnit release immutably" {
        $lock = Get-Content -LiteralPath (Join-Path $RepoRoot "templates\dependency-lock.json") -Raw -Encoding UTF8 | ConvertFrom-Json
        $entry = $lock.dependencies.yaxunit
        $entry.version | Should -Be "25.12"
        $entry.assetName | Should -Be "YAxUnit-25.12.cfe"
        $entry.url | Should -Be "https://github.com/bia-technologies/yaxunit/releases/download/25.12/YAxUnit-25.12.cfe"
        $entry.sha256 | Should -Be "805a2277c997a3c24be0b0d080696479e91e4a15ed7e27aaf3991a7346522d70"
        $entry.upstreamCommit | Should -Match '^[a-f0-9]{40}$'
    }

    It "installs the pinned CFE during project initialization and workflow update" {
        $core = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.core.ps1") -Raw -Encoding UTF8
        $lifecycle = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.lifecycle.ps1") -Raw -Encoding UTF8
        $init = [regex]::Match($core, '(?s)function Complete-InitProjectSettingsPreparation \{(?<body>.*?)\n\}').Groups['body'].Value
        $update = [regex]::Match($lifecycle, '(?s)function Update-WorkflowPackage \{(?<body>.*?)(?=\nfunction )').Groups['body'].Value

        $init | Should -Match 'Ensure-YAxUnitForInit'
        $postCopy = [regex]::Match($lifecycle, '(?s)function Invoke-WorkflowPackageFilePostCopy \{(?<body>.*?)(?=\nfunction )').Groups['body'].Value
        $postCopy | Should -Match 'Sync-WorkflowManagedDependencyLockEntries \| Out-Null\s+Install-YAxUnit \| Out-Null'
    }

    It "runs YAxUnit before Vanessa and includes unit-test inputs in freshness" {
        $modes = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.verification-modes.ps1") -Raw -Encoding UTF8
        $vanessa = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.vanessa.ps1") -Raw -Encoding UTF8
        $cycle = [regex]::Match($modes, '(?s)function Invoke-ItlVerificationCycle \{(?<body>.*?)\n\}').Groups['body'].Value
        $cycle.IndexOf('Invoke-YAxUnitVerification') | Should -BeLessThan $cycle.IndexOf('Run-DevBranchTests')
        $modes | Should -Match 'ITL_YAXUNIT_TESTING'
        $modes | Should -Match 'Component "yaxunit"'
        $vanessa | Should -Match '\(Get-YAxUnitTestsPath\)'
        $vanessa | Should -Match ([regex]::Escape('".agent-1c/dependency-lock.json"'))
    }

    It "makes boundary-focused unit coverage an installed agent rule" {
        $rules = Get-Content -LiteralPath (Join-Path $RepoRoot "templates\USER-RULES.append.md") -Raw -Encoding UTF8
        $reference = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\references\yaxunit-tests.md") -Raw -Encoding UTF8
        $rules | Should -Match 'For algorithms, recovery, or optimization'
        $rules | Should -Match 'boundary matrix, optimization invariants, test grouping, and benchmark cadence'
        $rules | Should -Match 'complex changes may need both'
        $reference | Should -Match 'immediately below, at, and immediately above every changed boundary'
        $reference | Should -Match 'corrupt data, select the wrong objects, silently lose rows, or report false success'
        $reference | Should -Match 'Parameterized YAxUnit cases are preferred'
    }

    It "requires correctness-first optimization coverage and bounded test groups" {
        $reference = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\references\yaxunit-tests.md") -Raw -Encoding UTF8
        $guide = Get-Content -LiteralPath (Join-Path $RepoRoot "docs\itl-workflow\FEATURE-DEVELOPMENT.ru.md") -Raw -Encoding UTF8
        $decode = { param([string]$Value) [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Value)) }

        $reference | Should -Match 'lock the current functional contract with characterization cases'
        $reference | Should -Match 'cache or intermediate-state invalidation'
        $reference | Should -Match 'isolation between independent plans, objects, tenants, sessions, or calculation contexts'
        $reference | Should -Match 'no partial or stale state after an error or cancellation'
        $reference | Should -Match 'one small representative performance regression that finishes quickly'
        $reference | Should -Match 'Correctness failures cannot be waived by a speed improvement'
        $reference | Should -Match 'Run all .*default-fast.* groups together in one normal YAxUnit session'
        $reference | Should -Match 'Keep .*explicit-benchmark.* modules outside the default .* registration'
        $reference | Should -Match 'owner-aware selective execution only after measurements'
        $guide | Should -Match ([regex]::Escape((& $decode '0YHQvdCw0YfQsNC70LAg0YTQuNC60YHQuNGA0YPQtdGCINC10LPQviDRgtC10LrRg9GJ0LjQuSDRhNGD0L3QutGG0LjQvtC90LDQu9GM0L3Ri9C5INC60L7QvdGC0YDQsNC60YI=')))
        $guide | Should -Match ([regex]::Escape((& $decode '0LPRgNGD0L/Qv9C40YDRg9GO0YLRgdGPINCyINGC0LXRgdGC0L7QstC+0Lwg0YDQsNGB0YjQuNGA0LXQvdC40Lgg0L/QviDQv9GA0LjQutC70LDQtNC90L7QuSDQv9C+0LTRgdC40YHRgtC10LzQtSwg0L7QsdGK0LXQutGC0YMg0Lgg0LDQu9Cz0L7RgNC40YLQvNGD')))
        $guide | Should -Match ([regex]::Escape((& $decode '0L7RgtC00LXQu9GM0L3Ri9C5INC/0YDQvtGG0LXRgdGBIDHQoSDQvdCwINC60LDQttC00YPRjiDQs9GA0YPQv9C/0YMg0L3QtSDQt9Cw0L/Rg9GB0LrQsNC10YLRgdGP')))
    }

    It "loads a separate test extension and requests the official command-line runner" {
        $text = Get-Content -LiteralPath $modulePath -Raw -Encoding UTF8
        $text | Should -Match 'Invoke-GuardedCfeExtensionApply.+-InfoBasePath'
        $text | Should -Match '-CfePath \$cfePath -ExtensionName \$extensionName'
        $text | Should -Match '"/LoadConfigFromFiles".+"-Extension".+\$testsExtensionName.+"-Format".+"Hierarchical"'
        $text | Should -Match 'Set-RunStage -Stage "yaxunit\.run"'
        $text | Should -Match 'Set-RunStage -Stage "yaxunit\.postprocess"'
        $text.IndexOf('Set-RunStage -Stage "yaxunit.run"') | Should -BeLessThan $text.IndexOf('Invoke-Enterprise')
        $text | Should -Match 'RunUnitTests=\$configPath'
        $text | Should -Match 'reportFormat = "jUnit"'
        $text | Should -Match 'ReconcileYAxUnitProtections'
        $text | Should -Match 'ITL_YAXUNIT_ZERO_TESTS'
    }

    It "accepts a clean JUnit report and counts skipped boundary cases" {
        $path = Join-Path $TestDrive "passed.xml"
        Set-Content -LiteralPath $path -Encoding UTF8 -Value '<testsuites><testsuite tests="4" failures="0" errors="0" skipped="1" /></testsuites>'
        $summary = Get-YAxUnitJunitSummary -Path $path
        $summary.tests | Should -Be 4
        $summary.skipped | Should -Be 1
        $summary.passed | Should -BeTrue
    }

    It "rejects zero executed tests and exposes failures" {
        $zeroPath = Join-Path $TestDrive "zero.xml"
        Set-Content -LiteralPath $zeroPath -Encoding UTF8 -Value '<testsuite tests="0" failures="0" errors="0" />'
        { Get-YAxUnitJunitSummary -Path $zeroPath } | Should -Throw '*ITL_YAXUNIT_ZERO_TESTS*'

        $failedPath = Join-Path $TestDrive "failed.xml"
        Set-Content -LiteralPath $failedPath -Encoding UTF8 -Value '<testsuite tests="3" failures="1" errors="0" skipped="0" />'
        $summary = Get-YAxUnitJunitSummary -Path $failedPath
        $summary.passed | Should -BeFalse
        $summary.failures | Should -Be 1
    }

    It "keeps the Designer Agent allowlist exact for YAxUnit protections" {
        $go = Get-Content -LiteralPath (Join-Path $RepoRoot "tools\itl-ondemand-mcp\designer_agent.go") -Raw -Encoding UTF8
        $go | Should -Match ([regex]::Escape('config extensions properties set --extension YAXUNIT --safe-mode no --unsafe-action-protection no'))
        $go | Should -Match 'designerYAxUnitUnsafeModeCommands'
        $lifecycle = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.lifecycle.ps1") -Raw -Encoding UTF8
        $releasePrepare = [regex]::Match($lifecycle, '(?s)function Prepare-ReleaseE2EOnDemandDependencies \{(?<body>.*?)\n\}').Groups['body'].Value
        $releasePrepare | Should -Match 'Install-YAxUnit'
        $releasePrepare | Should -Match 'ReconcileYAxUnitProtections'
        $releasePrepare | Should -Match 'yaxunit-runtime-properties.json'
    }

    It "requires proof that both YAxUnit protections are disabled" {
        $command = "config extensions properties get --extension YAXUNIT"
        $safeOnly = [pscustomobject]@{
            success = $true
            commands = @([pscustomobject]@{ command = $command; messages = @([pscustomobject]@{ body = [pscustomobject]@{ safeMode = $false } }) })
        }
        Test-VanessaDesignerAgentSafeModeResult -Result $safeOnly -ExtensionName YAXUNIT -RequireYAxUnitProtectionsDisabled | Should -BeFalse

        $both = [pscustomobject]@{
            success = $true
            commands = @([pscustomobject]@{ command = $command; messages = @([pscustomobject]@{ body = [pscustomobject]@{ safeMode = $false; unsafeActionProtection = $false } }) })
        }
        Test-VanessaDesignerAgentSafeModeResult -Result $both -ExtensionName YAXUNIT -RequireYAxUnitProtectionsDisabled | Should -BeTrue
    }

    It "rejects a unit-test source outside the project fingerprint" {
        function Get-Setting { return "../foreign-tests" }
        { Get-YAxUnitTestsPath } | Should -Throw '*ITL_YAXUNIT_TEST_SOURCE_OUTSIDE_PROJECT*'
    }

    It "requires every YAxUnit module to have one owner-classified cadence" {
        $tempRoot = Join-Path $TestDrive "classification"
        $moduleRoot = Join-Path $tempRoot "tests\yaxunit\CommonModules\PlanCalculation\Ext"
        New-Item -ItemType Directory -Force -Path $moduleRoot | Out-Null
        $modulePathValue = Join-Path $moduleRoot "Module.bsl"
        [IO.File]::WriteAllText($modulePathValue, "Procedure Test() Export`nEndProcedure", [Text.UTF8Encoding]::new($false))

        $result = & {
            $script:ProjectRoot = $tempRoot
            function Get-Setting { param([string]$Default) return $Default }
            function Resolve-ProjectPath { param([string]$Path) if ([IO.Path]::IsPathRooted($Path)) { [IO.Path]::GetFullPath($Path) } else { [IO.Path]::GetFullPath((Join-Path $script:ProjectRoot $Path)) } }
            function Read-Utf8Text { param([string]$Path) [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) }
            function Get-VerificationRepoRelativePath { param([string]$Path) $root = [IO.Path]::GetFullPath($script:ProjectRoot).TrimEnd('\'); $full = [IO.Path]::GetFullPath($Path); ($full.Substring($root.Length + 1) -replace '\\', '/') }
            function Test-VerificationRepoPathPattern { param([string]$Path, [string]$Pattern) [Management.Automation.WildcardPattern]::new($Pattern, [Management.Automation.WildcardOptions]::IgnoreCase).IsMatch($Path) }

            $missing = Read-YAxUnitSuiteCatalog -ModuleFiles @(Get-YAxUnitModuleFiles)
            [IO.File]::WriteAllText((Join-Path $tempRoot "tests\yaxunit-suites.branch.json"), '{"schemaVersion":1,"groups":[{"id":"plan","purpose":"default-fast","modulePaths":["tests/yaxunit/CommonModules/PlanCalculation/Ext/Module.bsl"],"ownerPaths":["src/cf/CommonModules/PlanCalculation/**"]}]}', [Text.UTF8Encoding]::new($false))
            $classified = Read-YAxUnitSuiteCatalog -ModuleFiles @(Get-YAxUnitModuleFiles)
            [pscustomobject]@{ missing = $missing; classified = $classified }
        }

        $result.missing.classificationComplete | Should -BeFalse
        $result.missing.issues[0] | Should -Match 'catalog|missing'
        @($result.missing.assignments).Count | Should -Be 1
        $result.missing.assignments[0].groupId | Should -Be '__unclassified__'
        $result.classified.classificationComplete | Should -BeTrue
        $result.classified.assignments[0].groupId | Should -Be 'plan'
    }

    It "reads schema-2 YAxUnit obligations while preserving the legacy default-fast selection" {
        $tempRoot = Join-Path $TestDrive 'schema-two-yaxunit'
        $moduleRoot = Join-Path $tempRoot 'tests\yaxunit\CommonModules\PlanCalculation\Ext'
        New-Item -ItemType Directory -Force -Path $moduleRoot | Out-Null
        $modulePathValue = Join-Path $moduleRoot 'Module.bsl'
        [IO.File]::WriteAllText($modulePathValue, 'Procedure Test() Export', [Text.UTF8Encoding]::new($false))
        $catalogPath = Join-Path $tempRoot 'tests\yaxunit-suites.branch.json'
        [IO.File]::WriteAllText($catalogPath, '{"schemaVersion":2,"groups":[{"id":"plan","purpose":"default-fast","modulePaths":["tests/yaxunit/CommonModules/PlanCalculation/Ext/Module.bsl"],"ownerPaths":["src/cf/CommonModules/PlanCalculation/**"]}],"obligations":[{"id":"plan-result","expectedResult":"Plan amount is correct","inputPaths":["src/cf/CommonModules/PlanCalculation/**"],"admissibleProof":["yaxunit-junit"],"retention":"retained","cadence":"affected","groupId":"plan"}]}', [Text.UTF8Encoding]::new($false))
        $result = & {
            $script:ProjectRoot = $tempRoot
            function Get-Setting { param([string]$Default) return $Default }
            function Resolve-ProjectPath { param([string]$Path) if ([IO.Path]::IsPathRooted($Path)) { [IO.Path]::GetFullPath($Path) } else { [IO.Path]::GetFullPath((Join-Path $script:ProjectRoot $Path)) } }
            function Read-Utf8Text { param([string]$Path) [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) }
            function Get-VerificationRepoRelativePath { param([string]$Path) $root = [IO.Path]::GetFullPath($script:ProjectRoot).TrimEnd('\'); $full = [IO.Path]::GetFullPath($Path); ($full.Substring($root.Length + 1) -replace '\\', '/') }
            function Test-VerificationRepoPathPattern { param([string]$Path, [string]$Pattern) [Management.Automation.WildcardPattern]::new($Pattern, [Management.Automation.WildcardOptions]::IgnoreCase).IsMatch($Path) }
            Read-YAxUnitSuiteCatalog -ModuleFiles @(Get-YAxUnitModuleFiles)
        }
        $result.classificationComplete | Should -BeTrue
        $result.obligations[0].id | Should -Be 'plan-result'
        $result.obligations[0].cadence | Should -Be 'affected'
    }

    It "rejects an explicit benchmark referenced by ordinary registration" {
        $tempRoot = Join-Path $TestDrive "benchmark"
        $registrationRoot = Join-Path $tempRoot "tests\yaxunit\CommonModules\ScenarioRegistration\Ext"
        $benchmarkRoot = Join-Path $tempRoot "tests\yaxunit\CommonModules\PlanCalculationBenchmark\Ext"
        New-Item -ItemType Directory -Force -Path $registrationRoot, $benchmarkRoot | Out-Null
        [IO.File]::WriteAllText((Join-Path $registrationRoot "Module.bsl"), "PlanCalculationBenchmark.AddTests();", [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $benchmarkRoot "Module.bsl"), "Procedure AddTests() Export`nEndProcedure", [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $tempRoot "tests\yaxunit-suites.branch.json"), '{"schemaVersion":1,"registrationPaths":["tests/yaxunit/CommonModules/ScenarioRegistration/Ext/Module.bsl"],"groups":[{"id":"benchmark","purpose":"explicit-benchmark","modulePaths":["tests/yaxunit/CommonModules/PlanCalculationBenchmark/Ext/Module.bsl"],"ownerPaths":["src/cf/CommonModules/PlanCalculation/**"]}]}', [Text.UTF8Encoding]::new($false))

        $result = & {
            $script:ProjectRoot = $tempRoot
            function Get-Setting { param([string]$Default) return $Default }
            function Resolve-ProjectPath { param([string]$Path) if ([IO.Path]::IsPathRooted($Path)) { [IO.Path]::GetFullPath($Path) } else { [IO.Path]::GetFullPath((Join-Path $script:ProjectRoot $Path)) } }
            function Read-Utf8Text { param([string]$Path) [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) }
            function Get-VerificationRepoRelativePath { param([string]$Path) $root = [IO.Path]::GetFullPath($script:ProjectRoot).TrimEnd('\'); $full = [IO.Path]::GetFullPath($Path); ($full.Substring($root.Length + 1) -replace '\\', '/') }
            function Test-VerificationRepoPathPattern { param([string]$Path, [string]$Pattern) [Management.Automation.WildcardPattern]::new($Pattern, [Management.Automation.WildcardOptions]::IgnoreCase).IsMatch($Path) }
            Read-YAxUnitSuiteCatalog -ModuleFiles @(Get-YAxUnitModuleFiles)
        }

        $result.classificationComplete | Should -BeFalse
        @($result.assignments | Where-Object groupId -eq '__registration__').Count | Should -Be 1
        @($result.issues) -join "`n" | Should -Match 'referenced by ordinary registration'
    }

    It "accepts an unregistered explicit benchmark and rejects self-registration" {
        $tempRoot = Join-Path $TestDrive "benchmark-self-registration"
        $benchmarkRoot = Join-Path $tempRoot "tests\yaxunit\CommonModules\PlanCalculationBenchmark\Ext"
        New-Item -ItemType Directory -Force -Path $benchmarkRoot | Out-Null
        $benchmarkPath = Join-Path $benchmarkRoot "Module.bsl"
        [IO.File]::WriteAllText($benchmarkPath, "Procedure AddTests() Export`nEndProcedure", [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $tempRoot "tests\yaxunit-suites.branch.json"), '{"schemaVersion":1,"registrationPaths":[],"groups":[{"id":"benchmark","purpose":"explicit-benchmark","modulePaths":["tests/yaxunit/CommonModules/PlanCalculationBenchmark/Ext/Module.bsl"],"ownerPaths":["src/cf/CommonModules/PlanCalculation/**"]}]}', [Text.UTF8Encoding]::new($false))
        $result = & {
            $script:ProjectRoot = $tempRoot
            function Get-Setting { param([string]$Default) return $Default }
            function Resolve-ProjectPath { param([string]$Path) if ([IO.Path]::IsPathRooted($Path)) { [IO.Path]::GetFullPath($Path) } else { [IO.Path]::GetFullPath((Join-Path $script:ProjectRoot $Path)) } }
            function Read-Utf8Text { param([string]$Path) [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) }
            function Get-VerificationRepoRelativePath { param([string]$Path) $root = [IO.Path]::GetFullPath($script:ProjectRoot).TrimEnd('\'); $full = [IO.Path]::GetFullPath($Path); ($full.Substring($root.Length + 1) -replace '\\', '/') }
            function Test-VerificationRepoPathPattern { param([string]$Path, [string]$Pattern) [Management.Automation.WildcardPattern]::new($Pattern, [Management.Automation.WildcardOptions]::IgnoreCase).IsMatch($Path) }
            $unregistered = Read-YAxUnitSuiteCatalog -ModuleFiles @(Get-YAxUnitModuleFiles)
            [IO.File]::WriteAllText($benchmarkPath, "Процедура ИсполняемыеСценарии() Экспорт`nКонецПроцедуры", [Text.UTF8Encoding]::new($false))
            $selfRegistered = Read-YAxUnitSuiteCatalog -ModuleFiles @(Get-YAxUnitModuleFiles)
            [pscustomobject]@{ unregistered = $unregistered; selfRegistered = $selfRegistered }
        }
        $result.unregistered.classificationComplete | Should -BeTrue
        $result.selfRegistered.classificationComplete | Should -BeFalse
        @($result.selfRegistered.issues) -join "`n" | Should -Match 'exports ИсполняемыеСценарии'
    }
}

Describe "Pinned YAxUnit vendor diagnostic assessment" {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        . (Join-Path $context.RepoRoot '.agents\skills\1c-workflow\scripts\lib\agent-1c.runtime-values.ps1')
        . (Join-Path $context.RepoRoot '.agents\skills\1c-workflow\scripts\lib\agent-1c.yaxunit.ps1')
        $tokens = $null; $parseErrors = $null
        $coreAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $context.RepoRoot '.agents\skills\1c-workflow\scripts\lib\agent-1c.core.ps1'), [ref]$tokens, [ref]$parseErrors)
        foreach ($name in @('Read-DesignerBatchStrictUtf8Text', 'Get-DesignerBatchCheckVerdict')) {
            $function = $coreAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $false)
            . ([scriptblock]::Create($function.Extent.Text))
        }
        $pin = (Get-Content -LiteralPath (Join-Path $context.RepoRoot 'templates\dependency-lock.json') -Raw -Encoding UTF8 | ConvertFrom-Json).dependencies.yaxunit
        $applicabilityLines = @(
            'YAXUNIT: Не найден метод "ОбработкаОтображенияОшибки", указанный в аннотации метода "ЮТОбработкаОтображенияОшибки".'
            'YAXUNIT: Не найден метод "ErrorDisplayProcessing", указанный в аннотации метода "ЮТErrorDisplayProcessing".'
            'YAXUNIT: Не найден метод "ОбработкаОтображенияОшибки", указанный в аннотации метода "ЮТОбработкаОтображенияОшибки".'
            'YAXUNIT: Не найден метод "ErrorDisplayProcessing", указанный в аннотации метода "ЮТErrorDisplayProcessing".'
        )
        $configurationLines = @(
            'YAXUNIT Обработка.ЮТПомощникДляСозданияТестовыхДанных.Форма.Форма.Форма Отсутствует обработчик:  СнятьВсеФлажки "СнятьВсеФлажки"'
            'YAXUNIT Обработка.ЮТПомощникДляСозданияТестовыхДанных.Форма.Форма.Форма Отсутствует обработчик:  УстановитьВсеФлажки "УстановитьВсеФлажки"'
        )
        function New-YAxUnitDiagnosticFixture {
            param([string]$Step = 'applicability', [bool]$Bom = $true, [string]$Newline = "`r`n")
            $root = Join-Path $TestDrive ('Сырые диагностики ' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $root | Out-Null
            $lines = $(if ($Step -eq 'configuration') { $configurationLines } else { $applicabilityLines })
            $code = $(if ($Step -eq 'configuration') { 101 } else { 0 })
            $logPath = Join-Path $root 'native Out.log'; $resultPath = Join-Path $root 'native DumpResult.result'
            [IO.File]::WriteAllText($logPath, ($lines -join $Newline) + $Newline, [Text.UTF8Encoding]::new($Bom))
            [IO.File]::WriteAllText($resultPath, [string]$code, [Text.UTF8Encoding]::new($Bom))
            [pscustomobject]@{
                baseline = (Get-YAxUnitArtifactDiagnosticBaseline -PinnedEntry $pin -ExtensionName 'YAXUNIT')
                step = $Step; sourceFingerprint = ('sha256:' + $pin.sha256); extensionName = 'YAXUNIT'
                verdict = (Get-DesignerBatchCheckVerdict -ExitCode $code -LogPath $logPath -ResultPath $resultPath)
            }
        }
        function Invoke-YAxUnitDiagnosticFixtureAssessment {
            param([object]$Fixture)
            Get-YAxUnitArtifactDiagnosticAssessment -Baseline $Fixture.baseline -Step $Fixture.step -Verdict $Fixture.verdict -SourceFingerprint $Fixture.sourceFingerprint -ExtensionName $Fixture.extensionName
        }
    }

    It "binds all seven canonical pin fields while preserving unrelated owner metadata" {
        $entry = $pin | ConvertTo-Json -Depth 5 | ConvertFrom-Json
        $entry | Add-Member -NotePropertyName updatedAt -NotePropertyValue 'owner metadata'
        $baseline = Get-YAxUnitArtifactDiagnosticBaseline -PinnedEntry $entry -ExtensionName 'YAXUNIT'
        $baseline.id | Should -BeExactly 'yaxunit-25.12-vendor-diagnostics'
        $baseline.version | Should -Be 1
        @($baseline.pin.PSObject.Properties).Count | Should -Be 7
        foreach ($field in $baseline.pin.PSObject.Properties.Name) { $baseline.pin.$field | Should -BeExactly $pin.$field }
        Get-YAxUnitArtifactDiagnosticBaseline -PinnedEntry $entry -ExtensionName 'tests' | Should -BeNullOrEmpty
    }

    It "rejects changed or missing pin field <Field>" -TestCases @(
        @{ Field = 'version' }, @{ Field = 'releaseTag' }, @{ Field = 'assetName' }, @{ Field = 'url' }
        @{ Field = 'sha256' }, @{ Field = 'upstreamCommit' }, @{ Field = 'source' }
    ) {
        param($Field)
        $entry = $pin | ConvertTo-Json -Depth 5 | ConvertFrom-Json
        $entry.$Field = 'changed'
        Get-YAxUnitArtifactDiagnosticBaseline -PinnedEntry $entry -ExtensionName 'YAXUNIT' | Should -BeNullOrEmpty
        $entry.PSObject.Properties.Remove($Field)
        Get-YAxUnitArtifactDiagnosticBaseline -PinnedEntry $entry -ExtensionName 'YAXUNIT' | Should -BeNullOrEmpty
    }

    It "admits only the complete official <Step> raw multiset without claiming clean native checks" -TestCases @(
        @{ Step = 'applicability'; Hash = '3e0d9bff581de21dbb6cbb14112c037dcffbab9e5ef5f2493185e35ad0b5b6a0'; Count = 4; Code = 0 }
        @{ Step = 'configuration'; Hash = '8d4cf5ed0431de8fa6637e44a2409936d888ee993e81a3af6b18543fc1cc3b87'; Count = 2; Code = 101 }
    ) {
        param($Step, $Hash, $Count, $Code)
        $fixture = New-YAxUnitDiagnosticFixture -Step $Step
        $fixture.verdict.passed | Should -BeFalse
        $assessment = Invoke-YAxUnitDiagnosticFixtureAssessment $fixture
        $assessment.status | Should -BeExactly 'vendor-warn'
        $assessment.applyAllowed | Should -BeTrue
        $assessment.cleanPassed | Should -BeFalse
        $assessment.nativePassed | Should -BeFalse
        $assessment.exitCode | Should -Be $Code
        $assessment.resultCode | Should -Be $Code
        $assessment.raw.logSha256 | Should -BeExactly $Hash
        $assessment.raw.resultSha256 | Should -BeExactly (Get-FileHash -LiteralPath $fixture.verdict.resultPath -Algorithm SHA256).Hash.ToLowerInvariant()
        @($assessment.raw.lines).Count | Should -Be $Count
        $assessment.rejectionReason | Should -BeNullOrEmpty
    }

    It "admits the exact version-labelled applicability output captured from the official CFE" {
        $fixture = New-YAxUnitDiagnosticFixture
        $lines = @(
            'YAXUNIT (25.12): Не найден метод "ОбработкаОтображенияОшибки", указанный в аннотации метода "ЮТОбработкаОтображенияОшибки".'
            'YAXUNIT (25.12): Не найден метод "ErrorDisplayProcessing", указанный в аннотации метода "ЮТErrorDisplayProcessing".'
            'YAXUNIT (25.12): Не найден метод "ОбработкаОтображенияОшибки", указанный в аннотации метода "ЮТОбработкаОтображенияОшибки".'
            'YAXUNIT (25.12): Не найден метод "ErrorDisplayProcessing", указанный в аннотации метода "ЮТErrorDisplayProcessing".'
        )
        [IO.File]::WriteAllText($fixture.verdict.logPath, ($lines -join "`r`n") + "`r`n", [Text.UTF8Encoding]::new($true))
        (Get-FileHash -LiteralPath $fixture.verdict.logPath -Algorithm SHA256).Hash.ToLowerInvariant() | Should -BeExactly '17f1a74bd5c1e62691e2194e9e65b44f28e7525196c81949fd7dceba7eb847ef'
        $assessment = Invoke-YAxUnitDiagnosticFixtureAssessment $fixture
        $assessment.status | Should -BeExactly 'vendor-warn'
        $assessment.applyAllowed | Should -BeTrue
        $assessment.nativePassed | Should -BeFalse
        $assessment.cleanPassed | Should -BeFalse
        @($assessment.raw.lines).Count | Should -Be 4
        $assessment.raw.lines[0] | Should -BeExactly $lines[0]
        $assessment.expected.multiset[0].text | Should -BeExactly $lines[0]
    }

    It "rejects a version-labelled applicability profile with <Mutation>" -TestCases @(
        @{ Mutation = 'different version' }, @{ Mutation = 'mixed labels' }, @{ Mutation = 'changed annotation' }
        @{ Mutation = 'missing repetition' }, @{ Mutation = 'extra diagnostic' }
    ) {
        param($Mutation)
        $fixture = New-YAxUnitDiagnosticFixture
        $lines = @($applicabilityLines | ForEach-Object { $_.Replace('YAXUNIT:', 'YAXUNIT (25.12):') })
        switch ($Mutation) {
            'different version' { $lines = @($lines | ForEach-Object { $_.Replace('(25.12)', '(25.11)') }) }
            'mixed labels' { $lines[2] = $applicabilityLines[2] }
            'changed annotation' { $lines[1] = $lines[1].Replace('ЮТErrorDisplayProcessing', 'ЮТДругойМетод') }
            'missing repetition' { $lines = @($lines[0..2]) }
            'extra diagnostic' { $lines += 'YAXUNIT (25.12): Не найден метод ДругойМетод' }
        }
        [IO.File]::WriteAllText($fixture.verdict.logPath, ($lines -join "`r`n") + "`r`n", [Text.UTF8Encoding]::new($true))
        $assessment = Invoke-YAxUnitDiagnosticFixtureAssessment $fixture
        $assessment.status | Should -BeExactly 'rejected'
        $assessment.applyAllowed | Should -BeFalse
    }

    It "normalizes only one optional BOM and line separators, retaining ordinal text and counts" {
        $fixture = New-YAxUnitDiagnosticFixture -Bom $false -Newline "`n"
        $text = $applicabilityLines[3], $applicabilityLines[1], $applicabilityLines[2], $applicabilityLines[0] -join "`n"
        [IO.File]::WriteAllText($fixture.verdict.logPath, $text, [Text.UTF8Encoding]::new($false))
        (Invoke-YAxUnitDiagnosticFixtureAssessment $fixture).applyAllowed | Should -BeTrue
    }

    It "preserves canonical numeric baseline identity across a JSON broker roundtrip" {
        $fixture = New-YAxUnitDiagnosticFixture
        $fixture.baseline.version = [long]1
        (Invoke-YAxUnitDiagnosticFixtureAssessment $fixture).applyAllowed | Should -BeTrue
        $fixture.baseline = $fixture.baseline | ConvertTo-Json -Depth 6 | ConvertFrom-Json
        $assessment = Invoke-YAxUnitDiagnosticFixtureAssessment $fixture
        $assessment.status | Should -BeExactly 'vendor-warn'
        $assessment.applyAllowed | Should -BeTrue
        $assessment.cleanPassed | Should -BeFalse
    }

    It "refuses <Mutation> rather than trusting filtered diagnostics or caller allowances" -TestCases @(
        @{ Mutation = 'neutral extra' }, @{ Mutation = 'unknown diagnostic' }, @{ Mutation = 'changed annotation' }
        @{ Mutation = 'case changed' }, @{ Mutation = 'missing repetition' }, @{ Mutation = 'extra repetition' }
        @{ Mutation = 'interior blank' }, @{ Mutation = 'extra terminal newline' }, @{ Mutation = 'second BOM' }
        @{ Mutation = 'invalid UTF8' }, @{ Mutation = 'invalid result' }, @{ Mutation = 'result whitespace' }
        @{ Mutation = 'result code drift' }, @{ Mutation = 'exit code drift' }, @{ Mutation = 'false clean verdict' }
        @{ Mutation = 'source drift' }, @{ Mutation = 'pin drift' }, @{ Mutation = 'id drift' }
        @{ Mutation = 'version drift' }, @{ Mutation = 'string version' }, @{ Mutation = 'boolean version' }
        @{ Mutation = 'extension drift' }, @{ Mutation = 'other extension' }
        @{ Mutation = 'modules step' }, @{ Mutation = 'cross-step raw' }, @{ Mutation = 'single handler space' }
    ) {
        param($Mutation)
        $fixture = New-YAxUnitDiagnosticFixture
        $raw = [IO.File]::ReadAllText($fixture.verdict.logPath, [Text.Encoding]::UTF8)
        switch ($Mutation) {
            'neutral extra' { $raw += "Everything completed`r`n" }
            'unknown diagnostic' { $raw += "YAXUNIT: Не найден метод ДругойМетод`r`n" }
            'changed annotation' { $raw = $raw.Replace('ЮТErrorDisplayProcessing', 'ЮТДругойМетод') }
            'case changed' { $raw = $raw.Replace('YAXUNIT:', 'yaxunit:') }
            'missing repetition' { $raw = ($applicabilityLines[0..2] -join "`r`n") + "`r`n" }
            'extra repetition' { $raw += $applicabilityLines[0] + "`r`n" }
            'interior blank' { $raw = $raw.Replace(".`r`n", ".`r`n`r`n") }
            'extra terminal newline' { $raw += "`r`n" }
            'second BOM' { $raw = [string][char]0xFEFF + $raw }
            'invalid UTF8' { [IO.File]::WriteAllBytes($fixture.verdict.logPath, [byte[]]@(0xC3, 0x28)) }
            'invalid result' { [IO.File]::WriteAllText($fixture.verdict.resultPath, 'not a code', [Text.UTF8Encoding]::new($true)) }
            'result whitespace' { [IO.File]::WriteAllText($fixture.verdict.resultPath, ' 0', [Text.UTF8Encoding]::new($true)) }
            'result code drift' { $fixture.verdict.resultCode = 101 }
            'exit code drift' { $fixture.verdict.exitCode = 1 }
            'false clean verdict' { $fixture.verdict.passed = $true }
            'source drift' { $fixture.sourceFingerprint = 'sha256:changed' }
            'pin drift' { $fixture.baseline.pin.sha256 = 'changed' }
            'id drift' { $fixture.baseline.id = 'changed' }
            'version drift' { $fixture.baseline.version = 2 }
            'string version' { $fixture.baseline.version = '1' }
            'boolean version' { $fixture.baseline.version = $true }
            'extension drift' { $fixture.baseline.extensionName = 'tests' }
            'other extension' { $fixture.extensionName = 'tests' }
            'modules step' { $fixture.step = 'modules' }
            'cross-step raw' { $fixture.step = 'configuration'; $fixture.verdict.exitCode = 101; $fixture.verdict.resultCode = 101; [IO.File]::WriteAllText($fixture.verdict.resultPath, '101') }
            'single handler space' { $fixture = New-YAxUnitDiagnosticFixture -Step configuration; $raw = ([IO.File]::ReadAllText($fixture.verdict.logPath, [Text.Encoding]::UTF8)).Replace('обработчик:  ', 'обработчик: ') }
        }
        if ($Mutation -ne 'invalid UTF8') { [IO.File]::WriteAllText($fixture.verdict.logPath, $raw, [Text.UTF8Encoding]::new($true)) }
        $fixture.baseline | Add-Member -NotePropertyName allowedLines -NotePropertyValue @($raw)
        $assessment = Invoke-YAxUnitDiagnosticFixtureAssessment $fixture
        $assessment.status | Should -BeExactly 'rejected'
        $assessment.applyAllowed | Should -BeFalse
        $assessment.cleanPassed | Should -BeFalse
        $assessment.rejectionReason | Should -Not -BeNullOrEmpty
        if ($Mutation -eq 'invalid UTF8') {
            $assessment.raw.logSha256 | Should -BeExactly (Get-FileHash -LiteralPath $fixture.verdict.logPath -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        if ($Mutation -eq 'invalid result') {
            $assessment.raw.resultSha256 | Should -BeExactly (Get-FileHash -LiteralPath $fixture.verdict.resultPath -Algorithm SHA256).Hash.ToLowerInvariant()
            @($assessment.raw.lines).Count | Should -Be 4
        }
    }

    It "leaves genuinely clean native results on their existing strict route" {
        $fixture = New-YAxUnitDiagnosticFixture
        [IO.File]::WriteAllText($fixture.verdict.logPath, '', [Text.UTF8Encoding]::new($false))
        $fixture.verdict = Get-DesignerBatchCheckVerdict -ExitCode 0 -LogPath $fixture.verdict.logPath -ResultPath $fixture.verdict.resultPath
        $fixture.verdict.passed | Should -BeTrue
        $assessment = Invoke-YAxUnitDiagnosticFixtureAssessment $fixture
        $assessment.applyAllowed | Should -BeFalse
        $assessment.cleanPassed | Should -BeFalse
        $assessment.nativePassed | Should -BeTrue
    }
}

Describe "Pinned YAxUnit diagnostic caller binding" {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $callerContext = Initialize-WorkflowPesterContext
        . $callerContext.HelperPath -ProjectRoot $callerContext.RepoRoot -Action help *> $null
    }
    BeforeEach {
        $savedProjectRoot = $script:ProjectRoot
        $savedModeVariable = Get-Variable -Name DependencyMode -Scope Script -ErrorAction SilentlyContinue
        $savedModeExists = $null -ne $savedModeVariable
        $savedDependencyMode = $(if ($savedModeExists) { $savedModeVariable.Value } else { $null })
        $savedLockVariable = Get-Variable -Name DependencyLockPath -Scope Script -ErrorAction SilentlyContinue
        $savedLockExists = $null -ne $savedLockVariable
        $savedDependencyLockPath = $(if ($savedLockExists) { $savedLockVariable.Value } else { $null })
        $callerRoot = Join-Path $TestDrive ('Проект YAxUnit ' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $callerRoot '.agent-1c'), (Join-Path $callerRoot 'tests\yaxunit') -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $callerContext.RepoRoot 'templates\dependency-lock.json') -Destination (Join-Path $callerRoot '.agent-1c\dependency-lock.json')
        [IO.File]::WriteAllText((Join-Path $callerRoot 'tests\yaxunit\Configuration.xml'), '<MetaDataObject><Configuration><Properties><Name>ПМ5Тесты</Name></Properties></Configuration></MetaDataObject>', [Text.UTF8Encoding]::new($false))
        & git -C $callerRoot init --quiet
        & git -C $callerRoot symbolic-ref HEAD refs/heads/itldev/yaxunit-diagnostic
        if ($LASTEXITCODE -ne 0) { throw 'Could not create the owned development branch fixture.' }
        $script:ProjectRoot = $callerRoot
        $script:DependencyMode = 'fresh'
        $script:DependencyLockPath = Join-Path $callerRoot '.agent-1c\dependency-lock.json'
        Get-DependencyLockPath | Should -BeExactly (Join-Path $callerRoot '.agent-1c\dependency-lock.json')
        $script:callerPin = Get-YAxUnitPinnedEntry
        $script:callerState = [pscustomobject]@{
            devBranchName = 'yaxunit-diagnostic'; devBranch = 'itldev/yaxunit-diagnostic'; devBranchKind = 'configuration'
            worktreePath = $callerRoot; infoBaseKind = 'file'; devBranchInfoBasePath = (Join-Path $callerRoot 'База 1С')
            toolingInfoBaseGeneration = 'generation'
            yaxunitInstallationProof = [pscustomobject]@{
                schemaVersion = 1; generation = 'generation'; infoBaseKey = 'base-key'
                engineName = 'YAXUNIT'; testsName = 'ПМ5Тесты'; engineSha256 = $script:callerPin.sha256
                engineRuntimeHash = 'engine-hash'; testsRuntimeHash = 'tests-hash'; testsFingerprint = 'tests-source'
            }
        }
        $script:callerRuntime = @(
            [pscustomobject]@{ name = 'YAXUNIT'; present = $true; active = $true; safeMode = $false; unsafeActionProtection = $false; contentHash = 'engine-hash' }
            [pscustomobject]@{ name = 'ПМ5Тесты'; present = $true; active = $true; safeMode = $false; unsafeActionProtection = $false; contentHash = 'tests-hash' }
        )
        $script:engineCalls = [Collections.Generic.List[object]]::new()
        $script:testCalls = [Collections.Generic.List[object]]::new()
        $script:failEngineApply = $false
        $script:callerGate6Evidence = $null
        Mock Set-RunStage {}
        Mock Read-DevBranchState { $script:callerState }
        Mock Ensure-DevBranchToolingGeneration { param($State) $State }
        Mock Get-YAxUnitTestsPath { 'tests/yaxunit' }
        Mock Get-YAxUnitTestsExtensionName { 'ПМ5Тесты' }
        Mock Get-ConfigSourceFingerprint { [pscustomobject]@{ fingerprint = 'tests-source' } }
        Mock Get-OneCInfoBaseIdentity { [pscustomobject]@{ key = 'base-key' } }
        Mock Get-ToolingRuntimeExtensions { $script:callerRuntime }
        Mock Install-VanessaAutomation {}
        Mock Install-ItlOnDemandMcp {}
        Mock Install-YAxUnit { Join-Path $script:ProjectRoot 'tools\YAxUnit-25.12.cfe' }
        Mock Stop-DevBranchRuntimeBeforeInfobaseMutation {}
        Mock Invoke-GuardedCfeExtensionApply {
            param($InfoBasePath, $InfoBaseKind, $CfePath, $ExtensionName, $ArtifactDiagnosticBaseline)
            $script:engineCalls.Add([pscustomobject]@{ infoBasePath = $InfoBasePath; infoBaseKind = $InfoBaseKind; cfePath = $CfePath; extensionName = $ExtensionName; baseline = $ArtifactDiagnosticBaseline })
            if ($script:failEngineApply) { throw 'native engine apply failed' }
            $script:callerGate6Evidence = [pscustomobject]@{
                schemaVersion = 2; artifactDiagnosticBaseline = $ArtifactDiagnosticBaseline
                steps = @([pscustomobject]@{ name = 'configuration'; nativePassed = $false; assessment = [pscustomobject]@{ status = 'vendor-warn'; applyAllowed = $true; cleanPassed = $false; evidencePath = 'unit-boundary-assessment.json'; evidenceSha256 = 'unit-boundary-sha' } })
            }
            [pscustomobject]@{ gate6Evidence = $script:callerGate6Evidence }
        }
        Mock Invoke-ConfigLoadDesignerAttempt {
            param($DesignerArgs, $ExtensionName, $ArtifactDiagnosticBaseline)
            $script:testCalls.Add([pscustomobject]@{ args = $DesignerArgs; extensionName = $ExtensionName; baseline = $ArtifactDiagnosticBaseline })
        }
        Mock Set-VanessaMcpExtensionUnsafeMode { [pscustomobject]@{ safeMode = $false; unsafeActionProtection = $false; artifactSha256 = $script:callerPin.sha256 } }
        Mock Get-EnvValue { param($Default) $Default }
        Mock Update-DevBranchState {
            param($State, $Updates)
            foreach ($key in $Updates.Keys) { $State | Add-Member -NotePropertyName $key -NotePropertyValue $Updates[$key] -Force }
        }
    }
    AfterEach {
        $script:ProjectRoot = $savedProjectRoot
        if ($savedModeExists) { $script:DependencyMode = $savedDependencyMode }
        else { Remove-Variable -Name DependencyMode -Scope Script -ErrorAction SilentlyContinue }
        if ($savedLockExists) { $script:DependencyLockPath = $savedDependencyLockPath }
        else { Remove-Variable -Name DependencyLockPath -Scope Script -ErrorAction SilentlyContinue }
    }

    It "uses a canonical baseline only for the engine and preserves legacy reuse for <Scenario>" -TestCases @(
        @{ Scenario = 'engine reload'; EngineCalls = 1; TestCalls = 0; Stops = 1 }
        @{ Scenario = 'tests reload'; EngineCalls = 0; TestCalls = 1; Stops = 1 }
        @{ Scenario = 'schema1 reuse'; EngineCalls = 0; TestCalls = 0; Stops = 0 }
    ) {
        param($Scenario, $EngineCalls, $TestCalls, $Stops)
        if ($Scenario -eq 'engine reload') { $script:callerState.yaxunitInstallationProof.engineSha256 = 'prior-engine' }
        if ($Scenario -eq 'tests reload') { $script:callerState.yaxunitInstallationProof.testsFingerprint = 'prior-tests' }
        Ensure-YAxUnitExtensions -State $script:callerState | Out-Null
        $script:engineCalls.Count | Should -Be $EngineCalls
        $script:testCalls.Count | Should -Be $TestCalls
        Should -Invoke Stop-DevBranchRuntimeBeforeInfobaseMutation -Times $Stops -Exactly
        if ($EngineCalls -gt 0) {
            $call = $script:engineCalls[0]
            $canonical = Get-YAxUnitArtifactDiagnosticBaseline -PinnedEntry $script:callerPin -ExtensionName 'YAXUNIT'
            $call.baseline.id | Should -BeExactly $canonical.id
            $call.baseline.version | Should -Be $canonical.version
            foreach ($field in $canonical.pin.PSObject.Properties.Name) { $call.baseline.pin.$field | Should -BeExactly $canonical.pin.$field }
            $call.infoBasePath | Should -BeExactly $script:callerState.devBranchInfoBasePath
            $call.infoBaseKind | Should -BeExactly 'file'
            $call.extensionName | Should -BeExactly 'YAXUNIT'
            $call.cfePath | Should -BeExactly (Join-Path $callerRoot 'tools\YAxUnit-25.12.cfe')
        }
        if ($TestCalls -gt 0) {
            $script:testCalls[0].baseline | Should -BeNullOrEmpty
            $script:testCalls[0].args[0] | Should -BeExactly '/LoadConfigFromFiles'
            $script:testCalls[0].extensionName | Should -BeExactly 'ПМ5Тесты'
        }
        $script:callerState.yaxunitInstallationProof.schemaVersion | Should -Be 1
        $script:callerState.yaxunitInstallationProof.PSObject.Properties.Name | Should -Not -Contain 'artifactDiagnosticBaseline'
    }

    It "binds actual Release preparation to the engine pin and retains failure before protection proof when apply fails=<Fails>" -TestCases @(
        @{ Fails = $false }, @{ Fails = $true }
    ) {
        param($Fails)
        $script:failEngineApply = $Fails
        $proofPath = Join-Path $callerRoot 'build\test-results\release-e2e\yaxunit-runtime-properties.json'
        if ($Fails) { { Prepare-ReleaseE2EOnDemandDependencies } | Should -Throw '*native engine apply failed*' }
        else { Prepare-ReleaseE2EOnDemandDependencies }
        $script:engineCalls.Count | Should -Be 1
        $call = $script:engineCalls[0]
        $canonical = Get-YAxUnitArtifactDiagnosticBaseline -PinnedEntry (Get-YAxUnitPinnedEntry) -ExtensionName 'YAXUNIT'
        $call.baseline.id | Should -BeExactly $canonical.id
        $call.baseline.version | Should -Be $canonical.version
        foreach ($field in $canonical.pin.PSObject.Properties.Name) { $call.baseline.pin.$field | Should -BeExactly $canonical.pin.$field }
        $call.infoBasePath | Should -BeExactly $script:callerState.devBranchInfoBasePath
        $call.infoBaseKind | Should -BeExactly 'file'
        $call.cfePath | Should -BeExactly (Join-Path $callerRoot 'tools\YAxUnit-25.12.cfe')
        $call.extensionName | Should -BeExactly 'YAXUNIT'
        Should -Invoke Set-VanessaMcpExtensionUnsafeMode -Times ([int](-not $Fails)) -Exactly -ParameterFilter { $ReconcileYAxUnitProtections }
        if ($Fails) { Test-Path -LiteralPath $proofPath | Should -BeFalse }
        else {
            $proof = Get-Content -LiteralPath $proofPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $proof.status | Should -BeExactly 'passed'
            $proof.safeMode | Should -BeFalse
            $proof.unsafeActionProtection | Should -BeFalse
            $proof.artifactSha256 | Should -BeExactly $canonical.pin.sha256
            $proof.PSObject.Properties.Name | Should -Not -Contain 'cleanPassed'
            $proof.PSObject.Properties.Name | Should -Not -Contain 'nativePassed'
            $script:callerGate6Evidence.schemaVersion | Should -Be 2
            $script:callerGate6Evidence.steps[0].nativePassed | Should -BeFalse
            $script:callerGate6Evidence.steps[0].assessment.status | Should -BeExactly 'vendor-warn'
            $script:callerGate6Evidence.steps[0].assessment.cleanPassed | Should -BeFalse
        }
    }
}
