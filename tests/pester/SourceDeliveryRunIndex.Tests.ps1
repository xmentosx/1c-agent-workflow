BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSupport.ps1')
    $context = Initialize-WorkflowPesterContext
    $RepoRoot = $context.RepoRoot
    . (Join-Path $RepoRoot 'scripts\source-delivery-process.ps1')
    . (Join-Path $RepoRoot 'scripts\release-qualification.ps1')

    function New-RunIndexStore {
        $nonAscii = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('0L/Rg9GC0Yw='))
        $script:CommonGit = Join-Path $TestDrive ("common git $nonAscii " + [guid]::NewGuid().ToString('N'))
        $runRoot = Join-Path $script:CommonGit 'itl\runs'
        New-Item -ItemType Directory -Force -Path $runRoot | Out-Null
        return $runRoot
    }

    function Get-DeliveryCommonGitDirectory { return $script:CommonGit }
    function Get-RepositoryCommonGitDirectory { param([string]$RepositoryRoot); return $script:CommonGit }
    function Invoke-WorktreeGit {
        param([string]$Root, [string[]]$Arguments)
        $value = if (($Arguments -join ' ') -match '\^\{tree\}') { 'b' * 40 } else { 'a' * 40 }
        return [pscustomobject]@{ stdout="$value`n"; exitCode=0 }
    }

    function Write-TestDeliveryRun {
        param(
            [Parameter(Mandatory = $true)][string]$RunRoot,
            [Parameter(Mandatory = $true)][datetime]$StartedAt,
            [Parameter(Mandatory = $true)][int]$Sequence,
            [int]$SchemaVersion = 3,
            [string]$Commit = ('a' * 40),
            [string]$Tree = ('b' * 40)
        )
        $record = [ordered]@{
            schemaVersion=$SchemaVersion; id=('{0:x32}' -f $Sequence); mode='Targeted'; status='passed'; exitCode=0
            startedAt=$StartedAt.ToString('o'); finishedAt=$StartedAt.AddMilliseconds(5).ToString('o'); durationMs=5
            commit=$Commit; tree=$Tree; error=''; tests=$null
            stages=@(
                [ordered]@{ name='pester'; status='passed' },
                [ordered]@{ name='tracked-state'; status='passed' },
                [ordered]@{ name='git-diff-check'; status='passed' }
            )
            releaseE2E=$null
        }
        $name = '{0}-targeted-{1:x8}.json' -f $StartedAt.ToString('yyyyMMdd-HHmmss-fff'), $Sequence
        $path = Join-Path $RunRoot $name
        [IO.File]::WriteAllText($path, (($record | ConvertTo-Json -Depth 8 -Compress) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        return $path
    }
}

Describe 'Delivery run hot index' {
    BeforeEach {
        $script:CommonGit = ''
    }

    It 'rebuilds 10000 raw runs into a bounded hot index and resolves more than the old latest-200 timing window' {
        $runRoot = New-RunIndexStore
        $started = [DateTime]::Parse('2026-09-01T00:00:00Z').ToUniversalTime()
        for ($i = 0; $i -lt 10000; $i++) {
            Write-TestDeliveryRun -RunRoot $runRoot -StartedAt $started.AddMilliseconds($i) -Sequence $i -SchemaVersion 3 | Out-Null
        }

        $repair = Repair-DeliveryRunHotIndex
        $repair.status | Should -Be 'rebuilt'
        $repair.validRunCount | Should -Be 10000
        $repair.retained | Should -Be 2048
        @(Get-ChildItem -LiteralPath $runRoot -File -Filter '*.json').Count | Should -Be 10000

        $history = Get-DeliveryRunHistory -Limit 5 -IncludeDetails
        $history.indexStatus | Should -Be 'ready'
        $history.count | Should -Be 10000
        $history.lastRuns | Should -HaveCount 5
        $history.truncated | Should -BeTrue
        $timing = Get-DeliveryQualificationTimingSummary -Tree ('b' * 40) -NotBefore $started.AddMilliseconds(9749)
        $timing.gates.Count | Should -BeGreaterThan 200

        $processText = Get-Content -LiteralPath (Join-Path $RepoRoot 'scripts\source-delivery-process.ps1') -Raw -Encoding UTF8
        $historyBody = [regex]::Match($processText, '(?s)function Get-DeliveryRunHistory \{.*?\n\}').Value
        $historyBody | Should -Not -Match 'Get-ChildItem'
    }

    It 'is restart-safe and idempotent, and reports stale or corrupt projection without scanning raw proof' {
        $runRoot = New-RunIndexStore
        $started = [DateTime]::Parse('2026-09-02T00:00:00Z').ToUniversalTime()
        0..9 | ForEach-Object { Write-TestDeliveryRun -RunRoot $runRoot -StartedAt $started.AddSeconds($_) -Sequence $_ -SchemaVersion 3 | Out-Null }
        Repair-DeliveryRunHotIndex | Out-Null
        $indexPath = Get-DeliveryRunHotIndexPath
        $firstSha = (Get-FileHash -LiteralPath $indexPath -Algorithm SHA256).Hash
        (Repair-DeliveryRunHotIndex).status | Should -Be 'reused'
        (Get-FileHash -LiteralPath $indexPath -Algorithm SHA256).Hash | Should -BeExactly $firstSha

        Write-DeliveryRunRecord -Mode Targeted -Status passed -ErrorMessage '' -WorkingRoot $TestDrive -StartedAt $started.AddSeconds(10) -FinishedAt $started.AddSeconds(10).AddMilliseconds(5) -ExitCode 0 | Out-Null
        $advanced = Get-DeliveryRunHistory
        $advanced.indexStatus | Should -Be 'ready'
        $advanced.count | Should -Be 11

        Write-TestDeliveryRun -RunRoot $runRoot -StartedAt $started.AddSeconds(11) -Sequence 11 -SchemaVersion 3 | Out-Null
        (Get-DeliveryRunHistory).indexStatus | Should -Be 'stale'
        $rebuilt = Repair-DeliveryRunHotIndex
        $rebuilt.status | Should -Be 'rebuilt'
        $rebuilt.validRunCount | Should -Be 12

        $semanticCorruption = Get-Content -LiteralPath $indexPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $semanticCorruption.validRunCount = [int64]$semanticCorruption.validRunCount + 1
        [IO.File]::WriteAllText($indexPath, (($semanticCorruption | ConvertTo-Json -Depth 16) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        $unavailable = Get-DeliveryRunHistory
        $unavailable.indexStatus | Should -Be 'corrupt'
        $unavailable.lastRuns | Should -HaveCount 0
        (Repair-DeliveryRunHotIndex).validRunCount | Should -Be 12
    }

    It 'serializes two process writers without losing either raw record or index entry' -Skip:(-not (Get-Command powershell.exe -ErrorAction SilentlyContinue)) {
        $runRoot = New-RunIndexStore
        $goPath = Join-Path $TestDrive 'writers-go'
        $sourcePath = (Join-Path $RepoRoot 'scripts\source-delivery-process.ps1').Replace("'", "''")
        $commonPath = $script:CommonGit.Replace("'", "''")
        $workingPath = $TestDrive.Replace("'", "''")
        $goLiteral = $goPath.Replace("'", "''")
        $processes = [Collections.Generic.List[Diagnostics.Process]]::new()
        try {
            foreach ($sequence in 1..2) {
                $readyPath = (Join-Path $TestDrive "writer-$sequence-ready").Replace("'", "''")
                $startedText = ([DateTime]::Parse('2026-09-05T00:00:00Z').ToUniversalTime().AddSeconds($sequence)).ToString('o')
                $command = @"
`$ErrorActionPreference='Stop'
function Get-DeliveryCommonGitDirectory { '$commonPath' }
function Invoke-WorktreeGit { param([string]`$Root,[string[]]`$Arguments); `$value=if((`$Arguments -join ' ') -match '\^\{tree\}'){'b'*40}else{'a'*40}; [pscustomobject]@{stdout="`$value`n";exitCode=0} }
. '$sourcePath'
[IO.File]::WriteAllText('$readyPath','ready',[Text.UTF8Encoding]::new(`$false))
`$deadline=[DateTime]::UtcNow.AddSeconds(20)
while(-not (Test-Path -LiteralPath '$goLiteral')){if([DateTime]::UtcNow -ge `$deadline){throw 'go timeout'};Start-Sleep -Milliseconds 20}
`$started=[DateTime]::Parse('$startedText').ToUniversalTime()
Write-DeliveryRunRecord -Mode Targeted -Status passed -ErrorMessage '' -WorkingRoot '$workingPath' -StartedAt `$started -FinishedAt `$started.AddMilliseconds(5) -ExitCode 0 | Out-Null
"@
                $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
                $start = [Diagnostics.ProcessStartInfo]::new()
                $start.FileName = 'powershell.exe'; $start.Arguments = "-NoProfile -EncodedCommand $encoded"
                $start.UseShellExecute = $false; $start.CreateNoWindow = $true
                $process = [Diagnostics.Process]::new(); $process.StartInfo = $start
                [void]$process.Start(); $processes.Add($process) | Out-Null
            }
            $deadline = [DateTime]::UtcNow.AddSeconds(20)
            while (@(Get-ChildItem -LiteralPath $TestDrive -File -Filter 'writer-*-ready' -ErrorAction SilentlyContinue).Count -lt 2) {
                if ([DateTime]::UtcNow -ge $deadline) { throw 'writer ready timeout' }
                Start-Sleep -Milliseconds 20
            }
            [IO.File]::WriteAllText($goPath, 'go', [Text.UTF8Encoding]::new($false))
            foreach ($process in $processes) {
                $process.WaitForExit(30000) | Should -BeTrue
                $process.ExitCode | Should -Be 0
            }
            @(Get-ChildItem -LiteralPath $runRoot -File -Filter '*.json') | Should -HaveCount 2
            $history = Get-DeliveryRunHistory -Limit 5 -IncludeDetails
            $history.indexStatus | Should -Be 'ready'
            $history.count | Should -Be 2
            $history.lastRuns | Should -HaveCount 2
        } finally {
            foreach ($process in $processes) { if (-not $process.HasExited) { $process.Kill() }; $process.Dispose() }
        }
    }

    It 'keeps the newest entries when an older recovered run is written late' {
        $runRoot = New-RunIndexStore
        $oldCapacity = $script:DeliveryRunHotIndexCapacity
        try {
            $script:DeliveryRunHotIndexCapacity = 3
            $started = [DateTime]::Parse('2026-09-06T00:00:00Z').ToUniversalTime()
            2..4 | ForEach-Object { Write-TestDeliveryRun -RunRoot $runRoot -StartedAt $started.AddSeconds($_) -Sequence $_ | Out-Null }
            Repair-DeliveryRunHotIndex | Out-Null
            Write-DeliveryRunRecord -Mode Targeted -Status passed -ErrorMessage '' -WorkingRoot $TestDrive -StartedAt $started.AddSeconds(1) -FinishedAt $started.AddSeconds(1).AddMilliseconds(5) -ExitCode 0 | Out-Null

            $history = Get-DeliveryRunHistory -Limit 3 -IncludeDetails
            $history.count | Should -Be 4
            $history.lastRuns | Should -HaveCount 3
            @($history.lastRuns | ForEach-Object startedAt) | Should -Not -Contain $started.AddSeconds(1).ToString('o')
            (ConvertTo-DeliveryUtcDateTime -Value $history.lastRuns[0].startedAt) | Should -Be $started.AddSeconds(4)
        } finally { $script:DeliveryRunHotIndexCapacity = $oldCapacity }
    }

    It 'classifies malformed time and duration as invalid and preserves raw proof on index lock contention' {
        $runRoot = New-RunIndexStore
        $started = [DateTime]::Parse('2026-09-07T00:00:00Z').ToUniversalTime()
        $badTimePath = Write-TestDeliveryRun -RunRoot $runRoot -StartedAt $started -Sequence 1
        $badTime = Get-Content -LiteralPath $badTimePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $badTime.startedAt = 'garbage'
        [IO.File]::WriteAllText($badTimePath, (($badTime | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        $badDurationPath = Write-TestDeliveryRun -RunRoot $runRoot -StartedAt $started.AddSeconds(1) -Sequence 2
        $badDuration = Get-Content -LiteralPath $badDurationPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $badDuration.durationMs = 'not-a-number'
        [IO.File]::WriteAllText($badDurationPath, (($badDuration | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))

        $repair = Repair-DeliveryRunHotIndex
        $repair.validRunCount | Should -Be 0
        $repair.invalidRunCount | Should -Be 2
        { Get-DeliveryQualificationTimingSummary -Tree ('b' * 40) -NotBefore $started } | Should -Not -Throw

        $lock = Enter-DeliveryRunHotIndexLock
        $oldTimeout = $script:DeliveryRunHotIndexLockTimeoutMilliseconds
        try {
            $script:DeliveryRunHotIndexLockTimeoutMilliseconds = 100
            $rawPath = Write-DeliveryRunRecord -Mode Targeted -Status passed -ErrorMessage '' -WorkingRoot $TestDrive -StartedAt $started.AddSeconds(2) -FinishedAt $started.AddSeconds(2).AddMilliseconds(5) -ExitCode 0
            Test-Path -LiteralPath $rawPath -PathType Leaf | Should -BeTrue
            (Get-DeliveryRunHistory).indexStatus | Should -Be 'stale'
        } finally {
            $script:DeliveryRunHotIndexLockTimeoutMilliseconds = $oldTimeout
            $lock.Dispose()
        }
        $repaired = Repair-DeliveryRunHotIndex
        $repaired.validRunCount | Should -Be 1
        $repaired.invalidRunCount | Should -Be 2
        @(Get-ChildItem -LiteralPath (Get-DeliveryRunHotIndexPendingRoot) -File -Filter '*.pending') | Should -HaveCount 0

        $stagingRoot = Join-Path $TestDrive 'late-staging'
        New-Item -ItemType Directory -Force -Path $stagingRoot | Out-Null
        $staged = Write-TestDeliveryRun -RunRoot $stagingRoot -StartedAt $started.AddSeconds(3) -Sequence 3
        $latePath = Join-Path $runRoot (Split-Path -Leaf $staged)
        $marker = Write-DeliveryRunHotIndexPendingMarker -RawPath $latePath
        Repair-DeliveryRunHotIndex | Out-Null
        Test-Path -LiteralPath $marker -PathType Leaf | Should -BeTrue
        (Get-DeliveryRunHistory).indexStatus | Should -Be 'stale'
        Copy-Item -LiteralPath $staged -Destination $latePath
        (Repair-DeliveryRunHotIndex).validRunCount | Should -Be 2
        Test-Path -LiteralPath $marker | Should -BeFalse

        $crashedRaw = Join-Path $runRoot '20260907-000004-000-targeted-00000000000000000000000000000004.json'
        $crashedMarker = Write-DeliveryRunHotIndexPendingMarker -RawPath $crashedRaw
        $crashedState = Get-Content -LiteralPath $crashedMarker -Raw -Encoding UTF8 | ConvertFrom-Json
        # Same PID but a nearby, non-exact creation time models PID reuse and
        # proves this does not rely on the operation lock's historical ±2s rule.
        $crashedState.writerStartedAt = (ConvertTo-DeliveryUtcDateTime -Value $crashedState.writerStartedAt).AddSeconds(1).ToString('o')
        [IO.File]::WriteAllText($crashedMarker, (($crashedState | ConvertTo-Json -Compress) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        Repair-DeliveryRunHotIndex | Out-Null
        Test-Path -LiteralPath $crashedMarker | Should -BeFalse
        (Get-DeliveryRunHistory).indexStatus | Should -Be 'ready'

        $torn = Join-Path (Get-DeliveryRunHotIndexPendingRoot) '20260907-000005-000-targeted-00000000000000000000000000000005.json.pending'
        [IO.File]::WriteAllText($torn, '', [Text.UTF8Encoding]::new($false))
        (Repair-DeliveryRunHotIndex).status | Should -Be 'rebuilt'
        Test-Path -LiteralPath $torn | Should -BeFalse
        (Get-DeliveryRunHistory).indexStatus | Should -Be 'ready'
    }

    It 'keeps schema-1 raw Targeted proof authoritative across indexed and corrupt-index lookup' {
        $runRoot = New-RunIndexStore
        $started = [DateTime]::Parse('2026-09-03T00:00:00Z').ToUniversalTime()
        $schemaOne = Write-TestDeliveryRun -RunRoot $runRoot -StartedAt $started -Sequence 1 -SchemaVersion 1
        Write-TestDeliveryRun -RunRoot $runRoot -StartedAt $started.AddSeconds(1) -Sequence 2 -SchemaVersion 3 | Out-Null
        Repair-DeliveryRunHotIndex | Out-Null

        $proof = Get-ExactTargetedRunProof -RepositoryRoot $TestDrive -Commit ('a' * 40) -Tree ('b' * 40)
        $proof.path | Should -BeExactly $schemaOne
        $proof.sha256 | Should -BeExactly (Get-FileHash -LiteralPath $schemaOne -Algorithm SHA256).Hash.ToLowerInvariant()

        $external = Join-Path $TestDrive 'outside-targeted-proof.json'
        $externalRecord = Get-Content -LiteralPath $schemaOne -Raw -Encoding UTF8 | ConvertFrom-Json
        $externalRecord.commit = 'c' * 40; $externalRecord.tree = 'd' * 40
        [IO.File]::WriteAllText($external, (($externalRecord | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        $state = Read-DeliveryRunHotIndex
        $outsideEntry = ConvertTo-DeliveryRunHotIndexEntry -Record $externalRecord -RawPath $external
        $state.index.entries = @($outsideEntry) + @($state.index.entries)
        Write-DeliveryRunHotIndex -Index $state.index | Out-Null
        Get-ExactTargetedRunProof -RepositoryRoot $TestDrive -Commit ('c' * 40) -Tree ('d' * 40) | Should -BeNullOrEmpty

        [IO.File]::WriteAllText((Get-DeliveryRunHotIndexPath), '{broken', [Text.UTF8Encoding]::new($false))
        (Get-ExactTargetedRunProof -RepositoryRoot $TestDrive -Commit ('a' * 40) -Tree ('b' * 40)).path | Should -BeExactly $schemaOne
    }

    It 'runs the rebuild and read contract in Windows PowerShell 5.1 at one path containing spaces and Cyrillic' -Skip:(-not (Get-Command powershell.exe -ErrorAction SilentlyContinue)) {
        $runRoot = New-RunIndexStore
        $started = [DateTime]::Parse('2026-09-04T00:00:00Z').ToUniversalTime()
        Write-TestDeliveryRun -RunRoot $runRoot -StartedAt $started -Sequence 1 -SchemaVersion 3 | Out-Null
        $probePath = Join-Path $TestDrive 'run-index-ps51.ps1'
        $resultPath = Join-Path $TestDrive 'run-index-ps51-result.json'
        $escapedCommon = $script:CommonGit.Replace("'", "''")
        $escapedSource = (Join-Path $RepoRoot 'scripts\source-delivery-process.ps1').Replace("'", "''")
        $escapedResult = $resultPath.Replace("'", "''")
        $probe = @"
`$ErrorActionPreference = 'Stop'
function Get-DeliveryCommonGitDirectory { '$escapedCommon' }
. '$escapedSource'
`$repair = Repair-DeliveryRunHotIndex
`$history = Get-DeliveryRunHistory -Limit 1
`$json = [pscustomobject]@{ repair=`$repair.status; index=`$history.indexStatus; count=`$history.count; root=`$history.root } | ConvertTo-Json -Compress
[IO.File]::WriteAllText('$escapedResult', `$json, [Text.UTF8Encoding]::new(`$false))
"@
        [IO.File]::WriteAllText($probePath, $probe, [Text.UTF8Encoding]::new($true))
        $result = Invoke-TestPowerShellFile -FilePath $probePath
        ($result.stderr -join [Environment]::NewLine) | Should -BeNullOrEmpty
        $result.exitCode | Should -Be 0
        $actual = Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $actual.repair | Should -Be 'rebuilt'
        $actual.index | Should -Be 'ready'
        $actual.count | Should -Be 1
        $actual.root | Should -BeExactly $runRoot
    }
}
