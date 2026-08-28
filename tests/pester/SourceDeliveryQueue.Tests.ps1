BeforeAll { . (Join-Path $PSScriptRoot "SourceDelivery.TestSupport.ps1") }

Describe "Source develop queue and delivery" {
It "parses the orchestrator and exposes the bounded delivery actions" {
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($DeliveryScript, [ref]$tokens, [ref]$errors)
        @($errors) | Should -BeNullOrEmpty
        $action = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq "Action" } | Select-Object -First 1
        @($action.Attributes | Where-Object TypeName -match ValidateSet | Select-Object -ExpandProperty PositionalArguments | ForEach-Object SafeGetValue) | Should -Be @("RegisterChange", "Status", "PublishDevelop", "PromoteRelease", "ReleaseMaster")
        $text = $DeliverySourceText
        $text | Should -Not -Match 'Restore-DeliveryContinuationQualification'
        $text | Should -Match 'publication-attempts\\develop\.json'
        $text | Should -Match 'develop-qualified'
        $text | Should -Match 'component-finalized'
        $text | Should -Match 'same failure twice'
        $text | Should -Match 'Restore-PriorDevelopPublicationQualification'
        $text | Should -Match 'Invoke-SourceGate -Mode "Develop" -WorkingRoot \$worktree\.path -TargetBaseRef \$remoteDevelop'
        $text | Should -Match 'Promote-AccumulatedDevelopToMaster'
    }

It "resolves the repository root after parameter binding in Windows PowerShell 5.1" {
        $result = Invoke-DeliveryTestPowerShell -Arguments @("-Action", "Status")
        $result.exitCode | Should -Be 0
        $status = $result.stdout | ConvertFrom-Json
        $status.status | Should -Be "ok"
        @($status.PSObject.Properties.Name) | Should -Contain "queue"
    }

It "registers base and head atomically for a path with Cyrillic and spaces" {
        $fixture = $null; $parallelRoot = ""; try {
            $fixture = New-DeliveryFixture
            $tests = Join-Path $fixture.root "tests\pester"
            New-Item -ItemType Directory -Force -Path $tests | Out-Null
            Set-Content -LiteralPath (Join-Path $fixture.root "скрипт с пробелами.ps1") -Encoding UTF8 -Value "'ok'"
            Set-Content -LiteralPath (Join-Path $tests "Behavior.Tests.ps1") -Encoding UTF8 -Value "Describe 'behavior' { It 'works' { `$true | Should -BeTrue } }"
            & git -C $fixture.root add --all
            & git -C $fixture.root commit -m "feat: fixture" *> $null
            $head = (& git -C $fixture.root rev-parse HEAD).Trim()
            $result = Invoke-DeliveryTestPowerShell -Arguments @("-Action", "RegisterChange", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"'), "-QueueId", '"codex/parallel branch"', "-CoverageContract", "contract-one,contract-two")
            $result.exitCode | Should -Be 0
            (& git -C $fixture.root rev-parse refs/itl/develop-queue/codex/parallel-branch/base).Trim() | Should -Be $fixture.base
            (& git -C $fixture.root rev-parse refs/itl/develop-queue/codex/parallel-branch/head).Trim() | Should -Be $head
            $parallelRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl parallel worktree " + [guid]::NewGuid().ToString("N"))
            & git -C $fixture.root worktree add --quiet -b topic-two $parallelRoot $fixture.base *> $null
            New-Item -ItemType Directory -Force -Path (Join-Path $parallelRoot "tests\pester") | Out-Null
            Set-Content -LiteralPath (Join-Path $parallelRoot "скрипт с пробелами.ps1") -Encoding UTF8 -Value "'conflicting second'"
            Set-Content -LiteralPath (Join-Path $parallelRoot "tests\pester\Second.Tests.ps1") -Encoding UTF8 -Value "Describe 'second' { It 'works' { `$true | Should -BeTrue } }"
            & git -C $parallelRoot add --all; & git -C $parallelRoot commit -m "feat: parallel fixture" *> $null
            Invoke-DeliveryTestPowerShell -Arguments @("-Action", "RegisterChange", "-RepositoryRoot", ('"' + $parallelRoot + '"'), "-GateScript", ('"' + $fixture.gate + '"'), "-QueueId", "parallel-two") | Out-Null
            $status = Invoke-DeliveryTestPowerShell -Arguments @("-Action", "Status", "-RepositoryRoot", ('"' + $fixture.root + '"'))
            $statusPayload = $status.stdout | ConvertFrom-Json; @($statusPayload.queue.id | Sort-Object) | Should -Be @("codex/parallel-branch", "parallel-two"); [int]$statusPayload.runHistory.count | Should -BeGreaterOrEqual 2; [int]($statusPayload.runHistory.byMode | Where-Object mode -eq Targeted | Select-Object -ExpandProperty count) | Should -BeGreaterOrEqual 2
            (Invoke-DeliveryTestPowerShell -Arguments @("-Action", "PublishDevelop", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"')) -AllowFailure).exitCode | Should -Not -Be 0
            @(& git -C $fixture.root for-each-ref refs/itl/develop-queue) | Should -HaveCount 4
        } finally {
            if ($fixture -and $parallelRoot) { & git -C $fixture.root worktree remove --force $parallelRoot *> $null }
            Remove-DeliveryFixture -Fixture $fixture
        }
    }

It "targets only commits after the existing head of the same queue" {
        $fixture = $null; try {
            $fixture = New-DeliveryFixture
            $tests = Join-Path $fixture.root "tests\pester"
            New-Item -ItemType Directory -Force -Path $tests | Out-Null
            Set-Content -LiteralPath (Join-Path $fixture.root "first.ps1") -Encoding UTF8 -Value "'first'"
            Set-Content -LiteralPath (Join-Path $tests "First.Tests.ps1") -Encoding UTF8 -Value "Describe 'first' { It 'works' { `$true | Should -BeTrue } }"
            & git -C $fixture.root add --all
            & git -C $fixture.root commit -m "feat: first queued change" *> $null
            $firstHead = (& git -C $fixture.root rev-parse HEAD).Trim()
            Invoke-DeliveryTestPowerShell -Arguments @("-Action", "RegisterChange", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"'), "-QueueId", "same-queue") | Out-Null

            $baseTree = (& git -C $fixture.root rev-parse "$($fixture.base)^{tree}").Trim()
            $remoteHead = (& git -C $fixture.root commit-tree $baseTree -p $fixture.base -m "unrelated remote develop movement").Trim()
            & git -C $fixture.root push --quiet origin "$remoteHead`:refs/heads/develop" *> $null
            & git -C $fixture.root fetch --quiet origin develop *> $null
            (& git -C $fixture.root rev-parse origin/develop).Trim() | Should -Be $remoteHead

            Set-Content -LiteralPath (Join-Path $fixture.root "second.ps1") -Encoding UTF8 -Value "'second'"
            Set-Content -LiteralPath (Join-Path $tests "Second.Tests.ps1") -Encoding UTF8 -Value "Describe 'second' { It 'works' { `$true | Should -BeTrue } }"
            & git -C $fixture.root add --all
            & git -C $fixture.root commit -m "feat: second queued change" *> $null
            $secondHead = (& git -C $fixture.root rev-parse HEAD).Trim()
            $result = Invoke-DeliveryTestPowerShell -Arguments @("-Action", "RegisterChange", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"'), "-QueueId", "same-queue")
            $payload = $result.stdout | ConvertFrom-Json

            @((Get-Content -LiteralPath $fixture.targetBaseLog -Encoding UTF8)) | Should -Be @($fixture.base, $firstHead)
            @($payload.paths | Sort-Object) | Should -Be @("second.ps1", "tests/pester/Second.Tests.ps1")
            (& git -C $fixture.root rev-parse refs/itl/develop-queue/same-queue/base).Trim() | Should -Be $fixture.base
            (& git -C $fixture.root rev-parse refs/itl/develop-queue/same-queue/head).Trim() | Should -Be $secondHead
        } finally { Remove-DeliveryFixture -Fixture $fixture }
    }

It "refuses executable changes without tests or an explicit reused contract" {
        $fixture = $null; try {
            $fixture = New-DeliveryFixture
            Set-Content -LiteralPath (Join-Path $fixture.root "behavior.ps1") -Encoding UTF8 -Value "'changed'"
            & git -C $fixture.root add behavior.ps1
            & git -C $fixture.root commit -m "feat: uncovered" *> $null
            $result = Invoke-DeliveryTestPowerShell -Arguments @("-Action", "RegisterChange", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"')) -AllowFailure
            $result.exitCode | Should -Not -Be 0
            $result.stderr | Should -Match "must declare an existing -CoverageContract"
            @(& git -C $fixture.root for-each-ref refs/itl/develop-queue) | Should -BeNullOrEmpty
        } finally { Remove-DeliveryFixture -Fixture $fixture }
    }

It "blocks a duplicate while an orphan gate is alive and journals stale recovery" {
        $fixture = $null; try {
            $fixture = New-DeliveryFixture; New-Item -ItemType Directory -Force -Path (Join-Path $fixture.root "tests\pester") | Out-Null; Set-Content -LiteralPath (Join-Path $fixture.root "tests\pester\DeliveryRecovery.Tests.ps1") -Encoding UTF8 -Value "Describe 'delivery recovery' { It 'works' { `$true | Should -BeTrue } }"; & git -C $fixture.root add --all; & git -C $fixture.root commit -m "feat: recovery fixture" *> $null; Invoke-DeliveryTestPowerShell -Arguments @("-Action", "RegisterChange", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"')) | Out-Null
            $lockRoot = Join-Path $fixture.root ".git\itl\delivery-operation"; New-Item -ItemType Directory -Force -Path $lockRoot | Out-Null; $acquiring = Invoke-DeliveryTestPowerShell -Arguments @("-Action", "PublishDevelop", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"')) -AllowFailure; $acquiring.exitCode | Should -Not -Be 0; $acquiring.stderr | Should -Match "acquiring the shared lock"; $pesterProcess = Get-Process -Id $PID
            $operation = [ordered]@{ schemaVersion=1; id=[guid]::NewGuid().ToString("N"); action="PublishDevelop"; startedAt=[DateTime]::UtcNow.AddMinutes(-1).ToString("o"); ownerPid=999999; ownerProcessStartedAt=[DateTime]::UtcNow.AddDays(-1).ToString("o"); mode="Develop"; workingRoot=""; gatePid=$PID; gateProcessStartedAt=$pesterProcess.StartTime.ToUniversalTime().ToString("o"); gateStatus="running"; runRecordPath="" }; [IO.File]::WriteAllText((Join-Path $lockRoot "operation.json"), (($operation | ConvertTo-Json -Depth 6) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
            $status = (Invoke-DeliveryTestPowerShell -Arguments @("-Action", "Status", "-RepositoryRoot", ('"' + $fixture.root + '"'))).stdout | ConvertFrom-Json; $status.activeOperation.status | Should -Be "running"; $status.activeOperation.gateAlive | Should -BeTrue; $duplicate = Invoke-DeliveryTestPowerShell -Arguments @("-Action", "PublishDevelop", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"')) -AllowFailure; $duplicate.exitCode | Should -Not -Be 0; $duplicate.stderr | Should -Match "already active"
            $summaryRoot = Join-Path $fixture.root "build\test-results\local"; New-Item -ItemType Directory -Force -Path $summaryRoot | Out-Null; $summaryStarted = [DateTime]::UtcNow.AddSeconds(-2); $summaryFinished = [DateTime]::UtcNow.AddSeconds(-1); $summary = [ordered]@{ mode="Targeted"; status="failed"; startedAt=$summaryStarted.ToString("o"); finishedAt=$summaryFinished.ToString("o"); error="fixture interrupted"; tests=[ordered]@{passed=0;failed=1;skipped=0}; stages=@() }; [IO.File]::WriteAllText((Join-Path $summaryRoot "check-summary.json"), (($summary | ConvertTo-Json -Depth 6) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
            $operation.gatePid = 999998; $operation.gateProcessStartedAt = [DateTime]::UtcNow.AddDays(-1).ToString("o"); $operation.workingRoot = $fixture.root; $operation.mode = "Targeted"; [IO.File]::WriteAllText((Join-Path $lockRoot "operation.json"), (($operation | ConvertTo-Json -Depth 6) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
            $published = Invoke-DeliveryTestPowerShell -Arguments @("-Action", "PublishDevelop", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"'), "-ComponentFinalizerScript", ('"' + $fixture.finalizer + '"')); ($published.stdout | ConvertFrom-Json).status | Should -Be "published"; Test-Path -LiteralPath (Join-Path $fixture.root ".git\itl\operations\$($operation.id).json") | Should -BeTrue; $history = ((Invoke-DeliveryTestPowerShell -Arguments @("-Action", "Status", "-RepositoryRoot", ('"' + $fixture.root + '"'))).stdout | ConvertFrom-Json).runHistory; @($history.lastRuns | Where-Object { [string]$_.error -match "Recovered after the delivery wrapper" }).Count | Should -Be 1
        } finally { Remove-DeliveryFixture -Fixture $fixture }
    }
}
