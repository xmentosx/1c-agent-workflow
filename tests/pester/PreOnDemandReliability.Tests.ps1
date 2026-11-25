Describe "pre-on-demand runner reliability" {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        $repoRoot = $context.RepoRoot
        . (Join-Path $repoRoot '.agents/skills/1c-workflow/scripts/lib/itl-runner-timeout.ps1')
        . (Join-Path $repoRoot '.agents/skills/1c-workflow/scripts/lib/agent-1c.core.ps1')
        . (Join-Path $repoRoot '.agents/skills/1c-workflow/scripts/lib/agent-1c.sessions.ps1')
        . (Join-Path $repoRoot '.agents/skills/1c-workflow/scripts/lib/agent-1c.vanessa.ps1')
    }

    It "selects a bounded action timeout and respects a Cyrillic project env override" {
        $root = Join-Path ([IO.Path]::GetTempPath()) ("itl timeout путь с пробелом " + [guid]::NewGuid().ToString("N"))
        $oldAction = [Environment]::GetEnvironmentVariable("ITL_RUNNER_INIT_PROJECT_TIMEOUT_SECONDS", "Process")
        $oldGlobal = [Environment]::GetEnvironmentVariable("ITL_RUNNER_OPERATION_TIMEOUT_SECONDS", "Process")
        try {
            New-Item -ItemType Directory -Force -Path $root | Out-Null
            [Environment]::SetEnvironmentVariable("ITL_RUNNER_INIT_PROJECT_TIMEOUT_SECONDS", $null, "Process")
            [Environment]::SetEnvironmentVariable("ITL_RUNNER_OPERATION_TIMEOUT_SECONDS", $null, "Process")
            (Resolve-ItlRunnerTimeout -ProjectRoot $root -Action 'init-project').seconds | Should -Be 14400
            (Resolve-ItlRunnerTimeout -ProjectRoot $root -Action 'sync-master').seconds | Should -Be 14400
            (Resolve-ItlRunnerTimeout -ProjectRoot $root -Action 'check-dev-branch').seconds | Should -Be 3600
            [IO.File]::WriteAllText((Join-Path $root '.dev.env'), "ITL_RUNNER_OPERATION_TIMEOUT_SECONDS=7200`nITL_RUNNER_INIT_PROJECT_TIMEOUT_SECONDS=18000`n", (New-Object Text.UTF8Encoding $false))
            (Resolve-ItlRunnerTimeout -ProjectRoot $root -Action 'init-project').seconds | Should -Be 18000
            (Resolve-ItlRunnerTimeout -ProjectRoot $root -Action 'sync-master').seconds | Should -Be 7200
            (Resolve-ItlRunnerTimeout -ProjectRoot $root -Action 'init-project' -ExplicitSeconds 10).seconds | Should -Be 10
            { Resolve-ItlRunnerTimeout -ProjectRoot $root -Action 'init-project' -ExplicitSeconds 0 } | Should -Throw '*between 1 and 86400*'
            [IO.File]::WriteAllText((Join-Path $root '.dev.env'), "ITL_RUNNER_INIT_PROJECT_TIMEOUT_SECONDS=86401`n", (New-Object Text.UTF8Encoding $false))
            { Resolve-ItlRunnerTimeout -ProjectRoot $root -Action 'init-project' } | Should -Throw '*between 1 and 86400*'
        } finally {
            [Environment]::SetEnvironmentVariable("ITL_RUNNER_INIT_PROJECT_TIMEOUT_SECONDS", $oldAction, "Process")
            [Environment]::SetEnvironmentVariable("ITL_RUNNER_OPERATION_TIMEOUT_SECONDS", $oldGlobal, "Process")
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "reports the exact canonical server target without echoing connection secrets" {
        (Format-OneCExecutionGuardTarget -Kind server -Path 'Srvr="server-one";Ref="main base";') | Should -Be 'server:server-one/main base'
        $display = Format-OneCExecutionGuardTarget -Kind server -Path 'Srvr="server-one";Ref="main base";Pwd="private";'
        $display | Should -Be 'server:<connection details omitted>'
        $display | Should -Not -Match 'private'
    }

    It "keeps terminal status intact while the heartbeat worker runs and cleans its sidecar" {
        $root = Join-Path ([IO.Path]::GetTempPath()) ("itl heartbeat путь с пробелом " + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path $root | Out-Null
            $script:ProjectRoot = $root
            $script:RunStatusPath = Join-Path $root 'status.json'
            $script:Action = 'init-project'
            $running = '{"status":"running","updatedAt":"initial"}'
            [IO.File]::WriteAllText($script:RunStatusPath, $running, (New-Object Text.UTF8Encoding $false))
            & { Set-StrictMode -Version Latest; Invoke-WithRunStatusHeartbeat -IntervalSeconds 1 -Action { $true } } | Should -BeTrue
            Invoke-WithRunStatusHeartbeat -IntervalSeconds 1 -Action {
                Invoke-WithRunStatusHeartbeat -Action {
                    $script:RunStatusHeartbeatDepth | Should -Be 2
                    $Action | Should -Be 'init-project'
                    (Test-Path -LiteralPath ($script:RunStatusPath + '.heartbeat')) | Should -BeTrue
                }
                Start-Sleep -Milliseconds 1300
                [IO.File]::ReadAllText($script:RunStatusPath) | Should -BeExactly $running
                [IO.File]::WriteAllText($script:RunStatusPath, '{"status":"succeeded","updatedAt":"terminal"}', (New-Object Text.UTF8Encoding $false))
                Start-Sleep -Milliseconds 1300
                [IO.File]::ReadAllText($script:RunStatusPath) | Should -Match '"status":"succeeded"'
            }
            (Test-Path -LiteralPath ($script:RunStatusPath + '.heartbeat')) | Should -BeFalse
            $script:RunStatusHeartbeatDepth | Should -Be 0
        } finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'publishes owned status before removing the heartbeat without changing terminal failure fields' {
        $root = Join-Path $TestDrive 'передача heartbeat с пробелом'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $script:ProjectRoot = $root
        $script:RunStatusPath = Join-Path $root 'status.json'
        $original = [ordered]@{ pid = $PID; updatedAt = '2000-01-01T00:00:00Z'; status = 'failed'; exitCode = 7; errorMessage = 'Первичный отказ'; stage = 'check.event-log'; evidence = @{ hash = 'unchanged' } }
        [IO.File]::WriteAllText($script:RunStatusPath, ($original | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
        Mock Remove-Item -ParameterFilter { $LiteralPath -eq ($script:RunStatusPath + '.heartbeat') } {
                $record = [IO.File]::ReadAllText($script:RunStatusPath) | ConvertFrom-Json
                [datetime]$record.updatedAt | Should -BeGreaterThan ([datetime]'2000-01-01')
                $record.status | Should -Be 'failed'
                $record.exitCode | Should -Be 7
                $record.errorMessage | Should -Be 'Первичный отказ'
                $record.stage | Should -Be 'check.event-log'
                $record.evidence.hash | Should -Be 'unchanged'
            [IO.File]::Delete($LiteralPath)
        }
        { Invoke-WithRunStatusHeartbeat -Action { throw 'Первичный отказ' } } | Should -Throw '*Первичный отказ*'
        Should -Invoke Remove-Item -Times 1 -ParameterFilter { $LiteralPath -eq ($script:RunStatusPath + '.heartbeat') }
        Test-Path -LiteralPath ($script:RunStatusPath + '.heartbeat') | Should -BeFalse
    }

    It 'does not refresh a status owned by another process' {
        $script:RunStatusPath = Join-Path $TestDrive 'чужой status.json'
        $original = '{"pid":99999999,"updatedAt":"2000-01-01T00:00:00Z","status":"running"}'
        [IO.File]::WriteAllText($script:RunStatusPath, $original, [Text.UTF8Encoding]::new($false))
        Invoke-WithRunStatusHeartbeat -Action { 'result' } | Should -Be 'result'
        [IO.File]::ReadAllText($script:RunStatusPath) | Should -BeExactly $original
    }

    It 'runs the journal scan through the existing heartbeat owner and preserves its arguments and result' {
        $script:RunStatusPath = Join-Path $TestDrive 'чтение журнала.json'
        $state = [pscustomobject]@{ id = 'same target' }
        $start = [datetime]'2026-07-03T12:00:00'
        $end = $start.AddMinutes(30)
        Mock Read-OneCEventLogDirectCore {
            Test-Path -LiteralPath ($script:RunStatusPath + '.heartbeat') | Should -BeTrue
            $script:RunStatusHeartbeatDepth | Should -Be 1
            [pscustomobject]@{ signature = 'exact event'; comment = 'Ошибка с кириллицей' }
        }
        $events = @(Read-OneCEventLogDirect -State $state -StartTime $start -EndTime $end -Levels @('Error') -SegmentPaths @('журнал с пробелом.lgp') -SegmentSelections @(@{ file = 'same selection' }))
        $events.Count | Should -Be 1
        $events[0].signature | Should -Be 'exact event'
        $events[0].comment | Should -Be 'Ошибка с кириллицей'
        Should -Invoke Read-OneCEventLogDirectCore -Times 1 -ParameterFilter { $State.id -eq 'same target' -and $StartTime -eq $start -and $EndTime -eq $end -and $Levels[0] -eq 'Error' -and $SegmentPaths[0] -eq 'журнал с пробелом.lgp' -and $SegmentSelections[0].file -eq 'same selection' }
        Test-Path -LiteralPath ($script:RunStatusPath + '.heartbeat') | Should -BeFalse
    }

    It "keeps completed phase timing after a later phase fails" {
        $root = Join-Path ([IO.Path]::GetTempPath()) ("itl timings путь с пробелом " + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path $root | Out-Null
            $script:ProjectRoot = $root
            $script:RunStatusPath = Join-Path $root 'status.json'
            $script:Action = 'init-project'
            $script:RunTimingRecords = @()
            $script:RunTimingStage = ''
            $script:RunTimingWriteFailed = $false
            $script:RunTimingImplementationSha256 = ''
            Start-RunPhaseTiming -Stage 'init.fingerprint'
            Set-RunTimingCounter -Name configurationFiles -Value 17
            Start-RunPhaseTiming -Stage 'init.seed'
            Complete-RunPhaseTiming -Outcome failed
            $artifact = Get-Content -LiteralPath (Join-Path $root 'phase-timings.json') -Encoding UTF8 -Raw | ConvertFrom-Json
            $artifact.schemaVersion | Should -Be 1
            $artifact.action | Should -Be 'init-project'
            $artifact.implementationSha256 | Should -Match '^[a-f0-9]{64}$'
            @($artifact.completedPhases).Count | Should -Be 2
            $artifact.completedPhases[0].phase | Should -Be 'init.fingerprint'
            $artifact.completedPhases[0].counters.configurationFiles | Should -Be 17
            $artifact.completedPhases[1].outcome | Should -Be 'failed'
        } finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
