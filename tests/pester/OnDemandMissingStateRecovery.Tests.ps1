BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSupport.ps1')
    $context=Initialize-WorkflowPesterContext
    . $context.HelperPath -ProjectRoot $context.RepoRoot -Action help *> $null
    $actualOwnershipProof=(Get-Command Get-ItlOnDemandProcessOwnershipProof).ScriptBlock
    $actualChildProof=(Get-Command Get-ItlOnDemandOwnedTestClientProcesses).ScriptBlock
}

Describe 'Cross-family retained cleanup on isolated native processes' {
    BeforeEach {
        $script:nativeSavedRoot=$script:ProjectRoot
        $script:ProjectRoot=Join-Path $TestDrive ('Изолированный стенд '+[guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $script:ProjectRoot | Out-Null
        $script:nativeFixtures=[Collections.Generic.List[object]]::new()
        $script:nativeLeases=@{}
        $script:listenerScript=Join-Path $script:ProjectRoot 'Владелец listener.py'
        Write-Utf8Text $listenerScript @'
import json, socket, sys, time
with socket.socket() as listener:
    listener.bind(('127.0.0.1', 0))
    listener.listen()
    with open(sys.argv[1], 'w', encoding='utf-8') as result:
        json.dump({'port': listener.getsockname()[1]}, result)
    while True:
        time.sleep(0.1)
'@
        function New-NativeCleanupFixture {
            param([string]$Name)
            $resultPath=Join-Path $script:ProjectRoot ($Name+'.json')
            $process=Start-NativeProcessBackground -FilePath (Get-Command python -CommandType Application | Select-Object -First 1).Source -Arguments @('-u',$script:listenerScript,$resultPath)
            $script:nativeFixtures.Add($process)
            $deadline=[DateTime]::UtcNow.AddSeconds(15)
            while(-not (Test-Path -LiteralPath $resultPath)) {
                if($process.HasExited -or [DateTime]::UtcNow -gt $deadline){throw 'isolated listener did not start'}
                Start-Sleep -Milliseconds 50
            }
            $port=[int](Read-Utf8Text $resultPath|ConvertFrom-Json).port
            return [pscustomobject]@{process=$process;port=$port;started=$process.StartTime.ToUniversalTime().ToString('o');executable=$process.Path;markers=@($script:listenerScript,$resultPath)}
        }
        Mock Get-ItlOnDemandManagedPortLeaseMatches {
            param($Family,$Key,$LeaseToken)
            if($script:nativeLeases.ContainsKey($LeaseToken)){$script:nativeLeases[$LeaseToken]}
        }
        Mock Release-ItlOnDemandManagedPortLease {param($Family,$Key,$LeaseToken) $script:nativeLeases.Remove($LeaseToken)}
        Mock Get-OneCExecutionGuardSettings { [pscustomobject]@{root=(Join-Path $script:ProjectRoot 'guards');python=(Get-Command python -CommandType Application|Select-Object -First 1).Source;waitTimeoutSeconds=15} }
    }
    AfterEach {
        foreach($process in $script:nativeFixtures){
            if(-not $process.HasExited){$null=$process.Handle;(Stop-NativeProcessForSafety -Process $process -UseOpenedProcess).confirmed | Should -BeTrue}
        }
        $script:ProjectRoot=$script:nativeSavedRoot
    }
    It 'releases only the retained <Family> runtime and keeps the other family usable' -ForEach @(@{Family='roctup'},@{Family='vanessa-ui'}) {
        param($Family)
        $own=New-NativeCleanupFixture own
        $other=New-NativeCleanupFixture peer
        $peerFamily=$(if($Family -eq 'roctup'){'vanessa-ui'}else{'roctup'})
        $basePath=Join-Path $script:ProjectRoot 'Копия базы'
        $record=[pscustomobject]@{schemaVersion=4;status='running';family=$Family;instanceId=('a'*32);pid=$own.process.Id;port=$own.port;processStartTime=$own.started;executablePath=$own.executable;ownershipMarkers=$own.markers;infoBaseKind='file';infoBasePath=$basePath;managerInfoBaseKind='file';managerInfoBasePath=$basePath;portFamily='isolated';portKey='own';portLeaseToken='own-token';testClientPid=0;testClientPort=0}
        $peer=$record|ConvertTo-Json -Depth 8|ConvertFrom-Json
        $peer.family=$peerFamily;$peer.instanceId=('b'*32);$peer.pid=$other.process.Id;$peer.port=$other.port;$peer.processStartTime=$other.started;$peer.executablePath=$other.executable;$peer.ownershipMarkers=$other.markers;$peer.portKey='peer';$peer.portLeaseToken='peer-token'
        $script:nativeLeases['peer-token']=[pscustomobject]@{port=$other.port;pid=$other.process.Id}
        $script:nativeLeases['own-token']=[pscustomobject]@{port=$own.port;pid=$own.process.Id}
        $script:nativeSessions=@([pscustomobject]@{pid=$own.process.Id},[pscustomobject]@{pid=$other.process.Id})
        if($peerFamily -eq 'vanessa-ui'){
            $client=New-NativeCleanupFixture client
            foreach($entry in @{testClientPid=$client.process.Id;testClientPort=$client.port;testClientProcessStartTime=$client.started;testClientExecutablePath=$client.executable;testClientOwnershipMarkers=$client.markers;testClientPortFamily='isolated';testClientPortKey='peer-client';testClientPortLeaseToken='peer-client-token'}.GetEnumerator()){$peer|Add-Member -Force -NotePropertyName $entry.Key -NotePropertyValue $entry.Value}
            $script:nativeLeases['peer-client-token']=[pscustomobject]@{port=$client.port;pid=$client.process.Id}
            $script:nativeSessions+=[pscustomobject]@{pid=$client.process.Id}
        }
        Invoke-WithItlOnDemandRuntimeMutation -Family $peerFamily -InstanceIds @('b'*32) -OwnerFunction Write-ItlOnDemandRuntimeState -OwnerArguments @{RuntimeState=$peer}|Out-Null
        $peerPath=Get-ItlOnDemandRuntimePath -Family $peerFamily -InstanceId ('b'*32)
        $peerHash=(Get-FileHash -LiteralPath $peerPath).Hash
        Mock Get-OneCInfoBaseSessionProcesses { $script:nativeSessions }
        $admissions=@([pscustomobject]@{infoBaseKind='file';infoBasePath=$basePath})
        $stopped=Invoke-WithOneCExecutionGuard -Admissions $admissions -Purpose "ondemand-$Family-call" -ScriptBlock {
            Stop-ItlOnDemandBackendInstance -Family $Family -InstanceId ('a'*32) -RetainedRuntimeState $record
        }
        $stopped.status | Should -Be stopped
        $own.process.WaitForExit(5000) | Should -BeTrue
        Test-TcpPortOpen -Port $own.port | Should -BeFalse
        $other.process.HasExited | Should -BeFalse
        Test-TcpPortOpen -Port $other.port | Should -BeTrue
        if($peerFamily -eq 'vanessa-ui'){$client.process.HasExited | Should -BeFalse;Test-TcpPortOpen -Port $client.port | Should -BeTrue;$script:nativeLeases.ContainsKey('peer-client-token') | Should -BeTrue}
        (Get-FileHash -LiteralPath $peerPath).Hash | Should -Be $peerHash
        $script:nativeLeases.ContainsKey('own-token') | Should -BeFalse
        $script:nativeLeases.ContainsKey('peer-token') | Should -BeTrue
        # The original task can acquire the same resource after owned cleanup,
        # while the other family's warmed native runtime remains available.
        (Invoke-WithOneCExecutionGuard -Admissions $admissions -Purpose "ondemand-$peerFamily-call" -ScriptBlock { Test-TcpPortOpen -Port $other.port }) | Should -BeTrue
    }
}

Describe 'Private TestClient close and runtime mutation owner' {
    BeforeEach {
        $script:savedRoot=$script:ProjectRoot
        $script:savedContext=$env:ITL_EXECUTION_CONTEXT
        $script:savedKey=$env:ITL_EXECUTION_CONTEXT_KEY
        $script:ProjectRoot=Join-Path $TestDrive ('Закрытие своего клиента '+[guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $script:ProjectRoot | Out-Null
        $env:ITL_EXECUTION_CONTEXT='original-owner';$env:ITL_EXECUTION_CONTEXT_KEY='original-key'
        $script:nativeStops=[Collections.Generic.List[int]]::new()
        $script:childAlive=$false
        $script:record=[pscustomobject]@{
            schemaVersion=4;family='vanessa-ui';instanceId=('a'*32);pid=101;port=9874;catalogSha256=('c'*64)
            processStartTime='2026-10-14T01:00:00.0000000Z';executablePath='C:\Платформа теста\1cv8.exe'
            ownershipMarkers=@('C:\База менеджера','port=9874');infoBaseKind='file';infoBasePath='C:\Целевая база'
            managerInfoBaseKind='file';managerInfoBasePath='C:\База менеджера';portFamily='vanessa';portKey='manager';portLeaseToken='manager-token'
            testClientPid=102;testClientPort=48151;testClientProcessStartTime='2026-10-14T01:01:00.0000000Z'
            testClientExecutablePath='C:\Платформа теста\1cv8c.exe';testClientOwnershipMarkers=@('C:\Целевая база','/TESTCLIENT','-TPort 48151')
            testClientPortFamily='vanessa-test';testClientPortKey='child';testClientPortLeaseToken='child-token';vanessaParamsPath=''
        }
        Invoke-WithItlOnDemandRuntimeMutation -Family vanessa-ui -InstanceIds @('a'*32) -OwnerFunction Write-ItlOnDemandRuntimeState -OwnerArguments @{RuntimeState=$script:record} | Out-Null
        Mock Get-ItlOnDemandManagedPortLeaseMatches { param($Family,$Key,$LeaseToken) if($Key -eq 'manager'){[pscustomobject]@{port=9874;pid=101}}else{[pscustomobject]@{port=48151;pid=102}} }
        Mock Get-Process { param($Id) if($Id -eq 101 -or ($Id -eq 102 -and $script:childAlive)){[pscustomobject]@{Id=$Id}} }
        Mock Get-ItlOnDemandOwnedTestClientProcesses { if($script:childAlive){[pscustomobject]@{process=[pscustomobject]@{Id=102}}} }
        Mock Test-TcpPortOpen { $false }
        Mock Invoke-WithOneCExecutionGuard { param($Admissions,$Purpose,$ScriptBlock) if(-not $env:ITL_EXECUTION_CONTEXT){throw 'unsigned'}; & $ScriptBlock }
        Mock Stop-Process { param($Id) $script:nativeStops.Add([int](@($Id)[0]));if($Id -eq 102){$script:childAlive=$false} }
        Mock Wait-ItlOnDemandProcessExit { param($ProcessId) return (-not $script:childAlive) }
        Mock Release-ItlOnDemandManagedPortLease { throw 'child close must retain reservations' }
    }
    AfterEach { $script:ProjectRoot=$script:savedRoot;$env:ITL_EXECUTION_CONTEXT=$script:savedContext;$env:ITL_EXECUTION_CONTEXT_KEY=$script:savedKey }

    It 'confirms an exited child while retaining manager and last registered recovery identity' {
        $result=Complete-ItlOnDemandTestClientClose -InstanceId ('a'*32) -ExpectedRuntimeState $script:record
        $result.status | Should -Be 'test-client-closed'
        $saved=Read-ItlOnDemandRuntimeState vanessa-ui ('a'*32)
        $saved.pid | Should -Be 101
        $saved.testClientPid | Should -Be 102
        $saved.testClientState | Should -Be 'exited'
        $script:nativeStops.Count | Should -Be 0
        Should -Invoke Invoke-WithOneCExecutionGuard -Times 1 -Exactly
    }
    It 'finishes a falsely successful backend close only for the original child under its inherited guard' {
        $script:childAlive=$true
        $result=Complete-ItlOnDemandTestClientClose -InstanceId ('a'*32) -ExpectedRuntimeState $script:record
        $result.testClientExitConfirmed | Should -BeTrue
        @($script:nativeStops.ToArray()) | Should -Be @(102)
        Should -Invoke Release-ItlOnDemandManagedPortLease -Times 0 -Exactly
    }
    It 'preserves a replacement child before any native stop' {
        $changed=$script:record|ConvertTo-Json -Depth 8|ConvertFrom-Json
        $changed.testClientPid=999
        {Complete-ItlOnDemandTestClientClose -InstanceId ('a'*32) -ExpectedRuntimeState $changed} | Should -Throw '*STOP_IDENTITY_CHANGED*'
        $script:nativeStops.Count | Should -Be 0
    }
    It 'refuses foreign unregistered children and unsigned close' {
        $script:childAlive=$true
        Mock Get-ItlOnDemandOwnedTestClientProcesses { @() }
        {Complete-ItlOnDemandTestClientClose -InstanceId ('a'*32) -ExpectedRuntimeState $script:record} | Should -Throw '*OWNERSHIP_MISMATCH*'
        $env:ITL_EXECUTION_CONTEXT=$null
        {Complete-ItlOnDemandTestClientClose -InstanceId ('a'*32) -ExpectedRuntimeState $script:record} | Should -Throw '*EXECUTION_CONTEXT_REQUIRED*'
        $script:nativeStops.Count | Should -Be 0
    }
    It 'refuses stale writes outside the whole mutation instead of recreating a stopped registration' {
        {Write-ItlOnDemandRuntimeState $script:record} | Should -Throw '*MUTATION_OWNER_REQUIRED*'
    }
    It 'keeps the canonical record visible to drain until exact native cleanup completes' {
        Mock Get-ItlOnDemandProcessOwnershipProof { [pscustomobject]@{owned=$true} }
        Mock Release-ItlOnDemandManagedPortLease { }
        Mock Stop-Process {
            param($Id)
            (Test-Path -LiteralPath (Get-ItlOnDemandRuntimePath vanessa-ui ('a'*32))) | Should -BeTrue
            @(Get-ItlOnDemandRuntimeInstances -Strict).Count | Should -Be 1
            $script:nativeStops.Add([int](@($Id)[0]))
        }
        $result=Stop-ItlOnDemandBackendInstance -Family vanessa-ui -InstanceId ('a'*32) -ExpectedRuntimeState $script:record
        $result.status | Should -Be 'stopped'
        @($script:nativeStops.ToArray()) | Should -Be @(101)
        @(Get-ItlOnDemandRuntimeInstances -Strict).Count | Should -Be 0
    }
    It 'revalidates the full stop snapshot after a replacement was registered' {
        $replacement=$script:record|ConvertTo-Json -Depth 8|ConvertFrom-Json
        $replacement.pid=202
        Invoke-WithItlOnDemandRuntimeMutation -Family vanessa-ui -InstanceIds @('a'*32) -OwnerFunction Write-ItlOnDemandRuntimeState -OwnerArguments @{RuntimeState=$replacement} | Out-Null
        {Stop-ItlOnDemandBackendInstance -Family vanessa-ui -InstanceId ('a'*32) -ExpectedRuntimeState $script:record} | Should -Throw '*STOP_IDENTITY_CHANGED*'
        $script:nativeStops.Count | Should -Be 0
        (Read-ItlOnDemandRuntimeState vanessa-ui ('a'*32)).pid | Should -Be 202
    }
    It 'limits the process-only payload to stop and rejects inherited database authority' {
        $saved=$env:ITL_EXECUTION_INVOCATION
        try {
            $env:ITL_EXECUTION_CONTEXT=$null;$env:ITL_EXECUTION_CONTEXT_KEY=$null
            $env:ITL_EXECUTION_INVOCATION=@{schemaVersion=3;kind='owned-idle-stop';projectRoot=$script:ProjectRoot;family='vanessa-ui';expectedBackend=@{pid=101}}|ConvertTo-Json -Compress
            foreach($operation in @('ensure','ensure-test-client','mark-running','recover','execution-plan','complete-test-client-close','stop-all')) {
                {Read-ItlOnDemandExecutionInvocation -Family vanessa-ui -AuxiliaryContour '' -Operation $operation} | Should -Throw '*EXECUTION_CONTEXT_INVALID*'
            }
            (Read-ItlOnDemandExecutionInvocation -Family vanessa-ui -AuxiliaryContour '' -Operation stop).kind | Should -Be 'owned-idle-stop'
            $env:ITL_EXECUTION_CONTEXT='foreign'
            {Read-ItlOnDemandExecutionInvocation -Family vanessa-ui -AuxiliaryContour '' -Operation stop} | Should -Throw '*EXECUTION_CONTEXT_INVALID*'
        } finally { $env:ITL_EXECUTION_INVOCATION=$saved }
    }
    It 'rejects mutation resource expansion instead of recursively acquiring an unsorted replacement' {
        function Invoke-ExpansionFixture { Invoke-WithItlOnDemandRuntimeMutation -Family vanessa-ui -InstanceIds @('b'*32) -OwnerFunction Write-ItlOnDemandRuntimeState -OwnerArguments @{RuntimeState=$script:record} }
        {Invoke-WithItlOnDemandRuntimeMutation -Family vanessa-ui -InstanceIds @('a'*32) -OwnerFunction Invoke-ExpansionFixture -OwnerArguments @{}} | Should -Throw '*MUTATION_RESOURCE_EXPANSION*'
    }
    It 'does not interpret missing expected registration or legacy claim as a clean drain' {
        $path=Get-ItlOnDemandRuntimePath vanessa-ui ('a'*32)
        Move-Item -LiteralPath $path -Destination ($path+'.removing-original')
        {Stop-ItlOnDemandBackendInstance -Family vanessa-ui -InstanceId ('a'*32) -ExpectedRuntimeState $script:record} | Should -Throw '*STOP_UNCONFIRMED*'
        {Get-ItlOnDemandRuntimeInstances -Strict} | Should -Throw '*CLEANUP_CLAIM_INCOMPLETE*'
    }
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

    It 'finishes retained <Family> cleanup beside a proven live peer, preserving it (<Defect>)' -ForEach @(
        @{Family='vanessa-ui';Defect='none'},@{Family='roctup';Defect='none'},
        @{Family='vanessa-ui';Defect='reused-pid'},@{Family='roctup';Defect='reused-pid'},
        @{Family='vanessa-ui';Defect='replaced-lease'},@{Family='roctup';Defect='replaced-lease'},
        @{Family='vanessa-ui';Defect='changed-registration'},@{Family='roctup';Defect='changed-registration'},
        @{Family='vanessa-ui';Defect='foreign-executable'},@{Family='roctup';Defect='foreign-executable'},
        @{Family='vanessa-ui';Defect='unregistered'},@{Family='roctup';Defect='unregistered'},
        @{Family='vanessa-ui';Defect='ambiguous'},@{Family='roctup';Defect='ambiguous'},
        @{Family='vanessa-ui';Defect='foreign-listener'},@{Family='roctup';Defect='foreign-listener'},
        @{Family='vanessa-ui';Defect='wrong-base'},@{Family='roctup';Defect='wrong-base'}
    ) {
        param($Family,$Defect)
        $script:launch.family=$Family
        if($Family -eq 'roctup'){$script:launch.testClientPid=0;$script:launch.testClientPort=0}
        $script:peerFamily=$(if($Family -eq 'roctup'){'vanessa-ui'}else{'roctup'})
        $script:peer=$script:launch|ConvertTo-Json -Depth 8|ConvertFrom-Json
        $script:peer.family=$peerFamily;$script:peer.instanceId=('d'*32)
        $script:peer | Add-Member status running
        $script:peer.pid=201;$script:peer.port=9876
        $script:peer.managerInfoBasePath=$(if($peerFamily -eq 'roctup'){'C:\Целевая база'}else{'C:\Менеджер соседа'})
        $script:peer.ownershipMarkers=@($peer.managerInfoBasePath,'port=9876')
        $script:peer.portKey='peer-backend';$script:peer.portLeaseToken='peer-backend-token'
        $script:peer.testClientPid=202;$script:peer.testClientPort=48152
        $script:peer.testClientPortKey='peer-child';$script:peer.testClientPortLeaseToken='peer-child-token'
        $script:peer.testClientOwnershipMarkers=@('C:\Целевая база','/TESTCLIENT','-TPort 48152')
        $script:peerSession=$(if($peerFamily -eq 'roctup'){201}else{202})
        $script:peerDefect=$Defect
        if($Defect -eq 'wrong-base'){$script:peer.managerInfoBasePath='C:\Другая база';$script:peer.infoBasePath='C:\Другая база'}
        Mock Get-ItlOnDemandRuntimeInstances {
            if($script:peerDefect -eq 'unregistered'){return @()}
            if($script:peerDefect -eq 'ambiguous'){return @($script:peer,$script:peer)}
            $script:peer
        }
        Mock Read-ItlOnDemandRuntimeState {
            param($Family,$InstanceId)
            if($InstanceId -cne ('d'*32)){return $null}
            $current=$script:peer|ConvertTo-Json -Depth 8|ConvertFrom-Json
            if($script:peerDefect -eq 'changed-registration'){$current.processStartTime=$script:started.AddSeconds(1).ToString('o')}
            $current
        }
        Mock Get-Process {
            param($Id)
            $start=$script:started
            if($Id -eq $script:peerSession -and $script:peerDefect -eq 'reused-pid'){$start=$start.AddMilliseconds(1)}
            [pscustomobject]@{Id=[int](@($Id)[0]);StartTime=$start;HasExited=$false}
        }
        Mock Get-CimInstance {
            param($ClassName,$Filter)
            $exe=$script:peer.executablePath
            if($script:peerDefect -eq 'foreign-executable'){$exe='C:\Чужая платформа\1cv8.exe'}
            [pscustomobject]@{ExecutablePath=$exe;CommandLine=($script:peer.ownershipMarkers -join ' ')+' '+($script:peer.testClientOwnershipMarkers -join ' ')}
        }
        Mock Get-ItlOnDemandProcessOwnershipProof {
            param($RuntimeState,$ExactStart)
            if($RuntimeState.pid -eq 201){return (& $actualOwnershipProof -RuntimeState $RuntimeState -ExactStart:$ExactStart)}
            [pscustomobject]@{owned=$true}
        }
        Mock Get-ItlOnDemandOwnedTestClientProcesses {
            param($RuntimeState,$ExactStart,$RegisteredOnly)
            if($RuntimeState.pid -eq 201){return (& $actualChildProof -RuntimeState $RuntimeState -ExactStart:$ExactStart -RegisteredOnly:$RegisteredOnly)}
            if($RuntimeState.family -eq 'vanessa-ui'){[pscustomobject]@{process=[pscustomobject]@{Id=102}}}
        }
        Mock Test-ItlOnDemandPortOwnedByProcess { param($Port,$ProcessId) if($script:peerDefect -eq 'foreign-listener'){return $false}; ($Port -eq 9876 -and $ProcessId -eq 201) -or ($Port -eq 48152 -and $ProcessId -eq 202) }
        Mock Get-ItlOnDemandManagedPortLeaseMatches {
            param($Family,$Key,$LeaseToken)
            if($script:peerDefect -eq 'replaced-lease' -and $Key -like 'peer-*'){return @()}
            if($Key -eq 'peer-backend' -and $LeaseToken -eq 'peer-backend-token'){return [pscustomobject]@{port=9876;pid=201}}
            if($Key -eq 'peer-child' -and $LeaseToken -eq 'peer-child-token'){return [pscustomobject]@{port=48152;pid=202}}
        }
        Mock Get-OneCInfoBaseSessionProcesses {
            param($InfoBaseKind,$InfoBasePath)
            [pscustomobject]@{pid=101}
            if($script:launch.family -eq 'vanessa-ui'){[pscustomobject]@{pid=102}}
            if($InfoBasePath -eq 'C:\Целевая база'){[pscustomobject]@{pid=$script:peerSession}}
        }
        $operation={ Stop-ItlOnDemandBackendInstance -Family $Family -InstanceId ('a'*32) -RetainedRuntimeState $script:launch }
        if($Defect -eq 'none') {
            (Get-ItlOnDemandProcessOwnershipProof -RuntimeState $script:peer -ExactStart).owned | Should -BeTrue
            if($peerFamily -eq 'vanessa-ui'){@(Get-ItlOnDemandOwnedTestClientProcesses -RuntimeState $script:peer -ExactStart -RegisteredOnly).Count | Should -Be 1}
            Assert-ItlOnDemandCleanupIdentity -Actual (Read-ItlOnDemandRuntimeState -Family $peerFamily -InstanceId ('d'*32)) -Expected $script:peer
            (& $operation).status | Should -Be stopped
            $script:sequence.ToArray() | Should -Contain 'stop-101'
            $script:sequence.ToArray() | Should -Contain 'release-original-backend-token'
        } else {
            $operation | Should -Throw '*ITL_ONDEMAND_RECOVERY_NOT_QUIESCENT*'
            Should -Invoke Stop-Process -Times 0 -Exactly
            Should -Invoke Release-ItlOnDemandManagedPortLease -Times 0 -Exactly
        }
        Should -Invoke Stop-Process -Times 0 -Exactly -ParameterFilter { $Id -in @(201,202) }
        Should -Invoke Release-ItlOnDemandManagedPortLease -Times 0 -Exactly -ParameterFilter { $Key -like 'peer-*' }
    }
}
