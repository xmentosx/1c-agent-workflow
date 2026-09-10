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
