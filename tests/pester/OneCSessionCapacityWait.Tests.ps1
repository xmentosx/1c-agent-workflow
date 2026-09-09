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
            throw (New-OneCSessionCapacityError -Waitable -Message 'ITL_ONEC_SESSION_LIMIT: max=1 active=1')
        }
        {
            Invoke-WithOneCSessionAdmissionContext -InfoBaseKind file -InfoBasePath $basePath -SessionWaitTimeoutSeconds 0.05 -ScriptBlock {
                Invoke-OneCSessionProcessStart -StartProcess { $script:NativeStarts++ }
            }
        } | Should -Throw '*ITL_ONEC_SESSION_LIMIT*active=1*'
        $script:NativeStarts | Should -Be 0
        Should -Invoke Stop-OneCInfoBaseSessionProcesses -Times 0 -Exactly
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

    It 'does not launch if the phase expires while admission is being inspected' {
        Mock Invoke-OneCSessionAdmissionSet { param($Admissions, $StartProcess) Start-Sleep -Milliseconds 40; & $StartProcess }
        $deadline = [long]([decimal][Diagnostics.Stopwatch]::GetTimestamp() * 1000000000 / [Diagnostics.Stopwatch]::Frequency) + 10000000
        {
            Invoke-WithOneCSessionAdmissionContext -InfoBaseKind file -InfoBasePath $basePath -SessionWaitTimeoutSeconds 10 -SessionDeadlineMonotonicNs $deadline -ScriptBlock {
                Invoke-OneCSessionProcessStart -StartProcess { $script:NativeStarts++ }
            }
        } | Should -Throw '*ITL_ONEC_SESSION_WAIT_TIMEOUT*'
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
