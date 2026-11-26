. (Join-Path $PSScriptRoot 'stand-lib.ps1')
$dev = Join-Path $Root 'ИБ разработчика'
$col = Join-Path $Root 'ИБ коллеги'
$rep = Join-Path $Root 'отчёты'
$list = Join-Path $Root 'объекты-формы.xml'
$r = @()
$r += Invoke-1C -Ib $dev -Arguments @('/UpdateDBCfg') -Label 'dev-updatedb'
$r += Invoke-1C -Ib $dev -Arguments ((Repo-Args 'Разработчик') + @('/ConfigurationRepositoryCommit', '-Objects', $list, '-comment', '0001234: Удаление реквизита и правка обработчика')) -Label 'dev-commit'
$r += Invoke-1C -Ib $dev -Arguments ((Repo-Args 'Разработчик') + @('/ConfigurationRepositoryReport', (Join-Path $rep 'история после помещения.mxl'), '-NBegin', '3')) -Label 'history-v3'
$r += Invoke-1C -Ib $col -Arguments ((Repo-Args 'Коллега') + @('/ConfigurationRepositoryLock', '-Objects', $list)) -Label 'col-lock-after-commit'
$r += Invoke-1C -Ib $col -Arguments ((Repo-Args 'Коллега') + @('/ConfigurationRepositoryUnLock', '-Objects', $list)) -Label 'col-unlock'
$r += Invoke-1C -Ib $dev -Arguments ((Repo-Args 'Разработчик') + @('/CompareCfg', '-FirstConfigurationType', 'ConfigurationRepository', '-FirstVersion', '3', '-SecondConfigurationType', 'MainConfiguration', '-ReportType', 'Full', '-ReportFormat', 'txt', '-ReportFile', (Join-Path $rep 'хранилище v3 против ИБ.txt'))) -Label 'repo3-vs-main'
$r | ForEach-Object { Show-1C $_ }
[IO.File]::ReadAllText((Join-Path $rep 'хранилище v3 против ИБ.txt'), [Text.Encoding]::Unicode)
$b = [IO.File]::ReadAllBytes((Join-Path $rep 'история после помещения.mxl')); $s = [Text.Encoding]::UTF8.GetString($b)
[regex]::Matches($s, '\{"#","((?:[^"]|"")*)"\}') | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_.Trim() -and $_ -notmatch '^C:' } | Select-Object -First 30
