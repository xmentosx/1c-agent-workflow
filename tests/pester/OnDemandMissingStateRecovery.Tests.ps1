BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSupport.ps1')
    $context=Initialize-WorkflowPesterContext
    . $context.HelperPath -ProjectRoot $context.RepoRoot -Action help *> $null
    $actualOwnershipProof=(Get-Command Get-ItlOnDemandProcessOwnershipProof).ScriptBlock
    $actualChildProof=(Get-Command Get-ItlOnDemandOwnedTestClientProcesses).ScriptBlock
    $actualPortOwnership=(Get-Command Get-ItlOnDemandPortOwnership).ScriptBlock
}

Describe 'Cross-family missing-registration cleanup on isolated native processes' {
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
    It 'stops only the launched <Family> runtime and keeps the other family usable' -ForEach @(@{Family='roctup'},@{Family='vanessa-ui'}) {
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
            Stop-ItlOnDemandBackendInstance -Family $Family -InstanceId ('a'*32) -LaunchProof $record
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

Describe 'Lifecycle stop followed by same-port native peer and missing-state recovery' {
    BeforeEach {
        $script:reusedSavedRoot=$script:ProjectRoot
        $script:ProjectRoot=Join-Path $TestDrive ('Повторное использование портов '+[guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $script:ProjectRoot | Out-Null
        $script:reusedProcesses=[Collections.Generic.List[object]]::new()
        $script:reusedSessions=@()
        $script:reusedBase=Join-Path $script:ProjectRoot 'Копия базы'
        $script:reusedManagerBase=Join-Path $script:ProjectRoot 'База менеджера'
        $script:reusedRegistry=Join-Path $script:ProjectRoot 'Реестр портов'
        Mock Get-ItlPortRegistryHome { $script:reusedRegistry }
        Mock Get-OneCExecutionGuardSettings { [pscustomobject]@{root=(Join-Path $script:ProjectRoot 'guards');python=(Get-Command python -CommandType Application|Select-Object -First 1).Source;waitTimeoutSeconds=15} }
        # Only 1C session discovery and native 1C launch are substituted. Registry,
        # process/start/EXE/markers, listeners, stop and signed guard are real.
        Mock Get-OneCInfoBaseSessionProcesses {
            param($InfoBaseKind,$InfoBasePath)
            @($script:reusedSessions | Where-Object { $_.path -eq $InfoBasePath })
        }
        $script:reusedListener=Join-Path $script:ProjectRoot 'Владелец порта.py'
        Write-Utf8Text $script:reusedListener @'
import json, socket, sys
with socket.socket() as listener:
    listener.bind(('127.0.0.1', int(sys.argv[2])))
    listener.listen()
    with open(sys.argv[1], 'w', encoding='utf-8') as ready:
        json.dump({'port': listener.getsockname()[1]}, ready)
    while True:
        connection, _ = listener.accept()
        with connection:
            connection.settimeout(2)
            try:
                if connection.recv(4) == b'ping':
                    connection.sendall(b'pong')
            except (OSError, TimeoutError):
                pass
'@
        function New-ReusedPortListener {
            param([string]$Name,[int]$Port,[string]$Base)
            $ready=Join-Path $script:ProjectRoot ($Name+'.ready.json')
            $process=Start-NativeProcessBackground -FilePath (Get-Command python -CommandType Application|Select-Object -First 1).Source -Arguments @('-u',$script:reusedListener,$ready,[string]$Port,$Base,$Name)
            $script:reusedProcesses.Add($process)
            $deadline=[DateTime]::UtcNow.AddSeconds(15)
            while(-not (Test-Path -LiteralPath $ready)) {
                if($process.HasExited -or [DateTime]::UtcNow -gt $deadline){throw 'native same-port listener did not start'}
                Start-Sleep -Milliseconds 50
            }
            $script:reusedSessions+= [pscustomobject]@{pid=$process.Id;path=$Base}
            return $process
        }
        function New-ReusedPortRuntime {
            param([string]$Family,[string]$InstanceId,[string]$Name,[int]$Port=0,[int]$ClientPort=0)
            $token=[guid]::NewGuid().ToString('N')
            $lease=Resolve-ItlManagedPortLease -Family native-manager -Key $InstanceId -LeaseToken $token -Start 49152 -End 65500 -ExplicitPort $Port
            $managerBase=$(if($Family -eq 'vanessa-ui'){$script:reusedManagerBase}else{$script:reusedBase})
            $manager=New-ReusedPortListener -Name ($Name+'-manager') -Port $lease.port -Base $managerBase
            Set-ItlManagedPortAllocationStatus -Family native-manager -Key $InstanceId -LeaseToken $token -Status running -ProcessId $manager.Id
            $record=[pscustomobject]@{
                schemaVersion=4;status='running';family=$Family;instanceId=$InstanceId;pid=$manager.Id;port=$lease.port;catalogSha256=('c'*64)
                processStartTime=$manager.StartTime.ToUniversalTime().ToString('o');executablePath=$manager.Path;ownershipMarkers=@($script:reusedListener,$managerBase)
                infoBaseKind='file';infoBasePath=$script:reusedBase;managerInfoBaseKind='file';managerInfoBasePath=$managerBase
                portFamily='native-manager';portKey=$InstanceId;portLeaseToken=$token;testClientPid=0;testClientPort=0;vanessaParamsPath=''
            }
            if($Family -eq 'vanessa-ui') {
                $clientToken=[guid]::NewGuid().ToString('N')
                $clientLease=Resolve-ItlManagedPortLease -Family native-client -Key $InstanceId -LeaseToken $clientToken -Start 49152 -End 65500 -ExplicitPort $ClientPort
                $clientName=$Name+'-client'
                $client=New-ReusedPortListener -Name $clientName -Port $clientLease.port -Base $script:reusedBase
                Set-ItlManagedPortAllocationStatus -Family native-client -Key $InstanceId -LeaseToken $clientToken -Status running -ProcessId $client.Id
                foreach($entry in @{testClientPid=$client.Id;testClientPort=$clientLease.port;testClientProcessStartTime=$client.StartTime.ToUniversalTime().ToString('o');testClientExecutablePath=$client.Path;testClientOwnershipMarkers=@($script:reusedListener,$script:reusedBase,$clientName);testClientPortFamily='native-client';testClientPortKey=$InstanceId;testClientPortLeaseToken=$clientToken}.GetEnumerator()) {
                    $record|Add-Member -Force -NotePropertyName $entry.Key -NotePropertyValue $entry.Value
                }
            }
            Invoke-WithItlOnDemandRuntimeMutation -Family $Family -InstanceIds @($InstanceId) -OwnerFunction Write-ItlOnDemandRuntimeState -OwnerArguments @{RuntimeState=$record}|Out-Null
            return $record
        }
        function Test-ReusedPortResponse {
            param([int]$Port)
            $client=[Net.Sockets.TcpClient]::new()
            try {
                $client.Connect('127.0.0.1',$Port)
                $stream=$client.GetStream();$stream.ReadTimeout=3000;$stream.WriteTimeout=3000
                $request=[Text.Encoding]::ASCII.GetBytes('ping');$stream.Write($request,0,$request.Length)
                $reply=New-Object byte[] 4
                $read=$stream.Read($reply,0,4)
                return $read -eq 4 -and [Text.Encoding]::ASCII.GetString($reply) -ceq 'pong'
            } finally { $client.Dispose() }
        }
        Mock Start-ItlOnDemandBackendInstance {
            param($Family,$InstanceId)
            New-ReusedPortRuntime -Family $Family -InstanceId $InstanceId -Name replacement
        }
    }
    AfterEach {
        foreach($process in $script:reusedProcesses) {
            if(-not $process.HasExited){$null=$process.Handle;(Stop-NativeProcessForSafety -Process $process -UseOpenedProcess).confirmed|Should -BeTrue}
            $process.Dispose()
        }
        $script:ProjectRoot=$script:reusedSavedRoot
    }
    It 'recovers retired <Family> beside a same-family peer on its exact old ports and resumes guarded work' -ForEach @(@{Family='vanessa-ui'},@{Family='roctup'}) {
        param($Family)
        $old=New-ReusedPortRuntime -Family $Family -InstanceId ('a'*32) -Name original
        $admissions=@(Get-ItlOnDemandRuntimeDatabaseConnections -RuntimeState $old -Family $Family | ForEach-Object {[pscustomobject]@{infoBaseKind=$_.kind;infoBasePath=$_.path}})
        Invoke-WithOneCExecutionGuard -Admissions $admissions -Purpose config-load -ScriptBlock {
            Stop-ItlOnDemandBackends -Family $Family -InfoBasePath $script:reusedBase
        }
        $script:reusedSessions=@()
        $oldPath=Get-ItlOnDemandRuntimePath $Family ('a'*32)
        Test-Path -LiteralPath $oldPath|Should -BeFalse
        @(Get-ItlOnDemandManagedPortLeaseMatches -Family $old.portFamily -Key $old.portKey -AnyLeaseToken).Count|Should -Be 0
        foreach($process in $script:reusedProcesses){$process.HasExited|Should -BeTrue}
        $peer=New-ReusedPortRuntime -Family $Family -InstanceId ('b'*32) -Name peer -Port $old.port -ClientPort $old.testClientPort
        $peer.port|Should -Be $old.port
        $peer.testClientPort|Should -Be $old.testClientPort
        $peerPath=Get-ItlOnDemandRuntimePath $Family ('b'*32)
        $peerHash=(Get-FileHash -LiteralPath $peerPath).Hash
        $peerLeases=@((Read-ItlPortRegistry).allocations|Where-Object {$_.key -eq ('b'*32)})|ConvertTo-Json -Compress -Depth 8
        $expected=[pscustomobject]@{instanceId=$old.instanceId;processStartTime=$old.processStartTime;nativeLaunchProof=$old}
        $invocation=[pscustomobject]@{plan=[pscustomobject]@{family=$Family;projectRoot=$script:ProjectRoot;targetBase=[pscustomobject]@{kind='file';path=$script:reusedBase}}}
        $recovered=Invoke-WithOneCExecutionGuard -Admissions $admissions -Purpose "ondemand-$Family-call" -ScriptBlock {
            Recover-ItlOnDemandBackendInstance -Family $Family -InstanceId $old.instanceId -ReplacementInstanceId ('c'*32) -ExpectedPid $old.pid -ExpectedPort $old.port -CatalogSha256 $old.catalogSha256 -Invocation $invocation -ExpectedBackend $expected
        }
        $recovered.instanceId|Should -Be ('c'*32)
        $recovered.pid|Should -Not -Be $old.pid
        Test-Path -LiteralPath $oldPath|Should -BeFalse
        (Get-FileHash -LiteralPath $peerPath).Hash|Should -Be $peerHash
        (@((Read-ItlPortRegistry).allocations|Where-Object {$_.key -eq ('b'*32)})|ConvertTo-Json -Compress -Depth 8)|Should -Be $peerLeases
        # Both original task continuation and the preserved peer still work
        # after the recovery's real execution-guard owner releases its handles.
        Invoke-WithOneCExecutionGuard -Admissions $admissions -Purpose "ondemand-$Family-call" -ScriptBlock {
            Test-ReusedPortResponse $recovered.port|Should -BeTrue
            Test-ReusedPortResponse $peer.port|Should -BeTrue
            if($Family -eq 'vanessa-ui') {
                Test-ReusedPortResponse $peer.testClientPort|Should -BeTrue
                Test-ReusedPortResponse $recovered.testClientPort|Should -BeTrue
            }
        }
        Should -Invoke Start-ItlOnDemandBackendInstance -Times 1 -Exactly
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
        # The stop path proves both ports through the real listener table, so the fixture
        # uses ports this host just released instead of the default Vanessa MCP port that
        # a live project on the same machine may hold.
        $listeners=@([Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0),[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0))
        try {
            foreach($listener in $listeners){$listener.Start()}
            $script:managerPort=[int]$listeners[0].LocalEndpoint.Port;$script:clientPort=[int]$listeners[1].LocalEndpoint.Port
        } finally { foreach($listener in $listeners){$listener.Stop()} }
        $script:nativeStops=[Collections.Generic.List[int]]::new()
        $script:childAlive=$false
        $script:record=[pscustomobject]@{
            schemaVersion=4;family='vanessa-ui';instanceId=('a'*32);pid=101;port=$script:managerPort;catalogSha256=('c'*64)
            processStartTime='2026-10-14T01:00:00.0000000Z';executablePath='C:\Платформа теста\1cv8.exe'
            ownershipMarkers=@('C:\База менеджера',"port=$script:managerPort");infoBaseKind='file';infoBasePath='C:\Целевая база'
            managerInfoBaseKind='file';managerInfoBasePath='C:\База менеджера';portFamily='vanessa';portKey='manager';portLeaseToken='manager-token'
            testClientPid=102;testClientPort=$script:clientPort;testClientProcessStartTime='2026-10-14T01:01:00.0000000Z'
            testClientExecutablePath='C:\Платформа теста\1cv8c.exe';testClientOwnershipMarkers=@('C:\Целевая база','/TESTCLIENT',"-TPort $script:clientPort")
            testClientPortFamily='vanessa-test';testClientPortKey='child';testClientPortLeaseToken='child-token';vanessaParamsPath=''
        }
        Invoke-WithItlOnDemandRuntimeMutation -Family vanessa-ui -InstanceIds @('a'*32) -OwnerFunction Write-ItlOnDemandRuntimeState -OwnerArguments @{RuntimeState=$script:record} | Out-Null
        Mock Get-ItlOnDemandManagedPortLeaseMatches { param($Family,$Key,$LeaseToken) if($Key -eq 'manager'){[pscustomobject]@{port=$script:managerPort;pid=101}}else{[pscustomobject]@{port=$script:clientPort;pid=102}} }
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

Describe 'Missing-registration recovery stops only what the facade launched' {
    # 2026-11-08 PM5 branch8/branch4: a lifecycle drain had already retired the
    # registration, and recovery demanded an unbroken proof chain (leases, ports,
    # peer sessions) before starting a replacement, so the guard stayed blocked for
    # hours. The facade's own launch snapshot now only selects what it may stop.
    BeforeEach {
        $script:savedRoot=$script:ProjectRoot
        $script:ProjectRoot=Join-Path $TestDrive ('Проект с пробелом '+[guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $script:ProjectRoot | Out-Null
        $script:sequence=[Collections.Generic.List[string]]::new()
        $script:started=[datetime]'2026-10-14T01:00:00Z'
        $script:alive=@{101=$true;102=$true}
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
        Mock Write-ItlOnDemandRuntimeState { throw 'must not reconstruct missing registration' }
        Mock Get-ItlOnDemandManagedPortLeaseMatches {
            param($Family,$Key,$LeaseToken)
            if ($Key -eq 'backend-key' -and $LeaseToken -eq 'original-backend-token') { [pscustomobject]@{port=9874;pid=101} }
            elseif ($Key -eq 'client-key' -and $LeaseToken -eq 'original-client-token') { [pscustomobject]@{port=48151;pid=102} }
        }
        Mock Get-Process { param($Id) $id=[int](@($Id)[0]); if ($script:alive[$id]) { [pscustomobject]@{Id=$id;StartTime=$script:started;Handle=1} } }
        Mock Get-CimInstance { [pscustomobject]@{ExecutablePath='C:\Платформа теста\1cv8.exe'} }
        Mock Stop-NativeProcessForSafety { param($Process) $script:sequence.Add("stop-$($Process.Id)"); $script:alive[[int]$Process.Id]=$false; [pscustomobject]@{confirmed=$true;error=''} }
        Mock Wait-ItlOnDemandProcessExit { param($ProcessId) -not $script:alive[[int]$ProcessId] }
        Mock Release-ItlOnDemandManagedPortLease { param($Family,$Key,$LeaseToken) $script:sequence.Add("release-$LeaseToken") }
        Mock Remove-VanessaAgentClientCodeChannel { $true }
        Mock Get-OneCInfoBaseSessionProcesses { throw 'missing-state recovery must not classify other sessions' }
        Mock Start-ItlOnDemandBackendInstance {
            param($Family,$InstanceId)
            $script:sequence.Add('start')
            [pscustomobject]@{family=$Family;instanceId=$InstanceId;pid=103;port=9875;status='readiness'}
        }
        function Invoke-MissingStateRecovery {
            Recover-ItlOnDemandBackendInstance -Family vanessa-ui -InstanceId ('a'*32) -ReplacementInstanceId ('b'*32) -ExpectedPid 101 -ExpectedPort 9874 -CatalogSha256 ('c'*64) -Invocation $script:invocation -ExpectedBackend $script:expected
        }
    }
    AfterEach { $script:ProjectRoot=$script:savedRoot }

    It 'stops the launched TestClient and backend, releases their exact leases, then starts a new instance' {
        (Invoke-MissingStateRecovery).instanceId | Should -Be ('b'*32)
        $script:sequence.ToArray() | Should -Be @('stop-102','stop-101','release-original-backend-token','release-original-client-token','start')
        Should -Invoke Write-ItlOnDemandRuntimeState -Times 0 -Exactly
    }

    It 'leaves a reused PID untouched and still starts the replacement' {
        Mock Get-Process { param($Id) [pscustomobject]@{Id=[int](@($Id)[0]);StartTime=$script:started.AddMilliseconds(1);Handle=1} }
        (Invoke-MissingStateRecovery).instanceId | Should -Be ('b'*32)
        Should -Invoke Stop-NativeProcessForSafety -Times 0 -Exactly
        $script:sequence[-1] | Should -Be 'start'
    }

    It 'never blocks on a replaced lease or another owner of the old ports' {
        Mock Get-ItlOnDemandManagedPortLeaseMatches { @() }
        (Invoke-MissingStateRecovery).instanceId | Should -Be ('b'*32)
        $script:sequence.ToArray() | Should -Be @('stop-102','stop-101','start')
        Should -Invoke Release-ItlOnDemandManagedPortLease -Times 0 -Exactly
    }

    It 'starts fresh without a launch snapshot of this exact instance (<Snapshot>)' -ForEach @(@{Snapshot='absent'},@{Snapshot='other-instance'},@{Snapshot='other-pid'}) {
        param($Snapshot)
        switch ($Snapshot) {
            absent { $script:expected.nativeLaunchProof=$null }
            other-instance { $script:launch.instanceId=('f'*32) }
            other-pid { $script:launch.pid=999 }
        }
        (Invoke-MissingStateRecovery).instanceId | Should -Be ('b'*32)
        Should -Invoke Stop-NativeProcessForSafety -Times 0 -Exactly
        Should -Invoke Release-ItlOnDemandManagedPortLease -Times 0 -Exactly
        $script:sequence.ToArray() | Should -Be @('start')
    }

    It 'refuses the replacement while its own launched process keeps running' {
        Mock Wait-ItlOnDemandProcessExit { $false }
        { Invoke-MissingStateRecovery } | Should -Throw '*ITL_ONDEMAND_STOP_FAILED*'
        Should -Invoke Release-ItlOnDemandManagedPortLease -Times 0 -Exactly
        Should -Invoke Start-ItlOnDemandBackendInstance -Times 0 -Exactly
    }
}

Describe 'On-demand port ownership recovery contract' {
    BeforeEach {
        $script:savedRoot=$script:ProjectRoot
        $script:ProjectRoot=Join-Path $TestDrive ('Владелец порта с пробелом '+[guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $script:ProjectRoot | Out-Null
        $script:ownership='owned'
        $script:ownershipCalls=[Collections.Generic.List[object]]::new()
        $script:stops=[Collections.Generic.List[int]]::new()
        $script:processAlive=$true
        $script:record=[pscustomobject]@{
            schemaVersion=4;status='readiness';family='roctup';instanceId=('e'*32);pid=24208;port=6003;catalogSha256=('c'*64)
            processStartTime='2026-11-03T01:00:00.0000000Z';executablePath='C:\Платформа теста\1cv8c.exe'
            ownershipMarkers=@('C:\База ROCTUP','port=6003');infoBaseKind='file';infoBasePath='C:\Целевая база'
            managerInfoBaseKind='file';managerInfoBasePath='C:\Целевая база';portFamily='roctup-mcp';portKey='roctup-key';portLeaseToken='roctup-token'
            testClientPid=0;testClientPort=0;readiness='tcp-port-owner-verified';readinessAt='2026-11-03T01:00:00.0000000Z';portOwnerPidVerified=$true
        }
        function Save-OwnershipFixtureState { param([object]$State) Invoke-WithItlOnDemandRuntimeMutation -Family $State.family -InstanceIds @($State.instanceId) -OwnerFunction Write-ItlOnDemandRuntimeState -OwnerArguments @{RuntimeState=$State} | Out-Null }
        Save-OwnershipFixtureState $script:record
        Mock Get-ItlOnDemandPortOwnership {
            param($Port,$ProcessId,$RetryUntil,[switch]$TestClient)
            $script:ownershipCalls.Add([pscustomobject]@{port=$Port;pid=$ProcessId;retry=$RetryUntil})
            $status=$(if($script:ownership -in @('owned','foreign')){'proven'}else{$script:ownership})
            [pscustomobject]@{decision=$script:ownership;status=$status;owners=@();diagnostic="decision=$($script:ownership) expectedPid=$ProcessId status=$status source=none address=127.0.0.1:$Port rows(state/pid/remote)=[0/24208/0] connection=timeout attempts=12 elapsedMs=3010"}
        }
        Mock Get-ItlOnDemandProcessOwnershipProof { [pscustomobject]@{owned=$script:processAlive;failedPredicate='';expected='';actual=''} }
        Mock Test-ItlOnDemandOwnedProcess { $script:processAlive }
        Mock Get-Process { param($Id) if($script:processAlive -and [int](@($Id)[0]) -eq 24208){[pscustomobject]@{Id=24208;StartTime=[datetime]'2026-11-03T01:00:00Z'}} }
        Mock Get-ItlOnDemandOwnedTestClientProcesses { @() }
        Mock Stop-Process { param($Id) $script:stops.Add([int](@($Id)[0])); $script:processAlive=$false }
        Mock Wait-ItlOnDemandProcessExit { -not $script:processAlive }
        Mock Test-TcpPortOpen { $script:processAlive }
        Mock Release-ItlOnDemandManagedPortLease {}
        Mock Set-ItlOnDemandManagedPortLeaseStatus {}
        Mock Get-ItlOnDemandManagedPortLeaseMatches { [pscustomobject]@{port=6003;pid=24208} }
    }
    AfterEach { $script:ProjectRoot=$script:savedRoot }

    It 'marks an unproven mark-running start-unconfirmed and owned recovery restarts it' {
        Mock Start-ItlOnDemandBackendInstance { param($Family,$InstanceId) [pscustomobject]@{family=$Family;instanceId=$InstanceId;pid=24300;port=6004;status='readiness'} }
        $script:ownership='unknown'
        { Confirm-ItlOnDemandBackendRunning -Family roctup -InstanceId ('e'*32) -ExpectedPid 24208 -ExpectedPort 6003 -CatalogSha256 ('c'*64) } |
            Should -Throw '*ITL_ONDEMAND_READINESS_IDENTITY_UNVERIFIED: port 6003*start-unconfirmed*Port evidence: decision=unknown*rows(state/pid/remote)=*attempts=12 elapsedMs=*'
        @($script:ownershipCalls | Where-Object { $null -ne $_.retry }).Count | Should -Be 1
        $marked=Read-ItlOnDemandRuntimeState roctup ('e'*32)
        $marked.status | Should -Be 'start-unconfirmed'
        $marked.pid | Should -Be 24208
        $health=Get-ItlOnDemandBackendRuntimeHealth -RuntimeState $marked
        $health.stale | Should -BeTrue
        $health.status | Should -Be 'owned-start-unconfirmed'
        $replacement=Recover-ItlOnDemandBackendInstance -Family roctup -InstanceId ('e'*32) -ReplacementInstanceId ('f'*32) -ExpectedPid 24208 -ExpectedPort 6003 -CatalogSha256 ('c'*64)
        $replacement.instanceId | Should -Be ('f'*32)
        $replacement.status | Should -Be 'readiness'
        @($script:stops) | Should -Be @(24208)
        Read-ItlOnDemandRuntimeState roctup ('e'*32) | Should -BeNullOrEmpty
    }

    It 'never treats readiness without the marker as stale, whatever its age, and keeps a backend on a transient probe failure' {
        Mock Start-ItlOnDemandBackendInstance { throw 'a healthy backend must not be restarted' }
        $script:ownership='unknown'
        $current=Read-ItlOnDemandRuntimeState roctup ('e'*32)
        ([DateTime]::UtcNow - [DateTimeOffset]::Parse($current.readinessAt).UtcDateTime).TotalHours | Should -BeGreaterThan 24
        $health=Get-ItlOnDemandBackendRuntimeHealth -RuntimeState $current
        $health.stale | Should -BeFalse
        $health.status | Should -Be 'owned-pid-port-unverified'
        $health.portDiagnostic | Should -Match 'decision=unknown'
        { Recover-ItlOnDemandBackendInstance -Family roctup -InstanceId ('e'*32) -ReplacementInstanceId ('f'*32) -ExpectedPid 24208 -ExpectedPort 6003 -CatalogSha256 ('c'*64) } |
            Should -Throw '*ITL_ONDEMAND_RECOVERY_NOT_STALE: status=owned-pid-port-unverified*Port evidence: decision=unknown*'
        $script:ownership='owned'
        (Get-ItlOnDemandBackendRuntimeHealth -RuntimeState $current).status | Should -Be 'healthy'
        $script:stops.Count | Should -Be 0
        (Read-ItlOnDemandRuntimeState roctup ('e'*32)).status | Should -Be 'readiness'
        Should -Invoke Start-ItlOnDemandBackendInstance -Times 0 -Exactly
    }

    It 'keeps the process on an unknown stop owner and its continuation completes the original call' {
        $script:ownership='unknown'
        $message=''
        try { Stop-ItlOnDemandBackendInstance -Family roctup -InstanceId ('e'*32) -StrictOwnership -ExpectedRuntimeState $script:record | Out-Null } catch { $message=$_.Exception.Message }
        $message | Should -Match '^ITL_ONDEMAND_STOP_PORT_OWNER_UNVERIFIED: backend port 6003 owner could not be proven for PID 24208; no process was stopped'
        $message | Should -Match 'start-unconfirmed'
        $message | Should -Match 'call itl_recover_connection again'
        $message | Should -Match 'refresh-dev-branch-lite'
        $message | Should -Match 'Port evidence: decision=unknown .*source=none .*attempts=12'
        $message | Should -Not -Match 'STOP_PORT_OWNER_CHANGED'
        $script:stops.Count | Should -Be 0
        $script:processAlive | Should -BeTrue
        (Read-ItlOnDemandRuntimeState roctup ('e'*32)).status | Should -Be 'start-unconfirmed'
        Should -Invoke Release-ItlOnDemandManagedPortLease -Times 0 -Exactly

        # itl_recover_connection: the same exact owned stop, then a fresh start
        # and protocol confirmation for the original call.
        $script:ownership='owned'
        (Stop-ItlOnDemandBackendInstance -Family roctup -InstanceId ('e'*32) -StrictOwnership -ExpectedRuntimeState $script:record).status | Should -Be 'stopped'
        @($script:stops) | Should -Be @(24208)
        $fresh=$script:record|ConvertTo-Json -Depth 8|ConvertFrom-Json
        $fresh.pid=24300
        Save-OwnershipFixtureState $fresh
        $script:processAlive=$true
        $confirmed=Confirm-ItlOnDemandBackendRunning -Family roctup -InstanceId ('e'*32) -ExpectedPid 24300 -ExpectedPort 6003 -CatalogSha256 ('c'*64)
        $confirmed.status | Should -Be 'running'
        (Read-ItlOnDemandRuntimeState roctup ('e'*32)).status | Should -Be 'running'
    }

    It 'preserves a proven foreign listener with the distinct changed-owner code' {
        $script:ownership='foreign'
        { Stop-ItlOnDemandBackendInstance -Family roctup -InstanceId ('e'*32) -StrictOwnership -ExpectedRuntimeState $script:record } | Should -Throw 'ITL_ONDEMAND_STOP_PORT_OWNER_CHANGED: preserve the foreign manager listener. Port evidence: decision=foreign*'
        $script:stops.Count | Should -Be 0
        (Read-ItlOnDemandRuntimeState roctup ('e'*32)).status | Should -Be 'readiness'
    }

    Context 'registered backend has exited (close_1c_session, crash or PID reuse)' {
        BeforeEach {
            $script:processAlive=$false
            $script:proofPredicate='process-present'
            $script:ownership='unknown'
            $script:portOwners=@()
            $script:nativeCommandLine=''
            Mock Get-ItlOnDemandProcessOwnershipProof { [pscustomobject]@{owned=$false;failedPredicate=$script:proofPredicate;expected='';actual=''} }
            Mock Get-ItlOnDemandPortOwnership {
                param($Port,$ProcessId,$RetryUntil,[switch]$TestClient)
                $status=$(if($script:ownership -in @('owned','foreign')){'proven'}else{$script:ownership})
                [pscustomobject]@{decision=$script:ownership;status=$status;owners=@($script:portOwners);diagnostic="decision=$($script:ownership) expectedPid=$ProcessId status=$status source=none address=127.0.0.1:$Port rows(state/pid/remote)=[0/0/63078,2/0/53750] connection=timeout attempts=3 elapsedMs=3424"}
            }
            Mock Get-Process { param($Id) $id=[int](@($Id)[0]); if($id -eq 5555 -or ($id -eq 24208 -and $script:proofPredicate -eq 'processStartTime')){[pscustomobject]@{Id=$id;StartTime=[datetime]'2026-11-11T01:27:00Z'}} }
            Mock Get-CimInstance { [pscustomobject]@{ProcessId=5555;ExecutablePath='C:\Платформа теста\1cv8c.exe';CommandLine=$script:nativeCommandLine} }
            Mock Stop-Process { param($Id) $script:stops.Add([int](@($Id)[0])) }
            Mock Wait-ItlOnDemandProcessExit { $true }
            # A listener left behind still accepts: the stop must not depend on it.
            Mock Test-TcpPortOpen { $script:stops.Count -eq 0 }
        }

        It 'retires the instance with a residual PID-0 listener and stops nothing' {
            $result=Stop-ItlOnDemandBackendInstance -Family roctup -InstanceId ('e'*32) -StrictOwnership -ExpectedRuntimeState $script:record
            $result.status | Should -Be 'stopped'
            $script:stops.Count | Should -Be 0
            Read-ItlOnDemandRuntimeState roctup ('e'*32) | Should -BeNullOrEmpty
            Should -Invoke Release-ItlOnDemandManagedPortLease -Times 1 -Exactly
        }

        It 'retires the instance and leaves a foreign listener on its port running' {
            $script:ownership='foreign'; $script:portOwners=@(5555)
            $script:nativeCommandLine='"C:\Платформа теста\1cv8c.exe" ENTERPRISE /F "C:\Другая база"'
            (Stop-ItlOnDemandBackendInstance -Family roctup -InstanceId ('e'*32) -StrictOwnership -ExpectedRuntimeState $script:record).status | Should -Be 'stopped'
            $script:stops.Count | Should -Be 0
            Read-ItlOnDemandRuntimeState roctup ('e'*32) | Should -BeNullOrEmpty
        }

        It 'stops the same backend restarted under a new PID by its exact markers' {
            $script:ownership='foreign'; $script:portOwners=@(5555)
            $script:nativeCommandLine='"C:\Платформа теста\1cv8c.exe" ENTERPRISE /F "C:\База ROCTUP" /C "startup;mode=embedded;port=6003"'
            (Stop-ItlOnDemandBackendInstance -Family roctup -InstanceId ('e'*32) -StrictOwnership -ExpectedRuntimeState $script:record).status | Should -Be 'stopped'
            @($script:stops) | Should -Be @(5555)
            Read-ItlOnDemandRuntimeState roctup ('e'*32) | Should -BeNullOrEmpty
        }

        It 'never treats a longer port number as the restarted backend marker' {
            $script:ownership='foreign'; $script:portOwners=@(5555)
            $script:nativeCommandLine='"C:\Платформа теста\1cv8c.exe" ENTERPRISE /F "C:\База ROCTUP" /C "startup;mode=embedded;port=60031"'
            (Stop-ItlOnDemandBackendInstance -Family roctup -InstanceId ('e'*32) -StrictOwnership -ExpectedRuntimeState $script:record).status | Should -Be 'stopped'
            $script:stops.Count | Should -Be 0
        }

        It 'retires a registration whose PID now names another process start' {
            $script:proofPredicate='processStartTime'
            (Stop-ItlOnDemandBackendInstance -Family roctup -InstanceId ('e'*32) -StrictOwnership -ExpectedRuntimeState $script:record).status | Should -Be 'stopped'
            $script:stops.Count | Should -Be 0
            Read-ItlOnDemandRuntimeState roctup ('e'*32) | Should -BeNullOrEmpty
        }

        It 'reports an exited or reused backend stale for owned recovery whatever its port shows' {
            Mock Test-ItlOnDemandOwnedProcess { $false }
            $health=Get-ItlOnDemandBackendRuntimeHealth -RuntimeState $script:record
            $health.stale | Should -BeTrue
            $health.status | Should -Be 'pid-dead-port-unverified'
            $script:ownership='foreign'
            (Get-ItlOnDemandBackendRuntimeHealth -RuntimeState $script:record).status | Should -Be 'pid-dead-port-open'
            $script:proofPredicate='processStartTime'
            $reused=Get-ItlOnDemandBackendRuntimeHealth -RuntimeState $script:record
            $reused.stale | Should -BeTrue
            $reused.status | Should -Be 'pid-reused'
        }
    }

    It 'never returns a start-unconfirmed instance to the broker on ensure' {
        Mock Read-CurrentDevBranchStateForRoctupMcp { [pscustomobject]@{devBranchInfoBasePath='C:\Целевая база';infoBaseKind='file'} }
        Mock Assert-DevBranchApplicationReady { param($State) $State }
        Mock Stop-ItlOnDemandBackendInstance { throw 'STOP-BEFORE-FRESH-START' }
        $marked=$script:record|ConvertTo-Json -Depth 8|ConvertFrom-Json
        $marked.status='start-unconfirmed'
        Save-OwnershipFixtureState $marked
        { Start-ItlOnDemandBackendInstance -Family roctup -InstanceId ('e'*32) -CatalogSha256 ('c'*64) } | Should -Throw '*STOP-BEFORE-FRESH-START*'
        Should -Invoke Get-ItlOnDemandPortOwnership -Times 0 -Exactly
        Save-OwnershipFixtureState $script:record
        $reused=Start-ItlOnDemandBackendInstance -Family roctup -InstanceId ('e'*32) -CatalogSha256 ('c'*64)
        $reused.status | Should -Be 'readiness'
        $reused.pid | Should -Be 24208
    }
}
