$ErrorActionPreference = "Stop"

Describe "Branch-first verification suite selection" {
    BeforeAll {
        $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $ModulePath = Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.verification-selection.ps1"
        $HelperPath = Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\agent-1c.ps1"
    }

    It "requires classification instead of running every feature when no catalog exists" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-selection-legacy-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot "tests\features") | Out-Null
            $first = Join-Path $tempRoot "tests\features\First.feature"
            $second = Join-Path $tempRoot "tests\features\Second.feature"
            [IO.File]::WriteAllText($first, "Функционал: First", [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText($second, "Функционал: Second", [Text.UTF8Encoding]::new($false))
            $result = & {
                $script:ProjectRoot = $tempRoot
                function Resolve-Agent1cFullPath { param([string]$Path) [IO.Path]::GetFullPath($Path) }
                function Resolve-ProjectPath { param([string]$Path) if ([IO.Path]::IsPathRooted($Path)) { [IO.Path]::GetFullPath($Path) } else { [IO.Path]::GetFullPath((Join-Path $script:ProjectRoot $Path)) } }
                function Read-Utf8Text { param([string]$Path) [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) }
                . $ModulePath
                function Get-VerificationSelectionEffectiveTree { "1111111111111111111111111111111111111111" }
                [pscustomobject]@{
                    catalog = Read-VerificationSuiteCatalog -ApplicationFeatureFiles @($first, $second)
                    plan = New-VerificationSelectionPlan -ApplicationFeatureFiles @($first, $second)
                }
            }
            $result.plan.mode | Should -Be "classification-required"
            @($result.plan.selectedFeatureFiles).Count | Should -Be 0
            $result.plan.catalogAvailable | Should -BeFalse
            @($result.catalog.assignments).Count | Should -Be 2
            @($result.catalog.assignments | Where-Object suiteId -eq '__unclassified__').Count | Should -Be 2
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "excludes explicit suites and reuses unchanged acceptance proof by owner" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-selection-owner-" + [guid]::NewGuid().ToString("N"))
        try {
            $features = Join-Path $tempRoot "tests\features"
            New-Item -ItemType Directory -Force -Path $features | Out-Null
            $orders = Join-Path $features "Orders.feature"
            $reports = Join-Path $features "Reports.feature"
            $profiling = Join-Path $features "Profiling.feature"
            $newProcessing = Join-Path $features "NewProcessing.feature"
            foreach ($path in @($orders, $reports, $profiling)) { [IO.File]::WriteAllText($path, "Функционал: test", [Text.UTF8Encoding]::new($false)) }
            $catalogPath = Join-Path $tempRoot "tests\verification-suites.branch.json"
            [IO.File]::WriteAllText($catalogPath, @'
{
  "schemaVersion": 1,
  "suites": [
    { "id": "orders", "purpose": "acceptance", "featurePaths": ["tests/features/Orders.feature"], "ownerPaths": ["src/cf/Orders/**"] },
    { "id": "reports", "purpose": "acceptance", "featurePaths": ["tests/features/Reports.feature"], "ownerPaths": ["src/cf/Reports/**"] },
    { "id": "profiling", "purpose": "explicit", "featurePaths": ["tests/features/Profiling.feature"], "ownerPaths": ["tools/profiling/**"] }
  ]
}
'@, [Text.UTF8Encoding]::new($false))

            $result = & {
                $script:ProjectRoot = $tempRoot
                $script:CurrentTree = "1111111111111111111111111111111111111111"
                $script:ChangedPaths = @()
                function Resolve-Agent1cFullPath { param([string]$Path) [IO.Path]::GetFullPath($Path) }
                function Resolve-ProjectPath { param([string]$Path) if ([IO.Path]::IsPathRooted($Path)) { [IO.Path]::GetFullPath($Path) } else { [IO.Path]::GetFullPath((Join-Path $script:ProjectRoot $Path)) } }
                function Read-Utf8Text { param([string]$Path) [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) }
                function Write-Utf8TextAtomic { param([string]$Path, [string]$Value) New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null; [IO.File]::WriteAllText($Path, $Value, [Text.UTF8Encoding]::new($false)) }
                . $ModulePath
                function Get-VerificationSelectionEffectiveTree { $script:CurrentTree }
                function Get-VerificationSelectionChangedPaths { param([string]$BaseTree, [string]$CurrentTree) @($script:ChangedPaths) }
                function Get-YAxUnitTestsPath { "tests/yaxunit" }
                function Get-YAxUnitSuiteCatalogPaths { @((Resolve-ProjectPath "tests/yaxunit-suites.shared.json"), (Resolve-ProjectPath "tests/yaxunit-suites.branch.json")) }
                function Get-YAxUnitModuleFiles { @("tests/yaxunit/CommonModules/CalculationTests/Ext/Module.bsl") }
                function Read-YAxUnitSuiteCatalog {
                    [pscustomobject]@{
                        classificationComplete = $true
                        issues = @()
                        groups = @([pscustomobject]@{ id = "calculation"; purpose = "default-fast"; ownerPaths = @("src/cf/Calculations/**") })
                    }
                }
                function Get-VanessaFeaturesPath { "tests/features" }

                $initial = New-VerificationSelectionPlan -ApplicationFeatureFiles @($orders, $reports, $profiling)
                Complete-VerificationSelectionProof -Plan $initial
                $script:CurrentTree = "2222222222222222222222222222222222222222"
                $script:ChangedPaths = @("src/cf/Orders/Documents/Order.xml")
                $incremental = New-VerificationSelectionPlan -ApplicationFeatureFiles @($orders, $reports, $profiling)
                $script:CurrentTree = "3333333333333333333333333333333333333333"
                $script:ChangedPaths = @("src/cf/Unknown/Object.xml")
                $unknown = New-VerificationSelectionPlan -ApplicationFeatureFiles @($orders, $reports, $profiling)
                $script:CurrentTree = "4444444444444444444444444444444444444444"
                $script:ChangedPaths = @("tools/profiling/measure.ps1")
                $explicitOnly = New-VerificationSelectionPlan -ApplicationFeatureFiles @($orders, $reports, $profiling)
                $script:CurrentTree = "4444444444444444444444444444444444444445"
                $script:ChangedPaths = @("src/cf/Calculations/CommonModules/Calculation/Ext/Module.bsl")
                $yaxUnitOnly = New-VerificationSelectionPlan -ApplicationFeatureFiles @($orders, $reports, $profiling) -YAxUnitVerificationPlanned
                $yaxUnitSkipped = New-VerificationSelectionPlan -ApplicationFeatureFiles @($orders, $reports, $profiling)
                [IO.File]::WriteAllText($newProcessing, "Функционал: new", [Text.UTF8Encoding]::new($false))
                $script:CurrentTree = "5555555555555555555555555555555555555555"
                $script:ChangedPaths = @("tests/features/NewProcessing.feature")
                $unclassifiedNewTest = New-VerificationSelectionPlan -ApplicationFeatureFiles @($orders, $reports, $profiling, $newProcessing)
                [IO.File]::WriteAllText($catalogPath, @'
{
  "schemaVersion": 1,
  "suites": [
    { "id": "orders", "purpose": "acceptance", "featurePaths": ["tests/features/Orders.feature"], "ownerPaths": ["src/cf/Orders/**"] },
    { "id": "reports", "purpose": "acceptance", "featurePaths": ["tests/features/Reports.feature"], "ownerPaths": ["src/cf/Reports/**"] },
    { "id": "new-processing", "purpose": "acceptance", "featurePaths": ["tests/features/NewProcessing.feature"], "ownerPaths": ["src/cf/NewProcessing/**"] },
    { "id": "profiling", "purpose": "explicit", "featurePaths": ["tests/features/Profiling.feature"], "ownerPaths": ["tools/profiling/**"] }
  ]
}
'@, [Text.UTF8Encoding]::new($false))
                $script:CurrentTree = "6666666666666666666666666666666666666666"
                $script:ChangedPaths = @("tests/verification-suites.branch.json", "tests/features/NewProcessing.feature", "src/cf/NewProcessing/Processing.xml")
                $newSuiteFirstFailure = New-VerificationSelectionPlan -ApplicationFeatureFiles @($orders, $reports, $profiling, $newProcessing)
                $newSuiteRetry = New-VerificationSelectionPlan -ApplicationFeatureFiles @($orders, $reports, $profiling, $newProcessing)
                [pscustomobject]@{ initial = $initial; incremental = $incremental; unknown = $unknown; explicitOnly = $explicitOnly; yaxUnitOnly = $yaxUnitOnly; yaxUnitSkipped = $yaxUnitSkipped; unclassifiedNewTest = $unclassifiedNewTest; newSuiteFirstFailure = $newSuiteFirstFailure; newSuiteRetry = $newSuiteRetry }
            }

            $result.initial.mode | Should -Be "full"
            @($result.initial.selectedFeatureFiles) | Should -Contain $orders
            @($result.initial.selectedFeatureFiles) | Should -Contain $reports
            @($result.initial.selectedFeatureFiles) | Should -Not -Contain $profiling
            $result.incremental.mode | Should -Be "incremental"
            @($result.incremental.selectedSuiteIds) | Should -Be @("orders")
            @($result.incremental.selectedFeatureFiles) | Should -Be @($orders)
            $result.unknown.mode | Should -Be "classification-required"
            $result.unknown.reason | Should -Match "no suite owner"
            $result.explicitOnly.mode | Should -Be "reuse"
            @($result.explicitOnly.selectedFeatureFiles).Count | Should -Be 0
            $result.yaxUnitOnly.mode | Should -Be "reuse"
            $result.yaxUnitOnly.reason | Should -Match "YAxUnit"
            $result.yaxUnitSkipped.mode | Should -Be "classification-required"
            $result.unclassifiedNewTest.mode | Should -Be "classification-required"
            @($result.unclassifiedNewTest.selectedFeatureFiles).Count | Should -Be 0
            $result.newSuiteFirstFailure.mode | Should -Be "incremental"
            @($result.newSuiteFirstFailure.selectedSuiteIds) | Should -Be @("new-processing")
            @($result.newSuiteFirstFailure.selectedFeatureFiles) | Should -Be @($newProcessing)
            $result.newSuiteRetry.mode | Should -Be "incremental"
            @($result.newSuiteRetry.selectedFeatureFiles) | Should -Be @($newProcessing)
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "requires classification without selecting files for an ambiguous catalog" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-selection-invalid-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot "tests\features") | Out-Null
            $feature = Join-Path $tempRoot "tests\features\Shared.feature"
            [IO.File]::WriteAllText($feature, "Функционал: shared", [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $tempRoot "tests\verification-suites.branch.json"), '{"schemaVersion":1,"suites":[{"id":"one","purpose":"acceptance","featurePaths":["tests/features/*.feature"],"ownerPaths":["src/cf/One/**"]},{"id":"two","purpose":"acceptance","featurePaths":["tests/features/Shared.feature"],"ownerPaths":["src/cf/Two/**"]}]}', [Text.UTF8Encoding]::new($false))
            $result = & {
                $script:ProjectRoot = $tempRoot
                function Resolve-Agent1cFullPath { param([string]$Path) [IO.Path]::GetFullPath($Path) }
                function Resolve-ProjectPath { param([string]$Path) if ([IO.Path]::IsPathRooted($Path)) { [IO.Path]::GetFullPath($Path) } else { [IO.Path]::GetFullPath((Join-Path $script:ProjectRoot $Path)) } }
                function Read-Utf8Text { param([string]$Path) [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) }
                . $ModulePath
                function Get-VerificationSelectionEffectiveTree { "1111111111111111111111111111111111111111" }
                New-VerificationSelectionPlan -ApplicationFeatureFiles @($feature)
            }
            $result.mode | Should -Be "classification-required"
            @($result.selectedFeatureFiles).Count | Should -Be 0
            $result.reason | Should -Match "ambiguous|AMBIGUOUS"
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "requires the agent to split an oversized mixed-cadence acceptance suite" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-selection-scenario-scope-" + [guid]::NewGuid().ToString("N"))
        try {
            $features = Join-Path $tempRoot "tests\features"
            New-Item -ItemType Directory -Force -Path $features | Out-Null
            $feature = Join-Path $features "Monolith.feature"
            $featureLines = @("# language: ru", "Функционал: Монолит")
            foreach ($number in 1..10) {
                if ($number -eq 10) { $featureLines += "@diag_slow_probe" }
                $featureLines += "Сценарий: Проверка $number"
                $featureLines += "    Дано выполнено действие $number"
            }
            [IO.File]::WriteAllText($feature, ($featureLines -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $tempRoot "tests\verification-suites.branch.json"), '{"schemaVersion":1,"suites":[{"id":"monolith","purpose":"acceptance","featurePaths":["tests/features/Monolith.feature"],"ownerPaths":["src/cf/**"]}]}', [Text.UTF8Encoding]::new($false))

            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                Read-VerificationSuiteCatalog -ApplicationFeatureFiles @($feature)
            }

            $result.classificationComplete | Should -BeFalse
            $result.migrationRequired | Should -BeTrue
            @($result.scenarios).Count | Should -Be 10
            $result.scenarios[0].line | Should -Be 3
            $result.scenarios[9].cadenceHint | Should -Be "explicit"
            ($result.issues -join "`n") | Should -Match "VERIFICATION_SUITE_ACCEPTANCE_SCOPE_TOO_BROAD"
            ($result.issues -join "`n") | Should -Match "VERIFICATION_SUITE_MIXED_CADENCE"
            ($result.issues -join "`n") | Should -Match "The agent must"
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "accepts bounded acceptance suites and a separate explicit diagnostic suite" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-selection-scenario-split-" + [guid]::NewGuid().ToString("N"))
        try {
            $features = Join-Path $tempRoot "tests\features"
            New-Item -ItemType Directory -Force -Path $features | Out-Null
            $files = @()
            foreach ($definition in @(
                [pscustomobject]@{ Name = "Orders"; Count = 4; Tag = "" },
                [pscustomobject]@{ Name = "Reports"; Count = 4; Tag = "" },
                [pscustomobject]@{ Name = "Diagnostics"; Count = 10; Tag = "@diag_probe" }
            )) {
                $path = Join-Path $features ($definition.Name + ".feature")
                $lines = @("# language: ru", "Функционал: $($definition.Name)")
                foreach ($number in 1..$definition.Count) {
                    if ($definition.Tag) { $lines += $definition.Tag }
                    $lines += "Сценарий: $($definition.Name) $number"
                    $lines += "    Дано выполнено действие $number"
                }
                [IO.File]::WriteAllText($path, ($lines -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
                $files += $path
            }
            [IO.File]::WriteAllText((Join-Path $tempRoot "tests\verification-suites.branch.json"), @'
{"schemaVersion":1,"suites":[
  {"id":"orders","purpose":"acceptance","featurePaths":["tests/features/Orders.feature"],"ownerPaths":["src/cf/Orders/**"]},
  {"id":"reports","purpose":"acceptance","featurePaths":["tests/features/Reports.feature"],"ownerPaths":["src/cf/Reports/**"]},
  {"id":"diagnostics","purpose":"explicit","featurePaths":["tests/features/Diagnostics.feature"],"ownerPaths":["tools/diagnostics/**"]}
]}
'@, [Text.UTF8Encoding]::new($false))

            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                Read-VerificationSuiteCatalog -ApplicationFeatureFiles $files
            }

            $result.classificationComplete | Should -BeTrue
            $result.migrationRequired | Should -BeFalse
            @($result.scenarios).Count | Should -Be 18
            @($result.scenarios | Where-Object purpose -eq "acceptance").Count | Should -Be 8
            @($result.scenarios | Where-Object purpose -eq "explicit").Count | Should -Be 10
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "allows refresh migration to move intact scenarios but not rewrite them" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-selection-scenario-preserve-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c"), (Join-Path $tempRoot "tests\features") | Out-Null
            [IO.File]::WriteAllText((Join-Path $tempRoot ".agent-1c\project.json"), '{"schemaVersion":1,"baseConfigurationVersion":"PM5","testsPath":"tests/features"}', [Text.UTF8Encoding]::new($false))
            $monolith = Join-Path $tempRoot "tests\features\Monolith.feature"
            $scenarioBlocks = @(1..9 | ForEach-Object { "Сценарий: Проверка $_`n    Дано выполнено действие $_" })
            [IO.File]::WriteAllText($monolith, "# language: ru`nФункционал: Монолит`n" + ($scenarioBlocks -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
            $catalogPath = Join-Path $tempRoot "tests\verification-suites.branch.json"
            [IO.File]::WriteAllText($catalogPath, '{"schemaVersion":1,"suites":[{"id":"monolith","purpose":"acceptance","featurePaths":["tests/features/Monolith.feature"],"ownerPaths":["src/cf/**"]}]}', [Text.UTF8Encoding]::new($false))

            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $before = Update-VerificationSuiteInventory -Reason "refresh-dev-branch-lite post-merge"
                $baselinePath = Get-VerificationScenarioMigrationBaselinePath
                $baselineCreated = Test-Path -LiteralPath $baselinePath -PathType Leaf

                Remove-Item -LiteralPath $monolith -Force
                $first = Join-Path $tempRoot "tests\features\First.feature"
                $second = Join-Path $tempRoot "tests\features\Second.feature"
                [IO.File]::WriteAllText($first, "# language: ru`nФункционал: First`n" + ($scenarioBlocks[0..4] -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
                [IO.File]::WriteAllText($second, "# language: ru`nФункционал: Second`n" + ($scenarioBlocks[5..8] -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
                [IO.File]::WriteAllText($catalogPath, '{"schemaVersion":1,"suites":[{"id":"first","purpose":"acceptance","featurePaths":["tests/features/First.feature"],"ownerPaths":["src/cf/First/**"]},{"id":"second","purpose":"acceptance","featurePaths":["tests/features/Second.feature"],"ownerPaths":["src/cf/Second/**"]}]}', [Text.UTF8Encoding]::new($false))
                $after = Update-VerificationSuiteInventory -Reason "explicit classification validation"
                Assert-VerificationScenarioMigrationPreserved -Inventory $after
                [pscustomobject]@{
                    before = $before
                    after = $after
                    baselineCreated = $baselineCreated
                    baselineRemoved = -not (Test-Path -LiteralPath $baselinePath -PathType Leaf)
                }
            }

            $result.before.scenarioMigrationRequired | Should -BeTrue
            $result.baselineCreated | Should -BeTrue
            $result.after.classificationComplete | Should -BeTrue
            $result.baselineRemoved | Should -BeTrue
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "rejects scenario behavior changes during refresh classification migration" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-selection-scenario-rewrite-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c"), (Join-Path $tempRoot "tests\features") | Out-Null
            [IO.File]::WriteAllText((Join-Path $tempRoot ".agent-1c\project.json"), '{"schemaVersion":1,"baseConfigurationVersion":"PM5","testsPath":"tests/features"}', [Text.UTF8Encoding]::new($false))
            $monolith = Join-Path $tempRoot "tests\features\Monolith.feature"
            $scenarioBlocks = @(1..9 | ForEach-Object { "Сценарий: Проверка $_`n    Дано выполнено действие $_" })
            [IO.File]::WriteAllText($monolith, "# language: ru`nФункционал: Монолит`n" + ($scenarioBlocks -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
            $catalogPath = Join-Path $tempRoot "tests\verification-suites.branch.json"
            [IO.File]::WriteAllText($catalogPath, '{"schemaVersion":1,"suites":[{"id":"monolith","purpose":"acceptance","featurePaths":["tests/features/Monolith.feature"],"ownerPaths":["src/cf/**"]}]}', [Text.UTF8Encoding]::new($false))

            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                [void](Update-VerificationSuiteInventory -Reason "refresh-dev-branch post-merge")
                $baselinePath = Get-VerificationScenarioMigrationBaselinePath
                Remove-Item -LiteralPath $monolith -Force
                $first = Join-Path $tempRoot "tests\features\First.feature"
                $second = Join-Path $tempRoot "tests\features\Second.feature"
                $rewritten = @($scenarioBlocks)
                $rewritten[0] = "Сценарий: Проверка 1`n    Дано незаметно изменено действие 1"
                [IO.File]::WriteAllText($first, "# language: ru`nФункционал: First`n" + ($rewritten[0..4] -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
                [IO.File]::WriteAllText($second, "# language: ru`nФункционал: Second`n" + ($rewritten[5..8] -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
                [IO.File]::WriteAllText($catalogPath, '{"schemaVersion":1,"suites":[{"id":"first","purpose":"acceptance","featurePaths":["tests/features/First.feature"],"ownerPaths":["src/cf/First/**"]},{"id":"second","purpose":"acceptance","featurePaths":["tests/features/Second.feature"],"ownerPaths":["src/cf/Second/**"]}]}', [Text.UTF8Encoding]::new($false))
                $after = Update-VerificationSuiteInventory -Reason "explicit classification validation"
                $message = try { Assert-VerificationScenarioMigrationPreserved -Inventory $after; "not-rejected" } catch { $_.Exception.Message }
                [pscustomobject]@{ message = $message; baselineRetained = Test-Path -LiteralPath $baselinePath -PathType Leaf }
            }

            $result.message | Should -Match "VERIFICATION_SUITE_MIGRATION_CHANGED_SCENARIOS"
            $result.baselineRetained | Should -BeTrue
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "classifies the configured Vanessa inventory when a single feature is selected" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-selection-single-feature-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot "tests\features") | Out-Null
            $feature = Join-Path $tempRoot "tests\features\Selected.feature"
            $otherFeature = Join-Path $tempRoot "tests\features\Other.feature"
            [IO.File]::WriteAllText($feature, "Функционал: selected", [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText($otherFeature, "Функционал: other", [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $tempRoot "tests\verification-suites.branch.json"), '{"schemaVersion":1,"suites":[{"id":"selected","purpose":"acceptance","featurePaths":["tests/features/Selected.feature"],"ownerPaths":["src/cf/Configuration.xml"]},{"id":"other","purpose":"acceptance","featurePaths":["tests/features/Other.feature"],"ownerPaths":["src/cf/Other/**"]}]}', [Text.UTF8Encoding]::new($false))

            $result = & {
                $script:ProjectRoot = $tempRoot
                function Resolve-Agent1cFullPath { param([string]$Path) [IO.Path]::GetFullPath($Path) }
                function Resolve-ProjectPath { param([string]$Path) if ([IO.Path]::IsPathRooted($Path)) { [IO.Path]::GetFullPath($Path) } else { [IO.Path]::GetFullPath((Join-Path $script:ProjectRoot $Path)) } }
                function Read-Utf8Text { param([string]$Path) [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) }
                function Write-Utf8TextAtomic { param([string]$Path, [string]$Value) New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null; [IO.File]::WriteAllText($Path, $Value, [Text.UTF8Encoding]::new($false)) }
                . $ModulePath
                function Get-VerificationSelectionStateRoot { Join-Path $script:ProjectRoot ".agent-1c\verification-selection" }
                $script:ActiveAuxiliaryVanessaContext = $null
                function Get-VanessaFeaturesPath { $feature }
                function Get-VanessaConfiguredFeaturesPath { "tests/features" }
                function Get-VanessaApplicationFeatureFiles { param([string]$FeaturePath) @(Get-ChildItem -LiteralPath (Resolve-ProjectPath $FeaturePath) -File -Filter "*.feature" | ForEach-Object FullName) }
                function Get-YAxUnitModuleFiles { @() }
                function Read-YAxUnitSuiteCatalog { [pscustomobject]@{ classificationComplete = $true; issues = @(); available = $false; valid = $true; groups = @(); assignments = @(); registrationPaths = @() } }
                function Test-YAxUnitSuitePresent { $false }
                Update-VerificationSuiteInventory -Reason "single feature regression"
            }

            $result.classificationComplete | Should -BeTrue
            $result.featureCount | Should -Be 2
            @($result.assignments).Count | Should -Be 2
            @($result.assignments.path) | Should -Contain "tests/features/Selected.feature"
            @($result.assignments.path) | Should -Contain "tests/features/Other.feature"
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "advances from an exact clean Git tree to an owner-selected dirty tree" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-selection-git-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot "tests\features") | Out-Null
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot "src\cf\Orders") | Out-Null
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot "docs") | Out-Null
            [IO.File]::WriteAllText((Join-Path $tempRoot ".agent-1c\project.json"), '{"schemaVersion":1,"baseConfigurationVersion":"PM5","testsPath":"tests/features"}', [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $tempRoot ".gitignore"), ".agent-1c/verification-selection/`n", [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $tempRoot "tests\features\Orders.feature"), "Функционал: Orders", [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $tempRoot "src\cf\Orders\Order.xml"), "before", [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $tempRoot "docs\guide.md"), "before", [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $tempRoot "tests\verification-suites.branch.json"), '{"schemaVersion":1,"suites":[{"id":"orders","purpose":"acceptance","featurePaths":["tests/features/Orders.feature"],"ownerPaths":["src/cf/Orders/**"]}]}', [Text.UTF8Encoding]::new($false))
            & git -C $tempRoot init *> $null
            & git -C $tempRoot config user.email "tests@example.invalid"
            & git -C $tempRoot config user.name "ITL Tests"
            & git -C $tempRoot add -- .
            & git -C $tempRoot commit -m baseline *> $null

            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $files = @(Get-VanessaApplicationFeatureFiles -FeaturePath "tests/features")
                $initial = New-VerificationSelectionPlan -ApplicationFeatureFiles $files
                Complete-VerificationSelectionProof -Plan $initial
                [IO.File]::WriteAllText((Join-Path $tempRoot "docs\guide.md"), "after", [Text.UTF8Encoding]::new($false))
                $unrelated = New-VerificationSelectionPlan -ApplicationFeatureFiles $files
                [IO.File]::WriteAllText((Join-Path $tempRoot "src\cf\Orders\Order.xml"), "after", [Text.UTF8Encoding]::new($false))
                $incremental = New-VerificationSelectionPlan -ApplicationFeatureFiles $files
                [pscustomobject]@{ initial = $initial; unrelated = $unrelated; incremental = $incremental }
            }

            $result.initial.currentTree | Should -Match '^[a-f0-9]{40}$'
            $result.incremental.currentTree | Should -Match '^[a-f0-9]{40}$'
            $result.incremental.currentTree | Should -Not -Be $result.initial.currentTree
            $result.unrelated.mode | Should -Be "reuse"
            $result.incremental.mode | Should -Be "incremental"
            @($result.incremental.selectedSuiteIds) | Should -Be @("orders")
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "does not start Vanessa when only explicit suites changed" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $script:EventLogCalls = 0
            $script:ProofCalls = 0
            $script:Updates = @()
            $script:ActiveAuxiliaryVanessaContext = $null
            $VanessaFeaturePath = ""
            $VanessaFilterTags = ""
            $DevBranchName = "branch"
            function Read-DevBranchState { [pscustomobject]@{ devBranchName = "branch" } }
            function Get-ItlVerificationExecutionDecision { param([string]$Component) [pscustomobject]@{ component = $Component; run = $true; reason = "test" } }
            function Test-ItlFullVerificationProofEligible { $true }
            function Get-VanessaFeaturesPath { "tests/features" }
            function Get-VanessaApplicationFeatureFiles { @("tests/features/Explicit.feature") }
            function New-VerificationSelectionPlan { [pscustomobject]@{ mode = "reuse"; reason = "explicit only"; selectedFeatureFiles = @(); selectedSuiteIds = @(); acceptanceSuiteIds = @("acceptance"); catalogFingerprint = "catalog"; currentTree = "1111111111111111111111111111111111111111"; catalogAvailable = $true } }
            function Assert-VerificationClassificationReady {}
            function Assert-DevelopmentBranchWorktreeContext {}
            function Assert-DevBranchExtensionInitialized {}
            function Assert-DevBranchApplicationReady { param([object]$State) $State }
            function Test-ItlEventLogCurrent { $script:EventLogCalls++ }
            function Get-CurrentCommit { "2222222222222222222222222222222222222222" }
            function Get-VerificationFingerprint { "fingerprint" }
            function Complete-VerificationSelectionProof { $script:ProofCalls++ }
            function Update-DevBranchState { param([hashtable]$Updates) $script:Updates += ,$Updates }
            function Get-VerificationState { [pscustomobject]@{ status = "passed" } }
            function Run-DevBranchTests { throw "Vanessa must not run" }
            Invoke-ItlVerificationCycle -Trigger command
            $reuseUpdateCount = @($script:Updates | Where-Object { $_.ContainsKey("lastVerificationSelectionMode") -and $_["lastVerificationSelectionMode"] -eq "reuse" }).Count
            [pscustomobject]@{ eventLogCalls = $script:EventLogCalls; proofCalls = $script:ProofCalls; reuseUpdateCount = $reuseUpdateCount }
        }

        $result.eventLogCalls | Should -Be 1
        $result.proofCalls | Should -Be 1
        $result.reuseUpdateCount | Should -Be 1
    }

    It "runs classification preflight before either executable test contour" {
        $modes = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.verification-modes.ps1") -Raw -Encoding UTF8
        $cycle = [regex]::Match($modes, '(?s)function Invoke-ItlVerificationCycle \{(?<body>.*?)\n\}').Groups['body'].Value
        $cycle.IndexOf('Assert-VerificationClassificationReady') | Should -BeGreaterThan -1
        $cycle.IndexOf('Assert-VerificationClassificationReady') | Should -BeLessThan $cycle.IndexOf('Invoke-YAxUnitVerification')
        $cycle.IndexOf('Assert-VerificationClassificationReady') | Should -BeLessThan $cycle.IndexOf('Run-DevBranchTests')
        $cycle | Should -Match 'classification-required'
    }

    It "exposes a static classification validator that never starts 1C" {
        $helper = Get-Content -LiteralPath $HelperPath -Raw -Encoding UTF8
        $selection = Get-Content -LiteralPath $ModulePath -Raw -Encoding UTF8
        $validator = [regex]::Match($selection, '(?s)function Test-VerificationClassification \{(?<body>.*?)\n\}').Groups['body'].Value

        $helper | Should -Match '"validate-test-classification" \{ Test-VerificationClassification \}'
        $validator | Should -Match 'Assert-VerificationClassificationReady'
        $validator | Should -Not -Match 'Invoke-(Designer|Enterprise)|Run-DevBranchTests|Invoke-YAxUnitVerification'
    }

    It "makes refresh return agent-owned classification continuation instead of silent full fallback" {
        $lifecycle = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.lifecycle.ps1") -Raw -Encoding UTF8
        $fastSkill = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow-fast\SKILL.md") -Raw -Encoding UTF8
        $refreshTemplate = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\kilo-command-templates\dev\itl-refresh.md.template") -Raw -Encoding UTF8
        $advanced = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\references\advanced-actions.md") -Raw -Encoding UTF8
        $selectionReference = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\references\verification-suite-selection.md") -Raw -Encoding UTF8

        $refresh = [regex]::Match($lifecycle, '(?s)function Invoke-RefreshDevBranchCore \{(?<body>.*?)(?=\nfunction Refresh-DevBranch)').Groups['body'].Value
        $refresh | Should -Match 'Update-VerificationSuiteInventory'
        $refresh | Should -Match 'Set-VerificationClassificationRequiredAction'
        $refresh.IndexOf('Set-VerificationClassificationRequiredAction') | Should -BeLessThan $refresh.IndexOf('Write-DevBranchRunUserReport')
        foreach ($contract in @($fastSkill, $refreshTemplate)) {
            $contract | Should -Match 'classify-tests-after-refresh:'
            $contract | Should -Match 'same task|same agent task|same task'
            $contract | Should -Match '(?is)do not ask the developer to\s+classify'
        }
        $fastSkill | Should -Match 'split oversized/mixed feature files yourself'
        $refreshTemplate | Should -Match 'split oversized or mixed feature files yourself'
        $advanced | Should -Match 'VERIFICATION_SUITE_ACCEPTANCE_SCOPE_TOO_BROAD'
        $advanced | Should -Match 'Do not merely rename the original file'
        $selectionReference | Should -Match '(?s)at most eight flat\s+scenarios'
        $selectionReference | Should -Match 'post-merge scenario baseline'
    }
}
