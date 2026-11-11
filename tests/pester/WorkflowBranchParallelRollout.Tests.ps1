BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSupport.ps1')
    $context = Initialize-WorkflowPesterContext
    $HelperPath = $context.HelperPath

    # Master plus registered development worktrees that the real inventory
    # classifies as eligible for the exact candidate.
    function New-RolloutFixture {
        param([Parameter(Mandatory = $true)][string]$Parent, [int]$Branches = 3)
        $root = Join-Path $Parent 'Главный проект с пробелом'
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        & git -C $root init --quiet
        & git -C $root symbolic-ref HEAD refs/heads/master
        & git -C $root config user.email 'rollout@example.invalid'
        & git -C $root config user.name 'Rollout Fixture'
        [IO.File]::WriteAllText((Join-Path $root '.gitignore'), ".agent-1c/snapshots/`n.agent-1c/locks/`n.agent-1c/runs/`n", [Text.UTF8Encoding]::new($false))
        $lock = Join-Path $root '.agent-1c/dependency-lock.json'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $lock) | Out-Null
        [IO.File]::WriteAllText((Join-Path $root '.agent-1c/project.json'), '{"aiRules":{"tools":[]}}', [Text.UTF8Encoding]::new($false))
        $candidate = '3' * 40
        [IO.File]::WriteAllText($lock, ('{"dependencies":{"workflowPackage":{"commit":"' + $candidate + '"}}}'), [Text.UTF8Encoding]::new($false))
        & git -C $root add --all
        & git -C $root commit --quiet -m base
        $branchRoots = @(foreach ($index in 1..$Branches) {
            $branchRoot = Join-Path $Parent "Ветка $index с пробелом"
            & git -C $root branch "itldev/ветка-$index"
            & git -C $root worktree add --quiet $branchRoot "itldev/ветка-$index"
            $branchRoot
        })
        return [pscustomobject]@{ root = $root; branchRoots = $branchRoots; candidate = $candidate
            source = [pscustomobject]@{ root = 'C:\candidate source'; repo = 'repo'; ref = 'pin'; commit = $candidate; source = 'path' } }
    }

    # A stand-in child: a real separate process that sleeps, records its
    # interval and writes the outcome file exactly as the branch helper does.
    $script:FakeChildScript = @'
param([string]$Timeline, [string]$Branch, [string]$ResultPath, [string]$Commit, [int]$Milliseconds, [string]$Mode)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
[IO.File]::AppendAllText($Timeline, ("start`t{0}`t{1}`n" -f $Branch, [DateTime]::UtcNow.Ticks), [Text.UTF8Encoding]::new($false))
Start-Sleep -Milliseconds $Milliseconds
[IO.File]::AppendAllText($Timeline, ("end`t{0}`t{1}`n" -f $Branch, [DateTime]::UtcNow.Ticks), [Text.UTF8Encoding]::new($false))
if ($Mode -eq 'crash') { [Console]::Error.WriteLine('Сбой дочернего процесса'); exit 3 }
$payload = @{ schemaVersion = 1; branch = $Branch; status = $Mode; reason = $(if ($Mode -eq 'completed') { '' } else { 'fixture reason' }); commit = $Commit; clients = @() }
[IO.File]::WriteAllText($ResultPath, ($payload | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
'@

    function Get-MaxOverlap {
        param([string]$Timeline)
        $events = @(Get-Content -LiteralPath $Timeline -Encoding UTF8 | ForEach-Object { $parts = $_ -split "`t"; [pscustomobject]@{ kind = $parts[0]; ticks = [int64]$parts[2] } } | Sort-Object ticks)
        $current = 0; $max = 0
        foreach ($event in $events) { if ($event.kind -eq 'start') { $current++; if ($current -gt $max) { $max = $current } } else { $current-- } }
        return $max
    }
}

Describe 'Parallel development-branch rollout of update-workflow' {
    It 'runs eligible branches in separate helpers up to the limit and keeps a failed branch from stopping the others' {
        $fixture = New-RolloutFixture -Parent (Join-Path $TestDrive 'Параллельный прогон') -Branches 4
        $timeline = Join-Path $TestDrive 'интервалы веток.txt'
        $childScript = Join-Path $TestDrive 'дочерний процесс.ps1'
        [IO.File]::WriteAllText($childScript, $script:FakeChildScript, [Text.UTF8Encoding]::new($true))
        $proof = & {
            . $HelperPath -ProjectRoot $fixture.root -Action help -MaxParallelWorkflowBranches 2 *> $null
            $script:childRequests = @()
            function Invoke-WorkflowDevelopmentBranchItemUpdate { throw 'the parallel route must not update a branch in process' }
            function Start-WorkflowDevelopmentBranchChild {
                param($Item, $Source, $MasterClients, $OutputRoot, $RunInputsPath)
                $script:childRequests += [pscustomobject]@{ branch = [string]$Item.branch; inputs = (Get-Content -LiteralPath $RunInputsPath -Raw -Encoding UTF8 | ConvertFrom-Json) }
                $safe = ConvertTo-SafeName ([string]$Item.branch)
                $resultPath = Join-Path $OutputRoot "$safe.result.json"
                $stdout = Join-Path $OutputRoot "$safe.stdout.json"
                $stderr = Join-Path $OutputRoot "$safe.stderr.log"
                $mode = if ([string]$Item.branch -eq 'itldev/ветка-3') { 'crash' } else { 'completed' }
                $commit = (Get-GitOutputAt -Root ([string]$Item.root) -Arguments @('rev-parse', 'HEAD')).Trim()
                $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $childScript, '-Timeline', $timeline, '-Branch', [string]$Item.branch,
                    '-ResultPath', $resultPath, '-Commit', $commit, '-Milliseconds', '1500', '-Mode', $mode)
                $process = Start-Process -FilePath 'powershell' -ArgumentList (Join-NativeCommandLineArguments -Arguments $arguments) -WindowStyle Hidden `
                    -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
                [pscustomobject]@{ item = $Item; process = $process; stdout = $stdout; stderr = $stderr; resultPath = $resultPath; startedAt = Get-Date; index = -1 }
            }
            $output = Invoke-WorkflowUpdateRunSharedInputs {
                # The master pass verified a machine input in this process.
                $script:ItlWorkflowUpdateRunInputs['roctup-mcp-artifact|fixture'] = @{ value = [pscustomobject]@{ path = 'C:\Общий кэш\MCP_Toolkit.epf'; version = 'v1' } }
                Invoke-WorkflowDevelopmentBranchRollout -Source $fixture.source
            } 6>&1
            [pscustomobject]@{ report = @($output | Where-Object { $_ -is [Collections.IDictionary] -or $_.PSObject.Properties['roots'] })[-1]
                messages = @($output | Where-Object { $_ -is [Management.Automation.InformationRecord] } | ForEach-Object { [string]$_ })
                requests = @($script:childRequests) }
        }
        Get-MaxOverlap -Timeline $timeline | Should -Be 2
        $proof.requests | Should -HaveCount 4
        foreach ($request in $proof.requests) {
            $request.inputs.sourceCommit | Should -Be $fixture.candidate
            @($request.inputs.entries | Where-Object key -eq 'roctup-mcp-artifact|fixture')[0].data.value.path | Should -Be 'C:\Общий кэш\MCP_Toolkit.epf'
        }
        $roots = @($proof.report.roots)
        $roots | Should -HaveCount 4
        @($roots | Where-Object status -eq 'completed') | Should -HaveCount 3
        $failed = @($roots | Where-Object branch -eq 'itldev/ветка-3')[0]
        $failed.status | Should -Be 'blocked'
        $failed.reason | Should -Match 'WORKFLOW_BRANCH_CHILD_FAILED'
        $failed.reason | Should -Match 'Сбой дочернего процесса'
        $failed.continuation | Should -Not -BeNullOrEmpty
        # Report order follows the inventory, not completion order.
        ($roots | ForEach-Object branch) -join ',' | Should -Be 'itldev/ветка-1,itldev/ветка-2,itldev/ветка-3,itldev/ветка-4'
        $saved = Get-Content -LiteralPath (Join-Path $fixture.root '.agent-1c/snapshots/workflow-update-rollout.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $saved.inventoryComplete | Should -BeTrue
        @($proof.messages | Where-Object { $_ -match '^Workflow branch itldev/ветка-\d: (completed|blocked) in \d\d:\d\d\. Log: ' }) | Should -HaveCount 4
    }

    It 'keeps the sequential in-process rollout for limit 1 and warms machine inputs with one in-process branch on resume' {
        $fixture = New-RolloutFixture -Parent (Join-Path $TestDrive 'Последовательный прогон') -Branches 3
        $sequential = & {
            . $HelperPath -ProjectRoot $fixture.root -Action help -MaxParallelWorkflowBranches 1 *> $null
            $script:inProcess = @()
            function Invoke-WorkflowDevelopmentBranchItemUpdate { param($BranchRoot, $Source, $MasterClients) $script:inProcess += $BranchRoot; [pscustomobject]@{ status = 'completed'; reason = ''; commit = 'c'; clients = @() } }
            function Invoke-WorkflowDevelopmentBranchChildren { throw 'limit 1 must not start child helpers' }
            Invoke-WorkflowDevelopmentBranchRollout -Source $fixture.source | Out-Null
            @($script:inProcess)
        }
        $sequential | Should -Be $fixture.branchRoots

        Remove-Item -LiteralPath (Join-Path $fixture.root '.agent-1c/snapshots/workflow-update-rollout.json') -Force
        $resume = & {
            . $HelperPath -ProjectRoot $fixture.root -Action help *> $null
            $script:inProcess = @(); $script:children = @()
            function Invoke-WorkflowDevelopmentBranchItemUpdate { param($BranchRoot, $Source, $MasterClients) $script:inProcess += $BranchRoot; [pscustomobject]@{ status = 'completed'; reason = ''; commit = 'c'; clients = @() } }
            function Invoke-WorkflowDevelopmentBranchChildren {
                param($Items, $Source, $MasterClients, $Limit, $OnOutcome)
                $script:children += @($Items | ForEach-Object { [string]$_.item.root }); $script:limit = $Limit
                foreach ($item in $Items) { & $OnOutcome ([int]$item.index) ([pscustomobject]@{ status = 'completed'; reason = ''; commit = 'c'; clients = @() }) }
            }
            # Resume route: no master pass verified machine inputs in this process.
            $report = Invoke-WorkflowUpdateRunSharedInputs { Invoke-WorkflowDevelopmentBranchRollout -Source $fixture.source }
            [pscustomobject]@{ inProcess = @($script:inProcess); children = @($script:children); limit = $script:limit; report = $report }
        }
        $resume.inProcess | Should -Be @($fixture.branchRoots[0])
        $resume.children | Should -Be @($fixture.branchRoots[1], $fixture.branchRoots[2])
        $resume.limit | Should -Be 3
        @($resume.report.roots | Where-Object status -eq 'completed') | Should -HaveCount 3
    }

    It 'waits for free memory before starting another branch and announces the wait once' {
        $fixture = New-RolloutFixture -Parent (Join-Path $TestDrive 'Ожидание памяти') -Branches 2
        $timeline = Join-Path $TestDrive 'интервалы памяти.txt'
        $childScript = Join-Path $TestDrive 'дочерний процесс памяти.ps1'
        [IO.File]::WriteAllText($childScript, $script:FakeChildScript, [Text.UTF8Encoding]::new($true))
        $messages = & {
            . $HelperPath -ProjectRoot $fixture.root -Action help *> $null
            $script:memoryCalls = 0
            function Get-WorkflowUpdateAvailableMemoryBytes { $script:memoryCalls++; if ($script:memoryCalls -le 4) { [int64]512MB } else { [int64]8GB } }
            function Start-WorkflowDevelopmentBranchChild {
                param($Item, $Source, $MasterClients, $OutputRoot, $RunInputsPath)
                $safe = ConvertTo-SafeName ([string]$Item.branch)
                $resultPath = Join-Path $OutputRoot "$safe.result.json"
                $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $childScript, '-Timeline', $timeline, '-Branch', [string]$Item.branch,
                    '-ResultPath', $resultPath, '-Commit', ('c' * 40), '-Milliseconds', '600', '-Mode', 'completed')
                $process = Start-Process -FilePath 'powershell' -ArgumentList (Join-NativeCommandLineArguments -Arguments $arguments) -WindowStyle Hidden `
                    -RedirectStandardOutput (Join-Path $OutputRoot "$safe.stdout.json") -RedirectStandardError (Join-Path $OutputRoot "$safe.stderr.log") -PassThru
                [pscustomobject]@{ item = $Item; process = $process; stdout = (Join-Path $OutputRoot "$safe.stdout.json"); stderr = (Join-Path $OutputRoot "$safe.stderr.log"); resultPath = $resultPath; startedAt = Get-Date; index = -1 }
            }
            $items = @(0..1 | ForEach-Object { [pscustomobject]@{ index = $_; item = [pscustomobject]@{ root = $fixture.branchRoots[$_]; branch = "itldev/ветка-$($_ + 1)" } } })
            $script:outcomes = @{}
            @(Invoke-WorkflowDevelopmentBranchChildren -Items $items -Source $fixture.source -MasterClients @() -Limit 2 -OnOutcome { param($Index, $Outcome) $script:outcomes[$Index] = $Outcome } 6>&1 |
                ForEach-Object { [string]$_ }) + @("outcomes=$($script:outcomes.Count)")
        }
        @($messages | Where-Object { $_ -match '^Workflow branches: waiting for free memory before the next branch \(512 MB free, 1536 MB required\); 1 running\.$' }) | Should -HaveCount 1
        $messages[-1] | Should -Be 'outcomes=2'
        Get-MaxOverlap -Timeline $timeline | Should -Be 1
    }

    It 'hands only completed machine inputs to a child and pins the catalog revision the master pass read' {
        $root = Join-Path $TestDrive 'Проект входов с пробелом'
        New-Item -ItemType Directory -Force -Path (Join-Path $root '.agent-1c') | Out-Null
        $path = Join-Path $TestDrive 'входы прогона.json'
        $imported = & {
            . $HelperPath -ProjectRoot $root -Action help *> $null
            Invoke-WorkflowUpdateRunSharedInputs {
                $script:ItlWorkflowUpdateRunInputs['roctup-mcp-artifact|a'] = @{ value = [pscustomobject]@{ path = 'C:\Кэш с пробелом\MCP_Toolkit.epf'; sha256 = ('a' * 64) } }
                $script:ItlWorkflowUpdateRunInputs['vanessa-automation-epf|b'] = @{ readyState = [pscustomobject]@{ ready = $true; epfPath = 'C:\Кэш\vanessa.epf' } }
                $script:ItlWorkflowUpdateRunInputs['ui-tool-preparation|c'] = @{ outcome = 'failed' }
                $script:ItlWorkflowUpdateRunInputs['ai-rules-candidate-inventory|d'] = @{ value = @('AGENTS.md', '.codex/rules/правило.md') }
                $script:ItlWorkflowUpdateRunInputs['vibecoding1c-mcp-registry|"C:\\registry"'] = @{ attempted = $true; error = $null; snapshot = @{ publishedAt = 'old' }
                    catalogRefreshAttempted = $true; catalogRefreshError = $null; catalogSnapshot = [pscustomobject]@{ catalogRevision = ('b' * 40) }
                    productContexts = @{ 'c:\master' = @{ projectId = 'master only' } } }
                $script:ItlWorkflowUpdateRunInputs['vibecoding1c-mcp-registry|"C:\\failed"'] = @{ attempted = $true; error = 'fetch failed'; snapshot = $null }
                $script:ItlWorkflowUpdateRunInputs['vanessa-ui-mcp-artifact|pending'] = @{}
                Export-WorkflowUpdateRunSharedInputs -Path $path -SourceCommit ('1' * 40)
            }
            function Read-Vibecoding1cMcpRegistryFile { [pscustomobject]@{ publishedAt = 'local checkout' } }
            Invoke-WorkflowUpdateRunSharedInputs {
                (Import-WorkflowUpdateRunSharedInputs -Path $path -SourceCommit ('2' * 40)) | Should -Be 0
                $count = Import-WorkflowUpdateRunSharedInputs -Path $path -SourceCommit ('1' * 40)
                [pscustomobject]@{ count = $count; entries = @{} + $script:ItlWorkflowUpdateRunInputs }
            }
        }
        $imported.count | Should -Be 5
        $imported.entries['roctup-mcp-artifact|a'].value.path | Should -Be 'C:\Кэш с пробелом\MCP_Toolkit.epf'
        $imported.entries['vanessa-automation-epf|b'].readyState.ready | Should -BeTrue
        $imported.entries['ui-tool-preparation|c'].outcome | Should -Be 'failed'
        @($imported.entries['ai-rules-candidate-inventory|d'].value) | Should -Be @('AGENTS.md', '.codex/rules/правило.md')
        $registry = $imported.entries['vibecoding1c-mcp-registry|"C:\\registry"']
        $registry.attempted | Should -BeTrue
        $registry.catalogRefreshAttempted | Should -BeTrue
        $registry.catalogPinnedRevision | Should -Be ('b' * 40)
        $registry.snapshot.publishedAt | Should -Be 'local checkout'
        $registry.ContainsKey('productContexts') | Should -BeFalse
        $registry.ContainsKey('catalogSnapshot') | Should -BeFalse
        $imported.entries.ContainsKey('vibecoding1c-mcp-registry|"C:\\failed"') | Should -BeFalse
        $imported.entries.ContainsKey('vanessa-ui-mcp-artifact|pending') | Should -BeFalse
    }

    It 'runs a real update-workflow-branch helper that takes the branch lease and reports a busy branch as deferred' {
        $fixture = New-RolloutFixture -Parent (Join-Path $TestDrive 'Настоящий дочерний') -Branches 1
        $branchRoot = $fixture.branchRoots[0]
        $busyLock = Join-Path $branchRoot '.agent-1c/locks/lifecycle.lock'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $busyLock) | Out-Null
        $outputRoot = Join-Path $TestDrive 'Вывод дочернего с пробелом'
        New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
        $runInputs = Join-Path $outputRoot 'run-inputs.json'
        [IO.File]::WriteAllText($runInputs, ('{"schemaVersion":1,"sourceCommit":"' + $fixture.candidate + '","entries":[]}'), [Text.UTF8Encoding]::new($false))
        $handle = [IO.File]::Open($busyLock, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try {
            $outcome = & {
                . $HelperPath -ProjectRoot $fixture.root -Action help *> $null
                $item = [pscustomobject]@{ root = $branchRoot; branch = 'itldev/ветка-1' }
                $entry = Start-WorkflowDevelopmentBranchChild -Item $item -Source $fixture.source -MasterClients @() -OutputRoot $outputRoot -RunInputsPath $runInputs
                if (-not $entry.process.WaitForExit(240000)) { $entry.process.Kill(); throw 'child helper did not finish' }
                Receive-WorkflowDevelopmentBranchChild -Entry $entry
            }
        } finally { $handle.Dispose() }
        $outcome.status | Should -Be 'deferred' -Because ($outcome | ConvertTo-Json -Depth 4)
        $outcome.reason | Should -Match 'LIFECYCLE_LOCK_WAIT_TIMEOUT'
        $outcome.logPath | Should -Match ([regex]::Escape((Join-Path $branchRoot '.agent-1c\runs\compact-')))
        Test-Path -LiteralPath $outcome.logPath -PathType Leaf | Should -BeTrue
        (Get-Content -LiteralPath (@(Get-ChildItem -LiteralPath $outputRoot -Filter '*.request.json')[0].FullName) -Raw -Encoding UTF8 | ConvertFrom-Json).branchRoot | Should -Be $branchRoot
        & git -C $branchRoot status --porcelain | Should -BeNullOrEmpty
    }

    It 'refuses an update-workflow-branch request for another worktree' {
        $fixture = New-RolloutFixture -Parent (Join-Path $TestDrive 'Чужой запрос') -Branches 1
        $requestPath = Join-Path $TestDrive 'запрос ветки.json'
        [IO.File]::WriteAllText($requestPath, ((@{ schemaVersion = 1; branchRoot = $fixture.root; branch = 'itldev/ветка-1'; source = $fixture.source
            masterClients = @(); runInputsPath = ''; resultPath = (Join-Path $TestDrive 'результат.json') }) | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
        {
            & {
                . $HelperPath -ProjectRoot $fixture.branchRoots[0] -Action help -WorkflowBranchRequestPath $requestPath *> $null
                Invoke-WorkflowDevelopmentBranchChild
            }
        } | Should -Throw '*WORKFLOW_BRANCH_REQUEST_INVALID*'
        Test-Path -LiteralPath (Join-Path $TestDrive 'результат.json') | Should -BeFalse
    }
}
