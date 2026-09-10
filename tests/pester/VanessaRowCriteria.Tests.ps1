BeforeAll {
    $script:RowCriteriaRepo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    $script:RowCriteriaFixture = Join-Path $script:RowCriteriaRepo 'tests/fixtures/vanessa-row-criteria'
    $script:RowCriteriaPatch = Join-Path $script:RowCriteriaRepo 'third-party/vanessa-automation/1.2.043.28-itl-r10/file-operations.patch'
    $script:RowOneScript = (Get-Command oscript -ErrorAction Stop).Source
    . (Join-Path $script:RowCriteriaRepo '.agents/skills/1c-workflow/scripts/lib/agent-1c.core.ps1')

    function Invoke-RowCriteriaProbe {
        param([string]$Root, [string]$Case, [bool]$Patched)
        [void][IO.Directory]::CreateDirectory($Root)
        $source = Get-Content (Join-Path $script:RowCriteriaFixture 'source.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $navigationPath = Join-Path $Root 'navigation.bsl'
        [IO.File]::Copy((Join-Path $script:RowCriteriaFixture 'navigation.bsl'), $navigationPath)
        (Get-FileHash $navigationPath -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $source.snippetSha256
        if ($Patched) {
            $patch = [IO.File]::ReadAllText($script:RowCriteriaPatch)
            $section = @($patch -split '(?m)(?=^diff --git )' | Where-Object {
                $_.StartsWith('diff --git a/' + $source.path + ' b/' + $source.path)
            })
            $section.Count | Should -Be 1
            $hunks = @([regex]::Matches($section[0], '(?ms)^@@ -(?<old>\d+)(?:,\d+)? [^\r\n]*\r?\n.*?(?=^@@ |\z)') | Where-Object {
                [int]$_.Groups['old'].Value -ge $source.firstLine -and [int]$_.Groups['old'].Value -le $source.lastLine
            })
            $hunks.Count | Should -BeGreaterThan 0
            $focusedPatch = "--- a/navigation.bsl`n+++ b/navigation.bsl`n" + (($hunks | ForEach-Object Value) -join '')
            $patchPath = Join-Path $Root 'criteria.patch'
            [IO.File]::WriteAllText($patchPath, $focusedPatch, [Text.UTF8Encoding]::new($false))
            & git -C $Root apply --check -- $patchPath 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'The row-criteria hunk does not apply to the exact upstream function.' }
            & git -C $Root apply -- $patchPath 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Applying row-criteria hunk failed.' }
        }
        $prefix = @'
Перем Ванесса;
Функция МодульМсп_Сервер()
    Возврат Новый ТестовыйМспСервер;
КонецФункции
Функция ТекстОшибкиИзОписанияОшибки(Текст)
    Возврат Текст;
КонецФункции
'@
        $probe = $prefix + "`n" + [IO.File]::ReadAllText($navigationPath) + "`n"
        $probe += 'КаталогФикстуры = "' + $script:RowCriteriaFixture.Replace('"', '""') + '";' + "`n"
        $probe += [IO.File]::ReadAllText((Join-Path $script:RowCriteriaFixture 'scenario.os'))
        $probePath = Join-Path $Root 'probe.os'
        [IO.File]::WriteAllText($probePath, $probe, [Text.UTF8Encoding]::new($true))
        $start = [Diagnostics.ProcessStartInfo]::new()
        $start.FileName = $script:RowOneScript
        $start.Arguments = Join-NativeCommandLineArguments -Arguments @('-encoding=utf-8', $probePath, $Case)
        $start.UseShellExecute = $false; $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
        $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
        $start.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
        $process = [Diagnostics.Process]::Start($start)
        try {
            $output = $process.StandardOutput.ReadToEndAsync(); $errors = $process.StandardError.ReadToEndAsync()
            if (-not $process.WaitForExit(30000)) { $process.Kill(); $process.WaitForExit(); throw 'OneScript row-criteria probe timed out.' }
            [pscustomobject]@{ exitCode = $process.ExitCode; output = $output.GetAwaiter().GetResult() + $errors.GetAwaiter().GetResult() }
        } finally { $process.Dispose() }
    }
}

Describe 'Vanessa row navigation with display captions <revision>' -ForEach @(@{revision='itl-r10'},@{revision='itl-r11'}, @{revision='itl-r12'}) {
    BeforeAll {
        $script:RowCriteriaPatch = Join-Path $script:RowCriteriaRepo "third-party/vanessa-automation/1.2.043.28-$revision/file-operations.patch"
    }
    It 'runs the unchanged upstream identifier case through the same UI transport double' {
        $result = Invoke-RowCriteriaProbe -Root (Join-Path $TestDrive 'Исходный обычный ключ') -Case identifier -Patched $false
        $result.exitCode | Should -Be 0 -Because $result.output
    }
    It 'reproduces the native Structure key failure for a Cyrillic caption containing a space' {
        $result = Invoke-RowCriteriaProbe -Root (Join-Path $TestDrive 'Исходный заголовок с пробелом') -Case spaces -Patched $false
        $result.exitCode | Should -Not -Be 0
        $result.output | Should -Match 'ACTION_FAILED'
        $result.output | Should -Match 'неправильное имя атрибута структуры.*Дата начала'
    }
    It 'preserves navigation and error outcomes after the shipping hunk: <case>' -TestCases @(
        @{case='identifier'}, @{case='spaces'}, @{case='multiple'}, @{case='punctuation'}, @{case='case'},
        @{case='repeated'}, @{case='equals'}, @{case='no-match'}, @{case='unknown-column'}, @{case='empty'}
    ) {
        param($case)
        $result = Invoke-RowCriteriaProbe -Root (Join-Path $TestDrive ('Исправленная навигация ' + $case)) -Case $case -Patched $true
        $result.exitCode | Should -Be 0 -Because $result.output
        $result.output | Should -Match ('ROW_CRITERIA_CASE_PASSED: ' + [regex]::Escape($case))
    }
}
