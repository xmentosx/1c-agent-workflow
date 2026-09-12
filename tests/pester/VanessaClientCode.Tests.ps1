BeforeAll {
    $script:ClientCodeRepo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    $script:ClientCodeFixture = Join-Path $script:ClientCodeRepo 'tests/fixtures/vanessa-client-code'
    $script:ClientCodePatch = Join-Path $script:ClientCodeRepo 'third-party/vanessa-automation/1.2.043.28-itl-r11/file-operations.patch'
    $script:ClientCodeOneScript = (Get-Command oscript -ErrorAction Stop).Source
    . (Join-Path $script:ClientCodeRepo '.agents/skills/1c-workflow/scripts/lib/agent-1c.core.ps1')

    function New-ClientCodeProbe {
        param([string]$Root, [bool]$Patched, [string]$ScenarioFile = 'scenario.os')
        [void][IO.Directory]::CreateDirectory($Root)
        $source = Get-Content (Join-Path $script:ClientCodeFixture 'source.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $patchText = [IO.File]::ReadAllText($script:ClientCodePatch)
        $modules = @{}
        foreach ($kind in @('producer', 'receiver', 'wait', 'startWait')) {
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
        $producer = [regex]::Matches($modules.producer, '(?ms)^(?:Функция ЯВыполняюКодВстроенногоЯзыкаЧерезФайлСобытияРасширениеСлужебный|(?:Функция|Процедура) ITL\w+)\(.*?^Конец(?:Функции|Процедуры)[^\r\n]*') | ForEach-Object Value
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
Процедура ПодключитьОбработчикОжидания(Имя, Период, Однократно)
КонецПроцедуры
'@
        $waiter = [regex]::Match($modules.wait, '(?ms)^Функция ЯЖдуРезультатПоследнегоСобытияЧерезФайлОбработчикОжидания\(.*?^КонецФункции[^\r\n]*').Value
        $waiter += "`n" + [regex]::Match($modules.startWait, '(?ms)^Функция ЯОжидаюСекундРезультатОбработкиПоследнегоСобытияЧерезФайлИЗапоминаюРезультатВПеременнуюРасширение\(.*?^КонецФункции[^\r\n]*').Value
        $probe = $prefix + "`n" + ($producer -join "`n") + "`n" + $receiver + "`n" + $waiter + "`nСчетчикВызовов = 0;`n"
        $probe += 'КаталогФикстуры = "' + $script:ClientCodeFixture.Replace('"','""') + '";' + "`n"
        $probe += 'ВерсияКанала = "' + $(if ($script:ClientCodePatch -match 'itl-r13') { 'itl-r13' } elseif ($script:ClientCodePatch -match 'itl-r12') { 'itl-r12' } else { 'itl-r11' }) + '";' + "`n"
        $scenario = [IO.File]::ReadAllText((Join-Path $script:ClientCodeFixture $ScenarioFile))
        if ($Patched) {
            $scenario = [regex]::Replace($scenario, '(?ms)^Если Лев\(Сценарий, 7\) = "legacy-" Тогда.*?^КонецЕсли;\r?\n', '')
        }
        if (-not $Patched) {
            # Only the original precondition reproducer runs; no revised receiver is substituted.
            $scenario = $scenario.Substring(0, $scenario.IndexOf('КонтекстСохраняемый._СписокPIDКлиентовСМониторингомСобытий.Вставить'))
            $scenario = [regex]::Replace($scenario, '(?ms)^Если Сценарий = "consume" Тогда.*?^КонецЕсли;\r?\n', '')
        }
        if ($Patched -and $script:ClientCodePatch -match 'itl-r1[23]') {
            $scenario = $scenario.Replace('КлючКлиентаДляПробы = 12345;', 'КлючКлиентаДляПробы = ITLКлючКлиентаМониторинга();')
        }
        $probe += $scenario
        $probePath = Join-Path $Root 'probe.os'
        [IO.File]::WriteAllText($probePath, $probe, [Text.UTF8Encoding]::new($true))
        return $probePath
    }

    function Invoke-ClientCodeProbe {
        param([string]$Root, [string]$Case, [bool]$Patched)
        $scenarioFile = if ($Case -eq 'identity-legacy-foreign') { 'recovery-r11.os' } elseif ($Case.StartsWith('identity-')) { 'recovery.os' } elseif ($Case.StartsWith('restart-')) { 'restart.os' } else { 'scenario.os' }
        $probePath = New-ClientCodeProbe -Root $Root -Patched $Patched -ScenarioFile $scenarioFile
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

Describe 'Vanessa correlated file-code execution <revision>' -ForEach @(@{revision='itl-r11'},@{revision='itl-r12'},@{revision='itl-r13'}) {
    BeforeAll {
        $script:ClientCodePatch = Join-Path $script:ClientCodeRepo "third-party/vanessa-automation/1.2.043.28-$revision/file-operations.patch"
    }
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
        try {
            # No clipboard contents are read or changed. When another owner already
            # makes it unavailable, retain that precondition and verify it again
            # after the probe instead of requiring this process to replace the owner.
            $result = Invoke-ClientCodeProbe -Root (Join-Path $TestDrive 'Занятый буфер обмена') -Case 'void' -Patched $true
            $result.exitCode | Should -Be 0 -Because $result.output
            $result.output | Should -Match 'CLIENT_CODE_CASE_PASSED: void'
            if (-not $opened) {
                $becameAvailable = [ItlClientCodeClipboardProbe]::OpenClipboard([IntPtr]::Zero)
                if ($becameAvailable) {
                    [void][ItlClientCodeClipboardProbe]::CloseClipboard()
                    throw 'Clipboard contention ended during the file-channel probe, so the unavailable-clipboard precondition was not proven.'
                }
            }
        } finally {
            if ($opened) { [void][ItlClientCodeClipboardProbe]::CloseClipboard() }
        }
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


Describe 'File-code monitor connection identity' {
    BeforeAll {
        $script:ClientCodePatch = Join-Path $script:ClientCodeRepo 'third-party/vanessa-automation/1.2.043.28-itl-r13/file-operations.patch'
    }
    It 'reproduces r11 dispatching to the other client when both profile PIDs are zero' {
        $savedPatch = $script:ClientCodePatch
        try {
            $script:ClientCodePatch = Join-Path $script:ClientCodeRepo 'third-party/vanessa-automation/1.2.043.28-itl-r11/file-operations.patch'
            $result = Invoke-ClientCodeProbe -Root (Join-Path $TestDrive 'Старый канал с нулевым PID') -Case 'identity-legacy-foreign' -Patched $true
            $result.exitCode | Should -Be 0 -Because $result.output
            $result.output | Should -Match 'R11_WRONG_CLIENT_DIRECTORY_REPRODUCED'
        } finally { $script:ClientCodePatch = $savedPatch }
    }
    It 'keeps the selected connection and request identity stable: <case>' -TestCases @(
        @{case='identity-selected-route'},@{case='identity-pid-becomes-known'},@{case='identity-host-case'},@{case='identity-switch-during-wait'}
    ) {
        param($case)
        $result = Invoke-ClientCodeProbe -Root (Join-Path $TestDrive ('Связь с клиентом ' + $case)) -Case $case -Patched $true
        $result.exitCode | Should -Be 0 -Because $result.output
        $result.output | Should -Match ('CLIENT_IDENTITY_CASE_PASSED: '+$case)
    }
    It 'rejects operations without their own connection ownership: <case>' -TestCases @(
        @{case='identity-foreign-send';error='ITL_CLIENT_CODE_MONITOR_NOT_STARTED_FOR_CLIENT'},
        @{case='identity-foreign-wait';error='ITL_CLIENT_CODE_PENDING_BELONGS_TO_ANOTHER_CLIENT'},
        @{case='identity-missing-endpoint';error='ITL_CLIENT_CODE_CONNECTION_IDENTITY_MISSING'}
    ) {
        param($case,$error)
        $result = Invoke-ClientCodeProbe -Root (Join-Path $TestDrive ('Чужой канал ' + $case)) -Case $case -Patched $true
        $result.exitCode | Should -Not -Be 0
        $result.output | Should -Match $error
        $expectedCount = if ($case -eq 'identity-foreign-wait') { 1 } else { 0 }
        @(Get-ChildItem $result.eventRoot -Recurse -File -Filter 'Event_ITL_*.json').Count | Should -Be $expectedCount
    }
}

Describe 'File-code restart reconciliation' {
    BeforeAll {
        $script:ClientCodePatch = Join-Path $script:ClientCodeRepo 'third-party/vanessa-automation/1.2.043.28-itl-r13/file-operations.patch'
    }
    It 'resumes the exact durable request without repeating its effect: <case>' -TestCases @(
        @{case='restart-terminal'}, @{case='restart-unclaimed'}, @{case='restart-unpublished'}
    ) {
        param($case)
        $result = Invoke-ClientCodeProbe -Root (Join-Path $TestDrive ('Перезапуск канала ' + $case)) -Case $case -Patched $true
        $result.exitCode | Should -Be 0 -Because $result.output
        $result.output | Should -Match ('CLIENT_RESTART_CASE_PASSED: ' + $case)
    }
    It 'keeps an already claimed request unresolved instead of executing it again' {
        $result = Invoke-ClientCodeProbe -Root (Join-Path $TestDrive 'Захваченный запрос после перезапуска') -Case 'restart-claimed-unknown' -Patched $true
        $result.exitCode | Should -Be 0 -Because $result.output
        $result.output | Should -Match 'CLIENT_RESTART_CASE_PASSED: restart-claimed-unknown'
    }
    It 'does not bind a foreign connection to the pending channel' {
        $result = Invoke-ClientCodeProbe -Root (Join-Path $TestDrive 'Чужое подключение после перезапуска') -Case 'restart-foreign-owner' -Patched $true
        $result.exitCode | Should -Be 0 -Because $result.output
        $result.output | Should -Match 'CLIENT_RESTART_CASE_PASSED: restart-foreign-owner'
    }
    It 'rejects a changed command while the recovered request is unresolved' {
        $result = Invoke-ClientCodeProbe -Root (Join-Path $TestDrive 'Измененная команда после перезапуска') -Case 'restart-changed-command' -Patched $true
        $result.exitCode | Should -Not -Be 0
        $result.output | Should -Match 'ITL_CLIENT_CODE_COMPLETION_UNKNOWN'
        @(Get-ChildItem $result.eventRoot -Recurse -File -Filter 'Event_ITL_*.json').Count | Should -Be 1
    }
    It 'fails closed when one connection has more than one unacknowledged request' {
        $result = Invoke-ClientCodeProbe -Root (Join-Path $TestDrive 'Неоднозначный перезапуск') -Case 'restart-ambiguous' -Patched $true
        $result.exitCode | Should -Not -Be 0
        $result.output | Should -Match 'ITL_CLIENT_CODE_RESTART_AMBIGUOUS'
        @(Get-ChildItem $result.eventRoot -Recurse -File -Filter 'Pending_ITL_*.json').Count | Should -Be 2
    }
}
