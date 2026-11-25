. (Join-Path $PSScriptRoot 'stand-lib.ps1')
$dev = Join-Path $Root 'ИБ разработчика'
$rep = Join-Path $Root 'отчёты'
$fresh = Join-Path $Root 'ветка-после-refresh.cf'
$list = Join-Path $Root 'объекты-формы.xml'
$r = @()
$r += Invoke-1C -Ib $dev -Arguments ((Repo-Args 'Разработчик') + @('/ConfigurationRepositoryUpdateCfg', '-force', '/UpdateDBCfg')) -Label 'dev-update'
$r += Invoke-1C -Ib $dev -Arguments ((Repo-Args 'Разработчик') + @('/ConfigurationRepositoryLock', '-Objects', $list)) -Label 'dev-lock'
$r += Invoke-1C -Ib $dev -Arguments @('/CompareCfg', '-FirstConfigurationType', 'MainConfiguration', '-SecondConfigurationType', 'File', '-SecondFile', $fresh, '-ReportType', 'Full', '-ReportFormat', 'txt', '-ReportFile', (Join-Path $rep 'ИБ-v2 против ветки.txt')) -Label 'cmp-after-update'
$r += Invoke-1C -Ib $dev -Arguments @('/MergeCfg', $fresh, '-force') -Label 'merge-no-settings'
$r | ForEach-Object { Show-1C $_ }
