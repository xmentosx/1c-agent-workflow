BeforeAll { . (Join-Path $PSScriptRoot "SourceDelivery.TestSupport.ps1") }

Describe "Source develop queue and delivery" {
It "blocks a duplicate while an orphan gate is alive and journals stale recovery" {
        # Zero wait keeps the immediate refusal; the queued wait has its own case.
        $fixture = $null; $priorWait = $env:ITL_DELIVERY_OPERATION_WAIT_SECONDS; $env:ITL_DELIVERY_OPERATION_WAIT_SECONDS = '0'; try {
            $fixture = New-DeliveryFixture; New-Item -ItemType Directory -Force -Path (Join-Path $fixture.root "tests\pester") | Out-Null; Set-Content -LiteralPath (Join-Path $fixture.root "tests\pester\DeliveryRecovery.Tests.ps1") -Encoding UTF8 -Value "Describe 'delivery recovery' { It 'works' { `$true | Should -BeTrue } }"; & git -C $fixture.root add --all; & git -C $fixture.root commit -m "feat: recovery fixture" *> $null; Invoke-DeliveryTestPowerShell -Arguments @("-Action", "RegisterChange", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"')) | Out-Null
            $lockRoot = Join-Path $fixture.root ".git\itl\delivery-operation"; New-Item -ItemType Directory -Force -Path $lockRoot | Out-Null; $acquiring = Invoke-DeliveryTestPowerShell -Arguments @("-Action", "PublishDevelop", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"')) -AllowFailure; $acquiring.exitCode | Should -Not -Be 0; $acquiring.stderr | Should -Match "acquiring the shared lock"; $pesterProcess = Get-Process -Id $PID
            $operation = [ordered]@{ schemaVersion=1; id=[guid]::NewGuid().ToString("N"); action="PublishDevelop"; startedAt=[DateTime]::UtcNow.AddMinutes(-1).ToString("o"); ownerPid=999999; ownerProcessStartedAt=[DateTime]::UtcNow.AddDays(-1).ToString("o"); mode="Develop"; workingRoot=""; gatePid=$PID; gateProcessStartedAt=$pesterProcess.StartTime.ToUniversalTime().ToString("o"); gateStatus="running"; runRecordPath="" }; [IO.File]::WriteAllText((Join-Path $lockRoot "operation.json"), (($operation | ConvertTo-Json -Depth 6) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
            $status = (Invoke-DeliveryTestPowerShell -Arguments @("-Action", "Status", "-RepositoryRoot", ('"' + $fixture.root + '"'))).stdout | ConvertFrom-Json; $status.activeOperation.status | Should -Be "running"; $status.activeOperation.gateAlive | Should -BeTrue; $duplicate = Invoke-DeliveryTestPowerShell -Arguments @("-Action", "PublishDevelop", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"')) -AllowFailure; $duplicate.exitCode | Should -Not -Be 0; $duplicate.stderr | Should -Match "already active"
            $summaryRoot = Join-Path $fixture.root "build\test-results\local"; New-Item -ItemType Directory -Force -Path $summaryRoot | Out-Null; $summaryStarted = [DateTime]::UtcNow.AddSeconds(-2); $summaryFinished = [DateTime]::UtcNow.AddSeconds(-1); $summary = [ordered]@{ mode="Targeted"; status="failed"; startedAt=$summaryStarted.ToString("o"); finishedAt=$summaryFinished.ToString("o"); error="fixture interrupted"; tests=[ordered]@{passed=0;failed=1;skipped=0}; stages=@() }; [IO.File]::WriteAllText((Join-Path $summaryRoot "check-summary.json"), (($summary | ConvertTo-Json -Depth 6) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
            $operation.gatePid = 999998; $operation.gateProcessStartedAt = [DateTime]::UtcNow.AddDays(-1).ToString("o"); $operation.workingRoot = $fixture.root; $operation.mode = "Targeted"; [IO.File]::WriteAllText((Join-Path $lockRoot "operation.json"), (($operation | ConvertTo-Json -Depth 6) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
            $published = Invoke-DeliveryTestPowerShell -Arguments @("-Action", "PublishDevelop", "-RepositoryRoot", ('"' + $fixture.root + '"'), "-GateScript", ('"' + $fixture.gate + '"'), "-ComponentFinalizerScript", ('"' + $fixture.finalizer + '"')); ($published.stdout | ConvertFrom-Json).status | Should -Be "published"; Test-Path -LiteralPath (Join-Path $fixture.root ".git\itl\operations\$($operation.id).json") | Should -BeTrue; $history = ((Invoke-DeliveryTestPowerShell -Arguments @("-Action", "Status", "-RepositoryRoot", ('"' + $fixture.root + '"'))).stdout | ConvertFrom-Json).runHistory; @($history.lastRuns | Where-Object { [string]$_.error -match "Recovered after the delivery wrapper" }).Count | Should -Be 1
        } finally { $env:ITL_DELIVERY_OPERATION_WAIT_SECONDS = $priorWait; Remove-DeliveryFixture -Fixture $fixture }
    }
}

Describe "Queued delivery publishers" {
    BeforeAll {
        . (Join-Path $RepoRoot 'scripts/git-path-list.ps1')
        . (Join-Path $RepoRoot 'scripts/source-delivery-process.ps1')
        . (Join-Path $RepoRoot 'scripts/source-delivery-queue.ps1')
        function Invoke-DeliveryGit { param([string[]]$Arguments, [switch]$AllowFailure); Invoke-RepositoryGit -RepositoryRoot $script:Root -Arguments $Arguments -AllowFailure:$AllowFailure }
        function Get-GitValue { param([string[]]$Arguments); (Invoke-DeliveryGit -Arguments $Arguments).stdout.Trim() }
        function Get-DeliveryCommonGitDirectory { Join-Path $script:Root '.git' }
        function Add-FrozenQueueTask { param([string]$Name)
            Set-Content -LiteralPath (Join-Path $script:Root "$Name.ps1") -Value "'$Name'" -Encoding UTF8
            & git -C $script:Root add --all; & git -C $script:Root commit --quiet -m "test: $Name"
            return (& git -C $script:Root rev-parse HEAD).Trim()
        }
        function Write-QueuedHolder { param([int]$ProcessId, [datetime]$StartedAt)
            $lock = Get-DeliveryOperationLockPath; New-Item -ItemType Directory -Force -Path $lock | Out-Null
            $operation = [ordered]@{ schemaVersion=1; id=[guid]::NewGuid().ToString('N'); action='PublishDevelop'; startedAt=[DateTime]::UtcNow.ToString('o')
                ownerPid=$ProcessId; ownerProcessStartedAt=$StartedAt.ToUniversalTime().ToString('o'); mode='Develop'; workingRoot=''; gatePid=0; gateProcessStartedAt=''; gateStatus='running'; runRecordPath='' }
            [IO.File]::WriteAllText((Join-Path $lock 'operation.json'), ($operation | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
            return $operation.id
        }
    }
    BeforeEach {
        $script:priorWait = $env:ITL_DELIVERY_OPERATION_WAIT_SECONDS
        $script:fixture = New-DeliveryFixture; $script:Root = $script:fixture.root; $script:Remote = 'origin'; $script:QueueRoot = 'refs/itl/develop-queue'
        $script:DeliveryOperationWaitPollSeconds = 1; $script:ActiveOperation = $null
    }
    AfterEach {
        Exit-DeliveryOperation
        $env:ITL_DELIVERY_OPERATION_WAIT_SECONDS = $script:priorWait
        Remove-DeliveryFixture -Fixture $script:fixture
    }

    It "waits for a live publisher instead of failing, then takes the lock it left" {
        $holder = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 4') -WindowStyle Hidden -PassThru
        try {
            $held = Write-QueuedHolder -ProcessId $holder.Id -StartedAt $holder.StartTime
            $operation = Enter-DeliveryOperation -Action PublishDevelop
            $holder.HasExited | Should -BeTrue
            $script:DeliveryOperationWaitedSeconds | Should -BeGreaterThan 0
            $operation.ownerPid | Should -Be $PID
            Test-Path -LiteralPath (Join-Path $script:Root ".git/itl/operations/$held.json") | Should -BeTrue
        } finally { if (-not $holder.HasExited) { $holder.Kill() } }
    }

    It "stops with the active holder after the bounded wait" {
        $env:ITL_DELIVERY_OPERATION_WAIT_SECONDS = '2'
        $null = Write-QueuedHolder -ProcessId $PID -StartedAt (Get-Process -Id $PID).StartTime
        { Enter-DeliveryOperation -Action PublishDevelop } | Should -Throw "*'PublishDevelop' is already active*of the 2s operation wait*"
        Test-Path -LiteralPath (Join-Path (Get-DeliveryOperationLockPath) 'operation.json') | Should -BeTrue
    }

    It "reports success when the run it waited for already published its registrations" {
        $alpha = Add-FrozenQueueTask -Name alpha
        $entries = @([pscustomobject]@{ id='alpha'; base=$script:fixture.base; head=$alpha })
        Get-DevelopQueuePublishedWhileWaiting -Entries $entries -WaitedSeconds 30 | Should -BeNullOrEmpty
        & git -C $script:Root push --quiet origin "$($alpha):refs/heads/develop"
        $done = Get-DevelopQueuePublishedWhileWaiting -Entries $entries -WaitedSeconds 30
        $done.status | Should -Be 'already-published'
        $done.commit | Should -Be $alpha
        @($done.entries.id) | Should -Be @('alpha')
        # A later registration still needs this publisher.
        $beta = Add-FrozenQueueTask -Name beta
        & git -C $script:Root update-ref "refs/itl/develop-queue/beta/base" $alpha
        & git -C $script:Root update-ref "refs/itl/develop-queue/beta/head" $beta
        Get-DevelopQueuePublishedWhileWaiting -Entries $entries -WaitedSeconds 30 | Should -BeNullOrEmpty
    }
}
