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
    function New-RerunFixture([string[]]$FailedFiles, [hashtable]$ObservedSeconds = @{}) {
        $root = Join-Path $TestDrive ('Кандидат с пробелом ' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        foreach ($relative in @('scripts', 'tests/pester', 'build/test-results/local')) { [void][IO.Directory]::CreateDirectory((Join-Path $root $relative)) }
        Copy-Item -LiteralPath (Join-Path $RepoRoot 'scripts/pester-timings.json') -Destination (Join-Path $root 'scripts/pester-timings.json')
        $suites = @($FailedFiles | ForEach-Object {
            $path = [Security.SecurityElement]::Escape((Join-Path $root $_))
            $time = if ($ObservedSeconds.ContainsKey($_)) { ' time="' + ([double]$ObservedSeconds[$_]).ToString([Globalization.CultureInfo]::InvariantCulture) + '"' } else { '' }
            '<testsuite name="' + $path + '"' + $time + '><testcase name="fails" classname="' + $path + '"><failure message="boom"/></testcase></testsuite>'
        }) -join ''
        [IO.File]::WriteAllText((Join-Path $root 'build/test-results/local/pester.xml'), ('<?xml version="1.0" encoding="utf-8"?><testsuites>' + $suites + '</testsuites>'), [Text.UTF8Encoding]::new($false))
        return $root
    }
    function Invoke-RerunFixture([string]$Root, [string[]]$PassingAlone, [int]$BudgetSeconds = 3600, [string[]]$Unfinished = @()) {
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
            # The real wait kills a child at its deadline before the worker writes a result.
            if (@($plan.paths)[0] -in $Unfinished) { throw "PowerShell child timed out after $TimeoutSeconds seconds" }
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

    It 'sizes the rerun deadline from the file time observed in this run and never reports an unfinished rerun as reproduced' {
        # The tracked weight of a real file can lag far behind its current duration.
        $file = 'tests/pester/AiRulesClients.Tests.ps1'
        $tracked = [double](Get-Content -LiteralPath (Join-Path $RepoRoot 'scripts/pester-timings.json') -Raw -Encoding UTF8 | ConvertFrom-Json).files.'AiRulesClients.Tests.ps1'
        $observed = [Math]::Max(80.987, $tracked + 50)
        $root = New-RerunFixture @($file) -ObservedSeconds @{ $file = $observed }
        # A stale result from an earlier rerun must not become this rerun's verdict.
        [void][IO.Directory]::CreateDirectory((Join-Path $root 'build/test-results/local/pester-isolated-rerun'))
        [IO.File]::WriteAllText((Join-Path $root 'build/test-results/local/pester-isolated-rerun/AiRulesClients.Tests.result.json'), '{"status":"passed"}')
        $result = Invoke-RerunFixture $root -PassingAlone @() -Unfinished @($file)
        @($script:rerunCalls.timeout) | Should -Be @(60 + [int][Math]::Ceiling(2 * $observed))
        $result.report.status | Should -Be 'inconclusive'
        @($result.report.files).isolatedRerun | Should -Be 'skipped'
        $result.text | Should -Match 'Isolated rerun inconclusive: tests/pester/AiRulesClients\.Tests\.ps1 ended without a worker result'
        $result.text | Should -Not -Match 'failed again|passed alone'
        # An inconclusive rerun neither downgrades nor excuses the original failure.
        Get-DeliveryFailureClass -Message ("Pester did not pass." + $result.text) -Stage 'pester' | Should -Be 'product'
        # A file without an observed time keeps its tracked or default weight.
        $plain = New-RerunFixture @('tests/pester/Unlisted.Tests.ps1')
        $null = Invoke-RerunFixture $plain -PassingAlone @() -Unfinished @('tests/pester/Unlisted.Tests.ps1')
        @($script:rerunCalls.timeout) | Should -Be @(180)
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
