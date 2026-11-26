. (Join-Path $PSScriptRoot 'stand-lib.ps1')
$bom = New-Object Text.UTF8Encoding $true
$dev = Join-Path $Root 'ИБ разработчика'
$build = Join-Path $Root 'ИБ сборки fresh'
$rep = Join-Path $Root 'отчёты'
$src = Join-Path $Root 'ветка 2'
$cf = Join-Path $Root 'ветка-2.cf'
$r = @()
$r += Invoke-1C -Ib $dev -Arguments @('/DumpConfigToFiles', $src) -Label 'dump-v3'
# a) delete common template
$cfgXml = Join-Path $src 'Configuration.xml'
$c = [IO.File]::ReadAllText($cfgXml)
$c = $c.Replace("`t`t`t<CommonTemplate>ITLДвоичныйМакетПроверки</CommonTemplate>`r`n", '')
# b) new common module
$c = $c.Replace("`t`t`t<CommonModule>ITLСерверныйОбщийМодуль</CommonModule>`r`n", "`t`t`t<CommonModule>ITLСерверныйОбщийМодуль</CommonModule>`r`n`t`t`t<CommonModule>ITLНовыйМодульЗадачи</CommonModule>`r`n")
[IO.File]::WriteAllText($cfgXml, $c, $bom)
Remove-Item -LiteralPath (Join-Path $src 'CommonTemplates\ITLДвоичныйМакетПроверки.xml') -Force
Remove-Item -LiteralPath (Join-Path $src 'CommonTemplates\ITLДвоичныйМакетПроверки') -Recurse -Force
$oldMod = Join-Path $src 'CommonModules\ITLСерверныйОбщийМодуль.xml'
$newMod = Join-Path $src 'CommonModules\ITLНовыйМодульЗадачи.xml'
$t = [IO.File]::ReadAllText($oldMod).Replace('ITLСерверныйОбщийМодуль', 'ITLНовыйМодульЗадачи').Replace('ITL серверный общий модуль', 'ITL новый модуль задачи')
$t = [regex]::Replace($t, 'uuid="[0-9a-f-]+"', 'uuid="' + [guid]::NewGuid().ToString() + '"')
[IO.File]::WriteAllText($newMod, $t, $bom)
New-Item -ItemType Directory -Force -Path (Join-Path $src 'CommonModules\ITLНовыйМодульЗадачи\Ext') | Out-Null
[IO.File]::WriteAllText((Join-Path $src 'CommonModules\ITLНовыйМодульЗадачи\Ext\Module.bsl'), "Функция НовоеЗначение() Экспорт`r`n`tВозврат 42;`r`nКонецФункции`r`n", $bom)
# c) property change on catalog
$catXml = Join-Path $src 'Catalogs\ITLСправочникСДлиннымКириллическимИменемДляПроверкиБюджетаПутей.xml'
$k = [IO.File]::ReadAllText($catXml)
$k2 = $k.Replace('<DescriptionLength>150</DescriptionLength>', '<DescriptionLength>120</DescriptionLength>').Replace('ITL справочник с длинным кириллическим именем', 'ITL справочник (синоним задачи)')
if ($k2 -eq $k) { throw 'catalog not changed' }
[IO.File]::WriteAllText($catXml, $k2, $bom)
# build CF
$r += Invoke-1C -Ib $build -Arguments @('/LoadConfigFromFiles', $src, '/UpdateDBCfg') -Label 'build2-load'
$r += Invoke-1C -Ib $build -Arguments @('/DumpCfg', $cf) -Label 'build2-dumpcfg'
$r += Invoke-1C -Ib $dev -Arguments ((Repo-Args 'Разработчик') + @('/CompareCfg', '-FirstConfigurationType', 'ConfigurationRepository', '-FirstVersion', '3', '-SecondConfigurationType', 'File', '-SecondFile', $cf, '-ReportType', 'Full', '-ReportFormat', 'txt', '-ReportFile', (Join-Path $rep 'хранилище v3 против ветки 2.txt'))) -Label 'cmp-repo3-vs-cf2'
# lock root + changed + deleted objects
$ns = 'http://v8.1c.ru/8.3/config/objects'
$lockList = Join-Path $Root 'объекты-задачи-2.xml'
[IO.File]::WriteAllText($lockList, "<?xml version=`"1.0`" encoding=`"UTF-8`"?>`r`n<Objects xmlns=`"$ns`" version=`"1.0`">`r`n  <Configuration includeChildObjects=`"false`"/>`r`n  <Object fullName=`"CommonTemplate.ITLДвоичныйМакетПроверки`" includeChildObjects=`"false`"/>`r`n  <Object fullName=`"Catalog.ITLСправочникСДлиннымКириллическимИменемДляПроверкиБюджетаПутей`" includeChildObjects=`"false`"/>`r`n</Objects>`r`n", (New-Object Text.UTF8Encoding $false))
$r += Invoke-1C -Ib $dev -Arguments ((Repo-Args 'Разработчик') + @('/ConfigurationRepositoryLock', '-Objects', $lockList)) -Label 'lock-2'
$files = Join-Path $Root 'файлы-задачи-2.txt'
[IO.File]::WriteAllLines($files, @($cfgXml, $newMod, (Join-Path $src 'CommonModules\ITLНовыйМодульЗадачи\Ext\Module.bsl'), $catXml), $bom)
$r += Invoke-1C -Ib $dev -Arguments @('/LoadConfigFromFiles', $src, '-listFile', $files, '-Format', 'Hierarchical') -Label 'apply-partial-2'
$r += Invoke-1C -Ib $dev -Arguments @('/CompareCfg', '-FirstConfigurationType', 'MainConfiguration', '-SecondConfigurationType', 'File', '-SecondFile', $cf, '-ReportType', 'Full', '-ReportFormat', 'txt', '-ReportFile', (Join-Path $rep 'после применения 2 ИБ против CF.txt')) -Label 'verify-2'
$r | ForEach-Object { Show-1C $_ }
foreach ($n in @('хранилище v3 против ветки 2.txt', 'после применения 2 ИБ против CF.txt')) { "== $n"; [IO.File]::ReadAllText((Join-Path $rep $n), [Text.Encoding]::Unicode) }
