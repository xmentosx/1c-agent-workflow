Describe 'Vanessa TestClient profile port ownership' {
    BeforeAll {
        $portRepo = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
        $portFixture = Join-Path $portRepo 'tests/fixtures/vanessa-testclient-ports'
        $portSource = Get-Content (Join-Path $portFixture 'source.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $portPatch = [IO.File]::ReadAllText((Join-Path $portRepo 'third-party/vanessa-automation/1.2.043.28-itl-r13/file-operations.patch'))
        $portEngine = (Get-Command oscript -ErrorAction Stop).Source
        . (Join-Path $portRepo '.agents/skills/1c-workflow/scripts/lib/agent-1c.core.ps1')
    }
    It 'runs the original allocator and shipping correction: <case>' -TestCases @(
        @{case='baseline'}, @{case='own-free'}, @{case='assigned-free'}, @{case='foreign-reserved'}, @{case='native-busy'}, @{case='exhausted'}
    ) {
        param($case)
        $root = Join-Path $TestDrive ('Порты клиентов ' + $case)
        [void][IO.Directory]::CreateDirectory($root)
        $functions = @()
        foreach ($kind in @('ports','occupied')) {
            $path = Join-Path $root ($kind + '.bsl')
            [IO.File]::Copy((Join-Path $portFixture ($kind + '-upstream.bsl')), $path)
            (Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $portSource.$kind.sha256
            if ($case -ne 'baseline') {
                $section = @($portPatch -split '(?m)(?=^diff --git )' | Where-Object { $_.StartsWith('diff --git a/' + $portSource.path + ' b/' + $portSource.path) })
                $hunks = @([regex]::Matches($section[0], '(?ms)^@@ -(?<old>\d+)(?:,\d+)? [^\r\n]*\r?\n.*?(?=^@@ |\z)') | Where-Object {
                    [int]$_.Groups['old'].Value -ge ($portSource.$kind.first - 3) -and [int]$_.Groups['old'].Value -le $portSource.$kind.last
                })
                $hunks.Count | Should -BeGreaterThan 0
                $patchPath = Join-Path $root ($kind + '.patch')
                [IO.File]::WriteAllText($patchPath, "--- a/$kind.bsl`n+++ b/$kind.bsl`n" + (($hunks | ForEach-Object Value) -join ''), [Text.UTF8Encoding]::new($false))
                & git -C $root apply --check -- $patchPath 2>&1 | Out-Null
                $LASTEXITCODE | Should -Be 0
                & git -C $root apply -- $patchPath 2>&1 | Out-Null
                $LASTEXITCODE | Should -Be 0
            }
            $body = [regex]::Match([IO.File]::ReadAllText($path), '(?ms)^Функция ' + $portSource.$kind.name + '\(.*?^КонецФункции[^\r\n]*').Value
            $functions += [regex]::Replace($body, '(?m)^\s*#(?:Если|КонецЕсли)[^\r\n]*', '')
        }
        $scenario = [IO.File]::ReadAllText((Join-Path $portFixture 'scenario.os')).Replace('// PRODUCTION_FUNCTIONS', ($functions -join "`n"))
        if ($case -eq 'baseline') { $scenario = $scenario.Replace('ПроверитьПортНаЗанятость(ПортЗапроса, "B")', 'ПроверитьПортНаЗанятость(ПортЗапроса)') }
        $scenarioPath = Join-Path $root 'probe.os'
        [IO.File]::WriteAllText($scenarioPath, $scenario, [Text.UTF8Encoding]::new($true))
        $start = [Diagnostics.ProcessStartInfo]::new()
        $start.FileName = $portEngine
        $start.Arguments = Join-NativeCommandLineArguments -Arguments @('-encoding=utf-8',$scenarioPath,$case)
        $start.UseShellExecute = $false; $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
        $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false); $start.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
        $process = [Diagnostics.Process]::Start($start)
        try {
            $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
            if (-not $process.WaitForExit(30000)) { $process.Kill(); $process.WaitForExit(); throw 'Port allocator probe timed out.' }
            $output = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
            $process.ExitCode | Should -Be 0 -Because $output
            $output | Should -Match $(if ($case -eq 'baseline') { 'ORIGINAL_BUSY_PORT_RETURNED' } else { 'PORT_CASE_PASSED: ' + $case })
        } finally { $process.Dispose() }
    }
}

Describe 'Vanessa 1.2.043.42 TestClient listening-port detection' {
    BeforeAll {
        $listenerRepo = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
        $listenerFixture = Join-Path $listenerRepo 'tests/fixtures/vanessa-testclient-ports'
        $listenerSource = Get-Content (Join-Path $listenerFixture 'listeners-source.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $listenerEngine = (Get-Command oscript -ErrorAction Stop).Source
        . (Join-Path $listenerRepo '.agents/skills/1c-workflow/scripts/lib/agent-1c.core.ps1')

        # Applies the recipe hunks of both owner functions to their verbatim upstream text
        # and returns a OneScript probe of every complete patched method.
        function New-ListenerProbe([string]$Revision, [string]$Case) {
            $recipe = Join-Path $listenerRepo ('third-party/vanessa-automation/1.2.043.42-' + $Revision)
            $patch = [IO.File]::ReadAllText((Join-Path $recipe 'file-operations.patch'), [Text.Encoding]::UTF8)
            $root = Join-Path $TestDrive ('Порты слушателей ' + $Revision + ' ' + $Case)
            [void][IO.Directory]::CreateDirectory($root)
            $methods = @()
            foreach ($kind in @('ports', 'occupied')) {
                $entry = $listenerSource.$kind
                $path = Join-Path $root ($kind + '.bsl')
                [IO.File]::Copy((Join-Path $listenerFixture ('listeners-' + $kind + '-upstream.bsl')), $path)
                (Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $entry.sha256
                $section = @($patch -split '(?m)(?=^diff --git )' | Where-Object { ($_ -split "`n")[0] -ceq ('diff --git a/' + $entry.path + ' b/' + $entry.path) })
                $section.Count | Should -Be 1
                $hunks = @([regex]::Matches($section[0], '(?ms)^@@ -(?<old>\d+)(?:,\d+)? [^\n]*\n.*?(?=^@@ |\z)') | Where-Object {
                    [int]$_.Groups['old'].Value -ge $entry.first -and [int]$_.Groups['old'].Value -le $entry.last
                })
                $hunks.Count | Should -BeGreaterThan 0
                $patchPath = Join-Path $root ($kind + '.patch')
                [IO.File]::WriteAllText($patchPath, "--- a/$kind.bsl`n+++ b/$kind.bsl`n" + (($hunks | ForEach-Object Value) -join ''), [Text.UTF8Encoding]::new($false))
                & git -C $root apply -- $patchPath 2>&1 | Out-Null
                $LASTEXITCODE | Should -Be 0 -Because "$Revision hunks of $kind apply to the pinned upstream text"
                $text = [IO.File]::ReadAllText($path)
                $found = @([regex]::Matches($text, '(?ms)^(?:Функция|Процедура) (?<name>[^\s(]+)\(.*?^Конец(?:Функции|Процедуры)[^\n]*'))
                @($found | Where-Object { $_.Groups['name'].Value -ceq $entry.name }).Count | Should -Be 1
                $methods += @($found | ForEach-Object { [regex]::Replace($_.Value, '(?m)^\s*#(?:Если|КонецЕсли)[^\n]*', '') })
            }
            $scenario = [IO.File]::ReadAllText((Join-Path $listenerFixture 'listeners-scenario.os'), [Text.Encoding]::UTF8)
            $probePath = Join-Path $root 'проба портов.os'
            [IO.File]::WriteAllText($probePath, $scenario.Replace('// PRODUCTION_FUNCTIONS', ($methods -join "`n")), [Text.UTF8Encoding]::new($true))
            return $probePath
        }

        function Invoke-ListenerProbe([string]$ProbePath, [string]$Case) {
            $start = [Diagnostics.ProcessStartInfo]::new()
            $start.FileName = $listenerEngine
            $start.Arguments = Join-NativeCommandLineArguments -Arguments @('-encoding=utf-8', $ProbePath, $Case, (Join-Path $listenerFixture 'listeners-vanessa.os'))
            $start.UseShellExecute = $false; $start.CreateNoWindow = $true
            $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
            $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false); $start.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
            $process = [Diagnostics.Process]::Start($start)
            try {
                $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
                if (-not $process.WaitForExit(30000)) { $process.Kill(); $process.WaitForExit(); throw 'Listening-port probe timed out.' }
                [pscustomobject]@{ exitCode = $process.ExitCode; output = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult() }
            } finally { $process.Dispose() }
        }
    }

    It 'reproduces the r11 rejection of a closed client''s TIME_WAIT port' {
        $result = Invoke-ListenerProbe -ProbePath (New-ListenerProbe -Revision 'itl-r11' -Case 'baseline') -Case 'baseline-time-wait'
        $result.exitCode | Should -Be 0 -Because $result.output
        $result.output | Should -Match 'ORIGINAL_TIME_WAIT_REJECTED'
    }

    It 'treats only a listening TCP socket as occupied in r12: <case>' -TestCases @(
        @{ case = 'time-wait' }, @{ case = 'established' }, @{ case = 'close-wait' }, @{ case = 'udp' },
        @{ case = 'listening' }, @{ case = 'listening-ipv6' }, @{ case = 'listening-localized' },
        @{ case = 'linux-time-wait' }, @{ case = 'linux-listening' }
    ) {
        param($case)
        $result = Invoke-ListenerProbe -ProbePath (New-ListenerProbe -Revision 'itl-r12' -Case $case) -Case $case
        $result.exitCode | Should -Be 0 -Because $result.output
        $result.output | Should -Match ('LISTENER_CASE_PASSED: ' + [regex]::Escape($case))
    }

    It 'changes only the occupied-port owner of r11 in the cumulative r12 recipe' {
        $base = Join-Path $listenerRepo 'third-party/vanessa-automation'
        $r11 = Get-Content -LiteralPath (Join-Path $base '1.2.043.42-itl-r11/manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $r12 = Get-Content -LiteralPath (Join-Path $base '1.2.043.42-itl-r12/manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $r12.downstreamRevision | Should -Be 'itl-r12'
        $r12.upstream.commit | Should -Be $listenerSource.commit
        (Get-FileHash -LiteralPath (Join-Path $base '1.2.043.42-itl-r12/file-operations.patch')).Hash.ToLowerInvariant() | Should -Be $r12.patch.sha256
        @($r12.patch.expectedChangedPaths) | Should -Be @($r11.patch.expectedChangedPaths)
        @($r12.patch.retainedDownstreamFixes) | Should -Be (@($r11.patch.retainedDownstreamFixes) + @($r12.patch.retainedDownstreamFixes)[-1])
        $r12.artifact.fileName | Should -Be 'vanessa-automation-single.1.2.043.42-itl-r12.zip'
        $r12.pairedExtension.fileName | Should -Be 'VAExtension.1.32-itl-r12.cfe'
        $old = [IO.File]::ReadAllText((Join-Path $base '1.2.043.42-itl-r11/file-operations.patch'), [Text.Encoding]::UTF8) -split '(?m)(?=^diff --git )'
        $new = [IO.File]::ReadAllText((Join-Path $base '1.2.043.42-itl-r12/file-operations.patch'), [Text.Encoding]::UTF8) -split '(?m)(?=^diff --git )'
        $new.Count | Should -Be $old.Count
        $owner = 'diff --git a/' + $listenerSource.occupied.path + ' b/' + $listenerSource.occupied.path
        for ($i = 0; $i -lt $new.Count; $i++) {
            if (($new[$i] -split "`n")[0] -ceq $owner) { $new[$i] | Should -Not -BeExactly $old[$i]; continue }
            $new[$i] | Should -BeExactly $old[$i]
        }
    }
}
