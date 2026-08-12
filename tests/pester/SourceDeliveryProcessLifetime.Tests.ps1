BeforeAll { . (Join-Path $PSScriptRoot "SourceDelivery.TestSupport.ps1") }

Describe "Source develop queue and delivery" {
It "fails fast below Windows 10 or Windows Server 2016 before using atomic job-list launch" {
        $startDefinition = Get-DeliveryFunctionDefinitions -Names @('Start-DeliveryProcess') | Select-Object -First 1
        $startDefinition.Extent.Text | Should -Match 'AssertAtomicJobListSupport\(\);\s*IntPtr job = CreateJobObject'
        $startDefinition.Extent.Text | Should -Match 'RtlGetVersion'
        $startDefinition.Extent.Text | Should -Match 'requires Windows 10 or Windows Server 2016\+'
        $startDefinition.Extent.Text | Should -Not -Match 'PlatformNotSupportedException[\s\S]+Start-Process'
    }

It "owns the publication gate tree across forced wrapper termination" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl delivery cancel путь " + [guid]::NewGuid().ToString("N"))
        $wrapper = $null; $gatePid = 0; $childPid = 0
        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            $gatePath = Join-Path $tempRoot "interrupt-gate.ps1"
            Set-Content -LiteralPath $gatePath -Encoding UTF8 -Value @'
param([string]$Mode)
$payload = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes('while ($true) { Start-Sleep -Seconds 1 }'))
$child = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoLogo', '-NoProfile', '-EncodedCommand', $payload) -WindowStyle Hidden -PassThru
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'child.pid'), [string]$child.Id, [Text.UTF8Encoding]::new($false))
while ($true) { Start-Sleep -Seconds 1 }
'@
            $functions = @(Get-DeliveryFunctionDefinitions -Names @('Stop-DeliveryProcessTree', 'Start-DeliveryProcess', 'Close-DeliveryProcessJob', 'Invoke-SourceGate', 'Invoke-ComponentPublicationFinalizer'))
            $stopDefinition = $functions | Where-Object Name -eq 'Stop-DeliveryProcessTree' | Select-Object -First 1
            $startDefinition = $functions | Where-Object Name -eq 'Start-DeliveryProcess' | Select-Object -First 1
            $closeJobDefinition = $functions | Where-Object Name -eq 'Close-DeliveryProcessJob' | Select-Object -First 1
            $gateDefinition = $functions | Where-Object Name -eq 'Invoke-SourceGate' | Select-Object -First 1
            $finalizerDefinition = $functions | Where-Object Name -eq 'Invoke-ComponentPublicationFinalizer' | Select-Object -First 1
            $stopDefinition | Should -Not -BeNullOrEmpty
            $startDefinition.Extent.Text | Should -Match 'JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE'
            $startDefinition.Extent.Text | Should -Match 'PROC_THREAD_ATTRIBUTE_JOB_LIST'
            $startDefinition.Extent.Text | Should -Match 'EXTENDED_STARTUPINFO_PRESENT'
            $startDefinition.Extent.Text | Should -Not -Match 'AssignProcessToJobObject'
            $closeJobDefinition.Extent.Text | Should -Match 'Stop-DeliveryProcessTree -Process \$Process'
            $closeJobDefinition.Extent.Text | Should -Match 'publication cannot continue'
            $closeJobDefinition.Extent.Text | Should -Not -Match 'Write-Warning'
            $gateDefinition.Extent.Text | Should -Match 'Start-DeliveryProcess -ArgumentList'
            $gateDefinition.Extent.Text | Should -Match 'finally\s*\{[\s\S]+Close-DeliveryProcessJob -JobHandle \$processJob -Process \$process -PriorErrorMessage \$gateError'
            $finalizerDefinition.Extent.Text | Should -Match 'Start-DeliveryProcess -ArgumentList'
            $finalizerDefinition.Extent.Text | Should -Match 'finally\s*\{[\s\S]+Close-DeliveryProcessJob -JobHandle \$processJob -Process \$process -PriorErrorMessage \$finalizerError'
            $finalizerDefinition.Extent.Text | Should -Not -Match 'Start-Process[^\r\n]+-Wait'

            $escapedRoot = $tempRoot.Replace("'", "''")
            $escapedGate = $gatePath.Replace("'", "''")
            $runspaceBody = @(
                $stopDefinition.Extent.Text
                $startDefinition.Extent.Text
                $closeJobDefinition.Extent.Text
                $gateDefinition.Extent.Text
                @'
function Update-DeliveryOperation {
    param([hashtable]$Values)
    if ($Values.ContainsKey('gatePid') -and [int]$Values.gatePid -gt 0) {
        [IO.File]::WriteAllText((Join-Path $script:TestRoot 'gate.pid'), [string]$Values.gatePid, [Text.UTF8Encoding]::new($false))
    }
}
function Write-DeliveryRunRecord { return 'test-run.json' }
'@
                "`$script:Root = '$escapedRoot'"
                "`$script:GateScript = '$escapedGate'"
                "`$script:TestRoot = '$escapedRoot'"
                '$CoverageContract = @(); $AiRulesSource = ""; $E2EProjectRoot = ""; $ReleaseResumeMode = "Auto"'
                "Invoke-SourceGate -Mode 'Develop' -WorkingRoot '$escapedRoot'"
            ) -join [Environment]::NewLine
            $wrapperPath = Join-Path $tempRoot 'delivery-wrapper.ps1'
            [IO.File]::WriteAllText($wrapperPath, ($runspaceBody + [Environment]::NewLine), [Text.UTF8Encoding]::new($true))
            $wrapperStdout = Join-Path $tempRoot 'wrapper.stdout.log'; $wrapperStderr = Join-Path $tempRoot 'wrapper.stderr.log'
            $wrapper = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $wrapperPath + '"')) -WindowStyle Hidden -RedirectStandardOutput $wrapperStdout -RedirectStandardError $wrapperStderr -PassThru
            $null = $wrapper.Handle

            $gatePidPath = Join-Path $tempRoot 'gate.pid'; $childPidPath = Join-Path $tempRoot 'child.pid'
            $readyDeadline = [DateTime]::UtcNow.AddSeconds(15)
            while ([DateTime]::UtcNow -lt $readyDeadline -and (-not (Test-Path -LiteralPath $gatePidPath) -or -not (Test-Path -LiteralPath $childPidPath))) { Start-Sleep -Milliseconds 100 }
            Test-Path -LiteralPath $gatePidPath | Should -BeTrue
            Test-Path -LiteralPath $childPidPath | Should -BeTrue
            $gatePid = [int](Get-Content -LiteralPath $gatePidPath -Raw -Encoding UTF8)
            $childPid = [int](Get-Content -LiteralPath $childPidPath -Raw -Encoding UTF8)
            (Get-Process -Id $gatePid -ErrorAction Stop).HasExited | Should -BeFalse
            (Get-Process -Id $childPid -ErrorAction Stop).HasExited | Should -BeFalse

            Stop-Process -Id $wrapper.Id -Force -ErrorAction Stop
            [void]$wrapper.WaitForExit(15000)
            $exitDeadline = [DateTime]::UtcNow.AddSeconds(15)
            do {
                $gateAlive = $null -ne (Get-Process -Id $gatePid -ErrorAction SilentlyContinue)
                $childAlive = $null -ne (Get-Process -Id $childPid -ErrorAction SilentlyContinue)
                if (-not $gateAlive -and -not $childAlive) { break }
                Start-Sleep -Milliseconds 100
            } while ([DateTime]::UtcNow -lt $exitDeadline)
            $gateAlive | Should -BeFalse
            $childAlive | Should -BeFalse
        } finally {
            if ($wrapper -and -not $wrapper.HasExited) { Stop-Process -Id $wrapper.Id -Force -ErrorAction SilentlyContinue }
            foreach ($processId in @($gatePid, $childPid)) { if ($processId -gt 0) { Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue } }
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

It "owns the custom finalizer and its grandchild across forced wrapper termination" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl finalizer cancel путь " + [guid]::NewGuid().ToString("N"))
        $wrapper = $null; $finalizerPid = 0; $childPid = 0
        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            $finalizerPath = Join-Path $tempRoot "interrupt-finalizer.ps1"
            Set-Content -LiteralPath $finalizerPath -Encoding UTF8 -Value @'
param([string]$RepositoryRoot, [string]$SourceRepositoryRoot, [string]$CandidateCommit, [string]$Remote, [switch]$ReleaseQualified)
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'finalizer.pid'), [string]$PID, [Text.UTF8Encoding]::new($false))
$payload = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes('while ($true) { Start-Sleep -Seconds 1 }'))
$child = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoLogo', '-NoProfile', '-EncodedCommand', $payload) -WindowStyle Hidden -PassThru
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'finalizer-child.pid'), [string]$child.Id, [Text.UTF8Encoding]::new($false))
while ($true) { Start-Sleep -Seconds 1 }
'@
            $names = @('Stop-DeliveryProcessTree', 'Start-DeliveryProcess', 'Close-DeliveryProcessJob', 'ConvertTo-DeliveryNativeArgument', 'Invoke-ComponentPublicationFinalizer')
            $functions = @(Get-DeliveryFunctionDefinitions -Names $names)
            foreach ($name in $names) { ($functions | Where-Object Name -eq $name | Select-Object -First 1) | Should -Not -BeNullOrEmpty }

            $escapedRoot = $tempRoot.Replace("'", "''")
            $escapedFinalizer = $finalizerPath.Replace("'", "''")
            $runspaceBody = @(
                ($functions | Where-Object Name -eq 'Stop-DeliveryProcessTree' | Select-Object -First 1).Extent.Text
                ($functions | Where-Object Name -eq 'Start-DeliveryProcess' | Select-Object -First 1).Extent.Text
                ($functions | Where-Object Name -eq 'Close-DeliveryProcessJob' | Select-Object -First 1).Extent.Text
                ($functions | Where-Object Name -eq 'ConvertTo-DeliveryNativeArgument' | Select-Object -First 1).Extent.Text
                ($functions | Where-Object Name -eq 'Invoke-ComponentPublicationFinalizer' | Select-Object -First 1).Extent.Text
                "`$script:Root = '$escapedRoot'"
                "`$script:Remote = 'origin'"
                "`$script:ComponentFinalizerScript = '$escapedFinalizer'"
                '$RequireRelease = $false'
                "Invoke-ComponentPublicationFinalizer -CandidateRoot '$escapedRoot' -CandidateCommit 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'"
            ) -join [Environment]::NewLine
            $wrapperPath = Join-Path $tempRoot 'finalizer-wrapper.ps1'
            [IO.File]::WriteAllText($wrapperPath, ($runspaceBody + [Environment]::NewLine), [Text.UTF8Encoding]::new($true))
            $wrapperStdout = Join-Path $tempRoot 'wrapper.stdout.log'; $wrapperStderr = Join-Path $tempRoot 'wrapper.stderr.log'
            $wrapper = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $wrapperPath + '"')) -WindowStyle Hidden -RedirectStandardOutput $wrapperStdout -RedirectStandardError $wrapperStderr -PassThru
            $null = $wrapper.Handle

            $finalizerPidPath = Join-Path $tempRoot 'finalizer.pid'; $childPidPath = Join-Path $tempRoot 'finalizer-child.pid'
            $readyDeadline = [DateTime]::UtcNow.AddSeconds(15)
            while ([DateTime]::UtcNow -lt $readyDeadline -and (-not (Test-Path -LiteralPath $finalizerPidPath) -or -not (Test-Path -LiteralPath $childPidPath))) { Start-Sleep -Milliseconds 100 }
            Test-Path -LiteralPath $finalizerPidPath | Should -BeTrue
            Test-Path -LiteralPath $childPidPath | Should -BeTrue
            $finalizerPid = [int](Get-Content -LiteralPath $finalizerPidPath -Raw -Encoding UTF8)
            $childPid = [int](Get-Content -LiteralPath $childPidPath -Raw -Encoding UTF8)
            (Get-Process -Id $finalizerPid -ErrorAction Stop).HasExited | Should -BeFalse
            (Get-Process -Id $childPid -ErrorAction Stop).HasExited | Should -BeFalse

            Stop-Process -Id $wrapper.Id -Force -ErrorAction Stop
            [void]$wrapper.WaitForExit(15000)
            $exitDeadline = [DateTime]::UtcNow.AddSeconds(15)
            do {
                $finalizerAlive = $null -ne (Get-Process -Id $finalizerPid -ErrorAction SilentlyContinue)
                $childAlive = $null -ne (Get-Process -Id $childPid -ErrorAction SilentlyContinue)
                if (-not $finalizerAlive -and -not $childAlive) { break }
                Start-Sleep -Milliseconds 100
            } while ([DateTime]::UtcNow -lt $exitDeadline)
            $finalizerAlive | Should -BeFalse
            $childAlive | Should -BeFalse
        } finally {
            if ($wrapper -and -not $wrapper.HasExited) { Stop-Process -Id $wrapper.Id -Force -ErrorAction SilentlyContinue }
            foreach ($processId in @($finalizerPid, $childPid)) { if ($processId -gt 0) { Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue } }
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
