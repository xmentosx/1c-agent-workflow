. (Join-Path $PSScriptRoot 'stand-lib.ps1')
$dev = Join-Path $Root 'ИБ разработчика'
$col = Join-Path $Root 'ИБ коллеги'
$rep = Join-Path $Root 'отчёты'
$ns = 'http://v8.1c.ru/8.3/config/objects'
$commitList = Join-Path $Root 'помещение-2.xml'
[IO.File]::WriteAllText($commitList, "<?xml version=`"1.0`" encoding=`"UTF-8`"?>`r`n<Objects xmlns=`"$ns`" version=`"1.0`">`r`n  <Configuration includeChildObjects=`"false`"/>`r`n  <Object fullName=`"CommonTemplate.ITLДвоичныйМакетПроверки`" includeChildObjects=`"false`"/>`r`n  <Object fullName=`"CommonModule.ITLНовыйМодульЗадачи`" includeChildObjects=`"false`"/>`r`n  <Object fullName=`"Catalog.ITLСправочникСДлиннымКириллическимИменемДляПроверкиБюджетаПутей`" includeChildObjects=`"false`"/>`r`n</Objects>`r`n", (New-Object Text.UTF8Encoding $false))
$r = @()
$r += Invoke-1C -Ib $dev -Arguments @('/UpdateDBCfg') -Label 'updatedb-2'
$r += Invoke-1C -Ib $dev -Arguments ((Repo-Args 'Разработчик') + @('/ConfigurationRepositoryCommit', '-Objects', $commitList, '-comment', 'Задача 2: объекты')) -Label 'commit-2'
$r += Invoke-1C -Ib $dev -Arguments ((Repo-Args 'Разработчик') + @('/CompareCfg', '-FirstConfigurationType', 'ConfigurationRepository', '-FirstVersion', '4', '-SecondConfigurationType', 'MainConfiguration', '-ReportType', 'Full', '-ReportFormat', 'txt', '-ReportFile', (Join-Path $rep 'хранилище v4 против ИБ.txt'))) -Label 'repo4-vs-main'
$rootList = Join-Path $Root 'корень.xml'
[IO.File]::WriteAllText($rootList, "<?xml version=`"1.0`" encoding=`"UTF-8`"?>`r`n<Objects xmlns=`"$ns`" version=`"1.0`">`r`n  <Configuration includeChildObjects=`"false`"/>`r`n</Objects>`r`n", (New-Object Text.UTF8Encoding $false))
$r += Invoke-1C -Ib $col -Arguments ((Repo-Args 'Коллега') + @('/ConfigurationRepositoryUpdateCfg', '-force')) -Label 'col-update-v4'
$r += Invoke-1C -Ib $col -Arguments ((Repo-Args 'Коллега') + @('/ConfigurationRepositoryLock', '-Objects', $rootList)) -Label 'col-lock-root'
$r += Invoke-1C -Ib $col -Arguments ((Repo-Args 'Коллега') + @('/ConfigurationRepositoryUnLock', '-Objects', $rootList)) -Label 'col-unlock-root'
# clean revision without touching the infobase
$r += Invoke-1C -Ib $dev -Arguments ((Repo-Args 'Разработчик') + @('/ConfigurationRepositoryDumpCfg', (Join-Path $Root 'хранилище-v4.cf'), '-v', '4')) -Label 'repo-dumpcfg-v4'
$r += Invoke-1C -Ib $dev -Arguments ((Repo-Args 'Разработчик') + @('/ConfigurationRepositoryReport', (Join-Path $rep 'история v4.mxl'), '-NBegin', '4')) -Label 'history-v4'
$r | ForEach-Object { Show-1C $_ }
"== repo4 vs main"; [IO.File]::ReadAllText((Join-Path $rep 'хранилище v4 против ИБ.txt'), [Text.Encoding]::Unicode)
$s = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes((Join-Path $rep 'история v4.mxl')))
"== history v4"; [regex]::Matches($s, '\{"#","((?:[^"]|"")*)"\}') | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_.Trim() -and $_ -notmatch '^C:' }
Get-Item -LiteralPath (Join-Path $Root 'хранилище-v4.cf') | Select-Object Name, Length
