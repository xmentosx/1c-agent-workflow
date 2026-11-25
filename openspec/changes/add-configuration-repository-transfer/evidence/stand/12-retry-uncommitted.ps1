. (Join-Path $PSScriptRoot 'stand-lib.ps1')
$bom = New-Object Text.UTF8Encoding $true
$dev = Join-Path $Root 'ИБ разработчика'
$col = Join-Path $Root 'ИБ коллеги'
$rep = Join-Path $Root 'отчёты'
$cat = 'Catalog.ITLСправочникСДлиннымКириллическимИменемДляПроверкиБюджетаПутей'
$form = 'DataProcessor.ITLОбработкаПроверкиОбработчиковФормы.Form.ФормаПроверкиОбработчиковСДлиннымИменем'
$catList = Write-ObjectList (Join-Path $Root 'справочник.xml') @($cat)
$formList = Join-Path $Root 'объекты-формы.xml'
$r = @()
# dev: first CF applied but not committed (catalog synonym)
$r += Invoke-1C -Ib $dev -Arguments ((Repo-Args 'Разработчик') + @('/ConfigurationRepositoryLock', '-Objects', $catList)) -Label 'dev-lock-cat'
$d = Join-Path $Root 'ветка 3'
$r += Invoke-1C -Ib $dev -Arguments @('/DumpConfigToFiles', $d) -Label 'dev-dump'
$catXml = Join-Path $d 'Catalogs\ITLСправочникСДлиннымКириллическимИменемДляПроверкиБюджетаПутей.xml'
[IO.File]::WriteAllText($catXml, [IO.File]::ReadAllText($catXml).Replace('ITL справочник (синоним задачи)', 'ITL справочник (первый CF, не помещён)'), $bom)
$fl = Join-Path $Root 'файлы-3.txt'; [IO.File]::WriteAllLines($fl, @($catXml), $bom)
$r += Invoke-1C -Ib $dev -Arguments @('/LoadConfigFromFiles', $d, '-listFile', $fl, '-Format', 'Hierarchical', '/UpdateDBCfg') -Label 'dev-apply-first'
# colleague commits another change to the form
$r += Invoke-1C -Ib $col -Arguments ((Repo-Args 'Коллега') + @('/ConfigurationRepositoryLock', '-Objects', $formList)) -Label 'col-lock-form'
$cd = Join-Path $Root 'исходники коллеги 2'
$r += Invoke-1C -Ib $col -Arguments @('/DumpConfigToFiles', $cd) -Label 'col-dump-2'
$mod = Join-Path $cd 'DataProcessors\ITLОбработкаПроверкиОбработчиковФормы\Forms\ФормаПроверкиОбработчиковСДлиннымИменем\Ext\Form\Module.bsl'
[IO.File]::WriteAllText($mod, [IO.File]::ReadAllText($mod).Replace('Коллега: изменено в хранилище', 'Коллега: версия 5'), $bom)
$fl2 = Join-Path $Root 'файлы-коллеги-2.txt'; [IO.File]::WriteAllLines($fl2, @($mod), $bom)
$r += Invoke-1C -Ib $col -Arguments @('/LoadConfigFromFiles', $cd, '-listFile', $fl2, '-Format', 'Hierarchical') -Label 'col-load-2'
$r += Invoke-1C -Ib $col -Arguments ((Repo-Args 'Коллега') + @('/ConfigurationRepositoryCommit', '-Objects', $formList, '-comment', 'Коллега: версия 5')) -Label 'col-commit-5'
# dev: foreign-change probe, then update from repository while catalog is locked and modified
$r += Invoke-1C -Ib $dev -Arguments ((Repo-Args 'Разработчик') + @('/CompareCfg', '-FirstConfigurationType', 'ConfigurationRepository', '-FirstVersion', '4', '-SecondConfigurationType', 'MainConfiguration', '-ReportType', 'Full', '-ReportFormat', 'txt', '-ReportFile', (Join-Path $rep 'непомещённое в ИБ.txt'))) -Label 'probe-uncommitted'
$r += Invoke-1C -Ib $dev -Arguments ((Repo-Args 'Разработчик') + @('/ConfigurationRepositoryUpdateCfg', '-force', '/UpdateDBCfg')) -Label 'dev-update-with-local'
$r += Invoke-1C -Ib $dev -Arguments ((Repo-Args 'Разработчик') + @('/CompareCfg', '-FirstConfigurationType', 'ConfigurationRepository', '-FirstVersion', '5', '-SecondConfigurationType', 'MainConfiguration', '-ReportType', 'Full', '-ReportFormat', 'txt', '-ReportFile', (Join-Path $rep 'после обновления v5 против ИБ.txt'))) -Label 'repo5-vs-main'
$r | ForEach-Object { Show-1C $_ }
foreach ($n in @('непомещённое в ИБ.txt', 'после обновления v5 против ИБ.txt')) { "== $n"; [IO.File]::ReadAllText((Join-Path $rep $n), [Text.Encoding]::Unicode) }
