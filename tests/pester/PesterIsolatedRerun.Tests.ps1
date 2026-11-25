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
    $script:ShardArgumentsDefinition = $script:CheckAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Get-PesterShardRunnerArguments' }, $true)
    $script:RealRepoRoot = $RepoRoot
    function Get-NamedArgument([string[]]$Arguments, [string]$Name) {
        $index = [Array]::IndexOf($Arguments, "-$Name")
        if ($index -lt 0) { return $null }
        if ($index + 1 -lt $Arguments.Count -and $Arguments[$index + 1] -notlike '-*') { return $Arguments[$index + 1] }
        return $true
    }
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
    # FailingAlone maps a file to the test names that fail in its rerun; by
    # default a file that does not pass alone fails its original test again.
    function Invoke-RerunFixture([string]$Root, [string[]]$PassingAlone, [int]$BudgetSeconds = 3600, [string[]]$Unfinished = @(), [hashtable]$FailingAlone = @{}) {
        $repoRoot = $Root
        $outputRoot = Join-Path $Root 'build/test-results/local'
        $junitPath = Join-Path $outputRoot 'pester.xml'
        $modeHardBudgetSeconds = $BudgetSeconds
        $overallStopwatch = [Diagnostics.Stopwatch]::StartNew()
        $effectiveMode = 'Targeted'; $resolvedAiRulesSource = ''; $effectivePesterWorkers = 3; $PesterWorkers = 3; $pesterWorkersExplicit = $false
        $script:rerunCalls = @()
        # The real child is scripts/invoke-pester-shards.ps1; this one writes the
        # scripted worker summary and JUnit the real runner would produce.
        function Invoke-PowerShellChild {
            param([string]$ScriptPath, [string[]]$Arguments, [int]$TimeoutSeconds, [int]$NoProgressSeconds, [string]$LogName)
            $paths = @((Get-Content -LiteralPath (Get-NamedArgument $Arguments 'SelectionPath') -Raw -Encoding UTF8 | ConvertFrom-Json).tests)
            $script:rerunCalls += @([pscustomobject]@{ script = (Split-Path -Leaf $ScriptPath); paths = $paths; timeout = $TimeoutSeconds; arguments = $Arguments })
            # The real wait kills a child at its deadline before the worker writes a result.
            if ($paths[0] -in $Unfinished) { throw "PowerShell child timed out after $TimeoutSeconds seconds" }
            $failing = @(if ($paths[0] -in $PassingAlone) { } elseif ($FailingAlone.ContainsKey($paths[0])) { $FailingAlone[$paths[0]] } else { 'fails' })
            $path = [Security.SecurityElement]::Escape((Join-Path $repoRoot $paths[0]))
            $cases = @(@(@('fails') + $failing) | Sort-Object -Unique | ForEach-Object {
                '<testcase name="' + [Security.SecurityElement]::Escape($_) + '" classname="' + $path + '">' + $(if ($_ -in $failing) { '<failure message="boom"/>' } else { '' }) + '</testcase>'
            }) -join ''
            [IO.File]::WriteAllText((Get-NamedArgument $Arguments 'JunitPath'), ('<?xml version="1.0" encoding="utf-8"?><testsuites><testsuite name="' + $path + '">' + $cases + '</testsuite></testsuites>'), [Text.UTF8Encoding]::new($false))
            $workerRoot = Join-Path (Get-NamedArgument $Arguments 'OutputRoot') 'pester-shards'
            [void][IO.Directory]::CreateDirectory($workerRoot)
            $status = if ($failing.Count) { 'failed' } else { 'passed' }
            [IO.File]::WriteAllText((Join-Path $workerRoot 'summary.json'), ([ordered]@{ status = $status; workers = @([ordered]@{ worker = 1; status = $status }) } | ConvertTo-Json -Depth 4))
            if ($status -ne 'passed') { throw "Pester shards failed" }
        }
        . ([scriptblock]::Create($script:ShardArgumentsDefinition.Extent.Text))
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
        # One serial worker per file, through the shard runner of the normal run, and no proof or cache output.
        @($script:rerunCalls).Count | Should -Be 2
        @($script:rerunCalls | Where-Object script -ne 'invoke-pester-shards.ps1') | Should -BeNullOrEmpty
        @($script:rerunCalls | ForEach-Object { @($_.paths).Count }) | Should -Be @(1, 1)
        foreach ($call in $script:rerunCalls) {
            Get-NamedArgument $call.arguments 'IsolatedRerun' | Should -BeTrue
            Get-NamedArgument $call.arguments 'WorkerCount' | Should -Be '1'
        }
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
        $staleRoot = Join-Path $root 'build/test-results/local/pester-isolated-rerun/AiRulesClients.Tests/pester-shards'
        [void][IO.Directory]::CreateDirectory($staleRoot)
        [IO.File]::WriteAllText((Join-Path $staleRoot 'summary.json'), '{"status":"passed","workers":[{"worker":1}]}')
        $result = Invoke-RerunFixture $root -PassingAlone @() -Unfinished @($file)
        @($script:rerunCalls.timeout) | Should -Be @(60 + [int][Math]::Ceiling(2 * $observed))
        $result.report.status | Should -Be 'inconclusive'
        @($result.report.files).isolatedRerun | Should -Be 'skipped'
        # The verdict names the unfinished file; the report above carries its status.
        $result.text | Should -Match 'inconclusive'
        $result.text.Contains('tests/pester/AiRulesClients.Tests.ps1') | Should -BeTrue
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

    It 'counts a rerun as reproduced only when an originally failed test fails again' {
        # Observed 2026-11-20: a flaky cache test failed, and its rerun failed a
        # different test that needed an input the rerun did not receive.
        $root = New-RerunFixture @('tests/pester/Other.Tests.ps1', 'tests/pester/Same.Tests.ps1')
        $result = Invoke-RerunFixture $root -PassingAlone @() -FailingAlone @{
            'tests/pester/Other.Tests.ps1' = @('needs the archive')
            'tests/pester/Same.Tests.ps1' = @('fails', 'needs the archive') }
        $other = @($result.report.files | Where-Object path -eq 'tests/pester/Other.Tests.ps1')[0]
        $other.isolatedRerun | Should -Be 'not-reproduced'
        @($other.originalFailures) | Should -Be @('fails')
        @($other.isolatedFailures) | Should -Be @('needs the archive')
        @($result.report.files | Where-Object path -eq 'tests/pester/Same.Tests.ps1').isolatedRerun | Should -Be 'failed'
        $result.report.status | Should -Be 'reproduced'
        $result.text | Should -Match 'tests/pester/Same\.Tests\.ps1 failed again'
        $result.text | Should -Not -Match 'Other\.Tests\.ps1[^.]*failed again'
        # The inconclusive file is named with the test that failed alone; the report fields above carry the verdict.
        $result.text | Should -Match ([regex]::Escape($other.path))
        $result.text | Should -Match ([regex]::Escape("($(@($other.isolatedFailures) -join ', '))"))

        $only = New-RerunFixture @('tests/pester/Other.Tests.ps1')
        $alone = Invoke-RerunFixture $only -PassingAlone @() -FailingAlone @{ 'tests/pester/Other.Tests.ps1' = @('needs the archive') }
        $alone.report.status | Should -Be 'inconclusive'
        $alone.text | Should -Not -Match 'failed again|passed alone'
        # A different failure neither reproduces nor excuses the original one.
        Get-DeliveryFailureClass -Message ("Pester did not pass." + $alone.text) -Stage 'pester' | Should -Be 'product'
        $summary = Get-DeliveryFailureSummary -ErrorMessage 'gate failed' -Summary $null -WorkingRoot $only -StartedAt ([DateTime]::UtcNow.AddMinutes(-1))
        @($summary.tests).isolatedRerun | Should -Be 'not-reproduced'
    }

    It 'gives the rerun the shard runner inputs of the normal run in every mode' {
        $effectivePesterWorkers = 4; $PesterWorkers = 3; $pesterWorkersExplicit = $false
        $repoRoot = Join-Path $TestDrive 'кандидат с пробелом'
        $resolvedAiRulesSource = Join-Path $TestDrive 'правила ai с пробелом'
        . ([scriptblock]::Create($script:ShardArgumentsDefinition.Extent.Text))
        foreach ($effectiveMode in @('Targeted', 'Full', 'Develop', 'Release')) {
            $normal = @(Get-PesterShardRunnerArguments -ShardOutputRoot 'a' -ShardJunitPath 'a.xml' -ShardSelectionPath 's.json')
            $rerun = @(Get-PesterShardRunnerArguments -ShardOutputRoot 'b' -ShardJunitPath 'b.xml' -ShardSelectionPath 's.json' -IsolatedRerun)
            Get-NamedArgument $rerun 'RepositoryRoot' | Should -BeExactly $repoRoot
            Get-NamedArgument $rerun 'AiRulesSource' | Should -Be (Get-NamedArgument $normal 'AiRulesSource')
            Get-NamedArgument $rerun 'IsolatedRerun' | Should -BeTrue
            Get-NamedArgument $normal 'IsolatedRerun' | Should -BeNullOrEmpty
        }
        Get-NamedArgument $normal 'AiRulesSource' | Should -BeExactly $resolvedAiRulesSource
    }

    It 'reruns a file that needs the Vanessa archive with the archive variable of the normal run' {
        $realRoot = $script:RealRepoRoot
        $root = Join-Path $TestDrive 'повтор vanessa с пробелом'
        New-Item -ItemType Directory -Force -Path (Join-Path $root 'tests/pester'), (Join-Path $root 'templates'), (Join-Path $root 'scripts') | Out-Null
        & git -C $root init --quiet; & git -C $root config user.name 'ITL Test'; & git -C $root config user.email 'itl-test@example.invalid'
        [IO.File]::WriteAllText((Join-Path $root '.gitignore'), "build/`n", [Text.UTF8Encoding]::new($false))
        Copy-Item -LiteralPath (Join-Path $realRoot 'scripts/pester-timings.json') -Destination (Join-Path $root 'scripts/pester-timings.json')
        # Fails once like the unstable cache test, and always without the archive.
        $body = @'
Describe 'fixture' {
    It 'needs the archive' {
        Add-Content -LiteralPath $env:ITL_TEST_RERUN_ARCHIVE_PROBE -Value ([string]$env:ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE) -Encoding UTF8
        $env:ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE | Should -Not -BeNullOrEmpty
        $marker = $env:ITL_TEST_RERUN_ARCHIVE_PROBE + '.first'
        if (-not (Test-Path -LiteralPath $marker)) { [IO.File]::WriteAllText($marker, ''); throw 'WORKFLOW_UPDATE_SOURCE_BUSY: simulated unstable first run' }
    }
}
'@
        [IO.File]::WriteAllText((Join-Path $root 'tests/pester/BootstrapUpdate.Tests.ps1'), $body, [Text.UTF8Encoding]::new($true))
        $catalog = [ordered]@{schemaVersion=1;contracts=@([ordered]@{id='bootstrap';owner='fixture';gate='targeted';budgetSeconds=30;primaryTest='tests/pester/BootstrapUpdate.Tests.ps1';paths=@('fixture/*');tests=@('tests/pester/BootstrapUpdate.Tests.ps1')});pesterExternalInputs=[ordered]@{'tests/pester/BootstrapUpdate.Tests.ps1'=@('ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE')}}
        [IO.File]::WriteAllText((Join-Path $root 'tests/quality-contracts.json'), ($catalog | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        $payload = [byte[]](80,75,3,4,9,8,7,6); $sha = [Security.Cryptography.SHA256]::Create()
        try { $expected = ([BitConverter]::ToString($sha.ComputeHash($payload))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
        $assetName = 'vanessa-automation-single.1.2.043.42-itl-r98.zip'
        # An empty URL makes any network fallback fail; only the exact local build can satisfy it.
        $lock = [ordered]@{dependencies=[ordered]@{vanessaAutomation=[ordered]@{compatibilityVersion='1.2.043.42';downstreamRevision='itl-r98';assetName=$assetName;sha256=$expected;url=''}}}
        [IO.File]::WriteAllText((Join-Path $root 'templates/dependency-lock.json'), ($lock | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        $build = Join-Path $root 'build/third-party/vanessa-automation/1.2.043.42-itl-r98'
        New-Item -ItemType Directory -Force -Path $build | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $build $assetName), $payload)
        & git -C $root add --all; & git -C $root commit --quiet -m fixture

        $repoRoot = $root
        $outputRoot = Join-Path $root 'build/test-results/local'
        $junitPath = Join-Path $outputRoot 'pester.xml'
        $modeHardBudgetSeconds = 3600; $overallStopwatch = [Diagnostics.Stopwatch]::StartNew()
        $effectiveMode = 'Targeted'; $resolvedAiRulesSource = ''; $effectivePesterWorkers = 1; $PesterWorkers = 1; $pesterWorkersExplicit = $true
        $script:childRuns = @()
        # The real shard runner of this repository, against the fixture candidate.
        function Invoke-PowerShellChild {
            param([string]$ScriptPath, [string[]]$Arguments, [int]$TimeoutSeconds, [int]$NoProgressSeconds, [string]$LogName)
            $run = Invoke-TestPowerShellFile -FilePath (Join-Path $realRoot ('scripts/' + (Split-Path -Leaf $ScriptPath))) -Arguments $Arguments
            $script:childRuns += @([pscustomobject]@{ arguments = $Arguments; run = $run })
            if ($run.exitCode -ne 0) { throw "child exit=$($run.exitCode)" }
        }
        . ([scriptblock]::Create($script:ShardArgumentsDefinition.Extent.Text))
        . ([scriptblock]::Create($script:RerunDefinition.Extent.Text))

        $probe = Join-Path $TestDrive 'архив повтора с пробелом.txt'
        $previousProbe = $env:ITL_TEST_RERUN_ARCHIVE_PROBE
        $previousArchive = [Environment]::GetEnvironmentVariable('ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE', 'Process')
        try {
            $env:ITL_TEST_RERUN_ARCHIVE_PROBE = $probe
            [Environment]::SetEnvironmentVariable('ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE', $null, 'Process')
            $selectionPath = Join-Path $root 'build/selection.json'
            [IO.File]::WriteAllText($selectionPath, '{"tests":["tests/pester/BootstrapUpdate.Tests.ps1"]}', [Text.UTF8Encoding]::new($false))
            { Invoke-PowerShellChild -ScriptPath 'invoke-pester-shards.ps1' -Arguments @(Get-PesterShardRunnerArguments -ShardOutputRoot $outputRoot -ShardJunitPath $junitPath -ShardSelectionPath $selectionPath) } | Should -Throw
            $cacheRoot = Join-Path $root '.git/itl/pester-shards/v1'
            $cacheEntries = @(Get-ChildItem -LiteralPath $cacheRoot -Force -ErrorAction SilentlyContinue).Count
            $text = Invoke-PesterIsolatedRerun
        } finally {
            $env:ITL_TEST_RERUN_ARCHIVE_PROBE = $previousProbe
            [Environment]::SetEnvironmentVariable('ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE', $previousArchive, 'Process')
        }
        $details = ($script:childRuns | ForEach-Object { $_.run.combinedText }) -join "`n"
        @($script:childRuns).Count | Should -Be 2 -Because $details
        Get-NamedArgument $script:childRuns[1].arguments 'IsolatedRerun' | Should -BeTrue
        $report = Get-Content -LiteralPath (Join-Path $outputRoot 'pester-isolated-rerun.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $report.status | Should -Be 'passed-in-isolation' -Because $details
        @($report.files).isolatedRerun | Should -Be 'passed'
        $text | Should -Match 'BootstrapUpdate\.Tests\.ps1 passed alone'
        # The normal run and its rerun observed one and the same archive.
        $observed = @(Get-Content -LiteralPath $probe -Encoding UTF8 | Where-Object { $_ })
        $observed.Count | Should -Be 2
        $observed[0] | Should -Not -BeNullOrEmpty
        $observed[1] | Should -BeExactly $observed[0]
        Test-Path -LiteralPath $observed[0] -PathType Leaf | Should -BeTrue
        # A rerun that passed adds no reusable proof.
        @(Get-ChildItem -LiteralPath $cacheRoot -Force -ErrorAction SilentlyContinue).Count | Should -Be $cacheEntries
    }
}
