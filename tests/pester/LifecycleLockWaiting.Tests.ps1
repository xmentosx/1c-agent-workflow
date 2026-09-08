Describe 'Lifecycle lock waiting' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        $HelperPath = $context.HelperPath
        $SupportPath = Join-Path $PSScriptRoot 'TestSupport.ps1'
        function Wait-Fixture {
            param([scriptblock]$Probe)
            $deadline = (Get-Date).AddSeconds(25)
            do {
                $value = & $Probe
                if ($value) { return $value }
                Start-Sleep -Milliseconds 100
            } while ((Get-Date) -lt $deadline)
            throw 'Lock fixture did not reach its handshake.'
        }
        function Start-Worker {
            param([string]$Worker, [string[]]$WorkerArguments)
            Start-Job -ScriptBlock {
                param($Support, $Worker, $WorkerArguments)
                . $Support
                $env:LIFECYCLE_LOCK_TIMEOUT_SECONDS = '30'
                Invoke-TestPowerShellFile -FilePath $Worker -Arguments $WorkerArguments
            } -ArgumentList $SupportPath, $Worker, $WorkerArguments
        }
        function Receive-Worker {
            param($Job)
            $Job | Wait-Job -Timeout 40 | Out-Null
            $Job.State | Should -Be Completed
            Receive-Job $Job
        }
        $workerText = @'
param($Helper, $Root, $RequestedAction = 'check-dev-branch')
. $Helper -ProjectRoot $Root -Action help *> $null
$RunStatusPath = Join-Path $Root 'wait-status.json'
Enter-Agent1cLifecycleOperation -RequestedAction $RequestedAction
try { 'ACQUIRED'; Complete-Agent1cLifecycleOperation -Status succeeded -ExitCode 0 }
finally { Exit-Agent1cLifecycleOperation }
'@
    }

    It 'waits for <Resource> without changing the holder and continues automatically' -ForEach @(
        @{ Resource = 'lifecycle' }, @{ Resource = 'runtime-mcp' }
    ) {
        $root = Join-Path $TestDrive "ожидание $Resource"
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        & {
            . $HelperPath -ProjectRoot $root -Action help *> $null
            $lockPath = if ($Resource -eq 'lifecycle') { Get-Agent1cLifecycleLockPath $root } else { Get-Agent1cRuntimeMcpLockPath $root }
            New-Item -ItemType Directory -Force -Path (Split-Path $lockPath) | Out-Null
            $ownerPath = Get-Agent1cLifecycleOperationStatePath $root
            Write-Agent1cLifecycleOperationRecord -Path $ownerPath -Record ([ordered]@{ status='running'; action='fixture-owner'; pid=$PID; phase='working' })
            $originalOwner = [IO.File]::ReadAllText($ownerPath)
            $holder = [IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'Read')
            $worker = Join-Path $root 'worker.ps1'
            Set-Content -LiteralPath $worker -Encoding UTF8 -Value $workerText
            $job = Start-Worker $worker @('-Helper', $HelperPath, '-Root', $root)
            try {
                $waiter = Wait-Fixture { Get-ChildItem -LiteralPath (Join-Path $root '.agent-1c/locks/lifecycle-waiters') -Filter '*.json' -ErrorAction SilentlyContinue | Select-Object -First 1 }
                $first = Read-Agent1cLifecycleOperationRecord $waiter.FullName
                $first.resource | Should -Be $Resource
                $first.owner | Should -Match "activeAction='fixture-owner'"
                [IO.File]::ReadAllText($ownerPath) | Should -BeExactly $originalOwner
                Start-Sleep -Milliseconds 1300
                $second = Read-Agent1cLifecycleOperationRecord $waiter.FullName
                $second.elapsedSeconds | Should -BeGreaterThan $first.elapsedSeconds
                $status = Get-Content -LiteralPath (Join-Path $root 'wait-status.json') -Raw | ConvertFrom-Json
                $status.status | Should -Be running
                $status.liveness | Should -Be 'waiting-lock'
                if ($Resource -eq 'runtime-mcp') { (Test-Agent1cLifecycleLockHeld $root) | Should -BeFalse }
                $holder.Dispose()
                $result = Receive-Worker $job
                $result.exitCode | Should -Be 0 -Because $result.combinedText
                $result.stdout | Should -Match ACQUIRED
                @(Get-ChildItem -LiteralPath $waiter.DirectoryName -Filter '*.json').Count | Should -Be 0
            } finally {
                $holder.Dispose()
                $job | Stop-Job
                $job | Remove-Job -Force
            }
        }
    }

    It 'releases main while refresh waits for a reset branch that still needs a main read' {
        $root = Join-Path $TestDrive 'общий ресурс'
        $main = Join-Path $root 'a main'
        $branch = Join-Path $root 'z ветка'
        New-Item -ItemType Directory -Force -Path $main | Out-Null
        & git -C $main init --quiet
        & git -C $main -c user.name=Test -c user.email=test@example.com commit --allow-empty --quiet -m init
        & git -C $main worktree add --quiet --detach $branch
        & {
            . $HelperPath -ProjectRoot $branch -Action help *> $null
            Enter-Agent1cLifecycleOperation -RequestedAction reset-dev-branch
            $worker = Join-Path $root 'refresh.ps1'
            Set-Content -LiteralPath $worker -Encoding UTF8 -Value $workerText
            $job = Start-Worker $worker @('-Helper', $HelperPath, '-Root', $branch, '-RequestedAction', 'refresh-dev-branch')
            try {
                $null = Wait-Fixture { Get-ChildItem -LiteralPath (Join-Path $branch '.agent-1c/locks/lifecycle-waiters') -Filter '*.json' -ErrorAction SilentlyContinue }
                Invoke-Agent1cMainWorktreeReadScope -TimeoutSeconds 2 -ScriptBlock { 'RESET_READ_FINISHED' } | Should -Be RESET_READ_FINISHED
                Complete-Agent1cLifecycleOperation -Status succeeded -ExitCode 0
                Exit-Agent1cLifecycleOperation
                $result = Receive-Worker $job
                $result.exitCode | Should -Be 0 -Because $result.combinedText
                $result.stdout | Should -Match ACQUIRED
            } finally {
                Exit-Agent1cLifecycleOperation
                $job | Stop-Job
                $job | Remove-Job -Force
            }
        }
    }

    It 'continues refresh in another branch after their common master is released' {
        $root = Join-Path $TestDrive 'две ветки refresh'
        $main = Join-Path $root 'a main'
        $firstBranch = Join-Path $root 'ветка one'
        $secondBranch = Join-Path $root 'ветка two'
        New-Item -ItemType Directory -Force -Path $main | Out-Null
        & git -C $main init --quiet
        & git -C $main -c user.name=Test -c user.email=test@example.com commit --allow-empty --quiet -m init
        & git -C $main worktree add --quiet --detach $firstBranch
        & git -C $main worktree add --quiet --detach $secondBranch
        & {
            . $HelperPath -ProjectRoot $firstBranch -Action help *> $null
            Enter-Agent1cLifecycleOperation -RequestedAction refresh-dev-branch
            $worker = Join-Path $root 'refresh.ps1'
            Set-Content -LiteralPath $worker -Encoding UTF8 -Value $workerText
            $job = Start-Worker $worker @('-Helper', $HelperPath, '-Root', $secondBranch, '-RequestedAction', 'refresh-dev-branch')
            try {
                $file = Wait-Fixture { Get-ChildItem -LiteralPath (Join-Path $secondBranch '.agent-1c/locks/lifecycle-waiters') -Filter '*.json' -ErrorAction SilentlyContinue | Select-Object -First 1 }
                $wait = Read-Agent1cLifecycleOperationRecord $file.FullName
                $wait.worktreePath | Should -Be $main
                $wait.owner | Should -Match "activeAction='refresh-dev-branch'"
                (Test-Agent1cLifecycleLockHeld $secondBranch) | Should -BeFalse
                Complete-Agent1cLifecycleOperation -Status succeeded -ExitCode 0
                Exit-Agent1cLifecycleOperation
                $result = Receive-Worker $job
                $result.exitCode | Should -Be 0 -Because $result.combinedText
                $result.stdout | Should -Match ACQUIRED
            } finally {
                Exit-Agent1cLifecycleOperation
                $job | Stop-Job
                $job | Remove-Job -Force
            }
        }
    }

    It 'honours cancellation through the real compact runner without altering its holder' {
        $root = Join-Path $TestDrive 'отмена runner'
        $scripts = Join-Path $root '.agents/skills/1c-workflow/scripts'
        New-Item -ItemType Directory -Force -Path $scripts | Out-Null
        Copy-Item -LiteralPath $HelperPath -Destination $scripts
        Copy-Item -LiteralPath (Join-Path (Split-Path $HelperPath) 'lib') -Destination $scripts -Recurse
        $runner = Join-Path $scripts 'run-itl-command.ps1'
        Copy-Item -LiteralPath (Join-Path (Split-Path $HelperPath) 'run-itl-command.ps1') -Destination $runner
        & {
            . $HelperPath -ProjectRoot $root -Action help *> $null
            Enter-Agent1cLifecycleOperation -RequestedAction check-dev-branch
            $ownerBefore = [IO.File]::ReadAllText($script:LifecycleOperationStatePath)
            $wrapper = Join-Path $root 'invoke.ps1'
            Set-Content -LiteralPath $wrapper -Encoding UTF8 -Value @'
param($Root, $Runner)
Set-Location -LiteralPath $Root
& $Runner -- -Action check-dev-branch
exit $LASTEXITCODE
'@
            $job = Start-Worker $wrapper @('-Root', $root, '-Runner', $runner)
            try {
                $waiter = Wait-Fixture { Get-ChildItem -LiteralPath (Join-Path $root '.agent-1c/locks/lifecycle-waiters') -Filter '*.json' -ErrorAction SilentlyContinue | Select-Object -First 1 }
                $wait = Read-Agent1cLifecycleOperationRecord $waiter.FullName
                [IO.File]::WriteAllText($wait.cancelPath, '')
                $result = Receive-Worker $job
                $result.exitCode | Should -Be 2 -Because $result.combinedText
                $summary = $result.stdout | ConvertFrom-Json
                $summary.status | Should -Be cancelled
                $summary.error | Should -Match LIFECYCLE_LOCK_WAIT_CANCELLED
                $result.combinedText | Should -Not -Match RUNNER_STATUS_STALE
                [IO.File]::ReadAllText($script:LifecycleOperationStatePath) | Should -BeExactly $ownerBefore
                (Test-Agent1cLifecycleLockHeld $root) | Should -BeTrue
            } finally {
                Complete-Agent1cLifecycleOperation -Status succeeded -ExitCode 0
                Exit-Agent1cLifecycleOperation
                $job | Stop-Job
                $job | Remove-Job -Force
            }
        }
    }

    It 'lets reset finish its main read during the refresh-all worker phase while excluding main writers' {
        $root = Join-Path $TestDrive 'refresh all и reset'
        $main = Join-Path $root 'main база'
        $branch = Join-Path $root 'ветка one'
        New-Item -ItemType Directory -Force -Path $main | Out-Null
        & git -C $main init --quiet
        & git -C $main -c user.name=Test -c user.email=test@example.com commit --allow-empty --quiet -m init
        & git -C $main worktree add --quiet --detach $branch
        & {
            . $HelperPath -ProjectRoot $main -Action help *> $null
            Enter-Agent1cLifecycleOperation -RequestedAction refresh-all-dev-branches
            $worker = Join-Path $root 'reset.ps1'
            Set-Content -LiteralPath $worker -Encoding UTF8 -Value @'
param($Helper, $Root)
. $Helper -ProjectRoot $Root -Action help *> $null
Enter-Agent1cLifecycleOperation -RequestedAction reset-dev-branch
try {
    Invoke-Agent1cMainWorktreeReadScope -ScriptBlock { 'RESET_READ_FINISHED' }
    Complete-Agent1cLifecycleOperation -Status succeeded -ExitCode 0
} finally { Exit-Agent1cLifecycleOperation }
'@
            $job = Start-Worker $worker @('-Helper', $HelperPath, '-Root', $branch)
            try {
                $null = Wait-Fixture { Get-ChildItem -LiteralPath (Join-Path $branch '.agent-1c/locks/lifecycle-waiters') -Filter '*.json' -ErrorAction SilentlyContinue }
                Enter-Agent1cMainReadPhase
                $result = Receive-Worker $job
                $result.exitCode | Should -Be 0 -Because $result.combinedText
                $result.stdout | Should -Match RESET_READ_FINISHED
                (Test-Agent1cLifecycleLockHeld $main) | Should -BeTrue
                $request = { [pscustomobject]@{ worktreePath=$main; lockPath=(Get-Agent1cLifecycleLockPath $main); share=[IO.FileShare]::Read; kind='lifecycle' } }
                { Wait-Agent1cLockSet -RequestedAction sync-master -TimeoutSeconds 0 -GetRequests $request } | Should -Throw '*LIFECYCLE_LOCK_WAIT_TIMEOUT*'
                $record = Read-Agent1cLifecycleOperationRecord $script:LifecycleOperationStatePath
                $record.action | Should -Be refresh-all-dev-branches
                $record.status | Should -Be running
            } finally {
                Complete-Agent1cLifecycleOperation -Status succeeded -ExitCode 0
                Exit-Agent1cLifecycleOperation
                $job | Stop-Job
                $job | Remove-Job -Force
            }
        }
    }

    It 'checks current inputs after waiting when <InputKind> changed' -ForEach @(
        @{ InputKind='config' }, @{ InputKind='environment' }
    ) {
        $root = Join-Path $TestDrive "новые данные $InputKind"
        $scripts = Join-Path $root 'scripts'
        New-Item -ItemType Directory -Force -Path $scripts | Out-Null
        Copy-Item -LiteralPath $HelperPath -Destination $scripts
        Copy-Item -LiteralPath (Join-Path (Split-Path $HelperPath) 'lib') -Destination $scripts -Recurse
        # Keep real entrypoint/admission/config loading; substitute only the
        # post-admission action so this regression never launches a real 1C base.
        Add-Content -LiteralPath (Join-Path $scripts 'lib/agent-1c.ai-rules-migration.ps1') -Encoding UTF8 -Value @'
function Check-DevBranch {
    if ((Get-ConfigValue -Path 'fixtureTarget') -ne 'current') { throw 'STALE_CONFIG' }
    Write-Output 'CURRENT_CONFIG'
}
'@
        & {
            . $HelperPath -ProjectRoot $root -Action help *> $null
            Enter-Agent1cLifecycleOperation -RequestedAction check-dev-branch
            $config = Join-Path $root '.agent-1c/project.json'
            [IO.File]::WriteAllText($config, '{"fixtureTarget":"old"}')
            $job = Start-Worker (Join-Path $scripts 'agent-1c.ps1') @('-ProjectRoot', $root, '-Action', 'check-dev-branch')
            try {
                $null = Wait-Fixture { Get-ChildItem -LiteralPath (Join-Path $root '.agent-1c/locks/lifecycle-waiters') -Filter '*.json' -ErrorAction SilentlyContinue }
                [IO.File]::WriteAllText($config, '{"fixtureTarget":"current"}')
                if ($InputKind -eq 'environment') { [IO.File]::WriteAllText((Join-Path $root '.dev.env'), 'FIXTURE_TARGET=changed') }
                Complete-Agent1cLifecycleOperation -Status succeeded -ExitCode 0
                Exit-Agent1cLifecycleOperation
                $result = Receive-Worker $job
                if ($InputKind -eq 'config') {
                    $result.exitCode | Should -Be 0 -Because $result.combinedText
                    $result.stdout | Should -Match CURRENT_CONFIG
                } else {
                    $result.exitCode | Should -Be 1
                    $result.combinedText | Should -Match LIFECYCLE_INPUT_CHANGED
                    $result.stdout | Should -Not -Match CURRENT_CONFIG
                }
            } finally {
                Exit-Agent1cLifecycleOperation
                $job | Stop-Job
                $job | Remove-Job -Force
            }
        }
    }

    It 'validates timeout configuration and allows explicit non-waiting admission' {
        & {
            . $HelperPath -ProjectRoot $TestDrive -Action help *> $null
            $previous = $env:LIFECYCLE_LOCK_TIMEOUT_SECONDS
            try {
                $env:LIFECYCLE_LOCK_TIMEOUT_SECONDS = $null
                Get-Agent1cLockWaitTimeoutSeconds | Should -Be 3600
                $script:Config = [pscustomobject]@{ lifecycleLockTimeoutSeconds = 17 }
                Get-Agent1cLockWaitTimeoutSeconds | Should -Be 17
                $env:LIFECYCLE_LOCK_TIMEOUT_SECONDS = '0'
                Get-Agent1cLockWaitTimeoutSeconds | Should -Be 0
                foreach ($invalid in @('-1', '86401', 'forever')) {
                    $env:LIFECYCLE_LOCK_TIMEOUT_SECONDS = $invalid
                    { Get-Agent1cLockWaitTimeoutSeconds } | Should -Throw '*integer between 0 and 86400*'
                }
            } finally { $env:LIFECYCLE_LOCK_TIMEOUT_SECONDS = $previous }
        }
    }

    It 'times out contention but fails immediately for an invalid lock path' {
        $root = Join-Path $TestDrive 'таймаут ресурс'
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        & {
            . $HelperPath -ProjectRoot $root -Action help *> $null
            $lockPath = Join-Path $root 'held.lock'
            $holder = [IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'Read')
            $request = { [pscustomobject]@{ worktreePath=$root; lockPath=$lockPath; share=[IO.FileShare]::Read; kind='lifecycle' } }
            try {
                $clock = [Diagnostics.Stopwatch]::StartNew()
                { Wait-Agent1cLockSet -RequestedAction check-dev-branch -TimeoutSeconds 1 -GetRequests $request } | Should -Throw '*LIFECYCLE_LOCK_WAIT_TIMEOUT*'
                $clock.Elapsed.TotalSeconds | Should -BeGreaterOrEqual 1
                $clock.Elapsed.TotalSeconds | Should -BeLessThan 10
            } finally { $holder.Dispose() }
            $lockPath = Join-Path $root 'absent/parent/lock'
            $clock.Restart()
            try {
                Wait-Agent1cLockSet -RequestedAction check-dev-branch -TimeoutSeconds 30 -GetRequests $request
                throw 'Invalid path unexpectedly admitted'
            } catch [IO.DirectoryNotFoundException] { }
            $clock.Elapsed.TotalSeconds | Should -BeLessThan 5
            $lockPath = $root
            $clock.Restart()
            try {
                Wait-Agent1cLockSet -RequestedAction check-dev-branch -TimeoutSeconds 30 -GetRequests $request
                throw 'Directory unexpectedly admitted for writing'
            } catch [UnauthorizedAccessException] { }
            $clock.Elapsed.TotalSeconds | Should -BeLessThan 5
            @(Get-ChildItem -LiteralPath (Join-Path $root '.agent-1c/locks/lifecycle-waiters') -Filter '*.json' -ErrorAction SilentlyContinue).Count | Should -Be 0
        }
    }
}
