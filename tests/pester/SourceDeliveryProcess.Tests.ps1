BeforeAll {
    . (Join-Path $PSScriptRoot 'SourceDelivery.TestSupport.ps1')
    foreach ($definition in @(Get-DeliveryFunctionDefinitions -Names @(
        'Start-DeliveryProcess', 'Stop-DeliveryProcessJobAndWait',
        'Close-DeliveryProcessJob', 'Stop-DeliveryProcessTree',
        'Test-DeliveryProcessCreationIdentity', 'ConvertTo-DeliveryNativeArgument'
    ))) {
        Invoke-Expression $definition.Extent.Text
    }
    $script:DeliveryQuoteDefinition = (Get-DeliveryFunctionDefinitions -Names @('ConvertTo-DeliveryNativeArgument') | Select-Object -First 1).Extent.Text
}

Describe 'Delivery Windows job quiescence' {
    It 'confirms descendant exit before Close when parentAlreadyExited=<ParentAlreadyExited>' -ForEach @(
        @{ ParentAlreadyExited = $false },
        @{ ParentAlreadyExited = $true }
    ) {
        $env:OS | Should -Be 'Windows_NT'
        $fixtureRoot = Join-Path $TestDrive ('owned job путь ' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
        $identityPath = Join-Path $fixtureRoot 'native descendant.json'
        $lockedPath = Join-Path $fixtureRoot 'held native файл.log'
        $grandchildPath = Join-Path $fixtureRoot 'native grandchild.ps1'
        $childPath = Join-Path $fixtureRoot 'delivery child.ps1'
        $grandchildText = @'
$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8
$process = [Diagnostics.Process]::GetCurrentProcess()
$stream = [IO.File]::Open((Join-Path $PSScriptRoot 'held native файл.log'), [IO.FileMode]::Create, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
try {
    $bytes = $utf8.GetBytes('точный UTF-8 descendant')
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush()
    $identity = [ordered]@{ processId=$PID; createdAt=$process.StartTime.ToUniversalTime().ToString('o'); root=$PSScriptRoot; powershellVersion=[string]$PSVersionTable.PSVersion }
    $identityPath = Join-Path $PSScriptRoot 'native descendant.json'
    [IO.File]::WriteAllText(($identityPath + '.tmp'), ($identity | ConvertTo-Json -Compress), $utf8)
    [IO.File]::Move(($identityPath + '.tmp'), $identityPath)
    while ($true) { [Threading.Thread]::Sleep(100) }
} finally { $stream.Dispose(); $process.Dispose() }
'@
        $childText = $script:DeliveryQuoteDefinition + [Environment]::NewLine + @'
$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8
$arguments = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'native grandchild.ps1'))
$info = [Diagnostics.ProcessStartInfo]::new()
$info.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$info.Arguments = (@($arguments | ForEach-Object { ConvertTo-DeliveryNativeArgument -Value $_ }) -join ' ')
$info.WorkingDirectory = $PSScriptRoot
$info.UseShellExecute = $false
$info.CreateNoWindow = $true
$grandchild = [Diagnostics.Process]::Start($info)
$null = $grandchild.Handle
$ready = [Diagnostics.Stopwatch]::StartNew()
while (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'native descendant.json'))) {
    if ($grandchild.HasExited) { throw 'Native descendant exited before readiness.' }
    if ($ready.ElapsedMilliseconds -gt 15000) { throw 'Native descendant did not become ready.' }
    [Threading.Thread]::Sleep(25)
}
if (__EXIT_PARENT__) { exit 0 }
while ($true) { [Threading.Thread]::Sleep(100) }
'@
        $childText = $childText.Replace('__EXIT_PARENT__', $(if ($ParentAlreadyExited) { '$true' } else { '$false' }))
        foreach ($file in @(
            @{ path=$grandchildPath; text=$grandchildText },
            @{ path=$childPath; text=$childText }
        )) {
            $text = $file.text.Replace("`r`n", "`n").Replace("`n", "`r`n")
            [IO.File]::WriteAllText($file.path, $text, [Text.UTF8Encoding]::new($true))
        }
        $started = $null
        $grandchild = $null
        try {
            $arguments = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $childPath)
            $started = Start-DeliveryProcess -ArgumentList (@($arguments | ForEach-Object { ConvertTo-DeliveryNativeArgument -Value $_ }) -join ' ') -WorkingDirectory $fixtureRoot -StandardOutputPath (Join-Path $fixtureRoot 'stdout.log') -StandardErrorPath (Join-Path $fixtureRoot 'stderr.log')
            $parentCreatedAt = $started.process.StartTime.ToUniversalTime()
            $ready = [Diagnostics.Stopwatch]::StartNew()
            while (-not (Test-Path -LiteralPath $identityPath)) {
                if ($ready.ElapsedMilliseconds -gt 20000) { throw 'Native descendant identity was not written.' }
                [Threading.Thread]::Sleep(25)
            }
            $identity = [Text.UTF8Encoding]::new($false, $true).GetString([IO.File]::ReadAllBytes($identityPath)) | ConvertFrom-Json
            $identity.root | Should -BeExactly $fixtureRoot
            ([version]$identity.powershellVersion).Major | Should -Be 5
            $grandchild = Get-Process -Id ([int]$identity.processId) -ErrorAction Stop
            $null = $grandchild.Handle
            $createdAt = [DateTimeOffset]::Parse([string]$identity.createdAt).UtcDateTime
            (Test-DeliveryProcessCreationIdentity -ProcessId $grandchild.Id -CreatedAt $createdAt) | Should -BeTrue
            if ($ParentAlreadyExited) {
                $started.process.WaitForExit(5000) | Should -BeTrue
            } else {
                $started.process.HasExited | Should -BeFalse
            }
            { $stream = [IO.File]::Open($lockedPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None); $stream.Dispose() } | Should -Throw

            $timeoutProofs = [Collections.Generic.List[object]]::new()
            $timeoutFailure = $null
            try { Stop-DeliveryProcessJobAndWait -JobHandle $started.jobHandle -Process $started.process -TimeoutMilliseconds 0 | ForEach-Object { $timeoutProofs.Add($_) } }
            catch { $timeoutFailure = $_ }
            $timeoutFailure | Should -Not -BeNullOrEmpty
            $timeoutFailure.Exception.Message | Should -Match 'DELIVERY_PROCESS_JOB_QUIESCENCE_TIMEOUT'
            $timeoutProofs.Count | Should -Be 0
            $grandchild.WaitForExit(0) | Should -BeFalse

            $proof = Stop-DeliveryProcessJobAndWait -JobHandle $started.jobHandle -Process $started.process -TimeoutMilliseconds 5000

            $proof.jobHandle | Should -Be (([IntPtr]$started.jobHandle).ToInt64().ToString([Globalization.CultureInfo]::InvariantCulture))
            $proof.processId | Should -Be $started.process.Id
            $proof.activeProcesses | Should -Be 0
            $proof.stopped | Should -BeTrue
            $proof.quiescenceConfirmed | Should -BeTrue
            $proof.processHandleWaitsVerified | Should -BeTrue
            $grandchild.WaitForExit(0) | Should -BeTrue
            $started.process.WaitForExit(0) | Should -BeTrue
            (Test-DeliveryProcessCreationIdentity -ProcessId $grandchild.Id -CreatedAt $createdAt) | Should -BeFalse
            (Test-DeliveryProcessCreationIdentity -ProcessId $started.process.Id -CreatedAt $parentCreatedAt) | Should -BeFalse
            $stream = [IO.File]::Open($lockedPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
            $stream.Dispose()
            [Text.UTF8Encoding]::new($false, $true).GetString([IO.File]::ReadAllBytes($lockedPath)) | Should -BeExactly 'точный UTF-8 descendant'
            # A second query succeeds before caller Close: the API did not
            # substitute closing the handle for proving accounting reached zero.
            $repeated = Stop-DeliveryProcessJobAndWait -JobHandle $started.jobHandle -Process $started.process -TimeoutMilliseconds 0
            $repeated.activeProcesses | Should -Be 0
            $repeated.quiescenceConfirmed | Should -BeTrue
        } finally {
            try {
                if ($started) { Close-DeliveryProcessJob -JobHandle $started.jobHandle -Process $started.process }
            } finally {
                if ($grandchild) { try { $grandchild.WaitForExit(5000) | Should -BeTrue } finally { $grandchild.Dispose() } }
                if ($started) { try { $started.process.WaitForExit(5000) | Should -BeTrue } finally { $started.process.Dispose() } }
            }
        }
    }

    It 'fails closed without emitting a stopped proof for invalid job handle <Handle>' -ForEach @(
        @{ Handle = [int64]0 },
        @{ Handle = [int64]-1 }
    ) {
        $proofs = [Collections.Generic.List[object]]::new()
        $failure = $null
        $process = [Diagnostics.Process]::GetCurrentProcess()
        try {
            try { Stop-DeliveryProcessJobAndWait -JobHandle ([IntPtr]$Handle) -Process $process | ForEach-Object { $proofs.Add($_) } }
            catch { $failure = $_ }
            $failure | Should -Not -BeNullOrEmpty
            $failure.Exception.Message | Should -Match 'DELIVERY_PROCESS_JOB_QUIESCENCE_UNAVAILABLE'
            $proofs.Count | Should -Be 0
        } finally { $process.Dispose() }
    }

    It 'fails closed when native Windows job accounting is unavailable' {
        $priorOs = $env:OS
        $process = [Diagnostics.Process]::GetCurrentProcess()
        try {
            $env:OS = 'fixture-unavailable'
            { Stop-DeliveryProcessJobAndWait -JobHandle ([IntPtr]-1) -Process $process } | Should -Throw '*DELIVERY_PROCESS_JOB_QUIESCENCE_UNAVAILABLE*'
        } finally { $env:OS = $priorOs; $process.Dispose() }
    }
}
