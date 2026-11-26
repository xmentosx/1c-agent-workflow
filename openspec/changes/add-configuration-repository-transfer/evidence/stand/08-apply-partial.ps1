. (Join-Path $PSScriptRoot 'stand-lib.ps1')
$dev = Join-Path $Root 'ИБ разработчика'
$rep = Join-Path $Root 'отчёты'
$fresh = Join-Path $Root 'ветка-после-refresh.cf'
$src = Join-Path $Root 'ветка после refresh'
$rel = 'DataProcessors\ITLОбработкаПроверкиОбработчиковФормы\Forms\ФормаПроверкиОбработчиковСДлиннымИменем\Ext'
$files = Join-Path $Root 'файлы-задачи.txt'
[IO.File]::WriteAllLines($files, @((Join-Path $src "$rel\Form.xml"), (Join-Path $src "$rel\Form\Module.bsl")), (New-Object Text.UTF8Encoding $true))
$r = @()
$r += Invoke-1C -Ib $dev -Arguments @('/LoadConfigFromFiles', $src, '-listFile', $files, '-Format', 'Hierarchical') -Label 'apply-partial'
$r += Invoke-1C -Ib $dev -Arguments @('/CompareCfg', '-FirstConfigurationType', 'MainConfiguration', '-SecondConfigurationType', 'File', '-SecondFile', $fresh, '-ReportType', 'Full', '-ReportFormat', 'txt', '-ReportFile', (Join-Path $rep 'после применения ИБ против CF.txt')) -Label 'verify-main-vs-cf'
$r += Invoke-1C -Ib $dev -Arguments ((Repo-Args 'Разработчик') + @('/CompareCfg', '-FirstConfigurationType', 'ConfigurationRepository', '-FirstVersion', '2', '-SecondConfigurationType', 'MainConfiguration', '-ReportType', 'Full', '-ReportFormat', 'txt', '-ReportFile', (Join-Path $rep 'хранилище v2 против ИБ после применения.txt'))) -Label 'repo-vs-main'
$r += Invoke-1C -Ib $dev -Arguments @('/CompareCfg', '-FirstConfigurationType', 'DBConfiguration', '-SecondConfigurationType', 'MainConfiguration', '-ReportType', 'Full', '-ReportFormat', 'txt', '-ReportFile', (Join-Path $rep 'конфигурация БД против основной.txt')) -Label 'db-vs-main'
$r | ForEach-Object { Show-1C $_ }
foreach ($f in Get-ChildItem -LiteralPath $rep -Filter '*.txt' | Where-Object { $_.Name -match 'после применения|БД против' }) { "== $($f.Name) ($($f.Length) bytes)"; [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::Unicode) }
