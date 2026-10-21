Describe 'Continuation fixture status snapshot transport' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'ContinuationStatusSnapshot.TestSupport.ps1')
        $corePath = Join-Path $PSScriptRoot '../../.agents/skills/1c-workflow/scripts/lib/agent-1c.core.ps1'
        . $corePath
    }

    It 'copies complete Unicode snapshots during concurrent atomic publication and a sharing violation' {
        $root = Join-Path $TestDrive 'Снимок статуса с пробелом'
        $source = Join-Path $root 'status.json'
        $destination = Join-Path $root 'observed-external.json'
        $payload = ('Кириллица с пробелом ' * 100)
        Write-Utf8TextAtomic -Path $source -Value (@{generation=0;payload=$payload} | ConvertTo-Json -Compress)
        $ready = [Threading.ManualResetEvent]::new($false)
        $startCopy = [Threading.ManualResetEvent]::new($false)
        $stop = [Threading.ManualResetEvent]::new($false)
        $writer = [PowerShell]::Create()
        try {
            $null = $writer.AddScript({
                param($Core, $Source, $Payload, $Ready, $StartCopy, $Stop)
                $ErrorActionPreference = 'Stop'
                . $Core
                $locked = [IO.File]::Open($Source, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
                try {
                    $null = $Ready.Set()
                    if (-not $StartCopy.WaitOne(10000)) { throw 'Snapshot reader did not start' }
                    Start-Sleep -Milliseconds 300
                } finally { $locked.Dispose() }
                $generation = 0
                $clock = [Diagnostics.Stopwatch]::StartNew()
                while (-not $Stop.WaitOne(0)) {
                    if ($clock.Elapsed.TotalSeconds -gt 60) { throw 'Snapshot reader did not finish' }
                    $generation++
                    Write-Utf8TextAtomic -Path $Source -Value (@{generation=$generation;payload=$Payload} | ConvertTo-Json -Compress)
                }
                $generation
            }).AddArgument($corePath).AddArgument($source).AddArgument($payload).AddArgument($ready).AddArgument($startCopy).AddArgument($stop)
            $async = $writer.BeginInvoke()
            $ready.WaitOne(10000) | Should -BeTrue
            # Prove the original unguarded operation fails on this same file.
            { Copy-Item -LiteralPath $source -Destination $destination -ErrorAction Stop } | Should -Throw
            $null = $startCopy.Set()
            $observedGenerations = [Collections.Generic.HashSet[int]]::new()
            for ($index = 0; $index -lt 1000; $index++) {
                if ($async.IsCompleted) { throw 'Atomic writer stopped before the reader' }
                Copy-TestContinuationStatusSnapshot -SourcePath $source -DestinationPath $destination
                $snapshot = [IO.File]::ReadAllText($destination, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
                if ($snapshot.payload -cne $payload -or $snapshot.generation -lt 0) { throw 'Incomplete or corrupt status snapshot' }
                $null = $observedGenerations.Add([int]$snapshot.generation)
            }
            $null = $stop.Set()
            $async.AsyncWaitHandle.WaitOne(10000) | Should -BeTrue
            $published = @($writer.EndInvoke($async))
            @($writer.Streams.Error).Count | Should -Be 0
            $published.Count | Should -Be 1
            $published[0] | Should -BeGreaterThan 0
            $observedGenerations.Count | Should -BeGreaterThan 1
        } finally {
            $null = $stop.Set()
            $null = $startCopy.Set()
            $writer.Stop()
            $writer.Dispose()
            $ready.Dispose(); $startCopy.Dispose(); $stop.Dispose()
        }
    }

    It 'waits for an absent status to be republished without accepting a stale destination' {
        $root = Join-Path $TestDrive 'Повтор публикации с пробелом'
        New-Item -ItemType Directory -Path $root | Out-Null
        $source = Join-Path $root 'status.json'
        $destination = Join-Path $root 'observed-external.json'
        [IO.File]::WriteAllText($destination, 'stale snapshot')
        $ready = [Threading.ManualResetEvent]::new($false)
        $writer = [PowerShell]::Create()
        try {
            $null = $writer.AddScript({
                param($Core, $Source, $Ready)
                $ErrorActionPreference = 'Stop'
                . $Core
                if (-not $Ready.WaitOne(10000)) { throw 'Snapshot reader did not start' }
                Start-Sleep -Milliseconds 300
                Write-Utf8TextAtomic -Path $Source -Value '{"status":"running","detail":"Ветка с пробелом"}'
            }).AddArgument($corePath).AddArgument($source).AddArgument($ready)
            $async = $writer.BeginInvoke()
            $null = $ready.Set()
            Copy-TestContinuationStatusSnapshot -SourcePath $source -DestinationPath $destination
            $snapshot = [IO.File]::ReadAllText($destination, [Text.Encoding]::UTF8) | ConvertFrom-Json
            $snapshot.status | Should -Be 'running'
            $snapshot.detail | Should -BeExactly 'Ветка с пробелом'
            $async.AsyncWaitHandle.WaitOne(10000) | Should -BeTrue
            $null = $writer.EndInvoke($async)
            @($writer.Streams.Error).Count | Should -Be 0
        } finally {
            $null = $ready.Set()
            $writer.Stop(); $writer.Dispose(); $ready.Dispose()
        }
    }

    It 'fails after the bounded retry when the source remains absent' {
        $source = Join-Path $TestDrive 'Отсутствующий статус.json'
        $destination = Join-Path $TestDrive 'Старый снимок.json'
        [IO.File]::WriteAllText($destination, 'stale snapshot')
        { Copy-TestContinuationStatusSnapshot -SourcePath $source -DestinationPath $destination } | Should -Throw
        [IO.File]::ReadAllText($destination) | Should -BeExactly 'stale snapshot'
    }

    It 'propagates a non-transient destination error without retrying' {
        $source = Join-Path $TestDrive 'Исходный статус.json'
        [IO.File]::WriteAllText($source, '{"status":"running"}')
        Mock Start-Sleep { throw 'A permanent error was retried' }
        { Copy-TestContinuationStatusSnapshot -SourcePath $source -DestinationPath 'unknown-snapshot-provider:\status.json' } | Should -Throw '*unknown-snapshot-provider*'
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }
}
