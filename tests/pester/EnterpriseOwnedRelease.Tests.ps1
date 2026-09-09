BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSupport.ps1')
    $context = Initialize-WorkflowPesterContext
    $script:EnterpriseReleaseHelper = $context.HelperPath

    function Invoke-EnterpriseReleaseFixture {
        param([string]$Failure = '', [switch]$ApplicationProbe, [switch]$Ordinary, [int]$GraceSeconds = 10)
        $root = Join-Path $TestDrive (([guid]::NewGuid().ToString('N')) + '/Обновление базы с пробелом')
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        & {
            param($Root, $Failure, $ApplicationProbe, $Ordinary, $GraceSeconds)
            . $script:EnterpriseReleaseHelper -ProjectRoot $Root -Action help *> $null
            $script:OneCNativeOperationJournal = New-OneCNativeOperationJournal
            $script:EnterpriseApplicationProbes = 0
            $script:EnterpriseInventoryReads = 0
            $script:Config = [pscustomobject]@{ logsPath = 'logs'; completionPostExitTimeoutSeconds = 5 }
            function Resolve-EnterpriseClientExecutablePath { 'fake.exe' }
            function Assert-InfoBaseAvailable {}
            function Invoke-OneCSessionAdmissionSet { param($Admissions, $StartProcess) & $StartProcess }
            function Get-CompletionPostExitTimeoutSeconds { 3 }
            function Publish-Agent1cLifecycleOperationProcessEvidence {}
            function Start-Process {
                if ($Failure -eq 'launch') { throw 'native start outcome unknown' }
                $process = [pscustomobject]@{ Id = 6100; HasExited = $true; ExitCode = $(if ($Failure -eq 'exit') { 7 } else { 0 }) }
                $process | Add-Member ScriptMethod Refresh {}
                $process | Add-Member ScriptMethod WaitForExit { param([int]$Milliseconds) $true }
                return $process
            }
            function Receive-DesignerProcessEnumeration {
                param($ProbeState, $LogPath)
                $script:EnterpriseInventoryReads++
                if ($Failure -eq 'pending-scans' -and ($script:EnterpriseInventoryReads % 2) -eq 1) {
                    return [pscustomobject]@{ status = 'pending' }
                }
                $inventory = @([pscustomobject]@{ Name = '1cv8c.exe'; ProcessId = 6200; ParentProcessId = 1; CommandLine = 'ENTERPRISE /Out foreign.log' })
                if ($Failure -eq 'child' -or ($Failure -eq 'delayed-child' -and $script:EnterpriseInventoryReads -gt 1)) {
                    $inventory += [pscustomobject]@{ Name = '1cv8c.exe'; ProcessId = 6101; ParentProcessId = 6100; CommandLine = 'ENTERPRISE' }
                }
                [pscustomobject]@{ status = 'completed'; processes = $inventory; infoBaseReleaseChecked = $false; infoBaseReleased = $false }
            }
            $probe = if ($ApplicationProbe) {
                { param($probeContext) $script:EnterpriseApplicationProbes++; return ($Failure -ne 'application') }
            } else { $null }
            $errorMessage = ''
            try {
                Invoke-Enterprise -InfoBaseKind file -InfoBasePath $Root -EnterpriseArgs @('/Execute', 'fixture.epf') `
                    -RequireOwnedProcessRelease:(-not $Ordinary) -CompletionProbe $probe -CompletionGraceSeconds $GraceSeconds -TimeoutSeconds 5 6>$null | Out-Null
            } catch { $errorMessage = $_.Exception.Message }
            [pscustomobject]@{
                error = $errorMessage
                released = (Test-OneCNativeOperationJournalReleased $script:OneCNativeOperationJournal)
                records = $script:OneCNativeOperationJournal.entries.Count
                inventoryReads = $script:EnterpriseInventoryReads
                applicationProbes = $script:EnterpriseApplicationProbes
            }
        } $root $Failure ([bool]$ApplicationProbe) ([bool]$Ordinary) $GraceSeconds
    }
}

Describe 'Enterprise normalization requires its owned native processes to finish' {
    It 'completes with an unrelated client still present and preserves the application probe' {
        $result = Invoke-EnterpriseReleaseFixture -ApplicationProbe -GraceSeconds 0
        $result.error | Should -Be ''
        $result.released | Should -BeTrue
        $result.records | Should -Be 1
        $result.applicationProbes | Should -BeGreaterThan 0
        $result.inventoryReads | Should -BeGreaterThan 0
    }
    It 'keeps the native reservation when a child survives launcher exit' {
        $result = Invoke-EnterpriseReleaseFixture -Failure child
        $result.error | Should -Match '^ENTERPRISE_OWNED_PROCESS_RELEASE_TIMEOUT'
        $result.released | Should -BeFalse
    }
    It 'does not turn a nonzero launcher exit into success when the release probe succeeds' {
        $result = Invoke-EnterpriseReleaseFixture -Failure exit
        $result.error | Should -Match 'failed with exit code 7'
        $result.released | Should -BeTrue
    }
    It 'confirms release across pending asynchronous scans without accepting a cached result' {
        $result = Invoke-EnterpriseReleaseFixture -Failure pending-scans
        $result.error | Should -Be ''
        $result.released | Should -BeTrue
        $result.inventoryReads | Should -BeGreaterThan 3
    }
    It 'requires a fresh second observation and detects a delayed owned child' {
        $result = Invoke-EnterpriseReleaseFixture -Failure delayed-child
        $result.error | Should -Match '^ENTERPRISE_OWNED_PROCESS_RELEASE_TIMEOUT'
        $result.released | Should -BeFalse
        $result.inventoryReads | Should -BeGreaterThan 1
    }
    It 'preserves application stability across pending native scans' {
        $result = Invoke-EnterpriseReleaseFixture -Failure pending-scans -ApplicationProbe -GraceSeconds 2
        $result.error | Should -Be ''
        $result.released | Should -BeTrue
        $result.applicationProbes | Should -BeGreaterThan 1
    }
    It 'retains an uncertain launch without an observed process' {
        $result = Invoke-EnterpriseReleaseFixture -Failure launch
        $result.error | Should -Match 'native start outcome unknown'
        $result.released | Should -BeFalse
    }
    It 'does not override an unmet application completion condition' {
        $result = Invoke-EnterpriseReleaseFixture -Failure application -ApplicationProbe
        $result.error | Should -Match '^ENTERPRISE_OWNED_PROCESS_RELEASE_TIMEOUT'
        $result.released | Should -BeTrue
    }
    It 'keeps ordinary Enterprise calls free of implicit descendant waiting' {
        $result = Invoke-EnterpriseReleaseFixture -Ordinary
        $result.error | Should -Be ''
        $result.inventoryReads | Should -Be 0
        $result.released | Should -BeFalse
    }
}
