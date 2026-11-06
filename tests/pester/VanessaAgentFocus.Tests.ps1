BeforeAll {
    $script:FocusRepo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    $script:FocusFixture = Join-Path $script:FocusRepo 'tests/fixtures/vanessa-agent-focus'
    $script:FocusRecipe = Join-Path $script:FocusRepo 'third-party/vanessa-automation/1.2.043.42-itl-r10'
    $script:FocusPrior = Join-Path $script:FocusRepo 'third-party/vanessa-automation/1.2.043.42-itl-r8'
    . (Join-Path $script:FocusRepo '.agents/skills/1c-workflow/scripts/lib/agent-1c.core.ps1')
    $script:FocusPatch = [IO.File]::ReadAllText((Join-Path $script:FocusRecipe 'file-operations.patch'), [Text.Encoding]::UTF8)
    $script:FocusSteps = 'features/Libraries/VAExtension/VAExtension/Forms/Форма/Ext/Form/Module.bsl'
    $script:FocusReceiver = 'lib/VAExtension/Ext/ManagedApplicationModule.bsl'
    $script:FocusMainForm = 'VanessaAutomation/Forms/УправляемаяФорма/Ext/Form/Module.bsl'

    function Get-FocusSection([string]$Patch, [string]$Path) {
        $section = @($Patch -split '(?m)(?=^diff --git )' | Where-Object { ($_ -split "`n")[0] -ceq ('diff --git a/' + $Path + ' b/' + $Path) })
        if ($section.Count -ne 1) { throw "Expected one patch section for $Path" }
        return $section[0]
    }

    # The new-side text of every hunk; hunks are separated so that a method is
    # taken only when it is contained in one contiguous block of the patched file.
    function Get-FocusNewSide([string]$Path) {
        $builder = New-Object Text.StringBuilder
        $inHunk = $false
        foreach ($line in ((Get-FocusSection $script:FocusPatch $Path) -split "`n")) {
            if ($line.StartsWith('@@ ')) { $inHunk = $true; [void]$builder.Append("`n// HUNK`n"); continue }
            if (-not $inHunk -or $line.Length -eq 0) { continue }
            if ($line[0] -eq '+' -or $line[0] -eq ' ') { [void]$builder.Append($line.Substring(1) + "`n") }
        }
        return $builder.ToString()
    }

    function Get-FocusMethod([string]$Text, [string]$Name) {
        $match = [regex]::Match($Text, '(?ms)^(?:Функция|Процедура) ' + [regex]::Escape($Name) + '\(.*?^Конец(?:Функции|Процедуры)[^\n]*')
        if (-not $match.Success) { throw "Missing production method $Name" }
        if ($match.Value.Contains('// HUNK')) { throw "Production method $Name crosses a patch hunk boundary" }
        return $match.Value
    }

    function Invoke-FocusProbe([string]$Source, [string[]]$Arguments) {
        $probePath = Join-Path $TestDrive ('Проба агента с пробелом ' + [guid]::NewGuid().ToString('N') + '.os')
        [IO.File]::WriteAllText($probePath, $Source, [Text.UTF8Encoding]::new($true))
        $start = [Diagnostics.ProcessStartInfo]::new()
        $start.FileName = (Get-Command oscript -ErrorAction Stop).Source
        $start.Arguments = Join-NativeCommandLineArguments -Arguments (@('-encoding=utf-8', $probePath) + $Arguments)
        $start.UseShellExecute = $false; $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
        $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
        $start.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
        $process = [Diagnostics.Process]::Start($start)
        try {
            $output = $process.StandardOutput.ReadToEndAsync(); $errors = $process.StandardError.ReadToEndAsync()
            if (-not $process.WaitForExit(60000)) { $process.Kill(); $process.WaitForExit(); throw 'OneScript agent probe timed out.' }
            [pscustomobject]@{ exitCode = $process.ExitCode; output = $output.GetAwaiter().GetResult() + $errors.GetAwaiter().GetResult() }
        } finally { $process.Dispose() }
    }

    function New-AgentRouteProbe {
        $steps = Get-FocusNewSide $script:FocusSteps
        $methods = @(
            'ЯВыполняюКодВстроенногоЯзыкаРасширение', 'ЯВыполняюКодВстроенногоЯзыкаНаСервереРасширение',
            'ITLОтправитьКодВКанал', 'ITLВыполнитьКодШагаЧерезКаналАгента', 'ITLМониторЗапущенАгентом',
            'ITLОбеспечитьМониторКаналаАгента', 'ITLОжиданиеКодаШагаАгентаОбработчик', 'ITLПроверитьЗахватКодаШагаАгента',
            'ITLПродолжитьШагСОшибкой', 'ITLИмяФайлаЗапроса', 'ITLНормализоватьКаталог', 'ITLЗаписатьJSONАтомарно',
            'ITLПрочитатьJSONФайл', 'ITLПрочитатьСостояниеЗапроса', 'ITLПроверитьПовторКоманды', 'ITLПодготовитьКаталогКанала',
            'ITLИнициализироватьПоследнееСобытиеКанала', 'ITLПроверитьПодтверждениеРезультата', 'ITLКаталогКаналаЗавершен',
            'ITLОчиститьЗавершенныйКаталогКанала', 'ITLПодтвердитьПолучениеРезультата', 'ITLКлючКлиентаМониторинга',
            'ITLКомандаДляОжидания', 'ITLПрочитатьРезультатКоманды', 'ITLОжидатьРезультатКоманды'
        ) | ForEach-Object { Get-FocusMethod $steps $_ }
        $receiver = Get-FocusMethod (Get-FocusNewSide $script:FocusReceiver) 'VAExtension_ITLОбработатьФайлКода'
        $prefix = @'
Перем Ванесса;
Перем КонтекстСохраняемый;
Перем ДатаНачалаОбработкиОжидания;
Перем КоличествоСекундОбработкаОжидания;
Перем СчетчикВызовов;
Перем ВызовыФормы;
Перем ЗапускиМонитора;
Перем VAExtensionОбщегоНазначенияВызовСервера;
Перем Корень;
Функция ПолучитьРазделительПути()
    Возврат "/";
КонецФункции
Процедура ОтключитьОбработчикОжидания(Имя)
КонецПроцедуры
Процедура ПодключитьОбработчикОжидания(Имя, Период, Однократно)
КонецПроцедуры
// Upstream form route of the plain code step.
Функция ЯВыполняюКодВстроенногоЯзыкаРасширениеСлужебный(ТабПарам, НаКлиенте)
    ВызовыФормы = ВызовыФормы + 1;
КонецФункции
// Production monitor start without its TestClient UI actions.
Функция ЯЗапускаюМониторингКаталогаДляВнешнихСобытийРасширение(Знач ПутьДоКаталога) Экспорт
    ЗапускиМонитора = ЗапускиМонитора + 1;
    Ключ = ITLКлючКлиентаМониторинга();
    Если НЕ КонтекстСохраняемый.Свойство("_СписокPIDКлиентовСМониторингомСобытий") Тогда
        КонтекстСохраняемый.Вставить("_СписокPIDКлиентовСМониторингомСобытий", Новый Соответствие);
    КонецЕсли;
    Если КонтекстСохраняемый._СписокPIDКлиентовСМониторингомСобытий.Получить(Ключ) <> Неопределено Тогда
        ВызватьИсключение "ITL_CLIENT_CODE_MONITOR_ALREADY_STARTED";
    КонецЕсли;
    ПутьДоКаталога = ITLПодготовитьКаталогКанала(ПутьДоКаталога, Ключ);
    КонтекстСохраняемый._СписокPIDКлиентовСМониторингомСобытий.Вставить(Ключ, ПутьДоКаталога);
    КонтекстСохраняемый.Вставить("_ПутьДоКаталогаСобытий", ПутьДоКаталога);
    КонтекстСохраняемый.Вставить("_ЗапущенМониторингКаталогаСобытий", Истина);
    ITLИнициализироватьПоследнееСобытиеКанала();
КонецФункции
Процедура Проверить(Условие, Код)
    Если НЕ Условие Тогда ВызватьИсключение Код; КонецЕсли;
КонецПроцедуры
Функция ЕдинственныйФайл(Маска)
    Файлы = НайтиФайлы(Корень, Маска, Истина);
    Если Файлы.Количество() <> 1 Тогда ВызватьИсключение "EXPECTED_ONE_FILE: " + Маска + "=" + Файлы.Количество(); КонецЕсли;
    Возврат Файлы[0].ПолноеИмя;
КонецФункции
Функция ПрочитатьJSONФайлПробы(Имя)
    Чтение = Новый ЧтениеJSON;
    Чтение.ОткрытьФайл(Имя);
    Значение = ПрочитатьJSON(Чтение);
    Чтение.Закрыть();
    Возврат Значение;
КонецФункции
Процедура Потребить()
    Для Каждого ФайлСобытия Из НайтиФайлы(Корень, "Event_ITL_*.json", Истина) Цикл
        VAExtension_ITLОбработатьФайлКода(ФайлСобытия);
    КонецЦикла;
КонецПроцедуры
Процедура Ждать()
    ITLОжиданиеКодаШагаАгентаОбработчик();
КонецПроцедуры
'@
        $body = 'КаталогФикстуры = "' + $script:FocusFixture.Replace('"', '""') + '";' + "`n"
        $body += [IO.File]::ReadAllText((Join-Path $script:FocusFixture 'agent-route.os'), [Text.Encoding]::UTF8)
        return $prefix + "`n" + ($methods -join "`n") + "`n" + $receiver + "`n" + $body
    }
}

Describe 'Vanessa agent launch keeps the TestClient out of the foreground' {
    It 'pins a cumulative r10 recipe that retains every r8 change outside its owner sections' {
        $manifest = Get-Content -LiteralPath (Join-Path $script:FocusRecipe 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $manifest.downstreamRevision | Should -Be 'itl-r10'
        $manifest.upstream.commit | Should -Be 'a0ce2ee9803dd69be52f682e5cf49e0938fd33f1'
        (Get-FileHash -LiteralPath (Join-Path $script:FocusRecipe 'file-operations.patch')).Hash.ToLowerInvariant() | Should -Be $manifest.patch.sha256
        $manifest.pairedExtension.fileName | Should -Be 'VAExtension.1.32-itl-r10.cfe'
        $manifest.pairedExtension.protocol | Should -Be 'itl-file-code-v1'
        $manifest.artifact.fileName | Should -Be 'vanessa-automation-single.1.2.043.42-itl-r10.zip'
        $priorManifest = Get-Content -LiteralPath (Join-Path $script:FocusPrior 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($fix in @($priorManifest.patch.retainedDownstreamFixes)) { @($manifest.patch.retainedDownstreamFixes) | Should -Contain $fix }
        foreach ($path in @($priorManifest.patch.expectedChangedPaths)) { @($manifest.patch.expectedChangedPaths) | Should -Contain $path }

        $owners = @(
            $script:FocusSteps, $script:FocusMainForm,
            'VanessaAutomation/Forms/КлиентТестирования/Ext/Form/Module.bsl',
            'VanessaAutomation/Forms/SikuliXСервер/Ext/Form/Module.bsl',
            'VanessaAutomation/Forms/UIAutomation/Ext/Form/Module.bsl',
            'features/Libraries/SikuliX/SikuliXServer/Forms/Форма/Ext/Form/Module.bsl',
            'features/Libraries/UIAutomation/UIAutomation/Forms/Форма/Ext/Form/Module.bsl',
            'features/Libraries/VB/step_definitions/Док_ОткрытиеФормыLib/Forms/Форма/Ext/Form/Module.bsl',
            'features/Libraries/VanessaExt/VanessaExt/Forms/Форма/Ext/Form/Module.bsl'
        )
        @($manifest.patch.expectedChangedPaths) | Should -HaveCount (@($priorManifest.patch.expectedChangedPaths).Count + 6)
        $prior = [IO.File]::ReadAllText((Join-Path $script:FocusPrior 'file-operations.patch'), [Text.Encoding]::UTF8)
        foreach ($oldSection in @($prior -split '(?m)(?=^diff --git )' | Where-Object { $_ })) {
            $header = ($oldSection -split "`n")[0]
            if (@($owners | Where-Object { $header -ceq ('diff --git a/' + $_ + ' b/' + $_) }).Count -gt 0) { continue }
            $current = @($script:FocusPatch -split '(?m)(?=^diff --git )' | Where-Object { ($_ -split "`n")[0] -ceq $header })
            $current.Count | Should -Be 1
            ($current[0] -replace '(?m)^index [^\n]+\n', '') | Should -BeExactly ($oldSection -replace '(?m)^index [^\n]+\n', '')
        }
    }

    It 'adds no property access on a Новый expression, which the 8.3.27 platform rejects and OneScript accepts' {
        # r10 build evidence: one such expression dropped the whole VAExtension library from the step cache.
        $added = @($script:FocusPatch -split "`n" | Where-Object { $_ -match '^\+[^+]' })
        @($added | Where-Object { $_ -match 'Новый\s+[\p{L}\p{Nd}_]+\([^()]*\)\s*\.' }) | Should -BeNullOrEmpty
    }

    It 'routes the plain code steps through the paired channel: <case>' -TestCases @(
        @{ case = 'manual' }, @{ case = 'no-identity' }, @{ case = 'client' }, @{ case = 'server' },
        @{ case = 'failure' }, @{ case = 'result-variable' }, @{ case = 'restart-recovered' }, @{ case = 'restart-withdrawn' }
    ) {
        param($case)
        $root = Join-Path $TestDrive ('Канал агента с пробелом ' + $case)
        [void][IO.Directory]::CreateDirectory($root)
        $result = Invoke-FocusProbe -Source (New-AgentRouteProbe) -Arguments @($case, $root)
        $result.exitCode | Should -Be 0 -Because $result.output
        $result.output | Should -Match ('AGENT_ROUTE_CASE_PASSED: ' + [regex]::Escape($case))
    }

    It 'reproduces the lost reply that the route avoids by resetting the consumer result' {
        $root = Join-Path $TestDrive 'Канал без сброса результата'
        [void][IO.Directory]::CreateDirectory($root)
        $result = Invoke-FocusProbe -Source (New-AgentRouteProbe) -Arguments @('result-variable-unwrapped', $root)
        $result.exitCode | Should -Be 0 -Because $result.output
        $result.output | Should -Match 'UNWRAPPED_REPLY_LOST'
    }

    It 'reuses an agent-started monitor when a scenario starts monitoring itself and forgets it on stop' {
        $steps = Get-FocusNewSide $script:FocusSteps
        $steps | Should -Match '(?s)ITL_CLIENT_CODE_MONITOR_ALREADY_STARTED.*?' -Because 'the existing duplicate guard is kept'
        $steps | Should -Match '(?s)Если ITLМониторЗапущенАгентом\(ТекущийКлючКлиента\) Тогда.*?ITL_CLIENT_CODE_MONITOR_REUSED.*?Возврат Неопределено;.*?ВызватьИсключение "ITL_CLIENT_CODE_MONITOR_ALREADY_STARTED";'
        $steps | Should -Match '(?s)_СписокPIDКлиентовСМониторингомСобытий\.Удалить\(ТекущийКлючКлиента\);\s*Если КонтекстСохраняемый\.Свойство\("_ITLМониторыКаналаАгента"\) Тогда\s*КонтекстСохраняемый\._ITLМониторыКаналаАгента\.Удалить\(ТекущийКлючКлиента\);'
    }

    It 'marks only agent launches and activates the TestClient only before foreign-foreground OS input' {
        $form = Get-FocusNewSide $script:FocusMainForm
        $prefix = @'
Перем Объект;
Перем ВнешняяКомпонентаДляСкриншотов;
Перем PIDТекущегоКлиентаТестирования;
Перем ДескрипторОсновногоОкнаТекущегоКлиентаТестирования;
Функция ПрочитатьСтрокуJSON(Текст)
    Чтение = Новый ЧтениеJSON;
    Чтение.УстановитьСтроку(Текст);
    Значение = ПрочитатьJSON(Чтение);
    Чтение.Закрыть();
    Возврат Значение;
КонецФункции
Процедура ЗаписатьЛогВЖРОшибка(Событие, Текст)
КонецПроцедуры
Процедура Проверить(Условие, Код)
    Если НЕ Условие Тогда ВызватьИсключение Код; КонецЕсли;
КонецПроцедуры
'@
        $methods = @('ITLАгентскийЗапуск', 'ITLКаталогКаналаКодаАгента', 'ITLАктивироватьКлиентТестированияДляВводаОС') | ForEach-Object { Get-FocusMethod $form $_ }
        $body = 'КаталогФикстуры = "' + $script:FocusFixture.Replace('"', '""') + '";' + "`n" + [IO.File]::ReadAllText((Join-Path $script:FocusFixture 'ui-helpers.os'), [Text.Encoding]::UTF8)
        $result = Invoke-FocusProbe -Source ($prefix + "`n" + ($methods -join "`n") + "`n" + $body) -Arguments @()
        $result.exitCode | Should -Be 0 -Because $result.output
        $result.output | Should -Match 'UI_HELPERS_PASSED'
    }

    It 'owns the agent launch parameters and removes only a fully acknowledged channel' {
        $root = Join-Path $TestDrive 'Проект агента с пробелом'
        [void][IO.Directory]::CreateDirectory((Join-Path $root '.agent-1c'))
        $result = & {
            . (Join-Path $script:FocusRepo '.agents/skills/1c-workflow/scripts/agent-1c.ps1') -ProjectRoot $root -Action help *> $null
            $short = [ordered]@{}
            $shortAgent = Add-VanessaAgentLaunchParams -Params $short -ClientCodeChannelRoot (Join-Path $root 'run с пробелом\cc')
            $long = [ordered]@{}
            $longRoot = Join-Path $root ('x' * 200)
            $longAgent = Add-VanessaAgentLaunchParams -Params $long -ClientCodeChannelRoot $longRoot
            $channel = Join-Path $root 'канал'
            $events = Join-Path $channel 'itl-a\events'
            [void][IO.Directory]::CreateDirectory($events)
            Set-Content -LiteralPath (Join-Path $events 'Pending_ITL_1.json') -Value '{}'
            $kept = Remove-VanessaAgentClientCodeChannel -Root $channel
            $keptExists = Test-Path -LiteralPath $channel
            Set-Content -LiteralPath (Join-Path $events 'Ack_ITL_1.json') -Value '{}'
            $removed = Remove-VanessaAgentClientCodeChannel -Root $channel
            [pscustomobject]@{
                short = $short; shortAgent = $shortAgent; long = $long; longAgent = $longAgent; longRootExists = Test-Path -LiteralPath $longRoot
                kept = $kept; keptExists = $keptExists; removed = $removed; removedExists = Test-Path -LiteralPath $channel
                missing = Remove-VanessaAgentClientCodeChannel -Root (Join-Path $root 'нет')
            }
        }
        $result.short.dopparams.ITLAgentLaunch | Should -BeTrue
        $result.short.dopparams.ITLClientCodeChannelRoot | Should -Be (Join-Path $root 'run с пробелом\cc')
        Test-Path -LiteralPath (Join-Path $root 'run с пробелом\cc') -PathType Container | Should -BeTrue
        # A root without MAX_PATH room keeps the agent launch and the form path of the code steps.
        $result.long.dopparams.ITLAgentLaunch | Should -BeTrue
        $result.long.dopparams.Contains('ITLClientCodeChannelRoot') | Should -BeFalse
        $result.longRootExists | Should -BeFalse
        $result.kept | Should -BeFalse
        $result.keptExists | Should -BeTrue
        $result.removed | Should -BeTrue
        $result.removedExists | Should -BeFalse
        $result.missing | Should -BeTrue
    }

    It 'skips connect-time activation and captures the client process window in agent launches' {
        $form = Get-FocusNewSide $script:FocusMainForm
        # Both upstream procedures are longer than their hunks; their changed blocks are asserted in place.
        $form | Should -Match '(?s)// ITL agent runs keep the user''s foreground window; OS input activates the client itself\.\s+Если Объект\.ИспользоватьКомпонентуVanessaExt\s+И ДескрипторОсновногоОкнаТекущегоКлиентаТестирования <> Неопределено\s+И НЕ ITLАгентскийЗапуск\(\)\s+Тогда\s+Оповещение = ОписаниеПустогоОбработчика\(3\);\s+ВнешняяКомпонентаДляСкриншотов\.НачатьВызовАктивироватьОкно\(Оповещение, ДескрипторОсновногоОкнаТекущегоКлиентаТестирования\);'
        $form | Should -Match '(?s)Процедура СделатьСкриншотыВсехОконКомпонентаПродолжение\(\) Экспорт\s+(?://[^\n]*\s+)+ITLФоновыйСнимок = ITLАгентскийЗапуск\(\) И ЗначениеЗаполнено\(PIDТекущегоКлиентаТестирования\);\s+Если Объект\.ИспользоватьКомпонентуVanessaExt\s+И ДескрипторОсновногоОкнаТекущегоКлиентаТестирования <> Неопределено\s+И ВнешняяКомпонентаДляСкриншотов <> Неопределено\s+И НЕ ITLФоновыйСнимок\s+Тогда\s+Попытка\s+Оповещение = ОписаниеПустогоОбработчика\(3\);'
        $form | Should -Match '(?s)Вставить\("ИмяПроцедуры", "СделатьСкриншотыВсехОконКомпонентаПродолжение2"\);\s+ПараметрыСкриншотов\.Вставить\("ИмяПроцедурыПриОшибкеСохранения", "ЗавершитьСнятиеСкриншотовОшибки"\);\s+ПараметрыСкриншотов\.Вставить\("СпособСнятияСкриншотовВнешнейКомпонентой", \?\(ITLФоновыйСнимок, 1, 0\)\);'
        # The upstream web-client branch and every other capture keep their modes.
        @([regex]::Matches($form, 'ITLФоновыйСнимок')) | Should -HaveCount 3
    }

    It 'activates the TestClient before every OS keyboard and mouse emulation it changes' {
        $sites = @{
            'VanessaAutomation/Forms/КлиентТестирования/Ext/Form/Module.bsl' = 1
            'VanessaAutomation/Forms/SikuliXСервер/Ext/Form/Module.bsl' = 2
            'VanessaAutomation/Forms/UIAutomation/Ext/Form/Module.bsl' = 3
            'features/Libraries/SikuliX/SikuliXServer/Forms/Форма/Ext/Form/Module.bsl' = 5
            'features/Libraries/UIAutomation/UIAutomation/Forms/Форма/Ext/Form/Module.bsl' = 3
            'features/Libraries/VB/step_definitions/Док_ОткрытиеФормыLib/Forms/Форма/Ext/Form/Module.bsl' = 1
            'features/Libraries/VanessaExt/VanessaExt/Forms/Форма/Ext/Form/Module.bsl' = 5
            $script:FocusMainForm = 4
        }
        foreach ($path in $sites.Keys) {
            $added = @((Get-FocusSection $script:FocusPatch $path) -split "`n" | Where-Object { $_ -match '^\+\s*(?:Ванесса\.)?ITLАктивироватьКлиентТестированияДляВводаОС\(\);' })
            $added | Should -HaveCount $sites[$path] -Because $path
            $lines = (Get-FocusNewSide $path) -split "`n"
            for ($index = 0; $index -lt $lines.Count; $index++) {
                if ($lines[$index] -match '^\s*(?:Ванесса\.)?ВнешняяКомпонентаДляСкриншотов\.(?:НачатьВызов)?Эмуляция(?:Нажатия|Ввода|Колеса|Двойного|Перетаскивания)') {
                    # The activation precedes the emulation within the same short block.
                    $window = @($lines[([Math]::Max(0, $index - 6))..($index - 1)] | Where-Object { $_ -ne '// HUNK' })
                    ($window -join "`n") | Should -Match 'ITLАктивироватьКлиентТестированияДляВводаОС\(\);|ВыполнитьПеремещениеМышкиВнешнейКомпонентой' -Because "$path line '$($lines[$index].Trim())'"
                }
            }
        }
    }
}
