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
    function Get-FocusNewSide([string]$Path, [string]$Patch = $script:FocusPatch) {
        $builder = New-Object Text.StringBuilder
        $inHunk = $false
        foreach ($line in ((Get-FocusSection $Patch $Path) -split "`n")) {
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

    function New-AgentRouteProbe([string]$Patch = $script:FocusPatch, [string[]]$ExtraMethods = @(), [string]$BodyFile = 'agent-route.os') {
        $steps = Get-FocusNewSide $script:FocusSteps $Patch
        $methods = @(
            'ЯВыполняюКодВстроенногоЯзыкаРасширение', 'ЯВыполняюКодВстроенногоЯзыкаНаСервереРасширение',
            'ITLОтправитьКодВКанал', 'ITLВыполнитьКодШагаЧерезКаналАгента', 'ITLМониторЗапущенАгентом',
            'ITLОбеспечитьМониторКаналаАгента', 'ITLОжиданиеКодаШагаАгентаОбработчик', 'ITLПроверитьЗахватКодаШагаАгента',
            'ITLПродолжитьШагСОшибкой', 'ITLИмяФайлаЗапроса', 'ITLНормализоватьКаталог', 'ITLЗаписатьJSONАтомарно',
            'ITLПрочитатьJSONФайл', 'ITLПрочитатьСостояниеЗапроса', 'ITLПроверитьПовторКоманды', 'ITLПодготовитьКаталогКанала',
            'ITLИнициализироватьПоследнееСобытиеКанала', 'ITLПроверитьПодтверждениеРезультата', 'ITLКаталогКаналаЗавершен',
            'ITLОчиститьЗавершенныйКаталогКанала', 'ITLПодтвердитьПолучениеРезультата', 'ITLКлючКлиентаМониторинга',
            'ITLКомандаДляОжидания', 'ITLПрочитатьРезультатКоманды', 'ITLОжидатьРезультатКоманды'
        ) + $ExtraMethods | ForEach-Object { Get-FocusMethod $steps $_ }
        $receiver = Get-FocusMethod (Get-FocusNewSide $script:FocusReceiver $Patch) 'VAExtension_ITLОбработатьФайлКода'
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
        $body += [IO.File]::ReadAllText((Join-Path $script:FocusFixture $BodyFile), [Text.Encoding]::UTF8)
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

Describe 'Foreground measurement separates new 1C process windows from reactivation' {
    BeforeAll {
        $script:MeasureScript = Join-Path $script:FocusRepo 'scripts/measure-foreground-changes.ps1'
    }

    It 'describes a 1C process at a whitespace Cyrillic path by launch mode and masks its passwords: <launch>' -TestCases @(
        @{ launch = 'designer'; mode = 'DESIGNER' },
        @{ launch = 'testclient'; mode = 'ENTERPRISE /TESTCLIENT /TPort 48100' },
        @{ launch = 'testmanager'; mode = 'ENTERPRISE /TESTMANAGER' }
    ) {
        param($launch, $mode)
        # A copied PowerShell stands in for the platform: the hook reads facts of the
        # 1cv8 image, and the comment makes it ignore the 1C arguments.
        $platform = Join-Path $TestDrive ('Платформа 1С с пробелом ' + $launch)
        [void][IO.Directory]::CreateDirectory($platform)
        $image = Join-Path $platform '1cv8.exe'
        Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -Destination $image
        $start = [Diagnostics.ProcessStartInfo]::new()
        $start.FileName = $image
        $start.Arguments = '-NoProfile -NonInteractive -Command Start-Sleep -Seconds 60 # ' + $mode +
            ' /F "C:\База с пробелом\ИБ" /N "Агент ИТЛ" /P "секрет пароль" /ConfigurationRepositoryPтайное' +
            ' /IBConnectionString "File=""C:\ИБ с пробелом"";Usr=""Агент"";Pwd=""тайна два"";"'
        $start.UseShellExecute = $false; $start.CreateNoWindow = $true
        $before = [DateTime]::UtcNow.AddSeconds(-1)
        $process = [Diagnostics.Process]::Start($start)
        try {
            Start-Sleep -Milliseconds 300
            $facts = & $script:MeasureScript -DescribeProcessId $process.Id
        } finally { $process.Kill(); $process.WaitForExit(); $process.Dispose() }

        $facts.process | Should -Be '1cv8'
        $facts.launch | Should -Be $launch
        $facts.imagePath | Should -Be $image
        [DateTime]::Parse($facts.processStartUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) | Should -BeGreaterThan $before
        $facts.commandLine | Should -BeLike ('*' + $mode + ' /F "C:\База с пробелом\ИБ" /N "Агент ИТЛ" /P *** /ConfigurationRepositoryP*** *')
        $facts.commandLine | Should -BeLike '*Usr=""Агент"";Pwd=***;"'
        $facts.commandLine | Should -Not -Match 'секрет|тайн'
        # Every record carries the unelevated reasons Windows lets a background window in.
        [ItlForegroundRecorderV2]::ForegroundLockTimeoutMs() | Should -BeGreaterOrEqual 0
        [ItlForegroundRecorderV2]::InputIdleMs() | Should -BeGreaterOrEqual 0
    }

    It 'counts the first window of a process started during the recording apart from reactivations' {
        $t0 = [DateTime]::new(2026, 11, 6, 13, 0, 0, [DateTimeKind]::Utc)
        function New-Line([int]$Second, [string]$Kind, [int]$ProcessId, [string]$Process, [int]$StartSecond, [long]$Window, [string]$CommandLine) {
            [ordered]@{
                timeUtc = $t0.AddSeconds($Second).ToString('o'); kind = $Kind; window = $Window; processId = $ProcessId; process = $Process
                processStartUtc = $t0.AddSeconds($StartSecond).ToString('o'); className = 'V8TopLevelFrameSDI'; title = 'Конфигурация с пробелом'
                commandLine = $CommandLine
            } | ConvertTo-Json -Compress
        }
        $designer = '"C:\Program Files\1cv8\8.3.27\bin\1cv8.exe" DESIGNER /F "C:\ИБ с пробелом" /DisableStartupDialogs'
        $client = '"C:\Program Files\1cv8\8.3.27\bin\1cv8c.exe" ENTERPRISE /F "C:\ИБ с пробелом" /TESTCLIENT /TPort 48100'
        $stand = '"C:\Program Files\1cv8\8.3.27\bin\1cv8c.exe" /F "C:\ИБ с пробелом"'
        $lines = @(
            (New-Line 0 'initial' 100 'Code' -900 1 'Code.exe'),
            (New-Line 2 'foreground' 200 '1cv8' 1 21 $designer),        # new-process designer
            (New-Line 3 'foreground' 200 '1cv8' 1 22 $designer),        # new-window designer
            (New-Line 4 'clipboard' 200 '1cv8' 1 22 ''),
            (New-Line 5 'foreground' 100 'Code' -900 1 'Code.exe'),     # not 1C
            (New-Line 6 'foreground' 200 '1cv8' 1 21 $designer),        # reactivation designer
            (New-Line 7 'foreground' 300 '1cv8c' -60 31 $stand),        # reactivation: predates the recording
            (New-Line 8 'foreground' 400 '1cv8c' 7 41 $client),         # new-process testclient
            (New-Line 9 'foreground' 200 '1cv8' 8 23 $designer),        # reused PID, new process
            (New-Line 20 'initial' 100 'Code' -900 1 'Code.exe'),       # second appended segment
            (New-Line 21 'foreground' 400 '1cv8c' 7 41 $client)         # predates the second segment
        )
        $path = Join-Path $TestDrive 'Замер переднего плана с пробелом.jsonl'
        [IO.File]::WriteAllLines($path, [string[]]$lines, [Text.UTF8Encoding]::new($false))

        $rows = @(& $script:MeasureScript -SummarizePath $path)
        $table = @{}
        foreach ($row in $rows) { $table[$row.appearance + '/' + $row.launch + '/' + $row.process] = '{0}:{1}' -f $row.count, $row.processes }
        $table.Keys.Count | Should -Be 6
        $table['new-process/designer/1cv8'] | Should -Be '2:1' -Because 'a reused PID with a new start time is a new process'
        $table['new-window/designer/1cv8'] | Should -Be '1:1'
        $table['reactivation/designer/1cv8'] | Should -Be '1:1'
        $table['new-process/testclient/1cv8c'] | Should -Be '1:1'
        $table['reactivation/enterprise/1cv8c'] | Should -Be '1:1'
        $table['reactivation/testclient/1cv8c'] | Should -Be '1:1' -Because 'each appended initial record starts a new segment'
    }
}

Describe 'Vanessa 1.2.043.42-itl-r11 agent diagnostics' {
    BeforeAll {
        $script:R11Recipe = Join-Path $script:FocusRepo 'third-party/vanessa-automation/1.2.043.42-itl-r11'
        $script:R11Patch = [IO.File]::ReadAllText((Join-Path $script:R11Recipe 'file-operations.patch'), [Text.Encoding]::UTF8)
        $script:R11Mcp = 'VanessaAutomation/Forms/MCPVA/Ext/Form/Module.bsl'
        $script:R11McpTools = 'VanessaAutomation/Forms/MCPVA_Служебный/Ext/Form/Module.bsl'
        $script:R11Client = 'VanessaAutomation/Forms/КлиентТестирования/Ext/Form/Module.bsl'
        $script:R11UiSteps = 'features/Libraries/UITestRunner/step_definitions/РаботаСИнтерфейсом/Forms/Форма/Ext/Form/Module.bsl'
        $script:R11HtmlForm = 'lib/VAExtension/DataProcessors/VAExtension_НажатьГиперссылкуHTMLДокумента/Forms/Форма/Ext/Form'
        $script:R11Catalog = Join-Path $script:FocusRepo '.agents/skills/1c-workflow/assets/ondemand-mcp/catalogs/vanessa-ui-v0.6.5-va-1.2.043.42.json'
        $script:R11FeatureMethods = @('ITLПодготовитьЗагрузкуФичи', 'ITLФайлФичиНадоЗагрузитьЗаново', 'ITLФичаНеИзмениласьПриЗагрузке',
            'ITLДобавитьХешФичиВРезультат', 'ITLХешИТекстФайлаФичи', 'ITLSha256ДвоичныхДанных', 'ITLНедопустимыйСимволXMLВФиче',
            'ITLОшибкаИзмененияФичиПриЗагрузке', 'ОтклонитьКомандуMCPДоВыполнения') | ForEach-Object { ,@($script:R11Mcp, $_) }
        $script:R11McpPrefix = "Перем Ванесса;`nПерем СерверMCP;`nФункция МодульМсп_Сервер()`n    Возврат СерверMCP;`nКонецФункции"

        # A probe runs production methods of the r11 new side with framework doubles. The
        # fixture directory is assigned before the first statement of the body.
        function New-R11Probe([string]$Prefix, [object[]]$Methods, [string]$Body, [hashtable]$Replace = @{}) {
            $source = @($Methods | ForEach-Object { Get-FocusMethod (Get-FocusNewSide $_[0] $script:R11Patch) $_[1] }) -join "`n"
            foreach ($key in $Replace.Keys) {
                if (-not $source.Contains($key)) { throw "Missing probe adapter target $key" }
                $source = $source.Replace($key, $Replace[$key])
            }
            $bodyText = [IO.File]::ReadAllText((Join-Path $script:FocusFixture $Body), [Text.Encoding]::UTF8)
            $first = $bodyText.IndexOf('ПодключитьСценарий(')
            $bodyText = $bodyText.Insert($first, 'КаталогФикстуры = "' + $script:FocusFixture.Replace('"', '""') + '";' + "`n")
            $check = "Процедура Проверить(Условие, Код)`n    Если НЕ Условие Тогда ВызватьИсключение Код; КонецЕсли;`nКонецПроцедуры`n"
            return $Prefix + "`n" + $check + $source + "`n" + $bodyText
        }

        function Invoke-R11Case([string]$Source, [string[]]$Arguments) {
            $result = Invoke-FocusProbe -Source $Source -Arguments $Arguments
            $result.exitCode | Should -Be 0 -Because $result.output
            $result.output | Should -Match ('R11_CASE_PASSED: ' + [regex]::Escape($Arguments[0]))
        }
    }

    It 'pins a cumulative r11 recipe that changes only its owner sections of r10' {
        $manifest = Get-Content -LiteralPath (Join-Path $script:R11Recipe 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $manifest.downstreamRevision | Should -Be 'itl-r11'
        $manifest.upstream.commit | Should -Be 'a0ce2ee9803dd69be52f682e5cf49e0938fd33f1'
        $manifest.patch.gitDiffFormat | Should -Be 'full-index'
        (Get-FileHash -LiteralPath (Join-Path $script:R11Recipe 'file-operations.patch')).Hash.ToLowerInvariant() | Should -Be $manifest.patch.sha256
        $manifest.pairedExtension.fileName | Should -Be 'VAExtension.1.32-itl-r11.cfe'
        $manifest.pairedExtension.protocol | Should -Be 'itl-file-code-v1'
        $manifest.artifact.fileName | Should -Be 'vanessa-automation-single.1.2.043.42-itl-r11.zip'
        $prior = Get-Content -LiteralPath (Join-Path $script:FocusRecipe 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($fix in @($prior.patch.retainedDownstreamFixes)) { @($manifest.patch.retainedDownstreamFixes) | Should -Contain $fix }
        @($manifest.patch.retainedDownstreamFixes) | Should -HaveCount (@($prior.patch.retainedDownstreamFixes).Count + 5)
        # Only the module of the HTML hyperlink form is a new path; the order stays Git's.
        $expected = [Collections.Generic.List[string]]::new([string[]]@($prior.patch.expectedChangedPaths))
        $expected.Insert($expected.IndexOf($script:R11HtmlForm + '.xml') + 1, $script:R11HtmlForm + '/Module.bsl')
        @($manifest.patch.expectedChangedPaths) | Should -Be @($expected)
        $owners = @($script:R11Mcp, $script:R11McpTools, $script:R11Client, $script:R11UiSteps, $script:FocusSteps,
            'VanessaAutomation/Forms/УправляемаяФорма/Ext/Form/Module.bsl', ($script:R11HtmlForm + '.xml'), ($script:R11HtmlForm + '/Module.bsl'))
        foreach ($oldSection in @($script:FocusPatch -split '(?m)(?=^diff --git )' | Where-Object { $_ })) {
            $header = ($oldSection -split "`n")[0]
            if (@($owners | Where-Object { $header -ceq ('diff --git a/' + $_ + ' b/' + $_) }).Count -gt 0) { continue }
            $current = @($script:R11Patch -split '(?m)(?=^diff --git )' | Where-Object { ($_ -split "`n")[0] -ceq $header })
            $current.Count | Should -Be 1
            ($current[0] -replace '(?m)^index [^\n]+\n', '') | Should -BeExactly ($oldSection -replace '(?m)^index [^\n]+\n', '')
        }
        # Every r10 line of an owner section is still present on the r11 new side.
        foreach ($owner in @($owners | Where-Object { $_ -notlike ($script:R11HtmlForm + '/*') })) {
            $after = (Get-FocusNewSide $owner $script:R11Patch) -split "`n"
            $missing = @((Get-FocusNewSide $owner) -split "`n" | Where-Object { $_.Trim() -and $_ -ne '// HUNK' -and $after -notcontains $_ })
            $missing | Should -BeNullOrEmpty -Because $owner
        }
        $added = @($script:R11Patch -split "`n" | Where-Object { $_ -match '^\+[^+]' })
        @($added | Where-Object { $_ -match 'Новый\s+[\p{L}\p{Nd}_]+\([^()]*\)\s*\.' }) | Should -BeNullOrEmpty
        @($added | Where-Object { $_ -match '[\x00-\x08\x0B\x0C\x0E-\x1F]' }) | Should -BeNullOrEmpty
    }

    It 'routes the clipboard code steps of an agent run through the paired channel: <case>' -TestCases @(
        @{ case = 'clipboard-client-exception' }, @{ case = 'clipboard-server-compile' }, @{ case = 'clipboard-privileged-success' },
        @{ case = 'clipboard-manual' }, @{ case = 'clipboard-agent-without-channel' }
    ) {
        param($case)
        $root = Join-Path $TestDrive ('Канал буфера с пробелом ' + $case)
        [void][IO.Directory]::CreateDirectory($root)
        Invoke-R11Case -Source (New-AgentRouteProbe -Patch $script:R11Patch -ExtraMethods @('ITLВыполнитьКодЧерезБуферОбменаВКаналеАгента') -BodyFile 'r11-clipboard-route.os') -Arguments @($case, $root)
    }

    It 'dispatches every clipboard code step to the agent route before the unchecked clipboard command' {
        # PM5 false success: the upstream clipboard route places the code on the clipboard,
        # runs the TestClient command and continues without reading its outcome.
        $steps = Get-FocusNewSide $script:FocusSteps $script:R11Patch
        $steps | Should -Match '(?s)Функция ЯВыполняюКодВстроенногоЯзыкаЧерезБуферОбменаРасширениеСлужебный\(ТабПарам, НаКлиенте, ПривилегированныйРежим = Ложь\)\s+Если ITLВыполнитьКодЧерезБуферОбменаВКаналеАгента\(ТабПарам, НаКлиенте, ПривилегированныйРежим\) Тогда\s+Возврат Неопределено;\s+КонецЕсли;\s+ТекстКодаДляВыполнения = Ванесса\.МногострочнаяСтрокаИзПараметраШага\(ТабПарам\);'
        @([regex]::Matches($steps, 'ITLВыполнитьКодЧерезБуферОбменаВКаналеАгента\(')) | Should -HaveCount 2
    }

    It 'loads the current feature text for every filePath run and reports its SHA-256: <case>' -TestCases @(
        @{ case = 'reload' }, @{ case = 'changed-during-load' }
    ) {
        param($case)
        $directory = Join-Path $TestDrive ('Фичи с пробелом ' + $case)
        [void][IO.Directory]::CreateDirectory($directory)
        $path = Join-Path $directory 'Проверка выгрузки.feature'
        $second = Join-Path $directory 'Вторая версия.feature'
        $utf8 = [Text.UTF8Encoding]::new($true)
        [IO.File]::WriteAllText($path, "#language: ru`r`nФункционал: Проба`r`n`tСценарий: Первый`r`n`t`tИ в таблице 'ДеревоСтруктурыDTO' я перехожу к строке`r`n", $utf8)
        [IO.File]::WriteAllText($second, "#language: ru`r`nФункционал: Проба`r`n`tСценарий: Первый`r`n`t`tИ Я активизирую окно 'Администрирование рабочего стола*'`r`n", $utf8)
        $first = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        $next = (Get-FileHash -LiteralPath $second -Algorithm SHA256).Hash.ToLowerInvariant()
        $probe = New-R11Probe -Prefix $script:R11McpPrefix -Methods $script:R11FeatureMethods -Body 'r11-feature-load.os'
        Invoke-R11Case -Source $probe -Arguments @($case, $path, $second, $first, $next)
    }

    It 'rejects an XML-invalid character with file:line:column before the load: <case>' -TestCases @(
        @{ case = 'form-feed'; text = "#language: ru`r`nФункционал: Выгрузка`r`n    И я выбираю файл 'C:\export`fold'`r`n"; expected = '3:32 U+000C' },
        @{ case = 'bom-control'; text = "#lan`aguage: ru`r`n"; expected = '1:5 U+0007' }
    ) {
        param($case, $text, $expected)
        $directory = Join-Path $TestDrive ('Недопустимый символ ' + $case)
        [void][IO.Directory]::CreateDirectory($directory)
        $path = Join-Path $directory 'Проба с пробелом.feature'
        [IO.File]::WriteAllText($path, $text, [Text.UTF8Encoding]::new($true))
        $probe = New-R11Probe -Prefix $script:R11McpPrefix -Methods $script:R11FeatureMethods -Body 'r11-feature-load.os'
        Invoke-R11Case -Source $probe -Arguments @('invalid-character', $path, $expected)
    }

    It 'creates ХешированиеДанных only in server methods that the thin-client TestManager can call' {
        # Develop E2E: a client ХешированиеДанных kept the MCPVA form from compiling in the
        # thin client, and every TESTMANAGER run stopped at the platform error dialog.
        $sections = @($script:R11Patch -split '(?m)(?=^diff --git )' | Where-Object { $_ -match '^diff --git a/(\S+) ' })
        $checked = 0
        foreach ($section in $sections) {
            $path = [regex]::Match($section, '^diff --git a/(\S+) ').Groups[1].Value
            $text = Get-FocusNewSide $path $script:R11Patch
            foreach ($use in [regex]::Matches($text, 'Новый\s+ХешированиеДанных\b')) {
                $before = $text.Substring(0, $use.Index)
                $directive = [regex]::Matches($before, '(?m)^&[^\n]+') | Select-Object -Last 1
                $directive | Should -Not -BeNullOrEmpty -Because $path
                $before.Substring($directive.Index) | Should -Not -Match '// HUNK' -Because $path
                $directive.Value.Trim() | Should -Match '^&НаСервере' -Because $path
                $checked++
            }
        }
        $checked | Should -BeGreaterThan 0
    }

    It 'keeps the loader diagnostics for a missing feature file' {
        $probe = New-R11Probe -Prefix $script:R11McpPrefix -Methods $script:R11FeatureMethods -Body 'r11-feature-load.os'
        Invoke-R11Case -Source $probe -Arguments @('missing', (Join-Path $TestDrive 'Нет файла с пробелом.feature'))
    }

    It 'wires the feature load checks into run_scenario and states the contract in the catalog' {
        $mcp = Get-FocusNewSide $script:R11Mcp $script:R11Patch
        $mcp | Should -Match '(?s)ИначеЕсли \(НРег\(Ванесса\.Объект\.КаталогФич\) <> НРег\(ПутьКФайлу\)\) И ЗначениеЗаполнено\(ПутьКФайлу\) Тогда\s+МСПНадоОткрытьФайл = Истина;\s+КонецЕсли;\s+Если ITLФайлФичиНадоЗагрузитьЗаново\(ПутьКФайлу, ДопПараметрыВызоваMCP\) Тогда\s+МСПНадоОткрытьФайл = Истина;\s+КонецЕсли;'
        $mcp | Should -Match '(?s)Если НЕ ITLПодготовитьЗагрузкуФичи\(ИмяФайла, ДопПараметрыВызоваMCP\) Тогда\s+Возврат;\s+КонецЕсли;\s+Если Ванесса\.МодульРедакторТекста\(\)\.СуществуетВкладкаСФайлом\(ИмяФайла\) Тогда'
        $mcp | Should -Match '(?s)ИначеЕсли Тип = "ЗагрузитьФичуДляВыполненияСценария" Тогда\s+Если НЕ ITLФичаНеИзмениласьПриЗагрузке\(ДопПараметрыВызоваMCP\) Тогда\s+Возврат;'
        $mcp | Should -Match '(?s)ИначеЕсли Тип = "ЗагрузитьФичаФайлИВыполнитьСценарии" Тогда\s+Если НЕ ITLФичаНеИзмениласьПриЗагрузке\(ДопПараметрыВызоваMCP\) Тогда\s+Возврат;'
        $mcp | Should -Match '(?s)МассивСтрок\.Добавить\(""\);\s+ITLДобавитьХешФичиВРезультат\(МассивСтрок, ДопПараметрыВызоваMCP\);\s+НадоСнятьСкриншот = Ложь;'
        # The facade catalog states the same filePath and mode contract as the Vanessa tool source.
        $tools = Get-FocusNewSide $script:R11McpTools $script:R11Patch
        $catalog = Get-Content -LiteralPath $script:R11Catalog -Raw -Encoding UTF8 | ConvertFrom-Json
        $run = @($catalog.tools | Where-Object name -eq 'run_scenario')[0]
        foreach ($property in @('filePath', 'mode')) {
            $match = [regex]::Match($tools, 'MCPНовоеСвойствоОписания\("' + $property + '", "string", "([^"]+)"\)')
            $match.Success | Should -BeTrue -Because $property
            $run.inputSchema.properties.$property.description | Should -BeExactly $match.Groups[1].Value
        }
        $run.inputSchema.properties.filePath.description | Should -Match 'featureSha256'
        $line = ($run.description -split "`n")[1]
        $line | Should -Match 'featureSha256'
        $tools | Should -Match ('\|' + [regex]::Escape($line))
    }

    It 'confirms a navigated row only after the activation handlers settle: <case>' -TestCases @(
        @{ case = 'settled-match' }, @{ case = 'async-return' }, @{ case = 'no-current-row' },
        @{ case = 'never-settles' }, @{ case = 'normalized-criteria' }
    ) {
        param($case)
        $probe = New-R11Probe -Prefix 'Перем Ванесса;' -Methods @(
            @($script:R11Mcp, 'ITLОшибкаТекущейСтрокиПослеПерехода'), @($script:R11Mcp, 'ITLНормализоватьТекстЯчейки')
        ) -Body 'r11-row-settle.os'
        Invoke-R11Case -Source $probe -Arguments @($case)
    }

    It 'returns the settled row check from navigate_to_row' {
        $mcp = Get-FocusNewSide $script:R11Mcp $script:R11Patch
        $mcp | Should -Match '(?s)Ванесса\.ВТаблицеЯПерехожуКСтроке\(ИмяТаблицы, ТабПарам,,,ДопПараметры\);\s+(?://[^\n]*\s+)+ПоляПоЗаголовку = Новый Соответствие;.*?ОшибкаСтроки = ITLОшибкаТекущейСтрокиПослеПерехода\(Таблица, ИмяТаблицы, Колонки, Значения, ПоляПоЗаголовку\);\s+Если ЗначениеЗаполнено\(ОшибкаСтроки\) Тогда\s+Возврат МодульМсп_Сервер\(\)\.ОшибкаИнструмента\("ACTION_FAILED", ОшибкаСтроки\);\s+КонецЕсли;\s+Возврат Ванесса\.ПодставитьПараметрыВСтроку'
    }

    It 'clicks HTML document anchors through the TestClient DOM in agent runs: <case>' -TestCases @(
        @{ case = 'dom-details-text' }, @{ case = 'dom-normalized-text' }, @{ case = 'dom-href' }, @{ case = 'dom-missing' },
        @{ case = 'caller-agent-fallback' }, @{ case = 'caller-agent-missing' }, @{ case = 'caller-manual' },
        @{ case = 'caller-index' }, @{ case = 'caller-platform-click' }
    ) {
        param($case)
        $prefix = @('Ванесса', 'ПолеHTML', 'Введено', 'ФормаОбработкиОткрыта', 'ОкноКлиента', 'ОкноОбработки', 'ОткрытыеСсылки',
            'ИмяГиперссылки', 'ТипГиперссылки', 'СсылкаНайдена', 'НайденныеСсылки') | ForEach-Object { 'Перем ' + $_ + ';' }
        # OneScript has no TestClient types; only the type literal of the button search is adapted.
        $probe = New-R11Probe -Prefix ($prefix -join "`n") -Methods @(
            @($script:R11Client, 'ITLНажатьГиперссылкуВПолеHTML'), @($script:R11Client, 'ITLНажатьГиперссылкуHTMLЧерезDOM'),
            @(($script:R11HtmlForm + '/Module.bsl'), 'ITLНажатьНаГиперссылкуПоDOM'), @(($script:R11HtmlForm + '/Module.bsl'), 'ITLНормализоватьТекстСсылки')
        ) -Body 'r11-html-dom.os' -Replace @{ 'Тип("ТестируемаяКнопкаФормы")' = '"ТестируемаяКнопкаФормы"' }
        Invoke-R11Case -Source $probe -Arguments @($case)
    }

    It 'routes the HTML hyperlink step and MCP click_hyperlink through the HTML document click' {
        (Get-FocusNewSide $script:R11UiSteps $script:R11Patch) | Should -Match '(?s)Процедура ВПолеHTMLДокументаЯНажимаюГиперссылкуСлужебный\(ИмяЭлемента,ИмяГиперссылки, ИскатьПоИмени\)\s+(?://[^\n]*\s+)?Ванесса\.ITLНажатьГиперссылкуВПолеHTML\(ИмяЭлемента, ИмяГиперссылки, ИскатьПоИмени\);[^\n]*\s+КонецПроцедуры'
        (Get-FocusNewSide 'VanessaAutomation/Forms/УправляемаяФорма/Ext/Form/Module.bsl' $script:R11Patch) | Should -Match '(?s)Процедура ITLНажатьГиперссылкуВПолеHTML\(ИмяЭлемента, Гиперссылка, ИскатьПоИмени\) Экспорт\s+МодульКлиентТестирования\.ITLНажатьГиперссылкуВПолеHTML\(ИмяЭлемента, Гиперссылка, ИскатьПоИмени\);'
        (Get-FocusNewSide $script:R11Mcp $script:R11Patch) | Should -Match '(?s)Если ПолеHTML <> Неопределено И ТипЗнч\(ПолеHTML\) = Тип\("ТестируемоеПолеФормы"\)\s+И ПолеHTML\.Вид = ВидПоляФормы\.ПолеHTMLДокумента Тогда\s+Ванесса\.ITLНажатьГиперссылкуВПолеHTML\(ИмяЭлемента, \?\(ЗаголовокГиперссылки <> Неопределено, ЗаголовокГиперссылки, ИндексГиперссылки\), Истина\);\s+ИначеЕсли ИндексГиперссылки = Неопределено И ЗаголовокГиперссылки = Неопределено Тогда'
        $form = Get-FocusNewSide ($script:R11HtmlForm + '/Module.bsl') $script:R11Patch
        $form | Should -Match '(?s)Процедура НажатьНаГиперссылку\(ПолеHTMLДокумента\)\s+Если ТипГиперссылки = 3 Тогда\s+ITLНажатьНаГиперссылкуПоDOM\(ПолеHTMLДокумента\);\s+Возврат;'
        @([regex]::Matches($form, 'ПолеHTMLДокумента = ITLПолеHTMLДокументаОкна\((?:ТекОкно|ОкноНачальнойСтраницы)\);')) | Should -HaveCount 2
        $xml = Get-FocusNewSide ($script:R11HtmlForm + '.xml') $script:R11Patch
        $xml | Should -Match '(?s)<InputField name="НайденныеСсылки" id="31">\s+<DataPath>НайденныеСсылки</DataPath>'
        $xml | Should -Match '(?s)<Attribute name="НайденныеСсылки" id="8">.*?<v8:Type>xs:string</v8:Type>'
    }
}
