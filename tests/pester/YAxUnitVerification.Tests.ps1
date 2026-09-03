Describe "YAxUnit verification" {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        $RepoRoot = $context.RepoRoot
        $modulePath = Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.yaxunit.ps1"
        . (Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.vanessa.ps1")
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
        $update | Should -Match 'Sync-WorkflowManagedDependencyLockEntries \| Out-Null\s+Install-YAxUnit \| Out-Null'
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
        $reference | Should -Match 'Run all default fast groups together in one normal YAxUnit session'
        $reference | Should -Match 'Keep heavy benchmarks outside the default .* registration'
        $reference | Should -Match 'owner-aware selective execution only after measurements'
        $guide | Should -Match ([regex]::Escape((& $decode '0YHQvdCw0YfQsNC70LAg0YTQuNC60YHQuNGA0YPQtdGCINC10LPQviDRgtC10LrRg9GJ0LjQuSDRhNGD0L3QutGG0LjQvtC90LDQu9GM0L3Ri9C5INC60L7QvdGC0YDQsNC60YI=')))
        $guide | Should -Match ([regex]::Escape((& $decode '0LPRgNGD0L/Qv9C40YDRg9GO0YLRgdGPINCyINGC0LXRgdGC0L7QstC+0Lwg0YDQsNGB0YjQuNGA0LXQvdC40Lgg0L/QviDQv9GA0LjQutC70LDQtNC90L7QuSDQv9C+0LTRgdC40YHRgtC10LzQtSwg0L7QsdGK0LXQutGC0YMg0Lgg0LDQu9Cz0L7RgNC40YLQvNGD')))
        $guide | Should -Match ([regex]::Escape((& $decode '0L7RgtC00LXQu9GM0L3Ri9C5INC/0YDQvtGG0LXRgdGBIDHQoSDQvdCwINC60LDQttC00YPRjiDQs9GA0YPQv9C/0YMg0L3QtSDQt9Cw0L/Rg9GB0LrQsNC10YLRgdGP')))
    }

    It "loads a separate test extension and requests the official command-line runner" {
        $text = Get-Content -LiteralPath $modulePath -Raw -Encoding UTF8
        $text | Should -Match '"/LoadCfg".+"-Extension".+\$extensionName.+"/UpdateDBCfg"'
        $text | Should -Match '"/LoadConfigFromFiles".+"-Extension".+\$testsExtensionName.+"-Format".+"Hierarchical"'
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
}
