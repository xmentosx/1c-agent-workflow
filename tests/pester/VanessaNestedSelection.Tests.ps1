BeforeAll {
    $script:NestedSelectionRepo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    $script:NestedSelectionFixture = Join-Path $script:NestedSelectionRepo 'tests/fixtures/vanessa-nested-selection'
    $script:NestedSelectionAsset = Join-Path $script:NestedSelectionRepo 'third-party/vanessa-automation/1.2.043.28-itl-r9'
    $script:OneScriptPath = (Get-Command oscript -ErrorAction Stop).Source

    function Invoke-NestedFeatureProbe {
        param([string]$Root, [bool]$Patched, [bool]$ReverseOrder = $false, [bool]$NoFilter = $false)
        [void][IO.Directory]::CreateDirectory($Root)
        # Recreate the pinned upstream LF text even when Git checked out this
        # source fixture with Windows line endings. Product files are untouched.
        $upstreamFilter = [IO.File]::ReadAllText((Join-Path $script:NestedSelectionFixture 'filter.bsl')).Replace("`r`n", "`n")
        [IO.File]::WriteAllText((Join-Path $Root 'filter.bsl'), $upstreamFilter, [Text.UTF8Encoding]::new($true))
        if ($Patched) {
            $patch = [IO.File]::ReadAllText((Join-Path $script:NestedSelectionAsset 'file-operations.patch'))
            $hunks = @([regex]::Matches($patch, '(?ms)^@@ [^\r\n]*\r?\n.*?(?=^@@ |^diff --git |\z)') | Where-Object {
                $_.Value.Contains('ДанныеВыбраннойФичи.Уровень = 1;')
            })
            if ($hunks.Count -ne 1) { throw 'The selected-feature owner hunk must be unique.' }
            $focusedPatch = "--- a/filter.bsl`n+++ b/filter.bsl`n" + $hunks[0].Value
            $patchPath = Join-Path $Root 'selection.patch'
            [IO.File]::WriteAllText($patchPath, $focusedPatch, [Text.UTF8Encoding]::new($false))
            & git -C $Root apply --check -- $patchPath 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Candidate hunk does not apply to the exact upstream fixture.' }
            & git -C $Root apply -- $patchPath 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Applying the candidate hunk failed.' }
        }
        $filter = [IO.File]::ReadAllText((Join-Path $Root 'filter.bsl'))
        $builder = [IO.File]::ReadAllText((Join-Path $script:NestedSelectionFixture 'tree-builder.bsl'))
        $prefix = @'
Процедура ДобавитьВход(МассивВхода, Имя, Уровень, Каталог)
    Путь = "C:/Тест с пробелом/features/" + Имя;
    МассивВхода.Добавить(Новый Структура("Каталог,Имя,ПолныйПуть,Уровень,Фича", Каталог, Имя, Путь, Уровень, НЕ Каталог));
КонецПроцедуры

Процедура СобратьДоступныеФичи(Дерево, Результат)
    Для Каждого Строка Из Дерево.Строки Цикл
        Если Строка.Тип = "Фича" Тогда
            Результат.Добавить(Строка.ПолныйПуть);
        Иначе
            СобратьДоступныеФичи(Строка, Результат);
        КонецЕсли;
    КонецЦикла;
КонецПроцедуры

Объект = Новый Структура("СписокФичДляВыполнения", Новый СписокЗначений);
МассивРезультатОбходаКаталогов = Новый Массив;
ДобавитьВход(МассивРезультатОбходаКаталогов, "", 1, Истина);
ДобавитьВход(МассивРезультатОбходаКаталогов, "Корневая.feature", 2, Ложь);
ДобавитьВход(МассивРезультатОбходаКаталогов, "БДР", 2, Истина);
ДобавитьВход(МассивРезультатОбходаКаталогов, "БДР/ЗакрытиеРасшифровки.feature", 3, Ложь);
ДобавитьВход(МассивРезультатОбходаКаталогов, "БДР/Подкаталог с пробелом", 3, Истина);
ДобавитьВход(МассивРезультатОбходаКаталогов, "БДР/Подкаталог с пробелом/ОткрытиеРасшифровки.feature", 4, Ложь);
ОжидаемыеПути = Новый Массив;
Для Каждого Элем Из МассивРезультатОбходаКаталогов Цикл
    Если НЕ Элем.Каталог Тогда ОжидаемыеПути.Добавить(Элем.ПолныйПуть); КонецЕсли;
КонецЦикла;
'@
        if ($ReverseOrder) {
            $prefix += "`nОжидаемыеПути.Вставить(0, ОжидаемыеПути[2]); ОжидаемыеПути.Удалить(3);`n"
        }
        if (-not $NoFilter) {
            $prefix += "`nДля Каждого Путь Из ОжидаемыеПути Цикл Объект.СписокФичДляВыполнения.Добавить(Путь); КонецЦикла;`n"
        }
        $prefix += @'

Дерево = Новый ДеревоЗначений;
Для Каждого Имя Из СтрРазделить("Тип,ТипКартинки,ПолныйПуть,Имя", ",") Цикл Дерево.Колонки.Добавить(Имя); КонецЦикла;
'@
        $assertions = @'

ДоступныеФичи = Новый Массив;
СобратьДоступныеФичи(Дерево, ДоступныеФичи);
Если ДоступныеФичи.Количество() <> ОжидаемыеПути.Количество() Тогда
    ВызватьИсключение "SELECTED_FEATURES_OMITTED: expected=" + ОжидаемыеПути.Количество() + "; actual=" + ДоступныеФичи.Количество();
КонецЕсли;
Для Номер = 0 По ОжидаемыеПути.Количество() - 1 Цикл
    Если ДоступныеФичи[Номер] <> ОжидаемыеПути[Номер] Тогда ВызватьИсключение "FEATURE_PATH_OR_ORDER_CHANGED"; КонецЕсли;
КонецЦикла;
Сообщить("ALL_SELECTED_FEATURE_IDENTITIES_REACH_LOADING");
'@
        $probePath = Join-Path $Root 'probe.os'
        [IO.File]::WriteAllText($probePath, $prefix + "`n" + $filter + "`n" + $builder + "`n" + $assertions, [Text.UTF8Encoding]::new($true))
        $output = & $script:OneScriptPath $probePath 2>&1
        [pscustomobject]@{ exitCode = $LASTEXITCODE; output = $output -join "`n" }
    }
}

Describe 'Selected nested feature ownership in the Vanessa tree' {
    It 'reproduces omitted features in the unchanged pinned upstream algorithm' {
        $result = Invoke-NestedFeatureProbe -Root (Join-Path $TestDrive 'Исходный с пробелом') -Patched $false
        $result.exitCode | Should -Not -Be 0
        $result.output | Should -Match 'SELECTED_FEATURES_OMITTED: expected=3; actual=1'
    }
    It 'keeps every selected physical path once and in the requested order after the candidate hunk' -TestCases @(
        @{ reverse = $false }, @{ reverse = $true }
    ) {
        param($reverse)
        $result = Invoke-NestedFeatureProbe -Root (Join-Path $TestDrive ("Исправление с пробелом $reverse")) -Patched $true -ReverseOrder $reverse
        $result.exitCode | Should -Be 0 -Because $result.output
        $result.output | Should -Match 'ALL_SELECTED_FEATURE_IDENTITIES_REACH_LOADING'
    }
    It 'retains ordinary directory traversal when no feature filter is requested' {
        $result = Invoke-NestedFeatureProbe -Root (Join-Path $TestDrive 'Без фильтра с пробелом') -Patched $true -NoFilter $true
        $result.exitCode | Should -Be 0 -Because $result.output
    }
}
