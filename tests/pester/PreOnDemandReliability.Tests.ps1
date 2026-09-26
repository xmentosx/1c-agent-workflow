Describe "pre-on-demand runner reliability" {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        $repoRoot = $context.RepoRoot
        . (Join-Path $repoRoot '.agents/skills/1c-workflow/scripts/lib/itl-runner-timeout.ps1')
        . (Join-Path $repoRoot '.agents/skills/1c-workflow/scripts/lib/agent-1c.core.ps1')
        . (Join-Path $repoRoot '.agents/skills/1c-workflow/scripts/lib/agent-1c.sessions.ps1')
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

    It "keeps the monitored owner PID through a validated helper continuation" {
        $root = Join-Path ([IO.Path]::GetTempPath()) ("itl reexec путь с пробелом " + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path $root | Out-Null
            $script:ProjectRoot = $root
            $script:RunStatusPath = Join-Path $root 'status.json'
            $script:RunLogPath = ''
            $script:Action = 'update-workflow'
            $script:RunStartedAt = Get-Date
            $script:RunStage = 'workflow-update.commit'
            $script:RunStageDetail = 'Verifying the managed commit'
            # The full helper entrypoint normally initializes these status fields.
            $statusFields = [regex]::Matches((Get-Command Write-RunStatus).ScriptBlock.ToString(), '\$script:([A-Za-z][A-Za-z0-9_]*)') |
                ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique
            foreach ($field in $statusFields) {
                if (-not (Get-Variable -Name $field -Scope Script -ErrorAction SilentlyContinue)) {
                    Set-Variable -Name $field -Scope Script -Value $null
                }
            }
            $script:LifecycleOperationIsContinuation = $true
            $script:LifecycleOperationOwnerPid = $PID + 100000
            $script:LifecycleOperationRecord = [ordered]@{
                pid = $script:LifecycleOperationOwnerPid
                continuationPid = $PID
            }

            Write-RunStatus -Status running
            $status = Get-Content -LiteralPath $script:RunStatusPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $status.pid | Should -Be $script:LifecycleOperationOwnerPid
            Invoke-WithRunStatusHeartbeat -IntervalSeconds 1 -Action {
                [IO.File]::ReadAllText(($script:RunStatusPath + '.heartbeat'),[Text.Encoding]::ASCII) | Should -BeExactly ([string]$script:LifecycleOperationOwnerPid)
            }

            $script:LifecycleOperationRecord['continuationPid'] = $PID + 1
            Get-RunStatusMonitorPid | Should -Be $PID
        } finally {
            $script:LifecycleOperationIsContinuation = $false
            $script:LifecycleOperationOwnerPid = 0
            $script:LifecycleOperationRecord = $null
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
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
