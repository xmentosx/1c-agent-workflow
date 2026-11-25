. (Join-Path $PSScriptRoot 'stand-lib.ps1')
$dev = Join-Path $Root 'ИБ разработчика'
$rep = Join-Path $Root 'отчёты'
$fresh = Join-Path $Root 'ветка-после-refresh.cf'
$r = @()
foreach ($v in @('-FirstVersion', '-FirstConfigurationVersion', '-FirstName')) {
  $r += Invoke-1C -Ib $dev -Arguments ((Repo-Args 'Разработчик') + @('/CompareCfg', '-FirstConfigurationType', 'ConfigurationRepository', $v, '2', '-SecondConfigurationType', 'File', '-SecondFile', $fresh, '-ReportType', 'Full', '-ReportFormat', 'txt', '-ReportFile', (Join-Path $rep "хранилище v2 против ветки $v.txt"))) -Label "cmp-repo$v"
}
$r += Invoke-1C -Ib $dev -Arguments ((Repo-Args 'Разработчик') + @('/ConfigurationRepositoryReport', (Join-Path $rep 'история.mxl'), '-NBegin', '1')) -Label 'repo-report-mxl'
$r += Invoke-1C -Ib $dev -Arguments ((Repo-Args 'Разработчик') + @('/ConfigurationRepositoryReport', (Join-Path $rep 'история.txt'), '-NBegin', '1')) -Label 'repo-report-txt'
$r | ForEach-Object { Show-1C $_ }
Get-ChildItem -LiteralPath $rep | Select-Object Name, Length
