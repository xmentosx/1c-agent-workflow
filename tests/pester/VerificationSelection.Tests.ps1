$ErrorActionPreference = "Stop"

Describe "Branch-first verification suite selection" {
    BeforeAll {
        $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $ModulePath = Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.verification-selection.ps1"
        $HelperPath = Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\agent-1c.ps1"
    }

    It "keeps legacy full selection when no catalog exists" {
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
                New-VerificationSelectionPlan -ApplicationFeatureFiles @($first, $second)
            }
            $result.mode | Should -Be "full"
            @($result.selectedFeatureFiles).Count | Should -Be 2
            $result.catalogAvailable | Should -BeFalse
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
                [IO.File]::WriteAllText($newProcessing, "Функционал: new", [Text.UTF8Encoding]::new($false))
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
                $script:CurrentTree = "5555555555555555555555555555555555555555"
                $script:ChangedPaths = @("tests/verification-suites.branch.json", "tests/features/NewProcessing.feature", "src/cf/NewProcessing/Processing.xml")
                $newSuiteFirstFailure = New-VerificationSelectionPlan -ApplicationFeatureFiles @($orders, $reports, $profiling, $newProcessing)
                $newSuiteRetry = New-VerificationSelectionPlan -ApplicationFeatureFiles @($orders, $reports, $profiling, $newProcessing)
                [pscustomobject]@{ initial = $initial; incremental = $incremental; unknown = $unknown; explicitOnly = $explicitOnly; newSuiteFirstFailure = $newSuiteFirstFailure; newSuiteRetry = $newSuiteRetry }
            }

            $result.initial.mode | Should -Be "full"
            @($result.initial.selectedFeatureFiles) | Should -Contain $orders
            @($result.initial.selectedFeatureFiles) | Should -Contain $reports
            @($result.initial.selectedFeatureFiles) | Should -Not -Contain $profiling
            $result.incremental.mode | Should -Be "incremental"
            @($result.incremental.selectedSuiteIds) | Should -Be @("orders")
            @($result.incremental.selectedFeatureFiles) | Should -Be @($orders)
            $result.unknown.mode | Should -Be "full"
            $result.unknown.reason | Should -Match "no suite owner"
            $result.explicitOnly.mode | Should -Be "reuse"
            @($result.explicitOnly.selectedFeatureFiles).Count | Should -Be 0
            $result.newSuiteFirstFailure.mode | Should -Be "incremental"
            @($result.newSuiteFirstFailure.selectedSuiteIds) | Should -Be @("new-processing")
            @($result.newSuiteFirstFailure.selectedFeatureFiles) | Should -Be @($newProcessing)
            $result.newSuiteRetry.mode | Should -Be "incremental"
            @($result.newSuiteRetry.selectedFeatureFiles) | Should -Be @($newProcessing)
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "falls back to all files for an ambiguous catalog" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-selection-invalid-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot "tests\features") | Out-Null
            $feature = Join-Path $tempRoot "tests\features\Shared.feature"
            [IO.File]::WriteAllText($feature, "Функционал: shared", [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $tempRoot "tests\verification-suites.branch.json"), '{"schemaVersion":1,"suites":[{"id":"one","purpose":"acceptance","featurePaths":["tests/features/*.feature"]},{"id":"two","purpose":"acceptance","featurePaths":["tests/features/Shared.feature"]}]}', [Text.UTF8Encoding]::new($false))
            $result = & {
                $script:ProjectRoot = $tempRoot
                function Resolve-Agent1cFullPath { param([string]$Path) [IO.Path]::GetFullPath($Path) }
                function Resolve-ProjectPath { param([string]$Path) if ([IO.Path]::IsPathRooted($Path)) { [IO.Path]::GetFullPath($Path) } else { [IO.Path]::GetFullPath((Join-Path $script:ProjectRoot $Path)) } }
                function Read-Utf8Text { param([string]$Path) [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) }
                . $ModulePath
                function Get-VerificationSelectionEffectiveTree { "1111111111111111111111111111111111111111" }
                New-VerificationSelectionPlan -ApplicationFeatureFiles @($feature)
            }
            $result.mode | Should -Be "full"
            @($result.selectedFeatureFiles) | Should -Be @($feature)
            $result.reason | Should -Match "ambiguous|AMBIGUOUS"
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
            [IO.File]::WriteAllText((Join-Path $tempRoot ".agent-1c\project.json"), '{"schemaVersion":1,"baseConfigurationVersion":"PM5","testsPath":"tests/features"}', [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $tempRoot ".gitignore"), ".agent-1c/verification-selection/`n", [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $tempRoot "tests\features\Orders.feature"), "Функционал: Orders", [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $tempRoot "src\cf\Orders\Order.xml"), "before", [Text.UTF8Encoding]::new($false))
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
                [IO.File]::WriteAllText((Join-Path $tempRoot "src\cf\Orders\Order.xml"), "after", [Text.UTF8Encoding]::new($false))
                $incremental = New-VerificationSelectionPlan -ApplicationFeatureFiles $files
                [pscustomobject]@{ initial = $initial; incremental = $incremental }
            }

            $result.initial.currentTree | Should -Match '^[a-f0-9]{40}$'
            $result.incremental.currentTree | Should -Match '^[a-f0-9]{40}$'
            $result.incremental.currentTree | Should -Not -Be $result.initial.currentTree
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
}
