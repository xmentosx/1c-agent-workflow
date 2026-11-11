BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSupport.ps1')
    $context = Initialize-WorkflowPesterContext
    $RepoRoot = $context.RepoRoot
    . (Join-Path $PSScriptRoot 'SourceDeliveryPlan.TestSupport.ps1')
    . (Join-Path $RepoRoot 'scripts/source-delivery-process.ps1')
    $tokens = $null; $errors = $null
    $script:CheckAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'scripts/check.ps1'), [ref]$tokens, [ref]$errors)
    @($errors).Count | Should -Be 0
    $script:RerunDefinition = $script:CheckAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Invoke-PesterIsolatedRerun' }, $true)
    function New-RerunFixture([string[]]$FailedFiles) {
        $root = Join-Path $TestDrive ('Кандидат с пробелом ' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        foreach ($relative in @('scripts', 'tests/pester', 'build/test-results/local')) { [void][IO.Directory]::CreateDirectory((Join-Path $root $relative)) }
        Copy-Item -LiteralPath (Join-Path $RepoRoot 'scripts/pester-timings.json') -Destination (Join-Path $root 'scripts/pester-timings.json')
        $cases = @($FailedFiles | ForEach-Object { '<testcase name="fails" classname="' + [Security.SecurityElement]::Escape((Join-Path $root $_)) + '"><failure message="boom"/></testcase>' }) -join ''
        [IO.File]::WriteAllText((Join-Path $root 'build/test-results/local/pester.xml'), ('<?xml version="1.0" encoding="utf-8"?><testsuites><testsuite name="x">' + $cases + '</testsuite></testsuites>'), [Text.UTF8Encoding]::new($false))
        return $root
    }
    function Invoke-RerunFixture([string]$Root, [string[]]$PassingAlone, [int]$BudgetSeconds = 3600) {
        $repoRoot = $Root
        $outputRoot = Join-Path $Root 'build/test-results/local'
        $junitPath = Join-Path $outputRoot 'pester.xml'
        $modeHardBudgetSeconds = $BudgetSeconds
        $overallStopwatch = [Diagnostics.Stopwatch]::StartNew()
        $script:rerunCalls = @()
        # The real child runs scripts/run-pester-shard.ps1; this one reports the scripted outcome.
        function Invoke-PowerShellChild {
            param([string]$ScriptPath, [string[]]$Arguments, [int]$TimeoutSeconds, [int]$NoProgressSeconds, [string]$LogName)
            $plan = Get-Content -LiteralPath $Arguments[1] -Raw -Encoding UTF8 | ConvertFrom-Json
            $script:rerunCalls += @([pscustomobject]@{ script = (Split-Path -Leaf $ScriptPath); paths = @($plan.paths); timeout = $TimeoutSeconds })
            $status = if (@($plan.paths)[0] -in $PassingAlone) { 'passed' } else { 'failed' }
            [IO.File]::WriteAllText($Arguments[5], (@{ status = $status } | ConvertTo-Json))
            if ($status -ne 'passed') { throw "worker failed" }
        }
        . ([scriptblock]::Create($script:RerunDefinition.Extent.Text))
        $text = Invoke-PesterIsolatedRerun
        return [pscustomobject]@{ text = $text; report = (Get-Content -LiteralPath (Join-Path $outputRoot 'pester-isolated-rerun.json') -Raw -Encoding UTF8 | ConvertFrom-Json) }
    }
}

Describe 'Unstable tests in detailed Status' {
    It 'lists tests that failed nondeterministically or before a pass on the identical tree' {
        $failure = { param([string[]]$Tests) [pscustomobject]@{ stage = 'pester'; codes = @(); testCount = $Tests.Count; tests = @($Tests) } }
        $entries = @(
            [pscustomobject]@{ status = 'failed'; failureClass = 'product'; tree = 't1'; startedAt = '2026-11-10T09:00:00Z'; rawPath = 'r1'; failure = (& $failure @('watchdog deadline')) },
            [pscustomobject]@{ status = 'passed'; failureClass = ''; tree = 't1'; startedAt = '2026-11-10T10:00:00Z'; rawPath = 'r2' },
            [pscustomobject]@{ status = 'failed'; failureClass = 'nondeterministic'; tree = 't2'; startedAt = '2026-11-11T09:00:00Z'; rawPath = 'r3'; failure = (& $failure @('watchdog deadline', 'host transport')) },
            [pscustomobject]@{ status = 'failed'; failureClass = 'product'; tree = 't3'; startedAt = '2026-11-11T10:00:00Z'; rawPath = 'r4'; failure = (& $failure @('real defect')) },
            # A pass that happened before the failure proves nothing about it.
            [pscustomobject]@{ status = 'passed'; failureClass = ''; tree = 't4'; startedAt = '2026-11-11T11:00:00Z'; rawPath = 'r5' },
            [pscustomobject]@{ status = 'failed'; failureClass = 'product'; tree = 't4'; startedAt = '2026-11-11T12:00:00Z'; rawPath = 'r6'; failure = (& $failure @('changed since')) })
        $unstable = @(Get-DeliveryUnstableTests -Entries $entries)
        @($unstable.test) | Should -Be @('watchdog deadline', 'host transport')
        $watchdog = $unstable[0]
        $watchdog.occurrences | Should -Be 2
        $watchdog.nondeterministic | Should -Be 1
        $watchdog.passedLaterOnSameTree | Should -Be 1
        $watchdog.lastOccurrence | Should -Be '2026-11-11T09:00:00Z'
        @($watchdog.runs) | Should -Be @('r1', 'r3')
        @(Get-DeliveryUnstableTests -Entries @()) | Should -BeNullOrEmpty
    }
}

Describe 'Diagnostic isolated rerun of failed Pester files' {
    It 'marks only a file that passes alone as nondeterministic and keeps a reproduced failure' {
        $root = New-RerunFixture @('tests/pester/Flaky.Tests.ps1', 'tests/pester/Broken.Tests.ps1')
        $result = Invoke-RerunFixture $root -PassingAlone @('tests/pester/Flaky.Tests.ps1')
        $result.report.status | Should -Be 'passed-in-isolation'
        @($result.report.files | Where-Object path -eq 'tests/pester/Flaky.Tests.ps1').isolatedRerun | Should -Be 'passed'
        @($result.report.files | Where-Object path -eq 'tests/pester/Broken.Tests.ps1').isolatedRerun | Should -Be 'failed'
        $result.text | Should -Match 'tests/pester/Flaky\.Tests\.ps1 passed alone \(nondeterministic'
        $result.text | Should -Match 'tests/pester/Broken\.Tests\.ps1 failed again'
        # One serial worker per file, through the real shard runner, and no proof or cache output.
        @($script:rerunCalls).Count | Should -Be 2
        @($script:rerunCalls | Where-Object script -ne 'run-pester-shard.ps1') | Should -BeNullOrEmpty
        @($script:rerunCalls | ForEach-Object { @($_.paths).Count }) | Should -Be @(1, 1)
        Test-Path -LiteralPath (Join-Path $root 'build/test-results/local/pester-shards') | Should -BeFalse
        # The classifier and the failure record read the same diagnosis.
        Get-DeliveryFailureClass -Message ("Pester did not pass." + $result.text) -Stage 'pester' | Should -Be 'nondeterministic'
        Get-DeliveryFailureClass -Message 'Pester did not pass. Isolated rerun: tests/pester/Broken.Tests.ps1 failed again.' -Stage 'pester' | Should -Be 'product'
        $summary = Get-DeliveryFailureSummary -ErrorMessage 'gate failed' -Summary $null -WorkingRoot $root -StartedAt ([DateTime]::UtcNow.AddMinutes(-1))
        @($summary.tests | Where-Object file -eq 'tests/pester/Flaky.Tests.ps1').isolatedRerun | Should -Be 'passed'
        @($summary.tests | Where-Object file -eq 'tests/pester/Broken.Tests.ps1').isolatedRerun | Should -Be 'failed'
    }

    It 'skips without a rerun when the budget is short or the failure is systematic' {
        $root = New-RerunFixture @('tests/pester/Flaky.Tests.ps1')
        $short = Invoke-RerunFixture $root -PassingAlone @('tests/pester/Flaky.Tests.ps1') -BudgetSeconds 10
        $short.report.status | Should -Be 'skipped'
        $short.text | Should -Match 'Isolated rerun skipped: remaining budget'
        @($script:rerunCalls).Count | Should -Be 0
        $wide = New-RerunFixture @(1..6 | ForEach-Object { "tests/pester/Broken$_.Tests.ps1" })
        $systematic = Invoke-RerunFixture $wide -PassingAlone @()
        $systematic.report.status | Should -Be 'skipped'
        $systematic.text | Should -Match '6 failed files suggest a systematic failure'
        Get-DeliveryFailureClass -Message ("Pester did not pass." + $systematic.text) -Stage 'pester' | Should -Not -Be 'nondeterministic'
    }
}
