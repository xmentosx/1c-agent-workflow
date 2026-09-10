Describe 'Native TestClient ownership after losing its launcher ancestry' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        . $context.HelperPath -ProjectRoot $context.RepoRoot -Action help *> $null
    }
    BeforeEach {
        $script:runRoot = Join-Path $TestDrive 'Два клиента с пробелом'
        [void][IO.Directory]::CreateDirectory($runRoot)
        $script:paramsPath = Join-Path $runRoot 'VAParams.json'
        $script:resources = @(@{kind='file';path=(Join-Path $runRoot 'Менеджер')},@{kind='file';path=(Join-Path $runRoot 'База А')},@{kind='file';path=(Join-Path $runRoot 'База Б')})
        $settings = @{КлиентТестирования=@{ДанныеКлиентовТестирования=@(
            @{Имя='A';ПутьКИнфобазе=('/F "'+$resources[1].path+'"');ПортЗапускаТестКлиента=53941},
            @{Имя='B';ПутьКИнфобазе=('/F "'+$resources[2].path+'"');ПортЗапускаТестКлиента=53942}
        )}}
        [IO.File]::WriteAllText($paramsPath,($settings | ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($true))
        $script:scopes = @(Get-OneCNativeRunProcessScopes -RunParamsPath $paramsPath -Resources $resources)
        # Retain the observed B client on A's port; the intermediate parent is absent.
        $script:orphan = [pscustomobject]@{Name='1cv8c.exe';ProcessId=27584;ParentProcessId=31796;CommandLine=('"C:\1c\1cv8c.exe" ENTERPRISE /F "'+$resources[2].path+'" /TESTCLIENT -TPort 53941 /Out"'+(Join-Path $runRoot 'itl-channel-b_20260910090821.txt')+'"')}
        $script:foreign = [pscustomobject]@{Name='1cv8c.exe';ProcessId=6200;ParentProcessId=1;CommandLine=$orphan.CommandLine.Replace($runRoot,($runRoot+' соседний запуск'))}
        # Keep the same base and port while changing only the run-owned Out path.
        $foreign.CommandLine = $foreign.CommandLine.Replace(($resources[2].path.Replace($runRoot,($runRoot+' соседний запуск'))),$resources[2].path)
        $script:inventory = @($orphan,$foreign)
        Mock Receive-DesignerProcessEnumeration { [pscustomobject]@{status='completed';processes=$script:inventory;infoBaseReleaseChecked=$false;infoBaseReleased=$false} }
        $script:probeContext = [pscustomobject]@{processId=3040;launcherExited=$true}
    }
    It 'reproduces the original ancestry-only probe reporting release despite the surviving run-owned B client' {
        $probe = New-DesignerInvocationProbeState -LauncherProcessId 3040
        Test-OneCNativeInvocationReleased -ProbeState $probe -ProbeContext $probeContext -LogPath '' | Should -BeFalse
        $probe.processesReleasedSinceUtc = [DateTime]::UtcNow.AddSeconds(-2)
        $probe.nextProcessCheckAtUtc = [DateTime]::MinValue
        Test-OneCNativeInvocationReleased -ProbeState $probe -ProbeContext $probeContext -LogPath '' | Should -BeTrue
    }
    It 'retains ownership by the captured run scope when the intermediate launcher is absent' {
        $probe = New-DesignerInvocationProbeState -LauncherProcessId 3040 -OwnedProcessScopes $scopes
        Test-OneCNativeInvocationReleased -ProbeState $probe -ProbeContext $probeContext -LogPath '' | Should -BeFalse
        $probe.lastProcessState.processIds | Should -Contain 27584
        $probe.lastProcessState.processIds | Should -Not -Contain 6200
        $probe.processesReleaseConfirmed | Should -BeFalse
    }
    It 'requires fresh empty observations after the owned client exits and leaves the foreign same-base session alone' {
        $probe = New-DesignerInvocationProbeState -LauncherProcessId 3040 -OwnedProcessScopes $scopes
        Test-OneCNativeInvocationReleased -ProbeState $probe -ProbeContext $probeContext -LogPath '' | Should -BeFalse
        $script:inventory = @($foreign)
        $probe.nextProcessCheckAtUtc = [DateTime]::MinValue
        Test-OneCNativeInvocationReleased -ProbeState $probe -ProbeContext $probeContext -LogPath '' | Should -BeFalse
        $probe.processesReleasedSinceUtc = [DateTime]::UtcNow.AddSeconds(-2)
        $probe.nextProcessCheckAtUtc = [DateTime]::MinValue
        Test-OneCNativeInvocationReleased -ProbeState $probe -ProbeContext $probeContext -LogPath '' | Should -BeTrue
        $probe.lastProcessState.processIds | Should -HaveCount 0
    }
    It 'ignores changed file contents after capturing the immutable run binding' {
        [IO.File]::WriteAllText($paramsPath,'{}')
        Test-OneCNativeProcessInRunScopes -ProcessInfo $orphan -Scopes $scopes | Should -BeTrue
    }
    It 'rejects a client targeting a database outside the reserved resource set' {
        { Get-OneCNativeRunProcessScopes -RunParamsPath $paramsPath -Resources @($resources[0],$resources[1]) } | Should -Throw '*TARGET_NOT_RESERVED*'
    }
    It 'excludes another port or role even when the database and output belong to this run: <change>' -TestCases @(
        @{change='port'},@{change='role'}
    ) {
        param($change)
        $orphan.CommandLine = if ($change -eq 'port') { $orphan.CommandLine.Replace('53941','53943') } else { $orphan.CommandLine.Replace('/TESTCLIENT','') }
        Test-OneCNativeProcessInRunScopes -ProcessInfo $orphan -Scopes $scopes | Should -BeFalse
    }

    It 'cleans every captured target through Enterprise and reconciles only after the orphan exits: <failure>' -TestCases @(
        @{failure='none'},@{failure='exit'},@{failure='cleanup'},@{failure='parameters'},@{failure='callback'},@{failure='selected'}
    ) {
        param($failure)
        $script:fixtureFailure = $failure
        if ($failure -eq 'callback') { $script:inventory = @($foreign) }
        $script:OneCNativeOperationJournal = New-OneCNativeOperationJournal
        $script:Config = [pscustomobject]@{logsPath=(Join-Path $runRoot 'logs')}
        Mock Resolve-EnterpriseClientExecutablePath { 'fake.exe' }
        Mock Assert-InfoBaseAvailable {}
        Mock Publish-Agent1cLifecycleOperationProcessEvidence {}
        Mock Invoke-OneCSessionAdmissionSet {
            param($Admissions,$StartProcess)
            if ($script:fixtureFailure -eq 'parameters') { [IO.File]::WriteAllText($script:paramsPath,'{}') }
            & $StartProcess
        }
        Mock Start-Process {
            $process = [pscustomobject]@{Id=3040;HasExited=$true;ExitCode=$(if ($script:fixtureFailure -eq 'exit') {7} else {0})}
            $process | Add-Member ScriptMethod Refresh {}
            $process | Add-Member ScriptMethod WaitForExit { param([int]$Milliseconds) $true }
            return $process
        }
        Mock Get-OneCProcessInfo { $script:inventory }
        Mock Stop-Process {
            param($Id)
            if ($script:fixtureFailure -eq 'cleanup') { throw 'access denied fixture' }
            $script:inventory = @($script:inventory | Where-Object { @($Id) -notcontains $_.ProcessId })
        }
        $admissions = @($resources | Select-Object -Skip 1 | ForEach-Object {
            [pscustomobject]@{infoBaseKind=$_.kind;infoBasePath=$_.path;requiredSessions=1;expectedChildRole='test-client';purpose='fixture'}
        })
        $runResources = @()
        if ($failure -eq 'selected') {
            $admissions = @($admissions[0])
            $runResources = @($resources[1],$resources[2])
        }
        $errorMessage = ''
        try {
            Invoke-Enterprise -InfoBaseKind file -InfoBasePath $resources[0].path -TestClientPort 53941 `
                -EnterpriseArgs @('/Execute','fixture.epf',('/C' + (New-VanessaStartFeaturePlayerCommand -ParamsPath $paramsPath))) `
                -AdditionalSessionAdmissions $admissions -AdditionalRunResources $runResources -RunParamsPath $paramsPath `
                -RequireOwnedProcessRelease:($failure -eq 'callback') `
                -OwnedProcessCleanup {
                    param($capturedScopes)
                    if ($script:fixtureFailure -eq 'callback') { throw 'callback cleanup failure' }
                    Stop-OwnVanessaRunScopeProcesses -Scopes $capturedScopes
                } `
                -TimeoutSeconds 5 6>$null | Out-Null
        } catch { $errorMessage = $_.Exception.Message }
        $record = $script:OneCNativeOperationJournal.entries[0]
        $record.ownedProcessScopes | Should -HaveCount 3
        @($script:inventory | Where-Object ProcessId -eq 6200) | Should -HaveCount 1
        Should -Invoke Stop-Process -Times 0 -ParameterFilter { $Id -eq 6200 }
        if ($failure -eq 'parameters') {
            $errorMessage | Should -Match 'ONEC_NATIVE_RUN_PARAMETERS_CHANGED_BEFORE_LAUNCH'
            Should -Invoke Start-Process -Times 0
            Should -Invoke Stop-Process -Times 0
            $record.startAttempted | Should -BeFalse
        } elseif ($failure -in @('cleanup','callback')) {
            $errorMessage | Should -Match $(if ($failure -eq 'callback') {'callback cleanup failure'} else {'VANESSA_RUN_SCOPE_CLEANUP_UNCONFIRMED'})
            Test-OneCNativeOperationJournalReleased $script:OneCNativeOperationJournal | Should -BeFalse
        } else {
            if ($failure -in @('none','selected')) { $errorMessage | Should -Be '' }
            else { $errorMessage | Should -Match 'exit code 7' }
            Test-OneCNativeOperationJournalReleased $script:OneCNativeOperationJournal | Should -BeTrue
            $record.releaseEvidence | Should -Be 'native-run-scoped-process-release'
            Should -Invoke Stop-Process -Times 1 -ParameterFilter { $Id -eq 27584 }
            if ($failure -eq 'selected') { $record.admissions | Should -HaveCount 2 }
        }
    }
}
