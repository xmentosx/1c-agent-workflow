BeforeAll {
    $script:ClientCodeRepo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    $script:ClientCodeFixture = Join-Path $script:ClientCodeRepo 'tests/fixtures/vanessa-client-code'
    $script:ClientCodePatch = Join-Path $script:ClientCodeRepo 'third-party/vanessa-automation/1.2.043.28-itl-r11/file-operations.patch'
    $script:ClientCodeOneScript = (Get-Command oscript -ErrorAction Stop).Source
    . (Join-Path $script:ClientCodeRepo '.agents/skills/1c-workflow/scripts/lib/agent-1c.core.ps1')

    function New-ClientCodeProbe {
        param([string]$Root, [bool]$Patched)
        [void][IO.Directory]::CreateDirectory($Root)
        $source = Get-Content (Join-Path $script:ClientCodeFixture 'source.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $patchText = [IO.File]::ReadAllText($script:ClientCodePatch)
        $modules = @{}
        foreach ($kind in @('producer', 'receiver', 'wait')) {
            $path = Join-Path $Root ($kind + '.bsl')
            [IO.File]::Copy((Join-Path $script:ClientCodeFixture ($kind + '-upstream.bsl')), $path, $true)
            (Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $source.($kind + 'Sha256')
            if ($Patched) {
                $upstreamPath = if ($kind -eq 'receiver') { $source.receiverPath } else { $source.stepsPath }
                $section = @($patchText -split '(?m)(?=^diff --git )' | Where-Object { $_.StartsWith('diff --git a/' + $upstreamPath + ' b/' + $upstreamPath) })
                $section.Count | Should -Be 1
                $hunks = @([regex]::Matches($section[0], '(?ms)^@@ -(?<old>\d+)(?:,\d+)? [^\r\n]*\r?\n.*?(?=^@@ |\z)') | Where-Object {
                    $kind -eq 'receiver' -or ([int]$_.Groups['old'].Value -ge ($source.($kind + 'FirstLine') - 3) -and [int]$_.Groups['old'].Value -le $source.($kind + 'LastLine'))
                })
                $hunks.Count | Should -BeGreaterThan 0
                $patchPath = Join-Path $Root ($kind + '.patch')
                $focusedPatch = "--- a/$kind.bsl`n+++ b/$kind.bsl`n" + (($hunks | ForEach-Object Value) -join '')
                [IO.File]::WriteAllText($patchPath, $focusedPatch, [Text.UTF8Encoding]::new($false))
                & git -C $Root apply --check -- $patchPath 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "The $kind shipping hunks do not apply to the exact upstream fixture." }
                & git -C $Root apply -- $patchPath 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "Applying the $kind shipping hunks failed." }
            }
            $modules[$kind] = [IO.File]::ReadAllText($path)
        }
        $producer = [regex]::Matches($modules.producer, '(?ms)^Функция (?:ЯВыполняюКодВстроенногоЯзыкаЧерезФайлСобытияРасширениеСлужебный|ITL\w+)\(.*?^КонецФункции[^\r\n]*') | ForEach-Object Value
        $receiver = if ($Patched) { [regex]::Match($modules.receiver, '(?ms)^Процедура VAExtension_ITLОбработатьФайлКода\(.*?^КонецПроцедуры[^\r\n]*').Value } else {
            # Select the original Windows thin-client preprocessor branch; no BSL body changes.
            $originalReceiver = [regex]::Match($modules.receiver, '(?ms)^Процедура VAExtension_ПроверкаКаталогаНаНовыеСобытия\(.*?^КонецПроцедуры[^\r\n]*').Value
            [regex]::Replace($originalReceiver, '(?m)^\s*#(?:Если|КонецЕсли)[^\r\n]*', '')
        }
        $prefix = @'
Перем Ванесса;
Перем КонтекстСохраняемый;
Перем ДатаНачалаОбработкиОжидания;
Перем КоличествоСекундОбработкаОжидания;
Перем СчетчикВызовов;
Перем VAExtensionОбщегоНазначенияВызовСервера;
Перем VAExtensionОбщегоНазначения;
Перем VAExtensionКлиент;
Перем VAExtension_КаталогиМониторинга;
Функция ПолучитьРазделительПути()
    Возврат "/";
КонецФункции
Процедура ОтключитьОбработчикОжидания(Имя)
КонецПроцедуры
'@
        $waiter = [regex]::Match($modules.wait, '(?ms)^Функция ЯЖдуРезультатПоследнегоСобытияЧерезФайлОбработчикОжидания\(.*?^КонецФункции[^\r\n]*').Value
        $probe = $prefix + "`n" + ($producer -join "`n") + "`n" + $receiver + "`n" + $waiter + "`nСчетчикВызовов = 0;`n"
        $probe += 'КаталогФикстуры = "' + $script:ClientCodeFixture.Replace('"','""') + '";' + "`n"
        $scenario = [IO.File]::ReadAllText((Join-Path $script:ClientCodeFixture 'scenario.os'))
        if ($Patched) {
            $scenario = [regex]::Replace($scenario, '(?ms)^Если Лев\(Сценарий, 7\) = "legacy-" Тогда.*?^КонецЕсли;\r?\n', '')
        }
        if (-not $Patched) {
            # Only the original precondition reproducer runs; no revised receiver is substituted.
            $scenario = $scenario.Substring(0, $scenario.IndexOf('КонтекстСохраняемый._СписокPIDКлиентовСМониторингомСобытий.Вставить'))
            $scenario = [regex]::Replace($scenario, '(?ms)^Если Сценарий = "consume" Тогда.*?^КонецЕсли;\r?\n', '')
        }
        $probe += $scenario
        $probePath = Join-Path $Root 'probe.os'
        [IO.File]::WriteAllText($probePath, $probe, [Text.UTF8Encoding]::new($true))
        return $probePath
    }

    function Invoke-ClientCodeProbe {
        param([string]$Root, [string]$Case, [bool]$Patched)
        $probePath = New-ClientCodeProbe -Root $Root -Patched $Patched
        $eventRoot = Join-Path $Root 'Event родитель с пробелом'
        [void][IO.Directory]::CreateDirectory($eventRoot)
        $start = [Diagnostics.ProcessStartInfo]::new()
        $start.FileName = $script:ClientCodeOneScript
        $start.Arguments = Join-NativeCommandLineArguments -Arguments @('-encoding=utf-8', $probePath, $Case, $eventRoot)
        $start.UseShellExecute = $false; $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
        $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
        $start.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
        $process = [Diagnostics.Process]::Start($start)
        try {
            $output = $process.StandardOutput.ReadToEndAsync(); $errors = $process.StandardError.ReadToEndAsync()
            if (-not $process.WaitForExit(30000)) { $process.Kill(); $process.WaitForExit(); throw 'OneScript client-code probe timed out.' }
            [pscustomobject]@{ exitCode=$process.ExitCode; output=$output.GetAwaiter().GetResult() + $errors.GetAwaiter().GetResult(); eventRoot=$eventRoot }
        } finally { $process.Dispose() }
    }
}

Describe 'Vanessa correlated file-code execution' {
    It 'reproduces the original receiver losing the outcome after executing the code: <case>' -TestCases @(@{case='legacy-void'},@{case='legacy-failed'}) {
        param($case)
        $result = Invoke-ClientCodeProbe -Root (Join-Path $TestDrive ('Исходный получатель ' + $case)) -Case $case -Patched $false
        $result.exitCode | Should -Be 0 -Because $result.output
        $result.output | Should -Match ('UPSTREAM_REPLY_LOST: ' + $case)
    }
    It 'executes and confirms the file command while the Windows clipboard is held open' {
        if (-not ('ItlClientCodeClipboardProbe' -as [type])) {
            Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class ItlClientCodeClipboardProbe {
    [DllImport("user32.dll", SetLastError = true)] public static extern bool OpenClipboard(IntPtr owner);
    [DllImport("user32.dll", SetLastError = true)] public static extern bool CloseClipboard();
}
'@
        }
        $opened = [ItlClientCodeClipboardProbe]::OpenClipboard([IntPtr]::Zero)
        if (-not $opened) { throw 'The busy-clipboard reproducer could not establish its own clipboard hold.' }
        try {
            # No clipboard contents are read or changed; the held handle reproduces access contention.
            $result = Invoke-ClientCodeProbe -Root (Join-Path $TestDrive 'Занятый буфер обмена') -Case 'void' -Patched $true
            $result.exitCode | Should -Be 0 -Because $result.output
            $result.output | Should -Match 'CLIENT_CODE_CASE_PASSED: void'
        } finally { [void][ItlClientCodeClipboardProbe]::CloseClipboard() }
    }
    It 'executes once across competing native processes and retains the claim after result loss' {
        $root = Join-Path $TestDrive 'Два процесса одного запроса'
        $probe = New-ClientCodeProbe -Root $root -Patched $true
        $id = [guid]::NewGuid().ToString()
        $requestPath = Join-Path $root ('Event_ITL_' + $id + '.json')
        $markerPrefix = (Join-Path $root 'executed_').Replace('"', '""')
        $code = 'ИмяМаркера = "' + $markerPrefix + '" + Строка(Новый УникальныйИдентификатор) + ".txt"; ЗаписьМаркера = Новый ЗаписьТекста(ИмяМаркера, КодировкаТекста.UTF8); ЗаписьМаркера.Записать("executed"); ЗаписьМаркера.Закрыть();'
        [IO.File]::WriteAllText($requestPath, (@{protocol='itl-file-code-v1';id=$id;target='client';code=$code} | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        $processes = @()
        try {
            foreach ($number in 1..2) {
                $start = [Diagnostics.ProcessStartInfo]::new()
                $start.FileName = $script:ClientCodeOneScript
                $start.Arguments = Join-NativeCommandLineArguments -Arguments @('-encoding=utf-8', $probe, 'consume', $requestPath)
                $start.UseShellExecute = $false; $start.CreateNoWindow = $true
                $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
                $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
                $start.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
                $processes += [Diagnostics.Process]::Start($start)
            }
            foreach ($process in $processes) {
                $process.WaitForExit(30000) | Should -BeTrue
                $process.ExitCode | Should -Be 0 -Because ($process.StandardOutput.ReadToEnd() + $process.StandardError.ReadToEnd())
            }
            @(Get-ChildItem $root -File -Filter 'executed_*.txt').Count | Should -Be 1
            $resultPath = Join-Path $root ('Result_ITL_' + $id + '.json')
            (Get-Content $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json).status | Should -Be 'succeeded'
            # Simulate lost/consumed response, leaving the actual request available for redelivery.
            [IO.File]::Delete($resultPath)
            $replay = [Diagnostics.Process]::Start($start)
            $processes += $replay
            $replay.WaitForExit(30000) | Should -BeTrue
            $replay.ExitCode | Should -Be 0 -Because ($replay.StandardOutput.ReadToEnd() + $replay.StandardError.ReadToEnd())
            @(Get-ChildItem $root -File -Filter 'executed_*.txt').Count | Should -Be 1
            (Join-Path $root ('Claim_ITL_' + $id + '.json')) | Should -Exist
            $requestPath | Should -Exist
            $resultPath | Should -Not -Exist
        } finally {
            foreach ($process in $processes) {
                if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
                $process.Dispose()
            }
        }
    }
    It 'reproduces upstream false success without an active monitor: <case>' -TestCases @(@{case='no-monitor'}, @{case='wrong-client'}) {
        param($case)
        $result = Invoke-ClientCodeProbe -Root (Join-Path $TestDrive ('Исходный канал ' + $case)) -Case $case -Patched $false
        $result.exitCode | Should -Be 0 -Because $result.output
        $result.output | Should -Match 'UPSTREAM_FALSE_SUCCESS'
        @(Get-ChildItem $result.eventRoot -File).Count | Should -Be 0
    }
    It 'rejects missing ownership or a pending command instead of returning success: <case>' -TestCases @(
        @{case='no-monitor'; error='ITL_CLIENT_CODE_MONITOR_NOT_STARTED'},
        @{case='wrong-client'; error='ITL_CLIENT_CODE_MONITOR_NOT_STARTED_FOR_CLIENT'},
        @{case='pending'; error='ITL_CLIENT_CODE_COMPLETION_UNKNOWN'}
    ) {
        param($case,$error)
        $result = Invoke-ClientCodeProbe -Root (Join-Path $TestDrive ('Проверка владельца ' + $case)) -Case $case -Patched $true
        $result.exitCode | Should -Not -Be 0
        $result.output | Should -Match $error
        $expectedEvents = if ($case -eq 'pending') { 1 } else { 0 }
        @(Get-ChildItem $result.eventRoot -File -Filter 'Event_ITL_*.json').Count | Should -Be $expectedEvents
    }
    It 'preserves actual execution and correlated completion: <case>' -TestCases @(
        @{case='void'}, @{case='value'}, @{case='multiline'}, @{case='failed'}, @{case='malformed'},
        @{case='timeout'}, @{case='wrong-response'}, @{case='publish-failure'}, @{case='repeat-failed'}
    ) {
        param($case)
        $result = Invoke-ClientCodeProbe -Root (Join-Path $TestDrive ('Выполнение команды ' + $case)) -Case $case -Patched $true
        $result.exitCode | Should -Be 0 -Because $result.output
        $result.output | Should -Match ('CLIENT_CODE_CASE_PASSED: ' + [regex]::Escape($case))
    }
}
