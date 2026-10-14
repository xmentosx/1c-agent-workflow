BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSupport.ps1')
    $context=Initialize-WorkflowPesterContext
    . $context.HelperPath -ProjectRoot $context.RepoRoot -Action help *> $null
    $actualOwnershipProof=(Get-Command Get-ItlOnDemandProcessOwnershipProof).ScriptBlock
}

Describe 'Retained on-demand launch evidence recovery' {
    BeforeEach {
        $script:savedRoot=$script:ProjectRoot
        $script:savedContext=$env:ITL_EXECUTION_CONTEXT
        $script:savedKey=$env:ITL_EXECUTION_CONTEXT_KEY
        $script:ProjectRoot=Join-Path $TestDrive ('Проект с пробелом '+[guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $script:ProjectRoot | Out-Null
        $env:ITL_EXECUTION_CONTEXT='live-owner'
        $env:ITL_EXECUTION_CONTEXT_KEY='live-key'
        $script:sequence=[Collections.Generic.List[string]]::new()
        $script:runtimePath=Join-Path $script:ProjectRoot 'missing.json'
        $script:started=[datetime]'2026-10-14T01:00:00Z'
        $script:launch=[pscustomobject]@{
            schemaVersion=4;family='vanessa-ui';instanceId=('a'*32);pid=101;port=9874;catalogSha256=('c'*64)
            processStartTime=$script:started.ToString('o');executablePath='C:\Платформа теста\1cv8.exe'
            ownershipMarkers=@('C:\База менеджера','port=9874')
            infoBaseKind='file';infoBasePath='C:\Целевая база';managerInfoBaseKind='file';managerInfoBasePath='C:\База менеджера'
            portFamily='vanessa-mcp';portKey='backend-key';portLeaseToken='original-backend-token'
            testClientPortFamily='vanessa-test';testClientPortKey='client-key';testClientPortLeaseToken='original-client-token';testClientPort=48151
            testClientPid=102;testClientProcessStartTime=$script:started.ToString('o');testClientExecutablePath='C:\Платформа теста\1cv8.exe'
            testClientOwnershipMarkers=@('C:\Целевая база','/TESTCLIENT','-TPort 48151');vanessaParamsPath=''
        }
        $script:expected=[pscustomobject]@{instanceId=('a'*32);pid=101;port=9874;processStartTime=$script:launch.processStartTime;nativeLaunchProof=$script:launch}
        $script:invocation=[pscustomobject]@{plan=[pscustomobject]@{family='vanessa-ui';projectRoot=$script:ProjectRoot;targetBase=[pscustomobject]@{kind='file';path='C:\Целевая база'}}}
        Mock Read-ItlOnDemandRuntimeState { $null }
        Mock Get-ItlOnDemandRuntimePath { $script:runtimePath }
        Mock Write-ItlOnDemandRuntimeState { throw 'must not reconstruct missing registration' }
        Mock Invoke-WithOneCExecutionGuard {
            param($Admissions,$Purpose,$ScriptBlock)
            $Purpose | Should -Be 'ondemand-vanessa-ui-recover'
            @($Admissions).Count | Should -Be 2
            $script:sequence.Add('guard')
            & $ScriptBlock
        }
        Mock Get-ItlOnDemandManagedPortLeaseMatches {
            param($Family,$Key,$LeaseToken)
            if ($Key -eq 'backend-key' -and $LeaseToken -eq 'original-backend-token') { [pscustomobject]@{port=9874;pid=101} }
            elseif ($Key -eq 'client-key' -and $LeaseToken -eq 'original-client-token') { [pscustomobject]@{port=48151;pid=102} }
        }
        Mock Get-Process { param($Id) [pscustomobject]@{Id=$Id;StartTime=$script:started;HasExited=$false} }
        Mock Get-ItlOnDemandProcessOwnershipProof { param($RuntimeState,$ExactStart) [pscustomobject]@{owned=$true} }
        Mock Get-ItlOnDemandOwnedTestClientProcesses { param($RuntimeState,$ExactStart,$RegisteredOnly) @([pscustomobject]@{process=[pscustomobject]@{Id=102;StartTime=$script:started}}) }
        Mock Get-OneCInfoBaseSessionProcesses { @([pscustomobject]@{pid=101},[pscustomobject]@{pid=102}) }
        Mock Stop-Process { param($Id) $script:sequence.Add("stop-$Id") }
        Mock Wait-ItlOnDemandProcessExit { $true }
        Mock Test-TcpPortOpen { $false }
        Mock Test-ItlOnDemandPortOwnedByProcess { $false }
        Mock Release-ItlOnDemandManagedPortLease { param($Family,$Key,$LeaseToken) $script:sequence.Add("release-$LeaseToken") }
        Mock Start-ItlOnDemandBackendInstance {
            param($Family,$InstanceId)
            $script:sequence.Add('start')
            [pscustomobject]@{family=$Family;instanceId=$InstanceId;pid=103;port=9875;status='readiness'}
        }
    }
    AfterEach {
        $script:ProjectRoot=$script:savedRoot
        $env:ITL_EXECUTION_CONTEXT=$script:savedContext
        $env:ITL_EXECUTION_CONTEXT_KEY=$script:savedKey
    }

    It 'stops only original proven owners and releases their exact leases before starting a new instance' {
        $result=Recover-ItlOnDemandBackendInstance -Family vanessa-ui -InstanceId ('a'*32) -ReplacementInstanceId ('b'*32) -ExpectedPid 101 -ExpectedPort 9874 -CatalogSha256 ('c'*64) -Invocation $script:invocation -ExpectedBackend $script:expected
        $result.instanceId | Should -Be ('b'*32)
        $script:sequence.ToArray() | Should -Be @('guard','stop-102','stop-101','release-original-backend-token','release-original-client-token','start')
        Should -Invoke Write-ItlOnDemandRuntimeState -Times 0 -Exactly
        Test-Path $script:runtimePath | Should -BeFalse
    }

    It 'keeps every process and lease for invalid <Defect> proof' -ForEach @(
        @{Defect='absent'},@{Defect='wrong-instance'},@{Defect='wrong-target'},@{Defect='missing-exe'},@{Defect='replaced-lease'},@{Defect='wrong-lease-pid'},@{Defect='missing-parent'}
    ) {
        param($Defect)
        switch ($Defect) {
            absent { $script:expected.nativeLaunchProof=$null }
            wrong-instance { $script:launch.instanceId=('f'*32) }
            wrong-target { $script:launch.infoBasePath='C:\Чужая база' }
            missing-exe { $script:launch.executablePath='' }
            replaced-lease { Mock Get-ItlOnDemandManagedPortLeaseMatches { @() } }
            wrong-lease-pid { Mock Get-ItlOnDemandManagedPortLeaseMatches { [pscustomobject]@{port=9874;pid=999} } }
            missing-parent { $env:ITL_EXECUTION_CONTEXT='' }
        }
        { Recover-ItlOnDemandBackendInstance -Family vanessa-ui -InstanceId ('a'*32) -ReplacementInstanceId ('b'*32) -ExpectedPid 101 -ExpectedPort 9874 -CatalogSha256 ('c'*64) -Invocation $script:invocation -ExpectedBackend $script:expected } | Should -Throw '*ITL_ONDEMAND_RECOVERY_*'
        Should -Invoke Stop-Process -Times 0 -Exactly
        Should -Invoke Release-ItlOnDemandManagedPortLease -Times 0 -Exactly
        Should -Invoke Start-ItlOnDemandBackendInstance -Times 0 -Exactly
    }

    It 'recovers a healthy old listener only after exact port ownership and owned cleanup' {
        Mock Test-TcpPortOpen {
            param($Port)
            if ($Port -eq 9874) { return -not $script:sequence.Contains('stop-101') }
            if ($Port -eq 48151) { return -not $script:sequence.Contains('stop-102') }
            return $false
        }
        Mock Test-ItlOnDemandPortOwnedByProcess { param($Port,$ProcessId) ($Port -eq 9874 -and $ProcessId -eq 101) -or ($Port -eq 48151 -and $ProcessId -eq 102) }
        $result=Recover-ItlOnDemandBackendInstance -Family vanessa-ui -InstanceId ('a'*32) -ReplacementInstanceId ('b'*32) -ExpectedPid 101 -ExpectedPort 9874 -CatalogSha256 ('c'*64) -Invocation $script:invocation -ExpectedBackend $script:expected
        $result.instanceId | Should -Be ('b'*32)
        Should -Invoke Test-ItlOnDemandPortOwnedByProcess -Times 2 -Exactly
        $script:sequence[-1] | Should -Be start
    }

    It 'preserves every process and lease when the <Port> listener is foreign' -ForEach @(@{Port=9874},@{Port=48151}) {
        param($Port)
        $script:foreignPort=$Port
        Mock Test-TcpPortOpen { param($Port) $Port -eq $script:foreignPort }
        { Recover-ItlOnDemandBackendInstance -Family vanessa-ui -InstanceId ('a'*32) -ReplacementInstanceId ('b'*32) -ExpectedPid 101 -ExpectedPort 9874 -CatalogSha256 ('c'*64) -Invocation $script:invocation -ExpectedBackend $script:expected } | Should -Throw '*ITL_ONDEMAND_RECOVERY_PORT_OWNER_CHANGED*'
        Should -Invoke Stop-Process -Times 0 -Exactly
        Should -Invoke Release-ItlOnDemandManagedPortLease -Times 0 -Exactly
        Should -Invoke Start-ItlOnDemandBackendInstance -Times 0 -Exactly
    }

    It 'does not stop an unidentified exact-base session or unregistered TestClient' -ForEach @(@{ForeignSession=$true},@{ForeignSession=$false}) {
        param($ForeignSession)
        if ($ForeignSession) { Mock Get-OneCInfoBaseSessionProcesses { @([pscustomobject]@{pid=999}) } }
        else {
            $script:launch.testClientPid=0
            Mock Get-ItlOnDemandOwnedTestClientProcesses { @() }
            Mock Test-TcpPortOpen { $true }
            Mock Test-ItlOnDemandPortOwnedByProcess { param($Port,$ProcessId) $Port -eq 9874 -and $ProcessId -eq 101 }
        }
        { Recover-ItlOnDemandBackendInstance -Family vanessa-ui -InstanceId ('a'*32) -ReplacementInstanceId ('b'*32) -ExpectedPid 101 -ExpectedPort 9874 -CatalogSha256 ('c'*64) -Invocation $script:invocation -ExpectedBackend $script:expected } | Should -Throw '*ITL_ONDEMAND_RECOVERY_NOT_QUIESCENT*'
        Should -Invoke Stop-Process -Times 0 -Exactly
        Should -Invoke Start-ItlOnDemandBackendInstance -Times 0 -Exactly
    }

    It 'rejects a one-millisecond PID reuse before any cleanup' {
        Mock Get-Process { param($Id) [pscustomobject]@{Id=$Id;StartTime=$script:started.AddMilliseconds(1);HasExited=$false} }
        Mock Get-CimInstance { [pscustomobject]@{ExecutablePath=$script:launch.executablePath;CommandLine='C:\База менеджера port=9874'} }
        Mock Get-ItlOnDemandProcessOwnershipProof { param($RuntimeState,$ExactStart) & $actualOwnershipProof -RuntimeState $RuntimeState -ExactStart:$ExactStart }
        { Recover-ItlOnDemandBackendInstance -Family vanessa-ui -InstanceId ('a'*32) -ReplacementInstanceId ('b'*32) -ExpectedPid 101 -ExpectedPort 9874 -CatalogSha256 ('c'*64) -Invocation $script:invocation -ExpectedBackend $script:expected } | Should -Throw '*ITL_ONDEMAND_OWNERSHIP_MISMATCH*'
        Should -Invoke Stop-Process -Times 0 -Exactly
        Should -Invoke Release-ItlOnDemandManagedPortLease -Times 0 -Exactly
    }

    It 'preserves a registration that reappears rather than replacing it with retained JSON' {
        [IO.File]::WriteAllText($script:runtimePath,'reappeared record')
        { Recover-ItlOnDemandBackendInstance -Family vanessa-ui -InstanceId ('a'*32) -ReplacementInstanceId ('b'*32) -ExpectedPid 101 -ExpectedPort 9874 -CatalogSha256 ('c'*64) -Invocation $script:invocation -ExpectedBackend $script:expected } | Should -Throw '*ITL_ONDEMAND_RECOVERY_STATE_REAPPEARED*'
        [IO.File]::ReadAllText($script:runtimePath) | Should -Be 'reappeared record'
        Should -Invoke Stop-Process -Times 0 -Exactly
        Should -Invoke Start-ItlOnDemandBackendInstance -Times 0 -Exactly
    }

    It 'retains leases and refuses restart when owned process termination remains unconfirmed' {
        Mock Wait-ItlOnDemandProcessExit { $false }
        { Recover-ItlOnDemandBackendInstance -Family vanessa-ui -InstanceId ('a'*32) -ReplacementInstanceId ('b'*32) -ExpectedPid 101 -ExpectedPort 9874 -CatalogSha256 ('c'*64) -Invocation $script:invocation -ExpectedBackend $script:expected } | Should -Throw '*ITL_ONDEMAND_STOP_FAILED*'
        Should -Invoke Release-ItlOnDemandManagedPortLease -Times 0 -Exactly
        Should -Invoke Start-ItlOnDemandBackendInstance -Times 0 -Exactly
    }

    It 'confirms an already completed owned cleanup without recreating its missing record or leases' {
        Mock Get-ItlOnDemandManagedPortLeaseMatches { @() }
        Mock Get-Process { $null }
        Mock Get-ItlOnDemandOwnedTestClientProcesses { @() }
        Mock Get-ItlOnDemandProcessOwnershipProof { [pscustomobject]@{owned=$false} }
        Mock Get-OneCInfoBaseSessionProcesses { @() }
        $result=Recover-ItlOnDemandBackendInstance -Family vanessa-ui -InstanceId ('a'*32) -ReplacementInstanceId ('b'*32) -ExpectedPid 101 -ExpectedPort 9874 -CatalogSha256 ('c'*64) -Invocation $script:invocation -ExpectedBackend $script:expected
        $result.instanceId | Should -Be ('b'*32)
        Should -Invoke Stop-Process -Times 0 -Exactly
        Should -Invoke Write-ItlOnDemandRuntimeState -Times 0 -Exactly
        Should -Invoke Start-ItlOnDemandBackendInstance -Times 1 -Exactly
    }
}
