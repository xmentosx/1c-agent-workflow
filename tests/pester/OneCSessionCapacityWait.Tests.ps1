Describe 'Session capacity waits without stopping or replaying another operation' {
    BeforeAll {
        $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $lib = Join-Path $repo '.agents/skills/1c-workflow/scripts/lib'
        . (Join-Path $lib 'agent-1c.core.ps1')
        . (Join-Path $lib 'agent-1c.runtime-values.ps1')
        . (Join-Path $lib 'agent-1c.sessions.ps1')
    }
    BeforeEach {
        $script:AdmissionAttempts = 0
        $script:NativeStarts = 0
        $script:OneCSessionLaunchContext = $null
        $script:cancelFile = Join-Path $TestDrive 'Отмена ожидания.json'
        $script:basePath = Join-Path $TestDrive 'База с пробелом'
        Mock Remove-OneCSessionReservation {}
        Mock Stop-OneCInfoBaseSessionProcesses { throw 'foreign sessions must remain untouched' }
        Mock Stop-NativeProcessForSafety { throw 'no process was started by this operation' }
    }

    It 'retries only prelaunch capacity rejection and starts exactly once after capacity changes' {
        Mock Invoke-OneCSessionAdmissionSet {
            param($Admissions, $StartProcess)
            $script:AdmissionAttempts++
            if ($script:AdmissionAttempts -lt 3) {
                throw (New-OneCSessionCapacityError -Waitable -Message 'ITL_ONEC_SESSION_LIMIT: existing foreign client')
            }
            & $StartProcess
        }
        $started = Invoke-WithOneCSessionAdmissionContext -InfoBaseKind file -InfoBasePath $basePath -SessionWaitTimeoutSeconds 2 -ScriptBlock {
            Invoke-OneCSessionProcessStart -StartProcess { $script:NativeStarts++; [pscustomobject]@{Id=1001} }
        }
        $started.Id | Should -Be 1001
        $script:AdmissionAttempts | Should -Be 3
        $script:NativeStarts | Should -Be 1
        Should -Invoke Stop-OneCInfoBaseSessionProcesses -Times 0 -Exactly
        Should -Invoke Stop-NativeProcessForSafety -Times 0 -Exactly
    }

    It 'retains the capacity error after a bounded wait and never launches' {
        Mock Invoke-OneCSessionAdmissionSet {
            $script:AdmissionAttempts++
            throw (New-OneCSessionCapacityError -Waitable -Message 'ITL_ONEC_SESSION_LIMIT: max=1 active=1')
        }
        $admissions = @([pscustomobject]@{infoBaseKind='file';infoBasePath=$basePath;requiredSessions=1;expectedChildRole='';purpose='1c-process'})
        # Establish admission before measuring the separate 50 ms capacity wait.
        Invoke-WithOneCExecutionGuard -Admissions $admissions -Purpose '1c-process' -WaitTimeoutSeconds 10 -ScriptBlock {
            {
                Invoke-WithOneCSessionAdmissionContext -InfoBaseKind file -InfoBasePath $basePath -SessionWaitTimeoutSeconds 0.05 -ScriptBlock {
                    Invoke-OneCSessionProcessStart -StartProcess { $script:NativeStarts++ }
                }
            } | Should -Throw '*ITL_ONEC_SESSION_LIMIT*active=1*'
        }
        $script:AdmissionAttempts | Should -BeGreaterThan 0
        $script:NativeStarts | Should -Be 0
        Should -Invoke Stop-OneCInfoBaseSessionProcesses -Times 0 -Exactly
        Should -Invoke Stop-NativeProcessForSafety -Times 0 -Exactly
    }

    It 'reports the execution guard timeout before capacity is inspected and never launches' {
        Mock Invoke-OneCSessionAdmissionSet {
            $script:AdmissionAttempts++
            throw (New-OneCSessionCapacityError -Waitable -Message 'ITL_ONEC_SESSION_LIMIT: max=1 active=1')
        }
        . (Join-Path $repo '.agents/skills/itl-remote-runner/scripts/ExecutionGuard.ps1')
        $admissions = @([pscustomobject]@{infoBaseKind='file';infoBasePath=$basePath;requiredSessions=1;expectedChildRole='';purpose='1c-process'})
        $settings = Get-OneCExecutionGuardSettings
        $request = [ordered]@{schemaVersion=1;root=$settings.root;bases=@(ConvertTo-OneCExecutionGuardBases -Admissions $admissions);
            operation='1c-process';executionId=[guid]::NewGuid().ToString('N');timeout=10;cancelPath='';phaseDeadline=$null}
        $holder = $null
        try {
            # A separate owner holds the same resource without granting inherited admission.
            $holder = Start-ItlExecutionGuardHost -Request $request -Python $settings.python
            {
                Invoke-WithOneCSessionAdmissionContext -InfoBaseKind file -InfoBasePath $basePath -SessionWaitTimeoutSeconds 0.05 -ScriptBlock {
                    Invoke-OneCSessionProcessStart -StartProcess { $script:NativeStarts++ }
                }
            } | Should -Throw '*EXECUTION_GUARD_WAIT_TIMEOUT*'
        } finally {
            if ($null -ne $holder) { Complete-ItlExecutionGuardHost -Owner $holder -Result succeeded -ErrorMessage '' | Out-Null }
        }
        $script:AdmissionAttempts | Should -Be 0
        $script:NativeStarts | Should -Be 0
        Should -Invoke Stop-OneCInfoBaseSessionProcesses -Times 0 -Exactly
        Should -Invoke Stop-NativeProcessForSafety -Times 0 -Exactly
    }

    It 'observes cancellation while capacity is occupied without touching its owner' {
        Mock Invoke-OneCSessionAdmissionSet {
            Set-Content -LiteralPath $script:cancelFile -Value '{}'
            throw (New-OneCSessionCapacityError -Waitable -Message 'ITL_ONEC_SESSION_LIMIT: foreign owner')
        }
        {
            Invoke-WithOneCSessionAdmissionContext -InfoBaseKind file -InfoBasePath $basePath -SessionWaitTimeoutSeconds 2 -SessionCancelPath $cancelFile -ScriptBlock {
                Invoke-OneCSessionProcessStart -StartProcess { $script:NativeStarts++ }
            }
        } | Should -Throw '*CANCELLED*'
        $script:NativeStarts | Should -Be 0
        Should -Invoke Stop-OneCInfoBaseSessionProcesses -Times 0 -Exactly
    }

    It 'does not wait on impossible capacity or retry a native failure disguised as capacity' {
        Mock Invoke-OneCSessionAdmissionSet {
            throw (New-OneCSessionCapacityError -Message 'ITL_ONEC_SESSION_LIMIT: required exceeds configured maximum')
        }
        {
            Invoke-WithOneCSessionAdmissionContext -InfoBaseKind file -InfoBasePath $basePath -SessionWaitTimeoutSeconds 10 -ScriptBlock {
                Invoke-OneCSessionProcessStart -StartProcess { $script:NativeStarts++ }
            }
        } | Should -Throw '*required exceeds*'
        Should -Invoke Invoke-OneCSessionAdmissionSet -Times 1 -Exactly
        Mock Invoke-OneCSessionAdmissionSet { param($Admissions, $StartProcess) & $StartProcess }
        {
            Invoke-WithOneCSessionAdmissionContext -InfoBaseKind file -InfoBasePath $basePath -SessionWaitTimeoutSeconds 10 -ScriptBlock {
                Invoke-OneCSessionProcessStart -StartProcess {
                    $script:NativeStarts++
                    throw (New-OneCSessionCapacityError -Waitable -Message 'ITL_ONEC_SESSION_LIMIT: native outcome unknown')
                }
            }
        } | Should -Throw '*native outcome unknown*'
        $script:NativeStarts | Should -Be 1
        Should -Invoke Invoke-OneCSessionAdmissionSet -Times 2 -Exactly
    }

    It 'does not launch if the execution phase expires while admission is being inspected' {
        Mock Invoke-OneCSessionAdmissionSet { param($Admissions, $StartProcess) Start-Sleep -Milliseconds 40; & $StartProcess }
        $deadline = [long]([decimal][Diagnostics.Stopwatch]::GetTimestamp() * 1000000000 / [Diagnostics.Stopwatch]::Frequency) + 10000000
        {
            Invoke-WithOneCSessionAdmissionContext -InfoBaseKind file -InfoBasePath $basePath -SessionWaitTimeoutSeconds 10 -SessionDeadlineMonotonicNs $deadline -ScriptBlock {
                Invoke-OneCSessionProcessStart -StartProcess { $script:NativeStarts++ }
            }
        } | Should -Throw '*EXECUTION_GUARD_PHASE_DEADLINE_EXPIRED*'
        $script:NativeStarts | Should -Be 0
    }

    It 'preserves the originating phase deadline and cancellation path in nested waits' {
        $path = Join-Path $TestDrive 'Контекст замера.json'
        $deadline = [long]([decimal][Diagnostics.Stopwatch]::GetTimestamp() * 1000000000 / [Diagnostics.Stopwatch]::Frequency) + 60000000000
        $record = @{cancelPath=$cancelFile;phase=@{executionHost=[Environment]::MachineName.ToLowerInvariant();timeoutSeconds=1800;deadlineMonotonicNs=$deadline}}
        Write-Utf8Text -Path $path -Value ($record | ConvertTo-Json)
        $options = Get-OneCSessionWaitParameters -ContextPath $path
        $options.SessionWaitTimeoutSeconds | Should -Be 1800
        $options.SessionDeadlineMonotonicNs | Should -Be $deadline
        $options.SessionCancelPath | Should -Be $cancelFile
        $record.phase.executionHost = 'another-host'
        Write-Utf8Text -Path $path -Value ($record | ConvertTo-Json)
        { Get-OneCSessionWaitParameters -ContextPath $path } | Should -Throw '*FOREIGN_PHASE_DEADLINE_HOST*'
    }

    It 'forbids combining waiting with a destructive recovery callback' {
        {
            Invoke-WithOneCSessionAdmissionContext -InfoBaseKind file -InfoBasePath $basePath -SessionWaitTimeoutSeconds 1 -SessionLimitRecovery { throw 'must not run' } -ScriptBlock { throw 'must not run' }
        } | Should -Throw '*waiting cannot invoke destructive*'
    }

    It 'releases an exited single-process reservation while retaining a promised TestClient slot' {
        Mock Test-OneCSessionProcessIdentityPresent { param($ProcessId, $ProcessStartTime) $ProcessId -eq 900 }
        $single = [pscustomobject]@{id='single';machine=[Environment]::MachineName;ownerPid=900;leaderPid=901;
            infoBaseKey='base';requiredSessions=1;expectedChildRole='';initialProcessIds=@();createdAt='2026-09-09T00:00:00Z'}
        $future = [pscustomobject]@{id='future';machine=[Environment]::MachineName;ownerPid=900;leaderPid=902;
            infoBaseKey='base';requiredSessions=1;expectedChildRole='test-client';initialProcessIds=@();createdAt='2026-09-09T00:00:01Z'}
        $result=Get-OneCSessionReservationSnapshot -Registry ([pscustomobject]@{reservations=@($single,$future)}) -InfoBaseIdentity ([pscustomobject]@{key='base'}) -Processes @()
        $result.pending | Should -Be 1
        @($result.reservations).Count | Should -Be 1
        $result.reservations[0].id | Should -Be 'future'
    }
}

Describe 'Branch holder release stops only this worktree''s own guard holders' {
    BeforeAll {
        $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $lib = Join-Path $repo '.agents/skills/1c-workflow/scripts/lib'
        . (Join-Path $lib 'agent-1c.core.ps1')
        . (Join-Path $lib 'agent-1c.runtime-values.ps1')
        . (Join-Path $lib 'agent-1c.sessions.ps1')
        . (Join-Path $repo '.agents/skills/itl-remote-runner/scripts/ExecutionGuard.ps1')
        $script:HolderScript = Join-Path $TestDrive 'держатель guard.ps1'
        @'
param([string]$Repository, [string]$RequestPath, [string]$ReadyPath)
$ErrorActionPreference = 'Stop'
. (Join-Path $Repository '.agents/skills/1c-workflow/scripts/lib/agent-1c.core.ps1')
. (Join-Path $Repository '.agents/skills/itl-remote-runner/scripts/ExecutionGuard.ps1')
$request = [IO.File]::ReadAllText($RequestPath, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
$owner = Start-ItlExecutionGuardHost -Request $request
[IO.File]::WriteAllText($ReadyPath, [string]$owner.process.Id)
Start-Sleep -Seconds 120
'@ | Set-Content -LiteralPath $script:HolderScript -Encoding UTF8
        function Start-TestBranchHolder {
            param([string]$ProjectRoot, [string]$HolderState, [object[]]$Bases)
            $id = [guid]::NewGuid().ToString('N')
            $requestPath = Join-Path $TestDrive "запрос $id.json"
            $readyPath = Join-Path $TestDrive "готов $id.txt"
            $request = [ordered]@{schemaVersion=1;root=(Get-OneCExecutionGuardSettings).root;bases=@($Bases);operation='ondemand-roctup-call'
                executionId=$id;timeout=30;projectRoot=$ProjectRoot;holderState=$HolderState}
            [IO.File]::WriteAllText($requestPath, ($request | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
            $arguments = Join-NativeCommandLineArguments -Arguments @('-NoProfile','-ExecutionPolicy','Bypass','-File',$script:HolderScript,$repo,$requestPath,$readyPath)
            $process = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $arguments -WindowStyle Hidden -PassThru
            $watch = [Diagnostics.Stopwatch]::StartNew()
            while (-not (Test-Path -LiteralPath $readyPath) -and $watch.Elapsed.TotalSeconds -lt 60 -and -not $process.HasExited) { Start-Sleep -Milliseconds 100 }
            if (-not (Test-Path -LiteralPath $readyPath)) { throw 'test holder was not admitted' }
            return [pscustomobject]@{process=$process;supervisor=[int](Get-Content -LiteralPath $readyPath -Raw)}
        }
    }
    BeforeEach {
        $script:previousGuardRoot = $env:ITL_EXECUTION_GUARD_ROOT
        $env:ITL_EXECUTION_GUARD_ROOT = Join-Path $TestDrive ('корень guard ' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $script:ProjectRoot = Join-Path $TestDrive 'Рабочая копия ветки'
        $script:basePath = Join-Path $TestDrive 'База ветки с пробелом'
        $script:holders = @()
    }
    AfterEach {
        foreach ($holder in $script:holders) { if (-not $holder.process.HasExited) { Stop-Process -Id $holder.process.Id -Force -ErrorAction SilentlyContinue } }
        $env:ITL_EXECUTION_GUARD_ROOT = $script:previousGuardRoot
    }

    It 'classifies holders by worktree evidence and never stops a mutating Designer, a shared base or this command' {
        $root = 'C:\Проекты\Ветка с пробелом'
        $created = [datetime]'2026-11-09T10:00:00'
        $facade = [pscustomobject]@{ProcessId=10;ParentProcessId=1;Name='itl-ondemand-mcp.exe';CommandLine="itl-ondemand-mcp.exe serve --project-root `"$root`"";CreationDate=$created}
        $host1 = [pscustomobject]@{ProcessId=11;ParentProcessId=10;Name='python.exe';CommandLine='python -m itl_remote.execution_guard_host';CreationDate=$created.AddSeconds(1)}
        $helper = [pscustomobject]@{ProcessId=20;ParentProcessId=1;Name='powershell.exe';CommandLine="powershell -File agent-1c.ps1 -Action check-dev-branch -ProjectRoot `"$root`"";CreationDate=$created}
        $host2 = [pscustomobject]@{ProcessId=21;ParentProcessId=20;Name='python.exe';CommandLine='python -m itl_remote.execution_guard_host';CreationDate=$created.AddSeconds(1)}
        $client = [pscustomobject]@{ProcessId=22;ParentProcessId=20;Name='1cv8c.exe';CommandLine='1cv8c.exe ENTERPRISE /F base';CreationDate=$created.AddSeconds(2)}
        $designer = [pscustomobject]@{ProcessId=23;ParentProcessId=20;Name='1cv8.exe';CommandLine='1cv8.exe DESIGNER /F base /LoadConfigFromFiles src';CreationDate=$created.AddSeconds(2)}
        $live = @{alive=$true;state='running';touchesShared=$false;projectRoot='';holderState=''}
        $legacy = [pscustomobject](@{pid=11} + $live)
        $class = Get-ItlExecutionGuardHolderClass -Holder $legacy -ProjectRoot $root -Processes @($facade,$host1) -CurrentProcessId 999
        $class.class | Should -Be 'this-worktree'
        $class.stopRoot | Should -Be 11
        @($class.stopProcesses.ProcessId) | Should -Be @(11)
        (Get-ItlExecutionGuardHolderClass -Holder $legacy -ProjectRoot 'C:\Проекты\Другая' -Processes @($facade,$host1) -CurrentProcessId 999).class | Should -Be 'other-worktree'
        (Get-ItlExecutionGuardHolderClass -Holder $legacy -ProjectRoot $root -Processes @($host1) -CurrentProcessId 999).class | Should -Be 'unproven'
        $shared = [pscustomobject](@{pid=11} + $live); $shared.touchesShared = $true
        (Get-ItlExecutionGuardHolderClass -Holder $shared -ProjectRoot $root -Processes @($facade,$host1) -CurrentProcessId 999).class | Should -Be 'shared-resource'
        $helperHolder = [pscustomobject](@{pid=21} + $live); $helperHolder.projectRoot = $root
        $class = Get-ItlExecutionGuardHolderClass -Holder $helperHolder -ProjectRoot $root -Processes @($helper,$host2,$client) -CurrentProcessId 999
        $class.class | Should -Be 'this-worktree'
        $class.stopRoot | Should -Be 20
        @($class.stopProcesses.ProcessId | Sort-Object) | Should -Be @(20,21,22)
        (Get-ItlExecutionGuardHolderClass -Holder $helperHolder -ProjectRoot $root -Processes @($helper,$host2,$client,$designer) -CurrentProcessId 999).class | Should -Be 'mutating-designer'
        (Get-ItlExecutionGuardHolderClass -Holder $helperHolder -ProjectRoot $root -Processes @($helper,$host2,$client) -CurrentProcessId 22).class | Should -Be 'self'
        $dead = [pscustomobject](@{pid=11} + $live); $dead.alive = $false
        (Get-ItlExecutionGuardHolderClass -Holder $dead -ProjectRoot $root -Processes @() -CurrentProcessId 999).class | Should -Be 'stale'
        $queued = [pscustomobject](@{pid=11} + $live); $queued.state = 'waiting'
        (Get-ItlExecutionGuardHolderClass -Holder $queued -ProjectRoot $root -Processes @() -CurrentProcessId 999).class | Should -Be 'queued'
    }

    It 'lets a waiting command release an idle same-worktree holder and then admits it' {
        $bases = @([pscustomobject]@{kind='file';path=(Resolve-Agent1cFullPath -Path $basePath)})
        $holder = Start-TestBranchHolder -ProjectRoot $script:ProjectRoot -HolderState 'cleanup-unconfirmed' -Bases $bases
        $script:holders += $holder
        $admissions = @([pscustomobject]@{infoBaseKind='file';infoBasePath=$basePath})
        $ran = Invoke-WithOneCExecutionGuard -Admissions $admissions -Purpose 'check-dev-branch' -WaitTimeoutSeconds 30 -ScriptBlock { 'admitted' }
        $ran | Should -Be 'admitted'
        Get-Process -Id $holder.supervisor -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }

    It 'waits for an active same-worktree holder, routes to repair, and repair releases it' {
        $bases = @([pscustomobject]@{kind='file';path=(Resolve-Agent1cFullPath -Path $basePath)})
        $holder = Start-TestBranchHolder -ProjectRoot $script:ProjectRoot -HolderState 'active-native-call' -Bases $bases
        $script:holders += $holder
        $foreign = Start-TestBranchHolder -ProjectRoot (Join-Path $TestDrive 'Другая копия') -HolderState 'cleanup-unconfirmed' -Bases @([pscustomobject]@{kind='file';path=(Resolve-Agent1cFullPath -Path (Join-Path $TestDrive 'Чужая база'))})
        $script:holders += $foreign
        $admissions = @([pscustomobject]@{infoBaseKind='file';infoBasePath=$basePath})
        { Invoke-WithOneCExecutionGuard -Admissions $admissions -Purpose 'check-dev-branch' -WaitTimeoutSeconds 7 -ScriptBlock { 'must not run' } } |
            Should -Throw '*EXECUTION_GUARD_BRANCH_HOLDER_RETAINED*repair-dev-branch-tooling*active-native-call*'
        Get-Process -Id $holder.supervisor -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        $script:RunErrorCategory = ''; $script:RunRequiredAction = ''
        Set-RunFailureContextFromMessage -Message 'EXECUTION_GUARD_BRANCH_HOLDER_RETAINED: holder'
        $script:RunRequiredAction | Should -Be 'repair-dev-branch-tooling'
        $release = Invoke-ItlBranchHolderRelease -Bases ($bases + @([pscustomobject]@{kind='file';path=(Resolve-Agent1cFullPath -Path (Join-Path $TestDrive 'Чужая база'))})) -Mode repair
        @($release.released.executionId).Count | Should -Be 1
        @($release.preserved | Where-Object class -eq 'other-worktree').Count | Should -Be 1
        Get-Process -Id $holder.supervisor -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        Get-Process -Id $foreign.supervisor -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Invoke-WithOneCExecutionGuard -Admissions $admissions -Purpose 'check-dev-branch' -WaitTimeoutSeconds 10 -ScriptBlock { 'admitted' } | Should -Be 'admitted'
    }
}
